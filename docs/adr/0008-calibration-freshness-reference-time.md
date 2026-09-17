---
status: accepted
date: 2026-09-16
---

# ADR-0008：校準樣本的 before 快照以 Start 時點判定新鮮度

## Context

`Add-CalibrationObservation` 的 `$freshSnapshots` 同時要求 before 與 after 快照在 `Inspect` 當下仍 fresh，而 freshness 門檻為 30 分鐘，因此任何執行時間超過 30 分鐘的派工都永遠無法成為校準樣本。實測 `quota-calibration.jsonl` 中 `gpt-5.6-luna / max / implement / cold-start` 這個日常主力分組 5 筆全部 `calibration_eligible=false`，同分組門檻為 5 筆，`ScopePlan` 的第 75 百分位估算路徑從未生效。其中 5 筆的 `calibration_checks` 欄位全為 true 卻仍 ineligible，因為 `freshSnapshots`、`hasUsage`、`executionCompleted` 與 `hasSnapshots` 未寫入該物件，失效原因無法從樣本檔診斷。

## Decision

before 快照的新鮮度改以 Start 當下的判定結果為準，由 `Start` 將 `quota_before_freshness` 與擷取時間寫入 RunRecord，`Inspect` 讀取後不再以自身時間重新判定；after 快照維持以 `Inspect` 當下判定。`calibration_checks` 追加 `snapshots_present`、`snapshots_fresh`、`usage_present`、`execution_completed`、`task_type_present` 與 `non_negative_delta`，所有 eligibility 條件都映射為布林欄位，任何 false 必須在新增的 `ineligible_reasons` 陣列列出對應欄位名稱。`Get-CodexQuota.ps1` 的 observation 建立與 30 分鐘門檻本身不變。

## Consequences

長時間執行且正常完成的派工可累積為校準樣本，達 5 筆後 `ScopePlan` 才能在低額度時依第 75 百分位取最長前綴，而非固定落入 `bounded-single-unit` 的單段切割。失效樣本可逐項定位原因，不再出現所有 check 皆為 true 但 eligible 為 false 的紀錄。此決策接受「before 在 Start 時 fresh 但在 Inspect 時已過期」的樣本，代價是 before 與 after 的時間跨距可能大於一個 freshness 視窗，reset window 變更仍由既有的 `same_reset_window` 檢查擋下；已排除的替代方案為放寬門檻分鐘數與在 Inspect 重新判定兩者。
