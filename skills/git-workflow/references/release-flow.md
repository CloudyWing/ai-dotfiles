# git-workflow 模式：release-flow

專案的 `git-workflow` 註記為 `release-flow` 時，與 `git-workflow` SKILL.md 本體一起載入。本檔只寫 `release-flow` 專屬的規則，線分支、整理與改寫邊界的共用規則以本體節名引用。本模式負責 `CHANGELOG.md` 與版號。

## 整合分支與版號

- `release/vX.Y.Z` 從 `main` 建立。`hotfix/vX.Y.Z` 從最新版本標籤建立，最新標籤為 `git tag --merged main --list "v*" --sort=-v:refname` 的第一筆。
- 建立分支時向使用者詢問分支種類（`release` 或 `hotfix`）與版號，可附建議值，由使用者決定。
- 確認版號符合 `^v[0-9]+\.[0-9]+\.[0-9]+$`、高於最新標籤，且本機與遠端都沒有同名標籤與分支。遠端查詢失敗時只檢查本機，並在回報註明。任一項不符時重新詢問，不自行修正。
- 建立 `hotfix` 時沒有任何版本標籤，停止並詢問是否改建 `release`。

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
- `main` 不改寫。已發佈內容的修正以 `hotfix/vX.Y.Z` 的新 commit 處理。
- 已合併的 `release/*`、`hotfix/*` 不改寫。
