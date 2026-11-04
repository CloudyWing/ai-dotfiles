import { expect, mock, test } from 'claude-code/testing'
import type { BoardSnapshot } from '../types'
import type { On } from 'claude-code'
import { defaultWorkRoots } from '../hooks/lib'

const PANE = {
  plugin: 'line-status-board', component: 'Pane', requestId: 'line-status-board',
  props: { title: '線狀態', isFocused: false, bodyColumns: 40, placement: 'dock', scroll: { offset: 0, bodyRows: 20 }, view: {} }
} as const
const row = { name: 'item', note: 'note', dot: 'success', detail: null, bars: [], tone: 'normal' } as const
const block = { rows: [{ ...row }], hiddenCount: 0, errorMessage: null }
const snapshot: BoardSnapshot = {
  sessions: block, lines: block, workRoots: block,
  quota: { ...block, rows: [{ ...row, bars: [{ label: '5 小時', percent: 50, tone: 'success', text: '50%' }] }] },
  currentLabel: null
}
const snapshotAnswer = (value: BoardSnapshot) => ({ value: { value: { shape: 'snapshot-3', value }, version: 1 } })

test('R1 desktop components and refresh', async ($, on) => {
  mock.store(on)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(snapshot) : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  for (const id of ['sessions', 'lines', 'workRoots', 'quota']) {
    expect(await ui.find({ type: 'Button', key: `toggle-${id}` })).not.toBe(undefined)
    expect(await ui.find({ type: 'Box', key: `row-${id}-0` })).not.toBe(undefined)
  }
  expect(await ui.find({ type: 'Svg', alt: /剩餘/ })).not.toBe(undefined)
  expect(await ui.find({ type: 'Button', key: 'refresh' })).not.toBe(undefined)
  await ui.unmount()
})
test('R2 toggle persists and restores', async ($, on) => {
  let stored: unknown
  on('store.get', () => ({ value: stored }))
  on('store.set', ($, e) => { stored = e.value; return { value: undefined } })
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(snapshot) : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  await ui.press({ key: 'toggle-lines' })
  expect(await ui.find({ type: 'Box', key: 'row-lines-0' })).toBe(undefined)
  expect(await ui.find({ type: 'Text', text: /▸ 線/ })).not.toBe(undefined)
  expect(stored).toEqual(['lines'])
  await ui.press({ key: 'toggle-lines' })
  expect(await ui.find({ type: 'Box', key: 'row-lines-0' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Text', text: /▾ 線/ })).not.toBe(undefined)
  expect(stored).toEqual([])
  await ui.unmount()
})
test('R3 stored collapse on new session', async ($, on) => {
  mock.store(on, { 'collapsed-blocks': ['quota'] })
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(snapshot) : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Box', key: 'row-quota-0' })).toBe(undefined)
  for (const id of ['sessions', 'lines', 'workRoots']) expect(await ui.find({ type: 'Box', key: `row-${id}-0` })).not.toBe(undefined)
  await ui.unmount()
})
for (const [label, value] of [['missing', undefined], ['string', 'x'], ['object', {}], ['unknown', ['bogus']]] as const) {
  test(`R4 invalid store ${label}`, async ($, on) => {
    mock.store(on, value === undefined ? {} : { 'collapsed-blocks': value })
    on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(snapshot) : next(e))
    const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
    for (const id of ['sessions', 'lines', 'workRoots', 'quota']) expect(await ui.find({ type: 'Box', key: `row-${id}-0` })).not.toBe(undefined)
    await ui.unmount()
  })
}
test('R5 non desktop uses text bars', async ($, on) => {
  mock.store(on)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(snapshot) : next(e))
  for (const surface of ['terminal', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Svg' })).toBe(undefined)
    expect(await ui.find({ type: 'Text', text: /[█░]/ })).not.toBe(undefined)
    await ui.unmount()
  }
})
test('R6 no old header or extra buttons', async ($, on) => {
  mock.store(on)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(snapshot) : next(e))
  for (const surface of ['desktop', 'terminal', 'mobile', 'vscode'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /Session（|● 執行中/ })).toBe(undefined)
    expect((await ui.findAll({ type: 'Button' })).length).toBe(5)
    await ui.unmount()
  }
})

type Call = { argv: readonly string[]; cwd?: string; timeoutMs?: number }
type Fixture = { calls: Call[]; placed: boolean; cwd: string; failure: string; release?: () => void; active: number; peak: number; writes: number; sessions: object[]; document: object }
const options = { options: { workRoots: '', scriptPath: 'C:\\x\\Get-LineStatus.ps1' } }
const result = (stdout: string, exitCode = 0, stderr = '') => ({ exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false })
async function waitFor(predicate: () => boolean, calls: Call[]): Promise<void> {
  for (let i = 0; i < 200; i++) {
    if (predicate()) return
    await new Promise(resolve => setTimeout(resolve, 0))
  }
  throw new Error('等待逾時：' + JSON.stringify(calls))
}
function setup(on: On, profile = true): Fixture {
  const state: Fixture = { calls: [], placed: true, cwd: 'D:\\Work\\Other.wt\\feat', failure: '', active: 0, peak: 0, writes: 0, sessions: [], document: { scannedRoots: [], lines: [], workRoots: [], quota: [], warnings: [] } }
  mock.store(on)
  mock.clock(on)
  mock.env(on, profile ? { USERPROFILE: 'C:\\Users\\X' } : {})
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.panes', () => ({ value: [{ id: 'line-status-board', title: '線狀態', isPlaced: state.placed }] }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('classic.CwdChanged', () => ({}))
  on('session.cwd', () => ({ value: state.cwd }))
  on('mcp.call', () => ({ value: { structuredContent: { sessions: state.sessions } } }))
  on('fs.write', () => { state.writes++; return { value: undefined } })
  on('process.run', async (_, e) => {
    state.calls.push({ argv: e.argv, cwd: e.init?.cwd, timeoutMs: e.init?.timeoutMs })
    if (e.argv.includes('rev-parse')) {
      if (state.failure === 'reject') throw new Error('timeout')
      if (state.failure === 'notRepo') return { value: result('', 128) }
      const top = e.init?.cwd?.includes('Second') ? 'E:\\Second' : 'D:\\Work\\Other.wt\\feat'
      return { value: result(top + '\n') }
    }
    if (e.argv.includes('worktree')) {
      if (state.failure === 'worktree') throw new Error('timeout')
      const top = e.init?.cwd?.includes('Second') ? 'E:\\Second' : 'D:\\Work\\Other.wt\\feat'
      return { value: result(top === 'E:\\Second' ? 'worktree E:/Second\n' : 'worktree D:/Work/Other\n\nworktree D:/Work/Other.wt/feat\n\nworktree D:/Work/Other.wt/two\n') }
    }
    state.active++
    state.peak = Math.max(state.peak, state.active)
    if (state.failure === 'defer') await new Promise<void>(resolve => { state.release = resolve })
    state.active--
    if (state.failure === 'old') return { value: result('', 1, 'ForceWorkRoot unsupported') }
    return { value: result(JSON.stringify(state.document)) }
  })
  return state
}
const scripts = (state: Fixture) => state.calls.filter(call => call.argv[0] === 'powershell.exe')
const argument = (call: Call, name: string) => call.argv[call.argv.indexOf(name) + 1]
async function finish(state: Fixture, count = 1): Promise<void> {
  await waitFor(() => scripts(state).length >= count && state.active === 0, state.calls)
  for (let i = 0; i < 30; i++) await new Promise(resolve => setTimeout(resolve, 0))
}
test('H1 repo arguments', options, async ($, on) => {
  const state = setup(on)
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  expect(state.calls[0].argv).toEqual(['git', '--no-optional-locks', 'rev-parse', '--show-toplevel'])
  expect(state.calls[1].argv).toEqual(['git', '--no-optional-locks', 'worktree', 'list', '--porcelain'])
  expect(state.calls[0].cwd).toBe(state.cwd)
  expect(state.calls[1].cwd).toBe(state.cwd)
  expect(argument(scripts(state)[0], '-WorkRoot')).toBe(defaultWorkRoots('C:\\Users\\X').join(';') + ';D:\\Work\\Other;D:\\Work\\Other.wt\\feat;D:\\Work\\Other.wt\\two')
  expect(argument(scripts(state)[0], '-ForceWorkRoot')).toBe('D:\\Work\\Other;D:\\Work\\Other.wt\\feat')
})
test('H2 cwd event', options, async ($, on) => {
  const state = setup(on)
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  await $.classic.CwdChanged({ old_cwd: state.cwd, new_cwd: 'E:\\Second' })
  await finish(state, 2)
  expect(state.calls.filter(call => call.argv.includes('rev-parse'))[1].cwd).toBe('E:\\Second')
  expect(argument(scripts(state)[1], '-WorkRoot').includes('E:\\Second')).toBe(true)
  expect(argument(scripts(state)[1], '-ForceWorkRoot')).toBe('E:\\Second')
  expect(argument(scripts(state)[1], '-WorkRoot').includes('D:\\Work\\Other')).toBe(false)
})
test('H2b empty cwd event falls back to session cwd', options, async ($, on) => {
  const state = setup(on)
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  await $.classic.CwdChanged({ old_cwd: state.cwd, new_cwd: '' })
  await finish(state, 2)
  expect(state.calls.filter(call => call.argv.includes('rev-parse'))[1].cwd).toBe(state.cwd)
  expect(argument(scripts(state)[1], '-ForceWorkRoot')).toBe('D:\\Work\\Other;D:\\Work\\Other.wt\\feat')
})
test('H3 pane unplaced', options, async ($, on) => {
  const state = setup(on)
  state.placed = false
  await $.classic.CwdChanged({ old_cwd: state.cwd, new_cwd: 'E:\\Second' })
  for (let i = 0; i < 30; i++) await new Promise(resolve => setTimeout(resolve, 0))
  expect(state.calls.length).toBe(0)
})
test('H4 busy cwd coalescing', options, async ($, on) => {
  const state = setup(on)
  state.failure = 'defer'
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await waitFor(() => !!state.release, state.calls)
  await $.classic.CwdChanged({ old_cwd: state.cwd, new_cwd: 'E:\\Second\\B' })
  await $.classic.CwdChanged({ old_cwd: 'E:\\Second\\B', new_cwd: 'E:\\Second\\C' })
  for (let i = 0; i < 10; i++) await new Promise(resolve => setTimeout(resolve, 0))
  state.failure = ''
  state.release?.()
  await finish(state, 2)
  expect(state.peak).toBe(1)
  expect(scripts(state).length).toBe(2)
  expect(state.calls.filter(call => call.argv.includes('rev-parse')).map(call => call.cwd)).toEqual([state.cwd, 'E:\\Second\\C'])
})
test('H5 git reject', options, async ($, on) => {
  const state = setup(on)
  state.failure = 'reject'
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  expect(scripts(state)[0].argv.includes('-ForceWorkRoot')).toBe(false)
  expect(scripts(state)[0].argv.includes('-WorkRoot')).toBe(false)
})
test('H5 git reject with configured roots', { options: { workRoots: 'D:\\a', scriptPath: 'C:\\x\\Get-LineStatus.ps1' } }, async ($, on) => {
  const state = setup(on)
  state.failure = 'reject'
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  expect(argument(scripts(state)[0], '-WorkRoot')).toBe('D:\\a')
  expect(scripts(state)[0].argv.includes('-ForceWorkRoot')).toBe(false)
})
test('H6 non Git and partial failure', options, async ($, on) => {
  const state = setup(on)
  state.failure = 'notRepo'
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  expect(argument(scripts(state)[0], '-ForceWorkRoot')).toBe(state.cwd)
  expect(argument(scripts(state)[0], '-WorkRoot')).toBe(defaultWorkRoots('C:\\Users\\X').join(';') + ';' + state.cwd)
  state.failure = 'worktree'
  await $.classic.CwdChanged({ old_cwd: state.cwd, new_cwd: 'E:\\Second' })
  await finish(state, 2)
  expect(argument(scripts(state)[1], '-ForceWorkRoot')).toBe('E:\\Second')
  expect(argument(scripts(state)[1], '-WorkRoot')).toBe(defaultWorkRoots('C:\\Users\\X').join(';') + ';E:\\Second')
})
test('H7 time budget and missing profile', options, async ($, on) => {
  const state = setup(on, false)
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  expect(state.calls.filter(call => call.argv[0] === 'git').every(call => call.timeoutMs === 3000)).toBe(true)
  expect(scripts(state)[0].timeoutMs! >= 34000 && scripts(state)[0].timeoutMs! <= 40000).toBe(true)
  expect(scripts(state)[0].argv.includes('-WorkRoot')).toBe(false)
  expect(scripts(state)[0].argv.includes('-ForceWorkRoot')).toBe(true)
})
test('H8 readonly git', options, async ($, on) => {
  const state = setup(on)
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  expect(state.calls.filter(call => call.argv[0] === 'git').every(call => ['rev-parse', 'worktree'].includes(call.argv[2]))).toBe(true)
  expect(state.writes).toBe(0)
})
test('H9 old script error', options, async ($, on) => {
  const state = setup(on)
  state.failure = 'old'
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.findAll({ type: 'Text', text: /ForceWorkRoot/ })).length).toBe(3)
  expect(scripts(state).length).toBe(1)
  await ui.unmount()
})

test('R7 current label on all surfaces', async ($, on) => {
  mock.store(on)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer({ ...snapshot, currentLabel: '目前：Other' }) : next(e))
  for (const surface of ['desktop', 'terminal', 'mobile', 'vscode'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    const label = await ui.find({ type: 'Text', text: '目前：Other' })
    expect(label).not.toBe(undefined)
    expect((await ui.findAll({ type: 'Text' }))[0]).toEqual(label)
    await ui.unmount()
  }
})
test('R8 no current label', async ($, on) => {
  mock.store(on)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(snapshot) : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: /^目前：/ })).toBe(undefined)
  await ui.unmount()
})
test('R8 unloaded snapshot', async ($, on) => {
  mock.store(on)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: /^目前：/ })).toBe(undefined)
  await ui.unmount()
})
test('R9 current repo and sessions', options, async ($, on) => {
  const state = setup(on)
  state.sessions = [{ cwd: state.cwd, title: 'Other session' }]
  state.document = { scannedRoots: ['D:\\Work\\Other.wt\\feat'], lines: [], workRoots: [{ Path: 'C:\\Unrelated' }, { Path: 'D:\\Work\\Other' }], quota: [], warnings: [] }
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: '目前：Other' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Box', key: 'row-sessions-0' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Box', key: 'row-workRoots-0' })).not.toBe(undefined)
  const text = (await ui.findAll({ type: 'Text' })).map(item => item.text)
  expect(text.indexOf('Other') >= 0 && text.indexOf('Other') < text.indexOf('Unrelated')).toBe(true)
  await ui.unmount()
})
