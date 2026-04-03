---
name: csharp-error-handling
description: 'C# 例外處理規範：例外設計原則、Guard Clause、全域錯誤處理與 ProblemDetails 回應標準化。'
---

# C# 例外處理規範

當撰寫或審查 C# 的錯誤處理邏輯時，請自動套用以下規範。

## 例外設計原則（Crucial）

### 何時拋出例外

例外用於表達**程式無法繼續正常流程**的狀況，不用於控制流程。

```csharp
// ❌ 錯誤：用例外控制流程
try {
    Order order = GetOrder(id);
    Process(order);
} catch (OrderNotFoundException) {
    return NotFound();
}

// ✅ 正確：可預期的失敗用回傳值處理
Order? order = FindOrder(id);
if (order is null) {
    return NotFound();
}

Process(order);
```

### 例外類型選用

| 例外類型 | 適用情境 |
| --- | --- |
| `ArgumentNullException` | 參數為 null |
| `ArgumentException` | 參數值不合法（非 null 但不符規則） |
| `ArgumentOutOfRangeException` | 參數超出允許範圍 |
| `InvalidOperationException` | 物件狀態不允許目前操作 |
| `NotSupportedException` | 介面方法在此實作中不支援 |
| `KeyNotFoundException` | 以鍵查詢但不存在 |
| `FormatException` | 字串格式不符預期 |

- 可預期的業務錯誤（如「餘額不足」「庫存不足」）：依專案慣例，使用自訂例外或 Result Pattern，不使用 `Exception` 基底類別。
- **禁止** `throw new Exception("...")`（太籠統，呼叫端無法精確捕捉）。

### 自訂例外

```csharp
// ✅ 正確：繼承最接近語意的例外類別
public class InsufficientBalanceException : InvalidOperationException {
    public InsufficientBalanceException(decimal required, decimal available)
        : base($"餘額不足：需要 {required}，可用 {available}。") {
        Required = required;
        Available = available;
    }

    public decimal Required { get; }
    public decimal Available { get; }
}
```

- 自訂例外命名以 `Exception` 結尾。
- 攜帶與錯誤直接相關的結構化資料（如上例的 `Required`、`Available`），方便呼叫端判斷處理。

## Guard Clause（Crucial）

方法入口處優先驗證前置條件，驗證失敗立即拋出例外，避免巢狀 if-else。

### 內建 Guard 方法（.NET 6+）

```csharp
public void CreateOrder(string customerName, int quantity) {
    ArgumentException.ThrowIfNullOrWhiteSpace(customerName);
    ArgumentOutOfRangeException.ThrowIfNegativeOrZero(quantity);

    // 業務邏輯
}
```

常用的內建 Guard 方法：

| 方法 | .NET 版本 |
| --- | --- |
| `ArgumentNullException.ThrowIfNull` | 6+ |
| `ArgumentException.ThrowIfNullOrEmpty` | 7+ |
| `ArgumentException.ThrowIfNullOrWhiteSpace` | 7+ |
| `ArgumentOutOfRangeException.ThrowIfZero` | 8+ |
| `ArgumentOutOfRangeException.ThrowIfNegative` | 8+ |
| `ArgumentOutOfRangeException.ThrowIfNegativeOrZero` | 8+ |
| `ArgumentOutOfRangeException.ThrowIfGreaterThan` | 8+ |
| `ArgumentOutOfRangeException.ThrowIfLessThan` | 8+ |
| `ObjectDisposedException.ThrowIf` | 8+ |

- 以上方法皆透過 `[CallerArgumentExpression]` 自動取得參數名稱，**不需要**傳入 `nameof`。
- 若目標框架不支援某 Guard 方法，使用傳統 `if + throw` 寫法。

## try-catch 規範

### 捕捉原則

- **只捕捉你能處理的例外**。無法處理的例外讓它向上傳播，由全域錯誤處理統一處理。
- **禁止**空的 catch 區塊（吞掉例外）。
- **禁止**捕捉 `Exception` 基底類別後不做任何處理。

```csharp
// ❌ 錯誤：吞掉例外
try {
    await SendEmailAsync(order);
} catch (Exception) {
    // 靜默忽略
}

// ✅ 正確：若允許信件發送失敗，至少記錄日誌
try {
    await SendEmailAsync(order);
} catch (SmtpException ex) {
    logger.LogWarning(ex, "訂單 {OrderId} 的通知信發送失敗", order.Id);
}
```

### 重新拋出

```csharp
// ✅ 正確：保留原始堆疊追蹤
catch (DbUpdateException ex) {
    logger.LogError(ex, "資料庫更新失敗");
    throw; // 保留原始 Stack Trace
}

// ❌ 錯誤：破壞堆疊追蹤
catch (DbUpdateException ex) {
    throw ex; // Stack Trace 從此處重新開始
}

// ✅ 正確：包裝為更高層的例外時，傳入內部例外
catch (DbUpdateException ex) {
    throw new OrderPersistenceException("訂單儲存失敗", ex);
}
```

### finally 與資源釋放

- 需要確保資源釋放時，優先使用 `using` 語句；`try/finally` 僅在 `using` 無法滿足的情境使用。
- `finally` 區塊中**禁止**拋出新例外（會覆蓋原始例外）。

## 全域錯誤處理（ASP.NET Core）

### Exception Handler Middleware

```csharp
// Program.cs
if (app.Environment.IsDevelopment()) {
    app.UseDeveloperExceptionPage();
} else {
    app.UseExceptionHandler();
}

app.UseStatusCodePages();
```

### IExceptionHandler（.NET 8+）

```csharp
public class GlobalExceptionHandler(ILogger<GlobalExceptionHandler> logger) : IExceptionHandler {
    public async ValueTask<bool> TryHandleAsync(
        HttpContext httpContext,
        Exception exception,
        CancellationToken cancellationToken
    ) {
        logger.LogError(exception, "未處理的例外");

        ProblemDetails problemDetails = new() {
            Status = StatusCodes.Status500InternalServerError,
            Title = "伺服器內部錯誤"
        };

        httpContext.Response.StatusCode = problemDetails.Status.Value;
        await httpContext.Response.WriteAsJsonAsync(problemDetails, cancellationToken)
            .ConfigureAwait(false);

        return true;
    }
}

// 註冊
builder.Services.AddExceptionHandler<GlobalExceptionHandler>();
builder.Services.AddProblemDetails();
```

### 多重 Handler 鏈

`IExceptionHandler` 支援鏈式註冊，依註冊順序執行。每個 Handler 回傳 `true` 表示已處理、`false` 表示交給下一個。可用於按例外類型分流處理。

```csharp
builder.Services.AddExceptionHandler<ValidationExceptionHandler>();
builder.Services.AddExceptionHandler<BusinessExceptionHandler>();
builder.Services.AddExceptionHandler<GlobalExceptionHandler>(); // 兜底
```

## ProblemDetails 標準化（Crucial）

所有 API 錯誤回應必須遵循 RFC 9457（ProblemDetails）。

```csharp
// ✅ 正確
return Results.Problem(
    title: "訂單不存在",
    detail: $"找不到 ID 為 {orderId} 的訂單。",
    statusCode: StatusCodes.Status404NotFound
);

// ❌ 錯誤：自訂格式
return Results.Json(new { code = 404, message = "Not found" }, statusCode: 404);
```

### 驗證錯誤

```csharp
return Results.ValidationProblem(
    errors: new Dictionary<string, string[]> {
        ["CustomerName"] = ["客戶名稱為必填欄位。"],
        ["Quantity"] = ["數量必須大於零。"]
    }
);
```

## Result Pattern（視專案慣例）

若專案採用 Result Pattern 取代例外驅動的錯誤處理，遵循以下原則：

- Result 類別包含 `IsSuccess`、`Value`（成功時）、`Error`（失敗時）。
- Service Layer 回傳 Result，Controller / Endpoint 層轉換為對應的 HTTP 回應。
- **不混用**：同一個 Service 方法不同時使用 Result 回傳與拋出例外來表達業務錯誤。

```csharp
// Service
public Result<Order> PlaceOrder(PlaceOrderRequest request) {
    if (request.Quantity <= 0) {
        return Result<Order>.Failure("數量必須大於零。");
    }

    // 業務邏輯...
    return Result<Order>.Success(order);
}

// Endpoint
Result<Order> result = orderService.PlaceOrder(request);
return result.IsSuccess
    ? Results.Created($"/api/orders/{result.Value.Id}", result.Value)
    : Results.Problem(title: "下單失敗", detail: result.Error, statusCode: 400);
```

## 非同步例外處理

- `async Task` 方法中的例外會被捕獲並封裝在回傳的 `Task` 中，由 `await` 時重新拋出。
- **禁止** `async void`（例外無法被捕捉，會直接崩潰）。唯一例外：事件處理器。
- 使用 `CancellationToken` 時，`OperationCanceledException` 通常不需要記錄為錯誤（屬於正常取消流程）。

```csharp
try {
    await ProcessOrderAsync(order, cancellationToken);
} catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) {
    logger.LogInformation("訂單處理已取消");
}
```
