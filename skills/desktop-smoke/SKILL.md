---
name: desktop-smoke
description: Windows 桌面應用煙霧驗證流程。當需要在修改 WinForm 或 WPF 應用後驗證行為，或使用者要求測試桌面程式、檢查視窗程式的互動與畫面時使用。
audience: agent
policy.allow_implicit_invocation: true
dispatch: split
---

# Desktop Smoke Verification

此 Skill 用於完成 WinForm 或 WPF 桌面應用變更後的低成本煙霧驗證。它不是完整 E2E 測試框架，不負責新增可重跑的測試案例；若使用者要求建立可重跑的 E2E 或操作手冊，改用 `e2e-manual`；其他正式測試依專案既有測試架構處理。

## 啟動條件

符合任一條件時套用：

- 使用者明確要求「測這個 WinForm / WPF」、「測一下桌面程式」、「檢查視窗程式」。
- 本次修改影響 WinForm / WPF 的視窗、控制項、互動或繪製邏輯。
- 由 `integration-verify` 判定為桌面應用專案後路由進入。

以下情境不強制套用：

- 只修改與 UI 無關的內部邏輯、文件或設定。
- 專案已有明確的 CI 桌面 UI 測試，且本輪只需執行該測試。

## 驗證流程

1. **確認驗證目標**：本次修改涉及的視窗、控制項或操作流程。若無法判斷，回報需要使用者指明。
2. **建置**：執行 `dotnet build`，確認編譯通過。編譯失敗先修正再繼續。
3. **判斷可用驗證層級**：依下節「驗證層級」由高至低判斷，採用最高可用層級。
4. **依層級執行驗證**。

## 驗證層級

AI 看不到桌面視窗，實際能做到的程度取決於環境提供的工具。依序判斷，採用最高可用層級。

### 層級 A：環境提供桌面 UI 操作工具

當前環境若提供桌面 UI 操作工具（如基於 FlaUI 的 MCP server 所暴露的工具），優先使用，比照 `browser-smoke` 操作瀏覽器的方式。Claude 端的 FlaUI.Mcp 工具由 `scripts/Register-McpServer.ps1 -FlaUI` 登記到 Claude 使用者層後才會出現。

- 讀取 UI Tree，定位本次修改相關的控制項。
- 走完整段操作流程（如開啟視窗 → 輸入 → 觸發動作 → 確認結果），而非只點單一控制項。
- 涵蓋正常、邊界與錯誤情境，確認各情境的實際回饋與預期一致。
- 涉及清單、表格、對話框或可捲動容器時，比照 `browser-smoke`「極端條件檢查」，不因預期由共用控制項或基底表單處理而略過。桌面另含 125%、150% DPI 縮放與小視窗，確認 Panel 自動捲動、對話框按鈕列與固定高度的控制項沒有被切掉。
- 讀 UI Tree 比對操作後實際顯示的值，確認狀態變更正確，無未預期的錯誤對話框、版面無明顯異常。
- 操作會寫入資料時，查詢資料來源確認寫入正確，並重開視窗或重啟程式確認資料正確載回。

此為一次性即時驗證，不產生可重跑的測試案例。

### 層級 B：專案已有 UI 自動化測試

無桌面操作工具，但專案已整合 FlaUI、WinAppDriver 或 Appium：

- 執行專案既有的 UI smoke / e2e 測試。
- 必要時依專案既有測試架構，協助撰寫涵蓋本次修改的測試。

### 層級 C：無 UI 自動化能力（fallback）

- 啟動存活檢查：以 `dotnet run` 在背景啟動程式（GUI 程式不會自行返回，須以背景或非同步方式啟動以免阻塞工具呼叫），等待數秒後確認 process 仍存活、未設定非零 exit code、stdout / stderr 無未處理例外，檢查後主動結束該 process。這只能證明「啟動後沒有立即崩潰」，不能證明畫面或互動正確。
- 視覺呈現、互動行為、版面正確性 AI 無法驗證。必須誠實回報「桌面 UI 互動需手動驗證」，並列出本次修改相關的手動檢查清單（操作哪個控制項、開哪個視窗、預期看到的結果）交給使用者，不得宣稱已驗證實際未驗證的項目。涉及清單、表格、對話框或可捲動容器時，清單須含 `browser-smoke`「極端條件檢查」的資料量、小視窗與 DPI 縮放項目。

提高自動化程度的方向：桌面程式的邏輯與 UI 分離得越好（WPF 採 MVVM、商業邏輯抽離 code-behind），可被單元測試與層級 A / B 涵蓋的比例越高。若要長期提升，可評估在專案導入 FlaUI（.NET 原生、較輕量）或 WinAppDriver + Appium。

## Blazor Hybrid 桌面應用

WPF 或 WinForms 外殼以 BlazorWebView 承載 Blazor 時，畫面內容在 WebView2 裡，驗證時另依下列各點處理：

- 讀取 WebView2 內容：正常狀態下 Blazor 元素經 UIA 可見，元素有 Name 與 ControlType，`ControlType.Document` 的 Name 為頁面標題。查詢要等待重試，不假設元素已存在。此行為只在 WPF 外殼驗證過，WinForms 外殼未經驗證。
- 等待 Blazor 首次渲染完成：受測程式提供就緒訊號時等該訊號，否則等 Document 的 Name 變為頁面標題，之後才查詢與操作。
- 判定白屏時搭配截圖：UIA 找得到元素時畫面仍可能未繪製，以 `PrintWindow` 擷取受測視窗並取樣像素判斷，不受其他視窗遮擋。
- 取得 DOM 細節：啟動前以環境變數開啟 WebView2 遠端偵錯，再經 CDP 讀取。
- 撰寫可重跑的測試：完整寫法與細節依 `blazor-testing` skill。
- 與使用者同時使用電腦：預設以 UIA pattern 與 CDP 操作並以 `PrintWindow` 截圖，不搶前景；必要的真實輸入與隔離選項依 `blazor-testing` skill 的 `## 與使用者同時使用電腦`。

## Claude 端桌面截圖留存

FlaUI.Mcp 的 `windows_screenshot` 只把影像回傳給模型，不存檔，且擷取的是視窗所在的螢幕區域，視窗被其他視窗遮住時回傳的是上層視窗的內容，工具不報錯。判讀畫面與留存證據都以下列配方的輸出為準。Claude 端的取證者需要留存桌面畫面時，在 PowerShell 7 執行下列配方，以 `PrintWindow` 擷取指定標題的視窗並存成 PNG，視窗被其他視窗遮住時內容仍正確。

- 輸入：視窗標題（取自 `windows_snapshot` 或 `Get-Process` 的 `MainWindowTitle`；封裝應用如小算盤的標題在 `ApplicationFrameHost` 行程上）與輸出 PNG 的絕對路徑。
- 輸出：PNG 檔，以及 stdout 的路徑、寬高與 SHA-256，報告「截圖」表照抄這三項並附命令原文與 exit code。
- `FindWindow` 的類別名稱傳 `[NullString]::Value`。PowerShell 會把 `$null` 轉成空字串傳給 `string` 參數，類別名稱變成 `""` 而找不到視窗。

```powershell
param([string]$WindowTitle, [string]$OutputPath)
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WinCapture {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
}
'@
[void][WinCapture]::SetProcessDPIAware()
$handle = [WinCapture]::FindWindow([NullString]::Value, $WindowTitle)
if ($handle -eq [IntPtr]::Zero) { Write-Error ('找不到視窗：' + $WindowTitle); exit 1 }
$rect = New-Object WinCapture+RECT
[void][WinCapture]::GetWindowRect($handle, [ref]$rect)
$width = $rect.Right - $rect.Left; $height = $rect.Bottom - $rect.Top
$bitmap = New-Object System.Drawing.Bitmap -ArgumentList $width, $height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$hdc = $graphics.GetHdc()
$ok = [WinCapture]::PrintWindow($handle, $hdc, 2)
$graphics.ReleaseHdc($hdc)
if ($ok) { $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png) }
$graphics.Dispose(); $bitmap.Dispose()
if (-not $ok) { Write-Error 'PrintWindow 失敗'; exit 1 }
Write-Output ('path=' + $OutputPath)
Write-Output ('size=' + $width + 'x' + $height)
Write-Output ('sha256=' + (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash)
```

`PrintWindow` 的旗標 `2`（`PW_RENDERFULLCONTENT`）已對 Windows 11 的小算盤（封裝應用）實測，擷取出完整視窗內容。`PrintWindow` 回傳失敗時配方以結束碼 1 結束，不改用其他擷取方式，取證者依 `executor-selection` skill「Claude 測試取證者派生契約」回報 `blocked: screenshot-unavailable`。

封裝應用（如 Windows 11 的小算盤）的最上層視窗屬於 `ApplicationFrameHost` 行程。`windows_attach` 以應用本身的行程（如 `CalculatorApp`）附加會回傳 no UIA-visible windows，改以 `processName` 為 `ApplicationFrameHost` 附加，再以回傳清單中標題相符的視窗 handle 操作。

## 派遣分界

工作拆成 Claude 端的建置與啟動、Codex 端以 MCP 工具的臨場操作，以及 Claude 端的判定。

| 工作 | 執行端 | 依據 |
| --- | --- | --- |
| 建置、執行層級 B 的既有 UI 測試專案 | 依派工判準選派：需要建置或測試命令者由選派入口選出的 Claude 執行者在沙盒外承接（建置要寫 `bin`、`obj` 並需要網路），標註 `-Type test -Tags build-test` | 派工判準 |
| 以背景方式啟動 GUI 程式 | 主 Agent 以背景進程啟動，驗證結束後依 `instructions.md` §1.4「背景進程清理」關閉 | 不派 |
| 以 FlaUI MCP 附加受測視窗、操作控制項、讀取文字與可見狀態 | 依登錄表選出的 `type=test` 執行者（標註 `-Type test -Tags desktop-control`，選出 Codex `test`），以 `scripts/Invoke-CodexRun.ps1` 發動，見 `codex-dispatch` skill `references/run.md`「測試取證（test）」；Codex 全數不可用時入口的 `fallback.selection` 選出 Sonnet，依 `executor-selection` skill「Claude 測試取證者派生契約」的「瀏覽器與桌面操作」承接，截圖依「Claude 端桌面截圖留存」 | 命令沙盒唯讀，MCP 伺服器在沙盒外操作視窗；`windows_attach` 以行程識別碼附加，不列舉其他視窗 |
| 判定畫面與視窗狀態是否符合預期、產出手動檢查清單、決定是否進入修正迴圈 | Claude 端 | 需要讀圖比對與需求脈絡 |
| 需要系統管理員權限的命令（例如 `powercfg /requests`） | 使用者在已提升權限的主控台執行 | 派遣不得提權 |
| 桌面畫面留存（存成檔案的截圖）、螢幕錄影 | Claude 端在沙盒外擷取，或由使用者手動留存 | `windows_screenshot` 只把影像回傳給模型，不存檔；留存方式與座標換算尚未定案 |

派遣檔 `## 任務` 寫明受測程式的視窗標題與行程識別碼。需要登入或測試資料時，把測試環境資料檔填入派遣檔 `test_context_file`。要在報告記錄顯示器縮放比時由 Claude 端提供，Codex 端的命令沙盒內看不到沙盒外的行程。

## 共用規範

**以 `integration-verify` 為單一來源的共用規範**（行為基準、結果驗證原則、主動詢問規範、步驟二判定執行環境、步驟六寫入回查 gate、資料異動安全規範、修正迴圈）：由 `integration-verify` 路由進入時已套用；獨立執行本 skill 時，先讀取上述各節並套用。

## 修正迴圈

修正迴圈規範以 `integration-verify` §修正迴圈 為單一來源，由 `integration-verify` 路由進入時已套用；獨立執行本 skill 時，先讀取並套用。本 skill 重跑驗證時的標的為「同一組桌面驗證」。

停止時回報（本 skill 領域專屬延伸）：

- 失敗的視窗或操作。
- 觀察到的錯誤對話框、例外或畫面現象。
- 已修正的項目。
- 尚未解決的原因或需要使用者補充的條件。

## 收尾清理

驗證結束後（成功或中止皆適用）：

- 層級 A 操作期間開啟的視窗，驗證後關閉。

## 驗證報告格式

完成後用精簡格式回報：

```text
桌面應用煙霧驗證：
- 程式 / 視窗：
- 驗證層級：A / B / C
- 檢查項目與結果：
- 修正迴圈：
- 未解決項目：
```

若沒有問題，`未解決項目` 可省略。採用層級 C 時，必須附上手動檢查清單。若未能執行驗證，必須說明缺少的工具、服務或資料條件。

獨立執行且需要寫入或刪除固定報告時，先從呼叫端取得 `LineContext`，驗證 `lineSlug` 符合 `^[a-z0-9]+(?:-[a-z0-9]+)*$`，並確認 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/line.json` 的 `line-slug` 欄位相符。缺少有效 `LineContext` 或 manifest 時停止固定報告的寫入或刪除操作，不得改用預設值。

有未解項目或阻塞條件時的檔案輸出：

- 本流程由 `integration-verify` 呼叫時，未解項目交回由其統一輸出，不自行寫檔。
- 本流程為獨立執行時，將未解項目、阻塞條件與手動檢查清單寫入 `<work-root>/.local/ai-sessions/report/<lineSlug>/verify-unresolved.md`（覆寫模式）。
- 全部通過時不寫檔；若該檔先前已存在，刪除它。
