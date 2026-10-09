function Get-PrepareRootInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [string]$ExecutionRoot,

        [string]$DispatchRoot,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
        [string]$DispatchSlug
    )

    if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
        throw 'Prepare 必須提供 SourceRoot。'
    }

    $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
    if (-not (Test-Path -LiteralPath $sourceRootPath -PathType Container)) {
        throw "sourceRoot 不存在或不是目錄：$sourceRootPath"
    }
    $sourceReportLineRoot = Join-Path -Path $sourceRootPath -ChildPath (Join-Path -Path '.local\ai-sessions\report' -ChildPath $LineSlug)

    $executionRootValue = $ExecutionRoot
    if ([string]::IsNullOrWhiteSpace($executionRootValue)) {
        $executionRootValue = $DispatchRoot
    }
    if ([string]::IsNullOrWhiteSpace($executionRootValue)) {
        $executionRootValue = $sourceRootPath
    }
    $executionRootPath = Resolve-AbsolutePath -Path $executionRootValue
    if (-not (Test-Path -LiteralPath $executionRootPath -PathType Container)) {
        throw "executionRoot 不存在或不是目錄：$executionRootPath"
    }

    $dispatchRootValue = $DispatchRoot
    if ([string]::IsNullOrWhiteSpace($dispatchRootValue)) {
        $dispatchRootValue = $executionRootPath
    }
    $dispatchRootPath = Resolve-AbsolutePath -Path $dispatchRootValue
    if (-not [string]::Equals($dispatchRootPath, $executionRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Prepare 的 DispatchRoot 必須與 ExecutionRoot 一致。'
    }

    $manifestInfo = Read-LineManifest -SourceRoot $sourceRootPath -LineSlug $LineSlug
    $dispatchLineRoot = Join-Path -Path $executionRootPath -ChildPath (Join-Path -Path '.local\ai-sessions\handoff' -ChildPath $LineSlug)
    $reportLineRoot = Join-Path -Path $executionRootPath -ChildPath (Join-Path -Path '.local\ai-sessions\report' -ChildPath $LineSlug)
    $historyLineRoot = Join-Path -Path $executionRootPath -ChildPath (Join-Path -Path '.local\ai-sessions\history' -ChildPath $LineSlug)
    $sourceDispatchOrderPath = Join-Path -Path $sourceRootPath -ChildPath ('.local\ai-sessions\handoff\dispatch-order-' + $DispatchSlug + '.md')

    return [pscustomobject]@{
        SourceRoot       = $sourceRootPath
        ExecutionRoot    = $executionRootPath
        DispatchRoot     = $dispatchRootPath
        LineSlug         = $LineSlug
        DispatchSlug     = $DispatchSlug
        ManifestInfo     = $manifestInfo
        SourceLineRoot   = $manifestInfo.SourceLineRoot
        SourceReportLineRoot = $sourceReportLineRoot
        SourceLineRoots  = @(
            [pscustomobject]@{ Name = 'handoff-line-root'; Path = $manifestInfo.SourceLineRoot }
            [pscustomobject]@{ Name = 'report-line-root'; Path = $sourceReportLineRoot }
            [pscustomobject]@{ Name = 'dispatch-order'; Path = $sourceDispatchOrderPath }
        )
        DispatchLineRoot = $dispatchLineRoot
        ReportLineRoot   = $reportLineRoot
        HistoryLineRoot  = $historyLineRoot
        DestinationRoots = @(
            [pscustomobject]@{ Name = 'dispatch-line-root'; Path = $dispatchLineRoot }
            [pscustomobject]@{ Name = 'report-line-root'; Path = $reportLineRoot }
            [pscustomobject]@{ Name = 'history-line-root'; Path = $historyLineRoot }
        )
    }
}

function Resolve-PrepareDestinationRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object[]]$DestinationRoots
    )

    $resolvedPath = Resolve-AbsolutePath -Path $Path
    foreach ($root in @($DestinationRoots)) {
        if (Test-PathWithinRoot -Path $resolvedPath -Root ([string]$root.Path)) {
            return [pscustomobject]@{
                Name = [string]$root.Name
                Path = Resolve-AbsolutePath -Path ([string]$root.Path)
            }
        }
    }
    return $null
}

function Resolve-PrepareSourceRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object[]]$SourceRoots
    )

    $resolvedPath = Resolve-AbsolutePath -Path $Path
    foreach ($root in @($SourceRoots)) {
        $rootPath = if ($root -is [string]) { [string]$root } else { [string]$root.Path }
        if ([string]::IsNullOrWhiteSpace($rootPath)) {
            continue
        }
        if (Test-PathWithinRoot -Path $resolvedPath -Root $rootPath) {
            return [pscustomobject]@{
                Name = if ($root -is [string]) { 'source-root' } else { [string]$root.Name }
                Path = Resolve-AbsolutePath -Path $rootPath
            }
        }
    }
    return $null
}

function Get-PrepareReceivedFileName {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Path
    )

    try {
        $fileName = [System.IO.Path]::GetFileName($Path)
        if (-not [string]::IsNullOrWhiteSpace($fileName)) {
            return $fileName
        }
    }
    catch {
    }
    return '<unresolved>'
}

function Get-PrepareDestinationRootsDescription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$RootInfo
    )

    $roots = foreach ($root in @($RootInfo.DestinationRoots)) {
        $name = [string]$root.Name
        $path = [string]$root.Path
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = 'destination-root'
        }
        if ([string]::IsNullOrWhiteSpace($path)) {
            $path = '<unresolved>'
        }
        '{0}={1}' -f $name, $path
    }
    if (@($roots).Count -eq 0) {
        return '<none>'
    }
    return [string]::Join(', ', @($roots))
}

function New-PrepareResultPathDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$RootInfo,

        [AllowEmptyString()]
        [string]$ReceivedPath,

        [AllowEmptyString()]
        [string]$ResolvedPath,

        [Parameter(Mandatory)]
        [string]$Correction,

        [AllowEmptyString()]
        [string]$Detail
    )

    $resolvedValue = if ([string]::IsNullOrWhiteSpace($ResolvedPath)) { '<unresolved>' } else { $ResolvedPath }
    $detailValue = if ([string]::IsNullOrWhiteSpace($Detail)) { '<none>' } else { $Detail }
    return 'received_filename={0}; resolved_path={1}; allowed_destination_roots={2}; correction={3}; detail={4}' -f `
        (Get-PrepareReceivedFileName -Path $ReceivedPath),
        $resolvedValue,
        (Get-PrepareDestinationRootsDescription -RootInfo $RootInfo),
        $Correction,
        $detailValue
}

function Get-PrepareDocumentFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Document
    )

    $fingerprintDocument = [ordered]@{}
    if ($Document -is [System.Collections.IDictionary]) {
        foreach ($key in $Document.Keys) {
            if ([string]$key -cne 'result_sha256') {
                $fingerprintDocument[[string]$key] = $Document[$key]
            }
        }
    }
    else {
        foreach ($property in $Document.PSObject.Properties) {
            if ($property.Name -cne 'result_sha256') {
                $fingerprintDocument[$property.Name] = $property.Value
            }
        }
    }
    return Get-JsonSha256 -Value $fingerprintDocument
}

function Get-DispatchResultLockPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResolvedPath
    )

    $normalizedPath = [System.IO.Path]::GetFullPath($ResolvedPath)
    if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        $normalizedPath = $normalizedPath.ToUpperInvariant()
    }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $identity = ([System.BitConverter]::ToString(
                $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalizedPath)))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
    $lockRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'codex-dispatch-result-locks'
    return Join-Path $lockRoot ('.dispatch-' + $identity + '.lock')
}

function Open-DispatchResultLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResolvedPath,

        [ValidateRange(1, 120)]
        [int]$TimeoutSeconds = 30
    )

    $lockPath = Get-DispatchResultLockPath -ResolvedPath $ResolvedPath
    $lockRoot = Resolve-AbsolutePath -Path ([System.IO.Path]::GetTempPath())
    $lockParent = Split-Path -Parent $lockPath
    Assert-DispatchOutputPathNoReparsePoint -Root $lockRoot -Path $lockPath
    $null = New-DispatchOutputDirectory -Path $lockParent -AllowedRoot @($lockRoot)
    Assert-DispatchOutputPathNoReparsePoint -Root $lockRoot -Path $lockPath
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        try {
            Assert-DispatchOutputPathNoReparsePoint -Root $lockRoot -Path $lockPath
            $stream = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
            return [pscustomobject]@{
                Path   = $lockPath
                Stream = $stream
            }
        }
        catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                $lockTimeout = New-Object System.InvalidOperationException("Dispatch result lock timeout: $lockPath")
                $lockTimeout.Data['errorCode'] = 'DispatchResultLockTimeout'
                $lockTimeout.Data['lockPath'] = $lockPath
                throw $lockTimeout
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Get-DispatchStageBindingFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Binding
    )

    $fingerprintDocument = [ordered]@{}
    foreach ($key in $Binding.Keys) {
        if ([string]$key -cne 'fingerprint') {
            $fingerprintDocument[[string]$key] = $Binding[$key]
        }
    }
    return Get-JsonSha256 -Value $fingerprintDocument
}

function New-DispatchStageBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$DispatchRoot,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [string[]]$TargetPath,

        [Parameter(Mandatory)]
        [string]$ResultPath,

        [Parameter(Mandatory)]
        [string]$PreflightResultPath,

        [Parameter(Mandatory)]
        [string]$PrepareResultPath,

        [AllowEmptyString()]
        [string]$QuotaBeforePath,

        [AllowEmptyString()]
        [string]$QuotaAfterPath
    )

    $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
    $executionRootPath = Resolve-AbsolutePath -Path $ExecutionRoot
    $dispatchRootPath = Resolve-AbsolutePath -Path $DispatchRoot
    $normalizedTargetPaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($target in @($TargetPath)) {
        if ([string]::IsNullOrWhiteSpace([string]$target)) {
            throw 'Dispatch stage binding 的 TargetPath 不可包含空白值。'
        }
        $normalizedTargetPaths.Add((Resolve-SourceTargetPath -Path ([string]$target) -Root $sourceRootPath))
    }

    $resolveOutputPath = {
        param([string]$CandidatePath, [string]$Name, [bool]$AllowNull)
        if ([string]::IsNullOrWhiteSpace($CandidatePath)) {
            if ($AllowNull) {
                return $null
            }
            throw ('Dispatch stage binding 缺少 ' + $Name + '。')
        }
        $resolvedCandidate = Resolve-AbsolutePath -Path $CandidatePath
        return Resolve-DispatchOutputPath -CandidatePath $resolvedCandidate -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($normalizedTargetPaths.ToArray())
    }
    $resultPathValue = & $resolveOutputPath $ResultPath 'result_path' $false
    $preflightResultPathValue = & $resolveOutputPath $PreflightResultPath 'preflight_result_path' $false
    $prepareResultPathValue = & $resolveOutputPath $PrepareResultPath 'prepare_result_path' $false
    $quotaBeforePathValue = & $resolveOutputPath $QuotaBeforePath 'quota_before_path' $true
    $quotaAfterPathValue = & $resolveOutputPath $QuotaAfterPath 'quota_after_path' $true

    $binding = [ordered]@{
        schema                 = 'ai-sessions.dispatch-stage-binding.v1'
        source_root            = $sourceRootPath
        execution_root         = $executionRootPath
        dispatch_root          = $dispatchRootPath
        line_slug              = $LineSlug
        dispatch_slug          = $DispatchSlug
        target_path            = @($normalizedTargetPaths.ToArray())
        result_path            = $resultPathValue
        preflight_result_path  = $preflightResultPathValue
        prepare_result_path    = $prepareResultPathValue
        quota_before_path      = $quotaBeforePathValue
        quota_after_path       = $quotaAfterPathValue
    }
    $binding.fingerprint = Get-DispatchStageBindingFingerprint -Binding $binding
    return $binding
}

function Assert-DispatchStageBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Binding,

        [Parameter(Mandatory)]
        [ValidateSet('preflight', 'prepare', 'start')]
        [string]$Stage,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$DispatchRoot,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [string[]]$TargetPath,

        [Parameter(Mandatory)]
        [string]$ResultPath,

        [Parameter(Mandatory)]
        [string]$PreflightResultPath,

        [Parameter(Mandatory)]
        [string]$PrepareResultPath,

        [AllowEmptyString()]
        [string]$QuotaBeforePath,

        [AllowEmptyString()]
        [string]$QuotaAfterPath
    )

    $expected = New-DispatchStageBinding -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -DispatchRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -TargetPath @($TargetPath) -ResultPath $ResultPath -PreflightResultPath $PreflightResultPath -PrepareResultPath $PrepareResultPath -QuotaBeforePath $QuotaBeforePath -QuotaAfterPath $QuotaAfterPath
    $actualFingerprint = Get-DispatchStageBindingFingerprint -Binding $Binding
    $receivedFingerprint = [string](Get-DispatchJsonProperty -Object $Binding -Name 'fingerprint')
    if ([string]::IsNullOrWhiteSpace($receivedFingerprint) -or $receivedFingerprint -ine $actualFingerprint -or $receivedFingerprint -ine [string]$expected.fingerprint) {
        throw "DispatchStageBindingConflict：$Stage 的 stage binding fingerprint 不一致。"
    }

    foreach ($name in @('source_root', 'execution_root', 'dispatch_root', 'result_path', 'preflight_result_path', 'prepare_result_path', 'quota_before_path', 'quota_after_path')) {
        $expectedValue = [string](Get-DispatchJsonProperty -Object $expected -Name $name)
        $receivedValue = [string](Get-DispatchJsonProperty -Object $Binding -Name $name)
        if (-not [string]::Equals($expectedValue, $receivedValue, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "DispatchStageBindingConflict：$Stage 的 $name 與既有 stage binding 不一致。"
        }
    }
    foreach ($name in @('line_slug', 'dispatch_slug')) {
        if (-not [string]::Equals([string](Get-DispatchJsonProperty -Object $expected -Name $name), [string](Get-DispatchJsonProperty -Object $Binding -Name $name), [System.StringComparison]::Ordinal)) {
            throw "DispatchStageBindingConflict：$Stage 的 $name 與既有 stage binding 不一致。"
        }
    }
    $expectedTargets = @((Get-DispatchJsonProperty -Object $expected -Name 'target_path'))
    $receivedTargets = @((Get-DispatchJsonProperty -Object $Binding -Name 'target_path'))
    if ($expectedTargets.Count -ne $receivedTargets.Count) {
        throw "DispatchStageBindingConflict：$Stage 的 target_path 數量與既有 stage binding 不一致。"
    }
    for ($index = 0; $index -lt $expectedTargets.Count; $index++) {
        if (-not [string]::Equals([string]$expectedTargets[$index], [string]$receivedTargets[$index], [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "DispatchStageBindingConflict：$Stage 的 target_path 與既有 stage binding 不一致。"
        }
    }
    return $true
}

function Write-DispatchAtomicJsonDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [psobject]$Document,

        [AllowEmptyString()]
        [string]$SourceRoot,

        [AllowEmptyString()]
        [string]$ExecutionRoot,

        [string[]]$TargetPath = @(),

        [string]$HashProperty = 'result_sha256',

        [AllowEmptyString()]
        [string]$ExpectedExistingSha256,

        [switch]$RequireAbsent,

        [string]$AbsentErrorCode = 'DispatchResultBindingConflict'
    )

    $context = Get-DispatchOutputPathContext -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    $resolvedPath = Resolve-DispatchOutputPathFromContext -CandidatePath $Path -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
    $documentHash = $null
    if (-not [string]::IsNullOrWhiteSpace($HashProperty)) {
        $fingerprintDocument = [ordered]@{}
        if ($Document -is [System.Collections.IDictionary]) {
            foreach ($key in $Document.Keys) {
                if ([string]$key -cne $HashProperty) {
                    $fingerprintDocument[[string]$key] = $Document[$key]
                }
            }
        }
        else {
            foreach ($property in $Document.PSObject.Properties) {
                if ($property.Name -cne $HashProperty) {
                    $fingerprintDocument[$property.Name] = $property.Value
                }
            }
        }
        $documentHash = Get-JsonSha256 -Value $fingerprintDocument
        if ($Document -is [System.Collections.IDictionary]) {
            $Document[$HashProperty] = $documentHash
        }
        else {
            $hashPropertyInfo = $Document.PSObject.Properties[$HashProperty]
            if ($null -eq $hashPropertyInfo) {
                $Document | Add-Member -MemberType NoteProperty -Name $HashProperty -Value $documentHash
            }
            else {
                $hashPropertyInfo.Value = $documentHash
            }
        }
    }

    $parent = Split-Path -Parent $resolvedPath
    $null = New-DispatchOutputDirectory -Path $parent -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
    $resolvedPath = Resolve-DispatchOutputPathFromContext -CandidatePath $resolvedPath -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
    $lock = $null
    $temporaryPath = $null
    $resolvedFileApiPath = ConvertTo-FileSystemApiPath -Path $resolvedPath
    try {
        $lock = Open-DispatchResultLock -ResolvedPath $resolvedPath
        if ($RequireAbsent -and [System.IO.File]::Exists($resolvedFileApiPath)) {
            $collision = New-Object System.InvalidOperationException(($AbsentErrorCode + ': 目標檔案已存在，拒絕覆寫：' + $resolvedPath))
            $collision.Data['errorCode'] = $AbsentErrorCode
            $collision.Data['path'] = $resolvedPath
            throw $collision
        }
        $temporaryPath = Join-Path -Path $parent -ChildPath ([guid]::NewGuid().ToString('D') + '.dispatch.tmp')
        $temporaryPath = Resolve-DispatchOutputPathFromContext -CandidatePath $temporaryPath -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
        Write-Utf8NoBom -Path $temporaryPath -Content ((ConvertTo-Json -InputObject $Document -Depth 40) + "
") -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
        if (-not [string]::IsNullOrWhiteSpace($ExpectedExistingSha256)) {
            if (-not [System.IO.File]::Exists($resolvedFileApiPath)) {
                $conflict = New-Object System.InvalidOperationException("Dispatch result binding target disappeared: $resolvedPath")
                $conflict.Data['errorCode'] = 'DispatchResultBindingConflict'
                $conflict.Data['expected_sha256'] = $ExpectedExistingSha256
                $conflict.Data['actual_sha256'] = $null
                throw $conflict
            }
            $actualExistingSha256 = Get-FileSha256 -Path $resolvedPath
            if (-not [string]::Equals($ExpectedExistingSha256, $actualExistingSha256, [StringComparison]::OrdinalIgnoreCase)) {
                $conflict = New-Object System.InvalidOperationException("Dispatch result binding target changed: $resolvedPath")
                $conflict.Data['errorCode'] = 'DispatchResultBindingConflict'
                $conflict.Data['expected_sha256'] = $ExpectedExistingSha256
                $conflict.Data['actual_sha256'] = $actualExistingSha256
                throw $conflict
            }
        }
        if ([System.IO.File]::Exists($resolvedFileApiPath)) {
            if ($RequireAbsent) {
                $collision = New-Object System.InvalidOperationException(($AbsentErrorCode + ': 原子提交前發現目標檔案已存在：' + $resolvedPath))
                $collision.Data['errorCode'] = $AbsentErrorCode
                $collision.Data['path'] = $resolvedPath
                throw $collision
            }
            $resolvedPath = Resolve-DispatchOutputPathFromContext -CandidatePath $resolvedPath -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
            $resolvedFileApiPath = ConvertTo-FileSystemApiPath -Path $resolvedPath
            [System.IO.File]::Replace((ConvertTo-FileSystemApiPath -Path $temporaryPath), $resolvedFileApiPath, [System.Management.Automation.Language.NullString]::Value)
        }
        elseif ([System.IO.Directory]::Exists($resolvedFileApiPath)) {
            throw "Dispatch result 目的路徑不是檔案：$resolvedPath"
        }
        else {
            $resolvedPath = Resolve-DispatchOutputPathFromContext -CandidatePath $resolvedPath -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
            $resolvedFileApiPath = ConvertTo-FileSystemApiPath -Path $resolvedPath
            [System.IO.File]::Move((ConvertTo-FileSystemApiPath -Path $temporaryPath), $resolvedFileApiPath)
        }
    }
    catch {
        if ($null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        if ($null -ne $lock -and $null -ne $lock.Stream) {
            $lock.Stream.Dispose()
        }
    }

    return [pscustomobject]@{
        Path   = $resolvedPath
        Sha256 = Get-FileSha256 -Path $resolvedPath
        Hash   = $documentHash
        Document = $Document
    }
}

function Get-DispatchInterruptionCheckpointPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$LineSlug,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$DispatchSlug,
        [Parameter(Mandatory)][string]$RunId
    )

    $parsedRunId = [guid]::Empty
    if (-not [guid]::TryParseExact($RunId, 'D', [ref]$parsedRunId)) {
        throw 'Interruption checkpoint run_id 必須為 GUID。'
    }
    $lineHistoryRoot = Join-Path -Path (Join-Path -Path (Resolve-AbsolutePath -Path $SourceRoot) -ChildPath '.local\ai-sessions\history') -ChildPath $LineSlug
    return Join-Path -Path $lineHistoryRoot -ChildPath ('interruption-checkpoint-' + $DispatchSlug + '-' + $parsedRunId.ToString('D') + '.json')
}

function New-DispatchInterruptionCheckpointDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string[]]$SelectedUnits,
        [Parameter(Mandatory)][string]$ScopePlanPath,
        [Parameter(Mandatory)][string]$RunRecordPath,
        [Parameter(Mandatory)][string]$EventStreamPath
    )

    return [ordered]@{
        schema = 'ai-sessions.dispatch-interruption-checkpoint.v1'
        line_slug = $LineSlug
        dispatch_slug = $DispatchSlug
        run_id = $RunId
        selected_units = @($SelectedUnits)
        confirmed_units = @()
        incomplete_units = @($SelectedUnits)
        source_locations = @(
            [ordered]@{ kind = 'scope_plan'; path = Resolve-AbsolutePath -Path $ScopePlanPath }
            [ordered]@{ kind = 'run_record'; path = Resolve-AbsolutePath -Path $RunRecordPath }
            [ordered]@{ kind = 'event_stream'; path = Resolve-AbsolutePath -Path $EventStreamPath }
        )
        updated_at_utc = [datetime]::UtcNow.ToString('o')
    }
}

function Get-DispatchInterruptionCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SourceRoot,
        [string]$ExecutionRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SelectedUnits,
        [string[]]$SourcePath = @()
    )

    $pathValue = Resolve-AbsolutePath -Path $Path
    $expectedPath = Get-DispatchInterruptionCheckpointPath -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId $RunId
    $emptyConfirmedUnits = @()
    $emptyResult = {
        param([string]$Status, [string]$Reason)
        return [ordered]@{
            status = $Status
            path = $pathValue
            line_slug = $LineSlug
            dispatch_slug = $DispatchSlug
            run_id = $RunId
            selected_units = @($SelectedUnits)
            confirmed_units = $emptyConfirmedUnits
            incomplete_units = @($SelectedUnits)
            source_locations = @($SourcePath | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { Resolve-AbsolutePath -Path ([string]$_) }) + @($pathValue)
            validation_error = $Reason
        }
    }
    $executionRootValue = if ([string]::IsNullOrWhiteSpace($ExecutionRoot)) { Join-Path (Resolve-AbsolutePath $SourceRoot) (Join-Path '.local\ai-sessions\worktrees' $DispatchSlug) } else { $ExecutionRoot }
    $executionExpectedPath = Get-DispatchInterruptionCheckpointPath -SourceRoot $executionRootValue -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId $RunId
    if (-not [string]::Equals($pathValue, $expectedPath, [System.StringComparison]::OrdinalIgnoreCase) -and -not [string]::Equals($pathValue, $executionExpectedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return & $emptyResult 'invalid' '中斷保全檔路徑與目前 line、dispatch、run 識別不一致。'
    }
    try {
        $checkpointRoot = if ([string]::Equals($pathValue, $expectedPath, [StringComparison]::OrdinalIgnoreCase)) { $SourceRoot } else { $executionRootValue }
        Assert-DispatchOutputPathNoReparsePoint -Root $checkpointRoot -Path $pathValue
    }
    catch {
        return & $emptyResult 'invalid' '中斷保全檔路徑包含 reparse point，拒絕讀取。'
    }
    if (-not (Test-Path -LiteralPath $pathValue -PathType Leaf)) {
        return & $emptyResult 'unavailable' '中斷保全檔不存在；所有 selected_units 維持未完成，未推論任何成果。'
    }

    try {
        $document = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $pathValue)
    }
    catch {
        return & $emptyResult 'invalid' ('中斷保全檔無法解析：' + $_.Exception.Message)
    }

    $identityMatches = [string](Get-DispatchJsonProperty -Object $document -Name 'schema') -ceq 'ai-sessions.dispatch-interruption-checkpoint.v1' -and
        [string](Get-DispatchJsonProperty -Object $document -Name 'line_slug') -ceq $LineSlug -and
        [string](Get-DispatchJsonProperty -Object $document -Name 'dispatch_slug') -ceq $DispatchSlug -and
        [string](Get-DispatchJsonProperty -Object $document -Name 'run_id') -ceq $RunId
    if (-not $identityMatches) {
        return & $emptyResult 'invalid' '中斷保全檔的 schema、lineSlug、dispatchSlug 或 run_id 與目前 RunRecord 不一致。'
    }

    $documentSelectedUnits = @((Get-DispatchJsonProperty -Object $document -Name 'selected_units') | ForEach-Object { [string]$_ })
    if (-not (Compare-DispatchStringArrays -Left $documentSelectedUnits -Right @($SelectedUnits))) {
        return & $emptyResult 'invalid' '中斷保全檔 selected_units 與 ScopePlan 不一致。'
    }

    $confirmedUnits = New-Object 'System.Collections.Generic.List[object]'
    $confirmedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $validationError = $null
    foreach ($confirmed in @((Get-DispatchJsonProperty -Object $document -Name 'confirmed_units'))) {
        $unit = [string](Get-DispatchJsonProperty -Object $confirmed -Name 'unit')
        $confirmedResult = [string](Get-DispatchJsonProperty -Object $confirmed -Name 'confirmed_result')
        $evidenceLocations = @((Get-DispatchJsonProperty -Object $confirmed -Name 'evidence_locations') | ForEach-Object { [string]$_ })
        if ([string]::IsNullOrWhiteSpace($unit) -or $SelectedUnits -cnotcontains $unit -or -not $confirmedNames.Add($unit)) {
            $validationError = 'confirmed_units 含有空白、重複或不屬於 selected_units 的單位。'
            break
        }
        if ([string]::IsNullOrWhiteSpace($confirmedResult) -or $confirmedResult -ceq '無' -or $evidenceLocations.Count -eq 0) {
            $validationError = '每個已確認單位都必須提供 confirmed_result 與 evidence_locations。'
            break
        }
        foreach ($evidenceLocation in $evidenceLocations) {
            if ([string]::IsNullOrWhiteSpace($evidenceLocation) -or -not (Test-DispatchFullyQualifiedPath -Path $evidenceLocation)) {
                $validationError = 'confirmed_units.evidence_locations 必須是絕對路徑或絕對路徑加行號。'
                break
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($validationError)) {
            break
        }
        $confirmedUnits.Add([ordered]@{
                unit = $unit
                confirmed_result = $confirmedResult.Trim()
                evidence_locations = @($evidenceLocations)
            })
    }
    if (-not [string]::IsNullOrWhiteSpace($validationError)) {
        return & $emptyResult 'invalid' $validationError
    }

    $expectedIncompleteUnits = @($SelectedUnits | Where-Object { -not $confirmedNames.Contains([string]$_) })
    $recordedIncompleteUnits = @((Get-DispatchJsonProperty -Object $document -Name 'incomplete_units') | ForEach-Object { [string]$_ })
    if (-not (Compare-DispatchStringArrays -Left $recordedIncompleteUnits -Right $expectedIncompleteUnits)) {
        return & $emptyResult 'invalid' 'incomplete_units 必須是 selected_units 扣除 confirmed_units 後的有序集合。'
    }
    $updatedAtUtc = [string](Get-DispatchJsonProperty -Object $document -Name 'updated_at_utc')
    if ([string]::IsNullOrWhiteSpace($updatedAtUtc)) {
        return & $emptyResult 'invalid' '中斷保全檔缺少 updated_at_utc。'
    }

    $sourceLocations = New-Object 'System.Collections.Generic.List[object]'
    foreach ($sourcePathValue in @($SourcePath | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        $sourceLocations.Add([ordered]@{ path = Resolve-AbsolutePath -Path ([string]$sourcePathValue) })
    }
    $sourceLocations.Add([ordered]@{ path = $pathValue })
    return [ordered]@{
        status = 'available'
        path = $pathValue
        line_slug = $LineSlug
        dispatch_slug = $DispatchSlug
        run_id = $RunId
        selected_units = @($SelectedUnits)
        confirmed_units = @($confirmedUnits.ToArray())
        incomplete_units = @($expectedIncompleteUnits)
        source_locations = @($sourceLocations.ToArray())
        validation_error = $null
    }
}

function Get-DispatchMessageInterruptionCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SelectedUnits,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [Parameter(Mandatory)][string]$RunId,
        [string[]]$SourcePath = @()
    )

    $emptyResult = [ordered]@{
        status = 'invalid'
        path = Resolve-AbsolutePath -Path $Path
        line_slug = $LineSlug
        dispatch_slug = $DispatchSlug
        run_id = $RunId
        selected_units = @($SelectedUnits)
        confirmed_units = @()
        incomplete_units = @($SelectedUnits)
        source_locations = @($SourcePath | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { Resolve-AbsolutePath -Path ([string]$_) })
        validation_error = $null
        source = 'agent-message'
    }
    if ([string]::IsNullOrWhiteSpace($Message) -or $SelectedUnits.Count -eq 0) {
        $emptyResult.validation_error = '結案訊息或 ScopePlan selected_units 為空。'
        return $emptyResult
    }

    $fieldPrefixes = [ordered]@{
        confirmed_result = '已確認結論：'
        incomplete_units = '未完成單位：'
        evidence_location = '證據位置：'
    }
    $values = [ordered]@{}
    $messageLines = @($Message -split '\r?\n')
    foreach ($fieldName in $fieldPrefixes.Keys) {
        $prefix = [string]$fieldPrefixes[$fieldName]
        $matchingLines = @($messageLines | Where-Object { ([string]$_).StartsWith($prefix, [StringComparison]::Ordinal) })
        if ($matchingLines.Count -ne 1) {
            $emptyResult.validation_error = ('結案訊息必須恰好包含一行 ' + $fieldName + '。')
            return $emptyResult
        }
        $value = ([string]$matchingLines[0]).Substring($prefix.Length)
        if ([string]::IsNullOrWhiteSpace($value)) {
            $emptyResult.validation_error = ('結案訊息的 ' + $fieldName + ' 不得為空。')
            return $emptyResult
        }
        $values[$fieldName] = $value.Trim()
    }

    if (-not (Test-DispatchFullyQualifiedPath -Path $values.evidence_location)) {
        $emptyResult.validation_error = '結案訊息的證據位置必須是絕對路徑或絕對路徑加行號。'
        return $emptyResult
    }

    $parsedIncompleteUnits = New-Object 'System.Collections.Generic.List[string]'
    $incompleteText = [string]$values.incomplete_units
    if ($incompleteText -cne '無') {
        $remaining = $incompleteText
        $separators = [char[]]@(',', '，', '、', ';', '；')
        while (-not [string]::IsNullOrWhiteSpace($remaining)) {
            $candidate = $null
            $candidateSuffix = $null
            foreach ($selectedUnit in @($SelectedUnits | Sort-Object { ([string]$_).Length } -Descending)) {
                $selectedText = [string]$selectedUnit
                if (-not $remaining.StartsWith($selectedText, [StringComparison]::Ordinal)) {
                    continue
                }
                $suffix = $remaining.Substring($selectedText.Length)
                if ($suffix.Length -eq 0 -or $separators -contains $suffix[0]) {
                    $candidate = $selectedText
                    $candidateSuffix = $suffix
                    break
                }
            }
            if ([string]::IsNullOrWhiteSpace($candidate) -or $parsedIncompleteUnits.Contains($candidate)) {
                $emptyResult.validation_error = '結案訊息的未完成單位無法依 ScopePlan selected_units 精確解析。'
                return $emptyResult
            }
            $parsedIncompleteUnits.Add($candidate)
            if ($candidateSuffix.Length -eq 0) {
                $remaining = ''
                continue
            }
            $remaining = $candidateSuffix.Substring(1).Trim()
            if ([string]::IsNullOrWhiteSpace($remaining)) {
                $emptyResult.validation_error = '結案訊息的未完成單位清單含有尾端分隔符。'
                return $emptyResult
            }
        }
    }

    $expectedIncompleteUnits = @($SelectedUnits | Where-Object { $parsedIncompleteUnits.Contains([string]$_) })
    if (-not (Compare-DispatchStringArrays -Left @($parsedIncompleteUnits.ToArray()) -Right $expectedIncompleteUnits)) {
        $emptyResult.validation_error = '結案訊息的未完成單位順序與 ScopePlan selected_units 不一致。'
        return $emptyResult
    }

    $confirmedUnits = New-Object 'System.Collections.Generic.List[object]'
    foreach ($selectedUnit in $SelectedUnits) {
        if ($expectedIncompleteUnits -ccontains [string]$selectedUnit) {
            continue
        }
        $confirmedUnits.Add([ordered]@{
                unit = [string]$selectedUnit
                confirmed_result = [string]$values.confirmed_result
                evidence_locations = @([string]$values.evidence_location)
            })
    }
    return [ordered]@{
        status = 'available'
        path = Resolve-AbsolutePath -Path $Path
        line_slug = $LineSlug
        dispatch_slug = $DispatchSlug
        run_id = $RunId
        selected_units = @($SelectedUnits)
        confirmed_units = @($confirmedUnits.ToArray())
        incomplete_units = @($expectedIncompleteUnits)
        source_locations = @($SourcePath | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [ordered]@{ path = Resolve-AbsolutePath -Path ([string]$_) } })
        validation_error = $null
        source = 'agent-message'
    }
}

function Get-DispatchInterruptionCheckpointWithMessageFallback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SourceRoot,
        [string]$ExecutionRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SelectedUnits,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [string[]]$SourcePath = @()
    )

    $checkpoint = Get-DispatchInterruptionCheckpoint -Path $Path -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId $RunId -SelectedUnits $SelectedUnits -SourcePath $SourcePath
    if ($checkpoint.status -eq 'available') {
        $checkpointConfirmedUnits = @($checkpoint.confirmed_units)
        $checkpointIncompleteUnits = @($checkpoint.incomplete_units)
        $isInitialCheckpoint = $checkpointConfirmedUnits.Count -eq 0 -and (Compare-DispatchStringArrays -Left $checkpointIncompleteUnits -Right @($SelectedUnits))
        if (-not $isInitialCheckpoint) {
            return $checkpoint
        }
    }
    elseif ($checkpoint.status -ne 'unavailable') {
        return $checkpoint
    }
    $messageCheckpoint = Get-DispatchMessageInterruptionCheckpoint -Message $Message -SelectedUnits $SelectedUnits -Path $Path -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId $RunId -SourcePath $SourcePath
    if ($messageCheckpoint.status -eq 'available') {
        return $messageCheckpoint
    }
    $checkpoint.message_fallback_error = [string]$messageCheckpoint.validation_error
    return $checkpoint
}

function Get-DispatchContinuationFailureHandoff {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$RequestPath,
        [AllowNull()][psobject]$RequestDocument,
        [AllowEmptyString()][string]$ScopePlanPath,
        [AllowEmptyString()][string]$EventStreamPath,
        [AllowEmptyString()][string]$RunRecordPath,
        [AllowEmptyString()][string]$LastMessagePath,
        [AllowEmptyString()][string]$InspectResultPath,
        [AllowEmptyString()][string]$SourceRoot,
        [AllowEmptyString()][string]$ExecutionRoot,
        [AllowEmptyString()][string]$DispatchRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [Parameter(Mandatory)][string]$DispatchExecutionId,
        [AllowEmptyCollection()][string[]]$FallbackSelectedUnits = @()
    )

    $selectedUnits = @()
    $requestedUnits = @()
    $deferredUnits = @()
    $scopePlanLoaded = $false
    $scopePlanPathValue = $null
    $resolvedExecutionRoot = if ([string]::IsNullOrWhiteSpace($ExecutionRoot)) { $SourceRoot } else { $ExecutionRoot }
    if (-not [string]::IsNullOrWhiteSpace($ScopePlanPath) -and -not [string]::IsNullOrWhiteSpace($resolvedExecutionRoot)) {
        try {
            $scopePlanPathValue = Resolve-AbsolutePath -Path $ScopePlanPath
            if ((Test-PathWithinRoot -Path $scopePlanPathValue -Root $resolvedExecutionRoot) -and (Test-Path -LiteralPath $scopePlanPathValue -PathType Leaf)) {
                $scopePlan = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $scopePlanPathValue)
                $selectedUnits = @((Get-DispatchJsonProperty -Object $scopePlan -Name 'selected_units') | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $requestedUnits = @((Get-DispatchJsonProperty -Object $scopePlan -Name 'requested_units') | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $deferredUnits = @((Get-DispatchJsonProperty -Object $scopePlan -Name 'deferred_units') | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $scopePlanLoaded = $true
            }
        }
        catch {
            $selectedUnits = @()
            $requestedUnits = @()
            $deferredUnits = @()
            $scopePlanLoaded = $false
        }
    }
    if (-not $scopePlanLoaded -and $selectedUnits.Count -eq 0) {
        $selectedUnits = @($FallbackSelectedUnits | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $scopePlanSelectionSource = if ($scopePlanLoaded) { 'scope_plan' } elseif ($selectedUnits.Count -gt 0) { 'fallback_selected_units' } else { 'unavailable' }

    $safePointMessage = ''
    $safePointSourcePath = $null
    $handoffEventStreamPathValue = $EventStreamPath
    $handoffRunRecordPathValue = $RunRecordPath
    if (-not [string]::IsNullOrWhiteSpace($EventStreamPath) -and -not [string]::IsNullOrWhiteSpace($resolvedExecutionRoot)) {
        try {
            $eventPathValue = Resolve-AbsolutePath -Path $EventStreamPath
            if ((Test-PathWithinRoot -Path $eventPathValue -Root $resolvedExecutionRoot) -and (Test-Path -LiteralPath $eventPathValue -PathType Leaf)) {
                $taskType = if ($null -eq $RequestDocument) { '' } else { [string](Get-DispatchJsonProperty -Object $RequestDocument -Name 'task_type') }
                $safePointMessage = Get-LatestSafePointMessage -EventPath $eventPathValue -TaskType $taskType
                if (-not [string]::IsNullOrWhiteSpace($safePointMessage)) {
                    $safePointSourcePath = $eventPathValue
                }
            }
        }
        catch {
            $safePointMessage = ''
            $safePointSourcePath = $null
        }
    }

    if ([string]::IsNullOrWhiteSpace($safePointMessage) -and
        -not [string]::IsNullOrWhiteSpace($SourceRoot) -and
        -not [string]::IsNullOrWhiteSpace($resolvedExecutionRoot)) {
        try {
            $candidateRecords = @(Get-DispatchRunRecordList -SourceRoot $SourceRoot -ExecutionRoot $resolvedExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug)
            $candidateRecords = @(
                $candidateRecords |
                    Sort-Object -Property @(
                        @{ Expression = { ConvertTo-DispatchTimestamp -Value $_.created_at_utc }; Descending = $true }
                        @{ Expression = { [string]$_.run_id }; Descending = $true }
                    )
            )
            $fallbackRecord = $null
            $fallbackEventPath = $null
            foreach ($candidateRecord in $candidateRecords) {
                $candidateRecordPath = Join-Path -Path (Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug) -ChildPath ([string]$candidateRecord.run_id + '.json')
                if ($null -eq $fallbackRecord) {
                    $fallbackRecord = $candidateRecord
                    $handoffRunRecordPathValue = $candidateRecordPath
                }
                $candidateEventPath = [string](Get-DispatchJsonProperty -Object $candidateRecord -Name 'event_stream_path')
                if ([string]::IsNullOrWhiteSpace($candidateEventPath)) {
                    continue
                }
                $candidateEventPath = Resolve-AbsolutePath -Path $candidateEventPath
                if (-not (Test-PathWithinRoot -Path $candidateEventPath -Root $resolvedExecutionRoot) -or
                    -not (Test-Path -LiteralPath $candidateEventPath -PathType Leaf)) {
                    continue
                }
                if ($null -eq $fallbackEventPath -and
                    $null -ne $fallbackRecord -and
                    [string]$candidateRecord.run_id -ceq [string]$fallbackRecord.run_id) {
                    $fallbackEventPath = $candidateEventPath
                }
                $candidateTaskType = if ($null -eq $RequestDocument) { '' } else { [string](Get-DispatchJsonProperty -Object $RequestDocument -Name 'task_type') }
                $candidateSafePointMessage = Get-LatestSafePointMessage -EventPath $candidateEventPath -TaskType $candidateTaskType
                if ([string]::IsNullOrWhiteSpace($candidateSafePointMessage)) {
                    continue
                }
                $safePointMessage = $candidateSafePointMessage
                $safePointSourcePath = $candidateEventPath
                $handoffRunRecordPathValue = $candidateRecordPath
                $handoffEventStreamPathValue = $candidateEventPath
                break
            }
            if ([string]::IsNullOrWhiteSpace($safePointMessage) -and $null -ne $fallbackRecord) {
                $handoffRunRecordPathValue = Join-Path -Path (Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug) -ChildPath ([string]$fallbackRecord.run_id + '.json')
                $handoffEventStreamPathValue = $fallbackEventPath
            }
        }
        catch {
            $handoffEventStreamPathValue = $EventStreamPath
            $handoffRunRecordPathValue = $RunRecordPath
        }
    }

    $confirmedResults = @()
    $incompleteUnits = @($selectedUnits)
    $discardedIncompleteUnits = New-Object 'System.Collections.Generic.List[object]'
    $confirmedMatch = [regex]::Match($safePointMessage, '(?m)^\s*已確認結論\s*[:：]\s*(?<value>.*?)\s*$')
    if ($confirmedMatch.Success -and -not [string]::IsNullOrWhiteSpace($confirmedMatch.Groups['value'].Value) -and $confirmedMatch.Groups['value'].Value -cne '無') {
        $confirmedResults += $confirmedMatch.Groups['value'].Value.Trim()
    }
    $coverageMatch = [regex]::Match($safePointMessage, '(?m)^\s*實際覆蓋範圍\s*[:：]\s*(?<value>.*?)\s*$')
    if ($coverageMatch.Success -and -not [string]::IsNullOrWhiteSpace($coverageMatch.Groups['value'].Value) -and $coverageMatch.Groups['value'].Value -cne '無') {
        $confirmedResults += ('實際覆蓋範圍：' + $coverageMatch.Groups['value'].Value.Trim())
    }
    $incompleteMatch = [regex]::Match($safePointMessage, '(?m)^\s*未完成單位\s*[:：]\s*(?<value>.*?)\s*$')
    if ($incompleteMatch.Success) {
        $incompleteText = $incompleteMatch.Groups['value'].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($incompleteText) -or $incompleteText -ceq '無') {
            $incompleteUnits = @()
        }
        else {
            $findUnitOccurrences = {
                param(
                    [string]$Text,
                    [string]$Unit
                )

                $positions = New-Object 'System.Collections.Generic.List[int]'
                if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Unit)) {
                    return $positions.ToArray()
                }
                $searchFrom = 0
                while ($searchFrom -lt $Text.Length) {
                    $position = $Text.IndexOf($Unit, $searchFrom, [System.StringComparison]::Ordinal)
                    if ($position -lt 0) {
                        break
                    }
                    $unitEnd = $position + $Unit.Length
                    $leftBoundary = $position -eq 0 -or -not [char]::IsLetterOrDigit($Text[$position - 1])
                    $rightBoundary = $unitEnd -ge $Text.Length -or -not [char]::IsLetterOrDigit($Text[$unitEnd])
                    if ($leftBoundary -and $rightBoundary) {
                        $positions.Add($position)
                        $searchFrom = $unitEnd
                    }
                    else {
                        $searchFrom = $position + $Unit.Length
                    }
                }
                return $positions.ToArray()
            }

            $candidateUnits = New-Object 'System.Collections.Generic.List[string]'
            foreach ($candidateUnit in @($requestedUnits) + @($deferredUnits) + @($selectedUnits)) {
                if ([string]::IsNullOrWhiteSpace([string]$candidateUnit)) {
                    continue
                }
                if (-not (@($candidateUnits.ToArray()) -ccontains [string]$candidateUnit)) {
                    $candidateUnits.Add([string]$candidateUnit)
                }
            }
            $orderedCandidates = @($candidateUnits.ToArray() | Sort-Object -Property @{ Expression = { $_.Length }; Descending = $true })
            $remainingIncompleteText = $incompleteText
            $matchedSelectedUnits = New-Object 'System.Collections.Generic.List[string]'
            foreach ($candidateUnit in $orderedCandidates) {
                $positions = @(& $findUnitOccurrences -Text $remainingIncompleteText -Unit ([string]$candidateUnit))
                if ($positions.Count -eq 0) {
                    continue
                }
                if (@($selectedUnits) -ccontains [string]$candidateUnit) {
                    if (-not (@($matchedSelectedUnits.ToArray()) -ccontains [string]$candidateUnit)) {
                        $matchedSelectedUnits.Add([string]$candidateUnit)
                    }
                }
                else {
                    $reason = if (@($deferredUnits) -ccontains [string]$candidateUnit) {
                        'ScopePlan deferred_units 不得進入 cold-start 範圍。'
                    }
                    else {
                        'safe point 單位不屬於 ScopePlan selected_units。'
                    }
                    $discardedIncompleteUnits.Add([ordered]@{
                            unit = [string]$candidateUnit
                            reason = $reason
                        })
                }
                foreach ($position in @($positions | Sort-Object -Descending)) {
                    $positionValue = [int]$position
                    $remainingIncompleteText = $remainingIncompleteText.Substring(0, $positionValue) + (' ' * ([string]$candidateUnit).Length) + $remainingIncompleteText.Substring($positionValue + ([string]$candidateUnit).Length)
                }
            }
            $unmatchedText = [regex]::Replace($remainingIncompleteText, '^\s*(?:(?:and|和|及|或)\s*)+', '')
            $unmatchedText = [regex]::Replace($unmatchedText, '(?:\s*(?:and|和|及|或))*\s*$', '')
            $unmatchedText = $unmatchedText.Trim([char[]]@(' ', [char]9, [char]10, [char]13, ',', ';', '，', '；', '、', '|'))
            if (-not [string]::IsNullOrWhiteSpace($unmatchedText) -and $unmatchedText -cne '無') {
                $discardedIncompleteUnits.Add([ordered]@{
                        unit = $unmatchedText
                        reason = 'safe point 文字未對應到任何完整 ScopePlan 單位，未加入 cold-start 範圍。'
                    })
            }
            $incompleteUnits = @($selectedUnits | Where-Object { @($matchedSelectedUnits.ToArray()) -ccontains [string]$_ })
        }
    }

    $handoffRunIdValue = ''
    $interruptionCheckpointPathValue = $null
    if (-not [string]::IsNullOrWhiteSpace($handoffRunRecordPathValue) -and (Test-Path -LiteralPath $handoffRunRecordPathValue -PathType Leaf)) {
        try {
            $handoffRunRecord = Read-DispatchRunRecord -Path $handoffRunRecordPathValue -SourceRoot $SourceRoot -ExecutionRoot $resolvedExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
            $handoffRunIdValue = [string](Get-DispatchJsonProperty -Object $handoffRunRecord -Name 'run_id')
            $interruptionCheckpointPathValue = [string](Get-DispatchJsonProperty -Object $handoffRunRecord -Name 'interruption_checkpoint_path')
            if ([string]::IsNullOrWhiteSpace($interruptionCheckpointPathValue) -and -not [string]::IsNullOrWhiteSpace($handoffRunIdValue)) {
                $interruptionCheckpointPathValue = Get-DispatchInterruptionCheckpointPath -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId $handoffRunIdValue
            }
        }
        catch {
            $handoffRunIdValue = ''
            $interruptionCheckpointPathValue = $null
        }
    }

    $sourceLocations = New-Object 'System.Collections.Generic.List[object]'
    foreach ($source in @(
            [pscustomobject]@{ kind = 'request'; path = $RequestPath },
            [pscustomobject]@{ kind = 'scope_plan'; path = $ScopePlanPath },
            [pscustomobject]@{ kind = 'run_record'; path = $handoffRunRecordPathValue },
            [pscustomobject]@{ kind = 'event_stream'; path = $handoffEventStreamPathValue },
            [pscustomobject]@{ kind = 'last_message'; path = $LastMessagePath },
            [pscustomobject]@{ kind = 'inspect_result'; path = $InspectResultPath },
            [pscustomobject]@{ kind = 'interruption_checkpoint'; path = $interruptionCheckpointPathValue }
        )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$source.path)) {
            $sourceLocations.Add([ordered]@{ kind = $source.kind; path = Resolve-AbsolutePath -Path $source.path; run_id = $handoffRunIdValue })
        }
    }
    foreach ($location in @($discardedIncompleteUnits.ToArray())) {
        if (-not [string]::IsNullOrWhiteSpace([string]$location.unit)) {
            $sourceLocations.Add([ordered]@{
                    kind = 'discarded_safe_point_unit'
                    path = $location.unit
                    reason = $location.reason
                    run_id = $handoffRunIdValue
                })
        }
    }

    $requestPathValue = if ([string]::IsNullOrWhiteSpace($RequestPath)) { $null } else { Resolve-AbsolutePath -Path $RequestPath }
    $requestTarget = if ($null -eq $RequestDocument) { @() } else { @(Get-DispatchJsonProperty -Object $RequestDocument -Name 'target_path') }
    $requestPrompt = if ($null -eq $RequestDocument) { $null } else { Get-DispatchJsonProperty -Object $RequestDocument -Name 'prompt_path' }
    $requestUnitKind = if ($null -eq $RequestDocument) { $null } else { Get-DispatchJsonProperty -Object $RequestDocument -Name 'unit_kind' }
    $requestDispatchKind = if ($null -eq $RequestDocument) { $null } else { Get-DispatchJsonProperty -Object $RequestDocument -Name 'dispatch_kind' }
    $requestWriteMode = if ($null -eq $RequestDocument) { $null } else { Get-DispatchJsonProperty -Object $RequestDocument -Name 'write_mode' }
    $requestTaskType = if ($null -eq $RequestDocument) { $null } else { Get-DispatchJsonProperty -Object $RequestDocument -Name 'task_type' }
    $requestIdentifier = if ($null -eq $RequestDocument) { $null } else { Get-DispatchJsonProperty -Object $RequestDocument -Name 'required_identifier' }
    $suffix = $DispatchExecutionId.Substring(0, [Math]::Min(8, $DispatchExecutionId.Length))
    $coldStartEntry = [ordered]@{
        operation = 'Dispatch'
        request_reference = $requestPathValue
        line_slug = $LineSlug
        dispatch_slug = $DispatchSlug + '-cold-' + $suffix
        source_root = if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $null } else { Resolve-AbsolutePath -Path $SourceRoot }
        execution_root = if ([string]::IsNullOrWhiteSpace($ExecutionRoot)) { $null } else { Resolve-AbsolutePath -Path $ExecutionRoot }
        dispatch_root = if ([string]::IsNullOrWhiteSpace($DispatchRoot)) { $null } else { Resolve-AbsolutePath -Path $DispatchRoot }
        session_mode = 'cold-start'
        resume_thread_id = $null
        requested_unit = @($incompleteUnits)
        unit_kind = $requestUnitKind
        dispatch_kind = $requestDispatchKind
        write_mode = $requestWriteMode
        task_type = $requestTaskType
        prompt_path = $requestPrompt
        target_path = $requestTarget
        required_identifier = $requestIdentifier
        new_request_required = $true
        automatic_retry = $false
    }
    return [ordered]@{
        confirmed_results = @($confirmedResults)
        confirmed_results_source = [ordered]@{
            status = if ($confirmedResults.Count -gt 0) { 'available' } else { 'insufficient' }
            path = $safePointSourcePath
            reason = if ($confirmedResults.Count -gt 0) { $null } else { '未能從 safe point 取得已確認結論或實際覆蓋範圍；confirmed_results 保持空陣列，未作推論。' }
        }
        incomplete_units = @($incompleteUnits)
        discarded_incomplete_units = @($discardedIncompleteUnits.ToArray())
        scope_plan_source = [ordered]@{
            status = if ($scopePlanLoaded) { 'available' } else { 'insufficient' }
            path = $scopePlanPathValue
            selection_source = $scopePlanSelectionSource
            selected_units = @($selectedUnits)
            deferred_units = @($deferredUnits)
        }
        source_locations = @($sourceLocations.ToArray())
        cold_start_entry = $coldStartEntry
        automatic_retry = $false
    }
}

function Write-DispatchFailureReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [string]$DispatchExecutionId,

        [Parameter(Mandatory)]
        [string]$ErrorCode,

        [Parameter(Mandatory)]
        [string]$ErrorMessage,

        [AllowEmptyString()]
        [string]$SourceRoot,

        [AllowEmptyString()]
        [string]$ExecutionRoot,

        [AllowEmptyString()]
        [string]$DispatchRoot,

        [ValidateSet('validation', 'preflight', 'before-snapshot', 'prepare', 'start', 'inspect')]
        [string]$FailedStage = 'preflight',

        [bool]$ProcessStarted = $false,

        [string[]]$TargetPath = @(),

        [AllowNull()]
        [System.Collections.IDictionary]$ContinuationHandoff
    )

    $guardSourceRoot = $SourceRoot
    $guardExecutionRoot = if ([string]::IsNullOrWhiteSpace($ExecutionRoot)) { $SourceRoot } else { $ExecutionRoot }
    $document = [ordered]@{
        schema = 'ai-sessions.dispatch-failure-receipt.v1'
        status = 'failed'
        failed_stage = $FailedStage
        error_code = $ErrorCode
        error = $ErrorMessage
        process_started = $ProcessStarted
        line_slug = $LineSlug
        dispatch_slug = $DispatchSlug
        dispatch_execution_id = $DispatchExecutionId
        source_root = if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $null } else { Resolve-AbsolutePath -Path $SourceRoot }
        execution_root = if ([string]::IsNullOrWhiteSpace($ExecutionRoot)) { $null } else { Resolve-AbsolutePath -Path $ExecutionRoot }
        dispatch_root = if ([string]::IsNullOrWhiteSpace($DispatchRoot)) { $null } else { Resolve-AbsolutePath -Path $DispatchRoot }
        failure_receipt_path = Resolve-AbsolutePath -Path $Path
        failure_receipt_saved = $true
    }
    if ($null -ne $ContinuationHandoff) {
        $document.continuation_handoff = $ContinuationHandoff
    }
    return Write-DispatchAtomicJsonDocument -Path $Path -Document $document -SourceRoot $guardSourceRoot -ExecutionRoot $guardExecutionRoot -TargetPath @($TargetPath) -HashProperty ''
}

function Write-PrepareResultDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [psobject]$Document,

        [AllowEmptyString()]
        [string]$GuardSourceRoot,

        [AllowEmptyString()]
        [string]$GuardExecutionRoot,

        [string[]]$GuardTargetPath,

        [switch]$RequireAbsent
    )

    $guardSourceRootValue = $GuardSourceRoot
    $guardSourceRoot = Get-DispatchJsonProperty -Object $Document -Name 'source_root'
    if (-not [string]::IsNullOrWhiteSpace([string]$guardSourceRootValue)) {
        $guardSourceRoot = $guardSourceRootValue
    }
    if ([string]::IsNullOrWhiteSpace([string]$guardSourceRoot)) {
        $guardSourceRoot = Get-DispatchScriptVariableValue -Name 'SourceRoot'
    }
    $guardExecutionRootValue = $GuardExecutionRoot
    $guardExecutionRoot = Get-DispatchJsonProperty -Object $Document -Name 'execution_root'
    if (-not [string]::IsNullOrWhiteSpace([string]$guardExecutionRootValue)) {
        $guardExecutionRoot = $guardExecutionRootValue
    }
    if ([string]::IsNullOrWhiteSpace([string]$guardExecutionRoot)) {
        $guardExecutionRoot = Get-DispatchScriptVariableValue -Name 'ExecutionRoot'
    }
    $guardTargetPathValue = if ($null -eq $GuardTargetPath) { @() } else { @($GuardTargetPath) }
    $resolvedPath = Resolve-DispatchOutputPath -CandidatePath $Path -SourceRoot ([string]$guardSourceRoot) -ExecutionRoot ([string]$guardExecutionRoot) -TargetPath $guardTargetPathValue
    $resultHash = Get-PrepareDocumentFingerprint -Document $Document
    if ($Document -is [System.Collections.IDictionary]) {
        $Document['result_sha256'] = $resultHash
    }
    else {
        $resultHashProperty = $Document.PSObject.Properties['result_sha256']
        if ($null -eq $resultHashProperty) {
            $Document | Add-Member -MemberType NoteProperty -Name 'result_sha256' -Value $resultHash
        }
        else {
            $Document.result_sha256 = $resultHash
        }
    }

    $written = Write-DispatchAtomicJsonDocument -Path $resolvedPath -Document $Document -SourceRoot ([string]$guardSourceRoot) -ExecutionRoot ([string]$guardExecutionRoot) -TargetPath @($guardTargetPathValue) -RequireAbsent:$RequireAbsent -AbsentErrorCode 'PrepareResultCollision'

    return [pscustomobject]@{
        Path     = $resolvedPath
        Sha256   = $written.Sha256
        Document = $Document
    }
}

function Read-PrepareResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
        [string]$DispatchSlug,

        [AllowEmptyString()]
        [string]$ExpectedSha256
    )

    $resolvedPath = Resolve-AbsolutePath -Path $Path
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "PreparedResultMissing：找不到 Prepare result：$resolvedPath"
    }
    $actualFileHash = Get-FileSha256 -Path $resolvedPath
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and $actualFileHash -ine $ExpectedSha256) {
        throw "PrepareArtifactMismatch：Prepare result hash 不一致；path=$resolvedPath; expected=$ExpectedSha256; actual=$actualFileHash"
    }

    $bytes = [System.IO.File]::ReadAllBytes($resolvedPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        throw "PrepareArtifactMismatch：Prepare result 必須是 UTF-8 無 BOM：$resolvedPath"
    }
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        $content = $encoding.GetString($bytes)
        $document = ConvertFrom-DispatchJson -Content $content
    }
    catch {
        throw "PrepareArtifactMismatch：Prepare result JSON 無法解析：$resolvedPath；$($_.Exception.Message)"
    }
    if ($null -eq $document -or $document -isnot [pscustomobject]) {
        throw "PrepareArtifactMismatch：Prepare result 根節點必須是 JSON object：$resolvedPath"
    }

    foreach ($requiredName in @('schema', 'operation', 'status', 'line_slug', 'dispatch_slug', 'source_root', 'execution_root', 'artifacts', 'result_sha256')) {
        $property = $document.PSObject.Properties[$requiredName]
        if ($null -eq $property) {
            throw "PrepareArtifactMismatch：Prepare result 缺少欄位 $requiredName：$resolvedPath"
        }
    }
    if ($document.schema -cne 'ai-sessions.prepare.v1' -or $document.operation -cne 'Prepare') {
        throw "PrepareArtifactMismatch：Prepare result schema 或 operation 不符：$resolvedPath"
    }
    if ($document.status -notin @('Preparing', 'Prepared', 'PrepareFailed', 'not-required')) {
        throw "PrepareArtifactMismatch：Prepare result status 不符：$resolvedPath"
    }
    if ($document.line_slug -cne $LineSlug -or $document.dispatch_slug -cne $DispatchSlug) {
        throw "PrepareArtifactMismatch：Prepare result line／dispatch 不一致：$resolvedPath"
    }
    if ((Resolve-AbsolutePath -Path ([string]$document.source_root)) -cne (Resolve-AbsolutePath -Path $SourceRoot)) {
        throw "PrepareArtifactMismatch：Prepare result source root 不一致：$resolvedPath"
    }
    if ((Resolve-AbsolutePath -Path ([string]$document.execution_root)) -cne (Resolve-AbsolutePath -Path $ExecutionRoot)) {
        throw "PrepareArtifactMismatch：Prepare result execution root 不一致：$resolvedPath"
    }
    if ([string]$document.result_sha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw "PrepareArtifactMismatch：Prepare result result_sha256 格式不符：$resolvedPath"
    }
    $computedResultHash = Get-PrepareDocumentFingerprint -Document $document
    if ($computedResultHash -ine [string]$document.result_sha256) {
        throw "PrepareArtifactMismatch：Prepare result 內容 hash 不一致：$resolvedPath"
    }

    return [pscustomobject]@{
        Path     = $resolvedPath
        Sha256   = $actualFileHash
        Document = $document
        Status   = [string]$document.status
    }
}

function Throw-PrepareValidationFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Code,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['prepareCode'] = $Code
    throw $exception
}

function New-PrepareDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$RootInfo,

        [Parameter(Mandatory)]
        [ValidateSet('Preparing', 'Prepared', 'PrepareFailed', 'not-required')]
        [string]$Status,

        [AllowEmptyString()]
        [string]$RequestPathValue,

        [AllowEmptyString()]
        [string]$RequestSha256Value,

        [AllowNull()]
        [object]$EffectiveCodexHome,

        [AllowEmptyCollection()]
        [object[]]$Artifacts,

        [AllowNull()]
        [object]$ErrorValue
    )

    $artifactList = New-Object 'System.Collections.Generic.List[object]'
    foreach ($artifact in @($Artifacts)) {
        if ($null -ne $artifact) {
            $artifactList.Add($artifact)
        }
    }

    $now = [datetime]::UtcNow.ToString('o')
    return [ordered]@{
        schema                 = 'ai-sessions.prepare.v1'
        operation              = 'Prepare'
        status                 = $Status
        line_slug              = $RootInfo.LineSlug
        dispatch_slug          = $RootInfo.DispatchSlug
        source_root            = $RootInfo.SourceRoot
        execution_root         = $RootInfo.ExecutionRoot
        dispatch_line_root     = $RootInfo.DispatchLineRoot
        report_line_root       = $RootInfo.ReportLineRoot
        history_line_root      = $RootInfo.HistoryLineRoot
        request_path           = if ([string]::IsNullOrWhiteSpace($RequestPathValue)) { $null } else { $RequestPathValue }
        request_sha256         = if ([string]::IsNullOrWhiteSpace($RequestSha256Value)) { $null } else { $RequestSha256Value }
        effective_codex_home   = if ($null -eq $EffectiveCodexHome) { $null } else { [string]$EffectiveCodexHome }
        artifacts              = $artifactList.ToArray()
        error                   = $ErrorValue
        created_at_utc          = $now
        completed_at_utc        = if ($Status -in @('Prepared', 'PrepareFailed', 'not-required')) { $now } else { $null }
        result_sha256           = $null
    }
}

function Get-PrepareResultTargetPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$RootInfo,

        [AllowEmptyString()]
        [string]$PrepareResultPathValue,

        [AllowEmptyString()]
        [string]$ResultPathValue,

        [string[]]$TargetPathValue
    )

    $candidate = $PrepareResultPathValue
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = $ResultPathValue
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = Join-Path -Path $RootInfo.HistoryLineRoot -ChildPath ('prepare-result-' + $RootInfo.DispatchSlug + '-' + [guid]::NewGuid().ToString('D') + '.json')
    }
    try {
        $resolvedCandidate = Resolve-AbsolutePath -Path $candidate
    }
    catch {
        $diagnostic = New-PrepareResultPathDiagnostic -RootInfo $RootInfo -ReceivedPath $candidate -ResolvedPath $null -Correction '請提供可解析的檔案路徑，並將檔案放在允許的 destination root 內。' -Detail $_.Exception.Message
        Throw-PrepareValidationFailure -Code 'PrepareResultBoundary' -Message ('Prepare result 路徑無法解析：' + $diagnostic)
    }
    try {
        $guardTargetPath = if ($null -eq $TargetPathValue) { @() } else { @($TargetPathValue) }
        $null = Resolve-DispatchOutputPath -CandidatePath $resolvedCandidate -SourceRoot $RootInfo.SourceRoot -ExecutionRoot $RootInfo.ExecutionRoot -TargetPath $guardTargetPath
    }
    catch {
        $outputCode = [string]$_.Exception.Data['outputCode']
        if ([string]::IsNullOrWhiteSpace($outputCode)) {
            $outputCode = 'DispatchOutputBoundary'
        }
        $diagnostic = New-PrepareResultPathDiagnostic -RootInfo $RootInfo -ReceivedPath $candidate -ResolvedPath $resolvedCandidate -Correction '請改用不在 target path 內且位於允許 destination root 的 result path。' -Detail $_.Exception.Message
        Throw-PrepareValidationFailure -Code $outputCode -Message ('Prepare result 路徑驗證失敗：' + $diagnostic)
    }
    $destinationRoot = Resolve-PrepareDestinationRoot -Path $resolvedCandidate -DestinationRoots $RootInfo.DestinationRoots
    if ($null -eq $destinationRoot) {
        $diagnostic = New-PrepareResultPathDiagnostic -RootInfo $RootInfo -ReceivedPath $candidate -ResolvedPath $resolvedCandidate -Correction '請將 result path 移至列出的 dispatch、report 或 history line root。' -Detail 'path is outside every allowed destination root'
        Throw-PrepareValidationFailure -Code 'PrepareResultBoundary' -Message ('Prepare result 路徑超出允許 root：' + $diagnostic)
    }
    return $resolvedCandidate
}

function Resolve-PrepareResultBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
        [string]$DispatchSlug,

        [AllowEmptyString()]
        [string]$ExpectedSha256
    )

    $rootInfo = Get-PrepareRootInfo -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -DispatchRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    $resultInfo = Read-PrepareResult -Path $Path -SourceRoot $rootInfo.SourceRoot -ExecutionRoot $rootInfo.ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -ExpectedSha256 $ExpectedSha256
    $document = $resultInfo.Document
    $status = [string]$document.status
    if ($status -eq 'PrepareFailed' -or $status -eq 'Preparing') {
        throw "PrepareArtifactMismatch：Prepare result 尚未完成：$($resultInfo.Path); status=$status"
    }

    if ($status -eq 'not-required') {
        if (-not [string]::Equals($rootInfo.SourceRoot, $rootInfo.ExecutionRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'PrepareArtifactMismatch：not-required 只適用 source root 與 dispatch root 相同的 direct-write。'
        }
        if (@($document.artifacts).Count -ne 0) {
            throw 'PrepareArtifactMismatch：not-required result 不可包含 artifact。'
        }
        return [pscustomobject]@{
            Path              = $resultInfo.Path
            Sha256            = $resultInfo.Sha256
            Status            = $status
            Document          = $document
            Artifacts         = @()
            EffectiveCodexHome = [string]$document.effective_codex_home
        }
    }

    $artifactValues = @($document.artifacts)
    if ($artifactValues.Count -eq 0) {
        throw 'PrepareArtifactMismatch：Prepared result 缺少 artifact。'
    }
    $verifiedArtifacts = New-Object 'System.Collections.Generic.List[object]'
    foreach ($artifact in $artifactValues) {
        foreach ($name in @('source', 'destination', 'purpose', 'expected_sha256', 'source_sha256', 'destination_sha256')) {
            if ($null -eq $artifact.PSObject.Properties[$name]) {
                throw "PrepareArtifactMismatch：artifact 缺少 $name。"
            }
        }
        $sourcePath = Resolve-AbsolutePath -Path ([string]$artifact.source)
        $destinationPath = Resolve-AbsolutePath -Path ([string]$artifact.destination)
        $destinationRoot = Resolve-PrepareDestinationRoot -Path $destinationPath -DestinationRoots $rootInfo.DestinationRoots
        $sourceRoot = Resolve-PrepareSourceRoot -Path $sourcePath -SourceRoots @($rootInfo.SourceLineRoots)
        if ($null -eq $sourceRoot) {
            throw "PrepareArtifactMismatch：artifact source 超出允許的 handoff/report line roots：$sourcePath"
        }
        if ($null -eq $destinationRoot) {
            throw "PrepareArtifactMismatch：artifact destination 超出允許 root：$destinationPath"
        }
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "PrepareArtifactMismatch：artifact source 不存在：$sourcePath"
        }
        if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
            throw "PrepareArtifactMismatch：artifact destination 不存在：$destinationPath"
        }
        $sourceHash = Get-FileSha256 -Path $sourcePath
        $destinationHash = Get-FileSha256 -Path $destinationPath
        $expectedHash = [string]$artifact.expected_sha256
        if ($sourceHash -ine $expectedHash -or $destinationHash -ine $expectedHash -or $sourceHash -ine $destinationHash) {
            throw "PrepareArtifactMismatch：artifact hash 不一致；source=$sourcePath; destination=$destinationPath; expected=$expectedHash; source_sha256=$sourceHash; destination_sha256=$destinationHash"
        }
        if ([string]$artifact.source_sha256 -ine $sourceHash -or [string]$artifact.destination_sha256 -ine $destinationHash) {
            throw "PrepareArtifactMismatch：Prepare result artifact hash 與目前檔案不一致：$destinationPath"
        }
        $verifiedArtifacts.Add([ordered]@{
                source             = $sourcePath
                destination        = $destinationPath
                purpose            = [string]$artifact.purpose
                destination_root   = $destinationRoot.Name
                expected_sha256    = $expectedHash
                source_sha256      = $sourceHash
                destination_sha256 = $destinationHash
            })
    }

    return [pscustomobject]@{
        Path               = $resultInfo.Path
        Sha256             = $resultInfo.Sha256
        Status             = $status
        Document           = $document
        Artifacts          = @($verifiedArtifacts.ToArray())
        EffectiveCodexHome = [string]$document.effective_codex_home
    }
}

function New-PrepareOperationResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Document,

        [AllowEmptyString()]
        [string]$ResultPathValue,

        [AllowEmptyString()]
        [string]$ResultSha256Value,

        [AllowEmptyString()]
        [string]$ErrorCode,

        [AllowEmptyString()]
        [string]$ErrorMessage
    )

    $status = [string]$Document.status
    return [ordered]@{
        operation             = 'Prepare'
        schema                = 'ai-sessions.prepare.v1'
        status                = $status
        prepareStatus         = $status
        lineSlug              = [string]$Document.line_slug
        dispatchSlug          = [string]$Document.dispatch_slug
        sourceRoot            = [string]$Document.source_root
        executionRoot         = [string]$Document.execution_root
        requestPath           = [string]$Document.request_path
        requestSha256         = [string]$Document.request_sha256
        effectiveCodexHome    = [string]$Document.effective_codex_home
        prepareResultPath     = if ([string]::IsNullOrWhiteSpace($ResultPathValue)) { $null } else { $ResultPathValue }
        prepareResultSha256   = if ([string]::IsNullOrWhiteSpace($ResultSha256Value)) { $null } else { $ResultSha256Value }
        artifacts             = ConvertTo-NonNullObjectArray -Values $Document.artifacts
        errorCode             = if ([string]::IsNullOrWhiteSpace($ErrorCode)) { $null } else { $ErrorCode }
        error                 = if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $null } else { $ErrorMessage }
        processStarted        = $false
        outputValid           = $status -in @('Prepared', 'not-required')
        prepareResult         = $Document
    }
}

function Invoke-Prepare {
    [CmdletBinding()]
    param(
        [string[]]$GuardTargetPath
    )

    $rootInfo = $null
    $resultPathValue = $null
    $resultSha256Value = $null
    $resultWriteFailure = $null
    $resultDocument = $null
    $temporaryPaths = New-Object 'System.Collections.Generic.List[string]'
    $temporaryByDestination = @{}
    $committedPaths = New-Object 'System.Collections.Generic.List[string]'
    $guardTargetPathValue = if ($null -eq $GuardTargetPath) { @() } else { @($GuardTargetPath) }
    $requestContext = $script:RequestContext
    try {
        if ($null -eq $requestContext -and -not [string]::IsNullOrWhiteSpace($RequestPath)) {
            $requestContext = Read-DispatchRequest -Path $RequestPath
            $script:RequestContext = $requestContext
            $script:RequestPrepareArtifacts = @($requestContext.prepare_artifacts)
        }
        $rootInfo = Get-PrepareRootInfo -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -DispatchRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        if ($null -ne $script:CallerSessionIdentity) {
            $null = Assert-DispatchAdmission `
                -SourceRoot $rootInfo.SourceRoot `
                -CallerIdentity $script:CallerSessionIdentity `
                -LineSlug $rootInfo.LineSlug `
                -DispatchSlug $rootInfo.DispatchSlug `
                -WriteMode $WriteMode `
                -TargetPath @($guardTargetPathValue) `
                -AddDirectory @($AddDirectory) `
                -ExecutionRoot $rootInfo.ExecutionRoot
        }
        $dispatchStageBinding = Get-DispatchScriptVariableValue -Name 'DispatchStageBinding'
        if ($null -ne $dispatchStageBinding) {
            $bindingDispatchRoot = if ([string]::Equals($rootInfo.SourceRoot, $rootInfo.ExecutionRoot, [StringComparison]::OrdinalIgnoreCase)) { [string]$dispatchStageBinding.dispatch_root } else { $rootInfo.DispatchRoot }
            $null = Assert-DispatchStageBinding -Binding $dispatchStageBinding -Stage 'prepare' -SourceRoot $rootInfo.SourceRoot -ExecutionRoot $rootInfo.ExecutionRoot -DispatchRoot $bindingDispatchRoot -LineSlug $rootInfo.LineSlug -DispatchSlug $rootInfo.DispatchSlug -TargetPath @($guardTargetPathValue) -ResultPath $ResultPath -PreflightResultPath $PreflightResultPath -PrepareResultPath $PrepareResultPath -QuotaBeforePath $QuotaBeforePath -QuotaAfterPath $QuotaAfterPath
        }
        $effectiveCodexHome = Resolve-CodexHomeForEvidence -CodexHomePath $CodexHome
        $requestPathValue = if ($null -eq $requestContext) { $null } else { [string]$requestContext.path }
        $requestSha256Value = if ($null -eq $requestContext) { $null } else { [string]$requestContext.sha256 }
        $resultPathValue = Get-PrepareResultTargetPath -RootInfo $rootInfo -PrepareResultPathValue $PrepareResultPath -ResultPathValue $ResultPath -TargetPathValue $guardTargetPathValue
        if (Test-Path -LiteralPath $resultPathValue) {
            $diagnostic = New-PrepareResultPathDiagnostic -RootInfo $rootInfo -ReceivedPath $resultPathValue -ResolvedPath $resultPathValue -Correction '請改用允許 destination root 內尚不存在的 result filename。' -Detail 'destination file already exists'
            Throw-PrepareValidationFailure -Code 'PrepareResultCollision' -Message ('Prepare result 已存在，拒絕覆寫：' + $diagnostic)
        }

        $requestArtifacts = @($script:RequestPrepareArtifacts)
        if ([string]::Equals($rootInfo.SourceRoot, $rootInfo.ExecutionRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            if ($requestArtifacts.Count -gt 0) {
                Throw-PrepareValidationFailure -Code 'PrepareArtifactMismatch' -Message 'direct-write 不應同步 artifact，請使用空的 prepare_artifacts。'
            }
            $resultDocument = New-PrepareDocument -RootInfo $rootInfo -Status 'not-required' -RequestPathValue $requestPathValue -RequestSha256Value $requestSha256Value -EffectiveCodexHome $effectiveCodexHome -Artifacts @() -ErrorValue $null
            $written = Write-PrepareResultDocument -Path $resultPathValue -Document $resultDocument -GuardSourceRoot $rootInfo.SourceRoot -GuardExecutionRoot $rootInfo.ExecutionRoot -GuardTargetPath $guardTargetPathValue
            return New-PrepareOperationResult -Document $written.Document -ResultPathValue $written.Path -ResultSha256Value $written.Sha256
        }

        if ($null -eq $requestContext -or $requestArtifacts.Count -eq 0) {
            Throw-PrepareValidationFailure -Code 'PrepareRequired' -Message 'worktree Prepare 必須提供非空 prepare_artifacts 清單。'
        }

        $artifactPlans = New-Object 'System.Collections.Generic.List[object]'
        foreach ($artifact in $requestArtifacts) {
            $sourcePath = $null
            $destinationPath = $null
            try {
                $sourcePath = Resolve-AbsolutePath -Path ([string]$artifact.source)
                $destinationPath = Resolve-AbsolutePath -Path ([string]$artifact.destination)
            }
            catch {
                Throw-PrepareValidationFailure -Code 'PrepareArtifactMismatch' -Message ('artifact 路徑無法解析：' + $_.Exception.Message)
            }
            $sourceRoot = Resolve-PrepareSourceRoot -Path $sourcePath -SourceRoots @($rootInfo.SourceLineRoots)
            if ($null -eq $sourceRoot) {
                Throw-PrepareValidationFailure -Code 'PrepareArtifactMismatch' -Message "artifact source 超出允許的 handoff/report line roots：$sourcePath"
            }
            $destinationRoot = Resolve-PrepareDestinationRoot -Path $destinationPath -DestinationRoots $rootInfo.DestinationRoots
            if ($null -eq $destinationRoot) {
                Throw-PrepareValidationFailure -Code 'PrepareArtifactMismatch' -Message "artifact destination 超出允許 root：$destinationPath"
            }
            $destinationPath = Resolve-DispatchOutputPath -CandidatePath $destinationPath -SourceRoot $rootInfo.SourceRoot -ExecutionRoot $rootInfo.ExecutionRoot -TargetPath @($guardTargetPathValue)
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                Throw-PrepareValidationFailure -Code 'PrepareArtifactMismatch' -Message "artifact source 不存在：$sourcePath"
            }
            if ([System.IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $destinationPath)) -or [System.IO.Directory]::Exists((ConvertTo-FileSystemApiPath -Path $destinationPath))) {
                Throw-PrepareValidationFailure -Code 'PrepareArtifactMismatch' -Message "artifact destination 已被占用：$destinationPath"
            }
            $artifactPlans.Add([ordered]@{
                    source             = $sourcePath
                    destination        = $destinationPath
                    purpose            = [string]$artifact.purpose
                    destination_root   = $destinationRoot.Name
                    expected_sha256    = ([string]$artifact.sha256).ToLowerInvariant()
                    source_sha256      = $null
                    destination_sha256 = $null
                })
        }

        $resultDocument = New-PrepareDocument -RootInfo $rootInfo -Status 'Preparing' -RequestPathValue $requestPathValue -RequestSha256Value $requestSha256Value -EffectiveCodexHome $effectiveCodexHome -Artifacts @($artifactPlans.ToArray()) -ErrorValue $null
        $null = Write-PrepareResultDocument -Path $resultPathValue -Document $resultDocument -GuardSourceRoot $rootInfo.SourceRoot -GuardExecutionRoot $rootInfo.ExecutionRoot -GuardTargetPath $guardTargetPathValue

        $verifiedPlans = New-Object 'System.Collections.Generic.List[object]'
        foreach ($plan in @($artifactPlans.ToArray())) {
            $sourcePath = [string]$plan.source
            $destinationPath = [string]$plan.destination
            $sourceHashBefore = Get-FileSha256 -Path $sourcePath
            if ($sourceHashBefore -ine [string]$plan.expected_sha256) {
                Throw-PrepareValidationFailure -Code 'PrepareArtifactMismatch' -Message "artifact source hash 不符：$sourcePath; expected=$($plan.expected_sha256); actual=$sourceHashBefore"
            }
            $sourceBytes = [System.IO.File]::ReadAllBytes($sourcePath)
            $sourceHashRead = Get-DispatchByteArraySha256 -Bytes $sourceBytes
            $sourceHashAfter = Get-FileSha256 -Path $sourcePath
            if ($sourceHashBefore -ine $sourceHashRead -or $sourceHashBefore -ine $sourceHashAfter) {
                Throw-PrepareValidationFailure -Code 'PrepareArtifactMismatch' -Message "artifact source 在複製期間變更：$sourcePath"
            }
            $destinationParent = Split-Path -Parent $destinationPath
            $null = New-DispatchOutputDirectory -Path $destinationParent -SourceRoot $rootInfo.SourceRoot -ExecutionRoot $rootInfo.ExecutionRoot -TargetPath @($guardTargetPathValue)
            $destinationPath = Resolve-DispatchOutputPath -CandidatePath $destinationPath -SourceRoot $rootInfo.SourceRoot -ExecutionRoot $rootInfo.ExecutionRoot -TargetPath @($guardTargetPathValue)
            $temporaryPath = Join-Path -Path $destinationParent -ChildPath ([guid]::NewGuid().ToString('D') + '.prepare.tmp')
            $temporaryPath = Resolve-DispatchOutputPath -CandidatePath $temporaryPath -SourceRoot $rootInfo.SourceRoot -ExecutionRoot $rootInfo.ExecutionRoot -TargetPath @($guardTargetPathValue)
            $temporaryPaths.Add($temporaryPath)
            $temporaryByDestination[$destinationPath] = $temporaryPath
            $temporaryPath = Resolve-DispatchOutputPath -CandidatePath $temporaryPath -SourceRoot $rootInfo.SourceRoot -ExecutionRoot $rootInfo.ExecutionRoot -TargetPath @($guardTargetPathValue)
            [System.IO.File]::WriteAllBytes((ConvertTo-FileSystemApiPath -Path $temporaryPath), $sourceBytes)
            $destinationHash = Get-FileSha256 -Path $temporaryPath
            if ($destinationHash -ine $sourceHashBefore -or $destinationHash -ine [string]$plan.expected_sha256) {
                Throw-PrepareValidationFailure -Code 'PrepareArtifactMismatch' -Message "artifact temporary destination hash 不符：$destinationPath; expected=$($plan.expected_sha256); actual=$destinationHash"
            }
            $verifiedPlans.Add([ordered]@{
                    source             = $sourcePath
                    destination        = $destinationPath
                    purpose            = [string]$plan.purpose
                    destination_root   = [string]$plan.destination_root
                    expected_sha256    = [string]$plan.expected_sha256
                    source_sha256      = $sourceHashBefore
                    destination_sha256 = $destinationHash
                })
        }

        foreach ($plan in @($verifiedPlans.ToArray())) {
            $destinationPath = [string]$plan.destination
            if ([System.IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $destinationPath)) -or [System.IO.Directory]::Exists((ConvertTo-FileSystemApiPath -Path $destinationPath))) {
                Throw-PrepareValidationFailure -Code 'PrepareArtifactMismatch' -Message "artifact destination 在提交前被占用：$destinationPath"
            }
            $temporaryPath = [string]$temporaryByDestination[$destinationPath]
            if ([string]::IsNullOrWhiteSpace([string]$temporaryPath) -or -not [System.IO.File]::Exists((ConvertTo-FileSystemApiPath -Path ([string]$temporaryPath)))) {
                Throw-PrepareValidationFailure -Code 'PrepareArtifactMismatch' -Message "找不到 artifact temporary destination：$destinationPath"
            }
            $temporaryPath = Resolve-DispatchOutputPath -CandidatePath $temporaryPath -SourceRoot $rootInfo.SourceRoot -ExecutionRoot $rootInfo.ExecutionRoot -TargetPath @($guardTargetPathValue)
            $destinationPath = Resolve-DispatchOutputPath -CandidatePath $destinationPath -SourceRoot $rootInfo.SourceRoot -ExecutionRoot $rootInfo.ExecutionRoot -TargetPath @($guardTargetPathValue)
            [System.IO.File]::Move((ConvertTo-FileSystemApiPath -Path ([string]$temporaryPath)), (ConvertTo-FileSystemApiPath -Path $destinationPath))
            $committedPaths.Add($destinationPath)
            $null = $temporaryPaths.Remove([string]$temporaryPath)
            $finalHash = Get-FileSha256 -Path $destinationPath
            if ($finalHash -ine [string]$plan.destination_sha256) {
                Throw-PrepareValidationFailure -Code 'PrepareArtifactMismatch' -Message "artifact destination hash 不符：$destinationPath; expected=$($plan.destination_sha256); actual=$finalHash"
            }
        }

        $resultDocument = New-PrepareDocument -RootInfo $rootInfo -Status 'Prepared' -RequestPathValue $requestPathValue -RequestSha256Value $requestSha256Value -EffectiveCodexHome $effectiveCodexHome -Artifacts @($verifiedPlans.ToArray()) -ErrorValue $null
        $writtenResult = Write-PrepareResultDocument -Path $resultPathValue -Document $resultDocument -GuardSourceRoot $rootInfo.SourceRoot -GuardExecutionRoot $rootInfo.ExecutionRoot -GuardTargetPath $guardTargetPathValue
        return New-PrepareOperationResult -Document $writtenResult.Document -ResultPathValue $writtenResult.Path -ResultSha256Value $writtenResult.Sha256
    }
    catch {
        $originalMessage = $_.Exception.Message
        $failureCode = [string]$_.Exception.Data['prepareCode']
        if ([string]::IsNullOrWhiteSpace($failureCode)) {
            $failureCode = 'PrepareFailed'
        }
        foreach ($temporaryPath in @($temporaryPaths.ToArray())) {
            try {
                $safeTemporaryPath = if ($null -eq $rootInfo) { $temporaryPath } else { Resolve-DispatchOutputPath -CandidatePath $temporaryPath -SourceRoot $rootInfo.SourceRoot -ExecutionRoot $rootInfo.ExecutionRoot -TargetPath @($guardTargetPathValue) }
                if (Test-Path -LiteralPath $safeTemporaryPath) {
                    Remove-Item -LiteralPath $safeTemporaryPath -Force -ErrorAction SilentlyContinue
                }
            }
            catch {
            }
        }
        foreach ($committedPath in @($committedPaths.ToArray())) {
            try {
                $safeCommittedPath = if ($null -eq $rootInfo) { $committedPath } else { Resolve-DispatchOutputPath -CandidatePath $committedPath -SourceRoot $rootInfo.SourceRoot -ExecutionRoot $rootInfo.ExecutionRoot -TargetPath @($guardTargetPathValue) }
                if (Test-Path -LiteralPath $safeCommittedPath) {
                    Remove-Item -LiteralPath $safeCommittedPath -Force -ErrorAction SilentlyContinue
                }
            }
            catch {
            }
        }
        if ($null -ne $rootInfo -and [string]::IsNullOrWhiteSpace($resultPathValue)) {
            try {
                $resultPathValue = Get-PrepareResultTargetPath -RootInfo $rootInfo -PrepareResultPathValue $PrepareResultPath -ResultPathValue $ResultPath -TargetPathValue $guardTargetPathValue
            }
            catch {
                $resultPathValue = $null
            }
        }
        if ($null -ne $rootInfo) {
            $requestPathValue = if ($null -eq $requestContext) { $null } else { [string]$requestContext.path }
            $requestSha256Value = if ($null -eq $requestContext) { $null } else { [string]$requestContext.sha256 }
            $effectiveCodexHome = Resolve-CodexHomeForEvidence -CodexHomePath $CodexHome
            $failureArtifacts = if ($null -eq $resultDocument) { ConvertTo-NonNullObjectArray -Values $null } else { ConvertTo-NonNullObjectArray -Values $resultDocument.artifacts }
            $failureError = [ordered]@{
                code    = $failureCode
                message = $originalMessage
            }
            $failureDocument = New-PrepareDocument -RootInfo $rootInfo -Status 'PrepareFailed' -RequestPathValue $requestPathValue -RequestSha256Value $requestSha256Value -EffectiveCodexHome $effectiveCodexHome -Artifacts $failureArtifacts -ErrorValue $failureError
            if (-not [string]::IsNullOrWhiteSpace($resultPathValue)) {
                try {
                    $writtenFailure = Write-PrepareResultDocument -Path $resultPathValue -Document $failureDocument -GuardSourceRoot $rootInfo.SourceRoot -GuardExecutionRoot $rootInfo.ExecutionRoot -GuardTargetPath $guardTargetPathValue -RequireAbsent
                    $resultDocument = $writtenFailure.Document
                    $resultPathValue = $writtenFailure.Path
                    $resultSha256Value = $writtenFailure.Sha256
                }
                catch {
                    $resultDocument = $failureDocument
                    $resultSha256Value = $null
                    $resultWriteFailure = [ordered]@{
                        code = 'PrepareResultWriteFailed'
                        path = $resultPathValue
                    }
                }
            }
            else {
                $resultDocument = $failureDocument
            }
        }
        if ($null -ne $resultDocument) {
            $failureResult = New-PrepareOperationResult -Document $resultDocument -ResultPathValue $resultPathValue -ResultSha256Value ([string]$resultSha256Value) -ErrorCode $failureCode -ErrorMessage $originalMessage
            if ($null -ne $resultWriteFailure) {
                $failureResult.prepareResultWriteFailure = $resultWriteFailure
            }
            $operationException = New-Object System.InvalidOperationException($originalMessage)
            $operationException.Data['operationResult'] = $failureResult
            throw $operationException
        }
        throw
    }
}
