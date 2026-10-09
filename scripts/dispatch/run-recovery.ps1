function Get-DispatchEventEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EventPath
    )

    $resolvedPath = Resolve-AbsolutePath -Path $EventPath
    if (-not [System.IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $resolvedPath))) {
        return [ordered]@{
            path = $resolvedPath
            exists = $false
            sha256 = $null
            event_state = 'not-started'
            last_event_type = $null
            raw_lines = [string[]]@()
            usage_limit = $false
        }
    }

    $rawLines = @((Read-DispatchUtf8Text -Path $resolvedPath) -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $events = New-Object 'System.Collections.Generic.List[object]'
    $usageLimitEvidence = New-Object 'System.Collections.Generic.List[object]'
    $usageLimit = $false
    $errorTypes = @('error', 'turn.failed', 'turn_failed', 'stream_error', 'turn_aborted')
    $usageLimitPattern = '(?i)usage[\s_-]*limit(?:ed|[\s_-]*(?:reached|exceeded)|\b)'
    $rateLimitPattern = '(?i)rate[\s_-]*limit(?:ed|[\s_-]*(?:reached|exceeded)|\b)'
    $quotaExceededPattern = '(?i)quota[\s_-]+exceeded'
    $tooManyRequestsPattern = '(?i)too[\s_-]+many[\s_-]+requests|\b429\b'
    foreach ($rawLine in $rawLines) {
        try {
            $event = ConvertFrom-DispatchJson -Content $rawLine
            $null = $events.Add($event)
        }
        catch {
            continue
        }

        $payload = Get-DispatchJsonProperty -Object $event -Name 'payload'
        if ($null -eq $payload) {
            $payload = Get-DispatchJsonProperty -Object $event -Name 'data'
        }
        $recordType = [string](Get-DispatchJsonProperty -Object $event -Name 'type')
        $payloadType = [string](Get-DispatchJsonProperty -Object $payload -Name 'type')
        $isErrorEvent = $errorTypes -contains $recordType -or $errorTypes -contains $payloadType
        $rateLimits = Get-DispatchJsonProperty -Object $payload -Name 'rate_limits'
        if ($null -eq $rateLimits) {
            $rateLimits = Get-DispatchJsonProperty -Object $payload -Name 'rateLimits'
        }
        if ($null -eq $rateLimits) {
            $rateLimits = Get-DispatchJsonProperty -Object $event -Name 'rate_limits'
        }
        if ($null -eq $rateLimits) {
            $rateLimits = Get-DispatchJsonProperty -Object $event -Name 'rateLimits'
        }
        $reachedType = [string](Get-DispatchJsonProperty -Object $rateLimits -Name 'rate_limit_reached_type')
        if ([string]::IsNullOrWhiteSpace($reachedType)) {
            $reachedType = [string](Get-DispatchJsonProperty -Object $rateLimits -Name 'rateLimitReachedType')
        }
        if (-not $isErrorEvent -and [string]::IsNullOrWhiteSpace($reachedType)) {
            continue
        }

        $messageParts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($source in @($event, $payload)) {
            foreach ($name in @('message', 'reason', 'code')) {
                $value = Get-DispatchJsonProperty -Object $source -Name $name
                if ($null -ne $value) {
                    $messageParts.Add([string]$value)
                }
            }
            $errorObject = Get-DispatchJsonProperty -Object $source -Name 'error'
            if ($errorObject -is [string]) {
                $messageParts.Add($errorObject)
            }
            elseif ($null -ne $errorObject) {
                foreach ($name in @('message', 'reason', 'code', 'type')) {
                    $value = Get-DispatchJsonProperty -Object $errorObject -Name $name
                    if ($null -ne $value) {
                        $messageParts.Add([string]$value)
                    }
                }
            }
        }

        $messageText = $messageParts -join ' '
        $matchReasonCode = $null
        if ($messageText -match $usageLimitPattern) {
            $matchReasonCode = 'usage-limit'
        }
        elseif ($messageText -match $rateLimitPattern) {
            $matchReasonCode = 'rate-limit'
        }
        elseif ($messageText -match $quotaExceededPattern) {
            $matchReasonCode = 'quota-exceeded'
        }
        elseif ($messageText -match $tooManyRequestsPattern) {
            $matchReasonCode = 'too-many-requests'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($reachedType)) {
            $matchReasonCode = 'rate-limit'
        }
        if ($null -ne $matchReasonCode) {
            $timestampValue = Get-DispatchJsonProperty -Object $event -Name 'timestamp'
            if ($null -eq $timestampValue) {
                $timestampValue = Get-DispatchJsonProperty -Object $event -Name 'created_at'
            }
            $usageLimit = $true
            $null = $usageLimitEvidence.Add([ordered]@{
                    reason_code = $matchReasonCode
                    observed_at = if ($null -eq $timestampValue) { $null } else { [string]$timestampValue }
                    raw_line = $rawLine
                })
        }
    }
    $lastType = $null
    if ($events.Count -gt 0) {
        $lastType = [string](Get-DispatchJsonProperty -Object $events[$events.Count - 1] -Name 'type')
    }
    $state = 'unknown'
    if ($usageLimit) {
        $state = 'quota-rejected'
    }
    elseif ($lastType -eq 'turn.completed') {
        $state = 'completed'
    }
    elseif ($lastType -eq 'turn.failed') {
        $state = 'launch-failed'
    }
    elseif ($lastType -eq 'turn.started') {
        $state = 'unknown'
    }
    return [ordered]@{
        path = $resolvedPath
        exists = $true
        sha256 = Get-FileSha256 -Path $resolvedPath
        event_state = $state
        last_event_type = $lastType
        raw_lines = [string[]]$rawLines
        usage_limit_evidence = @($usageLimitEvidence.ToArray())
        usage_limit = $usageLimit
    }
}

function Convert-EventEvidenceToServiceRejection {
    param(
        [Parameter(Mandatory)]
        [psobject]$EventEvidence
    )

    if ((Get-DispatchJsonProperty -Object $EventEvidence -Name 'usage_limit') -ne $true) {
        return $null
    }
    $reasonCode = 'usage-limit'
    $observedAtUtc = [DateTimeOffset]::UtcNow
    $usageLimitEvidenceValue = Get-DispatchJsonProperty -Object $EventEvidence -Name 'usage_limit_evidence'
    $usageLimitEvidence = New-Object 'System.Collections.Generic.List[object]'
    if ($usageLimitEvidenceValue -is [System.Collections.IEnumerable] -and $usageLimitEvidenceValue -isnot [string]) {
        foreach ($evidence in $usageLimitEvidenceValue) {
            $null = $usageLimitEvidence.Add($evidence)
        }
    }
    elseif ($null -ne $usageLimitEvidenceValue) {
        $null = $usageLimitEvidence.Add($usageLimitEvidenceValue)
    }
    if ($usageLimitEvidence.Count -eq 0) {
        return $null
    }
    foreach ($match in @($usageLimitEvidence.ToArray() | Select-Object -Last 20)) {
        $matchedReasonCode = [string](Get-DispatchJsonProperty -Object $match -Name 'reason_code')
        if (-not [string]::IsNullOrWhiteSpace($matchedReasonCode)) {
            $reasonCode = $matchedReasonCode
        }
        $timestamp = Get-DispatchJsonProperty -Object $match -Name 'observed_at'
        if ($null -ne $timestamp) {
            try {
                $observedAtUtc = [DateTimeOffset]$timestamp
            }
            catch {
            }
        }
    }
    return [ordered]@{
        status              = 'quota-rejected'
        window              = 'unknown'
        reason_code         = $reasonCode
        observed_at_utc     = $observedAtUtc.ToUniversalTime().ToString('o')
        raw_evidence_path   = [string]$EventEvidence.path
        raw_evidence_sha256 = [string]$EventEvidence.sha256
        resets_at           = $null
        retry_allowed       = $false
    }
}

function Get-RecoveryChainInterruptedUnknownRecords {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Records
    )

    $unknownRecords = New-Object 'System.Collections.Generic.List[object]'
    foreach ($record in @($Records)) {
        if ($null -eq $record) {
            continue
        }
        $unknownInterruption = Get-DispatchJsonProperty -Object (Get-DispatchJsonProperty -Object $record -Name 'unknown_interruption') -Name 'status'
        if ([string]$unknownInterruption -ceq 'InterruptedUnknown') {
            $unknownRecords.Add($record)
        }
    }
    return @($unknownRecords.ToArray())
}

function New-InterruptedUnknownResumeRejectedException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ExecutionRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [Parameter(Mandatory)][psobject]$Record,
        [AllowNull()][object]$Events
    )

    $recordPath = Join-Path -Path (Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug) -ChildPath ($Record.run_id + '.json')
    $message = 'InterruptedUnknownResumeRejected process_started=false cold_start_recommended=true new_dispatch_worktree_required=true worktree="' + $ExecutionRoot + '" record="' + $recordPath + '" reason=InterruptedUnknown'
    $exception = New-Object System.Exception($message)
    $exception.Data['recoveryResumeGate'] = [ordered]@{
        code = 'InterruptedUnknownResumeRejected'
        process_started = $false
        cold_start_recommended = $true
        new_dispatch_worktree_required = $true
        worktree = $ExecutionRoot
        record_path = $recordPath
        run_id = $Record.run_id
        evidence = $Events
    }
    return $exception
}

function Get-RecoveryChainModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$LatestRecord,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug
    )

    $records = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $current = $LatestRecord
    while ($null -ne $current) {
        if (-not $seen.Add([string]$current.run_id)) {
            throw 'Execution chain 存在循環。'
        }
        $records.Add($current)
        $parentId = [string](Get-DispatchJsonProperty -Object $current -Name 'attempt_parent_run_id')
        if ([string]::IsNullOrWhiteSpace($parentId)) {
            $parentId = [string](Get-DispatchJsonProperty -Object $current -Name 'previous_run_id')
        }
        if ([string]::IsNullOrWhiteSpace($parentId)) {
            $current = $null
            continue
        }
        $parentPath = Join-Path -Path (Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug) -ChildPath ($parentId + '.json')
        if (-not (Test-Path -LiteralPath $parentPath -PathType Leaf)) {
            throw 'Execution chain 斷鏈：' + $parentId
        }
        $current = Read-DispatchRunRecord -Path $parentPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    }

    $interruptedUnknownRecords = @(Get-RecoveryChainInterruptedUnknownRecords -Records @($records.ToArray()))
    $anchor = $null
    foreach ($candidate in @($records.ToArray())) {
        $unknownInterruption = Get-DispatchJsonProperty -Object (Get-DispatchJsonProperty -Object $candidate -Name 'unknown_interruption') -Name 'status'
        if ($candidate.launch_state -ne 'launch-failed' -and $unknownInterruption -ne 'InterruptedUnknown') {
            $anchor = $candidate
            break
        }
    }
    $chainItems = New-Object 'System.Collections.Generic.List[object]'
    $reverseRecords = @($records.ToArray())
    [array]::Reverse($reverseRecords)
    foreach ($record in $reverseRecords) {
        $chainItems.Add([ordered]@{
                run_id = $record.run_id
                path = Join-Path -Path (Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug) -ChildPath ($record.run_id + '.json')
                sha256 = Get-FileSha256 -Path (Join-Path -Path (Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug) -ChildPath ($record.run_id + '.json'))
                launch_state = $record.launch_state
            })
    }
    $chainFingerprint = Get-JsonSha256 -Value @($chainItems.ToArray())
    return [ordered]@{
        latest = $LatestRecord
        anchor = $anchor
        records = @($records.ToArray())
        items = @($chainItems.ToArray())
        fingerprint = $chainFingerprint
        interrupted_unknown_records = @($interruptedUnknownRecords)
        contains_interrupted_unknown = $interruptedUnknownRecords.Count -gt 0
        skipped_attempts = @($records.ToArray() | Where-Object {
                $_.launch_state -eq 'launch-failed' -or
                (Get-DispatchJsonProperty -Object (Get-DispatchJsonProperty -Object $_ -Name 'unknown_interruption') -Name 'status') -eq 'InterruptedUnknown'
            } | ForEach-Object {
                [ordered]@{
                    run_id = $_.run_id
                    path = Join-Path -Path (Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug) -ChildPath ($_.run_id + '.json')
                    sha256 = Get-FileSha256 -Path (Join-Path -Path (Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug) -ChildPath ($_.run_id + '.json'))
                    reason = [string](Get-DispatchJsonProperty -Object $_.failure -Name 'reason_code')
                    failure = Get-DispatchJsonProperty -Object $_ -Name 'failure'
                }
            })
    }
}

function Get-DispatchRunDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$LineSlug,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$DispatchSlug
    )

    $history = Join-Path (Resolve-AbsolutePath $SourceRoot) '.local\ai-sessions\history'
    return Join-Path (Join-Path (Join-Path $history $LineSlug) 'runs') $DispatchSlug
}

function Get-DispatchPathEvidence {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Path
    )

    $resolvedPath = $null
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        try {
            $resolvedPath = Resolve-AbsolutePath -Path $Path
        }
        catch {
            $resolvedPath = $Path
        }
    }
    $exists = $false
    $length = [int64]0
    $sha256 = $null
    $readError = $null
    if (-not [string]::IsNullOrWhiteSpace($resolvedPath) -and (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        $exists = $true
        try {
            $file = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
            $length = [int64]$file.Length
            $sha256 = Get-FileSha256 -Path $resolvedPath
        }
        catch {
            $readError = $_.Exception.Message
        }
    }
    return [ordered]@{
        path = $resolvedPath
        exists = $exists
        length = $length
        sha256 = $sha256
        error = $readError
    }
}

function Get-DispatchFailureReasonCode {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Message,

        [AllowNull()]
        [string]$Phase
    )

    $text = if ($null -eq $Message) { '' } else { $Message }
    if ($text -match '(?i)quota[\s_-]+service[\s_-]+rejection') {
        return 'QuotaServiceRejected'
    }
    foreach ($code in @(
            'RequiredParameterMissing',
            'EvidencePackRequiredOutputInvalid',
            'AdvisorImplementationProfileRejected',
            'AdvisorProfileRequired',
            'AdvisorAuthorizationRequired',
            'RequestedResolutionMismatch',
            'EvidencePackInlineMismatch',
            'EvidencePackInvalid',
            'EvidencePackMissing',
            'NoValidResumeAnchor',
            'ResumeHandoffUnavailable',
            'ProfileEvidenceUnknown',
            'ThreadRelayTimeout',
            'ProcessIdentityUnknown',
            'CodexLaunchFailed',
            'ParentOptionsMismatch',
            'ParentOptionsUnknown',
            'InterruptedUnknownResumeRejected',
            'InterruptedUnknown',
            'CrossLine',
            'ScopePlanMismatch',
            'BaselineUnknown',
            'ProcessAlive',
            'ModelUnknown',
            'PrepareRequired',
            'PrepareArtifactMismatch',
            'PreparedResultMissing',
            'ScopePlanInvalid',
            'QuotaServiceRejected')) {
        if ($text.Contains($code)) {
            return $code
        }
    }
    if ($Phase -eq 'thread-relay-not-ready') {
        return 'ThreadRelayTimeout'
    }
    if ($Phase -eq 'identity-unverified') {
        return 'ProcessIdentityUnknown'
    }
    if ($Phase -eq 'preparation') {
        return 'ProfileEvidenceUnknown'
    }
    if ($Phase -eq 'started') {
        return 'CodexLaunchFailed'
    }
    return 'CodexLaunchFailed'
}

function New-DispatchFailureRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Phase,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$ReasonCode,

        [bool]$ProcessStarted,

        [Nullable[int]]$ProcessExitCode,

        [string]$EventPath,

        [string]$ErrorPath,

        [string]$LastMessagePath,

        [string]$ThreadPath,

        [string]$PidPath,

        [string]$LauncherPath,

        [string[]]$RolloutPaths,

        [AllowNull()]
        [object]$Observation
    )

    $effectiveReasonCode = if ([string]::IsNullOrWhiteSpace($ReasonCode)) { Get-DispatchFailureReasonCode -Message $Message -Phase $Phase } else { $ReasonCode }
    $processExit = if ($null -eq $ProcessExitCode) { $null } else { [int]$ProcessExitCode }
    $originalOutput = [ordered]@{
        exception = $Message
        event_stream = Get-DispatchPathEvidence -Path $EventPath
        stderr = Get-DispatchPathEvidence -Path $ErrorPath
        last_message = Get-DispatchPathEvidence -Path $LastMessagePath
        thread_id = Get-DispatchPathEvidence -Path $ThreadPath
        pid_record = Get-DispatchPathEvidence -Path $PidPath
        launcher = Get-DispatchPathEvidence -Path $LauncherPath
        rollout = @($RolloutPaths | ForEach-Object { Get-DispatchPathEvidence -Path $_ })
        raw_message = $Message
    }
    $failureObservation = if ($null -eq $Observation) {
        [ordered]@{
            process_started = $ProcessStarted
            process_exit_code = $processExit
        }
    }
    else {
        $Observation
    }
    return [ordered]@{
        status = 'failed'
        phase = $Phase
        reason_code = $effectiveReasonCode
        message = $Message
        observation = $failureObservation
        original_output = $originalOutput
        resumable = $false
        recorded_at_utc = [datetime]::UtcNow.ToString('o')
    }
}

function New-DispatchInspectDiagnosis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ReasonCode,

        [Parameter(Mandatory)]
        [string]$Observation,

        [Parameter(Mandatory)]
        [string]$EventStreamPath,

        [string]$ErrorStreamPath,

        [AllowEmptyCollection()]
        [object[]]$RawEventLines,

        [AllowEmptyString()]
        [string]$Stderr
    )

    return [ordered]@{
        status = 'failed'
        reason_code = $ReasonCode
        observation = $Observation
        original_output = [ordered]@{
            event_stream_path = $EventStreamPath
            error_stream_path = if ([string]::IsNullOrWhiteSpace($ErrorStreamPath)) { $null } else { $ErrorStreamPath }
            raw_event_lines = [string[]]@($RawEventLines | ForEach-Object {
                    if ($_ -is [string]) { $_ } else { [string](Get-DispatchJsonProperty -Object $_ -Name 'raw') }
                })
            stderr = $Stderr
        }
    }
}

function Write-DispatchOperationFailureResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Exception]$Exception,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Result
    )

    try {
        $Exception.Data['operationResult'] = $Result
    }
    catch {
        # 例外型別可能不允許寫入 Data，保留原始例外供外層 catch 處理。
    }
    return $Exception
}

function Write-DispatchRunRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Record,
        [switch]$Update
    )

    $directory = Get-DispatchRunDirectory -SourceRoot $Record.source_root -LineSlug $Record.line_slug -DispatchSlug $Record.dispatch_slug
    $runGuid = [guid]::Empty
    if (-not [guid]::TryParseExact($Record.run_id, 'D', [ref]$runGuid)) {
        throw 'RunRecord run_id 必須為 GUID。'
    }
    $path = Join-Path $directory ($Record.run_id + '.json')
    $null = New-DispatchOutputDirectory -Path $directory -SourceRoot ([string]$Record.source_root) -ExecutionRoot ([string]$Record.execution_root) -TargetPath @()
    $written = Write-DispatchAtomicJsonDocument -Path $path -Document $Record -SourceRoot ([string]$Record.source_root) -ExecutionRoot ([string]$Record.execution_root) -TargetPath @() -HashProperty '' -RequireAbsent:(-not $Update) -AbsentErrorCode 'RunRecordCollision'
    return $written.Path
}

function ConvertFrom-DispatchJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Content)

    $options = @{ InputObject = $Content; ErrorAction = 'Stop' }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $options.DateKind = 'String'
    }
    return ConvertFrom-Json @options
}

function Read-DispatchRunRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ExecutionRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug
    )

    $pathValue = Resolve-AbsolutePath $Path
    $directory = Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    if (-not [string]::Equals((Split-Path $pathValue -Parent), $directory, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'RunRecord 路徑不屬於指定 line／dispatch。'
    }
    Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $pathValue
    $record = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $pathValue)
    if ($null -eq $record -or $record -isnot [pscustomobject]) { throw 'RunRecord 必須為 JSON object。' }
    foreach ($name in @('previous_run_id', 'requested_thread_id', 'thread_id', 'baseline_path', 'baseline_sha256', 'baseline_resolution', 'attempt_parent_run_id', 'resume_anchor_run_id', 'failure', 'resume_diagnostics', 'model_evidence', 'reasoning_effort_evidence', 'started_at_utc', 'thread_id_path', 'launcher_path', 'process_exit_code_sidecar_path', 'prompt_path', 'prompt_source_path', 'prompt_source_sha256', 'prompt_transfer_path', 'prompt_transfer_sha256', 'inspect_result_path', 'profile_config_path', 'codex_home', 'effective_codex_home', 'evidence_pack_path', 'evidence_pack_sha256', 'evidence_pack_length', 'skipped_attempts', 'parent_options', 'parent_options_sha256', 'parent_options_status', 'scope_plan_parent_path', 'scope_plan_parent_sha256', 'scope_plan_parent_run_id', 'scope_plan_root_run_id', 'scope_plan_selection', 'unknown_interruption', 'prepare_result_path', 'prepare_result_sha256', 'prepare_status', 'quota_before_path', 'quota_before_sha256', 'quota_before_captured_at_utc', 'quota_before_freshness', 'quota_after_path', 'quota_after_sha256', 'request_path', 'request_sha256', 'request_operation')) {
        if ($null -eq $record.PSObject.Properties[$name]) {
            $value = $null
            if ($name -eq 'attempt_parent_run_id') {
                $value = Get-DispatchJsonProperty -Object $record -Name 'previous_run_id'
            }
            elseif ($name -eq 'skipped_attempts') {
                $value = @()
            }
            elseif ($name -eq 'parent_options_status') {
                $value = 'unknown'
            }
            elseif ($name -eq 'scope_plan_selection') {
                $value = 'root'
            }
            $record | Add-Member -MemberType NoteProperty -Name $name -Value $value
        }
    }
    if ($null -eq $record.model_evidence) {
        $record.model_evidence = ConvertTo-DispatchEvidenceGroup -Evidence $null -Field 'model'
    }
    if ($null -eq $record.reasoning_effort_evidence) {
        $record.reasoning_effort_evidence = ConvertTo-DispatchEvidenceGroup -Evidence $null -Field 'model_reasoning_effort'
    }
    if ($null -ne $record.parent_options) {
        $parentFingerprint = [string](Get-DispatchJsonProperty -Object $record.parent_options -Name 'fingerprint')
        if ([string]::IsNullOrWhiteSpace($parentFingerprint)) {
            throw 'RunRecord parent_options 缺少 fingerprint。'
        }
        if ($record.parent_options_status -ne 'confirmed') {
            throw 'RunRecord parent_options 存在但狀態不是 confirmed。'
        }
        if ($record.parent_options_sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $record.parent_options_sha256 -ine $parentFingerprint) {
            throw 'RunRecord parent_options SHA-256 不一致。'
        }
    }
    elseif ($record.parent_options_status -eq 'confirmed' -or $null -ne $record.parent_options_sha256) {
        throw 'RunRecord parent_options 狀態與內容不一致。'
    }
    foreach ($name in @('schema', 'run_id', 'dispatch_slug', 'line_slug', 'source_root', 'execution_root', 'event_stream_path', 'last_message_path', 'preflight_result_path', 'preflight_sha256', 'created_at_utc', 'launch_state', 'pid_record_path')) {
        $property = $record.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($property.Value)) {
            throw "RunRecord 缺少有效欄位：$name"
        }
    }
    $scopePathProperty = $record.PSObject.Properties['scope_plan_path']
    $scopeHashProperty = $record.PSObject.Properties['scope_plan_sha256']
    if ($null -eq $scopePathProperty -or $null -eq $scopeHashProperty) {
        throw 'RunRecord 缺少 ScopePlan 欄位。'
    }
    $scopePathValue = $scopePathProperty.Value
    $scopeHashValue = $scopeHashProperty.Value
    $failureValue = $record.failure
    $failurePhase = if ($null -eq $failureValue) { $null } else { [string](Get-DispatchJsonProperty -Object $failureValue -Name 'phase') }
    $scopeMayBeNull = $record.launch_state -eq 'launch-failed' -and $failurePhase -eq 'preparation'
    if ([string]::IsNullOrWhiteSpace([string]$scopePathValue)) {
        if (-not $scopeMayBeNull -or $null -ne $scopeHashValue) {
            throw 'RunRecord ScopePlan path 與 SHA-256 必須成對存在；只有 preparation failed 可同時為 null。'
        }
    }
    elseif ($scopePathValue -isnot [string] -or $scopeHashValue -isnot [string] -or [string]::IsNullOrWhiteSpace($scopeHashValue)) {
        throw 'RunRecord ScopePlan 欄位型別或 SHA-256 異常。'
    }
    foreach ($name in @('previous_run_id', 'requested_thread_id', 'thread_id', 'baseline_path', 'baseline_sha256', 'attempt_parent_run_id', 'resume_anchor_run_id', 'started_at_utc', 'thread_id_path', 'launcher_path', 'process_exit_code_sidecar_path', 'prompt_path', 'prompt_source_path', 'prompt_source_sha256', 'prompt_transfer_path', 'prompt_transfer_sha256', 'inspect_result_path', 'profile_config_path', 'codex_home', 'effective_codex_home', 'evidence_pack_path', 'evidence_pack_sha256', 'parent_options_sha256', 'parent_options_status', 'scope_plan_parent_path', 'scope_plan_parent_sha256', 'scope_plan_parent_run_id', 'scope_plan_root_run_id', 'scope_plan_selection', 'prepare_result_path', 'prepare_result_sha256', 'prepare_status', 'quota_before_path', 'quota_before_sha256', 'quota_before_captured_at_utc', 'quota_before_freshness', 'quota_after_path', 'quota_after_sha256')) {
        $property = $record.PSObject.Properties[$name]
        if ($null -eq $property -or ($null -ne $property.Value -and ($property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($property.Value)))) {
            throw "RunRecord nullable 欄位異常：$name"
        }
    }
    foreach ($name in @('quota_before_observations', 'quota_before_service_rejection')) {
        if ($null -eq $record.PSObject.Properties[$name]) {
            $record | Add-Member -MemberType NoteProperty -Name $name -Value $null
        }
    }
    if ($record.schema -cne 'ai-sessions.dispatch-run.v1' -or $record.line_slug -cne $LineSlug -or $record.dispatch_slug -cne $DispatchSlug) {
        throw 'RunRecord schema／line／dispatch 不一致。'
    }
    foreach ($name in @('run_id', 'previous_run_id', 'requested_thread_id', 'thread_id', 'attempt_parent_run_id', 'resume_anchor_run_id', 'scope_plan_parent_run_id', 'scope_plan_root_run_id')) {
        $parsed = [guid]::Empty
        if ($null -ne $record.$name -and -not [guid]::TryParseExact($record.$name, 'D', [ref]$parsed)) { throw "RunRecord GUID 異常：$name" }
    }
    if ($null -ne $record.attempt_parent_run_id -and $record.attempt_parent_run_id -ceq $record.run_id) { throw 'RunRecord attempt parent 不可指向自身。' }
    if ([IO.Path]::GetFileName($pathValue) -cne ($record.run_id + '.json')) { throw 'RunRecord 檔名與 run_id 不一致。' }
    if ($record.launch_state -cnotin @('prepared', 'started', 'launch-failed')) { throw 'RunRecord launch_state 異常。' }
    if ($record.launch_state -eq 'started' -and $null -eq $record.thread_id) { throw 'started RunRecord 缺少 thread。' }
    if (($null -eq $record.previous_run_id) -ne ($null -eq $record.requested_thread_id) -and $record.launch_state -ne 'launch-failed') { throw 'RunRecord previous 與 requested thread 不一致。' }
    if ($null -ne $record.thread_id -and $null -ne $record.requested_thread_id -and $record.thread_id -cne $record.requested_thread_id) { throw 'RunRecord thread 與 requested thread 不一致。' }
    $created = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse($record.created_at_utc, [ref]$created) -or $created.Offset -ne [timespan]::Zero) { throw 'RunRecord UTC 時間異常。' }
    if ($null -ne $record.started_at_utc) {
        $started = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse($record.started_at_utc, [ref]$started) -or $started.Offset -ne [timespan]::Zero) { throw 'RunRecord started_at_utc 時間異常。' }
    }
    foreach ($entry in @(@('source_root', $SourceRoot), @('execution_root', $ExecutionRoot))) {
        if (-not [string]::Equals((Resolve-AbsolutePath $record.($entry[0])), (Resolve-AbsolutePath $entry[1]), [StringComparison]::OrdinalIgnoreCase)) { throw 'RunRecord roots 不一致。' }
    }
    $executionHistory = Join-Path (Resolve-AbsolutePath $ExecutionRoot) '.local\ai-sessions\history'
    foreach ($name in @('event_stream_path', 'last_message_path', 'preflight_result_path', 'pid_record_path')) {
        $resolved = Resolve-AbsolutePath $record.$name
        if (-not [string]::Equals($resolved, $record.$name, [StringComparison]::OrdinalIgnoreCase)) { throw "RunRecord 路徑未正規化：$name" }
    }
    foreach ($name in @('thread_id_path', 'launcher_path', 'process_exit_code_sidecar_path', 'prompt_path', 'prompt_source_path', 'prompt_transfer_path', 'inspect_result_path', 'evidence_pack_path', 'request_path')) {
        if ($null -ne $record.$name) {
            $resolved = Resolve-AbsolutePath $record.$name
            if (-not [string]::Equals($resolved, $record.$name, [StringComparison]::OrdinalIgnoreCase)) { throw "RunRecord 路徑未正規化：$name" }
        }
    }
    if (-not (Test-PathWithinRoot $record.event_stream_path $executionHistory) -or -not (Test-PathWithinRoot $record.last_message_path $ExecutionRoot)) { throw 'RunRecord 證據超出 executionRoot。' }
    if (-not [string]::IsNullOrWhiteSpace([string]$scopePathValue) -and -not (Test-PathWithinRoot $scopePathValue $ExecutionRoot)) { throw 'RunRecord ScopePlan 超出 executionRoot。' }
    if (-not (Test-PathWithinRoot $record.pid_record_path (Join-Path $SourceRoot '.local\ai-sessions\history'))) { throw 'RunRecord PID 路徑超出 history。' }
    foreach ($name in @('thread_id_path', 'launcher_path', 'process_exit_code_sidecar_path', 'prompt_path', 'prompt_transfer_path', 'inspect_result_path')) {
        if ($null -ne $record.$name -and -not (Test-PathWithinRoot $record.$name $ExecutionRoot)) { throw "RunRecord 證據超出 executionRoot：$name" }
    }
    if ($null -ne $record.prompt_source_path -and -not (Test-PathWithinRoot $record.prompt_source_path $SourceRoot) -and -not (Test-PathWithinRoot $record.prompt_source_path $ExecutionRoot)) { throw 'RunRecord Prompt source 超出 sourceRoot／executionRoot。' }
    if ($null -ne $record.evidence_pack_path -and -not (Test-PathWithinRoot $record.evidence_pack_path $ExecutionRoot)) { throw 'RunRecord evidence pack 超出 executionRoot。' }
    if ($null -ne $record.process_exit_code_sidecar_path -and -not (Test-PathWithinRoot $record.process_exit_code_sidecar_path $executionHistory)) { throw 'RunRecord exit sidecar 超出 execution history。' }
    if (-not [string]::IsNullOrWhiteSpace([string]$scopePathValue)) {
        if ($scopeHashValue -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileSha256 $scopePathValue) -ne $scopeHashValue) { throw 'RunRecord 證據 SHA-256 不一致。' }
    }
    if ([string]$record.scope_plan_selection -notin @('root', 'subset')) {
        throw 'RunRecord scope_plan_selection 異常。'
    }
    $scopeParentPath = [string](Get-DispatchJsonProperty -Object $record -Name 'scope_plan_parent_path')
    $scopeParentSha256 = [string](Get-DispatchJsonProperty -Object $record -Name 'scope_plan_parent_sha256')
    $scopeParentRunId = [string](Get-DispatchJsonProperty -Object $record -Name 'scope_plan_parent_run_id')
    if ([string]::IsNullOrWhiteSpace($scopeParentPath)) {
        if (-not [string]::IsNullOrWhiteSpace($scopeParentSha256) -or -not [string]::IsNullOrWhiteSpace($scopeParentRunId) -or $record.scope_plan_selection -eq 'subset') {
            throw 'RunRecord ScopePlan parent 欄位必須成對存在。'
        }
    }
    else {
        if ($scopeParentSha256 -notmatch '^[a-fA-F0-9]{64}$' -or [string]::IsNullOrWhiteSpace($scopeParentRunId)) {
            throw 'RunRecord ScopePlan parent 欄位型別或 SHA-256 異常。'
        }
        if (-not [string]::Equals((Resolve-AbsolutePath $scopeParentPath), $scopeParentPath, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-PathWithinRoot $scopeParentPath $ExecutionRoot)) {
            throw 'RunRecord ScopePlan parent path 必須是 executionRoot 內的正規化路徑。'
        }
        if (-not (Test-Path -LiteralPath $scopeParentPath -PathType Leaf) -or (Get-FileSha256 $scopeParentPath) -ine $scopeParentSha256) {
            throw 'RunRecord ScopePlan parent SHA-256 不一致。'
        }
        if ($record.scope_plan_selection -ne 'subset') {
            throw 'RunRecord 有 ScopePlan parent 時 selection 必須是 subset。'
        }
    }
    if ($record.preflight_sha256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileSha256 $record.preflight_result_path) -ne $record.preflight_sha256) {
        throw 'RunRecord 證據 SHA-256 不一致。'
    }
    $preflight = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $record.preflight_result_path)
    foreach ($entry in @(@('sourceRoot', $SourceRoot), @('executionRoot', $ExecutionRoot))) {
        $value = Get-RequiredPreflightProperty $preflight $entry[0]
        if (-not [string]::Equals((Resolve-AbsolutePath $value), (Resolve-AbsolutePath $entry[1]), [StringComparison]::OrdinalIgnoreCase)) { throw 'RunRecord Preflight roots 不一致。' }
    }
    if ((Get-RequiredPreflightProperty $preflight 'lineSlug') -cne $LineSlug -or (Get-RequiredPreflightProperty $preflight 'dispatchSlug') -cne $DispatchSlug) { throw 'RunRecord Preflight 身分不一致。' }
    $baselineResolutionValue = $record.baseline_resolution
    $baselineResolutionStatus = $null
    if ($null -ne $baselineResolutionValue) {
        if ($baselineResolutionValue -isnot [psobject]) { throw 'RunRecord baseline_resolution 必須為 object。' }
        $baselineResolutionStatus = [string](Get-DispatchJsonProperty -Object $baselineResolutionValue -Name 'status')
        if ($baselineResolutionStatus -notin @('pending', 'confirmed', 'failed', 'not-applicable')) { throw 'RunRecord baseline_resolution status 異常。' }
        $baselineQueryLocation = [string](Get-DispatchJsonProperty -Object $baselineResolutionValue -Name 'query_location')
        if ([string]::IsNullOrWhiteSpace($baselineQueryLocation)) { throw 'RunRecord baseline_resolution 缺少 query_location。' }
        if ($baselineResolutionStatus -eq 'failed' -and [string]::IsNullOrWhiteSpace([string](Get-DispatchJsonProperty -Object $baselineResolutionValue -Name 'error'))) {
            throw 'RunRecord baseline_resolution failed 缺少 error。'
        }
        if ($baselineResolutionStatus -eq 'confirmed') {
            $confirmedBaselinePath = [string](Get-DispatchJsonProperty -Object $baselineResolutionValue -Name 'path')
            $confirmedBaselineSha256 = [string](Get-DispatchJsonProperty -Object $baselineResolutionValue -Name 'sha256')
            if ([string]::IsNullOrWhiteSpace($confirmedBaselinePath) -or $confirmedBaselineSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'RunRecord baseline_resolution confirmed 缺少有效 Baseline。' }
        }
    }
    else {
        $baselineResolutionStatus = if ([string]::Equals((Resolve-AbsolutePath $SourceRoot), (Resolve-AbsolutePath $ExecutionRoot), [StringComparison]::OrdinalIgnoreCase)) { 'not-applicable' } elseif (-not [string]::IsNullOrWhiteSpace($record.baseline_path) -and $record.baseline_sha256 -match '^[a-fA-F0-9]{64}$') { 'confirmed' } else { $null }
    }
    $baselineResolutionFailure = $record.launch_state -eq 'launch-failed' -and $baselineResolutionStatus -eq 'failed'
    if (-not [string]::Equals((Resolve-AbsolutePath $SourceRoot), (Resolve-AbsolutePath $ExecutionRoot), [StringComparison]::OrdinalIgnoreCase)) {
        if ($baselineResolutionFailure) {
            if ($null -ne $record.baseline_path -or $null -ne $record.baseline_sha256) { throw 'baseline resolution failed 的 RunRecord 不可宣稱已綁定 Baseline。' }
        }
        else {
            $null = Resolve-DispatchBaselineBinding -Preflight $preflight -SourceRoot $SourceRoot -DispatchRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -BaseSha (Get-RequiredPreflightProperty $preflight 'baseSha') -Path $record.baseline_path -Sha256 $record.baseline_sha256
            if ([string]::IsNullOrWhiteSpace($record.baseline_path) -or [string]::IsNullOrWhiteSpace($record.baseline_sha256)) { throw 'worktree RunRecord 缺少 Baseline 綁定。' }
        }
    }
    elseif ($null -ne $record.baseline_path -or $null -ne $record.baseline_sha256) { throw 'direct-write RunRecord Baseline 必須為 null。' }
    if ($record.launch_state -eq 'launch-failed') {
        if ($null -eq $failureValue -or $failureValue -isnot [psobject]) { throw 'launch-failed RunRecord 缺少 failure object。' }
        foreach ($name in @('status', 'phase', 'reason_code', 'message', 'recorded_at_utc')) {
            $property = $failureValue.PSObject.Properties[$name]
            if ($null -eq $property -or $property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($property.Value)) { throw "failure 缺少有效欄位：$name" }
        }
        if ($failureValue.status -cne 'failed' -or $failureValue.resumable -ne $false) { throw 'failure status 或 resumable 不符合契約。' }
        foreach ($name in @('observation', 'original_output')) {
            if ($null -eq $failureValue.PSObject.Properties[$name] -or $null -eq $failureValue.$name) { throw "failure 缺少欄位：$name" }
        }
        $failureRecordedAt = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse($failureValue.recorded_at_utc, [ref]$failureRecordedAt) -or $failureRecordedAt.Offset -ne [timespan]::Zero) { throw 'failure recorded_at_utc 時間異常。' }
    }
    elseif ($null -ne $failureValue) {
        throw '成功或 prepared RunRecord 不可包含 failure object。'
    }
    return $record
}

function Get-DispatchRunEvents {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Record)

    $retryAttempts = 1
    $rootPidProperty = $Record.PSObject.Properties['root_pid']
    $rootPid = 0
    if ($null -ne $rootPidProperty -and [int]::TryParse([string]$rootPidProperty.Value, [ref]$rootPid) -and $rootPid -gt 0) {
        try {
            $rootProcess = Get-Process -Id $rootPid -ErrorAction Stop
            $retryAttempts = if ($rootProcess.HasExited) { 10 } else { 60 }
        }
        catch {
            $retryAttempts = 10
        }
    }

    $events = @()
    $lastReadError = $null
    for ($attempt = 1; $attempt -le $retryAttempts; $attempt++) {
        try {
            $rawText = Read-DispatchUtf8Text -Path $Record.event_stream_path
            $events = @(
                foreach ($line in ($rawText -split '\r?\n')) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    $event = $line | ConvertFrom-Json -ErrorAction Stop
                    $typeProperty = if ($null -eq $event) { $null } else { $event.PSObject.Properties['type'] }
                    if ($null -eq $event -or $event -isnot [pscustomobject] -or $null -eq $typeProperty -or -not ($typeProperty.Value -is [string]) -or [string]::IsNullOrWhiteSpace($typeProperty.Value)) { throw 'RunRecord 事件缺少 type。' }
                    $event
                }
            )
            $lastReadError = $null
            if ($events.Count -gt 0) { break }
        }
        catch {
            $lastReadError = $_
        }
        if ($attempt -lt $retryAttempts) {
            Start-Sleep -Milliseconds 100
        }
    }
    if ($events.Count -eq 0 -and $null -ne $lastReadError) {
        throw $lastReadError.Exception
    }
    if ($events.Count -eq 0) { throw 'RunRecord 事件流為空。' }
    $threads = @($events | Where-Object { $_.type -eq 'thread.started' })
    if ($threads.Count -ne 1) { throw 'RunRecord 事件必須包含唯一 thread.started。' }
    $thread = Get-EventPropertyValue $threads[0] 'thread_id'
    $parsed = [guid]::Empty
    if ($thread -isnot [string] -or -not [guid]::TryParseExact($thread, 'D', [ref]$parsed)) { throw 'RunRecord 事件 thread 無效。' }
    if (($null -ne $Record.thread_id -and $Record.thread_id -cne $thread) -or ($null -ne $Record.requested_thread_id -and $Record.requested_thread_id -cne $thread)) { throw 'RunRecord 事件 thread 不一致。' }
    $lastType = [string]$events[-1].type
    return [pscustomobject]@{
        ThreadId = $thread
        Completed = $lastType -eq 'turn.completed'
        Terminal = $lastType -in @('turn.completed', 'turn.failed')
        LastEventType = $lastType
        UnknownInterruption = $lastType -eq 'turn.started'
    }
}

function Get-DispatchRunRecordList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ExecutionRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug
    )

    $directory = Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        return @()
    }
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -ErrorAction Stop)) {
        $record = Read-DispatchRunRecord -Path $file.FullName -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        if (@($records | Where-Object { $_.run_id -ceq $record.run_id }).Count -gt 0) { throw 'RunRecord 重複 run_id。' }
        $records.Add($record)
    }
    return @($records.ToArray())
}

function Get-DispatchRunRecordStartClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Record
    )

    $launchStateProperty = $Record.PSObject.Properties['launch_state']
    $launchState = if ($null -eq $launchStateProperty) { $null } else { [string]$launchStateProperty.Value }
    $preStartStages = @('preparation', 'profile-evidence', 'evidence-pack-inline')
    if ($launchState -eq 'started') {
        return [pscustomobject]@{
            classification = 'actual-start'
            reason = 'launch_state=started。'
            launch_state = $launchState
            process_started = $true
            phase = $null
            failure_stage = $null
        }
    }

    $failureProperty = $Record.PSObject.Properties['failure']
    $failure = if ($null -eq $failureProperty) { $null } else { $failureProperty.Value }
    $failurePhaseProperty = if ($null -eq $failure) { $null } else { $failure.PSObject.Properties['phase'] }
    $phase = if ($null -eq $failurePhaseProperty) { $null } else { [string]$failurePhaseProperty.Value }
    $observationProperty = if ($null -eq $failure) { $null } else { $failure.PSObject.Properties['observation'] }
    $observation = if ($null -eq $observationProperty) { $null } else { $observationProperty.Value }
    $processStartedProperty = if ($null -eq $observation) { $null } else { $observation.PSObject.Properties['process_started'] }
    $failureStageProperty = if ($null -eq $observation) { $null } else { $observation.PSObject.Properties['failure_stage'] }
    $failureStage = if ($null -eq $failureStageProperty) { $null } else { [string]$failureStageProperty.Value }
    $knownStages = @($phase, $failureStage) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    $hasPreStartStage = @($knownStages | Where-Object { $preStartStages -contains [string]$_ }).Count -gt 0
    $hasNonPreStartStage = @($knownStages | Where-Object { $preStartStages -notcontains [string]$_ }).Count -gt 0

    if ($launchState -eq 'launch-failed' -and $null -ne $processStartedProperty -and $processStartedProperty.Value -is [bool]) {
        $processStarted = [bool]$processStartedProperty.Value
        if ($processStarted) {
            return [pscustomobject]@{
                classification = 'actual-start'
                reason = 'launch-failed 但 failure.observation.process_started=true，不能略過。'
                launch_state = $launchState
                process_started = $true
                phase = $phase
                failure_stage = $failureStage
            }
        }
        if ($hasPreStartStage -and -not $hasNonPreStartStage) {
            return [pscustomobject]@{
                classification = 'unstarted-sandbox'
                reason = 'launch-failed、process_started=false，且失敗階段為已知 pre-start 階段。'
                launch_state = $launchState
                process_started = $false
                phase = $phase
                failure_stage = $failureStage
            }
        }
        return [pscustomobject]@{
            classification = 'unknown'
            reason = 'process_started=false 但缺少或衝突的已定義 pre-start 階段。'
            launch_state = $launchState
            process_started = $false
            phase = $phase
            failure_stage = $failureStage
        }
    }

    return [pscustomobject]@{
        classification = 'unknown'
        reason = if ($launchState -eq 'launch-failed') { 'launch-failed 缺少明確布林 process_started 或 observation。' } else { 'RunRecord 狀態不是可判定的 started 或 launch-failed。' }
        launch_state = $launchState
        process_started = $null
        phase = $phase
        failure_stage = $failureStage
    }
}

function Resolve-LatestColdStartFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ExecutionRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug
    )

    $records = @(Get-DispatchRunRecordList -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug)
    if ($records.Count -eq 0) {
        return $null
    }
    $classifiedRecords = @($records | ForEach-Object {
            [pscustomobject]@{
                record = $_
                classification = Get-DispatchRunRecordStartClassification -Record $_
            }
        })
    $latest = @(
        $classifiedRecords | Sort-Object -Property @(
            @{ Expression = { ConvertTo-DispatchTimestamp -Value $_.record.created_at_utc }; Descending = $true }
            @{ Expression = { $_.record.run_id }; Descending = $true }
        )
    )[0]
    $latestRecord = $latest.record
    if ($latestRecord.launch_state -ne 'launch-failed' -or $latest.classification.classification -ne 'unstarted-sandbox') {
        throw '同派遣最新 RunRecord 不是 launch-failed，拒絕另建 cold-start。'
    }
    $pidCheck = Get-PidCheckResult -SourceRoot $SourceRoot -LineSlug $LineSlug -WriteMode 'readonly'
    $blockingPidRecords = @(Get-BlockingDispatchPidRecords -PidCheckResult $pidCheck -DispatchSlug $DispatchSlug)
    if ($blockingPidRecords.Count -gt 0) {
        throw (New-DispatchPidIdentityBlockedMessage -DispatchSlug $DispatchSlug -Records $blockingPidRecords)
    }
    return $latestRecord
}

function Resolve-PreviousDispatchRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ExecutionRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [Parameter(Mandatory)][string]$ResumeThreadId,
        [string]$LastMessagePath
    )

    $recordsList = @(Get-DispatchRunRecordList -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug)
    if ($recordsList.Count -eq 0) { throw '續行缺少 RunRecord。' }
    $records = @{}
    foreach ($record in $recordsList) {
        $records[$record.run_id] = $record
    }
    $childrenByParent = @{}
    $parentByRun = @{}
    foreach ($record in $recordsList) {
        $parentId = [string](Get-DispatchJsonProperty -Object $record -Name 'attempt_parent_run_id')
        if ([string]::IsNullOrWhiteSpace($parentId)) {
            $parentId = [string](Get-DispatchJsonProperty -Object $record -Name 'previous_run_id')
        }
        if ([string]::IsNullOrWhiteSpace($parentId)) {
            $parentId = $null
        }
        $parentByRun[$record.run_id] = $parentId
        if ($null -ne $parentId) {
            if ($childrenByParent.ContainsKey($parentId)) { throw 'RunRecord 存在分支。' }
            $childrenByParent[$parentId] = $record.run_id
        }
    }
    foreach ($parentId in @($parentByRun.Values | Where-Object { $null -ne $_ } | Sort-Object -Unique)) {
        if (-not $records.ContainsKey($parentId)) { throw 'RunRecord 斷鏈。' }
    }
    $tails = @($recordsList | Where-Object { -not $childrenByParent.ContainsKey($_.run_id) })
    if ($tails.Count -ne 1) { throw 'RunRecord 必須有唯一鏈尾。' }
    $tail = $tails[0]
    $chain = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $current = $tail
    while ($null -ne $current) {
        if ($seen.ContainsKey($current.run_id)) { throw 'RunRecord 存在循環。' }
        $seen[$current.run_id] = $true
        $chain.Add($current)
        $parentId = $parentByRun[$current.run_id]
        if ($null -eq $parentId) { break }
        $current = $records[$parentId]
    }
    if ($seen.Count -ne $recordsList.Count) { throw 'RunRecord 存在不相連的紀錄或循環。' }

    $startClassifications = @{}
    foreach ($candidate in @($chain.ToArray())) {
        $classification = Get-DispatchRunRecordStartClassification -Record $candidate
        $startClassifications[$candidate.run_id] = $classification
        if ($candidate.launch_state -eq 'launch-failed' -and $classification.classification -eq 'unknown') {
            throw ('UnknownRunRecordStartClassification：run_id={0}; reason={1}; phase={2}; failure_stage={3}; process_started={4}' -f $candidate.run_id, $classification.reason, [string]$classification.phase, [string]$classification.failure_stage, [string]$classification.process_started)
        }
    }

    for ($index = 0; $index -lt $chain.Count - 1; $index++) {
        $child = $chain[$index]
        $parent = $chain[$index + 1]
        if ($child.launch_state -eq 'launch-failed' -or $parent.launch_state -eq 'launch-failed') {
            continue
        }
        $parentEvents = Get-DispatchRunEvents -Record $parent
        if ($child.requested_thread_id -cne $parentEvents.ThreadId) { throw 'RunRecord 前後輪 thread 不一致。' }
        if ([string]::IsNullOrWhiteSpace([string]$child.scope_plan_path) -or [string]::IsNullOrWhiteSpace([string]$parent.scope_plan_path)) {
            throw 'RunRecord 前後輪 ScopePlan 不一致。'
        }
        $childScopePlanSelection = [string](Get-DispatchJsonProperty -Object $child -Name 'scope_plan_selection')
        $childScopePlanParentPath = [string](Get-DispatchJsonProperty -Object $child -Name 'scope_plan_parent_path')
        $childScopePlanParentSha256 = [string](Get-DispatchJsonProperty -Object $child -Name 'scope_plan_parent_sha256')
        $childScopePlanParentRunId = [string](Get-DispatchJsonProperty -Object $child -Name 'scope_plan_parent_run_id')
        $isScopePlanSubsetChild = [string]::Equals($childScopePlanSelection, 'subset', [StringComparison]::Ordinal) -and
            -not [string]::IsNullOrWhiteSpace($childScopePlanParentPath) -and
            -not [string]::IsNullOrWhiteSpace($childScopePlanParentSha256) -and
            -not [string]::IsNullOrWhiteSpace($childScopePlanParentRunId)
        if ($isScopePlanSubsetChild) {
            if (-not [string]::Equals((Resolve-AbsolutePath -Path $childScopePlanParentPath), (Resolve-AbsolutePath -Path ([string]$parent.scope_plan_path)), [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals($childScopePlanParentSha256, [string]$parent.scope_plan_sha256, [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals($childScopePlanParentRunId, [string]$parent.run_id, [StringComparison]::OrdinalIgnoreCase) -or
                [string]::Equals([string]$child.scope_plan_path, $childScopePlanParentPath, [StringComparison]::OrdinalIgnoreCase) -or
                [string]::Equals([string]$child.scope_plan_sha256, $childScopePlanParentSha256, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'RunRecord 子集 ScopePlan 父計畫綁定不一致。'
            }
        }
        elseif ($child.scope_plan_path -ne $parent.scope_plan_path -or $child.scope_plan_sha256 -ne $parent.scope_plan_sha256) {
            throw 'RunRecord 前後輪 ScopePlan 不一致。'
        }
    }

    $interruptedUnknownRecords = @(Get-RecoveryChainInterruptedUnknownRecords -Records @($chain.ToArray()))
    if ($interruptedUnknownRecords.Count -gt 0) {
        $unknownRecord = $interruptedUnknownRecords[0]
        $unknownEvents = $null
        try {
            $unknownEvents = Get-DispatchRunEvents -Record $unknownRecord
        }
        catch {
            $unknownEvents = [ordered]@{
                path = $unknownRecord.event_stream_path
                error = $_.Exception.Message
            }
        }
        throw (New-InterruptedUnknownResumeRejectedException -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -Record $unknownRecord -Events $unknownEvents)
    }

    $anchor = $null
    $anchorEvents = $null
    $latestActualStartRecord = $null
    $latestActualStartEvents = $null
    $preparedAnchor = $null
    $preparedAnchorEvents = $null
    foreach ($candidate in @($chain.ToArray())) {
        $classification = $startClassifications[$candidate.run_id]
        if ($classification.classification -eq 'unstarted-sandbox') { continue }
        if ($candidate.launch_state -eq 'launch-failed') { continue }
        $candidateEvents = Get-DispatchRunEvents -Record $candidate
        if ($candidateEvents.ThreadId -cne $ResumeThreadId) { continue }
        if ($classification.classification -eq 'actual-start') {
            if ($null -eq $latestActualStartRecord) {
                $latestActualStartRecord = $candidate
                $latestActualStartEvents = $candidateEvents
            }
            if ($null -eq $anchor) {
                $anchor = $candidate
                $anchorEvents = $candidateEvents
            }
        }
        elseif ($candidate.launch_state -eq 'prepared' -and $null -eq $preparedAnchor) {
            $preparedAnchor = $candidate
            $preparedAnchorEvents = $candidateEvents
        }
    }
    if ($null -eq $anchor -and $null -ne $preparedAnchor) {
        $anchor = $preparedAnchor
        $anchorEvents = $preparedAnchorEvents
    }
    if ($null -eq $anchor) {
        throw 'NoValidResumeAnchor：找不到與 ResumeThreadId 相符的有效 anchor。'
    }

    $scopePlanRootRecord = @(
        @($chain.ToArray()) |
            Where-Object {
                [string]::Equals([string](Get-DispatchJsonProperty -Object $_ -Name 'scope_plan_selection'), 'root', [StringComparison]::OrdinalIgnoreCase) -and
                -not [string]::IsNullOrWhiteSpace([string](Get-DispatchJsonProperty -Object $_ -Name 'scope_plan_path'))
            } |
            Select-Object -Last 1
    )
    if ($scopePlanRootRecord.Count -eq 0) {
        $scopePlanRootRecord = @($anchor)
    }

    $pidCheck = Get-PidCheckResult -SourceRoot $SourceRoot -LineSlug $LineSlug -WriteMode 'readonly'
    $blockingPidRecords = @(Get-BlockingDispatchPidRecords -PidCheckResult $pidCheck -DispatchSlug $DispatchSlug)
    if ($blockingPidRecords.Count -gt 0) {
        throw (New-DispatchPidIdentityBlockedMessage -DispatchSlug $DispatchSlug -Records $blockingPidRecords)
    }
    if (-not (Test-Path -LiteralPath $anchor.pid_record_path -PathType Leaf) -and -not $anchorEvents.Terminal) { throw '鏈尾缺少 PID 停止證據。' }
    if (-not [string]::IsNullOrWhiteSpace($LastMessagePath) -and -not [string]::Equals((Resolve-AbsolutePath $LastMessagePath), $anchor.last_message_path, [StringComparison]::OrdinalIgnoreCase)) { throw '續行顯式 last-message 與鏈尾不一致。' }
    $handoffPath = $anchor.last_message_path
    $handoffSourceType = 'last-message'
    if (Test-Path -LiteralPath $handoffPath -PathType Leaf) {
        $message = Read-DispatchUtf8Text -Path $handoffPath
    }
    else {
        $checkpointPath = [string](Get-DispatchJsonProperty -Object $anchor -Name 'interruption_checkpoint_path')
        $checkpoint = $null
        if ($anchorEvents.LastEventType -ceq 'turn.failed' -and -not [string]::IsNullOrWhiteSpace($checkpointPath)) {
            $anchorPlan = Read-ScopePlanFile -Path $anchor.scope_plan_path
            $checkpoint = Get-DispatchInterruptionCheckpoint -Path $checkpointPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId $anchor.run_id -SelectedUnits @($anchorPlan.selected_units) -SourcePath @($anchor.scope_plan_path, $anchor.event_stream_path)
        }
        if ($null -eq $checkpoint -or $checkpoint.status -cne 'available') {
            if ([string]::IsNullOrWhiteSpace($checkpointPath)) {
                $checkpointPath = Get-DispatchInterruptionCheckpointPath -SourceRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId $anchor.run_id
            }
            $exception = New-Object InvalidOperationException('ResumeHandoffUnavailable：前輪 last-message 與有效中斷檢查點不可用；last-message=' + $anchor.last_message_path + '; interruption-checkpoint=' + $checkpointPath)
            $exception.Data['errorCode'] = 'ResumeHandoffUnavailable'
            throw $exception
        }
        $handoffPath = $checkpoint.path
        $handoffSourceType = 'interruption-checkpoint'
        $confirmed = if (@($checkpoint.confirmed_units).Count -eq 0) { '尚無已確認完成單位。' } else { (@($checkpoint.confirmed_units | ForEach-Object { $_.unit + '：' + ($_.confirmed_result -replace '\r?\n', ' ') }) -join '；') }
        $incomplete = if (@($checkpoint.incomplete_units).Count -eq 0) { '無' } else { $checkpoint.incomplete_units -join '、' }
        $message = '已確認結論：' + $confirmed + [Environment]::NewLine +
            '未完成單位：' + $incomplete + [Environment]::NewLine +
            '證據位置：' + $handoffPath + [Environment]::NewLine +
            '[前輪已驗證中斷檢查點]' + [Environment]::NewLine + ($checkpoint | ConvertTo-Json -Depth 20)
    }
    if ([string]::IsNullOrWhiteSpace($message)) { throw '續行 last-message 為空。' }
    if (-not $anchorEvents.Completed) {
        foreach ($name in @('已確認結論', '未完成單位', '證據位置')) {
            $match = [regex]::Match($message, ('(?m)^[ \t-]*' + [regex]::Escape($name) + '[ \t]*[:：][ \t]*(?<value>[^\r\n]+)\r?$'))
            if (-not $match.Success -or [string]::IsNullOrWhiteSpace($match.Groups['value'].Value)) { throw "續行 last-message 缺少必要交接欄位：$name" }
        }
    }
    $skippedAttempts = @(
        @($chain.ToArray()) |
            Where-Object { $_.launch_state -eq 'launch-failed' } |
            ForEach-Object {
                $failure = Get-DispatchJsonProperty -Object $_ -Name 'failure'
                $classification = $startClassifications[$_.run_id]
                [ordered]@{
                    run_id = $_.run_id
                    classification = $classification.classification
                    classification_reason = $classification.reason
                    phase = Get-DispatchJsonProperty -Object $failure -Name 'phase'
                    reason_code = Get-DispatchJsonProperty -Object $failure -Name 'reason_code'
                    message = Get-DispatchJsonProperty -Object $failure -Name 'message'
                    original_output = Get-DispatchJsonProperty -Object $failure -Name 'original_output'
                }
            }
    )
    [array]::Reverse($skippedAttempts)
    return [pscustomobject]@{
        Record = $tail
        AnchorRecord = $anchor
        ChainTailRecord = $tail
        LatestActualStartRecord = $latestActualStartRecord
        LatestActualStartEvents = $latestActualStartEvents
        ScopePlanRootRecord = $scopePlanRootRecord[0]
        SkippedAttempts = @($skippedAttempts)
        StartClassifications = @($chain.ToArray() | ForEach-Object {
                [ordered]@{
                    run_id = $_.run_id
                    classification = $startClassifications[$_.run_id].classification
                    reason = $startClassifications[$_.run_id].reason
                }
            })
        Message = $message
        HandoffPath = $handoffPath
        HandoffSourceType = $handoffSourceType
        ResumeThreadId = $ResumeThreadId
    }
}

function Get-DispatchRecoverableArtifactState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$RunRecord,

        [string[]]$ConclusionReportPath = @()
    )

    $state = [ordered]@{
        applicable = $false
        base_sha = $null
        recoverable_artifacts_present = $false
        recoverable_artifact_files = @()
    }

    foreach ($reportPathValue in @($ConclusionReportPath)) {
        if ([string]::IsNullOrWhiteSpace([string]$reportPathValue)) {
            continue
        }
        try {
            $resolvedReportPath = Resolve-AbsolutePath -Path ([string]$reportPathValue)
            if (Test-Path -LiteralPath $resolvedReportPath -PathType Leaf) {
                return $state
            }
        }
        catch {
            continue
        }
    }

    $eventPath = [string](Get-DispatchJsonProperty -Object $RunRecord -Name 'event_stream_path')
    if ([string]::IsNullOrWhiteSpace($eventPath) -or -not (Test-Path -LiteralPath $eventPath -PathType Leaf)) {
        return $state
    }

    $eventEvidence = Get-DispatchEventEvidence -EventPath $eventPath
    if ([string](Get-DispatchJsonProperty -Object $eventEvidence -Name 'last_event_type') -cne 'turn.failed') {
        return $state
    }
    $state.applicable = $true

    $baselinePath = [string](Get-DispatchJsonProperty -Object $RunRecord -Name 'baseline_path')
    $baselineSha256 = [string](Get-DispatchJsonProperty -Object $RunRecord -Name 'baseline_sha256')
    if ([string]::IsNullOrWhiteSpace($baselinePath) -or $baselineSha256 -notmatch '^[a-fA-F0-9]{64}$') {
        return $state
    }

    try {
        $baselineDocument = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $baselinePath)
        $baseSha = [string](Get-DispatchJsonProperty -Object $baselineDocument -Name 'base_sha')
        if ([string]::IsNullOrWhiteSpace($baseSha)) {
            return $state
        }

        $sourceRoot = [string](Get-DispatchJsonProperty -Object $RunRecord -Name 'source_root')
        $dispatchRoot = [string](Get-DispatchJsonProperty -Object $RunRecord -Name 'execution_root')
        $lineSlug = [string](Get-DispatchJsonProperty -Object $RunRecord -Name 'line_slug')
        $dispatchSlug = [string](Get-DispatchJsonProperty -Object $RunRecord -Name 'dispatch_slug')
        $baseline = Read-DispatchBaseline -Path $baselinePath -Sha256 $baselineSha256 -SourceRoot $sourceRoot -DispatchRoot $dispatchRoot -LineSlug $lineSlug -DispatchSlug $dispatchSlug -BaseSha $baseSha
        $changedFiles = @(Get-DispatchIncrementalChanges -Baseline $baseline -DispatchRoot $dispatchRoot)
        $state.base_sha = $baseSha
        $state.recoverable_artifact_files = @($changedFiles)
        $state.recoverable_artifacts_present = $changedFiles.Count -gt 0
    }
    catch {
        return $state
    }

    return $state
}
function Resolve-InspectDispatchRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ExecutionRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [Parameter(Mandatory)][string]$EventStreamPath,
        [AllowEmptyString()][string]$ScopePlanPath,
        [string]$RunRecordPath
    )

    $directory = Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    $paths = @($RunRecordPath)
    if ([string]::IsNullOrWhiteSpace($RunRecordPath)) { $paths = @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -ErrorAction Stop | Select-Object -ExpandProperty FullName) }
    $matches = @(
        foreach ($path in $paths) {
            $record = Read-DispatchRunRecord -Path $path -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
            if ([string]::Equals($record.event_stream_path, (Resolve-AbsolutePath $EventStreamPath), [StringComparison]::OrdinalIgnoreCase)) { [pscustomobject]@{ Record = $record; Path = $path } }
        }
    )
    if ($matches.Count -ne 1) { throw 'Inspect 事件必須精確對應唯一 RunRecord。' }
    $match = $matches[0]
    if ($match.Record.launch_state -eq 'launch-failed') {
        if (-not [string]::IsNullOrWhiteSpace($ScopePlanPath) -and -not [string]::IsNullOrWhiteSpace([string]$match.Record.scope_plan_path) -and -not [string]::Equals($match.Record.scope_plan_path, (Resolve-AbsolutePath $ScopePlanPath), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Inspect ScopePlan 與 RunRecord 不一致。'
        }
        return $match
    }
    if ([string]::IsNullOrWhiteSpace($ScopePlanPath)) { throw 'Inspect 必須提供 ScopePlanPath。' }
    if (-not [string]::Equals($match.Record.scope_plan_path, (Resolve-AbsolutePath $ScopePlanPath), [StringComparison]::OrdinalIgnoreCase)) { throw 'Inspect ScopePlan 與 RunRecord 不一致。' }
    $null = Get-DispatchRunEvents $match.Record
    return $match
}

function New-DispatchIdentityDifference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Field,
        [AllowNull()][object]$Expected,
        [AllowNull()][object]$Received,
        [Parameter(Mandatory)][string]$Source
    )

    return [ordered]@{
        field = $Field
        expected = $Expected
        received = $Received
        source = $Source
    }
}

function Get-DispatchFinalMessageIdentity {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Message,
        [AllowEmptyString()][string]$RequiredIdentifier,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$Source
    )

    $messageText = if ($null -eq $Message) { '' } else { $Message.Trim() }
    $tokens = @($messageText -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $requiredIndex = -1
    if (-not [string]::IsNullOrWhiteSpace($RequiredIdentifier)) {
        $wrapperCharacters = [char[]]@([char]96, [char]34, [char]39, [char]91, [char]93, [char]40, [char]41, [char]0x2018, [char]0x2019, [char]0x201C, [char]0x201D, [char]0x300C, [char]0x300D, [char]0x300E, [char]0x300F)
        $trailingPunctuationCharacters = [char[]]@(',', '.', ';', ':', '!', '?', '，', '、', '。', '；', '：', '！', '？', '…')
        for ($index = 0; $index -lt $tokens.Count; $index++) {
            $normalizedToken = [string]$tokens[$index]
            $normalizedToken = [regex]::Replace($normalizedToken, '^(?i:requiredIdentifier|required_identifier|dispatchOrderPath|派遣單(?:路徑)?)[:：=]', '')
            $linkMatch = [regex]::Match($normalizedToken, '^\[(?<label>[^\]]+)\]\([^)]*\)$')
            if ($linkMatch.Success) { $normalizedToken = $linkMatch.Groups['label'].Value }
            do {
                $previousNormalizedToken = $normalizedToken
                $normalizedToken = $normalizedToken.Trim($wrapperCharacters)
                $normalizedToken = $normalizedToken.TrimStart([char[]]@(':', '：', '='))
                $normalizedToken = $normalizedToken.TrimEnd($trailingPunctuationCharacters)
            } while ($normalizedToken.Length -lt $previousNormalizedToken.Length)

            $matchesRequiredIdentifier = [string]::Equals($normalizedToken, $RequiredIdentifier, [System.StringComparison]::Ordinal)
            if (-not $matchesRequiredIdentifier) {
                $lastPathSeparatorIndex = [Math]::Max($normalizedToken.LastIndexOf([char]92), $normalizedToken.LastIndexOf([char]47))
                if ($lastPathSeparatorIndex -ge 0) {
                    $pathFileName = $normalizedToken.Substring($lastPathSeparatorIndex + 1)
                    $matchesRequiredIdentifier = [string]::Equals($pathFileName, $RequiredIdentifier, [System.StringComparison]::Ordinal)
                }
            }

            if ($matchesRequiredIdentifier) {
                $requiredIndex = $index
                break
            }
        }
    }

    $dispatchMatch = [regex]::Match($messageText, '(?i)(?:dispatchSlug|dispatch_slug)[ \t]*[:：=][ \t]*[`"''\[]?(?<value>[a-z0-9]+(?:-[a-z0-9]+)*)(?![a-z0-9-])')
    $lineMatch = [regex]::Match($messageText, '(?i)(?:lineSlug|line_slug)[ \t]*[:：=][ \t]*[`"''\[]?(?<value>[a-z0-9]+(?:-[a-z0-9]+)*)(?![a-z0-9-])')
    $receivedDispatch = if ($dispatchMatch.Success) { $dispatchMatch.Groups['value'].Value } else { $null }
    $receivedLine = if ($lineMatch.Success) { $lineMatch.Groups['value'].Value } else { $null }

    if (-not $dispatchMatch.Success -and -not $lineMatch.Success -and $requiredIndex -ge 0) {
        if ($requiredIndex + 1 -lt $tokens.Count) { $receivedDispatch = [string]$tokens[$requiredIndex + 1] }
        if ($requiredIndex + 2 -lt $tokens.Count) { $receivedLine = [string]$tokens[$requiredIndex + 2] }
    }
    elseif (-not $dispatchMatch.Success -and $requiredIndex -ge 0 -and $requiredIndex + 1 -lt $tokens.Count) {
        $receivedDispatch = [string]$tokens[$requiredIndex + 1]
    }
    elseif (-not $lineMatch.Success -and $requiredIndex -ge 0 -and $requiredIndex + 2 -lt $tokens.Count) {
        $receivedLine = [string]$tokens[$requiredIndex + 2]
    }

    $mismatches = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($RequiredIdentifier) -and $requiredIndex -lt 0) {
        $missing.Add('required_identifier')
        $mismatches.Add((New-DispatchIdentityDifference -Field 'final_message.required_identifier' -Expected $RequiredIdentifier -Received $null -Source $Source))
    }
    if ([string]::IsNullOrWhiteSpace($receivedDispatch)) {
        $missing.Add('dispatchSlug')
        $mismatches.Add((New-DispatchIdentityDifference -Field 'final_message.dispatchSlug' -Expected $DispatchSlug -Received $null -Source $Source))
    }
    elseif (-not [string]::Equals($receivedDispatch, $DispatchSlug, [System.StringComparison]::Ordinal)) {
        $mismatches.Add((New-DispatchIdentityDifference -Field 'final_message.dispatchSlug' -Expected $DispatchSlug -Received $receivedDispatch -Source $Source))
    }
    if ([string]::IsNullOrWhiteSpace($receivedLine)) {
        $missing.Add('lineSlug')
        $mismatches.Add((New-DispatchIdentityDifference -Field 'final_message.lineSlug' -Expected $LineSlug -Received $null -Source $Source))
    }
    elseif (-not [string]::Equals($receivedLine, $LineSlug, [System.StringComparison]::Ordinal)) {
        $mismatches.Add((New-DispatchIdentityDifference -Field 'final_message.lineSlug' -Expected $LineSlug -Received $receivedLine -Source $Source))
    }

    return [ordered]@{
        valid = $mismatches.Count -eq 0
        fields = [ordered]@{
            required_identifier = $RequiredIdentifier
            dispatchSlug = $receivedDispatch
            lineSlug = $receivedLine
        }
        missing = @($missing.ToArray())
        mismatches = @($mismatches.ToArray())
    }
}

function Get-DispatchIdentityProperty {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string[]]$Names
    )

    foreach ($name in $Names) {
        $value = Get-DispatchJsonProperty -Object $Object -Name $name
        if ($null -ne $value) {
            return $value
        }
    }
    return $null
}

function ConvertTo-DispatchIdentityPath {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    try {
        return Resolve-AbsolutePath -Path ([string]$Value)
    }
    catch {
        return [string]$Value
    }
}

function Add-DispatchIdentityComparison {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Differences,
        [Parameter(Mandatory)][string]$Field,
        [AllowNull()][object]$Expected,
        [AllowNull()][object]$Received,
        [Parameter(Mandatory)][string]$Source,
        [switch]$PathComparison
    )

    $expectedText = if ($null -eq $Expected) { $null } else { [string]$Expected }
    $receivedText = if ($null -eq $Received) { $null } else { [string]$Received }
    $equal = if ($PathComparison) {
        $expectedPath = ConvertTo-DispatchIdentityPath -Value $Expected
        $receivedPath = ConvertTo-DispatchIdentityPath -Value $Received
        $null -eq $expectedPath -and $null -eq $receivedPath -or
        ($null -ne $expectedPath -and $null -ne $receivedPath -and [string]::Equals($expectedPath, $receivedPath, [StringComparison]::OrdinalIgnoreCase))
    }
    else {
        $null -eq $Expected -and $null -eq $Received -or
        ($null -ne $Expected -and $null -ne $Received -and [string]::Equals($expectedText, $receivedText, [StringComparison]::Ordinal))
    }
    if (-not $equal) {
        $Differences.Add((New-DispatchIdentityDifference -Field $Field -Expected $Expected -Received $Received -Source $Source))
    }
}

function Get-DispatchRequiredIdentifier {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$ConfiguredIdentifier,

        [AllowEmptyString()]
        [string]$DispatchKind,

        [AllowEmptyString()]
        [string]$TaskType,

        [AllowEmptyString()]
        [string]$EvidencePackPath,

        [AllowEmptyCollection()]
        [string[]]$TargetPath = @()
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredIdentifier)) {
        return $ConfiguredIdentifier
    }
    if ([string]::Equals($DispatchKind, 'workflow', [System.StringComparison]::Ordinal)) {
        return 'design.md'
    }
    if ([string]::Equals($TaskType, 'advisor-consult', [System.StringComparison]::Ordinal)) {
        if ([string]::IsNullOrWhiteSpace($EvidencePackPath)) {
            throw 'advisor-consult 必須以 evidence pack 檔名作為 requiredIdentifier。'
        }
        $evidenceFileName = [System.IO.Path]::GetFileName($EvidencePackPath)
        if ([string]::IsNullOrWhiteSpace($evidenceFileName)) {
            throw 'advisor-consult evidence pack 路徑沒有可用檔名。'
        }
        return $evidenceFileName
    }

    foreach ($target in @($TargetPath)) {
        if ([string]::IsNullOrWhiteSpace([string]$target)) {
            continue
        }
        $targetFileName = [System.IO.Path]::GetFileName([string]$target)
        if (-not [string]::IsNullOrWhiteSpace($targetFileName)) {
            return $targetFileName
        }
    }

    throw '派遣缺少可產生 requiredIdentifier 的目標路徑。'
}

function Get-DispatchCollectIdentityRunRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ExecutionRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [string]$RunRecordPath
    )

    $candidatePath = $RunRecordPath
    if ([string]::IsNullOrWhiteSpace($candidatePath)) {
        return $null
    }

    return [ordered]@{
        path = Resolve-AbsolutePath -Path $candidatePath
        record = $null
        error = $null
    }
}

function Resolve-DispatchCollectIdentityRequestSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$LatestRecord,
        [Parameter(Mandatory)][string]$LatestRunRecordPath,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ExecutionRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug
    )

    $chain = Get-RecoveryChainModel -LatestRecord $LatestRecord -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    $runDirectory = Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    foreach ($candidate in @($chain.records)) {
        $launchState = [string](Get-DispatchJsonProperty -Object $candidate -Name 'launch_state')
        $unknownInterruption = [string](Get-DispatchJsonProperty -Object (Get-DispatchJsonProperty -Object $candidate -Name 'unknown_interruption') -Name 'status')
        if ($launchState -eq 'launch-failed' -or $unknownInterruption -eq 'InterruptedUnknown') {
            continue
        }

        $candidateRequestPath = [string](Get-DispatchJsonProperty -Object $candidate -Name 'request_path')
        $candidateRequestSha256 = [string](Get-DispatchJsonProperty -Object $candidate -Name 'request_sha256')
        if ([string]::IsNullOrWhiteSpace($candidateRequestPath) -or [string]::IsNullOrWhiteSpace($candidateRequestSha256)) {
            continue
        }

        $candidateRunId = [string](Get-DispatchJsonProperty -Object $candidate -Name 'run_id')
        $candidatePath = if ([string]::Equals($candidateRunId, [string](Get-DispatchJsonProperty -Object $LatestRecord -Name 'run_id'), [StringComparison]::OrdinalIgnoreCase)) {
            Resolve-AbsolutePath -Path $LatestRunRecordPath
        }
        else {
            Join-Path -Path $runDirectory -ChildPath ($candidateRunId + '.json')
        }
        return [ordered]@{
            status = 'found'
            source = if ([string]::Equals($candidateRunId, [string](Get-DispatchJsonProperty -Object $LatestRecord -Name 'run_id'), [StringComparison]::OrdinalIgnoreCase)) { 'latest' } else { 'ancestor' }
            run_id = $candidateRunId
            path = $candidatePath
            launch_state = $launchState
            request_path = Resolve-AbsolutePath -Path $candidateRequestPath
            request_sha256 = $candidateRequestSha256
            request_operation = [string](Get-DispatchJsonProperty -Object $candidate -Name 'request_operation')
            skipped_attempts = @($chain.skipped_attempts)
            chain_fingerprint = [string]$chain.fingerprint
        }
    }

    return [ordered]@{
        status = 'missing'
        source = 'none'
        run_id = $null
        path = $null
        launch_state = $null
        request_path = $null
        request_sha256 = $null
        request_operation = $null
        skipped_attempts = @($chain.skipped_attempts)
        chain_fingerprint = [string]$chain.fingerprint
    }
}

function Get-DispatchCollectInterruptionIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$RunRecord,
        [Parameter(Mandatory)][string]$RunRecordPath,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ExecutionRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug
    )

    $runId = [string](Get-DispatchJsonProperty -Object $RunRecord -Name 'run_id')
    $scopePlanPath = [string](Get-DispatchJsonProperty -Object $RunRecord -Name 'scope_plan_path')
    $eventStreamPath = [string](Get-DispatchJsonProperty -Object $RunRecord -Name 'event_stream_path')
    $result = [ordered]@{
        status = 'unavailable'
        run_id = $runId
        run_record_path = $RunRecordPath
        event_stream_path = $eventStreamPath
        checkpoint = $null
        reason = $null
    }

    try {
        if ([string]::IsNullOrWhiteSpace($runId) -or [string]::IsNullOrWhiteSpace($scopePlanPath) -or [string]::IsNullOrWhiteSpace($eventStreamPath)) {
            throw 'RunRecord 缺少 run_id、scope_plan_path 或 event_stream_path。'
        }

        $scopePlan = Read-ScopePlanFile -Path $scopePlanPath
        $selectedUnits = @($scopePlan.selected_units | ForEach-Object { [string]$_ })
        $checkpointPath = [string](Get-DispatchJsonProperty -Object $RunRecord -Name 'interruption_checkpoint_path')
        if ([string]::IsNullOrWhiteSpace($checkpointPath)) {
            $checkpointPath = Get-DispatchInterruptionCheckpointPath -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId $runId
        }
        $checkpoint = Get-DispatchInterruptionCheckpoint -Path $checkpointPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId $runId -SelectedUnits $selectedUnits -SourcePath @($scopePlanPath, $RunRecordPath, $eventStreamPath)
        $result.checkpoint = $checkpoint
        if ([string]$checkpoint.status -cne 'available') {
            $result.status = 'unavailable'
            $result.reason = [string]$checkpoint.validation_error
            return $result
        }

        $resolvedEventStreamPath = Resolve-AbsolutePath -Path $eventStreamPath
        if (-not (Test-Path -LiteralPath $resolvedEventStreamPath -PathType Leaf)) {
            throw 'RunRecord event_stream_path 不存在。'
        }
        $events = New-Object 'System.Collections.Generic.List[object]'
        $eventStreamContent = Read-DispatchUtf8Text -Path $resolvedEventStreamPath
        foreach ($line in [regex]::Split($eventStreamContent, '\r?\n')) {
            if ([string]::IsNullOrWhiteSpace([string]$line)) {
                continue
            }
            $events.Add((ConvertFrom-DispatchJson -Content ([string]$line)))
        }
        if ($events.Count -eq 0) {
            throw 'RunRecord event_stream_path 沒有可解析的事件。'
        }

        $latestThreadId = ''
        $terminalEventFound = $false
        foreach ($event in $events) {
            $eventType = [string](Get-DispatchJsonProperty -Object $event -Name 'type')
            if ($eventType -eq 'turn.completed' -or $eventType -eq 'turn.failed') {
                $terminalEventFound = $true
            }
            if ($eventType -eq 'thread.started') {
                $latestThreadId = [string](Get-DispatchJsonProperty -Object $event -Name 'thread_id')
            }
        }

        $expectedThreadId = [string](Get-DispatchJsonProperty -Object $RunRecord -Name 'thread_id')
        if ([string]::IsNullOrWhiteSpace($expectedThreadId) -or -not [string]::Equals($latestThreadId, $expectedThreadId, [System.StringComparison]::Ordinal)) {
            throw '事件流最新 thread.started 與 RunRecord thread_id 不一致。'
        }
        if ($terminalEventFound) {
            $result.status = 'terminal'
            $result.reason = '事件流已包含 turn.completed 或 turn.failed。'
            return $result
        }

        $result.status = 'interrupted'
        return $result
    }
    catch {
        $result.status = 'invalid'
        $result.reason = $_.Exception.Message
        return $result
    }
}

function Test-DispatchCollectIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ExecutionRoot,
        [Parameter(Mandatory)][string]$DispatchRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [AllowEmptyString()][string]$RequiredIdentifier,
        [AllowEmptyString()][string]$BaseSha,
        [AllowNull()][object]$Preflight,
        [string]$PreflightPath,
        [string]$RequestPath,
        [string]$RunRecordPath,
        [string]$ReviewerReportPath,
        [ValidateSet('Collect')][string]$Operation = 'Collect'
    )

    $differences = New-Object 'System.Collections.Generic.List[object]'
    $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
    $executionRootPath = Resolve-AbsolutePath -Path $ExecutionRoot
    $dispatchRootPath = Resolve-AbsolutePath -Path $DispatchRoot
    $expectedRunDirectory = Get-DispatchRunDirectory -SourceRoot $sourceRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    $runRecordInfo = $null
    $runRecord = $null
    try {
        $runRecordInfo = Get-DispatchCollectIdentityRunRecord -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunRecordPath $RunRecordPath
        if ($null -ne $runRecordInfo) {
            $runRecord = Read-DispatchRunRecord -Path $runRecordInfo.path -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug
            $runRecordInfo.record = $runRecord
        }
    }
    catch {
        $recordSource = if ($null -ne $runRecordInfo -and -not [string]::IsNullOrWhiteSpace([string]$runRecordInfo.path)) { [string]$runRecordInfo.path } elseif (-not [string]::IsNullOrWhiteSpace($RunRecordPath)) { $RunRecordPath } else { $expectedRunDirectory }
        $differences.Add((New-DispatchIdentityDifference -Field 'run_record' -Expected 'valid RunRecord bound to current identity' -Received $_.Exception.Message -Source $recordSource))
    }

    $requestIdentitySource = [ordered]@{
        status = 'missing'
        source = 'none'
        run_id = $null
        path = $null
        launch_state = $null
        request_path = $null
        request_sha256 = $null
        request_operation = $null
        skipped_attempts = @()
        chain_fingerprint = $null
    }
    if ($null -ne $runRecord -and $null -ne $runRecordInfo) {
        try {
            $requestIdentitySource = Resolve-DispatchCollectIdentityRequestSource -LatestRecord $runRecord -LatestRunRecordPath $runRecordInfo.path -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        }
        catch {
            $differences.Add((New-DispatchIdentityDifference -Field 'run_record.request_chain' -Expected 'valid RunRecord chain with current line_slug and dispatch_slug' -Received $_.Exception.Message -Source $runRecordInfo.path))
        }
    }

    $finalMessageIdentity = $null
    $interruptionIdentity = $null
    if ($null -ne $runRecord) {
        $interruptionIdentity = Get-DispatchCollectInterruptionIdentity -RunRecord $runRecord -RunRecordPath $runRecordInfo.path -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        if ([string]$interruptionIdentity.status -cne 'interrupted') {
            $lastMessagePath = [string](Get-DispatchJsonProperty -Object $runRecord -Name 'last_message_path')
            if ([string]::IsNullOrWhiteSpace($lastMessagePath)) {
                $differences.Add((New-DispatchIdentityDifference -Field 'final_message' -Expected 'readable final message with dispatchSlug and lineSlug' -Received 'last_message_path missing' -Source $runRecordInfo.path))
            }
            else {
                try {
                    $lastMessagePathValue = Resolve-AbsolutePath -Path $lastMessagePath
                    if (-not (Test-Path -LiteralPath $lastMessagePathValue -PathType Leaf)) {
                        throw 'last-message file 不存在。'
                    }
                    $finalMessage = Read-DispatchUtf8Text -Path $lastMessagePathValue
                    $finalMessageIdentity = Get-DispatchFinalMessageIdentity -Message $finalMessage -RequiredIdentifier $RequiredIdentifier -DispatchSlug $DispatchSlug -LineSlug $LineSlug -Source $lastMessagePathValue
                    foreach ($mismatch in @($finalMessageIdentity.mismatches)) {
                        $differences.Add($mismatch)
                    }
                }
                catch {
                    $differences.Add((New-DispatchIdentityDifference -Field 'final_message' -Expected 'readable final message with dispatchSlug and lineSlug' -Received $_.Exception.Message -Source $lastMessagePath))
                }
            }
        }
    }

    $requestContext = $null
    $requestPathValue = $null
    $recordRequestPath = if ($null -eq $runRecord) { $null } else { [string](Get-DispatchJsonProperty -Object $runRecord -Name 'request_path') }
    if (-not [string]::IsNullOrWhiteSpace($RequestPath)) {
        try { $requestPathValue = Resolve-AbsolutePath -Path $RequestPath } catch { $requestPathValue = $RequestPath }
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$requestIdentitySource.request_path)) {
        $requestPathValue = [string]$requestIdentitySource.request_path
    }
    elseif (-not [string]::IsNullOrWhiteSpace($recordRequestPath)) {
        $requestPathValue = $recordRequestPath
    }
    if (-not [string]::IsNullOrWhiteSpace($requestPathValue)) {
        try {
            $requestContext = Read-DispatchRequest -Path $requestPathValue
        }
        catch {
            $differences.Add((New-DispatchIdentityDifference -Field 'request' -Expected 'readable request file' -Received $_.Exception.Message -Source $requestPathValue))
        }
    }
    if ($null -ne $requestContext) {
        $requestDocument = Get-DispatchJsonProperty -Object $requestContext -Name 'document'
        Add-DispatchIdentityComparison -Differences $differences -Field 'line_slug' -Expected $LineSlug -Received (Get-DispatchIdentityProperty -Object $requestDocument -Names @('line_slug', 'lineSlug')) -Source ([string]$requestContext.path)
        Add-DispatchIdentityComparison -Differences $differences -Field 'dispatch_slug' -Expected $DispatchSlug -Received (Get-DispatchIdentityProperty -Object $requestDocument -Names @('dispatch_slug', 'dispatchSlug')) -Source ([string]$requestContext.path)
        if ($null -ne $runRecord) {
            $recordRequestPathValue = if ($requestIdentitySource.status -eq 'found') { [string]$requestIdentitySource.request_path } else { [string](Get-DispatchJsonProperty -Object $runRecord -Name 'request_path') }
            if (-not [string]::IsNullOrWhiteSpace($recordRequestPathValue)) {
                Add-DispatchIdentityComparison -Differences $differences -Field 'request.path' -Expected (Resolve-AbsolutePath -Path $recordRequestPathValue) -Received ([string]$requestContext.path) -Source ([string]$requestContext.path) -PathComparison
            }
            $recordRequestSha256 = if ($requestIdentitySource.status -eq 'found') { [string]$requestIdentitySource.request_sha256 } else { [string](Get-DispatchJsonProperty -Object $runRecord -Name 'request_sha256') }
            Add-DispatchIdentityComparison -Differences $differences -Field 'request_sha256' -Expected $recordRequestSha256 -Received ([string](Get-DispatchJsonProperty -Object $requestContext -Name 'sha256')) -Source ([string]$requestContext.path)
            $expectedRequestOperation = if ($requestIdentitySource.status -eq 'found') { [string]$requestIdentitySource.request_operation } else { [string](Get-DispatchJsonProperty -Object $runRecord -Name 'request_operation') }
            if ([string]::IsNullOrWhiteSpace($expectedRequestOperation)) { $expectedRequestOperation = $Operation }
            Add-DispatchIdentityComparison -Differences $differences -Field 'operation' -Expected $expectedRequestOperation -Received ([string](Get-DispatchJsonProperty -Object $requestDocument -Name 'operation')) -Source ([string]$requestContext.path)
        }
        else {
            Add-DispatchIdentityComparison -Differences $differences -Field 'operation' -Expected $Operation -Received ([string](Get-DispatchJsonProperty -Object $requestDocument -Name 'operation')) -Source ([string]$requestContext.path)
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($recordRequestPath)) {
        $differences.Add((New-DispatchIdentityDifference -Field 'request' -Expected $recordRequestPath -Received 'unreadable' -Source $recordRequestPath))
    }

    $preflightValue = $Preflight
    $preflightPathValue = $PreflightPath
    if ($null -eq $preflightValue -and [string]::IsNullOrWhiteSpace($preflightPathValue) -and $null -ne $runRecord) {
        $preflightPathValue = [string](Get-DispatchJsonProperty -Object $runRecord -Name 'preflight_result_path')
    }
    if ($null -eq $preflightValue -and -not [string]::IsNullOrWhiteSpace($preflightPathValue)) {
        try {
            $preflightPathValue = Resolve-AbsolutePath -Path $preflightPathValue
            $preflightValue = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $preflightPathValue)
        }
        catch {
            $differences.Add((New-DispatchIdentityDifference -Field 'preflight' -Expected 'readable Preflight result' -Received $_.Exception.Message -Source $preflightPathValue))
        }
    }
    if ($null -ne $preflightValue) {
        $preflightSource = if ([string]::IsNullOrWhiteSpace($preflightPathValue)) { 'preflight result' } else { $preflightPathValue }
        foreach ($entry in @(
                [pscustomobject]@{ field = 'source_root'; names = @('source_root', 'sourceRoot'); expected = $sourceRootPath; path = $true }
                [pscustomobject]@{ field = 'dispatch_root'; names = @('dispatch_root', 'dispatchRoot'); expected = $dispatchRootPath; path = $true }
                [pscustomobject]@{ field = 'execution_root'; names = @('execution_root', 'executionRoot'); expected = $executionRootPath; path = $true }
                [pscustomobject]@{ field = 'line_slug'; names = @('line_slug', 'lineSlug'); expected = $LineSlug; path = $false }
                [pscustomobject]@{ field = 'dispatch_slug'; names = @('dispatch_slug', 'dispatchSlug'); expected = $DispatchSlug; path = $false }
                [pscustomobject]@{ field = 'base_sha'; names = @('base_sha', 'baseSha'); expected = $BaseSha; path = $false })) {
            $received = Get-DispatchIdentityProperty -Object $preflightValue -Names $entry.names
            Add-DispatchIdentityComparison -Differences $differences -Field ('preflight.' + $entry.field) -Expected $entry.expected -Received $received -Source $preflightSource -PathComparison:$entry.path
        }
        if ($null -ne $runRecord -and -not [string]::IsNullOrWhiteSpace($preflightPathValue)) {
            Add-DispatchIdentityComparison -Differences $differences -Field 'preflight.path' -Expected ([string](Get-DispatchJsonProperty -Object $runRecord -Name 'preflight_result_path')) -Received $preflightPathValue -Source $preflightPathValue -PathComparison
            $recordPreflightHash = [string](Get-DispatchJsonProperty -Object $runRecord -Name 'preflight_sha256')
            if (-not [string]::IsNullOrWhiteSpace($recordPreflightHash) -and (Test-Path -LiteralPath $preflightPathValue -PathType Leaf)) {
                Add-DispatchIdentityComparison -Differences $differences -Field 'preflight_sha256' -Expected $recordPreflightHash -Received (Get-FileSha256 -Path $preflightPathValue) -Source $preflightPathValue
            }
        }
    }

    if ($null -ne $runRecord) {
        foreach ($entry in @(
                [pscustomobject]@{ field = 'source_root'; name = 'source_root'; expected = $sourceRootPath; path = $true }
                [pscustomobject]@{ field = 'execution_root'; name = 'execution_root'; expected = $executionRootPath; path = $true }
                [pscustomobject]@{ field = 'line_slug'; name = 'line_slug'; expected = $LineSlug; path = $false }
                [pscustomobject]@{ field = 'dispatch_slug'; name = 'dispatch_slug'; expected = $DispatchSlug; path = $false })) {
            Add-DispatchIdentityComparison -Differences $differences -Field ('run_record.' + $entry.field) -Expected $entry.expected -Received (Get-DispatchJsonProperty -Object $runRecord -Name $entry.name) -Source ($runRecordInfo.path + ':' + $entry.name) -PathComparison:$entry.path
        }
        $runId = [string](Get-DispatchJsonProperty -Object $runRecord -Name 'run_id')
        if (-not [string]::IsNullOrWhiteSpace($runId)) {
            Add-DispatchIdentityComparison -Differences $differences -Field 'run_record.path' -Expected (Join-Path $expectedRunDirectory ($runId + '.json')) -Received $runRecordInfo.path -Source $runRecordInfo.path -PathComparison
        }
        if ($null -ne $requestContext) {
            $runRecordRequestSha256 = if ($requestIdentitySource.status -eq 'found') { [string]$requestIdentitySource.request_sha256 } else { [string](Get-DispatchJsonProperty -Object $runRecord -Name 'request_sha256') }
            $runRecordRequestShaSource = if ($requestIdentitySource.status -eq 'found') { [string]$requestIdentitySource.path + ':request_sha256' } else { $runRecordInfo.path + ':request_sha256' }
            Add-DispatchIdentityComparison -Differences $differences -Field 'run_record.request_sha256' -Expected ([string](Get-DispatchJsonProperty -Object $requestContext -Name 'sha256')) -Received $runRecordRequestSha256 -Source $runRecordRequestShaSource
        }
    }

    $reviewerReport = $null
    $reviewerPathValue = $null
    if (-not [string]::IsNullOrWhiteSpace($ReviewerReportPath)) {
        try {
            $reviewerPathValue = Resolve-AbsolutePath -Path $ReviewerReportPath
            if (-not (Test-Path -LiteralPath $reviewerPathValue -PathType Leaf)) {
                throw 'Reviewer report 不存在。'
            }
            $reviewerReport = Test-ReviewerFindingReport -Path $reviewerPathValue
        }
        catch {
            $reportErrorSource = if ([string]::IsNullOrWhiteSpace($reviewerPathValue)) { $ReviewerReportPath } else { $reviewerPathValue }
            $differences.Add((New-DispatchIdentityDifference -Field 'report.path' -Expected 'readable Reviewer report' -Received $_.Exception.Message -Source $reportErrorSource))
        }
    }
    if ($null -ne $reviewerReport) {
        $expectedReportRoot = Join-Path (Join-Path $executionRootPath '.local\ai-sessions\report') $LineSlug
        if (-not [string]::Equals((Split-Path -Parent $reviewerPathValue), $expectedReportRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $differences.Add((New-DispatchIdentityDifference -Field 'report.path' -Expected $expectedReportRoot -Received $reviewerPathValue -Source $reviewerPathValue))
        }
        Add-DispatchIdentityComparison -Differences $differences -Field 'report.line_slug' -Expected $LineSlug -Received ([string](Get-DispatchJsonProperty -Object $reviewerReport -Name 'line_slug')) -Source $reviewerPathValue
        Add-DispatchIdentityComparison -Differences $differences -Field 'report.dispatch_slug' -Expected $DispatchSlug -Received ([string](Get-DispatchJsonProperty -Object $reviewerReport -Name 'dispatch_slug')) -Source $reviewerPathValue
        $reportRound = Get-DispatchJsonProperty -Object $reviewerReport -Name 'round'
        $expectedRound = if ($null -eq $runRecord) { $null } else { Get-DispatchIdentityProperty -Object $runRecord -Names @('review_round', 'round') }
        if ($null -ne $expectedRound) {
            Add-DispatchIdentityComparison -Differences $differences -Field 'report.round' -Expected ([int64]$expectedRound) -Received ([int64]$reportRound) -Source $reviewerPathValue
        }
        elseif ($null -eq $reportRound -or [int64]$reportRound -le 0) {
            $differences.Add((New-DispatchIdentityDifference -Field 'report.round' -Expected 'positive integer' -Received $reportRound -Source $reviewerPathValue))
        }
        $actualReportHash = Get-FileSha256 -Path $reviewerPathValue
        Add-DispatchIdentityComparison -Differences $differences -Field 'report.sha256' -Expected ([string](Get-DispatchJsonProperty -Object $reviewerReport -Name 'reviewer_report_sha256')) -Received $actualReportHash -Source $reviewerPathValue
        if ($null -ne $runRecord) {
            $recordReportPath = [string](Get-DispatchIdentityProperty -Object $runRecord -Names @('reviewer_report_path', 'report_path'))
            if (-not [string]::IsNullOrWhiteSpace($recordReportPath)) {
                Add-DispatchIdentityComparison -Differences $differences -Field 'run_record.report_path' -Expected (Resolve-AbsolutePath -Path $recordReportPath) -Received $reviewerPathValue -Source $runRecordInfo.path -PathComparison
            }
            $recordReportHash = [string](Get-DispatchIdentityProperty -Object $runRecord -Names @('reviewer_report_sha256', 'report_sha256'))
            if (-not [string]::IsNullOrWhiteSpace($recordReportHash)) {
                Add-DispatchIdentityComparison -Differences $differences -Field 'run_record.report_sha256' -Expected $recordReportHash -Received $actualReportHash -Source $runRecordInfo.path
            }
        }
    }

    return [ordered]@{
        valid = $differences.Count -eq 0
        error_code = if ($differences.Count -eq 0) { $null } else { 'IdentityMismatch' }
        differences = @($differences.ToArray())
        request = $requestContext
        preflight = $preflightValue
        run_record = $runRecord
        run_record_path = if ($null -eq $runRecordInfo) { $null } else { $runRecordInfo.path }
        request_identity_source = $requestIdentitySource
        final_message_identity = $finalMessageIdentity
        interruption_identity = $interruptionIdentity
        reviewer_report = $reviewerReport
        reviewer_report_path = $reviewerPathValue
    }
}

function Throw-DispatchIdentityCollectFailure {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Result)

    $Result['outputValid'] = $false
    $Result['errorCode'] = 'IdentityMismatch'
    $Result['error_code'] = 'IdentityMismatch'
    $Result['reason_code'] = 'IdentityMismatch'
    $differences = @($Result['identityMismatches'])
    $message = 'Collect 身分驗證失敗：' + (($differences | ForEach-Object {
                'field={0}; expected={1}; received={2}; source={3}' -f [string]$_.field, [string]$_.expected, [string]$_.received, [string]$_.source
            }) -join ' | ')
    $exception = New-Object System.InvalidOperationException($message)
    $exception.Data['errorCode'] = 'IdentityMismatch'
    $exception.Data['operationResult'] = $Result
    throw $exception
}
