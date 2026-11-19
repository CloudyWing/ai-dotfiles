---
name: csharp-validation
description: 'C# 輸入驗證規範：DataAnnotations、FluentValidation 選型、驗證層級劃分、必填欄位與繫結來源，以及 ASP.NET Core 整合策略。當撰寫 Request 驗證或設計輸入檢核時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# C# 輸入驗證規範

## 驗證層級

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

### FluentValidation（複雜或跨屬性驗證）

適用於需要跨屬性條件判斷、依情境切換規則、或需要注入服務的驗證場景。

### 選型原則

- **不在同一個專案中混用**兩種框架做同一層級的驗證。選定後全專案統一。
- 新專案若無跨屬性驗證需求，從 DataAnnotations 開始；需要時再引入 FluentValidation。
- 遵循**專案既有慣例**，不主動替換已使用的框架。

## DataAnnotations 規範

### 常用 Attributes

| Attribute | 用途 |
| --- | --- |
| `[Required]` | 必填（搭配 NRT 的 `required` keyword 使用） |
| `[Compare]` | 兩個屬性值必須一致（如密碼確認） |
| `[AllowedValues]` | 限制允許的值（.NET 8+） |
| `[DeniedValues]` | 限制禁止的值（.NET 8+） |
| `[Length(min, max)]` | 同時限制最小與最大長度（.NET 8+） |

### ErrorMessage 規範

- 每個驗證 Attribute **必須**提供 `ErrorMessage`，不使用框架預設的英文訊息。
- 錯誤訊息使用**台灣用語正體中文**。
- 訊息格式：「{欄位中文名}{驗證規則說明}。」（以句號結尾）。

## FluentValidation 規範

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

## ASP.NET Core 整合

### Model State 自動驗證（Controller）

ASP.NET Core MVC 預設啟用 `[ApiController]` 時，Model Validation 失敗會自動回傳 `ValidationProblemDetails`（400）。不需要在每個 Action 中手動檢查 `ModelState.IsValid`。

### 必填欄位與繫結來源

- 實值型別繫結不到值時會得到預設值（例如 `bool` 為 `false`），無法分辨對方是漏傳還是傳了預設值。
- `[BindRequired]` 只對表單資料等模型繫結生效，對 `[FromBody]` 的 JSON 或 XML 不生效，因為 `[FromBody]` 的請求本文由 input formatter 反序列化，不經過模型繫結。`[FromBody]` 的實值型別必填欄位改用 `Nullable<T>` 搭配 `[Required]`，或使用 `required` 屬性（見 `csharp-nrt` skill）。
- 專案啟用 NRT 時，MVC 對非 nullable 的參考型別屬性隱含套用 `[Required(AllowEmptyStrings = true)]`，即使沒加 `[Required]` 也會擋下 `null`。空字串是否被擋依繫結來源而定。`[FromBody]` JSON 的空字串保留為空字串而通過；表單等模型繫結預設把空字串轉成 `null`，因此驗證失敗。

## 防禦性驗證原則

- **驗證在系統邊界執行**：API 入口、訊息消費者、檔案匯入等外部資料進入點。
- **內部方法之間不重複驗證**：Service 呼叫 Repository 時，不需要再驗證一次參數格式（已在入口處驗證）。
- **信任 DI 注入的服務**：不對注入的服務做 null check（DI Container 保證）。
- **禁止過度防禦**：不在每個方法都加滿 Guard Clause，範圍依 `ai-profile` skill 的 `project-kind` 與「專案層解析」決定：

| `project-kind` | Guard Clause 範圍 |
| --- | --- |
| `library` | `public` 成員（公開 API 方法與建構函式） |
| `application` | 系統邊界入口與 Domain Model 建構函式的不變式保護 |
| `sample` | 不強制 |
| 未設定 | 比照 `application` |
