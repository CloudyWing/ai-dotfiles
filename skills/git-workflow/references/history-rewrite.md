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

1. 確認前置條件：`git status --porcelain` 為空；內容修改（程式、文件、CHANGELOG、版號檔）已全部成為獨立 commit；記錄 `beforeSha` 與 `rangeBase`。範圍內沒有 `fixup!` commit 也沒有整理計畫時結束，不建立備份分支。`git rev-list --count <rangeBase>..<S>` 與 `git rev-list --count <rangeBase>..<S> --not --remotes` 相等時，範圍內全部是尚未推送的 commit，整理不需授權；不相等時範圍含已推送的 commit，屬已推送分支的歷史改寫，先依 `../SKILL.md`「改寫與 force push 邊界」取得當輪授權。
2. 建立備份：`git branch backup/<名稱> <beforeSha>`。同名分支已存在時停止，不覆蓋。
3. 從 S 建立整理分支 `refactor/tidy-<名稱>`。
4. 在整理分支執行整理，一律加上 `-c rebase.updateRefs=false`，不使用互動編輯器。
    - 只收合 `fixup!` 時執行 `git -c sequence.editor=true -c rebase.updateRefs=false rebase -i --autosquash <rangeBase>`。
    - 需要刪除、重排或改訊息時，先寫出 todo 檔（只用 `pick`、`fixup`、`drop`，改訊息以 `exec git commit --amend -F <訊息檔>` 表示），再執行 `git -c "sequence.editor=cp '<todo 檔絕對路徑>'" -c rebase.updateRefs=false rebase -i <rangeBase>` 套用該檔。各 commit 的去向寫入回報。
    - 以 `-c sequence.editor=...` 指定 todo 編輯器，不使用 `GIT_SEQUENCE_EDITOR` 環境變數前綴。`sequence.editor` 的值由 git 交給其內建 shell 執行，同一行命令在 PowerShell 與 Git Bash 都可直接使用。
    - 衝突時執行 `git rebase --abort`，保留備份分支與整理分支，停止回報。整合上游變更的 rebase 可依第一層「解衝突路徑」續行。
5. 執行第一層零差異 gate。`rangeBase` 未前進時屬純歷史重排，`afterSha` 與 `beforeSha` 的完整 tree 必須相同。
6. 執行 `../SKILL.md`「重整後驗證」。
7. 更新來源分支：切回 S，執行 `git reset --hard <afterSha>`。第 5 步已證明 tree 相同且工作樹乾淨，工作樹檔案不會改變。
8. 清理：刪除整理分支；第 5、6 步通過後以 `git branch -D` 刪除備份分支。任一步失敗時不切換、不刪除，保留 S、備份分支、整理分支與證據。

- 整理不得改動檔案內容，需要修改內容時先成為獨立 commit，再整理。
- 不使用 `--no-verify`。
- 歸併計畫（例如把修正收進原 commit）不影響 tree，零差異 gate 偵測不到歸併錯誤。主 Agent 在回報列出計畫，並在 push 或發佈的授權請求中呈現給使用者。

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

第一層通過後才可切回來源分支並更新來源分支指標。任一適用路徑的差異、未追蹤檔案、命令失敗或證據缺漏都算失敗。失敗時不得切換或更新來源分支，保留原始分支、`<rewrite-branch>` 與全部 history-rewrite 證據供裁決。

Git 只會回報 patch 套用成功或衝突，不會回報內容遺失。Squash 遺漏某個 commit 的修正時，工作樹仍可能看起來正常，建置也可能未涵蓋遺失內容。因此重整成功不等於內容正確，第一層的 `git diff` 內容不變量驗證不可由既有「重整後驗證」的建置結果取代。

#### 解衝突路徑

只適用於整合上游變更的 rebase。純歷史重排發生衝突時，維持停止回報。

1. 第一次 rebase 衝突時執行 `git rebase --abort`，回報衝突的 commit SHA、主題與檔案清單，取得使用者當輪授權後才續行。授權屬 commit 類，只涵蓋這次解衝突；該授權為本次解衝突新取得，前面 rebase 的轉述授權不涵蓋此步，依 `../SKILL.md`「當輪授權」。`git rev-list --merges --count <upstreamBeforeSha>..<beforeSha>` 大於 `0` 時，範圍含 merge commit，`range-diff` 與一般 rebase 都會略過它，本路徑不適用，停止回報。
2. 在整理分支重新執行同一個 rebase，逐一解衝突後以 `git rebase --continue` 完成。備份分支保留不動。
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
