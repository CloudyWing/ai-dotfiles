---
status: accepted
date: 2026-11-02
---

# ADR-0021：已推送分支的改寫與 force push 邊界

## Context

整理 commit 歷史後，已推送的分支需要 force push，這是不可逆操作，而 `main` 在 `trunk` 與 `release-flow` 兩種模式下的發佈意義不同。

## Decision

依分支分級，未合併的 `release/*`、`hotfix/*` 可改寫，`trunk` 的 `main` 需使用者當輪授權，`release-flow` 的 `main`、已合併的 `release/*`、`hotfix/*` 與缺少註記時的 `main` 不改寫，線分支、整理分支與備份分支不推送。一律使用 `--force-with-lease=<ref>:<遠端預期 SHA>`，授權以固定格式請求且不跨輪、不跨分支，lease 失敗時停止，不改用 `--force`。整理只在拋棄式整理分支執行，並以完整 tree 零差異驗證（整合上游變更時改比對 patch-id）通過後才更新來源分支。

## Consequences

每次 force push 增加一次使用者授權停頓，但改寫範圍、遠端預期 SHA 與備份分支都會在請求中列出。已發佈內容的修正只能以新 commit 處理，版本由標籤保存。
