#Requires -Version 7.0
# MCP 工具呼叫紀錄 hook 的測試：判定與紀錄內容在 hooks\core\mcp-call-record.ts，
# 由 tests\run-hook.ts 的 mcp-call 模式以命令型 hook 的 stdin 形式執行，紀錄寫到本測試指定的 LOCALAPPDATA 暫存目錄。
# 註冊層（事件與 matcher 的接線）由 claude-plugins\ai-agents-hooks\tests\register.test.ts 驗證。
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$pluginRoot = Join-Path $repoRoot 'claude-plugins\ai-agents-hooks'
$runHook = Join-Path $pluginRoot 'tests\run-hook.ts'
$recordSource = Join-Path $pluginRoot 'hooks\core\mcp-call-record.ts'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$passed = 0
$failed = 0

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

function Invoke-McpCallHook {
    # LocalAppData 為 $null 時不設定 LOCALAPPDATA 環境變數（模擬未設定）。回傳 Written（寫入的完整路徑或 $null）與 Text（檔案內容或 $null）。
    param([Parameter(Mandatory)]$EventData, [ValidateSet('completed', 'failed')][string]$Kind = 'completed', [AllowNull()][string]$LocalAppData, [string]$Now = '2026-11-28T00:00:00.000Z')

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new('node')
    foreach ($argument in @('--no-warnings', $runHook, 'mcp-call')) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $startInfo.StandardOutputEncoding = $utf8NoBom
    if ([string]::IsNullOrEmpty($LocalAppData)) { [void]$startInfo.EnvironmentVariables.Remove('LOCALAPPDATA') }
    else { $startInfo.EnvironmentVariables['LOCALAPPDATA'] = $LocalAppData }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdin = ([ordered]@{ event = $EventData; kind = $Kind; now = $Now } | ConvertTo-Json -Depth 6 -Compress)
        $stdinBytes = $utf8NoBom.GetBytes($stdin)
        $process.StandardInput.BaseStream.Write($stdinBytes, 0, $stdinBytes.Length)
        $process.StandardInput.Close()
        $output = $process.StandardOutput.ReadToEnd()
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0 -or $errorText.Length -ne 0) { throw "exit=$($process.ExitCode) stderr=$errorText" }
        $written = (ConvertFrom-Json -InputObject $output).written
        $text = if ($null -ne $written -and [IO.File]::Exists($written)) { [IO.File]::ReadAllText($written, $utf8NoBom) } else { $null }
        return [pscustomobject]@{ Written = $written; Text = $text }
    }
    finally {
        $process.Dispose()
    }
}

function New-CallEvent {
    param([string]$Tool = 'mcp__playwright__browser_click', [string]$ToolUseId = 'toolu_01', [AllowNull()][string]$AgentId = 'agent-a', [hashtable]$Extra = @{})
    $data = [ordered]@{ session_id = 's1'; tool_name = $Tool; tool_use_id = $ToolUseId; agent_type = 'general-purpose'; duration_ms = 12 }
    if (-not [string]::IsNullOrEmpty($AgentId)) { $data['agent_id'] = $AgentId }
    foreach ($key in $Extra.Keys) { $data[$key] = $Extra[$key] }
    return $data
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('mcp-call-hook-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $callRoot = Join-Path $root 'ai-agents\mcp-calls'

    Test-Case 'MH01 成功事件寫出紀錄：路徑為 <LOCALAPPDATA>\ai-agents\mcp-calls\<agent_id>\<tool_use_id>.json，內容含 schema、server、status、agent_id、ts_utc、tool_name' {
        $result = Invoke-McpCallHook -EventData (New-CallEvent -Extra @{ mcp_server = [ordered]@{ name = 'playwright'; source = 'user' } }) -LocalAppData $root
        Assert-True ($result.Written -ceq (Join-Path $callRoot 'agent-a\toolu_01.json')) ('路徑不符：' + $result.Written)
        $record = ConvertFrom-Json -InputObject $result.Text
        Assert-True ($record.schema -ceq 'ai-agents.mcp-call.v1') 'schema'
        Assert-True ($record.server -ceq 'playwright' -and $record.status -ceq 'completed' -and $record.agent_id -ceq 'agent-a') 'server、status 或 agent_id 不符'
        Assert-True ($record.tool_name -ceq 'mcp__playwright__browser_click' -and $record.session_id -ceq 's1' -and $record.agent_type -ceq 'general-purpose') 'tool_name、session_id 或 agent_type 不符'
        Assert-True ($result.Text -match '"ts_utc":\s*"2026-11-28T00:00:00\.000Z"') 'ts_utc 不符'
        Assert-True ($record.duration_ms -eq 12) 'duration_ms'
        Assert-True ($null -eq $record.PSObject.Properties['is_interrupt']) '成功事件不應有 is_interrupt'
    }
    Test-Case 'MH02 失敗事件的 status 為 failed 並帶 is_interrupt（true 與 false）' {
        $failedEvent = Invoke-McpCallHook -EventData (New-CallEvent -ToolUseId 'toolu_02' -Extra @{ error = 'boom'; is_interrupt = $false }) -Kind 'failed' -LocalAppData $root
        $interrupted = Invoke-McpCallHook -EventData (New-CallEvent -ToolUseId 'toolu_03' -Extra @{ is_interrupt = $true }) -Kind 'failed' -LocalAppData $root
        $first = ConvertFrom-Json -InputObject $failedEvent.Text
        $second = ConvertFrom-Json -InputObject $interrupted.Text
        Assert-True ($first.status -ceq 'failed' -and $first.is_interrupt -eq $false) '失敗事件'
        Assert-True ($second.status -ceq 'failed' -and $second.is_interrupt -eq $true) '中斷的失敗事件'
    }
    Test-Case 'MH03 主執行緒的呼叫（沒有 agent_id）寫入 _main 目錄，agent_id 為 null' {
        $result = Invoke-McpCallHook -EventData (New-CallEvent -ToolUseId 'toolu_04' -AgentId $null) -LocalAppData $root
        Assert-True ($result.Written -ceq (Join-Path $callRoot '_main\toolu_04.json')) ('路徑不符：' + $result.Written)
        Assert-True ($null -eq (ConvertFrom-Json -InputObject $result.Text).agent_id) 'agent_id 應為 null'
    }
    Test-Case 'MH04 playwright 與 flaui-mcp 的工具都被記錄；伺服器名稱缺少 mcp_server 時由工具名稱解析' {
        $playwright = Invoke-McpCallHook -EventData (New-CallEvent -Tool 'mcp__playwright__browser_navigate' -ToolUseId 'toolu_05') -LocalAppData $root
        $flaui = Invoke-McpCallHook -EventData (New-CallEvent -Tool 'mcp__flaui-mcp__windows_click' -ToolUseId 'toolu_06') -LocalAppData $root
        Assert-True ((ConvertFrom-Json -InputObject $playwright.Text).server -ceq 'playwright') 'playwright'
        Assert-True ((ConvertFrom-Json -InputObject $flaui.Text).server -ceq 'flaui-mcp') 'flaui-mcp'
    }
    Test-Case 'MH05 非受控的伺服器與工具（其他 MCP、Bash、名稱只是前綴相似）不寫檔' {
        foreach ($tool in @('mcp__other__browser_click', 'Bash', 'mcp__playwright-extra__x', 'mcp__playwrightx__x', 'playwright', 'mcp__playwright')) {
            $result = Invoke-McpCallHook -EventData (New-CallEvent -Tool $tool -ToolUseId 'toolu_07') -LocalAppData $root
            Assert-True ($null -eq $result.Written) ('不應寫入：' + $tool)
        }
    }
    Test-Case 'MH06 LOCALAPPDATA 未設定時不寫檔' {
        $result = Invoke-McpCallHook -EventData (New-CallEvent -ToolUseId 'toolu_08') -LocalAppData $null
        Assert-True ($null -eq $result.Written) '未設定 LOCALAPPDATA 不應寫入'
    }
    Test-Case 'MH07 agent_id 或 tool_use_id 含路徑分隔符、.. 或其他非法字元時不寫檔（避免路徑注入）' {
        $beforeCount = @(Get-ChildItem -LiteralPath $root -Recurse -File).Count
        $invalidAgents = @('..', '..\evil', '../evil', 'a\b', 'a/b', 'a b', 'a:b', ('a' * 129))
        foreach ($agent in $invalidAgents) {
            $result = Invoke-McpCallHook -EventData (New-CallEvent -ToolUseId 'toolu_09' -AgentId $agent) -LocalAppData $root
            Assert-True ($null -eq $result.Written) ('agent_id 不應寫入：' + $agent)
        }
        foreach ($id in @('..', '..\x', 'a/b', 'a.b', '')) {
            $result = Invoke-McpCallHook -EventData (New-CallEvent -ToolUseId $id) -LocalAppData $root
            Assert-True ($null -eq $result.Written) ('tool_use_id 不應寫入：' + $id)
        }
        $missingId = New-CallEvent
        $missingId.Remove('tool_use_id')
        Assert-True ($null -eq (Invoke-McpCallHook -EventData $missingId -LocalAppData $root).Written) '缺少 tool_use_id 不應寫入'
        Assert-True (@(Get-ChildItem -LiteralPath $root -Recurse -File).Count -eq $beforeCount) '不應新增任何檔案'
    }
    Test-Case 'MH08 tool_input 含 password、error 含敏感文字時，寫出的檔案不含這些字串（不記錄工具輸入、輸出與錯誤）' {
        $secret = 'password-SECRET-123'
        $event = New-CallEvent -Tool 'mcp__playwright__browser_type' -ToolUseId 'toolu_10' -Extra @{ tool_input = [ordered]@{ text = $secret; password = $secret }; tool_response = [ordered]@{ content = $secret }; error = $secret }
        $success = Invoke-McpCallHook -EventData $event -LocalAppData $root
        $failure = Invoke-McpCallHook -EventData $event -Kind 'failed' -LocalAppData $root
        Assert-True ($null -ne $success.Text -and -not $success.Text.Contains('SECRET') -and -not $success.Text.Contains('password')) '成功紀錄含敏感字串'
        Assert-True ($null -ne $failure.Text -and -not $failure.Text.Contains('SECRET') -and -not $failure.Text.Contains('password')) '失敗紀錄含敏感字串'
    }
    Test-Case 'MH09 核心邏輯不讀取工具輸入、輸出與錯誤欄位（原始碼沒有 tool_input、tool_response、.error）；hooks.json 仍只列 modules' {
        $source = [IO.File]::ReadAllText($recordSource)
        Assert-True ($source -notmatch 'tool_input|tool_response|\.error') '原始碼不應讀取工具輸入、輸出或錯誤'
        $hooksJson = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $pluginRoot 'hooks\hooks.json')))
        Assert-True (@($hooksJson.PSObject.Properties.Name) -join ',' -ceq 'modules' -and @($hooksJson.modules).Count -eq 1) 'hooks.json 只應列 modules'
    }
    Test-Case 'MH10 同一 agent 的多次呼叫各寫一個檔案，互不覆寫' {
        $first = Invoke-McpCallHook -EventData (New-CallEvent -ToolUseId 'toolu_11' -AgentId 'agent-b') -LocalAppData $root
        $second = Invoke-McpCallHook -EventData (New-CallEvent -ToolUseId 'toolu_12' -AgentId 'agent-b') -LocalAppData $root
        Assert-True ($first.Written -cne $second.Written -and [IO.File]::Exists($first.Written) -and [IO.File]::Exists($second.Written)) '應為兩個檔案'
    }
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output "PASSED: $passed"
Write-Output "FAILED: $failed"
if ($failed -gt 0) { exit 1 }
exit 0
