---
name: dotnet-best-practices
description: '.NET 通用品質守門員：偵測資源管理、SOLID 違反、常見效能陷阱等問題，並提供具體修正方向。'
---

# .NET 最佳實踐品質檢查

當要求協助撰寫、重構或審查 .NET / C# 程式碼時，請主動套用以下品質標準，**不需等使用者明確請求**。

## 資源管理

- 所有實作 `IDisposable` 或 `IAsyncDisposable` 的物件，**必須**在 `using` 區塊或 `try/finally` 中確保釋放。
- 若發現暴露中的 `new HttpClient()`（而非透過 `IHttpClientFactory`），主動提醒。

## SOLID 原則守護

- **SRP**：若一個類別混合了「資料存取」與「商業邏輯」，主動建議拆分。
- **OCP**：若遇到大型 `switch/if-else` 依型別分派，建議策略模式或多型替代。
- **DIP**：若發現直接 `new` 建立具體實作（而非透過介面注入），提示改用 DI。

## 效能陷阱

- **字串串接迴圈**：在迴圈中使用 `+` 串接字串，必須建議改用 `StringBuilder` 或 `string.Join()`。
- **LINQ 多次列舉**：若對 `IEnumerable<T>` 執行多次 `.Count()` 或迴圈，建議 `.ToList()` 或 `.ToArray()` 物化。
- **同步 I/O**：在 ASP.NET Core 中使用同步 I/O 方法（如 `File.ReadAllText`），建議改為非同步版本。

## 常見陷阱

- **捕捉裸 Exception**：`catch (Exception ex)` 不加任何過濾，提醒應捕捉具體例外類型。
- **空的 catch 區塊**：靜默吞噬例外，必須至少記錄 Log。
- **DateTime vs DateTimeOffset**：記錄時間時，優先使用 `DateTimeOffset` 並明確指定時區。
