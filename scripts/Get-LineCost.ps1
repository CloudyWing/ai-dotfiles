#Requires -Version 7.0

<#
.SYNOPSIS
唯讀彙整一條線的成本，輸出 JSON。

.DESCRIPTION
Codex 端取自兩個既有來源，不推算：
1. report\<lineSlug>\runs\*.record.json（Invoke-CodexRun.ps1 的執行紀錄，含 model、結果、耗時與 usage）。
2. report\<lineSlug>\cost-ledger.md 的 `事件` 列（含舊入口 Invoke-CodexDispatch.ps1 的 Inspect 追加列）。
   只採計 runId 不在 1 的紀錄中的列，這些列沒有 model，model 輸出 null。

事件列備註的 usage_basis 為 cumulative-no-anchor 時，該列的 token 是 Codex thread 的累計值，
錨點讀不到而無法換算成增量，因此不計入合計；列仍保留在 runs 中，並在 totals 與 warnings 標示用量不完整。

runs 的每一列有 platform 欄位。Claude 審查者的執行紀錄（Write-ClaudeRunRecord.ps1 寫出，executor_platform 為 claude）同樣列在 codex.runs，
platform 為 claude，沒有 token 用量：該列計入 run_count、結果與耗時，不計入 token 合計，並使 totals.usage_incomplete 為 true、
totals.claude_runs_without_usage 為其數量，且在 warnings 列出 run_id。

Claude 端不輸出推算值。線登記資料與執行紀錄都不含 Claude session id，因此預設為 null 並附原因；
以 -ClaudeSessionId 或 -ClaudeTranscriptPath 指定後，改呼叫 Get-ClaudeSessionUsage.ps1 取得該 session 的用量，
無法取得的數值輸出 null。

沒有可加總的數值時，合計輸出 null，不輸出 0。腳本不寫任何檔案、不呼叫網路。
損毀的紀錄檔與列記入 warnings，不中止彙整。

.PARAMETER WorkRoot
線所在的 work-root。

.PARAMETER LineSlug
線識別。

.PARAMETER ClaudeSessionId
選填。對應此線的 Claude session id，由 Get-ClaudeSessionUsage.ps1 查詢。

.PARAMETER ClaudeTranscriptPath
選填。對應此線的 Claude transcript 路徑。與 -ClaudeSessionId 擇一。

.PARAMETER ProjectsRoot
Claude projects 目錄，只在 -ClaudeSessionId 時使用。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkRoot,
    [Parameter(Mandatory)][string]$LineSlug,
    [string]$ClaudeSessionId,
    [string]$ClaudeTranscriptPath,
    [string]$ProjectsRoot = (Join-Path $env:USERPROFILE '.claude\projects')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function ConvertTo-NullableLong {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [int] -or $Value -is [long]) { return [long]$Value }
    return $null
}

function Get-NullableSum {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Run,
        [Parameter(Mandatory)][string]$Name
    )
    $values = @($Run | Where-Object { $null -ne $_[$Name] } | ForEach-Object { [long]$_[$Name] })
    if ($values.Count -eq 0) { return $null }
    return [long]($values | Measure-Object -Sum).Sum
}

function Read-RecordRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $record = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $runId = Get-PropertyValue $record 'run_id'
    if ([string]::IsNullOrWhiteSpace([string]$runId)) { throw 'run_id 缺少。' }
    $duration = Get-PropertyValue $record 'duration_seconds'
    if ($null -ne $duration -and $duration -isnot [int] -and $duration -isnot [long] -and $duration -isnot [double]) {
        throw 'duration_seconds 不是數值。'
    }
    $usage = Get-PropertyValue $record 'usage'
    return [ordered]@{
        source = 'record'
        platform = $(if ((Get-PropertyValue $record 'executor_platform') -ceq 'claude') { 'claude' } else { 'codex' })
        run_id = [string]$runId
        dispatch_slug = Get-PropertyValue $record 'dispatch_slug'
        task_type = Get-PropertyValue $record 'task_type'
        model = Get-PropertyValue $record 'model'
        account = Get-PropertyValue (Get-PropertyValue $record 'account') 'name'
        cycle_id = Get-PropertyValue $record 'cycle_id'
        cycle_round = $(if ($null -eq (Get-PropertyValue $record 'cycle_round')) { $null } else { [string](Get-PropertyValue $record 'cycle_round') })
        result = Get-PropertyValue $record 'result'
        rejection_kind = Get-PropertyValue $record 'rejection_kind'
        exit_code = Get-PropertyValue $record 'exit_code'
        started_utc = Get-PropertyValue $record 'started_utc'
        ended_utc = Get-PropertyValue $record 'ended_utc'
        duration_seconds = $duration
        usage_status = Get-PropertyValue $usage 'status'
        usage_basis = $null
        input_tokens = ConvertTo-NullableLong (Get-PropertyValue $usage 'input_tokens')
        cached_input_tokens = ConvertTo-NullableLong (Get-PropertyValue $usage 'cached_input_tokens')
        output_tokens = ConvertTo-NullableLong (Get-PropertyValue $usage 'output_tokens')
    }
}

function Read-LedgerRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Warnings
    )
    $runs = New-Object System.Collections.Generic.List[object]
    $inTable = $false
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        if ($line.Contains('<!-- cost-ledger.v2 -->')) { $inTable = $true; continue }
        if (-not $inTable -or -not $line.StartsWith('| ')) { continue }
        $cells = @(($line.Trim().Trim('|') -split '(?<!\\)\|') | ForEach-Object { $_.Trim() })
        if ($cells.Count -ne 14) { $Warnings.Add("cost-ledger.md 有一列不是 14 欄，已略過：$($line.Substring(0, [Math]::Min(80, $line.Length)))"); continue }
        if ($cells[1] -ne '事件') { continue }
        $note = @{}
        foreach ($pair in ($cells[13] -split ';')) {
            $index = $pair.IndexOf('=')
            if ($index -gt 0) { $note[$pair.Substring(0, $index)] = $pair.Substring($index + 1) }
        }
        $number = { param([string]$Cell) if ($Cell -match '^\d+$') { [long]$Cell } else { $null } }
        $duration = if ($cells[9] -match '^\d+(\.\d+)?$') { [double]$cells[9] } else { $null }
        $runs.Add([ordered]@{
            source = 'ledger'
            platform = 'codex'
            run_id = $cells[4]
            dispatch_slug = if ($cells[3] -eq '-') { $null } else { $cells[3] }
            task_type = if ($note.ContainsKey('task')) { $note['task'] } else { $null }
            model = $null
            account = if ($note.ContainsKey('account')) { $note['account'] } else { $null }
            cycle_id = if ($cells[5] -eq '-') { $null } else { $cells[5] }
            cycle_round = if ($cells[6] -eq '-') { $null } else { $cells[6] }
            result = if ($note.ContainsKey('result')) { $note['result'] } else { $null }
            rejection_kind = if ($note.ContainsKey('rejection') -and $note['rejection'] -ne 'none') { $note['rejection'] } else { $null }
            exit_code = if ($note.ContainsKey('exit') -and $note['exit'] -match '^-?\d+$') { [int]$note['exit'] } else { $null }
            started_utc = $null
            ended_utc = $cells[0]
            duration_seconds = $duration
            usage_status = if ($note.ContainsKey('usage')) { $note['usage'] } else { $null }
            usage_basis = if ($note.ContainsKey('usage_basis')) { $note['usage_basis'] } else { $null }
            input_tokens = & $number $cells[10]
            cached_input_tokens = & $number $cells[11]
            output_tokens = & $number $cells[12]
        })
    }
    return , $runs
}

function Get-ClaudeCost {
    [CmdletBinding()]
    param()
    if (-not [string]::IsNullOrWhiteSpace($ClaudeSessionId) -and -not [string]::IsNullOrWhiteSpace($ClaudeTranscriptPath)) {
        throw '-ClaudeSessionId 與 -ClaudeTranscriptPath 只能擇一。'
    }
    if ([string]::IsNullOrWhiteSpace($ClaudeSessionId) -and [string]::IsNullOrWhiteSpace($ClaudeTranscriptPath)) {
        return @{ value = $null; reason = '線登記資料與執行紀錄不含 Claude session id，無法對應；以 -ClaudeSessionId 或 -ClaudeTranscriptPath 指定後才計算。' }
    }
    $usageScript = Join-Path $PSScriptRoot 'Get-ClaudeSessionUsage.ps1'
    $arguments = if ([string]::IsNullOrWhiteSpace($ClaudeSessionId)) { @('-TranscriptPath', $ClaudeTranscriptPath) } else { @('-SessionId', $ClaudeSessionId, '-ProjectsRoot', $ProjectsRoot) }
    $output = @(& pwsh -NoProfile -File $usageScript @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        return @{ value = $null; reason = "Get-ClaudeSessionUsage.ps1 失敗：$($output -join ' ')" }
    }
    $values = @{}
    foreach ($line in $output) { if ("$line" -match '^([^=]+)=(.*)$') { $values[$Matches[1]] = $Matches[2] } }
    $group = {
        param([string]$Prefix)
        $result = [ordered]@{ status = $values["${Prefix}_status"] }
        foreach ($name in @('input_tokens', 'cache_write_tokens', 'cache_read_tokens', 'output_tokens')) {
            $text = $values["${Prefix}_$name"]
            $result[$name] = if ($text -match '^\d+$') { [long]$text } else { $null }
        }
        $result
    }
    return @{
        value = [ordered]@{
            session_id = $values['session_id']
            last_write_time_utc = $values['last_write_time_utc']
            main = & $group 'main'
            subagents = & $group 'subagents'
            total = & $group 'total'
        }
        reason = $null
    }
}

try {
    if ($LineSlug -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw "LineSlug 格式無效：$LineSlug" }
    if (-not (Test-Path -LiteralPath $WorkRoot -PathType Container)) { throw "WorkRoot 不存在：$WorkRoot" }
    $sessions = Join-Path (Join-Path $WorkRoot '.local') 'ai-sessions'
    $lineJson = Join-Path (Join-Path (Join-Path $sessions 'handoff') $LineSlug) 'line.json'
    $reportRoot = Join-Path (Join-Path $sessions 'report') $LineSlug
    if (-not (Test-Path -LiteralPath $lineJson -PathType Leaf) -and -not (Test-Path -LiteralPath $reportRoot -PathType Container)) {
        throw "找不到線 $LineSlug（缺少 handoff 的 line.json 與 report 目錄）。"
    }

    $warnings = New-Object System.Collections.Generic.List[string]
    $byRunId = [ordered]@{}

    $runsDirectory = Join-Path $reportRoot 'runs'
    if (Test-Path -LiteralPath $runsDirectory -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $runsDirectory -File -Filter '*.record.json' | Sort-Object Name)) {
            try {
                $run = Read-RecordRun $file.FullName
                $byRunId[$run.run_id] = $run
            } catch {
                $warnings.Add("執行紀錄無法解析，已略過：$($file.Name)（$($_.Exception.Message)）")
            }
        }
    }

    $ledgerPath = Join-Path $reportRoot 'cost-ledger.md'
    if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
        foreach ($run in (Read-LedgerRun $ledgerPath $warnings)) {
            if (-not $byRunId.Contains($run.run_id)) { $byRunId[$run.run_id] = $run; continue }
            # Codex 的執行紀錄沒有循環欄位，循環標示取自同 runId 的成本事件列；Claude 的紀錄自帶循環欄位，不受影響。
            $existing = $byRunId[$run.run_id]
            if ($null -eq $existing.cycle_id) { $existing.cycle_id = $run.cycle_id; $existing.cycle_round = $run.cycle_round }
        }
    }

    $runs = @($byRunId.Values | Sort-Object { [string]$_.ended_utc })
    # 有 token 值的 run；累計值無法換算增量的列另計，不併入合計。
    $withUsage = @($runs | Where-Object { $null -ne $_.input_tokens -or $null -ne $_.output_tokens })
    $unanchored = @($withUsage | Where-Object { $_.usage_basis -ceq 'cumulative-no-anchor' })
    $countable = @($withUsage | Where-Object { $_.usage_basis -cne 'cumulative-no-anchor' })
    if ($unanchored.Count -gt 0) {
        $warnings.Add("續行 run 的用量是累計值且錨點讀不到，未計入合計：$(@($unanchored | ForEach-Object { $_.run_id }) -join ',')")
    }
    # Claude 審查者的執行紀錄不含 token 用量，列在 runs 中並計入次數與耗時，但 token 合計不含這些列，因此合計不完整。
    $claudeRuns = @($runs | Where-Object { $_.platform -ceq 'claude' })
    if ($claudeRuns.Count -gt 0) {
        $warnings.Add("Claude 審查者的執行紀錄沒有 token 用量，token 合計不含這些列：$(@($claudeRuns | ForEach-Object { $_.run_id }) -join ',')")
    }
    $results = [ordered]@{}
    foreach ($run in $runs) {
        $key = if ($null -eq $run.result) { 'unknown' } else { [string]$run.result }
        $results[$key] = 1 + $(if ($results.Contains($key)) { $results[$key] } else { 0 })
    }
    $models = [ordered]@{}
    foreach ($group in @($runs | Group-Object { if ($null -eq $_.model) { 'unknown' } else { [string]$_.model } })) {
        $modelRuns = @($group.Group | Where-Object { $countable -contains $_ })
        $models[$group.Name] = [ordered]@{
            runs = $group.Count
            input_tokens = Get-NullableSum $modelRuns 'input_tokens'
            cached_input_tokens = Get-NullableSum $modelRuns 'cached_input_tokens'
            output_tokens = Get-NullableSum $modelRuns 'output_tokens'
        }
    }
    $durations = @($runs | Where-Object { $null -ne $_.duration_seconds } | ForEach-Object { [double]$_.duration_seconds })
    $durationSum = if ($durations.Count -eq 0) { $null } else { [Math]::Round([double]($durations | Measure-Object -Sum).Sum, 1) }
    if ($runs.Count -eq 0 -and $warnings.Count -eq 0) { $warnings.Add('此線沒有任何 Codex 執行紀錄或成本事件列。') }

    $claude = Get-ClaudeCost
    $output = [ordered]@{
        schema = 'ai-agents.line-cost.v1'
        line_slug = $LineSlug
        work_root = $WorkRoot
        codex = [ordered]@{
            run_count = $runs.Count
            by_result = $results
            by_model = $models
            totals = [ordered]@{
                runs_with_usage = $countable.Count
                runs_without_usage = $runs.Count - $withUsage.Count
                runs_usage_not_counted = $unanchored.Count
                claude_runs_without_usage = $claudeRuns.Count
                usage_incomplete = ($unanchored.Count -gt 0 -or $claudeRuns.Count -gt 0)
                input_tokens = Get-NullableSum $countable 'input_tokens'
                cached_input_tokens = Get-NullableSum $countable 'cached_input_tokens'
                output_tokens = Get-NullableSum $countable 'output_tokens'
                duration_seconds = $durationSum
            }
            runs = $runs
        }
        claude = $claude.value
        claude_unavailable_reason = $claude.reason
        warnings = @($warnings)
    }
    $output | ConvertTo-Json -Depth 8
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
