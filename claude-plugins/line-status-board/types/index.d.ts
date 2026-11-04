export type BlockId = 'sessions' | 'lines' | 'workRoots' | 'quota'
export type ExpandId = 'stalledLines'
export type DetailSegment = { text: string; tone: 'normal' | 'attention' }
export type DotTone = 'success' | 'warning' | 'error' | 'inactive'
export type BoardBar = { percent: number | null; tone: DotTone }
export type BoardRow = { name: string; tag: string; right: string; rightShrink: boolean; dot: DotTone; detail: DetailSegment[] | null; bar: BoardBar | null; tone: 'normal' | 'error'; isCurrent: boolean }
export type BoardBlock = { rows: BoardRow[]; stalledRows: BoardRow[]; hiddenCount: number; errorMessage: string | null; warning?: string }
export type BoardSnapshot = {
  sessions: BoardBlock
  lines: BoardBlock
  workRoots: BoardBlock
  quota: BoardBlock
  currentLabel: string | null
}

declare module 'claude-code' {
  interface PluginState {
    'line-status-board': {
      snapshot: Shaped<BoardSnapshot | null>
      collapsed: Shaped<BlockId[] | null>
      expanded: Shaped<ExpandId[] | null>
      refreshedAt: string | null
      isRefreshing: boolean
    }
  }
}
