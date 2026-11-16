# Blazor Hybrid e2e（FlaUI）

本檔收錄以 FlaUI 測試 WPF 或 WinForms BlazorWebView 外殼的寫法，含測試專案結構、受測程式的啟動與就緒、UIA 查詢與操作、關閉與清理，以及 `DesktopAppSession` 工作階段範例。撰寫或修改 Blazor Hybrid 的 FlaUI e2e 測試時讀。

FlaUI 透過 UI Automation（UIA3）操作外殼與 WebView2 內容。正常狀態下 WebView2 內的 Blazor 元素會出現在 UIA 樹，以 Name 加 ControlType 可找到 MudBlazor 的 Button、Hyperlink、MenuItem，`ControlType.Document` 的 Name 為頁面標題〔AAM〕〔SE〕。

## 測試專案結構

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

UI 測試專案啟用 ImplicitUsings，套件為 `FlaUI.Core`、`FlaUI.UIA3`、`NUnit`、`NUnit3TestAdapter`、`Microsoft.NET.Test.Sdk`；Playwright 範例另加 `Microsoft.Playwright`，截圖範例另加 `System.Drawing.Common`。本章與 `no-interference.md` 的範例以 FlaUI 5.0.0、Microsoft.Playwright 1.64.1、System.Drawing.Common 10.0.2 建置。

路徑以 `$(TargetFramework)` 組成，受測專案與測試專案的 TFM 必須一致。路徑寫死 TFM 時，TFM 變更後路徑失效，見 `../SKILL.md` 的 `## Blazor Hybrid 專屬陷阱`。

## 受測程式的啟動與就緒

- 隔離資料：以啟動引數把資料目錄導向暫存目錄（引數名稱由受測程式自訂，AAM 為 `--data-root`）〔AAM〕，或把 `LOCALAPPDATA` 環境變數改成暫存目錄〔SE〕，避免動到使用者的真實設定。
- 設定 `WorkingDirectory`：AAM 設為 exe 所在目錄〔AAM〕，SE 設為暫存目錄〔SE〕，兩者的測試皆通過。取捨條件列於 `pending-probes.md`。
- 檢查單一執行個體：受測程式只允許單一實例時，測試前以 `Process.GetProcessesByName` 檢查同名程序，存在時略過並提示，否則新程序只會喚醒舊視窗後結束〔AAM〕。
- 等待就緒訊號。視窗出現早於 Blazor 渲染，只等主視窗會在空白頁上操作。就緒訊號分兩層〔AAM〕：
  - 受測程式提供 marker 契約：接受一個 marker 路徑引數（AAM 為 `--startup-render-probe`），只在該引數存在時，於根元件首次 `OnAfterRenderAsync(firstRender: true)` 後寫出 marker 檔，寫入方式為先寫暫存檔再移動。正式啟動不帶此引數，沒有這個行為。測試側等 marker 檔出現，或程序提前結束時判定失敗。
  - 頁面就緒以 `ControlType.Document` 的 Name 等於 PageTitle 判定。`index.html` 的預設標題與視窗標題相同時，Name 等於視窗標題不算就緒。

## UIA 查詢與操作

- 查詢一律帶等待與重試：`Retry.WhileNull`（`ignoreException: true`），以 Name 加 `ControlType` 比對〔AAM〕〔SE〕。`aria-label` 會成為 UIA 的 Name〔SE〕。`Retry.*` 回傳 `RetryResult<T>`，其 `.Result` 是結果屬性，不是 `Task.Result`。
- 查詢以 Name 加 `ControlType` 為主。HTML `id` 是否對應成 UIA AutomationId 只有社群報告，沒有官方文件〔待探針〕，需要用 AutomationId 時先以探針確認，見 `pending-probes.md`。
- 操作一律用 UIA pattern：一般按鈕與連結用 `Patterns.Invoke`；MudMenu 的觸發鈕只支援 `ExpandCollapse`，以 `Patterns.ExpandCollapse.Pattern.Expand()` 展開，選單項目再以 `AsMenuItem().Invoke()` 觸發〔SE〕。
- 避免真實輸入：`Click()`、`Keyboard`、`Mouse` 會移動真實滑鼠與鍵盤，視窗不在前景時會點到其他程式，SE 曾因此點到使用者正在使用的其他程式〔SE〕。AAM 的 `Activate` 在元素沒有 Invoke 時退回 `Click()`〔AAM〕，本 skill 的 `Activate` 不退回，無 Invoke 時拋例外。元素沒有可用 pattern 時依 `../SKILL.md` 的 `## 與使用者同時使用電腦` 的三階梯處理。
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

## 關閉與清理

- 關閉程序：關閉前先記下 `ProcessId`（程序結束後再讀會拋例外），`MainWindow.Close()` 後等 `HasExited`，逾時才以 `Kill(entireProcessTree: true)` 結束整個程序樹〔SE〕〔AAM〕。
- 釋放資源：程序結束後釋放 `Application` 與 `UIA3Automation`。
- 判定正常關閉以 `HasExited` 加等待為準，不讀 `Application.ExitCode`，原因見 `pending-probes.md`。
- 重試刪除暫存目錄：WebView2 子程序可能在主程序結束後短暫持有檔案，刪除失敗時間隔 500 毫秒重試，最多 10 次〔AAM〕。

## FlaUI 工作階段範例

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
