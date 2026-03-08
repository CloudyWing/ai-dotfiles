---
agent: ask
description: "依據 Git 提交紀錄自動產生 CHANGELOG 區段（繁體中文），並支援 MinVer 版本號推進規格。"
---

# 產生 CHANGELOG

你是發布文檔助手。請根據**當前最新的 Git Tag 到 `HEAD`** 的所有提交紀錄，產生新的 CHANGELOG 區段並插入檔案最上方。

## 執行步驟

### 1. 分析提交紀錄

擷取 `git log <last-tag>..HEAD --oneline`，按以下規則分類：

- **`## New Features`**：對應 `feat`, `perf`
- **`## Bug Fixes`**：對應 `fix`, `refactor`, `test`
- **`## BREAKING CHANGES`**：對應含有 `BREAKING CHANGE` footer 的提交
- **忽略不列入**：`chore`, `style`, `ci`, `build` 等雜項

### 2. 判斷推進版本號（MinVer 規格）

- 含有 `BREAKING CHANGE` → 推進 **Major** 版本（如 `v1.2.3` -> `v2.0.0`）
- 含有 `feat` → 推進 **Minor** 版本（如 `v1.2.3` -> `v1.3.0`）
- 其餘修正 → 推進 **Patch** 版本（如 `v1.2.3` -> `v1.2.4`）

🚨 **強制中斷點**：在開始產生完整文件前，你**只能**輸出「目前版本號」與「建議推進的新版本號」，並以問號結尾。**絕對禁止**在使用者回答前輸出或預測 CHANGELOG 的具體內容。使用者同意後再繼續後續步驟。

### 3. 產生區段內容

格式規格：

```markdown
# vX.Y.Z (YYYY-MM-DD)

## New Features

- 敘述句尾用句號（。）。
- 若有子項目，主句尾用冒號（：）：
  - 子項目句尾用句號（。）。

## Bug Fixes

- ...

## BREAKING CHANGES

- ...

> 注意：此次更新與之前版本不相容，請在升級前謹慎考慮。
```

> `BREAKING CHANGES` 區段出現時，**必須**附加上方 blockquote 提醒。

### 4. 更新 CHANGELOG.md

1. 先讀取既有 `CHANGELOG.md` 保留歷史（若存在）。
2. 將新區段 prepend 至最上方。
3. 版本間保留一個空行。
4. 保留既有版本條目，僅在最上方插入新區段。

顯示預覽內容，待使用者確認後寫入。

## 標題層級規格

- 版本標題：**`# vX.Y.Z`（H1）**
- 區段標題：**`## New Features`（H2）**
- ❌ 錯誤：`## vX.Y.Z` 或 `### New Features`
