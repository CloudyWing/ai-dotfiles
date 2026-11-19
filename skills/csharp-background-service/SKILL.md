---
name: csharp-background-service
description: 'Background Service 開發規範：IHostedService 預熱的有界條件、Channel Queue 模式、Timer 重疊與回收陷阱、多 instance 排程。當撰寫或審查 .NET 背景工作、排程任務或佇列處理邏輯時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Background Service 開發規範

## Scoped 服務存取

- EF Core 場景優先注入 `IDbContextFactory<TContext>`，以 `await using` 搭配 `CreateDbContextAsync(stoppingToken)` 建立並釋放 DbContext。

## IHostedService 實作規範

`IHostedService` 適合在 `StartAsync` 中做一次性初始化（如預熱快取、建立連線），不需要持續迴圈；僅限資料量與耗時有界、具取消處置且為 Host 就緒必要條件的工作。一般或無界外部 I/O 預熱應移至可追蹤且可取消的背景路徑。

在 `StartAsync` 預熱時，以 `CancellationTokenSource.CreateLinkedTokenSource(cancellationToken)` 建立連結的 CTS（以 `using` 釋放）並呼叫 `CancelAfter`（例如 5 秒）限制該次預熱耗時，傳遞至資料來源的必須是這個連結 CTS 的 `.Token`，不是 `StartAsync` 的原始 `cancellationToken`，資料來源才會同時因逾時與 Host 停止而取消；另以筆數上限限制單次預熱資料量（例如只取第一頁 100 筆）。預熱需要 Scoped 服務時以 `CreateAsyncScope` 解析。逾時或 Host 停止時，`StartAsync` 觀察取消例外並讓必要條件未滿足的 Host 維持啟動失敗。

- `StartAsync` 應快速返回，不在其中執行無界外部 I/O。需要長期或非必要預熱時，移到可追蹤且可取消的背景路徑，並在 `StopAsync` 等待已保存的工作完成。
- `StopAsync` 有 timeout（預設 30 秒），必須在時限內完成清理。

## Channel-based Queue 模式

適用於「生產者-消費者」場景：HTTP 請求快速入隊，背景服務非同步處理。

- 佇列使用有界 Channel（`Channel.CreateBounded`，容量依負載設定，例如 100），`FullMode` 為 `BoundedChannelFullMode.Wait`。
- 工作項目型別為 `Func<IServiceScopeFactory, CancellationToken, ValueTask>`，由工作項目自行建立 Scope 解析 Scoped 服務。
- 消費者為 `BackgroundService`，在迴圈內逐筆取出並以 try-catch 包住執行：`stoppingToken` 觸發時的 `OperationCanceledException` 視為正常停止，其餘例外記錄後繼續處理下一筆。
- 生產者（Endpoint）以 HTTP 請求的 `CancellationToken` 等待入隊（一路傳到 `channel.Writer.WriteAsync`），佇列已滿時用戶端中止請求即可取消等待；入隊後回傳 `202 Accepted`。
- 消費者取出（`channel.Reader.ReadAsync`）與執行工作項目都使用 `stoppingToken`，工作項目收到的是這個停止 Token，不是請求的 Token。
- 佇列註冊為 Singleton，消費者以 `AddHostedService` 註冊。

## 定時任務（Timer-based）

- `System.Threading.Timer`、`System.Timers.Timer` 或其他 callback-based timer 若可能在前一次 callback 完成前再次觸發，必須改用 `PeriodicTimer`，或以該 timer 專用的 lock / semaphore 序列化 callback；不可只依賴 callback 順序。
- Timer 必須由生命週期擁有者保存強參考，並在停止或 dispose 生命週期結束時釋放。只有短暫區域變數或弱參考時，GC 可能回收 Timer，導致排程停止。

## 註冊與啟動順序

- 若某個服務的啟動依賴另一個服務已完成初始化，應透過共享狀態（如 `TaskCompletionSource`）協調，不依賴註冊順序。
- 多個 Host instance 會同時執行相同的 hosted schedule；需要單次執行時，使用分散式 lock、leader election 或集中式 queue，並以冪等處理作為重試與 lock 失效的最後保護。process 內 lock 只涵蓋單一 instance。

## 禁止模式

- 禁止在 Controller 或 Service 以 `Task.Run` 啟動長期工作，一律改用 Hosted Service。Fire-and-forget 的工作無法追蹤。
