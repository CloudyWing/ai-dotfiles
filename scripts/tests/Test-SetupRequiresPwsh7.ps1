#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$setupPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\Setup-AIGlobalConfig.ps1')).Path
$moduleNames = @('common-runtime.ps1', 'git-baseline.ps1', 'dispatch-evidence.ps1')
$modulePaths = @($moduleNames | ForEach-Object { (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot ('..\dispatch\' + $_))).Path })
$windowsPowerShellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$pwshCommand = Get-Command -Name 'pwsh' -ErrorAction Stop
$pwshPath = if ([string]::IsNullOrWhiteSpace($pwshCommand.Source)) { $pwshCommand.Path } else { $pwshCommand.Source }
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('setup-requires7-' + [guid]::NewGuid().ToString('N'))
$failed = 0
$passed = 0

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

function ConvertTo-ArgumentText {
    param([string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-HostProcess {
    param(
        [Parameter(Mandatory)][string]$HostPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [hashtable]$EnvironmentVariables = @{}
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $HostPath
    $startInfo.Arguments = ($Arguments | ForEach-Object { ConvertTo-ArgumentText -Value $_ }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($key in $EnvironmentVariables.Keys) { $startInfo.EnvironmentVariables[[string]$key] = [string]$EnvironmentVariables[$key] }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) {
            try { $process.Kill($true) } catch { }
            throw "子程序逾時：$HostPath"
        }
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdoutTask.GetAwaiter().GetResult()
            StdErr   = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-FileTextWithoutBom {
    param([string]$Path)
    return [IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
}

$setupAst = $null
$versionBlock = $null
try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $tokens = $null
    $parseErrors = $null
    $setupAst = [System.Management.Automation.Language.Parser]::ParseFile($setupPath, [ref]$tokens, [ref]$parseErrors)
    Assert-True (@($parseErrors).Count -eq 0) ('pwsh 解析 Setup 發生語法錯誤：' + (@($parseErrors | ForEach-Object { $_.Message }) -join '；'))
    $versionBlocks = @($setupAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text.Contains('$PSVersionTable.PSVersion.Major')
            }, $true))
    Assert-True ($versionBlocks.Count -ge 1) 'Setup 找不到含 $PSVersionTable.PSVersion.Major 的判斷區塊。'
    $versionBlock = $versionBlocks | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1

    Test-Case 'S01-windows-powershell-parse' {
        Assert-True (Test-Path -LiteralPath $windowsPowerShellPath -PathType Leaf) ('找不到 Windows PowerShell：' + $windowsPowerShellPath)
        $parseCommand = '$errors = $null; $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($env:SETUP_PATH_UNDER_TEST, [ref]$tokens, [ref]$errors); Write-Output (''ERRORS='' + @($errors).Count); foreach ($e in @($errors)) { Write-Output ($e.Extent.StartLineNumber.ToString() + '':'' + $e.Message) }'
        $result = Invoke-HostProcess -HostPath $windowsPowerShellPath -Arguments @('-NoProfile', '-NonInteractive', '-Command', $parseCommand) -EnvironmentVariables @{ SETUP_PATH_UNDER_TEST = $setupPath }
        Assert-True ($result.ExitCode -eq 0 -and $result.StdOut -match '(?m)^ERRORS=0\s*$') ('Windows PowerShell 5.1 解析 Setup 有語法錯誤：' + $result.StdOut + $result.StdErr)
        $true
    }

    Test-Case 'S02-windows-powershell-rejected-with-guidance' {
        Assert-True (Test-Path -LiteralPath $windowsPowerShellPath -PathType Leaf) ('找不到 Windows PowerShell：' + $windowsPowerShellPath)
        $fakeProfile = Join-Path $tempRoot 'userprofile'
        New-Item -ItemType Directory -Path $fakeProfile | Out-Null
        $result = Invoke-HostProcess -HostPath $windowsPowerShellPath -Arguments @('-NoProfile', '-NonInteractive', '-File', $setupPath, '-WhatIf') -EnvironmentVariables @{ USERPROFILE = $fakeProfile }
        $combined = $result.StdOut + "`n" + $result.StdErr
        Assert-True ($result.ExitCode -eq 1) ('Windows PowerShell 5.1 執行 Setup 的結束碼應為 1：' + $result.ExitCode + [Environment]::NewLine + $combined)
        # 重新導向的 stderr 以 80 欄折行，標記可能被換行切開，比對前移除全部空白。
        $compact = $combined -replace '\s', ''
        Assert-True ($compact.Contains('wingetinstallMicrosoft.PowerShell')) ('輸出缺少安裝命令標記：' + $combined)
        Assert-True ($compact.Contains('PowerShell7')) ('輸出缺少 PowerShell 7 標記：' + $combined)
        Assert-True (-not $combined.Contains('ScriptRequiresUnmatchedPSVersion')) ('Setup 不應被 #Requires 在執行前拒絕：' + $combined)
        # Windows PowerShell 5.1 宿主啟動時自行建立空的 AppData 目錄，Setup 的建立目標（.ai-agents、.claude、.codex、.agents 與任何檔案）不得出現。
        $allowedEmptyDirectories = @((Join-Path $fakeProfile 'AppData'), (Join-Path $fakeProfile 'AppData\Roaming'))
        $leftovers = @(Get-ChildItem -LiteralPath $fakeProfile -Force -Recurse -ErrorAction SilentlyContinue | Where-Object { -not ($_.PSIsContainer -and $allowedEmptyDirectories -contains $_.FullName) })
        Assert-True ($leftovers.Count -eq 0) ('暫存 USERPROFILE 執行後除宿主自建的空 AppData 目錄外應為空：' + (($leftovers | ForEach-Object { $_.FullName }) -join ', '))
        $true
    }

    Test-Case 'S03-version-check-precedes-dot-source-and-admin-check' {
        $dotSourceOffsets = @()
        foreach ($moduleName in $moduleNames) {
            $dotSources = @($setupAst.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot -and
                        $node.Extent.Text.Contains($moduleName)
                    }, $true))
            Assert-True ($dotSources.Count -eq 1) ('Setup 應恰有一個 dot-source ' + $moduleName + '，實際 ' + $dotSources.Count)
            $dotSourceOffsets += [int]$dotSources[0].Extent.StartOffset
        }
        $adminChecks = @($setupAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Extent.Text -ceq 'IsInRole'
                }, $true))
        Assert-True ($adminChecks.Count -ge 1) 'Setup 找不到系統管理員檢查（IsInRole）。'
        $versionStart = [int]$versionBlock.Extent.StartOffset
        foreach ($offset in $dotSourceOffsets) {
            Assert-True ($versionStart -lt $offset) ('版本判斷區塊必須早於 dot-source：version=' + $versionStart + ' dot-source=' + $offset)
        }
        foreach ($adminCheck in $adminChecks) {
            Assert-True ($versionStart -lt [int]$adminCheck.Extent.StartOffset) ('版本判斷區塊必須早於 IsInRole：version=' + $versionStart + ' IsInRole=' + $adminCheck.Extent.StartOffset)
        }
        $true
    }

    Test-Case 'S04-version-check-block-passes-on-pwsh7' {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($versionBlock.Extent.Text))
        $result = Invoke-HostProcess -HostPath $pwshPath -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)
        Assert-True ($result.ExitCode -eq 0) ('pwsh 執行版本判斷區塊的結束碼應為 0：' + $result.ExitCode + [Environment]::NewLine + $result.StdOut + $result.StdErr)
        Assert-True ([string]::IsNullOrWhiteSpace($result.StdOut + $result.StdErr)) ('pwsh 執行版本判斷區塊不應有輸出：' + $result.StdOut + $result.StdErr)
        $true
    }

    Test-Case 'S05-requires-headers' {
        foreach ($modulePath in $modulePaths) {
            $text = Get-FileTextWithoutBom -Path $modulePath
            Assert-True ($text.StartsWith('#Requires -Version 7.0')) ('模組檔首必須是 #Requires -Version 7.0：' + $modulePath)
        }
        $setupText = Get-FileTextWithoutBom -Path $setupPath
        Assert-True ($setupText.StartsWith('#Requires -Version 5.1')) 'Setup 檔首必須維持 #Requires -Version 5.1。'
        Assert-True (-not $setupText.Contains('相容 Windows PowerShell 5.1 與 PowerShell 7+')) 'Setup 標頭註解仍宣稱相容 5.1。'
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
