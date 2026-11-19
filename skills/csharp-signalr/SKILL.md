---
name: csharp-signalr
description: 'SignalR Hub 開發規範：Hub Lifetime、群組管理、認證整合、錯誤處理與 Scale-Out 策略。當撰寫或修改 SignalR Hub 與即時推播功能時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# SignalR Hub 開發規範

## Hub Lifetime

- Hub 實例為 **Transient**：每次用戶端呼叫 Hub 方法時，都會建立新的 Hub 實例。
- **禁止**在 Hub 中儲存狀態（instance field）。跨呼叫的狀態必須使用外部儲存（如 Redis、資料庫或 `IMemoryCache`）。
- Hub 可透過建構函式注入 Scoped 與 Transient 服務。注入 Singleton 服務時需注意執行緒安全。

## Hub 設計原則

### 方法命名

- Hub 方法（Server-side）使用 PascalCase，與 C# 方法慣例一致。
- 用戶端接收的事件名稱（`SendAsync` 的第一個參數）使用 PascalCase，與前端 `on` 方法對應。
- 命名應明確表達動作語意（如 `SendMessage`、`JoinRoom`、`LeaveRoom`）。

### 強型別 Hub（推薦）

使用介面定義用戶端方法（如 `IChatClient`），Hub 繼承 `Hub<IChatClient>`，獲得編譯時期型別檢查。

## 群組管理

- 群組名稱使用有意義的識別字（如 `room:{roomId}`、`order:{orderId}`）。

## 認證與授權

- JWT 認證時，Token 透過 Query String 傳遞（WebSocket 不支援自訂 Header）。在 `JwtBearerEvents.OnMessageReceived` 讀取 Query String 的 `access_token`，僅在 Token 有值且 `context.HttpContext.Request.Path.StartsWithSegments("/hubs")` 成立時設為 `context.Token`。路徑以 `StartsWithSegments` 依路徑段比對，不以字串前綴比對，`/hubs-admin` 這類路徑不得接受 Query String Token。

## 錯誤處理

- 開發環境可啟用詳細錯誤：`builder.Services.AddSignalR(o => o.EnableDetailedErrors = true);`
- 需要回傳結構化錯誤給用戶端時，使用 `HubException`。

## 設定與註冊

- Hub 路由掛在 `/hubs/` 之下（如 `/hubs/chat`），與 JWT 的路徑判斷一致。
- `EnableDetailedErrors` 只在開發環境啟用（`builder.Environment.IsDevelopment()`）。
- 訊息大小上限與逾時（`MaximumReceiveMessageSize`、`KeepAliveInterval`、`ClientTimeoutInterval`）依需求在 `AddSignalR` 明確設定。

## Scale-Out

單一伺服器實例時，SignalR 使用 In-Memory 管理連線。多實例部署時，必須使用 Backplane 同步訊息。

### Redis Backplane

- 以 `AddStackExchangeRedis` 設定，並以 `options.Configuration.ChannelPrefix`（`RedisChannel.Literal("<應用程式名稱>")`）區隔共用同一個 Redis 的應用程式。

### 選型原則

| Backplane | 適用情境 |
| --- | --- |
| Redis | 通用首選，支援 Pub/Sub |
| Azure SignalR Service | Azure 部署，免管理 Backplane |
| SQL Server | 已有 SQL Server 且流量不高 |
