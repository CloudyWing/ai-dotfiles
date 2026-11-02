---
status: accepted
date: 2026-11-02
---

# ADR-0026：續行的父層選項由錨點 RunRecord 還原並逐欄比對

## Context

`--profile`、`--add-dir`、`--search` 與 `-c` 覆寫決定檔位、寫入權限與網路能力，續行若依當下 shell 或預設值重新推導，執行條件會與前一輪不一致。

## Decision

初次 Start 將有效父層選項寫入 RunRecord 的 `parent_options`（保留原文與順序）與 `parent_options_sha256`。續行未顯式傳入時從錨點還原，顯式傳入時逐欄比對，任一不同即以 `ParentOptionsMismatch` 拒絕並輸出首個差異位置，不以當次呼叫值覆蓋錨點值。舊 RunRecord 沒有此欄位時回報 `ParentOptionsUnknown`，不續行原 thread。

## Consequences

新增的自動選項只在新 cold-start 合成，舊錨點維持原陣列，因此要套用新預設須以新的 cold-start 重建 thread，ADR-0017 的 token 組即依此運作。fingerprint 涵蓋範圍變動時須同時處理舊紀錄的相容讀取。
