# EF Core provider 相容性設定

專案的 EF Core provider 為 SQL Server 或 Oracle 時載入本檔，套用方式依 `ef-core` SKILL.md「目標版本與相容性設定」。有效版本與有效相容性層級的取得依 `sql-query` SKILL.md「目標版本」，SQL Server 的有效相容性層級見 `sql-query` 的 `references/sqlserver.md`「版本與相容性層級對照」。

## SQL Server

### 通用寫法

在 `UseSqlServer` 的 provider 選項委派呼叫 `UseCompatibilityLevel(<有效相容性層級>)`。

```csharp
services.AddDbContext<AppDbContext>(options =>
    options.UseSqlServer(connectionString, sqlServer => sqlServer.UseCompatibilityLevel(130)));
```

### 版本注意事項

- EF Core 8.0 起提供 `UseCompatibilityLevel(int compatibilityLevel)`。專案 EF Core 為 7 以下時不設定，並在回覆註明。
- `UseCompatibilityLevel` 只決定 EF Core 產生的 SQL，不修改資料庫本身的相容性層級。
- EF Core 不會自動讀取資料庫的相容性層級。
- EF Core 8、9 的參數集合 `Contains` 預設以 `OPENJSON` 展開，`OPENJSON` 需要資料庫層級至少 130。設為 120 時改用舊版 SQL，集合值以常值列入 `IN`。
- EF Core 10 起，參數集合 `Contains` 預設改為每個元素各一個純量參數，不再依賴 `OPENJSON`。要指定翻譯方式時，在 `UseSqlServer` 的 provider 選項委派呼叫 `UseParameterizedCollectionMode(ParameterTranslationMode.<值>)`。

## Oracle

### 通用寫法

在 `UseOracle` 的 provider 選項委派呼叫 `UseOracleSQLCompatibility`，依專案引用的 `Oracle.EntityFrameworkCore` 實際提供的多載選用：

1. 有 `UseOracleSQLCompatibility(OracleSQLCompatibility version)` 時使用 enum 多載，值依下表。
2. 只有 `UseOracleSQLCompatibility(string version)` 時使用 string 多載，規則見「版本注意事項」。
3. 兩種多載都沒有時不設定，並在回覆註明。

```csharp
services.AddDbContext<AppDbContext>(options =>
    options.UseOracle(connectionString, oracle => oracle.UseOracleSQLCompatibility(OracleSQLCompatibility.DatabaseVersion19)));
```

| `target.oracle` | enum 值 |
| --- | --- |
| `19c` | `DatabaseVersion19` |
| `21c` | `DatabaseVersion21` |
| `23ai`、`26ai` | `DatabaseVersion23` |
| 早於 `19c` | 沒有對應值，不使用 enum 多載。套件提供 string 多載時改依 string 多載規則，否則不設定並在回覆註明 |

### 版本注意事項

- string 多載已淘汰，預設值為 `"12"`，產生的 SQL 相容 Oracle 12 以上，傳入其他值不改變行為。`target.oracle` 為 `11g` 時，在回覆註明 provider 產生的 SQL 不保證相容。
- `DatabaseVersion23` 讓 .NET `bool` 對映 Oracle `BOOLEAN`，`DatabaseVersion21` 以下對映 `NUMBER(1)`。既有資料表已以 `NUMBER(1)` 建立時，提高到 `DatabaseVersion23` 前先確認 Migration 的影響。

## 來源

最後查證日：2026-11-05。Oracle 官方文件對 enum 多載起始的 EF Core 版本有兩種說法，因此 Oracle 一律依套件實際提供的多載判定。每一列規則對應的官方文件如下。

| 對象 | 來源 |
| --- | --- |
| SQL Server：`UseCompatibilityLevel` 與 EF Core 8.0 起提供 | [UseCompatibilityLevel API](https://learn.microsoft.com/en-us/dotnet/api/microsoft.entityframeworkcore.infrastructure.sqlserverdbcontextoptionsbuilder.usecompatibilitylevel) |
| SQL Server：EF Core 8、9 的 `Contains` 與 `OPENJSON`、層級 120 的舊版 SQL、不自動讀取層級 | [EF Core 8 breaking changes](https://learn.microsoft.com/en-us/ef/core/what-is-new/ef-core-8.0/breaking-changes) |
| SQL Server：EF Core 10 的參數集合翻譯與 `UseParameterizedCollectionMode` | [EF Core 10 新功能：參數集合翻譯](https://learn.microsoft.com/en-us/ef/core/what-is-new/ef-core-10.0/whatsnew#improved-translation-for-parameterized-collection) |
| Oracle：string 多載的預設值與行為 | [Oracle EF Core API（21）](https://docs.oracle.com/en/database/oracle/oracle-database/21/odpnt/EFCoreAPI.html) |
| Oracle：enum 多載與 `target.oracle` 對映、`bool` 對映 | [Oracle EF Core API（26）](https://docs.oracle.com/en/database/oracle/oracle-database/26/odpnt/EFCoreAPI.html) |
| Oracle：enum 多載起始版本的另一種說法 | [Oracle EF Core Breaking Changes](https://docs.oracle.com/en/database/oracle/oracle-database/21/odpnt/EFCoreDesupportedAPIs.html) |
