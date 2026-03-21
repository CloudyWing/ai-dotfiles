---
name: csharp-di
description: '.NET 相依性注入進階規範：Generic Host、Worker Service、Keyed Services 與 Decorator 模式。'
---

# .NET 相依性注入進階規範

當使用者撰寫涉及 DI 容器進階配置的程式碼（如 Worker Service、多實作切換、Decorator 模式）時，請自動套用以下規範。基礎 DI Lifetime 規範參閱 `csharp-aspnetcore` skill。

## Generic Host

- 非 Web 應用程式（Console、Worker Service）使用 `Host.CreateDefaultBuilder()` 或 `Host.CreateApplicationBuilder()` 建立宿主，統一 DI、Configuration、Logging 基礎設施。
- **禁止**在 Generic Host 應用程式中手動建立 `ServiceCollection` 再 `BuildServiceProvider()`，除非是單元測試場景。

```csharp
// ✅ 正確
HostApplicationBuilder builder = Host.CreateApplicationBuilder(args);
builder.Services.AddHostedService<MyWorker>();
IHost host = builder.Build();
await host.RunAsync().ConfigureAwait(false);

// ❌ 錯誤：手動建立容器
ServiceCollection services = new();
services.AddSingleton<IMyService, MyService>();
ServiceProvider provider = services.BuildServiceProvider();
```

## Worker Service（BackgroundService）

- 繼承 `BackgroundService` 並覆寫 `ExecuteAsync()`。
- `ExecuteAsync()` 內的迴圈**必須**檢查 `CancellationToken`，確保 Graceful Shutdown。
- 需要使用 Scoped 服務時，透過 `IServiceScopeFactory` 在迴圈內建立 Scope：

```csharp
public class OrderProcessorWorker(
    IServiceScopeFactory scopeFactory,
    ILogger<OrderProcessorWorker> logger
) : BackgroundService {
    protected override async Task ExecuteAsync(CancellationToken stoppingToken) {
        while (!stoppingToken.IsCancellationRequested) {
            await using AsyncServiceScope scope = scopeFactory.CreateAsyncScope();
            IOrderService orderService = scope.ServiceProvider
                .GetRequiredService<IOrderService>();

            await orderService.ProcessPendingOrdersAsync(stoppingToken)
                .ConfigureAwait(false);

            await Task.Delay(TimeSpan.FromSeconds(30), stoppingToken)
                .ConfigureAwait(false);
        }
    }
}
```

## 註冊慣例

### 介面與實作分離

- 註冊服務時**必須**以介面為服務型別，具體實作為實作型別。
- 禁止直接註冊具體類別（除非該類別本身就是最終消費端，如 `BackgroundService`）。

```csharp
// ✅ 正確
builder.Services.AddScoped<IOrderService, OrderService>();

// ❌ 錯誤
builder.Services.AddScoped<OrderService>();
```

### 多實作註冊

- 同一介面的多個實作，優先使用 **Keyed Services**（.NET 8+）區分：

```csharp
builder.Services.AddKeyedScoped<INotificationService, EmailNotificationService>("email");
builder.Services.AddKeyedScoped<INotificationService, SmsNotificationService>("sms");

// 消費端
public class OrderController(
    [FromKeyedServices("email")] INotificationService emailNotifier
) { }
```

- 若需注入所有實作，使用 `IEnumerable<T>` 接收：

```csharp
builder.Services.AddScoped<IValidator, NameValidator>();
builder.Services.AddScoped<IValidator, EmailValidator>();

// 消費端：注入所有 IValidator 實作
public class ValidationService(IEnumerable<IValidator> validators) { }
```

## Decorator 模式

- 需要在現有服務外層加入橫切邏輯（如快取、日誌、重試）時，使用 Decorator 模式。
- 手動註冊 Decorator 時，透過工廠方法取得內層服務：

```csharp
builder.Services.AddScoped<IProductRepository, ProductRepository>();
builder.Services.Decorate<IProductRepository, CachedProductRepository>();
```

- 若未使用 Scrutor 等套件，手動實作：

```csharp
builder.Services.AddScoped<ProductRepository>();
builder.Services.AddScoped<IProductRepository>(sp => {
    ProductRepository inner = sp.GetRequiredService<ProductRepository>();
    return new CachedProductRepository(inner, sp.GetRequiredService<IMemoryCache>());
});
```

## 驗證與診斷

- 開發環境啟用 `ValidateScopes` 與 `ValidateOnBuild`，及早發現 Captive Dependency 與遺漏註冊：

```csharp
HostApplicationBuilder builder = Host.CreateApplicationBuilder(args);

if (builder.Environment.IsDevelopment()) {
    builder.Services.BuildServiceProvider(new ServiceProviderOptions {
        ValidateScopes = true,
        ValidateOnBuild = true
    });
}
```

## 禁止模式

- **Service Locator**：禁止在業務邏輯中直接呼叫 `IServiceProvider.GetService<T>()`。服務應透過建構函式注入，而非在方法內自行解析。唯一允許的例外是工廠方法與 `BackgroundService` 內的 Scope 建立。
- **靜態服務存取**：禁止將 `IServiceProvider` 存放於靜態欄位供全域存取（如 `ServiceLocator.Instance`）。
