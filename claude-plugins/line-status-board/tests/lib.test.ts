import { test, expect } from 'claude-code/testing'
import { normalizePath, isUnder, filterSessions, mapSessionToLine, parseScriptOutput, parseSessions, buildSnapshot, errorSnapshot, normalizeCollapsed, toggleBlock, dedupeLines, roundPercent, quotaTone, quotaDotTone, quotaBarSvg, quotaBarText } from '../hooks/lib'
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
  expect(board.sessions.rows.length).toBe(15)
  expect(board.sessions.rows[0].name).toBe('甲'.repeat(25))
  expect(board.sessions.rows[0].note).toBe('line-one')
  expect(board.sessions.rows[0].dot).toBe('success')
  expect(board.sessions.hiddenCount).toBe(1)
  expect(board.quota.rows[0].tone).toBe('error')
  expect(board.quota.rows[0].dot).toBe('error')
})

test('P3-a collapsed values normalize', () => {
  for (const value of [undefined, null, 'x', {}, []]) expect(normalizeCollapsed(value)).toEqual([])
  expect(normalizeCollapsed(['lines', 'lines', 'bogus', 3, 'quota'])).toEqual(['lines', 'quota'])
})
test('P3-b toggle preserves order and input', () => {
  const value: ('lines' | 'quota')[] = ['lines', 'quota']
  expect(toggleBlock([], 'lines')).toEqual(['lines'])
  expect(toggleBlock(value, 'lines')).toEqual(['quota'])
  expect(toggleBlock(['quota'], 'sessions')).toEqual(['sessions', 'quota'])
  expect(value).toEqual(['lines', 'quota'])
})
test('P3-c1 to c9 deduplication and filtering', () => {
  const old = { LineSlug: 'same', WorkRoot: 'old', CheckpointUpdatedUtc: '2025-01-01' }
  const recent = { ...old, WorkRoot: 'new', CheckpointUpdatedUtc: '2026-01-01' }
  expect(dedupeLines([old, recent])[0].WorkRoot).toBe('new')
  expect(dedupeLines([recent, old])[0].WorkRoot).toBe('new')
  const missing = { ...old, CheckpointUpdatedUtc: null }
  expect(dedupeLines([missing, recent])[0].WorkRoot).toBe('new')
  expect(dedupeLines([recent, missing])[0].WorkRoot).toBe('new')
  expect(dedupeLines([{ ...missing, Error: 'bad' }, { ...missing, WorkRoot: 'ok' }])[0].WorkRoot).toBe('ok')
  expect(dedupeLines([missing, { ...missing, WorkRoot: 'later' }])[0].WorkRoot).toBe('old')
  expect(dedupeLines([{ ...old, CheckpointUpdatedUtc: 'not-a-date' }, recent])[0].WorkRoot).toBe('new')
  expect(dedupeLines([old, { ...old, WorkRoot: 'later' }])[0].WorkRoot).toBe('old')
  expect(dedupeLines([old, { ...old, LineSlug: 'other' }, recent]).map(x => x.LineSlug)).toEqual(['same', 'other'])
  const snapshot = (lines: Document['lines']) => buildSnapshot({ ok: true, value: { ...doc, lines } }, { ok: true, value: [] }, new Date())
  expect(snapshot([old, recent]).lines.rows.length).toBe(1)
  expect(snapshot([old, recent]).lines.rows[0].name).toBe('same')
  const filterOrderCase = [{ ...missing, WorkRoot: root }, { ...missing, WorkRoot: linked, CheckpointType: 'design-accepted' }]
  expect(dedupeLines(filterOrderCase)[0].WorkRoot).toBe(root)
  const filteredFirst = snapshot(filterOrderCase).lines.rows
  expect(filteredFirst.length).toBe(1)
  expect(filteredFirst[0].detail).toBe('設計驗收 ▸ （未載明下一步）')
})
test('P3-d e line fields and errors', () => {
  const lines = [{ ...doc.lines[0], CheckpointUpdatedUtc: '2025-01-02T03:04:00', NextStepSummary: '審查。' }, { LineSlug: 'empty', WorkRoot: linked }, { LineSlug: 'bad', WorkRoot: root, Error: '錯誤' }]
  const rows = buildSnapshot({ ok: true, value: { ...doc, lines } }, { ok: true, value: [] }, new Date()).lines.rows
  expect(rows[0].name).toBe('line-one')
  expect(rows[0].note).toBe('01-02 03:04')
  expect(rows[0].detail).toBe('設計驗收 ▸ 審查。')
  expect(rows.find(x => x.name === 'empty')?.note).toBe('無檢查點')
  expect(rows.find(x => x.name === 'empty')?.detail).toBe(null)
  expect(rows.find(x => x.name === 'bad · 錯誤')?.tone).toBe('error')
  expect(rows.find(x => x.name === 'bad · 錯誤')?.dot).toBe(null)
  const absent = buildSnapshot({ ok: true, value: { ...doc, lines: [{ ...lines[0], NextStepSummary: null }] } }, { ok: true, value: [] }, new Date())
  expect(absent.lines.rows[0].detail).toBe('設計驗收 ▸ （未載明下一步）')
})
test('P3-f g sessions and work roots', () => {
  const workRoots = [{ Path: root, DirtyCount: 0 }, { Path: linked, DirtyCount: 3, Branch: 'main', MainAhead: 1, MainBehind: 0, Upstream: 'origin', UpstreamAhead: 2 }, { Path: root + '\\null' }, { Path: root + '\\bad', Error: 'error' }]
  const board = buildSnapshot({ ok: true, value: { ...doc, workRoots } }, { ok: true, value: [{ cwd: root, name: 'line-one', isRunning: true }, { cwd: root, name: 'other', isRunning: false }] }, new Date())
  expect(board.sessions.rows.map(x => x.dot)).toEqual(['success', 'inactive'])
  expect(board.sessions.rows.map(x => x.note)).toEqual(['line-one', ''])
  expect(board.workRoots.rows.map(x => x.dot)).toEqual(['success', 'warning', 'inactive', 'error'])
  expect(board.workRoots.rows[1].detail).toBe('未 commit 3 · 主分支 +1/-0 · 未 push 2')
  expect(board.workRoots.rows[1].note).toBe('main')
  expect(board.workRoots.rows[0].note).toBe('-')
  expect(board.workRoots.rows[0].detail?.endsWith('無 upstream')).toBe(true)
})
test('P3-h i quota thresholds', () => {
  expect([50, 100, 49, 20, 19, 0, null].map(quotaTone)).toEqual(['success', 'success', 'warning', 'warning', 'error', 'error', 'inactive'])
  expect([49.5, 19.5, 19.4].map(x => quotaTone(roundPercent(x)))).toEqual(['success', 'warning', 'error'])
  expect([null, undefined, NaN, 150, -5].map(roundPercent)).toEqual([null, null, null, 100, 0])
  expect(quotaDotTone(80, 15)).toBe('error')
  expect(quotaDotTone(null, null)).toBe('inactive')
})
test('P3-j quota row', () => {
  const quota = [{ Name: 'a', State: 'ok', PrimaryRemaining: 78, SecondaryRemaining: 42, PrimaryResetsAtLocal: '2025-01-02T03:04:00', SecondaryResetsAtLocal: '2025-01-03T03:04:00' }, { Name: 'b', State: 'ok' }]
  const rows = buildSnapshot({ ok: true, value: { ...doc, quota } }, { ok: true, value: [] }, new Date()).quota.rows
  expect(rows[0].bars.map(x => x.label)).toEqual(['5 小時', '週'])
  expect(rows[0].bars[0].text).toBe('78%')
  expect(rows[0].bars[1].text.includes(' · ')).toBe(true)
  expect(rows[0].bars[1].text.includes('重置')).toBe(true)
  expect(rows[0].note.endsWith('重置')).toBe(true)
  expect(rows[1].bars[0].percent).toBe(null)
  expect(rows[1].bars[0].text).toBe('-')
})
test('P3-k bars', () => {
  const svg = quotaBarSvg(50, 'success')
  expect(svg.includes('width="48"')).toBe(true)
  expect((svg.match(/<rect/g) || []).length).toBe(2)
  expect(quotaBarSvg(100, 'success').includes('width="96"')).toBe(true)
  expect(quotaBarSvg(150, 'success').includes('width="96"')).toBe(true)
  expect((quotaBarSvg(0, 'error').match(/<rect/g) || []).length).toBe(1)
  expect((quotaBarSvg(null, 'inactive').match(/<rect/g) || []).length).toBe(1)
  expect(svg.startsWith('<svg')).toBe(true)
  expect(svg.endsWith('</svg>')).toBe(true)
  expect(svg.includes('xmlns')).toBe(true)
  expect(quotaBarText(50)).toBe('█████░░░░░')
  expect(quotaBarText(null)).toBe('░'.repeat(10))
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
