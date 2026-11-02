---
status: accepted
date: 2026-11-02
---

# ADR-0011：workflow-depth 的 light 路徑與 Reviewer 放寬邊界

## Context

規模小的示範專案走完整的 Design、Implement 與跨家族審查成本偏高，但規則檔機制條款與公開契約的審查不能因此失效。

## Decision

新增 `workflow-depth` 鍵（`full`、`light`），`light` 不派生 `Architect`、不產生 `design.md` 與交接檢查點，實作依 F1 與實作分流處理，需求意圖驗收照常執行。Reviewer 必發清單在 `light` 只放寬第 1 項（核對建置與測試原始輸出成功且不含 `library` 公開 API 改動時可不發），第 2、5 項維持必發，變更命中跨模組介面、`library` 公開 API 或 UI 線別 B、C 時升級為 `full`。排除保留 `Developer` 並以需求摘要取代 `design.md`，因其需改寫 `Developer` 的前置條件。

## Consequences

`light` 線的程式碼 diff 可能未經跨家族審查，風險由原始輸出核對失敗即恢復必發、升級判定優先於所有深度來源，以及需求摘要 `## Workflow 深度` 節的記錄承擔。調整放寬範圍時，須同步更新 `instructions.md` 的風險邊界表與 `workflow-orchestration` 的 light 路徑。
