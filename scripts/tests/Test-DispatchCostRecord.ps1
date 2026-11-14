#Requires -Version 7.0
<#
.SYNOPSIS
循環欄位、usage 解析與成本事件列追加的單元測試。

.PARAMETER Unit
Identity：循環欄位的解析、驗證與 Request 往返。
Usage：Get-DispatchRunUsage 的事件流解析與取最後一筆有效的累計 usage。
Ledger：Add-DispatchCostLedgerRow 的檔案建立、附加、去重與跳脫。
Hook：Invoke-DispatchCostRecord 的 Inspect 掛勾行為。
Comparison：成效比對文件的程式區塊。
All：依序執行已實作的全部單元。
#>
[CmdletBinding()]
param(
    [ValidateSet('Identity', 'Usage', 'Ledger', 'Hook', 'Comparison', 'All')]
    [string]$Unit = 'All',

    [string]$FixtureBaseRootPath = [IO.Path]::GetTempPath()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $scriptsRoot
foreach ($moduleName in @(
        'common-runtime.ps1', 'git-baseline.ps1', 'dispatch-scope.ps1', 'dispatch-evidence.ps1',
        'quota-observation.ps1', 'advisor-evidence.ps1', 'process-identity.ps1', 'reviewer-contract.ps1',
        'run-recovery.ps1', 'prepare-stage.ps1', 'dispatch-lifecycle.ps1', 'start-lifecycle.ps1',
        'inspect-lifecycle.ps1', 'collect-contract.ps1', 'cleanup.ps1', 'Invoke-DispatchConcurrency.ps1')) {
    . (Join-Path (Join-Path $scriptsRoot 'dispatch') $moduleName)
}
$script:CallerSessionIdentity = $null

$script:cases = New-Object 'System.Collections.Generic.List[object]'
$script:fixtureRoot = Join-Path ([IO.Path]::GetFullPath($FixtureBaseRootPath)) ('cr' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = [IO.Directory]::CreateDirectory($script:fixtureRoot)

function Assert-Case {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action
        $script:cases.Add([pscustomobject]@{ name = $Name; result = 'PASS'; error = $null })
    }
    catch {
        $script:cases.Add([pscustomobject]@{ name = $Name; result = 'FAIL'; error = $_.Exception.Message })
    }
}

function Write-TestUtf8NoBom {
    param([string]$Path, [string]$Text)
    $directory = Split-Path -Parent $Path
    if (-not [IO.Directory]::Exists($directory)) { $null = [IO.Directory]::CreateDirectory($directory) }
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-FailureCode {
    param([scriptblock]$Action)
    try {
        & $Action | Out-Null
    }
    catch {
        $operationResult = $_.Exception.Data['operationResult']
        if ($null -ne $operationResult) { return [string]$operationResult.code }
        return 'UnexpectedException:' + $_.Exception.Message
    }
    return 'NoFailure'
}

function New-RequestJson {
    param([string]$Operation, [string[]]$ExtraLines)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('"schema": "ai-sessions.dispatch-request.v1"')
    $lines.Add('"operation": "' + $Operation + '"')
    $lines.Add('"line_slug": "cost-line"')
    $lines.Add('"dispatch_slug": "cost-probe"')
    if ($Operation -eq 'Dispatch') {
        $lines.Add('"source_root": "C:\\fixture\\source"')
        $lines.Add('"dispatch_root": "C:\\fixture\\source\\.local\\ai-sessions\\worktrees\\cost-probe"')
        $lines.Add('"target_path": ["C:\\fixture\\source\\a.txt"]')
        $lines.Add('"write_mode": "readonly"')
        $lines.Add('"dispatch_kind": "resource"')
        $lines.Add('"prompt_path": "C:\\fixture\\prompt.md"')
        $lines.Add('"task_type": "scan"')
        $lines.Add('"session_mode": "cold-start"')
        $lines.Add('"unit_kind": "resource-target"')
        $lines.Add('"failure_receipt_path": "C:\\fixture\\failure.json"')
    }
    foreach ($extra in @($ExtraLines)) {
        if (-not [string]::IsNullOrEmpty($extra)) { $lines.Add($extra) }
    }
    return ('{' + [Environment]::NewLine + '  ' + ($lines -join (',' + [Environment]::NewLine + '  ')) + [Environment]::NewLine + '}')
}

function Read-RequestFromText {
    param([string]$Name, [string]$Operation, [string[]]$ExtraLines)
    $path = Join-Path $script:fixtureRoot ($Name + '.json')
    Write-TestUtf8NoBom -Path $path -Text (New-RequestJson -Operation $Operation -ExtraLines $ExtraLines)
    return (Read-DispatchRequest -Path $path)
}

function Invoke-IdentityUnit {
    Invoke-Case 'Identity:完整欄位且 cycle_round 為整數時解析為規範化值' {
        $document = ConvertFrom-DispatchJson -Content '{"cycle_id":"c16-move-c1","cycle_round":2,"cycle_role":"review"}'
        $identity = Get-DispatchCycleIdentity -Document $document -Validate
        Assert-Case ($identity.present -eq $true) 'present 應為 true'
        Assert-Case ($identity.cycle_id -ceq 'c16-move-c1') 'cycle_id 不符'
        Assert-Case ($identity.cycle_round -eq 2 -and $identity.cycle_round -is [int]) 'cycle_round 應為整數 2'
        Assert-Case ($identity.cycle_role -ceq 'review') 'cycle_role 不符'
    }
    Invoke-Case 'Identity:cycle_round 為數字字串時規範化為整數' {
        $document = ConvertFrom-DispatchJson -Content '{"cycle_id":"a-c1","cycle_round":"12","cycle_role":"fix"}'
        $identity = Get-DispatchCycleIdentity -Document $document -Validate
        Assert-Case ($identity.cycle_round -is [int] -and $identity.cycle_round -eq 12) 'cycle_round 應規範化為整數 12'
        Assert-Case ($identity.cycle_role -ceq 'fix') 'cycle_role 應為 fix'
    }
    Invoke-Case 'Identity:邊界值 1 與 99 合法，長度 64 的 cycle_id 合法' {
        $longId = ('a' * 64)
        $document = ConvertFrom-DispatchJson -Content ('{"cycle_id":"' + $longId + '","cycle_round":99,"cycle_role":"review"}')
        $identity = Get-DispatchCycleIdentity -Document $document -Validate
        Assert-Case ($identity.cycle_round -eq 99 -and $identity.cycle_id.Length -eq 64) '邊界值應合法'
        $document = ConvertFrom-DispatchJson -Content '{"cycle_id":"a","cycle_round":1,"cycle_role":"review"}'
        Assert-Case ((Get-DispatchCycleIdentity -Document $document -Validate).cycle_round -eq 1) 'cycle_round=1 應合法'
    }
    Invoke-Case 'Identity:全部省略時 present 為 false 且三值為 null' {
        $document = ConvertFrom-DispatchJson -Content '{"operation":"Dispatch"}'
        $identity = Get-DispatchCycleIdentity -Document $document -Validate
        Assert-Case ($identity.present -eq $false) 'present 應為 false'
        Assert-Case ($null -eq $identity.cycle_id -and $null -eq $identity.cycle_round -and $null -eq $identity.cycle_role) '三值應為 null'
        $nullIdentity = Get-DispatchCycleIdentity -Document $null
        Assert-Case ($nullIdentity.present -eq $false) 'Document 為 null 時 present 應為 false'
    }
    Invoke-Case 'Identity:Dispatch Request 經 Read-DispatchRequest 保留三個欄位' {
        $context = Read-RequestFromText -Name 'identity-ok' -Operation 'Dispatch' -ExtraLines @('"cycle_id": "cost-probe-c1"', '"cycle_round": 2', '"cycle_role": "review"')
        Assert-Case ([string]$context.dispatch_values.cycle_id -ceq 'cost-probe-c1') 'dispatch_values.cycle_id 不符'
        Assert-Case ($context.dispatch_values.cycle_round -eq 2) 'dispatch_values.cycle_round 不符'
        Assert-Case ([string]$context.dispatch_values.cycle_role -ceq 'review') 'dispatch_values.cycle_role 不符'
        Assert-Case ($context.dispatch_field_presence.cycle_id -eq $true) 'field_presence.cycle_id 應為 true'
        $fromDocument = Get-DispatchCycleIdentity -Document $context.document
        Assert-Case ($fromDocument.cycle_id -ceq $context.dispatch_values.cycle_id -and $fromDocument.cycle_round -eq $context.dispatch_values.cycle_round -and $fromDocument.cycle_role -ceq $context.dispatch_values.cycle_role) 'Get-DispatchCycleIdentity 讀取值應等於 Request 值'
    }
    Invoke-Case 'Identity:Dispatch Request 省略三欄時 dispatch_values 為 null' {
        $context = Read-RequestFromText -Name 'identity-none' -Operation 'Dispatch' -ExtraLines @()
        Assert-Case ($null -eq $context.dispatch_values.cycle_id -and $null -eq $context.dispatch_values.cycle_round -and $null -eq $context.dispatch_values.cycle_role) '省略時三值應為 null'
        Assert-Case ($context.dispatch_field_presence.cycle_id -eq $false) 'field_presence.cycle_id 應為 false'
    }
    Invoke-Case 'Identity:欄位數量為 1 或 2 時以 DispatchRequestMissingField 拒絕並指名缺少欄位' {
        $cases = @(
            @{ extra = @('"cycle_id": "a-c1"'); missing = 'cycle_round' },
            @{ extra = @('"cycle_round": 1'); missing = 'cycle_id' },
            @{ extra = @('"cycle_role": "review"'); missing = 'cycle_id' },
            @{ extra = @('"cycle_id": "a-c1"', '"cycle_round": 1'); missing = 'cycle_role' },
            @{ extra = @('"cycle_round": 1', '"cycle_role": "fix"'); missing = 'cycle_id' }
        )
        $index = 0
        foreach ($case in $cases) {
            $index++
            $document = ConvertFrom-DispatchJson -Content ('{' + (@($case.extra) -join ',') + '}')
            $captured = $null
            try { Get-DispatchCycleIdentity -Document $document -RequestPathValue 'C:\fixture\request.json' -Validate | Out-Null } catch { $captured = $_.Exception }
            Assert-Case ($null -ne $captured) ('案例 ' + $index + ' 應拒絕')
            $result = $captured.Data['operationResult']
            Assert-Case ($result.code -ceq 'DispatchRequestMissingField') ('案例 ' + $index + ' 錯誤碼應為 DispatchRequestMissingField，實際 ' + $result.code)
            Assert-Case ($captured.Message.Contains([string]$case.missing)) ('案例 ' + $index + ' 訊息應指名缺少的欄位 ' + $case.missing)
        }
        $code = Get-FailureCode { Read-RequestFromText -Name 'identity-partial' -Operation 'Dispatch' -ExtraLines @('"cycle_id": "a-c1"') }
        Assert-Case ($code -ceq 'DispatchRequestMissingField') ('經 Read-DispatchRequest 的部分欄位應為 DispatchRequestMissingField，實際 ' + $code)
    }
    Invoke-Case 'Identity:格式、範圍或列舉不符時以 DispatchRequestInvalidValue 拒絕' {
        $badCases = @(
            @{ name = 'Bad_ID'; extra = @('"cycle_id": "Bad_ID"', '"cycle_round": 1', '"cycle_role": "review"') },
            @{ name = 'len65'; extra = @(('"cycle_id": "' + ('a' * 65) + '"'), '"cycle_round": 1', '"cycle_role": "review"') },
            @{ name = 'empty'; extra = @('"cycle_id": ""', '"cycle_round": 1', '"cycle_role": "review"') },
            @{ name = 'round0'; extra = @('"cycle_id": "a-c1"', '"cycle_round": 0', '"cycle_role": "review"') },
            @{ name = 'round100'; extra = @('"cycle_id": "a-c1"', '"cycle_round": 100', '"cycle_role": "review"') },
            @{ name = 'roundNegative'; extra = @('"cycle_id": "a-c1"', '"cycle_round": -1', '"cycle_role": "review"') },
            @{ name = 'roundX'; extra = @('"cycle_id": "a-c1"', '"cycle_round": "x"', '"cycle_role": "review"') },
            @{ name = 'round1.5'; extra = @('"cycle_id": "a-c1"', '"cycle_round": 1.5', '"cycle_role": "review"') },
            @{ name = 'roundNull'; extra = @('"cycle_id": "a-c1"', '"cycle_round": null', '"cycle_role": "review"') },
            @{ name = 'roleTest'; extra = @('"cycle_id": "a-c1"', '"cycle_round": 1', '"cycle_role": "test"') },
            @{ name = 'roleUpper'; extra = @('"cycle_id": "a-c1"', '"cycle_round": 1', '"cycle_role": "Review"') }
        )
        foreach ($case in $badCases) {
            $extra = @($case.extra)
            $code = Get-FailureCode { Read-RequestFromText -Name ('identity-bad-' + $case.name) -Operation 'Dispatch' -ExtraLines $extra }
            Assert-Case ($code -ceq 'DispatchRequestInvalidValue') ($case.name + ' 應為 DispatchRequestInvalidValue，實際 ' + $code)
        }
        $captured = $null
        $document = ConvertFrom-DispatchJson -Content '{"cycle_id":"a-c1","cycle_round":100,"cycle_role":"review"}'
        try { Get-DispatchCycleIdentity -Document $document -Validate | Out-Null } catch { $captured = $_.Exception }
        $detail = $captured.Data['operationResult'].detail
        Assert-Case (-not [string]::IsNullOrWhiteSpace([string]$detail.expected_format)) 'detail 應含 expected_format'
    }
    Invoke-Case 'Identity:Prepare、Start、Cleanup 的 Request 帶 cycle_id 以 DispatchRequestFieldNotAllowed 拒絕' {
        foreach ($operation in @('Prepare', 'Start', 'Cleanup', 'Inspect', 'Collect', 'Preflight')) {
            $code = Get-FailureCode { Read-RequestFromText -Name ('identity-op-' + $operation) -Operation $operation -ExtraLines @('"cycle_id": "a-c1"') }
            Assert-Case ($code -ceq 'DispatchRequestFieldNotAllowed') ($operation + ' 應為 DispatchRequestFieldNotAllowed，實際 ' + $code)
        }
    }
    Invoke-Case 'Identity:舊 RunRecord 沒有三欄時以 Get-DispatchJsonProperty 取得 null' {
        $oldRecord = ConvertFrom-DispatchJson -Content '{"schema":"ai-sessions.dispatch-run.v1","run_id":"r1","dispatch_slug":"cost-probe"}'
        foreach ($name in @('cycle_id', 'cycle_round', 'cycle_role')) {
            Assert-Case ($null -eq (Get-DispatchJsonProperty -Object $oldRecord -Name $name)) ($name + ' 缺少時應取得 null')
        }
    }
    Invoke-Case 'Identity:超過 Int32 的 cycle_round 與尾端換行的 cycle_id 以 DispatchRequestInvalidValue 拒絕' {
        $bigRound = ConvertFrom-DispatchJson -Content '{"cycle_id":"a-c1","cycle_round":2147483648,"cycle_role":"review"}'
        $code = Get-FailureCode { Get-DispatchCycleIdentity -Document $bigRound -Validate | Out-Null }
        Assert-Case ($code -ceq 'DispatchRequestInvalidValue') ('大整數 cycle_round 應為 DispatchRequestInvalidValue，實際 ' + $code)
        $newlineId = ConvertFrom-DispatchJson -Content '{"cycle_id":"a-c1\n","cycle_round":1,"cycle_role":"review"}'
        $code = Get-FailureCode { Get-DispatchCycleIdentity -Document $newlineId -Validate | Out-Null }
        Assert-Case ($code -ceq 'DispatchRequestInvalidValue') ('尾端換行的 cycle_id 應為 DispatchRequestInvalidValue，實際 ' + $code)
    }
    Invoke-Case 'Identity:續行沿用錨點 RunRecord 的循環欄位，舊 RunRecord 不沿用' {
        $anchor = ConvertFrom-DispatchJson -Content '{"schema":"ai-sessions.dispatch-run.v1","run_id":"r1","cycle_id":"cost-probe-c1","cycle_round":1,"cycle_role":"review"}'
        $inherited = Get-DispatchCycleIdentity -Document $anchor
        Assert-Case ($inherited.present -and $inherited.cycle_id -ceq 'cost-probe-c1' -and $inherited.cycle_round -eq 1 -and $inherited.cycle_role -ceq 'review') '錨點三欄應原樣取得'
        $legacy = ConvertFrom-DispatchJson -Content '{"schema":"ai-sessions.dispatch-run.v1","run_id":"r0"}'
        Assert-Case (-not (Get-DispatchCycleIdentity -Document $legacy).present) '舊 RunRecord 沒有三欄時 present 應為 false'
        $startText = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'dispatch\start-lifecycle.ps1'))
        Assert-Case ([regex]::IsMatch($startText, 'Get-DispatchCycleIdentity -Document \$previousRun\.AnchorRecord')) 'Invoke-Start 應在 Request 未提供三欄時讀取錨點 RunRecord'
    }
    Invoke-Case 'Identity:Invoke-CodexDispatch 入口沒有新增命令列參數' {
        $entryText = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'Invoke-CodexDispatch.ps1'))
        Assert-Case (-not [regex]::IsMatch($entryText, 'CycleId|CycleRound|CycleRole')) '入口不應出現 CycleId、CycleRound、CycleRole'
    }
}

function ConvertTo-TestEvent {
    param([string[]]$Json)
    return @($Json | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-TestLedgerRows {
    param([string]$Path)
    $text = [IO.File]::ReadAllText($Path)
    $rows = @($text -split '\r?\n' | Where-Object { $_.StartsWith('| ') -and -not $_.StartsWith('| ---') -and -not $_.StartsWith('| 時間（UTC）') })
    return , $rows
}

function Split-TestLedgerRow {
    param([string]$Row)
    $trimmed = $Row.Substring(2, $Row.Length - 4)
    return @([regex]::Split($trimmed, '(?<!\\) \| '))
}

function New-TestLedgerRow {
    param([string]$RunId, [string]$Note = 'note')
    return @('2026-11-10T00:00:00Z', '事件', 'cost-line', 'cost-probe', $RunId, 'cost-probe-c1', '1', 'review', '首次', '5', '10', '4', '2', $Note)
}

function Invoke-UsageUnit {
    $turnOne = '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10,"reasoning_output_tokens":3}}'
    $turnTwo = '{"type":"turn.completed","usage":{"input_tokens":50,"cached_input_tokens":20,"output_tokens":5,"reasoning_output_tokens":1}}'
    $started = '{"type":"thread.started","thread_id":"00000000-0000-0000-0000-000000000001"}'

    Invoke-Case 'Usage:兩個 turn.completed 取最後一筆（thread 累計值），不逐欄加總' {
        $summary = Get-DispatchRunUsage -Event (ConvertTo-TestEvent -Json @($started, $turnOne, $turnTwo))
        Assert-Case ($summary.status -ceq 'recorded') ('status 應為 recorded，實際 ' + $summary.status)
        Assert-Case ($summary.turn_completed_count -eq 2) 'turn_completed_count 應為 2'
        Assert-Case ($summary.usage['input_tokens'] -eq 50) 'input_tokens 應為最後一筆的 50'
        Assert-Case ($summary.usage['cached_input_tokens'] -eq 20) 'cached_input_tokens 應為最後一筆的 20'
        Assert-Case ($summary.usage['output_tokens'] -eq 5) 'output_tokens 應為最後一筆的 5'
        Assert-Case ($summary.usage['reasoning_output_tokens'] -eq 1) 'reasoning_output_tokens 應為最後一筆的 1'
    }
    Invoke-Case 'Usage:沒有 cached_input_tokens 與 reasoning_output_tokens 時視為 0' {
        $summary = Get-DispatchRunUsage -Event (ConvertTo-TestEvent -Json @('{"type":"turn.completed","usage":{"input_tokens":7,"output_tokens":3}}'))
        Assert-Case ($summary.status -ceq 'recorded' -and $summary.usage['input_tokens'] -eq 7 -and $summary.usage['cached_input_tokens'] -eq 0 -and $summary.usage['reasoning_output_tokens'] -eq 0) '缺少的選用欄位應為 0'
    }
    Invoke-Case 'Usage:沒有 turn.completed 為 no-terminal-event' {
        $summary = Get-DispatchRunUsage -Event (ConvertTo-TestEvent -Json @($started, '{"type":"turn.started"}'))
        Assert-Case ($summary.status -ceq 'no-terminal-event') ('status 應為 no-terminal-event，實際 ' + $summary.status)
        Assert-Case ($summary.turn_completed_count -eq 0 -and $null -eq $summary.usage) 'usage 應為 null'
        $emptySummary = Get-DispatchRunUsage -Event @()
        Assert-Case ($emptySummary.status -ceq 'no-terminal-event') '空事件應為 no-terminal-event'
    }
    Invoke-Case 'Usage:usage 缺 output_tokens 或型別非數值時為 no-usage-field' {
        $missing = Get-DispatchRunUsage -Event (ConvertTo-TestEvent -Json @('{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40}}'))
        Assert-Case ($missing.status -ceq 'no-usage-field' -and $null -eq $missing.usage -and $missing.turn_completed_count -eq 1) '缺 output_tokens 應為 no-usage-field'
        $notNumber = Get-DispatchRunUsage -Event (ConvertTo-TestEvent -Json @('{"type":"turn.completed","usage":{"input_tokens":"100","output_tokens":5}}'))
        Assert-Case ($notNumber.status -ceq 'no-usage-field') '字串型別應為 no-usage-field'
        $noUsage = Get-DispatchRunUsage -Event (ConvertTo-TestEvent -Json @('{"type":"turn.completed"}'))
        Assert-Case ($noUsage.status -ceq 'no-usage-field') '沒有 usage 屬性應為 no-usage-field'
    }
    Invoke-Case 'Usage:最後一筆無效時取其前最後一筆有效者，無效筆不得進入結果' {
        $mixed = Get-DispatchRunUsage -Event (ConvertTo-TestEvent -Json @($turnOne, '{"type":"turn.completed","usage":{"input_tokens":"x","output_tokens":5}}'))
        Assert-Case ($mixed.status -ceq 'recorded' -and $mixed.turn_completed_count -eq 2) '有效筆存在時應為 recorded'
        Assert-Case ($mixed.usage['input_tokens'] -eq 100 -and $mixed.usage['output_tokens'] -eq 10) '無效筆不得進入結果'
    }
    Invoke-Case 'Usage:累計值遞增的兩筆 turn.completed 取最後一筆，與事件流參數集一致' {
        $cumulativeOne = '{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":50,"reasoning_output_tokens":10}}'
        $cumulativeTwo = '{"type":"turn.completed","usage":{"input_tokens":2500,"cached_input_tokens":2300,"output_tokens":120,"reasoning_output_tokens":30}}'
        $fromEvents = Get-DispatchRunUsage -Event (ConvertTo-TestEvent -Json @($started, $cumulativeOne, $cumulativeTwo))
        Assert-Case ($fromEvents.usage['input_tokens'] -eq 2500 -and $fromEvents.usage['cached_input_tokens'] -eq 2300 -and $fromEvents.usage['output_tokens'] -eq 120 -and $fromEvents.usage['reasoning_output_tokens'] -eq 30) '應取最後一筆累計值'
        $path = Join-Path $script:fixtureRoot 'usage-cumulative.jsonl'
        Write-TestUtf8NoBom -Path $path -Text ($started + "`n" + $cumulativeOne + "`n" + $cumulativeTwo + "`n")
        $fromStream = Get-DispatchRunUsage -EventStreamPath $path
        Assert-Case ($fromStream.usage['input_tokens'] -eq 2500 -and $fromStream.turn_completed_count -eq 2) '事件流參數集應取最後一筆'
    }
    Invoke-Case 'Usage:事件流含無法解析的行時其餘行照常解析，且與 -Event 結果相同' {
        $path = Join-Path $script:fixtureRoot 'usage-stream.jsonl'
        Write-TestUtf8NoBom -Path $path -Text ($started + "`n" + 'not json {{' + "`n" + $turnOne + "`n`n" + $turnTwo + "`n")
        $fromStream = Get-DispatchRunUsage -EventStreamPath $path
        $fromEvents = Get-DispatchRunUsage -Event (ConvertTo-TestEvent -Json @($started, $turnOne, $turnTwo))
        Assert-Case ($fromStream.status -ceq 'recorded') '事件流應為 recorded'
        Assert-Case (($fromStream | ConvertTo-Json -Depth 5 -Compress) -ceq ($fromEvents | ConvertTo-Json -Depth 5 -Compress)) '兩個參數集結果應相同'
        $missingPath = Join-Path $script:fixtureRoot 'usage-missing.jsonl'
        Assert-Case ((Get-DispatchRunUsage -EventStreamPath $missingPath).status -ceq 'no-terminal-event') '事件流不存在時應為 no-terminal-event'
    }
}

function Invoke-LedgerUnit {
    Invoke-Case 'Ledger:檔案不存在時建立檔頭與表頭並追加一列 14 欄' {
        $path = Join-Path (Join-Path $script:fixtureRoot 'ledger-new\cost-line') 'cost-ledger.md'
        $status = Add-DispatchCostLedgerRow -LedgerPath $path -RunId 'run-1' -Row (New-TestLedgerRow -RunId 'run-1')
        Assert-Case ($status -ceq 'recorded') ('status 應為 recorded，實際 ' + $status)
        $text = [IO.File]::ReadAllText($path)
        Assert-Case ($text.StartsWith('# cost-line 成本紀錄')) '首行應為成本紀錄標題'
        Assert-Case ($text.Contains('<!-- cost-ledger.v2 -->')) '應含 v2 標記'
        $bytes = [IO.File]::ReadAllBytes($path)
        Assert-Case (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) '不得寫入 BOM'
        $rows = Get-TestLedgerRows -Path $path
        Assert-Case ($rows.Count -eq 1) ('應有 1 列事件，實際 ' + $rows.Count)
        Assert-Case ((Split-TestLedgerRow -Row $rows[0]).Count -eq 14) '事件列應為 14 欄'
        $headerLine = @($text -split '\r?\n' | Where-Object { $_.StartsWith('| 時間（UTC）') })[0]
        Assert-Case ((Split-TestLedgerRow -Row $headerLine).Count -eq 14) '表頭應為 14 欄'
    }
    Invoke-Case 'Ledger:既有無標記的手寫表保留原內容並於檔尾附加 v2 區塊' {
        $path = Join-Path (Join-Path $script:fixtureRoot 'ledger-legacy\cost-line') 'cost-ledger.md'
        $legacy = "# cost-line 成本紀錄`r`n`r`n| 時間 | 成本目標 | dispatchSlug | 階段 | 事件類型 | 耗時 | before | after | 備註 |`r`n| --- | --- | --- | --- | --- | --- | --- | --- | --- |`r`n| 2026-11-01 | cost-line | a | P1 | 預算 | - | - | - | 手寫 |`r`n"
        Write-TestUtf8NoBom -Path $path -Text $legacy
        $status = Add-DispatchCostLedgerRow -LedgerPath $path -RunId 'run-2' -Row (New-TestLedgerRow -RunId 'run-2')
        Assert-Case ($status -ceq 'recorded') 'status 應為 recorded'
        $text = [IO.File]::ReadAllText($path)
        Assert-Case ($text.StartsWith($legacy)) '既有內容必須原樣保留'
        $markerIndex = $text.IndexOf('<!-- cost-ledger.v2 -->')
        Assert-Case ($markerIndex -gt $legacy.Length) 'v2 區塊應位於舊內容之後'
        Assert-Case ($text.Substring($legacy.Length).StartsWith("`r`n<!-- cost-ledger.v2 -->")) '舊內容與 v2 區塊之間應空一行'
        $legacyRows = Get-TestLedgerRows -Path $path
        Assert-Case (@($legacyRows | Where-Object { $_.Contains('| run-2 |') }).Count -eq 1) '應追加一列事件'
    }
    Invoke-Case 'Ledger:已含標記時直接追加且不重複附加表頭' {
        $path = Join-Path (Join-Path $script:fixtureRoot 'ledger-marked\cost-line') 'cost-ledger.md'
        $null = Add-DispatchCostLedgerRow -LedgerPath $path -RunId 'run-a' -Row (New-TestLedgerRow -RunId 'run-a')
        $null = Add-DispatchCostLedgerRow -LedgerPath $path -RunId 'run-b' -Row (New-TestLedgerRow -RunId 'run-b')
        $text = [IO.File]::ReadAllText($path)
        Assert-Case (([regex]::Matches($text, [regex]::Escape('<!-- cost-ledger.v2 -->'))).Count -eq 1) '標記只應出現一次'
        Assert-Case ((Get-TestLedgerRows -Path $path).Count -eq 2) '應有 2 列事件'
    }
    Invoke-Case 'Ledger:同 runId 第二次追加回傳 skipped-existing 且檔案不變；手寫列不影響去重' {
        $path = Join-Path (Join-Path $script:fixtureRoot 'ledger-dedupe\cost-line') 'cost-ledger.md'
        $null = Add-DispatchCostLedgerRow -LedgerPath $path -RunId 'run-d' -Row (New-TestLedgerRow -RunId 'run-d')
        $before = [IO.File]::ReadAllBytes($path)
        $status = Add-DispatchCostLedgerRow -LedgerPath $path -RunId 'run-d' -Row (New-TestLedgerRow -RunId 'run-d')
        Assert-Case ($status -ceq 'skipped-existing') ('status 應為 skipped-existing，實際 ' + $status)
        $after = [IO.File]::ReadAllBytes($path)
        Assert-Case ($before.Length -eq $after.Length -and [Convert]::ToBase64String($before) -ceq [Convert]::ToBase64String($after)) '檔案不得變更'
        $manualRow = @('2026-11-10T00:00:00Z', '事件（手寫）', 'cost-line', 'x', 'claude-abcd1234', 'cost-probe-c1', '1', 'fix', '首次', '-', '1000', '-', '-', 'source=claude-subagent;model=sonnet')
        $null = Add-DispatchCostLedgerRow -LedgerPath $path -RunId 'claude-abcd1234' -Row $manualRow
        $statusManual = Add-DispatchCostLedgerRow -LedgerPath $path -RunId 'claude-abcd1234' -Row (New-TestLedgerRow -RunId 'claude-abcd1234')
        Assert-Case ($statusManual -ceq 'recorded') '去重只認列類型為事件的列，手寫列同 runId 不阻擋腳本事件列'
    }
    Invoke-Case 'Ledger:儲存格內的 | 被跳脫、換行以空白取代' {
        $path = Join-Path (Join-Path $script:fixtureRoot 'ledger-escape\cost-line') 'cost-ledger.md'
        $row = New-TestLedgerRow -RunId 'run-e' -Note ("a|b`nc`r`nd")
        $null = Add-DispatchCostLedgerRow -LedgerPath $path -RunId 'run-e' -Row $row
        $text = [IO.File]::ReadAllText($path)
        Assert-Case ($text.Contains('a\|b c d |')) ('備註應為 a\|b c d，實際內容：' + $text)
        Assert-Case ((Split-TestLedgerRow -Row (Get-TestLedgerRows -Path $path)[0]).Count -eq 14) '跳脫後仍為 14 欄'
    }
    Invoke-Case 'Ledger:沿用檔案既有換行' {
        $crlfPath = Join-Path (Join-Path $script:fixtureRoot 'ledger-crlf\cost-line') 'cost-ledger.md'
        Write-TestUtf8NoBom -Path $crlfPath -Text "# cost-line 成本紀錄`r`n`r`n<!-- cost-ledger.v2 -->`r`n| 時間（UTC） | 列類型 | 成本目標 | dispatchSlug | runId | cycle_id | cycle_round | cycle_role | 事件類型 | 耗時（秒） | input | cached_input | output | 備註 |`r`n| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |`r`n"
        $null = Add-DispatchCostLedgerRow -LedgerPath $crlfPath -RunId 'run-c' -Row (New-TestLedgerRow -RunId 'run-c')
        $crlfText = [IO.File]::ReadAllText($crlfPath)
        Assert-Case (-not [regex]::IsMatch($crlfText, '(?<!\r)\n')) 'CRLF 檔案不得出現單獨的 LF'
        $lfPath = Join-Path (Join-Path $script:fixtureRoot 'ledger-lf\cost-line') 'cost-ledger.md'
        Write-TestUtf8NoBom -Path $lfPath -Text "# cost-line 成本紀錄`n`n<!-- cost-ledger.v2 -->`n| 時間（UTC） | 列類型 | 成本目標 | dispatchSlug | runId | cycle_id | cycle_round | cycle_role | 事件類型 | 耗時（秒） | input | cached_input | output | 備註 |`n| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |`n"
        $null = Add-DispatchCostLedgerRow -LedgerPath $lfPath -RunId 'run-l' -Row (New-TestLedgerRow -RunId 'run-l')
        Assert-Case (-not ([IO.File]::ReadAllText($lfPath)).Contains("`r")) 'LF 檔案不得出現 CR'
    }
    Invoke-Case 'Ledger:欄數不是 14 時拒絕' {
        $path = Join-Path (Join-Path $script:fixtureRoot 'ledger-bad\cost-line') 'cost-ledger.md'
        $thrown = $false
        try { Add-DispatchCostLedgerRow -LedgerPath $path -RunId 'run-x' -Row @('a', 'b') | Out-Null } catch { $thrown = $true }
        Assert-Case $thrown '欄數不足應拋出例外'
        Assert-Case (-not (Test-Path -LiteralPath $path)) '拒絕時不得建立檔案'
    }
}

function New-TestRunRecord {
    param([string]$RunId, [AllowNull()][string]$RequestedThreadId, [AllowNull()][string]$CycleId, [AllowNull()][object]$CycleRound, [AllowNull()][string]$CycleRole)
    return [pscustomobject]@{
        schema              = 'ai-sessions.dispatch-run.v1'
        run_id              = $RunId
        dispatch_slug       = 'cost-probe'
        line_slug           = 'cost-line'
        requested_thread_id = $RequestedThreadId
        started_at_utc      = [datetime]::UtcNow.AddSeconds(-30).ToString('o')
        cycle_id            = $CycleId
        cycle_round         = $CycleRound
        cycle_role          = $CycleRole
    }
}

function Invoke-HookUnit {
    $completedEvents = ConvertTo-TestEvent -Json @(
        '{"type":"thread.started","thread_id":"00000000-0000-0000-0000-000000000001"}',
        '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10}}')
    $okResult = [ordered]@{ operation = 'Inspect'; success = $true; status = 'completed'; dispatchStatus = 'completed'; processExitCode = 0 }

    Invoke-Case 'Hook:首次與續行兩個 RunRecord 產生對應事件類型與欄位' {
        $sourceRoot = Join-Path $script:fixtureRoot 'hook-main'
        $first = New-TestRunRecord -RunId 'run-first' -RequestedThreadId $null -CycleId 'cost-probe-c1' -CycleRound 1 -CycleRole 'review'
        $second = New-TestRunRecord -RunId 'run-second' -RequestedThreadId '00000000-0000-0000-0000-000000000009' -CycleId 'cost-probe-c1' -CycleRound 2 -CycleRole 'review'
        $outcomeFirst = Invoke-DispatchCostRecord -Run $first -Result $okResult -Event $completedEvents -SourceRoot $sourceRoot -DispatchBound $true -TaskType 'scan'
        Assert-Case ($outcomeFirst.status -ceq 'recorded') ('首次應為 recorded，實際 ' + $outcomeFirst.status + ' / ' + $outcomeFirst.error_code)
        $outcomeSecond = Invoke-DispatchCostRecord -Run ([pscustomobject]@{ Record = $second; Path = 'x' }) -Result $okResult -Event $completedEvents -SourceRoot $sourceRoot -DispatchBound $true -TaskType 'scan'
        Assert-Case ($outcomeSecond.status -ceq 'recorded') ('續行應為 recorded，實際 ' + $outcomeSecond.status)
        $ledgerPath = Join-Path $sourceRoot '.local\ai-sessions\report\cost-line\cost-ledger.md'
        $rows = Get-TestLedgerRows -Path $ledgerPath
        Assert-Case ($rows.Count -eq 2) ('應有 2 列，實際 ' + $rows.Count)
        $firstCells = Split-TestLedgerRow -Row ($rows | Where-Object { $_.Contains('| run-first |') } | Select-Object -First 1)
        Assert-Case ($firstCells[1] -ceq '事件' -and $firstCells[2] -ceq 'cost-line' -and $firstCells[3] -ceq 'cost-probe' -and $firstCells[4] -ceq 'run-first') '首次列的列類型、成本目標、dispatchSlug、runId 不符'
        Assert-Case ($firstCells[5] -ceq 'cost-probe-c1' -and $firstCells[6] -ceq '1' -and $firstCells[7] -ceq 'review') '首次列的 cycle 欄位不符'
        Assert-Case ($firstCells[8] -ceq '首次') '首次列事件類型應為首次'
        Assert-Case ($firstCells[10] -ceq '100' -and $firstCells[11] -ceq '40' -and $firstCells[12] -ceq '10') 'usage 三欄不符'
        Assert-Case ($firstCells[13].Contains('exit=0') -and $firstCells[13].Contains('result=completed') -and $firstCells[13].Contains('task=scan') -and $firstCells[13].Contains('usage=recorded')) ('備註不符：' + $firstCells[13])
        Assert-Case ([int]$firstCells[9] -ge 29 -and [int]$firstCells[9] -lt 600) ('耗時應為約 30 秒，實際 ' + $firstCells[9])
        $secondCells = Split-TestLedgerRow -Row ($rows | Where-Object { $_.Contains('| run-second |') } | Select-Object -First 1)
        Assert-Case ($secondCells[8] -ceq '續行' -and $secondCells[6] -ceq '2') '續行列的事件類型或 cycle_round 不符'
        Assert-Case ([DateTime]::ParseExact($firstCells[0], 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal) -gt [DateTime]::UtcNow.AddMinutes(-5)) '時間欄應為寫入當下的 UTC'
    }
    $cumulativeLine = { param([long]$InputTokens, [long]$CachedTokens, [long]$OutputTokens) '{"type":"turn.completed","usage":{"input_tokens":' + $InputTokens + ',"cached_input_tokens":' + $CachedTokens + ',"output_tokens":' + $OutputTokens + ',"reasoning_output_tokens":0}}' }
    $newContinuation = {
        param([string]$SourceRoot, [string]$RunId, [string]$AnchorField, [string]$AnchorId)
        $record = New-TestRunRecord -RunId $RunId -RequestedThreadId '00000000-0000-0000-0000-000000000009' -CycleId 'cost-probe-c1' -CycleRound 2 -CycleRole 'fix'
        $record | Add-Member -MemberType NoteProperty -Name $AnchorField -Value $AnchorId
        return $record
    }
    $writeAnchorRecord = {
        param([string]$SourceRoot, [string]$AnchorId, [string]$EventStreamPath, [string]$ExecutionRoot)
        $runsDirectory = Join-Path $SourceRoot '.local\ai-sessions\history\cost-line\runs\cost-probe'
        $anchorDocument = [ordered]@{ run_id = $AnchorId; event_stream_path = $EventStreamPath; execution_root = $ExecutionRoot }
        Write-TestUtf8NoBom -Path (Join-Path $runsDirectory ($AnchorId + '.json')) -Text ($anchorDocument | ConvertTo-Json -Compress)
    }
    $runCumulativeEvents = ConvertTo-TestEvent -Json @(& $cumulativeLine 2500 2300 120)

    Invoke-Case 'Hook:續行 run 以錨點 RunRecord 的事件流計算增量，usage_basis 為 delta；首次為 cumulative' {
        $sourceRoot = Join-Path $script:fixtureRoot 'hook-delta'
        $anchorId = '11111111-1111-1111-1111-111111111111'
        $anchorStream = Join-Path $sourceRoot 'streams\anchor.jsonl'
        Write-TestUtf8NoBom -Path $anchorStream -Text ((& $cumulativeLine 1000 900 50) + "`n")
        & $writeAnchorRecord $sourceRoot $anchorId $anchorStream (Join-Path $sourceRoot 'wt')
        $record = & $newContinuation $sourceRoot 'run-delta' 'previous_run_id' $anchorId
        $outcome = Invoke-DispatchCostRecord -Run $record -Result $okResult -Event $runCumulativeEvents -SourceRoot $sourceRoot -DispatchBound $true
        Assert-Case ($outcome.status -ceq 'recorded') ('應為 recorded，實際 ' + $outcome.status + ' / ' + $outcome.error_code)
        $cells = Split-TestLedgerRow -Row (Get-TestLedgerRows -Path (Join-Path $sourceRoot '.local\ai-sessions\report\cost-line\cost-ledger.md'))[0]
        Assert-Case ($cells[8] -ceq '續行') '事件類型應為續行'
        Assert-Case ($cells[10] -ceq '1500' -and $cells[11] -ceq '1400' -and $cells[12] -ceq '70') ('增量不符：' + ($cells[10..12] -join '/'))
        Assert-Case ($cells[13].Contains('usage_basis=delta')) ('備註應含 usage_basis=delta：' + $cells[13])
        $firstSource = Join-Path $script:fixtureRoot 'hook-first-basis'
        $null = Invoke-DispatchCostRecord -Run (New-TestRunRecord -RunId 'run-first-basis' -RequestedThreadId $null -CycleId 'a-c1' -CycleRound 1 -CycleRole 'review') -Result $okResult -Event $runCumulativeEvents -SourceRoot $firstSource -DispatchBound $true
        $firstCells = Split-TestLedgerRow -Row (Get-TestLedgerRows -Path (Join-Path $firstSource '.local\ai-sessions\report\cost-line\cost-ledger.md'))[0]
        Assert-Case ($firstCells[10] -ceq '2500' -and $firstCells[13].Contains('usage_basis=cumulative') -and -not $firstCells[13].Contains('cumulative-no-anchor')) ('首次應寫累計值且 basis 為 cumulative：' + $firstCells[13])
    }
    Invoke-Case 'Hook:錨點事件流已隨 worktree 移走時，從 source_root 下的保存副本讀取（resume_anchor_run_id）' {
        $sourceRoot = Join-Path $script:fixtureRoot 'hook-archived'
        $executionRoot = Join-Path $script:fixtureRoot 'hook-archived-wt\wt'
        $relativeStream = '.local\ai-sessions\history\cost-line\codex-exec-anchor.jsonl'
        $anchorId = '22222222-2222-2222-2222-222222222222'
        Write-TestUtf8NoBom -Path (Join-Path $sourceRoot $relativeStream) -Text ((& $cumulativeLine 1000 900 50) + "`n")
        & $writeAnchorRecord $sourceRoot $anchorId (Join-Path $executionRoot $relativeStream) $executionRoot
        Assert-Case (-not (Test-Path -LiteralPath (Join-Path $executionRoot $relativeStream))) '前置：execution root 下的事件流不應存在'
        $record = & $newContinuation $sourceRoot 'run-archived' 'resume_anchor_run_id' $anchorId
        $outcome = Invoke-DispatchCostRecord -Run $record -Result $okResult -Event $runCumulativeEvents -SourceRoot $sourceRoot -DispatchBound $true
        Assert-Case ($outcome.status -ceq 'recorded') ('應為 recorded，實際 ' + $outcome.status)
        $cells = Split-TestLedgerRow -Row (Get-TestLedgerRows -Path (Join-Path $sourceRoot '.local\ai-sessions\report\cost-line\cost-ledger.md'))[0]
        Assert-Case ($cells[10] -ceq '1500' -and $cells[11] -ceq '1400' -and $cells[12] -ceq '70' -and $cells[13].Contains('usage_basis=delta')) ('保存副本的增量不符：' + ($cells[10..13] -join '/'))
    }
    Invoke-Case 'Hook:錨點缺失、事件流找不到或差值為負時寫累計值，usage_basis 為 cumulative-no-anchor' {
        $sourceRoot = Join-Path $script:fixtureRoot 'hook-noanchor'
        $ledgerPath = Join-Path $sourceRoot '.local\ai-sessions\report\cost-line\cost-ledger.md'
        $missingRecord = & $newContinuation $sourceRoot 'run-missing' 'previous_run_id' '33333333-3333-3333-3333-333333333333'
        $outcomeMissing = Invoke-DispatchCostRecord -Run $missingRecord -Result $okResult -Event $runCumulativeEvents -SourceRoot $sourceRoot -DispatchBound $true
        Assert-Case ($outcomeMissing.status -ceq 'recorded') '錨點 RunRecord 不存在時掛勾不得失敗'
        $noPointerRecord = & $newContinuation $sourceRoot 'run-nopointer' 'attempt_parent_run_id' '44444444-4444-4444-4444-444444444444'
        $null = Invoke-DispatchCostRecord -Run $noPointerRecord -Result $okResult -Event $runCumulativeEvents -SourceRoot $sourceRoot -DispatchBound $true
        $lostStreamId = '55555555-5555-5555-5555-555555555555'
        & $writeAnchorRecord $sourceRoot $lostStreamId (Join-Path $sourceRoot 'streams\nowhere.jsonl') (Join-Path $script:fixtureRoot 'elsewhere')
        $null = Invoke-DispatchCostRecord -Run (& $newContinuation $sourceRoot 'run-lost' 'previous_run_id' $lostStreamId) -Result $okResult -Event $runCumulativeEvents -SourceRoot $sourceRoot -DispatchBound $true
        $negativeId = '66666666-6666-6666-6666-666666666666'
        $negativeStream = Join-Path $sourceRoot 'streams\negative.jsonl'
        Write-TestUtf8NoBom -Path $negativeStream -Text ((& $cumulativeLine 9000 100 10) + "`n")
        & $writeAnchorRecord $sourceRoot $negativeId $negativeStream (Join-Path $sourceRoot 'wt')
        $null = Invoke-DispatchCostRecord -Run (& $newContinuation $sourceRoot 'run-negative' 'previous_run_id' $negativeId) -Result $okResult -Event $runCumulativeEvents -SourceRoot $sourceRoot -DispatchBound $true
        $rows = Get-TestLedgerRows -Path $ledgerPath
        Assert-Case ($rows.Count -eq 4) ('應有 4 列，實際 ' + $rows.Count)
        foreach ($row in $rows) {
            $cells = Split-TestLedgerRow -Row $row
            Assert-Case ($cells[10] -ceq '2500' -and $cells[11] -ceq '2300' -and $cells[12] -ceq '120') ($cells[4] + ' 應寫本 run 累計值：' + ($cells[10..12] -join '/'))
            Assert-Case ($cells[13].Contains('usage_basis=cumulative-no-anchor')) ($cells[4] + ' 備註應含 cumulative-no-anchor：' + $cells[13])
        }
    }
    Invoke-Case 'Hook:以 RunRecord 綁定（Resolve 結果物件）的 Inspect 會寫列，且 Invoke-Inspect 的綁定判定含 RunRecordPath' {
        $sourceRoot = Join-Path $script:fixtureRoot 'hook-runrecord-bound'
        $record = New-TestRunRecord -RunId 'run-bound' -RequestedThreadId $null -CycleId 'a-c1' -CycleRound 1 -CycleRole 'review'
        $outcome = Invoke-DispatchCostRecord -Run ([pscustomobject]@{ Record = $record; Path = (Join-Path $sourceRoot '.local\ai-sessions\history\cost-line\runs\cost-probe\run-bound.json') }) -Result $okResult -Event $completedEvents -SourceRoot $sourceRoot -DispatchBound $true
        Assert-Case ($outcome.status -ceq 'recorded') ('應為 recorded，實際 ' + $outcome.status)
        $inspectText = [IO.File]::ReadAllText((Join-Path (Join-Path $scriptsRoot 'dispatch') 'inspect-lifecycle.ps1'))
        Assert-Case ($inspectText.Contains('$costDispatchBound = ($null -ne $dispatchInspectBinding) -or (-not [string]::IsNullOrWhiteSpace($RunRecordPath) -and $null -ne $inspectRun)')) 'Invoke-Inspect 的 -DispatchBound 應含 dispatch binding 或 RunRecordPath 解析成功兩種條件'
        Assert-Case ($inspectText.Contains('-DispatchBound $costDispatchBound')) 'Invoke-DispatchCostRecord 應以 $costDispatchBound 呼叫'
    }
    Invoke-Case 'Hook:循環欄位為 null、事件流沒有 turn.completed 時對應儲存格寫 -' {
        $sourceRoot = Join-Path $script:fixtureRoot 'hook-null'
        $record = New-TestRunRecord -RunId 'run-null' -RequestedThreadId $null -CycleId $null -CycleRound $null -CycleRole $null
        $failedResult = [ordered]@{ operation = 'Inspect'; success = $false; status = 'failed'; dispatchStatus = 'failed'; processExitCode = 1 }
        $outcome = Invoke-DispatchCostRecord -Run $record -Result $failedResult -Event (ConvertTo-TestEvent -Json @('{"type":"turn.started"}')) -SourceRoot $sourceRoot -DispatchBound $true
        Assert-Case ($outcome.status -ceq 'recorded') ('應為 recorded，實際 ' + $outcome.status)
        $rows = Get-TestLedgerRows -Path (Join-Path $sourceRoot '.local\ai-sessions\report\cost-line\cost-ledger.md')
        $cells = Split-TestLedgerRow -Row $rows[0]
        Assert-Case ($cells[5] -ceq '-' -and $cells[6] -ceq '-' -and $cells[7] -ceq '-') 'cycle 三欄應為 -'
        Assert-Case ($cells[10] -ceq '-' -and $cells[11] -ceq '-' -and $cells[12] -ceq '-') 'token 三欄應為 -'
        Assert-Case ($cells[13].Contains('result=failed') -and $cells[13].Contains('exit=1') -and $cells[13].Contains('usage=no-terminal-event') -and $cells[13].Contains('task=-')) ('備註不符：' + $cells[13])
    }
    Invoke-Case 'Hook:同一 RunRecord 重複掛勾回傳 skipped-existing' {
        $sourceRoot = Join-Path $script:fixtureRoot 'hook-dup'
        $record = New-TestRunRecord -RunId 'run-dup' -RequestedThreadId $null -CycleId 'a-c1' -CycleRound 1 -CycleRole 'review'
        $null = Invoke-DispatchCostRecord -Run $record -Result $okResult -Event $completedEvents -SourceRoot $sourceRoot -DispatchBound $true
        $again = Invoke-DispatchCostRecord -Run $record -Result $okResult -Event $completedEvents -SourceRoot $sourceRoot -DispatchBound $true
        Assert-Case ($again.status -ceq 'skipped-existing') ('應為 skipped-existing，實際 ' + $again.status)
        Assert-Case ((Get-TestLedgerRows -Path (Join-Path $sourceRoot '.local\ai-sessions\report\cost-line\cost-ledger.md')).Count -eq 1) '只應有 1 列'
    }
    Invoke-Case 'Hook:-DispatchBound 為 false 時回傳 skipped-not-dispatch 且不建立檔案' {
        $sourceRoot = Join-Path $script:fixtureRoot 'hook-unbound'
        $record = New-TestRunRecord -RunId 'run-unbound' -RequestedThreadId $null -CycleId 'a-c1' -CycleRound 1 -CycleRole 'review'
        $outcome = Invoke-DispatchCostRecord -Run $record -Result $okResult -Event $completedEvents -SourceRoot $sourceRoot -DispatchBound $false
        Assert-Case ($outcome.status -ceq 'skipped-not-dispatch') ('應為 skipped-not-dispatch，實際 ' + $outcome.status)
        Assert-Case (-not (Test-Path -LiteralPath (Join-Path $sourceRoot '.local'))) '不得建立任何檔案或目錄'
    }
    Invoke-Case 'Hook:ledger 路徑被同名目錄佔位時回傳 failed 且不拋出例外' {
        $sourceRoot = Join-Path $script:fixtureRoot 'hook-blocked'
        $blocked = Join-Path $sourceRoot '.local\ai-sessions\report\cost-line\cost-ledger.md'
        $null = [IO.Directory]::CreateDirectory($blocked)
        $record = New-TestRunRecord -RunId 'run-blocked' -RequestedThreadId $null -CycleId 'a-c1' -CycleRound 1 -CycleRole 'review'
        $outcome = $null
        $thrown = $false
        try { $outcome = Invoke-DispatchCostRecord -Run $record -Result $okResult -Event $completedEvents -SourceRoot $sourceRoot -DispatchBound $true } catch { $thrown = $true }
        Assert-Case (-not $thrown) '掛勾不得拋出例外'
        Assert-Case ($outcome.status -ceq 'failed' -and -not [string]::IsNullOrWhiteSpace([string]$outcome.error_code)) '應回傳 failed 與 error_code'
    }
    Invoke-Case 'Hook:RunRecord 缺少 line_slug 時回傳 failed' {
        $sourceRoot = Join-Path $script:fixtureRoot 'hook-invalid'
        $outcome = Invoke-DispatchCostRecord -Run ([pscustomobject]@{ run_id = 'x' }) -Result $okResult -Event $completedEvents -SourceRoot $sourceRoot -DispatchBound $true
        Assert-Case ($outcome.status -ceq 'failed' -and $outcome.error_code -ceq 'CostRecordInvalidRun') ('應為 CostRecordInvalidRun，實際 ' + $outcome.error_code)
        $null = Invoke-DispatchCostRecord -Run ([pscustomobject]@{ run_id = 'x'; dispatch_slug = 'd'; line_slug = '..\evil' }) -Result $okResult -Event $completedEvents -SourceRoot $sourceRoot -DispatchBound $true
        Assert-Case (-not (Test-Path -LiteralPath $sourceRoot)) 'line_slug 不合法時不得建立任何路徑'
    }
    Invoke-Case 'Hook:Inspect 掛勾的靜態結構（呼叫存在且函式內含 try 與 catch）' {
        $inspectText = [IO.File]::ReadAllText((Join-Path (Join-Path $scriptsRoot 'dispatch') 'inspect-lifecycle.ps1'))
        Assert-Case (([regex]::Matches($inspectText, 'Invoke-DispatchCostRecord')).Count -ge 2) 'Invoke-DispatchCostRecord 應至少出現定義與呼叫'
        Assert-Case ($inspectText.Contains('$result.costRecord = Invoke-DispatchCostRecord')) 'Invoke-Inspect 應把掛勾結果存入 $result.costRecord'
        $definitionMatch = [regex]::Match($inspectText, '(?s)function Invoke-DispatchCostRecord \{.*?(?=\r?\nfunction )')
        Assert-Case $definitionMatch.Success '應找得到 Invoke-DispatchCostRecord 的定義'
        Assert-Case ($definitionMatch.Value.Contains('try {') -and $definitionMatch.Value.Contains('catch {')) '定義內應含 try 與 catch'
        $callIndex = $inspectText.IndexOf('$result.costRecord = Invoke-DispatchCostRecord')
        $inspectStart = $inspectText.IndexOf('function Invoke-Inspect {')
        Assert-Case ($callIndex -gt $inspectStart) '呼叫應位於 Invoke-Inspect 內'
        $returnIndex = $inspectText.IndexOf('return Protect-DispatchInspectResult -Result $result -SecretExposure $secretExposure', $callIndex)
        Assert-Case ($returnIndex -gt $callIndex) '呼叫應位於最後的 return Protect-DispatchInspectResult 之前'
    }
}

function New-TestComparisonRow {
    param([string]$Kind, [string]$RunId, [string]$CycleId, [string]$Round, [string]$Role, [string]$InputTokens)
    $cells = @('2026-11-10T00:00:00Z', $Kind, 'cost-line', ('cmp-' + $RunId), $RunId, $CycleId, $Round, $Role, '首次', '5', $InputTokens, '-', '-', 'note')
    return ('| ' + ($cells -join ' | ') + ' |')
}

function Invoke-ComparisonUnit {
    $documentPath = Join-Path $repoRoot 'skills\session-artifacts\references\cost-comparison.md'
    $snippet = $null
    $extractError = $null
    try {
        $documentText = [IO.File]::ReadAllText($documentPath, (New-Object System.Text.UTF8Encoding($false)))
        $markerIndex = $documentText.IndexOf('<!-- new-data-snippet -->')
        if ($markerIndex -lt 0) { throw '找不到 <!-- new-data-snippet --> 標記' }
        $fenceMatch = [regex]::Match($documentText.Substring($markerIndex), '(?s)```powershell\r?\n(.*?)\r?\n```')
        if (-not $fenceMatch.Success) { throw '標記之後找不到 powershell 程式區塊' }
        $snippet = $fenceMatch.Groups[1].Value
    }
    catch { $extractError = $_.Exception.Message }

    Invoke-Case 'Comparison:自文件標記之後取得 powershell 程式區塊且含 -LedgerRoot 參數' {
        Assert-Case ($null -eq $extractError) ('取得程式區塊失敗：' + $extractError)
        Assert-Case ($snippet.StartsWith('param([Parameter(Mandatory)][string]$LedgerRoot)')) '程式區塊應以 LedgerRoot 的 param 開頭'
    }

    $comparisonRoot = Join-Path $script:fixtureRoot 'comparison'
    $ledgerPath = Join-Path $comparisonRoot 'report\cost-line\cost-ledger.md'
    $header = '| 時間（UTC） | 列類型 | 成本目標 | dispatchSlug | runId | cycle_id | cycle_round | cycle_role | 事件類型 | 耗時（秒） | input | cached_input | output | 備註 |'
    $separator = '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |'
    $legacyRow = New-TestComparisonRow -Kind '事件' -RunId 'run-legacy' -CycleId 'cycle-legacy' -Round '1' -Role 'review' -InputTokens '99999'
    $ledgerLines = @(
        '# cost-line 成本紀錄', '',
        $header, $separator, $legacyRow, '',
        '<!-- cost-ledger.v2 -->', $header, $separator,
        (New-TestComparisonRow -Kind '事件' -RunId 'run-01' -CycleId 'cycle-a' -Round '1' -Role 'review' -InputTokens '1000'),
        (New-TestComparisonRow -Kind '事件' -RunId 'run-02' -CycleId 'cycle-a' -Round '2' -Role 'review' -InputTokens '500'),
        (New-TestComparisonRow -Kind '事件' -RunId 'run-02' -CycleId 'cycle-a' -Round '2' -Role 'review' -InputTokens '500'),
        (New-TestComparisonRow -Kind '事件' -RunId 'run-03' -CycleId 'cycle-a' -Round '3' -Role 'review' -InputTokens '300'),
        (New-TestComparisonRow -Kind '事件' -RunId 'run-04' -CycleId 'cycle-b' -Round '1' -Role 'review' -InputTokens '800'),
        (New-TestComparisonRow -Kind '事件' -RunId 'run-05' -CycleId 'cycle-b' -Round '2' -Role 'review' -InputTokens '-'),
        (New-TestComparisonRow -Kind '事件（手寫）' -RunId 'run-06' -CycleId 'cycle-c' -Round '1' -Role 'review' -InputTokens '700'),
        (New-TestComparisonRow -Kind '事件' -RunId 'run-07' -CycleId '-' -Round '-' -Role '-' -InputTokens '200'),
        (New-TestComparisonRow -Kind '事件（手寫）' -RunId 'claude-abcd1234-1' -CycleId 'cycle-f' -Round '1' -Role 'fix' -InputTokens '5000'),
        (New-TestComparisonRow -Kind '事件（手寫）' -RunId 'claude-abcd1234-2' -CycleId 'cycle-f' -Round '2' -Role 'fix' -InputTokens '3000'),
        (New-TestComparisonRow -Kind '事件（手寫）' -RunId 'claude-abcd1234-3' -CycleId 'cycle-f' -Round '2' -Role 'fix' -InputTokens '4000'),
        '| 2026-11-10T00:00:00Z | 預算 | cost-line | - | - | - | - | - | - | - | - | - | - | 預算列不參與計算 |'
    )
    Write-TestUtf8NoBom -Path $ledgerPath -Text (($ledgerLines -join [Environment]::NewLine) + [Environment]::NewLine)

    $output = @()
    $runError = $null
    try {
        $snippetPath = Join-Path $comparisonRoot 'comparison-snippet.ps1'
        [IO.File]::WriteAllText($snippetPath, $snippet, (New-Object System.Text.UTF8Encoding($true)))
        $output = @(& { Set-StrictMode -Off; & $snippetPath -LedgerRoot $comparisonRoot } | ForEach-Object { [string]$_ })
    }
    catch { $runError = $_.Exception.Message }

    Invoke-Case 'Comparison:程式區塊對 fixture ledger 執行成功' {
        Assert-Case ($null -eq $runError) ('執行失敗：' + $runError)
        Assert-Case ($output.Count -ge 6) ('輸出行數不足：' + ($output -join ' / '))
    }
    Invoke-Case 'Comparison:M1 與 M1u 以全部輪次與有 usage 輪次計算，舊版手寫表與重複 runId 不影響' {
        Assert-Case ($output -contains 'M1 median = 2 over 3,2,1') ('M1 不符：' + ($output -join ' / '))
        Assert-Case ($output -contains 'M1u median = 1 over 3,1,1') ('M1u 不符：' + ($output -join ' / '))
    }
    Invoke-Case 'Comparison:M2 合併與各循環比例只計有 usage 的 Codex 事件列' {
        Assert-Case ($output -contains 'M2 combined = 30.77%') ('M2 合併不符：' + ($output -join ' / '))
        Assert-Case ($output -contains 'M2 cost-line, cycle-a = 44.44%') ('M2 循環 A 不符：' + ($output -join ' / '))
        Assert-Case ($output -contains 'M2 cost-line, cycle-b = 0%') ('M2 循環 B 不符：' + ($output -join ' / '))
        Assert-Case (@($output | Where-Object { $_.StartsWith('M2 cost-line, cycle-c') -or $_.StartsWith('M2 cost-line, cycle-f') }).Count -eq 0) '手寫列不得出現在 M2'
    }
    Invoke-Case 'Comparison:M3 分母含未標記事件列，分子為有 usage 者' {
        Assert-Case ($output -contains 'M3 = 5/6（未標記 1 列）') ('M3 不符：' + ($output -join ' / '))
    }
    Invoke-Case 'Comparison:M4 取實作循環最大輪次，Claude token 合計只含手寫列且不併入 M2' {
        Assert-Case ($output -contains 'M4 median = 2 over 2') ('M4 不符：' + ($output -join ' / '))
        # 同一 subagent 三次通知的總數依序為 5000、8000、12000，三列增量 5000、3000、4000 的和等於最後一次總數；另含 cycle-c 手寫列 700。
        Assert-Case ($output -contains 'Claude subagent token 合計 = 12700（不併入 M2）') ('Claude token 合計不符：' + ($output -join ' / '))
    }
}

$unitHandlers = [ordered]@{
    Identity   = { Invoke-IdentityUnit }
    Usage      = { Invoke-UsageUnit }
    Ledger     = { Invoke-LedgerUnit }
    Hook       = { Invoke-HookUnit }
    Comparison = { Invoke-ComparisonUnit }
}
$selectedUnits = if ($Unit -eq 'All') { @($unitHandlers.Keys) } else { @($Unit) }
foreach ($selectedUnit in $selectedUnits) {
    if (-not $unitHandlers.Contains($selectedUnit)) {
        $script:cases.Add([pscustomobject]@{ name = $selectedUnit + ':尚未實作'; result = 'FAIL'; error = '單元尚未實作' })
        continue
    }
    & $unitHandlers[$selectedUnit]
}

foreach ($case in $script:cases) {
    if ($case.result -eq 'PASS') {
        Write-Host ('PASS ' + $case.name)
    }
    else {
        Write-Host ('FAIL ' + $case.name + ' => ' + $case.error)
    }
}
$failed = @($script:cases | Where-Object { $_.result -ne 'PASS' })
Write-Host ('合計 {0} 案，失敗 {1} 案。' -f $script:cases.Count, $failed.Count)
try { Remove-Item -LiteralPath $script:fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
if ($failed.Count -gt 0) { exit 1 }
exit 0
