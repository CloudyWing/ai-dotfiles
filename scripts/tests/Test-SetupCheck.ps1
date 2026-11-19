#Requires -Version 7.0
[CmdletBinding()]
param()

# Setup-AIGlobalConfig.ps1 -Check 的測試：在暫存的 USERPROFILE 內建立假的全域設定，驗證「全部符合」「缺少」「指向錯誤位置」等判定，
# 並驗證每次 -Check 執行前後檔案系統（含 git 設定檔）沒有任何變動。
# 建立檔案的 Symbolic Link 需要系統管理員或開發人員模式；沒有權限時，目錄連結改用 Junction，檔案連結不建立（對應項目視為已知缺少），
# 以真實 Symbolic Link 驗證「全部符合且結束碼 0」的案例（C01b）以 SKIP 標示並寫明未涵蓋的部分。
# C01c 不需要 Symbolic Link 權限：連結一律以 Junction（目錄）與 mount point 型態的重分析點（檔案）建立，不登記派工帳號，涵蓋 -Check 對連結類全部符合與結束碼 0 的路徑。
# 以系統管理員 pwsh 執行可涵蓋全部案例。

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
        if ($result -is [string] -and $result.StartsWith('SKIP', [System.StringComparison]::Ordinal)) {
            $script:skipped++
            $reason = if ($result.Length -gt 4) { $result.Substring(4) } else { '' }
            Write-Output "SKIP $Id$reason"
            return
        }
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
    param([Parameter(Mandatory)][object]$Fixture, [string[]]$Arguments = @('-Check'), [string[]]$PathDirectories = $null)

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
    $pathDirectoryList = if ($null -ne $PathDirectories) { $PathDirectories } else { @($Fixture.BinDirectory, (Split-Path -Parent $pwshPath), (Split-Path -Parent $gitPath), (Join-Path $env:WINDIR 'System32')) }
    $startInfo.EnvironmentVariables['PATH'] = ($pathDirectoryList -join ';')
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

function New-FileMountPoint {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target)

    # 建立「目標是檔案」的 Junction：mklink /J 不驗證目標的種類，也不需要 Symbolic Link 權限。
    # New-Item -ItemType Junction 只接受目錄目標，因此改用 mklink。-Check 的連結判讀讀的是 ReparsePoint 屬性與 Target，兩者與真實連結相同。
    $output = & cmd.exe /d /c mklink /J "$Path" "$Target" 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('mklink /J 失敗（' + $LASTEXITCODE + '）：' + (@($output) -join ' ')) }
}

function New-Link {
    param([string]$Path, [string]$Target, [System.Collections.Generic.List[string]]$Unlinked, [switch]$AsJunction)

    # -AsJunction：不論有無權限，目錄建 Junction、檔案建目標為檔案的 mount point，不需要 Symbolic Link 權限，也不會有無法建立的連結。
    # 其他情況有權限時一律建 Symbolic Link；沒有權限時，目錄改建 Junction，檔案不建立並記入 Unlinked。
    if ($AsJunction) {
        if (Test-Path -LiteralPath $Target -PathType Container) { $null = New-Item -ItemType Junction -Path $Path -Target $Target }
        else { New-FileMountPoint -Path $Path -Target $Target }
        return
    }
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
    # -AllLinksAsJunction：連結一律以 Junction 與檔案 mount point 建立，且不登記派工帳號（檔位設定檔連結的判讀要求 Symbolic Link，無法以 Junction 替代）。
    param([switch]$WithoutMcpCommand, [switch]$AllLinksAsJunction)

    $root = Join-Path $tempBase ([guid]::NewGuid().ToString('N'))
    $userProfile = Join-Path $root 'user'
    $configRoot = Join-Path $userProfile '.ai-agents'
    $accountHome = Join-Path $userProfile '.codex-acct'
    $binDirectory = Join-Path $root 'bin'
    foreach ($directory in @($configRoot, $accountHome, $binDirectory, (Join-Path $userProfile '.claude'), (Join-Path $userProfile '.codex'), (Join-Path $userProfile '.agents'),
            (Join-Path $configRoot 'skills'), (Join-Path $configRoot 'agents\claude'), (Join-Path $configRoot 'agents\codex'), (Join-Path $configRoot 'rules\claude'),
            (Join-Path $configRoot 'scripts\dispatch'), (Join-Path $configRoot 'templates'), (Join-Path $configRoot '.local'))) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    Set-Content -LiteralPath (Join-Path $configRoot 'instructions.md') -Value 'rules' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $configRoot 'git-global-excludes') -Value '.local/' -Encoding utf8
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\dispatch\executor-registry.json') -Destination (Join-Path $configRoot 'scripts\dispatch\executor-registry.json')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\codex-profiles') -Destination (Join-Path $configRoot 'scripts\codex-profiles') -Recurse
    $machine = [ordered]@{ schema = 'ai-agents.machine.v1' }
    if (-not $AllLinksAsJunction) { $machine['codex_accounts'] = @([ordered]@{ name = 'test-account'; codex_home = $accountHome }) }
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
    foreach ($link in $links) { New-Link -Path (Join-Path $userProfile $link.Link) -Target (Join-Path $configRoot $link.Source) -Unlinked $unlinked -AsJunction:$AllLinksAsJunction }
    # 測試取證檔位的 flaui-mcp 指令由帳號目錄 config.toml 提供（enabled = false）；路徑指向測試暫存目錄。
    if (-not $WithoutMcpCommand -and -not $AllLinksAsJunction) {
        $mcpConfig = "[mcp_servers.flaui-mcp]`r`ncommand = '" + (Join-Path $root 'tools\FlaUI.Mcp.exe') + "'`r`nstartup_timeout_sec = 60.0`r`nenabled = false`r`n"
        [IO.File]::WriteAllText((Join-Path $accountHome 'config.toml'), $mcpConfig, (New-Object Text.UTF8Encoding($false)))
    }
    $profileFiles = @(Get-ChildItem -LiteralPath (Join-Path $configRoot 'scripts\codex-profiles') -Filter '*.config.toml' -File)
    if ($AllLinksAsJunction) { $profileFiles = @() }
    foreach ($profileFile in $profileFiles) { New-Link -Path (Join-Path $accountHome $profileFile.Name) -Target $profileFile.FullName -Unlinked $unlinked }

    # Claude 使用者層設定：settings 範本與 settings.json（內容為範本本身，即共用部分齊備）。MCP 登記與 WSL 不在 Setup 檢查範圍，夾具不建立 MCP 範本、~\.claude.json 與假的 wsl。
    Copy-Item -LiteralPath (Join-Path $repoRoot 'templates\claude-settings.shared.json') -Destination (Join-Path $configRoot 'templates\claude-settings.shared.json')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'templates\claude-settings.shared.json') -Destination (Join-Path $userProfile '.claude\settings.json')
    # 假的 claude CLI：只回答 marketplace 與 plugin 清單查詢，內容與預期狀態一致（含設定範本列為必裝的官方外掛）。
    $manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'claude-plugins\.claude-plugin\marketplace.json') -Raw | ConvertFrom-Json
    $pluginJson = '[' + ((@($manifest.plugins) | ForEach-Object { '{"id":"' + $_.name + '@ai-agents-local","enabled":true}' }) + '{"id":"microsoft-docs@claude-plugins-official","enabled":true}' -join ',') + ']'
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
    param([Parameter(Mandatory)][object]$Fixture, [string[]]$Arguments = @('-Check', '-AsJson'), [string[]]$PathDirectories = $null)

    $extra = @($Fixture.GitGlobalConfig)
    $before = Get-TreeSnapshot -Root $Fixture.Root -ExtraFile $extra
    $run = Invoke-SetupProcess -Fixture $Fixture -Arguments $Arguments -PathDirectories $PathDirectories
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

    # 以真實檔案 Symbolic Link 驗證全部符合且結束碼 0；沒有權限時以 SKIP 明確標示未涵蓋的部分，不在 C01 的降級斷言中默默略過。
    # 連結類全部符合與結束碼 0 的路徑由 C01c 涵蓋；C01b 在沒有權限時仍未涵蓋的是檔案 Symbolic Link 的建立與讀取，以及派工帳號的檔位設定檔連結。
    Test-Case 'C01b-all-ok-exit-0' {
        if (-not $canLink) { return 'SKIP: 沒有 Symbolic Link 權限；未涵蓋檔案 Symbolic Link 的建立與讀取、派工帳號的檔位設定檔連結（連結類全部符合與結束碼 0 由 C01c 涵蓋）' }
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

    # 不需要 Symbolic Link 權限：現役連結（含兩個檔案連結）全部以重分析點建立並不登記派工帳號，-Check 應全部符合；結束碼依長路徑項目是否符合為 0 或 1。
    Test-Case 'C01c-all-ok-exit-0-with-junction-links' {
        $fixture = New-Fixture -AllLinksAsJunction
        Assert-True ($fixture.Unlinked.Count -eq 0) '所有連結都應建立'
        foreach ($fileLink in @('.claude\CLAUDE.md', '.codex\AGENTS.md')) {
            $created = Get-Item -LiteralPath (Join-Path $fixture.UserProfile $fileLink) -Force
            Assert-True ([bool]($created.Attributes -band [IO.FileAttributes]::ReparsePoint)) ("$fileLink 應為重分析點")
            Assert-True ((@($created.Target) -join '').EndsWith('instructions.md', [StringComparison]::OrdinalIgnoreCase)) ("$fileLink 的目標應為 instructions.md")
        }
        $result = Invoke-CheckRun -Fixture $fixture
        Assert-True $result.Unchanged '-Check 執行前後檔案系統有變動'
        Assert-True ($result.Items.Count -gt 0) ('沒有取得 JSON 結果：' + $result.Run.StdOut + $result.Run.StdErr)
        Assert-OthersOk -Fixture $fixture -Items $result.Items -Except @()
        $links = @($result.Items | Where-Object { $_.category -ceq 'link' })
        Assert-True ($links.Count -eq 7 -and @($links | Where-Object { $_.status -cne 'ok' }).Count -eq 0) '現役連結 7 項應全部符合'
        Assert-True (@($result.Items | Where-Object { $_.category -like 'codex-*' }).Count -eq 1 -and (Get-ItemByPath -Items $result.Items -Category 'codex-profile-generated' -Suffix 'codex-profiles').status -ceq 'ok') '未登記派工帳號時只應有檔位產生檔一項 Codex 項目'
        Assert-True (@($result.Json.notes | Where-Object { $_.Contains('沒有登記的派工帳號') }).Count -eq 1) '未登記派工帳號時應有備註'
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

    # ---- Claude 使用者層設定的新類別（前置軟體、settings.json 共用部分與官方外掛） ----
    Test-Case 'C11-claude-user-config-categories-all-ok' {
        $fixture = New-Fixture
        $result = Invoke-CheckRun -Fixture $fixture
        Assert-True $result.Unchanged '-Check 執行前後檔案系統有變動'
        Assert-OthersOk -Fixture $fixture -Items $result.Items -Except @()
        foreach ($name in @('pwsh', 'git', 'claude')) { Assert-True ((Get-ItemByPath -Items $result.Items -Category 'prerequisite' -Suffix $name).status -ceq 'ok') "前置軟體 $name 應為 ok" }
        Assert-True (@($result.Items | Where-Object { $_.category -ceq 'prerequisite' }).Count -eq 3) '前置軟體應只有 pwsh、git、claude 三項（WSL 由 Register-McpServer.ps1 -Check 檢查）'
        Assert-True (@($result.Items | Where-Object { $_.category -ceq 'claude-mcp' }).Count -eq 0) 'Setup 檢查不應有 claude-mcp 類別'
        Assert-True (@($result.Json.notes | Where-Object { $_.Contains('MCP') -or $_.Contains('mcp-lab') }).Count -eq 0) 'Setup 檢查不應有 MCP 相關備註'
        $settings = @($result.Items | Where-Object { $_.category -ceq 'claude-settings' })
        Assert-True ($settings.Count -eq 1 -and $settings[0].status -ceq 'ok' -and $settings[0].path.EndsWith('settings.json#enabledPlugins')) 'claude-settings 應為 enabledPlugins 一項且為 ok'
        $plugins = @($result.Items | Where-Object { $_.category -ceq 'plugin' })
        Assert-True ($plugins.Count -eq 3 -and @($plugins | Where-Object { $_.path -ceq 'microsoft-docs@claude-plugins-official' -and $_.status -ceq 'ok' }).Count -eq 1) 'plugin 應含 microsoft-docs 官方外掛且為 ok'
        $expectedExit = if (@($result.Items | Where-Object { $_.status -cne 'ok' }).Count -eq 0) { 0 } else { 1 }
        Assert-True ($result.Run.ExitCode -eq $expectedExit) ("結束碼應為 $expectedExit，實際 $($result.Run.ExitCode)")
        $true
    }

    Test-Case 'C12-prerequisite-git-missing' {
        $fixture = New-Fixture
        $withoutGit = @($fixture.BinDirectory, (Split-Path -Parent $pwshPath), (Join-Path $env:WINDIR 'System32'))
        $result = Invoke-CheckRun -Fixture $fixture -PathDirectories $withoutGit
        Assert-True $result.Unchanged '-Check 執行前後檔案系統有變動'
        $git = Get-ItemByPath -Items $result.Items -Category 'prerequisite' -Suffix 'git'
        Assert-True ($git.status -ceq 'missing' -and $git.detail.Contains('winget install Git.Git')) ('git 應為缺少並附安裝命令：' + $git.status + ' ' + $git.detail)
        Assert-True ($result.Run.ExitCode -eq 1 -and $result.Json.allOk -eq $false) '缺少 git 時結束碼應為 1'
        $true
    }

    Test-Case 'C14-claude-cli-missing-keeps-other-checks' {
        $fixture = New-Fixture
        $noClaudeBin = Join-Path $fixture.Root 'bin-no-claude'
        $null = New-Item -ItemType Directory -Path $noClaudeBin -Force
        $result = Invoke-CheckRun -Fixture $fixture -PathDirectories @($noClaudeBin, (Split-Path -Parent $pwshPath), (Split-Path -Parent $gitPath), (Join-Path $env:WINDIR 'System32'))
        Assert-True $result.Unchanged '-Check 執行前後檔案系統有變動'
        $claude = Get-ItemByPath -Items $result.Items -Category 'prerequisite' -Suffix 'claude'
        Assert-True ($claude.status -ceq 'missing' -and $claude.detail.Contains('winget install Anthropic.ClaudeCode')) 'claude 應為缺少並附安裝命令'
        Assert-True (@($result.Items | Where-Object { $_.category -ceq 'plugin' }).Count -eq 0) '沒有 claude 時 plugin 項目不輸出'
        Assert-True (@($result.Items | Where-Object { $_.category -ceq 'claude-settings' -and $_.status -ceq 'ok' }).Count -eq 1) '不依賴 CLI 的 settings 檢查應照常進行'
        Assert-True ($result.Run.ExitCode -eq 1) '缺少 claude 時結束碼應為 1'
        $true
    }

    Test-Case 'C17-settings-shared-part' {
        $fixture = New-Fixture
        $settingsPath = Join-Path $fixture.UserProfile '.claude\settings.json'
        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($settingsPath, '{"theme":"light","permissions":{"allow":["x"]}}', $utf8)
        $lacking = Invoke-CheckRun -Fixture $fixture
        Assert-True $lacking.Unchanged '-Check 執行前後檔案系統有變動'
        $item = Get-ItemByPath -Items $lacking.Items -Category 'claude-settings' -Suffix 'settings.json#enabledPlugins'
        Assert-True ($item.status -ceq 'missing' -and $item.detail.Contains('缺少：enabledPlugins；')) ('整個範本鍵缺少時應為 missing 並列出鍵名：' + $item.detail)
        Assert-True ($lacking.Run.ExitCode -eq 1) '共用部分缺少時結束碼應為 1'

        [IO.File]::WriteAllText($settingsPath, '{"enabledPlugins":{"ai-agents-hooks@ai-agents-local":true}}', $utf8)
        $partial = Invoke-CheckRun -Fixture $fixture
        $partialItem = Get-ItemByPath -Items $partial.Items -Category 'claude-settings' -Suffix 'settings.json#enabledPlugins'
        Assert-True ($partialItem.status -ceq 'missing' -and $partialItem.detail.Contains('enabledPlugins.microsoft-docs@claude-plugins-official') -and $partialItem.detail.Contains('enabledPlugins.line-status-board@ai-agents-local') -and -not $partialItem.detail.Contains('enabledPlugins.ai-agents-hooks')) ('缺少部分子項目時應只列出缺少的鍵名：' + $partialItem.detail)

        [IO.File]::WriteAllText($settingsPath, '{ not json', $utf8)
        $unreadable = Invoke-CheckRun -Fixture $fixture
        $unknown = @($unreadable.Items | Where-Object { $_.category -ceq 'claude-settings' })
        Assert-True ($unknown.Count -eq 1 -and $unknown[0].status -ceq 'unknown') 'settings.json 無法剖析時應為單一 unknown'

        Remove-Item -LiteralPath $settingsPath -Force
        $absent = Invoke-CheckRun -Fixture $fixture
        $single = @($absent.Items | Where-Object { $_.category -ceq 'claude-settings' })
        Assert-True ($single.Count -eq 1 -and $single[0].status -ceq 'missing') 'settings.json 不存在時應為單一 missing'
        Assert-True (-not (Test-Path -LiteralPath $settingsPath)) '-Check 不得建立 settings.json'

        Remove-Item -LiteralPath (Join-Path $fixture.ConfigRoot 'templates\claude-settings.shared.json') -Force
        $noTemplate = Invoke-CheckRun -Fixture $fixture
        Assert-True (@($noTemplate.Items | Where-Object { $_.category -ceq 'claude-settings' }).Count -eq 0) '範本不存在時 claude-settings 類別不輸出'
        Assert-True (@($noTemplate.Json.notes | Where-Object { $_.Contains('settings 共用範本不存在') }).Count -eq 1) '範本不存在時應有備註'
        Assert-True (@($noTemplate.Items | Where-Object { $_.category -ceq 'plugin' }).Count -eq 2) '範本不存在時沒有官方外掛項目'
        $true
    }

    Test-Case 'C18-settings-differing-values-are-notes-only' {
        $fixture = New-Fixture
        $settingsPath = Join-Path $fixture.UserProfile '.claude\settings.json'
        [IO.File]::WriteAllText($settingsPath, '{"enabledPlugins":{"ai-agents-hooks@ai-agents-local":true,"line-status-board@ai-agents-local":true,"microsoft-docs@claude-plugins-official":false}}', (New-Object Text.UTF8Encoding($false)))
        $result = Invoke-CheckRun -Fixture $fixture
        Assert-True $result.Unchanged '-Check 執行前後檔案系統有變動'
        Assert-True ((Get-ItemByPath -Items $result.Items -Category 'claude-settings' -Suffix 'settings.json#enabledPlugins').status -ceq 'ok') '值與範本不同但鍵存在時共用部分視為齊備'
        Assert-True (@($result.Json.notes | Where-Object { $_.Contains('enabledPlugins.microsoft-docs@claude-plugins-official') -and $_.Contains('保留你的值') }).Count -eq 1) '與範本不同的項目應列在備註（只列路徑）'
        $true
    }

    # Setup 檢查不讀取 MCP 登記，也不檢查 WSL：登記檔損毀、MCP 範本不存在時結果與全部齊備的夾具相同，結束碼只取決於項目。
    Test-Case 'C20-setup-check-ignores-mcp-registration-and-wsl' {
        $fixture = New-Fixture
        [IO.File]::WriteAllText((Join-Path $fixture.UserProfile '.claude.json'), '{ not json', (New-Object Text.UTF8Encoding($false)))
        $result = Invoke-CheckRun -Fixture $fixture
        Assert-True $result.Unchanged '-Check 執行前後檔案系統有變動（含 ~\.claude.json）'
        Assert-OthersOk -Fixture $fixture -Items $result.Items -Except @()
        Assert-True (@($result.Items | Where-Object { $_.category -ceq 'claude-mcp' -or ($_.category -ceq 'prerequisite' -and $_.path -ceq 'wsl') }).Count -eq 0) 'Setup 檢查不應有 claude-mcp 項目或 WSL 項目'
        Assert-True (@($result.Items | Where-Object { $_.status -cne 'ok' -and $_.category -cne 'long-paths' -and $fixture.Unlinked -notcontains $_.path }).Count -eq 0) '沒有 MCP 登記與有效 WSL 的環境，除連結與長路徑外不應有不符項目'
        $expectedExit = if (@($result.Items | Where-Object { $_.status -cne 'ok' }).Count -eq 0) { 0 } else { 1 }
        Assert-True ($result.Run.ExitCode -eq $expectedExit) ("結束碼只取決於項目，應為 $expectedExit，實際 $($result.Run.ExitCode)")
        $true
    }

    # 使用者在 settings.json 把官方外掛設為 false 是他的決定：Setup 不會重新啟用，檢查不把它列為缺少；沒有這項設定而外掛停用時照舊為缺少。
    Test-Case 'C21-user-disabled-official-plugin-is-not-missing' {
        $fixture = New-Fixture
        $cmdPath = Join-Path $fixture.BinDirectory 'claude.cmd'
        $cmdText = [IO.File]::ReadAllText($cmdPath)
        $enabledEntry = '"microsoft-docs@claude-plugins-official","enabled":true'
        Assert-True ($cmdText.Contains($enabledEntry)) '夾具的假 claude 應列出啟用的官方外掛'
        [IO.File]::WriteAllText($cmdPath, $cmdText.Replace($enabledEntry, '"microsoft-docs@claude-plugins-official","enabled":false'), (New-Object Text.UTF8Encoding($false)))
        $notUserDisabled = Invoke-CheckRun -Fixture $fixture
        $stillMissing = Get-ItemByPath -Items $notUserDisabled.Items -Category 'plugin' -Suffix 'microsoft-docs@claude-plugins-official'
        Assert-True ($stillMissing.status -ceq 'missing' -and $stillMissing.detail.Contains('已安裝但未啟用')) 'settings.json 沒有設為 false 而外掛停用時應為缺少'

        $settingsPath = Join-Path $fixture.UserProfile '.claude\settings.json'
        [IO.File]::WriteAllText($settingsPath, '{"enabledPlugins":{"ai-agents-hooks@ai-agents-local":true,"line-status-board@ai-agents-local":true,"microsoft-docs@claude-plugins-official":false}}', (New-Object Text.UTF8Encoding($false)))
        $userDisabled = Invoke-CheckRun -Fixture $fixture
        Assert-True $userDisabled.Unchanged '-Check 執行前後檔案系統有變動'
        $item = Get-ItemByPath -Items $userDisabled.Items -Category 'plugin' -Suffix 'microsoft-docs@claude-plugins-official'
        Assert-True ($item.status -ceq 'ok' -and $item.actual -ceq 'disabled' -and $item.detail.Contains('你已在 settings.json')) ('使用者設為 false 的官方外掛應為符合：' + $item.status + ' ' + $item.detail)
        Assert-OthersOk -Fixture $fixture -Items $userDisabled.Items -Except @()
        $true
    }

    # 使用者設為 false 且尚未安裝的官方外掛：Setup 不會安裝，-Check 視為符合並說明，不寫「重新執行 Setup 會安裝」；沒有設為 false 時照舊為缺少。
    Test-Case 'C22-user-disabled-and-not-installed-official-plugin-is-ok' {
        $fixture = New-Fixture
        $cmdPath = Join-Path $fixture.BinDirectory 'claude.cmd'
        $cmdText = [IO.File]::ReadAllText($cmdPath)
        $entry = ',{"id":"microsoft-docs@claude-plugins-official","enabled":true}'
        Assert-True ($cmdText.Contains($entry)) '夾具的假 claude 應列出官方外掛'
        [IO.File]::WriteAllText($cmdPath, $cmdText.Replace($entry, ''), (New-Object Text.UTF8Encoding($false)))
        $notDisabled = Invoke-CheckRun -Fixture $fixture
        $missing = Get-ItemByPath -Items $notDisabled.Items -Category 'plugin' -Suffix 'microsoft-docs@claude-plugins-official'
        Assert-True ($missing.status -ceq 'missing' -and $missing.detail.Contains('重新執行 Setup 會安裝')) '沒有設為 false 且未安裝時應為缺少'

        $settingsPath = Join-Path $fixture.UserProfile '.claude\settings.json'
        [IO.File]::WriteAllText($settingsPath, '{"enabledPlugins":{"ai-agents-hooks@ai-agents-local":true,"line-status-board@ai-agents-local":true,"microsoft-docs@claude-plugins-official":false}}', (New-Object Text.UTF8Encoding($false)))
        $userDisabled = Invoke-CheckRun -Fixture $fixture
        Assert-True $userDisabled.Unchanged '-Check 執行前後檔案系統有變動'
        $item = Get-ItemByPath -Items $userDisabled.Items -Category 'plugin' -Suffix 'microsoft-docs@claude-plugins-official'
        Assert-True ($item.status -ceq 'ok' -and $item.detail.Contains('使用者已') -and -not $item.detail.Contains('重新執行 Setup 會安裝')) ('使用者設為 false 且未安裝的官方外掛應為符合：' + $item.status + ' ' + $item.detail)
        Assert-OthersOk -Fixture $fixture -Items $userDisabled.Items -Except @()
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
