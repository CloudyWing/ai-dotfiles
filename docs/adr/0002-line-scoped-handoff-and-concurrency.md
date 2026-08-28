---
status: accepted
date: 2026-08-28
---

# ADR-0002：線層交接與並行隔離契約

## Context

交接檔、八個固定名稱報告與 `exceptions.md` 都是每個 work-root 一份的單例路徑，Codex PID 並行檢查也只比對 work-root。使用者的實際用法是一個需求開一個 Clarify 對話，因此同一專案下常態並行多條線，後寫的交接檔會靜默覆寫先寫的，第二條線的派工也會被第一條線的活躍 Codex 阻擋。既有的 dispatch worktree 隔離軸是派遣，不涵蓋對話這個維度。

## Decision

引入 `lineSlug` 作為與 `dispatchSlug` 並存的獨立識別，由 Clarify 從需求內容推導語意名稱、以 `handoff/<lineSlug>/line.json` 登記持有權，交接檔、固定報告、例外紀錄與覆寫備份一律改為線層子目錄。PID 並行檢查改以 `work-root` 加 `line-slug` 雙鍵比對，同線仍維持單一活躍實例。排除的替代方案為平面檔名加尾碼（線內檔案無法整組管理）、重用 `dispatchSlug`（一條線含多次派遣，生命週期不同）與設定預設 slug（會重新建立單例覆寫點）。

## Consequences

跨線可並行寫入與派工，同線的重複派遣仍被擋下，代價是每條線多一次 slug 推導與 manifest 登記，且缺少線脈絡時固定報告的寫入必須停止而非回退預設值。既有未分線的交接檔與報告不搬移，新規則只管理新建立的線層資料。
