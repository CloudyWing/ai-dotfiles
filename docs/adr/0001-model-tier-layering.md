---
status: accepted
---

# ADR-0001：模型檔位分層，規則層只認語意名稱

## Context

跨平台派工需要依任務性質與額度狀況切換 Codex 模型，但 `agents/codex/*.toml` 的頂層鍵白名單只允許 `name`、`description` 與 `developer_instructions`，寫入其他鍵會使 Codex 靜默丟棄整份 agent 定義，因此模型設定無法綁在 agent 定義上。剩餘的承載位置只有規則層的 `instructions.md` 與本機的 `~/.codex/` 設定。

## Decision

`instructions.md` 只記載語意檔位名稱 `bulk` 與 `deep`，實際 model id 與 `model_reasoning_effort` 全數留在 `~/.codex/<檔位名稱>.config.toml`，派工指令以 `-p <檔位名稱>` 引用。不帶 `-p` 即為頂層預設的省用檔位。

## Consequences

model id 改名或額度配比調整時只改本機設定，規則層不動，且規則層不會洩漏模型代號。代價是 profile 檔案位於 `~/.codex/` 且不進版控，換機器需重新建立，此缺口由 `Setup-AIGlobalConfig.ps1` 的環境檢查段與 README 前置需求章節承接。另因 Codex 遇到不存在的 profile 不報錯、exit 0、靜默回退預設值，`-p` 的值域只能由規則層以白名單約束，無法機械強制。
