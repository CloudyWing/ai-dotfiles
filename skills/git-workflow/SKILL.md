---
name: git-workflow
description: 'Git 分支策略與協作規範：分支命名、PR 模板、Merge 策略選用與 Git Hooks 慣例。當討論分支管理、PR 流程或版本發布時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Git 分支策略與協作規範

rebase 改寫歷史風險、衝突解決步驟等通用知識不在此複述，本文件只收專案慣例。

## 分支策略

- **小型專案 / 持續部署**：採用 GitHub Flow（僅 `main` + feature branches）。
- **有明確版本週期的專案**：採用 Git Flow（`main` + `develop` + feature/release/hotfix）。
- 遵循**專案既有慣例**，不主動切換分支策略。

### 功能分支命名

**Pattern**: `<type>/<short-description>`

```text
feature/user-registration
fix/order-total-calculation
refactor/extract-email-service
```

- `type` 與 commit 的 type whitelist 一致（`feature` 對應 `feat`，其餘相同）。
- `short-description` 使用 kebab-case（小寫字母，連字號分隔）。
- **禁止**使用個人名稱或日期作為分支名（如 `wing-0403`、`test-branch`）。

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

- Squash 後的 commit message 使用 PR 標題，不使用自動產生的 commit 清單，且須符合 `generate-commit` skill 的規範。
- Rebase 後需 force push 至遠端功能分支時，使用 `--force-with-lease`（非 `--force`）。

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

- 專案初始化時以 `generate-gitignore-by-techstack` skill 產生對應技術棧的 `.gitignore`，新增工具或框架時及時補充排除規則。
- **禁止**將編譯輸出、機密檔案（`.env`、`*.pfx`）、IDE 個人設定、作業系統暫存檔納入版控。
