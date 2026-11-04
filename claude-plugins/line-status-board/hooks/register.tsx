import { atom, read, update } from 'claude-code'
import type { Engine, Register } from 'claude-code'
import type { BoardBlock, BoardSnapshot } from '../types'
import { buildSnapshot, errorSnapshot, parseScriptOutput, parseSessions, REFRESH_MS } from './lib'
import type { Document, Result, Session } from './lib'

const PANE = 'line-status-board'
const snapshot = atom({ plugin: 'line-status-board', key: 'snapshot' } as const, null as BoardSnapshot | null, { shape: 'snapshot-1' })
const refreshedAt = atom({ plugin: 'line-status-board', key: 'refreshedAt' } as const, null as string | null)
const isRefreshing = atom({ plugin: 'line-status-board', key: 'isRefreshing' } as const, false)
let isBusy = false

const message = (error: unknown): string => String(error instanceof Error ? error.message : error).split(/\r?\n/)[0].slice(0, 120)

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
    const current = await read($, snapshot)
    const updated = await read($, refreshedAt)
    const busy = await read($, isRefreshing)
    const renderBlock = (title: string, value: BoardBlock | undefined, empty: string) => (
      <Box flexDirection="column">
        <Text weight="semibold">{title}（{value ? value.rows.length + value.hiddenCount : 0}）</Text>
        {value?.errorMessage && <Text color="error">{value.errorMessage}</Text>}
        {value && !value.errorMessage && value.rows.length === 0 && <Text dimColor>{empty}{value.warning ? ' ' + value.warning : ''}</Text>}
        {value?.rows.map(item => <Text wrap="truncate-end" color={item.tone === 'error' ? 'error' : undefined} dimColor={item.tone === 'dim'}>{item.text}</Text>)}
        {value && value.rows.length > 0 && value.warning && <Text dimColor>{value.warning}</Text>}
        {value && value.hiddenCount > 0 && <Text dimColor>另 {value.hiddenCount} 項未顯示</Text>}
      </Box>
    )
    return (
      <Box flexDirection="column">
        {renderBlock('Session', current?.sessions, '（沒有符合的 Session）')}
        {renderBlock('線', current?.lines, '（沒有線）')}
        {renderBlock('work-root', current?.workRoots, '（沒有 work-root）')}
        {renderBlock('額度', current?.quota, '（沒有帳號資料）')}
        <Box flexDirection="row">
          <Text dimColor>最後更新 {updated ? new Date(updated).toLocaleTimeString('zh-TW', { hour12: false }) : '-'}{busy ? ' 更新中…' : ''}</Text>
          <Button key="refresh" label={busy ? '更新中…' : '重新整理'} onPress={() => void refresh($, options)} />
        </Box>
      </Box>
    )
  })
}
