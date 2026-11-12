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

測試命名、AAA 與斷言規則依 `csharp-nunit`，本章不重述。範例的私有欄位前綴依專案 `csharp-style` 註記調整。

範例的測試專案使用 `Microsoft.NET.Sdk.Razor`、TFM `net10.0` 並啟用 ImplicitUsings，套件為 `bunit`、`MudBlazor`、`NUnit`、`NUnit3TestAdapter`、`Microsoft.NET.Test.Sdk`、`NSubstitute`；範例以 bunit 2.13.3、MudBlazor 9.11.0、NUnit 4.5.1 建置並通過。

### 套件與 API（bUnit 2.x）

bUnit 2.x 只有單一套件 `bunit`，測試環境型別為 `BunitContext`，渲染統一使用 `Render<T>`，`BunitContext` 同時實作 `IAsyncDisposable`〔官方〕。bUnit 可搭配 NUnit、MSTest 與 xUnit〔官方〕。來源：<https://bunit.dev/docs/migrations/1to2.html>、<https://learn.microsoft.com/aspnet/core/blazor/test?view=aspnetcore-10.0>。

| 1.x 名稱 | 2.x 名稱 |
| --- | --- |
| `bunit.core`、`bunit.web` 套件 | `bunit` 套件 |
| `TestContext` | `BunitContext` |
| `RenderComponent<T>`、`SetParametersAndRender` | `Render<T>` |
| `DisposeComponents()` | `DisposeComponentsAsync()` |

### 測試基底

- 建立每個測試獨立的 `BunitContext`：在 `[SetUp]` 建立，在 `[TearDown]` 以 `await DisposeAsync()` 釋放〔AAM〕〔SE〕。
- 釋放一律走非同步路徑。MudBlazor 有些服務只實作 `IAsyncDisposable`，同步 `Dispose` 會拋例外〔SE〕。
- 設定 `JSInterop.Mode = JSRuntimeMode.Loose` 的時機為元件測試只驗證 Blazor 端行為、JS interop 呼叫不是斷言對象時〔AAM〕〔SE〕。需要斷言特定 JS 呼叫時保留預設的 Strict，並設定預期呼叫〔官方〕。來源：<https://bunit.dev/docs/test-doubles/emulating-ijsruntime.html>。

完整檔案：ComponentTestBase.cs

```csharp
using Bunit;
using Microsoft.Extensions.DependencyInjection;
using MudBlazor;
using MudBlazor.Services;
using NUnit.Framework;

namespace MyApp.Components.Tests;

/// <summary>
/// 為每個測試建立獨立的 bUnit 環境，並註冊 MudBlazor 所需服務。
/// </summary>
public abstract class ComponentTestBase {
    private BunitContext? context;

    protected BunitContext Context => context ?? throw new InvalidOperationException("bUnit 環境尚未建立。");

    [SetUp]
    public void SetUpContext() {
        context = new BunitContext();
        // MudBlazor 元件會呼叫多個 JS interop；元件測試只驗證 Blazor 端行為，因此採寬鬆模式。
        context.JSInterop.Mode = JSRuntimeMode.Loose;
        context.Services.AddMudServices(options => {
            // 測試只渲染受測元件，不渲染 MainLayout 中的 MudPopoverProvider。
            options.PopoverOptions.CheckForPopoverProvider = false;
        });
    }

    [TearDown]
    public async Task TearDownContextAsync() {
        if (context is not null) {
            // MudBlazor 部分服務只實作 IAsyncDisposable，必須非同步釋放。
            await context.DisposeAsync();
            context = null;
        }
    }

    protected IRenderedComponent<MudDialogProvider> RenderDialogProvider() {
        Context.Render<MudPopoverProvider>();
        return Context.Render<MudDialogProvider>();
    }
}
```

### MudBlazor 設定

- 註冊 `AddMudServices`，並設定 `PopoverOptions.CheckForPopoverProvider = false`〔AAM〕。
- 渲染對話框前先 `Render<MudPopoverProvider>()` 再 `Render<MudDialogProvider>()`。內嵌對話框的內容出現在 `MudDialogProvider` 的渲染結果中，查詢要對 provider 做〔AAM〕。

上述設定在 MudBlazor 9.11.0 驗證，MudBlazor 主版本升級時 API 可能變動。

### DI 替身策略

- 註冊 State 類別的真實作，外部依賴（檔案系統、對話框服務、資料庫、更新服務等）換成 NSubstitute 替身或暫存目錄〔SE〕。
- 新增測試接縫前依 `csharp-nunit`「測試接縫需先議定」。

片段：

```csharp
ISettingsStore store = Substitute.For<ISettingsStore>();
Context.Services.AddSingleton(store);
Context.Services.AddSingleton(new ExportState(store));
```

### 元素查詢

以使用者看得到的文字或 `aria-label` 查詢元素，不綁定元件庫內部的 CSS 類別，元件庫改版時測試才不會跟著壞〔AAM〕。

完整檔案：ElementQueries.cs

```csharp
using AngleSharp.Dom;
using Bunit;
using Microsoft.AspNetCore.Components;

namespace MyApp.Components.Tests;

/// <summary>
/// 以使用者看得到的文字或無障礙名稱尋找元素。
/// </summary>
internal static class ElementQueries {
    public static IElement FindButton<TComponent>(this IRenderedComponent<TComponent> cut, string text)
        where TComponent : IComponent {
        IElement[] matches = cut.FindAll("button")
            .Where(button => string.Equals(button.TextContent.Trim(), text, StringComparison.Ordinal))
            .ToArray();
        return matches.Length == 1
            ? matches[0]
            : throw new InvalidOperationException($"預期找到 1 個文字為「{text}」的按鈕，實際找到 {matches.Length} 個。");
    }

    public static bool HasButton<TComponent>(this IRenderedComponent<TComponent> cut, string text)
        where TComponent : IComponent {
        return cut.FindAll("button").Any(button => string.Equals(button.TextContent.Trim(), text, StringComparison.Ordinal));
    }

    public static IElement FindByLabel<TComponent>(this IRenderedComponent<TComponent> cut, string label)
        where TComponent : IComponent {
        return cut.FindAll("[aria-label]")
            .Single(element => string.Equals(element.GetAttribute("aria-label"), label, StringComparison.Ordinal));
    }

    public static bool IsDisabled(this IElement element) => element.HasAttribute("disabled");
}
```

### 對話框測試範例

受測元件為以 `Visible` 控制的 MudBlazor 內嵌對話框。

完整檔案：ConfirmDialog.razor

```razor
@using MudBlazor

<MudDialog Visible="@Visible" VisibleChanged="VisibleChanged">
    <TitleContent><MudText Typo="Typo.h6">確認刪除</MudText></TitleContent>
    <DialogContent><MudText>刪除後無法復原。</MudText></DialogContent>
    <DialogActions>
        <MudButton Color="Color.Error" OnClick="ConfirmAsync">確認</MudButton>
        <MudButton OnClick="CancelAsync">取消</MudButton>
    </DialogActions>
</MudDialog>

@code {
    [Parameter]
    public bool Visible { get; set; }

    [Parameter]
    public EventCallback<bool> VisibleChanged { get; set; }

    [Parameter]
    public EventCallback OnConfirm { get; set; }

    [Parameter]
    public EventCallback OnCancel { get; set; }

    private async Task ConfirmAsync() {
        await OnConfirm.InvokeAsync();
    }

    private async Task CancelAsync() {
        await OnCancel.InvokeAsync();
        await VisibleChanged.InvokeAsync(false);
    }
}
```

完整檔案：ConfirmDialogTests.cs

```csharp
using Bunit;
using MudBlazor;
using NUnit.Framework;

namespace MyApp.Components.Tests;

[TestFixture]
public sealed class ConfirmDialogTests : ComponentTestBase {
    [Test]
    public void Confirm_WhenClicked_InvokesOnConfirm() {
        int confirmCount = 0;
        IRenderedComponent<MudDialogProvider> provider = RenderDialogProvider();
        Context.Render<ConfirmDialog>(parameters => parameters
            .Add(p => p.Visible, true)
            .Add(p => p.OnConfirm, () => confirmCount++));
        provider.WaitForState(() => provider.HasButton("確認"));

        provider.FindButton("確認").Click();

        Assert.That(confirmCount, Is.EqualTo(1));
    }

    [Test]
    public void Cancel_WhenClicked_InvokesOnCancelAndHidesDialog() {
        int cancelCount = 0;
        List<bool> visibleChanges = [];
        IRenderedComponent<MudDialogProvider> provider = RenderDialogProvider();
        Context.Render<ConfirmDialog>(parameters => parameters
            .Add(p => p.Visible, true)
            .Add(p => p.OnCancel, () => cancelCount++)
            .Add(p => p.VisibleChanged, visible => visibleChanges.Add(visible)));
        provider.WaitForState(() => provider.HasButton("取消"));

        provider.FindButton("取消").Click();

        using (Assert.EnterMultipleScope()) {
            Assert.That(cancelCount, Is.EqualTo(1));
            Assert.That(visibleChanges, Is.EqualTo(new[] { false }));
        }
    }
}
```

## bUnit 非同步等待與易錯點

1. 採用 `WaitForState` 加單次 Assert。`WaitForState` 在呼叫時與每次元件渲染時檢查述詞，預設逾時 1 秒，逾時拋 `WaitForFailedException`〔官方〕。慢狀態傳入較長的 `TimeSpan`，SE 使用 10 秒〔SE〕。`WaitForAssertion` 會重跑斷言直到不拋例外〔官方〕，但在 NUnit 4 下，重試過程中失敗的 `Assert.That` 會被 NUnit 記錄，最後即使通過，測試仍判失敗〔SE〕；AAM 在 NUnit 5.0.0 下使用 `WaitForAssertion` 的測試通過〔AAM〕。版本差異列於 `## 待確認項目`。來源：<https://bunit.dev/docs/interaction/awaiting-async-state.html>、<https://bunit.dev/docs/verification/async-assertion.html>。
2. 選最後才成立的訊號作為等待條件〔SE〕。例如匯出完成時，進度訊息也含「匯出結果」字樣，等文字會在中間狀態誤判完成；改等主要按鈕重新變成可按。

    ```csharp
    cut.WaitForState(() => !cut.FindButton("開始匯出").IsDisabled(), TimeSpan.FromSeconds(10));
    Assert.That(cut.Markup, Does.Contain("匯出結果"));
    ```

3. 等到明確階段再查詢並觸發〔SE〕。元件可能在找到元素之後、點擊之前重新渲染，點到已被替換的元素。以替身讓外部依賴停在目標階段，述詞同時要求按鈕可用與階段文字出現，之後才 `Find` 與 `Click`。

    ```csharp
    loader.LoadAsync(Arg.Any<CancellationToken>())
        .Returns(call => Task.Delay(Timeout.Infinite, call.Arg<CancellationToken>()));
    cut.FindButton("開始匯出").Click();
    cut.WaitForState(() => cut.Markup.Contains("從資料庫載入") && !cut.FindButton("取消").IsDisabled());
    cut.FindButton("取消").Click();
    ```

## Blazor Hybrid e2e（FlaUI）

FlaUI 透過 UI Automation（UIA3）操作外殼與 WebView2 內容。正常狀態下 WebView2 內的 Blazor 元素會出現在 UIA 樹，以 Name 加 ControlType 可找到 MudBlazor 的 Button、Hyperlink、MenuItem，`ControlType.Document` 的 Name 為頁面標題〔AAM〕〔SE〕。

### 測試專案結構

- 建立獨立的 UI 測試專案，與 bUnit 專案分開〔SE〕〔AAM〕。SE 命名為 `<專案>.Desktop.UITests`，AAM 命名為 `<專案>.UiTests`。
- 標註測試類別：`[Category]`（以常數類別集中名稱）、`[NonParallelizable]`、`[Platform(Include = "Win")]`〔SE〕〔AAM〕。
- 決定是否加 `[Explicit]`，兩種作法並列如下。

| 作法 | 一般 `dotnet test` | 指定或排除 | 來源 |
| --- | --- | --- | --- |
| 加 `[Explicit]` | 不執行 | `--filter "TestCategory=<名稱>"` 指定執行 | 〔SE〕 |
| 不加 `[Explicit]` | 執行；缺受測 exe 或已有執行中的實例時以 `Assert.Ignore` 略過 | `--filter "TestCategory!=<名稱>"` 排除 | 〔AAM〕 |

無互動桌面的 CI 要預設排除時，兩種作法皆可。`Assert.Ignore` 讓環境不具備時略過而非失敗，CI 若需強制執行，要另外檢查略過數〔建議〕。

csproj 片段：以 `AssemblyMetadata` 傳入受測 exe 路徑，測試可再用環境變數覆寫；`ProjectReference` 加 `ReferenceOutputAssembly="false"`，確保受測專案先建置但不載入其組件〔AAM〕〔SE〕。路徑中的 RID 資料夾依受測專案實際輸出調整。

```xml
<PropertyGroup>
  <TargetFramework>net10.0-windows10.0.19041.0</TargetFramework>
  <DesktopExecutablePath>$([System.IO.Path]::GetFullPath('$(MSBuildThisFileDirectory)..\..\src\MyApp.Desktop\bin\$(Configuration)\$(TargetFramework)\win-x64\MyApp.Desktop.exe'))</DesktopExecutablePath>
</PropertyGroup>

<ItemGroup>
  <AssemblyMetadata Include="DesktopExecutablePath" Value="$(DesktopExecutablePath)" />
</ItemGroup>

<ItemGroup>
  <ProjectReference Include="..\..\src\MyApp.Desktop\MyApp.Desktop.csproj"
                    ReferenceOutputAssembly="false"
                    Private="false" />
</ItemGroup>
```

UI 測試專案啟用 ImplicitUsings，套件為 `FlaUI.Core`、`FlaUI.UIA3`、`NUnit`、`NUnit3TestAdapter`、`Microsoft.NET.Test.Sdk`；Playwright 範例另加 `Microsoft.Playwright`，截圖範例另加 `System.Drawing.Common`。本章與 `## 與使用者同時使用電腦` 的範例以 FlaUI 5.0.0、Microsoft.Playwright 1.64.1、System.Drawing.Common 10.0.2 建置。

路徑以 `$(TargetFramework)` 組成，受測專案與測試專案的 TFM 必須一致。路徑寫死 TFM 時，TFM 變更後路徑失效，見 `## Blazor Hybrid 專屬陷阱`。

### 受測程式的啟動與就緒

- 隔離資料：以啟動引數把資料目錄導向暫存目錄（引數名稱由受測程式自訂，AAM 為 `--data-root`）〔AAM〕，或把 `LOCALAPPDATA` 環境變數改成暫存目錄〔SE〕，避免動到使用者的真實設定。
- 設定 `WorkingDirectory`：AAM 設為 exe 所在目錄〔AAM〕，SE 設為暫存目錄〔SE〕，兩者的測試皆通過。取捨條件列於 `## 待確認項目`。
- 檢查單一執行個體：受測程式只允許單一實例時，測試前以 `Process.GetProcessesByName` 檢查同名程序，存在時略過並提示，否則新程序只會喚醒舊視窗後結束〔AAM〕。
- 等待就緒訊號。視窗出現早於 Blazor 渲染，只等主視窗會在空白頁上操作。就緒訊號分兩層〔AAM〕：
  - 受測程式提供 marker 契約：接受一個 marker 路徑引數（AAM 為 `--startup-render-probe`），只在該引數存在時，於根元件首次 `OnAfterRenderAsync(firstRender: true)` 後寫出 marker 檔，寫入方式為先寫暫存檔再移動。正式啟動不帶此引數，沒有這個行為。測試側等 marker 檔出現，或程序提前結束時判定失敗。
  - 頁面就緒以 `ControlType.Document` 的 Name 等於 PageTitle 判定。`index.html` 的預設標題與視窗標題相同時，Name 等於視窗標題不算就緒。

### UIA 查詢與操作

- 查詢一律帶等待與重試：`Retry.WhileNull`（`ignoreException: true`），以 Name 加 `ControlType` 比對〔AAM〕〔SE〕。`aria-label` 會成為 UIA 的 Name〔SE〕。`Retry.*` 回傳 `RetryResult<T>`，其 `.Result` 是結果屬性，不是 `Task.Result`。
- 查詢以 Name 加 `ControlType` 為主。HTML `id` 是否對應成 UIA AutomationId 只有社群報告，沒有官方文件〔待探針〕，需要用 AutomationId 時先以探針確認，見 `## 待確認項目`。
- 操作一律用 UIA pattern：一般按鈕與連結用 `Patterns.Invoke`；MudMenu 的觸發鈕只支援 `ExpandCollapse`，以 `Patterns.ExpandCollapse.Pattern.Expand()` 展開，選單項目再以 `AsMenuItem().Invoke()` 觸發〔SE〕。
- 避免真實輸入：`Click()`、`Keyboard`、`Mouse` 會移動真實滑鼠與鍵盤，視窗不在前景時會點到其他程式，SE 曾因此點到使用者正在使用的其他程式〔SE〕。AAM 的 `Activate` 在元素沒有 Invoke 時退回 `Click()`〔AAM〕，本 skill 的 `Activate` 不退回，無 Invoke 時拋例外。元素沒有可用 pattern 時依 `## 與使用者同時使用電腦` 的三階梯處理。
- 原生對話框（MessageBox、資料夾選擇）以 `MainWindow.ModalWindows` 取得，等待時同樣用 `Retry`，關閉用 `dialog.Close()`〔SE〕。

片段：

```csharp
session.WaitForElement("切換主題", ControlType.Button).Patterns.ExpandCollapse.Pattern.Expand();
session.WaitForElement("深色", ControlType.MenuItem).AsMenuItem().Invoke();

Window dialog = Retry.WhileNull(
    () => session.MainWindow.ModalWindows.FirstOrDefault(),
    TimeSpan.FromSeconds(30),
    TimeSpan.FromMilliseconds(250)
).Result ?? throw new AssertionException("原生對話框未在時限內出現。");
dialog.Close();
```

### 關閉與清理

- 關閉程序：關閉前先記下 `ProcessId`（程序結束後再讀會拋例外），`MainWindow.Close()` 後等 `HasExited`，逾時才以 `Kill(entireProcessTree: true)` 結束整個程序樹〔SE〕〔AAM〕。
- 釋放資源：程序結束後釋放 `Application` 與 `UIA3Automation`。
- 判定正常關閉以 `HasExited` 加等待為準，不讀 `Application.ExitCode`，原因見 `## 待確認項目`。
- 重試刪除暫存目錄：WebView2 子程序可能在主程序結束後短暫持有檔案，刪除失敗時間隔 500 毫秒重試，最多 10 次〔AAM〕。

### FlaUI 工作階段範例

完整檔案：UiTestCategory.cs

```csharp
namespace MyApp.UiTests;

/// <summary>
/// UI 測試分類；需要互動式 Windows 桌面與 WebView2 Runtime。
/// </summary>
public static class UiTestCategory {
    public const string Name = "UI";
    public const string RealInput = "RealInput";
}
```

完整檔案：DesktopAppSession.cs

```csharp
using System.Diagnostics;
using System.Reflection;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Tools;
using FlaUI.UIA3;
using NUnit.Framework;

namespace MyApp.UiTests;

/// <summary>
/// 以隔離的資料目錄啟動桌面程式，等待 Blazor 介面就緒，並提供 FlaUI 操作入口。
/// </summary>
public sealed class DesktopAppSession : IDisposable {
    public const string WindowTitle = "MyApp";
    public const string ExecutablePathVariable = "MYAPP_DESKTOP_EXE";

    private const string ProcessName = "MyApp.Desktop";
    private static readonly TimeSpan StartupTimeout = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan ElementTimeout = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan ShutdownTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(250);

    private readonly string workingRoot;
    private readonly int processId;
    private bool disposed;

    private DesktopAppSession(string workingRoot, Application application, UIA3Automation automation, Window mainWindow) {
        this.workingRoot = workingRoot;
        Application = application;
        Automation = automation;
        MainWindow = mainWindow;
        processId = application.ProcessId;
    }

    public Application Application { get; }

    public UIA3Automation Automation { get; }

    public Window MainWindow { get; }

    public string DataRoot => Path.Combine(workingRoot, "data");

    public static DesktopAppSession Launch() {
        string executablePath = ResolveExecutablePath();
        if (!File.Exists(executablePath)) {
            Assert.Ignore($"找不到受測執行檔：{executablePath}。請先建置方案，或以環境變數 {ExecutablePathVariable} 指定路徑。");
        }

        // 單一執行個體程式在已有實例時只會喚醒舊視窗後結束，測試無法進行。
        if (Process.GetProcessesByName(ProcessName).Length > 0) {
            Assert.Ignore("偵測到受測程式正在執行，請先結束它再執行 UI 測試。");
        }

        string workingRoot = Path.Combine(Path.GetTempPath(), "MyApp.UiTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(workingRoot);
        string markerPath = Path.Combine(workingRoot, "startup-render.json");

        ProcessStartInfo startInfo = new(executablePath) {
            WorkingDirectory = Path.GetDirectoryName(executablePath)!,
            UseShellExecute = false
        };
        startInfo.ArgumentList.Add("--data-root");
        startInfo.ArgumentList.Add(Path.Combine(workingRoot, "data"));
        startInfo.ArgumentList.Add("--startup-render-probe");
        startInfo.ArgumentList.Add(markerPath);

        Application application = Application.Launch(startInfo);
        UIA3Automation automation = new();
        try {
            bool rendered = Retry.WhileFalse(
                () => File.Exists(markerPath) || application.HasExited,
                StartupTimeout,
                PollInterval
            ).Result;
            if (application.HasExited) {
                Assert.Fail("受測程式在介面就緒前結束。");
            }

            if (!rendered || !File.Exists(markerPath)) {
                Assert.Fail($"等待 {StartupTimeout.TotalSeconds:0} 秒後 Blazor 介面仍未完成第一次渲染。");
            }

            Window mainWindow = application.GetMainWindow(automation, StartupTimeout)
                ?? throw new InvalidOperationException("找不到受測程式的主視窗。");
            return new DesktopAppSession(workingRoot, application, automation, mainWindow);
        } catch {
            // 啟動已失敗，不等正常關閉，直接結束程序樹。
            StopProcessTree(application.ProcessId, TimeSpan.Zero);
            application.Dispose();
            automation.Dispose();
            TryDeleteDirectory(workingRoot);
            throw;
        }
    }

    public AutomationElement WaitForElement(string name, ControlType controlType, TimeSpan? timeout = null) {
        TimeSpan wait = timeout ?? ElementTimeout;
        AutomationElement? element = Retry.WhileNull(
            () => MainWindow.FindFirstDescendant(cf => cf.ByName(name).And(cf.ByControlType(controlType))),
            wait,
            PollInterval,
            ignoreException: true
        ).Result;
        return element ?? throw new AssertionException($"等待 {wait.TotalSeconds:0} 秒後仍找不到 {controlType}「{name}」。");
    }

    public void WaitForPageTitle(string title) {
        string? lastTitle = null;
        bool matched = Retry.WhileFalse(
            () => {
                lastTitle = MainWindow.FindFirstDescendant(cf => cf.ByControlType(ControlType.Document))?.Name;
                return string.Equals(lastTitle, title, StringComparison.Ordinal);
            },
            ElementTimeout,
            PollInterval,
            ignoreException: true
        ).Result;
        if (!matched) {
            throw new AssertionException($"頁面標題預期為「{title}」，實際為「{lastTitle ?? "(找不到文件元素)"}」。");
        }
    }

    public static void Activate(AutomationElement element) {
        if (!element.Patterns.Invoke.TryGetPattern(out var invoke)) {
            throw new InvalidOperationException($"元素「{element.Name}」不支援 Invoke pattern，請改用該元素支援的 pattern。");
        }

        invoke.Invoke();
    }

    public bool CloseAndWaitForExit() {
        if (Application.HasExited) {
            return true;
        }

        MainWindow.Close();
        return Retry.WhileFalse(() => Application.HasExited, ShutdownTimeout, PollInterval).Result;
    }

    public void Dispose() {
        if (disposed) {
            return;
        }

        disposed = true;
        try {
            if (!CloseAndWaitForExit()) {
                StopProcessTree(processId, TimeSpan.Zero);
            }
        } catch {
            StopProcessTree(processId, ShutdownTimeout);
        } finally {
            Application.Dispose();
            Automation.Dispose();
            TryDeleteDirectory(workingRoot);
        }
    }

    private static string ResolveExecutablePath() {
        string? overridePath = Environment.GetEnvironmentVariable(ExecutablePathVariable);
        if (!string.IsNullOrWhiteSpace(overridePath)) {
            return Path.GetFullPath(overridePath);
        }

        string? builtPath = typeof(DesktopAppSession).Assembly
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(attribute => attribute.Key == "DesktopExecutablePath")?.Value;
        return builtPath ?? throw new InvalidOperationException("測試組件缺少 DesktopExecutablePath 中繼資料。");
    }

    private static void StopProcessTree(int processId, TimeSpan wait) {
        try {
            using Process process = Process.GetProcessById(processId);
            if (!process.WaitForExit(wait)) {
                process.Kill(entireProcessTree: true);
            }
        } catch (ArgumentException) {
            // 程序已結束。
        } catch (InvalidOperationException) {
            // 程序已結束。
        }
    }

    private static void TryDeleteDirectory(string path) {
        // WebView2 子程序可能在主程序結束後短暫持有檔案，稍候重試。
        for (int attempt = 0; attempt < 10 && Directory.Exists(path); attempt++) {
            try {
                Directory.Delete(path, recursive: true);
            } catch (IOException) {
                Thread.Sleep(500);
            } catch (UnauthorizedAccessException) {
                Thread.Sleep(500);
            }
        }
    }
}
```

`[OneTimeSetUp]` 共用一次啟動以降低啟動成本〔AAM〕，`[SetUp]` 每個測試啟動以隔離狀態〔SE〕，依測試之間是否共用狀態選擇。

完整檔案：NavigationTests.cs

```csharp
using FlaUI.Core.Definitions;
using NUnit.Framework;

namespace MyApp.UiTests;

[TestFixture]
[Category(UiTestCategory.Name)]
[NonParallelizable]
[Platform(Include = "Win")]
public sealed class NavigationTests {
    private DesktopAppSession? session;

    private DesktopAppSession Session => session ?? throw new InvalidOperationException("受測程式尚未啟動。");

    [OneTimeSetUp]
    public void LaunchApplication() {
        session = DesktopAppSession.Launch();
    }

    [OneTimeTearDown]
    public void CloseApplication() {
        session?.Dispose();
        session = null;
    }

    [TestCase("設定", "設定")]
    public void NavMenu_WhenLinkActivated_OpensPage(string linkName, string expectedTitle) {
        DesktopAppSession.Activate(Session.WaitForElement(linkName, ControlType.Hyperlink));

        Session.WaitForPageTitle(expectedTitle);
    }
}
```

完整檔案：LifecycleTests.cs

```csharp
using NUnit.Framework;

namespace MyApp.UiTests;

[TestFixture]
[Category(UiTestCategory.Name)]
[NonParallelizable]
[Platform(Include = "Win")]
public sealed class LifecycleTests {
    [Test]
    public void CloseMainWindow_WhenRequested_ExitsWithinTimeout() {
        using DesktopAppSession session = DesktopAppSession.Launch();

        bool exited = session.CloseAndWaitForExit();

        Assert.That(exited, Is.True);
    }
}
```

## Blazor Hybrid e2e（Playwright）

需要 CSS 選擇器、DOM 細節、JS 狀態或網路攔截，且不需操作原生外殼時，改用 Playwright 透過 Chrome DevTools Protocol（CDP）連線 WebView2。其餘情況用 FlaUI。

- 開啟遠端偵錯：啟動前設定環境變數 `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=<port>`，或以 `CoreWebView2EnvironmentOptions.AdditionalBrowserArguments` 設定〔官方〕。
- 連線：以 `ConnectOverCDPAsync` 連線後取 `Contexts[0].Pages[0]`〔官方〕。
- 隔離平行執行：WebView2 預設所有執行個體共用同一個使用者資料目錄，每次執行要使用不同的 port 與 `WEBVIEW2_USER_DATA_FOLDER`〔官方〕。port 由專案自行取得，例如以 `TcpListener` 綁定 port 0 取得空閒 port〔建議〕。
- 支援範圍：官方頁面只寫 WebView2 適用 Windows 10 與 Windows 11，未列 WebView2 Runtime 或 Playwright 的最低版本〔官方〕。
- 連線時機：官方範例在程序內以 `CoreWebView2InitializationCompleted` 確認初始化完成〔官方〕。外部啟動的 exe 沒有這個事件，改等 FlaUI 章節的就緒 marker 後再連線，`Pages` 為空時重試〔建議〕。
- 限制遠端偵錯 port 只在測試啟動時開啟，不進入正式發行設定〔建議〕。
- 截圖範圍：Playwright 的 page screenshot 只含 WebView2 網頁區域，不含原生外殼〔推論〕。

來源：<https://playwright.dev/dotnet/docs/webview2>、<https://learn.microsoft.com/en-us/microsoft-edge/webview2/how-to/playwright>。

完整檔案：WebView2PlaywrightTests.cs

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

    [TearDown]
    public async Task CloseAsync() {
        if (browser is not null) {
            await browser.CloseAsync();
        }

        playwright?.Dispose();
        if (process is not null && !process.HasExited) {
            // 先要求正常關閉，逾時才結束整個程序樹。
            process.CloseMainWindow();
            if (!process.WaitForExit(TimeSpan.FromSeconds(10))) {
                process.Kill(entireProcessTree: true);
                await process.WaitForExitAsync();
            }
        }

        process?.Dispose();
        if (userDataFolder is not null) {
            await DeleteDirectoryWithRetryAsync(userDataFolder);
        }
    }

    [Test]
    public async Task SettingsLink_WhenClicked_ShowsSettingsHeadingAsync() {
        IPage page = await GetPageAsync();

        await page.GetByRole(AriaRole.Link, new() { Name = "設定" }).ClickAsync();

        await Expect(page.GetByRole(AriaRole.Heading, new() { Name = "設定" })).ToBeVisibleAsync();
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

    private static int GetFreePort() {
        TcpListener listener = new(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    private static async Task DeleteDirectoryWithRetryAsync(string path) {
        // WebView2 在關閉時延遲清理使用者資料目錄，刪除失敗時稍候重試。
        for (int attempt = 0; attempt < 10 && Directory.Exists(path); attempt++) {
            try {
                Directory.Delete(path, recursive: true);
            } catch (IOException) {
                await Task.Delay(500);
            } catch (UnauthorizedAccessException) {
                await Task.Delay(500);
            }
        }
    }
}
```

範例在受測程式啟動後輪詢 CDP 端點直到可連線，正式專案建議先等 FlaUI 章節的就緒 marker〔建議〕。

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

- 以一般 Playwright 對瀏覽器測試 Blazor Web App（Server 與 WebAssembly）。E2E 驗證前必須確認環境已達預期狀態〔官方〕。
- 等待互動就緒。互動式 render mode 預設先預先渲染，`RendererInfo.IsInteractive` 在預先渲染與靜態 SSR 時為 `false`，靜態 SSR 下 Blazor 事件處理不運作，在預先渲染的靜態 HTML 上操作會讓事件不觸發〔官方〕。
- 選用等待訊號：官方範例以 `disabled="@(!RendererInfo.IsInteractive)"` 讓按鈕在互動就緒前停用〔官方〕。測試以 Playwright 網頁優先斷言（例如 `ToBeEnabledAsync`）等待該訊號，斷言會自動重試，預設逾時 5 秒，WebAssembly 首次載入較慢時調高逾時〔官方〕。app 沒有這類訊號時，由 app 暴露一個互動後才出現的元素或屬性〔建議〕。
- 判斷就緒時不使用 `networkidle`，Playwright 官方標示不建議用於測試〔官方〕。
- 手動啟動 Blazor 的情境可串接 `Blazor.start()` 回傳的 Promise；增強式導覽後的頁面更新可監聽 `enhancedload` 事件〔官方〕。

來源：<https://learn.microsoft.com/aspnet/core/blazor/components/render-modes?view=aspnetcore-10.0>、<https://learn.microsoft.com/aspnet/core/blazor/test?view=aspnetcore-10.0>、<https://playwright.dev/dotnet/docs/test-assertions>、<https://learn.microsoft.com/aspnet/core/blazor/fundamentals/startup?view=aspnetcore-10.0>、<https://learn.microsoft.com/aspnet/core/blazor/fundamentals/navigation?view=aspnetcore-10.0>。

## 與使用者同時使用電腦

原則是只在必要操作時影響使用者。預設作法不影響使用者，必要例外限縮在可標示、可篩選、可挑時段執行的範圍。本章同時適用 FlaUI 與 Playwright。

### 干擾對照表

| 作法 | 對使用者的干擾 | 使用者對測試的干擾 | 歸類 | 來源 |
| --- | --- | --- | --- | --- |
| UIA pattern（Invoke、ExpandCollapse） | 不移動游標、不送按鍵、不改前景 | 使用者在受測視窗內操作會改變頁面狀態；使用者結束受測程式會使測試失敗 | 預設 | 〔SE〕〔AAM〕 |
| CDP 操作與斷言（Playwright） | 不經作業系統輸入佇列 | 同上 | 預設 | 〔推論〕〔待探針〕 |
| `PrintWindow` 截圖 | 不需前景，不受使用者視窗遮擋 | 視窗最小化時無法取得內容；使用者鎖定螢幕或切換工作階段時可能失敗 | 預設 | 〔AAM〕〔推論〕 |
| 啟動受測程式 | 視窗顯示，測試模式下不主動搶前景 | 使用者已開啟同名的單一執行個體程式時，測試略過 | 預設 | 〔AAM〕〔官方〕 |
| 前景加真實輸入（`RealInput`） | 搶前景、移動游標、送出按鍵 | 使用者切換視窗或輸入會中斷測試，`EnsureForeground` 偵測後中止 | 必要例外 | 〔SE〕〔AAM〕 |
| 最小化受測視窗 | 不影響使用者 | composition 版 WebView2 最小化後可能停止繪製，截圖與像素判定失效 | 不採用 | 〔官方〕〔待探針〕 |
| Windows Sandbox 或 VM | 完全隔離，雙向皆不干擾 | 需準備環境，composition 版 WebView2 行為待確認 | 選項 | 〔官方〕〔待探針〕 |

### 預設作法：不干擾

操作一個元素時依下列階梯選用，前一階可行即停止。

1. 使用 UIA pattern（Invoke、ExpandCollapse、Toggle、SelectionItem、Value），元素本身不支援時找其父元素或子元素〔SE〕〔AAM〕。
2. 改用 CDP，條件為需求屬 `## Blazor Hybrid e2e（Playwright）` 的適用範圍且不需操作原生外殼〔推論〕。
3. 前兩階皆不可行，或被測行為本身是真實輸入時，才進入 `### 必要例外：RealInput`。

- 截圖一律以 `PrintWindow` 取得，見 `### 截圖：PrintWindow`。
- 保持受測視窗不最小化。
- 維持 `DesktopAppSession.Activate` 在沒有 Invoke 時拋例外，見 `### UIA 查詢與操作`。
- 測試執行期間避免在受測視窗內操作，其他視窗可照常使用〔建議〕。

### 受測程式的測試模式

測試模式是 app 側的契約，本 skill 只寫契約，不貼 app 實作。

| 項目 | 契約 | 標籤 |
| --- | --- | --- |
| 啟用 | 測試專用啟動引數存在時生效。範例 `DesktopAppSession.cs` 沿用就緒 marker 引數；專案也可另設專用引數，此時 `Launch()` 多加一個引數。正式啟動路徑沒有此行為 | 〔建議〕 |
| 不搶前景 | 主視窗顯示前設定 WPF `ShowActivated=false`，或在 WinForms 覆寫 `ShowWithoutActivation` 回傳 `true`。啟動、就緒與導覽流程不呼叫 app 自己把視窗帶到前景的程式碼（AAM 的 `WindowForeground` 會還原最小化並呼叫 `SetForegroundWindow`）。實際啟動後是否仍搶前景需探針確認 | 〔官方〕〔AAM〕〔待探針〕 |
| 不最小化 | 不以最小化狀態啟動，測試也不最小化視窗。官方建議應用程式在視窗最小化時把 WebView2 的 `IsVisible` 設為 false；WPF BlazorWebView 的 composition 版在最小化時是否停止繪製未確認 | 〔官方〕〔待探針〕 |
| 未啟用時可讀取 | 視窗從未被啟用（`ShowActivated=false`）時，WebView2 內容的 UIA 樹是否可讀 | 〔待探針〕 |

來源：<https://learn.microsoft.com/en-us/dotnet/api/system.windows.window.showactivated>、<https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.form.showwithoutactivation>、<https://learn.microsoft.com/dotnet/api/microsoft.web.webview2.core.corewebview2controller.isvisible>。

### 必要例外：RealInput

- 判定條件，三項同時成立才使用前景與真實輸入：
  1. 元素與其父元素、子元素皆無可用 UIA pattern，或被測行為本身是真實輸入（拖放、滑鼠懸停樣式、鍵盤快捷鍵）。
  2. CDP 不適用或無法達成，包含必須操作原生外殼的情況。Playwright 的 `ClickAsync` 經 CDP 注入，屬第 2 階，是否不需前景標〔待探針〕。
  3. 測試的 `[Explicit]` 原因字串寫明前兩項的具體理由。
- 標示方式：
  - 標註 `[Category(UiTestCategory.Name)]`、`[Category(UiTestCategory.RealInput)]`、`[Explicit("<原因與時段提示>")]`、`[NonParallelizable]`、`[Platform(Include = "Win")]`。`[Explicit]` 讓一般 `dotnet test` 預設不執行。
  - 一個測試類別只放 RealInput 測試，分類與 `[Explicit]` 的範圍才會等於干擾範圍。
- 篩選指令〔建議〕：

| 情境 | 指令 |
| --- | --- |
| 使用者正在使用電腦，只跑不干擾的 UI 測試 | `dotnet test --filter "TestCategory=UI&TestCategory!=RealInput"` |
| 使用者不使用電腦的時段，只跑 RealInput | `dotnet test --filter "TestCategory=RealInput"` |

- 作法：以 `RealInputScope` 包住必要的輸入，`using` 區塊越小越好，等待與斷言放在區塊外。
  - 進入範圍時記下前一個前景視窗，呼叫 `SetForegroundWindow`，再輪詢確認受測視窗已成為前景，逾時就拋例外、不送出輸入。Windows 拒絕切換前景時會改為閃爍工作列〔官方〕，因此以輪詢實際前景視窗為準〔推論〕。
  - 每次輸入前再確認一次前景，使用者已切換視窗時中止。
  - 離開範圍時，受測視窗仍是前景才把前景還給原本的視窗；使用者已切換到其他視窗時不再搶回。還原屬盡力而為，失敗只寫入 `TestContext.Out`，是否成功標〔待探針〕。
- AAM 的 `Activate` 在沒有 Invoke 時退回 `Click()`，屬此例外〔AAM〕。本 skill 的 `Activate` 不退回，需要時由測試明確進入範圍後呼叫 `scope.Click`。

來源：<https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow>、<https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getforegroundwindow>。

完整檔案：RealInputScope.cs（例外：RealInput）

```csharp
using System.Runtime.InteropServices;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using NUnit.Framework;

namespace MyApp.UiTests;

/// <summary>
/// 在受測視窗為前景的範圍內送出真實輸入，離開範圍時把前景還給原本的視窗。
/// </summary>
public sealed class RealInputScope : IDisposable {
    private static readonly TimeSpan ForegroundTimeout = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(100);

    private readonly nint targetWindow;
    private readonly nint previousWindow;
    private bool disposed;

    private RealInputScope(nint targetWindow, nint previousWindow) {
        this.targetWindow = targetWindow;
        this.previousWindow = previousWindow;
    }

    public static RealInputScope Enter(Window window) {
        nint handle = window.Properties.NativeWindowHandle.ValueOrDefault;
        if (handle == 0) {
            throw new InvalidOperationException("無法取得受測視窗的控制代碼，不送出真實輸入。");
        }

        nint previous = GetForegroundWindow();
        SetForegroundWindow(handle);
        // 系統拒絕切換前景時只會閃爍工作列，因此以輪詢確認結果。
        bool isForeground = Retry.WhileFalse(
            () => GetForegroundWindow() == handle,
            ForegroundTimeout,
            PollInterval
        ).Result;
        if (!isForeground) {
            throw new InvalidOperationException("受測視窗未能成為前景視窗，不送出真實輸入。");
        }

        return new RealInputScope(handle, previous);
    }

    public void EnsureForeground() {
        if (GetForegroundWindow() != targetWindow) {
            throw new InvalidOperationException("受測視窗已不是前景視窗，使用者可能已切換視窗，中止真實輸入。");
        }
    }

    public void Click(AutomationElement element) {
        EnsureForeground();
        element.Click();
    }

    public void Drag(AutomationElement source, AutomationElement target) {
        EnsureForeground();
        Mouse.Drag(source.GetClickablePoint(), target.GetClickablePoint());
    }

    public void Dispose() {
        if (disposed) {
            return;
        }

        disposed = true;
        if (previousWindow == 0 || previousWindow == targetWindow) {
            return;
        }

        // 使用者已切換到其他視窗時不再搶回前景；還原屬盡力而為，失敗不影響測試結果。
        if (GetForegroundWindow() != targetWindow) {
            return;
        }

        bool restored = SetForegroundWindow(previousWindow);
        TestContext.Out.WriteLine(restored ? "已嘗試把前景還給原本的視窗。" : "無法把前景還給原本的視窗。");
    }

    [DllImport("user32.dll")]
    private static extern nint GetForegroundWindow();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint hWnd);
}
```

拖曳來源、放置目標與頁面標題為占位，依專案頁面調整。

完整檔案：RealInputTests.cs（例外：RealInput）

```csharp
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using NUnit.Framework;

namespace MyApp.UiTests;

[TestFixture]
[Category(UiTestCategory.Name)]
[Category(UiTestCategory.RealInput)]
[Explicit("拖放沒有對應的 UIA pattern，且拖放來源是原生清單、CDP 無法操作，需要前景與真實輸入，請在不使用電腦的時段執行。")]
[NonParallelizable]
[Platform(Include = "Win")]
public sealed class RealInputTests {
    [Test]
    public void DragItem_WhenDroppedOnTarget_ShowsDropResult() {
        using DesktopAppSession session = DesktopAppSession.Launch();
        session.WaitForPageTitle("看板");
        AutomationElement source = session.WaitForElement("待辦項目 1", ControlType.ListItem);
        AutomationElement target = session.WaitForElement("已完成", ControlType.List);

        using (RealInputScope scope = RealInputScope.Enter(session.MainWindow)) {
            scope.Drag(source, target);
        }

        Assert.That(session.WaitForElement("已移至已完成", ControlType.Text), Is.Not.Null);
    }
}
```

### 截圖：PrintWindow

- 以 `PrintWindow` 直接向視窗取得內容，不需前景，也不受使用者視窗遮擋〔AAM〕。
- nFlags 使用 2：AAM 回報可擷取 .NET 10 composition 版 WebView2 的內容〔AAM〕；官方頁面的 nFlags 只列 `PW_CLIENTONLY`，未載明 2 的語意〔官方〕，語意與穩定性〔待探針〕。
- 處理 DPI：`GetWindowRect` 在 DPI unaware 的程序會回傳虛擬化座標〔官方〕，AAM 先呼叫 `SetProcessDPIAware`〔AAM〕。官方建議以 manifest 設定 DPI 感知，以 API 呼叫可能造成非預期行為〔官方〕；以 `SetThreadDpiAwarenessContext` 只設定單一執行緒是官方載明的另一作法〔官方〕，未經來源專案驗證〔待探針〕。
- 跳過最小化的視窗，最小化時沒有可擷取的內容。
- 在 UI 執行緒以外呼叫，`PrintWindow` 為同步阻塞呼叫〔官方〕。
- 參考 `System.Drawing.Common` 套件〔建議〕。

截圖的時機、命名與落點不在本 skill 範圍；以像素判定白屏的規則見 `## Blazor Hybrid 專屬陷阱`。來源：<https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-printwindow>、<https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindowrect>、<https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setprocessdpiaware>、<https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setthreaddpiawarenesscontext>。

完整檔案：WindowCapture.cs

```csharp
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace MyApp.UiTests;

/// <summary>
/// 以 PrintWindow 擷取視窗內容，不需前景，也不受其他視窗遮擋。
/// </summary>
public static class WindowCapture {
    private const uint RenderFullContent = 2;

    static WindowCapture() {
        // 讓 GetWindowRect 回傳實體像素；程序已設定 DPI 感知時呼叫會失敗，忽略即可。
        SetProcessDPIAware();
    }

    public static Bitmap Capture(nint windowHandle) {
        if (IsIconic(windowHandle)) {
            throw new InvalidOperationException("視窗已最小化，無法擷取內容。");
        }

        if (!GetWindowRect(windowHandle, out Rect rect)) {
            throw new InvalidOperationException("無法取得視窗大小。");
        }

        int width = rect.Right - rect.Left;
        int height = rect.Bottom - rect.Top;
        if (width <= 0 || height <= 0) {
            throw new InvalidOperationException("視窗大小無效，無法擷取內容。");
        }

        Bitmap bitmap = new(width, height, PixelFormat.Format32bppArgb);
        bool printed;
        using (Graphics graphics = Graphics.FromImage(bitmap)) {
            nint deviceContext = graphics.GetHdc();
            try {
                printed = PrintWindow(windowHandle, deviceContext, RenderFullContent);
            } finally {
                graphics.ReleaseHdc(deviceContext);
            }
        }

        if (!printed) {
            bitmap.Dispose();
            throw new InvalidOperationException("PrintWindow 擷取失敗。");
        }

        return bitmap;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PrintWindow(nint hWnd, nint hdcBlt, uint nFlags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(nint hWnd, out Rect lpRect);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsIconic(nint hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetProcessDPIAware();

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}
```

### 完全隔離選項

| 選項 | 條件與限制 | 標籤 |
| --- | --- | --- |
| Windows Sandbox | 支援 Windows Pro、Enterprise、Education，不支援 Home；一次只能執行一個實例；每次啟動為乾淨環境，主機安裝的軟體在內不可用，.NET 執行階段、WebView2 Runtime 與受測檔案須在內安裝，或以 `.wsb` 的 `MappedFolders` 傳入；具寫入權限的對應資料夾在關閉後仍保留，可用來取回測試結果；以 `LogonCommand` 執行啟動腳本；vGPU 預設啟用，停用時改用 WARP 軟體算繪。composition 版 WebView2 與 UIA 在內是否正常未確認 | 〔官方〕〔待探針〕 |
| Hyper-V 或其他 VM | 自備客體作業系統與授權；以快照還原乾淨狀態；composition 版 WebView2 與 UIA 在內是否正常未確認 | 〔建議〕〔待探針〕 |

Windows Sandbox 提供獨立的互動桌面，與 `## 環境限制` 所列無法執行 e2e 的沙箱是不同機制。來源：<https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-overview>、<https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file>。

## 環境限制

- Blazor Hybrid 的 e2e 需要互動桌面 session 與 WebView2 Runtime，無頭環境與 Codex AppContainer 沙箱跑不起來〔SE〕。
- bUnit 不受此限制，可在一般 `dotnet test` 執行。

## 待確認項目

| 項目 | 目前處置 | 確認方式 | 標籤 |
| --- | --- | --- | --- |
| HTML `id` 對應 UIA AutomationId | 查詢以 Name 加 `ControlType` 為主，不依賴 AutomationId | 在目標專案以 FlaUI 列出元素的 AutomationId，與 HTML `id` 比對 | 〔待探針〕 |
| NUnit 5 搭配 `WaitForAssertion` | 採用 `WaitForState` 加單次 Assert。NUnit 4.5.1 下判定不相容〔SE〕，NUnit 5.0.0 下使用且通過〔AAM〕 | 同一組先失敗後通過的 bUnit 測試在 NUnit 4.x 與 5.x 各執行一次 | 〔待探針〕 |
| `Application.Launch(ProcessStartInfo)` 後讀 `ExitCode` | AAM 實測拋 `InvalidOperationException`〔AAM〕，改以 `HasExited` 加等待判定正常關閉。需要退出碼時改以自持的 `Process` 啟動並讀其 `ExitCode` | 以兩種啟動方式各讀一次 `ExitCode` | 〔推論〕 |
| `WorkingDirectory` 取 exe 目錄或暫存目錄 | AAM 取 exe 目錄，SE 取暫存目錄，兩者的測試皆通過，取捨條件未比對 | 同一受測程式以兩種設定各啟動一次，比對靜態資產是否正常載入 | 〔待探針〕 |
| 測試模式下啟動是否不搶前景，且視窗從未啟用時 UIA 是否可讀 WebView2 內容 | 契約要求 `ShowActivated=false` 或 `ShowWithoutActivation`，實際效果未確認 | 在目標專案以測試模式啟動，記錄啟動前後的前景視窗，並以 FlaUI 在未啟用狀態讀取 Document 的 Name | 〔待探針〕 |
| composition 版 WebView2 在最小化或被遮擋時是否停止繪製 | 不最小化受測視窗；截圖用 `PrintWindow` | 最小化與遮擋兩種狀態各擷取一次，比對像素顏色種類 | 〔待探針〕 |
| `PrintWindow` nFlags=2 與 DPI 作法 | 範例採 AAM 的 nFlags=2 與 `SetProcessDPIAware`；官方頁面未載明 nFlags=2 | 在 100% 與非 100% 縮放各擷取一次，比對影像尺寸與內容；另以 `SetThreadDpiAwarenessContext` 擷取比對，並確認同程序內 FlaUI 真實輸入的座標是否受 DPI 虛擬化影響 | 〔待探針〕 |
| `RealInputScope` 還原前一個前景視窗是否成功 | 失敗只記錄於 `TestContext.Out`，不使測試失敗 | 在使用者視窗為前景時進入並離開範圍，檢查前景視窗是否回到原視窗 | 〔待探針〕 |
| Playwright CDP 輸入是否不需前景且不移動真實游標 | 歸為第 2 階 | 以另一視窗為前景時執行 CDP 點擊，檢查游標位置與前景視窗是否不變 | 〔待探針〕 |
| Windows Sandbox 與 VM 內 composition 版 WebView2 與 UIA | 列為選項，不寫部署步驟 | 在 Sandbox 內啟動受測程式，讀取 UIA 樹並以 `PrintWindow` 擷取 | 〔待探針〕 |
