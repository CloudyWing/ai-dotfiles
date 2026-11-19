#Requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'Get-LineCost.ps1'
$root = Join-Path $env:TEMP ('line-cost-test-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8

function Assert-Equal {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected,
        [Parameter(Mandatory)][string]$Name
    )
    if ("$Actual" -ne "$Expected") { throw "$Name expected [$Expected], got [$Actual]" }
}
function Invoke-LineCost {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    $previous = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $output = & pwsh -NoProfile -File $script @Arguments 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    $text = ($output | ForEach-Object { "$_" }) -join "`n"
    $json = $null
    if ($code -eq 0) { $json = $text | ConvertFrom-Json }
    return @{ code = $code; text = $text; json = $json }
}
function New-Line {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Slug)
    $handoff = Join-Path $root ".local\ai-sessions\handoff\$Slug"
    $report = Join-Path $root ".local\ai-sessions\report\$Slug"
    New-Item -ItemType Directory -Path $handoff, (Join-Path $report 'runs') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $handoff 'line.json'), "{`"line-slug`":`"$Slug`"}", $utf8)
    return $report
}
function Write-Record {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Report,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Result,
        [Parameter(Mandatory)][object]$Usage,
        [object]$Duration = 100.5
    )
    $record = [ordered]@{
        run_id = $RunId; dispatch_slug = "d-$RunId"; task_type = 'review'; model = 'model-a'
        account = [ordered]@{ name = 'acc' }; result = $Result; exit_code = 0
        rejection_kind = $(if ($Result -eq 'rejected') { 'usage-limit' } else { $null })
        started_utc = '2026-11-01T00:00:00Z'; ended_utc = "2026-11-01T00:10:0$($RunId.Substring($RunId.Length - 1))Z"; duration_seconds = $Duration
        usage = $Usage
    }
    [IO.File]::WriteAllText((Join-Path $Report "runs\x-$RunId.record.json"), ($record | ConvertTo-Json -Depth 5), $utf8)
}
function Write-Ledger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Report,
        [Parameter(Mandatory)][string[]]$Rows
    )
    $head = @('# t 成本紀錄', '', '<!-- cost-ledger.v2 -->',
        '| 時間（UTC） | 列類型 | 成本目標 | dispatchSlug | runId | cycle_id | cycle_round | cycle_role | 事件類型 | 耗時（秒） | input | cached_input | output | 備註 |',
        '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |')
    [IO.File]::WriteAllLines((Join-Path $Report 'cost-ledger.md'), ($head + $Rows), $utf8)
}
try {
    # 空線：只有 line.json。
    New-Line 'empty-line' | Out-Null
    $r = Invoke-LineCost @('-WorkRoot', $root, '-LineSlug', 'empty-line')
    Assert-Equal $r.code 0 'empty exit'
    Assert-Equal $r.json.codex.run_count 0 'empty run_count'
    Assert-Equal $r.json.codex.totals.input_tokens $null 'empty input is null'
    Assert-Equal $r.json.codex.totals.duration_seconds $null 'empty duration is null'
    if ($null -ne $r.json.claude) { throw 'empty claude should be null' }
    if (-not $r.json.claude_unavailable_reason) { throw 'empty claude reason missing' }
    Assert-Equal @($r.json.warnings).Count 1 'empty warnings'

    # 只有成功：記錄加同 runId 的事件列，循環標示取自事件列。
    $report = New-Line 'ok-line'
    Write-Record $report 'r1' 'success' ([ordered]@{ status = 'recorded'; input_tokens = 1000; cached_input_tokens = 900; output_tokens = 50 })
    Write-Record $report 'r2' 'success' ([ordered]@{ status = 'recorded'; input_tokens = 2000; cached_input_tokens = 1800; output_tokens = 70 })
    Write-Ledger $report @('| 2026-11-01T00:10:01Z | 事件 | ok-line | d-r1 | r1 | cyc | 1 | review | 首次 | 100 | 1000 | 900 | 50 | exit=0;result=success;task=review;account=acc;rejection=none;usage=recorded |')
    $r = Invoke-LineCost @('-WorkRoot', $root, '-LineSlug', 'ok-line')
    Assert-Equal $r.code 0 'ok exit'
    Assert-Equal $r.json.codex.run_count 2 'ok run_count'
    Assert-Equal $r.json.codex.totals.input_tokens 3000 'ok input'
    Assert-Equal $r.json.codex.totals.cached_input_tokens 2700 'ok cached'
    Assert-Equal $r.json.codex.totals.output_tokens 120 'ok output'
    Assert-Equal $r.json.codex.totals.duration_seconds 201 'ok duration'
    Assert-Equal $r.json.codex.by_model.'model-a'.runs 2 'ok model runs'
    Assert-Equal $r.json.codex.runs[0].cycle_id 'cyc' 'ok cycle from ledger'
    Assert-Equal @($r.json.warnings).Count 0 'ok warnings'

    # 含被拒，另有只存在於成本列的舊入口 run（沒有 model）。
    $report = New-Line 'rej-line'
    Write-Record $report 'r1' 'success' ([ordered]@{ status = 'recorded'; input_tokens = 500; cached_input_tokens = 400; output_tokens = 10 })
    Write-Record $report 'r2' 'rejected' ([ordered]@{ status = 'no-terminal-event' })
    Write-Ledger $report @('| 2026-11-01T00:20:00Z | 事件 | rej-line | old-d | legacy9 | - | - | - | 首次 | 60 | 300 | 100 | 5 | exit=0;result=completed;task=test;usage=recorded;usage_basis=delta |')
    $r = Invoke-LineCost @('-WorkRoot', $root, '-LineSlug', 'rej-line')
    Assert-Equal $r.code 0 'rej exit'
    Assert-Equal $r.json.codex.run_count 3 'rej run_count'
    Assert-Equal $r.json.codex.by_result.rejected 1 'rej rejected'
    Assert-Equal $r.json.codex.by_result.success 1 'rej success'
    Assert-Equal $r.json.codex.totals.runs_without_usage 1 'rej without usage'
    Assert-Equal $r.json.codex.totals.input_tokens 800 'rej input'
    Assert-Equal $r.json.codex.by_model.unknown.runs 1 'rej unknown model'
    Assert-Equal $r.json.codex.by_model.unknown.input_tokens 300 'rej unknown model input'

    # 紀錄檔毀損：略過並記入 warnings，其餘照常彙整。
    $report = New-Line 'bad-line'
    Write-Record $report 'r1' 'success' ([ordered]@{ status = 'recorded'; input_tokens = 10; cached_input_tokens = 0; output_tokens = 1 })
    [IO.File]::WriteAllText((Join-Path $report 'runs\x-broken.record.json'), '{ not json', $utf8)
    Write-Ledger $report @('| 損毀的列 |', '| 2026-11-01T00:30:00Z | 事件 | bad-line | d | r7 | - | - | - | 首次 | 1 | 1 | 1 | 1 | usage=recorded |')
    $r = Invoke-LineCost @('-WorkRoot', $root, '-LineSlug', 'bad-line')
    Assert-Equal $r.code 0 'bad exit'
    Assert-Equal $r.json.codex.run_count 2 'bad run_count'
    Assert-Equal @($r.json.warnings).Count 2 'bad warnings'

    # 續行的累計用量（cumulative-no-anchor）無法換算增量，不併入合計並標示不完整。
    $report = New-Line 'cont-line'
    Write-Ledger $report @(
        '| 2026-11-01T01:00:00Z | 事件 | cont-line | d1 | a1 | - | - | - | 首次 | 10 | 1000 | 800 | 50 | exit=0;result=completed;task=test;usage=recorded;usage_basis=cumulative |',
        '| 2026-11-01T01:10:00Z | 事件 | cont-line | d1 | a2 | - | - | - | 續行 | 10 | 1500 | 1200 | 80 | exit=0;result=completed;task=test;usage=recorded;usage_basis=cumulative-no-anchor |',
        '| 2026-11-01T01:20:00Z | 事件 | cont-line | d1 | a3 | - | - | - | 續行 | 10 | 200 | 100 | 5 | exit=0;result=completed;task=test;usage=recorded;usage_basis=delta |')
    $r = Invoke-LineCost @('-WorkRoot', $root, '-LineSlug', 'cont-line')
    Assert-Equal $r.code 0 'cont exit'
    Assert-Equal $r.json.codex.run_count 3 'cont run_count'
    Assert-Equal $r.json.codex.totals.input_tokens 1200 'cont input excludes cumulative-no-anchor'
    Assert-Equal $r.json.codex.totals.runs_usage_not_counted 1 'cont not counted'
    Assert-Equal $r.json.codex.totals.usage_incomplete $true 'cont incomplete'
    Assert-Equal @($r.json.warnings).Count 1 'cont warnings'

    # 合法 JSON 但耗時欄位毀損：該筆略過並記警告，其餘照常彙整。
    $report = New-Line 'dur-line'
    Write-Record $report 'r1' 'success' ([ordered]@{ status = 'recorded'; input_tokens = 10; cached_input_tokens = 0; output_tokens = 1 })
    Write-Record $report 'r2' 'success' ([ordered]@{ status = 'recorded'; input_tokens = 20; cached_input_tokens = 0; output_tokens = 2 }) 'abc'
    $r = Invoke-LineCost @('-WorkRoot', $root, '-LineSlug', 'dur-line')
    Assert-Equal $r.code 0 'dur exit'
    Assert-Equal $r.json.codex.run_count 1 'dur run_count'
    Assert-Equal $r.json.codex.totals.input_tokens 10 'dur input'
    Assert-Equal @($r.json.warnings).Count 1 'dur warnings'

    # 全部 run 都沒有 usage：token 合計為 null，不是 0。
    $report = New-Line 'nouse-line'
    Write-Record $report 'r2' 'rejected' ([ordered]@{ status = 'no-terminal-event' })
    $r = Invoke-LineCost @('-WorkRoot', $root, '-LineSlug', 'nouse-line')
    Assert-Equal $r.code 0 'nouse exit'
    Assert-Equal $r.json.codex.totals.input_tokens $null 'nouse input null'
    Assert-Equal $r.json.codex.totals.cached_input_tokens $null 'nouse cached null'
    Assert-Equal $r.json.codex.by_model.'model-a'.output_tokens $null 'nouse model output null'

    # 不存在的線與無效 slug 以結束碼 1 回報。
    Assert-Equal (Invoke-LineCost @('-WorkRoot', $root, '-LineSlug', 'no-such-line')).code 1 'missing line exit'
    Assert-Equal (Invoke-LineCost @('-WorkRoot', $root, '-LineSlug', 'Bad_Slug')).code 1 'invalid slug exit'

    # Claude：指定 transcript 時重用 Get-ClaudeSessionUsage.ps1。
    $transcript = Join-Path $root 'session1.jsonl'
    [IO.File]::WriteAllText($transcript, '{"type":"assistant","message":{"id":"a","usage":{"input_tokens":3,"cache_creation_input_tokens":4,"cache_read_input_tokens":5,"output_tokens":6}}}', $utf8)
    $r = Invoke-LineCost @('-WorkRoot', $root, '-LineSlug', 'empty-line', '-ClaudeTranscriptPath', $transcript)
    Assert-Equal $r.code 0 'claude exit'
    Assert-Equal $r.json.claude.total.input_tokens 3 'claude total input'
    Assert-Equal $r.json.claude.main.output_tokens 6 'claude main output'
    if ($null -ne $r.json.claude_unavailable_reason) { throw 'claude reason should be null when computed' }
    $r = Invoke-LineCost @('-WorkRoot', $root, '-LineSlug', 'empty-line', '-ClaudeTranscriptPath', (Join-Path $root 'missing.jsonl'))
    Assert-Equal $r.code 0 'claude missing exit'
    if ($null -ne $r.json.claude -or -not $r.json.claude_unavailable_reason) { throw 'claude missing transcript should be null with reason' }

    # Claude 未知數值輸出 null，不輸出 unknown 字串。
    $partial = Join-Path $root 'partial.jsonl'
    [IO.File]::WriteAllText($partial, '{"type":"assistant","message":{"id":"a","usage":{"input_tokens":3,"output_tokens":6}}}', $utf8)
    $r = Invoke-LineCost @('-WorkRoot', $root, '-LineSlug', 'empty-line', '-ClaudeTranscriptPath', $partial)
    Assert-Equal $r.code 0 'claude partial exit'
    Assert-Equal $r.json.claude.main.cache_write_tokens $null 'claude unknown is null'
    Assert-Equal $r.json.claude.main.input_tokens 3 'claude known value kept'

    Write-Output 'Test-GetLineCost: PASS'
    exit 0
} catch {
    [Console]::Error.WriteLine("Test-GetLineCost: FAIL - $($_.Exception.Message)")
    exit 1
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
