# Blazor Hybrid e2e（Playwright）與 Blazor Web App e2e 簡述

本檔收錄以 Playwright 透過 CDP 連線 WebView2 的規則與連線重試範例，以及 Blazor Web App 以 Playwright 做 e2e 的等待重點。撰寫或修改 Playwright 的 Blazor 測試時讀。

## Blazor Hybrid e2e（Playwright）

需要 CSS 選擇器、DOM 細節、JS 狀態或網路攔截，且不需操作原生外殼時，改用 Playwright 透過 Chrome DevTools Protocol（CDP）連線 WebView2。其餘情況用 FlaUI。

- 開啟遠端偵錯：啟動前設定環境變數 `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=<port>`，或以 `CoreWebView2EnvironmentOptions.AdditionalBrowserArguments` 設定〔官方〕。
- 連線：以 `ConnectOverCDPAsync` 連線後取 `Contexts[0].Pages[0]`〔官方〕。
- 隔離平行執行：WebView2 預設所有執行個體共用同一個使用者資料目錄，每次執行要使用不同的 port 與 `WEBVIEW2_USER_DATA_FOLDER`〔官方〕。port 由專案自行取得，例如以 `TcpListener` 綁定 port 0 取得空閒 port〔建議〕。
- 支援範圍：官方頁面只寫 WebView2 適用 Windows 10 與 Windows 11，未列 WebView2 Runtime 或 Playwright 的最低版本〔官方〕。
- 連線時機：官方範例在程序內以 `CoreWebView2InitializationCompleted` 確認初始化完成〔官方〕。外部啟動的 exe 沒有這個事件，改等 `hybrid-flaui.md` 的就緒 marker 後再連線，`Pages` 為空時重試〔建議〕。
- 限制遠端偵錯 port 只在測試啟動時開啟，不進入正式發行設定〔建議〕。
- 截圖範圍：Playwright 的 page screenshot 只含 WebView2 網頁區域，不含原生外殼〔推論〕。

來源：<https://playwright.dev/dotnet/docs/webview2>、<https://learn.microsoft.com/en-us/microsoft-edge/webview2/how-to/playwright>。

片段：WebView2PlaywrightTests.cs（連線與重試）

```csharp
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using Microsoft.Playwright;
using NUnit.Framework;
using static Microsoft.Playwright.Assertions;

namespace MyApp.UiTests;

[TestFixture]
[Category(UiTestCategory.Name)]
[NonParallelizable]
[Platform(Include = "Win")]
public sealed class WebView2PlaywrightTests {
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(60);

    private Process? process;
    private IPlaywright? playwright;
    private IBrowser? browser;
    private string? userDataFolder;

    [SetUp]
    public async Task LaunchAndConnectAsync() {
        string? executablePath = Environment.GetEnvironmentVariable("MYAPP_DESKTOP_EXE");
        if (string.IsNullOrWhiteSpace(executablePath) || !File.Exists(executablePath)) {
            Assert.Ignore("請以環境變數 MYAPP_DESKTOP_EXE 指定受測執行檔。");
        }

        int port = GetFreePort();
        userDataFolder = Path.Combine(Path.GetTempPath(), "MyApp.UiTests", Guid.NewGuid().ToString("N"));
        ProcessStartInfo startInfo = new(executablePath) {
            UseShellExecute = false
        };
        startInfo.Environment["WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS"] = $"--remote-debugging-port={port}";
        startInfo.Environment["WEBVIEW2_USER_DATA_FOLDER"] = userDataFolder;
        process = Process.Start(startInfo) ?? throw new InvalidOperationException("無法啟動受測程式。");

        playwright = await Playwright.CreateAsync();
        browser = await ConnectWithRetryAsync(playwright, $"http://127.0.0.1:{port}", process);
    }

    private async Task<IPage> GetPageAsync() {
        Stopwatch stopwatch = Stopwatch.StartNew();
        while (stopwatch.Elapsed < ConnectTimeout) {
            IPage? page = browser!.Contexts.FirstOrDefault()?.Pages.FirstOrDefault();
            if (page is not null) {
                return page;
            }

            await Task.Delay(250);
        }

        throw new AssertionException("WebView2 尚未建立頁面。");
    }

    private static async Task<IBrowser> ConnectWithRetryAsync(IPlaywright playwright, string endpoint, Process target) {
        Stopwatch stopwatch = Stopwatch.StartNew();
        while (true) {
            try {
                return await playwright.Chromium.ConnectOverCDPAsync(endpoint);
            } catch (PlaywrightException) when (stopwatch.Elapsed < ConnectTimeout && !target.HasExited) {
                await Task.Delay(500);
            }
        }
    }
}
```

範例在受測程式啟動後輪詢 CDP 端點直到可連線，正式專案建議先等 `hybrid-flaui.md` 的就緒 marker〔建議〕。

## Blazor Web App e2e 簡述

- 以一般 Playwright 對瀏覽器測試 Blazor Web App（Server 與 WebAssembly）。E2E 驗證前必須確認環境已達預期狀態〔官方〕。
- 等待互動就緒。互動式 render mode 預設先預先渲染，`RendererInfo.IsInteractive` 在預先渲染與靜態 SSR 時為 `false`，靜態 SSR 下 Blazor 事件處理不運作，在預先渲染的靜態 HTML 上操作會讓事件不觸發〔官方〕。
- 選用等待訊號：官方範例以 `disabled="@(!RendererInfo.IsInteractive)"` 讓按鈕在互動就緒前停用〔官方〕。測試以 Playwright 網頁優先斷言（例如 `ToBeEnabledAsync`）等待該訊號，斷言會自動重試，預設逾時 5 秒，WebAssembly 首次載入較慢時調高逾時〔官方〕。app 沒有這類訊號時，由 app 暴露一個互動後才出現的元素或屬性〔建議〕。
- 判斷就緒時不使用 `networkidle`，Playwright 官方標示不建議用於測試〔官方〕。
- 手動啟動 Blazor 的情境可串接 `Blazor.start()` 回傳的 Promise；增強式導覽後的頁面更新可監聽 `enhancedload` 事件〔官方〕。

來源：<https://learn.microsoft.com/aspnet/core/blazor/components/render-modes?view=aspnetcore-10.0>、<https://learn.microsoft.com/aspnet/core/blazor/test?view=aspnetcore-10.0>、<https://playwright.dev/dotnet/docs/test-assertions>、<https://learn.microsoft.com/aspnet/core/blazor/fundamentals/startup?view=aspnetcore-10.0>、<https://learn.microsoft.com/aspnet/core/blazor/fundamentals/navigation?view=aspnetcore-10.0>。
