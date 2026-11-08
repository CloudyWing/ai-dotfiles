export type BlockId = 'sessions' | 'lines' | 'workRoots' | 'quota'
export type ExpandId = 'stalledLines'
export type DetailSegment = { text: string; tone: 'normal' | 'attention' }
export type DotTone = 'success' | 'warning' | 'error' | 'inactive'
export type BoardBar = { percent: number | null; tone: DotTone }
export type BoardLogin = { account: string; command: string | null }
export type BoardRow = { name: string; tag: string; right: string; rightShrink: boolean; dot: DotTone; detail: DetailSegment[] | null; bar: BoardBar | null; tone: 'normal' | 'error' | 'dim'; isCurrent: boolean; link: string | null; login: BoardLogin | null }
export type BoardBlock = { rows: BoardRow[]; stalledRows: BoardRow[]; hiddenCount: number; errorMessage: string | null; warning?: string }
export type BoardSnapshot = {
  sessions: BoardBlock
  lines: BoardBlock
  workRoots: BoardBlock
  quota: BoardBlock
  currentLabel: string | null
  scannedRoots: string[]
}
export type CleanupItem = {
  id: string
  kind: 'worktree' | 'dispatchWorktree' | 'lineArtifacts' | 'backup'
  root: string
  path: string
  name: string
  lineSlug: string | null
  category: string | null
  status: 'cleanable' | 'needs-review' | 'protected'
  reasons: string[]
  sizeBytes: number
  fileCount: number
  protectedFileCount: number
  trackedChangeCount?: number | null
  untrackedCount?: number | null
}
export type CleanupPlan = {
  schema: 'ai-agents.work-overview-cleanup.v1'
  mode: 'list' | 'delete'
  generatedAtUtc: string
  planId: string
  sessionsKnown: boolean
  items: CleanupItem[]
  totals: { cleanableCount: number; cleanableBytes: number; needsReviewCount: number; protectedCount: number }
  warnings: string[]
  result: { deleted: { id: string; bytes: number }[]; failed: { id: string; reason: string }[]; freedBytes: number } | null
}
export type CleanupView = { phase: 'idle' | 'listing' | 'listed' | 'deleting' | 'done' | 'error'; plan: CleanupPlan | null; message: string | null }

declare module 'claude-code' {
  interface PluginState {
    'line-status-board': {
      snapshot: Shaped<BoardSnapshot | null>
      collapsed: Shaped<BlockId[] | null>
      expanded: Shaped<ExpandId[] | null>
      loginShown: Shaped<string[]>
      cleanup: Shaped<CleanupView>
      cleanupClosedPending: Shaped<string[]>
      cleanupClosedApplied: Shaped<string[]>
      refreshedAt: string | null
      isRefreshing: boolean
    }
  }
}
