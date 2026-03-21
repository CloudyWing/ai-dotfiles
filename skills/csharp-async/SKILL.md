---
name: csharp-async
description: 'C# 非同步設計最佳實踐：強制套用 Task/ValueTask 與 ConfigureAwait 等非同步開發規範。'
---

# C# 非同步程式設計最佳實踐

當使用者要求撰寫或重構 C# 非同步 (Asynchronous) 程式碼時，請自動套用以下準則。底線規則（`Task`/`Task<T>` 回傳型別、`ConfigureAwait(false)`、禁止 `.Result`/`.Wait()`）由全域規範管理，本 Skill 僅涵蓋延伸最佳實踐。

## 命名慣例

- 所有非同步方法必須使用 `Async` 後綴。
- 盡可能與對應的同步方法名稱保持一致（例如 `GetDataAsync()` 對應 `GetData()`）。

## 回傳類型延伸

- **`async void` 例外**：僅事件處理函式允許使用，其他情境一律使用 `Task`。
- **`ValueTask<T>`**：高頻或效能敏感場景中，為減少記憶體配置可考慮使用，但不作為預設選型。

## 例外處理

- 將 `await` 運算式包裝在 `try/catch` 區塊中，確保例外正確傳播，避免靜默吞噬。
- 若方法簽名回傳 `Task` 但不使用 `async` 關鍵字，以 `Task.FromException()` 傳遞例外，不使用 `throw`。

## 效能與併發

- 使用 `Task.WhenAll()` 併發執行多個不相依的工作。
- 使用 `Task.WhenAny()` 處理逾時機制或取得第一個完成的工作。
- 避免不必要的 async/await 狀態機生成：若方法僅轉發 Task 結果，直接回傳 Task（`return DoSomethingAsync();`），不加 `async`/`await`。
- 長時間執行的操作應支援傳入 `CancellationToken`。

## 常見陷阱

- 避免混合阻擋式 (blocking) 與非同步 (async) 程式碼。
- 確保所有回傳 Task 的方法都被正確 `await` 或妥善處置，不得靜默丟棄。
