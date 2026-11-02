---
name: codex-dispatch
description: 'Codex 派工機制：依派工類型建立執行契約、以 codex exec 啟動 Codex、背景等待、取證並回收結果。當需要發動 codex、撰寫派遣單或執行派遣回收判定時使用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Codex 派工機制

本 Skill 負責派工的執行機制。是否派工由 `instructions.md` §1.5 的路由規則判定，本 Skill 只處理指令、落點、等待、取證、續 session 與回收。

## 階段路由

依目前所在階段讀取對應的 reference，不需要預先讀取其他階段的檔案。

| 階段 | 讀取 | 涵蓋 |
| --- | --- | --- |
| 首次派遣：撰寫派遣單、Preflight、Prepare、Start | `references/start.md` | 入口選擇、Dispatch 正式入口、Caller Session 併行准入、派工前的 AI-PROFILE 前置檢查、派工前的 git-workflow 分支符合性檢查、額度與範圍、advisor consult、腳本介面、派遣單、Git 前置探針與 worktree、PID 與並行檢查、模型檔位 |
| 等待與續行：等待完成、判定出口、事件流取證、續 session | `references/execution.md`；續行時另讀 `references/recovery.md`「失敗與恢復導引」末段的 ScopePlan hash 紀錄說明 | 中斷保全、三出口、事件流取證、續行與跨介面接手、sandbox 外環境動作、網路能力邊界 |
| 回收與清理：Collect、回收三態、Phase commit、Cleanup、結案報告 | `references/collect.md`，回收前另讀 `references/recovery.md`「RecoveryPrecheck」與 `references/start.md`「派遣單契約」的「補驗」小節（複核政策） | 歷史派遣 Cleanup 接手、Phase commit、執行端共用作業、回收三態、值班通知、保存契約、結案報告 |
| 失敗與恢復 | `references/recovery.md`，再讀失敗所在階段的檔案 | 失敗形狀與恢復方式、四種阻塞形狀、RecoveryPrecheck |

references 內的「上節」「本 Skill 開頭」等位置描述沿用拆分前的章節順序；跨檔相依以上表為準。執行端角色依角色規則檔引用的節名讀取該節，節所在檔案見「章節位置」。

## 章節位置

| 章節 | 檔案 |
| --- | --- |
| 使用時機與入口選擇 | `references/start.md` |
| 已結束歷史派遣的 Cleanup 接手 | `references/collect.md` |
| 最短正常路徑 | `references/start.md` |
| 失敗與恢復導引 | `references/recovery.md` |
| 額度與範圍契約 | `references/start.md` |
| InterruptionSafeguard | `references/execution.md` |
| Advisor consult resource dispatch | `references/start.md` |
| Git 前置探針與 worktree 生命週期 | `references/start.md` |
| Worktree 安全不變量 | `references/start.md` |
| Codex 進程 PID 與並行檢查 | `references/start.md` |
| Phase commit 回收與驗證 | `references/collect.md` |
| 腳本介面與執行前提 | `references/start.md` |
| 指令契約 | `references/start.md` |
| 模型檔位規則 | `references/start.md` |
| 完成判定與三出口 | `references/execution.md` |
| 事件流取證 | `references/execution.md` |
| 續 session 與跨介面接手 | `references/execution.md` |
| sandbox 外環境動作 | `references/execution.md` |
| 網路能力硬邊界 | `references/execution.md` |
| 兩種派工差異 | `references/start.md` |
| 執行端共用作業 | `references/collect.md` |
| 派遣單契約 | `references/start.md` |
| RecoveryPrecheck | `references/recovery.md` |
| 回收三態判定 | `references/collect.md` |
| 值班通知 | `references/collect.md` |
| 保存契約對照 | `references/collect.md` |
| 結案報告與 Git 來源紀錄 | `references/collect.md` |
