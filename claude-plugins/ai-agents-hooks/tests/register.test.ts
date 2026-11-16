// 註冊層的測試：事件與 matcher 的接線、資料目錄的推得方式與回傳形狀。判定邏輯本身由 scripts/tests 的 PowerShell 測試經 tests/run-hook.ts 驗證。
import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const PROFILE = 'C:\\Users\\tester'
const DATA = PROFILE + '\\.claude\\plugins\\data\\ai-agents-hooks-ai-agents-local\\turn-guard'
const DOC = 'C:\\repo\\docs\\a.md'

type World = { files: Map<string, string>; logs: string[]; gitCalls: string[][]; failWrites: boolean }

// 以記憶體模擬 $.fs、$.process.run 與 $.ui.log；目錄只認 C:\repo\docs。
function world(on: On, gitExitCode = 1): World {
  const state: World = { files: new Map(), logs: [], gitCalls: [], failWrites: false }
  on('fs.exists', (_$, e) => ({ value: state.files.has(e.path) }))
  on('fs.read', (_$, e) => {
    const text = state.files.get(e.path)
    if (text === undefined) return { deny: 'missing' }
    return { value: e.as === 'bytes' ? { base64: btoa(unescape(encodeURIComponent(text))) } : text }
  })
  on('fs.write', (_$, e) => {
    if (state.failWrites) return { deny: 'write failed' }
    state.files.set(e.path, e.text)
    return { value: undefined }
  })
  on('fs.list', (_$, e) => ({
    value: [...state.files]
      .filter(([path]) => directoryOf(path) === e.path)
      .map(([path, text]) => ({ name: nameOf(path), kind: 'file' as const, size: new TextEncoder().encode(text).length, mtimeMs: 0, isLink: false }))
  }))
  on('fs.stat', (_$, e) => e.path === 'C:\\repo\\docs' ? { value: { kind: 'dir', size: 0, mtimeMs: 0, isLink: false } } : { deny: 'missing' })
  on('process.run', (_$, e) => { state.gitCalls.push([...e.argv]); return { value: { exitCode: gitExitCode, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } })
  on('ui.log', (_$, e) => { state.logs.push(e.text); return { value: undefined } })
  on('tool.call', () => ({ result: {} }))
  // 引擎的 settings hook 不存在，classic 事件由測試回答空結果。
  on('classic.UserPromptSubmit', () => ({}))
  on('classic.PostToolUse', () => ({}))
  on('classic.PostToolUseFailure', () => ({}))
  on('classic.Stop', () => ({}))
  return state
}

function directoryOf(path: string): string {
  return path.slice(0, path.lastIndexOf('\\'))
}

function nameOf(path: string): string {
  return path.slice(path.lastIndexOf('\\') + 1)
}

// 某個 session 在資料目錄中的全部檔：<session>.jsonl、<session>.<實例>.jsonl 與輪替段。
function sessionFiles(state: World, session: string, directory = DATA): string[] {
  const pattern = new RegExp(`^${session}(\\.[A-Za-z0-9]+(\\.[0-9]+)?)?\\.jsonl$`)
  return [...state.files.keys()].filter(path => directoryOf(path) === directory && pattern.test(nameOf(path)))
}

// 合併全部檔的紀錄並依 ts 排序。
function rows(state: World, session: string, directory = DATA): Record<string, unknown>[] {
  const all = sessionFiles(state, session, directory).flatMap(path => (state.files.get(path) ?? '').split('\n').filter(line => line !== '').map(line => JSON.parse(line) as Record<string, unknown>))
  return all.sort((left, right) => String(left['ts'] ?? '').localeCompare(String(right['ts'] ?? '')))
}

test('R01 資料目錄由 USERPROFILE 推得，四個 turn-guard 事件各寫一筆', async ($, on) => {
  mock.env(on, { USERPROFILE: PROFILE })
  const state = world(on)
  // 模組狀態在同一個測試檔的各測試之間保留，因此每個測試使用不同的 session。
  await $.classic.UserPromptSubmit({ session_id: 'r01', prompt: 'p' })
  await $.classic.PostToolUse({ session_id: 'r01', tool_name: 'Read', tool_input: { file_path: 'x' }, tool_response: {}, tool_use_id: 't1' })
  await $.classic.PostToolUseFailure({ session_id: 'r01', tool_name: 'Bash', tool_input: { command: 'bad' }, tool_use_id: 't2', error: 'boom' })
  await $.classic.Stop({ session_id: 'r01', stop_hook_active: false })
  expect(rows(state, 'r01').map(row => row['event'])).toEqual(['UserPromptSubmit', 'PostToolUse', 'PostToolUseFailure', 'Stop'])
  // 本實例只寫一個名稱含實例識別的檔，不寫命令型 hook 時期的 <session>.jsonl。
  const files = sessionFiles(state, 'r01')
  expect(files.length).toBe(1)
  expect(nameOf(files[0] ?? '')).toMatch(/^r01\.[0-9a-f]{12}\.jsonl$/)
})

test('R02 CLAUDE_PLUGIN_DATA 有設定時優先採用', async ($, on) => {
  mock.env(on, { CLAUDE_PLUGIN_DATA: 'D:\\data', USERPROFILE: PROFILE })
  const state = world(on)
  await $.classic.UserPromptSubmit({ session_id: 'r02', prompt: 'p' })
  expect([...state.files.keys()].every(path => directoryOf(path) === 'D:\\data\\turn-guard')).toBe(true)
  expect(sessionFiles(state, 'r02', 'D:\\data\\turn-guard').length).toBe(1)
})

test('R03 取不到資料目錄時不寫任何檔案', async ($, on) => {
  mock.env(on, {})
  const state = world(on)
  await $.classic.UserPromptSubmit({ session_id: 's1', prompt: 'p' })
  expect(state.files.size).toBe(0)
})

test('R04 matcher 以外的工具不寫紀錄', async ($, on) => {
  mock.env(on, { USERPROFILE: PROFILE })
  const state = world(on)
  await $.classic.PostToolUse({ session_id: 's1', tool_name: 'mcp__ccd_session_mgmt__list_sessions', tool_input: {}, tool_response: {}, tool_use_id: 't1' })
  await $.classic.PostToolUseFailure({ session_id: 's1', tool_name: 'WebFetch', tool_input: {}, tool_use_id: 't2', error: 'boom' })
  expect(state.files.size).toBe(0)
})

test('R05 同一失敗第 2 次以 additionalContext 回傳提醒，第 1、3 次不回傳', async ($, on) => {
  mock.env(on, { USERPROFILE: PROFILE })
  world(on)
  const failure = { session_id: 'r05', tool_name: 'Bash', tool_input: { command: 'bad' }, tool_use_id: 't', error: 'boom' }
  await $.classic.UserPromptSubmit({ session_id: 'r05', prompt: 'p' })
  const first = await $.classic.PostToolUseFailure(failure)
  const second = await $.classic.PostToolUseFailure(failure)
  const third = await $.classic.PostToolUseFailure(failure)
  expect(first.additionalContext ?? []).toEqual([])
  expect(second.additionalContext).toEqual(['同一失敗已在本 turn 重複 2 次：Bash|bad|boom。下一次嘗試前先說明為什麼這次會成功；說不出來就停下並回報。'])
  expect(third.additionalContext ?? []).toEqual([])
})

test('R06 Bash 與 PowerShell 直接呼叫 powershell.exe 時拒絕，pwsh 放行', async ($, on) => {
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

test('R07 AI_AGENTS_ALLOW_POWERSHELL51=1 時放行', async ($, on) => {
  mock.env(on, { AI_AGENTS_ALLOW_POWERSHELL51: '1' })
  world(on)
  const result = await $.tool.call({ tool: 'Bash', command: 'powershell.exe -File a.ps1' })
  expect(result.isError ?? false).toBe(false)
})

test('R08 受控 .md 寫入含本機路徑時以 additionalContext 提醒，並呼叫 git check-ignore', async ($, on) => {
  mock.env(on, {})
  const state = world(on, 1)
  state.files.set(DOC, 'x')
  const result = await $.classic.PostToolUse({ session_id: 's1', tool_name: 'Write', tool_input: { file_path: DOC, content: '第一行\n另見 D:\\Work\\data.csv' }, tool_response: {}, tool_use_id: 't' })
  expect(result.additionalContext?.length).toBe(1)
  expect(result.additionalContext?.[0]).toContain('doc-placement: ' + DOC + ' 本次寫入的內容含本機磁碟機絕對路徑')
  expect(result.additionalContext?.[0]).toContain('line 2: D:\\Work\\data.csv')
  expect(state.gitCalls).toEqual([['git', '-C', 'C:\\repo\\docs', 'check-ignore', '-q', '--', DOC]])
})

test('R09 git check-ignore 不是 1 時不提醒', async ($, on) => {
  mock.env(on, {})
  world(on, 0)
  const result = await $.classic.PostToolUse({ session_id: 's1', tool_name: 'Edit', tool_input: { file_path: DOC, old_string: 'a', new_string: 'E:\\Work\\repo' }, tool_response: {}, tool_use_id: 't' })
  expect(result.additionalContext ?? []).toEqual([])
})

test('R10 post-edit-write 的訊息只寫入 debug log，不送給模型', async ($, on) => {
  mock.env(on, {})
  const state = world(on)
  state.files.set('C:\\repo\\docs\\b.md', '\uFEFF這裡——轉折\n')
  const result = await $.classic.PostToolUse({ session_id: 's1', tool_name: 'Write', tool_input: { file_path: 'C:\\repo\\docs\\b.md', content: '這裡——轉折\n' }, tool_response: {}, tool_use_id: 't' })
  expect(result.additionalContext ?? []).toEqual([])
  expect(state.logs[0]).toBe('[post-edit-write hook] C:\\repo\\docs\\b.md was written. Please run check-markdown skill to verify Markdown formatting.')
  expect(state.logs.some(line => line.includes('forbidden full-width dash'))).toBe(true)
  expect(state.logs.some(line => line.includes('has unexpected UTF-8 BOM'))).toBe(true)
})

test('R11 其他實例與命令型 hook 時期的檔納入計數，且不被改寫', async ($, on) => {
  mock.env(on, { USERPROFILE: PROFILE })
  const state = world(on)
  const legacy = DATA + '\\r11.jsonl'
  const other = DATA + '\\r11.aaaaaaaaaaaa.jsonl'
  const failureRow = (ts: string): string => JSON.stringify({ v: 1, ts, session_id: 'r11', event: 'PostToolUseFailure', turn: 1, agent_id: null, class: 'other', fingerprint: { hash: 'h', text: 't', repeat: 1 } })
  const legacyText = JSON.stringify({ v: 1, ts: '2026-01-01T00:00:00.000Z', session_id: 'r11', event: 'UserPromptSubmit', turn: 1 }) + '\n'
  const otherText = failureRow('2026-01-01T00:00:01.000Z') + '\n'
  state.files.set(legacy, legacyText)
  state.files.set(other, otherText)
  await $.classic.Stop({ session_id: 'r11', stop_hook_active: false })
  const stop = rows(state, 'r11').at(-1) ?? {}
  expect(stop['turn']).toBe(1)
  expect((stop['counts'] as Record<string, number>)['failure']).toBe(1)
  expect(state.files.get(legacy)).toBe(legacyText)
  expect(state.files.get(other)).toBe(otherText)
  // 其他實例之後追加的紀錄，下一個事件依大小變化重新讀取。
  state.files.set(other, otherText + failureRow('2026-01-01T00:00:02.000Z') + '\n')
  await $.classic.Stop({ session_id: 'r11', stop_hook_active: false })
  expect(((rows(state, 'r11').at(-1) ?? {})['counts'] as Record<string, number>)['failure']).toBe(2)
})

test('R12 資料目錄寫不進去時仍照常計數與提醒，恢復後寫入失敗的列一併落檔', async ($, on) => {
  mock.env(on, { USERPROFILE: PROFILE })
  const state = world(on)
  const failure = { session_id: 'r12', tool_name: 'Bash', tool_input: { command: 'bad' }, tool_use_id: 't', error: 'boom' }
  await $.classic.UserPromptSubmit({ session_id: 'r12', prompt: 'p' })
  state.failWrites = true
  const lost = await $.classic.PostToolUseFailure(failure)
  state.failWrites = false
  const first = await $.classic.PostToolUseFailure(failure)
  const second = await $.classic.PostToolUseFailure(failure)
  // 寫入失敗的那一筆仍計入：恢復後的第一次失敗即為第 2 次，提醒一次；第 3 次不再提醒。
  expect(lost.additionalContext ?? []).toEqual([])
  expect(first.additionalContext?.length).toBe(1)
  expect(second.additionalContext ?? []).toEqual([])
  // 寫入恢復後，檔案含全部 4 個事件。
  expect(rows(state, 'r12').map(row => row['event'])).toEqual(['UserPromptSubmit', 'PostToolUseFailure', 'PostToolUseFailure', 'PostToolUseFailure'])
  expect(rows(state, 'r12').map(row => (row['fingerprint'] as Record<string, unknown> | undefined)?.['repeat'] ?? null)).toEqual([null, 1, 2, 3])
})

test('R13 連續數次寫入失敗後恢復，期間的列全部落檔', async ($, on) => {
  mock.env(on, { USERPROFILE: PROFILE })
  const state = world(on)
  await $.classic.UserPromptSubmit({ session_id: 'r13', prompt: 'p' })
  state.failWrites = true
  for (let index = 0; index < 3; index++) {
    await $.classic.PostToolUse({ session_id: 'r13', tool_name: 'Read', tool_input: { file_path: 'x' + index }, tool_response: {}, tool_use_id: 't' + index })
  }
  expect(rows(state, 'r13').map(row => row['event'])).toEqual(['UserPromptSubmit'])
  state.failWrites = false
  await $.classic.Stop({ session_id: 'r13', stop_hook_active: false })
  const all = rows(state, 'r13')
  expect(all.map(row => row['event'])).toEqual(['UserPromptSubmit', 'PostToolUse', 'PostToolUse', 'PostToolUse', 'Stop'])
  expect(((all.at(-1) ?? {})['counts'] as Record<string, number>)['read']).toBe(3)
})

test('R14 session.end 釋放狀態後再收到同一 session 的事件，從磁碟接續計數且不覆寫已落檔的內容', async ($, on) => {
  mock.env(on, { USERPROFILE: PROFILE })
  const state = world(on)
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
  const failure = { session_id: 'r14', tool_name: 'Bash', tool_input: { command: 'bad' }, tool_use_id: 't', error: 'boom' }
  await $.classic.UserPromptSubmit({ session_id: 'r14', prompt: 'p' })
  await $.classic.PostToolUseFailure(failure)
  const before = sessionFiles(state, 'r14')
  const beforeText = state.files.get(before[0] ?? '')
  await $.session.end({ reason: 'clear', sessionId: 'r14', resume: { id: 'r14' } })
  const second = await $.classic.PostToolUseFailure(failure)
  expect(second.additionalContext?.length).toBe(1)
  expect(state.files.get(before[0] ?? '')).toBe(beforeText)
  const after = sessionFiles(state, 'r14')
  expect(after.length).toBe(2)
  expect(after.some(path => /\.[0-9a-f]{12}\.1\.jsonl$/.test(path))).toBe(true)
  expect(rows(state, 'r14').map(row => row['turn'])).toEqual([1, 1, 1])
})

test('R15 保留的 session 超過上限時釋放最久未使用者，該 session 之後的事件從磁碟接續計數', async ($, on) => {
  mock.env(on, { USERPROFILE: PROFILE })
  const state = world(on)
  const failure = (session: string) => ({ session_id: session, tool_name: 'Bash', tool_input: { command: 'bad' }, tool_use_id: 't', error: 'boom' })
  for (let index = 0; index < 20; index++) {
    await $.classic.UserPromptSubmit({ session_id: 'r15s' + index, prompt: 'p' })
    await $.classic.PostToolUseFailure(failure('r15s' + index))
  }
  const first = sessionFiles(state, 'r15s0')
  const firstText = state.files.get(first[0] ?? '')
  const again = await $.classic.PostToolUseFailure(failure('r15s0'))
  expect(again.additionalContext?.length).toBe(1)
  expect(state.files.get(first[0] ?? '')).toBe(firstText)
  expect(sessionFiles(state, 'r15s0').length).toBe(2)
})
