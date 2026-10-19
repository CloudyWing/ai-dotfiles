---
name: database-comment-generator
description: 'Use when the user asks to build or update a source-backed database comment vocabulary, or to generate reviewable table and column comment SQL from approved terms and a SchemaExporter snapshot.'
audience: agent
policy.allow_implicit_invocation: true
---

# Database Comment Generator

本 Skill 分為語彙候選整理與 SQL 產生兩階段。候選只記錄程式碼證據，不等於已核准的業務定義；只有使用者明確核准的詞條可進入 SQL 階段。SQL 階段的 Agent 只負責產生註解清單，SQL 內容由 SchemaExporter 的 `comment-sql` 子命令確定性產生。

## 語彙候選與增量維護

語彙表位於 `<ProjectRoot>/.local/ai-context/database-comment-generator/comment-vocabulary.md`。第一次建立前確認輸出目錄被機器層 `.local/` 規則排除；不修改專案 `.gitignore`。增量更新時先讀現有語彙表，保留所有 Approved 定義與狀態，不靜默改寫。

執行 `<AiAgentsRoot>/scripts/Export-CommentVocabularyCandidates.csx` 時，傳入 ProjectRoot，解析 stdout 的 JSON。腳本唯讀 `.cs` 檔案，只輸出候選事實，不寫語彙表、不連線資料庫、不執行 SQL。每筆候選須保留來源相對路徑與行號。`complete` 表示所有來源均解析成功；`partial` 表示有 Roslyn parse error，須回報檔案、行號與診斷，不得把該次候選標為 Approved。

候選範圍包含 XML doc、Entity／Model 屬性名稱與 attributes，以及 enum 成員、原始數值 expression 和可解析的數值候選。只有 `Table`、`Column`、`Key`、`Required`、`StringLength`、`MaxLength`、`MinLength`、`Display`、`DisplayName`、`Description`、`Comment`、`Index`、`ForeignKey`、`NotMapped`、`DatabaseGenerated` 與 `Owned` attribute 可輸出參數；其他 attribute 只輸出名稱。允許清單的參數只在 expression 是單純字串、字元、數值、布林或 `null` literal、`typeof`／`nameof` 的單純名稱，或語意模型確認的 enum member access 時輸出原值。其他 expression（包含字串串接、插值字串、方法呼叫與條件運算）整個參數以 `***` 取代，不嘗試部分遮蔽。任何輸出的字串 literal 若不分大小寫含 `password`、`pwd`、`secret`、`token`、`api[-_ ]?key`、`connection ?string`、`server=`、`data source=`、`user id=` 或 `uid=`，整段 literal 以 `"***"` 取代；XML documentation 文字含任一標記時，整個 documentation 欄位以 `***` 取代，避免敏感值進入 stdout 或 transcript。

enum 數值候選由腳本建立 `CSharpCompilation` 取得：所有掃描 `.cs` 語法樹作為 `syntaxTrees`，優先引用執行環境 `TRUSTED_PLATFORM_ASSEMBLIES` 中可用的平台組件，輸出類型為 `DynamicallyLinkedLibrary`；不新增 NuGet 套件，也不引用專案組件。對每個 enum 成員使用 `SemanticModel.GetDeclaredSymbol(member)` 取得 `IFieldSymbol`，再讀取 `IFieldSymbol.ConstantValue` 並轉成 `CultureInfo.InvariantCulture` 字串；不要使用 `SemanticModel.GetConstantValue()`。候選 JSON 為 enum 成員輸出 `numericValueStatus`（`resolved` 或 `unresolved`）與 `numericValueReason`；只有取得常數值時才輸出數值候選。Compilation、SemanticModel 或 declared symbol 無法取得、成員沒有常數值或讀取發生例外時，保留原 expression、將 `numericValueCandidate` 設為 `null`、提供原因並繼續抽取其他候選。此方式依 C# 語意處理整數 literal、底層型別、位移、位元補數、自動遞增及成員引用；外部組件常數若未被平台組件引用，須標為 unresolved，不得補猜數字。腳本的 Entity／Model 標記是名稱或 attribute heuristic，不是型別語意證明；欄位定義不得只從英文屬性名稱猜測。未解析的數值保留 expression 與來源位置，不能補猜數字。

EF fluent mapping 與 SQL 欄位對應須以 `rg` 找到來源後人工追蹤，例如 `HasColumnName`、`ToTable`、`[Column]` 與 SQL projection。明確區分語法抽取事實、人工追蹤的 mapping 與使用者確認的業務語意。找不到 mapping、跨檔案關係不清、條件編譯或產生碼造成歧義時，列為待確認；不可假稱 Roslyn 已推得完整資料庫語意。

語彙表使用固定十欄 Markdown 表格，欄位順序如下：

| 範圍 | Schema | Table | Column | 定義 | 證據檔案:行號 | 來源種類 | Enum 代碼值 | 信心 | 狀態 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 全域一致／限定表 | 實際值或未確認 | 實際值或未確認 | 實際欄名或未確認 | 證據支持的定義或待補證據 | 相對路徑:行號 | XML doc／屬性／EF mapping／SQL mapping／enum | 實際值或不適用 | 高／中／低 | Draft／PendingUserConfirmation／Approved |

不適用欄位填「不適用」，未知資訊填「未確認」，不可留空。候選定義以 XML doc 或其他可定位證據為主；只有屬性名、enum 名或 heuristic 而沒有語意描述時，定義填「待補證據」，狀態維持 Draft 或 PendingUserConfirmation。

歸併與狀態規則：

1. 同名欄位有明確 mapping，且不同使用位置的證據支持相同語意時，維護一筆「全域一致」定義，並追加所有證據路徑與行號。
2. 同名欄位在不同表可能代表不同概念、mapping 不明、證據互相衝突或語意仍需使用者判斷時，建立「限定表」候選並設為 `PendingUserConfirmation`。不能因欄名相同就合併。
3. 有直接但未核准的程式碼描述時可列 `Draft`；證據不足或候選間有歧義時列 `PendingUserConfirmation`。confidence 只描述目前證據強弱，不代表核准。
4. 只有使用者明確確認該筆定義後才能改為 `Approved`。不得從程式碼、測試通過、先前曾產生 SQL 或未回覆推定核准。
5. 新證據與既有 Approved 定義相同時，只增量補上證據；若相矛盾，保留原 Approved 定義，另建限定表 PendingUserConfirmation 候選並指出衝突，不覆寫既有語意。
6. 更新後逐筆呈現新增、補充證據、待確認、衝突及核准狀態，讓使用者能確認詞條；此階段不產生 SQL。

### 蒐集與覆核流程

1. 讀取目標專案 `.cs` 來源與現有語彙表；不讀取 `.env` 或任何連線字串。
2. 執行候選抽取腳本。腳本若失敗或回傳 `partial`，保留來源與既有詞條，回報診斷，不用不完整候選更新 Approved 定義。
3. 依每筆來源路徑和行號檢視 XML docs、attributes、enum 與明確欄位 mapping。必要時用 `rg` 搜尋 EF fluent 設定及 SQL，再人工確認跨檔關係。
4. 以證據逐筆分類為全域或限定表，建立或增量更新十欄語彙表。未確認的 Schema／Table／Column 不以猜測補值。
5. 呈現待確認詞條，等待使用者對明確詞條核准；未核准項目維持 Draft 或 PendingUserConfirmation。

語彙候選階段只寫語彙表及回報候選，不連資料庫、不讀取 SchemaExporter Snapshot、不建立 SQL 檔、不執行 SQL。

## 從核准詞條產生 SQL

只有使用者明確要求產生或更新註解 SQL 時才執行此階段。SQL 檔是供人工覆核的檔案，由 `schemaexporter comment-sql` 離線產生。該子命令只讀取 Snapshot 與註解清單，不連線資料庫、不查詢 metadata、不執行 SQL。Agent 不自行撰寫或修改 SQL 語句，使用者檢視 SQL 檔之後自行執行。

### 前置檢查

1. 確認使用者指定的 connection 名稱。名稱的列出方式、安全名稱規則與執行檔解析順序沿用 `database-schema-context` Skill，連線字串不出現在任何命令、檔案或回報中。
2. 以 `<exe> --help` 檢查能力。輸出不含 `comment-sql` 時停止，請使用者將 SchemaExporter 更新至 0.4.0 以上，不改以 Agent 或腳本拼 SQL。不以實際呼叫 `comment-sql` 試探版本，舊版會把未知參數交給桌面視窗，命令不會結束。
3. 依 `database-schema-context` Skill 的「僅檢視既有文件」流程定位該 connection 的 Snapshot，路徑取自 `<ProjectRoot>/.local/ai-context/index.md` 的 Snapshot 列。Snapshot 不存在或不完整時，請使用者先以 `database-schema-context` 匯出，本階段不自行匯出。Snapshot 已過期時回報「已過期 N 天」，由使用者決定是否先刷新，因為新增段與差異段以 Snapshot 當下的註解為準。
4. 讀取語彙表。沒有任何 Approved 詞條時，不建立或覆寫任何檔案，回報原因及待核准詞條數量。

### 註解清單

Agent 依 Approved 詞條與 Snapshot 寫出註解清單 `<ProjectRoot>/.local/ai-context/database-comment-generator/<connection>/comments.json`，格式為 UTF-8 JSON 陣列，每個元素有 `schema`、`object`、`column`、`comment` 四個欄位。

```json
[
  { "schema": "dbo", "object": "Users", "column": "", "comment": "使用者資料表" },
  { "schema": "dbo", "object": "Users", "column": "Name", "comment": "顯示名稱" }
]
```

- `schema` 為 SQL Server 的 schema 或 Oracle 的 owner。表層註解的 `column` 填空字串。
- 名稱使用 Snapshot 內的寫法，依 Schema、Table、Column 精確對應詞條，不從欄名推導。Schema、Table 或 Column 為「未確認」、Snapshot 找不到或有歧義的詞條不列入，並在回報列為略過。
- 只列入 Approved 詞條，且只處理 Snapshot 中的資料表與其欄位。Draft、PendingUserConfirmation、View 與 Routine 不列入。
- `comment` 逐字使用詞條的定義，不修剪、不改寫，也不自行縮短。`comment` 為空字串的項目會被子命令略過，不會清除資料庫現有註解。
- 同一目標在清單中只出現一次。

### 產生與覆核

執行下列命令。三個選項都必要，資料庫類型取自 Snapshot。

```bash
schemaexporter comment-sql --snapshot "<snapshot>" --comments "<comments.json>" --output "<ProjectRoot>/.local/ai-context/database-comment-generator/<connection>/comment-script.sql"
```

| 結束代碼 | 處理方式 |
| --- | --- |
| 0 | 成功。進入索引登記與回報。 |
| 1 | 參數錯誤。依 stderr 訊息修正命令後重跑。 |
| 2 | 輸入檔錯誤或清單有問題，stderr 為 `Comment SQL failed: ...` 並逐項列出全部問題，輸出檔不會被建立或修改。依訊息修正 `comments.json` 後重跑。名稱對不上 Snapshot 時以 Snapshot 的寫法修正。註解超過長度上限或含不允許的字元時，修正會改變已核准的定義，停止並請使用者決定。同一項目修正一次後仍失敗時停止並回報。 |
| 3 | 未預期的錯誤。保留 stderr 並回報，不重試。 |

內容有誤時修正 `comments.json` 或回到語彙表，再重新執行子命令，不手動編輯 `comment-script.sql`。

輸出的 SQL 檔分成新增段與差異段。

- 新增段列出 Snapshot 現有註解為空的目標。
- 差異段列出現有註解不同的目標，每筆語句上方以 `-- existing: "..."` 附上資料庫既有值。只含空白的既有值也列入差異段，標示為 `-- existing (whitespace-only): "..."`。
- 現有註解與清單逐字相同的目標不輸出語句，只計入檔頭的 `Unchanged` 筆數。
- SQL Server 以 `MS_Description` 擴充屬性寫入，每筆語句在執行時檢查屬性是否存在，存在就更新，不存在就新增。Oracle 使用 `COMMENT ON`。
- 相同的 Snapshot 與清單產生逐位元組相同的檔案。SQL Server 檔為 UTF-8 含 BOM，Oracle 檔為 UTF-8 不含 BOM，換行固定為 LF。

### 索引登記與回報

命令成功後，更新 `<ProjectRoot>/.local/ai-context/index.md`，依 `ai-context-index` Skill 的五欄格式為 `comment-script.sql` 登記一列。工具填 `database-comment-generator`，產物路徑相對於 ProjectRoot，重產命令填入本次實際使用的 `comment-sql` 命令，來源指紋填「不適用」，產生時間使用 UTC ISO 8601。同一產物路徑已有索引列時更新該列，不新增重複列。`index.md` 不存在時依 `ai-context-index` 的格式建立。命令失敗時不更新索引。

回報下列項目。

- connection 名稱、資料庫類型與 Snapshot 路徑。
- Approved 詞條數、列入清單數、略過數（附原因）與待確認數。
- 子命令輸出的 `Add`、`Update`、`Unchanged (skipped)` 與 `Empty comment (skipped)` 筆數。
- `comments.json` 與 `comment-script.sql` 的路徑。
- 子命令輸出 `Warning:` 行時轉述該警告，並提醒使用者 Snapshot 套用過遮罩，其中的現有註解可能已被取代，新增段與差異段的判定可能不準確，執行前請對照資料庫現況。

回報同時提醒使用者執行方式。SQL Server 檔以 `sqlcmd -i <file>` 或 SSMS 執行。Oracle 檔以 SQL*Plus 執行，並先設定 `NLS_LANG=AMERICAN_AMERICA.AL32UTF8`，中文與 emoji 才會正確寫入。本 Skill 不執行這些命令。
