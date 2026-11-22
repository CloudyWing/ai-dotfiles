---
status: accepted
date: 2026-11-20
---

# ADR-0047：Claude subagent 的模型與驗證失敗處置只由登錄表決定

## Context

ADR-0043 讓執行者由登錄表與選派入口判定，但 Claude 端 subagent 的模型仍另寫在三類位置，包含設計起草與 Demo 產出兩個角色寫在規則檔與 agent 定義的模型、規則檔轉述的選派結果，以及 skill 標註的預期執行者。驗證失敗時可否自行修正重跑，也以模型名稱寫在多份 agent 規則檔與 skill，各處寫法已不一致。

## Decision

Claude 端 subagent 的模型與驗證失敗時可否自行修正重跑，都只寫在 `scripts/dispatch/executor-registry.json`，由 `scripts/Select-DispatchExecutor.ps1` 輸出；規則檔、agent 規則檔與 skill 只寫任務標註，不寫模型名稱，也不轉述選派結果（條文見 `rules/claude/10-persona-routing.md`「Claude 端 sub-agent 模型指定」與 `skills/workflow-orchestration/references/claude-implement.md`「驗證失敗處置」）。理由是任務標註是穩定的輸入，執行者是登錄表算出的結果，同一件事只留一個來源。決定當時評估並排除的做法如下，來源為 2026-11-20 使用者確認的需求摘要。

- 設計起草與 Demo 產出兩個角色的模型維持寫在規則檔與 agent 定義。
- 驗證失敗處置改依任務旗標判定，因為可否自行修正是執行者的性質，同一任務轉給其他執行者時處置應隨之改變。
- 驗證失敗處置維持以模型名稱區分。
- 在登錄表另外記錄推理強度，因為當時沒有任何執行者需要非預設值的證據。

## Consequences

新增或更換 Claude 模型只改登錄表。在規則檔、agent 定義或 skill 寫回模型名稱（例如在 agent 定義指定模型、標註預期執行者，或寫明某個模型不重試）即違反本決定，檢查方式是在 `rules/claude`、`skills`、`agents` 與 `templates` 搜尋模型名稱應無命中。未經選派入口派生的執行（例如使用者直接叫起 Persona）沒有選派結果可依，視同可自行修正。
