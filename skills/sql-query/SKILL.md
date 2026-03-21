---
name: sql-query
description: 'T-SQL 查詢撰寫規範：參數化查詢、索引友善寫法、效能陷阱迴避與可讀性格式要求。'
---

# T-SQL 查詢撰寫規範

當使用者要求撰寫、檢視或最佳化 SQL 查詢（以 Microsoft SQL Server / T-SQL 為主）時，請自動套用以下規範。

## SQL Injection 防範（Crucial）

- 所有來自應用程式的查詢**必須**使用參數化查詢，禁止字串串接。
- 預存程序內部的動態 SQL 必須使用 `sp_executesql` 搭配參數，禁止 `EXEC('SELECT ...' + @input)`。

```sql
-- ✅ 正確
EXEC sp_executesql
    N'SELECT * FROM Products WHERE CategoryId = @CategoryId',
    N'@CategoryId INT',
    @CategoryId = @inputCategoryId;

-- ❌ 錯誤
EXEC('SELECT * FROM Products WHERE CategoryId = ' + @inputCategoryId);
```

## 查詢格式與可讀性

- **關鍵字大寫**：`SELECT`, `FROM`, `WHERE`, `JOIN`, `ON`, `GROUP BY`, `ORDER BY`, `INSERT`, `UPDATE`, `DELETE` 等 SQL 關鍵字一律大寫。
- **縮排**：使用 4 個空格，不使用 Tab。
- **每個子句獨立一行**：`SELECT`, `FROM`, `WHERE`, `JOIN`, `GROUP BY`, `ORDER BY`, `HAVING` 各佔一行。
- **逗號前置**：多欄位 `SELECT` 時，逗號置於行首以利增刪欄位時的 diff 乾淨度。

```sql
SELECT
    o.OrderId
    ,o.OrderDate
    ,c.CustomerName
    ,SUM(d.Quantity * d.UnitPrice) AS TotalAmount
FROM Orders AS o
INNER JOIN Customers AS c
    ON o.CustomerId = c.CustomerId
INNER JOIN OrderDetails AS d
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

## 資料表別名

- **必須**使用 `AS` 關鍵字指定別名（如 `Orders AS o`），不使用隱式別名（`Orders o`）。
- 別名應簡短且有意義，通常取資料表名稱的首字母小寫（如 `Orders AS o`、`CustomerAddresses AS ca`）。

## 索引友善查詢（Crucial）

### 避免破壞索引的寫法

- **禁止對欄位套用函式**後再比較，會導致索引失效：

```sql
-- ❌ 索引失效
WHERE YEAR(OrderDate) = 2024
WHERE CONVERT(VARCHAR, OrderDate, 112) = '20240101'
WHERE ISNULL(Status, 0) = 1

-- ✅ 索引友善
WHERE OrderDate >= '2024-01-01' AND OrderDate < '2025-01-01'
WHERE Status = 1
```

- **禁止對欄位進行隱式型別轉換**：確保比較值的型別與欄位型別一致（如 `NVARCHAR` 欄位使用 `N'...'` 前綴）。

### 萬用字元查詢

- `LIKE` 的前綴萬用字元（`LIKE '%keyword'`）無法使用索引，應盡量避免。
- 若需全文搜尋，建議使用 Full-Text Search 而非 `LIKE '%...%'`。

## SELECT 規範

- **禁止 `SELECT *`**：必須明確列出所需欄位，減少 I/O 開銷並避免結構變更時的隱性問題。
- **例外**：`EXISTS (SELECT 1 FROM ...)` 中的子查詢允許使用 `SELECT 1`。

## 分頁查詢

- 使用 `OFFSET ... FETCH NEXT` 語法（SQL Server 2012+），不使用舊式 `ROW_NUMBER()` 子查詢包裝。

```sql
SELECT
    ProductId
    ,ProductName
FROM Products
ORDER BY ProductId
OFFSET @PageSize * (@PageNumber - 1) ROWS
FETCH NEXT @PageSize ROWS ONLY;
```

## NULL 處理

- 比較 NULL 使用 `IS NULL` / `IS NOT NULL`，禁止 `= NULL`。
- 注意 `NOT IN` 與 NULL 值的陷阱：若子查詢可能回傳 NULL，改用 `NOT EXISTS`。

```sql
-- ❌ 當子查詢含 NULL 時，NOT IN 會回傳空結果
SELECT * FROM Products
WHERE CategoryId NOT IN (SELECT CategoryId FROM ExcludedCategories);

-- ✅ NOT EXISTS 不受 NULL 影響
SELECT p.*
FROM Products AS p
WHERE NOT EXISTS (
    SELECT 1
    FROM ExcludedCategories AS e
    WHERE e.CategoryId = p.CategoryId
);
```

## 交易與鎖定

- 長時間執行的查詢應評估是否需要 `WITH (NOLOCK)` 或 `READ UNCOMMITTED` 隔離等級（僅限可容忍 Dirty Read 的報表查詢）。
- 更新操作若涉及先讀後寫，考慮使用 `UPDLOCK` 或適當的隔離等級防止競爭條件。

## 效能注意事項

- **避免巢狀子查詢過深**：超過 2 層的巢狀子查詢應考慮改用 CTE (`WITH`) 或暫存資料表提升可讀性與效能。
- **大量資料操作**：`INSERT`, `UPDATE`, `DELETE` 大量資料列時，應分批處理（如每批 5,000～10,000 筆），避免長時間鎖定與交易日誌暴增。
- **UNION vs UNION ALL**：若不需要去重，使用 `UNION ALL`，避免不必要的排序開銷。
