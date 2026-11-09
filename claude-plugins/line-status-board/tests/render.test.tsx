import { expect, mock, test } from 'claude-code/testing'
import type { BoardSnapshot, CleanupItem, CleanupPlan } from '../types'
import type { Engine, On } from 'claude-code'
import { buildSnapshot, defaultWorkRoots } from '../hooks/lib'
import { notify } from '../hooks/register'

const PANE = {
  plugin: 'line-status-board', component: 'Pane', requestId: 'line-status-board',
  props: { title: '工作總覽', isFocused: false, bodyColumns: 40, placement: 'dock', scroll: { offset: 0, bodyRows: 20 }, view: {} }
} as const
const row = { name: 'item', tag: '', right: '', rightShrink: false, dot: 'inactive', detail: null, bar: null, tone: 'normal', isCurrent: false, link: null, login: null } as const
const block = { rows: [{ ...row }], stalledRows: [], hiddenCount: 0, errorMessage: null }
const snapshot: BoardSnapshot = {
  sessions: { ...block, rows: [{ ...row, dot: 'success', tag: 'line-one', right: '剛剛' }] },
  quota: { ...block, rows: [{ ...row, dot: 'warning', right: '剩 40%', bar: { percent: 40, tone: 'warning', window: '5 小時' }, detail: [{ text: '週 ', tone: 'normal' }, { text: '28%', tone: 'attention' }] }] },
  lines: { ...block, rows: [{ ...row }] },
  workRoots: { ...block, rows: [{ ...row, dot: 'warning', right: 'main', rightShrink: true, isCurrent: true, detail: [{ text: '3', tone: 'attention' }, { text: ' 未 commit', tone: 'normal' }] }] },
  currentLabel: null,
  scannedRoots: []
}
const snapshotAnswer = (value: BoardSnapshot) => ({ value: { value: { shape: 'snapshot-6', value }, version: 1 } })

const loginText = '$env:CODEX_HOME = "C:\\Users\\X\\.codex-a"; codex login; Remove-Item Env:CODEX_HOME'
const loginSnapshot: BoardSnapshot = { ...snapshot, quota: { ...snapshot.quota, rows: [{ ...row, name: 'account · 登入失效', dot: 'error', tone: 'error', login: { account: 'account', command: loginText } }] } }

test('P7 phase 4 opens only Desktop Session rows through process fallback', async ($, on) => {
  mock.store(on)
  const link = 'claude://claude.ai/epitaxy/local_123'
  const linked: BoardSnapshot = {
    ...snapshot,
    sessions: { ...block, rows: [{ ...row, name: 'linked session', link }, { ...row, name: 'plain session' }] },
    quota: { ...block, rows: [{ ...row, name: 'quota row', link }] },
    lines: { ...block, rows: [{ ...row, name: 'line row', link }] },
    workRoots: { ...block, rows: [{ ...row, name: 'root row', link }] }
  }
  const calls: string[][] = []
  const toasts: string[] = []
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(linked) : next(e))
  on('process.run', (_, e) => { calls.push([...e.argv]); return { value: result('', 1) } })
  on('ui.toast', (_, e) => { toasts.push(e.text); return { value: undefined } })
  const desktop = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await desktop.findAll({ type: 'Link' })).length).toBe(0)
  expect(await desktop.find({ type: 'Button', key: 'session-open-0' })).not.toBe(undefined)
  expect(await desktop.find({ type: 'Button', key: 'session-open-1' })).toBe(undefined)
  await desktop.press({ key: 'session-open-0' })
  expect(calls).toEqual([['explorer.exe', link]])
  expect(toasts).toEqual([])
  for (const name of ['plain session', 'quota row', 'line row', 'root row']) expect(await desktop.find({ type: 'Text', text: name })).not.toBe(undefined)
  await desktop.unmount()
  for (const surface of ['terminal', 'mobile', 'vscode'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.findAll({ type: 'Link' })).length).toBe(0)
    expect(await ui.find({ type: 'Text', text: 'linked session' })).not.toBe(undefined)
    expect(await ui.find({ type: 'Text', text: 'plain session' })).not.toBe(undefined)
    await ui.unmount()
  }
})
test('P7 phase 4 process rejection shows a toast', async ($, on) => {
  mock.store(on)
  const linked: BoardSnapshot = { ...snapshot, sessions: { ...block, rows: [{ ...row, link: 'claude://claude.ai/epitaxy/local_123' }] } }
  const toasts: string[] = []
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(linked) : next(e))
  on('process.run', () => { throw new Error('process failed') })
  on('ui.toast', (_, e) => { toasts.push(e.text); return { value: undefined } })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  await ui.press({ key: 'session-open-0' })
  expect(toasts).toEqual(['無法開啟 Session'])
  await ui.unmount()
})

test('P7 phase 2 login copy uses the active surface and reports success', async ($, on) => {
  mock.store(on)
  const calls: { text: string; surface?: string }[] = []
  const toasts: string[] = []
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(loginSnapshot) : next(e))
  on('ui.copy', (_, e) => { calls.push({ text: e.text, surface: e.surface }); return { value: { isCopied: true } } })
  on('ui.toast', (_, e) => { toasts.push(e.text); return { value: undefined } })
  for (const surface of ['desktop', 'terminal', 'mobile', 'vscode'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Button', key: 'copy-login-account' })).not.toBe(undefined)
    await ui.press({ key: 'copy-login-account' })
    expect(await ui.find({ type: 'Text', text: loginText })).toBe(undefined)
    await ui.unmount()
  }
  expect(calls).toEqual(['desktop', 'terminal', 'mobile', 'vscode'].map(surface => ({ text: loginText, surface })))
  expect(toasts).toEqual(Array(4).fill('已複製 account 的登入命令'))
})
for (const failure of ['no-clipboard', 'reject'] as const) test(`P7 phase 2 copy ${failure} reveals the command`, async ($, on) => {
  mock.store(on)
  const toasts: string[] = []
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(loginSnapshot) : next(e))
  on('ui.copy', () => { if (failure === 'reject') throw new Error('copy failed'); return { value: { isCopied: false, reason: 'no-clipboard' } } })
  on('ui.toast', (_, e) => { toasts.push(e.text); return { value: undefined } })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  await ui.press({ key: 'copy-login-account' })
  const command = await ui.find({ type: 'Text', text: loginText })
  expect(command?.props.mono).toBe(true)
  expect(toasts).toEqual([`無法複製（${failure === 'reject' ? 'no implementation for ui.copy' : failure}），已改顯示命令`])
  await ui.unmount()
})
test('P7 phase 2 invalid login path displays guidance without copy', async ($, on) => {
  mock.store(on)
  const invalid: BoardSnapshot = { ...loginSnapshot, quota: { ...loginSnapshot.quota, rows: [{ ...row, login: { account: 'account', command: null } }] } }
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(invalid) : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: 'CodexHome 路徑含特殊字元，請手動登入' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Button', key: 'copy-login-account' })).toBe(undefined)
  await ui.unmount()
})
test('P7 phase 2 previous snapshot shape is treated as absent', async ($, on) => {
  mock.store(on)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? { value: { value: { shape: 'snapshot-' + '5', value: snapshot }, version: 1 } } : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Box', key: 'row-sessions-0' })).toBe(undefined)
  await ui.unmount()
})

test('R1 desktop components and refresh', async ($, on) => {
  mock.store(on)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(snapshot) : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  for (const id of ['sessions', 'lines', 'workRoots', 'quota']) {
    expect(await ui.find({ type: 'Button', key: `toggle-${id}` })).not.toBe(undefined)
    expect(await ui.find({ type: 'Box', key: `row-${id}-0` })).not.toBe(undefined)
  }
  expect((await ui.findAll({ type: 'Svg' })).some(item => /剩餘/.test(String(item.props.alt)))).toBe(true)
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
  expect(await ui.find({ type: 'Text', text: /^工作線 .*▸$/ })).not.toBe(undefined)
  expect(stored).toEqual(['lines'])
  await ui.press({ key: 'toggle-lines' })
  expect(await ui.find({ type: 'Box', key: 'row-lines-0' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Text', text: /^工作線 .*▾$/ })).not.toBe(undefined)
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
    expect((await ui.findAll({ type: 'Text', text: /^─+$/ })).length).toBe(3)
    await ui.unmount()
  }
})
test('R6 no old header or extra buttons', async ($, on) => {
  mock.store(on)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(snapshot) : next(e))
  for (const surface of ['desktop', 'terminal', 'mobile', 'vscode'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /Session（|● 執行中/ })).toBe(undefined)
    expect((await ui.findAll({ type: 'Button' })).length).toBe(6)
    await ui.unmount()
  }
})
test('R10 R11 block order and titles', async ($, on) => {
  mock.store(on)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(snapshot) : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.findAll({ type: 'Button' })).map(x => x.key)).toEqual(['toggle-sessions', 'toggle-quota', 'toggle-lines', 'toggle-workRoots', 'cleanup-open', 'refresh'])
  for (const title of ['Session 顯示 1 個，共 1 個 ▾', 'Codex 額度 顯示 1 個帳號，共 1 個帳號 ▾', '工作線 顯示 1 條，共 1 條 ▾', '工作目錄 顯示 1 個，共 1 個 ▾']) expect(await ui.find({ type: 'Text', text: title })).not.toBe(undefined)
  for (const id of ['sessions', 'quota', 'lines', 'workRoots']) expect(await ui.find({ type: 'Box', key: `row-${id}-0` })).not.toBe(undefined)
  await ui.unmount()
})
test('R11b empty states use section names', async ($, on) => {
  const emptyBlock = { ...block, rows: [] }
  mock.store(on)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer({ ...snapshot, quota: emptyBlock, lines: emptyBlock, workRoots: emptyBlock }) : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  for (const text of ['（沒有 Codex 帳號資料）', '（沒有工作線）', '（沒有工作目錄）']) expect(await ui.find({ type: 'Text', text })).not.toBe(undefined)
  await ui.unmount()
})
test('R12 R13 dot and number colours', async ($, on) => {
  mock.store(on)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(snapshot) : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.findAll({ type: 'Text', text: '●' })).map(x => x.props.color)).toEqual(['success', 'warning', 'inactive', 'warning'])
  expect((await ui.findAll({ type: 'Text' })).some(x => x.text === '3' && x.props.color === 'warning')).toBe(true)
  expect((await ui.findAll({ type: 'Text' })).some(x => x.text === '28%' && x.props.color === 'warning')).toBe(true)
  expect((await ui.findAll({ type: 'Text' })).some(x => x.text === ' 未 commit' && x.props.dimColor === true)).toBe(true)
  expect((await ui.findAll({ type: 'Text' })).filter(x => x.text !== '●' && (x.props.color === 'success' || x.props.color === 'error')).length).toBe(0)
  await ui.unmount()
})
test('R14 R15 dividers and icons', async ($, on) => {
  mock.store(on)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(snapshot) : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  const svg = await ui.findAll({ type: 'Svg' })
  expect(svg[0].props.alt).toBe('Session 圖示')
  const dividers = svg.filter(x => x.props.alt === '分隔線')
  expect(dividers.length).toBe(3)
  expect(dividers.every(x => x.props.height === 1 && x.props.width === undefined)).toBe(true)
  for (const alt of ['Session 圖示', 'Codex 額度圖示', '工作線圖示', '工作目錄圖示']) {
    const icons = svg.filter(x => x.props.alt === alt)
    expect(icons.length).toBe(1)
    expect(icons[0].props.width).toBe(14)
    expect(icons[0].props.height).toBe(14)
  }
  await ui.unmount()
  for (const surface of ['terminal', 'mobile'] as const) {
    const other = await $.ui.mount({ ...PANE, surface })
    expect((await other.findAll({ type: 'Svg' })).length).toBe(0)
    expect((await other.findAll({ type: 'Text', text: /^─+$/ })).map(x => x.text?.length)).toEqual([40, 40, 40])
    await other.unmount()
  }
})
test('R16 layout shrink and current background', async ($, on) => {
  mock.store(on)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(snapshot) : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  const boxes = await ui.findAll({ type: 'Box' })
  expect(boxes.find(x => x.text === '剛剛')?.props.flexShrink).toBe(0)
  expect(boxes.filter(x => x.props.flexShrink === 8).length).toBe(2)
  expect(boxes.some(x => x.props.flexShrink === 1)).toBe(true)
  expect(boxes.filter(x => x.props.paddingLeft === 2).length).toBe(4)
  expect((await ui.find({ type: 'Box', key: 'row-workRoots-0' }))?.props.backgroundColor).toBe('#80808014')
  expect((await ui.find({ type: 'Box', key: 'row-sessions-0' }))?.props.backgroundColor).toBe(undefined)
  await ui.unmount()
})
const withStalled: BoardSnapshot = { ...snapshot, lines: { ...snapshot.lines, stalledRows: [{ ...row, name: 'old-a' }, { ...row, name: 'old-b' }] } }
test('R17 stalled toggle persists independently', async ($, on) => {
  let expandedValue: unknown
  let collapsedValue: unknown = ['quota']
  on('store.get', (_, e) => ({ value: e.key === 'expanded-sections' ? expandedValue : collapsedValue }))
  on('store.set', (_, e) => { if (e.key === 'expanded-sections') expandedValue = e.value; else collapsedValue = e.value; return { value: undefined } })
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(withStalled) : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: '工作線 顯示 1 條，共 3 條 ▾' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Text', text: '已結束／停擺 2 條 ▸' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Box', key: 'row-stalledLines-0' })).toBe(undefined)
  await ui.press({ key: 'toggle-stalledLines' })
  expect(await ui.find({ type: 'Box', key: 'row-stalledLines-0' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Box', key: 'row-stalledLines-1' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Text', text: '工作線 顯示 3 條，共 3 條 ▾' })).not.toBe(undefined)
  expect(expandedValue).toEqual(['stalledLines'])
  expect(collapsedValue).toEqual(['quota'])
  await ui.press({ key: 'toggle-stalledLines' })
  expect(expandedValue).toEqual([])
  await ui.unmount()
})
test('R18 stored expanded state and invalid values', async ($, on) => {
  let value: unknown = ['stalledLines']
  on('store.get', (_, e) => ({ value: e.key === 'expanded-sections' ? value : ['quota'] }))
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(withStalled) : next(e))
  let ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Box', key: 'row-stalledLines-0' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Box', key: 'row-quota-0' })).toBe(undefined)
  await ui.unmount()
  for (value of [undefined, 'x', {}, ['bogus']]) {
    ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
    expect(await ui.find({ type: 'Box', key: 'row-stalledLines-0' })).toBe(undefined)
    await ui.unmount()
  }
})
test('R19 line name dim tone', async ($, on) => {
  mock.store(on)
  const value: BoardSnapshot = { ...snapshot, lines: { ...snapshot.lines, rows: [{ ...row, name: 'dim-line', tone: 'dim' }, { ...row, name: 'normal-line' }] } }
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(value) : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: 'dim-line' }))?.props.dimColor).toBe(true)
  expect((await ui.find({ type: 'Text', text: 'normal-line' }))?.props.dimColor).toBe(false)
  await ui.unmount()
})
test('R20 note responds to body columns', async ($, on) => {
  mock.store(on)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(snapshot) : next(e))
  for (const columns of [28, 27, undefined]) {
    const props = { ...PANE.props, bodyColumns: columns }
    const ui = await $.ui.mount({ ...PANE, props, surface: 'desktop' })
    expect(!!(await ui.find({ type: 'Text', text: 'line-one' }))).toBe(columns !== 27)
    expect(await ui.find({ type: 'Text', text: 'item' })).not.toBe(undefined)
    expect(await ui.find({ type: 'Text', text: '剛剛' })).not.toBe(undefined)
    await ui.unmount()
  }
})
test('R21 line label in right column without detail', async ($, on) => {
  mock.store(on)
  const value: BoardSnapshot = { ...snapshot, quota: { ...snapshot.quota, rows: [] }, workRoots: { ...snapshot.workRoots, rows: [] }, lines: { ...snapshot.lines, rows: [{ ...row, name: 'line', right: '設計驗收 · 1 天前' }] } }
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(value) : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: '設計驗收 · 1 天前' })).not.toBe(undefined)
  expect((await ui.findAll({ type: 'Text', text: '設計驗收 · 1 天前' }))[0].props.size).toBe('footnote')
  expect((await ui.findAll({ type: 'Text' })).some(item => item.props.size === 'caption')).toBe(false)
  await ui.unmount()
})
test('R22 quota and folded label', async ($, on) => {
  mock.store(on)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(withStalled) : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: '剩 40%' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Text', text: '已結束／停擺 2 條 ▸' })).not.toBe(undefined)
  await ui.press({ key: 'toggle-stalledLines' })
  expect(await ui.find({ type: 'Text', text: '已結束／停擺 2 條 ▾' })).not.toBe(undefined)
  await ui.unmount()
})

test('R23 quota row without a weekly window', async ($, on) => {
  mock.store(on)
  const noWeekly: BoardSnapshot = { ...snapshot, quota: { ...snapshot.quota, rows: [{ ...row, dot: 'warning', right: '剩 40%', bar: { percent: 40, tone: 'warning', window: '5 小時' }, detail: [{ text: '無週視窗', tone: 'normal' }] }] } }
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(noWeekly) : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Box', key: 'row-quota-0' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Text', text: '無週視窗' })).not.toBe(undefined)
  await ui.unmount()
})

test('R24 quota bar alt text follows the account window length', async ($, on) => {
  mock.store(on)
  const quota = [
    { Name: 'monthly', State: 'ok', PrimaryRemaining: 40, PrimaryWindowMinutes: 43200 },
    { Name: 'short', State: 'ok', PrimaryRemaining: 40, PrimaryWindowMinutes: 300, SecondaryRemaining: 70 },
    { Name: 'legacy', State: 'ok', PrimaryRemaining: 40 },
    { Name: 'unknown-level', State: 'ok', PrimaryWindowMinutes: 43200 }
  ]
  const built = buildSnapshot({ ok: true, value: { scannedRoots: [], lines: [], workRoots: [], quota, warnings: [] } }, { ok: true, value: [] }, new Date('2026-11-05T01:23:10Z'), null)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? snapshotAnswer(built) : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  const alts = (await ui.findAll({ type: 'Svg' })).map(item => String(item.props.alt)).filter(alt => /剩餘/.test(alt))
  expect(alts).toEqual(['30 天剩餘 40%', '5 小時剩餘 40%', '5 小時剩餘 40%', '30 天剩餘量未知'])
  await ui.unmount()
})

type Call = { argv: readonly string[]; cwd?: string; timeoutMs?: number }
type Fixture = { calls: Call[]; placed: boolean; cwd: string; failure: string; release?: () => void; active: number; peak: number; writes: number; sessions: object[]; sessionFailure?: boolean; document: object; porcelain?: string; branches: string; branchFailure?: 'exit' | 'reject' }
const options = { options: { workRoots: '', scriptPath: 'C:\\x\\Get-LineStatus.ps1' } }
const result = (stdout: string, exitCode = 0, stderr = '') => ({ exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false })
async function waitFor(predicate: () => boolean, calls: Call[]): Promise<void> {
  for (let i = 0; i < 200; i++) {
    if (predicate()) return
    await new Promise(resolve => setTimeout(resolve, 0))
  }
  throw new Error('等待逾時：' + JSON.stringify(calls))
}
function setup(on: On, profile = true, useStore = true): Fixture {
  const state: Fixture = { calls: [], placed: true, cwd: 'D:\\Work\\Other.wt\\feat', failure: '', active: 0, peak: 0, writes: 0, sessions: [], branches: '', document: { scannedRoots: [], lines: [], workRoots: [], quota: [], warnings: [] } }
  if (useStore) mock.store(on)
  mock.clock(on)
  mock.env(on, profile ? { USERPROFILE: 'C:\\Users\\X' } : {})
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.panes', () => ({ value: [{ id: 'line-status-board', title: '工作總覽', isPlaced: state.placed }] }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('classic.CwdChanged', () => ({}))
  on('session.cwd', () => ({ value: state.cwd }))
  on('mcp.call', () => {
    if (state.sessionFailure) throw new Error('session list failed')
    return { value: { structuredContent: { sessions: state.sessions } } }
  })
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
      return { value: result(state.porcelain ?? (top === 'E:\\Second' ? 'worktree E:/Second\n' : 'worktree D:/Work/Other\n\nworktree D:/Work/Other.wt/feat\n\nworktree D:/Work/Other.wt/two\n')) }
    }
    if (e.argv.includes('branch')) {
      if (state.branchFailure === 'reject') throw new Error('timeout')
      return { value: result(state.branches, state.branchFailure === 'exit' ? 1 : 0) }
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
const scripts = (state: Fixture) => state.calls.filter(call => call.argv[0] === 'pwsh')
const argument = (call: Call, name: string) => call.argv[call.argv.indexOf(name) + 1]
async function finish(state: Fixture, count = 1): Promise<void> {
  await waitFor(() => scripts(state).length >= count && state.active === 0, state.calls)
  for (let i = 0; i < 30; i++) await new Promise(resolve => setTimeout(resolve, 0))
}
test('P7 phase 3 session refresh reports one transition and keeps baseline on failure', options, async ($, on) => {
  const state = setup(on)
  const toasts: string[] = []
  state.sessions = [{ sessionId: 'one', cwd: state.cwd, title: '任務一', isRunning: true }]
  state.document = { scannedRoots: [state.cwd], lines: [], workRoots: [], quota: [], warnings: [] }
  on('ui.toast', (_, e) => { toasts.push(e.text); return { value: undefined } })
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  expect(toasts).toEqual([])
  state.sessions = [{ sessionId: 'one', cwd: state.cwd, title: '任務一', isRunning: false }]
  state.sessionFailure = true
  await $.classic.CwdChanged({ old_cwd: state.cwd, new_cwd: state.cwd })
  await finish(state, 2)
  expect(toasts).toEqual([])
  state.sessionFailure = false
  await $.classic.CwdChanged({ old_cwd: state.cwd, new_cwd: state.cwd })
  await finish(state, 3)
  expect(toasts).toEqual(['「任務一」已跑完'])
  await $.classic.CwdChanged({ old_cwd: state.cwd, new_cwd: state.cwd })
  await finish(state, 4)
  expect(toasts).toEqual(['「任務一」已跑完'])
})
test('P7 phase 3 disabled session notification remains silent', { options: { ...options.options, notifySessionDone: false } }, async ($, on) => {
  const state = setup(on)
  const toasts: string[] = []
  state.sessions = [{ sessionId: 'disabled', cwd: state.cwd, isRunning: true }]
  state.document = { scannedRoots: [state.cwd], lines: [], workRoots: [], quota: [], warnings: [] }
  on('ui.toast', (_, e) => { toasts.push(e.text); return { value: undefined } })
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  state.sessions = [{ sessionId: 'disabled', cwd: state.cwd, isRunning: false }]
  await $.classic.CwdChanged({ old_cwd: state.cwd, new_cwd: state.cwd })
  await finish(state, 2)
  expect(toasts).toEqual([])
})
test('P7 phase 3 enabling session notification does not replay disabled transitions', async () => {
  const toasts: string[] = []
  const cwd = 'D:\\Work\\Switch'
  const script = { ok: true as const, value: { scannedRoots: [cwd], lines: [], workRoots: [], quota: [], warnings: [] } }
  const sessions = (isRunning: boolean) => ({ ok: true as const, value: [{ sessionId: 'switch', cwd, isRunning }] })
  const engine = { store: { get: async () => null, set: async () => {} }, ui: { toast: (text: string) => toasts.push(text) } } as unknown as Engine
  await notify(engine, { notifySessionDone: false }, script, sessions(true))
  await notify(engine, { notifySessionDone: false }, script, sessions(false))
  await notify(engine, { notifySessionDone: true }, script, sessions(false))
  expect(toasts).toEqual([])
  await notify(engine, { notifySessionDone: true }, script, sessions(true))
  await notify(engine, { notifySessionDone: true }, script, sessions(false))
  expect(toasts).toEqual(['「switch」已跑完'])
})
test('P7 phase 3 stored quota signature prevents a repeat on startup', options, async ($, on) => {
  const state = setup(on, true, false)
  const toasts: string[] = []
  let reads = 0
  let writes = 0
  state.document = { scannedRoots: [state.cwd], lines: [], workRoots: [], quota: [{ Name: 'stored', State: 'ok', PrimaryRemaining: 7, PrimaryResetsAtLocal: 'T' }], warnings: [] }
  on('store.get', (_, e) => { if (e.key === 'quota-alert') reads++; return { value: 'stored@T' } })
  on('store.set', () => { writes++; return { value: undefined } })
  on('ui.toast', (_, e) => { toasts.push(e.text); return { value: undefined } })
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  expect([reads, writes]).toEqual([1, 0])
  expect(toasts).toEqual([])
})
test('P7 phase 3 quota signature persists and rearms after reset', options, async ($, on) => {
  const state = setup(on, true, false)
  const toasts: string[] = []
  const saved: unknown[] = []
  state.document = { scannedRoots: [state.cwd], lines: [], workRoots: [], quota: [{ Name: 'a', State: 'ok', PrimaryRemaining: 10, PrimaryResetsAtLocal: 'T' }], warnings: [] }
  on('store.get', (_, e, next) => e.key === 'quota-alert' ? { value: null } : next(e))
  on('store.set', (_, e, next) => { if (e.key !== 'quota-alert') return next(e); saved.push(e.value); return { value: undefined } })
  on('ui.toast', (_, e) => { toasts.push(e.text); return { value: undefined } })
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  expect(saved).toEqual(['a@T'])
  expect(toasts).toEqual(['Codex 5 小時額度：a 剩 10%'])
  await $.classic.CwdChanged({ old_cwd: state.cwd, new_cwd: state.cwd })
  await finish(state, 2)
  expect(saved).toEqual(['a@T'])
  expect(toasts.length).toBe(1)
  state.failure = 'old'
  await $.classic.CwdChanged({ old_cwd: state.cwd, new_cwd: state.cwd })
  await finish(state, 3)
  expect(saved).toEqual(['a@T'])
  expect(toasts.length).toBe(1)
  state.failure = ''
  state.document = { scannedRoots: [state.cwd], lines: [], workRoots: [], quota: [{ Name: 'a', State: 'ok', PrimaryRemaining: 10, PrimaryResetsAtLocal: 'T2' }], warnings: [] }
  await $.classic.CwdChanged({ old_cwd: state.cwd, new_cwd: state.cwd })
  await finish(state, 4)
  expect(saved).toEqual(['a@T', 'a@T2'])
  expect(toasts.length).toBe(2)
})
test('P7 phase 3 quota store write failure keeps in-memory signature', options, async ($, on) => {
  const state = setup(on, true, false)
  const toasts: string[] = []
  let writes = 0
  state.document = { scannedRoots: [state.cwd], lines: [], workRoots: [], quota: [{ Name: 'b', State: 'ok', PrimaryRemaining: 5, PrimaryResetsAtLocal: 'W' }], warnings: [] }
  on('store.get', (_, e, next) => e.key === 'quota-alert' ? { value: null } : next(e))
  on('store.set', (_, e, next) => { if (e.key !== 'quota-alert') return next(e); writes++; throw new Error('store unavailable') })
  on('ui.toast', (_, e) => { toasts.push(e.text); return { value: undefined } })
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  await $.classic.CwdChanged({ old_cwd: state.cwd, new_cwd: state.cwd })
  await finish(state, 2)
  expect(writes).toBe(1)
  expect(toasts).toEqual(['Codex 5 小時額度：b 剩 5%'])
})
test('P7 phase 2 refresh publishes scoped running count and lowest quota', options, async ($, on) => {
  const state = setup(on)
  const statuses: (string | undefined)[] = []
  state.sessions = [{ cwd: state.cwd, isRunning: true }, { cwd: state.cwd, isRunning: false }, { cwd: 'C:\\outside', isRunning: true }]
  state.document = { scannedRoots: [state.cwd], lines: [], workRoots: [], quota: [{ Name: 'a', State: 'ok', PrimaryRemaining: 3 }, { Name: 'b', State: 'unknown', PrimaryRemaining: 0 }], warnings: [] }
  on('ui.status', (_, e) => { statuses.push(e.text); return { value: undefined } })
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  expect(statuses).toEqual(['1 執行中 · 額度 3%'])
})
test('P7 phase 2 status failure does not prevent snapshot update', options, async ($, on) => {
  const state = setup(on)
  let attempted = false
  state.document = { scannedRoots: [state.cwd], lines: [], workRoots: [], quota: [{ Name: 'a', State: 'unknown', ErrorKind: 'limit-reached' }], warnings: [] }
  on('ui.status', () => { attempted = true; throw new Error('status failed') })
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  expect(attempted).toBe(true)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: 'a · 已達上限' })).not.toBe(undefined)
  await ui.unmount()
})
test('H0 opens the work overview pane', async ($, on) => {
  let title: string | undefined
  mock.clock(on)
  on('ui.open', (_, event) => { title = event.title; return { value: { isPlaced: false } } })
  on('session.start', (_, event) => ({ cwd: event.cwd }))
  await $.session.start({ cwd: 'D:\\Work\\Other', surface: 'desktop', isInteractive: true })
  expect(title).toBe('工作總覽')
})
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
test('H10 excludes dispatch worktrees from script arguments', options, async ($, on) => {
  const state = setup(on)
  state.porcelain = 'worktree D:/Work/Other\n\nworktree D:/Work/Other.wt/feat\n\nworktree D:/Work/Other/.local/ai-sessions/worktrees/dev-dd-1\n\nworktree D:/Work/Other/.local/ai-sessions/worktrees/rev-2\n'
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  expect(argument(scripts(state)[0], '-WorkRoot').includes('D:\\Work\\Other.wt\\feat')).toBe(true)
  expect(argument(scripts(state)[0], '-WorkRoot').includes('ai-sessions\\worktrees')).toBe(false)
  expect(argument(scripts(state)[0], '-ForceWorkRoot').includes('ai-sessions\\worktrees')).toBe(false)
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
  expect(state.calls.filter(call => call.argv[0] === 'git').every(call => ['rev-parse', 'worktree', 'branch'].includes(call.argv[2]))).toBe(true)
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
test('H11 branch command once', options, async ($, on) => {
  const state = setup(on)
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  const calls = state.calls.filter(call => call.argv.includes('branch'))
  expect(calls.length).toBe(1)
  expect(calls[0]).toEqual({ argv: ['git', '--no-optional-locks', 'branch', '--no-color', '--list', 'feature/*'], cwd: 'D:\\Work\\Other', timeoutMs: 3000 })
})
const landedDocument = {
  scannedRoots: ['D:\\Work\\Other', 'D:\\Work\\Other.wt\\feat'],
  lines: [{ LineSlug: 'landed', WorkRoot: 'D:\\Work\\Other.wt\\feat', CheckpointType: 'developer-collected', CheckpointUpdatedUtc: new Date().toISOString() }, { LineSlug: 'landed', WorkRoot: 'D:\\Work\\Other' }],
  workRoots: [{ Path: 'D:\\Work\\Other', IsLinkedWorktree: false }, { Path: 'D:\\Work\\Other.wt\\feat', IsLinkedWorktree: true }], quota: [], warnings: []
}
test('H12 landed line is folded', options, async ($, on) => {
  const state = setup(on)
  state.document = landedDocument
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Box', key: 'row-lines-0' })).toBe(undefined)
  expect(await ui.find({ type: 'Text', text: '已結束／停擺 1 條 ▸' })).not.toBe(undefined)
  await ui.unmount()
})
for (const failure of ['exit', 'reject'] as const) test(`H13 branch ${failure}`, options, async ($, on) => {
  const state = setup(on)
  state.document = landedDocument
  state.branchFailure = failure
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Box', key: 'row-lines-0' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Button', key: 'toggle-stalledLines' })).toBe(undefined)
  expect(scripts(state).length).toBe(1)
  await ui.unmount()
})
test('H14 existing branch and unavailable repository', options, async ($, on) => {
  const state = setup(on)
  state.document = landedDocument
  state.branches = '* feature/landed\n'
  await $.session.start({ cwd: state.cwd, surface: 'desktop', isInteractive: true })
  await finish(state)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Box', key: 'row-lines-0' })).not.toBe(undefined)
  await ui.unmount()
  for (const failure of ['reject', 'notRepo']) {
    state.failure = failure
    const before = state.calls.filter(call => call.argv.includes('branch')).length
    await $.classic.CwdChanged({ old_cwd: state.cwd, new_cwd: 'E:\\Second' })
    await finish(state, failure === 'reject' ? 2 : 3)
    expect(state.calls.filter(call => call.argv.includes('branch')).length).toBe(before)
  }
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

const cleanupEntry: CleanupItem = { id: 'dispatch:one', kind: 'dispatchWorktree', root: 'C:\\one', path: 'C:\\one\\dispatch', name: 'dev-one', lineSlug: 'line-one', category: null, status: 'cleanable', reasons: [], sizeBytes: 1536, fileCount: 5, protectedFileCount: 0, trackedChangeCount: 3, untrackedCount: 2 }
const reviewEntry: CleanupItem = { ...cleanupEntry, id: 'review:one', name: 'review', status: 'needs-review', reasons: ['Session 使用中'] }
const protectedEntry: CleanupItem = { ...cleanupEntry, id: 'protected:one', kind: 'lineArtifacts', status: 'protected', reasons: ['未結案'] }
const cleanupPlan: CleanupPlan = { schema: 'ai-agents.work-overview-cleanup.v1', mode: 'list', generatedAtUtc: '2026-11-08T00:00:00Z', planId: 'plan-123', sessionsKnown: true, items: [cleanupEntry, reviewEntry, protectedEntry], totals: { cleanableCount: 1, cleanableBytes: 1536, needsReviewCount: 1, protectedCount: 1 }, warnings: [], result: null }
type CleanupCall = { argv: readonly string[]; stdin?: string; timeoutMs?: number }
type CleanupFixture = { calls: CleanupCall[]; sessions: object[]; sessionFailure: boolean; plan: CleanupPlan; exitCode: number; stderr: string; defer: boolean; release?: () => void; writes: number; missingScript: boolean; partialFailure: boolean; rawOutput: string | null; storedCleanup: object | null }

function setupCleanup(on: On, roots = ['C:\\one', 'D:\\two']): CleanupFixture {
  const state: CleanupFixture = { calls: [], sessions: [{ cwd: 'C:\\one\\work', name: 'first', title: 'First' }, { cwd: 'D:\\two\\old', name: 'old', isArchived: true }], sessionFailure: false, plan: cleanupPlan, exitCode: 0, stderr: '', defer: false, writes: 0, missingScript: false, partialFailure: false, rawOutput: null, storedCleanup: null }
  mock.store(on)
  mock.env(on, { USERPROFILE: 'C:\\Users\\X' })
  let seeded = true
  on('state.get', ($, e, next) => {
    if (e.key === 'cleanup' && state.storedCleanup) return { value: { value: { shape: 'cleanup-1', value: state.storedCleanup }, version: 1 } }
    return e.key === 'snapshot' && seeded ? snapshotAnswer({ ...snapshot, scannedRoots: roots }) : next(e)
  })
  on('state.set', ($, e, next) => { if (e.key === 'snapshot') seeded = false; return next(e) })
  on('fs.stat', () => {
    if (state.missingScript) throw new Error('missing')
    return { value: { kind: 'file', size: 0, mtimeMs: 0, isLink: false } }
  })
  on('fs.write', () => { state.writes++; return { value: undefined } })
  on('mcp.call', () => {
    if (state.sessionFailure) throw new Error('session list failed')
    return { value: { structuredContent: { sessions: state.sessions } } }
  })
  on('session.cwd', () => ({ value: '' }))
  on('process.run', async (_, e) => {
    state.calls.push({ argv: e.argv, stdin: e.init?.stdin, timeoutMs: e.init?.timeoutMs })
    if (!e.argv.includes('-SessionsFromStdin')) return { value: result(JSON.stringify({ scannedRoots: roots, lines: [], workRoots: [], quota: [], warnings: [] })) }
    if (state.defer) await new Promise<void>(resolve => { state.release = resolve })
    if (state.exitCode) return { value: result('', state.exitCode, state.stderr) }
    if (state.rawOutput !== null) return { value: result(state.rawOutput) }
    const deleting = e.argv.includes('-ConfirmPlan')
    const failed = state.partialFailure ? [{ id: 'protected:two', reason: '檔案被占用' }] : []
    const plan = deleting ? { ...state.plan, mode: 'delete', result: { deleted: [{ id: cleanupEntry.id, bytes: 1536 }], failed, freedBytes: 1536 } } : state.plan
    return { value: result(JSON.stringify(plan), deleting && state.partialFailure ? 2 : 0) }
  })
  return state
}

const cleanupCalls = (state: CleanupFixture) => state.calls.filter(call => call.argv.includes('-SessionsFromStdin'))

test('P7 phase 6 lists, confirms, refreshes, and never writes through fs', options, async ($, on) => {
  const state = setupCleanup(on)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Button', key: 'cleanup-open' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Button', key: 'cleanup-confirm' })).toBe(undefined)
  await ui.press({ key: 'cleanup-open' })
  expect(cleanupCalls(state).length).toBe(1)
  const listed = cleanupCalls(state)[0]
  expect(listed.argv).toEqual(['pwsh', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', 'C:\\x\\Invoke-WorkOverviewCleanup.ps1', '-Root', 'C:\\one;D:\\two', '-SessionsFromStdin', '-AsJson'])
  expect(listed.timeoutMs).toBe(300000)
  expect(JSON.parse(listed.stdin || '')).toEqual({ sessions: [{ cwd: 'C:\\one\\work', name: 'first', title: 'First' }] })
  expect(state.calls.every(call => !call.argv.includes('-ConfirmPlan'))).toBe(true)
  const texts = (await ui.findAll({ type: 'Text' })).map(item => item.text)
  expect(texts).toContain('可清理 1 項（2 KB）· 待確認 1 項 · 保留 1 項')
  expect(texts).toContain('派工 dev-one（line-one）')
  expect(texts.some(text => /未 commit 改動 3 個、未追蹤 2 個/.test(text))).toBe(true)
  expect(texts.some(text => /Session 使用中/.test(text))).toBe(true)
  expect(texts.some(text => /保留 1 項：未結案 1 項/.test(text))).toBe(true)
  expect((await ui.find({ type: 'Button', key: 'cleanup-confirm' }))?.props.label).toBe('確認刪除 1 項（2 KB）')
  state.sessions = [{ cwd: 'D:\\two\\new', name: 'second', title: 'Second' }]
  await ui.press({ key: 'cleanup-confirm' })
  expect(cleanupCalls(state).length).toBe(2)
  const confirmed = cleanupCalls(state)[1]
  expect(confirmed.argv.slice(-2)).toEqual(['-ConfirmPlan', 'plan-123'])
  expect(confirmed.timeoutMs).toBe(600000)
  expect(JSON.parse(confirmed.stdin || '')).toEqual({ sessions: [{ cwd: 'D:\\two\\new', name: 'second', title: 'Second' }] })
  expect(state.calls.some(call => call.argv.includes('Get-LineStatus.ps1') || call.argv.includes('C:\\x\\Get-LineStatus.ps1'))).toBe(true)
  expect(await ui.find({ type: 'Text', text: '已刪除 1 項，釋出 2 KB；失敗 0 項' })).not.toBe(undefined)
  expect(state.writes).toBe(0)
  await ui.press({ key: 'cleanup-close' })
  expect(await ui.find({ type: 'Button', key: 'cleanup-open' })).not.toBe(undefined)
  await ui.unmount()
})

test('P7 phase 6 cancel and empty plan never confirm', options, async ($, on) => {
  const state = setupCleanup(on)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  await ui.press({ key: 'cleanup-open' })
  await ui.press({ key: 'cleanup-cancel' })
  expect(state.calls.every(call => !call.argv.includes('-ConfirmPlan'))).toBe(true)
  state.plan = { ...cleanupPlan, items: [], totals: { cleanableCount: 0, cleanableBytes: 0, needsReviewCount: 0, protectedCount: 0 } }
  await ui.press({ key: 'cleanup-open' })
  expect(await ui.find({ type: 'Text', text: '沒有可清理項目' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Button', key: 'cleanup-confirm' })).toBe(undefined)
  await ui.press({ key: 'cleanup-cancel' })
  expect(cleanupCalls(state).length).toBe(2)
  await ui.unmount()
})

test('P7 phase 6 handles changed plans, retry, and Session failure', options, async ($, on) => {
  const state = setupCleanup(on)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  state.sessionFailure = true
  await ui.press({ key: 'cleanup-open' })
  expect(JSON.parse(cleanupCalls(state)[0].stdin || '')).toEqual({ sessions: null })
  state.exitCode = 3
  await ui.press({ key: 'cleanup-confirm' })
  expect(await ui.find({ type: 'Text', text: '清單已變更，請重新列出' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Button', key: 'cleanup-retry' })).not.toBe(undefined)
  state.exitCode = 0
  await ui.press({ key: 'cleanup-retry' })
  expect(cleanupCalls(state)[2].argv.includes('-ConfirmPlan')).toBe(false)
  expect(await ui.find({ type: 'Button', key: 'cleanup-confirm' })).not.toBe(undefined)
  await ui.press({ key: 'cleanup-cancel' })
  await ui.unmount()
})

test('P7 phase 6 rejects missing roots and missing script before running cleanup', options, async ($, on) => {
  const state = setupCleanup(on, [])
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  await ui.press({ key: 'cleanup-open' })
  expect(state.calls.length).toBe(0)
  expect(await ui.find({ type: 'Text', text: '尚未取得掃描範圍，請先重新整理' })).not.toBe(undefined)
  await ui.press({ key: 'cleanup-close' })
  await ui.unmount()
})

test('P7 phase 6 missing script reports the cleanup script name', options, async ($, on) => {
  const state = setupCleanup(on)
  state.missingScript = true
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  await ui.press({ key: 'cleanup-open' })
  expect(state.calls.length).toBe(0)
  expect(await ui.find({ type: 'Text', text: '找不到 Invoke-WorkOverviewCleanup.ps1' })).not.toBe(undefined)
  await ui.press({ key: 'cleanup-close' })
  await ui.unmount()
})

test('P7 phase 6 prevents duplicate presses while listing', options, async ($, on) => {
  const state = setupCleanup(on)
  state.defer = true
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  const first = ui.press({ key: 'cleanup-open' })
  const second = ui.press({ key: 'cleanup-open' })
  for (let i = 0; i < 200 && !state.release; i++) await new Promise(resolve => setTimeout(resolve, 0))
  expect(cleanupCalls(state).length).toBe(1)
  expect(await ui.find({ type: 'Text', text: '正在列出清理清單…' })).not.toBe(undefined)
  state.release?.()
  await Promise.all([first, second])
  await ui.press({ key: 'cleanup-cancel' })
  await ui.unmount()
})

test('P7 phase 6 partial delete failure still reports the result and refreshes', options, async ($, on) => {
  const state = setupCleanup(on)
  state.partialFailure = true
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  await ui.press({ key: 'cleanup-open' })
  await ui.press({ key: 'cleanup-confirm' })
  expect(await ui.find({ type: 'Text', text: '已刪除 1 項，釋出 2 KB；失敗 1 項' })).not.toBe(undefined)
  expect(state.calls.some(call => call.argv.includes('-AsJson') && !call.argv.includes('-SessionsFromStdin'))).toBe(true)
  await ui.press({ key: 'cleanup-close' })
  await ui.unmount()
})

test('P7 phase 6 shows the first stderr line and rejects unreadable output', options, async ($, on) => {
  const state = setupCleanup(on)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  state.exitCode = 4
  state.stderr = '另一個清理程序執行中\r\n第二行'
  await ui.press({ key: 'cleanup-open' })
  expect(await ui.find({ type: 'Text', text: '另一個清理程序執行中' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Button', key: 'cleanup-retry' })).toBe(undefined)
  await ui.press({ key: 'cleanup-close' })
  state.exitCode = 0
  state.rawOutput = 'not json'
  await ui.press({ key: 'cleanup-open' })
  expect(await ui.find({ type: 'Button', key: 'cleanup-confirm' })).toBe(undefined)
  expect(await ui.find({ type: 'Button', key: 'cleanup-close' })).not.toBe(undefined)
  expect(state.calls.every(call => !call.argv.includes('-ConfirmPlan'))).toBe(true)
  await ui.press({ key: 'cleanup-close' })
  await ui.unmount()
})

test('P7 phase 6 stale in-progress state from a reload renders as idle', options, async ($, on) => {
  const state = setupCleanup(on)
  state.storedCleanup = { phase: 'listing', plan: null, message: null }
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Button', key: 'cleanup-open' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Text', text: '正在列出清理清單…' })).toBe(undefined)
  expect(state.calls.length).toBe(0)
  await ui.unmount()
})

const openLine: CleanupItem = { ...protectedEntry, id: 'line:alpha', name: 'alpha', lineSlug: 'alpha', category: 'all', reasons: ['缺少結案檢查點'] }
const busyLine: CleanupItem = { ...openLine, id: 'line:busy', name: 'busy', lineSlug: 'busy', reasons: ['同名 Session 使用中'] }
const closedHistory: CleanupItem = { ...openLine, id: 'line:alpha:history', name: 'alpha · history', category: 'history', status: 'cleanable', reasons: [], sizeBytes: 2048, fileCount: 3 }
const linesPlan: CleanupPlan = { ...cleanupPlan, items: [cleanupEntry, openLine, busyLine], totals: { cleanableCount: 1, cleanableBytes: 1536, needsReviewCount: 0, protectedCount: 2 } }
const designatedPlan: CleanupPlan = { ...cleanupPlan, items: [cleanupEntry, closedHistory, busyLine], totals: { cleanableCount: 2, cleanableBytes: 3584, needsReviewCount: 0, protectedCount: 1 } }
const closedLineValues = (argv: readonly string[]) => argv.filter((value, index) => argv[index - 1] === '-ClosedLine' || value === '-ClosedLine')

test('P7 review round 2 designated closed lines go to both list and confirm calls', options, async ($, on) => {
  const state = setupCleanup(on)
  state.plan = linesPlan
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  await ui.press({ key: 'cleanup-open' })
  expect(cleanupCalls(state)[0].argv.includes('-ClosedLine')).toBe(false)
  expect(await ui.find({ type: 'Button', key: 'cleanup-mark-alpha' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Button', key: 'cleanup-mark-busy' })).toBe(undefined)
  expect(await ui.find({ type: 'Button', key: 'cleanup-relist' })).toBe(undefined)
  await ui.press({ key: 'cleanup-mark-alpha' })
  expect(cleanupCalls(state).length).toBe(1)
  expect(await ui.find({ type: 'Button', key: 'cleanup-unmark-alpha' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Button', key: 'cleanup-mark-alpha' })).toBe(undefined)
  expect(await ui.find({ type: 'Button', key: 'cleanup-relist' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Button', key: 'cleanup-confirm' })).toBe(undefined)
  state.plan = designatedPlan
  await ui.press({ key: 'cleanup-relist' })
  expect(cleanupCalls(state).length).toBe(2)
  const relisted = cleanupCalls(state)[1]
  expect(closedLineValues(relisted.argv)).toEqual(['-ClosedLine', 'alpha'])
  expect(relisted.argv.slice(-3)).toEqual(['-AsJson', '-ClosedLine', 'alpha'])
  expect(relisted.argv.includes('-ConfirmPlan')).toBe(false)
  expect(await ui.find({ type: 'Button', key: 'cleanup-unmark-alpha' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Button', key: 'cleanup-relist' })).toBe(undefined)
  expect((await ui.find({ type: 'Button', key: 'cleanup-confirm' }))?.props.label).toBe('確認刪除 2 項（4 KB）')
  await ui.press({ key: 'cleanup-confirm' })
  expect(cleanupCalls(state).length).toBe(3)
  const confirmed = cleanupCalls(state)[2]
  expect(confirmed.argv.slice(-4)).toEqual(['-ClosedLine', 'alpha', '-ConfirmPlan', 'plan-123'])
  expect(state.writes).toBe(0)
  await ui.press({ key: 'cleanup-close' })
  await ui.press({ key: 'cleanup-open' })
  expect(cleanupCalls(state).length).toBe(4)
  expect(cleanupCalls(state)[3].argv.includes('-ClosedLine')).toBe(false)
  await ui.press({ key: 'cleanup-cancel' })
  await ui.unmount()
})

test('P7 review round 2 designation can be cancelled before listing again', options, async ($, on) => {
  const state = setupCleanup(on)
  state.plan = linesPlan
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  await ui.press({ key: 'cleanup-open' })
  await ui.press({ key: 'cleanup-mark-alpha' })
  expect(await ui.find({ type: 'Button', key: 'cleanup-confirm' })).toBe(undefined)
  await ui.press({ key: 'cleanup-unmark-alpha' })
  expect(await ui.find({ type: 'Button', key: 'cleanup-mark-alpha' })).not.toBe(undefined)
  expect(await ui.find({ type: 'Button', key: 'cleanup-relist' })).toBe(undefined)
  expect(await ui.find({ type: 'Button', key: 'cleanup-confirm' })).not.toBe(undefined)
  await ui.press({ key: 'cleanup-confirm' })
  expect(cleanupCalls(state).length).toBe(2)
  expect(cleanupCalls(state)[1].argv.includes('-ClosedLine')).toBe(false)
  expect(cleanupCalls(state)[1].argv.slice(-2)).toEqual(['-ConfirmPlan', 'plan-123'])
  await ui.press({ key: 'cleanup-close' })
  await ui.unmount()
})