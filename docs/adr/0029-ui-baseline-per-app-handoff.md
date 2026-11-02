---
status: accepted
date: 2026-11-02
---

# ADR-0029：UI 樣式基準逐 app 產出，確認狀態由協調者交接

## Context

同一專案可能有多個前端 app，各自的元件與樣式不同，合併成單一基準會讓消費者拿到其他 app 的慣例。基準的待決策值若由下游自行採用，會在已確認的設計之後引入未驗收的輸入。

## Decision

`uiux-baseline` 對每個 app 各自產出 `ui-style-baseline.<app-name>.md` 與同名樣本頁，單一 app 沿用固定檔名，並交付 `app-name`、`baseline-path`、`sample-path` 與待決策項。協調者選定目標 app 並管理 `confirmed-choices`，下游 `uiux` 只讀取指定基準，欄位缺少、檔案不可讀或 app 錯配時停止並回報缺件，不改用其他基準。內部候選版只列待確認項，正式採用只使用已統一慣例或使用者確認的值，排除由 Developer 自行決定候選。

## Consequences

多 app 專案每個 app 都需要一份基準與一次交接，確認狀態沿用需求摘要流程保存，不新增狀態檔。基準缺漏時由 `Analyst` 或 `Maintainer` 放行補件，派工失敗時下游維持阻擋。
