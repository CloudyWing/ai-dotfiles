---
name: translate-zh-en
description: 技術文件雙向翻譯（繁體中文 ↔ 英文），保留程式碼區塊原文，並維持術語一致性。Use when the user asks to translate documentation, comments, or technical content between Traditional Chinese and English.
---

# 技術文件雙向翻譯

## 翻譯方向判斷

- **繁體中文 → 英文**：原文主要為中文時。
- **英文 → 繁體中文**：原文主要為英文時，目標語言為台灣慣用的繁體中文。

若原文為混合語言，以主要語言決定翻譯方向，或詢問使用者。

## 翻譯規則

### 保留原文的情境

以下內容**一律保持原文，不翻譯**：

- 程式碼區塊（` ``` ` 包圍的內容）
- 行內程式碼（`` ` `` 包圍的內容）
- 指令與命令列（如 `dotnet run`、`npm install`）
- 專有名詞與技術術語（如 NuGet、Docker、Entity Framework）
- URL 與路徑
- 版本號（如 `v1.2.3`）

### 術語一致性

- **中文 → 英文**：技術術語優先使用 .NET / 業界慣用英文（如「相依性注入」→ Dependency Injection，不縮寫為 DI 除非上下文已建立縮寫）。
- **英文 → 中文**：優先使用台灣慣用譯法（如 Exception → 例外，不用「異常」；Configuration → 設定，不用「配置」）。

常見術語對照（中文 → 英文）：

| 中文 | 英文 |
| --- | --- |
| 例外 | Exception |
| 相依性注入 | Dependency Injection |
| 中介軟體 | Middleware |
| 介面 | Interface |
| 命名空間 | Namespace |
| 方法 | Method |
| 屬性 | Property |
| 建構函式 | Constructor |
| 非同步 | Asynchronous |
| 泛型 | Generic |

### 格式保留

- Markdown 結構（標題、清單、表格、粗體）完整保留。
- 中英文混排的空格規則（中文與英文/數字之間加空格）：翻譯後依目標語言的慣例調整。
- 表格的欄位對齊格式維持不變。

## 輸出格式

直接輸出翻譯結果，不附加原文。若有術語不確定或有多種譯法，以括號標注：

```
Dependency Injection（依賴注入 / 相依性注入）
```

## 注意事項

- 翻譯的目標是**忠實傳達技術意涵**，而非逐字對應。必要時重組句子結構以符合目標語言的表達習慣。
- 若原文有明顯的技術錯誤（如 API 名稱有誤），翻譯時保持原文的說法，不自行更正，並以 `⚠️` 標記。
- 不修改程式碼區塊的任何內容，包含縮排、換行、註解。
