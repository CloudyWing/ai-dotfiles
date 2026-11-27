// 註冊層的測試：事件與 matcher 的接線與回傳形狀。判定邏輯本身由 scripts/tests 的 PowerShell 測試經 tests/run-hook.ts 驗證。
import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const DOC = 'C:\\repo\\docs\\a.md'

type World = { files: Map<string, string>; writes: Map<string, string>; logs: string[]; gitCalls: string[][] }

// 以記憶體模擬 $.fs、$.process.run 與 $.ui.log；目錄只認 C:\repo\docs。
function world(on: On, gitExitCode = 1): World {
  const state: World = { files: new Map(), writes: new Map(), logs: [], gitCalls: [] }
  on('fs.write', (_$, e) => { state.writes.set(e.path, e.text); return { value: undefined } })
  on('fs.read', (_$, e) => {
    const text = state.files.get(e.path)
    if (text === undefined) return { deny: 'missing' }
    return { value: e.as === 'bytes' ? { base64: btoa(unescape(encodeURIComponent(text))) } : text }
  })
  on('fs.stat', (_$, e) => e.path === 'C:\\repo\\docs' ? { value: { kind: 'dir', size: 0, mtimeMs: 0, isLink: false } } : { deny: 'missing' })
  on('process.run', (_$, e) => { state.gitCalls.push([...e.argv]); return { value: { exitCode: gitExitCode, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } })
  on('ui.log', (_$, e) => { state.logs.push(e.text); return { value: undefined } })
  on('tool.call', () => ({ result: {} }))
  // 引擎的 settings hook 不存在，classic 事件由測試回答空結果。
  on('classic.PostToolUse', () => ({}))
  on('classic.PostToolUseFailure', () => ({}))
  return state
}

test('R01 Bash 與 PowerShell 直接呼叫 powershell.exe 時拒絕，pwsh 放行', async ($, on) => {
  mock.env(on, {})
  world(on)
  for (const tool of ['Bash', 'PowerShell'] as const) {
    const denied = await $.tool.call({ tool, command: 'powershell.exe -NoProfile -Command "Write-Output x"' })
    expect(denied.isError).toBe(true)
    expect(denied.text).toContain('禁止直接呼叫 powershell.exe（Windows PowerShell 5.1）。')
    const allowed = await $.tool.call({ tool, command: 'pwsh -NoProfile -Command "Write-Output x"' })
    expect(allowed.isError ?? false).toBe(false)
  }
})

test('R02 AI_AGENTS_ALLOW_POWERSHELL51=1 時放行', async ($, on) => {
  mock.env(on, { AI_AGENTS_ALLOW_POWERSHELL51: '1' })
  world(on)
  const result = await $.tool.call({ tool: 'Bash', command: 'powershell.exe -File a.ps1' })
  expect(result.isError ?? false).toBe(false)
})

test('R03 受控 .md 寫入含本機路徑時以 additionalContext 提醒，並呼叫 git check-ignore', async ($, on) => {
  mock.env(on, {})
  const state = world(on, 1)
  state.files.set(DOC, 'x')
  const result = await $.classic.PostToolUse({ session_id: 's1', tool_name: 'Write', tool_input: { file_path: DOC, content: '第一行\n另見 D:\\Work\\data.csv' }, tool_response: {}, tool_use_id: 't' })
  expect(result.additionalContext?.length).toBe(1)
  expect(result.additionalContext?.[0]).toContain('doc-placement: ' + DOC + ' 本次寫入的內容含本機磁碟機絕對路徑')
  expect(result.additionalContext?.[0]).toContain('line 2: D:\\Work\\data.csv')
  expect(state.gitCalls).toEqual([['git', '-C', 'C:\\repo\\docs', 'check-ignore', '-q', '--', DOC]])
})

test('R04 git check-ignore 不是 1 時不提醒', async ($, on) => {
  mock.env(on, {})
  world(on, 0)
  const result = await $.classic.PostToolUse({ session_id: 's1', tool_name: 'Edit', tool_input: { file_path: DOC, old_string: 'a', new_string: 'E:\\Work\\repo' }, tool_response: {}, tool_use_id: 't' })
  expect(result.additionalContext ?? []).toEqual([])
})

test('R05 post-edit-write 的訊息只寫入 debug log，不送給模型', async ($, on) => {
  mock.env(on, {})
  const state = world(on)
  state.files.set('C:\\repo\\docs\\b.md', '\uFEFF這裡——轉折\n')
  const result = await $.classic.PostToolUse({ session_id: 's1', tool_name: 'Write', tool_input: { file_path: 'C:\\repo\\docs\\b.md', content: '這裡——轉折\n' }, tool_response: {}, tool_use_id: 't' })
  expect(result.additionalContext ?? []).toEqual([])
  expect(state.logs[0]).toBe('[post-edit-write hook] C:\\repo\\docs\\b.md was written. Please run check-markdown skill to verify Markdown formatting.')
  expect(state.logs.some(line => line.includes('forbidden full-width dash'))).toBe(true)
  expect(state.logs.some(line => line.includes('has unexpected UTF-8 BOM'))).toBe(true)
})
const LOCAL = 'C:\\Local'
const CALL_ROOT = LOCAL + '\\ai-agents\\mcp-calls'

test('R06 受控 MCP 工具成功時寫一個呼叫紀錄：路徑為 <LOCALAPPDATA>\\ai-agents\\mcp-calls\\<agent_id>\\<tool_use_id>.json，內容含伺服器、狀態與歸屬', async ($, on) => {
  mock.env(on, { LOCALAPPDATA: LOCAL })
  const state = world(on)
  const result = await $.classic.PostToolUse({ session_id: 's1', agent_id: 'agent-1', agent_type: 'general-purpose', tool_name: 'mcp__playwright__browser_click', tool_input: { ref: 'e1', text: 'password-secret' }, tool_response: { content: 'password-secret' }, tool_use_id: 'tu_1', duration_ms: 12, mcp_server: { name: 'playwright', source: 'user' } })
  expect(result.additionalContext ?? []).toEqual([])
  expect([...state.writes.keys()]).toEqual([CALL_ROOT + '\\agent-1\\tu_1.json'])
  const record = JSON.parse(state.writes.get(CALL_ROOT + '\\agent-1\\tu_1.json') ?? '{}')
  expect(record.schema).toBe('ai-agents.mcp-call.v1')
  expect(record.server).toBe('playwright')
  expect(record.status).toBe('completed')
  expect(record.agent_id).toBe('agent-1')
  expect(record.tool_name).toBe('mcp__playwright__browser_click')
  expect(state.writes.get(CALL_ROOT + '\\agent-1\\tu_1.json')).not.toContain('password')
})

test('R07 受控 MCP 工具失敗時（PostToolUseFailure）寫 failed 紀錄並帶 is_interrupt；主執行緒的呼叫寫入 _main 目錄；flaui-mcp 同樣受控', async ($, on) => {
  mock.env(on, { LOCALAPPDATA: LOCAL })
  const state = world(on)
  await $.classic.PostToolUseFailure({ session_id: 's1', tool_name: 'mcp__flaui-mcp__windows_click', tool_input: { ref: 'x' }, error: 'boom', tool_use_id: 'tu_2', is_interrupt: false })
  const record = JSON.parse(state.writes.get(CALL_ROOT + '\\_main\\tu_2.json') ?? '{}')
  expect(record.status).toBe('failed')
  expect(record.is_interrupt).toBe(false)
  expect(record.agent_id).toBe(null)
  expect(record.server).toBe('flaui-mcp')
})

test('R08 非受控伺服器與工具、agent_id 或 tool_use_id 含路徑字元時不寫入', async ($, on) => {
  mock.env(on, { LOCALAPPDATA: LOCAL })
  const state = world(on)
  await $.classic.PostToolUse({ session_id: 's1', agent_id: 'agent-1', tool_name: 'mcp__other__tool', tool_input: {}, tool_response: {}, tool_use_id: 'tu_3' })
  await $.classic.PostToolUse({ session_id: 's1', tool_name: 'Bash', tool_input: {}, tool_response: {}, tool_use_id: 'tu_4' })
  await $.classic.PostToolUse({ session_id: 's1', agent_id: '..\\evil', tool_name: 'mcp__playwright__browser_click', tool_input: {}, tool_response: {}, tool_use_id: 'tu_5' })
  await $.classic.PostToolUse({ session_id: 's1', agent_id: 'agent-1', tool_name: 'mcp__playwright__browser_click', tool_input: {}, tool_response: {}, tool_use_id: '../tu_6' })
  expect(state.writes.size).toBe(0)
})

test('R09 沒有 LOCALAPPDATA 時不寫入，hook 不改變工具結果', async ($, on) => {
  mock.env(on, {})
  const state = world(on)
  const result = await $.classic.PostToolUse({ session_id: 's1', agent_id: 'agent-1', tool_name: 'mcp__playwright__browser_type', tool_input: { text: 'password-secret' }, tool_response: {}, tool_use_id: 'tu_7' })
  expect(result.additionalContext ?? []).toEqual([])
  expect(state.writes.size).toBe(0)
})
