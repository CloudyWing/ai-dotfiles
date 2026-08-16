---
name: csharp-validation
description: 'C# 輸入驗證規範：DataAnnotations、FluentValidation 選型、驗證層級劃分與 ASP.NET Core 整合策略。當撰寫 Request 驗證或設計輸入檢核時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# C# 輸入驗證規範

## 驗證層級（Crucial）

輸入驗證分為三個層級，各有職責，不可混淆：

| 層級 | 職責 | 負責位置 | 範例 |
| --- | --- | --- | --- |
| 格式驗證 | 資料型別、必填、長度、格式 | Model Binding / Request Model | 必填欄位、Email 格式、字串長度 |
| 商業規則驗證 | 需要查詢資料庫或外部狀態的規則 | Service Layer | 帳號是否重複、庫存是否足夠 |
| 不變式保護 | Domain Model 自身的完整性約束 | Domain Model 建構函式 | 金額不可為負、起始日不可晚於結束日 |

- **格式驗證**在 Controller / Endpoint 層自動觸發，驗證失敗直接回傳 400，不進入 Service。
- **商業規則驗證**在 Service Layer 處理，透過例外或 Result Pattern 回報（依專案慣例）。
- **不變式保護**在 Domain Model 的建構函式或 setter 中以 Guard Clause 實作。

## 驗證框架選型

### DataAnnotations（預設選擇）

適用於大多數格式驗證場景。ASP.NET Core Model Binding 原生支援，零設定即可使用。

```csharp
public class CreateOrderRequest {
    [Required(ErrorMessage = "客戶名稱為必填。")]
    [StringLength(100, ErrorMessage = "客戶名稱不可超過 100 字。")]
    public required string CustomerName { get; set; }

    [Range(1, 10000, ErrorMessage = "數量必須介於 1 到 10000 之間。")]
    public required int Quantity { get; set; }

    [EmailAddress(ErrorMessage = "Email 格式不正確。")]
    public string? ContactEmail { get; set; }
}
```

### FluentValidation（複雜或跨屬性驗證）

適用於需要跨屬性條件判斷、依情境切換規則、或需要注入服務的驗證場景。

```csharp
public class CreateOrderRequestValidator : AbstractValidator<CreateOrderRequest> {
    public CreateOrderRequestValidator() {
        RuleFor(x => x.CustomerName)
            .NotEmpty().WithMessage("客戶名稱為必填。")
            .MaximumLength(100).WithMessage("客戶名稱不可超過 100 字。");

        RuleFor(x => x.Quantity)
            .InclusiveBetween(1, 10000).WithMessage("數量必須介於 1 到 10000 之間。");

        RuleFor(x => x.ContactEmail)
            .EmailAddress().WithMessage("Email 格式不正確。")
            .When(x => x.ContactEmail is not null);
    }
}
```

### 選型原則

- **不在同一個專案中混用**兩種框架做同一層級的驗證。選定後全專案統一。
- 新專案若無跨屬性驗證需求，從 DataAnnotations 開始；需要時再引入 FluentValidation。
- 遵循**專案既有慣例**，不主動替換已使用的框架。

## DataAnnotations 規範

### 常用 Attributes

| Attribute | 用途 |
| --- | --- |
| `[Required]` | 必填（搭配 NRT 的 `required` keyword 使用） |
| `[StringLength(max)]` | 字串最大長度 |
| `[MinLength]` / `[MaxLength]` | 集合或字串的長度限制 |
| `[Range(min, max)]` | 數值範圍 |
| `[EmailAddress]` | Email 格式 |
| `[Phone]` | 電話格式 |
| `[Url]` | URL 格式 |
| `[RegularExpression]` | 自訂正規表達式 |
| `[Compare]` | 兩個屬性值必須一致（如密碼確認） |
| `[AllowedValues]` | 限制允許的值（.NET 8+） |
| `[DeniedValues]` | 限制禁止的值（.NET 8+） |
| `[Length(min, max)]` | 同時限制最小與最大長度（.NET 8+） |

### ErrorMessage 規範

- 每個驗證 Attribute **必須**提供 `ErrorMessage`，不使用框架預設的英文訊息。
- 錯誤訊息使用**台灣用語正體中文**。
- 訊息格式：「{欄位中文名}{驗證規則說明}。」（以句號結尾）。

### 自訂 ValidationAttribute

```csharp
[AttributeUsage(AttributeTargets.Property | AttributeTargets.Field)]
public class TaiwanIdAttribute : ValidationAttribute {
    protected override ValidationResult? IsValid(object? value, ValidationContext validationContext) {
        if (value is not string id) {
            return ValidationResult.Success;
        }

        if (!TaiwanIdValidator.IsValid(id)) {
            return new ValidationResult(ErrorMessage ?? "身分證格式不正確。");
        }

        return ValidationResult.Success;
    }
}
```

## FluentValidation 規範

### 註冊

```csharp
// 掃描組件中所有 Validator 並註冊
builder.Services.AddValidatorsFromAssemblyContaining<CreateOrderRequestValidator>();
```

### Minimal API 整合

Minimal API 不像 MVC 有自動 Model Validation Filter。需要手動驗證或搭配 Endpoint Filter。

```csharp
// Endpoint Filter 方式
public class ValidationFilter<T>(IValidator<T> validator) : IEndpointFilter
    where T : class {
    public async ValueTask<object?> InvokeAsync(
        EndpointFilterInvocationContext context,
        EndpointFilterDelegate next
    ) {
        T? model = context.Arguments.OfType<T>().FirstOrDefault();
        if (model is null) {
            return Results.Problem(title: "無效的請求", statusCode: 400);
        }

        ValidationResult result = await validator.ValidateAsync(model).ConfigureAwait(false);
        if (!result.IsValid) {
            return Results.ValidationProblem(result.ToDictionary());
        }

        return await next(context).ConfigureAwait(false);
    }
}

// 使用
app.MapPost("/api/orders", (CreateOrderRequest request) => { /* ... */ })
   .AddEndpointFilter<ValidationFilter<CreateOrderRequest>>();
```

### 跨屬性驗證

```csharp
public class DateRangeRequestValidator : AbstractValidator<DateRangeRequest> {
    public DateRangeRequestValidator() {
        RuleFor(x => x.StartDate)
            .NotEmpty().WithMessage("起始日期為必填。");

        RuleFor(x => x.EndDate)
            .NotEmpty().WithMessage("結束日期為必填。")
            .GreaterThanOrEqualTo(x => x.StartDate)
            .WithMessage("結束日期不可早於起始日期。");
    }
}
```

### 條件式驗證

```csharp
RuleFor(x => x.CompanyName)
    .NotEmpty().WithMessage("公司名稱為必填。")
    .When(x => x.CustomerType == CustomerType.Business);
```

## ASP.NET Core 整合

### Model State 自動驗證（Controller）

ASP.NET Core MVC 預設啟用 `[ApiController]` 時，Model Validation 失敗會自動回傳 `ValidationProblemDetails`（400）。不需要在每個 Action 中手動檢查 `ModelState.IsValid`。

```csharp
// ❌ 不需要：[ApiController] 已自動處理
[HttpPost]
public IActionResult Create(CreateOrderRequest request) {
    if (!ModelState.IsValid) {
        return BadRequest(ModelState);
    }
    // ...
}

// ✅ 正確：直接使用，驗證由框架處理
[HttpPost]
public IActionResult Create(CreateOrderRequest request) {
    // request 到達此處已通過格式驗證
    // ...
}
```

### 停用自動驗證的情境

若需要自訂驗證流程（如部分欄位條件式驗證），可在特定 Controller 停用：

```csharp
builder.Services.Configure<ApiBehaviorOptions>(options => {
    options.SuppressModelStateInvalidFilter = true;
});
```

## 防禦性驗證原則

- **驗證在系統邊界執行**：API 入口、訊息消費者、檔案匯入等外部資料進入點。
- **內部方法之間不重複驗證**：Service 呼叫 Repository 時，不需要再驗證一次參數格式（已在入口處驗證）。
- **信任 DI 注入的服務**：不對注入的服務做 null check（DI Container 保證）。
- **禁止過度防禦**：不在每個方法都加滿 Guard Clause，只在公開 API 方法與建構函式中驗證。

```csharp
// ✅ 正確：公開方法驗證參數
public class OrderService {
    private readonly IOrderRepository repository;

    public OrderService(IOrderRepository repository) {
        this.repository = repository;
    }

    public async Task<Order> GetOrderAsync(int orderId, CancellationToken cancellationToken) {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(orderId);

        return await repository.GetByIdAsync(orderId, cancellationToken).ConfigureAwait(false)
            ?? throw new KeyNotFoundException($"找不到 ID 為 {orderId} 的訂單。");
    }
}

// ❌ 錯誤：私有方法重複驗證已在公開方法中驗證過的值
private decimal CalculateTotal(int quantity, decimal unitPrice) {
    ArgumentOutOfRangeException.ThrowIfNegativeOrZero(quantity);    // 多餘
    ArgumentOutOfRangeException.ThrowIfNegativeOrZero(unitPrice);  // 多餘
    return quantity * unitPrice;
}
```
