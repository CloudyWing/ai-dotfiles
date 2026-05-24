---
name: pinia
description: 'Pinia 狀態管理規範：Store 設計、Setup Store 寫法、跨 Store 互動、持久化策略與元件整合。'
---

# Pinia 狀態管理規範

當偵測到專案使用 Pinia（含 `pinia` 相依套件）或使用者要求撰寫狀態管理邏輯時，請自動套用以下規範。

## Store 設計原則（Crucial）

### Setup Store 優先

**必須**使用 Setup Store（函式寫法），與 Composition API 風格一致，型別推斷更佳。

```typescript
// stores/order.ts
import { ref, computed } from 'vue';
import { defineStore } from 'pinia';
import type { Order } from '@/types/order';
import { orderApi } from '@/api/order';

export const useOrderStore = defineStore('order', () => {
  // State
  const orders = ref<Order[]>([]);
  const isLoading = ref(false);
  const error = ref<string | null>(null);

  // Getters
  const pendingOrders = computed(() =>
    orders.value.filter(o => o.status === 'pending')
  );
  const orderCount = computed(() => orders.value.length);

  // Actions
  async function fetchOrders() {
    isLoading.value = true;
    error.value = null;
    try {
      orders.value = await orderApi.getAll();
    } catch (e) {
      error.value = e instanceof Error ? e.message : '載入失敗';
      throw e;
    } finally {
      isLoading.value = false;
    }
  }

  async function createOrder(input: CreateOrderInput) {
    const newOrder = await orderApi.create(input);
    orders.value.push(newOrder);
    return newOrder;
  }

  function $reset() {
    orders.value = [];
    isLoading.value = false;
    error.value = null;
  }

  return {
    // State
    orders,
    isLoading,
    error,
    // Getters
    pendingOrders,
    orderCount,
    // Actions
    fetchOrders,
    createOrder,
    $reset
  };
});
```

### Options Store（僅限既有專案）

若專案既有 Store 皆為 Options 風格，新增 Store 可沿用。不在同一專案中混用。

```typescript
// ❌ 避免在新專案使用
export const useOrderStore = defineStore('order', {
  state: () => ({
    orders: [] as Order[]
  }),
  getters: {
    pendingOrders: (state) => state.orders.filter(o => o.status === 'pending')
  },
  actions: {
    async fetchOrders() { /* ... */ }
  }
});
```

## 命名慣例

| 項目 | 規則 | 範例 |
| --- | --- | --- |
| Store 函式 | `use` + Domain + `Store` | `useOrderStore`, `useAuthStore` |
| Store ID | 與 Domain 一致，camelCase | `'order'`, `'auth'` |
| Store 檔名 | Domain 名稱 | `order.ts`, `auth.ts` |

## Store 職責劃分

### 按 Domain 拆分

一個 Store 對應一個業務領域，不做萬用 Store。

```text
stores/
├── auth.ts        # 認證狀態（登入、登出、Token）
├── order.ts       # 訂單相關
├── customer.ts    # 客戶相關
├── ui.ts          # UI 狀態（Sidebar 開關、Theme）
└── index.ts       # 統一匯出（選用）
```

### Store 與 Composable 的界線

| 放 Store | 放 Composable |
| --- | --- |
| 跨元件共享的全域狀態 | 單一元件或少數元件的局部邏輯 |
| 認證狀態、購物車、通知 | 表單驗證、視窗尺寸偵測、分頁邏輯 |
| 需要持久化或 DevTools 檢視 | 不需要跨元件共享 |

## 跨 Store 互動

```typescript
// stores/order.ts
export const useOrderStore = defineStore('order', () => {
  async function createOrder(input: CreateOrderInput) {
    const newOrder = await orderApi.create(input);
    orders.value.push(newOrder);

    // ✅ 在 Action 內部使用其他 Store
    const notificationStore = useNotificationStore();
    notificationStore.showSuccess('訂單建立成功');

    return newOrder;
  }

  return { createOrder };
});
```

- 跨 Store 呼叫**必須**在 Action 函式內部取得 Store 實例，不在模組頂層。
- 避免循環依賴：A Store 的 Action 呼叫 B Store 的 Action，B 又呼叫 A。若有此需求，提取共用邏輯至獨立的 Service 或 Composable。

## 元件中使用 Store

### 基本用法

```vue
<script setup lang="ts">
import { useOrderStore } from '@/stores/order';
import { storeToRefs } from 'pinia';

const orderStore = useOrderStore();

// ✅ storeToRefs：解構 State 與 Getter，保持響應式
const { orders, pendingOrders, isLoading, error } = storeToRefs(orderStore);

// ✅ Action 直接解構（函式不需要響應式）
const { fetchOrders, createOrder } = orderStore;
</script>
```

### 解構注意事項（Crucial）

```typescript
// ❌ 錯誤：直接解構 State 會失去響應式
const { orders, isLoading } = orderStore; // orders 不再響應

// ✅ 正確：使用 storeToRefs
const { orders, isLoading } = storeToRefs(orderStore);

// ✅ 正確：不解構，直接用 store 存取
orderStore.orders;
orderStore.isLoading;
```

## $reset 實作

Setup Store 不像 Options Store 自帶 `$reset()`，必須手動實作。

```typescript
export const useOrderStore = defineStore('order', () => {
  const orders = ref<Order[]>([]);
  const currentPage = ref(1);

  // ✅ 手動實作 $reset
  function $reset() {
    orders.value = [];
    currentPage.value = 1;
  }

  return { orders, currentPage, $reset };
});
```

- 在登出或頁面切換時呼叫 `$reset()` 清除狀態，防止資料洩漏。

## 非同步 Action

```typescript
export const useOrderStore = defineStore('order', () => {
  const orders = ref<Order[]>([]);
  const isLoading = ref(false);
  const error = ref<string | null>(null);

  // ✅ 非同步 Action 模式
  async function fetchOrders() {
    isLoading.value = true;
    error.value = null;
    try {
      orders.value = await orderApi.getAll();
    } catch (e) {
      error.value = e instanceof Error ? e.message : '載入訂單失敗';
      throw e; // 重新拋出，讓元件決定是否顯示 Toast
    } finally {
      isLoading.value = false;
    }
  }

  return { orders, isLoading, error, fetchOrders };
});
```

- 每個非同步 Action 搭配 `isLoading` 和 `error` 狀態。
- 錯誤在 Store 中記錄，同時 `throw` 讓元件層可選擇性顯示通知。

## 持久化策略

### pinia-plugin-persistedstate

```typescript
// main.ts
import { createPinia } from 'pinia';
import piniaPluginPersistedstate from 'pinia-plugin-persistedstate';

const pinia = createPinia();
pinia.use(piniaPluginPersistedstate);
```

```typescript
// 需要持久化的 Store
export const useAuthStore = defineStore('auth', () => {
  const token = ref<string | null>(null);
  const user = ref<User | null>(null);

  return { token, user };
}, {
  persist: {
    pick: ['token'], // 僅持久化 Token，不持久化完整 User
    storage: localStorage
  }
});
```

### 持久化原則

- **僅持久化必要的最小資料**（如 Token、使用者偏好），不持久化完整的業務資料。
- 敏感資料（如完整使用者資訊）不放 `localStorage`。
- Token 使用 `localStorage`（跨分頁持久）；UI 偏好可用 `sessionStorage`。

## 測試

```typescript
import { setActivePinia, createPinia } from 'pinia';
import { useOrderStore } from '@/stores/order';

describe('useOrderStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
  });

  it('fetchOrders should populate orders', async () => {
    const store = useOrderStore();
    // Mock API...
    await store.fetchOrders();
    expect(store.orders).toHaveLength(3);
  });
});
```

- 每個測試前呼叫 `setActivePinia(createPinia())` 建立全新的 Pinia 實例。
- Store 測試聚焦 Action 的業務邏輯，不測試 Pinia 框架本身的響應式行為。
