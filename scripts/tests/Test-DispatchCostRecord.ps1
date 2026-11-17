#Requires -Version 7.0
<#
.SYNOPSIS
成效比對文件（cost-comparison.md）程式區塊與 Get-LineCost.ps1 的單元測試。

.PARAMETER Unit
Comparison：成效比對文件的程式區塊。
All：依序執行已實作的全部單元。
#>
[CmdletBinding()]
param(
    [ValidateSet('Comparison', 'All')]
    [string]$Unit = 'All',

    [string]$FixtureBaseRootPath = [IO.Path]::GetTempPath()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $scriptsRoot

$script:cases = New-Object 'System.Collections.Generic.List[object]'
$script:fixtureRoot = Join-Path ([IO.Path]::GetFullPath($FixtureBaseRootPath)) ('cr' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = [IO.Directory]::CreateDirectory($script:fixtureRoot)

function Assert-Case {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action
        $script:cases.Add([pscustomobject]@{ name = $Name; result = 'PASS'; error = $null })
    }
    catch {
        $script:cases.Add([pscustomobject]@{ name = $Name; result = 'FAIL'; error = $_.Exception.Message })
    }
}

function Write-TestUtf8NoBom {
    param([string]$Path, [string]$Text)
    $directory = Split-Path -Parent $Path
    if (-not [IO.Directory]::Exists($directory)) { $null = [IO.Directory]::CreateDirectory($directory) }
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function New-TestComparisonRow {
    param([string]$Kind, [string]$RunId, [string]$CycleId, [string]$Round, [string]$Role, [string]$InputTokens)
    $cells = @('2026-11-10T00:00:00Z', $Kind, 'cost-line', ('cmp-' + $RunId), $RunId, $CycleId, $Round, $Role, '首次', '5', $InputTokens, '-', '-', 'note')
    return ('| ' + ($cells -join ' | ') + ' |')
}

function Invoke-ComparisonUnit {
    $documentPath = Join-Path $repoRoot 'skills\session-artifacts\references\cost-comparison.md'
    $snippet = $null
    $extractError = $null
    try {
        $documentText = [IO.File]::ReadAllText($documentPath, (New-Object System.Text.UTF8Encoding($false)))
        $markerIndex = $documentText.IndexOf('<!-- new-data-snippet -->')
        if ($markerIndex -lt 0) { throw '找不到 <!-- new-data-snippet --> 標記' }
        $fenceMatch = [regex]::Match($documentText.Substring($markerIndex), '(?s)```powershell\r?\n(.*?)\r?\n```')
        if (-not $fenceMatch.Success) { throw '標記之後找不到 powershell 程式區塊' }
        $snippet = $fenceMatch.Groups[1].Value
    }
    catch { $extractError = $_.Exception.Message }

    Invoke-Case 'Comparison:自文件標記之後取得 powershell 程式區塊且含 -WorkRoot 與 -LineCostScript 參數' {
        Assert-Case ($null -eq $extractError) ('取得程式區塊失敗：' + $extractError)
        Assert-Case ($snippet.StartsWith('param([Parameter(Mandatory)][string]$WorkRoot, [Parameter(Mandatory)][string]$LineCostScript)')) '程式區塊應以 WorkRoot 與 LineCostScript 的 param 開頭'
    }

    $comparisonRoot = Join-Path $script:fixtureRoot 'comparison'
    $ledgerPath = Join-Path $comparisonRoot '.local\ai-sessions\report\cost-line\cost-ledger.md'
    $header = '| 時間（UTC） | 列類型 | 成本目標 | dispatchSlug | runId | cycle_id | cycle_round | cycle_role | 事件類型 | 耗時（秒） | input | cached_input | output | 備註 |'
    $separator = '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |'
    $legacyRow = New-TestComparisonRow -Kind '事件' -RunId 'run-legacy' -CycleId 'cycle-legacy' -Round '1' -Role 'review' -InputTokens '99999'
    $ledgerLines = @(
        '# cost-line 成本紀錄', '',
        $header, $separator, $legacyRow, '',
        '<!-- cost-ledger.v2 -->', $header, $separator,
        (New-TestComparisonRow -Kind '事件' -RunId 'run-01' -CycleId 'cycle-a' -Round '1' -Role 'review' -InputTokens '1000'),
        (New-TestComparisonRow -Kind '事件' -RunId 'run-02' -CycleId 'cycle-a' -Round '2' -Role 'review' -InputTokens '500'),
        (New-TestComparisonRow -Kind '事件' -RunId 'run-02' -CycleId 'cycle-a' -Round '2' -Role 'review' -InputTokens '500'),
        (New-TestComparisonRow -Kind '事件' -RunId 'run-03' -CycleId 'cycle-a' -Round '3' -Role 'review' -InputTokens '300'),
        (New-TestComparisonRow -Kind '事件' -RunId 'run-04' -CycleId 'cycle-b' -Round '1' -Role 'review' -InputTokens '800'),
        (New-TestComparisonRow -Kind '事件' -RunId 'run-05' -CycleId 'cycle-b' -Round '2' -Role 'review' -InputTokens '-'),
        (New-TestComparisonRow -Kind '事件（手寫）' -RunId 'run-06' -CycleId 'cycle-c' -Round '1' -Role 'review' -InputTokens '700'),
        (New-TestComparisonRow -Kind '事件' -RunId 'run-07' -CycleId '-' -Round '-' -Role '-' -InputTokens '200'),
        (New-TestComparisonRow -Kind '事件（手寫）' -RunId 'claude-abcd1234-1' -CycleId 'cycle-f' -Round '1' -Role 'fix' -InputTokens '5000'),
        (New-TestComparisonRow -Kind '事件（手寫）' -RunId 'claude-abcd1234-2' -CycleId 'cycle-f' -Round '2' -Role 'fix' -InputTokens '3000'),
        (New-TestComparisonRow -Kind '事件（手寫）' -RunId 'claude-abcd1234-3' -CycleId 'cycle-f' -Round '2' -Role 'fix' -InputTokens '4000'),
        '| 2026-11-10T00:00:00Z | 預算 | cost-line | - | - | - | - | - | - | - | - | - | - | 預算列不參與計算 |'
    )
    Write-TestUtf8NoBom -Path $ledgerPath -Text (($ledgerLines -join [Environment]::NewLine) + [Environment]::NewLine)

    $output = @()
    $runError = $null
    try {
        $snippetPath = Join-Path $comparisonRoot 'comparison-snippet.ps1'
        [IO.File]::WriteAllText($snippetPath, $snippet, (New-Object System.Text.UTF8Encoding($true)))
        $output = @(& { Set-StrictMode -Off; & $snippetPath -WorkRoot $comparisonRoot -LineCostScript (Join-Path $scriptsRoot 'Get-LineCost.ps1') } | ForEach-Object { [string]$_ })
    }
    catch { $runError = $_.Exception.Message }

    Invoke-Case 'Comparison:程式區塊對 fixture ledger 執行成功' {
        Assert-Case ($null -eq $runError) ('執行失敗：' + $runError)
        Assert-Case ($output.Count -ge 6) ('輸出行數不足：' + ($output -join ' / '))
    }
    Invoke-Case 'Comparison:M1 與 M1u 以全部輪次與有 usage 輪次計算，舊版表、非事件列與重複 runId 不影響' {
        Assert-Case ($output -contains 'M1 median = 2.5 over 3,2') ('M1 不符：' + ($output -join ' / '))
        Assert-Case ($output -contains 'M1u median = 2 over 3,1') ('M1u 不符：' + ($output -join ' / '))
    }
    Invoke-Case 'Comparison:M2 合併與各循環比例只計有 usage 的 Codex run' {
        Assert-Case ($output -contains 'M2 combined = 30.77%') ('M2 合併不符：' + ($output -join ' / '))
        Assert-Case ($output -contains 'M2 cost-line, cycle-a = 44.44%') ('M2 循環 A 不符：' + ($output -join ' / '))
        Assert-Case ($output -contains 'M2 cost-line, cycle-b = 0%') ('M2 循環 B 不符：' + ($output -join ' / '))
        Assert-Case (@($output | Where-Object { $_.StartsWith('M2 cost-line, cycle-c') -or $_.StartsWith('M2 cost-line, cycle-f') }).Count -eq 0) '非事件列不得出現在 M2'
    }
    Invoke-Case 'Comparison:M3 分母含未標記事件列，分子為有 usage 者' {
        Assert-Case ($output -contains 'M3 = 5/6（未標記 1 列）') ('M3 不符：' + ($output -join ' / '))
    }
    Invoke-Case 'Comparison:輸出不含 M4 與 Claude subagent token 合計' {
        Assert-Case (@($output | Where-Object { $_.StartsWith('M4') -or $_.StartsWith('Claude subagent') }).Count -eq 0) ('不應輸出 M4 或 Claude token 合計：' + ($output -join ' / '))
    }
}

$unitHandlers = [ordered]@{
    Comparison = { Invoke-ComparisonUnit }
}
$selectedUnits = if ($Unit -eq 'All') { @($unitHandlers.Keys) } else { @($Unit) }
foreach ($selectedUnit in $selectedUnits) {
    if (-not $unitHandlers.Contains($selectedUnit)) {
        $script:cases.Add([pscustomobject]@{ name = $selectedUnit + ':尚未實作'; result = 'FAIL'; error = '單元尚未實作' })
        continue
    }
    & $unitHandlers[$selectedUnit]
}

foreach ($case in $script:cases) {
    if ($case.result -eq 'PASS') {
        Write-Host ('PASS ' + $case.name)
    }
    else {
        Write-Host ('FAIL ' + $case.name + ' => ' + $case.error)
    }
}
$failed = @($script:cases | Where-Object { $_.result -ne 'PASS' })
Write-Host ('合計 {0} 案，失敗 {1} 案。' -f $script:cases.Count, $failed.Count)
try { Remove-Item -LiteralPath $script:fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
if ($failed.Count -gt 0) { exit 1 }
exit 0
