---
name: csharp-linq
description: 'LINQ 查詢規範：回傳型別、語法選用與 Lambda 排版的專案慣例。當撰寫 In-Memory 集合操作或 LINQ to Objects 時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# LINQ 查詢規範

EF Core 的 LINQ to SQL 查詢由 `ef-core` skill 管轄，本文件不重複。延遲執行、操作子語意等通用知識不在此複述，本文件只收專案慣例。方法鏈的換行見 `csharp-style` skill「排版」，`FirstOrDefault()!` 的禁令見 `csharp-nrt` skill。

## 回傳型別

- **方法回傳值**：若回傳集合會被呼叫端多次使用，物化後以 `IReadOnlyList<T>` 回傳；若語意上為串流，回傳 `IEnumerable<T>` 並在 XML 文件中標註為延遲執行。

## 查詢語法 vs 方法語法

- **預設使用方法語法**（Method Syntax / Fluent Syntax）。
- **允許查詢語法的情境**：多重 `join`、`let` 綁定、`group by ... into` 等使用查詢語法可顯著提升可讀性時。
- 同一個查詢中**禁止混用**查詢語法與方法語法。

## Lambda 格式

- Lambda 簡短時（單一條件或單一投影）使用 expression body；複雜時使用 statement body 並換行。
