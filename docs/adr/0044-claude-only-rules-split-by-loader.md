---
status: accepted
date: 2026-11-17
---

# ADR-0044：規則層依載入端分置為 instructions.md 與 rules/claude/

## Context

全域規則集中在單一 `instructions.md`，Claude 與 Codex 兩端載入同一份完整內容。評估時約 73% 的內容只有 Claude 端需要，Codex 端因此載入大量與審查無關的 Persona、協調、授權與派工規則。

## Decision

兩端都需要的規則留在 `instructions.md`，只有 Claude 端需要的規則放在 `rules/claude/`，由 `scripts/Setup-AIGlobalConfig.ps1` 連結為 `~/.claude/rules`，Codex 端不載入。排除為 Codex 另做精簡版，因為共用規則會有兩份要同步；也排除把 Claude 專屬規則下放為 Skill，因為常駐規則無法下放。

## Consequences

需要 Codex 端遵守的規則不得寫在 `rules/claude/`。`~/.claude/rules` 連結缺少或中斷時 Claude Code 不載入也不提示，須重跑 Setup，`scripts/Setup-AIGlobalConfig.ps1 -Check` 可檢查連結現況。
