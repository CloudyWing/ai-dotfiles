---
status: accepted
date: 2026-11-14
---

# ADR-0041：Codex 檔位改為 review、scan、content、advisor，審查只用單一檔位

## Context

ADR-0032 的檔位白名單為 `implement`、`review`、`deep-review`、`scan`、`advisor` 與 `intensive`，審查依 `Deep` 旗標分為 `review` 與 `deep-review`。分工改版後 Codex 不再承接實作，`implement` 與 `intensive` 沒有用途；`scan` 同時承接測試、事實校閱與影像產生，三者無法分別指定模型。

以同一個跨檔審查案例比較四組模型，品質以四組已證實 finding 的聯集為基準（17 條，含 4 條 Major）。terra high 只審 1 個單位就停止；terra max 命中全部 Major，分數 12/17，token 約 3,031 萬；sol medium 分數 4/17，token 約 685 萬；sol high 分數 5/17。四組都未達 80% 的品質門檻。既有 52 筆審查派遣中，依 `Deep` 規則會落到 `review` 檔位的只有 2 筆。完整數據在 `codex-model-compare` 線的比較報告。

## Decision

本決策取代 ADR-0032 的檔位集合。檔位白名單改為 `review`、`scan`、`content` 與 `advisor`，各讀取 `<CodexHome>\<檔位>.config.toml`，缺檔時於啟動前拒絕；以已移除的檔位續行同樣拒絕。ADR-0032 的其餘規則維持有效：主 Agent 在 Request 必填 `profile`；`default` 與缺少 `profile` 於啟動前拒絕；腳本不依 `task_type` 自動選檔。用途與模型如下。

| 檔位 | 用途 | model | reasoning effort |
| --- | --- | --- | --- |
| `review` | 審查，不再依 `Deep` 旗標分層 | `gpt-6.1-sol` | medium |
| `scan` | 測試（煙霧驗證取證） | `gpt-6.1-terra` | max |
| `content` | 事實校閱與影像產生 | `gpt-6.1-sol` | medium |
| `advisor` | 顧問，用途與授權沿用 ADR-0003 | `gpt-6.1-sol` | high |

選派入口移除 `Deep` 旗標，登錄表新增 `codex-content` 執行者。審查檔位依使用者裁決選用消耗最少的 sol medium。排除的方案如下。審查改用 terra max，品質最高但 token 約為 4.4 倍，5 小時視窗多耗約 32 個百分點。保留兩層審查，`Deep` 判定幾乎總是落到 `deep-review`，分層沒有實際作用。

## Consequences

審查成本以 sol medium 為準，召回率低於 terra max，漏掉的 finding 依共同收斂契約由後續輪次與需求意圖驗收補償。比較結論只來自單一案例且每組只跑一次，無法區分模型差異與單次波動，後續有新案例時應重新比較。`implement`、`intensive`、`default` 三個檔位設定檔仍留在本機，不再被讀取，預定在選派機制改版時一併退役。
