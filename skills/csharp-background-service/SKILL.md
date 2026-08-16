---
name: csharp-background-service
description: 'Background Service 開發規範：BackgroundService、IHostedService、Channel Queue 模式與生命週期管理。當撰寫或審查 .NET 背景工作、排程任務或佇列處理邏輯時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Background Service 開發規範

## 選型指引（Crucial）

| 基底類別 | 適用情境 |
| --- | --- |
| `BackgroundService` | 長期執行的迴圈式工作（如輪詢、佇列消費） |
| `IHostedService` | 需精確控制啟動 / 停止順序的初始化或清理任務 |

- `BackgroundService` 繼承自 `IHostedService`，提供 `ExecuteAsync` 抽象方法，適合大多數場景。
- `IHostedService` 適合在 `StartAsync` 中做一次性初始化（如預熱快取、建立連線），不需要持續迴圈。

## BackgroundService 實作規範

### 基本結構

```csharp
public class OrderSyncService : BackgroundService {
    private readonly IServiceScopeFactory scopeFactory;
    private readonly ILogger<OrderSyncService> logger;

    public OrderSyncService(IServiceScopeFactory scopeFactory, ILogger<OrderSyncService> logger) {
        this.scopeFactory = scopeFactory;
        this.logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken) {
        logger.LogInformation("OrderSyncService 已啟動");

        while (!stoppingToken.IsCancellationRequested) {
            try {
                await using AsyncServiceScope scope = scopeFactory.CreateAsyncScope();
                IOrderRepository repository = scope.ServiceProvider
                    .GetRequiredService<IOrderRepository>();

                await repository.SyncPendingOrdersAsync(stoppingToken).ConfigureAwait(false);
            } catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) {
                // 正常停止，不記錄為錯誤
            } catch (Exception ex) {
                logger.LogError(ex, "訂單同步發生錯誤，將在下次迴圈重試");
            }

            await Task.Delay(TimeSpan.FromMinutes(5), stoppingToken).ConfigureAwait(false);
        }

        logger.LogInformation("OrderSyncService 已停止");
    }
}
```

### 關鍵規範

- **CancellationToken**：`ExecuteAsync` 的 `stoppingToken` 必須傳遞給所有非同步操作與 `Task.Delay`。
- **例外處理（Crucial）**：`ExecuteAsync` 中的未處理例外會導致整個 Host 停止（.NET 6+ 預設行為）。迴圈式工作**必須**在 `while` 內部 try-catch，記錄錯誤後繼續下次迴圈。
- **OperationCanceledException**：`stoppingToken` 觸發時，`Task.Delay` 和非同步操作會拋出此例外。使用 `when (stoppingToken.IsCancellationRequested)` 過濾，避免記錄為錯誤。

### Scoped 服務存取（Crucial）

BackgroundService 註冊為 Singleton，**不能**直接注入 Scoped 服務（如 DbContext）。必須透過 `IServiceScopeFactory` 建立 Scope。

```csharp
// ❌ 錯誤：直接注入 Scoped 服務
public class MyWorker : BackgroundService {
    public MyWorker(AppDbContext db) { /* ... */ }
}

// ✅ 正確：透過 IServiceScopeFactory
public class MyWorker : BackgroundService {
    private readonly IServiceScopeFactory scopeFactory;

    public MyWorker(IServiceScopeFactory scopeFactory) {
        this.scopeFactory = scopeFactory;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken) {
        await using AsyncServiceScope scope = scopeFactory.CreateAsyncScope();
        AppDbContext db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
    }
}

// ✅ 正確：EF Core 場景優先使用 IDbContextFactory
public class MyWorker : BackgroundService {
    private readonly IDbContextFactory<AppDbContext> factory;

    public MyWorker(IDbContextFactory<AppDbContext> factory) {
        this.factory = factory;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken) {
        await using AppDbContext db = await factory.CreateDbContextAsync(stoppingToken)
            .ConfigureAwait(false);
    }
}
```

## IHostedService 實作規範

```csharp
public class CacheWarmupService : IHostedService {
    private readonly IServiceScopeFactory scopeFactory;
    private readonly IMemoryCache cache;
    private readonly ILogger<CacheWarmupService> logger;

    public CacheWarmupService(
        IServiceScopeFactory scopeFactory,
        IMemoryCache cache,
        ILogger<CacheWarmupService> logger
    ) {
        this.scopeFactory = scopeFactory;
        this.cache = cache;
        this.logger = logger;
    }

    public async Task StartAsync(CancellationToken cancellationToken) {
        logger.LogInformation("開始預熱快取");

        await using AsyncServiceScope scope = scopeFactory.CreateAsyncScope();
        IProductRepository repository = scope.ServiceProvider
            .GetRequiredService<IProductRepository>();

        IReadOnlyList<Product> products = await repository
            .GetAllAsync(cancellationToken)
            .ConfigureAwait(false);

        cache.Set("products:all", products, TimeSpan.FromHours(1));
        logger.LogInformation("快取預熱完成，共 {Count} 筆產品", products.Count);
    }

    public Task StopAsync(CancellationToken cancellationToken) {
        return Task.CompletedTask;
    }
}
```

- `StartAsync` 應盡快完成，不阻塞 Host 啟動。若需要長期作業，在 `StartAsync` 中啟動 `Task` 並儲存參考，在 `StopAsync` 中等待完成。
- `StopAsync` 有 timeout（預設 30 秒），必須在時限內完成清理。

## Channel-based Queue 模式

適用於「生產者-消費者」場景：HTTP 請求快速入隊，背景服務非同步處理。

### 佇列定義

```csharp
public class BackgroundTaskQueue {
    private readonly Channel<Func<IServiceScopeFactory, CancellationToken, ValueTask>> channel
        = Channel.CreateBounded<Func<IServiceScopeFactory, CancellationToken, ValueTask>>(
            new BoundedChannelOptions(100) {
                FullMode = BoundedChannelFullMode.Wait
            });

    public async ValueTask EnqueueAsync(
        Func<IServiceScopeFactory, CancellationToken, ValueTask> workItem,
        CancellationToken cancellationToken
    ) {
        ArgumentNullException.ThrowIfNull(workItem);
        await channel.Writer.WriteAsync(workItem, cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask<Func<IServiceScopeFactory, CancellationToken, ValueTask>> DequeueAsync(
        CancellationToken cancellationToken
    ) {
        return await channel.Reader.ReadAsync(cancellationToken).ConfigureAwait(false);
    }
}
```

### 消費者

```csharp
public class QueuedHostedService : BackgroundService {
    private readonly BackgroundTaskQueue taskQueue;
    private readonly IServiceScopeFactory scopeFactory;
    private readonly ILogger<QueuedHostedService> logger;

    public QueuedHostedService(
        BackgroundTaskQueue taskQueue,
        IServiceScopeFactory scopeFactory,
        ILogger<QueuedHostedService> logger
    ) {
        this.taskQueue = taskQueue;
        this.scopeFactory = scopeFactory;
        this.logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken) {
        while (!stoppingToken.IsCancellationRequested) {
            Func<IServiceScopeFactory, CancellationToken, ValueTask> workItem
                = await taskQueue.DequeueAsync(stoppingToken).ConfigureAwait(false);

            try {
                await workItem(scopeFactory, stoppingToken).ConfigureAwait(false);
            } catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) {
                // 正常停止
            } catch (Exception ex) {
                logger.LogError(ex, "佇列工作項目執行失敗");
            }
        }
    }
}
```

### 生產者（Endpoint）

```csharp
app.MapPost("/api/reports/generate", async (
    GenerateReportRequest request,
    BackgroundTaskQueue queue,
    CancellationToken cancellationToken
) => {
    await queue.EnqueueAsync(async (scopeFactory, token) => {
        await using AsyncServiceScope scope = scopeFactory.CreateAsyncScope();
        IReportService reportService = scope.ServiceProvider
            .GetRequiredService<IReportService>();
        await reportService.GenerateAsync(request.ReportId, token).ConfigureAwait(false);
    }, cancellationToken).ConfigureAwait(false);

    return Results.Accepted();
});
```

### 註冊

```csharp
builder.Services.AddSingleton<BackgroundTaskQueue>();
builder.Services.AddHostedService<QueuedHostedService>();
```

## 定時任務（Timer-based）

### PeriodicTimer（.NET 6+，推薦）

```csharp
public class MetricsCollector : BackgroundService {
    private readonly ILogger<MetricsCollector> logger;

    public MetricsCollector(ILogger<MetricsCollector> logger) {
        this.logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken) {
        using PeriodicTimer timer = new(TimeSpan.FromSeconds(30));

        while (await timer.WaitForNextTickAsync(stoppingToken).ConfigureAwait(false)) {
            try {
                // 收集指標
                logger.LogDebug("收集系統指標");
            } catch (Exception ex) {
                logger.LogError(ex, "指標收集失敗");
            }
        }
    }
}
```

- `PeriodicTimer` 確保上一次 tick 的工作完成後才開始計時，避免重疊執行。
- 優於 `Task.Delay`：語意更明確，且不會因工作耗時導致間隔漂移。

## 註冊與啟動順序

```csharp
// 基本註冊
builder.Services.AddHostedService<OrderSyncService>();
builder.Services.AddHostedService<MetricsCollector>();
```

- Hosted Service 依**註冊順序**依次啟動（`StartAsync` 依序呼叫）。
- 停止時以**反向順序**依次停止。
- 若某個服務的啟動依賴另一個服務已完成初始化，應透過共享狀態（如 `TaskCompletionSource`）協調，不依賴註冊順序。

## 禁止模式

```csharp
// ❌ 禁止：在 Controller 中 Task.Run 長期工作
[HttpPost]
public IActionResult StartWork() {
    Task.Run(async () => await DoLongWorkAsync()); // Fire-and-forget，無法追蹤
    return Accepted();
}

// ❌ 禁止：在 ExecuteAsync 中不處理例外
protected override async Task ExecuteAsync(CancellationToken stoppingToken) {
    while (!stoppingToken.IsCancellationRequested) {
        await ProcessAsync(stoppingToken); // 未 try-catch，例外會終止 Host
        await Task.Delay(TimeSpan.FromMinutes(1), stoppingToken);
    }
}
```
