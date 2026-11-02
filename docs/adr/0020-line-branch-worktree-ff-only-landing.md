---
status: accepted
date: 2026-11-02
---

# ADR-0020：線分支使用獨立 worktree，rebase 後以 ff-only 落地

## Context

Phase 數大於等於 2 的 Workflow 線會跨 Session，且同一專案常並行多條線，直接在整合分支 commit 會讓各線的 commit 與未 commit 改動混在同一工作樹，也無法單獨整理某一條線的歷史。

## Decision

Phase 數大於等於 2 的線建立 `feature/<lineSlug>` 與位於 repo 上一層 `<repo>.wt\<lineSlug>` 的獨立 worktree，本線 work-root 切到該 worktree。Accept 後先整理線分支，在整理分支 rebase 整合分支並通過第一層驗證，再於主 checkout 以 `git merge --ff-only` 落地。Phase 數為 1 的線、資源派遣與單筆修正直接在整合分支 commit，排除 PR 協作與線分支推送。

## Consequences

落地後須將同線 handoff 與 report 目錄歸還主 checkout，覆蓋前備份並逐檔比對 SHA-256，再移除 worktree 與線分支。整合分支前進使 ff-only 被拒時，重做 rebase 一次，仍被拒則停止回報，整合分支歷史維持線性。
