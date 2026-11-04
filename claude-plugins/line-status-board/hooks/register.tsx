import { atom, read, update } from 'claude-code'
import type { Engine, Register } from 'claude-code'
import type { BlockId, BoardBlock, BoardRow, BoardSnapshot } from '../types'
import { buildSnapshot, errorSnapshot, parseScriptOutput, parseSessions, REFRESH_MS, STORE_KEY, HOVER_BG, BAR_WIDTH, BAR_HEIGHT, normalizeCollapsed, toggleBlock, quotaBarSvg, quotaBarText } from './lib'
import type { Document, Result, Session } from './lib'

const PANE = 'line-status-board'
const snapshot = atom({ plugin: 'line-status-board', key: 'snapshot' } as const, null as BoardSnapshot | null, { shape: 'snapshot-2' })
const collapsed = atom({ plugin: 'line-status-board', key: 'collapsed' } as const, null as BlockId[] | null, { shape: 'collapsed-1' })
const refreshedAt = atom({ plugin: 'line-status-board', key: 'refreshedAt' } as const, null as string | null)
const isRefreshing = atom({ plugin: 'line-status-board', key: 'isRefreshing' } as const, false)
let isBusy = false

const message = (error: unknown): string => String(error instanceof Error ? error.message : error).split(/\r?\n/)[0].slice(0, 120)

async function loadStored($: Engine): Promise<BlockId[]> {
  try { return normalizeCollapsed(await $.store.get(STORE_KEY)) } catch { return [] }
}
async function toggle($: Engine, id: BlockId): Promise<void> {
  const stored = await loadStored($)
  try {
    const next = await update($, collapsed, previous => toggleBlock(previous ?? stored, id))
    await $.store.set(STORE_KEY, next)
  } catch { /* 狀態更新或儲存失敗時保留目前狀態 */ }
}

async function scriptResult($: Engine, options: { workRoots?: string; scriptPath?: string }): Promise<Result<Document>> {
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
    if (options.workRoots?.trim()) argv.push('-WorkRoot', options.workRoots.trim())
    const result = await $.process.run(argv, { timeoutMs: 40000 })
    if (result.exitCode !== 0) throw new Error(result.stderr || `exit ${result.exitCode}`)
    return parseScriptOutput(result.stdout)
  } catch (error) { return { ok: false, error: message(error) } }
}

async function sessionResult($: Engine): Promise<Result<Session[]>> {
  try { return parseSessions(await $.mcp.call('ccd_session_mgmt', 'list_sessions', { limit: 200 })) }
  catch (error) { return { ok: false, error: message(error) } }
}

async function refresh($: Engine, options: { workRoots?: string; scriptPath?: string }): Promise<void> {
  if (isBusy) return
  isBusy = true
  try {
    const now = new Date()
    await update($, refreshedAt, () => now.toISOString())
    await update($, isRefreshing, () => true)
    const [script, sessions] = await Promise.all([scriptResult($, options), sessionResult($)])
    let next: BoardSnapshot
    try { next = buildSnapshot(script, sessions, now) }
    catch (error) { next = errorSnapshot(message(error)) }
    await update($, snapshot, () => next)
  } finally {
    try { await update($, isRefreshing, () => false) } finally { isBusy = false }
  }
}

export const register: Register = (on, options = {}) => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    const opened = await $.ui.open({ id: PANE, title: '線狀態' })
    if (opened.isPlaced) void refresh($, options)
    $.clock.every(REFRESH_MS, async () => {
      const panes = await $.ui.panes()
      if (panes.some(pane => pane.id === PANE && pane.isPlaced)) void refresh($, options)
    })
    return result
  })
  on('session.attach', async ($, e, next) => {
    if (e.surface === 'desktop') void refresh($, options)
    return next(e)
  })
  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const Svg = e.surface === 'desktop' ? $.ui.resolve(e).Svg : undefined
    const current = await read($, snapshot)
    const updated = await read($, refreshedAt)
    const busy = await read($, isRefreshing)
    const closed = await read($, collapsed) ?? await loadStored($)
    const renderRow = (blockId: BlockId, item: BoardRow, index: number) => (
      <Box key={`row-${blockId}-${index}`} flexDirection="column" paddingX="xs" hover={{ backgroundColor: HOVER_BG }}>
        <Box flexDirection="row" gap="xs">
          <Box flexDirection="row" flexGrow={1} flexShrink={1} minWidth={0} gap="xs">
            {item.dot && <Text color={item.dot}>●</Text>}
            <Text wrap="truncate-end" color={item.tone === 'error' ? 'error' : undefined}>{item.name}</Text>
          </Box>
          {item.note && <Box flexShrink={0}><Text size="footnote" dimColor>{item.note}</Text></Box>}
        </Box>
        {item.detail && <Box paddingLeft={item.dot ? 2 : 0}><Text size="caption" dimColor wrap="truncate-end">{item.detail}</Text></Box>}
        {item.bars.map(bar => <Box key={`bar-${blockId}-${index}-${bar.label}`} flexDirection="row" gap="sm" alignItems="center" paddingLeft={item.dot ? 2 : 0}>
          <Box width={6}><Text size="caption" dimColor>{bar.label}</Text></Box>
          {Svg ? <Svg source={quotaBarSvg(bar.percent, bar.tone)} alt={bar.percent === null ? `${bar.label}剩餘量未知` : `${bar.label}剩餘 ${bar.percent}%`} width={BAR_WIDTH} height={BAR_HEIGHT} /> : <Text color={bar.tone}>{quotaBarText(bar.percent)}</Text>}
          <Text size="caption" dimColor>{bar.text}</Text>
        </Box>)}
      </Box>
    )
    const renderBlock = (id: BlockId, title: string, value: BoardBlock | undefined, empty: string) => (
      <Box flexDirection="column">
        <Box flexDirection="row" justifyContent="space-between">
          <Button key={`toggle-${id}`} label={title} plain dimColor onPress={() => void toggle($, id)}><Text size="footnote" weight="medium" dimColor>{closed.includes(id) ? '▸' : '▾'} {title}</Text></Button>
          <Text size="footnote" dimColor={value?.errorMessage == null} color={value?.errorMessage != null ? 'error' : undefined}>{value ? value.rows.length + value.hiddenCount : 0}</Text>
        </Box>
        {!closed.includes(id) && <>
          {value?.errorMessage && <Text color="error">{value.errorMessage}</Text>}
          {value && !value.errorMessage && value.rows.length === 0 && <Text dimColor>{empty}{value.warning ? ' ' + value.warning : ''}</Text>}
          {value?.rows.map((item, index) => renderRow(id, item, index))}
          {value && value.rows.length > 0 && value.warning && <Text dimColor>{value.warning}</Text>}
          {value && value.hiddenCount > 0 && <Text dimColor>另 {value.hiddenCount} 項未顯示</Text>}
        </>}
      </Box>
    )
    return (
      <Box flexDirection="column" gap="sm">
        {renderBlock('sessions', 'Session', current?.sessions, '（沒有符合的 Session）')}
        {renderBlock('lines', '線', current?.lines, '（沒有線）')}
        {renderBlock('workRoots', 'work-root', current?.workRoots, '（沒有 work-root）')}
        {renderBlock('quota', '額度', current?.quota, '（沒有帳號資料）')}
        <Box flexDirection="row">
          <Text dimColor>最後更新 {updated ? new Date(updated).toLocaleTimeString('zh-TW', { hour12: false }) : '-'}{busy ? ' 更新中…' : ''}</Text>
          <Button key="refresh" label={busy ? '更新中…' : '重新整理'} onPress={() => void refresh($, options)} />
        </Box>
      </Box>
    )
  })
}
