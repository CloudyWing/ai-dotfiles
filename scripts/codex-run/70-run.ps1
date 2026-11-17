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
        [Parameter(Mandatory)][string]$ReportPath,
        [AllowNull()][AllowEmptyString()][string]$ReviewerLine
    )

    # 「審查者:」行由審查者照抄到報告「## 總覽」第一行，使報告標明實際執行者與 model。
    $lines = @(
        'LineContext'
        ('- lineSlug: ' + $Order.line_slug)
        ('- dispatchLineRoot: ' + (Split-Path -Parent $Order.dispatch_file_path))
        ('- reportLineRoot: ' + $Order.report_line_root)
        ('- executionRoot: ' + $Order.execution_root)
        ('輸出目錄: ' + $OutputDirectory)
        ('報告檔: ' + $ReportPath)
        if (-not [string]::IsNullOrWhiteSpace($ReviewerLine)) { '審查者: ' + $ReviewerLine }
        ''
        ('請依角色規則檔 `' + $Order.role_file + '` 定義的審查角色，先完整讀取該檔，再讀取派遣檔 `' + $Order.dispatch_file_path + '` 依其內容執行。')
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
        [Parameter(Mandatory)][int]$TurnEndGraceSeconds,
        [AllowNull()][AllowEmptyString()][string]$ExecutorDisplay
    )

    # 一個帳號搭配一個 model 的一次嘗試，各自有獨立的 runKey、輸出目錄、紀錄與成本列。
    # Candidate.model 是本次實際使用的 model；與 Candidate.primary_model 不同時為備援 model，以 -c model= 覆寫檔位設定。
    $modelSource = 'primary'
    $modelOverride = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Candidate.model) -and [string]$Candidate.model -cne [string]$Candidate.primary_model) {
        $modelSource = 'fallback'
        $modelOverride = [string]$Candidate.model
    }
    $reviewerLine = $null
    if (-not [string]::IsNullOrWhiteSpace($ExecutorDisplay)) {
        $reviewerLine = $ExecutorDisplay
        if (-not [string]::IsNullOrWhiteSpace([string]$Candidate.model)) { $reviewerLine += '；model: ' + [string]$Candidate.model + $(if ($modelSource -ceq 'fallback') { '（備援）' } else { '' }) }
    }
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
        model_source = $modelSource
        execution_root = $Order.execution_root
        output_dir = $outputDirectory
        report_path = $reportPath
        started_utc = ConvertTo-RunIsoTime -Value $startedAt
        # 本次實際套用的時限。初稿就寫入，執行中的派工可由紀錄判斷是否已超過時限，不必推測入口的預設值。
        timeout_seconds = [int]$TimeoutSeconds
        turn_end_grace_seconds = [int]$TurnEndGraceSeconds
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

    $argument = New-RunExecArgument -ExecutionRoot $Order.execution_root -Profile $Order.profile -OutputDirectory $outputDirectory -LastMessagePath $lastMessagePath -IsGitRepository $IsGitRepository -ReportLineRoot $Order.report_line_root -ModelOverride $modelOverride
    $prompt = New-RunPrompt -Order $Order -OutputDirectory $outputDirectory -ReportPath $reportPath -ReviewerLine $reviewerLine
    Write-RunDiagnostic ('[codex-run] 嘗試帳號 ' + $Candidate.name + $(if ($modelSource -ceq 'fallback') { '（備援 model ' + $modelOverride + '）' } else { '' }) + '，runKey ' + $runKey)
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
        model = $Candidate.model
        model_source = $modelSource
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

function Assert-RunProfileConsistency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Profile,

        [Parameter(Mandatory)]
        [string[]]$AccountHome,

        [Parameter(Mandatory)]
        [string]$ProfileSourceRoot
    )

    # 啟動 Codex 前只讀比對實際要使用的帳號：帳號目錄的檔位設定檔必須是指向主 checkout 產生檔的 Symbolic Link 且內容相同，
    # 產生檔等於主 checkout 登錄表的預期內容，入口所在工作樹的登錄表設定也已落地到主 checkout。
    # 不一致時停止，不改任何檔案，訊息列出可整行貼到 pwsh 的修正命令。
    try {
        $findings = @(Test-CodexProfileConsistency -RegistryPath (Get-CodexProfileRegistryPath -RepoRoot $ProfileSourceRoot) -GeneratedDirectory (Get-CodexProfileGeneratedDirectory -RepoRoot $ProfileSourceRoot) -AccountHome @($AccountHome) -Profile $Profile -TreeRegistryPath (Get-CodexProfileRegistryPath -RepoRoot (Get-CodexProfileRepoRoot)))
    }
    catch {
        throw (New-RunError -Code 'CodexProfileDrift' -Message ('無法比對檔位設定檔，已停止，未啟動 Codex，未改任何檔案：' + $_.Exception.Message) -ExitCode 2)
    }
    if ($findings.Count -eq 0) { return }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($finding in $findings) {
        $lines.Add('[' + $finding.code + '] ' + $finding.path + '：' + $finding.detail)
        foreach ($fixLine in @(Format-CodexProfileFixLine -Command $finding.fix_commands -Note $finding.fix_note)) { $lines.Add($fixLine) }
    }
    throw (New-RunError -Code 'CodexProfileDrift' -Message ('檔位 ' + $Profile + ' 的設定檔與主 checkout 的產生檔不一致，已停止，未啟動 Codex，未改任何檔案。以下每一行可直接貼到 pwsh 執行，# 開頭為說明：' + [Environment]::NewLine + ($lines -join [Environment]::NewLine)) -ExitCode 2)
}

function Get-RunProfileExecutor {
    param(
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$RegistryPath
    )

    # 登錄表內使用該檔位的 Codex 執行者（Id、Display、FallbackModels）。登錄表讀不到或沒有該檔位時回傳 $null，
    # 呼叫端視為沒有備援 model，也不產生下一位執行者；檔位設定本身的問題由派工前比對回報。
    try {
        $registry = Read-CodexProfileRegistry -RegistryPath $RegistryPath
        $executor = @($registry.Executors | Where-Object { $_.Platform -ceq 'codex' -and $_.Profile -ceq $Profile })
        if ($executor.Count -eq 0) { return $null }
        return [pscustomobject]@{ Id = [string]$executor[0].Id; Display = [string]$executor[0].Display; FallbackModels = [string[]]@($executor[0].ProfileSettings['fallbackModels']) }
    }
    catch { return $null }
}

function Get-RunFallbackSelection {
    param(
        [Parameter(Mandatory)][string]$TaskType,
        [Parameter(Mandatory)][string]$UnavailableExecutorId
    )

    # 全部帳號不可用時，以選派入口取得下一位執行者，協調者不必手動帶 -Offline 重新呼叫。
    # 實作者家族固定為 claude（Codex 不承擔實作）。不寫任何狀態，下一次新的派工照常先選 Codex。
    # 選派入口無法執行或輸出不是 JSON 時回傳 $null，呼叫端照常回報原錯誤。
    try {
        $selectorPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Select-DispatchExecutor.ps1'
        if (-not [IO.File]::Exists($selectorPath)) { throw ('找不到選派入口：' + $selectorPath) }
        $hostPath = (Get-Process -Id $PID).Path
        $output = @(& $hostPath -NoProfile -NonInteractive -File $selectorPath -Type $TaskType -ImplementerFamily claude -Offline $UnavailableExecutorId 2>$null)
        $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
        if ([string]::IsNullOrWhiteSpace($text)) { throw ('選派入口沒有輸出，結束碼 ' + $LASTEXITCODE) }
        return [ordered]@{ unavailable_executor = $UnavailableExecutorId; selection = (ConvertFrom-Json -InputObject $text) }
    }
    catch {
        Write-RunDiagnostic ('[codex-run] 無法取得下一位執行者，請以 -Offline ' + $UnavailableExecutorId + ' 手動呼叫選派入口：' + $_.Exception.Message)
        return $null
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
        [int]$TurnEndGraceSeconds = 60,

        # 檔位設定檔比對的 repo 根目錄（含 scripts\dispatch\executor-registry.json 與 scripts\codex-profiles）。測試與診斷用，預設為主 checkout（machine.json 所在 repo）。
        [string]$ProfileSourceRoot,

        # 略過派工前的檔位設定檔比對。測試與診斷用；略過時於 stderr 留下一行紀錄。
        [switch]$SkipProfileCheck
    )

    # 回傳 ExitCode 與 Document（ai-agents.codex-run-result.v1）。診斷行寫 stderr，結果文件由入口輸出到 stdout。
    $attempts = New-Object 'System.Collections.Generic.List[object]'
    $final = $null
    $fallback = $null
    $profileExecutor = $null
    $taskType = $null
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
        $profileRoot = $ProfileSourceRoot
        if ([string]::IsNullOrWhiteSpace($profileRoot)) { $profileRoot = Split-Path -Parent (Split-Path -Parent $machinePath) }
        # 備援 model 與執行者名稱取自主 checkout 的登錄表，與派工前比對使用同一份。
        $taskType = [string]$order.task_type
        $profileExecutor = Get-RunProfileExecutor -Profile $order.profile -RegistryPath (Get-CodexProfileRegistryPath -RepoRoot $profileRoot)
        $fallbackModels = if ($null -ne $profileExecutor) { [string[]]@($profileExecutor.FallbackModels) } else { [string[]]@() }
        $executorDisplay = if ($null -ne $profileExecutor) { [string]$profileExecutor.Display } else { $null }
        $selection = Get-RunAccountCandidate -Profile $order.profile -MachineConfigPath $machinePath -FallbackModel $fallbackModels
        if (@($selection.candidates).Count -eq 0 -and -not $SkipProfileCheck) {
            # 已登入的帳號因檔位設定檔缺失而被排除時，這是本機檔位設定問題，不是 Codex 帳號全數不可用；
            # 以 CodexProfileDrift 回報修正命令，避免呼叫端誤判為 Codex 離線而改派。
            $missingProfileHomes = @(@($selection.skipped) | Where-Object { $_.reason_code -ceq 'ProfileConfigMissing' } | ForEach-Object { [string]$_.codex_home })
            if ($missingProfileHomes.Count -gt 0) {
                Assert-RunProfileConsistency -Profile $order.profile -AccountHome $missingProfileHomes -ProfileSourceRoot $profileRoot
            }
        }
        if (@($selection.candidates).Count -eq 0) {
            throw (New-RunError -Code 'CodexAccountsAllUnavailable' -Message ('所有登記帳號都不可用：' + (Format-RunAccountSkippedSummary -Skipped $selection.skipped)) -ExitCode 4)
        }
        foreach ($skippedItem in @($selection.skipped)) {
            Write-RunDiagnostic ('[codex-run] 略過帳號 ' + $skippedItem.name + '：' + $skippedItem.reason_code)
        }
        if ($SkipProfileCheck) {
            Write-RunDiagnostic '[codex-run] 已略過檔位設定檔比對（-SkipProfileCheck）。'
        }
        else {
            # 只檢查實際要使用的帳號；換帳號後對新的候選帳號在使用前再檢查，未使用的候選帳號不一致不阻擋。
            Assert-RunProfileConsistency -Profile $order.profile -AccountHome ([string]$selection.candidates[0].codex_home) -ProfileSourceRoot $profileRoot
        }
        if (-not (Test-RunMxc -CodexPath $codex -CodexHome $selection.candidates[0].codex_home)) {
            throw (New-RunError -Code 'RunMxcUnavailable' -Message '偵測不到 MXC 沙盒（codex sandbox 探針失敗）。新入口不改用其他沙盒，也不在沒有沙盒的情況下啟動 Codex。' -ExitCode 3)
        }
        $null = [IO.Directory]::CreateDirectory((Join-Path $order.report_line_root 'runs'))
        $dispatchSha = Get-RunSha256File -Path $dispatchPath
        $isGit = Test-RunGitRepository -Directory $order.execution_root

        $lastAttempt = $null
        $exhausted = $false
        $candidateIndex = 0
        foreach ($candidate in @($selection.candidates)) {
            if ($candidateIndex -gt 0 -and -not $SkipProfileCheck) {
                Assert-RunProfileConsistency -Profile $order.profile -AccountHome ([string]$candidate.codex_home) -ProfileSourceRoot $profileRoot
            }
            $candidateIndex++
            # 同一帳號依序嘗試可用的 model：被服務端以 model not supported 拒絕且尚無進度時改試下一個 model，
            # 其他拒絕種類（額度、未授權等）換 model 無效，改試下一個帳號。同一帳號的同一個 model 不重送。
            $settled = $false
            foreach ($model in @($candidate.models)) {
                $attemptCandidate = [pscustomobject]@{ name = $candidate.name; codex_home = $candidate.codex_home; model = $model; primary_model = $candidate.primary_model }
                $lastAttempt = Invoke-RunAttempt -Order $order -Candidate $attemptCandidate -CodexPath $codex -MachineConfigPath $machinePath -DispatchSha256 $dispatchSha -IsGitRepository $isGit -TimeoutSeconds $TimeoutSeconds -TurnEndGraceSeconds $TurnEndGraceSeconds -ExecutorDisplay $executorDisplay
                $attempts.Add([ordered]@{
                        run_key = $lastAttempt.run_key
                        account = $lastAttempt.account
                        model = $lastAttempt.model
                        result = $lastAttempt.result
                        rejection_kind = $lastAttempt.rejection_kind
                        record_path = $lastAttempt.record_path
                        relogin_command = $lastAttempt.relogin_command
                    })
                $final = [ordered]@{
                    run_key = $lastAttempt.run_key
                    model = $lastAttempt.model
                    model_source = $lastAttempt.model_source
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
                    if ($lastAttempt.rejection_kind -ceq 'model-not-supported') { continue }
                    break
                }
                $exhausted = $false
                $settled = $true
                break
            }
            if ($settled) { break }
        }
        if ($exhausted) {
            throw (New-RunError -Code 'CodexAccountsExhausted' -Message ('所有候選帳號都被服務端拒絕：' + (@($attempts | ForEach-Object { $_.account + $(if ([string]::IsNullOrWhiteSpace([string]$_.model)) { '' } else { '(' + $_.model + ')' }) + ':' + $_.rejection_kind }) -join '; ')) -ExitCode 4)
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
        if (($errorInfo.code -ceq 'CodexAccountsAllUnavailable' -or $errorInfo.code -ceq 'CodexAccountsExhausted') -and $null -ne $profileExecutor -and -not [string]::IsNullOrWhiteSpace($taskType)) {
            $fallback = Get-RunFallbackSelection -TaskType $taskType -UnavailableExecutorId $profileExecutor.Id
        }
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
        fallback = $fallback
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Document = $document }
}
