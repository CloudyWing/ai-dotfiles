---
status: accepted
date: 2026-11-02
---

# ADR-0016：Codex Reviewer 的大範圍審查由規則指定 intensive 檔位

## Context

ADR-0009 規定 `intensive` 只在使用者於當下 Session 明確指定後使用，但預設檔位審查規則檔機制條款與多檔變更時多次提前結束，要求使用者每次審查前都指定並不實際。

## Decision

檔位集合維持預設、`intensive` 與 `advisor`。Codex `Reviewer` 審查規則檔機制條款，或審查範圍達 3 個檔案以上時，由主 Agent 依規則在 Request 指定 `intensive`，不需使用者在當下 Session 指定，其餘實作與審查使用預設檔位，使用者在當下 Session 指定 `intensive` 的路徑保留。腳本不自動選用檔位、不依額度切換，`intensive.config.toml` 不存在時於啟動前拒絕，`advisor` 的用途與授權沿用 ADR-0003 的決策。

## Consequences

大範圍審查的 Codex 消耗較高，檔位判定集中在 `instructions.md` 的審查配對，README 與 `start.md` 指回該處。本決策取代 ADR-0009 的檔位選用條件。
