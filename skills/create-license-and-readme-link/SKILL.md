---
name: create-license-and-readme-link
description: 自動判斷專案屬性並推薦合適的開源授權，建立 LICENSE 檔案並將其連結補入 README.md 中。
disable-model-invocation: true
---

# 建立開源授權並更新 README 連結

## 執行步驟

### 1. 判斷專案屬性

讀取以下資訊以了解專案性質：

- `README.md`（若存在）：查看用途描述、技術棧
- `*.csproj`、`package.json`、`pyproject.toml` 等專案檔：確認語言與框架
- 是否已有 `LICENSE` 或 `LICENSE.md` 檔案（若已存在，詢問使用者是否要取代）

### 2. 掃描相依性授權相容性

在推薦授權前，掃描以下檔案取得主要相依套件清單：

- `package.json` → `dependencies`、`peerDependencies`
- `*.csproj` → `<PackageReference>`
- `requirements.txt`、`pyproject.toml` → 套件清單
- `go.mod` → `require` 區塊

若清單中出現採用 **GPL-2.0**、**GPL-3.0** 或 **AGPL-3.0** 授權的套件，在推薦授權前明確告知使用者：

- 相依套件名稱與其授權
- 採用 GPL/AGPL 相依套件對專案授權選擇的限制（若選擇 MIT/Apache 等寬鬆授權，需注意 GPL 的「傳染性」是否適用於你的使用情境）
- 若使用者不確定，建議諮詢法律顧問

若無 GPL/AGPL 相依套件，略過此步驟，直接進入授權推薦。

### 3. 推薦授權

依下列準則推薦，並向使用者確認後再執行：

| 情境 | 建議授權 |
| --- | --- |
| 函式庫 / SDK，希望被廣泛使用 | MIT |
| 函式庫，希望衍生物也開源 | LGPL-2.1 |
| 應用程式，要求衍生物也開源 | GPL-3.0 |
| 商業友善、保留專利權 | Apache-2.0 |
| 個人作品集或文件 | CC BY 4.0 |
| 完全公眾領域 | Unlicense |

推薦前，以一個引導問題縮小選擇範圍：

**問**：「此專案是否允許他人商業使用或將程式碼嵌入閉源產品？」

- **允許**：推薦 MIT 或 Apache-2.0（視是否需要專利保護而定）。
- **不允許**（要求衍生物開源）：推薦 GPL-3.0 或 AGPL-3.0。
- **不確定**：列出完整表格讓使用者對照選擇。

列出推薦選項（最多 3 個），說明理由，等待使用者選擇。

### 4. 建立 LICENSE 檔案

授權取得策略：

1. **MIT 走本地範本**：若使用者選擇 MIT，優先讀取 `~/.ai-agents/templates/LICENSE.md.template`（含使用者預設姓名），僅替換 `{YEAR}` 為當前年份。不需詢問 fullname。
2. **其他授權走線上來源**：從公開來源取得該授權的標準全文（若 WebFetch 可用）；若無法取得，告知使用者自行複製。替換授權文本中的 `[year]`（填入當前年份）與 `[fullname]`（詢問使用者或從 `git config user.name` 取得）。

- 檔案名稱固定為 `LICENSE.md`，儲存於專案根目錄。
- 編碼：UTF-8 無 BOM。

### 5. 更新 README.md

若 `README.md` 存在：

1. 搜尋是否已有 License 段落或 badge。
2. **已有 badge**：更新 shield URL 與連結。
3. **已有文字連結**：更新連結指向 `LICENSE.md`。
4. **完全沒有**：在 README 末尾加入以下區塊（Merge 模式，融入既有風格）：

   ```markdown
   ## License

   This project is licensed under the [MIT License](LICENSE.md).
   ```

   若 README 以繁體中文撰寫，改用：

   ```markdown
   ## 授權條款

   本專案採用 [MIT 授權條款](LICENSE.md)。
   ```

若 `README.md` 不存在，告知使用者並略過此步驟。

### 6. 完成確認

輸出執行摘要：

- 建立的 `LICENSE` 授權名稱
- README.md 的修改位置（若有）
