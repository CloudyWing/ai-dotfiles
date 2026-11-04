import { expect, mock, test } from 'claude-code/testing'
import type { BoardSnapshot } from '../types'

const PANE = {
  plugin: 'line-status-board', component: 'Pane', requestId: 'line-status-board',
  props: { title: '線狀態', isFocused: false, bodyColumns: 40, placement: 'dock', scroll: { offset: 0, bodyRows: 20 }, view: {} }
} as const
const row = { name: 'item', note: 'note', dot: 'success', detail: null, bars: [], tone: 'normal' } as const
const block = { rows: [{ ...row }], hiddenCount: 0, errorMessage: null }
const snapshot: BoardSnapshot = {
  sessions: block, lines: block, workRoots: block,
  quota: { ...block, rows: [{ ...row, bars: [{ label: '5 小時', percent: 50, tone: 'success', text: '50%' }] }] }
}

test('R1 desktop components and refresh', async ($, on) => {
  mock.store(on)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? { value: { value: { shape: 'snapshot-2', value: snapshot }, version: 1 } } : next(e))
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
  on('state.get', ($, e, next) => e.key === 'snapshot' ? { value: { value: { shape: 'snapshot-2', value: snapshot }, version: 1 } } : next(e))
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
  on('state.get', ($, e, next) => e.key === 'snapshot' ? { value: { value: { shape: 'snapshot-2', value: snapshot }, version: 1 } } : next(e))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Box', key: 'row-quota-0' })).toBe(undefined)
  for (const id of ['sessions', 'lines', 'workRoots']) expect(await ui.find({ type: 'Box', key: `row-${id}-0` })).not.toBe(undefined)
  await ui.unmount()
})
for (const [label, value] of [['missing', undefined], ['string', 'x'], ['object', {}], ['unknown', ['bogus']]] as const) {
  test(`R4 invalid store ${label}`, async ($, on) => {
    mock.store(on, value === undefined ? {} : { 'collapsed-blocks': value })
    on('state.get', ($, e, next) => e.key === 'snapshot' ? { value: { value: { shape: 'snapshot-2', value: snapshot }, version: 1 } } : next(e))
    const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
    for (const id of ['sessions', 'lines', 'workRoots', 'quota']) expect(await ui.find({ type: 'Box', key: `row-${id}-0` })).not.toBe(undefined)
    await ui.unmount()
  })
}
test('R5 non desktop uses text bars', async ($, on) => {
  mock.store(on)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? { value: { value: { shape: 'snapshot-2', value: snapshot }, version: 1 } } : next(e))
  for (const surface of ['terminal', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Svg' })).toBe(undefined)
    expect(await ui.find({ type: 'Text', text: /[█░]/ })).not.toBe(undefined)
    await ui.unmount()
  }
})
test('R6 no old header or extra buttons', async ($, on) => {
  mock.store(on)
  on('state.get', ($, e, next) => e.key === 'snapshot' ? { value: { value: { shape: 'snapshot-2', value: snapshot }, version: 1 } } : next(e))
  for (const surface of ['desktop', 'terminal', 'mobile', 'vscode'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /Session（|● 執行中/ })).toBe(undefined)
    expect((await ui.findAll({ type: 'Button' })).length).toBe(5)
    await ui.unmount()
  }
})
