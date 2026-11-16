#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# 判定邏輯在 hooks\core\host-guard.ts，由 tests\run-hook.ts 以命令型 hook 的 stdin 與 stdout 形式執行。
$runHookPath = Join-Path $repositoryRoot 'claude-plugins\ai-agents-hooks\tests\run-hook.ts'
$hooksJsonPath = Join-Path $repositoryRoot 'claude-plugins\ai-agents-hooks\hooks\hooks.json'
$registerPath = Join-Path $repositoryRoot 'claude-plugins\ai-agents-hooks\hooks\register.ts'
$passed = 0
$failed = 0
$optInName = 'AI_AGENTS_ALLOW_POWERSHELL51'
$previousOptIn = [Environment]::GetEnvironmentVariable($optInName)

function Test-Case {
    param([string]$Id, [scriptblock]$Check)
    try {
        & $Check
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

# 以原始位元組取得 hook 的 stdout，stdin 以無 BOM 的 UTF-8 送入。
function Invoke-Hook {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$InputText, [hashtable]$EnvironmentVariables = @{})

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'node'
    $startInfo.Arguments = '--no-warnings "' + $runHookPath + '" host-guard'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($key in $EnvironmentVariables.Keys) { $startInfo.EnvironmentVariables[[string]$key] = [string]$EnvironmentVariables[$key] }
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $errorTask = $process.StandardError.ReadToEndAsync()
        $outputStream = New-Object IO.MemoryStream
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($outputStream)
        $inputBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($InputText)
        $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(60000)) { try { $process.Kill() } catch { }; throw 'hook process timeout' }
        $copyTask.Wait()
        $errorTask.Wait()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $outputStream.ToArray(); Stderr = $errorTask.Result }
    }
    finally { $process.Dispose() }
}

function New-HookInput {
    param([string]$ToolName = 'Bash', [Parameter(Mandatory)][AllowEmptyString()][string]$Command)
    return ([ordered]@{ hook_event_name = 'PreToolUse'; tool_name = $ToolName; tool_input = [ordered]@{ command = $Command } } | ConvertTo-Json -Compress -Depth 4)
}

function Assert-Allowed {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$InputText, [hashtable]$EnvironmentVariables = @{})
    $result = Invoke-Hook -InputText $InputText -EnvironmentVariables $EnvironmentVariables
    Assert-True ($result.ExitCode -eq 0 -and $result.Stdout.Length -eq 0 -and $result.Stderr.Length -eq 0) ("應放行但 exit=$($result.ExitCode) stdout=$([Text.Encoding]::UTF8.GetString($result.Stdout)) stderr=$($result.Stderr)；輸入：$InputText")
}

function Get-DenyResponse {
    param([Parameter(Mandatory)][string]$InputText)
    $result = Invoke-Hook -InputText $InputText
    Assert-True ($result.ExitCode -eq 0 -and $result.Stderr.Length -eq 0) ("拒絕案例 exit=$($result.ExitCode) stderr=$($result.Stderr)；輸入：$InputText")
    Assert-True ($result.Stdout.Length -gt 0) "應輸出 deny JSON 但 stdout 為空；輸入：$InputText"
    return [Text.Encoding]::UTF8.GetString($result.Stdout)
}

function Assert-Denied {
    param([Parameter(Mandatory)][string]$InputText)
    $outputText = Get-DenyResponse -InputText $InputText
    $parsed = $outputText | ConvertFrom-Json
    Assert-True ($parsed.hookSpecificOutput.permissionDecision -ceq 'deny') "permissionDecision 不是 deny：$outputText"
    $reason = [string]$parsed.hookSpecificOutput.permissionDecisionReason
    Assert-True ($reason.Contains('pwsh -NoProfile -File') -and $reason.Contains('pwsh -NoProfile -Command') -and $reason.Contains('Setup-AIGlobalConfig.ps1') -and $reason.Contains($optInName)) "拒絕原因缺少正確寫法、例外或 opt-in 說明：$reason"
}

try {
    [Environment]::SetEnvironmentVariable($optInName, $null)

    Test-Case 'P01 判定邏輯檔 host-guard.ts 為 UTF-8 無 BOM、CRLF，且 register.ts 由它取得判定' {
        $corePath = Join-Path $repositoryRoot 'claude-plugins\ai-agents-hooks\hooks\core\host-guard.ts'
        $bytes = [IO.File]::ReadAllBytes($corePath)
        Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) '含 UTF-8 BOM'
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        Assert-True (-not [regex]::IsMatch($text, '(?<!\r)\n')) '含單獨 LF 行尾'
        $registerText = Get-Content -LiteralPath $registerPath -Raw -Encoding UTF8
        Assert-True ($registerText.Contains("import { hostGuardDenyReason } from './core/host-guard'")) 'register.ts 未匯入 hostGuardDenyReason'
    }

    $allowedCommands = @(
        'pwsh -NoProfile -File x.ps1'
        '& "C:\Program Files\PowerShell\7\pwsh.exe" -File x.ps1'
        'git commit -m "docs: powershell.exe 說明"'
        'rg powershell.exe scripts'
        "Select-String -Pattern 'powershell.exe' a.md"
        'powershell.exe -NoProfile -File C:\x\Setup-AIGlobalConfig.ps1'
    )
    $allowedIndex = 0
    foreach ($command in $allowedCommands) {
        $allowedIndex++
        $capturedCommand = $command
        Test-Case ('A{0:00} 放行：{1}' -f $allowedIndex, $capturedCommand) { Assert-Allowed -InputText (New-HookInput -Command $capturedCommand) }
    }
    $quotedAllowedCommands = @(
        'git commit -m "a; powershell.exe"'
        "rg 'x|powershell.exe' scripts"
        'echo "a && powershell.exe -File x.ps1"'
        'git commit -m "note \"a; powershell.exe 說明"'
        ("cat > f.md <<'EOF'`npowershell.exe -c x`nEOF`n")
    )
    $quotedAllowedIndex = 0
    foreach ($command in $quotedAllowedCommands) {
        $quotedAllowedIndex++
        $capturedCommand = $command
        Test-Case ('Q{0:00} 放行（引號、跳脫或 heredoc 內）：{1}' -f $quotedAllowedIndex, ($capturedCommand -replace '\r?\n', ' / ')) { Assert-Allowed -InputText (New-HookInput -Command $capturedCommand) }
    }
    Test-Case 'A07 放行：tool_name 為 Edit' { Assert-Allowed -InputText ('{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"command":"powershell.exe -c x"}}') }
    Test-Case 'A08 放行：stdin 為損毀 JSON' { Assert-Allowed -InputText '{"tool_name":"Bash","tool_input":{' }
    Test-Case 'A09 放行：command 為空字串' { Assert-Allowed -InputText (New-HookInput -Command '') }
    Test-Case 'A10 放行：stdin 為空' { Assert-Allowed -InputText '' }
    Test-Case 'A11 放行：tool_input 缺少 command' { Assert-Allowed -InputText '{"tool_name":"Bash","tool_input":{"description":"x"}}' }
    Test-Case 'A12 放行：command 型別不是字串' { Assert-Allowed -InputText '{"tool_name":"Bash","tool_input":{"command":123}}' }
    Test-Case 'A13 放行：tool_name 為 PowerShell 且使用 pwsh' { Assert-Allowed -InputText (New-HookInput -ToolName 'PowerShell' -Command '& pwsh -NoProfile -Command Get-Date') }
    Test-Case "A14 放行：設定 $optInName=1 時 powershell.exe 放行" {
        Assert-Allowed -InputText (New-HookInput -Command 'powershell.exe -File a.ps1') -EnvironmentVariables @{ $optInName = '1' }
    }

    $deniedCommands = @(
        'powershell.exe -NoProfile -File a.ps1'
        '& powershell -Command Get-Date'
        'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -File a.ps1'
        'cd x && powershell.exe -c Get-Date'
        'echo a | powershell.exe'
        "Start-Process powershell.exe -ArgumentList '-File a.ps1'"
        'Start-Process -FilePath powershell.exe -Wait'
        'POWERSHELL.EXE -c x'
        'FOO=1 powershell.exe -c x'
        '"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -File a.ps1'
        'powershell.exe -File Setup-AIGlobalConfig.ps1; powershell.exe -c x'
    )
    $deniedIndex = 0
    foreach ($command in $deniedCommands) {
        $deniedIndex++
        $capturedCommand = $command
        Test-Case ('D{0:00} 拒絕：{1}' -f $deniedIndex, $capturedCommand) { Assert-Denied -InputText (New-HookInput -Command $capturedCommand) }
    }
    Test-Case 'D12 拒絕：tool_name 為 PowerShell 且命令為 & powershell.exe -File a.ps1' {
        Assert-Denied -InputText (New-HookInput -ToolName 'PowerShell' -Command '& powershell.exe -File a.ps1')
    }
    Test-Case 'D13 拒絕：多行命令的第二行呼叫 powershell.exe' {
        Assert-Denied -InputText (New-HookInput -Command ("echo start`npowershell.exe -c x"))
    }

    Test-Case 'D14 拒絕：引號外的 ; powershell.exe 仍被擋（引號內同形文字放行）' {
        Assert-Denied -InputText (New-HookInput -Command 'git commit -m "a; powershell.exe"; powershell.exe -c x')
    }
    Test-Case 'D15 拒絕：含 \" 跳脫的引號字串結束後，引號外的 ; powershell.exe 仍被擋' {
        Assert-Denied -InputText (New-HookInput -Command 'git commit -m "note \"a\" b"; powershell.exe -c x')
    }

    # 空白字元集合與 [char]::IsWhiteSpace 相同：U+FEFF 不是空白，U+0085、U+00A0、U+3000 是空白。
    Test-Case 'W01 放行：U+FEFF 夾在 powershell.exe 與參數之間時不切 token' {
        Assert-Allowed -InputText (New-HookInput -Command ('powershell.exe' + [char]0xFEFF + '-Command Get-Date'))
    }
    Test-Case 'W02 拒絕：U+0085 視為空白而切 token' {
        Assert-Denied -InputText (New-HookInput -Command ('powershell.exe' + [char]0x0085 + '-Command Get-Date'))
    }
    Test-Case 'W03 拒絕：U+00A0 視為空白而切 token' {
        Assert-Denied -InputText (New-HookInput -Command ('powershell.exe' + [char]0x00A0 + '-Command Get-Date'))
    }
    Test-Case 'W04 拒絕：U+3000 視為空白而切 token' {
        Assert-Denied -InputText (New-HookInput -ToolName 'PowerShell' -Command ('powershell.exe' + [char]0x3000 + '-Command Get-Date'))
    }
    # 已接受的差異（設計 X7）：緊貼命令名的零權重字元使 token 不等於 powershell.exe，新版放行。
    # 舊版以 PowerShell -eq 的文化比較忽略這些字元而拒絕；這類 token 實際上找不到命令，不會執行 powershell.exe。
    Test-Case 'W05 放行：U+200B 緊貼在 powershell.exe 之前（X7）' {
        Assert-Allowed -InputText (New-HookInput -Command ([string][char]0x200B + 'powershell.exe -Command Get-Date'))
    }
    Test-Case 'W06 放行：U+00AD 夾在 powershell.exe 之中（X7）' {
        Assert-Allowed -InputText (New-HookInput -ToolName 'PowerShell' -Command ('power' + [char]0x00AD + 'shell.exe -Command Get-Date'))
    }
    Test-Case 'D16 拒絕：heredoc 結束標記之後的 powershell.exe 仍被擋' {
        Assert-Denied -InputText (New-HookInput -Command ("cat > f.md <<'EOF'`nbody`nEOF`npowershell.exe -c x"))
    }

    Test-Case 'D17 拒絕：PowerShell 工具的結尾反斜線路徑不使引號保持開啟，其後的 powershell.exe 仍被擋' {
        Assert-Denied -InputText (New-HookInput -ToolName 'PowerShell' -Command 'Set-Location "C:\proj\"; powershell.exe -File x.ps1')
    }
    Test-Case 'Q06 放行：PowerShell 工具以反引號跳脫雙引號，引號內的 ; powershell.exe 是字串內容' {
        Assert-Allowed -InputText (New-HookInput -ToolName 'PowerShell' -Command ('Write-Output "a`"; powershell.exe -c x"'))
    }
    Test-Case 'D18 拒絕：PowerShell 工具反引號跳脫的引號字串結束後，引號外的 ; powershell.exe 仍被擋' {
        Assert-Denied -InputText (New-HookInput -ToolName 'PowerShell' -Command ('Write-Output "a`"b"; powershell.exe -c x'))
    }
    Test-Case 'Q07 放行：Bash 工具的 \" 跳脫維持（引號內的 ; powershell.exe 放行）' {
        Assert-Allowed -InputText (New-HookInput -ToolName 'Bash' -Command 'git commit -m "note \"a; powershell.exe 說明"')
    }

    Test-Case 'S01 淺層探針：違規輸入的 stdout 為單行純 ASCII、無 BOM、可解析的 deny JSON' {
        $result = Invoke-Hook -InputText (New-HookInput -Command 'powershell.exe -File a.ps1')
        $bytes = $result.Stdout
        Assert-True ($result.ExitCode -eq 0 -and $bytes.Length -gt 0) 'exit code 非 0 或 stdout 為空'
        Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'stdout 含 BOM'
        foreach ($byte in $bytes) { Assert-True ($byte -lt 128) 'stdout 含非 ASCII 位元組' }
        $outputText = [Text.Encoding]::ASCII.GetString($bytes)
        Assert-True (@($outputText.Trim() -split '\r?\n').Count -eq 1) 'stdout 不是單行'
        $parsed = $outputText | ConvertFrom-Json -ErrorAction Stop
        Assert-True ($parsed.hookSpecificOutput.hookEventName -ceq 'PreToolUse' -and $parsed.hookSpecificOutput.permissionDecision -ceq 'deny') 'hookEventName 或 permissionDecision 不符'
    }

    Test-Case 'H01 hooks.json 只列出 register.ts 模組，PreToolUse 以 Bash 與 PowerShell 的 matcher 註冊' {
        $hooks = Get-Content -LiteralPath $hooksJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $names = @($hooks.PSObject.Properties.Name)
        Assert-True ($names.Count -eq 1 -and $names[0] -ceq 'modules') ('hooks.json 頂層鍵不符：' + ($names -join ','))
        $modules = @($hooks.modules)
        Assert-True ($modules.Count -eq 1 -and $modules[0] -ceq './register.ts') ('modules 不符：' + ($modules -join ','))
        $registerText = Get-Content -LiteralPath $registerPath -Raw -Encoding UTF8
        $registrations = [regex]::Matches($registerText, "on\('classic\.PreToolUse'")
        Assert-True ($registrations.Count -eq 1) ('classic.PreToolUse 註冊數不是 1：' + $registrations.Count)
        Assert-True ($registerText.Contains("on('classic.PreToolUse', { tool: ['Bash', 'PowerShell'] }")) 'classic.PreToolUse 的 matcher 不是 Bash 與 PowerShell'
    }

    Test-Case 'H02 hooks.json 不含 powershell.exe 作為 command' {
        $hooksText = Get-Content -LiteralPath $hooksJsonPath -Raw -Encoding UTF8
        Assert-True (-not $hooksText.Contains('"powershell.exe"')) 'hooks.json 仍含 "powershell.exe"'
    }
}
finally {
    [Environment]::SetEnvironmentVariable($optInName, $previousOptIn)
}

Write-Output ("PASSED {0} FAILED {1}" -f $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
