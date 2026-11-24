---
name: database-schema-context
description: 'Use when the user asks to export or inspect database schema context, use an existing offline schema snapshot, or check database schema changes with SchemaExporter, or when the agent itself needs table structure (columns, types, indexes, relationships, descriptions) while writing or reviewing SQL, ORM mappings or data-access code.'
audience: agent
policy.allow_implicit_invocation: true
---

# Database Schema Context

使用 SchemaExporter 的 named connection 匯出並檢視資料庫 Schema Summary 與 Snapshot，將各連線的完整產物組保存於專案 .local/ai-context/。本 Skill 不修改 SchemaExporter、不執行 SQL，也不為了查看產物而自行連線資料庫。僅檢視既有產物時保持唯讀。CLI 只在兩種情況執行。第一種是使用者明確要求匯出、刷新、強制重產或檢查變動。第二種是依「按需查表」，或依其他 skill 對快照的規定（例如 database-comment-generator 的註解 SQL 階段）自動建立或刷新。

## 連線名稱與設定

SchemaExporter 從自己的使用者設定讀取已設定的 named connection。使用者設定路徑為 %LOCALAPPDATA%\SchemaExporter\appsettings.json。

列出連線名稱時使用以下單段 PowerShell 命令。輸出只包含 Name 與 DatabaseType：

    Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'SchemaExporter\appsettings.json') -Raw | ConvertFrom-Json | ForEach-Object { $_.Schema.Connections } | Select-Object Name, DatabaseType

使用者已提供連線名稱時使用該名稱。未提供時，列出 Name 與 DatabaseType 後請使用者選擇，不自行挑選。指定名稱不在 Schema.Connections 時回報「連線名稱不存在」，請使用者提供有效名稱，並停止流程；不得改用其他連線，也不得建立輸出目錄或輸出檔。

SchemaExporter CLI 執行檔依序解析：

1. PATH 上的 schemaexporter。
2. PATH 上的 CloudyWing.SchemaExporter.Cli。
3. %LOCALAPPDATA%\CloudyWing.SchemaExporter\current\tools\CloudyWing.SchemaExporter.Cli.exe。

前兩項使用 Windows Get-Command 以 Application 類型查找。第三項使用環境變數展開後的路徑。三者都找不到時回報無法定位執行檔並停止；不安裝或下載工具。桌面程式 CloudyWing.SchemaExporter.exe 帶引數啟動時直接以結束代碼 1 結束，不作為解析目標。下文命令中的 schemaexporter 代表解析到的 CLI 執行檔。

每次啟動前，以執行檔的 --help、export --help 與 diff --help 檢查能力。確認支援 export --connection、--schema-summary、--snapshot，以及 diff 子命令的 --left、--right；任何必要能力缺少或說明無法確認時停止，並說明需要 SchemaExporter 0.5.0 以上。

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

設定檔頂層另有選填鍵 onDemandLookup，唯一合法值為字串 disabled，表示使用者已表示這個專案不使用「按需查表」。該鍵不存在時視為未停用。只記錄這項停用的設定檔，connections 寫成空物件。

## 匯出與索引

每個連線的輸出根目錄為 <ProjectRoot>/.local/ai-context/schemaexporter/<connection-name>/。不同連線使用不同目錄，不得互相覆蓋。唯一匯出命令為：

    schemaexporter export --connection <name> --output "<temporary-directory>" --schema-summary --snapshot --no-timestamp --no-open-output-folder

<name> 必須是使用者指定（含使用者回答後登記於 schema-context.json 的連線）且已存在於 Schema.Connections 的名稱。<temporary-directory> 是該連線目錄內以隨機 nonce 命名的暫存目錄。命令中的路徑佔位符一律以雙引號括住；實際路徑含空白時必須保留雙引號。使用解析出的 SchemaExporter 執行檔呼叫該命令。

必要輸出包含 Schema Summary entry、Snapshot 與 Summary entry 所有連結的分檔。依 CLI 回報的輸出路徑定位 entry；驗證 Snapshot 為有效 JSON，entry 與連結檔存在且非空，連結解析後仍在暫存目錄內。拒絕絕對連結、.. 路徑或任何離開暫存目錄的連結。Summary entry 與其 <entry-stem>.objects/ 分檔視為同一 artifact set。Excel、manifest 與其他 sidecar 不屬於本 Skill 的 artifact set，不提升至正式目錄。

CLI 成功且整組輸出完整後，才提升 artifact set 並更新 <ProjectRoot>/.local/ai-context/index.md。索引採 ai-context-index 的五欄格式，Summary 與 Snapshot 各有一列：工具為 SchemaExporter、產物路徑相對於 ProjectRoot、重產命令只使用 named connection、來源指紋填「不適用」、產生時間使用 UTC ISO 8601。Summary entry 的連結分檔不另列為獨立產物。

提升前保留原有完整 artifact set 與索引。使用同目錄暫存準備索引；artifact 或索引任何一步提升失敗時，還原舊組與舊索引，清除 pending 與 backup 暫存，再回報錯誤。不得留下半組產物。不新增鎖定機制；同一連線的併發更新可能互相覆蓋。

## 按需查表

Agent 在工作中需要資料表結構資訊時使用本節，不需要使用者要求。本節只讀取目標物件所需的檔案，「僅檢視既有文件」的整組讀取與完整性檢查只適用於整組檢視，不適用於本節。

### 適用判定

需要的資訊屬下列適用情況，且沒有命中不適用情況時，先依本節取得，資料庫查詢排在其後。命中任一不適用情況時直接用其他方式取得，不需先試快照。

適用情況：

- 要的是結構資訊，即欄位、型別、索引、關聯或說明。
- 同一工作要查多張資料表，或要看資料表之間的關聯。
- 資料庫未啟動，或沒有連線授權。

不適用情況：

- 要的是資料內容、筆數或其他快照沒有的資訊。
- 本次工作中剛變更過結構（例如剛執行 Migration 或 DDL），需要確認變更後的現況。
- 使用者指定直接查資料庫。
- 當前工作所依的 skill 對快照的讀取、匯出或刷新另有規定，例如 database-comment-generator 的註解 SQL 階段。此時快照的建立、刷新與失敗處置依該 skill 的規定，不依本節。

### 執行者

- 直接與使用者對話的 Agent 可執行本節的全部步驟。
- 由其他 Agent 以 prompt 或派遣檔啟動的執行者（子代理、Codex 派遣）只讀取既有快照，不執行 SchemaExporter CLI、不詢問連線、不寫入 schema-context.json。快照不存在、缺少目標物件或無法讀取時，改用其他方式取得結構，並在回報註明。快照已過期時照常使用，並在回報註明過期天數。
- 直接與使用者對話的 Agent 派出預期需要資料表結構資訊的工作前，先依「快照準備」執行一次，使執行者有可用的快照。

### 讀寫位置

ProjectRoot 是 Git 的連結工作樹時，本節讀寫的 schemaexporter 目錄與 index.md 以主工作樹為準，主工作樹是 `git worktree list --porcelain` 輸出的第一筆。連結工作樹移除後其 .local 不保留，寫在其中的連線登記與快照會遺失。

### 快照準備

1. 讀取 schema-context.json，依下列順序判定，命中即停止。
   - onDemandLookup 為 disabled：不使用本節，改用其他方式取得結構，不詢問也不建立。
   - connections 只有一個連線：使用該連線。
   - connections 有多個連線：能從工作內容判定對應連線時使用該連線，無法判定時詢問使用者，不自行挑選。
   - 設定檔不存在或 connections 為空：依「連線名稱與設定」列出 Name 與 DatabaseType，詢問使用者這個專案對應哪一個連線，或這個專案不使用快照。使用者回答連線名稱時寫入 connections，databaseType 取列出的值；回答不使用時寫入 onDemandLookup。每個專案只問這一次。提出詢問的當輪先用其他方式取得結構並繼續工作，答案用於之後的查表。
2. 依 index.md 中該連線的 Summary 與 Snapshot 兩列定位 Summary entry 與 Snapshot，只檢查檔案是否存在與修改時間，不讀取 Snapshot 內容。
   - 缺少索引列，或 Summary entry 與 Snapshot 任一不存在：建立快照。
   - Snapshot 的 LastWriteTimeUtc 距今超過 freshnessDays：刷新快照。
   - 其餘情況：直接依「查表」讀取。
3. 建立與刷新都依「使用者明確要求匯出或刷新」的步驟執行，不詢問使用者。同一工作內每個連線最多自動執行一次，不論成功或失敗都不再執行第二次。
4. 建立或刷新失敗時回報一行原因，並依下列方式繼續工作，不安裝也不下載工具。失敗包含找不到執行檔、能力檢查不通過、連線或匯出失敗、提升或索引更新失敗。
   - 有舊快照：使用舊快照查表。舊快照已超過 freshnessDays 時標註「已過期 N 天」，N 依 Snapshot 的 LastWriteTimeUtc 與 freshnessDays 計算。
   - 沒有舊快照：改用其他方式取得結構。
5. 「連線名稱與設定」與「使用者明確要求匯出或刷新」中的停止，在本節只代表停止建立或刷新，不停止當前工作。

### 查表

1. 讀取 Summary entry。entry 內含 Objects 明細時，直接取目標物件的段落。entry 只有 Object Inventory 與明細連結時，依目標物件那一列的連結讀取該物件的分檔，其他物件的分檔不讀。連結解析後須仍在該連線的目錄內，絕對連結與 .. 路徑一律拒絕。entry 篇幅大時，可只搜尋目標物件名稱所在的列。
2. 資料表之間的關聯取自 entry 的 Relationships。
3. 目標物件的段落或分檔已讀到，但其中沒有所需資訊時，改依「僅檢視既有文件」整組讀取。讀不到目標物件的情況依第 4 步，不依本步。
4. Summary entry 無法讀取、Object Inventory 沒有目標物件，或該物件的分檔不存在、為空或無法讀取時，視為缺表，依「缺表」處理。

### 缺表

依下列順序處理，命中即停止。

- 本次工作尚未對該連線自動建立或刷新過時，依「快照準備」第 3 步刷新一次後重查。
- 本次工作已對該連線自動建立或刷新過時，不再刷新。成功時所用快照已是最新的匯出結果，失敗時依「快照準備」第 3 步不執行第二次。

刷新後仍缺表、刷新失敗，或依上列第二項不再刷新時，回報連線名稱、缺少的物件名稱與快照時間，改用其他方式取得結構。

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

「按需查表」不使用上述回報格式。自動建立或刷新成功時不另行回報；失敗、使用過期快照或缺表時，依該節各以一行說明。
