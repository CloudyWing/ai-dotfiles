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
        $changed = New-OrderFile -Name 'order.md' -Override @{ task_type = 'factcheck'; profile = 'content' }
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
}
finally {
    $exitCode = Complete-TestRun
}
exit $exitCode
