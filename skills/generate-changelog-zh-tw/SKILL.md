---
name: generate-changelog-zh-tw
description: 依據 Git 提交紀錄自動產生 CHANGELOG 區段（繁體中文），並支援 MinVer 版本號推進規格。
disable-model-invocation: true
---

# 產生 CHANGELOG（繁體中文）

## 使用方式

```
/generate-changelog-zh-tw [版本號]
```

若未傳入版本號，依 MinVer 規格自動推算下一個版本號（見步驟 1）。

## 執行步驟

### 1. 確認版本號

**已傳入版本號**：直接使用，確認格式符合 `MAJOR.MINOR.PATCH`（可含預發布後綴如 `-preview.1`）。

**未傳入版本號**，依序嘗試以下來源：

1. **從分支名稱推算**：執行 `git branch --show-current` 取得當前分支名稱。
   - 若符合 `release/vX.Y.Z` 或 `hotfix/vX.Y.Z` 格式，擷取版本號（去掉 `v` 前綴），直接使用。
   - 若不符合上述格式，進入下一步。
2. **從 Git Tag 推算**：執行 `git tag --sort=-v:refname | head -1` 取得最新標籤，讀取自上次標籤以來的 commit 類型，依下列規則推算：
   - 有任何 `BREAKING CHANGE` → 升 MAJOR。
   - 有 `feat:` 但無 Breaking Change → 升 MINOR。
   - 僅有 `fix:`、`docs:`、`chore:` 等 → 升 PATCH。
3. **無任何標籤**：詢問使用者初始版本號（預設建議 `0.1.0`）。

### 2. 取得 Commit 紀錄

執行：

```bash
git log [上次標籤]..HEAD --pretty=format:"%H %s" --no-merges
```

若無標籤，改用：

```bash
git log --pretty=format:"%H %s" --no-merges
```

### 3. 過濾與分類 Commit

依 Conventional Commits 類型分類，過濾掉非使用者可見的變更：

| 類型 | CHANGELOG 分類 | 顯示 |
| --- | --- | --- |
| `feat` | New Features | ✅ |
| `fix` | Bug Fixes | ✅ |
| `perf` | Improvements | ✅ |
| `docs` | 文件 | 僅在 commit 標題明確有使用者影響時顯示 |
| `refactor` | - | ❌ 略過 |
| `style` | - | ❌ 略過 |
| `chore` | - | ❌ 略過 |
| `ci` | - | ❌ 略過 |
| `test` | - | ❌ 略過 |

### 4. 產生 CHANGELOG 區段

輸出格式：

```markdown
## v1.2.0 (2026-04-04)

### New Features

- 新增使用者頭像上傳功能，支援 JPG 與 PNG 格式。
- 新增多語言切換 API 端點 `POST /api/locale`。

### Bug Fixes

- 修正訂單金額在特定幣別下計算錯誤的問題。

### Improvements

- 最佳化商品列表查詢，減少 N+1 查詢。

### BREAKING CHANGE

- 移除 `IUserRepository.GetById(int)` 方法，請改用 `GetByIdAsync(Guid)`。
```

規則：

- 版本號格式為 `v{MAJOR}.{MINOR}.{PATCH}`，日期格式為 `(YYYY-MM-DD)`，固定使用今日日期。
- 條列項目以命令式動詞開頭（新增、修正、移除、最佳化）。
- 不包含 commit hash。
- 若某分類無條目，略去該標題。

### 5. 寫入 CHANGELOG.md

**已存在 `CHANGELOG.md`**：將新區段插入至第一個 `## v` 標題之前（Append 模式，追加於標頭之後）。

**不存在 `CHANGELOG.md`**：建立新檔，結構如下：

```markdown
# CHANGELOG

[新產生的區段]
```

### 6. 完成確認

輸出產生的版本號與條目數量摘要，告知使用者寫入位置。
