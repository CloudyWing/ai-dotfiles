function Get-DispatchIgnoredPathLookup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DispatchRoot,
        [Parameter(Mandatory)][string[]]$GitRelativePath,
        [Parameter(Mandatory)][string[]]$SourcePath
    )

    $uniquePaths = New-Object 'System.Collections.Generic.List[string]'
    $uniquePathLookup = @{}
    foreach ($pathValue in $GitRelativePath) {
        $normalizedPath = ([string]$pathValue).Replace([string][char]92, [string][char]47)
        if (-not $uniquePathLookup.ContainsKey($normalizedPath)) {
            $uniquePathLookup[$normalizedPath] = $true
            $uniquePaths.Add($normalizedPath)
        }
    }
    if ($uniquePaths.Count -eq 0) { return @{} }

    $standardInputBuilder = New-Object System.Text.StringBuilder
    foreach ($pathValue in $uniquePaths) {
        $null = $standardInputBuilder.Append($pathValue)
        $null = $standardInputBuilder.Append([char]0)
    }
    $ignoreResult = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('check-ignore', '--stdin', '-z', '--no-index') -StandardInput $standardInputBuilder.ToString() -AllowFailure
    if (($ignoreResult.ExitCode -notin @(0, 1)) -or -not [string]::IsNullOrWhiteSpace($ignoreResult.StdErr)) {
        throw "git check-ignore 批次探針失敗，無法判定 target_path：$($SourcePath -join ', ')；exit code $($ignoreResult.ExitCode)；$($ignoreResult.StdErr.Trim())"
    }

    $ignoredPathLookup = @{}
    $reportedPaths = New-Object 'System.Collections.Generic.List[string]'
    $standardOutput = [string]$ignoreResult.StdOut
    $segmentStart = 0
    for ($index = 0; $index -lt $standardOutput.Length; $index++) {
        if ($standardOutput[$index] -ne [char]0) { continue }
        if ($index -gt $segmentStart) {
            $reportedPaths.Add($standardOutput.Substring($segmentStart, $index - $segmentStart))
        }
        $segmentStart = $index + 1
    }
    if ($segmentStart -lt $standardOutput.Length) {
        $reportedPaths.Add($standardOutput.Substring($segmentStart))
    }
    foreach ($reportedPath in $reportedPaths) {
        $normalizedReportedPath = $reportedPath.Replace([string][char]92, [string][char]47)
        if (-not $uniquePathLookup.ContainsKey($normalizedReportedPath)) {
            throw "git check-ignore 批次探針回傳未提交的路徑：$normalizedReportedPath"
        }
        $ignoredPathLookup[$normalizedReportedPath] = $true
    }
    if (($ignoreResult.ExitCode -eq 0 -and $ignoredPathLookup.Count -eq 0) -or
        ($ignoreResult.ExitCode -eq 1 -and $ignoredPathLookup.Count -gt 0)) {
        throw "git check-ignore 批次探針回傳不一致的結果：$($SourcePath -join ', ')"
    }

    return $ignoredPathLookup
}

function Get-TargetsOutsideRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DispatchRoot,
        [Parameter(Mandatory)][string[]]$TargetPath
    )

    $targetsOutsideRepository = New-Object System.Collections.Generic.List[string]
    $targetRecords = New-Object 'System.Collections.Generic.List[object]'
    $gitRelativePaths = New-Object 'System.Collections.Generic.List[string]'
    $sourcePathsForGit = New-Object 'System.Collections.Generic.List[string]'
    foreach ($target in $TargetPath) {
        $sourceTargetPath = Resolve-SourceTargetPath -Path $target -Root $SourceRoot
        $relativePath = Get-RelativePathFromRoot -Path $sourceTargetPath -Root $SourceRoot
        $dispatchTargetPath = if ($relativePath -eq '.') { $DispatchRoot } else { Join-Path -Path $DispatchRoot -ChildPath $relativePath }
        $targetRecord = [pscustomobject]@{
            SourcePath = $sourceTargetPath
            GitRelativePath = $relativePath.Replace([string][char]92, [string][char]47)
            OutsideRepository = -not (Test-PathWithinRoot -Path $dispatchTargetPath -Root $DispatchRoot)
            IsDirectory = [System.IO.Directory]::Exists($sourceTargetPath)
            ChildFiles = New-Object 'System.Collections.Generic.List[object]'
            ScanError = $null
        }
        $targetRecords.Add($targetRecord)
        if ($targetRecord.OutsideRepository) { continue }

        $gitRelativePaths.Add($targetRecord.GitRelativePath)
        $sourcePathsForGit.Add($sourceTargetPath)
        if (-not $targetRecord.IsDirectory) { continue }

        $directoryStack = New-Object 'System.Collections.Generic.Stack[string]'
        $directoryStack.Push($sourceTargetPath)
        while ($directoryStack.Count -gt 0 -and $null -eq $targetRecord.ScanError) {
            $currentDirectoryPath = $directoryStack.Pop()
            $currentDirectory = New-Object System.IO.DirectoryInfo($currentDirectoryPath)
            try {
                $currentAttributes = $currentDirectory.Attributes
            }
            catch {
                $targetRecord.ScanError = "無法盤點 readonly directory target：$currentDirectoryPath"
                break
            }
            if (($currentAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            try {
                $children = @($currentDirectory.EnumerateFileSystemInfos())
            }
            catch {
                $targetRecord.ScanError = "無法盤點 readonly directory target：$currentDirectoryPath"
                break
            }
            foreach ($child in $children) {
                try {
                    $childAttributes = $child.Attributes
                }
                catch {
                    $targetRecord.ScanError = "無法盤點 readonly directory target 子項目：$($child.FullName)"
                    break
                }
                if (($childAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if (($childAttributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                    $directoryStack.Push($child.FullName)
                    continue
                }

                $childPath = Resolve-AbsolutePath -Path $child.FullName
                if (-not (Test-PathWithinRoot -Path $childPath -Root $SourceRoot)) {
                    $targetRecord.ScanError = "readonly directory target 子檔超出 sourceRoot：$childPath"
                    break
                }
                $childRelativePath = (Get-RelativePathFromRoot -Path $childPath -Root $SourceRoot).Replace([string][char]92, [string][char]47)
                $targetRecord.ChildFiles.Add([pscustomobject]@{ SourcePath = $childPath; GitRelativePath = $childRelativePath })
                $gitRelativePaths.Add($childRelativePath)
                $sourcePathsForGit.Add($childPath)
            }
        }
    }

    $ignoredPathLookup = @{}
    if ($gitRelativePaths.Count -gt 0) {
        $ignoredPathLookup = Get-DispatchIgnoredPathLookup -DispatchRoot $DispatchRoot -GitRelativePath $gitRelativePaths.ToArray() -SourcePath $sourcePathsForGit.ToArray()
    }
    foreach ($targetRecord in $targetRecords) {
        if ($targetRecord.OutsideRepository) {
            $targetsOutsideRepository.Add($targetRecord.SourcePath)
            continue
        }
        if ($ignoredPathLookup.ContainsKey($targetRecord.GitRelativePath)) {
            $targetsOutsideRepository.Add($targetRecord.SourcePath)
            continue
        }
        if (-not $targetRecord.IsDirectory) { continue }
        if ($null -ne $targetRecord.ScanError) { throw [string]$targetRecord.ScanError }

        foreach ($childFile in $targetRecord.ChildFiles) {
            if ($ignoredPathLookup.ContainsKey($childFile.GitRelativePath)) {
                $targetsOutsideRepository.Add($childFile.SourcePath)
            }
        }
    }

    return @($targetsOutsideRepository.ToArray())
}
function Invoke-Preflight {
    if ([string]::IsNullOrWhiteSpace($SourceRoot) -or [string]::IsNullOrWhiteSpace($DispatchRoot) -or [string]::IsNullOrWhiteSpace($LineSlug) -or [string]::IsNullOrWhiteSpace($DispatchSlug)) {
        throw 'Preflight 必須提供 SourceRoot、DispatchRoot、LineSlug 與 DispatchSlug。'
    }
    if ($null -eq $TargetPath -or $TargetPath.Count -eq 0) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestMissingField' -Message 'Preflight 的 target_path 至少需要一項。' -Field 'target_path' -Detail ([ordered]@{ count = 0 })
    }
    $secretTargetPaths = New-Object System.Collections.Generic.List[string]
    for ($targetIndex = 0; $targetIndex -lt $TargetPath.Count; $targetIndex++) {
        $targetPathValue = [string]$TargetPath[$targetIndex]
        if ([string]::IsNullOrWhiteSpace($targetPathValue)) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message ("Preflight 的 target_path 第 {0} 項不可為空白。" -f $targetIndex) -Field 'target_path' -Detail ([ordered]@{ index = $targetIndex })
        }
        if (-not (Test-DispatchFullyQualifiedPath -Path $targetPathValue)) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidPath' -Message ("Preflight 的 target_path 第 {0} 項必須是完整絕對路徑。" -f $targetIndex) -Field 'target_path' -Detail ([ordered]@{ index = $targetIndex; expected = 'fully-qualified path'; received = $targetPathValue })
        }
        if (Test-DispatchSecretPathName -Path $targetPathValue) {
            $secretTargetPaths.Add($targetPathValue)
        }
    }
    if ($secretTargetPaths.Count -gt 0) {
        Throw-DispatchRequestFailure -Code 'PreflightSecretTargetRejected' -Message ('Preflight 拒絕機密 target_path：' + ($secretTargetPaths.ToArray() -join ', ')) -Field 'target_path' -Detail ([ordered]@{ paths = @($secretTargetPaths.ToArray()) })
    }

    $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
    $dispatchRootPath = Resolve-AbsolutePath -Path $DispatchRoot
    if (-not (Test-Path -LiteralPath $sourceRootPath -PathType Container)) {
        throw "sourceRoot 不存在或不是目錄：$sourceRootPath"
    }
    $worktreesRoot = Join-Path $sourceRootPath '.local\ai-sessions\worktrees'
    foreach ($target in @($TargetPath)) {
        $targetValue = Resolve-AbsolutePath ([string]$target)
        if (-not (Test-PathWithinRoot -Path $targetValue -Root $worktreesRoot)) { continue }
        Assert-DispatchOutputPathNoReparsePoint -Root $sourceRootPath -Path $targetValue
        $relativeTarget = $targetValue.Substring($worktreesRoot.Length).TrimStart([char[]]@('\','/'))
        $worktreeName = ($relativeTarget -split '[\\/]')[0]
        if ([string]::IsNullOrWhiteSpace($worktreeName)) { throw ('PreflightTargetWorktreeNotRegistered：target_path 未指定已登記 worktree：' + $targetValue) }
        $targetWorktree = Join-Path $worktreesRoot $worktreeName
        $registration = Invoke-GitCommand -WorkingDirectory $sourceRootPath -Arguments @('worktree','list','--porcelain') -AllowFailure
        if ($registration.ExitCode -ne 0) { throw ('PreflightTargetWorktreeRegistrationUnavailable：' + $registration.StdErr) }
        $targetRegistered = $false
        foreach ($registrationLine in ([string]$registration.StdOut -split '\r?\n')) {
            if ($registrationLine.StartsWith('worktree ', [StringComparison]::Ordinal) -and
                [string]::Equals((Resolve-AbsolutePath $registrationLine.Substring(9).Trim()), $targetWorktree, [StringComparison]::OrdinalIgnoreCase)) { $targetRegistered = $true; break }
        }
        if (-not $targetRegistered) { throw ('PreflightTargetWorktreeNotRegistered：target_path 所屬 worktree 未登記：' + $targetWorktree) }
    }
    if ([string]::Equals($sourceRootPath, $dispatchRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'sourceRoot 與 dispatchRoot 不可相同。'
    }
    $expectedDispatchRoot = Join-Path -Path $sourceRootPath -ChildPath (Join-Path -Path '.local\ai-sessions\worktrees' -ChildPath $DispatchSlug)
    if (-not [string]::Equals($dispatchRootPath, (Resolve-AbsolutePath -Path $expectedDispatchRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "dispatchRoot 必須位於 sourceRoot 的隔離 worktree 路徑，且與 dispatchSlug 一一對應：$expectedDispatchRoot"
    }
    if (Test-Path -LiteralPath $dispatchRootPath) {
        throw "dispatchRoot 已存在，視為已被占用：$dispatchRootPath"
    }

    $manifestInfo = Read-LineManifest -SourceRoot $sourceRootPath -LineSlug $LineSlug
    $pidCheck = Get-PidCheckResult -SourceRoot $sourceRootPath -LineSlug $LineSlug -WriteMode $WriteMode
    $dispatchPidBlockers = @(Get-BlockingDispatchPidRecords -PidCheckResult $pidCheck -DispatchSlug $DispatchSlug)
    if ($dispatchPidBlockers.Count -gt 0) {
        throw (New-DispatchPidIdentityBlockedMessage -DispatchSlug $DispatchSlug -Records $dispatchPidBlockers)
    }
    if ($null -ne $script:CallerSessionIdentity) {
        $preflightExecutionRoot = if (-not [string]::IsNullOrWhiteSpace($ExecutionRoot)) { $ExecutionRoot } else { $DispatchRoot }
        $null = Assert-DispatchAdmission `
            -SourceRoot $sourceRootPath `
            -CallerIdentity $script:CallerSessionIdentity `
            -LineSlug $LineSlug `
            -DispatchSlug $DispatchSlug `
            -WriteMode $WriteMode `
            -TargetPath @($TargetPath) `
            -AddDirectory @($AddDirectory) `
            -ExecutionRoot $preflightExecutionRoot
    }

    $gitProbeState = $null
    $targetStates = @()
    $gitProbeState = Get-ExistingGitRepositoryState -SourceRoot $sourceRootPath
    $worktreeCreated = $WriteMode -eq 'readonly' -and $gitProbeState.IsRepository
    if ($WriteMode -eq 'write') {
        if ($gitProbeState.IsRepository) {
            $targetStates = @(Get-TrackedPathState -SourceRoot $sourceRootPath -TargetPath $TargetPath)
            $hasTrackedWriteTarget = @($targetStates | Where-Object { $_.IsTracked }).Count -gt 0
            $worktreeCreated = $hasTrackedWriteTarget
        }
        else {
            $targetStates = @(Get-NonGitTargetState -SourceRoot $sourceRootPath -TargetPath $TargetPath)
            $worktreeCreated = $false
        }
    }
    elseif (-not $gitProbeState.IsRepository) {
        $targetStates = @(Get-NonGitTargetState -SourceRoot $sourceRootPath -TargetPath $TargetPath)
    }

    $executionRootPath = $sourceRootPath
    $targetsOutsideRepository = @()
    $carryInManifest = [ordered]@{
        TrackedPatchApplied = $false
        TrackedPatchLength  = 0
        UntrackedFiles      = @()
        CopiedFiles         = @()
        excludedSecrets     = @()
    }

    $gitState = $null
    $baseShaValue = ''
    $baseline = $null
    if ($worktreeCreated) {
        if ($null -ne $gitProbeState -and $gitProbeState.IsRepository) {
            $gitState = [ordered]@{
                GitOrigin = 'existing'
            }
        }
        else {
            $gitState = Get-GitRepositoryState -SourceRoot $sourceRootPath
        }
        if ($targetStates.Count -eq 0) {
            $targetStates = @(Get-TrackedPathState -SourceRoot $sourceRootPath -TargetPath $TargetPath)
        }
        $baseResult = Invoke-GitCommand -WorkingDirectory $sourceRootPath -Arguments @('rev-parse', 'HEAD')
        $baseShaValue = $baseResult.StdOut.Trim()
        if ($baseShaValue -notmatch '^[0-9a-fA-F]{7,64}$') {
            throw "無法取得有效 baseSha：$baseShaValue"
        }

        $dispatchParent = Split-Path -Parent $dispatchRootPath
        $null = New-DispatchOutputDirectory -Path $dispatchParent -SourceRoot $sourceRootPath -ExecutionRoot $sourceRootPath -TargetPath @($TargetPath)
        $worktreeResult = Invoke-GitCommand -WorkingDirectory $sourceRootPath -Arguments @('worktree', 'add', '--detach', $dispatchRootPath, $baseShaValue) -AllowFailure
        if ($worktreeResult.ExitCode -ne 0) {
            throw "建立 dispatch worktree 失敗：$($worktreeResult.StdErr.Trim())"
        }
        $executionRootPath = $dispatchRootPath
        $carryInManifest = Apply-SourceCarryIn -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath
        $baseline = New-DispatchBaseline -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -BaseSha $baseShaValue -TargetPath @($TargetPath)
        if ($WriteMode -eq 'readonly') {
            $targetsOutsideRepository = @(Get-TargetsOutsideRepository -SourceRoot $sourceRootPath -DispatchRoot $executionRootPath -TargetPath @($TargetPath))
        }
    }
    elseif ($WriteMode -eq 'write' -and $null -ne $gitProbeState -and $gitProbeState.IsRepository) {
        $gitState = [ordered]@{
            GitOrigin = 'existing'
        }
    }
    else {
        $gitState = [ordered]@{
            GitOrigin = 'not-applicable'
        }
    }

    $executionHandoffRoot = Join-Path -Path $executionRootPath -ChildPath '.local\ai-sessions\handoff'
    $executionReportRoot = Join-Path -Path $executionRootPath -ChildPath '.local\ai-sessions\report'
    $executionHistoryRoot = Join-Path -Path $executionRootPath -ChildPath '.local\ai-sessions\history'
    $executionScratchRoot = Join-Path -Path $executionRootPath -ChildPath '.local\ai-sessions\scratch'
    $dispatchLineRoot = Join-Path -Path $executionHandoffRoot -ChildPath $LineSlug
    $reportLineRoot = Join-Path -Path $executionReportRoot -ChildPath $LineSlug
    foreach ($directoryPath in @($executionHandoffRoot, $executionReportRoot, $executionHistoryRoot, $executionScratchRoot, $dispatchLineRoot, $reportLineRoot)) {
        $null = New-DispatchOutputDirectory -Path $directoryPath -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
    }

    $prepareBinding = $null
    $prepareStatusValue = 'not-provided'
    $prepareResultPathValue = $null
    $prepareResultSha256Value = $null
    if (-not [string]::IsNullOrWhiteSpace($PrepareResultPath)) {
        $prepareResultPathValue = Resolve-AbsolutePath -Path $PrepareResultPath
        $prepareBinding = Resolve-PrepareResultBinding -Path $prepareResultPathValue -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        $prepareStatusValue = $prepareBinding.Status
        $prepareResultSha256Value = $prepareBinding.Sha256
    }
    elseif ([string]::Equals($sourceRootPath, $executionRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $prepareStatusValue = 'not-required'
    }
    $effectiveCodexHomeValue = Resolve-CodexHomeForEvidence -CodexHomePath $CodexHome

    $result = [ordered]@{
        operation       = 'Preflight'
        sourceRoot      = $sourceRootPath
        dispatchRoot    = $dispatchRootPath
        executionRoot   = $executionRootPath
        lineSlug        = $LineSlug
        dispatchSlug    = $DispatchSlug
        writeMode       = $WriteMode
        dispatchKind    = $DispatchKind
        taskType        = $TaskType
        gitOrigin       = $gitState.GitOrigin
        baseSha         = $baseShaValue
        worktreeCreated = $worktreeCreated
        carryInManifest = $carryInManifest
        targetsOutsideRepository = @($targetsOutsideRepository)
        baselinePath    = if ($null -ne $baseline) { $baseline.Path } else { $null }
        baselineSha256  = if ($null -ne $baseline) { $baseline.Sha256 } else { $null }
        targetStates    = @($targetStates)
        sourceLineRoot  = $manifestInfo.SourceLineRoot
        dispatchLineRoot = $dispatchLineRoot
        reportLineRoot  = $reportLineRoot
        pidCheck        = $pidCheck
        prepareResultPath = $prepareResultPathValue
        prepareResultSha256 = $prepareResultSha256Value
        prepareStatus = $prepareStatusValue
        effectiveCodexHome = $effectiveCodexHomeValue
    }

    return $result
}

function Get-DispatchResultPropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string[]]$Names
    )

    foreach ($name in @($Names)) {
        $property = Get-DispatchJsonProperty -Object $Object -Name $name
        if ($null -ne $property) {
            return $property
        }
    }
    return $null
}

function Write-DispatchStageResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('preflight', 'prepare', 'start')]
        [string]$Stage,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Result,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [string[]]$TargetPath = @(),

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug
    )

    $document = [ordered]@{}
    if ($null -ne $Result) {
        if ($Result -is [System.Collections.IDictionary]) {
            foreach ($key in $Result.Keys) {
                $document[[string]$key] = $Result[$key]
            }
        }
        else {
            foreach ($property in $Result.PSObject.Properties) {
                $document[$property.Name] = $property.Value
            }
        }
    }
    if (-not $document.Contains('operation')) {
        $document.operation = switch ($Stage) {
            'preflight' { 'Preflight' }
            'prepare' { 'Prepare' }
            default { 'Start' }
        }
    }
    if (-not $document.Contains('status')) {
        $document.status = 'completed'
    }
    if (-not $document.Contains('line_slug')) {
        $document.line_slug = $LineSlug
    }
    if (-not $document.Contains('dispatch_slug')) {
        $document.dispatch_slug = $DispatchSlug
    }
    $stageBinding = Get-DispatchScriptVariableValue -Name 'DispatchStageBinding'
    if ($null -ne $stageBinding) {
        $document.stage_binding_fingerprint = [string](Get-DispatchJsonProperty -Object $stageBinding -Name 'fingerprint')
    }
    $document.dispatch_stage = $Stage
    $document.dispatch_stage_status = [string]$document.status
    $written = Write-DispatchAtomicJsonDocument -Path $Path -Document $document -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath @($TargetPath)
    return [pscustomobject]@{
        Path = $written.Path
        Sha256 = $written.Sha256
        Status = [string]$document.status
        Document = $written.Document
    }
}

function Write-DispatchInspectResultBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [bool]$ProcessStarted,

        [Parameter(Mandatory)]
        [string]$RunRecordPath,

        [Parameter(Mandatory)]
        [string]$EventStreamPath,

        [Parameter(Mandatory)]
        [string]$ScopePlanPath,

        [Parameter(Mandatory)]
        [string]$QuotaBeforePath,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-fA-F0-9]{64}$')]
        [string]$QuotaBeforeSha256,

        [Parameter(Mandatory)]
        [string]$ProcessExitCodeSidecarPath
    )

    $resolvedPath = Resolve-AbsolutePath -Path $Path
    $document = [ordered]@{
        schema = 'ai-sessions.dispatch-result.v1'
        operation = 'Dispatch'
        status = 'started'
        line_slug = $LineSlug
        dispatch_slug = $DispatchSlug
        completed_stages = @('start')
        failed_stage = $null
        error_code = $null
        error = $null
        process_started = $ProcessStarted
        result_path = $resolvedPath
        quota_before_path = $QuotaBeforePath
        quota_before_sha256 = $QuotaBeforeSha256
        inspect_binding = [ordered]@{
            run_record_path = $RunRecordPath
            event_stream_path = $EventStreamPath
            scope_plan_path = $ScopePlanPath
            quota_before_path = $QuotaBeforePath
            quota_before_sha256 = $QuotaBeforeSha256
            process_exit_code_sidecar_path = $ProcessExitCodeSidecarPath
            process_exit_code = $null
            process_exit_code_source = 'sidecar-pending'
            sidecar_sha256 = $null
        }
    }
    return Write-DispatchAtomicJsonDocument -Path $resolvedPath -Document $document -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath @() -RequireAbsent -AbsentErrorCode 'DispatchResultBindingCollision'
}

function New-DispatchResultEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [AllowEmptyCollection()]
        [Parameter(Mandatory)][string[]]$CompletedStages,
        [AllowEmptyString()][string]$FailedStage,
        [AllowEmptyString()][string]$ErrorCode,
        [AllowEmptyString()][string]$ErrorMessage,
        [bool]$ProcessStarted,
        [AllowNull()][object]$PreflightStage,
        [AllowNull()][object]$PrepareStage,
        [AllowNull()][object]$StartStage,
        [AllowEmptyString()][string]$QuotaBeforePath,
        [AllowEmptyString()][string]$QuotaBeforeSha256,
        [AllowEmptyString()][string]$ResultPathValue,
        [AllowEmptyString()][string]$StartResultPathValue,
        [AllowEmptyString()][string]$SidecarPath,
        [AllowNull()][object]$StageBinding,
        [AllowNull()][object]$EvidenceBinding
    )

    $startResult = $StartStage
    $startDocument = Get-DispatchResultPropertyValue -Object $StartStage -Names @('Document', 'document')
    if ($null -ne $startDocument) {
        $startResult = $startDocument
    }
    $runRecordPath = Get-DispatchResultPropertyValue -Object $startResult -Names @('runRecordPath', 'run_record_path')
    $eventStreamPath = Get-DispatchResultPropertyValue -Object $startResult -Names @('eventStreamPath', 'event_stream_path')
    $scopePlanPath = Get-DispatchResultPropertyValue -Object $startResult -Names @('scopePlanPath', 'scope_plan_path')
    $startSidecarPath = Get-DispatchResultPropertyValue -Object $startResult -Names @('processExitCodeSidecarPath', 'process_exit_code_sidecar_path')
    $inspectResultPath = Get-DispatchResultPropertyValue -Object $startResult -Names @('inspectResultPath', 'inspect_result_path')
    $promptPath = Get-DispatchResultPropertyValue -Object $startResult -Names @('promptPath', 'prompt_path')
    $promptSourcePath = Get-DispatchResultPropertyValue -Object $startResult -Names @('promptSourcePath', 'prompt_source_path')
    $promptTransferPath = Get-DispatchResultPropertyValue -Object $startResult -Names @('promptTransferPath', 'prompt_transfer_path')
    if ([string]::IsNullOrWhiteSpace($SidecarPath) -and $null -ne $startSidecarPath) {
        $SidecarPath = [string]$startSidecarPath
    }
    $inspectBinding = [ordered]@{
        run_record_path = if ($null -eq $runRecordPath) { $null } else { [string]$runRecordPath }
        event_stream_path = if ($null -eq $eventStreamPath) { $null } else { [string]$eventStreamPath }
        scope_plan_path = if ($null -eq $scopePlanPath) { $null } else { [string]$scopePlanPath }
        quota_before_path = if ([string]::IsNullOrWhiteSpace($QuotaBeforePath)) { $null } else { $QuotaBeforePath }
        quota_before_sha256 = if ([string]::IsNullOrWhiteSpace($QuotaBeforeSha256)) { $null } else { $QuotaBeforeSha256 }
        process_exit_code_sidecar_path = if ([string]::IsNullOrWhiteSpace($SidecarPath)) { $null } else { $SidecarPath }
        process_exit_code = $null
        process_exit_code_source = 'sidecar-pending'
        sidecar_sha256 = $null
    }
    return [ordered]@{
        schema = 'ai-sessions.dispatch-result.v1'
        operation = 'Dispatch'
        status = $Status
        line_slug = $LineSlug
        dispatch_slug = $DispatchSlug
        completed_stages = @($CompletedStages)
        failed_stage = if ([string]::IsNullOrWhiteSpace($FailedStage)) { $null } else { $FailedStage }
        error_code = if ([string]::IsNullOrWhiteSpace($ErrorCode)) { $null } else { $ErrorCode }
        error = if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $null } else { $ErrorMessage }
        process_started = $ProcessStarted
        preflight_result_path = if ($null -eq $PreflightStage) { $null } else { [string](Get-DispatchResultPropertyValue -Object $PreflightStage -Names @('Path', 'path')) }
        preflight_result_sha256 = if ($null -eq $PreflightStage) { $null } else { [string](Get-DispatchResultPropertyValue -Object $PreflightStage -Names @('Sha256', 'sha256')) }
        prepare_result_path = if ($null -eq $PrepareStage) { $null } else { [string](Get-DispatchResultPropertyValue -Object $PrepareStage -Names @('Path', 'path', 'prepareResultPath', 'prepare_result_path')) }
        prepare_result_sha256 = if ($null -eq $PrepareStage) { $null } else { [string](Get-DispatchResultPropertyValue -Object $PrepareStage -Names @('Sha256', 'sha256', 'prepareResultSha256', 'prepare_result_sha256')) }
        quota_before_path = if ([string]::IsNullOrWhiteSpace($QuotaBeforePath)) { $null } else { $QuotaBeforePath }
        quota_before_sha256 = if ([string]::IsNullOrWhiteSpace($QuotaBeforeSha256)) { $null } else { $QuotaBeforeSha256 }
        start_result_path = if ([string]::IsNullOrWhiteSpace($StartResultPathValue)) { $null } else { $StartResultPathValue }
        prompt_path = if ($null -eq $promptPath) { $null } else { [string]$promptPath }
        promptPath = if ($null -eq $promptPath) { $null } else { [string]$promptPath }
        prompt_source_path = if ($null -eq $promptSourcePath) { $null } else { [string]$promptSourcePath }
        promptSourcePath = if ($null -eq $promptSourcePath) { $null } else { [string]$promptSourcePath }
        prompt_transfer_path = if ($null -eq $promptTransferPath) { $null } else { [string]$promptTransferPath }
        promptTransferPath = if ($null -eq $promptTransferPath) { $null } else { [string]$promptTransferPath }
        inspect_result_path = if ($null -eq $inspectResultPath) { $null } else { [string]$inspectResultPath }
        inspectResultPath = if ($null -eq $inspectResultPath) { $null } else { [string]$inspectResultPath }
        stage_binding = $StageBinding
        inspect_binding = $inspectBinding
        stage_results = [ordered]@{
            preflight = if ($null -eq $PreflightStage) { $null } else { [ordered]@{ path = $PreflightStage.Path; sha256 = $PreflightStage.Sha256; status = $PreflightStage.Status } }
            prepare = if ($null -eq $PrepareStage) { $null } else { [ordered]@{ path = $PrepareStage.Path; sha256 = $PrepareStage.Sha256; status = $PrepareStage.Status } }
            start = if ($null -eq $StartStage) { $null } else { [ordered]@{ path = $StartStage.Path; sha256 = $StartStage.Sha256; status = $StartStage.Status } }
        }
        result_path = $ResultPathValue
        execution_root = if ($null -eq $EvidenceBinding) { $null } else { [string](Get-DispatchResultPropertyValue -Object $EvidenceBinding -Names @('execution_root')) }
        head = if ($null -eq $EvidenceBinding) { $null } else { [string](Get-DispatchResultPropertyValue -Object $EvidenceBinding -Names @('head')) }
        uncommitted_content_fingerprint = if ($null -eq $EvidenceBinding) { $null } else { [string](Get-DispatchResultPropertyValue -Object $EvidenceBinding -Names @('uncommitted_content_fingerprint')) }
        evidence_kind = if ($null -eq $EvidenceBinding) { $null } else { [string](Get-DispatchResultPropertyValue -Object $EvidenceBinding -Names @('evidence_kind')) }
        evidence_position = if ($null -eq $EvidenceBinding) { $null } else { Get-DispatchResultPropertyValue -Object $EvidenceBinding -Names @('evidence_position') }
        evidence_binding = $EvidenceBinding
    }
}

function Invoke-Dispatch {
    [CmdletBinding()]
    param()

    $completedStages = New-Object 'System.Collections.Generic.List[string]'
    $failedStage = 'validation'
    $failureException = $null
    $processStarted = $false
    $preflightStage = $null
    $prepareStage = $null
    $startStage = $null
    $preflightResult = $null
    $prepareResult = $null
    $startResult = $null
    $quotaBeforePathValue = $null
    $quotaBeforeSha256Value = $null
    $script:DispatchQuotaBeforeSha256 = $null
    $resultPathValue = $null
    $failureReceiptPathValue = $null
    $startResultPathValue = $null
    $sidecarPathValue = $null
    $dispatchPrepareResultPath = $null
    $sourceRootPath = $null
    $executionRootPath = $null
    $evidenceBinding = $null
    $dispatchToken = [guid]::NewGuid().ToString('N')
    $requestedResultPath = [string]$ResultPath
    $requestedFailureReceiptPath = [string]$FailureReceiptPath
    $requestedPreflightResultPath = [string]$PreflightResultPath
    $requestedPrepareResultPath = [string]$PrepareResultPath
    $requestedQuotaBeforePath = [string]$QuotaBeforePath
    $requestedQuotaAfterPath = [string]$QuotaAfterPath
    $stageBinding = $null
    $failureReceiptWritten = $false
    $failureReceiptSha256Value = $null
    $continuationFailureHandoff = $null

    try {
        if ($null -eq $script:RequestContext -or [string]$script:RequestContext.document.operation -cne 'Dispatch') {
            throw 'Dispatch 必須由 operation=Dispatch 的 request JSON 驅動。'
        }
        if ([string]::IsNullOrWhiteSpace($SourceRoot) -or [string]::IsNullOrWhiteSpace($DispatchRoot) -or [string]::IsNullOrWhiteSpace($LineSlug) -or [string]::IsNullOrWhiteSpace($DispatchSlug)) {
            throw 'Dispatch request 必須提供 source_root、dispatch_root、line_slug 與 dispatch_slug。'
        }
        if ($null -eq $TargetPath -or @($TargetPath).Count -eq 0) {
            throw 'Dispatch request 必須提供至少一個 target_path。'
        }
        if ([string]::IsNullOrWhiteSpace($PromptPath)) {
            throw 'Dispatch request 必須提供 prompt_path。'
        }
        $script:DispatchStageBinding = $null
        $script:ResultPath = $null
        $script:PreflightResultPath = $null
        $script:PrepareResultPath = $null
        $script:QuotaBeforePath = $null
        $script:QuotaAfterPath = $null
        $ResultPath = $null
        $PreflightResultPath = $null
        $PrepareResultPath = $null
        $QuotaBeforePath = $null
        $QuotaAfterPath = $null

        $failedStage = 'preflight'
        if ([string]::IsNullOrWhiteSpace($requestedFailureReceiptPath)) {
            throw 'Dispatch request 必須提供 failure_receipt_path。'
        }
        $failureReceiptPathValue = Resolve-DispatchOutputPath -CandidatePath $requestedFailureReceiptPath -SourceRoot ([string]$SourceRoot) -ExecutionRoot ([string]$SourceRoot) -TargetPath @($TargetPath)
        $preflightResult = Invoke-Preflight
        if ($null -eq $preflightResult) {
            throw 'Preflight 未回傳結果。'
        }
        $preflightSourceRoot = [string](Get-DispatchResultPropertyValue -Object $preflightResult -Names @('sourceRoot', 'source_root'))
        $preflightExecutionRoot = [string](Get-DispatchResultPropertyValue -Object $preflightResult -Names @('executionRoot', 'execution_root'))
        $preflightDispatchRoot = [string](Get-DispatchResultPropertyValue -Object $preflightResult -Names @('dispatchRoot', 'dispatch_root'))
        if ([string]::IsNullOrWhiteSpace($preflightSourceRoot)) { $preflightSourceRoot = $SourceRoot }
        if ([string]::IsNullOrWhiteSpace($preflightExecutionRoot)) { $preflightExecutionRoot = $ExecutionRoot }
        if ([string]::IsNullOrWhiteSpace($preflightExecutionRoot)) { $preflightExecutionRoot = $preflightSourceRoot }
        if ([string]::IsNullOrWhiteSpace($preflightDispatchRoot)) { $preflightDispatchRoot = $DispatchRoot }
        $sourceRootPath = Resolve-AbsolutePath -Path $preflightSourceRoot
        $executionRootPath = Resolve-AbsolutePath -Path $preflightExecutionRoot
        $dispatchRootPath = Resolve-AbsolutePath -Path $preflightDispatchRoot
        $historyLineRoot = Join-Path -Path (Join-Path -Path $executionRootPath -ChildPath '.local\ai-sessions\history') -ChildPath $LineSlug
        $resultPathValue = if ([string]::IsNullOrWhiteSpace($requestedResultPath)) {
            Join-Path -Path $historyLineRoot -ChildPath ('dispatch-result-' + $DispatchSlug + '-' + $dispatchToken + '.json')
        }
        else {
            Resolve-AbsolutePath -Path $requestedResultPath
        }
        $preflightResultPathValue = if ([string]::IsNullOrWhiteSpace($requestedPreflightResultPath)) {
            Join-Path -Path $historyLineRoot -ChildPath ('preflight-result-' + $DispatchSlug + '-' + $dispatchToken + '.json')
        }
        else {
            Resolve-AbsolutePath -Path $requestedPreflightResultPath
        }
        $dispatchPrepareResultPath = if ([string]::IsNullOrWhiteSpace($requestedPrepareResultPath)) {
            Join-Path -Path $historyLineRoot -ChildPath ('prepare-result-' + $DispatchSlug + '-' + $dispatchToken + '.json')
        }
        else {
            Resolve-AbsolutePath -Path $requestedPrepareResultPath
        }
        $historyRoot = Join-Path -Path $executionRootPath -ChildPath '.local\ai-sessions\history'
        $quotaBeforePathValue = New-QuotaSnapshotPath -HistoryRoot $historyRoot -Purpose 'before'
        $quotaAfterPathValue = if ([string]::IsNullOrWhiteSpace($requestedQuotaAfterPath)) {
            $null
        }
        else {
            Resolve-AbsolutePath -Path $requestedQuotaAfterPath
        }
        $stageBinding = New-DispatchStageBinding -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -TargetPath @($TargetPath) -ResultPath $resultPathValue -PreflightResultPath $preflightResultPathValue -PrepareResultPath $dispatchPrepareResultPath -QuotaBeforePath $quotaBeforePathValue -QuotaAfterPath $quotaAfterPathValue
        $script:DispatchStageBinding = $stageBinding
        $resultPathValue = [string]$stageBinding.result_path
        $PreflightResultPath = [string]$stageBinding.preflight_result_path
        $dispatchPrepareResultPath = [string]$stageBinding.prepare_result_path
        $QuotaBeforePath = [string]$stageBinding.quota_before_path
        $QuotaAfterPath = [string]$stageBinding.quota_after_path
        $script:ResultPath = $resultPathValue
        $script:PreflightResultPath = $PreflightResultPath
        $script:PrepareResultPath = $dispatchPrepareResultPath
        $script:QuotaBeforePath = $QuotaBeforePath
        $script:QuotaAfterPath = $QuotaAfterPath
        $ResultPath = $resultPathValue
        $PreflightResultPath = $PreflightResultPath
        $PrepareResultPath = $dispatchPrepareResultPath
        $QuotaBeforePath = $QuotaBeforePath
        $QuotaAfterPath = $QuotaAfterPath
        $script:SourceRoot = $sourceRootPath
        $script:ExecutionRoot = $executionRootPath
        $script:DispatchRoot = $executionRootPath
        if ([string]::Equals($sourceRootPath, $executionRootPath, [StringComparison]::OrdinalIgnoreCase)) {
            $script:RequestPrepareArtifacts = @($script:RequestManualPrepareArtifacts)
        }
        Set-DispatchJsonPropertyValue -Object $preflightResult -Name 'prepareResultPath' -Value $dispatchPrepareResultPath
        Set-DispatchJsonPropertyValue -Object $preflightResult -Name 'prepare_result_path' -Value $dispatchPrepareResultPath
        Set-DispatchJsonPropertyValue -Object $preflightResult -Name 'prepareResultSha256' -Value $null
        Set-DispatchJsonPropertyValue -Object $preflightResult -Name 'prepare_result_sha256' -Value $null
        Set-DispatchJsonPropertyValue -Object $preflightResult -Name 'stage_binding_fingerprint' -Value ([string]$stageBinding.fingerprint)
        $preflightStage = Write-DispatchStageResult -Stage 'preflight' -Path $PreflightResultPath -Result $preflightResult -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath) -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        $completedStages.Add('preflight')
        $PreflightResultPath = [string]$preflightStage.Path
        $script:SourceRoot = $sourceRootPath
        $script:ExecutionRoot = $executionRootPath
        $script:PreflightResultPath = $preflightStage.Path
        $script:PrepareResultPath = $dispatchPrepareResultPath
        $PrepareResultPath = $dispatchPrepareResultPath

        $failedStage = 'before-snapshot'
        $quotaBeforePathValue = Get-OrCreateQuotaSnapshot -Path $requestedQuotaBeforePath -SnapshotPath ([string]$stageBinding.quota_before_path) -CodexHome $CodexHome -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath) -HistoryRoot $historyRoot -Purpose 'before' -Required
        $quotaBeforePathValue = Resolve-AbsolutePath -Path $quotaBeforePathValue
        if (-not [string]::Equals($quotaBeforePathValue, [string]$stageBinding.quota_before_path, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'DispatchStageBindingConflict：QuotaBeforePath 未沿用既有 stage binding。'
        }
        $quotaBeforeSha256Value = Get-FileSha256 -Path $quotaBeforePathValue
        $script:DispatchQuotaBeforeSha256 = $quotaBeforeSha256Value
        $script:QuotaBeforePath = $quotaBeforePathValue
        $completedStages.Add('before-snapshot')

        $failedStage = 'prepare'
        $dispatchUnitKind = Get-DefaultUnitKind -DispatchKind ([string]$DispatchKind) -UnitKind ([string]$UnitKind) -TaskType ([string]$TaskType)
        if (-not [string]::Equals($sourceRootPath, $executionRootPath, [StringComparison]::OrdinalIgnoreCase) -and $dispatchUnitKind -ne 'advisor-evidence-question') {
            $script:RequestAutoPrepareArtifacts = @(New-DispatchAutoPrepareArtifacts -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -DispatchKind ([string]$DispatchKind) -ResourceOrder $script:RequestResourceOrder)
            $script:RequestPrepareArtifacts = @($script:RequestAutoPrepareArtifacts) + @($script:RequestManualPrepareArtifacts)
        }
        else {
            $script:RequestAutoPrepareArtifacts = New-Object 'System.Object[]' 0
            $script:RequestPrepareArtifacts = @($script:RequestManualPrepareArtifacts)
        }
        $prepareResult = Invoke-Prepare -GuardTargetPath @($TargetPath)
        if ($null -eq $prepareResult) {
            throw 'Prepare 未回傳結果。'
        }
        $prepareDocument = Get-DispatchResultPropertyValue -Object $prepareResult -Names @('prepareResult', 'prepare_result')
        if ($null -eq $prepareDocument) { $prepareDocument = $prepareResult }
        $prepareStage = Write-DispatchStageResult -Stage 'prepare' -Path $dispatchPrepareResultPath -Result $prepareDocument -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath) -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        $completedStages.Add('prepare')
        $script:PrepareResultPath = $prepareStage.Path

        $failedStage = 'start'
        $script:WaitForStartProcessExit = [bool]$script:DispatchWaitForCompletion
        $startResult = Invoke-Start
        if ($null -eq $startResult) {
            throw 'Start 未回傳結果。'
        }
        $processStartedValue = Get-DispatchResultPropertyValue -Object $startResult -Names @('processStarted', 'process_started')
        if ($null -ne $processStartedValue) { $processStarted = [bool]$processStartedValue }
        if (-not $processStarted) {
            throw 'Start 未回傳 process_started=true。'
        }
        $startHistoryRoot = Join-Path -Path $executionRootPath -ChildPath '.local\ai-sessions\history'
        if ([string]::IsNullOrWhiteSpace($startResultPathValue)) {
            $startResultPathValue = Join-Path -Path $startHistoryRoot -ChildPath ('start-result-' + $DispatchSlug + '-' + $dispatchToken + '.json')
        }
        $startStage = Write-DispatchStageResult -Stage 'start' -Path $startResultPathValue -Result $startResult -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath) -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        $completedStages.Add('start')
        $sidecarPathValue = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('processExitCodeSidecarPath', 'process_exit_code_sidecar_path'))
        $evidencePosition = [ordered]@{
            request_path = if ([string]::IsNullOrWhiteSpace($RequestPath)) { $null } else { Resolve-AbsolutePath -Path $RequestPath }
            preflight_result_path = $preflightStage.Path
            prepare_result_path = $prepareStage.Path
            start_result_path = $startStage.Path
            result_path = $resultPathValue
            quota_before_path = $quotaBeforePathValue
            quota_before_sha256 = $quotaBeforeSha256Value
            run_record_path = Get-DispatchResultPropertyValue -Object $startResult -Names @('runRecordPath', 'run_record_path')
            event_stream_path = Get-DispatchResultPropertyValue -Object $startResult -Names @('eventStreamPath', 'event_stream_path')
            last_message_path = Get-DispatchResultPropertyValue -Object $startResult -Names @('lastMessagePath', 'last_message_path')
            inspect_result_path = Get-DispatchResultPropertyValue -Object $startResult -Names @('inspectResultPath', 'inspect_result_path')
            evidence_paths = @($EvidencePath)
        }
        $evidenceBinding = New-DispatchEvidenceBinding -ExecutionRoot $executionRootPath -EvidencePosition $evidencePosition
        $result = New-DispatchResultEnvelope -Status 'started' -LineSlug $LineSlug -DispatchSlug $DispatchSlug -CompletedStages @($completedStages.ToArray()) -FailedStage '' -ErrorCode '' -ErrorMessage '' -ProcessStarted $processStarted -PreflightStage $preflightStage -PrepareStage $prepareStage -StartStage $startStage -QuotaBeforePath $quotaBeforePathValue -QuotaBeforeSha256 $quotaBeforeSha256Value -ResultPathValue $resultPathValue -StartResultPathValue $startStage.Path -SidecarPath $sidecarPathValue -StageBinding $stageBinding -EvidenceBinding $evidenceBinding
        $result.background = -not [bool]$script:DispatchWaitForCompletion
        $result.requested_units = @($script:ResolvedRequestedUnit)
        $writtenResult = Write-DispatchAtomicJsonDocument -Path $resultPathValue -Document $result -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
        $result.result_path = $writtenResult.Path
        $result.result_sha256 = $writtenResult.Hash
        if ($script:DispatchWaitForCompletion) {
            $failedStage = 'inspect'
            $runRecordPathValue = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('runRecordPath', 'run_record_path'))
            $eventStreamPathValue = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('eventStreamPath', 'event_stream_path'))
            $sidecarPathValue = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('processExitCodeSidecarPath', 'process_exit_code_sidecar_path'))
            $null = Wait-DispatchExitAndTerminalEvent -ExecutionRoot $executionRootPath -SourceRoot $sourceRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -WriteMode $WriteMode -RunRecordPath $runRecordPathValue -EventStreamPath $eventStreamPathValue -SidecarPath $sidecarPathValue

            $script:DispatchResultPath = $resultPathValue
            $startEvidencePackPath = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('evidencePackPath', 'evidence_pack_path'))
            $script:RequiredIdentifier = Get-DispatchRequiredIdentifier -ConfiguredIdentifier ([string]$RequiredIdentifier) -DispatchKind ([string]$DispatchKind) -TaskType ([string]$TaskType) -EvidencePackPath $startEvidencePackPath -TargetPath @($TargetPath)
            $script:LastMessagePath = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('lastMessagePath', 'last_message_path'))
            $script:ErrorStreamPath = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('errorStreamPath', 'error_stream_path'))
            $script:ThreadIdPath = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('threadIdPath', 'thread_id_path'))
            $inspectScopePlanPath = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('scopePlanPath', 'scope_plan_path'))
            if (-not [string]::IsNullOrWhiteSpace($inspectScopePlanPath)) {
                $script:ScopePlanPath = $inspectScopePlanPath
                if ($null -ne $script:InvocationBoundParameters -and $script:InvocationBoundParameters.Contains('ScopePlanPath')) {
                    $script:InvocationBoundParameters['ScopePlanPath'] = $inspectScopePlanPath
                }
            }
            $inspectResult = Invoke-Inspect
            $inspectSuccess = [bool](Get-DispatchResultPropertyValue -Object $inspectResult -Names @('success'))
            $inspectLastEventType = [string](Get-DispatchResultPropertyValue -Object $inspectResult -Names @('lastEventType', 'last_event_type'))
            $inspectTerminalEventAvailableValue = Get-DispatchResultPropertyValue -Object $inspectResult -Names @('terminalEventAvailable', 'terminal_event_available')
            $inspectTerminalEventAvailable = if ($null -eq $inspectTerminalEventAvailableValue) {
                $inspectLastEventType -in @('turn.completed', 'turn.failed')
            }
            else {
                [bool]$inspectTerminalEventAvailableValue
            }
            $inspectTurnFailedReason = [string](Get-DispatchResultPropertyValue -Object $inspectResult -Names @('turnFailedReason', 'turn_failed_reason'))
            $inspectProcessExitCode = Get-DispatchResultPropertyValue -Object $inspectResult -Names @('processExitCode', 'process_exit_code')
            $result.status = if ($inspectSuccess) { 'completed' } else { 'failed' }
            $result.failed_stage = if ($inspectSuccess) { $null } else { 'inspect' }
            $result.error_code = if ($inspectSuccess) { $null } elseif ([string]$inspectLastEventType -eq 'turn.failed') { 'CodexTurnFailed' } else { 'DispatchInspectFailed' }
            $result.error = if ($inspectSuccess) { $null } elseif (-not [string]::IsNullOrWhiteSpace($inspectTurnFailedReason)) { $inspectTurnFailedReason } elseif ($null -ne $inspectResult.diagnosis) { [string](Get-DispatchJsonProperty -Object $inspectResult.diagnosis -Name 'observation') } else { 'Dispatch Inspect 未通過。' }
            $result.completed_stages = @($completedStages.ToArray()) + @('inspect')
            $result.process_exit_code = $inspectProcessExitCode
            $result.termination_reason = if ([string]$inspectLastEventType -eq 'turn.failed' -and -not [string]::IsNullOrWhiteSpace($inspectTurnFailedReason)) { 'turn.failed: ' + $inspectTurnFailedReason } elseif (-not [string]::IsNullOrWhiteSpace($inspectLastEventType)) { [string]$inspectLastEventType } else { [string]$result.error }
            $result.inspect_status = if ($inspectSuccess) { 'completed' } else { 'failed' }
            $result.inspect_success = $inspectSuccess
            $result.inspect_result_path = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('inspectResultPath', 'inspect_result_path'))
            $inspectExitCodeValue = 0
            $hasNonzeroInspectExitCode = $null -ne $inspectProcessExitCode -and [int]::TryParse([string]$inspectProcessExitCode, [ref]$inspectExitCodeValue) -and $inspectExitCodeValue -ne 0
            $continuationExecutionFailed = [string]$SessionMode -ieq 'continuation' -and -not $inspectSuccess -and ([string]$inspectLastEventType -ceq 'turn.failed' -or $hasNonzeroInspectExitCode -or -not $inspectTerminalEventAvailable)
            if ($continuationExecutionFailed) {
                $requestDocument = if ($null -eq $script:RequestContext) { $null } else { $script:RequestContext.document }
                $continuationFailureHandoff = Get-DispatchContinuationFailureHandoff `
                    -RequestPath ([string]$RequestPath) `
                    -RequestDocument $requestDocument `
                    -ScopePlanPath ([string](Get-DispatchResultPropertyValue -Object $startResult -Names @('scopePlanPath', 'scope_plan_path'))) `
                    -EventStreamPath $eventStreamPathValue `
                    -RunRecordPath $runRecordPathValue `
                    -LastMessagePath ([string](Get-DispatchResultPropertyValue -Object $startResult -Names @('lastMessagePath', 'last_message_path'))) `
                    -InspectResultPath ([string](Get-DispatchResultPropertyValue -Object $startResult -Names @('inspectResultPath', 'inspect_result_path'))) `
                    -SourceRoot $sourceRootPath `
                    -ExecutionRoot $executionRootPath `
                    -DispatchRoot $dispatchRootPath `
                    -LineSlug ([string]$LineSlug) `
                    -DispatchSlug ([string]$DispatchSlug) `
                    -DispatchExecutionId $dispatchToken `
                    -FallbackSelectedUnits @($script:ResolvedRequestedUnit)
                $writtenContinuationReceipt = Write-DispatchFailureReceipt `
                    -Path $failureReceiptPathValue `
                    -LineSlug ([string]$LineSlug) `
                    -DispatchSlug ([string]$DispatchSlug) `
                    -DispatchExecutionId $dispatchToken `
                    -ErrorCode ([string]$result.error_code) `
                    -ErrorMessage ([string]$result.error) `
                    -SourceRoot $sourceRootPath `
                    -ExecutionRoot $executionRootPath `
                    -DispatchRoot $dispatchRootPath `
                    -FailedStage 'inspect' `
                    -ProcessStarted $processStarted `
                    -TargetPath @($TargetPath) `
                    -ContinuationHandoff $continuationFailureHandoff
                $failureReceiptWritten = $true
                $failureReceiptSha256Value = [string]$writtenContinuationReceipt.Sha256
                $result.failure_receipt_path = $writtenContinuationReceipt.Path
                $result.failure_receipt_sha256 = $failureReceiptSha256Value
                $result.failure_receipt_saved = $true
                $result.continuation_handoff = $continuationFailureHandoff
            }
            $writtenFinalResult = Write-DispatchAtomicJsonDocument -Path $resultPathValue -Document $result -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
            $result.result_path = $writtenFinalResult.Path
            $result.result_sha256 = $writtenFinalResult.Hash
        }
        $script:DispatchStageBinding = $null
        return $result
    }
    catch {
        $failureException = $_.Exception
        if ($failedStage -eq 'start' -and $null -ne $failureException.Data['operationResult']) {
            $startResult = $failureException.Data['operationResult']
            $processStartedValue = Get-DispatchResultPropertyValue -Object $startResult -Names @('processStarted', 'process_started')
            if ($null -ne $processStartedValue) { $processStarted = [bool]$processStartedValue }
        }
        $errorCode = [string]$failureException.Data['outputCode']
        if ([string]::IsNullOrWhiteSpace($errorCode)) { $errorCode = [string]$failureException.Data['errorCode'] }
        if ([string]::IsNullOrWhiteSpace($errorCode)) { $errorCode = [string]$failureException.Data['prepareCode'] }
        if ([string]::IsNullOrWhiteSpace($errorCode)) {
            $errorCode = switch ($failedStage) {
                'validation' { 'DispatchRequestInvalidValue' }
                'preflight' { 'DispatchPreflightFailed' }
                'before-snapshot' { 'DispatchQuotaBeforeFailed' }
                'prepare' { 'DispatchPrepareFailed' }
                'inspect' { 'DispatchInspectFailed' }
                default { 'DispatchStartFailed' }
            }
        }
        if ($failedStage -ne 'preflight' -and [string]::IsNullOrWhiteSpace($resultPathValue) -and -not [string]::IsNullOrWhiteSpace($SourceRoot) -and -not [string]::IsNullOrWhiteSpace($LineSlug) -and -not [string]::IsNullOrWhiteSpace($DispatchSlug)) {
            try {
                $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
                $resultPathValue = Join-Path -Path (Join-Path -Path (Join-Path -Path $sourceRootPath -ChildPath '.local\ai-sessions\history') -ChildPath $LineSlug) -ChildPath ('dispatch-result-' + $DispatchSlug + '-' + $dispatchToken + '.json')
            }
            catch { $resultPathValue = $null }
        }
        $failureResult = New-DispatchResultEnvelope -Status 'failed' -LineSlug ([string]$LineSlug) -DispatchSlug ([string]$DispatchSlug) -CompletedStages @($completedStages.ToArray()) -FailedStage $failedStage -ErrorCode $errorCode -ErrorMessage $failureException.Message -ProcessStarted $processStarted -PreflightStage $preflightStage -PrepareStage $prepareStage -StartStage $startStage -QuotaBeforePath $quotaBeforePathValue -QuotaBeforeSha256 $quotaBeforeSha256Value -ResultPathValue $resultPathValue -StartResultPathValue $startResultPathValue -SidecarPath $sidecarPathValue -StageBinding $stageBinding -EvidenceBinding $evidenceBinding
        $failureResult.dispatch_execution_id = $dispatchToken
        $failureResult.failure_receipt_path = if ([string]::IsNullOrWhiteSpace($failureReceiptPathValue)) { $null } else { $failureReceiptPathValue }
        $failureResult.failure_receipt_saved = $false
        if ([string]$SessionMode -ieq 'continuation') {
            if ($null -eq $continuationFailureHandoff) {
                $requestDocument = if ($null -eq $script:RequestContext) { $null } else { $script:RequestContext.document }
                $handoffScopePlanPath = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('scopePlanPath', 'scope_plan_path'))
                if ([string]::IsNullOrWhiteSpace($handoffScopePlanPath)) { $handoffScopePlanPath = [string]$ScopePlanPath }
                $handoffEventStreamPath = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('eventStreamPath', 'event_stream_path'))
                if ([string]::IsNullOrWhiteSpace($handoffEventStreamPath)) { $handoffEventStreamPath = [string]$EventStreamPath }
                $handoffRunRecordPath = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('runRecordPath', 'run_record_path'))
                if ([string]::IsNullOrWhiteSpace($handoffRunRecordPath)) { $handoffRunRecordPath = [string]$RunRecordPath }
                $handoffLastMessagePath = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('lastMessagePath', 'last_message_path'))
                if ([string]::IsNullOrWhiteSpace($handoffLastMessagePath)) { $handoffLastMessagePath = [string]$LastMessagePath }
                $handoffInspectResultPath = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('inspectResultPath', 'inspect_result_path'))
                $handoffRequestPath = [string]$RequestPath
                if ([string]::IsNullOrWhiteSpace($handoffRequestPath) -and $null -ne $script:RequestContext) {
                    $handoffRequestPath = [string]$script:RequestContext.path
                }
                $handoffParameters = @{
                    RequestPath = $handoffRequestPath
                    RequestDocument = $requestDocument
                    ScopePlanPath = $handoffScopePlanPath
                    EventStreamPath = $handoffEventStreamPath
                    RunRecordPath = $handoffRunRecordPath
                    LastMessagePath = $handoffLastMessagePath
                    InspectResultPath = $handoffInspectResultPath
                    SourceRoot = if ([string]::IsNullOrWhiteSpace($sourceRootPath)) { [string]$SourceRoot } else { $sourceRootPath }
                    ExecutionRoot = if ([string]::IsNullOrWhiteSpace($executionRootPath)) { [string]$ExecutionRoot } else { $executionRootPath }
                    DispatchRoot = if ([string]::IsNullOrWhiteSpace($dispatchRootPath)) { [string]$DispatchRoot } else { $dispatchRootPath }
                    LineSlug = [string]$LineSlug
                    DispatchSlug = [string]$DispatchSlug
                    DispatchExecutionId = $dispatchToken
                    FallbackSelectedUnits = @($script:ResolvedRequestedUnit)
                }
                $continuationFailureHandoff = Get-DispatchContinuationFailureHandoff @handoffParameters
            }
            if ($null -ne $continuationFailureHandoff) {
                $failureResult.continuation_handoff = $continuationFailureHandoff
            }
        }
        $failureResult.failure_receipt_sha256 = $null
        if ($failureReceiptWritten) {
            $failureResult.failure_receipt_path = $failureReceiptPathValue
            $failureResult.failure_receipt_sha256 = $failureReceiptSha256Value
            $failureResult.failure_receipt_saved = $true
            $failureResult.continuation_handoff = $continuationFailureHandoff
        }
        elseif (-not [string]::IsNullOrWhiteSpace($failureReceiptPathValue)) {
            try {
                $receiptSourceRoot = if ([string]::IsNullOrWhiteSpace($sourceRootPath)) { [string]$SourceRoot } else { $sourceRootPath }
                $receiptExecutionRoot = if ([string]::IsNullOrWhiteSpace($executionRootPath)) { $receiptSourceRoot } else { $executionRootPath }
                $receiptDispatchRoot = if ([string]::IsNullOrWhiteSpace($DispatchRoot)) { $null } else { [string]$DispatchRoot }
                $writtenReceipt = Write-DispatchFailureReceipt -Path $failureReceiptPathValue -LineSlug ([string]$LineSlug) -DispatchSlug ([string]$DispatchSlug) -DispatchExecutionId $dispatchToken -ErrorCode $errorCode -ErrorMessage $failureException.Message -SourceRoot $receiptSourceRoot -ExecutionRoot $receiptExecutionRoot -DispatchRoot $receiptDispatchRoot -FailedStage $failedStage -ProcessStarted $processStarted -TargetPath @($TargetPath) -ContinuationHandoff $continuationFailureHandoff
                $failureResult.failure_receipt_path = $writtenReceipt.Path
                $failureResult.failure_receipt_sha256 = $writtenReceipt.Sha256
                $failureResult.failure_receipt_saved = $true
            }
            catch {
                $persistenceMessage = $_.Exception.Message
                $failureResult.error_code = 'DispatchFailureReceiptPersistenceFailed'
                $failureResult.error = 'DispatchFailureReceiptPersistenceFailed：' + $persistenceMessage
                $failureResult.failure_receipt_error = $persistenceMessage
                $failureResult.failure_receipt_saved = $false
        if ($processStarted -and [string]$SessionMode -ieq 'continuation') {
            if ($null -eq $continuationFailureHandoff) {
                $requestDocument = if ($null -eq $script:RequestContext) { $null } else { $script:RequestContext.document }
                $handoffScopePlanPath = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('scopePlanPath', 'scope_plan_path'))
                if ([string]::IsNullOrWhiteSpace($handoffScopePlanPath)) { $handoffScopePlanPath = [string]$ScopePlanPath }
                $handoffEventStreamPath = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('eventStreamPath', 'event_stream_path'))
                if ([string]::IsNullOrWhiteSpace($handoffEventStreamPath)) { $handoffEventStreamPath = [string]$EventStreamPath }
                $handoffRunRecordPath = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('runRecordPath', 'run_record_path'))
                if ([string]::IsNullOrWhiteSpace($handoffRunRecordPath)) { $handoffRunRecordPath = [string]$RunRecordPath }
                $handoffLastMessagePath = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('lastMessagePath', 'last_message_path'))
                if ([string]::IsNullOrWhiteSpace($handoffLastMessagePath)) { $handoffLastMessagePath = [string]$LastMessagePath }
                $handoffInspectResultPath = [string](Get-DispatchResultPropertyValue -Object $startResult -Names @('inspectResultPath', 'inspect_result_path'))
                $handoffRequestPath = [string]$RequestPath
                if ([string]::IsNullOrWhiteSpace($handoffRequestPath) -and $null -ne $script:RequestContext) {
                    $handoffRequestPath = [string]$script:RequestContext.path
                }
                $handoffParameters = @{
                    RequestPath = $handoffRequestPath
                    RequestDocument = $requestDocument
                    ScopePlanPath = $handoffScopePlanPath
                    EventStreamPath = $handoffEventStreamPath
                    RunRecordPath = $handoffRunRecordPath
                    LastMessagePath = $handoffLastMessagePath
                    InspectResultPath = $handoffInspectResultPath
                    SourceRoot = if ([string]::IsNullOrWhiteSpace($sourceRootPath)) { [string]$SourceRoot } else { $sourceRootPath }
                    ExecutionRoot = if ([string]::IsNullOrWhiteSpace($executionRootPath)) { [string]$ExecutionRoot } else { $executionRootPath }
                    DispatchRoot = if ([string]::IsNullOrWhiteSpace($dispatchRootPath)) { [string]$DispatchRoot } else { $dispatchRootPath }
                    LineSlug = [string]$LineSlug
                    DispatchSlug = [string]$DispatchSlug
                    DispatchExecutionId = $dispatchToken
                    FallbackSelectedUnits = @($script:ResolvedRequestedUnit)
                }
                $continuationFailureHandoff = Get-DispatchContinuationFailureHandoff @handoffParameters
            }
            if ($null -ne $continuationFailureHandoff) {
                $failureResult.continuation_handoff = $continuationFailureHandoff
            }
        }
                $persistenceException = New-Object System.InvalidOperationException($failureResult.error)
                $persistenceException.Data['operationResult'] = $failureResult
                throw $persistenceException
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($resultPathValue) -and -not [string]::IsNullOrWhiteSpace($sourceRootPath) -and -not [string]::IsNullOrWhiteSpace($executionRootPath)) {
            try {
                $writtenFailure = Write-DispatchAtomicJsonDocument -Path $resultPathValue -Document $failureResult -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
                $failureResult.result_path = $writtenFailure.Path
                $failureResult.result_sha256 = $writtenFailure.Hash
            }
            catch {
                $failureResult.result_write_error = $_.Exception.Message
            }
        }
        $script:DispatchStageBinding = $null
        return $failureResult
    }
}
