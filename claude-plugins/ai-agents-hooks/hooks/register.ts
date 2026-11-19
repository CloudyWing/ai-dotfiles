import type { Engine, Register } from 'claude-code'
import type { HookIo } from './core/io'
import { docPathReminder } from './core/doc-path'
import { hostGuardDenyReason } from './core/host-guard'
import { postEditWriteMessages } from './core/post-edit-write'

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
    readBytes: async path => decodeBase64((await $.fs.read(path, { as: 'bytes' })).base64),
    isDirectory: async path => {
      try { return (await $.fs.stat(path)).kind === 'dir' } catch { return false }
    },
    run: async argv => (await $.process.run(argv, { timeoutMs: GIT_TIMEOUT_MS })).exitCode,
    log: text => { $.ui.log(text, { to: 'debug' }) }
  }
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
