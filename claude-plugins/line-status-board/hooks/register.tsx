import { atom, read, update } from 'claude-code'
import type { Engine, Register, RenderSurface } from 'claude-code'
import type { BlockId, BoardBlock, BoardLogin, BoardRow, BoardSnapshot, CleanupItem, CleanupView, ExpandId } from '../types'
import { buildSnapshot, errorSnapshot, parseScriptOutput, parseSessions, REFRESH_MS, STORE_KEY, HOVER_BG, BAR_WIDTH, BAR_HEIGHT, normalizeCollapsed, toggleBlock, quotaBarSvg, quotaBarText, BLOCK_ORDER, blockTitleText, iconSvg, ICON_ALT, ICON_SIZE, DIVIDER_SVG, DIVIDER_MODE, dividerText, NAME_SHRINK, NOTE_SHRINK, CURRENT_BG } from './lib'
import type { Document, Result, Session } from './lib'
import { GIT_TIMEOUT_MS, SCRIPT_BUDGET_MS, parseWorktreeList, resolveCurrentRepo, buildWorkRootArgument, buildForceWorkRootArgument, remainingBudgetMs } from './lib'
import type { CurrentRepo, GitProbe } from './lib'
import { EXPAND_KEY, normalizeExpanded, toggleExpanded, stalledToggleText, canShowNote, parseFeatureBranches } from './lib'
import { LOGIN_COMMAND_MODE, loginDisplayMode, lowestPrimary, scopedSessions, statusText } from './lib'
import { finishedSessions, finishedToastText, normalizeAlertSignature, quotaAlert, QUOTA_ALERT_KEY } from './lib'
import { SESSION_OPEN_MODE, sessionOpenTarget, windowLabel } from './lib'
import { CLEANUP_DELETE_TIMEOUT_MS, CLEANUP_LIST_TIMEOUT_MS, cleanupItemDetail, cleanupItemName, formatBytes, groupCleanupItems, parseCleanupOutput } from './lib'
import { closableCleanupLines, closedLineArgument, normalizeClosedLines, toggleClosedLine } from './lib'
import { REFRESH_MS as CACHE_MAX_AGE_MS, SCRIPT_CACHE_KEY, WAITING_PREFIX, isWaitingExpired, newWaiting, parseSelfSessionId, parseWaiting, pickPermissionCall, prunableWaitingKeys, reusableScriptOutput, scopedWaiting, scriptSignature, waitingKey, waitingKindForTool, waitingSessionPrefix, waitingToastText } from './lib'
import type { PendingCall, WaitingEntry, WaitingKind } from './lib'

const PANE = 'line-status-board'
const snapshot = atom({ plugin: 'line-status-board', key: 'snapshot' } as const, null as BoardSnapshot | null, { shape: 'snapshot-7' })
const collapsed = atom({ plugin: 'line-status-board', key: 'collapsed' } as const, null as BlockId[] | null, { shape: 'collapsed-1' })
const expanded = atom({ plugin: 'line-status-board', key: 'expanded' } as const, null as ExpandId[] | null, { shape: 'expanded-1' })
const loginShown = atom({ plugin: 'line-status-board', key: 'loginShown' } as const, [] as string[], { shape: 'loginShown-1' })
const initialCleanup: CleanupView = { phase: 'idle', plan: null, message: null }
const cleanup = atom({ plugin: 'line-status-board', key: 'cleanup' } as const, initialCleanup, { shape: 'cleanup-1' })
const cleanupClosedPending = atom({ plugin: 'line-status-board', key: 'cleanupClosedPending' } as const, [] as string[], { shape: 'cleanupClosedPending-1' })
const cleanupClosedApplied = atom({ plugin: 'line-status-board', key: 'cleanupClosedApplied' } as const, [] as string[], { shape: 'cleanupClosedApplied-1' })
const refreshedAt = atom({ plugin: 'line-status-board', key: 'refreshedAt' } as const, null as string | null)
const isRefreshing = atom({ plugin: 'line-status-board', key: 'isRefreshing' } as const, false)
let isBusy = false
let pendingCwd: string | null = null
let lastRunning: Map<string, boolean> | null = null
let quotaSignature: string | null | undefined
let cleanupBusy = false
let selfId: string | null = null
const pendingCalls = new Map<string, PendingCall>()
const writtenKeys = new Set<string>()
let sessionStartedAt = 0
let lastWaiting: Set<string> | null = null

type BoardOptions = { workRoots?: string; scriptPath?: string; notifySessionDone?: boolean }

const message = (error: unknown): string => String(error instanceof Error ? error.message : error).split(/\r?\n/)[0].slice(0, 120)

async function loadStored($: Engine): Promise<BlockId[]> {
  try { return normalizeCollapsed(await $.store.get(STORE_KEY)) } catch { return [] }
}
async function toggle($: Engine, id: BlockId): Promise<void> {
  const stored = await loadStored($)
  try {
    const next = await update($, collapsed, previous => toggleBlock(previous ?? stored, id))
    await $.store.set(STORE_KEY, next)
  } catch { /* 狀態更新或儲存失敗時保留原有狀態 */ }
}
async function loadStoredExpanded($: Engine): Promise<ExpandId[]> {
  try { return normalizeExpanded(await $.store.get(EXPAND_KEY)) } catch { return [] }
}
async function toggleStalled($: Engine): Promise<void> {
  const stored = await loadStoredExpanded($)
  try {
    const next = await update($, expanded, previous => toggleExpanded(previous ?? stored, 'stalledLines'))
    await $.store.set(EXPAND_KEY, next)
  } catch { /* 狀態更新或儲存失敗時保留原有狀態 */ }
}
async function copyLogin($: Engine, login: BoardLogin, surface: RenderSurface): Promise<void> {
  if (login.command === null) return
  let reason: string
  try {
    const result = await $.ui.copy({ text: login.command, surface })
    if (result.isCopied) { $.ui.toast(`已複製 ${login.account} 的登入命令`); return }
    reason = result.reason
  } catch (error) { reason = message(error) }
  await update($, loginShown, previous => previous.includes(login.account) ? previous : [...previous, login.account])
  $.ui.toast(`無法複製（${reason}），已改顯示命令`)
}
async function openSession($: Engine, argv: string[]): Promise<void> {
  try { await $.process.run(argv) } catch { $.ui.toast('無法開啟 Session') }
}

async function runGit($: Engine, cwd: string, args: string[]) {
  return $.process.run(['git', '--no-optional-locks', ...args], { cwd, timeoutMs: GIT_TIMEOUT_MS })
}
async function probeGit($: Engine, cwd: string): Promise<GitProbe> {
  let top
  try { top = await runGit($, cwd, ['rev-parse', '--show-toplevel']) }
  catch { return { kind: 'failed' } }
  const topLevel = top.stdout.split(/\r?\n/)[0].trim()
  if (top.exitCode !== 0 || !topLevel) return { kind: 'notRepo' }
  let worktrees = null
  try {
    const result = await runGit($, cwd, ['worktree', 'list', '--porcelain'])
    if (result.exitCode === 0) worktrees = parseWorktreeList(result.stdout)
  } catch { /* 使用 topLevel */ }
  return { kind: 'repo', topLevel, worktrees }
}
async function locateCurrent($: Engine, cwdHint?: string): Promise<CurrentRepo | null> {
  try {
    const cwd = cwdHint?.trim() ? cwdHint : await $.session.cwd()
    if (!cwd?.trim()) return null
    return resolveCurrentRepo(cwd, await probeGit($, cwd))
  } catch { return null }
}
async function listFeatureBranches($: Engine, current: CurrentRepo | null): Promise<Set<string> | null> {
  if (!current?.isGit) return null
  const cwd = current.forced[0] ?? current.roots[0]
  if (!cwd) return null
  try {
    const result = await runGit($, cwd, ['branch', '--no-color', '--list', 'feature/*'])
    return result.exitCode === 0 ? parseFeatureBranches(result.stdout) : null
  } catch { return null }
}

async function scriptOwner($: Engine): Promise<string> {
  try { return await $.session.id() } catch { return 'unknown' }
}
async function cachedScriptOutput($: Engine, signature: string, owner: string): Promise<{ stdout: string; at: number } | null> {
  try { return reusableScriptOutput(await $.store.get(SCRIPT_CACHE_KEY), signature, owner, Date.now(), CACHE_MAX_AGE_MS) } catch { return null }
}
async function saveScriptOutput($: Engine, signature: string, owner: string, stdout: string): Promise<void> {
  try { await $.store.set(SCRIPT_CACHE_KEY, { signature, owner, at: Date.now(), stdout }) } catch { /* 共用失敗時各 Session 自行執行 */ }
}

type ScriptOutcome = { result: Result<Document>; dataAt: number | null }
async function scriptResult($: Engine, options: { workRoots?: string; scriptPath?: string }, current: CurrentRepo | null, startedAt: number, useCache = false): Promise<ScriptOutcome> {
  try {
    let path = options.scriptPath?.trim()
    if (!path) {
      const local = $.plugin.root + '\\..\\..\\scripts\\Get-LineStatus.ps1'
      if (await scriptFileExists($, local)) path = local
      else {
        const profile = await $.env.get('USERPROFILE')
        if (profile) {
          const fallback = profile + '\\.ai-agents\\scripts\\Get-LineStatus.ps1'
          if (await scriptFileExists($, fallback)) path = fallback
        }
      }
    }
    if (!path) throw new Error('找不到 Get-LineStatus.ps1')
    const argv = ['pwsh', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path, '-AsJson']
    let profile: string | null = null
    try { profile = await $.env.get('USERPROFILE') ?? null } catch { /* 使用腳本預設值 */ }
    const roots = buildWorkRootArgument(options.workRoots, profile, current)
    if (roots !== null) argv.push('-WorkRoot', roots)
    const forced = buildForceWorkRootArgument(current)
    if (forced !== null) argv.push('-ForceWorkRoot', forced)
    const signature = scriptSignature(argv)
    const owner = await scriptOwner($)
    const cached = useCache ? await cachedScriptOutput($, signature, owner) : null
    if (cached !== null) {
      const reused = parseScriptOutput(cached.stdout)
      if (reused.ok) return { result: reused, dataAt: cached.at }
    }
    const result = await $.process.run(argv, { timeoutMs: remainingBudgetMs(SCRIPT_BUDGET_MS, Date.now() - startedAt) })
    if (result.exitCode !== 0) throw new Error(result.stderr || `exit ${result.exitCode}`)
    const parsed = parseScriptOutput(result.stdout)
    if (parsed.ok && !result.isStdoutTruncated) await saveScriptOutput($, signature, owner, result.stdout)
    return { result: parsed, dataAt: null }
  } catch (error) { return { result: { ok: false, error: message(error) }, dataAt: null } }
}

async function sessionResult($: Engine): Promise<Result<Session[]>> {
  try { return parseSessions(await $.mcp.call('ccd_session_mgmt', 'list_sessions', { limit: 200 })) }
  catch (error) { return { ok: false, error: message(error) } }
}

async function resolveSelfId($: Engine): Promise<string | null> {
  if (selfId !== null) return selfId
  try { selfId = parseSelfSessionId(await $.mcp.call('ccd_session_mgmt', 'get_session', { session_id: 'self' })) } catch { selfId = null }
  return selfId
}
// 等待標示以工具呼叫為單位各自寫入與清除；寫入在背景進行，寫完時該呼叫已結束就立即刪除，避免留下殘留。
async function markWaiting($: Engine, callId: string, kind: WaitingKind, tool: string | null): Promise<void> {
  try {
    const at = Date.now()
    const id = await resolveSelfId($)
    if (id === null || !pendingCalls.has(callId)) return
    const key = waitingKey(id, callId)
    if (key === null) return
    await $.store.set(key, { kind, tool, at })
    writtenKeys.add(key)
    if (!pendingCalls.has(callId)) await clearKeys($, [key])
  } catch { /* 寫入失敗時面板不顯示這筆等待 */ }
}
async function clearKeys($: Engine, keys: string[]): Promise<void> {
  for (const key of keys) {
    try {
      await $.store.delete(key)
      writtenKeys.delete(key)
    } catch { /* 下次事件再清除 */ }
  }
}
async function clearCall($: Engine, callId: string): Promise<void> {
  const keys = [...writtenKeys].filter(key => key.endsWith(':' + callId))
  if (keys.length) await clearKeys($, keys)
}
async function clearAllWaiting($: Engine): Promise<void> {
  if (writtenKeys.size) await clearKeys($, [...writtenKeys])
}
// 只刪除本次啟動之前留下的鍵；取得 Session id 期間新寫入的有效等待以寫入時間與 writtenKeys 區分，不會被刪除。
async function clearOwnWaiting($: Engine, startedAt: number): Promise<void> {
  try {
    const id = await resolveSelfId($)
    if (id === null) return
    const prefix = waitingSessionPrefix(id)
    const stale: string[] = []
    for (const key of await $.store.keys()) {
      if (!key.startsWith(prefix) || writtenKeys.has(key)) continue
      const entry = parseWaiting(key, await $.store.get(key))
      if (entry === null || entry.at < startedAt) stale.push(key)
    }
    if (stale.length) await clearKeys($, stale)
  } catch { /* 下次啟動再清除 */ }
}
async function pruneWaiting($: Engine, waiting: WaitingEntry[], sessions: Result<Session[]>): Promise<void> {
  if (!sessions.ok || selfId === null) return
  const keys = prunableWaitingKeys(waiting, sessions.value, selfId, Date.now())
  if (keys.length) await clearKeys($, keys)
}
function forgetPendingCalls(): void {
  pendingCalls.clear()
}
async function startCall($: Engine, callId: string | undefined, tool: string): Promise<void> {
  if (!callId) return
  pendingCalls.set(callId, { tool, asked: false, marked: false })
  const kind = waitingKindForTool(tool)
  if (kind !== null) {
    pendingCalls.set(callId, { tool, asked: false, marked: true })
    void markWaiting($, callId, kind, null)
  }
}
async function endCall($: Engine, callId: string | undefined): Promise<void> {
  if (!callId) return
  pendingCalls.delete(callId)
  await clearCall($, callId)
}
function noteAsk(callId: string | undefined, decision: unknown): void {
  const call = callId ? pendingCalls.get(callId) : undefined
  if (call && decision === 'ask') call.asked = true
}
function markPermission($: Engine, tool: string): void {
  const callId = pickPermissionCall(pendingCalls, tool)
  const call = callId ? pendingCalls.get(callId) : undefined
  if (!callId || !call) return
  call.marked = true
  void markWaiting($, callId, 'permission', tool)
}
async function endSessionWaiting($: Engine): Promise<void> {
  pendingCalls.clear()
  await clearAllWaiting($)
  selfId = null
}
async function readWaiting($: Engine): Promise<WaitingEntry[]> {
  try {
    const entries: WaitingEntry[] = []
    const expired: string[] = []
    const now = Date.now()
    for (const key of await $.store.keys()) {
      if (!key.startsWith(WAITING_PREFIX)) continue
      const entry = parseWaiting(key, await $.store.get(key))
      if (entry === null || isWaitingExpired(entry, now)) expired.push(key)
      else entries.push(entry)
    }
    if (expired.length) void clearKeys($, expired)
    return entries
  } catch { return [] }
}
async function copyDispatchDetail($: Engine, text: string | null, surface: RenderSurface): Promise<void> {
  if (text === null) return
  try {
    const result = await $.ui.copy({ text, surface })
    $.ui.toast(result.isCopied ? '已複製派工明細' : `無法複製（${result.reason}）`)
  } catch (error) { $.ui.toast(`無法複製（${message(error)}）`) }
}

async function scriptFileExists($: Engine, path: string): Promise<boolean> {
  try { await $.fs.stat(path); return true } catch { return false }
}

async function cleanupScriptPath($: Engine, options: BoardOptions): Promise<string> {
  const filename = 'Invoke-WorkOverviewCleanup.ps1'
  const configured = options.scriptPath?.trim()
  if (configured) {
    const separator = Math.max(configured.lastIndexOf('\\'), configured.lastIndexOf('/'))
    const path = configured.slice(0, separator + 1) + filename
    if (await scriptFileExists($, path)) return path
    throw new Error(`找不到 ${filename}`)
  }
  const local = $.plugin.root + '\\..\\..\\scripts\\' + filename
  if (await scriptFileExists($, local)) return local
  try {
    const profile = await $.env.get('USERPROFILE')
    if (profile) {
      const fallback = profile + '\\.ai-agents\\scripts\\' + filename
      if (await scriptFileExists($, fallback)) return fallback
    }
  } catch { /* 路徑不存在 */ }
  throw new Error(`找不到 ${filename}`)
}

async function runCleanup($: Engine, options: BoardOptions, confirm: boolean, reset = false): Promise<void> {
  if (cleanupBusy) return
  cleanupBusy = true
  try {
    if (reset) {
      await update($, cleanupClosedPending, () => [])
      await update($, cleanupClosedApplied, () => [])
    }
    const previous = await read($, cleanup)
    if (confirm && (previous.phase !== 'listed' || !previous.plan || previous.plan.totals.cleanableCount === 0)) return
    const planId = confirm ? previous.plan?.planId : undefined
    await update($, cleanup, () => ({ phase: confirm ? 'deleting' : 'listing', plan: previous.plan, message: null }))
    const current = await read($, snapshot)
    if (!current?.scannedRoots.length) throw new Error('尚未取得掃描範圍，請先重新整理')
    const path = await cleanupScriptPath($, options)
    const sessions = await sessionResult($)
    const stdin = JSON.stringify({ sessions: sessions.ok ? sessions.value.filter(item => item.isArchived !== true).map(item => ({ cwd: item.cwd, name: item.name, title: item.title })) : null })
    const closed = normalizeClosedLines(confirm ? await read($, cleanupClosedApplied) : await read($, cleanupClosedPending))
    const closedArgument = closedLineArgument(closed)
    const argv = ['pwsh', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path, '-Root', current.scannedRoots.join(';'), '-SessionsFromStdin', '-AsJson']
    if (closedArgument !== null) argv.push('-ClosedLine', closedArgument)
    if (planId) argv.push('-ConfirmPlan', planId)
    const result = await $.process.run(argv, { stdin, timeoutMs: confirm ? CLEANUP_DELETE_TIMEOUT_MS : CLEANUP_LIST_TIMEOUT_MS })
    if (result.exitCode === 3) throw new Error('清單已變更，請重新列出')
    if (result.exitCode !== 0 && !(confirm && result.exitCode === 2)) throw new Error(result.stderr || `exit ${result.exitCode}`)
    if (result.isStdoutTruncated) throw new Error('清理清單輸出不完整，請重新列出')
    const parsed = parseCleanupOutput(result.stdout)
    if (!parsed.ok) throw new Error(parsed.error)
    if (parsed.value.mode !== (confirm ? 'delete' : 'list')) throw new Error('清理腳本回傳的模式不正確')
    if (!confirm && parsed.value.items.filter(item => item.status === 'cleanable').length !== parsed.value.totals.cleanableCount) throw new Error('清理清單資料不完整，請重新列出')
    if (!confirm) await update($, cleanupClosedApplied, () => closed)
    await update($, cleanup, () => ({ phase: confirm ? 'done' : 'listed', plan: parsed.value, message: null }))
    if (confirm) {
      try { await refresh($, options) } catch { /* 清理已完成，更新失敗不改變結果 */ }
    }
  } catch (error) {
    await update($, cleanup, () => ({ phase: 'error', plan: null, message: message(error) }))
  } finally {
    cleanupBusy = false
  }
}

async function closeCleanup($: Engine): Promise<void> {
  if (cleanupBusy) return
  await update($, cleanup, () => initialCleanup)
  await update($, cleanupClosedPending, () => [])
  await update($, cleanupClosedApplied, () => [])
}

async function toggleClosedLineSelection($: Engine, slug: string): Promise<void> {
  if (cleanupBusy) return
  await update($, cleanupClosedPending, previous => toggleClosedLine(previous, slug))
}

export async function notify($: Engine, options: BoardOptions, script: Result<Document>, sessions: Result<Session[]>, waiting: WaitingEntry[] = []): Promise<void> {
  try {
    const scoped = scopedSessions(script, sessions)
    if (scoped !== null) {
      const result = finishedSessions(lastRunning, scoped)
      lastRunning = result.next
      if (options.notifySessionDone !== false && result.finished.length) $.ui.toast(finishedToastText(result.finished))
      const others = scoped.filter(session => session.sessionId !== selfId)
      const pending = newWaiting(lastWaiting, scopedWaiting(others, waiting, Date.now()))
      lastWaiting = pending.next
      if (options.notifySessionDone !== false && pending.added.length) $.ui.toast(waitingToastText(pending.added))
    }
  } catch { /* Session 提醒失敗不影響更新 */ }
  try {
    if (!script.ok) return
    if (quotaSignature === undefined) {
      try { quotaSignature = normalizeAlertSignature(await $.store.get(QUOTA_ALERT_KEY)) }
      catch { quotaSignature = null }
    }
    const previous = quotaSignature
    const result = quotaAlert(script.value.quota, previous)
    quotaSignature = result.signature
    if (result.signature !== previous) {
      try { await $.store.set(QUOTA_ALERT_KEY, result.signature) } catch { /* 保留記憶體中的簽章 */ }
    }
    if (result.alert && result.text !== null) $.ui.toast(result.text)
  } catch { /* 額度提醒失敗不影響更新 */ }
}

async function refresh($: Engine, options: BoardOptions, cwd?: string, isCwdChange = false, useCache = false): Promise<void> {
  if (isBusy) {
    if (isCwdChange && cwd) pendingCwd = cwd
    return
  }
  isBusy = true
  try {
    const now = new Date()
    await update($, refreshedAt, () => now.toISOString())
    await update($, isRefreshing, () => true)
    const startedAt = Date.now()
    const located: { current: CurrentRepo | null; branches: Set<string> | null; dataAt: number | null } = { current: null, branches: null, dataAt: null }
    const [script, sessions] = await Promise.all([
      (async () => {
        located.current = await locateCurrent($, cwd)
        const [outcome, branches] = await Promise.all([scriptResult($, options, located.current, startedAt, useCache), listFeatureBranches($, located.current)])
        located.branches = branches
        located.dataAt = outcome.dataAt
        return outcome.result
      })(),
      sessionResult($)
    ])
    void resolveSelfId($)
    if (located.dataAt !== null) await update($, refreshedAt, () => new Date(located.dataAt as number).toISOString())
    const waiting = await readWaiting($)
    void pruneWaiting($, waiting, sessions)
    let next: BoardSnapshot
    try { next = buildSnapshot(script, sessions, new Date(), located.current, located.branches, waiting) }
    catch (error) { next = errorSnapshot(message(error)) }
    await update($, snapshot, () => next)
    await notify($, options, script, sessions, waiting)
    try {
      const scoped = scopedSessions(script, sessions)
      const running = scoped === null ? null : scoped.filter(session => session.isRunning === true).length
      $.ui.status(statusText(running, script.ok ? lowestPrimary(script.value.quota) : null, next.waitingCount))
    } catch { /* 狀態列失敗不影響面板更新 */ }
  } finally {
    try { await update($, isRefreshing, () => false) } finally {
      isBusy = false
      const nextCwd = pendingCwd
      pendingCwd = null
      if (nextCwd) void refresh($, options, nextCwd, true)
    }
  }
}
async function refreshIfPlaced($: Engine, options: BoardOptions, cwd?: string, isCwdChange = false, useCache = false): Promise<void> {
  try {
    const panes = await $.ui.panes()
    if (panes.some(pane => pane.id === PANE && pane.isPlaced)) void refresh($, options, cwd, isCwdChange, useCache)
  } catch { /* 取不到 Pane 狀態時不更新 */ }
}

export const register: Register = (on, pluginOptions = {}) => {
  const options: BoardOptions = {
    workRoots: typeof pluginOptions.workRoots === 'string' ? pluginOptions.workRoots : undefined,
    scriptPath: typeof pluginOptions.scriptPath === 'string' ? pluginOptions.scriptPath : undefined,
    notifySessionDone: pluginOptions.notifySessionDone !== false
  }
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    sessionStartedAt = Date.now()
    void clearOwnWaiting($, sessionStartedAt)
    const opened = await $.ui.open({ id: PANE, title: '工作總覽' })
    if (opened.isPlaced) void refresh($, options)
    $.clock.every(REFRESH_MS, async () => {
      void refreshIfPlaced($, options, undefined, false, true)
    })
    return result
  })
  on('classic.PermissionRequest', async ($, e, next) => {
    markPermission($, e.tool_name)
    return next(e)
  })
  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)
    noteAsk(e.tool_use_id, verdict.decision)
    return verdict
  })
  on('tool.call', async ($, e, next) => {
    await startCall($, e.tool_use_id, e.tool)
    let result
    try { result = await next(e) } finally { await endCall($, e.tool_use_id) }
    return result
  })
  on('prompt.submit', async ($, e, next) => {
    forgetPendingCalls()
    await clearAllWaiting($)
    return next(e)
  })
  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId === undefined) forgetPendingCalls()
    if (e.agentId === undefined) await clearAllWaiting($)
    return result
  })
  on('session.end', async ($, e, next) => {
    await endSessionWaiting($)
    return next(e)
  })
  on('session.attach', async ($, e, next) => {
    if (e.surface === 'desktop') void refresh($, options)
    return next(e)
  })
  on('classic.CwdChanged', async ($, e, next) => {
    const result = await next(e)
    void refreshIfPlaced($, options, e.new_cwd, true)
    return result
  })
  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button, Link } = $.ui.resolve(e)
    const Svg = e.surface === 'desktop' ? $.ui.resolve(e).Svg : undefined
    const current = await read($, snapshot)
    const updated = await read($, refreshedAt)
    const busy = await read($, isRefreshing)
    const closed = await read($, collapsed) ?? await loadStored($)
    const openStalled = (await read($, expanded) ?? await loadStoredExpanded($)).includes('stalledLines')
    const shownLogins = await read($, loginShown)
    const storedCleanup = await read($, cleanup)
    const cleanupView = !cleanupBusy && (storedCleanup.phase === 'listing' || storedCleanup.phase === 'deleting') ? initialCleanup : storedCleanup
    const pendingClosed = normalizeClosedLines(await read($, cleanupClosedPending))
    const appliedClosed = normalizeClosedLines(await read($, cleanupClosedApplied))
    const closedChanged = pendingClosed.join(',') !== appliedClosed.join(',')
    const columns = e.props.bodyColumns
    const renderLogin = (login: BoardLogin) => {
      const mode = loginDisplayMode(LOGIN_COMMAND_MODE, login.command, shownLogins.includes(login.account))
      return <Box flexDirection="column">
        {mode === 'invalid' && <Text size="caption" dimColor>CodexHome 路徑含特殊字元，請手動登入</Text>}
        {(mode === 'copy' || mode === 'copy-and-text') && <Button key={`copy-login-${login.account}`} label="複製登入命令" plain dimColor onPress={press => copyLogin($, login, press.surface)} />}
        {(mode === 'text' || mode === 'copy-and-text') && <Text mono>{login.command}</Text>}
      </Box>
    }
    const renderRow = (keyPrefix: string, iconId: BlockId, item: BoardRow, index: number) => {
      const target = Svg && iconId === 'sessions' ? sessionOpenTarget(SESSION_OPEN_MODE, item.link) : null
      return <Box key={`row-${keyPrefix}-${index}`} flexDirection="row" gap="xs" paddingX="xs" backgroundColor={item.isCurrent ? CURRENT_BG : undefined} hover={{ backgroundColor: HOVER_BG }}>
        <Box flexDirection="row" flexShrink={0} height={1} alignSelf="flex-start" alignItems="center" gap="xs">
          {Svg && <Svg source={iconSvg(iconId)} alt={ICON_ALT[iconId]} width={ICON_SIZE} height={ICON_SIZE} />}
          <Text color={item.dot}>●</Text>
        </Box>
        <Box flexDirection="column" flexGrow={1} flexShrink={1} minWidth={0}>
          <Box flexDirection="row" gap="xs">
            <Box flexDirection="row" flexGrow={1} flexShrink={1} minWidth={0} gap="xs">
              <Box flexShrink={NAME_SHRINK} minWidth={0}>
                {target?.kind === 'process'
                  ? <Button key={`session-open-${index}`} label={item.name} plain onPress={() => openSession($, target.argv)} />
                  : <Text wrap="truncate-end" color={item.tone === 'error' ? 'error' : undefined} dimColor={item.tone === 'dim'}>{target?.kind === 'link' ? <Link href={target.href}>{item.name}</Link> : item.name}</Text>}
              </Box>
              {canShowNote(columns, item.name, item.tag, item.right) && <Box flexShrink={NOTE_SHRINK} minWidth={0}><Text size="footnote" dimColor wrap="truncate-end">{item.tag}</Text></Box>}
            </Box>
            {(item.right || item.bar) && <Box flexDirection="row" alignItems="center" gap="xs" minWidth={0} flexShrink={item.rightShrink ? NOTE_SHRINK : 0}>
              <Text size="footnote" dimColor wrap="truncate-end">{item.right}</Text>
              {item.bar && (Svg ? <Svg source={quotaBarSvg(item.bar.percent, item.bar.tone)} alt={`${item.bar.window ?? windowLabel(null)}${item.bar.percent === null ? '剩餘量未知' : `剩餘 ${item.bar.percent}%`}`} width={BAR_WIDTH} height={BAR_HEIGHT} /> : <Text color={item.bar.tone}>{quotaBarText(item.bar.percent)}</Text>)}
            </Box>}
          </Box>
          {item.detail && <Text size="caption" wrap="truncate-end">{item.detail.map((segment, i) => <Text key={String(i)} color={segment.tone === 'attention' ? 'warning' : undefined} dimColor={segment.tone === 'normal'}>{segment.text}</Text>)}</Text>}
          {item.extra && <Text size="caption" wrap="truncate-end">{item.extra.map((segment, i) => <Text key={String(i)} color={segment.tone === 'attention' ? 'warning' : undefined} dimColor={segment.tone === 'normal'}>{segment.text}</Text>)}</Text>}
          {item.login && renderLogin(item.login)}
        </Box>
      </Box>
    }
    const empty: Record<BlockId, string> = { sessions: '（沒有符合的 Session）', dispatch: '（沒有派工紀錄，派工開始後會列在這裡）', quota: '（沒有 Codex 帳號資料）', lines: '（沒有工作線）', workRoots: '（沒有工作目錄）' }
    const renderBlock = (id: BlockId, value: BoardBlock | undefined) => {
      const title = blockTitleText(id, value, closed.includes(id), id === 'lines' && openStalled)
      return <Box flexDirection="column" paddingY="xs">
        <Button key={`toggle-${id}`} label={title} plain dimColor onPress={() => void toggle($, id)}><Text size="footnote" weight="medium" dimColor>{title}</Text></Button>
        {!closed.includes(id) && <Box flexDirection="column" paddingLeft={2}>
          {value?.errorMessage && <Text color="error">{value.errorMessage}</Text>}
          {value && !value.errorMessage && value.rows.length === 0 && value.stalledRows.length === 0 && <Text dimColor>{empty[id]}{value.warning ? ' ' + value.warning : ''}</Text>}
          {value?.rows.map((item, index) => renderRow(id, id, item, index))}
          {id === 'lines' && value && value.stalledRows.length > 0 && <>
            <Button key="toggle-stalledLines" label={stalledToggleText(value.stalledRows.length, openStalled)} plain dimColor onPress={() => void toggleStalled($)}><Text size="footnote" dimColor>{stalledToggleText(value.stalledRows.length, openStalled)}</Text></Button>
            {openStalled && value.stalledRows.map((item, index) => renderRow('stalledLines', 'lines', item, index))}
          </>}
          {value && value.rows.length > 0 && value.warning && <Text dimColor>{value.warning}</Text>}
          {value && value.hiddenCount > 0 && <Text dimColor>另 {value.hiddenCount} 項未顯示</Text>}
          {id === 'dispatch' && current?.dispatchDetail && <Button key="copy-dispatch" label="複製診斷明細" plain dimColor onPress={press => copyDispatchDetail($, current.dispatchDetail, press.surface)} />}
        </Box>}
      </Box>
    }
    const renderCleanupRow = (item: CleanupItem, index: number) => <Box key={`cleanup-${item.status}-${index}`} flexDirection="row" gap="xs" paddingX="xs">
      <Text color={item.status === 'needs-review' ? 'warning' : 'inactive'}>●</Text>
      <Box flexDirection="column" flexGrow={1} flexShrink={1} minWidth={0}>
        <Box flexDirection="row" justifyContent="space-between" gap="xs">
          <Text wrap="truncate-end">{cleanupItemName(item)}</Text>
          <Text size="footnote" dimColor>{formatBytes(item.sizeBytes)}</Text>
        </Box>
        <Text size="caption" dimColor>{cleanupItemDetail(item)}</Text>
      </Box>
    </Box>
    const renderCleanup = () => {
      if (cleanupView.phase === 'idle') return null
      const plan = cleanupView.plan
      const groups = plan ? groupCleanupItems(plan.items) : null
      const summary = plan?.totals
      const closable = plan ? closableCleanupLines(plan.items, pendingClosed) : { shown: [], hidden: 0 }
      return <Box flexDirection="column" paddingY="xs">
        <Text size="footnote" weight="medium" dimColor>清理</Text>
        {cleanupView.phase === 'listing' && <Text dimColor>正在列出清理清單…</Text>}
        {cleanupView.phase === 'deleting' && <Text dimColor>正在清理…</Text>}
        {cleanupView.phase === 'listed' && plan && summary && groups && <Box flexDirection="column" paddingLeft={2}>
          <Text>可清理 {summary.cleanableCount} 項（{formatBytes(summary.cleanableBytes)}）· 待確認 {summary.needsReviewCount} 項 · 保留 {summary.protectedCount} 項</Text>
          {summary.cleanableCount === 0 && <Text dimColor>沒有可清理項目</Text>}
          {groups.cleanable.map(renderCleanupRow)}
          {groups.cleanableHidden > 0 && <Text dimColor>另 {groups.cleanableHidden} 項未顯示</Text>}
          {groups.review.map(renderCleanupRow)}
          {groups.reviewHidden > 0 && <Text dimColor>另 {groups.reviewHidden} 項待確認未顯示</Text>}
          {groups.protected.length > 0 && <Text dimColor>保留 {summary.protectedCount} 項：{groups.protected.map(item => `${item.reason} ${item.count} 項`).join('、')}</Text>}
          {plan.warnings.map((warning, index) => <Text key={`cleanup-warning-${index}`} color="warning">{warning}</Text>)}
          {(pendingClosed.length > 0 || closable.shown.length > 0) && <Box flexDirection="column" paddingY="xs">
            <Text size="footnote" weight="medium" dimColor>手動指定已結案的線（僅影響這次清理）</Text>
            {pendingClosed.map(slug => <Box key={`cleanup-closed-${slug}`} flexDirection="row" gap="xs">
              <Text wrap="truncate-end">{slug}</Text>
              <Button key={`cleanup-unmark-${slug}`} label="取消指定" plain dimColor onPress={() => toggleClosedLineSelection($, slug)} />
            </Box>)}
            {closedChanged && <Text color="warning">指定已變更，需重新列出後才能確認刪除</Text>}
            {closable.shown.map(line => <Box key={`cleanup-closable-${line.slug}`} flexDirection="row" gap="xs">
              <Text wrap="truncate-end">{line.slug}</Text>
              <Text size="caption" dimColor wrap="truncate-end">{line.reason}</Text>
              <Button key={`cleanup-mark-${line.slug}`} label="指定已結案" plain dimColor onPress={() => toggleClosedLineSelection($, line.slug)} />
            </Box>)}
            {closable.hidden > 0 && <Text dimColor>另 {closable.hidden} 條線未顯示</Text>}
          </Box>}
          <Box flexDirection="row" gap="xs">
            {summary.cleanableCount > 0 && !closedChanged && <Button key="cleanup-confirm" label={`確認刪除 ${summary.cleanableCount} 項（${formatBytes(summary.cleanableBytes)}）`} variant="primary" onPress={() => runCleanup($, options, true)} />}
            {closedChanged && <Button key="cleanup-relist" label="重新列出" onPress={() => runCleanup($, options, false)} />}
            <Button key="cleanup-cancel" label="取消" onPress={() => closeCleanup($)} />
          </Box>
        </Box>}
        {cleanupView.phase === 'done' && plan?.result && <Box flexDirection="column" paddingLeft={2}>
          <Text>已刪除 {plan.result.deleted.length} 項，釋出 {formatBytes(plan.result.freedBytes)}；失敗 {plan.result.failed.length} 項</Text>
          <Button key="cleanup-close" label="關閉" onPress={() => closeCleanup($)} />
        </Box>}
        {cleanupView.phase === 'error' && <Box flexDirection="column" paddingLeft={2}>
          <Text color="error">{cleanupView.message}</Text>
          <Box flexDirection="row" gap="xs">
            {cleanupView.message === '清單已變更，請重新列出' && <Button key="cleanup-retry" label="重新列出" onPress={() => runCleanup($, options, false)} />}
            <Button key="cleanup-close" label="關閉" onPress={() => closeCleanup($)} />
          </Box>
        </Box>}
      </Box>
    }
    return (
      <Box flexDirection="column">
        {current?.currentLabel && <Text size="footnote" dimColor wrap="truncate-end">{current.currentLabel}</Text>}
        {BLOCK_ORDER.map((id, index) => <Box key={id} flexDirection="column">
          {index > 0 && (Svg && DIVIDER_MODE === 'svg' ? <Svg source={DIVIDER_SVG} alt="分隔線" height={1} /> : <Text dimColor wrap="truncate-end">{dividerText(e.props.bodyColumns)}</Text>)}
          {renderBlock(id, current?.[id])}
        </Box>)}
        {renderCleanup()}
        <Box flexDirection="row" justifyContent="space-between" paddingTop="xs">
          <Text dimColor>最後更新 {updated ? new Date(updated).toLocaleTimeString('zh-TW', { hour12: false }) : '-'}{busy ? ' 更新中…' : ''}</Text>
          <Box flexDirection="row" gap="xs">
            {cleanupView.phase === 'idle' && <Button key="cleanup-open" label="清理…" plain dimColor onPress={() => runCleanup($, options, false, true)} />}
            <Button key="refresh" label={busy ? '更新中…' : '重新整理'} onPress={() => void refresh($, options)} />
          </Box>
        </Box>
      </Box>
    )
  })
}
