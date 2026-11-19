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

撰寫或修改 Blazor 元件（`.razor.cs` 與 `@code` 區塊）的 `[Inject]`、`[Parameter]`、`[SupplyParameterFromForm]`、`[CascadingParameter]` 屬性或欄位宣告時，先讀 `references/blazor.md`。`= default!` 在 Blazor 元件只有該檔表列的兩種情境可用。

---

## 集合與 NRT

### 規範

- DTO / Response 的集合屬性：集合本身不應為 null，用 `= []` 初始化。元素是否 nullable 依業務語意決定。
- 方法參數的集合：集合本身通常不接受 null（呼叫端傳空集合），除非 null 與空集合有不同語意。
- 方法回傳值：回傳空集合而非 null。

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
2. **Blazor 元件的表單 Model 與 `[Inject]` 屬性**：僅限 `references/blazor.md` 表列的兩種情境。
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
