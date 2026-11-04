import { test, expect } from 'claude-code/testing'
import { normalizePath, isUnder, filterSessions, mapSessionToLine, parseScriptOutput, parseSessions, buildSnapshot, errorSnapshot } from '../hooks/lib'
import type { Document } from '../hooks/lib'

const root = 'C:\\Users\\X\\.ai-agents'
const linked = root + '\\worktree'
const doc: Document = {
  scannedRoots: [root, linked],
  workRoots: [{ Path: root, IsLinkedWorktree: false }, { Path: linked, IsLinkedWorktree: true }],
  lines: [{ LineSlug: 'line-one', WorkRoot: linked, CheckpointType: 'design-accepted', NextStepSummary: '審查。' }],
  quota: [{ Name: 'account', State: 'unknown', Error: 'unavailable' }],
  warnings: []
}

test('P2-a normalizePath', () => {
  expect(normalizePath('C:/Users/X/.ai-agents/')).toBe('c:\\users\\x\\.ai-agents')
})
test('P2-b directory boundary', () => {
  expect(isUnder('C:\\Users\\X\\.ai-agents.wt\\a', root)).toBe(false)
})
test('P2-c filter cwd', () => {
  expect(filterSessions([{ cwd: 'D:\\Programming\\Projects\\YunXin' }, {}, { cwd: 7 }, { cwd: root }], doc.scannedRoots).length).toBe(1)
})
test('P2-d named line', () => {
  expect(mapSessionToLine({ cwd: root, name: 'line-one' }, doc)).toBe('line-one')
})
test('P2-e unique linked line', () => {
  expect(mapSessionToLine({ cwd: linked + '\\child' }, doc)).toBe('line-one')
})
test('P2-f ambiguous and main worktree', () => {
  expect(mapSessionToLine({ cwd: root, name: 'cost-reduction' }, doc)).toBe(null)
  expect(mapSessionToLine({ cwd: linked }, { ...doc, lines: [...doc.lines, { LineSlug: 'other', WorkRoot: linked }] })).toBe(null)
})
test('P2-g noisy script JSON', () => {
  expect(parseScriptOutput('noise ' + JSON.stringify(doc)).ok).toBe(true)
  expect(parseScriptOutput('{}').ok).toBe(false)
})
test('P2-h independent errors', () => {
  const scriptError = buildSnapshot({ ok: false, error: 'script' }, { ok: true, value: [] }, new Date())
  expect(scriptError.sessions.errorMessage).toBe('無法判定掃描範圍')
  expect(scriptError.lines.errorMessage).toBe('script')
  const mcpError = buildSnapshot({ ok: true, value: doc }, { ok: false, error: 'mcp' }, new Date())
  expect(mcpError.sessions.errorMessage).toBe('mcp')
  expect(mcpError.lines.rows.length).toBe(1)
  expect(mcpError.workRoots.rows.length).toBe(2)
  expect(mcpError.quota.rows.length).toBe(1)
  expect(parseSessions({ structuredContent: { sessions: [] } }).ok).toBe(true)
})
test('P2-i truncation and limits', () => {
  const sessions = Array.from({ length: 16 }, () => ({ cwd: linked, title: '甲'.repeat(25), isRunning: true }))
  const board = buildSnapshot({ ok: true, value: doc }, { ok: true, value: sessions }, new Date())
  expect(board.sessions.rows[0].text).toBe('● 執行中 ' + '甲'.repeat(24) + '… → line-one')
  expect(board.sessions.hiddenCount).toBe(1)
  expect(board.quota.rows[0].tone).toBe('error')
})

test('F-004 invalid records are skipped independently', () => {
  const value = {
    ...doc,
    lines: [null, {}, { ...doc.lines[0], CheckpointType: 42 }, doc.lines[0]],
    workRoots: [null, { Path: 9 }, { Path: root, DirtyCount: 'bad' }, doc.workRoots[0]],
    quota: [null, { Name: 'bad' }, { Name: 'bad', State: 'ok', PrimaryRemaining: 'bad' }, doc.quota[0]]
  }
  const parsed = parseScriptOutput(JSON.stringify(value))
  expect(parsed.ok).toBe(true)
  if (parsed.ok) {
    expect(parsed.value.lines.length).toBe(1)
    expect(parsed.value.workRoots.length).toBe(1)
    expect(parsed.value.quota.length).toBe(1)
    expect(buildSnapshot(parsed, { ok: true, value: [] }, new Date()).lines.rows.length).toBe(1)
  }
  const failed = errorSnapshot('格式錯誤')
  expect(failed.sessions.errorMessage).toBe('格式錯誤')
  expect(failed.lines.errorMessage).toBe('格式錯誤')
  expect(failed.workRoots.errorMessage).toBe('格式錯誤')
  expect(failed.quota.errorMessage).toBe('格式錯誤')
})

test('T011 warnings do not count as quota rows', () => {
  const empty = buildSnapshot({ ok: true, value: { ...doc, quota: [], warnings: ['警告一', '警告二'] } }, { ok: true, value: [] }, new Date())
  expect(empty.quota.rows.length).toBe(0)
  expect(empty.quota.warning).toBe('警告一 / 警告二')
  const populated = buildSnapshot({ ok: true, value: { ...doc, warnings: ['警告'] } }, { ok: true, value: [] }, new Date())
  expect(populated.quota.rows.length).toBe(1)
  expect(populated.quota.warning).toBe('警告')
})
