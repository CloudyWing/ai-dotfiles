// 註冊層的測試：事件與 matcher 的接線與回傳形狀。判定邏輯本身由 scripts/tests 的 PowerShell 測試經 tests/run-hook.ts 驗證。
import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const DOC = 'C:\\repo\\docs\\a.md'

type World = { files: Map<string, string>; logs: string[]; gitCalls: string[][] }

// 以記憶體模擬 $.fs、$.process.run 與 $.ui.log；目錄只認 C:\repo\docs。
function world(on: On, gitExitCode = 1): World {
  const state: World = { files: new Map(), logs: [], gitCalls: [] }
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
