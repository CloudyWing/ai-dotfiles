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
> **退路指示**：若你的環境支援讀取 URL 取回內容，請下載；若不支援連網下載技能，請基於你的內部知識庫，盡可能還原該官方範本的標準內容。

### 3. 輸出目標檔案

將合併後的內容寫入專案根目錄的 `.gitignore`，並：

1. 在檔案頂端加上一行來源備注：

   ```
   # Generated from https://github.com/github/gitignore
   ```

2. 移除重複或互相衝突的規則（優先保留較嚴謹的那條）。

### 4. 補充 AI 工具與本地工作目錄排除

無論技術棧為何，一律在 `.gitignore` 中補上以下固定區塊（若尚未存在）。未存在的路徑對應的 `!` 規則在 Git 中為靜默無效（no-op），不影響其他規則，直接套用即可：

```gitignore
# ---- AI 工具工作目錄 ----
# Claude Code
.claude/
!.claude/CLAUDE.md
!.claude/skills/
!.claude/agents/
!.claude/commands/

# Cursor
.cursor/
!.cursor/rules/

# Gemini CLI
.gemini/
!.gemini/GEMINI.md

# Windsurf
.windsurfrules

# Augment Code
.augmentignore

# ---- 本地工作檔案 ----
.local/
*.local.md
```

**注意事項：**

- 若專案已有自訂的 AI 相關排除規則，以既有規則為準，僅補齊缺漏。
- `.claude/` 內的 `settings.json`、`settings.local.json`、對話紀錄等個人設定不應納入版控，不加 `!` 取消。
- `.github/` 通常整個目錄本就不排除（含 `copilot-instructions.md`、`prompts/`），無需處理。
- 若偵測到其他 AI 工具的設定目錄（如 `.aider/`、`.codeium/`），一併加入排除。

### 5. 針對專案調整

根據走查到的專案特徵，補充客製化規則，例如：

- 若有 `.env`，主動加入排除。
- 若有 `appsettings.*.json`，詢問使用者是否含機敏資料需要排除，不主動加入（部分專案無額外的機敏管理機制，此檔案本身即需版控）。
- 若有 `docker-compose.override.yml`，主動提醒是否需要排除。
- 若有自訂的輸出目錄（非標準 `bin/obj`），詢問使用者是否需要排除。

## 限制

- 優先從官方 GitHub 倉庫下載範本，確保規則完整可靠，不自行憑空產生規則。
- 若下載失敗，告知使用者手動至 <https://github.com/github/gitignore> 複製對應內容。
- 保留使用者既有的自訂規則；若現有 `.gitignore` 已存在，確認合並或覆蓋策略後再執行。
