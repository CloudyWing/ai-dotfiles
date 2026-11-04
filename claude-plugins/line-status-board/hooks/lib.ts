import type { BoardBlock, BoardRow, BoardSnapshot } from '../types'

export const REFRESH_MS = 60000
export type Result<T> = { ok: true; value: T } | { ok: false; error: string }
export type Session = { cwd?: unknown; isArchived?: boolean; isRunning?: boolean; name?: string; title?: string; sessionId?: string }
export type Line = { LineSlug: string; WorkRoot: string; CheckpointType?: string | null; CheckpointUpdatedUtc?: string | null; NextStepSummary?: string | null; Error?: string | null }
export type Root = { Path: string; IsLinkedWorktree?: boolean | null; Branch?: string | null; DirtyCount?: number | null; MainAhead?: number | null; MainBehind?: number | null; Upstream?: string | null; UpstreamAhead?: number | null; Error?: string | null }
export type Quota = { Name: string; State: string; Error?: string | null; PrimaryRemaining?: number | null; SecondaryRemaining?: number | null; PrimaryResetsAtLocal?: string | null; SecondaryResetsAtLocal?: string | null }
export type Document = { scannedRoots: string[]; lines: Line[]; workRoots: Root[]; quota: Quota[]; warnings: string[] }

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
function optional(value: unknown, kind: 'string' | 'number' | 'boolean'): boolean {
  return value == null || (typeof value === kind && (kind !== 'number' || (typeof value === 'number' && Number.isFinite(value))))
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
    && ['Error', 'PrimaryResetsAtLocal', 'SecondaryResetsAtLocal'].every(key => optional(value[key], 'string'))
    && ['PrimaryRemaining', 'SecondaryRemaining'].every(key => optional(value[key], 'number'))
}

export function normalizePath(path: string): string {
  const value = path.replace(/\//g, '\\').toLowerCase()
  return /^[a-z]:\\+$/.test(value) ? value.slice(0, 3) : value.replace(/\\+$/, '')
}

export function isUnder(path: string, root: string): boolean {
  const p = normalizePath(path)
  const r = normalizePath(root)
  return p === r || p.startsWith(r.endsWith('\\') ? r : r + '\\')
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

const row = (text: string, tone: BoardRow['tone'] = 'normal'): BoardRow => ({ text, tone })
const block = (rows: BoardRow[], limit = rows.length): BoardBlock => ({ rows: rows.slice(0, limit), hiddenCount: Math.max(0, rows.length - limit), errorMessage: null })
const errorBlock = (message: string): BoardBlock => ({ rows: [], hiddenCount: 0, errorMessage: message })
export function errorSnapshot(message: string): BoardSnapshot {
  return { sessions: errorBlock(message), lines: errorBlock(message), workRoots: errorBlock(message), quota: errorBlock(message) }
}
const clip = (value: string, limit: number): string => Array.from(value).length > limit ? Array.from(value).slice(0, limit).join('') + '…' : value
const time = (value?: string | null): string => {
  if (!value) return '-'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value.replace(/^\d{4}-/, '').slice(0, 11)
  const pad = (v: number) => String(v).padStart(2, '0')
  return `${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`
}
const number = (value?: number | null): string => value == null ? '-' : String(value)

export function buildSnapshot(script: Result<Document>, sessions: Result<Session[]>, _now: Date): BoardSnapshot {
  if (!script.ok) return { sessions: errorBlock('無法判定掃描範圍'), lines: errorBlock(script.error), workRoots: errorBlock(script.error), quota: errorBlock(script.error) }
  const data = script.value
  const sessionBlock = !sessions.ok ? errorBlock(sessions.error) : block(filterSessions(sessions.value, data.scannedRoots).map(session => {
    const title = clip(session.title || session.name || session.sessionId || '-', 24)
    const line = mapSessionToLine(session, data)
    return row(`${session.isRunning ? '● 執行中' : '○ 閒置'} ${title}${line ? ' → ' + line : ''}`)
  }), 15)
  const lines = data.lines.filter(line => line.CheckpointType || line.CheckpointUpdatedUtc || line.Error || data.workRoots.some(root => root.IsLinkedWorktree && normalizePath(root.Path) === normalizePath(line.WorkRoot)))
    .sort((a, b) => (b.CheckpointUpdatedUtc || '').localeCompare(a.CheckpointUpdatedUtc || '') || a.LineSlug.localeCompare(b.LineSlug))
    .map(line => {
      if (line.Error) return row(`${line.LineSlug} · ${line.Error}`, 'error')
      if (!line.CheckpointType && !line.CheckpointUpdatedUtc) return row(`${line.LineSlug} · 無檢查點`)
      const type = line.CheckpointType === 'design-accepted' ? '設計驗收' : line.CheckpointType === 'developer-collected' ? 'Dev 回收' : (line.CheckpointType || '-').slice(0, 12)
      return row(`${line.LineSlug} · ${type} · ${time(line.CheckpointUpdatedUtc)} ▸ ${line.NextStepSummary ? clip(line.NextStepSummary, 40) : '（未載明下一步）'}`)
    })
  const roots = data.workRoots.map(root => {
    const name = root.Path.replace(/[\\/]+$/, '').split(/[\\/]/).pop() || root.Path
    if (root.Error) return row(`${name} · ${root.Error}`, 'error')
    return row(`${name} · ${root.Branch || '-'} · 未 commit ${number(root.DirtyCount)} · 主分支 +${number(root.MainAhead)}/-${number(root.MainBehind)} · ${root.Upstream ? '未 push ' + number(root.UpstreamAhead) : '無 upstream'}`)
  })
  const quota = data.quota.map(account => account.State === 'unknown'
    ? row(`${account.Name} · 無法取得：${clip(account.Error || '-', 40)}`, 'error')
    : row(`${account.Name} · 5 小時 剩 ${account.PrimaryRemaining == null ? '-' : Math.round(account.PrimaryRemaining)}%（${time(account.PrimaryResetsAtLocal)} 重置） · 週 剩 ${account.SecondaryRemaining == null ? '-' : Math.round(account.SecondaryRemaining)}%（${time(account.SecondaryResetsAtLocal)} 重置）`))
  const quotaBlock = block(quota)
  if (data.warnings.length) quotaBlock.warning = data.warnings.join(' / ')
  return { sessions: sessionBlock, lines: block(lines, 12), workRoots: block(roots), quota: quotaBlock }
}
