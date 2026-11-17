import { expect, mock, test } from 'claude-code/testing'
import type { Engine, On } from 'claude-code'
import type { BoardSnapshot } from '../types'
import { accountExtra, buildSnapshot, dispatchBlock, dispatchDetailText, dispatchResultText, dispatchRow, durationText, newWaiting, parseDispatch, parseScriptOutput, parseSelfSessionId, parseWaiting, pickPermissionCall, reusableScriptOutput, scopedWaiting, scriptSignature, statusText, waitingKey, waitingKindForTool, waitingText, waitingToastText, DISPATCH_ENDED_LIMIT, SCRIPT_CACHE_KEY, WAITING_MAX_AGE_MS } from '../hooks/lib'
import { ACTIVITY_TOLERANCE_MS, PERMISSION_ACTIVE_MS, prunableWaitingKeys, staleWaitingText, waitingDiagnostics, waitingVerdict } from '../hooks/lib'
import type { Dispatch, DispatchRun, Document, PendingCall, Session, WaitingEntry } from '../hooks/lib'

const now = new Date('2026-11-16T12:00:00Z')
const base: DispatchRun = { RunKey: 'k', LineSlug: 'line-a', State: 'ended', TaskType: 'review', Profile: 'review', Account: 'acct-a', Model: 'model-x' }
const dispatch = (runs: DispatchRun[], extra: Partial<Dispatch> = {}): Dispatch => ({ runs, accounts: [], totalCount: runs.length, warnings: [], error: null, errorDetail: null, ...extra })
const segmentsText = (value: { text: string }[] | null | undefined) => (value || []).map(item => item.text).join('')
const documentWith = (value: unknown): Document => ({ scannedRoots: ['C:\\repo'], lines: [], workRoots: [], quota: [], warnings: [], dispatch: parseDispatch(value) })

test('Z2a parses the dispatch section emitted by the script and ignores unknown fields', () => {
  const emitted = String.raw`{"schema":"ai-agents.line-status.v1","scannedRoots":["C:\\repo"],"warnings":[],"workRoots":[],"lines":[],"quota":[],"dispatch":{"timeoutSeconds":1800,"turnEndGraceSeconds":60,"totalCount":3,"runs":[{"RunKey":"r1","LineSlug":"line-a","State":"running","LimitSource":"default","Account":"acct-a","Model":"model-x","StartedUtc":"2026-11-16T11:50:00Z","LastEventUtc":"2026-11-16T11:59:50Z","FutureField":{"x":1},"IsQuiet":"legacy","DurationSeconds":null},{"RunKey":"bad"},{"RunKey":"r2","LineSlug":"line-b","State":"ended","Result":"rejected","RejectionKind":"usage-limit","DurationSeconds":15.7}],"accounts":[{"Name":"acct-a","LastResult":"success","Unsupported":{"Profile":"review","Model":"model-x","ExpiresAtUtc":"2026-11-17T00:00:00Z"}},{"Name":"acct-b","Unsupported":[]},{"LastResult":"x"}],"warnings":["w\u8b66\u544a"],"error":null,"errorDetail":null}}`
  const parsed = parseScriptOutput(emitted)
  expect(parsed.ok).toBe(true)
  if (!parsed.ok) return
  const value = parsed.value.dispatch
  expect(value?.runs.map(run => run.RunKey)).toEqual(['r1', 'r2'])
  expect(value?.totalCount).toBe(3)
  expect(value?.accounts.map(account => account.Name)).toEqual(['acct-a', 'acct-b'])
  expect(value?.accounts[0].Unsupported).toEqual([{ Profile: 'review', Model: 'model-x' }])
  expect(value?.warnings).toEqual(['w警告'])
  expect(value?.error).toBe(null)
})
test('Z2a missing or malformed dispatch section keeps the rest of the board', () => {
  const old = parseScriptOutput(JSON.stringify({ scannedRoots: [], lines: [], workRoots: [], quota: [], warnings: [] }))
  expect(old.ok && old.value.dispatch).toBe(null)
  expect(parseDispatch('text')).toBe(null)
  expect(parseDispatch({ runs: 'x', accounts: null })).toEqual({ runs: [], accounts: [], totalCount: 0, warnings: [], error: null, errorDetail: null })
  expect(dispatchBlock(null, now).errorMessage).toBe('狀態腳本沒有提供派工資料，請更新腳本後重新整理')
  const failed = parseDispatch({ runs: [], accounts: [], error: '派工紀錄無法彙整', errorDetail: '找不到路徑 C:\\secret\\a.record.json' })
  expect(dispatchBlock(failed, now).errorMessage).toBe('派工紀錄無法彙整，請按「重新整理」再試一次')
  expect(dispatchBlock(failed, now).errorMessage).not.toMatch(/C:|secret/)
  expect(JSON.parse(dispatchDetailText(failed) ?? '{}').errorDetail).toBe('找不到路徑 C:\\secret\\a.record.json')
  const snap = buildSnapshot({ ok: true, value: documentWith(undefined) }, { ok: true, value: [] }, now)
  expect(snap.dispatch.errorMessage).not.toBe(null)
  expect(snap.quota.errorMessage).toBe(null)
  expect(snap.dispatchDetail).toBe(null)
})
test('Z2a dispatch rows describe running, overdue, ended and unreadable runs without implying a stall', () => {
  const running = dispatchRow({ ...base, State: 'running', StartedUtc: '2026-11-16T11:35:00Z', LastEventUtc: '2026-11-16T11:59:50Z' }, now)
  expect([running.name, running.tag, running.right, running.dot, segmentsText(running.detail)]).toEqual(['line-a · 審查', 'acct-a', '已跑 25 分鐘', 'success', '最後事件 剛剛 · model-x'])
  const longGap = dispatchRow({ ...base, State: 'running', StartedUtc: '2026-11-16T10:30:00Z', LastEventUtc: '2026-11-16T11:40:00Z', Model: null }, now)
  expect([longGap.right, longGap.dot, segmentsText(longGap.detail), longGap.detail?.[0].tone]).toEqual(['已跑 1 小時 30 分', 'success', '最後事件 20 分鐘前', 'normal'])
  const noEvents = dispatchRow({ ...base, State: 'running', StartedUtc: '2026-11-16T11:59:30Z', TaskType: 'scan', Profile: 'scan' }, now)
  expect([noEvents.name, noEvents.right, segmentsText(noEvents.detail)]).toEqual(['line-a · 派工', '已跑 30 秒', '尚無事件 · model-x'])
  const overdue = dispatchRow({ ...base, State: 'overdue', StartedUtc: '2026-11-16T10:00:00Z', LastEventUtc: '2026-11-16T10:20:00Z' }, now)
  expect([overdue.dot, overdue.right, segmentsText(overdue.detail)]).toEqual(['error', '2 小時前開始', '超過時限仍沒有結果，可能已中斷 · 最後事件 1 小時前'])
  const ok = dispatchRow({ ...base, Result: 'success', EndedUtc: '2026-11-16T11:10:00Z', DurationSeconds: 600 }, now)
  expect([ok.dot, ok.right, segmentsText(ok.detail), ok.tone]).toEqual(['inactive', '50 分鐘前', '完成 · 耗時 10 分鐘', 'normal'])
  const rejected = dispatchRow({ ...base, Result: 'rejected', RejectionKind: 'usage-limit', FailureReason: 'usage-limit', EndedUtc: '2026-11-14T11:00:00Z', DurationSeconds: 15.7 }, now)
  expect([rejected.dot, segmentsText(rejected.detail), rejected.tone]).toEqual(['warning', '被拒絕（額度用完） · 耗時 15 秒', 'dim'])
  const timeout = dispatchRow({ ...base, Result: 'failed', FailureReason: 'timeout', EndedUtc: '2026-11-16T11:30:00Z', DurationSeconds: 1800.2 }, now)
  expect([timeout.dot, segmentsText(timeout.detail)]).toEqual(['error', '失敗（超過時限） · 耗時 30 分鐘'])
  const unknown = dispatchRow({ ...base, Result: 'paused', EndedUtc: '2026-11-16T11:30:00Z' }, now)
  expect([unknown.dot, segmentsText(unknown.detail)]).toEqual(['inactive', '結果不明'])
  const invalid = dispatchRow({ RunKey: 'x', LineSlug: 'line-bad', State: 'invalid', RecordUpdatedUtc: '2026-11-16T11:00:00Z', Error: '執行紀錄無法讀取：x' }, now)
  expect([invalid.name, invalid.dot, invalid.tone, invalid.right]).toEqual(['line-bad · 紀錄無法讀取', 'error', 'error', '1 小時前'])
  for (const item of [running, longGap, noEvents, overdue, ok, rejected, timeout, unknown, invalid]) expect(JSON.stringify(item)).not.toMatch(/RunKey|\\\\|C:|usage-limit|timeout|scan|review/)
})
test('Z2a result texts follow the action the user can take', () => {
  expect(dispatchResultText('rejected', null, 'unauthorized')).toBe('被拒絕（登入失效）')
  expect(dispatchResultText('rejected', null, 'model-not-supported')).toBe('被拒絕（帳號不支援這個 model）')
  expect(dispatchResultText('rejected', null, 'other-kind')).toBe('被拒絕（服務端拒絕）')
  expect(dispatchResultText('failed', 'report-empty', null)).toBe('失敗（沒有產出報告）')
  expect(dispatchResultText('failed', 'launch-failed', null)).toBe('失敗（無法啟動）')
  expect(dispatchResultText('failed', 'something-new', null)).toBe('失敗（原因不明）')
  expect(dispatchResultText(null, null, null)).toBe('結果不明')
  expect([durationText(null), durationText(-1), durationText(59.9), durationText(3600)]).toEqual(['', '', '59 秒', '1 小時'])
})
test('Z2a dispatch block lists running and overdue runs first and limits the rest', () => {
  const ended = Array.from({ length: 8 }, (_, i): DispatchRun => ({ ...base, RunKey: `e${i}`, LineSlug: `ended-${i}`, Result: 'success', EndedUtc: '2026-11-16T11:00:00Z' }))
  const value = dispatch([{ ...base, RunKey: 'r', LineSlug: 'running-1', State: 'running', StartedUtc: '2026-11-16T11:00:00Z' }, { ...base, RunKey: 'o', LineSlug: 'overdue-1', State: 'overdue', StartedUtc: '2026-11-16T09:00:00Z' }, ...ended], { totalCount: 30, warnings: ['讀不到派工的逾時設定'] })
  const result = dispatchBlock(value, now)
  expect(result.rows.length).toBe(2 + DISPATCH_ENDED_LIMIT)
  expect(result.rows.slice(0, 2).map(item => item.name)).toEqual(['running-1 · 審查', 'overdue-1 · 審查'])
  expect(result.hiddenCount).toBe(30 - result.rows.length)
  expect(result.warning).toBe('讀不到派工的逾時設定')
  expect(dispatchBlock(dispatch([]), now).rows).toEqual([])
  expect(JSON.parse(dispatchDetailText(value) ?? '{}').runs[0].RunKey).toBe('r')
  expect(dispatchDetailText(dispatch([]))).toBe(null)
})
test('Z2a account state joins the existing quota rows instead of a new block', () => {
  const value = documentWith({ runs: [], accounts: [
    { Name: 'acct-a', LastResult: 'rejected', LastRejectionKind: 'usage-limit', LastEndedUtc: '2026-11-16T11:00:00Z', Unsupported: [{ Profile: 'review', Model: 'model-x' }, { Profile: 'scan', Model: 'model-x' }] },
    { Name: 'acct-b', LastResult: 'success', LastEndedUtc: '2026-11-16T11:59:00Z', Unsupported: [] },
    { Name: 'acct-c', Unsupported: [{ Profile: 'review', Model: null }] }
  ], totalCount: 0, warnings: [], error: null })
  value.quota = [{ Name: 'ACCT-A', State: 'ok', PrimaryRemaining: 40 }, { Name: 'acct-b', State: 'unknown', ErrorKind: 'auth-expired', CodexHome: 'C:\\h' }, { Name: 'acct-c', State: 'ok', PrimaryRemaining: 90 }, { Name: 'acct-d', State: 'ok', PrimaryRemaining: 90 }]
  const snap = buildSnapshot({ ok: true, value }, { ok: true, value: [] }, now)
  expect(snap.quota.rows.map(item => segmentsText(item.extra))).toEqual(['上次派工被拒絕（額度用完） · 1 小時前 · 不支援 model-x', '上次派工完成 · 1 分鐘前', '有不支援的 model', ''])
  expect(snap.quota.rows[0].extra?.map(item => item.tone)).toEqual(['attention', 'normal', 'attention'])
  expect(snap.quota.rows[1].login?.account).toBe('acct-b')
  expect(JSON.stringify(snap.quota.rows[2])).not.toMatch(/review/)
  expect(accountExtra(undefined, now)).toBe(null)
  expect(accountExtra({ Name: 'x', Unsupported: [] }, now)).toBe(null)
})

test('quota-reset-display limit-reached account row shows the server reset time only while it is in the future', () => {
  // 重設時間不含時區，以本地時間解析；測試以本地時間建構 now，避免依賴執行機器的時區。
  const quotaRow = (nowAt: Date, resetLocal: string | null, kind = 'usage-limit') => {
    const value = documentWith({ runs: [], accounts: [{ Name: 'acct-a', LastResult: 'rejected', LastRejectionKind: kind, LastLimitResetLocal: resetLocal, LastEndedUtc: nowAt.toISOString(), Unsupported: [] }], totalCount: 0, warnings: [], error: null })
    value.quota = [{ Name: 'acct-a', State: 'unknown', ErrorKind: 'limit-reached' }]
    return buildSnapshot({ ok: true, value }, { ok: true, value: [] }, nowAt).quota.rows[0]
  }
  const reset = '2026-11-22T17:21:00'
  expect(segmentsText(quotaRow(new Date(2026, 10, 18, 17, 21), reset).extra)).toBe('上次派工被拒絕（額度用完） · 剛剛 · 重設 11/22 17:21（約 4 天後）')
  expect(segmentsText(quotaRow(new Date(2026, 10, 22, 14, 21), reset).extra)).toBe('上次派工被拒絕（額度用完） · 剛剛 · 重設 11/22 17:21（約 3 小時後）')
  expect(segmentsText(quotaRow(new Date(2026, 10, 22, 17, 0), reset).extra)).toBe('上次派工被拒絕（額度用完） · 剛剛 · 重設 11/22 17:21（約 21 分鐘後）')
  // 沒有重設時間、重設時間已過、無法解析，或拒絕種類不是 usage-limit 時維持原顯示。
  for (const value of [null, '2026-11-22T17:21:00', 'not a time']) {
    expect(segmentsText(quotaRow(new Date(2026, 10, 22, 17, 21), value).extra)).toBe('上次派工被拒絕（額度用完） · 剛剛')
  }
  expect(segmentsText(quotaRow(new Date(2026, 10, 18, 17, 21), reset, 'rate-limited').extra)).toBe('上次派工被拒絕（請求過於頻繁） · 剛剛')
  expect(quotaRow(new Date(2026, 10, 18, 17, 21), reset).name).toBe('acct-a · 已達上限')
  // 邊界：進位到下一個單位。
  const at = (h: number, m: number) => new Date(2026, 10, 22, h, m)
  expect(segmentsText(quotaRow(at(16, 22), reset).extra)).toMatch(/（約 59 分鐘後）$/)
  expect(segmentsText(quotaRow(at(16, 21), reset).extra)).toMatch(/（約 1 小時後）$/)
  expect(segmentsText(quotaRow(new Date(2026, 10, 21, 18, 21), reset).extra)).toMatch(/（約 23 小時後）$/)
  expect(segmentsText(quotaRow(new Date(2026, 10, 21, 17, 21), reset).extra)).toMatch(/（約 1 天後）$/)
  expect(segmentsText(quotaRow(new Date(2026, 10, 21, 17, 51), reset).extra)).toMatch(/（約 1 天後）$/)
  expect(segmentsText(quotaRow(new Date(2026, 10, 22, 17, 21), reset).extra)).toBe('上次派工被拒絕（額度用完） · 剛剛')
  // 額度查詢正常、最近一次派工是 usage-limit 時不顯示重設時間。
  const okValue = documentWith({ runs: [], accounts: [{ Name: 'acct-a', LastResult: 'rejected', LastRejectionKind: 'usage-limit', LastLimitResetLocal: reset, LastEndedUtc: new Date(2026, 10, 18, 17, 21).toISOString(), Unsupported: [] }], totalCount: 0, warnings: [], error: null })
  okValue.quota = [{ Name: 'acct-a', State: 'ok', PrimaryRemaining: 40 }]
  expect(segmentsText(buildSnapshot({ ok: true, value: okValue }, { ok: true, value: [] }, new Date(2026, 10, 18, 17, 21)).quota.rows[0].extra)).toBe('上次派工被拒絕（額度用完） · 剛剛')
  expect(parseDispatch({ runs: [], accounts: [{ Name: 'a', LastLimitResetLocal: 5, Unsupported: [] }] })?.accounts).toEqual([])
})

const entry = (sessionId: string, kind: WaitingEntry['kind'], at: number, tool: string | null = null, callId = 'toolu_1'): WaitingEntry => ({ key: `waiting:${sessionId}:${callId}`, sessionId, callId, kind, tool, at })
const nowMs = now.getTime()
test('Z2a waiting entries parse per tool call and hide internal tool names', () => {
  expect(waitingKey('local_1', 'toolu_a')).toBe('waiting:local_1:toolu_a')
  expect(waitingKey('local 1', 'toolu_a')).toBe(null)
  expect(waitingKey('local_1', 'a:b')).toBe(null)
  expect(parseWaiting('waiting:local_1:toolu_a', { kind: 'permission', tool: 'Write', at: 1794852541585 })).toEqual(entry('local_1', 'permission', 1794852541585, 'Write', 'toolu_a'))
  expect(parseWaiting('waiting:local_1:toolu_a', { kind: 'permission', tool: 'mcp__server__tool', at: 1794852541585 })?.tool).toBe(null)
  for (const [key, value] of [['other:x:y', { kind: 'plan', at: 1 }], ['waiting:local_1', { kind: 'plan', at: 1794852541585 }], ['waiting::x', { kind: 'plan', at: 1 }], ['waiting:x:y', { kind: 'nope', at: 1794852541585 }], ['waiting:x:y', { kind: 'plan', at: 'soon' }], ['waiting:x:y', { kind: 'plan', at: -1 }], ['waiting:x:y', { kind: 'plan', at: 1e20 }], ['waiting:x:y', 'plan']] as const) expect(parseWaiting(key, value)).toBe(null)
  expect([waitingText(entry('a', 'permission', 0, 'Bash')), waitingText(entry('a', 'permission', 0)), waitingText(entry('a', 'question', 0)), waitingText(entry('a', 'plan', 0))]).toEqual(['等你同意：Bash', '等你同意', '等你回答', '等你核准計畫'])
  expect([waitingKindForTool('AskUserQuestion'), waitingKindForTool('ExitPlanMode'), waitingKindForTool('Bash')]).toEqual(['question', 'plan', null])
})
test('Z2a waiting verdicts rely on write time, listing and later activity, with isRunning only removing old permission requests', () => {
  const at = nowMs - 120000
  const live: Session = { sessionId: 'a', isRunning: true, lastActivityAt: new Date(at - 5000).toISOString() }
  const verdict = (session: Session | undefined, value: WaitingEntry) => { const result = waitingVerdict(session, value, nowMs); return `${result.state}:${result.reason}` }
  expect(verdict(live, entry('a', 'permission', at))).toBe('active:ok')
  expect(verdict({ ...live, isRunning: false }, entry('a', 'permission', at))).toBe('active:ok')
  expect(verdict({ ...live, isRunning: undefined }, entry('a', 'permission', at))).toBe('active:ok')
  expect(verdict({ ...live, isRunning: false, lastActivityAt: new Date(nowMs - 31 * 60000).toISOString() }, entry('a', 'plan', nowMs - 30 * 60000))).toBe('active:ok')
  expect(verdict({ ...live, lastActivityAt: new Date(at + ACTIVITY_TOLERANCE_MS).toISOString() }, entry('a', 'permission', at))).toBe('active:ok')
  expect(verdict({ ...live, lastActivityAt: new Date(at + ACTIVITY_TOLERANCE_MS + 1).toISOString() }, entry('a', 'permission', at))).toBe('hidden:activity-after')
  expect(verdict({ ...live, isArchived: true }, entry('a', 'permission', at))).toBe('hidden:archived')
  expect(verdict({ ...live, lastActivityAt: undefined }, entry('a', 'permission', at))).toBe('hidden:no-activity-time')
  expect(verdict({ ...live, lastActivityAt: new Date(nowMs - WAITING_MAX_AGE_MS - 10000).toISOString() }, entry('a', 'question', nowMs - WAITING_MAX_AGE_MS - 1))).toBe('hidden:expired')
  expect(verdict(live, entry('a', 'permission', nowMs + 10 * 60000))).toBe('hidden:future')
  expect(verdict(undefined, entry('a', 'permission', at))).toBe('hidden:not-listed')
  const old = nowMs - PERMISSION_ACTIVE_MS - 1000
  const oldSession = { ...live, lastActivityAt: new Date(old - 1000).toISOString() }
  expect(verdict(oldSession, entry('a', 'permission', old))).toBe('stale:stale-permission')
  expect(verdict({ ...oldSession, isRunning: undefined }, entry('a', 'permission', old))).toBe('stale:stale-permission')
  expect(verdict({ ...oldSession, isRunning: false }, entry('a', 'permission', old))).toBe('hidden:not-running')
  expect(verdict(oldSession, entry('a', 'permission', nowMs - PERMISSION_ACTIVE_MS))).toBe('active:ok')
  expect(staleWaitingText(entry('a', 'permission', nowMs - 12 * 60000, 'Bash'), now)).toBe('同意請求 12 分鐘前：Bash')
  expect(staleWaitingText(entry('a', 'permission', nowMs - 12 * 60000), now)).toBe('同意請求 12 分鐘前')
  const sessions: Session[] = [{ ...live, sessionId: 'a', title: 'A' }, { ...live, sessionId: 'b', title: 'B' }, { title: 'no id' }, { ...live, sessionId: 'archived', isArchived: true, title: 'Archived' }, { ...oldSession, sessionId: 'old', title: 'Old' }]
  const picked = scopedWaiting(sessions, [entry('b', 'plan', at - 1000, null, 'c1'), entry('a', 'question', at, null, 'c2'), entry('a', 'permission', at - 3000, 'Bash', 'c3'), entry('archived', 'plan', at), entry('zzz', 'plan', at), entry('old', 'permission', old, 'Bash', 'c4'), entry('old', 'question', old + 500, null, 'c5')], nowMs)
  expect(picked.map(item => [item.session.title, item.entry.callId, item.state])).toEqual([['Old', 'c5', 'active'], ['A', 'c3', 'active'], ['B', 'c1', 'active']])
  const onlyStale = scopedWaiting([{ ...oldSession, sessionId: 'old', title: 'Old' }], [entry('old', 'permission', old, 'Bash', 'c4')], nowMs)
  expect(onlyStale.map(item => [item.entry.callId, item.state])).toEqual([['c4', 'stale']])
})
test('Z2a the reader prunes keys of archived, answered, expired, or stopped sessions but never its own or keys of unlisted sessions', () => {
  const at = nowMs - 120000
  const old = nowMs - PERMISSION_ACTIVE_MS - 1000
  const sessions: Session[] = [
    { sessionId: 'live', isRunning: false, lastActivityAt: new Date(at - 1000).toISOString() },
    { sessionId: 'archived', isArchived: true, lastActivityAt: new Date(at - 1000).toISOString() },
    { sessionId: 'answered', isRunning: true, lastActivityAt: new Date(at + ACTIVITY_TOLERANCE_MS + 5000).toISOString() },
    { sessionId: 'stopped', isRunning: false, lastActivityAt: new Date(old - 1000).toISOString() },
    { sessionId: 'unknown-time', isRunning: true }
  ]
  const waiting = [
    entry('live', 'permission', at, 'Bash', 'k1'), entry('archived', 'plan', at, null, 'k2'), entry('answered', 'question', at, null, 'k3'),
    entry('stopped', 'permission', old, 'Bash', 'k4'), entry('unknown-time', 'plan', at, null, 'k5'), entry('gone', 'plan', at, null, 'k6'),
    entry('gone', 'plan', old, null, 'k7'), entry('local_me', 'plan', old, null, 'k8'), entry('live', 'question', nowMs - WAITING_MAX_AGE_MS - 1, null, 'k9')
  ]
  expect(prunableWaitingKeys(waiting, sessions, 'local_me', nowMs).map(key => key.split(':')[2])).toEqual(['k2', 'k3', 'k4', 'k9'])
})
test('Z2a waiting diagnostics show what the reader saw for each entry', () => {
  const at = nowMs - 120000
  const sessions: Session[] = [{ sessionId: 'a', title: 'A', isRunning: false, lastActivityAt: new Date(at - 1000).toISOString() }]
  const diag = waitingDiagnostics([entry('a', 'permission', at, 'Bash'), entry('gone', 'plan', at - 1)], sessions, nowMs)
  expect(diag.map(item => [item.sessionId, item.title, item.state, item.reason, item.isRunning, item.lastActivityAt, item.ageSeconds])).toEqual([
    ['gone', null, 'hidden', 'not-listed', null, null, 120],
    ['a', 'A', 'active', 'ok', false, new Date(at - 1000).toISOString(), 120]
  ])
  const text = dispatchDetailText(null, diag)
  expect(JSON.parse(text ?? '{}').waiting.length).toBe(2)
  expect(dispatchDetailText(null, [])).toBe(null)
})
test('Z2a permission requests map to the pending tool call without overwriting questions or plans', () => {
  const calls = new Map<string, PendingCall>([['t1', { tool: 'Bash', asked: false, marked: false }], ['t2', { tool: 'Bash', asked: true, marked: false }], ['t3', { tool: 'ExitPlanMode', asked: false, marked: true }], ['t4', { tool: 'Write', asked: false, marked: true }]])
  expect(pickPermissionCall(calls, 'Bash')).toBe('t2')
  calls.get('t2')!.marked = true
  expect(pickPermissionCall(calls, 'Bash')).toBe('t1')
  expect(pickPermissionCall(calls, 'ExitPlanMode')).toBe(null)
  expect(pickPermissionCall(calls, 'AskUserQuestion')).toBe(null)
  expect(pickPermissionCall(calls, 'Write')).toBe(null)
  expect(pickPermissionCall(calls, 'Read')).toBe(null)
  const ambiguous = new Map<string, PendingCall>([['u1', { tool: 'Edit', asked: false, marked: false }], ['u2', { tool: 'Edit', asked: false, marked: false }], ['v1', { tool: 'Write', asked: true, marked: false }], ['v2', { tool: 'Write', asked: true, marked: false }], ['v3', { tool: 'Write', asked: false, marked: false }]])
  expect(pickPermissionCall(ambiguous, 'Edit')).toBe(null)
  expect(pickPermissionCall(ambiguous, 'Write')).toBe(null)
})
test('Z2a new waiting toasts start from a baseline, fire once per wait and skip stale requests', () => {
  const items = [{ session: { sessionId: 'a', title: '任務一' }, entry: entry('a', 'permission', 10, 'Write') }]
  const first = newWaiting(null, items)
  expect(first.added).toEqual([])
  expect(newWaiting(first.next, items).added).toEqual([])
  const again = newWaiting(first.next, [...items, { session: { sessionId: 'b', name: 'line-b' }, entry: entry('b', 'question', 20) }, { session: { sessionId: 'c', name: 'line-c' }, entry: entry('c', 'permission', 30, 'Bash'), state: 'stale' as const }])
  expect(again.added).toEqual([{ title: 'line-b', text: '等你回答' }])
  expect(waitingToastText(again.added)).toBe('「line-b」等你回答')
  expect(waitingToastText([{ title: 'A', text: 'x' }, { title: 'B', text: 'y' }, { title: 'C', text: 'z' }, { title: 'D', text: 'w' }])).toBe('4 個 Session 在等你：A、B、C…')
})
test('Z2a waiting sessions are listed first, old permission requests are grey and uncounted', () => {
  const at = nowMs - 120000
  const old = nowMs - 12 * 60000
  const sessions: Session[] = [
    { sessionId: 'busy', cwd: 'C:\\repo', title: '忙碌', isRunning: true, lastActivityAt: '2026-11-16T11:59:00Z' },
    { sessionId: 'wait', cwd: 'C:\\repo', title: '等待中', isRunning: false, lastActivityAt: new Date(at - 1000).toISOString() },
    { sessionId: 'answered', cwd: 'C:\\repo', title: '已回應', isRunning: true, lastActivityAt: new Date(at + ACTIVITY_TOLERANCE_MS + 30000).toISOString() },
    { sessionId: 'long', cwd: 'C:\\repo', title: '長時間工具', isRunning: true, lastActivityAt: new Date(old - 1000).toISOString() },
    { sessionId: 'outside', cwd: 'D:\\other', title: '別處', isRunning: true, lastActivityAt: new Date(at - 1000).toISOString() }
  ]
  const waiting = [entry('wait', 'permission', at, 'Bash'), entry('answered', 'permission', at, 'Write'), entry('long', 'permission', old, 'Bash'), entry('outside', 'plan', at)]
  const snap = buildSnapshot({ ok: true, value: documentWith({ runs: [], accounts: [] }) }, { ok: true, value: sessions }, now, null, null, waiting)
  expect(snap.sessions.rows.map(item => item.name)).toEqual(['等待中', '已回應', '忙碌', '長時間工具'])
  expect([snap.sessions.rows[0].dot, snap.sessions.rows[0].right]).toEqual(['warning', '等你同意：Bash · 2 分鐘前'])
  expect(snap.sessions.rows[1].right).toBe('剛剛')
  expect([snap.sessions.rows[3].dot, snap.sessions.rows[3].right]).toEqual(['inactive', '同意請求 12 分鐘前：Bash'])
  expect(snap.waitingCount).toBe(1)
  const detail = JSON.parse(snap.dispatchDetail ?? '{}')
  expect(detail.waiting.map((item: { sessionId: string; state: string; isRunning: unknown }) => [item.sessionId, item.state, item.isRunning])).toEqual([['long', 'stale', true], ['wait', 'active', false], ['answered', 'hidden', true], ['outside', 'active', true]])
  expect(statusText(2, 40, 1)).toBe('1 等你 · 2 執行中 · 額度 40%')
  expect(statusText(2, 40)).toBe('2 執行中 · 額度 40%')
  expect(buildSnapshot({ ok: false, error: 'x' }, { ok: true, value: sessions }, now, null, null, waiting).waitingCount).toBe(0)
})
test('Z2a self session id and shared script output helpers', () => {
  expect(parseSelfSessionId({ structuredContent: { sessionId: 'local_abc-1' } })).toBe('local_abc-1')
  expect(parseSelfSessionId({ content: [{ type: 'text', text: '{"sessionId":"local_x"}' }] })).toBe('local_x')
  for (const value of [null, { isError: true, structuredContent: { sessionId: 'local_x' } }, { structuredContent: { sessionId: 'bad id;' } }, { content: [{ type: 'text', text: 'not json' }] }]) expect(parseSelfSessionId(value)).toBe(null)
  const signature = scriptSignature(['pwsh', '-NoProfile', '-File', 'C:\\s.ps1', '-AsJson', '-WorkRoot', 'C:\\a'])
  expect(signature).toBe(['C:\\s.ps1', '-AsJson', '-WorkRoot', 'C:\\a'].join('\u0001'))
  const cache = { signature, owner: 'other', at: 1000, stdout: '{}' }
  expect(reusableScriptOutput(cache, signature, 'me', 30000, 60000)).toEqual({ stdout: '{}', at: 1000 })
  expect(reusableScriptOutput(cache, signature, 'other', 30000, 60000)).toBe(null)
  expect(reusableScriptOutput(cache, signature + 'x', 'me', 30000, 60000)).toBe(null)
  expect(reusableScriptOutput(cache, signature, 'me', 61000, 60000)).toBe(null)
  expect(reusableScriptOutput(cache, signature, 'me', 500, 60000)).toBe(null)
  expect(reusableScriptOutput({ ...cache, stdout: 1 }, signature, 'me', 30000, 60000)).toBe(null)
  expect(SCRIPT_CACHE_KEY).toBe('script-cache')
})

type Store = Map<string, unknown>
function recordingStore(on: On, store: Store): void {
  on('store.get', (_, e) => ({ value: store.get(e.key) }))
  on('store.set', (_, e) => { store.set(e.key, e.value); return { value: undefined } })
  on('store.delete', (_, e) => { store.delete(e.key); return { value: undefined } })
  on('store.keys', () => ({ value: [...store.keys()] }))
}
const selfAnswer = (id: string | null) => (_: unknown, e: { server: string; tool: string }) => {
  if (e.tool === 'get_session') return { value: id === null ? { isError: true, content: [{ type: 'text', text: 'no' }] } : { structuredContent: { sessionId: id } } }
  return { value: { structuredContent: { sessions: [] } } }
}
const ownKeys = (store: Store) => [...store.keys()].filter(key => key.startsWith('waiting:local_me:'))
async function until(predicate: () => boolean): Promise<boolean> {
  for (let i = 0; i < 200; i++) {
    if (predicate()) return true
    await new Promise(resolve => setTimeout(resolve, 0))
  }
  return predicate()
}
type Probe = { store: Store; seen: Record<string, unknown>; nested?: boolean; gate?: Promise<void> }
function waitingHarness($: Engine, on: On, id: string | null = 'local_me'): Probe {
  const probe: Probe = { store: new Map(), seen: {} }
  recordingStore(on, probe.store)
  mock.clock(on)
  on('mcp.call', selfAnswer(id) as never)
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'test' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('classic.PermissionRequest', () => ({}))
  on('prompt.submit', (_, e) => ({ text: e.text }) as never)
  on('turn.complete', () => ({ text: '' }) as never)
  on('session.end', () => ({ sessionId: 'cli-1' }) as never)
  on('tool.call', async (_: unknown, e: { tool: string }) => {
    if (e.tool === 'Write' || e.tool === 'Bash') {
      await $.classic.PermissionRequest({ tool_name: e.tool, tool_input: {} } as never)
      await until(() => ownKeys(probe.store).length > 0)
      probe.seen[e.tool] = ownKeys(probe.store).map(key => probe.store.get(key))
      if (probe.gate && e.tool === 'Bash') await probe.gate
      if (probe.nested && e.tool === 'Write') {
        await $.tool.call({ tool: 'Read', file_path: 'C:\\repo\\a.txt' } as never)
        probe.seen.afterNested = ownKeys(probe.store).length
      }
    }
    if (e.tool === 'ExitPlanMode' || e.tool === 'AskUserQuestion') {
      await until(() => ownKeys(probe.store).length > 0)
      await $.classic.PermissionRequest({ tool_name: e.tool, tool_input: {} } as never)
      await new Promise(resolve => setTimeout(resolve, 0))
      probe.seen[e.tool] = ownKeys(probe.store).map(key => probe.store.get(key))
    }
    return { deny: 'test' }
  })
  return probe
}
const kinds = (value: unknown) => (value as { kind: string; tool: string | null }[] | undefined)?.map(item => `${item.kind}:${item.tool}`)
test('Z2a a permission request raised inside the tool call is recorded per call and cleared when that call ends', async ($, on) => {
  const probe = waitingHarness($, on)
  await $.session.start({ cwd: 'C:\\repo', surface: 'desktop', isInteractive: true })
  await $.tool.call({ tool: 'Write', file_path: 'C:\\repo\\a.txt', content: 'x' } as never)
  expect(kinds(probe.seen.Write)).toEqual(['permission:Write'])
  expect(await until(() => ownKeys(probe.store).length === 0)).toBe(true)
})
test('Z2a a parallel call that ends first does not clear another call that is still waiting', async ($, on) => {
  const probe = waitingHarness($, on)
  probe.nested = true
  await $.session.start({ cwd: 'C:\\repo', surface: 'desktop', isInteractive: true })
  await $.tool.call({ tool: 'Write', file_path: 'C:\\repo\\a.txt', content: 'x' } as never)
  expect(probe.seen.afterNested).toBe(1)
  expect(await until(() => ownKeys(probe.store).length === 0)).toBe(true)
})
test('Z2a questions and plans keep their own text when a permission request follows', async ($, on) => {
  const probe = waitingHarness($, on)
  await $.session.start({ cwd: 'C:\\repo', surface: 'desktop', isInteractive: true })
  await $.tool.call({ tool: 'ExitPlanMode', plan: 'x' } as never)
  await $.tool.call({ tool: 'AskUserQuestion', questions: [] } as never)
  expect(kinds(probe.seen.ExitPlanMode)).toEqual(['plan:null'])
  expect(kinds(probe.seen.AskUserQuestion)).toEqual(['question:null'])
  expect(await until(() => ownKeys(probe.store).length === 0)).toBe(true)
})
test('Z2a no Desktop session id means no waiting entry', async ($, on) => {
  const probe = waitingHarness($, on, null)
  await $.session.start({ cwd: 'C:\\repo', surface: 'desktop', isInteractive: true })
  await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: {} } as never)
  for (let i = 0; i < 20; i++) await new Promise(resolve => setTimeout(resolve, 0))
  expect([...probe.store.keys()].filter(key => key.startsWith('waiting:'))).toEqual([])
})
test('Z2a session start removes this session entries left by an earlier run and keeps other sessions', async ($, on) => {
  const probe = waitingHarness($, on)
  probe.store.set('waiting:local_me:old', { kind: 'permission', tool: 'Bash', at: Date.now() })
  probe.store.set('waiting:local_other:x', { kind: 'plan', tool: null, at: Date.now() })
  await $.session.start({ cwd: 'C:\\repo', surface: 'desktop', isInteractive: true })
  expect(await until(() => !probe.store.has('waiting:local_me:old'))).toBe(true)
  expect(probe.store.has('waiting:local_other:x')).toBe(true)
})
for (const [name, fire] of [
  ['prompt submit', async ($: Engine) => { await $.prompt.submit({ text: 'next' } as never) }],
  ['main turn complete', async ($: Engine) => { await $.turn.complete({ answer: '', durationMs: 1, isAborted: true, turnId: 't1', reason: 'aborted' } as never) }],
  ['session end', async ($: Engine) => { await $.session.end({ reason: 'clear' } as never) }]
] as const) {
  test(`Z2a ${name} clears a wait whose tool call has not finished`, async ($, on) => {
    const probe = waitingHarness($, on)
    let release = () => {}
    probe.gate = new Promise<void>(resolve => { release = resolve })
    await $.session.start({ cwd: 'C:\repo', surface: 'desktop', isInteractive: true })
    const pending = $.tool.call({ tool: 'Bash', command: 'x' } as never)
    expect(await until(() => ownKeys(probe.store).length === 1)).toBe(true)
    await fire($)
    expect(await until(() => ownKeys(probe.store).length === 0)).toBe(true)
    release()
    await pending
    expect(ownKeys(probe.store)).toEqual([])
  })
}
test('Z2a a subagent turn does not clear the main loop wait and a main turn does', async ($, on) => {
  const probe = waitingHarness($, on)
  let release = () => {}
  probe.gate = new Promise<void>(resolve => { release = resolve })
  await $.session.start({ cwd: 'C:\repo', surface: 'desktop', isInteractive: true })
  const pending = $.tool.call({ tool: 'Bash', command: 'x' } as never)
  expect(await until(() => ownKeys(probe.store).length === 1)).toBe(true)
  await $.turn.complete({ answer: '', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer', agentId: 'sub-1' } as never)
  for (let i = 0; i < 20; i++) await new Promise(resolve => setTimeout(resolve, 0))
  expect(ownKeys(probe.store).length).toBe(1)
  await $.turn.complete({ answer: '', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' } as never)
  expect(await until(() => ownKeys(probe.store).length === 0)).toBe(true)
  release()
  await pending
})

test('Z2a without a clearing event the wait stays until its tool call ends', async ($, on) => {
  const probe = waitingHarness($, on)
  let release = () => {}
  probe.gate = new Promise<void>(resolve => { release = resolve })
  await $.session.start({ cwd: 'C:\\repo', surface: 'desktop', isInteractive: true })
  const pending = $.tool.call({ tool: 'Bash', command: 'x' } as never)
  expect(await until(() => ownKeys(probe.store).length === 1)).toBe(true)
  for (let i = 0; i < 50; i++) await new Promise(resolve => setTimeout(resolve, 0))
  expect(ownKeys(probe.store).length).toBe(1)
  release()
  await pending
  expect(await until(() => ownKeys(probe.store).length === 0)).toBe(true)
})

function bareHarness($: Engine, on: On, beneath: (e: { tool: string; tool_use_id?: string }) => Promise<unknown>, mcp: (e: { tool: string }) => Promise<unknown> | unknown = e => selfAnswer('local_me')(undefined, e as never)): Store {
  const store: Store = new Map()
  recordingStore(on, store)
  mock.clock(on)
  on('mcp.call', ((_: unknown, e: { tool: string }) => mcp(e)) as never)
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'test' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('classic.PermissionRequest', () => ({}))
  on('tool.check', ((_: unknown, e: { input?: { command?: string } }) => ({ decision: e.input?.command === 'inner-check' ? 'ask' : 'allow' })) as never)
  on('tool.call', (async (_: unknown, e: { tool: string; tool_use_id?: string }) => beneath(e)) as never)
  void $
  return store
}
test('Z2a tool.check marks the asking call so a permission request maps to it among same-name calls', async ($, on) => {
  const seen: { outer?: string; inner?: string; keys?: string[]; afterInner?: string[]; checked?: string } = {}
  let store: Store = new Map()
  store = bareHarness($, on, async e => {
    if (e.tool !== 'Bash') return { deny: 'test' }
    if (!seen.outer) {
      seen.outer = e.tool_use_id
      await $.tool.call({ tool: 'Bash', command: 'inner' } as never)
      seen.afterInner = ownKeys(store)
      return { deny: 'test' }
    }
    seen.inner = e.tool_use_id
    seen.checked = (await $.tool.check({ tool: 'Bash', input: { command: 'inner-check' }, tool_use_id: e.tool_use_id } as never) as { decision?: string }).decision
    await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: {} } as never)
    await until(() => ownKeys(store).length > 0)
    seen.keys = ownKeys(store)
    return { deny: 'test' }
  })
  await $.session.start({ cwd: 'C:\\repo', surface: 'desktop', isInteractive: true })
  await $.tool.call({ tool: 'Bash', command: 'outer' } as never)
  expect(typeof seen.inner).toBe('string')
  expect(seen.checked).toBe('ask')
  expect(seen.keys).toEqual([`waiting:local_me:${seen.inner}`])
  expect(seen.afterInner).toEqual([])
})
test('Z2a a tool call that throws still removes its pending entry and its wait', async ($, on) => {
  let store: Store = new Map()
  let written: string[] = []
  store = bareHarness($, on, async e => {
    if (e.tool !== 'Write') return { deny: 'test' }
    await $.classic.PermissionRequest({ tool_name: 'Write', tool_input: {} } as never)
    await until(() => ownKeys(store).length > 0)
    written = ownKeys(store)
    throw new Error('aborted by the user')
  })
  await $.session.start({ cwd: 'C:\\repo', surface: 'desktop', isInteractive: true })
  let failed = false
  try { await $.tool.call({ tool: 'Write', file_path: 'C:\\repo\\a.txt', content: 'x' } as never) } catch { failed = true }
  expect(written.length).toBe(1)
  expect(failed || ownKeys(store).length === 0).toBe(true)
  expect(await until(() => ownKeys(store).length === 0)).toBe(true)
  await $.classic.PermissionRequest({ tool_name: 'Write', tool_input: {} } as never)
  for (let i = 0; i < 20; i++) await new Promise(resolve => setTimeout(resolve, 0))
  expect(ownKeys(store)).toEqual([])
})
test('Z2a session start keeps a wait written while the session id was still being fetched', async ($, on) => {
  let releaseId = () => {}
  const idGate = new Promise<void>(resolve => { releaseId = resolve })
  let during: unknown
  let store: Store = new Map()
  store = bareHarness($, on, async e => {
    if (e.tool === 'ExitPlanMode') {
      releaseId()
      await until(() => ownKeys(store).some(key => key !== 'waiting:local_me:old'))
      for (let i = 0; i < 30; i++) await new Promise(resolve => setTimeout(resolve, 0))
      during = ownKeys(store)
    }
    return { deny: 'test' }
  }, async e => {
    if (e.tool === 'get_session') { await idGate; return { value: { structuredContent: { sessionId: 'local_me' } } } }
    return { value: { structuredContent: { sessions: [] } } }
  })
  store.set('waiting:local_me:old', { kind: 'permission', tool: 'Bash', at: Date.now() - 60000 })
  await $.session.start({ cwd: 'C:\\repo', surface: 'desktop', isInteractive: true })
  await $.tool.call({ tool: 'ExitPlanMode', plan: 'x' } as never)
  expect((during as string[]).filter(key => key !== 'waiting:local_me:old').length).toBe(1)
  expect((during as string[]).includes('waiting:local_me:old')).toBe(false)
})

const PANE = { plugin: 'line-status-board', component: 'Pane', requestId: 'line-status-board', props: { title: '工作總覽', isFocused: false, bodyColumns: 60, placement: 'dock', scroll: { offset: 0, bodyRows: 40 }, view: {} } } as const
test('Z2a the dispatch block renders rows, an empty state and a copy button for details', async ($, on) => {
  mock.store(on)
  const value = dispatch([{ ...base, State: 'running', StartedUtc: '2026-11-16T11:50:00Z', LastEventUtc: new Date(Date.now() - 90000).toISOString() }])
  const filled = buildSnapshot({ ok: true, value: { scannedRoots: [], lines: [], workRoots: [], quota: [], warnings: [], dispatch: value } }, { ok: true, value: [] }, new Date())
  const empty: BoardSnapshot = { ...filled, dispatch: { rows: [], stalledRows: [], hiddenCount: 0, errorMessage: null }, dispatchDetail: null }
  let current: BoardSnapshot = filled
  const copied: string[] = []
  on('state.get', ($, e, next) => e.key === 'snapshot' ? { value: { value: { shape: 'snapshot-7', value: current }, version: 1 } } : next(e))
  on('ui.copy', (_, e) => { copied.push(e.text); return { value: { isCopied: true } } })
  on('ui.toast', () => ({ value: undefined }))
  for (const surface of ['terminal', 'desktop'] as const) {
    current = filled
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: 'line-a · 審查' })).not.toBe(undefined)
    expect(await ui.find({ type: 'Text', text: /^派工 顯示 1 筆，共 1 筆/ })).not.toBe(undefined)
    expect((await ui.findAll({ type: 'Text' })).some(item => item.text === '最後事件 1 分鐘前' && item.props.color !== 'warning')).toBe(true)
    await ui.press({ key: 'copy-dispatch' })
    await ui.unmount()
    current = empty
    const blank = await $.ui.mount({ ...PANE, surface })
    expect(await blank.find({ type: 'Text', text: '（沒有派工紀錄，派工開始後會列在這裡）' })).not.toBe(undefined)
    expect(await blank.find({ type: 'Button', key: 'copy-dispatch' })).toBe(undefined)
    await blank.unmount()
  }
  expect(copied.length).toBe(2)
  expect(JSON.parse(copied[0]).runs[0].RunKey).toBe('k')
})
