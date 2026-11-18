#Requires -Version 7.0
[CmdletBinding()]
param()

# scripts/Register-McpServer.ps1 與 scripts/lib/mcp-registration.ps1 的測試：
# Claude 端的登記（只選取的項目、已存在不覆寫、重複執行不重複）、FlaUI.Mcp 寫入 Codex 桌面版設定檔（新增、只改 command、其餘位元組不變、保留編碼與換行、
# 執行檔或設定檔不存在不寫入、-WhatIf 不寫入）、唯讀檢查，以及腳本本身的選取、用法與結束碼。
# 所有檔案操作都在暫存目錄內進行；腳本以子行程執行時，USERPROFILE、LOCALAPPDATA 與 PATH 都指向暫存目錄與假的 claude，不碰真實的使用者設定與 Claude CLI。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$scriptPath = Join-Path $repoRoot 'scripts\Register-McpServer.ps1'
$libPath = Join-Path $repoRoot 'scripts\lib\mcp-registration.ps1'
$mcpTemplatePath = Join-Path $repoRoot 'templates\claude-mcp-servers.json'
$pwshCommand = Get-Command -Name 'pwsh' -ErrorAction Stop
$pwshPath = if ([string]::IsNullOrWhiteSpace($pwshCommand.Source)) { $pwshCommand.Path } else { $pwshCommand.Source }
$tempBase = Join-Path (Join-Path $env:LOCALAPPDATA 'Temp') ('mcp-registration-' + [guid]::NewGuid().ToString('N'))
$failed = 0
$passed = 0

. (Join-Path $repoRoot 'scripts\lib\claude-user-config.ps1')
. (Join-Path $repoRoot 'scripts\codex-run\45-profile-sync.ps1')
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
    param([string[]]$Exclude = @())
    $path = Join-Path (New-TestDirectory) 'claude.json'
    $existing = New-ExistingRegistrations -Template $script:template
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
        $bytes = if ($PSBoundParameters.ContainsKey('RawBytes')) { $RawBytes } elseif ($Bom) { [byte[]](0xEF, 0xBB, 0xBF) + $utf8.GetBytes($Text) } else { $utf8.GetBytes($Text) }
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

$crlf = "`r`n"
$baseConfigLines = @('model = "gpt"', '', '[mcp_servers.playwright]', "command = 'npx'", '', '[projects.''x:\work'']', 'trust_level = "trusted"')
$baseConfig = ($baseConfigLines -join $crlf) + $crlf
$presentConfig = (@('model = "gpt"', '', '[mcp_servers.flaui-mcp]', "command = 'X:\old\FlaUI.Mcp.exe'", 'startup_timeout_sec = 60.0', '', '[projects.''x:\work'']', 'trust_level = "trusted"') -join $crlf) + $crlf

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
    param([Parameter(Mandatory)][object]$Environment, [string[]]$Arguments = @())
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
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
    $startInfo.EnvironmentVariables['CLAUDE_CALL_LOG'] = $Environment.CallLog
    $startInfo.EnvironmentVariables['PATH'] = (@($Environment.Bin, (Split-Path -Parent $pwshPath), (Join-Path $env:WINDIR 'System32')) -join ';')
    foreach ($name in @('CODEX_HOME', 'CLAUDE_CONFIG_DIR')) { [void]$startInfo.EnvironmentVariables.Remove($name) }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { try { $process.Kill($true) } catch { $null = $_ }; throw '子程序逾時' }
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdoutTask.GetAwaiter().GetResult(); StdErr = $stderrTask.GetAwaiter().GetResult() }
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
        $manifest = Join-Path (Split-Path -Parent $result.BackupPath) 'manifest.txt'
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
    Test-Case 'RG03 只選 FlaUI：不呼叫 claude，寫入桌面版設定檔；未選的 Claude 項目不被處理' {
        Reset-Stubs
        $userMcp = New-UserMcpFile -Exclude ($template | ForEach-Object { $_.Name })
        $codex = New-CodexFixture -Text $baseConfig
        $captured = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' }
        $null -eq $captured.Error -and $script:CliCalls.Count -eq 0 -and $captured.Result[0].FlaUIResult.Status -eq 'added' -and (Get-FileText -Path $codex.Config).Contains("command = '" + $codex.Executable + "'") -and $captured.Result[0].Problems -eq 0
    }
    Test-Case 'RG04 三項全選：重複執行不產生重複登記（第二次零次 mcp add、FlaUI unchanged）' {
        Reset-Stubs
        $emptyMcp = New-UserMcpFile -Exclude ($template | ForEach-Object { $_.Name })
        $codex = New-CodexFixture -Text $baseConfig
        $first = Invoke-Captured { Invoke-McpRegistration -Target @('mcp-lab', 'infra-lab', 'flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $emptyMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo }
        $firstCalls = $script:CliCalls.Count
        $script:CliCalls.Clear()
        $fullMcp = New-UserMcpFile
        $second = Invoke-Captured { Invoke-McpRegistration -Target @('mcp-lab', 'infra-lab', 'flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $fullMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo }
        $firstCalls -eq 12 -and $script:CliCalls.Count -eq 0 -and $second.Result[0].FlaUIResult.Status -eq 'unchanged' -and $first.Result[0].Problems -eq 0 -and $second.Result[0].Problems -eq 0
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
    Test-Case 'RG06 問題計入結束碼：infra-lab 缺值、FlaUI 執行檔不存在、桌面版設定檔不存在、mcp add 失敗各算一個問題' {
        Reset-Stubs
        $userMcp = New-UserMcpFile -Exclude ($template | ForEach-Object { $_.Name })
        $codex = New-CodexFixture
        $noValues = Invoke-Captured { Invoke-McpRegistration -Target @('infra-lab') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' }
        $noExe = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath (Join-Path $codex.Directory 'none.exe') -BackupRoot $codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' }
        $noConfig = Invoke-Captured { Invoke-McpRegistration -Target @('flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro '' -InfraLabWslRepo '' }
        $script:CliHandler = { param($Arguments) [pscustomobject]@{ ExitCode = 1; Output = 'boom' } }
        $addFails = Invoke-Captured { Invoke-McpRegistration -Target @('infra-lab') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo }
        $noValues.Result[0].Problems -eq 1 -and $noExe.Result[0].Problems -eq 1 -and $noConfig.Result[0].Problems -eq 1 -and $addFails.Result[0].Problems -eq 1 -and -not (Test-Path -LiteralPath $codex.Config)
    }
    Test-Case 'RG07 -WhatIf：零次 mcp add，FlaUI 不寫入、不備份' {
        Reset-Stubs
        $userMcp = New-UserMcpFile -Exclude ($template | ForEach-Object { $_.Name })
        $codex = New-CodexFixture -Text $baseConfig
        $hash = Get-TestBytesHex $codex.Config
        $captured = Invoke-Captured { Invoke-McpRegistration -Target @('mcp-lab', 'infra-lab', 'flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -BackupRoot $codex.Backups -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo -WhatIf }
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
    Test-Case 'CK01 三項全部登記且 WSL 可用：結束碼 0；檢查不寫入任何檔案（Claude 登記檔與桌面版設定檔雜湊不變）' {
        Reset-Stubs
        $userMcp = New-UserMcpFile
        $codex = New-CodexFixture -Text $presentConfig.Replace('X:\old\FlaUI.Mcp.exe', 'PLACEHOLDER')
        [IO.File]::WriteAllText($codex.Config, (Get-FileText -Path $codex.Config).Replace('PLACEHOLDER', $codex.Executable), $utf8)
        $hashes = (Get-TestBytesHex $userMcp) + (Get-TestBytesHex $codex.Config)
        $snapshot = Get-FileSnapshot -Directory (Split-Path -Parent $codex.Directory)
        $captured = Invoke-Captured { Invoke-McpRegistrationCheck -Target @('mcp-lab', 'infra-lab', 'flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -InfraLabDistro '' -InfraLabWslRepo '' }
        $null -eq $captured.Error -and $captured.Result[0] -eq 0 -and $script:CliCalls.Count -eq 0 -and ((Get-TestBytesHex $userMcp) + (Get-TestBytesHex $codex.Config)) -ceq $hashes -and (Get-FileSnapshot -Directory (Split-Path -Parent $codex.Directory)) -ceq $snapshot
    }
    Test-Case 'CK02 缺少登記時結束碼 1 並指出缺哪一項與補救方式：mcp-lab 缺一個、infra-lab 未登記、FlaUI 項目不存在' {
        Reset-Stubs
        $userMcp = New-UserMcpFile -Exclude @('mcp-reader', 'infra-lab')
        $codex = New-CodexFixture -Text $baseConfig
        $captured = Invoke-Captured { Invoke-McpRegistrationCheck -Target @('mcp-lab', 'infra-lab', 'flaui') -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -CodexConfigPath $codex.Config -FlaUIPath $codex.Executable -InfraLabDistro '' -InfraLabWslRepo '' }
        $text = $captured.Info -join "`n"
        $captured.Result[0] -eq 1 -and $text -match '\[缺少\] mcp-reader.*Register-McpServer\.ps1 -McpLab' -and $text -match '\[缺少\] infra-lab.*-InfraLabDistro' -and $text -match '\[缺少\] flaui-mcp.*Register-McpServer\.ps1 -FlaUI'
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

    # ---- 腳本本身（子行程）：選取、用法與結束碼 ----
    Test-Case 'SC01 沒有指定任何項目：不做任何寫入、印出用法、結束碼 1，不呼叫 claude' {
        $environment = New-ScriptEnvironment
        $before = Get-FileSnapshot -Directory $environment.Root
        $run = Invoke-RegisterScript -Environment $environment
        $run.ExitCode -eq 1 -and $run.StdOut.Contains('Register-McpServer.ps1') -and $run.StdOut.Contains('-McpLab') -and (Get-FileSnapshot -Directory $environment.Root) -ceq $before -and -not (Test-Path -LiteralPath $environment.CallLog)
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
    Test-Case 'SC04 -FlaUI 以 -CodexConfigPath 與 -FlaUIPath 寫入暫存設定檔：結束碼 0；執行檔不存在時結束碼 1 且不寫入；-FlaUIPath 沒有 -FlaUI 時被拒絕；不呼叫 claude' {
        $environment = New-ScriptEnvironment
        $codex = New-CodexFixture -Text $baseConfig
        $hash = Get-TestBytesHex $codex.Config
        $missingExe = Invoke-RegisterScript -Environment $environment -Arguments @('-FlaUI', '-CodexConfigPath', $codex.Config, '-FlaUIPath', (Join-Path $codex.Directory 'none.exe'))
        $unchangedAfterMissing = (Get-TestBytesHex $codex.Config) -ceq $hash
        $ok = Invoke-RegisterScript -Environment $environment -Arguments @('-FlaUI', '-CodexConfigPath', $codex.Config, '-FlaUIPath', $codex.Executable, '-BackupRoot', $codex.Backups)
        $orphan = Invoke-RegisterScript -Environment $environment -Arguments @('-McpLab', '-FlaUIPath', $codex.Executable)
        $missingExe.ExitCode -eq 1 -and $unchangedAfterMissing -and $ok.ExitCode -eq 0 -and (Get-FileText -Path $codex.Config).Contains("command = '" + $codex.Executable + "'") -and $orphan.ExitCode -eq 1 -and -not (Test-Path -LiteralPath $environment.CallLog)
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
        $run.ExitCode -eq 0 -and (Get-FileText -Path (Join-Path $codexDirectory 'config.toml')).Contains("command = '" + $defaultExe + "'")
    }
    Test-Case 'SC06 -Check：沒有指定項目時檢查三項全部；缺少登記時結束碼 1 且不寫入任何檔案、不呼叫 claude；指定項目時只檢查該項' {
        $environment = New-ScriptEnvironment
        $codexDirectory = Join-Path $environment.UserProfile '.codex'
        New-Item -ItemType Directory -Path $codexDirectory -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $codexDirectory 'config.toml'), $utf8.GetBytes($baseConfig))
        $before = Get-FileSnapshot -Directory $environment.Root
        $all = Invoke-RegisterScript -Environment $environment -Arguments @('-Check')
        $flauiOnly = Invoke-RegisterScript -Environment $environment -Arguments @('-Check', '-FlaUI')
        $after = Get-FileSnapshot -Directory $environment.Root
        $all.ExitCode -eq 1 -and $all.StdOut -match 'flaui-mcp' -and $all.StdOut -match 'mcp-sql-server' -and $flauiOnly.ExitCode -eq 1 -and $flauiOnly.StdOut -notmatch 'mcp-sql-server' -and $before -ceq $after -and -not (Test-Path -LiteralPath $environment.CallLog)
    }
    Test-Case 'SC07 -WhatIf：以假 claude 零次呼叫，桌面版設定檔不變，結束碼 0' {
        $environment = New-ScriptEnvironment
        $codex = New-CodexFixture -Text $baseConfig
        $hash = Get-TestBytesHex $codex.Config
        $run = Invoke-RegisterScript -Environment $environment -Arguments @('-McpLab', '-InfraLab', '-InfraLabDistro', $infraLabDistro, '-InfraLabWslRepo', $infraLabRepo, '-FlaUI', '-CodexConfigPath', $codex.Config, '-FlaUIPath', $codex.Executable, '-BackupRoot', $codex.Backups, '-WhatIf')
        $run.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $environment.CallLog) -and (Get-TestBytesHex $codex.Config) -ceq $hash
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
    Test-Case 'G04 寫入檔案的 API 在 lib 只出現在 Set-FlaUIMcpCommand 內；刪除只針對自己建立的暫存檔；不刪除 .codex 目錄下任何其他檔案' {
        $function = $libAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-FlaUIMcpCommand' }, $true) | Select-Object -First 1
        $writeHits = @($tokens | Where-Object { $_.Text -match 'Set-Content|WriteAllText|WriteAllBytes|Out-File|Add-Content|Move-Item|Copy-Item|New-Item|\bMove\b' })
        $outside = @($writeHits | Where-Object { $_.Extent.StartOffset -lt $function.Extent.StartOffset -or $_.Extent.EndOffset -gt $function.Extent.EndOffset })
        Assert-True ($writeHits.Count -gt 0) '沒有找到任何寫入 API，檢查失效'
        Assert-True ($outside.Count -eq 0) ('Set-FlaUIMcpCommand 之外的寫入 API：' + (($outside | ForEach-Object { $_.Text + '@' + $_.Extent.StartLineNumber }) -join ','))
        $removeLines = @($libText -split "`r?`n" | Where-Object { $_ -match 'Remove-Item|\.Delete\(|\[IO\.File\]::Delete' })
        $removeLines.Count -eq 1 -and $removeLines[0].Contains('$temporaryPath')
    }
    Test-Case 'G05 腳本不引用真實的使用者目錄：路徑只由 $env:USERPROFILE、$env:LOCALAPPDATA 與參數決定' {
        $scriptText -cnotmatch '[A-Za-z]:\\Users' -and $libText -cnotmatch '[A-Za-z]:\\Users' -and $scriptText -cmatch 'LOCALAPPDATA' -and $scriptText -cmatch 'USERPROFILE'
    }
}
finally {
    $env:PATH = $originalPath
    if (Test-Path -LiteralPath $tempBase) { Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output "PASSED: $passed"
Write-Output "FAILED: $failed"
if ($failed -gt 0) { exit 1 }
exit 0
