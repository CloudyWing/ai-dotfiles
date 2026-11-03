---
name: git-workflow
description: 'Git 分支策略與協作規範：依專案 AGENTS.local.md 的 git-workflow 註記載入 trunk 或 release-flow 模式，涵蓋分支命名、線分支 worktree、commit 整理、合併與標籤、改寫與 force push 邊界、PR 模板與 Git Hooks 慣例。討論或執行分支管理、commit 整理、合併、push 與版本發布時套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Git 分支策略與協作規範

rebase 改寫歷史風險、衝突解決步驟等通用知識不在此複述，本文件只收專案慣例。

## git-workflow 註記與模式載入

專案的 git 流程依專案根目錄 `AGENTS.local.md` 的 `AI-PROFILE` 區塊中 `git-workflow` 鍵決定。區塊格式、解析、詢問與寫入由 `ai-profile` skill 的共用機制承擔，鍵登錄表也位於該 skill，本節只規定 `git-workflow` 鍵的值與載入行為。

| 欄位 | 內容 |
| --- | --- |
| 合法值 | `trunk`、`release-flow`，大小寫須完全一致 |
| 適用條件 | Git repo，即 `git rev-parse --is-inside-work-tree` 輸出 `true`。非 Git 專案不適用，不詢問、不阻擋 |
| 阻擋範圍 | commit、啟動 Workflow、建立分支 |
| 缺少時處置 | 依共用機制詢問，附「推薦值推導」的推薦答案 |

### 模式載入

| 註記值 | 載入的檔案 |
| --- | --- |
| `trunk` | 本文件，加上 `references/trunk.md` |
| `release-flow` | 本文件，加上 `references/release-flow.md` |
| 缺少 | 阻擋範圍內的動作依共用機制詢問；阻擋範圍以外的討論不載入模式檔 |
| 未知值 | 依共用機制視為無效註記，停止阻擋範圍內的動作並指出錯誤位置，不載入模式檔，不猜測，不修改檔案 |

### 阻擋動作的檢查位置

| 阻擋動作 | 檢查位置 | 通過後 |
| --- | --- | --- |
| commit | `generate-commit` 步驟 0 | 依模式檔「commit 落點」檢查 |
| 啟動 Workflow | `workflow-orchestration`「自動推進鏈」第 1 步「分支前置」 | 依「線分支與獨立 worktree」決定直接在整合分支或開線分支 |
| 建立分支 | 本節 | 執行 `git branch <新分支>`、`git switch -c`、`git worktree add -b` 等建立分支的命令前先確認註記有效，再依「分支策略」命名 |

Workflow 派工前，`codex-dispatch` 另行核對註記與分支符合性，該檢查只讀不建，不建立或切換分支。

缺少註記時，阻擋範圍以外的工作照常進行。整理、rebase、push 與 force push 不屬阻擋範圍，缺少註記時只套用本文件的通用規則（備份、零差異 gate、`--force-with-lease`、當輪授權），不套用任一模式檔；「改寫與 force push 邊界」中 `main` 的處置視同 `release-flow`。

### 推薦值推導

共用機制詢問時，依下列順序產生推薦答案。推薦值須經使用者確認才寫入註記。

1. `project-kind` 為 `library` 時推薦 `release-flow`，為 `sample` 時推薦 `trunk`。
2. `project-kind` 為 `application` 或缺少時，讀取現有分支與最近 20 個合併記錄。

    ```powershell
    git branch --all --format="%(refname:short)"
    git log --merges -n 20 --pretty=format:"%h %s"
    ```

3. 存在 `release/*` 或 `hotfix/*` 分支，或合併記錄含 `Merge branch 'release/` 或 `Merge branch 'hotfix/` 時推薦 `release-flow`，其餘推薦 `trunk`。

### 主分支判定

本文件與模式檔中的 `main` 一律指 repo 的主分支，`origin/main` 指主分支的遠端追蹤分支。主分支依下列順序判定，命中即停止：

1. 讀取 `git symbolic-ref --short refs/remotes/origin/HEAD`。命令成功時，去掉 `origin/` 前綴的分支名稱即為主分支。
2. 本機存在 `main` 分支時，主分支為 `main`。
3. 本機存在 `master` 分支時，主分支為 `master`。
4. 以上皆未命中時，停止 commit、啟動 Workflow 與建立分支，回報分支清單並請使用者指定。

第 1 步判定出的分支在本機不存在時，同樣停止上述動作，回報判定結果與 `git branch --list` 的輸出，請使用者決定是否建立對應的本機追蹤分支。

判定結果只用於當次操作，不寫入 `AGENTS.local.md`。執行命令時，以判定出的分支名稱取代命令範例中的 `main`。

## 分支策略

分支決策依 `git-workflow` 註記與已載入的模式檔。分支分類如下。

| 類別 | 命名 | 說明 |
| --- | --- | --- |
| 整合分支 | `trunk` 為主分支（見「主分支判定」）；`release-flow` 為 `release/vX.Y.Z` 或 `hotfix/vX.Y.Z` | 版號符合 `^v[0-9]+\.[0-9]+\.[0-9]+$` |
| 線分支 | `feature/<lineSlug>` | 規則見「線分支與獨立 worktree」 |
| 整理分支 | `refactor/tidy-<來源分支名，斜線改為連字號>` | 即第一層的拋棄式 `<rewrite-branch>` |
| 備份分支 | `backup/<來源分支名，斜線改為連字號>-before-tidy-<beforeSha 前 7 碼>` | 規則見「整理流程」 |
| 派遣分支 | `dispatch/<時間戳>-<用途>` | 規則見「dispatch 分支」 |

### 分支 type whitelist

一般功能分支的 `type` 白名單如下。

- `feature`
- `fix`
- `refactor`
- `hotfix`
- `release`

分支 `type` 與 commit type 分別依各自白名單判定；`feature` 對應 `feat`，其餘分支名稱依語意對應 commit type。

`dispatch` 與 `backup` 是白名單以外的特殊類別，不建立 PR，也不推送。整理分支使用白名單內的 `refactor`，符合第一層對 `<rewrite-branch>` 的 type 要求。

### dispatch 分支

`dispatch` 是 Agent 派工使用的拋棄式分支類別，識別字使用 UTC 時間戳與用途 slug，例如 `dispatch/20260827-171238-design`。時間戳在此類別中用於區分派工實例，分支名稱不受一般日期識別限制。`dispatch` 分支不建立 PR，也不回收到主線歷史；派遣結果依 `codex-dispatch` 的 worktree 回收契約處理。

### 功能分支命名

**Pattern**: `<type>/<short-description>`

```text
feature/user-registration
fix/order-total-calculation
refactor/extract-email-service
```

- `short-description` 使用 kebab-case（小寫字母，連字號分隔）。
- 一般功能分支以用途型 `type` 與 kebab-case 描述命名；個人名稱與日期不作為一般功能分支的唯一識別。
- 線分支命名為 `feature/<lineSlug>`，`lineSlug` 本身為 kebab-case，符合本規則。

## 線分支與獨立 worktree

### 適用判定

| 工作 | 落點 |
| --- | --- |
| Workflow 線，`design.md` 的 Phase 數 >= 2 | 線分支 `feature/<lineSlug>` 加獨立 worktree |
| Workflow 線，Phase 數 = 1；資源派遣；Maintainer 單筆修正；使用者明確要求的單筆小改 | 直接在整合分支 commit |
| 使用者明確指定另一種做法 | 依使用者指定，並記錄於回報 |

Phase 數 >= 2 的 Workflow 線在 Design 驗收後依交接檢查點開新 Session，因此視為跨 Session 的線。

### 建立程序

由 `workflow-orchestration`「自動推進鏈」第 1 步執行。

1. 確認前置條件：註記有效；目前分支是整合分支（整合分支名稱見模式檔）；`git rev-parse --verify -q refs/heads/feature/<lineSlug>` 沒有輸出；目標路徑不存在。線分支已存在且 `git worktree list --porcelain` 列出對應 worktree 時沿用，視為續行；線分支存在但沒有 worktree 時停止回報。
2. 決定 worktree 路徑為 `<repo 根目錄的上一層>\<repo 目錄名>.wt\<lineSlug>`。放在 repo 之外，與 `.local\ai-sessions\worktrees\` 的派遣 worktree 分開，也縮短路徑。
3. 建立分支與 worktree。

    ```powershell
    git worktree add --track -b feature/<lineSlug> "<路徑>" <整合分支>
    ```

    `--track` 讓線分支的 upstream 指向整合分支，`git rev-parse --abbrev-ref feature/<lineSlug>@{upstream}` 可讀回整合分支名稱。
4. 確認本機排除：在新 worktree 執行 `git check-ignore -q .local/ai-sessions`，失敗時停止回報，不寫入任何 `.local` 內容。
5. 複製本機資料到新 worktree：`AGENTS.local.md`、`.local\ai-context\`（存在時）、`.local\ai-sessions\handoff\<lineSlug>\`、`.local\ai-sessions\report\<lineSlug>\`。複製後逐檔比對 SHA-256，不一致時停止，以 `git worktree remove "<路徑>"`（不加 `--force`）移除本次建立的 worktree 並回報。
6. 切換 work-root：該 worktree 根目錄成為本線的 work-root，之後的 `LineContext`、交接檢查點與派遣 `sourceRoot` 都使用新 work-root。主 checkout 的同線目錄保留原樣，不再寫入。
7. 保持線分支不推送。遠端已有同名分支（`git ls-remote --heads origin feature/<lineSlug>` 有輸出）且需要改寫其歷史時，停止並詢問使用者。

### 落地程序

在 Accept 之後、取得使用者當輪授權後執行。落地授權屬 commit 類。

1. 依「整理流程」整理 `<整合分支>..feature/<lineSlug>`。
2. 從整理後的線分支建立整理分支，在整理分支執行 `git -c rebase.updateRefs=false rebase <整合分支>`，以第一層「整合上游變更」路徑驗證，通過後才更新線分支指標。
3. 在主 checkout 的整合分支執行 `git merge --ff-only feature/<lineSlug>`。整合分支已前進而被拒時，重做第 2 步一次；仍被拒時停止回報。主 checkout 含其他線未 commit 的改動時不 stash、不還原，git 因檔案重疊拒絕時停止回報。
4. 歸還本機資料：將 worktree 的 `.local\ai-sessions\handoff\<lineSlug>\` 與 `.local\ai-sessions\report\<lineSlug>\` 複製回主 checkout 同路徑。覆蓋前先將主 checkout 的原目錄移到 `.local\ai-sessions\backups\<時間戳>\` 並附一行 `manifest.txt`，複製後逐檔比對 SHA-256。另比對兩邊的 `AGENTS.local.md`，有差異時列出差異，由使用者決定是否帶回。
5. 執行 `git worktree remove "<路徑>"`（不加 `--force`，有未提交內容時 git 會拒絕，此時停止回報），再執行 `git branch -d feature/<lineSlug>`。

## Pull Request 規範

本節為使用 PR 協作的專案適用的通用章節。`trunk` 與 `release-flow` 不使用 PR。

- PR 標題與 commit message 的 Header 格式一致：`<type>([scope]): <subject>`。
- **一個 PR 一個目的**：不在同一個 PR 中混合功能新增與重構；變更檔案數建議不超過 20 個，過大應拆分。
- 進行中的工作使用 Draft PR 標示。

### PR 描述模板

```markdown
## Summary
- 變更摘要（1-3 個重點）

## Test Plan
- [ ] 測試項目 1
- [ ] 測試項目 2
```

## Merge 策略

| 策略 | 適用情境 |
| --- | --- |
| 線分支落地（`--ff-only`） | `feature/<lineSlug>` 整理並 rebase 後落地到整合分支，兩種模式共用 |
| Merge Commit（`--no-ff`） | `release-flow` 的 `release/vX.Y.Z`、`hotfix/vX.Y.Z` 併入 `main`，訊息固定為 `Merge branch '<分支>'` |
| Rebase | 線分支或 release 分支同步整合分支或 `main`；已推送的分支依「改寫與 force push 邊界」 |
| Squash Merge | 僅限 PR 協作專案 |
| Phase commit 回收 | dispatch worktree → 來源分支，依 `design.md` Phase 順序回收 |

- 已推送分支的 rebase 與 force push 依「改寫與 force push 邊界」。
- PR 協作專案 Squash 後的 commit message 使用 PR 標題，不使用自動產生的 commit 清單，且須符合 `generate-commit` skill 的規範。

### Phase commit 回收

Codex 端不建立 commit，Workflow `Developer` 的成果以 dispatch worktree 的工作區差異形式存在。Phase commit 以 Phase 為單位回收，一個 Phase 一個 commit。主 Agent 依結案報告「Phase 對照」節記載的逐 Phase 檔案清單分組，重整為每個 Phase 恰有一筆 commit；每筆訊息依 `generate-commit` skill 產生，且符合其 type、subject 與 body 規範。

Workflow Developer 收下時先將成果套回來源工作樹，維持未 commit 的工作區變更，不建立 Phase commit，並保留 dispatch worktree。只有在 Reviewer 收下、需求意圖驗收完成、結案報告產出且使用者授權 commit 後，才依 Phase 順序將各 Phase 的差異套用至來源分支並建立對應 commit。Phase commit 回收完成且驗證通過後，才可移除 Workflow Developer dispatch worktree。Reviewer 退回時，續行沿用保留的同一 dispatch worktree 與 thread。

Phase commit 回收步驟依 Phase 順序將各 Phase 的差異套用至來源分支並建立對應 commit。來源分支是已通過 `codex-dispatch` 分支符合性檢查的線分支或整合分支。保留每個 Phase 的獨立語意，不在此步驟把全部 Phase squash 成單一 commit，也不以 merge commit 取代 Phase commit。回收完成並通過驗證後，依模式檔規定的整理時機執行「整理流程」。每筆 commit 必須通過可用性驗證，且回收後歷史整理必須通過第一層零差異 gate。回收衝突時停止並保留 worktree 與證據。

### 分組 commit 與 pre-commit hook 的先後順序

pre-commit hook 會重新產生索引或格式化產物並自行 `git add`。分組 commit 時，被 hook 自動暫存的檔案若仍帶有未暫存的變更，會被掃進當下這一筆 commit，破壞分組邊界。

先確認本 repo 的 pre-commit hook 會自動暫存哪些檔案。含這些檔案的那一組最先 commit。無法把它們集中在同一組時，改為先單獨 commit hook 產物，再依序建立其餘分組。

判定方式為讀取 hook 腳本中的 `git add` 目標，或於第一筆 commit 後以 `git show --stat` 確認實際納入的檔案與預期分組一致。

### 重整後驗證

Rebase 或解衝突完成後，先確認重整後的 Phase commit 數量與專案可用的建置命令。

- 重整後 commit 數不超過 10 且存在可執行建置命令時，逐 commit 執行建置並記錄每筆結果。
- 重整後 commit 數超過 10 時，只驗證最終 commit，並在回報中說明未逐個驗證與原因。
- 沒有建置命令時，改用既有驗證手段；專案也沒有既有驗證手段時，在回報中明寫略過與原因。

## 整理流程

整理把來源分支 S 的 commit 歸併、刪除或重排，不改變檔案內容。觸發時機與整理範圍由模式檔規定。整理範圍的下界 `rangeBase` 依 S 決定。

| S | `rangeBase` |
| --- | --- |
| `trunk` 的 `main` | `origin/main`；不存在時範圍為空，跳過整理 |
| `release/*`、`hotfix/*` | `main` |
| `feature/<lineSlug>` | 該分支的 upstream，即整合分支 |

1. 確認前置條件：`git status --porcelain` 為空；內容修改（程式、文件、CHANGELOG、版號檔）已全部成為獨立 commit；記錄 `beforeSha` 與 `rangeBase`。範圍內沒有 `fixup!` commit 也沒有整理計畫時結束，不建立備份分支。
2. 建立備份：`git branch backup/<名稱> <beforeSha>`。同名分支已存在時停止，不覆蓋。
3. 從 S 建立整理分支 `refactor/tidy-<名稱>`。
4. 在整理分支執行整理，一律加上 `-c rebase.updateRefs=false`，不使用互動編輯器。
    - 只收合 `fixup!` 時執行 `git -c sequence.editor=true -c rebase.updateRefs=false rebase -i --autosquash <rangeBase>`。
    - 需要刪除、重排或改訊息時，先寫出 todo 檔（只用 `pick`、`fixup`、`drop`，改訊息以 `exec git commit --amend -F <訊息檔>` 表示），再執行 `git -c "sequence.editor=cp '<todo 檔絕對路徑>'" -c rebase.updateRefs=false rebase -i <rangeBase>` 套用該檔。各 commit 的去向寫入回報。
    - 以 `-c sequence.editor=...` 指定 todo 編輯器，不使用 `GIT_SEQUENCE_EDITOR` 環境變數前綴。`sequence.editor` 的值由 git 交給其內建 shell 執行，同一行命令在 PowerShell 與 Git Bash 都可直接使用。
    - 衝突時執行 `git rebase --abort`，保留備份分支與整理分支，停止回報。
5. 執行第一層零差異 gate。`rangeBase` 未前進時屬純歷史重排，`afterSha` 與 `beforeSha` 的完整 tree 必須相同。
6. 執行「重整後驗證」。
7. 更新來源分支：切回 S，執行 `git reset --hard <afterSha>`。第 5 步已證明 tree 相同且工作樹乾淨，工作樹檔案不會改變。
8. 清理：刪除整理分支；第 5、6 步通過後以 `git branch -D` 刪除備份分支。任一步失敗時不切換、不刪除，保留 S、備份分支、整理分支與證據。

- 整理不得改動檔案內容，需要修改內容時先成為獨立 commit，再整理。
- 不使用 `--no-verify`。
- 歸併計畫（例如把修正收進原 commit）不影響 tree，零差異 gate 偵測不到歸併錯誤。主 Agent 在回報列出計畫，並在 push 或合併的授權請求中呈現給使用者。

## 改寫與 force push 邊界

| 分支 | 已推送後可否改寫 | 條件 |
| --- | --- | --- |
| 未合併的 `release/*`、`hotfix/*` | 可 | `--force-with-lease`，每次取得當輪授權 |
| `trunk` 的 `main` | 需使用者當輪授權 | 授權涵蓋該次改寫與 force push，每次單獨取得 |
| `release-flow` 的 `main` | 不改寫 | 修正已發佈內容以新 commit 處理 |
| 已合併的 `release/*`、`hotfix/*` | 不改寫 | 版本由標籤保存 |
| 線分支、整理分支、備份分支 | 不推送 | 已被推送時停止並詢問使用者 |
| 缺少或無效註記時的 `main` | 不改寫 | 視同 `release-flow` |

- 每次 force push 都需使用者當輪授權。一般 push 的授權不涵蓋 force push，授權不跨輪、不跨分支。
- 一律使用 `git push --force-with-lease=<ref>:<遠端預期 SHA> origin <branch>`，不使用 `--force`。
- 授權請求固定格式為 `[force push 授權] 分支=<名稱>；遠端目前=<sha>；改寫後=<sha>；備份=<備份分支或 SHA>；理由=<一句話>`。
- lease 失敗（遠端已被更新）時停止回報，不重試，也不改用 `--force`。

## 歷史重整與修正循環三層防護

本節附加於既有分支策略、Pull Request 規範、Merge 策略、Phase commit 回收與「重整後驗證」規則。它不改變一般分支的 `type` 白名單、PR 標題與模板、Merge 策略適用情境、每個 Phase 一筆 commit 的回收方式，以及 `--force-with-lease` 的要求。

「重整後驗證」是重整完成後的功能驗證，依 commit 數量執行建置或既有驗證手段。本節第一層是重整前後的檔案內容不變量驗證，兩者分別回答功能是否可用與內容是否遺失，必須各自執行。

### 第一層：history-rewrite 重整不變量驗證

第一層先依上游基準的 SHA 與 commit 範圍機械判定重整類型。開始前記錄來源分支、`beforeSha`、tracked 狀態、未追蹤檔案清單，以及下列兩個上游基準。

- `upstreamBeforeSha`：重整開始前來源分支所依附的上游基準。
- `upstreamAfterSha`：重整操作指定的上游基準。

兩個基準都必須先通過 `git rev-parse --verify <sha>^{commit}`。執行下列判定。

- 純歷史重排：`upstreamBeforeSha` 與 `upstreamAfterSha` 相同，且 `git rev-list --count <upstreamBeforeSha>..<upstreamAfterSha>` 為 `0`。這表示操作沒有讓新的上游 commit 進入基準，後續以完整 tree 零差異 gate 判定是否只改寫自己的歷史。
- 整合上游變更：`git merge-base --is-ancestor <upstreamBeforeSha> <upstreamAfterSha>` 的 exit code 為 `0`，且 `git rev-list --count <upstreamBeforeSha>..<upstreamAfterSha>` 大於 `0`。這表示 `upstreamAfterSha` 是包含新增上游 commit 的更新基準。此路徑不適用完整 tree 零差異 gate，改用本地 commit 範圍的內容比對。
- 無法由上述兩組命令證明任一情境時停止，不自行猜測重整類型或補造基準 SHA。

- 來源工作樹必須乾淨。先記錄來源分支、`beforeSha`、tracked 狀態與未追蹤檔案清單，並保存為 history-rewrite 證據。工作樹不乾淨或狀態無法記錄時停止，不開始重整。
- 從來源分支建立本地拋棄式 `<rewrite-branch>`。分支名稱必須使用既有 branch type whitelist 的 `<type>/<short-description>` 格式，`<type>` 只能是 `feature`、`fix`、`refactor`、`hotfix` 或 `release`；`dispatch/*` 不符合本層的拋棄式重整分支要求。該分支不建立 PR，也不直接更新來源分支。
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

`return-count` 只記錄該 `problem-key` 的 Git 回歸修正次數，初次值為 `0`，每次回歸失敗後增加，不作一般停止條件。全部回歸矩陣列通過時進入回收。前輪問題連續兩輪未閉合、同一 `area-key` 連續兩輪出現新的 `Major` 以上問題、修正需要改變需求或已確認設計，或 `round` 達到 6 輪時停止，保留回歸矩陣、Git 命令輸出與替代方向。所有問題均屬純技術可解、未命中上述停止訊號，且前輪問題已閉合或本輪新問題只有 `Minor` 時自動續行。新出現的 Major 在尚未形成停止訊號前依純技術路徑續行；`return-count` 只在回歸失敗後增加，`round` 依一次修正連同其驗收或回歸判定增加一輪，兩者均不提前取代停止訊號判定。

此 `problem-key` 的 Git 修正循環計數與 `codex-dispatch` 回收契約的 `dispatch-return-count` 分開保存、分開判定，不能共用或相互重設。相同目標、相同症狀或同一回歸 assertion 失敗時，不得藉由重新命名分支或改寫 `problem-key` 將計數歸零；變更 key 必須先取得使用者判斷。任一層的觸發條件、判定結果、失敗處置、來源分支、`beforeSha`／`afterSha`、`git diff` exit-code、回歸矩陣逐列結果或 `return-count` 缺漏時，Agent 不得回報成功。

## 版本標籤

- 使用 Semantic Versioning：`vMAJOR.MINOR.PATCH`（如 `v1.2.3`）。
- 若專案使用 MinVer 或其他自動版本工具，遵循該工具的標籤格式。
- `trunk` 不打標籤。`release-flow` 使用 annotated tag，打在 `main` 的 merge commit，細節見 `references/release-flow.md`。

## Git Hooks 慣例

| Hook | 用途 |
| --- | --- |
| `pre-commit` | Lint 檢查、格式化（如 `dotnet format`） |
| `commit-msg` | 驗證 commit message 格式 |
| `pre-push` | 執行測試（避免推送破壞主線的程式碼） |

- Hook 腳本納入版控（放在 `scripts/` 或 `.githooks/` 目錄），透過 `git config core.hooksPath` 或 Husky 等工具統一。
- **不跳過 Hook**：禁止在一般開發流程中使用 `--no-verify`。

## .gitignore 維護

專案初始化時以 `generate-gitignore-by-techstack` skill 產生對應技術棧的 `.gitignore`，新增工具或框架時及時補充排除規則。

範本取不到時，先告知使用者，再使用最小內建清單 `bin/`、`obj/`、`node_modules/`、`.env` 與 `.local/`。
Fallback 完成後不停止派工。

`.gitignore` 應排除編譯輸出、機密檔案（`.env`、`*.pfx`）、IDE 個人設定與作業系統暫存檔，不將上述內容納入版控。
