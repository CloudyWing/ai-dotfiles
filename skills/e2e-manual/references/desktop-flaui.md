# 視窗程式路徑：FlaUI 加 NUnit

本檔是 `e2e-manual` 視窗程式路徑的寫法，適用 WinForms 與 WPF 原生程式。Blazor Hybrid 的測試碼依 `blazor-testing` skill 撰寫，截圖規則同本檔。

## 沙盒狀態

FlaUI 在 Codex 沙盒能否操作元件尚未實測。本路徑的 E2E 由使用者在本機主控台執行，或在使用者當輪同意後由 Claude 端執行，不送 Codex，執行端判定見 `SKILL.md`「派遣分界」。回報的「FlaUI 沙盒能力」欄固定寫「未驗證」。

## 專案設定

- 參考 `NUnit`、`NUnit3TestAdapter`、`Microsoft.NET.Test.Sdk`、`FlaUI.Core`，再依受測程式加 `FlaUI.UIA3`（WPF）或 `FlaUI.UIA2`（WinForms）。控制項找不到時，改用另一種 UIA 實作實測後再決定。
- 測試專案的 `TargetFramework` 使用 `net<版本>-windows`。
- 測試類別標 `[NonParallelizable]` 與 `[Platform("Win")]`，同一時間只操作一個受測程式。
- 新增套件前取得使用者當輪同意。

## 前置條件

- 需要互動式桌面 session。服務帳號、鎖定畫面或無桌面的 CI agent 無法操作 UI，遇到時回報阻塞條件。
- 受測 exe 由 `dotnet build` 產生，路徑以環境變數 `E2E_APP_PATH` 傳入。缺少變數或檔案不存在時測試失敗，並說明需要先建置。

## 受測程式啟動生命週期

每個流程獨立啟動與結束受測程式，下列五項依序套用。

### 暫存目錄隔離資料

- 建立每個流程專屬的暫存目錄 `Path.Combine(Path.GetTempPath(), "<ProjectName>.E2E", Guid.NewGuid().ToString("N"))`，不重用。
- 以受測程式既有的覆寫機制（命令列參數、環境變數或設定檔）把資料位置指向該目錄。
- 受測程式沒有這類機制時停止並回報，由使用者決定是否新增接縫。

### 單一執行個體檢查

- 啟動前以 `Process.GetProcessesByName` 檢查同名 process。
- 結束前次測試遺留的 process。判定依 `<Temp>/<ProjectName>.E2E/launched.pid` 記錄的 PID 與 process 啟動時間（`Process.StartTime` 的 UTC ticks），兩者都相符才視為遺留，避免 PID 被重用時誤結束使用者的實例。
- 保留其他同名 process，視為使用者正在使用的實例，不結束；該流程以 `Assert.Fail` 說明原因。

### 啟動

- 以 `Application.Launch(ProcessStartInfo)` 啟動，啟動參數或環境變數帶入「不干擾使用者」的測試模式，`WaitWhileMainHandleIsMissing` 與 `GetMainWindow` 各設 30 秒逾時。
- 啟動後把 PID 與 process 啟動時間寫入 `launched.pid`，受測程式正常結束後刪除該檔。
- 主視窗逾時或受測程式啟動後立即結束時，該流程失敗並記錄 exit code。

### 強制結束

- 在 `[TearDown]` 先呼叫 `Close()`，等待 `HasExited` 最多 5 秒，仍未結束則 `Kill()`。
- 只處理本測試啟動的 PID。資料位於暫存目錄，「是否儲存」這類確認對話框不阻擋結束。

### 重試刪除

- 刪除暫存目錄時最多重試 5 次，間隔 500 毫秒，捕捉 `IOException` 與 `UnauthorizedAccessException`。
- 仍失敗時以 `TestContext.Out` 記錄路徑，不使測試失敗。

## DPI-aware

在命名空間根的 `[SetUpFixture]` 中，於任何 FlaUI 呼叫之前宣告 per-monitor DPI-aware v2。未宣告時，截圖與座標會依顯示器縮放比被虛擬化。`E2E_RUN` 閘門放在同一個 `[OneTimeSetUp]` 的開頭，`Assume` 不成立時整個命名空間標為 Inconclusive，受測程式不會啟動。

```csharp
using System.Runtime.InteropServices;
using NUnit.Framework;

namespace MyApp.E2ETests;

[SetUpFixture]
public class E2ESetUpFixture
{
    private static readonly IntPtr PerMonitorAwareV2 = new(-4);

    [OneTimeSetUp]
    public void OneTimeSetUp()
    {
        Assume.That(Environment.GetEnvironmentVariable("E2E_RUN"), Is.EqualTo("1"), "未設定 E2E_RUN=1，略過 E2E");
        SetProcessDpiAwarenessContext(PerMonitorAwareV2);
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
}
```

程序已由 manifest 或執行環境設定過 DPI 感知時，呼叫會回傳 `false`，可忽略。

## 不干擾使用者

E2E 執行期間使用者可能同時在使用電腦，測試只在必要操作時影響使用者。

### 測試模式

- 以受測程式既有的測試模式參數或環境變數啟動。測試模式下啟動不搶前景（WPF 設 `ShowActivated = false`，WinForms 覆寫 `ShowWithoutActivation` 回傳 `true`），不最小化，主視窗大小固定為 1280×800 邏輯像素。
- 測試只讀取視窗，不從外部移動、縮放或啟用視窗。
- 受測程式沒有測試模式時停止並回報，由使用者決定是否新增接縫。

### 操作方式

- 操作一律透過 UIA pattern：`Invoke`、`Value`、`Toggle`、`SelectionItem`、`ExpandCollapse`。例如按鈕用 `AsButton().Invoke()`，文字框用 `AsTextBox().Text = "..."`（走 Value pattern）。
- 移動游標或送出鍵盤事件的 API（`Click()`、`Mouse`、`Keyboard`）只用於下列 `RealInput` 測試。
- 標 `[Category("RealInput")]` 於必須真實輸入或前景的測試，例如只回應真實鍵盤事件的控制項。執行前以 `GetForegroundWindow` 記錄前景視窗，操作完成後立即以 `SetForegroundWindow` 還原，並在回報註明哪些流程用了真實輸入。

## 截圖

以 PrintWindow 向視窗要畫面，不受其他視窗遮擋，也不需要前景。flag 使用 2（`PW_RENDERFULLCONTENT`），才能取得 WPF、WebView2 等以 GPU 合成的內容。

```csharp
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace MyApp.E2ETests;

public static class WindowCapture
{
    private const uint PwRenderFullContent = 2;

    public static void SaveToPng(IntPtr hwnd, string path)
    {
        if (!GetWindowRect(hwnd, out NativeRect rect))
        {
            throw new InvalidOperationException($"GetWindowRect failed: {Marshal.GetLastWin32Error()}");
        }

        using Bitmap bitmap = new(rect.Right - rect.Left, rect.Bottom - rect.Top, PixelFormat.Format32bppArgb);

        using (Graphics graphics = Graphics.FromImage(bitmap))
        {
            IntPtr hdc = graphics.GetHdc();

            try
            {
                if (!PrintWindow(hwnd, hdc, PwRenderFullContent))
                {
                    throw new InvalidOperationException("PrintWindow failed");
                }
            }
            finally
            {
                graphics.ReleaseHdc(hdc);
            }
        }

        bitmap.Save(path, ImageFormat.Png);
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr hwnd, out NativeRect rect);

    [DllImport("user32.dll")]
    private static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}
```

測試類別的截圖委派：

```csharp
private Task CaptureAsync(string path)
{
    WindowCapture.SaveToPng(window.Properties.NativeWindowHandle.Value, path);
    return Task.CompletedTask;
}
```

- 參考 `System.Drawing.Common`，測試專案的 `TargetFramework` 已是 `net<版本>-windows`。新增套件前取得使用者當輪同意。
- PrintWindow 回傳 `false` 時，該步驟失敗。
- 讀圖確認內容完整。Windows 10 以後的 `GetWindowRect` 含不可見的縮放邊框，截圖四周可能有透明邊；畫面出現黑塊或空白時，該流程不入手冊並回報。

## 流程骨架

```csharp
[TestFixture]
[Category("E2E")]
[NonParallelizable]
[Platform("Win")]
public class OrderEntryE2ETests
{
    private UIA3Automation automation = null!;
    private Application? app;
    private Window window = null!;
    private string dataDirectory = null!;
    private ManualRecorder? recorder;

    [SetUp]
    public void SetUp()
    {
        recorder = null;
        app = null;
    }

    [Test]
    public async Task CreateOrder_WithValidInput_ShowsOrderInList()
    {
        recorder = ManualRecorder.FromEnvironment(1, "新增一筆訂單");
        StartApplication();

        window.FindFirstDescendant(cf => cf.ByAutomationId("NewOrderButton")).AsButton().Invoke();
        Assert.That(window.FindFirstDescendant(cf => cf.ByAutomationId("OrderForm")), Is.Not.Null);
        await recorder.StepAsync("點選「新增訂單」", "畫面顯示訂單輸入表單", CaptureAsync);
    }
}
```

- 建立 recorder 後才呼叫 `StartApplication()`。`StartApplication()` 依「受測程式啟動生命週期」的前三項建立暫存目錄、檢查同名 process、啟動並取得主視窗。啟動失敗時例外發生在測試方法內，`[TearDown]` 仍會寫出 `Failed` 的 `flowNN.json`，失敗訊息與 exit code 不會遺失。
- `[TearDown]` 先依 `recorder.md` 寫出紀錄，再依「強制結束」與「重試刪除」處理受測程式與暫存目錄；`app` 為 `null` 時略過結束步驟。

## 執行命令

```powershell
$env:E2E_RUN = '1'
$env:E2E_APP_PATH = '<專案根目錄>\src\<ProjectName>\bin\Debug\<tfm>\<ProjectName>.exe'
$env:E2E_MANUAL_STAGING = '<work-root>\.local\ai-sessions\scratch\e2e-manual\<功能>'
dotnet test tests/<ProjectName>.E2ETests --filter "TestCategory=E2E&FullyQualifiedName~<Feature>E2ETests"
```

一次只執行一個功能的測試類別，`E2E_MANUAL_STAGING` 指向同一個功能。
