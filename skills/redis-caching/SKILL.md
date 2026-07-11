---
name: redis-caching
description: 'Redis 快取開發規範：Key 命名階層、TTL 策略、Cache-Aside 模式與 StackExchange.Redis 連線管理。當撰寫或修改快取邏輯時自動套用。'
---

# Redis 快取開發規範

當撰寫或修改 Redis 快取相關程式碼時，請自動套用以下規範。

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
- **穿透防護**：查無資料的結果以短 TTL（如 30〜60 秒）快取空值標記，避免不存在的 ID 反覆打穿到資料庫。

## 失效容錯（Crucial）

- 快取故障不得中斷業務：連線失敗或逾時時記錄警告並直接回源，**禁止**把 Redis 例外往上拋成 5xx。
- 回源路徑必須獨立可用，不得存在「只有快取有、資料來源沒有」的資料。

## StackExchange.Redis 慣例

- `ConnectionMultiplexer` 全應用程式單例，透過 DI 註冊為 Singleton；`IDatabase` 為輕量物件，隨用隨取，不快取也不包 `using`。

```csharp
builder.Services.AddSingleton<IConnectionMultiplexer>(_ =>
    ConnectionMultiplexer.Connect(builder.Configuration.GetConnectionString("Redis")!));
```

- 序列化統一使用 `System.Text.Json`（camelCase），反序列化容忍未知欄位；結構變更時以改 Key 版本段（如 `shop:product:v2:1024`）處理，不就地混存新舊結構。
- 抽象層選型：一般快取需求優先 `HybridCache` / `IDistributedCache`；需要 Redis 原生資料結構（Hash、Sorted Set、Stream、分散式鎖）時才直接使用 `IDatabase`，並將存取集中於獨立的 Repository / Service 類別，不散落於業務邏輯。

## 禁止模式

- 禁止把 Redis 當唯一持久層存放不可重建的業務資料（快取內容必須可從資料來源重建）。
- 禁止在迴圈中逐 Key 呼叫（N 次 round-trip）；批次讀寫使用 `StringGetAsync(RedisKey[])`、pipeline 或 Lua script。
- 禁止大 Key（單值數 MB、集合數十萬元素）；需要時拆分結構並記錄設計理由。
