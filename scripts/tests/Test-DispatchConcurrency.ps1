#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Worker,
    [string]$WorkerConfigPath,
    [string]$FixtureBaseRootPath = $env:TEMP,
    [string]$EvidencePath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$scriptsRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $scriptsRoot
$script:SourceRoot = ''
$script:ExecutionRoot = ''
$script:TargetPath = @()
$script:LineSlug = ''
$script:DispatchSlug = ''
$script:RunRecordPath = ''
$script:PreflightResultPath = ''
$script:RequestContext = $null
$script:CallerSessionIdentity = $null
$script:QuotaTestReplacement = ''
$script:T049EvidenceRoot = ''
$script:T049OwnerIdentity = $null

foreach ($moduleName in @(
        'common-runtime.ps1', 'git-baseline.ps1', 'dispatch-scope.ps1', 'dispatch-evidence.ps1',
        'quota-observation.ps1', 'advisor-evidence.ps1', 'process-identity.ps1', 'reviewer-contract.ps1',
        'run-recovery.ps1', 'prepare-stage.ps1', 'dispatch-lifecycle.ps1', 'start-lifecycle.ps1',
        'inspect-lifecycle.ps1', 'collect-contract.ps1', 'cleanup.ps1', 'Invoke-DispatchConcurrency.ps1')) {
    . (Join-Path (Join-Path $scriptsRoot 'dispatch') $moduleName)
}

function Get-TestErrorCode {
    param([Parameter(Mandatory)][System.Exception]$Exception)
    if ($null -ne $Exception.Data['errorCode']) { return [string]$Exception.Data['errorCode'] }
    if ($Exception.Message -match '^([A-Za-z][A-Za-z0-9]+)：') { return [string]$Matches[1] }
    return 'UnhandledTestException'
}

function Get-TestHash {
    param([Parameter(Mandatory)][string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Write-TestJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Value)
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 50), (New-Object Text.UTF8Encoding($false)))
}

function Get-TestProcessIdentity {
    $process = [Diagnostics.Process]::GetCurrentProcess()
    try {
        return [pscustomobject]@{
            ProcessId = $process.Id
            ProcessName = $process.ProcessName
            ProcessStartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
            RunRecordPath = ''
            PidRecordPath = ''
        }
    }
    finally { $process.Dispose() }
}

function Get-TestRecordArray {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    $records = New-Object 'System.Collections.Generic.List[object]'
    foreach ($record in $Value) {
        if ($record -is [array]) {
            foreach ($nestedRecord in $record) {
                if ($null -ne $nestedRecord) { $records.Add($nestedRecord) }
            }
        }
        elseif ($null -ne $record) {
            $records.Add($record)
        }
    }
    return $records.ToArray()
}

function Set-QuotaSnapshotFromCodex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$CodexHome,
        [string]$SourceRoot,
        [string]$ExecutionRoot,
        [string[]]$TargetPath,
        [string]$HistoryRoot,
        [string]$Purpose,
        [switch]$Required
    )
    [IO.File]::WriteAllText($Path, $script:QuotaTestReplacement, (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Path = $Path }
}

function Wait-TestMarker {
    param([Parameter(Mandatory)][string]$Path, [Diagnostics.Process[]]$Processes, [int]$TimeoutSeconds = 60)
    $limit = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $limit) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return }
        foreach ($process in $Processes) {
            if ($process.HasExited) { throw ('worker 提前結束；pid=' + $process.Id + '; marker=' + $Path + '; exit=' + $process.ExitCode) }
        }
        Start-Sleep -Milliseconds 25
    }
    throw ('IPC barrier timeout：' + $Path)
}

function ConvertTo-TestArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-TestWorker {
    param([Parameter(Mandatory)][string]$ConfigPath)
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $scenarioRoot = [string]$config.scenario_root
    $workerId = [string]$config.worker_id
    $script:SourceRoot = [string]$config.source_root
    $script:ExecutionRoot = [string]$config.execution_root
    $script:LineSlug = [string]$config.line_slug
    $script:DispatchSlug = [string]$config.dispatch_slug
    $script:QuotaTestReplacement = [string]$config.quota_replacement
    $ownerStartValue = $config.owner_process_start_time_utc
    $ownerStartUtc = if ($ownerStartValue -is [DateTime]) { $ownerStartValue.ToUniversalTime().ToString('o') } else { [string]$ownerStartValue }
    $ownerIdentity = [pscustomobject]@{
        ProcessId = [int]$config.owner_process_id
        ProcessName = [string]$config.owner_process_name
        ProcessStartTimeUtc = $ownerStartUtc
        RunRecordPath = ''
        PidRecordPath = ''
    }
    $identity = [pscustomobject]@{ Fingerprint = [string]$config.caller_fingerprint; Source = [string]$config.caller_source }
    [IO.File]::WriteAllText((Join-Path $scenarioRoot ('ready-' + $workerId)), [DateTime]::UtcNow.ToString('o'))
    Wait-TestMarker -Path (Join-Path $scenarioRoot 'go')
    $result = $null
    $started = [DateTime]::UtcNow.ToString('o')
    try {
        switch ([string]$config.action) {
            'admission' {
                $marker = [string]$config.pid_marker_path
                $parameters = @{
                    SourceRoot = $script:SourceRoot
                    CallerIdentity = $identity
                    LineSlug = $script:LineSlug
                    DispatchSlug = $script:DispatchSlug
                    WriteMode = [string]$config.write_mode
                    WritePaths = @($config.write_paths)
                    PidCheckAction = { return [pscustomobject]@{ Blocked = (-not [string]::IsNullOrWhiteSpace($marker) -and (Test-Path -LiteralPath $marker -PathType Leaf)) } }
                    StartAction = { if (-not [string]::IsNullOrWhiteSpace($marker)) { [IO.File]::WriteAllText($marker, [string]$ownerIdentity.ProcessId) }; return $ownerIdentity }
                }
                $admission = Invoke-DispatchAdmissionStart @parameters
                $result = [ordered]@{ worker_id = $workerId; status = 'admitted'; error_code = $null; dispatch_slug = $script:DispatchSlug; pid = $admission.Process.ProcessId; started_at_utc = $started; finished_at_utc = [DateTime]::UtcNow.ToString('o') }
            }
            'source' {
                $baseline = Get-Content -LiteralPath ([string]$config.baseline_path) -Raw -Encoding UTF8 | ConvertFrom-Json
                $parameters = @{
                    SourceRoot = $script:SourceRoot
                    DispatchRoot = $script:ExecutionRoot
                    Path = @('payload.txt')
                    Baseline = $baseline
                    CallerIdentity = $identity
                    LineSlug = $script:LineSlug
                    DispatchSlug = $script:DispatchSlug
                    RunRecordPath = ''
                }
                $applied = Invoke-DispatchSourceIntegration @parameters
                $result = [ordered]@{ worker_id = $workerId; status = [string]$applied.status; error_code = $null; dispatch_slug = $script:DispatchSlug; started_at_utc = $started; finished_at_utc = [DateTime]::UtcNow.ToString('o'); worktree_preserved = [bool]$applied.worktree_preserved }
            }
            'quota' {
                $parameters = @{
                    Path = [string]$config.quota_path
                    ExpectedSha256 = [string]$config.expected_sha256
                    SourceRoot = $script:SourceRoot
                    ExecutionRoot = $script:ExecutionRoot
                    TargetPath = @()
                }
                $updated = Update-AdvisorAfterSnapshotFromCodex @parameters
                $result = [ordered]@{ worker_id = $workerId; status = 'replaced'; error_code = $null; sha256 = [string]$updated.Sha256; started_at_utc = $started; finished_at_utc = [DateTime]::UtcNow.ToString('o') }
            }
            default { throw ('未知的 worker action：' + [string]$config.action) }
        }
    }
    catch {
        $result = [ordered]@{ worker_id = $workerId; status = 'rejected'; error_code = Get-TestErrorCode -Exception $_.Exception; error = $_.Exception.Message; dispatch_slug = $script:DispatchSlug; started_at_utc = $started; finished_at_utc = [DateTime]::UtcNow.ToString('o') }
    }
    Write-TestJson -Path (Join-Path $scenarioRoot ('result-' + $workerId + '.json')) -Value $result
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $result -Depth 20 -Compress))
    Wait-TestMarker -Path (Join-Path $scenarioRoot 'release') -TimeoutSeconds 120
    exit 0
}

if ($Worker) {
    if ([string]::IsNullOrWhiteSpace($WorkerConfigPath)) { throw 'WorkerConfigPath 不可為空白。' }
    Invoke-TestWorker -ConfigPath $WorkerConfigPath
}

function New-WorkerConfig {
    param(
        [string]$ScenarioRoot, [string]$WorkerId, [string]$SourceRoot, [string]$ExecutionRoot,
        [string]$DispatchSlug, [string]$CallerTag, [ValidateSet('write', 'readonly')][string]$WriteMode,
        [string]$Action, [object[]]$WritePaths = @(), [string]$PidMarkerPath,
        [string]$BaselinePath, [string]$QuotaPath, [string]$ExpectedSha256, [string]$QuotaReplacement
    )
    return [ordered]@{
        scenario_root = $ScenarioRoot
        worker_id = $WorkerId
        source_root = $SourceRoot
        execution_root = $ExecutionRoot
        line_slug = 't049-concurrency'
        dispatch_slug = $DispatchSlug
        caller_fingerprint = Get-TestHash -Value ('test-caller:' + $CallerTag)
        caller_source = 'test'
        owner_process_id = [int]$script:T049OwnerIdentity.ProcessId
        owner_process_name = [string]$script:T049OwnerIdentity.ProcessName
        owner_process_start_time_utc = [string]$script:T049OwnerIdentity.ProcessStartTimeUtc
        write_mode = $WriteMode
        action = $Action
        write_paths = @($WritePaths)
        pid_marker_path = $PidMarkerPath
        baseline_path = $BaselinePath
        quota_path = $QuotaPath
        expected_sha256 = $ExpectedSha256
        quota_replacement = $QuotaReplacement
    }
}

function Invoke-WorkerBatch {
    param([string]$ScenarioName, [string]$ScenarioRoot, [object[]]$Configurations)
    $null = [IO.Directory]::CreateDirectory($ScenarioRoot)
    $hostPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $workers = New-Object Collections.Generic.List[object]
    $barrierUtc = ''
    try {
        foreach ($config in $Configurations) {
            $configPath = Join-Path $ScenarioRoot ('worker-' + $config.worker_id + '.json')
            Write-TestJson -Path $configPath -Value $config
            $args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-Worker', '-WorkerConfigPath', $configPath)
            $process = New-Object Diagnostics.Process
            $startInfo = New-Object Diagnostics.ProcessStartInfo
            $startInfo.FileName = $hostPath
            $startInfo.Arguments = (($args | ForEach-Object { ConvertTo-TestArgument ([string]$_) }) -join ' ')
            $startInfo.WorkingDirectory = $repoRoot
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $utf8 = New-Object Text.UTF8Encoding($false)
            $startInfo.StandardOutputEncoding = $utf8
            $startInfo.StandardErrorEncoding = $utf8
            $startInfo.EnvironmentVariables['PSExecutionPolicyPreference'] = 'Bypass'
            $process.StartInfo = $startInfo
            if (-not $process.Start()) { throw ('worker 啟動失敗：' + $config.worker_id) }
            $workers.Add([pscustomobject]@{
                Id = [string]$config.worker_id
                Config = $config
                Process = $process
                Stdout = $process.StandardOutput.ReadToEndAsync()
                Stderr = $process.StandardError.ReadToEndAsync()
                Command = $hostPath + ' ' + $startInfo.Arguments
            })
        }
        foreach ($config in $Configurations) {
            Wait-TestMarker -Path (Join-Path $ScenarioRoot ('ready-' + $config.worker_id)) -Processes @($workers | ForEach-Object { $_.Process })
        }
        $barrierUtc = [DateTime]::UtcNow.ToString('o')
        [IO.File]::WriteAllText((Join-Path $ScenarioRoot 'go'), $barrierUtc)
        foreach ($config in $Configurations) {
            Wait-TestMarker -Path (Join-Path $ScenarioRoot ('result-' + $config.worker_id + '.json')) -Processes @($workers | ForEach-Object { $_.Process }) -TimeoutSeconds 90
        }
    }
    finally {
        [IO.File]::WriteAllText((Join-Path $ScenarioRoot 'release'), [DateTime]::UtcNow.ToString('o'))
        foreach ($worker in $workers) {
            if (-not $worker.Process.HasExited) { $null = $worker.Process.WaitForExit(30000) }
            $stdout = if ($worker.Stdout.IsCompleted) { [string]$worker.Stdout.Result } else { '' }
            $stderr = if ($worker.Stderr.IsCompleted) { [string]$worker.Stderr.Result } else { '' }
            [IO.File]::WriteAllText((Join-Path $ScenarioRoot ($worker.Id + '.stdout.txt')), $stdout, (New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText((Join-Path $ScenarioRoot ($worker.Id + '.stderr.txt')), $stderr, (New-Object Text.UTF8Encoding($false)))
        }
    }
    $evidenceScenarioRoot = Join-Path $script:T049EvidenceRoot $ScenarioName
    $null = [IO.Directory]::CreateDirectory($evidenceScenarioRoot)
    foreach ($sharedPath in @((Join-Path $ScenarioRoot 'go'), (Join-Path $ScenarioRoot 'release'))) {
        if (Test-Path -LiteralPath $sharedPath -PathType Leaf) {
            [IO.File]::Copy($sharedPath, (Join-Path $evidenceScenarioRoot (Split-Path -Leaf $sharedPath)), $true)
        }
    }
    foreach ($sourceFile in @(Get-ChildItem -LiteralPath $ScenarioRoot -File -Force)) {
        [IO.File]::Copy($sourceFile.FullName, (Join-Path $evidenceScenarioRoot $sourceFile.Name), $true)
    }
    $participants = New-Object Collections.Generic.List[object]
    foreach ($worker in $workers) {
        $path = Join-Path $ScenarioRoot ('result-' + $worker.Id + '.json')
        $evidenceStdoutPath = Join-Path $evidenceScenarioRoot ($worker.Id + '.stdout.txt')
        $evidenceStderrPath = Join-Path $evidenceScenarioRoot ($worker.Id + '.stderr.txt')
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $result = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $participants.Add([pscustomobject]@{
                worker_id = $worker.Id
                dispatch_slug = [string]$worker.Config.dispatch_slug
                caller_session_fingerprint = [string]$worker.Config.caller_fingerprint
                status = [string]$result.status
                error_code = [string]$result.error_code
                started_at_utc = [string]$result.started_at_utc
                finished_at_utc = [string]$result.finished_at_utc
                process_id = $worker.Process.Id
                command = $worker.Command
                exit_code = $worker.Process.ExitCode
                result_path = Join-Path $evidenceScenarioRoot ('result-' + $worker.Id + '.json')
                stdout_path = $evidenceStdoutPath
                stderr_path = $evidenceStderrPath
            })
        }
        $worker.Process.Dispose()
    }
    return [pscustomobject]@{ scenario = $ScenarioName; synchronization_point = Join-Path $evidenceScenarioRoot 'go'; barrier_released_at_utc = $barrierUtc; participants = @($participants.ToArray()) }
}

function Assert-Batch {
    param([object]$Batch, [int]$Admitted, [int]$Rejected, [string]$ErrorCode)
    $admittedCount = @($Batch.participants | Where-Object { $_.status -in @('admitted', 'applied', 'replaced') }).Count
    $rejectedRows = @($Batch.participants | Where-Object { $_.status -eq 'rejected' })
    if ($admittedCount -ne $Admitted -or $rejectedRows.Count -ne $Rejected) { throw ('競態結果筆數錯誤：' + $Batch.scenario + '; expected_admitted=' + $Admitted + '; actual_admitted=' + $admittedCount + '; expected_rejected=' + $Rejected + '; actual_rejected=' + $rejectedRows.Count) }
    if ($Rejected -gt 0 -and @($rejectedRows | Where-Object { $_.error_code -eq $ErrorCode }).Count -ne $Rejected) {
        throw ('競態錯誤碼錯誤：' + $Batch.scenario + '; expected=' + $ErrorCode + '; actual=' + (($rejectedRows | ForEach-Object { [string]$_.error_code + ': ' + [string]$_.stdout_path }) -join '; '))
    }
    foreach ($row in $Batch.participants) {
        if ($row.exit_code -ne 0 -or (Get-Item -LiteralPath $row.stderr_path).Length -gt 0) { throw ('worker 執行失敗：' + $row.worker_id) }
    }
}

function Add-TestOwner {
    param(
        [string]$SourceRoot,
        [string]$LineSlug,
        [string]$DispatchSlug,
        [object]$Identity,
        [switch]$Unknown,
        [ValidateSet('readonly', 'write')][string]$WriteMode = 'write',
        [string]$PidRecordPath = ''
    )
    $processIdentity = Get-TestProcessIdentity
    $lock = Open-DispatchAdmissionLock -SourceRoot $SourceRoot
    try {
        $ledger = Read-DispatchAdmissionLedger -Lock $lock
        $entry = [pscustomobject]@{
            caller_session_fingerprint = [string]$Identity.Fingerprint
            caller_session_source = [string]$Identity.Source
            process_id = if ($Unknown) { 2147483646 } else { $processIdentity.ProcessId }
            process_name = if ($Unknown) { '' } else { $processIdentity.ProcessName }
            process_start_time_utc = if ($Unknown) { 'invalid' } else { $processIdentity.ProcessStartTimeUtc }
            line_slug = $LineSlug
            dispatch_slug = $DispatchSlug
            write_mode = $WriteMode
            write_paths = @()
            state = 'active'
            admitted_at_utc = [DateTime]::UtcNow.ToString('o')
            run_record_path = ''
            pid_record_path = $PidRecordPath
        }
        $ledger.Document.entries = @($ledger.Document.entries) + @($entry)
        $null = Write-DispatchAdmissionLedger -Lock $lock -Ledger $ledger
    }
    finally { Close-DispatchAdmissionLock -Lock $lock }
}

function Write-TestPidRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [Parameter(Mandatory)][ValidateSet('readonly', 'write')][string]$WriteMode,
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][object]$ProcessSnapshot,
        [bool]$IdentityVerified = $true
    )

    $historyRoot = Join-Path $SourceRoot '.local\ai-sessions\history'
    $null = [System.IO.Directory]::CreateDirectory($historyRoot)
    $recordPath = Join-Path $historyRoot ('codex-pid-' + $DispatchSlug + '-' + [guid]::NewGuid().ToString('N') + '.txt')
    $rootProcessName = [string](Get-DispatchJsonProperty -Object $ProcessSnapshot -Name 'ProcessName')
    $rootParentPid = [string](Get-DispatchJsonProperty -Object $ProcessSnapshot -Name 'ParentProcessId')
    $creationUtc = Get-DispatchJsonProperty -Object $ProcessSnapshot -Name 'CreationUtc'
    if ($null -eq $creationUtc) { throw 'PID fixture 缺少 CreationUtc。' }
    $rootStartedAtUtc = ([datetime]$creationUtc).ToUniversalTime().ToString('o')
    $identityStatus = [string](Get-DispatchJsonProperty -Object $ProcessSnapshot -Name 'IdentityStatus')
    $identityValue = if ($IdentityVerified) { 'true' } else { 'false' }
    $fields = [ordered]@{
        pid = $ProcessId
        'root-pid' = $ProcessId
        'root-process-name' = $rootProcessName
        'root-parent-pid' = $rootParentPid
        'root-started-at-utc' = $rootStartedAtUtc
        'identity-status' = $identityStatus
        'identity-verified' = $identityValue
        'process-tree-scope' = 'pid-and-descendants'
        'process-tree-query' = 'Win32_Process.ParentProcessId'
        'process-group-id' = $ProcessId
        'work-root' = [System.IO.Path]::GetFullPath($SourceRoot)
        'line-slug' = $LineSlug
        'dispatch-slug' = $DispatchSlug
        'write-mode' = $WriteMode
        'caller-session-fingerprint' = 'unknown'
        'caller-session-source' = 'test'
        'started-at-utc' = [DateTime]::UtcNow.ToString('o')
    }
    $content = foreach ($field in $fields.GetEnumerator()) { [string]$field.Key + '=' + [string]$field.Value }
    [System.IO.File]::WriteAllText($recordPath, (($content -join [Environment]::NewLine) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    return $recordPath
}

function Get-TestPidCheckResult {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][ValidateSet('readonly', 'write')][string]$WriteMode,
        [Parameter(Mandatory)][object]$CallerIdentity
    )

    $previousIdentity = $script:CallerSessionIdentity
    $script:CallerSessionIdentity = $CallerIdentity
    try {
        return Get-PidCheckResult -SourceRoot $SourceRoot -LineSlug $LineSlug -WriteMode $WriteMode
    }
    finally {
        $script:CallerSessionIdentity = $previousIdentity
    }
}

function Invoke-TestPidAdmission {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][object]$CallerIdentity,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [Parameter(Mandatory)][ValidateSet('readonly', 'write')][string]$WriteMode,
        [Parameter(Mandatory)][object]$PidCheckResult
    )

    $previousIdentity = $script:CallerSessionIdentity
    $script:CallerSessionIdentity = $CallerIdentity
    try {
        $pidCheckAction = { return [pscustomobject]@{ Blocked = $false; PidCheckResult = $PidCheckResult } }
        $pidCheckAction = $pidCheckAction.GetNewClosure()
        $startAction = { return Get-TestProcessIdentity }
        $parameters = @{
            SourceRoot = $SourceRoot
            CallerIdentity = $CallerIdentity
            LineSlug = $LineSlug
            DispatchSlug = $DispatchSlug
            WriteMode = $WriteMode
            WritePaths = @()
            PidCheckAction = $pidCheckAction
            StartAction = $startAction
        }
        return Invoke-DispatchAdmissionStart @parameters
    }
    finally {
        $script:CallerSessionIdentity = $previousIdentity
    }
}

function Invoke-TestGit {
    param([string]$Root, [string[]]$Arguments)
    $output = & git -C $Root @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('git ' + ($Arguments -join ' ') + ' failed: ' + ($output -join ' ')) }
    return @($output)
}

function Test-CleanupOwner {
    param([string]$FixtureRoot)
    $EvidencePath = @()
    $sourceRoot = Join-Path $FixtureRoot 'cleanup-source'
    $null = [IO.Directory]::CreateDirectory($sourceRoot)
    $null = Invoke-TestGit $sourceRoot @('init', '--quiet')
    $null = Invoke-TestGit $sourceRoot @('config', 'user.name', 'T049 Fixture')
    $null = Invoke-TestGit $sourceRoot @('config', 'user.email', 't049-fixture@example.invalid')
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'README.md'), 'fixture')
    $null = Invoke-TestGit $sourceRoot @('add', 'README.md')
    $null = Invoke-TestGit $sourceRoot @('commit', '--quiet', '-m', 'fixture')
    $line = 't049-cleanup'
    $slug = 't049-owner-worktree'
    $dispatchRoot = Join-Path $sourceRoot ('.local\ai-sessions\worktrees\' + $slug)
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $dispatchRoot))
    $null = Invoke-TestGit $sourceRoot @('worktree', 'add', '--quiet', '--detach', $dispatchRoot, 'HEAD')
    $reportRoot = Join-Path $dispatchRoot ('.local\ai-sessions\report\' + $line)
    $null = [IO.Directory]::CreateDirectory($reportRoot)
    [IO.File]::WriteAllText((Join-Path $reportRoot 'closure.md'), 'fixture report')
    $preflight = Join-Path $dispatchRoot 'preflight.json'
    Write-TestJson $preflight ([ordered]@{ sourceRoot = $sourceRoot; dispatchRoot = $dispatchRoot; lineSlug = $line; dispatchSlug = $slug })
    $owner = [pscustomobject]@{ Fingerprint = Get-TestHash 'owner-session'; Source = 'request' }
    $start = @{
        SourceRoot = $sourceRoot
        CallerIdentity = $owner
        LineSlug = $line
        DispatchSlug = $slug
        WriteMode = 'write'
        PidCheckAction = { return [pscustomobject]@{ Blocked = $false } }
        StartAction = { return Get-TestProcessIdentity }
    }
    $null = Invoke-DispatchAdmissionStart @start
    $script:SourceRoot = $sourceRoot
    $script:ExecutionRoot = $dispatchRoot
    $script:LineSlug = $line
    $script:DispatchSlug = $slug
    $script:PreflightResultPath = $preflight
    $script:RunRecordPath = ''
    $script:EvidencePath = @()
    $script:CallerSessionIdentity = [pscustomobject]@{ Fingerprint = 'different-owner'; Source = 'cli' }
    $mismatch = ''
    try { $null = Invoke-Cleanup -Confirm:$false } catch { $mismatch = Get-TestErrorCode $_.Exception }
    if ($mismatch -ne 'DispatchAdmissionOwnerMismatch' -or -not (Test-Path -LiteralPath $dispatchRoot)) { throw 'Cleanup 未拒絕不同 caller owner。' }
    Add-TestOwner $sourceRoot $line $slug $owner -Unknown
    $script:CallerSessionIdentity = $owner
    $unknown = ''
    try { $null = Invoke-Cleanup -Confirm:$false } catch { $unknown = Get-TestErrorCode $_.Exception }
    if ($unknown -ne 'DispatchAdmissionOwnerUnknown' -or -not (Test-Path -LiteralPath $dispatchRoot)) { throw 'Cleanup 未對未知 owner fail closed。' }
    $lock = Open-DispatchAdmissionLock $sourceRoot
    try {
        $ledger = Read-DispatchAdmissionLedger $lock
        $processIdentity = Get-TestProcessIdentity
        foreach ($entry in @($ledger.Document.entries | Where-Object { $_.dispatch_slug -ceq $slug })) {
            $entry.process_id = $processIdentity.ProcessId
            $entry.process_name = $processIdentity.ProcessName
            $entry.process_start_time_utc = $processIdentity.ProcessStartTimeUtc
            $entry.state = 'active'
        }
        $null = Write-DispatchAdmissionLedger $lock $ledger
    }
    finally { Close-DispatchAdmissionLock $lock }
    $activeOwner = ''
    try { $null = Invoke-Cleanup -Confirm:$false }
    catch { if ($_.Exception.Message -match '^(CleanupProcessNotEnded)：') { $activeOwner = $Matches[1] } else { $activeOwner = Get-TestErrorCode $_.Exception } }
    if ($activeOwner -ne 'CleanupProcessNotEnded' -or -not (Test-Path -LiteralPath $dispatchRoot)) { throw 'Cleanup 未拒絕仍存活的 owner。' }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Start-Sleep -Milliseconds 500"'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $endedProcess = New-Object Diagnostics.Process
    $endedProcess.StartInfo = $info
    try {
        $null = $endedProcess.Start()
        $endedIdentity = [pscustomobject]@{ ProcessId = $endedProcess.Id; ProcessName = $endedProcess.ProcessName; ProcessStartTimeUtc = $endedProcess.StartTime.ToUniversalTime().ToString('o') }
        if (-not $endedProcess.WaitForExit(10000)) { throw 'Cleanup owner fixture process timeout.' }
        $lock = Open-DispatchAdmissionLock $sourceRoot
        try {
            $ledger = Read-DispatchAdmissionLedger $lock
            foreach ($entry in @($ledger.Document.entries | Where-Object { $_.dispatch_slug -ceq $slug })) {
                $entry.process_id = $endedIdentity.ProcessId
                $entry.process_name = $endedIdentity.ProcessName
                $entry.process_start_time_utc = $endedIdentity.ProcessStartTimeUtc
                $entry.state = 'active'
            }
            $null = Write-DispatchAdmissionLedger $lock $ledger
        }
        finally { Close-DispatchAdmissionLock $lock }
    }
    finally {
        if (-not $endedProcess.HasExited) { $endedProcess.Kill(); $endedProcess.WaitForExit() }
        $endedProcess.Dispose()
    }
    $removed = Invoke-Cleanup -Confirm:$false
    if ($removed.status -ne 'completed' -or -not $removed.worktree_removed -or (Test-Path -LiteralPath $dispatchRoot)) { throw 'owner 相符的 Cleanup 未移除 worktree。' }
    return [pscustomobject]@{ scenario = 'cleanup-owner'; different_owner_error = $mismatch; unknown_owner_error = $unknown; active_owner_error = $activeOwner; matching_owner_status = $removed.status; worktree_removed = $removed.worktree_removed }
}

function Invoke-TestMain {
    param(
        [string]$FixtureBaseRootPath = $env:TEMP,
        [string]$EvidencePath
    )
    if (-not (Test-IsWindowsPlatform)) { throw 'T049 競態驗證需要 Windows PowerShell 與 Git worktree。' }
    if ([string]::IsNullOrWhiteSpace($FixtureBaseRootPath)) { throw 'FixtureBaseRootPath 不可為空白。' }
    $base = [IO.Path]::GetFullPath($FixtureBaseRootPath).TrimEnd([char[]]@('\', '/'))
    $fixture = [IO.Path]::GetFullPath((Join-Path $base ('.local\ai-sessions\scratch\t049-' + [guid]::NewGuid().ToString('N'))))
    if (-not $fixture.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'T049 fixture 超出 FixtureBaseRootPath。' }
    $null = [IO.Directory]::CreateDirectory($fixture)
    $evidence = if ([string]::IsNullOrWhiteSpace($EvidencePath)) { Join-Path $fixture 'evidence' } else { [IO.Path]::GetFullPath($EvidencePath) }
    $null = [IO.Directory]::CreateDirectory($evidence)
    $script:T049EvidenceRoot = $evidence
    $script:T049OwnerIdentity = Get-TestProcessIdentity
    $cases = New-Object Collections.Generic.List[object]
    $oldClaude = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_SESSION_ID')
    $oldCodex = [Environment]::GetEnvironmentVariable('CODEX_THREAD_ID')
    $completed = $false
    try {
        $sources = New-Object Collections.Generic.List[object]
        [Environment]::SetEnvironmentVariable('CLAUDE_CODE_SESSION_ID', 'synthetic-claude-id')
        [Environment]::SetEnvironmentVariable('CODEX_THREAD_ID', 'synthetic-codex-id')
        $requestId = Get-DispatchCallerSessionIdentity -RequestCallerSessionId 'synthetic-request-id' -RequestCallerSessionIdProvided $true -CliCallerSessionId 'synthetic-cli-id' -CliCallerSessionIdProvided $true
        $cliId = Get-DispatchCallerSessionIdentity -RequestCallerSessionId $null -RequestCallerSessionIdProvided $false -CliCallerSessionId 'synthetic-cli-id' -CliCallerSessionIdProvided $true
        $claudeId = Get-DispatchCallerSessionIdentity -RequestCallerSessionId $null -RequestCallerSessionIdProvided $false -CliCallerSessionId $null -CliCallerSessionIdProvided $false
        [Environment]::SetEnvironmentVariable('CLAUDE_CODE_SESSION_ID', '')
        $codexId = Get-DispatchCallerSessionIdentity -RequestCallerSessionId $null -RequestCallerSessionIdProvided $false -CliCallerSessionId $null -CliCallerSessionIdProvided $false
        foreach ($pair in @(
                [pscustomobject]@{ expected = 'request'; actual = $requestId.Source; identity = $requestId },
                [pscustomobject]@{ expected = 'cli'; actual = $cliId.Source; identity = $cliId },
                [pscustomobject]@{ expected = 'env-claude'; actual = $claudeId.Source; identity = $claudeId },
                [pscustomobject]@{ expected = 'env-codex'; actual = $codexId.Source; identity = $codexId }
            )) {
            if ($pair.expected -cne $pair.actual) { throw ('caller source 不符：' + $pair.expected) }
            $sources.Add([pscustomobject]@{ expected = $pair.expected; actual = $pair.actual; fingerprint = $pair.identity.Fingerprint })
        }
        [Environment]::SetEnvironmentVariable('CODEX_THREAD_ID', '')
        $missing = ''
        try { $null = Get-DispatchCallerSessionIdentity -RequestCallerSessionId $null -RequestCallerSessionIdProvided $false -CliCallerSessionId $null -CliCallerSessionIdProvided $false } catch { $missing = Get-TestErrorCode $_.Exception }
        if ($missing -ne 'CallerSessionIdMissing') { throw 'caller id 缺少時未在 side effect 前拒絕。' }
        $entryText = Get-Content -LiteralPath (Join-Path $scriptsRoot 'Invoke-CodexDispatch.ps1') -Raw -Encoding UTF8
        if ($entryText.IndexOf('Get-DispatchCallerSessionIdentity') -ge $entryText.IndexOf('$result = switch ($Operation)')) { throw 'caller identity resolution 順序錯誤。' }
        $identityRoot = Join-Path $fixture 'identity-ledger'
        $null = [IO.Directory]::CreateDirectory($identityRoot)
        $start = @{ SourceRoot = $identityRoot; CallerIdentity = $requestId; LineSlug = 't049-identity'; DispatchSlug = 't049-request-source'; WriteMode = 'readonly'; PidCheckAction = { return [pscustomobject]@{ Blocked = $false } }; StartAction = { return Get-TestProcessIdentity } }
        $null = Invoke-DispatchAdmissionStart @start
        $ledgerText = Get-Content -LiteralPath (Get-DispatchAdmissionPaths $identityRoot).LedgerPath -Raw -Encoding UTF8
        foreach ($raw in @('synthetic-request-id', 'synthetic-cli-id', 'synthetic-claude-id', 'synthetic-codex-id')) { if ($ledgerText.Contains($raw)) { throw 'ledger 寫入原始 caller ID。' } }
        if (-not $ledgerText.Contains($requestId.Fingerprint)) { throw 'ledger 缺少 caller fingerprint。' }
        $cases.Add([pscustomobject]@{ scenario = 'caller-id-source-and-fingerprint'; outcomes = @($sources.ToArray()); missing_error_code = $missing; raw_id_in_ledger = $false; evidence = (Get-DispatchAdmissionPaths $identityRoot).LedgerPath })

        $writeRoot = Join-Path $fixture 'write-capacity'
        $writeSource = Join-Path $writeRoot 'source'
        $null = [IO.Directory]::CreateDirectory($writeSource)
        $writeConfigs = @(
            (New-WorkerConfig $writeRoot 'write-1' $writeSource $writeSource 't049-write-1' 'same-write-caller' write admission),
            (New-WorkerConfig $writeRoot 'write-2' $writeSource $writeSource 't049-write-2' 'same-write-caller' write admission)
        )
        $writeBatch = Invoke-WorkerBatch 'one-write' $writeRoot $writeConfigs
        Assert-Batch $writeBatch 1 1 'DispatchAdmissionWriteLimit'
        $cases.Add([pscustomobject]@{ scenario = 'one-write-capacity'; participants = @($writeBatch.participants); synchronization_point = $writeBatch.synchronization_point; barrier_released_at_utc = $writeBatch.barrier_released_at_utc; final_state = 'one admitted, one rejected by write limit' })

        $readRoot = Join-Path $fixture 'readonly-capacity'
        $readSource = Join-Path $readRoot 'source'
        $null = [IO.Directory]::CreateDirectory($readSource)
        $readConfigs = @()
        for ($i = 1; $i -le 3; $i++) { $readConfigs += New-WorkerConfig $readRoot ('read-' + $i) $readSource $readSource ('t049-read-' + $i) 'same-read-caller' readonly admission }
        $readBatch = Invoke-WorkerBatch 'two-readonly' $readRoot $readConfigs
        Assert-Batch $readBatch 2 1 'DispatchAdmissionReadonlyLimit'
        $cases.Add([pscustomobject]@{ scenario = 'two-readonly-capacity'; participants = @($readBatch.participants); synchronization_point = $readBatch.synchronization_point; barrier_released_at_utc = $readBatch.barrier_released_at_utc; final_state = 'two admitted, third rejected by readonly limit' })

        $mixedRoot = Join-Path $fixture 'mixed-capacity'
        $mixedSource = Join-Path $mixedRoot 'source'
        $null = [IO.Directory]::CreateDirectory($mixedSource)
        $mixedConfigs = @(
            (New-WorkerConfig $mixedRoot 'write' $mixedSource $mixedSource 't049-mixed-write' 'mixed-caller' write admission),
            (New-WorkerConfig $mixedRoot 'read-1' $mixedSource (Join-Path $mixedRoot 'worktree-one') 't049-mixed-read-1' 'mixed-caller' readonly admission),
            (New-WorkerConfig $mixedRoot 'read-2' $mixedSource (Join-Path $mixedRoot 'worktree-two') 't049-mixed-read-2' 'mixed-caller' readonly admission)
        )
        $mixedBatch = Invoke-WorkerBatch 'write-plus-two-readonly' $mixedRoot $mixedConfigs
        Assert-Batch $mixedBatch 3 0 ''
        $cases.Add([pscustomobject]@{ scenario = 'write-plus-two-readonly'; participants = @($mixedBatch.participants); synchronization_point = $mixedBatch.synchronization_point; final_state = 'one write and two readonly admissions coexist' })

        $overlapRoot = Join-Path $fixture 'overlap'
        $overlapSource = Join-Path $overlapRoot 'source'
        $null = [IO.Directory]::CreateDirectory($overlapSource)
        $parentPath = Join-Path $overlapSource 'component'
        $childPath = Join-Path $parentPath 'child'
        $direct = Get-DispatchAdmissionWritePaths -SourceRoot $overlapSource -ExecutionRoot $overlapSource -WriteMode write -TargetPath @($parentPath) -AddDirectory @()
        $addDir = Get-DispatchAdmissionWritePaths -SourceRoot $overlapSource -ExecutionRoot (Join-Path $overlapRoot 'worktree') -WriteMode write -TargetPath @() -AddDirectory @($childPath)
        $overlapConfigs = @(
            (New-WorkerConfig $overlapRoot 'direct' $overlapSource $overlapSource 't049-direct' 'direct-caller' write admission $direct),
            (New-WorkerConfig $overlapRoot 'adddir' $overlapSource (Join-Path $overlapRoot 'worktree') 't049-adddir' 'adddir-caller' write admission $addDir)
        )
        $overlapBatch = Invoke-WorkerBatch 'parent-child-path-conflict' $overlapRoot $overlapConfigs
        Assert-Batch $overlapBatch 1 1 'DispatchAdmissionPathConflict'
        $cases.Add([pscustomobject]@{ scenario = 'direct-write-vs-add-directory-overlap'; participants = @($overlapBatch.participants); paths = @($direct) + @($addDir); synchronization_point = $overlapBatch.synchronization_point; final_state = 'parent and child paths conflict; one rejected' })

        $separateRoot = Join-Path $fixture 'non-overlap'
        $separateSource = Join-Path $separateRoot 'source'
        $null = [IO.Directory]::CreateDirectory($separateSource)
        $separateOne = Get-DispatchAdmissionWritePaths -SourceRoot $separateSource -ExecutionRoot $separateSource -WriteMode write -TargetPath @(Join-Path $separateSource 'one') -AddDirectory @()
        $separateTwo = Get-DispatchAdmissionWritePaths -SourceRoot $separateSource -ExecutionRoot (Join-Path $separateRoot 'worktree') -WriteMode write -TargetPath @() -AddDirectory @(Join-Path $separateSource 'two')
        $separateConfigs = @(
            (New-WorkerConfig $separateRoot 'one' $separateSource $separateSource 't049-separate-one' 'separate-one' write admission $separateOne),
            (New-WorkerConfig $separateRoot 'two' $separateSource (Join-Path $separateRoot 'worktree') 't049-separate-two' 'separate-two' write admission $separateTwo)
        )
        $separateBatch = Invoke-WorkerBatch 'non-overlap' $separateRoot $separateConfigs
        Assert-Batch $separateBatch 2 0 ''
        $cases.Add([pscustomobject]@{ scenario = 'non-overlapping-paths'; participants = @($separateBatch.participants); paths = @($separateOne) + @($separateTwo); synchronization_point = $separateBatch.synchronization_point; final_state = 'non-overlapping paths both admitted' })

        $pidRoot = Join-Path $fixture 'pid-check-register'
        $pidSource = Join-Path $pidRoot 'source'
        $null = [IO.Directory]::CreateDirectory($pidSource)
        $pidMarker = Join-Path $pidRoot 'pid-registered'
        $pidConfigs = @(
            (New-WorkerConfig $pidRoot 'pid-one' $pidSource $pidSource 't049-pid-race' 'pid-caller-one' write admission @() $pidMarker),
            (New-WorkerConfig $pidRoot 'pid-two' $pidSource $pidSource 't049-pid-race' 'pid-caller-two' write admission @() $pidMarker)
        )
        $pidBatch = Invoke-WorkerBatch 'pid-check-register' $pidRoot $pidConfigs
        Assert-Batch $pidBatch 1 1 'DispatchAdmissionPidConflict'
        $cases.Add([pscustomobject]@{ scenario = 'pid-check-to-register'; participants = @($pidBatch.participants); synchronization_point = $pidBatch.synchronization_point; pid_marker = $pidMarker; final_state = 'PID check, StartAction marker, and ledger registration serialize under one lock' })

        $f001 = [pscustomobject]@{ ActiveRecords = @(); UnconfirmedRecords = @([pscustomobject]@{ DispatchSlug = 'other-dispatch'; IdentityStatus = 'unknown'; Path = 'other.pid' }, [pscustomobject]@{ DispatchSlug = 'current-dispatch'; IdentityStatus = 'unknown'; Path = 'current.pid' }) }
        $blocking = @(Get-BlockingDispatchPidRecords -PidCheckResult $f001 -DispatchSlug 'current-dispatch')
        if ($blocking.Count -ne 1 -or $blocking[0].Path -cne 'current.pid') { throw 'F-001 未依 dispatchSlug 篩選未知 PID owner。' }
        $cases.Add([pscustomobject]@{ scenario = 'f-001-same-line-other-dispatch'; records = @($f001.UnconfirmedRecords); blocking_records = $blocking; final_state = 'another dispatchSlug does not block the current dispatch' })

        $unknownRoot = Join-Path $fixture 'unknown-owner'
        $unknownSource = Join-Path $unknownRoot 'source'
        $null = [IO.Directory]::CreateDirectory($unknownSource)
        $unknownIdentity = [pscustomobject]@{ Fingerprint = Get-TestHash 'old-owner'; Source = 'test' }
        Add-TestOwner $unknownSource 't049-unknown' 't049-old-owner' $unknownIdentity -Unknown
        $unknownCode = ''
        try {
            $newIdentity = [pscustomobject]@{ Fingerprint = Get-TestHash 'new-owner'; Source = 'test' }
            $null = Assert-DispatchAdmission -SourceRoot $unknownSource -CallerIdentity $newIdentity -LineSlug 't049-unknown' -DispatchSlug 't049-new-owner' -WriteMode readonly
        } catch { $unknownCode = Get-TestErrorCode $_.Exception }
        if ($unknownCode -ne 'DispatchAdmissionOwnerUnknown') { throw 'Admission 未對未知舊 owner fail closed。' }
        $cases.Add([pscustomobject]@{ scenario = 'unknown-owner-admission'; error_code = $unknownCode; final_state = 'admission rejected because prior owner identity was unverifiable' })

        $pidSnapshotResult = Get-WindowsProcessSnapshots -FailOnError
        $pidSnapshot = $pidSnapshotResult.ById[[int]$PID]
        if ($null -eq $pidSnapshot -or [string](Get-DispatchJsonProperty -Object $pidSnapshot -Name 'IdentityStatus') -cne 'confirmed') {
            throw 'P0-D PID fixture 無法取得目前 PowerShell process 的已確認身分。'
        }

        $liveWriteSource = Join-Path $fixture 'p0d-live-write'
        $null = [System.IO.Directory]::CreateDirectory($liveWriteSource)
        $liveWritePath = Write-TestPidRecord -SourceRoot $liveWriteSource -LineSlug 'p0d-live-write' -DispatchSlug 'p0d-legacy-write' -WriteMode write -ProcessId ([int]$PID) -ProcessSnapshot $pidSnapshot
        $liveWriteCaller = [pscustomobject]@{ Fingerprint = Get-TestHash 'p0d-live-write-caller'; Source = 'test' }
        $liveWriteCheck = Get-TestPidCheckResult -SourceRoot $liveWriteSource -LineSlug 'p0d-live-write' -WriteMode readonly -CallerIdentity $liveWriteCaller
        $liveRecords = @(Get-TestRecordArray -Value (Get-DispatchJsonProperty -Object $liveWriteCheck -Name 'ActiveRecords'))
        $liveWriteCode = ''
        $liveWriteMessage = ''
        try {
            $null = Invoke-TestPidAdmission -SourceRoot $liveWriteSource -CallerIdentity $liveWriteCaller -LineSlug 'p0d-live-write' -DispatchSlug 'p0d-new-readonly' -WriteMode readonly -PidCheckResult $liveWriteCheck
        }
        catch {
            $liveWriteCode = Get-TestErrorCode -Exception $_.Exception
            $liveWriteMessage = $_.Exception.Message
        }
        if ($liveRecords.Count -ne 1 -or [bool](Get-DispatchJsonProperty -Object $liveWriteCheck -Name 'Blocked') -or
            $liveWriteCode -ne 'DispatchAdmissionPidConflict' -or
            $liveWriteMessage.IndexOf($liveWritePath, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
            $liveWriteMessage -notmatch 'dispatch_slug=p0d-legacy-write') {
            throw ('P0-D 同線未登記 live write PID 未依舊佔用規則拒絕新 caller。' + $liveWriteMessage)
        }
        $cases.Add([pscustomobject]@{
            scenario = 'p0d-unregistered-same-line-live-write'
            caller_id_present = $true
            pid_record_path = $liveWritePath
            pid_record_count = $liveRecords.Count
            error_code = $liveWriteCode
            conflict_message = $liveWriteMessage
            final_state = 'unregistered live write PID retains legacy same-line occupancy'
        })

        $legacyReadonlySource = Join-Path $fixture 'p0d-one-readonly'
        $null = [System.IO.Directory]::CreateDirectory($legacyReadonlySource)
        $legacyReadonlyPath = Write-TestPidRecord -SourceRoot $legacyReadonlySource -LineSlug 'p0d-one-readonly' -DispatchSlug 'p0d-legacy-readonly' -WriteMode readonly -ProcessId ([int]$PID) -ProcessSnapshot $pidSnapshot
        $legacyReadonlyCaller = [pscustomobject]@{ Fingerprint = Get-TestHash 'p0d-one-readonly-caller'; Source = 'test' }
        $legacyReadonlyCheck = Get-TestPidCheckResult -SourceRoot $legacyReadonlySource -LineSlug 'p0d-one-readonly' -WriteMode readonly -CallerIdentity $legacyReadonlyCaller
        $legacyReadonlyAdmission = Invoke-TestPidAdmission -SourceRoot $legacyReadonlySource -CallerIdentity $legacyReadonlyCaller -LineSlug 'p0d-one-readonly' -DispatchSlug 'p0d-new-readonly' -WriteMode readonly -PidCheckResult $legacyReadonlyCheck
        if ([string]$legacyReadonlyAdmission.admission_status -cne 'admitted') { throw 'P0-D 單筆舊 readonly PID 未遵守兩筆 readonly 上限。' }
        $cases.Add([pscustomobject]@{
            scenario = 'p0d-unregistered-same-line-one-readonly'
            caller_id_present = $true
            pid_record_path = $legacyReadonlyPath
            admitted_status = [string]$legacyReadonlyAdmission.admission_status
            final_state = 'one legacy readonly PID permits a second readonly admission'
        })

        $legacyReadonlyLimitSource = Join-Path $fixture 'p0d-two-readonly'
        $null = [System.IO.Directory]::CreateDirectory($legacyReadonlyLimitSource)
        $legacyReadonlyLimitPath1 = Write-TestPidRecord -SourceRoot $legacyReadonlyLimitSource -LineSlug 'p0d-two-readonly' -DispatchSlug 'p0d-legacy-readonly-one' -WriteMode readonly -ProcessId ([int]$PID) -ProcessSnapshot $pidSnapshot
        $legacyReadonlyLimitPath2 = Write-TestPidRecord -SourceRoot $legacyReadonlyLimitSource -LineSlug 'p0d-two-readonly' -DispatchSlug 'p0d-legacy-readonly-two' -WriteMode readonly -ProcessId ([int]$PID) -ProcessSnapshot $pidSnapshot
        $legacyReadonlyLimitCaller = [pscustomobject]@{ Fingerprint = Get-TestHash 'p0d-two-readonly-caller'; Source = 'test' }
        $legacyReadonlyLimitCheck = Get-TestPidCheckResult -SourceRoot $legacyReadonlyLimitSource -LineSlug 'p0d-two-readonly' -WriteMode readonly -CallerIdentity $legacyReadonlyLimitCaller
        $legacyReadonlyLimitCode = ''
        $legacyReadonlyLimitMessage = ''
        try {
            $null = Invoke-TestPidAdmission -SourceRoot $legacyReadonlyLimitSource -CallerIdentity $legacyReadonlyLimitCaller -LineSlug 'p0d-two-readonly' -DispatchSlug 'p0d-new-readonly' -WriteMode readonly -PidCheckResult $legacyReadonlyLimitCheck
        }
        catch {
            $legacyReadonlyLimitCode = Get-TestErrorCode -Exception $_.Exception
            $legacyReadonlyLimitMessage = $_.Exception.Message
        }
        $legacyReadonlyLimitActiveRecords = @(Get-TestRecordArray -Value (Get-DispatchJsonProperty -Object $legacyReadonlyLimitCheck -Name 'ActiveRecords'))
        $legacyReadonlyLimitUnconfirmedRecords = @(Get-TestRecordArray -Value (Get-DispatchJsonProperty -Object $legacyReadonlyLimitCheck -Name 'UnconfirmedRecords'))
        if ($legacyReadonlyLimitActiveRecords.Count -ne 2 -or $legacyReadonlyLimitCode -ne 'DispatchAdmissionPidConflict') {
            $recordSummary = New-Object 'System.Collections.Generic.List[object]'
            foreach ($record in @($legacyReadonlyLimitActiveRecords) + @($legacyReadonlyLimitUnconfirmedRecords)) {
                $recordSummary.Add([pscustomobject]@{
                        path = [string](Get-DispatchJsonProperty -Object $record -Name 'Path')
                        dispatch_slug = [string](Get-DispatchJsonProperty -Object $record -Name 'DispatchSlug')
                        write_mode = [string](Get-DispatchJsonProperty -Object $record -Name 'WriteMode')
                        identity_status = [string](Get-DispatchJsonProperty -Object $record -Name 'IdentityStatus')
                    })
            }
            throw ('P0-D 兩筆同線未登記 readonly PID 未套用既有上限。active_count=' + $legacyReadonlyLimitActiveRecords.Count + '; unconfirmed_count=' + $legacyReadonlyLimitUnconfirmedRecords.Count + '; error_code=' + $legacyReadonlyLimitCode + '; error=' + $legacyReadonlyLimitMessage + '; records=' + (ConvertTo-Json -InputObject $recordSummary -Depth 5 -Compress))
        }
        $cases.Add([pscustomobject]@{
            scenario = 'p0d-unregistered-same-line-readonly-limit'
            caller_id_present = $true
            pid_record_paths = @($legacyReadonlyLimitPath1, $legacyReadonlyLimitPath2)
            error_code = $legacyReadonlyLimitCode
            final_state = 'two legacy readonly PIDs reject a third readonly admission'
        })

        $endedPidSource = Join-Path $fixture 'p0d-ended-pid'
        $null = [System.IO.Directory]::CreateDirectory($endedPidSource)
        $endedPidPath = Write-TestPidRecord -SourceRoot $endedPidSource -LineSlug 'p0d-ended-pid' -DispatchSlug 'p0d-ended-old' -WriteMode write -ProcessId 2147483647 -ProcessSnapshot $pidSnapshot
        $endedPidCaller = [pscustomobject]@{ Fingerprint = Get-TestHash 'p0d-ended-caller'; Source = 'test' }
        $endedPidCheck = Get-TestPidCheckResult -SourceRoot $endedPidSource -LineSlug 'p0d-ended-pid' -WriteMode readonly -CallerIdentity $endedPidCaller
        $endedPidRecords = @(Get-TestRecordArray -Value (Get-DispatchJsonProperty -Object $endedPidCheck -Name 'UnconfirmedRecords'))
        $endedPidStatus = if ($endedPidRecords.Count -gt 0) { [string]$endedPidRecords[0].IdentityStatus } else { '' }
        $endedPidAdmission = Invoke-TestPidAdmission -SourceRoot $endedPidSource -CallerIdentity $endedPidCaller -LineSlug 'p0d-ended-pid' -DispatchSlug 'p0d-after-ended' -WriteMode readonly -PidCheckResult $endedPidCheck
        if ($endedPidStatus -cne 'root-process-absent' -or [string]$endedPidAdmission.admission_status -cne 'admitted') {
            throw 'P0-D 已結束的舊 PID 紀錄阻擋新的 same-line admission。'
        }
        $cases.Add([pscustomobject]@{
            scenario = 'p0d-unregistered-same-line-ended-pid'
            caller_id_present = $true
            pid_record_path = $endedPidPath
            identity_status = $endedPidStatus
            admitted_status = [string]$endedPidAdmission.admission_status
            final_state = 'ended PID does not consume same-line occupancy'
        })

        $unknownPidSource = Join-Path $fixture 'p0d-unknown-pid'
        $null = [System.IO.Directory]::CreateDirectory($unknownPidSource)
        $unknownPidPath = Write-TestPidRecord -SourceRoot $unknownPidSource -LineSlug 'p0d-unknown-pid' -DispatchSlug 'p0d-unknown-old' -WriteMode write -ProcessId ([int]$PID) -ProcessSnapshot $pidSnapshot -IdentityVerified $false
        $unknownPidCaller = [pscustomobject]@{ Fingerprint = Get-TestHash 'p0d-unknown-caller'; Source = 'test' }
        $unknownPidCheck = Get-TestPidCheckResult -SourceRoot $unknownPidSource -LineSlug 'p0d-unknown-pid' -WriteMode readonly -CallerIdentity $unknownPidCaller
        $unknownPidRecords = @(Get-TestRecordArray -Value (Get-DispatchJsonProperty -Object $unknownPidCheck -Name 'UnconfirmedRecords'))
        if ($unknownPidRecords.Count -ne 1) { throw 'P0-D 無法建立唯一身分不確定的舊 PID fixture。' }
        $unknownPidStatus = [string]$unknownPidRecords[0].IdentityStatus
        if ([string]::IsNullOrWhiteSpace($unknownPidStatus) -or $unknownPidStatus -in @('root-process-absent', 'record-identity-mismatch')) {
            throw 'P0-D 身分不確定 PID fixture 被錯誤分類。'
        }
        $unknownPidCode = ''
        $unknownPidMessage = ''
        try {
            $null = Invoke-TestPidAdmission -SourceRoot $unknownPidSource -CallerIdentity $unknownPidCaller -LineSlug 'p0d-unknown-pid' -DispatchSlug 'p0d-after-unknown' -WriteMode readonly -PidCheckResult $unknownPidCheck
        }
        catch {
            $unknownPidCode = Get-TestErrorCode -Exception $_.Exception
            $unknownPidMessage = $_.Exception.Message
        }
        if ($unknownPidCode -ne 'DispatchAdmissionPidConflict' -or
            $unknownPidMessage.IndexOf($unknownPidPath, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
            $unknownPidMessage -notmatch 'dispatch_slug=p0d-unknown-old' -or
            $unknownPidMessage.IndexOf(('identity_status=' + $unknownPidStatus), [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw ('P0-D 身分不確定 PID 未只以既有 PID 類別拒絕或未提供必要明細。' + $unknownPidMessage)
        }
        $differentLineCheck = Get-TestPidCheckResult -SourceRoot $unknownPidSource -LineSlug 'p0d-different-line' -WriteMode readonly -CallerIdentity $unknownPidCaller
        $differentLineActiveRecords = @(Get-TestRecordArray -Value (Get-DispatchJsonProperty -Object $differentLineCheck -Name 'ActiveRecords'))
        $differentLineUnconfirmedRecords = @(Get-TestRecordArray -Value (Get-DispatchJsonProperty -Object $differentLineCheck -Name 'UnconfirmedRecords'))
        if ($differentLineActiveRecords.Count -ne 0 -or $differentLineUnconfirmedRecords.Count -ne 0) {
            throw 'P0-D 同一來源的另一條線仍收到舊 PID 紀錄。'
        }
        $differentLineAdmission = Invoke-TestPidAdmission -SourceRoot $unknownPidSource -CallerIdentity $unknownPidCaller -LineSlug 'p0d-different-line' -DispatchSlug 'p0d-different-line-new' -WriteMode readonly -PidCheckResult $differentLineCheck
        if ([string]$differentLineAdmission.admission_status -cne 'admitted') { throw 'P0-D 同一來源的另一條線被舊 PID 阻擋。' }
        $cases.Add([pscustomobject]@{
            scenario = 'p0d-unknown-pid-blocks-only-its-line'
            caller_id_present = $true
            blocked_line = 'p0d-unknown-pid'
            pid_record_path = $unknownPidPath
            dispatch_slug = 'p0d-unknown-old'
            identity_status = $unknownPidStatus
            error_code = $unknownPidCode
            different_line_status = [string]$differentLineAdmission.admission_status
            final_state = 'unconfirmed legacy PID blocks only its own line and reports path, slug, and identity status'
        })

        $registeredPidSource = Join-Path $fixture 'p0d-registered-owner'
        $null = [System.IO.Directory]::CreateDirectory($registeredPidSource)
        $registeredLineSlug = 'p0d-registered-owner'
        $registeredDispatchSlug = 'p0d-registered-write'
        $registeredOwner = [pscustomobject]@{ Fingerprint = Get-TestHash 'p0d-registered-owner'; Source = 'test' }
        $registeredPidPath = Write-TestPidRecord -SourceRoot $registeredPidSource -LineSlug $registeredLineSlug -DispatchSlug $registeredDispatchSlug -WriteMode write -ProcessId ([int]$PID) -ProcessSnapshot $pidSnapshot
        Add-TestOwner -SourceRoot $registeredPidSource -LineSlug $registeredLineSlug -DispatchSlug $registeredDispatchSlug -Identity $registeredOwner -WriteMode write -PidRecordPath $registeredPidPath
        $registeredPidCheck = Get-TestPidCheckResult -SourceRoot $registeredPidSource -LineSlug $registeredLineSlug -WriteMode readonly -CallerIdentity $registeredOwner
        $differentOwner = [pscustomobject]@{ Fingerprint = Get-TestHash 'p0d-different-owner'; Source = 'test' }
        $differentOwnerAdmission = Invoke-TestPidAdmission -SourceRoot $registeredPidSource -CallerIdentity $differentOwner -LineSlug $registeredLineSlug -DispatchSlug 'p0d-registered-readonly' -WriteMode readonly -PidCheckResult $registeredPidCheck
        $registeredOwnerLimitCode = ''
        try {
            $null = Invoke-TestPidAdmission -SourceRoot $registeredPidSource -CallerIdentity $registeredOwner -LineSlug $registeredLineSlug -DispatchSlug 'p0d-registered-second-write' -WriteMode write -PidCheckResult $registeredPidCheck
        }
        catch {
            $registeredOwnerLimitCode = Get-TestErrorCode -Exception $_.Exception
        }
        if ([string]$differentOwnerAdmission.admission_status -cne 'admitted' -or $registeredOwnerLimitCode -ne 'DispatchAdmissionWriteLimit') {
            throw 'P0-D active ledger owner 未保留 caller admission 限額判定。'
        }
        $cases.Add([pscustomobject]@{
            scenario = 'p0d-registered-active-ledger-owner'
            caller_id_present = $true
            registered_pid_record_path = $registeredPidPath
            other_owner_status = [string]$differentOwnerAdmission.admission_status
            same_owner_limit_error_code = $registeredOwnerLimitCode
            final_state = 'registered active PID follows caller owner limits and does not consume legacy occupancy'
        })

        $finishedLedgerSource = Join-Path $fixture 'p0d-finished-ledger-no-pid'
        $null = [System.IO.Directory]::CreateDirectory($finishedLedgerSource)
        $finishedOwner = [pscustomobject]@{ Fingerprint = Get-TestHash 'p0d-finished-owner'; Source = 'test' }
        Add-TestOwner -SourceRoot $finishedLedgerSource -LineSlug 'p0d-finished-ledger' -DispatchSlug 'p0d-finished-old' -Identity $finishedOwner
        $finishedLock = Open-DispatchAdmissionLock -SourceRoot $finishedLedgerSource
        try {
            $finishedLedger = Read-DispatchAdmissionLedger -Lock $finishedLock
            foreach ($entry in @($finishedLedger.Document.entries)) { $entry.state = 'finished' }
            $null = Write-DispatchAdmissionLedger -Lock $finishedLock -Ledger $finishedLedger
        }
        finally {
            Close-DispatchAdmissionLock -Lock $finishedLock
        }
        $finishedCaller = [pscustomobject]@{ Fingerprint = Get-TestHash 'p0d-finished-new-owner'; Source = 'test' }
        $finishedCheck = Get-TestPidCheckResult -SourceRoot $finishedLedgerSource -LineSlug 'p0d-finished-ledger' -WriteMode readonly -CallerIdentity $finishedCaller
        $finishedActiveRecords = @(Get-TestRecordArray -Value (Get-DispatchJsonProperty -Object $finishedCheck -Name 'ActiveRecords'))
        $finishedUnconfirmedRecords = @(Get-TestRecordArray -Value (Get-DispatchJsonProperty -Object $finishedCheck -Name 'UnconfirmedRecords'))
        if ($finishedActiveRecords.Count -ne 0 -or $finishedUnconfirmedRecords.Count -ne 0) {
            throw 'P0-D finished ledger no-PID scenario unexpectedly has history PID records.'
        }
        $finishedAdmission = Invoke-TestPidAdmission -SourceRoot $finishedLedgerSource -CallerIdentity $finishedCaller -LineSlug 'p0d-finished-ledger' -DispatchSlug 'p0d-finished-new' -WriteMode readonly -PidCheckResult $finishedCheck
        if ([string]$finishedAdmission.admission_status -cne 'admitted') { throw 'P0-D 只有 finished ledger 且沒有 PID history 時拒絕 admission。' }
        $cases.Add([pscustomobject]@{
            scenario = 'p0d-finished-ledger-with-empty-history'
            caller_id_present = $true
            finished_ledger_state = 'finished'
            active_pid_record_count = 0
            unconfirmed_pid_record_count = 0
            admitted_status = [string]$finishedAdmission.admission_status
            final_state = 'new caller admission succeeds when history is empty and ledger contains only a finished entry'
        })

        $sourceRoot = Join-Path $fixture 'source-integration'
        $worktreeOne = Join-Path $fixture 'worktree-one'
        $worktreeTwo = Join-Path $fixture 'worktree-two'
        foreach ($directory in @($sourceRoot, $worktreeOne, $worktreeTwo)) { $null = [IO.Directory]::CreateDirectory($directory) }
        $sourceFile = Join-Path $sourceRoot 'payload.txt'
        [IO.File]::WriteAllText($sourceFile, 'baseline')
        [IO.File]::WriteAllText((Join-Path $worktreeOne 'payload.txt'), 'from-one')
        [IO.File]::WriteAllText((Join-Path $worktreeTwo 'payload.txt'), 'from-two')
        $baselinePath = Join-Path $fixture 'integration-baseline.json'
        Write-TestJson $baselinePath ([ordered]@{ files = @([ordered]@{ path = 'payload.txt'; exists = $true; sha256 = Get-DispatchAdmissionFileSha256 $sourceFile }) })
        foreach ($seed in @(
                [pscustomobject]@{ slug = 't049-source-one'; tag = 'source-one' },
                [pscustomobject]@{ slug = 't049-source-two'; tag = 'source-two' }
            )) {
            $seedIdentity = [pscustomobject]@{ Fingerprint = Get-TestHash ('test-caller:' + [string]$seed.tag); Source = 'test' }
            $seedArgs = @{ SourceRoot = $sourceRoot; CallerIdentity = $seedIdentity; LineSlug = 't049-concurrency'; DispatchSlug = $seed.slug; WriteMode = 'write'; PidCheckAction = { return [pscustomobject]@{ Blocked = $false } }; StartAction = { return Get-TestProcessIdentity } }
            $null = Invoke-DispatchAdmissionStart @seedArgs
        }
        $sourceConfigs = @(
            (New-WorkerConfig $fixture 'source-one' $sourceRoot $worktreeOne 't049-source-one' 'source-one' write source @() '' $baselinePath),
            (New-WorkerConfig $fixture 'source-two' $sourceRoot $worktreeTwo 't049-source-two' 'source-two' write source @() '' $baselinePath)
        )
        $sourceBatch = Invoke-WorkerBatch 'source-lock-fingerprint' $fixture $sourceConfigs
        $sourcePass = @($sourceBatch.participants | Where-Object { $_.status -eq 'applied' }).Count
        $sourceDrift = @($sourceBatch.participants | Where-Object { $_.error_code -eq 'DispatchSourceDrift' }).Count
        if ($sourcePass -ne 1 -or $sourceDrift -ne 1 -or -not (Test-Path -LiteralPath $worktreeOne) -or -not (Test-Path -LiteralPath $worktreeTwo)) { throw '來源整合鎖／漂移競態結果錯誤。' }
        $cases.Add([pscustomobject]@{ scenario = 'source-lock-and-fingerprint-drift'; participants = @($sourceBatch.participants); synchronization_point = $sourceBatch.synchronization_point; source_file = $sourceFile; value_after = [IO.File]::ReadAllText($sourceFile); worktrees_preserved = $true; final_state = 'one applied; stale fingerprint rejected; both worktrees retained' })

        $quotaRoot = Join-Path $fixture 'quota-race'
        $quotaSource = Join-Path $quotaRoot 'source'
        $null = [IO.Directory]::CreateDirectory($quotaSource)
        $quotaPath = Join-Path $quotaSource 'after-snapshot.json'
        [IO.File]::WriteAllText($quotaPath, 'initial')
        $expected = Get-DispatchAdmissionFileSha256 $quotaPath
        $quotaConfigs = @(
            (New-WorkerConfig $quotaRoot 'quota-one' $quotaSource $quotaSource 't049-quota-one' 'quota-one' readonly quota @() '' '' $quotaPath $expected 'replacement-one'),
            (New-WorkerConfig $quotaRoot 'quota-two' $quotaSource $quotaSource 't049-quota-two' 'quota-two' readonly quota @() '' '' $quotaPath $expected 'replacement-two')
        )
        $quotaBatch = Invoke-WorkerBatch 'quota-file-replace-race' $quotaRoot $quotaConfigs
        $quotaPass = @($quotaBatch.participants | Where-Object { $_.status -eq 'replaced' }).Count
        $quotaDrift = @($quotaBatch.participants | Where-Object { $_.error_code -eq 'QuotaAfterSnapshotChanged' }).Count
        if ($quotaPass -ne 1 -or $quotaDrift -ne 1) { throw 'quota replacement 共用鎖競態結果錯誤。' }
        $cases.Add([pscustomobject]@{ scenario = 'quota-file-replace-lock'; participants = @($quotaBatch.participants); synchronization_point = $quotaBatch.synchronization_point; quota_path = $quotaPath; final_sha256 = Get-DispatchAdmissionFileSha256 $quotaPath; final_state = 'one File.Replace succeeded; stale fingerprint rejected' })

        $cleanup = Test-CleanupOwner $fixture
        $cases.Add($cleanup)
        $summary = [ordered]@{ schema = 'ai-sessions.dispatch-concurrency-test.v1'; result = 'PASS'; host = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName; powershell_version = $PSVersionTable.PSVersion.ToString(); fixture_root = $fixture; evidence_root = $evidence; raw_caller_session_ids_written = $false; test_count = $cases.Count; cases = @($cases.ToArray()) }
        $summaryPath = Join-Path $evidence 't049-concurrency-summary.json'
        Write-TestJson $summaryPath $summary
        [IO.File]::WriteAllText((Join-Path $evidence 't049-concurrency-summary.stdout.txt'), (ConvertTo-Json -InputObject $summary -Depth 50), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $evidence 't049-concurrency-summary.stderr.txt'), '')
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject ([ordered]@{ result = 'PASS'; test_count = $cases.Count; summary_path = $summaryPath; powershell_version = $PSVersionTable.PSVersion.ToString() }) -Depth 10 -Compress))
        $completed = $true
        return 0
    }
    finally {
        [Environment]::SetEnvironmentVariable('CLAUDE_CODE_SESSION_ID', $oldClaude)
        [Environment]::SetEnvironmentVariable('CODEX_THREAD_ID', $oldCodex)
        if (-not $completed -and (Test-Path -LiteralPath $fixture -PathType Container)) {
            $failureEvidence = Join-Path $evidence 'failed-fixture'
            $null = [IO.Directory]::CreateDirectory($failureEvidence)
            foreach ($file in @(Get-ChildItem -LiteralPath $fixture -File -Recurse -Force | Where-Object { $_.Name -match '(?i)(stdout|stderr|result-|worker-|^go$|^release$)' })) {
                $relative = $file.FullName.Substring($fixture.Length).TrimStart([char[]]@('\', '/'))
                $destination = Join-Path $failureEvidence $relative
                $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
                [IO.File]::Copy($file.FullName, $destination, $true)
            }
        }
        if ($completed -and $fixture.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fixture -PathType Container)) {
            Remove-Item -LiteralPath $fixture -Recurse -Force
        }
    }
}

$code = Invoke-TestMain -FixtureBaseRootPath $FixtureBaseRootPath -EvidencePath $EvidencePath
exit $code
