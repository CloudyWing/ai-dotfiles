---
name: typescript-frontend
description: '前端 TypeScript 規範：strict 模式、型別設計、泛型使用、型別窄化與 Vue 3 整合。當偵測到前端 TypeScript 專案時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# 前端 TypeScript 規範

## 嚴格模式

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

- 同一專案中選定一種作為物件定義的預設，保持一致。
- **禁止**在 interface 和 type 之間反覆切換同一個型別定義。

### 禁止 any

- `any` 完全繞過型別檢查，等同關閉 TypeScript。
- 需要表達「任意型別」時使用 `unknown`，強制呼叫端做型別窄化。
- 第三方套件缺少型別定義時，優先尋找 `@types/*` 套件；無法取得時，自行撰寫 `.d.ts` 宣告檔。

### 避免 as 斷言

- API 回應等外部資料以 Type Guard（`data is Order`）做執行期驗證後使用，避免以 `as` 斷言。
- `as` 不做執行期檢查，API 回傳格式變更時不會報錯。
- 允許使用 `as` 的情境：`as const`（常數斷言）、測試程式碼中已知結構的資料。

## 型別窄化（Type Narrowing）

- 依情境使用 `typeof`、`in` 運算子與 Discriminated Union 窄化型別。

### Discriminated Union 設計

- API 回應、表單狀態、非同步操作等多態場景，優先使用 Discriminated Union。
- 判別屬性（discriminant）使用字串字面量型別（如 `status: 'success' | 'error'`）。

## 列舉替代方案

- 避免使用 `enum`。改用 `as const` 物件，並以 `typeof Status[keyof typeof Status]` 取得聯合型別；簡單場景直接用字串聯合型別（如 `'pending' | 'active' | 'closed'`）。
- TypeScript `enum` 產生額外的 IIFE 程式碼，增加 bundle 大小。
- 與後端 API 的溝通使用字串值，避免數字 enum 的脆弱性。

## 泛型

### 函式泛型

- 泛型參數只在需要關聯多個位置的型別時使用，不為了泛型而泛型。
- 命名：單一參數用 `T`；多參數用有意義的名稱（如 `TInput`、`TOutput`）。

## Utility Types 常用清單

- 輸入型別由實體型別以 `Omit`、`Pick`、`Partial` 衍生（如 `Omit<Order, 'id' | 'createdAt'>`、`Partial<Pick<Order, 'customerName' | 'note'>>`）。

## 型別檔案組織

- 一個 domain 一個型別檔案，以 domain 名稱命名。
- 匯出使用 `export type`（確保型別在編譯後被移除）。
- **禁止**將所有型別放在一個巨大的 `types.ts` 中。
- API 通用型別（分頁回應、ProblemDetails）放 `types/api.ts`；`index.ts` 統一匯出。

## 非同步型別安全

- 非同步函式的回傳型別明確標註（如 `Promise<Order>`）。
- 單一資源的 API 回應不包 wrapper，成功時的回應內容就是資源型別（如 `api.get<Order>`）；分頁清單使用 `PaginatedResponse<T>`；錯誤回應為 ProblemDetails。型別定義見 `openapi-client` skill「通用型別定義」。

## 與 Vue 3 整合

### Provide / Inject 型別安全

- 以 `InjectionKey<T>` 的 `Symbol` 作為 key，集中定義於 `keys.ts`。
- `inject` 的結果可能為 `undefined`，使用前檢查，缺少時拋出錯誤。

### 事件型別

- 事件處理函式的參數標註原生事件型別（如 `MouseEvent`、`Event`）。
- `event.target` 以 `instanceof`（如 `HTMLInputElement`）窄化後使用。
