---
status: accepted
date: 2026-11-11
---

# ADR-0036：Codex 成本列由 Inspect 自動追加並以增量記錄 usage

## Context

ADR-0004 規定需求級的成本累計由協調者寫入同線 `cost-ledger.md`，成效比對需要每個 run 的輪次與 token 資料，手寫無法保證每個 run 都被記錄。實測證實事件流 `turn.completed.usage` 是 Codex thread 的累計值，續行的 run 直接加總會重複計入前次用量。

## Decision

每個 Codex run 結束時由 `Inspect` 自動在 `cost-ledger.md` 追加一列事件列，usage 取自事件流，續行的 run 記錄與前一次累計值的差額。Claude subagent 的成本列與預算列仍由協調者手寫，同一 subagent 的續派列記錄本次通知總數減去已記錄 input 的累計和。本決策只修訂 ADR-0004 中「成本累計由協調者寫入」的寫入者分工，額度只供顯示與紀錄的其餘決定維持不變，因此 ADR-0004 不標為 `superseded`。

## Consequences

Codex 成本列不再依賴協調者手寫，續行不會被重複計入；在本決策之前以累計值直接加總的成本分析，續行占比較高的數字可能偏高。協調者漏填循環欄位時該 run 不進入輪數指標，Claude subagent 列與 Codex 列在 input 比例指標中分開呈現。
