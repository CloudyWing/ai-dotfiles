---
name: openapi-client
description: '前後端 API 契約規範：OpenAPI Client 產生策略、Axios 封裝、型別同步與錯誤處理。當撰寫前端 API 呼叫層或同步前後端型別時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# 前後端 API 契約規範

## API 契約策略

### Code Generation 優先

前端的 API Client 與型別定義應盡可能從後端的 OpenAPI（Swagger）規格檔自動產生，而非手動撰寫。

### 手動撰寫的適用情境

- 後端尚未產出 OpenAPI spec。
- API 來源為第三方，無法取得 spec。
- 專案規模小，API 數量少於 10 個。

## Axios 封裝

### 建立共用實例

- 共用實例定義於 `lib/axios.ts` 並以 default export 匯出。`baseURL` 取 `import.meta.env.VITE_API_BASE_URL`，未設定時為 `/api`。
- 明確設定 `timeout`（如 30 秒；Axios 預設不逾時），預設標頭 `Content-Type` 為 `application/json`。
- Request Interceptor 在有 Token 時注入 `Authorization: Bearer <token>`；Response Interceptor 在 401 時以 `window.location.href = '/login'` 整頁導向登入頁，不在 `lib/axios.ts` 匯入 Router。Router 的 Guard 會使用 Store，Store 又呼叫 `apiClient`，匯入 Router 會形成循環相依。兩者的錯誤處理都以 `Promise.reject(error)` 把錯誤交還呼叫端，不吞掉錯誤。

### Axios 規範

- **禁止**在元件或 Store 中直接 `import axios from 'axios'`。統一透過封裝的 `apiClient` 存取。
- **禁止**在每次請求中重新建立 Axios 實例。
- Interceptor 聚焦橫切關注點（Token 注入、全域錯誤處理），不含業務邏輯。

## API 模組設計

### API 模組原則

- 一個 Domain 一個檔案（`order.ts`、`customer.ts`）。
- 模組匯出單一物件 `<domain>Api`（如 `orderApi`），方法命名為 `getAll`、`getById`、`create`、`update`、`delete`。`getAll` 的查詢條件以 `params` 傳遞並回傳 `PaginatedResponse<T>`，`delete` 回傳 `void`。
- 每個方法都有明確的輸入與回傳型別。
- 方法內部解包 `response.data`，呼叫端不需要處理 Axios 的 Response 結構。
- **禁止**在 API 模組中直接操作 Store 或 Router（保持純粹的資料存取層）。

## 通用型別定義

```typescript
// types/api.ts

/** 分頁回應 */
interface PaginatedResponse<T> {
  data: ReadonlyArray<T>;
  total: number;
  page: number;
  pageSize: number;
  totalPages: number;
}

/** ProblemDetails（RFC 9457）對應 */
interface ProblemDetails {
  type?: string;
  title: string;
  status: number;
  detail?: string;
  instance?: string;
  errors?: Record<string, string[]>;
}
```

- 這些型別直接對應後端的回應格式。若後端修改回應結構，此處同步更新。
- 單一資源的回應不包 wrapper，成功時直接回傳資源；分頁清單使用 `PaginatedResponse<T>`；錯誤回應為 ProblemDetails。

## 錯誤處理

### API 錯誤型別

錯誤判讀集中於 `lib/apiError.ts`，提供下列函式：

- `isApiError(error)`：Type Guard。`axios.isAxiosError(error)` 成立，且回應內容含 ProblemDetails 的 `title`。
- `getErrorMessage(error)`：依序取 ProblemDetails 的 `detail`、`title`，再取 `Error.message`，皆無時回傳通用訊息。
- `getValidationErrors(error)`：回應狀態為 400（ASP.NET Core 驗證失敗的預設狀態碼）且含 `errors` 時回傳 `Record<string, string[]>`，否則回傳空物件。

元件 `catch` 後先取 `getValidationErrors` 的結果顯示於表單欄位；沒有欄位錯誤時，以通知顯示 `getErrorMessage` 的訊息。

## 取消請求

### AbortController

- 路由切換或元件卸載時，取消進行中的 API 請求。
- 搜尋輸入等連續觸發的場景，新請求前取消舊請求。

## 型別同步策略

### 自動產生（推薦）

- 以 `npx openapi-typescript <swagger.json 位址> -o src/types/generated/api.d.ts` 從後端 Swagger endpoint 產生型別，並將指令加入 `package.json` 的 scripts（如 `api:types`）。
- 產生的型別檔案納入版控，確保 CI 環境不需要啟動後端服務。
- 手動撰寫的型別不混入產生的檔案中。

### 手動維護

若採用手動維護型別，遵循以下原則：

- 前端型別命名與後端 DTO **完全對應**（如後端 `OrderDto` → 前端 `Order`，去掉 Dto 後綴）。
- API 回應有新增欄位時，前端型別同步更新。
- 使用 `interface` 定義 API 回應型別，方便擴展。

## 檔案上傳

- 提供上傳進度回報（`onUploadProgress`）給 UI 層。
