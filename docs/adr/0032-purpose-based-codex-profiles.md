---
status: accepted
date: 2026-11-03
---

# ADR-0032：Codex 檔位依用途拆分並移除預設檔位

## Context

ADR-0016 沿用 ADR-0009 的預設、`intensive` 與 `advisor` 三檔位，預設檔位同時承接實作、一般審查、盤點與診斷，無法依用途分別指定模型與 reasoning effort。大範圍審查因此借用原本只供使用者覆寫實作的 `intensive`，造成同一檔位兼具兩種用途。

## Decision

本決策取代 ADR-0009 的檔位集合與 ADR-0016，檔位白名單改為 `implement`、`review`、`deep-review`、`scan`、`advisor` 與 `intensive`，各讀取 `<CodexHome>\<檔位>.config.toml`，缺檔時於啟動前拒絕，不回退其他檔位。主 Agent 依用途在 Request 必填 `profile`，實作用 `implement`，一般審查用 `review`，規則檔機制條款或 3 個檔案以上的審查用 `deep-review`，讀取為主的工作用 `scan`；`intensive` 只在使用者於當下 Session 指定時覆寫實作，`advisor` 的用途與授權沿用 ADR-0003。`default` 與缺少 `profile` 一律在啟動前拒絕，腳本不依 `task_type` 自動選檔，排除的方案為保留 `default` 作為別名與以單一設定檔的區段承載多個檔位。

## Consequences

`Setup-AIGlobalConfig.ps1` 補建缺少的五個必備設定檔且不覆寫既有檔，`New-CodexDispatchAccount.ps1` 為每個派工帳號連結這些檔案；未完成這兩步前，派遣都會在啟動前拒絕。舊 RunRecord 不改寫，其 `default` 依派工角色換算為 `implement`、`review` 或 `scan`，殘留的 `default.config.toml` 不再被讀取。
