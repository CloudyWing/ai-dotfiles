---
name: git-workflow
description: 'Git 分支策略與協作規範：分支命名、PR 流程、Merge 策略與版本標籤管理。'
---

# Git 分支策略與協作規範

當使用者詢問 Git 分支管理、Pull Request 流程或版本發布策略時，請自動套用以下規範。

## 分支策略

### 主要分支

| 分支 | 用途 | 保護規則 |
| --- | --- | --- |
| `main` | 正式發布版本，隨時可部署 | 禁止直接推送，僅透過 PR 合併 |
| `develop` | 開發整合分支（若採用 Git Flow） | 禁止直接推送，僅透過 PR 合併 |

- **小型專案 / 持續部署**：採用 GitHub Flow（僅 `main` + feature branches）。
- **有明確版本週期的專案**：採用 Git Flow（`main` + `develop` + feature/release/hotfix）。
- 遵循**專案既有慣例**，不主動切換分支策略。

### 功能分支命名

**Pattern**: `<type>/<short-description>`

```text
feature/user-registration
fix/order-total-calculation
refactor/extract-email-service
docs/api-endpoint-guide
chore/upgrade-dotnet-10
hotfix/null-reference-on-checkout
```

- `type` 與 commit 的 type whitelist 一致（`feature` 對應 `feat`，其餘相同）。
- `short-description` 使用 kebab-case（小寫字母，連字號分隔）。
- **禁止**使用個人名稱或日期作為分支名（如 `wing-0403`、`test-branch`）。

## Pull Request 規範

### PR 標題

與 commit message 的 Header 格式一致：`<type>([scope]): <subject>`

### PR 描述模板

```markdown
## Summary
- 變更摘要（1-3 個重點）

## Test Plan
- [ ] 測試項目 1
- [ ] 測試項目 2
```

### PR 原則

- **一個 PR 一個目的**：不在同一個 PR 中混合功能新增與重構。
- **保持 PR 精簡**：單一 PR 的變更檔案數建議不超過 20 個。過大的 PR 應拆分為多個漸進式 PR。
- **Draft PR**：進行中的工作使用 Draft PR 標示，方便團隊掌握進度但不觸發正式審查。
- **自我審查**：提交 PR 前，先自行在 diff 介面走查一次，清除除錯程式碼、多餘的 `console.log` 或註解。

## Merge 策略

| 策略 | 適用情境 | 說明 |
| --- | --- | --- |
| Squash Merge | 功能分支 → main/develop | 多個 commit 壓縮為一個，保持主線歷史乾淨 |
| Merge Commit | release → main, hotfix → main | 保留完整合併記錄 |
| Rebase | 功能分支同步上游變更 | 保持線性歷史，僅限本地未推送的 commit |

### Squash Merge 規範

- Squash 後的 commit message 使用 PR 標題，不使用自動產生的 commit 清單。
- 確認 Squash 後的 commit message 符合 `generate-commit` skill 的規範。

### Rebase 安全規則

- **禁止**對已推送至遠端的 commit 執行 rebase（會改寫歷史，影響其他協作者）。
- 僅在本地功能分支上使用 `git rebase main` 同步上游變更。
- Rebase 完成後需 force push 至遠端功能分支時，使用 `--force-with-lease`（非 `--force`），防止覆蓋他人推送。

## 衝突處理

1. 先確認衝突範圍：`git diff --name-only --diff-filter=U`。
2. 逐一解決衝突，優先在本地解決後推送，避免在 GitHub 介面上解決（無法執行測試）。
3. 衝突解決後，執行完整的建置與測試確認無迴歸。
4. **禁止**直接丟棄他人的變更來解決衝突，必須理解雙方意圖後合併。

## 版本標籤

- 使用 [Semantic Versioning](https://semver.org/)：`vMAJOR.MINOR.PATCH`（如 `v1.2.3`）。
- 標籤僅在 `main` 分支建立。
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

- 專案初始化時產生對應技術棧的 `.gitignore`（參閱 `generate-gitignore-by-techstack` prompt）。
- 新增工具或框架時，及時補充對應的排除規則。
- **禁止**將以下檔案納入版控：
  - 編譯輸出（`bin/`、`obj/`、`dist/`、`node_modules/`）
  - 機密檔案（`.env`、`*.pfx`、`credentials.json`）
  - IDE 個人設定（`.vs/`、`.idea/`、`*.user`）
  - 作業系統暫存（`Thumbs.db`、`.DS_Store`）
