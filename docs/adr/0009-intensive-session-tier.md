---
status: accepted
date: 2026-10-13
---

# ADR-0009：新增 Session 層級指定的 intensive 實作檔位

## Context

ADR-0003 把檔位集合定為預設與 `advisor`，並排除額外的實作檔位，理由是以額度門檻自動啟動高推理模型會讓派工卡在等待授權。實際運作中，部分 Session 的整批實作需要比預設檔位更強的模型，而這個需求由使用者在當下 Session 判斷，與額度門檻無關。預設檔位的設定檔又是全域共用，臨時改寫會影響其他專案的派工。

## Decision

本決策取代 ADR-0003 的檔位集合，改為預設、`intensive` 與 `advisor`。`intensive` 與預設檔位同為實作與執行檔位，差別只在讀取 `~/.codex/intensive.config.toml`；只有在使用者於當下 Session 明確指定後，該 Session 的派工才以 Request `profile` 或 `-Profile` 選用，指定不延續到其他 Session。腳本不自動選用、不依額度切換，設定檔不存在時在啟動前拒絕，不回退預設檔位。`advisor` 的用途、授權與 gate 維持 ADR-0003 的決策。排除的方案為直接改寫 `default.config.toml`，以及依額度或任務類型自動切換檔位。

## Consequences

使用者可在單一 Session 改用較強模型，不影響其他專案的預設派工；`intensive.config.toml` 是選用的本機設定，`Setup-AIGlobalConfig.ps1` 缺檔時不警告。續行沿用初始啟動的檔位，跨檔位續行照常以父層選項不一致拒絕。檔位值域仍由規則層白名單約束，因為 Codex 遇到不存在的 profile 會靜默回退預設值。
