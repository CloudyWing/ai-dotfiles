export type BlockId = 'sessions' | 'lines' | 'workRoots' | 'quota'
export type DotTone = 'success' | 'warning' | 'error' | 'inactive'
export type BoardBar = { label: string; percent: number | null; tone: DotTone; text: string }
export type BoardRow = { name: string; note: string; dot: DotTone | null; detail: string | null; bars: BoardBar[]; tone: 'normal' | 'error' }
export type BoardBlock = { rows: BoardRow[]; hiddenCount: number; errorMessage: string | null; warning?: string }
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
      refreshedAt: string | null
      isRefreshing: boolean
    }
  }
}
