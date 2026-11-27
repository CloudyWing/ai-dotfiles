#Requires -Version 7.0
[CmdletBinding()]
param()

# scripts/Register-McpServer.ps1 與 scripts/lib/mcp-registration.ps1 的測試：
# Claude 端的登記（只選取的項目、已存在不覆寫、重複執行不重複）、FlaUI.Mcp 寫入 Codex 桌面版設定檔（新增、只改 command、其餘位元組不變、保留編碼與換行、
# 執行檔或設定檔不存在不寫入、-WhatIf 不寫入、讀取後被改動不寫入、連結的處理、相對路徑轉成絕對路徑）、同步更新 machine.json 登記的派工帳號、唯讀檢查（含帳號與桌面版一致），以及腳本本身的選取、用法與結束碼。
# 帳號與 machine.json 都是暫存目錄內的假檔案；執行腳本的輔助函式預設把 -MachineConfigPath 指向暫存目錄，測試不讀寫真實的帳號設定檔。
# 所有檔案操作都在暫存目錄內進行；腳本以子行程執行時，USERPROFILE、LOCALAPPDATA 與 PATH 都指向暫存目錄與假的 claude，不碰真實的使用者設定與 Claude CLI。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$scriptPath = Join-Path $repoRoot 'scripts\Register-McpServer.ps1'
$libPath = Join-Path $repoRoot 'scripts\lib\mcp-registration.ps1'
$mcpTemplatePath = Join-Path $repoRoot 'templates\claude-mcp-servers.json'
$pwshCommand = Get-Command -Name 'pwsh' -ErrorAction Stop
$pwshPath = if ([string]::IsNullOrWhiteSpace($pwshCommand.Source)) { $pwshCommand.Path } else { $pwshCommand.Source }
$tempBase = Join-Path ([IO.Path]::GetTempPath()) ('mcp-registration-' + [guid]::NewGuid().ToString('N'))
$failed = 0
$passed = 0
$skipped = 0

. (Join-Path $repoRoot 'scripts\lib\claude-user-config.ps1')
. (Join-Path $repoRoot 'scripts\codex-run\45-profile-sync.ps1')
. (Join-Path $repoRoot 'scripts\dispatch\common-runtime.ps1')
. (Join-Path $repoRoot 'scripts\dispatch\git-baseline.ps1')
. (Join-Path $repoRoot 'scripts\dispatch\dispatch-evidence.ps1')
. $libPath

# 替身：記錄呼叫並由測試指定回應。
$script:CliCalls = New-Object 'System.Collections.Generic.List[object]'
$script:CliHandler = { param($Arguments) [pscustomobject]@{ ExitCode = 0; Output = '' } }
$script:WslStatus = 'ok'
$script:WslCalls = 0

function Invoke-ClaudeCli {
    param([string[]]$Arguments)
    $script:CliCalls.Add($Arguments)
    return (& $script:CliHandler $Arguments)
}

function Get-WslStatus {
    param([string]$WslPath)
    $script:WslCalls++
    return $script:WslStatus
}

function Test-Case {
    param([string]$Id, [scriptblock]$Check)
    try {
        $output = @(& $Check)
        $result = if ($output.Count -gt 0) { $output[-1] } else { $false }
        # 測試以 [pscustomobject]@{ Skip = '原因' } 表示環境條件不具備（例如沒有建立符號連結的權限）而略過。
        if ($result -is [pscustomobject] -and $null -ne $result.PSObject.Properties['Skip']) {
            $script:skipped++
            Write-Output "SKIP $Id $($result.Skip)"
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

function Reset-Stubs {
    $script:CliCalls.Clear()
    $script:CliHandler = { param($Arguments) [pscustomobject]@{ ExitCode = 0; Output = '' } }
    $script:WslStatus = 'ok'
    $script:WslCalls = 0
}

function New-TestDirectory {
    $path = Join-Path $tempBase ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Join-Arguments {
    param([object[]]$Arguments)
    return (@($Arguments) -join [char]0)
}

function Test-DirectoryHasClaude {
    param([string]$Directory)
    foreach ($name in @('claude.exe', 'claude.cmd', 'claude.bat', 'claude.ps1', 'claude')) {
        if (Test-Path -LiteralPath (Join-Path $Directory $name) -PathType Leaf -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Invoke-Captured {
    param([scriptblock]$Action)
    $captured = [pscustomobject]@{ Result = @(); Warnings = @(); Info = @(); Error = $null }
    try {
        $stream = @(& $Action 3>&1 6>&1)
        $captured.Warnings = @($stream | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        $captured.Info = @($stream | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        $captured.Result = @($stream | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] -and $_ -isnot [System.Management.Automation.InformationRecord] })
    }
    catch { $captured.Error = $_.Exception.Message }
    return $captured
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
$infraLabDistro = 'Ubuntu-test'
$infraLabRepo = '/work/infra-lab'

function New-ExistingRegistrations {
    param([object[]]$Template)
    $existing = @{}
    foreach ($server in $Template) {
        if ($server.Type -eq 'http') { $existing[$server.Name] = [ordered]@{ type = 'http'; url = $server.Url } }
        else { $existing[$server.Name] = [ordered]@{ type = 'stdio'; command = 'wsl.exe'; args = @('-d', $infraLabDistro, '-e', 'bash', ($infraLabRepo + '/scripts/mcp.sh')); env = [ordered]@{} } }
    }
    return $existing
}

function New-UserMcpFile {
    # IncludeFixedStdio（預設開）：登記檔含固定形狀的 playwright 與 flaui-mcp；-Exclude 可依名稱移除。
    # FlaUICommand 是 flaui-mcp 登記的 command，需要與被測執行檔路徑一致時由案例指定；PlaywrightDir 是 playwright 登記的輸出目錄。
    param([string[]]$Exclude = @(), [bool]$IncludeFixedStdio = $true, [string]$FlaUICommand = 'X:\placeholder\FlaUI.Mcp.exe', [string]$PlaywrightDir = $script:testPlaywrightDir)
    $path = Join-Path (New-TestDirectory) 'claude.json'
    $existing = New-ExistingRegistrations -Template $script:template
    if ($IncludeFixedStdio) {
        $existing['playwright'] = [ordered]@{ type = 'stdio'; command = 'cmd'; args = @('/c', 'npx', '-y', '@playwright/mcp@latest'); env = [ordered]@{ PLAYWRIGHT_MCP_OUTPUT_DIR = $PlaywrightDir } }
        $existing['flaui-mcp'] = [ordered]@{ type = 'stdio'; command = $FlaUICommand; args = @(); env = [ordered]@{} }
    }
    foreach ($name in $Exclude) { $existing.Remove($name) }
    [IO.File]::WriteAllText($path, (@{ mcpServers = $existing } | ConvertTo-Json -Depth 8), $utf8)
    return $path
}

# Codex 桌面版設定檔夾具：位元組完全由測試指定（BOM、換行）；同目錄放其他檔案，驗證不被動到。
function New-CodexFixture {
    param([string]$Text, [switch]$Bom, [byte[]]$RawBytes)
    $directory = Join-Path (New-TestDirectory) '.codex'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $configPath = Join-Path $directory 'config.toml'
    if ($PSBoundParameters.ContainsKey('Text') -or $PSBoundParameters.ContainsKey('RawBytes')) {
        # 空字串的位元組是空陣列，if 運算式賦值會把它列舉成 $null，所以逐分支賦值。
        [byte[]]$bytes = @()
        if ($PSBoundParameters.ContainsKey('RawBytes')) { $bytes = $RawBytes }
        elseif ($Bom) { $bytes = [byte[]](0xEF, 0xBB, 0xBF) + $utf8.GetBytes($Text) }
        else { $bytes = $utf8.GetBytes($Text) }
        [IO.File]::WriteAllBytes($configPath, $bytes)
    }
    [IO.File]::WriteAllBytes((Join-Path $directory 'state.sqlite'), [byte[]](1, 2, 3, 4, 5))
    [IO.File]::WriteAllText((Join-Path $directory 'AGENTS.md'), 'rules', $utf8)
    $executableDirectory = Join-Path (Split-Path -Parent $directory) 'tools'
    New-Item -ItemType Directory -Path $executableDirectory -Force | Out-Null
    $executablePath = Join-Path $executableDirectory 'FlaUI.Mcp.exe'
    [IO.File]::WriteAllBytes($executablePath, [byte[]](77, 90))
    return [pscustomobject]@{ Directory = $directory; Config = $configPath; Executable = $executablePath; Backups = (Join-Path (Split-Path -Parent $directory) 'backups') }
}

function Get-FileSnapshot {
    param([string]$Directory)
    # pwsh 宿主啟動時會在 USERPROFILE\AppData 寫入自己的啟動資料，與腳本無關，不納入比對。
    return ((Get-ChildItem -LiteralPath $Directory -Recurse -File -Force | Where-Object { $_.FullName -notlike '*\AppData\*' } | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($Directory.Length) + '|' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join "`n")
}

function Get-FileText {
    param([string]$Path, [switch]$KeepBom)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = if (-not $KeepBom -and $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
    return $utf8.GetString($bytes, $offset, $bytes.Length - $offset)
}

function Get-TestBytesHex {
    param([string]$Path)
    return [Convert]::ToHexString([IO.File]::ReadAllBytes($Path))
}

function Get-TestTemporaryFile {
    param([string]$Directory)
    return , @(Get-ChildItem -LiteralPath $Directory -Force | Where-Object { $_.Name -like '*.tmp-*' })
}

$crlf = "`r`n"
$baseConfigLines =@('model = "gpt"', '', '[mcp_servers.playwright]', "command = 'npx'", '', '[projects.''x:\work'']', 'trust_level = "trusted"')
$baseConfig = ($baseConfigLines -join $crlf) + $crlf
$presentConfig = (@('model = "gpt"', '', '[mcp_servers.flaui-mcp]', "command = 'X:\old\FlaUI.Mcp.exe'", 'startup_timeout_sec = 60.0', '', '[projects.''x:\work'']', 'trust_level = "trusted"') -join $crlf) + $crlf
# 派工帳號已有 flaui-mcp 表的設定檔：Setup 複製時加入的 enabled = false 與 startup_timeout_sec 不得被改動。
$accountPresentConfig = (@('model = "gpt"', '', '[mcp_servers.flaui-mcp]', "command = 'X:\old\FlaUI.Mcp.exe'", 'startup_timeout_sec = 90.0', 'enabled = false', '', '[projects.''x:\work'']', 'trust_level = "trusted"') -join $crlf) + $crlf

# 派工帳號夾具：machine.json 與各帳號目錄都在暫存目錄。NoConfig 的帳號只有目錄、沒有 config.toml（登記檔的讀取要求帳號目錄存在）。
function New-AccountFixture {
    param([hashtable]$Config = @{}, [string[]]$Name = @('acct-a', 'acct-b'), [string[]]$NoConfig = @())
    $root = New-TestDirectory
    $entries = @()
    $homes = @{}
    foreach ($accountName in $Name) {
        $accountHome = Join-Path $root ('.codex-' + $accountName)
        New-Item -ItemType Directory -Path $accountHome -Force | Out-Null
        if ($NoConfig -notcontains $accountName) {
            $text = if ($Config.ContainsKey($accountName)) { $Config[$accountName] } else { $baseConfig }
            [IO.File]::WriteAllBytes((Join-Path $accountHome 'config.toml'), $utf8.GetBytes($text))
        }
        [IO.File]::WriteAllText((Join-Path $accountHome 'sibling.txt'), 'sibling', $utf8)
        $entries += [ordered]@{ name = $accountName; codex_home = $accountHome }
        $homes[$accountName] = $accountHome
    }
    $machinePath = Join-Path $root 'machine.json'
    [IO.File]::WriteAllText($machinePath, ([ordered]@{ schema = 'ai-agents.machine.v1'; codex_accounts = @($entries) } | ConvertTo-Json -Depth 5), $utf8)
    return [pscustomobject]@{ Root = $root; Machine = $machinePath; Homes = $homes; Backups = (Join-Path $root 'backups') }
}

function Get-AccountConfigPath {
    param($Fixture, [string]$Name)
    return (Join-Path $Fixture.Homes[$Name] 'config.toml')
}

# 子行程：腳本在暫存的 USERPROFILE、LOCALAPPDATA 與只含假 claude 的 PATH 下執行。假 claude 把引數寫入 CALLLOG 並以結束碼 0 結束。
function ConvertTo-ArgumentText {
    param([string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function New-ScriptEnvironment {
    $root = New-TestDirectory
    $profileDirectory = Join-Path $root 'user'
    $binDirectory = Join-Path $root 'bin'
    New-Item -ItemType Directory -Path $profileDirectory, $binDirectory, (Join-Path $profileDirectory 'AppData\Local') -Force | Out-Null
    $callLog = Join-Path $root 'claude-calls.log'
    [IO.File]::WriteAllText((Join-Path $binDirectory 'claude.cmd'), "@echo off`r`necho %* >> `"%CLAUDE_CALL_LOG%`"`r`nexit /b 0`r`n", $utf8)
    return [pscustomobject]@{ Root = $root; UserProfile = $profileDirectory; LocalAppData = (Join-Path $profileDirectory 'AppData\Local'); Bin = $binDirectory; CallLog = $callLog }
}

function Invoke-RegisterScript {
    param([Parameter(Mandatory)][object]$Environment, [string[]]$Arguments = @(), [string]$WorkingDirectory, [switch]$UnsetLocalAppData)
    # 腳本的帳號登記檔預設是 repo 的 .local\machine.json（真實的派工帳號）。測試一律指向暫存目錄內不存在的檔案，
    # 需要帳號時由案例以 -MachineConfigPath 指定暫存的 machine.json，不會碰到真實的帳號設定檔。
    if ($Arguments -notcontains '-MachineConfigPath') { $Arguments = @($Arguments) + @('-MachineConfigPath', (Join-Path $Environment.Root 'no-machine.json')) }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) { $startInfo.WorkingDirectory = $WorkingDirectory }
    $startInfo.FileName = $pwshPath
    $startInfo.Arguments = ((@('-NoProfile', '-NonInteractive', '-File', $scriptPath) + $Arguments) | ForEach-Object { ConvertTo-ArgumentText -Value $_ }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $oemCodePage = [int](Get-ItemPropertyValue -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name 'OEMCP')
    $childEncoding = [System.Text.Encoding]::GetEncoding($oemCodePage)
    $startInfo.StandardOutputEncoding = $childEncoding
    $startInfo.StandardErrorEncoding = $childEncoding
    $startInfo.EnvironmentVariables['USERPROFILE'] = $Environment.UserProfile
    $startInfo.EnvironmentVariables['HOME'] = $Environment.UserProfile
    $startInfo.EnvironmentVariables['LOCALAPPDATA'] = $Environment.LocalAppData
    if ($UnsetLocalAppData) { [void]$startInfo.EnvironmentVariables.Remove('LOCALAPPDATA') }
    $startInfo.EnvironmentVariables['CLAUDE_CALL_LOG'] = $Environment.CallLog
    $startInfo.EnvironmentVariables['PATH'] = (@($Environment.Bin, (Split-Path -Parent $pwshPath), (Join-Path $env:WINDIR 'System32')) -join ';')
    foreach ($name in @('CODEX_HOME', 'CLAUDE_CONFIG_DIR')) { [void]$startInfo.EnvironmentVariables.Remove($name) }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { try { $process.Kill($true) } catch { $null = $_ }; throw '子程序逾時' }
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdoutTask.GetAwaiter().GetResult(); StdErr = $stderrTask.GetAwaiter().GetResult(); Arguments = @($Arguments) }
    }
    finally { $process.Dispose() }
}

$originalPath = $env:PATH
try {
    New-Item -ItemType Directory -Path $tempBase -Force | Out-Null

    # 假的 claude 放在本程序的 PATH：步驟函式以 Get-Command claude 判斷 CLI 是否存在，測試不依賴機器是否裝了 Claude Code，也不會呼叫到真實的 CLI。
    $fakeClaudeDirectory = Join-Path $tempBase 'fake-claude-bin'
    New-Item -ItemType Directory -Path $fakeClaudeDirectory -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $fakeClaudeDirectory 'claude.cmd'), "@echo off`r`necho fake claude must not be called 1>&2`r`nexit /b 99`r`n", $utf8)
    $pathWithoutClaude = @($originalPath -split ';' | Where-Object { $_ -ne '' -and -not (Test-DirectoryHasClaude -Directory $_) })
    $env:PATH = (@($fakeClaudeDirectory) + $pathWithoutClaude) -join ';'

    $script:template = @(Read-ClaudeMcpTemplate -Path $mcpTemplatePath)
    $template = $script:template

    # Playwright MCP 的預設輸出目錄為 <LocalAppData>\ai-agents\playwright-mcp。測試一律以 -LocalAppData 注入夾具目錄，不讀真實 %LOCALAPPDATA%。
    # 連結的 worktree 夾具：.git 是檔案；預設輸出目錄與它無關。
    $script:testLocalAppData = Join-Path $tempBase 'localappdata'
    $testLocalAppData = $script:testLocalAppData
    $script:testPlaywrightDir = Join-Path $testLocalAppData 'ai-agents\playwright-mcp'
    $testPlaywrightDir = $script:testPlaywrightDir
    $testWorktreeRoot = Join-Path $tempBase 'repo-worktree'
    New-Item -ItemType Directory -Path $testWorktreeRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $testWorktreeRoot '.git'), 'gitdir: X:\main\.git\worktrees\x', $utf8)

    # ---- FlaUI：寫入 Codex 桌面版設定檔 ----
    Test-Case 'FL01 項目不存在時在檔尾新增，含 command 與 startup_timeout_sec；原有位元組不變，原檔備份與 manifest 存在，同目錄其他檔案不變' {
        $fixture = New-CodexFixture -Text $baseConfig
        $originalBytes = [IO.File]::ReadAllBytes($fixture.Config)
        $siblings = Get-FileSnapshot -Directory $fixture.Directory
        $siblingsWithoutConfig = (($siblings -split "`n") | Where-Object { $_ -notlike '*config.toml*' }) -join "`n"
        $result = Set-FlaUIMcpCommand -ConfigPath $fixture.Config -ExecutablePath $fixture.Executable -BackupRoot $fixture.Backups
        $written = [IO.File]::ReadAllBytes($fixture.Config)
        $expectedText = $baseConfig + $crlf + '[mcp_servers.flaui-mcp]' + $crlf + "command = '" + $fixture.Executable + "'" + $crlf + 'startup_timeout_sec = 60.0' + $crlf
        $prefixSame = [Convert]::ToHexString($written[0..($originalBytes.Length - 1)]) -ceq [Convert]::ToHexString($originalBytes)
        $manifest = Join-Path (Split-Path -Parent (Split-Path -Parent $result.BackupPath)) 'manifest.txt'
        $after = (Get-FileSnapshot -Directory $fixture.Directory) -split "`n" | Where-Object { $_ -notlike '*config.toml*' }
        $result.Status -eq 'added' -and $prefixSame -and (Get-FileText -Path $fixture.Config) -ceq $expectedText -and (Test-Path -LiteralPath $manifest) -and
        (Get-TestBytesHex $result.BackupPath) -ceq [Convert]::ToHexString($originalBytes) -and ($after -join "`n") -ceq $siblingsWithoutConfig -and @(Get-ChildItem -LiteralPath $fixture.Directory -Filter '*.tmp-*').Count -eq 0
    }
    Test-Case 'FL02 項目已存在時只更新 command 那一行的值，其餘位元組逐位元組不變（含 BOM 與 CRLF）' {
        $fixture = New-CodexFixture -Text $presentConfig -Bom
        $result = Set-FlaUIMcpCommand -ConfigPath $fixture.Config -ExecutablePath $fixture.Executable -BackupRoot $fixture.Backups
        $expected = $presentConfig.Replace("command = 'X:\old\FlaUI.Mcp.exe'", "command = '" + $fixture.Executable + "'")
        $expectedBytes = [byte[]](0xEF, 0xBB, 0xBF) + $utf8.GetBytes($expected)
        $result.Status -eq 'updated' -and (Get-TestBytesHex $fixture.Config) -ceq [Convert]::ToHexString($expectedBytes) -and (Get-FileText -Path $result.BackupPath -KeepBom) -ceq ([string][char]0xFEFF + $presentConfig)
    }
    Test-Case 'FL03 command 為雙引號字串時沿用雙引號並跳脫反斜線；LF 換行的檔案維持 LF、沒有 BOM 維持沒有 BOM' {
        $lfConfig = (@('[mcp_servers.flaui-mcp]', 'command = "X:\\old\\FlaUI.Mcp.exe"', 'startup_timeout_sec = 60.0') -join "`n") + "`n"
        $fixture = New-CodexFixture -Text $lfConfig
        $result = Set-FlaUIMcpCommand -ConfigPath $fixture.Config -ExecutablePath $fixture.Executable -BackupRoot $fixture.Backups
        $expected = $lfConfig.Replace('command = "X:\\old\\FlaUI.Mcp.exe"', 'command = "' + $fixture.Executable.Replace('\', '\\') + '"')
        $bytes = [IO.File]::ReadAllBytes($fixture.Config)
        $result.Status -eq 'updated' -and (Get-FileText -Path $fixture.Config) -ceq $expected -and -not ($bytes[0] -eq 0xEF) -and -not (Get-FileText -Path $fixture.Config).Contains("`r")
    }
    Test-Case 'FL04 command 已是指定路徑（不分大小寫）時回報 unchanged，不寫檔、不備份' {
        $fixture = New-CodexFixture -Text ($presentConfig.Replace('X:\old\FlaUI.Mcp.exe', 'PLACEHOLDER'))
        $text = (Get-FileText -Path $fixture.Config).Replace('PLACEHOLDER', $fixture.Executable.ToUpperInvariant())
        [IO.File]::WriteAllBytes($fixture.Config, $utf8.GetBytes($text))
        $hash = Get-TestBytesHex $fixture.Config
        $result = Set-FlaUIMcpCommand -ConfigPath $fixture.Config -ExecutablePath $fixture.Executable -BackupRoot $fixture.Backups
        $result.Status -eq 'unchanged' -and (Get-TestBytesHex $fixture.Config) -ceq $hash -and -not (Test-Path -LiteralPath $fixture.Backups)
    }
    Test-Case 'FL05 表存在但沒有 command 時只在表頭下新增 command，其餘不變' {
        $text = (@('[mcp_servers.flaui-mcp]', 'startup_timeout_sec = 60.0', '', '[other]', 'a = 1') -join $crlf) + $crlf
        $fixture = New-CodexFixture -Text $text
        $result = Set-FlaUIMcpCommand -ConfigPath $fixture.Config -ExecutablePath $fixture.Executable -BackupRoot $fixture.Backups
        $expected = $text.Replace('[mcp_servers.flaui-mcp]' + $crlf, '[mcp_servers.flaui-mcp]' + $crlf + "command = '" + $fixture.Executable + "'" + $crlf)
        $result.Status -eq 'updated' -and (Get-FileText -Path $fixture.Config) -ceq $expected
    }
    Test-Case 'FL06 執行檔不存在時不寫入、不備份，回報 executable-missing' {
        $fixture = New-CodexFixture -Text $baseConfig
        $hash = Get-TestBytesHex $fixture.Config
        $result = Set-FlaUIMcpCommand -ConfigPath $fixture.Config -ExecutablePath (Join-Path $fixture.Directory 'none\FlaUI.Mcp.exe') -BackupRoot $fixture.Backups
        $result.Status -eq 'executable-missing' -and (Get-TestBytesHex $fixture.Config) -ceq $hash -and -not (Test-Path -LiteralPath $fixture.Backups)
    }
    Test-Case 'FL07 設定檔不存在時不建立，回報 config-missing；.codex 目錄不被動到' {
        $fixture = New-CodexFixture
        $before = Get-FileSnapshot -Directory $fixture.Directory
        $result = Set-FlaUIMcpCommand -ConfigPath $fixture.Config -ExecutablePath $fixture.Executable -BackupRoot $fixture.Backups
        $result.Status -eq 'config-missing' -and -not (Test-Path -LiteralPath $fixture.Config) -and (Get-FileSnapshot -Directory $fixture.Directory) -ceq $before -and -not (Test-Path -LiteralPath $fixture.Backups)
    }
    Test-Case 'FL08 -WhatIf 時不寫入、不備份（新增與更新兩種情況）' {
        $added = New-CodexFixture -Text $baseConfig
        $updated = New-CodexFixture -Text $presentConfig
        $hashAdded = Get-TestBytesHex $added.Config
        $hashUpdated = Get-TestBytesHex $updated.Config
        $first = Set-FlaUIMcpCommand -ConfigPath $added.Config -ExecutablePath $added.Executable -BackupRoot $added.Backups -WhatIf
        $second = Set-FlaUIMcpCommand -ConfigPath $updated.Config -ExecutablePath $updated.Executable -BackupRoot $updated.Backups -WhatIf
        $first.Status -eq 'whatif' -and $second.Status -eq 'whatif' -and (Get-TestBytesHex $added.Config) -ceq $hashAdded -and (Get-TestBytesHex $updated.Config) -ceq $hashUpdated -and -not (Test-Path -LiteralPath $added.Backups) -and -not (Test-Path -LiteralPath $updated.Backups)
    }
    Test-Case 'FL09 無法確定語意的寫法一律不寫入：command 後有註解、多行字串、父表 [mcp_servers]、行內表、不是合法 UTF-8、含 NUL' {
        $cases = [ordered]@{
            'trailing-comment' = $utf8.GetBytes("[mcp_servers.flaui-mcp]`r`ncommand = 'X:\old.exe' # note`r`n")
            'multiline'        = $utf8.GetBytes("[mcp_servers.flaui-mcp]`r`ncommand = '''`r`nX:\old.exe'''`r`n")
            'parent-table'     = $utf8.GetBytes("[mcp_servers]`r`n")
            'inline-table'     = $utf8.GetBytes("mcp_servers = { flaui-mcp = { command = 'x' } }`r`n")
            'invalid-utf8'     = [byte[]](0x5B, 0xFF, 0xFE, 0x5D)
            'nul'              = [byte[]](0x61, 0x00, 0x62, 0x00)
        }
        foreach ($key in $cases.Keys) {
            $fixture = New-CodexFixture -RawBytes $cases[$key]
            $hash = Get-TestBytesHex $fixture.Config
            $result = Set-FlaUIMcpCommand -ConfigPath $fixture.Config -ExecutablePath $fixture.Executable -BackupRoot $fixture.Backups
            Assert-True ($result.Status -eq 'blocked') ("應為 blocked：$key，實際 $($result.Status)")
            Assert-True ((Get-TestBytesHex $fixture.Config) -ceq $hash -and -not (Test-Path -LiteralPath $fixture.Backups)) ("不應寫入或備份：$key")
        }
        $true
    }
    Test-Case 'FL10 執行檔路徑含單引號時改用基本字串並跳脫；檔尾沒有換行時先補一個換行再新增' {
        $directory = New-TestDirectory
        $odd = Join-Path $directory "it's"
        New-Item -ItemType Directory -Path $odd -Force | Out-Null
        $exe = Join-Path $odd 'FlaUI.Mcp.exe'
        [IO.File]::WriteAllBytes($exe, [byte[]](77, 90))
        $noNewline = 'model = "gpt"'
        $fixture = New-CodexFixture -Text $noNewline
        $result = Set-FlaUIMcpCommand -ConfigPath $fixture.Config -ExecutablePath $exe -BackupRoot $fixture.Backups
        $text = Get-FileText -Path $fixture.Config
        $expectedCommand = 'command = "' + $exe.Replace('\', '\\') + '"'
        $result.Status -eq 'added' -and $text.StartsWith('model = "gpt"' + $crlf + $crlf + '[mcp_servers.flaui-mcp]' + $crlf + $expectedCommand + $crlf)
    }
    Test-Case 'FL11 寫入失敗（原檔唯讀）時回報 failed，原檔不變且不留暫存檔' {
        $fixture = New-CodexFixture -Text $baseConfig
        $hash = Get-TestBytesHex $fixture.Config
        Set-ItemProperty -LiteralPath $fixture.Config -Name IsReadOnly -Value $true
        try { $result = Set-FlaUIMcpCommand -ConfigPath $fixture.Config -ExecutablePath $fixture.Executable -BackupRoot $fixture.Backups }
        finally { Set-ItemProperty -LiteralPath $fixture.Config -Name IsReadOnly -Value $false }
        $result.Status -eq 'failed' -and (Get-TestBytesHex $fixture.Config) -ceq $hash -and @(Get-ChildItem -LiteralPath $fixture.Directory -Filter '*.tmp-*' -Force).Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $fixture.Directory 'state.sqlite'))
    }

    Test-Case 'FL12 執行檔路徑不是完整的絕對路徑（相對、只有檔名、磁碟機相對）時回報 invalid-path，不寫入、不備份，相對路徑不會被寫進設定檔' {
        $fixture = New-CodexFixture -Text $baseConfig
        $hash = Get-TestBytesHex $fixture.Config
        $statuses = @('.\FlaUI.Mcp.exe', 'FlaUI.Mcp.exe', 'C:FlaUI.Mcp.exe', '..\tools\FlaUI.Mcp.exe') | ForEach-Object { (Set-FlaUIMcpCommand -ConfigPath $fixture.Config -ExecutablePath $_ -BackupRoot $fixture.Backups).Status }
        @($statuses | Where-Object { $_ -ne 'invalid-path' }).Count -eq 0 -and (Get-TestBytesHex $fixture.Config) -ceq $hash -and -not (Test-Path -LiteralPath $fixture.Backups)
    }
    Test-Case 'FL13 讀取之後設定檔被其他程式改動時不寫入：回報 changed，改動後的內容保留，備份是讀取時的內容，不留暫存檔' {
        $fixture = New-CodexFixture -Text $baseConfig
        $originalHex = Get-TestBytesHex $fixture.Config
        $originalSave = ${function:Save-ConfigFileBackup}
        function Save-ConfigFileBackup {
            # 模擬備份之後、取代之前有其他程式寫入（例如 Codex 新增專案的信任項目）。
            param($Context, $BackupRoot, $RelativePath, $Bytes, $SourcePath, $Operation)
            $path = & $originalSave -Context $Context -BackupRoot $BackupRoot -RelativePath $RelativePath -Bytes $Bytes -SourcePath $SourcePath -Operation $Operation
            [IO.File]::AppendAllText($SourcePath, "# other-writer`r`n", $utf8)
            return $path
        }
        $result = Set-FlaUIMcpCommand -ConfigPath $fixture.Config -ExecutablePath $fixture.Executable -BackupRoot $fixture.Backups
        $text = Get-FileText -Path $fixture.Config
        $result.Status -eq 'changed' -and $result.Message.Contains('被其他程式改動') -and $text.EndsWith("# other-writer`r`n") -and -not $text.Contains('flaui-mcp') -and (Get-TestBytesHex $result.BackupPath) -ceq $originalHex -and (Get-TestTemporaryFile -Directory $fixture.Directory).Count -eq 0
    }
    Test-Case 'FL14 設定檔是硬連結時原地寫入，連結關係保留：另一個名稱看到相同的新內容，備份是原內容' {
        $fixture = New-CodexFixture -Text $presentConfig
        $dotfiles = Join-Path (Split-Path -Parent $fixture.Directory) 'dotfiles'
        New-Item -ItemType Directory -Path $dotfiles -Force | Out-Null
        $linkedName = Join-Path $dotfiles 'config.toml'
        $null = New-Item -ItemType HardLink -Path $linkedName -Target $fixture.Config
        $originalHex = Get-TestBytesHex $fixture.Config
        $result = Set-FlaUIMcpCommand -ConfigPath $fixture.Config -ExecutablePath $fixture.Executable -BackupRoot $fixture.Backups
        $result.Status -eq 'updated' -and (Get-TestBytesHex $linkedName) -ceq (Get-TestBytesHex $fixture.Config) -and (Get-FileText -Path $linkedName).Contains("command = '" + $fixture.Executable + "'") -and [string](Get-Item -LiteralPath $fixture.Config -Force).LinkType -ceq 'HardLink' -and
        (Get-TestBytesHex $result.BackupPath) -ceq $originalHex -and (Get-TestTemporaryFile -Directory $fixture.Directory).Count -eq 0
    }
    Test-Case 'FL15 設定檔是符號連結時寫入連結指向的實際檔案：連結仍是連結，目標檔更新，備份是目標檔的原內容（沒有建立符號連結的權限時略過）' {
        $fixture = New-CodexFixture
        $realDirectory = Join-Path (Split-Path -Parent $fixture.Directory) 'dotfiles'
        New-Item -ItemType Directory -Path $realDirectory -Force | Out-Null
        $realPath = Join-Path $realDirectory 'config.toml'
        [IO.File]::WriteAllBytes($realPath, $utf8.GetBytes($presentConfig))
        try { $null = New-Item -ItemType SymbolicLink -Path $fixture.Config -Target $realPath -ErrorAction Stop }
        catch { return [pscustomobject]@{ Skip = '沒有建立符號連結的權限' } }
        $originalHex = Get-TestBytesHex $realPath
        $result = Set-FlaUIMcpCommand -ConfigPath $fixture.Config -ExecutablePath $fixture.Executable -BackupRoot $fixture.Backups
        $result.Status -eq 'updated' -and ((Get-Item -LiteralPath $fixture.Config -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -and (Get-FileText -Path $realPath).Contains("command = '" + $fixture.Executable + "'") -and (Get-TestBytesHex $result.BackupPath) -ceq $originalHex
    }
    Test-Case 'FL16 寫入目標無法確定（連結指向不存在的目標等）時回報 unresolved，不備份、不寫入，-WhatIf 同樣回報' {
        $fixture = New-CodexFixture -Text $baseConfig
        $hash = Get-TestBytesHex $fixture.Config
        function Resolve-ConfigWriteTarget {
            param([string]$Path)
            return [pscustomobject]@{ Ok = $false; Path = $Path; InPlace = $false; Message = '連結指向不存在的目標' }
        }
        $result = Set-FlaUIMcpCommand -ConfigPath $fixture.Config -ExecutablePath $fixture.Executable -BackupRoot $fixture.Backups
        $whatIf = Set-FlaUIMcpCommand -ConfigPath $fixture.Config -ExecutablePath $fixture.Executable -BackupRoot $fixture.Backups -WhatIf
        $result.Status -eq 'unresolved' -and $result.Message.Contains('連結指向不存在的目標') -and $whatIf.Status -eq 'unresolved' -and (Get-TestBytesHex $fixture.Config) -ceq $hash -and -not (Test-Path -LiteralPath $fixture.Backups)
    }

    # ---- 派工帳號：-FlaUI 同時更新 .local\machine.json 登記的帳號 ----
    Test-Case 'AC01 已有表的帳號只改 command 那一行（enabled = false、startup_timeout_sec 與其餘位元組不變）；沒有表的帳號依 Setup 複製的形式追加整張表（與 Set-CodexMcpAccountConfig 的結果位元組相同）' {
        Reset-Stubs
        $codex = New-CodexFixture -Text $baseConfig
        $accounts = New-AccountFixture -Config @{ 'acct-a' = $accountPresentConfig; 'acct-b' = $baseConfig }
        $siblingsBefore = Get-FileSnapshot -Directory $accounts.Root
        $captured = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path (New-TestDirectory) 'none.json') -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $accounts.Backups -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $accounts.Machine }

        # Setup 的形式：對 acct-b 的原內容副本呼叫 Set-CodexMcpAccountConfig（來源為同一份桌面版設定檔）。
        $referenceHome = Join-Path (New-TestDirectory) 'reference'
        New-Item -ItemType Directory -Path $referenceHome -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $referenceHome 'config.toml'), $utf8.GetBytes($baseConfig))
        $spec = [pscustomobject]@{ McpServers = @([pscustomobject]@{ Name = 'flaui-mcp'; Command = $null }) }
        $null = @(Set-CodexMcpAccountConfig -AccountHome $referenceHome -Spec $spec -SourceConfigPath $codex.Config)

        $expectedA = $accountPresentConfig.Replace("command = 'X:\old\FlaUI.Mcp.exe'", "command = '" + $codex.Executable + "'")
        $configA = Get-AccountConfigPath -Fixture $accounts -Name 'acct-a'
        $configB = Get-AccountConfigPath -Fixture $accounts -Name 'acct-b'
        $result = $captured.Result[0]
        $siblingsAfter = (Get-FileSnapshot -Directory $accounts.Root) -split "`n" | Where-Object { $_ -notlike '*config.toml*' -and $_ -notlike '*backups*' -and $_ -notlike '*machine.json*' }
        $siblingsExpected = $siblingsBefore -split "`n" | Where-Object { $_ -notlike '*config.toml*' -and $_ -notlike '*machine.json*' }
        $null -eq $captured.Error -and $result.Problems -eq 0 -and @($result.AccountResults | ForEach-Object { $_.Status }) -join ',' -ceq 'updated,added' -and
        (Get-FileText -Path $configA) -ceq $expectedA -and (Get-TestBytesHex $configB) -ceq (Get-TestBytesHex (Join-Path $referenceHome 'config.toml')) -and
        (Get-FileText -Path $configB).EndsWith("[mcp_servers.flaui-mcp]$crlf" + "command = '" + $codex.Executable + "'$crlf" + "startup_timeout_sec = 60.0$crlf" + "enabled = false$crlf") -and ($siblingsAfter -join "`n") -ceq ($siblingsExpected -join "`n")
    }
    Test-Case 'AC02 備份：桌面版與每個帳號各一份（相對路徑區分來源），同一次執行共用一個備份目錄，內容是寫入前的位元組，manifest.txt 每個檔案一行' {
        Reset-Stubs
        $codex = New-CodexFixture -Text $baseConfig
        $accounts = New-AccountFixture -Config @{ 'acct-a' = $accountPresentConfig; 'acct-b' = $baseConfig }
        $before = @{ desktop = (Get-TestBytesHex $codex.Config); a = (Get-TestBytesHex (Get-AccountConfigPath -Fixture $accounts -Name 'acct-a')); b = (Get-TestBytesHex (Get-AccountConfigPath -Fixture $accounts -Name 'acct-b')) }
        $captured = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path (New-TestDirectory) 'none.json') -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $accounts.Backups -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $accounts.Machine }
        $runDirectories = @(Get-ChildItem -LiteralPath $accounts.Backups -Directory)
        $runDirectory = $runDirectories[0].FullName
        $manifest = @(Get-Content -LiteralPath (Join-Path $runDirectory 'manifest.txt'))
        $runDirectories.Count -eq 1 -and (Get-TestBytesHex (Join-Path $runDirectory 'desktop\config.toml')) -ceq $before.desktop -and (Get-TestBytesHex (Join-Path $runDirectory 'accounts\acct-a\config.toml')) -ceq $before.a -and
        (Get-TestBytesHex (Join-Path $runDirectory 'accounts\acct-b\config.toml')) -ceq $before.b -and $manifest.Count -eq 3 -and @($manifest | Where-Object { $_.Contains($codex.Config) }).Count -eq 1 -and
        @($manifest | Where-Object { $_.Contains((Get-AccountConfigPath -Fixture $accounts -Name 'acct-a')) }).Count -eq 1 -and $captured.Result[0].FlaUIResult.BackupPath -ceq (Join-Path $runDirectory 'desktop\config.toml')
    }
    Test-Case 'AC03 帳號 config.toml 不存在時略過該帳號並回報（不建立檔案），其餘帳號照常更新；問題數為 1' {
        Reset-Stubs
        $codex = New-CodexFixture -Text $baseConfig
        $accounts = New-AccountFixture -Config @{ 'acct-b' = $accountPresentConfig } -NoConfig @('acct-a')
        $captured = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path (New-TestDirectory) 'none.json') -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $accounts.Backups -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $accounts.Machine }
        $statuses = @($captured.Result[0].AccountResults | ForEach-Object { $_.Status }) -join ','
        $null -eq $captured.Error -and $captured.Result[0].Problems -eq 1 -and $statuses -ceq 'config-missing,updated' -and -not (Test-Path -LiteralPath (Get-AccountConfigPath -Fixture $accounts -Name 'acct-a')) -and
        (Get-FileText -Path (Get-AccountConfigPath -Fixture $accounts -Name 'acct-b')).Contains("command = '" + $codex.Executable + "'") -and (($captured.Warnings -join "`n") -match 'acct-a')
    }
    Test-Case 'AC04 帳號 config.toml 讀不到、寫法無法確定（command 後有註解、父表 [mcp_servers]）時各略過該帳號並回報，不寫入、不備份該帳號；其餘帳號照常更新' {
        Reset-Stubs
        $codex = New-CodexFixture -Text $baseConfig
        $accounts = New-AccountFixture -Name @('acct-a', 'acct-b', 'acct-c', 'acct-d') -Config @{
            'acct-a' = "[mcp_servers.flaui-mcp]`r`ncommand = 'X:\old.exe' # note`r`n"
            'acct-b' = "[mcp_servers]`r`n"
            'acct-c' = $accountPresentConfig
            'acct-d' = $baseConfig
        }
        [IO.File]::WriteAllBytes((Get-AccountConfigPath -Fixture $accounts -Name 'acct-d'), [byte[]](0x5B, 0xFF, 0xFE, 0x5D))
        $hashes = @('acct-a', 'acct-b', 'acct-d') | ForEach-Object { Get-TestBytesHex (Get-AccountConfigPath -Fixture $accounts -Name $_) }
        $captured = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path (New-TestDirectory) 'none.json') -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $accounts.Backups -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $accounts.Machine }
        $statuses = @($captured.Result[0].AccountResults | ForEach-Object { $_.Status }) -join ','
        $after = @('acct-a', 'acct-b', 'acct-d') | ForEach-Object { Get-TestBytesHex (Get-AccountConfigPath -Fixture $accounts -Name $_) }
        $captured.Result[0].Problems -eq 3 -and $statuses -ceq 'blocked,blocked,updated,blocked' -and ($after -join ',') -ceq ($hashes -join ',') -and (Get-FileText -Path (Get-AccountConfigPath -Fixture $accounts -Name 'acct-c')).Contains("command = '" + $codex.Executable + "'")
    }
    Test-Case 'AC05 沒有登記帳號（沒有 machine.json、codex_accounts 為空陣列、沒有 codex_accounts、路徑為空）時只處理桌面版，問題數為 0' {
        Reset-Stubs
        $directory = New-TestDirectory
        $emptyList = Join-Path $directory 'empty.json'
        [IO.File]::WriteAllText($emptyList, '{"schema":"ai-agents.machine.v1","codex_accounts":[]}', $utf8)
        $noProperty = Join-Path $directory 'no-property.json'
        [IO.File]::WriteAllText($noProperty, '{"schema":"ai-agents.machine.v1"}', $utf8)
        $verdicts = @()
        foreach ($machine in @((Join-Path $directory 'none.json'), $emptyList, $noProperty, '')) {
            $codex = New-CodexFixture -Text $baseConfig
            $captured = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path $directory 'none.json') -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $machine }
            $verdicts += ($null -eq $captured.Error -and $captured.Result[0].Problems -eq 0 -and $captured.Result[0].FlaUIResult.Status -eq 'added' -and @($captured.Result[0].AccountResults).Count -eq 0)
        }
        @($verdicts | Where-Object { -not $_ }).Count -eq 0
    }
    Test-Case 'AC06 -WhatIf：桌面版與帳號都不寫入、不備份，結果為 whatif，問題數為 0' {
        Reset-Stubs
        $codex = New-CodexFixture -Text $baseConfig
        $accounts = New-AccountFixture -Config @{ 'acct-a' = $accountPresentConfig; 'acct-b' = $baseConfig }
        $snapshot = (Get-FileSnapshot -Directory $accounts.Root) + (Get-FileSnapshot -Directory $codex.Directory)
        $captured = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path (New-TestDirectory) 'none.json') -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $accounts.Backups -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $accounts.Machine -WhatIf }
        $statuses = @($captured.Result[0].AccountResults | ForEach-Object { $_.Status }) -join ','
        $null -eq $captured.Error -and $captured.Result[0].FlaUIResult.Status -eq 'whatif' -and $statuses -ceq 'whatif,whatif' -and $captured.Result[0].Problems -eq 0 -and ((Get-FileSnapshot -Directory $accounts.Root) + (Get-FileSnapshot -Directory $codex.Directory)) -ceq $snapshot -and -not (Test-Path -LiteralPath $accounts.Backups)
    }
    Test-Case 'AC07 桌面版沒有完成（設定檔不存在、執行檔不存在）時不處理帳號：帳號檔案不變，問題數只算桌面版的 1' {
        Reset-Stubs
        $accounts = New-AccountFixture -Config @{ 'acct-a' = $accountPresentConfig; 'acct-b' = $baseConfig }
        $snapshot = Get-FileSnapshot -Directory $accounts.Root
        $noDesktop = New-CodexFixture
        $noExecutable = New-CodexFixture -Text $baseConfig
        $first = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path (New-TestDirectory) 'none.json') -CodexConfigPath $noDesktop.Config -FlaUIPath $noDesktop.Executable -BackupRoot $accounts.Backups -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $accounts.Machine }
        $second = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path (New-TestDirectory) 'none.json') -CodexConfigPath $noExecutable.Config -FlaUIPath (Join-Path $noExecutable.Directory 'none.exe') -BackupRoot $accounts.Backups -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $accounts.Machine }
        $first.Result[0].Problems -eq 1 -and $second.Result[0].Problems -eq 1 -and @($first.Result[0].AccountResults).Count -eq 0 -and @($second.Result[0].AccountResults).Count -eq 0 -and (Get-FileSnapshot -Directory $accounts.Root) -ceq $snapshot
    }
    Test-Case 'AC08 帳號登記檔不合法時桌面版照常處理，帳號全部略過並回報，問題數為 1' {
        Reset-Stubs
        $codex = New-CodexFixture -Text $baseConfig
        $directory = New-TestDirectory
        $bad = Join-Path $directory 'machine.json'
        [IO.File]::WriteAllText($bad, '{ not json', $utf8)
        $captured = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path $directory 'none.json') -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $bad }
        $null -eq $captured.Error -and $captured.Result[0].FlaUIResult.Status -eq 'added' -and $captured.Result[0].Problems -eq 1 -and @($captured.Result[0].AccountResults).Count -eq 0 -and (($captured.Warnings -join "`n") -match '派工帳號登記無法讀取')
    }
    Test-Case 'AC09 帳號的 config.toml 在讀取之後被改動時不寫該帳號（回報 changed，改動後的內容保留），其餘帳號與桌面版照常寫入，問題數為 1' {
        Reset-Stubs
        $codex = New-CodexFixture -Text $baseConfig
        $accounts = New-AccountFixture -Config @{ 'acct-a' = $accountPresentConfig; 'acct-b' = $accountPresentConfig }
        $originalSave = ${function:Save-ConfigFileBackup}
        function Save-ConfigFileBackup {
            param($Context, $BackupRoot, $RelativePath, $Bytes, $SourcePath, $Operation)
            $path = & $originalSave -Context $Context -BackupRoot $BackupRoot -RelativePath $RelativePath -Bytes $Bytes -SourcePath $SourcePath -Operation $Operation
            if ($RelativePath -like 'accounts\acct-a\*') { [IO.File]::AppendAllText($SourcePath, "# other-writer`r`n", $utf8) }
            return $path
        }
        $captured = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path (New-TestDirectory) 'none.json') -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $accounts.Backups -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $accounts.Machine }
        $statuses = @($captured.Result[0].AccountResults | ForEach-Object { $_.Status }) -join ','
        $textA = Get-FileText -Path (Get-AccountConfigPath -Fixture $accounts -Name 'acct-a')
        $captured.Result[0].Problems -eq 1 -and $statuses -ceq 'changed,updated' -and $textA.EndsWith("# other-writer`r`n") -and $textA.Contains('X:\old\FlaUI.Mcp.exe') -and
        (Get-FileText -Path (Get-AccountConfigPath -Fixture $accounts -Name 'acct-b')).Contains("command = '" + $codex.Executable + "'") -and (Get-FileText -Path $codex.Config).Contains("command = '" + $codex.Executable + "'")
    }
    Test-Case 'AC10 帳號已是桌面版的路徑時回報 unchanged，不備份、不寫入；重複執行不再追加或改動' {
        Reset-Stubs
        $codex = New-CodexFixture -Text $baseConfig
        $accounts = New-AccountFixture -Config @{ 'acct-a' = $accountPresentConfig; 'acct-b' = $baseConfig }
        $first = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path (New-TestDirectory) 'none.json') -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $accounts.Backups -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $accounts.Machine }
        $snapshot = (Get-FileSnapshot -Directory $accounts.Root) + (Get-FileSnapshot -Directory $codex.Directory)
        Start-Sleep -Milliseconds 1100
        $second = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path (New-TestDirectory) 'none.json') -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $accounts.Backups -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $accounts.Machine }
        $statuses = @($second.Result[0].AccountResults | ForEach-Object { $_.Status }) -join ','
        $first.Result[0].Problems -eq 0 -and $second.Result[0].Problems -eq 0 -and $second.Result[0].FlaUIResult.Status -eq 'unchanged' -and $statuses -ceq 'unchanged,unchanged' -and ((Get-FileSnapshot -Directory $accounts.Root) + (Get-FileSnapshot -Directory $codex.Directory)) -ceq $snapshot
    }
    Test-Case 'AC11 桌面版設定檔寫法無法確定（blocked）時不處理帳號；帳號沒有表而來源（桌面版）沒有可複製的 command 時，單一帳號的函式回報 blocked 並不寫入' {
        Reset-Stubs
        $codex = New-CodexFixture -Text ("[mcp_servers.flaui-mcp]`r`ncommand = 'X:\old.exe' # note`r`n")
        $accounts = New-AccountFixture -Name @('acct-a')
        $configA = Get-AccountConfigPath -Fixture $accounts -Name 'acct-a'
        $hash = Get-TestBytesHex $configA
        $captured = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path (New-TestDirectory) 'none.json') -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $accounts.Backups -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $accounts.Machine }
        $direct = Set-FlaUIMcpAccountCommand -AccountName 'acct-a' -AccountHome $accounts.Homes['acct-a'] -ExecutablePath $codex.Executable -SourceConfigPath (Join-Path (New-TestDirectory) 'none.toml') -BackupRoot $accounts.Backups -BackupContext (New-ConfigBackupContext)
        $captured.Result[0].FlaUIResult.Status -eq 'blocked' -and @($captured.Result[0].AccountResults).Count -eq 0 -and $direct.Status -eq 'blocked' -and $direct.Message.Contains('沒有 [mcp_servers.flaui-mcp] 的 command') -and (Get-TestBytesHex $configA) -ceq $hash -and -not (Test-Path -LiteralPath $accounts.Backups)
    }

    Test-Case 'AC12 0 位元組的 config.toml（桌面版與帳號）可備份並追加項目，不以難懂的繫結錯誤失敗；帳號的結果與 Set-CodexMcpAccountConfig 對空檔的結果位元組相同' {
        Reset-Stubs
        $codex = New-CodexFixture -Text ''
        $accounts = New-AccountFixture -Name @('acct-a') -Config @{ 'acct-a' = '' }
        $configA = Get-AccountConfigPath -Fixture $accounts -Name 'acct-a'
        $emptyBefore = ([IO.File]::ReadAllBytes($codex.Config)).Length -eq 0 -and ([IO.File]::ReadAllBytes($configA)).Length -eq 0
        $captured = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path (New-TestDirectory) 'none.json') -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $accounts.Backups -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $accounts.Machine }
        $referenceHome = Join-Path (New-TestDirectory) 'reference'
        New-Item -ItemType Directory -Path $referenceHome -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $referenceHome 'config.toml'), [byte[]]@())
        $spec = [pscustomobject]@{ McpServers = @([pscustomobject]@{ Name = 'flaui-mcp'; Command = $null }) }
        $null = @(Set-CodexMcpAccountConfig -AccountHome $referenceHome -Spec $spec -SourceConfigPath $codex.Config)
        $backups = @(Get-ChildItem -LiteralPath $accounts.Backups -Recurse -File -Filter 'config.toml')
        $emptyBefore -and $null -eq $captured.Error -and $captured.Result[0].Problems -eq 0 -and $captured.Result[0].FlaUIResult.Status -eq 'added' -and @($captured.Result[0].AccountResults | ForEach-Object { $_.Status }) -join ',' -ceq 'added' -and
        (Get-FileText -Path $codex.Config).Contains("[mcp_servers.flaui-mcp]") -and (Get-TestBytesHex $configA) -ceq (Get-TestBytesHex (Join-Path $referenceHome 'config.toml')) -and $backups.Count -eq 2 -and @($backups | Where-Object { $_.Length -ne 0 }).Count -eq 0
    }

    # ---- -FlaUI 的主控台說明與摘要（只比對關鍵字） ----
    function Get-FlaUIConsole {
        param($Codex, $Accounts, [switch]$WhatIfRun)
        if ($WhatIfRun) { return (Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path (New-TestDirectory) 'none.json') -CodexConfigPath $Codex.Config -FlaUIPath $Codex.Executable -BackupRoot $Accounts.Backups -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $Accounts.Machine -WhatIf }) }
        return (Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path (New-TestDirectory) 'none.json') -CodexConfigPath $Codex.Config -FlaUIPath $Codex.Executable -BackupRoot $Accounts.Backups -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $Accounts.Machine })
    }
    Test-Case 'MS01 桌面版沒有完成時：警告說明派工帳號沒有被更動並要求排除問題後重新執行同一個命令；摘要標示桌面版未完成、帳號未處理' {
        Reset-Stubs
        $codex = New-CodexFixture
        $accounts = New-AccountFixture
        $captured = Get-FlaUIConsole -Codex $codex -Accounts $accounts
        $warnings = $captured.Warnings -join "`n"
        $info = $captured.Info -join "`n"
        $warnings -match '派工帳號沒有被更動' -and $warnings -match '重新執行同一個命令' -and $info -match 'FlaUI 摘要' -and $info -match '桌面版 未完成' -and $info -match '派工帳號 未處理'
    }
    Test-Case 'MS02 派工帳號登記無法讀取（登記的帳號目錄不存在）時：警告寫明原因與目錄、桌面版已處理完成、全部帳號都沒有更新、補救方式；摘要標示全部略過；桌面版仍寫入' {
        Reset-Stubs
        $codex = New-CodexFixture -Text $baseConfig
        $accounts = New-AccountFixture -Config @{ 'acct-a' = $accountPresentConfig }
        $missingHome = $accounts.Homes['acct-b']
        Remove-Item -LiteralPath $missingHome -Recurse -Force
        $hashA = Get-TestBytesHex (Get-AccountConfigPath -Fixture $accounts -Name 'acct-a')
        $captured = Get-FlaUIConsole -Codex $codex -Accounts $accounts
        $warnings = $captured.Warnings -join "`n"
        $info = $captured.Info -join "`n"
        $warnings -match '帳號目錄不存在' -and $warnings.Contains('acct-b') -and $warnings.Contains($missingHome) -and $warnings -match '桌面版已處理完成' -and $warnings -match '全部派工帳號都沒有更新' -and $warnings -match 'machine\.json' -and $warnings -match '重新執行同一個命令' -and
        $info -match '全部略過' -and (Get-FileText -Path $codex.Config).Contains("command = '" + $codex.Executable + "'") -and (Get-TestBytesHex (Get-AccountConfigPath -Fixture $accounts -Name 'acct-a')) -ceq $hashA -and $captured.Result[0].Problems -eq 1
    }
    Test-Case 'MS03 單一帳號被略過（缺 config.toml、無法解析、定義有歧義、寫入前被改動）時：警告指出帳號名稱、原因與其他帳號照常處理；摘要有略過件數；訊息不含設定檔的其他內容' {
        Reset-Stubs
        $codex = New-CodexFixture -Text $baseConfig
        $secret = 'SECRET-SENTINEL-VALUE'
        $accounts = New-AccountFixture -Name @('acct-a', 'acct-b', 'acct-c', 'acct-d', 'acct-e') -NoConfig @('acct-a') -Config @{
            'acct-b' = ("api_key = '$secret'`r`n[mcp_servers.flaui-mcp]`r`ncommand = 'X:\old.exe' # note`r`n")
            'acct-c' = ("api_key = '$secret'`r`n[mcp_servers]`r`n")
            'acct-d' = ($accountPresentConfig + "api_key = '$secret'`r`n")
            'acct-e' = $accountPresentConfig
        }
        $originalSave = ${function:Save-ConfigFileBackup}
        function Save-ConfigFileBackup {
            param($Context, $BackupRoot, $RelativePath, $Bytes, $SourcePath, $Operation)
            $path = & $originalSave -Context $Context -BackupRoot $BackupRoot -RelativePath $RelativePath -Bytes $Bytes -SourcePath $SourcePath -Operation $Operation
            if ($RelativePath -like 'accounts\acct-d\*') { [IO.File]::AppendAllText($SourcePath, "# other-writer`r`n", $utf8) }
            return $path
        }
        $captured = Get-FlaUIConsole -Codex $codex -Accounts $accounts
        $warnings = $captured.Warnings -join "`n"
        $info = $captured.Info -join "`n"
        $everything = $warnings + "`n" + $info
        $perAccount = @('acct-a', 'acct-b', 'acct-c', 'acct-d') | ForEach-Object { $name = $_; @($captured.Warnings | Where-Object { $_.Contains($name) -and $_.Contains('其他帳號照常處理') }).Count -eq 1 }
        @($perAccount | Where-Object { -not $_ }).Count -eq 0 -and $warnings -match '不存在' -and $warnings -match '寫法|歧義|可能已有' -and $warnings -match '被其他程式改動' -and $info -match '已更新 1、未變更 0、略過 4' -and -not $everything.Contains($secret) -and $captured.Result[0].Problems -eq 4
    }
    Test-Case 'MS04 摘要：新增與更新時桌面版與帳號件數；重複執行為未變更；-WhatIf 標明預覽且帳號為預覽件數；沒有登記帳號時標明沒有登記' {
        Reset-Stubs
        $codex = New-CodexFixture -Text $baseConfig
        $accounts = New-AccountFixture -Config @{ 'acct-a' = $accountPresentConfig; 'acct-b' = $baseConfig }
        $preview = Get-FlaUIConsole -Codex $codex -Accounts $accounts -WhatIfRun
        $first = Get-FlaUIConsole -Codex $codex -Accounts $accounts
        $second = Get-FlaUIConsole -Codex $codex -Accounts $accounts
        $codex2 = New-CodexFixture -Text $baseConfig
        $none = Get-FlaUIConsole -Codex $codex2 -Accounts ([pscustomobject]@{ Machine = (Join-Path (New-TestDirectory) 'none.json'); Backups = (Join-Path (New-TestDirectory) 'backups') })
        ($preview.Info -join "`n") -match 'FlaUI 摘要（預覽' -and ($preview.Info -join "`n") -match '預覽將更新 2' -and ($first.Info -join "`n") -match '桌面版 新增；派工帳號 已更新 2、未變更 0、略過 0' -and
        ($second.Info -join "`n") -match '桌面版 未變更；派工帳號 已更新 0、未變更 2、略過 0' -and ($none.Info -join "`n") -match '桌面版 新增；派工帳號 沒有登記'
    }

    # ---- 登記（Invoke-McpRegistration） ----
    Test-Case 'RG01 只選 mcp-lab：登記 11 個 http 伺服器，不登記 infra-lab，不碰 Codex 桌面版設定檔' {
        Reset-Stubs
        $userMcp = New-UserMcpFile -Exclude ($template | ForEach-Object { $_.Name })
        $codex = New-CodexFixture -Text $baseConfig
        $hash = Get-TestBytesHex $codex.Config
        $captured = Invoke-Captured { Invoke-McpRegistration -Target @('mcp-lab') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' }
        $names = @($script:CliCalls | ForEach-Object { $_[6] })
        $null -eq $captured.Error -and $script:CliCalls.Count -eq 11 -and $names -notcontains 'infra-lab' -and $captured.Result[0].Problems -eq 0 -and (Get-TestBytesHex $codex.Config) -ceq $hash -and $script:WslCalls -eq 0
    }
    Test-Case 'RG02 只選 infra-lab：以參數登記 1 個，引數與設計相同，不登記 mcp-lab' {
        Reset-Stubs
        $userMcp = New-UserMcpFile -Exclude ($template | ForEach-Object { $_.Name })
        $codex = New-CodexFixture -Text $baseConfig
        $captured = Invoke-Captured { Invoke-McpRegistration -Target @('infra-lab') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo }
        $expected = @('mcp', 'add', '--transport', 'stdio', '--scope', 'user', 'infra-lab', '--', 'wsl.exe', '-d', $infraLabDistro, '-e', 'bash', ($infraLabRepo + '/scripts/mcp.sh'))
        $null -eq $captured.Error -and $script:CliCalls.Count -eq 1 -and (Join-Arguments $script:CliCalls[0]) -ceq (Join-Arguments $expected) -and $captured.Result[0].Problems -eq 0
    }
    Test-Case 'RG03 只選 FlaUI：寫入桌面版設定檔，並對 Claude 使用者層呼叫一次 mcp add flaui-mcp（路徑同桌面版）；未選的 Claude 項目（mcp-lab、infra-lab、playwright）不被處理' {
        Reset-Stubs
        $userMcp = New-UserMcpFile -Exclude (@($template | ForEach-Object { $_.Name }) + @('playwright', 'flaui-mcp'))
        $codex = New-CodexFixture -Text $baseConfig
        $captured = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' }
        $expectedCall = @('mcp', 'add', '--transport', 'stdio', '--scope', 'user', 'flaui-mcp', '--', $codex.Executable)
        $null -eq $captured.Error -and $script:CliCalls.Count -eq 1 -and (Join-Arguments $script:CliCalls[0]) -ceq (Join-Arguments $expectedCall) -and $captured.Result[0].FlaUIResult.Status -eq 'added' -and (Get-FileText -Path $codex.Config).Contains("command = '" + $codex.Executable + "'") -and $captured.Result[0].Problems -eq 0
    }
    Test-Case 'RG04 四項全選：重複執行不產生重複登記（第一次 14 次 mcp add：11 個 http、infra-lab、playwright、flaui-mcp 各一；第二次零次、FlaUI unchanged）' {
        Reset-Stubs
        $emptyMcp = New-UserMcpFile -Exclude (@($template | ForEach-Object { $_.Name }) + @('playwright', 'flaui-mcp'))
        $codex = New-CodexFixture -Text $baseConfig
        $first = Invoke-Captured { Invoke-McpRegistration -Target @('mcp-lab', 'infra-lab', 'flaui', 'playwright') -McpTemplatePath $mcpTemplatePath -UserMcpPath $emptyMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo -LocalAppData $testLocalAppData }
        $firstCalls = $script:CliCalls.Count
        $script:CliCalls.Clear()
        $fullMcp = New-UserMcpFile -FlaUICommand $codex.Executable
        $second = Invoke-Captured { Invoke-McpRegistration -Target @('mcp-lab', 'infra-lab', 'flaui', 'playwright') -McpTemplatePath $mcpTemplatePath -UserMcpPath $fullMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo -LocalAppData $testLocalAppData }
        $firstCalls -eq 14 -and $script:CliCalls.Count -eq 0 -and $second.Result[0].FlaUIResult.Status -eq 'unchanged' -and $first.Result[0].Problems -eq 0 -and $second.Result[0].Problems -eq 0
    }
    Test-Case 'RG05 已存在的其他登記不被覆寫：內容與範本不同只回報（不算問題、不呼叫 add、警告不含現有值）' {
        Reset-Stubs
        $userMcp = New-UserMcpFile
        $json = [IO.File]::ReadAllText($userMcp).Replace('9840', '19999')
        [IO.File]::WriteAllText($userMcp, $json, $utf8)
        $codex = New-CodexFixture -Text $baseConfig
        $captured = Invoke-Captured { Invoke-McpRegistration -Target @('mcp-lab') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' }
        $null -eq $captured.Error -and $script:CliCalls.Count -eq 0 -and $captured.Result[0].Problems -eq 0 -and (($captured.Warnings -join "`n") -match 'claude mcp remove mcp-reader --scope user') -and (($captured.Warnings -join "`n") -notmatch '19999')
    }
    Test-Case 'RG06 問題計入結束碼：infra-lab 缺值、FlaUI 執行檔不存在（Claude 步驟略過、不重複計數）、桌面版設定檔不存在（Claude 步驟仍登記）、mcp add 失敗各算一個問題' {
        Reset-Stubs
        $userMcp = New-UserMcpFile -Exclude (@($template | ForEach-Object { $_.Name }) + @('playwright', 'flaui-mcp'))
        $codex = New-CodexFixture
        $noValues = Invoke-Captured { Invoke-McpRegistration -Target @('infra-lab') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' }
        $noExe = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath (Join-Path $codex.Directory 'none.exe') -BackupRoot $codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' }
        $callsAfterNoExe = $script:CliCalls.Count
        $noConfig = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' }
        $callsAfterNoConfig = $script:CliCalls.Count
        $script:CliHandler = { param($Arguments) [pscustomobject]@{ ExitCode = 1; Output = 'boom' } }
        $addFails = Invoke-Captured { Invoke-McpRegistration -Target @('infra-lab') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo }
        $noValues.Result[0].Problems -eq 1 -and $noExe.Result[0].Problems -eq 1 -and $callsAfterNoExe -eq 0 -and $noConfig.Result[0].Problems -eq 1 -and $callsAfterNoConfig -eq 1 -and $addFails.Result[0].Problems -eq 1 -and -not (Test-Path -LiteralPath $codex.Config)
    }
    Test-Case 'RG07 -WhatIf：零次 mcp add（含 playwright 與 flaui-mcp 的 Claude 登記），FlaUI 不寫入、不備份' {
        Reset-Stubs
        $userMcp = New-UserMcpFile -Exclude (@($template | ForEach-Object { $_.Name }) + @('playwright', 'flaui-mcp'))
        $codex = New-CodexFixture -Text $baseConfig
        $hash = Get-TestBytesHex $codex.Config
        $captured = Invoke-Captured { Invoke-McpRegistration -Target @('mcp-lab', 'infra-lab', 'flaui', 'playwright') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo -LocalAppData $testLocalAppData -WhatIf }
        $null -eq $captured.Error -and $script:CliCalls.Count -eq 0 -and $captured.Result[0].FlaUIResult.Status -eq 'whatif' -and (Get-TestBytesHex $codex.Config) -ceq $hash -and -not (Test-Path -LiteralPath $codex.Backups) -and $captured.Result[0].Problems -eq 0
    }
    Test-Case 'RG08 選 infra-lab 但 WSL 不存在：警告後仍登記（只寫設定），不算問題；只選 mcp-lab 時不檢查 WSL' {
        Reset-Stubs
        $script:WslStatus = 'missing'
        $userMcp = New-UserMcpFile -Exclude ($template | ForEach-Object { $_.Name })
        $codex = New-CodexFixture -Text $baseConfig
        $infra = Invoke-Captured { Invoke-McpRegistration -Target @('infra-lab') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo }
        $infraCalls = $script:CliCalls.Count
        $infraWslCalls = $script:WslCalls
        $script:CliCalls.Clear()
        $script:WslCalls = 0
        $lab = Invoke-Captured { Invoke-McpRegistration -Target @('mcp-lab') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' }
        $infraCalls -eq 1 -and $infraWslCalls -eq 1 -and @($infra.Warnings | Where-Object { $_.Contains('WSL') }).Count -eq 1 -and $infra.Result[0].Problems -eq 0 -and $script:WslCalls -eq 0 -and $lab.Result[0].Problems -eq 0
    }
    Test-Case 'RG09 找不到 claude 或登記檔無法讀取時，Claude 項目以警告回報並計為問題，FlaUI 項目照常處理' {
        Reset-Stubs
        $codex = New-CodexFixture -Text $baseConfig
        $bad = Join-Path (New-TestDirectory) 'claude.json'
        [IO.File]::WriteAllText($bad, '{ not json', $utf8)
        $unreadable = Invoke-Captured { Invoke-McpRegistration -Target @('mcp-lab', 'flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $bad -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' }
        $savedPath = $env:PATH
        try {
            $env:PATH = (New-TestDirectory)
            $noClaude = Invoke-Captured { Invoke-McpRegistration -Target @('mcp-lab') -McpTemplatePath $mcpTemplatePath -UserMcpPath $bad -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' }
        }
        finally { $env:PATH = $savedPath }
        $script:CliCalls.Count -eq 0 -and $unreadable.Result[0].Problems -eq 1 -and $unreadable.Result[0].FlaUIResult.Status -in @('added', 'updated') -and (($unreadable.Warnings -join "`n") -match '無法讀取') -and $noClaude.Result[0].Problems -eq 1 -and (($noClaude.Warnings -join "`n") -match '找不到 claude CLI')
    }

    # ---- 唯讀檢查（Invoke-McpRegistrationCheck） ----
    Test-Case 'CK01 四項全部登記（含 Claude 端的 playwright 與 flaui-mcp）且 WSL 可用：結束碼 0；檢查不寫入任何檔案（Claude 登記檔與桌面版設定檔雜湊不變）' {
        Reset-Stubs
        $codex = New-CodexFixture -Text $presentConfig.Replace('X:\old\FlaUI.Mcp.exe', 'PLACEHOLDER')
        $userMcp = New-UserMcpFile -FlaUICommand $codex.Executable
        [IO.File]::WriteAllText($codex.Config, (Get-FileText -Path $codex.Config).Replace('PLACEHOLDER', $codex.Executable), $utf8)
        $hashes = (Get-TestBytesHex $userMcp) + (Get-TestBytesHex $codex.Config)
        $snapshot = Get-FileSnapshot -Directory (Split-Path -Parent $codex.Directory)
        $captured = Invoke-Captured { Invoke-McpRegistrationCheck -Target @('mcp-lab', 'infra-lab', 'flaui', 'playwright') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -InfraLabDistro '' -InfraLabWslRepo '' -LocalAppData $testLocalAppData }
        $null -eq $captured.Error -and $captured.Result[0] -eq 0 -and $script:CliCalls.Count -eq 0 -and ((Get-TestBytesHex $userMcp) + (Get-TestBytesHex $codex.Config)) -ceq $hashes -and (Get-FileSnapshot -Directory (Split-Path -Parent $codex.Directory)) -ceq $snapshot
    }
    Test-Case 'CK02 缺少登記時結束碼 1 並指出缺哪一項與補救方式：mcp-lab 缺一個、infra-lab 未登記、playwright 未登記、FlaUI 項目不存在' {
        Reset-Stubs
        $userMcp = New-UserMcpFile -Exclude @('mcp-reader', 'infra-lab', 'playwright')
        $codex = New-CodexFixture -Text $baseConfig
        $captured = Invoke-Captured { Invoke-McpRegistrationCheck -Target @('mcp-lab', 'infra-lab', 'flaui', 'playwright') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -InfraLabDistro '' -InfraLabWslRepo '' -LocalAppData $testLocalAppData }
        $text = $captured.Info -join "`n"
        $captured.Result[0] -eq 1 -and $text -match '\[缺少\] mcp-reader.*Register-McpServer\.ps1 -McpLab' -and $text -match '\[缺少\] infra-lab.*-InfraLabDistro' -and $text -match '\[缺少\] flaui-mcp.*Register-McpServer\.ps1 -FlaUI' -and $text -match '\[缺少\] playwright（Claude Code）.*Register-McpServer\.ps1 -Playwright'
    }
    Test-Case 'CK03 mcp-lab 服務未啟動只在備註提示，不影響結束碼；登記全部相符時結束碼為 0' {
        Reset-Stubs
        $openListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $closedListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $openListener.Start(); $closedListener.Start()
        $openPort = $openListener.LocalEndpoint.Port
        $closedPort = $closedListener.LocalEndpoint.Port
        $closedListener.Stop()
        try {
            $directory = New-TestDirectory
            $templateFile = Join-Path $directory 'servers.json'
            [IO.File]::WriteAllText($templateFile, ('{ "servers": [ { "name": "mcp-open-test", "type": "http", "url": "http://127.0.0.1:' + $openPort + '/mcp" }, { "name": "mcp-closed-test", "type": "http", "url": "http://127.0.0.1:' + $closedPort + '/mcp" } ] }'), $utf8)
            $userFile = Join-Path $directory 'claude.json'
            [IO.File]::WriteAllText($userFile, ('{"mcpServers":{"mcp-open-test":{"type":"http","url":"http://127.0.0.1:' + $openPort + '/mcp"},"mcp-closed-test":{"type":"http","url":"http://127.0.0.1:' + $closedPort + '/mcp"}}}'), $utf8)
            $captured = Invoke-Captured { Invoke-McpRegistrationCheck -Target @('mcp-lab') -McpTemplatePath $templateFile -UserMcpPath $userFile -CodexConfigPath (Join-Path $directory 'none.toml') -FlaUIPath (Join-Path $directory 'none.exe') -InfraLabDistro '' -InfraLabWslRepo '' }
        }
        finally { $openListener.Stop() }
        $text = $captured.Info -join "`n"
        $captured.Result[0] -eq 0 -and $text -match '備註：mcp-lab 的 1 個埠無回應（mcp-closed-test）' -and $text -notmatch 'mcp-open-test）'
    }
    Test-Case 'CK04 選 infra-lab 時 WSL 不存在：結束碼 1 並附補救方式；只選 mcp-lab 時不檢查 WSL，結束碼不受 WSL 影響' {
        Reset-Stubs
        $script:WslStatus = 'missing'
        $userMcp = New-UserMcpFile
        $codex = New-CodexFixture -Text $baseConfig
        $infra = Invoke-Captured { Invoke-McpRegistrationCheck -Target @('infra-lab') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -InfraLabDistro '' -InfraLabWslRepo '' }
        $wslCalls = $script:WslCalls
        $script:WslCalls = 0
        $lab = Invoke-Captured { Invoke-McpRegistrationCheck -Target @('mcp-lab') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -InfraLabDistro '' -InfraLabWslRepo '' }
        $infra.Result[0] -eq 1 -and (($infra.Info -join "`n") -match 'wsl --install') -and $wslCalls -eq 1 -and $lab.Result[0] -eq 0 -and $script:WslCalls -eq 0
    }
    Test-Case 'CK05 FlaUI 的 command 與指定路徑不同為內容不符（結束碼 1，列出目前值）；執行檔不存在只在備註；設定檔不存在為缺少且不建立' {
        Reset-Stubs
        $userMcp = New-UserMcpFile
        $codex = New-CodexFixture -Text $presentConfig
        $differs = Invoke-Captured { Invoke-McpRegistrationCheck -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath (Join-Path $codex.Directory 'none\FlaUI.Mcp.exe') -InfraLabDistro '' -InfraLabWslRepo '' }
        $noConfig = New-CodexFixture
        $missing = Invoke-Captured { Invoke-McpRegistrationCheck -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $noConfig.Config -FlaUIPath $noConfig.Executable -InfraLabDistro '' -InfraLabWslRepo '' }
        $differsText = $differs.Info -join "`n"
        $differs.Result[0] -eq 1 -and $differsText -match '\[內容不符\] flaui-mcp' -and $differsText -match 'X:\\old\\FlaUI\.Mcp\.exe' -and $differsText -match '備註：FlaUI\.Mcp 執行檔不存在' -and $missing.Result[0] -eq 1 -and -not (Test-Path -LiteralPath $noConfig.Config)
    }
    Test-Case 'CK06 登記檔無法讀取為無法判定（結束碼 1）；登記檔不存在時所選的 11 個項目各為缺少' {
        Reset-Stubs
        $codex = New-CodexFixture -Text $baseConfig
        $bad = Join-Path (New-TestDirectory) 'claude.json'
        [IO.File]::WriteAllText($bad, '{ not json', $utf8)
        $unreadable = Invoke-Captured { Invoke-McpRegistrationCheck -Target @('mcp-lab') -McpTemplatePath $mcpTemplatePath -UserMcpPath $bad -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -InfraLabDistro '' -InfraLabWslRepo '' }
        $absent = Invoke-Captured { Invoke-McpRegistrationCheck -Target @('mcp-lab') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path (New-TestDirectory) 'none.json') -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -InfraLabDistro '' -InfraLabWslRepo '' }
        $unreadable.Result[0] -eq 1 -and (($unreadable.Info -join "`n") -match '\[無法判定\]') -and $absent.Result[0] -eq 1 -and @([regex]::Matches(($absent.Info -join "`n"), '\[缺少\] mcp-')).Count -eq 11
    }

    # ---- 唯讀檢查：派工帳號的 command 與桌面版一致 ----
    function New-ConsistentCodex {
        # 桌面版設定檔的 flaui-mcp command 已是 Executable。
        $codex = New-CodexFixture -Text $presentConfig.Replace('X:\old\FlaUI.Mcp.exe', 'PLACEHOLDER')
        [IO.File]::WriteAllText($codex.Config, (Get-FileText -Path $codex.Config).Replace('PLACEHOLDER', $codex.Executable), $utf8)
        return $codex
    }
    Test-Case 'CK07 帳號與桌面版的 command 一致時結束碼 0；不一致時為內容不符、指出帳號名稱並使結束碼為 1；檢查不寫入任何檔案' {
        Reset-Stubs
        $codex = New-ConsistentCodex
        $matching = $accountPresentConfig.Replace('X:\old\FlaUI.Mcp.exe', $codex.Executable)
        $consistent = New-AccountFixture -Config @{ 'acct-a' = $matching; 'acct-b' = $matching }
        $inconsistent = New-AccountFixture -Config @{ 'acct-a' = $matching; 'acct-b' = $accountPresentConfig }
        $claudeRegistered = New-UserMcpFile -FlaUICommand $codex.Executable
        $snapshot = (Get-FileSnapshot -Directory $consistent.Root) + (Get-FileSnapshot -Directory $inconsistent.Root) + (Get-FileSnapshot -Directory (Split-Path -Parent $codex.Directory))
        $ok = Invoke-Captured { Invoke-McpRegistrationCheck -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $claudeRegistered -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $consistent.Machine }
        $bad = Invoke-Captured { Invoke-McpRegistrationCheck -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $claudeRegistered -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $inconsistent.Machine }
        $badText = $bad.Info -join "`n"
        $okText = $ok.Info -join "`n"
        $ok.Result[0] -eq 0 -and $okText -match '統計：共 4 項，符合 4、其他 0' -and $bad.Result[0] -eq 1 -and $badText -match '\[內容不符\] flaui-mcp（派工帳號 acct-b）' -and $badText -match 'X:\\old\\FlaUI\.Mcp\.exe' -and $badText -notmatch '\[內容不符\] flaui-mcp（派工帳號 acct-a）' -and
        ((Get-FileSnapshot -Directory $consistent.Root) + (Get-FileSnapshot -Directory $inconsistent.Root) + (Get-FileSnapshot -Directory (Split-Path -Parent $codex.Directory))) -ceq $snapshot
    }
    Test-Case 'CK08 帳號缺少 config.toml、沒有 flaui-mcp 表、表沒有 command 為缺少；寫法無法確定為無法判定；桌面版沒有可比對的 command 時各帳號為無法判定；結束碼皆為 1' {
        Reset-Stubs
        $codex = New-ConsistentCodex
        $accounts = New-AccountFixture -Name @('acct-a', 'acct-b', 'acct-c', 'acct-d') -NoConfig @('acct-a') -Config @{
            'acct-b' = $baseConfig
            'acct-c' = "[mcp_servers.flaui-mcp]`r`nstartup_timeout_sec = 60.0`r`n"
            'acct-d' = "[mcp_servers.flaui-mcp]`r`ncommand = 'X:\old.exe' # note`r`n"
        }
        $captured = Invoke-Captured { Invoke-McpRegistrationCheck -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path (New-TestDirectory) 'none.json') -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $accounts.Machine }
        $text = $captured.Info -join "`n"
        $noDesktop = New-CodexFixture -Text $baseConfig
        $undetermined = Invoke-Captured { Invoke-McpRegistrationCheck -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path (New-TestDirectory) 'none.json') -CodexConfigPath $noDesktop.Config -FlaUIPath $noDesktop.Executable -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $accounts.Machine }
        $captured.Result[0] -eq 1 -and $text -match '\[缺少\] flaui-mcp（派工帳號 acct-a）' -and $text -match '\[缺少\] flaui-mcp（派工帳號 acct-b）' -and $text -match '\[缺少\] flaui-mcp（派工帳號 acct-c）' -and $text -match '\[無法判定\] flaui-mcp（派工帳號 acct-d）' -and
        $undetermined.Result[0] -eq 1 -and @([regex]::Matches(($undetermined.Info -join "`n"), '\[無法判定\] flaui-mcp（派工帳號')).Count -eq 4
    }
    Test-Case 'CK09 沒有登記帳號時只檢查桌面版並在備註說明，結束碼不受影響；登記檔不合法時為無法判定（結束碼 1）' {
        Reset-Stubs
        $codex = New-ConsistentCodex
        $directory = New-TestDirectory
        $bad = Join-Path $directory 'machine.json'
        [IO.File]::WriteAllText($bad, '{ not json', $utf8)
        $claudeRegistered = New-UserMcpFile -FlaUICommand $codex.Executable
        $none = Invoke-Captured { Invoke-McpRegistrationCheck -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $claudeRegistered -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath (Join-Path $directory 'none.json') }
        $omitted = Invoke-Captured { Invoke-McpRegistrationCheck -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $claudeRegistered -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -InfraLabDistro '' -InfraLabWslRepo '' }
        $invalid = Invoke-Captured { Invoke-McpRegistrationCheck -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path $directory 'none.json') -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -InfraLabDistro '' -InfraLabWslRepo '' -MachineConfigPath $bad }
        $none.Result[0] -eq 0 -and (($none.Info -join "`n") -match '備註：沒有登記的派工帳號') -and $omitted.Result[0] -eq 0 -and $invalid.Result[0] -eq 1 -and (($invalid.Info -join "`n") -match '\[無法判定\] flaui-mcp（派工帳號）')
    }

    # ---- Playwright MCP（Claude Code 使用者層） ----
    $playwrightArguments = @('mcp', 'add', '-e', ('PLAYWRIGHT_MCP_OUTPUT_DIR=' + $testPlaywrightDir), '--transport', 'stdio', '--scope', 'user', 'playwright', '--', 'cmd', '/c', 'npx', '-y', '@playwright/mcp@latest')
    function Invoke-PlaywrightRegistration {
        param([string]$UserMcp, [string]$OutputDir = '', [string]$LocalAppData = $script:testLocalAppData, [switch]$WhatIfRun, [string[]]$Target = @('playwright'))
        $codex = New-CodexFixture -Text $baseConfig
        if ($WhatIfRun) { return (Invoke-Captured { Invoke-McpRegistration -Target $Target -McpTemplatePath $mcpTemplatePath -UserMcpPath $UserMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' -PlaywrightOutputDir $OutputDir -LocalAppData $LocalAppData -WhatIf }) }
        return (Invoke-Captured { Invoke-McpRegistration -Target $Target -McpTemplatePath $mcpTemplatePath -UserMcpPath $UserMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' -PlaywrightOutputDir $OutputDir -LocalAppData $LocalAppData })
    }
    function Invoke-PlaywrightCheck {
        param([string]$UserMcp, [string]$OutputDir = '', [string]$LocalAppData = $script:testLocalAppData)
        $codex = New-CodexFixture -Text $baseConfig
        return (Invoke-Captured { Invoke-McpRegistrationCheck -Target @('playwright') -McpTemplatePath $mcpTemplatePath -UserMcpPath $UserMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -InfraLabDistro '' -InfraLabWslRepo '' -PlaywrightOutputDir $OutputDir -LocalAppData $LocalAppData })
    }
    Test-Case 'PW01 未登記時以假 claude 收到一次 mcp add：引數序逐項等於 mcp add -e PLAYWRIGHT_MCP_OUTPUT_DIR=<dir> --transport stdio --scope user playwright -- cmd /c npx -y @playwright/mcp@latest；沒有問題；不碰 Codex 設定檔' {
        Reset-Stubs
        $userMcp = New-UserMcpFile -Exclude @('playwright')
        $captured = Invoke-PlaywrightRegistration -UserMcp $userMcp
        $null -eq $captured.Error -and $script:CliCalls.Count -eq 1 -and (Join-Arguments $script:CliCalls[0]) -ceq (Join-Arguments $playwrightArguments) -and $captured.Result[0].Problems -eq 0 -and @($captured.Result[0].ClaudeFixedStdioResults | ForEach-Object { $_.Status }) -join ',' -ceq 'added' -and $script:WslCalls -eq 0
    }
    Test-Case 'PW02 已登記且相同：零次 mcp add（重跑不重複）；沒有問題' {
        Reset-Stubs
        $captured = Invoke-PlaywrightRegistration -UserMcp (New-UserMcpFile)
        $null -eq $captured.Error -and $script:CliCalls.Count -eq 0 -and $captured.Result[0].Problems -eq 0 -and @($captured.Result[0].ClaudeFixedStdioResults | ForEach-Object { $_.Status }) -join ',' -ceq 'unchanged'
    }
    Test-Case 'PW03 已登記但 command、args、env 各自不同：不覆寫（零次呼叫），不算問題，警告指出欄位且不印出現有值' {
        Reset-Stubs
        $bad = @()
        $secret = 'SECRET-SENTINEL-DIR'
        $variants = [ordered]@{
            command = { param($e) $e['command'] = 'npx' }
            args    = { param($e) $e['args'] = @('/c', 'npx', '-y', '@playwright/mcp@0.0.1') }
            env     = { param($e) $e['env'] = [ordered]@{ PLAYWRIGHT_MCP_OUTPUT_DIR = ('D:\' + $secret) } }
        }
        foreach ($key in $variants.Keys) {
            $userMcp = New-UserMcpFile -Exclude @('playwright')
            $document = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($userMcp)) -AsHashTable
            $entry = [ordered]@{ type = 'stdio'; command = 'cmd'; args = @('/c', 'npx', '-y', '@playwright/mcp@latest'); env = [ordered]@{ PLAYWRIGHT_MCP_OUTPUT_DIR = $testPlaywrightDir } }
            & $variants[$key] $entry
            $document['mcpServers']['playwright'] = $entry
            [IO.File]::WriteAllText($userMcp, ($document | ConvertTo-Json -Depth 8), $utf8)
            $captured = Invoke-PlaywrightRegistration -UserMcp $userMcp
            $warnings = $captured.Warnings -join "`n"
            if ($script:CliCalls.Count -ne 0 -or $captured.Result[0].Problems -ne 0 -or $warnings -notmatch ('playwright 的 ' + $key) -or $warnings.Contains($secret)) { $bad += $key }
            Reset-Stubs
        }
        $bad.Count -eq 0
    }
    Test-Case 'PW04 -WhatIf：零次 mcp add，結果為預演，沒有問題' {
        Reset-Stubs
        $captured = Invoke-PlaywrightRegistration -UserMcp (New-UserMcpFile -Exclude @('playwright')) -WhatIfRun
        $null -eq $captured.Error -and $script:CliCalls.Count -eq 0 -and $captured.Result[0].Problems -eq 0 -and @($captured.Result[0].ClaudeFixedStdioResults | ForEach-Object { $_.Status }) -join ',' -ceq 'whatif'
    }
    Test-Case 'PW05 輸出目錄含禁用字元（&）或不是絕對路徑：不呼叫 claude，各算一個問題並指出原因' {
        Reset-Stubs
        $ampersand = Invoke-PlaywrightRegistration -UserMcp (New-UserMcpFile -Exclude @('playwright')) -OutputDir 'D:\a&b'
        $relative = Invoke-PlaywrightRegistration -UserMcp (New-UserMcpFile -Exclude @('playwright')) -OutputDir 'out\dir'
        $script:CliCalls.Count -eq 0 -and $ampersand.Result[0].Problems -eq 1 -and $relative.Result[0].Problems -eq 1 -and (($ampersand.Warnings -join "`n") -match '輸出目錄') -and (($relative.Warnings -join "`n") -match '輸出目錄')
    }
    Test-Case 'PW06 Resolve-PlaywrightOutputDir：未指定時回傳 <LocalAppData>\ai-agents\playwright-mcp；指定時用指定值；LocalAppData 未設定或空白時回傳錯誤並指向 -PlaywrightOutputDir（指定目錄時不受影響）；無效路徑回傳錯誤' {
        $default = Resolve-PlaywrightOutputDir -OutputDir '' -LocalAppData $testLocalAppData
        $explicit = Resolve-PlaywrightOutputDir -OutputDir 'D:\Shared\playwright-out' -LocalAppData $testLocalAppData
        $unset = Resolve-PlaywrightOutputDir -OutputDir '' -LocalAppData ''
        $blank = Resolve-PlaywrightOutputDir -OutputDir '' -LocalAppData '   '
        $explicitWithoutLocalAppData = Resolve-PlaywrightOutputDir -OutputDir 'D:\Shared\playwright-out' -LocalAppData ''
        $invalid = Resolve-PlaywrightOutputDir -OutputDir 'D:\bad"dir' -LocalAppData $testLocalAppData
        $relativeLocalAppData = Resolve-PlaywrightOutputDir -OutputDir '' -LocalAppData 'rel\appdata'
        $default.Ok -and $default.Path -ceq $testPlaywrightDir -and $explicit.Ok -and $explicit.Path -ceq 'D:\Shared\playwright-out' -and
        -not $unset.Ok -and $unset.Message.Contains('LOCALAPPDATA') -and $unset.Message.Contains('-PlaywrightOutputDir') -and -not $blank.Ok -and
        $explicitWithoutLocalAppData.Ok -and $explicitWithoutLocalAppData.Path -ceq 'D:\Shared\playwright-out' -and -not $invalid.Ok -and -not $relativeLocalAppData.Ok
    }
    Test-Case 'PW07 從連結的 worktree 執行且未指定輸出目錄：照常登記一次，-e PLAYWRIGHT_MCP_OUTPUT_DIR= 的值為注入的 LocalAppData 路徑，沒有問題；LocalAppData 未設定且未指定時不呼叫 claude，算一個問題，警告指向 -PlaywrightOutputDir' {
        Reset-Stubs
        $userMcp = New-UserMcpFile -Exclude @('playwright')
        Push-Location -LiteralPath $testWorktreeRoot
        try { $fromWorktree = Invoke-PlaywrightRegistration -UserMcp $userMcp }
        finally { Pop-Location }
        $callsFromWorktree = $script:CliCalls.Count
        $registeredDirectory = if ($callsFromWorktree -eq 1) { @($script:CliCalls[0]) } else { @() }
        Reset-Stubs
        $withoutLocalAppData = Invoke-PlaywrightRegistration -UserMcp $userMcp -LocalAppData ''
        $callsFromWorktree -eq 1 -and $fromWorktree.Result[0].Problems -eq 0 -and ($registeredDirectory -contains ('PLAYWRIGHT_MCP_OUTPUT_DIR=' + $testPlaywrightDir)) -and
        $script:CliCalls.Count -eq 0 -and $withoutLocalAppData.Result[0].Problems -eq 1 -and (($withoutLocalAppData.Warnings -join "`n") -match '-PlaywrightOutputDir')
    }
    Test-Case 'PW08 Claude 端前置失敗只計一個問題並略過其後的 Claude 步驟：登記檔無法讀取時 mcp-lab 加 playwright 為 1、只選 playwright 為 1；找不到 claude 時為 1；零次呼叫' {
        Reset-Stubs
        $bad = Join-Path (New-TestDirectory) 'claude.json'
        [IO.File]::WriteAllText($bad, '{ not json', $utf8)
        $both = Invoke-PlaywrightRegistration -UserMcp $bad -Target @('mcp-lab', 'playwright')
        $only = Invoke-PlaywrightRegistration -UserMcp $bad
        $savedPath = $env:PATH
        try {
            $env:PATH = (New-TestDirectory)
            $noClaude = Invoke-PlaywrightRegistration -UserMcp (New-UserMcpFile -Exclude @('playwright'))
        }
        finally { $env:PATH = $savedPath }
        $script:CliCalls.Count -eq 0 -and $both.Result[0].Problems -eq 1 -and $only.Result[0].Problems -eq 1 -and $noClaude.Result[0].Problems -eq 1 -and (($noClaude.Warnings -join "`n") -match '找不到 claude CLI')
    }
    Test-Case 'PW09 mcp add 結束碼非零時該項為 failed、算一個問題，不重試；其餘項目照常處理' {
        Reset-Stubs
        $script:CliHandler = { param($Arguments) [pscustomobject]@{ ExitCode = 1; Output = 'boom' } }
        $captured = Invoke-PlaywrightRegistration -UserMcp (New-UserMcpFile -Exclude @('playwright'))
        $script:CliCalls.Count -eq 1 -and $captured.Result[0].Problems -eq 1 -and @($captured.Result[0].ClaudeFixedStdioResults | ForEach-Object { $_.Status }) -join ',' -ceq 'failed'
    }
    Test-Case 'PW10 -Check：登記相符為 ok（結束碼 0，不寫檔）；未登記為缺少；command、args、env 不同為內容不符；登記檔無法讀取為無法判定；LocalAppData 未設定且未指定輸出目錄為無法判定；結束碼皆為 1' {
        Reset-Stubs
        $ok = New-UserMcpFile
        $hash = Get-TestBytesHex $ok
        $okRun = Invoke-PlaywrightCheck -UserMcp $ok
        $missing = Invoke-PlaywrightCheck -UserMcp (New-UserMcpFile -Exclude @('playwright'))
        $otherDirectory = Invoke-PlaywrightCheck -UserMcp (New-UserMcpFile -PlaywrightDir 'D:\Other\out')
        $bad = Join-Path (New-TestDirectory) 'claude.json'
        [IO.File]::WriteAllText($bad, '{ not json', $utf8)
        $unreadable = Invoke-PlaywrightCheck -UserMcp $bad
        $noLocalAppData = Invoke-PlaywrightCheck -UserMcp $ok -LocalAppData ''
        $okRun.Result[0] -eq 0 -and (($okRun.Info -join "`n") -match '\[符合\] playwright（Claude Code）') -and (Get-TestBytesHex $ok) -ceq $hash -and $script:CliCalls.Count -eq 0 -and
        $missing.Result[0] -eq 1 -and (($missing.Info -join "`n") -match '\[缺少\] playwright（Claude Code）.*-Playwright') -and
        $otherDirectory.Result[0] -eq 1 -and (($otherDirectory.Info -join "`n") -match '\[內容不符\] playwright（Claude Code）.*env') -and
        $unreadable.Result[0] -eq 1 -and (($unreadable.Info -join "`n") -match '\[無法判定\] playwright（Claude Code）') -and
        $noLocalAppData.Result[0] -eq 1 -and (($noLocalAppData.Info -join "`n") -match '\[無法判定\] playwright（Claude Code）.*-PlaywrightOutputDir')
    }
    Test-Case 'PW14 -Check：type、command、env 為單元素陣列或錯誤型別（物件、數字）時判為內容不符並指出欄位，不誤判為符合，也不寫檔' {
        Reset-Stubs
        $override = {
            param([string]$Name, [hashtable]$Fields)
            $path = New-UserMcpFile
            $document = ConvertFrom-Json -InputObject (Get-FileText -Path $path) -AsHashtable -Depth 10
            foreach ($key in $Fields.Keys) { $document['mcpServers'][$Name][$key] = $Fields[$key] }
            [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $document -Depth 10), $utf8)
            return $path
        }
        $envValue = [ordered]@{ PLAYWRIGHT_MCP_OUTPUT_DIR = $script:testPlaywrightDir }
        $cases = [ordered]@{
            typeArray  = @{ type = @('stdio') }
            typeNumber = @{ type = 5 }
            commandArr = @{ command = @('cmd') }
            commandObj = @{ command = [ordered]@{ path = 'cmd' } }
            envArray   = @{ env = @($envValue) }
            envNumber  = @{ env = 7 }
        }
        $bad = @()
        foreach ($key in $cases.Keys) {
            $field = ($cases[$key].Keys | Select-Object -First 1)
            $path = & $override 'playwright' $cases[$key]
            $hash = Get-TestBytesHex $path
            $run = Invoke-PlaywrightCheck -UserMcp $path
            $text = $run.Info -join "`n"
            if ($run.Result[0] -ne 1 -or $text -notmatch ('\[內容不符\] playwright（Claude Code）.*' + $field) -or $text -match '\[符合\] playwright' -or (Get-TestBytesHex $path) -cne $hash) { $bad += $key }
        }
        $bad.Count -eq 0 -and $script:CliCalls.Count -eq 0
    }
    Test-Case 'PW11 -Check在 npx 不在 PATH 時加備註「找不到 npx」，結束碼不受影響（登記相符時仍為 0）' {
        Reset-Stubs
        $ok = New-UserMcpFile
        $savedPath = $env:PATH
        try {
            $env:PATH = (New-TestDirectory)
            $noNpx = Invoke-PlaywrightCheck -UserMcp $ok
        }
        finally { $env:PATH = $savedPath }
        $noNpx.Result[0] -eq 0 -and (($noNpx.Info -join "`n") -match '備註：找不到 npx；Playwright MCP 啟動時會失敗。腳本不安裝 Node\.js')
    }
    Test-Case 'PW12 漂移檢查：登記內容的 npx 引數（-y @playwright/mcp@latest）與登錄表 codex-test 的 playwright 設定相同；codex-test 的 playwright 仍有 PLAYWRIGHT_MCP_OUTPUT_DIR 環境變數' {
        $registry = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts\dispatch\executor-registry.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $codexTest = @($registry.executors | Where-Object { $_.id -ceq 'codex-test' })[0]
        $codexPlaywright = $codexTest.profileSettings.mcpServers.playwright
        $definition = Get-PlaywrightMcpDefinition -OutputDir $testPlaywrightDir
        $definition.Args[1] -ceq $codexPlaywright.command -and (@($definition.Args | Select-Object -Skip 2) -join ' ') -ceq (@($codexPlaywright.args) -join ' ') -and @($codexPlaywright.envVars) -contains 'PLAYWRIGHT_MCP_OUTPUT_DIR' -and
        $definition.Command -ceq 'cmd' -and $definition.Args[0] -ceq '/c' -and $definition.Env['PLAYWRIGHT_MCP_OUTPUT_DIR'] -ceq $testPlaywrightDir
    }
    Test-Case 'PW13 範本不被改動：Read-ClaudeMcpTemplate 仍回傳 12 個伺服器且不含 playwright 與 flaui-mcp；Invoke-ClaudeMcpStep 的 Group 驗證集合仍是 mcp-lab、infra-lab' {
        $names = @(Read-ClaudeMcpTemplate -Path $mcpTemplatePath | ForEach-Object { $_.Name })
        $groupAttribute = @((Get-Command Invoke-ClaudeMcpStep).Parameters['Group'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })[0]
        $names.Count -eq 12 -and $names -cnotcontains 'playwright' -and $names -cnotcontains 'flaui-mcp' -and (@($groupAttribute.ValidValues) -join ',') -ceq 'mcp-lab,infra-lab'
    }

    # ---- FlaUI.Mcp（Claude Code 使用者層） ----
    function Invoke-FlaUIClaudeRegistration {
        param($Codex, [string]$UserMcp, [string]$ExecutablePath, [switch]$WhatIfRun)
        if ([string]::IsNullOrEmpty($ExecutablePath)) { $ExecutablePath = $Codex.Executable }
        if ($WhatIfRun) { return (Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $UserMcp -CodexConfigPath $Codex.Config -FlaUIPath $ExecutablePath -BackupRoot $Codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' -WhatIf }) }
        return (Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $UserMcp -CodexConfigPath $Codex.Config -FlaUIPath $ExecutablePath -BackupRoot $Codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' })
    }
    Test-Case 'FC01 flaui-mcp 已登記且與 -FlaUIPath 相同：零次 mcp add（重跑不重複）、沒有問題；路徑不同時不覆寫（零次呼叫、不算問題、警告指出 command 不同且不印出現有路徑）' {
        Reset-Stubs
        $codex = New-CodexFixture -Text $baseConfig
        $same = Invoke-FlaUIClaudeRegistration -Codex $codex -UserMcp (New-UserMcpFile -FlaUICommand $codex.Executable)
        $sameCalls = $script:CliCalls.Count
        $codex2 = New-CodexFixture -Text $baseConfig
        $different = Invoke-FlaUIClaudeRegistration -Codex $codex2 -UserMcp (New-UserMcpFile -FlaUICommand 'X:\SECRET-OLD-PATH\FlaUI.Mcp.exe')
        $sameCalls -eq 0 -and $same.Result[0].Problems -eq 0 -and @($same.Result[0].ClaudeFixedStdioResults | ForEach-Object { $_.Status }) -join ',' -ceq 'unchanged' -and
        $script:CliCalls.Count -eq 0 -and $different.Result[0].Problems -eq 0 -and (($different.Warnings -join "`n") -match 'flaui-mcp 的 command') -and -not (($different.Warnings -join "`n") -match 'SECRET-OLD-PATH')
    }
    Test-Case 'FC02 FlaUI 執行檔不存在：Claude 步驟略過並印一行說明（零次 mcp add），問題數維持 1（只由 Codex 步驟計）；-FlaUIPath 不是完整的絕對路徑時同樣略過' {
        Reset-Stubs
        $codex = New-CodexFixture -Text $baseConfig
        $missing = Invoke-FlaUIClaudeRegistration -Codex $codex -UserMcp (New-UserMcpFile -Exclude @('flaui-mcp')) -ExecutablePath (Join-Path $codex.Directory 'none.exe')
        $relative = Invoke-FlaUIClaudeRegistration -Codex $codex -UserMcp (New-UserMcpFile -Exclude @('flaui-mcp')) -ExecutablePath '.\FlaUI.Mcp.exe'
        $script:CliCalls.Count -eq 0 -and $missing.Result[0].Problems -eq 1 -and $relative.Result[0].Problems -eq 1 -and (($missing.Info -join "`n") -match '略過 Claude Code 使用者層的 flaui-mcp 登記') -and (($relative.Info -join "`n") -match '略過 Claude Code 使用者層的 flaui-mcp 登記')
    }
    Test-Case 'FC03 Codex 桌面版設定檔不存在不阻擋 Claude 步驟：仍登記 flaui-mcp（一次 mcp add），問題數為 1（只由桌面版設定檔缺失計）' {
        Reset-Stubs
        $codex = New-CodexFixture
        $captured = Invoke-FlaUIClaudeRegistration -Codex $codex -UserMcp (New-UserMcpFile -Exclude @('flaui-mcp'))
        $script:CliCalls.Count -eq 1 -and $captured.Result[0].FlaUIResult.Status -eq 'config-missing' -and $captured.Result[0].Problems -eq 1 -and @($captured.Result[0].ClaudeFixedStdioResults | ForEach-Object { $_.Status }) -join ',' -ceq 'added' -and -not (Test-Path -LiteralPath $codex.Config)
    }
    Test-Case 'FC04 整個 Claude 端前置失敗只計一個問題：只選 FlaUI 且登記檔無法讀取、或找不到 claude 時問題數為 1，桌面版仍照常寫入，零次 mcp add' {
        Reset-Stubs
        $bad = Join-Path (New-TestDirectory) 'claude.json'
        [IO.File]::WriteAllText($bad, '{ not json', $utf8)
        $codex = New-CodexFixture -Text $baseConfig
        $unreadable = Invoke-FlaUIClaudeRegistration -Codex $codex -UserMcp $bad
        $codex2 = New-CodexFixture -Text $baseConfig
        $savedPath = $env:PATH
        try {
            $env:PATH = (New-TestDirectory)
            $noClaude = Invoke-FlaUIClaudeRegistration -Codex $codex2 -UserMcp (New-UserMcpFile -Exclude @('flaui-mcp'))
        }
        finally { $env:PATH = $savedPath }
        $script:CliCalls.Count -eq 0 -and $unreadable.Result[0].Problems -eq 1 -and $unreadable.Result[0].FlaUIResult.Status -in @('added', 'updated') -and $noClaude.Result[0].Problems -eq 1 -and $noClaude.Result[0].FlaUIResult.Status -in @('added', 'updated') -and (($noClaude.Warnings -join "`n") -match '找不到 claude CLI')
    }
    Test-Case 'FC05 flaui-mcp 的 -FlaUIPath 含禁用字元（&）：不呼叫 claude，invalid-path 算一個問題並指出原因；-WhatIf 零次呼叫' {
        Reset-Stubs
        $directory = Join-Path (New-TestDirectory) 'a&b'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $executable = Join-Path $directory 'FlaUI.Mcp.exe'
        [IO.File]::WriteAllBytes($executable, [byte[]](77, 90))
        $codex = New-CodexFixture -Text $baseConfig
        $invalid = Invoke-FlaUIClaudeRegistration -Codex $codex -UserMcp (New-UserMcpFile -Exclude @('flaui-mcp')) -ExecutablePath $executable
        $invalidCalls = $script:CliCalls.Count
        $codex2 = New-CodexFixture -Text $baseConfig
        $whatIf = Invoke-FlaUIClaudeRegistration -Codex $codex2 -UserMcp (New-UserMcpFile -Exclude @('flaui-mcp')) -WhatIfRun
        $invalidCalls -eq 0 -and $invalid.Result[0].Problems -eq 1 -and (($invalid.Warnings -join "`n") -match '絕對路徑或含有不允許的字元') -and $script:CliCalls.Count -eq 0 -and $whatIf.Result[0].Problems -eq 0 -and @($whatIf.Result[0].ClaudeFixedStdioResults | ForEach-Object { $_.Status }) -join ',' -ceq 'whatif'
    }
    Test-Case 'FC07 順序：Claude 端的 flaui-mcp 登記在 Codex 端的 FlaUI 步驟（含 FlaUI 摘要）之後，且在 mcp-lab、infra-lab 之後' {
        Reset-Stubs
        $codex = New-CodexFixture -Text $baseConfig
        $userMcp = New-UserMcpFile -Exclude (@($template | ForEach-Object { $_.Name }) + @('flaui-mcp'))
        $captured = Invoke-Captured { Invoke-McpRegistration -Target @('mcp-lab', 'flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' }
        $info = $captured.Info -join "`n"
        $labIndex = $info.IndexOf('正在登記 Claude Code 的 MCP 伺服器（mcp-lab）')
        $codexIndex = $info.IndexOf('正在寫入 Codex 桌面版的 flaui-mcp 指令')
        $summaryIndex = $info.IndexOf('FlaUI 摘要')
        $claudeFlauiIndex = $info.IndexOf('正在登記 Claude Code 的 MCP 伺服器（flaui-mcp）')
        $labIndex -ge 0 -and $codexIndex -gt $labIndex -and $summaryIndex -gt $codexIndex -and $claudeFlauiIndex -gt $summaryIndex -and $script:CliCalls.Count -eq 12 -and $captured.Result[0].Problems -eq 0
    }
    Test-Case 'FC06 -Check 的 flaui-mcp（Claude Code）：登記相符為 ok；未登記為缺少；command 不同為內容不符；登記檔無法讀取為無法判定；結束碼不符時為 1' {
        Reset-Stubs
        $codex = New-ConsistentCodex
        $check = {
            param($UserMcp)
            Invoke-Captured { Invoke-McpRegistrationCheck -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $UserMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -InfraLabDistro '' -InfraLabWslRepo '' }
        }
        $ok = & $check (New-UserMcpFile -FlaUICommand $codex.Executable)
        $missing = & $check (New-UserMcpFile -Exclude @('flaui-mcp'))
        $mismatch = & $check (New-UserMcpFile -FlaUICommand 'X:\other\FlaUI.Mcp.exe')
        $bad = Join-Path (New-TestDirectory) 'claude.json'
        [IO.File]::WriteAllText($bad, '{ not json', $utf8)
        $unreadable = & $check $bad
        $ok.Result[0] -eq 0 -and (($ok.Info -join "`n") -match '\[符合\] flaui-mcp（Claude Code）') -and (($ok.Info -join "`n") -match 'FlaUI\.Mcp（Codex 桌面版、派工帳號與 Claude Code）') -and
        $missing.Result[0] -eq 1 -and (($missing.Info -join "`n") -match '\[缺少\] flaui-mcp（Claude Code）.*-FlaUI') -and
        $mismatch.Result[0] -eq 1 -and (($mismatch.Info -join "`n") -match '\[內容不符\] flaui-mcp（Claude Code）.*command') -and -not (($mismatch.Info -join "`n") -match 'X:\\other') -and
        $unreadable.Result[0] -eq 1 -and (($unreadable.Info -join "`n") -match '\[無法判定\] flaui-mcp（Claude Code）')
    }

    # ---- 腳本本身（子行程）：選取、用法與結束碼 ----
    Test-Case 'SC01 沒有指定任何項目：不做任何寫入、印出用法、結束碼 1，不呼叫 claude' {
        $environment = New-ScriptEnvironment
        $before = Get-FileSnapshot -Directory $environment.Root
        $run = Invoke-RegisterScript -Environment $environment
        $run.ExitCode -eq 1 -and $run.StdOut.Contains('Register-McpServer.ps1') -and $run.StdOut.Contains('-McpLab') -and $run.StdOut.Contains('-Playwright') -and (Get-FileSnapshot -Directory $environment.Root) -ceq $before -and -not (Test-Path -LiteralPath $environment.CallLog)
    }
    Test-Case 'SC02 -McpLab：以假 claude 收到 11 次 mcp add（名稱與位址與範本相同），沒有其他呼叫；未選的 infra-lab 與 FlaUI 不處理' {
        $environment = New-ScriptEnvironment
        $run = Invoke-RegisterScript -Environment $environment -Arguments @('-McpLab')
        $calls = @(Get-Content -LiteralPath $environment.CallLog)
        $http = @($template | Where-Object { $_.Type -eq 'http' })
        $allMatch = $true
        foreach ($server in $http) { if (@($calls | Where-Object { $_ -match ('^mcp add --transport http --scope user ' + [regex]::Escape($server.Name) + ' ' + [regex]::Escape($server.Url) + '\s*$') }).Count -ne 1) { $allMatch = $false } }
        $run.ExitCode -eq 0 -and $calls.Count -eq 11 -and $allMatch -and -not (Test-Path -LiteralPath (Join-Path $environment.UserProfile '.codex'))
    }
    Test-Case 'SC03 -InfraLab 與值：以假 claude 收到 1 次 stdio 登記；缺值時結束碼 1 且不呼叫；-InfraLabDistro 沒有 -InfraLab 時被拒絕' {
        $environment = New-ScriptEnvironment
        $run = Invoke-RegisterScript -Environment $environment -Arguments @('-InfraLab', '-InfraLabDistro', $infraLabDistro, '-InfraLabWslRepo', $infraLabRepo)
        $calls = @(Get-Content -LiteralPath $environment.CallLog)
        $noValues = New-ScriptEnvironment
        $missingValues = Invoke-RegisterScript -Environment $noValues -Arguments @('-InfraLab')
        $orphan = Invoke-RegisterScript -Environment (New-ScriptEnvironment) -Arguments @('-McpLab', '-InfraLabDistro', 'x')
        $run.ExitCode -eq 0 -and $calls.Count -eq 1 -and $calls[0] -match '^mcp add --transport stdio --scope user infra-lab -- wsl\.exe -d Ubuntu-test -e bash /work/infra-lab/scripts/mcp\.sh\s*$' -and
        $missingValues.ExitCode -eq 1 -and -not (Test-Path -LiteralPath $noValues.CallLog) -and $orphan.ExitCode -eq 1
    }
    Test-Case 'SC04 -FlaUI 以 -CodexConfigPath 與 -FlaUIPath 寫入暫存設定檔：結束碼 0 且對假 claude 收到一次 mcp add flaui-mcp；執行檔不存在時結束碼 1、不寫入、不呼叫 claude；-FlaUIPath 沒有 -FlaUI 時被拒絕、不呼叫 claude' {
        $environment = New-ScriptEnvironment
        $codex = New-CodexFixture -Text $baseConfig
        $hash = Get-TestBytesHex $codex.Config
        $missingExe = Invoke-RegisterScript -Environment $environment -Arguments @('-FlaUI', '-CodexConfigPath', $codex.Config, '-FlaUIPath', (Join-Path $codex.Directory 'none.exe'))
        $unchangedAfterMissing = (Get-TestBytesHex $codex.Config) -ceq $hash
        $noCallAfterMissing = -not (Test-Path -LiteralPath $environment.CallLog)
        $ok = Invoke-RegisterScript -Environment $environment -Arguments @('-FlaUI', '-CodexConfigPath', $codex.Config, '-FlaUIPath', $codex.Executable, '-BackupRoot', $codex.Backups)
        $callsAfterOk = @(Get-Content -LiteralPath $environment.CallLog).Count
        $orphan = Invoke-RegisterScript -Environment $environment -Arguments @('-McpLab', '-FlaUIPath', $codex.Executable)
        $calls = @(Get-Content -LiteralPath $environment.CallLog)
        $missingExe.ExitCode -eq 1 -and $unchangedAfterMissing -and $noCallAfterMissing -and $callsAfterOk -eq 1 -and $ok.ExitCode -eq 0 -and (Get-FileText -Path $codex.Config).Contains("command = '" + $codex.Executable + "'") -and $orphan.ExitCode -eq 1 -and $calls.Count -eq 1 -and $calls[0] -match ('^mcp add --transport stdio --scope user flaui-mcp -- ' + [regex]::Escape($codex.Executable) + '\s*$')
    }
    Test-Case 'SC05 -FlaUI 的預設路徑為 %LOCALAPPDATA%\Programs\FlaUI-MCP\FlaUI.Mcp.exe：該檔存在時寫入暫存的使用者目錄 .codex\config.toml' {
        $environment = New-ScriptEnvironment
        $defaultDirectory = Join-Path $environment.LocalAppData 'Programs\FlaUI-MCP'
        New-Item -ItemType Directory -Path $defaultDirectory -Force | Out-Null
        $defaultExe = Join-Path $defaultDirectory 'FlaUI.Mcp.exe'
        [IO.File]::WriteAllBytes($defaultExe, [byte[]](77, 90))
        $codexDirectory = Join-Path $environment.UserProfile '.codex'
        New-Item -ItemType Directory -Path $codexDirectory -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $codexDirectory 'config.toml'), $utf8.GetBytes($baseConfig))
        $run = Invoke-RegisterScript -Environment $environment -Arguments @('-FlaUI', '-BackupRoot', (Join-Path $environment.Root 'backups'))
        $calls = @(Get-Content -LiteralPath $environment.CallLog)
        $run.ExitCode -eq 0 -and (Get-FileText -Path (Join-Path $codexDirectory 'config.toml')).Contains("command = '" + $defaultExe + "'") -and $calls.Count -eq 1 -and $calls[0].Contains('flaui-mcp -- ' + $defaultExe)
    }
    Test-Case 'SC06 -Check：沒有指定項目時檢查四項全部（含 playwright）；缺少登記時結束碼 1 且不寫入任何檔案、不呼叫 claude；指定項目時只檢查該項' {
        $environment = New-ScriptEnvironment
        $codexDirectory = Join-Path $environment.UserProfile '.codex'
        New-Item -ItemType Directory -Path $codexDirectory -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $codexDirectory 'config.toml'), $utf8.GetBytes($baseConfig))
        $before = Get-FileSnapshot -Directory $environment.Root
        $all = Invoke-RegisterScript -Environment $environment -Arguments @('-Check')
        $flauiOnly = Invoke-RegisterScript -Environment $environment -Arguments @('-Check', '-FlaUI')
        $after = Get-FileSnapshot -Directory $environment.Root
        $all.ExitCode -eq 1 -and $all.StdOut -match 'flaui-mcp' -and $all.StdOut -match 'mcp-sql-server' -and $all.StdOut -match 'playwright' -and $flauiOnly.StdOut -notmatch 'playwright' -and $flauiOnly.ExitCode -eq 1 -and $flauiOnly.StdOut -notmatch 'mcp-sql-server' -and $before -ceq $after -and -not (Test-Path -LiteralPath $environment.CallLog)
    }
    Test-Case 'SC07 -WhatIf：以假 claude 零次呼叫，桌面版設定檔不變，結束碼 0' {
        $environment = New-ScriptEnvironment
        $codex = New-CodexFixture -Text $baseConfig
        $hash = Get-TestBytesHex $codex.Config
        $run = Invoke-RegisterScript -Environment $environment -Arguments @('-McpLab', '-InfraLab', '-InfraLabDistro', $infraLabDistro, '-InfraLabWslRepo', $infraLabRepo, '-FlaUI', '-CodexConfigPath', $codex.Config, '-FlaUIPath', $codex.Executable, '-BackupRoot', $codex.Backups, '-WhatIf')
        $run.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $environment.CallLog) -and (Get-TestBytesHex $codex.Config) -ceq $hash
    }

    Test-Case 'SC08 -FlaUIPath 是相對路徑時先轉成絕對路徑（以目前的工作目錄為基準）：設定檔寫入的是完整路徑，-Check 以同一個相對路徑檢查也一致' {
        $environment = New-ScriptEnvironment
        $codex = New-CodexFixture -Text $baseConfig
        $executableDirectory = Split-Path -Parent $codex.Executable
        $run = Invoke-RegisterScript -Environment $environment -Arguments @('-FlaUI', '-CodexConfigPath', $codex.Config, '-FlaUIPath', '.\FlaUI.Mcp.exe', '-BackupRoot', $codex.Backups) -WorkingDirectory $executableDirectory
        $text = Get-FileText -Path $codex.Config
        $calls = @(Get-Content -LiteralPath $environment.CallLog)
        # 假 claude 不寫登記檔：以檔案模擬 Claude 端已登記為絕對路徑，-Check 以同一個相對路徑檢查時 Codex 與 Claude 兩端都一致。
        [IO.File]::WriteAllText((Join-Path $environment.UserProfile '.claude.json'), ([ordered]@{ mcpServers = [ordered]@{ 'flaui-mcp' = [ordered]@{ type = 'stdio'; command = $codex.Executable; args = @(); env = [ordered]@{} } } } | ConvertTo-Json -Depth 8), $utf8)
        $check = Invoke-RegisterScript -Environment $environment -Arguments @('-Check', '-FlaUI', '-CodexConfigPath', $codex.Config, '-FlaUIPath', '.\FlaUI.Mcp.exe') -WorkingDirectory $executableDirectory
        $run.ExitCode -eq 0 -and $text.Contains("command = '" + $codex.Executable + "'") -and -not $text.Contains("command = '.\") -and $calls.Count -eq 1 -and $calls[0].Contains('flaui-mcp -- ' + $codex.Executable) -and $check.ExitCode -eq 0
    }
    Test-Case 'SC09 -FlaUI 同時更新 -MachineConfigPath 登記的帳號：全部完成時結束碼 0；其中一個帳號沒有 config.toml 時其餘照常更新、結束碼 1；沒有登記帳號時結束碼不受影響' {
        $environment = New-ScriptEnvironment
        $codex = New-CodexFixture -Text $baseConfig
        $accounts = New-AccountFixture -Config @{ 'acct-a' = $accountPresentConfig; 'acct-b' = $baseConfig }
        $ok = Invoke-RegisterScript -Environment $environment -Arguments @('-FlaUI', '-CodexConfigPath', $codex.Config, '-FlaUIPath', $codex.Executable, '-BackupRoot', $accounts.Backups, '-MachineConfigPath', $accounts.Machine)
        $accountsUpdated = (Get-FileText -Path (Get-AccountConfigPath -Fixture $accounts -Name 'acct-a')).Contains("command = '" + $codex.Executable + "'") -and (Get-FileText -Path (Get-AccountConfigPath -Fixture $accounts -Name 'acct-b')).Contains("enabled = false")

        $codex2 = New-CodexFixture -Text $baseConfig
        $partial = New-AccountFixture -Config @{ 'acct-b' = $accountPresentConfig } -NoConfig @('acct-a')
        $failed = Invoke-RegisterScript -Environment $environment -Arguments @('-FlaUI', '-CodexConfigPath', $codex2.Config, '-FlaUIPath', $codex2.Executable, '-BackupRoot', $partial.Backups, '-MachineConfigPath', $partial.Machine)
        $partialUpdated = (Get-FileText -Path (Get-AccountConfigPath -Fixture $partial -Name 'acct-b')).Contains("command = '" + $codex2.Executable + "'")

        $codex3 = New-CodexFixture -Text $baseConfig
        $none = Invoke-RegisterScript -Environment $environment -Arguments @('-FlaUI', '-CodexConfigPath', $codex3.Config, '-FlaUIPath', $codex3.Executable, '-BackupRoot', $codex3.Backups)
        $ok.ExitCode -eq 0 -and $accountsUpdated -and $failed.ExitCode -eq 1 -and $partialUpdated -and -not (Test-Path -LiteralPath (Get-AccountConfigPath -Fixture $partial -Name 'acct-a')) -and $none.ExitCode -eq 0
    }
    Test-Case 'SC10 -WhatIf 與 -Check 不寫入帳號設定檔；-Check 帳號不一致時結束碼 1' {
        $environment = New-ScriptEnvironment
        $codex = New-CodexFixture -Text $baseConfig
        $accounts = New-AccountFixture -Config @{ 'acct-a' = $accountPresentConfig; 'acct-b' = $baseConfig }
        $snapshot = (Get-FileSnapshot -Directory $accounts.Root) + (Get-FileSnapshot -Directory $codex.Directory)
        $whatIf = Invoke-RegisterScript -Environment $environment -Arguments @('-FlaUI', '-CodexConfigPath', $codex.Config, '-FlaUIPath', $codex.Executable, '-BackupRoot', $accounts.Backups, '-MachineConfigPath', $accounts.Machine, '-WhatIf')
        $check = Invoke-RegisterScript -Environment $environment -Arguments @('-Check', '-FlaUI', '-CodexConfigPath', $codex.Config, '-FlaUIPath', $codex.Executable, '-MachineConfigPath', $accounts.Machine)
        $whatIf.ExitCode -eq 0 -and $check.ExitCode -eq 1 -and $check.StdOut -match 'acct-a' -and ((Get-FileSnapshot -Directory $accounts.Root) + (Get-FileSnapshot -Directory $codex.Directory)) -ceq $snapshot
    }
    Test-Case 'SC11 測試隔離：執行腳本的輔助函式預設把 -MachineConfigPath 指向暫存目錄內不存在的檔案，腳本的預設值（repo 的 .local\machine.json 與其中登記的真實帳號）不會被測試讀到或寫入' {
        $environment = New-ScriptEnvironment
        $run = Invoke-RegisterScript -Environment $environment -Arguments @('-Check', '-FlaUI')
        $index = [array]::IndexOf($run.Arguments, '-MachineConfigPath')
        $injected = if ($index -ge 0) { [string]$run.Arguments[$index + 1] } else { '' }
        $explicit = Invoke-RegisterScript -Environment $environment -Arguments @('-Check', '-FlaUI', '-MachineConfigPath', 'X:\explicit.json')
        $index -ge 0 -and $injected.StartsWith($environment.Root, [StringComparison]::OrdinalIgnoreCase) -and -not (Test-Path -LiteralPath $injected) -and @($explicit.Arguments | Where-Object { $_ -ceq '-MachineConfigPath' }).Count -eq 1
    }

    Test-Case 'SC12 -Playwright 與 -PlaywrightOutputDir：以假 claude 收到一次 mcp add（輸出目錄為指定值，相對路徑先轉成絕對路徑）；沒有 -Playwright 時 -PlaywrightOutputDir 被拒絕且不呼叫；-WhatIf 零次呼叫' {
        $environment = New-ScriptEnvironment
        $outputDirectory = Join-Path $environment.Root 'pw-out'
        $run = Invoke-RegisterScript -Environment $environment -Arguments @('-Playwright', '-PlaywrightOutputDir', $outputDirectory)
        $calls = @(Get-Content -LiteralPath $environment.CallLog)
        $expectedPattern = '^mcp add -e PLAYWRIGHT_MCP_OUTPUT_DIR=' + [regex]::Escape($outputDirectory) + ' --transport stdio --scope user playwright -- cmd /c npx -y @playwright/mcp@latest\s*$'

        $relativeEnvironment = New-ScriptEnvironment
        $relativeRun = Invoke-RegisterScript -Environment $relativeEnvironment -Arguments @('-Playwright', '-PlaywrightOutputDir', '.\rel-out') -WorkingDirectory $relativeEnvironment.Root
        $relativeCalls = @(Get-Content -LiteralPath $relativeEnvironment.CallLog)

        $orphanEnvironment = New-ScriptEnvironment
        $orphan = Invoke-RegisterScript -Environment $orphanEnvironment -Arguments @('-McpLab', '-PlaywrightOutputDir', $outputDirectory)

        $whatIfEnvironment = New-ScriptEnvironment
        $whatIf = Invoke-RegisterScript -Environment $whatIfEnvironment -Arguments @('-Playwright', '-PlaywrightOutputDir', $outputDirectory, '-WhatIf')
        $run.ExitCode -eq 0 -and $calls.Count -eq 1 -and $calls[0] -match $expectedPattern -and
        $relativeRun.ExitCode -eq 0 -and $relativeCalls.Count -eq 1 -and $relativeCalls[0].Contains('PLAYWRIGHT_MCP_OUTPUT_DIR=' + (Join-Path $relativeEnvironment.Root 'rel-out')) -and
        $orphan.ExitCode -eq 1 -and -not (Test-Path -LiteralPath $orphanEnvironment.CallLog) -and
        $whatIf.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $whatIfEnvironment.CallLog)
    }
    Test-Case 'SC13 -Check -Playwright：未登記時結束碼 1；使用者層登記檔有相符的 playwright 時結束碼 0；不呼叫 claude、不寫入任何檔案' {
        $environment = New-ScriptEnvironment
        $outputDirectory = Join-Path $environment.Root 'pw-out'
        $before = Get-FileSnapshot -Directory $environment.Root
        $missing = Invoke-RegisterScript -Environment $environment -Arguments @('-Check', '-Playwright', '-PlaywrightOutputDir', $outputDirectory)
        $missingUnchanged = $before -ceq (Get-FileSnapshot -Directory $environment.Root)
        $registered = [ordered]@{ mcpServers = [ordered]@{ playwright = [ordered]@{ type = 'stdio'; command = 'cmd'; args = @('/c', 'npx', '-y', '@playwright/mcp@latest'); env = [ordered]@{ PLAYWRIGHT_MCP_OUTPUT_DIR = $outputDirectory } } } }
        [IO.File]::WriteAllText((Join-Path $environment.UserProfile '.claude.json'), ($registered | ConvertTo-Json -Depth 8), $utf8)
        $ok = Invoke-RegisterScript -Environment $environment -Arguments @('-Check', '-Playwright', '-PlaywrightOutputDir', $outputDirectory)
        $missing.ExitCode -eq 1 -and $missingUnchanged -and $missing.StdOut -match '\[缺少\] playwright' -and $ok.ExitCode -eq 0 -and $ok.StdOut -match '\[符合\] playwright' -and -not (Test-Path -LiteralPath $environment.CallLog)
    }

    Test-Case 'PW15 LocalAppData 指向目前工作階段沒有的磁碟機：Resolve-PlaywrightOutputDir 不丟例外，由路徑驗證判定（語法上完整的路徑照常回傳，PowerShell provider 路徑回傳錯誤）；登記與 -Check 同樣不中斷' {
        $missingDrive = $null
        foreach ($code in 90..68) {
            $letter = [string][char]$code
            if (-not (Test-Path -LiteralPath ($letter + ':\'))) { $missingDrive = $letter; break }
        }
        if ($null -eq $missingDrive) { return [pscustomobject]@{ Skip = '沒有未使用的磁碟機代號' } }
        $unmappedAppData = $missingDrive + ':\appdata'
        $thrown = $false
        $unmapped = $null
        try { $unmapped = Resolve-PlaywrightOutputDir -OutputDir '' -LocalAppData $unmappedAppData } catch { $thrown = $true }
        $providerPath = Resolve-PlaywrightOutputDir -OutputDir '' -LocalAppData 'HKLM:\Software'
        Reset-Stubs
        $registered = Invoke-PlaywrightRegistration -UserMcp (New-UserMcpFile -Exclude @('playwright')) -LocalAppData $unmappedAppData
        $checked = Invoke-PlaywrightCheck -UserMcp (New-UserMcpFile -Exclude @('playwright')) -LocalAppData $unmappedAppData
        -not $thrown -and $unmapped.Ok -and $unmapped.Path -ceq ($unmappedAppData + '\ai-agents\playwright-mcp') -and -not $providerPath.Ok -and $providerPath.Message.Length -gt 0 -and
        $null -eq $registered.Error -and $registered.Result[0].Problems -eq 0 -and $script:CliCalls.Count -eq 1 -and
        $null -eq $checked.Error -and $checked.Result[0] -eq 1 -and (($checked.Info -join "`n") -match '\[缺少\] playwright（Claude Code）')
    }
    Test-Case 'SC14 LOCALAPPDATA 未設定時只影響需要它的目標：-Playwright 加 -PlaywrightOutputDir 照常登記一次；-McpLab 不受影響；-Playwright 未指定目錄與 -FlaUI 未指定路徑各自結束碼 1、不呼叫 claude 並指向對應參數；-FlaUI 加 -FlaUIPath 不需要它' {
        $withDirectoryEnvironment = New-ScriptEnvironment
        $outputDirectory = Join-Path $withDirectoryEnvironment.Root 'pw-out'
        $withDirectory = Invoke-RegisterScript -Environment $withDirectoryEnvironment -Arguments @('-Playwright', '-PlaywrightOutputDir', $outputDirectory) -UnsetLocalAppData
        $withDirectoryCalls = @(Get-Content -LiteralPath $withDirectoryEnvironment.CallLog)

        $mcpLabEnvironment = New-ScriptEnvironment
        $mcpLab = Invoke-RegisterScript -Environment $mcpLabEnvironment -Arguments @('-McpLab') -UnsetLocalAppData
        $mcpLabCalls = @(Get-Content -LiteralPath $mcpLabEnvironment.CallLog)

        $noDirectoryEnvironment = New-ScriptEnvironment
        $noDirectory = Invoke-RegisterScript -Environment $noDirectoryEnvironment -Arguments @('-Playwright') -UnsetLocalAppData

        $noFlaUIPathEnvironment = New-ScriptEnvironment
        $noFlaUIPath = Invoke-RegisterScript -Environment $noFlaUIPathEnvironment -Arguments @('-FlaUI') -UnsetLocalAppData

        $explicitFlaUIEnvironment = New-ScriptEnvironment
        $codex = New-CodexFixture -Text $baseConfig
        $explicitFlaUI = Invoke-RegisterScript -Environment $explicitFlaUIEnvironment -Arguments @('-FlaUI', '-FlaUIPath', $codex.Executable, '-CodexConfigPath', $codex.Config, '-BackupRoot', $codex.Backups) -UnsetLocalAppData

        $withDirectory.ExitCode -eq 0 -and $withDirectoryCalls.Count -eq 1 -and $withDirectoryCalls[0].Contains('PLAYWRIGHT_MCP_OUTPUT_DIR=' + $outputDirectory) -and
        $mcpLab.ExitCode -eq 0 -and $mcpLabCalls.Count -eq 11 -and
        $noDirectory.ExitCode -eq 1 -and -not (Test-Path -LiteralPath $noDirectoryEnvironment.CallLog) -and (($noDirectory.StdOut + $noDirectory.StdErr) -match '-PlaywrightOutputDir') -and
        $noFlaUIPath.ExitCode -eq 1 -and -not (Test-Path -LiteralPath $noFlaUIPathEnvironment.CallLog) -and (($noFlaUIPath.StdOut + $noFlaUIPath.StdErr) -match '-FlaUIPath') -and
        $explicitFlaUI.ExitCode -eq 0
    }

    # ---- 靜態檢查 ----
    $scriptText = [IO.File]::ReadAllText($scriptPath)
    $libText = [IO.File]::ReadAllText($libPath)
    $scriptBytes = [IO.File]::ReadAllBytes($scriptPath)
    $libBytes = [IO.File]::ReadAllBytes($libPath)
    $tokens = $null
    $parseErrors = $null
    $libAst = [System.Management.Automation.Language.Parser]::ParseFile($libPath, [ref]$tokens, [ref]$parseErrors)
    Test-Case 'G01 腳本與 lib 檔首為 BOM 與 #Requires -Version 7.0，沒有語法錯誤' {
        $scriptFirst = ($scriptText.TrimStart([char]0xFEFF) -split "`r?`n")[0]
        $libFirst = ($libText.TrimStart([char]0xFEFF) -split "`r?`n")[0]
        $scriptErrors = $null
        $scriptTokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$scriptTokens, [ref]$scriptErrors)
        $parseErrors.Count -eq 0 -and $scriptErrors.Count -eq 0 -and $scriptBytes[0] -eq 0xEF -and $scriptBytes[1] -eq 0xBB -and $scriptBytes[2] -eq 0xBF -and $libBytes[0] -eq 0xEF -and $scriptFirst -ceq '#Requires -Version 7.0' -and $libFirst -ceq '#Requires -Version 7.0'
    }
    Test-Case 'G02 lib 只定義函式，頂層沒有可執行陳述式' {
        @($libAst.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] }).Count -eq 0
    }
    Test-Case 'G03 腳本與 lib 不含下載、安裝、拉 repo、啟動服務的命令（只寫設定）' {
        $pattern = 'Invoke-WebRequest|Invoke-RestMethod|Start-BitsTransfer|DownloadFile|winget|git clone|git pull|Start-Process|docker|task bootstrap|Install-Module|npm i|dotnet tool'
        ($scriptText -cnotmatch $pattern) -and ($libText -cnotmatch $pattern)
    }
    Test-Case 'G04 lib 沒有直接寫檔或刪檔的 API：Codex 設定檔的寫入只經 claude-user-config.ps1 的受保護寫入（Save-ConfigFileBackup、Write-ConfigFileGuarded），寫入入口只有 Set-FlaUIMcpCommand 與 Set-FlaUIMcpAccountCommand（經 Invoke-FlaUIConfigWrite）；不刪除 .codex 目錄下任何檔案' {
        $writeHits = @($tokens | Where-Object { $_.Text -match 'Set-Content|WriteAllText|WriteAllBytes|AppendAllText|Out-File|Add-Content|Move-Item|Copy-Item|New-Item|Remove-Item|\bMove\b|\.Delete\(|\[IO\.File\]::Delete' })
        Assert-True ($writeHits.Count -eq 0) ('lib 內的直接寫入或刪除 API：' + (($writeHits | ForEach-Object { $_.Text + '@' + $_.Extent.StartLineNumber }) -join ','))
        $callers = @($libAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-FlaUIConfigWrite' }, $true) | ForEach-Object {
            $parent = $_.Parent
            while ($null -ne $parent -and $parent -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $parent = $parent.Parent }
            $parent.Name
        } | Sort-Object -Unique)
        ($callers -join ',') -ceq 'Set-FlaUIMcpAccountCommand,Set-FlaUIMcpCommand'
    }
    Test-Case 'G05 腳本不引用真實的使用者目錄：路徑只由 $env:USERPROFILE、$env:LOCALAPPDATA 與參數決定' {
        $scriptText -cnotmatch '[A-Za-z]:\\Users' -and $libText -cnotmatch '[A-Za-z]:\\Users' -and $scriptText -cmatch 'LOCALAPPDATA' -and $scriptText -cmatch 'USERPROFILE'
    }
    Test-Case 'G06 Invoke-ClaudeFixedStdioMcpStep 不直接啟動任何外部程式：沒有 & 或 . 呼叫運算子、沒有 claude 與 Start-Process 命令，登記只經 Invoke-ClaudeMcpRegister（其呼叫 Invoke-ClaudeCli）' {
        $function = @($libAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-ClaudeFixedStdioMcpStep' }, $true))[0]
        $commands = @($function.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
        $names = @($commands | ForEach-Object { $_.GetCommandName() })
        $operators = @($commands | Where-Object { $_.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Unknown })
        $null -ne $function -and $operators.Count -eq 0 -and $names -cnotcontains 'claude' -and $names -cnotcontains 'Start-Process' -and $names -cnotcontains 'Invoke-ClaudeCli' -and $names -ccontains 'Invoke-ClaudeMcpRegister'
    }
}
finally {
    $env:PATH = $originalPath
    if (Test-Path -LiteralPath $tempBase) { Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output "PASSED: $passed"
Write-Output "FAILED: $failed"
Write-Output "SKIPPED: $skipped"
if ($failed -gt 0) { exit 1 }
exit 0
