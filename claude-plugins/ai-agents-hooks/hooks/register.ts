import type { Engine, Register } from 'claude-code'
import type { HookIo } from './core/io'
import { isBlank, joinPath } from './core/io'
import { docPathReminder } from './core/doc-path'
import { hostGuardDenyReason } from './core/host-guard'
import { postEditWriteMessages } from './core/post-edit-write'
import { handleTurnGuardEvent, releaseTurnGuardSession } from './core/turn-guard'

// 外掛資料目錄的名稱：外掛名稱加上 marketplace 名稱，與命令型 hook 的 CLAUDE_PLUGIN_DATA 相同。
const DATA_DIRECTORY_NAME = 'ai-agents-hooks-ai-agents-local'
const TURN_GUARD_TOOLS = /^(Bash|PowerShell|Read|Grep|Glob|Edit|Write|Skill|Agent)$/
const EDIT_TOOLS = /^(Edit|Write)$/
const GIT_TIMEOUT_MS = 8000

function decodeBase64(base64: string): Uint8Array {
  const binary = atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index)
  return bytes
}

function ioOf($: Engine): HookIo {
  return {
    readText: path => $.fs.read(path),
    readBytes: async path => decodeBase64((await $.fs.read(path, { as: 'bytes' })).base64),
    writeText: (path, text) => $.fs.write(path, text),
    exists: path => $.fs.exists(path),
    isDirectory: async path => {
      try { return (await $.fs.stat(path)).kind === 'dir' } catch { return false }
    },
    list: async directory => (await $.fs.list(directory)).filter(entry => entry.kind === 'file').map(entry => ({ name: entry.name, size: entry.size })),
    run: async argv => (await $.process.run(argv, { timeoutMs: GIT_TIMEOUT_MS })).exitCode,
    log: text => { $.ui.log(text, { to: 'debug' }) }
  }
}

// 模組的執行環境沒有 CLAUDE_PLUGIN_DATA。有設定時採用，否則由設定目錄推得同一個位置；都取不到時回傳 undefined，不寫任何檔案。
async function dataRootOf($: Engine): Promise<string | undefined> {
  try {
    const explicit = await $.env.get('CLAUDE_PLUGIN_DATA')
    if (explicit !== undefined && !isBlank(explicit)) return explicit
    const configDirectory = await $.env.get('CLAUDE_CONFIG_DIR')
    if (configDirectory !== undefined && !isBlank(configDirectory)) return joinPath(joinPath(joinPath(configDirectory, 'plugins'), 'data'), DATA_DIRECTORY_NAME)
    const profile = await $.env.get('USERPROFILE')
    if (profile !== undefined && !isBlank(profile)) return joinPath(joinPath(joinPath(joinPath(profile, '.claude'), 'plugins'), 'data'), DATA_DIRECTORY_NAME)
  } catch {
    // 取不到環境變數時視同未設定。
  }
  return undefined
}

async function turnGuard($: Engine, input: unknown): Promise<string | undefined> {
  try { return await handleTurnGuardEvent(ioOf($), await dataRootOf($), input) } catch { return undefined }
}

async function hostGuard($: Engine, tool: unknown, command: unknown): Promise<string | undefined> {
  let optIn: string | undefined
  try { optIn = await $.env.get('AI_AGENTS_ALLOW_POWERSHELL51') } catch { optIn = undefined }
  return hostGuardDenyReason(optIn, tool, command)
}

async function docPath($: Engine, input: unknown): Promise<string | undefined> {
  return docPathReminder(ioOf($), input)
}

async function postEditWrite($: Engine, input: unknown): Promise<void> {
  await postEditWriteMessages(ioOf($), input)
}

function withContext<Result extends { additionalContext?: string[] }>(result: Result, text: string | undefined): Result {
  if (text === undefined) return result
  return { ...result, additionalContext: [...(result.additionalContext ?? []), text] }
}

export const register: Register = on => {
  on('classic.UserPromptSubmit', async ($, e, next) => {
    await turnGuard($, e)
    return next(e)
  })

  // session 結束（含 /clear）時釋放 turn-guard 在記憶體中的狀態。session.end 的預算很短，失敗時不影響結束流程。
  on('session.end', async ($, e, next) => {
    try { await releaseTurnGuardSession(ioOf($), await dataRootOf($), e.sessionId) } catch { /* 釋放失敗時保留狀態 */ }
    return next(e)
  })

  on('classic.Stop', async ($, e, next) => {
    await turnGuard($, e)
    return next(e)
  })

  on('classic.PostToolUse', { tool_name: TURN_GUARD_TOOLS }, async ($, e, next) => {
    await turnGuard($, e)
    return next(e)
  })

  on('classic.PostToolUseFailure', { tool_name: TURN_GUARD_TOOLS }, async ($, e, next) => {
    const reminder = await turnGuard($, e)
    return withContext(await next(e), reminder)
  })

  // 判定失敗時放行，與其餘無法判定的情況一致，因此不加 .catch。
  on('classic.PreToolUse', { tool: ['Bash', 'PowerShell'] }, async ($, e, next) => {
    const reason = await hostGuard($, e.tool, e.command)
    return reason === undefined ? next(e) : { deny: reason }
  })

  on('classic.PostToolUse', { tool_name: EDIT_TOOLS }, async ($, e, next) => {
    await postEditWrite($, e)
    return next(e)
  })

  on('classic.PostToolUse', { tool_name: EDIT_TOOLS }, async ($, e, next) => {
    const reminder = await docPath($, e)
    return withContext(await next(e), reminder)
  })
}
