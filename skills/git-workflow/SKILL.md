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

Workflow `Implement` 的 dispatch worktree 回收只涵蓋 `baseSha..dispatchHead` 內的派工機械 commit。Phase commit 以 Phase 為單位回收，一個 Phase 一個 commit。主 Agent 依 `design.md` 的 Phase 分組變更，重整為每個 Phase 恰有一筆 commit；每筆訊息依 `generate-commit` skill 產生，且符合其 type、subject 與 body 規範。

回收時依 Phase 順序將各 Phase 的差異套用至來源分支並建立對應 commit。保留每個 Phase 的獨立語意，不將全部 Phase squash 成單一 commit，也不以 merge commit 取代 Phase commit。dispatch 的機械 commit 不逐條搬移，回收衝突時停止並保留 worktree 與證據。

### 重整後驗證

Rebase 或解衝突完成後，先確認重整後的 Phase commit 數量與專案可用的建置命令。

- 重整後 commit 數不超過 10 且存在可執行建置命令時，逐 commit 執行建置並記錄每筆結果。
- 重整後 commit 數超過 10 時，只驗證最終 commit，並在回報中說明未逐個驗證與原因。
- 沒有建置命令時，改用既有驗證手段；專案也沒有既有驗證手段時，在回報中明寫略過與原因。

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
