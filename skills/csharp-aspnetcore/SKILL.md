---
name: csharp-aspnetcore
description: 'ASP.NET Core 開發規範：端點風格沿用、API 版本控制、Options Pattern 設定讀取、SameSite Cookie 與 Server-Sent Events 的行為陷阱。當偵測到 ASP.NET Core 專案或使用者要求撰寫 API 端點時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# ASP.NET Core 開發規範

錯誤回應格式見 `csharp-error-handling` skill「ProblemDetails 標準化」，背景工作見 `csharp-background-service` skill。

## Minimal API vs Controller

- 不主動替換現有架構形式（Minimal API ↔ Controller）。
- 新建端點遵循**專案既有慣例**，不擅自引入另一種風格。

## API 版本控制

- 若專案已啟用 API Versioning（如 `Asp.Versioning.Http`），產生或修改端點時必須加入對應版本路由前綴（如 `/api/v1/`）。
- 不在未啟用版本控制的專案中自行加入版本前綴。

## 設定讀取（IOptions vs IConfiguration）

- **禁止**在服務類別中直接注入 `IConfiguration` 並以字串索引取值，會散落硬編碼 Key 且缺乏型別安全。
- 統一使用 **Options Pattern**：定義 POCO 設定類別，以 `IOptions<T>` / `IOptionsSnapshot<T>` / `IOptionsMonitor<T>` 注入。

## SameSite Cookie

- 跨站請求時，`Lax` Cookie 只在使用安全方法（如 `GET`）的頂層導覽送出，例如點擊連結或以 `GET` 表單切換整個頁面；`POST` 表單、`iframe` 內的載入、AJAX 與 `<img>` 不會帶上 Cookie。判斷依據是請求是否為頂層導覽與使用的方法，同一個連結若在 `iframe` 內開啟就不算頂層導覽。
- `CookieOptions.SameSite` 預設為 `SameSiteMode.Unspecified`，未設定與指定 `Unspecified` 都不會寫出 SameSite 屬性，交由瀏覽器決定。
- `CookiePolicyOptions.MinimumSameSitePolicy` 與個別 Cookie 的設定取較嚴者，順序為 `Strict` > `Lax` > `None` > `Unspecified`。例如 `MinimumSameSitePolicy` 為 `Lax`、Cookie 設 `None` 時最終為 `Lax`。
- 使用 `CookiePolicyOptions` 時呼叫 `app.UseCookiePolicy()`，放在會寫出 Cookie 的中介軟體之前（例如 `UseAuthentication()` 之前）。

## Server-Sent Events（SSE）

- `Response.WriteAsync()` 每次寫入後會自行 flush。改用 `Response.Body.WriteAsync()` 等不會自動 flush 的寫入方式時，每寫完一則訊息呼叫 `await Response.Body.FlushAsync()`，否則訊息停在緩衝區，用戶端收不到即時推送。回應緩衝或回應壓縮中介軟體也可能延遲推送。
- 同源的 `EventSource` 不設定 `withCredentials` 也會帶上 Cookie。跨域連線要帶 Cookie 時才設定 `new EventSource(url, { withCredentials: true })`，伺服端也需要允許 credentials 的 CORS 設定。
