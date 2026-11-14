#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$runtimePath = Join-Path $scriptsRoot 'dispatch\common-runtime.ps1'
$startLifecyclePath = Join-Path $scriptsRoot 'dispatch\start-lifecycle.ps1'
$dispatchLifecyclePath = Join-Path $scriptsRoot 'dispatch\dispatch-lifecycle.ps1'
. $runtimePath
. $startLifecyclePath

$script:failed = 0
$script:passed = 0
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$hostPath = [Environment]::ProcessPath
$sleepSeconds = 30
$positiveLimitSeconds = 10
$negativeLimitSeconds = 20
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('fx-handle-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$null = New-Item -ItemType Directory -Path $tempRoot -Force
$startedPids = New-Object System.Collections.Generic.List[int]

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

function Stop-FixtureProcessTree {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return }
    $null = & taskkill.exe /PID $ProcessId /T /F 2>&1
}

# 探針。direct 模式與 Start 相同：New-ProcessStartInfo（UseShellExecute=false、不轉向）啟動 cmd.exe 執行 launcher，
# launcher 只把子程序自己的 stdio 轉向到檔案，探針啟動後立即結束。
# outer 模式與 Invoke-DispatchAttemptProcess 相同：重導 stdout／stderr、UseShellExecute=false 啟動中層探針（direct guarded），
# 讀完輸出並等待中層結束後才結束。
$probeText = @'
param([string]$RuntimePath, [string]$Dir, [string]$Mode, [int]$Seconds, [string]$PwshPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $RuntimePath
if ($Mode -eq 'outer-guarded' -or $Mode -eq 'outer-unguarded') {
    $argumentList = @('-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-RuntimePath', $RuntimePath, '-Dir', $Dir, '-Mode', 'guarded', '-Seconds', [string]$Seconds, '-PwshPath', $PwshPath)
    $middleInfo = New-Object System.Diagnostics.ProcessStartInfo
    $middleInfo.FileName = $PwshPath
    $middleInfo.Arguments = (@($argumentList | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    $middleInfo.UseShellExecute = $false
    $middleInfo.RedirectStandardOutput = $true
    $middleInfo.RedirectStandardError = $true
    $middleInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
    $middleInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
    $middle = New-Object System.Diagnostics.Process
    $middle.StartInfo = $middleInfo
    if ($Mode -eq 'outer-guarded') {
        $null = Invoke-WithoutStdHandleInheritance -ScriptBlock { $middle.Start() }
    }
    else {
        $null = $middle.Start()
    }
    $stdoutTask = $middle.StandardOutput.ReadToEndAsync()
    $stderrTask = $middle.StandardError.ReadToEndAsync()
    $middle.WaitForExit()
    Write-Output $stdoutTask.Result.Trim()
    if ($middle.ExitCode -ne 0) { Write-Output ('MIDDLE-STDERR=' + $stderrTask.Result) }
    exit $middle.ExitCode
}
$launcher = Join-Path $Dir 'launch.cmd'
$cmdText = '@echo off' + "`r`n" + 'call "' + $PwshPath + '" -NoProfile -NonInteractive -Command "Start-Sleep ' + $Seconds + '" < nul > "' + (Join-Path $Dir 'ev.txt') + '" 2> "' + (Join-Path $Dir 'er.txt') + '"' + "`r`n" + 'exit /b 0' + "`r`n"
[IO.File]::WriteAllText($launcher, $cmdText, (New-Object Text.UTF8Encoding($false)))
$startInfo = New-ProcessStartInfo -FileName (Join-Path $env:SystemRoot 'System32\cmd.exe') -WorkingDirectory $Dir -Arguments @('/d', '/c', 'call', $launcher)
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $startInfo
if ($Mode -eq 'guarded') {
    $started = Invoke-WithoutStdHandleInheritance -ScriptBlock { $process.Start() }
}
else {
    $started = $process.Start()
}
if (-not $started) { throw 'Start 失敗' }
Write-Output ('PID=' + $process.Id)
exit 0
'@

# 還原探針：記錄三個 std handle 的 inherit 旗標（-1 表示無有效 handle）。
$restoreProbeText = @'
param([string]$RuntimePath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $RuntimePath
$null = Initialize-DispatchStdHandleGuard
function Get-Flags { return @(@(-10, -11, -12) | ForEach-Object { [DispatchStdHandleGuard]::GetInheritFlag($_) }) }
$before = Get-Flags
$script:insideFlags = $null
$script:insideThrow = $null
$returned = Invoke-WithoutStdHandleInheritance -ScriptBlock { $script:insideFlags = Get-Flags; 42 }
$inside = $script:insideFlags
$afterNormal = Get-Flags
$thrown = $null
$thrownType = $null
try {
    Invoke-WithoutStdHandleInheritance -ScriptBlock { $script:insideThrow = Get-Flags; throw 'boom-fixture' }
}
catch {
    $thrown = $_.Exception.Message
    $thrownType = $_.Exception.GetType().FullName
}
$afterThrow = Get-Flags
[ordered]@{
    before = $before; inside = $inside; afterNormal = $afterNormal; returned = $returned
    insideThrow = @($script:insideThrow); afterThrow = $afterThrow; thrown = $thrown; thrownType = $thrownType
} | ConvertTo-Json -Compress
exit 0
'@

$probePath = Join-Path $tempRoot 'probe.ps1'
$restoreProbePath = Join-Path $tempRoot 'restore-probe.ps1'
[IO.File]::WriteAllText($probePath, $probeText, $utf8NoBom)
[IO.File]::WriteAllText($restoreProbePath, $restoreProbeText, $utf8NoBom)

function Invoke-HandleProbe {
    param([ValidateSet('guarded', 'unguarded', 'outer-guarded', 'outer-unguarded')][string]$Mode, [int]$Seconds)
    $dir = Join-Path $tempRoot ($Mode + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $null = New-Item -ItemType Directory -Path $dir -Force
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $out = & $hostPath -NoProfile -NonInteractive -File $probePath -RuntimePath $runtimePath -Dir $dir -Mode $Mode -Seconds $Seconds -PwshPath $hostPath 2>&1
    $elapsed = $stopwatch.Elapsed.TotalSeconds
    $exitCode = $LASTEXITCODE
    $pidLine = @($out | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^PID=\d+$' })
    $startedPid = if ($pidLine.Count -gt 0) { [int]$pidLine[0].Substring(4) } else { 0 }
    if ($startedPid -gt 0) { $startedPids.Add($startedPid) }
    $alive = ($startedPid -gt 0) -and ($null -ne (Get-Process -Id $startedPid -ErrorAction SilentlyContinue))
    return [pscustomobject]@{ Elapsed = $elapsed; ExitCode = $exitCode; Pid = $startedPid; AliveAfterReturn = $alive; Output = (@($out) -join "`n") }
}

function Assert-AllStartCallsWrapped {
    param([string]$Path, [string]$FunctionName, [int]$MinimumCount)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ('解析 ' + $Path + ' 失敗。') }
    $scope = $ast
    if (-not [string]::IsNullOrEmpty($FunctionName)) {
        $function = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $FunctionName }, $true))
        if ($function.Count -ne 1) { throw ('找不到函式 ' + $FunctionName) }
        $scope = $function[0]
    }
    $calls = @($scope.FindAll({
                param($node)
                $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                $node.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
                $node.Member.Value -ceq 'Start'
            }, $true))
    if ($calls.Count -lt $MinimumCount) { throw ('預期至少 ' + $MinimumCount + ' 處 .Start()，實際 ' + $calls.Count) }
    foreach ($call in $calls) {
        $wrapped = $false
        $parent = $call.Parent
        while ($null -ne $parent) {
            if ($parent -is [Management.Automation.Language.ScriptBlockExpressionAst] -and
                $parent.Parent -is [Management.Automation.Language.CommandAst] -and
                ([string]$parent.Parent.GetCommandName() -ceq 'Invoke-WithoutStdHandleInheritance')) {
                $wrapped = $true
                break
            }
            $parent = $parent.Parent
        }
        if (-not $wrapped) { throw ($Path + ' 第 ' + $call.Extent.StartLineNumber + ' 行的 .Start() 未包在 Invoke-WithoutStdHandleInheritance 內。') }
    }
    return $true
}

# 產生 launcher 內容：覆寫平台判定與檔案、命令副作用後呼叫 New-CodexLauncher 的非 Windows 分支，取得實際組出的 .sh 內容。
function Get-GeneratedShLauncherLine {
    param([string]$ExitSidecarPath)
    $script:capturedLauncherContent = $null
    $lines = & {
        function Test-IsWindowsPlatform { return $false }
        function Write-Utf8NoBom { param($Path, $SourceRoot, $ExecutionRoot, $TargetPath, $Content) $script:capturedLauncherContent = $Content }
        function Invoke-ExternalCommand { param($FileName, $WorkingDirectory, $Arguments) return $null }
        function Get-CommandPath { param($Name) return ('/usr/bin/' + $Name) }
        $null = New-CodexLauncher -CodexExecutable '/usr/bin/codex' -CodexArguments @('exec', '--json') -PromptPath '/tmp/p.md' -EventPath '/tmp/e.jsonl' -ErrorPath '/tmp/err.txt' -HistoryRoot '/tmp/h' -LauncherPath '/tmp/h/launch.sh' -ExitSidecarPath $ExitSidecarPath -LineSlug 'fx-line' -DispatchSlug 'fx-job' -RunId 'run-1' -SourceRoot '' -ExecutionRoot '' -TargetPath @()
    }
    if ([string]::IsNullOrEmpty($script:capturedLauncherContent)) { throw '未取得 launcher 內容。' }
    return @([regex]::Split($script:capturedLauncherContent, '\r?\n') | Where-Object { $_.Length -gt 0 })
}

try {
    $onWindows = Test-IsWindowsPlatform
    $positive = $null
    $negative = $null
    $nestedPositive = $null
    $nestedNegative = $null
    if ($onWindows) {
        $positive = Invoke-HandleProbe -Mode guarded -Seconds $sleepSeconds
        Stop-FixtureProcessTree -ProcessId $positive.Pid
        $negative = Invoke-HandleProbe -Mode unguarded -Seconds $sleepSeconds
        Stop-FixtureProcessTree -ProcessId $negative.Pid
        $nestedPositive = Invoke-HandleProbe -Mode outer-guarded -Seconds $sleepSeconds
        Stop-FixtureProcessTree -ProcessId $nestedPositive.Pid
        $nestedNegative = Invoke-HandleProbe -Mode outer-unguarded -Seconds $sleepSeconds
        Stop-FixtureProcessTree -ProcessId $nestedNegative.Pid
        Write-Output ('INFO direct guarded={0:N2}s alive={1}; direct unguarded={2:N2}s; nested guarded={3:N2}s alive={4}; nested unguarded={5:N2}s' -f $positive.Elapsed, $positive.AliveAfterReturn, $negative.Elapsed, $nestedPositive.Elapsed, $nestedPositive.AliveAfterReturn, $nestedNegative.Elapsed)
    }

    Test-Case ('HANDLE-INHERIT-POSITIVE 經 Invoke-WithoutStdHandleInheritance 啟動後呼叫端 ' + $positiveLimitSeconds + ' 秒內返回') {
        if (-not $onWindows) { return $true }
        if ($positive.ExitCode -ne 0 -or $positive.Pid -le 0) { throw ('探針失敗：' + $positive.Output) }
        $positive.Elapsed -lt $positiveLimitSeconds -and $positive.AliveAfterReturn
    }
    Test-Case ('HANDLE-INHERIT-NEGATIVE 不經函式啟動時呼叫端被阻擋超過 ' + $negativeLimitSeconds + ' 秒（證明測試可偵測回歸）') {
        if (-not $onWindows) { return $true }
        if ($negative.ExitCode -ne 0 -or $negative.Pid -le 0) { throw ('探針失敗：' + $negative.Output) }
        $negative.Elapsed -gt $negativeLimitSeconds
    }
    Test-Case ('HANDLE-INHERIT-NESTED-POSITIVE 重導啟動中層（外層經包裝）時最外層呼叫端 ' + $positiveLimitSeconds + ' 秒內返回') {
        if (-not $onWindows) { return $true }
        if ($nestedPositive.ExitCode -ne 0 -or $nestedPositive.Pid -le 0) { throw ('探針失敗：' + $nestedPositive.Output) }
        $nestedPositive.Elapsed -lt $positiveLimitSeconds -and $nestedPositive.AliveAfterReturn
    }
    Test-Case ('HANDLE-INHERIT-NESTED-NEGATIVE 重導啟動中層（外層未包裝）時最外層呼叫端被阻擋超過 ' + $negativeLimitSeconds + ' 秒') {
        if (-not $onWindows) { return $true }
        if ($nestedNegative.ExitCode -ne 0 -or $nestedNegative.Pid -le 0) { throw ('探針失敗：' + $nestedNegative.Output) }
        $nestedNegative.Elapsed -gt $negativeLimitSeconds
    }
    Test-Case 'HANDLE-INHERIT-CLEANUP 測試啟動的子程序樹已全部結束' {
        foreach ($startedPid in $startedPids) {
            $deadline = [datetime]::UtcNow.AddSeconds(10)
            while ($null -ne (Get-Process -Id $startedPid -ErrorAction SilentlyContinue) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
            if ($null -ne (Get-Process -Id $startedPid -ErrorAction SilentlyContinue)) { throw ('PID ' + $startedPid + ' 未結束。') }
        }
        $true
    }
    Test-Case 'HANDLE-INHERIT-RESTORE 旗標在函式內清除、結束與例外後皆還原，例外原樣上拋' {
        if (-not $onWindows) { return $true }
        $raw = & $hostPath -NoProfile -NonInteractive -File $restoreProbePath -RuntimePath $runtimePath 2>&1
        if ($LASTEXITCODE -ne 0) { throw ('還原探針失敗：' + (@($raw) -join "`n")) }
        $json = @($raw | ForEach-Object { [string]$_ } | Where-Object { $_.StartsWith('{') })[0] | ConvertFrom-Json
        $before = @($json.before)
        if (-not ($before -contains 1)) { throw '前置條件不成立：呼叫端沒有可繼承的 std handle，無法驗證還原。' }
        $insideOk = $true
        for ($i = 0; $i -lt 3; $i++) {
            if ($before[$i] -eq 1 -and @($json.inside)[$i] -ne 0) { $insideOk = $false }
            if ($before[$i] -eq 1 -and @($json.insideThrow)[$i] -ne 0) { $insideOk = $false }
        }
        $insideOk -and
            ((@($json.afterNormal) -join ',') -ceq ($before -join ',')) -and
            ((@($json.afterThrow) -join ',') -ceq ($before -join ',')) -and
            ([int]$json.returned -eq 42) -and
            ([string]$json.thrown -ceq 'boom-fixture') -and
            ([string]$json.thrownType -ceq 'System.Management.Automation.RuntimeException')
    }
    Test-Case 'HANDLE-INHERIT-STATIC-START start-lifecycle.ps1 的每個 .Start() 都位於 Invoke-WithoutStdHandleInheritance 的 ScriptBlock 內' {
        Assert-AllStartCallsWrapped -Path $startLifecyclePath -FunctionName '' -MinimumCount 2
    }
    Test-Case 'HANDLE-INHERIT-STATIC-ATTEMPT dispatch-lifecycle.ps1 的 Invoke-DispatchAttemptProcess 之 .Start() 位於 Invoke-WithoutStdHandleInheritance 的 ScriptBlock 內' {
        Assert-AllStartCallsWrapped -Path $dispatchLifecyclePath -FunctionName 'Invoke-DispatchAttemptProcess' -MinimumCount 1
    }
    Test-Case 'HANDLE-INHERIT-INIT-BEFORE-LOCK Invoke-Start 在 Invoke-DispatchAdmissionStart 之前呼叫 Initialize-DispatchStdHandleGuard' {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($startLifecyclePath, [ref]$tokens, [ref]$errors)
        $function = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-Start' }, $true))[0]
        $commands = @($function.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
        $init = @($commands | Where-Object { [string]$_.GetCommandName() -ceq 'Initialize-DispatchStdHandleGuard' })
        $admission = @($commands | Where-Object { [string]$_.GetCommandName() -ceq 'Invoke-DispatchAdmissionStart' })
        $launcherCall = @($commands | Where-Object { [string]$_.GetCommandName() -ceq 'New-CodexLauncher' })
        if ($init.Count -ne 1 -or $admission.Count -lt 1 -or $launcherCall.Count -ne 1) { throw '找不到預期的呼叫。' }
        $init[0].Extent.StartOffset -lt $admission[0].Extent.StartOffset -and $init[0].Extent.StartOffset -lt $launcherCall[0].Extent.StartOffset
    }
    Test-Case 'HANDLE-INHERIT-SH-LAUNCHER-SIDECAR 有 sidecar 的 .sh launcher：shebang 後緊接 exec 轉向，codex 命令行不加 exec 前綴' {
        $lines = Get-GeneratedShLauncherLine -ExitSidecarPath '/tmp/h/exit.json'
        $lines[0] -ceq '#!/bin/sh' -and
            $lines[1] -ceq 'exec </dev/null >/dev/null 2>&1' -and
            $lines[2].StartsWith("'/usr/bin/codex' ", [StringComparison]::Ordinal) -and
            $lines[2].Contains("< '/tmp/p.md' > '/tmp/e.jsonl' 2> '/tmp/err.txt'") -and
            @($lines | Where-Object { $_ -ceq 'exec </dev/null >/dev/null 2>&1' }).Count -eq 1 -and
            $lines.Count -gt 3
    }
    Test-Case 'HANDLE-INHERIT-SH-LAUNCHER-NOSIDECAR 無 sidecar 的 .sh launcher：shebang 後緊接 exec 轉向，codex 命令行以 exec 取代 shell' {
        $lines = Get-GeneratedShLauncherLine -ExitSidecarPath ''
        $lines.Count -eq 3 -and
            $lines[0] -ceq '#!/bin/sh' -and
            $lines[1] -ceq 'exec </dev/null >/dev/null 2>&1' -and
            $lines[2].StartsWith("exec '/usr/bin/codex' ", [StringComparison]::Ordinal) -and
            $lines[2].Contains("< '/tmp/p.md' > '/tmp/e.jsonl' 2> '/tmp/err.txt'")
    }
}
finally {
    foreach ($startedPid in $startedPids) { Stop-FixtureProcessTree -ProcessId $startedPid }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output "PASSED: $($script:passed)"
Write-Output "FAILED: $($script:failed)"
if ($script:failed -gt 0) { exit 1 }
exit 0
