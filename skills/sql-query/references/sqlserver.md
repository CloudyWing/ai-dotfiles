# SQL Server 版本資料

本輪工作涉及 SQL Server 時載入本檔，判讀方式依 `sql-query` SKILL.md「目標版本」的「判讀方式」。

## 版本與相容性層級對照

列由舊到新，「標示」欄即 `target.sqlserver` 的合法值。

| 標示 | 產品主版本號 | 預設相容性層級 | 可設定相容性層級 |
| --- | --- | --- | --- |
| `2012` | 11 | 110 | 90、100、110 |
| `2014` | 12 | 120 | 100、110、120 |
| `2016` | 13 | 130 | 100、110、120、130 |
| `2017` | 14 | 140 | 100、110、120、130、140 |
| `2019` | 15 | 150 | 100、110、120、130、140、150 |
| `2022` | 16 | 160 | 100、110、120、130、140、150、160 |
| `2025` | 17 | 170 | 100、110、120、130、140、150、160、170 |

`target.sqlserver.compat` 的值必須在該列「可設定相容性層級」內，超出時視為值錯誤。

## 功能版本門檻

| 用法 | 支援條件 | 有支援時的寫法 | 不支援時的替代寫法 |
| --- | --- | --- | --- |
| `OFFSET ... FETCH` 分頁 | 引擎 `2012` | `sql-query` 共通規範「分頁查詢」的寫法 | 合法值下限即為門檻，不需替代寫法 |
| 字串彙總，不指定順序 | 引擎 `2017` | `STRING_AGG(expr, separator)` | `FOR XML PATH` 搭配 `STUFF`，省略子查詢的 `ORDER BY`，見「替代寫法」 |
| 字串彙總，依指定順序 | 引擎 `2017`，且相容性層級 110 以上 | `STRING_AGG(expr, separator) WITHIN GROUP (ORDER BY ...)` | `FOR XML PATH` 搭配 `STUFF`，順序寫在子查詢的 `ORDER BY`，見「替代寫法」 |
| 去除前後空白 | 引擎 `2017` | `TRIM(expr)` | `LTRIM(RTRIM(expr))`，見「替代寫法」 |
| 只去除開頭或只去除結尾的空白 | 引擎 `2012` | 開頭用 `LTRIM(expr)`，結尾用 `RTRIM(expr)` | 合法值下限即為門檻，不需替代寫法 |
| 去除指定字元（`LEADING`、`TRAILING`、`BOTH`） | 引擎 `2022`，且相容性層級 160 以上 | `TRIM(LEADING 'x' FROM expr)` | 本檔沒有替代寫法，回覆註明 |
| `CREATE OR ALTER` | 引擎 `2016` SP1 | `CREATE OR ALTER PROCEDURE ...`；僅限支援的物件類型 | `IF OBJECT_ID` 判斷後 `DROP`，再 `CREATE`，見「替代寫法」 |
| `DROP TABLE IF EXISTS` | 引擎 `2016` | `DROP TABLE IF EXISTS dbo.TableName;` | `IF OBJECT_ID(..., N'U') IS NOT NULL DROP TABLE ...`，見「替代寫法」 |
| `GREATEST`、`LEAST` | 引擎 `2022` | `GREATEST(a, b)`、`LEAST(a, b)` | `CASE` 運算式，見「替代寫法」 |
| 字串拆分，不依賴輸出順序 | 引擎 `2016`，且相容性層級 130 以上 | `STRING_SPLIT(expr, separator)` | 本檔沒有替代寫法，回覆註明 |
| 字串拆分，保留原始順序 | 引擎 `2022`，且相容性層級 130 以上 | `STRING_SPLIT(expr, separator, 1)`，以 `ordinal` 欄排序 | 本檔沒有替代寫法；改由應用程式端拆分，並在回覆註明 |
| Accelerated Database Recovery（RCSI 的資料列版本改存使用者資料庫） | 引擎 `2019` | `ALTER DATABASE ... SET ACCELERATED_DATABASE_RECOVERY = ON` | 資料列版本存放在 TempDB，開啟 RCSI 前確認 TempDB 空間與 I/O |
| Parameter Sensitive Plan 最佳化 | 引擎 `2022`，且相容性層級 160 以上 | 引擎自動依參數分派計畫，查詢不需改寫；相容性層級 160 每個資料表參照只挑一個述詞，170 可對同一資料表挑多個述詞、每個欄位至多一個 | 依 SKILL.md「Parameter Sniffing」改用 `OPTIMIZE FOR` 或 `RECOMPILE` |

- 每一列描述一種完整用法，「支援條件」列出的條件全部成立才算有支援。
- 「`DROP TABLE IF EXISTS`」列只適用資料表。其他物件類型的 `DROP ... IF EXISTS` 依「判讀方式」的未收錄用法處理。
- `STRING_SPLIT` 未指定 `enable_ordinal` 時，不依賴輸出列的順序。資料庫啟用 `ALLOW_BUILTIN_TVF_IN_ALL_COMPAT_LEVELS` 時，相容性層級 130 的要求不適用；無法確認該設定時依門檻表判定。

## 已移除或棄用的用法

判讀方式依 `sql-query` SKILL.md「目標版本」的「已移除或棄用的用法」。「已移除」列的失效條件以引擎版本表示；`2012` 為合法值下限，代表所有合法目標版本都已不支援。

| 用法 | 狀態 | 失效條件 | 替代寫法 |
| --- | --- | --- | --- |
| `*=`、`=*` 非 ANSI 外部聯結 | 已移除 | 引擎 `2012` | `LEFT JOIN`、`RIGHT JOIN` 等 ANSI 聯結語法 |
| `COMPUTE`、`COMPUTE BY` | 已移除 | 引擎 `2012` | `GROUP BY` 搭配 `ROLLUP` |
| `RAISERROR integer 'string'` 舊式寫法 | 已移除 | 引擎 `2012` | `RAISERROR (msg, severity, state, ...)`，或 `THROW` |
| `FASTFIRSTROW` table hint | 已移除 | 引擎 `2012` | `OPTION (FAST n)` |
| `DATABASEPROPERTY` | 已移除 | 引擎 `2012` | `DATABASEPROPERTYEX` |
| `text`、`ntext`、`image` 型別 | 棄用 | 未定 | `varchar(max)`、`nvarchar(max)`、`varbinary(max)` |
| `READTEXT`、`WRITETEXT`、`UPDATETEXT` | 棄用 | 未定 | 大型值型別搭配 `UPDATE ... .WRITE` |
| `SET ROWCOUNT` 限制 `INSERT`、`UPDATE`、`DELETE` 筆數 | 棄用 | 未定 | 在該陳述式使用 `TOP` |
| `SET ANSI_NULLS OFF`、`SET ANSI_PADDING OFF`、`SET CONCAT_NULL_YIELDS_NULL OFF` | 棄用 | 未定 | 維持 `ON`，依 `ON` 的語意撰寫 |

## 保留字

- 保留字由資料庫相容性層級決定，某層級引入的保留字在更高層級仍保留。例如相容性層級 110 加入 `WITHIN GROUP`、`TRY_CONVERT` 等保留字。
- 官方保留字頁另列 ODBC 保留字與未來保留字，新增識別字時一併避開。
- 資料表或欄位名為 `NEXT`、別名為 `VALUE` 且省略 `AS` 時，`SELECT NEXT VALUE FROM ...` 會被解讀為序列的 `NEXT VALUE FOR` 而報錯。別名一律加 `AS`，寫成 `SELECT NEXT AS VALUE FROM ...`。

## 相容性層級的語意差異

下列行為的語法在各相容性層級都合法，結果則依有效相容性層級而不同。

- `datetime` 轉為 `datetime2` 或 `time`：相容性層級 130 以上把 `datetime` 的 1/300 秒刻度完整換算，`'1900-01-01 00:00:00.003'` 轉成 `datetime2(7)` 為 `.0033333`；低於 130 時為 `.0030000`。
- `datetime` 與 `datetime2` 比較：相容性層級 130 以上，`datetime` 值不再截到毫秒再比較，低於 130 時相等的值（例如 `datetime` 的 `.003` 與 `datetime2(3)` 的 `.003`）在 130 以上會變成不相等。
- `DATEPART`、`DATEDIFF` 對 `datetime` 使用 `MICROSECOND` 或 `NANOSECOND`：相容性層級 130 以上不再先截到毫秒，`.003` 的 `DATEPART(MICROSECOND, ...)` 由 `3000` 變為 `3333`。
- 資料庫的相容性層級從低於 130 調升時，持久化的運算結果（`CHECK` 條件約束涵蓋的資料、persisted computed column、引用 computed column 的索引、篩選索引、索引檢視）可能與新語意不一致，調升後重建受影響的結構。

## 替代寫法

以下寫法在合法值下限 `2012` 皆可用。

### 字串彙總（取代 `STRING_AGG`）

```sql
SELECT
    c.CustomerId
    ,STUFF((
        SELECT ',' + o.OrderNo
        FROM Orders o
        WHERE o.CustomerId = c.CustomerId
        ORDER BY o.OrderNo
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(MAX)'), 1, 1, '') AS OrderNos
FROM Customers c;
```

- 保留 `TYPE` 與 `.value(...)`。省略時結果以字串回傳並經過 XML 實體轉換，`&`、`<` 等字元會變成 `&amp;`、`&lt;`。
- `STUFF` 的第 3 個參數是分隔字串的長度，分隔字串改變時同步調整。

### 去除前後空白（取代 `TRIM`）

```sql
SELECT LTRIM(RTRIM(c.CustomerName)) AS CustomerName
FROM Customers c;
```

### 取較大值（取代 `GREATEST`、`LEAST`）

```sql
SELECT
    o.OrderId
    ,CASE
        WHEN o.ShippedAmount >= o.InvoicedAmount THEN o.ShippedAmount
        ELSE o.InvoicedAmount
    END AS MaxAmount
FROM Orders o;
```

- 任一運算元為 NULL 時，比較結果不成立而落入 `ELSE`。`GREATEST`、`LEAST` 會略過 NULL 參數，只有全部參數皆為 NULL 時才回傳 NULL。運算元可能為 NULL 且需要相同結果時，先分支處理 NULL，再比較非 NULL 值。
- 取較小值時把 `>=` 改為 `<=`。

### 存在時刪除（取代 `DROP TABLE IF EXISTS` 與 `CREATE OR ALTER`）

`OBJECT_ID` 的第 2 個參數為物件類型，例如 `U` 為資料表、`P` 為預存程序。

```sql
IF OBJECT_ID(N'dbo.OrderArchive', N'U') IS NOT NULL
    DROP TABLE dbo.OrderArchive;
```

取代 `CREATE OR ALTER` 時，先依物件類型執行同樣的判斷與 `DROP`，再以 `CREATE` 重建。`CREATE PROCEDURE`、`CREATE VIEW`、`CREATE FUNCTION`、`CREATE TRIGGER` 必須是批次中的唯一陳述式，`DROP` 與 `CREATE` 分成不同批次執行。`GO` 是 sqlcmd 與 SSMS 的批次分隔指令，不是 T-SQL 陳述式；從應用程式執行時改為分次送出。重建會移除該物件既有的權限設定，需在同一份腳本重新授權。

## 開發機版本查詢

| 用途 | 查詢 |
| --- | --- |
| 引擎完整版本 | `SELECT SERVERPROPERTY('ProductVersion') AS ProductVersion;` |
| 引擎主版本 | `SELECT SERVERPROPERTY('ProductMajorVersion') AS ProductMajorVersion;` |
| 資料庫相容性層級 | `SELECT name, compatibility_level FROM sys.databases;` |

- 對映合法值：取 `ProductVersion` 第一個 `.` 之前的數字作為產品主版本號，對照「版本與相容性層級對照」的「產品主版本號」欄得到標示。取不到 `ProductMajorVersion` 時改用 `ProductVersion`。
- 相容性層級取本輪工作目標資料庫那一列的 `compatibility_level`。
- 主版本號不在對照表內時，視為無法對映，不附推薦值。

## 來源

最後查證日：2026-11-05。每一列門檻與替代寫法對應的官方文件如下。

| 對象 | 來源 |
| --- | --- |
| 版本與相容性層級對照 | [ALTER DATABASE compatibility level](https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-compatibility-level) |
| `OFFSET ... FETCH` 分頁 | [ORDER BY clause](https://learn.microsoft.com/en-us/sql/t-sql/queries/select-order-by-clause-transact-sql) |
| 字串彙總（不指定順序、依指定順序） | [STRING_AGG](https://learn.microsoft.com/en-us/sql/t-sql/functions/string-agg-transact-sql) |
| 去除前後空白、去除指定字元 | [TRIM](https://learn.microsoft.com/en-us/sql/t-sql/functions/trim-transact-sql) |
| 只去除開頭或只去除結尾的空白 | [LTRIM（2012）](https://learn.microsoft.com/en-us/previous-versions/sql/sql-server-2012/ms177827(v=sql.110))、[RTRIM（2012）](https://learn.microsoft.com/en-us/previous-versions/sql/sql-server-2012/ms178660(v=sql.110)) |
| `CREATE OR ALTER` | [ScriptingOptions.ScriptForCreateOrAlter](https://learn.microsoft.com/en-us/dotnet/api/microsoft.sqlserver.management.smo.scriptingoptions.scriptforcreateoralter) |
| `DROP TABLE IF EXISTS` | [DROP TABLE](https://learn.microsoft.com/en-us/sql/t-sql/statements/drop-table-transact-sql) |
| `GREATEST`、`LEAST` | [What's new in SQL Server 2022](https://learn.microsoft.com/en-us/sql/sql-server/what-s-new-in-sql-server-2022)、[GREATEST](https://learn.microsoft.com/en-us/sql/t-sql/functions/logical-functions-greatest-transact-sql)、[LEAST](https://learn.microsoft.com/en-us/sql/t-sql/functions/logical-functions-least-transact-sql) |
| 字串拆分（不依賴輸出順序、保留原始順序）、`ALLOW_BUILTIN_TVF_IN_ALL_COMPAT_LEVELS` | [STRING_SPLIT](https://learn.microsoft.com/en-us/sql/t-sql/functions/string-split-transact-sql) |
| 已移除：`*=`、`COMPUTE`、舊式 `RAISERROR`、`FASTFIRSTROW`、`DATABASEPROPERTY` | [Discontinued Database Engine functionality，Discontinued Features in SQL Server 2012](https://learn.microsoft.com/en-us/previous-versions/sql/2014/database-engine/discontinued-database-engine-functionality-in-sql-server-2016) |
| 棄用：`text`、`ntext`、`image` | [ntext, text, and image](https://learn.microsoft.com/en-us/sql/t-sql/data-types/ntext-text-and-image-transact-sql) |
| 棄用：`READTEXT`、`WRITETEXT`、`UPDATETEXT` | [SQL Server, Deprecated Features object](https://learn.microsoft.com/en-us/sql/relational-databases/performance-monitor/sql-server-deprecated-features-object)、[WRITETEXT](https://learn.microsoft.com/en-us/sql/t-sql/queries/writetext-transact-sql)、[UPDATETEXT](https://learn.microsoft.com/en-us/sql/t-sql/queries/updatetext-transact-sql) |
| 棄用：`SET ROWCOUNT` 限制 DML | [SET ROWCOUNT](https://learn.microsoft.com/en-us/sql/t-sql/statements/set-rowcount-transact-sql) |
| 棄用：`SET ANSI_NULLS OFF` 等三項 | [Deprecated Database Engine features in SQL Server 2017](https://learn.microsoft.com/en-us/sql/database-engine/deprecated-database-engine-features-in-sql-server-2017) |
| 保留字與相容性層級 | [Reserved keywords](https://learn.microsoft.com/en-us/sql/t-sql/language-elements/reserved-keywords-transact-sql)、[ALTER DATABASE compatibility level](https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-compatibility-level) |
| 保留字：`NEXT VALUE` 別名 | [Assessment rules for SQL Server to Azure SQL Database，Next column](https://learn.microsoft.com/en-us/data-migration/sql-server/database/assessment-rules#next-column) |
| 相容性層級的語意差異 | [datetime2：Convert date and time data](https://learn.microsoft.com/en-us/sql/t-sql/data-types/datetime2-transact-sql#convert-date-and-time-data)、[Improvements in handling some data types and uncommon operations，Appendix A](https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/general/sql-server-azure-sql-database-improvements#appendix-a-changes-in-compatibility-level-130) |
| Accelerated Database Recovery | [Accelerated database recovery](https://learn.microsoft.com/en-us/sql/relational-databases/accelerated-database-recovery-concepts) |
| Parameter Sensitive Plan 最佳化 | [Parameter Sensitive Plan optimization](https://learn.microsoft.com/en-us/sql/relational-databases/performance/parameter-sensitive-plan-optimization) |
| 替代寫法：字串彙總 | [FOR XML PATH（2012）](https://learn.microsoft.com/en-us/previous-versions/sql/sql-server-2012/ms189885(v=sql.110))、[STUFF（2012）](https://learn.microsoft.com/en-us/previous-versions/sql/sql-server-2012/ms188043(v=sql.110))、[xml value() 方法（2012）](https://learn.microsoft.com/en-us/previous-versions/sql/sql-server-2012/ms178030(v=sql.110)) |
| 替代寫法：去除前後空白 | [LTRIM（2012）](https://learn.microsoft.com/en-us/previous-versions/sql/sql-server-2012/ms177827(v=sql.110))、[RTRIM（2012）](https://learn.microsoft.com/en-us/previous-versions/sql/sql-server-2012/ms178660(v=sql.110)) |
| 替代寫法：取較大值 | [CASE（2012）](https://learn.microsoft.com/en-us/previous-versions/sql/sql-server-2012/ms181765(v=sql.110))；NULL 語意差異見 [GREATEST](https://learn.microsoft.com/en-us/sql/t-sql/functions/logical-functions-greatest-transact-sql) |
| 替代寫法：存在時刪除 | [OBJECT_ID（2012）](https://learn.microsoft.com/en-us/previous-versions/sql/sql-server-2012/ms190328(v=sql.110))；批次限制見 [CREATE PROCEDURE](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-procedure-transact-sql) |
| 開發機查詢：引擎完整版本 | [Determine which version of SQL Server](https://learn.microsoft.com/en-sg/troubleshoot/sql/releases/find-my-sql-version) |
| 開發機查詢：引擎主版本 | [SERVERPROPERTY](https://learn.microsoft.com/en-us/sql/t-sql/functions/serverproperty-transact-sql) |
| 開發機查詢：資料庫相容性層級 | [EF Core 8 breaking changes](https://learn.microsoft.com/en-us/ef/core/what-is-new/ef-core-8.0/breaking-changes) |
