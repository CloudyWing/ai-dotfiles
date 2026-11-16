# 待確認項目

本檔收錄 blazor-testing 中標為〔待探針〕的項目，各項列出目前處置與確認方式。依賴標有〔待探針〕的內容前讀。

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
