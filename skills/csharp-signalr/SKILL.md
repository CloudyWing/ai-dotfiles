---
name: csharp-signalr
description: 'SignalR Hub 開發規範：方法與事件命名、強型別 Hub、群組命名、JWT Query String 的路徑判斷、路由慣例與 Redis Backplane 的 ChannelPrefix。當撰寫或修改 SignalR Hub 與即時推播功能時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# SignalR Hub 開發規範

## Hub 設計原則

### 方法命名

- Hub 方法（Server-side）使用 PascalCase，與 C# 方法慣例一致。
- 用戶端接收的事件名稱（`SendAsync` 的第一個參數）使用 PascalCase，與前端 `on` 方法對應。

### 強型別 Hub（推薦）

使用介面定義用戶端方法（如 `IChatClient`），Hub 繼承 `Hub<IChatClient>`，獲得編譯時期型別檢查。

## 群組管理

- 群組名稱使用有意義的識別字（如 `room:{roomId}`、`order:{orderId}`）。

## 認證與授權

- JWT 認證時，Token 透過 Query String 傳遞（WebSocket 不支援自訂 Header）。在 `JwtBearerEvents.OnMessageReceived` 讀取 Query String 的 `access_token`，僅在 Token 有值且 `context.HttpContext.Request.Path.StartsWithSegments("/hubs")` 成立時設為 `context.Token`。路徑以 `StartsWithSegments` 依路徑段比對，不以字串前綴比對，`/hubs-admin` 這類路徑不得接受 Query String Token。

## 設定與註冊

- Hub 路由掛在 `/hubs/` 之下（如 `/hubs/chat`），與 JWT 的路徑判斷一致。
- `EnableDetailedErrors` 只在開發環境啟用（`builder.Environment.IsDevelopment()`）。
- 訊息大小上限與逾時（`MaximumReceiveMessageSize`、`KeepAliveInterval`、`ClientTimeoutInterval`）依需求在 `AddSignalR` 明確設定。

## Scale-Out

### Redis Backplane

- 以 `AddStackExchangeRedis` 設定，並以 `options.Configuration.ChannelPrefix`（`RedisChannel.Literal("<應用程式名稱>")`）區隔共用同一個 Redis 的應用程式。
