---
name: csharp-nrt
description: 'C# Nullable Reference Types 規範：依類別用途選擇正確的屬性宣告策略，禁止用假預設值消除警告，並列出 EF Core Navigation Property 與 Blazor 元件屬性的例外條件。當專案啟用 NRT 且撰寫或修改型別宣告（含 Blazor 元件的 `.razor.cs` 與 `@code` 區塊）時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# C# Nullable Reference Types (NRT) 規範

當專案啟用 NRT（`<Nullable>enable</Nullable>`）時，自動套用以下規範。專案未啟用 NRT 時，不強迫修改。

## 核心原則

**用型別系統表達語意，不用假預設值消除警告。**

屬性是否 nullable、是否 required，應反映業務語意，而非為了讓編譯器安靜。

### 禁止模式

以下寫法一律禁止，除非本文件明確列出的例外情境：

```csharp
// ❌ 硬塞預設值消警告
public string Name { get; set; } = "";
public string Name { get; set; } = default!;
public string Name { get; set; } = null!;
public OrderDto Order { get; set; } = default!;
```

### 允許的預設值

集合屬性使用空集合初始化是合理的語意表達（空集合 ≠ null），不屬於「假預設值」：

```csharp
// ✅ 集合用空集合初始化
public IReadOnlyList<string> Tags { get; init; } = [];
public required IReadOnlyList<OrderItemDto> Items { get; init; } = [];
```

---

## 屬性宣告策略（依類別用途）

### DTO / Response Model

API 回傳或層間傳遞的資料物件。所有必填屬性使用 `required init`。

```csharp
public class OrderDto {
    public required int Id { get; init; }
    public required string CustomerName { get; init; }
    public string? Note { get; init; }
    public required IReadOnlyList<OrderItemDto> Items { get; init; } = [];
}
```

### Request / Input Model（API Binding、Form Binding）

ASP.NET Core Model Binding 與 `System.Text.Json` 反序列化需要 setter。必填屬性使用 `required set`。

```csharp
public class CreateOrderRequest {
    public required string CustomerName { get; set; }
    public required IReadOnlyList<CreateOrderItemRequest> Items { get; set; } = [];
    public string? Note { get; set; }
}
```

> `System.Text.Json` 從 .NET 7 起支援 `required` keyword，反序列化時缺少必填屬性會拋出 `JsonException`。若需相容 `Newtonsoft.Json`，改用 `[JsonRequired]` attribute。

### EF Core Entity

EF Core 透過內部機制具現化 Entity，不走建構函式。屬性使用 `set`（非 `init`，因為 EF 的 change tracking 需要 setter）。

**一般屬性**：必填欄位不加 `?`，由 EF 與資料庫 NOT NULL 條件約束保證賦值。編譯器警告透過建構函式或 `required` 消除。

```csharp
public class Order {
    public int Id { get; set; }
    public required string CustomerName { get; set; }
    public string? Note { get; set; }
    public DateTime CreatedAt { get; set; }
}
```

**搭配建構函式與 `[SetsRequiredMembers]`**：若 Entity 同時提供帶參數建構函式（供應用程式碼使用）與無參數建構函式（供 EF Core 具現化），在帶參數建構函式上標註 `[SetsRequiredMembers]`，讓呼叫端不需要再透過 object initializer 賦值 `required` 屬性。

```csharp
public class Order {
    [SetsRequiredMembers]
    public Order(string customerName) {
        CustomerName = customerName;
    }

    // EF Core 具現化用
    private Order() { }

    public int Id { get; set; }
    public required string CustomerName { get; set; }
    public string? Note { get; set; }
}
```

**Navigation Properties（例外情境）**：Navigation Property 由 EF Core 的 lazy loading 或 eager loading 機制賦值，無法在建構函式中初始化。此處允許使用 `= null!`。

```csharp
public class OrderItem {
    public int Id { get; set; }
    public int OrderId { get; set; }

    // ✅ Navigation Property 允許 null!（EF Core 保證載入時賦值）
    public Order Order { get; set; } = null!;

    // ✅ Collection Navigation 用空集合初始化
    public ICollection<Tag> Tags { get; set; } = new List<Tag>();
}
```

### Blazor 元件

Blazor 元件屬性只有下表兩種情境可用 `= default!`。允許的依據是生命週期方法讀取前屬性一定已賦值：表單 Model 的保證寫在同一元件生命週期方法的開頭，`[Inject]` 的保證來自框架在建構元件後完成的屬性注入，服務未註冊時拋出 `InvalidOperationException`，不會留下 `null`。

| 情境 | 宣告 | 成立條件 |
| --- | --- | --- |
| `[SupplyParameterFromForm]` 的表單 Model | `= default!` | 同一元件的 `OnInitialized` 或 `OnInitializedAsync` 在方法開頭寫無條件的 `屬性 ??= new();`，之前沒有其他敘述；同一元件有多個表單 Model 時，各自的 `??= new();` 連續排在方法開頭。expression-bodied 寫法則整個方法本體就是這個運算式（`=> Model ??= new();`） |
| `[Inject]` 屬性 | `= default!` | 符合下列任一項：宣告在供其他元件繼承的基底元件類別；使用 `[Inject(Key = ...)]` 注入 keyed service；目標框架為 .NET 8 以下 |

- 寫法統一為 `default!`，與官方文件及範本一致。Blazor 元件屬性上的 `= null!` 不屬於本例外。
- 表單 Model 寫成 `= new()` 會觸發 BL0008。表單 POST 時框架可能把屬性覆寫為 `null`，因此改在 `OnInitialized{Async}` 補建實體。
- 補建必須寫在方法開頭，理由是放在條件分支內、讀取之後或 `await` 之後時，元件可能在屬性仍為 `null` 時讀取或先轉譯一次。
- `[Inject]` 屬性在元件建構函式執行期間尚未注入，建構函式內不讀取 `[Inject]` 屬性。

```csharp
// ✅ 表單 Model：無條件的 ??= new() 寫在方法開頭
[SupplyParameterFromForm]
private OrderRequest Model { get; set; } = default!;

protected override async Task OnInitializedAsync() {
    Model ??= new();
    await LoadProductsAsync();
}

// ✅ 基底元件類別的注入
public abstract class PageComponentBase : ComponentBase {
    [Inject]
    protected NavigationManager Navigation { get; set; } = default!;
}

// ✅ 一般元件：.razor.cs 用傳統建構函式注入，.razor 用 @inject
public partial class OrderList {
    private readonly IOrderService orderService;

    public OrderList(IOrderService orderService) {
        this.orderService = orderService;
    }
}
```

下列框架賦值的屬性與欄位依表中方式宣告，不適用 `default!`：

| 對象 | 宣告方式 | 理由 |
| --- | --- | --- |
| 一般元件的 `[Inject]`（.NET 9 以上，keyed service 除外） | `.razor.cs` 用傳統建構函式注入（見 `csharp-language-features`），`.razor` 用 `@inject` | 建構函式注入不需要屬性初始值 |
| 初始化完成後仍可能為 `null` 的 `[SupplyParameterFromForm]`（純量欄位、依查詢載入且可能查無資料的 Model） | `T?` | `null` 是真實狀態，應由使用處處理 |
| `[CascadingParameter]`（含 `HttpContext`） | `T?` | 只有上層提供時才有值；`HttpContext` 只在 static SSR 有值，interactive 轉譯時為 `null` |
| `[Parameter]`（含 `[EditorRequired]`） | `T?`；集合型別可宣告為非 nullable 並以 `= []` 初始化 | `[EditorRequired]` 與非 nullable 宣告都只產生編譯期警告，呼叫端仍可在執行期傳入 `null`。集合以 `= []` 初始化後，未傳入時元件直接處理空集合，省去 `null` 判斷 |
| 在生命週期方法中才賦值的欄位或屬性（如 `EditContext`、從 `ScopedServices` 取得的服務；符合允許表的表單 Model 除外） | `T?` | 賦值依賴呼叫順序，例外或提早轉譯時仍為 `null` |

```csharp
// ❌ 依查詢載入的 Model 可能查無資料，不適用例外
[SupplyParameterFromForm]
private Movie Movie { get; set; } = default!;

// ✅ 宣告為 nullable，查無資料時處理 null
[SupplyParameterFromForm]
private Movie? Movie { get; set; }
```

`[Parameter]` 的集合型別指可用集合運算式 `[]` 初始化的序列型別，例如 `IReadOnlyList<T>`、`IList<T>`、`List<T>`、`T[]`、`IEnumerable<T>`。`string` 與字典型別不屬於此類，依表中 `T?` 宣告。以 `= []` 初始化時，注意下列三點：

- `= []` 無法區分未傳入與傳入空集合。需要區分時改用 `T?`。
- 呼叫端明確傳入 `null` 時，屬性值為 `null`，`= []` 擋不住。元件在使用處以 `Items ?? []` 讀取，不在元件內改寫參數本身。
- `= []` 只在元件建立後從未傳入時生效。以 `@attributes` 展開或 `DynamicComponent` 傳參時，前一次有傳、這次沒傳的參數保留上一次的值，不會回到 `[]`。

**範本產生碼**：ASP.NET Core Identity scaffold 產生的 `Components/Account/` 檔案，以成員為判定單位。維持範本原樣的成員不套用本節；新增或改寫的成員依本節規則宣告。其他來源複製的程式碼不屬於範本產生碼。

**審查判定**：搜尋 `= default!` 與 `= null!`，每個命中須為 EF Core Navigation Property 的 `null!`、本節表列的兩種 `default!` 情境，或 `Components/Account/` 內維持範本原樣的成員。其餘命中列為 Major。

### Domain Model

透過建構函式保護不變式 (invariant)，屬性盡量唯讀。

```csharp
public class Customer {
    public Customer(string name, string email) {
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        ArgumentException.ThrowIfNullOrWhiteSpace(email);
        Name = name;
        Email = email;
    }

    public int Id { get; private set; }
    public string Name { get; private set; }
    public string Email { get; private set; }
    public string? Phone { get; private set; }
}
```

若 Domain Model 同時使用 `required` 屬性，建構函式可標註 `[SetsRequiredMembers]`：

```csharp
public class Customer {
    [SetsRequiredMembers]
    public Customer(string name, string email) {
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        ArgumentException.ThrowIfNullOrWhiteSpace(email);
        Name = name;
        Email = email;
    }

    public int Id { get; private set; }
    public required string Name { get; private set; }
    public required string Email { get; private set; }
    public string? Phone { get; private set; }
}
```

### Record Types

Record 的 positional parameter 天生具備 `required` 語意，不需額外標註。

```csharp
// positional parameter 本身即為必填
public record OrderSummary(int Id, string CustomerName, decimal Total);

// 可選屬性另外宣告
public record CustomerInfo(string Name, string Email) {
    public string? Phone { get; init; }
}
```

---

## 集合與 NRT

### 元素 Nullability

集合本身的 nullability 與元素的 nullability 是獨立的兩件事：

| 宣告 | 集合本身 | 元素 |
| --- | --- | --- |
| `IReadOnlyList<string>` | 非 null | 非 null |
| `IReadOnlyList<string>?` | 可 null | 非 null |
| `IReadOnlyList<string?>` | 非 null | 可 null |
| `IReadOnlyList<string?>?` | 可 null | 可 null |

### 規範

- DTO / Response 的集合屬性：集合本身不應為 null，用 `= []` 初始化。元素是否 nullable 依業務語意決定。
- 方法參數的集合：集合本身通常不接受 null（呼叫端傳空集合），除非 null 與空集合有不同語意。
- 方法回傳值：回傳空集合而非 null。

```csharp
// ✅ 正確
public IReadOnlyList<string> GetTags() {
    // 無資料時回傳空集合
    return [];
}

// ❌ 錯誤：回傳 null 強迫呼叫端做 null check
public IReadOnlyList<string>? GetTags() {
    return null;
}
```

### Dictionary 的 TryGetValue

`TryGetValue` 的 `out` 參數在 NRT 下為 `T?`，編譯器會正確推斷。不需要加 `!`。

```csharp
if (dict.TryGetValue(key, out string? value)) {
    // 此處 value 已被編譯器推斷為非 null
    Console.WriteLine(value.Length);
}
```

---

## Null 檢查寫法

### 統一使用 Pattern Matching

```csharp
// ✅ 優先
if (order is not null) { }
if (order is null) { }

// ❌ 避免（除非型別有自訂 == operator 且需要觸發）
if (order != null) { }
if (order == null) { }
```

選擇 `is not null` / `is null` 的理由：不受 `==` / `!=` operator overloading 影響，語意明確且一致。

### 禁止的 Null 檢查模式

```csharp
// ❌ 不使用 is { } 作為 null check（語意不直觀）
if (order is { }) { }
```

---

## Null-Forgiving Operator (`!`)

### 原則：非完全禁止，但嚴格限制

允許使用的情境：

1. **EF Core Navigation Property**（如上述）。
2. **Blazor 元件的表單 Model 與 `[Inject]` 屬性**：僅限「Blazor 元件」一節表列的兩種情境。
3. **測試程式碼中，`Assert` 之後的存取**：

   ```csharp
   OrderDto? result = await GetOrderAsync(id);
   Assert.That(result, Is.Not.Null);
   // Assert 後已保證非 null，允許 !
   string name = result!.CustomerName;
   ```

4. **編譯器流程分析的盲區**：已有足夠的上下文保證非 null，但編譯器無法推斷。應搭配註解說明理由。

禁止使用的情境：

- 為了消除警告而不加思考地附加 `!`。
- `FirstOrDefault()!`、`SingleOrDefault()!`：`OrDefault` 語意本身就表示可能為 null，加 `!` 是自相矛盾。應改用 `First()` / `Single()`（確定有值時），或正確處理 null。
- `(await SomeAsync())!`：若回傳值可能為 null，應處理 null，而非用 `!` 略過。

---

## Guard Clause

### `ArgumentNullException.ThrowIfNull`

此方法透過 `[CallerArgumentExpression]` 自動取得參數名稱，不需要傳入 `nameof`。

```csharp
// ✅ 正確：自動取得參數名
public void Process(Order order) {
    ArgumentNullException.ThrowIfNull(order);
}

// ❌ 多餘：手動傳入 nameof
public void Process(Order order) {
    ArgumentNullException.ThrowIfNull(order, nameof(order));
}
```

同理，`ArgumentException.ThrowIfNullOrEmpty` 和 `ArgumentException.ThrowIfNullOrWhiteSpace` 也不需要 `nameof`。

### 流程分析 Attributes

自訂的 Try-pattern 或 guard 方法，應搭配 `System.Diagnostics.CodeAnalysis` 下的 attributes，讓編譯器正確推斷 nullability：

```csharp
public static bool TryParse(string? input, [NotNullWhen(true)] out OrderId? result) {
    if (string.IsNullOrWhiteSpace(input)) {
        result = null;
        return false;
    }

    result = new OrderId(input);
    return true;
}
```

常用 attributes：

| Attribute | 用途 |
| --- | --- |
| `[NotNullWhen(true)]` | 方法回傳 true 時，該參數保證非 null |
| `[MaybeNullWhen(false)]` | 方法回傳 false 時，該參數可能為 null |
| `[NotNull]` | 方法正常返回時，該參數保證非 null（否則拋例外） |
| `[MemberNotNull]` | 方法執行後，指定的成員保證非 null |

---

## 編譯器流程分析的已知能力

以下方法呼叫後，編譯器能自動推斷變數非 null，不需要額外加 `!`：

- `string.IsNullOrEmpty()` / `string.IsNullOrWhiteSpace()` 的 false 分支
- `ArgumentNullException.ThrowIfNull()` 之後
- `is not null` 判斷的 true 分支
- `?? throw` 之後的變數

```csharp
// ✅ 編譯器自動推斷，不需要 !
if (!string.IsNullOrEmpty(name)) {
    // name 在此處已被推斷為 string（非 null）
    int length = name.Length;
}

string validated = input ?? throw new ArgumentException("Input is required.");
// validated 在此處已被推斷為非 null
```
