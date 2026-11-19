---
name: vue-router
description: 'Vue Router 4 開發規範：路由設計、Navigation Guard、動態載入、Meta 型別安全與權限控制。當撰寫或修改路由設定與 Navigation Guard 時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Vue Router 4 開發規範

## 路由設計原則

### 路由定義結構

- 路由定義於 `router/index.ts`，路由陣列的型別標註為 `ReadonlyArray<RouteRecordRaw>`。
- History 使用 `createWebHistory(import.meta.env.BASE_URL)`。
- 帶參數的路由設定 `props: true`，由元件以 Props 接收參數。
- 共用同一個 Layout 的頁面放在以該 Layout 為 `component` 的頂層路由 `children` 內，子路由的 `path` 不加開頭的 `/`；不使用該 Layout 的頁面（如 `Login`、`NotFound`）為與它並列的頂層路由。
- 路由陣列最後定義 catch-all 路由 `/:pathMatch(.*)*`（`NotFound`）。

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

## 動態載入（Lazy Loading）

### 所有頁面元件必須動態載入

- 頁面元件一律以 `component: () => import('...')` 動態載入，不使用靜態 import（會全部打包進主 bundle）。
- 動態 import 搭配 Vite 自動實現 Code Splitting，每個路由產生獨立的 chunk。
- Layout 元件若體積小且所有路由都使用，可選擇靜態 import。

## Navigation Guard

- 依範圍選用 Guard：全域 `beforeEach` 處理認證，路由層級 `beforeEnter` 處理角色檢查（不具角色時導向 `Forbidden`），元件內 `onBeforeRouteLeave` 處理未儲存變更的離開確認（使用者取消時回傳 `false`）。
- 全域 `beforeEach`：`meta.requiresAuth` 且未登入時導向 `Login`，並以 `query.redirect` 帶上 `to.fullPath`；`meta.guestOnly` 且已登入時導向 `Home`。
- Guard 優先以回傳值控制導航（回傳路由位置，或回傳 `false` 取消導航）。
- Guard 中使用 Pinia Store 時，必須在 Guard 函式**內部**呼叫 `useXxxStore()`（而非模組頂層），確保 Pinia 已初始化。

## Route Meta 型別安全

### 擴充 RouteMeta 型別

- 以 `declare module 'vue-router'` 擴充 `RouteMeta`，欄位為 `requiresAuth`、`guestOnly`、`roles`（`ReadonlyArray<string>`）與 `title`，皆為選填。型別擴充檔為 `router/types.ts`，檔內需有 `export {}` 使其成為模組。
- 將 Meta 型別定義放在獨立檔案中，並確保該檔案被 `tsconfig.json` 涵蓋。
- 定義後，`to.meta.requiresAuth` 等存取具備型別檢查。

## 程式化導航

- 程式化導航優先使用 `name`，避免硬編碼路徑。
- 路由參數使用 `params`，查詢條件使用 `query`。

## 頁面標題

- 在 `router.afterEach` 依 `to.meta.title` 設定 `document.title`，格式為 `<title> | <應用程式名稱>`；沒有 `title` 時只顯示應用程式名稱。

## 路由模組化

大型專案可將路由定義拆到 `router/modules/<domain>.ts`，各模組匯出 `ReadonlyArray<RouteRecordRaw>`，由 `router/index.ts` 展開到對應 Layout 路由的 `children`。
