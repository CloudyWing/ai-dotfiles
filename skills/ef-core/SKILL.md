---
name: ef-core
description: 'Entity Framework Core 開發規範：DbContext Lifetime、查詢效能、Migration 管理與變更追蹤最佳實踐。'
---

# Entity Framework Core 開發規範

當偵測到專案使用 Entity Framework Core（含 `Microsoft.EntityFrameworkCore` 相依套件）或使用者要求撰寫資料存取邏輯時，請自動套用以下規範。

## DbContext Lifetime（Crucial）

- DbContext **必須**註冊為 `Scoped`（`AddDbContext<T>` 預設行為）。
- **禁止**將 DbContext 注入至 Singleton 服務，會導致 Captive Dependency 與並行存取問題。
- 若需在 Singleton 或背景服務中使用，必須注入 `IDbContextFactory<T>` 並在使用處建立短生命週期實例。

```csharp
// ✅ 正確：背景服務使用 IDbContextFactory
public class MyBackgroundService(IDbContextFactory<AppDbContext> contextFactory) : BackgroundService {
    protected override async Task ExecuteAsync(CancellationToken stoppingToken) {
        await using AppDbContext db = await contextFactory.CreateDbContextAsync(stoppingToken)
            .ConfigureAwait(false);
        // ...
    }
}

// ❌ 錯誤：直接注入 DbContext 至 Singleton
public class MyBackgroundService(AppDbContext db) : BackgroundService { }
```

## 查詢效能（Crucial）

### N+1 問題防範

- 迴圈中對 Navigation Property 的逐筆存取為典型 N+1 模式，必須使用 `Include()` / `ThenInclude()` 預先載入，或改用投影（`Select`）一次取回所需欄位。
- 禁止在迴圈中呼叫 `SaveChanges()` 或 `SaveChangesAsync()`，應批次處理後統一儲存。

### AsNoTracking

- **唯讀查詢**（不需要後續更新的資料）必須加上 `.AsNoTracking()`，降低記憶體與效能開銷。
- 若整個 DbContext 的查詢皆為唯讀場景，可在註冊時設定 `UseQueryTrackingBehavior(QueryTrackingBehavior.NoTracking)`。

```csharp
// ✅ 正確：唯讀查詢
IReadOnlyList<OrderDto> orders = await db.Orders
    .AsNoTracking()
    .Where(o => o.Status == OrderStatus.Completed)
    .Select(o => new OrderDto {
        Id = o.Id,
        Total = o.Total
    })
    .ToListAsync(cancellationToken)
    .ConfigureAwait(false);

// ❌ 錯誤：唯讀場景未加 AsNoTracking，且回傳整個 Entity
List<Order> orders = await db.Orders
    .Where(o => o.Status == OrderStatus.Completed)
    .ToListAsync(cancellationToken);
```

### 投影優先

- 若只需 Entity 的部分欄位，優先使用 `Select()` 投影至 DTO，避免載入整個 Entity。
- 投影可同時解決 AsNoTracking 的需求（投影查詢本身不追蹤）。

## 全域查詢篩選 (Global Query Filter)

- 軟刪除（`IsDeleted`）、多租戶（`TenantId`）等橫切條件，優先在 `OnModelCreating` 中透過 `.HasQueryFilter()` 統一設定。
- 需要繞過篩選的場景使用 `.IgnoreQueryFilters()`，並加上註解說明原因。

## Migration 管理

- Migration 檔案**必須**納入版本控制。
- **禁止**手動修改已套用至任何環境的 Migration 檔案內容；若需修正已套用的 Migration，建立新的修正 Migration。
- Migration 名稱應具描述性（如 `AddOrderStatusColumn`），不使用自動產生的時間戳名稱。
- 資料 Seeding 使用 `HasData()` 方式，不在 Migration 的 `Up()` 方法中直接寫入 SQL Insert。

## 變更追蹤與儲存

- `SaveChangesAsync()` 應在業務操作單元的最外層呼叫一次，不在 Repository 方法內部呼叫（避免破壞 Unit of Work 模式）。
- 批次新增大量資料時，考慮使用 `AddRangeAsync()` 並控制批次大小，避免單次追蹤過多 Entity。

## 交易管理

- 單一 `SaveChangesAsync()` 呼叫本身即為一個交易，簡單場景不需額外包裝。
- 跨多次 `SaveChangesAsync()` 或需要搭配其他外部操作時，使用 `IDbContextTransaction`：

```csharp
await using IDbContextTransaction transaction = await db.Database
    .BeginTransactionAsync(cancellationToken)
    .ConfigureAwait(false);

try {
    // 多個操作...
    await db.SaveChangesAsync(cancellationToken).ConfigureAwait(false);
    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
} catch {
    await transaction.RollbackAsync(cancellationToken).ConfigureAwait(false);
    throw;
}
```

## 原生 SQL 與 FromSql

- 優先使用 LINQ 查詢；僅在 LINQ 無法表達或效能明確不足時，才使用 `FromSqlInterpolated()` 或 `FromSqlRaw()`。
- 使用 `FromSqlRaw()` 時，**必須**透過參數化查詢防止 SQL Injection，禁止字串串接。

```csharp
// ✅ 正確：參數化
IReadOnlyList<Product> products = await db.Products
    .FromSqlInterpolated($"SELECT * FROM Products WHERE CategoryId = {categoryId}")
    .ToListAsync(cancellationToken)
    .ConfigureAwait(false);

// ❌ 錯誤：字串串接
IReadOnlyList<Product> products = await db.Products
    .FromSqlRaw("SELECT * FROM Products WHERE CategoryId = " + categoryId)
    .ToListAsync(cancellationToken);
```
