---
name: powershell
description: 'PowerShell 腳本撰寫規範：嚴格模式、錯誤處理、參數宣告、Verb-Noun 命名與 5.1 相容語法邊界。當撰寫或修改 `*.ps1` / `*.psm1` 腳本時自動套用。'
---

# PowerShell 腳本規範

當撰寫或修改 `*.ps1`、`*.psm1` 檔案時，請自動套用以下規範。

## 編碼與版本目標

- 檔案編碼依全域規則 §2 Encoding Strategy（UTF-8 with BOM），本檔不另行定義。
- 新腳本預設以 **PowerShell 7+ (pwsh)** 為目標版本。
- 若腳本需在 Windows PowerShell 5.1 執行（如散佈到未安裝 pwsh 的機器、被 Windows 工作排程器以 `powershell.exe` 呼叫），必須遵守 5.1 語法邊界，並在腳本開頭以 `#Requires -Version 5.1` 標明。

## 5.1 相容語法邊界

目標包含 5.1 時，下列 7+ 語法**禁止使用**：

- Pipeline chain 運算子 `&&`、`||` → 改用 `if ($?)` 或檢查 `$LASTEXITCODE`。
- 三元運算子 `? :`、null 合併 `??`、null 條件 `?.` → 改用 `if/else` 與明確的 `$null` 檢查。
- `ForEach-Object -Parallel`。
- `Get-Content -AsByteStream` → 5.1 改用 `-Encoding Byte`。
- 自動變數 `$IsWindows`、`$IsLinux`（5.1 不存在，引用會因 StrictMode 報錯）。

僅目標 7+ 的腳本不受此限，允許使用上述語法。

## 嚴格模式與錯誤處理（Crucial）

- 腳本開頭必須宣告嚴格模式與錯誤偏好：

  ```powershell
  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'
  ```

- 可預期且需處理的失敗，以 `try/catch` 包覆並在 `catch` 中給出具體錯誤訊息；不可吞掉例外後靜默繼續。
- 呼叫原生執行檔（`git`、`dotnet` 等）後，必須檢查 `$LASTEXITCODE`，失敗時終止或回報；原生命令失敗不會觸發 `$ErrorActionPreference = 'Stop'`。
- 腳本以 `exit 0` / `exit 1` 明確回傳結束碼，供 CI 與呼叫端判斷成敗。

## 參數宣告

- 具參數的腳本與函式一律使用 `[CmdletBinding()]` 搭配 `param()` 區塊，不讀取 `$args`。
- 每個參數標明型別，必填參數加 `[Parameter(Mandatory)]`，可枚舉值用 `[ValidateSet()]`，路徑類參數視需要加 `[ValidateScript({ Test-Path $_ })]`。
- 會修改系統狀態（刪檔、改設定、寫入註冊表）的函式，加 `SupportsShouldProcess` 並在執行點呼叫 `$PSCmdlet.ShouldProcess()`，使呼叫端可用 `-WhatIf` 預演。

```powershell
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$TargetPath,

    [ValidateSet('Install', 'Uninstall')]
    [string]$Mode = 'Install'
)
```

## 命名慣例

- 函式採 **Verb-Noun** 命名，動詞限用 `Get-Verb` 列出的核准動詞（如 `Get-`、`Set-`、`New-`、`Remove-`、`Test-`、`Install-`）。
- 參數名與全域變數用 PascalCase，函式內區域變數用 camelCase。
- 不使用 cmdlet 別名（`ls`、`cat`、`%`、`?`），一律寫完整 cmdlet 名稱，確保可讀性與跨平台一致。

## 輸出與管線

- 給使用者看的進度與狀態訊息用 `Write-Host`，函式的回傳資料直接輸出物件（隱式 output）。兩者不可混用，避免狀態訊息污染管線回傳值。
- 警告用 `Write-Warning`，除錯細節用 `Write-Verbose`（搭配 `[CmdletBinding()]` 由 `-Verbose` 控制），不以 `Write-Host` 模擬。
- 函式有多個輸出點時，確認每個分支的輸出型別一致；不需要回傳值的呼叫，將輸出指派給 `$null` 或加 `| Out-Null`。

## 路徑與跨平台

- 組合路徑一律使用 `Join-Path`，不手動串接分隔符。
- 引用腳本自身位置使用 `$PSScriptRoot`，不依賴執行時的工作目錄。
- 比較 `$null` 時將 `$null` 放在運算子左側（`if ($null -eq $value)`），避免集合比較的語意陷阱。

## 自動化情境限制

- 供 CI、git hook 或排程執行的腳本，禁止任何互動式呼叫（`Read-Host`、`Get-Credential`、確認提示）；需要確認行為時改以參數（如 `-Force`）控制。
- 機密資料依全域 Security Baseline 透過環境變數或 Secret Manager 注入，不硬編碼於腳本中。
