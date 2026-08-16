---
name: ai-context-index
description: '依 AGENTS.md 宣告探索技術棧與既有產物，呼叫宣告工具產生 AI 脈絡索引並寫入 .local/ai-context/。'
audience: agent
policy.allow_implicit_invocation: true
---

# AI 脈絡索引

本 Skill 只認得 `AGENTS.md` 的 `AI-DECLARATIONS` 宣告格式，不內建工具清單，也不以 raw grep 取代已宣告的索引查詢。

## 執行流程

1. 讀取專案根目錄 `AGENTS.md`，確認存在成對的 `AI-DECLARATIONS` 標記。
2. 解析下列宣告鍵：`context-index-query`、`glossary`、`adr`、`context-index`。缺少或格式無效時停止並回報缺件。
3. 探索專案技術棧、現有規範、詞彙表、ADR 與其他已宣告產物，將需要索引的來源交給 `context-index-query` 宣告的工具或命令。
4. 將工具輸出寫入宣告的 `.local/ai-context/` 路徑，至少包含可定位來源檔案的 `index.md` 或工具指定的等價索引檔。
5. 只更新 `AGENTS.md` 的宣告區塊與 `.local/ai-context/` 產物。保留宣告區塊外的專案規範，不修改 `.gitignore`。

## 工具邊界

- 不在本 Skill 內列出或選擇索引工具。工具名稱、命令與輸出格式由專案的 `context-index-query` 宣告提供。
- 宣告工具不存在、命令失敗或輸出無法定位來源時，停止並回報命令、結束碼與缺少的輸出。
- 不把完整程式碼複製進索引；索引只保留技術棧、規範、入口與來源路徑等可定位資訊。

## Git 排除與驗證

- `.local/ai-context/` 永遠由機器層 `git-global-excludes` 排除。先執行 `git check-ignore -q .local/ai-context/` 驗證，失敗時回報排除設定缺件，不把目錄加入專案 `.gitignore`。
- 確認產物位於宣告的路徑，索引內每個來源路徑都能由 `Test-Path` 或對應平台命令確認存在。
- 確認 `AGENTS.md` 仍保留完整 `AI-DECLARATIONS` 區塊，且 `context-index-query` 指向實際可執行的工具或命令。
