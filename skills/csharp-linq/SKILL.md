---
name: csharp-linq
description: 'LINQ 查詢規範：延遲執行、物化時機、查詢可讀性與效能陷阱迴避。當撰寫 In-Memory 集合操作或 LINQ to Objects 時自動套用。'
---

# LINQ 查詢規範

當撰寫 LINQ to Objects（In-Memory 集合操作）或審查非 EF Core 的 LINQ 查詢時，請自動套用以下規範。EF Core 的 LINQ to SQL 查詢由 `ef-core` skill 管轄，本文件不重複。

## 延遲執行與物化（Crucial）

### 延遲執行陷阱

`IEnumerable<T>` 的 LINQ 查詢預設為延遲執行（Deferred Execution），每次列舉（`foreach`、`.Count()`、`.ToList()`）都會重新執行查詢管線。

```csharp
// ❌ 錯誤：多次列舉同一個 IEnumerable，查詢管線重複執行
IEnumerable<Order> expensiveOrders = orders.Where(o => o.Total > 1000);
int count = expensiveOrders.Count();       // 第一次列舉
Order first = expensiveOrders.First();     // 第二次列舉
List<Order> list = expensiveOrders.ToList(); // 第三次列舉

// ✅ 正確：先物化再多次使用
IReadOnlyList<Order> expensiveOrders = orders
    .Where(o => o.Total > 1000)
    .ToList();
int count = expensiveOrders.Count;   // O(1) 屬性存取
Order first = expensiveOrders[0];
```

### 物化時機

- **需要多次列舉結果**時，先呼叫 `.ToList()` 或 `.ToArray()` 物化。
- **僅傳遞給下一個 LINQ 操作或單次 `foreach`**時，維持延遲執行即可，不需提前物化。
- **方法回傳值**：若回傳集合會被呼叫端多次使用，物化後以 `IReadOnlyList<T>` 回傳；若語意上為串流，回傳 `IEnumerable<T>` 並在 XML 文件中標註為延遲執行。

## 查詢語法 vs 方法語法

- **預設使用方法語法**（Method Syntax / Fluent Syntax），與 C# 開發者的主流習慣一致。
- **允許查詢語法的情境**：多重 `join`、`let` 綁定、`group by ... into` 等複雜操作，使用查詢語法可顯著提升可讀性時允許使用。
- 同一個查詢中**禁止混用**查詢語法與方法語法。

```csharp
// ✅ 正確：方法語法（一般情境）
IReadOnlyList<string> names = customers
    .Where(c => c.IsActive)
    .OrderBy(c => c.Name)
    .Select(c => c.Name)
    .ToList();

// ✅ 正確：查詢語法（多重 join 可讀性更佳）
var result =
    from o in orders
    join c in customers on o.CustomerId equals c.Id
    join p in products on o.ProductId equals p.Id
    where o.Total > 1000
    select new { c.Name, p.Title, o.Total };
```

## 操作子選用規範

### Select vs SelectMany

- `Select`：一對一投影，每個元素轉換為一個結果。
- `SelectMany`：一對多展開，將巢狀集合攤平為單層。

```csharp
// ❌ 錯誤：先 Select 再手動攤平
IEnumerable<IEnumerable<OrderItem>> nested = orders.Select(o => o.Items);

// ✅ 正確：直接使用 SelectMany
IEnumerable<OrderItem> allItems = orders.SelectMany(o => o.Items);
```

### First / Single / FirstOrDefault / SingleOrDefault

| 方法 | 語意 | 適用情境 |
| --- | --- | --- |
| `First()` | 取第一筆，無資料拋例外 | 確定至少有一筆（已驗證或業務保證） |
| `FirstOrDefault()` | 取第一筆，無資料回傳預設值 | 允許無結果，後續處理 null/default |
| `Single()` | 預期恰好一筆，其餘拋例外 | 以唯一鍵查詢，確保資料完整性 |
| `SingleOrDefault()` | 預期零或一筆 | 以唯一鍵查詢，允許不存在 |

- **禁止**在預期有多筆結果的情境下使用 `Single` / `SingleOrDefault`。
- **禁止** `FirstOrDefault()!` 或 `SingleOrDefault()!`（`OrDefault` 語意表示可能為 null，加 `!` 自相矛盾）。

### Any vs Count

```csharp
// ✅ 正確：檢查是否有元素用 Any()
if (orders.Any(o => o.IsUrgent)) { }

// ❌ 錯誤：用 Count() > 0 檢查存在性（遍歷整個序列）
if (orders.Count(o => o.IsUrgent) > 0) { }
```

- 檢查集合是否為空：`!collection.Any()`，不用 `collection.Count() == 0`。
- 需要實際數量時才使用 `Count()`；已物化的 `IReadOnlyList<T>` / `List<T>` 使用 `.Count` 屬性（O(1)）。

### GroupBy 效能

- In-Memory `GroupBy` 需要完整列舉來源集合才能分組，對大型集合有記憶體壓力。
- 若只需要分組後的第一筆，考慮使用 `DistinctBy()` 或 `ToLookup()` 替代。

```csharp
// ✅ GroupBy 的正確使用：需要所有分組結果
IReadOnlyList<IGrouping<string, Order>> grouped = orders
    .GroupBy(o => o.Category)
    .ToList();

// ✅ 若只需快速查詢，用 ToLookup（立即執行，建立查找表）
ILookup<string, Order> lookup = orders.ToLookup(o => o.Category);
IEnumerable<Order> electronics = lookup["Electronics"];
```

## 鏈式呼叫格式

- 每個 LINQ 操作子獨立一行，以 `.` 開頭對齊。
- Lambda 簡短時（單一條件或單一投影）使用 expression body；複雜時使用 statement body 並換行。

```csharp
// ✅ 正確：鏈式每行一個操作子
IReadOnlyList<OrderSummary> summaries = orders
    .Where(o => o.Status == OrderStatus.Completed)
    .OrderByDescending(o => o.CreatedAt)
    .Select(o => new OrderSummary {
        Id = o.Id,
        Total = o.Total
    })
    .ToList();

// ❌ 錯誤：全部擠在一行
IReadOnlyList<OrderSummary> summaries = orders.Where(o => o.Status == OrderStatus.Completed).OrderByDescending(o => o.CreatedAt).Select(o => new OrderSummary { Id = o.Id, Total = o.Total }).ToList();
```

## 效能陷阱

### 避免在 LINQ 中進行副作用操作

```csharp
// ❌ 錯誤：在 Select 中執行副作用
orders.Select(o => {
    o.Status = OrderStatus.Processed; // 副作用
    return o;
}).ToList();

// ✅ 正確：用 foreach 明確表達意圖
foreach (Order order in orders) {
    order.Status = OrderStatus.Processed;
}
```

### OrderBy 穩定性

- `OrderBy` / `ThenBy` 為穩定排序（Stable Sort），相同鍵值的元素維持原始順序。
- 多重排序使用 `OrderBy(...).ThenBy(...)`，**禁止**鏈接多個 `OrderBy`（後者會覆蓋前者）。

```csharp
// ❌ 錯誤：第二個 OrderBy 覆蓋第一個
orders.OrderBy(o => o.Category).OrderBy(o => o.Total);

// ✅ 正確
orders.OrderBy(o => o.Category).ThenBy(o => o.Total);
```

### 字串串接

- LINQ 結果需要串接成字串時，使用 `string.Join()`，不在 `Aggregate` 中串接。

```csharp
// ✅ 正確
string names = string.Join(", ", customers.Select(c => c.Name));

// ❌ 錯誤：Aggregate 串接效能差
string names = customers.Select(c => c.Name).Aggregate((a, b) => a + ", " + b);
```
