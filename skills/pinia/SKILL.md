---
name: pinia
description: 'Pinia 狀態管理規範：Store 設計、Setup Store 寫法、跨 Store 互動、持久化策略與元件整合。當撰寫或修改 Pinia Store 及其元件整合時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Pinia 狀態管理規範

## Store 設計原則

### Setup Store 優先

**必須**使用 Setup Store（函式寫法），與 Composition API 風格一致，型別推斷更佳。

- Store 內依 State（`ref`）、Getters（`computed`）、Actions（函式）的順序撰寫，`return` 的物件依相同順序列出。

### Options Store（僅限既有專案）

若專案既有 Store 皆為 Options 風格，新增 Store 可沿用。不在同一專案中混用。

## 命名慣例

| 項目 | 規則 | 範例 |
| --- | --- | --- |
| Store 函式 | `use` + Domain + `Store` | `useOrderStore`, `useAuthStore` |
| Store ID | 與 Domain 一致，camelCase | `'order'`, `'auth'` |
| Store 檔名 | Domain 名稱 | `order.ts`, `auth.ts` |

## Store 職責劃分

### 按 Domain 拆分

一個 Store 對應一個業務領域，不做萬用 Store。

UI 狀態（Sidebar 開關、Theme）獨立為 `ui.ts`；以 `index.ts` 統一匯出為選用。

### Store 與 Composable 的界線

| 放 Store | 放 Composable |
| --- | --- |
| 跨元件共享的全域狀態 | 單一元件或少數元件的局部邏輯 |
| 認證狀態、購物車、通知 | 表單驗證、視窗尺寸偵測、分頁邏輯 |
| 需要持久化或 DevTools 檢視 | 不需要跨元件共享 |

## 跨 Store 互動

- 跨 Store 呼叫**必須**在 Action 函式內部取得 Store 實例，不在模組頂層。
- 避免循環依賴：A Store 的 Action 呼叫 B Store 的 Action，B 又呼叫 A。若有此需求，提取共用邏輯至獨立的 Service 或 Composable。

## 元件中使用 Store

### 解構注意事項

- State 與 Getter 以 `storeToRefs(store)` 解構，或不解構、直接以 `store.xxx` 存取。直接解構會失去響應式。
- Action 直接從 store 解構（函式不需要響應式）。

## $reset 實作

Setup Store 不像 Options Store 自帶 `$reset()`，必須手動實作：把所有 State 設回初始值，並列入 `return`。

- 在登出或頁面切換時呼叫 `$reset()` 清除狀態，防止資料洩漏。

## 非同步 Action

- 每個非同步 Action 搭配 `isLoading` 和 `error` 狀態：開始時設 `isLoading` 並清除 `error`，在 `finally` 重設 `isLoading`。
- 錯誤在 Store 中記錄，同時 `throw` 讓元件層可選擇性顯示通知。

## 持久化策略

### pinia-plugin-persistedstate

- 於 `main.ts` 以 `pinia.use(piniaPluginPersistedstate)` 註冊；需要持久化的 Store 在 `defineStore` 第三個參數的 `persist` 以 `pick` 指定欄位、以 `storage` 指定儲存位置。

### 持久化原則

- **僅持久化必要的最小資料**（如 Token、使用者偏好），不持久化完整的業務資料。
- 敏感資料（如完整使用者資訊）不放 `localStorage`。
- Token 使用 `localStorage`（跨分頁持久）；UI 偏好可用 `sessionStorage`。

## 測試

- 每個測試前呼叫 `setActivePinia(createPinia())` 建立全新的 Pinia 實例。
- Store 測試聚焦 Action 的業務邏輯，不測試 Pinia 框架本身的響應式行為。
