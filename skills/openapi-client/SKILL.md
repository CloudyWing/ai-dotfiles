---
name: openapi-client
description: '前後端 API 契約規範：OpenAPI Client 產生策略、Axios 封裝、型別同步與錯誤處理。當撰寫前端 API 呼叫層或同步前後端型別時自動套用。'
---

# 前後端 API 契約規範

當撰寫或審查前端 API 呼叫層，或處理前後端型別同步時，請自動套用以下規範。

## API 契約策略（Crucial）

### Code Generation 優先

前端的 API Client 與型別定義應盡可能從後端的 OpenAPI（Swagger）規格檔自動產生，而非手動撰寫。

**推薦工具鏈：**

| 工具 | 用途 |
| --- | --- |
| `openapi-typescript` | 從 OpenAPI spec 產生 TypeScript 型別定義 |
| `openapi-fetch` | 搭配 `openapi-typescript` 的型別安全 Fetch Client |
| NSwag | 從 ASP.NET Core 產生 TypeScript Client（含型別與方法） |

### 手動撰寫的適用情境

- 後端尚未產出 OpenAPI spec。
- API 來源為第三方，無法取得 spec。
- 專案規模小，API 數量少於 10 個。

## Axios 封裝

### 建立共用實例

```typescript
// lib/axios.ts
import axios from 'axios';
import type { AxiosInstance, InternalAxiosRequestConfig, AxiosResponse, AxiosError } from 'axios';

const apiClient: AxiosInstance = axios.create({
  baseURL: import.meta.env.VITE_API_BASE_URL || '/api',
  timeout: 30000,
  headers: {
    'Content-Type': 'application/json'
  }
});

// Request Interceptor
apiClient.interceptors.request.use(
  (config: InternalAxiosRequestConfig) => {
    const token = localStorage.getItem('token');
    if (token) {
      config.headers.Authorization = `Bearer ${token}`;
    }
    return config;
  },
  (error: AxiosError) => Promise.reject(error)
);

// Response Interceptor
apiClient.interceptors.response.use(
  (response: AxiosResponse) => response,
  (error: AxiosError) => {
    if (error.response?.status === 401) {
      // Token 過期，導向登入頁
      window.location.href = '/login';
    }
    return Promise.reject(error);
  }
);

export default apiClient;
```

### Axios 規範

- **禁止**在元件或 Store 中直接 `import axios from 'axios'`。統一透過封裝的 `apiClient` 存取。
- **禁止**在每次請求中重新建立 Axios 實例。
- Interceptor 聚焦橫切關注點（Token 注入、全域錯誤處理），不含業務邏輯。

## API 模組設計

### 按 Domain 組織

```typescript
// api/order.ts
import apiClient from '@/lib/axios';
import type { Order, CreateOrderInput, UpdateOrderInput } from '@/types/order';
import type { PaginatedResponse } from '@/types/api';

export const orderApi = {
  async getAll(params?: { status?: string; page?: number }): Promise<PaginatedResponse<Order>> {
    const response = await apiClient.get<PaginatedResponse<Order>>('/orders', { params });
    return response.data;
  },

  async getById(id: number): Promise<Order> {
    const response = await apiClient.get<Order>(`/orders/${id}`);
    return response.data;
  },

  async create(input: CreateOrderInput): Promise<Order> {
    const response = await apiClient.post<Order>('/orders', input);
    return response.data;
  },

  async update(id: number, input: UpdateOrderInput): Promise<Order> {
    const response = await apiClient.put<Order>(`/orders/${id}`, input);
    return response.data;
  },

  async delete(id: number): Promise<void> {
    await apiClient.delete(`/orders/${id}`);
  }
};
```

### API 模組原則

- 一個 Domain 一個檔案（`order.ts`、`customer.ts`）。
- 每個方法都有明確的輸入與回傳型別。
- 方法內部解包 `response.data`，呼叫端不需要處理 Axios 的 Response 結構。
- **禁止**在 API 模組中直接操作 Store 或 Router（保持純粹的資料存取層）。

## 通用型別定義

```typescript
// types/api.ts

/** API 標準回應包裝 */
interface ApiResponse<T> {
  data: T;
  message: string;
}

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

## 錯誤處理（Crucial）

### API 錯誤型別

```typescript
// lib/apiError.ts
import type { AxiosError } from 'axios';
import type { ProblemDetails } from '@/types/api';

export function isApiError(error: unknown): error is AxiosError<ProblemDetails> {
  return axios.isAxiosError(error) && error.response?.data?.title !== undefined;
}

export function getErrorMessage(error: unknown): string {
  if (isApiError(error)) {
    return error.response!.data.detail ?? error.response!.data.title;
  }
  if (error instanceof Error) {
    return error.message;
  }
  return '發生未預期的錯誤';
}

export function getValidationErrors(error: unknown): Record<string, string[]> {
  if (isApiError(error) && error.response?.status === 422) {
    return error.response.data.errors ?? {};
  }
  return {};
}
```

### 元件中的錯誤處理

```vue
<script setup lang="ts">
import { getErrorMessage, getValidationErrors } from '@/lib/apiError';

async function handleSubmit() {
  try {
    await orderStore.createOrder(formData.value);
    router.push({ name: 'OrderList' });
  } catch (error) {
    const validationErrors = getValidationErrors(error);
    if (Object.keys(validationErrors).length > 0) {
      fieldErrors.value = validationErrors;
    } else {
      toast.error(getErrorMessage(error));
    }
  }
}
</script>
```

## 取消請求

### AbortController

```typescript
// Composable 中管理請求取消
export function useOrderDetail(id: Ref<number>) {
  const order = ref<Order | null>(null);
  let abortController: AbortController | null = null;

  async function fetchDetail() {
    // 取消前一次請求
    abortController?.abort();
    abortController = new AbortController();

    try {
      const response = await apiClient.get<Order>(`/orders/${id.value}`, {
        signal: abortController.signal
      });
      order.value = response.data;
    } catch (error) {
      if (!axios.isCancel(error)) {
        throw error;
      }
    }
  }

  watch(id, fetchDetail, { immediate: true });

  onUnmounted(() => {
    abortController?.abort();
  });

  return { order };
}
```

- 路由切換或元件卸載時，取消進行中的 API 請求。
- 搜尋輸入等連續觸發的場景，新請求前取消舊請求。

## 型別同步策略

### 自動產生（推薦）

```bash
# 從後端 Swagger endpoint 產生型別
npx openapi-typescript https://localhost:5001/swagger/v1/swagger.json -o src/types/generated/api.d.ts
```

- 將型別產生指令加入 `package.json` 的 scripts：`"api:types": "openapi-typescript ..."`。
- 產生的型別檔案納入版控，確保 CI 環境不需要啟動後端服務。
- 手動撰寫的型別不混入產生的檔案中。

### 手動維護

若採用手動維護型別，遵循以下原則：

- 前端型別命名與後端 DTO **完全對應**（如後端 `OrderDto` → 前端 `Order`，去掉 Dto 後綴）。
- API 回應有新增欄位時，前端型別同步更新。
- 使用 `interface` 定義 API 回應型別，方便擴展。

## 檔案上傳

```typescript
async function uploadFile(file: File): Promise<UploadResult> {
  const formData = new FormData();
  formData.append('file', file);

  const response = await apiClient.post<UploadResult>('/files/upload', formData, {
    headers: { 'Content-Type': 'multipart/form-data' },
    onUploadProgress: (progressEvent) => {
      const percent = Math.round(
        (progressEvent.loaded * 100) / (progressEvent.total ?? 1)
      );
      uploadProgress.value = percent;
    }
  });

  return response.data;
}
```

- 檔案上傳使用 `FormData`，設定 `Content-Type: multipart/form-data`。
- 提供上傳進度回報（`onUploadProgress`）給 UI 層。
