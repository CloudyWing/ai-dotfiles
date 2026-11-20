---
name: csharp-error-handling
description: 'C# 例外處理規範：業務錯誤的表達方式、Guard Clause 寫法、IExceptionHandler 全域錯誤處理與 ProblemDetails 回應標準化。當設計例外、撰寫 try-catch 或全域錯誤處理時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# C# 例外處理規範

## 業務錯誤的表達

- 可預期的業務錯誤（如「餘額不足」「庫存不足」）：依專案慣例，使用自訂例外或 Result Pattern，不使用 `Exception` 基底類別。
- **禁止** `throw new Exception("...")`（太籠統，呼叫端無法精確捕捉）。

## Guard Clause

- `ArgumentNullException.ThrowIfNull`、`ArgumentException.ThrowIfNullOrEmpty` 等內建 Guard 方法皆透過 `[CallerArgumentExpression]` 自動取得參數名稱，**不需要**傳入 `nameof`。
- 若目標框架不支援某 Guard 方法，使用傳統 `if + throw` 寫法。

## 全域錯誤處理（ASP.NET Core）

### IExceptionHandler（.NET 8+）

- 實作 `IExceptionHandler`（如 `GlobalExceptionHandler`）：記錄例外後寫出狀態 500 的 ProblemDetails，`Title` 使用通用訊息（如「伺服器內部錯誤」），不輸出例外細節，回傳 `true` 表示已處理。
- 以 `AddExceptionHandler<T>()` 與 `AddProblemDetails()` 註冊，並在管線呼叫 `app.UseExceptionHandler()`；未呼叫時已註冊的 Handler 不會被執行。

## ProblemDetails 標準化

所有 API 錯誤回應必須遵循 RFC 9457（ProblemDetails）。

- 以 `Results.Problem(title, detail, statusCode)` 回傳錯誤，不回傳 `{ code, message }` 這類自訂格式。
- 驗證錯誤以 `Results.ValidationProblem(errors)` 回傳，`errors` 為欄位名稱對應訊息陣列的字典。

## Result Pattern（視專案慣例）

若專案採用 Result Pattern 取代例外驅動的錯誤處理，遵循以下原則：

- Service Layer 以 `Result<T>.Success(value)` 或 `Result<T>.Failure(error)` 回傳 Result，Controller / Endpoint 層轉換為對應的 HTTP 回應：成功回傳對應結果（如 `Results.Created`），失敗以 `Results.Problem` 回傳並把 `Error` 放入 `detail`（業務錯誤如 400）。
- **不混用**：同一個 Service 方法不同時使用 Result 回傳與拋出例外來表達業務錯誤。
