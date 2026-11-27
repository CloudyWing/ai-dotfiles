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

    # ---- 測試取證（task_type 為 test）：MCP 工具呼叫的結構化紀錄 ----
    $testReport = "# 測試取證報告`n`n| 序號 | 工具 |`n| --- | --- |`n| 1 | browser_navigate |`n"
    function New-TestOrderFile {
        [CmdletBinding()]
        param([string]$Name = 'order-test.md', [hashtable]$Override = @{})
        $merged = @{ task_type = 'test'; profile = 'test'; dispatch_slug = 'test-p1'; report_name = 'test-report.md' }
        foreach ($key in $Override.Keys) { $merged[$key] = $Override[$key] }
        return (New-OrderFile -Name $Name -Override $merged)
    }
    function New-McpCallFile {
        # 與 ai-agents-hooks 寫下的紀錄檔同格式：<根>\<agent 目錄>\<tool_use_id>.json。
        param([string]$Root, [string]$Agent, [string]$Id, [string]$Tool = 'mcp__playwright__browser_click', [string]$Status = 'completed', [Nullable[DateTime]]$Time)
        $stamp = if ($null -eq $Time) { [DateTime]::UtcNow } else { [DateTime]$Time }
        $server = ($Tool -replace '^mcp__(.+?)__.*$', '$1')
        $agentValue = if ($Agent -ceq '_main') { $null } else { $Agent }
        $directory = Join-Path $Root $Agent
        $null = New-Item -ItemType Directory -Path $directory -Force
        $document = [ordered]@{ schema = 'ai-agents.mcp-call.v1'; session_id = 's1'; agent_id = $agentValue; agent_type = 'general-purpose'; tool_use_id = $Id; tool_name = $Tool; server = $server; status = $Status; ts_utc = $stamp.ToUniversalTime().ToString('o'); duration_ms = 5 }
        if ($Status -ceq 'failed') { $document['is_interrupt'] = $false }
        Write-TestUtf8 -Path (Join-Path $directory ($Id + '.json')) -Text ($document | ConvertTo-Json -Depth 4)
    }
    function Start-TestRun {
        param([string]$OrderPath)
        Remove-Runs
        Write-TestUtf8 -Path $target -Text 'v1'
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $OrderPath, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $start.Code $start.Stderr
        return $start
    }
    function Get-RecordOf { param($Start) return (Get-Content -LiteralPath $Start.Json.record_path -Raw | ConvertFrom-Json) }

    Test-Case 'CR-TEST-OK test 類型的 Start 與 End：紀錄含 mcp_tool_calls（completed、failed、servers、tools、attribution、calls、skipped）、artifacts（含截圖、不含報告）、mcp_stray_output；時間窗內唯一 agent 自動採用；已採用的呼叫紀錄檔 End 後刪除' {
        $callRoot = New-TestDirectory -Name 'mcp-calls-ok'
        $testOrder = New-TestOrderFile
        $start = Start-TestRun -OrderPath $testOrder
        $draft = Get-RecordOf $start
        Assert-True ($null -eq $draft.mcp_tool_calls -and $null -eq $draft.artifacts -and $null -eq $draft.mcp_stray_output) 'Start 的草稿三欄應為 null'
        Assert-Equal 'test' $draft.task_type
        New-McpCallFile -Root $callRoot -Agent 'agent-a' -Id 'tu1' -Tool 'mcp__playwright__browser_navigate'
        New-McpCallFile -Root $callRoot -Agent 'agent-a' -Id 'tu2' -Tool 'mcp__playwright__browser_click'
        New-McpCallFile -Root $callRoot -Agent 'agent-a' -Id 'tu3' -Tool 'mcp__playwright__browser_click' -Status 'failed'
        Write-TestUtf8 -Path (Join-Path $start.Json.output_dir 'shot-web-1.png') -Text 'png'
        Write-TestUtf8 -Path $start.Json.report_path -Text $testReport
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot)
        Assert-Equal 0 $end.Code $end.Stderr
        Assert-Equal 'success' $end.Json.result
        Assert-Equal 2 $end.Json.mcp_tool_calls.completed
        $record = Get-RecordOf $start
        $calls = $record.mcp_tool_calls
        Assert-Equal 2 $calls.completed
        Assert-Equal 1 $calls.failed
        Assert-Equal 'playwright' (@($calls.servers) -join ',')
        Assert-Equal 'mcp__playwright__browser_click,mcp__playwright__browser_navigate' (@($calls.tools) -join ',')
        Assert-Equal 'agent' $calls.attribution
        Assert-Equal 3 @($calls.calls).Count
        Assert-Equal 0 $calls.skipped
        foreach ($field in @('ts_utc', 'tool_name', 'status')) { Assert-True ($null -ne $calls.calls[0].PSObject.Properties[$field]) ('calls 缺少欄位 ' + $field) }
        Assert-Equal 'shot-web-1.png' (@($record.artifacts) -join ',')
        Assert-Equal $false $record.mcp_stray_output.exists
        Assert-Equal 'determined' $record.mcp_stray_output.state
        Assert-Equal 0 @(Get-ChildItem -LiteralPath (Join-Path $callRoot 'agent-a') -File).Count '已採用的呼叫紀錄檔應刪除'
    }
    Test-Case 'CR-TEST-AGENT 給 -AgentId 只取該 agent（其他 agent 的檔案不採用也不刪除）；agent id 含路徑字元時結束碼 2' {
        $callRoot = New-TestDirectory -Name 'mcp-calls-agent'
        $testOrder = New-TestOrderFile
        $start = Start-TestRun -OrderPath $testOrder
        New-McpCallFile -Root $callRoot -Agent 'agent-a' -Id 'a1'
        New-McpCallFile -Root $callRoot -Agent 'agent-b' -Id 'b1'
        New-McpCallFile -Root $callRoot -Agent 'agent-b' -Id 'b2' -Tool 'mcp__flaui-mcp__windows_click'
        Write-TestUtf8 -Path $start.Json.report_path -Text $testReport
        $bad = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot, '-AgentId', '..\agent-b')
        Assert-Equal 2 $bad.Code $bad.Stderr
        Assert-True ($null -eq (Get-RecordOf $start).ended_utc) '拒絕後紀錄應維持未結束'
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot, '-AgentId', 'agent-b')
        Assert-Equal 0 $end.Code $end.Stderr
        $calls = (Get-RecordOf $start).mcp_tool_calls
        Assert-Equal 2 $calls.completed
        Assert-Equal 'flaui-mcp,playwright' (@($calls.servers) -join ',')
        Assert-Equal 'agent' $calls.attribution
        Assert-Equal 1 @(Get-ChildItem -LiteralPath (Join-Path $callRoot 'agent-a') -File).Count '未採用的 agent 的檔案不動'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath (Join-Path $callRoot 'agent-b') -File).Count
    }
    Test-Case 'CR-TEST-AMBIGUOUS 省略 -AgentId 且多個 agent 在時間窗內都有紀錄：結束碼 2、訊息列出候選、紀錄維持未結束、呼叫紀錄檔都在；補 -AgentId 後可 End' {
        $callRoot = New-TestDirectory -Name 'mcp-calls-ambiguous'
        $testOrder = New-TestOrderFile
        $start = Start-TestRun -OrderPath $testOrder
        New-McpCallFile -Root $callRoot -Agent 'agent-a' -Id 'a1'
        New-McpCallFile -Root $callRoot -Agent 'agent-b' -Id 'b1'
        Write-TestUtf8 -Path $start.Json.report_path -Text $testReport
        $refused = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot)
        Assert-Equal 2 $refused.Code $refused.Stderr
        Assert-True ($refused.Stderr.Contains('ClaudeRunAgentAmbiguous') -and $refused.Stderr.Contains('agent-a') -and $refused.Stderr.Contains('agent-b')) ('訊息應列出候選：' + $refused.Stderr)
        Assert-True ($null -eq (Get-RecordOf $start).ended_utc) '紀錄應維持未結束'
        Assert-Equal 2 (@(Get-ChildItem -LiteralPath $callRoot -Recurse -File).Count) '呼叫紀錄檔不應被刪除'
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot, '-AgentId', 'agent-a')
        Assert-Equal 0 $end.Code $end.Stderr
        Assert-Equal 1 (Get-RecordOf $start).mcp_tool_calls.completed
    }
    Test-Case 'CR-TEST-WINDOW 時間窗之外的紀錄檔不計入也不刪除，且不造成歧義（Start 之前、End 之後的紀錄）' {
        $callRoot = New-TestDirectory -Name 'mcp-calls-window'
        $testOrder = New-TestOrderFile
        New-McpCallFile -Root $callRoot -Agent 'agent-old' -Id 'old1' -Time ([DateTime]::UtcNow.AddHours(-1))
        $start = Start-TestRun -OrderPath $testOrder
        New-McpCallFile -Root $callRoot -Agent 'agent-a' -Id 'a1'
        New-McpCallFile -Root $callRoot -Agent 'agent-future' -Id 'f1' -Time ([DateTime]::UtcNow.AddHours(1))
        Write-TestUtf8 -Path $start.Json.report_path -Text $testReport
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot)
        Assert-Equal 0 $end.Code $end.Stderr
        $calls = (Get-RecordOf $start).mcp_tool_calls
        Assert-Equal 1 $calls.completed
        Assert-Equal 'agent' $calls.attribution
        Assert-True ([IO.File]::Exists((Join-Path $callRoot 'agent-old\old1.json')) -and [IO.File]::Exists((Join-Path $callRoot 'agent-future\f1.json'))) '時間窗外的檔案不應被刪除'
    }
    Test-Case 'CR-TEST-NONE 沒有任何呼叫紀錄檔（根目錄不存在或為空）：completed 與 failed 為 0、servers 為空、attribution 為 none，result 仍依既有條件判定為 success' {
        $testOrder = New-TestOrderFile
        $missingRoot = Join-Path (New-TestDirectory -Name 'mcp-calls-none') 'does-not-exist'
        $start = Start-TestRun -OrderPath $testOrder
        Write-TestUtf8 -Path $start.Json.report_path -Text $testReport
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $missingRoot)
        Assert-Equal 0 $end.Code $end.Stderr
        Assert-Equal 'success' $end.Json.result
        $calls = (Get-RecordOf $start).mcp_tool_calls
        Assert-True ($calls.completed -eq 0 -and $calls.failed -eq 0 -and @($calls.servers).Count -eq 0 -and @($calls.tools).Count -eq 0 -and @($calls.calls).Count -eq 0 -and $calls.attribution -ceq 'none') '應為零呼叫與 none'
        $emptyRoot = New-TestDirectory -Name 'mcp-calls-empty'
        $start2 = Start-TestRun -OrderPath $testOrder
        Write-TestUtf8 -Path $start2.Json.report_path -Text $testReport
        $end2 = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $emptyRoot)
        Assert-Equal 0 $end2.Code $end2.Stderr
        Assert-Equal 'none' (Get-RecordOf $start2).mcp_tool_calls.attribution
    }
    Test-Case 'CR-TEST-MAIN 只有 _main 的紀錄時預設為 none（不採用）；加 -AllowWindowAttribution 才為 window 並採用、刪除該些檔案' {
        $callRoot = New-TestDirectory -Name 'mcp-calls-main'
        $testOrder = New-TestOrderFile
        $start = Start-TestRun -OrderPath $testOrder
        New-McpCallFile -Root $callRoot -Agent '_main' -Id 'm1'
        New-McpCallFile -Root $callRoot -Agent '_main' -Id 'm2'
        Write-TestUtf8 -Path $start.Json.report_path -Text $testReport
        $endDefault = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot)
        Assert-Equal 0 $endDefault.Code $endDefault.Stderr
        $calls = (Get-RecordOf $start).mcp_tool_calls
        Assert-True ($calls.completed -eq 0 -and $calls.attribution -ceq 'none') '預設不採用 _main'
        Assert-Equal 2 @(Get-ChildItem -LiteralPath (Join-Path $callRoot '_main') -File).Count
        $start2 = Start-TestRun -OrderPath $testOrder
        New-McpCallFile -Root $callRoot -Agent '_main' -Id 'm3'
        Write-TestUtf8 -Path $start2.Json.report_path -Text $testReport
        $endWindow = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot, '-AllowWindowAttribution')
        Assert-Equal 0 $endWindow.Code $endWindow.Stderr
        $windowCalls = (Get-RecordOf $start2).mcp_tool_calls
        Assert-True ($windowCalls.completed -eq 1 -and $windowCalls.attribution -ceq 'window') ('應為 window 且只計時間窗內的 1 筆：' + ($windowCalls | ConvertTo-Json -Compress))
        Assert-True (-not [IO.File]::Exists((Join-Path $callRoot '_main\m3.json'))) '採用的檔案應刪除'
    }
    Test-Case 'CR-TEST-MAIN-ID 明示 -AgentId 為 _main（含大小寫不同）：結束碼 2、訊息為 ClaudeRunAgentIdReserved 並指向 -AllowWindowAttribution、紀錄維持未結束、_main 的檔案不動；改用 -AllowWindowAttribution 才取得 window' {
        $callRoot = New-TestDirectory -Name 'mcp-calls-main-id'
        $testOrder = New-TestOrderFile
        $start = Start-TestRun -OrderPath $testOrder
        New-McpCallFile -Root $callRoot -Agent '_main' -Id 'm1'
        Write-TestUtf8 -Path $start.Json.report_path -Text $testReport
        foreach ($id in @('_main', '_MAIN')) {
            $refused = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot, '-AgentId', $id)
            Assert-Equal 2 $refused.Code $refused.Stderr
            Assert-True ($refused.Stderr.Contains('ClaudeRunAgentIdReserved') -and $refused.Stderr.Contains('-AllowWindowAttribution')) ('訊息應說明 _main 的取得方式：' + $refused.Stderr)
            Assert-True ($null -eq (Get-RecordOf $start).ended_utc) '拒絕後紀錄應維持未結束'
            Assert-Equal 1 @(Get-ChildItem -LiteralPath (Join-Path $callRoot '_main') -File).Count '拒絕時 _main 的檔案不動'
        }
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot, '-AllowWindowAttribution')
        Assert-Equal 0 $end.Code $end.Stderr
        $calls = (Get-RecordOf $start).mcp_tool_calls
        Assert-True ($calls.completed -eq 1 -and $calls.attribution -ceq 'window') ('應為 window：' + ($calls | ConvertTo-Json -Compress))
    }
    Test-Case 'CR-TEST-MAIN-ID-NOROOT 紀錄根目錄不存在時，明示 -AgentId 為 _main 仍以 ClaudeRunAgentIdReserved（結束碼 2）拒絕，紀錄維持未結束' {
        $callRoot = Join-Path (New-TestDirectory -Name 'mcp-calls-noroot') 'absent'
        $testOrder = New-TestOrderFile
        $start = Start-TestRun -OrderPath $testOrder
        Write-TestUtf8 -Path $start.Json.report_path -Text $testReport
        $refused = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot, '-AgentId', '_main')
        Assert-Equal 2 $refused.Code $refused.Stderr
        Assert-True ($refused.Stderr.Contains('ClaudeRunAgentIdReserved')) ('應為保留 id 拒絕：' + $refused.Stderr)
        Assert-True ($null -eq (Get-RecordOf $start).ended_utc) '拒絕後紀錄應維持未結束'
    }
    Test-Case 'CR-TEST-ARRAY-AGENT 紀錄檔的 agent_id 為單元素陣列時不展開成字串：計入 skipped，不採用也不刪除' {
        $callRoot = New-TestDirectory -Name 'mcp-calls-array-agent'
        $testOrder = New-TestOrderFile
        $start = Start-TestRun -OrderPath $testOrder
        New-McpCallFile -Root $callRoot -Agent 'agent-a' -Id 'arr'
        $path = Join-Path $callRoot 'agent-a\arr.json'
        $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $document['agent_id'] = @('agent-a')
        Write-TestUtf8 -Path $path -Text ($document | ConvertTo-Json -Depth 4)
        Assert-True ((Get-Content -LiteralPath $path -Raw) -match '"agent_id":\s*\[') '前置：agent_id 應寫成陣列'
        Write-TestUtf8 -Path $start.Json.report_path -Text $testReport
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot, '-AgentId', 'agent-a')
        Assert-Equal 0 $end.Code $end.Stderr
        $calls = (Get-RecordOf $start).mcp_tool_calls
        Assert-True ($calls.completed -eq 0 -and $calls.skipped -eq 1) ('陣列 agent_id 應計入 skipped：' + ($calls | ConvertTo-Json -Compress))
        Assert-True ([IO.File]::Exists($path)) '未採用的檔案不刪除'
    }
    Test-Case 'CR-TEST-ARRAY-FIELDS 紀錄檔的 status、tool_name、server、ts_utc 任一為單元素陣列時計入 skipped；名為 _MAIN 的目錄不參與自動歸屬' {
        foreach ($field in @('status', 'tool_name', 'server', 'ts_utc')) {
            $callRoot = New-TestDirectory -Name ('mcp-calls-array-' + $field.Replace('_', '-'))
            $testOrder = New-TestOrderFile
            $start = Start-TestRun -OrderPath $testOrder
            New-McpCallFile -Root $callRoot -Agent 'agent-a' -Id 'arr'
            $path = Join-Path $callRoot 'agent-a\arr.json'
            $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
            $document[$field] = @([string]$document[$field])
            Write-TestUtf8 -Path $path -Text ($document | ConvertTo-Json -Depth 4)
            Write-TestUtf8 -Path $start.Json.report_path -Text $testReport
            $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot, '-AgentId', 'agent-a')
            Assert-Equal 0 $end.Code $end.Stderr
            $calls = (Get-RecordOf $start).mcp_tool_calls
            Assert-True ($calls.completed -eq 0 -and $calls.skipped -eq 1) ($field + ' 為陣列時應計入 skipped：' + ($calls | ConvertTo-Json -Compress))
        }
        $callRoot = New-TestDirectory -Name 'mcp-calls-upper-main'
        $testOrder = New-TestOrderFile
        $start = Start-TestRun -OrderPath $testOrder
        New-McpCallFile -Root $callRoot -Agent '_MAIN' -Id 'upper'
        $path = Join-Path $callRoot '_MAIN\upper.json'
        $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $document['agent_id'] = '_MAIN'
        Write-TestUtf8 -Path $path -Text ($document | ConvertTo-Json -Depth 4)
        Write-TestUtf8 -Path $start.Json.report_path -Text $testReport
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot)
        Assert-Equal 0 $end.Code $end.Stderr
        $calls = (Get-RecordOf $start).mcp_tool_calls
        Assert-True ($calls.attribution -cne 'agent' -and $calls.completed -eq 0) ('_MAIN 不應被當作 agent：' + ($calls | ConvertTo-Json -Compress))
    }
    Test-Case 'CR-TEST-ARRAY-ROOT 紀錄檔根層為單元素陣列時計入 skipped，不採用也不刪除' {
        $callRoot = New-TestDirectory -Name 'mcp-calls-array-root'
        $testOrder = New-TestOrderFile
        $start = Start-TestRun -OrderPath $testOrder
        New-McpCallFile -Root $callRoot -Agent 'agent-a' -Id 'root'
        $path = Join-Path $callRoot 'agent-a\root.json'
        Write-TestUtf8 -Path $path -Text ('[' + (Get-Content -LiteralPath $path -Raw) + ']')
        Write-TestUtf8 -Path $start.Json.report_path -Text $testReport
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot, '-AgentId', 'agent-a')
        Assert-Equal 0 $end.Code $end.Stderr
        $calls = (Get-RecordOf $start).mcp_tool_calls
        Assert-True ($calls.completed -eq 0 -and $calls.skipped -eq 1) ('根層陣列應計入 skipped：' + ($calls | ConvertTo-Json -Compress))
        Assert-True ([IO.File]::Exists($path)) '未採用的檔案不刪除'
    }
    Test-Case 'CR-TEST-DIRMISMATCH 檔案內的 agent_id 與所在目錄不符（agent 目錄內是別的 agent、_main 目錄內有 agent_id）：計入 skipped，不計入 completed、failed、servers，也不刪除' {
        $callRoot = New-TestDirectory -Name 'mcp-calls-dirmismatch'
        $testOrder = New-TestOrderFile
        $start = Start-TestRun -OrderPath $testOrder
        New-McpCallFile -Root $callRoot -Agent 'agent-a' -Id 'good'
        New-McpCallFile -Root $callRoot -Agent 'agent-a' -Id 'wrong'
        New-McpCallFile -Root $callRoot -Agent '_main' -Id 'mainwrong'
        foreach ($entry in @(@{ Path = (Join-Path $callRoot 'agent-a\wrong.json'); Agent = 'agent-b' }, @{ Path = (Join-Path $callRoot '_main\mainwrong.json'); Agent = 'agent-c' })) {
            $document = Get-Content -LiteralPath $entry.Path -Raw | ConvertFrom-Json -AsHashtable
            $document['agent_id'] = $entry.Agent
            Write-TestUtf8 -Path $entry.Path -Text ($document | ConvertTo-Json -Depth 4)
        }
        Write-TestUtf8 -Path $start.Json.report_path -Text $testReport
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot, '-AgentId', 'agent-a')
        Assert-Equal 0 $end.Code $end.Stderr
        $calls = (Get-RecordOf $start).mcp_tool_calls
        Assert-True ($calls.completed -eq 1 -and $calls.failed -eq 0 -and $calls.skipped -eq 1 -and $calls.attribution -ceq 'agent') ('只應採用目錄與 agent_id 相符的 1 筆：' + ($calls | ConvertTo-Json -Compress))
        Assert-True ([IO.File]::Exists((Join-Path $callRoot 'agent-a\wrong.json'))) '不符的檔案不刪除'
        Assert-True (-not [IO.File]::Exists((Join-Path $callRoot 'agent-a\good.json'))) '採用的檔案應刪除'
        # 省略 -AgentId：agent 目錄只剩不符的檔案時沒有可歸屬的紀錄；_main 內帶 agent_id 的檔案同樣不採用為 window。
        $start2 = Start-TestRun -OrderPath $testOrder
        New-McpCallFile -Root $callRoot -Agent 'agent-a' -Id 'wrong2'
        New-McpCallFile -Root $callRoot -Agent '_main' -Id 'mainwrong2'
        foreach ($entry in @(@{ Path = (Join-Path $callRoot 'agent-a\wrong2.json'); Agent = 'agent-b' }, @{ Path = (Join-Path $callRoot '_main\mainwrong2.json'); Agent = 'agent-c' })) {
            $document = Get-Content -LiteralPath $entry.Path -Raw | ConvertFrom-Json -AsHashtable
            $document['agent_id'] = $entry.Agent
            Write-TestUtf8 -Path $entry.Path -Text ($document | ConvertTo-Json -Depth 4)
        }
        Write-TestUtf8 -Path $start2.Json.report_path -Text $testReport
        $end2 = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot, '-AllowWindowAttribution')
        Assert-Equal 0 $end2.Code $end2.Stderr
        $calls2 = (Get-RecordOf $start2).mcp_tool_calls
        Assert-True ($calls2.completed -eq 0 -and $calls2.attribution -ceq 'none' -and $calls2.skipped -ge 2) ('時間窗內不符的檔案不得歸為 agent 或 window：' + ($calls2 | ConvertTo-Json -Compress))
        Assert-True ([IO.File]::Exists((Join-Path $callRoot '_main\mainwrong2.json'))) '不符的檔案不刪除'
    }
    Test-Case 'CR-TEST-SKIPPED 無法剖析、欄位缺少或時間不可解析的呼叫紀錄檔：略過並計入 skipped，不計入 completed 與 failed，也不刪除' {
        $callRoot = New-TestDirectory -Name 'mcp-calls-skipped'
        $testOrder = New-TestOrderFile
        $start = Start-TestRun -OrderPath $testOrder
        New-McpCallFile -Root $callRoot -Agent 'agent-a' -Id 'ok1'
        $directory = Join-Path $callRoot 'agent-a'
        Write-TestUtf8 -Path (Join-Path $directory 'broken.json') -Text '{ not json'
        Write-TestUtf8 -Path (Join-Path $directory 'nofield.json') -Text '{"schema":"ai-agents.mcp-call.v1","tool_name":"mcp__playwright__x"}'
        Write-TestUtf8 -Path (Join-Path $directory 'badtime.json') -Text '{"tool_name":"mcp__playwright__x","server":"playwright","status":"completed","ts_utc":"not-a-time"}'
        Write-TestUtf8 -Path $start.Json.report_path -Text $testReport
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $testOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot)
        Assert-Equal 0 $end.Code $end.Stderr
        $calls = (Get-RecordOf $start).mcp_tool_calls
        Assert-True ($calls.completed -eq 1 -and $calls.failed -eq 0 -and $calls.skipped -eq 3) ('應 completed 1、skipped 3：' + ($calls | ConvertTo-Json -Compress))
        Assert-True ([IO.File]::Exists((Join-Path $directory 'broken.json'))) '略過的檔案不應被刪除'
    }
    Test-Case 'CR-TEST-STRAY .playwright-mcp 在 Start 與 End 之間新增或變動的檔案記入 mcp_stray_output（先前殘留的不算）；該目錄不納入來源雜湊，不使 result 失敗' {
        $projectRoot = Join-Path (New-TestDirectory -Name 'stray-project') 'proj'
        $null = New-Item -ItemType Directory -Path (Join-Path $projectRoot '.playwright-mcp') -Force
        Write-TestUtf8 -Path (Join-Path $projectRoot 'page.html') -Text '<html></html>'
        Write-TestUtf8 -Path (Join-Path $projectRoot '.playwright-mcp\old.png') -Text 'old'
        $strayRole = Join-Path $projectRoot 'role.toml'
        Write-TestUtf8 -Path $strayRole -Text 'role'
        $strayOrder = New-TestOrderFile -Name 'order-stray.md' -Override @{ execution_root = $projectRoot; targets = @($projectRoot); role_file = $strayRole }
        Remove-Runs
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $strayOrder, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $start.Code $start.Stderr
        Write-TestUtf8 -Path (Join-Path $projectRoot '.playwright-mcp\new.png') -Text 'new'
        Write-TestUtf8 -Path $start.Json.report_path -Text $testReport
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $strayOrder, '-ExecutorId', 'sonnet', '-McpCallRoot', (Join-Path (New-TestDirectory -Name 'stray-calls') 'none'))
        Assert-Equal 0 $end.Code $end.Stderr
        Assert-Equal 'success' $end.Json.result
        Assert-Equal $false $end.Json.source_changed
        $stray = (Get-RecordOf $start).mcp_stray_output
        Assert-True ($stray.exists -eq $true -and $stray.state -ceq 'determined' -and (@($stray.files) -join ',') -ceq 'new.png') ('應只記新增的 new.png：' + ($stray | ConvertTo-Json -Compress))
    }
    Test-Case 'CR-TEST-NONTEST 非 test 類型（review）的紀錄三個新鍵為 null，不讀取呼叫紀錄；review 的 End 不受 -McpCallRoot 影響' {
        $callRoot = New-TestDirectory -Name 'mcp-calls-review'
        New-McpCallFile -Root $callRoot -Agent 'agent-a' -Id 'r1'
        Remove-Runs
        Write-TestUtf8 -Path $target -Text 'v1'
        $start = Invoke-Script $recordScript @('-Action', 'Start', '-DispatchFile', $order, '-ExecutorId', 'sonnet')
        Assert-Equal 0 $start.Code $start.Stderr
        Write-TestUtf8 -Path $start.Json.report_path -Text $validReport
        $end = Invoke-Script $recordScript @('-Action', 'End', '-DispatchFile', $order, '-ExecutorId', 'sonnet', '-McpCallRoot', $callRoot)
        Assert-Equal 0 $end.Code $end.Stderr
        $record = Get-RecordOf $start
        foreach ($field in @('mcp_tool_calls', 'artifacts', 'mcp_stray_output')) {
            Assert-True ($null -ne $record.PSObject.Properties[$field]) ('審查紀錄應有欄位 ' + $field)
            Assert-True ($null -eq $record.$field) ($field + ' 應為 null')
        }
        Assert-True ($null -eq $end.Json.PSObject.Properties['mcp_tool_calls']) '審查的 End 輸出不應含 mcp_tool_calls'
        Assert-True ([IO.File]::Exists((Join-Path $callRoot 'agent-a\r1.json'))) '審查不應刪除呼叫紀錄檔'
    }
}
finally {
    $exitCode = Complete-TestRun
}
exit $exitCode
