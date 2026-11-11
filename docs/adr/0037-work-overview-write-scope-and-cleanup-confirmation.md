---
status: accepted
date: 2026-11-11
---

# ADR-0037：工作總覽面板只允許清理寫入，並以 planId 綁定刪除確認

## Context

`line-status-board` 原為唯讀面板，資料來源 `scripts\Get-LineStatus.ps1` 有靜態測試保護唯讀契約。0.6.0 起面板要能清理已結案線的產物，刪除不可逆，判定錯誤會刪到未結案線、被引用的檔案或帶未 commit 改動的 worktree。

## Decision

面板唯一的寫入操作是清理，派工、commit、push 與代為登入不在面板範圍內。清理由獨立腳本 `scripts\Invoke-WorkOverviewCleanup.ps1` 承擔：預設只列出計畫，以 `-ConfirmPlan <planId>` 重新計算並在 `planId` 相符時才刪除；plugin 只傳 `planId`、不傳路徑。保留、引用與使用中判定全部在腳本內，`git worktree remove --force` 只用於所屬線已結案、沒有派工在跑、報告已以 SHA-256 確認保存回來源的 dispatch worktree。排除的方案包括：由 plugin 以 `$.fs` 直接刪檔、擴充 `Get-LineStatus.ps1`、以 `$.ui.ask` 確認，以及呼叫派遣 `Cleanup`，因為這些做法分別會讓判定散在 TypeScript、破壞唯讀契約、無法在確認前顯示清單，或需要派遣身分與 owner 指紋。

## Consequences

`Get-LineStatus.ps1` 維持唯讀，刪除判定可以在暫存目錄以腳本測試完整涵蓋，清單與實際刪除之間的變動會因 `planId` 不符而被拒絕。新增可清理的產物類型時，必須在清理腳本加入判定與測試，不得讓 plugin 直接傳入路徑或擴大 `--force` 的適用範圍。
