import { test, expect } from 'claude-code/testing'
import { normalizePath, isUnder, filterSessions, mapSessionToLine, parseScriptOutput, parseSessions, buildSnapshot, errorSnapshot, normalizeCollapsed, toggleBlock, dedupeLines, roundPercent, quotaTone, quotaDotTone, quotaBarSvg, quotaBarText } from '../hooks/lib'
import type { Document } from '../hooks/lib'
import { toWindowsPath, parseWorktreeList, splitRoots, defaultWorkRoots, coversPath, buildWorkRootArgument, buildForceWorkRootArgument, resolveCurrentRepo, orderWorkRoots, currentLabel, remainingBudgetMs, GIT_TIMEOUT_MS, SCRIPT_BUDGET_MS } from '../hooks/lib'
import type { CurrentRepo } from '../hooks/lib'

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

const profile = 'C:\\Users\\X'
const defaults = defaultWorkRoots(profile).join(';')
const other: CurrentRepo = { name: 'Other', isGit: true, roots: ['D:\\Work\\Other', 'D:\\Work\\Other.wt\\feat'], forced: ['D:\\Work\\Other', 'D:\\Work\\Other.wt\\feat'] }
const withRoots = (roots: string[]): CurrentRepo => ({ ...other, roots })
test('P4-a1 paths', () => {
  expect(toWindowsPath(' C:/a/b/ ')).toBe('C:\\a\\b')
  expect(toWindowsPath('C:/')).toBe('C:\\')
  expect(toWindowsPath('//server/share/x')).toBe('\\\\server\\share\\x')
})
test('P4-a2 worktree porcelain', () => {
  expect(parseWorktreeList('worktree D:/Main\nHEAD a\nbranch refs/heads/main\n\nworktree D:/one\ndetached\n\nworktree D:/two\nlocked reason')).toEqual([{ path: 'D:\\Main', isBare: false }, { path: 'D:\\one', isBare: false }, { path: 'D:\\two', isBare: false }])
})
test('P4-a3 invalid, bare, Unicode and CRLF', () => {
  const value = 'worktree D:/中文 空白\nbare\nworktree \nworktree relative/path'
  expect(parseWorktreeList(value)).toEqual([{ path: 'D:\\中文 空白', isBare: true }])
  expect(parseWorktreeList(value.replace(/\n/g, '\r\n'))).toEqual(parseWorktreeList(value))
  expect(parseWorktreeList('')).toEqual([])
})
test('P4-b1 split', () => {
  expect(splitRoots('a; b ;;c')).toEqual(['a', 'b', 'c'])
  for (const value of ['', '  ', undefined]) expect(splitRoots(value)).toEqual([])
})
test('P4-b2 defaults', () => {
  expect(defaultWorkRoots(profile)).toEqual([profile + '\\.ai-agents', profile + '\\.ai-agents.wt\\*', profile + '\\.ai-agents\\.claude\\worktrees\\*', 'D:\\Programming\\Projects\\.claude-worktrees\\.ai-agents\\*'])
  expect(defaultWorkRoots(profile + '\\')).toEqual(defaultWorkRoots(profile))
})
test('P4-c1 exact and direct children', () => {
  expect(coversPath('D:/FOO/', 'd:\\foo')).toBe(true)
  expect(coversPath(profile + '\\.ai-agents.wt\\*', 'c:/users/x/.AI-AGENTS.wt/foo')).toBe(true)
  expect(coversPath('C:\\*', 'C:\\foo')).toBe(true)
})
test('P4-c2 wildcard boundaries', () => {
  const entry = profile + '\\.ai-agents.wt\\*'
  for (const path of [profile + '\\.ai-agents.wt\\foo\\bar', profile + '\\.ai-agents.wt2\\foo']) expect(coversPath(entry, path)).toBe(false)
  expect(coversPath('X:\\*\\y', 'X:\\a\\y')).toBe(false)
  expect(coversPath('X:\\a*', 'X:\\abc')).toBe(false)
  expect(coversPath('X:\\a*', 'x:\\A*')).toBe(true)
})
test('P4-d1 default base', () => expect(buildWorkRootArgument('', profile, other)).toBe(defaults + ';' + other.roots.join(';')))
test('P4-d2 configured base', () => expect(buildWorkRootArgument('D:\\a;D:\\b', profile, other)).toBe('D:\\a;D:\\b;' + other.roots.join(';')))
test('P4-d3 deduplication', () => expect(buildWorkRootArgument('D:/work/other/', profile, withRoots([...other.roots, 'd:/WORK/other.wt/feat/']))).toBe('D:/work/other/;D:\\Work\\Other.wt\\feat'))
test('P4-d4 covered defaults', () => expect(buildWorkRootArgument('', profile, withRoots([profile + '\\.ai-agents', profile + '\\.ai-agents.wt\\foo', profile + '\\.ai-agents\\.claude\\worktrees\\bar']))).toBe(null))
test('P4-d5 uncovered children', () => expect(buildWorkRootArgument('', profile, withRoots([profile + '\\.ai-agents.wt\\foo\\bar', profile + '\\.ai-agents.wt2\\foo']))).toBe(defaults + ';' + profile + '\\.ai-agents.wt\\foo\\bar;' + profile + '\\.ai-agents.wt2\\foo'))
test('P4-d6 absent current', () => {
  expect(buildWorkRootArgument('', profile, null)).toBe(null)
  expect(buildWorkRootArgument(' D:\\a ; D:\\b ', profile, null)).toBe('D:\\a ; D:\\b')
  expect(buildWorkRootArgument(' D:\\a ; D:\\b ', profile, withRoots([]))).toBe('D:\\a ; D:\\b')
})
test('P4-d7 unavailable defaults', () => {
  expect(buildWorkRootArgument('', null, other)).toBe(null)
  expect(buildWorkRootArgument('D:\\a', null, other)).toBe('D:\\a;' + other.roots.join(';'))
})
test('P4-d8 non Git', () => expect(buildWorkRootArgument('', profile, { name: 'Notes', isGit: false, roots: ['E:\\Temp\\Notes'], forced: ['E:\\Temp\\Notes'] })).toBe(defaults + ';E:\\Temp\\Notes'))
test('P4-d9 special characters', () => expect(buildWorkRootArgument('D:\\a', profile, withRoots(['D:\\x;y', 'D:\\Work\\a[1]', 'd:\\work\\A[1]']))).toBe('D:\\a;D:\\Work\\a`[1`]'))
test('P4-d10 extra limit', () => expect(buildWorkRootArgument('D:\\a', profile, withRoots(Array.from({ length: 70 }, (_, i) => `D:\\r${i}`)))?.split(';').length).toBe(65))
test('P4-j1 forced paths', () => {
  expect(buildForceWorkRootArgument(other)).toBe(other.forced.join(';'))
  expect(buildForceWorkRootArgument({ ...other, forced: [other.forced[0]] })).toBe(other.forced[0])
})
test('P4-j2 forced special and duplicate', () => expect(buildForceWorkRootArgument({ ...other, forced: ['D:\\a[1]', 'd:\\A[1]', 'D:\\x;y'] })).toBe('D:\\a[1]'))
test('P4-j3 no forced paths', () => {
  expect(buildForceWorkRootArgument(null)).toBe(null)
  expect(buildForceWorkRootArgument({ ...other, forced: [] })).toBe(null)
  expect(buildForceWorkRootArgument({ ...other, forced: ['D:\\x;y'] })).toBe(null)
})
test('P4-j4 forced covered path', () => expect(buildForceWorkRootArgument({ ...other, forced: [profile + '\\.ai-agents.wt\\foo'] })).toBe(profile + '\\.ai-agents.wt\\foo'))
const entries = [{ path: 'D:\\Work\\Other', isBare: false }, { path: 'D:\\Work\\Other.wt\\feat', isBare: false }, { path: 'D:\\Work\\Other.wt\\two', isBare: false }]
test('P4-e1 main repo', () => expect(resolveCurrentRepo(entries[0].path, { kind: 'repo', topLevel: entries[0].path, worktrees: entries })).toEqual({ name: 'Other', isGit: true, roots: entries.map(x => x.path), forced: [entries[0].path] }))
test('P4-e2 linked repo', () => expect(resolveCurrentRepo(entries[1].path, { kind: 'repo', topLevel: entries[1].path, worktrees: entries })).toEqual({ name: 'Other', isGit: true, roots: entries.map(x => x.path), forced: [entries[0].path, entries[1].path] }))
test('P4-e3 missing and bare worktrees', () => {
  for (const trees of [null, []]) expect(resolveCurrentRepo(entries[1].path, { kind: 'repo', topLevel: entries[1].path, worktrees: trees })).toEqual({ name: 'feat', isGit: true, roots: [entries[1].path], forced: [entries[1].path] })
  expect(resolveCurrentRepo(entries[1].path, { kind: 'repo', topLevel: entries[1].path, worktrees: [{ ...entries[0], isBare: true }] })).toEqual({ name: 'Other', isGit: true, roots: [entries[1].path], forced: [entries[1].path] })
  expect(resolveCurrentRepo(entries[1].path, { kind: 'repo', topLevel: entries[1].path, worktrees: [entries[0]] })?.roots).toEqual([entries[0].path, entries[1].path])
})
test('P4-e4 non Git', () => {
  expect(resolveCurrentRepo('E:/Temp/Notes/', { kind: 'notRepo' })).toEqual({ name: 'Notes', isGit: false, roots: ['E:\\Temp\\Notes'], forced: ['E:\\Temp\\Notes'] })
  expect(resolveCurrentRepo('D:\\', { kind: 'notRepo' })?.name).toBe('D:\\')
})
test('P4-e5 invalid probes', () => {
  for (const cwd of [null, '', 'relative']) expect(resolveCurrentRepo(cwd, { kind: 'notRepo' })).toBe(null)
  expect(resolveCurrentRepo('D:\\x', { kind: 'failed' })).toBe(null)
  expect(resolveCurrentRepo('D:\\x', { kind: 'repo', topLevel: 'relative', worktrees: [] })).toBe(null)
})
test('P4-f1 ordering', () => {
  const rows = [{ Path: 'A' }, { Path: entries[1].path }, { Path: 'B' }, { Path: entries[0].path }]
  expect(orderWorkRoots(rows, other).map(x => x.Path)).toEqual([entries[0].path, entries[1].path, 'A', 'B'])
  expect(rows[0].Path).toBe('A')
})
test('P4-f2 case and error', () => expect(orderWorkRoots([{ Path: 'A' }, { Path: 'd:/work/other', Error: 'x' }], other)[0].Path).toBe('d:/work/other'))
test('P4-f3 no match', () => {
  const rows = [{ Path: 'A' }, { Path: 'B' }]
  expect(orderWorkRoots(rows, null)).toEqual(rows)
  expect(orderWorkRoots(rows, other)).toEqual(rows)
  expect(rows).toEqual([{ Path: 'A' }, { Path: 'B' }])
})
test('P4-g1 labels', () => {
  expect(currentLabel(other)).toBe('目前：Other')
  expect(currentLabel({ ...other, name: 'Notes', isGit: false })).toBe('目前：Notes（非 Git）')
  expect(currentLabel(null)).toBe(null)
})
test('P4-g2 snapshot current', () => {
  const result = buildSnapshot({ ok: true, value: { ...doc, workRoots: [{ Path: root }, { Path: entries[0].path }] } }, { ok: true, value: [] }, new Date(), other)
  expect(result.workRoots.rows[0].name).toBe('Other')
  expect(result.currentLabel).toBe('目前：Other')
  expect(buildSnapshot({ ok: false, error: 'x' }, { ok: true, value: [] }, new Date(), other).currentLabel).toBe('目前：Other')
  expect(errorSnapshot('x').currentLabel).toBe(null)
})
test('P4-g3 old call', () => {
  const result = buildSnapshot({ ok: true, value: doc }, { ok: true, value: [] }, new Date())
  expect(result.currentLabel).toBe(null)
  expect(result.workRoots.rows.map(item => item.name)).toEqual(['.ai-agents', 'worktree'])
})
test('P4-h budget', () => expect([0, 6000, 39500, 90000, -5].map(x => remainingBudgetMs(40000, x))).toEqual([40000, 34000, 1000, 1000, 40000]))
test('P4-i budget total', () => expect(GIT_TIMEOUT_MS * 2 + remainingBudgetMs(SCRIPT_BUDGET_MS, GIT_TIMEOUT_MS * 2)).toBe(SCRIPT_BUDGET_MS))
