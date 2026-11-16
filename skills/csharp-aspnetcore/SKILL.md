---
name: csharp-aspnetcore
description: 'ASP.NET Core 開發規範：DI Lifetime、HttpClient、回應格式、API 版本控制、SameSite Cookie 與 Server-Sent Events。當偵測到 ASP.NET Core 專案或使用者要求撰寫 API 端點時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# ASP.NET Core 開發規範

## DI Lifetime（Crucial）

| Lifetime | 適用情境 |
| --- | --- |
| `Singleton` | 無狀態、執行緒安全的服務（如 `IOptions<T>`、記憶體快取） |
| `Scoped` | 每次 HTTP 請求一個實例；**DbContext 必須使用此 Lifetime** |
| `Transient` | 輕量、無狀態的短暫任務型服務 |

- Scoped 服務只能由 Scoped 或 Transient 消費；注入至 Singleton 將導致 **Captive Dependency**，造成資料隔離失效。
- 若需在 Singleton 中使用 Scoped 服務，必須透過 `IServiceScopeFactory` 手動建立 Scope。

## HttpClient

- **禁止**在方法內直接 `new HttpClient()`，會造成 Socket 耗盡問題。
- 必須透過 `IHttpClientFactory` 或具名/型別化用戶端（Named / Typed Client）注入。

## Minimal API vs Controller

- 不主動替換現有架構形式（Minimal API ↔ Controller）。
- 新建端點遵循**專案既有慣例**，不擅自引入另一種風格。

## 回應格式一致性

- API 的錯誤回應必須遵循 **ProblemDetails（RFC 9457）** 格式。
- 使用 `Results.Problem(...)` 或 `Results.ValidationProblem(...)` 產生標準化錯誤。

## API 版本控制

- 若專案已啟用 API Versioning（如 `Asp.Versioning.Http`），產生或修改端點時必須加入對應版本路由前綴（如 `/api/v1/`）。
- 不在未啟用版本控制的專案中自行加入版本前綴。

## 設定讀取（IOptions vs IConfiguration）

- **禁止**在服務類別中直接注入 `IConfiguration` 並以字串索引取值，會散落硬編碼 Key 且缺乏型別安全。
- 統一使用 **Options Pattern**：定義 POCO 設定類別，以 `IOptions<T>` / `IOptionsSnapshot<T>` / `IOptionsMonitor<T>` 注入。

## SameSite Cookie

| 值 | 行為 |
| --- | --- |
| `None` | 同站與跨站請求都送出 Cookie（仍受 `Domain`、`Path`、`Secure` 等條件限制），必須同時設定 `Secure` |
| `Lax` | 第一方請求，以及使用者從第三方網站以連結等方式導覽到本站時送出；現今瀏覽器的預設值 |
| `Strict` | 只在第一方請求送出 |

- 跨站請求時，`Lax` Cookie 只在使用安全方法（如 `GET`）的頂層導覽送出，例如點擊連結或以 `GET` 表單切換整個頁面；`POST` 表單、`iframe` 內的載入、AJAX 與 `<img>` 不會帶上 Cookie。判斷依據是請求是否為頂層導覽與使用的方法，同一個連結若在 `iframe` 內開啟就不算頂層導覽。
- `CookieOptions.SameSite` 預設為 `SameSiteMode.Unspecified`，未設定與指定 `Unspecified` 都不會寫出 SameSite 屬性，交由瀏覽器決定。
- `CookiePolicyOptions.MinimumSameSitePolicy` 與個別 Cookie 的設定取較嚴者，順序為 `Strict` > `Lax` > `None` > `Unspecified`。例如 `MinimumSameSitePolicy` 為 `Lax`、Cookie 設 `None` 時最終為 `Lax`。
- 使用 `CookiePolicyOptions` 時呼叫 `app.UseCookiePolicy()`，放在會寫出 Cookie 的中介軟體之前（例如 `UseAuthentication()` 之前）。
- SameSite 的效果依賴瀏覽器實作，不同瀏覽器版本行為可能不同。

## Server-Sent Events（SSE）

- 回應的 `Content-Type` 為 `text/event-stream`，並設定 `Cache-Control: no-cache`。
- 每則訊息以空行結束，即 `data: ...\n\n`；第一個 `\n` 結束該行，第二個 `\n` 結束該則訊息。自訂事件寫成 `event: <name>\ndata: ...\n\n`。
- `Response.WriteAsync()` 每次寫入後會自行 flush。改用 `Response.Body.WriteAsync()` 等不會自動 flush 的寫入方式時，每寫完一則訊息呼叫 `await Response.Body.FlushAsync()`，否則訊息停在緩衝區，用戶端收不到即時推送。回應緩衝或回應壓縮中介軟體也可能延遲推送。
- 同源的 `EventSource` 不設定 `withCredentials` 也會帶上 Cookie。跨域連線要帶 Cookie 時才設定 `new EventSource(url, { withCredentials: true })`，伺服端也需要允許 credentials 的 CORS 設定。

## 背景服務

- 不要在 Controller / Service 中自行 `Task.Run` 長期工作，一律改用 Hosted Service。
