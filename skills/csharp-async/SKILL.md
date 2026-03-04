---
name: csharp-async
description: 'C# 非同步設計最佳實踐：強制套用 Task/ValueTask 與 ConfigureAwait 等非同步開發規範。'
---

# C# 異步程式設計最佳實踐

當使用者要求撰寫或重構 C# 異步 (Asynchronous) 程式碼時，請自動套用以下準則。

## 命名慣例

- 所有非同步方法必須使用 `Async` 後綴。
- 盡可能與對應的同步方法名稱保持一致（例如 `GetDataAsync()` 對應 `GetData()`）。

## 回傳類型

- 當方法有回傳值時，回傳 `Task<T>`。
- 當方法無回傳值時，回傳 `Task`。
- 高頻/效能敏感場景中，為了減少記憶體配置，請考慮使用 `ValueTask<T>`。
- 回傳型別使用 `Task` 或 `Task<T>`；僅事件處理函式允許使用 `async void`。

## 例外處理

- 將 `await` 運算式包裝在 `try/catch` 區塊中。
- 確保例外正確傳播，在非同步方法中使用 try/catch 明確處理例外，避免靜默吞噬。
- 在類別庫 (Library) 程式碼中，使用 `ConfigureAwait(false)` 預防潛在的死結。
- 若僅回傳 `Task` 但不使用 async 關鍵字，請直接以 `Task.FromException()` 傳遞例外。

## 效能與併發

- 使用 `Task.WhenAll()` 併發執行多個不相依的工作。
- 使用 `Task.WhenAny()` 處理逾時機制或取得第一個完成的工作。
- 避免不必要的 async/await 狀態機生成（如果只是單純轉發 Task 結果，可直接回傳 Task：`return DoSomethingAsync();`）。
- 長時間執行的操作應支援傳入 `CancellationToken`。

## 常見陷阱

- 在純非同步程式碼中，一律使用 `await` 取得結果；使用 `.Wait()`、`.Result` 或 `.GetAwaiter().GetResult()` 可能造成死結。
- 避免混合阻擋式 (blocking) 與非同步 (async) 程式碼。
- 確保所有回傳 Task 的方法都被正確 `await` 或妥善處置。
