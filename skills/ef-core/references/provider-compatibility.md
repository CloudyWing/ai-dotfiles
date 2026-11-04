# EF Core provider 相容性設定

專案的 EF Core provider 為 SQL Server 或 Oracle 時載入本檔，套用方式依 `ef-core` SKILL.md「目標版本與相容性設定」。有效版本與有效相容性層級的取得依 `sql-query` SKILL.md「目標版本」，SQL Server 的預設相容性層級對照見 `sql-query` 的 `references/sqlserver.md`「版本與相容性層級對照」。最後查證日：2026-11-04。

## 設定寫法

| Provider | API | 設定位置 | 適用版本 | 來源 |
| --- | --- | --- | --- | --- |
| SQL Server（`Microsoft.EntityFrameworkCore.SqlServer`） | `UseCompatibilityLevel(int compatibilityLevel)` | `UseSqlServer` 的 provider 選項委派 | EF Core 8.0 起 | [UseCompatibilityLevel](https://learn.microsoft.com/en-us/dotnet/api/microsoft.entityframeworkcore.infrastructure.sqlserverdbcontextoptionsbuilder.usecompatibilitylevel) |
| Oracle（`Oracle.EntityFrameworkCore`） | `UseOracleSQLCompatibility(OracleSQLCompatibility version)`，值為 `DatabaseVersion19`、`DatabaseVersion21`、`DatabaseVersion23` | `UseOracle` 的 provider 選項委派 | 官方文件說法不一致，見下方說明 | [Oracle EF Core API](https://docs.oracle.com/en/database/oracle/oracle-database/21/odpnt/EFCoreAPI.html) |
| Oracle（`Oracle.EntityFrameworkCore`） | `UseOracleSQLCompatibility(string version)`，已淘汰 | `UseOracle` 的 provider 選項委派 | EF Core 6、7；預設值 `"12"`，產生的 SQL 相容 Oracle 12 以上，其他值不改變行為 | [Oracle EF Core API](https://docs.oracle.com/en/database/oracle/oracle-database/21/odpnt/EFCoreAPI.html) |

```csharp
// SQL Server：依有效相容性層級設定
services.AddDbContext<AppDbContext>(options =>
    options.UseSqlServer(connectionString, sqlServer => sqlServer.UseCompatibilityLevel(130)));

// Oracle：enum 多載
services.AddDbContext<AppDbContext>(options =>
    options.UseOracle(connectionString, oracle => oracle.UseOracleSQLCompatibility(OracleSQLCompatibility.DatabaseVersion19)));
```

- `UseCompatibilityLevel` 只告訴 EF Core 要產生哪個層級的 SQL，不修改資料庫本身的相容性層級。
- Oracle enum 多載的適用版本有兩種官方說法：API 頁寫「只存在於 EF Core 8」，[Breaking changes 頁](https://docs.oracle.com/en/database/oracle/oracle-database/21/odpnt/EFCoreDesupportedAPIs.html)寫「EF Core 6 以上搭配 Oracle EF Core 21.12.1」。本檔不斷言版本，以專案引用的 `Oracle.EntityFrameworkCore` 實際提供的多載為準；兩種多載都不存在時不設定，並在回覆註明。

## 鍵到設定值的對映

| 鍵狀態 | SQL Server | Oracle |
| --- | --- | --- |
| 已設定 | `UseCompatibilityLevel(<有效相容性層級>)` | `target.oracle` 為 `19c` 時 `DatabaseVersion19`；`21c` 時 `DatabaseVersion21`；`23ai`、`26ai` 時 `DatabaseVersion23` |
| 已設定但低於可對映範圍 | 不適用，合法值皆有對應層級 | `target.oracle` 早於 `19c` 時 enum 沒有對應值，不設定；只有 string 多載可用時，產生的 SQL 相容 Oracle 12 以上，`target.oracle` 為 `11g` 時在回覆註明 provider 產生的 SQL 不保證相容 |
| 專案 EF Core 版本低於 API 適用版本 | 不設定，在回覆註明 | 不設定，在回覆註明 |
| 缺少或使用者已略過 | 依 `ef-core` SKILL.md「目標版本與相容性設定」的「未確認目標版本」 | 同左 |

## 受相容性層級影響的行為

| 行為 | 門檻層級 | 低於門檻的產生結果 | 達門檻的產生結果 | 來源 |
| --- | --- | --- | --- | --- |
| SQL Server 參數集合的 `Contains` | 相容性層級 130 | 設為 120 時使用舊版 SQL，集合值以常值列入 `IN` | 以 `OPENJSON` 展開參數集合 | [EF Core 8 breaking changes](https://learn.microsoft.com/en-us/ef/core/what-is-new/ef-core-8.0/breaking-changes) |
| Oracle 的 .NET `bool` 對映 | `DatabaseVersion23` | `DatabaseVersion21` 以下對映 `NUMBER(1)` | 對映 Oracle `BOOLEAN` | [Oracle EF Core API](https://docs.oracle.com/en/database/oracle/oracle-database/26/odpnt/EFCoreAPI.html) |

## 寫法注意事項

- EF Core 不會自動讀取資料庫的相容性層級。未設定 `UseCompatibilityLevel` 時，正式環境層級低於 130 的資料庫會收到 `OPENJSON` 查詢，來源見 [EF Core 8 breaking changes](https://learn.microsoft.com/en-us/ef/core/what-is-new/ef-core-8.0/breaking-changes)。
- 調整 Oracle 相容性值會改變 `bool` 的資料庫型別，既有資料表已以 `NUMBER(1)` 建立時，提高到 `DatabaseVersion23` 前先確認 Migration 的影響。
