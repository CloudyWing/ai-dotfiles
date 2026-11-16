---
name: csharp-signalr
description: 'SignalR Hub 開發規範：Hub Lifetime、群組管理、認證整合、錯誤處理與 Scale-Out 策略。當撰寫或修改 SignalR Hub 與即時推播功能時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# SignalR Hub 開發規範

## Hub Lifetime（Crucial）

- Hub 實例為 **Transient**：每次用戶端呼叫 Hub 方法時，都會建立新的 Hub 實例。
- **禁止**在 Hub 中儲存狀態（instance field）。跨呼叫的狀態必須使用外部儲存（如 Redis、資料庫或 `IMemoryCache`）。
- Hub 可透過建構函式注入 Scoped 與 Transient 服務。注入 Singleton 服務時需注意執行緒安全。

```csharp
// ❌ 錯誤：在 Hub 中儲存狀態
public class ChatHub : Hub {
    private readonly List<string> messages = []; // 每次呼叫都是新實例，此欄位無用

    public async Task SendMessage(string message) {
        messages.Add(message); // 永遠只有一筆
    }
}

// ✅ 正確：使用外部服務管理狀態
public class ChatHub : Hub {
    private readonly IChatService chatService;

    public ChatHub(IChatService chatService) {
        this.chatService = chatService;
    }

    public async Task SendMessage(string message) {
        await chatService.SaveMessageAsync(message).ConfigureAwait(false);
        await Clients.All.SendAsync("ReceiveMessage", message).ConfigureAwait(false);
    }
}
```

## Hub 設計原則

### 方法命名

- Hub 方法（Server-side）使用 PascalCase，與 C# 方法慣例一致。
- 用戶端接收的事件名稱（`SendAsync` 的第一個參數）使用 PascalCase，與前端 `on` 方法對應。
- 命名應明確表達動作語意（如 `SendMessage`、`JoinRoom`、`LeaveRoom`）。

### 強型別 Hub（推薦）

使用介面定義用戶端方法，獲得編譯時期型別檢查。

```csharp
public interface IChatClient {
    Task ReceiveMessage(string user, string message);
    Task UserJoined(string user);
    Task UserLeft(string user);
}

public class ChatHub : Hub<IChatClient> {
    private readonly IChatService chatService;

    public ChatHub(IChatService chatService) {
        this.chatService = chatService;
    }

    public async Task SendMessage(string message) {
        string user = Context.User?.Identity?.Name ?? "匿名";
        await chatService.SaveMessageAsync(user, message).ConfigureAwait(false);
        await Clients.All.ReceiveMessage(user, message).ConfigureAwait(false);
    }
}
```

## 群組管理

- 群組名稱使用有意義的識別字（如 `room:{roomId}`、`order:{orderId}`）。

## 認證與授權

- JWT 認證時，Token 透過 Query String 傳遞（WebSocket 不支援自訂 Header）：

```csharp
builder.Services.AddAuthentication().AddJwtBearer(options => {
    options.Events = new JwtBearerEvents {
        OnMessageReceived = context => {
            string? accessToken = context.Request.Query["access_token"];
            PathString path = context.HttpContext.Request.Path;
            if (!string.IsNullOrEmpty(accessToken) && path.StartsWithSegments("/hubs")) {
                context.Token = accessToken;
            }

            return Task.CompletedTask;
        }
    };
});
```

## 錯誤處理

- 開發環境可啟用詳細錯誤：`builder.Services.AddSignalR(o => o.EnableDetailedErrors = true);`
- 需要回傳結構化錯誤給用戶端時，使用 `HubException`。

## 設定與註冊

```csharp
// Program.cs
builder.Services.AddSignalR(options => {
    options.MaximumReceiveMessageSize = 64 * 1024; // 64 KB
    options.KeepAliveInterval = TimeSpan.FromSeconds(15);
    options.ClientTimeoutInterval = TimeSpan.FromSeconds(30);
    options.EnableDetailedErrors = builder.Environment.IsDevelopment();
});

app.MapHub<ChatHub>("/hubs/chat");
```

## Scale-Out

單一伺服器實例時，SignalR 使用 In-Memory 管理連線。多實例部署時，必須使用 Backplane 同步訊息。

### Redis Backplane

```csharp
builder.Services.AddSignalR()
    .AddStackExchangeRedis(connectionString, options => {
        options.Configuration.ChannelPrefix = RedisChannel.Literal("MyApp");
    });
```

### 選型原則

| Backplane | 適用情境 |
| --- | --- |
| Redis | 通用首選，支援 Pub/Sub |
| Azure SignalR Service | Azure 部署，免管理 Backplane |
| SQL Server | 已有 SQL Server 且流量不高 |
