---
name: vue3
description: 'Vue 3 開發規範：Composition API、<script setup>、Composable 設計、元件結構與 Vite 建置設定。當偵測到 Vue 3 專案時自動套用。'
---

# Vue 3 開發規範

當偵測到 Vue 3 專案（含 `vue` 3.x 相依套件）或使用者要求撰寫 Vue 元件時，請自動套用以下規範。

## Composition API（Crucial）

### `<script setup>` 優先

所有新建的 Single File Component（SFC）**必須**使用 `<script setup>` 語法。禁止在新檔案中使用 Options API 或非 `<script setup>` 的 Composition API。

```vue
<!-- ✅ 正確 -->
<script setup lang="ts">
import { ref, computed } from 'vue';
import type { Order } from '@/types/order';

const props = defineProps<{
  orderId: number;
}>();

const emit = defineEmits<{
  update: [order: Order];
  delete: [id: number];
}>();

const count = ref(0);
const doubled = computed(() => count.value * 2);
</script>

<!-- ❌ 錯誤：Options API -->
<script lang="ts">
export default {
  data() {
    return { count: 0 };
  }
};
</script>
```

- 遵循**專案既有慣例**：若整個專案仍在使用 Options API，新檔案可沿用，但不在同一元件中混用。

### defineProps & defineEmits

- **必須**使用 TypeScript 型別宣告（Type-based）而非 Runtime 宣告。
- Props 預設值使用 `withDefaults`。

```typescript
// ✅ 正確：Type-based
const props = defineProps<{
  title: string;
  count?: number;
  items: ReadonlyArray<Item>;
}>();

// ✅ 帶預設值
const props = withDefaults(defineProps<{
  title: string;
  count?: number;
}>(), {
  count: 0
});

// ❌ 錯誤：Runtime 宣告
const props = defineProps({
  title: { type: String, required: true },
  count: { type: Number, default: 0 }
});
```

### defineModel（Vue 3.4+）

雙向繫結使用 `defineModel` 取代手動的 `props` + `emit` 組合。

```vue
<script setup lang="ts">
// ✅ 簡潔的 v-model 支援
const modelValue = defineModel<string>({ required: true });
const title = defineModel<string>('title');
</script>
```

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

```vue
<script setup lang="ts">
// 1. imports
// 2. props & emits
// 3. composables
// 4. reactive state
// 5. computed
// 6. watchers
// 7. methods
// 8. lifecycle hooks
</script>

<template>
  <!-- HTML -->
</template>

<style scoped>
/* CSS */
</style>
```

- 區塊順序固定為 `script` → `template` → `style`。
- `<style>` **必須**加上 `scoped`，除非有明確需要全域樣式的理由。

## Composable 設計

### 基本結構

```typescript
// composables/useOrderList.ts
import { ref, computed, onMounted } from 'vue';
import type { Order } from '@/types/order';
import { orderApi } from '@/api/order';

export function useOrderList() {
  const orders = ref<Order[]>([]);
  const isLoading = ref(false);
  const error = ref<string | null>(null);

  const pendingOrders = computed(() =>
    orders.value.filter(o => o.status === 'pending')
  );

  async function fetchOrders() {
    isLoading.value = true;
    error.value = null;
    try {
      orders.value = await orderApi.getAll();
    } catch (e) {
      error.value = e instanceof Error ? e.message : '載入失敗';
    } finally {
      isLoading.value = false;
    }
  }

  onMounted(fetchOrders);

  return {
    orders: computed(() => orders.value),
    pendingOrders,
    isLoading: computed(() => isLoading.value),
    error: computed(() => error.value),
    fetchOrders
  };
}
```

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

```typescript
// ✅ 預設用 ref
const count = ref(0);
const user = ref<User | null>(null);
const items = ref<Item[]>([]);

// ❌ 錯誤：reactive 整體重新賦值
const state = reactive({ items: [] as Item[] });
state = reactive({ items: newItems }); // 斷開響應式

// ✅ 若用 reactive，修改屬性
state.items = newItems;
```

### computed vs watch

| 用途 | 選擇 |
| --- | --- |
| 從現有狀態衍生新值 | `computed` |
| 狀態變更時執行副作用（API 呼叫、DOM 操作） | `watch` / `watchEffect` |

- **禁止**在 `computed` 中執行副作用。
- `watchEffect` 適合自動追蹤依賴的場景；`watch` 適合需要存取新舊值或控制執行時機的場景。

```typescript
// ✅ computed：衍生值
const fullName = computed(() => `${firstName.value} ${lastName.value}`);

// ✅ watch：副作用
watch(selectedId, async (newId) => {
  if (newId) {
    detail.value = await fetchDetail(newId);
  }
});

// ✅ watchEffect：自動追蹤依賴
watchEffect(() => {
  console.log(`目前選取：${selectedId.value}`);
});
```

## Template 規範

### v-for 必須搭配 key

```vue
<!-- ✅ 正確：唯一且穩定的 key -->
<li v-for="order in orders" :key="order.id">{{ order.name }}</li>

<!-- ❌ 錯誤：使用 index 作為 key（元素新增/刪除時會錯亂） -->
<li v-for="(order, index) in orders" :key="index">{{ order.name }}</li>
```

### v-if vs v-show

- `v-if`：條件不常變動，或需要延遲渲染（如 Tab 內容）。
- `v-show`：頻繁切換顯示/隱藏（如 Toggle）。
- **禁止** `v-if` 與 `v-for` 並用在同一元素上（`v-if` 優先級較高，Vue 3 中會報警告）。

### 屬性排序

```vue
<MyComponent
  v-if="isVisible"
  v-model="value"
  :title="title"
  :items="items"
  class="my-class"
  @click="handleClick"
  @update="handleUpdate"
/>
```

順序：指令（`v-if`、`v-for`）→ 繫結（`v-model`、`:prop`）→ 靜態屬性 → 事件（`@event`）。

## Vite 建置設定

### 基本設定

```typescript
// vite.config.ts
import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';
import { fileURLToPath, URL } from 'node:url';

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url))
    }
  },
  server: {
    proxy: {
      '/api': {
        target: 'https://localhost:5001',
        changeOrigin: true,
        secure: false
      }
    }
  }
});
```

### 路徑別名

- 使用 `@` 對應 `src/` 目錄。
- `tsconfig.json` 中的 `paths` 必須與 Vite 的 `resolve.alias` 保持同步。

### 環境變數

- 環境變數檔案：`.env`（所有環境）、`.env.development`、`.env.production`。
- 前綴規則：只有 `VITE_` 前綴的變數會暴露給前端程式碼。
- **禁止**將機密資訊放入前端環境變數（前端程式碼會被打包至 bundle 中，對使用者可見）。

```typescript
// ✅ 使用環境變數
const apiBase = import.meta.env.VITE_API_BASE_URL;

// ❌ 機密不可放前端環境變數
const apiKey = import.meta.env.VITE_API_SECRET_KEY; // 會暴露在 bundle 中
```

### Build 最佳化

```typescript
export default defineConfig({
  build: {
    rollupOptions: {
      output: {
        manualChunks: {
          vendor: ['vue', 'vue-router', 'pinia']
        }
      }
    }
  }
});
```

- 第三方套件拆為獨立 chunk（`vendor`），利用瀏覽器快取。
- 路由元件使用動態 import 實現 Code Splitting（參閱 `vue-router` skill）。

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
