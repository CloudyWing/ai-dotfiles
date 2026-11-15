#Requires -Version 7.0
<#
.SYNOPSIS
對一份派遣檔執行一次一次性的 codex exec（審查類），在 MXC 沙盒的權限設定下直接於線工作樹執行。

.DESCRIPTION
stdout 輸出單一 ASCII 跳脫的 JSON 結果文件，stderr 輸出診斷行。
結束碼：0 成功；1 執行完成但結果為失敗，或服務端拒絕但已有進度；2 派遣檔無效、啟動前檢查不合格，或帳號目錄的檔位設定檔與 repo 產生檔不一致（CodexProfileDrift）；
3 平台、MXC 或 codex 執行檔不可用；4 沒有登記帳號、全部帳號不可用，或所有候選帳號都被服務端拒絕。
逾時與其他執行失敗同為結束碼 1。
流程與契約見 skills\codex-dispatch\references\run.md。

.PARAMETER DispatchFile
派遣檔的絕對路徑（範本為 templates\dispatch\run-order.md）。

.PARAMETER CodexPath
codex 執行檔的絕對路徑，測試與診斷用。預設為 PATH 上的 codex.cmd。

.PARAMETER MachineConfigPath
machine.json 的絕對路徑，測試與診斷用。預設為主 checkout 的 .local\machine.json。

.PARAMETER ProfileSourceRoot
檔位設定檔比對所用的 repo 根目錄，測試與診斷用。預設為主 checkout（machine.json 所在 repo），與帳號目錄連結的目標一致，從線工作樹發動時也相同。

.PARAMETER SkipProfileCheck
略過派工前的檔位設定檔比對，測試與診斷用。略過時 stderr 會留下一行紀錄。

.PARAMETER TimeoutSeconds
單次 codex 執行的總時限（秒），預設 1800。逾時時終止整棵行程樹，結果為 failed、failure_reason 為 timeout。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DispatchFile,

    [string]$CodexPath,

    [string]$MachineConfigPath,

    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 1800,

    [string]$ProfileSourceRoot,

    [switch]$SkipProfileCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)

$moduleRoot = Join-Path $PSScriptRoot 'codex-run'
foreach ($module in (Get-ChildItem -LiteralPath $moduleRoot -Filter '*.ps1' | Sort-Object -Property Name)) {
    . $module.FullName
}

try {
    $outcome = Invoke-CodexRunMain -DispatchFile $DispatchFile -CodexPath $CodexPath -MachineConfigPath $MachineConfigPath -TimeoutSeconds $TimeoutSeconds -ProfileSourceRoot $ProfileSourceRoot -SkipProfileCheck:$SkipProfileCheck
    [Console]::Out.WriteLine((ConvertTo-AsciiJson -InputObject $outcome.Document -Depth 10 -Compress))
    exit $outcome.ExitCode
}
catch {
    [Console]::Error.WriteLine('[codex-run] 未預期的錯誤：' + $_.Exception.Message)
    exit 1
}
