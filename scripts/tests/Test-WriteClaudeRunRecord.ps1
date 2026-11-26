#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$recordScript = Join-Path $scriptsRoot 'Write-ClaudeRunRecord.ps1'
$costScript = Join-Path $scriptsRoot 'Get-LineCost.ps1'
. (Join-Path $PSScriptRoot 'codex-run-fixtures\TestHelpers.ps1')

function Invoke-Concurrent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Script, [Parameter(Mandatory)][object[]]$ArgumentSet)

    # 同時啟動多個行程再一起等待，回傳各自的結束碼與 stderr。
    $items = foreach ($set in $ArgumentSet) {
        $out = Join-Path (Get-TestTempRoot) ('cc-' + [guid]::NewGuid().ToString('N') + '.txt')
        $process = Start-Process -FilePath 'pwsh' -ArgumentList (@('-NoProfile', '-File', $Script) + @($set)) -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError ($out + '.err')
        [pscustomobject]@{ Process = $process; Out = $out }
    }
    foreach ($item in $items) { $item.Process.WaitForExit() }
    return @($items | ForEach-Object {
            $stderr = if ([IO.File]::Exists($_.Out + '.err')) { [IO.File]::ReadAllText($_.Out + '.err') } else { '' }
            foreach ($file in @($_.Out, ($_.Out + '.err'))) { if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } }
            [pscustomobject]@{ Code = $_.Process.ExitCode; Stderr = $stderr }
        })
}

function Invoke-Script {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Script, [Parameter(Mandatory)][string[]]$Argument)

    $stderrPath = Join-Path (Get-TestTempRoot) ('cr-stderr-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        $stdout = @(& pwsh -NoProfile -File $Script @Argument 2>$stderrPath)
        $code = $LASTEXITCODE
        $stderr = if ([IO.File]::Exists($stderrPath)) { [IO.File]::ReadAllText($stderrPath) } else { '' }
    }
    finally { if ([IO.File]::Exists($stderrPath)) { [IO.File]::Delete($stderrPath) } }
    $text = ($stdout | ForEach-Object { [string]$_ }) -join "`n"
    $json = $null
    if (-not [string]::IsNullOrWhiteSpace($text)) { try { $json = ConvertFrom-Json -InputObject $text } catch { $json = $null } }
    return [pscustomobject]@{ Code = $code; Json = $json; Stderr = $stderr }
}

$validReport = @'
# 審查報告

## 總覽

審查者: Sonnet subagent；同家族審查

## Finding manifest

```json
{"schema":"codex-run.review-findings.v1","findings":[]}
```
'@

try {
    $root = New-TestDirectory -Name 'claude-record'
    $exec = Join-Path $root 'exec'
    $reportRoot = Join-Path $root 'report\line-a'
    $null = New-Item -ItemType Directory -Path (Join-Path $exec 'src'), $reportRoot -Force
    $roleFile = Join-Path $exec 'reviewer.toml'
    $target = Join-Path $exec 'src\a.txt'
    Write-TestUtf8 -Path $roleFile -Text 'role'
    Write-TestUtf8 -Path $target -Text 'v1'

    function New-OrderFile {
        [CmdletBinding()]
        param([string]$Name = 'order.md', [hashtable]$Override = @{})
        $setting = [ordered]@{
            schema = 'ai-agents.codex-run-order.v1'; line_slug = 'line-a'; dispatch_slug = 'review-p1'; task_type = 'review'; profile = 'review'
            role_file = $roleFile; execution_root = $exec; report_line_root = $reportRoot; report_name = 'review-report.md'
            targets = @($target); required_reads = @()
        }
        foreach ($key in $Override.Keys) { $setting[$key] = $Override[$key] }
        $json = ConvertTo-Json -InputObject $setting -Depth 6
        $path = Join-Path $reportRoot $Name
        Write-TestUtf8 -Path $path -Text "# 派遣檔`n`n## 派遣設定`n`n``````json`n$json`n```````n`n## 任務`n`n審查。`n"
        return $path
    }
    function Get-Records { return @(Get-ChildItem -LiteralPath (Join-Path $reportRoot 'runs') -Filter '*.record.json' -File -ErrorAction SilentlyContinue) }
    function Remove-Runs { if ([IO.Directory]::Exists((Join-Path $reportRoot 'runs'))) { Remove-Item -LiteralPath (Join-Path $reportRoot 'runs') -Recurse -Force } }

    $order = New-OrderFile

    Test-Case 'CR-OK 開始與結束成功，紀錄欄位與 Codex 紀錄一致且 Claude 專有欄位為 null' {
        Remove-Runs
        Write-TestUtf8 -Path $target -Text 'v1'
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $start.Code $start.Stderr
        Assert-True ([IO.Directory]::Exists($start.Json.output_dir))
        Assert-Equal 'sonnet' $start.Json.model
        Assert-Equal (Join-Path $start.Json.output_dir 'review-report.md') $start.Json.report_path
        $draft = Get-Content -LiteralPath $start.Json.record_path -Raw | ConvertFrom-Json
        Assert-True ($null -eq $draft.ended_utc)
        Write-TestUtf8 -Path $start.Json.report_path -Text $validReport
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $end.Code $end.Stderr
        Assert-Equal 'success' $end.Json.result
        Assert-Equal $false $end.Json.source_changed
        $record = Get-Content -LiteralPath $start.Json.record_path -Raw | ConvertFrom-Json
        Assert-Equal 'claude' $record.executor_platform
        Assert-Equal 'sonnet' $record.executor_id
        Assert-Equal 'sonnet' $record.model
        Assert-Equal 'review' $record.task_type
        Assert-Equal 'success' $record.result
        Assert-True ($null -ne $record.ended_utc -and $record.duration_seconds -ge 0 -and $record.duration_seconds -le 60)
        Assert-True ($null -eq $record.account)
        Assert-True ($null -eq $record.usage)
        Assert-True ($null -eq $record.events_path)
        Assert-True ($null -eq $record.permission)
        Assert-Equal $true $record.review_report_check.valid
        Assert-Equal 64 ([string]$record.dispatch_file.sha256).Length
        Assert-Equal ((Get-FileHash -LiteralPath $order -Algorithm SHA256).Hash.ToLowerInvariant()) $record.dispatch_file.sha256
        Assert-True ($null -ne $record.source_state_start -and $null -ne $record.source_state_end)
    }
    Test-Case 'CR-COST 成本腳本讀得到該列，標示為 claude、無 token 用量且合計不完整' {
        $workRoot = Join-Path $root 'cost-root'
        $costReport = Join-Path $workRoot '.local\ai-sessions\report\line-a'
        $null = New-Item -ItemType Directory -Path (Join-Path $costReport 'runs'), (Join-Path $workRoot '.local\ai-sessions\handoff\line-a') -Force
        Write-TestUtf8 -Path (Join-Path $workRoot '.local\ai-sessions\handoff\line-a\line.json') -Text '{"line-slug":"line-a"}'
        Copy-Item -LiteralPath (Get-Records)[0].FullName -Destination (Join-Path $costReport 'runs')
        $cost = Invoke-Script $costScript @('-WorkRoot', $workRoot, '-LineSlug', 'line-a')
        Assert-Equal 0 $cost.Code $cost.Stderr
        Assert-Equal 1 $cost.Json.codex.run_count
        Assert-Equal 'claude' $cost.Json.codex.runs[0].platform
        Assert-Equal 'sonnet' $cost.Json.codex.runs[0].model
        Assert-Equal 'success' $cost.Json.codex.runs[0].result
        Assert-True ($null -eq $cost.Json.codex.totals.input_tokens)
        Assert-Equal $true $cost.Json.codex.totals.usage_incomplete
        Assert-Equal 1 $cost.Json.codex.totals.claude_runs_without_usage
        Assert-True (@($cost.Json.warnings | Where-Object { $_ -like '*Claude 審查者*沒有 token 用量*' }).Count -eq 1)
    }
    Test-Case 'CR-CYCLE 派遣檔有 cycle 時紀錄帶循環欄位，成本腳本據此輸出；無 cycle 時為 null' {
        Remove-Runs
        $noCycle = New-OrderFile -Name 'nocycle.md'
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $noCycle, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $start.Code $start.Stderr
        $plain = Get-Content -LiteralPath $start.Json.record_path -Raw | ConvertFrom-Json
        Assert-True ($null -eq $plain.cycle_id -and $null -eq $plain.cycle_round -and $null -eq $plain.cycle_role)
        Write-TestUtf8 -Path $start.Json.report_path -Text $validReport
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $noCycle, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $end.Code $end.Stderr

        Remove-Runs
        $withCycle = New-OrderFile -Name 'cycle.md' -Override @{ cycle = [ordered]@{ id = 'cyc-1'; round = 2; role = 'review' } }
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $withCycle, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $start.Code $start.Stderr
        Write-TestUtf8 -Path $start.Json.report_path -Text $validReport
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $withCycle, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $end.Code $end.Stderr
        $record = Get-Content -LiteralPath $start.Json.record_path -Raw | ConvertFrom-Json
        Assert-Equal 'cyc-1' $record.cycle_id
        Assert-Equal 2 $record.cycle_round
        Assert-Equal 'review' $record.cycle_role
        $workRoot = Join-Path $root 'cost-root-cycle'
        $costReport = Join-Path $workRoot '.local\ai-sessions\report\line-a'
        $null = New-Item -ItemType Directory -Path (Join-Path $costReport 'runs'), (Join-Path $workRoot '.local\ai-sessions\handoff\line-a') -Force
        Write-TestUtf8 -Path (Join-Path $workRoot '.local\ai-sessions\handoff\line-a\line.json') -Text '{"line-slug":"line-a"}'
        Copy-Item -LiteralPath (Get-Records)[0].FullName -Destination (Join-Path $costReport 'runs')
        $cost = Invoke-Script $costScript @('-WorkRoot', $workRoot, '-LineSlug', 'line-a')
        Assert-Equal 0 $cost.Code $cost.Stderr
        Assert-Equal 'claude' $cost.Json.codex.runs[0].platform
        Assert-Equal 'cyc-1' $cost.Json.codex.runs[0].cycle_id
        Assert-Equal '2' ([string]$cost.Json.codex.runs[0].cycle_round)
    }
    Test-Case 'CR-INVALID-ORDER 派遣檔無效以結束碼 2 拒絕，不建立任何輸出' {
        Remove-Runs
        $bad = New-OrderFile -Name 'bad.md' -Override @{ line_slug = 'Bad_Slug' }
        $result = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $bad, '-ExecutorId', 'sonnet')
        Assert-Equal 2 $result.Code
        Assert-True ($result.Stderr -like '*RunDispatchFileInvalid*')
        Assert-Equal 0 @(Get-Records).Count
        $missing = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', (Join-Path $reportRoot 'absent.md'), '-ExecutorId', 'sonnet')
        Assert-Equal 2 $missing.Code
        $noTarget = New-OrderFile -Name 'notarget.md' -Override @{ targets = @((Join-Path $exec 'src\missing.txt')) }
        $result = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $noTarget, '-ExecutorId', 'sonnet')
        Assert-Equal 2 $result.Code
        Assert-True ($result.Stderr -like '*RunPathsInvalid*')
    }
    Test-Case 'CR-UNKNOWN-EXECUTOR 未知、Codex 與不受理該類型的執行者以結束碼 2 拒絕' {
        Remove-Runs
        $unknown = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'nobody')
        Assert-Equal 2 $unknown.Code
        Assert-True ($unknown.Stderr -like '*ClaudeRunExecutorUnknown*')
        $codex = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'codex-review')
        Assert-Equal 2 $codex.Code
        Assert-True ($codex.Stderr -like '*ClaudeRunExecutorNotClaude*')
        $haiku = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'haiku')
        Assert-Equal 2 $haiku.Code
        Assert-True ($haiku.Stderr -like '*ClaudeRunTaskTypeNotAccepted*')
        Assert-Equal 0 @(Get-Records).Count
    }
    Test-Case 'CR-DOUBLE-START 開始後未結束就再開始以結束碼 2 拒絕，結束後可重新開始' {
        Remove-Runs
        $first = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $first.Code
        $second = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 2 $second.Code
        Assert-True ($second.Stderr -like '*ClaudeRunAlreadyStarted*')
        Assert-Equal 1 @(Get-Records).Count
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 1 $end.Code
        $third = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $third.Code
        Assert-Equal 2 @(Get-Records).Count
    }
    Test-Case 'CR-END-WITHOUT-START 沒有開始就結束以結束碼 2 拒絕' {
        Remove-Runs
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 2 $end.Code
        Assert-True ($end.Stderr -like '*ClaudeRunNotStarted*')
    }
    Test-Case 'CR-SOURCE-CHANGED 審查期間來源被改時結果為 failed、source-changed，紀錄仍寫出' {
        Remove-Runs
        Write-TestUtf8 -Path $target -Text 'v1'
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'opus')
        Assert-Equal 0 $start.Code
        Write-TestUtf8 -Path $start.Json.report_path -Text $validReport
        Write-TestUtf8 -Path $target -Text 'v2 changed during review'
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $order, '-ExecutorId', 'opus')
        Assert-Equal 1 $end.Code
        Assert-Equal 'failed' $end.Json.result
        Assert-Equal 'source-changed' $end.Json.failure_reason
        Assert-Equal $true $end.Json.source_changed
        $record = Get-Content -LiteralPath $start.Json.record_path -Raw | ConvertFrom-Json
        Assert-Equal 'source-changed' $record.failure_reason
        Assert-Equal 'opus' $record.model
        Write-TestUtf8 -Path $target -Text 'v1'
    }
    Test-Case 'CR-REPORT-MISSING 報告缺失或為空時結果為 failed、report-missing' {
        Remove-Runs
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 1 $end.Code
        Assert-Equal 'report-missing' $end.Json.failure_reason
        $record = Get-Content -LiteralPath $start.Json.record_path -Raw | ConvertFrom-Json
        Assert-Equal $false $record.report.exists
        Assert-True ($null -eq $record.review_report_check)
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Write-TestUtf8 -Path $start.Json.report_path -Text ''
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 'report-missing' $end.Json.failure_reason
    }
    Test-Case 'CR-REPORT-INVALID 報告缺 finding manifest 時結果為 failed、review-report-invalid' {
        Remove-Runs
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Write-TestUtf8 -Path $start.Json.report_path -Text "# 報告`n沒有 manifest`n"
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 1 $end.Code
        Assert-Equal 'review-report-invalid' $end.Json.failure_reason
        Assert-Equal $false $end.Json.review_report_check.valid
        Assert-True (@($end.Json.review_report_check.errors).Count -gt 0)
    }
    Test-Case 'CR-END-TARGET-DELETED Start 後目標被刪除，End 仍寫出 source_changed 為 true 的失敗紀錄，之後可再 Start' {
        Remove-Runs
        Write-TestUtf8 -Path $target -Text 'v1'
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $start.Code
        Write-TestUtf8 -Path $start.Json.report_path -Text $validReport
        Remove-Item -LiteralPath $target -Force
        try {
            $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
            Assert-Equal 1 $end.Code $end.Stderr
            Assert-Equal 'source-changed' $end.Json.failure_reason
            Assert-Equal $true $end.Json.source_changed
            $record = Get-Content -LiteralPath $start.Json.record_path -Raw | ConvertFrom-Json
            Assert-True ($null -ne $record.ended_utc)
            Assert-Equal 'failed' $record.result
        }
        finally { Write-TestUtf8 -Path $target -Text 'v1' }
        $again = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $again.Code $again.Stderr
    }
    Test-Case 'CR-END-SOURCE-STATE-ERROR 來源狀態計算拋出例外時，紀錄含 source_state_error、stderr 有診斷行、source_changed 為 true 且紀錄完整寫出' {
        Remove-Runs
        Write-TestUtf8 -Path $target -Text 'v1'
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $start.Code
        Write-TestUtf8 -Path $start.Json.report_path -Text $validReport
        # 把紀錄的 execution_root 改為空字串，使 Get-RunSourceState 的必要參數繫結必然失敗，不改動正式程式。
        $recordData = Get-Content -LiteralPath $start.Json.record_path -Raw | ConvertFrom-Json -AsHashtable
        $recordData['execution_root'] = ''
        Write-TestUtf8 -Path $start.Json.record_path -Text ($recordData | ConvertTo-Json -Depth 10)
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 1 $end.Code $end.Stderr
        Assert-Equal $true $end.Json.source_changed
        Assert-Equal 'source-changed' $end.Json.failure_reason
        Assert-True ($end.Stderr -match '來源狀態計算失敗') ('stderr 缺少診斷行：' + $end.Stderr)
        $record = Get-Content -LiteralPath $start.Json.record_path -Raw | ConvertFrom-Json
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$record.source_state_error)) 'source_state_error 不應為空'
        Assert-True ($null -ne $record.ended_utc -and $null -eq $record.source_state_end) '紀錄應完整寫出且 source_state_end 為 null'
        Assert-Equal 'failed' $record.result
    }
    Test-Case 'CR-END-BASELINE 派遣檔 targets 在 Start 後改指別處時，仍以 Start 的 targets 核對來源' {
        Remove-Runs
        Write-TestUtf8 -Path $target -Text 'v1'
        $other = Join-Path $exec 'src\b.txt'
        Write-TestUtf8 -Path $other -Text 'b'
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $start.Code
        Write-TestUtf8 -Path $start.Json.report_path -Text $validReport
        Write-TestUtf8 -Path $target -Text 'v2 changed'
        $moved = New-OrderFile -Name 'order.md' -Override @{ targets = @($other) }
        try {
            $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $moved, '-ExecutorId', 'sonnet')
            Assert-Equal 1 $end.Code $end.Stderr
            Assert-Equal $true $end.Json.source_changed
            Assert-Equal 'source-changed' $end.Json.failure_reason
            Assert-Equal $true $end.Json.dispatch_changed
        }
        finally { Write-TestUtf8 -Path $target -Text 'v1'; $null = New-OrderFile }
    }
    Test-Case 'CR-END-DISPATCH-CHANGED 派遣檔在 Start 後被改且來源未變時為 failed、dispatch-changed，仍依 Start 的 report_check 檢查報告' {
        Remove-Runs
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $start.Code
        Write-TestUtf8 -Path $start.Json.report_path -Text "# 報告`n沒有 manifest`n"
        $changed = New-OrderFile -Name 'order.md' -Override @{ task_type = 'factcheck'; profile = 'factcheck' }
        try {
            $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $changed, '-ExecutorId', 'sonnet')
            Assert-Equal 1 $end.Code $end.Stderr
            Assert-Equal 'dispatch-changed' $end.Json.failure_reason
            Assert-Equal $false $end.Json.source_changed
            Assert-Equal $false $end.Json.review_report_check.valid
            $record = Get-Content -LiteralPath $start.Json.record_path -Raw | ConvertFrom-Json
            Assert-Equal 'review' $record.task_type
            Assert-True ($record.dispatch_file.sha256 -cne $record.dispatch_file.sha256_end)
        }
        finally { $null = New-OrderFile }
    }
    Test-Case 'CR-PARALLEL-START 同時多個 Start 只有一個成功，其餘以結束碼 2 拒絕，只留一份未結束紀錄且可 End' {
        Remove-Runs
        $argumentSet = @(1..5 | ForEach-Object { , @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet') })
        $results = Invoke-Concurrent $recordScript $argumentSet
        Assert-Equal 1 @($results | Where-Object { $_.Code -eq 0 }).Count (($results | ForEach-Object { [string]$_.Code + ' ' + $_.Stderr }) -join "`n")
        Assert-Equal 4 @($results | Where-Object { $_.Code -eq 2 }).Count
        Assert-Equal 1 @(Get-Records).Count
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-True ($end.Code -in @(0, 1)) $end.Stderr
    }
    Test-Case 'CR-PARALLEL-END 同時多個 End 只有一個寫出結果，其餘以結束碼 2 拒絕' {
        Remove-Runs
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $start.Code
        Write-TestUtf8 -Path $start.Json.report_path -Text $validReport
        $argumentSet = @(1..4 | ForEach-Object { , @('-Action', 'End', '-DispatchFile', $order, '-ExecutorId', 'sonnet') })
        $results = Invoke-Concurrent $recordScript $argumentSet
        Assert-Equal 1 @($results | Where-Object { $_.Code -eq 0 }).Count (($results | ForEach-Object { [string]$_.Code + ' ' + $_.Stderr }) -join "`n")
        Assert-Equal 3 @($results | Where-Object { $_.Code -eq 2 }).Count
        Assert-Equal 1 @(Get-Records).Count
    }
    Test-Case 'CR-DURATION 開始時間以 UTC（Z）或帶位移的字串寫入，duration_seconds 都不受本機時區影響' {
        foreach ($started in @([DateTime]::UtcNow.AddSeconds(-30).ToString('o', [Globalization.CultureInfo]::InvariantCulture), [DateTimeOffset]::UtcNow.AddSeconds(-30).ToOffset([TimeSpan]::FromHours(-7)).ToString('o', [Globalization.CultureInfo]::InvariantCulture))) {
            Remove-Runs
            $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
            Assert-Equal 0 $start.Code
            $text = [IO.File]::ReadAllText($start.Json.record_path)
            $replaced = [regex]::Replace($text, '"started_utc":\s*"[^"]*"', ('"started_utc": "' + $started + '"'))
            Assert-True ($replaced -cne $text)
            Write-TestUtf8 -Path $start.Json.record_path -Text $replaced
            $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
            Assert-True ($end.Code -in @(0, 1)) $end.Stderr
            $record = Get-Content -LiteralPath $start.Json.record_path -Raw | ConvertFrom-Json
            Assert-True ($record.duration_seconds -ge 29 -and $record.duration_seconds -le 90) ([string]$record.duration_seconds + ' / ' + $started)
        }
    }
    Test-Case 'CR-LOCK-TIMEOUT 鎖被他人持有且逾時時拋出 RunLockTimeout 錯誤代碼' {
        $lockPath = Join-Path $root 'held.lock'
        $holder = New-Object System.IO.FileStream -ArgumentList @($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $common = Join-Path $scriptsRoot 'codex-run\00-common.ps1'
            # 路徑以參數傳入暫存腳本，不經字串內插，路徑含單引號等字元時也不受影響。
            $probeScript = Join-Path $root 'lock-probe.ps1'
            Write-TestUtf8 -Path $probeScript -Text ("param([string]`$Common, [string]`$LockPath)`n. `$Common`ntry { `$null = Enter-RunFileLock -Path `$LockPath -TimeoutSeconds 1; 'acquired' } catch { `$_.Exception.Data['Code'] + ':' + `$_.Exception.Data['ExitCode'] }`n")
            $output = @(& pwsh -NoProfile -File $probeScript -Common $common -LockPath $lockPath 2>&1)
            Assert-Equal 'RunLockTimeout:1' (($output | ForEach-Object { [string]$_ }) -join '')
        }
        finally { $holder.Dispose() }
    }
    Test-Case 'CR-START-NO-OVERWRITE 連續開始與結束不覆寫既有紀錄，每次的 run_id 與目錄都不同' {
        Remove-Runs
        $ids = @()
        foreach ($index in 1..4) {
            $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
            Assert-Equal 0 $start.Code $start.Stderr
            $ids += $start.Json.run_key
            $null = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        }
        Assert-Equal 4 @($ids | Sort-Object -Unique).Count
        Assert-Equal 4 @(Get-Records).Count
        Assert-Equal 4 @(Get-ChildItem -LiteralPath (Join-Path $reportRoot 'runs') -Directory).Count
    }
    Test-Case 'CR-INVENTORY 審查的 Start 在輸出目錄產生工作樹盤點檔，stdout 與紀錄記錄路徑與雜湊，End 填 sha256_end 且不影響結果' {
        Remove-Runs
        Write-TestUtf8 -Path $target -Text 'v1'
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $start.Code $start.Stderr
        $inventoryPath = Join-Path $start.Json.output_dir 'worktree-inventory.md'
        Assert-Equal $inventoryPath $start.Json.worktree_inventory_path
        Assert-True ([IO.File]::Exists($inventoryPath)) '盤點檔不存在'
        $text = [IO.File]::ReadAllText($inventoryPath)
        Assert-True ($text.StartsWith("# 工作樹盤點`n") -and $text.Contains('- schema: ai-agents.worktree-inventory.v1')) '盤點檔標頭'
        $draft = Get-Content -LiteralPath $start.Json.record_path -Raw | ConvertFrom-Json
        Assert-Equal $inventoryPath $draft.worktree_inventory.path
        Assert-Equal (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant() $draft.worktree_inventory.sha256
        Assert-Equal ([long](Get-Item -LiteralPath $inventoryPath).Length) ([long]$draft.worktree_inventory.bytes)
        Assert-True ($null -eq $draft.worktree_inventory.sha256_end) '初稿的 sha256_end 應為 null'
        Assert-True ($null -ne $draft.worktree_inventory.PSObject.Properties['error'] -and $null -eq $draft.worktree_inventory.error) '成功時 error 應為 null'
        Assert-True ($null -eq $start.Json.PSObject.Properties['worktree_inventory_error']) '成功時 stdout 不應含 worktree_inventory_error'
        Write-TestUtf8 -Path $start.Json.report_path -Text $validReport
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $end.Code $end.Stderr
        Assert-Equal 'success' $end.Json.result
        $record = Get-Content -LiteralPath $start.Json.record_path -Raw | ConvertFrom-Json
        Assert-Equal $record.worktree_inventory.sha256 $record.worktree_inventory.sha256_end
    }
    Test-Case 'CR-INVENTORY-END-DELETED 盤點檔在 End 前被刪除時 sha256_end 為 null，結果不受影響' {
        Remove-Runs
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $start.Code $start.Stderr
        [IO.File]::Delete($start.Json.worktree_inventory_path)
        Write-TestUtf8 -Path $start.Json.report_path -Text $validReport
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $end.Code $end.Stderr
        Assert-Equal 'success' $end.Json.result
        $record = Get-Content -LiteralPath $start.Json.record_path -Raw | ConvertFrom-Json
        Assert-True ($null -eq $record.worktree_inventory.sha256_end) 'sha256_end 應為 null'
    }
    Test-Case 'CR-INVENTORY-NON-REVIEW 非審查類型的 Start 不產生盤點檔，stdout 與紀錄都沒有盤點欄位' {
        Remove-Runs
        $factOrder = New-OrderFile -Name 'fact-order.md' -Override @{ task_type = 'factcheck'; profile = 'factcheck'; dispatch_slug = 'fact-p1'; report_name = 'fact-report.md' }
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $factOrder, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $start.Code $start.Stderr
        Assert-True ($null -eq $start.Json.PSObject.Properties['worktree_inventory_path']) 'stdout 不應含 worktree_inventory_path'
        $record = Get-Content -LiteralPath $start.Json.record_path -Raw | ConvertFrom-Json
        Assert-Equal 'factcheck' $record.task_type
        Assert-True ($null -eq $record.PSObject.Properties['worktree_inventory']) '紀錄不應含 worktree_inventory'
        Assert-True (-not [IO.File]::Exists((Join-Path $start.Json.output_dir 'worktree-inventory.md'))) '不應產生盤點檔'
    }
    Test-Case 'CR-INVENTORY-FAILED 盤點產生失敗（索引損毀）時 Start 不停止：結束碼 0、紀錄記下錯誤、stdout 帶 worktree_inventory_error、沒有盤點檔，End 的 sha256_end 為 null 且結果不因此失敗' {
        Remove-Runs
        $gitBase = New-TestDirectory -Name 'claude-record-git'
        $gitRepo = New-TestGitRepository -Directory $gitBase
        Write-TestUtf8 -Path (Join-Path $gitRepo.Root 'src\a.txt') -Text "a`n"
        $null = Invoke-TestGit -WorkingDirectory $gitRepo.Root -Argument @('add', '-A')
        [IO.File]::WriteAllBytes((Join-Path $gitRepo.Root '.git\index'), [byte[]]@(1, 2, 3, 4, 5, 6, 7, 8))
        $badReportRoot = Join-Path $gitBase 'report\line-a'
        $null = New-Item -ItemType Directory -Path $badReportRoot -Force
        $badRole = Join-Path $gitRepo.Root 'reviewer.toml'
        Write-TestUtf8 -Path $badRole -Text 'role'
        $badOrder = New-OrderFile -Name 'bad-order.md' -Override @{ dispatch_slug = 'bad-p1'; role_file = $badRole; execution_root = $gitRepo.Root; report_line_root = $badReportRoot; targets = @((Join-Path $gitRepo.Root 'src\a.txt')) }
        $badOrderInRoot = Join-Path $badReportRoot 'bad-order.md'
        Copy-Item -LiteralPath $badOrder -Destination $badOrderInRoot
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $badOrderInRoot, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $start.Code $start.Stderr
        Assert-True ($start.Stderr -like '*工作樹盤點檔產生失敗*') ('stderr 缺警告：' + $start.Stderr)
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$start.Json.worktree_inventory_error)) 'stdout 的 worktree_inventory_error 應非空'
        Assert-True ($null -eq $start.Json.PSObject.Properties['worktree_inventory_path']) 'stdout 不應含 worktree_inventory_path'
        Assert-True ([IO.File]::Exists($start.Json.record_path)) '紀錄應存在'
        $draft = Get-Content -LiteralPath $start.Json.record_path -Raw | ConvertFrom-Json
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$draft.worktree_inventory.error)) '紀錄的 worktree_inventory.error 應非空'
        Assert-Equal $start.Json.worktree_inventory_error $draft.worktree_inventory.error
        Assert-True ($null -eq $draft.worktree_inventory.path) 'path 應為 null'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $badReportRoot -Recurse -Filter 'worktree-inventory.md' -File -ErrorAction SilentlyContinue).Count
        Write-TestUtf8 -Path $start.Json.report_path -Text $validReport
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $badOrderInRoot, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $end.Code ('End：' + $end.Stderr)
        Assert-Equal 'success' $end.Json.result
        $record = Get-Content -LiteralPath $start.Json.record_path -Raw | ConvertFrom-Json
        Assert-True ($null -ne $record.ended_utc) 'End 應補完紀錄'
        Assert-True ($null -eq $record.worktree_inventory.path -and $null -eq $record.worktree_inventory.sha256_end) 'End 後 path 與 sha256_end 應為 null'
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$record.worktree_inventory.error)) 'End 後 error 應保留'
    }
    Test-Case 'CR-INVENTORY-OTHER-ERROR 盤點步驟丟出 RunWorktreeInventoryFailed 以外的錯誤（其他 Code 或沒有 Code）時，Start 照舊失敗：結束碼 1、stderr 有原錯誤、不寫紀錄' {
        Remove-Runs
        # 複製腳本與模組到暫存位置，在複本的 50-source-state.ps1 末尾以同名函式覆寫盤點步驟；Start 的 catch 判斷式仍是產品碼本身。
        $copyScripts = Join-Path (New-TestDirectory -Name 'claude-record-copy') 'scripts'
        $null = New-Item -ItemType Directory -Path (Join-Path $copyScripts 'dispatch') -Force
        Copy-Item -LiteralPath $recordScript -Destination $copyScripts
        Copy-Item -LiteralPath (Join-Path $scriptsRoot 'codex-run') -Destination (Join-Path $copyScripts 'codex-run') -Recurse
        Copy-Item -LiteralPath (Join-Path $scriptsRoot 'lib') -Destination (Join-Path $copyScripts 'lib') -Recurse
        Copy-Item -LiteralPath (Join-Path $scriptsRoot 'dispatch\executor-registry.json') -Destination (Join-Path $copyScripts 'dispatch\executor-registry.json')
        $copyState = Join-Path $copyScripts 'codex-run\50-source-state.ps1'
        $originalState = [IO.File]::ReadAllText($copyState)
        $copyRecordScript = Join-Path $copyScripts 'Write-ClaudeRunRecord.ps1'
        foreach ($variant in @('coded', 'plain')) {
            $override = if ($variant -ceq 'coded') { "throw (New-RunError -Code 'ClaudeTestOtherFailure' -Message 'injected-other-coded' -ExitCode 1)" } else { "throw 'injected-other-plain'" }
            [IO.File]::WriteAllText($copyState, $originalState + "`nfunction Write-RunWorktreeInventory { " + $override + " }`n", (New-Object System.Text.UTF8Encoding -ArgumentList @($true)))
            $start = Invoke-Script $copyRecordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
            Assert-Equal 1 $start.Code ($variant + '：' + $start.Stderr)
            Assert-True ($start.Stderr -like ('*injected-other-' + $variant + '*')) ($variant + ' stderr：' + $start.Stderr)
            Assert-True ($start.Stderr -notlike '*工作樹盤點檔產生失敗*') ($variant + '：不應走吞下路徑的警告')
            Assert-Equal 0 @(Get-Records).Count ($variant + '：不應寫出紀錄')
        }
    }
}
finally {
    $exitCode = Complete-TestRun
}
exit $exitCode
