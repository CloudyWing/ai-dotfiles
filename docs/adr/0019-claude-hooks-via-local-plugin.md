---
status: accepted
date: 2026-11-02
---

# ADR-0019：Claude Code hook 以本機 plugin 散佈，取代 settings.json 直接引用

## Context

Claude Code hook 原由 `~/.claude/settings.json` 以絕對路徑引用 `scripts/hooks/post-edit-write-hook.ps1`，`Setup-AIGlobalConfig.ps1` 不建立也不合併該檔，新機需手動填入路徑。新增 hook 會擴大手動設定面，hook 位置也與各機器的 checkout 路徑綁定。

## Decision

hook 改由 `.ai-agents` 內的本機 marketplace `ai-agents-local` 與 plugin `ai-agents-hooks` 提供，Setup 以 `claude plugin` CLI 加入 marketplace 並安裝 plugin，對 `settings.json` 只移除指向舊腳本的 hook 項目。plugin 不設 `version` 以就地載入，marketplace 根取 Setup 所在 checkout 根下的 `claude-plugins`，排除由 Setup 合併 `settings.json` 與維持手動引用。

## Consequences

修改 hook 腳本後下一個 session 生效而不需重裝，新機執行 Setup 即得到相同 hook。實測確認桌面 app Code 分頁與 CLI 都會觸發 plugin hook，`${CLAUDE_PLUGIN_ROOT}` 指向 marketplace 原始目錄；Claude Code 另在 `~/.claude/plugins/cache/` 保留一份副本，但不作為執行來源。

marketplace 根隨執行 Setup 的 checkout 而定，從線分支 worktree 執行時會指向該 worktree。合併回 main 後須在 main 以 `-Force` 重跑 Setup 改指 marketplace，確認 hook 仍觸發後才移除 worktree，否則 worktree 移除後 hook 失效。

PostToolUse 的純文字 stdout 不進入模型 context，`post-edit-write-hook` 的提示只在背景輸出，與改用 plugin 前的行為相同。
