#Requires -Version 7.0
# 一次發動的流程編排：派遣檔、啟動前檢查、MXC 偵測、逐帳號嘗試、紀錄、成本列與結果文件。
# 依賴 00 至 60 各模組，由 scripts\Invoke-CodexRun.ps1 載入。

function Write-RunDiagnostic {
    param([Parameter(Mandatory)][string]$Message)

    [Console]::Error.WriteLine($Message)
}

function New-RunPrompt {
    param(
        [Parameter(Mandatory)][object]$Order,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$ReportPath
    )

    $lines = @(
        'LineContext'
        ('- lineSlug: ' + $Order.line_slug)
        ('- dispatchLineRoot: ' + (Split-Path -Parent $Order.dispatch_file_path))
        ('- reportLineRoot: ' + $Order.report_line_root)
        ('- executionRoot: ' + $Order.execution_root)
        ('輸出目錄: ' + $OutputDirectory)
        ('報告檔: ' + $ReportPath)
        ''
        ('請以 Reviewer 身分，先完整讀取角色規則檔 `' + $Order.role_file + '`，再讀取派遣檔 `' + $Order.dispatch_file_path + '` 依其內容執行。')
    )
    return (($lines -join "`n") + "`n")
}

function Test-RunGitRepository {
    param([Parameter(Mandatory)][string]$Directory)

    try {
        $probe = Invoke-RunGitBytes -WorkingDirectory $Directory -Argument @('rev-parse', '--is-inside-work-tree')
        return $probe.ExitCode -eq 0
    }
    catch { return $false }
}

function ConvertTo-RunIsoTime {
    param([Parameter(Mandatory)][DateTime]$Value)

    return $Value.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
}

function Invoke-RunAttempt {
    param(
        [Parameter(Mandatory)][object]$Order,
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][string]$CodexPath,
        [Parameter(Mandatory)][string]$MachineConfigPath,
        [Parameter(Mandatory)][string]$DispatchSha256,
        [Parameter(Mandatory)][bool]$IsGitRepository,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][int]$TurnEndGraceSeconds
    )

    # 一個帳號一次嘗試，各自有獨立的 runKey、輸出目錄、紀錄與成本列。
    $runId = New-RunId
    $runKey = $Order.dispatch_slug + '-' + $runId
    $runsDirectory = Join-Path $Order.report_line_root 'runs'
    $outputDirectory = Join-Path $runsDirectory $runKey
    $recordPath = Join-Path $runsDirectory ($runKey + '.record.json')
    $eventsPath = Join-Path $runsDirectory ($runKey + '.events.jsonl')
    $stderrPath = Join-Path $runsDirectory ($runKey + '.stderr.txt')
    $lastMessagePath = Join-Path $runsDirectory ($runKey + '.last-message.md')
    $reportPath = Join-Path $outputDirectory $Order.report_name
    $null = [IO.Directory]::CreateDirectory($outputDirectory)

    $plan = Get-RunPermissionPlan -ExecutionRoot $Order.execution_root -OutputDirectory $outputDirectory -ReportLineRoot $Order.report_line_root
    $permission = [ordered]@{ name = $plan.name; read_roots = @($plan.read_roots); write_roots = @($plan.write_roots); deny_patterns = @($plan.deny_patterns) }
    $startedAt = [DateTime]::UtcNow
    $sourceStart = Get-RunSourceState -ExecutionRoot $Order.execution_root -Target $Order.targets -ExcludeRoot @($Order.report_line_root)
    $record = [ordered]@{
        schema = 'ai-agents.codex-run-record.v1'
        run_key = $runKey
        run_id = $runId
        line_slug = $Order.line_slug
        dispatch_slug = $Order.dispatch_slug
        task_type = $Order.task_type
        profile = $Order.profile
        dispatch_file = [ordered]@{ path = $Order.dispatch_file_path; sha256 = $DispatchSha256 }
        account = [ordered]@{ name = $Candidate.name; codex_home = $Candidate.codex_home }
        model = $Candidate.model
        execution_root = $Order.execution_root
        output_dir = $outputDirectory
        report_path = $reportPath
        started_utc = ConvertTo-RunIsoTime -Value $startedAt
        ended_utc = $null
        duration_seconds = $null
        source_state_start = $sourceStart
        source_state_end = $null
        source_changed = $null
        exit_code = $null
        result = $null
        failure_reason = $null
        terminated_by_entry = $null
        rejection_kind = $null
        item_event_count = $null
        usage = $null
        last_message = [ordered]@{ path = $lastMessagePath; exists = $null; empty = $null }
        events_path = $eventsPath
        stderr_path = $stderrPath
        report = $null
        review_report_check = $null
        permission = $permission
    }
    try { Write-RunJsonAtomic -Path $recordPath -InputObject $record -Depth 8 }
    catch { throw (New-RunError -Code 'RunRecordWriteFailed' -Message ('執行紀錄初稿寫入失敗：' + $_.Exception.Message) -ExitCode 1) }

    $argument = New-RunExecArgument -ExecutionRoot $Order.execution_root -Profile $Order.profile -OutputDirectory $outputDirectory -LastMessagePath $lastMessagePath -IsGitRepository $IsGitRepository -ReportLineRoot $Order.report_line_root
    $prompt = New-RunPrompt -Order $Order -OutputDirectory $outputDirectory -ReportPath $reportPath
    Write-RunDiagnostic ('[codex-run] 嘗試帳號 ' + $Candidate.name + '，runKey ' + $runKey)
    $exitCode = -1
    $duration = 0.0
    $launchFailed = $false
    $terminatedBy = $null
    try {
        $process = Invoke-RunCodexProcess -CodexPath $CodexPath -Argument $argument -Prompt $prompt -CodexHome $Candidate.codex_home -EventStreamPath $eventsPath -StderrPath $stderrPath -WorkingDirectory $Order.execution_root `
            -LastMessagePath $lastMessagePath -TimeoutSeconds $TimeoutSeconds -TurnEndGraceSeconds $TurnEndGraceSeconds
        $exitCode = [int]$process.ExitCode
        $duration = [double]$process.DurationSeconds
        $terminatedBy = $process.TerminatedBy
    }
    catch {
        if ($_.Exception.Data.Contains('Code')) { throw }
        $launchFailed = $true
        $duration = ([DateTime]::UtcNow - $startedAt).TotalSeconds
        Write-RunDiagnostic ('[codex-run] codex 行程無法啟動：' + $_.Exception.Message)
    }
    $endedAt = [DateTime]::UtcNow
    $sourceEnd = Get-RunSourceState -ExecutionRoot $Order.execution_root -Target $Order.targets -ExcludeRoot @($Order.report_line_root)
    $sourceChanged = (ConvertTo-Json -InputObject $sourceStart -Compress) -cne (ConvertTo-Json -InputObject $sourceEnd -Compress)

    if ($terminatedBy -ceq 'timeout') { Write-RunDiagnostic ('[codex-run] 超過總時限 ' + $TimeoutSeconds + ' 秒，已終止 codex 行程樹。') }
    if ($terminatedBy -ceq 'after-turn-end') { Write-RunDiagnostic ('[codex-run] 回合結束後 ' + $TurnEndGraceSeconds + ' 秒 codex 行程仍未結束，已由入口終止，結果依報告判定。') }
    # 被入口終止的行程，結束碼是終止所致，不拿來判讀事件流。
    $evidence = Get-RunEventEvidence -EventStreamPath $eventsPath -StderrPath $stderrPath -ExitCode $(if ($launchFailed -or $null -ne $terminatedBy) { $null } else { $exitCode })
    $judged = Get-RunResult -ExitCode $exitCode -LastMessagePath $lastMessagePath -ReportPath $reportPath -Evidence $evidence -TimedOut:($terminatedBy -ceq 'timeout') -TerminatedAfterTurnEnd:($terminatedBy -ceq 'after-turn-end')
    $result = $judged.result
    $failureReason = $judged.failure_reason
    if ($launchFailed) { $result = 'failed'; $failureReason = 'launch-failed' }
    $reviewCheck = $null
    if ($result -ceq 'success' -and $Order.task_type -ceq 'review') {
        $checked = Test-RunReviewReport -ReportPath $reportPath
        $reviewCheck = [ordered]@{ valid = $checked.valid; errors = @($checked.errors) }
    }

    $healthError = $null
    try {
        if ($result -ceq 'rejected' -and $evidence.rejection_kind -ceq 'model-not-supported' -and (Test-RunFailoverEligible -Evidence $evidence)) {
            $null = Register-RunAccountHealth -AccountName $Candidate.name -CodexHome $Candidate.codex_home -Profile $Order.profile -Model $Candidate.model -ReasonCode 'model-not-supported' -MachineConfigPath $MachineConfigPath `
                -Evidence ([ordered]@{ dispatch_slug = $Order.dispatch_slug; run_key = $runKey; event_stream_path = $eventsPath })
        }
        elseif ($result -ceq 'success') {
            $null = Clear-RunAccountHealth -AccountName $Candidate.name -CodexHome $Candidate.codex_home -Profile $Order.profile -Model $Candidate.model -MachineConfigPath $MachineConfigPath
        }
    }
    catch {
        $healthError = $_.Exception.Message
        Write-RunDiagnostic ('[codex-run] 帳號健康狀態寫入失敗，不影響派遣結果：' + $healthError)
    }

    $lastMessageInfo = New-Object System.IO.FileInfo -ArgumentList @($lastMessagePath)
    $reportInfo = New-Object System.IO.FileInfo -ArgumentList @($reportPath)
    $record['ended_utc'] = ConvertTo-RunIsoTime -Value $endedAt
    $record['duration_seconds'] = $duration
    $record['source_state_end'] = $sourceEnd
    $record['source_changed'] = $sourceChanged
    $record['exit_code'] = if ($launchFailed) { $null } else { $exitCode }
    $record['result'] = $result
    $record['failure_reason'] = $failureReason
    $record['terminated_by_entry'] = $terminatedBy
    $record['rejection_kind'] = $evidence.rejection_kind
    $record['item_event_count'] = $evidence.item_event_count
    $record['usage'] = $evidence.usage
    $record['last_message'] = [ordered]@{ path = $lastMessagePath; exists = $lastMessageInfo.Exists; empty = (-not $lastMessageInfo.Exists) -or $lastMessageInfo.Length -eq 0 }
    $record['report'] = [ordered]@{ exists = $reportInfo.Exists; bytes = if ($reportInfo.Exists) { $reportInfo.Length } else { 0 } }
    $record['review_report_check'] = $reviewCheck
    try {
        Write-RunJsonAtomic -Path $recordPath -InputObject $record -Depth 8
        $null = Add-RunCostRow -LedgerPath (Join-Path $Order.report_line_root 'cost-ledger.md') -LineSlug $Order.line_slug -DispatchSlug $Order.dispatch_slug -RunId $runId `
            -Cycle $Order.cycle -DurationSeconds $duration -Usage $evidence.usage -ExitCode $exitCode -Result $result -TaskType $Order.task_type -AccountName $Candidate.name `
            -RejectionKind $evidence.rejection_kind -EndedUtc $endedAt
    }
    catch {
        throw (New-RunError -Code 'RunRecordWriteFailed' -Message ('執行紀錄或成本列寫入失敗，已完成的報告保留於 ' + $reportPath + '：' + $_.Exception.Message) -ExitCode 1)
    }

    $reloginCommand = $null
    if ($evidence.rejection_kind -ceq 'unauthorized') { $reloginCommand = Get-RunReloginCommand -CodexHome $Candidate.codex_home }
    return [pscustomobject]@{
        run_key = $runKey
        account = $Candidate.name
        result = $result
        failure_reason = $failureReason
        rejection_kind = $evidence.rejection_kind
        record_path = $recordPath
        report_path = $reportPath
        last_message_path = $lastMessagePath
        events_path = $eventsPath
        stderr_path = $stderrPath
        source_changed = $sourceChanged
        review_report_check = $reviewCheck
        relogin_command = $reloginCommand
        failover_eligible = (Test-RunFailoverEligible -Evidence $evidence)
        health_error = $healthError
    }
}

function Invoke-CodexRunMain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DispatchFile,

        [string]$CodexPath,

        [string]$MachineConfigPath,

        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds = 1800,

        # 回合結束後的寬限秒數。入口不對外提供，供測試縮短。
        [ValidateRange(0, 3600)]
        [int]$TurnEndGraceSeconds = 60
    )

    # 回傳 ExitCode 與 Document（ai-agents.codex-run-result.v1）。診斷行寫 stderr，結果文件由入口輸出到 stdout。
    $attempts = New-Object 'System.Collections.Generic.List[object]'
    $final = $null
    $errorInfo = $null
    $status = 'stopped'
    $exitCode = 1
    try {
        if (-not [OperatingSystem]::IsWindows()) {
            throw (New-RunError -Code 'RunPlatformUnsupported' -Message '新入口只支援 Windows（MXC 沙盒）。' -ExitCode 3)
        }
        $dispatchPath = [IO.Path]::GetFullPath($DispatchFile)
        $order = Read-RunDispatchFile -Path $dispatchPath
        Test-RunPreStart -Order $order
        $codex = Get-RunCodexPath -ConfiguredPath $CodexPath
        $machinePath = $MachineConfigPath
        if ([string]::IsNullOrWhiteSpace($machinePath)) { $machinePath = Resolve-RunMachineConfigPath }
        $selection = Get-RunAccountCandidate -Profile $order.profile -MachineConfigPath $machinePath
        if (@($selection.candidates).Count -eq 0) {
            throw (New-RunError -Code 'CodexAccountsAllUnavailable' -Message ('所有登記帳號都不可用：' + (Format-RunAccountSkippedSummary -Skipped $selection.skipped)) -ExitCode 4)
        }
        foreach ($skippedItem in @($selection.skipped)) {
            Write-RunDiagnostic ('[codex-run] 略過帳號 ' + $skippedItem.name + '：' + $skippedItem.reason_code)
        }
        if (-not (Test-RunMxc -CodexPath $codex -CodexHome $selection.candidates[0].codex_home)) {
            throw (New-RunError -Code 'RunMxcUnavailable' -Message '偵測不到 MXC 沙盒（codex sandbox 探針失敗）。新入口不改用其他沙盒，也不在沒有沙盒的情況下啟動 Codex。' -ExitCode 3)
        }
        $null = [IO.Directory]::CreateDirectory((Join-Path $order.report_line_root 'runs'))
        $dispatchSha = Get-RunSha256File -Path $dispatchPath
        $isGit = Test-RunGitRepository -Directory $order.execution_root

        $lastAttempt = $null
        $exhausted = $false
        foreach ($candidate in @($selection.candidates)) {
            $lastAttempt = Invoke-RunAttempt -Order $order -Candidate $candidate -CodexPath $codex -MachineConfigPath $machinePath -DispatchSha256 $dispatchSha -IsGitRepository $isGit -TimeoutSeconds $TimeoutSeconds -TurnEndGraceSeconds $TurnEndGraceSeconds
            $attempts.Add([ordered]@{
                    run_key = $lastAttempt.run_key
                    account = $lastAttempt.account
                    result = $lastAttempt.result
                    rejection_kind = $lastAttempt.rejection_kind
                    record_path = $lastAttempt.record_path
                    relogin_command = $lastAttempt.relogin_command
                })
            $final = [ordered]@{
                run_key = $lastAttempt.run_key
                report_path = $lastAttempt.report_path
                record_path = $lastAttempt.record_path
                last_message_path = $lastAttempt.last_message_path
                events_path = $lastAttempt.events_path
                stderr_path = $lastAttempt.stderr_path
                source_changed = $lastAttempt.source_changed
                review_report_check = $lastAttempt.review_report_check
                relogin_command = $lastAttempt.relogin_command
            }
            if ($lastAttempt.result -ceq 'rejected' -and $lastAttempt.failover_eligible) {
                $exhausted = $true
                continue
            }
            $exhausted = $false
            break
        }
        if ($exhausted) {
            throw (New-RunError -Code 'CodexAccountsExhausted' -Message ('所有候選帳號都被服務端拒絕：' + (@($attempts | ForEach-Object { $_.account + ':' + $_.rejection_kind }) -join '; ')) -ExitCode 4)
        }
        $status = [string]$lastAttempt.result
        $exitCode = if ($status -ceq 'success') { 0 } else { 1 }
        if ($null -ne $lastAttempt.health_error) {
            $errorInfo = [ordered]@{ code = 'CodexAccountHealthWriteFailed'; message = [string]$lastAttempt.health_error; details = @() }
        }
    }
    catch {
        $exception = $_.Exception
        if ($exception.Data.Contains('Code')) {
            $errorInfo = [ordered]@{ code = [string]$exception.Data['Code']; message = $exception.Message; details = @($exception.Data['Details']) }
            $exitCode = [int]$exception.Data['ExitCode']
        }
        else {
            $errorInfo = [ordered]@{ code = 'RunUnexpectedError'; message = $exception.Message; details = @() }
            $exitCode = 1
        }
        $status = 'stopped'
        $pathDetails = @(@($errorInfo.details) | Where-Object { $_ -is [pscustomobject] -and $null -ne $_.PSObject.Properties['path'] })
        if ($pathDetails.Count -gt 0) {
            # 訊息本文已含每個路徑，stderr 改為摘要加逐行明細，每個路徑只出現一次。
            Write-RunDiagnostic ('[codex-run] ' + $errorInfo.code + '：' + $pathDetails.Count + ' 個路徑不合格')
            foreach ($detail in $pathDetails) { Write-RunDiagnostic ('[codex-run]   ' + $detail.path + ' (' + $detail.reason + ')') }
        }
        else {
            Write-RunDiagnostic ('[codex-run] ' + $errorInfo.message)
        }
    }
    $document = [ordered]@{
        schema = 'ai-agents.codex-run-result.v1'
        status = $status
        exit_code = $exitCode
        error = $errorInfo
        attempts = @($attempts.ToArray())
        final = $final
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Document = $document }
}
