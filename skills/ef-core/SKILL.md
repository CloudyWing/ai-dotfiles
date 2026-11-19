---
name: ef-core
description: 'Entity Framework Core 開發規範：DbContext Lifetime、查詢效能、Migration 管理、變更追蹤最佳實踐、模型設定（DateTime Kind、精度、資料庫預設值）、SaveChanges 失敗後的狀態與導覽屬性同步，以及依 AI-PROFILE 目標版本鍵設定 provider 相容性。當偵測到 EF Core 相依，或撰寫 DbContext、資料庫查詢與 Migration 時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Entity Framework Core 開發規範

## DbContext Lifetime

- 若需在 Singleton 或背景服務中使用，必須注入 `IDbContextFactory<T>` 並在使用處建立短生命週期實例（`await using` 搭配 `CreateDbContextAsync`）。

## 查詢效能

### AsNoTracking

- **唯讀查詢**（不需要後續更新的資料）必須加上 `.AsNoTracking()`，降低記憶體與效能開銷。
- 若整個 DbContext 的查詢皆為唯讀場景，可在註冊時設定 `UseQueryTrackingBehavior(QueryTrackingBehavior.NoTracking)`。

### 投影優先

- 投影至 DTO、匿名型別或純量時，結果不受變更追蹤。投影結果中包含 Entity 實例時，該 Entity 仍會被追蹤，唯讀查詢仍需加上 `.AsNoTracking()`。

### 分頁查詢

- 使用 `Skip` / `Take` 前，先以唯一且穩定的欄位排序。非唯一的排序欄位必須以 `ThenBy` 追加 unique key、identity 或 sequence，固定同一資料快照內的順序，避免相同排序值的順序不確定。
- 唯一排序鍵只固定單一資料快照內的順序。跨請求的頁面漂移、keyset pagination 的限制與固定資料集合的作法見 `sql-query` skill「分頁查詢」。

## 全域查詢篩選 (Global Query Filter)

- 軟刪除（`IsDeleted`）、多租戶（`TenantId`）等橫切條件，優先在 `OnModelCreating` 中透過 `.HasQueryFilter()` 統一設定。
- 需要繞過篩選的場景使用 `.IgnoreQueryFilters()`，並加上註解說明原因。

## Migration 管理

- 資料 Seeding 使用 `HasData()` 方式，不在 Migration 的 `Up()` 方法中直接寫入 SQL Insert。

## 模型設定

### DateTime 的 Kind

- `datetime`、`datetime2` 等不含時區的欄位讀回 `DateTime` 時，`Kind` 為 `Unspecified`，序列化結果結尾沒有 `Z`。專案約定使用 UTC 時，前端會把時間當成本機時間解讀而差了時區偏移。
- `Kind` 為 `Unspecified` 時，`ToLocalTime()` 假設原值為 UTC 並加上時區偏移，`ToUniversalTime()` 假設原值為本機時間並減去偏移；`Kind` 不確定時呼叫這兩個方法會得到非預期結果。
- 在讀寫邊界以 `ValueConverter` 統一 `Kind`，不在輸出時以 `ToString("...Z")` 手動補 `Z`。寫入時 `Kind` 不是 `Utc` 就呼叫 `ToUniversalTime()`，讀取時以 `DateTime.SpecifyKind(v, DateTimeKind.Utc)` 標記。寫入端的 `ToUniversalTime()` 會把 `Unspecified` 當成本機時間，應用程式端建立 `DateTime` 時明確使用 `Utc` 或 `Local`。

```csharp
public class UtcDateTimeValueConverter : ValueConverter<DateTime, DateTime> {
    public UtcDateTimeValueConverter()
        : base(v => v.Kind == DateTimeKind.Utc ? v : v.ToUniversalTime(), v => DateTime.SpecifyKind(v, DateTimeKind.Utc)) {
    }
}

protected override void ConfigureConventions(ModelConfigurationBuilder configurationBuilder) {
    configurationBuilder.Properties<DateTime>().HaveConversion<UtcDateTimeValueConverter>();
}
```

- `ConfigureConventions()` 在 `OnModelCreating()` 之前執行，用來定義慣例；個別屬性要覆寫時寫在 `OnModelCreating()`。反向工程產生的 DbContext 以同 namespace 的 partial 類別實作 `OnModelCreatingPartial()` 或覆寫 `ConfigureConventions()`，不修改產生的檔案。
- `datetime2` 與 `datetimeoffset` 欄位以 `.HasPrecision()` 明確指定精度，預設行為可能隨版本或 provider 而異。

### 資料庫預設值

- 屬性設定 `HasDefaultValue()` 或 `HasDefaultValueSql()` 時，新增 Entity 的屬性值若等於該 CLR 型別的預設值（`null`、`0`、`default(DateTime)`、`Guid.Empty`），EF Core 產生的 `INSERT` 會省略該欄位，改由資料庫預設值寫入。明確設為 `null` 與沒設值的結果相同。EF Core 8 起可用 `HasSentinel()` 改變判定省略的值；資料庫預設值為 `true` 的 `bool` 屬性會自動以 `true` 為判定值。
- 欄位沒有資料庫預設值時，CLR 預設值照常寫入。
- 反向工程把有預設值的 `bit` 欄位產生為 `bool?` 時，`null` 同樣會被省略而寫入資料庫預設值。
- 使用資料庫預設值時，讓資料庫預設值與 C# 預設值一致；不一致時，程式寫入 C# 預設值的結果會變成資料庫預設值。字串欄位可設為 `NOT NULL DEFAULT ''`，但程式碼仍明確寫入空字串，不靠 `null` 加資料庫預設值得到空字串。

## 變更追蹤與儲存

- `SaveChangesAsync()` 應在業務操作單元的最外層呼叫一次，不在 Repository 方法內部呼叫（避免破壞 Unit of Work 模式）。
### 更新與 EntityState

- 對追蹤中的 Entity 設值但值不變時，`EntityState` 維持 `Unchanged`，不送出 `UPDATE`，`SaveChanges()` 回傳 `0`。`SaveChanges()` 回傳的是整個 context 寫入的狀態項目數，回傳 `0` 不代表更新失敗。只異動單一 Entity 的更新方法可寫成 `context.Entry(entity).State == EntityState.Unchanged || context.SaveChanges() > 0`，避免值不變時誤判為失敗；此寫法在該 Entity 未變更時不會呼叫 `SaveChanges()`，context 還有其他待儲存變更時不適用。
- 追蹤中的 Entity 只更新有變動的欄位。手動設定 `context.Entry(entity).State = EntityState.Modified` 會更新所有欄位。
- 要更新的資料不加 `AsNoTracking()` 查詢。以 `AsNoTracking()` 取出後再手動設 `Modified`，同樣會更新所有欄位。

### SaveChanges 失敗後的狀態

- `SaveChanges()` 失敗時，Entity 狀態會保留。同一個 DbContext 下一次呼叫 `SaveChanges()` 會連同上次失敗的變更一起送出；失敗原因沒有處理（例如主鍵重複）時，之後每次 `SaveChanges()` 都會因同一筆變更而失敗。批次處理依賴主鍵擋重複資料時會踩到這點；寫入前先檢查重複資料，或在失敗後還原狀態。
- 還原方式依狀態處理。`Added` 改為 `Detached`；`Modified` 先以 `entry.CurrentValues.SetValues(entry.OriginalValues)` 還原值再改為 `Unchanged`；`Deleted` 改為 `Unchanged`。
- Entity 有外鍵或多對多關聯時，狀態還原不可靠。透過導覽屬性 `Remove()` 的關聯無法加回導覽屬性，還原後重新查詢仍可能拿到 DbContext 中已追蹤、缺少關聯的實體。有外鍵的 Entity 結構不使用狀態還原。
- `DbUpdateException` 的 `Message` 只有籠統的「See the inner exception for details」，記錄日誌時取 `InnerException` 的訊息。
- EF Core 的 `SaveChanges()` 不驗證 DataAnnotations，EF6 的 `DbEntityValidationException` 在 EF Core 不存在；驗證在 Model Binding 或 Service 層完成。
- `DbSet.Add()` 加入與已追蹤 Entity 相同主鍵的實體時，`Add()` 當下就拋出 `InvalidOperationException`，不會進入包住 `SaveChanges()` 的錯誤處理。

### 導覽屬性與外鍵同步

- 導覽屬性與外鍵只在兩端 Entity 都被追蹤時同步，同步發生在 Entity 開始被追蹤時的關聯修正（例如 `Add()` 加入追蹤），以及變更偵測時：`Entry()` 預設對該 Entity 做局部偵測，`SaveChanges()` 預設做完整偵測。使用快照追蹤時，加入追蹤後才設定導覽屬性或外鍵屬性，在下一次變更偵測前導覽屬性不會更新；通知實體或變更追蹤 Proxy 則會即時偵測。
- 透過導覽屬性加入時，追蹤會沿關聯擴散。`main.Subs.Add(sub)` 後 `Add(main)` 會一併追蹤 `sub`；`sub.Main = main` 後 `Add(sub)` 會一併追蹤 `main`。只 `Add(sub)` 而關聯是設在 `main.Subs` 上時，`main` 不會被追蹤。
- 只追蹤子表並設定外鍵屬性（例如 `sub.MainId`）時，兩端的導覽屬性都不會同步；以 `Find()` 等方式載入主表後才同步。
- `main.Subs.Remove(sub)` 解除關聯後的結果取決於關聯是否為必要關聯與 `DeleteBehavior`。外鍵可為 `null` 的選擇性關聯預設把外鍵設為 `null`，子表資料保留；必要關聯預設把子表資料視為孤兒刪除；多對多關聯只刪除聯結表的那一列。要刪除子表資料時明確使用 `context.Subs.Remove(sub)`。

## Lazy Loading 警告

- EF Core **預設停用** Lazy Loading。若安裝 `Microsoft.EntityFrameworkCore.Proxies` 並呼叫 `.UseLazyLoadingProxies()`，Navigation Property 將在存取時觸發額外查詢，容易引發隱性 N+1。EF Core 8 起，`AsNoTracking()` 查詢回傳的 Entity 也會觸發 Lazy Loading。
- 正式環境建議維持停用（預設值），改用明確的 `Include()`、`ThenInclude()` 或投影。

## 目標版本與相容性設定

- 讀鍵：provider 為 SQL Server 時讀取 `target.sqlserver` 與 `target.sqlserver.compat`，為 Oracle 時讀取 `target.oracle`。provider 依 `sql-query` SKILL.md「目標版本」的「適用偵測」判定。鍵的語意、詢問、缺少與略過處置依該節，先載入 `sql-query` 再執行本節。
- 設定：建立或修改 provider 選項時，依 `references/provider-compatibility.md` 對應 provider 的節設定 `UseCompatibilityLevel`（SQL Server）或 `UseOracleSQLCompatibility`（Oracle）。有效相容性層級依 `sql-query` 的 `references/sqlserver.md`「版本與相容性層級對照」取得。
- 未確認目標版本：使用者略過詢問時不設定相容性選項，沿用 provider 預設，並在回覆註明「未確認目標版本」。
- 既有設定：既有設定值與鍵推導的值不同時，在回覆列出差異，不改寫既有設定。只有本輪本來就要新增或修改 provider 選項時，才採用推導的值。
- 多個 provider：同一專案有多個 provider 時，各自依其鍵設定。
- 找不到設定處：專案中找不到 provider 選項的設定位置時，回報缺口位置，不新增設定檔。

| Provider | 載入的檔案 |
| --- | --- |
| SQL Server 或 Oracle | 本文件，加上 `references/provider-compatibility.md` |
| 其他 provider | 本文件，不讀目標版本鍵 |

## 原生 SQL 與 FromSql

- 優先使用 LINQ 查詢；僅在 LINQ 無法表達或效能明確不足時，才使用 `FromSqlInterpolated()` 或 `FromSqlRaw()`。
