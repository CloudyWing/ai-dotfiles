---
name: database-schema-context
description: 'Use when the user asks to export or inspect database schema context, use an existing offline schema snapshot, or check database schema changes with SchemaExporter.'
audience: agent
policy.allow_implicit_invocation: true
---

# Database Schema Context

使用 SchemaExporter direct mode 取得資料庫 Schema Summary 與 Snapshot，並將每個連線的完整產物組保存於專案 `.local/ai-context/`。本 Skill 不修改 SchemaExporter、不執行 SQL，也不會為了查看產物而自行連線資料庫。僅檢視既有產物時一律唯讀，完整的過期舊組仍回傳並標註過期天數。只有使用者明確要求匯出、刷新、強制重產或「檢查變動」時才呼叫 CLI。

## 連線設定與秘密

設定檔位於 `<ProjectRoot>/.local/ai-context/schemaexporter/schema-context.json`。檔案只存連線名稱、資料庫類型、`freshnessDays`、傳遞模式及環境變數名稱，不存連線字串值。沒有 `freshnessDays` 時使用 7 天。每個連線必須指定 `SqlServer` 或 `Oracle`，並選擇環境變數或 stdin 傳遞方式。

設定格式如下；環境變數名稱由連線名稱正規化為大寫英數與底線：

```json
{
  "schema": "database-schema-context.v1",
  "freshnessDays": 7,
  "connections": {
    "local-dev": {
      "databaseType": "SqlServer",
      "credentialMode": "environmentVariable",
      "environmentVariableName": "SCHEMAEXPORTER_LOCAL_DEV_CONNECTION_STRING"
    },
    "reporting": {
      "databaseType": "Oracle",
      "credentialMode": "stdin"
    }
  }
}
```

連線名稱僅接受英數、底線及連字號，作為單一目錄名稱；Windows 上大小寫不同視為相同名稱。環境變數正規化將非英數字元轉成底線，若兩個連線得到同一環境變數名稱則停止並要求使用者調整名稱。設定缺欄、資料庫類型無效、連線名稱不安全或正規化衝突時，不建立目錄也不呼叫 CLI。

連線字串只可經設定檔指定的環境變數名稱或 stdin 傳入。絕不讀取 `.env`、`.env.*`，不在命令列、暫存檔、SQL、索引、日誌或報告中放入連線字串值。命令及回報只顯示環境變數名稱或 stdin 模式；不讀取或回顯環境變數值。stdin 來源必須直接 pipe 至 CLI，不先寫入檔案、console、transcript 或中介日誌。CLI 失敗時回報結束碼及已遮蔽的錯誤摘要，先確認錯誤內容不含連線字串。

CLI 使用 direct mode，不讀取 SchemaExporter 連線註冊表。範例如下，`<...>` 是需替換的非秘密參數：

```text
schemaexporter export --connection-string-env SCHEMAEXPORTER_LOCAL_DEV_CONNECTION_STRING --database-type SqlServer --connection local-dev --output <temporary-directory> --schema-summary --snapshot --no-timestamp --no-open-output-folder
<secure-secret-source> | schemaexporter export --connection-string-stdin --database-type Oracle --connection reporting --output <temporary-directory> --schema-summary --snapshot --no-timestamp --no-open-output-folder
```

環境變數名稱與 stdin 參數互斥。直接模式的 `--database-type` 必須明確指定；`--connection` 只作輸出標籤，不讀取同名設定連線。不要使用含連線值的 `--connection` 設定或連線字串命令列參數。若 `schemaexporter` 不在 PATH，回報未安裝並停止，不嘗試安裝或下載。

## 輸出與索引

每個連線的輸出根為 `<ProjectRoot>/.local/ai-context/schemaexporter/<connection>/`。不同連線使用不同目錄，不得互相覆蓋。匯出時將 CLI 的 `--output` 指向該連線目錄內以隨機 nonce 命名的 pending 目錄，並使用 `--no-timestamp`。只提升 Schema Summary 與 Snapshot；Excel、manifest 及其他 sidecar 不屬於本 Skill 的 artifact set。

將 CLI 回報的 `.schema-summary.md` 與 `.snapshot.json` 作為必需 entry 檔。驗證 Snapshot 為有效 JSON；Summary 的每個相對連結都指向 pending 目錄內存在的檔案，且不得以 `..` 或絕對路徑離開該目錄。Summary entry 與其 `<entry-stem>.objects/` 分檔視為同一組。缺少 entry、連結目標、Snapshot，或任一檔案為空時，整組不完整，不得取代舊產物。

成功完整後才提升新 artifact set 並更新 `<ProjectRoot>/.local/ai-context/index.md`。索引採 ai-context-index 定義的五欄，Summary 與 Snapshot 各有一列：工具為 `SchemaExporter`、產物路徑相對於 ProjectRoot、重產命令只含環境變數名稱或 stdin、來源指紋填「不適用」、產生時間使用 UTC ISO 8601。Summary entry 所連結的分檔不另列為獨立產物。更新前以同目錄暫存檔準備索引；提升 artifact 或索引任一步驟失敗時，還原原有完整 artifact set 與舊索引，再清除 pending／backup 暫存並回報錯誤。不得留下半組產物。不要新增鎖定機制；同一連線併發更新仍可能互相覆蓋。

## 僅檢視既有文件

1. 讀取設定與該連線索引列，檢查現有 Summary、Snapshot 及 Summary 所有連結分檔完整性。只讀取 SchemaExporter Snapshot 中的 `objectDescription`、`columnDescription` 等現況欄位；需要時才從 Summary 補足。不要另行查詢資料庫 metadata。
2. 完整 artifact set 一律回傳現有文件。對每個必需檔案檢查 `LastWriteTimeUtc`，全部不超過 `freshnessDays` 時標為新鮮；最舊檔案超過時標為過期，並以超過 `freshnessDays` 的天數標註「已過期 N 天」。此流程不呼叫 SchemaExporter、不連線，也不更新產物或索引。
3. Summary、Snapshot 或 Summary links 不完整時回報缺少的檔案，不回傳半組文件，也不因缺漏而自行呼叫 CLI。

## 使用者明確要求匯出或刷新

1. 只有使用者明確要求匯出、刷新或強制重產時，才依連線設定呼叫上述 direct export 命令，將 Summary 與 Snapshot 寫入 pending 目錄。即使舊組新鮮，也依明確要求執行。
2. 驗證新 artifact set 完整後才取代現有組並更新索引。只提升 Summary、Snapshot 與其 Summary links，不提升 Excel、manifest 或其他 sidecar。
3. CLI 連線或匯出失敗時，若舊 Summary、Snapshot 與全部 Summary links 完整，保留舊檔與索引，回傳舊文件並標註「離線快照：N 天前」。N 由 Snapshot 的 `LastWriteTimeUtc` 計算；時間無法取得時標註「快照時間未確認」。若沒有完整舊組，回報錯誤並停止，不回傳半組文件。
4. 成功或失敗後均清理 pending 與 backup 暫存。提升或索引更新失敗時，先完成回復，再回報錯誤。

## 手動檢查變動

只在使用者明確要求「檢查變動」時執行，不把日常閱讀、過期提示或使用者未授權的刷新解讀成 diff 要求。此流程會以 direct export 讀取資料庫現況，接著只用本機 Snapshot 執行離線 diff。

1. 確認現有 Summary、Snapshot 與 Summary links 完整。先選定一個 `GenerateSchemaSummary=false` 的 SchemaExporter profile，並確認本次 direct export 會套用該 profile。CLI 沒有停用 Summary 的命令列開關；若無法確認 profile 會停用 Summary，先停止，不要開始 export。
2. 以該 profile 將 Snapshot-only export 寫入同一連線目錄的 pending nonce 目錄。命令不得帶 `--schema-summary`，並須確認 pending 只包含有效 JSON Snapshot，沒有產生 `.schema-summary.md`。若產生 Summary，視為 profile 設定不符，刪除 pending 並停止。

   ```text
   schemaexporter export --connection-string-env <ENV_NAME> --database-type <SqlServer|Oracle> --connection <label> --profile <SnapshotOnlyProfile> --output <pending-directory> --snapshot --no-timestamp --no-open-output-folder
   <secure-secret-source> | schemaexporter export --connection-string-stdin --database-type <SqlServer|Oracle> --connection <label> --profile <SnapshotOnlyProfile> --output <pending-directory> --snapshot --no-timestamp --no-open-output-folder
   ```

3. 驗證 pending Snapshot 為有效 JSON，再使用 SchemaExporter 離線 diff 比較舊 Snapshot 與 pending Snapshot。diff 只讀本機兩個檔案，不連線資料庫：

   ```text
   schemaexporter diff --left <baseline-snapshot> --right <pending-snapshot> --format json
   ```

   CLI 失敗、輸出格式無效或無法明確判斷是否有差異時，視為失敗；保留舊 artifact set 與索引，清理 pending 後回報。

4. **無差異**：不呼叫會產生 Summary 的 export。舊 Summary entry、分檔的 bytes 與 mtime 保持不變；驗證 Snapshot 完整後只以 pending Snapshot 取代舊 Snapshot。更新 Snapshot 索引列，並將 Summary 索引列的產生時間設為本次成功檢查的 UTC 時間。此時間代表最近一次成功比對，不表示 Summary bytes 被重寫。清除 pending 內其他輸出。
5. **有差異**：只有在離線 diff 明確顯示差異後，才再次執行 direct export，這次使用會產生 Summary 的 profile 並同時帶 `--schema-summary --snapshot`，輸出到新的 pending nonce 目錄。驗證新 Summary entry、所有連結分檔與 Snapshot 完整後，一起提升新 Summary、分檔及 Snapshot，並更新兩列索引。不要使用 Snapshot-only profile 產生這份 Summary。
6. 匯出、diff、完整性檢查、提升或索引更新任何一步失敗時，刪除 pending，還原並保留上一組完整 Summary／Snapshot 與索引，回報結束碼與已遮蔽錯誤摘要。不要在本流程執行 SQL 或發出額外資料庫 metadata 查詢。
## 回報

回報連線名稱、資料庫類型、所用傳遞模式、輸出路徑、狀態（新鮮／已更新／離線快照／錯誤）與是否執行 diff。失敗時列出步驟、結束碼及已遮蔽錯誤。不得回報連線字串值、環境變數值或未經確認的差異結論。
