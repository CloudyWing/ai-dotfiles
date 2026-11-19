---
name: vitest
description: '前端測試規範：Vitest 設定、Vue 元件測試、Composable 測試、Mock 策略與測試結構。當撰寫或修改前端測試時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# 前端測試規範（Vitest）

以 Vitest + Vue Test Utils 為主要框架。

## 測試框架設定

### vitest.config.ts

- `globals: true`：啟用全域 API（`describe`、`it`、`expect`），不需逐一 import。
- `environment: 'jsdom'`：提供 DOM 環境，元件測試必備。
- `include` 為 `src/**/*.{test,spec}.{ts,tsx}`；`resolve.alias` 與 `vite.config.ts` 一致。
- 覆蓋率（`test.coverage`）：`provider` 為 `v8`，`reporter` 為 `text` 與 `html`，`include` 為 `['src/**/*.{ts,vue}']`，`exclude` 為 `['src/**/*.d.ts', 'src/**/*.test.ts', 'src/main.ts']`。

## 測試結構

### AAA 模式

與後端 NUnit 規範一致，前端測試同樣嚴格遵守 Arrange-Act-Assert 模式。

- 三個區塊間空一行，不加 `// Arrange`、`// Act`、`// Assert` 註解。
- 每個 `it` 只驗證一種行為。

### 命名慣例

- 測試檔與被測模組同名並加上 `.test.ts`（`useOrderList.ts` 對應 `useOrderList.test.ts`，`OrderDetail.vue` 對應 `OrderDetail.test.ts`）。
- `it` 的描述使用 `should` 加動詞（如 `should fetch orders on mount`）。

### 測試檔案位置

- 測試檔案與原始碼放在同一目錄，不集中到 `__tests__/` 資料夾。
- 遵循**專案既有慣例**：若專案使用 `__tests__/` 目錄結構，新測試沿用。

## Vue 元件測試

### 測試選擇器

- **優先**使用 `data-testid` 選擇元素，不依賴 CSS class 或標籤結構。
- `data-testid` 不受樣式重構影響，測試更穩定。

### 全域插件與 Mock

- 需要 Pinia 或 Router 的元件，以共用的掛載輔助函式（如 `mountWithPlugins`）在 `global.plugins` 加入 `createTestingPinia({ createSpy: vi.fn })` 與使用 `createMemoryHistory()` 的 Router（只需一筆 `/` 的空元件路由）；呼叫端傳入的掛載選項展開在後。

## Composable 測試

### 需要 Vue 生命週期的 Composable

若 Composable 使用 `onMounted` 等生命週期 Hook，需要在元件 setup 中執行。以輔助函式（如 `@/test-utils/withSetup`）建立 app，在 `setup()` 內呼叫 Composable 後掛載，回傳 Composable 的結果與 app。

## Mock 策略

### API Mock

- 使用 Axios 時以 `vi.mock('@/lib/axios', ...)` mock 封裝後的實例，回傳模組的 `default` 為各方法（`get`、`post`、`put`、`delete`）皆是 `vi.fn()` 的物件。

## 斷言最佳實踐

- 使用具體斷言：`toBe`（嚴格相等）、`toEqual`（深度相等）、`toHaveLength`、`toContain`、`toHaveBeenCalledWith`、`toHaveBeenCalledTimes`。
- 避免模糊斷言：不以 `toBeTruthy()` 驗證具體值；驗證長度用 `toHaveLength`，不寫 `expect(list.length > 0).toBe(true)`。

## 禁止模式

- 禁止測試實作細節（如透過 `wrapper.vm` 讀取元件內部 ref 的值），改為驗證行為與輸出。
- 禁止濫用快照測試（`toMatchSnapshot`），UI 頻繁變動時快照會不斷失敗。
- 禁止不寫斷言的測試。
