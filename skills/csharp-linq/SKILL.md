---
name: csharp-linq
description: 'LINQ 查詢規範：物化時機、回傳型別、語法選用與鏈式排版的專案慣例。當撰寫 In-Memory 集合操作或 LINQ to Objects 時自動套用。'
---

# LINQ 查詢規範

當撰寫 LINQ to Objects（In-Memory 集合操作）或審查非 EF Core 的 LINQ 查詢時，請自動套用以下規範。EF Core 的 LINQ to SQL 查詢由 `ef-core` skill 管轄，本文件不重複。延遲執行、操作子語意等通用知識不在此複述，本文件只收專案慣例。

## 物化時機與回傳型別

- **需要多次列舉結果**時，先呼叫 `.ToList()` 或 `.ToArray()` 物化，避免查詢管線重複執行。
- **僅傳遞給下一個 LINQ 操作或單次 `foreach`**時，維持延遲執行即可，不需提前物化。
- **方法回傳值**：若回傳集合會被呼叫端多次使用，物化後以 `IReadOnlyList<T>` 回傳；若語意上為串流，回傳 `IEnumerable<T>` 並在 XML 文件中標註為延遲執行。

## 查詢語法 vs 方法語法

- **預設使用方法語法**（Method Syntax / Fluent Syntax）。
- **允許查詢語法的情境**：多重 `join`、`let` 綁定、`group by ... into` 等使用查詢語法可顯著提升可讀性時。
- 同一個查詢中**禁止混用**查詢語法與方法語法。

## 操作子禁止模式

- **禁止**在預期有多筆結果的情境下使用 `Single` / `SingleOrDefault`。
- **禁止** `FirstOrDefault()!` 或 `SingleOrDefault()!`（`OrDefault` 語意表示可能為 null，加 `!` 自相矛盾）。
- 已物化的 `IReadOnlyList<T>` / `List<T>` 使用 `.Count` 屬性，不呼叫 `.Count()` 方法。

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
