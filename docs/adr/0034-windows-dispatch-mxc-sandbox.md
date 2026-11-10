---
status: proposed
date: 2026-11-10
---

# ADR-0034：Windows 的 Codex 派遣全面使用 MXC sandbox

## Context

Windows 的 elevated sandbox 以專用本機帳號透過 `CreateProcessWithLogonW` 登入後執行命令，網域群組原則限縮「允許本機登入」的電腦會以錯誤 1385 失敗，readonly、advisor 與 direct-readonly 派遣因此無法啟動。ADR-0017 只讓 write 派遣改用 `mxc`，帳號 `config.toml` 的設定檢查也只接受 `elevated`。官方文件把 `mxc` 列為首選，它不需要沙盒帳號、登入權限與防火牆規則，實測在網域電腦與一般電腦都能執行。

## Decision

Windows 上所有派遣類型的新 cold-start 一律以 `windows.sandbox="mxc"` 執行，不依賴帳號設定；帳號設定檢查接受 `mxc` 與 `elevated`，新建帳號與缺少設定時寫入 `mxc`。以 elevated 建立的 readonly、advisor 與 direct-readonly 錨點續行時補上 `mxc`，作為 ADR-0026 逐欄比對的例外；write 錨點與 ADR-0017 的網路及 NuGet 路徑覆寫維持原樣還原。排除 `unelevated`，因為它的網路隔離較弱且不支援禁止讀取路徑；也排除依電腦分別設定，因為會讓同一套派工在不同電腦行為不一致。

## Consequences

網域環境的電腦恢復唯讀類派遣，各電腦使用相同的 sandbox 行為。`mxc` 是否支援禁止讀取路徑，以及沙盒狀態目錄的 Junction 是否仍需要，必須實測確認後才能調整相關規則與建立帳號腳本。
