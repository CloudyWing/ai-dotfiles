#Requires -Version 7.0
<#
.SYNOPSIS
逐一以子行程執行 scripts\tests\Test-CodexRun*.ps1（排除自身），加總耗時。

.DESCRIPTION
全部通過且總耗時小於 TimeLimitSeconds（預設 600）時結束碼 0，否則結束碼 1 並列出失敗檔與耗時。
任一檔案超過剩餘時間時終止該檔與其子行程並判為超時。這些測試都不呼叫服務端。
#>
[CmdletBinding()]
param(
    [ValidateRange(10, 3600)]
    [int]$TimeLimitSeconds = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)

$self = $MyInvocation.MyCommand.Path
$files = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Test-CodexRun*.ps1' -File | Where-Object { $_.FullName -ne $self } | Sort-Object -Property Name)
$hostPath = [Environment]::ProcessPath
$total = [Diagnostics.Stopwatch]::StartNew()
$results = New-Object 'System.Collections.Generic.List[object]'

foreach ($file in $files) {
    $remaining = $TimeLimitSeconds - $total.Elapsed.TotalSeconds
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $hostPath
    foreach ($item in @('-NoProfile', '-File', $file.FullName)) { [void]$startInfo.ArgumentList.Add($item) }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timedOut = $false
    if ($remaining -le 0 -or -not $process.WaitForExit([int][Math]::Max(1, $remaining * 1000))) {
        $timedOut = $true
        try { $process.Kill($true) } catch { $null = $_ }
        # 終止後最多再等 10 秒，不無限期阻塞。
        $null = $process.WaitForExit(10000)
    }
    else {
        $process.WaitForExit()
    }
    $exitCode = if ($process.HasExited) { $process.ExitCode } else { -1 }
    # 孫行程若握著輸出管線，Task.Result 會無限期阻塞。只在兩個工作都完成時才取結果，逾時的輸出直接放棄。
    $drained = [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000)
    $output = if ($drained) { $stdoutTask.Result + $stderrTask.Result } else { '（輸出管線未在 5 秒內關閉，略過輸出）' }
    $process.Dispose()
    $stopwatch.Stop()
    $status = if ($timedOut) { 'TIMEOUT' } elseif ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
    $results.Add([pscustomobject]@{ Name = $file.Name; Status = $status; ExitCode = $exitCode; Seconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1) })
    Write-Output ('{0} {1} exit={2} {3}s' -f $status, $file.Name, $exitCode, [math]::Round($stopwatch.Elapsed.TotalSeconds, 1))
    if ($status -ne 'PASS') {
        $lines = @($output -split '\r?\n' | Where-Object { $_ -match '^FAIL |^Error|例外|錯誤' } | Select-Object -First 15)
        foreach ($line in $lines) { Write-Output ('  ' + $line) }
    }
}

$total.Stop()
$failed = @($results | Where-Object { $_.Status -ne 'PASS' })
$overTime = $total.Elapsed.TotalSeconds -ge $TimeLimitSeconds
Write-Output ('TOTAL {0}s，檔案 {1} 個，失敗 {2} 個，時限 {3}s' -f [math]::Round($total.Elapsed.TotalSeconds, 1), $results.Count, $failed.Count, $TimeLimitSeconds)
if ($results.Count -eq 0) {
    Write-Output 'FAILED: 找不到任何 Test-CodexRun*.ps1'
    exit 1
}
if ($failed.Count -gt 0 -or $overTime) {
    foreach ($item in $failed) { Write-Output ('FAILED: ' + $item.Name + ' (' + $item.Status + ', ' + $item.Seconds + 's)') }
    if ($overTime) { Write-Output ('FAILED: 總耗時超過 ' + $TimeLimitSeconds + ' 秒') }
    exit 1
}
Write-Output 'ALL PASSED'
exit 0
