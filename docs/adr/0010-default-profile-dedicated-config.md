---
status: accepted
date: 2026-09-18
---

# ADR-0010：預設檔位改用獨立設定檔

## Context

派工的預設檔位原本以 `~/.codex/config.toml` 作為 profile 設定來源，但該檔是 Codex 應用程式自身的使用者設定，會被應用程式改寫。使用者在應用程式切換模型或 reasoning effort 後，派工的 resolved 證據隨之改變，校準樣本會被拆散到不同分組而無法累積至同分組 5 筆的門檻。

## Decision

預設檔位改用獨立的 `~/.codex/default.config.toml`，並在一般 Start、續行 Start 與 QuotaProbe 一律顯式傳入 `--profile default`；`advisor` 維持 `advisor.config.toml`，兩份檔案都保留 `[agents]` 區段。已評估並排除的替代方案為沿用 `config.toml` 並加漂移偵測，以及改用 `dispatch.config.toml` 這類更具體的命名。

## Consequences

`config.toml` 回歸 Codex 應用程式自身設定的角色，預設檔位的 resolved model 與 effort 不再隨應用程式操作漂移。`--profile` 仍是語意欄位而不進入 `codex_parent_option`，父層選項比對未放寬，因此本次變更前建立的 RunRecord 續行時會以 `ParentOptionsMismatch` 拒絕，屬一次性過渡影響。
