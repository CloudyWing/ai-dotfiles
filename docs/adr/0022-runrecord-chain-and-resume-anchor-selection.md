---
status: accepted
date: 2026-11-02
---

# ADR-0022：RunRecord 執行鏈保留失敗嘗試，續行錨點略過所有 launch-failed 紀錄

## Context

準備或啟動前就失敗的 `launch-failed` RunRecord 若被當成最新紀錄，會讓同一 dispatchSlug 無法再冷啟動，也會遮蔽較早的有效啟動紀錄而使續行被拒。人工搬移失敗紀錄會破壞稽核證據。

## Decision

所有失敗嘗試留在執行鏈中不搬移不刪除，以 `attempt_parent_run_id` 記錄前一次嘗試，並以 `previous_run_id` 與 `resume_anchor_run_id` 另記可續行的 thread 錨點。選取器依啟動觀測分類 `launch-failed` 紀錄。`process_started` 明確為 `false` 並落在 pre-start 階段者分類為 `unstarted-sandbox`，`process_started` 為 `true` 者分類為實際啟動，啟動觀測缺漏或矛盾者拒絕續行。分類決定能否再冷啟動，續行錨點另依失敗狀態判定。所有 `launch-failed` 紀錄都不作續行錨點，選取器略過並沿鏈回到上一筆有效錨點。同 dispatchSlug 只在最新紀錄為 `unstarted-sandbox` 且 PID 檢查沒有活躍程序時允許再冷啟動，因此最新紀錄為已啟動的 `launch-failed` 時不得再冷啟動。排除時間推測、人工搬檔與只看最新紀錄。

## Consequences

沿鏈找不到有效錨點時以 `NoValidResumeAnchor` 停止，略過的嘗試寫入 `resume_diagnostics.skipped_attempts` 供稽核。新增啟動階段或失敗型態時，須先更新 pre-start 階段的分類，未分類者預設視為無法證明未啟動。
