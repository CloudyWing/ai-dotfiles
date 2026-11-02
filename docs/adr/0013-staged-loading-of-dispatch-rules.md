---
status: accepted
date: 2026-11-02
---

# ADR-0013：派工規範依工作分支與階段載入

## Context

`instructions.md` 常駐載入，`codex-dispatch/SKILL.md` 一次載入約 161KB，Claude 每次呼叫都重送整段 context，成本隨載入量乘上呼叫次數增加。

## Decision

工作分支的操作細節下放為 skill，Workflow 流程與驗證歸 `workflow-orchestration`，產物分類與落點歸 `session-artifacts`，advisor 程序歸 `codex-dispatch`。`codex-dispatch` 拆為入口與 `start.md`、`execution.md`、`collect.md`、`recovery.md` 四份 reference，入口以階段路由表指定各階段只讀對應檔案，規則層保留角色、觸發、授權與升級門檻。搬移的原文逐位元組保留並以快照 hash 驗證，排除 Claude 專用精簡入口與優化套件的拆分工具。

## Consequences

首次派遣載入量由約 161KB 降為入口加 `start.md` 約 100KB，`instructions.md` 當時由 76149 位元組降為 70574 位元組。其他線修改原章節時改在對應 reference 內修改，新增章節須同步更新入口的「章節位置」表；執行者未依階段路由載入相依 reference 時會漏讀規則。
