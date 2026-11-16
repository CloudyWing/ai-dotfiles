---
name: vue-router
description: 'Vue Router 4 開發規範：路由設計、Navigation Guard、動態載入、Meta 型別安全與權限控制。當撰寫或修改路由設定與 Navigation Guard 時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Vue Router 4 開發規範

## 路由設計原則

### 路由定義結構

```typescript
// router/index.ts
import { createRouter, createWebHistory } from 'vue-router';
import type { RouteRecordRaw } from 'vue-router';

const routes: ReadonlyArray<RouteRecordRaw> = [
  {
    path: '/',
    component: () => import('@/layouts/DefaultLayout.vue'),
    children: [
      {
        path: '',
        name: 'Home',
        component: () => import('@/views/HomeView.vue')
      },
      {
        path: 'orders',
        name: 'OrderList',
        component: () => import('@/views/orders/OrderListView.vue'),
        meta: { requiresAuth: true }
      },
      {
        path: 'orders/:id',
        name: 'OrderDetail',
        component: () => import('@/views/orders/OrderDetailView.vue'),
        meta: { requiresAuth: true },
        props: true
      }
    ]
  },
  {
    path: '/login',
    name: 'Login',
    component: () => import('@/views/LoginView.vue'),
    meta: { guestOnly: true }
  },
  {
    path: '/:pathMatch(.*)*',
    name: 'NotFound',
    component: () => import('@/views/NotFoundView.vue')
  }
];

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes
});

export default router;
```

### 命名規範

| 項目 | 規則 | 範例 |
| --- | --- | --- |
| Route name | PascalCase | `OrderDetail`, `UserProfile` |
| Path | kebab-case | `/order-items`, `/user-profile` |
| 參數 | camelCase | `:orderId`, `:userId` |
| View 檔名 | PascalCase + `View` 後綴 | `OrderDetailView.vue` |

### 巢狀路由與 Layout

- 使用巢狀路由搭配 Layout 元件，實現共用佈局（如 Header、Sidebar）。
- Layout 元件透過 `<RouterView />` 渲染子路由內容。
- 不同的佈局需求（如登入頁無 Sidebar）透過多個頂層路由群組處理，不在元件內做條件判斷。

## 動態載入（Lazy Loading）（Crucial）

### 所有頁面元件必須動態載入

```typescript
// ✅ 正確：動態 import
{
  path: '/orders',
  component: () => import('@/views/orders/OrderListView.vue')
}

// ❌ 錯誤：靜態 import（會全部打包進主 bundle）
import OrderListView from '@/views/orders/OrderListView.vue';
{
  path: '/orders',
  component: OrderListView
}
```

- 動態 import 搭配 Vite 自動實現 Code Splitting，每個路由產生獨立的 chunk。
- Layout 元件若體積小且所有路由都使用，可選擇靜態 import。

## Navigation Guard

### 全域 Guard

```typescript
// router/index.ts
router.beforeEach(async (to, from) => {
  const authStore = useAuthStore();

  // 需要認證的路由
  if (to.meta.requiresAuth && !authStore.isAuthenticated) {
    return {
      name: 'Login',
      query: { redirect: to.fullPath }
    };
  }

  // 僅限訪客（已登入不可進入）
  if (to.meta.guestOnly && authStore.isAuthenticated) {
    return { name: 'Home' };
  }
});
```

### 路由層級 Guard

```typescript
{
  path: '/admin',
  component: () => import('@/views/admin/AdminView.vue'),
  beforeEnter: (to, from) => {
    const authStore = useAuthStore();
    if (!authStore.hasRole('admin')) {
      return { name: 'Forbidden' };
    }
  }
}
```

### 元件內 Guard

```vue
<script setup lang="ts">
import { onBeforeRouteLeave } from 'vue-router';

const hasUnsavedChanges = ref(false);

onBeforeRouteLeave((to, from) => {
  if (hasUnsavedChanges.value) {
    const answer = window.confirm('尚有未儲存的變更，確定離開？');
    if (!answer) {
      return false;
    }
  }
});
</script>
```

### Guard 注意事項

- Guard 中使用 Pinia Store 時，必須在 Guard 函式**內部**呼叫 `useXxxStore()`（而非模組頂層），確保 Pinia 已初始化。

## Route Meta 型別安全

### 擴充 RouteMeta 型別

```typescript
// router/types.ts
export {};

declare module 'vue-router' {
  interface RouteMeta {
    requiresAuth?: boolean;
    guestOnly?: boolean;
    roles?: ReadonlyArray<string>;
    title?: string;
  }
}
```

- 將 Meta 型別定義放在獨立檔案中，並確保該檔案被 `tsconfig.json` 涵蓋。
- 定義後，`to.meta.requiresAuth` 等存取具備型別檢查。

## 程式化導航

- 程式化導航優先使用 `name`，避免硬編碼路徑。
- 路由參數使用 `params`，查詢條件使用 `query`。

## 頁面標題

```typescript
router.afterEach((to) => {
  const title = to.meta.title;
  document.title = title ? `${title} | MyApp` : 'MyApp';
});
```

## 路由模組化

大型專案可將路由定義拆分為多個模組：

```typescript
// router/modules/order.ts
import type { RouteRecordRaw } from 'vue-router';

export const orderRoutes: ReadonlyArray<RouteRecordRaw> = [
  {
    path: 'orders',
    name: 'OrderList',
    component: () => import('@/views/orders/OrderListView.vue'),
    meta: { requiresAuth: true, title: '訂單列表' }
  },
  {
    path: 'orders/:id',
    name: 'OrderDetail',
    component: () => import('@/views/orders/OrderDetailView.vue'),
    meta: { requiresAuth: true, title: '訂單明細' },
    props: true
  }
];

// router/index.ts
import { orderRoutes } from './modules/order';
import { customerRoutes } from './modules/customer';

const routes: ReadonlyArray<RouteRecordRaw> = [
  {
    path: '/',
    component: () => import('@/layouts/DefaultLayout.vue'),
    children: [
      ...orderRoutes,
      ...customerRoutes
    ]
  }
];
```
