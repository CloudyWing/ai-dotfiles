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
export const BLOCK_IDS: BlockId[] = ['sessions', 'lines', 'workRoots', 'quota']
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
export const BLOCK_ORDER: BlockId[] = ['sessions', 'quota', 'lines', 'workRoots']
export const BLOCK_TITLES: Record<BlockId, string> = { sessions: 'Session', quota: 'Codex 額度', lines: '工作線', workRoots: '工作目錄' }
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
  const result: DetailSegment[] = [{ text: '週 ', tone: 'normal' }, { text: secondary === null ? '-' : `${secondary}%`, tone: numberTone('weekly', secondary) }]
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
  const units: Record<BlockId, string> = { sessions: '個', quota: '個帳號', lines: '條', workRoots: '個' }
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
export const ICON_ALT: Record<BlockId, string> = { sessions: 'Session 圖示', quota: 'Codex 額度圖示', lines: '工作線圖示', workRoots: '工作目錄圖示' }
export function iconSvg(id: BlockId): string {
  const paths: Record<BlockId, string> = {
    sessions: '<path d="M3 2h8a1.5 1.5 0 0 1 1.5 1.5V8A1.5 1.5 0 0 1 11 9.5H7L4.5 12V9.5H3A1.5 1.5 0 0 1 1.5 8V3.5A1.5 1.5 0 0 1 3 2z"/>',
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
export type Quota = { Name: string; State: string; CodexHome?: string | null; Error?: string | null; ErrorKind?: string | null; ErrorReason?: string | null; PrimaryRemaining?: number | null; SecondaryRemaining?: number | null; PrimaryResetsAtLocal?: string | null; SecondaryResetsAtLocal?: string | null }
export type Document = { scannedRoots: string[]; lines: Line[]; workRoots: Root[]; quota: Quota[]; warnings: string[] }
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
    && ['PrimaryRemaining', 'SecondaryRemaining'].every(key => optional(value[key], 'number'))
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
    return { ok: true, value: { scannedRoots: value.scannedRoots, lines: value.lines.filter(isLine), workRoots: value.workRoots.filter(isRoot), quota: value.quota.filter(isQuota), warnings: Array.isArray(value.warnings) ? value.warnings.filter((item): item is string => typeof item === 'string') : [] } }
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
export function lowestPrimary(quota: Quota[]): number | null {
  const values = quota.filter(account => account.State === 'ok').map(account => roundPercent(account.PrimaryRemaining)).filter((value): value is number => value !== null)
  return values.length ? Math.min(...values) : null
}
export function statusText(running: number | null, lowest: number | null): string | undefined {
  const parts = [running === null ? '' : `${running} 執行中`, lowest === null ? '' : `額度 ${lowest}%`].filter(Boolean)
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

type QuotaAlertAccount = { name: string; kind: 'high' | 'low' | 'limit' | 'login' | 'unknown'; percent: number | null; token: string }
function quotaAlertAccount(account: Quota): QuotaAlertAccount {
  const percent = account.State === 'ok' ? roundPercent(account.PrimaryRemaining) : null
  if (percent !== null) return { name: account.Name, kind: percent >= QUOTA_ALERT_BELOW ? 'high' : 'low', percent, token: account.PrimaryResetsAtLocal ?? '' }
  if (account.ErrorKind === 'limit-reached') return { name: account.Name, kind: 'limit', percent: null, token: '*' }
  if (account.ErrorKind === 'auth-expired') return { name: account.Name, kind: 'login', percent: null, token: '*' }
  return { name: account.Name, kind: 'unknown', percent: null, token: '' }
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
  const details = accounts.map(account => account.kind === 'low' ? `${account.name} 剩 ${account.percent}%` : account.kind === 'limit' ? `${account.name} 已達上限` : `${account.name} 登入失效`)
  return { alert: true, signature: current, text: `Codex 5 小時額度：${details.join('、')}` }
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
  return { sessions: errorBlock(message), lines: errorBlock(message), workRoots: errorBlock(message), quota: errorBlock(message), currentLabel: null, scannedRoots: [] }
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
export function buildSnapshot(script: Result<Document>, sessions: Result<Session[]>, now: Date, current: CurrentRepo | null = null, branches: ReadonlySet<string> | null = null): BoardSnapshot {
  if (!script.ok) return { sessions: errorBlock('無法判定掃描範圍'), lines: errorBlock(script.error), workRoots: errorBlock(script.error), quota: errorBlock(script.error), currentLabel: currentLabel(current), scannedRoots: [] }
  const data = script.value
  const filtered = scopedSessions(script, sessions) ?? []
  const running = new Set(filtered.filter(session => session.isRunning === true).map(session => mapSessionToLine(session, data)).filter((slug): slug is string => slug !== null))
  const sessionBlock = !sessions.ok ? errorBlock(sessions.error) : block(sortSessionsByActivity(filtered).map(session => {
    const title = session.title || session.name || session.sessionId || '-'
    const line = mapSessionToLine(session, data)
    return row(title, { dot: sessionTone(session.isRunning), tag: line || '', right: relativeTime(session.lastActivityAt, now), link: sessionLink(session) })
  }), SESSION_LIMIT)
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
    if (account.State === 'unknown') return quotaErrorRow(account)
    const primary = roundPercent(account.PrimaryRemaining)
    const secondary = roundPercent(account.SecondaryRemaining)
    return row(account.Name, { dot: quotaDotTone(primary, secondary), right: primary === null ? '-' : `剩 ${primary}%`, bar: { percent: primary, tone: quotaTone(primary) }, detail: quotaDetail(secondary, account.SecondaryResetsAtLocal ? time(account.SecondaryResetsAtLocal) : null) })
  })
  const quotaBlock = block(quota)
  if (data.warnings.length) quotaBlock.warning = data.warnings.join(' / ')
  return { sessions: sessionBlock, lines: block(normalLines, LINE_LIMIT, stalledLines), workRoots: block(roots), quota: quotaBlock, currentLabel: currentLabel(current), scannedRoots: data.scannedRoots }
}
