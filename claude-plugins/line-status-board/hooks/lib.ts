import type { BlockId, BoardBlock, BoardRow, BoardSnapshot, CleanupItem, CleanupPlan, DetailSegment, DotTone, ExpandId } from '../types'
import type { Engine } from 'claude-code'

export const REFRESH_MS = 60000
export const GIT_TIMEOUT_MS = 3000
export const SCRIPT_BUDGET_MS = 40000
export const CLEANUP_LIST_TIMEOUT_MS = 300000
export const CLEANUP_DELETE_TIMEOUT_MS = 600000
export const CLEANUP_LIST_LIMIT = 30
export const CLEANUP_REVIEW_LIMIT = 15
export const CLEANUP_LINE_LIMIT = 30
export const MAX_EXTRA_ROOTS = 64
export const BLOCK_IDS: BlockId[] = ['sessions', 'dispatch', 'lines', 'workRoots', 'quota']
export const STORE_KEY = 'collapsed-blocks'
export const BAR_WIDTH = 48
export const BAR_HEIGHT = 4
export const HOVER_BG = '#80808026'
export const STALE_MS = 3 * 24 * 60 * 60 * 1000
export const DIM_AFTER_MS = 24 * 60 * 60 * 1000
export const SESSION_LIMIT = 15
export const LINE_LIMIT = 12
export const QUOTA_OK_FROM = 50
export const QUOTA_WARN_FROM = 20
export const QUOTA_ALERT_BELOW = QUOTA_WARN_FROM
export const QUOTA_ALERT_KEY = 'quota-alert'
export const EXPAND_KEY = 'expanded-sections'
export const EXPAND_IDS: ExpandId[] = ['stalledLines']
export const BLOCK_ORDER: BlockId[] = ['sessions', 'dispatch', 'quota', 'lines', 'workRoots']
export const BLOCK_TITLES: Record<BlockId, string> = { sessions: 'Session', dispatch: '派工', quota: 'Codex 額度', lines: '工作線', workRoots: '工作目錄' }
export const TONE_HEX: Record<DotTone, string> = { success: '#3fb950', warning: '#d29922', error: '#f85149', inactive: '#808080' }
export const NAME_SHRINK = 1
export const NOTE_SHRINK = 8
export const CURRENT_BG = '#80808014'
export const ICON_SIZE = 14
export const DIVIDER_MODE: 'svg' | 'text' = 'svg'
export const LOGIN_COMMAND_MODE: 'copy' | 'text' = 'copy'
export const SESSION_LINK_PATTERN = /^claude:\/\/claude\.ai\/epitaxy\/[A-Za-z0-9_-]+$/
export const SESSION_OPEN_MODE: 'link' | 'process' | 'off' = 'process'
export function normalizeCollapsed(value: unknown): BlockId[] {
  return Array.isArray(value) ? BLOCK_IDS.filter(id => value.includes(id)) : []
}
export function toggleBlock(collapsed: BlockId[], id: BlockId): BlockId[] {
  return BLOCK_IDS.filter(item => item === id ? !collapsed.includes(item) : collapsed.includes(item))
}
export function normalizeExpanded(value: unknown): ExpandId[] {
  return Array.isArray(value) ? EXPAND_IDS.filter(id => value.includes(id)) : []
}
export function toggleExpanded(expanded: ExpandId[], id: ExpandId): ExpandId[] {
  return EXPAND_IDS.filter(item => item === id ? !expanded.includes(item) : expanded.includes(item))
}
export function dedupeLines(lines: Line[]): Line[] {
  const selected = new Map<string, Line>()
  for (const line of lines) {
    const previous = selected.get(line.LineSlug)
    if (!previous) { selected.set(line.LineSlug, line); continue }
    const timestamp = (value?: string | null) => { const parsed = Date.parse(value || ''); return Number.isNaN(parsed) ? -Infinity : parsed }
    const nextTime = timestamp(line.CheckpointUpdatedUtc)
    const previousTime = timestamp(previous.CheckpointUpdatedUtc)
    if (nextTime > previousTime || (nextTime === previousTime && !!previous.Error && !line.Error)) selected.set(line.LineSlug, line)
  }
  return [...selected.values()]
}
export function roundPercent(value: number | null | undefined): number | null {
  return value == null || !Number.isFinite(value) ? null : Math.min(100, Math.max(0, Math.round(value)))
}
export function toEpochMs(value: unknown): number | null {
  if (typeof value === 'string') {
    if (!value.trim()) return null
    if (/^\d+$/.test(value)) return toEpochMs(Number(value))
    const parsed = Date.parse(value)
    return Number.isNaN(parsed) ? null : parsed
  }
  if (typeof value !== 'number' || !Number.isFinite(value)) return null
  return value >= 1e11 ? value : value >= 1e9 ? value * 1000 : null
}
export function relativeTime(value: unknown, now: Date): string {
  const ts = toEpochMs(value)
  if (ts === null) return ''
  const diff = now.getTime() - ts
  if (diff < 60000) return '剛剛'
  if (diff < 3600000) return `${Math.floor(diff / 60000)} 分鐘前`
  if (diff < 86400000) return `${Math.floor(diff / 3600000)} 小時前`
  return `${Math.floor(diff / 86400000)} 天前`
}
export function isStalled(updatedMs: number | null, nowMs: number): boolean {
  return updatedMs !== null && nowMs - updatedMs > STALE_MS
}
export function sortSessionsByActivity(sessions: Session[]): Session[] {
  return [...sessions].sort((a, b) => (toEpochMs(b.lastActivityAt) ?? -Infinity) - (toEpochMs(a.lastActivityAt) ?? -Infinity))
}
export function quotaTone(percent: number | null): DotTone {
  return percent === null ? 'inactive' : percent >= QUOTA_OK_FROM ? 'inactive' : percent >= QUOTA_WARN_FROM ? 'warning' : 'error'
}
export function quotaDotTone(primary: number | null, secondary: number | null): DotTone {
  const values = [primary, secondary].filter((value): value is number => value !== null)
  return quotaTone(values.length ? Math.min(...values) : null)
}
export type NumberTone = 'normal' | 'attention'
export function sessionTone(isRunning: boolean | undefined): DotTone { return isRunning === true ? 'success' : 'inactive' }
export function lineTone(state: { hasError: boolean; isRunning: boolean }): DotTone {
  return state.hasError ? 'error' : state.isRunning ? 'success' : 'inactive'
}
export function lineNameTone(state: { hasError: boolean; updatedMs: number | null }, nowMs: number): 'normal' | 'error' | 'dim' {
  return state.hasError ? 'error' : state.updatedMs !== null && state.updatedMs < nowMs - DIM_AFTER_MS ? 'dim' : 'normal'
}
export function rootTone(root: Root): DotTone {
  return root.Error ? 'error' : (root.DirtyCount ?? 0) > 0 || (root.UpstreamAhead ?? 0) > 0 ? 'warning' : 'inactive'
}
export function numberTone(kind: 'dirty' | 'unpushed' | 'behind' | 'ahead' | 'weekly', value: number | null): NumberTone {
  return kind === 'ahead' ? 'normal' : kind === 'weekly' ? value !== null && value < QUOTA_OK_FROM ? 'attention' : 'normal' : value !== null && value > 0 ? 'attention' : 'normal'
}
export function rootDetail(root: Root): DetailSegment[] | null {
  const result: DetailSegment[] = []
  const add = (value: number | null | undefined, kind: 'dirty' | 'unpushed' | 'ahead' | 'behind', prefix: string, suffix: string) => {
    if (value == null || !Number.isFinite(value) || value <= 0) return
    if (result.length) result.push({ text: ' · ', tone: 'normal' })
    if (prefix) result.push({ text: prefix, tone: 'normal' })
    result.push({ text: String(value), tone: numberTone(kind, value) })
    if (suffix) result.push({ text: suffix, tone: 'normal' })
  }
  add(root.DirtyCount, 'dirty', '', ' 未 commit')
  add(root.UpstreamAhead, 'unpushed', '', ' 未 push')
  add(root.MainAhead, 'ahead', '領先 ', '')
  add(root.MainBehind, 'behind', '落後 ', '')
  return result.length ? result : null
}
export function quotaDetail(secondary: number | null, resetText: string | null): DetailSegment[] {
  if (secondary === null) return [{ text: '無週視窗', tone: 'normal' }]
  const result: DetailSegment[] = [{ text: '週 ', tone: 'normal' }, { text: `${secondary}%`, tone: numberTone('weekly', secondary) }]
  if (resetText) result.push({ text: ` · ${resetText} 重置`, tone: 'normal' })
  return result
}
export function checkpointLabel(raw: string | null | undefined): string {
  let value = (raw || '').replace(/`/g, '')
  let previous: string
  do { previous = value; value = value.replace(/（[^（）]*）|\([^()]*\)/g, '') } while (value !== previous)
  value = value.replace(/[（(].*$/, '').trim()
  if (!value) return '-'
  if (value.toLowerCase().startsWith('design-accepted')) return '設計驗收'
  if (value.toLowerCase().startsWith('developer-collected')) return 'Dev 回收'
  return clip(value, 12)
}
export function segmentsText(segments: DetailSegment[] | null): string { return segments?.map(item => item.text).join('') || '' }
export function quotaBarSvg(percent: number | null, tone: DotTone): string {
  const width = Math.round(BAR_WIDTH * (roundPercent(percent) ?? 0) / 100)
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${BAR_WIDTH}" height="${BAR_HEIGHT}" viewBox="0 0 ${BAR_WIDTH} ${BAR_HEIGHT}"><rect width="${BAR_WIDTH}" height="${BAR_HEIGHT}" rx="2" fill="#80808040"/>${width > 0 ? `<rect width="${width}" height="${BAR_HEIGHT}" rx="2" fill="${TONE_HEX[tone]}"/>` : ''}</svg>`
}
export function quotaBarText(percent: number | null): string {
  const filled = Math.round((roundPercent(percent) ?? 0) / 20)
  return '█'.repeat(filled) + '░'.repeat(5 - filled)
}
export function countText(id: BlockId, shown: number, total: number): string {
  const units: Record<BlockId, string> = { sessions: '個', dispatch: '筆', quota: '個帳號', lines: '條', workRoots: '個' }
  const unit = units[id]
  return `顯示 ${shown} ${unit}，共 ${total} ${unit}`
}
export function blockCounts(value: BoardBlock, stalledExpanded: boolean): { shown: number; total: number } {
  const stalled = value.stalledRows.length
  return { shown: value.rows.length + (stalledExpanded ? stalled : 0), total: value.rows.length + value.hiddenCount + stalled }
}
export function blockTitleText(id: BlockId, value: BoardBlock | undefined, isCollapsed: boolean, stalledExpanded: boolean): string {
  const counts = value && !value.errorMessage ? blockCounts(value, stalledExpanded) : null
  return `${BLOCK_TITLES[id]}${counts ? ' ' + countText(id, counts.shown, counts.total) : ''} ${isCollapsed ? '▸' : '▾'}`
}
export function stalledToggleText(count: number, expanded: boolean): string { return `已結束／停擺 ${count} 條 ${expanded ? '▾' : '▸'}` }
export const ICON_ALT: Record<BlockId, string> = { sessions: 'Session 圖示', dispatch: '派工圖示', quota: 'Codex 額度圖示', lines: '工作線圖示', workRoots: '工作目錄圖示' }
export function iconSvg(id: BlockId): string {
  const paths: Record<BlockId, string> = {
    sessions: '<path d="M3 2h8a1.5 1.5 0 0 1 1.5 1.5V8A1.5 1.5 0 0 1 11 9.5H7L4.5 12V9.5H3A1.5 1.5 0 0 1 1.5 8V3.5A1.5 1.5 0 0 1 3 2z"/>',
    dispatch: '<path d="M1.5 6.5l11-4.5-4 10.5-2-4.5z"/><path d="M6.5 8l6-6"/>',
    quota: '<path d="M2 10a5 5 0 0 1 10 0"/><path d="M7 10l2.5-3.5"/><circle cx="7" cy="10" r="0.8"/>',
    lines: '<circle cx="4" cy="3.5" r="1.5"/><circle cx="4" cy="10.5" r="1.5"/><circle cx="10" cy="5.5" r="1.5"/><path d="M4 5v4M10 7c0 2.2-2 2.8-5 2.9"/>',
    workRoots: '<path d="M1.5 3.5a1 1 0 0 1 1-1h3L7 4h4.5a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1h-9a1 1 0 0 1-1-1z"/>'
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${ICON_SIZE}" height="${ICON_SIZE}" viewBox="0 0 ${ICON_SIZE} ${ICON_SIZE}" fill="none" stroke="${TONE_HEX.inactive}" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round">${paths[id]}</svg>`
}
export const DIVIDER_SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1" viewBox="0 0 1000 1" preserveAspectRatio="none"><rect width="1000" height="1" fill="#80808059"/></svg>'
export function dividerText(columns: number | undefined): string { return '─'.repeat(Math.min(200, Math.max(10, Math.floor(columns ?? 40)))) }
export const DEFAULT_BODY_COLUMNS = 40
export const ROW_RESERVED_COLUMNS = 12
const WIDE_RANGES = [[0x1100, 0x115f], [0x2e80, 0x303e], [0x3041, 0x33ff], [0x3400, 0x4dbf], [0x4e00, 0x9fff], [0xa000, 0xa4cf], [0xac00, 0xd7a3], [0xf900, 0xfaff], [0xfe30, 0xfe4f], [0xff00, 0xff60], [0xffe0, 0xffe6], [0x20000, 0x2fffd], [0x30000, 0x3fffd]]
export function displayWidth(text: string): number {
  return Array.from(text).reduce((width, char) => {
    const code = char.codePointAt(0)!
    return width + (WIDE_RANGES.some(([start, end]) => code >= start && code <= end) ? 2 : 1)
  }, 0)
}
export function canShowNote(columns: number | undefined, name: string, note: string, right: string): boolean {
  if (!note) return false
  const available = columns !== undefined && Number.isFinite(columns) && columns > 0 ? Math.floor(columns) : DEFAULT_BODY_COLUMNS
  return ROW_RESERVED_COLUMNS + displayWidth(name) + displayWidth(note) + displayWidth(right) <= available
}
export type Result<T> = { ok: true; value: T } | { ok: false; error: string }
export type Session = { cwd?: unknown; isArchived?: boolean; isRunning?: boolean; name?: string; title?: string; sessionId?: string; lastActivityAt?: unknown; link?: unknown }
export type Line = { LineSlug: string; WorkRoot: string; CheckpointType?: string | null; CheckpointUpdatedUtc?: string | null; NextStepSummary?: string | null; Error?: string | null }
export type Root = { Path: string; IsLinkedWorktree?: boolean | null; Branch?: string | null; DirtyCount?: number | null; MainAhead?: number | null; MainBehind?: number | null; Upstream?: string | null; UpstreamAhead?: number | null; Error?: string | null }
export type Quota = { Name: string; State: string; CodexHome?: string | null; Error?: string | null; ErrorKind?: string | null; ErrorReason?: string | null; PrimaryRemaining?: number | null; SecondaryRemaining?: number | null; PrimaryResetsAtLocal?: string | null; SecondaryResetsAtLocal?: string | null; PrimaryWindowMinutes?: number | null }
export type Document = { scannedRoots: string[]; lines: Line[]; workRoots: Root[]; quota: Quota[]; warnings: string[]; dispatch?: Dispatch | null }
export type WorktreeEntry = { path: string; isBare: boolean }
export type GitProbe = { kind: 'failed' } | { kind: 'notRepo' } | { kind: 'repo'; topLevel: string; worktrees: WorktreeEntry[] | null }
export type CurrentRepo = { name: string; isGit: boolean; roots: string[]; forced: string[] }

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
function optional(value: unknown, kind: 'string' | 'number' | 'boolean'): boolean {
  return value == null || (typeof value === kind && (kind !== 'number' || (typeof value === 'number' && Number.isFinite(value))))
}
function isCount(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0
}
export async function scriptFileExists($: Engine, path: string): Promise<boolean> {
  try { await $.fs.stat(path); return true } catch { return false }
}
function isCleanupItem(value: unknown): value is CleanupItem {
  if (!isRecord(value)) return false
  return typeof value.id === 'string' && ['worktree', 'dispatchWorktree', 'lineArtifacts', 'backup'].includes(String(value.kind))
    && typeof value.root === 'string' && typeof value.path === 'string' && typeof value.name === 'string'
    && (value.lineSlug === null || typeof value.lineSlug === 'string') && (value.category === null || typeof value.category === 'string')
    && ['cleanable', 'needs-review', 'protected'].includes(String(value.status))
    && Array.isArray(value.reasons) && value.reasons.every(reason => typeof reason === 'string')
    && isCount(value.sizeBytes) && isCount(value.fileCount) && isCount(value.protectedFileCount)
    && (value.trackedChangeCount == null || isCount(value.trackedChangeCount))
    && (value.untrackedCount == null || isCount(value.untrackedCount))
}
function isCleanupTotals(value: unknown): value is CleanupPlan['totals'] {
  return isRecord(value) && isCount(value.cleanableCount) && isCount(value.cleanableBytes)
    && isCount(value.needsReviewCount) && isCount(value.protectedCount)
}
function isCleanupResult(value: unknown): value is NonNullable<CleanupPlan['result']> {
  return isRecord(value) && isCount(value.freedBytes)
    && Array.isArray(value.deleted) && value.deleted.every(item => isRecord(item) && typeof item.id === 'string' && isCount(item.bytes))
    && Array.isArray(value.failed) && value.failed.every(item => isRecord(item) && typeof item.id === 'string' && typeof item.reason === 'string')
}
function isLine(value: unknown): value is Line {
  return isRecord(value) && typeof value.LineSlug === 'string' && typeof value.WorkRoot === 'string'
    && ['CheckpointType', 'CheckpointUpdatedUtc', 'NextStepSummary', 'Error'].every(key => optional(value[key], 'string'))
}
function isRoot(value: unknown): value is Root {
  return isRecord(value) && typeof value.Path === 'string' && optional(value.IsLinkedWorktree, 'boolean')
    && ['Branch', 'Upstream', 'Error'].every(key => optional(value[key], 'string'))
    && ['DirtyCount', 'MainAhead', 'MainBehind', 'UpstreamAhead'].every(key => optional(value[key], 'number'))
}
function isQuota(value: unknown): value is Quota {
  return isRecord(value) && typeof value.Name === 'string' && typeof value.State === 'string'
    && ['CodexHome', 'Error', 'ErrorKind', 'ErrorReason', 'PrimaryResetsAtLocal', 'SecondaryResetsAtLocal'].every(key => optional(value[key], 'string'))
    && ['PrimaryRemaining', 'SecondaryRemaining', 'PrimaryWindowMinutes'].every(key => optional(value[key], 'number'))
}

export function normalizePath(path: string): string {
  const value = path.replace(/\//g, '\\').toLowerCase()
  return /^[a-z]:\\+$/.test(value) ? value.slice(0, 3) : value.replace(/\\+$/, '')
}
export function isDispatchWorktree(path: string): boolean {
  return isAbsoluteWindowsPath(toWindowsPath(path)) && (normalizePath(path) + '\\').includes('\\.local\\ai-sessions\\worktrees\\')
}

export function isUnder(path: string, root: string): boolean {
  const p = normalizePath(path)
  const r = normalizePath(root)
  return p === r || p.startsWith(r.endsWith('\\') ? r : r + '\\')
}

export function toWindowsPath(path: string): string {
  const value = path.trim().replace(/\//g, '\\')
  return /^[a-zA-Z]:\\+$/.test(value) ? value.slice(0, 3) : value.replace(/\\+$/, '')
}
export function isAbsoluteWindowsPath(path: string): boolean {
  return /^[a-zA-Z]:\\/.test(path) || path.startsWith('\\\\')
}
export function leafName(path: string): string {
  if (/^[a-zA-Z]:[\\/]+$/.test(path)) return path
  return path.replace(/[\\/]+$/, '').split(/[\\/]/).pop() || path
}
export function parseWorktreeList(stdout: string): WorktreeEntry[] {
  const entries: WorktreeEntry[] = []
  let current: WorktreeEntry | null = null
  for (const line of stdout.split(/\r?\n/)) {
    if (line.startsWith('worktree ')) {
      const path = toWindowsPath(line.slice(9))
      current = isAbsoluteWindowsPath(path) ? { path, isBare: false } : null
      if (current) entries.push(current)
    } else if (line === 'bare' && current) current.isBare = true
  }
  return entries
}
export function splitRoots(value?: string): string[] {
  return (value || '').split(';').map(item => item.trim()).filter(Boolean)
}
// 與 scripts/Get-LineStatus.ps1 的預設 work-root 清單保持同步。
export function defaultWorkRoots(profile: string | null): string[] {
  if (!profile) return []
  const base = toWindowsPath(profile)
  return [`${base}\\.ai-agents`, `${base}\\.ai-agents.wt\\*`, `${base}\\.ai-agents\\.claude\\worktrees\\*`, 'D:\\Programming\\Projects\\.claude-worktrees\\.ai-agents\\*']
}
export function coversPath(entry: string, path: string): boolean {
  const e = normalizePath(entry)
  const p = normalizePath(path)
  if (e === p) return true
  if (!e.endsWith('\\*')) return false
  let prefix = e.slice(0, -2)
  if (/[*?\[\]]/.test(prefix)) return false
  if (/^[a-z]:$/.test(prefix)) prefix += '\\'
  let parent = p.slice(0, p.lastIndexOf('\\'))
  if (/^[a-z]:$/.test(parent)) parent += '\\'
  return parent === prefix
}
export function buildWorkRootArgument(configured: string | undefined, profile: string | null, current: CurrentRepo | null): string | null {
  const config = splitRoots(configured)
  const original = config.length ? configured!.trim() : null
  if (!current || !current.roots.length) return original
  if (!config.length && !profile) return null
  const base = config.length ? config : defaultWorkRoots(profile)
  const added: string[] = []
  const seen = new Set<string>()
  for (const path of current.roots) {
    const key = normalizePath(path)
    if (path.includes(';') || seen.has(key) || base.some(entry => coversPath(entry, path))) continue
    seen.add(key)
    added.push(path)
    if (added.length === MAX_EXTRA_ROOTS) break
  }
  if (!added.length) return original
  return [...base, ...added.map(path => path.replace(/[\[\]]/g, match => '`' + match))].join(';')
}
export function buildForceWorkRootArgument(current: CurrentRepo | null): string | null {
  const seen = new Set<string>()
  const paths = (current?.forced || []).filter(path => {
    const key = normalizePath(path)
    if (path.includes(';') || seen.has(key)) return false
    seen.add(key)
    return true
  })
  return paths.length ? paths.join(';') : null
}
export function resolveCurrentRepo(cwd: string | null, probe: GitProbe): CurrentRepo | null {
  if (!cwd || !isAbsoluteWindowsPath(toWindowsPath(cwd)) || probe.kind === 'failed') return null
  const path = toWindowsPath(cwd)
  if (probe.kind === 'notRepo') return { name: leafName(path), isGit: false, roots: isDispatchWorktree(path) ? [] : [path], forced: isDispatchWorktree(path) ? [] : [path] }
  const top = toWindowsPath(probe.topLevel)
  if (!isAbsoluteWindowsPath(top)) return null
  const entries = probe.worktrees || []
  const unique = (paths: string[]) => paths.filter((item, index) => paths.findIndex(other => normalizePath(other) === normalizePath(item)) === index)
  const roots = unique([...entries.filter(entry => !entry.isBare).map(entry => toWindowsPath(entry.path)), top]).filter(path => !isDispatchWorktree(path))
  const forced = unique([...(entries[0] && !entries[0].isBare ? [toWindowsPath(entries[0].path)] : []), top]).filter(path => !isDispatchWorktree(path))
  return { name: leafName(entries[0]?.path || top), isGit: true, roots, forced }
}
export function orderWorkRoots(roots: Root[], current: CurrentRepo | null): Root[] {
  if (!current) return [...roots]
  const rank = (root: Root) => current.roots.findIndex(path => normalizePath(path) === normalizePath(root.Path))
  return [...roots].sort((a, b) => {
    const left = rank(a), right = rank(b)
    return (left < 0 ? Infinity : left) - (right < 0 ? Infinity : right) || 0
  })
}
export function currentLabel(current: CurrentRepo | null): string | null {
  return current ? `目前：${current.name}${current.isGit ? '' : '（非 Git）'}` : null
}
export function remainingBudgetMs(totalMs: number, elapsedMs: number): number {
  return Math.max(1000, totalMs - Math.max(0, elapsedMs))
}

export function parseScriptOutput(stdout: string): Result<Document> {
  try {
    const start = stdout.indexOf('{')
    const end = stdout.lastIndexOf('}')
    if (start < 0 || end < start) throw new Error('找不到 JSON')
    const value: unknown = JSON.parse(stdout.slice(start, end + 1))
    if (!isRecord(value) || !Array.isArray(value.scannedRoots)) throw new Error('缺少 scannedRoots')
    if (!value.scannedRoots.every(item => typeof item === 'string') || !Array.isArray(value.lines) || !Array.isArray(value.workRoots) || !Array.isArray(value.quota)) throw new Error('腳本資料格式錯誤')
    return { ok: true, value: { scannedRoots: value.scannedRoots, lines: value.lines.filter(isLine), workRoots: value.workRoots.filter(isRoot), quota: value.quota.filter(isQuota), warnings: Array.isArray(value.warnings) ? value.warnings.filter((item): item is string => typeof item === 'string') : [], dispatch: parseDispatch(value.dispatch) } }
  } catch (error) {
    return { ok: false, error: String(error instanceof Error ? error.message : error).slice(0, 120) }
  }
}

export function parseCleanupOutput(stdout: string): Result<CleanupPlan> {
  try {
    const value: unknown = JSON.parse(stdout)
    if (!isRecord(value) || value.schema !== 'ai-agents.work-overview-cleanup.v1' || !Array.isArray(value.items)
      || typeof value.planId !== 'string' || !value.planId || (value.mode !== 'list' && value.mode !== 'delete')
      || typeof value.generatedAtUtc !== 'string' || typeof value.sessionsKnown !== 'boolean' || !isCleanupTotals(value.totals)
      || !Array.isArray(value.warnings) || !value.warnings.every(item => typeof item === 'string')
      || (value.result !== null && !isCleanupResult(value.result)) || (value.mode === 'delete' && value.result === null)) {
      throw new Error('清理腳本資料格式錯誤')
    }
    return { ok: true, value: { schema: value.schema, mode: value.mode, generatedAtUtc: value.generatedAtUtc, planId: value.planId,
      sessionsKnown: value.sessionsKnown, items: value.items.filter(isCleanupItem), totals: value.totals, warnings: value.warnings, result: value.result } }
  } catch (error) {
    return { ok: false, error: String(error instanceof Error ? error.message : error).split(/\r?\n/)[0].slice(0, 120) }
  }
}

export function formatBytes(value: number): string {
  let size = value
  for (const unit of ['B', 'KB', 'MB']) {
    const rounded = Math.round(size)
    if (rounded < 1024) return `${rounded} ${unit}`
    size /= 1024
  }
  return `${size.toFixed(1)} GB`
}

export function groupCleanupItems(items: CleanupItem[]): { cleanable: CleanupItem[]; cleanableHidden: number; review: CleanupItem[]; reviewHidden: number; protected: { reason: string; count: number }[] } {
  const cleanable = items.filter(item => item.status === 'cleanable').sort((a, b) => b.sizeBytes - a.sizeBytes)
  const review = items.filter(item => item.status === 'needs-review')
  const reasons = new Map<string, number>()
  for (const item of items) {
    if (item.status === 'protected') {
      const reason = item.reasons[0] || '未提供原因'
      reasons.set(reason, (reasons.get(reason) ?? 0) + 1)
    }
  }
  return { cleanable: cleanable.slice(0, CLEANUP_LIST_LIMIT), cleanableHidden: Math.max(0, cleanable.length - CLEANUP_LIST_LIMIT),
    review: review.slice(0, CLEANUP_REVIEW_LIMIT), reviewHidden: Math.max(0, review.length - CLEANUP_REVIEW_LIMIT),
    protected: [...reasons].map(([reason, count]) => ({ reason, count })) }
}

const LINE_SLUG = /^[a-z0-9]+(?:-[a-z0-9]+)*$/

export function normalizeClosedLines(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return [...new Set(value.filter((item): item is string => typeof item === 'string' && LINE_SLUG.test(item)))].sort()
}

export function toggleClosedLine(lines: string[], slug: string): string[] {
  const current = normalizeClosedLines(lines)
  if (!LINE_SLUG.test(slug)) return current
  return current.includes(slug) ? current.filter(item => item !== slug) : normalizeClosedLines([...current, slug])
}

export function closedLineArgument(lines: string[]): string | null {
  const normalized = normalizeClosedLines(lines)
  return normalized.length ? normalized.join(',') : null
}

export function closableCleanupLines(items: CleanupItem[], designated: string[]): { shown: { slug: string; reason: string }[]; hidden: number } {
  const chosen = new Set(designated)
  const seen = new Set<string>()
  const lines: { slug: string; reason: string }[] = []
  for (const item of items) {
    if (item.kind !== 'lineArtifacts' || item.category !== 'all' || item.status !== 'protected' || !item.lineSlug) continue
    if (!LINE_SLUG.test(item.lineSlug) || chosen.has(item.lineSlug) || seen.has(item.lineSlug)) continue
    if (item.reasons.some(reason => reason.includes('Session'))) continue
    seen.add(item.lineSlug)
    lines.push({ slug: item.lineSlug, reason: item.reasons[0] || '未提供原因' })
  }
  lines.sort((a, b) => a.slug.localeCompare(b.slug))
  return { shown: lines.slice(0, CLEANUP_LINE_LIMIT), hidden: Math.max(0, lines.length - CLEANUP_LINE_LIMIT) }
}

export function cleanupItemName(item: CleanupItem): string {
  if (item.kind === 'worktree') return `工作目錄 ${item.name}`
  if (item.kind === 'dispatchWorktree') {
    const slug = item.lineSlug
    if (!slug) return `派工 ${item.name}`
    const suffix = `（${slug}）`
    return `派工 ${item.name.endsWith(suffix) ? item.name.slice(0, -suffix.length) : item.name}${suffix}`
  }
  if (item.kind === 'backup') return `備份 ${item.name}`
  const label = item.category === 'history' ? '歷史' : item.category === 'handoff-extras' ? '交接暫存' : item.category === 'report-logs' ? '報告大檔' : '工作線'
  return `${item.lineSlug || item.name} · ${label}`
}

export function cleanupItemDetail(item: CleanupItem): string {
  const parts: string[] = []
  if (item.kind === 'worktree' || item.kind === 'dispatchWorktree') {
    parts.push(item.trackedChangeCount == null || item.untrackedCount == null ? '改動數無法取得' : `未 commit 改動 ${item.trackedChangeCount} 個、未追蹤 ${item.untrackedCount} 個`)
  }
  parts.push(item.reasons.length ? item.reasons.join('；') : `${item.fileCount} 個檔案`)
  return parts.join('；')
}

export function parseSessions(result: unknown): Result<Session[]> {
  try {
    if (!result || typeof result !== 'object') throw new Error('MCP 回應格式錯誤')
    const response = result as { isError?: boolean; structuredContent?: unknown; content?: { type: string; text?: string }[] }
    if (response.isError) throw new Error(response.content?.find(item => item.type === 'text')?.text || 'MCP 呼叫失敗')
    let body = response.structuredContent
    if (body == null) body = JSON.parse((response.content || []).filter(item => item.type === 'text').map(item => item.text || '').join('\n'))
    if (body && typeof body === 'object' && !Array.isArray(body) && 'sessions' in body) body = body.sessions
    if (!Array.isArray(body)) throw new Error('MCP Session 資料不是陣列')
    return { ok: true, value: body.filter(item => item && typeof item === 'object') }
  } catch (error) {
    return { ok: false, error: String(error instanceof Error ? error.message : error).slice(0, 120) }
  }
}

export function filterSessions(sessions: Session[], roots: string[]): Session[] {
  return sessions.filter(session => typeof session.cwd === 'string' && session.isArchived !== true && roots.some(root => isUnder(session.cwd as string, root)))
}
export function sessionLink(session: Session): string | null {
  return typeof session.link === 'string' && SESSION_LINK_PATTERN.exec(session.link)?.[0] === session.link ? session.link : null
}
export function sessionOpenTarget(mode: 'link' | 'process' | 'off', link: string | null): { kind: 'link'; href: string } | { kind: 'process'; argv: string[] } | null {
  if (mode === 'off' || link === null) return null
  return mode === 'link' ? { kind: 'link', href: link } : { kind: 'process', argv: ['explorer.exe', link] }
}
export function scopedSessions(script: Result<Document>, sessions: Result<Session[]>): Session[] | null {
  return script.ok && sessions.ok ? filterSessions(sessions.value, script.value.scannedRoots) : null
}
const DEFAULT_WINDOW_LABEL = '5 小時'
function isWindowMinutes(minutes: number | null | undefined): minutes is number {
  return typeof minutes === 'number' && Number.isInteger(minutes) && minutes > 0
}
export function windowLabel(minutes: number | null | undefined): string {
  if (!isWindowMinutes(minutes)) return DEFAULT_WINDOW_LABEL
  if (minutes % 1440 === 0) return `${minutes / 1440} 天`
  if (minutes % 60 === 0) return `${minutes / 60} 小時`
  return `${minutes} 分鐘`
}
export function lowestPrimary(quota: Quota[]): number | null {
  const values = quota.filter(account => account.State === 'ok').map(account => roundPercent(account.PrimaryRemaining)).filter((value): value is number => value !== null)
  return values.length ? Math.min(...values) : null
}
export function statusText(running: number | null, lowest: number | null, waiting = 0): string | undefined {
  const parts = [waiting > 0 ? `${waiting} 等你` : '', running === null ? '' : `${running} 執行中`, lowest === null ? '' : `額度 ${lowest}%`].filter(Boolean)
  return parts.length ? parts.join(' · ') : undefined
}

export function finishedSessions(previous: ReadonlyMap<string, boolean> | null, current: Session[]): { next: Map<string, boolean>; finished: string[] } {
  const next = new Map<string, boolean>()
  const finished: string[] = []
  for (const session of current) {
    const id = session.sessionId
    if (!id) continue
    const running = session.isRunning === true
    next.set(id, running)
    if (previous?.get(id) === true && !running) finished.push(session.title || session.name || id)
  }
  return { next, finished }
}
export function finishedToastText(titles: string[]): string {
  const displayed = titles.slice(0, 3).map(title => clip(title, 30))
  return titles.length === 1 ? `「${displayed[0]}」已跑完` : `${titles.length} 個 Session 已跑完：${displayed.join('、')}${titles.length > 3 ? '…' : ''}`
}

type QuotaAlertAccount = { name: string; kind: 'high' | 'low' | 'limit' | 'login' | 'unknown'; percent: number | null; token: string; window: string | null }
function quotaAlertAccount(account: Quota): QuotaAlertAccount {
  const percent = account.State === 'ok' ? roundPercent(account.PrimaryRemaining) : null
  if (percent !== null) return { name: account.Name, kind: percent >= QUOTA_ALERT_BELOW ? 'high' : 'low', percent, token: account.PrimaryResetsAtLocal ?? '', window: account.State === 'ok' && isWindowMinutes(account.PrimaryWindowMinutes) ? windowLabel(account.PrimaryWindowMinutes) : null }
  if (account.ErrorKind === 'limit-reached') return { name: account.Name, kind: 'limit', percent: null, token: '*', window: null }
  if (account.ErrorKind === 'auth-expired') return { name: account.Name, kind: 'login', percent: null, token: '*', window: null }
  return { name: account.Name, kind: 'unknown', percent: null, token: '', window: null }
}
function parseAlertSignature(value: string): Map<string, string> | null {
  const accounts = new Map<string, string>()
  for (const part of value.split('|')) {
    const separator = part.lastIndexOf('@')
    if (separator < 1) return null
    const name = part.slice(0, separator)
    if (accounts.has(name)) return null
    accounts.set(name, part.slice(separator + 1))
  }
  return accounts.size ? accounts : null
}
export function normalizeAlertSignature(value: unknown): string | null {
  return typeof value === 'string' && parseAlertSignature(value) !== null ? value : null
}
function sameWindow(previous: string, current: string): boolean {
  const before = parseAlertSignature(previous)
  const after = parseAlertSignature(current)
  if (!before || !after || before.size !== after.size) return false
  for (const [name, token] of before) {
    const next = after.get(name)
    if (next === undefined || (token !== next && token !== '*' && next !== '*')) return false
  }
  return true
}
export function quotaAlert(quota: Quota[], previous: string | null): { alert: boolean; signature: string | null; text: string | null } {
  if (!quota.length) return { alert: false, signature: null, text: null }
  const accounts = quota.map(quotaAlertAccount).sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
  if (accounts.some(account => account.kind === 'high')) return { alert: false, signature: null, text: null }
  if (accounts.some(account => account.kind === 'unknown')) return { alert: false, signature: previous, text: null }
  const current = accounts.map(account => `${account.name}@${account.token}`).join('|')
  if (previous !== null && sameWindow(previous, current)) return { alert: false, signature: previous, text: null }
  const windows = new Set(accounts.map(account => account.window).filter((window): window is string => window !== null))
  const mixed = windows.size > 1
  const details = accounts.map(account => account.kind === 'low' ? `${account.name} 剩 ${account.percent}%${mixed && account.window !== null ? `（${account.window}）` : ''}` : account.kind === 'limit' ? `${account.name} 已達上限` : `${account.name} 登入失效`)
  const label = mixed ? '' : (windows.values().next().value ?? DEFAULT_WINDOW_LABEL)
  return { alert: true, signature: current, text: `Codex ${label}額度：${details.join('、')}` }
}

export function mapSessionToLine(session: Session, document: Document): string | null {
  const named = document.lines.find(line => session.name && line.LineSlug === session.name)
  if (named) return named.LineSlug
  if (typeof session.cwd !== 'string') return null
  const cwd = session.cwd
  const root = document.scannedRoots.filter(item => isUnder(cwd, item)).sort((a, b) => normalizePath(b).length - normalizePath(a).length)[0]
  if (!root || !document.workRoots.some(item => normalizePath(item.Path) === normalizePath(root) && item.IsLinkedWorktree === true)) return null
  const lines = document.lines.filter(line => normalizePath(line.WorkRoot) === normalizePath(root))
  return lines.length === 1 ? lines[0].LineSlug : null
}

const row = (name: string, fields: Partial<Omit<BoardRow, 'name'>> = {}): BoardRow => ({ name, tag: '', right: '', rightShrink: false, dot: 'inactive', detail: null, bar: null, tone: 'normal', isCurrent: false, link: null, login: null, ...fields })
const block = (rows: BoardRow[], limit = rows.length, stalledRows: BoardRow[] = []): BoardBlock => ({ rows: rows.slice(0, limit), stalledRows, hiddenCount: Math.max(0, rows.length - limit), errorMessage: null })
const errorBlock = (message: string): BoardBlock => ({ rows: [], stalledRows: [], hiddenCount: 0, errorMessage: message })
export function errorSnapshot(message: string): BoardSnapshot {
  return { sessions: errorBlock(message), dispatch: errorBlock(message), lines: errorBlock(message), workRoots: errorBlock(message), quota: errorBlock(message), currentLabel: null, scannedRoots: [], waitingCount: 0, dispatchDetail: null }
}
const clip = (value: string, limit: number): string => Array.from(value).length > limit ? Array.from(value).slice(0, limit).join('') + '…' : value
export function loginCommand(codexHome: unknown): string | null {
  return typeof codexHome === 'string' && /^[A-Za-z]:\\[^"`$;\r\n]+$/.test(codexHome)
    ? `$env:CODEX_HOME = "${codexHome}"; codex login; Remove-Item Env:CODEX_HOME`
    : null
}
export function loginDisplayMode(mode: 'copy' | 'text', command: string | null, shown: boolean): 'invalid' | 'copy' | 'text' | 'copy-and-text' {
  return command === null ? 'invalid' : mode === 'text' ? 'text' : shown ? 'copy-and-text' : 'copy'
}
export function quotaErrorRow(account: Quota): BoardRow {
  if (account.ErrorKind === 'auth-expired') return row(`${account.Name} · 登入失效`, { tone: 'error', dot: 'error', login: { account: account.Name, command: loginCommand(account.CodexHome) } })
  if (account.ErrorKind === 'limit-reached') return row(`${account.Name} · 已達上限`, { tone: 'error', dot: 'error' })
  const fallback = (account.Error || '').replace(/^exit \d+[：:]\s*/i, '').replace(/^Get-CodexQuota\.ps1 \S+[：:]\s*/i, '').split(/\r?\n/)[0].trim()
  const candidate = account.ErrorReason?.trim() || fallback
  const reason = !candidate || /^exit\s+\d+$/i.test(candidate) ? '原因不明' : candidate
  return row(`${account.Name} · 無法取得：${clip(reason, 40)}`, { tone: 'error', dot: 'error' })
}
const time = (value?: string | null): string => {
  if (!value) return '-'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value.replace(/^\d{4}-/, '').slice(0, 11)
  const pad = (v: number) => String(v).padStart(2, '0')
  return `${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`
}
export type LandedContext = { rawLines: Line[]; workRoots: Root[]; currentRoots: string[]; branches: ReadonlySet<string> | null }
export function parseFeatureBranches(stdout: string): Set<string> {
  return new Set(stdout.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '').split(/\r?\n/).map(line => line.replace(/^\s*[*+]?\s*/, '').trim()).filter(line => line.startsWith('feature/')))
}
export function isLanded(line: Line, context: LandedContext): boolean {
  if (line.Error || context.branches === null || checkpointLabel(line.CheckpointType) !== 'Dev 回收') return false
  const roots = new Set(context.currentRoots.map(normalizePath))
  if (!roots.has(normalizePath(line.WorkRoot))) return false
  const matches = new Set(context.rawLines.filter(item => item.LineSlug === line.LineSlug && roots.has(normalizePath(item.WorkRoot))).map(item => normalizePath(item.WorkRoot)))
  return matches.size >= 2 && context.workRoots.some(root => root.IsLinkedWorktree === false && matches.has(normalizePath(root.Path))) && !context.branches.has('feature/' + line.LineSlug)
}
export function lineRightText(type: string | null | undefined, timeText: string): string {
  const label = checkpointLabel(type)
  return [label === 'Dev 回收' || label === '-' ? '' : label, timeText].filter(Boolean).join(' · ')
}
export function buildSnapshot(script: Result<Document>, sessions: Result<Session[]>, now: Date, current: CurrentRepo | null = null, branches: ReadonlySet<string> | null = null, waiting: WaitingEntry[] = []): BoardSnapshot {
  if (!script.ok) return { sessions: errorBlock('無法判定掃描範圍'), dispatch: errorBlock(script.error), lines: errorBlock(script.error), workRoots: errorBlock(script.error), quota: errorBlock(script.error), currentLabel: currentLabel(current), scannedRoots: [], waitingCount: 0, dispatchDetail: null }
  const data = script.value
  const filtered = scopedSessions(script, sessions) ?? []
  const running = new Set(filtered.filter(session => session.isRunning === true).map(session => mapSessionToLine(session, data)).filter((slug): slug is string => slug !== null))
  const waitingItems = sessions.ok ? scopedWaiting(filtered, waiting, now.getTime()) : []
  const activeWaiting = waitingItems.filter(item => item.state === 'active')
  const waitingBySession = new Map(waitingItems.map(item => [item.entry.sessionId, item]))
  const activeIds = new Set(activeWaiting.map(item => item.entry.sessionId))
  const orderedSessions = [...activeWaiting.map(item => item.session), ...sortSessionsByActivity(filtered).filter(session => !session.sessionId || !activeIds.has(session.sessionId))]
  const sessionBlock = !sessions.ok ? errorBlock(sessions.error) : block(orderedSessions.map(session => {
    const title = session.title || session.name || session.sessionId || '-'
    const line = mapSessionToLine(session, data)
    const item = session.sessionId ? waitingBySession.get(session.sessionId) : undefined
    if (item?.state === 'active') return row(title, { dot: 'warning', tag: line || '', right: `${waitingText(item.entry)} · ${relativeTime(item.entry.at, now)}`, rightShrink: true, link: sessionLink(session) })
    if (item?.state === 'stale') return row(title, { dot: 'inactive', tag: line || '', right: staleWaitingText(item.entry, now), rightShrink: true, link: sessionLink(session) })
    return row(title, { dot: sessionTone(session.isRunning), tag: line || '', right: relativeTime(session.lastActivityAt, now), link: sessionLink(session) })
  }), SESSION_LIMIT)
  const dispatch = data.dispatch ?? null
  const normalLines: BoardRow[] = []
  const stalledLines: BoardRow[] = []
  const landedContext: LandedContext = { rawLines: data.lines, workRoots: data.workRoots, currentRoots: current?.roots ?? [], branches }
  dedupeLines(data.lines.filter(line => line.CheckpointType || line.CheckpointUpdatedUtc || line.Error || data.workRoots.some(root => root.IsLinkedWorktree && normalizePath(root.Path) === normalizePath(line.WorkRoot))))
    .sort((a, b) => (b.CheckpointUpdatedUtc || '').localeCompare(a.CheckpointUpdatedUtc || '') || a.LineSlug.localeCompare(b.LineSlug))
    .forEach(line => {
      if (line.Error) { normalLines.push(row(`${line.LineSlug} · ${line.Error}`, { tone: 'error', dot: 'error' })); return }
      const updatedMs = toEpochMs(line.CheckpointUpdatedUtc)
      const dot = lineTone({ hasError: false, isRunning: running.has(line.LineSlug) })
      const tone = lineNameTone({ hasError: false, updatedMs }, now.getTime())
      const item = !line.CheckpointType && !line.CheckpointUpdatedUtc
        ? row(line.LineSlug, { dot, tone, right: '無檢查點' })
        : row(line.LineSlug, { dot, tone, right: lineRightText(line.CheckpointType, relativeTime(line.CheckpointUpdatedUtc, now)) })
      const target = !running.has(line.LineSlug) && (isStalled(updatedMs, now.getTime()) || isLanded(line, landedContext)) ? stalledLines : normalLines
      target.push(item)
    })
  const roots = orderWorkRoots(data.workRoots.filter(root => !isDispatchWorktree(root.Path)), current).map(root => {
    const name = leafName(root.Path)
    if (root.Error) return row(`${name} · ${root.Error}`, { tone: 'error', dot: 'error', isCurrent: current !== null && current.roots.some(path => normalizePath(path) === normalizePath(root.Path)) })
    return row(name, { dot: rootTone(root), right: root.Branch || '-', rightShrink: true, detail: rootDetail(root), isCurrent: current !== null && current.roots.some(path => normalizePath(path) === normalizePath(root.Path)) })
  })
  const quota = data.quota.map(account => {
    const extra = accountExtra(findDispatchAccount(dispatch, account.Name), now)
    if (account.State === 'unknown') return { ...quotaErrorRow(account), extra }
    const primary = roundPercent(account.PrimaryRemaining)
    const secondary = roundPercent(account.SecondaryRemaining)
    return row(account.Name, { dot: quotaDotTone(primary, secondary), right: primary === null ? '-' : `剩 ${primary}%`, bar: { percent: primary, tone: quotaTone(primary), window: windowLabel(account.PrimaryWindowMinutes) }, detail: quotaDetail(secondary, account.SecondaryResetsAtLocal ? time(account.SecondaryResetsAtLocal) : null), extra })
  })
  const quotaBlock = block(quota)
  if (data.warnings.length) quotaBlock.warning = data.warnings.join(' / ')
  return { sessions: sessionBlock, dispatch: dispatchBlock(dispatch, now), lines: block(normalLines, LINE_LIMIT, stalledLines), workRoots: block(roots), quota: quotaBlock, currentLabel: currentLabel(current), scannedRoots: data.scannedRoots, waitingCount: activeWaiting.length, dispatchDetail: dispatchDetailText(dispatch, waitingDiagnostics(waiting, sessions.ok ? sessions.value : [], now.getTime())) }
}

export const DISPATCH_ENDED_LIMIT = 5
export const WAITING_PREFIX = 'waiting:'
export const SCRIPT_CACHE_KEY = 'script-cache'
// 等待標示最多保留 24 小時，與淡化舊資料的門檻相同；超過即視為失效並由讀取端刪除。
export const WAITING_MAX_AGE_MS = DIM_AFTER_MS
// 寫入時間晚於讀取時間超過一個更新週期，視為時鐘不一致而不採信。
export const WAITING_FUTURE_TOLERANCE_MS = REFRESH_MS
export const WAITING_TOOL_NAMES = ['Bash', 'PowerShell', 'Write', 'Edit', 'NotebookEdit', 'Read', 'Glob', 'Grep', 'WebFetch', 'WebSearch', 'Agent', 'Skill']
export type DispatchRun = { RunKey: string; LineSlug: string; State: string; LimitSource?: string | null; DispatchSlug?: string | null; TaskType?: string | null; Profile?: string | null; Account?: string | null; Model?: string | null; WorkRoot?: string | null; StartedUtc?: string | null; EndedUtc?: string | null; LastEventUtc?: string | null; RecordUpdatedUtc?: string | null; DurationSeconds?: number | null; Result?: string | null; FailureReason?: string | null; RejectionKind?: string | null; TerminatedByEntry?: string | null; Error?: string | null }
export type DispatchUnsupported = { Profile?: string | null; Model?: string | null }
export type DispatchAccount = { Name: string; LastResult?: string | null; LastFailureReason?: string | null; LastRejectionKind?: string | null; LastEndedUtc?: string | null; Unsupported: DispatchUnsupported[] }
export type Dispatch = { runs: DispatchRun[]; accounts: DispatchAccount[]; totalCount: number; warnings: string[]; error: string | null; errorDetail?: string | null }
export type WaitingKind = 'permission' | 'question' | 'plan'
export type WaitingEntry = { key: string; sessionId: string; callId: string; kind: WaitingKind; tool: string | null; at: number }
export type ScriptCache = { signature: string; owner: string; at: number; stdout: string }

function isDispatchRun(value: unknown): value is DispatchRun {
  return isRecord(value) && typeof value.RunKey === 'string' && typeof value.LineSlug === 'string' && typeof value.State === 'string'
    && optional(value.DurationSeconds, 'number')
    && ['LimitSource', 'DispatchSlug', 'TaskType', 'Profile', 'Account', 'Model', 'WorkRoot', 'StartedUtc', 'EndedUtc', 'LastEventUtc', 'RecordUpdatedUtc', 'Result', 'FailureReason', 'RejectionKind', 'TerminatedByEntry', 'Error'].every(key => optional(value[key], 'string'))
}
function toDispatchAccount(value: unknown): DispatchAccount | null {
  if (!isRecord(value) || typeof value.Name !== 'string') return null
  if (!['LastResult', 'LastFailureReason', 'LastRejectionKind', 'LastEndedUtc'].every(key => optional(value[key], 'string'))) return null
  const text = (item: unknown): string | null => typeof item === 'string' ? item : null
  const list = Array.isArray(value.Unsupported) ? value.Unsupported : isRecord(value.Unsupported) ? [value.Unsupported] : []
  return { Name: value.Name, LastResult: text(value.LastResult), LastFailureReason: text(value.LastFailureReason), LastRejectionKind: text(value.LastRejectionKind), LastEndedUtc: text(value.LastEndedUtc),
    Unsupported: list.filter(isRecord).map(item => ({ Profile: text(item.Profile), Model: text(item.Model) })) }
}
export function parseDispatch(value: unknown): Dispatch | null {
  if (!isRecord(value)) return null
  const runs = Array.isArray(value.runs) ? value.runs.filter(isDispatchRun) : []
  const accounts = Array.isArray(value.accounts) ? value.accounts.map(toDispatchAccount).filter((item): item is DispatchAccount => item !== null) : []
  return { runs, accounts, totalCount: isCount(value.totalCount) ? Math.max(value.totalCount, runs.length) : runs.length,
    warnings: Array.isArray(value.warnings) ? value.warnings.filter((item): item is string => typeof item === 'string') : [],
    error: typeof value.error === 'string' && value.error.trim() ? value.error : null,
    errorDetail: typeof value.errorDetail === 'string' && value.errorDetail.trim() ? value.errorDetail : null }
}

const TASK_LABELS: Record<string, string> = { review: '審查', test: '測試', advise: '顧問', factcheck: '事實查核', image: '影像' }
export function dispatchTaskLabel(run: DispatchRun): string {
  return (run.TaskType && TASK_LABELS[run.TaskType]) || '派工'
}
export function durationText(seconds: number | null | undefined): string {
  if (seconds == null || !Number.isFinite(seconds) || seconds < 0) return ''
  if (seconds < 60) return `${Math.floor(seconds)} 秒`
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分鐘`
  const minutes = Math.floor((seconds % 3600) / 60)
  return `${Math.floor(seconds / 3600)} 小時${minutes ? ` ${minutes} 分` : ''}`
}
export function rejectionLabel(kind: string | null | undefined): string {
  return kind === 'usage-limit' ? '額度用完' : kind === 'unauthorized' ? '登入失效' : kind === 'model-not-supported' ? '帳號不支援這個 model' : kind === 'rate-limited' ? '請求過於頻繁' : '服務端拒絕'
}
export function failureLabel(reason: string | null | undefined): string {
  return reason === 'timeout' ? '超過時限' : reason === 'nonzero-exit' ? '執行異常結束' : reason === 'no-last-message' ? '沒有產出結論'
    : reason === 'report-missing' || reason === 'report-empty' ? '沒有產出報告' : reason === 'launch-failed' ? '無法啟動' : '原因不明'
}
export function dispatchResultText(result: string | null | undefined, failureReason: string | null | undefined, rejectionKind: string | null | undefined): string {
  if (result === 'success') return '完成'
  if (result === 'rejected') return `被拒絕（${rejectionLabel(rejectionKind || failureReason)}）`
  if (result === 'failed') return `失敗（${failureLabel(failureReason)}）`
  return '結果不明'
}
export function dispatchResultTone(result: string | null | undefined): DotTone {
  return result === 'success' ? 'inactive' : result === 'rejected' ? 'warning' : result === 'failed' ? 'error' : 'inactive'
}
function elapsedSeconds(value: unknown, now: Date): number | null {
  const started = toEpochMs(value)
  return started === null ? null : Math.max(0, (now.getTime() - started) / 1000)
}
export function dispatchRow(run: DispatchRun, now: Date): BoardRow {
  const name = `${run.LineSlug} · ${dispatchTaskLabel(run)}`
  const account = run.Account || ''
  if (run.State === 'running') {
    // 最後事件的時間只作為資訊顯示；長時間推理期間沒有事件屬正常，不以顏色暗示異常。
    const lastEvent = relativeTime(run.LastEventUtc, now)
    const detail: DetailSegment[] = [{ text: lastEvent ? `最後事件 ${lastEvent}` : '尚無事件', tone: 'normal' }]
    if (run.Model) detail.push({ text: ` · ${run.Model}`, tone: 'normal' })
    const elapsed = durationText(elapsedSeconds(run.StartedUtc, now))
    return row(name, { tag: account, right: elapsed ? `已跑 ${elapsed}` : '執行中', dot: 'success', detail })
  }
  if (run.State === 'overdue') {
    const started = relativeTime(run.StartedUtc, now)
    const lastEvent = relativeTime(run.LastEventUtc, now)
    return row(name, { tag: account, right: started ? `${started}開始` : '', dot: 'error', detail: [{ text: `超過時限仍沒有結果，可能已中斷${lastEvent ? ` · 最後事件 ${lastEvent}` : ''}`, tone: 'attention' }] })
  }
  const updated = toEpochMs(run.EndedUtc) ?? toEpochMs(run.RecordUpdatedUtc)
  const when = relativeTime(updated, now)
  if (run.State !== 'ended') return row(`${run.LineSlug} · 紀錄無法讀取`, { right: when, dot: 'error', tone: 'error' })
  const detail: DetailSegment[] = [{ text: dispatchResultText(run.Result, run.FailureReason, run.RejectionKind), tone: run.Result === 'success' ? 'normal' : 'attention' }]
  const took = durationText(run.DurationSeconds)
  if (took) detail.push({ text: ` · 耗時 ${took}`, tone: 'normal' })
  return row(name, { tag: account, right: when, dot: dispatchResultTone(run.Result), detail, tone: updated !== null && updated < now.getTime() - DIM_AFTER_MS ? 'dim' : 'normal' })
}
export function dispatchBlock(dispatch: Dispatch | null, now: Date): BoardBlock {
  if (dispatch === null) return errorBlock('狀態腳本沒有提供派工資料，請更新腳本後重新整理')
  if (dispatch.error !== null) return errorBlock('派工紀錄無法彙整，請按「重新整理」再試一次')
  const active = dispatch.runs.filter(run => run.State === 'running' || run.State === 'overdue')
  const rest = dispatch.runs.filter(run => run.State !== 'running' && run.State !== 'overdue').slice(0, DISPATCH_ENDED_LIMIT)
  const rows = [...active, ...rest].map(run => dispatchRow(run, now))
  const result: BoardBlock = { rows, stalledRows: [], hiddenCount: Math.max(0, dispatch.totalCount - rows.length), errorMessage: null }
  if (dispatch.warnings.length) result.warning = dispatch.warnings.join(' / ')
  return result
}
export function dispatchDetailText(dispatch: Dispatch | null, waiting: WaitingDiagnostic[] = []): string | null {
  const runs = dispatch?.runs ?? []
  const error = dispatch?.error ?? null
  if (!runs.length && error === null && !waiting.length) return null
  return JSON.stringify({ runs, error, errorDetail: dispatch?.errorDetail ?? null, waiting }, null, 2)
}
export function accountExtra(account: DispatchAccount | undefined, now: Date): DetailSegment[] | null {
  if (!account) return null
  const result: DetailSegment[] = []
  if (account.LastResult) {
    const when = relativeTime(account.LastEndedUtc, now)
    result.push({ text: `上次派工${dispatchResultText(account.LastResult, account.LastFailureReason, account.LastRejectionKind)}${when ? ` · ${when}` : ''}`, tone: account.LastResult === 'success' ? 'normal' : 'attention' })
  }
  if (account.Unsupported.length) {
    const models = [...new Set(account.Unsupported.map(item => item.Model).filter((item): item is string => !!item))]
    if (result.length) result.push({ text: ' · ', tone: 'normal' })
    result.push({ text: models.length && account.Unsupported.every(item => !!item.Model) ? `不支援 ${models.join('、')}` : '有不支援的 model', tone: 'attention' })
  }
  return result.length ? result : null
}
export function findDispatchAccount(dispatch: Dispatch | null, name: string): DispatchAccount | undefined {
  return dispatch?.accounts.find(account => account.Name.toLowerCase() === name.toLowerCase())
}

const STORE_ID = /^[A-Za-z0-9_-]{1,128}$/
export function waitingSessionPrefix(sessionId: string): string { return `${WAITING_PREFIX}${sessionId}:` }
export function waitingKey(sessionId: string, callId: string): string | null {
  return STORE_ID.test(sessionId) && STORE_ID.test(callId) ? waitingSessionPrefix(sessionId) + callId : null
}
export function parseWaiting(key: string, value: unknown): WaitingEntry | null {
  if (!key.startsWith(WAITING_PREFIX) || !isRecord(value)) return null
  const rest = key.slice(WAITING_PREFIX.length)
  const separator = rest.indexOf(':')
  if (separator < 1) return null
  const sessionId = rest.slice(0, separator)
  const callId = rest.slice(separator + 1)
  if (!STORE_ID.test(sessionId) || !STORE_ID.test(callId)) return null
  if (value.kind !== 'permission' && value.kind !== 'question' && value.kind !== 'plan') return null
  if (typeof value.at !== 'number' || !Number.isFinite(value.at) || value.at <= 0 || value.at > MAX_DATE_MS) return null
  return { key, sessionId, callId, kind: value.kind, tool: typeof value.tool === 'string' && WAITING_TOOL_NAMES.includes(value.tool) ? value.tool : null, at: value.at }
}
export function waitingText(entry: WaitingEntry): string {
  return entry.kind === 'question' ? '等你回答' : entry.kind === 'plan' ? '等你核准計畫' : `等你同意${entry.tool ? `：${entry.tool}` : ''}`
}
export function waitingKindForTool(tool: string): WaitingKind | null { return tool === 'ExitPlanMode' ? 'plan' : tool === 'AskUserQuestion' ? 'question' : null }
// Date 可表示的最大毫秒數；超過時無法轉成時間字串。
const MAX_DATE_MS = 8.64e15
export function isWaitingExpired(entry: WaitingEntry, nowMs: number): boolean {
  return nowMs - entry.at > WAITING_MAX_AGE_MS
}
// 外掛取不到「使用者已同意權限」的訊號。超過這段時間後，無法分辨是仍在等待，還是已同意而工具仍在執行，因此改為只陳述曾有請求。
export const PERMISSION_ACTIVE_MS = 5 * 60 * 1000
// 寫入時間與 lastActivityAt 由不同行程取得，同回合的其他工具結果也可能稍後寫入；一個更新週期內的活動視為同一次請求的前後。
export const ACTIVITY_TOLERANCE_MS = REFRESH_MS
export type WaitingState = 'active' | 'stale' | 'hidden'
export type WaitingReason = 'ok' | 'stale-permission' | 'archived' | 'no-activity-time' | 'activity-after' | 'future' | 'expired' | 'not-running' | 'not-listed'
export type WaitingVerdict = { state: WaitingState; reason: WaitingReason }
const PRUNE_REASONS: WaitingReason[] = ['archived', 'activity-after', 'expired', 'not-running']
// 顯示與否只看寫入時間、Session 是否在清單內且未封存、寫入後有沒有新活動。isRunning 的語意未經驗證，只用來提早移除已超過 PERMISSION_ACTIVE_MS 的權限請求。
export function waitingVerdict(session: Session | undefined, entry: WaitingEntry, nowMs: number): WaitingVerdict {
  if (!session) return { state: 'hidden', reason: 'not-listed' }
  if (session.isArchived === true) return { state: 'hidden', reason: 'archived' }
  if (entry.at - nowMs > WAITING_FUTURE_TOLERANCE_MS) return { state: 'hidden', reason: 'future' }
  if (isWaitingExpired(entry, nowMs)) return { state: 'hidden', reason: 'expired' }
  const activity = toEpochMs(session.lastActivityAt)
  if (activity === null) return { state: 'hidden', reason: 'no-activity-time' }
  if (activity > entry.at + ACTIVITY_TOLERANCE_MS) return { state: 'hidden', reason: 'activity-after' }
  if (entry.kind === 'permission' && nowMs - entry.at > PERMISSION_ACTIVE_MS) {
    return session.isRunning === false ? { state: 'hidden', reason: 'not-running' } : { state: 'stale', reason: 'stale-permission' }
  }
  return { state: 'active', reason: 'ok' }
}
export type WaitingItem = { session: Session; entry: WaitingEntry; state: 'active' | 'stale' }
export function scopedWaiting(sessions: Session[], waiting: WaitingEntry[], nowMs: number): WaitingItem[] {
  const result: WaitingItem[] = []
  for (const session of sessions) {
    if (!session.sessionId) continue
    const judged = waiting.filter(item => item.sessionId === session.sessionId).map(entry => ({ entry, state: waitingVerdict(session, entry, nowMs).state })).sort((a, b) => a.entry.at - b.entry.at)
    const pick = judged.find(item => item.state === 'active') ?? judged.find(item => item.state === 'stale')
    if (pick && pick.state !== 'hidden') result.push({ session, entry: pick.entry, state: pick.state })
  }
  return result.sort((a, b) => a.entry.at - b.entry.at)
}
export function staleWaitingText(entry: WaitingEntry, now: Date): string {
  const when = relativeTime(entry.at, now)
  return `同意請求 ${when}${entry.tool ? `：${entry.tool}` : ''}`
}
// 讀取端可刪除的鍵：該 Session 已封存、寫入後已有新活動、逾時、權限請求超過 PERMISSION_ACTIVE_MS 且已不在執行中。不在 Session 清單內的鍵不刪除，清單可能不完整，留到逾時由讀取時移除。自己的鍵交給寫入端處理。
export function prunableWaitingKeys(waiting: WaitingEntry[], sessions: Session[], selfId: string | null, nowMs: number): string[] {
  const byId = new Map(sessions.filter(session => typeof session.sessionId === 'string').map(session => [session.sessionId as string, session]))
  return waiting.filter(entry => {
    if (entry.sessionId === selfId) return false
    const session = byId.get(entry.sessionId)
    if (!session) return false
    return PRUNE_REASONS.includes(waitingVerdict(session, entry, nowMs).reason)
  }).map(entry => entry.key)
}
export type WaitingDiagnostic = { sessionId: string; title: string | null; kind: WaitingKind; tool: string | null; writtenAt: string; ageSeconds: number; state: WaitingState; reason: WaitingReason; isRunning: unknown; lastActivityAt: unknown }
export function waitingDiagnostics(waiting: WaitingEntry[], sessions: Session[], nowMs: number): WaitingDiagnostic[] {
  const byId = new Map(sessions.filter(session => typeof session.sessionId === 'string').map(session => [session.sessionId as string, session]))
  return [...waiting].sort((a, b) => a.at - b.at).map(entry => {
    const session = byId.get(entry.sessionId)
    const verdict = waitingVerdict(session, entry, nowMs)
    return { sessionId: entry.sessionId, title: session?.title || session?.name || null, kind: entry.kind, tool: entry.tool, writtenAt: new Date(entry.at).toISOString(), ageSeconds: Math.round((nowMs - entry.at) / 1000), state: verdict.state, reason: verdict.reason, isRunning: session ? session.isRunning ?? null : null, lastActivityAt: session ? session.lastActivityAt ?? null : null }
  })
}
export function newWaiting(previous: ReadonlySet<string> | null, current: { session: Session; entry: WaitingEntry; state?: 'active' | 'stale' }[]): { next: Set<string>; added: { title: string; text: string }[] } {
  const next = new Set<string>()
  const added: { title: string; text: string }[] = []
  for (const item of current) {
    if (item.state === 'stale') continue
    const signature = `${item.entry.key}@${item.entry.at}`
    next.add(signature)
    if (previous !== null && !previous.has(signature)) added.push({ title: item.session.title || item.session.name || item.entry.sessionId, text: waitingText(item.entry) })
  }
  return { next, added }
}
export function waitingToastText(added: { title: string; text: string }[]): string {
  if (added.length === 1) return `「${clip(added[0].title, 30)}」${added[0].text}`
  return `${added.length} 個 Session 在等你：${added.slice(0, 3).map(item => clip(item.title, 30)).join('、')}${added.length > 3 ? '…' : ''}`
}
export function parseSelfSessionId(result: unknown): string | null {
  try {
    if (!isRecord(result) || result.isError === true) return null
    let body: unknown = result.structuredContent
    if (body == null && Array.isArray(result.content)) body = JSON.parse(result.content.filter(item => isRecord(item) && item.type === 'text').map(item => String((item as { text?: unknown }).text ?? '')).join('\n'))
    return isRecord(body) && typeof body.sessionId === 'string' && STORE_ID.test(body.sessionId) ? body.sessionId : null
  } catch { return null }
}
export type PendingCall = { tool: string; asked: boolean; marked: boolean }
// PermissionRequest 不帶工具呼叫識別，依工具名稱對應到進行中且尚未標示的呼叫，tool.check 已判為需要詢問者優先。
// 同一優先層有兩筆以上而無法分辨時不對應，寧可不顯示這次等待，也不寫到錯的呼叫上。
export function pickPermissionCall(calls: ReadonlyMap<string, PendingCall>, tool: string): string | null {
  if (waitingKindForTool(tool) !== null) return null
  const asked: string[] = []
  const others: string[] = []
  for (const [id, call] of calls) {
    if (call.tool !== tool || call.marked) continue
    if (call.asked) asked.push(id)
    else others.push(id)
  }
  if (asked.length) return asked.length === 1 ? asked[0] : null
  return others.length === 1 ? others[0] : null
}

export function scriptSignature(argv: string[]): string {
  const start = argv.indexOf('-File')
  return (start < 0 ? argv : argv.slice(start + 1)).join('\u0001')
}
export function reusableScriptOutput(value: unknown, signature: string, owner: string, nowMs: number, maxAgeMs: number): { stdout: string; at: number } | null {
  if (!isRecord(value) || value.signature !== signature || typeof value.owner !== 'string' || value.owner === owner) return null
  if (typeof value.stdout !== 'string' || typeof value.at !== 'number' || !Number.isFinite(value.at)) return null
  const age = nowMs - value.at
  return age >= 0 && age < maxAgeMs ? { stdout: value.stdout, at: value.at } : null
}
