---
name: codex-dispatch
description: 'Codex 派工機制：依派工類型建立派遣檔、以 Invoke-CodexRun.ps1 啟動 codex exec、等待並回收結果。當需要發動 codex、撰寫派遣檔或執行派遣回收判定時使用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Codex 派工機制

本 Skill 負責 Codex 派工的執行機制，只處理已由執行者登錄表選定的 Codex 執行者（測試、審查、顧問、事實校閱、影像產生）。是否派工由 `rules/claude/` 的路由與派工規則判定，執行者判定見 `executor-selection` skill；本 Skill 只處理指令、落點、等待與回收。

## 階段路由

依目前所在階段讀取對應的 reference，不需要預先讀取其他階段的檔案。

| 階段 | 讀取 | 涵蓋 |
| --- | --- | --- |
| 派遣檔、發動、等待、結果與結束碼、帳號、成本列、重跑 | `references/run.md` | 審查、事實校閱、影像產生、測試取證與顧問 |
| 回收判定、執行端共用作業、派工後的殘餘工作、值班通知、sandbox 外環境動作 | `references/collect.md` | 回收三態、覆寫前備份、共同基準與主張反證比對、Finding 編號與前輪對照、覆核取證助手 |
| 派工前的 AI-PROFILE 前置檢查、檔位用途、額度快照 | `references/start.md` | 鍵的補齊與停止條件、四個語意檔位、`Get-CodexQuota.ps1` 輸出 |

執行端角色依角色規則檔引用的節名讀取該節。
