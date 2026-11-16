---
name: csharp-error-handling
description: 'C# 例外處理規範：例外設計原則、Guard Clause、全域錯誤處理與 ProblemDetails 回應標準化。當設計例外、撰寫 try-catch 或全域錯誤處理時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# C# 例外處理規範

## 例外設計原則（Crucial）

### 何時拋出例外

例外用於表達**程式無法繼續正常流程**的狀況，不用於控制流程。可預期的失敗（如查無資料）以回傳值處理，例如 `FindOrder` 回傳 `null` 後由呼叫端判斷，不以 `try-catch` 攔截 `OrderNotFoundException` 來分流。

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

### 重新拋出

- 重新拋出使用 `throw;`，保留原始堆疊追蹤；禁止 `throw ex;`（Stack Trace 會從該處重新開始）。
- 包裝為更高層的例外時，將原例外傳入內部例外（inner exception）。

### finally 與資源釋放

- 需要確保資源釋放時，優先使用 `using` 語句；`try/finally` 僅在 `using` 無法滿足的情境使用。
- `finally` 區塊中**禁止**拋出新例外（會覆蓋原始例外）。

## 全域錯誤處理（ASP.NET Core）

### IExceptionHandler（.NET 8+）

- 實作 `IExceptionHandler`（如 `GlobalExceptionHandler`）：記錄例外後寫出狀態 500 的 ProblemDetails，`Title` 使用通用訊息（如「伺服器內部錯誤」），不輸出例外細節，回傳 `true` 表示已處理。
- 以 `AddExceptionHandler<T>()` 與 `AddProblemDetails()` 註冊，並在管線呼叫 `app.UseExceptionHandler()`；未呼叫時已註冊的 Handler 不會被執行。

### 多重 Handler 鏈

`IExceptionHandler` 支援鏈式註冊，依註冊順序執行。每個 Handler 回傳 `true` 表示已處理、`false` 表示交給下一個。可用於按例外類型分流處理。

```csharp
builder.Services.AddExceptionHandler<ValidationExceptionHandler>();
builder.Services.AddExceptionHandler<BusinessExceptionHandler>();
builder.Services.AddExceptionHandler<GlobalExceptionHandler>(); // 兜底
```

## ProblemDetails 標準化（Crucial）

所有 API 錯誤回應必須遵循 RFC 9457（ProblemDetails）。

- 以 `Results.Problem(title, detail, statusCode)` 回傳錯誤，不回傳 `{ code, message }` 這類自訂格式。
- 驗證錯誤以 `Results.ValidationProblem(errors)` 回傳，`errors` 為欄位名稱對應訊息陣列的字典。

## Result Pattern（視專案慣例）

若專案採用 Result Pattern 取代例外驅動的錯誤處理，遵循以下原則：

- Result 類別包含 `IsSuccess`、`Value`（成功時）、`Error`（失敗時）。
- Service Layer 以 `Result<T>.Success(value)` 或 `Result<T>.Failure(error)` 回傳 Result，Controller / Endpoint 層轉換為對應的 HTTP 回應：成功回傳對應結果（如 `Results.Created`），失敗以 `Results.Problem` 回傳並把 `Error` 放入 `detail`（業務錯誤如 400）。
- **不混用**：同一個 Service 方法不同時使用 Result 回傳與拋出例外來表達業務錯誤。
