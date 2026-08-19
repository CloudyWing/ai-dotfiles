---
name: fix-file-encoding
description: 偵測並修正檔案亂碼問題，依副檔名轉換至正確目標編碼（Big5/ANSI → UTF-8 系列）。
audience: human
dispatch: dispatchable
disable-model-invocation: true
policy.allow_implicit_invocation: false
---

# 修正檔案編碼

## 使用方式

```
/fix-file-encoding [檔案路徑或 glob 模式]
```

若未傳入路徑，詢問使用者要處理哪些檔案。

## 執行步驟

### 1. 確認目標檔案

列出符合條件的檔案清單，讓使用者確認範圍後再繼續。

### 2. 判斷目標編碼

依副檔名與專案框架決定目標編碼，規則同 CLAUDE.md §2 Encoding Strategy：

| 檔案類型 | 目標編碼 |
| --- | --- |
| `*.ps1` | UTF-8 **with BOM** |
| `*.csv` | UTF-8 **with BOM** |
| `.NET Framework` 的 `*.cs`, `*.vb`, `*.aspx`, `*.master` | UTF-8 **with BOM** |
| `net4x` 框架的 `*.cshtml` | UTF-8 **with BOM** |
| 其他所有檔案 | UTF-8 **無 BOM** |

判斷 `*.cshtml` 的框架版本：讀取同專案的 `.csproj`，檢查 `<TargetFramework>` 欄位。`net4x` 為 .NET Framework，其餘（`net5+`、`netcoreapp`）為 .NET Core/ASP.NET Core。

### 3. 偵測來源編碼

使用 PowerShell 偵測檔案的實際編碼：

```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$bytes = [System.IO.File]::ReadAllBytes("$FilePath")
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    "UTF-8 with BOM"
} elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    "UTF-16 LE"
} else {
    "Unknown (likely ANSI/Big5)"
}
```

若偵測為「Unknown」，嘗試以 Big5 解碼，若解碼後中文可讀，則來源編碼視為 Big5。

### 4. 轉換編碼

若來源編碼與目標編碼相同，告知使用者無需轉換並跳過。

執行轉換（PowerShell）：

```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$content = [System.IO.File]::ReadAllText("$FilePath", [System.Text.Encoding]::GetEncoding(950))  # Big5
# 目標為 UTF-8 無 BOM（不可用 [System.Text.Encoding]::UTF8，該屬性會寫出 BOM）
[System.IO.File]::WriteAllText("$OutputPath", $content, (New-Object System.Text.UTF8Encoding($false)))
# 目標為 UTF-8 with BOM
[System.IO.File]::WriteAllText("$OutputPath", $content, (New-Object System.Text.UTF8Encoding($true)))
```

### 5. 驗證結果

轉換後重新以 UTF-8 讀取，確認中文內容可正常顯示，輸出前幾行供使用者確認。

若驗證無法完成，將檔案路徑、偵測到的編碼與錯誤訊息寫入 `<work-root>/.local/ai-sessions/report/verify-unresolved.md`，保留原始檔案與備份供後續處理。

### 6. 輸出摘要

```markdown
## 編碼轉換摘要
| 檔案 | 來源編碼 | 目標編碼 | 狀態 |
| --- | --- | --- | --- |
| path/to/file.cs | Big5 | UTF-8 with BOM | ✅ 完成 |
| path/to/script.ps1 | UTF-8 無 BOM | UTF-8 with BOM | ✅ 完成 |
| path/to/other.cs | UTF-8 with BOM | UTF-8 with BOM | ⏭️ 略過（已正確） |
```

## 注意事項

- **轉換前必須備份**：編碼轉換屬於原地改寫非本 Session 產生的檔案，依全域 §1.4「腳本改寫安全」，先將受影響檔案複製到 `<work-root>/.local/ai-sessions/backups/<時間戳>/`（保留原始相對路徑），並寫入一行 `manifest.txt` 記錄該次操作。不因專案有 git 而省略。備份保留於 `backups/`，不放入 `report/`。
- 若檔案為二進位檔（如圖片、PDF），跳過並警告。
