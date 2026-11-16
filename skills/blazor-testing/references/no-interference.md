# 與使用者同時使用電腦

本檔收錄 Blazor Hybrid e2e 在使用者同時使用電腦時的作法，含干擾對照表、不干擾的預設階梯、受測程式的測試模式、必要時的 RealInput 與 `RealInputScope`、PrintWindow 截圖說明與完全隔離選項。需要真實輸入、截圖或隔離環境時讀。

原則是只在必要操作時影響使用者。預設作法不影響使用者，必要例外限縮在可標示、可篩選、可挑時段執行的範圍。本章同時適用 FlaUI 與 Playwright。

## 干擾對照表

| 作法 | 對使用者的干擾 | 使用者對測試的干擾 | 歸類 | 來源 |
| --- | --- | --- | --- | --- |
| UIA pattern（Invoke、ExpandCollapse） | 不移動游標、不送按鍵、不改前景 | 使用者在受測視窗內操作會改變頁面狀態；使用者結束受測程式會使測試失敗 | 預設 | 〔SE〕〔AAM〕 |
| CDP 操作與斷言（Playwright） | 不經作業系統輸入佇列 | 同上 | 預設 | 〔推論〕〔待探針〕 |
| `PrintWindow` 截圖 | 不需前景，不受使用者視窗遮擋 | 視窗最小化時無法取得內容；使用者鎖定螢幕或切換工作階段時可能失敗 | 預設 | 〔AAM〕〔推論〕 |
| 啟動受測程式 | 視窗顯示，測試模式下不主動搶前景 | 使用者已開啟同名的單一執行個體程式時，測試略過 | 預設 | 〔AAM〕〔官方〕 |
| 前景加真實輸入（`RealInput`） | 搶前景、移動游標、送出按鍵 | 使用者切換視窗或輸入會中斷測試，`EnsureForeground` 偵測後中止 | 必要例外 | 〔SE〕〔AAM〕 |
| 最小化受測視窗 | 不影響使用者 | composition 版 WebView2 最小化後可能停止繪製，截圖與像素判定失效 | 不採用 | 〔官方〕〔待探針〕 |
| Windows Sandbox 或 VM | 完全隔離，雙向皆不干擾 | 需準備環境，composition 版 WebView2 行為待確認 | 選項 | 〔官方〕〔待探針〕 |

## 預設作法：不干擾

操作一個元素時依下列階梯選用，前一階可行即停止。

1. 使用 UIA pattern（Invoke、ExpandCollapse、Toggle、SelectionItem、Value），元素本身不支援時找其父元素或子元素〔SE〕〔AAM〕。
2. 改用 CDP，條件為需求屬 `hybrid-playwright.md` 的 `## Blazor Hybrid e2e（Playwright）` 適用範圍且不需操作原生外殼〔推論〕。
3. 前兩階皆不可行，或被測行為本身是真實輸入時，才進入 `## 必要例外：RealInput`。

- 截圖一律以 `PrintWindow` 取得，見 `## 截圖：PrintWindow`。
- 保持受測視窗不最小化。
- 維持 `DesktopAppSession.Activate` 在沒有 Invoke 時拋例外，見 `hybrid-flaui.md` 的 `## UIA 查詢與操作`。
- 測試執行期間避免在受測視窗內操作，其他視窗可照常使用〔建議〕。

## 受測程式的測試模式

測試模式是 app 側的契約，本 skill 只寫契約，不貼 app 實作。

| 項目 | 契約 | 標籤 |
| --- | --- | --- |
| 啟用 | 測試專用啟動引數存在時生效。範例 `DesktopAppSession.cs` 沿用就緒 marker 引數；專案也可另設專用引數，此時 `Launch()` 多加一個引數。正式啟動路徑沒有此行為 | 〔建議〕 |
| 不搶前景 | 主視窗顯示前設定 WPF `ShowActivated=false`，或在 WinForms 覆寫 `ShowWithoutActivation` 回傳 `true`。啟動、就緒與導覽流程不呼叫 app 自己把視窗帶到前景的程式碼（AAM 的 `WindowForeground` 會還原最小化並呼叫 `SetForegroundWindow`）。實際啟動後是否仍搶前景需探針確認 | 〔官方〕〔AAM〕〔待探針〕 |
| 不最小化 | 不以最小化狀態啟動，測試也不最小化視窗。官方建議應用程式在視窗最小化時把 WebView2 的 `IsVisible` 設為 false；WPF BlazorWebView 的 composition 版在最小化時是否停止繪製未確認 | 〔官方〕〔待探針〕 |
| 未啟用時可讀取 | 視窗從未被啟用（`ShowActivated=false`）時，WebView2 內容的 UIA 樹是否可讀 | 〔待探針〕 |

來源：<https://learn.microsoft.com/en-us/dotnet/api/system.windows.window.showactivated>、<https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.form.showwithoutactivation>、<https://learn.microsoft.com/dotnet/api/microsoft.web.webview2.core.corewebview2controller.isvisible>。

## 必要例外：RealInput

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

## 截圖：PrintWindow

- 以 `PrintWindow` 直接向視窗取得內容，不需前景，也不受使用者視窗遮擋〔AAM〕。
- nFlags 使用 2：AAM 回報可擷取 .NET 10 composition 版 WebView2 的內容〔AAM〕；官方頁面的 nFlags 只列 `PW_CLIENTONLY`，未載明 2 的語意〔官方〕，語意與穩定性〔待探針〕。
- 處理 DPI：`GetWindowRect` 在 DPI unaware 的程序會回傳虛擬化座標〔官方〕，AAM 先呼叫 `SetProcessDPIAware`〔AAM〕。官方建議以 manifest 設定 DPI 感知，以 API 呼叫可能造成非預期行為〔官方〕；以 `SetThreadDpiAwarenessContext` 只設定單一執行緒是官方載明的另一作法〔官方〕，未經來源專案驗證〔待探針〕。
- 跳過最小化的視窗，最小化時沒有可擷取的內容。
- 在 UI 執行緒以外呼叫，`PrintWindow` 為同步阻塞呼叫〔官方〕。
- 參考 `System.Drawing.Common` 套件〔建議〕。

截圖的時機、命名與落點不在本 skill 範圍；以像素判定白屏的規則見 `../SKILL.md` 的 `## Blazor Hybrid 專屬陷阱`。來源：<https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-printwindow>、<https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindowrect>、<https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setprocessdpiaware>、<https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setthreaddpiawarenesscontext>。

## 完全隔離選項

| 選項 | 條件與限制 | 標籤 |
| --- | --- | --- |
| Windows Sandbox | 支援 Windows Pro、Enterprise、Education，不支援 Home；一次只能執行一個實例；每次啟動為乾淨環境，主機安裝的軟體在內不可用，.NET 執行階段、WebView2 Runtime 與受測檔案須在內安裝，或以 `.wsb` 的 `MappedFolders` 傳入；具寫入權限的對應資料夾在關閉後仍保留，可用來取回測試結果；以 `LogonCommand` 執行啟動腳本；vGPU 預設啟用，停用時改用 WARP 軟體算繪。composition 版 WebView2 與 UIA 在內是否正常未確認 | 〔官方〕〔待探針〕 |
| Hyper-V 或其他 VM | 自備客體作業系統與授權；以快照還原乾淨狀態；composition 版 WebView2 與 UIA 在內是否正常未確認 | 〔建議〕〔待探針〕 |

Windows Sandbox 提供獨立的互動桌面，與 `../SKILL.md` 的 `## 環境限制` 所列無法執行 e2e 的沙箱是不同機制。來源：<https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-overview>、<https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file>。
