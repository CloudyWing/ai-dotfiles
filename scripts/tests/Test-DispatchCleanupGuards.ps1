#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$FixtureBaseRootPath = $env:TEMP,
    [string]$EvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $scriptsRoot
foreach ($moduleName in @(
        'common-runtime.ps1', 'git-baseline.ps1', 'dispatch-scope.ps1', 'dispatch-input-checks.ps1', 'dispatch-evidence.ps1',
        'quota-observation.ps1', 'advisor-evidence.ps1', 'process-identity.ps1', 'reviewer-contract.ps1',
        'run-recovery.ps1', 'prepare-stage.ps1', 'dispatch-lifecycle.ps1', 'start-lifecycle.ps1',
        'inspect-lifecycle.ps1', 'collect-contract.ps1', 'cleanup.ps1', 'Invoke-DispatchConcurrency.ps1')) {
    . (Join-Path (Join-Path $scriptsRoot 'dispatch') $moduleName)
}

# 入口參數 EvidencePath 是本測試的證據輸出路徑；Invoke-Cleanup 以同名的動態範圍變數讀取證據檔清單，
# 因此先保存輸出路徑，再移除帶型別限制的參數變數，改供 Cleanup 使用。
$evidenceOutputPath = $EvidencePath
Remove-Variable -Name EvidencePath -Scope Script
$SourceRoot = $null
$DispatchRoot = $null
$LineSlug = $null
$DispatchSlug = $null
$PreflightResultPath = $null
$RunRecordPath = $null
$EvidencePath = @()
$ReportPath = @()
$ResultPath = $null
$FailureReceiptPath = $null
$TakeoverOwner = $false
$CleanupBeforeRemovalHook = $null
$script:CallerSessionIdentity = $null

$script:cases = New-Object 'System.Collections.Generic.List[object]'
$script:observations = New-Object 'System.Collections.Generic.List[object]'
function Assert-Guard {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Invoke-GuardCase {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action
        $script:cases.Add([pscustomobject]@{ name = $Name; result = 'PASS'; error = $null })
    }
    catch {
        $script:cases.Add([pscustomobject]@{ name = $Name; result = 'FAIL'; error = $_.Exception.ToString() })
    }
}

$base = [IO.Path]::GetFullPath($FixtureBaseRootPath)
$fixture = Join-Path $base ('g' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$summaryPath = if ([string]::IsNullOrWhiteSpace($evidenceOutputPath)) { Join-Path (Join-Path $fixture 'evidence') 'cleanup-guards-summary.json' } else { [IO.Path]::GetFullPath($evidenceOutputPath) }
if ([IO.Path]::GetExtension($summaryPath) -ine '.json') { $summaryPath = Join-Path $summaryPath 'cleanup-guards-summary.json' }
$null = [IO.Directory]::CreateDirectory($fixture)
$null = [IO.Directory]::CreateDirectory((Split-Path -Parent $summaryPath))

function Write-GuardText {
    param([string]$Path, [string]$Content)
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}
function Invoke-GuardGit {
    param([string]$Root, [string[]]$Arguments)
    # 原生命令寫到 stderr 的進度訊息會以 ErrorRecord 輸出，
    # 呼叫期間改為 Continue，只以結束碼判定成敗。
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & git -C $Root @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($exitCode -ne 0) { throw ('git failed: ' + (@($output | ForEach-Object { [string]$_ }) -join "`n")) }
}
function New-GuardFixture {
    $root = Join-Path $fixture ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $source = Join-Path $root 'source'
    $null = [IO.Directory]::CreateDirectory($source)
    Invoke-GuardGit $source @('init', '-q')
    Invoke-GuardGit $source @('config', 'user.email', 'fixture@example.invalid')
    Invoke-GuardGit $source @('config', 'user.name', 'Fixture')
    Write-GuardText (Join-Path $source 'tracked.txt') 'baseline'
    Invoke-GuardGit $source @('add', 'tracked.txt')
    Invoke-GuardGit $source @('commit', '-qm', 'fixture')
    $slug = 'guard-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $worktree = Join-Path $source ('.local/ai-sessions/worktrees/' + $slug)
    Invoke-GuardGit $source @('worktree', 'add', '--detach', '--', $worktree, 'HEAD')
    return [pscustomobject]@{ source = $source; worktree = $worktree; slug = $slug }
}

function ConvertTo-GuardArgument {
    param([string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    $null = $builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) { $backslashes++; continue }
        if ($character -eq [char]34) {
            $null = $builder.Append([char]92, ($backslashes * 2 + 1))
            $null = $builder.Append([char]34)
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { $null = $builder.Append([char]92, $backslashes); $backslashes = 0 }
        $null = $builder.Append($character)
    }
    if ($backslashes -gt 0) { $null = $builder.Append([char]92, ($backslashes * 2)) }
    $null = $builder.Append('"')
    return $builder.ToString()
}
function Invoke-GuardProcess {
    param([string]$HostPath, [string[]]$Arguments, [string]$WorkingDirectory)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $HostPath
    $startInfo.Arguments = (@($Arguments | ForEach-Object { ConvertTo-GuardArgument ([string]$_) }) -join ' ')
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{ exit_code = $process.ExitCode; stdout = $stdoutTask.Result; stderr = $stderrTask.Result; command = $HostPath + ' ' + $startInfo.Arguments }
    }
    finally { $process.Dispose() }
}
function Get-GuardIdentity {
    param([string]$SessionId)
    return Get-DispatchCallerSessionIdentity -RequestCallerSessionId $SessionId -RequestCallerSessionIdProvided $true -CliCallerSessionId '' -CliCallerSessionIdProvided $false
}
function Get-GuardTreeSnapshot {
    param([string]$Root)
    $entries = New-Object 'System.Collections.Generic.List[string]'
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force)) {
        if ($file.FullName -match '[\\/]\.git[\\/]' -or $file.Name -ceq 'dispatch-admission.lock') { continue }
        $entries.Add($file.FullName.Substring($Root.Length) + '=' + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)
    }
    return ((@($entries.ToArray()) | Sort-Object) -join "`n")
}
function Remove-GuardWorktree {
    param([string]$Source, [string]$Worktree)
    if (-not [string]::IsNullOrWhiteSpace($Worktree) -and (Test-Path -LiteralPath $Worktree)) {
        try { Invoke-GuardGit $Source @('worktree', 'remove', '--force', '--', $Worktree) } catch { }
    }
}

function Set-GuardCleanupContext {
    param([object]$Scenario, [AllowNull()][object]$Identity, [bool]$Takeover = $false)
    $script:SourceRoot = $Scenario.source_root
    $script:DispatchRoot = $Scenario.dispatch_root
    $script:LineSlug = $Scenario.line_slug
    $script:DispatchSlug = $Scenario.dispatch_slug
    $script:PreflightResultPath = $Scenario.preflight_path
    $script:RunRecordPath = $Scenario.run_record_path
    $script:EvidencePath = @($Scenario.evidence_paths)
    $script:ReportPath = @()
    $script:ResultPath = $null
    $script:TakeoverOwner = $Takeover
    $script:CleanupBeforeRemovalHook = $null
    $script:CallerSessionIdentity = $Identity
}
function Invoke-GuardCleanup {
    $outcome = [ordered]@{ result = $null; failure_code = $null; message = $null; exception = $null }
    try { $outcome.result = Invoke-Cleanup -Confirm:$false }
    catch {
        $outcome.exception = $_.Exception
        $outcome.message = $_.Exception.Message
        $operationResult = $_.Exception.Data['operationResult']
        $outcome.failure_code = if ($null -ne $operationResult) { [string]$operationResult.failure_code } else { [string]$_.Exception.Data['errorCode'] }
    }
    return [pscustomobject]$outcome
}

# 以真實 git repo 與 worktree 建立 Cleanup 場景（不啟動 Codex）。
function New-GuardCleanupScenario {
    param([string]$StartedAtUtc)
    $id = [guid]::NewGuid().ToString('N')
    $scenarioRoot = Join-Path $fixture ('c' + $id.Substring(0, 6))
    $sourceRoot = Join-Path $scenarioRoot 'source'
    $slug = 'q' + $id.Substring(6, 8)
    $lineSlug = 'line-a'
    Write-GuardText (Join-Path $sourceRoot '.local\ai-sessions\history\initial.txt') 'cleanup history fixture'
    Write-GuardText (Join-Path $sourceRoot 'tracked.txt') 'baseline'
    Invoke-GuardGit $sourceRoot @('init', '-q')
    Invoke-GuardGit $sourceRoot @('config', 'user.email', 'fixture@example.invalid')
    Invoke-GuardGit $sourceRoot @('config', 'user.name', 'Fixture')
    Invoke-GuardGit $sourceRoot @('config', 'core.longpaths', 'true')
    Invoke-GuardGit $sourceRoot @('add', '--all')
    Invoke-GuardGit $sourceRoot @('add', '--force', '--', '.local/ai-sessions/history')
    Invoke-GuardGit $sourceRoot @('commit', '-qm', 'fixture')
    $dispatchRoot = Join-Path $sourceRoot ('.local\ai-sessions\worktrees\' + $slug)
    Invoke-GuardGit $sourceRoot @('worktree', 'add', '--detach', '--', $dispatchRoot, 'HEAD')
    $historyLineRoot = Join-Path $dispatchRoot ('.local\ai-sessions\history\' + $lineSlug)
    $reportRoot = Join-Path $dispatchRoot ('.local\ai-sessions\report\' + $lineSlug)
    $runRoot = Join-Path $sourceRoot ('.local\ai-sessions\history\' + $lineSlug + '\runs\' + $slug)
    $eventPath = Join-Path $historyLineRoot 'cleanup-event.jsonl'
    $lastMessagePath = Join-Path $historyLineRoot 'cleanup-last-message.md'
    $preflightPath = Join-Path $historyLineRoot 'cleanup-preflight.json'
    $runRecordPath = Join-Path $runRoot ([guid]::NewGuid().ToString('D') + '.json')
    Write-GuardText $eventPath '{"type":"thread.started","thread_id":"00000000-0000-0000-0000-000000000001"}'
    Write-GuardText $lastMessagePath 'cleanup fixture final message'
    $null = [IO.Directory]::CreateDirectory($reportRoot)
    $preflight = [ordered]@{ operation = 'Preflight'; sourceRoot = $sourceRoot; executionRoot = $dispatchRoot; dispatchRoot = $dispatchRoot; lineSlug = $lineSlug; dispatchSlug = $slug }
    Write-GuardText $preflightPath ((ConvertTo-Json -InputObject $preflight -Depth 10) + "`r`n")
    $record = [ordered]@{
        schema = 'ai-sessions.dispatch-run.v1'; line_slug = $lineSlug; dispatch_slug = $slug
        source_root = $sourceRoot; execution_root = $dispatchRoot
        event_stream_path = $eventPath; last_message_path = $lastMessagePath; preflight_result_path = $preflightPath
    }
    if (-not [string]::IsNullOrWhiteSpace($StartedAtUtc)) { $record['started_at_utc'] = $StartedAtUtc }
    Write-GuardText $runRecordPath ((ConvertTo-Json -InputObject $record -Depth 10) + "`r`n")
    return [pscustomobject]@{
        source_root = $sourceRoot; dispatch_root = $dispatchRoot; line_slug = $lineSlug; dispatch_slug = $slug
        run_record_path = $runRecordPath; preflight_path = $preflightPath; evidence_paths = @($eventPath)
        report_root = $reportRoot; source_report_root = Join-Path $sourceRoot ('.local\ai-sessions\report\' + $lineSlug)
    }
}

# 以真實 Dispatch 入口與虛擬 codex 建立「已結束」的派遣（事件流 turn.completed、退出 sidecar、PID 紀錄與 ledger owner 齊備）。
function New-GuardRealDispatch {
    param([string]$SessionId = 'guard-session-a')
    $id = [guid]::NewGuid().ToString('N')
    $source = Join-Path $fixture ('r' + $id.Substring(0, 6))
    $slug = 'd' + $id.Substring(6, 6)
    $lineSlug = 'a'
    $dispatchRoot = Join-Path $source ('.local\ai-sessions\worktrees\' + $slug)
    $lineRoot = Join-Path $source ('.local\ai-sessions\handoff\' + $lineSlug)
    $sourceHistory = Join-Path $source ('.local\ai-sessions\history\' + $lineSlug)
    $codexHome = Join-Path $source 'codex-home'
    $targetPath = Join-Path $source 'target.txt'
    $promptPath = Join-Path $source 'dispatch-prompt.md'
    $requestPath = Join-Path $source 'dispatch-request.json'
    $fakeCodexPath = Join-Path $source 'codex.cmd'
    $preflightPath = Join-Path $source 'preflight-result.json'
    $resultPath = Join-Path $sourceHistory 'dispatch-result.json'
    $threadId = [guid]::NewGuid().ToString('D')
    Write-GuardText (Join-Path $lineRoot 'line.json') ((ConvertTo-Json -InputObject ([ordered]@{ schema = 'ai-sessions.line.v1'; 'line-slug' = $lineSlug }) -Depth 10) + "`r`n")
    Write-GuardText (Join-Path $lineRoot 'requirement-summary.md') "# guard requirement summary`r`n"
    Write-GuardText (Join-Path $lineRoot 'design.md') "# guard design`r`n`r`n#### Phase 1 fixture`r`n"
    Write-GuardText $targetPath 'guard target'
    $lineContext = @(
        'LineContext:'
        ('lineSlug=' + $lineSlug)
        ('sourceRoot=' + $source)
        ('sourceLineRoot=' + $lineRoot)
        ('dispatchRoot=' + $dispatchRoot)
        ('dispatchLineRoot=' + (Join-Path $dispatchRoot ('.local\ai-sessions\handoff\' + $lineSlug)))
        ('reportLineRoot=' + (Join-Path $dispatchRoot ('.local\ai-sessions\report\' + $lineSlug)))
    ) -join "`n"
    Write-GuardText $promptPath ($lineContext + "`n`n" + 'guard dispatch prompt')
    Write-GuardText (Join-Path $codexHome 'scan.config.toml') ('model = "fixture-model"' + "`r`n" + 'model_reasoning_effort = "high"' + "`r`n")
    Invoke-GuardGit $source @('init', '-q')
    Invoke-GuardGit $source @('config', 'user.email', 'fixture@example.invalid')
    Invoke-GuardGit $source @('config', 'user.name', 'Fixture')
    Invoke-GuardGit $source @('add', '--', 'target.txt', 'dispatch-prompt.md')
    Invoke-GuardGit $source @('commit', '-qm', 'fixture')
    $fakeIdentifier = 'design.md'
    $fakeLines = @(
        '@echo off'
        ':findLastMessage'
        'if "%~1"=="" goto emitEvents'
        'if /I "%~1"=="--output-last-message" goto writeLastMessage'
        'shift'
        'goto findLastMessage'
        ':writeLastMessage'
        ('>"%~2" echo ' + $fakeIdentifier + ' ' + $slug + ' ' + $lineSlug)
        ':emitEvents'
        ('echo {"type":"thread.started","thread_id":"' + $threadId + '"}')
        ('echo {"type":"item.completed","item":{"type":"agent_message","text":"' + $fakeIdentifier + ' ' + $slug + ' ' + $lineSlug + '"}}')
        'echo {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
        'powershell.exe -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 1"'
        'exit /b 0'
    )
    Write-GuardText $fakeCodexPath (($fakeLines -join "`r`n") + "`r`n")
    $request = [ordered]@{
        schema = 'ai-sessions.dispatch-request.v1'; operation = 'Dispatch'
        source_root = $source; dispatch_root = $dispatchRoot; line_slug = $lineSlug; dispatch_slug = $slug
        profile = 'scan'; write_mode = 'write'; dispatch_kind = 'workflow'
        target_path = @($targetPath); prompt_path = $promptPath; task_type = 'script-change'; session_mode = 'cold-start'
        unit_kind = 'workflow-phase'; requested_unit = [string[]]@('Phase 1')
        failure_receipt_path = (Join-Path $sourceHistory 'failure-receipt.json'); result_path = $resultPath
        preflight_result_path = $preflightPath; prepare_result_path = (Join-Path $dispatchRoot ('.local\ai-sessions\history\' + $lineSlug + '\prepare.json'))
        caller_session_id = $SessionId
    }
    Write-GuardText $requestPath ((ConvertTo-Json -InputObject $request -Depth 20) + "`r`n")
    $hostPath = (Get-Process -Id $PID).Path
    $run = Invoke-GuardProcess -HostPath $hostPath -WorkingDirectory $repoRoot -Arguments @(
        '-NoProfile', '-NonInteractive', '-File', (Join-Path $scriptsRoot 'Invoke-CodexDispatch.ps1'),
        '-CodexPath', $fakeCodexPath, '-CodexHome', $codexHome, '-Operation', 'Dispatch', '-RequestPath', $requestPath)
    if ($run.exit_code -ne 0) { throw ('guard dispatch failed: exit=' + $run.exit_code + ' stdout=' + $run.stdout + ' stderr=' + $run.stderr) }
    $output = ConvertFrom-Json -InputObject $run.stdout
    $startResultPath = [string]$output.stage_results.start.path
    $startResult = [IO.File]::ReadAllText($startResultPath) | ConvertFrom-Json
    $runRecordPath = [string]$startResult.runRecordPath
    $sidecarPath = [string]$output.inspect_binding.process_exit_code_sidecar_path
    for ($attempt = 1; $attempt -le 50 -and -not [IO.File]::Exists($sidecarPath); $attempt++) { Start-Sleep -Milliseconds 100 }
    Assert-Guard ([IO.File]::Exists($runRecordPath) -and [IO.File]::Exists($sidecarPath)) ('guard dispatch 未產生 RunRecord 或退出 sidecar：' + $run.stdout)
    $record = [IO.File]::ReadAllText($runRecordPath) | ConvertFrom-Json
    return [pscustomobject]@{
        source_root = $source; dispatch_root = $dispatchRoot; line_slug = $lineSlug; dispatch_slug = $slug
        run_record_path = $runRecordPath; run_record_document = $record; preflight_path = $preflightPath
        sidecar_path = $sidecarPath; event_path = [string]$record.event_stream_path; pid_record_path = [string]$record.pid_record_path
        evidence_paths = @(); output = $output; process = $run
    }
}
function Get-GuardBaseline {
    param([object]$Real)
    $record = $Real.run_record_document
    $preflight = [IO.File]::ReadAllText($Real.preflight_path) | ConvertFrom-Json
    return Read-DispatchBaseline -Path $record.baseline_path -Sha256 $record.baseline_sha256 -SourceRoot $Real.source_root -DispatchRoot $Real.dispatch_root -LineSlug $Real.line_slug -DispatchSlug $Real.dispatch_slug -BaseSha $preflight.baseSha
}
function Invoke-GuardCollect {
    param([object]$Real, [object]$Identity, [object]$Baseline)
    $outcome = [ordered]@{ result = $null; error_code = $null; rejection = $null; message = $null }
    try {
        $outcome.result = Invoke-DispatchSourceIntegration -SourceRoot $Real.source_root -DispatchRoot $Real.dispatch_root -Path @('target.txt') -Baseline $Baseline -CallerIdentity $Identity -LineSlug $Real.line_slug -DispatchSlug $Real.dispatch_slug -RunRecordPath $Real.run_record_path
    }
    catch {
        $outcome.message = $_.Exception.Message
        $outcome.error_code = [string]$_.Exception.Data['errorCode']
        $outcome.rejection = $_.Exception.Data['takeoverRejection']
    }
    return [pscustomobject]$outcome
}
# 重現 Invoke-Cleanup 對 Assert-DispatchRecoveryOwner 的呼叫，取得放寬證明被拒絕時的 Data['takeoverRejection']。
function Get-GuardCleanupOwnerOutcome {
    param([object]$Real, [object]$Identity)
    $lock = Open-DispatchAdmissionLock -SourceRoot $Real.source_root
    try {
        $ledger = Read-DispatchAdmissionLedger -Lock $lock
        $provider = { param($code) Test-CleanupTakeoverTerminal -SourceRoot $Real.source_root -DispatchRoot $Real.dispatch_root -LineSlug $Real.line_slug -DispatchSlug $Real.dispatch_slug -RunRecordPath $Real.run_record_path -Ledger $ledger }
        try {
            $owner = Assert-DispatchRecoveryOwner -Lock $lock -Ledger $ledger -CallerIdentity $Identity -SourceRoot $Real.source_root -ExecutionRoot $Real.dispatch_root -LineSlug $Real.line_slug -DispatchSlug $Real.dispatch_slug -RunRecordPath $Real.run_record_path -TerminalTakeoverProof $provider
            return [pscustomobject]@{ owner = $owner; error_code = $null; rejection = $null; message = $null }
        }
        catch { return [pscustomobject]@{ owner = $null; error_code = [string]$_.Exception.Data['errorCode']; rejection = $_.Exception.Data['takeoverRejection']; message = $_.Exception.Message } }
    }
    finally { Close-DispatchAdmissionLock -Lock $lock }
}
function Get-GuardTakeoverAuditFiles {
    param([string]$Source)
    $history = Join-Path $Source '.local\ai-sessions\history'
    if (-not (Test-Path -LiteralPath $history)) { return @() }
    return @(Get-ChildItem -LiteralPath $history -Recurse -File -Force | Where-Object { $_.Name -like 'cleanup-takeover-*' -or $_.Name -like 'collect-takeover-*' })
}
function Assert-GuardTakeoverAudit {
    param([string]$Path, [string]$ExpectedSha256, [string]$Schema, [AllowNull()][string]$Operation, [object]$NewIdentity, [string]$OriginalFingerprint)
    Assert-Guard ([IO.File]::Exists($Path)) ('接手稽核檔不存在：' + $Path)
    Assert-Guard ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ieq $ExpectedSha256) 'audit_sha256 與稽核檔不符。'
    $audit = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    Assert-Guard ($audit.schema -ceq $Schema) ('稽核 schema 不符：' + $audit.schema)
    if (-not [string]::IsNullOrWhiteSpace($Operation)) { Assert-Guard ($audit.operation -ceq $Operation) ('稽核 operation 不符：' + $audit.operation) }
    Assert-Guard ($audit.explicit_takeover -eq $false -and $audit.automatic_takeover -eq $true) '稽核 explicit_takeover／automatic_takeover 不符。'
    Assert-Guard ($audit.trigger_error_code -ceq 'DispatchAdmissionOwnerMismatch') '稽核 trigger_error_code 不符。'
    Assert-Guard ($audit.new_owner_fingerprint -ceq $NewIdentity.Fingerprint) '稽核 new_owner_fingerprint 不符。'
    $originals = @($audit.original_owners | ForEach-Object { [string]$_.caller_session_fingerprint })
    Assert-Guard (($originals -contains $OriginalFingerprint) -and ($originals -cnotcontains $NewIdentity.Fingerprint)) 'original_owners 應含原 Session 且不含新 Session。'
    Assert-Guard (@($audit.terminal_evidence).Count -gt 0 -and @($audit.process_evidence).Count -gt 0) '稽核 terminal_evidence／process_evidence 為空。'
    return $audit
}

Invoke-GuardCase 'DD-CLEANUP-REPORTS fallback and conflicts' {
    $scenario = New-GuardFixture
    foreach ($name in @('review-report', 'frontend-reviewer-report', 'contract-auditor-report', 'implement-closure-report', 'support-engineer-report', 'cleanup-review', 'maintainer-notes', 'duty-queue', 'review-report-claude')) {
        $relative = '.local/ai-sessions/report/line-a/' + $name + '.md'
        $incoming = Join-Path $scenario.worktree $relative
        $destination = Join-Path $scenario.source $relative
        Write-GuardText $incoming 'incoming'
        Write-GuardText $destination 'destination'
        $saved = $null
        $errorMessage = ''
        try { $saved = Preserve-CleanupFile -Item ([pscustomobject]@{ source_path = $incoming; relative_path = $relative }) -SourceRoot $scenario.source -DispatchRoot $scenario.worktree -DispatchSlug $scenario.slug }
        catch { $errorMessage = $_.Exception.Message }
        if ($name -in @('implement-closure-report', 'support-engineer-report', 'cleanup-review')) {
            Assert-Guard ($null -ne $saved -and $saved.version_decision.basis -ceq 'closure-version-unknown' -and [IO.File]::ReadAllText($destination) -ceq 'destination' -and [IO.File]::ReadAllText($saved.archive_path) -ceq 'incoming') ('fallback failed: ' + $name + ' ' + $errorMessage)
        }
        elseif ($name -in @('review-report', 'frontend-reviewer-report', 'contract-auditor-report')) {
            Assert-Guard ($errorMessage -match 'CleanupReportVersionUnknown') ('unknown version accepted: ' + $name)
        }
        else { Assert-Guard ($errorMessage -match 'CleanupDestinationConflict') ('unlisted file accepted: ' + $name) }
    }
    $relative = '.local/ai-sessions/report/line-a/new-report.md'
    $incoming = Join-Path $scenario.worktree $relative
    Write-GuardText $incoming 'new report'
    $saved = Preserve-CleanupFile -Item ([pscustomobject]@{ source_path = $incoming; relative_path = $relative }) -SourceRoot $scenario.source -DispatchRoot $scenario.worktree -DispatchSlug $scenario.slug
    Assert-Guard ($null -eq $saved.archive_path -and [IO.File]::ReadAllText($saved.destination_path) -ceq 'new report') 'new report was not preserved'
}

Invoke-GuardCase 'DD-CLEANUP-REPORTS static coverage' {
    $cleanupPath = Join-Path $scriptsRoot 'dispatch/cleanup.ps1'
    $text = [IO.File]::ReadAllText($cleanupPath)
    Assert-Guard (@([regex]::Matches($text, 'implement-closure-report')).Count -eq 1) 'unexpected hard-coded closure report'
    Assert-Guard (-not $text.Contains('(?:review-report|frontend-reviewer-report|contract-auditor-report|implement-closure-report)')) 'old regex remains'
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($cleanupPath, [ref]$tokens, [ref]$errors)
    $compare = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Compare-CleanupReportVersion' }, $true)
    Assert-Guard (-not $compare.Extent.Text.Contains("-ceq 'implement-closure-report.md'")) 'hard-coded fallback remains'
    $orderText = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'New-DispatchOrder.ps1'))
    $mapping = [regex]::Match($orderText, '(?s)\$fixedReportName = switch.*?\r?\n    }').Value
    $reports = @([regex]::Matches($mapping, "'([a-z-]+)\.md'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    Assert-Guard ($reports.Count -gt 0) 'role report mapping not found'
    foreach ($name in $reports) { Assert-Guard (@($script:CleanupFixedReportNames | Where-Object { $_.Name -ceq $name }).Count -eq 1) ('missing role report: ' + $name) }
}

Invoke-GuardCase 'DD-CLEANUP-REPORTS version ordering and archive drift' {
    $scenario = New-GuardFixture
    $relative = '.local/ai-sessions/report/line-a/support-engineer-report.md'
    $incoming = Join-Path $scenario.worktree $relative
    $destination = Join-Path $scenario.source $relative
    $olderSlug = 'guard-older'
    $olderRun = Join-Path $scenario.source ('.local/ai-sessions/history/line-a/runs/' + $olderSlug + '/older.json')
    $newerRun = Join-Path $scenario.source ('.local/ai-sessions/history/line-a/runs/' + $scenario.slug + '/newer.json')
    foreach ($entry in @(@($olderRun, $olderSlug, '2024-01-01T00:00:00Z'), @($newerRun, $scenario.slug, '2025-01-01T00:00:00Z'))) {
        $record = [ordered]@{ schema = 'ai-sessions.dispatch-run.v1'; line_slug = 'line-a'; dispatch_slug = $entry[1]; source_root = $scenario.source; started_at_utc = $entry[2] }
        Write-GuardText $entry[0] ($record | ConvertTo-Json)
    }
    Write-GuardText $destination ('dispatchSlug: ' + $olderSlug)
    Write-GuardText $incoming ('dispatchSlug: ' + $scenario.slug)
    $item = [pscustomobject]@{ source_path = $incoming; relative_path = $relative }
    $saved = Preserve-CleanupFile -Item $item -SourceRoot $scenario.source -DispatchRoot $scenario.worktree -DispatchSlug $scenario.slug
    Assert-Guard ($saved.version_decision.basis -ceq 'run-record-started-at-utc' -and [IO.File]::ReadAllText($destination) -ceq ('dispatchSlug: ' + $scenario.slug) -and [IO.File]::ReadAllText($saved.archive_path) -ceq ('dispatchSlug: ' + $olderSlug)) 'run record ordering failed'

    Write-GuardText $incoming 'incoming tamper'
    Write-GuardText $destination 'destination tamper'
    $script:guardHashOriginal = (Get-Command Get-FileSha256 -CommandType Function).ScriptBlock
    $script:guardTamperPath = $destination
    $script:guardTamperCount = 0
    try {
        Set-Item Function:\Get-FileSha256 { param([string]$Path)
            if ([string]::Equals($Path, $script:guardTamperPath, [StringComparison]::OrdinalIgnoreCase)) {
                $script:guardTamperCount++
                if ($script:guardTamperCount -eq 2) { [IO.File]::WriteAllText($Path, 'changed during archive') }
            }
            & $script:guardHashOriginal -Path $Path
        }
        $rejected = $false
        try { $null = Preserve-CleanupFile -Item $item -SourceRoot $scenario.source -DispatchRoot $scenario.worktree -DispatchSlug $scenario.slug }
        catch { $rejected = $_.Exception.Message -match 'CleanupDestinationConflict' }
        Assert-Guard ($rejected -and $script:guardTamperCount -eq 2) 'archive drift was not rejected'
    }
    finally { Set-Item Function:\Get-FileSha256 $script:guardHashOriginal }
}

# T128：完整 Cleanup 路徑（真實 git worktree、Invoke-Cleanup）逐名稱驗證固定報告保存。
Invoke-GuardCase 'DD-CLEANUP-REPORTS full Cleanup per fixed report name' {
    foreach ($entry in @(
            @{ name = 'review-report'; fallback = $false }, @{ name = 'frontend-reviewer-report'; fallback = $false }, @{ name = 'contract-auditor-report'; fallback = $false },
            @{ name = 'implement-closure-report'; fallback = $true }, @{ name = 'support-engineer-report'; fallback = $true }, @{ name = 'cleanup-review'; fallback = $true })) {
        $scenario = New-GuardCleanupScenario
        try {
            $relative = '.local/ai-sessions/report/line-a/' + $entry.name + '.md'
            $incoming = Join-Path $scenario.report_root ($entry.name + '.md')
            $destination = Join-Path $scenario.source_report_root ($entry.name + '.md')
            Write-GuardText $incoming ('incoming ' + $entry.name)
            Write-GuardText $destination ('destination ' + $entry.name)
            Set-GuardCleanupContext $scenario $null
            $outcome = Invoke-GuardCleanup
            if ($entry.fallback) {
                Assert-Guard ($null -ne $outcome.result -and $outcome.result.status -ceq 'completed') ('Cleanup 未完成：' + $entry.name + ' ' + $outcome.message)
                Assert-Guard (-not (Test-Path -LiteralPath $scenario.dispatch_root)) ('worktree 未移除：' + $entry.name)
                $files = @($outcome.result.files | Where-Object { $_.relative_path -ceq $relative })
                Assert-Guard ($files.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$files[0].archive_path) -and [IO.File]::Exists([string]$files[0].archive_path)) ('archive_path 缺漏：' + $entry.name)
                Assert-Guard ($files[0].version_decision.basis -ceq 'closure-version-unknown') ('basis 不符：' + $entry.name)
                Assert-Guard ([IO.File]::ReadAllText($destination) -ceq ('destination ' + $entry.name) -and [IO.File]::ReadAllText([string]$files[0].archive_path) -ceq ('incoming ' + $entry.name)) ('主檔或封存內容不符：' + $entry.name)
            }
            else {
                Assert-Guard ($null -eq $outcome.result -and $outcome.failure_code -ceq 'CleanupReportVersionUnknown') ('應以 CleanupReportVersionUnknown 拒絕：' + $entry.name + ' code=' + $outcome.failure_code + ' ' + $outcome.message)
                Assert-Guard ((Test-Path -LiteralPath $scenario.dispatch_root) -and [IO.File]::Exists($incoming) -and [IO.File]::ReadAllText($destination) -ceq ('destination ' + $entry.name)) ('拒絕後 worktree 或主檔被改動：' + $entry.name)
            }
        }
        finally { Remove-GuardWorktree $scenario.source_root $scenario.dispatch_root }
    }
}

Invoke-GuardCase 'DD-CLEANUP-REPORTS full Cleanup run record ordering' {
    foreach ($direction in @('incoming-newer', 'incoming-older')) {
        $startedAt = if ($direction -ceq 'incoming-newer') { '2025-01-01T00:00:00Z' } else { '2023-01-01T00:00:00Z' }
        $scenario = New-GuardCleanupScenario -StartedAtUtc $startedAt
        try {
            $relative = '.local/ai-sessions/report/line-a/support-engineer-report.md'
            $olderSlug = 'guard-older'
            $olderRun = Join-Path $scenario.source_root ('.local\ai-sessions\history\line-a\runs\' + $olderSlug + '\older.json')
            $olderRecord = [ordered]@{ schema = 'ai-sessions.dispatch-run.v1'; line_slug = 'line-a'; dispatch_slug = $olderSlug; source_root = $scenario.source_root; started_at_utc = '2024-01-01T00:00:00Z' }
            Write-GuardText $olderRun (ConvertTo-Json -InputObject $olderRecord)
            $incoming = Join-Path $scenario.report_root 'support-engineer-report.md'
            $destination = Join-Path $scenario.source_report_root 'support-engineer-report.md'
            $incomingText = 'dispatchSlug: ' + $scenario.dispatch_slug
            $destinationText = 'dispatchSlug: ' + $olderSlug
            Write-GuardText $incoming $incomingText
            Write-GuardText $destination $destinationText
            Set-GuardCleanupContext $scenario $null
            $outcome = Invoke-GuardCleanup
            Assert-Guard ($null -ne $outcome.result -and $outcome.result.status -ceq 'completed' -and -not (Test-Path -LiteralPath $scenario.dispatch_root)) ('Cleanup 未完成：' + $direction + ' ' + $outcome.message)
            $files = @($outcome.result.files | Where-Object { $_.relative_path -ceq $relative })
            Assert-Guard ($files.Count -eq 1 -and $files[0].version_decision.basis -ceq 'run-record-started-at-utc' -and [IO.File]::Exists([string]$files[0].archive_path)) ('basis 不符：' + $direction)
            $mainText = [IO.File]::ReadAllText($destination)
            $archiveText = [IO.File]::ReadAllText([string]$files[0].archive_path)
            if ($direction -ceq 'incoming-newer') { Assert-Guard ($mainText -ceq $incomingText -and $archiveText -ceq $destinationText) '較新者應為主檔、較舊者封存。' }
            else { Assert-Guard ($mainText -ceq $destinationText -and $archiveText -ceq $incomingText) '來源較舊時主檔應維持、incoming 封存。' }
        }
        finally { Remove-GuardWorktree $scenario.source_root $scenario.dispatch_root }
    }
}

Invoke-GuardCase 'DD-CLEANUP-REPORTS full Cleanup no destination and out-of-table conflicts' {
    $scenario = New-GuardCleanupScenario
    try {
        $fresh = Join-Path $scenario.report_root 'support-engineer-report.md'
        $freshFile = Join-Path $scenario.report_root 'maintainer-notes-fresh.md'
        Write-GuardText $fresh 'fresh report'
        Write-GuardText $freshFile 'fresh note'
        Set-GuardCleanupContext $scenario $null
        $outcome = Invoke-GuardCleanup
        Assert-Guard ($null -ne $outcome.result -and $outcome.result.status -ceq 'completed') ('來源無同名檔時 Cleanup 未完成：' + $outcome.message)
        foreach ($pair in @(@('support-engineer-report.md', 'fresh report'), @('maintainer-notes-fresh.md', 'fresh note'))) {
            $files = @($outcome.result.files | Where-Object { $_.relative_path -ceq ('.local/ai-sessions/report/line-a/' + $pair[0]) })
            Assert-Guard ($files.Count -eq 1 -and $null -eq $files[0].archive_path -and [IO.File]::ReadAllText((Join-Path $scenario.source_report_root $pair[0])) -ceq $pair[1]) ('來源無同名檔應直接保存：' + $pair[0])
        }
    }
    finally { Remove-GuardWorktree $scenario.source_root $scenario.dispatch_root }
    foreach ($name in @('maintainer-notes', 'duty-queue', 'review-report-claude')) {
        $scenario = New-GuardCleanupScenario
        try {
            $incoming = Join-Path $scenario.report_root ($name + '.md')
            $destination = Join-Path $scenario.source_report_root ($name + '.md')
            Write-GuardText $incoming 'incoming'
            Write-GuardText $destination 'destination'
            Set-GuardCleanupContext $scenario $null
            $outcome = Invoke-GuardCleanup
            Assert-Guard ($null -eq $outcome.result -and $outcome.failure_code -ceq 'CleanupDestinationConflict') ('表外檔名應 CleanupDestinationConflict：' + $name + ' code=' + $outcome.failure_code + ' ' + $outcome.message)
            Assert-Guard ((Test-Path -LiteralPath $scenario.dispatch_root) -and [IO.File]::ReadAllText($destination) -ceq 'destination') ('表外檔名拒絕後狀態被改動：' + $name)
        }
        finally { Remove-GuardWorktree $scenario.source_root $scenario.dispatch_root }
    }
}

Invoke-GuardCase 'DD-CLEANUP-REPORTS full Cleanup rejects archive drift' {
    $scenario = New-GuardCleanupScenario
    $script:guardHashOriginal = (Get-Command Get-FileSha256 -CommandType Function).ScriptBlock
    try {
        $incoming = Join-Path $scenario.report_root 'support-engineer-report.md'
        $destination = Join-Path $scenario.source_report_root 'support-engineer-report.md'
        Write-GuardText $incoming 'incoming drift'
        Write-GuardText $destination 'destination drift'
        $script:guardTamperPath = $destination
        $script:guardTamperCount = 0
        Set-Item Function:\Get-FileSha256 { param([string]$Path)
            if ([string]::Equals($Path, $script:guardTamperPath, [StringComparison]::OrdinalIgnoreCase)) {
                $script:guardTamperCount++
                if ($script:guardTamperCount -eq 2) { [IO.File]::WriteAllText($Path, 'changed during archive') }
            }
            & $script:guardHashOriginal -Path $Path
        }
        Set-GuardCleanupContext $scenario $null
        $outcome = Invoke-GuardCleanup
        Set-Item Function:\Get-FileSha256 $script:guardHashOriginal
        Assert-Guard ($null -eq $outcome.result -and $outcome.failure_code -ceq 'CleanupDestinationConflict' -and $script:guardTamperCount -ge 2) ('封存期間改動應 CleanupDestinationConflict：code=' + $outcome.failure_code + ' ' + $outcome.message)
        Assert-Guard (Test-Path -LiteralPath $scenario.dispatch_root) '封存期間改動後 worktree 應保留。'
    }
    finally {
        Set-Item Function:\Get-FileSha256 $script:guardHashOriginal
        Remove-GuardWorktree $scenario.source_root $scenario.dispatch_root
    }
}

Invoke-GuardCase 'DD-OWNER-TAKEOVER owner proof and rejection' {
    $scenario = New-GuardFixture
    $savedUpdate = (Get-Command Update-DispatchAdmissionOwnerStates -CommandType Function).ScriptBlock
    $runPath = Join-Path $scenario.source 'owner-record.json'
    $identity = [pscustomobject]@{ Fingerprint = 'session-b'; Source = 'fixture' }
    $entry = [pscustomobject]@{ line_slug = 'line-a'; dispatch_slug = $scenario.slug; caller_session_fingerprint = 'session-a' }
    $ledger = [pscustomobject]@{ Document = [pscustomobject]@{ entries = @($entry) } }
    try {
        Set-Item Function:\Update-DispatchAdmissionOwnerStates { param($Ledger) }
        Write-GuardText $runPath '{"caller_session_fingerprint":"session-a"}'
        $proof = { param($code) [pscustomobject]@{ marker = $code } }
        $arguments = @{ Lock = [pscustomobject]@{}; Ledger = $ledger; CallerIdentity = $identity; LineSlug = 'line-a'; DispatchSlug = $scenario.slug; RunRecordPath = $runPath }
        $owner = Assert-DispatchAdmissionOwner @arguments -TerminalTakeoverProof $proof
        Assert-Guard ($owner.OwnerTakeover.trigger_error_code -ceq 'DispatchAdmissionOwnerMismatch' -and $owner.OwnerTakeover.proof.marker -ceq 'DispatchAdmissionOwnerMismatch') 'terminal proof missing'
        $failure = $null
        try { $null = Assert-DispatchAdmissionOwner @arguments -TerminalTakeoverProof { throw 'CleanupTakeoverRunNotTerminal：fixture' } }
        catch { $failure = $_.Exception }
        Assert-Guard ($null -ne $failure -and $failure.Data['errorCode'] -ceq 'DispatchAdmissionOwnerMismatch' -and $failure.Data['takeoverRejection'].code -ceq 'CleanupTakeoverRunNotTerminal') 'rejection reason missing'
        Write-GuardText $runPath '{}'
        $failure = $null
        try { $null = Assert-DispatchAdmissionOwner @arguments -TerminalTakeoverProof $proof }
        catch { $failure = $_.Exception }
        Assert-Guard ($null -ne $failure -and $failure.Data['errorCode'] -ceq 'DispatchAdmissionOwnerMismatch' -and $failure.Data['takeoverRejection'].code -ceq 'CleanupTakeoverOwnerUnverifiable') 'missing owner accepted'
        $failure = $null
        try { $null = Assert-DispatchAdmissionOwner @arguments }
        catch { $failure = $_.Exception }
        Assert-Guard ($null -ne $failure -and $failure.Data['errorCode'] -ceq 'DispatchAdmissionOwnerMismatch') 'legacy mismatch changed without provider'
        foreach ($invalidRecord in @('', '{')) {
            Write-GuardText $runPath $invalidRecord
            $failure = $null
            try { $null = Assert-DispatchAdmissionOwner @arguments -TerminalTakeoverProof { throw 'proof must not run' } }
            catch { $failure = $_.Exception }
            Assert-Guard ($null -ne $failure -and $failure.Data['errorCode'] -ceq 'DispatchAdmissionOwnerMismatch' -and $failure.Data['takeoverRejection'].code -ceq 'CleanupTakeoverOwnerUnverifiable') 'invalid record accepted'
        }
        $arguments.RunRecordPath = ''
        $failure = $null
        try { $null = Assert-DispatchAdmissionOwner @arguments -TerminalTakeoverProof { throw 'proof must not run' } }
        catch { $failure = $_.Exception }
        Assert-Guard ($null -ne $failure -and $failure.Data['errorCode'] -ceq 'DispatchAdmissionOwnerMismatch' -and $failure.Data['takeoverRejection'].code -ceq 'CleanupTakeoverOwnerUnverifiable') 'missing record accepted'
        $arguments.RunRecordPath = Join-Path $scenario.source 'absent-record.json'
        $failure = $null
        try { $null = Assert-DispatchAdmissionOwner @arguments -TerminalTakeoverProof { throw 'proof must not run' } }
        catch { $failure = $_.Exception }
        Assert-Guard ($null -ne $failure -and $failure.Data['errorCode'] -ceq 'DispatchAdmissionOwnerMismatch' -and $failure.Data['takeoverRejection'].code -ceq 'CleanupTakeoverOwnerUnverifiable') 'absent record accepted'
        $arguments.RunRecordPath = $runPath
        $entry.caller_session_fingerprint = ''
        $failure = $null
        try { $null = Assert-DispatchAdmissionOwner @arguments -TerminalTakeoverProof { throw 'proof must not run' } }
        catch { $failure = $_.Exception }
        Assert-Guard ($null -ne $failure -and $failure.Data['errorCode'] -ceq 'DispatchAdmissionOwnerMismatch' -and $failure.Data['takeoverRejection'].code -ceq 'CleanupTakeoverOwnerUnverifiable') 'missing ledger owner accepted'
        $entry.caller_session_fingerprint = 'session-b'
        Write-GuardText $runPath '{"caller_session_fingerprint":"session-b"}'
        $owner = Assert-DispatchAdmissionOwner @arguments -TerminalTakeoverProof { throw 'same session invoked proof' }
        Assert-Guard ($null -eq $owner.PSObject.Properties['OwnerTakeover']) 'same session created takeover'
        Write-GuardText $runPath '{}'
        $failure = $null
        try { $null = Assert-DispatchAdmissionOwner @arguments -TerminalTakeoverProof { throw 'proof must not run' } }
        catch { $failure = $_.Exception }
        Assert-Guard ($null -ne $failure -and $failure.Data['errorCode'] -ceq 'DispatchAdmissionOwnerMismatch' -and $failure.Data['takeoverRejection'].code -ceq 'CleanupTakeoverOwnerUnverifiable') 'same ledger owner with legacy record accepted'
    }
    finally { Set-Item Function:\Update-DispatchAdmissionOwnerStates $savedUpdate }
}

# T132 正向：已確定結束的派遣由另一個 Session 不帶 -TakeoverOwner 自動接手（Collect 先，Cleanup 後）。
Invoke-GuardCase 'DD-OWNER-TAKEOVER automatic takeover by another session (Collect then Cleanup CLI)' {
    $real = New-GuardRealDispatch
    try {
        $identityA = Get-GuardIdentity 'guard-session-a'
        $identityB = Get-GuardIdentity 'guard-session-b'
        Assert-Guard ([string]$real.run_record_document.caller_session_fingerprint -ceq $identityA.Fingerprint) 'fixture owner 應為 Session A。'
        $baseline = Get-GuardBaseline $real
        $sourceTarget = Join-Path $real.source_root 'target.txt'
        Write-GuardText (Join-Path $real.dispatch_root 'target.txt') 'collected change'
        $runRecordHash = (Get-FileHash -LiteralPath $real.run_record_path -Algorithm SHA256).Hash

        $collect = Invoke-GuardCollect $real $identityB $baseline
        Assert-Guard ($null -ne $collect.result -and $collect.result.status -ceq 'applied' -and $collect.result.owner_takeover.used) ('Collect 自動接手失敗：' + $collect.message)
        $collectAudit = Assert-GuardTakeoverAudit -Path $collect.result.owner_takeover.audit_path -ExpectedSha256 $collect.result.owner_takeover.audit_sha256 -Schema 'ai-sessions.collect-takeover.v1' -Operation 'Collect' -NewIdentity $identityB -OriginalFingerprint $identityA.Fingerprint
        Assert-Guard ([IO.File]::ReadAllText($sourceTarget) -ceq 'collected change') 'Collect 未套回來源。'
        $applyLedger = [IO.File]::ReadAllText((Join-Path $real.source_root '.local\ai-sessions\history\a\collect-apply-ledger.json')) | ConvertFrom-Json
        $applyEntry = @($applyLedger.entries | Where-Object { $_.relative_path -ceq 'target.txt' })
        Assert-Guard ($applyEntry.Count -eq 1 -and $collectAudit.requested_at_utc -le $applyEntry[0].applied_at_utc) '稽核檔應先於第一個套回寫入（requested_at_utc 晚於 applied_at_utc）。'
        Assert-Guard ((Get-Item -LiteralPath $collect.result.owner_takeover.audit_path).LastWriteTimeUtc -le (Get-Item -LiteralPath $sourceTarget).LastWriteTimeUtc) '稽核檔寫入時間應早於套回的來源檔。'

        $resultFile = Join-Path $real.source_root 'cleanup-cli-result.json'
        $cli = Invoke-GuardProcess -HostPath (Get-Process -Id $PID).Path -WorkingDirectory $repoRoot -Arguments @(
            '-NoProfile', '-NonInteractive', '-File', (Join-Path $scriptsRoot 'Invoke-CodexDispatch.ps1'), '-Operation', 'Cleanup',
            '-SourceRoot', $real.source_root, '-DispatchRoot', $real.dispatch_root, '-LineSlug', $real.line_slug, '-DispatchSlug', $real.dispatch_slug,
            '-PreflightResultPath', $real.preflight_path, '-RunRecordPath', $real.run_record_path, '-CallerSessionId', 'guard-session-b', '-ResultPath', $resultFile)
        Assert-Guard ($cli.exit_code -eq 0) ('Cleanup CLI 應 exit 0：exit=' + $cli.exit_code + ' stdout=' + $cli.stdout + ' stderr=' + $cli.stderr)
        $cleanup = [IO.File]::ReadAllText($resultFile) | ConvertFrom-Json
        Assert-Guard ($cleanup.status -ceq 'completed' -and $cleanup.worktree_removed -eq $true -and -not (Test-Path -LiteralPath $real.dispatch_root)) ('Cleanup 未完成：' + $cleanup.status)
        Assert-Guard ($cleanup.owner_takeover.used -eq $true) 'Cleanup owner_takeover.used 應為 true。'
        $admissionPath = (Get-DispatchAdmissionPaths -SourceRoot $real.source_root).LedgerPath
        $admission = [IO.File]::ReadAllText($admissionPath) | ConvertFrom-Json
        $entries = @($admission.entries | Where-Object { $_.line_slug -ceq $real.line_slug -and $_.dispatch_slug -ceq $real.dispatch_slug })
        Assert-Guard ($entries.Count -gt 0) 'Cleanup 後應保留對應的 admission entry。'
        $entry = $entries[-1]
        Assert-Guard ($entry.state -ceq 'cleaned' -and -not [string]::IsNullOrWhiteSpace([string]$entry.cleaned_at_utc)) 'Cleanup 後 ledger 應記錄 cleaned 與 cleaned_at_utc。'
        Assert-Guard ($null -eq $entry.PSObject.Properties['OwnerTakeover'] -and $entry.caller_session_fingerprint -ceq $identityA.Fingerprint) 'ledger 不應保存 OwnerTakeover 或改寫原 fingerprint。'
        $cleanupAudit = Assert-GuardTakeoverAudit -Path $cleanup.owner_takeover.audit_path -ExpectedSha256 $cleanup.owner_takeover.audit_sha256 -Schema 'ai-sessions.cleanup-takeover.v1' -Operation $null -NewIdentity $identityB -OriginalFingerprint $identityA.Fingerprint
        Assert-Guard ($cleanupAudit.status -ceq 'completed' -and @($cleanupAudit.preserved_files).Count -gt 0) 'Cleanup 稽核狀態或 preserved_files 不符。'
        Assert-Guard ((Get-FileHash -LiteralPath $real.run_record_path -Algorithm SHA256).Hash -ceq $runRecordHash) '自動接手不得改寫原 RunRecord。'
    }
    finally { Remove-GuardWorktree $real.source_root $real.dispatch_root }
}

# T132 正向：同 Session 執行時不接手、不產生稽核檔。
Invoke-GuardCase 'DD-OWNER-TAKEOVER same session performs no takeover' {
    $real = New-GuardRealDispatch
    try {
        $identityA = Get-GuardIdentity 'guard-session-a'
        $baseline = Get-GuardBaseline $real
        Write-GuardText (Join-Path $real.dispatch_root 'target.txt') 'collected by owner'
        $collect = Invoke-GuardCollect $real $identityA $baseline
        Assert-Guard ($null -ne $collect.result -and $collect.result.status -ceq 'applied' -and $collect.result.owner_takeover.used -eq $false -and $null -eq $collect.result.owner_takeover.audit_path) ('同 Session Collect 不應接手：' + $collect.message)
        Set-GuardCleanupContext $real $identityA
        $cleanup = Invoke-GuardCleanup
        Assert-Guard ($null -ne $cleanup.result -and $cleanup.result.status -ceq 'completed' -and $cleanup.result.owner_takeover.used -eq $false -and $null -eq $cleanup.result.owner_takeover.audit_path) ('同 Session Cleanup 不應接手：' + $cleanup.message)
        Assert-Guard (@(Get-GuardTakeoverAuditFiles $real.source_root).Count -eq 0 -and -not (Test-Path -LiteralPath $real.dispatch_root)) '同 Session 不應產生稽核檔，且 Cleanup 應移除 worktree。'
    }
    finally {
        $script:CallerSessionIdentity = $null
        Remove-GuardWorktree $real.source_root $real.dispatch_root
    }
}

# T132 負向 (a) 至 (g)：Cleanup 與 Collect 皆維持拒絕，且來源與 worktree 雜湊不變、無稽核檔。
Invoke-GuardCase 'DD-OWNER-TAKEOVER rejects non-terminal and unverifiable dispatches (a)-(g)' {
    $real = New-GuardRealDispatch
    $script:guardLiveProcess = $null
    try {
        $identityB = Get-GuardIdentity 'guard-session-b'
        $baseline = Get-GuardBaseline $real
        Write-GuardText (Join-Path $real.dispatch_root 'target.txt') 'collected change'
        $ledgerPath = (Get-DispatchAdmissionPaths -SourceRoot $real.source_root).LedgerPath
        $mutable = [ordered]@{ run = $real.run_record_path; event = $real.event_path; sidecar = $real.sidecar_path; pid = $real.pid_record_path; ledger = $ledgerPath }
        $originals = @{}
        foreach ($key in $mutable.Keys) { $originals[$key] = [IO.File]::ReadAllBytes($mutable[$key]) }
        $faults = @(
            @{ id = '(a) 事件流最後一筆非 terminal'; code = 'DispatchAdmissionOwnerMismatch'; rejection = 'CleanupTakeoverRunNotTerminal'
                apply = { Write-GuardText $real.event_path '{"type":"turn.started"}' } },
            @{ id = '(a) 事件流為空'; code = 'DispatchAdmissionOwnerMismatch'; rejection = 'CleanupTakeoverRunNotTerminal'
                apply = { Write-GuardText $real.event_path '' } },
            @{ id = '(b) 無 sidecar 且無 Inspect'; code = 'DispatchAdmissionOwnerMismatch'; rejection = 'CleanupTakeoverRunNotTerminal'
                apply = {
                    $text = [IO.File]::ReadAllText($real.run_record_path)
                    $text = [regex]::Replace($text, '"process_exit_code_sidecar_path":\s*"[^"]*"', '"process_exit_code_sidecar_path": null')
                    $text = [regex]::Replace($text, '"inspect_result_path":\s*"[^"]*"', '"inspect_result_path": null')
                    Write-GuardText $real.run_record_path $text
                } },
            @{ id = '(c) PID 紀錄缺 root-process-name'; code = 'DispatchAdmissionOwnerMismatch'; rejection = 'CleanupTakeoverProcessUnverifiable'
                apply = {
                    $text = [regex]::Replace([IO.File]::ReadAllText($real.pid_record_path), '(?m)^root-process-name=[^\r\n]*\r?\n', '')
                    Assert-Guard (-not $text.Contains('root-process-name')) 'fixture 未移除 root-process-name。'
                    Write-GuardText $real.pid_record_path $text
                } },
            @{ id = '(d) 與 PID 三鍵吻合的程序仍存活'; code = 'DispatchAdmissionOwnerMismatch'; rejection = 'ProcessIdentityBlocked'
                apply = {
                    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
                    $startInfo.FileName = 'ping.exe'
                    $startInfo.Arguments = '-n 600 127.0.0.1'
                    $startInfo.UseShellExecute = $false
                    $startInfo.CreateNoWindow = $true
                    $startInfo.RedirectStandardOutput = $true
                    $script:guardLiveProcess = [System.Diagnostics.Process]::Start($startInfo)
                    $liveName = $script:guardLiveProcess.ProcessName
                    $liveStart = $script:guardLiveProcess.StartTime.ToUniversalTime().ToString('o')
                    $pidText = [IO.File]::ReadAllText($real.pid_record_path)
                    $pidText = [regex]::Replace($pidText, '(?m)^pid=[^\r\n]*', 'pid=' + $script:guardLiveProcess.Id)
                    $pidText = [regex]::Replace($pidText, '(?m)^root-pid=[^\r\n]*', 'root-pid=' + $script:guardLiveProcess.Id)
                    $pidText = [regex]::Replace($pidText, '(?m)^root-process-name=[^\r\n]*', 'root-process-name=' + $liveName)
                    $pidText = [regex]::Replace($pidText, '(?m)^root-started-at-utc=[^\r\n]*', 'root-started-at-utc=' + $liveStart)
                    Write-GuardText $real.pid_record_path $pidText
                    $ledgerText = [IO.File]::ReadAllText($ledgerPath)
                    $ledgerText = [regex]::Replace($ledgerText, '"process_id":\s*\d+', '"process_id": ' + $script:guardLiveProcess.Id)
                    $ledgerText = [regex]::Replace($ledgerText, '"process_name":\s*"[^"]*"', '"process_name": "' + $liveName + '"')
                    $ledgerText = [regex]::Replace($ledgerText, '"process_start_time_utc":\s*"[^"]*"', '"process_start_time_utc": "' + $liveStart + '"')
                    Write-GuardText $ledgerPath $ledgerText
                } },
            @{ id = '(e) ledger 無該派遣的 owner 記錄'; code = 'DispatchAdmissionOwnerUnverifiable'; rejection = $null
                apply = {
                    $lock = Open-DispatchAdmissionLock -SourceRoot $real.source_root
                    try {
                        $ledger = Read-DispatchAdmissionLedger -Lock $lock
                        $ledger.Document.entries = @()
                        $null = Write-DispatchAdmissionLedger -Lock $lock -Ledger $ledger
                    }
                    finally { Close-DispatchAdmissionLock -Lock $lock }
                } },
            @{ id = '(f) 舊格式 RunRecord（無 caller_session_fingerprint）'; code = 'DispatchAdmissionOwnerMismatch'; rejection = 'CleanupTakeoverOwnerUnverifiable'
                apply = {
                    $text = [regex]::Replace([IO.File]::ReadAllText($real.run_record_path), ',\s*"caller_session_fingerprint":\s*"[^"]*",\s*"caller_session_source":\s*"[^"]*"', '')
                    Assert-Guard (-not $text.Contains('caller_session_fingerprint')) 'fixture 未移除 RunRecord 的 caller_session_fingerprint。'
                    Write-GuardText $real.run_record_path $text
                } }
        )
        foreach ($fault in $faults) {
            foreach ($key in $mutable.Keys) { [IO.File]::WriteAllBytes($mutable[$key], $originals[$key]) }
            try {
                & $fault.apply
                $before = Get-GuardTreeSnapshot $real.source_root
                $label = $fault.id
                # Cleanup 呼叫的 Assert-DispatchRecoveryOwner 與 provider：驗證拒絕代碼與 Data['takeoverRejection']。
                $ownerOutcome = Get-GuardCleanupOwnerOutcome $real $identityB
                Assert-Guard ($ownerOutcome.error_code -ceq $fault.code) ($label + ' owner 判定應為 ' + $fault.code + '，實際 ' + $ownerOutcome.error_code + '：' + $ownerOutcome.message)
                if ($null -eq $fault.rejection) { Assert-Guard ($null -eq $ownerOutcome.rejection) ($label + ' 不屬放寬範圍，不應帶 takeoverRejection。') }
                else { Assert-Guard ($null -ne $ownerOutcome.rejection -and $ownerOutcome.rejection.code -ceq $fault.rejection) ($label + ' takeoverRejection 應為 ' + $fault.rejection + '，實際 ' + $(if ($null -eq $ownerOutcome.rejection) { '(null)' } else { $ownerOutcome.rejection.code })) }
                Set-GuardCleanupContext $real $identityB
                $cleanup = Invoke-GuardCleanup
                Assert-Guard ($null -eq $cleanup.result -and $cleanup.failure_code -ceq $fault.code) ($label + ' Cleanup 應以 ' + $fault.code + ' 拒絕，實際 ' + $cleanup.failure_code + '：' + $cleanup.message)
                if ($null -ne $fault.rejection) {
                    $cleanupRejection = $cleanup.exception.Data['takeoverRejection']
                    $operationResult = $cleanup.exception.Data['operationResult']
                    Assert-Guard ($null -ne $cleanupRejection -and $cleanupRejection.code -ceq $fault.rejection) ($label + ' Cleanup 最終例外的 takeoverRejection 不符。')
                    Assert-Guard ($null -ne $operationResult -and @($operationResult.errors).Count -gt 0 -and $operationResult.errors[0].takeover_rejection.code -ceq $fault.rejection) ($label + ' Cleanup operationResult 的 takeover_rejection 不符。')
                }
                $collect = Invoke-GuardCollect $real $identityB $baseline
                Assert-Guard ($null -eq $collect.result -and $collect.error_code -ceq $fault.code) ($label + ' Collect 應以 ' + $fault.code + ' 拒絕，實際 ' + $collect.error_code + '：' + $collect.message)
                if ($null -ne $fault.rejection) { Assert-Guard ($null -ne $collect.rejection -and $collect.rejection.code -ceq $fault.rejection) ($label + ' Collect takeoverRejection 不符。') }
                $script:observations.Add([pscustomobject]@{ fault = $label; owner_error_code = $ownerOutcome.error_code; takeover_rejection_code = $(if ($null -eq $ownerOutcome.rejection) { $null } else { [string]$ownerOutcome.rejection.code }); cleanup_failure_code = $cleanup.failure_code; collect_error_code = $collect.error_code; collect_rejection_code = $(if ($null -eq $collect.rejection) { $null } else { [string]$collect.rejection.code }) })
                $after = Get-GuardTreeSnapshot $real.source_root
                Assert-Guard ($before -ceq $after) ($label + ' 拒絕後來源或 worktree 雜湊改變。')
                Assert-Guard (@(Get-GuardTakeoverAuditFiles $real.source_root).Count -eq 0) ($label + ' 不應產生稽核檔。')
                Assert-Guard ((Test-Path -LiteralPath $real.dispatch_root) -and [IO.File]::ReadAllText((Join-Path $real.source_root 'target.txt')) -ceq 'guard target') ($label + ' worktree 應保留且來源未被套回。')
            }
            finally {
                $script:CallerSessionIdentity = $null
                if ($null -ne $script:guardLiveProcess) {
                    try { $script:guardLiveProcess.Kill() } catch { }
                    try { $null = $script:guardLiveProcess.WaitForExit(5000) } catch { }
                    $script:guardLiveProcess.Dispose()
                    $script:guardLiveProcess = $null
                }
            }
        }
    }
    finally {
        if ($null -ne $script:guardLiveProcess) { try { $script:guardLiveProcess.Kill() } catch { }; $script:guardLiveProcess = $null }
        Remove-GuardWorktree $real.source_root $real.dispatch_root
    }
}

# T132 負向 (h)：Collect 接手稽核寫入失敗時，不套回任何檔案。
Invoke-GuardCase 'DD-OWNER-TAKEOVER Collect audit write failure applies nothing (h)' {
    $real = New-GuardRealDispatch
    $script:guardAtomicOriginal = (Get-Command Write-DispatchAtomicJsonDocument -CommandType Function).ScriptBlock
    try {
        $identityB = Get-GuardIdentity 'guard-session-b'
        $baseline = Get-GuardBaseline $real
        Write-GuardText (Join-Path $real.dispatch_root 'target.txt') 'collected change'
        $before = Get-GuardTreeSnapshot $real.source_root
        # 模擬稽核目錄不可寫：僅對 collect-takeover 稽核路徑拋出，其餘寫入維持原行為。
        Set-Item Function:\Write-DispatchAtomicJsonDocument {
            $pathIndex = [Array]::IndexOf(@($args), '-Path')
            if ($pathIndex -ge 0 -and ([string]$args[$pathIndex + 1]) -like '*collect-takeover-*') { throw 'simulated unwritable audit directory' }
            & $script:guardAtomicOriginal @args
        }
        $collect = Invoke-GuardCollect $real $identityB $baseline
        Set-Item Function:\Write-DispatchAtomicJsonDocument $script:guardAtomicOriginal
        Assert-Guard ($null -eq $collect.result -and $collect.error_code -ceq 'CollectTakeoverAuditWriteFailed') ('稽核寫入失敗應為 CollectTakeoverAuditWriteFailed：' + $collect.error_code + ' ' + $collect.message)
        Assert-Guard ([IO.File]::ReadAllText((Join-Path $real.source_root 'target.txt')) -ceq 'guard target') '稽核寫入失敗時不得套回任何檔案。'
        Assert-Guard (@(Get-GuardTakeoverAuditFiles $real.source_root).Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $real.source_root '.local\ai-sessions\history\a\collect-apply-ledger.json'))) '稽核寫入失敗時不應留下稽核檔或套回帳冊。'
        Assert-Guard ((Get-GuardTreeSnapshot $real.source_root) -ceq $before) '稽核寫入失敗後來源或 worktree 雜湊改變。'
    }
    finally {
        Set-Item Function:\Write-DispatchAtomicJsonDocument $script:guardAtomicOriginal
        Remove-GuardWorktree $real.source_root $real.dispatch_root
    }
}

# 靜態斷言：Test-CleanupTakeoverTerminal 函式本體在 Phase 14 範圍內無變更；TerminalTakeoverProof 在 Invoke-DispatchConcurrency.ps1 存在。
Invoke-GuardCase 'DD-OWNER-TAKEOVER static coverage' {
    $concurrencyText = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'dispatch/Invoke-DispatchConcurrency.ps1'))
    Assert-Guard (@([regex]::Matches($concurrencyText, 'TerminalTakeoverProof')).Count -gt 0) 'TerminalTakeoverProof 不存在於 Invoke-DispatchConcurrency.ps1。'
    $cleanupPath = Join-Path $scriptsRoot 'dispatch/cleanup.ps1'
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($cleanupPath, [ref]$tokens, [ref]$errors)
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-CleanupTakeoverTerminal' }, $true)
    Assert-Guard ($null -ne $function) '找不到 Test-CleanupTakeoverTerminal。'
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $diff = @(& git -C $repoRoot diff -U0 -- scripts/dispatch/cleanup.ps1 2>&1 | ForEach-Object { [string]$_ })
        $diffExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    Assert-Guard ($diffExit -eq 0) 'git diff 失敗。'
    foreach ($line in $diff) {
        $hunk = [regex]::Match($line, '^@@ -\d+(?:,\d+)? \+(?<start>\d+)(?:,(?<count>\d+))? @@')
        if (-not $hunk.Success) { continue }
        $start = [int]$hunk.Groups['start'].Value
        $count = if ($hunk.Groups['count'].Success) { [int]$hunk.Groups['count'].Value } else { 1 }
        if ($count -eq 0) { $start++; $end = $start - 1 } else { $end = $start + $count - 1 }
        $overlaps = $count -gt 0 -and $start -le $function.Extent.EndLineNumber -and $end -ge $function.Extent.StartLineNumber
        Assert-Guard (-not $overlaps) ('Test-CleanupTakeoverTerminal 函式本體有變更：' + $line)
    }
}

$failed = @($script:cases | Where-Object { $_.result -eq 'FAIL' })
$coverageGaps = @()
$result = if ($script:cases.Count -gt 0 -and $failed.Count -eq 0 -and $coverageGaps.Count -eq 0) { 'PASS' } else { 'FAIL' }
$summary = [ordered]@{ result = $result; test_count = $script:cases.Count; failed = $failed.Count; coverage_gaps = $coverageGaps; cases = @($script:cases.ToArray()); negative_observations = @($script:observations.ToArray()); powershell_version = $PSVersionTable.PSVersion.ToString() }
[IO.File]::WriteAllText($summaryPath, (ConvertTo-Json -InputObject $summary -Depth 30), (New-Object Text.UTF8Encoding($false)))
[Console]::Out.WriteLine((ConvertTo-Json -InputObject ([ordered]@{ result = $result; test_count = $script:cases.Count; failed = $failed.Count; summary_path = $summaryPath; powershell_version = $PSVersionTable.PSVersion.ToString() }) -Compress))
if ($result -eq 'FAIL') { exit 1 }
exit 0
