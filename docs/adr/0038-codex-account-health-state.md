---
status: accepted
date: 2026-11-14
---

# ADR-0038：以本機健康狀態檔略過不支援檔位 model 的派工帳號

## Context

派工帳號由 Dispatch 依 `machine.json` 的 `codex_accounts` 登記順序動態選擇，只有在服務端拒絕且尚無 item 進度時才改試下一個帳號。停用訂閱的帳號對檔位 model 一律回 `model not supported`，每次派工仍會先選到它、等服務端拒絕後才換帳號，多花一次啟動與等待。服務端拒絕訊息附帶的恢復時間不可信，曾出現訊息寫數天後恢復、實際數小時後即可使用的情況。

## Decision

帳號遭服務端回報 `model not supported` 時，Inspect 把帳號名稱、Codex home、檔位與 model 寫入 `machine.json` 同目錄的 `codex-account-health.json`（schema `ai-agents.codex-account-health.v1`），寫入點只有 Inspect 一處。Dispatch 選帳號時，24 小時內以原因碼 `ModelNotSupportedRecorded` 略過符合的組合，並在派遣結果的 `account_selection.skipped` 寫出略過原因。檔位設定的 model 改變後，舊記錄不再生效；同一組合派遣成功時清除記錄。所有候選都被記錄時，取記錄最舊者實際嘗試一次，避免記錄過期造成全部帳號永久不可用。

排除的方案如下。每次派工前先探測帳號可用的 model，會讓每筆派工多一次服務端往返。永久封鎖帳號，會讓重新訂閱後的帳號無法自動恢復。採信拒絕訊息附帶的恢復時間，與實際恢復時間不符。

## Consequences

停用訂閱的帳號在 24 小時內不再拖慢派工，重新訂閱後最遲 24 小時、或該組合下一次派遣成功時自動恢復。健康狀態檔屬本機狀態，不進版控，換電腦時從空檔開始。使用者要立即恢復某帳號時，刪除該檔中對應的項目。
