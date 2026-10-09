---
status: accepted
date: 2026-10-09
---

# ADR-0001：線層交接、並行隔離與 caller 准入

## Context

交接檔、固定名稱報告與 `exceptions.md` 原本是每個 work-root 一份的單例路徑，而使用者常態以一個需求一個對話的方式在同一專案並行多條線，後寫的交接檔會覆寫先寫的，派工也會互相阻擋。審查與實作同時進行的需求另外要求同一個 caller Session 能並行持有多筆派遣，但兩筆寫入不能改到同一組路徑。

## Decision

以 `lineSlug` 作為與 `dispatchSlug` 並存的線層識別，由 Clarify 推導並以 `handoff/<lineSlug>/line.json` 登記，交接檔、固定報告、例外紀錄與覆寫備份一律放在線層子目錄；PID 並行檢查以 `work-root`、`line-slug` 與 `write-mode` 比對，同線 `write` 與任何其他活躍模式互斥、`readonly` 上限為 2。跨程序准入以 caller Session fingerprint 為 owner，同一 caller 同時最多一個 write 與兩個 readonly admission，direct-write 目標路徑重疊時互斥、不重疊時放行，owner 無法確認時拒絕 admission 與 Cleanup，套用前檢查來源漂移。排除的方案為平面檔名加尾碼、重用 `dispatchSlug` 作為線識別與設定預設 slug，三者都會重新建立單例覆寫點或混淆線與派遣的生命週期。

## Consequences

跨線可並行寫入與派工，同一 caller 可在 worktree write 期間執行同線審查，代價是每條線多一次 slug 推導與登記，缺少線脈絡時固定報告的寫入必須停止而不回退預設值。准入 ledger 位於 source root 的 history 並在獨占鎖內讀寫，缺少 `write-mode` 的舊 PID 記錄一律視為 `write`。
