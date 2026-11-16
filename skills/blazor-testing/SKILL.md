---
name: blazor-testing
description: 'Use when 撰寫或修改 Blazor 的 bUnit 元件測試（搭配 NUnit、MudBlazor），或 Blazor Hybrid（WPF 與 WinForms 的 BlazorWebView）與 Blazor Web App 的可重跑 e2e 測試（FlaUI、Playwright）時。'
audience: agent
policy.allow_implicit_invocation: true
---

# Blazor 測試

本 skill 供撰寫 Blazor 測試時載入，涵蓋 bUnit 元件測試、Blazor Hybrid 的 e2e 測試，以及 Blazor Web App e2e 的等待重點。Blazor Hybrid 以 FlaUI 為主要工具，Playwright 為輔助工具。依任務只讀對應章節即可。

## 適用範圍與工具選擇

| 測試目標 | 工具 | 章節 |
| --- | --- | --- |
| 元件邏輯與渲染結果，不經過 WebView2 | bUnit | `## bUnit 元件測試` |
| 原生外殼加 Blazor 內容：啟動、導覽、原生對話框、選單、關閉流程 | FlaUI | `## Blazor Hybrid e2e（FlaUI）` |
| 需要 CSS 選擇器、DOM 細節、JS 狀態或網路攔截，且不需操作原生外殼 | Playwright（CDP 連線 WebView2） | `## Blazor Hybrid e2e（Playwright）` |
| Blazor Web App 的瀏覽器測試 | Playwright | `## Blazor Web App e2e 簡述` |
| 一次性煙霧驗證，不留下可重跑的測試 | 依 `desktop-smoke` 或 `browser-smoke` | 該 skill |

範圍外的主題如下：

- 非 Blazor 的 FlaUI（純 WinForms、WPF 控制項）與一般網站 Playwright 的通用寫法。
- 截圖的時機、命名、落點與操作手冊規則。
- MAUI Blazor Hybrid。
- BlazorWebView 重建、釋放卡住、`TryDispatchAsync` 等待上限等應用程式本身的實作。

來源專案的外殼皆為 WPF，WinForms 外殼的 UIA 行為未經來源驗證〔推論〕。

## 來源標注

正文句末以下列標籤標明依據。同一句有多個標籤時，表示多個來源都支持該句。

| 標籤 | 意義 |
| --- | --- |
| 〔官方〕 | 官方文件載明，附近附該頁 URL |
| 〔SE〕 | SchemaExporter 專案實作所得（WPF 加 BlazorWebView 加 MudBlazor，.NET 10，bunit 2.13.3、NUnit 4.5.1、FlaUI.UIA3 5.0.0） |
| 〔AAM〕 | AiAccountManager 專案實作所得（WPF 加 Microsoft.AspNetCore.Components.WebView.Wpf 10.0.110 加 Microsoft.Web.WebView2 1.0.4258.31 加 MudBlazor 9.11.0，bunit 2.13.3、NUnit 5.0.0、FlaUI 5.0.0，TFM `net10.0-windows10.0.19041.0`） |
| 〔推論〕 | 由上述來源推得，尚未以探針或測試證實 |
| 〔待探針〕 | 需先以探針在目標專案確認後才可依賴 |
| 〔建議〕 | 本 skill 依來源歸納的作法建議，非來源原文 |

## bUnit 元件測試

撰寫 bUnit 元件測試（NUnit、MudBlazor）時讀 `references/bunit.md`，內容含 bUnit 2.x 的 API 對照、`BunitContext` 測試基底、MudBlazor 設定、DI 替身策略、元素查詢約定與非同步等待易錯點。

## Blazor Hybrid e2e（FlaUI）

撰寫 WPF 或 WinForms BlazorWebView 的 FlaUI e2e 測試時讀 `references/hybrid-flaui.md`，內容含測試專案結構、受測程式的啟動與就緒、UIA 查詢與操作、關閉與清理，以及 `DesktopAppSession` 工作階段範例。

## Blazor Hybrid e2e（Playwright）

以 Playwright 透過 CDP 連線 WebView2 時讀 `references/hybrid-playwright.md`，內容含遠端偵錯設定、連線與重試範例。

## Blazor Hybrid 專屬陷阱

本表的 TFM 與 composition 陷阱限於 WPF BlazorWebView，WinForms 外殼未經來源驗證〔推論〕。

| 陷阱 | 症狀 | 判斷方式 | 來源 |
| --- | --- | --- | --- |
| WPF BlazorWebView 的 TFM 缺 Windows SDK 版本 | 建置與 bUnit 皆通過，程式啟動時因 `FileNotFoundException` 崩潰 | 只有真正啟動 exe 的測試抓得到。.NET 10 的 WPF BlazorWebView 內部改用 `WebView2CompositionControl`，TFM 要帶 Windows SDK 版本（`net10.0-windows10.0.17763.0` 以上），測試專案 TFM 與 exe 路徑中的 TFM 資料夾要跟著改 | 〔官方〕〔SE〕 |
| bUnit 不經過 WebView2 | 元件測試全過，Hybrid 畫面卻不正常 | 元件測試不代表外殼正常，至少保留一個啟動 exe 並導覽一頁的 FlaUI 測試 | 〔AAM〕 |
| UIA 找得到元素不代表畫面有畫出來 | composition 版白屏時，程序與 DOM 都還在 | 擷取主視窗影像並取樣多個像素點，顏色種類低於專案設定的門檻（例如全為同一底色）判為未繪製；或以 app 內事件記錄判定。不以 UIA 查得到元素作為畫面已繪製的證據 | 〔AAM〕 |
| 含逾時與重試的流程難以測試 | 單元測試需要等待真實時間 | 把時間抽成可注入的 `TimeProvider`，測試以可手動推進的替身驅動（SE 自行實作 `ManualTimeProvider`）。新增接縫前先依 `csharp-nunit`「測試接縫需先議定」 | 〔SE〕 |

TFM 的官方依據：<https://learn.microsoft.com/aspnet/core/blazor/hybrid/tutorials/wpf?view=aspnetcore-10.0>。

## Blazor Web App e2e 簡述

以 Playwright 測試 Blazor Web App（Server 與 WebAssembly）時讀 `references/hybrid-playwright.md` 的 `## Blazor Web App e2e 簡述`，內容含互動就緒的等待重點。

## 與使用者同時使用電腦

測試期間使用者同時使用電腦，或需要真實輸入（FlaUI）、PrintWindow 截圖與完全隔離環境時，讀 `references/no-interference.md`，內容含干擾對照表、受測程式的測試模式、`RealInputScope` 與篩選指令。操作元素的預設階梯如下。

操作一個元素時依下列階梯選用，前一階可行即停止。

1. 使用 UIA pattern（Invoke、ExpandCollapse、Toggle、SelectionItem、Value），元素本身不支援時找其父元素或子元素〔SE〕〔AAM〕。
2. 改用 CDP，條件為需求屬 `## Blazor Hybrid e2e（Playwright）` 的適用範圍且不需操作原生外殼〔推論〕。
3. 前兩階皆不可行，或被測行為本身是真實輸入時，才進入 `references/no-interference.md` 的 `## 必要例外：RealInput`。

## 環境限制

- Blazor Hybrid 的 e2e 需要互動桌面 session 與 WebView2 Runtime，無頭環境與 Codex AppContainer 沙箱跑不起來〔SE〕。
- bUnit 不受此限制，可在一般 `dotnet test` 執行。

## 待確認項目

標有〔待探針〕的內容，其目前處置與確認方式列於 `references/pending-probes.md`，依賴前先讀。
