---
name: vue3
description: 'Vue 3 開發規範：Composition API、<script setup>、Composable 設計、元件結構與 Vite 建置設定。當偵測到 Vue 3 專案時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Vue 3 開發規範

## Composition API（Crucial）

### `<script setup>` 優先

所有新建的 Single File Component（SFC）**必須**使用 `<script setup>` 語法。禁止在新檔案中使用 Options API 或非 `<script setup>` 的 Composition API。

- 遵循**專案既有慣例**：若整個專案仍在使用 Options API，新檔案可沿用，但不在同一元件中混用。

### defineProps & defineEmits

- **必須**使用 TypeScript 型別宣告（Type-based）而非 Runtime 宣告，`<script setup>` 加上 `lang="ts"`。
- `defineEmits` 以具名 tuple 宣告事件參數（如 `update: [order: Order]`）；陣列型別的 Props 使用 `ReadonlyArray<T>`。
- Props 預設值使用 `withDefaults`。

### defineModel（Vue 3.4+）

雙向繫結使用 `defineModel` 取代手動的 `props` + `emit` 組合。

## 元件設計原則

### 命名慣例

| 類型 | 命名規則 | 範例 |
| --- | --- | --- |
| 元件檔名 | PascalCase | `OrderDetail.vue` |
| Template 中的元件 | PascalCase | `<OrderDetail />` |
| Composable 函式 | `use` 前綴 + camelCase | `useOrderList`, `useAuth` |
| Composable 檔名 | camelCase | `useOrderList.ts` |
| 事件名稱 | camelCase | `@updateOrder`, `@deleteItem` |

### 元件職責

- **單一職責**：一個元件只負責一個 UI 區塊或一種互動行為。
- **分層設計**：
  - **Page 元件**（`views/`）：組合多個 Feature 元件，處理路由層級的資料取得。
  - **Feature 元件**（`components/features/`）：包含業務邏輯的功能區塊。
  - **UI 元件**（`components/ui/`）：無業務邏輯的純 UI 元件，透過 Props 與 Emit 通訊。

### SFC 區塊排序

- 區塊順序固定為 `script` → `template` → `style`。
- `<style>` **必須**加上 `scoped`，除非有明確需要全域樣式的理由。
- `<script setup>` 內依序排列 imports、props 與 emits、composables、響應式狀態、computed、watchers、methods、lifecycle hooks。

## Composable 設計

### Composable 原則

- 命名以 `use` 開頭。
- 回傳值使用具名物件（非陣列），方便解構時重新命名。
- 回傳的響應式狀態使用 `computed()` 包裝，防止外部直接修改內部 `ref`。
- 可接受 `ref` 或純值作為參數（使用 `toValue()` 統一處理）。
- 一個 Composable 聚焦一個關注點，不做成萬用工具。

## 響應式系統

### ref vs reactive

- **預設使用 `ref`**：適用於所有情境，語意統一。
- `reactive` 僅在物件結構固定且不需要重新賦值時考慮使用。
- **禁止** `reactive` 整體重新賦值（會斷開響應式追蹤）。

### computed vs watch

| 用途 | 選擇 |
| --- | --- |
| 從現有狀態衍生新值 | `computed` |
| 狀態變更時執行副作用（API 呼叫、DOM 操作） | `watch` / `watchEffect` |

- **禁止**在 `computed` 中執行副作用。
- `watchEffect` 適合自動追蹤依賴的場景；`watch` 適合需要存取新舊值或控制執行時機的場景。

## Template 規範

### v-for 必須搭配 key

- `key` 使用唯一且穩定的值（如 `order.id`）。
- 不使用 index 作為 `key`，元素新增或刪除時會錯亂。

### v-if vs v-show

- `v-if`：條件不常變動，或需要延遲渲染（如 Tab 內容）。
- `v-show`：頻繁切換顯示/隱藏（如 Toggle）。
- **禁止** `v-if` 與 `v-for` 並用在同一元素上（`v-if` 優先級較高，Vue 3 中會報警告）。

### 屬性排序

順序：指令（`v-if`、`v-for`）→ 繫結（`v-model`、`:prop`）→ 靜態屬性 → 事件（`@event`）。

## Vite 建置設定

### 基本設定

- 開發伺服器以 `server.proxy` 將 `/api` 轉發到後端（`changeOrigin: true`；後端使用自簽憑證時 `secure: false`）。

### 路徑別名

- 使用 `@` 對應 `src/` 目錄。
- `tsconfig.json` 中的 `paths` 必須與 Vite 的 `resolve.alias` 保持同步。

### 環境變數

- 前綴規則：只有 `VITE_` 前綴的變數會暴露給前端程式碼。
- **禁止**將機密資訊放入前端環境變數（前端程式碼會被打包至 bundle 中，對使用者可見）。

### Build 最佳化

- 第三方套件以 `build.rollupOptions.output.manualChunks` 拆為獨立 chunk（`vendor`，如 `vue`、`vue-router`、`pinia`），利用瀏覽器快取。

## 目錄結構

```text
src/
├── api/              # API 呼叫層
├── assets/           # 靜態資源（圖片、字型）
├── components/
│   ├── ui/           # 通用 UI 元件
│   └── features/     # 業務功能元件
├── composables/      # Composable 函式
├── layouts/          # 佈局元件
├── router/           # Vue Router 設定
├── stores/           # Pinia Store
├── types/            # TypeScript 型別定義
├── utils/            # 工具函式
├── views/            # 頁面元件（對應路由）
├── App.vue
└── main.ts
```

- 遵循**專案既有慣例**。若專案已有不同的目錄結構，不主動重組。
