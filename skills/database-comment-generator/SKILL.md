---
name: database-comment-generator
description: 'Use when the user asks to build or update a source-backed database comment vocabulary, or to generate reviewable table and column comment SQL from approved terms and a SchemaExporter snapshot.'
audience: agent
policy.allow_implicit_invocation: true
---

# Database Comment Generator

本 Skill 分為語彙候選整理與 SQL 產生兩階段。候選只記錄程式碼證據，不等於已核准的業務定義；只有使用者明確核准的詞條可進入 SQL 階段。

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

只有使用者明確要求產生或更新註解 SQL 時才執行此階段。SQL 是供人工覆核的檔案；產生流程不連線資料庫、不查詢 metadata、不執行 SQL，也不呼叫會執行 SQL 的工具。

輸入必須包括指定 connection 的 Approved 詞條、`schema-context.json` 中該 connection 的資料庫類型，以及同一 connection 的完整 SchemaExporter Snapshot／Summary artifact set。只使用 Snapshot 的 `objectDescription`、`columnDescription` 與物件名稱；Snapshot 缺少本次必要欄位時才從 Summary 補足，兩者都不足就停止該筆並回報。必須以 Schema、Table、Column 精確對應，不從欄名、SQL Server default 或 Oracle default 推導物件或語意。未知或歧義的 mapping 不產生該筆 SQL。

只處理 Table 與 Column。明確略過 Draft、PendingUserConfirmation、View、Routine 與其他物件。若沒有任何 Approved 詞條，不建立或覆寫 SQL 檔；回報原因及待核准詞條數量。對每筆 Approved 詞條，先將 CRLF、CR 與 LF 統一成 LF，再使用 ordinal 比較，不 Trim 空白：

| Snapshot 現況 | 處理方式 |
| --- | --- |
| description 為 null 或長度為 0 | 放入 `-- New Comments`，建立註解。 |
| description 長度大於 0，且正規化換行後只含空白字元 | 一律放入 `-- Differences`，不論它是否等於 Approved 定義；以 `-- DB existing value (whitespace-only): "<JSON-escaped value>"` 顯示完整現況。 |
| description 非空且與 Approved 定義完全相同 | 不輸出該物件。 |
| description 非空且與 Approved 定義不同 | 放入 `-- Differences`，並在 SQL 註解逐行列出完整 DB 既有值。 |

空白字元判定不 Trim description。whitespace-only 的既有值以雙引號包住 JSON-escaped 字串，並使用 `whitespace-only` 標籤，讓空格、tab 與正規化後的換行可辨識；它不能列入 New Comments。

輸出固定為 `<ProjectRoot>/.local/ai-context/database-comment-generator/<connection>/comment-script.sql`，每次產生都包含 `-- New Comments` 與 `-- Differences` 兩段標題，即使其中一段沒有語句。依 Schema、Table、Column 的 ordinal 順序輸出，使用 UTF-8、CRLF。若所有 Approved 詞條都相同，輸出只有兩個空段標題的 no-op 檔；每筆相同值本身不產生語句。

### SQL Server

每個 Table／Column 以條件式 `sp_addextendedproperty` 或 `sp_updateextendedproperty` 寫入 `MS_Description`。產生 SQL 時只讀 Snapshot；下列 catalog lookup 是 SQL 檔內容，留給使用者在覆核後自行執行：

- Table 以 `sys.extended_properties` 的 `class = 1`、`major_id = OBJECT_ID(...)`、`minor_id = 0` 及 `name = N'MS_Description'` 判斷既有 property。
- Column 以 `sys.extended_properties` 和 `sys.columns` 連接 `object_id` 與實際 `column_id` 判斷；不得假設欄位序號或以 0 代表 Column。
- 存在時呼叫 `sys.sp_updateextendedproperty`，不存在時呼叫 `sys.sp_addextendedproperty`。使用 `@level0type=N'SCHEMA'`、`@level1type=N'TABLE'`；Column 再加 `@level2type=N'COLUMN'` 與實際物件名稱。
- SQL identifier 使用方括號並將 `]` 寫成 `]]`；`OBJECT_ID` 中的 Unicode 字串同時逸出單引號。description 使用 `N'...'` Unicode literal，單引號加倍。

### Oracle

使用 Oracle `COMMENT ON`，Table 與 Column 分開輸出：

```sql
COMMENT ON TABLE "<schema>"."<table>" IS '<description>';
COMMENT ON COLUMN "<schema>"."<table>"."<column>" IS '<description>';
```

識別字以雙引號包住並將內部 `"` 加倍；字串 literal 的單引號加倍。Oracle description 只從 Snapshot／Summary 取得；Snapshot 沒有提供的 column default 或 routine description 不作推論。本流程不輸出 View、Routine 或預設值註解。

### 差異註解與寫檔

`-- Differences` 中每個物件先列 Schema、Table 與 Column，再標出完整既有 description。一般差異值的每一行都加 SQL line comment prefix，避免舊值被當成可執行 SQL；不得截斷或改寫舊值。whitespace-only 現況使用單行 `-- DB existing value (whitespace-only): "<JSON-escaped value>"`，雙引號內的 JSON string 必須代表正規化換行後的完整現況。New Comments 不附不存在的既有值。新增／更新的 description 以 SQL literal 規則逸出，不能透過字串拼接把 description 當成 SQL 程式碼。

先在同一 connection 目錄 nonce 暫存檔完整產生 SQL，檢查兩段標題、所有輸出物件名稱、引用規則及 Draft／PendingUserConfirmation 排除結果，再替換 `comment-script.sql`。渲染、Snapshot 解析或驗證失敗時移除暫存，保留原 SQL 檔並回報錯誤。產生後回報資料庫類型、Snapshot 路徑、核准／略過／待確認筆數、New Comments 與 Differences 語句數及 SQL 檔路徑；不得連線或執行輸出檔。

語法依據：[SQL Server sp_addextendedproperty](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-addextendedproperty-transact-sql?view=sql-server-2017)、[sp_updateextendedproperty](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-updateextendedproperty-transact-sql?view=sql-server-ver16)、[sys.extended_properties](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/extended-properties-catalog-views-sys-extended-properties?view=sql-server-ver17)；[Oracle COMMENT](https://docs.oracle.com/en/database/oracle/oracle-database/26/sqlrf/COMMENT.html)。
