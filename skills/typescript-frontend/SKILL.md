---
name: typescript-frontend
description: '前端 TypeScript 規範：strict 模式、型別設計、泛型使用、型別窄化與 Vue 3 整合。當偵測到前端 TypeScript 專案時自動套用。'
---

# 前端 TypeScript 規範

當偵測到前端 TypeScript 專案（`tsconfig.json` 中包含 Vue/React 相關設定）或使用者要求撰寫前端 TypeScript 程式碼時，請自動套用以下規範。

## 嚴格模式（Crucial）

### tsconfig.json 基本設定

```json
{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": false,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true
  }
}
```

- `strict: true` 為強制項。新專案不允許關閉。
- 遵循**專案既有設定**：若既有專案未啟用 strict，不強迫修改，但新檔案應以 strict 標準撰寫。

## 型別設計

### interface vs type

| 選擇 | 適用情境 |
| --- | --- |
| `interface` | 物件形狀定義（API 回應、Props、State）、可擴展的契約 |
| `type` | 聯合型別、交叉型別、Mapped Types、Utility Types 組合 |

```typescript
// ✅ interface：物件形狀
interface Order {
  id: number
  customerName: string
  items: ReadonlyArray<OrderItem>
  note?: string
}

// ✅ type：聯合型別
type OrderStatus = 'pending' | 'processing' | 'completed' | 'cancelled'

// ✅ type：複雜型別操作
type PartialOrder = Partial<Pick<Order, 'customerName' | 'note'>>
```

- 同一專案中選定一種作為物件定義的預設，保持一致。
- **禁止**在 interface 和 type 之間反覆切換同一個型別定義。

### 禁止 any（Crucial）

```typescript
// ❌ 禁止
function process(data: any) { }
const result: any = fetchData()

// ✅ 替代方案
function process(data: unknown) {
  if (isOrder(data)) {
    // 窄化後使用
  }
}

// ✅ 泛型
function process<T>(data: T): T { }
```

- `any` 完全繞過型別檢查，等同關閉 TypeScript。
- 需要表達「任意型別」時使用 `unknown`，強制呼叫端做型別窄化。
- 第三方套件缺少型別定義時，優先尋找 `@types/*` 套件；無法取得時，自行撰寫 `.d.ts` 宣告檔。

### 避免 as 斷言

```typescript
// ❌ 避免：型別斷言（跳過檢查）
const order = response.data as Order

// ✅ 正確：使用 Type Guard 做執行期驗證
function isOrder(data: unknown): data is Order {
  return (
    typeof data === 'object'
    && data !== null
    && 'id' in data
    && 'customerName' in data
  )
}

if (isOrder(response.data)) {
  // data 在此處為 Order 型別
}
```

- `as` 不做執行期檢查，API 回傳格式變更時不會報錯。
- 允許使用 `as` 的情境：`as const`（常數斷言）、測試程式碼中已知結構的資料。

## 型別窄化（Type Narrowing）

### 常用窄化技巧

```typescript
// typeof guard
function formatValue(value: string | number): string {
  if (typeof value === 'string') {
    return value.toUpperCase()
  }
  return value.toFixed(2)
}

// in operator
function getArea(shape: Circle | Rectangle): number {
  if ('radius' in shape) {
    return Math.PI * shape.radius ** 2
  }
  return shape.width * shape.height
}

// Discriminated Union（推薦）
type ApiResult<T> =
  | { success: true; data: T }
  | { success: false; error: string }

function handleResult(result: ApiResult<Order>) {
  if (result.success) {
    // result.data 可用
    console.log(result.data.id)
  } else {
    // result.error 可用
    console.error(result.error)
  }
}
```

### Discriminated Union 設計

- API 回應、表單狀態、非同步操作等多態場景，優先使用 Discriminated Union。
- 判別屬性（discriminant）使用字串字面量型別。

## 列舉替代方案

```typescript
// ❌ 避免 enum（產生額外的 JavaScript 程式碼）
enum Status {
  Pending,
  Active,
  Closed
}

// ✅ 使用 const 物件 + as const
const Status = {
  Pending: 'pending',
  Active: 'active',
  Closed: 'closed',
} as const

type Status = typeof Status[keyof typeof Status]
// => 'pending' | 'active' | 'closed'

// ✅ 簡單場景直接用聯合型別
type Status = 'pending' | 'active' | 'closed'
```

- TypeScript `enum` 產生額外的 IIFE 程式碼，增加 bundle 大小。
- 與後端 API 的溝通使用字串值，避免數字 enum 的脆弱性。

## 泛型

### 元件 Props 泛型

```vue
<script setup lang="ts" generic="T">
defineProps<{
  items: ReadonlyArray<T>
  selected?: T
}>()

const emit = defineEmits<{
  select: [item: T]
}>()
</script>
```

### 函式泛型

```typescript
// ✅ 泛型工具函式
function groupBy<T, K extends string | number>(
  items: ReadonlyArray<T>,
  keyFn: (item: T) => K
): Record<K, T[]> {
  const result = {} as Record<K, T[]>
  for (const item of items) {
    const key = keyFn(item)
    ;(result[key] ??= []).push(item)
  }
  return result
}

// 使用時自動推斷型別
const grouped = groupBy(orders, o => o.status)
```

- 泛型參數只在需要關聯多個位置的型別時使用，不為了泛型而泛型。
- 命名：單一參數用 `T`；多參數用有意義的名稱（如 `TInput`、`TOutput`）。

## Utility Types 常用清單

| Type | 用途 |
| --- | --- |
| `Partial<T>` | 所有屬性可選 |
| `Required<T>` | 所有屬性必填 |
| `Pick<T, K>` | 選取部分屬性 |
| `Omit<T, K>` | 排除部分屬性 |
| `Record<K, V>` | 建立鍵值對型別 |
| `Readonly<T>` | 所有屬性唯讀 |
| `ReturnType<T>` | 取得函式回傳型別 |
| `Parameters<T>` | 取得函式參數型別 |
| `Awaited<T>` | 取得 Promise 解析後的型別 |

```typescript
// 常見組合
type CreateOrderInput = Omit<Order, 'id' | 'createdAt'>
type OrderUpdate = Partial<Pick<Order, 'customerName' | 'note'>>
```

## 型別檔案組織

```text
src/types/
├── order.ts        # 訂單相關型別
├── customer.ts     # 客戶相關型別
├── api.ts          # API 通用型別（Response wrapper、Pagination）
└── index.ts        # 統一匯出
```

- 一個 domain 一個型別檔案，以 domain 名稱命名。
- 匯出使用 `export type`（確保型別在編譯後被移除）。
- **禁止**將所有型別放在一個巨大的 `types.ts` 中。

```typescript
// types/order.ts
export interface Order {
  id: number
  customerName: string
  items: ReadonlyArray<OrderItem>
}

export interface OrderItem {
  productId: number
  quantity: number
  unitPrice: number
}

export type OrderStatus = 'pending' | 'processing' | 'completed' | 'cancelled'
```

## 非同步型別安全

```typescript
// ✅ API 回應型別
interface ApiResponse<T> {
  data: T
  message: string
}

interface PaginatedResponse<T> {
  data: ReadonlyArray<T>
  total: number
  page: number
  pageSize: number
}

// ✅ 非同步函式回傳型別明確標註
async function fetchOrder(id: number): Promise<Order> {
  const response = await api.get<ApiResponse<Order>>(`/orders/${id}`)
  return response.data.data
}
```

## 與 Vue 3 整合

### 元件實例型別

```typescript
import type { ComponentPublicInstance } from 'vue'

// Template Ref 型別
const formRef = ref<InstanceType<typeof MyForm> | null>(null)

// 使用
formRef.value?.validate()
```

### Provide / Inject 型別安全

```typescript
// keys.ts
import type { InjectionKey } from 'vue'
import type { AuthService } from '@/services/auth'

export const authServiceKey: InjectionKey<AuthService> = Symbol('authService')

// 提供方
provide(authServiceKey, authService)

// 注入方
const authService = inject(authServiceKey)
if (!authService) {
  throw new Error('AuthService 未提供')
}
```

### 事件型別

```typescript
// ✅ 原生事件型別
function handleClick(event: MouseEvent) { }
function handleInput(event: Event) {
  const target = event.target as HTMLInputElement
  console.log(target.value)
}
```
