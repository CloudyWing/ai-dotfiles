---
name: sql-query
description: 'SQL 撰寫規範：參數化查詢、索引友善寫法、效能陷阱迴避與可讀性格式要求，涵蓋 SQL Server（T-SQL）與 Oracle 雙資料庫的語法差異與語意陷阱，並依 AI-PROFILE 目標版本鍵避開不支援語法。當撰寫或審查原生 SQL 時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# SQL 撰寫規範

本規範涵蓋 SQL Server（T-SQL）與 Oracle 兩種資料庫的原生 SQL 撰寫，內容包含查詢、DML、交易與可讀性格式。「目標版本」節先定義依正式環境版本選用語法的方式。其後的規範分三層，先列兩庫共通規範，再分列 SQL Server 專屬與 Oracle 專屬語法。撰寫或審查原生 SQL 時自動套用。

## 目標版本

本節定義目標版本鍵的語意、讀取與詢問流程，以及版本資料的判讀方式。版本門檻資料只記載在 `references/` 的參考檔，本體不寫具體版本。`ef-core` 與 `ai-profile` 引用本節，不另行定義。

### 鍵與語意

| 鍵 | 語意 |
| --- | --- |
| `target.sqlserver` | 正式環境必須支援的最低 SQL Server 引擎版本。同一專案部署到多個正式環境時，記其中最低的版本。不填開發機版本 |
| `target.sqlserver.compat` | 正式環境資料庫的相容性層級，選填。多個資料庫時記最低者。未填時視為 `target.sqlserver` 對應的預設相容性層級 |
| `target.oracle` | 正式環境必須支援的最低 Oracle 版本。同一專案部署到多個正式環境時，記其中最低的版本。不填開發機版本 |

合法值、阻擋範圍與缺少時處置見 `ai-profile` 鍵登錄表。

### 適用偵測

下列任一證據成立時，判定專案使用該資料庫：

| 資料庫 | 證據 |
| --- | --- |
| SQL Server | 專案檔有 `Microsoft.Data.SqlClient`、`System.Data.SqlClient` 或 `Microsoft.EntityFrameworkCore.SqlServer` 的 `PackageReference` |
| Oracle | 專案檔有 `Oracle.ManagedDataAccess.Core`、`Oracle.ManagedDataAccess` 或 `Oracle.EntityFrameworkCore` 的 `PackageReference` |

非 .NET 專案以本輪要撰寫的 SQL 方言為準。

### 讀取與詢問

- 讀取：本 skill 載入且本輪工作涉及該資料庫時，讀取對應的鍵。修改程式與產生 SQL 查詢都適用。
- 詢問：鍵缺少時依 `ai-profile`「一次問完」詢問，必答。選項為合法值，推薦答案為「開發機版本」取得的值；詢問 `target.sqlserver` 時一併列出選填的 `target.sqlserver.compat`。
- 臨時查詢：沒有專案根目錄時照樣詢問，答案只用於本輪，不寫入任何檔案。
- 非互動執行端：依 `ai-profile`「非互動執行端」處理。
- 審查既有 SQL：鍵存在時依鍵檢查版本相容；鍵缺少時不詢問、不阻擋，並在審查報告標示「未確認目標版本」。
- `compat` 已設定而 `target.sqlserver` 缺少：先詢問引擎版本，保留 `compat` 的值。
- `compat` 超出該引擎版本的可設定範圍（見 `references/sqlserver.md`）：視同值錯誤，停止 SQL Server 版本相關工作並指出錯誤位置。

### 載入參考檔

| 鍵狀態 | 載入的檔案 |
| --- | --- |
| `target.sqlserver` 已設定 | 本文件，加上 `references/sqlserver.md` |
| `target.oracle` 已設定 | 本文件，加上 `references/oracle.md` |
| 缺少且使用者已略過 | 依涉及的資料庫載入同一參考檔，並依「未確認目標版本」處置 |
| 缺少 | 依「讀取與詢問」詢問；取得答案或使用者略過後依上列載入 |
| 未知值 | 依 `ai-profile` 視為值錯誤，停止並指出錯誤位置，不載入參考檔，不猜測，不修改檔案 |

載入哪個參考檔由涉及的資料庫決定，鍵值只決定檔內各列的判讀結果。同一輪涉及兩種資料庫時兩檔都載入。參考檔讀取失敗時，停止該資料庫的版本相關工作並回報路徑，不憑記憶補足。

排查查詢變慢、查詢被阻塞或找出高成本 SQL 時，依資料庫另載入排查參考檔。這兩份與目標版本鍵無關，撰寫一般 SQL 時不載入。

| 資料庫 | 排查參考檔 |
| --- | --- |
| SQL Server | `references/sqlserver-troubleshooting.md` |
| Oracle | `references/oracle-troubleshooting.md` |

### 判讀方式

1. 取得有效版本：有效版本為鍵值。SQL Server 另有有效相容性層級，為 `target.sqlserver.compat` 的值；缺少時取參考檔「版本與相容性層級對照」表中該引擎版本的預設相容性層級。
2. 判定先後：版本先後以參考檔版本對照表的列順序為準，由上而下為由舊到新，不以字面數值比較。
3. 找出對應列：參考檔門檻表每一列描述一種完整用法。依本輪要寫的完整呼叫（含參數、子句與語意，例如「依指定順序彙總」）找出唯一對應的列，不把多列的結果合併。
4. 判讀支援條件：該列「支援條件」的每個條件都成立才算有支援。引擎版本條件以有效版本不早於該版本為成立；相容性層級條件以有效相容性層級不低於該值為成立；鍵無法表達的條件（例如資料庫參數）在無法確認時視為不成立。
5. 選用寫法：有支援時採「有支援時的寫法」；不支援時採該列「不支援時的替代寫法」，不使用該用法。
6. 處理更新層級：條件帶更新層級（例如 Service Pack）時，鍵值只能表達產品版本，因此在該產品版本判定為不成立。
7. 處理未收錄用法：參考檔沒有對應的列時，不憑記憶斷言版本，改用標準 SQL 寫法，或在回覆註明該語法未收錄版本資訊。條件中的版本標示不在版本對照表時，視該列無效並回報。
8. 註明依據：選定與版本相關的寫法後，回覆以一句話註明所依的目標版本。

### 已移除或棄用的用法

參考檔「已移除或棄用的用法」節列出在較新版本被移除，或已棄用、將於未來版本移除的用法。目標版本鍵記的是正式環境的最低版本，只依它判定，會讓程式在升級後失效，因此這張表不套用「判讀方式」。

- 撰寫新 SQL：表中用法一律不用，與目標版本無關，改用該列的替代寫法。
- 審查既有 SQL：命中表中用法時依有效版本標示。失效條件在有效版本已成立時標示「目標版本已不支援」；尚未成立時標示「升級至 <失效版本> 後失效」；狀態為棄用時標示「棄用，未來版本移除」。三者都附該列的替代寫法。
- 新增識別字：避開參考檔「保留字」節指向的官方保留字與未來保留字清單。既有識別字與保留字衝突時，SQL Server 以 `[]`、Oracle 以雙引號包住，不改名。

### 未確認目標版本

使用者明確略過詢問時，假定目標為參考檔版本對照表的第一列（最舊的合法值）及其預設相容性層級，依「判讀方式」判讀，不使用在該版本支援條件不成立的用法，並在回覆註明「未確認目標版本」。同一 Session 內再次涉及時，依 `ai-profile`「一次問完」的既有規則重新列出。

### 開發機版本

- 取得：有 mcp-sql-server 或 mcp-oracle 連線時，執行參考檔「開發機版本查詢」節的查詢，依該節的對映規則轉成合法值，作為詢問時的推薦答案。
- 提醒：目標鍵已設定且與開發機版本不一致時，本 Session 提醒一次，不阻擋工作，不改寫鍵值。
- 失敗：查詢失敗、沒有連線、多個連線無法判定或結果無法對映合法值時，不附推薦值，照常詢問，不重試。

## 共通規範

以下規範對 SQL Server 與 Oracle 皆適用。範例的參數以 SQL Server 的 `@name` 表示，Oracle 改用 `:name` bind 變數。

### 查詢格式與可讀性

- **關鍵字大寫**：`SELECT`、`FROM`、`WHERE`、`JOIN`、`ON`、`GROUP BY`、`ORDER BY`、`INSERT`、`UPDATE`、`DELETE` 等 SQL 關鍵字一律大寫。
- **內建函式名大寫**：`COUNT`、`SUM` 等內建函式名一律大寫，與關鍵字風格一致。資料庫專屬函式同樣適用，例如 SQL Server 的 `GETDATE`、`ISNULL`，Oracle 的 `SYSDATE`、`NVL`。
- **縮排**：使用 4 個空格，不使用 Tab。
- **每個子句獨立一行**：`SELECT`、`FROM`、`WHERE`、`JOIN`、`GROUP BY`、`ORDER BY`、`HAVING` 各佔一行。
- **逗號前置**：多欄位 `SELECT` 時，逗號置於行首以利增刪欄位時的 diff 乾淨度。

```sql
SELECT
    o.OrderId
    ,o.OrderDate
    ,c.CustomerName
    ,SUM(d.Quantity * d.UnitPrice) AS TotalAmount
FROM Orders o
INNER JOIN Customers c
    ON o.CustomerId = c.CustomerId
INNER JOIN OrderDetails d
    ON o.OrderId = d.OrderId
WHERE o.OrderDate >= @StartDate
    AND o.Status = @Status
GROUP BY
    o.OrderId
    ,o.OrderDate
    ,c.CustomerName
HAVING SUM(d.Quantity * d.UnitPrice) > @MinAmount
ORDER BY o.OrderDate DESC;
```

### 識別字大小寫

- 資料表名與欄位名照定義時的原始大小寫書寫，不刻意全大寫或全小寫。
- SQL Server 預設依 collation 判斷識別字，一般不區分大小寫；Oracle 對未加雙引號的識別字有折疊行為，見 Oracle 專屬節的「識別字大小寫折疊」。

### 資料表與欄位別名

兩種別名採不同規則，此組合在 SQL Server 與 Oracle 皆合法且行為一致。

- **資料表別名一律不加 `AS`**：寫 `FROM Orders o`，不寫 `FROM Orders AS o`。Oracle 的資料表別名禁止加 `AS`（加了會回 `ORA-00933`），SQL Server 則加不加皆可，因此統一不加以求雙庫一致。
- **欄位別名一律加 `AS`**：寫 `SUM(...) AS TotalAmount`。`AS` 在此處是防呆哨兵，漏寫逗號時多欄位不會被靜默併成別名，而是直接語法錯誤，便於即時發現。
- **別名簡短且有意義**：資料表別名通常取名稱首字母小寫（如 `Orders o`、`CustomerAddresses ca`）。

```sql
-- ❌ 漏逗號時，若欄位別名不加 AS 會被靜默吃成別名，只回一欄
SELECT
    OrderId
    OrderDate
FROM Orders;

-- ✅ 欄位別名加 AS，同樣漏逗號會語法錯誤，立即暴露問題
SELECT
    OrderId
    OrderDate AS d
FROM Orders;
```

### SQL Injection 防範（Crucial）

- 所有來自應用程式的查詢**必須**使用參數化查詢，禁止字串串接。
- 預存程序與動態 SQL 內部同樣禁止把外部輸入串接進 SQL 文字。各資料庫的參數化機制見對應專屬節（SQL Server 用 `sp_executesql`，Oracle 用 Bind Variables）。

### 索引友善查詢（Crucial）

#### 避免破壞索引的寫法

- **禁止對欄位套用函式**後再比較，會導致索引失效：

```sql
-- ❌ 索引失效（T-SQL）
WHERE YEAR(OrderDate) = 2024
WHERE CONVERT(VARCHAR, OrderDate, 112) = '20240101'
WHERE ISNULL(Status, 0) = 1

-- ❌ 索引失效（Oracle）
WHERE EXTRACT(YEAR FROM OrderDate) = 2024
WHERE TO_CHAR(OrderDate, 'YYYYMMDD') = '20240101'
WHERE NVL(Status, 0) = 1

-- ✅ 索引友善（T-SQL）
WHERE OrderDate >= '2024-01-01' AND OrderDate < '2025-01-01'
WHERE Status = 1

-- ✅ 索引友善（Oracle）
WHERE OrderDate >= DATE '2024-01-01' AND OrderDate < DATE '2025-01-01'
WHERE Status = 1
```

- **禁止對欄位進行隱式型別轉換**：確保比較值的型別與欄位型別一致（如 `NVARCHAR` 欄位使用 `N'...'` 前綴）。

#### 萬用字元查詢

- `LIKE` 的前綴萬用字元（`LIKE '%keyword'`）無法使用索引，應盡量避免。
- 若需全文搜尋，建議使用 Full-Text Search 而非 `LIKE '%...%'`。

### SELECT 規範

- **禁止 `SELECT *`**：必須明確列出所需欄位，減少 I/O 開銷並避免結構變更時的隱性問題。
- **例外**：`EXISTS (SELECT 1 FROM ...)` 中的子查詢允許使用 `SELECT 1`。

### NULL 處理

- 比較 NULL 使用 `IS NULL` / `IS NOT NULL`，禁止 `= NULL`。
- 注意 `NOT IN` 與 NULL 值的陷阱：若子查詢可能回傳 NULL，改用 `NOT EXISTS`。

```sql
-- ❌ 當子查詢含 NULL 時，NOT IN 會回傳空結果
SELECT ProductId, ProductName, CategoryId FROM Products
WHERE CategoryId NOT IN (SELECT CategoryId FROM ExcludedCategories);

-- ✅ NOT EXISTS 不受 NULL 影響
SELECT p.ProductId, p.ProductName, p.CategoryId
FROM Products p
WHERE NOT EXISTS (
    SELECT 1
    FROM ExcludedCategories e
    WHERE e.CategoryId = p.CategoryId
);
```

### 分頁查詢

- 使用 `OFFSET ... FETCH NEXT` 語法，不使用舊式 `ROW_NUMBER()` 子查詢包裝。版本門檻與低於門檻的替代寫法見 references/sqlserver.md 與 references/oracle.md。
- SQL Server 的 `OFFSET` / `FETCH`、Oracle 的 `OFFSET ... FETCH` 分頁，以及低版本替代用的 `ROWNUM` 雙層查詢，都必須先建立唯一且穩定的 `ORDER BY`，非唯一欄位須追加 unique key。唯一排序鍵只固定單一資料快照內相同排序值的順序，不保證跨請求的資料集合一致。keyset pagination（seek method）可避免 offset 位移造成的部分頁面漂移，但不等於 snapshot。其排序鍵與 cursor 鍵必須不可變，鍵變更時視為新序列；資料列在 cursor 前後移動仍可能漏列或重複；它只能以前後 cursor 翻相鄰頁，無法任意跳頁。需要固定資料集合時，快照隔離必須涵蓋所有頁面的同一交易範圍，並使用與資料庫相容的隔離層級。

```sql
SELECT
    ProductId
    ,ProductName
FROM Products
ORDER BY ProductId
OFFSET @PageSize * (@PageNumber - 1) ROWS
FETCH NEXT @PageSize ROWS ONLY;
```

### 效能注意事項

- **避免巢狀子查詢過深**：超過 2 層的巢狀子查詢應考慮改用 CTE（`WITH`）或暫存資料表提升可讀性與效能。
- **大量資料操作**：`INSERT`、`UPDATE`、`DELETE` 大量資料列時，應分批處理（如每批 5,000～10,000 筆），避免長時間鎖定與交易日誌暴增。
- **UNION vs UNION ALL**：若不需要去重，使用 `UNION ALL`，避免不必要的排序開銷。

---

## SQL Server 專屬語法（T-SQL）

以下規則**僅適用於 SQL Server**，與共通規範不重疊。

### 動態 SQL 參數化

- 預存程序內部的動態 SQL 必須使用 `sp_executesql` 搭配參數，禁止 `EXEC('SELECT ...' + @input)`：

```sql
-- ✅ 正確
EXEC sp_executesql
    N'SELECT ProductId, ProductName FROM Products WHERE CategoryId = @CategoryId',
    N'@CategoryId INT',
    @CategoryId = @inputCategoryId;

-- ❌ 錯誤
EXEC('SELECT * FROM Products WHERE CategoryId = ' + @inputCategoryId);
```

### 日期時間型別與區間查詢

| 型別 | 範圍 | 精度 |
| --- | --- | --- |
| `datetime` | 1753-01-01 ~ 9999-12-31 | 3.33 毫秒，毫秒尾數只有 `0`、`3`、`7`，會進位 |
| `smalldatetime` | 1900-01-01 ~ 2079-06-06 | 1 分鐘，秒數四捨五入進位到分 |
| `datetime2` | 0001-01-01 ~ 9999-12-31 | 100 奈秒，可自訂 0~7 位小數，預設 `7` |
| `datetimeoffset` | 0001-01-01 ~ 9999-12-31 | 同 `datetime2`，另含時區偏移 |

- 新欄位使用 `datetime2`，有時區需求用 `datetimeoffset`。Oracle 遷移的資料常有早於 1753 年的日期，寫入 `datetime` 會失敗。
- `datetime` 會進位，`'2026-02-10 07:59:59.999'` 會被進位成 `'2026-02-10 08:00:00.000'`，拿它查整點資料會查到。
- ADO.NET 未指定 `Parameter` 型別時，`DateTime` 預設對應 `datetime`。Dapper 底層走 ADO.NET，行為相同。以這種參數查 `datetime2(7)` 欄位，欄位值不在 `datetime` 的 1/300 秒刻度上時，參數端被進位而欄位是原值，同一個值會查不到；明確指定參數型別為 `DbType.DateTime2`。
- 以 `datetime2` 參數查 `datetime` 欄位，`=` 的執行計畫不受影響，`<=` 與 `<` 等範圍比較的計畫會明顯變差。參數型別與欄位型別保持一致。
- `datetime` 與 `datetime2` 混合比較的結果會隨相容性層級改變，差異見 `references/sqlserver.md`「相容性層級的語意差異」。無法避免混合比較時，明確以 `CAST(... AS datetime2)` 轉型。
- 時間區間一律寫 `>= 起始 AND < 結束`，不寫 `<= 結束.AddTicks(-1)`。`AddTicks(-1)` 操作的是 100 奈秒，欄位精度低於 `(7)` 時會進位到結束時間本身，誤含下一秒的資料。半開區間同時適用 `date`、`time` 與 `datetime2`。

```csharp
// ❌ 欄位精度不是 (7) 時，endTime 會被進位，誤含結束時間的資料
DateTime endTime = input.EndTime.AddTicks(-1);
db.Table.Where(x => x.Time >= input.StartTime && x.Time <= endTime);

// ✅ 半開區間
db.Table.Where(x => x.Time >= input.StartTime && x.Time < input.EndTime);
```

### 交易與鎖定

- 讀取被寫入阻塞時，優先評估在資料庫開啟 RCSI（`ALTER DATABASE ... SET READ_COMMITTED_SNAPSHOT ON`），而非在查詢逐一加 hint。RCSI 讓 READ COMMITTED 的讀取改讀寫入前最後一個已提交版本，一般 DML 寫入不再擋住讀取；堆積上的最佳化大量載入與結構描述鎖（例如 DDL）仍可能阻塞查詢。
  - RCSI 是資料庫層級設定，開啟後所有以 READ COMMITTED 執行的查詢都改為快照讀取（連線未變更隔離等級時即為 READ COMMITTED），無法只套用部分資料表；個別資料表需要鎖定讀取時加 `WITH (READCOMMITTEDLOCK)`。需要選擇性使用快照時改用 Snapshot Isolation，資料庫先開啟 `ALLOW_SNAPSHOT_ISOLATION`，再在交易顯式指定 `IsolationLevel.Snapshot`。
  - RCSI 需要存放資料列版本。未啟用 Accelerated Database Recovery（ADR）時版本存放在 TempDB，開啟前確認 TempDB 空間與 I/O 能負擔；啟用 ADR 的資料庫改存放在該使用者資料庫的 persistent version store，ADR 的版本門檻見 `references/sqlserver.md`。Azure SQL Database 預設開啟 RCSI。
  - RCSI 只解決讀取被阻塞，不處理兩人同時修改同一筆的更新衝突，該情境仍以 RowVersion 樂觀並發控制處理。
- 無法開啟 RCSI 時，依需求選用 table hint。三者都只改變自己這一側遇到鎖定時的行為（`NOLOCK`、`READPAST` 繞過，`NOWAIT` 立即失敗），阻塞的根因在持有鎖定的交易，仍需另行處理。

| Hint | 行為 | 適用情境 |
| --- | --- | --- |
| `WITH (NOLOCK)` | 讀取未提交的資料（Dirty Read），可能讀到交易做到一半的中間狀態 | 僅限可容忍髒讀的報表查詢；取出資料準備異動時禁用 |
| `WITH (READPAST)` | 跳過被鎖住的資料列，結果會少資料 | Queue 取件；不適合報表。只跳過資料列層級鎖定，頁面或資料表鎖定仍會擋住；只能在 `READ COMMITTED` 或 `REPEATABLE READ` 隔離等級使用 |
| `WITH (NOWAIT)` | 遇到鎖定立即回傳錯誤，不等待 | 寧可失敗也不要長時間阻塞的查詢，呼叫端需處理錯誤；與 `TABLOCK` 併用時不生效，該情境改用 `SET LOCK_TIMEOUT 0` |

- 更新操作若涉及先讀後寫，考慮使用 `UPDLOCK` 或適當的隔離等級防止競爭條件。
- Oracle 採 MVCC 多版本讀一致性，讀取不阻塞寫入，無 `NOLOCK` 對應語法，本節不套用於 Oracle。

### Parameter Sniffing

SQL Server 第一次編譯參數化查詢時，依當下傳入的參數值估算筆數並快取計畫，在重新編譯或計畫被清除前，後續不同參數值重用同一份計畫。參數值對應的資料量落差極大時，重用的計畫會讓其中一方效能崩潰，例如 `@Status = 0` 對到 10 筆、`@Status = 1` 對到 500 萬筆。判定依據是參數值對應的資料量落差，與參數值本身的數值大小無關。

- 只有預存程序、透過 `sp_executesql` 送出的查詢與 prepared 查詢會被嗅探。.NET 的參數化查詢（`SqlCommand` 搭配 `SqlParameter`、Dapper、EF Core）在伺服器端以 `sp_executesql` 執行，呼叫 `SqlCommand.Prepare()` 時則以 `sp_prepexec` 等 prepared 方式執行，兩者都屬於會被嗅探的範圍。
- 重現或比較時，以 `sp_executesql` 作為參數化的一側，不用 `DECLARE` 區域變數。區域變數在編譯期看不到值（加了 `OPTION (RECOMPILE)` 時例外），最佳化器改用統計資料的平均密度估算，沒有統計資料時改用啟發式估算，行為接近 `OPTIMIZE FOR UNKNOWN`，比出來的差異與 Parameter Sniffing 無關。
- 處理方式依查詢性質選擇：

| 方式 | 作法 | 代價 |
| --- | --- | --- |
| `OPTION (OPTIMIZE FOR (@p = value))` | 針對大宗值產生計畫 | 小眾值被迫使用大宗值的計畫而變慢，資料量大時可搭配篩選索引 |
| `OPTION (OPTIMIZE FOR UNKNOWN)` | 改用欄位統計分佈的平均值產生中庸計畫 | 計畫不再針對任何特定值最佳化 |
| `OPTION (RECOMPILE)` | 每次執行依當下參數重新編譯 | 增加 CPU 編譯成本，適合執行頻率低、參數組合複雜的報表，不適合高併發 OLTP |
| Parameter Sensitive Plan 最佳化 | 由引擎為同一查詢依參數分派多份計畫，查詢不需改寫 | 只支援等號述詞，最多挑選三個述詞；版本、相容性層級門檻與各層級的述詞挑選差異見 `references/sqlserver.md` |
| Query Store 強制計畫 | 將穩定的計畫固定下來 | 需啟用 Query Store，設定注意事項見 `references/sqlserver-troubleshooting.md` |

找出受影響的查詢與清除計畫快取的方式，見 `references/sqlserver-troubleshooting.md`。

### 索引設計

- 叢集索引鍵選擇窄且不可變的欄位。每個非叢集索引的每一列都存一份叢集索引鍵作為 row locator，鍵多寬，表上所有非叢集索引就跟著多寬。以 16 bytes 的 `uniqueidentifier` 取代 4 bytes 的 `int`，多出的 12 bytes 大致按「資料列數 × 非叢集索引數」放大。
- 叢集索引未宣告 `UNIQUE` 時，引擎會在索引鍵後補上 4 bytes 的 uniqueifier，同樣會放大到所有非叢集索引。
- 更新叢集索引鍵的值，等於連帶改掉所有非叢集索引的 row locator，成本遠高於更新一般欄位。
- 非叢集索引已包含叢集索引鍵，查詢只取索引鍵欄位加叢集索引鍵時不必回查資料頁，叢集索引鍵不必寫進 `INCLUDE`。非唯一的非叢集索引會把叢集索引鍵補在索引鍵尾端，中間層頁面也跟著變寬；唯一的非叢集索引只補成 included column。同一欄位不會存兩份，叢集索引鍵已寫在非叢集索引定義裡時不會再補。
- GUID 作為叢集索引鍵時，除了寬度，非遞增的值會插入索引中間造成頁面分割，需改用循序產生的 GUID。
- 遺漏索引建議（執行計畫提示或 `sys.dm_db_missing_index_*`）不照單全收。它只建議非叢集索引、不指定索引鍵的欄位順序，也不替大量 included column 做成本效益分析；多個建議常可整併，過多索引會降低寫入效能。

---

## Oracle 專屬語法（Oracle SQL / PL/SQL）

以下規則**僅適用於 Oracle 資料庫**，與共通規範及 SQL Server 節不重疊。Oracle 的語法錯誤多來自「把 SQL Server（T-SQL）習慣反射套用到 Oracle」，本節先以對照表列出高頻直譯錯誤。語意陷阱（空字串與 NULL、提交行為、`ROWNUM` 與排序、日期隱式轉換）見 references/oracle.md「語意陷阱」，撰寫或審查 Oracle SQL 前必讀。

### T-SQL 習慣 → Oracle 正解對照

下列 T-SQL 寫法在 Oracle 不存在或行為不同，撰寫 Oracle SQL 時直接改用右欄：

| T-SQL（反射寫法） | Oracle 正解 | 說明 |
| --- | --- | --- |
| `ISNULL(x, y)` | `NVL(x, y)` / `COALESCE(x, y)` | NULL 取代；Oracle 不支援 `ISNULL` |
| `GETDATE()` | `SYSDATE` / `SYSTIMESTAMP` | 目前時間 |
| `LEN(x)` | `LENGTH(x)` | 字串長度；`LEN` 不計尾端空白，`LENGTH` 會計入，需要相同結果時用 `CASE WHEN x IS NULL THEN NULL ELSE NVL(LENGTH(RTRIM(x)), 0) END`（全空白字串經 `RTRIM` 後為 NULL；Oracle 的 `''` 即 NULL，原值為 `''` 時結果為 NULL） |
| `CHARINDEX(sub, x)` | `INSTR(x, sub)` | 子字串位置，注意參數順序相反 |
| `SUBSTRING(x, s, l)` | `SUBSTR(x, s, l)` | 擷取子字串 |
| `a + b`（字串） | `a || b` | 字串串接；Oracle 的 `+` 用於數值與日期算術，不能串接字串 |
| `SELECT TOP n ...` | `... FETCH FIRST n ROWS ONLY` | 限制筆數（版本門檻見 references/oracle.md） |
| `VARCHAR` / `INT` | `VARCHAR2` / `NUMBER(p, 0)` | 常用型別；Oracle 也接受 `VARCHAR`、`INT`，字串一律寫 `VARCHAR2`，整數寫 `NUMBER(p, 0)` |

- NULL 合併優先使用標準 SQL 的 `COALESCE`，`NVL` 為 Oracle 專屬。

```sql
SELECT FirstName || ' ' || LastName AS FullName FROM Employees;
```

### 識別字大小寫折疊

- 未加雙引號的識別字，Oracle 一律折疊為大寫儲存與比對。`SELECT id FROM orders` 與 `SELECT ID FROM ORDERS` 等價。
- 加了雙引號的識別字，Oracle 區分大小寫，且之後每次引用都必須完全比對。若建表時寫 `"OrderId"`，後續一律要用 `"OrderId"`；寫成 `OrderId`（未加引號會被折成 `ORDERID`）會找不到欄位。
- 建議除非有明確理由，避免對識別字加雙引號，以免被迫全程帶引號。

### 動態 SQL 參數化

- 動態 SQL 使用 **Bind Variables**（`:paramName`），禁止字串串接：

```sql
-- ✅ 正確
EXECUTE IMMEDIATE 'SELECT ProductName FROM Products WHERE ProductId = :pid'
    INTO v_product_name
    USING v_product_id;

-- ❌ 錯誤
EXECUTE IMMEDIATE 'SELECT ProductName FROM Products WHERE ProductId = ' || v_product_id
    INTO v_product_name;
```

### 分頁查詢

- Oracle 使用 `OFFSET ... FETCH NEXT`（與共通規範的分頁語法相同，版本門檻與替代寫法見 references/oracle.md）：

```sql
SELECT ProductId, ProductName
FROM Products
ORDER BY ProductId
OFFSET :offset ROWS
FETCH NEXT :page_size ROWS ONLY;
```

### 自動編號（SEQUENCE）

- 使用 `SEQUENCE` 搭配 `NEXTVAL`（`IDENTITY` 欄位的版本門檻見 references/oracle.md）：

```sql
CREATE SEQUENCE seq_products START WITH 1 INCREMENT BY 1 NOCACHE;

INSERT INTO Products (ProductId, ProductName)
VALUES (seq_products.NEXTVAL, :product_name);
```

### 日期與字串轉換

- 日期格式轉換使用 `TO_DATE` / `TO_CHAR`，必須明確指定格式遮罩：

```sql
-- 字串轉日期
WHERE OrderDate >= TO_DATE(:date_str, 'YYYY-MM-DD')

-- 日期轉字串
SELECT TO_CHAR(OrderDate, 'YYYY-MM-DD HH24:MI:SS') AS FormattedDate
FROM Orders;
```

### Unicode 參數型別（.NET 驅動）

- 以 Dapper 搭配 `Oracle.ManagedDataAccess.Core` 寫入 `NVARCHAR2` 欄位時，`DbType.String` 會被對應到 `OracleDbType.Varchar2` 而非 `OracleDbType.NVarchar2`。資料庫字元集無法表示該字元時（例如不是 AL32UTF8），簡體中文等 Unicode 字元會變成亂碼；AL32UTF8 資料庫的 `VARCHAR2` 本身可儲存 Unicode 字元。
- 寫入 `NVARCHAR2` 欄位的參數改以 `OracleParameter` 指定 `OracleDbType = OracleDbType.NVarchar2`。Dapper 的 `DynamicParameters` 不直接接受 `IDbDataParameter`，以實作 `SqlMapper.IDynamicParameters` 的參數類別，或以實作 `SqlMapper.ICustomQueryParameter` 的值傳入 `DynamicParameters.Add()`，把 `OracleParameter` 加進 `IDbCommand.Parameters`。

### Function-Based Index

條件欄位被函式包住（例如 `UPPER(TRIM(STATUS)) = 'A'`）時，原欄位的 B-Tree 索引對不上運算式。資料本身乾淨時直接比對原欄位；無法改寫條件時，對運算式建立 Function-Based Index：

```sql
CREATE INDEX IX_ORDERS_STATUS_UPPER
ON ORDERS (UPPER(TRIM(STATUS)));

EXEC DBMS_STATS.GATHER_TABLE_STATS(ownname => 'APP', tabname => 'ORDERS');
```

- 查詢條件的運算式必須與索引定義相同。Oracle 比對剖析後的運算式，大小寫與空白差異不影響，但 `UPPER(TRIM(STATUS))` 的索引接不住只寫 `UPPER(STATUS)` 的條件。
- 索引運算式含自訂函式時，該函式必須宣告為 `DETERMINISTIC`，否則建立索引會被擋下。
- 建立後收集統計資訊，Optimizer 才有依據評估是否使用。

### DUAL 虛擬資料表

- 計算純運算式時使用 `FROM DUAL`，各版本皆可用。省略 `FROM` 的寫法有版本門檻，見 references/oracle.md：

```sql
SELECT SYSDATE FROM DUAL;
SELECT seq_products.NEXTVAL FROM DUAL;
```

### 交易提交範例

- Oracle DML 需顯式 `COMMIT`，程序性批次操作以 `BEGIN ... END;` 包裝並明確提交或回滾：

```plsql
BEGIN
    UPDATE Orders SET Status = :new_status
    WHERE OrderId = :order_id;
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END;
```
