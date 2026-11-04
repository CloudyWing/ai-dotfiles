export type BoardRow = { text: string; tone: 'normal' | 'dim' | 'error' }
export type BoardBlock = { rows: BoardRow[]; hiddenCount: number; errorMessage: string | null; warning?: string }
export type BoardSnapshot = {
  sessions: BoardBlock
  lines: BoardBlock
  workRoots: BoardBlock
  quota: BoardBlock
}

declare module 'claude-code' {
  interface PluginState {
    'line-status-board': {
      snapshot: Shaped<BoardSnapshot | null>
      refreshedAt: string | null
      isRefreshing: boolean
    }
  }
}
