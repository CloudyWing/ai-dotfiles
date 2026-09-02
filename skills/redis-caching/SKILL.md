---
name: redis-caching
description: 'Redis 快取開發規範：Key 命名階層、TTL 策略、Cache-Aside 模式與 StackExchange.Redis 連線管理。當撰寫或修改快取邏輯時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Redis 快取開發規範

## Key 命名（Crucial）

- 格式：`<app>:<entity>:<識別值>[:<面向>]`，全小寫、冒號分隔階層。例如 `shop:product:1024`、`shop:product:1024:stock`。
- 應用程式前綴必填，避免多系統共用 Redis 時互撞。
- Key 中的識別值必須有界（ID、代碼），**禁止**把使用者輸入的自由文字直接組進 Key。
- 掃描 Key 一律使用 `SCAN`（`IServer.Keys` 底層即 SCAN），**禁止**在正式環境執行 `KEYS`。

## TTL 策略（Crucial）

- **每個快取 Key 都必須設定 TTL**，禁止無期限快取（配置類長效資料也應設長 TTL 而非永久）。
- 同類 Key 的 TTL 加入隨機抖動（如基準值 ±10%），避免同時到期造成快取雪崩。
- TTL 長度依資料容忍的過期程度決定，並集中定義為常數或設定，不散落 magic number。

## 快取模式

- **預設 Cache-Aside**：讀取先查快取，未命中查資料來源後回填。寫入時**失效（刪除）對應 Key**，不採「寫入時更新快取值」（雙寫易產生不一致）。
- 高併發熱點 Key 的回源需防擊穿：優先使用 .NET 9+ 的 `HybridCache`（內建 stampede 防護與 L1/L2 兩層）；未使用 HybridCache 時以 per-key 鎖或單飛（single-flight）模式限制同時回源數。
- 高併發 Key 的 concurrent rebuild 必須在每個 Key 維持 single-flight。`HybridCache` 內部維護的 in-flight 狀態由 `HybridCache` 擁有與清理，呼叫端不得以自建 per-key lock 清除或釋放該狀態；應用程式自建的 per-key lock 與 in-flight 狀態由建立它的協調器擁有。互斥鎖本身不構成 single-flight，成功取得 lock 後必須重新檢查快取，或讓所有請求共用同一個 in-flight `Task`。
- 應用程式自建的回源工作在成功取得 lock 後，無論成功、失敗或取消，都要在其 `try` / `finally` 釋放 lock 並清除由該工作擁有的 in-flight 狀態。只有成功取得 lock 的執行緒或非同步工作可以釋放該 lock；取消或例外若發生在 `WaitAsync` 成功返回前，不得釋放未持有的 lock。使用 `SemaphoreSlim` 時，`WaitAsync(cancellationToken)` 成功返回後才進入包覆回源工作的 `try`，並將 `Release` 放在該 `try` 的 `finally`。
- per-key 狀態的移除必須涵蓋等待者。每個等待者必須以不可分割的原子步驟取得狀態參考並登記等待者計數，不能先讀取參考再稍後計數；完成等待與回源後才遞減。只有狀態表仍指向同一個 state、持有者已完成且等待者計數歸零時，才可 reference-conditional removal。也可改用 Task-based coalescing，且只能在同一個 in-flight `Task` 完成後移除。A 清除狀態後，C 不得建立新 semaphore 再讓仍持有舊狀態參考的 B 並行回源。
- **穿透防護**：查無資料的結果以短 TTL（如 30〜60 秒）快取空值標記，避免不存在的 ID 反覆打穿到資料庫。
- `null`、有效的空集合與查無資料標記是不同的結果契約。有效空集合依資料新鮮度使用一般 TTL；查無資料或 `null` 使用短 TTL，且每一種結果都要定義回源與序列化表示，不以空集合推導未授權的補償資料。

## 失效容錯（Crucial）

- 快取故障不得中斷業務：Redis GET、反序列化、連線失敗或逾時時記錄警告並直接回源，**禁止**把 Redis exception 往上拋成 5xx。應用程式自建且由該回源工作成功取得的 lock 或 in-flight 狀態也必須在失敗路徑釋放；`HybridCache` 內部狀態則由 `HybridCache` 自行清理。長時間回源仍須受既定 timeout 與 cancellation token 約束，狀態移除遵守等待者計數或同一 Task 完成條件。
- 回源路徑必須獨立可用，不得存在「只有快取有、資料來源沒有」的資料。

## StackExchange.Redis 慣例

- `ConnectionMultiplexer` 全應用程式單例，交由實作 `IAsyncDisposable` 的 provider wrapper 持有。DI 只註冊 wrapper，不在 registration factory 執行外部 I/O；wrapper 在明確的非同步方法內建立連線，`IDatabase` 為輕量物件，隨用隨取，不快取也不包 `using`。

```csharp
public sealed class RedisConnectionProvider : IAsyncDisposable
{
    private readonly SemaphoreSlim connectionGate = new(1, 1);
    private readonly ConfigurationOptions options;
    private ConnectionMultiplexer? multiplexer;
    private int disposed;

    public RedisConnectionProvider(IConfiguration configuration)
    {
        string connectionString = configuration.GetConnectionString("Redis")
            ?? throw new InvalidOperationException("Redis connection string is missing");

        options = ConfigurationOptions.Parse(connectionString);
        options.ConnectTimeout = 3000;
    }

    public async Task<ConnectionMultiplexer> GetAsync(
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();

        ConnectionMultiplexer? current = Volatile.Read(ref multiplexer);
        if (current?.IsConnected == true)
        {
            return current;
        }

        await connectionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            ThrowIfDisposed();

            current = multiplexer;
            if (current?.IsConnected == true)
            {
                return current;
            }

            current?.Dispose();
            multiplexer = null;

            current = await ConnectionMultiplexer
                .ConnectAsync(options)
                .ConfigureAwait(false);
            multiplexer = current;
            return current;
        }
        catch
        {
            multiplexer = null;
            throw;
        }
        finally
        {
            connectionGate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        await connectionGate.WaitAsync().ConfigureAwait(false);
        try
        {
            ConnectionMultiplexer? current =
                Interlocked.Exchange(ref multiplexer, null);
            current?.Dispose();
        }
        finally
        {
            connectionGate.Release();
            connectionGate.Dispose();
        }
    }

    private void ThrowIfDisposed()
    {
        if (Volatile.Read(ref disposed) != 0)
        {
            throw new ObjectDisposedException(nameof(RedisConnectionProvider));
        }
    }
}

builder.Services.AddSingleton<RedisConnectionProvider>();
```

此範例的建構函式與 DI registration factory 只解析設定並建立 wrapper，不呼叫 `Connect`、`ConnectAsync` 或取得連線值，符合 SD-001。需要預熱時，Hosted Service 必須 `await provider.GetAsync(cancellationToken)` 並觀察成功回傳或例外，將結果納入 readiness 或記錄策略。`GetAsync` 成功時回傳並快取連線；建立失敗時清除 `multiplexer`，將例外交給快取失效容錯層，下一次呼叫重新建立連線，不永久快取 faulted `Task`。每次連線建立的 timeout 為 3000 毫秒；`WaitAsync` 尚未成功時的取消不會釋放 semaphore，已取得 semaphore 後會先重新檢查取消，連線嘗試再由 `ConnectTimeout` 限制。DI 會在 Host shutdown 呼叫 provider 的 `DisposeAsync`，由 wrapper 關閉內部 `ConnectionMultiplexer`；Host 應先停止新的呼叫，再等待處置完成。這組預熱結果、timeout 與失敗狀態契約符合 SD-007。

- 序列化統一使用 `System.Text.Json`（camelCase），反序列化容忍未知欄位；結構變更時以改 Key 版本段（如 `shop:product:v2:1024`）處理，不就地混存新舊結構。
- 抽象層選型：一般快取需求優先 `HybridCache` / `IDistributedCache`；需要 Redis 原生資料結構（Hash、Sorted Set、Stream、分散式鎖）時才直接使用 `IDatabase`，並將存取集中於獨立的 Repository / Service 類別，不散落於業務邏輯。

## 禁止模式

- 禁止把 Redis 當唯一持久層存放不可重建的業務資料（快取內容必須可從資料來源重建）。
- 禁止在迴圈中逐 Key 呼叫（N 次 round-trip）；批次讀寫使用 `StringGetAsync(RedisKey[])`、pipeline 或 Lua script。
- 禁止大 Key（單值數 MB、集合數十萬元素）；需要時拆分結構並記錄設計理由。
