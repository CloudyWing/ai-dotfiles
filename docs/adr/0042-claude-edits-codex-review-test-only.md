---
status: accepted
date: 2026-11-17
---

# ADR-0042：修改原始碼由 Claude 承接，Codex 只承接測試取證、審查、顧問、事實校閱與影像產生

## Context

ADR-0015 把需要探索範圍或測試循環的實作交給 Codex。派出的實作常以執行失敗或提早停止收場，Claude 端要回收、判讀、重派或接手，成本因此上升。派工成本分析（961 筆派遣紀錄）顯示一輪完成者只有 19.6%。

## Decision

修改專案原始碼（含測試碼）與盤點取證由 Claude 端承接，Codex 只承接測試取證、審查、顧問、事實校閱與影像產生。排除的方案是維持 ADR-0015 的分流，因為派工失敗與提早停止會持續推高 Claude 端的成本。

## Consequences

實作類角色只在 Claude 端執行，Codex 端只留審查類角色檔。各執行者的受理範圍以 `scripts/dispatch/executor-registry.json` 為準，見 ADR-0043。日後要讓 Codex 重新修改原始碼時，比照 Claude subagent 直接在線工作樹執行並以 `git diff` 驗收，不重建併回機制。
