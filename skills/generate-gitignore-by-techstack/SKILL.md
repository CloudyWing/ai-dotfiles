---
name: generate-gitignore-by-techstack
description: 從 github/gitignore 下載對應技術棧的 .gitignore 範本，合併並針對當前專案調整。
disable-model-invocation: true
---

# 產生或更新 .gitignore

## 執行步驟

### 1. 偵測技術棧

掃描專案根目錄，識別使用的語言與工具（與 `generate-editorconfig-by-techstack` 採用相同偵測邏輯）：

| 偵測依據 | 對應 gitignore 範本 |
| --- | --- |
| `*.csproj`、`*.sln` | `VisualStudio.gitignore` |
| `package.json` | `Node.gitignore` |
| `*.vue` | （已含於 Node） |
| `*.py`、`pyproject.toml` | `Python.gitignore` |
| `go.mod` | `Go.gitignore` |
| `Dockerfile` | `community/Golang/Go.gitignore`（或直接加 docker 排除段） |
| JetBrains IDE（`.idea/`） | `JetBrains.gitignore` |
| VS Code（`.vscode/`） | `VisualStudioCode.gitignore` |

### 2. 讀取既有 .gitignore

若 `.gitignore` 已存在：

1. 完整讀取現有內容。
2. 識別使用者已自訂的區段（通常以空行或註解分隔）。
3. 後續步驟以 Merge 模式補齊缺少的規則，不移除使用者已有的設定。

若不存在，從空白開始建立。

### 3. 下載範本

使用 WebFetch 從以下 URL 下載對應的官方範本（若 WebFetch 不可用，略過此步驟並告知使用者）：

```
https://raw.githubusercontent.com/github/gitignore/main/{TemplateName}.gitignore
```

範例：

- `https://raw.githubusercontent.com/github/gitignore/main/VisualStudio.gitignore`
- `https://raw.githubusercontent.com/github/gitignore/main/Node.gitignore`
- `https://raw.githubusercontent.com/github/gitignore/main/Python.gitignore`

### 4. 合併與調整

1. 將各範本內容依技術棧分組，以 `# ===== [技術名稱] =====` 作為段落標頭。
2. 去除各範本之間的重複規則。
3. 加入以下專案慣用規則（若尚未存在）：

   ```gitignore
   # ===== 本機環境 =====
   CONTEXT.local.md
   .env
   .env.*
   !.env.example
   ```

4. 若偵測到 Windows 環境，加入：

   ```gitignore
   # ===== Windows =====
   Thumbs.db
   Desktop.ini
   ```

### 5. 寫入結果

- 直接寫入 `.gitignore`。
- 若已存在，將新段落追加至末尾（避免打亂既有結構）。

### 6. 完成確認

輸出：

- 下載的範本清單（含來源 URL）
- 新增的自訂規則段落
- 若有任何範本無法下載，列出手動取得的建議連結
