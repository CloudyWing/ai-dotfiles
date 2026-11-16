# Blazor 元件

本檔收錄 Blazor 元件屬性（`.razor.cs` 與 `@code` 區塊中的 `[Inject]`、`[Parameter]`、`[SupplyParameterFromForm]`、`[CascadingParameter]` 等）的 NRT 宣告規則。撰寫或修改 Blazor 元件屬性時讀取。

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
