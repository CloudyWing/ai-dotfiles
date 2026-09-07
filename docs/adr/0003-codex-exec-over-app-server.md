---
status: accepted
date: 2026-09-07
---

# ADR-0003：派工執行介面採用 codex exec

## Context

派工流程原以 `codex app-server` 作為唯一執行介面，需自行維護 JSON-RPC over JSONL 的 request id、thread 與 turn 關聯、通知重播與取消收尾。該路徑累積五處失效規範且全部集中在 protocol 層，而 app-server 提供的核准互動、`turn/steer` 與即時控制在現行派遣中皆未使用。

## Decision

一般派工與退回續行改用 `codex exec` 與 `codex exec resume`，僅在派遣確實需要執行核准或即時控制時才使用 `app-server`。`codex exec` 支援 `--profile`，因此檔位回歸 `-p <檔位名稱>`，不再以 `-c` 逐鍵展開設定檔。

## Consequences

完成判定改以 `turn.completed` 事件與 process exit code 為準，結案報告結構改由 `--output-schema` 約束，續行以 `thread.started` 事件回報的 `thread_id` 作為 `exec resume` 的 session 識別。app-server 的 protocol 狀態機規範自 `codex-dispatch` skill 移除，未來若新增需要核准的派遣類型，須另建 ADR 評估是否恢復該路徑。
