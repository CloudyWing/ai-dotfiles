# 歷史重整與整理流程

本檔收錄整理流程（歸併、刪除或重排 commit）與歷史重整與修正循環三層防護的完整規格。整理、rebase、squash、`fixup!` 收合、解衝突與修正循環前讀取。分支策略、授權、改寫與 force push 邊界留在 `../SKILL.md`。

## 整理流程

整理把來源分支 S 的 commit 歸併、刪除或重排，不改變檔案內容。觸發時機與整理範圍由模式檔規定。整理範圍的下界 `rangeBase` 依 S 決定。

| S | `rangeBase` |
| --- | --- |
| `trunk` 的 `main` | `origin/main`；不存在時範圍為空，跳過整理 |
| 尚無版本標籤時 `release-flow` 的 `main` | `origin/main`；不存在時範圍為空，跳過整理。初次發佈的壓縮另依 `release-flow.md`「壓縮成初始 commit」 |
| `release/*`、`hotfix/*` | `main` |
| `feature/<lineSlug>` | 該分支的 upstream，即整合分支 |

上表的值是參照。流程實際使用的 `rangeBase` 是該參照與 S 的 merge-base，以 `git merge-base --all <參照> <S>` 取得。輸出恰為一行時，該行的完整 SHA 即 `rangeBase`，在第 1 步記錄後全程使用同一個值。`<rangeBase>..<S>` 的 commit 與 `<參照>..<S>` 相同。沒有輸出，或輸出多於一行時本流程不適用，不擇一使用。輸出多於一行表示參照與 S 之間有交叉合併，`<參照>..<S>` 含 merge commit。此時停止回報，附 `git merge-base --all <參照> <S>` 與 `git rev-list --merges <參照>..<S>` 的輸出，範圍內的 commit 維持原樣，Agent 不改寫含 merge commit 的範圍，後續由使用者決定。第 1 步的結束條件先以 `<參照>..<S>` 判定，不需整理時不取 merge-base。參照已前進時，第 4 步的命令仍以分岔點為基準，不納入參照上的新 commit。需要整合上游變更時，另以整理分支執行 rebase，依第一層「整合上游變更」路徑驗證。

1. 確認前置條件：`git status --porcelain --untracked-files=all` 為空，本流程確認工作樹的命令都帶 `--untracked-files=all`，使結果不受 `status.showUntrackedFiles` 設定影響；內容修改（程式、文件、CHANGELOG、版號檔）已全部成為獨立 commit；記錄 `beforeSha` 與 `rangeBase`。範圍內沒有 `fixup!` commit 也沒有整理計畫時結束，不建立備份分支。`git rev-list --count <rangeBase>..<S>` 與 `git rev-list --count <rangeBase>..<S> --not --remotes` 相等時，範圍內全部是尚未推送的 commit，整理不需授權；不相等時範圍含已推送的 commit，屬已推送分支的歷史改寫，先依 `../SKILL.md`「改寫與 force push 邊界」取得當輪授權。下列三項任一成立時本流程不適用，停止。環境變數 `GIT_SEQUENCE_EDITOR` 已設定，它優先於第 4 步以 `-c sequence.editor=...` 指定的編輯器，會使擷取底稿的命令直接開始 rebase。`git rev-parse --git-path rebase-merge` 或 `git rev-parse --git-path rebase-apply` 所指的目錄存在，表示已有進行中的 rebase。`git rev-list --merges --count <rangeBase>..<S>` 大於 `0`，表示範圍含 merge commit，rebase 會略過它並把歷史改成線性，Agent 不改寫含 merge commit 的範圍。
2. 建立備份：`git branch backup/<名稱> <beforeSha>`。同名分支已存在時停止，不覆蓋。
3. 從 S 建立整理分支並切換過去：`git switch --no-track -c refactor/tidy-<名稱> <S>`。同名分支已存在時 git 拒絕建立，此時停止，不覆蓋，同一個 S 因此同一時間只有一個整理在進行。整理分支與備份分支只供建立它的這次整理使用，其他 Session 不簽出，也不在其上 commit。`--no-track` 使整理分支不繼承 upstream，第 8 步刪除時 git 才以 S 判定它有沒有獨有的 commit。切換後確認 `git status --porcelain --untracked-files=all` 為空，有輸出時（例如 checkout hook 改動了檔案）停止。
4. 在整理分支產生 todo 檔並套用，一律加上 `-c rebase.updateRefs=false`，不使用互動編輯器。
    - 取得底稿。先寫出擷取腳本，內容為 `cp "$1" "<底稿檔絕對路徑>"` 與 `exit 1` 兩行，再執行 `git -c "sequence.editor=sh '<擷取腳本絕對路徑>'" -c rebase.updateRefs=false -c rebase.abbreviateCommands=false rebase -i --autosquash <rangeBase>`。git 把依 autosquash 排好的 todo 交給腳本，腳本複製後以非零結束，rebase 不會開始，這個命令以非零結束是預期的結果。命令結束後確認底稿檔存在、`git rev-parse HEAD` 等於 `beforeSha`，且 `git status --porcelain --untracked-files=all` 為空，任一不符時停止。底稿去除註解行與空行後，每一行由命令與範圍內一筆 commit 的 SHA 組成，`fixup` 行緊接在它的目標之後，SHA 都是 S 上原本的 SHA。
    - 檢查底稿。出現 `pick`、`fixup` 以外的命令時（例如 `squash!`、`amend!` commit 產生的 `squash` 與 `fixup -C`）本流程不適用，停止。`pick` 行的 commit 第一行以 `fixup! `、`squash! ` 或 `amend! ` 開頭時，該筆是殘留修正，依「殘留修正」處理。
    - 寫出 todo 檔。以底稿為基礎，只用 `pick`、`fixup`、`drop`，改訊息以 `exec git commit --amend -F <訊息檔>` 表示。沒有整理計畫也沒有殘留修正時，底稿原樣作為 todo 檔，稱為「只收合 `fixup!`」路徑。其餘情況稱為 todo 檔路徑，依下列三項改寫。
      - 底稿的 `fixup` 行與它的目標是一組。移動目標時整組一起移動，刪除目標時整組都改為 `drop`。
      - 改訊息的 `exec` 行排在該 commit 與其全部 `fixup` 行之後。
      - 殘留修正依使用者的處置改寫，見「殘留修正」。
    - 檢查 todo 檔，全部符合才套用，不符時重寫。底稿的每一筆 commit 在 todo 檔恰好出現一次。每個 `fixup` 行往上第一個不是 `fixup` 的行是 `pick`，且該行的 commit 是這筆修正的目標；目標以底稿的分組與使用者對殘留修正的處置為準。目的是避免目標已改為 `drop` 的修正被收進前一筆 commit，這種錯誤不改變 tree，第 5 步偵測不到。
    - 套用。執行 `git -c "sequence.editor=cp '<todo 檔絕對路徑>'" -c rebase.updateRefs=false rebase -i --no-autosquash <rangeBase>`。`--no-autosquash` 使 git 不再重排已排好的 todo 檔。各 commit 的去向寫入回報。
    - 以 `-c sequence.editor=...` 指定 todo 編輯器，不使用 `GIT_SEQUENCE_EDITOR` 環境變數前綴。`sequence.editor` 的值由 git 交給其內建 shell 執行，同一行命令在 PowerShell 與 Git Bash 都可直接使用。
    - rebase 沒有完成就停下時（衝突、`exec` 行的命令失敗、git 拒絕 todo 檔的內容）停止。`git rebase --abort` 會重設 index 與工作樹，因此只在 `git status --porcelain --untracked-files=all` 為空時執行，執行後依「停止時的處置」重新取得狀態。`git status --porcelain --untracked-files=all` 有輸出時不執行 abort，rebase 維持在進行中，由使用者決定；衝突一律屬於這種情況。整合上游變更的 rebase 發生衝突時可依第一層「解衝突路徑」處理。
5. 執行第一層零差異 gate。第 4 步以 `rangeBase` 為基準，`upstreamBeforeSha` 與 `upstreamAfterSha` 都是 `rangeBase`，屬純歷史重排，`afterSha` 與 `beforeSha` 的完整 tree 必須相同。`git log <rangeBase>..<afterSha> --format=%s` 有以 `fixup! `、`squash! ` 或 `amend! ` 開頭的行時，本步不通過。
6. 執行 `../SKILL.md`「重整後驗證」。
7. 更新來源分支。在整理分支上依序確認下列兩項，任一項不符時停止。通過後依第一層「更新來源分支指標」切回 S 並更新，不使用 `git reset --hard`。
    - `git status --porcelain --untracked-files=all` 為空。
    - 重新執行第 1 步的兩個 `git rev-list --count`。第 1 步判定為不需授權，而此時兩者不相等時，範圍內有 commit 在整理期間被推送，停止。
8. 清理。依第一層「刪除重整建立的分支」刪除整理分支（預期 SHA 為 `afterSha`）與備份分支（預期 SHA 為 `beforeSha`）。

- 整理不得改動檔案內容，需要修改內容時先成為獨立 commit，再整理。
- 不使用 `--no-verify`。
- 本流程沒有續行。任何一步停止後，下一次整理從第 1 步重新開始，重新取得 `beforeSha`、`rangeBase` 與已推送狀態的判定，不沿用前一次的整理分支、備份分支、底稿與 todo 檔。目的是避免停止期間分支、工作樹或遠端狀態改變後，仍依舊的判定改寫歷史。
- 歸併計畫（例如把修正收進原 commit）不影響 tree，零差異 gate 偵測不到歸併錯誤。主 Agent 在回報列出計畫，並在 push 或發佈的授權請求中呈現給使用者。

### 停止時的處置

任何一步沒有得到該步寫明的結果時停止，含命令的結束碼、輸出或確認與該步所寫的不符，以及各步沒有寫到的情況。停止後不依停下的步驟推定狀態，先以下列命令取得實際狀態，再依下表由上而下對照，依第一個符合的列處置。回報列出停止的步驟、原因、這些命令的輸出與留下的分支。

- `git branch --show-current` 與 `git rev-parse HEAD`。前者沒有輸出表示 detached HEAD。
- `git rev-parse -q --verify refs/heads/<分支>`，對 S、整理分支與備份分支各執行一次，沒有輸出表示該分支不存在。
- `git --no-optional-locks status --porcelain --untracked-files=all`。`--no-optional-locks` 使這個命令不寫入 index。
- `git rev-parse --git-path rebase-merge` 與 `git rev-parse --git-path rebase-apply` 所指的目錄是否存在。

| 取得的狀態 | 處置 |
| --- | --- |
| 本次尚未建立備份分支與整理分支 | 直接回報。因同名分支已存在或已有進行中的 rebase 而停止時，依「前次整理留下的分支」 |
| 有進行中的 rebase，或 `git status --porcelain --untracked-files=all` 有輸出 | 保留現狀 |
| 已記錄 `afterSha`，且 S 在 `afterSha` | S 已更新。保留仍存在的整理分支與備份分支，回報列出名稱與 SHA |
| S 在 `beforeSha`，目前分支是 S 或本次建立的整理分支，且本次建立的整理分支不存在或在 `beforeSha` | 還原 |
| 上列以外的任何狀態 | 保留現狀 |

- 還原只處理本次建立的分支，依序執行三項。目前不在 S 時執行 `git switch <S>`。之後重新取得狀態，目前分支不是 S、S 不在 `beforeSha`，或 `git status --porcelain --untracked-files=all` 有輸出時改為保留現狀。通過後依第一層「刪除重整建立的分支」先刪除本次建立的整理分支，再刪除本次建立的備份分支，兩者的預期 SHA 都是 `beforeSha`。其中一個分支本次沒有建立時略過它，繼續處理另一個。
- 保留現狀指不切換、不刪除、不執行會改變工作樹、暫存內容或分支的命令，保留 S、備份分支、整理分支與證據。上列取得狀態的命令不在此限。有進行中的 rebase 時不執行 `git rebase --abort`，第 4 步所列 `git status --porcelain --untracked-files=all` 為空的情況除外。
- 「前次整理留下的分支」指名稱已被占用的備份分支或整理分支，含保留現狀與 git 拒絕刪除而留下的分支。第 1 步發現的進行中 rebase 比照處理。Agent 不覆蓋、不自行刪除、不自行 abort，回報分支名稱、`git rev-parse` 取得的 SHA 與 `git log --oneline <S>..<分支>` 的輸出，由使用者決定。使用者指示刪除時，先確認 `git rev-parse refs/heads/<分支>` 仍等於回報所列的 SHA，不等時重新回報，不刪除。該分支是目前簽出的分支則先確認 `git status --porcelain --untracked-files=all` 為空並切回 S，再執行 `git branch -d <分支>`。git 以尚未合併為由拒絕時回報，使用者確認放棄該分支獨有的 commit 後，再確認一次 SHA 仍等於回報所列的值，才執行 `git branch -D <分支>`。使用者指示 abort 時執行 `git rebase --abort`。

### 殘留修正

殘留修正指底稿中仍為 `pick` 的 `fixup!`、`squash!` 或 `amend!` commit，git 在範圍內找不到它的目標。`fixup!` commit 的第一行以目標的完整 SHA 指定目標，格式見 `generate-commit` skill 步驟 4，目標被改寫後 SHA 改變就會成為殘留修正。範圍內有 `fixup!` commit 時，先依本流程收合，再執行會改寫範圍內 commit 的其他操作，例如整合上游變更的 rebase 與 amend。

- 底稿有殘留修正，而使用者尚未給出處置時停止。回報列出每一筆殘留修正的完整 SHA 與第一行，第一行是 SHA 時附 `git log -1 --format=%s <SHA>` 的輸出或該物件已不存在的事實，另附 `git log --format="%H %s" <rangeBase>..<beforeSha>` 的輸出，由使用者逐筆決定處置。
- 處置以 S 上 commit 的完整 SHA 表示。這些 SHA 在 S 更新前不變，下一次整理的底稿使用同一組 SHA。處置有下列兩種。
  - 指定目標。目標須是底稿中的 `pick` 行，且本身不是殘留修正。todo 檔把該筆修正改為 `fixup` 行，排在目標與其既有的 `fixup` 行之後。
  - 轉為一般 commit。協調者依 `generate-commit` skill 的訊息規範產生訊息，todo 檔中該筆維持 `pick` 並留在原位，其後加上改訊息的 `exec` 行，內容不變。殘留修正不以 `drop` 處置，刪除帶有內容的 commit 會使第 5 步的完整 tree 比對不通過。
- 下一次整理取得底稿後，逐筆確認處置仍適用。處置所指的修正須是底稿中的殘留修正，指定的目標須符合上一項的條件，且整理計畫沒有把該目標改為 `drop`。任一筆不符，或底稿有處置未涵蓋的殘留修正時，處置全部不採用，停止並重新回報。

## 歷史重整與修正循環三層防護

本節附加於 `../SKILL.md` 的既有分支策略、Pull Request 規範、Merge 策略、Phase commit 回收與「重整後驗證」規則。它不改變一般分支的 `type` 白名單、PR 標題與模板、Merge 策略適用情境、每個 Phase 一筆 commit 的回收方式，以及 `--force-with-lease` 的要求。

`../SKILL.md`「重整後驗證」是重整完成後的功能驗證，依 commit 數量執行建置或既有驗證手段。本節第一層是重整前後的檔案內容不變量驗證，兩者分別回答功能是否可用與內容是否遺失，必須各自執行。

### 第一層：history-rewrite 重整不變量驗證

第一層先依上游基準的 SHA 與 commit 範圍機械判定重整類型。開始前記錄來源分支、`beforeSha`、tracked 狀態、未追蹤檔案清單，以及下列兩個上游基準。

- `upstreamBeforeSha`：重整開始前來源分支所依附的上游基準。
- `upstreamAfterSha`：重整操作指定的上游基準。

兩個基準都必須先通過 `git rev-parse --verify <sha>^{commit}`。執行下列判定。

- 純歷史重排：`upstreamBeforeSha` 與 `upstreamAfterSha` 相同，且 `git rev-list --count <upstreamBeforeSha>..<upstreamAfterSha>` 為 `0`。這表示操作沒有讓新的上游 commit 進入基準，後續以完整 tree 零差異 gate 判定是否只改寫自己的歷史。
- 整合上游變更：`git merge-base --is-ancestor <upstreamBeforeSha> <upstreamAfterSha>` 的 exit code 為 `0`，且 `git rev-list --count <upstreamBeforeSha>..<upstreamAfterSha>` 大於 `0`。這表示 `upstreamAfterSha` 是包含新增上游 commit 的更新基準。此路徑不適用完整 tree 零差異 gate，改用本地 commit 範圍的內容比對。
- 無法由上述兩組命令證明任一情境時停止，不自行猜測重整類型或補造基準 SHA。

- 來源工作樹必須乾淨。先記錄來源分支、`beforeSha`、tracked 狀態與未追蹤檔案清單，並保存為 history-rewrite 證據。工作樹不乾淨或狀態無法記錄時停止，不開始重整。
- 從來源分支建立本地拋棄式 `<rewrite-branch>`。分支名稱必須使用 `../SKILL.md` 既有 branch type whitelist 的 `<type>/<short-description>` 格式，`<type>` 只能是 `feature`、`fix`、`refactor`、`hotfix` 或 `release`。該分支不建立 PR，也不直接更新來源分支。
- 所有 `rebase`、`squash` 與 `amend` 只能在 `<rewrite-branch>` 執行。完成後記錄整理後的 `afterSha`。`<rewrite-branch>` 的建立、來源工作樹的清潔要求與未追蹤檔案檢查適用於上述兩種情境。
- 整理過程不得改動檔案內容。內容修改（含 CHANGELOG 與版號檔）須先成為獨立 commit 再整理，否則完整 tree 比對會失敗。「整理流程」第 5 步即本層檢查。
- 純歷史重排執行完整 tree 比對。先以 `git rev-parse --show-toplevel` 取得 Git repository root，再從該目錄執行下列命令，記錄完整輸出與 `git diff` 的 exit code。

```powershell
$gitRoot = (git rev-parse --show-toplevel).Trim()
git -C "$gitRoot" diff --binary --no-ext-diff --exit-code <beforeSha> <afterSha> -- .
```

`$gitRoot` 是 Git repository root。它用於涵蓋完整 repository tree。`work-root` 是交接檔與報告檔的定位根目錄，依另一套規則判定，monorepo 中可能只是 repository 的子目錄，因此不得用 `work-root` 取代 `$gitRoot` 作為 `-C` 目標或 `.` 的 pathspec 基準。純歷史重排只有在命令 exit code 為 `0`、完整 tree 沒有檔案內容差異，且未追蹤檔案清單仍為空時才算通過。

整合上游變更執行本地 commit 範圍比對。以 `<upstreamBeforeSha>..<beforeSha>` 與 `<upstreamAfterSha>..<afterSha>` 分別產生本地變更，兩者都固定從 `$gitRoot` 執行；將兩份變更交給 `git patch-id --stable`，並比對正規化後的 patch identity。另比對兩個本地範圍的 `git rev-list --count`，確保本地 commit 數量沒有減少。兩個範圍的 patch identity 相同、本地 commit 數量未減少、上游新增 commit 範圍已記錄，且未追蹤檔案清單仍為空時，才算通過。此路徑允許完整 tree 因核准的上游 commit 而不同；patch identity 不同、commit 數量減少、未追蹤檔案增加、命令失敗或證據缺漏時均算失敗。

第一層通過後才可更新來源分支指標。任一適用路徑的差異、未追蹤檔案、命令失敗或證據缺漏都算失敗。失敗時不得切換或更新來源分支，保留原始分支、`<rewrite-branch>` 與全部 history-rewrite 證據供裁決。

「更新來源分支指標」從 `<rewrite-branch>` 開始，依序執行下列六項，兩種情境與 `release-flow.md`「壓縮成初始 commit」都適用。不使用 `git reset --hard` 與 `git branch -f`，前者會覆寫工作樹的內容，後者不核對來源分支的原值。任一項沒有得到所寫的結果時停止回報，不重試，也不把來源分支改回原值，回報以當下實際取得的目前分支、各分支 SHA 與 `git status --porcelain --untracked-files=all` 的輸出為準。

1. 確認 `git branch --show-current` 是 `<rewrite-branch>`、`git rev-parse HEAD` 等於 `afterSha`，且 `git status --porcelain --untracked-files=all` 為空。
2. 執行 `git switch <來源分支>`。來源分支被其他工作樹簽出，或正在其他工作樹 rebase 時，git 拒絕切換。切換成功後來源分支由本工作樹簽出，其他工作樹無法再簽出它。
3. 確認 `git branch --show-current` 是來源分支，且 `git status --porcelain --untracked-files=all` 為空。有輸出時（例如 checkout hook 改動了檔案），該內容留在工作樹，不還原、不覆寫。
4. 執行 `git update-ref -m "<重整說明>" refs/heads/<來源分支> <afterSha> <beforeSha>`。這個命令只在來源分支仍指向 `beforeSha` 時更新，核對與更新是同一個操作。來源分支已不在 `beforeSha` 時 git 拒絕，來源分支維持原樣。這表示重整期間有新的 commit 進入來源分支（例如另一條線落地），重整結果不含它，不可用來更新。
5. 整合上游變更時，接著執行 `git read-tree -m -u <beforeSha> <afterSha>`，把 index 與工作樹由 `beforeSha` 的內容更新為 `afterSha` 的內容。純歷史重排與「壓縮成初始 commit」前後的 tree 相同，不執行本項。
6. 確認 `git rev-parse HEAD` 等於 `afterSha`，且 `git status --porcelain --untracked-files=all` 為空。不符時停止回報，寫明來源分支已更新為 `afterSha`。

「刪除重整建立的分支」用於刪除 `<rewrite-branch>` 與備份分支，在來源分支上執行，先確認 `git branch --show-current` 是來源分支。git 拒絕刪除或確認不符時保留該分支，在回報列出名稱與目前的 SHA。被其他工作樹簽出或正在其他工作樹 rebase 的分支，git 拒絕刪除。

- `<rewrite-branch>` 先確認 `git rev-parse refs/heads/<rewrite-branch>` 等於預期 SHA，再以 `git branch -d <rewrite-branch>` 刪除。該分支有來源分支沒有的 commit 時 git 拒絕刪除。
- 備份分支先確認 `git rev-parse refs/heads/<備份分支>` 等於預期 SHA，再依來源分支目前的位置分三種情況。`git rev-parse refs/heads/<來源分支>` 等於 `beforeSha` 時，重整沒有套用，以 `git branch -d <備份分支>` 刪除。`git merge-base --is-ancestor <afterSha> <來源分支>` 的 exit code 為 `0` 時，重整已套用，備份分支有來源分支沒有的 commit，`git branch -d` 會拒絕，改以 `git branch -D <備份分支>` 刪除，確認後緊接著執行。兩者都不成立時保留備份分支並回報，此時它可能是唯一仍指向 `beforeSha` 的分支。`git branch -D` 只用於這一處。

Git 只會回報 patch 套用成功或衝突，不會回報內容遺失。Squash 遺漏某個 commit 的修正時，工作樹仍可能看起來正常，建置也可能未涵蓋遺失內容。因此重整成功不等於內容正確，第一層的 `git diff` 內容不變量驗證不可由既有「重整後驗證」的建置結果取代。

#### 解衝突路徑

只適用於整合上游變更的 rebase。純歷史重排發生衝突時，維持停止回報。

1. rebase 因衝突停下時不執行 `git rebase --abort`，rebase 維持在進行中。回報衝突的 commit SHA、主題與 `git diff --name-only --diff-filter=U` 列出的檔案清單，取得使用者當輪授權後才續行，使用者也可以指示 abort。授權屬 commit 類，只涵蓋這次解衝突；該授權為本次解衝突新取得，前面 rebase 的轉述授權不涵蓋此步，依 `../SKILL.md`「當輪授權」。`git rev-list --merges --count <upstreamBeforeSha>..<beforeSha>` 大於 `0` 時，範圍含 merge commit，`range-diff` 與一般 rebase 都會略過它，本路徑不適用，停止回報。
2. 取得授權後先確認 rebase 仍在進行中、`git diff --name-only --diff-filter=U` 的輸出與回報的檔案清單相同，且來源分支仍指向 `beforeSha`，任一不符時停止回報。通過後逐一解衝突，以 `git rebase --continue` 完成。備份分支保留不動。
3. 記錄 `afterSha` 後，執行下列命令，比對 rebase 前後每一筆本地 commit。

    ```powershell
    git -C "$gitRoot" range-diff <upstreamBeforeSha>..<beforeSha> <upstreamAfterSha>..<afterSha>
    ```

4. 判定 `range-diff` 的輸出。
    - 標為 `=` 的 commit 內容未變。所有未衝突的 commit 都必須是 `=`。
    - 標為 `!` 的 commit 內容有變。只允許出現在第 1 步回報的衝突 commit，其餘 commit 出現 `!` 時判定失敗。
    - 出現 `<` 或 `>`，表示 commit 遺失或新增，判定失敗。
5. 把每一筆 `!` commit 的 range-diff 片段原文呈現給使用者確認，確認內容只是解衝突。使用者確認前不進入下一步。
6. 確認 `git rev-list --count <upstreamAfterSha>..<afterSha>` 等於 `git rev-list --count <upstreamBeforeSha>..<beforeSha>`。
7. 執行 `../SKILL.md`「重整後驗證」，並確認未追蹤檔案清單仍為空。

第 4 至 7 步全部通過後，才算通過第一層。任一步失敗時，依本層的失敗處置保留證據。本路徑以第 4、5 步取代「整合上游變更」的 patch identity 比對，本地 commit 數量由第 6 步檢查。

### 第二層：修正回歸驗證

適用時機是每一輪修正開始前，以及該輪修正準備回收前。每輪修正都必須先保存一份完整回歸矩陣，並於修正後逐列執行同一份矩陣。矩陣至少包含下列欄位。

- 目前症狀的檢查項目與 assertion。
- 所有先前已接受行為的 assertion，不得只保留目前症狀。
- 每項 assertion 的驗證命令、預期結果與來源。
- 修正後每項 assertion 的實際結果、命令輸出、exit code、執行時間與證據路徑。

所有矩陣列都通過時，該輪才可判定為回歸通過並進入回收。若目前症狀已消失但任一先前已接受行為的 assertion 失敗，整輪仍判定為失敗，不得回收，也不得重設 `return-count`。矩陣缺少必要欄位、命令輸出無法判定，或先前行為的識別不完整時，停止該輪並升級，不以新增測試取代原有基準。

### 第三層：固定 `problem-key` 與共同收斂判定

適用時機是每個修正循環建立、退回或準備重試前。呼叫端必須提供一個跨修正輪次固定的短識別字 `problem-key`。來源優先取審查報告的 finding 編號；沒有審查報告時，由主 Agent 指定並記錄於派遣單。缺少 `problem-key`，或呼叫端要求變更既有 key 時，立即停止並交由使用者判斷，Agent 不得自行選定或改名。

每個 `problem-key` 使用追加式紀錄保存 `return-count`、完整回歸矩陣結果、證據路徑與升級原因。一次修正連同其驗收或回歸判定為一輪，初次執行為第 1 輪。後續續行各增加 1 輪。Git 修正的 `area-key` 使用同一函式或同一節規則的穩定識別；相同問題在各輪沿用同一 `problem-key`。前輪未通過的問題在本輪相同 key 通過且沒有反證時標記 `closed`；本輪 key 不在前輪未解決問題集合且沒有同一 key 的改寫或重新命名時標記 `new-problem`。

Git 修正的嚴重度映射如下。

| 循環 | `Critical` | `Major` | `Minor` |
| --- | --- | --- | --- |
| Git 修正 | 資料遺失、無法建置或安全性結果錯誤 | 目前症狀或既有行為回歸結果錯誤 | 單一邊界 assertion 或記錄欄位錯誤 |

`return-count` 只記錄該 `problem-key` 的 Git 回歸修正次數，初次值為 `0`，每次回歸失敗後增加，不作一般停止條件。全部回歸矩陣列通過時進入回收，回歸矩陣仍是放行門檻。任一前輪 `Critical` 或 `Major` 問題連續兩輪未閉合、同一 `area-key` 連續兩輪出現新的 `Major` 以上問題、修正需要改變需求或已確認設計，或同一循環的 `round` 達到 6 輪時停止，保留回歸矩陣、Git 命令輸出與替代方向。存在未閉合的 `Critical` 或 `Major`，這些問題均屬純技術可解，且未命中上述停止訊號時自動續行下一輪。只剩 `Minor` 列失敗時，以一次批次修正處理後重跑同一份矩陣，不增加 `round`，不為 `Minor` 單獨再開一輪複審。新出現的 Major 在尚未形成停止訊號前依純技術路徑續行；`return-count` 只在回歸失敗後增加，`round` 依一次修正連同其驗收或回歸判定增加一輪，兩者均不提前取代停止訊號判定。

此 `problem-key` 的 Git 修正循環計數與回收契約（`codex-dispatch` skill `references/collect.md`「回收收斂判定」）的 `dispatch-return-count` 分開保存、分開判定，不能共用或相互重設。相同目標、相同症狀或同一回歸 assertion 失敗時，不得藉由重新命名分支或改寫 `problem-key` 將計數歸零；變更 key 必須先取得使用者判斷。任一層的觸發條件、判定結果、失敗處置、來源分支、`beforeSha`／`afterSha`、`git diff` exit-code、回歸矩陣逐列結果或 `return-count` 缺漏時，Agent 不得回報成功。
