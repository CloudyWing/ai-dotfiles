---
name: database-schema-context
description: 'Use when the user asks to export or inspect database schema context, use an existing offline schema snapshot, or check database schema changes with SchemaExporter.'
audience: agent
policy.allow_implicit_invocation: true
---

# Database Schema Context

使用 SchemaExporter 的 named connection 匯出並檢視資料庫 Schema Summary 與 Snapshot，將各連線的完整產物組保存於專案 .local/ai-context/。本 Skill 不修改 SchemaExporter、不執行 SQL，也不為了查看產物而自行連線資料庫。僅檢視既有產物時保持唯讀；只有使用者明確要求匯出、刷新、強制重產或檢查變動時才執行 CLI。

## 連線名稱與設定

SchemaExporter 從自己的使用者設定讀取已設定的 named connection。使用者設定路徑為 %LOCALAPPDATA%\SchemaExporter\appsettings.json。

列出連線名稱時使用以下單段 PowerShell 命令。輸出只包含 Name 與 DatabaseType：

    Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'SchemaExporter\appsettings.json') -Raw | ConvertFrom-Json | ForEach-Object { $_.Schema.Connections } | Select-Object Name, DatabaseType

使用者已提供連線名稱時使用該名稱。未提供時，列出 Name 與 DatabaseType 後請使用者選擇，不自行挑選。指定名稱不在 Schema.Connections 時回報「連線名稱不存在」，請使用者提供有效名稱，並停止流程；不得改用其他連線，也不得建立輸出目錄或輸出檔。

SchemaExporter 執行檔依序解析：

1. PATH 上的 schemaexporter。
2. PATH 上的 CloudyWing.SchemaExporter。
3. %LOCALAPPDATA%\CloudyWing.SchemaExporter\current\CloudyWing.SchemaExporter.exe。

前兩項使用 Windows Get-Command 以 Application 類型查找。第三項使用環境變數展開後的路徑。三者都找不到時回報無法定位執行檔並停止；不安裝或下載工具。

每次啟動前，以執行檔的 --help、export --help 與 diff --help 檢查能力。確認支援 export --connection、--schema-summary、--snapshot，以及 diff 子命令的 --left、--right；任何必要能力缺少或說明無法確認時停止，並說明需要 SchemaExporter 0.4.0。

Schema context 設定檔為 <ProjectRoot>/.local/ai-context/schemaexporter/schema-context.json。以連線名稱作為 connections 的 key，每個項目只記錄 databaseType 與 freshnessDays。databaseType 必須與列出的 DatabaseType 相符，支援 SqlServer 與 Oracle；freshnessDays 為正整數，未設定時預設 7。範例如下：

    {
      "schema": "database-schema-context.v1",
      "connections": {
        "LocalDev": {
          "databaseType": "SqlServer",
          "freshnessDays": 7
        }
      }
    }

連線名稱作為單一目錄名稱時，只接受英數字、底線與連字號；含路徑分隔符、點點路徑或其他字元時停止並要求安全名稱。不要在此設定檔保存其他連線欄位。

## 匯出與索引

每個連線的輸出根目錄為 <ProjectRoot>/.local/ai-context/schemaexporter/<connection-name>/。不同連線使用不同目錄，不得互相覆蓋。唯一匯出命令為：

    schemaexporter export --connection <name> --output "<temporary-directory>" --schema-summary --snapshot --no-timestamp --no-open-output-folder

<name> 必須是使用者指定且已存在於 Schema.Connections 的名稱。<temporary-directory> 是該連線目錄內以隨機 nonce 命名的暫存目錄。命令中的路徑佔位符一律以雙引號括住；實際路徑含空白時必須保留雙引號。使用解析出的 SchemaExporter 執行檔呼叫該命令。

必要輸出包含 Schema Summary entry、Snapshot 與 Summary entry 所有連結的分檔。依 CLI 回報的輸出路徑定位 entry；驗證 Snapshot 為有效 JSON，entry 與連結檔存在且非空，連結解析後仍在暫存目錄內。拒絕絕對連結、.. 路徑或任何離開暫存目錄的連結。Summary entry 與其 <entry-stem>.objects/ 分檔視為同一 artifact set。Excel、manifest 與其他 sidecar 不屬於本 Skill 的 artifact set，不提升至正式目錄。

CLI 成功且整組輸出完整後，才提升 artifact set 並更新 <ProjectRoot>/.local/ai-context/index.md。索引採 ai-context-index 的五欄格式，Summary 與 Snapshot 各有一列：工具為 SchemaExporter、產物路徑相對於 ProjectRoot、重產命令只使用 named connection、來源指紋填「不適用」、產生時間使用 UTC ISO 8601。Summary entry 的連結分檔不另列為獨立產物。

提升前保留原有完整 artifact set 與索引。使用同目錄暫存準備索引；artifact 或索引任何一步提升失敗時，還原舊組與舊索引，清除 pending 與 backup 暫存，再回報錯誤。不得留下半組產物。不新增鎖定機制；同一連線的併發更新可能互相覆蓋。

## 僅檢視既有文件

1. 讀取 schema-context.json、該連線的索引列、Summary、Snapshot 與 Summary 的所有連結分檔。只以 Snapshot 的 objectDescription、columnDescription 等欄位作為資料庫現況；必要時才從 Summary 補足。不得另做資料庫 metadata 查詢。
2. 確認整組文件完整後，檢查每個必需檔案的 LastWriteTimeUtc。所有必需檔案都在 freshnessDays 內時標為新鮮；最舊檔案超過時效時標為過期，並標註「已過期 N 天」。
3. 完整的過期舊組仍回傳內容並標註過期天數。Summary、Snapshot 或連結分檔不完整時，列出缺少檔案並停止回傳文件，不提供半組內容。
4. 此流程不呼叫 SchemaExporter、不連線、不建立或更新產物與索引。

## 使用者明確要求匯出或刷新

1. 確認連線名稱存在，解析執行檔並完成 --help 能力檢查。
2. 依唯一匯出命令將新 Summary、Snapshot 與連結檔寫入 pending 目錄；使用者明確要求刷新時，即使舊組仍新鮮也執行。
3. 驗證整組輸出完整後，提升新 artifact set 並更新 Summary 與 Snapshot 索引列。
4. CLI 連線或匯出失敗時，若舊 Summary、Snapshot 與全部連結檔完整，保留舊檔與索引，回傳舊文件並標註「離線快照：N 天前」。N 依 Snapshot 的 LastWriteTimeUtc 計算；時間無法取得時標註「快照時間未確認」。若沒有完整舊組，回報錯誤並停止，不回傳半組文件。
5. 成功或失敗後均清除 pending 與 backup 暫存。提升或索引更新失敗時先完成回復，再回報錯誤。

## 手動檢查變動

只在使用者明確要求「檢查變動」時執行，不把日常閱讀或過期提示解讀成差異檢查。先確認現有 Summary、Snapshot 與連結分檔完整，再使用唯一匯出命令將新一組文件寫入 pending 目錄。接著以本機 Snapshot 執行離線 diff：

    schemaexporter diff --left "<baseline-snapshot>" --right "<pending-snapshot>" --format json

diff 只讀本機兩個檔案，不連線資料庫。CLI 失敗、輸出格式無效或無法明確判斷是否有差異時，視為失敗，保留舊 artifact set 與索引，清理 pending 後回報。

- 無差異：Summary entry、連結分檔的 bytes 與 mtime 保持不變。完整性檢查通過後，只以 pending Snapshot 取代舊 Snapshot。更新 Snapshot 索引列，並將 Summary 索引列的產生時間設為本次檢查的 UTC 時間；此時間代表最近一次成功檢查，不表示 Summary bytes 被重寫。清除 pending 中的新 Summary 與其他輸出。
- 有差異：確認 pending Summary、所有連結分檔與 Snapshot 完整後，一起提升新 artifact set，更新 Summary 與 Snapshot 兩列索引。
- 匯出、diff、完整性檢查、提升或索引更新任何一步失敗：刪除 pending，還原並保留上一組完整 Summary、Snapshot 與索引，回報錯誤。

## 回報

回報連線名稱、資料庫類型、輸出路徑、狀態（新鮮、已更新、離線快照或錯誤）與是否執行 diff。失敗時列出步驟、結束碼及已遮蔽的錯誤摘要。命令、輸出、索引、日誌與報告都不得包含連線字串或其他認證值。
