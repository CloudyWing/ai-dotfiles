---
status: proposed
date: 2026-11-14
---

# ADR-0040：派工時自動補上派工帳號的專案信任

## Context

Codex 只在受信任的專案內執行命令。派工帳號的 `config.toml` 缺少某專案的信任段落時，該專案的派遣會失敗，使用者必須在建立帳號時預先列出所有會派工的專案，新增專案時再逐一補上。派工帳號有多個，換帳號時每個帳號都需要相同的信任設定。

## Decision

Dispatch 在選定帳號後、Preflight 建立 worktree 前，確認該帳號的 `config.toml` 已信任派遣來源專案，缺少時在 `machine.json` 同目錄的 `codex-account.lock` 鎖內以原子寫入補上信任段落，並在派遣結果的 `project_trust` 記錄帳號、設定檔路徑與信任鍵。信任鍵為來源專案的 git 主工作樹根，以小寫寫入；來源是 linked worktree 時取其主工作樹根，來源不是 git 目錄時取來源目錄本身。範圍限 `machine.json` 登記的派工帳號，使用者預設的 `~/.codex` 與未登記的 home 維持原樣，只信任專案根目錄，不信任上層資料夾。`config.toml` 不存在、是連結或格式不支援的帳號，在候選階段略過並改試下一個帳號。

排除的方案如下。建立帳號時要求列出全部專案，新增專案就要重跑建立腳本。信任上層資料夾，會讓同一資料夾下的其他專案一併被信任。修改 `~/.codex`，會影響使用者在 Codex Desktop 的設定。

## Consequences

新專案第一次派工時自動取得信任，建立帳號時 `-ProjectPath` 改為選填。派工腳本會改寫派工帳號的使用者設定檔，改寫範圍與內容記錄在每次派遣結果中。

來源專案的路徑無法轉為信任鍵時（例如 git submodule），Dispatch 以 `CodexProjectPathUnsupported` 拒絕該次嘗試且不換帳號，由使用者以建立腳本的 `-ProjectPath` 預先加入信任。

本決策維持 proposed，原因是 Codex 判定信任依據的路徑尚未以實機確認。信任鍵設為主工作樹根的前提是 Codex 對位於其下的 dispatch worktree 套用同一份信任；以獨立的試驗 Codex home 與試驗 repo 實測派遣 worktree 能否執行命令後，才改為 accepted。實際派遣結果中出現 `already-trusted` 並正常完成，屬間接證據。README、`start.md` 與腳本訊息已依此前提撰寫，實測結果若否定前提，這些文件與信任鍵的計算方式須一併修正。
