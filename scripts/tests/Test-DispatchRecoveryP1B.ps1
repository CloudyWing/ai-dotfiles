#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('B1','B2','B3','B4','B5','B6','B7','B8','B9','D1','D2','D3','D4','D5','D6','D7','All')][string]$Unit = 'All',
    [string]$FixtureBaseRootPath = 'C:\tmp',
    [ValidateRange(1,2)][int]$Repeat = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
foreach ($module in @('common-runtime','git-baseline','dispatch-scope','dispatch-evidence','quota-observation','advisor-evidence','process-identity','reviewer-contract','run-recovery','prepare-stage','dispatch-lifecycle','start-lifecycle','inspect-lifecycle','collect-contract','cleanup','Invoke-DispatchConcurrency')) {
    . (Join-Path $scriptsRoot ('dispatch\' + $module + '.ps1'))
}
$script:InvocationBoundParameters = @{}
$script:SourceRoot = ''; $script:ExecutionRoot = ''; $script:TargetPath = @()
$script:CallerSessionIdentity = $null
$script:RunRecordPath = ''; $script:RequestPath = ''; $script:RequiredIdentifier = ''; $script:ReviewerReportPath = ''
$script:BaselinePath = ''; $script:BaselineSha256 = ''; $script:SelectedRequirement = '#22'
$script:EvidencePath = @(); $script:FailureReceiptPath = ''; $script:PrepareResultPath = ''; $script:CodexHome = ''
$script:WorkflowCollectContractVersion = 'workflow-collect.v1'
$script:FixtureBaseRootPath = [IO.Path]::GetFullPath($FixtureBaseRootPath)
$root = Join-Path $script:FixtureBaseRootPath ('p1b-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($root)
$script:Results = New-Object 'Collections.Generic.List[object]'

function Write-P1BText {
    [CmdletBinding()]
    param([string]$Path, [AllowEmptyString()][string]$Text)
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Assert-P1B {
    [CmdletBinding()]
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-P1BCase {
    [CmdletBinding()]
    param([string]$Name, [scriptblock]$Action)
    $started = [DateTime]::UtcNow
    try {
        & $Action
        $row = [ordered]@{ unit = $Unit; round = $script:Round; case = $Name; status = 'PASS'; started_at_utc = $started.ToString('o'); error = $null }
    }
    catch { $row = [ordered]@{ unit = $Unit; round = $script:Round; case = $Name; status = 'FAIL'; started_at_utc = $started.ToString('o'); error = $_.Exception.ToString(); stack = $_.ScriptStackTrace } }
    $script:Results.Add($row)
    Write-Output ($row | ConvertTo-Json -Depth 10 -Compress)
}

function New-P1BFixtureName {
    [CmdletBinding()]
    param()
    return ('f-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}

function Get-P1BFixturePathPlan {
    [CmdletBinding()]
    param(
        [string]$FixtureRoot,
        [string]$DispatchSlug,
        [string]$LineSlug
    )
    $historyRoot = Join-Path $FixtureRoot ('.local\ai-sessions\worktrees\' + $DispatchSlug + '\.local\ai-sessions\history\' + $LineSlug)
    $checkpointFileName = 'interruption-checkpoint-' + $DispatchSlug + '-' + [guid]::Empty.ToString('D') + '.json'
    $longestPath = Join-Path $historyRoot $checkpointFileName
    $estimatedPathLength = $longestPath.Length
    if ($estimatedPathLength -gt 240) {
        throw ('Expected deepest path length: {0} characters; limit: 240; fixture root: {1}.' -f $estimatedPathLength, $FixtureRoot)
    }
    return [pscustomobject]@{
        FixtureRoot = $FixtureRoot
        DispatchRoot = Join-Path $FixtureRoot ('.local\ai-sessions\worktrees\' + $DispatchSlug)
        DispatchSlug = $DispatchSlug
        LongestPath = $longestPath
        EstimatedPathLength = $estimatedPathLength
    }
}
function New-P1BFixture {
    [CmdletBinding()]
    param(

        [string[]]$TargetPathRelative = @('README.md', 'new.txt'),
        [string[]]$AdditionalIgnore = @(),
        [string[]]$InitialTrackedFiles = @(),
        [string[]]$ModifiedTrackedFiles = @(),
        [string[]]$UntrackedFilesBeforePreflight = @(),
        [switch]$DeferPreflight,
        [string]$FixtureBaseRootPath = $script:FixtureBaseRootPath
    )
    $script:RunRecordPath = ''; $script:RequestPath = ''; $script:FailureReceiptPath = ''
    $script:BaselinePath = ''; $script:BaselineSha256 = ''; $script:ReviewerReportPath = ''
    $script:EvidencePath = @()
    $fixtureName = New-P1BFixtureName
    $fixtureBaseRoot = [IO.Path]::GetFullPath($FixtureBaseRootPath)
    $fixtureParent = $root
    if (-not [string]::Equals($fixtureBaseRoot, $script:FixtureBaseRootPath, [StringComparison]::OrdinalIgnoreCase)) {
        $fixtureParent = Join-Path $fixtureBaseRoot ('p1b-' + [guid]::NewGuid().ToString('N'))
    }
    $source = Join-Path $fixtureParent $fixtureName
    $pathPlan = Get-P1BFixturePathPlan -FixtureRoot $source -DispatchSlug $fixtureName -LineSlug 'p1b'
    $null = [IO.Directory]::CreateDirectory($source)
    Write-P1BText (Join-Path $source 'README.md') 'fixture'
    $ignoreContent = ".local/`r`n" + (($AdditionalIgnore | ForEach-Object { [string]$_ + "`r`n" }) -join '')
    Write-P1BText (Join-Path $source '.gitignore') $ignoreContent
    foreach ($relativePath in $InitialTrackedFiles) {
        Write-P1BText (Join-Path $source $relativePath) ('baseline:' + $relativePath)
    }
    $null = Invoke-GitCommand -WorkingDirectory $source -Arguments @('init')
    $initialGitPaths = @('README.md', '.gitignore') + @($InitialTrackedFiles)
    $null = Invoke-GitCommand -WorkingDirectory $source -Arguments (@('add', '--') + $initialGitPaths)
    $null = Invoke-GitCommand -WorkingDirectory $source -Arguments @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-m','fixture')
    foreach ($relativePath in $ModifiedTrackedFiles) {
        if ($InitialTrackedFiles -notcontains $relativePath) {
            throw ('ModifiedTrackedFiles must be included in InitialTrackedFiles: ' + $relativePath)
        }
        Write-P1BText (Join-Path $source $relativePath) 'FAKE_SECRET_VALUE_CHANGED'
    }
    foreach ($relativePath in $UntrackedFilesBeforePreflight) {
        Write-P1BText (Join-Path $source $relativePath) 'FAKE_SECRET_VALUE'
    }
    Write-P1BText (Join-Path $source '.local\ai-sessions\handoff\p1b\line.json') '{"schema":"ai-sessions.line.v1","line-slug":"p1b"}'
    $script:SourceRoot = $source
    $script:DispatchSlug = $fixtureName; $script:LineSlug = 'p1b'
    $script:DispatchRoot = $pathPlan.DispatchRoot
    $script:ExecutionRoot = $script:DispatchRoot
    $script:TargetPath = @($TargetPathRelative | ForEach-Object { Join-Path $source $_ })
    $script:WriteMode = 'write'; $script:DispatchKind = 'resource'; $script:TaskType = 'script-change'; $script:AddDirectory = @()
    $script:CallerSessionIdentity = Get-DispatchCallerSessionIdentity -CliCallerSessionId 'p1b-fixture' -CliCallerSessionIdProvided $true
    if ($DeferPreflight) {
        return [pscustomobject]@{ Source = $source; Dispatch = $script:DispatchRoot; Slug = $fixtureName; EstimatedLongestPathLength = $pathPlan.EstimatedPathLength; Preflight = $null }
    }
    $preflight = Invoke-Preflight
    $script:PreflightResultPath = Join-Path $source ('.local\ai-sessions\history\p1b\preflight-' + $fixtureName + '.json')
    Write-P1BText $script:PreflightResultPath ($preflight | ConvertTo-Json -Depth 30)
    $script:BaseSha = $preflight.baseSha
    return [pscustomobject]@{ Source = $source; Dispatch = $script:DispatchRoot; Slug = $fixtureName; EstimatedLongestPathLength = $pathPlan.EstimatedPathLength; Preflight = $preflight }
}

function Register-P1BOwner {
    [CmdletBinding()]
    param([object]$Fixture)
    $process = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $owner = [pscustomobject]@{ ProcessId = $PID; ProcessName = $process.ProcessName; ProcessStartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o'); RunRecordPath = ''; PidRecordPath = '' }
        $paths = Get-DispatchAdmissionWritePaths -SourceRoot $Fixture.Source -ExecutionRoot $Fixture.Dispatch -WriteMode write -TargetPath $script:TargetPath -AddDirectory @()
        $null = Invoke-DispatchAdmissionStart -SourceRoot $Fixture.Source -CallerIdentity $script:CallerSessionIdentity -LineSlug p1b -DispatchSlug $Fixture.Slug -WriteMode write -WritePaths $paths -PidCheckAction { [pscustomobject]@{ Blocked = $false } } -StartAction { $owner }
    }
    finally { $process.Dispose() }
}

function Set-P1BUnstartedCleanup {
    [CmdletBinding()]
    param([object]$Fixture)
    $script:CleanupBeforeRemovalHook = $null
    $script:ReportPath = @((Join-Path $Fixture.Dispatch '.local\ai-sessions\report\p1b'))
    $script:EvidencePath = @(); $script:RunRecordPath = ''
    $script:FailureReceiptPath = Join-Path $Fixture.Source ('.local\ai-sessions\history\p1b\failure-' + $Fixture.Slug + '.json')
    Write-P1BText $script:FailureReceiptPath (([ordered]@{ schema = 'ai-sessions.dispatch-failure-receipt.v1'; source_root = $Fixture.Source; execution_root = $Fixture.Dispatch; dispatch_root = $Fixture.Dispatch; line_slug = 'p1b'; dispatch_slug = $Fixture.Slug; process_started = $false; status = 'failed'; failed_stage = 'start'; error_code = 'DispatchAdmissionWriteLimit' }) | ConvertTo-Json)
}

function Get-P1BReport {
    [CmdletBinding()]
    param([string]$Slug, [int]$ReportRound)
    return "# Report`r`n`r`n## Finding manifest`r`n`r`n``````json`r`n" + (([ordered]@{ schema = 'codex-dispatch.review-findings.v2'; line_slug = 'p1b'; dispatch_slug = $Slug; round = $ReportRound }) | ConvertTo-Json) + "`r`n```````r`n"
}

function Set-P1BWorkflowCollectInputs {
    [CmdletBinding()]
    param([object]$Fixture, [string[]]$Paths)
    $script:ReportPath = @((Join-Path $Fixture.Dispatch '.local\ai-sessions\report\p1b\closure.md'))
    $script:RequirementSummaryPath = Join-Path $Fixture.Dispatch '.local\ai-sessions\handoff\p1b\requirement-summary.md'
    $nl = ([string][char]13) + [char]10
    $summary = @(
        '## 程式面項目'
        ''
        '| # | 項目 | 內容 |'
        '| --- | --- | --- |'
        '| 1 | fixture | fixture |'
        ''
        '## 功能面項目'
        ''
        '| # | 項目 | 內容 |'
        '| --- | --- | --- |'
        '| 22 | fixture | fixture |'
    ) -join $nl
    Write-P1BText $script:RequirementSummaryPath $summary
    $mark = [string][char]96
    $phaseLines = @($Paths | ForEach-Object { '- Phase 2：' + $mark + [string]$_ + $mark })
    $report = @(
        '## Phase 對照'
        ''
    ) + $phaseLines + @(
        ''
        '## 需求對照'
        ''
        '| 需求 | 驗收方向 | T-code | 實際行為 | 證據 | 狀態 |'
        '| --- | --- | --- | --- | --- | --- |'
        ('| #22 | fixture | T049 | Collect apply | ' + [string]$Paths[0] + ':1 | 部分交付 |')
        '範圍外（本輪不要求交付）：#1'
    ) -join $nl
    Write-P1BText $script:ReportPath[0] $report
}

function Set-P1BEvidenceCleanup {
    [CmdletBinding()]
    param([object]$Fixture)
    Set-P1BUnstartedCleanup $Fixture
    $id = [guid]::NewGuid().ToString('D')
    $script:RunRecordPath = Join-Path $Fixture.Source ('.local\ai-sessions\history\p1b\runs\' + $Fixture.Slug + '\' + $id + '.json')
    $event = Join-Path $Fixture.Dispatch '.local\ai-sessions\history\events.jsonl'
    $record = [ordered]@{
        schema = 'ai-sessions.dispatch-run.v1'; run_id = $id; source_root = $Fixture.Source; execution_root = $Fixture.Dispatch; line_slug = 'p1b'; dispatch_slug = $Fixture.Slug
        event_stream_path = $event; last_message_path = (Join-Path $Fixture.Dispatch '.local\ai-sessions\history\last.md')
        preflight_result_path = $script:PreflightResultPath; preflight_sha256 = (Get-FileSha256 $script:PreflightResultPath); pid_record_path = (Join-Path $Fixture.Source '.local\ai-sessions\history\codex-pid-cleanup.txt')
        created_at_utc = [DateTime]::UtcNow.ToString('o'); launch_state = 'launch-failed'; scope_plan_path = $null; scope_plan_sha256 = $null
        caller_session_fingerprint = $script:CallerSessionIdentity.Fingerprint
        baseline_resolution = @{ status = 'failed'; query_location = $Fixture.Source; error = 'fixture pre-start failure' }
        failure = (New-DispatchFailureRecord -Phase preparation -Message 'fixture pre-start failure' -ProcessStarted $false -Observation ([pscustomobject]@{ process_started = $false }))
    }
    Write-P1BText $script:RunRecordPath ($record | ConvertTo-Json -Depth 10)
    Write-P1BText $event '{"fixture":"pre-start evidence"}'
    return $event
}

function New-P1BInspectFixture {
    [CmdletBinding()]
    param([string]$FinalMessage, [string]$TerminalEvent = 'turn.failed', [string]$FailureReason = 'Selected model is at capacity')

    $fixture = New-P1BFixture -TargetPathRelative @('README.md')
    $finalMessage = $FinalMessage.Replace('__P1B_DISPATCH_SLUG__', $fixture.Slug)
    $dispatchHistory = Join-Path $fixture.Dispatch '.local\ai-sessions\history\p1b'
    $sourceHistory = Join-Path $fixture.Source '.local\ai-sessions\history\p1b'
    $runId = [guid]::NewGuid().ToString('D')
    $threadId = [guid]::NewGuid().ToString('D')
    $runRecordPath = Join-Path (Join-Path $sourceHistory ('runs\' + $fixture.Slug)) ($runId + '.json')
    $eventPath = Join-Path $dispatchHistory ($fixture.Slug + '.jsonl')
    $lastMessagePath = Join-Path $dispatchHistory ($fixture.Slug + '-last.md')
    $scopePlanPath = Join-Path $dispatchHistory ($fixture.Slug + '-scope.json')
    $scopePlan = New-ScopePlan -DispatchSlug $fixture.Slug -DispatchKind 'resource' -TaskType 'script-change' -RequestedProfile 'default' -SessionMode 'cold-start' -BeforeSnapshot $null -Units @('d2-inspect') -UnitKind 'resource-target' -RequestedBudgetPercent $null -RequestedReservePercent $null -Model $null -ModelEvidence $null -ReasoningEffortEvidence $null -ActivationDecision $null
    Write-P1BText $scopePlanPath ($scopePlan | ConvertTo-Json -Depth 30)
    $now = [DateTime]::UtcNow.ToString('o')
    $events = @(
        [ordered]@{ type = 'thread.started'; thread_id = $threadId }
        [ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'agent_message'; text = $finalMessage } }
        [ordered]@{ type = $TerminalEvent; error = [ordered]@{ message = $FailureReason } }
    )
    Write-P1BText $eventPath (($events | ForEach-Object { $_ | ConvertTo-Json -Depth 15 -Compress }) -join "`r`n")
    Write-P1BText $lastMessagePath $finalMessage
    $record = [pscustomobject]@{
        schema = 'ai-sessions.dispatch-run.v1'
        run_id = $runId
        line_slug = 'p1b'
        dispatch_slug = $fixture.Slug
        source_root = $fixture.Source
        execution_root = $fixture.Dispatch
        previous_run_id = $null
        requested_thread_id = $null
        thread_id = $threadId
        attempt_parent_run_id = $null
        resume_anchor_run_id = $null
        skipped_attempts = @()
        event_stream_path = Resolve-AbsolutePath $eventPath
        last_message_path = Resolve-AbsolutePath $lastMessagePath
        scope_plan_path = Resolve-AbsolutePath $scopePlanPath
        scope_plan_sha256 = Get-FileSha256 $scopePlanPath
        scope_plan_parent_path = $null
        scope_plan_parent_sha256 = $null
        scope_plan_parent_run_id = $null
        scope_plan_root_run_id = $runId
        scope_plan_selection = 'root'
        preflight_result_path = Resolve-AbsolutePath $script:PreflightResultPath
        preflight_sha256 = Get-FileSha256 $script:PreflightResultPath
        pid_record_path = Resolve-AbsolutePath (Join-Path $sourceHistory ($fixture.Slug + '.pid'))
        created_at_utc = $now
        started_at_utc = $now
        launch_state = 'started'
        baseline_path = $fixture.Preflight.baselinePath
        baseline_sha256 = $fixture.Preflight.baselineSha256
        baseline_resolution = [ordered]@{ status = 'confirmed'; query_location = $fixture.Source; path = $fixture.Preflight.baselinePath; sha256 = $fixture.Preflight.baselineSha256 }
        failure = $null
        resume_diagnostics = $null
        model_evidence = $null
        reasoning_effort_evidence = $null
        parent_options = $null
        parent_options_sha256 = $null
        parent_options_status = 'unknown'
        quota_before_path = $null
        quota_before_sha256 = $null
    }
    $null = Write-DispatchRunRecord -Record $record
    $script:SourceRoot = $fixture.Source
    $script:ExecutionRoot = $fixture.Dispatch
    $script:DispatchRoot = $fixture.Dispatch
    $script:DispatchSlug = $fixture.Slug
    $script:LineSlug = 'p1b'
    $script:TargetPath = @((Join-Path $fixture.Source 'README.md'))
    $script:WriteMode = 'readonly'
    $script:DispatchKind = 'resource'
    $script:TaskType = 'script-change'
    $script:RequiredIdentifier = 'design.md'
    $script:DispatchResultPath = ''
    $script:WaitForCompletion = $false
    $script:EventStreamPath = Resolve-AbsolutePath $eventPath
    $script:ScopePlanPath = Resolve-AbsolutePath $scopePlanPath
    $script:RunRecordPath = Resolve-AbsolutePath $runRecordPath
    $script:ProcessExitCode = 0
    $script:LastMessagePath = Resolve-AbsolutePath $lastMessagePath
    $script:ErrorStreamPath = ''
    $script:ThreadIdPath = ''
    $script:QuotaBeforePath = ''
    $script:QuotaAfterPath = ''
    $script:BudgetMonitorPath = ''
    $script:CodexHome = ''
    $script:AdvisorConsultReportPath = ''
    $script:EvidencePackPath = ''
    $script:SessionMode = 'cold-start'
    $script:ReportPath = @()
    $script:InvocationBoundParameters = @{}
    return [pscustomobject]@{ Fixture = $fixture; EventPath = $eventPath; LastMessagePath = $lastMessagePath; FinalMessage = $finalMessage }
}

function Test-P1BFixturePathGuard {
    [CmdletBinding()]
    param()

    $defaultFixture = New-P1BFixture -DeferPreflight -FixtureBaseRootPath $script:FixtureBaseRootPath
    Assert-P1B ($defaultFixture.EstimatedLongestPathLength -le 240) ('Default fixture path exceeded the 240-character guard: ' + $defaultFixture.EstimatedLongestPathLength)

    $longBaseRoot = Join-Path $script:FixtureBaseRootPath ('fixture-base-' + [guid]::NewGuid().ToString('N') + '-' + ('x' * 90))
    $longError = ''
    try {
        $null = New-P1BFixture -DeferPreflight -FixtureBaseRootPath $longBaseRoot
    }
    catch {
        $longError = $_.Exception.Message
    }
    $lengthMatch = [regex]::Match($longError, 'Expected deepest path length: (?<length>\d+) characters; limit: 240; fixture root: (?<root>.+)\.')
    Assert-P1B ($lengthMatch.Success) ('Long fixture base path did not report the expected length, limit and fixture root: ' + $longError)
    Assert-P1B ([int]$lengthMatch.Groups['length'].Value -gt 240) ('Long fixture base path reported a length within the limit: ' + $longError)
    Assert-P1B ($lengthMatch.Groups['root'].Value.Contains($longBaseRoot)) ('Long fixture path error omitted the fixture root: ' + $longError)
    Assert-P1B (-not [IO.Directory]::Exists($longBaseRoot)) 'Long fixture base root was created before the guard rejected it.'

    $guardResult = [ordered]@{
        unit = 'B2'
        case = 'fixture path-length guard'
        status = 'PASS'
        default_fixture_base_root = $script:FixtureBaseRootPath
        default_estimated_length = $defaultFixture.EstimatedLongestPathLength
        maximum_length = 240
        long_fixture_error = $longError
    }
    Write-Output ('B2_GUARD: ' + ($guardResult | ConvertTo-Json -Depth 5 -Compress))
}
for ($script:Round = 1; $script:Round -le $Repeat; $script:Round++) {
    Invoke-P1BCase 'T044 traversal and junction boundaries remain closed' {
        $guardRoot = Join-Path $root ('guard-' + [guid]::NewGuid().ToString('N'))
        $outside = Join-Path $root ('outside-' + [guid]::NewGuid().ToString('N'))
        $null = [IO.Directory]::CreateDirectory($guardRoot)
        $null = [IO.Directory]::CreateDirectory($outside)
        Write-P1BText (Join-Path $outside 'sentinel.txt') 'unchanged'
        $null = New-Item -ItemType Junction -Path (Join-Path $guardRoot 'link') -Target $outside
        foreach ($relative in @('../sentinel.txt','link/sentinel.txt')) {
            $rejected = $false
            try { $null = Get-DispatchAdmissionContainedPath -Root $guardRoot -RelativePath $relative }
            catch { $rejected = $_.Exception.Message -match 'DispatchCollectPathInvalid' }
            Assert-P1B $rejected ('Boundary accepted: ' + $relative)
        }
        Assert-P1B ([IO.File]::ReadAllText((Join-Path $outside 'sentinel.txt')) -eq 'unchanged') 'External sentinel changed.'
    }
    if ($Unit -in @('B1','B9','All')) {
        foreach ($kind in @('resource','workflow')) {
            Invoke-P1BCase ($kind + ' approved add applies; unapproved add remains listed') {
                $fixture = New-P1BFixture
                Register-P1BOwner $fixture
                $baseline = Read-DispatchBaseline -Path $fixture.Preflight.baselinePath -Sha256 $fixture.Preflight.baselineSha256 -SourceRoot $fixture.Source -DispatchRoot $fixture.Dispatch -LineSlug p1b -DispatchSlug $fixture.Slug -BaseSha $script:BaseSha
                $absent = @($baseline.files | Where-Object { $_.path -eq 'new.txt' })
                Assert-P1B ($absent.Count -eq 1 -and -not $absent[0].exists -and $null -eq $absent[0].sha256) 'Approved absent target not recorded.'
                Write-P1BText (Join-Path $fixture.Dispatch 'new.txt') 'new payload'
                Write-P1BText (Join-Path $fixture.Dispatch 'unapproved.txt') 'unapproved payload'
                $script:ReportPath = @((Join-Path $fixture.Dispatch '.local\ai-sessions\report\p1b\closure.md'))
                $script:RequirementSummaryPath = Join-Path $fixture.Dispatch '.local\ai-sessions\handoff\p1b\requirement-summary.md'
                Write-P1BText $script:RequirementSummaryPath "## 程式面項目`r`n`r`n| # | 項目 | 內容 |`r`n| --- | --- | --- |`r`n| 1 | fixture | fixture |`r`n`r`n## 功能面項目`r`n`r`n| # | 項目 | 內容 |`r`n| --- | --- | --- |`r`n| 22 | fixture | fixture |`r`n"
                Write-P1BText $script:ReportPath[0] "## Phase 對照`r`n`r`n- Phase 2：``new.txt``、``unapproved.txt```r`n`r`n## 需求對照`r`n`r`n| 需求 | 驗收方向 | T-code | 實際行為 | 證據 | 狀態 |`r`n| --- | --- | --- | --- | --- | --- |`r`n| #22 | fixture | T049 | add | new.txt:1 | 已交付 |`r`n範圍外（本輪不要求交付）：#1`r`n"
                $script:DispatchKind = $kind
                $result = Invoke-Collect -ApplyCollectedChanges
                Assert-P1B ($result.status -eq 'collected' -and $result.sourceIntegration.status -eq 'applied' -and [IO.File]::ReadAllText((Join-Path $fixture.Source 'new.txt')) -eq 'new payload') 'Approved add was not applied.'
                Assert-P1B ($result.unappliedNewFiles -contains 'unapproved.txt' -and -not [IO.File]::Exists((Join-Path $fixture.Source 'unapproved.txt'))) 'Unapproved add was applied or omitted.'
                foreach ($field in @('newFiles','carryInFiles','rejectedFiles','allFiles','dispatchDiff','baselinePath','reportEvidence','identity','outputValid','worktreeRemoved')) { Assert-P1B ($result.Contains($field)) ('Missing result field: ' + $field) }
            }
            Invoke-P1BCase ($kind + ' approved add source drift rejects without source changes') {
                $fixture = New-P1BFixture
                Register-P1BOwner $fixture
                Write-P1BText (Join-Path $fixture.Dispatch 'new.txt') 'dispatch'
                Write-P1BText (Join-Path $fixture.Source 'new.txt') 'source'
                $baseline = Read-DispatchBaseline -Path $fixture.Preflight.baselinePath -Sha256 $fixture.Preflight.baselineSha256 -SourceRoot $fixture.Source -DispatchRoot $fixture.Dispatch -LineSlug p1b -DispatchSlug $fixture.Slug -BaseSha $script:BaseSha
                $script:ReportPath = @((Join-Path $fixture.Dispatch '.local\ai-sessions\report\p1b\closure.md'))
                $script:RequirementSummaryPath = Join-Path $fixture.Dispatch '.local\ai-sessions\handoff\p1b\requirement-summary.md'
                Write-P1BText $script:RequirementSummaryPath "## 程式面項目`r`n`r`n| # | 項目 | 內容 |`r`n| --- | --- | --- |`r`n| 1 | fixture | fixture |`r`n`r`n## 功能面項目`r`n`r`n| # | 項目 | 內容 |`r`n| --- | --- | --- |`r`n| 22 | fixture | fixture |`r`n"
                Write-P1BText $script:ReportPath[0] "## Phase 對照`r`n`r`n- Phase 2：``new.txt```r`n`r`n## 需求對照`r`n`r`n| 需求 | 驗收方向 | T-code | 實際行為 | 證據 | 狀態 |`r`n| --- | --- | --- | --- | --- | --- |`r`n| #22 | fixture | T049 | drift | new.txt:1 | 已交付 |`r`n範圍外（本輪不要求交付）：#1`r`n"
                $script:DispatchKind = $kind
                $rejected = $false
                try { $null = Invoke-Collect -ApplyCollectedChanges }
                catch { $rejected = $_.Exception.Message -match 'DispatchSourceDrift' }
                Assert-P1B ($rejected -and [IO.File]::ReadAllText((Join-Path $fixture.Source 'new.txt')) -eq 'source') 'Source drift was not safely rejected.'
            }
        }
        Invoke-P1BCase 'Staged out-of-target add remains unapplied' {
            $fixture = New-P1BFixture
            Register-P1BOwner $fixture
            Write-P1BText (Join-Path $fixture.Dispatch 'unapproved-index.txt') 'staged unapproved payload'
            $null = Invoke-GitCommand -WorkingDirectory $fixture.Dispatch -Arguments @('add', '--', 'unapproved-index.txt')
            $script:ReportPath = @((Join-Path $fixture.Dispatch '.local/ai-sessions/report/p1b/closure.md'))
            $script:RequirementSummaryPath = Join-Path $fixture.Dispatch '.local/ai-sessions/handoff/p1b/requirement-summary.md'
            $nl = ([string][char]13) + [char]10
            $summary = @(
                '## 程式面項目'
                ''
                '| # | 項目 | 內容 |'
                '| --- | --- | --- |'
                '| 1 | fixture | fixture |'
                ''
                '## 功能面項目'
                ''
                '| # | 項目 | 內容 |'
                '| --- | --- | --- |'
                '| 22 | fixture | fixture |'
            ) -join $nl
            Write-P1BText $script:RequirementSummaryPath $summary
            $mark = [string][char]96
            $phaseLine = '- Phase 2：' + $mark + 'unapproved-index.txt' + $mark
            $report = @(
                '## Phase 對照'
                ''
                $phaseLine
                ''
                '## 需求對照'
                ''
                '| 需求 | 驗收方向 | T-code | 實際行為 | 證據 | 狀態 |'
                '| --- | --- | --- | --- | --- | --- |'
                '| #22 | fixture | T049 | staged add | unapproved-index.txt:1 | 部分交付 |'
                '範圍外（本輪不要求交付）：#1'
            ) -join $nl
            Write-P1BText $script:ReportPath[0] $report
            $script:DispatchKind = 'workflow'
            $result = Invoke-Collect -ApplyCollectedChanges
            Assert-P1B ($result.status -eq 'collected' -and $result.newFiles -contains 'unapproved-index.txt' -and $result.unappliedNewFiles -contains 'unapproved-index.txt') 'Staged out-of-target file was omitted or applied.'
            Assert-P1B (-not [IO.File]::Exists((Join-Path $fixture.Source 'unapproved-index.txt')) -and $result.sourceIntegration.applied_paths -notcontains 'unapproved-index.txt') 'Staged out-of-target file changed the source.'
            foreach ($field in @('newFiles','carryInFiles','rejectedFiles','allFiles','dispatchDiff','baselinePath','reportEvidence','identity','outputValid','worktreeRemoved','unappliedNewFiles','sourceIntegration')) { Assert-P1B ($result.Contains($field)) ('Missing result field: ' + $field) }
        }
        Invoke-P1BCase 'Ignored approved absent target remains visible and applies' {
            $fixture = New-P1BFixture -TargetPathRelative @('README.md', 'ignored-target.txt') -AdditionalIgnore @('ignored-target.txt')
            Register-P1BOwner $fixture
            Write-P1BText (Join-Path $fixture.Dispatch 'ignored-target.txt') 'ignored payload'
            Set-P1BWorkflowCollectInputs -Fixture $fixture -Paths @('ignored-target.txt')
            $script:DispatchKind = 'workflow'
            $result = Invoke-Collect -ApplyCollectedChanges
            Assert-P1B ($result.status -eq 'collected' -and $result.allFiles -contains 'ignored-target.txt') 'Ignored approved target was absent from the Collect snapshot.'
            Assert-P1B ($result.sourceIntegration.status -eq 'applied' -and [IO.File]::ReadAllText((Join-Path $fixture.Source 'ignored-target.txt')) -eq 'ignored payload') 'Ignored approved target was not applied.'
        }
        Invoke-P1BCase 'Ignored approved absent target rejects source drift' {
            $fixture = New-P1BFixture -TargetPathRelative @('README.md', 'ignored-target.txt') -AdditionalIgnore @('ignored-target.txt')
            Register-P1BOwner $fixture
            Write-P1BText (Join-Path $fixture.Dispatch 'ignored-target.txt') 'dispatch payload'
            Write-P1BText (Join-Path $fixture.Source 'ignored-target.txt') 'source payload'
            Set-P1BWorkflowCollectInputs -Fixture $fixture -Paths @('ignored-target.txt')
            $script:DispatchKind = 'workflow'
            $rejected = $false
            try { $null = Invoke-Collect -ApplyCollectedChanges }
            catch { $rejected = $_.Exception.Message -match 'DispatchSourceDrift' }
            Assert-P1B ($rejected -and [IO.File]::ReadAllText((Join-Path $fixture.Source 'ignored-target.txt')) -eq 'source payload') 'Source drift did not reject the ignored approved target.'
        }
        Invoke-P1BCase 'Existing approved directory applies nested new files' {
            $fixture = New-P1BFixture -TargetPathRelative @('README.md', 'outputs') -InitialTrackedFiles @('outputs/baseline.txt')
            Register-P1BOwner $fixture
            Write-P1BText (Join-Path $fixture.Dispatch 'outputs/one.txt') 'one payload'
            Write-P1BText (Join-Path $fixture.Dispatch 'outputs/nested/two.txt') 'two payload'
            Set-P1BWorkflowCollectInputs -Fixture $fixture -Paths @('outputs/one.txt', 'outputs/nested/two.txt')
            $script:DispatchKind = 'workflow'
            $result = Invoke-Collect -ApplyCollectedChanges
            Assert-P1B ($result.status -eq 'collected' -and $result.sourceIntegration.status -eq 'applied') 'New files under an existing approved directory were not applied.'
            foreach ($relativePath in @('outputs/one.txt', 'outputs/nested/two.txt')) {
                Assert-P1B ($result.sourceIntegration.applied_paths -contains $relativePath -and [IO.File]::Exists((Join-Path $fixture.Source $relativePath))) ('Approved directory output was not written: ' + $relativePath)
            }
        }
        Invoke-P1BCase 'Approved absent directory applies new child file' {
            $fixture = New-P1BFixture -TargetPathRelative @('README.md', 'outputs\\')
            Register-P1BOwner $fixture
            Write-P1BText (Join-Path $fixture.Dispatch 'outputs/one.txt') 'one payload'
            Set-P1BWorkflowCollectInputs -Fixture $fixture -Paths @('outputs/one.txt')
            $script:DispatchKind = 'workflow'
            $result = Invoke-Collect -ApplyCollectedChanges
            Assert-P1B ($result.status -eq 'collected' -and $result.sourceIntegration.status -eq 'applied' -and [IO.File]::ReadAllText((Join-Path $fixture.Source 'outputs/one.txt')) -eq 'one payload') 'New child under an absent-at-start approved directory was not applied.'
        }
        Invoke-P1BCase 'Approved absent directory child rejects source drift' {
            $fixture = New-P1BFixture -TargetPathRelative @('README.md', 'outputs\\')
            Register-P1BOwner $fixture
            Write-P1BText (Join-Path $fixture.Dispatch 'outputs/one.txt') 'dispatch payload'
            Write-P1BText (Join-Path $fixture.Source 'outputs/one.txt') 'source payload'
            Set-P1BWorkflowCollectInputs -Fixture $fixture -Paths @('outputs/one.txt')
            $script:DispatchKind = 'workflow'
            $rejected = $false
            try { $null = Invoke-Collect -ApplyCollectedChanges }
            catch { $rejected = $_.Exception.Message -match 'DispatchSourceDrift' }
            Assert-P1B ($rejected -and [IO.File]::ReadAllText((Join-Path $fixture.Source 'outputs/one.txt')) -eq 'source payload') 'Source drift did not reject a new approved-directory child.'
        }
    }
    if ($Unit -in @('B2','B9','All')) {
        Invoke-P1BCase 'Cleanup dot-source caller may omit ReportPath variable' {
            $fixture = New-P1BFixture
            Set-P1BUnstartedCleanup $fixture
            $relative = '.local\ai-sessions\report\dispatch-report-' + $fixture.Slug + '.md'
            Write-P1BText (Join-Path $fixture.Dispatch $relative) '# Dispatch report'
            Remove-Variable -Name ReportPath -Scope Script
            try {
                $result = Invoke-Cleanup -Confirm:$false
                Assert-P1B ($result.worktree_removed -and [IO.File]::Exists((Join-Path $fixture.Source $relative))) 'Omitted ReportPath variable failed under StrictMode.'
            }
            finally { $script:ReportPath = @() }
        }
        Invoke-P1BCase 'Cleanup automatically preserves dispatch report with only line ReportPath' {
            $fixture = New-P1BFixture
            Set-P1BUnstartedCleanup $fixture
            $relative = '.local\ai-sessions\report\dispatch-report-' + $fixture.Slug + '.md'
            Write-P1BText (Join-Path $fixture.Dispatch $relative) '# Dispatch report'
            $result = Invoke-Cleanup -Confirm:$false
            Assert-P1B ($result.status -eq 'completed' -and $result.worktree_removed -and [IO.File]::ReadAllText((Join-Path $fixture.Source $relative)) -eq '# Dispatch report') 'Dispatch report lost.'
            foreach ($field in @('schema','source_files','destination_files','files','errors','worktree_removed','status','failure_code','error','inventory','removal')) { Assert-P1B ($result.Contains($field)) ('Missing Cleanup field: ' + $field) }
        }
        Invoke-P1BCase 'Cleanup refuses unlisted report root file and preserves worktree' {
            $fixture = New-P1BFixture
            Set-P1BUnstartedCleanup $fixture
            $path = Join-Path $fixture.Dispatch '.local\ai-sessions\report\unlisted.md'
            Write-P1BText $path 'unlisted'
            $failure = $null
            try { $null = Invoke-Cleanup -Confirm:$false }
            catch { $failure = $_.Exception.Data['operationResult'] }
            Assert-P1B ($null -ne $failure -and $failure.status -eq 'preservation-failed' -and $failure.error.Contains($path) -and [IO.Directory]::Exists($fixture.Dispatch)) 'Unlisted file was removed or not reported.'
        }
        Invoke-P1BCase 'Cleanup rechecks report root immediately before removal' {
            $fixture = New-P1BFixture
            Set-P1BUnstartedCleanup $fixture
            $latePath = Join-Path $fixture.Dispatch '.local\ai-sessions\report\late-unlisted.md'
            $script:CleanupBeforeRemovalHook = {
                param([string]$ReportsRoot)
                Write-P1BText (Join-Path $ReportsRoot 'late-unlisted.md') 'added after inventory'
            }
            $failure = $null
            try { $null = Invoke-Cleanup -Confirm:$false }
            catch { $failure = $_.Exception.Data['operationResult'] }
            finally { $script:CleanupBeforeRemovalHook = $null }
            Assert-P1B ($null -ne $failure -and $failure.status -eq 'preservation-failed' -and $failure.failure_code -eq 'CleanupReportUnpreserved' -and $failure.error.Contains($latePath)) 'Late report was not rejected as a preservation failure.'
            Assert-P1B ([IO.Directory]::Exists($fixture.Dispatch) -and [IO.File]::ReadAllText($latePath) -eq 'added after inventory' -and -not [IO.File]::Exists((Join-Path $fixture.Source '.local\ai-sessions\report\late-unlisted.md'))) 'Late report or worktree was removed or copied unexpectedly.'
        }
    }
    if ($Unit -in @('B3','B9','All')) {
        Invoke-P1BCase 'Cleanup report version reads paths beyond the legacy path limit' {
            $fixture = New-P1BFixture
            $longDirectory = Join-Path $fixture.Dispatch '.local\ai-sessions\report\p1b'
            foreach ($segment in @(('first-' + ('a' * 72)), ('second-' + ('b' * 72)), ('third-' + ('c' * 72)))) {
                $longDirectory = Join-Path $longDirectory $segment
            }
            $longReportPath = Join-Path $longDirectory 'review-report.md'
            Assert-P1B ($longReportPath.Length -gt 260) 'Long path fixture did not exceed the legacy path limit.'
            $fileSystemPath = ConvertTo-FileSystemApiPath -Path $longReportPath
            $null = [IO.Directory]::CreateDirectory((ConvertTo-FileSystemApiPath -Path $longDirectory))
            [IO.File]::WriteAllText($fileSystemPath, ('dispatchSlug=' + $fixture.Slug), (New-Object Text.UTF8Encoding($false)))
            $version = Get-CleanupReportVersion -Path $longReportPath -SourceRoot $fixture.Source -LineSlug 'p1b' -KnownDispatchSlug $fixture.Slug
            Assert-P1B ($version.dispatch_slug -ceq $fixture.Slug -and $version.path -ceq $longReportPath) 'Cleanup did not read the long-path report identity.'
        }
        Invoke-P1BCase 'RunRecord started time orders reports without manifest round' {
            $fixture = New-P1BFixture
            $olderSlug = New-P1BFixtureName
            $incomingSlug = New-P1BFixtureName
            foreach ($entry in @(@($olderSlug,'2026-01-01T00:00:00Z'),@($incomingSlug,'2026-01-02T00:00:00Z'))) {
                $path = Join-Path $fixture.Source ('.local\ai-sessions\history\p1b\runs\' + $entry[0] + '\' + [guid]::NewGuid().ToString('D') + '.json')
                Write-P1BText $path (([ordered]@{ schema = 'ai-sessions.dispatch-run.v1'; line_slug = 'p1b'; dispatch_slug = $entry[0]; source_root = $fixture.Source; started_at_utc = $entry[1] }) | ConvertTo-Json)
            }
            $incoming = Join-Path $fixture.Dispatch '.local\ai-sessions\report\p1b\contract-auditor-report.md'
            $destination = Join-Path $fixture.Source '.local\ai-sessions\report\p1b\contract-auditor-report.md'
            Write-P1BText $incoming ('dispatchSlug=' + $incomingSlug)
            Write-P1BText $destination ('dispatchSlug=' + $olderSlug)
            $decision = Compare-CleanupReportVersion -IncomingPath $incoming -DestinationPath $destination -SourceRoot $fixture.Source -LineSlug p1b -DispatchSlug $incomingSlug
            Assert-P1B ($decision.incoming_newer -and $decision.basis -eq 'run-record-started-at-utc' -and $decision.incoming.run_record_paths.Count -eq 1) 'RunRecord ordering evidence not used.'
        }
        Invoke-P1BCase 'Newer report first then older Cleanup keeps newer and archives both' {
            $fixture = New-P1BFixture
            Set-P1BUnstartedCleanup $fixture
            $relative = '.local\ai-sessions\report\p1b\review-report.md'
            $initialSlug = New-P1BFixtureName
            $olderSlug = New-P1BFixtureName
            $initial = Get-P1BReport $initialSlug 1
            $newer = Get-P1BReport $fixture.Slug 3
            $older = Get-P1BReport $olderSlug 2
            Write-P1BText (Join-Path $fixture.Source $relative) $initial
            Write-P1BText (Join-Path $fixture.Dispatch $relative) $newer
            $newResult = Invoke-Cleanup -Confirm:$false
            $newFile = @($newResult.files | Where-Object { $_.relative_path -like '*/review-report.md' })[0]
            Assert-P1B ($newResult.status -eq 'completed' -and $newFile.version_decision.basis -eq 'report-manifest-round' -and [IO.File]::ReadAllText($newFile.archive_path) -eq $initial) 'New report did not archive original.'
            $script:DispatchSlug = $olderSlug
            $script:DispatchRoot = Join-Path $fixture.Source ('.local\ai-sessions\worktrees\' + $olderSlug)
            $script:ExecutionRoot = $script:DispatchRoot
            $null = Invoke-GitCommand -WorkingDirectory $fixture.Source -Arguments @('worktree','add','--detach',$script:DispatchRoot,'HEAD')
            $script:PreflightResultPath = Join-Path $fixture.Source ('.local\ai-sessions\history\p1b\preflight-' + $olderSlug + '.json')
            $oldPreflight = [ordered]@{ sourceRoot = $fixture.Source; dispatchRoot = $script:DispatchRoot; executionRoot = $script:DispatchRoot; lineSlug = 'p1b'; dispatchSlug = $olderSlug; worktreeCreated = $true }
            Write-P1BText $script:PreflightResultPath ($oldPreflight | ConvertTo-Json)
            $oldFixture = [pscustomobject]@{ Source = $fixture.Source; Dispatch = $script:DispatchRoot; Slug = $olderSlug }
            Set-P1BUnstartedCleanup $oldFixture
            Write-P1BText (Join-Path $oldFixture.Dispatch $relative) $older
            $oldResult = Invoke-Cleanup -Confirm:$false
            $oldFile = @($oldResult.files | Where-Object { $_.relative_path -like '*/review-report.md' })[0]
            Assert-P1B ($oldResult.status -eq 'completed' -and -not $oldFile.version_decision.incoming_newer -and [IO.File]::ReadAllText($oldFile.destination_path) -eq $newer -and [IO.File]::ReadAllText($oldFile.archive_path) -eq $older) 'Older report overwrote newer or disappeared.'
        }
        Invoke-P1BCase 'Unknown report version preserves worktree and destination' {
            $fixture = New-P1BFixture
            Set-P1BUnstartedCleanup $fixture
            $relative = '.local\ai-sessions\report\p1b\frontend-reviewer-report.md'
            Write-P1BText (Join-Path $fixture.Source $relative) 'source report'
            Write-P1BText (Join-Path $fixture.Dispatch $relative) 'incoming report'
            $failure = $null
            try { $null = Invoke-Cleanup -Confirm:$false }
            catch { $failure = $_.Exception.Data['operationResult'] }
            Assert-P1B ($null -ne $failure -and $failure.status -eq 'preservation-failed' -and $failure.error -match 'CleanupReportVersionUnknown' -and [IO.Directory]::Exists($fixture.Dispatch) -and [IO.File]::ReadAllText((Join-Path $fixture.Source $relative)) -eq 'source report') 'Unknown report order guessed or source changed.'
        }
    }
    if ($Unit -in @('B4','B9','All')) {
        Invoke-P1BCase 'H1-only exception preamble is compatible; destination preamble stays intact' {
            $fixture = New-P1BFixture
            Set-P1BUnstartedCleanup $fixture
            $relative = '.local\ai-sessions\report\p1b\exceptions.md'
            $original = "## existing`r`n`r`n- original`r`n"
            Write-P1BText (Join-Path $fixture.Source $relative) $original
            Write-P1BText (Join-Path $fixture.Dispatch $relative) ("# 例外紀錄`r`n`r`n" + $original + "`r`n## new`r`n`r`n- added`r`n")
            $result = Invoke-Cleanup -Confirm:$false
            $text = [IO.File]::ReadAllText((Join-Path $fixture.Source $relative))
            Assert-P1B ($result.worktree_removed -and $text.StartsWith($original.TrimEnd()) -and $text.Contains('## new') -and $text -notmatch '(?m)^# ') 'H1 inserted into source or blocks lost.'
            $destinationHeader = "# 來源例外`r`n`r`n" + $original
            $merged = Join-CleanupExceptionBlocks -SourceText "# 派遣例外`r`n`r`n## another`r`n`r`n- body" -DestinationText $destinationHeader
            Assert-P1B ($merged.StartsWith($destinationHeader.TrimEnd()) -and -not $merged.Contains('# 派遣例外')) 'Source H1 was not retained.'
        }
        Invoke-P1BCase 'Non-H1 exception preamble mismatch still rejects' {
            $rejected = $false
            try { $null = Join-CleanupExceptionBlocks -SourceText "different prose`n`n## new`n`n- body" -DestinationText "## original`n`n- body" }
            catch { $rejected = $_.Exception.Message -match 'CleanupExceptionsConflict' }
            Assert-P1B $rejected 'Non-H1 preamble mismatch accepted.'
        }
    }
    if ($Unit -in @('B5','B9','All')) {
        Invoke-P1BCase 'Zero-byte stdout stderr preserve with standard empty SHA256' {
            $fixture = New-P1BFixture
            Set-P1BUnstartedCleanup $fixture
            foreach ($name in @('stdout.log','stderr.log')) { Write-P1BText (Join-Path $fixture.Dispatch ('.local\ai-sessions\report\p1b\' + $name)) '' }
            $emptyHash = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
            Assert-P1B ((Get-DispatchByteArraySha256 -Bytes ([byte[]]@())) -eq $emptyHash) 'Empty byte-array hash rejected or incorrect.'
            $result = Invoke-Cleanup -Confirm:$false
            Assert-P1B ($result.worktree_removed -and $result.files.Count -eq 2) 'Empty logs not preserved.'
            foreach ($file in $result.files) { Assert-P1B ($file.length -eq 0 -and $file.source_sha256 -eq $emptyHash -and $file.destination_sha256 -eq $emptyHash -and [IO.File]::Exists($file.destination_path)) 'Empty log evidence incorrect.' }
        }
        Invoke-P1BCase 'Evidence binding handles empty diff and empty untracked file' {
            $fixture = New-P1BFixture
            Write-P1BText (Join-Path $fixture.Dispatch 'empty.txt') ''
            $binding = New-DispatchEvidenceBinding -ExecutionRoot $fixture.Dispatch -EvidencePosition $null
            $emptyHash = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
            Assert-P1B ($binding.capture_status -eq 'completed' -and $binding.tracked_diff_sha256 -eq $emptyHash -and @($binding.untracked_files).Count -eq 1 -and $binding.untracked_files[0].sha256 -eq $emptyHash) ('Empty binding failed: ' + $binding.capture_error)
            foreach ($field in @('schema','head','tracked_diff_sha256','untracked_files','uncommitted_content_fingerprint','serialization_version','commands','evidence_position','captured_at_utc','capture_status','capture_error')) { Assert-P1B ($binding.Contains($field)) ('Missing binding field: ' + $field) }
        }
    }
    if ($Unit -in @('B8','All')) {
        Invoke-P1BCase 'Finished staged readonly owner releases admission without Collect' {
            $fixture = New-P1BFixture
            $script:WriteMode = 'readonly'
            $hostPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $child = Start-Process -FilePath $hostPath -ArgumentList '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Start-Sleep -Seconds 2"' -WindowStyle Hidden -PassThru
            try {
                $owner = [pscustomobject]@{ ProcessId = $child.Id; ProcessName = $child.ProcessName; ProcessStartTimeUtc = $child.StartTime.ToUniversalTime().ToString('o'); RunRecordPath = ''; PidRecordPath = '' }
                $null = Invoke-DispatchAdmissionStart -SourceRoot $fixture.Source -CallerIdentity $script:CallerSessionIdentity -LineSlug p1b -DispatchSlug $fixture.Slug -WriteMode readonly -WritePaths @() -PidCheckAction { [pscustomobject]@{ Blocked = $false } } -StartAction { $owner }
                Assert-P1B ($child.WaitForExit(15000)) 'Readonly fixture did not finish.'
                $child.Refresh()
                Assert-P1B ($child.ExitCode -eq 0) 'Readonly child failed.'
                $ledgerPath = Join-Path $fixture.Source '.local\ai-sessions\history\dispatch-admission-ledger.json'
                $ledgerBefore = [IO.File]::ReadAllText($ledgerPath) | ConvertFrom-Json
                Assert-P1B ($ledgerBefore.entries[0].state -eq 'active') 'Fixture did not retain staged active entry.'
                $current = [Diagnostics.Process]::GetCurrentProcess()
                $activeOwner = [pscustomobject]@{ ProcessId = $PID; ProcessName = $current.ProcessName; ProcessStartTimeUtc = $current.StartTime.ToUniversalTime().ToString('o'); RunRecordPath = ''; PidRecordPath = '' }
                foreach ($slug in @('readonly-live-one','readonly-live-two')) {
                    $null = Invoke-DispatchAdmissionStart -SourceRoot $fixture.Source -CallerIdentity $script:CallerSessionIdentity -LineSlug p1b -DispatchSlug $slug -WriteMode readonly -WritePaths @() -PidCheckAction { [pscustomobject]@{ Blocked = $false } } -StartAction { $activeOwner }
                }
                $ledgerAfter = [IO.File]::ReadAllText($ledgerPath) | ConvertFrom-Json
                Assert-P1B ($ledgerAfter.schema -eq 'ai-sessions.dispatch-admission.v1' -and @($ledgerAfter.entries | Where-Object { $_.state -eq 'finished' -and $_.dispatch_slug -eq $fixture.Slug }).Count -eq 1 -and @($ledgerAfter.entries | Where-Object { $_.state -eq 'active' }).Count -eq 2) 'Ended owner still consumes readonly admission.'
                $current.Dispose()
            }
            finally { $child.Dispose() }
        }
        Invoke-P1BCase 'Unknown owner keeps active state and refuses admission' {
            $fixture = New-P1BFixture
            $owner = [pscustomobject]@{ ProcessId = $PID; ProcessName = ''; ProcessStartTimeUtc = [DateTime]::UtcNow.ToString('o'); RunRecordPath = ''; PidRecordPath = '' }
            $null = Invoke-DispatchAdmissionStart -SourceRoot $fixture.Source -CallerIdentity $script:CallerSessionIdentity -LineSlug p1b -DispatchSlug $fixture.Slug -WriteMode readonly -WritePaths @() -PidCheckAction { [pscustomobject]@{ Blocked = $false } } -StartAction { $owner }
            $ledgerPath = Join-Path $fixture.Source '.local\ai-sessions\history\dispatch-admission-ledger.json'
            $beforeHash = Get-FileSha256 $ledgerPath
            $rejected = $false
            try { $null = Assert-DispatchAdmission -SourceRoot $fixture.Source -CallerIdentity $script:CallerSessionIdentity -LineSlug p1b -DispatchSlug readonly-next -WriteMode readonly -ExecutionRoot $fixture.Dispatch }
            catch { $rejected = $_.Exception.Message -match 'DispatchAdmissionOwnerUnknown' }
            Assert-P1B ($rejected -and (Get-FileSha256 $ledgerPath) -eq $beforeHash) 'Unknown owner guessed finished or ledger modified.'
        }
    }
    if ($Unit -in @('B7','B9','All')) {
        Invoke-P1BCase 'Direct-write directory captures two per-file evidence records' {
            $source = Join-Path $root ('direct-' + [guid]::NewGuid().ToString('N'))
            $target = Join-Path $source 'outputs'
            Write-P1BText (Join-Path $target 'one.txt') 'one'
            Write-P1BText (Join-Path $target 'nested\two.txt') 'two'
            $report = Join-Path $source 'closure.md'
            Write-P1BText $report '# Closure'
            $result = Invoke-DirectWriteCollect -SourceRoot $source -ExecutionRoot $source -DispatchRoot $source -DispatchKind resource -TargetStates @([pscustomobject]@{ InputPath = $target; FullPath = $target }) -ReportPath @($report) -LineSlug p1b -DispatchSlug direct-directory
            Assert-P1B ($result.status -eq 'collected' -and $result.approvedOutputs.Count -eq 2) 'Directory output evidence missing.'
            $expectedEvidencePaths = @('one.txt', 'nested\two.txt')
            $evidencePaths = @($result.approvedOutputs | ForEach-Object { (Get-RelativePathFromRoot -Path $_.evidence.path -Root $target).Replace('/', '\') })
            $uniqueEvidencePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            $hasDuplicateEvidencePaths = $false
            foreach ($path in $evidencePaths) { if (-not $uniqueEvidencePaths.Add([string]$path)) { $hasDuplicateEvidencePaths = $true } }
            $hasExactEvidencePaths = $evidencePaths.Count -eq $expectedEvidencePaths.Count -and @($expectedEvidencePaths | Where-Object { $evidencePaths -notcontains $_ }).Count -eq 0
            Assert-P1B ($hasExactEvidencePaths -and -not $hasDuplicateEvidencePaths) 'Directory evidence paths were missing, unexpected, or duplicated.'
            foreach ($output in $result.approvedOutputs) { Assert-P1B ($output.evidence.length -eq 3 -and $output.evidence.lastWriteTimeUtc -and $output.evidence.sha256 -eq (Get-FileSha256 $output.evidence.path)) 'Per-file length/time/hash missing.' }
            foreach ($field in @('operation','status','collectionMode','sourceRoot','executionRoot','dispatchRoot','baseSha','dispatchKind','reportPaths','reportEvidence','identity','outputValid','worktreeRemoved')) { Assert-P1B ($result.Contains($field)) ('Missing direct-write field: ' + $field) }
        }
        Invoke-P1BCase 'Direct-write empty directory and missing target refuse with paths' {
            $source = Join-Path $root ('direct-empty-' + [guid]::NewGuid().ToString('N'))
            $target = Join-Path $source 'outputs'
            $null = [IO.Directory]::CreateDirectory($target)
            $report = Join-Path $source 'closure.md'; Write-P1BText $report '# Closure'
            foreach ($path in @($target,(Join-Path $source 'missing'))) {
                $message = ''
                try { $null = Invoke-DirectWriteCollect -SourceRoot $source -ExecutionRoot $source -DispatchRoot $source -DispatchKind resource -TargetStates @([pscustomobject]@{ FullPath = $path }) -ReportPath @($report) -LineSlug p1b -DispatchSlug direct-empty }
                catch { $message = $_.Exception.Message }
                Assert-P1B ($message.Contains($path) -and $message -match '沒有非空檔案|缺少') 'Empty/missing target not rejected with path.'
            }
            Write-P1BText (Join-Path $target 'empty.txt') ''
            $rejected = $false
            try { $null = Invoke-DirectWriteCollect -SourceRoot $source -ExecutionRoot $source -DispatchRoot $source -DispatchKind resource -TargetStates @([pscustomobject]@{ FullPath = $target }) -ReportPath @($report) -LineSlug p1b -DispatchSlug direct-empty }
            catch { $rejected = $_.Exception.Message -match '沒有非空檔案' }
            Assert-P1B $rejected 'Directory containing only empty files accepted.'
        }
    }
    if ($Unit -in @('B6','B9','All')) {
        Invoke-P1BCase 'Omitted EvidencePath preserves RunRecord event stream' {
            $fixture = New-P1BFixture
            $event = Set-P1BEvidenceCleanup $fixture
            $script:EvidencePath = $null
            $result = Invoke-Cleanup -Confirm:$false
            $file = @($result.files | Where-Object { $_.source_path -eq $event })
            Assert-P1B ($result.worktree_removed -and $file.Count -eq 1 -and [IO.File]::ReadAllText($file[0].destination_path) -eq '{"fixture":"pre-start evidence"}') 'Default event evidence lost.'
        }
        Invoke-P1BCase 'Explicit unreferenced evidence rejects and lists acceptable paths' {
            $fixture = New-P1BFixture
            $event = Set-P1BEvidenceCleanup $fixture
            $script:EvidencePath = @((Join-Path $fixture.Dispatch '.local\ai-sessions\history\unreferenced.log'))
            Write-P1BText $script:EvidencePath[0] 'unreferenced'
            $failure = $null
            try { $null = Invoke-Cleanup -Confirm:$false }
            catch { $failure = $_.Exception.Data['operationResult'] }
            Assert-P1B ($null -ne $failure -and $failure.error -match 'CleanupEvidenceUnreferenced' -and $failure.error.Contains($event) -and $failure.error.Contains($script:EvidencePath[0]) -and [IO.Directory]::Exists($fixture.Dispatch)) 'Unreferenced evidence not rejected with acceptable list.'
        }
    }
    if ($Unit -in @('D1','All')) {
        Invoke-P1BCase 'Preflight excludes tracked and untracked secret carry-in by filename' {
            $fixture = New-P1BFixture -TargetPathRelative @('README.md') -InitialTrackedFiles @('.env') -ModifiedTrackedFiles @('.env') -UntrackedFilesBeforePreflight @('secrets.json')
            $manifest = $fixture.Preflight.carryInManifest
            $excludedSecrets = @($manifest.excludedSecrets)
            $manifestText = $manifest | ConvertTo-Json -Depth 10 -Compress
            $preflightText = $fixture.Preflight | ConvertTo-Json -Depth 30 -Compress
            Assert-P1B ($excludedSecrets.Count -eq 2 -and $excludedSecrets -contains '.env' -and $excludedSecrets -contains 'secrets.json') ('Excluded secret paths missing: ' + ($excludedSecrets -join ', '))
            Assert-P1B ([IO.File]::ReadAllText((Join-Path $fixture.Dispatch '.env')) -eq 'baseline:.env') 'Tracked .env carry-in patch changed the worktree baseSha version.'
            Assert-P1B (-not [IO.File]::Exists((Join-Path $fixture.Dispatch 'secrets.json'))) 'Untracked secrets.json was copied into the worktree.'
            Assert-P1B (-not $manifest.TrackedPatchApplied -and @($manifest.CopiedFiles | Where-Object { $_ -in @('.env','secrets.json') }).Count -eq 0) 'A secret path was included in tracked patches or copied files.'
            Assert-P1B ($manifestText -notmatch 'FAKE_SECRET_VALUE' -and $preflightText -notmatch 'FAKE_SECRET_VALUE') 'Carry-in manifest or Preflight output disclosed fake secret content.'
        }
        Invoke-P1BCase 'Preflight rejects a secret target before worktree creation' {
            $fixture = New-P1BFixture -TargetPathRelative @('.env') -InitialTrackedFiles @('.env') -DeferPreflight
            $targetPath = [string]$script:TargetPath[0]
            $TargetPath = @($script:TargetPath)
            $failureMessage = ''
            $failureCode = ''
            try { $null = Invoke-Preflight }
            catch {
                $failureMessage = $_.Exception.ToString() + [Environment]::NewLine + $_.ScriptStackTrace
                $operationResult = $_.Exception.Data['operationResult']
                if ($null -ne $operationResult) { $failureCode = [string]$operationResult['code'] }
            }
            Assert-P1B ($failureCode -ceq 'PreflightSecretTargetRejected' -and $failureMessage.Contains($targetPath)) ('Secret target was not rejected with its path: ' + $failureMessage)
            Assert-P1B (-not [IO.Directory]::Exists($fixture.Dispatch)) 'Preflight created a worktree for a rejected secret target.'
        }
    }
    if ($Unit -in @('D2','All')) {
        Invoke-P1BCase 'Inspect reports PEM and connection-string exposures without outputting matched content' {
            $fakeValue = 'FAKE_SECRET_VALUE'
            $message = 'design.md dispatchSlug=__P1B_DISPATCH_SLUG__ lineSlug=p1b' + "`r`n-----BEGIN PRIVATE KEY-----`r`nPassword=" + $fakeValue
            $fixture = New-P1BInspectFixture $message
            $result = Invoke-Inspect
            $resultText = $result | ConvertTo-Json -Depth 30 -Compress
            $patterns = @($result.secret_exposure_findings | ForEach-Object { [string]$_.pattern })
            Assert-P1B ($result.secret_exposure_suspected -and $patterns -contains 'pem-private-key-header' -and $patterns -contains 'connection-string-password') 'Inspect did not report both secret patterns.'
            Assert-P1B (@($result.secret_exposure_findings | Where-Object { $_.file -eq $fixture.EventPath -and $_.line -eq 2 -and $_.pattern -eq 'pem-private-key-header' }).Count -eq 1) 'Event stream exposure location is missing or incorrect.'
            Assert-P1B (@($result.secret_exposure_findings | Where-Object { $_.file -eq $fixture.LastMessagePath -and $_.line -eq 3 -and $_.pattern -eq 'connection-string-password' }).Count -eq 1) 'Last-message exposure location is missing or incorrect.'
            Assert-P1B (-not $resultText.Contains($fakeValue) -and -not $resultText.Contains('-----BEGIN PRIVATE KEY-----')) 'Inspect output disclosed a matched secret value or PEM header.'
            Assert-P1B (-not $result.success -and $result.lastEventType -eq 'turn.failed') 'Secret scanning changed the turn.failed success result.'
        }
        Invoke-P1BCase 'Inspect reports a clean event stream as not suspected' {
            $message = 'design.md dispatchSlug=__P1B_DISPATCH_SLUG__ lineSlug=p1b'
            $null = New-P1BInspectFixture $message
            $result = Invoke-Inspect
            Assert-P1B (-not $result.secret_exposure_suspected -and @($result.secret_exposure_findings).Count -eq 0) 'Clean event stream was marked as a secret exposure.'
            Assert-P1B (-not $result.success -and $result.lastEventType -eq 'turn.failed') 'Clean fixture did not retain its turn.failed result.'
        }
        Invoke-P1BCase 'Inspect detects and masks normalized secret property names while preserving usage' {
            $fakeValue = 'FAKE_SECRET_VALUE'
            $secretNames = @('client_secret', 'dbPassword', 'github_token', 'x-api-key', 'ApiKey', 'access.token', 'userPwd', 'AWS_SECRET_ACCESS_KEY', 'private_key')
            $ordinaryNames = @('input_tokens', 'tokenizer', 'passive', 'username', 'keyword')
            foreach ($name in $secretNames) {
                Assert-P1B (Test-DispatchSecretJsonPropertyName -Name $name) ('Secret key was not detected: ' + $name)
                $secretProbe = [ordered]@{}
                $secretProbe[$name] = $fakeValue
                $protectedProbe = Protect-DispatchInspectResult -Result $secretProbe -SecretExposure ([ordered]@{ secret_exposure_suspected = $false; secret_exposure_findings = @() })
                Assert-P1B ([string]$protectedProbe[$name] -ceq '***') ('Secret key was not masked: ' + $name)
                Assert-P1B (-not (($protectedProbe | ConvertTo-Json -Depth 10 -Compress).Contains($fakeValue))) ('Masked secret output retained the fake value for key: ' + $name)
            }
            foreach ($name in $ordinaryNames) {
                Assert-P1B (-not (Test-DispatchSecretJsonPropertyName -Name $name)) ('Ordinary usage key was marked as secret: ' + $name)
                $ordinaryProbe = [ordered]@{}
                $ordinaryProbe[$name] = 'visible-value'
                $protectedProbe = Protect-DispatchInspectResult -Result $ordinaryProbe -SecretExposure ([ordered]@{ secret_exposure_suspected = $false; secret_exposure_findings = @() })
                Assert-P1B ([string]$protectedProbe[$name] -ceq 'visible-value') ('Ordinary key was masked: ' + $name)
            }

            $secretPayload = [ordered]@{}
            foreach ($name in $secretNames) { $secretPayload[$name] = $fakeValue }
            foreach ($name in $ordinaryNames) { $secretPayload[$name] = 'visible-value' }
            $finalMessage = ConvertTo-Json -InputObject @('design.md', 'dispatchSlug=__P1B_DISPATCH_SLUG__', 'lineSlug=p1b', $secretPayload) -Depth 10
            $fixture = New-P1BInspectFixture $finalMessage -TerminalEvent 'turn.completed'
            $finalMessage = $fixture.FinalMessage
            $threadEvent = Get-Content -LiteralPath $fixture.EventPath | Select-Object -First 1 | ConvertFrom-Json
            $usage = [ordered]@{
                input_tokens = 100
                cached_input_tokens = 25
                cache_write_input_tokens = 5
                output_tokens = 40
                reasoning_output_tokens = 10
                total_tokens = 140
            }
            $events = @(
                $threadEvent
                [ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'agent_message'; text = $finalMessage } }
                [ordered]@{ type = 'turn.completed'; usage = $usage }
            )
            Write-P1BText $fixture.EventPath (($events | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 15 -Compress }) -join [Environment]::NewLine)
            Write-P1BText $fixture.LastMessagePath $finalMessage

            $beforeUsage = (Get-Content -LiteralPath $fixture.EventPath | Select-Object -Last 1 | ConvertFrom-Json).usage
            $result = Invoke-Inspect
            $afterUsage = $result.usage
            Assert-P1B ($result.success -and $result.secret_exposure_suspected) 'Inspect did not retain success while detecting secret JSON properties.'
            Assert-P1B ($afterUsage -is [pscustomobject] -and (Test-UsageObject -Value $afterUsage)) 'Inspect changed the structured usage type.'
            $beforeProperties = @($beforeUsage.PSObject.Properties)
            $afterProperties = @($afterUsage.PSObject.Properties)
            Assert-P1B ($beforeProperties.Count -eq $afterProperties.Count) 'Inspect changed the usage property count.'
            for ($propertyIndex = 0; $propertyIndex -lt $beforeProperties.Count; $propertyIndex++) {
                Assert-P1B ($beforeProperties[$propertyIndex].Name -ceq $afterProperties[$propertyIndex].Name) ('Inspect changed usage key order or name at index ' + $propertyIndex)
                Assert-P1B ($beforeProperties[$propertyIndex].Value -ceq $afterProperties[$propertyIndex].Value -and $beforeProperties[$propertyIndex].Value.GetType() -eq $afterProperties[$propertyIndex].Value.GetType()) ('Inspect changed usage value or type for key: ' + $beforeProperties[$propertyIndex].Name)
            }
            $protectedMessage = ConvertFrom-Json -InputObject $result.finalMessage
            foreach ($name in $secretNames) { Assert-P1B ([string]$protectedMessage[3].$name -ceq '***') ('Inspect did not mask secret key in finalMessage: ' + $name) }
            foreach ($name in $ordinaryNames) { Assert-P1B ([string]$protectedMessage[3].$name -ceq 'visible-value') ('Inspect changed ordinary key in finalMessage: ' + $name) }
            Assert-P1B (-not (($result | ConvertTo-Json -Depth 30 -Compress).Contains($fakeValue))) 'Inspect output retained the fake secret value.'
        }
        Invoke-P1BCase 'Inspect detects and redacts secret-key JSON values in nested objects, arrays, event streams and last-message' {
            $fakeValue = 'FAKE_SECRET_VALUE'
            $jsonMessage = '{"secret":"' + $fakeValue + '","se_cret":"' + $fakeValue + '","password":"' + $fakeValue + '","pass_word":"' + $fakeValue + '","pass-word":"' + $fakeValue + '","passwd":"' + $fakeValue + '","pwd":"' + $fakeValue + '","token":"' + $fakeValue + '","api_key":"' + $fakeValue + '","apikey":"' + $fakeValue + '","api-key":"' + $fakeValue + '","client_secret":"' + $fakeValue + '","clientsecret":"' + $fakeValue + '","client-secret":"' + $fakeValue + '","connectionstring":"' + $fakeValue + '","connection_string":"' + $fakeValue + '","connection-string":"' + $fakeValue + '","safe_note":"visible"}'
            $fixture = New-P1BInspectFixture $jsonMessage
            $result = Invoke-Inspect
            $resultText = $result | ConvertTo-Json -Depth 30 -Compress
            $jsonFindings = @($result.secret_exposure_findings | Where-Object { $_.pattern -eq 'json-secret-property' })
            Assert-P1B ($result.secret_exposure_suspected -and $jsonFindings.Count -ge 2) 'Inspect did not detect JSON secret-property keys in both input files.'
            Assert-P1B (@($jsonFindings | Where-Object { $_.file -eq $fixture.EventPath -and $_.line -eq 2 }).Count -eq 1) 'Event-stream JSON secret location is missing or incorrect.'
            Assert-P1B (@($jsonFindings | Where-Object { $_.file -eq $fixture.LastMessagePath -and $_.line -eq 1 }).Count -eq 1) 'Last-message JSON secret location is missing or incorrect.'
            Assert-P1B (-not $resultText.Contains($fakeValue) -and $result.finalMessage.Contains('"client_secret":"***"') -and $result.finalMessage.Contains('"safe_note":"visible"')) 'Inspect did not redact JSON secret values while preserving ordinary keys.'

            $nestedResult = [ordered]@{
                eventStreamPath = $fixture.EventPath
                nested = [pscustomobject]@{
                    client_secret = $fakeValue
                    children = @([pscustomobject]@{ 'api-key' = $fakeValue; safe_note = 'visible' })
                }
                json_text = $jsonMessage
            }
            $protected = Protect-DispatchInspectResult -Result $nestedResult -SecretExposure ([ordered]@{ secret_exposure_suspected = $false; secret_exposure_findings = @() })
            Assert-P1B ($protected.nested.client_secret -eq '***' -and $protected.nested.children[0].'api-key' -eq '***' -and $protected.nested.children[0].safe_note -eq 'visible') 'Inspect output protection did not recurse through nested objects and arrays.'
            $protectedText = $protected | ConvertTo-Json -Depth 30 -Compress
            Assert-P1B (-not $protectedText.Contains($fakeValue) -and $protected.json_text.Contains('"connection-string":"***"')) 'Inspect text fields retained a secret JSON value.'
        }
        Invoke-P1BCase 'Inspect reports the actual line for a secret key in multiline last-message JSON' {
            $fakeValue = 'FAKE_SECRET_VALUE'
            $message = 'design.md dispatchSlug=__P1B_DISPATCH_SLUG__ lineSlug=p1b'
            $fixture = New-P1BInspectFixture $message
            $lastMessageJson = @(
                ''
                '{'
                ('  "client_secret": "' + $fakeValue + '",')
                '  "note": "visible"'
                '}'
            ) -join "`r`n"
            Write-P1BText $fixture.LastMessagePath $lastMessageJson
            $result = Invoke-Inspect
            $resultText = $result | ConvertTo-Json -Depth 30 -Compress
            $lastMessageFindings = @($result.secret_exposure_findings | Where-Object { $_.file -eq $fixture.LastMessagePath -and $_.pattern -eq 'json-secret-property' })
            Assert-P1B ($lastMessageFindings.Count -eq 1 -and $lastMessageFindings[0].line -eq 3) 'Multiline last-message secret finding did not report source line 3.'
            Assert-P1B (-not $resultText.Contains($fakeValue)) 'Inspect output disclosed the multiline last-message secret value.'
        }
        Invoke-P1BCase 'Inspect maps secret-key lines inside JSON array objects' {
            $fakeValue = 'FAKE_SECRET_VALUE'
            $fixture = New-P1BInspectFixture 'design.md dispatchSlug=__P1B_DISPATCH_SLUG__ lineSlug=p1b'
            $arrayJson = @(
                '{'
                '  "items": ['
                '    {'
                ('      "client_secret": "' + $fakeValue + '"')
                '    }'
                '  ]'
                '}'
            ) -join [Environment]::NewLine
            Write-P1BText $fixture.LastMessagePath $arrayJson
            $result = Invoke-Inspect
            $arrayFindings = @($result.secret_exposure_findings | Where-Object { $_.file -eq $fixture.LastMessagePath -and $_.pattern -eq 'json-secret-property' })
            Assert-P1B ($arrayFindings.Count -eq 1 -and $arrayFindings[0].line -eq 4) 'Array object secret finding did not report source line 4.'
            Assert-P1B (-not (($result | ConvertTo-Json -Depth 30 -Compress).Contains($fakeValue))) 'Array object Inspect output disclosed the fake secret value.'

            $duplicateFixture = New-P1BInspectFixture 'design.md dispatchSlug=__P1B_DISPATCH_SLUG__ lineSlug=p1b'
            $duplicateJson = @(
                '{'
                '  "items": ['
                '    {'
                ('      "client_secret": "' + $fakeValue + '"')
                '    },'
                '    {'
                ('      "client_secret": "' + $fakeValue + '"')
                '    }'
                '  ]'
                '}'
            ) -join [Environment]::NewLine
            Write-P1BText $duplicateFixture.LastMessagePath $duplicateJson
            $duplicateResult = Invoke-Inspect
            $duplicateFindings = @($duplicateResult.secret_exposure_findings | Where-Object { $_.file -eq $duplicateFixture.LastMessagePath -and $_.pattern -eq 'json-secret-property' })
            $duplicateLines = @($duplicateFindings | ForEach-Object { [int]$_.line })
            Assert-P1B ($duplicateLines.Count -eq 2 -and $duplicateLines[0] -eq 4 -and $duplicateLines[1] -eq 7) 'Array objects with duplicate secret keys did not report source lines 4 and 7.'
            Assert-P1B (-not (($duplicateResult | ConvertTo-Json -Depth 30 -Compress).Contains($fakeValue))) 'Duplicate array object Inspect output disclosed the fake secret value.'
        }
        Invoke-P1BCase 'Inspect isolates nested JSON string lines from the outer property lookup' {
            $fakeValue = 'FAKE_SECRET_VALUE'
            $fixture = New-P1BInspectFixture 'design.md dispatchSlug=__P1B_DISPATCH_SLUG__ lineSlug=p1b'
            $nestedJson = @(
                '{'
                '  "payload": "{\"password\":\"' + $fakeValue + '\"}",'
                '  "note": "visible",'
                '  "other": "visible",'
                ('  "password": "' + $fakeValue + '"')
                '}'
            ) -join [Environment]::NewLine
            Write-P1BText $fixture.LastMessagePath $nestedJson
            $result = Invoke-Inspect
            $findings = @($result.secret_exposure_findings | Where-Object { $_.file -eq $fixture.LastMessagePath -and $_.pattern -eq 'json-secret-property' })
            $lines = @($findings | ForEach-Object { [int]$_.line })
            Assert-P1B ($lines.Count -eq 2 -and $lines[0] -eq 2 -and $lines[1] -eq 5) 'Nested JSON string and outer password findings did not report source lines 2 and 5.'
            Assert-P1B (-not (($result | ConvertTo-Json -Depth 30 -Compress).Contains($fakeValue))) 'Nested JSON string Inspect output disclosed the fake secret value.'
        }

        Invoke-P1BCase 'Inspect sanitizes event and last-message failures without source content' {
            $fakeValue = 'FAKE_SECRET_VALUE'
            $fixture = New-P1BInspectFixture 'design.md dispatchSlug=__P1B_DISPATCH_SLUG__ lineSlug=p1b'
            $malformedLine = '{"type":"turn.failed","client_secret":"' + $fakeValue + '"'
            Write-P1BText $fixture.EventPath $malformedLine
            $stdoutPath = Join-Path $fixture.Fixture.Dispatch 'inspect-stdout.txt'
            $stderrPath = Join-Path $fixture.Fixture.Dispatch 'inspect-stderr.txt'
            Write-P1BText $stdoutPath ''
            Write-P1BText $stderrPath ''
            $exceptionMessage = ''
            $failure = $null
            $innerException = $null
            try { $null = Invoke-Inspect 1> $stdoutPath 2> $stderrPath }
            catch {
                $exceptionMessage = $_.Exception.Message
                $innerException = $_.Exception.InnerException
                $failure = $_.Exception.Data['operationResult']
            }
            $failureKeys = if ($null -eq $failure) { @() } else { @($failure.Keys) }
            Assert-P1B ($null -ne $failure -and [string]$failure.errorCode -ceq 'InspectJsonParseFailed' -and [string]$failure.file -ceq $fixture.EventPath -and $failure.line -eq 1 -and $failure.line -is [int]) 'Malformed JSON did not produce the fixed Inspect failure object.'
            Assert-P1B ($failureKeys.Count -eq 3 -and $failureKeys -contains 'errorCode' -and $failureKeys -contains 'file' -and $failureKeys -contains 'line') 'Failure object contained fields beyond the fixed code, file path and line number.'
            Assert-P1B ($exceptionMessage -ceq ('InspectJsonParseFailed: file=' + $fixture.EventPath + '; line=1')) 'Malformed JSON exception message contains unexpected parser details.'
            Assert-P1B ($null -eq $innerException) 'Malformed JSON failure retained the original parser exception.'
            $failureText = $failure | ConvertTo-Json -Depth 30 -Compress
            $reportedText = $exceptionMessage + [Environment]::NewLine + $failureText + [IO.File]::ReadAllText($stdoutPath) + [IO.File]::ReadAllText($stderrPath)
            Assert-P1B (-not $reportedText.Contains($fakeValue) -and -not $reportedText.Contains('"client_secret"')) 'Inspect failure output or report content disclosed malformed source text.'

            $lastMessageFixture = New-P1BInspectFixture 'design.md dispatchSlug=__P1B_DISPATCH_SLUG__ lineSlug=p1b'
            Write-P1BText $lastMessageFixture.LastMessagePath ('{"password":"' + $fakeValue + '"')
            $lastMessageStdoutPath = Join-Path $lastMessageFixture.Fixture.Dispatch 'inspect-stdout.txt'
            $lastMessageStderrPath = Join-Path $lastMessageFixture.Fixture.Dispatch 'inspect-stderr.txt'
            Write-P1BText $lastMessageStdoutPath ''
            Write-P1BText $lastMessageStderrPath ''
            $lastMessageResult = $null
            $lastMessageException = ''
            try { $lastMessageResult = Invoke-Inspect 2> $lastMessageStderrPath }
            catch { $lastMessageException = $_.Exception.Message }
            $lastMessageResultText = if ($null -eq $lastMessageResult) { '' } else { $lastMessageResult | ConvertTo-Json -Depth 30 -Compress }
            $lastMessageReportedText = $lastMessageResultText + $lastMessageException + [IO.File]::ReadAllText($lastMessageStdoutPath) + [IO.File]::ReadAllText($lastMessageStderrPath)
            Assert-P1B (-not $lastMessageReportedText.Contains($fakeValue)) 'Inspect output or report disclosed malformed last-message source text.'

        }
        Invoke-P1BCase 'Inspect output protection preserves structured usage type' {
            $usage = [pscustomobject]@{ input_tokens = 1; output_tokens = 1 }
            $result = Protect-DispatchInspectResult -Result ([ordered]@{ usage = $usage }) -SecretExposure ([ordered]@{ secret_exposure_suspected = $false; secret_exposure_findings = @() })
            Assert-P1B ($result.usage -is [pscustomobject] -and (Test-UsageObject -Value $result.usage)) 'Inspect output protection changed the structured usage type.'
        }
    }
    if ($Unit -in @('D6','All')) {
        Invoke-P1BCase 'Inspect marks changed files for usage-limit and capacity turn.failed events' {
            foreach ($failureReason in @('usage-limit', 'Selected model is at capacity')) {
                $inspectFixture = New-P1BInspectFixture 'design.md dispatchSlug=__P1B_DISPATCH_SLUG__ lineSlug=p1b' -FailureReason $failureReason
                Write-P1BText (Join-Path $inspectFixture.Fixture.Dispatch 'README.md') 'partial worktree artifact'
                $result = Invoke-Inspect
                Assert-P1B (-not $result.success) ('turn.failed success changed for reason: ' + $failureReason)
                Assert-P1B ($result.recoverable_artifacts_present -and @($result.recoverable_artifact_files) -contains 'README.md') ('Inspect omitted the changed worktree file for reason: ' + $failureReason)
            }
        }
        Invoke-P1BCase 'Inspect reports no recoverable files when turn.failed leaves worktree unchanged' {
            $null = New-P1BInspectFixture 'design.md dispatchSlug=__P1B_DISPATCH_SLUG__ lineSlug=p1b' -FailureReason 'usage-limit'
            $result = Invoke-Inspect
            Assert-P1B (-not $result.success -and $result.lastEventType -eq 'turn.failed') 'Inspect changed turn.failed success state.'
            Assert-P1B (-not $result.recoverable_artifacts_present -and @($result.recoverable_artifact_files).Count -eq 0) 'Inspect reported files when the worktree has no baseSha changes.'
        }
        Invoke-P1BCase 'Recoverable artifact scan tolerates legacy RunRecord without baseline binding' {
            $fixture = New-P1BInspectFixture 'design.md dispatchSlug=__P1B_DISPATCH_SLUG__ lineSlug=p1b' -FailureReason 'usage-limit'
            $record = [pscustomobject]@{ event_stream_path = $fixture.EventPath }
            $state = Get-DispatchRecoverableArtifactState -RunRecord $record
            Assert-P1B ($state.applicable -and -not $state.recoverable_artifacts_present -and @($state.recoverable_artifact_files).Count -eq 0) 'Missing baseline did not return empty recovery evidence fields.'
        }
        Invoke-P1BCase 'Collect returns recovery evidence when turn.failed has no conclusion report' {
            $inspectFixture = New-P1BInspectFixture 'design.md dispatchSlug=__P1B_DISPATCH_SLUG__ lineSlug=p1b' -FailureReason 'usage-limit'
            $fixture = $inspectFixture.Fixture
            Write-P1BText (Join-Path $fixture.Dispatch 'README.md') 'partial collect artifact'
            $script:ReportPath = @((Join-Path $fixture.Dispatch '.local\ai-sessions\report\p1b\missing-closure.md'))
            $script:DispatchKind = 'workflow'
            $collectFailure = $null
            try {
                $null = Invoke-Collect
            }
            catch {
                $collectFailure = $_.Exception.Data['operationResult']
            }
            Assert-P1B ($null -ne $collectFailure -and $collectFailure.status -eq 'failed' -and -not $collectFailure.outputValid) 'Collect did not return its failed operation result for a missing conclusion report.'
            Assert-P1B ($collectFailure.recoverable_artifacts_present -and @($collectFailure.recoverable_artifact_files) -contains 'README.md') 'Collect recovery result omitted the changed worktree file.'
        }
        Invoke-P1BCase 'Collect reports no recoverable files when failed worktree has no changes' {
            $inspectFixture = New-P1BInspectFixture 'design.md dispatchSlug=__P1B_DISPATCH_SLUG__ lineSlug=p1b' -FailureReason 'Selected model is at capacity'
            $fixture = $inspectFixture.Fixture
            $script:ReportPath = @((Join-Path $fixture.Dispatch '.local\ai-sessions\report\p1b\missing-closure.md'))
            $script:DispatchKind = 'workflow'
            $collectFailure = $null
            try {
                $null = Invoke-Collect
            }
            catch {
                $collectFailure = $_.Exception.Data['operationResult']
            }
            Assert-P1B ($null -ne $collectFailure -and -not $collectFailure.outputValid) 'Collect did not reject the missing conclusion report.'
            Assert-P1B (-not $collectFailure.recoverable_artifacts_present -and @($collectFailure.recoverable_artifact_files).Count -eq 0) 'Collect reported files when the worktree has no baseSha changes.'
        }
    }    if ($Unit -in @('D5','All')) {
        Invoke-P1BCase 'Dispatch order Markdown bullets strip one backtick layer for target matching' {
            $fixture = New-P1BFixture -DeferPreflight
            $targetPath = Join-Path $fixture.Source 'requested-target.md'
            $mark = [char]96
            $orderPath = Join-Path $fixture.Source ('.local\ai-sessions\handoff\dispatch-order-' + $fixture.Slug + '.md')
            $orderContent = @(
                '## 3. 目標物件'
                ''
                ('- ' + $mark + $targetPath + $mark)
                ''
                '## 4. 任務內容'
                'fixture'
                '## 5. 驗收條件'
                'fixture'
            ) -join "`r`n"
            Write-P1BText $orderPath $orderContent
            $order = Read-DispatchOrderSections -Path $orderPath
            Assert-P1B ((Compare-DispatchStringArrays -Left @($targetPath) -Right @($order.Targets)) -and $order.TargetDetails[0].Path -eq $targetPath -and $order.TargetDetails[0].LineNumber -eq 3) 'Markdown target bullet did not normalize to the requested target and preserve source line number.'
        }
        Invoke-P1BCase 'Dispatch order text code block remains accepted' {
            $fixture = New-P1BFixture -DeferPreflight
            $targetPath = Join-Path $fixture.Source 'text-target.md'
            $orderPath = Join-Path $fixture.Source ('.local\ai-sessions\handoff\dispatch-order-' + $fixture.Slug + '.md')
            $orderContent = @(
                '## 3. 目標物件'
                ''
                '```text'
                $targetPath
                '```'
                '## 4. 任務內容'
                'fixture'
                '## 5. 驗收條件'
                'fixture'
            ) -join "`r`n"
            Write-P1BText $orderPath $orderContent
            $order = Read-DispatchOrderSections -Path $orderPath
            Assert-P1B ($order.Targets.Count -eq 1 -and $order.Targets[0] -eq $targetPath) 'Text code block target was not parsed.'
        }
        Invoke-P1BCase 'Malformed dispatch order format reports normalized path and original line' {
            $fixture = New-P1BFixture -DeferPreflight
            $targetPath = Join-Path $fixture.Source 'invalid-target.md'
            $mark = [char]96
            $orderPath = Join-Path $fixture.Source ('.local\ai-sessions\handoff\dispatch-order-' + $fixture.Slug + '.md')
            $orderContent = @(
                '## 3. 目標物件'
                ''
                ('* ' + $mark + $targetPath + $mark)
                '## 4. 任務內容'
                'fixture'
                '## 5. 驗收條件'
                'fixture'
            ) -join "`r`n"
            Write-P1BText $orderPath $orderContent
            $failureMessage = ''
            try { $null = Read-DispatchOrderSections -Path $orderPath }
            catch { $failureMessage = $_.Exception.Message }
            Assert-P1B ($failureMessage.Contains($targetPath) -and $failureMessage.Contains('原始行號=3')) ('Format error omitted the normalized path or original line: ' + $failureMessage)
        }
    }
    if ($Unit -in @('D4','All')) {
        Invoke-P1BCase 'Collect rejects exact file target changed to a directory' {
            $fixture = New-P1BFixture -TargetPathRelative @('README.md', 'outputs')
            $targetState = @($fixture.Preflight.targetStates | Where-Object { $_.InputPath -eq $script:TargetPath[1] })[0]
            Assert-P1B ($targetState.TargetKind -eq 'file') 'Missing exact target was not recorded as a file.'
            Register-P1BOwner $fixture
            Write-P1BText (Join-Path $fixture.Dispatch 'outputs\child.txt') 'child payload'
            Set-P1BWorkflowCollectInputs -Fixture $fixture -Paths @('outputs/child.txt')
            $script:DispatchKind = 'workflow'
            $rejected = $false
            try { $null = Invoke-Collect -ApplyCollectedChanges }
            catch { $rejected = $_.Exception.Message -match 'CollectTargetKindChanged' }
            Assert-P1B ($rejected -and -not [IO.File]::Exists((Join-Path $fixture.Source 'outputs\child.txt'))) 'Collect accepted child files under an exact file target that became a directory.'
        }
        Invoke-P1BCase 'Legacy absent exact target without TargetKind rejects a dispatch-created directory' {
            $fixture = New-P1BFixture -TargetPathRelative @('README.md', 'outputs')
            $preflightText = [IO.File]::ReadAllText($script:PreflightResultPath, [Text.Encoding]::UTF8)
            $oldPreflight = ConvertFrom-DispatchJson -Content $preflightText
            foreach ($state in @($oldPreflight.targetStates)) {
                $targetKindProperty = $state.PSObject.Properties['TargetKind']
                if ($null -ne $targetKindProperty) { $state.PSObject.Properties.Remove('TargetKind') }
            }
            Write-P1BText $script:PreflightResultPath ($oldPreflight | ConvertTo-Json -Depth 30)
            $legacyPreflightText = [IO.File]::ReadAllText($script:PreflightResultPath, [Text.Encoding]::UTF8)
            Register-P1BOwner $fixture
            Write-P1BText (Join-Path $fixture.Dispatch 'outputs\child.txt') 'legacy child payload'
            Set-P1BWorkflowCollectInputs -Fixture $fixture -Paths @('outputs/child.txt')
            $script:DispatchKind = 'workflow'
            $rejected = $false
            try { $null = Invoke-Collect -ApplyCollectedChanges }
            catch { $rejected = $_.Exception.Message -match 'CollectTargetKindChanged' }
            Assert-P1B ($rejected -and -not [IO.Directory]::Exists((Join-Path $fixture.Source 'outputs')) -and -not [IO.File]::Exists((Join-Path $fixture.Source 'outputs\child.txt'))) 'Collect applied a child beneath a missing legacy target interpreted as a directory.'
            Assert-P1B ([IO.File]::ReadAllText($script:PreflightResultPath, [Text.Encoding]::UTF8) -ceq $legacyPreflightText -and [IO.File]::ReadAllText((Join-Path $fixture.Source 'README.md')) -ceq 'fixture') 'Collect changed the legacy Preflight result or source files after rejecting the target kind change.'
        }
        Invoke-P1BCase 'Collect normalizes nested Windows target separators before kind checks' {
            $fixture = New-P1BFixture -TargetPathRelative @('scripts\Invoke-CodexDispatch.ps1', 'outputs\') -InitialTrackedFiles @('scripts\Invoke-CodexDispatch.ps1')
            $nestedTargetState = @($fixture.Preflight.targetStates | Where-Object { $_.InputPath -eq $script:TargetPath[0] })[0]
            Assert-P1B ($nestedTargetState.TargetKind -eq 'file') 'Nested absent target was not recorded as an exact file.'
            Register-P1BOwner $fixture
            Write-P1BText (Join-Path $fixture.Dispatch 'outputs\child.txt') 'nested path child'
            Set-P1BWorkflowCollectInputs -Fixture $fixture -Paths @('outputs/child.txt')
            $script:DispatchKind = 'workflow'
            $result = Invoke-Collect -ApplyCollectedChanges
            Assert-P1B ($result.status -eq 'collected' -and [IO.File]::ReadAllText((Join-Path $fixture.Source 'outputs\child.txt')) -eq 'nested path child') 'Collect failed to normalize nested Windows separators in a Preflight target path.'
        }
        Invoke-P1BCase 'Trailing separator declares an absent directory target and allows child files' {
            $fixture = New-P1BFixture -TargetPathRelative @('README.md', 'outputs\')
            $targetState = @($fixture.Preflight.targetStates | Where-Object { $_.InputPath -eq $script:TargetPath[1] })[0]
            Assert-P1B ($targetState.TargetKind -eq 'directory') 'Trailing separator did not declare the absent target as a directory.'
            Register-P1BOwner $fixture
            Write-P1BText (Join-Path $fixture.Dispatch 'outputs\child.txt') 'child payload'
            Set-P1BWorkflowCollectInputs -Fixture $fixture -Paths @('outputs/child.txt')
            $script:DispatchKind = 'workflow'
            $result = Invoke-Collect -ApplyCollectedChanges
            Assert-P1B ($result.status -eq 'collected' -and $result.sourceIntegration.status -eq 'applied' -and [IO.File]::ReadAllText((Join-Path $fixture.Source 'outputs\child.txt')) -eq 'child payload') 'Collect did not apply a child under a trailing-separator directory target.'
        }
        Invoke-P1BCase 'Legacy Preflight missing TargetKind treats trailing-separator target as an exact file' {
            $fixture = New-P1BFixture -TargetPathRelative @('README.md', 'outputs\')
            $oldPreflight = ConvertFrom-DispatchJson -Content ([IO.File]::ReadAllText($script:PreflightResultPath, [Text.Encoding]::UTF8))
            foreach ($state in @($oldPreflight.targetStates)) {
                $targetKindProperty = $state.PSObject.Properties['TargetKind']
                if ($null -ne $targetKindProperty) { $state.PSObject.Properties.Remove('TargetKind') }
            }
            Write-P1BText $script:PreflightResultPath ($oldPreflight | ConvertTo-Json -Depth 30)
            $legacyPreflightText = [IO.File]::ReadAllText($script:PreflightResultPath, [Text.Encoding]::UTF8)
            Register-P1BOwner $fixture
            Write-P1BText (Join-Path $fixture.Dispatch 'outputs\child.txt') 'legacy child payload'
            Set-P1BWorkflowCollectInputs -Fixture $fixture -Paths @('outputs/child.txt')
            $script:DispatchKind = 'workflow'
            $resolution = Resolve-CollectTargetStates -TargetStates @($oldPreflight.targetStates) -SourceRoot $fixture.Source -DispatchRoot $fixture.Dispatch
            $resolvedTarget = @($resolution.targetStates | Where-Object { $_.FullPath -eq $script:TargetPath[1] })[0]
            Assert-P1B ($resolution.kind_source -eq 'inferred' -and $resolvedTarget.TargetKind -eq 'file' -and $resolvedTarget.kind_source -eq 'inferred' -and @($resolution.kindChangedPaths).Count -eq 1) 'Collect did not treat the absent legacy target as an inferred exact file.'
            $rejected = $false
            try { $null = Invoke-Collect -ApplyCollectedChanges }
            catch { $rejected = $_.Exception.Message -match 'CollectTargetKindChanged' }
            Assert-P1B ($rejected -and -not [IO.Directory]::Exists((Join-Path $fixture.Source 'outputs')) -and -not [IO.File]::Exists((Join-Path $fixture.Source 'outputs\child.txt'))) 'Collect accepted a directory under an absent legacy target with a trailing separator.'
            Assert-P1B ([IO.File]::ReadAllText($script:PreflightResultPath, [Text.Encoding]::UTF8) -ceq $legacyPreflightText -and [IO.File]::ReadAllText((Join-Path $fixture.Source 'README.md')) -ceq 'fixture') 'Collect changed the legacy Preflight result or source files after rejecting the target kind change.'
        }
        Invoke-P1BCase 'Collect rejects Preflight directory target changed to a file' {
            $fixture = New-P1BFixture -TargetPathRelative @('README.md', 'outputs') -InitialTrackedFiles @('outputs/baseline.txt')
            $targetState = @($fixture.Preflight.targetStates | Where-Object { $_.InputPath -eq $script:TargetPath[1] })[0]
            Assert-P1B ($targetState.TargetKind -eq 'directory') 'Existing directory target was not recorded as a directory.'
            $preflightText = [IO.File]::ReadAllText($script:PreflightResultPath, [Text.Encoding]::UTF8)
            Register-P1BOwner $fixture
            $dispatchTargetPath = Join-Path $fixture.Dispatch 'outputs'
            Remove-Item -LiteralPath $dispatchTargetPath -Recurse -Force
            Write-P1BText $dispatchTargetPath 'replacement file payload'
            Set-P1BWorkflowCollectInputs -Fixture $fixture -Paths @('outputs/baseline.txt')
            $script:DispatchKind = 'workflow'
            $rejected = $false
            try { $null = Invoke-Collect -ApplyCollectedChanges }
            catch { $rejected = $_.Exception.Message -match 'CollectTargetKindChanged' }
            Assert-P1B ($rejected -and [IO.Directory]::Exists((Join-Path $fixture.Source 'outputs')) -and [IO.File]::ReadAllText((Join-Path $fixture.Source 'outputs\baseline.txt')) -ceq 'baseline:outputs/baseline.txt' -and -not [IO.File]::Exists((Join-Path $fixture.Source 'outputs'))) 'Collect accepted a directory target replaced by a file or changed the source directory.'
            Assert-P1B ([IO.File]::ReadAllText($script:PreflightResultPath, [Text.Encoding]::UTF8) -ceq $preflightText) 'Collect changed the Preflight result after rejecting the target kind change.'
        }
    }
    if ($Unit -in @('D3','All')) {
        Invoke-P1BCase 'Readonly Preflight lists ignored source report and Start prompt directs direct reads' {
            $fixture = New-P1BFixture -TargetPathRelative @('.local\ai-sessions\report\p1b\review-report.md') -DeferPreflight
            $sourceReportPath = [string]$script:TargetPath[0]
            Write-P1BText -Path $sourceReportPath -Text 'ignored report fixture'
            $script:WriteMode = 'readonly'
            $preflight = Invoke-Preflight
            $outsideTargets = @($preflight.targetsOutsideRepository)
            Assert-P1B ($preflight.worktreeCreated -and $outsideTargets.Count -eq 1 -and $outsideTargets[0] -eq $sourceReportPath) ('Readonly Preflight did not identify the ignored source report: ' + ($outsideTargets -join ', '))

            $directive = New-TargetsOutsideRepositoryPromptDirective -Preflight $preflight
            Assert-P1B ($directive.Contains($sourceReportPath) -and $directive.Contains('直接讀取') -and $directive.Contains('不經 Git 狀態盤點')) ('Start prompt directive omitted the target or direct-read instruction: ' + $directive)
        }
        Invoke-P1BCase 'Readonly directory target batches ignore checks once for 200 files and matches per-file results' {
            $childRelativePaths = New-Object 'System.Collections.Generic.List[string]'
            $ignorePatterns = New-Object 'System.Collections.Generic.List[string]'
            for ($fileIndex = 0; $fileIndex -lt 200; $fileIndex++) {
                $relativeChildPath = 'outputs/child-{0:D3}.txt' -f $fileIndex
                $childRelativePaths.Add($relativeChildPath)
                if (($fileIndex % 2) -eq 0) { $ignorePatterns.Add($relativeChildPath) }
            }
            $fixture = New-P1BFixture -TargetPathRelative @('outputs') -InitialTrackedFiles @('outputs/tracked.txt') -AdditionalIgnore $ignorePatterns.ToArray() -DeferPreflight
            foreach ($relativeChildPath in $childRelativePaths) {
                Write-P1BText (Join-Path $fixture.Source $relativeChildPath.Replace('/', '\')) 'ignored child fixture'
            }
            $script:WriteMode = 'write'
            $setupPreflight = Invoke-Preflight
            Assert-P1B ($setupPreflight.worktreeCreated -and $setupPreflight.writeMode -eq 'write') 'Write-mode setup did not create the dispatch worktree for the focused ignore check.'
            $script:WriteMode = 'readonly'
            $originalGitCommand = (Get-Item Function:\Invoke-GitCommand).ScriptBlock
            $candidatePaths = @('outputs', 'outputs/tracked.txt') + @($childRelativePaths.ToArray())
            $expectedIgnoredPaths = New-Object 'System.Collections.Generic.List[string]'
            foreach ($relativePath in $candidatePaths) {
                $perFileResult = & $originalGitCommand -WorkingDirectory $fixture.Source -Arguments @('check-ignore', '--quiet', '--no-index', '--', $relativePath) -AllowFailure
                if ($perFileResult.ExitCode -eq 0) {
                    $expectedIgnoredPaths.Add($relativePath)
                }
                elseif ($perFileResult.ExitCode -ne 1 -or -not [string]::IsNullOrWhiteSpace($perFileResult.StdErr)) {
                    throw ('Per-file git check-ignore baseline failed for ' + $relativePath + ': ' + $perFileResult.StdErr)
                }
            }

            $script:G5OriginalInvokeGitCommand = $originalGitCommand
            $checkIgnoreCalls = New-Object 'System.Collections.Generic.List[string]'
            $instrumentedGitCommand = {
                param(
                    [Parameter(Mandatory)][string]$WorkingDirectory,
                    [Parameter(Mandatory)][string[]]$Arguments,
                    [AllowEmptyString()][string]$StandardInput,
                    [switch]$AllowFailure
                )
                if ($Arguments.Count -gt 0 -and $Arguments[0] -eq 'check-ignore') { $checkIgnoreCalls.Add(($Arguments -join ' ')) }
                $forwardParameters = @{ WorkingDirectory = $WorkingDirectory; Arguments = $Arguments }
                if ($null -ne $StandardInput) { $forwardParameters.StandardInput = $StandardInput }
                if ($AllowFailure) { $forwardParameters.AllowFailure = $true }
                return & $script:G5OriginalInvokeGitCommand @forwardParameters
            }
            Set-Item -Path Function:\script:Invoke-GitCommand -Value $instrumentedGitCommand
            try {
                $outsideTargets = @(Get-TargetsOutsideRepository -SourceRoot $fixture.Source -DispatchRoot $fixture.Dispatch -TargetPath @($script:TargetPath))
            }
            finally {
                $checkIgnoreInvocationCount = $checkIgnoreCalls.Count
                Set-Item -Path Function:\script:Invoke-GitCommand -Value $originalGitCommand
                Remove-Variable -Name G5OriginalInvokeGitCommand -Scope Script -ErrorAction SilentlyContinue
            }
            $actualRelativePaths = @($outsideTargets | ForEach-Object {
                (Get-RelativePathFromRoot -Path $_ -Root $fixture.Source).Replace([string][char]92, [string][char]47)
            } | Sort-Object -CaseSensitive)
            $expectedSortedPaths = @($expectedIgnoredPaths.ToArray() | Sort-Object -CaseSensitive)
            $actualText = [string]::Join([string][char]10, [string[]]$actualRelativePaths)
            $expectedText = [string]::Join([string][char]10, [string[]]$expectedSortedPaths)
            $singleIgnoredPath = 'outputs/child-000.txt'
            $singleRegularPath = 'outputs/child-001.txt'
            $singleIgnoredLookup = Get-DispatchIgnoredPathLookup -DispatchRoot $fixture.Dispatch -GitRelativePath @($singleIgnoredPath) -SourcePath @(Join-Path $fixture.Source $singleIgnoredPath.Replace('/', '\'))
            $singleRegularLookup = Get-DispatchIgnoredPathLookup -DispatchRoot $fixture.Dispatch -GitRelativePath @($singleRegularPath) -SourcePath @(Join-Path $fixture.Source $singleRegularPath.Replace('/', '\'))
            $mixedLookup = Get-DispatchIgnoredPathLookup -DispatchRoot $fixture.Dispatch -GitRelativePath @($singleIgnoredPath, $singleRegularPath) -SourcePath @((Join-Path $fixture.Source $singleIgnoredPath.Replace('/', '\')), (Join-Path $fixture.Source $singleRegularPath.Replace('/', '\')))
            Assert-P1B ($checkIgnoreInvocationCount -eq 1) ('Readonly directory target started git check-ignore ' + $checkIgnoreInvocationCount + ' times instead of once.')
            Assert-P1B ($expectedIgnoredPaths.Count -eq 100 -and $actualText -ceq $expectedText) 'Batched git check-ignore results differ from the per-file baseline.'
            Assert-P1B ($outsideTargets -notcontains [string]$script:TargetPath[0] -and $outsideTargets -notcontains (Join-Path $fixture.Source 'outputs\tracked.txt')) 'Readonly Preflight listed the directory target or tracked child instead of ignored files.'
            Assert-P1B ($singleIgnoredLookup.ContainsKey($singleIgnoredPath) -and -not $singleRegularLookup.ContainsKey($singleRegularPath)) 'Single-target ignore checks did not distinguish ignored and ordinary files.'
            Assert-P1B ($mixedLookup.Count -eq 1 -and $mixedLookup.ContainsKey($singleIgnoredPath) -and -not $mixedLookup.ContainsKey($singleRegularPath)) 'Multi-target ignore checks did not match the per-file results.'
            $sampleIgnoredChildPath = Join-Path $fixture.Source 'outputs\child-000.txt'
            $directive = New-TargetsOutsideRepositoryPromptDirective -Preflight ([pscustomobject]@{ targetsOutsideRepository = @($outsideTargets) })
            Assert-P1B ($directive.Contains($sampleIgnoredChildPath) -and $directive.Contains('直接讀取') -and $directive.Contains('不經 Git 狀態盤點')) 'Start prompt directive omitted an ignored descendant file or direct-read instruction.'
        }
    }
    if ($Unit -in @('D7','All')) {
        Invoke-P1BCase 'Dispatch skill documents D1-D6 contracts' {
            $skillPath = Join-Path (Split-Path $scriptsRoot -Parent) 'skills\codex-dispatch\SKILL.md'
            $skillText = [IO.File]::ReadAllText($skillPath, [Text.Encoding]::UTF8)
            $requiredTerms = @(
                'excludedSecrets', '.env.*', '*.pfx', '*.pem', '*.key', 'secrets.*', 'PreflightSecretTargetRejected',
                'secret_exposure_suspected', 'secret_exposure_findings', '壞行只留在原始事件流，不複製到 stdout、stderr、結果 JSON、診斷物件或報告', '移除連字號、底線、句點與空白', 'connectionstring', 'privatekey', 'PRIVATE KEY', 'Password=', 'Pwd=', 'AKIA', 'sk-',
                'targetsOutsideRepository', '不經 Git 狀態盤點', 'targetStates', 'CollectTargetKindChanged', 'kind_source=inferred',
                'Markdown 條列', '原始行號', 'recoverable_artifacts_present', 'recoverable_artifact_files', 'turn.failed', 'baseSha'
            )
            foreach ($term in $requiredTerms) { Assert-P1B ($skillText.Contains($term)) ('Dispatch skill omits required compatibility text: ' + $term) }
            Assert-P1B (-not $skillText.Contains('保存原文與行號，繼續解析其餘事件')) 'Dispatch skill still says malformed event lines are preserved in results and parsing continues.'
            Assert-P1B (-not $skillText.Contains('失敗原因取 `turn.failed.error.message`')) 'Dispatch skill still says Inspect returns the raw turn.failed error message.'
        }
    }
}
Test-P1BFixturePathGuard
Write-P1BText (Join-Path $root 'results.json') ($script:Results.ToArray() | ConvertTo-Json -Depth 12)
Write-Output ('EVIDENCE_ROOT: ' + $root)
Write-Output ('PASSED: ' + @($script:Results | Where-Object { $_.status -eq 'PASS' }).Count)
$failed = @($script:Results | Where-Object { $_.status -eq 'FAIL' }).Count
Write-Output ('FAILED: ' + $failed)
if ($failed -gt 0) { exit 1 }
exit 0
