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

### 2. 推薦授權

依下列準則推薦，並向使用者確認後再執行：

| 情境 | 建議授權 |
| --- | --- |
| 函式庫 / SDK，希望被廣泛使用 | MIT |
| 函式庫，希望衍生物也開源 | LGPL-2.1 |
| 應用程式，要求衍生物也開源 | GPL-3.0 |
| 商業友善、保留專利權 | Apache-2.0 |
| 個人作品集或文件 | CC BY 4.0 |
| 完全公眾領域 | Unlicense |

列出推薦選項（最多 3 個），說明理由，等待使用者選擇。

### 3. 建立 LICENSE 檔案

- 使用使用者選定的授權。
- 從公開來源取得該授權的標準全文（若 WebFetch 可用）；若無法取得，告知使用者自行複製。
- 替換授權文本中的 `[year]`（填入當前年份）與 `[fullname]`（詢問使用者或從 `git config user.name` 取得）。
- 檔案名稱固定為 `LICENSE`（無副檔名），儲存於專案根目錄。
- 編碼：UTF-8 無 BOM。

### 4. 更新 README.md

若 `README.md` 存在：

1. 搜尋是否已有 License 段落或 badge。
2. **已有 badge**：更新 shield URL 與連結。
3. **已有文字連結**：更新連結指向 `LICENSE`。
4. **完全沒有**：在 README 末尾加入以下區塊（Merge 模式，融入既有風格）：

   ```markdown
   ## License

   This project is licensed under the [MIT License](LICENSE).
   ```

   若 README 以繁體中文撰寫，改用：

   ```markdown
   ## 授權條款

   本專案採用 [MIT 授權條款](LICENSE)。
   ```

若 `README.md` 不存在，告知使用者並略過此步驟。

### 5. 完成確認

輸出執行摘要：

- 建立的 `LICENSE` 授權名稱
- README.md 的修改位置（若有）
