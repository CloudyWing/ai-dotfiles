import { atom, read, update } from 'claude-code'
import type { Engine, Register } from 'claude-code'
import type { BlockId, BoardBlock, BoardRow, BoardSnapshot, ExpandId } from '../types'
import { buildSnapshot, errorSnapshot, parseScriptOutput, parseSessions, REFRESH_MS, STORE_KEY, HOVER_BG, BAR_WIDTH, BAR_HEIGHT, normalizeCollapsed, toggleBlock, quotaBarSvg, quotaBarText, BLOCK_ORDER, blockTitleText, iconSvg, ICON_ALT, ICON_SIZE, DIVIDER_SVG, DIVIDER_MODE, dividerText, NAME_SHRINK, NOTE_SHRINK, CURRENT_BG } from './lib'
import type { Document, Result, Session } from './lib'
import { GIT_TIMEOUT_MS, SCRIPT_BUDGET_MS, parseWorktreeList, resolveCurrentRepo, buildWorkRootArgument, buildForceWorkRootArgument, remainingBudgetMs } from './lib'
import type { CurrentRepo, GitProbe } from './lib'
import { EXPAND_KEY, normalizeExpanded, toggleExpanded, stalledToggleText, canShowNote, parseFeatureBranches } from './lib'

const PANE = 'line-status-board'
const snapshot = atom({ plugin: 'line-status-board', key: 'snapshot' } as const, null as BoardSnapshot | null, { shape: 'snapshot-5' })
const collapsed = atom({ plugin: 'line-status-board', key: 'collapsed' } as const, null as BlockId[] | null, { shape: 'collapsed-1' })
const expanded = atom({ plugin: 'line-status-board', key: 'expanded' } as const, null as ExpandId[] | null, { shape: 'expanded-1' })
const refreshedAt = atom({ plugin: 'line-status-board', key: 'refreshedAt' } as const, null as string | null)
const isRefreshing = atom({ plugin: 'line-status-board', key: 'isRefreshing' } as const, false)
let isBusy = false
let pendingCwd: string | null = null

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

async function scriptResult($: Engine, options: { workRoots?: string; scriptPath?: string }, current: CurrentRepo | null, startedAt: number): Promise<Result<Document>> {
  try {
    let path = options.scriptPath?.trim()
    if (!path) {
      const local = $.plugin.root + '\\..\\..\\scripts\\Get-LineStatus.ps1'
      try { await $.fs.stat(local); path = local } catch {
        const profile = await $.env.get('USERPROFILE')
        if (profile) {
          const fallback = profile + '\\.ai-agents\\scripts\\Get-LineStatus.ps1'
          try { await $.fs.stat(fallback); path = fallback } catch { /* 路徑不存在 */ }
        }
      }
    }
    if (!path) throw new Error('找不到 Get-LineStatus.ps1')
    const argv = ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path, '-AsJson']
    let profile: string | null = null
    try { profile = await $.env.get('USERPROFILE') ?? null } catch { /* 使用腳本預設值 */ }
    const roots = buildWorkRootArgument(options.workRoots, profile, current)
    if (roots !== null) argv.push('-WorkRoot', roots)
    const forced = buildForceWorkRootArgument(current)
    if (forced !== null) argv.push('-ForceWorkRoot', forced)
    const result = await $.process.run(argv, { timeoutMs: remainingBudgetMs(SCRIPT_BUDGET_MS, Date.now() - startedAt) })
    if (result.exitCode !== 0) throw new Error(result.stderr || `exit ${result.exitCode}`)
    return parseScriptOutput(result.stdout)
  } catch (error) { return { ok: false, error: message(error) } }
}

async function sessionResult($: Engine): Promise<Result<Session[]>> {
  try { return parseSessions(await $.mcp.call('ccd_session_mgmt', 'list_sessions', { limit: 200 })) }
  catch (error) { return { ok: false, error: message(error) } }
}

async function refresh($: Engine, options: { workRoots?: string; scriptPath?: string }, cwd?: string, isCwdChange = false): Promise<void> {
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
    const located: { current: CurrentRepo | null; branches: Set<string> | null } = { current: null, branches: null }
    const [script, sessions] = await Promise.all([
      (async () => {
        located.current = await locateCurrent($, cwd)
        const [script, branches] = await Promise.all([scriptResult($, options, located.current, startedAt), listFeatureBranches($, located.current)])
        located.branches = branches
        return script
      })(),
      sessionResult($)
    ])
    let next: BoardSnapshot
    try { next = buildSnapshot(script, sessions, new Date(), located.current, located.branches) }
    catch (error) { next = errorSnapshot(message(error)) }
    await update($, snapshot, () => next)
  } finally {
    try { await update($, isRefreshing, () => false) } finally {
      isBusy = false
      const nextCwd = pendingCwd
      pendingCwd = null
      if (nextCwd) void refresh($, options, nextCwd, true)
    }
  }
}
async function refreshIfPlaced($: Engine, options: { workRoots?: string; scriptPath?: string }, cwd?: string, isCwdChange = false): Promise<void> {
  try {
    const panes = await $.ui.panes()
    if (panes.some(pane => pane.id === PANE && pane.isPlaced)) void refresh($, options, cwd, isCwdChange)
  } catch { /* 取不到 Pane 狀態時不更新 */ }
}

export const register: Register = (on, options = {}) => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    const opened = await $.ui.open({ id: PANE, title: '線狀態' })
    if (opened.isPlaced) void refresh($, options)
    $.clock.every(REFRESH_MS, async () => {
      void refreshIfPlaced($, options)
    })
    return result
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
    const { Box, Text, Button } = $.ui.resolve(e)
    const Svg = e.surface === 'desktop' ? $.ui.resolve(e).Svg : undefined
    const current = await read($, snapshot)
    const updated = await read($, refreshedAt)
    const busy = await read($, isRefreshing)
    const closed = await read($, collapsed) ?? await loadStored($)
    const openStalled = (await read($, expanded) ?? await loadStoredExpanded($)).includes('stalledLines')
    const columns = e.props.bodyColumns
    const renderRow = (keyPrefix: string, iconId: BlockId, item: BoardRow, index: number) => (
      <Box key={`row-${keyPrefix}-${index}`} flexDirection="row" gap="xs" paddingX="xs" backgroundColor={item.isCurrent ? CURRENT_BG : undefined} hover={{ backgroundColor: HOVER_BG }}>
        <Box flexDirection="row" flexShrink={0} height={1} alignSelf="flex-start" alignItems="center" gap="xs">
          {Svg && <Svg source={iconSvg(iconId)} alt={ICON_ALT[iconId]} width={ICON_SIZE} height={ICON_SIZE} />}
          <Text color={item.dot}>●</Text>
        </Box>
        <Box flexDirection="column" flexGrow={1} flexShrink={1} minWidth={0}>
          <Box flexDirection="row" gap="xs">
            <Box flexDirection="row" flexGrow={1} flexShrink={1} minWidth={0} gap="xs">
              <Box flexShrink={NAME_SHRINK} minWidth={0}><Text wrap="truncate-end" color={item.tone === 'error' ? 'error' : undefined} dimColor={item.tone === 'dim'}>{item.name}</Text></Box>
              {canShowNote(columns, item.name, item.tag, item.right) && <Box flexShrink={NOTE_SHRINK} minWidth={0}><Text size="footnote" dimColor wrap="truncate-end">{item.tag}</Text></Box>}
            </Box>
            {(item.right || item.bar) && <Box flexDirection="row" alignItems="center" gap="xs" minWidth={0} flexShrink={item.rightShrink ? NOTE_SHRINK : 0}>
              <Text size="footnote" dimColor wrap="truncate-end">{item.right}</Text>
              {item.bar && (Svg ? <Svg source={quotaBarSvg(item.bar.percent, item.bar.tone)} alt={item.bar.percent === null ? '5 小時剩餘量未知' : `5 小時剩餘 ${item.bar.percent}%`} width={BAR_WIDTH} height={BAR_HEIGHT} /> : <Text color={item.bar.tone}>{quotaBarText(item.bar.percent)}</Text>)}
            </Box>}
          </Box>
          {item.detail && <Text size="caption" wrap="truncate-end">{item.detail.map((segment, i) => <Text key={String(i)} color={segment.tone === 'attention' ? 'warning' : undefined} dimColor={segment.tone === 'normal'}>{segment.text}</Text>)}</Text>}
        </Box>
      </Box>
    )
    const empty: Record<BlockId, string> = { sessions: '（沒有符合的 Session）', quota: '（沒有帳號資料）', lines: '（沒有線）', workRoots: '（沒有 work-root）' }
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
        <Box flexDirection="row" justifyContent="space-between" paddingTop="xs">
          <Text dimColor>最後更新 {updated ? new Date(updated).toLocaleTimeString('zh-TW', { hour12: false }) : '-'}{busy ? ' 更新中…' : ''}</Text>
          <Button key="refresh" label={busy ? '更新中…' : '重新整理'} onPress={() => void refresh($, options)} />
        </Box>
      </Box>
    )
  })
}
