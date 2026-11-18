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
| 適用條件 | Git repo，即 `git rev-parse --is-inside-work-tree` 輸出 `true`。非 Git 專案不適用，不詢問、不阻擋 |

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

1. `git rev-parse --verify -q HEAD` 沒有輸出時，repo 還沒有任何 commit，主分支為 `git symbolic-ref --short HEAD` 的輸出。
2. 讀取 `git symbolic-ref --short refs/remotes/origin/HEAD`。命令成功時，去掉 `origin/` 前綴的分支名稱即為主分支。
3. 本機存在 `main` 分支時，主分支為 `main`。
4. 本機存在 `master` 分支時，主分支為 `master`。
5. 以上皆未命中時，停止 commit、啟動 Workflow 與建立分支，回報分支清單並請使用者指定。

第 2 步判定出的分支在本機不存在時，同樣停止上述動作，回報判定結果與 `git branch --list` 的輸出，請使用者決定是否建立對應的本機追蹤分支。

判定結果只用於當次操作，不寫入 `AGENTS.local.md`。執行命令時，以判定出的分支名稱取代命令範例中的 `main`。

## 分支策略

分支決策依 `git-workflow` 註記與已載入的模式檔。分支分類如下。

| 類別 | 命名 | 說明 |
| --- | --- | --- |
| 整合分支 | `trunk` 為主分支（見「主分支判定」）；`release-flow` 為 `release/vX.Y.Z` 或 `hotfix/vX.Y.Z`，尚無版本標籤時為主分支（見 `references/release-flow.md`「初次發佈前」） | 版號符合 `^v[0-9]+\.[0-9]+\.[0-9]+$` |
| 線分支 | `feature/<lineSlug>` | 規則見「線分支與獨立 worktree」 |
| 整理分支 | `refactor/tidy-<來源分支名，斜線改為連字號>` | 即 `references/history-rewrite.md` 第一層的拋棄式 `<rewrite-branch>` |
| 備份分支 | `backup/<來源分支名，斜線改為連字號>-before-tidy-<beforeSha 前 7 碼>` | 規則見「整理流程」 |

### 分支 type whitelist

一般功能分支的 `type` 白名單如下。

- `feature`
- `fix`
- `refactor`
- `hotfix`
- `release`

分支 `type` 與 commit type 分別依各自白名單判定；`feature` 對應 `feat`，其餘分支名稱依語意對應 commit type。

`backup` 是白名單以外的特殊類別，不建立 PR，也不推送。整理分支使用白名單內的 `refactor`，符合 `references/history-rewrite.md` 第一層對 `<rewrite-branch>` 的 type 要求。

### 功能分支命名

**Pattern**: `<type>/<short-description>`

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
2. 決定 worktree 路徑為 `<repo 根目錄的上一層>\<repo 目錄名>.wt\<lineSlug>`。放在 repo 之外，也縮短路徑。
3. 建立分支與 worktree。

    ```powershell
    git worktree add --track -b feature/<lineSlug> "<路徑>" <整合分支>
    ```

    `--track` 讓線分支的 upstream 指向整合分支，`git rev-parse --abbrev-ref feature/<lineSlug>@{upstream}` 可讀回整合分支名稱。
4. 確認本機排除：在新 worktree 執行 `git check-ignore -q .local/ai-sessions`，失敗時停止回報，不寫入任何 `.local` 內容。
5. 複製本機資料到新 worktree：`AGENTS.local.md`、`.local\machine.json`（存在時，派工腳本與其測試讀取帳號登記）、`.local\ai-context\`（存在時）、`.local\ai-sessions\handoff\<lineSlug>\`、`.local\ai-sessions\report\<lineSlug>\`。複製後逐檔比對 SHA-256，不一致時停止，以 `git worktree remove "<路徑>"`（不加 `--force`）移除本次建立的 worktree 並回報。
6. 切換 work-root：該 worktree 根目錄成為本線的 work-root，之後的 `LineContext`、交接檢查點與派遣 `sourceRoot` 都使用新 work-root。主 checkout 的同線目錄保留原樣，不再寫入。
7. 保持線分支不推送。遠端已有同名分支（`git ls-remote --heads origin feature/<lineSlug>` 有輸出）且需要改寫其歷史時，停止並詢問使用者。

### 落地程序

線的這一段工作符合 `rules/claude/20-coordination.md`「授權分類」的落地條件時執行，不需授權。線還有後續工作（例如審查尚未完成）時可留在線分支繼續，待該段完成再落地；落地後的修正直接在整合分支進行，同樣適用落地條件。

1. 線分支範圍內有 `fixup!` 或整理計畫時，可先依「整理流程」整理 `<整合分支>..feature/<lineSlug>`，不需授權。整理也可留到模式檔規定的時點（`trunk` 在 push 前，`release-flow` 在合併前流程），此時略過本步。
2. 從整理後的線分支建立整理分支，在整理分支執行 `git -c rebase.updateRefs=false rebase <整合分支>`，以 `references/history-rewrite.md` 第一層「整合上游變更」路徑驗證，通過後才更新線分支指標。發生衝突時依該檔第一層「解衝突路徑」處理。
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
| Phase commit 回收 | 來源工作樹的未 commit 變更 → 來源分支，依 `design.md` Phase 順序回收 |

- 已推送分支的 rebase 與 force push 依「改寫與 force push 邊界」。
- PR 協作專案 Squash 後的 commit message 使用 PR 標題，不使用自動產生的 commit 清單，且須符合 `generate-commit` skill 的規範。

### Phase commit 回收

Workflow Phase 由 Claude 執行者直接修改來源工作樹，執行者不建立 commit，成果以來源工作樹的未 commit 變更形式存在。Phase commit 以 Phase 為單位回收，一個 Phase 一個 commit。主 Agent 依結案報告「Phase 對照」節記載的逐 Phase 檔案清單分組，重整為每個 Phase 恰有一筆 commit；每筆訊息依 `generate-commit` skill 產生，且符合其 type、subject 與 body 規範。

Developer 回收收下並覆核後，立即依 Phase 順序逐 Phase 暫存指名路徑並建立對應 commit，不等 Reviewer 與需求意圖驗收。來源分支為線分支時不需授權；來源分支為整合分支時 commit 即落地，不需授權，須符合 `rules/claude/20-coordination.md`「授權分類」的落地條件。Reviewer 退回時，修正仍在同一來源工作樹進行，回收並覆核後由 `generate-commit` 步驟 4 建立 `fixup!` commit；每個 Phase 一筆 commit 的最終形態由落地或 push 前的「整理流程」收合 `fixup!` 達成。

Phase commit 回收步驟依 Phase 順序將各 Phase 的差異套用至來源分支並建立對應 commit。來源分支是符合 `git-workflow` 註記模式的線分支或整合分支，分支前置見 `workflow-orchestration` skill「自動推進鏈」第 1 步。保留每個 Phase 的獨立語意，不在此步驟把全部 Phase squash 成單一 commit，也不以 merge commit 取代 Phase commit。回收完成並通過驗證後，依模式檔規定的整理時機執行「整理流程」。每筆 commit 必須通過可用性驗證，且回收後歷史整理必須通過 `references/history-rewrite.md` 第一層零差異 gate。回收衝突時停止並保留證據。

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

整理（歸併、刪除或重排 commit）的 `rangeBase` 對照表與 8 步程序見 `references/history-rewrite.md`，整理、rebase、squash 與 `fixup!` 收合前讀取。

## 當輪授權

當輪授權指使用者在執行端當輪的直接回覆，或符合 `rules/claude/20-coordination.md`「授權期限」的協調 Session 轉述。轉述授權的判定依 `rules/claude/20-coordination.md`「授權期限」。

| 動作 | 可否轉述 | 條件 |
| --- | --- | --- |
| 線分支本機 commit | 可 | 限 `feature/<lineSlug>` 的本機 commit。本身不需授權，需求摘要另有授權要求時才需轉述 |
| 線分支 rebase | 可 | 須先建備份分支，一遇衝突就停下；解衝突須新的當輪授權，使用者直接回覆或新的轉述皆可，rebase 的轉述授權不涵蓋解衝突 |
| 線分支的整理、整合分支上整理範圍全部尚未推送時的整理、整合分支落地（含 `merge --ff-only` 與直接在整合分支的 commit） | 不適用 | 本身不需授權。整理範圍是否全部尚未推送，依 `references/history-rewrite.md`「整理流程」第 1 步判定，含已推送的 commit 時依「改寫與 force push 邊界」。落地須符合 `rules/claude/20-coordination.md`「授權分類」的落地條件。需求摘要另有授權要求時，使用者須在執行端當輪直接授權 |
| 發佈（`release/*`、`hotfix/*` 合併進 `main` 與打標籤，含初次發佈）、push、force push | 不可 | 使用者須在執行端當輪直接授權 |

「commit 類」授權中，只有線分支本機 commit 適用轉述。

### push 授權請求

- 每次 push 都取得使用者當輪直接授權，授權不跨輪、不跨分支。
- 請求附變更摘要（待推送範圍的 commit 清單與各自主題）、審查結論（審查者、輪數、結論與報告路徑；依 Reviewer 必發清單不需審查時附不發理由）、驗證結果（建置與測試命令及其結果；專案沒有可執行的測試或驗證手段時明寫「無可執行測試」），以及整理結果（各 commit 的去向；沒有整理時註明）。
- 提出請求前須完成的審查與整理依模式檔。

## 改寫與 force push 邊界

| 分支 | 已推送後可否改寫 | 條件 |
| --- | --- | --- |
| 未合併的 `release/*`、`hotfix/*` | 可 | `--force-with-lease`，每次取得當輪授權 |
| `trunk` 的 `main` | 需使用者當輪授權 | 授權涵蓋該次改寫與 force push，每次單獨取得 |
| `release-flow` 的 `main` | 不改寫 | 修正已發佈內容以新 commit 處理 |
| 尚無版本標籤且未推送的 `release-flow` 的 `main` | 不適用（未推送） | 初次發佈時依 `references/release-flow.md`「壓縮成初始 commit」整理為單一 commit，隨初次發佈的當輪授權執行，不涉及 force push |
| 已合併的 `release/*`、`hotfix/*` | 不改寫 | 版本由標籤保存 |
| 線分支、整理分支、備份分支 | 不推送 | 已被推送時停止並詢問使用者 |
| 缺少或無效註記時的 `main` | 不改寫 | 視同 `release-flow` |

- 每次 force push 都需使用者在執行端當輪直接授權，協調 Session 轉述不適用。一般 push 的授權不涵蓋 force push，授權不跨輪、不跨分支。
- 一律使用 `git push --force-with-lease=<ref>:<遠端預期 SHA> origin <branch>`，不使用 `--force`。
- 授權請求固定格式為 `[force push 授權] 分支=<名稱>；遠端目前=<sha>；改寫後=<sha>；備份=<備份分支或 SHA>；理由=<一句話>`。
- lease 失敗（遠端已被更新）時停止回報，不重試，也不改用 `--force`。

## 歷史重整與修正循環三層防護

歷史重整的第一層（重整不變量驗證，含「解衝突路徑」）、第二層（修正回歸驗證）與第三層（固定 `problem-key` 與共同收斂判定）見 `references/history-rewrite.md`，rebase、squash、解衝突與修正循環前讀取。

## 版本標籤

- 使用 Semantic Versioning：`vMAJOR.MINOR.PATCH`（如 `v1.2.3`）。
- 若專案使用 MinVer 或其他自動版本工具，遵循該工具的標籤格式。
- `trunk` 不打標籤。`release-flow` 使用 annotated tag，打在 `main` 的 merge commit；第一個版本標籤打在初次發佈的 commit，細節見 `references/release-flow.md`「初次發佈前」與「合併前流程」。

## Git Hooks 慣例

- Hook 腳本納入版控（放在 `scripts/` 或 `.githooks/` 目錄），透過 `git config core.hooksPath` 或 Husky 等工具統一。
- **不跳過 Hook**：禁止在一般開發流程中使用 `--no-verify`。

## .gitignore 維護

專案初始化時以 `generate-gitignore-by-techstack` skill 產生對應技術棧的 `.gitignore`，新增工具或框架時及時補充排除規則。

範本取不到時，先告知使用者，再使用最小內建清單 `bin/`、`obj/`、`node_modules/`、`.env` 與 `.local/`。
Fallback 完成後不停止派工。
