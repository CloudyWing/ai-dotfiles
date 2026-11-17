#Requires -Version 7.0
[CmdletBinding()]
param()

# Setup-AIGlobalConfig.ps1 -Check 的測試：在暫存的 USERPROFILE 內建立假的全域設定，驗證「全部符合」「缺少」「指向錯誤位置」等判定，
# 並驗證每次 -Check 執行前後檔案系統（含 git 設定檔）沒有任何變動。
# 建立檔案的 Symbolic Link 需要系統管理員或開發人員模式；沒有權限時，目錄連結改用 Junction，檔案連結不建立（對應項目視為已知缺少），
# 「全部符合且結束碼 0」的案例（C01b）以 SKIP 標示未涵蓋。以系統管理員 pwsh 執行可涵蓋全部案例。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$setupPath = Join-Path $repoRoot 'scripts\Setup-AIGlobalConfig.ps1'
$pwshCommand = Get-Command -Name 'pwsh' -ErrorAction Stop
$pwshPath = if ([string]::IsNullOrWhiteSpace($pwshCommand.Source)) { $pwshCommand.Path } else { $pwshCommand.Source }
$gitPath = (Get-Command -Name 'git' -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$tempBase = Join-Path (Join-Path $env:LOCALAPPDATA 'Temp') ('setup-check-' + [guid]::NewGuid().ToString('N'))
$failed = 0
$passed = 0
$skipped = 0

function Test-Case {
    param([string]$Id, [scriptblock]$Check)
    try {
        $output = @(& $Check)
        $result = if ($output.Count -gt 0) { $output[-1] } else { $false }
        if ($result -is [string] -and $result -ceq 'SKIP') { $script:skipped++; Write-Output "SKIP $Id"; return }
        if (-not $result) { throw '條件不成立' }
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

function Invoke-SetupProcess {
    param([Parameter(Mandatory)][object]$Fixture, [string[]]$Arguments = @('-Check'))

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $pwshPath
    $argumentList = @('-NoProfile', '-NonInteractive', '-File', $setupPath) + $Arguments
    $startInfo.Arguments = ($argumentList | ForEach-Object { ConvertTo-ArgumentText -Value $_ }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    # 以 CreateNoWindow 啟動的子行程，主控台輸出編碼取系統 OEM 字碼頁，與測試行程目前的 [Console]::OutputEncoding 無關，因此以 OEM 字碼頁解碼。
    # 系統 OEM 字碼頁取自登錄 OEMCP；使用者文化的 OEMCodePage 會隨區域格式改變，不代表系統值。
    $oemCodePage = [int](Get-ItemPropertyValue -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name 'OEMCP')
    $childEncoding = [System.Text.Encoding]::GetEncoding($oemCodePage)
    $startInfo.StandardOutputEncoding = $childEncoding
    $startInfo.StandardErrorEncoding = $childEncoding
    $startInfo.EnvironmentVariables['USERPROFILE'] = $Fixture.UserProfile
    $startInfo.EnvironmentVariables['HOME'] = $Fixture.UserProfile
    $startInfo.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = $Fixture.GitGlobalConfig
    $startInfo.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
    $startInfo.EnvironmentVariables['PATH'] = (@($Fixture.BinDirectory, (Split-Path -Parent $pwshPath), (Split-Path -Parent $gitPath), (Join-Path $env:WINDIR 'System32')) -join ';')
    [void]$startInfo.EnvironmentVariables.Remove('CODEX_HOME')
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) {
            try { $process.Kill($true) } catch { }
            throw '子程序逾時'
        }
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdoutTask.GetAwaiter().GetResult(); StdErr = $stderrTask.GetAwaiter().GetResult() }
    }
    finally { $process.Dispose() }
}

function Get-TreeSnapshot {
    param([Parameter(Mandatory)][string]$Root, [string[]]$ExtraFile = @())

    # pwsh 宿主啟動時會在 USERPROFILE\AppData 寫入自己的啟動資料，與 Setup 無關，不納入比對。
    # 不跟隨連結：記錄路徑、屬性、連結目標、大小、時間，一般檔案另記 SHA-256。
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force | Where-Object { -not ($_.PSIsContainer -and $_.Name -ceq 'AppData' -and $_.Parent.Name -ceq 'user') } | Sort-Object FullName)) {
            $isLink = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
            # 目錄的時間會隨子項目增減（含宿主自建的 AppData）改變，子項目變動已由逐項列舉涵蓋，目錄只比對屬性。
            $entry = '{0}|{1}|{2}' -f $item.FullName, [int]$item.Attributes, ($(if ($isLink) { (@($item.Target) -join '') } else { '' }))
            if (-not $item.PSIsContainer) { $entry += '|' + $item.LastWriteTimeUtc.Ticks + '|' + $item.CreationTimeUtc.Ticks }
            if (-not $item.PSIsContainer -and -not $isLink) { $entry += '|' + $item.Length + '|' + (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash }
            $lines.Add($entry)
            if ($item.PSIsContainer -and -not $isLink) { $stack.Push($item.FullName) }
        }
    }
    foreach ($file in $ExtraFile) {
        $lines.Add($file + '|' + $(if (Test-Path -LiteralPath $file) { (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash } else { 'absent' }))
    }
    return (($lines.ToArray() | Sort-Object) -join "`n")
}

function New-Link {
    param([string]$Path, [string]$Target, [System.Collections.Generic.List[string]]$Unlinked)

    # 有權限時一律建 Symbolic Link；沒有權限時，目錄改建 Junction，檔案不建立並記入 Unlinked。
    if ($script:canLink) { $null = New-Item -ItemType SymbolicLink -Path $Path -Target $Target; return }
    if (Test-Path -LiteralPath $Target -PathType Container) { $null = New-Item -ItemType Junction -Path $Path -Target $Target; return }
    if ($null -ne $Unlinked) { $Unlinked.Add($Path) }
}

function Remove-Link {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -ne $item) { $item.Delete() }
}

function New-Fixture {
    param([switch]$WithoutMcpCommand)

    $root = Join-Path $tempBase ([guid]::NewGuid().ToString('N'))
    $userProfile = Join-Path $root 'user'
    $configRoot = Join-Path $userProfile '.ai-agents'
    $accountHome = Join-Path $userProfile '.codex-acct'
    $binDirectory = Join-Path $root 'bin'
    foreach ($directory in @($configRoot, $accountHome, $binDirectory, (Join-Path $userProfile '.claude'), (Join-Path $userProfile '.codex'), (Join-Path $userProfile '.agents'),
            (Join-Path $configRoot 'skills'), (Join-Path $configRoot 'agents\claude'), (Join-Path $configRoot 'agents\codex'), (Join-Path $configRoot 'rules\claude'),
            (Join-Path $configRoot 'scripts\dispatch'), (Join-Path $configRoot '.local'))) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    Set-Content -LiteralPath (Join-Path $configRoot 'instructions.md') -Value 'rules' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $configRoot 'git-global-excludes') -Value '.local/' -Encoding utf8
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\dispatch\executor-registry.json') -Destination (Join-Path $configRoot 'scripts\dispatch\executor-registry.json')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\codex-profiles') -Destination (Join-Path $configRoot 'scripts\codex-profiles') -Recurse
    $machine = [ordered]@{ schema = 'ai-agents.machine.v1'; codex_accounts = @([ordered]@{ name = 'test-account'; codex_home = $accountHome }) }
    [IO.File]::WriteAllText((Join-Path $configRoot '.local\machine.json'), ($machine | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

    & $gitPath -C $configRoot init --quiet
    & $gitPath -C $configRoot config --local core.hooksPath .githooks
    $gitGlobalConfig = Join-Path $root 'gitconfig'
    & $gitPath config --file $gitGlobalConfig core.excludesFile (Join-Path $configRoot 'git-global-excludes')

    $links = @(
        @{ Link = '.claude\CLAUDE.md'; Source = 'instructions.md' }
        @{ Link = '.claude\skills'; Source = 'skills' }
        @{ Link = '.claude\agents'; Source = 'agents\claude' }
        @{ Link = '.claude\rules'; Source = 'rules\claude' }
        @{ Link = '.codex\AGENTS.md'; Source = 'instructions.md' }
        @{ Link = '.codex\agents'; Source = 'agents\codex' }
        @{ Link = '.agents\skills'; Source = 'skills' }
    )
    $unlinked = New-Object 'System.Collections.Generic.List[string]'
    foreach ($link in $links) { New-Link -Path (Join-Path $userProfile $link.Link) -Target (Join-Path $configRoot $link.Source) -Unlinked $unlinked }
    # 測試取證檔位的 flaui-mcp 指令由帳號目錄 config.toml 提供（enabled = false）；路徑指向測試暫存目錄。
    if (-not $WithoutMcpCommand) {
        $mcpConfig = "[mcp_servers.flaui-mcp]`r`ncommand = '" + (Join-Path $root 'tools\FlaUI.Mcp.exe') + "'`r`nstartup_timeout_sec = 60.0`r`nenabled = false`r`n"
        [IO.File]::WriteAllText((Join-Path $accountHome 'config.toml'), $mcpConfig, (New-Object Text.UTF8Encoding($false)))
    }
    $profileFiles = @(Get-ChildItem -LiteralPath (Join-Path $configRoot 'scripts\codex-profiles') -Filter '*.config.toml' -File)
    foreach ($profileFile in $profileFiles) { New-Link -Path (Join-Path $accountHome $profileFile.Name) -Target $profileFile.FullName -Unlinked $unlinked }

    # 假的 claude CLI：只回答 marketplace 與 plugin 清單查詢，內容與預期狀態一致。
    $manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'claude-plugins\.claude-plugin\marketplace.json') -Raw | ConvertFrom-Json
    $pluginJson = '[' + ((@($manifest.plugins) | ForEach-Object { '{"id":"' + $_.name + '@ai-agents-local","enabled":true}' }) -join ',') + ']'
    $marketplacePath = (Join-Path $repoRoot 'claude-plugins').Replace('\', '\\')
    $cmd = @(
        '@echo off'
        'if "%~1 %~2 %~3"=="plugin marketplace list" goto mk'
        'if "%~1 %~2"=="plugin list" goto pl'
        'exit /b 1'
        ':mk'
        ('echo [{"name":"ai-agents-local","source":{"path":"' + $marketplacePath + '"}}]')
        'exit /b 0'
        ':pl'
        ('echo ' + $pluginJson)
        'exit /b 0'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $binDirectory 'claude.cmd'), $cmd + "`r`n", (New-Object Text.UTF8Encoding($false)))

    return [pscustomobject]@{
        Root = $root; UserProfile = $userProfile; ConfigRoot = $configRoot; AccountHome = $accountHome; BinDirectory = $binDirectory
        GitGlobalConfig = $gitGlobalConfig; ProfileCount = $profileFiles.Count; Unlinked = @($unlinked.ToArray())
    }
}

function Invoke-CheckRun {
    param([Parameter(Mandatory)][object]$Fixture, [string[]]$Arguments = @('-Check', '-AsJson'))

    $extra = @($Fixture.GitGlobalConfig)
    $before = Get-TreeSnapshot -Root $Fixture.Root -ExtraFile $extra
    $run = Invoke-SetupProcess -Fixture $Fixture -Arguments $Arguments
    $after = Get-TreeSnapshot -Root $Fixture.Root -ExtraFile $extra
    $items = @()
    $parsed = $null
    if ($Arguments -contains '-AsJson' -and $run.ExitCode -le 1 -and $run.StdOut.TrimStart().StartsWith('{')) {
        $parsed = $run.StdOut | ConvertFrom-Json
        $items = @($parsed.items)
    }
    return [pscustomobject]@{ Run = $run; Items = $items; Json = $parsed; Unchanged = ($before -ceq $after) }
}

function Get-ItemByPath {
    param([object[]]$Items, [string]$Category, [string]$Suffix)
    $found = @($Items | Where-Object { $_.category -ceq $Category -and $_.path.EndsWith($Suffix, [StringComparison]::OrdinalIgnoreCase) })
    Assert-True ($found.Count -eq 1) ("找不到唯一項目 $Category $Suffix（實際 $($found.Count)）")
    return $found[0]
}

function Assert-OthersOk {
    param([object]$Fixture, [object[]]$Items, [string[]]$Except)
    # 長路徑取決於執行機器的登錄值，不納入判定；沒有權限建立的檔案連結（Fixture.Unlinked）預期為缺少。
    $bad = @($Items | Where-Object {
            $_.status -cne 'ok' -and $_.category -cne 'long-paths' -and
            $Fixture.Unlinked -notcontains $_.path -and
            $Except -notcontains ($_.category + '|' + $_.path.Substring([Math]::Max(0, $_.path.LastIndexOf('\'))))
        })
    Assert-True ($bad.Count -eq 0) ('非預期的不符項目：' + (($bad | ForEach-Object { $_.category + ' ' + $_.path + ' ' + $_.status + ' ' + $_.detail }) -join ' / '))
}

try {
    $null = New-Item -ItemType Directory -Path $tempBase -Force
    $canLink = $true
    try {
        $probeTarget = Join-Path $tempBase 'probe-target.txt'
        Set-Content -LiteralPath $probeTarget -Value 'x'
        New-Link -Path (Join-Path $tempBase 'probe-link.txt') -Target $probeTarget
    }
    catch { $canLink = $false }

    # 有建立 Symbolic Link 權限時，C01 要求全部符合且結束碼 0；沒有權限時，要求除了無法建立的檔案連結（缺少）與長路徑以外全部符合。
    Test-Case 'C01-all-ok' {
        $fixture = New-Fixture
        $result = Invoke-CheckRun -Fixture $fixture
        Assert-True $result.Unchanged '-Check 執行前後檔案系統有變動'
        Assert-True ($result.Items.Count -gt 0) ('沒有取得 JSON 結果：' + $result.Run.StdOut + $result.Run.StdErr)
        Assert-OthersOk -Fixture $fixture -Items $result.Items -Except @()
        Assert-True (@($result.Items | Where-Object { $_.category -ceq 'link' }).Count -eq 7) '現役連結應有 7 項'
        Assert-True (@($result.Items | Where-Object { $_.category -ceq 'codex-profile-link' }).Count -eq $fixture.ProfileCount) '檔位設定檔連結數量與檔位數不同'
        Assert-True ((Get-ItemByPath -Items $result.Items -Category 'codex-mcp-command' -Suffix 'config.toml').status -ceq 'ok') '帳號 config.toml 有 flaui-mcp 的 command 時 MCP 指令項目應為 ok'
        foreach ($unlinkedPath in $fixture.Unlinked) { Assert-True ((@($result.Items | Where-Object { $_.path -ceq $unlinkedPath })[0]).status -ceq 'missing') ('無法建立的連結應為缺少：' + $unlinkedPath) }
        $expectedExit = if (@($result.Items | Where-Object { $_.status -cne 'ok' }).Count -eq 0) { 0 } else { 1 }
        Assert-True ($result.Run.ExitCode -eq $expectedExit) ("結束碼應為 $expectedExit，實際 $($result.Run.ExitCode)")
        Assert-True ($result.Json.allOk -eq ($expectedExit -eq 0)) 'allOk 與結束碼不一致'
        if ($canLink -and $expectedExit -eq 0) { Assert-True ($result.Json.summary.ok -eq $result.Json.summary.total) '統計與項目數不一致' }
        if ($canLink) { Assert-True ($fixture.Unlinked.Count -eq 0) '有權限時所有連結都應建立' }
        $true
    }

    # 全部符合且結束碼 0 的路徑需要檔案的 Symbolic Link；沒有權限時以 SKIP 明確標示未涵蓋，不在 C01 的降級斷言中默默略過。
    Test-Case 'C01b-all-ok-exit-0' {
        if (-not $canLink) { return 'SKIP' }
        $fixture = New-Fixture
        $result = Invoke-CheckRun -Fixture $fixture
        Assert-True $result.Unchanged '-Check 執行前後檔案系統有變動'
        # 長路徑取決於執行機器的登錄值，不納入判定；其餘項目須全部符合，結束碼依長路徑項目是否符合為 0 或 1。
        Assert-OthersOk -Fixture $fixture -Items $result.Items -Except @()
        $longPathOk = @($result.Items | Where-Object { $_.category -ceq 'long-paths' -and $_.status -cne 'ok' }).Count -eq 0
        $expectedExit = if ($longPathOk) { 0 } else { 1 }
        Assert-True ($result.Run.ExitCode -eq $expectedExit) ("結束碼應為 $expectedExit，實際 $($result.Run.ExitCode)：" + $result.Run.StdOut)
        Assert-True ($result.Json.allOk -eq $longPathOk) 'allOk 與長路徑以外的符合狀態不一致'
        if ($longPathOk) { Assert-True ($result.Json.summary.ok -eq $result.Json.summary.total) '統計與項目數不一致' }
        $true
    }

    # 連結判讀的符合與指向錯誤分支以目錄 Junction 涵蓋（與檔案的 Symbolic Link 共用同一段判讀），不需要 Symbolic Link 權限。
    Test-Case 'C08-link-judgement-without-symlink-privilege' {
        . (Join-Path $repoRoot 'scripts\lib\setup-check.ps1')
        $base = Join-Path $tempBase ('c08-' + [guid]::NewGuid().ToString('N'))
        $targetA = Join-Path $base 'target-a'
        $targetB = Join-Path $base 'target-b'
        $null = New-Item -ItemType Directory -Path $targetA, $targetB -Force
        $junction = Join-Path $base 'link'
        $null = New-Item -ItemType Junction -Path $junction -Target $targetA
        $same = Test-SetupCheckLink -Category 'link' -LinkPath $junction -TargetPath $targetA
        Assert-True ($same.status -ceq 'ok') ('指向預期來源時應為 ok，實際 ' + $same.status + ' ' + $same.detail)
        $other = Test-SetupCheckLink -Category 'link' -LinkPath $junction -TargetPath $targetB
        Assert-True ($other.status -ceq 'wrong-target') ('指向其他位置時應為 wrong-target，實際 ' + $other.status)
        $true
    }

    # Git 無法啟動時，相關項目回報無法判定，其餘檢查照常完成並輸出單一 JSON。
    Test-Case 'C09-git-unavailable' {
        $fixture = New-Fixture
        $cleanBin = Join-Path $fixture.Root 'bin-no-git'
        $null = New-Item -ItemType Directory -Path $cleanBin -Force
        Copy-Item -LiteralPath (Join-Path $fixture.BinDirectory 'claude.cmd') -Destination $cleanBin
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $pwshPath
        $startInfo.Arguments = (@('-NoProfile', '-NonInteractive', '-File', $setupPath, '-Check', '-AsJson') | ForEach-Object { ConvertTo-ArgumentText -Value $_ }) -join ' '
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.EnvironmentVariables['USERPROFILE'] = $fixture.UserProfile
        $startInfo.EnvironmentVariables['HOME'] = $fixture.UserProfile
        $startInfo.EnvironmentVariables['PATH'] = (@($cleanBin, (Split-Path -Parent $pwshPath), (Join-Path $env:WINDIR 'System32')) -join ';')
        [void]$startInfo.EnvironmentVariables.Remove('CODEX_HOME')
        $process = [System.Diagnostics.Process]::Start($startInfo)
        try {
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(120000)) { try { $process.Kill($true) } catch { }; throw '子程序逾時' }
            $process.WaitForExit()
            $stdout = $stdoutTask.GetAwaiter().GetResult()
            $stderr = $stderrTask.GetAwaiter().GetResult()
            $exitCode = $process.ExitCode
        }
        finally { $process.Dispose() }
        Assert-True ($exitCode -eq 1) ("Git 無法執行時結束碼應為 1，實際 $exitCode：" + $stderr)
        $json = $stdout | ConvertFrom-Json
        $hooks = @($json.items | Where-Object { $_.category -ceq 'git-hooks-path' })
        $excludes = @($json.items | Where-Object { $_.category -ceq 'git-excludes' })
        Assert-True ($hooks.Count -eq 1 -and $hooks[0].status -ceq 'unknown') 'core.hooksPath 應為無法判定'
        Assert-True ($excludes.Count -eq 1 -and $excludes[0].status -ceq 'unknown') 'core.excludesFile 應為無法判定'
        Assert-True (@($json.items | Where-Object { $_.category -ceq 'link' }).Count -eq 7) '其餘檢查項目應照常輸出'
        $true
    }

    Test-Case 'C02-missing-link' {
        $fixture = New-Fixture
        Remove-Link -Path (Join-Path $fixture.UserProfile '.claude\skills')
        Remove-Link -Path (Join-Path $fixture.AccountHome 'review.config.toml')
        $result = Invoke-CheckRun -Fixture $fixture
        Assert-True $result.Unchanged '-Check 執行前後檔案系統有變動'
        Assert-True ($result.Run.ExitCode -eq 1) "有缺少項目時結束碼應為 1，實際 $($result.Run.ExitCode)"
        Assert-True ((Get-ItemByPath -Items $result.Items -Category 'link' -Suffix '.claude\skills').status -ceq 'missing') '.claude\skills 應為 missing'
        Assert-True ((Get-ItemByPath -Items $result.Items -Category 'codex-profile-link' -Suffix 'review.config.toml').status -ceq 'missing') 'review.config.toml 應為 missing'
        Assert-OthersOk -Fixture $fixture -Items $result.Items -Except @('link|\skills', 'codex-profile-link|\review.config.toml')
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.UserProfile '.claude\skills'))) '-Check 不得建立缺少的連結'
        $true
    }

    Test-Case 'C10-missing-mcp-command' {
        $fixture = New-Fixture -WithoutMcpCommand
        $result = Invoke-CheckRun -Fixture $fixture
        Assert-True $result.Unchanged '-Check 執行前後檔案系統有變動'
        Assert-True ($result.Run.ExitCode -eq 1) "帳號缺少 MCP command 時結束碼應為 1，實際 $($result.Run.ExitCode)"
        Assert-True ($result.Json.allOk -eq $false) 'allOk 應為 false'
        $item = Get-ItemByPath -Items $result.Items -Category 'codex-mcp-command' -Suffix 'config.toml'
        Assert-True ($item.status -ceq 'missing') ('MCP 指令項目應為 missing，實際 ' + $item.status)
        Assert-True ($item.expected.Contains('flaui-mcp') -and $item.detail.Contains('test-account')) ('項目應指出伺服器與帳號：' + $item.expected + ' / ' + $item.detail)
        Assert-OthersOk -Fixture $fixture -Items $result.Items -Except @('codex-mcp-command|\config.toml')
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.AccountHome 'config.toml'))) '-Check 不得建立 config.toml'
        $true
    }

    Test-Case 'C03-wrong-target-and-not-link-and-orphan' {
        $fixture = New-Fixture
        Remove-Link -Path (Join-Path $fixture.UserProfile '.agents\skills')
        New-Link -Path (Join-Path $fixture.UserProfile '.agents\skills') -Target (Join-Path $fixture.ConfigRoot 'agents\codex')
        Remove-Link -Path (Join-Path $fixture.UserProfile '.claude\CLAUDE.md')
        Set-Content -LiteralPath (Join-Path $fixture.UserProfile '.claude\CLAUDE.md') -Value 'real file'
        $goneDirectory = Join-Path $fixture.ConfigRoot 'gone'
        $null = New-Item -ItemType Directory -Path $goneDirectory
        $null = New-Item -ItemType Junction -Path (Join-Path $fixture.UserProfile '.claude\dangling') -Target $goneDirectory
        Remove-Item -LiteralPath $goneDirectory
        $result = Invoke-CheckRun -Fixture $fixture
        Assert-True $result.Unchanged '-Check 執行前後檔案系統有變動'
        Assert-True ($result.Run.ExitCode -eq 1) "結束碼應為 1，實際 $($result.Run.ExitCode)"
        $wrong = Get-ItemByPath -Items $result.Items -Category 'link' -Suffix '.agents\skills'
        Assert-True ($wrong.status -ceq 'wrong-target' -and $wrong.actual.EndsWith('agents\codex', [StringComparison]::OrdinalIgnoreCase)) '.agents\skills 應為指向錯誤位置'
        $notLink = Get-ItemByPath -Items $result.Items -Category 'link' -Suffix '.claude\CLAUDE.md'
        Assert-True ($notLink.status -ceq 'wrong-target') '一般檔案取代連結時應為指向錯誤位置'
        $orphan = Get-ItemByPath -Items $result.Items -Category 'orphan' -Suffix '.claude\dangling'
        Assert-True ($orphan.status -ceq 'wrong-target') '斷鍊應被回報'
        Assert-True ($null -ne (Get-Item -LiteralPath (Join-Path $fixture.UserProfile '.claude\dangling') -Force -ErrorAction SilentlyContinue)) '-Check 不得清除斷鍊'
        $true
    }

    Test-Case 'C04-git-and-source-and-unknown' {
        $fixture = New-Fixture
        & $gitPath -C $fixture.ConfigRoot config --local core.hooksPath other-hooks
        & $gitPath config --file $fixture.GitGlobalConfig --unset core.excludesFile
        Remove-Item -LiteralPath (Join-Path $fixture.ConfigRoot 'scripts\dispatch\executor-registry.json')
        $result = Invoke-CheckRun -Fixture $fixture
        Assert-True $result.Unchanged '-Check 執行前後檔案系統有變動'
        Assert-True ((Get-ItemByPath -Items $result.Items -Category 'git-hooks-path' -Suffix '.ai-agents').status -ceq 'wrong-target') 'core.hooksPath 應為指向錯誤位置'
        Assert-True ((Get-ItemByPath -Items $result.Items -Category 'git-excludes' -Suffix 'core.excludesFile').status -ceq 'missing') 'core.excludesFile 應為 missing'
        $unknown = @($result.Items | Where-Object { $_.category -ceq 'codex-profile-generated' -and $_.status -ceq 'unknown' })
        Assert-True ($unknown.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($unknown[0].detail)) '登錄表讀不到時應為無法判定並附原因'
        Assert-True ($result.Run.ExitCode -eq 1) '有無法判定項目時結束碼應為 1'
        $true
    }

    Test-Case 'C05-plugin-wrong-marketplace-and-legacy-hook' {
        $fixture = New-Fixture
        $other = (Join-Path $fixture.Root 'elsewhere').Replace('\', '\\')
        $cmdPath = Join-Path $fixture.BinDirectory 'claude.cmd'
        $text = [IO.File]::ReadAllText($cmdPath)
        $text = [regex]::Replace($text, '"path":"[^"]*"', ('"path":"' + $other.Replace('$', '$$') + '"'))
        [IO.File]::WriteAllText($cmdPath, $text, (New-Object Text.UTF8Encoding($false)))
        $settings = '{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"pwsh scripts/hooks/post-edit-write-hook.ps1"}]}]}}'
        [IO.File]::WriteAllText((Join-Path $fixture.UserProfile '.claude\settings.json'), $settings, (New-Object Text.UTF8Encoding($false)))
        $result = Invoke-CheckRun -Fixture $fixture
        Assert-True $result.Unchanged '-Check 執行前後檔案系統有變動'
        Assert-True ((Get-ItemByPath -Items $result.Items -Category 'plugin-marketplace' -Suffix 'ai-agents-local').status -ceq 'wrong-target') 'marketplace 來源不同時應為指向錯誤位置'
        Assert-True ((Get-ItemByPath -Items $result.Items -Category 'legacy-hook' -Suffix 'settings.json').status -ceq 'mismatch') '殘留舊 hook 應為內容不符'
        $true
    }

    Test-Case 'C06-text-output-and-summary' {
        $fixture = New-Fixture
        Remove-Link -Path (Join-Path $fixture.UserProfile '.codex\agents')
        $result = Invoke-CheckRun -Fixture $fixture -Arguments @('-Check')
        Assert-True $result.Unchanged '-Check 執行前後檔案系統有變動'
        Assert-True ($result.Run.ExitCode -eq 1) '有缺少項目時結束碼應為 1'
        $expectedMissing = 1 + @($fixture.Unlinked | Where-Object { -not $_.EndsWith('.codex\agents') }).Count
        Assert-True ($result.Run.StdOut -match ('統計：共 \d+ 項，符合 \d+、缺少 ' + $expectedMissing + '、指向錯誤位置 0')) ('缺少統計列：' + $result.Run.StdOut)
        $true
    }

    Test-Case 'C07-parameter-guards' {
        $fixture = New-Fixture
        $force = Invoke-CheckRun -Fixture $fixture -Arguments @('-Check', '-Force')
        Assert-True ($force.Run.ExitCode -eq 1 -and $force.Unchanged) '-Check -Force 應被拒絕且不改動檔案'
        $json = Invoke-CheckRun -Fixture $fixture -Arguments @('-AsJson')
        Assert-True ($json.Run.ExitCode -eq 1 -and $json.Unchanged) '單獨 -AsJson 應被拒絕且不改動檔案'
        $true
    }
}
catch {
    $failed++
    Write-Output "FAIL setup-check $($_.Exception.Message)"
}
finally {
    if (Test-Path -LiteralPath $tempBase) {
        # 連結先以 Delete 移除，避免遞迴刪除跟隨連結。
        foreach ($item in @(Get-ChildItem -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })) {
            try { $item.Delete() } catch { $null = $_ }
        }
        Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Output "PASSED: $passed"
Write-Output "SKIPPED: $skipped"
Write-Output "FAILED: $failed"
if ($failed -gt 0) { exit 1 }
exit 0
