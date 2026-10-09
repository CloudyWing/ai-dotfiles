---
name: generate-frontend-lint-config
description: 產生或補齊前端 Lint 設定（Prettier + ESLint Flat Config），統一格式化與程式碼品質規則，保留既有自訂偏好。
audience: human
dispatch: dispatchable
disable-model-invocation: true
policy.allow_implicit_invocation: false
---

# 產生或補齊前端 Lint 設定

## 範本來源

本 Skill 同時管理兩個檔案，各自以對應範本為單一來源：

| 目標檔案 | 範本來源 |
| --- | --- |
| `.prettierrc.json` | `~/.ai-agents/templates/.prettierrc.json` |
| `eslint.config.js` | `~/.ai-agents/templates/eslint.config.js` |

修改建議規則時，**只改範本檔，不改 SKILL.md**。SKILL.md 僅描述執行流程。

範本檔以 Vue 3 + TypeScript 專案為設計基準。若目標專案是純 JS、React、Svelte 等其他技術棧，產生後需手動調整 `eslint.config.js`，本 Skill 會在後續提醒中說明。

## 適用前提

本 Skill 假設目標專案：

- 是前端專案（存在 `package.json`，且依賴含 `vue`、`react`、`svelte`、`typescript` 其中之一，或目錄存在 `*.vue`、`*.ts`、`*.tsx`、`*.jsx`）。
- 使用 ESLint 9+（Flat Config）。若專案還在 ESLint 8 以下且使用 `.eslintrc.*`，本 Skill **不自動轉換格式**，僅產生 `eslint.config.js` 並提醒使用者手動處理舊版設定。

不符合前提時，告知使用者後流程終止。

## 執行步驟

### 1. 偵測專案環境

掃描目標專案：

1. 確認是否存在 `package.json`。
2. 從 `package.json` 的 `dependencies` / `devDependencies` 判斷主要框架（Vue / React / Svelte / 純 TS）。
3. 確認是否已存在 `.prettierrc*` 或 `eslint.config.*` / `.eslintrc.*`。

### 2. 讀取範本與既有設定

1. 讀取 `~/.ai-agents/templates/.prettierrc.json` 與 `~/.ai-agents/templates/eslint.config.js`。
2. 若目標專案已存在對應檔案：
   - 完整讀取現有內容。
   - 識別使用者已自訂的規則（如刻意設定的 `printWidth`、特定 `rules` 等）。
   - 後續步驟僅**補齊範本中有、現有檔案中缺少的規則**，不覆蓋已有設定。
3. 若不存在，後續步驟以範本內容為基底建立全新檔案。

### 3. 衝突偵測

對 Prettier 與 ESLint 各自比對既有規則與範本規則：

**Prettier 衝突項**：同一鍵但值不同（如現有 `tabWidth: 2`、範本為 `4`）。

**ESLint 衝突項**：

- 既有 config 已 `extends` / 引入某 plugin，但範本指定不同版本或不同 plugin。
- 既有 `rules` 區塊中與範本同名但設定值不同。

對每個衝突點，提供**最小變更方案**：優先保留使用者已設定的值，僅補齊完全缺少的規則。

若衝突點超過 3 個，在進入步驟 4 前先列出衝突清單，讓使用者決定哪些保留、哪些覆蓋。

特別注意：既有檔案的 `extends` 順序與 plugin 載入順序對 ESLint Flat Config 有語意意義，**不可任意重排**。

### 4. 套用前確認

分別顯示 `.prettierrc.json` 與 `eslint.config.js` 的預覽內容（或僅顯示新增/修改的段落），**停止等待使用者確認**後再執行寫入。確認格式：

```
以下是將要寫入的設定預覽：

【.prettierrc.json】
{
    "tabWidth": 4,
    ...
}

【eslint.config.js】
import js from '@eslint/js';
...

確認後將寫入，請回覆「確認」。
```

若使用者要求調整，修改後重新顯示確認。

### 5. 寫入結果

**已存在對應檔案**：使用 Merge 模式，將缺少的規則插入適當位置：

- `.prettierrc.json`：物件層級合併，保留既有鍵值。
- `eslint.config.js`：在現有 export 的陣列中插入缺少的 config 物件；若既有檔案結構與範本差異過大（如使用 legacy `.eslintrc` 或 CommonJS 寫法），不嘗試自動合併，告知使用者衝突並提供範本內容供手動整合。

**不存在對應檔案**：直接以範本內容建立新檔。

### 6. 後續提醒

寫入完成後，提醒使用者下列事項（不自動執行）：

1. **安裝相依套件**：依專案的套件管理器執行對應指令。

   ```bash
   # npm
   npm install -D eslint @eslint/js typescript-eslint eslint-plugin-vue eslint-config-prettier prettier

   # pnpm
   pnpm add -D eslint @eslint/js typescript-eslint eslint-plugin-vue eslint-config-prettier prettier

   # yarn
   yarn add -D eslint @eslint/js typescript-eslint eslint-plugin-vue eslint-config-prettier prettier
   ```

   若專案非 Vue，移除 `eslint-plugin-vue`。

2. **加入 npm scripts**（若 `package.json` 尚無對應 scripts）：

   ```json
   {
     "scripts": {
       "lint": "eslint . --fix",
       "format": "prettier --write ."
     }
   }
   ```

3. **非 Vue / 純 TS 專案的調整**：

   - 移除 `eslint.config.js` 中 `pluginVue` 的 import 與 `...pluginVue.configs['flat/recommended']` 一行。
   - 移除 Vue SFC parser 區塊。
   - 移除 `eslint-plugin-vue` 安裝指令。

4. **與 `.editorconfig` 的對齊**：確認 `.editorconfig` 的 `tab_width` / `indent_size` 與 `.prettierrc.json` 的 `tabWidth` 一致；`end_of_line` 與 `endOfLine` 一致。

5. **IDE 整合**：建議啟用 IDE 的 Format on Save，並設定 Prettier 為預設 formatter；ESLint extension 設為 lint on save。

### 7. 完成確認

輸出：

- 範本來源路徑。
- 寫入的檔案清單。
- 新增的規則段落清單。
- 略過（已存在）的規則清單。
- 衝突清單與處理結果。
- 後續提醒中需使用者執行的指令清單。
