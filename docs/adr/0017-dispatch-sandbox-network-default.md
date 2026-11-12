---
status: superseded
date: 2026-11-02
superseded-by: 0034
---

# ADR-0017：write 派遣預設開啟 sandbox 網路，續行沿用錨點記錄

## Context

write 派遣在 `workspace-write` sandbox 內預設沒有網路，`dotnet restore` 等需下載套件的命令會失敗。Windows 的 elevated sandbox 內 TLS 取不到憑證，使用者目錄下的 NuGet 快取在 `mxc` 內不可寫，路徑過長時套件也無法還原。

## Decision

Start 在 write 且 `workspace-write` 的新 cold-start 於 `exec` 前自動加入 `-c sandbox_workspace_write.network_access=true`，Windows 另加 `windows.sandbox="mxc"` 與指向 executionRoot 下 `.local\nuget\` 的 NuGet 路徑覆寫，並記入 `parent_options`。readonly、advisor 與 direct-readonly 不加入，Request 不提供開關，`codex_parent_option` 自帶同名覆寫時於啟動前拒絕，續行沿用錨點記錄的完整陣列且舊錨點不補加。排除修改帳號 `config.toml`（需逐次控制）以及 `danger-full-access` 與 `unelevated`（需求要求維持 sandbox）。

## Consequences

write 派遣可在 sandbox 內完成 restore 與 build，開放網路造成的 prompt injection 外洩風險由使用者接受，不另加限制。Windows 需開啟 LongPaths，由 `Setup-AIGlobalConfig.ps1` 檢查，要套用新預設的舊 thread 須以新的 cold-start 重建。
