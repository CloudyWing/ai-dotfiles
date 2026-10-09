---
status: accepted
date: 2026-10-09
---

# ADR-0005：續行以程序身分與 failure receipt 保護，不以 ACL evidence 放行

## Context

Codex sandbox 在 dispatch worktree 留下的 ACL 條目會讓同 worktree 續行被誤判為殘留，曾以 Start 時點擷取 ACL evidence、改於 Inspect 後擷取並以 fingerprint 白名單放行，但實測 sandbox ACE 在 spawn 後約 30 秒才出現，且該 gate 只讀取 ACL、不施加任何權限，證據缺少或變動時反而擋下有效 thread 的續行。另外 CIM 查詢在部分 sandbox 環境會被拒絕存取，程序身分若只依 CIM 判定，會把查詢失敗誤當成程序已結束。

## Decision

續行不再以 ACL／SID evidence 作為放行條件，保護改由 PID、根程序名稱與建立時間、完整程序樹與停止程序檢查承擔；CIM 只在存取遭拒（0x80041003、0x80070005、UnauthorizedAccessException、CimException 的 NativeErrorCode 為 AccessDenied）或逾時（0x80041069、0x80043001、0x800705B4、TimeoutException）時改用 System.Diagnostics.Process 備援，其他錯誤回報無法查詢，備援缺少父程序資訊時一律視為未確認並阻擋 Start、Cleanup 與 recovery。續行失敗時寫入 failure receipt，交接已確認成果、未完成單位與冷啟動範圍，不自動重試。排除的方案為 ACL evidence whitelist、Inspect 時點擷取與以 PID 單獨判定身分。

## Consequences

正常結束的 worktree 可直接續行，查詢遭拒不會被推導為程序不存在，被強制終止的派遣以程序身分與 failure receipt 判定能否清理或冷啟動。舊 RunRecord 中的 `sandbox_acl_evidence` 欄位不再被讀取。
