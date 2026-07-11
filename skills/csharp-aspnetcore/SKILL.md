---
name: csharp-aspnetcore
description: 'ASP.NET Core 開發規範：DI Lifetime、HttpClient、回應格式與 API 版本控制。當偵測到 ASP.NET Core 專案或使用者要求撰寫 API 端點時自動套用。'
---

# ASP.NET Core 開發規範

當偵測到 ASP.NET Core 專案（含 `Microsoft.AspNetCore` 相依套件）或使用者要求撰寫 API 端點、Controller、Middleware 時，請自動套用以下規範。

## DI Lifetime（Crucial）

| Lifetime | 適用情境 |
| --- | --- |
| `Singleton` | 無狀態、執行緒安全的服務（如 `IOptions<T>`、記憶體快取） |
| `Scoped` | 每次 HTTP 請求一個實例；**DbContext 必須使用此 Lifetime** |
| `Transient` | 輕量、無狀態的短暫任務型服務 |

- Scoped 服務只能由 Scoped 或 Transient 消費；注入至 Singleton 將導致 **Captive Dependency**，造成資料隔離失效。
- 若需在 Singleton 中使用 Scoped 服務，必須透過 `IServiceScopeFactory` 手動建立 Scope。

## HttpClient

- **禁止**在方法內直接 `new HttpClient()`，會造成 Socket 耗盡問題。
- 必須透過 `IHttpClientFactory` 或具名/型別化用戶端（Named / Typed Client）注入。

```csharp
// ✅ 正確
builder.Services.AddHttpClient<MyService>();

public class MyService {
    private readonly HttpClient httpClient;

    public MyService(HttpClient httpClient) {
        this.httpClient = httpClient;
    }
}

// ❌ 錯誤
public void DoWork() {
    using HttpClient client = new();
}
```

## Minimal API vs Controller

- 不主動替換現有架構形式（Minimal API ↔ Controller）。
- 新建端點遵循**專案既有慣例**，不擅自引入另一種風格。

## 回應格式一致性

- API 的錯誤回應必須遵循 **ProblemDetails（RFC 7807）** 格式。
- 使用 `Results.Problem(...)` 或 `Results.ValidationProblem(...)` 產生標準化錯誤。

```csharp
// ✅ 正確
return Results.Problem(
    title: "資源不存在",
    statusCode: StatusCodes.Status404NotFound
);

// ❌ 錯誤
return Results.Json(new { error = "Not found" }, statusCode: 404);
```

## API 版本控制

- 若專案已啟用 API Versioning（如 `Asp.Versioning.Http`），產生或修改端點時必須加入對應版本路由前綴（如 `/api/v1/`）。
- 不在未啟用版本控制的專案中自行加入版本前綴。

## 設定讀取（IOptions vs IConfiguration）

- **禁止**在服務類別中直接注入 `IConfiguration` 並以字串索引取值，會散落硬編碼 Key 且缺乏型別安全。
- 統一使用 **Options Pattern**：定義 POCO 設定類別，以 `IOptions<T>` / `IOptionsSnapshot<T>` / `IOptionsMonitor<T>` 注入。

| 介面 | Lifetime | 適用情境 |
| --- | --- | --- |
| `IOptions<T>` | Singleton | 應用程式啟動後不會變更的設定 |
| `IOptionsSnapshot<T>` | Scoped | 每次請求重新讀取（支援熱更新，不可用於 Singleton） |
| `IOptionsMonitor<T>` | Singleton | 需要即時感知設定變更（支援 `OnChange` 回呼） |

```csharp
// 註冊
builder.Services.Configure<SmtpOptions>(
    builder.Configuration.GetSection("Smtp")
);

// 注入
public class EmailService {
    private readonly SmtpOptions smtp;

    public EmailService(IOptions<SmtpOptions> options) {
        smtp = options.Value;
    }
}
```

## 背景服務

- 不要在 Controller / Service 中自行 `Task.Run` 長期工作，一律改用 Hosted Service。
- 選型（`BackgroundService` vs `IHostedService`）、實作規範與 Scoped 服務存取，參閱 `csharp-background-service` skill，本文件不重複。
