---
status: accepted
date: 2026-11-02
---

# ADR-0023：派工帳號以 CODEX_HOME 綁定，跨 home 以冷啟動交接

## Context

單一帳號的額度用盡或認證失效時，派工會停擺，而 Codex 的認證與 session 都存放在各自的 `CODEX_HOME`。續行若在不同 home 執行，原 thread 不存在，也不應複製 sessions 或憑證。

## Decision

派工帳號登記於本機 `machine.json` 的 `codex_accounts`（名稱與已存在的絕對目錄），每個 home 使用獨立的非憑證 profile，並以 `-CodexHome` 明確選擇，同一派遣固定使用原 home。續行比對錨點記錄的 home 與帳號名稱，不符以 `ResumeAccountMismatch` 或 `ResumeAccountUnverifiable` 拒絕，要換 home 時以新 dispatchSlug 冷啟動，新 prompt 引用原 ScopePlan、成果與中斷檢查點並只列未完成單位。帳號切換由主 Agent 依實際服務端拒絕與有效額度快照判斷，排除自動輪替器與預先輪流派發。

## Consequences

腳本只能證明儲存目錄與別名，無法確認同一目錄內實際登入者的身分。新增帳號由 `New-CodexDispatchAccount.ps1` 建立，缺少可靠候選時不切換帳號，其他派遣仍遵守額度不作放行條件的契約。
