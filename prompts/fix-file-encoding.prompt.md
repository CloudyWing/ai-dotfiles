---
agent: ask
description: "偵測並修正檔案亂碼問題，依副檔名轉換至正確目標編碼（Big5/ANSI → UTF-8 系列）。"
---

# 修正檔案編碼 (Fix File Encoding)

你是熟悉 Windows 編碼環境的工具工程師。請依照以下流程，協助使用者解決檔案的中文亂碼或編碼錯誤問題。

## 執行步驟

### 1. 偵測檔案編碼

掃描目標目錄下的文字檔案：

- 檢查 BOM (Byte Order Mark) 標記。
- 若無 BOM，根據位元組模式推斷（Big5 / UTF-8 / ANSI）。
- 輸出偵測報告，列出每個檔案的目前編碼。

### 2. 判斷目標編碼

框架版本相依的副檔名（`.cs`、`.vb`、`.aspx`、`.master`、`.cshtml`），須先執行框架偵測：

1. 在目標目錄及其父層目錄向上尋找 `.csproj` 檔案。
2. 讀取 `<TargetFramework>` 欄位：
   - `net4x`（如 `net472`）→ Legacy .NET Framework。
   - `net5+`、`netcoreapp`（如 `net8.0`）→ Modern .NET。
3. 找不到 `.csproj` 時，依副檔名的預設慣例處理（見下表備註）。

| 副檔名 | 目標編碼 | 備註 |
| --- | --- | --- |
| `.cs` / `.vb` / `.aspx` / `.master` / `.resx`（Legacy .NET Framework） | UTF-8 with BOM | 避免舊工具或編譯器誤判。`.aspx` 為 Web Forms 頁面，`.master` 為 Web Forms Master Pages，兩者皆僅存在於 .NET Framework 專案。 |
| `.cs` / `.vb`（Modern .NET Core/5+） | UTF-8（無 BOM） | 現代工具鏈已無需 BOM。 |
| `.cshtml`（Legacy .NET Framework MVC） | UTF-8 with BOM | 視同 Legacy C# 處理。 |
| `.cshtml`（ASP.NET Core） | UTF-8（無 BOM） | 現代工具鏈已無需 BOM。 |
| `.ps1` | UTF-8 with BOM | 向下相容 PowerShell 5.1。 |
| `.csv` | UTF-8 with BOM | 避免 Excel 開啟亂碼。 |
| `.json` / `.xml` / `.yaml` | UTF-8（無 BOM） | 標準慣例。 |
| 其他文字檔 | UTF-8（無 BOM） | 通用預設。 |

### 3. 執行轉換

- 以偵測到的原始編碼讀取檔案。
- 以目標編碼重新寫入。
- 轉換前可選擇建立 `.bak` 備份。

### 4. 驗證結果

- 重新偵測轉換後的編碼。
- 確認中文字元正確顯示。
- 比對檔案內容未遺失。

## 注意事項

- 僅對文字檔案執行轉換；二進位檔案（`.dll`、`.exe`、`.png` 等）跳過不處理。
- 若檔案已是正確編碼，跳過不處理。
- 轉換前確認 Git 狀態乾淨，方便 `git diff` 檢視變更。
- `.editorconfig` 的編碼設定擁有最高優先權，衝突時以其為準。
