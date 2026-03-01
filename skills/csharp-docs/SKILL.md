---
name: csharp-docs
description: 'C# 文件與 XML 註解標準：強制使用標準標籤與用詞規範產生類別與方法的說明。'
---

# C# 原始碼註解最佳實踐

當要求幫 C# 程式碼產生或補充 XML 註解時，必須嚴格遵守以下準則。

## 通用 API 指南

- 針對公開 (Public) 成員必須包含 XML 註解；內部 (Internal) 若有複雜邏輯亦強烈建議加入。
- `<summary>`：提供一句話的簡短描述。中文應直接描述動作（例如：取得或設定...、初始化...）。
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
