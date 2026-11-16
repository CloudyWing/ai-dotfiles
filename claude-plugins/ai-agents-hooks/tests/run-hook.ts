// 測試用轉接器：以 node 執行 hooks/core 的邏輯，輸入輸出比照命令型 hook（stdin 為事件 JSON，stdout 為 hook 回應）。
// 只供 scripts/tests 下的測試使用，不是外掛執行期的一部分。用法：node --no-warnings tests/run-hook.ts <模式>
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { registerHooks } from 'node:module'
import { spawnSync } from 'node:child_process'
import { dirname } from 'node:path'
import type { HookIo } from '../hooks/core/io'

// hooks 模組的相對匯入不帶副檔名（引擎的解析方式），node 需要補上 .ts。
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier.startsWith('.') && !/\.[cm]?[jt]sx?$/u.test(specifier)) return nextResolve(specifier + '.ts', context)
    return nextResolve(specifier, context)
  }
})

// 讀取失敗注入：TURN_GUARD_TEST_READ_FAILURE 為「<檔名結尾>|<計次檔>」，符合的檔案每次讀取都失敗並在計次檔追加一個 x。
const readFailure = (process.env['TURN_GUARD_TEST_READ_FAILURE'] ?? '').split('|')

const io: HookIo = {
  readText: async path => {
    if (readFailure.length === 2 && readFailure[0] !== '' && path.endsWith(readFailure[0] ?? '')) {
      appendFileSync(readFailure[1] ?? '', 'x')
      throw new Error('injected read failure')
    }
    return readFileSync(path, 'utf8')
  },
  readBytes: async path => new Uint8Array(readFileSync(path)),
  writeText: async (path, text) => {
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, text, 'utf8')
  },
  exists: async path => existsSync(path),
  isDirectory: async path => {
    try { return statSync(path).isDirectory() } catch { return false }
  },
  list: async directory => readdirSync(directory, { withFileTypes: true }).filter(entry => entry.isFile()).map(entry => ({ name: entry.name, size: statSync(dirname(directory + '/x') + '/' + entry.name).size })),
  run: async argv => {
    const [command, ...rest] = argv
    const result = spawnSync(command ?? '', rest, { stdio: 'ignore', windowsHide: true })
    if (result.error !== undefined || result.status === null) throw result.error ?? new Error('process failed')
    return result.status
  },
  log: text => { process.stdout.write(text + '\n') }
}

// 比照命令型 hook 的輸出：單一 JSON 物件，純 ASCII、不帶 BOM，非 ASCII 字元以 \uXXXX 跳脫。
function emit(payload: unknown): void {
  const ascii = JSON.stringify(payload).replace(/[^\u0000-\u007F]/gu, text => Array.from({ length: text.length }, (_unused, index) => String.fromCharCode(92) + 'u' + text.charCodeAt(index).toString(16).padStart(4, '0')).join(''))
  process.stdout.write(ascii, 'ascii')
}

function parse(text: string): unknown {
  if (text.trim() === '') return undefined
  try { return JSON.parse(text) } catch { return undefined }
}

function property(value: unknown, name: string): unknown {
  return typeof value === 'object' && value !== null ? (value as Record<string, unknown>)[name] : undefined
}

const mode = process.argv[2] ?? ''
const dataRoot = process.env['CLAUDE_PLUGIN_DATA']
// 與命令型 turn-guard 相同：未設定資料目錄時不讀 stdin。
const input = mode === 'turn-guard' && (dataRoot === undefined || dataRoot.trim() === '') ? undefined : parse(readFileSync(0, 'utf8'))

if (mode === 'turn-guard') {
  const { handleTurnGuardEvent } = await import('../hooks/core/turn-guard')
  const reminder = await handleTurnGuardEvent(io, dataRoot, input)
  if (reminder !== undefined) emit({ hookSpecificOutput: { hookEventName: 'PostToolUseFailure', additionalContext: reminder } })
} else if (mode === 'turn-guard-batch') {
  // 輸入為事件陣列，在同一行程內同時送出，驗證同一 session 的並行事件依序處理。每則提醒輸出一行。
  const { handleTurnGuardEvent } = await import('../hooks/core/turn-guard')
  const events = Array.isArray(input) ? input : []
  const reminders = await Promise.all(events.map(event => handleTurnGuardEvent(io, dataRoot, event)))
  for (const reminder of reminders) {
    if (reminder === undefined) continue
    emit({ hookSpecificOutput: { hookEventName: 'PostToolUseFailure', additionalContext: reminder } })
    process.stdout.write('\n')
  }
} else if (mode === 'host-guard') {
  const { hostGuardDenyReason } = await import('../hooks/core/host-guard')
  const reason = hostGuardDenyReason(process.env['AI_AGENTS_ALLOW_POWERSHELL51'], property(input, 'tool_name'), property(property(input, 'tool_input'), 'command'))
  if (reason !== undefined) emit({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason } })
} else if (mode === 'doc-path') {
  const { docPathReminder } = await import('../hooks/core/doc-path')
  const reminder = await docPathReminder(io, input)
  if (reminder !== undefined) emit({ hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: reminder } })
} else if (mode === 'post-edit-write') {
  const { postEditWriteMessages } = await import('../hooks/core/post-edit-write')
  await postEditWriteMessages(io, input)
} else if (mode === 'lib-parity') {
  // 輸入為 [{ kind: 'find' | 'excluded', input: string }]，輸出為各筆結果的陣列，供與 PowerShell 函式庫比對。
  const { findLocalPathViolations, isLocalPathExcludedFile } = await import('../hooks/core/doc-path')
  const cases = Array.isArray(input) ? input : []
  emit(cases.map(item => {
    const text = property(item, 'input')
    const value = typeof text === 'string' ? text : ''
    return property(item, 'kind') === 'excluded' ? isLocalPathExcludedFile(value) : findLocalPathViolations(value)
  }))
} else {
  process.stderr.write('unknown mode: ' + mode + '\n')
  process.exitCode = 2
}
