---
name: ai-context-index
description: 'Use when an agent needs to create or update a project AI context index from the tools declared in AGENTS.md.'
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

## 產物索引欄位

專案的 .local/ai-context/index.md 使用固定五欄表格，每列記錄一個產物或互相關聯的 artifact set：

| 工具 | 產物路徑 | 重產命令 | 來源指紋 | 產生時間 |
| --- | --- | --- | --- | --- |

- 工具填正式名稱。
- 產物路徑填相對專案根目錄的主檔路徑；Summary 分檔時填 entry 路徑，並將連結分檔視為同一組。
- 重產命令填可重現產物的命令。不適用時填「不適用」；連線字串只可使用環境變數名稱或 stdin 模式。
- 三支既有 `.csx` 與 graphify 的重產命令一律填 `pwsh -NoProfile -File "<AiAgentsRoot>/scripts/Ensure-AiContextArtifacts.ps1" -ProjectRoot "<ProjectRoot>" -ToolName <ToolName>`；將 `<AiAgentsRoot>` 與 `<ProjectRoot>` 換成實際絕對路徑，`<ToolName>` 換成該列工具名稱。
- 重產命令欄是索引唯一允許且必須含實際絕對使用者路徑的欄位；其他索引欄位與來源指紋 manifest 不得含絕對使用者路徑或秘密值。
- 來源指紋使用 sha256:v1: 加 64 位小寫十六進位；不適用時填「不適用」。
- 產生時間使用成功產生或檢查時的 UTC ISO 8601 時間；不適用時填「不適用」。
- 五欄皆不得留空，工具與產物路徑不得重複。
- 儲存格內的直線字元 `|` 寫成 `\|`；解析時還原為 `|`。儲存格內的反斜線寫成 `\\`，解析時還原為單一反斜線。

## 共用產物 ensure

三支 Roslyn exporter 與 graphify 由 Ensure-AiContextArtifacts.ps1 唯一負責來源指紋、no-op 判斷、產物提升及索引登記。呼叫格式為：

pwsh -NoProfile -File "<AiAgentsRoot>/scripts/Ensure-AiContextArtifacts.ps1" -ProjectRoot "<ProjectRoot>" -ToolName <ToolName>

三個 Export ToolName 的 ProjectRoot 根目錄必須包含唯一一個 .sln 或 .slnx。graphify 直接以 ProjectRoot 為輸入。ToolName 限定為 Export-ApiSurface、Export-TypeHierarchy、Export-ProjectGraph、graphify。三支 exporter 維持原有 Markdown 輸出路徑，並接受額外暫存輸出目標。graphify 的 --out 指向 .local/ai-context/graphify/，其輸出位於該目錄下的 graphify-out/。

相同指紋且所有必需產物完整時回報「未變更」，不得呼叫產生器或改動產物與索引列時間。指紋不同、索引列缺漏或產物不完整時，先寫同目錄 nonce 暫存，再檢查輸出完整性；確認完整後才提升產物與更新索引。更新失敗時還原舊產物與舊索引列。

來源指紋使用 UTF-8、LF、相對路徑正規斜線與 ordinal 排序。ApiSurface 與 TypeHierarchy 納入 Solution、專案清單及 exporter 實際讀取的 C# 檔案 bytes；ProjectGraph 納入 Solution、已解析的專案檔 bytes 與 ProjectReference 關係。這三個 Roslyn exporter 的來源集合不得按敏感檔名過濾。graphify 納入排除目錄之外的一般檔案相對路徑與內容雜湊、graphify 版本及正規化命令參數；列舉時在任何內容讀取前、所有深度排除檔名 `.env`、`.env.*`、`*.pfx`、`*.pem`、`*.key` 與 `secrets.*`。每筆指紋另納入 exporter 與共用 Ensure 腳本的內容雜湊。各工具均排除 .git、.local、bin、obj、dist、out、build、target、node_modules 與 __pycache__。

## 工具邊界

- 不在本 Skill 內列出或選擇索引工具。工具名稱、命令與輸出格式由專案的 `context-index-query` 宣告提供。
- 宣告工具不存在、命令失敗或輸出無法定位來源時，停止並回報命令、結束碼與缺少的輸出。
- 不把完整程式碼複製進索引；索引只保留技術棧、規範、入口與來源路徑等可定位資訊。

## Git 排除與驗證

- `.local/ai-context/` 永遠由機器層 `git-global-excludes` 排除。先執行 `git check-ignore -q .local/ai-context/` 驗證，失敗時回報排除設定缺件，不把目錄加入專案 `.gitignore`。
- 確認產物位於宣告的路徑，索引內每個來源路徑都能由 `Test-Path` 或對應平台命令確認存在。
- 確認 `AGENTS.md` 仍保留完整 `AI-DECLARATIONS` 區塊，且 `context-index-query` 指向實際可執行的工具或命令。
