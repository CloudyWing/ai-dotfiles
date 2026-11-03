# git-workflow 模式：release-flow

專案的 `git-workflow` 註記為 `release-flow` 時，與 `git-workflow` SKILL.md 本體一起載入。本檔只寫 `release-flow` 專屬的規則，線分支、整理與改寫邊界的共用規則以本體節名引用。本模式負責 `CHANGELOG.md` 與版號。

## 整合分支與版號

本檔的 `main` 指主分支，判定方式見本體「主分支判定」。

本節與「commit 落點與啟動 Workflow 檢查」「合併前流程」「hotfix 合併後同步」適用於已有版本標籤的 repo。尚無版本標籤時依「初次發佈前」，`release/*` 與 `hotfix/*` 從第一個版本標籤建立後才使用。

- `release/vX.Y.Z` 從 `main` 建立。`hotfix/vX.Y.Z` 從最新版本標籤建立，最新標籤為 `git tag --merged main --list "v*" --sort=-v:refname` 的第一筆。
- 建立分支時向使用者詢問分支種類（`release` 或 `hotfix`）與版號，可附建議值，由使用者決定。
- 確認版號符合 `^v[0-9]+\.[0-9]+\.[0-9]+$`、高於最新標籤，且本機與遠端都沒有同名標籤與分支。遠端查詢失敗時只檢查本機，並在回報註明。任一項不符時重新詢問，不自行修正。
- 尚無版本標籤時不建立 `release` 或 `hotfix` 分支，改依「初次發佈前」。

## commit 落點與啟動 Workflow 檢查

| 目前分支 | commit | 啟動 Workflow |
| --- | --- | --- |
| `release/*`、`hotfix/*` | 允許 | 允許 |
| 本線的 `feature/<lineSlug>`，upstream 為 `release/*` 或 `hotfix/*` | 允許 | 允許 |
| `main` | 只允許純文件修改 | 停止並詢問版號（分支種類與版號），依回答建立對應分支並切換後繼續 |
| 其他分支或 detached HEAD | 停止回報 | 停止回報 |

- 純文件修改指變更檔案全部符合 `*.md`、`docs/**`、`LICENSE*`，且不含 `CHANGELOG.md`。
- `main` 上的變更含非純文件檔案時，commit 停止並詢問版號，處置與啟動 Workflow 相同。
- 純文件修改 commit 到 `main` 之後，進行中的 `release/*`、`hotfix/*` 在下一次於其上 commit 前或合併前（先到者為準），以 `git merge-base --is-ancestor main <分支>` 檢查。落後時以本體「整理流程」的整理分支 rebase 到 `main`，走第一層「整合上游變更」路徑；分支已推送時依本體「改寫與 force push 邊界」取得當輪授權。
- 開發期間（合併前流程以外）的 commit 變更集含 `CHANGELOG.md` 時停止，說明 CHANGELOG 在合併前流程才寫入，詢問是否將該檔排除於本次 commit。

## 初次發佈前

### 版本標籤判定

`git tag --list "v*"` 沒有輸出，且存在 `origin` 遠端時 `git ls-remote --tags origin "v*"` 也沒有輸出，即為尚無版本標籤。遠端查詢失敗時停止回報，不判定。

尚無版本標籤時，`main` 是整合分支。

### commit 落點與啟動 Workflow 檢查

| 目前分支 | commit | 啟動 Workflow |
| --- | --- | --- |
| `main` | 允許 | 允許，不詢問版號 |
| 本線的 `feature/<lineSlug>`，upstream 為 `main` | 允許 | 允許 |
| 其他分支或 detached HEAD | 停止回報 | 停止回報 |

- 開發期間 commit 的變更集含 `CHANGELOG.md` 時，處置與已有版本標籤時相同，CHANGELOG 在初次發佈流程才寫入。
- 每次 push 前，對 `origin/main..main` 執行本體「整理流程」的「只收合 `fixup!`」路徑，並確認 `git log origin/main..main --format=%s` 沒有以 `fixup! `、`squash! `、`amend! ` 開頭的行。`origin/main` 不存在時本項不適用。

### 遠端分支判定

只看主分支是否已推送，遠端的其他分支不影響判定。依下列順序判定，命中即停止。

1. `git remote` 的輸出不含 `origin` 時，判定為未推送。
2. `git ls-remote --heads origin refs/heads/main` 成功且沒有輸出時，判定為未推送。
3. `git ls-remote --heads origin refs/heads/main` 成功且有輸出時，判定為已推送。
4. 命令失敗時停止回報，不判定，也不壓縮。

### 初次發佈流程

使用者要求發佈第一個版本時，依下列順序執行，前一步通過才進入下一步。

1. 詢問版號，可附建議值，由使用者決定。確認版號符合 `^v[0-9]+\.[0-9]+\.[0-9]+$`，且本機與遠端都沒有同名標籤與分支。
2. 確認缺陷已修完，做法同「合併前流程」第 1 步。範圍是 `.local\ai-sessions\report\` 下的全部 `lineSlug` 目錄，交使用者確認。
3. 更新版號檔，做法同「合併前流程」第 3 步。
4. 寫入 CHANGELOG。在 `main` 加入最後一筆獨立 commit，只含 `CHANGELOG.md`，type 為 `docs`，內容記錄第一個版本。打標籤前以 `git log -1 --name-only --format=` 確認末筆只列出 `CHANGELOG.md`。未推送路徑的這筆 commit 會在第 7 步併入初始 commit。
5. 依「遠端分支判定」分流，把結果與第 6 步的處理方式列入授權請求。
6. 取得使用者當輪授權，屬 commit 類。
7. 整理歷史。
    - 未推送：依「壓縮成初始 commit」把 `main` 整理為單一 commit。
    - 已推送：不壓縮。對 `origin/main..main` 執行本體「整理流程」的「只收合 `fixup!`」路徑。
8. 打標籤：`git tag -a vX.Y.Z -m "vX.Y.Z" <SHA>`。未推送時 `<SHA>` 是初始 commit，已推送時 `<SHA>` 是 `main` 的 HEAD。
9. 推送 `main` 與標籤前，另取得使用者當輪授權。未推送路徑是首次推送，不使用 force push。
10. 清理：依「壓縮成初始 commit」第 7 步處理備份分支。

第一個版本標籤建立後，之後的版本依「合併前流程」。

### 壓縮成初始 commit

只在「遠端分支判定」為未推送時執行。

前置條件如下，任一項不符時停止回報。

- `git status --porcelain` 沒有輸出。
- 本機分支只有 `main`，且 `git worktree list --porcelain` 只列出主 checkout。其他分支與 worktree 以壓縮前的歷史為基底，壓縮後會與 `main` 失去共同祖先，所以有其他分支或 worktree 時列出清單，由使用者決定先落地或刪除。
- 「遠端分支判定」為未推送。
- 以 `git ls-remote --heads origin` 列出遠端的其他分支（沒有 `origin` 時略過）。有任何分支時列出清單並停止，由使用者決定先刪除、落地或接受它們與新 `main` 失去共同祖先。這項只影響能否壓縮，不改變「遠端分支判定」的結果。

1. 記錄 `beforeSha` 為 `git rev-parse main` 的輸出。
2. 建立備份：`git branch backup/main-before-initial-squash-<beforeSha 前 7 碼> <beforeSha>`。同名分支已存在時停止，不覆蓋。
3. 建立整理分支並提交。執行 `git checkout --orphan refactor/tidy-main` 保留目前的 index 與工作樹，再以 `git commit -F <訊息檔>` 建立無父 commit，記錄 `afterSha`。訊息依 `generate-commit` skill「初始 commit」的固定格式。hook 照常執行，不使用 `--no-verify`。
4. 驗證。以本體第一層「純歷史重排」的完整 tree 比對確認 `beforeSha` 與 `afterSha` 沒有檔案內容差異，`git rev-list --count <afterSha>` 輸出 `1`，且 `git status --porcelain` 沒有輸出。hook 已暫存的改動會讓完整 tree 比對失敗；hook 留下未暫存或未追蹤的改動時，`git status --porcelain` 會有輸出，同樣判定失敗。
5. 執行本體「重整後驗證」。
6. 更新 `main`：執行 `git switch main`，再確認一次 `git status --porcelain` 沒有輸出（切換會觸發 post-checkout hook），通過後才執行 `git reset --hard <afterSha>`，再以 `git branch -D refactor/tidy-main` 刪除整理分支。有輸出時不執行 reset，停止回報。第 4、5 步任一失敗時不切換、不刪除，保留 `main`、備份分支、整理分支與證據。
7. 首次推送成功，且 `git rev-parse origin/main` 等於 `afterSha` 後，才以 `git branch -D` 刪除備份分支。尚未推送時保留備份分支，在回報中列出名稱。

## 合併前流程

依下列順序執行，前一步通過才進入下一步。

1. 確認缺陷已修完。列出本 release 範圍各線的審查報告（`review-report*.md`、`frontend-reviewer-report.md`、`contract-auditor-report.md`）finding、Developer 結案報告「未解決項目」，以及 `exceptions.md` 中類型為「範圍外既有問題」且未處理的條目，逐筆標示已修、已排除或未修。已排除須由使用者明示並記錄於 `exceptions.md`。任一筆未修時停止。本 release 範圍的線，以 `.local\ai-sessions\report\` 下最後寫入時間晚於該分支第一筆獨有 commit 時間的 `lineSlug` 目錄列出，交使用者確認。
2. 對 `main..<release 分支>` 執行本體「整理流程」。
3. 更新版號檔。專案在檔案內宣告版號（例如 `<Version>`、`package.json`）時，更新後成為一筆獨立 commit；以 MinVer 或標籤推導版號的專案略過。無法判定版號宣告位置時詢問使用者。
4. 寫入 CHANGELOG。在 release 分支加入最後一筆獨立 commit，只含 `CHANGELOG.md`，type 為 `docs`，主題記錄該版本的變更。
5. 確認末筆。`git log -1 --name-only --format=` 只列出 `CHANGELOG.md`，且 `git diff --name-only <第 2 步的 afterSha> HEAD` 只含 `CHANGELOG.md` 與第 3 步的版號檔。第 4 步之後若出現修正，以 `fixup!` 建立並重做第 2 步，autosquash 會把修正併入目標，CHANGELOG commit 維持在最後一筆；修正影響 CHANGELOG 內容時，對 CHANGELOG commit 建立 `fixup!`。
6. 取得使用者當輪授權，屬 commit 類。
7. 合併：執行 `git switch main` 後，以 `git merge --no-ff -m "Merge branch '<分支>'" <分支>` 合併。`main` 已前進而分支尚未 rebase 時，先依「commit 落點與啟動 Workflow 檢查」的規則 rebase 再合併。
8. 打標籤：`git tag -a vX.Y.Z -m "vX.Y.Z" <merge commit SHA>`，標籤只打在 merge commit。
9. 推送 `main` 與標籤前，另取得使用者當輪授權。
10. 清理：標籤推送成功後，以 `git branch -d <分支>` 刪除本機分支。備份分支已在整理驗證通過後刪除。遠端分支不由本流程刪除。

## hotfix 合併後同步

hotfix 合併到 `main` 後，偵測進行中的 release 分支，即本機 `refs/heads/release/*` 與遠端 `refs/remotes/origin/release/*` 中尚未併入 `main`（`--no-merged main`）者。

| 偵測結果 | 處置 |
| --- | --- |
| 沒有 | 回報「無進行中的 release 分支，略過同步」，不建立分支 |
| 一個 | 將該分支 rebase 到 `main`，以本體「整理流程」的整理分支執行並走第一層「整合上游變更」路徑；已推送時依本體「改寫與 force push 邊界」取得當輪授權；衝突時停止回報 |
| 多個 | 列出並詢問使用者，不自行選擇 |

## 改寫與 force push

- 未合併的 `release/*`、`hotfix/*` 推送後仍可改寫，條件見本體「改寫與 force push 邊界」。
- `main` 不改寫。已發佈內容的修正以 `hotfix/vX.Y.Z` 的新 commit 處理。唯一的例外是尚無版本標籤且未推送的 `main`，初次發佈時依「壓縮成初始 commit」整理。
- 已合併的 `release/*`、`hotfix/*` 不改寫。
