#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('U1', 'U2', 'U3')][string]$Unit = 'U1',
    [string]$FixtureBaseRootPath = 'C:\tmp',
    [string]$FixtureRootPath,
    [ValidateRange(1, 2)][int]$Repeat = 2,
    [ValidateSet('', 'hash-first', 'hash-second')][string]$Worker = '',
    [string]$WorkerRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$script:SourceRoot = ''
$script:ExecutionRoot = ''
$script:TargetPath = @()
$script:CallerSessionIdentity = $null
foreach ($moduleName in @(
        'common-runtime.ps1', 'git-baseline.ps1', 'dispatch-scope.ps1', 'dispatch-evidence.ps1',
        'quota-observation.ps1', 'advisor-evidence.ps1', 'process-identity.ps1', 'reviewer-contract.ps1',
        'run-recovery.ps1', 'prepare-stage.ps1', 'dispatch-lifecycle.ps1', 'start-lifecycle.ps1',
        'inspect-lifecycle.ps1', 'collect-contract.ps1', 'cleanup.ps1', 'Invoke-DispatchConcurrency.ps1')) {
    . (Join-Path (Join-Path $scriptsRoot 'dispatch') $moduleName)
}

function Assert-P1A {
    [CmdletBinding()]
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Wait-P1AMarker {
    [CmdletBinding()]
    param([string]$Path)
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    while (-not [IO.File]::Exists($Path)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw ('IPC timeout: ' + $Path) }
        Start-Sleep -Milliseconds 25
    }
}

function Write-P1AText {
    [CmdletBinding()]
    param([string]$Path, [string]$Text)
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

if ($Worker) {
    $rootRunId = '11111111-1111-4111-8111-111111111111'
    $runId = if ($Worker -eq 'hash-first') { $rootRunId } else { '22222222-2222-4222-8222-222222222222' }
    $planPath = Join-Path $WorkerRoot 'plan.json'
    if ($Worker -eq 'hash-second') { Wait-P1AMarker -Path (Join-Path $WorkerRoot 'first-claimed') }
    $claim = New-DispatchStartHashClaim -SourceRoot $WorkerRoot -ExecutionRoot $WorkerRoot -SourceHistoryRoot (Join-Path $WorkerRoot '.local\ai-sessions\history') -LineSlug 'p1a' -DispatchSlug 'race' -ScopePlanPath $planPath -RunId $runId -RootRunId $rootRunId -TargetPath @()
    Write-P1AText -Path (Join-Path $WorkerRoot ($Worker + '.json')) -Text ($claim | ConvertTo-Json)
    if ($Worker -eq 'hash-first') {
        Write-P1AText -Path (Join-Path $WorkerRoot 'first-claimed') -Text 'claimed'
        Wait-P1AMarker -Path (Join-Path $WorkerRoot 'second-failed')
        Assert-P1A ($claim.Created -and (Get-FileSha256 $claim.Path) -ceq $claim.Sha256) 'First Start hash was removed or changed.'
    }
    else {
        Assert-P1A (-not $claim.Created) 'Failed second Start claimed first Start hash.'
        $wrongRootRejected = $false
        try {
            $null = New-DispatchStartHashClaim -SourceRoot $WorkerRoot -ExecutionRoot $WorkerRoot -SourceHistoryRoot (Join-Path $WorkerRoot '.local\ai-sessions\history') -LineSlug 'p1a' -DispatchSlug 'race' -ScopePlanPath $planPath -RunId $runId -RootRunId $runId -TargetPath @()
        }
        catch { $wrongRootRejected = $_.Exception.Message -match 'root run' }
        Assert-P1A $wrongRootRejected 'Second Start with different root run was accepted.'
        Write-P1AText -Path (Join-Path $WorkerRoot 'second-failed') -Text 'rejected; no claim to remove'
    }
    exit 0
}

$baseRoot = [IO.Path]::GetFullPath($FixtureBaseRootPath)
$fixtureRoot = if ($FixtureRootPath) { [IO.Path]::GetFullPath($FixtureRootPath) } else { Join-Path $baseRoot ('p1a-' + [guid]::NewGuid().ToString('N')) }
Assert-P1A (Test-PathWithinRoot -Path $fixtureRoot -Root $baseRoot) 'Fixture path outside base root.'
Assert-DispatchOutputPathNoReparsePoint -Root $baseRoot -Path $fixtureRoot
$null = [IO.Directory]::CreateDirectory($fixtureRoot)
$script:p1aResults = New-Object 'System.Collections.Generic.List[object]'

function New-P1ACleanupFixture {
    [CmdletBinding()]
    param([string]$Root, [string]$Slug = 'cleanup')

    $source = Join-Path $Root 'source'
    Write-P1AText (Join-Path $source 'README.md') 'fixture'
    Write-P1AText (Join-Path $source '.gitignore') ".local/`r`n"
    $null = Invoke-GitCommand -WorkingDirectory $source -Arguments @('init')
    $null = Invoke-GitCommand -WorkingDirectory $source -Arguments @('add','README.md','.gitignore')
    $null = Invoke-GitCommand -WorkingDirectory $source -Arguments @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-m','fixture')
    $dispatch = Join-Path $source ('.local\ai-sessions\worktrees\' + $Slug)
    $null = Invoke-GitCommand -WorkingDirectory $source -Arguments @('worktree','add','--detach',$dispatch,'HEAD')
    $preflight = Join-Path $source ('.local\ai-sessions\history\p1a\preflight-' + $Slug + '.json')
    Write-P1AText $preflight (([ordered]@{ sourceRoot = $source; dispatchRoot = $dispatch; executionRoot = $dispatch; lineSlug = 'p1a'; dispatchSlug = $Slug; worktreeCreated = $true } | ConvertTo-Json) + "`r`n")
    Write-P1AText (Join-Path $source '.local\ai-sessions\handoff\p1a\line.json') '{"schema":"ai-sessions.line.v1","line-slug":"p1a"}'
    $script:SourceRoot = $source
    $script:DispatchRoot = $dispatch
    $script:ExecutionRoot = $dispatch
    $script:LineSlug = 'p1a'
    $script:DispatchSlug = $Slug
    $script:PreflightResultPath = $preflight
    $script:RunRecordPath = ''
    $script:EvidencePath = @()
    $script:FailureReceiptPath = ''
    $script:TargetPath = @()
    $script:CallerSessionIdentity = Get-DispatchCallerSessionIdentity -CliCallerSessionId 'p1a-fixture' -CliCallerSessionIdProvided $true
    return [pscustomobject]@{ Source = $source; Dispatch = $dispatch; Preflight = $preflight; Slug = $Slug }
}

function New-P1AUnstartedReceipt {
    [CmdletBinding()]
    param([object]$Fixture, [bool]$Started = $false)

    $path = Join-Path $Fixture.Source ('.local\ai-sessions\history\p1a\failure-' + $Fixture.Slug + '.json')
    $document = [ordered]@{ schema = 'ai-sessions.dispatch-failure-receipt.v1'; source_root = $Fixture.Source; execution_root = $Fixture.Dispatch; dispatch_root = $Fixture.Dispatch; line_slug = 'p1a'; dispatch_slug = $Fixture.Slug; process_started = $Started; status = 'failed'; failed_stage = 'start'; error_code = 'DispatchAdmissionWriteLimit' }
    Write-P1AText $path ($document | ConvertTo-Json)
    return $path
}

function New-P1AUnstartedRecord {
    [CmdletBinding()]
    param([object]$Fixture)

    $id = [guid]::NewGuid().ToString('D')
    $path = Join-Path $Fixture.Source ('.local\ai-sessions\history\p1a\runs\' + $Fixture.Slug + '\' + $id + '.json')
    $record = [ordered]@{
        schema = 'ai-sessions.dispatch-run.v1'; run_id = $id; source_root = $Fixture.Source; execution_root = $Fixture.Dispatch; line_slug = 'p1a'; dispatch_slug = $Fixture.Slug
        event_stream_path = (Join-Path $Fixture.Dispatch '.local\ai-sessions\history\events.jsonl'); last_message_path = (Join-Path $Fixture.Dispatch '.local\ai-sessions\history\last.md')
        preflight_result_path = $Fixture.Preflight; preflight_sha256 = (Get-FileSha256 $Fixture.Preflight); pid_record_path = (Join-Path $Fixture.Source '.local\ai-sessions\history\codex-pid-cleanup.txt')
        created_at_utc = [DateTime]::UtcNow.ToString('o'); launch_state = 'launch-failed'; scope_plan_path = $null; scope_plan_sha256 = $null
        caller_session_fingerprint = $script:CallerSessionIdentity.Fingerprint
        baseline_resolution = @{ status = 'failed'; query_location = $Fixture.Source; error = 'fixture failure before baseline binding' }
        failure = (New-DispatchFailureRecord -Phase 'preparation' -Message 'fixture pre-start failure' -ProcessStarted $false -Observation ([pscustomobject]@{ process_started = $false }))
    }
    Write-P1AText $path ($record | ConvertTo-Json -Depth 10)
    return $path
}

function Invoke-P1ACase {
    [CmdletBinding()]
    param([string]$Name, [scriptblock]$Action)
    $started = [DateTime]::UtcNow
    try {
        & $Action
        $row = [ordered]@{ unit = $Unit; round = $script:p1aRound; case = $Name; status = 'PASS'; started_at_utc = $started.ToString('o'); error = $null }
    }
    catch {
        $row = [ordered]@{ unit = $Unit; round = $script:p1aRound; case = $Name; status = 'FAIL'; started_at_utc = $started.ToString('o'); error = $_.Exception.ToString(); stack = $_.ScriptStackTrace }
    }
    $script:p1aResults.Add($row)
    Write-Output ($row | ConvertTo-Json -Depth 10 -Compress)
}

function Invoke-P1AAdmission {
    [CmdletBinding()]
    param([object]$Fixture, [string]$Slug, [string]$Mode, [string[]]$Targets = @(), [string[]]$Directories = @(), [string]$Caller = 'p1a-fixture')

    $identity = Get-DispatchCallerSessionIdentity -CliCallerSessionId $Caller -CliCallerSessionIdProvided $true
    $paths = Get-DispatchAdmissionWritePaths -SourceRoot $Fixture.Source -ExecutionRoot $Fixture.Source -WriteMode $Mode -TargetPath $Targets -AddDirectory $Directories
    $process = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $owner = [pscustomobject]@{ ProcessId = $PID; ProcessName = $process.ProcessName; ProcessStartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o'); RunRecordPath = ''; PidRecordPath = '' }
        return Invoke-DispatchAdmissionStart -SourceRoot $Fixture.Source -CallerIdentity $identity -LineSlug 'p1a' -DispatchSlug $Slug -WriteMode $Mode -WritePaths $paths -PidCheckAction { [pscustomobject]@{ Blocked = $false } } -StartAction { $owner }
    }
    finally { $process.Dispose() }
}

function Invoke-P1AReadonlyPreflight {
    [CmdletBinding()]
    param([object]$Fixture, [string]$Slug, [string[]]$Directories = @())

    $script:DispatchSlug = $Slug
    $script:DispatchRoot = Join-Path $Fixture.Source ('.local\ai-sessions\worktrees\' + $Slug)
    $script:ExecutionRoot = $script:DispatchRoot
    $script:TargetPath = @((Join-Path $Fixture.Source 'README.md'))
    $script:WriteMode = 'readonly'; $script:DispatchKind = 'resource'; $script:TaskType = 'script-change'
    $script:AddDirectory = $Directories; $script:PrepareResultPath = ''; $script:CodexHome = ''
    return Invoke-Preflight
}

for ($script:p1aRound = 1; $script:p1aRound -le $Repeat; $script:p1aRound++) {
    $roundRoot = Join-Path $fixtureRoot ('round-' + $script:p1aRound + '-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($roundRoot)
    if ($Unit -eq 'U1') {
        Invoke-P1ACase 'F-040 history junction rejected before RunRecord read or lock write' {
            $source = Join-Path $roundRoot 'source'
            $outside = Join-Path $roundRoot 'outside'
            $history = Join-Path $source '.local\ai-sessions\history'
            $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $history))
            $null = [IO.Directory]::CreateDirectory($outside)
            $sentinel = Join-Path $outside 'sentinel.txt'
            Write-P1AText $sentinel 'unchanged'
            $null = New-Item -ItemType Junction -Path $history -Target $outside
            $rejected = $false
            try { $null = Open-DispatchAdmissionLock -SourceRoot $source }
            catch { $rejected = $_.Exception.Message -match 'ReparsePoint' }
            Assert-P1A ($rejected -and -not [IO.File]::Exists((Join-Path $outside 'dispatch-admission.lock'))) 'Junction admission lock escaped root.'
            $rejected = $false
            try { $null = Read-DispatchRunRecord -Path (Join-Path $history 'p1a\runs\race\run.json') -SourceRoot $source -ExecutionRoot $source -LineSlug 'p1a' -DispatchSlug 'race' }
            catch { $rejected = $_.Exception.Message -match 'ReparsePoint' }
            Assert-P1A ($rejected -and [IO.File]::ReadAllText($sentinel) -ceq 'unchanged') 'Junction RunRecord was read.'
            $safe = Join-Path $roundRoot 'safe'
            $null = [IO.Directory]::CreateDirectory($safe)
            $lock = Open-DispatchAdmissionLock -SourceRoot $safe
            Close-DispatchAdmissionLock $lock
            Assert-P1A ([IO.File]::Exists((Join-Path $safe '.local\ai-sessions\history\dispatch-admission.lock'))) 'Normal lock failed.'
            $ancestorLink = Join-Path $roundRoot 'ancestor-link'
            $null = New-Item -ItemType Junction -Path $ancestorLink -Target $safe
            $nestedSource = Join-Path $safe 'nested-source'
            $null = [IO.Directory]::CreateDirectory($nestedSource)
            $rejected = $false
            try { $null = Open-DispatchAdmissionLock -SourceRoot (Join-Path $ancestorLink 'nested-source') }
            catch { $rejected = $_.Exception.Message -match 'ReparsePoint' }
            Assert-P1A ($rejected -and -not [IO.Directory]::Exists((Join-Path $nestedSource '.local'))) 'SourceRoot ancestor junction escaped guard.'
        }
        Invoke-P1ACase 'F-041 source blocks preserved; same-title worktree blocks append once' {
            $first = "## same`r`n`r`n- first`r`n"
            $second = "## same`r`n`r`n- second`r`n"
            $new = "## new`r`n`r`n- added`r`n"
            $destination = $first + "`r`n" + $second
            $worktree = $second + "`r`n" + $first + "`r`n" + $new + "`r`n" + $new
            $merged = Join-CleanupExceptionBlocks -SourceText $worktree -DestinationText $destination
            Assert-P1A ($merged.StartsWith($destination.TrimEnd()) -and $merged.Contains('- added') -and ([regex]::Matches($merged, '(?m)^## same')).Count -eq 2 -and ([regex]::Matches($merged, '(?m)^## new')).Count -eq 1) 'Existing or duplicate source blocks changed.'
            Assert-P1A ($null -eq (Join-CleanupExceptionBlocks -SourceText $merged -DestinationText $merged)) 'Repeated merge not idempotent.'
            $differentBody = Join-CleanupExceptionBlocks -SourceText "## same`n`n- third" -DestinationText $destination
            Assert-P1A ($differentBody.StartsWith($destination.TrimEnd()) -and $differentBody.Contains('- first') -and $differentBody.Contains('- second') -and $differentBody.Contains('- third') -and ([regex]::Matches($differentBody, '(?m)^## same')).Count -eq 3) 'Different body under an existing heading was not appended.'
            $rejected = $false
            try { $null = Join-CleanupExceptionBlocks -SourceText "Worktree preamble`n`n## same`n`n- third" -DestinationText ("Source preamble`n`n" + $destination) }
            catch { $rejected = $_.Exception.Message -match 'CleanupExceptionsConflict' }
            Assert-P1A $rejected 'Mismatched preamble was accepted.'
        }
        Invoke-P1ACase 'F-042 independent Start hash claims retain first owner after second failure' {
            $raceRoot = Join-Path $roundRoot 'hash-race'
            Write-P1AText (Join-Path $raceRoot 'plan.json') '{"selected_units":["Phase 2"]}'
            $processes = New-Object 'System.Collections.Generic.List[object]'
            try {
                foreach ($role in @('hash-first', 'hash-second')) {
                    $info = New-Object Diagnostics.ProcessStartInfo
                    $info.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
                    $info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Worker ' + $role + ' -WorkerRoot "' + $raceRoot + '"'
                    $info.UseShellExecute = $false
                    $info.CreateNoWindow = $true
                    $info.RedirectStandardOutput = $true
                    $info.RedirectStandardError = $true
                    $process = New-Object Diagnostics.Process
                    $process.StartInfo = $info
                    $null = $process.Start()
                    $processes.Add([pscustomobject]@{ Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Error = $process.StandardError.ReadToEndAsync() })
                }
                foreach ($entry in $processes) {
                    Assert-P1A ($entry.Process.WaitForExit(60000)) 'Hash race worker timeout.'
                    $workerOutput = $entry.Out.GetAwaiter().GetResult() + $entry.Error.GetAwaiter().GetResult()
                    Assert-P1A ($entry.Process.ExitCode -eq 0) ('Hash race failed: ' + $workerOutput)
                }
                $firstClaim = ConvertFrom-DispatchJson -Content ([IO.File]::ReadAllText((Join-Path $raceRoot 'hash-first.json')))
                $secondClaim = ConvertFrom-DispatchJson -Content ([IO.File]::ReadAllText((Join-Path $raceRoot 'hash-second.json')))
                Assert-P1A ($firstClaim.Created -and -not $secondClaim.Created -and (Get-FileSha256 $firstClaim.Path) -ceq $firstClaim.Sha256) 'Start hash ownership mismatch.'
            }
            finally {
                foreach ($entry in $processes) {
                    if (-not $entry.Process.HasExited) { $entry.Process.Kill(); $entry.Process.WaitForExit() }
                    $entry.Process.Dispose()
                }
            }
        }
        Invoke-P1ACase 'F-043 FixtureRootPath junction rejected without external writes' {
            $outside = Join-Path $roundRoot 'fixture-outside'
            $link = Join-Path $roundRoot 'fixture-link'
            $null = [IO.Directory]::CreateDirectory($outside)
            $null = New-Item -ItemType Junction -Path $link -Target $outside
            $info = New-Object Diagnostics.ProcessStartInfo
            $info.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'Test-DispatchRecoveryBinding.ps1') + '" -Child -Phase 9 -FocusedCase P0-B -FixtureBaseRootPath "' + $baseRoot + '" -FixtureRootPath "' + (Join-Path $link 'rejected') + '"'
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $process = New-Object Diagnostics.Process
            $process.StartInfo = $info
            try {
                $null = $process.Start()
                $outTask = $process.StandardOutput.ReadToEndAsync()
                $errorTask = $process.StandardError.ReadToEndAsync()
                Assert-P1A ($process.WaitForExit(60000)) 'Fixture rejection timeout.'
                $text = $outTask.GetAwaiter().GetResult() + $errorTask.GetAwaiter().GetResult()
                Assert-P1A ($process.ExitCode -ne 0 -and $text -match 'ReparsePoint' -and -not [IO.Directory]::Exists((Join-Path $outside 'rejected'))) ('Fixture junction not rejected: ' + $text)
            }
            finally {
                if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
                $process.Dispose()
            }
        }
        Invoke-P1ACase 'F-039 reused PID with completed event reports completed' {
            $progressRoot = Join-Path $roundRoot 'progress'
            $historyRoot = Join-Path $progressRoot '.local\ai-sessions\history'
            $process = Get-Process -Id $PID -ErrorAction Stop
            foreach ($kind in @('name', 'time')) {
                $slug = 'reused-' + $kind
                $expectedName = if ($kind -eq 'name') { 'different-process' } else { $process.ProcessName }
                $expectedTime = if ($kind -eq 'time') { '2000-01-01T00:00:00Z' } else { $process.StartTime.ToUniversalTime().ToString('o') }
                $record = @('line-slug=p1a', ('dispatch-slug=' + $slug), ('root-pid=' + $PID), ('root-process-name=' + $expectedName), ('root-started-at-utc=' + $expectedTime)) -join "`r`n"
                Write-P1AText (Join-Path $historyRoot ('codex-pid-' + $slug + '.txt')) $record
                Write-P1AText (Join-Path $historyRoot ('codex-exec-' + $slug + '.jsonl')) '{"type":"turn.completed"}'
            }
            $rows = @(& (Join-Path $scriptsRoot 'Get-DispatchProgress.ps1') -WorkRoot $progressRoot -LineSlug p1a -All)
            Assert-P1A ($rows.Count -eq 2) 'Progress rows missing.'
            foreach ($row in $rows) { Assert-P1A ($row.status -ceq 'completed' -and -not $row.rootPidAlive -and $row.rootPidIdentityStatus -match '^pid-reused-') 'Reused PID reported running after completed event.' }
        }
    }
    elseif ($Unit -eq 'U2') {
        Invoke-P1ACase 'Q10 latest fixed reports archive old versions; other reports reject drift' {
            $f = New-P1ACleanupFixture (Join-Path $roundRoot 'archive')
            foreach ($name in @('review-report.md','frontend-reviewer-report.md','contract-auditor-report.md')) {
                $relative = '.local/ai-sessions/report/p1a/' + $name
                $origin = Join-Path $f.Source $relative
                $work = Join-Path $f.Dispatch $relative
                $oldReport = "## Finding manifest`r`n`r`n``````json`r`n" + (([ordered]@{ schema = 'codex-dispatch.review-findings.v2'; line_slug = 'p1a'; dispatch_slug = 'previous'; round = 1 }) | ConvertTo-Json) + "`r`n```````r`n"
                $newReport = "## Finding manifest`r`n`r`n``````json`r`n" + (([ordered]@{ schema = 'codex-dispatch.review-findings.v2'; line_slug = 'p1a'; dispatch_slug = $f.Slug; round = 2 }) | ConvertTo-Json) + "`r`n```````r`n"
                Write-P1AText $origin $oldReport
                Write-P1AText $work $newReport
                $item = [pscustomobject]@{ source_path = $work; relative_path = $relative }
                $saved = Preserve-CleanupFile -Item $item -SourceRoot $f.Source -DispatchRoot $f.Dispatch -DispatchSlug $f.Slug
                Assert-P1A ([IO.File]::ReadAllText($origin) -ceq $newReport -and [IO.File]::ReadAllText($saved.archive_path) -ceq $oldReport -and $saved.version_decision.basis -eq 'report-manifest-round') 'Fixed report archive did not preserve both versions.'
                $repeat = Preserve-CleanupFile -Item $item -SourceRoot $f.Source -DispatchRoot $f.Dispatch -DispatchSlug $f.Slug
                Assert-P1A ($null -eq $repeat.archive_path) 'Identical fixed report created another archive.'
            }
            $relative = '.local/ai-sessions/report/p1a/other.md'
            Write-P1AText (Join-Path $f.Source $relative) 'old'
            Write-P1AText (Join-Path $f.Dispatch $relative) 'new'
            $rejected = $false
            try { $null = Preserve-CleanupFile -Item ([pscustomobject]@{ source_path = (Join-Path $f.Dispatch $relative); relative_path = $relative }) -SourceRoot $f.Source -DispatchRoot $f.Dispatch }
            catch { $rejected = $_.Exception.Message -match 'CleanupDestinationConflict' }
            Assert-P1A ($rejected -and [IO.File]::ReadAllText((Join-Path $f.Source $relative)) -ceq 'old') 'Other report drift accepted.'
            [IO.File]::Delete((Join-Path $f.Dispatch $relative))
            $latestReport = $newReport -replace '"round":  2|"round": 2', '"round": 3'
            Write-P1AText (Join-Path $f.Dispatch '.local/ai-sessions/report/p1a/review-report.md') $latestReport
            $result = Invoke-Cleanup -Confirm:$false
            $archives = @($result.files | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.archive_path) })
            Assert-P1A ($result.worktree_removed -and $archives.Count -eq 1 -and [IO.File]::ReadAllText($archives[0].archive_path) -ceq $newReport) 'Cleanup result omitted archive path.'
        }
        Invoke-P1ACase 'Q8 Q13 registered unstarted no-RunRecord worktree cleans without Preflight; started or unproved rejects' {
            $f = New-P1ACleanupFixture (Join-Path $roundRoot 'no-preflight')
            $script:FailureReceiptPath = New-P1AUnstartedReceipt $f
            $script:PreflightResultPath = ''
            Write-P1AText (Join-Path $f.Dispatch '.local\ai-sessions\report\p1a\partial.md') 'confirmed partial result'
            $result = Invoke-Cleanup -Confirm:$false
            Assert-P1A ($result.worktree_removed -and $result.status -ceq 'completed' -and [IO.File]::ReadAllText((Join-Path $f.Source '.local\ai-sessions\report\p1a\partial.md')) -ceq 'confirmed partial result') 'Unstarted orphan did not clean and preserve reports.'
            foreach ($proof in @('started','missing')) {
                $f = New-P1ACleanupFixture (Join-Path $roundRoot ('reject-' + $proof))
                $script:PreflightResultPath = ''
                if ($proof -eq 'started') { $script:FailureReceiptPath = New-P1AUnstartedReceipt $f $true }
                $rejected = $false
                try { $null = Invoke-Cleanup -Confirm:$false }
                catch { $rejected = $_.Exception.Data['errorCode'] -ceq 'CleanupPreflightResultRequired' }
                Assert-P1A ($rejected -and [IO.File]::Exists((Join-Path $f.Dispatch 'README.md'))) ('Unsafe orphan cleanup accepted: ' + $proof)
            }
            foreach ($artifact in @('codex-exec-fixture.jsonl', 'codex-thread-cleanup.txt')) {
                $f = New-P1ACleanupFixture (Join-Path $roundRoot ('history-artifact-' + [IO.Path]::GetFileNameWithoutExtension($artifact)))
                $script:RunRecordPath = New-P1AUnstartedRecord $f
                $script:FailureReceiptPath = New-P1AUnstartedReceipt $f
                [IO.File]::Delete($f.Preflight)
                $script:PreflightResultPath = ''
                Write-P1AText (Join-Path $f.Dispatch ('.local\ai-sessions\history\' + $artifact)) 'unstarted proof contradicting history artifact'
                $rejected = $false
                try { $null = Invoke-Cleanup -Confirm:$false }
                catch { $rejected = $_.Exception.Data['errorCode'] -ceq 'CleanupPreflightResultRequired' }
                Assert-P1A ($rejected -and [IO.File]::Exists((Join-Path $f.Dispatch 'README.md'))) ('History artifact allowed unstarted cleanup: ' + $artifact)
            }
            $f = New-P1ACleanupFixture (Join-Path $roundRoot 'receipt-history-artifact')
            $script:FailureReceiptPath = New-P1AUnstartedReceipt $f
            [IO.File]::Delete($f.Preflight)
            $script:PreflightResultPath = ''
            Write-P1AText (Join-Path $f.Dispatch '.local\ai-sessions\history\codex-exec-fixture.jsonl') 'unstarted proof contradicting event stream'
            $rejected = $false
            try { $null = Invoke-Cleanup -Confirm:$false }
            catch { $rejected = $_.Exception.Data['errorCode'] -ceq 'CleanupPreflightResultRequired' }
            Assert-P1A ($rejected -and [IO.File]::Exists((Join-Path $f.Dispatch 'README.md'))) 'Receipt-only proof allowed event stream cleanup.'
            $f = New-P1ACleanupFixture (Join-Path $roundRoot 'preflight-only')
            Assert-P1A ((Invoke-Cleanup -Confirm:$false).worktree_removed) 'Preflight-only unstarted worktree rejected.'
        }
        Invoke-P1ACase 'Q14 post-C17 never-started RunRecord recovers; started and owner mismatch reject' {
            $f = New-P1ACleanupFixture (Join-Path $roundRoot 'new-unstarted')
            $script:RunRecordPath = New-P1AUnstartedRecord $f
            [IO.File]::Delete($f.Preflight)
            $script:PreflightResultPath = ''
            $result = Invoke-Cleanup -Confirm:$false
            Assert-P1A $result.worktree_removed 'Post-C17 never-started record rejected.'
            $f = New-P1ACleanupFixture (Join-Path $roundRoot 'new-started')
            $path = New-P1AUnstartedRecord $f
            $record = ConvertFrom-DispatchJson -Content ([IO.File]::ReadAllText($path))
            $record.failure.observation.process_started = $true
            Write-P1AText $path ($record | ConvertTo-Json -Depth 10)
            $script:RunRecordPath = $path
            $rejected = $false
            try { $null = Invoke-Cleanup -Confirm:$false }
            catch { $rejected = $_.Exception.Message -match 'DispatchAdmissionOwnerUnverifiable' }
            Assert-P1A ($rejected -and [IO.File]::Exists((Join-Path $f.Dispatch 'README.md'))) 'Started new record took legacy fallback.'
            $f = New-P1ACleanupFixture (Join-Path $roundRoot 'owner-mismatch')
            $script:FailureReceiptPath = New-P1AUnstartedReceipt $f
            $lock = Open-DispatchAdmissionLock -SourceRoot $f.Source
            try {
                $ledger = Read-DispatchAdmissionLedger -Lock $lock
                $ledger.Document.entries = @([pscustomobject]@{ line_slug = 'p1a'; dispatch_slug = $f.Slug; state = 'finished'; caller_session_fingerprint = ('a' * 64) })
                $null = Write-DispatchAdmissionLedger -Lock $lock -Ledger $ledger
            }
            finally { Close-DispatchAdmissionLock $lock }
            $rejected = $false
            try { $null = Invoke-Cleanup -Confirm:$false }
            catch { $rejected = $_.Exception.Message -match 'DispatchAdmissionOwnerMismatch' }
            Assert-P1A ($rejected -and [IO.File]::Exists((Join-Path $f.Dispatch 'README.md'))) 'Unstarted proof bypassed a registered different owner.'
        }
        Invoke-P1ACase 'Q15 locked file preserves registration and actual error; unlock permits retry' {
            $f = New-P1ACleanupFixture (Join-Path $roundRoot 'locked')
            $lockedPath = Join-Path $f.Dispatch 'locked.txt'
            Write-P1AText $lockedPath 'locked'
            $handle = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try { $result = Invoke-Cleanup -Confirm:$false }
            finally { $handle.Dispose() }
            $registration = Invoke-GitCommand -WorkingDirectory $f.Source -Arguments @('worktree','list','--porcelain')
            Assert-P1A ($result.status -ceq 'removal-failed' -and $result.error.Contains($lockedPath) -and $registration.StdOut.Contains($f.Dispatch.Replace('\','/')) -and [IO.File]::Exists((Join-Path $f.Dispatch '.git'))) 'Locked removal lost registration or actual error.'
            Assert-P1A ((Invoke-Cleanup -Confirm:$false).worktree_removed) 'Unlocked retry failed.'
        }
        Invoke-P1ACase 'Q15 unregistered residue requires prior verified Cleanup result' {
            $f = New-P1ACleanupFixture (Join-Path $roundRoot 'residue')
            $script:SavedGitCommand = ${function:Invoke-GitCommand}
            $script:ResidualDispatch = $f.Dispatch
            function Invoke-GitCommand {
                [CmdletBinding()]
                param([string]$WorkingDirectory, [string[]]$Arguments, [switch]$AllowFailure)
                $result = & $script:SavedGitCommand -WorkingDirectory $WorkingDirectory -Arguments $Arguments -AllowFailure:$AllowFailure
                if ($Arguments.Count -gt 1 -and $Arguments[0] -ceq 'worktree' -and $Arguments[1] -ceq 'remove' -and $result.ExitCode -eq 0) {
                    Write-P1AText (Join-Path $script:ResidualDispatch 'leftover.txt') 'residue'
                    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'fixture removal failed after deregistration: leftover.txt' }
                }
                return $result
            }
            try { $result = Invoke-Cleanup -Confirm:$false }
            finally { Set-Item -LiteralPath Function:Invoke-GitCommand -Value $script:SavedGitCommand }
            Assert-P1A ($result.status -ceq 'removal-failed' -and [IO.Directory]::Exists($f.Dispatch)) 'Residue shape not generated.'
            $script:PreflightResultPath = ''
            Assert-P1A ((Invoke-Cleanup -Confirm:$false).worktree_removed) 'Verified residual recovery failed.'
            $f = New-P1ACleanupFixture (Join-Path $roundRoot 'unproved-residue')
            $null = Invoke-GitCommand -WorkingDirectory $f.Source -Arguments @('worktree','remove','--force',$f.Dispatch)
            Write-P1AText (Join-Path $f.Dispatch 'leftover.txt') 'unproved'
            $rejected = $false
            try { $null = Invoke-Cleanup -Confirm:$false }
            catch { $rejected = $_.Exception.Message -match '未在 Git worktree registration' }
            Assert-P1A ($rejected -and [IO.File]::Exists((Join-Path $f.Dispatch 'leftover.txt'))) 'Unregistered ordinary directory was deleted.'
        }
        Invoke-P1ACase 'Q16 Preflight refuses target in unregistered worktree; registered target succeeds' {
            $f = New-P1ACleanupFixture (Join-Path $roundRoot 'target')
            $script:DispatchSlug = 'next'
            $script:DispatchRoot = Join-Path $f.Source '.local\ai-sessions\worktrees\next'
            $script:ExecutionRoot = $script:DispatchRoot
            $script:TargetPath = @((Join-Path $f.Source '.local\ai-sessions\worktrees\missing\new.md'))
            $script:WriteMode = 'readonly'; $script:DispatchKind = 'resource'; $script:TaskType = 'script-change'
            $script:AddDirectory = @(); $script:PrepareResultPath = ''; $script:CodexHome = ''
            $rejected = $false
            try { $null = Invoke-Preflight }
            catch { $rejected = $_.Exception.Message -match 'PreflightTargetWorktreeNotRegistered' }
            Assert-P1A ($rejected -and -not [IO.Directory]::Exists($script:DispatchRoot) -and -not [IO.Directory]::Exists((Split-Path -Parent $script:TargetPath[0]))) 'Preflight created an ordinary worktree folder.'
            $script:TargetPath = @((Join-Path $f.Dispatch 'README.md'))
            $result = Invoke-Preflight
            Assert-P1A ($result.worktreeCreated -and [IO.File]::Exists((Join-Path $result.dispatchRoot '.git'))) 'Registered worktree target rejected.'
        }
        Invoke-P1ACase 'Q13 admission rejection precedes worktree creation; legacy output fields remain compatible' {
            $f = New-P1ACleanupFixture (Join-Path $roundRoot 'admission')
            $script:DispatchSlug = 'rejected'
            $script:DispatchRoot = Join-Path $f.Source '.local\ai-sessions\worktrees\rejected'
            $script:ExecutionRoot = $script:DispatchRoot
            $script:TargetPath = @((Join-Path $f.Source 'README.md'))
            $script:WriteMode = 'readonly'; $script:AddDirectory = @()
            $process = [Diagnostics.Process]::GetCurrentProcess()
            $lock = Open-DispatchAdmissionLock -SourceRoot $f.Source
            try {
                $ledger = Read-DispatchAdmissionLedger -Lock $lock
                $ledger.Document.entries = @(foreach ($slug in @('active-one','active-two')) {
                    [pscustomobject]@{ line_slug = 'p1a'; dispatch_slug = $slug; state = 'active'; write_mode = 'readonly'; write_paths = @(); caller_session_fingerprint = $script:CallerSessionIdentity.Fingerprint; process_id = $PID; process_name = $process.ProcessName; process_start_time_utc = $process.StartTime.ToUniversalTime().ToString('o') }
                })
                $null = Write-DispatchAdmissionLedger -Lock $lock -Ledger $ledger
            }
            finally { Close-DispatchAdmissionLock $lock }
            $rejected = $false
            try { $null = Invoke-Preflight }
            catch { $rejected = $_.Exception.Message -match 'DispatchAdmissionReadonlyLimit' }
            $registration = Invoke-GitCommand -WorkingDirectory $f.Source -Arguments @('worktree','list','--porcelain')
            Assert-P1A ($rejected -and -not [IO.Directory]::Exists($script:DispatchRoot) -and -not $registration.StdOut.Contains($script:DispatchRoot.Replace('\','/'))) 'Admission rejection left a worktree.'
            $currentResult = New-CleanupOperationResult -SourceRoot $f.Source -DispatchRoot $f.Dispatch -LineSlug 'p1a' -DispatchSlug $f.Slug
            foreach ($revision in @('b1955c5','75d8443','8310aec')) {
                $baseline = Invoke-GitCommand -WorkingDirectory (Split-Path -Parent $scriptsRoot) -Arguments @('show',($revision + ':scripts/dispatch/cleanup.ps1'))
                $tokens = $null; $errors = $null
                $ast = [Management.Automation.Language.Parser]::ParseInput($baseline.StdOut, [ref]$tokens, [ref]$errors)
                $constructor = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'New-CleanupOperationResult' }, $true)
                Assert-P1A ($null -ne $constructor) ('Legacy Cleanup constructor missing: ' + $revision)
                $baselineConstructor = [scriptblock]::Create($constructor.Body.Extent.Text.Substring(1, $constructor.Body.Extent.Text.Length - 2))
                $oldResult = & $baselineConstructor -SourceRoot $f.Source -DispatchRoot $f.Dispatch -LineSlug 'p1a' -DispatchSlug $f.Slug
                foreach ($key in $oldResult.Keys) { Assert-P1A ($currentResult.Contains($key)) ('Legacy result field missing: ' + $revision + '/' + $key) }
            }
        }
        Invoke-P1ACase 'fixed gate query denial and history junction reject before removal' {
            $f = New-P1ACleanupFixture (Join-Path $roundRoot 'query-denial')
            $savedPid = ${function:Get-PidCheckResult}
            function Get-PidCheckResult { throw 'Win32_Process fixture access denied' }
            $rejected = $false
            try { $null = Invoke-Cleanup -Confirm:$false }
            catch { $rejected = $_.Exception.Message -match 'Win32_Process fixture access denied' }
            finally { Set-Item -LiteralPath Function:Get-PidCheckResult -Value $savedPid }
            Assert-P1A ($rejected -and [IO.File]::Exists((Join-Path $f.Dispatch 'README.md'))) 'Denied process query inferred process absence.'
            $outside = Join-Path $roundRoot 'outside-receipt'
            $history = Join-Path $f.Source '.local\ai-sessions\history'
            $null = [IO.Directory]::CreateDirectory($outside)
            $null = Rename-Item -LiteralPath $history -NewName 'saved-history'
            $null = New-Item -ItemType Junction -Path $history -Target $outside
            $script:PreflightResultPath = ''
            $script:FailureReceiptPath = Join-Path $history 'p1a\failure.json'
            $rejected = $false
            try { $null = Invoke-Cleanup -Confirm:$false }
            catch { $rejected = $_.Exception.Message -match 'ReparsePoint' }
            Assert-P1A ($rejected -and @(Get-ChildItem -LiteralPath $outside -Force).Count -eq 0 -and [IO.File]::Exists((Join-Path $f.Dispatch 'README.md'))) 'History junction escaped Cleanup boundary.'
        }
    }
    elseif ($Unit -eq 'U3') {
        Invoke-P1ACase 'Q19 active write with add-dir permits readonly Preflight and Start without add-dir' {
            $f = New-P1ACleanupFixture (Join-Path $roundRoot 'empty')
            $null = Invoke-P1AAdmission $f 'active-write' 'write' -Directories @($baseRoot)
            $paths = Get-DispatchAdmissionWritePaths -SourceRoot $f.Source -ExecutionRoot $f.Source -WriteMode readonly
            Assert-P1A ($null -ne $paths -and $paths -is [array] -and $paths.Count -eq 0) 'Readonly paths did not preserve an empty array.'
            $preflight = Invoke-P1AReadonlyPreflight $f 'readonly'
            Assert-P1A ($preflight.worktreeCreated) 'Readonly Preflight was not admitted.'
            $admitted = Invoke-P1AAdmission $f 'readonly' 'readonly'
            Assert-P1A ($admitted.admission_status -eq 'admitted') 'Readonly Start was not admitted.'
            $nullFiltered = Assert-DispatchAdmission -SourceRoot $f.Source -CallerIdentity $script:CallerSessionIdentity -LineSlug 'p1a' -DispatchSlug 'null-probe' -WriteMode readonly -ExecutionRoot $f.Source
            Assert-P1A ($nullFiltered.allowed) 'Empty paths failed with nonempty active write paths.'
        }
        Invoke-P1ACase 'Q21 two readonly history add-dirs permit Preflight and Start; third readonly rejects' {
            $f = New-P1ACleanupFixture (Join-Path $roundRoot 'history')
            $history = Join-Path $f.Source '.local\ai-sessions\history\p1a'
            $null = Invoke-P1AReadonlyPreflight $f 'read-one' -Directories @($history)
            $null = Invoke-P1AAdmission $f 'read-one' 'readonly' -Directories @($history)
            $null = Invoke-P1AReadonlyPreflight $f 'read-two' -Directories @($history)
            $second = Invoke-P1AAdmission $f 'read-two' 'readonly' -Directories @($history)
            Assert-P1A ($second.admission_status -eq 'admitted') 'Second readonly history admission rejected.'
            foreach ($stage in @('Preflight','Start')) {
                $rejected = $false
                try {
                    if ($stage -eq 'Preflight') { $null = Invoke-P1AReadonlyPreflight $f 'read-three' -Directories @($history) }
                    else { $null = Invoke-P1AAdmission $f 'read-three' 'readonly' -Directories @($history) }
                }
                catch { $rejected = $_.Exception.Message -match 'DispatchAdmissionReadonlyLimit' }
                Assert-P1A $rejected ('Third readonly did not reject at ' + $stage)
            }
        }
        Invoke-P1ACase 'Q21 add-dir versus add-dir overlap permits admission outside history' {
            $f = New-P1ACleanupFixture (Join-Path $roundRoot 'add-only')
            $parent = Join-Path $f.Source 'shared'
            $null = Invoke-P1AAdmission $f 'read-one' 'readonly' -Directories @($parent)
            $admitted = Invoke-P1AAdmission $f 'read-two' 'readonly' -Directories @((Join-Path $parent 'child'))
            Assert-P1A ($admitted.admission_status -eq 'admitted') 'Add-dir versus add-dir overlap rejected.'
        }
        Invoke-P1ACase 'Q21 direct-write versus add-dir overlap rejects in both parent-child directions and orderings' {
            foreach ($directFirst in @($true,$false)) {
                foreach ($directParent in @($true,$false)) {
                    $f = New-P1ACleanupFixture (Join-Path $roundRoot ('overlap-' + $directFirst + '-' + $directParent))
                    $parent = Join-Path $f.Source 'protected'
                    $child = Join-Path $parent 'child'
                    $direct = if ($directParent) { $parent } else { $child }
                    $directory = if ($directParent) { $child } else { $parent }
                    $rejected = $false
                    if ($directFirst) { $null = Invoke-P1AAdmission $f 'direct' 'write' -Targets @($direct) }
                    else { $null = Invoke-P1AAdmission $f 'add' 'readonly' -Directories @($directory) }
                    try {
                        if ($directFirst) { $null = Invoke-P1AAdmission $f 'add' 'readonly' -Directories @($directory) }
                        else { $null = Invoke-P1AAdmission $f 'direct' 'write' -Targets @($direct) }
                    }
                    catch { $rejected = $_.Exception.Message -match 'DispatchAdmissionPathConflict' }
                    Assert-P1A $rejected 'Direct-write/add-dir overlap did not reject.'
                }
            }
        }
        Invoke-P1ACase 'Q21 history add-dir exemption does not hide direct-write overlap; second write still rejects' {
            $f = New-P1ACleanupFixture (Join-Path $roundRoot 'history-direct')
            $history = Join-Path $f.Source '.local\ai-sessions\history\p1a'
            $null = Invoke-P1AAdmission $f 'direct' 'write' -Targets @($f.Source)
            $historyRead = Invoke-P1AAdmission $f 'history-read' 'readonly' -Directories @($history)
            Assert-P1A ($historyRead.admission_status -eq 'admitted') 'Same-line history was included in conflicts.'
            $rejected = $false
            try { $null = Invoke-P1AAdmission $f 'second-write' 'write' -Targets @((Join-Path $f.Source 'separate')) }
            catch { $rejected = $_.Exception.Message -match 'DispatchAdmissionWriteLimit' }
            Assert-P1A $rejected 'Second write did not reject.'
            $rejected = $false
            try { $null = Invoke-P1AAdmission $f 'other-caller-direct' 'write' -Targets @((Join-Path $history 'own.json')) -Caller 'other-caller' }
            catch { $rejected = $_.Exception.Message -match 'DispatchAdmissionPathConflict' }
            Assert-P1A $rejected 'Direct history path overlap was not rejected.'
        }
    }
}
$failed = @($script:p1aResults | Where-Object { $_.status -eq 'FAIL' })
Write-Output (([ordered]@{ unit = $Unit; case_count = $script:p1aResults.Count; passed = $script:p1aResults.Count - $failed.Count; failed = $failed.Count; fixture_root = $fixtureRoot }) | ConvertTo-Json -Compress)
if ($failed.Count -gt 0) { exit 1 }
exit 0
