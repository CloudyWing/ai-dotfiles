#Requires -Version 7.0
# 新入口測試共用輔助。由各 Test-CodexRun*.ps1 dot-source，不單獨執行。
# 測試腳本負責 Set-StrictMode 與 $ErrorActionPreference，本檔只提供函式與計數器。

$script:TestPassed = 0
$script:TestFailed = 0
$script:TestDirectories = New-Object 'System.Collections.Generic.List[string]'
$script:TestUtf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList @($false)

function Get-TestTempRoot {
    # 以長路徑格式取得暫存根目錄（TEMP 環境變數可能是 8.3 短路徑，MXC 與路徑比對都需要長路徑）。
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $candidate = Join-Path $local 'Temp'
    if ([IO.Directory]::Exists($candidate)) { return $candidate }
    return [IO.Path]::GetTempPath().TrimEnd('\', '/')
}

function New-TestDirectory {
    [CmdletBinding()]
    param([string]$Name = 'dir')

    $path = Join-Path (Get-TestTempRoot) ('cr-test-' + $Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
    $null = [IO.Directory]::CreateDirectory($path)
    $script:TestDirectories.Add($path)
    return $path
}

function Remove-TestDirectory {
    [CmdletBinding()]
    param()

    foreach ($path in @($script:TestDirectories.ToArray())) {
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            if (-not [IO.Directory]::Exists($path)) { break }
            try {
                Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    if (($_.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) { $_.Attributes = $_.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly) }
                }
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            }
            catch { Start-Sleep -Milliseconds 200 }
        }
    }
    $script:TestDirectories.Clear()
}

function Test-Case {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][scriptblock]$Check
    )

    try {
        $null = & $Check
        $script:TestPassed++
        Write-Output ('PASS ' + $Id)
    }
    catch {
        $script:TestFailed++
        Write-Output ('FAIL ' + $Id + ' ' + $_.Exception.Message)
    }
}

function Complete-TestRun {
    [CmdletBinding()]
    param()

    Remove-TestDirectory
    Write-Host ('PASSED: ' + $script:TestPassed)
    Write-Host ('FAILED: ' + $script:TestFailed)
    if ($script:TestFailed -gt 0) { return 1 }
    return 0
}

function Assert-True {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Condition,
        [string]$Message = '條件不成立'
    )

    if ($Condition -isnot [bool] -or -not $Condition) { throw $Message }
}

function Assert-Equal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Expected,
        [Parameter(Mandatory)][AllowNull()]$Actual,
        [string]$Message = ''
    )

    $expectedText = if ($null -eq $Expected) { '$null' } else { ConvertTo-Json -InputObject $Expected -Compress -Depth 5 }
    $actualText = if ($null -eq $Actual) { '$null' } else { ConvertTo-Json -InputObject $Actual -Compress -Depth 5 }
    if ($expectedText -cne $actualText) {
        throw ($Message + ' 預期 ' + $expectedText + '，實際 ' + $actualText).Trim()
    }
}

function Assert-Throws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Script,
        [string]$Code,
        [string]$MessageContains
    )

    # 腳本必須丟出例外。指定 Code 時比對 New-RunError 放在 Exception.Data['Code'] 的值，指定 MessageContains 時比對訊息。
    $caught = $null
    try { & $Script } catch { $caught = $_.Exception }
    if ($null -eq $caught) { throw '預期丟出例外，但沒有。' }
    if (-not [string]::IsNullOrEmpty($Code)) {
        $actualCode = if ($caught.Data.Contains('Code')) { [string]$caught.Data['Code'] } else { '(無 Code：' + $caught.Message + ')' }
        if ($actualCode -cne $Code) { throw ('預期錯誤碼 ' + $Code + '，實際 ' + $actualCode) }
    }
    if (-not [string]::IsNullOrEmpty($MessageContains) -and -not $caught.Message.Contains($MessageContains)) {
        throw ('例外訊息不含 ' + $MessageContains + '：' + $caught.Message)
    }
    return $caught
}

function Write-TestUtf8 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    $directory = Split-Path -Parent $Path
    if (-not [IO.Directory]::Exists($directory)) { $null = [IO.Directory]::CreateDirectory($directory) }
    [IO.File]::WriteAllText($Path, $Text, $script:TestUtf8NoBom)
}

function New-TestMachineConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [AllowEmptyCollection()][object[]]$Account = @()
    )

    # 寫 <Directory>\machine.json，Account 為 @{ name; codex_home } 的陣列。回傳檔案路徑。
    $null = [IO.Directory]::CreateDirectory($Directory)
    $document = [ordered]@{
        schema = 'ai-agents.machine.v1'
        codex_accounts = @($Account | ForEach-Object { [ordered]@{ name = [string]$_.name; codex_home = [string]$_.codex_home } })
    }
    $path = Join-Path $Directory 'machine.json'
    Write-TestUtf8 -Path $path -Text (ConvertTo-Json -InputObject $document -Depth 5)
    return $path
}

function New-TestAccountHome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [string]$Profile = 'review',
        [string]$Model = 'fake-model-1',
        [ValidateSet('valid', 'missing', 'empty')][string]$Login = 'valid',
        [switch]$NoProfileConfig
    )

    # 帳號目錄含 auth.json（假內容）與 <檔位>.config.toml。回傳目錄路徑。
    $accountHome = Join-Path $Root $Name
    $null = [IO.Directory]::CreateDirectory($accountHome)
    if ($Login -eq 'valid') { Write-TestUtf8 -Path (Join-Path $accountHome 'auth.json') -Text '{"fake":"test-only"}' }
    if ($Login -eq 'empty') { [IO.File]::WriteAllBytes((Join-Path $accountHome 'auth.json'), [byte[]]@()) }
    if (-not $NoProfileConfig) {
        Write-TestUtf8 -Path (Join-Path $accountHome ($Profile + '.config.toml')) -Text ('model = "' + $Model + '"' + "`n" + 'model_reasoning_effort = "medium"' + "`n")
    }
    return $accountHome
}

function New-TestEventStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyCollection()][object[]]$Event = @(),
        [string[]]$RawLine = @(),
        [string]$Stderr = ''
    )

    # Event 為事件物件陣列（轉成 JSONL），RawLine 為原樣附加的行（測試無法解析行）。回傳 @{ event; error } 兩個檔案路徑。
    $null = [IO.Directory]::CreateDirectory($Directory)
    $lines = @($Event | ForEach-Object { ConvertTo-Json -InputObject $_ -Compress -Depth 8 }) + @($RawLine)
    $eventPath = Join-Path $Directory ($Name + '.events.jsonl')
    $errorPath = Join-Path $Directory ($Name + '.stderr.txt')
    Write-TestUtf8 -Path $eventPath -Text (($lines -join "`n") + "`n")
    Write-TestUtf8 -Path $errorPath -Text $Stderr
    return [pscustomobject]@{ event = $eventPath; error = $errorPath }
}

function New-FakeCodexCmd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$ScriptText
    )

    # 在 Directory 寫 codex.cmd 與 fake-codex-body.ps1，cmd 內容為 pwsh -NoProfile -File <腳本> %*。回傳 codex.cmd 路徑。
    $null = [IO.Directory]::CreateDirectory($Directory)
    $bodyPath = Join-Path $Directory 'fake-codex-body.ps1'
    [IO.File]::WriteAllText($bodyPath, $ScriptText, (New-Object System.Text.UTF8Encoding -ArgumentList @($true)))
    $cmdPath = Join-Path $Directory 'codex.cmd'
    $pwsh = [Environment]::ProcessPath
    [IO.File]::WriteAllText($cmdPath, ('@echo off' + "`r`n" + '"' + $pwsh + '" -NoProfile -File "' + $bodyPath + '" %*' + "`r`n" + 'exit /b %errorlevel%' + "`r`n"), (New-Object System.Text.UTF8Encoding -ArgumentList @($false)))
    return $cmdPath
}

function Invoke-TestGit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$Argument
    )

    $output = & git -C $WorkingDirectory -c user.name=test -c user.email=test@example.invalid -c core.autocrlf=false -c commit.gpgsign=false @Argument 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('git ' + ($Argument -join ' ') + ' 失敗：' + (@($output) -join "`n")) }
    return @($output)
}

function New-TestGitRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [switch]$WithWorktree
    )

    # 在 Directory\main 建立含初始 commit 的 repo；WithWorktree 時另建 Directory\wt 為 linked worktree。
    $root = Join-Path $Directory 'main'
    $null = [IO.Directory]::CreateDirectory($root)
    $null = Invoke-TestGit -WorkingDirectory $root -Argument @('init', '-q', '-b', 'main')
    Write-TestUtf8 -Path (Join-Path $root 'readme.txt') -Text "hello`n"
    $null = Invoke-TestGit -WorkingDirectory $root -Argument @('add', '-A')
    $null = Invoke-TestGit -WorkingDirectory $root -Argument @('commit', '-q', '-m', 'init')
    $worktree = $null
    if ($WithWorktree) {
        $worktree = Join-Path $Directory 'wt'
        $null = Invoke-TestGit -WorkingDirectory $root -Argument @('worktree', 'add', '-q', '-b', 'line', $worktree)
    }
    return [pscustomobject]@{ Root = $root; Worktree = $worktree }
}
