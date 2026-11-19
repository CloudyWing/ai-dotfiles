---
name: csharp-grpc
description: 'gRPC 服務開發規範：Proto 檔案管理、服務實作、攔截器、錯誤處理與用戶端工廠模式。當偵測到 gRPC 專案或撰寫 .proto、gRPC 服務與用戶端時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# gRPC 服務開發規範

## Proto 檔案管理

### 目錄結構

- Proto 檔案集中於 `Protos/` 目錄。
- 服務實作放在 `Services/` 目錄（如 `OrderGrpcService.cs`）。
- 檔名使用 snake_case（`order_service.proto`），與 Protobuf 社群慣例一致。
- 每個 `.proto` 檔案對應一個邏輯上的服務 domain。

### Proto 檔案規範

- 使用 `syntax = "proto3"`；日期時間欄位使用 `google.protobuf.Timestamp`（需 `import "google/protobuf/timestamp.proto";`）。
- **必須**指定 `csharp_namespace`，避免產生的 C# 程式碼落入預設命名空間。
- **必須**指定 `package`，含版本號（如 `myapp.v1`）。
- 欄位命名使用 snake_case（Protobuf 慣例，Code Generator 會轉為 PascalCase）。
- Request / Response 訊息以 RPC 方法名稱為前綴，避免命名衝突。

### 版本管理

- API 變更時，新增欄位不破壞相容性（proto3 預設行為）。
- 移除或變更欄位語意時，使用 `reserved` 保留舊欄位號。
- 重大變更建立新的 package 版本（如 `myapp.v2`）。

## 服務實作

- 服務類別命名以 `GrpcService` 結尾，與 Domain Service 區分。
- **必須**使用 `ServerCallContext.CancellationToken` 傳入所有非同步操作。

## 錯誤處理

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

- 以 `RpcException` 搭配明確的 `StatusCode` 拋出錯誤。拋出一般例外時，用戶端只會收到 `StatusCode.Unknown`。

### 全域錯誤攔截器

- 以全域 Interceptor（如 `ErrorInterceptor`）覆寫 `UnaryServerHandler`：`RpcException` 直接傳播；其餘例外記錄後轉為 `StatusCode.Internal`，回應訊息不含內部細節。

## 攔截器（Interceptor）

- 於 `AddGrpc` 的 `options.Interceptors.Add<T>()` 註冊，錯誤攔截器最先註冊（位於最外層）。
- 攔截器依註冊順序執行（外到內），回應時反向（內到外）。
- 攔截器本身為 Transient，可透過建構函式注入服務。

## 用戶端工廠（gRPC Client Factory）

- 以 `AddGrpcClient<TClient>` 註冊並設定 `Address`，產生的 client 由建構函式注入，呼叫時傳入 `cancellationToken`。
- **禁止**手動建立 `GrpcChannel`。使用 `AddGrpcClient` 搭配 HttpClientFactory，獲得連線管理與重試策略。

## 串流（Streaming）

- 串流中必須檢查 `context.CancellationToken`，用戶端中斷時及時停止。

## 效能考量

- `repeated` 欄位（集合）避免傳送過大的資料量，超過 4 MB 建議改用 Server Streaming 分批傳送。
- 預設訊息大小上限為 4 MB，可透過 `MaxReceiveMessageSize` / `MaxSendMessageSize` 調整。
