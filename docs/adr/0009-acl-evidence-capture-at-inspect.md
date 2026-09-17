---
status: accepted
date: 2026-09-17
---

# ADR-0009：ACL evidence 改於 Inspect 正常結束後擷取

## Context

ADR-0006 規定 `Start` 在 Codex 行程啟動且 sandbox 套用後擷取 ACL evidence，但 `Start` 在 spawn 後數毫秒即回傳，而 sandbox 外部實測顯示 sandbox ACE 在 spawn 後約 30 秒才出現、正常結束後保留，且同一目錄連續執行沿用同一 SID 不累積，因此 Start 時點的 known 零命中是常態而非邊界。此時點錯誤使 Review 連續三輪在同一段擷取邏輯出現不同缺陷，其中一輪以 gate 已接受的 entry 回填零命中結果，把未曾觀察到的 ACE 標記為已擷取。

## Decision

`Start` 只在 spawn 前把 dispatch root 的非繼承 ACL 保存為 `sandbox_acl_baseline` 並寫入 `capture_status=pending`，`Inspect` 僅在事件尾端為 `turn.completed` 且 exit code 為 0 時擷取 post-completion snapshot，依 `pending`、`captured`、`no_match`、`unknown`、`failed`、`rejected` 六態判定，只有 `captured` 允許續行，gate 已接受的 entry 不得寫入任何觀察結果。首輪 `captured` 須相對 baseline 恰多出一筆 identity 未解析且 canonical tuple 為 `(OI)(CI)(M)` 的 entry，且 baseline 無任何條目消失；續行時 `Inspect` 與 gate 皆以雙向集合比較，要求非繼承 entry 集合與前輪 `captured` 的 fingerprint 集合完全相同。ADR-0006 其餘決策維持有效，包括沒有可用 `captured` RunRecord 時才適用單筆 fallback、被強制終止的殘留維持 `WorktreeAclResidue` 拒絕，以及整個流程只讀取 ACL、不呼叫任何 ACL 寫入 API。

## Consequences

本 ADR 取代 ADR-0006 成為 ACL continuation evidence 的唯一有效入口；正常結束的 worktree 可在 Inspect 後續行，零命中、讀取失敗或 ACL 發生未預期增減時一律拒絕續行，不以候選資料補足證據。支持本決策的時點、保留與 SID 穩定性實測保存於本機 `.local/ai-sessions/report/dispatch-mechanism-batch1/acl-lifecycle-probe/`，不在版控內，強制終止時的 ACL 行為與其他機器環境仍待平台驗證。`codex-dispatch` SKILL.md 中「sandbox helper 在正常結束時才移除自己套用的 ACL」與實測相反，須另行修正。
