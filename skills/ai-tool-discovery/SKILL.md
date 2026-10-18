---
name: ai-tool-discovery
description: 'Use when the agent is about to explore a project or generate AI support artifacts and needs the local tool inventory or the state and rebuild path of existing .local/ai-context artifacts.'
audience: agent
policy.allow_implicit_invocation: true
---

# AI 工具與產物偵測

在探索專案或產生 AI 輔助產物之前，回報本機可用工具與專案既有產物狀態。工具 inventory 與專案產物狀態分開處理；inventory 快取不代表任何專案產物新鮮。

## 本機工具 Inventory

工具 inventory 固定檢查 graphify、dotnet-script、SchemaExporter、rg、ast-grep、jq 與 yq。Windows 環境以 Get-Command 定位命令。命中後才執行該工具的版本探測；不要執行會產生專案產物、連線資料庫、呼叫模型或下載資料的功能命令。

版本探測方式如下：

| 工具 | 定位方式 | 版本方式 |
| --- | --- | --- |
| graphify | Get-Command graphify | graphify --version |
| dotnet-script | Get-Command dotnet-script | dotnet-script --version |
| SchemaExporter | Get-Command schemaexporter | 讀取 executable 的 FileVersionInfo.ProductVersion；空值時使用 FileVersion |
| rg | Get-Command rg | rg --version |
| ast-grep | Get-Command ast-grep | ast-grep --version |
| jq | Get-Command jq | jq --version |
| yq | Get-Command yq | 優先 yq --version；不支援時使用 yq -V，並確認輸出標記 Mike Farah 或 github.com/mikefarah/yq |

Get-Command 找不到工具時，回報「未安裝」。命令存在但版本探測失敗時，回報「已安裝、版本未確認」及原始錯誤；不得將探測失敗推論為未安裝。yq 命令存在但輸出沒有 Mike Farah 或 github.com/mikefarah/yq 識別資訊時，回報「實作未確認」，不可將同名工具當成已確認的 yq。

Inventory 快取只存工具名稱、命令定位狀態、版本或未確認原因，以及掃描時間。快取路徑為機器層 ~/.ai-agents/.local/cache/ai-tool-discovery.json，有效期為 7 天。快取採下列格式片段（完整快取有固定七種工具各一筆）；欄位缺漏、型別錯誤或工具清單與固定清單不一致時視為格式無效：

```json
{
  "schema": "ai-tool-discovery-cache.v1",
  "scannedAtUtc": "2026-01-01T00:00:00Z",
  "tools": [
    {
      "name": "graphify",
      "commandFound": true,
      "version": "0.0.0",
      "versionError": null
    }
  ]
}
```

`tools` 必須各有固定七種工具的一筆記錄；`version` 或 `versionError` 可為 null，但不可同時為非 null。讀取快取前確認 schema、工具清單與 scannedAtUtc 欄位有效；讀取失敗、掃描時間在未來、格式無效或超過 7 天時視為不可用並重掃。快取有效時直接使用，不執行 Get-Command 或版本命令。重掃時以暫存檔取代快取。

不要快取或輸出任何環境變數值、連線字串、認證資料、完整命令環境或不必要的 executable 參數。SchemaExporter 版本只讀 executable 中繼資料，不透過資料庫或連線參數探測。

Inventory 回報使用固定欄位：

| 工具 | 安裝狀態 | 版本 | 用途 | 適用時機 | 產物路徑 | 重產命令 |
| --- | --- | --- | --- | --- | --- | --- |

各工具用途、時機與產物資訊如下：

| 工具 | 用途 | 適用時機 | 產物路徑 | 重產命令 |
| --- | --- | --- | --- | --- |
| graphify | 建立程式碼關聯圖。 | 需要跨檔案結構脈絡時。 | .local/ai-context/graphify/graphify-out/ | pwsh -NoProfile -File "<AiAgentsRoot>/scripts/Ensure-AiContextArtifacts.ps1" -ProjectRoot "<ProjectRoot>" -ToolName graphify |
| dotnet-script | 執行 repo 內既有 Roslyn C# Script 分析。 | 需要公開 API、型別繼承或專案參考圖時。 | .local/ai-context/api-surface.md、type-hierarchy.md、project-graph.md | Ensure-AiContextArtifacts.ps1，分別指定 Export-ApiSurface、Export-TypeHierarchy 或 Export-ProjectGraph。 |
| SchemaExporter | 匯出資料庫 Schema Summary 與 Snapshot。 | 需要查詢 Schema、資料庫註解或離線比對時。 | .local/ai-context/schemaexporter/<connection>/ | Direct export 命令只可使用 --connection-string-env <ENV_NAME> 或 --connection-string-stdin；列出安全命令範本，不填任何連線字串值。 |
| rg | 以文字與 regular expression 搜尋來源。 | 定位名稱、設定與 SQL／EF mapping 時。 | 不適用 | 不適用 |
| ast-grep | 以 AST pattern 搜尋程式結構。 | 語法形狀穩定且需要避免文字誤比對時。 | 不適用 | 不適用 |
| jq | 查詢與轉換 JSON。 | 檢查 Snapshot 欄位或篩選 JSON 時。 | 不適用 | 不適用 |
| yq | 查詢與轉換 YAML，也可處理 JSON。 | 檢查專案 YAML 設定或資料時。 | 不適用 | 不適用 |

Inventory 實際輸出需合併以上用途與探測結果。沒有產物的工具，產物路徑與重產命令填「不適用」。SchemaExporter 的重產命令只列環境變數名稱或 stdin 模式；不得讀取 .env、命令列環境或連線字串值。

## 專案產物狀態

使用者詢問專案既有 AI 產物時，讀取 ProjectRoot/.local/ai-context/index.md 與索引所列實際 artifact set。逐列回報狀態與可供使用者參考的重產命令。這是唯讀流程，不呼叫任何重產命令，也不建立、更新、刪除或整理產物。

索引使用 ai-context-index 宣告的五欄格式。將產物路徑解析於 ProjectRoot 之下；拒絕解析到 ProjectRoot 之外的路徑。一般檔案須存在且非空。graphify artifact set 必須是 `.local/ai-context/graphify/graphify-out/`，且其中 `graph.json` 必須存在且非空；目錄內其他檔案不能替代 `graph.json`。其他目錄 artifact set 須存在並包含檔案。Summary entry 的相對連結檔與目錄是同一 artifact set，缺少任何必需連結檔時視為不完整。

依下列規則分類：

| 狀態 | 判定 |
| --- | --- |
| 新鮮 | 索引列存在、artifact set 完整，且依工具所屬 Skill 的明確演算法重算來源指紋相同；無法重算來源指紋時，僅在所屬 Skill 明確定義的 freshness 規則有效時列為新鮮。 |
| 過期 | 索引列與產物存在，但重算來源指紋不相同，或所屬 Skill 明確定義的 freshness 時效已超過。 |
| 缺漏 | 索引列或 artifact set 缺少。索引列缺少但實際檔案存在時，仍列出實際路徑，並在判定依據標註「無索引」。 |

Ensure 產物依 ai-context-index 的來源集合計算方式讀取並重算指紋。SchemaExporter artifact set 依 database-schema-context 的設定與 freshnessDays 規則判斷，使用最舊的必需檔案時間。若某列沒有可重算指紋，且所屬 Skill 未明確定義 freshness 規則，停止該列分類並回報缺少的判定規則；不得新增第四種狀態，也不得將它冒充新鮮、過期或缺漏。

若 index.md 不存在，列出 .local/ai-context/ 下實際存在的產物並標註「缺漏／無索引」。若索引格式無效、欄位不全或路徑超出 ProjectRoot，回報具體索引錯誤，不猜測狀態。索引沒有列出但實際存在的檔案不可靜默忽略。

專案狀態回報使用固定欄位：

| 工具 | 產物路徑 | 狀態 | 判定依據 | 重產命令 |
| --- | --- | --- | --- | --- |

重產命令只作為文字回報，使用索引列或所屬 Skill 定義的安全命令。命令中的連線資訊僅能是環境變數名稱或 stdin 模式，不得包含連線字串值。過期或缺漏都不會觸發重產。
