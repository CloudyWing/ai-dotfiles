---
status: accepted
date: 2026-11-02
---

# ADR-0015：實作依工作類型分流，Architect 改由 Claude 起草

## Context

派工原則上全部交給 Codex，但實測每次派遣仍有約 3 次呼叫的 Claude 協調成本，派工後 Claude 補做達 171 次，Design 驗收也多次拉長到 12 至 16 輪。Claude 5.5 家族的續航改善後，機械小修走完整派遣的成本高於自理。

## Decision

實作依旗標分流，範圍已列舉（E）且不需測試循環（T）的修改交 Claude Haiku subagent，其餘交 Codex 預設檔位，Workflow 以 `design.md` 的 Phase 為判定單位，混合僅在無 blocking 鏈且需求編號集合不相交時採用。目標不超過 2 檔、60 行且只需 1 個驗證命令的小型修改由主 Agent 自理，`Architect` 改由 Claude Sonnet subagent 起草 `design.md`，影響範圍盤點等跨檔掃描仍由 Codex 唯讀派遣執行。排除以額度為唯一依據的歸屬判定，因額度只能推翻能力程度差異，不能推翻唯一可行性差異。

## Consequences

主 Agent 在 Design 驗收通過時逐 Phase 輸出 `[派工判定]` 並記入檢查點，Haiku Phase 的修正超過小型門檻時改派 Codex，不反覆重派。派工後的殘餘工作依同一門檻由 Claude 收尾並記錄「派工後補做」，超過門檻則退回執行端。
