import { test, expect } from 'claude-code/testing'
import { normalizePath, isUnder, filterSessions, mapSessionToLine, parseScriptOutput, parseSessions, buildSnapshot, errorSnapshot, normalizeCollapsed, toggleBlock, dedupeLines, roundPercent, quotaTone, quotaDotTone, quotaBarSvg, quotaBarText } from '../hooks/lib'
import type { Document } from '../hooks/lib'
import { toWindowsPath, parseWorktreeList, splitRoots, defaultWorkRoots, coversPath, buildWorkRootArgument, buildForceWorkRootArgument, resolveCurrentRepo, orderWorkRoots, currentLabel, remainingBudgetMs, GIT_TIMEOUT_MS, SCRIPT_BUDGET_MS } from '../hooks/lib'
import type { CurrentRepo } from '../hooks/lib'
import { isDispatchWorktree, toEpochMs, relativeTime, isStalled, sortSessionsByActivity, checkpointLabel, sessionTone, lineTone, rootTone, numberTone, rootDetail, quotaDetail, segmentsText, normalizeExpanded, toggleExpanded, iconSvg, ICON_ALT, DIVIDER_SVG, dividerText, QUOTA_OK_FROM, QUOTA_WARN_FROM, STALE_MS } from '../hooks/lib'
import { BLOCK_IDS, BLOCK_ORDER, BLOCK_TITLES, countText, blockCounts, blockTitleText, stalledToggleText } from '../hooks/lib'
import { DIM_AFTER_MS, lineNameTone, isLanded, parseFeatureBranches, lineRightText, displayWidth, canShowNote } from '../hooks/lib'
import { loginCommand, loginDisplayMode, quotaErrorRow, scopedSessions, lowestPrimary, statusText } from '../hooks/lib'
import { finishedSessions, finishedToastText, normalizeAlertSignature, quotaAlert, QUOTA_ALERT_BELOW, QUOTA_ALERT_KEY, windowLabel } from '../hooks/lib'
import { SESSION_OPEN_MODE, sessionLink, sessionOpenTarget } from '../hooks/lib'
import type { Quota } from '../hooks/lib'
import { CLEANUP_DELETE_TIMEOUT_MS, CLEANUP_LIST_LIMIT, CLEANUP_LIST_TIMEOUT_MS, CLEANUP_REVIEW_LIMIT, cleanupItemDetail, cleanupItemName, formatBytes, groupCleanupItems, parseCleanupOutput } from '../hooks/lib'
import { CLEANUP_LINE_LIMIT, closableCleanupLines, closedLineArgument, normalizeClosedLines, toggleClosedLine } from '../hooks/lib'
import type { CleanupItem } from '../types'

const cleanupItem: CleanupItem = { id: 'one', kind: 'dispatchWorktree', root: 'C:\\root', path: 'C:\\root\\one', name: 'one', lineSlug: 'line-a', category: null, status: 'cleanable', reasons: [], sizeBytes: 1536, fileCount: 3, protectedFileCount: 0, trackedChangeCount: 2, untrackedCount: 4 }
const cleanupDocument = { schema: 'ai-agents.work-overview-cleanup.v1', mode: 'list', generatedAtUtc: '2026-11-08T00:00:00Z', planId: 'plan-id', sessionsKnown: true, items: [cleanupItem], totals: { cleanableCount: 1, cleanableBytes: 1536, needsReviewCount: 0, protectedCount: 0 }, warnings: [], result: null }

test('P7 phase 6 parses cleanup plans and rejects invalid envelopes', () => {
  const parsed = parseCleanupOutput(JSON.stringify({ ...cleanupDocument, items: [cleanupItem, { id: 'invalid' }] }))
  expect(parsed.ok).toBe(true)
  if (parsed.ok) {
    expect(parsed.value.items).toEqual([cleanupItem])
    expect([parsed.value.items[0].trackedChangeCount, parsed.value.items[0].untrackedCount]).toEqual([2, 4])
  }
  for (const invalid of [
    { ...cleanupDocument, schema: 'wrong' }, { ...cleanupDocument, items: {} },
    { ...cleanupDocument, planId: '' }, { ...cleanupDocument, planId: undefined },
    { ...cleanupDocument, totals: null }, { ...cleanupDocument, mode: 'delete' }
  ]) expect(parseCleanupOutput(JSON.stringify(invalid)).ok).toBe(false)
  expect(parseCleanupOutput('not json').ok).toBe(false)
  const done = { ...cleanupDocument, mode: 'delete', result: { deleted: [{ id: 'one', bytes: 1536 }], failed: [], freedBytes: 1536 } }
  expect(parseCleanupOutput(JSON.stringify(done)).ok).toBe(true)
})

test('P7 phase 6 parses the cleanup script ASCII-escaped JSON as emitted', () => {
  const emitted = String.raw`{"schema":"ai-agents.work-overview-cleanup.v1","mode":"list","generatedAtUtc":"2026-11-08T08:03:02Z","planId":"10740312","sessionsKnown":false,"items":[{"id":"worktree:c:\\x\\repo-wt","kind":"worktree","root":"C:\\x\\repo-wt","path":"C:\\x\\repo-wt","name":"repo-wt","lineSlug":"","category":"","status":"needs-review","reasons":["\u672a\u53d6\u5f97 Session \u6e05\u55ae"],"sizeBytes":98,"fileCount":1,"protectedFileCount":0,"trackedChangeCount":0,"untrackedCount":0},{"id":"backup:c:\\x\\b","kind":"backup","root":"C:\\x","path":"C:\\x\\b","name":"20200101_000000","lineSlug":"","category":"","status":"cleanable","reasons":[],"sizeBytes":3,"fileCount":1,"protectedFileCount":0,"trackedChangeCount":null,"untrackedCount":null}],"totals":{"cleanableCount":1,"cleanableBytes":3,"needsReviewCount":1,"protectedCount":0},"warnings":[],"result":null}`
  const parsed = parseCleanupOutput(emitted)
  expect(parsed.ok).toBe(true)
  if (parsed.ok) {
    expect(parsed.value.items.length).toBe(2)
    expect(parsed.value.items[0].reasons).toEqual(['未取得 Session 清單'])
    expect(cleanupItemName(parsed.value.items[1])).toBe('備份 20200101_000000')
    expect(cleanupItemDetail(parsed.value.items[0])).toBe('未 commit 改動 0 個、未追蹤 0 個；未取得 Session 清單')
    expect(groupCleanupItems(parsed.value.items).cleanable.length).toBe(1)
  }
})
test('P7 review round 2 closed line helpers validate, dedupe, and build one argument', () => {
  expect(normalizeClosedLines(['b-line', 'a-line', 'a-line', 'Bad Slug', '', '-x', 'c;d', 7, null])).toEqual(['a-line', 'b-line'])
  expect(normalizeClosedLines('a-line')).toEqual([])
  expect(closedLineArgument([])).toBe(null)
  expect(closedLineArgument(['b-line', 'a-line'])).toBe('a-line,b-line')
  expect(closedLineArgument(['not valid'])).toBe(null)
  expect(toggleClosedLine([], 'a-line')).toEqual(['a-line'])
  expect(toggleClosedLine(['a-line'], 'b-line')).toEqual(['a-line', 'b-line'])
  expect(toggleClosedLine(['a-line', 'b-line'], 'a-line')).toEqual(['b-line'])
  expect(toggleClosedLine(['a-line'], 'bad slug')).toEqual(['a-line'])
})

test('P7 review round 2 only offers unclosed lines that a designation can release', () => {
  const open = (slug: string, reasons = ['缺少結案檢查點']): CleanupItem => ({ ...cleanupItem, id: `line:${slug}`, kind: 'lineArtifacts', name: slug, lineSlug: slug, category: 'all', status: 'protected', reasons })
  const items: CleanupItem[] = [
    open('beta'), open('alpha'), open('alpha'), open('busy', ['同名 Session 使用中']), open('unknown', ['未取得 Session 清單']),
    open('chosen'), open('Bad Slug'), { ...open('history-only'), category: 'history' }, { ...open('review-only'), status: 'needs-review' }, { ...cleanupItem, lineSlug: null }
  ]
  const result = closableCleanupLines(items, ['chosen'])
  expect(result.shown).toEqual([{ slug: 'alpha', reason: '缺少結案檢查點' }, { slug: 'beta', reason: '缺少結案檢查點' }])
  expect(result.hidden).toBe(0)
  const many = Array.from({ length: CLEANUP_LINE_LIMIT + 5 }, (_, index) => open(`line-${String(index).padStart(3, '0')}`))
  const limited = closableCleanupLines(many, [])
  expect(limited.shown.length).toBe(CLEANUP_LINE_LIMIT)
  expect(limited.hidden).toBe(5)
})

test('P7 phase 6 cleanup formats sizes, names, and change counts', () => {
  expect([0, 1536, 1024 ** 2, 1024 ** 3].map(formatBytes)).toEqual(['0 B', '2 KB', '1 MB', '1.0 GB'])
  expect([1023, 1024, 1048575, 1048576, 1073741823, 1073741824].map(formatBytes)).toEqual(['1023 B', '1 KB', '1 MB', '1 MB', '1.0 GB', '1.0 GB'])
  expect(cleanupItemName(cleanupItem)).toBe('派工 one（line-a）')
  expect(cleanupItemDetail(cleanupItem)).toBe('未 commit 改動 2 個、未追蹤 4 個；3 個檔案')
  expect(cleanupItemDetail({ ...cleanupItem, trackedChangeCount: null })).toContain('改動數無法取得')
  expect(cleanupItemDetail({ ...cleanupItem, untrackedCount: undefined })).toContain('改動數無法取得')
  expect(cleanupItemName({ ...cleanupItem, name: 'one（line-a）' })).toBe('派工 one（line-a）')
  expect(cleanupItemName({ ...cleanupItem, lineSlug: '' })).toBe('派工 one')
  expect(cleanupItemName({ ...cleanupItem, kind: 'lineArtifacts', category: 'history', lineSlug: '', name: 'x' })).toBe('x · 歷史')
  expect(cleanupItemName({ ...cleanupItem, kind: 'worktree' })).toBe('工作目錄 one')
  expect(cleanupItemName({ ...cleanupItem, kind: 'backup' })).toBe('備份 one')
  expect(cleanupItemName({ ...cleanupItem, kind: 'lineArtifacts', category: 'handoff-extras' })).toBe('line-a · 交接暫存')
  expect([CLEANUP_LIST_TIMEOUT_MS, CLEANUP_DELETE_TIMEOUT_MS]).toEqual([300000, 600000])
})

test('P7 phase 6 groups and limits cleanup lists', () => {
  const cleanable = Array.from({ length: 33 }, (_, index) => ({ ...cleanupItem, id: `c${index}`, sizeBytes: index }))
  const review: CleanupItem[] = Array.from({ length: 17 }, (_, index) => ({ ...cleanupItem, id: `r${index}`, status: 'needs-review', reasons: ['使用中'] }))
  const protectedItems: CleanupItem[] = [
    { ...cleanupItem, id: 'p1', status: 'protected', reasons: ['未結案'] },
    { ...cleanupItem, id: 'p2', status: 'protected', reasons: ['未結案', '被引用'] },
    { ...cleanupItem, id: 'p3', status: 'protected', reasons: ['被引用'] }
  ]
  const groups = groupCleanupItems([...cleanable, ...review, ...protectedItems])
  expect([groups.cleanable.length, groups.cleanableHidden, groups.review.length, groups.reviewHidden]).toEqual([CLEANUP_LIST_LIMIT, 3, CLEANUP_REVIEW_LIMIT, 2])
  expect(groups.cleanable.map(item => item.sizeBytes)).toEqual(Array.from({ length: 30 }, (_, index) => 32 - index))
  expect(groups.protected).toEqual([{ reason: '未結案', count: 2 }, { reason: '被引用', count: 1 }])
})

test('P7 phase 3 session transitions and baseline', () => {
  const first = finishedSessions(null, [{ sessionId: 'a', title: 'Alpha', isRunning: true }, { sessionId: 'b', isRunning: false }, { isRunning: true }])
  expect([...first.next]).toEqual([['a', true], ['b', false]])
  expect(first.finished).toEqual([])
  const transitions = finishedSessions(new Map([['a', true], ['b', true], ['c', false], ['d', false], ['missing', true]]), [
    { sessionId: 'a', title: 'Alpha', isRunning: false }, { sessionId: 'b', name: 'Beta' },
    { sessionId: 'c', isRunning: true }, { sessionId: 'd', isRunning: false },
    { sessionId: 'new', isRunning: false }, { isRunning: false }
  ])
  expect(transitions.finished).toEqual(['Alpha', 'Beta'])
  expect([...transitions.next]).toEqual([['a', false], ['b', false], ['c', true], ['d', false], ['new', false]])
  expect(finishedSessions(new Map([['a', true]]), [{ sessionId: 'a', isRunning: true }]).finished).toEqual([])
  expect(finishedSessions(new Map([['a', true]]), [{ sessionId: 'a' }]).finished).toEqual(['a'])
  expect(finishedSessions(transitions.next, [{ sessionId: 'a', isRunning: false }]).finished).toEqual([])
})
test('P7 phase 3 finished toast text limits titles and count', () => {
  expect(finishedToastText(['Alpha'])).toBe('「Alpha」已跑完')
  expect(finishedToastText(['a', 'b', 'c'])).toBe('3 個 Session 已跑完：a、b、c')
  expect(finishedToastText(['a', 'b', 'c', 'd'])).toBe('4 個 Session 已跑完：a、b、c…')
  expect(finishedToastText(['😀'.repeat(31)])).toBe(`「${'😀'.repeat(30)}…」已跑完`)
})
test('P7 phase 3 quota alert thresholds and invalid store values', () => {
  const low = (name: string, value: number, reset = 'T'): Quota => ({ Name: name, State: 'ok', PrimaryRemaining: value, PrimaryResetsAtLocal: reset })
  expect([QUOTA_ALERT_BELOW, QUOTA_ALERT_KEY]).toEqual([20, 'quota-alert'])
  expect(quotaAlert([low('b', 5), low('a', 19.4)], null)).toEqual({ alert: true, signature: 'a@T|b@T', text: 'Codex 5 小時額度：a 剩 19%、b 剩 5%' })
  expect(quotaAlert([low('a', 19.6), low('b', 5)], 'a@T|b@T')).toEqual({ alert: false, signature: null, text: null })
  expect(quotaAlert([low('a', 19.4)], null)).toEqual({ alert: true, signature: 'a@T', text: 'Codex 5 小時額度：a 剩 19%' })
  expect(quotaAlert([], 'a@T')).toEqual({ alert: false, signature: null, text: null })
  for (const value of [null, undefined, 7, {}, '', 'invalid', 'a@T|a@T']) expect(normalizeAlertSignature(value)).toBe(null)
  expect(normalizeAlertSignature('a@|b@*')).toBe('a@|b@*')
})
test('P7 phase 3 quota alert failure classes and uncertain data', () => {
  const low: Quota = { Name: 'a', State: 'ok', PrimaryRemaining: 10, PrimaryResetsAtLocal: 'T' }
  const limit: Quota = { Name: 'b', State: 'unknown', ErrorKind: 'limit-reached' }
  const login: Quota = { Name: 'b', State: 'unknown', ErrorKind: 'auth-expired' }
  const unknown: Quota = { Name: 'b', State: 'unknown', ErrorKind: 'other' }
  expect(quotaAlert([low, limit], null)).toEqual({ alert: true, signature: 'a@T|b@*', text: 'Codex 5 小時額度：a 剩 10%、b 已達上限' })
  expect(quotaAlert([low, login], null)).toEqual({ alert: true, signature: 'a@T|b@*', text: 'Codex 5 小時額度：a 剩 10%、b 登入失效' })
  const allUnavailable = quotaAlert([{ ...limit, Name: 'a' }, login], null)
  expect(allUnavailable).toEqual({ alert: true, signature: 'a@*|b@*', text: 'Codex 5 小時額度：a 已達上限、b 登入失效' })
  expect(/停止|暫停|建議/.test(allUnavailable.text || '')).toBe(false)
  expect(quotaAlert([limit, { ...low, PrimaryRemaining: 20 }], 'old@T')).toEqual({ alert: false, signature: null, text: null })
  for (const item of [unknown, { Name: 'b', State: 'unknown' }, { Name: 'b', State: 'ok', PrimaryRemaining: null }]) {
    expect(quotaAlert([low, item], 'a@T|b@T')).toEqual({ alert: false, signature: 'a@T|b@T', text: null })
  }
  expect(quotaAlert([limit, { ...unknown, Name: 'a' }], 'a@T|b@T')).toEqual({ alert: false, signature: 'a@T|b@T', text: null })
})
test('P7 phase 3 quota alert deduplicates windows and rearms', () => {
  const low = (name: string, reset: string): Quota => ({ Name: name, State: 'ok', PrimaryRemaining: 10, PrimaryResetsAtLocal: reset })
  const limit: Quota = { Name: 'a', State: 'unknown', ErrorKind: 'limit-reached' }
  const previous = 'a@T|b@T'
  expect(quotaAlert([low('b', 'T'), low('a', 'T')], previous)).toEqual({ alert: false, signature: previous, text: null })
  expect(quotaAlert([limit, low('b', 'T')], previous)).toEqual({ alert: false, signature: previous, text: null })
  expect(quotaAlert([limit, low('b', 'T2')], previous)).toEqual({ alert: true, signature: 'a@*|b@T2', text: 'Codex 5 小時額度：a 已達上限、b 剩 10%' })
  expect(quotaAlert([low('a', 'T2'), low('b', 'T')], previous)).toEqual({ alert: true, signature: 'a@T2|b@T', text: 'Codex 5 小時額度：a 剩 10%、b 剩 10%' })
  expect(quotaAlert([limit, low('c', 'T')], previous)).toEqual({ alert: true, signature: 'a@*|c@T', text: 'Codex 5 小時額度：a 已達上限、c 剩 10%' })
  expect(quotaAlert([limit, low('b', 'T')], 'a@*|b@T')).toEqual({ alert: false, signature: 'a@*|b@T', text: null })
  expect(quotaAlert([low('a', 'T')], null).alert).toBe(true)
})

test('P5-a1 dispatch worktree boundaries', () => {
  for (const path of ['C:/Users/X/.ai-agents/.local/ai-sessions/worktrees/dev-dd-1', 'c:/users/x/.ai-agents/.local/AI-Sessions/Worktrees/rev-2/', 'C:/x/.local/ai-sessions/worktrees']) expect(isDispatchWorktree(path)).toBe(true)
  for (const path of ['C:/x/.local/ai-sessions/worktrees-old/x', 'C:/x/.local/ai-sessions/handoff/x', 'C:/x/.claude/worktrees/a', '', 'relative/path', 'relative/.local/ai-sessions/worktrees/a']) expect(isDispatchWorktree(path)).toBe(false)
})
test('P5-b1 to b5 time and ordering', () => {
  const now = new Date('2026-11-05T01:23:10Z')
  const ms = now.getTime()
  expect(toEpochMs(now.toISOString())).toBe(ms)
  expect(toEpochMs(String(ms / 1000))).toBe(ms)
  for (const value of [NaN, true, {}, 0, 'bad', '', null, undefined]) expect(toEpochMs(value)).toBe(null)
  for (const [delta, expected] of [[0, '剛剛'], [59000, '剛剛'], [60000, '1 分鐘前'], [720000, '12 分鐘前'], [3600000, '1 小時前'], [86400000, '1 天前'], [STALE_MS, '3 天前'], [-1, '剛剛']] as const) expect(relativeTime(ms - delta, now)).toBe(expected)
  expect(relativeTime('bad', now)).toBe('')
  expect(isStalled(ms - STALE_MS, ms)).toBe(false)
  expect(isStalled(ms - STALE_MS - 1, ms)).toBe(true)
  expect(isStalled(null, ms)).toBe(false)
  const input = [{ title: 'old', lastActivityAt: ms - 1000 }, { title: 'new', lastActivityAt: ms }, { title: 'missing' }]
  expect(sortSessionsByActivity(input).map(item => item.title)).toEqual(['new', 'old', 'missing'])
  expect(input[0].title).toBe('old')
})
test('P5-c1 c2 checkpoint labels', () => {
  expect(checkpointLabel('`developer-collected`（Phase 1 至 3）')).toBe('Dev 回收')
  expect(checkpointLabel('`design-accepted`（未結')).toBe('設計驗收')
  expect(checkpointLabel('（只有括號）')).toBe('-')
  expect(checkpointLabel(null)).toBe('-')
  expect(checkpointLabel('abcdefghijklmn')).toBe('abcdefghijkl…')
})
test('P5-d1 d2 tone rules', () => {
  expect([sessionTone(true), sessionTone(false), sessionTone(undefined)]).toEqual(['success', 'inactive', 'inactive'])
  expect(lineTone({ hasError: true, isRunning: true })).toBe('error')
  expect(lineTone({ hasError: false, isRunning: true })).toBe('success')
  expect(rootTone({ Path: 'x', DirtyCount: 1 })).toBe('warning')
  expect(rootTone({ Path: 'x', MainBehind: 25 })).toBe('inactive')
  expect([QUOTA_OK_FROM, QUOTA_WARN_FROM]).toEqual([50, 20])
  expect([numberTone('dirty', 1), numberTone('ahead', 1), numberTone('weekly', 19), numberTone('weekly', 49), numberTone('weekly', 50), numberTone('weekly', null)]).toEqual(['attention', 'normal', 'attention', 'attention', 'normal', 'normal'])
})
test('P5-d3 d4 details', () => {
  const detail = rootDetail({ Path: 'x', DirtyCount: 19, UpstreamAhead: 9, MainAhead: 9, MainBehind: 25 })
  expect(segmentsText(detail)).toBe('19 未 commit · 9 未 push · 領先 9 · 落後 25')
  expect(detail?.filter(item => item.tone === 'attention').map(item => item.text)).toEqual(['19', '9', '25'])
  expect(rootDetail({ Path: 'x', DirtyCount: 0 })).toBe(null)
  expect(segmentsText(quotaDetail(28, '11-10 13:16'))).toBe('週 28% · 11-10 13:16 重置')
  expect(segmentsText(quotaDetail(null, null))).toBe('無週視窗')
  expect(segmentsText(quotaDetail(null, '11-10 13:16'))).toBe('無週視窗')
})
test('P5-e1 expanded state', () => {
  expect(normalizeExpanded(['stalledLines', 'stalledLines', 'bogus', 3])).toEqual(['stalledLines'])
  expect(normalizeExpanded({})).toEqual([])
  expect(toggleExpanded([], 'stalledLines')).toEqual(['stalledLines'])
  expect(toggleExpanded(['stalledLines'], 'stalledLines')).toEqual([])
})
test('P5-f1 f2 icons and divider', () => {
  const icons = (['sessions', 'quota', 'lines', 'workRoots'] as const).map(iconSvg)
  expect(new Set(icons).size).toBe(4)
  for (const icon of icons) { expect(icon.startsWith('<svg')).toBe(true); expect(icon.includes('stroke="#808080"')).toBe(true) }
  expect(ICON_ALT.lines).toBe('工作線圖示')
  expect(DIVIDER_SVG.includes('height="1"')).toBe(true)
  expect([dividerText(40).length, dividerText(undefined).length, dividerText(3).length, dividerText(999).length]).toEqual([40, 40, 10, 200])
})

const root = 'C:\\Users\\X\\.ai-agents'
const linked = root + '\\worktree'
const doc: Document = {
  scannedRoots: [root, linked],
  workRoots: [{ Path: root, IsLinkedWorktree: false }, { Path: linked, IsLinkedWorktree: true }],
  lines: [{ LineSlug: 'line-one', WorkRoot: linked, CheckpointType: 'design-accepted', NextStepSummary: '審查。' }],
  quota: [{ Name: 'account', State: 'unknown', Error: 'unavailable' }],
  warnings: []
}

test('P7 phase 4 session links accept only the specified Claude URI', () => {
  const link = 'claude://claude.ai/epitaxy/local_12345678-1234-1234-1234-123456789abc'
  expect(sessionLink({ link })).toBe(link)
  expect(sessionLink({ link: 'claude://claude.ai/epitaxy/A_z-09' })).toBe('claude://claude.ai/epitaxy/A_z-09')
  expect(sessionLink({ sessionId: 'local_123' })).toBe(null)
  for (const invalid of [null, undefined, 1, {}, '', 'https://claude.ai/epitaxy/local_123', `${link} x`, `${link};x`, `${link}&x`, `${link}\n`, `${link}/extra`, `${link}?x=1`]) {
    expect(sessionLink({ link: invalid })).toBe(null)
  }
})
test('P7 phase 4 open target selects link, process or no action', () => {
  const link = 'claude://claude.ai/epitaxy/local_123'
  expect(SESSION_OPEN_MODE).toBe('process')
  expect(sessionOpenTarget('link', link)).toEqual({ kind: 'link', href: link })
  expect(sessionOpenTarget('process', link)).toEqual({ kind: 'process', argv: ['explorer.exe', link] })
  expect(sessionOpenTarget('off', link)).toBe(null)
  for (const mode of ['link', 'process', 'off'] as const) expect(sessionOpenTarget(mode, null)).toBe(null)
})
test('P7 phase 4 snapshot includes only validated Session links', () => {
  const link = 'claude://claude.ai/epitaxy/local_123'
  const sessions = [{ cwd: root, title: 'linked', link }, { cwd: root, title: 'invalid', link: `${link};bad` }, { cwd: root, title: 'missing', sessionId: 'local_123' }]
  const board = buildSnapshot({ ok: true, value: doc }, { ok: true, value: sessions }, new Date())
  expect(board.sessions.rows.map(item => [item.name, item.link])).toEqual([['linked', link], ['invalid', null], ['missing', null]])
  for (const item of [...board.quota.rows, ...board.lines.rows, ...board.lines.stalledRows, ...board.workRoots.rows]) expect(item.link).toBe(null)
})

test('P7 phase 2 quota failures produce distinct rows', () => {
  const home = 'C:\\Users\\X\\.codex-a'
  const command = '$env:CODEX_HOME = "C:\\Users\\X\\.codex-a"; codex login; Remove-Item Env:CODEX_HOME'
  const expired = quotaErrorRow({ Name: 'a', State: 'unknown', ErrorKind: 'auth-expired', CodexHome: home })
  const limited = quotaErrorRow({ Name: 'b', State: 'unknown', ErrorKind: 'limit-reached' })
  const other = quotaErrorRow({ Name: 'c', State: 'unknown', ErrorKind: 'other', ErrorReason: '查詢逾時' })
  expect([expired.name, limited.name, other.name]).toEqual(['a · 登入失效', 'b · 已達上限', 'c · 無法取得：查詢逾時'])
  expect(expired.login).toEqual({ account: 'a', command })
  expect([expired.dot, expired.tone, limited.dot, other.tone]).toEqual(['error', 'error', 'error', 'error'])
  expect([limited.login, other.login]).toEqual([null, null])
  expect(quotaErrorRow({ Name: 'd', State: 'unknown', Error: 'exit 1：' }).name).toBe('d · 無法取得：原因不明')
  expect(quotaErrorRow({ Name: 'd', State: 'unknown', Error: 'exit 1' }).name).toBe('d · 無法取得：原因不明')
  expect(quotaErrorRow({ Name: 'e', State: 'unknown', Error: 'exit 1：Get-CodexQuota.ps1 失敗：可讀原因\n另一行' }).name).toBe('e · 無法取得：可讀原因')
  expect(quotaErrorRow({ Name: 'f', State: 'unknown', ErrorReason: '字'.repeat(41) }).name).toBe('f · 無法取得：' + '字'.repeat(40) + '…')
  const board = buildSnapshot({ ok: true, value: { ...doc, quota: [{ Name: 'd', State: 'unknown', Error: 'exit 1：' }] } }, { ok: true, value: [] }, new Date())
  expect(new RegExp('無法取得：' + 'exit \\d+$').test(board.quota.rows[0].name)).toBe(false)
})
test('P7 phase 2 login command validates paths and display mode', () => {
  expect(loginCommand('C:\\Users\\X\\.codex-a')).toBe('$env:CODEX_HOME = "C:\\Users\\X\\.codex-a"; codex login; Remove-Item Env:CODEX_HOME')
  for (const path of ['relative', 'C:\\', 'C:\\bad"x', 'C:\\bad`x', 'C:\\bad$x', 'C:\\bad;x', 'C:\\bad\nx', 'C:\\bad\rx', null]) expect(loginCommand(path)).toBe(null)
  expect([loginDisplayMode('copy', 'cmd', false), loginDisplayMode('copy', 'cmd', true), loginDisplayMode('text', 'cmd', false), loginDisplayMode('copy', null, false)]).toEqual(['copy', 'copy-and-text', 'text', 'invalid'])
})
test('P7 phase 2 status, scoped sessions and snapshot roots', () => {
  const sessions = [{ cwd: root, isRunning: true }, { cwd: linked, isRunning: false }, { cwd: 'D:\\outside', isRunning: true }, { cwd: root, isArchived: true }]
  const script = { ok: true, value: doc } as const
  const found = { ok: true, value: sessions } as const
  const failed = { ok: false, error: 'failure' } as const
  expect(scopedSessions(script, found)).toEqual(sessions.slice(0, 2))
  expect([scopedSessions(failed, found), scopedSessions(script, failed)]).toEqual([null, null])
  expect(lowestPrimary([{ Name: 'a', State: 'ok', PrimaryRemaining: 3.4 }, { Name: 'b', State: 'ok', PrimaryRemaining: 8 }, { Name: 'c', State: 'unknown', PrimaryRemaining: 0 }])).toBe(3)
  expect(lowestPrimary([{ Name: 'a', State: 'unknown', PrimaryRemaining: 0 }, { Name: 'b', State: 'ok' }])).toBe(null)
  expect([statusText(1, 3), statusText(0, null), statusText(null, 3), statusText(null, null)]).toEqual(['1 執行中 · 額度 3%', '0 執行中', '額度 3%', undefined])
  expect(buildSnapshot(script, found, new Date()).scannedRoots).toEqual(doc.scannedRoots)
  expect(buildSnapshot(failed, found, new Date()).scannedRoots).toEqual([])
  expect(errorSnapshot('bad').scannedRoots).toEqual([])
  expect(buildSnapshot(script, found, new Date()).sessions.rows.every(item => item.link === null && item.login === null)).toBe(true)
})
test('P7 phase 2 quota optional strings are validated independently', () => {
  const value = { ...doc, quota: [
    { Name: 'old', State: 'unknown' },
    { Name: 'new', State: 'unknown', CodexHome: null, ErrorKind: 'auth-expired', ErrorReason: '登入失效' },
    { Name: 'bad-home', State: 'unknown', CodexHome: 1 },
    { Name: 'bad-kind', State: 'unknown', ErrorKind: false },
    { Name: 'bad-reason', State: 'unknown', ErrorReason: {} }
  ] }
  const parsed = parseScriptOutput(JSON.stringify(value))
  expect(parsed.ok).toBe(true)
  if (parsed.ok) expect(parsed.value.quota.map(item => item.Name)).toEqual(['old', 'new'])
})

test('P5-a2 a3 current repo and arguments exclude dispatch worktrees', () => {
  const temporary = root + '\\.local\\ai-sessions\\worktrees\\dev-dd-1'
  const temporary2 = root + '\\.local\\ai-sessions\\worktrees\\rev-2'
  const worktrees = [root, linked, temporary, temporary2].map(path => ({ path, isBare: false }))
  const current = resolveCurrentRepo(temporary, { kind: 'repo', topLevel: temporary, worktrees })!
  expect(current.name).toBe('.ai-agents')
  expect(current.roots).toEqual([root, linked])
  expect(current.forced).toEqual([root])
  expect(buildWorkRootArgument('', 'C:\\Users\\X', current)?.includes('ai-sessions\\worktrees')).toBe(false)
  expect(buildForceWorkRootArgument(current)?.includes('ai-sessions\\worktrees')).toBe(false)
})
test('P5-a4 snapshot excludes dispatch worktrees only from roots', () => {
  const temporary = root + '\\.local\\ai-sessions\\worktrees\\dev-dd-1'
  const data = { ...doc, workRoots: [...doc.workRoots, { Path: temporary }, { Path: temporary + '\\nested' }] }
  const board = buildSnapshot({ ok: true, value: data }, { ok: true, value: [] }, new Date('2026-11-05T01:23:10Z'))
  expect(board.workRoots.rows.map(item => item.name)).toEqual(['.ai-agents', 'worktree'])
  expect(board.workRoots.hiddenCount).toBe(0)
  expect(board.lines.rows.length).toBe(1)
  expect(data.scannedRoots).toEqual(doc.scannedRoots)
})
test('P5 phase 1 remaining time boundaries and stable sorting', () => {
  const now = new Date('2026-11-05T01:23:10Z'), ms = now.getTime()
  for (const [delta, expected] of [[3599000, '59 分鐘前'], [86399000, '23 小時前'], [71 * 3600000, '2 天前'], [30 * 86400000, '30 天前']] as const) expect(relativeTime(ms - delta, now)).toBe(expected)
  for (const value of [null, undefined, '', 'bad']) expect(relativeTime(value, now)).toBe('')
  expect(isStalled(ms - STALE_MS + 3600000, ms)).toBe(false)
  expect(isStalled(ms + 1, ms)).toBe(false)
  const items = [{ title: 'old', lastActivityAt: ms - 10800000 }, { title: 'now', lastActivityAt: ms }, { title: 'middle', lastActivityAt: ms - 720000 }, { title: 'missing' }, { title: 'bad', lastActivityAt: 'bad' }]
  expect(sortSessionsByActivity(items).map(item => item.title)).toEqual(['now', 'middle', 'old', 'missing', 'bad'])
})
test('P5 phase 1 remaining tone and detail boundaries', () => {
  expect(lineTone({ hasError: false, isRunning: false })).toBe('inactive')
  expect(rootTone({ Path: 'x', Error: 'x' })).toBe('error')
  expect(rootTone({ Path: 'x', UpstreamAhead: 2 })).toBe('warning')
  for (const kind of ['dirty', 'unpushed', 'behind'] as const) expect([numberTone(kind, 0), numberTone(kind, 1)]).toEqual(['normal', 'attention'])
  expect(segmentsText(rootDetail({ Path: 'x', DirtyCount: 1, UpstreamAhead: 15 }))).toBe('1 未 commit · 15 未 push')
  expect(segmentsText(rootDetail({ Path: 'x', UpstreamAhead: 2, MainAhead: 2, MainBehind: 25 }))).toBe('2 未 push · 領先 2 · 落後 25')
  for (const value of [0, -1, NaN, null]) expect(rootDetail({ Path: 'x', DirtyCount: value })).toBe(null)
  expect(quotaDetail(100, '11-12 01:22').filter(item => item.tone === 'attention')).toEqual([])
  expect(quotaDetail(28, '11-10 13:16').filter(item => item.tone === 'attention').map(item => item.text)).toEqual(['28%'])
})
test('P5 phase 1 remaining labels and icon contract', () => {
  for (const value of ['developer-collected', 'developer-collected (partial)', '`developer-collected`（前一版為 `design-accepted`）']) expect(checkpointLabel(value)).toBe('Dev 回收')
  expect(checkpointLabel('結案')).toBe('結案')
  for (const id of ['sessions', 'quota', 'lines', 'workRoots'] as const) {
    const svg = iconSvg(id)
    for (const fragment of ['xmlns=', 'width="14"', 'height="14"', 'viewBox="0 0 14 14"', 'fill="none"', '</svg>']) expect(svg.includes(fragment)).toBe(true)
  }
  expect(Object.values(ICON_ALT)).toEqual(['Session 圖示', 'Codex 額度圖示', '工作線圖示', '工作目錄圖示'])
  expect(DIVIDER_SVG.includes('preserveAspectRatio="none"')).toBe(true)
  expect((DIVIDER_SVG.match(/<rect/g) || []).length).toBe(1)
})
test('P5-g1 session order, activity and line mapping', () => {
  const now = new Date('2026-11-05T01:23:10Z'), ms = now.getTime()
  const sessions = [{ cwd: root, title: 'A', lastActivityAt: ms - 10800000 }, { cwd: root, title: 'B', name: 'line-one', isRunning: true, lastActivityAt: ms }, { cwd: root, title: 'C', lastActivityAt: ms - 720000 }]
  const rows = buildSnapshot({ ok: true, value: doc }, { ok: true, value: sessions }, now).sessions.rows
  expect(rows.map(x => x.name)).toEqual(['B', 'C', 'A'])
  expect(rows.map(x => x.right)).toEqual(['剛剛', '12 分鐘前', '3 小時前'])
  expect(rows.map(x => x.dot)).toEqual(['success', 'inactive', 'inactive'])
  expect(rows[0].tag).toBe('line-one')
})
test('P5-g2 line tone and failed sessions', () => {
  const now = new Date('2026-11-05T01:23:10Z'), ms = now.getTime()
  const lines = [{ LineSlug: 'running', WorkRoot: root, CheckpointUpdatedUtc: new Date(ms - 20 * 86400000).toISOString() }, { LineSlug: 'recent', WorkRoot: root, CheckpointUpdatedUtc: new Date(ms - 23 * 3600000).toISOString() }, { LineSlug: 'old', WorkRoot: root, CheckpointUpdatedUtc: new Date(ms - 25 * 3600000).toISOString() }, { LineSlug: 'empty', WorkRoot: linked }, { LineSlug: 'bad', WorkRoot: root, Error: 'x' }]
  const data = { ...doc, lines }
  const board = buildSnapshot({ ok: true, value: data }, { ok: true, value: [{ cwd: root, name: 'running', isRunning: true }] }, now)
  const find = (name: string) => [...board.lines.rows, ...board.lines.stalledRows].find(x => x.name === name)!
  expect(find('running').dot).toBe('success')
  expect(find('recent').dot).toBe('inactive')
  expect(find('old').dot).toBe('inactive')
  expect(find('empty').right).toBe('無檢查點')
  expect(find('bad · x').dot).toBe('error')
  expect(buildSnapshot({ ok: true, value: data }, { ok: false, error: 'mcp' }, now).lines.stalledRows.find(x => x.name === 'running')?.dot).toBe('inactive')
})
test('P5-g3 roots and current highlight', () => {
  const data = { ...doc, workRoots: [{ Path: root, DirtyCount: 1, UpstreamAhead: 15, Branch: 'main' }, { Path: linked }, { Path: root + '\\bad', Error: 'x' }] }
  const current: CurrentRepo = { name: 'x', isGit: true, roots: [root], forced: [] }
  const rows = buildSnapshot({ ok: true, value: data }, { ok: true, value: [] }, new Date('2026-11-05T01:23:10Z'), current).workRoots.rows
  expect(rows.map(x => x.dot)).toEqual(['warning', 'inactive', 'error'])
  expect(rows[0].right).toBe('main')
  expect(rows[0].rightShrink).toBe(true)
  expect(rows.map(x => x.isCurrent)).toEqual([true, false, false])
  expect(buildSnapshot({ ok: true, value: data }, { ok: true, value: [] }, new Date('2026-11-05T01:23:10Z'), null).workRoots.rows.every(x => x.isCurrent === false)).toBe(true)
})
test('P5-g4 quota row and warning', () => {
  const quota = [{ Name: 'a', State: 'ok', PrimaryRemaining: 40, SecondaryRemaining: 28, SecondaryResetsAtLocal: '2026-11-10 13:16' }, { Name: 'b', State: 'ok', PrimaryRemaining: 100, SecondaryRemaining: 100 }, { Name: 'bad', State: 'unknown', Error: 'x' }]
  const result = buildSnapshot({ ok: true, value: { ...doc, quota, warnings: ['w'] } }, { ok: true, value: [] }, new Date('2026-11-05T01:23:10Z')).quota
  expect(result.rows[0].bar).toEqual({ percent: 40, tone: 'warning', window: '5 小時' })
  expect(result.rows[0].right).toBe('剩 40%')
  expect(segmentsText(result.rows[0].detail)).toBe('週 28% · 11-10 13:16 重置')
  expect(result.rows[1].dot).toBe('inactive')
  expect(result.rows[2].dot).toBe('error')
  expect(result.warning).toBe('w')
})
test('P5-h1 h2 block counts and ordering', () => {
  const block = { rows: [{ name: 'a' }, { name: 'b' }], stalledRows: [], hiddenCount: 1, errorMessage: null } as unknown as import('../types').BoardBlock
  expect(countText('sessions', 4, 32)).toBe('顯示 4 個，共 32 個')
  expect(countText('quota', 4, 32)).toBe('顯示 4 個帳號，共 32 個帳號')
  expect(countText('lines', 4, 32)).toBe('顯示 4 條，共 32 條')
  expect(countText('workRoots', 4, 32)).toBe('顯示 4 個，共 32 個')
  expect(blockCounts(block, false)).toEqual({ shown: 2, total: 3 })
  expect(blockTitleText('lines', block, false, false)).toBe('工作線 顯示 2 條，共 3 條 ▾')
  expect(blockTitleText('lines', block, true, false)).toBe('工作線 顯示 2 條，共 3 條 ▸')
  expect(blockTitleText('lines', undefined, false, false)).toBe('工作線 ▾')
  expect(BLOCK_ORDER).toEqual(['sessions', 'quota', 'lines', 'workRoots'])
  expect(BLOCK_IDS).toEqual(['sessions', 'lines', 'workRoots', 'quota'])
  expect(BLOCK_TITLES.quota).toBe('Codex 額度')
  expect(BLOCK_TITLES.lines).toBe('工作線')
  expect(BLOCK_TITLES.workRoots).toBe('工作目錄')
})
test('P5-i1 i2 stalled grouping and boundary', () => {
  const now = new Date('2026-11-05T01:23:10Z'), ms = now.getTime()
  const ago = (n: number) => new Date(ms - n).toISOString()
  const lines = [{ LineSlug: 'L1', WorkRoot: root, CheckpointUpdatedUtc: ago(2 * 86400000) }, { LineSlug: 'L2', WorkRoot: root, CheckpointUpdatedUtc: ago(STALE_MS + 1000) }, { LineSlug: 'L3', WorkRoot: root, CheckpointUpdatedUtc: ago(10 * 86400000) }, { LineSlug: 'L4', WorkRoot: root, CheckpointUpdatedUtc: ago(0) }, { LineSlug: 'edge', WorkRoot: root, CheckpointUpdatedUtc: ago(STALE_MS) }, { LineSlug: 'future', WorkRoot: root, CheckpointUpdatedUtc: ago(-1000) }, { LineSlug: 'invalid', WorkRoot: root, CheckpointUpdatedUtc: 'not-a-date' }, { LineSlug: 'empty', WorkRoot: linked }]
  const value = buildSnapshot({ ok: true, value: { ...doc, lines } }, { ok: true, value: [] }, now).lines
  const ordered = buildSnapshot({ ok: true, value: { ...doc, lines: lines.slice(0, 4) } }, { ok: true, value: [] }, now).lines
  expect(ordered.rows.map(x => x.name)).toEqual(['L4', 'L1'])
  expect(value.stalledRows.map(x => x.name)).toEqual(['L2', 'L3'])
  for (const name of ['L1', 'L4', 'edge', 'future', 'invalid', 'empty']) expect(value.rows.some(x => x.name === name)).toBe(true)
  expect(blockCounts(value, false)).toEqual({ shown: 6, total: 8 })
  expect(blockCounts(value, true)).toEqual({ shown: 8, total: 8 })
})
test('P5-i3 running and error lines remain visible', () => {
  const now = new Date('2026-11-05T01:23:10Z'), old = new Date(now.getTime() - 10 * 86400000).toISOString()
  const data = { ...doc, lines: [{ LineSlug: 'active', WorkRoot: root, CheckpointUpdatedUtc: old }, { LineSlug: 'bad', WorkRoot: root, CheckpointUpdatedUtc: old, Error: 'x' }] }
  const result = buildSnapshot({ ok: true, value: data }, { ok: true, value: [{ cwd: root, name: 'active', isRunning: true }] }, now).lines
  expect(result.rows.find(x => x.name === 'active')?.dot).toBe('success')
  expect(result.rows.some(x => x.name === 'bad · x')).toBe(true)
  expect(buildSnapshot({ ok: true, value: data }, { ok: true, value: [{ cwd: root, name: 'active', isRunning: false }] }, now).lines.stalledRows[0].name).toBe('active')
})
test('P5-i4 i5 active limit and title counts', () => {
  const now = new Date('2026-11-05T01:23:10Z')
  const lines = [...Array.from({ length: 15 }, (_, i) => ({ LineSlug: `active-${i}`, WorkRoot: root, CheckpointUpdatedUtc: now.toISOString() })), ...Array.from({ length: 20 }, (_, i) => ({ LineSlug: `old-${i}`, WorkRoot: root, CheckpointUpdatedUtc: '2026-10-01T00:00:00Z' }))]
  const result = buildSnapshot({ ok: true, value: { ...doc, lines } }, { ok: true, value: [] }, now).lines
  expect([result.rows.length, result.hiddenCount, result.stalledRows.length]).toEqual([12, 3, 20])
  expect(blockCounts(result, true).total).toBe(35)
  expect(stalledToggleText(22, false)).toBe('已結束／停擺 22 條 ▸')
  expect(stalledToggleText(22, true)).toBe('已結束／停擺 22 條 ▾')
  const titleBlock = { ...result, rows: result.rows.slice(0, 8), stalledRows: Array.from({ length: 22 }, () => result.stalledRows[0]), hiddenCount: 0 }
  expect(blockTitleText('lines', titleBlock, false, false)).toBe('工作線 顯示 8 條，共 30 條 ▾')
  expect(blockTitleText('lines', titleBlock, false, true)).toBe('工作線 顯示 30 條，共 30 條 ▾')
})
test('P5-i6 error blocks and MCP failure grouping', () => {
  const now = new Date('2026-11-05T01:23:10Z')
  const error = errorSnapshot('x')
  for (const id of ['sessions', 'quota', 'lines', 'workRoots'] as const) expect(error[id].stalledRows).toEqual([])
  const data = { ...doc, lines: [{ LineSlug: 'old', WorkRoot: root, CheckpointUpdatedUtc: '2026-10-01T00:00:00Z' }] }
  expect(buildSnapshot({ ok: true, value: data }, { ok: false, error: 'mcp' }, now).lines.stalledRows[0].name).toBe('old')
})

test('P6-a line tones and name age', () => {
  expect(lineTone({ hasError: true, isRunning: true })).toBe('error')
  expect(lineTone({ hasError: false, isRunning: true })).toBe('success')
  expect(lineTone({ hasError: false, isRunning: false })).toBe('inactive')
  const now = DIM_AFTER_MS + 10
  for (const updatedMs of [null, 10, now + 1]) expect(lineNameTone({ hasError: false, updatedMs }, now)).toBe('normal')
  expect(lineNameTone({ hasError: false, updatedMs: 9 }, now)).toBe('dim')
  expect(lineNameTone({ hasError: true, updatedMs: 9 }, now)).toBe('error')
})
test('P6-b parse branches', () => {
  expect([...parseFeatureBranches('  feature/a\r\n* feature/b\n+ feature/c\n  main\n* (HEAD detached at x)\n')]).toEqual(['feature/a', 'feature/b', 'feature/c'])
  expect([...parseFeatureBranches('')]).toEqual([])
})
test('P6-b2 branch ANSI sequences', () => {
  expect([...parseFeatureBranches('\u001b[32m* feature/x\u001b[m')]).toEqual(['feature/x'])
})
test('P6-c landed conditions', () => {
  const line = { LineSlug: 'a', WorkRoot: linked, CheckpointType: '`developer-collected`（階段）' }
  const context = { rawLines: [line, { ...line, WorkRoot: root }], workRoots: doc.workRoots, currentRoots: [root, linked], branches: new Set<string>() }
  expect(isLanded(line, context)).toBe(true)
  expect(isLanded({ ...line, CheckpointType: 'design-accepted' }, context)).toBe(false)
  expect(isLanded(line, { ...context, rawLines: [line] })).toBe(false)
  expect(isLanded(line, { ...context, workRoots: [{ Path: root, IsLinkedWorktree: true }, { Path: linked, IsLinkedWorktree: true }] })).toBe(false)
  expect(isLanded(line, { ...context, workRoots: [{ Path: root, IsLinkedWorktree: null }] })).toBe(false)
  expect(isLanded(line, { ...context, branches: new Set(['feature/a']) })).toBe(false)
  expect(isLanded(line, { ...context, branches: null })).toBe(false)
  expect(isLanded({ ...line, Error: 'x' }, context)).toBe(false)
  expect(isLanded({ ...line, WorkRoot: 'D:\\other' }, context)).toBe(false)
})
test('P6-d landed grouping and running exception', () => {
  const now = new Date('2026-11-05T00:00:00Z')
  const line = { LineSlug: 'a', WorkRoot: linked, CheckpointType: 'developer-collected', CheckpointUpdatedUtc: now.toISOString() }
  const data = { ...doc, lines: [line, { ...line, WorkRoot: root, CheckpointUpdatedUtc: null }] }
  const current: CurrentRepo = { name: 'x', isGit: true, roots: [root, linked], forced: [root] }
  const snapshot = (running: boolean, branches: Set<string> | null) => buildSnapshot({ ok: true, value: data }, { ok: true, value: running ? [{ cwd: root, name: 'a', isRunning: true }] : [] }, now, current, branches).lines
  expect(snapshot(false, new Set()).stalledRows.length).toBe(1)
  expect(snapshot(false, new Set()).rows.length).toBe(0)
  expect(blockCounts(snapshot(false, new Set()), false).total).toBe(1)
  expect(snapshot(true, new Set()).rows.length).toBe(1)
  expect(snapshot(false, null).rows.length).toBe(1)
  expect(buildSnapshot({ ok: true, value: data }, { ok: true, value: [] }, now, current).lines.rows.length).toBe(1)
  const old = { ...line, CheckpointUpdatedUtc: '2026-10-01T00:00:00Z' }
  const oldData = { ...data, lines: [old, { ...old, WorkRoot: root }] }
  expect(buildSnapshot({ ok: true, value: oldData }, { ok: true, value: [] }, now, current, new Set()).lines.stalledRows.length).toBe(1)
  expect(stalledToggleText(3, false)).toBe('已結束／停擺 3 條 ▸')
  expect(stalledToggleText(3, true)).toBe('已結束／停擺 3 條 ▾')
})
test('P6-e checkpoint labels', () => {
  expect(lineRightText('developer-collected', '1 天前')).toBe('1 天前')
  expect(lineRightText('`design-accepted`', '1 天前')).toBe('設計驗收 · 1 天前')
  expect(lineRightText('結案', '3 天前')).toBe('結案 · 3 天前')
  expect(lineRightText(null, '5 分鐘前')).toBe('5 分鐘前')
  expect(lineRightText('design-accepted', '')).toBe('設計驗收')
  const now = new Date('2026-11-05T00:00:00Z')
  const lines = [
    { LineSlug: 'dev', WorkRoot: root, CheckpointType: 'developer-collected', CheckpointUpdatedUtc: '2026-11-04T00:00:00Z' },
    { LineSlug: 'design', WorkRoot: root, CheckpointType: 'design-accepted', CheckpointUpdatedUtc: '2026-11-04T00:00:00Z' },
    { LineSlug: 'end', WorkRoot: root, CheckpointType: '結案', CheckpointUpdatedUtc: '2026-11-02T00:00:00Z' },
    { LineSlug: 'invalid', WorkRoot: root, CheckpointType: 'design-accepted', CheckpointUpdatedUtc: 'bad' },
    { LineSlug: 'empty', WorkRoot: linked }, { LineSlug: 'bad', WorkRoot: root, Error: 'x' }
  ]
  const rows = buildSnapshot({ ok: true, value: { ...doc, lines } }, { ok: true, value: [] }, now).lines.rows
  const get = (name: string) => rows.find(row => row.name === name)!
  expect(get('dev').right).toBe('1 天前')
  expect(get('design').right).toBe('設計驗收 · 1 天前')
  expect(get('end').right).toBe('結案 · 3 天前')
  expect(get('invalid').right).toBe('設計驗收')
  expect(get('empty').right).toBe('無檢查點')
  expect(get('bad · x').right).toBe('')
  expect(rows.every(row => row.detail === null)).toBe(true)
  expect(get('design').dot).toBe('inactive')
  expect(get('design').tone).toBe('normal')
  expect(get('end').tone).toBe('dim')
})
test('P6-f display width', () => {
  expect(['abc', '線', '한', 'カ', '／', 'ａ', 'ｱ', 'a線', '', '甲'.repeat(25), '·', '▸'].map(displayWidth)).toEqual([3, 2, 2, 2, 2, 2, 1, 3, 0, 50, 1, 1])
})
test('P6-g note width boundaries', () => {
  expect(canShowNote(28, 'item', 'line-one', '剛剛')).toBe(true)
  expect(canShowNote(27, 'item', 'line-one', '剛剛')).toBe(false)
  expect(canShowNote(40, 'item', '', '剛剛')).toBe(false)
  for (const columns of [undefined, NaN, 0, -1]) {
    expect(canShowNote(columns, 'item', 'line-one', '剛剛')).toBe(true)
    expect(canShowNote(columns, '甲'.repeat(15), 'line-one', '剛剛')).toBe(false)
  }
  expect(canShowNote(28, '甲甲甲甲', 'line-one', '剛剛')).toBe(false)
})
test('P6-h quota remaining', () => {
  const quota = [{ Name: 'a', State: 'ok', PrimaryRemaining: 24, SecondaryRemaining: 42 }, { Name: 'b', State: 'ok', PrimaryRemaining: null }]
  const rows = buildSnapshot({ ok: true, value: { ...doc, quota } }, { ok: true, value: [] }, new Date()).quota.rows
  expect(rows.map(item => item.right)).toEqual(['剩 24%', '-'])
  expect(rows[0].bar?.percent).toBe(24)
  expect(segmentsText(rows[0].detail)).toBe('週 42%')
})

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
  const scriptError = buildSnapshot({ ok: false, error: 'script' }, { ok: true, value: [] }, new Date('2026-11-05T01:23:10Z'))
  expect(scriptError.sessions.errorMessage).toBe('無法判定掃描範圍')
  expect(scriptError.lines.errorMessage).toBe('script')
  const mcpError = buildSnapshot({ ok: true, value: doc }, { ok: false, error: 'mcp' }, new Date('2026-11-05T01:23:10Z'))
  expect(mcpError.sessions.errorMessage).toBe('mcp')
  expect(mcpError.lines.rows.length).toBe(1)
  expect(mcpError.workRoots.rows.length).toBe(2)
  expect(mcpError.quota.rows.length).toBe(1)
  expect(parseSessions({ structuredContent: { sessions: [] } }).ok).toBe(true)
})
test('P2-i truncation and limits', () => {
  const sessions = Array.from({ length: 16 }, () => ({ cwd: linked, title: '甲'.repeat(25), isRunning: true }))
  const board = buildSnapshot({ ok: true, value: doc }, { ok: true, value: sessions }, new Date('2026-11-05T01:23:10Z'))
  expect(board.sessions.rows.length).toBe(15)
  expect(board.sessions.rows[0].name).toBe('甲'.repeat(25))
  expect(board.sessions.rows[0].tag).toBe('line-one')
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
  const snapshot = (lines: Document['lines']) => buildSnapshot({ ok: true, value: { ...doc, lines } }, { ok: true, value: [] }, new Date('2026-01-02T00:00:00Z'))
  expect(snapshot([old, recent]).lines.rows.length).toBe(1)
  expect(snapshot([old, recent]).lines.rows[0].name).toBe('same')
  const filterOrderCase = [{ ...missing, WorkRoot: root }, { ...missing, WorkRoot: linked, CheckpointType: 'design-accepted' }]
  expect(dedupeLines(filterOrderCase)[0].WorkRoot).toBe(root)
  const filteredFirst = snapshot(filterOrderCase).lines.rows
  expect(filteredFirst.length).toBe(1)
  expect(filteredFirst[0].right).toBe('設計驗收')
})
test('P3-d e line fields and errors', () => {
  const lines = [{ ...doc.lines[0], CheckpointUpdatedUtc: '2025-01-02T03:04:00', NextStepSummary: '審查。' }, { LineSlug: 'empty', WorkRoot: linked }, { LineSlug: 'bad', WorkRoot: root, Error: '錯誤' }]
  const rows = buildSnapshot({ ok: true, value: { ...doc, lines } }, { ok: true, value: [] }, new Date('2025-01-02T04:04:00')).lines.rows
  expect(rows[0].name).toBe('line-one')
  expect(rows[0].right).toBe('設計驗收 · 1 小時前')
  expect(rows[0].detail).toBe(null)
  expect(rows.find(x => x.name === 'empty')?.right).toBe('無檢查點')
  expect(rows.find(x => x.name === 'empty')?.detail).toBe(null)
  expect(rows.find(x => x.name === 'bad · 錯誤')?.tone).toBe('error')
  expect(rows.find(x => x.name === 'bad · 錯誤')?.dot).toBe('error')
  const absent = buildSnapshot({ ok: true, value: { ...doc, lines: [{ ...lines[0], NextStepSummary: null }] } }, { ok: true, value: [] }, new Date('2025-01-02T04:04:00'))
  expect(absent.lines.rows[0].right).toBe('設計驗收 · 1 小時前')
})
test('P3-f g sessions and work roots', () => {
  const workRoots = [{ Path: root, DirtyCount: 0 }, { Path: linked, DirtyCount: 3, Branch: 'main', MainAhead: 1, MainBehind: 0, Upstream: 'origin', UpstreamAhead: 2 }, { Path: root + '\\null' }, { Path: root + '\\bad', Error: 'error' }]
  const board = buildSnapshot({ ok: true, value: { ...doc, workRoots } }, { ok: true, value: [{ cwd: root, name: 'line-one', isRunning: true }, { cwd: root, name: 'other', isRunning: false }] }, new Date('2026-11-05T01:23:10Z'))
  expect(board.sessions.rows.map(x => x.dot)).toEqual(['success', 'inactive'])
  expect(board.sessions.rows.map(x => x.tag)).toEqual(['line-one', ''])
  expect(board.workRoots.rows.map(x => x.dot)).toEqual(['inactive', 'warning', 'inactive', 'error'])
  expect(segmentsText(board.workRoots.rows[1].detail)).toBe('3 未 commit · 2 未 push · 領先 1')
  expect(board.workRoots.rows[1].right).toBe('main')
  expect(board.workRoots.rows[0].right).toBe('-')
  expect(board.workRoots.rows[0].detail).toBe(null)
})
test('P3-h i quota thresholds', () => {
  expect([50, 100, 49, 20, 19, 0, null].map(quotaTone)).toEqual(['inactive', 'inactive', 'warning', 'warning', 'error', 'error', 'inactive'])
  expect([49.5, 19.5, 19.4].map(x => quotaTone(roundPercent(x)))).toEqual(['inactive', 'warning', 'error'])
  expect([null, undefined, NaN, 150, -5].map(roundPercent)).toEqual([null, null, null, 100, 0])
  expect(quotaDotTone(80, 15)).toBe('error')
  expect(quotaDotTone(null, null)).toBe('inactive')
})
test('P3-j quota row', () => {
  const quota = [{ Name: 'a', State: 'ok', PrimaryRemaining: 78, SecondaryRemaining: 42, PrimaryResetsAtLocal: '2025-01-02T03:04:00', SecondaryResetsAtLocal: '2025-01-03T03:04:00' }, { Name: 'b', State: 'ok' }]
  const rows = buildSnapshot({ ok: true, value: { ...doc, quota } }, { ok: true, value: [] }, new Date('2026-11-05T01:23:10Z')).quota.rows
  expect(rows[0].right).toBe('剩 78%')
  expect(rows[0].bar).toEqual({ percent: 78, tone: 'inactive', window: '5 小時' })
  expect(segmentsText(rows[0].detail)).toBe('週 42% · 01-03 03:04 重置')
  expect(rows[0].detail?.filter(x => x.tone === 'attention').map(x => x.text)).toEqual(['42%'])
  expect(rows[1].bar?.percent).toBe(null)
  expect(rows[1].right).toBe('-')
  expect(segmentsText(rows[1].detail)).toBe('無週視窗')
})
test('P14 quota row without a weekly window', () => {
  const base = { Name: 'a', State: 'ok', PrimaryRemaining: 40, PrimaryResetsAtLocal: '2026-11-10 13:16' }
  const variants = [base, { ...base, SecondaryRemaining: null, SecondaryResetsAtLocal: null }]
  for (const account of variants) {
    const rows = buildSnapshot({ ok: true, value: { ...doc, quota: [account] } }, { ok: true, value: [] }, new Date('2026-11-05T01:23:10Z')).quota.rows
    expect(rows.length).toBe(1)
    expect(rows[0].right).toBe('剩 40%')
    expect(rows[0].bar).toEqual({ percent: 40, tone: 'warning', window: '5 小時' })
    expect(rows[0].dot).toBe('warning')
    expect(segmentsText(rows[0].detail)).toBe('無週視窗')
  }
})
test('P14 quota alert and status text ignore a missing weekly window', () => {
  const base = { Name: 'a', State: 'ok', PrimaryRemaining: 10, PrimaryResetsAtLocal: 'T' }
  const withSecondary = [{ ...base, SecondaryRemaining: 42 }]
  for (const quota of [[base], [{ ...base, SecondaryRemaining: null, SecondaryResetsAtLocal: null }]]) {
    expect(quotaAlert(quota, null)).toEqual(quotaAlert(withSecondary, null))
    expect(quotaAlert(quota, null)).toEqual({ alert: true, signature: 'a@T', text: 'Codex 5 小時額度：a 剩 10%' })
    expect(lowestPrimary(quota)).toBe(lowestPrimary(withSecondary))
    expect(lowestPrimary(quota)).toBe(10)
    expect(statusText(1, lowestPrimary(quota))).toBe(statusText(1, lowestPrimary(withSecondary)))
    expect(statusText(1, lowestPrimary(quota))).toBe('1 執行中 · 額度 10%')
  }
})
test('P14b windowLabel renders the actual window length', () => {
  expect([300, 600, 10080, 43200, 90, 1440, 60, 1].map(windowLabel)).toEqual(['5 小時', '10 小時', '7 天', '30 天', '90 分鐘', '1 天', '1 小時', '1 分鐘'])
  expect([null, undefined, 0, -300, NaN, Infinity, 90.5].map(windowLabel)).toEqual(Array(7).fill('5 小時'))
})
test('P14b isQuota accepts numeric and null PrimaryWindowMinutes and rejects strings', () => {
  const account = { Name: 'a', State: 'ok', PrimaryRemaining: 40 }
  const parse = (item: unknown) => {
    const parsed = parseScriptOutput(JSON.stringify({ ...doc, quota: [item] }))
    return parsed.ok ? parsed.value.quota.length : -1
  }
  expect(parse({ ...account, PrimaryWindowMinutes: 43200 })).toBe(1)
  expect(parse({ ...account, PrimaryWindowMinutes: null })).toBe(1)
  expect(parse(account)).toBe(1)
  expect(parse({ ...account, PrimaryWindowMinutes: '43200' })).toBe(0)
})
test('P14b quota row bar carries the window label', () => {
  const quota = [
    { Name: 'a', State: 'ok', PrimaryRemaining: 40, PrimaryWindowMinutes: 43200 },
    { Name: 'b', State: 'ok', PrimaryRemaining: 40, PrimaryWindowMinutes: 300, SecondaryRemaining: 70 },
    { Name: 'c', State: 'ok', PrimaryRemaining: 40 },
    { Name: 'd', State: 'ok', PrimaryRemaining: 40, PrimaryWindowMinutes: null }
  ]
  const rows = buildSnapshot({ ok: true, value: { ...doc, quota } }, { ok: true, value: [] }, new Date('2026-11-05T01:23:10Z')).quota.rows
  expect(rows.map(item => item.bar)).toEqual([
    { percent: 40, tone: 'warning', window: '30 天' },
    { percent: 40, tone: 'warning', window: '5 小時' },
    { percent: 40, tone: 'warning', window: '5 小時' },
    { percent: 40, tone: 'warning', window: '5 小時' }
  ])
  expect(rows[0].right).toBe('剩 40%')
})
test('P14b quota alert text follows the window label of the accounts', () => {
  const low = (name: string, value: number, minutes?: number | null): Quota => ({ Name: name, State: 'ok', PrimaryRemaining: value, PrimaryResetsAtLocal: 'T', PrimaryWindowMinutes: minutes })
  const limit: Quota = { Name: 'c', State: 'unknown', ErrorKind: 'limit-reached' }
  const login: Quota = { Name: 'd', State: 'unknown', ErrorKind: 'auth-expired' }
  expect(quotaAlert([low('a', 10, 43200), low('b', 5, 43200)], null)).toEqual({ alert: true, signature: 'a@T|b@T', text: 'Codex 30 天額度：a 剩 10%、b 剩 5%' })
  expect(quotaAlert([low('a', 10, 300), low('b', 5, 300)], null).text).toBe('Codex 5 小時額度：a 剩 10%、b 剩 5%')
  expect(quotaAlert([low('a', 19.4, 300), low('b', 5, 43200)], null)).toEqual({ alert: true, signature: 'a@T|b@T', text: 'Codex 額度：a 剩 19%（5 小時）、b 剩 5%（30 天）' })
  expect(quotaAlert([low('a', 19.4, 300), low('b', 5, 43200), limit, login], null).text).toBe('Codex 額度：a 剩 19%（5 小時）、b 剩 5%（30 天）、c 已達上限、d 登入失效')
  expect(quotaAlert([low('a', 10, 43200), limit], null).text).toBe('Codex 30 天額度：a 剩 10%、c 已達上限')
  expect(quotaAlert([low('a', 10, 43200), low('b', 10)], null).text).toBe('Codex 30 天額度：a 剩 10%、b 剩 10%')
  expect(quotaAlert([low('a', 10), low('b', 5, null)], null).text).toBe('Codex 5 小時額度：a 剩 10%、b 剩 5%')
  expect(quotaAlert([low('a', 10, 43200), low('b', 5, 300)], 'a@T|b@T')).toEqual({ alert: false, signature: 'a@T|b@T', text: null })
  expect(quotaAlert([{ ...low('a', 10, 43200), State: 'unknown', ErrorKind: 'limit-reached' }, login], null).text).toBe('Codex 5 小時額度：a 已達上限、d 登入失效')
})
test('P3-k bars', () => {
  const svg = quotaBarSvg(50, 'inactive')
  expect(svg.includes('width="24"')).toBe(true)
  expect((svg.match(/<rect/g) || []).length).toBe(2)
  expect(quotaBarSvg(100, 'inactive').includes('width="48"')).toBe(true)
  expect(quotaBarSvg(150, 'inactive').includes('width="48"')).toBe(true)
  expect((quotaBarSvg(0, 'error').match(/<rect/g) || []).length).toBe(1)
  expect((quotaBarSvg(null, 'inactive').match(/<rect/g) || []).length).toBe(1)
  expect(svg.startsWith('<svg')).toBe(true)
  expect(svg.endsWith('</svg>')).toBe(true)
  expect(svg.includes('xmlns')).toBe(true)
  expect(quotaBarText(50)).toBe('███░░')
  expect(quotaBarText(null)).toBe('░'.repeat(5))
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
