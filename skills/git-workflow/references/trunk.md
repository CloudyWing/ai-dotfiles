# git-workflow 模式：trunk

專案的 `git-workflow` 註記為 `trunk` 時，與 `git-workflow` SKILL.md 本體一起載入。本檔只寫 `trunk` 專屬的規則，線分支、整理與改寫邊界的共用規則以本體節名引用。

## 整合分支

整合分支為主分支，判定方式見本體「主分支判定」。本檔的 `main` 與 `origin/main` 皆指判定結果，例如主分支為 `master` 時，`origin/main..main` 即為 `origin/master..master`。

## commit 落點

| 目前分支 | commit |
| --- | --- |
| `main` | 允許，適用本體「線分支與獨立 worktree」判定為直接在整合分支的工作 |
| 本線的 `feature/<lineSlug>` | 允許 |
| 其他分支（`backup/*`、`dispatch/*`、其他線的 `feature/*`）或 detached HEAD | 停止回報，不 commit |

## 啟動 Workflow 檢查

- 確認 Phase 數 = 1 的線目前分支為 `main`。
- 確認 Phase 數 >= 2 的線已依本體「線分支與獨立 worktree」的建立程序開出 `feature/<lineSlug>`，且目前位於該 worktree。
- 目前分支不符上列任一情形時停止回報。

## 線分支落地

依本體「線分支與獨立 worktree」的落地程序，以 `main` 為整合分支，用 `git merge --ff-only feature/<lineSlug>` 落地。落地需使用者當輪授權，屬 commit 類。

## 尚未推送前的修正

修正尚未推送的 commit 時，由 `generate-commit` 步驟 4 建立 `fixup!` commit，不另建獨立的修正 commit。

## push 前整理與檢查

- 每次 push 前，對 `origin/main..main` 執行本體「整理流程」的「只收合 `fixup!`」路徑（`rebase -i --autosquash`），並把整理結果列入 push 授權請求。範圍內沒有 `fixup!` 時不整理。
- 確認 `git log origin/main..main --format=%s` 沒有以 `fixup! `、`squash! `、`amend! ` 開頭的行，再請求 push 授權。
- `origin/main` 不存在（沒有遠端）時本節不適用。

## 改寫已推送的 main

依本體「改寫與 force push 邊界」，改寫已推送的 `main` 每次都需使用者當輪授權，授權涵蓋該次改寫與 force push。

## CHANGELOG 與版號

本模式不處理 `CHANGELOG.md`、版號與標籤。
