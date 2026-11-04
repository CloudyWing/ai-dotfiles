# SQL Server 版本資料

本輪工作涉及 SQL Server 時載入本檔，判讀方式依 `sql-query` SKILL.md「目標版本」的「判讀方式」。最後查證日：2026-11-04。

## 版本與相容性層級對照

列由舊到新，「標示」欄即 `target.sqlserver` 的合法值。

| 標示 | 產品主版本號 | 預設相容性層級 | 可設定相容性層級 | 來源 |
| --- | --- | --- | --- | --- |
| `2012` | 11 | 110 | 90、100、110 | [ALTER DATABASE compatibility level](https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-compatibility-level) |
| `2014` | 12 | 120 | 100、110、120 | [ALTER DATABASE compatibility level](https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-compatibility-level) |
| `2016` | 13 | 130 | 100、110、120、130 | [ALTER DATABASE compatibility level](https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-compatibility-level) |
| `2017` | 14 | 140 | 100、110、120、130、140 | [ALTER DATABASE compatibility level](https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-compatibility-level) |
| `2019` | 15 | 150 | 100、110、120、130、140、150 | [ALTER DATABASE compatibility level](https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-compatibility-level) |
| `2022` | 16 | 160 | 100、110、120、130、140、150、160 | [ALTER DATABASE compatibility level](https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-compatibility-level) |
| `2025` | 17 | 170 | 100、110、120、130、140、150、160、170 | [ALTER DATABASE compatibility level](https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-compatibility-level) |

`target.sqlserver.compat` 的值必須在該列「可設定相容性層級」內，超出時視為值錯誤。

## 功能版本門檻

| 用法 | 支援條件 | 有支援時的寫法 | 不支援時的替代寫法 | 來源 |
| --- | --- | --- | --- | --- |
| `OFFSET ... FETCH` 分頁 | 引擎 `2012` | `sql-query` 共通規範「分頁查詢」的寫法 | 合法值下限即為門檻，不需替代寫法 | [ORDER BY clause](https://learn.microsoft.com/en-us/sql/t-sql/queries/select-order-by-clause-transact-sql) |
| 字串彙總，不指定順序 | 引擎 `2017` | `STRING_AGG(expr, separator)` | `FOR XML PATH` 搭配 `STUFF`，省略子查詢的 `ORDER BY`，見「替代寫法」 | [STRING_AGG](https://learn.microsoft.com/en-us/sql/t-sql/functions/string-agg-transact-sql) |
| 字串彙總，依指定順序 | 引擎 `2017`，且相容性層級 110 以上 | `STRING_AGG(expr, separator) WITHIN GROUP (ORDER BY ...)` | `FOR XML PATH` 搭配 `STUFF`，順序寫在子查詢的 `ORDER BY`，見「替代寫法」 | [STRING_AGG](https://learn.microsoft.com/en-us/sql/t-sql/functions/string-agg-transact-sql) |
| 去除前後空白 | 引擎 `2017` | `TRIM(expr)` | `LTRIM(RTRIM(expr))`，見「替代寫法」 | [TRIM](https://learn.microsoft.com/en-us/sql/t-sql/functions/trim-transact-sql) |
| 只去除開頭或只去除結尾的空白 | 引擎 `2012` | 開頭用 `LTRIM(expr)`，結尾用 `RTRIM(expr)` | 合法值下限即為門檻，不需替代寫法 | [LTRIM](https://learn.microsoft.com/en-us/previous-versions/sql/sql-server-2012/ms177827(v=sql.110))、[RTRIM](https://learn.microsoft.com/en-us/previous-versions/sql/sql-server-2012/ms178660(v=sql.110)) |
| 去除指定字元（`LEADING`、`TRAILING`、`BOTH`） | 引擎 `2022`，且相容性層級 160 以上 | `TRIM(LEADING 'x' FROM expr)` | 本檔未收錄替代寫法，回覆註明 | [TRIM](https://learn.microsoft.com/en-us/sql/t-sql/functions/trim-transact-sql) |
| `CREATE OR ALTER` | 引擎 `2016` SP1（依判讀方式第 6 點，`2016` 判定為不成立） | `CREATE OR ALTER PROCEDURE ...`；僅限支援的物件類型 | `IF OBJECT_ID` 判斷後 `DROP`，再 `CREATE`，見「替代寫法」 | [ScriptingOptions.ScriptForCreateOrAlter](https://learn.microsoft.com/en-us/dotnet/api/microsoft.sqlserver.management.smo.scriptingoptions.scriptforcreateoralter) |
| `DROP TABLE IF EXISTS` | 引擎 `2016` | `DROP TABLE IF EXISTS dbo.TableName;` | `IF OBJECT_ID(..., N'U') IS NOT NULL DROP TABLE ...`，見「替代寫法」 | [DROP TABLE](https://learn.microsoft.com/en-us/sql/t-sql/statements/drop-table-transact-sql) |
| `GREATEST`、`LEAST` | 引擎 `2022` | `GREATEST(a, b)`、`LEAST(a, b)` | `CASE` 運算式，見「替代寫法」 | [What's new in SQL Server 2022](https://learn.microsoft.com/en-us/sql/sql-server/what-s-new-in-sql-server-2022) |
| 字串拆分，不依賴輸出順序 | 相容性層級 130 以上 | `STRING_SPLIT(expr, separator)` | 本檔未收錄替代寫法，回覆註明 | [STRING_SPLIT](https://learn.microsoft.com/en-us/sql/t-sql/functions/string-split-transact-sql) |
| 字串拆分，保留原始順序 | 引擎 `2022`，且相容性層級 130 以上 | `STRING_SPLIT(expr, separator, 1)`，以 `ordinal` 欄排序 | 本檔未收錄替代寫法；改由應用程式端拆分，並在回覆註明 | [STRING_SPLIT](https://learn.microsoft.com/en-us/sql/t-sql/functions/string-split-transact-sql) |

每一列描述一種完整用法，「支援條件」列出的條件全部成立才算有支援。`DROP ... IF EXISTS` 的查證範圍只涵蓋 `TABLE`，其他物件類型不依本列判定。

## 替代寫法

以下寫法所依賴的語法在合法值下限 `2012` 皆可用，來源為 SQL Server 2012 封存文件。

### 字串彙總（取代 `STRING_AGG`）

依賴 [FOR XML PATH](https://learn.microsoft.com/en-us/previous-versions/sql/sql-server-2012/ms189885(v=sql.110))、[STUFF](https://learn.microsoft.com/en-us/previous-versions/sql/sql-server-2012/ms188043(v=sql.110)) 與 [xml value() 方法](https://learn.microsoft.com/en-us/previous-versions/sql/sql-server-2012/ms178030(v=sql.110))。

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

依賴 [LTRIM](https://learn.microsoft.com/en-us/previous-versions/sql/sql-server-2012/ms177827(v=sql.110)) 與 [RTRIM](https://learn.microsoft.com/en-us/previous-versions/sql/sql-server-2012/ms178660(v=sql.110))。

```sql
SELECT LTRIM(RTRIM(c.CustomerName)) AS CustomerName
FROM Customers c;
```

### 取較大值（取代 `GREATEST`、`LEAST`）

依賴 [CASE](https://learn.microsoft.com/en-us/previous-versions/sql/sql-server-2012/ms181765(v=sql.110))。

```sql
SELECT
    o.OrderId
    ,CASE
        WHEN o.ShippedAmount >= o.InvoicedAmount THEN o.ShippedAmount
        ELSE o.InvoicedAmount
    END AS MaxAmount
FROM Orders o;
```

- 任一運算元為 NULL 時，比較結果不成立而落入 `ELSE`。運算元可能為 NULL 時，先以 `COALESCE` 決定 NULL 的取值。
- 取較小值時把 `>=` 改為 `<=`。

### 存在時刪除（取代 `DROP TABLE IF EXISTS` 與 `CREATE OR ALTER`）

依賴 [OBJECT_ID](https://learn.microsoft.com/en-us/previous-versions/sql/sql-server-2012/ms190328(v=sql.110))。第 2 個參數為物件類型，例如 `U` 為資料表、`P` 為預存程序。

```sql
IF OBJECT_ID(N'dbo.OrderArchive', N'U') IS NOT NULL
    DROP TABLE dbo.OrderArchive;
```

取代 `CREATE OR ALTER` 時，先依物件類型執行同樣的判斷與 `DROP`，再以 `CREATE` 重建。重建會移除該物件既有的權限設定，需在同一份腳本重新授權。

## 寫法注意事項

- `STRING_SPLIT` 未指定 `enable_ordinal` 時，不依賴輸出列的順序。資料庫啟用 `ALLOW_BUILTIN_TVF_IN_ALL_COMPAT_LEVELS` 時，相容性層級 130 的要求不適用，來源見 [STRING_SPLIT](https://learn.microsoft.com/en-us/sql/t-sql/functions/string-split-transact-sql)；無法確認該設定時依門檻表判定。

## 開發機版本查詢

| 用途 | 查詢 | 來源 |
| --- | --- | --- |
| 引擎完整版本 | `SELECT SERVERPROPERTY('ProductVersion') AS ProductVersion;` | [Determine which version of SQL Server](https://learn.microsoft.com/en-sg/troubleshoot/sql/releases/find-my-sql-version) |
| 引擎主版本 | `SELECT SERVERPROPERTY('ProductMajorVersion') AS ProductMajorVersion;` | [SERVERPROPERTY](https://learn.microsoft.com/en-us/sql/t-sql/functions/serverproperty-transact-sql) |
| 資料庫相容性層級 | `SELECT name, compatibility_level FROM sys.databases;` | [EF Core 8 breaking changes](https://learn.microsoft.com/en-us/ef/core/what-is-new/ef-core-8.0/breaking-changes) |

- 對映合法值：取 `ProductVersion` 第一個 `.` 之前的數字作為產品主版本號，對照「版本與相容性層級對照」的「產品主版本號」欄得到標示。取不到 `ProductMajorVersion` 時改用 `ProductVersion`。
- 相容性層級取本輪工作目標資料庫那一列的 `compatibility_level`。
- 主版本號不在對照表內時，視為無法對映，不附推薦值。
