---
name: csharp-docs
description: 'C# 文件與 XML 註解標準：強制使用標準標籤與用詞規範產生類別與方法的說明。Use when writing, reviewing, or generating XML documentation comments (///) in C# files, or when the user asks to add, fix, or supplement XML docs.'
audience: agent
policy.allow_implicit_invocation: true
---

# C# 原始碼註解最佳實踐

## 通用 API 指南

### XML 註解分級

| 專案類型 | 對象 | 規則 |
| --- | --- | --- |
| 套件 / Library | 所有 `public` 成員 | 必須加入 XML 註解 |
| Web 專案 | Web API Controller Action | 加入 `<summary>`、`<param>` 與 `<returns>` |
| Web 專案 | 共用 Interface 方法 | 描述跨模組契約，實作類別使用 `<inheritdoc/>` |
| Web 專案 | 公開 Enum 值 | 補充命名無法表達的語意邊界 |
| Web 專案 | DTO / ViewModel / Entity 屬性 | 補充業務含義、格式約束與單位 |
| Web 專案 | 其他 public 成員 | 名稱不足以表達行為或存在非直覺行為時加入 |
| Web 專案 | private / internal | 不要求 XML 註解，使用 `//` 註解處理 |

- `<summary>` 以第三人稱現在式動詞開頭，例如 `Gets...` 或 `Initializes...`，說明 Why 與 What。
- `<summary>` 提供一句話的簡短描述。中文直接描述動作，例如取得、設定或初始化。
- `<remarks>`：用於補充詳細資訊、實作細節或上下文。
- `<see langword>`：用於語言關鍵字（如 `null`, `true`, `false`, `int`, `bool`）。
- `<c>`：用於行內程式碼片段。
- `<example>`：提供如何使用該成員的範例。內部應搭配 `<code language="csharp">`。
- `<see cref>`：用於句子內參照其他型別或成員。
- `<seealso>`：用於獨立的參照區段。
- `<inheritdoc/>`：繼承介面或基礎類別的註解。

## 方法 (Methods)

- `<param>`：描述參數用途（名詞片語，不要寫出資料型別）。
  - 若是布林值，寫法應為：`若要...則為 <see langword="true" />；否則為 <see langword="false" />。`。
- `<paramref>`：在說明中需要參照參數名稱時使用。
- `<returns>`：描述回傳值（名詞片語）。若是布林值，描述格式與 `<param>` 類似。
- `<typeparam>` 與 `<typeparamref>`：用於泛型型別參數。

## 屬性 (Properties)

- `<summary>` 開頭應為：
  - 讀寫屬性：「取得或設定... (Gets or sets ...)」
  - 唯讀屬性：「取得... (Gets ...)」
  - 布林屬性：「取得或設定一個值，用以指出是否...」
- 可使用 `<value>` 標籤描述回傳值的涵義及預設值。

## 例外 (Exceptions)

- 透過 `<exception cref="ExceptionType">` 記錄所有直接拋出的例外情況。
- 描述觸發例外的條件，直接陳述情境即可（避免前面的 "Thrown if..." 贅字，例如直接說「存取某某失敗時」。）。

## XML 標籤格式

`<summary>` **統一使用多行格式**，不以字數判斷：

```csharp
/// <summary>
/// 取得指定使用者的訂單清單。
/// </summary>
/// <param name="userId">使用者識別碼。</param>
/// <returns>該使用者的訂單集合。</returns>
```

**各標籤適用格式：**

- `<summary>` **固定使用多行**，即使內容僅一句話。
- `<param>` 與 `<returns>` 原則上使用**單行**（內容通常簡短）。若單行含標籤後超過 120 字元，則展開為多行。
- `<remarks>`、`<example>` 固定使用多行。
- 同一方法的多個標籤格式應保持視覺一致：若有某個標籤需要多行，其餘標籤格式保持不變。
