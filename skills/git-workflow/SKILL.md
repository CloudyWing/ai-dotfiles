---
name: git-workflow
description: 'Git 分支策略與協作規範：分支命名、PR 模板、Merge 策略選用與 Git Hooks 慣例。當討論分支管理、PR 流程或版本發布時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Git 分支策略與協作規範

rebase 改寫歷史風險、衝突解決步驟等通用知識不在此複述，本文件只收專案慣例。

## 分支策略

分支策略先依實際 repository 狀態判定。主 Agent 先讀取現有分支名稱，再讀取最近 20 個合併記錄。

```powershell
git branch --all --format="%(refname:short)"
git log --merges -n 20 --pretty=format:"%h %s"
```

能從分支名稱與合併記錄推得既有慣例時沿用該慣例。資料不足以推得慣例時，使用 `main` 加 feature branches。文件不再宣告採用特定 flow，分支決策以命令輸出與 repository 現況為依據。

### 分支 type whitelist

一般功能分支的 `type` 白名單如下。

- `feature`
- `fix`
- `refactor`
- `hotfix`
- `release`

分支 `type` 與 commit type 分別依各自白名單判定；`feature` 對應 `feat`，其餘分支名稱依語意對應 commit type。

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

## Pull Request 規範

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
| Squash Merge | 功能分支 → main/develop，保持主線歷史乾淨 |
| Merge Commit | release → main, hotfix → main，保留完整合併記錄 |
| Rebase | 功能分支同步上游變更，僅限本地未推送的 commit |
| Phase commit 回收 | dispatch worktree → 來源分支，依 `design.md` Phase 重整後按 Phase 順序回收 |

- Squash 後的 commit message 使用 PR 標題，不使用自動產生的 commit 清單，且須符合 `generate-commit` skill 的規範。
- Rebase 後需 force push 至遠端功能分支時，使用 `--force-with-lease`（非 `--force`）。

### Phase commit 回收

Codex 端不建立 commit，Workflow `Developer` 的成果以 dispatch worktree 的工作區差異形式存在。Phase commit 以 Phase 為單位回收，一個 Phase 一個 commit。主 Agent 依結案報告「Phase 對照」節記載的逐 Phase 檔案清單分組，重整為每個 Phase 恰有一筆 commit；每筆訊息依 `generate-commit` skill 產生，且符合其 type、subject 與 body 規範。

Workflow Developer 收下時先將成果套回來源工作樹，維持未 commit 的工作區變更，不建立 Phase commit，並保留 dispatch worktree。只有在 Reviewer 收下、需求意圖驗收完成、結案報告產出且使用者授權 commit 後，才依 Phase 順序將各 Phase 的差異套用至來源分支並建立對應 commit。Phase commit 回收完成且驗證通過後，才可移除 Workflow Developer dispatch worktree。Reviewer 退回時，續行沿用保留的同一 dispatch worktree 與 thread。

Phase commit 回收步驟依 Phase 順序將各 Phase 的差異套用至來源分支並建立對應 commit。保留每個 Phase 的獨立語意，不在此步驟把全部 Phase squash 成單一 commit，也不以 merge commit 取代 Phase commit。回收完成後可在 `rewrite-branch` 依成果整理並 squash。每筆 commit 必須通過可用性驗證，且回收後歷史整理必須通過第一層零差異 gate。回收衝突時停止並保留 worktree 與證據。

### 分組 commit 與 pre-commit hook 的先後順序

pre-commit hook 會重新產生索引或格式化產物並自行 `git add`。分組 commit 時，被 hook 自動暫存的檔案若仍帶有未暫存的變更，會被掃進當下這一筆 commit，破壞分組邊界。

先確認本 repo 的 pre-commit hook 會自動暫存哪些檔案。含這些檔案的那一組最先 commit。無法把它們集中在同一組時，改為先單獨 commit hook 產物，再依序建立其餘分組。

判定方式為讀取 hook 腳本中的 `git add` 目標，或於第一筆 commit 後以 `git show --stat` 確認實際納入的檔案與預期分組一致。

### 重整後驗證

Rebase 或解衝突完成後，先確認重整後的 Phase commit 數量與專案可用的建置命令。

- 重整後 commit 數不超過 10 且存在可執行建置命令時，逐 commit 執行建置並記錄每筆結果。
- 重整後 commit 數超過 10 時，只驗證最終 commit，並在回報中說明未逐個驗證與原因。
- 沒有建置命令時，改用既有驗證手段；專案也沒有既有驗證手段時，在回報中明寫略過與原因。

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

- 使用 Semantic Versioning：`vMAJOR.MINOR.PATCH`（如 `v1.2.3`），標籤僅在 `main` 分支建立。
- 若專案使用 MinVer 或其他自動版本工具，遵循該工具的標籤格式。

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
