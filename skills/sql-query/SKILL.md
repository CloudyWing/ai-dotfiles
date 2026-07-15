---
name: sql-query
description: 'SQL 撰寫規範：參數化查詢、索引友善寫法、效能陷阱迴避與可讀性格式要求，涵蓋 SQL Server（T-SQL）與 Oracle 雙資料庫的語法差異與語意陷阱。當撰寫或審查原生 SQL 時自動套用。'
---

# SQL 撰寫規範

本規範涵蓋 SQL Server（T-SQL）與 Oracle 兩種資料庫的原生 SQL 撰寫，內容包含查詢、DML、交易與可讀性格式。規範分三層，先列兩庫共通規範，再分列 SQL Server 專屬與 Oracle 專屬語法。撰寫或審查原生 SQL 時自動套用。

## 共通規範

以下規範對 SQL Server 與 Oracle 皆適用。

### 查詢格式與可讀性

- **關鍵字大寫**：`SELECT`、`FROM`、`WHERE`、`JOIN`、`ON`、`GROUP BY`、`ORDER BY`、`INSERT`、`UPDATE`、`DELETE` 等 SQL 關鍵字一律大寫。
- **內建函式名大寫**：`COUNT`、`SUM`、`SYSDATE`、`NVL`、`SUBSTR` 等內建函式名一律大寫，與關鍵字風格一致。
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
    ,OrderDate AS d
FROM Orders;
```

### SQL Injection 防範（Crucial）

- 所有來自應用程式的查詢**必須**使用參數化查詢，禁止字串串接。
- 預存程序與動態 SQL 內部同樣禁止把外部輸入串接進 SQL 文字。各資料庫的參數化機制見對應專屬節（SQL Server 用 `sp_executesql`，Oracle 用 Bind Variables）。

### 索引友善查詢（Crucial）

#### 避免破壞索引的寫法

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
SELECT * FROM Products
WHERE CategoryId NOT IN (SELECT CategoryId FROM ExcludedCategories);

-- ✅ NOT EXISTS 不受 NULL 影響
SELECT p.*
FROM Products p
WHERE NOT EXISTS (
    SELECT 1
    FROM ExcludedCategories e
    WHERE e.CategoryId = p.CategoryId
);
```

### 分頁查詢

- 使用 `OFFSET ... FETCH NEXT` 語法，不使用舊式 `ROW_NUMBER()` 子查詢包裝。此語法在 SQL Server 2012+ 與 Oracle 12c+ 相同；Oracle 11g 以下的替代寫法見 Oracle 專屬節。

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
    N'SELECT * FROM Products WHERE CategoryId = @CategoryId',
    N'@CategoryId INT',
    @CategoryId = @inputCategoryId;

-- ❌ 錯誤
EXEC('SELECT * FROM Products WHERE CategoryId = ' + @inputCategoryId);
```

### 交易與鎖定

- 長時間執行的查詢應評估是否需要 `WITH (NOLOCK)` 或 `READ UNCOMMITTED` 隔離等級（僅限可容忍 Dirty Read 的報表查詢）。
- 更新操作若涉及先讀後寫，考慮使用 `UPDLOCK` 或適當的隔離等級防止競爭條件。
- Oracle 採 MVCC 多版本讀一致性，讀取不阻塞寫入，無 `NOLOCK` 對應語法，本節不套用於 Oracle。

---

## Oracle 專屬語法（Oracle SQL / PL/SQL）

以下規則**僅適用於 Oracle 資料庫**，與共通規範及 SQL Server 節不重疊。Oracle 的語法錯誤多來自「把 SQL Server（T-SQL）習慣反射套用到 Oracle」，本節先以對照表列出高頻直譯錯誤，再列語意陷阱。

### T-SQL 習慣 → Oracle 正解對照

下列 T-SQL 寫法在 Oracle 不存在或行為不同，撰寫 Oracle SQL 時直接改用右欄：

| T-SQL（反射寫法） | Oracle 正解 | 說明 |
| --- | --- | --- |
| `ISNULL(x, y)` | `NVL(x, y)` / `COALESCE(x, y)` | NULL 取代；Oracle 不支援 `ISNULL` |
| `GETDATE()` | `SYSDATE` / `SYSTIMESTAMP` | 目前時間 |
| `LEN(x)` | `LENGTH(x)` | 字串長度 |
| `CHARINDEX(sub, x)` | `INSTR(x, sub)` | 子字串位置，注意參數順序相反 |
| `SUBSTRING(x, s, l)` | `SUBSTR(x, s, l)` | 擷取子字串 |
| `a + b`（字串） | `a || b` | 字串串接；Oracle 的 `+` 僅為數值運算 |
| `SELECT TOP n ...` | `... FETCH FIRST n ROWS ONLY` | 限制筆數（12c+） |
| `VARCHAR` / `INT` | `VARCHAR2` / `NUMBER` | 常用型別 |

- NULL 合併優先使用標準 SQL 的 `COALESCE`，`NVL` 為 Oracle 專屬。

```sql
SELECT FirstName || ' ' || LastName AS FullName FROM Employees;
```

### 語意陷阱（最易忽略）

以下語法在 Oracle 看似正確卻行為不同，是 T-SQL 經驗者最常踩的坑。

- **空字串等於 NULL**：Oracle 中 `''` 即 NULL，`col = ''` 永遠不成立，判斷空值一律用 `IS NULL`。像 `NVL(col, '') = ''` 這種寫法恆為 false（`''` 是 NULL，`NVL` 的預設值也成 NULL），達不到預期效果。
- **DML 不自動提交**：Oracle 的 `INSERT` / `UPDATE` / `DELETE` 執行後需顯式 `COMMIT` 才生效，不像 SQL Server 預設 autocommit。忘記 `COMMIT` 會讓變更在連線結束時回滾。
- **`ROWNUM` 在 `ORDER BY` 之前套用**：`SELECT * FROM Orders WHERE ROWNUM <= 10 ORDER BY OrderDate` 會先取任意 10 筆再排序，不是排序後的前 10 筆。要取排序後的前 N 筆，須先在子查詢排序再於外層套 `ROWNUM`，或改用 `FETCH FIRST n ROWS ONLY`。
- **日期字串隱式轉換依賴 NLS**：直接 `WHERE OrderDate >= '2024-01-01'` 依賴會談的 `NLS_DATE_FORMAT`，不同環境結果可能不同。明確使用 `TO_DATE('2024-01-01', 'YYYY-MM-DD')` 或 `DATE '2024-01-01'` 字面值。

### 識別字大小寫折疊

- 未加雙引號的識別字，Oracle 一律折疊為大寫儲存與比對。`SELECT id FROM orders` 與 `SELECT ID FROM ORDERS` 等價。
- 加了雙引號的識別字，Oracle 區分大小寫，且之後每次引用都必須完全比對。若建表時寫 `"OrderId"`，後續一律要用 `"OrderId"`；寫成 `OrderId`（未加引號會被折成 `ORDERID`）會找不到欄位。
- 建議除非有明確理由，避免對識別字加雙引號，以免被迫全程帶引號。

### 動態 SQL 參數化

- 動態 SQL 使用 **Bind Variables**（`:paramName`），禁止字串串接：

```sql
-- ✅ 正確
EXECUTE IMMEDIATE 'SELECT * FROM Products WHERE CategoryId = :cid'
    USING v_category_id;

-- ❌ 錯誤
EXECUTE IMMEDIATE 'SELECT * FROM Products WHERE CategoryId = ' || v_category_id;
```

### 分頁查詢

- Oracle 12c 以上使用 `OFFSET ... FETCH NEXT`（與共通規範的分頁語法相同）：

```sql
SELECT ProductId, ProductName
FROM Products
ORDER BY ProductId
OFFSET :offset ROWS
FETCH NEXT :page_size ROWS ONLY;
```

- Oracle 11g 以下使用 `ROWNUM` 雙層包裝：

```sql
SELECT *
FROM (
    SELECT inner_q.*, ROWNUM AS rn
    FROM (
        SELECT ProductId, ProductName
        FROM Products
        ORDER BY ProductId
    ) inner_q
    WHERE ROWNUM <= :end_row
)
WHERE rn > :start_row;
```

### 自動編號（SEQUENCE）

- Oracle 沒有 `IDENTITY` 欄位，使用 `SEQUENCE` 搭配 `NEXTVAL`：

```sql
CREATE SEQUENCE seq_products START WITH 1 INCREMENT BY 1 NOCACHE;

INSERT INTO Products (ProductId, ProductName)
VALUES (seq_products.NEXTVAL, :product_name);
```

- Oracle 12c 以上可使用 `GENERATED AS IDENTITY`：

```sql
ProductId NUMBER GENERATED BY DEFAULT AS IDENTITY
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

### DUAL 虛擬資料表

- Oracle 無法在 `SELECT` 中省略 `FROM`，計算純運算式時使用 `DUAL`：

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
