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
function Throw-DispatchPreflightFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['errorCode'] = 'DispatchPreflightFailed'
    throw $exception
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
    $gitProbeState = $null
    $targetStates = @()
    $gitProbeState = Get-ExistingGitRepositoryState -SourceRoot $sourceRootPath
    $baseShaValue = ''
    $hasBaseCommit = $false
    if ($gitProbeState.IsRepository) {
        $headResult = Invoke-GitCommand -WorkingDirectory $sourceRootPath -Arguments @('rev-parse', '--verify', 'HEAD^{commit}') -AllowFailure
        if ($headResult.ExitCode -eq 0) {
            $baseShaValue = $headResult.StdOut.Trim()
            if ($baseShaValue -notmatch '^[0-9a-fA-F]{7,64}$') {
                throw "無法取得有效 baseSha：$baseShaValue"
            }
            $hasBaseCommit = $true
        }
    }
    $worktreeCreated = $WriteMode -eq 'readonly' -and $gitProbeState.IsRepository
    $hasTrackedWriteTarget = $false
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

    if ($DispatchKind -eq 'workflow' -and $WriteMode -eq 'write' -and -not $hasTrackedWriteTarget) {
        $targetStateDetails = @(
            foreach ($targetState in $targetStates) {
                'RelativePath={0}, Exists={1}, IsTracked={2}' -f [string]$targetState.RelativePath, [bool]$targetState.Exists, [bool]$targetState.IsTracked
            }
        ) -join '; '
        $baselineCommitMessage = if ($gitProbeState.IsRepository -and -not $hasBaseCommit) { ' Git 儲存庫需要先有基準 commit。' } else { '' }
        Throw-DispatchPreflightFailure -Message ('Workflow write 必須至少包含一個 tracked target；Preflight 未建立產物。目標皆未追蹤時請改走資源派遣 direct-write（dispatch_kind=resource、write_mode=write，Prepare 為 not-required）；Workflow 的 worktree 隔離與 Collect 驗收依賴 git baseline，不放寬此限制。targets: ' + $targetStateDetails + $baselineCommitMessage)
    }

    if ($gitProbeState.IsRepository -and -not $hasBaseCommit) {
        if ($WriteMode -eq 'readonly') {
            $worktreeCreated = $false
        }
        elseif ($WriteMode -eq 'write') {
            Throw-DispatchPreflightFailure -Message 'Git write dispatch 需要先有基準 commit；請先在 SourceRoot 建立 commit，再執行 Preflight。'
        }
    }

    $requestResourceOrder = Get-Variable -Scope Script -Name 'RequestResourceOrder' -ValueOnly -ErrorAction SilentlyContinue
    if ($DispatchKind -eq 'resource' -and $worktreeCreated -and $null -ne $requestResourceOrder) {
        $reportPathValue = [string]$requestResourceOrder.ReportPath
        if (-not [string]::IsNullOrWhiteSpace($reportPathValue)) {
            $resolvedReportPath = Resolve-AbsolutePath -Path $reportPathValue
            if (-not (Test-PathWithinRoot -Path $resolvedReportPath -Root $dispatchRootPath)) {
                $reportPathFailure = New-Object System.InvalidOperationException(('DispatchReportPathOutsideExecutionRoot：派遣單第 7 欄原始路徑={0}；executionRoot={1}。請將第 7 欄改為 executionRoot 內的路徑；完成回收後由 Cleanup 同步至來源。' -f $reportPathValue, $dispatchRootPath))
                $reportPathFailure.Data['errorCode'] = 'DispatchReportPathOutsideExecutionRoot'
                throw $reportPathFailure
            }
        }
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
    $baseline = $null
    if ($worktreeCreated) {
        if (-not $hasBaseCommit) {
            throw 'Preflight worktree 建立前需要有效的基準 commit。'
        }
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

        $dispatchParent = Split-Path -Parent $dispatchRootPath
        $null = New-DispatchOutputDirectory -Path $dispatchParent -SourceRoot $sourceRootPath -ExecutionRoot $sourceRootPath -TargetPath @($TargetPath)
        $worktreeResult = Invoke-GitCommand -WorkingDirectory $sourceRootPath -Arguments @('worktree', 'add', '--detach', $dispatchRootPath, $baseShaValue) -AllowFailure
        if ($worktreeResult.ExitCode -ne 0) {
            throw "建立 dispatch worktree 失敗：$($worktreeResult.StdErr.Trim())"
        }
        $executionRootPath = $dispatchRootPath
        $carryInManifest = Apply-SourceCarryIn -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath
        $null = Sync-DispatchTrackedRawBytesFromSource -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath
        $baseline = New-DispatchBaseline -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -BaseSha $baseShaValue -TargetPath @($TargetPath)
        if ($WriteMode -eq 'readonly') {
            $targetsOutsideRepository = @(Get-TargetsOutsideRepository -SourceRoot $sourceRootPath -DispatchRoot $executionRootPath -TargetPath @($TargetPath))
        }
    }
    elseif ($null -ne $gitProbeState -and $gitProbeState.IsRepository) {
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
        inputWarnings   = @(@(Get-DispatchScriptVariableValue -Name 'DispatchInputFindings') | Where-Object { $null -ne $_ -and $_.severity -eq 'warning' })
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
        inspect_binding = [ordered]@{
            run_record_path = $RunRecordPath
            event_stream_path = $EventStreamPath
            scope_plan_path = $ScopePlanPath
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
    $stageBinding = $null
    $failureReceiptWritten = $false
    $failureReceiptSha256Value = $null
    $continuationFailureHandoff = $null
    $projectTrust = $null
    $previousAccountSelection = Get-DispatchScriptVariableValue -Name 'DispatchAccountSelection'

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
        $ResultPath = $null
        $PreflightResultPath = $null
        $PrepareResultPath = $null

        $failedStage = 'preflight'
        try {
            $script:DispatchAccountSelection = Resolve-CodexAccountSelection -CodexHomePath $CodexHome -Profile $Profile -SourceRoot ([string]$SourceRoot)
        }
        catch {
            if (-not [string]::IsNullOrWhiteSpace([string]$_.Exception.Data['reasonCode'])) {
                $projectTrust = New-CodexProjectTrustRejection -AccountSelection $null -Exception $_.Exception
            }
            throw
        }
        $CodexHome = $script:DispatchAccountSelection.CodexHome
        if ([string]::IsNullOrWhiteSpace($requestedFailureReceiptPath)) {
            throw 'Dispatch request 必須提供 failure_receipt_path。'
        }
        $failureReceiptPathValue = Resolve-DispatchOutputPath -CandidatePath $requestedFailureReceiptPath -SourceRoot ([string]$SourceRoot) -ExecutionRoot ([string]$SourceRoot) -TargetPath @($TargetPath)
        try {
            $projectTrust = Confirm-CodexAccountProjectTrust -AccountSelection $script:DispatchAccountSelection -SourceRoot ([string]$SourceRoot)
        }
        catch {
            $projectTrust = New-CodexProjectTrustRejection -AccountSelection $script:DispatchAccountSelection -Exception $_.Exception
            throw
        }
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
        $dispatchUnitKind = Get-DefaultUnitKind -DispatchKind ([string]$DispatchKind) -UnitKind ([string]$UnitKind) -TaskType ([string]$TaskType)
        $isAdvisorDispatch = $dispatchUnitKind -eq 'advisor-evidence-question'
        $stageBinding = New-DispatchStageBinding -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -TargetPath @($TargetPath) -ResultPath $resultPathValue -PreflightResultPath $preflightResultPathValue -PrepareResultPath $dispatchPrepareResultPath
        $script:DispatchStageBinding = $stageBinding
        $resultPathValue = [string]$stageBinding.result_path
        $PreflightResultPath = [string]$stageBinding.preflight_result_path
        $dispatchPrepareResultPath = [string]$stageBinding.prepare_result_path
        $script:ResultPath = $resultPathValue
        $script:PreflightResultPath = $PreflightResultPath
        $script:PrepareResultPath = $dispatchPrepareResultPath
        $ResultPath = $resultPathValue
        $PreflightResultPath = $PreflightResultPath
        $PrepareResultPath = $dispatchPrepareResultPath
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

        $failedStage = 'prepare'
        if (-not [string]::Equals($sourceRootPath, $executionRootPath, [StringComparison]::OrdinalIgnoreCase) -and $isAdvisorDispatch) {
            $script:RequestAutoPrepareArtifacts = New-Object 'System.Object[]' 0
            $script:RequestPrepareArtifacts = @($script:RequestManualPrepareArtifacts)
            if (@($script:RequestManualPrepareArtifacts).Count -eq 0) {
                $requestedEvidencePackPath = Resolve-AbsolutePath -Path ([string]$script:EvidencePackPath)
                $sourceLineRoot = Join-Path -Path $sourceRootPath -ChildPath ('.local\ai-sessions\handoff\' + $LineSlug)
                $isSourceLineEvidencePack = Test-PathWithinRoot -Path $requestedEvidencePackPath -Root $sourceLineRoot
                if ($isSourceLineEvidencePack) {
                    $script:RequestAutoPrepareArtifacts = @(New-DispatchAutoPrepareArtifacts -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -DispatchKind ([string]$DispatchKind) -WriteMode ([string]$script:WriteMode) -ResourceOrder $null -AdvisorEvidencePackPath $requestedEvidencePackPath)
                    $script:RequestPrepareArtifacts = @($script:RequestAutoPrepareArtifacts)
                    if (@($script:RequestAutoPrepareArtifacts).Count -eq 1) {
                        $script:EvidencePackPath = [string]$script:RequestAutoPrepareArtifacts[0].destination
                    }
                }
                else {
                    $evidenceBoundaryException = New-Object System.InvalidOperationException('AdvisorEvidencePackSourceBoundary：advisor evidence pack 必須位於 sourceRoot 同線 handoff 或 dispatchRoot／executionRoot 內。')
                    $evidenceBoundaryException.Data['errorCode'] = 'AdvisorEvidencePackSourceBoundary'
                    throw $evidenceBoundaryException
                }
            }
            else {
                $requestedEvidencePackPath = Resolve-AbsolutePath -Path ([string]$script:EvidencePackPath)
                $matchingManualEvidenceArtifacts = @($script:RequestManualPrepareArtifacts | Where-Object {
                        [string]::Equals((Resolve-AbsolutePath -Path ([string]$_.source)), $requestedEvidencePackPath, [StringComparison]::OrdinalIgnoreCase) -or
                        [string]::Equals((Resolve-AbsolutePath -Path ([string]$_.destination)), $requestedEvidencePackPath, [StringComparison]::OrdinalIgnoreCase)
                    })
                if ($matchingManualEvidenceArtifacts.Count -eq 1) {
                    $script:EvidencePackPath = Resolve-AbsolutePath -Path ([string]$matchingManualEvidenceArtifacts[0].destination)
                }
                elseif ($matchingManualEvidenceArtifacts.Count -gt 1) {
                    $ambiguousEvidenceException = New-Object System.InvalidOperationException('AdvisorEvidencePackPrepareAmbiguous：prepare_artifacts 包含多筆 evidence pack 來源。')
                    $ambiguousEvidenceException.Data['errorCode'] = 'AdvisorEvidencePackPrepareAmbiguous'
                    throw $ambiguousEvidenceException
                }
            }
        }
        elseif (-not [string]::Equals($sourceRootPath, $executionRootPath, [StringComparison]::OrdinalIgnoreCase)) {
            $script:RequestAutoPrepareArtifacts = @(New-DispatchAutoPrepareArtifacts -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -DispatchKind ([string]$DispatchKind) -WriteMode ([string]$script:WriteMode) -ResourceOrder $script:RequestResourceOrder)
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
        if ($null -ne $script:RequestContext) {
            $script:DispatchInputContext.ExecutionRoot = $executionRootPath
            $worktreeFindings = @(Invoke-DispatchInputChecks -Stage Worktree -Context $script:DispatchInputContext)
            Assert-DispatchInputFindings -Findings $worktreeFindings -RequestPathValue ([string]$script:RequestContext.path)
        }

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
            run_record_path = Get-DispatchResultPropertyValue -Object $startResult -Names @('runRecordPath', 'run_record_path')
            event_stream_path = Get-DispatchResultPropertyValue -Object $startResult -Names @('eventStreamPath', 'event_stream_path')
            last_message_path = Get-DispatchResultPropertyValue -Object $startResult -Names @('lastMessagePath', 'last_message_path')
            inspect_result_path = Get-DispatchResultPropertyValue -Object $startResult -Names @('inspectResultPath', 'inspect_result_path')
            evidence_paths = @($EvidencePath)
        }
        $evidenceBinding = New-DispatchEvidenceBinding -ExecutionRoot $executionRootPath -EvidencePosition $evidencePosition
        $result = New-DispatchResultEnvelope -Status 'started' -LineSlug $LineSlug -DispatchSlug $DispatchSlug -CompletedStages @($completedStages.ToArray()) -FailedStage '' -ErrorCode '' -ErrorMessage '' -ProcessStarted $processStarted -PreflightStage $preflightStage -PrepareStage $prepareStage -StartStage $startStage -ResultPathValue $resultPathValue -StartResultPathValue $startStage.Path -SidecarPath $sidecarPathValue -StageBinding $stageBinding -EvidenceBinding $evidenceBinding
        $result.background = -not [bool]$script:DispatchWaitForCompletion
        $result.requested_units = @($script:ResolvedRequestedUnit)
        $result.project_trust = $projectTrust
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
            $inspectTargetPath = @($TargetPath)
            if ($isAdvisorDispatch -and -not [string]::IsNullOrWhiteSpace($startEvidencePackPath)) {
                $inspectTargetPath = @($startEvidencePackPath)
            }
            $script:RequiredIdentifier = Get-DispatchRequiredIdentifier -ConfiguredIdentifier ([string]$RequiredIdentifier) -DispatchKind ([string]$DispatchKind) -TaskType ([string]$TaskType) -EvidencePackPath $startEvidencePackPath -TargetPath $inspectTargetPath
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
            $priorInspectTargetPath = $script:TargetPath
            if ($isAdvisorDispatch) { $script:TargetPath = @($inspectTargetPath) }
            try {
                $inspectResult = Invoke-Inspect
            }
            finally {
                if ($isAdvisorDispatch) { $script:TargetPath = $priorInspectTargetPath }
            }
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
            $inspectAccountFailover = Get-DispatchResultPropertyValue -Object $inspectResult -Names @('account_failover')
            if ($null -ne $inspectAccountFailover) { $result.account_failover = $inspectAccountFailover }
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
                $result.retry_allowed = Get-DispatchResultPropertyValue -Object $continuationFailureHandoff -Names @('retry_allowed')
                $result.recommended_next_step = Get-DispatchResultPropertyValue -Object $continuationFailureHandoff -Names @('recommended_next_step')
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
        $inputFailure = $failureException.Data['operationResult']
        if ([string]::IsNullOrWhiteSpace($errorCode) -and $null -ne $inputFailure -and [string](Get-DispatchResultPropertyValue -Object $inputFailure -Names @('operation')) -eq 'DispatchRequest') { $errorCode = [string](Get-DispatchResultPropertyValue -Object $inputFailure -Names @('code', 'error_code')) }
        if ([string]::IsNullOrWhiteSpace($errorCode)) {
            $errorCode = switch ($failedStage) {
                'validation' { 'DispatchRequestInvalidValue' }
                'preflight' { 'DispatchPreflightFailed' }
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
        $failureResult = New-DispatchResultEnvelope -Status 'failed' -LineSlug ([string]$LineSlug) -DispatchSlug ([string]$DispatchSlug) -CompletedStages @($completedStages.ToArray()) -FailedStage $failedStage -ErrorCode $errorCode -ErrorMessage $failureException.Message -ProcessStarted $processStarted -PreflightStage $preflightStage -PrepareStage $prepareStage -StartStage $startStage -ResultPathValue $resultPathValue -StartResultPathValue $startResultPathValue -SidecarPath $sidecarPathValue -StageBinding $stageBinding -EvidenceBinding $evidenceBinding
        if ($null -ne $inputFailure -and [string](Get-DispatchResultPropertyValue -Object $inputFailure -Names @('operation')) -eq 'DispatchRequest') {
            $failureResult.detail = Get-DispatchResultPropertyValue -Object $inputFailure -Names @('detail')
        }
        $failureResult.dispatch_execution_id = $dispatchToken
        $failureResult.project_trust = $projectTrust
        $failureOperationAccountFailover = Get-DispatchResultPropertyValue -Object $failureException.Data['operationResult'] -Names @('account_failover')
        if ($null -ne $failureOperationAccountFailover) { $failureResult.account_failover = $failureOperationAccountFailover }
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
    finally {
        $script:DispatchAccountSelection = $previousAccountSelection
    }
}

function Test-DispatchAccountFailoverApplicable {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$CodexHome,
        [bool]$WaitForCompletion,
        [AllowEmptyString()][string]$SessionMode,
        [bool]$NoAccountFailover,
        [AllowNull()][System.Collections.IDictionary]$BoundParameter = $null,
        [string]$MachineConfigPath
    )

    if ($NoAccountFailover -or -not $WaitForCompletion) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($CodexHome)) { return $false }
    if ([string]$SessionMode -ieq 'continuation') { return $false }
    if ($null -ne $BoundParameter) {
        foreach ($name in @($BoundParameter.Keys)) {
            $value = $BoundParameter[$name]
            if ($null -ne $value -and $value -is [System.Array]) { return $false }
        }
    }
    try {
        $accounts = @(Read-CodexAccountConfiguration -MachineConfigPath $MachineConfigPath)
    }
    catch {
        return $false
    }
    return $accounts.Count -gt 0
}

function Invoke-DispatchWithAccountFailover {
    [CmdletBinding()]
    param(
        [switch]$NoAccountFailover,

        [string]$MachineConfigPath
    )

    $boundParameters = Get-DispatchScriptVariableValue -Name 'InvocationBoundParameters'
    $applicable = Test-DispatchAccountFailoverApplicable `
        -CodexHome ([string](Get-DispatchScriptVariableValue -Name 'CodexHome')) `
        -WaitForCompletion ([bool](Get-DispatchScriptVariableValue -Name 'DispatchWaitForCompletion')) `
        -SessionMode ([string](Get-DispatchScriptVariableValue -Name 'SessionMode')) `
        -NoAccountFailover ([bool]$NoAccountFailover) `
        -BoundParameter $boundParameters `
        -MachineConfigPath $MachineConfigPath
    if (-not $applicable) {
        return Invoke-Dispatch
    }
    return Invoke-DispatchAccountFailover `
        -RequestPath ([string](Get-DispatchScriptVariableValue -Name 'RequestPath')) `
        -Profile ([string](Get-DispatchScriptVariableValue -Name 'Profile')) `
        -MachineConfigPath $MachineConfigPath `
        -BoundParameter $boundParameters
}

function Test-DispatchSlugText {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Slug)

    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return [regex]::IsMatch($Text, ('(?<![A-Za-z0-9])' + [regex]::Escape($Slug) + '(?![A-Za-z0-9])'))
}

function Convert-DispatchSlugText {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$OldSlug, [Parameter(Mandatory)][string]$NewSlug)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return [regex]::Replace($Text, ('(?<![A-Za-z0-9])' + [regex]::Escape($OldSlug) + '(?![A-Za-z0-9])'), $NewSlug.Replace('$', '$$'))
}

function New-DispatchAttemptRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][ValidateRange(2, 99)][int]$Attempt
    )

    $originalSlug = [string](Get-DispatchJsonProperty -Object $Document -Name 'dispatch_slug')
    $newSlug = $originalSlug + '-r' + [string]$Attempt
    $missingFields = New-Object 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrWhiteSpace($originalSlug) -or $newSlug -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        return [pscustomobject]@{ derivable = $false; dispatch_slug = $newSlug; document = $null; missing_fields = @('dispatch_slug') }
    }
    $copy = ConvertFrom-DispatchJson -Content (ConvertTo-Json -InputObject $Document -Depth 40)
    foreach ($fieldName in @('dispatch_root', 'failure_receipt_path', 'result_path', 'preflight_result_path', 'prepare_result_path')) {
        $value = Get-DispatchJsonProperty -Object $copy -Name $fieldName
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { continue }
        if (-not (Test-DispatchSlugText -Text ([string]$value) -Slug $originalSlug)) {
            $null = $missingFields.Add($fieldName)
            continue
        }
        Set-DispatchJsonPropertyValue -Object $copy -Name $fieldName -Value (Convert-DispatchSlugText -Text ([string]$value) -OldSlug $originalSlug -NewSlug $newSlug)
    }
    $artifacts = Get-DispatchJsonProperty -Object $copy -Name 'prepare_artifacts'
    if ($null -ne $artifacts) {
        $artifactIndex = 0
        foreach ($artifact in @($artifacts)) {
            $destination = Get-DispatchJsonProperty -Object $artifact -Name 'destination'
            if ($null -ne $destination -and -not [string]::IsNullOrWhiteSpace([string]$destination)) {
                if (Test-DispatchSlugText -Text ([string]$destination) -Slug $originalSlug) {
                    Set-DispatchJsonPropertyValue -Object $artifact -Name 'destination' -Value (Convert-DispatchSlugText -Text ([string]$destination) -OldSlug $originalSlug -NewSlug $newSlug)
                }
                else {
                    $null = $missingFields.Add('prepare_artifacts[' + $artifactIndex + '].destination')
                }
            }
            $artifactIndex++
        }
    }
    Set-DispatchJsonPropertyValue -Object $copy -Name 'dispatch_slug' -Value $newSlug
    return [pscustomobject]@{
        derivable = $missingFields.Count -eq 0
        dispatch_slug = $newSlug
        document = if ($missingFields.Count -eq 0) { $copy } else { $null }
        missing_fields = @($missingFields.ToArray())
    }
}

function ConvertTo-DispatchProcessArgument {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    $null = $builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]'\') {
            $backslashes++
            continue
        }
        if ($character -eq [char]'"') {
            $null = $builder.Append('\', ($backslashes * 2 + 1)).Append('"')
        }
        else {
            $null = $builder.Append('\', $backslashes).Append($character)
        }
        $backslashes = 0
    }
    $null = $builder.Append('\', ($backslashes * 2)).Append('"')
    return $builder.ToString()
}

function Get-DispatchAttemptForwardArgument {
    [CmdletBinding()]
    param(
        [AllowNull()][System.Collections.IDictionary]$BoundParameter,
        [string]$OriginalSlug,
        [string]$NewSlug
    )

    $forward = New-Object 'System.Collections.Generic.List[string]'
    $missing = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $BoundParameter) { return [pscustomobject]@{ arguments = @(); missing_fields = @() } }
    $excluded = @('Operation', 'RequestPath', 'CodexHome', 'NoAccountFailover')
    $slugRequired = @('DispatchSlug', 'DispatchRoot', 'FailureReceiptPath', 'ResultPath', 'PreflightResultPath', 'PrepareResultPath')
    foreach ($name in @($BoundParameter.Keys)) {
        $key = [string]$name
        if ($excluded -contains $key) { continue }
        $value = $BoundParameter[$name]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ([bool]$value) { $null = $forward.Add('-' + $key) }
            continue
        }
        if ($null -eq $value) { continue }
        $text = [string]$value
        if (-not [string]::IsNullOrWhiteSpace($NewSlug)) {
            if (Test-DispatchSlugText -Text $text -Slug $OriginalSlug) {
                $text = Convert-DispatchSlugText -Text $text -OldSlug $OriginalSlug -NewSlug $NewSlug
            }
            elseif ($slugRequired -contains $key) {
                $null = $missing.Add($key)
                continue
            }
        }
        $null = $forward.Add('-' + $key)
        $null = $forward.Add($text)
    }
    return [pscustomobject]@{ arguments = @($forward.ToArray()); missing_fields = @($missing.ToArray()) }
}

function Invoke-DispatchAttemptProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RequestPath,
        [Parameter(Mandatory)][string]$CodexHome,
        [string[]]$ForwardArgument = @(),
        [string]$ResultPathHint
    )

    $entryRoot = [string](Get-DispatchScriptVariableValue -Name 'DispatchEntryScriptRoot')
    $entryScript = Join-Path -Path $entryRoot -ChildPath 'Invoke-CodexDispatch.ps1'
    $hostPath = (Get-Process -Id $PID).Path
    $argumentList = @('-NoProfile', '-NonInteractive', '-File', $entryScript, '-Operation', 'Dispatch', '-RequestPath', $RequestPath, '-CodexHome', $CodexHome, '-NoAccountFailover') + @($ForwardArgument)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $hostPath
    $startInfo.Arguments = (@($argumentList | ForEach-Object { ConvertTo-DispatchProcessArgument -Value ([string]$_) }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exitCode = $process.ExitCode
    $process.Dispose()
    $parsed = $null
    $resultPathValue = $null
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        $jsonText = $stdout.Trim()
        $firstBrace = $jsonText.IndexOf('{')
        $lastBrace = $jsonText.LastIndexOf('}')
        if ($firstBrace -ge 0 -and $lastBrace -gt $firstBrace) {
            try { $parsed = ConvertFrom-DispatchJson -Content $jsonText.Substring($firstBrace, $lastBrace - $firstBrace + 1) } catch { $parsed = $null }
        }
    }
    if ($null -ne $parsed) {
        $parsedResultPath = Get-DispatchResultPropertyValue -Object $parsed -Names @('result_path')
        if ($null -ne $parsedResultPath) { $resultPathValue = [string]$parsedResultPath }
    }
    if ($null -eq $parsed -and -not [string]::IsNullOrWhiteSpace($ResultPathHint) -and (Test-Path -LiteralPath $ResultPathHint -PathType Leaf)) {
        try {
            $parsed = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $ResultPathHint)
            $resultPathValue = $ResultPathHint
        }
        catch { $parsed = $null }
    }
    return [pscustomobject]@{
        exit_code = [int]$exitCode
        stdout = $stdout
        stderr = $stderr
        result = $parsed
        result_path = $resultPathValue
    }
}

function Get-DispatchAttemptProcessStarted {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug
    )

    # 依該次嘗試的 RunRecord 判定 Codex 程序是否已啟動：有任一筆確認啟動回 $true，
    # 全部筆數都確認為未啟動（pre-start 階段失敗）回 $false，沒有 RunRecord 或無法判定回 $null（未知）。
    try {
        $directory = Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return $null }
        $classifications = New-Object 'System.Collections.Generic.List[object]'
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -ErrorAction Stop)) {
            $record = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $file.FullName)
            if ($null -eq $record -or $record -isnot [pscustomobject]) { return $null }
            $null = $classifications.Add((Get-DispatchRunRecordStartClassification -Record $record))
        }
        if ($classifications.Count -eq 0) { return $null }
        if (@($classifications.ToArray() | Where-Object { $_.process_started -eq $true }).Count -gt 0) { return $true }
        if (@($classifications.ToArray() | Where-Object { [string]$_.classification -ceq 'unstarted-sandbox' }).Count -eq $classifications.Count) { return $false }
        return $null
    }
    catch {
        return $null
    }
}

function Write-DispatchAccountFailoverSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][object]$Document
    )

    return Write-DispatchAtomicJsonDocument -Path $Path -Document $Document -SourceRoot $SourceRoot -ExecutionRoot $SourceRoot -TargetPath @() -HashProperty '' -RequireAbsent -AbsentErrorCode 'DispatchAccountFailoverSummaryCollision'
}

function Invoke-DispatchAccountFailover {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RequestPath,
        [string]$Profile,
        [string]$MachineConfigPath,
        [AllowNull()][System.Collections.IDictionary]$BoundParameter = $null
    )

    $requestPathValue = Resolve-AbsolutePath -Path $RequestPath
    $document = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $requestPathValue)
    $sourceRootValue = [string](Get-DispatchJsonProperty -Object $document -Name 'source_root')
    if ([string]::IsNullOrWhiteSpace($sourceRootValue)) { $sourceRootValue = [string](Get-DispatchScriptVariableValue -Name 'SourceRoot') }
    $sourceRootPath = Resolve-AbsolutePath -Path $sourceRootValue
    $lineSlugValue = [string](Get-DispatchJsonProperty -Object $document -Name 'line_slug')
    $dispatchSlugValue = [string](Get-DispatchJsonProperty -Object $document -Name 'dispatch_slug')
    $profileValue = $Profile
    if ([string]::IsNullOrWhiteSpace($profileValue)) { $profileValue = [string](Get-DispatchJsonProperty -Object $document -Name 'profile') }
    $summaryPath = Join-Path -Path (Join-Path -Path (Join-Path -Path $sourceRootPath -ChildPath '.local\ai-sessions\history') -ChildPath $lineSlugValue) -ChildPath ('dispatch-account-failover-' + $dispatchSlugValue + '.json')
    if ([System.IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $summaryPath))) {
        throw ('DispatchAccountFailoverSummaryCollision：摘要檔已存在，拒絕覆寫：' + $summaryPath)
    }

    $candidateSet = Get-CodexDispatchAccountCandidates -Profile $profileValue -MachineConfigPath $MachineConfigPath -SourceRoot $sourceRootPath
    $candidates = @($candidateSet.candidates)
    $summary = [ordered]@{
        schema = 'ai-sessions.dispatch-account-failover.v1'
        line_slug = $lineSlugValue
        dispatch_slug = $dispatchSlugValue
        candidates = @($candidates)
        skipped = @($candidateSet.skipped)
        attempts = @()
        all_unavailable = $false
        final_attempt = $null
        skipped_reason = $null
    }
    if ($candidates.Count -eq 0) {
        $summary.all_unavailable = $true
        $null = Write-DispatchAccountFailoverSummary -Path $summaryPath -SourceRoot $sourceRootPath -Document $summary
        throw ('CodexAccountsAllUnavailable：' + (Format-CodexAccountSkippedSummary -Skipped @($candidateSet.skipped)))
    }

    $attempts = New-Object 'System.Collections.Generic.List[object]'
    $finalResult = $null
    $loopError = $null
    $attemptNumber = 0
    try {
        foreach ($candidate in $candidates) {
            $attemptNumber++
            $attemptRequestPath = $requestPathValue
            $attemptSlug = $dispatchSlugValue
            $attemptDocument = $document
            $forwardArguments = @()
            if ($attemptNumber -ge 2) {
                $derived = New-DispatchAttemptRequest -Document $document -Attempt $attemptNumber
                $forward = Get-DispatchAttemptForwardArgument -BoundParameter $BoundParameter -OriginalSlug $dispatchSlugValue -NewSlug ([string]$derived.dispatch_slug)
                if (-not [bool]$derived.derivable -or @($forward.missing_fields).Count -gt 0) {
                    $summary.skipped_reason = 'AccountFailoverNotDerivable'
                    break
                }
                $attemptSlug = [string]$derived.dispatch_slug
                $attemptDocument = $derived.document
                $attemptRequestPath = Join-Path -Path (Join-Path -Path (Join-Path -Path $sourceRootPath -ChildPath '.local\ai-sessions\history') -ChildPath $lineSlugValue) -ChildPath ('dispatch-request-' + $attemptSlug + '.json')
                $null = Write-DispatchAtomicJsonDocument -Path $attemptRequestPath -Document $attemptDocument -SourceRoot $sourceRootPath -ExecutionRoot $sourceRootPath -TargetPath @() -HashProperty '' -RequireAbsent -AbsentErrorCode 'DispatchAccountFailoverRequestCollision'
                $forwardArguments = @($forward.arguments)
            }
            else {
                $forward = Get-DispatchAttemptForwardArgument -BoundParameter $BoundParameter -OriginalSlug $dispatchSlugValue -NewSlug ''
                $forwardArguments = @($forward.arguments)
            }
            $resultPathHint = [string](Get-DispatchJsonProperty -Object $attemptDocument -Name 'result_path')
            $run = Invoke-DispatchAttemptProcess -RequestPath $attemptRequestPath -CodexHome ([string]$candidate.codex_home) -ForwardArgument $forwardArguments -ResultPathHint $resultPathHint
            $result = $run.result
            $status = if ($null -eq $result) { '' } else { [string](Get-DispatchResultPropertyValue -Object $result -Names @('status')) }
            $accountFailover = if ($null -eq $result) { $null } else { Get-DispatchResultPropertyValue -Object $result -Names @('account_failover') }
            $eligible = $null -ne $accountFailover -and (Get-DispatchJsonProperty -Object $accountFailover -Name 'eligible') -eq $true
            $outcome = if ($status -ceq 'completed') { 'completed' } elseif ($status -ceq 'failed' -and $eligible) { 'rejected' } else { 'failed' }
            $kindValue = if ($null -eq $accountFailover) { $null } else { Get-DispatchJsonProperty -Object $accountFailover -Name 'rejection_kind' }
            $itemCountValue = if ($null -eq $accountFailover) { $null } else { Get-DispatchJsonProperty -Object $accountFailover -Name 'item_event_count' }
            $dispatchRootValue = [string](Get-DispatchJsonProperty -Object $attemptDocument -Name 'dispatch_root')
            $attemptProjectTrust = $null
            if ($null -ne $result) {
                $resultDispatchRoot = Get-DispatchResultPropertyValue -Object $result -Names @('dispatch_root', 'dispatchRoot')
                if ($null -ne $resultDispatchRoot) { $dispatchRootValue = [string]$resultDispatchRoot }
                $attemptProjectTrust = Get-DispatchResultPropertyValue -Object $result -Names @('project_trust')
            }
            $resultPathValue = if ($null -ne $result -and $null -ne (Get-DispatchResultPropertyValue -Object $result -Names @('result_path'))) { [string](Get-DispatchResultPropertyValue -Object $result -Names @('result_path')) } else { $run.result_path }
            $null = $attempts.Add([ordered]@{
                    attempt = $attemptNumber
                    dispatch_slug = $attemptSlug
                    account_name = [string]$candidate.name
                    codex_home = [string]$candidate.codex_home
                    outcome = $outcome
                    rejection_kind = if ($null -eq $kindValue) { $null } else { [string]$kindValue }
                    item_event_count = if ($null -eq $itemCountValue) { $null } else { [int]$itemCountValue }
                    dispatch_root = if ([string]::IsNullOrWhiteSpace($dispatchRootValue)) { $null } else { $dispatchRootValue }
                    result_path = if ([string]::IsNullOrWhiteSpace($resultPathValue)) { $null } else { $resultPathValue }
                    project_trust = $attemptProjectTrust
                })
            $summary.final_attempt = $attemptNumber
            if ($null -eq $result) {
                $attemptProcessStarted = Get-DispatchAttemptProcessStarted -SourceRoot $sourceRootPath -LineSlug $lineSlugValue -DispatchSlug $attemptSlug
                $finalResult = [ordered]@{
                    schema = 'ai-sessions.dispatch-result.v1'
                    operation = 'Dispatch'
                    status = 'failed'
                    line_slug = $lineSlugValue
                    dispatch_slug = $attemptSlug
                    failed_stage = 'dispatch-account-failover'
                    error_code = 'DispatchAccountFailoverAttemptFailed'
                    error = ('Dispatch 子程序未回傳可解析的結果；exit_code=' + [string]$run.exit_code + '; stderr=' + [string]$run.stderr)
                    process_started = $attemptProcessStarted
                }
            }
            else {
                $finalResult = $result
            }
            if ($outcome -cne 'rejected') { break }
        }
    }
    catch {
        $loopError = $_
    }
    $summary.attempts = @($attempts.ToArray())
    $summary.all_unavailable = $attempts.Count -gt 0 -and $attempts.Count -eq $candidates.Count -and @($attempts.ToArray() | Where-Object { [string]$_.outcome -cne 'rejected' }).Count -eq 0
    $null = Write-DispatchAccountFailoverSummary -Path $summaryPath -SourceRoot $sourceRootPath -Document $summary
    if ($null -ne $loopError) { throw $loopError }
    $failoverEvidence = [ordered]@{
        summary_path = $summaryPath
        attempt_count = $attempts.Count
        all_unavailable = [bool]$summary.all_unavailable
        error_code = if ([bool]$summary.all_unavailable) { 'CodexAccountsAllUnavailable' } else { $null }
        skipped_reason = $summary.skipped_reason
        skipped = @($candidateSet.skipped | ForEach-Object {
                [ordered]@{
                    name = [string]$_.name
                    reason_code = [string]$_.reason_code
                    config_path = $_.config_path
                    detail = $_.detail
                }
            })
    }
    if ($null -eq $finalResult) {
        throw 'DispatchAccountFailoverAttemptFailed：沒有任何嘗試產生結果。'
    }
    if ($finalResult -isnot [System.Collections.IDictionary]) {
        $resultDictionary = [ordered]@{}
        foreach ($resultProperty in $finalResult.PSObject.Properties) { $resultDictionary[$resultProperty.Name] = $resultProperty.Value }
        $finalResult = $resultDictionary
    }
    $finalResult['account_failover_summary'] = $failoverEvidence
    if ([bool]$summary.all_unavailable) {
        $attemptSummaryText = (@($attempts.ToArray() | ForEach-Object { [string]$_.account_name + ':' + [string]$_.rejection_kind }) -join '; ')
        if (@($candidateSet.skipped).Count -gt 0) { $attemptSummaryText += '; 略過：' + (Format-CodexAccountSkippedSummary -Skipped @($candidateSet.skipped)) }
        [Console]::Error.WriteLine('CodexAccountsAllUnavailable：' + $attemptSummaryText)
    }
    return $finalResult
}
