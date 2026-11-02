---
name: csharp-language-features
description: 'Use when 讀取或修改 C# 專案設定、TargetFramework 或 C# 程式碼，需判斷語言特性、非同步、型別選用，或依 project-kind 判斷 ConfigureAwait 與公開 API 相容性時。'
audience: agent
policy.allow_implicit_invocation: true
---

# C# Framework Context 與語言特性

## Framework Awareness

修改 C# 程式碼前先判斷目標框架與語言版本：

- **Legacy .NET Framework**：若為 .NET Framework，例如 v4.7.2，語法上限為 C# 7.3，不使用 C# 8.0 以上特性，例如 `using var`、`switch` 運算式、Records 與 Nullable Reference Types。
- **Modern .NET**：Core、5+ 或更新版本可使用相容的現代 C# 特性。依賴注入使用傳統建構函式，不使用 Primary Constructors。
- **明示 LangVersion**：`.csproj` 或 `Directory.Build.props` 明示 `<LangVersion>` 時，語言版本以其為準，優先於由 `<TargetFramework>` 推論的預設版本；兩者不一致時依 `<LangVersion>` 判斷可用特性。

## Async / Await

- 非同步方法回傳 `Task` 或 `Task<T>`，`async void` 僅用於事件處理函式。
- 依 `ai-profile` skill 的 `project-kind` 與「專案層解析」決定是否加上 `.ConfigureAwait(false)`。`library` 的非同步呼叫加上；`application` 與 `sample` 不加；未設定時不強制，沿用同專案既有寫法。
- 避免 Sync-over-Async。同步介面必須呼叫非同步邏輯時，視情況使用 `.GetAwaiter().GetResult()`，不使用 `.Result` 或 `.Wait()`。
- 方法只轉發另一個 Task 結果時，直接回傳該 Task，例如 `return DoSomethingAsync();`，不增加多餘的 `async` / `await` 狀態機。
- 回傳 Task 且未宣告 `async` 的方法，以 `Task.FromException()` 傳遞例外，不使用 `throw`。

## 公開 API 相容性

- **範圍**：`ai-profile` skill「專案層解析」為 `library` 的專案，且本次修改新增、移除或改變 `public` 或 `protected` 成員的簽章或可見性時適用。`application`、`sample` 與 `project-kind` 未設定時不檢查。
- **啟用判定**：專案檔或 `Directory.Build.props` 設定 `EnablePackageValidation` 為 `true`，或有 `Microsoft.CodeAnalysis.PublicApiAnalyzers` 的 `PackageReference` 且存在 `PublicAPI.Shipped.txt` 與 `PublicAPI.Unshipped.txt`，即視為已啟用。
- **已啟用**：修改後必須通過檢查。PackageValidation 在 `dotnet pack` 的 Pack 之後執行驗證（診斷如 `CP0002`）；PublicApiAnalyzers 在 `dotnet build` 產生 RS 系列診斷。失敗時修正或回報，不以抑制診斷或更新 `PublicAPI.Shipped.txt` 規避；公開 API 簽章變更需經使用者同意的規則維持不變。
- **未啟用**：在報告提醒「未啟用 PackageValidation 與 PublicAPI 分析器，未檢查公開 API 相容性」，不列為阻擋條件。
- **專案檔**：保留既有 `*.csproj` 與 `Directory.Build.props`，不為啟用檢查而修改。
- **回報位置**：在 Developer 結案報告、資源派遣報告或主 Agent 的完成回覆中，擇所使用者寫明檢查結果、未檢查原因或提醒。

## Object Creation 與 Var

- 只在 C# 版本支援時使用 Target-typed `new`，例如 `Type x = new();`。
- `var` 使用以 `.editorconfig` 為準。沒有相關設定時原則上禁用，只在匿名型別或極度複雜的巢狀泛型中使用。

## Types 與 Memory

- 字串比較明確指定比較規則，例如 `StringComparison.OrdinalIgnoreCase`。
- 時間型別遵循專案既有慣例。專案統一使用 `DateTime` 時維持該型別，統一使用 `DateTimeOffset` 時維持該型別。新建程式碼沒有既有慣例時優先使用 `DateTimeOffset`。
- 同一專案內的 `DateTime` 不混用 `Local`、`Utc` 與 `Unspecified`。
- 空字串使用空字串文字，不使用 `string.Empty`。

## Collection Type Selection

依語意選擇最窄的集合介面，並同時檢查能力、執行緒安全與列舉順序三軸，不預設使用 `List<T>`：

| 介面 | 能力 | 執行緒安全 | 列舉順序 | 適用情境 |
| --- | --- | --- | --- | --- |
| `IEnumerable<T>` | 迭代 | 介面不提供同步；來源不可變或由呼叫端保護 | 只反映來源順序，不由介面保證 | 方法參數、只需走訪的回傳值 |
| `IReadOnlyCollection<T>` | 迭代 + Count | 介面不提供同步；來源不可變或由呼叫端保護 | 只反映來源順序，不由介面保證 | 需要數量但無需索引存取 |
| `IReadOnlyList<T>` | 迭代 + Count + 索引 | 介面不提供同步；來源不可變或由呼叫端保護 | 只反映來源順序，不由介面保證 | DTO 屬性、唯讀回傳值 |
| `ICollection<T>` | 迭代 + Count + Add/Remove | 預設非執行緒安全；並行寫入需明確同步 | 只反映實作順序，不由介面保證 | 可修改但不需索引的集合 |
| `IList<T>` | 迭代 + Count + 索引 + Add/Remove | 預設非執行緒安全；並行寫入需明確同步 | 只反映實作順序，不由介面保證 | 可修改且需索引的集合 |
| `List<T>` | 具體型別 | 預設非執行緒安全；並行寫入需明確同步 | 目前實例的索引順序可用，但跨來源契約需自行排序 | 僅限內部實作或明確需要 `List<T>` 方法時 |

- Modern .NET 且語言版本支援時，DTO / Response 物件的集合屬性使用 `IReadOnlyList<T> { get; init; }`，搭配集合運算式 `[]` 預設值防止 null。
- Legacy .NET Framework（C# 7.3）使用 `IReadOnlyList<T> { get; private set; }` 搭配建構函式或 `new List<T>()` 初始化，防止 null；不使用 `init` 與集合運算式 `[]`。
- 可修改的聚合根 / Builder 物件使用 `{ get; } = new List<T>();` 或 `ICollection<T> { get; } = new List<T>();`，固定屬性參考並允許元素增減。
- DTO 禁止使用 `List<T> { get; set; }`，避免同時暴露具體型別與可替換屬性。
- 方法參數偏好 `IEnumerable<T>`，需要索引時使用 `IReadOnlyList<T>`，不要求呼叫端傳入 `List<T>`。
- `private` 與 `internal` 方法若不需要替換實作或跨 assembly 的抽象契約，可依 CA1859 回傳實際集合型別，讓編譯器保留具體型別資訊；`public`、`protected` 與提供給外部 assembly 的 `internal` 契約仍使用最窄介面。
- 集合型別只表達能力，不自動提供執行緒安全或 business order；需要共享讀寫時加入明確同步策略，需要穩定順序時以 sequence 或 `OrderBy` 建立契約。

## Nullable Value Types 與 NRT

- 對 `Nullable<T>` Value Types 檢查是否有值時，優先使用 `.HasValue`。
- 專案啟用 Nullable Reference Types 時消除所有相關警告。專案未啟用時不強迫開啟。
- NRT 的 `required`、`init` / `set`、禁止假預設值與 null 檢查寫法依 `csharp-nrt` skill 執行，null 檢查統一使用 `is not null`。

## Logging 與 Nameof

- 實作日誌時優先使用 `[LoggerMessage]` Attribute 與 Source Generator。
- 引用成員名稱時使用 `nameof()`，不硬編碼字串。
