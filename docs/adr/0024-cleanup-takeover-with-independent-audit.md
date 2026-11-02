---
status: accepted
date: 2026-11-02
---

# ADR-0024：Cleanup 以獨立稽核明示接手，不改寫原 owner

## Context

Cleanup 依 caller Session fingerprint 檢查 owner，原 Session 結束後，已終態的歷史派遣會因 `DispatchAdmissionOwnerMismatch` 或 `DispatchAdmissionOwnerUnverifiable` 無法清理，worktree 因此殘留。

## Decision

Cleanup 新增明示的 `-TakeoverOwner` 開關，只在 owner 檢查失敗時由主 Agent 使用，且僅適用於 Cleanup。接手前在來源 admission lock 內驗證全部 RunRecord 的 identity、hash 與終態，並確認 PID 與程序樹已結束，證據保存後寫入來源 `history` 下的獨立稽核檔，移除前再重驗。保留真實 `CallerSessionId` 與歷史 RunRecord 的 owner，排除改寫它們，因為該欄位承載啟動來源。

## Consequences

終態證據不足、程序身分不明或保存與稽核失敗時一律保留 worktree，移除後稽核更新失敗以 `CleanupTakeoverAuditFinalizeFailed` 回報。`cleanup-result` 記錄是否使用接手與稽核檔的路徑和 SHA-256，每次重試重新驗證。
