---
name: vitest
description: '前端測試規範：Vitest 設定、Vue 元件測試、Composable 測試、Mock 策略與測試結構。當撰寫或修改前端測試時自動套用。'
---

# 前端測試規範（Vitest）

當撰寫或審查前端測試時，請自動套用以下規範。以 Vitest + Vue Test Utils 為主要框架。

## 測試框架設定

### vitest.config.ts

```typescript
import { defineConfig } from 'vitest/config';
import vue from '@vitejs/plugin-vue';
import { fileURLToPath, URL } from 'node:url';

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url))
    }
  },
  test: {
    globals: true,
    environment: 'jsdom',
    include: ['src/**/*.{test,spec}.{ts,tsx}'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'html'],
      include: ['src/**/*.{ts,vue}'],
      exclude: ['src/**/*.d.ts', 'src/**/*.test.ts', 'src/main.ts']
    }
  }
});
```

- `globals: true`：啟用全域 API（`describe`、`it`、`expect`），不需逐一 import。
- `environment: 'jsdom'`：提供 DOM 環境，元件測試必備。

## 測試結構（Crucial）

### AAA 模式

與後端 NUnit 規範一致，前端測試同樣嚴格遵守 Arrange-Act-Assert 模式。

```typescript
describe('OrderService', () => {
  it('should calculate total with tax', () => {
    // Arrange
    const items: OrderItem[] = [
      { productId: 1, quantity: 2, unitPrice: 100 },
      { productId: 2, quantity: 1, unitPrice: 200 }
    ];

    // Act
    const total = calculateTotal(items, 0.05);

    // Assert
    expect(total).toBe(420);
  });
});
```

- 三個區塊間空一行，不加 `// Arrange`、`// Act`、`// Assert` 註解。
- 每個 `it` 只驗證一種行為。

### 命名慣例

```typescript
// 檔案命名：與被測試模組對應
// useOrderList.ts → useOrderList.test.ts
// OrderDetail.vue → OrderDetail.test.ts

// 測試描述：使用 should + 動詞
describe('useOrderList', () => {
  it('should fetch orders on mount', () => {});
  it('should filter pending orders', () => {});
  it('should handle fetch error gracefully', () => {});
});
```

### 測試檔案位置

```text
src/
├── composables/
│   ├── useOrderList.ts
│   └── useOrderList.test.ts     # 與原始碼並列
├── components/
│   ├── OrderCard.vue
│   └── OrderCard.test.ts
```

- 測試檔案與原始碼放在同一目錄，不集中到 `__tests__/` 資料夾。
- 遵循**專案既有慣例**：若專案使用 `__tests__/` 目錄結構，新測試沿用。

## Vue 元件測試

### 基本結構

```typescript
import { describe, it, expect } from 'vitest';
import { mount } from '@vue/test-utils';
import OrderCard from '@/components/OrderCard.vue';

describe('OrderCard', () => {
  it('should render order title', () => {
    const wrapper = mount(OrderCard, {
      props: {
        order: {
          id: 1,
          title: '測試訂單',
          status: 'pending'
        }
      }
    });

    expect(wrapper.text()).toContain('測試訂單');
  });

  it('should emit delete event when delete button clicked', async () => {
    const wrapper = mount(OrderCard, {
      props: {
        order: { id: 1, title: '測試', status: 'pending' }
      }
    });

    await wrapper.find('[data-testid="delete-btn"]').trigger('click');

    expect(wrapper.emitted('delete')).toHaveLength(1);
    expect(wrapper.emitted('delete')![0]).toEqual([1]);
  });
});
```

### 測試選擇器

```vue
<!-- 元件中加入 data-testid -->
<button data-testid="submit-btn" @click="handleSubmit">送出</button>
```

- **優先**使用 `data-testid` 選擇元素，不依賴 CSS class 或標籤結構。
- `data-testid` 不受樣式重構影響，測試更穩定。

### 全域插件與 Mock

```typescript
import { createTestingPinia } from '@pinia/testing';
import { createRouter, createMemoryHistory } from 'vue-router';

function mountWithPlugins(component: Component, options = {}) {
  return mount(component, {
    global: {
      plugins: [
        createTestingPinia({
          createSpy: vi.fn
        }),
        createRouter({
          history: createMemoryHistory(),
          routes: [{ path: '/', component: { template: '<div />' } }]
        })
      ]
    },
    ...options
  });
}
```

## Composable 測試

### 獨立測試（不依賴元件）

```typescript
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { useOrderList } from '@/composables/useOrderList';
import { orderApi } from '@/api/order';
import { flushPromises } from '@vue/test-utils';

vi.mock('@/api/order');

describe('useOrderList', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('should fetch orders on initialization', async () => {
    const mockOrders = [
      { id: 1, title: '訂單 A', status: 'pending' },
      { id: 2, title: '訂單 B', status: 'completed' }
    ];
    vi.mocked(orderApi.getAll).mockResolvedValue(mockOrders);

    const { orders, isLoading } = useOrderList();

    expect(isLoading.value).toBe(true);
    await flushPromises();
    expect(isLoading.value).toBe(false);
    expect(orders.value).toEqual(mockOrders);
  });

  it('should handle fetch error', async () => {
    vi.mocked(orderApi.getAll).mockRejectedValue(new Error('Network Error'));

    const { error } = useOrderList();

    await flushPromises();
    expect(error.value).toBe('Network Error');
  });
});
```

### 需要 Vue 生命週期的 Composable

若 Composable 使用 `onMounted` 等生命週期 Hook，需要在元件 setup 中執行：

```typescript
import { withSetup } from '@/test-utils/withSetup';

function withSetup<T>(composable: () => T) {
  let result: T;
  const app = createApp({
    setup() {
      result = composable();
      return () => {};
    }
  });
  app.mount(document.createElement('div'));
  return { result: result!, app };
}

// 使用
const { result } = withSetup(() => useOrderList());
```

## Mock 策略

### 模組 Mock

```typescript
// Mock 整個模組
vi.mock('@/api/order', () => ({
  orderApi: {
    getAll: vi.fn(),
    create: vi.fn(),
    delete: vi.fn()
  }
}));

// 或自動 Mock（所有匯出替換為 vi.fn()）
vi.mock('@/api/order');
```

### Timer Mock

```typescript
describe('debounced search', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('should debounce search input', async () => {
    const { search } = useSearch();

    search('test');
    expect(searchApi.query).not.toHaveBeenCalled();

    vi.advanceTimersByTime(300);
    expect(searchApi.query).toHaveBeenCalledWith('test');
  });
});
```

### API Mock

```typescript
// ✅ Mock Axios instance（若使用 Axios）
vi.mock('@/lib/axios', () => ({
  default: {
    get: vi.fn(),
    post: vi.fn(),
    put: vi.fn(),
    delete: vi.fn()
  }
}));
```

## Pinia Store 測試

```typescript
import { setActivePinia, createPinia } from 'pinia';
import { useOrderStore } from '@/stores/order';

vi.mock('@/api/order');

describe('useOrderStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.clearAllMocks();
  });

  it('should fetch and store orders', async () => {
    const mockOrders = [{ id: 1, title: '訂單 A', status: 'pending' }];
    vi.mocked(orderApi.getAll).mockResolvedValue(mockOrders);

    const store = useOrderStore();
    await store.fetchOrders();

    expect(store.orders).toEqual(mockOrders);
    expect(store.isLoading).toBe(false);
  });

  it('should compute pending orders', async () => {
    const store = useOrderStore();
    store.orders = [
      { id: 1, status: 'pending' },
      { id: 2, status: 'completed' },
      { id: 3, status: 'pending' }
    ] as Order[];

    expect(store.pendingOrders).toHaveLength(2);
  });
});
```

## 斷言最佳實踐

```typescript
// ✅ 具體斷言
expect(result).toBe(42);                    // 嚴格相等
expect(result).toEqual({ id: 1, name: 'A' }); // 深度相等
expect(list).toHaveLength(3);
expect(wrapper.text()).toContain('訂單');
expect(fn).toHaveBeenCalledWith(1, 'test');
expect(fn).toHaveBeenCalledTimes(1);

// ❌ 避免模糊斷言
expect(result).toBeTruthy();                // 不具體
expect(list.length > 0).toBe(true);         // 用 toHaveLength
```

## 禁止模式

```typescript
// ❌ 測試實作細節（元件內部 ref 的值）
expect(wrapper.vm.internalCount).toBe(3);

// ✅ 測試行為與輸出
expect(wrapper.text()).toContain('3');

// ❌ 快照測試濫用（UI 頻繁變動時快照會不斷失敗）
expect(wrapper.html()).toMatchSnapshot();

// ❌ 不寫斷言的測試
it('should work', () => {
  const result = doSomething();
  // 沒有 expect
});
```
