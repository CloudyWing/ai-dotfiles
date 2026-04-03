---
name: csharp-grpc
description: 'gRPC 服務開發規範：Proto 檔案管理、服務實作、攔截器、錯誤處理與用戶端工廠模式。'
---

# gRPC 服務開發規範

當偵測到專案使用 gRPC（含 `Grpc.AspNetCore` 或 `Google.Protobuf` 相依套件）或使用者要求撰寫 gRPC 服務時，請自動套用以下規範。

## Proto 檔案管理（Crucial）

### 目錄結構

```text
src/
├── Protos/
│   ├── order_service.proto
│   └── product_service.proto
├── Services/
│   ├── OrderGrpcService.cs
│   └── ProductGrpcService.cs
```

- Proto 檔案集中於 `Protos/` 目錄。
- 檔名使用 snake_case（`order_service.proto`），與 Protobuf 社群慣例一致。
- 每個 `.proto` 檔案對應一個邏輯上的服務domain。

### Proto 檔案規範

```protobuf
syntax = "proto3";

option csharp_namespace = "MyApp.Grpc";

package myapp.v1;

service OrderService {
  rpc GetOrder (GetOrderRequest) returns (GetOrderResponse);
  rpc ListOrders (ListOrdersRequest) returns (ListOrdersResponse);
  rpc CreateOrder (CreateOrderRequest) returns (CreateOrderResponse);
}

message GetOrderRequest {
  int32 id = 1;
}

message GetOrderResponse {
  int32 id = 1;
  string customer_name = 2;
  google.protobuf.Timestamp created_at = 3;
  repeated OrderItemMessage items = 4;
}

message OrderItemMessage {
  int32 product_id = 1;
  int32 quantity = 2;
  double unit_price = 3;
}
```

- **必須**指定 `csharp_namespace`，避免產生的 C# 程式碼落入預設命名空間。
- **必須**指定 `package`，含版本號（如 `myapp.v1`）。
- 欄位命名使用 snake_case（Protobuf 慣例，Code Generator 會轉為 PascalCase）。
- Request / Response 訊息以 RPC 方法名稱為前綴，避免命名衝突。

### 版本管理

- API 變更時，新增欄位不破壞相容性（proto3 預設行為）。
- 移除或變更欄位語意時，使用 `reserved` 保留舊欄位號。
- 重大變更建立新的 package 版本（如 `myapp.v2`）。

## 專案設定

```xml
<ItemGroup>
  <Protobuf Include="Protos\*.proto" GrpcServices="Server" />
</ItemGroup>
```

| 屬性值 | 用途 |
| --- | --- |
| `Server` | 僅產生伺服器端基底類別 |
| `Client` | 僅產生用戶端 Stub |
| `Both` | 同時產生（同專案需要測試或自呼叫時） |

## 服務實作

```csharp
public class OrderGrpcService(
    IOrderService orderService,
    ILogger<OrderGrpcService> logger
) : OrderService.OrderServiceBase {
    public override async Task<GetOrderResponse> GetOrder(
        GetOrderRequest request,
        ServerCallContext context
    ) {
        Order? order = await orderService
            .FindByIdAsync(request.Id, context.CancellationToken)
            .ConfigureAwait(false);

        if (order is null) {
            throw new RpcException(new Status(StatusCode.NotFound, $"訂單 {request.Id} 不存在"));
        }

        return new GetOrderResponse {
            Id = order.Id,
            CustomerName = order.CustomerName,
            CreatedAt = Timestamp.FromDateTime(order.CreatedAt.ToUniversalTime())
        };
    }

    public override async Task<ListOrdersResponse> ListOrders(
        ListOrdersRequest request,
        ServerCallContext context
    ) {
        IReadOnlyList<Order> orders = await orderService
            .GetAllAsync(context.CancellationToken)
            .ConfigureAwait(false);

        ListOrdersResponse response = new();
        response.Orders.AddRange(orders.Select(o => new GetOrderResponse {
            Id = o.Id,
            CustomerName = o.CustomerName
        }));

        return response;
    }
}
```

- 服務類別命名以 `GrpcService` 結尾，與 Domain Service 區分。
- **必須**使用 `ServerCallContext.CancellationToken` 傳入所有非同步操作。

## 錯誤處理（Crucial）

### Status Code 對應

| gRPC StatusCode | HTTP 對應 | 適用情境 |
| --- | --- | --- |
| `OK` | 200 | 成功 |
| `InvalidArgument` | 400 | 參數格式錯誤 |
| `NotFound` | 404 | 資源不存在 |
| `AlreadyExists` | 409 | 資源已存在 |
| `PermissionDenied` | 403 | 無權限 |
| `Unauthenticated` | 401 | 未認證 |
| `FailedPrecondition` | 400 | 前置條件不滿足 |
| `Internal` | 500 | 伺服器內部錯誤 |
| `Unavailable` | 503 | 服務暫時不可用 |

### 拋出錯誤

```csharp
// ✅ 正確：使用 RpcException 搭配明確的 StatusCode
throw new RpcException(new Status(StatusCode.InvalidArgument, "客戶名稱不可為空"));

// ❌ 錯誤：拋出一般例外（用戶端只會收到 StatusCode.Unknown）
throw new ArgumentException("客戶名稱不可為空");
```

### 全域錯誤攔截器

```csharp
public class ErrorInterceptor(ILogger<ErrorInterceptor> logger) : Interceptor {
    public override async Task<TResponse> UnaryServerHandler<TRequest, TResponse>(
        TRequest request,
        ServerCallContext context,
        UnaryServerMethod<TRequest, TResponse> continuation
    ) {
        try {
            return await continuation(request, context).ConfigureAwait(false);
        } catch (RpcException) {
            throw; // 已處理的 gRPC 錯誤直接傳播
        } catch (Exception ex) {
            logger.LogError(ex, "gRPC 方法 {Method} 發生未處理的例外", context.Method);
            throw new RpcException(new Status(StatusCode.Internal, "伺服器內部錯誤"));
        }
    }
}
```

## 攔截器（Interceptor）

```csharp
// 註冊
builder.Services.AddGrpc(options => {
    options.Interceptors.Add<ErrorInterceptor>();
    options.Interceptors.Add<LoggingInterceptor>();
});
```

- 攔截器依註冊順序執行（外到內），回應時反向（內到外）。
- 攔截器本身為 Transient，可透過建構函式注入服務。

## 用戶端工廠（gRPC Client Factory）

```csharp
// 註冊
builder.Services.AddGrpcClient<OrderService.OrderServiceClient>(options => {
    options.Address = new Uri("https://localhost:5001");
})
.ConfigureChannel(options => {
    options.MaxRetryAttempts = 3;
});

// 使用
public class OrderProxy(OrderService.OrderServiceClient client) {
    public async Task<GetOrderResponse> GetOrderAsync(int id, CancellationToken cancellationToken) {
        return await client.GetOrderAsync(
            new GetOrderRequest { Id = id },
            cancellationToken: cancellationToken
        ).ConfigureAwait(false);
    }
}
```

- **禁止**手動建立 `GrpcChannel`。使用 `AddGrpcClient` 搭配 HttpClientFactory，獲得連線管理與重試策略。

## 串流（Streaming）

### Server Streaming

```csharp
public override async Task StreamOrders(
    StreamOrdersRequest request,
    IServerStreamWriter<OrderMessage> responseStream,
    ServerCallContext context
) {
    await foreach (Order order in orderService
        .GetOrderStreamAsync(context.CancellationToken)
        .ConfigureAwait(false)
    ) {
        await responseStream.WriteAsync(new OrderMessage { Id = order.Id }, context.CancellationToken)
            .ConfigureAwait(false);
    }
}
```

### 串流注意事項

- Server Streaming 適合大量資料逐筆傳送（如匯出、即時推播）。
- Client Streaming 適合批次上傳（如檔案分片）。
- Bidirectional Streaming 適合即時互動（如聊天）。
- 串流中必須檢查 `context.CancellationToken`，用戶端中斷時及時停止。

## 註冊與端點映射

```csharp
// Program.cs
builder.Services.AddGrpc();

app.MapGrpcService<OrderGrpcService>();
app.MapGrpcService<ProductGrpcService>();
```

## 效能考量

- gRPC 使用 HTTP/2，需要 TLS。開發環境可透過 Kestrel 設定啟用不加密的 HTTP/2。
- `repeated` 欄位（集合）避免傳送過大的資料量，超過 4 MB 建議改用 Server Streaming 分批傳送。
- 預設訊息大小上限為 4 MB，可透過 `MaxReceiveMessageSize` / `MaxSendMessageSize` 調整。
