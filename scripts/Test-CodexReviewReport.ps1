#Requires -Version 7.0
<#
.SYNOPSIS
檢查審查報告的 Finding manifest（codex-run.review-findings.v1）。

.DESCRIPTION
輸出 ASCII 跳脫的 JSON（valid、errors、findings）。valid 為 false 時結束碼為 1。
供審查者自驗、Claude 審查者的回收與主 Agent 回收使用，不呼叫服務端。

.PARAMETER ReportPath
審查報告檔的絕對路徑。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$moduleRoot = Join-Path $PSScriptRoot 'codex-run'
. (Join-Path $moduleRoot '00-common.ps1')
. (Join-Path $moduleRoot '35-review-check.ps1')

$result = Test-RunReviewReport -ReportPath $ReportPath
Write-Output (ConvertTo-AsciiJson -InputObject $result -Depth 6)
if (-not $result.valid) { exit 1 }
exit 0
