---
status: superseded
date: 2026-09-16
superseded-by: 0009
---

# ADR-0006：以 sandbox ACL evidence whitelist 判定 worktree 續行

## Context

`Get-WorktreeAclGate` 原本以「dispatch 根目錄的明確 ACE 是否全部存在於 source」的集合差集判定殘留，但 Codex sandbox 正常結束後留下的 SID 條目必然不在 source，因此 Codex 執行過一次的 worktree 一律被判 `WorktreeAclResidue`，Reviewer 退回時的同 worktree 續修與 RecoveryHandoff 都會被擋。`codex-dispatch` 規則禁止修改 worktree ACL，無法以清除殘留的方式繞過。

## Decision

`Start` 在 Codex 行程啟動且 sandbox 套用後，將本次的明確 ACL 條目連同 canonical tuple 與 fingerprint 寫入 RunRecord 的 `sandbox_acl_evidence`，`Inspect` 只在事件尾端為 `turn.completed` 且 process exit code 為 0 時標記 `continuation_allowed=true`。gate 改為先算 raw residue，再以前輪正常完成 RunRecord 的 fingerprint 白名單過濾；沒有可用 RunRecord 時，只把單筆 identity 未解析且 canonical tuple 等於 `(OI)(CI)(M)` 的條目視為 sandbox ACE，已解析 SID、不同權限、不同 inheritance 或多筆殘留一律不適用此 fallback。整個流程只讀取與保存 ACL，不呼叫任何 ACL 寫入 API。

## Consequences

正常結束的 worktree 可續行，被強制終止而沒有正常完成證據的殘留維持 `WorktreeAclResidue` 拒絕，`SKILL.md`「被強制終止過的 dispatch worktree 不得重用」的安全不變量不變。`RecoveryHandoff` 的 `acl_gate` 追加 `raw_residue`、`accepted_sandbox_entries` 與 `sandbox_evidence_status`，缺少白名單的舊 handoff 視為空集合，只能通過沒有殘留的情境。不同 Windows 版本對未解析 identity 的文字表示可能不同，因此判定以 canonical tuple 與 fingerprint 為準而非顯示字串，無法符合單筆 tuple 時一律拒絕。
