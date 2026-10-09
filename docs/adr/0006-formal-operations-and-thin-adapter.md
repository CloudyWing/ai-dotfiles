---
status: accepted
date: 2026-10-09
---

# ADR-0006：派遣正式 operation、薄 adapter 與模組拆分

## Context

主 Agent 原本必須自行串接 Preflight、before 額度快照、Prepare 與 Start 並逐一傳遞結果路徑，實測發生陣列參數錯位覆寫來源檔、Prepare 結果檔名傳錯，以及背景派遣因未保存 launcher 結束碼而無法執行 Inspect。派工入口單檔一度超過 19,000 行，修改與審查成本隨檔案大小上升。

## Decision

`Dispatch` 是新派遣的唯一正式入口，只接受一份 `ai-sessions.dispatch-request.v1` request JSON，內部依序完成 Preflight、before 額度快照、Prepare 與 Start，輸出 `ai-sessions.dispatch-result.v1` 並以 sidecar 保存 launcher 結束碼；正常路徑的正式 operation 為 `Dispatch`、`Inspect`、`Collect` 與 `Cleanup`，Preflight、Prepare 與 Start 為內部階段，命令列保留供診斷與續行。`Invoke-CodexDispatch.ps1` 保留為薄 adapter，負責參數與 Request 驗證、operation 路由、結果寫入與 exit code，其餘函式依責任拆入 `scripts\dispatch\` 下 16 個模組，拆分以逐批純搬移進行，每批輸出與當時基線逐位元組相同才進行簡化。排除的方案為另建獨立派工腳本、一次性重寫入口與新增只轉送參數的檔案。

## Consequences

陣列一律經 Request JSON 傳遞，背景派遣可直接 Inspect，Request 與命令列同名欄位不一致時以 `DispatchRequestMismatch` 拒絕。模組間共享 PID、RunRecord 與 baseline 等跨階段狀態，再進一步抽離須先提出可量測的修改或測試成本收益，並沿用逐位元組基線比對。
