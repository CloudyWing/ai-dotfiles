// 測試用轉接器：以 node 執行 hooks/core 的邏輯，輸入輸出比照命令型 hook（stdin 為事件 JSON，stdout 為 hook 回應）。
// 只供 scripts/tests 下的測試使用，不是外掛執行期的一部分。用法：node --no-warnings tests/run-hook.ts <模式>
import { mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import { registerHooks } from 'node:module'
import { spawnSync } from 'node:child_process'
import type { HookIo } from '../hooks/core/io'

// hooks 模組的相對匯入不帶副檔名（引擎的解析方式），node 需要補上 .ts。
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier.startsWith('.') && !/\.[cm]?[jt]sx?$/u.test(specifier)) return nextResolve(specifier + '.ts', context)
    return nextResolve(specifier, context)
  }
})

const io: HookIo = {
  readBytes: async path => new Uint8Array(readFileSync(path)),
  isDirectory: async path => {
    try { return statSync(path).isDirectory() } catch { return false }
  },
  run: async argv => {
    const [command, ...rest] = argv
    const result = spawnSync(command ?? '', rest, { stdio: 'ignore', windowsHide: true })
    if (result.error !== undefined || result.status === null) throw result.error ?? new Error('process failed')
    return result.status
  },
  log: text => { process.stdout.write(text + '\n') },
  writeText: async (path, text) => {
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, text, 'utf8')
  }
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
const input = parse(readFileSync(0, 'utf8'))

if (mode === 'host-guard') {
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
} else if (mode === 'mcp-call') {
  // 輸入為 { event, kind: 'completed' | 'failed', now? }；LOCALAPPDATA 取自本程序的環境變數（未設定時不寫入）。
  // 輸出為 { written: 寫入的完整路徑或 null }，檔案內容由測試自行讀取。
  const { writeMcpCallRecord } = await import('../hooks/core/mcp-call-record')
  const kindValue = property(input, 'kind')
  const nowValue = property(input, 'now')
  const written = await writeMcpCallRecord(io, process.env['LOCALAPPDATA'], property(input, 'event'), kindValue === 'failed' ? 'failed' : 'completed', typeof nowValue === 'string' ? nowValue : new Date().toISOString())
  emit({ written: written ?? null })
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
