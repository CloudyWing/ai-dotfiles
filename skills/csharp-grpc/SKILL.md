---
name: csharp-grpc
description: 'gRPC 服務開發規範：Proto 檔案的目錄與命名慣例、服務類別命名、全域錯誤攔截器與用戶端工廠模式。當偵測到 gRPC 專案或撰寫 .proto、gRPC 服務與用戶端時自動套用。'
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
- **必須**指定 `package`，含版本號（如 `myapp.v1`）。服務位址由 package 與服務名稱組成，帶版本號才能讓 `v1` 與 `v2` 並存，發佈破壞性變更時舊用戶端仍可呼叫 `v1`。
- 欄位命名使用 snake_case（Protobuf 慣例，Code Generator 會轉為 PascalCase）。
- Request / Response 訊息以 RPC 方法名稱為前綴，避免命名衝突。

## 服務實作

- 服務類別命名以 `GrpcService` 結尾，與 Domain Service 區分。

## 錯誤處理

- 以全域 Interceptor（如 `ErrorInterceptor`）覆寫 `UnaryServerHandler`：`RpcException` 直接傳播；其餘例外記錄後轉為 `StatusCode.Internal`，回應訊息不含內部細節。
- 攔截器於 `AddGrpc` 的 `options.Interceptors.Add<T>()` 註冊，錯誤攔截器最先註冊（位於最外層）。

## 用戶端工廠（gRPC Client Factory）

- 以 `AddGrpcClient<TClient>` 註冊並設定 `Address`，產生的 client 由建構函式注入，呼叫時傳入 `cancellationToken`。
- **禁止**手動建立 `GrpcChannel`。使用 `AddGrpcClient` 搭配 HttpClientFactory，獲得連線管理與重試策略。
