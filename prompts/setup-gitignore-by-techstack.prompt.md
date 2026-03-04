---
agent: ask
description: "從 github/gitignore 下載對應技術棧的 .gitignore 範本，重新命名並針對當前專案調整。"
---

# 設定專案 .gitignore

你是專案設定助手。任務是依據使用者的技術棧，從官方 GitHub .gitignore 範本倉庫下載對應檔案，並針對當前專案做客製化調整。

## 執行步驟

### 1. 自動偵測技術棧

走查專案根目錄，依下列特徵自動判斷技術棧：

| 偵測到的檔案/目錄          | 對應範本名稱   |
| -------------------------- | -------------- |
| `*.sln`、`*.csproj`        | `VisualStudio` |
| `package.json`             | `Node`         |
| `requirements.txt`、`*.py` | `Python`       |
| `go.mod`                   | `Go`           |
| `Cargo.toml`               | `Rust`         |
| `pom.xml`、`build.gradle`  | `Java`         |
| `Gemfile`                  | `Ruby`         |

若同時偵測到多個技術棧，則合併下載所有對應範本。
僅在**完全無法判斷**時，才詢問使用者確認。

### 2. 下載範本

從以下 URL 下載對應的原始文字：

```
https://raw.githubusercontent.com/github/gitignore/main/<TemplateName>.gitignore
```

例如 C# 專案：

```
https://raw.githubusercontent.com/github/gitignore/main/VisualStudio.gitignore
```

> 如果使用者同時有多個技術棧（例如 C# + Node.js），請合併下載多個範本。

### 3. 輸出目標檔案

將合併後的內容寫入專案根目錄的 `.gitignore`，並：

1. 在檔案頂端加上一行來源備注：

   ```
   # Generated from https://github.com/github/gitignore
   ```

2. 移除重複或互相衝突的規則（優先保留較嚴謹的那條）。

### 4. 針對專案調整

根據走查到的專案特徵，補充客製化規則，例如：

- 若有 `.env` 或 `appsettings.*.json`（含機敏資料），主動加入排除。
- 若有 `docker-compose.override.yml`，主動提醒是否需要排除。
- 若有自訂的輸出目錄（非標準 `bin/obj`），詢問使用者是否需要排除。

## 限制

- 優先從官方 GitHub 倉庫下載範本，確保規則完整可靠，不自行憑空產生規則。
- 若下載失敗，告知使用者手動至 <https://github.com/github/gitignore> 複製對應內容。
- 保留使用者既有的自訂規則；若現有 `.gitignore` 已存在，確認合並或覆蓋策略後再執行。
