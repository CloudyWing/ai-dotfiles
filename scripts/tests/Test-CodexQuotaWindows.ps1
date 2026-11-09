#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name Microsoft.PowerShell.Utility

$quotaScriptPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\Get-CodexQuota.ps1')).Path
$lineStatusPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\Get-LineStatus.ps1')).Path
$selfPath = $MyInvocation.MyCommand.Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('quota-windows-' + [guid]::NewGuid().ToString('N'))
$failed = 0
$passed = 0
$caseCounter = 0
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$hostPath = if ($PSVersionTable.PSEdition -eq 'Desktop') {
    Join-Path $PSHOME 'powershell.exe'
}
else {
    $hostCommand = Get-Command -Name 'pwsh' -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($hostCommand.Source)) { $hostCommand.Path } else { $hostCommand.Source }
}

function Test-Case {
    param([string]$Id, [scriptblock]$Check)
    try {
        if (-not (& $Check)) { throw '條件不成立' }
        $script:passed++
        Write-Output "PASS $Id"
    }
    catch {
        $script:failed++
        Write-Output "FAIL $Id $($_.Exception.Message)"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-HostProcess {
    param(
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $hostPath
    $startInfo.Arguments = (($Arguments | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' ')
    $startInfo.WorkingDirectory = $tempRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $utf8NoBom
    $startInfo.StandardErrorEncoding = $utf8NoBom
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $result = [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdoutTask.Result
        StdErr   = $stderrTask.Result
    }
    $process.Dispose()
    return $result
}

function New-QuotaWindow {
    param(
        [double]$UsedPercent = 40,
        [int]$WindowSeconds = 18000,
        [int]$ResetAfterSeconds = 3600
    )

    return [ordered]@{
        used_percent         = $UsedPercent
        limit_window_seconds = $WindowSeconds
        reset_after_seconds  = $ResetAfterSeconds
        reset_at             = [DateTimeOffset]::UtcNow.AddSeconds($ResetAfterSeconds).ToUnixTimeSeconds()
    }
}

function New-QuotaApiResponse {
    param(
        [AllowNull()][object]$Primary = (New-QuotaWindow -UsedPercent 40 -WindowSeconds 18000 -ResetAfterSeconds 7200),
        [AllowNull()][object]$Secondary = (New-QuotaWindow -UsedPercent 50 -WindowSeconds 604800 -ResetAfterSeconds 432000),
        [switch]$OmitPrimary,
        [switch]$OmitSecondary,
        [bool]$Allowed = $true,
        [bool]$LimitReached = $false,
        [string]$ReachedType,
        [bool]$SpendControlReached = $false
    )

    $rateLimit = [ordered]@{
        allowed       = $Allowed
        limit_reached = $LimitReached
    }
    if (-not [string]::IsNullOrWhiteSpace($ReachedType)) { $rateLimit['rate_limit_reached_type'] = $ReachedType }
    if (-not $OmitPrimary) { $rateLimit['primary_window'] = $Primary }
    if (-not $OmitSecondary) { $rateLimit['secondary_window'] = $Secondary }
    return [ordered]@{
        rate_limit    = $rateLimit
        spend_control = [ordered]@{ reached = $SpendControlReached }
    }
}

function Invoke-QuotaCase {
    param(
        [Parameter(Mandatory)][object]$Response
    )

    $script:caseCounter++
    $caseRoot = Join-Path $tempRoot ('case-{0:00}' -f $script:caseCounter)
    $codexHome = Join-Path $caseRoot 'codex-home'
    New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
    $authDocument = [ordered]@{
        tokens = [ordered]@{
            access_token = 'fixture-access-token'
            account_id   = 'fixture-account-id'
        }
    }
    [IO.File]::WriteAllText((Join-Path $codexHome 'auth.json'), ($authDocument | ConvertTo-Json -Depth 4), $utf8NoBom)
    $responsePath = Join-Path $caseRoot 'api-response.json'
    [IO.File]::WriteAllText($responsePath, ($Response | ConvertTo-Json -Depth 8), $utf8NoBom)
    $snapshotPath = Join-Path $caseRoot 'snapshot.json'

    $process = Invoke-HostProcess -Arguments @(
        '-NoProfile', '-NonInteractive', '-File', $script:wrapperPath,
        '-QuotaScriptPath', $quotaScriptPath,
        '-CodexHomePath', $codexHome,
        '-SnapshotPath', $snapshotPath,
        '-ApiResponsePath', $responsePath
    )
    $snapshot = $null
    if (Test-Path -LiteralPath $snapshotPath -PathType Leaf) {
        $snapshot = [IO.File]::ReadAllText($snapshotPath, $utf8NoBom) | ConvertFrom-Json
    }
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $process.StdOut
        StdErr   = $process.StdErr
        Lines    = @($process.StdOut -split "`r?`n" | Where-Object { $_.Length -gt 0 })
        Snapshot = $snapshot
    }
}

function Assert-PrimaryLines {
    param([object]$Result)

    foreach ($suffix in 'used_percent', 'remaining_percent', 'days_to_reset', 'window_minutes', 'window_days', 'resets_at', 'resets_at_local', 'source_file') {
        Assert-True (@($Result.Lines | Where-Object { $_.StartsWith('primary_' + $suffix + '=') }).Count -eq 1) ('stdout 缺少 primary_' + $suffix + '=')
    }
    Assert-True (@($Result.Lines | Where-Object { $_.StartsWith('primary_') }).Count -eq 8) 'primary 行數不是 8。'
}

function Assert-NoSecondaryWindow {
    param([object]$Result)

    Assert-True ($Result.ExitCode -eq 0) ('結束碼不是 0：' + $Result.ExitCode + ' ' + $Result.StdErr)
    Assert-PrimaryLines -Result $Result
    $secondaryLines = @($Result.Lines | Where-Object { $_.StartsWith('secondary_') })
    Assert-True ($secondaryLines.Count -eq 1 -and $secondaryLines[0] -eq 'secondary_window=none') ('secondary 行不是單行 secondary_window=none：' + ($secondaryLines -join ','))
    foreach ($suffix in 'used_percent', 'remaining_percent', 'resets_at_local') {
        Assert-True ($Result.StdOut -notmatch ('secondary_' + $suffix + '=')) ('stdout 不應含 secondary_' + $suffix + '=')
    }
    $snapshot = $Result.Snapshot
    Assert-True ($null -ne $snapshot) '沒有快照。'
    Assert-True ($snapshot.schema -eq 'ai-sessions.quota-snapshot.v1') 'schema 不是 v1。'
    Assert-True ($snapshot.state -eq 'Valid') ('state 不是 Valid：' + $snapshot.state)
    Assert-True ([string]::IsNullOrEmpty([string]$snapshot.error)) ('error 不是空值：' + $snapshot.error)
    Assert-True ($null -ne $snapshot.primary) 'primary 為 null。'
    Assert-True ($null -eq $snapshot.secondary) 'secondary 不是 null。'
    Assert-True ($null -ne $snapshot.observations.primary) 'observations.primary 為 null。'
    Assert-True ($null -eq $snapshot.observations.secondary) 'observations.secondary 不是 null。'
}

function Assert-PrimaryUnavailable {
    param([object]$Result)

    Assert-True ($Result.ExitCode -eq 1) ('結束碼不是 1：' + $Result.ExitCode)
    $snapshot = $Result.Snapshot
    Assert-True ($null -ne $snapshot) '沒有快照。'
    Assert-True ($snapshot.state -eq 'SnapshotUnavailable') ('state 不是 SnapshotUnavailable：' + $snapshot.state)
    Assert-True ($snapshot.error.StartsWith('QuotaApiResponseInvalid;')) ('error 開頭不符：' + $snapshot.error)
    Assert-True ($snapshot.error.Contains('field=rate_limit.primary_window')) ('error 缺少 primary_window 欄位：' + $snapshot.error)
    Assert-True ($null -eq $snapshot.primary -and $null -eq $snapshot.secondary -and $null -eq $snapshot.observations) 'primary、secondary、observations 應皆為 null。'
    Assert-True ($Result.StdErr.Contains('Get-CodexQuota.ps1 失敗')) ('stderr 缺少失敗訊息：' + $Result.StdErr)
}

function New-FakeQuotaScript {
    param(
        [string]$Path,
        [string]$Body
    )

    $content = "param([string]`$CodexHome)`r`n" + $Body + "`r`n"
    [IO.File]::WriteAllText($Path, $content, $utf8Bom)
    return $Path
}

$wrapperContent = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QuotaScriptPath,
    [Parameter(Mandatory)][string]$CodexHomePath,
    [Parameter(Mandatory)][string]$SnapshotPath,
    [Parameter(Mandatory)][string]$ApiResponsePath
)

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

function global:Invoke-WebRequest {
    [CmdletBinding()]
    param(
        [string]$Uri,
        [string]$Method,
        [hashtable]$Headers,
        [int]$TimeoutSec,
        [int]$MaximumRedirection,
        [switch]$UseBasicParsing
    )

    if ($Uri -cne 'https://chatgpt.com/backend-api/wham/usage' -or $Method -cne 'Get') {
        throw 'Quota fixture rejected an unexpected request.'
    }
    $content = Get-Content -LiteralPath $ApiResponsePath -Raw -Encoding UTF8
    return [pscustomobject]@{ StatusCode = 200; Content = $content }
}

$env:CODEX_HOME = $CodexHomePath
$global:LASTEXITCODE = $null
& $QuotaScriptPath -SnapshotPath $SnapshotPath
if ($null -eq $LASTEXITCODE) { exit 1 }
exit $LASTEXITCODE
'@

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $wrapperPath = Join-Path $tempRoot 'fixture-wrapper.ps1'
    [IO.File]::WriteAllText($wrapperPath, $wrapperContent, $utf8Bom)

    Test-Case Q01 {
        $result = Invoke-QuotaCase -Response (New-QuotaApiResponse -Secondary $null)
        Assert-NoSecondaryWindow -Result $result
        $true
    }
    Test-Case Q02 {
        $result = Invoke-QuotaCase -Response (New-QuotaApiResponse -OmitSecondary)
        Assert-NoSecondaryWindow -Result $result
        $true
    }
    Test-Case Q03 {
        $result = Invoke-QuotaCase -Response (New-QuotaApiResponse -Primary $null)
        Assert-PrimaryUnavailable -Result $result
        $true
    }
    Test-Case Q04 {
        $result = Invoke-QuotaCase -Response (New-QuotaApiResponse -OmitPrimary -Secondary $null)
        Assert-PrimaryUnavailable -Result $result
        $true
    }
    Test-Case Q05 {
        $result = Invoke-QuotaCase -Response (New-QuotaApiResponse)
        Assert-True ($result.ExitCode -eq 0) ('結束碼不是 0：' + $result.ExitCode + ' ' + $result.StdErr)
        Assert-PrimaryLines -Result $result
        Assert-True (@($result.Lines | Where-Object { $_.StartsWith('secondary_') }).Count -eq 8) 'secondary 行數不是 8。'
        Assert-True ($result.StdOut -notmatch 'secondary_window=none') 'stdout 不應含 secondary_window=none。'
        Assert-True ($result.Snapshot.state -eq 'Valid') 'state 不是 Valid。'
        Assert-True ($null -ne $result.Snapshot.secondary -and $null -ne $result.Snapshot.observations.secondary) 'secondary 與 observations.secondary 不應為 null。'
        Assert-True ($result.Snapshot.secondary.window_minutes -eq 10080) ('secondary.window_minutes 不是 10080：' + $result.Snapshot.secondary.window_minutes)
        Assert-True ($result.Snapshot.primary.window_minutes -eq 300) ('primary.window_minutes 不是 300：' + $result.Snapshot.primary.window_minutes)
        $true
    }
    Test-Case Q06 {
        $result = Invoke-QuotaCase -Response (New-QuotaApiResponse -Secondary 'not-an-object')
        Assert-True ($result.ExitCode -eq 1) ('結束碼不是 1：' + $result.ExitCode)
        Assert-True ($result.Snapshot.state -eq 'SnapshotUnavailable') ('state 不是 SnapshotUnavailable：' + $result.Snapshot.state)
        Assert-True ($result.Snapshot.error.Contains('field=rate_limit.secondary_window; expected=Object')) ('error 不符：' + $result.Snapshot.error)
        Assert-True ($result.StdOut -notmatch 'secondary_window=none') '不應輸出 secondary_window=none。'
        $true
    }
    Test-Case Q07 {
        $incomplete = New-QuotaWindow -UsedPercent 50 -WindowSeconds 604800 -ResetAfterSeconds 432000
        $incomplete.Remove('used_percent')
        $result = Invoke-QuotaCase -Response (New-QuotaApiResponse -Secondary $incomplete)
        Assert-True ($result.ExitCode -eq 1) ('結束碼不是 1：' + $result.ExitCode)
        Assert-True ($result.Snapshot.state -eq 'SnapshotUnavailable') ('state 不是 SnapshotUnavailable：' + $result.Snapshot.state)
        Assert-True ($result.Snapshot.error.Contains('rate_limit.secondary_window.used_percent')) ('error 不符：' + $result.Snapshot.error)
        $true
    }
    Test-Case Q08 {
        $primaryRejected = Invoke-QuotaCase -Response (New-QuotaApiResponse -Secondary $null -LimitReached $true -ReachedType 'primary')
        Assert-True ($primaryRejected.ExitCode -eq 1) ('primary 拒絕的結束碼不是 1：' + $primaryRejected.ExitCode)
        Assert-True ($primaryRejected.Snapshot.state -eq 'ServiceRejected') ('primary 拒絕的 state 不符：' + $primaryRejected.Snapshot.state)
        Assert-True ($primaryRejected.Snapshot.service_rejection.window -eq 'primary') 'primary 拒絕的 window 不是 primary。'
        Assert-True ($null -ne $primaryRejected.Snapshot.service_rejection.resets_at) 'primary 拒絕的 resets_at 不應為 null。'

        $secondaryRejected = Invoke-QuotaCase -Response (New-QuotaApiResponse -Secondary $null -LimitReached $true -ReachedType 'secondary')
        Assert-True ($secondaryRejected.ExitCode -eq 1) ('secondary 拒絕的結束碼不是 1：' + $secondaryRejected.ExitCode)
        Assert-True ($secondaryRejected.Snapshot.state -eq 'ServiceRejected') ('secondary 拒絕的 state 不符：' + $secondaryRejected.Snapshot.state)
        Assert-True ($secondaryRejected.Snapshot.service_rejection.window -eq 'secondary') 'secondary 拒絕的 window 不是 secondary。'
        Assert-True ($null -eq $secondaryRejected.Snapshot.service_rejection.resets_at) 'secondary 拒絕的 resets_at 應為 null。'
        Assert-True ($secondaryRejected.StdErr.Contains('QuotaApiServiceRejected')) ('stderr 缺少 QuotaApiServiceRejected：' + $secondaryRejected.StdErr)
        $true
    }
    Test-Case Q09 {
        foreach ($path in @($quotaScriptPath, $lineStatusPath, $selfPath)) {
            $bytes = [IO.File]::ReadAllBytes($path)
            Assert-True ($bytes.Length -gt 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ($path + ' 不是 UTF-8 with BOM。')
            $tokens = $null
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            Assert-True ($errors.Count -eq 0) ($path + ' 語法錯誤：' + (($errors | ForEach-Object { $_.Message }) -join '; '))
        }
        $true
    }

    . $lineStatusPath
    $fakeCodexHome = Join-Path $tempRoot 'fake-codex-home'
    $noWeeklyBody = "Write-Output 'primary_used_percent=60'; Write-Output 'primary_remaining_percent=40'; Write-Output 'primary_days_to_reset=0.1'; Write-Output 'primary_window_minutes=43200'; Write-Output 'primary_window_days=30'; Write-Output 'primary_resets_at=1'; Write-Output 'primary_resets_at_local=2026-11-10 13:16'; Write-Output 'primary_source_file=fixture'; Write-Output 'secondary_window=none'; exit 0"
    $withWeeklyBody = $noWeeklyBody.Replace("Write-Output 'secondary_window=none'", "Write-Output 'secondary_remaining_percent=70'; Write-Output 'secondary_resets_at_local=2026-11-12 01:00'").Replace("primary_window_minutes=43200", "primary_window_minutes=300")

    Test-Case L01 {
        $fake = New-FakeQuotaScript -Path (Join-Path $tempRoot 'fake-no-weekly.ps1') -Body $noWeeklyBody
        $summary = Get-QuotaSummary -Name 'a' -CodexHome $fakeCodexHome -QuotaScriptPath $fake
        Assert-True ($summary.State -eq 'ok') ('State 不是 ok：' + $summary.State + ' ' + $summary.Error)
        Assert-True ($summary.PrimaryRemaining -eq 40) ('PrimaryRemaining 不是 40：' + $summary.PrimaryRemaining)
        Assert-True ($summary.PrimaryWindowMinutes -eq 43200) ('PrimaryWindowMinutes 不是 43200：' + $summary.PrimaryWindowMinutes)
        Assert-True ($null -eq $summary.SecondaryRemaining -and $null -eq $summary.SecondaryResetsAtLocal) 'Secondary 欄位應為 null。'
        Assert-True ($null -eq $summary.Error) 'Error 應為 null。'
        $true
    }
    Test-Case L02 {
        $fakeNone = New-FakeQuotaScript -Path (Join-Path $tempRoot 'fake-no-weekly-json.ps1') -Body $noWeeklyBody
        $fakeWith = New-FakeQuotaScript -Path (Join-Path $tempRoot 'fake-with-weekly-json.ps1') -Body $withWeeklyBody
        $none = Get-QuotaSummary -Name 'a' -CodexHome $fakeCodexHome -QuotaScriptPath $fakeNone
        $with = Get-QuotaSummary -Name 'a' -CodexHome $fakeCodexHome -QuotaScriptPath $fakeWith
        $json = $none | ConvertTo-Json -Depth 4
        Assert-True ($json -match '"SecondaryRemaining":\s+null') 'JSON 應含 SecondaryRemaining: null。'
        Assert-True ($json -match '"SecondaryResetsAtLocal":\s+null') 'JSON 應含 SecondaryResetsAtLocal: null。'
        Assert-True (($none.PSObject.Properties.Name -join ',') -eq ($with.PSObject.Properties.Name -join ',')) '欄位名稱集合與有 secondary 時不同。'
        Assert-True (($none.PSObject.Properties.Name -join ',') -eq 'Name,CodexHome,State,PrimaryRemaining,PrimaryResetsAtLocal,PrimaryWindowMinutes,SecondaryRemaining,SecondaryResetsAtLocal,Error,ErrorKind,ErrorReason') ('欄位名稱集合不符：' + ($none.PSObject.Properties.Name -join ','))
        Assert-True ($json -match '"PrimaryWindowMinutes":\s+43200') 'JSON 應含 PrimaryWindowMinutes: 43200。'
        Assert-True ($none.PrimaryWindowMinutes -eq 43200 -and $with.PrimaryWindowMinutes -eq 300) 'PrimaryWindowMinutes 與假額度輸出不符。'
        Assert-True ($with.SecondaryRemaining -eq 70 -and $with.SecondaryResetsAtLocal -eq '2026-11-12 01:00') '有 secondary 時的彙整不符。'
        $true
    }
    Test-Case L03 {
        Assert-True ((Format-QuotaWindowText -State 'ok' -Remaining $null -ResetsAtLocal $null -WindowName 'secondary') -eq '無週視窗') 'ok、null、secondary 應為 無週視窗。'
        Assert-True ((Format-QuotaWindowText -State 'ok' -Remaining 60 -ResetsAtLocal '2026-11-10 13:16' -WindowName 'secondary') -eq '60% (reset 2026-11-10 13:16)') '有值時格式不符。'
        Assert-True ((Format-QuotaWindowText -State 'unknown' -Remaining $null -ResetsAtLocal $null -WindowName 'secondary') -eq '-') 'unknown、null、secondary 應為 -。'
        Assert-True ((Format-QuotaWindowText -State 'ok' -Remaining $null -ResetsAtLocal $null -WindowName 'primary') -eq '-') 'ok、null、primary 應為 -。'
        $true
    }
    Test-Case L04 {
        $fake = New-FakeQuotaScript -Path (Join-Path $tempRoot 'fake-failing.ps1') -Body "[Console]::Error.WriteLine('Get-CodexQuota.ps1 失敗：QuotaApiFailure; category=Timeout; timeout_seconds=30'); exit 1"
        $summary = Get-QuotaSummary -Name 'a' -CodexHome $fakeCodexHome -QuotaScriptPath $fake
        Assert-True ($summary.State -eq 'unknown') ('State 不是 unknown：' + $summary.State)
        $text = Format-QuotaWindowText -State $summary.State -Remaining $summary.SecondaryRemaining -ResetsAtLocal $summary.SecondaryResetsAtLocal -WindowName 'secondary'
        Assert-True ($text -eq '-') ('失敗帳號的 Secondary 欄文字不是 -：' + $text)
        $true
    }
    Test-Case L05 {
        $bundle = Join-Path $tempRoot 'bundle'
        $emptyRoot = Join-Path $tempRoot 'empty-root'
        New-Item -ItemType Directory -Path $bundle, $emptyRoot -Force | Out-Null
        Copy-Item -LiteralPath $lineStatusPath -Destination (Join-Path $bundle 'Get-LineStatus.ps1')
        $null = New-FakeQuotaScript -Path (Join-Path $bundle 'Get-CodexQuota.ps1') -Body $noWeeklyBody
        $machine = [ordered]@{ codex_accounts = @([ordered]@{ name = 'degraded'; codex_home = $fakeCodexHome }) } | ConvertTo-Json -Depth 4
        $machinePath = Join-Path $bundle 'machine.json'
        [IO.File]::WriteAllText($machinePath, $machine, $utf8NoBom)
        $tableCommand = '[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); & ''{0}'' -WorkRoot ''{1}'' -MachineConfigPath ''{2}''; exit $LASTEXITCODE' -f (Join-Path $bundle 'Get-LineStatus.ps1'), $emptyRoot, $machinePath
        $table = Invoke-HostProcess -Arguments @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $tableCommand)
        Assert-True ($table.ExitCode -eq 0) ('表格輸出結束碼不是 0：' + $table.ExitCode + ' ' + $table.StdErr)
        Assert-True ($table.StdOut -match '(?m)^degraded\s+ok\s+40% \(reset 2026-11-10 13:16\)\s+無週視窗') ('表格列不符：' + $table.StdOut)
        $null = New-FakeQuotaScript -Path (Join-Path $bundle 'Get-CodexQuota.ps1') -Body "[Console]::Error.WriteLine('Get-CodexQuota.ps1 失敗：QuotaApiFailure; category=Timeout; timeout_seconds=30'); exit 1"
        $failure = Invoke-HostProcess -Arguments @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $tableCommand)
        Assert-True ($failure.ExitCode -eq 0) ('失敗帳號的表格輸出結束碼不是 0：' + $failure.ExitCode)
        Assert-True ($failure.StdOut -notmatch '無週視窗') '查詢失敗的帳號不應顯示無週視窗。'
        $true
    }
}
catch {
    $failed++
    Write-Output "FAIL setup $($_.Exception.Message)"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
Write-Output "PASSED: $passed"
Write-Output "FAILED: $failed"
if ($failed -gt 0) { exit 1 }
exit 0
