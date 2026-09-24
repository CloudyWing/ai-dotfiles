#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Preflight', 'Prepare', 'Start', 'Inspect', 'Collect', 'QuotaProbe', 'Dispatch', 'Cleanup')]
    [string]$Operation,

    [string]$SourceRoot,

    [string]$DispatchRoot,

    [string]$ExecutionRoot,

    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
    [string]$LineSlug,

    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
    [string]$DispatchSlug,

    [ValidateSet('readonly', 'write')]
    [string]$WriteMode = 'readonly',

    [string[]]$TargetPath,

    [string]$ResultPath,

    [string]$DispatchResultPath,

    [string]$RequestPath,

    [string]$FailureReceiptPath,

    [string]$PrepareResultPath,

    [string]$PreflightResultPath,

    [string]$CodexPath,

    [string]$PromptPath,

    [ValidateSet('default', 'advisor')]
    [string]$Profile = 'default',

    [ValidateSet('Valid', 'PostResetNoSnapshot', 'SnapshotExpired', 'SnapshotUnavailable', 'ServiceRejected')]
    [string]$InitialQuotaState = 'PostResetNoSnapshot',

    [ValidateSet('primary', 'secondary', 'both', 'unknown')]
    [string]$TriggerWindow = 'unknown',

    [ValidateRange(1, 2)]
    [int]$ProbeAttempt = 1,

    [string]$CodexHome,

    [string]$Model,

    [string]$ReasoningEffort,

    [string]$TaskType = 'unspecified',

    [string]$SessionMode = 'cold-start',

    [ValidateSet('automatic-quota', 'user-explicit')]
    [string]$AdvisorRequestSource,

    [Nullable[double]]$SecondaryDaysToReset,

    [Nullable[double]]$SecondaryRemainingPercent,

    [Alias('DowngradeInstruction')]
    [switch]$InterruptionSafeguard,

    [string]$QuotaBeforePath,

    [string]$QuotaAfterPath,

    [string]$CalibrationPath,

    [string]$ScopePlanPath,

    [switch]$ContinueFromScopePlan,

    [string[]]$RequestedUnit,

    [ValidateSet('workflow-phase', 'resource-target', 'advisor-evidence-question')]
    [string]$UnitKind,

    [ValidateRange(0, 100)]
    [Nullable[double]]$PrimaryBudgetPercent,

    [ValidateRange(0, 100)]
    [Nullable[double]]$PrimaryReservePercent,

    [string]$EvidencePackPath,

    [string]$AdvisorConsultReportPath,

    [ValidateRange(5, 60)]
    [int]$AbortGraceSeconds = 30,

    [string]$BudgetMonitorPath,

    [string[]]$AddDirectory,

    [switch]$Search,

    [string[]]$CodexParentOption,

    [string]$ResumeThreadId,

    [string]$EventStreamPath,

    [string]$StdoutPath,

    [string]$ErrorStreamPath,

    [string]$LastMessagePath,

    [string]$RunRecordPath,

    [string]$ThreadIdPath,

    [string]$PidRecordPath,

    [Parameter(Mandatory = $false)]
    [Nullable[int]]$ProcessExitCode,

    [string]$RequiredIdentifier,

    [string]$BaseSha,

    [string]$BaselinePath,

    [string]$BaselineSha256,

    [ValidateSet('workflow', 'resource')]
    [string]$DispatchKind,

    [string]$RequirementSummaryPath,

    [string[]]$ReportPath,

    [string]$ReviewerReportPath,

    [string[]]$EvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:InvocationBoundParameters = [ordered]@{}
foreach ($boundName in $PSBoundParameters.Keys) {
    $script:InvocationBoundParameters[[string]$boundName] = $PSBoundParameters[$boundName]
}
$script:RequestContext = $null
$script:DispatchStageBinding = $null
$script:RequestLiteralValues = @()
$script:RequestPrepareArtifacts = @()
$script:WorkflowCollectContractVersion = 'workflow-collect-v1'
$script:AddDirectoryExplicit = $script:InvocationBoundParameters.Contains('AddDirectory')
$script:SearchExplicit = $script:InvocationBoundParameters.Contains('Search')
$script:CodexParentOptionExplicit = $script:InvocationBoundParameters.Contains('CodexParentOption')
$script:ProfileExplicit = $script:InvocationBoundParameters.Contains('Profile')

function Test-IsWindowsPlatform {
    return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function ConvertTo-FileSystemApiPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-IsWindowsPlatform)) {
        return $Path
    }
    if ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
        return $Path
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith('\\', [System.StringComparison]::Ordinal)) {
        return '\\?\UNC\' + $fullPath.Substring(2)
    }
    return '\\?\' + $fullPath
}

function Resolve-AbsolutePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw '路徑不可為空。'
    }

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        throw "路徑必須是絕對路徑：$Path"
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Root
    )

    $fullPath = Resolve-AbsolutePath -Path $Path
    $fullRoot = (Resolve-AbsolutePath -Path $Root).TrimEnd('\', '/')
    if ([string]::Equals($fullPath, $fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $rootWithSeparator = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-DispatchScriptVariableValue {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $variable = Get-Variable -Name $Name -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $variable) {
        return $null
    }

    return $variable.Value
}


function Throw-DispatchOutputFailure {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DispatchOutputBoundary', 'DispatchOutputTrackedTarget', 'DispatchOutputTargetCollision')]
        [string]$Code,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $exception = New-Object System.InvalidOperationException(('{0}：{1}' -f $Code, $Message))
    $exception.Data['outputCode'] = $Code
    $exception.Data['errorCode'] = $Code
    throw $exception
}

function Resolve-DispatchOutputPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$CandidatePath,

        [AllowEmptyString()]
        [string]$SourceRoot,

        [AllowEmptyString()]
        [string]$ExecutionRoot,

        [string[]]$TargetPath = @()
    )

    try {
        $resolvedCandidate = Resolve-AbsolutePath -Path $CandidatePath
    }
    catch {
        Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message ('candidate path 無法解析：' + $_.Exception.Message)
    }

    $candidateRoots = New-Object System.Collections.Generic.List[string]
    foreach ($rootValue in @($SourceRoot, $ExecutionRoot)) {
        if ([string]::IsNullOrWhiteSpace([string]$rootValue)) {
            continue
        }

        try {
            $resolvedRoot = Resolve-AbsolutePath -Path ([string]$rootValue)
        }
        catch {
            Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message ('root path 無法解析：' + $_.Exception.Message)
        }

        if (-not ($candidateRoots -contains $resolvedRoot)) {
            $candidateRoots.Add($resolvedRoot)
        }
    }

    if ($candidateRoots.Count -eq 0) {
        Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message '未提供可驗證的 SourceRoot 或 ExecutionRoot。'
    }

    foreach ($rootValue in $candidateRoots.ToArray()) {
        if (-not (Test-PathWithinRoot -Path $resolvedCandidate -Root $rootValue)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $rootValue -PathType Container)) {
            Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message "root 不存在或不是目錄：$rootValue"
        }

        try {
            $gitState = Get-ExistingGitRepositoryState -SourceRoot $rootValue
        }
        catch {
            Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message ('Git tracked probe 無法判定：' + $_.Exception.Message)
        }

        if ($gitState.IsRepository) {
            try {
                $trackedState = @(Get-TrackedPathState -SourceRoot $rootValue -TargetPath @($resolvedCandidate))
            }
            catch {
                Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message ('Git tracked probe 無法判定：' + $_.Exception.Message)
            }
            if (@($trackedState | Where-Object { $_.IsTracked }).Count -gt 0) {
                Throw-DispatchOutputFailure -Code 'DispatchOutputTrackedTarget' -Message "candidate 指向 tracked file：$resolvedCandidate"
            }
        }
    }

    $collisionRoot = if (-not [string]::IsNullOrWhiteSpace([string]$SourceRoot)) {
        Resolve-AbsolutePath -Path $SourceRoot
    }
    else {
        $candidateRoots[0]
    }
    foreach ($target in @($TargetPath)) {
        if ([string]::IsNullOrWhiteSpace([string]$target)) {
            continue
        }

        try {
            $resolvedTarget = Resolve-SourceTargetPath -Path ([string]$target) -Root $collisionRoot
        }
        catch {
            Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message ('TargetPath 無法解析：' + $_.Exception.Message)
        }
        if (Test-PathWithinRoot -Path $resolvedCandidate -Root $resolvedTarget) {
            Throw-DispatchOutputFailure -Code 'DispatchOutputTargetCollision' -Message "candidate 命中 TargetPath：$resolvedCandidate; target=$resolvedTarget"
        }
    }

    return $resolvedCandidate
}

function Get-RelativePathFromRoot {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Root
    )

    $fullPath = Resolve-AbsolutePath -Path $Path
    $fullRoot = (Resolve-AbsolutePath -Path $Root).TrimEnd('\', '/')
    if (-not (Test-PathWithinRoot -Path $fullPath -Root $fullRoot)) {
        throw "路徑超出根目錄界線：$fullPath；根目錄：$fullRoot"
    }

    if ([string]::Equals($fullPath, $fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return '.'
    }

    $rootWithSeparator = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    return $fullPath.Substring($rootWithSeparator.Length)
}

function Resolve-SourceTargetPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Root
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        $fullPath = Resolve-AbsolutePath -Path $Path
    }
    else {
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path -Path $Root -ChildPath $Path))
    }

    if (-not (Test-PathWithinRoot -Path $fullPath -Root $Root)) {
        throw "目標路徑超出 sourceRoot：$fullPath"
    }

    return $fullPath
}

function Get-CommandPath {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "找不到命令：$Name"
    }

    $path = $command.Source
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = $command.Path
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = $command.Definition
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "無法解析命令的實體路徑：$Name"
    }

    return Resolve-AbsolutePath -Path $path
}

function Test-ProcessStartInfoArgumentList {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.ProcessStartInfo]$StartInfo
    )

    return $null -ne $StartInfo.PSObject.Properties['ArgumentList']
}

function ConvertTo-WindowsProcessArgument {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.Length -eq 0) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

function Add-ProcessArguments {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.ProcessStartInfo]$StartInfo,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    if (Test-ProcessStartInfoArgumentList -StartInfo $StartInfo) {
        foreach ($argument in $Arguments) {
            [void]$StartInfo.ArgumentList.Add($argument)
        }
        return
    }

    $StartInfo.Arguments = (($Arguments | ForEach-Object {
                ConvertTo-WindowsProcessArgument -Value $_
            }) -join ' ')
}

function New-ProcessStartInfo {
    param(
        [Parameter(Mandatory)]
        [string]$FileName,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$RedirectOutput
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FileName
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    Add-ProcessArguments -StartInfo $startInfo -Arguments $Arguments

    if ($RedirectOutput) {
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList @($false)
        if ($null -ne $startInfo.PSObject.Properties['StandardInputEncoding']) {
            $startInfo.StandardInputEncoding = $utf8NoBom
        }
        $startInfo.StandardOutputEncoding = $utf8NoBom
        $startInfo.StandardErrorEncoding = $utf8NoBom
    }

    return $startInfo
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)]
        [string]$FileName,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [AllowEmptyString()]
        [string]$StandardInput,

        [switch]$AllowFailure
    )

    $startInfo = New-ProcessStartInfo -FileName $FileName -WorkingDirectory $WorkingDirectory -Arguments $Arguments -RedirectOutput
    $process = New-Object System.Diagnostics.Process
    $null = ($process.StartInfo = $startInfo)
    try {
        if (-not $process.Start()) {
            throw "無法啟動外部命令：$FileName"
        }

        if ($null -ne $StandardInput) {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            $inputBytes = $utf8NoBom.GetBytes($StandardInput)
            $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
            $process.StandardInput.BaseStream.Flush()
        }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $result = [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdout
            StdErr   = $stderr
        }

        if (-not $AllowFailure -and $result.ExitCode -ne 0) {
            throw "外部命令失敗，exit code $($result.ExitCode)：$FileName $($Arguments -join ' ')`n$($result.StdErr)"
        }

        return $result
    }
    finally {
        $process.Dispose()
    }
}

function Get-GitPath {
    if (Test-IsWindowsPlatform) {
        return Get-CommandPath -Name 'git.exe'
    }

    return Get-CommandPath -Name 'git'
}

function Invoke-GitCommand {
    param(
        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [AllowEmptyString()]
        [string]$StandardInput,

        [switch]$AllowFailure
    )

    $gitPath = Get-GitPath
    return Invoke-ExternalCommand -FileName $gitPath -WorkingDirectory $WorkingDirectory -Arguments $Arguments -StandardInput $StandardInput -AllowFailure:$AllowFailure
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList @($false)
    [System.IO.File]::WriteAllText((ConvertTo-FileSystemApiPath -Path $Path), $Content, $encoding)
}


function ConvertTo-InvariantDouble {
    param(
        [Parameter(Mandatory)]
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$Name
    )

    try {
        return [double]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        throw "額度快照欄位 $Name 不是有效數值：$Value"
    }
}

function Read-QuotaSnapshot {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $snapshotPath = Resolve-AbsolutePath -Path $Path
    if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
        throw "找不到額度快照：$snapshotPath"
    }

    $content = Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "額度快照為空：$snapshotPath"
    }

    if ($content.TrimStart().StartsWith('{')) {
        try {
            $document = $content | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "額度快照 JSON 格式錯誤：$snapshotPath；$($_.Exception.Message)"
        }

        $schemaProperty = $document.PSObject.Properties['schema']
        $stateProperty = $document.PSObject.Properties['state']
        $supportedSchemas = @('quota-snapshot.v1', 'ai-sessions.quota-snapshot.v1')
        if ($null -eq $schemaProperty -or $supportedSchemas -notcontains [string]$schemaProperty.Value) {
            throw "額度快照 schema 不支援：$snapshotPath"
        }
        if ($null -eq $stateProperty) {
            throw "額度快照缺少 state：$snapshotPath"
        }
        $stateValue = [string]$stateProperty.Value
        $supportedStates = @('Valid', 'PostResetNoSnapshot', 'SnapshotExpired', 'SnapshotUnavailable', 'ServiceRejected', 'Invalid')
        if ($supportedStates -notcontains $stateValue) {
            throw "額度快照 state 不支援：$snapshotPath；quota_state=$stateValue"
        }

        $windowValues = [ordered]@{}
        $windowObjects = [ordered]@{}
        $observationObjects = [ordered]@{}
        foreach ($windowName in @('primary', 'secondary')) {
            $windowProperty = $document.PSObject.Properties[$windowName]
            if ($null -eq $windowProperty -or $null -eq $windowProperty.Value) {
                if ($stateValue -eq 'Valid') {
                    throw "額度快照缺少視窗：$snapshotPath；$windowName"
                }
                $windowObjects[$windowName] = $null
            }
            else {
                $window = $windowProperty.Value
                foreach ($requiredName in @('used_percent', 'remaining_percent', 'window_minutes', 'resets_at', 'source_file')) {
                    $requiredProperty = $window.PSObject.Properties[$requiredName]
                    if ($null -eq $requiredProperty -or $null -eq $requiredProperty.Value -or ([string]$requiredName -eq 'source_file' -and [string]::IsNullOrWhiteSpace([string]$requiredProperty.Value))) {
                        throw "額度快照缺少欄位：$snapshotPath；$windowName.$requiredName"
                    }
                }

                try {
                    $usedPercent = [double]$window.used_percent
                    $remainingPercent = [double]$window.remaining_percent
                    $windowMinutes = [int64]$window.window_minutes
                    $resetsAt = [int64]$window.resets_at
                }
                catch {
                    throw "額度快照欄位不是有效數值：$snapshotPath；$windowName"
                }
                if ($usedPercent -lt 0 -or $usedPercent -gt 100 -or $remainingPercent -lt 0 -or $remainingPercent -gt 100 -or $windowMinutes -le 0 -or $resetsAt -le 0) {
                    throw "額度快照欄位超出有效範圍：$snapshotPath；$windowName"
                }

                $windowObject = [ordered]@{
                    used_percent      = $usedPercent
                    remaining_percent = $remainingPercent
                    window_minutes    = $windowMinutes
                    resets_at         = $resetsAt
                    source_file       = [string]$window.source_file
                }
                $windowObjects[$windowName] = $windowObject
                $prefix = $windowName + '_'
                $windowValues[$prefix + 'used_percent'] = $usedPercent
                $windowValues[$prefix + 'remaining_percent'] = $remainingPercent
                $windowValues[$prefix + 'window_minutes'] = $windowMinutes
                $windowValues[$prefix + 'resets_at'] = $resetsAt
                $windowValues[$prefix + 'source_file'] = [string]$window.source_file
                if ($null -ne $window.PSObject.Properties['days_to_reset']) {
                    $windowValues[$prefix + 'days_to_reset'] = [double]$window.days_to_reset
                }
                if ($null -ne $window.PSObject.Properties['window_days']) {
                    $windowValues[$prefix + 'window_days'] = [double]$window.window_days
                }
            }

            $observation = $null
            $observationsProperty = $document.PSObject.Properties['observations']
            if ($null -ne $observationsProperty -and $null -ne $observationsProperty.Value) {
                $observationProperty = $observationsProperty.Value.PSObject.Properties[$windowName]
                if ($null -ne $observationProperty) {
                    $observation = $observationProperty.Value
                }
            }

            if ($null -ne $observation) {
                foreach ($requiredObservationName in @('used_percent', 'remaining_percent', 'source', 'freshness', 'window', 'resets_at')) {
                    $requiredObservationProperty = $observation.PSObject.Properties[$requiredObservationName]
                    if ($null -eq $requiredObservationProperty -or
                        ($null -eq $requiredObservationProperty.Value -and ($stateValue -eq 'Valid' -or ([string]$requiredObservationName -in @('source', 'window', 'freshness')))) -or
                        ([string]$requiredObservationName -in @('source', 'window', 'freshness') -and [string]::IsNullOrWhiteSpace([string]$requiredObservationProperty.Value))) {
                        throw "額度 observation 缺少欄位：$snapshotPath；observations.$windowName.$requiredObservationName"
                    }
                }
                if ([string]$observation.window -ne $windowName -or [string]$observation.freshness -notin @('fresh', 'stale', 'unknown')) {
                    throw "額度 observation 欄位無效：$snapshotPath；observations.$windowName"
                }
                $observationUsed = $null
                $observationRemaining = $null
                $observationReset = $null
                if ($null -ne $observation.used_percent) {
                    $observationUsed = [double]$observation.used_percent
                }
                if ($null -ne $observation.remaining_percent) {
                    $observationRemaining = [double]$observation.remaining_percent
                }
                if ($null -ne $observation.resets_at) {
                    $observationReset = [int64]$observation.resets_at
                }
                if (($null -ne $observationUsed -and ($observationUsed -lt 0 -or $observationUsed -gt 100)) -or
                    ($null -ne $observationRemaining -and ($observationRemaining -lt 0 -or $observationRemaining -gt 100)) -or
                    ($null -ne $observationReset -and $observationReset -le 0)) {
                    throw "額度 observation 欄位超出有效範圍：$snapshotPath；observations.$windowName"
                }
                $observedAtUtc = $null
                $observedAtProperty = $observation.PSObject.Properties['observed_at_utc']
                if ($null -ne $observedAtProperty -and -not [string]::IsNullOrWhiteSpace([string]$observedAtProperty.Value)) {
                    try {
                        $observedAtUtc = [DateTimeOffset]$observedAtProperty.Value
                    }
                    catch {
                        throw "額度 observation observed_at_utc 無效：$snapshotPath；observations.$windowName"
                    }
                }
                $observationObjects[$windowName] = [ordered]@{
                    used_percent      = $observationUsed
                    remaining_percent = $observationRemaining
                    observed_at_utc   = $observedAtUtc
                    source            = [string]$observation.source
                    freshness         = [string]$observation.freshness
                    window            = $windowName
                    resets_at         = $observationReset
                }
            }
            else {
                $windowObject = $windowObjects[$windowName]
                $observationObjects[$windowName] = [ordered]@{
                    used_percent      = if ($null -eq $windowObject) { $null } else { $windowObject.used_percent }
                    remaining_percent = if ($null -eq $windowObject) { $null } else { $windowObject.remaining_percent }
                    observed_at_utc   = $null
                    source            = if ($null -eq $windowObject) { 'snapshot-unavailable' } else { [string]$windowObject.source_file }
                    freshness         = 'unknown'
                    window            = $windowName
                    resets_at         = if ($null -eq $windowObject) { $null } else { $windowObject.resets_at }
                }
            }
        }

        $capturedAtUtc = $null
        $capturedAtProperty = $document.PSObject.Properties['captured_at_utc']
        if ($null -ne $capturedAtProperty -and -not [string]::IsNullOrWhiteSpace([string]$capturedAtProperty.Value)) {
            try {
                $capturedAtUtc = [DateTimeOffset]$capturedAtProperty.Value
            }
            catch {
                throw "額度快照 captured_at_utc 無效：$snapshotPath"
            }
        }

        $serviceRejection = $null
        $serviceRejectionProperty = $document.PSObject.Properties['service_rejection']
        if ($null -ne $serviceRejectionProperty -and $null -ne $serviceRejectionProperty.Value) {
            $serviceRejection = $serviceRejectionProperty.Value
            foreach ($requiredRejectionName in @('status', 'window', 'reason_code', 'observed_at_utc', 'raw_evidence_path', 'raw_evidence_sha256', 'retry_allowed')) {
                $requiredRejectionProperty = $serviceRejection.PSObject.Properties[$requiredRejectionName]
                if ($null -eq $requiredRejectionProperty -or $null -eq $requiredRejectionProperty.Value -or ([string]$requiredRejectionName -in @('status', 'window', 'reason_code', 'raw_evidence_path', 'raw_evidence_sha256') -and [string]::IsNullOrWhiteSpace([string]$requiredRejectionProperty.Value))) {
                    throw "額度 service_rejection 缺少欄位：$snapshotPath；$requiredRejectionName"
                }
            }
            if ([string]$serviceRejection.status -ne 'quota-rejected' -or $serviceRejection.retry_allowed -ne $false) {
                throw "額度 service_rejection 欄位無效：$snapshotPath"
            }
        }

        $serviceRejectionEvidence = $null
        $serviceRejectionEvidenceProperty = $document.PSObject.Properties['service_rejection_evidence']
        if ($null -ne $serviceRejectionEvidenceProperty -and $null -ne $serviceRejectionEvidenceProperty.Value) {
            $serviceRejectionEvidence = $serviceRejectionEvidenceProperty.Value
        }

        return [ordered]@{
            path              = $snapshotPath
            schema            = [string]$schemaProperty.Value
            state             = $stateValue
            capturedAtUtc     = $capturedAtUtc
            values            = $windowValues
            primary           = $windowObjects['primary']
            secondary         = $windowObjects['secondary']
            observations      = $observationObjects
            serviceRejection  = $serviceRejection
            serviceRejectionEvidence = $serviceRejectionEvidence
            document          = $document
        }
    }

    $values = [ordered]@{}
    foreach ($line in ($content -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $match = [regex]::Match($line, '^([^=]+)=(.*)$')
        if (-not $match.Success) {
            throw "額度快照格式錯誤：$snapshotPath；內容：$line"
        }

        $name = $match.Groups[1].Value.Trim()
        $value = $match.Groups[2].Value
        if ($name -match '(?i)(used_percent|remaining_percent|days_to_reset|window_days)$') {
            $values[$name] = ConvertTo-InvariantDouble -Value $value -Name $name
        }
        elseif ($name -match '(?i)(window_minutes|resets_at)$') {
            $values[$name] = [int64](ConvertTo-InvariantDouble -Value $value -Name $name)
        }
        else {
            $values[$name] = $value
        }
    }

    foreach ($requiredName in @(
            'primary_used_percent',
            'primary_remaining_percent',
            'primary_days_to_reset',
            'primary_window_minutes',
            'primary_resets_at',
            'secondary_used_percent',
            'secondary_remaining_percent',
            'secondary_days_to_reset',
            'secondary_window_minutes',
            'secondary_resets_at'
        )) {
        if (-not $values.Contains($requiredName)) {
            throw "額度快照缺少欄位：$snapshotPath；$requiredName"
        }
    }

    return [ordered]@{
        path          = $snapshotPath
        schema        = 'legacy-key-value'
        state         = 'Valid'
        capturedAtUtc = $null
        values        = $values
        primary       = [ordered]@{
            used_percent      = $values['primary_used_percent']
            remaining_percent = $values['primary_remaining_percent']
            window_minutes    = $values['primary_window_minutes']
            resets_at         = $values['primary_resets_at']
            source_file       = if ($values.Contains('primary_source_file')) { [string]$values['primary_source_file'] } else { [string]$snapshotPath }
        }
        secondary     = [ordered]@{
            used_percent      = $values['secondary_used_percent']
            remaining_percent = $values['secondary_remaining_percent']
            window_minutes    = $values['secondary_window_minutes']
            resets_at         = $values['secondary_resets_at']
            source_file       = if ($values.Contains('secondary_source_file')) { [string]$values['secondary_source_file'] } else { [string]$snapshotPath }
        }
        observations  = [ordered]@{
            primary   = [ordered]@{
                used_percent      = $values['primary_used_percent']
                remaining_percent = $values['primary_remaining_percent']
                observed_at_utc   = $null
                source            = if ($values.Contains('primary_source_file')) { [string]$values['primary_source_file'] } else { [string]$snapshotPath }
                freshness         = 'unknown'
                window            = 'primary'
                resets_at         = $values['primary_resets_at']
            }
            secondary = [ordered]@{
                used_percent      = $values['secondary_used_percent']
                remaining_percent = $values['secondary_remaining_percent']
                observed_at_utc   = $null
                source            = if ($values.Contains('secondary_source_file')) { [string]$values['secondary_source_file'] } else { [string]$snapshotPath }
                freshness         = 'unknown'
                window            = 'secondary'
                resets_at         = $values['secondary_resets_at']
            }
        }
        serviceRejection = $null
        serviceRejectionEvidence = $null
        document      = $null
    }
}

function Get-OptionalObjectProperty {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) {
            return $null
        }
        Write-Output -NoEnumerate -InputObject $Object[$Name]
        return
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    Write-Output -NoEnumerate -InputObject $property.Value
}

function Get-QuotaSnapshotObservation {
    param(
        [AllowNull()]
        [object]$Snapshot,

        [Parameter(Mandatory)]
        [ValidateSet('primary', 'secondary')]
        [string]$WindowName
    )

    if ($null -eq $Snapshot) {
        return $null
    }
    $observations = Get-DispatchJsonProperty -Object $Snapshot -Name 'observations'
    if ($null -eq $observations) {
        return $null
    }
    return Get-DispatchJsonProperty -Object $observations -Name $WindowName
}

function Test-QuotaSnapshotObservationContract {
    param(
        [AllowNull()]
        [object]$Snapshot
    )

    if ($null -eq $Snapshot) {
        return $false
    }
    if ($Snapshot -is [System.Collections.IDictionary]) {
        return $Snapshot.Contains('observations')
    }
    return $null -ne $Snapshot.PSObject.Properties['observations']
}

function Test-QuotaSnapshotHasObservations {
    param(
        [AllowNull()]
        [object]$Snapshot
    )

    if (-not (Test-QuotaSnapshotObservationContract -Snapshot $Snapshot)) {
        return $false
    }
    foreach ($windowName in @('primary', 'secondary')) {
        $observation = Get-QuotaSnapshotObservation -Snapshot $Snapshot -WindowName $windowName
        if ($null -eq $observation) {
            return $false
        }
        $used = Get-DispatchJsonProperty -Object $observation -Name 'used_percent'
        $remaining = Get-DispatchJsonProperty -Object $observation -Name 'remaining_percent'
        $resetsAt = Get-DispatchJsonProperty -Object $observation -Name 'resets_at'
        try {
            $usedValue = [double]$used
            $remainingValue = [double]$remaining
            $resetValue = [int64]$resetsAt
        }
        catch {
            return $false
        }
        if ([double]::IsNaN($usedValue) -or [double]::IsInfinity($usedValue) -or $usedValue -lt 0 -or $usedValue -gt 100 -or
            [double]::IsNaN($remainingValue) -or [double]::IsInfinity($remainingValue) -or $remainingValue -lt 0 -or $remainingValue -gt 100 -or
            $resetValue -le 0) {
            return $false
        }
    }
    return $true
}

function Get-QuotaSnapshotFreshness {
    param(
        [AllowNull()]
        [object]$Snapshot
    )

    if (-not (Test-QuotaSnapshotObservationContract -Snapshot $Snapshot)) {
        return 'unknown'
    }
    $freshnessValues = New-Object System.Collections.Generic.List[string]
    foreach ($windowName in @('primary', 'secondary')) {
        $observation = Get-QuotaSnapshotObservation -Snapshot $Snapshot -WindowName $windowName
        $freshness = [string](Get-DispatchJsonProperty -Object $observation -Name 'freshness')
        if ($freshness -notin @('fresh', 'stale', 'unknown')) {
            return 'unknown'
        }
        $freshnessValues.Add($freshness)
    }
    if ($freshnessValues -contains 'stale') {
        return 'stale'
    }
    if ($freshnessValues.Count -eq 2 -and @($freshnessValues | Where-Object { $_ -eq 'fresh' }).Count -eq 2) {
        return 'fresh'
    }
    return 'unknown'
}

function Get-QuotaSnapshotServiceRejection {
    param(
        [AllowNull()]
        [object]$Snapshot
    )

    return Get-DispatchJsonProperty -Object $Snapshot -Name 'serviceRejection'
}


function Test-QuotaSnapshotFresh {
    param(
        [Parameter(Mandatory)]
        [psobject]$Snapshot,

        [int]$MaxAgeMinutes = 30
    )

    if ($null -eq $Snapshot -or $Snapshot.state -ne 'Valid' -or $null -ne (Get-QuotaSnapshotServiceRejection -Snapshot $Snapshot)) {
        return $false
    }
    if (-not (Test-QuotaSnapshotHasObservations -Snapshot $Snapshot) -or (Get-QuotaSnapshotFreshness -Snapshot $Snapshot) -ne 'fresh') {
        return $false
    }
    foreach ($windowName in @('primary', 'secondary')) {
        $observation = Get-QuotaSnapshotObservation -Snapshot $Snapshot -WindowName $windowName
        $observedAt = Get-DispatchJsonProperty -Object $observation -Name 'observed_at_utc'
        if ($null -eq $observedAt -or [string]::IsNullOrWhiteSpace([string]$observedAt)) {
            return $false
        }
        try {
            $ageMinutes = ([DateTimeOffset]::UtcNow - [DateTimeOffset]$observedAt).TotalMinutes
        }
        catch {
            return $false
        }
        if ($ageMinutes -lt 0 -or $ageMinutes -gt $MaxAgeMinutes) {
            return $false
        }
    }
    return $true
}

function Get-QuotaSnapshotDelta {
    param(
        [Parameter(Mandatory)]
        [psobject]$Before,

        [Parameter(Mandatory)]
        [psobject]$After
    )

    if ($null -eq $Before -or $null -eq $After) {
        return $null
    }
    return [double]$Before.primary.remaining_percent - [double]$After.primary.remaining_percent
}

function Get-AdvisorActivationDecision {
    param(
        [Parameter(Mandatory)]
        [psobject]$QuotaSnapshot,

        [Parameter(Mandatory = $false)]
        [Alias('SnapshotState')]
        [AllowEmptyString()]
        [string]$State,

        [Parameter(Mandatory)]
        [double]$EstimatePercent,

        [Parameter(Mandatory)]
        [ValidateSet('automatic-quota', 'user-explicit')]
        [string]$RequestSource,

        [Parameter(Mandatory = $false)]
        [bool]$HasFreshObservations = $true,

        [Parameter(Mandatory = $false)]
        [bool]$ServiceRejected = $false
    )

    $primaryRemaining = $null
    if ($null -ne $QuotaSnapshot -and $null -ne $QuotaSnapshot.primary) {
        $primaryRemaining = [double]$QuotaSnapshot.primary.remaining_percent
    }

    $snapshotState = [string](Get-DispatchJsonProperty -Object $QuotaSnapshot -Name 'state')
    $effectiveState = if ([string]::IsNullOrWhiteSpace($State)) { $snapshotState } else { $State }
    $snapshotStateValid = [string]::Equals($snapshotState, 'Valid', [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals($effectiveState, 'Valid', [System.StringComparison]::OrdinalIgnoreCase)
    $snapshotSafe = $null -ne $primaryRemaining -and $snapshotStateValid -and $HasFreshObservations -and -not $ServiceRejected
    $reservePercent = 30.0
    $hardLimit = [math]::Round($EstimatePercent * 1.25, 2)
    $automaticEligible = $snapshotSafe -and $primaryRemaining - $reservePercent -ge $hardLimit

    if ($RequestSource -eq 'user-explicit') {
        if (-not $snapshotSafe) {
            return [ordered]@{
                granted                  = $false
                activationMode           = 'none'
                authorizationSource      = $null
                reserveBypassed           = $false
                minimumUnitOverBudget     = $false
                reasonCode                = if ($ServiceRejected) { 'QuotaServiceRejected' } else { 'blocked-no-fresh-quota' }
                notice                    = 'advisor 需要有效且新鮮的 quota snapshot 才能啟動。'
                requiredAuthorization    = 'user-explicit'
                hardLimitPercent         = $hardLimit
                remainingPercent         = $primaryRemaining
            }
        }

        return [ordered]@{
            granted                  = $true
            activationMode           = 'user-authorized'
            authorizationSource      = 'user-explicit'
            reserveBypassed           = $true
            minimumUnitOverBudget     = $primaryRemaining -lt $hardLimit
            reasonCode                = $null
            notice                    = '使用者明示要求 advisor，保留安全 snapshot 並略過 30% reserve。'
            requiredAuthorization    = $null
            hardLimitPercent         = $hardLimit
            remainingPercent         = $primaryRemaining
        }
    }

    if (-not $snapshotSafe) {
        return [ordered]@{
            granted                  = $false
            activationMode           = 'none'
            authorizationSource      = $null
            reserveBypassed           = $false
            minimumUnitOverBudget     = $false
            reasonCode                = if ($ServiceRejected) { 'QuotaServiceRejected' } else { 'blocked-no-fresh-quota' }
            notice                    = 'advisor 的 automatic-quota 啟動需要有效且新鮮的 quota snapshot。'
            requiredAuthorization    = 'user-explicit'
            hardLimitPercent         = $hardLimit
            remainingPercent         = $primaryRemaining
        }
    }

    if (-not $automaticEligible) {
        return [ordered]@{
            granted                  = $false
            activationMode           = 'none'
            authorizationSource      = $null
            reserveBypassed           = $false
            minimumUnitOverBudget     = $false
            reasonCode                = 'AdvisorAuthorizationRequired'
            notice                    = 'advisor automatic-quota 估算後無法在 primary 保留 30% reserve，需使用者明示要求。'
            requiredAuthorization    = 'user-explicit'
            hardLimitPercent         = $hardLimit
            remainingPercent         = $primaryRemaining
        }
    }

    return [ordered]@{
        granted                  = $true
        activationMode           = 'automatic-quota'
        authorizationSource      = 'automatic-quota'
        reserveBypassed           = $false
        minimumUnitOverBudget     = $false
        reasonCode                = $null
        notice                    = 'advisor automatic-quota 已通過 30% reserve 與估算上限檢查。'
        requiredAuthorization    = $null
        hardLimitPercent         = $hardLimit
        remainingPercent         = $primaryRemaining
    }
}

function Get-ConservativeEstimate {
    param(
        [Parameter(Mandatory)]
        [string]$TaskType
    )

    switch ($TaskType.ToLowerInvariant()) {
        'advisor-consult' { return 24.0 }
        'readonly-review' { return 7.0 }
        'review' { return 7.0 }
        'script-change' { return 14.0 }
        default { return $null }
    }
}

function Get-CalibrationEstimate {
    param(
        [string]$Path,

        [AllowNull()]
        [object]$ModelEvidence,

        [AllowNull()]
        [object]$ReasoningEffortEvidence,

        [string]$Model,

        [string]$ReasoningEffort,

        [Parameter(Mandatory)]
        [string]$Profile,

        [Parameter(Mandatory)]
        [string]$SessionMode,

        [Parameter(Mandatory)]
        [string]$TaskType
    )

    $normalizedModelEvidence = $null
    if ($null -ne $ModelEvidence) {
        $normalizedModelEvidence = ConvertTo-DispatchEvidence -Evidence $ModelEvidence -Field 'model'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Model)) {
        $normalizedModelEvidence = New-ConfirmedDispatchEvidence -Value $Model -Source 'compatibility-parameter' -Field 'model'
    }
    else {
        $normalizedModelEvidence = New-UnknownDispatchEvidence -Field 'model' -Reason '校準缺少 resolved model evidence。' -Source 'evidence-missing'
    }
    $normalizedEffortEvidence = $null
    if ($null -ne $ReasoningEffortEvidence) {
        $normalizedEffortEvidence = ConvertTo-DispatchEvidence -Evidence $ReasoningEffortEvidence -Field 'model_reasoning_effort'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ReasoningEffort)) {
        $normalizedEffortEvidence = New-ConfirmedDispatchEvidence -Value $ReasoningEffort -Source 'compatibility-parameter' -Field 'model_reasoning_effort'
    }
    else {
        $normalizedEffortEvidence = New-UnknownDispatchEvidence -Field 'model_reasoning_effort' -Reason '校準缺少 resolved reasoning effort evidence。' -Source 'evidence-missing'
    }
    $resolvedModel = Get-DispatchEvidenceValue -Evidence $normalizedModelEvidence
    $resolvedEffort = Get-DispatchEvidenceValue -Evidence $normalizedEffortEvidence
    if ($null -eq $resolvedModel -or $null -eq $resolvedEffort) {
        return [ordered]@{
            estimate = $null
            source   = 'evidence-unknown'
            sampleCount = 0
            model = $normalizedModelEvidence
            reasoning_effort = $normalizedEffortEvidence
        }
    }

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [ordered]@{
            estimate = $null
            source   = 'none'
            sampleCount = 0
            model = $normalizedModelEvidence
            reasoning_effort = $normalizedEffortEvidence
        }
    }

    $records = @(Get-CalibrationRecords -Path $Path | Where-Object {
            $groupProperty = $_.PSObject.Properties['group']
            $group = if ($null -eq $groupProperty) { $null } else { $groupProperty.Value }
            $groupModel = Get-DispatchJsonProperty -Object $group -Name 'model'
            $groupEffort = Get-DispatchJsonProperty -Object $group -Name 'reasoning_effort'
            $evidenceProperty = $_.PSObject.Properties['model_evidence']
            $effortEvidenceProperty = $_.PSObject.Properties['reasoning_effort_evidence']
            $recordEvidence = if ($null -eq $evidenceProperty) { $null } else { $evidenceProperty.Value }
            $recordEffortEvidence = if ($null -eq $effortEvidenceProperty) { $null } else { $effortEvidenceProperty.Value }
            $recordResolvedModelEvidence = Get-DispatchJsonProperty -Object $recordEvidence -Name 'resolved'
            $recordRuntimeModelEvidence = Get-DispatchJsonProperty -Object $recordEvidence -Name 'runtime_verifiable'
            $recordResolvedEffortEvidence = Get-DispatchJsonProperty -Object $recordEffortEvidence -Name 'resolved'
            $recordRuntimeEffortEvidence = Get-DispatchJsonProperty -Object $recordEffortEvidence -Name 'runtime_verifiable'
            $recordResolvedModel = Get-DispatchEvidenceValue -Evidence $recordResolvedModelEvidence
            $recordRuntimeModel = Get-DispatchEvidenceValue -Evidence $recordRuntimeModelEvidence
            $recordResolvedEffort = Get-DispatchEvidenceValue -Evidence $recordResolvedEffortEvidence
            $recordRuntimeEffort = Get-DispatchEvidenceValue -Evidence $recordRuntimeEffortEvidence
            $_.calibration_eligible -eq $true -and
            $groupModel -eq $resolvedModel -and
            $groupEffort -eq $resolvedEffort -and
            $_.profile -eq $Profile -and
            $_.session_mode -eq $SessionMode -and
            $_.task_type -eq $TaskType -and
            $recordResolvedModel -eq $resolvedModel -and
            $recordRuntimeModel -eq $resolvedModel -and
            $recordResolvedEffort -eq $resolvedEffort -and
            $recordRuntimeEffort -eq $resolvedEffort -and
            $null -ne $_.observed_primary_delta_percent
        })
    $deltas = @($records | ForEach-Object { [double]$_.observed_primary_delta_percent } | Where-Object { $_ -ge 0 })
    if ($deltas.Count -ge 5) {
        $sorted = @($deltas | Sort-Object)
        $index = [math]::Ceiling($sorted.Count * 0.75) - 1
        if ($index -lt 0) {
            $index = 0
        }
        return [ordered]@{
            estimate = [double]$sorted[$index]
            source   = 'p75'
            sampleCount = $sorted.Count
            model = $normalizedModelEvidence
            reasoning_effort = $normalizedEffortEvidence
        }
    }

    return [ordered]@{
        estimate = $null
        source   = 'insufficient-samples'
        sampleCount = $deltas.Count
        model = $normalizedModelEvidence
        reasoning_effort = $normalizedEffortEvidence
    }
}

function Get-DispatchUnitList {
    param(
        [string[]]$RequestedUnit,

        [string]$DispatchKind,

        [string]$UnitKind,

        [string]$ExecutionRoot,

        [string]$LineSlug,

        [string]$EvidencePackPath,

        [string[]]$EvidenceQuestionUnits,

        [string[]]$TargetPath
    )

    $units = New-Object System.Collections.Generic.List[string]
    $isAdvisorEvidence = $UnitKind -eq 'advisor-evidence-question' -or -not [string]::IsNullOrWhiteSpace($EvidencePackPath)
    if ($isAdvisorEvidence) {
        $declaredUnits = @($EvidenceQuestionUnits | ForEach-Object { ([string]$_).Trim() })
        if ($declaredUnits.Count -eq 0) {
            throw 'EvidencePackInvalid：advisor evidence pack 未宣告 question units。'
        }
        if ($null -ne $RequestedUnit -and $RequestedUnit.Count -gt 0) {
            foreach ($unit in $RequestedUnit) {
                if ([string]::IsNullOrWhiteSpace($unit)) {
                    throw 'RequestedUnit 不可包含空白項目。'
                }
                $units.Add($unit.Trim())
            }
            $requestedUnits = @($units.ToArray())
            if (-not (Test-StringArrayEqual -Left $requestedUnits -Right $declaredUnits)) {
                $differences = New-Object System.Collections.Generic.List[string]
                $maxCount = [math]::Max($requestedUnits.Count, $declaredUnits.Count)
                for ($index = 0; $index -lt $maxCount; $index++) {
                    $expectedValue = if ($index -lt $declaredUnits.Count) { $declaredUnits[$index] } else { '<none>' }
                    $requestedValue = if ($index -lt $requestedUnits.Count) { $requestedUnits[$index] } else { '<none>' }
                    if (-not [string]::Equals($expectedValue, $requestedValue, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $differences.Add(('index {0}: expected={1}; requested={2}' -f $index, $expectedValue, $requestedValue))
                    }
                }
                throw ('EvidencePackUnitOrderMismatch：RequestedUnit 必須完全符合 evidence pack 宣告順序；expected=' + ($declaredUnits -join ', ') + '；requested=' + ($requestedUnits -join ', ') + '；differences=' + ($differences.ToArray() -join '; '))
            }
        }
        else {
            foreach ($questionId in $declaredUnits) {
                $units.Add($questionId)
            }
        }
    }
    elseif ($null -ne $RequestedUnit -and $RequestedUnit.Count -gt 0) {
        foreach ($unit in $RequestedUnit) {
            if ([string]::IsNullOrWhiteSpace($unit)) {
                throw 'RequestedUnit 不可包含空白項目。'
            }
            $units.Add($unit.Trim())
        }
    }
    elseif ($DispatchKind -eq 'workflow') {
        $designPath = Join-Path -Path $ExecutionRoot -ChildPath ('.local\ai-sessions\handoff\' + $LineSlug + '\design.md')
        if (-not (Test-Path -LiteralPath $designPath -PathType Leaf)) {
            throw "找不到 Workflow 設計文件，無法建立 Phase 單位清單：$designPath"
        }
        foreach ($line in Get-Content -LiteralPath $designPath -Encoding UTF8) {
            if ($line -match '^###\s+Phase\s+[^：:]+') {
                $units.Add($line.TrimStart('#', ' '))
            }
        }
    }
    elseif ($DispatchKind -eq 'resource' -and $null -ne $TargetPath -and $TargetPath.Count -gt 0) {
        foreach ($target in $TargetPath) {
            if ([string]::IsNullOrWhiteSpace($target)) {
                throw 'TargetPath 不可包含空白項目。'
            }
            $units.Add($target.Trim())
        }
    }
    else {
        $units.Add('dispatch-unit')
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($unit in $units) {
        if (-not $seen.Add($unit)) {
            throw "派工單位不可重複：$unit"
        }
    }
    return @($units.ToArray())
}

function Test-DefaultProfileThreshold {
    param(
        [Parameter(Mandatory)]
        [psobject]$Snapshot
    )

    if ($null -eq $Snapshot -or $Snapshot.state -ne 'Valid' -or -not (Test-QuotaSnapshotHasObservations -Snapshot $Snapshot) -or (Get-QuotaSnapshotFreshness -Snapshot $Snapshot) -ne 'fresh') {
        return $false
    }

    $primaryObservation = Get-QuotaSnapshotObservation -Snapshot $Snapshot -WindowName 'primary'
    $secondaryObservation = Get-QuotaSnapshotObservation -Snapshot $Snapshot -WindowName 'secondary'
    return [double](Get-DispatchJsonProperty -Object $primaryObservation -Name 'remaining_percent') -ge 30.0 -and
        [double](Get-DispatchJsonProperty -Object $secondaryObservation -Name 'remaining_percent') -ge 15.0
}

function Get-DefaultUnitKind {
    param(
        [string]$DispatchKind,

        [string]$UnitKind,

        [string]$TaskType
    )

    if (-not [string]::IsNullOrWhiteSpace($UnitKind)) {
        return $UnitKind
    }
    if ($TaskType -eq 'advisor-consult') {
        return 'advisor-evidence-question'
    }
    if ($DispatchKind -eq 'workflow') {
        return 'workflow-phase'
    }
    return 'resource-target'
}

function New-ScopePlan {
    param(
        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [string]$DispatchKind,

        [Parameter(Mandatory)]
        [string]$TaskType,

        [Parameter(Mandatory)]
        [string]$RequestedProfile,

        [Parameter(Mandatory)]
        [string]$SessionMode,

        [Parameter(Mandatory)]
        [psobject]$BeforeSnapshot,

        [string]$CalibrationPath,

        [string[]]$Units,

        [Parameter(Mandatory)]
        [string]$UnitKind,

        [Nullable[double]]$RequestedBudgetPercent,

        [Nullable[double]]$RequestedReservePercent,

        [string]$Model,

        [AllowNull()]
        [object]$ModelEvidence,

        [AllowNull()]
        [object]$ReasoningEffortEvidence,

        [AllowNull()]
        [object]$ActivationDecision
    )

    if ($null -eq $BeforeSnapshot) {
        throw 'ScopePlan 必須提供 before quota snapshot。'
    }
    if ($null -eq $Units -or $Units.Count -eq 0) {
        throw 'ScopePlan 不可使用空的單位清單。'
    }

    $primaryWindow = Get-DispatchJsonProperty -Object $BeforeSnapshot -Name 'primary'
    $primaryObservation = Get-QuotaSnapshotObservation -Snapshot $BeforeSnapshot -WindowName 'primary'
    $remainingValue = Get-DispatchJsonProperty -Object $primaryObservation -Name 'remaining_percent'
    if ($null -eq $remainingValue) {
        $remainingValue = Get-DispatchJsonProperty -Object $primaryWindow -Name 'remaining_percent'
    }
    $remaining = 0.0
    if ($null -ne $remainingValue) {
        try {
            $remaining = [double]$remainingValue
        }
        catch {
            $remaining = 0.0
        }
    }
    if ($TaskType -eq 'advisor-consult') {
        if ($null -ne $ActivationDecision -and [bool](Get-OptionalObjectProperty -Object $ActivationDecision -Name 'reserveBypassed')) {
            $reserve = 0.0
        }
        elseif ($null -eq $RequestedReservePercent) {
            $reserve = 30.0
        }
        else {
            $reserve = [math]::Max(30.0, [double]$RequestedReservePercent)
        }
    }
    else {
        $reserve = if ($null -eq $RequestedReservePercent) { 30.0 } else { [double]$RequestedReservePercent }
    }
    $calibration = Get-CalibrationEstimate -Path $CalibrationPath -ModelEvidence $ModelEvidence -ReasoningEffortEvidence $ReasoningEffortEvidence -Model $Model -Profile $RequestedProfile -SessionMode $SessionMode -TaskType $TaskType
    $estimate = $null
    $estimateSource = 'none'
    if ($null -ne $calibration.estimate) {
        $estimate = [double]$calibration.estimate
        $estimateSource = $calibration.source
    }
    $quotaFreshness = Get-QuotaSnapshotFreshness -Snapshot $BeforeSnapshot
    $hasObservations = Test-QuotaSnapshotHasObservations -Snapshot $BeforeSnapshot
    $serviceRejection = Get-QuotaSnapshotServiceRejection -Snapshot $BeforeSnapshot
    $quotaState = [string](Get-DispatchJsonProperty -Object $BeforeSnapshot -Name 'state')
    if ($null -eq $serviceRejection) {
        if (-not $hasObservations) {
            $quotaState = 'SnapshotUnavailable'
        }
        elseif ([string]::IsNullOrWhiteSpace($quotaState)) {
            $quotaState = 'Valid'
        }
    }
    else {
        $quotaState = 'ServiceRejected'
    }
    $remainingBudget = [math]::Max(0.0, $remaining - $reserve)
    if ($RequestedProfile -eq 'default' -and $TaskType -ne 'advisor-consult' -and -not (Test-DefaultProfileThreshold -Snapshot $BeforeSnapshot)) {
        $reserve = 0.0
        $remainingBudget = [math]::Max(0.0, $remaining)
    }

    $plan = [ordered]@{
        dispatch_slug              = $DispatchSlug
        dispatch_kind              = $DispatchKind
        task_type                  = $TaskType
        requested_profile          = $RequestedProfile
        session_mode               = $SessionMode
        primary_remaining_percent  = $remaining
        primary_reserve_percent    = $reserve
        primary_budget_percent     = $null
        estimate_percent           = $estimate
        estimate_source            = $estimateSource
        unit_kind                  = $UnitKind
        requested_units            = @($Units)
        selected_units             = @()
        deferred_units             = @($Units)
        decision                   = 'blocked-no-estimate'
        decision_reason            = ''
        calibration_sample_count   = $calibration.sampleCount
        resolved_model             = Get-DispatchEvidenceValue -Evidence $ModelEvidence
        resolved_reasoning_effort  = Get-DispatchEvidenceValue -Evidence $ReasoningEffortEvidence
        quota_state                 = $quotaState
        quota_freshness             = $quotaFreshness
        quota_observation_available = $hasObservations
        service_rejection           = $serviceRejection
        retry_allowed               = if ($null -eq $serviceRejection) { $null } else { $false }
        stop_after_selected_units  = $false
        authorization_source       = if ($null -eq $ActivationDecision) { $null } else { Get-OptionalObjectProperty -Object $ActivationDecision -Name 'authorizationSource' }
        activation_mode            = if ($null -eq $ActivationDecision) { 'none' } else { Get-OptionalObjectProperty -Object $ActivationDecision -Name 'activationMode' }
        activation_granted         = if ($null -eq $ActivationDecision) { $false } else { [bool](Get-OptionalObjectProperty -Object $ActivationDecision -Name 'granted') }
        activation_notice          = if ($null -eq $ActivationDecision) { '' } else { [string](Get-OptionalObjectProperty -Object $ActivationDecision -Name 'notice') }
        advisor_hard_limit_percent = if ($null -eq $ActivationDecision) { $null } else { Get-OptionalObjectProperty -Object $ActivationDecision -Name 'hardLimitPercent' }
        advisor_unit_estimate_percent = $estimate
        reserve_bypassed            = if ($null -eq $ActivationDecision) { $false } else { [bool](Get-OptionalObjectProperty -Object $ActivationDecision -Name 'reserveBypassed') }
        minimum_unit_over_budget    = $false
    }

    if ($null -ne $serviceRejection) {
        $plan.primary_budget_percent = $remainingBudget
        if ($TaskType -eq 'advisor-consult' -and $null -eq $estimate) {
            $estimate = Get-ConservativeEstimate -TaskType $TaskType
            $estimateSource = if ($null -eq $estimate) { 'blocked-no-fresh-quota' } else { 'conservative-default' }
            $plan.estimate_percent = $estimate
            $plan.estimate_source = $estimateSource
            if ($null -ne $estimate) {
        $plan.advisor_hard_limit_percent = [double]$estimate * 1.25
            }
        }
        $plan.decision = 'blocked-no-fresh-quota'
        $plan.decision_reason = 'quota service rejection 已保留 last observation；retry_allowed=false，等待 reset 或新 quota evidence。'
        return $plan
    }

    if (-not $hasObservations) {
        $plan.primary_budget_percent = 0.0
        $plan.estimate_percent = $null
        $plan.estimate_source = 'blocked-no-fresh-quota'
        $plan.decision = 'blocked-no-fresh-quota'
        $plan.decision_reason = 'Quota snapshot 沒有可用 observation，狀態為 SnapshotUnavailable，停止建立可執行 ScopePlan。'
        return $plan
    }

    if ($TaskType -ne 'advisor-consult' -and $RequestedProfile -eq 'default' -and $quotaFreshness -eq 'fresh' -and (Test-DefaultProfileThreshold -Snapshot $BeforeSnapshot)) {
        $plan.primary_budget_percent = $remaining - $reserve
        if ($plan.primary_budget_percent -lt 0) {
            $plan.primary_budget_percent = 0.0
        }
        $plan.estimate_percent = $null
        $plan.estimate_source = 'not-required-above-threshold'
        $plan.selected_units = @($Units)
        $plan.deferred_units = @()
        $plan.decision = 'full'
        $plan.decision_reason = 'primary 剩餘至少 30% 且 secondary 剩餘至少 15%，高於預設檔位門檻，不要求估算並完整派工。'
        return $plan
    }

    if ($quotaFreshness -eq 'stale') {
        if ($TaskType -eq 'advisor-consult') {
            $plan.primary_budget_percent = $remainingBudget
            if ($null -eq $estimate) {
                $plan.estimate_source = 'blocked-no-fresh-quota'
            }
            $plan.decision = 'blocked-no-fresh-quota'
            $plan.decision_reason = 'Quota observation 已過期，advisor 必須取得 fresh evidence；保留至少 30% primary reserve。'
            if ($TaskType -eq 'advisor-consult' -and $null -ne $estimate) {
                $plan.advisor_hard_limit_percent = [double]$estimate * 1.25
            }
            return $plan
        }
        if ($remainingBudget -le 0 -and $RequestedProfile -ne 'default') {
            $plan.primary_budget_percent = 0.0
            $plan.decision = 'blocked-insufficient-budget'
            $plan.decision_reason = 'Quota observation 已過期且保留門檻後沒有可用預算，等待 fresh evidence 或 primary reset。'
            return $plan
        }
        $plan.primary_budget_percent = $remainingBudget
        $plan.estimate_percent = $null
        $plan.estimate_source = 'bounded-single-unit'
        $plan.selected_units = @($Units | Select-Object -First 1)
        $plan.deferred_units = @($Units | Select-Object -Skip 1)
        $plan.stop_after_selected_units = $true
        $plan.decision = if ($plan.deferred_units.Count -eq 0) { 'full' } else { 'scoped' }
        $plan.decision_reason = 'Quota observation 已過期，保留 last observed 並採單一 declared unit 的保守範圍。'
        return $plan
    }

    if ($null -eq $estimate) {
        if ($TaskType -eq 'advisor-consult') {
            if ($quotaFreshness -eq 'fresh') {
                $estimate = Get-ConservativeEstimate -TaskType $TaskType
                if ($null -ne $estimate) {
                    $estimate = [double]$estimate
                    $estimateSource = 'conservative-default'
                    $plan.estimate_percent = $estimate
                    $plan.estimate_source = $estimateSource
                }
            }
            if ($null -eq $estimate) {
                $plan.decision_reason = 'advisor-consult 找不到同分組 eligible 校準樣本，也沒有 task type 保守量級。'
            }
        }
        else {
            if ($remainingBudget -le 0 -and $RequestedProfile -ne 'default') {
                $plan.primary_budget_percent = 0.0
                $plan.decision = 'blocked-insufficient-budget'
                $plan.decision_reason = '額度低於目標檔位門檻，保留門檻後沒有可用預算，保留阻擋結果。'
                return $plan
            }
            $plan.primary_budget_percent = $remainingBudget
            $plan.estimate_source = 'bounded-single-unit'
            $plan.selected_units = @($Units | Select-Object -First 1)
            $plan.deferred_units = @($Units | Select-Object -Skip 1)
            $plan.stop_after_selected_units = $true
            $plan.decision = if ($plan.deferred_units.Count -eq 0) { 'full' } else { 'scoped' }
            $plan.decision_reason = '額度低於目標檔位門檻且沒有 eligible calibration sample，固定只選第一個 declared unit。'
        }
        if ($null -eq $estimate) {
            return $plan
        }
    }

    $unitEstimate = [double]$estimate
    if ($TaskType -eq 'advisor-consult') {
        $unitEstimate = [double]$estimate / [double]$Units.Count
        $plan.advisor_unit_estimate_percent = $unitEstimate
    }
    $hardLimit = if ($TaskType -eq 'advisor-consult') { [double]$estimate * 1.25 } else { [double]::PositiveInfinity }
    $budget = if ($null -eq $RequestedBudgetPercent) { $remainingBudget } else { [double]$RequestedBudgetPercent }
    if ($TaskType -eq 'advisor-consult') {
        $activationModeValue = if ($null -eq $ActivationDecision) { 'automatic-quota' } else { [string](Get-OptionalObjectProperty -Object $ActivationDecision -Name 'activationMode') }
        if ($activationModeValue -eq 'user-authorized') {
            $budget = $remaining
        }
        else {
            $budget = [math]::Min($hardLimit, $remainingBudget)
        }
    }
    else {
        $budget = [math]::Min($budget, $remainingBudget)
    }
    $plan.primary_budget_percent = $budget

    $allowMinimumUnitOverBudget = ($RequestedProfile -eq 'default') -or
        ($TaskType -eq 'advisor-consult' -and $null -ne $ActivationDecision -and [bool](Get-OptionalObjectProperty -Object $ActivationDecision -Name 'granted'))
    if ($budget -le 0 -and -not $allowMinimumUnitOverBudget) {
        $plan.decision = 'blocked-insufficient-budget'
        $plan.decision_reason = if ($TaskType -eq 'advisor-consult') {
            'AdvisorAuthorizationRequired：advisor 未獲得啟用授權，未建立可執行 ScopePlan。'
        }
        else {
            'primary 預估保留門檻後沒有可用預算，保留阻擋結果。'
        }
        return $plan
    }

    $selected = New-Object System.Collections.Generic.List[string]
    $consumed = 0.0
    foreach ($unit in $Units) {
        if ($consumed + $unitEstimate -le $budget -or ($selected.Count -eq 0 -and $allowMinimumUnitOverBudget)) {
            $selected.Add($unit)
            $consumed += $unitEstimate
        }
        else {
            break
        }
    }
    $plan.selected_units = @($selected.ToArray())
    $plan.deferred_units = @($Units | Where-Object { $plan.selected_units -notcontains $_ })
    if ($plan.selected_units.Count -gt 0 -and $consumed -gt $budget -and $TaskType -eq 'advisor-consult') {
        $plan.minimum_unit_over_budget = $true
    }
    if ($plan.deferred_units.Count -gt 0 -or $plan.minimum_unit_over_budget) {
        $plan.stop_after_selected_units = $true
    }
    if ($plan.selected_units.Count -eq 0) {
        $plan.decision = 'blocked-insufficient-budget'
        $plan.decision_reason = if ($TaskType -eq 'advisor-consult') {
            'AdvisorAuthorizationRequired：advisor 未獲得啟用授權，未選取問題單位。'
        }
        else {
            '第一個最小單位超出可用預算，保留阻擋結果。'
        }
    }
    elseif ($plan.selected_units.Count -eq $Units.Count) {
        $plan.decision = 'full'
        $plan.decision_reason = '完整單位清單可容納於保留門檻後的有效預算。'
    }
    else {
        $plan.decision = 'scoped'
        $plan.decision_reason = '依宣告順序取可容納的最長前綴，延後未選單位。'
    }
    if ($TaskType -eq 'advisor-consult') {
        $plan.advisor_hard_limit_percent = $hardLimit
        $plan.advisor_unit_estimate_percent = $unitEstimate
    }
    return $plan
}

function New-DispatchPrompt {
    param(
        [Parameter(Mandatory)]
        [string]$PromptPath,

        [Parameter(Mandatory)]
        [string]$HistoryRoot,

        [Parameter(Mandatory)]
        [string]$Timestamp,

        [string[]]$Directive,

        [string]$OutputPath
    )

    $targetPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        if ($null -eq $Directive -or $Directive.Count -eq 0) {
            return $PromptPath
        }
        Join-Path -Path $HistoryRoot -ChildPath ('codex-prompt-' + $Timestamp + '.md')
    }
    else {
        Resolve-AbsolutePath -Path $OutputPath
    }

    $promptContent = Read-DispatchUtf8Text -Path $PromptPath
    if ($null -ne $Directive -and $Directive.Count -gt 0) {
        $suffix = "`n`n" + ($Directive -join "`n`n") + "`n"
        $promptContent = $promptContent + $suffix
    }

    $parent = Split-Path -Parent $targetPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $lock = $null
    $temporaryPath = $null
    try {
        $lock = Open-DispatchResultLock -ResolvedPath $targetPath
        if (Test-Path -LiteralPath $targetPath) {
            $collision = New-Object System.InvalidOperationException(('PromptTransferCollision：衍生 prompt 目標已存在，拒絕覆寫：' + $targetPath))
            $collision.Data['errorCode'] = 'PromptTransferCollision'
            $collision.Data['path'] = $targetPath
            throw $collision
        }
        $temporaryPath = Join-Path -Path $parent -ChildPath ([guid]::NewGuid().ToString('D') + '.prompt.tmp')
        Write-Utf8NoBom -Path $temporaryPath -Content $promptContent
        [System.IO.File]::Move((ConvertTo-FileSystemApiPath -Path $temporaryPath), (ConvertTo-FileSystemApiPath -Path $targetPath))
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

    return $targetPath
}

function Copy-DispatchPromptToExecutionHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PromptPath,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$HistoryRoot,

        [Parameter(Mandatory)]
        [string]$Timestamp
    )

    $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
    $executionRootPath = Resolve-AbsolutePath -Path $ExecutionRoot
    $sourcePath = Resolve-AbsolutePath -Path $PromptPath
    if (-not (Test-PathWithinRoot -Path $sourcePath -Root $sourceRootPath) -and -not (Test-PathWithinRoot -Path $sourcePath -Root $executionRootPath)) {
        $exception = New-Object System.InvalidOperationException(('PromptSourceBoundary：Prompt 必須位於 sourceRoot 或 executionRoot 內；received=' + $sourcePath + '; sourceRoot=' + $sourceRootPath + '; executionRoot=' + $executionRootPath))
        $exception.Data['errorCode'] = 'PromptSourceBoundary'
        $exception.Data['receivedPath'] = $sourcePath
        $exception.Data['sourceRoot'] = $sourceRootPath
        $exception.Data['executionRoot'] = $executionRootPath
        throw $exception
    }
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        $exception = New-Object System.InvalidOperationException(('PromptSourceMissing：找不到 sourceRoot 內的 Prompt：' + $sourcePath))
        $exception.Data['errorCode'] = 'PromptSourceMissing'
        $exception.Data['path'] = $sourcePath
        throw $exception
    }

    $historyPath = Resolve-AbsolutePath -Path $HistoryRoot
    $destinationPath = Join-Path -Path $historyPath -ChildPath ('codex-prompt-source-' + $Timestamp + '.md')
    $destinationPath = Resolve-DispatchOutputPath -CandidatePath $destinationPath -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @()
    $sourceApiPath = ConvertTo-FileSystemApiPath -Path $sourcePath
    $destinationApiPath = ConvertTo-FileSystemApiPath -Path $destinationPath
    $sourceBytes = [System.IO.File]::ReadAllBytes($sourceApiPath)
    $sourceSha256 = Get-DispatchByteArraySha256 -Bytes $sourceBytes
    $parent = Split-Path -Parent $destinationPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $lock = $null
    $temporaryPath = $null
    try {
        $lock = Open-DispatchResultLock -ResolvedPath $destinationPath
        if (Test-Path -LiteralPath $destinationPath) {
            $collision = New-Object System.InvalidOperationException(('PromptTransferCollision：Prompt 搬移目標已存在，拒絕覆寫：' + $destinationPath))
            $collision.Data['errorCode'] = 'PromptTransferCollision'
            $collision.Data['path'] = $destinationPath
            throw $collision
        }
        $temporaryPath = Join-Path -Path $parent -ChildPath ([guid]::NewGuid().ToString('D') + '.prompt.tmp')
        [System.IO.File]::WriteAllBytes((ConvertTo-FileSystemApiPath -Path $temporaryPath), $sourceBytes)
        $temporarySha256 = Get-DispatchByteArraySha256 -Bytes ([System.IO.File]::ReadAllBytes((ConvertTo-FileSystemApiPath -Path $temporaryPath)))
        if (-not [string]::Equals($temporarySha256, $sourceSha256, [StringComparison]::OrdinalIgnoreCase)) {
            $exception = New-Object System.InvalidOperationException(('PromptTransferHashMismatch：暫存 Prompt SHA-256 不一致；path=' + $sourcePath))
            $exception.Data['errorCode'] = 'PromptTransferHashMismatch'
            throw $exception
        }
        $sourceSha256AfterRead = Get-FileSha256 -Path $sourcePath
        if (-not [string]::Equals($sourceSha256AfterRead, $sourceSha256, [StringComparison]::OrdinalIgnoreCase)) {
            $exception = New-Object System.InvalidOperationException(('PromptTransferSourceChanged：Prompt 在搬移期間變更；path=' + $sourcePath))
            $exception.Data['errorCode'] = 'PromptTransferSourceChanged'
            throw $exception
        }
        [System.IO.File]::Move((ConvertTo-FileSystemApiPath -Path $temporaryPath), $destinationApiPath)
        $destinationSha256 = Get-FileSha256 -Path $destinationPath
        if (-not [string]::Equals($destinationSha256, $sourceSha256, [StringComparison]::OrdinalIgnoreCase)) {
            $exception = New-Object System.InvalidOperationException(('PromptTransferHashMismatch：搬移後 Prompt SHA-256 不一致；path=' + $destinationPath))
            $exception.Data['errorCode'] = 'PromptTransferHashMismatch'
            throw $exception
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
        SourcePath = $sourcePath
        Path = $destinationPath
        SourceSha256 = $sourceSha256
        DestinationSha256 = $destinationSha256
    }
}

function Read-DispatchUtf8Text {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
    $resolvedPath = Resolve-AbsolutePath -Path $Path
    $primaryReadError = $null
    $contentBytes = $null
    try {
        $contentBytes = [System.IO.File]::ReadAllBytes((ConvertTo-FileSystemApiPath -Path $resolvedPath))
    }
    catch {
        $primaryReadError = $_.Exception
        try {
            $contentBytes = [System.IO.File]::ReadAllBytes($resolvedPath)
        }
        catch {
            try {
                $content = [string](Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8)
                if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) {
                    return $content.Substring(1)
                }
                return $content
            }
            catch {
                throw $primaryReadError
            }
        }
    }
    $content = $encoding.GetString($contentBytes)
    if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) {
        return $content.Substring(1)
    }
    return $content
}

function Assert-AdvisorContract {
    param(
        [Parameter(Mandatory)]
        [string]$RequestedProfile,

        [Parameter(Mandatory)]
        [string]$TaskType,

        [Parameter(Mandatory)]
        [string]$DispatchKind,

        [Parameter(Mandatory)]
        [string]$WriteMode
    )

    if ($RequestedProfile -eq 'advisor' -and $TaskType -ne 'advisor-consult') {
        throw 'AdvisorImplementationProfileRejected：Profile=advisor 只允許 TaskType=advisor-consult。'
    }
    if ($RequestedProfile -eq 'advisor' -and $DispatchKind -eq 'workflow') {
        throw 'AdvisorImplementationProfileRejected：Profile=advisor 不允許 workflow 派遣。'
    }
    if ($RequestedProfile -eq 'advisor' -and $WriteMode -ne 'readonly') {
        throw 'AdvisorImplementationProfileRejected：Profile=advisor 必須使用 readonly 派遣。'
    }
    if ($TaskType -eq 'advisor-consult' -and $RequestedProfile -ne 'advisor') {
        throw 'AdvisorProfileRequired：TaskType=advisor-consult 必須使用 Profile=advisor。'
    }
}

function New-QuotaSnapshotPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HistoryRoot,

        [Parameter(Mandatory)]
        [ValidateSet('before', 'after', 'source-refresh')]
        [string]$Purpose,

        [AllowEmptyString()]
        [string]$DispatchSlug
    )

    $timestamp = [datetime]::UtcNow.ToString('yyyyMMdd_HHmmss_fff')
    $guidValue = [guid]::NewGuid().ToString('N')
    if ($Purpose -eq 'source-refresh') {
        if ([string]::IsNullOrWhiteSpace($DispatchSlug)) {
            throw 'source-refresh quota snapshot path 必須提供 DispatchSlug。'
        }
        $fileName = 'quota-source-refresh-' + $DispatchSlug + '-' + $timestamp + '-' + $guidValue + '.json'
    }
    else {
        $fileName = 'quota-' + $Purpose + '-' + $timestamp + '-' + $guidValue + '.json'
    }

    return Join-Path -Path $HistoryRoot -ChildPath $fileName
}

function Get-OrCreateQuotaSnapshot {
    param(
        [string]$Path,

        [string]$SnapshotPath,

        [string]$CodexHome,

        [Parameter(Mandatory)]
        [string]$HistoryRoot,

        [Parameter(Mandatory)]
        [string]$Purpose,

        [switch]$Required
    )

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $resolvedPath = Resolve-AbsolutePath -Path $Path
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
            throw "QuotaSnapshotValidationRejected：QuotaBeforePath 不存在或不是檔案：$resolvedPath"
        }

        try {
            $null = Read-QuotaSnapshot -Path $resolvedPath
        }
        catch {
            throw "QuotaSnapshotValidationRejected：QuotaBeforePath 不符合額度快照契約：$resolvedPath；$($_.Exception.Message)"
        }
    }

    $configuredHome = $CodexHome
    if ([string]::IsNullOrWhiteSpace($configuredHome)) {
        $configuredHome = $env:CODEX_HOME
    }
    if ([string]::IsNullOrWhiteSpace($configuredHome)) {
        $configuredHome = Resolve-CodexHomeForEvidence -CodexHomePath $null
    }
    if ([string]::IsNullOrWhiteSpace($configuredHome)) {
        if ($Required) {
            throw "$Purpose 需要 quota snapshot，無法解析有效 CodexHome。"
        }
        return $null
    }

    $snapshotPath = if ([string]::IsNullOrWhiteSpace($SnapshotPath)) {
        New-QuotaSnapshotPath -HistoryRoot $HistoryRoot -Purpose $Purpose
    }
    else {
        Resolve-AbsolutePath -Path $SnapshotPath
    }
    if (-not [string]::IsNullOrWhiteSpace($Path) -and [string]::Equals((Resolve-AbsolutePath -Path $Path), $snapshotPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'QuotaSnapshotPathReuseRejected：新 quota snapshot 不可沿用呼叫端提供的 QuotaBeforePath。'
    }
    return Set-QuotaSnapshotFromCodex -Path $snapshotPath -CodexHome $configuredHome
}

function Set-QuotaSnapshotFromCodex {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$CodexHome
    )

    $resolvedPath = Resolve-AbsolutePath -Path $Path
    $configuredHome = $CodexHome
    if ([string]::IsNullOrWhiteSpace($configuredHome)) {
        $configuredHome = $env:CODEX_HOME
    }
    if ([string]::IsNullOrWhiteSpace($configuredHome)) {
        $configuredHome = Resolve-CodexHomeForEvidence -CodexHomePath $null
    }
    if ([string]::IsNullOrWhiteSpace($configuredHome)) {
        throw 'quota snapshot 更新需要有效的 CodexHome。'
    }

    $parent = Split-Path -Parent $resolvedPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $quotaScript = Join-Path -Path $PSScriptRoot -ChildPath 'Get-CodexQuota.ps1'
    if (-not (Test-Path -LiteralPath $quotaScript -PathType Leaf)) {
        throw "找不到額度快照腳本：$quotaScript"
    }
    $quotaOutput = & $quotaScript -CodexHome $configuredHome -SnapshotPath $resolvedPath 2>&1
    $quotaExitCode = $LASTEXITCODE
    if ($quotaExitCode -ne 0 -or -not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        $details = ($quotaOutput | Out-String).Trim()
        throw "quota snapshot 更新失敗，exit code $quotaExitCode。$details"
    }
    $null = Read-QuotaSnapshot -Path $resolvedPath
    return $resolvedPath
}

function New-AdvisorAfterSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CallerPath,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$HistoryRoot,

        [string]$CodexHome
    )

    $callerPathValue = Resolve-AbsolutePath -Path $CallerPath
    if (-not (Test-PathWithinRoot -Path $callerPathValue -Root $ExecutionRoot)) {
        throw "advisor-consult QuotaAfterPath 必須位於 executionRoot 內：$callerPathValue"
    }
    if (-not (Test-Path -LiteralPath $callerPathValue -PathType Leaf)) {
        throw "QuotaAfterSnapshotValidationRejected：呼叫端 QuotaAfterPath 不存在或不是檔案：$callerPathValue"
    }
    try {
        $null = Read-QuotaSnapshot -Path $callerPathValue
    }
    catch {
        throw "QuotaAfterSnapshotValidationRejected：呼叫端 QuotaAfterPath 不符合額度快照契約：$callerPathValue；$($_.Exception.Message)"
    }

    $snapshotPathValue = New-QuotaSnapshotPath -HistoryRoot $HistoryRoot -Purpose 'after'
    if (-not (Test-PathWithinRoot -Path $snapshotPathValue -Root $ExecutionRoot)) {
        throw "QuotaAfterSnapshotPathRejected：新 after snapshot 超出 executionRoot：$snapshotPathValue"
    }
    $snapshotPathValue = Set-QuotaSnapshotFromCodex -Path $snapshotPathValue -CodexHome $CodexHome
    return [pscustomobject]@{
        Path   = $snapshotPathValue
        Sha256 = Get-FileSha256 -Path $snapshotPathValue
    }
}

function Update-AdvisorAfterSnapshotFromCodex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExpectedSha256,

        [string]$CodexHome
    )

    if ($ExpectedSha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'QuotaAfterSnapshotOwnershipInvalid：預期 SHA-256 格式無效。'
    }

    $pathValue = Resolve-AbsolutePath -Path $Path
    if (-not (Test-Path -LiteralPath $pathValue -PathType Leaf)) {
        throw "QuotaAfterSnapshotMissing：本次執行建立的 after snapshot 不存在：$pathValue"
    }
    $currentSha256 = Get-FileSha256 -Path $pathValue
    if (-not [string]::Equals($currentSha256, $ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "QuotaAfterSnapshotChanged：after snapshot 已被外部變更；path=$pathValue; expected_sha256=$ExpectedSha256; actual_sha256=$currentSha256"
    }

    $parentPath = Split-Path -Parent $pathValue
    $temporaryName = '.' + [System.IO.Path]::GetFileName($pathValue) + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $temporaryPath = Join-Path -Path $parentPath -ChildPath $temporaryName
    $backupName = '.' + [System.IO.Path]::GetFileName($pathValue) + '.' + [guid]::NewGuid().ToString('N') + '.bak'
    $backupPath = Join-Path -Path $parentPath -ChildPath $backupName
    try {
        $null = Set-QuotaSnapshotFromCodex -Path $temporaryPath -CodexHome $CodexHome
        $currentSha256 = Get-FileSha256 -Path $pathValue
        if (-not [string]::Equals($currentSha256, $ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "QuotaAfterSnapshotChanged：after snapshot 在更新期間被外部變更；path=$pathValue; expected_sha256=$ExpectedSha256; actual_sha256=$currentSha256"
        }
        [System.IO.File]::Replace($temporaryPath, $pathValue, $backupPath)
        [System.IO.File]::Delete($backupPath)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            [System.IO.File]::Delete($temporaryPath)
        }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            [System.IO.File]::Delete($backupPath)
        }
    }

    return [pscustomobject]@{
        Path   = $pathValue
        Sha256 = Get-FileSha256 -Path $pathValue
    }
}

function Get-AdvisorConsultReportPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug
    )

    $fullPath = Resolve-AbsolutePath -Path $Path
    $reportRoot = Join-Path -Path (Resolve-AbsolutePath -Path $ExecutionRoot) -ChildPath ('.local\ai-sessions\report\' + $LineSlug)
    if (-not (Test-PathWithinRoot -Path $fullPath -Root $reportRoot)) {
        throw "AdvisorConsultReportPath 必須位於同線 report root 內：$fullPath"
    }
    $expectedName = 'advisor-consult-' + $DispatchSlug + '.md'
    if (-not [string]::Equals([System.IO.Path]::GetFileName($fullPath), $expectedName, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "AdvisorConsultReportPath 檔名必須為 $expectedName：$fullPath"
    }
    return $fullPath
}

function Get-AdvisorEvidenceQuestionUnits {
    param(
        [Parameter(Mandatory)]
        [string]$QuestionSection
    )

    $questionMatches = [regex]::Matches($QuestionSection, '(?m)^\s*(?<id>question-[A-Za-z0-9][A-Za-z0-9_-]*):\s*(?<value>.*?)\s*$')
    if ($questionMatches.Count -eq 0) {
        throw 'EvidencePackInvalid：evidence pack 待答問題必須至少包含一個 question-<id>。'
    }
    $questionUnits = New-Object System.Collections.Generic.List[string]
    $questionIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($questionMatch in $questionMatches) {
        $questionId = $questionMatch.Groups['id'].Value.Trim()
        $questionValue = $questionMatch.Groups['value'].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($questionValue)) {
            throw "EvidencePackInvalid：問題 $questionId 不可為空。"
        }
        if (-not $questionIds.Add($questionId)) {
            throw "EvidencePackInvalid：問題 ID 不可重複：$questionId"
        }
        $questionUnits.Add($questionId)
    }
    return @($questionUnits.ToArray())
}

function Test-AdvisorEvidencePack {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug
    )

    $fullPath = Resolve-AbsolutePath -Path $Path
    if (-not (Test-PathWithinRoot -Path $fullPath -Root $ExecutionRoot)) {
        throw "evidence pack 必須位於 executionRoot 內：$fullPath"
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "找不到 evidence pack：$fullPath"
    }
    $content = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "evidence pack 不可為空：$fullPath"
    }
    foreach ($requiredPattern in @(
            '(?m)^schema:\s*advisor-consult\.evidence\.v1\s*$',
            '(?m)^line-slug:\s*' + [regex]::Escape($LineSlug) + '\s*$',
            '(?m)^dispatch-slug:\s*' + [regex]::Escape($DispatchSlug) + '\s*$',
            '(?m)^##\s+目標段落\s*$',
            '(?m)^##\s+已知結論\s*$',
            '(?m)^##\s+待答問題\s*$',
            '(?m)^##\s+可能反證\s*$',
            '(?m)^##\s+邊界\s*$',
            '(?m)^-\s+allowed-input:\s*this evidence pack only',
            '(?m)^-\s+forbidden-action:\s*source exploration, repository scan, file mutation, external dispatch'
        )) {
        if (-not [regex]::IsMatch($content, $requiredPattern)) {
            throw "evidence pack 缺少必要內容：$requiredPattern"
        }
    }

    $sectionBodies = [ordered]@{}
    foreach ($sectionName in @('目標段落', '已知結論', '待答問題', '可能反證', '邊界')) {
        $sectionMatch = [regex]::Match($content, '(?ms)^##\s+' + [regex]::Escape($sectionName) + '\s*\r?\n(?<body>.*?)(?=^##\s|\z)')
        if (-not $sectionMatch.Success -or [string]::IsNullOrWhiteSpace($sectionMatch.Groups['body'].Value)) {
            throw "evidence pack 必要區段不可為空：$sectionName"
        }
        $sectionBodies[$sectionName] = $sectionMatch.Groups['body'].Value.Trim()
    }
    if ($sectionBodies['目標段落'] -notmatch '(?m)^\s*source:\s*\S+' -or
        $sectionBodies['目標段落'] -notmatch '(?m)^\s*excerpt:\s*\S+') {
        throw 'evidence pack 目標段落必須包含非空 source 與 excerpt。'
    }
    $questionUnits = @(Get-AdvisorEvidenceQuestionUnits -QuestionSection $sectionBodies['待答問題'])

    $requiredOutputMatches = [regex]::Matches($sectionBodies['待答問題'], '(?m)^[ \t]*required-output:[ \t]*(?<value>[^\r\n]*?)[ \t]*\r?$')
    if ($requiredOutputMatches.Count -ne 1) {
        throw 'C25 EvidencePackRequiredOutputInvalid：required-output 必須恰好宣告一次。'
    }
    $questionSectionLines = @($sectionBodies['待答問題'] -split '\r?\n')
    for ($lineIndex = 0; $lineIndex -lt $questionSectionLines.Count; $lineIndex++) {
        if ($questionSectionLines[$lineIndex] -notmatch '^\s*required-output:\s*') {
            continue
        }
        if ($lineIndex + 1 -ge $questionSectionLines.Count) {
            continue
        }
        $nextLine = $questionSectionLines[$lineIndex + 1]
        if ([string]::IsNullOrWhiteSpace($nextLine) -or
            $nextLine -match '^\s*question-[A-Za-z0-9][A-Za-z0-9_-]*:\s*' -or
            $nextLine -match '^\s*output-rules:\s*' -or
            $nextLine -match '^\s*##\s+') {
            continue
        }
        throw 'C25 EvidencePackRequiredOutputInvalid：required-output 宣告後不可出現未標記的續行。'
    }
    $requiredOutputValue = $requiredOutputMatches[0].Groups['value'].Value.Trim()
    $requiredOutput = @($requiredOutputValue.Split(';') | ForEach-Object { $_.Trim() })
    if ([string]::IsNullOrWhiteSpace($requiredOutputValue) -or $requiredOutput.Count -eq 0 -or @($requiredOutput | Where-Object { $_ -notmatch '^#{1,6}[ \t]+\S' }).Count -gt 0) {
        throw 'C25 EvidencePackRequiredOutputInvalid：required-output 必須由半形分號分隔的非空 Markdown heading 組成。'
    }
    $requiredOutputSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($heading in $requiredOutput) {
        if (-not $requiredOutputSet.Add($heading)) {
            throw "C25 EvidencePackRequiredOutputInvalid：required-output 不可重複：$heading"
        }
    }
    if ($sectionBodies['待答問題'] -notmatch '(?m)^\s*output-rules:\s*\S+') {
        throw 'C25 EvidencePackRequiredOutputInvalid：待答問題必須包含非空 output-rules。'
    }

    $hash = Get-FileSha256 -Path $fullPath
    $sandboxRoot = Join-Path -Path $ExecutionRoot -ChildPath ('.local\ai-sessions\scratch\advisor-consult\' + $DispatchSlug)
    $sandboxPath = Join-Path -Path $sandboxRoot -ChildPath 'evidence-pack.md'
    if (-not [string]::Equals($fullPath, (Resolve-AbsolutePath -Path $sandboxPath), [System.StringComparison]::OrdinalIgnoreCase)) {
        New-Item -ItemType Directory -Path $sandboxRoot -Force | Out-Null
        Copy-Item -LiteralPath $fullPath -Destination $sandboxPath -Force
    }

    return [ordered]@{
        path        = $fullPath
        sandboxPath = Resolve-AbsolutePath -Path $sandboxPath
        sha256      = $hash
        length      = [int64](Get-Item -LiteralPath $fullPath).Length
        content     = $content
        required_output = $requiredOutput
        requiredOutput = $requiredOutput
        question_units  = @($questionUnits)
    }
}

function Get-ThreadIdsFromEventStream {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $ids = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }
        if ((Get-OptionalObjectProperty -Object $event -Name 'type') -ne 'thread.started') {
            continue
        }
        $threadId = Get-OptionalObjectProperty -Object $event -Name 'thread_id'
        if ($threadId -is [string] -and -not [string]::IsNullOrWhiteSpace($threadId)) {
            $parsedThreadId = [guid]::Empty
            if (-not [guid]::TryParse($threadId, [ref]$parsedThreadId)) {
                throw "事件流 thread.started.thread_id 必須為 UUID：$threadId"
            }
            $ids.Add($threadId)
        }
    }
    return @($ids.ToArray())
}

function Set-ThreadIdFromEventStream {
    param(
        [Parameter(Mandatory)]
        [string]$EventPath,

        [Parameter(Mandatory)]
        [string]$ThreadPath,

        [switch]$RequireThreadId
    )

    $threadPathValue = Resolve-AbsolutePath -Path $ThreadPath
    $eventIds = @(Get-ThreadIdsFromEventStream -Path $EventPath)
    $existingId = ''
    if (Test-Path -LiteralPath $threadPathValue -PathType Leaf) {
        $existingId = (Get-Content -LiteralPath $threadPathValue -Raw -Encoding UTF8).Trim()
        if (-not [string]::IsNullOrWhiteSpace($existingId)) {
            $parsedExistingId = [guid]::Empty
            if (-not [guid]::TryParse($existingId, [ref]$parsedExistingId)) {
                throw "既有 thread id 檔案內容必須為 UUID：$existingId"
            }
        }
    }
    $distinctIds = @($eventIds | Sort-Object -Unique)
    if ($distinctIds.Count -gt 1) {
        throw "事件流包含不同 thread id：$($distinctIds -join ',')"
    }
    if ($distinctIds.Count -eq 0) {
        if ($RequireThreadId) {
            throw 'thread.started.thread_id 尚未取得。'
        }
        return [ordered]@{
            threadId         = $existingId
            existingThreadId = $existingId
            relayed          = $false
            ready            = $false
            eventObserved    = $false
            source           = 'existing-or-not-ready'
        }
    }
    $eventId = $distinctIds[0]
    if (-not [string]::IsNullOrWhiteSpace($existingId) -and $existingId -ne $eventId) {
        throw "thread id 衝突：既有=$existingId；事件流=$eventId"
    }
    if ([string]::IsNullOrWhiteSpace($existingId)) {
        Write-Utf8NoBom -Path $threadPathValue -Content ($eventId + "`n")
        return [ordered]@{
            threadId         = $eventId
            existingThreadId = ''
            relayed          = $true
            ready            = $true
            eventObserved    = $true
            source           = 'thread.started'
        }
    }
    return [ordered]@{
        threadId         = $existingId
        existingThreadId = $existingId
        relayed          = $false
        ready            = $true
        eventObserved    = $true
        source           = 'existing'
    }
}

function Add-ThreadRelayDiagnostics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Relay,

        [Parameter(Mandatory)]
        [string]$EventPath,

        [Parameter(Mandatory)]
        [string]$ThreadPath,

        [Parameter(Mandatory)]
        [DateTimeOffset]$StartedAt,

        [Parameter(Mandatory)]
        [DateTimeOffset]$DeadlineAt,

        [Parameter(Mandatory)]
        [int]$AttemptCount,

        [Parameter(Mandatory)]
        [bool]$TerminalEventObserved
    )

    $result = [ordered]@{}
    if ($Relay -is [System.Collections.IDictionary]) {
        foreach ($key in $Relay.Keys) {
            $result[[string]$key] = $Relay[$key]
        }
    }
    elseif ($null -ne $Relay) {
        foreach ($property in $Relay.PSObject.Properties) {
            $result[[string]$property.Name] = $property.Value
        }
    }
    $eventBytes = 0L
    if (Test-Path -LiteralPath $EventPath -PathType Leaf) {
        $eventBytes = [int64](Get-Item -LiteralPath $EventPath).Length
    }
    $observedAt = if ($eventBytes -gt 0) { [DateTimeOffset]::UtcNow.ToString('o') } else { $null }
    $result['relay_diagnostics'] = [ordered]@{
        launch_started_at_utc = $StartedAt.ToString('o')
        deadline_at_utc = $DeadlineAt.ToString('o')
        observed_at_utc = $observedAt
        event_path = $EventPath
        thread_path = $ThreadPath
        event_bytes = $eventBytes
        attempt_count = $AttemptCount
        ready = [bool](Get-DispatchJsonProperty -Object $Relay -Name 'ready')
        timed_out = [bool](Get-DispatchJsonProperty -Object $Relay -Name 'timedOut')
        terminal_event_observed = $TerminalEventObserved
    }
    return $result
}

function Wait-ForThreadRelay {
    param(
        [Parameter(Mandatory)]
        [string]$EventPath,

        [Parameter(Mandatory)]
        [string]$ThreadPath,

        [int]$TimeoutSeconds = 5
    )

    $startedAt = [DateTimeOffset]::UtcNow
    $deadline = $startedAt.AddSeconds($TimeoutSeconds)
    $attemptCount = 0
    $terminalEventObserved = $false
    do {
        $attemptCount++
        $relay = Set-ThreadIdFromEventStream -EventPath $EventPath -ThreadPath $ThreadPath
        if ([bool](Get-DispatchJsonProperty -Object $relay -Name 'ready')) {
            return Add-ThreadRelayDiagnostics -Relay $relay -EventPath $EventPath -ThreadPath $ThreadPath -StartedAt $startedAt -DeadlineAt $deadline -AttemptCount $attemptCount -TerminalEventObserved $terminalEventObserved
        }
        if (Test-Path -LiteralPath $EventPath -PathType Leaf) {
            $eventContent = Get-Content -LiteralPath $EventPath -Raw -Encoding UTF8
            if ($eventContent -match '(?m)"type"\s*:\s*"turn\.(completed|failed)"') {
                $terminalEventObserved = $true
                break
            }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    $attemptCount++
    $finalRelay = Set-ThreadIdFromEventStream -EventPath $EventPath -ThreadPath $ThreadPath
    if ([bool](Get-DispatchJsonProperty -Object $finalRelay -Name 'ready')) {
        return Add-ThreadRelayDiagnostics -Relay $finalRelay -EventPath $EventPath -ThreadPath $ThreadPath -StartedAt $startedAt -DeadlineAt $deadline -AttemptCount $attemptCount -TerminalEventObserved $terminalEventObserved
    }
    $notReady = [ordered]@{
        threadId         = ''
        existingThreadId = [string](Get-DispatchJsonProperty -Object $finalRelay -Name 'existingThreadId')
        relayed          = $false
        ready            = $false
        eventObserved    = $false
        source           = 'not-ready'
        timedOut         = $true
        timeoutSeconds   = $TimeoutSeconds
    }
    return Add-ThreadRelayDiagnostics -Relay $notReady -EventPath $EventPath -ThreadPath $ThreadPath -StartedAt $startedAt -DeadlineAt $deadline -AttemptCount $attemptCount -TerminalEventObserved $terminalEventObserved
}

function Read-ScopePlanFile {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    $fullPath = Resolve-AbsolutePath -Path $Path
    if (-not [System.IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $fullPath))) {
        throw "找不到 ScopePlan：$fullPath"
    }
    try {
        $plan = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $fullPath)
    }
    catch {
        throw "ScopePlan 格式錯誤：$fullPath；$($_.Exception.Message)"
    }
    foreach ($requiredName in @('dispatch_slug', 'dispatch_kind', 'task_type', 'requested_profile', 'session_mode', 'primary_remaining_percent', 'primary_reserve_percent', 'primary_budget_percent', 'estimate_percent', 'estimate_source', 'unit_kind', 'requested_units', 'selected_units', 'deferred_units', 'decision', 'decision_reason')) {
        if ($null -eq $plan.PSObject.Properties[$requiredName]) {
            throw "ScopePlan 缺少欄位：$fullPath；$requiredName"
        }
    }
    if (-not (Test-ScopePlanCompleteness -ScopePlan $plan)) {
        throw "ScopePlan 欄位不完整或單位清單不一致：$fullPath"
    }
    return $plan
}

function Test-StringArrayEqual {
    param(
        [AllowNull()]
        [object]$Left,

        [AllowNull()]
        [object]$Right
    )

    $leftItems = @($Left | ForEach-Object { [string]$_ })
    $rightItems = @($Right | ForEach-Object { [string]$_ })
    if ($leftItems.Count -ne $rightItems.Count) {
        return $false
    }
    for ($index = 0; $index -lt $leftItems.Count; $index++) {
        if (-not [string]::Equals($leftItems[$index], $rightItems[$index], [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    return $true
}


function Get-ScopePlanFingerprint {
    param(
        [Parameter(Mandatory)]
        [psobject]$ScopePlan
    )

    $normalizedScopePlan = $ScopePlan | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $fingerprintInput = [ordered]@{}
    foreach ($property in @($normalizedScopePlan.PSObject.Properties | Sort-Object -Property Name)) {
        if ($property.Name -ne 'scope_plan_fingerprint') {
            if ($property.Name -in @('requested_units', 'selected_units', 'deferred_units')) {
                $fingerprintInput[$property.Name] = @($property.Value | ForEach-Object { [string]$_ })
            }
            else {
                $value = $property.Value
                if ($null -ne $value -and $value -is [ValueType] -and $value -isnot [bool]) {
                    try {
                        $value = ([double]$value).ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    catch {
                        $value = $property.Value
                    }
                }
                $fingerprintInput[$property.Name] = $value
            }
        }
    }
    $json = ConvertTo-Json -InputObject $fingerprintInput -Depth 20 -Compress
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-FileSha256 {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolvedPath = Resolve-AbsolutePath -Path $Path
    $fileApiPath = ConvertTo-FileSystemApiPath -Path $resolvedPath
    if (-not [System.IO.File]::Exists($fileApiPath)) {
        throw "找不到要計算 SHA-256 的檔案：$resolvedPath"
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($fileApiPath)
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-JsonSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value
    )

    $json = ConvertTo-Json -InputObject $Value -Depth 30 -Compress
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Compare-DispatchStringArrays {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]]$Left,

        [AllowEmptyCollection()]
        [string[]]$Right,

        [switch]$OrdinalIgnoreCase
    )

    $leftValues = @($Left)
    $rightValues = @($Right)
    if ($leftValues.Count -ne $rightValues.Count) {
        return $false
    }
    $comparison = if ($OrdinalIgnoreCase) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    for ($index = 0; $index -lt $leftValues.Count; $index++) {
        if (-not [string]::Equals([string]$leftValues[$index], [string]$rightValues[$index], $comparison)) {
            return $false
        }
    }
    return $true
}

function New-ParentOptionsModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Profile,

        [Parameter(Mandatory)]
        [string]$Sandbox,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [AllowEmptyCollection()]
        [string[]]$AddDirectory,

        [bool]$Search,

        [AllowEmptyCollection()]
        [string[]]$CodexParentOption
    )

    $normalizedDirectories = New-Object 'System.Collections.Generic.List[string]'
    $directoryValues = if ($null -eq $AddDirectory) { @() } else { @($AddDirectory) }
    foreach ($directory in $directoryValues) {
        if ([string]::IsNullOrWhiteSpace($directory)) {
            throw 'parent_options.add_directory 不可包含空白項目。'
        }
        $normalizedDirectories.Add((Resolve-AbsolutePath -Path $directory))
    }

    $parentOptions = New-Object 'System.Collections.Generic.List[string]'
    $optionValues = if ($null -eq $CodexParentOption) { @() } else { @($CodexParentOption) }
    foreach ($option in $optionValues) {
        if ([string]::IsNullOrWhiteSpace($option)) {
            throw 'parent_options.codex_parent_option 不可包含空白項目。'
        }
        $parentOptions.Add([string]$option)
    }

    $model = [ordered]@{
        profile              = $Profile
        sandbox              = $Sandbox
        add_directory        = @($normalizedDirectories.ToArray())
        search               = [bool]$Search
        codex_parent_option  = @($parentOptions.ToArray())
        working_directory    = Resolve-AbsolutePath -Path $WorkingDirectory
    }
    $model.fingerprint = Get-JsonSha256 -Value $model
    return $model
}

function Compare-ParentOptions {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Current,

        [AllowNull()]
        [object]$Anchor
    )

    if ($null -eq $Anchor) {
        return [ordered]@{
            matches     = $false
            code        = 'ParentOptionsUnknown'
            differences = @('anchor.parent_options')
        }
    }
    if ($null -eq $Current) {
        return [ordered]@{
            matches     = $false
            code        = 'ParentOptionsUnknown'
            differences = @('current.parent_options')
        }
    }

    $differences = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @('profile', 'sandbox', 'search', 'working_directory')) {
        $currentValue = Get-DispatchJsonProperty -Object $Current -Name $name
        $anchorValue = Get-DispatchJsonProperty -Object $Anchor -Name $name
        $equal = if ($name -eq 'working_directory') {
            [string]::Equals([string]$currentValue, [string]$anchorValue, [System.StringComparison]::OrdinalIgnoreCase)
        }
        else {
            [string]::Equals([string]$currentValue, [string]$anchorValue, [System.StringComparison]::Ordinal)
        }
        if (-not $equal) {
            $differences.Add($name)
        }
    }
    $currentDirectories = @((Get-DispatchJsonProperty -Object $Current -Name 'add_directory'))
    $anchorDirectories = @((Get-DispatchJsonProperty -Object $Anchor -Name 'add_directory'))
    if (-not (Compare-DispatchStringArrays -Left $currentDirectories -Right $anchorDirectories -OrdinalIgnoreCase)) {
        $differences.Add('add_directory')
    }
    $currentOptions = @((Get-DispatchJsonProperty -Object $Current -Name 'codex_parent_option'))
    $anchorOptions = @((Get-DispatchJsonProperty -Object $Anchor -Name 'codex_parent_option'))
    if (-not (Compare-DispatchStringArrays -Left $currentOptions -Right $anchorOptions)) {
        $differences.Add('codex_parent_option')
    }
    $anchorFingerprint = [string](Get-DispatchJsonProperty -Object $Anchor -Name 'fingerprint')
    if ([string]::IsNullOrWhiteSpace($anchorFingerprint)) {
        $differences.Add('fingerprint')
    }
    return [ordered]@{
        matches     = $differences.Count -eq 0
        code        = if ($differences.Count -eq 0) { $null } else { 'ParentOptionsMismatch' }
        differences = @($differences.ToArray())
    }
}

function Resolve-ParentOptionsForStart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Profile,

        [bool]$ProfileProvided,

        [Parameter(Mandatory)]
        [string]$Sandbox,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [AllowEmptyCollection()]
        [string[]]$AddDirectory,

        [bool]$Search,

        [bool]$AddDirectoryProvided,

        [bool]$SearchProvided,

        [AllowEmptyCollection()]
        [string[]]$CodexParentOption,

        [bool]$CodexParentOptionProvided,

        [AllowNull()]
        [object]$Anchor
    )

    if ($null -eq $Anchor) {
        $model = New-ParentOptionsModel -Profile $Profile -Sandbox $Sandbox -WorkingDirectory $WorkingDirectory -AddDirectory $AddDirectory -Search $Search -CodexParentOption $CodexParentOption
        return [ordered]@{
            model = $model
            differences = @()
            code = $null
            restored = $false
        }
    }

    $anchorProfile = [string](Get-DispatchJsonProperty -Object $Anchor -Name 'profile')
    $anchorSandbox = [string](Get-DispatchJsonProperty -Object $Anchor -Name 'sandbox')
    $anchorWorkingDirectory = [string](Get-DispatchJsonProperty -Object $Anchor -Name 'working_directory')
    $anchorDirectories = @((Get-DispatchJsonProperty -Object $Anchor -Name 'add_directory'))
    $anchorSearch = [bool](Get-DispatchJsonProperty -Object $Anchor -Name 'search')
    $anchorOptions = @((Get-DispatchJsonProperty -Object $Anchor -Name 'codex_parent_option'))
    $differences = New-Object 'System.Collections.Generic.List[string]'

    $effectiveProfile = $anchorProfile
    if ($ProfileProvided) {
        if ($Profile -ne $anchorProfile) {
            $differences.Add('profile')
        }
        $effectiveProfile = $Profile
    }
    if ($Sandbox -ne $anchorSandbox) {
        $differences.Add('sandbox')
    }
    $resolvedWorkingDirectory = Resolve-AbsolutePath -Path $WorkingDirectory
    if (-not [string]::Equals($resolvedWorkingDirectory, $anchorWorkingDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        $differences.Add('working_directory')
    }

    $effectiveDirectories = $anchorDirectories
    if ($AddDirectoryProvided) {
        $currentDirectoriesModel = New-ParentOptionsModel -Profile $effectiveProfile -Sandbox $Sandbox -WorkingDirectory $WorkingDirectory -AddDirectory $AddDirectory -Search $Search -CodexParentOption @()
        $currentDirectories = @((Get-DispatchJsonProperty -Object $currentDirectoriesModel -Name 'add_directory'))
        if (-not (Compare-DispatchStringArrays -Left $currentDirectories -Right $anchorDirectories -OrdinalIgnoreCase)) {
            $differences.Add('add_directory')
        }
        $effectiveDirectories = $currentDirectories
    }

    $effectiveSearch = $anchorSearch
    if ($SearchProvided) {
        if ($Search -ne $anchorSearch) {
            $differences.Add('search')
        }
        $effectiveSearch = $Search
    }

    $effectiveParentOptions = $anchorOptions
    if ($CodexParentOptionProvided) {
        if (-not (Compare-DispatchStringArrays -Left $CodexParentOption -Right $anchorOptions)) {
            $differences.Add('codex_parent_option')
        }
        $effectiveParentOptions = @($CodexParentOption)
    }

    $model = New-ParentOptionsModel -Profile $effectiveProfile -Sandbox $Sandbox -WorkingDirectory $WorkingDirectory -AddDirectory $effectiveDirectories -Search $effectiveSearch -CodexParentOption $effectiveParentOptions
    return [ordered]@{
        model = $model
        differences = @($differences.ToArray())
        code = if ($differences.Count -eq 0) { $null } else { 'ParentOptionsMismatch' }
        restored = $true
    }
}

function New-UnknownDispatchEvidence {
    param(
        [Parameter(Mandatory)]
        [string]$Field,

        [Parameter(Mandatory)]
        [string]$Reason,

        [string]$Source = 'unknown',

        [string]$Path,

        [Nullable[int]]$Line,

        [string]$Sha256
    )

    return [ordered]@{
        value = $null
        status = 'unknown'
        source = if ([string]::IsNullOrWhiteSpace($Source)) { 'unknown' } else { $Source }
        field = $Field
        path = if ([string]::IsNullOrWhiteSpace($Path)) { $null } else { $Path }
        line = $Line
        reason = $Reason
        captured_at_utc = [datetime]::UtcNow.ToString('o')
        sha256 = if ([string]::IsNullOrWhiteSpace($Sha256)) { $null } else { $Sha256 }
    }
}

function New-ConfirmedDispatchEvidence {
    param(
        [Parameter(Mandatory)]
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Field,

        [string]$Path,

        [Nullable[int]]$Line,

        [string]$Sha256
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return New-UnknownDispatchEvidence -Field $Field -Reason '證據值為空。' -Source 'unknown' -Path $Path -Line $Line -Sha256 $Sha256
    }
    return [ordered]@{
        value = $Value
        status = 'confirmed'
        source = $Source
        field = $Field
        path = if ([string]::IsNullOrWhiteSpace($Path)) { $null } else { $Path }
        line = $Line
        reason = $null
        captured_at_utc = [datetime]::UtcNow.ToString('o')
        sha256 = if ([string]::IsNullOrWhiteSpace($Sha256)) { $null } else { $Sha256 }
    }
}

function ConvertTo-DispatchEvidence {
    param(
        [AllowNull()]
        [object]$Evidence,

        [Parameter(Mandatory)]
        [string]$Field,

        [string]$UnknownReason = '缺少證據。'
    )

    if ($null -eq $Evidence) {
        return New-UnknownDispatchEvidence -Field $Field -Reason $UnknownReason
    }
    $value = Get-DispatchJsonProperty -Object $Evidence -Name 'value'
    $status = Get-DispatchJsonProperty -Object $Evidence -Name 'status'
    if ($null -eq $value -or $null -eq $status) {
        return New-UnknownDispatchEvidence -Field $Field -Reason $UnknownReason
    }
    $value = [string]$value
    $status = [string]$status
    if ($status -ne 'confirmed' -or [string]::IsNullOrWhiteSpace($value)) {
        $reasonValue = Get-DispatchJsonProperty -Object $Evidence -Name 'reason'
        $reason = if ($null -ne $reasonValue -and -not [string]::IsNullOrWhiteSpace([string]$reasonValue)) { [string]$reasonValue } else { $UnknownReason }
        $sourceValue = Get-DispatchJsonProperty -Object $Evidence -Name 'source'
        $source = if ($null -ne $sourceValue) { [string]$sourceValue } else { 'unknown' }
        $pathValue = Get-DispatchJsonProperty -Object $Evidence -Name 'path'
        $path = if ($null -ne $pathValue) { [string]$pathValue } else { $null }
        $lineValue = Get-DispatchJsonProperty -Object $Evidence -Name 'line'
        $line = if ($null -ne $lineValue) { [int]$lineValue } else { $null }
        $shaValue = Get-DispatchJsonProperty -Object $Evidence -Name 'sha256'
        $sha = if ($null -ne $shaValue) { [string]$shaValue } else { $null }
        return New-UnknownDispatchEvidence -Field $Field -Reason $reason -Source $source -Path $path -Line $line -Sha256 $sha
    }
    $sourceValue = Get-DispatchJsonProperty -Object $Evidence -Name 'source'
    $source = if ($null -ne $sourceValue) { [string]$sourceValue } else { 'unknown' }
    $pathValue = Get-DispatchJsonProperty -Object $Evidence -Name 'path'
    $path = if ($null -ne $pathValue) { [string]$pathValue } else { $null }
    $lineValue = Get-DispatchJsonProperty -Object $Evidence -Name 'line'
    $line = if ($null -ne $lineValue) { [int]$lineValue } else { $null }
    $shaValue = Get-DispatchJsonProperty -Object $Evidence -Name 'sha256'
    $sha = if ($null -ne $shaValue) { [string]$shaValue } else { $null }
    return New-ConfirmedDispatchEvidence -Value $value -Source $source -Field $Field -Path $path -Line $line -Sha256 $sha
}

function New-ModelEvidence {
    param(
        [AllowNull()]
        [object]$RequestedModel,

        [AllowNull()]
        [object]$ResolvedModel,

        [AllowNull()]
        [object]$RuntimeModel,

        [AllowNull()]
        [object]$RequestedReasoningEffort,

        [AllowNull()]
        [object]$ResolvedReasoningEffort,

        [AllowNull()]
        [object]$RuntimeReasoningEffort
    )

    return [ordered]@{
        evidence_contract = 'codex-dispatch.model-evidence.v1'
        model = [ordered]@{
            requested = ConvertTo-DispatchEvidence -Evidence $RequestedModel -Field 'Model'
            resolved = ConvertTo-DispatchEvidence -Evidence $ResolvedModel -Field 'model'
            runtime_verifiable = ConvertTo-DispatchEvidence -Evidence $RuntimeModel -Field 'payload.model'
        }
        reasoning_effort = [ordered]@{
            requested = ConvertTo-DispatchEvidence -Evidence $RequestedReasoningEffort -Field 'ReasoningEffort'
            resolved = ConvertTo-DispatchEvidence -Evidence $ResolvedReasoningEffort -Field 'model_reasoning_effort'
            runtime_verifiable = ConvertTo-DispatchEvidence -Evidence $RuntimeReasoningEffort -Field 'payload.effort'
        }
    }
}

function ConvertTo-DispatchEvidenceGroup {
    param(
        [AllowNull()]
        [object]$Evidence,

        [Parameter(Mandatory)]
        [string]$Field,

        [string]$CompatibilityValue
    )

    $requested = $null
    $resolved = $null
    $runtime = $null
    if ($null -ne $Evidence) {
        $requested = Get-DispatchJsonProperty -Object $Evidence -Name 'requested'
        $resolved = Get-DispatchJsonProperty -Object $Evidence -Name 'resolved'
        $runtime = Get-DispatchJsonProperty -Object $Evidence -Name 'runtime_verifiable'
    }
    if ($null -eq $requested -and $null -eq $resolved -and $null -eq $runtime) {
        if ([string]::IsNullOrWhiteSpace($CompatibilityValue)) {
            $single = ConvertTo-DispatchEvidence -Evidence $Evidence -Field $Field
            $requested = New-UnknownDispatchEvidence -Field $Field -Reason '校準缺少 requested evidence。' -Source 'evidence-missing'
            $resolved = $single
            $runtime = New-UnknownDispatchEvidence -Field $Field -Reason '校準缺少 runtime_verifiable evidence。' -Source 'evidence-missing'
        }
        else {
            $requested = New-ConfirmedDispatchEvidence -Value $CompatibilityValue -Source 'compatibility-parameter' -Field $Field
            $resolved = New-ConfirmedDispatchEvidence -Value $CompatibilityValue -Source 'compatibility-parameter' -Field $Field
            $runtime = New-ConfirmedDispatchEvidence -Value $CompatibilityValue -Source 'compatibility-parameter' -Field $Field
        }
    }
    return [ordered]@{
        requested = ConvertTo-DispatchEvidence -Evidence $requested -Field $Field -UnknownReason 'requested evidence 無法正規化。'
        resolved = ConvertTo-DispatchEvidence -Evidence $resolved -Field $Field -UnknownReason 'resolved evidence 無法正規化。'
        runtime_verifiable = ConvertTo-DispatchEvidence -Evidence $runtime -Field $Field -UnknownReason 'runtime_verifiable evidence 無法正規化。'
    }
}

function Test-DispatchEvidencePair {
    param(
        [Parameter(Mandatory)]
        [psobject]$EvidenceGroup
    )

    $resolvedEvidence = Get-DispatchJsonProperty -Object $EvidenceGroup -Name 'resolved'
    $runtimeEvidence = Get-DispatchJsonProperty -Object $EvidenceGroup -Name 'runtime_verifiable'
    $resolved = Get-DispatchEvidenceValue -Evidence $resolvedEvidence
    $runtime = Get-DispatchEvidenceValue -Evidence $runtimeEvidence
    $matches = $null -ne $resolved -and $null -ne $runtime -and [string]::Equals($resolved, $runtime, [StringComparison]::Ordinal)
    return [ordered]@{
        eligible = $matches
        resolved = $resolved
        runtime = $runtime
        reason = if ($matches) { $null } elseif ($null -eq $resolved -or $null -eq $runtime) { 'resolved 或 runtime_verifiable evidence unknown。' } else { 'resolved 與 runtime_verifiable evidence 不一致。' }
    }
}

function Get-DispatchEvidenceValue {
    param(
        [AllowNull()]
        [object]$Evidence
    )

    if ($null -eq $Evidence) {
        return $null
    }
    $status = Get-DispatchJsonProperty -Object $Evidence -Name 'status'
    $value = Get-DispatchJsonProperty -Object $Evidence -Name 'value'
    if ($null -eq $status -or $null -eq $value -or [string]$status -ne 'confirmed') {
        return $null
    }
    return [string]$value
}

function New-RequestedDispatchEvidence {
    param(
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$Field
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return New-UnknownDispatchEvidence -Field $Field -Reason '呼叫端沒有明確提供參數。' -Source 'parameter-omitted'
    }
    return New-ConfirmedDispatchEvidence -Value $Value -Source 'parameter' -Field $Field
}

function Resolve-CodexHomeForEvidence {
    param(
        [string]$CodexHomePath
    )

    $configured = $CodexHomePath
    if ([string]::IsNullOrWhiteSpace($configured)) {
        $configured = $env:CODEX_HOME
    }
    if ([string]::IsNullOrWhiteSpace($configured)) {
        $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
            $configured = Join-Path -Path $userProfile -ChildPath '.codex'
        }
    }
    if ([string]::IsNullOrWhiteSpace($configured)) {
        return $null
    }
    return Resolve-AbsolutePath -Path $configured
}

function Resolve-ProfileConfigPath {
    param(
        [string]$CodexHome,

        [string]$Profile
    )

    if ([string]::IsNullOrWhiteSpace($CodexHome) -or $Profile -notin @('default', 'advisor')) {
        return $null
    }
    $homePath = Resolve-AbsolutePath -Path $CodexHome
    $fileName = if ($Profile -eq 'advisor') { 'advisor.config.toml' } else { 'default.config.toml' }
    $configPath = Join-Path -Path $homePath -ChildPath $fileName
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return $null
    }
    return Resolve-AbsolutePath -Path $configPath
}

function Read-ProfileModelEvidence {
    param(
        [string]$ConfigPath,

        [string]$Profile
    )

    $modelField = 'model'
    $effortField = 'model_reasoning_effort'
    $unknownPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $null } else { Resolve-AbsolutePath -Path $ConfigPath }
    if ([string]::IsNullOrWhiteSpace($unknownPath) -or -not (Test-Path -LiteralPath $unknownPath -PathType Leaf)) {
        return [ordered]@{
            config_path = $unknownPath
            config_sha256 = $null
            model = New-UnknownDispatchEvidence -Field $modelField -Reason 'Profile 設定檔不存在。' -Source 'profile-config-missing' -Path $unknownPath
            reasoning_effort = New-UnknownDispatchEvidence -Field $effortField -Reason 'Profile 設定檔不存在。' -Source 'profile-config-missing' -Path $unknownPath
        }
    }

    $hash = $null
    $content = $null
    try {
        $hash = Get-FileSha256 -Path $unknownPath
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $content = $utf8.GetString([IO.File]::ReadAllBytes($unknownPath))
    }
    catch {
        $reason = 'Profile 設定檔讀取失敗：' + $_.Exception.Message
        return [ordered]@{
            config_path = $unknownPath
            config_sha256 = $hash
            model = New-UnknownDispatchEvidence -Field $modelField -Reason $reason -Source 'profile-config-read-failed' -Path $unknownPath -Sha256 $hash
            reasoning_effort = New-UnknownDispatchEvidence -Field $effortField -Reason $reason -Source 'profile-config-read-failed' -Path $unknownPath -Sha256 $hash
        }
    }

    $assignments = @{
        model = New-Object System.Collections.Generic.List[object]
        model_reasoning_effort = New-Object System.Collections.Generic.List[object]
    }
    $invalidFields = @{}
    $lines = [regex]::Split($content, '\r?\n')
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        if ($index -eq 0 -and $line.Length -gt 0 -and $line[0] -eq [char]0xFEFF) {
            $line = $line.Substring(1)
        }
        if ($line -match '^\s*\[\[?') {
            break
        }
        if ($line -match '^\s*(?<field>model|model_reasoning_effort)\s*=\s*(?<value>.*?)(?:\s+#.*)?$') {
            $field = $Matches['field']
            $rawValue = $Matches['value'].Trim()
            $value = $null
            if ($rawValue -match '^"(?<quoted>(?:[^"\\]|\\.)*)"$') {
                $value = $Matches['quoted']
                $value = $value.Replace('\\"', '"').Replace('\\\\', '\\')
            }
            elseif ($rawValue -match "^'(?<quoted>[^']*)'$") {
                $value = $Matches['quoted']
            }
            else {
                $invalidFields[$field] = '格式不是字串 assignment'
            }
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $assignments[$field].Add([pscustomobject]@{ Value = $value; Line = $index + 1 })
            }
            elseif (-not $invalidFields.ContainsKey($field)) {
                $invalidFields[$field] = '值為空'
            }
        }
    }

    $buildEvidence = {
        param($Field, $Items, $InvalidFields)
        if ($InvalidFields.ContainsKey($Field)) {
            return New-UnknownDispatchEvidence -Field $Field -Reason ('Profile top-level assignment 無法解析：' + $InvalidFields[$Field]) -Source 'profile-config-invalid' -Path $unknownPath -Sha256 $hash
        }
        if ($Items.Count -eq 0) {
            return New-UnknownDispatchEvidence -Field $Field -Reason 'Profile 設定檔缺少 top-level assignment。' -Source 'profile-config-missing-field' -Path $unknownPath -Sha256 $hash
        }
        $first = $Items[0]
        foreach ($item in $Items) {
            if ($item.Value -cne $first.Value) {
                return New-UnknownDispatchEvidence -Field $Field -Reason 'Profile top-level assignment 重複且值衝突。' -Source 'profile-config-conflict' -Path $unknownPath -Line $first.Line -Sha256 $hash
            }
        }
        return New-ConfirmedDispatchEvidence -Value $first.Value -Source 'profile-config' -Field $Field -Path $unknownPath -Line ([int]$first.Line) -Sha256 $hash
    }
    $modelEvidence = & $buildEvidence 'model' $assignments.model $invalidFields
    $effortEvidence = & $buildEvidence 'model_reasoning_effort' $assignments.model_reasoning_effort $invalidFields
    return [ordered]@{
        config_path = $unknownPath
        config_sha256 = $hash
        model = $modelEvidence
        reasoning_effort = $effortEvidence
    }
}

function Get-DispatchJsonProperty {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) {
            return $null
        }
        Write-Output -NoEnumerate -InputObject $Object[$Name]
        return
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    Write-Output -NoEnumerate -InputObject $property.Value
    return
}

function Get-DispatchByteArraySha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Invoke-DispatchRawGitEvidenceCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $gitPath = Get-GitPath
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $gitPath
    $startInfo.WorkingDirectory = $ExecutionRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    Add-ProcessArguments -StartInfo $startInfo -Arguments $Arguments
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList @($false)
    if ($null -ne $startInfo.PSObject.Properties['StandardInputEncoding']) {
        $startInfo.StandardInputEncoding = $utf8NoBom
    }
    $startInfo.StandardOutputEncoding = $utf8NoBom
    $startInfo.StandardErrorEncoding = $utf8NoBom
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $stdoutBuffer = New-Object System.IO.MemoryStream
    $startedAt = [DateTimeOffset]::UtcNow
    try {
        if (-not $process.Start()) {
            throw 'Git evidence Process.Start() 回傳 false。'
        }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutBuffer)
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $null = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $bytes = $stdoutBuffer.ToArray()
        return [pscustomobject]@{
            command = $gitPath + ' ' + ($Arguments -join ' ')
            exit_code = $process.ExitCode
            stdout_bytes = $bytes
            stdout_text = ([Text.Encoding]::UTF8.GetString($bytes))
            stderr = $stderr
            start_utc = $startedAt.ToString('o')
            finish_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
    }
    finally {
        $stdoutBuffer.Dispose()
        $process.Dispose()
    }
}

function New-DispatchEvidenceBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$EvidencePosition
    )

    $binding = [ordered]@{
        schema = 'ai-sessions.dispatch-evidence-binding.v1'
        evidence_kind = 'fixture'
        execution_root = $ExecutionRoot
        head = $null
        tracked_diff_sha256 = $null
        untracked_files = @()
        uncommitted_content_fingerprint = $null
        serialization_version = 'dispatch-content-fingerprint-v1'
        commands = [ordered]@{}
        evidence_position = $EvidencePosition
        captured_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        capture_status = 'not-attempted'
        capture_error = $null
    }
    try {
        $headResult = Invoke-DispatchRawGitEvidenceCommand -ExecutionRoot $ExecutionRoot -Arguments @('rev-parse', '--verify', 'HEAD')
        $binding.commands.head = $headResult.command
        $binding.commands.tracked_diff = $null
        $binding.commands.untracked = $null
        if ([int]$headResult.exit_code -ne 0) {
            $binding.capture_status = 'fixture-no-git'
            $binding.capture_error = [string]$headResult.stderr
            return $binding
        }
        $head = ([string]$headResult.stdout_text).Trim()
        if ($head -notmatch '^[0-9a-fA-F]{40}$') {
            throw ('Git HEAD 不是完整 SHA-1：' + $head)
        }
        $diffResult = Invoke-DispatchRawGitEvidenceCommand -ExecutionRoot $ExecutionRoot -Arguments @('diff', '--binary', '--no-ext-diff', 'HEAD', '--')
        $untrackedResult = Invoke-DispatchRawGitEvidenceCommand -ExecutionRoot $ExecutionRoot -Arguments @('ls-files', '--others', '--exclude-standard', '-z')
        $binding.commands.tracked_diff = $diffResult.command
        $binding.commands.untracked = $untrackedResult.command
        if ([int]$diffResult.exit_code -ne 0 -or [int]$untrackedResult.exit_code -ne 0) {
            throw ('Git content evidence 命令失敗：diff=' + [string]$diffResult.stderr + '; untracked=' + [string]$untrackedResult.stderr)
        }
        $untrackedText = [Text.Encoding]::UTF8.GetString([byte[]]$untrackedResult.stdout_bytes)
        $untrackedEntries = New-Object 'System.Collections.Generic.List[object]'
        foreach ($rawPath in @($untrackedText -split [char]0 | Where-Object { -not [string]::IsNullOrEmpty($_) })) {
            $relativePath = ([string]$rawPath).Replace('\', '/')
            if ([IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '(^|/)\.\.(/|$)') {
                throw ('untracked path 不合法：' + $relativePath)
            }
            $candidatePath = Resolve-AbsolutePath -Path (Join-Path $ExecutionRoot ($relativePath.Replace('/', '\')))
            if (-not (Test-PathWithinRoot -Path $candidatePath -Root $ExecutionRoot)) {
                throw ('untracked path 超出 execution root：' + $relativePath)
            }
            if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
                throw ('untracked path 不存在：' + $relativePath)
            }
            $bytes = [IO.File]::ReadAllBytes((ConvertTo-FileSystemApiPath -Path $candidatePath))
            $untrackedEntries.Add([ordered]@{
                    path = $relativePath
                    byte_length = $bytes.Length
                    sha256 = Get-DispatchByteArraySha256 -Bytes $bytes
                })
        }
        $sortedEntries = @($untrackedEntries.ToArray() | Sort-Object -Property path)
        $trackedDiffSha256 = Get-DispatchByteArraySha256 -Bytes ([byte[]]$diffResult.stdout_bytes)
        $canonical = [ordered]@{
            serialization_version = 'dispatch-content-fingerprint-v1'
            head = $head.ToLowerInvariant()
            tracked_diff_sha256 = $trackedDiffSha256
            untracked_files = $sortedEntries
        }
        $canonicalJson = ConvertTo-Json -InputObject $canonical -Depth 50 -Compress
        $binding.evidence_kind = 'real-dispatch'
        $binding.head = $head.ToLowerInvariant()
        $binding.tracked_diff_sha256 = $trackedDiffSha256
        $binding.untracked_files = $sortedEntries
        $binding.uncommitted_content_fingerprint = Get-DispatchByteArraySha256 -Bytes ([Text.Encoding]::UTF8.GetBytes($canonicalJson))
        $binding.capture_status = 'completed'
        return $binding
    }
    catch {
        $binding.capture_status = 'capture-failed'
        $binding.capture_error = $_.Exception.Message
        return $binding
    }
}

function Get-DispatchStringArraySha256 {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]]$Values
    )

    $valueList = New-Object 'System.Collections.Generic.List[string]'
    foreach ($value in @($Values)) {
        $valueList.Add([string]$value)
    }
    [object]$arrayValue = $valueList.ToArray()
    $json = ConvertTo-Json -InputObject $arrayValue -Depth 10 -Compress
    return Get-DispatchByteArraySha256 -Bytes ([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Throw-DispatchRequestFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Code,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$RequestPathValue,

        [string]$Field,

        [AllowNull()]
        [object]$Detail
    )

    $detailValue = if ($null -eq $Detail) { [ordered]@{} } else { $Detail }
    $classification = switch ($Code) {
        'DispatchRequestMissingField' { 'MissingField' }
        'DispatchRequestFieldType' { 'FieldType' }
        'DispatchRequestNullArrayElement' { 'FieldType' }
        'DispatchRequestInvalidValue' { 'InvalidValue' }
        'DispatchRequestInvalidPath' { 'InvalidPath' }
        default { $null }
    }
    $result = [ordered]@{
        operation      = 'DispatchRequest'
        schema         = 'ai-sessions.dispatch-request.v1'
        code           = $Code
        error_code     = $Code
        reason_code    = $Code
        classification = $classification
        message        = $Message
        request_path   = if ([string]::IsNullOrWhiteSpace($RequestPathValue)) { $null } else { $RequestPathValue }
        field          = if ([string]::IsNullOrWhiteSpace($Field)) { $null } else { $Field }
        process_started = $false
        output_valid   = $false
        detail         = $detailValue
    }
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['operationResult'] = $result
    throw $exception
}

function Test-DispatchFullyQualifiedPath {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    return [System.Text.RegularExpressions.Regex]::IsMatch(
        $Path,
        '^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/]+[\\/][^\\/]+(?:[\\/]|$))',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
}

function Test-DispatchRequestFieldPresent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Document,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return $null -ne $Document.PSObject.Properties[$Name]
}

function Assert-DispatchRequestRequiredField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Document,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$RequestPathValue
    )

    $property = $Document.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestMissingField' -Message ("request file 缺少必要欄位：{0}" -f $Name) -RequestPathValue $RequestPathValue -Field $Name
    }
}

function Get-DispatchRequestTypeName {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return 'null'
    }
    return $Value.GetType().FullName
}

function Get-DispatchRequestStringArray {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Field,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$RequestPathValue
    )

    if ($Value -isnot [array]) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message ("request 欄位 {0} 必須是 string array。" -f $Field) -RequestPathValue $RequestPathValue -Field $Field -Detail ([ordered]@{ expected_type = 'string[]'; actual_type = Get-DispatchRequestTypeName -Value $Value })
    }

    $values = New-Object 'System.Collections.Generic.List[string]'
    $index = 0
    foreach ($item in @($Value)) {
        if ($null -eq $item) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestNullArrayElement' -Message ("request 欄位 {0} 的第 {1} 項不可為 null。" -f $Field, $index) -RequestPathValue $RequestPathValue -Field $Field -Detail ([ordered]@{ index = $index })
        }
        if ($item -isnot [string]) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message ("request 欄位 {0} 的第 {1} 項必須是 string。" -f $Field, $index) -RequestPathValue $RequestPathValue -Field $Field -Detail ([ordered]@{ index = $index; expected_type = 'string'; actual_type = $item.GetType().FullName })
        }
        $stringValue = [string]$item
        if ($Field -ne 'literal_values' -and [string]::IsNullOrWhiteSpace($stringValue)) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message ("request 欄位 {0} 的第 {1} 項不可為空白。" -f $Field, $index) -RequestPathValue $RequestPathValue -Field $Field -Detail ([ordered]@{ index = $index })
        }
        $values.Add($stringValue)
        $index++
    }

    return @($values.ToArray())
}

function Get-DispatchRequestArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$RequestPathValue
    )

    if ($Value -isnot [array]) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message 'request 欄位 prepare_artifacts 必須是 object array。' -RequestPathValue $RequestPathValue -Field 'prepare_artifacts' -Detail ([ordered]@{ expected_type = 'object[]'; actual_type = Get-DispatchRequestTypeName -Value $Value })
    }

    $artifacts = New-Object 'System.Collections.Generic.List[object]'
    $allowedArtifactFields = @('source', 'destination', 'sha256', 'purpose')
    $requiredArtifactFields = @('source', 'destination', 'sha256', 'purpose')
    $index = 0
    foreach ($item in @($Value)) {
        if ($null -eq $item -or $item -isnot [psobject]) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message ("request 欄位 prepare_artifacts 的第 {0} 項必須是 object。" -f $index) -RequestPathValue $RequestPathValue -Field ('prepare_artifacts[' + $index + ']') -Detail ([ordered]@{ index = $index; expected_type = 'object' })
        }
        foreach ($property in $item.PSObject.Properties) {
            if ($allowedArtifactFields -notcontains $property.Name) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestUnknownField' -Message ("request 欄位 prepare_artifacts[{0}] 含未知欄位 {1}。" -f $index, $property.Name) -RequestPathValue $RequestPathValue -Field ('prepare_artifacts[' + $index + '].' + $property.Name) -Detail ([ordered]@{ index = $index; name = $property.Name })
            }
        }
        foreach ($requiredField in $requiredArtifactFields) {
            $property = $item.PSObject.Properties[$requiredField]
            if ($null -eq $property) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestMissingField' -Message ("request 欄位 prepare_artifacts[{0}] 缺少 {1}。" -f $index, $requiredField) -RequestPathValue $RequestPathValue -Field ('prepare_artifacts[' + $index + '].' + $requiredField) -Detail ([ordered]@{ index = $index; name = $requiredField })
            }
            if ($property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message ("request 欄位 prepare_artifacts[{0}].{1} 必須是非空字串。" -f $index, $requiredField) -RequestPathValue $RequestPathValue -Field ('prepare_artifacts[' + $index + '].' + $requiredField) -Detail ([ordered]@{ index = $index; name = $requiredField })
            }
        }
        if ([string]$item.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
            Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message ("request 欄位 prepare_artifacts[{0}].sha256 必須是 64 碼 SHA-256。" -f $index) -RequestPathValue $RequestPathValue -Field ('prepare_artifacts[' + $index + '].sha256') -Detail ([ordered]@{ index = $index })
        }
        $artifacts.Add($item)
        $index++
    }

    return @($artifacts.ToArray())
}

function Get-DispatchRequestOptionalString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Document,

        [Parameter(Mandatory)]
        [string]$Field,

        [Parameter(Mandatory)]
        [string]$RequestPathValue
    )

    $property = $Document.PSObject.Properties[$Field]
    if ($null -eq $property) {
        return $null
    }
    if ($null -eq $property.Value -or $property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message ("request 欄位 {0} 必須是非空字串。" -f $Field) -RequestPathValue $RequestPathValue -Field $Field -Detail ([ordered]@{ expected_type = 'non-empty string' })
    }
    return [string]$property.Value
}

function Get-DispatchRequestEnumValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Document,

        [Parameter(Mandatory)]
        [string]$Field,

        [Parameter(Mandatory)]
        [string[]]$AllowedValues,

        [Parameter(Mandatory)]
        [string]$RequestPathValue
    )

    $value = Get-DispatchRequestOptionalString -Document $Document -Field $Field -RequestPathValue $RequestPathValue
    if ($null -ne $value -and $AllowedValues -notcontains $value) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message ("request 欄位 {0} 不支援：{1}" -f $Field, $value) -RequestPathValue $RequestPathValue -Field $Field -Detail ([ordered]@{ valid_values = @($AllowedValues); received = $value })
    }
    return $value
}

function Read-DispatchRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestMissingField' -Message 'RequestPath 不可為空。' -Field 'RequestPath'
    }

    try {
        $requestPathValue = Resolve-AbsolutePath -Path $Path
    }
    catch {
        Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidPath' -Message ('RequestPath 無法解析：' + $_.Exception.Message) -RequestPathValue $Path -Field 'RequestPath'
    }
    if (-not (Test-Path -LiteralPath $requestPathValue -PathType Leaf)) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestMissingFile' -Message ('找不到 request file：' + $requestPathValue) -RequestPathValue $requestPathValue -Field 'RequestPath'
    }

    $bytesBefore = [System.IO.File]::ReadAllBytes($requestPathValue)
    if ($bytesBefore.Length -ge 3 -and $bytesBefore[0] -eq 239 -and $bytesBefore[1] -eq 187 -and $bytesBefore[2] -eq 191) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestEncoding' -Message ('request file 必須是 UTF-8 無 BOM：' + $requestPathValue) -RequestPathValue $requestPathValue -Field 'encoding'
    }
    $hashBefore = Get-DispatchByteArraySha256 -Bytes $bytesBefore
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
    try {
        $content = [System.IO.File]::ReadAllText($requestPathValue, $encoding)
    }
    catch {
        Throw-DispatchRequestFailure -Code 'DispatchRequestEncoding' -Message ('request file 不是有效 UTF-8：' + $requestPathValue + '；' + $_.Exception.Message) -RequestPathValue $requestPathValue -Field 'encoding'
    }
    try {
        $document = ConvertFrom-DispatchJson -Content $content
    }
    catch {
        Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidJson' -Message ('request file JSON 無法解析：' + $_.Exception.Message) -RequestPathValue $requestPathValue
    }
    $bytesAfter = [System.IO.File]::ReadAllBytes($requestPathValue)
    $hashAfter = Get-DispatchByteArraySha256 -Bytes $bytesAfter
    if (-not [string]::Equals($hashBefore, $hashAfter, [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestChanged' -Message ('request file 在解析期間變更：' + $requestPathValue) -RequestPathValue $requestPathValue -Detail ([ordered]@{ before_sha256 = $hashBefore; after_sha256 = $hashAfter })
    }
    if ($null -eq $document -or $document -isnot [pscustomobject]) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidJson' -Message 'request file 根節點必須是 JSON object。' -RequestPathValue $requestPathValue
    }

    $dispatchOnlyFields = @('write_mode', 'dispatch_kind', 'prompt_path', 'task_type', 'session_mode', 'unit_kind', 'requested_unit', 'continue_from_scope_plan', 'failure_receipt_path', 'prepare_result_path', 'quota_before_path', 'quota_after_path', 'evidence_pack_path', 'advisor_consult_report_path')
    $commonRootFields = @('source_root', 'dispatch_root')
    $cleanupOnlyFields = @('run_record_path', 'reviewer_report_path', 'report_path', 'evidence_path')
    $allowedFields = @('schema', 'operation', 'line_slug', 'dispatch_slug', 'profile', 'advisor_request_source', 'target_path', 'add_directory', 'search', 'codex_parent_option', 'literal_values', 'prepare_artifacts', 'result_path', 'preflight_result_path') + $commonRootFields + $dispatchOnlyFields + $cleanupOnlyFields
    foreach ($property in $document.PSObject.Properties) {
        if ($allowedFields -notcontains $property.Name) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestUnknownField' -Message ("request file 含未知欄位：{0}" -f $property.Name) -RequestPathValue $requestPathValue -Field $property.Name -Detail ([ordered]@{ name = $property.Name })
        }
    }

    foreach ($requiredField in @('schema', 'operation', 'line_slug', 'dispatch_slug')) {
        Assert-DispatchRequestRequiredField -Document $document -Name $requiredField -RequestPathValue $requestPathValue
    }

    if ($document.schema -isnot [string] -or [string]$document.schema -cne 'ai-sessions.dispatch-request.v1') {
        Throw-DispatchRequestFailure -Code 'DispatchRequestSchemaMismatch' -Message 'request file schema 不符。' -RequestPathValue $requestPathValue -Field 'schema' -Detail ([ordered]@{ expected = 'ai-sessions.dispatch-request.v1'; received = [string]$document.schema })
    }
    $validOperations = @('Preflight', 'Prepare', 'Start', 'Inspect', 'Collect', 'QuotaProbe', 'Dispatch', 'Cleanup')
    if ($document.operation -isnot [string] -or $validOperations -notcontains [string]$document.operation) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message ('request operation 不支援：' + [string]$document.operation) -RequestPathValue $requestPathValue -Field 'operation' -Detail ([ordered]@{ valid_operations = $validOperations; received = [string]$document.operation })
    }
    if ([string]$document.operation -notin @('Dispatch', 'Cleanup')) {
        foreach ($field in @($commonRootFields) + @('result_path', 'preflight_result_path') + $dispatchOnlyFields + $cleanupOnlyFields) {
            if (Test-DispatchRequestFieldPresent -Document $document -Name $field) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestFieldNotAllowed' -Message ("request 欄位 {0} 僅可用於 operation=Dispatch 或 Cleanup。" -f $field) -RequestPathValue $requestPathValue -Field $field -Detail ([ordered]@{ operation = [string]$document.operation })
            }
        }
    }
    elseif ([string]$document.operation -eq 'Dispatch') {
        foreach ($field in $cleanupOnlyFields) {
            if (Test-DispatchRequestFieldPresent -Document $document -Name $field) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestFieldNotAllowed' -Message ("request 欄位 {0} 僅可用於 operation=Cleanup。" -f $field) -RequestPathValue $requestPathValue -Field $field -Detail ([ordered]@{ operation = [string]$document.operation })
            }
        }
        foreach ($requiredDispatchField in @('source_root', 'dispatch_root', 'write_mode', 'dispatch_kind', 'target_path', 'prepare_artifacts', 'prompt_path', 'task_type', 'session_mode', 'unit_kind', 'requested_unit', 'failure_receipt_path')) {
            $requiredDispatchProperty = $document.PSObject.Properties[$requiredDispatchField]
            if ($null -eq $requiredDispatchProperty -or $null -eq $requiredDispatchProperty.Value) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestMissingField' -Message ("Dispatch request file 缺少必要欄位：{0}" -f $requiredDispatchField) -RequestPathValue $requestPathValue -Field $requiredDispatchField
            }
        }
    }
    else {
        foreach ($field in $dispatchOnlyFields) {
            if (Test-DispatchRequestFieldPresent -Document $document -Name $field) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestFieldNotAllowed' -Message ("Cleanup request 不允許欄位：{0}" -f $field) -RequestPathValue $requestPathValue -Field $field -Detail ([ordered]@{ operation = 'Cleanup' })
            }
        }
    }
    foreach ($identityField in @('line_slug', 'dispatch_slug')) {
        $identityValue = $document.$identityField
        if ($identityValue -isnot [string]) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message ("request 欄位 {0} 必須是字串。" -f $identityField) -RequestPathValue $requestPathValue -Field $identityField -Detail ([ordered]@{ expected_type = 'string'; actual_type = Get-DispatchRequestTypeName -Value $identityValue })
        }
        if ([string]::IsNullOrWhiteSpace([string]$identityValue) -or [regex]::IsMatch([string]$identityValue, '^[a-z0-9]+(?:-[a-z0-9]+)*$') -eq $false) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message ("request 欄位 {0} 必須是小寫 slug。" -f $identityField) -RequestPathValue $requestPathValue -Field $identityField -Detail ([ordered]@{ received = [string]$identityValue })
        }
    }

    $fieldPresence = [ordered]@{}
    $arrayValues = [ordered]@{}
    foreach ($arrayField in @('target_path', 'add_directory', 'codex_parent_option', 'literal_values')) {
        $present = Test-DispatchRequestFieldPresent -Document $document -Name $arrayField
        $fieldPresence[$arrayField] = $present
        if ($present) {
            $arrayProperty = $document.PSObject.Properties[$arrayField]
            $arrayValues[$arrayField] = @(Get-DispatchRequestStringArray -Field $arrayField -Value $arrayProperty.Value -RequestPathValue $requestPathValue)
            if ($arrayField -ceq 'target_path') {
                if ($arrayValues[$arrayField].Count -eq 0) {
                    Throw-DispatchRequestFailure -Code 'DispatchRequestMissingField' -Message 'request 欄位 target_path 至少需要一項。' -RequestPathValue $requestPathValue -Field 'target_path' -Detail ([ordered]@{ count = 0 })
                }
                for ($targetIndex = 0; $targetIndex -lt $arrayValues[$arrayField].Count; $targetIndex++) {
                    $targetPathValue = [string]$arrayValues[$arrayField][$targetIndex]
                    if (-not (Test-DispatchFullyQualifiedPath -Path $targetPathValue)) {
                        Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidPath' -Message ("request 欄位 target_path 的第 {0} 項必須是完整絕對路徑。" -f $targetIndex) -RequestPathValue $requestPathValue -Field 'target_path' -Detail ([ordered]@{ index = $targetIndex; expected = 'fully-qualified path'; received = $targetPathValue })
                    }
                }
            }
        }
        else {
            $arrayValues[$arrayField] = $null
        }
    }
    $searchPresent = Test-DispatchRequestFieldPresent -Document $document -Name 'search'
    $fieldPresence.search = $searchPresent
    if ($searchPresent -and $document.search -isnot [bool]) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message 'request 欄位 search 必須是 boolean。' -RequestPathValue $requestPathValue -Field 'search' -Detail ([ordered]@{ expected_type = 'boolean'; actual_type = Get-DispatchRequestTypeName -Value $document.search })
    }
    $profilePresent = Test-DispatchRequestFieldPresent -Document $document -Name 'profile'
    $fieldPresence.profile = $profilePresent
    $profileValue = $null
    if ($profilePresent) {
        if ($document.profile -isnot [string]) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message 'request 欄位 profile 必須是 string。' -RequestPathValue $requestPathValue -Field 'profile' -Detail ([ordered]@{ expected_type = 'string'; actual_type = Get-DispatchRequestTypeName -Value $document.profile })
        }
        $profileValue = [string]$document.profile
        if (@('default', 'advisor') -notcontains $profileValue) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message ('request 欄位 profile 不支援：' + $profileValue) -RequestPathValue $requestPathValue -Field 'profile' -Detail ([ordered]@{ valid_values = @('default', 'advisor'); received = $profileValue })
        }
    }
    $advisorRequestSourcePresent = Test-DispatchRequestFieldPresent -Document $document -Name 'advisor_request_source'
    $fieldPresence.advisor_request_source = $advisorRequestSourcePresent
    $advisorRequestSourceValue = $null
    if ($advisorRequestSourcePresent) {
        if ($document.advisor_request_source -isnot [string]) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message 'request 欄位 advisor_request_source 必須是 string。' -RequestPathValue $requestPathValue -Field 'advisor_request_source' -Detail ([ordered]@{ expected_type = 'string'; actual_type = Get-DispatchRequestTypeName -Value $document.advisor_request_source })
        }
        $advisorRequestSourceValue = [string]$document.advisor_request_source
        if (@('automatic-quota', 'user-explicit') -notcontains $advisorRequestSourceValue) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message ('request 欄位 advisor_request_source 不支援：' + $advisorRequestSourceValue) -RequestPathValue $requestPathValue -Field 'advisor_request_source' -Detail ([ordered]@{ valid_values = @('automatic-quota', 'user-explicit'); received = $advisorRequestSourceValue })
        }
    }
    $fieldPresence.prepare_artifacts = Test-DispatchRequestFieldPresent -Document $document -Name 'prepare_artifacts'
    $prepareArtifacts = @()
    if ($fieldPresence.prepare_artifacts) {
        $prepareArtifactsProperty = $document.PSObject.Properties['prepare_artifacts']
        $prepareArtifacts = @(Get-DispatchRequestArtifacts -Value $prepareArtifactsProperty.Value -RequestPathValue $requestPathValue)
    }

    $dispatchFieldPresence = [ordered]@{}
    $dispatchValues = [ordered]@{}
    $cleanupFieldPresence = [ordered]@{}
    $cleanupValues = [ordered]@{}
    if ([string]$document.operation -ceq 'Dispatch') {
        foreach ($field in @('source_root', 'dispatch_root', 'prompt_path', 'task_type', 'failure_receipt_path', 'result_path', 'preflight_result_path', 'prepare_result_path', 'quota_before_path', 'quota_after_path', 'evidence_pack_path', 'advisor_consult_report_path')) {
            $dispatchFieldPresence[$field] = Test-DispatchRequestFieldPresent -Document $document -Name $field
            $dispatchValues[$field] = Get-DispatchRequestOptionalString -Document $document -Field $field -RequestPathValue $requestPathValue
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$dispatchValues.failure_receipt_path) -and -not (Test-DispatchFullyQualifiedPath -Path ([string]$dispatchValues.failure_receipt_path))) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidPath' -Message 'request 欄位 failure_receipt_path 必須是完整絕對路徑。' -RequestPathValue $requestPathValue -Field 'failure_receipt_path' -Detail ([ordered]@{ expected = 'fully-qualified path'; received = [string]$dispatchValues.failure_receipt_path })
        }
        if ([string]$dispatchValues.task_type -ceq 'advisor-consult') {
            foreach ($advisorField in @('evidence_pack_path', 'advisor_consult_report_path')) {
                if (-not [bool]$dispatchFieldPresence[$advisorField] -or [string]::IsNullOrWhiteSpace([string]$dispatchValues[$advisorField])) {
                    Throw-DispatchRequestFailure -Code 'DispatchRequestMissingField' -Message ("advisor-consult Request 缺少必要欄位：{0}" -f $advisorField) -RequestPathValue $requestPathValue -Field $advisorField
                }
                if (-not (Test-DispatchFullyQualifiedPath -Path ([string]$dispatchValues[$advisorField]))) {
                    Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidPath' -Message ("request 欄位 {0} 必須是完整絕對路徑。" -f $advisorField) -RequestPathValue $requestPathValue -Field $advisorField -Detail ([ordered]@{ expected = 'fully-qualified path'; received = [string]$dispatchValues[$advisorField] })
                }
            }
        }
        foreach ($fieldAndValues in @(
                [pscustomobject]@{ name = 'write_mode'; values = @('readonly', 'write') },
                [pscustomobject]@{ name = 'dispatch_kind'; values = @('workflow', 'resource') },
                [pscustomobject]@{ name = 'session_mode'; values = @('cold-start', 'continuation') },
                [pscustomobject]@{ name = 'unit_kind'; values = @('workflow-phase', 'resource-target', 'advisor-evidence-question') })) {
            $field = [string]$fieldAndValues.name
            $dispatchFieldPresence[$field] = Test-DispatchRequestFieldPresent -Document $document -Name $field
            $dispatchValues[$field] = Get-DispatchRequestEnumValue -Document $document -Field $field -AllowedValues @($fieldAndValues.values) -RequestPathValue $requestPathValue
        }
        $dispatchFieldPresence.requested_unit = Test-DispatchRequestFieldPresent -Document $document -Name 'requested_unit'
        if ($dispatchFieldPresence.requested_unit) {
            $requestedUnitProperty = $document.PSObject.Properties['requested_unit']
            $dispatchValues.requested_unit = @(Get-DispatchRequestStringArray -Field 'requested_unit' -Value $requestedUnitProperty.Value -RequestPathValue $requestPathValue)
        }
        else {
            $dispatchValues.requested_unit = $null
        }
        $dispatchFieldPresence.continue_from_scope_plan = Test-DispatchRequestFieldPresent -Document $document -Name 'continue_from_scope_plan'
        if ($dispatchFieldPresence.continue_from_scope_plan -and $document.continue_from_scope_plan -isnot [bool]) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message 'request 欄位 continue_from_scope_plan 必須是 boolean。' -RequestPathValue $requestPathValue -Field 'continue_from_scope_plan' -Detail ([ordered]@{ expected_type = 'boolean'; actual_type = Get-DispatchRequestTypeName -Value $document.continue_from_scope_plan })
        }
        $dispatchValues.continue_from_scope_plan = if ($dispatchFieldPresence.continue_from_scope_plan) { [bool]$document.continue_from_scope_plan } else { $null }
    }
    elseif ([string]$document.operation -ceq 'Cleanup') {
        foreach ($field in @('source_root', 'dispatch_root', 'result_path', 'preflight_result_path', 'run_record_path', 'reviewer_report_path')) {
            $cleanupFieldPresence[$field] = Test-DispatchRequestFieldPresent -Document $document -Name $field
            $cleanupValues[$field] = Get-DispatchRequestOptionalString -Document $document -Field $field -RequestPathValue $requestPathValue
        }
        foreach ($field in @('report_path', 'evidence_path')) {
            $cleanupFieldPresence[$field] = Test-DispatchRequestFieldPresent -Document $document -Name $field
            if ($cleanupFieldPresence[$field]) {
                $property = $document.PSObject.Properties[$field]
                $cleanupValues[$field] = @(Get-DispatchRequestStringArray -Field $field -Value $property.Value -RequestPathValue $requestPathValue)
            }
            else {
                $cleanupValues[$field] = $null
            }
        }
    }

    return [ordered]@{
        path                  = $requestPathValue
        sha256                = $hashBefore
        length                = [int64]$bytesBefore.Length
        schema                = 'ai-sessions.dispatch-request.v1'
        document              = $document
        field_presence        = $fieldPresence
        values                = $arrayValues
        profile               = $profileValue
        advisor_request_source = $advisorRequestSourceValue
        search                = if ($searchPresent) { [bool]$document.search } else { $null }
        prepare_artifacts     = @($prepareArtifacts)
        literal_values_sha256 = if ($fieldPresence.literal_values) { Get-DispatchStringArraySha256 -Values $arrayValues.literal_values } else { $null }
        dispatch_field_presence = $dispatchFieldPresence
        dispatch_values       = $dispatchValues
        cleanup_field_presence = $cleanupFieldPresence
        cleanup_values        = $cleanupValues
    }
}

function Test-DispatchInvocationParameterBound {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    return $script:InvocationBoundParameters.Contains($Name)
}

function Get-DispatchInvocationParameterValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Test-DispatchInvocationParameterBound -Name $Name)) {
        return $null
    }
    return $script:InvocationBoundParameters[$Name]
}

function New-DispatchRequestArrayMismatchDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Field,

        [AllowEmptyCollection()]
        [string[]]$Expected,

        [AllowEmptyCollection()]
        [string[]]$Received
    )

    $expectedValues = @($Expected)
    $receivedValues = @($Received)
    $mismatches = New-Object 'System.Collections.Generic.List[object]'
    $firstMismatchIndex = $null
    $maxCount = [math]::Max($expectedValues.Count, $receivedValues.Count)
    for ($index = 0; $index -lt $maxCount; $index++) {
        $expectedValue = if ($index -lt $expectedValues.Count) { $expectedValues[$index] } else { $null }
        $receivedValue = if ($index -lt $receivedValues.Count) { $receivedValues[$index] } else { $null }
        if ($null -eq $firstMismatchIndex -and -not [string]::Equals([string]$expectedValue, [string]$receivedValue, [System.StringComparison]::Ordinal)) {
            $firstMismatchIndex = $index
        }
        if (-not [string]::Equals([string]$expectedValue, [string]$receivedValue, [System.StringComparison]::Ordinal) -or ($null -eq $expectedValue -xor $null -eq $receivedValue)) {
            $mismatches.Add([ordered]@{ index = $index; expected = $expectedValue; received = $receivedValue })
        }
    }
    return [ordered]@{
        field                 = $Field
        expected_count        = $expectedValues.Count
        received_count        = $receivedValues.Count
        first_mismatch_index  = $firstMismatchIndex
        mismatches             = @($mismatches.ToArray())
    }
}

function Apply-DispatchRequestScalarField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Context,

        [Parameter(Mandatory)]
        [string]$CliField,

        [Parameter(Mandatory)]
        [string]$RequestField
    )

    if (-not [bool]$Context.dispatch_field_presence[$RequestField]) {
        return
    }
    $requestValue = [string]$Context.dispatch_values[$RequestField]
    if (Test-DispatchInvocationParameterBound -Name $CliField) {
        $receivedValue = [string](Get-DispatchInvocationParameterValue -Name $CliField)
        if ($receivedValue -cne $requestValue) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message ("request {0} 與命令列參數不一致。" -f $RequestField) -RequestPathValue ([string]$Context.path) -Field $RequestField -Detail ([ordered]@{ expected = $requestValue; received = $receivedValue; process_started = $false })
        }
    }
    else {
        Set-Variable -Name $CliField -Scope Script -Value $requestValue
    }
}

function Apply-DispatchRequestBooleanField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Context,

        [Parameter(Mandatory)]
        [string]$CliField,

        [Parameter(Mandatory)]
        [string]$RequestField
    )

    if (-not [bool]$Context.dispatch_field_presence[$RequestField]) {
        return
    }
    $requestValue = [bool]$Context.dispatch_values[$RequestField]
    if (Test-DispatchInvocationParameterBound -Name $CliField) {
        $receivedValue = [bool](Get-DispatchInvocationParameterValue -Name $CliField)
        if ($receivedValue -ne $requestValue) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message ("request {0} 與命令列參數不一致。" -f $RequestField) -RequestPathValue ([string]$Context.path) -Field $RequestField -Detail ([ordered]@{ expected = $requestValue; received = $receivedValue; process_started = $false })
        }
    }
    else {
        Set-Variable -Name $CliField -Scope Script -Value $requestValue
    }
}

function Apply-DispatchRequest {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($RequestPath)) {
        return $null
    }

    $context = Read-DispatchRequest -Path $RequestPath
    $script:RequestContext = $context
    $document = $context.document
    $requestPathValue = $context.path

    $operationBound = Test-DispatchInvocationParameterBound -Name 'Operation'
    $collectLifecycleRequest = $operationBound -and [string]$Operation -ceq 'Collect' -and [string]$document.operation -ceq 'Dispatch'
    if ($operationBound -and [string]$Operation -cne [string]$document.operation -and -not $collectLifecycleRequest) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message 'request operation 與命令列 Operation 不一致。' -RequestPathValue $requestPathValue -Field 'operation' -Detail ([ordered]@{ expected = [string]$document.operation; received = [string]$Operation; process_started = $false })
    }
    elseif (-not (Test-DispatchInvocationParameterBound -Name 'Operation')) {
        $script:Operation = [string]$document.operation
    }

    if ([bool]$context.field_presence.profile) {
        $requestProfile = [string]$context.profile
        if (Test-DispatchInvocationParameterBound -Name 'Profile') {
            $receivedProfile = [string](Get-DispatchInvocationParameterValue -Name 'Profile')
            if ($receivedProfile -cne $requestProfile) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message 'request profile 與命令列參數不一致。' -RequestPathValue $requestPathValue -Field 'profile' -Detail ([ordered]@{ expected = $requestProfile; received = $receivedProfile; process_started = $false })
            }
        }
        else {
            $script:Profile = $requestProfile
            $script:ProfileExplicit = $true
        }
    }

    if ([bool]$context.field_presence.advisor_request_source) {
        $requestAdvisorSource = [string]$context.advisor_request_source
        if (Test-DispatchInvocationParameterBound -Name 'AdvisorRequestSource') {
            $receivedAdvisorSource = [string](Get-DispatchInvocationParameterValue -Name 'AdvisorRequestSource')
            if ($receivedAdvisorSource -cne $requestAdvisorSource) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message 'request advisor_request_source 與命令列參數不一致。' -RequestPathValue $requestPathValue -Field 'advisor_request_source' -Detail ([ordered]@{ expected = $requestAdvisorSource; received = $receivedAdvisorSource; process_started = $false })
            }
        }
        else {
            $script:AdvisorRequestSource = $requestAdvisorSource
        }
    }

    foreach ($identityField in @('LineSlug', 'DispatchSlug')) {
        $requestField = if ($identityField -eq 'LineSlug') { 'line_slug' } else { 'dispatch_slug' }
        $requestValue = [string](Get-DispatchJsonProperty -Object $document -Name $requestField)
        if (Test-DispatchInvocationParameterBound -Name $identityField) {
            $currentValue = [string](Get-DispatchInvocationParameterValue -Name $identityField)
            if ($currentValue -cne $requestValue) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message ("request {0} 與命令列參數不一致。" -f $requestField) -RequestPathValue $requestPathValue -Field $requestField -Detail ([ordered]@{ expected = $requestValue; received = $currentValue; process_started = $false })
            }
        }
        else {
            if ($identityField -eq 'LineSlug') { $script:LineSlug = $requestValue } else { $script:DispatchSlug = $requestValue }
        }
    }

    foreach ($mapping in @(
            @('TargetPath', 'target_path'),
            @('AddDirectory', 'add_directory'),
            @('CodexParentOption', 'codex_parent_option'))) {
        $cliField = [string]$mapping[0]
        $requestField = [string]$mapping[1]
        if (-not [bool]$context.field_presence[$requestField]) {
            continue
        }
        $requestValues = @($context.values[$requestField])
        if (Test-DispatchInvocationParameterBound -Name $cliField) {
            $receivedValues = @((Get-DispatchInvocationParameterValue -Name $cliField))
            if (-not (Compare-DispatchStringArrays -Left $requestValues -Right $receivedValues)) {
                $detail = New-DispatchRequestArrayMismatchDetail -Field $requestField -Expected $requestValues -Received $receivedValues
                Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message ("request {0} 與命令列參數不一致。" -f $requestField) -RequestPathValue $requestPathValue -Field $requestField -Detail $detail
            }
        }
        else {
            switch ($cliField) {
                'TargetPath' {
                    $script:TargetPath = if ($requestValues.Count -eq 0) { New-Object 'System.String[]' 0 } else { [string[]]$requestValues }
                }
                'AddDirectory' {
                    $script:AddDirectory = if ($requestValues.Count -eq 0) { New-Object 'System.String[]' 0 } else { [string[]]$requestValues }
                    $script:AddDirectoryExplicit = $true
                }
                'CodexParentOption' {
                    $script:CodexParentOption = if ($requestValues.Count -eq 0) { New-Object 'System.String[]' 0 } else { [string[]]$requestValues }
                    $script:CodexParentOptionExplicit = $true
                }
            }
        }
    }

    if ([bool]$context.field_presence.search) {
        $requestSearch = [bool]$context.search
        if (Test-DispatchInvocationParameterBound -Name 'Search') {
            $receivedSearch = [bool](Get-DispatchInvocationParameterValue -Name 'Search')
            if ($requestSearch -ne $receivedSearch) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message 'request search 與命令列參數不一致。' -RequestPathValue $requestPathValue -Field 'search' -Detail ([ordered]@{ expected = $requestSearch; received = $receivedSearch; process_started = $false })
            }
        }
        else {
            $script:Search = $requestSearch
            $script:SearchExplicit = $true
        }
    }

    if ([bool]$context.field_presence.literal_values) {
        $script:RequestLiteralValues = @($context.values.literal_values)
    }
    else {
        $script:RequestLiteralValues = New-Object 'System.String[]' 0
    }
    if ([bool]$context.field_presence.prepare_artifacts) {
        $script:RequestPrepareArtifacts = @($context.prepare_artifacts)
    }
    else {
        $script:RequestPrepareArtifacts = New-Object 'System.Object[]' 0
    }

    if ([string]$document.operation -ceq 'Dispatch') {
        foreach ($mapping in @(
                @('SourceRoot', 'source_root'),
                @('DispatchRoot', 'dispatch_root'),
                @('WriteMode', 'write_mode'),
                @('DispatchKind', 'dispatch_kind'),
                @('PromptPath', 'prompt_path'),
                @('TaskType', 'task_type'),
                @('SessionMode', 'session_mode'),
                @('UnitKind', 'unit_kind'),
                @('FailureReceiptPath', 'failure_receipt_path'),
                @('EvidencePackPath', 'evidence_pack_path'),
                @('AdvisorConsultReportPath', 'advisor_consult_report_path'),
                @('ResultPath', 'result_path'),
                @('PreflightResultPath', 'preflight_result_path'),
                @('PrepareResultPath', 'prepare_result_path'),
                @('QuotaBeforePath', 'quota_before_path'),
                @('QuotaAfterPath', 'quota_after_path'))) {
            Apply-DispatchRequestScalarField -Context $context -CliField ([string]$mapping[0]) -RequestField ([string]$mapping[1])
        }
        Apply-DispatchRequestBooleanField -Context $context -CliField 'ContinueFromScopePlan' -RequestField 'continue_from_scope_plan'
        if ([bool]$context.dispatch_field_presence.requested_unit) {
            $requestValues = @($context.dispatch_values.requested_unit)
            if (Test-DispatchInvocationParameterBound -Name 'RequestedUnit') {
                $receivedValues = @((Get-DispatchInvocationParameterValue -Name 'RequestedUnit'))
                if (-not (Compare-DispatchStringArrays -Left $requestValues -Right $receivedValues)) {
                    $detail = New-DispatchRequestArrayMismatchDetail -Field 'requested_unit' -Expected $requestValues -Received $receivedValues
                    Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message 'request requested_unit 與命令列參數不一致。' -RequestPathValue ([string]$context.path) -Field 'requested_unit' -Detail $detail
                }
            }
            else {
                $script:RequestedUnit = if ($requestValues.Count -eq 0) { New-Object 'System.String[]' 0 } else { [string[]]$requestValues }
            }
        }
    }
    elseif ([string]$document.operation -ceq 'Cleanup') {
        foreach ($mapping in @(
                @('SourceRoot', 'source_root'),
                @('DispatchRoot', 'dispatch_root'),
                @('ResultPath', 'result_path'),
                @('PreflightResultPath', 'preflight_result_path'),
                @('RunRecordPath', 'run_record_path'),
                @('ReviewerReportPath', 'reviewer_report_path'))) {
            $requestField = [string]$mapping[1]
            if (-not [bool]$context.cleanup_field_presence[$requestField]) { continue }
            $cliField = [string]$mapping[0]
            $requestValue = [string]$context.cleanup_values[$requestField]
            if (Test-DispatchInvocationParameterBound -Name $cliField) {
                $receivedValue = [string](Get-DispatchInvocationParameterValue -Name $cliField)
                if ($receivedValue -cne $requestValue) {
                    Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message ("request {0} 與命令列參數不一致。" -f $requestField) -RequestPathValue ([string]$context.path) -Field $requestField -Detail ([ordered]@{ expected = $requestValue; received = $receivedValue; process_started = $false })
                }
            }
            else {
                Set-Variable -Name $cliField -Scope Script -Value $requestValue
            }
        }
        foreach ($mapping in @(@('ReportPath', 'report_path'), @('EvidencePath', 'evidence_path'))) {
            $cliField = [string]$mapping[0]
            $requestField = [string]$mapping[1]
            if (-not [bool]$context.cleanup_field_presence[$requestField]) { continue }
            $requestValues = @($context.cleanup_values[$requestField])
            if (Test-DispatchInvocationParameterBound -Name $cliField) {
                $receivedValues = @((Get-DispatchInvocationParameterValue -Name $cliField))
                if (-not (Compare-DispatchStringArrays -Left $requestValues -Right $receivedValues)) {
                    $detail = New-DispatchRequestArrayMismatchDetail -Field $requestField -Expected $requestValues -Received $receivedValues
                    Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message ("request {0} 與命令列參數不一致。" -f $requestField) -RequestPathValue ([string]$context.path) -Field $requestField -Detail $detail
                }
            }
            else {
                Set-Variable -Name $cliField -Scope Script -Value ([string[]]$requestValues)
            }
        }
    }
    return $context
}

function Assert-DispatchSessionMode {
    [CmdletBinding()]
    param()

    $validValues = @('cold-start', 'continuation')
    if ($validValues -contains [string]$SessionMode) {
        return
    }
    $receivedValue = if ($null -eq $SessionMode) { $null } else { [string]$SessionMode }
    if ($null -ne $script:RequestContext) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message ('request 欄位 session_mode 不支援：' + [string]$receivedValue) -RequestPathValue ([string]$script:RequestContext.path) -Field 'session_mode' -Detail ([ordered]@{ valid_values = $validValues; received = $receivedValue })
    }
    throw ('SessionMode 不支援：received={0}; valid_values={1}' -f [string]$receivedValue, ($validValues -join ', '))
}

function ConvertTo-NonNullObjectArray {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Values
    )

    $valueList = New-Object 'System.Collections.Generic.List[object]'
    if ($null -ne $Values) {
        foreach ($value in @($Values)) {
            if ($null -ne $value) {
                $valueList.Add($value)
            }
        }
    }
    return ,$valueList.ToArray()
}

function Get-DispatchRequestEvidence {
    [CmdletBinding()]
    param()

    if ($null -eq $script:RequestContext) {
        return $null
    }
    $context = $script:RequestContext
    $arrayEvidence = [ordered]@{}
    foreach ($field in @('target_path', 'add_directory', 'codex_parent_option', 'literal_values')) {
        $provided = [bool]$context.field_presence[$field]
        $valueList = New-Object 'System.Collections.Generic.List[string]'
        if ($provided) {
            foreach ($value in @($context.values[$field])) {
                if ($null -ne $value) {
                    $valueList.Add([string]$value)
                }
            }
        }
        $values = $valueList.ToArray()
        $arrayEvidence[$field] = [ordered]@{
            provided = $provided
            count    = $values.Count
            sha256   = if ($provided) { Get-DispatchStringArraySha256 -Values $values } else { $null }
            values   = $values
        }
    }
    return [ordered]@{
        schema                = $context.schema
        path                  = $context.path
        sha256                = $context.sha256
        length                = $context.length
        literal_values_sha256 = $context.literal_values_sha256
        profile               = [ordered]@{
            provided = [bool]$context.field_presence.profile
            value    = if ([bool]$context.field_presence.profile) { [string]$context.profile } else { $null }
        }
        arrays                = $arrayEvidence
        prepare_artifacts     = ConvertTo-NonNullObjectArray -Values $context.prepare_artifacts
        dispatch              = [ordered]@{
            field_presence = $context.dispatch_field_presence
            values         = $context.dispatch_values
        }
    }
}

function ConvertTo-DispatchTimestamp {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    $parsed = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return $null
    }
    return $parsed.ToUniversalTime()
}

function Get-RuntimeModelEvidence {
    param(
        [string]$CodexHome,

        [string]$ThreadId,

        [string]$StartedAtUtc
    )

    $modelUnknown = New-UnknownDispatchEvidence -Field 'payload.model' -Reason '尚未找到與本 thread 對應的 rollout turn_context。' -Source 'rollout-not-observed'
    $effortUnknown = New-UnknownDispatchEvidence -Field 'payload.effort' -Reason '尚未找到與本 thread 對應的 rollout turn_context。' -Source 'rollout-not-observed'
    if ([string]::IsNullOrWhiteSpace($CodexHome) -or [string]::IsNullOrWhiteSpace($ThreadId)) {
        return [ordered]@{ model = $modelUnknown; reasoning_effort = $effortUnknown; rollout_paths = @() }
    }
    $started = ConvertTo-DispatchTimestamp -Value $StartedAtUtc
    if ($null -eq $started) {
        $reason = 'started_at_utc 缺失或無法解析，無法判定 turn_context 時間範圍。'
        return [ordered]@{
            model = New-UnknownDispatchEvidence -Field 'payload.model' -Reason $reason -Source 'rollout-time-unknown'
            reasoning_effort = New-UnknownDispatchEvidence -Field 'payload.effort' -Reason $reason -Source 'rollout-time-unknown'
            rollout_paths = @()
        }
    }

    $matchedFiles = New-Object System.Collections.Generic.List[object]
    $modelValues = New-Object System.Collections.Generic.List[object]
    $effortValues = New-Object System.Collections.Generic.List[object]
    $modelMissing = $false
    $effortMissing = $false
    $turnContextFound = $false
    $timeUnknown = $false
    try {
        $rolloutFiles = @(Get-QuotaProbeRolloutFiles -CodexHomePath (Resolve-AbsolutePath -Path $CodexHome))
    }
    catch {
        $reason = 'rollout 掃描失敗：' + $_.Exception.Message
        return [ordered]@{
            model = New-UnknownDispatchEvidence -Field 'payload.model' -Reason $reason -Source 'rollout-scan-failed'
            reasoning_effort = New-UnknownDispatchEvidence -Field 'payload.effort' -Reason $reason -Source 'rollout-scan-failed'
            rollout_paths = @()
        }
    }

    foreach ($file in $rolloutFiles) {
        $sessionMatched = $false
        $fileEvents = New-Object System.Collections.Generic.List[object]
        $lineNumber = 0
        try {
            foreach ($rawLine in Get-Content -LiteralPath $file.Path -Encoding UTF8 -ErrorAction Stop) {
                $lineNumber++
                if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
                try { $event = ConvertFrom-DispatchJson -Content $rawLine } catch { continue }
                $fileEvents.Add([pscustomobject]@{ Event = $event; Line = $lineNumber; Raw = $rawLine })
                $type = [string](Get-DispatchJsonProperty -Object $event -Name 'type')
                if ($type -eq 'session_meta') {
                    $payload = Get-DispatchJsonProperty -Object $event -Name 'payload'
                    $sessionId = [string](Get-DispatchJsonProperty -Object $payload -Name 'session_id')
                    if ([string]::IsNullOrWhiteSpace($sessionId)) {
                        $sessionId = [string](Get-DispatchJsonProperty -Object $payload -Name 'id')
                    }
                    if ($sessionId -ceq $ThreadId) { $sessionMatched = $true }
                }
            }
        }
        catch {
            continue
        }
        if (-not $sessionMatched) { continue }
        $matchedFiles.Add($file)
        foreach ($entry in $fileEvents) {
            $type = [string](Get-DispatchJsonProperty -Object $entry.Event -Name 'type')
            if ($type -ne 'turn_context') { continue }
            $timestampValue = Get-DispatchJsonProperty -Object $entry.Event -Name 'timestamp'
            if ($null -eq $timestampValue) { $timestampValue = Get-DispatchJsonProperty -Object $entry.Event -Name 'created_at_utc' }
            if ($null -eq $timestampValue) { $timestampValue = Get-DispatchJsonProperty -Object $entry.Event -Name 'created_at' }
            $turnTime = ConvertTo-DispatchTimestamp -Value $timestampValue
            if ($null -eq $turnTime) { $timeUnknown = $true; continue }
            if ($turnTime -le $started) { continue }
            $turnContextFound = $true
            $payload = Get-DispatchJsonProperty -Object $entry.Event -Name 'payload'
            $modelValue = [string](Get-DispatchJsonProperty -Object $payload -Name 'model')
            $effortValue = [string](Get-DispatchJsonProperty -Object $payload -Name 'effort')
            if ([string]::IsNullOrWhiteSpace($modelValue)) { $modelMissing = $true } else { $modelValues.Add([pscustomobject]@{ Value = $modelValue; File = $file.Path; Line = $entry.Line }) }
            if ([string]::IsNullOrWhiteSpace($effortValue)) { $effortMissing = $true } else { $effortValues.Add([pscustomobject]@{ Value = $effortValue; File = $file.Path; Line = $entry.Line }) }
        }
    }

    $rolloutPaths = @($matchedFiles | ForEach-Object { $_.Path } | Sort-Object -Unique)
    $firstFile = if ($matchedFiles.Count -gt 0) { $matchedFiles[0] } else { $null }
    $firstHash = if ($null -ne $firstFile) { Get-FileSha256 -Path $firstFile.Path } else { $null }
    $createValueEvidence = {
        param($Field, $Values, $Missing, $PayloadField)
        if ($matchedFiles.Count -eq 0) {
            return New-UnknownDispatchEvidence -Field $PayloadField -Reason '沒有 rollout 的 exact session ID。' -Source 'rollout-session-not-found'
        }
        if (-not $turnContextFound -or $timeUnknown) {
            return New-UnknownDispatchEvidence -Field $PayloadField -Reason 'rollout 缺少可判定時間範圍的 turn_context。' -Source 'rollout-time-unknown' -Path (if ($null -eq $firstFile) { $null } else { $firstFile.Path }) -Sha256 $firstHash
        }
        if ($Missing -or $Values.Count -eq 0) {
            return New-UnknownDispatchEvidence -Field $PayloadField -Reason 'turn_context 欄位缺失。' -Source 'rollout-field-missing' -Path (if ($null -eq $firstFile) { $null } else { $firstFile.Path }) -Sha256 $firstHash
        }
        $first = $Values[0]
        foreach ($valueEntry in $Values) {
            if ($valueEntry.Value -cne $first.Value) {
                return New-UnknownDispatchEvidence -Field $PayloadField -Reason '多筆 turn_context 值衝突。' -Source 'rollout-values-conflict' -Path $first.File -Line ([int]$first.Line) -Sha256 (Get-FileSha256 -Path $first.File)
            }
        }
        $evidence = New-ConfirmedDispatchEvidence -Value $first.Value -Source 'rollout' -Field $PayloadField -Path $first.File -Line ([int]$first.Line) -Sha256 (Get-FileSha256 -Path $first.File)
        $evidence.source_paths = @($rolloutPaths)
        return $evidence
    }
    return [ordered]@{
        model = & $createValueEvidence 'model' $modelValues $modelMissing 'payload.model'
        reasoning_effort = & $createValueEvidence 'reasoning_effort' $effortValues $effortMissing 'payload.effort'
        rollout_paths = $rolloutPaths
    }
}

function Get-OriginalThreadModelEvidence {
    param(
        [AllowNull()]
        [object]$AnchorRecord,

        [string]$AnchorEventStreamPath
    )

    $eventPath = $AnchorEventStreamPath
    if ([string]::IsNullOrWhiteSpace($eventPath) -and $null -ne $AnchorRecord) {
        $eventPath = [string](Get-DispatchJsonProperty -Object $AnchorRecord -Name 'event_stream_path')
    }
    if ([string]::IsNullOrWhiteSpace($eventPath)) {
        return New-UnknownDispatchEvidence -Field 'original_thread_model' -Reason 'anchor 缺少 event stream 路徑。' -Source 'event-stream-missing'
    }
    $fullPath = Resolve-AbsolutePath -Path $eventPath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return New-UnknownDispatchEvidence -Field 'original_thread_model' -Reason 'anchor event stream 不存在。' -Source 'event-stream-missing' -Path $fullPath
    }
    $values = New-Object System.Collections.Generic.List[object]
    $lineNumber = 0
    foreach ($rawLine in Get-Content -LiteralPath $fullPath -Encoding UTF8) {
        $lineNumber++
        if ($rawLine -match '(?i)recorded\s+with\s+model\s+(?<model>[A-Za-z0-9._-]+)') {
            $values.Add([pscustomobject]@{ Value = $Matches['model']; Line = $lineNumber; Raw = $rawLine })
        }
    }
    $uniqueValues = @($values | ForEach-Object Value | Sort-Object -Unique)
    $hash = Get-FileSha256 -Path $fullPath
    if ($uniqueValues.Count -eq 1) {
        $first = $values[0]
        $evidence = New-ConfirmedDispatchEvidence -Value $uniqueValues[0] -Source 'event-stream-diagnostic' -Field 'original_thread_model' -Path $fullPath -Line ([int]$first.Line) -Sha256 $hash
        $evidence.raw_line = $first.Raw
        return $evidence
    }
    if ($uniqueValues.Count -gt 1) {
        return New-UnknownDispatchEvidence -Field 'original_thread_model' -Reason 'event stream diagnostic 包含多個衝突的 recorded model。' -Source 'event-stream-diagnostic-conflict' -Path $fullPath -Sha256 $hash
    }
    return New-UnknownDispatchEvidence -Field 'original_thread_model' -Reason 'event stream 沒有可解析的 recorded with model diagnostic。' -Source 'event-stream-diagnostic-missing' -Path $fullPath -Sha256 $hash
}

function Compare-ResumeThreadModel {
    param(
        [Parameter(Mandatory)]
        [psobject]$AnchorRecord,

        [Parameter(Mandatory)]
        [psobject]$CurrentModelEvidence,

        [string]$CodexHome
    )

    $current = ConvertTo-DispatchEvidence -Evidence $CurrentModelEvidence -Field 'model'
    $original = New-UnknownDispatchEvidence -Field 'original_thread_model' -Reason 'anchor 沒有可驗證的 runtime model。' -Source 'anchor-evidence-unknown'
    $recordEvidence = Get-DispatchJsonProperty -Object $AnchorRecord -Name 'model_evidence'
    if ($null -ne $recordEvidence) {
        $runtimeEvidence = Get-DispatchJsonProperty -Object $recordEvidence -Name 'runtime_verifiable'
        if ($null -ne $runtimeEvidence -and (Get-DispatchEvidenceValue -Evidence $runtimeEvidence)) {
            $original = ConvertTo-DispatchEvidence -Evidence $runtimeEvidence -Field 'payload.model'
        }
    }
    if ($null -eq (Get-DispatchEvidenceValue -Evidence $original)) {
        $anchorThread = [string](Get-DispatchJsonProperty -Object $AnchorRecord -Name 'thread_id')
        $anchorStarted = [string](Get-DispatchJsonProperty -Object $AnchorRecord -Name 'started_at_utc')
        $runtime = Get-RuntimeModelEvidence -CodexHome $CodexHome -ThreadId $anchorThread -StartedAtUtc $anchorStarted
        if ($null -ne $runtime -and (Get-DispatchEvidenceValue -Evidence $runtime.model)) {
            $original = $runtime.model
        }
    }
    if ($null -eq (Get-DispatchEvidenceValue -Evidence $original)) {
        $original = Get-OriginalThreadModelEvidence -AnchorRecord $AnchorRecord
    }
    $originalValue = Get-DispatchEvidenceValue -Evidence $original
    $currentValue = Get-DispatchEvidenceValue -Evidence $current
    $status = 'unknown'
    $reasonCode = 'ThreadModelUnknown'
    if ($null -ne $originalValue -and $null -ne $currentValue) {
        if ([string]::Equals($originalValue, $currentValue, [StringComparison]::Ordinal)) {
            $status = 'match'
            $reasonCode = 'None'
        }
        else {
            $status = 'mismatch'
            $reasonCode = 'ThreadModelMismatch'
        }
    }
    return [ordered]@{
        status = $status
        reason_code = $reasonCode
        original_thread_model = $originalValue
        current_resolved_model = $currentValue
        original_evidence = $original
        current_evidence = $current
        process_started = $false
    }
}

function Test-RequiredOutputSections {
    param(
        [AllowNull()]
        [string]$Message,

        [AllowNull()]
        [object[]]$RequiredOutput
    )

    $required = @($RequiredOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $present = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]
    $duplicates = New-Object System.Collections.Generic.List[string]
    $details = New-Object System.Collections.Generic.List[object]
    foreach ($heading in $required) {
        $headingMatch = [regex]::Match($heading, '^(?<level>#{1,6})[ \t]+')
        $headingLevel = 6
        if ($headingMatch.Success) {
            $headingLevel = $headingMatch.Groups['level'].Value.Length
        }
        $bodyTerminator = '^#{1,' + $headingLevel + '}[ \t]+'
        $pattern = '(?ms)^' + [regex]::Escape($heading) + '[ \t]*\r?\n(?<body>.*?)(?=' + $bodyTerminator + '|\z)'
        $matches = [regex]::Matches([string]$Message, $pattern)
        if ($matches.Count -eq 0) {
            $missing.Add($heading)
            $details.Add([ordered]@{ heading = $heading; present = $false; body_non_empty = $false })
            continue
        }
        if ($matches.Count -gt 1) { $duplicates.Add($heading) }
        $body = $matches[0].Groups['body'].Value.Trim()
        $present.Add($heading)
        $details.Add([ordered]@{ heading = $heading; present = $true; body_non_empty = -not [string]::IsNullOrWhiteSpace($body) })
        if ([string]::IsNullOrWhiteSpace($body)) { $missing.Add($heading) }
    }
    return [ordered]@{
        valid = $missing.Count -eq 0 -and $duplicates.Count -eq 0
        required = @($required)
        present = @($present.ToArray())
        missing = @($missing.ToArray() | Sort-Object -Unique)
        duplicate = @($duplicates.ToArray() | Sort-Object -Unique)
        sections = @($details.ToArray())
    }
}

function New-AdvisorInlineEvidenceDirective {
    param(
        [Parameter(Mandatory)]
        [psobject]$EvidencePackInfo
    )

    $content = [string]$EvidencePackInfo.content
    $contentWithLineBreak = $content
    if (-not $contentWithLineBreak.EndsWith("`n", [StringComparison]::Ordinal)) {
        $contentWithLineBreak += "`r`n"
    }
    return ('[advisor evidence-only]' + "`r`n" +
        'evidence-pack-sha256=' + [string]$EvidencePackInfo.sha256 + "`r`n" +
        'evidence-pack-length=' + [string]$EvidencePackInfo.length + "`r`n" +
        '---BEGIN INLINE EVIDENCE PACK---' + "`r`n" +
        $contentWithLineBreak +
        '---END INLINE EVIDENCE PACK---' + "`r`n" +
        '執行端只能依上述 inline evidence pack 回答。禁止 repository 探索、檔案掃描、檔案變更與外部派遣。')
}

function Test-AdvisorInlineEvidenceDirective {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$PromptContent,

        [Parameter(Mandatory)]
        [psobject]$EvidencePackInfo
    )

    $content = [string]$EvidencePackInfo.content
    $hashMarker = 'evidence-pack-sha256=' + [string]$EvidencePackInfo.sha256
    $lengthMarker = 'evidence-pack-length=' + [string]$EvidencePackInfo.length
    $beginMarker = '---BEGIN INLINE EVIDENCE PACK---'
    $endMarker = '---END INLINE EVIDENCE PACK---'
    $hasMarkers = $PromptContent.Contains('[advisor evidence-only]') -and
        $PromptContent.Contains($hashMarker) -and
        $PromptContent.Contains($lengthMarker) -and
        $PromptContent.Contains($beginMarker) -and
        $PromptContent.Contains($endMarker)
    $hasFullContent = $PromptContent.Contains($content)
    return [ordered]@{
        valid = $hasMarkers -and $hasFullContent
        has_markers = $hasMarkers
        has_full_content = $hasFullContent
        expected_sha256 = [string]$EvidencePackInfo.sha256
        expected_length = [int64]$EvidencePackInfo.length
        reason = if ($hasMarkers -and $hasFullContent) { $null } else { 'prompt 缺少完整 evidence pack、hash、length 或 inline marker。' }
    }
}

function Get-ReviewerPropertyValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Test-ReviewerJsonArray {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $false
    }
    $value = $property.Value
    return $null -ne $value -and $value -is [System.Collections.IEnumerable] -and $value -isnot [string] -and $value -isnot [System.Collections.IDictionary]
}

function Get-ReviewerDeclaredCount {
    param(
        [AllowNull()]
        [object]$Counts,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Inconsistencies
    )

    $property = if ($null -eq $Counts) { $null } else { $Counts.PSObject.Properties[$Name] }
    if ($null -eq $property) {
        $Inconsistencies.Add('counts.' + $Name + ' missing')
        return $null
    }

    try {
        $value = [int64]$property.Value
    }
    catch {
        $Inconsistencies.Add('counts.' + $Name + ' is not an integer')
        return $null
    }
    if ($value -lt 0) {
        $Inconsistencies.Add('counts.' + $Name + ' is negative')
        return $null
    }
    return $value
}

function ConvertTo-ReviewerJudgmentStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    switch -Regex ($Value.Trim().ToLowerInvariant()) {
        '^(closed|已閉合)$' { return 'closed' }
        '^(open|未閉合)$' { return 'open' }
        '^(withdrawn|撤回)$' { return 'withdrawn' }
        default { return $null }
    }
}

function Test-ReviewerAbsolutePath {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathRooted($Path)) {
        return $false
    }
    if (Test-IsWindowsPlatform) {
        return $Path -match '^(?:[A-Za-z]:[\\/]|\\\\)'
    }
    return $true
}

function Get-ReviewerBodyJudgment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Content
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $entries = New-Object System.Collections.Generic.List[object]
    $sectionMatches = [regex]::Matches($Content, '(?ms)^##[ \t]+本輪 finding 判定[ \t]*\r?\n(?<section>.*?)(?=^##[ \t]|\z)')
    if ($sectionMatches.Count -ne 1) {
        $errors.Add(('current judgment prose section count={0}' -f $sectionMatches.Count))
        return [ordered]@{ present = $false; entries = @(); errors = @($errors) }
    }

    $seen = @{}
    foreach ($line in [regex]::Split($sectionMatches[0].Groups['section'].Value, '\r?\n')) {
        $idMatch = [regex]::Match($line, '\[(?<id>F-[0-9]{3})\]')
        if (-not $idMatch.Success) {
            continue
        }

        $id = $idMatch.Groups['id'].Value
        $statusMatch = [regex]::Match($line, '(?i)(?<![A-Za-z])(?<status>closed|open|withdrawn|已閉合|未閉合|撤回)(?![A-Za-z])')
        $status = if ($statusMatch.Success) { ConvertTo-ReviewerJudgmentStatus -Value $statusMatch.Groups['status'].Value } else { $null }
        if ($null -eq $status) {
            $errors.Add($id + ' current judgment prose status missing')
        }

        $severityMatch = [regex]::Match($line, '(?:\[(?<bracket>Critical|Major|Minor)\]|（(?<full>Critical|Major|Minor)）)')
        $severity = if ($severityMatch.Success) {
            if (-not [string]::IsNullOrWhiteSpace($severityMatch.Groups['bracket'].Value)) { $severityMatch.Groups['bracket'].Value } else { $severityMatch.Groups['full'].Value }
        }
        else {
            $null
        }
        if ($null -eq $severity) {
            $errors.Add($id + ' current judgment prose severity missing')
        }

        $evidenceMatch = [regex]::Match($line, '(?i)(?:evidence|證據)[ \t]*[:：][ \t]*(?<path>.+?)(?::(?<line>[0-9]+))[ \t]*$')
        $evidencePath = if ($evidenceMatch.Success) { $evidenceMatch.Groups['path'].Value.Trim() } else { $null }
        $evidenceLine = [int64]0
        $hasEvidenceLine = $evidenceMatch.Success -and [int64]::TryParse($evidenceMatch.Groups['line'].Value, [ref]$evidenceLine) -and $evidenceLine -gt 0
        if (-not $hasEvidenceLine -or [string]::IsNullOrWhiteSpace($evidencePath)) {
            $errors.Add($id + ' current judgment prose evidence missing')
        }
        elseif (-not (Test-ReviewerAbsolutePath -Path $evidencePath)) {
            $errors.Add($id + ' current judgment prose evidence path must be absolute')
        }

        $entry = [pscustomobject]@{
            id = $id
            status = $status
            severity = $severity
            evidence = if ($hasEvidenceLine) { @([ordered]@{ path = $evidencePath; line = $evidenceLine }) } else { @() }
        }
        if ($seen.ContainsKey($id)) {
            $previous = $seen[$id]
            if ($previous.status -cne $entry.status -or $previous.severity -cne $entry.severity -or (ConvertTo-Json -InputObject $previous.evidence -Compress) -cne (ConvertTo-Json -InputObject $entry.evidence -Compress)) {
                $errors.Add($id + ' current judgment prose duplicate fields conflict')
            }
        }
        else {
            $seen[$id] = $entry
            $entries.Add($entry)
        }
    }

    return [ordered]@{
        present = $true
        entries = @($entries.ToArray())
        errors = @($errors)
    }
}

function Test-ReviewerFindingReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $fullPath = Resolve-AbsolutePath -Path $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Reviewer report 不存在：$fullPath"
    }

    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $content = $utf8.GetString([System.IO.File]::ReadAllBytes($fullPath))
    }
    catch {
        throw "Reviewer report 無法讀取：$fullPath；$($_.Exception.Message)"
    }
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Reviewer report 為空：$fullPath"
    }

    $inconsistencies = New-Object System.Collections.Generic.List[string]
    $overviewMatches = [regex]::Matches($content, '(?m)^##[ \t]+總覽[ \t]*\r?$')
    $manifestMatches = [regex]::Matches($content, '(?m)^##[ \t]+Finding manifest[ \t]*\r?$')
    if ($overviewMatches.Count -ne 1) {
        $inconsistencies.Add(('overview heading count={0}' -f $overviewMatches.Count))
    }
    if ($manifestMatches.Count -ne 1) {
        $inconsistencies.Add(('Finding manifest heading count={0}' -f $manifestMatches.Count))
    }
    if ($overviewMatches.Count -eq 1 -and $manifestMatches.Count -eq 1 -and $manifestMatches[0].Index -lt $overviewMatches[0].Index) {
        $inconsistencies.Add('Finding manifest must follow 總覽')
    }

    $manifest = $null
    $manifestSection = ''
    if ($manifestMatches.Count -eq 1) {
        $manifestStart = $manifestMatches[0].Index + $manifestMatches[0].Length
        $remaining = $content.Substring($manifestStart)
        $nextHeading = [regex]::Match($remaining, '(?m)^##[ \t]+')
        if ($nextHeading.Success) {
            $manifestSection = $remaining.Substring(0, $nextHeading.Index)
        }
        else {
            $manifestSection = $remaining
        }

        $jsonBlocks = [regex]::Matches($manifestSection, '(?ms)^```json[ \t]*\r?\n(?<json>.*?)^```[ \t]*\r?$')
        $fenceLines = [regex]::Matches($manifestSection, '(?m)^```')
        if ($jsonBlocks.Count -ne 1 -or $fenceLines.Count -ne 2) {
            $inconsistencies.Add(('Finding manifest JSON block count={0}; fence line count={1}' -f $jsonBlocks.Count, $fenceLines.Count))
        }
        elseif ($jsonBlocks.Count -eq 1) {
            try {
                $manifest = ConvertFrom-DispatchJson -Content $jsonBlocks[0].Groups['json'].Value.Trim()
            }
            catch {
                $inconsistencies.Add('Finding manifest JSON parse failed: ' + $_.Exception.Message)
            }
        }
    }

    $currentEntries = @()
    $previousEntries = @()
    $currentJudgmentEntries = @()
    $currentJudgmentSeen = @{}
    $currentJudgmentExplicit = $false
    $currentJudgmentAdapter = $false
    $manifestSchema = [string](Get-ReviewerPropertyValue -Object $manifest -Name 'schema')
    $manifestLineSlug = [string](Get-ReviewerPropertyValue -Object $manifest -Name 'line_slug')
    $manifestDispatchSlug = [string](Get-ReviewerPropertyValue -Object $manifest -Name 'dispatch_slug')
    $manifestRound = Get-ReviewerPropertyValue -Object $manifest -Name 'round'
    $manifestRoundValue = $null
    $currentSeen = @{}
    $previousSeen = @{}
    $duplicateIds = New-Object System.Collections.Generic.List[string]
    if ($null -ne $manifest) {
        if ($manifestSchema -notin @('codex-dispatch.review-findings.v1', 'codex-dispatch.review-findings.v2')) {
            $inconsistencies.Add('schema must be codex-dispatch.review-findings.v1 or codex-dispatch.review-findings.v2')
        }
        if ($manifestSchema -ceq 'codex-dispatch.review-findings.v2') {
            if ([string]::IsNullOrWhiteSpace($manifestLineSlug)) {
                $inconsistencies.Add('line_slug missing')
            }
            elseif ($manifestLineSlug -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
                $inconsistencies.Add('line_slug invalid: ' + $manifestLineSlug)
            }
            if ([string]::IsNullOrWhiteSpace($manifestDispatchSlug)) {
                $inconsistencies.Add('dispatch_slug missing')
            }
            elseif ($manifestDispatchSlug -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
                $inconsistencies.Add('dispatch_slug invalid: ' + $manifestDispatchSlug)
            }
            $roundValue = [int64]0
            if ($null -eq $manifestRound -or -not [int64]::TryParse([string]$manifestRound, [ref]$roundValue) -or $roundValue -lt 1) {
                $inconsistencies.Add('round must be a positive integer')
            }
            else {
                $manifestRoundValue = $roundValue
            }
        }
        if (-not (Test-ReviewerJsonArray -Object $manifest -Name 'current_findings')) {
            $inconsistencies.Add('current_findings must be an array')
        }
        else {
            $currentEntries = @($manifest.PSObject.Properties['current_findings'].Value)
        }
        if (-not (Test-ReviewerJsonArray -Object $manifest -Name 'previous_status')) {
            $inconsistencies.Add('previous_status must be an array')
        }
        else {
            $previousEntries = @($manifest.PSObject.Properties['previous_status'].Value)
        }

        $currentJudgmentProperty = $manifest.PSObject.Properties['current_judgment']
        if ($null -ne $currentJudgmentProperty) {
            $currentJudgmentExplicit = $true
            if (-not (Test-ReviewerJsonArray -Object $manifest -Name 'current_judgment')) {
                $inconsistencies.Add('current_judgment must be an array')
            }
            else {
                $currentJudgmentEntries = @($currentJudgmentProperty.Value)
            }
        }
        elseif ($manifestSchema -ceq 'codex-dispatch.review-findings.v2') {
            $inconsistencies.Add('current_judgment must be present for v2')
        }

        foreach ($entry in $currentEntries) {
            if ($null -eq $entry -or $entry -isnot [pscustomobject]) {
                $inconsistencies.Add('current_findings contains a non-object entry')
                continue
            }
            $id = [string](Get-ReviewerPropertyValue -Object $entry -Name 'id')
            $axis = [string](Get-ReviewerPropertyValue -Object $entry -Name 'axis')
            $status = [string](Get-ReviewerPropertyValue -Object $entry -Name 'status')
            $severity = [string](Get-ReviewerPropertyValue -Object $entry -Name 'severity')
            $disposition = [string](Get-ReviewerPropertyValue -Object $entry -Name 'disposition')
            $summary = [string](Get-ReviewerPropertyValue -Object $entry -Name 'summary')
            if ($id -notmatch '^F-[0-9]{3}$') { $inconsistencies.Add('current finding ID invalid: ' + $id); continue }
            if ($axis -notin @('Standards', 'Spec')) { $inconsistencies.Add($id + ' axis invalid: ' + $axis) }
            if ($status -cne 'open') { $inconsistencies.Add($id + ' current status must be open') }
            if ($severity -notin @('Critical', 'Major', 'Minor')) { $inconsistencies.Add($id + ' severity invalid: ' + $severity) }
            if ($disposition -notin @('new', 'carried')) { $inconsistencies.Add($id + ' disposition invalid: ' + $disposition) }
            if ([string]::IsNullOrWhiteSpace($summary)) { $inconsistencies.Add($id + ' summary missing') }
            $normalizedEntry = [pscustomobject]@{ id = $id; status = $status; severity = $severity; disposition = $disposition }
            if ($currentSeen.ContainsKey($id)) {
                $duplicateIds.Add($id)
                $previousEntry = $currentSeen[$id]
                if ($previousEntry.status -cne $status -or $previousEntry.severity -cne $severity -or $previousEntry.disposition -cne $disposition) {
                    $inconsistencies.Add($id + ' duplicate fields conflict')
                }
            }
            else {
                $currentSeen[$id] = $normalizedEntry
            }
        }

        foreach ($entry in $previousEntries) {
            if ($null -eq $entry -or $entry -isnot [pscustomobject]) {
                $inconsistencies.Add('previous_status contains a non-object entry')
                continue
            }
            $id = [string](Get-ReviewerPropertyValue -Object $entry -Name 'id')
            $status = [string](Get-ReviewerPropertyValue -Object $entry -Name 'status')
            $severity = [string](Get-ReviewerPropertyValue -Object $entry -Name 'severity')
            if ($id -notmatch '^F-[0-9]{3}$') { $inconsistencies.Add('previous finding ID invalid: ' + $id); continue }
            if ($status -notin @('closed', 'open', 'withdrawn')) { $inconsistencies.Add($id + ' previous status invalid: ' + $status) }
            if ($severity -notin @('Critical', 'Major', 'Minor')) { $inconsistencies.Add($id + ' previous severity invalid: ' + $severity) }
            $normalizedEntry = [pscustomobject]@{ id = $id; status = $status; severity = $severity }
            if ($previousSeen.ContainsKey($id)) {
                $previousEntry = $previousSeen[$id]
                if ($previousEntry.status -cne $status -or $previousEntry.severity -cne $severity) {
                    $inconsistencies.Add($id + ' previous duplicate fields conflict')
                }
            }
            else {
                $previousSeen[$id] = $normalizedEntry
            }
        }

        foreach ($entry in $currentJudgmentEntries) {
            if ($null -eq $entry -or $entry -isnot [pscustomobject]) {
                $inconsistencies.Add('current_judgment contains a non-object entry')
                continue
            }
            $id = [string](Get-ReviewerPropertyValue -Object $entry -Name 'id')
            $status = [string](Get-ReviewerPropertyValue -Object $entry -Name 'status')
            $severity = [string](Get-ReviewerPropertyValue -Object $entry -Name 'severity')
            $evidence = Get-ReviewerPropertyValue -Object $entry -Name 'evidence'
            if ($id -notmatch '^F-[0-9]{3}$') { $inconsistencies.Add('current judgment ID invalid: ' + $id); continue }
            if ($status -notin @('closed', 'open', 'withdrawn')) { $inconsistencies.Add($id + ' current judgment status invalid: ' + $status) }
            if ($severity -notin @('Critical', 'Major', 'Minor')) { $inconsistencies.Add($id + ' current judgment severity invalid: ' + $severity) }
            if ($null -eq $evidence -or $evidence -is [string] -or $evidence -is [System.Collections.IDictionary]) {
                $inconsistencies.Add($id + ' current judgment evidence must be an array')
                $evidence = @()
            }
            $normalizedEvidence = New-Object System.Collections.Generic.List[object]
            foreach ($position in @($evidence)) {
                $positionPath = [string](Get-ReviewerPropertyValue -Object $position -Name 'path')
                $positionLine = [int64]0
                $positionLineValue = Get-ReviewerPropertyValue -Object $position -Name 'line'
                if ([string]::IsNullOrWhiteSpace($positionPath) -or $null -eq $positionLineValue -or -not [int64]::TryParse([string]$positionLineValue, [ref]$positionLine) -or $positionLine -lt 1) {
                    $inconsistencies.Add($id + ' current judgment evidence position invalid')
                    continue
                }
                if (-not (Test-ReviewerAbsolutePath -Path $positionPath)) {
                    $inconsistencies.Add($id + ' current judgment evidence path must be absolute')
                    continue
                }
                $normalizedEvidence.Add([ordered]@{ path = $positionPath; line = $positionLine })
            }
            if ($normalizedEvidence.Count -eq 0) {
                $inconsistencies.Add($id + ' current judgment evidence missing')
            }
            $normalizedEntry = [pscustomobject]@{ id = $id; status = $status; severity = $severity; evidence = @($normalizedEvidence.ToArray()) }
            if ($currentJudgmentSeen.ContainsKey($id)) {
                $previousEntry = $currentJudgmentSeen[$id]
                if ((ConvertTo-Json -InputObject $previousEntry -Compress) -cne (ConvertTo-Json -InputObject $normalizedEntry -Compress)) {
                    $inconsistencies.Add($id + ' current judgment duplicate fields conflict')
                }
            }
            else {
                $currentJudgmentSeen[$id] = $normalizedEntry
            }
        }
    }

    foreach ($id in @($currentSeen.Keys)) {
        $current = $currentSeen[$id]
        $previous = if ($previousSeen.ContainsKey($id)) { $previousSeen[$id] } else { $null }
        if ($current.disposition -ceq 'carried' -and ($null -eq $previous -or $previous.status -cne 'open')) {
            $inconsistencies.Add($id + ' carried finding must have previous open status')
        }
        if ($current.disposition -ceq 'carried' -and $null -ne $previous -and $current.severity -cne $previous.severity) {
            $inconsistencies.Add($id + ' carried finding severity conflicts with previous_status')
        }
        if ($current.disposition -ceq 'new' -and $null -ne $previous) {
            $inconsistencies.Add($id + ' new finding must not appear in previous_status')
        }
        if ($null -ne $previous -and $previous.status -in @('closed', 'withdrawn')) {
            $inconsistencies.Add($id + ' closed or withdrawn finding cannot be current')
        }
    }

    $judgmentBody = [ordered]@{ present = $false; entries = @(); errors = @() }
    if ($manifestSchema -ceq 'codex-dispatch.review-findings.v2' -or $currentJudgmentExplicit) {
        $judgmentBody = Get-ReviewerBodyJudgment -Content $content
        foreach ($error in @($judgmentBody.errors)) {
            $inconsistencies.Add([string]$error)
        }
        $bodySeen = @{}
        foreach ($entry in @($judgmentBody.entries)) {
            $bodySeen[[string]$entry.id] = $entry
        }
        foreach ($id in @($currentJudgmentSeen.Keys)) {
            if (-not $bodySeen.ContainsKey($id)) {
                $inconsistencies.Add('current judgment missing from prose: ' + $id)
                continue
            }
            $manifestEntry = $currentJudgmentSeen[$id]
            $bodyEntry = $bodySeen[$id]
            if ($manifestEntry.status -cne $bodyEntry.status) { $inconsistencies.Add($id + ' current judgment prose status conflicts with manifest') }
            if ($manifestEntry.severity -cne $bodyEntry.severity) { $inconsistencies.Add($id + ' current judgment prose severity conflicts with manifest') }
            $manifestEvidence = @($manifestEntry.evidence)
            $bodyEvidence = @($bodyEntry.evidence)
            $evidenceMatches = $manifestEvidence.Count -eq $bodyEvidence.Count
            if ($evidenceMatches) {
                for ($index = 0; $index -lt $manifestEvidence.Count; $index++) {
                    $manifestPosition = $manifestEvidence[$index]
                    $bodyPosition = $bodyEvidence[$index]
                    $manifestPath = [string](Get-ReviewerPropertyValue -Object $manifestPosition -Name 'path')
                    $bodyPath = [string](Get-ReviewerPropertyValue -Object $bodyPosition -Name 'path')
                    $manifestLine = [int64](Get-ReviewerPropertyValue -Object $manifestPosition -Name 'line')
                    $bodyLine = [int64](Get-ReviewerPropertyValue -Object $bodyPosition -Name 'line')
                    if ($manifestPath -cne $bodyPath -or $manifestLine -ne $bodyLine) {
                        $evidenceMatches = $false
                        break
                    }
                }
            }
            if (-not $evidenceMatches) { $inconsistencies.Add($id + ' current judgment prose evidence conflicts with manifest') }
        }
        foreach ($id in @($bodySeen.Keys)) {
            if (-not $currentJudgmentSeen.ContainsKey($id)) {
                $inconsistencies.Add('current judgment prose missing from manifest: ' + $id)
            }
        }

    }

    $previousProseEntries = @{}
    $previousProseMatches = [regex]::Matches($content, '(?ms)^##[ \t]+前輪 finding 狀態(?:[ \t]*（[^\r\n]*）)?[ \t]*\r?\n(?<section>.*?)(?=^##[ \t]|\z)')
    if ($previousProseMatches.Count -gt 1) {
        $inconsistencies.Add(('previous prose section count={0}' -f $previousProseMatches.Count))
    }
    if ($previousProseMatches.Count -eq 1) {
        $previousHeadingLine = 1 + ([regex]::Matches($content.Substring(0, $previousProseMatches[0].Index), '\r?\n')).Count
        $previousSectionLineOffset = 1
        foreach ($line in [regex]::Split($previousProseMatches[0].Groups['section'].Value, '\r?\n')) {
            $previousEvidenceLine = $previousHeadingLine + $previousSectionLineOffset
            $previousSectionLineOffset++
            $idMatch = [regex]::Match($line, '\[(?<id>F-[0-9]{3})\]')
            if (-not $idMatch.Success) {
                continue
            }
            $id = $idMatch.Groups['id'].Value
            $statusMatch = [regex]::Match($line, '(?<status>已閉合|未閉合|撤回)')
            $severityMatch = [regex]::Match($line, '(?:\[(?<bracket>Critical|Major|Minor)\]|（(?<full>Critical|Major|Minor)）)')
            $status = $null
            if ($statusMatch.Success) {
                $status = switch ($statusMatch.Groups['status'].Value) {
                    '已閉合' { 'closed' }
                    '未閉合' { 'open' }
                    '撤回' { 'withdrawn' }
                }
            }
            $severity = $null
            if ($severityMatch.Success) {
                $severity = if (-not [string]::IsNullOrWhiteSpace($severityMatch.Groups['bracket'].Value)) { $severityMatch.Groups['bracket'].Value } else { $severityMatch.Groups['full'].Value }
            }
            if ($null -eq $status) {
                $inconsistencies.Add($id + ' previous prose status missing')
            }
            if ($null -eq $severity) {
                $inconsistencies.Add($id + ' previous prose severity missing')
            }
            $normalizedEntry = [pscustomobject]@{
                id = $id
                status = $status
                severity = $severity
                evidence = if ($null -ne $status -and $null -ne $severity) {
                    @([ordered]@{ path = $fullPath; line = $previousEvidenceLine })
                }
                else {
                    @()
                }
            }
            if ($previousProseEntries.ContainsKey($id)) {
                $previousProseEntry = $previousProseEntries[$id]
                if ($previousProseEntry.status -cne $status -or $previousProseEntry.severity -cne $severity) {
                    $inconsistencies.Add($id + ' previous prose duplicate fields conflict')
                }
            }
            else {
                $previousProseEntries[$id] = $normalizedEntry
            }
        }
    }
    if ($previousSeen.Count -gt 0 -and $previousProseMatches.Count -eq 0) {
        $inconsistencies.Add('missing previous prose section: 前輪 finding 狀態')
    }
    foreach ($id in @($previousSeen.Keys)) {
        if (-not $previousProseEntries.ContainsKey($id)) {
            $inconsistencies.Add('previous finding missing from prose: ' + $id)
            continue
        }
        $previous = $previousSeen[$id]
        $previousProse = $previousProseEntries[$id]
        if ($previousProse.status -cne $previous.status) {
            $inconsistencies.Add($id + ' previous prose status conflicts with previous_status')
        }
        if ($previousProse.severity -cne $previous.severity) {
            $inconsistencies.Add($id + ' previous prose severity conflicts with previous_status')
        }
    }
    foreach ($id in @($previousProseEntries.Keys)) {
        if (-not $previousSeen.ContainsKey($id)) {
            $inconsistencies.Add('previous prose finding missing from previous_status: ' + $id)
        }
    }

    if ($manifestSchema -ceq 'codex-dispatch.review-findings.v1' -and -not $currentJudgmentExplicit) {
        $currentJudgmentAdapter = $true
        foreach ($id in @($previousSeen.Keys)) {
            $previous = $previousSeen[$id]
            $proseEntry = if ($previousProseEntries.ContainsKey($id)) { $previousProseEntries[$id] } else { $null }
            $evidence = if ($null -ne $proseEntry) { @($proseEntry.evidence) } else { @([ordered]@{ path = $fullPath; line = 1 }) }
            $currentJudgmentSeen[$id] = [pscustomobject]@{
                id = $id
                status = $previous.status
                severity = $previous.severity
                evidence = @($evidence)
            }
        }
        foreach ($id in @($currentSeen.Keys)) {
            if ($currentJudgmentSeen.ContainsKey($id)) {
                continue
            }
            $current = $currentSeen[$id]
            $currentJudgmentSeen[$id] = [pscustomobject]@{
                id = $id
                status = 'open'
                severity = $current.severity
                evidence = @([ordered]@{ path = $fullPath; line = 1 })
            }
        }
    }

    $currentJudgmentActive = $manifestSchema -ceq 'codex-dispatch.review-findings.v2' -or $currentJudgmentExplicit -or $currentJudgmentAdapter
    if ($currentJudgmentActive) {
        foreach ($id in @($previousSeen.Keys)) {
            if (-not $currentJudgmentSeen.ContainsKey($id)) {
                $inconsistencies.Add('previous finding missing from current_judgment: ' + $id)
            }
        }
        foreach ($id in @($currentSeen.Keys)) {
            if (-not $currentJudgmentSeen.ContainsKey($id)) {
                $inconsistencies.Add('current finding missing from current_judgment: ' + $id)
            }
        }
        foreach ($id in @($currentJudgmentSeen.Keys)) {
            if (-not $previousSeen.ContainsKey($id) -and -not $currentSeen.ContainsKey($id)) {
                $inconsistencies.Add('current_judgment finding missing from previous_status and current_findings: ' + $id)
            }
        }

        $judgmentOpenIds = @($currentJudgmentSeen.Values | Where-Object { $_.status -ceq 'open' } | ForEach-Object { [string]$_.id } | Sort-Object -Unique)
        $currentFindingIds = @($currentSeen.Keys | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        foreach ($id in $judgmentOpenIds) {
            if ($currentFindingIds -notcontains $id) {
                $inconsistencies.Add('current judgment open finding missing from current_findings: ' + $id)
            }
        }
        foreach ($id in $currentFindingIds) {
            if ($judgmentOpenIds -notcontains $id) {
                $inconsistencies.Add('current finding missing from current_judgment open status: ' + $id)
            }
        }
    }

    $proseIds = New-Object System.Collections.Generic.List[string]
    foreach ($heading in @('Standards', 'Standards 缺陷審查', '需求對照核對', 'Spec')) {
        $sectionMatches = [regex]::Matches($content, '(?ms)^##[ \t]+' + [regex]::Escape($heading) + '[ \t]*\r?\n(?<section>.*?)(?=^##[ \t]|\z)')
        if ($sectionMatches.Count -eq 0) {
            $inconsistencies.Add('missing current prose section: ' + $heading)
            continue
        }
        foreach ($sectionMatch in $sectionMatches) {
            foreach ($idMatch in [regex]::Matches($sectionMatch.Groups['section'].Value, '\[F-[0-9]{3}\]')) {
                $proseIds.Add($idMatch.Value.Substring(1, $idMatch.Value.Length - 2))
            }
        }
    }

    $currentIdSet = @($currentSeen.Keys | Sort-Object)
    $proseIdSet = @($proseIds | Sort-Object -Unique)
    foreach ($id in $currentIdSet) {
        if ($proseIdSet -notcontains $id) { $inconsistencies.Add('current finding missing from prose: ' + $id) }
    }
    foreach ($id in $proseIdSet) {
        if ($currentIdSet -notcontains $id) { $inconsistencies.Add('prose finding missing from current_findings: ' + $id) }
    }

    $counts = Get-ReviewerPropertyValue -Object $manifest -Name 'counts'
    $declaredCounts = [ordered]@{}
    foreach ($name in @('previous_closed', 'previous_open', 'current_new', 'current_open')) {
        $declaredCounts[$name] = Get-ReviewerDeclaredCount -Counts $counts -Name $name -Inconsistencies $inconsistencies
    }
    $expectedCounts = [ordered]@{
        previous_closed = @($previousSeen.Values | Where-Object { $_.status -ceq 'closed' }).Count
        previous_open = @($previousSeen.Values | Where-Object { $_.status -ceq 'open' }).Count
        current_new = @($currentSeen.Values | Where-Object { $_.disposition -ceq 'new' }).Count
        current_open = $currentSeen.Count
    }
    if ($manifestSchema -ceq 'codex-dispatch.review-findings.v2' -or $currentJudgmentExplicit -or $currentJudgmentAdapter) {
        $expectedCounts.current_closed = @($currentJudgmentSeen.Values | Where-Object { $_.status -ceq 'closed' }).Count
        $expectedCounts.current_withdrawn = @($currentJudgmentSeen.Values | Where-Object { $_.status -ceq 'withdrawn' }).Count
        $expectedCounts.previous_withdrawn = @($previousSeen.Values | Where-Object { $_.status -ceq 'withdrawn' }).Count
    }
    foreach ($name in $expectedCounts.Keys) {
        $declared = if ($null -eq $counts) { $null } else { $declaredCounts[$name] }
        if ($null -eq $declared -and ($manifestSchema -ceq 'codex-dispatch.review-findings.v2' -or $currentJudgmentExplicit)) {
            $declared = Get-ReviewerDeclaredCount -Counts $counts -Name $name -Inconsistencies $inconsistencies
            $declaredCounts[$name] = $declared
        }
        if ($null -ne $declared -and [int64]$declared -ne [int64]$expectedCounts[$name]) {
            $inconsistencies.Add(('counts.{0} declared={1}; expected={2}' -f $name, $declaredCounts[$name], $expectedCounts[$name]))
        }
    }

    $conclusion = [string](Get-ReviewerPropertyValue -Object $manifest -Name 'conclusion')
    if ($conclusion -notin @('pass', 'fail')) {
        $inconsistencies.Add('conclusion must be pass or fail')
    }
    $judgmentEntriesForConclusion = if ($currentJudgmentActive) { @($currentJudgmentSeen.Values) } else { @($currentSeen.Values) }
    $expectedConclusion = if (@($judgmentEntriesForConclusion | Where-Object { $_.status -ceq 'open' -and $_.severity -in @('Critical', 'Major') }).Count -gt 0) { 'fail' } else { 'pass' }
    if ($conclusion -in @('pass', 'fail') -and $conclusion -cne $expectedConclusion) {
        $inconsistencies.Add(('conclusion declared={0}; expected={1}' -f $conclusion, $expectedConclusion))
    }

    $uniqueInconsistencies = @($inconsistencies | Sort-Object -Unique)
    return [ordered]@{
        reviewer_report_path = $fullPath
        reviewer_report_sha256 = Get-FileSha256 -Path $fullPath
        valid = $uniqueInconsistencies.Count -eq 0
        schema = $manifestSchema
        line_slug = if ([string]::IsNullOrWhiteSpace($manifestLineSlug)) { $null } else { $manifestLineSlug }
        dispatch_slug = if ([string]::IsNullOrWhiteSpace($manifestDispatchSlug)) { $null } else { $manifestDispatchSlug }
        round = $manifestRoundValue
        current_judgment_explicit = $currentJudgmentExplicit
        current_judgment_source = if ($currentJudgmentExplicit) { 'manifest' } elseif ($currentJudgmentAdapter) { 'v1-adapter' } else { $null }
        current_judgment = @($currentJudgmentSeen.Values)
        previous_status = @($previousSeen.Values)
        current_findings = @($currentSeen.Values)
        conclusion = if ($conclusion -in @('pass', 'fail')) { $conclusion } else { $null }
        current_finding_count = $currentSeen.Count
        previous_closed_count = $expectedCounts.previous_closed
        previous_open_count = $expectedCounts.previous_open
        previous_withdrawn_count = @($previousSeen.Values | Where-Object { $_.status -ceq 'withdrawn' }).Count
        current_new_count = $expectedCounts.current_new
        current_open_count = $expectedCounts.current_open
        current_closed_count = if ($expectedCounts.Contains('current_closed')) { $expectedCounts.current_closed } else { $null }
        current_withdrawn_count = if ($expectedCounts.Contains('current_withdrawn')) { $expectedCounts.current_withdrawn } else { $null }
        error_code = $null
        duplicate_ids = @($duplicateIds | Sort-Object -Unique)
        inconsistencies = $uniqueInconsistencies
    }
}

function Resolve-ReviewerEvidencePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EvidencePath,

        [Parameter(Mandatory)]
        [string]$ReportPath
    )

    if ([System.IO.Path]::IsPathRooted($EvidencePath)) {
        return Resolve-AbsolutePath -Path $EvidencePath
    }
    return Resolve-AbsolutePath -Path (Join-Path (Split-Path -Parent (Resolve-AbsolutePath -Path $ReportPath)) $EvidencePath)
}

function Get-ReviewerLedgerHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Ledger
    )

    $canonical = [ordered]@{
        schema = [string]$Ledger.schema
        line_slug = [string]$Ledger.line_slug
        entries = @($Ledger.entries)
    }
    return Get-JsonSha256 -Value $canonical
}

function Write-ReviewerFindingLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$ReviewerFindings
    )

    $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
    $executionRootPath = Resolve-AbsolutePath -Path $ExecutionRoot
    $historyLineRoot = Join-Path (Join-Path $sourceRootPath '.local\ai-sessions\history') $LineSlug
    $ledgerPath = Join-Path $historyLineRoot 'review-finding-ledger.json'
    New-Item -ItemType Directory -Path $historyLineRoot -Force | Out-Null

    $existingLedger = $null
    $existingFileSha256 = $null
    if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
        try {
            $existingLedger = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $ledgerPath)
        }
        catch {
            $exception = New-Object System.InvalidOperationException('LedgerConflict：finding ledger JSON 無法解析：' + $_.Exception.Message)
            $exception.Data['errorCode'] = 'LedgerConflict'
            $exception.Data['path'] = $ledgerPath
            throw $exception
        }
        if ($null -eq $existingLedger -or $existingLedger -isnot [pscustomobject] -or [string]$existingLedger.schema -cne 'codex-dispatch.review-finding-ledger.v1' -or [string]$existingLedger.line_slug -cne $LineSlug -or $null -eq $existingLedger.entries) {
            $exception = New-Object System.InvalidOperationException('LedgerConflict：finding ledger schema 或 line_slug 不一致。')
            $exception.Data['errorCode'] = 'LedgerConflict'
            $exception.Data['path'] = $ledgerPath
            throw $exception
        }
        $existingLedgerCanonical = [ordered]@{
            schema = [string]$existingLedger.schema
            line_slug = [string]$existingLedger.line_slug
            entries = @($existingLedger.entries)
        }
        $existingHash = Get-ReviewerLedgerHash -Ledger $existingLedgerCanonical
        if ([string]$existingLedger.ledger_sha256 -cne $existingHash) {
            $exception = New-Object System.InvalidOperationException('LedgerConflict：finding ledger SHA-256 不一致。')
            $exception.Data['errorCode'] = 'LedgerConflict'
            $exception.Data['path'] = $ledgerPath
            $exception.Data['expected_sha256'] = $existingHash
            $exception.Data['received_sha256'] = [string]$existingLedger.ledger_sha256
            throw $exception
        }
        $existingFileSha256 = Get-FileSha256 -Path $ledgerPath
    }

    $currentFindingById = @{}
    foreach ($finding in @($ReviewerFindings.current_findings)) {
        $currentFindingById[[string]$finding.id] = $finding
    }
    $previousById = @{}
    foreach ($finding in @($ReviewerFindings.previous_status)) {
        $previousById[[string]$finding.id] = $finding
    }

    $newEntries = New-Object System.Collections.Generic.List[object]
    $round = [int64]$ReviewerFindings.round
    foreach ($judgment in @($ReviewerFindings.current_judgment)) {
        $findingId = [string]$judgment.id
        $entryKey = $findingId + '/' + $round
        $existingEntry = $null
        if ($null -ne $existingLedger) {
            $existingMatches = @($existingLedger.entries | Where-Object { ([string]$_.finding_id + '/' + [int64]$_.round) -ceq $entryKey })
            if ($existingMatches.Count -gt 1) {
                $exception = New-Object System.InvalidOperationException('LedgerConflict：finding_id + round 出現重複：' + $entryKey)
                $exception.Data['errorCode'] = 'LedgerConflict'
                $exception.Data['path'] = $ledgerPath
                throw $exception
            }
            if ($existingMatches.Count -eq 1) { $existingEntry = $existingMatches[0] }
        }

        $currentFinding = if ($currentFindingById.ContainsKey($findingId)) { $currentFindingById[$findingId] } else { $null }
        $previousFinding = if ($previousById.ContainsKey($findingId)) { $previousById[$findingId] } else { $null }
        $axis = if ($null -ne $currentFinding) { [string](Get-ReviewerPropertyValue -Object $currentFinding -Name 'axis') } elseif ($null -ne $previousFinding) { [string](Get-ReviewerPropertyValue -Object $previousFinding -Name 'axis') } else { 'Unknown' }
        if ([string]::IsNullOrWhiteSpace($axis)) { $axis = 'Unknown' }
        $evidenceList = New-Object System.Collections.Generic.List[object]
        foreach ($position in @($judgment.evidence)) {
            $resolvedEvidencePath = Resolve-ReviewerEvidencePath -EvidencePath ([string]$position.path) -ReportPath ([string]$ReviewerFindings.reviewer_report_path)
            if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
                throw ('Reviewer evidence 不存在：' + $resolvedEvidencePath)
            }
            $evidenceList.Add([ordered]@{
                    path = $resolvedEvidencePath
                    line = [int64]$position.line
                    sha256 = Get-FileSha256 -Path $resolvedEvidencePath
                })
        }
        $entry = [ordered]@{
            finding_id = $findingId
            round = $round
            previous_status = if ($null -eq $previousFinding) { $null } else { [string]$previousFinding.status }
            current_judgment = [string]$judgment.status
            axis = $axis
            severity = [string]$judgment.severity
            source_report_path = [string]$ReviewerFindings.reviewer_report_path
            source_report_sha256 = [string]$ReviewerFindings.reviewer_report_sha256
            evidence = @($evidenceList.ToArray())
            recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        if ($null -ne $existingEntry) {
            $existingComparable = [ordered]@{
                finding_id = [string]$existingEntry.finding_id
                round = [int64]$existingEntry.round
                previous_status = if ($null -eq $existingEntry.previous_status) { $null } else { [string]$existingEntry.previous_status }
                current_judgment = [string]$existingEntry.current_judgment
                axis = [string]$existingEntry.axis
                severity = [string]$existingEntry.severity
                source_report_path = [string]$existingEntry.source_report_path
                source_report_sha256 = [string]$existingEntry.source_report_sha256
                evidence = @($existingEntry.evidence)
            }
            $newComparable = [ordered]@{
                finding_id = [string]$entry.finding_id
                round = [int64]$entry.round
                previous_status = if ($null -eq $entry.previous_status) { $null } else { [string]$entry.previous_status }
                current_judgment = [string]$entry.current_judgment
                axis = [string]$entry.axis
                severity = [string]$entry.severity
                source_report_path = [string]$entry.source_report_path
                source_report_sha256 = [string]$entry.source_report_sha256
                evidence = @($entry.evidence)
            }
            if ((ConvertTo-Json -InputObject $existingComparable -Depth 20 -Compress) -cne (ConvertTo-Json -InputObject $newComparable -Depth 20 -Compress)) {
                $exception = New-Object System.InvalidOperationException('LedgerConflict：既有 finding entry 與本輪資料不一致：' + $entryKey)
                $exception.Data['errorCode'] = 'LedgerConflict'
                $exception.Data['path'] = $ledgerPath
                throw $exception
            }
            continue
        }
        $newEntries.Add($entry)
    }

    $entries = New-Object System.Collections.Generic.List[object]
    if ($null -ne $existingLedger) {
        foreach ($entry in @($existingLedger.entries)) { $entries.Add($entry) }
    }
    foreach ($entry in @($newEntries.ToArray())) { $entries.Add($entry) }
    $ledger = [ordered]@{
        schema = 'codex-dispatch.review-finding-ledger.v1'
        line_slug = $LineSlug
        entries = @($entries.ToArray())
        ledger_sha256 = $null
    }
    $ledger.ledger_sha256 = Get-ReviewerLedgerHash -Ledger $ledger
    $writeArguments = @{
        Path = $ledgerPath
        Document = $ledger
        SourceRoot = $sourceRootPath
        ExecutionRoot = $executionRootPath
        TargetPath = @()
        HashProperty = ''
    }
    if ($null -ne $existingFileSha256) {
        $writeArguments.ExpectedExistingSha256 = $existingFileSha256
    }
    else {
        $writeArguments.RequireAbsent = $true
        $writeArguments.AbsentErrorCode = 'LedgerConflict'
    }
    try {
        $written = Write-DispatchAtomicJsonDocument @writeArguments
    }
    catch {
        $exception = $_.Exception
        try { $exception.Data['errorCode'] = 'LedgerConflict' } catch { }
        throw $exception
    }
    return [ordered]@{
        path = $written.Path
        sha256 = $written.Sha256
        entries_added = @($newEntries.ToArray())
        ledger = $ledger
    }
}

function Get-ReviewerFindingsForCollect {
    param(
        [string]$Path,
        [string]$SourceRoot,
        [string]$ExecutionRoot,
        [string]$LineSlug,
        [string]$DispatchSlug,
        [bool]$WriteLedger = $true
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $result = Test-ReviewerFindingReport -Path $Path
    $judgmentEntries = @($result.current_judgment)
    $openBlockingCount = @($judgmentEntries | Where-Object {
            $_.status -ceq 'open' -and $_.severity -in @('Critical', 'Major')
        }).Count
    $expectedConclusion = if ($openBlockingCount -gt 0) { 'fail' } else { 'pass' }
    if ($result.valid -and [string]$result.conclusion -cne $expectedConclusion) {
        $result.valid = $false
        $result.error_code = 'ReviewerConclusionMismatch'
        $result.inconsistencies = @(
            @($result.inconsistencies)
            ('manifest inconsistency: current_judgment open Critical/Major={0}; conclusion declared={1}; expected={2}' -f $openBlockingCount, [string]$result.conclusion, $expectedConclusion)
        )
    }
    if ($result.valid -and $WriteLedger -and -not [string]::IsNullOrWhiteSpace($SourceRoot) -and -not [string]::IsNullOrWhiteSpace($ExecutionRoot) -and -not [string]::IsNullOrWhiteSpace($LineSlug) -and -not [string]::IsNullOrWhiteSpace($DispatchSlug)) {
        $result.ledger = Write-ReviewerFindingLedger -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -ReviewerFindings $result
    }
    return $result
}

function Throw-ReviewerFindingCollectFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Result
    )

    $reviewerFindings = $Result['reviewerFindings']
    $Result['outputValid'] = $false
    $errorCode = [string](Get-ReviewerPropertyValue -Object $reviewerFindings -Name 'error_code')
    if ([string]::IsNullOrWhiteSpace($errorCode)) { $errorCode = 'ReviewerManifestInvalid' }
    $Result['errorCode'] = $errorCode
    $message = 'Reviewer report 結構無效，Collect 拒絕回收：' + $errorCode + '：' + ([string]::Join('; ', @($reviewerFindings.inconsistencies)))
    $operationException = New-Object System.Exception($message)
    $operationException = Write-DispatchOperationFailureResult -Exception $operationException -Result $Result
    throw $operationException
}

function Get-ScopePlanHashRecordPath {
    param(
        [Parameter(Mandatory)]
        [string]$SourceHistoryRoot,

        [Parameter(Mandatory)]
        [string]$DispatchSlug
    )

    return Join-Path -Path $SourceHistoryRoot -ChildPath ('scope-plan-hash-' + $DispatchSlug + '.json')
}

function Write-ScopePlanHashRecordIfMissing {
    param(
        [Parameter(Mandatory)]
        [string]$SourceHistoryRoot,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$ScopePlanPath,

        [string]$RootRunId
    )

    $recordPath = Get-ScopePlanHashRecordPath -SourceHistoryRoot $SourceHistoryRoot -DispatchSlug $DispatchSlug
    if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
        try {
            $existingRecord = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            throw "既有 ScopePlan SHA-256 紀錄無法解析：$recordPath；$($_.Exception.Message)"
        }
        if (-not [string]::IsNullOrWhiteSpace($RootRunId)) {
            $existingRootRunIdProperty = $existingRecord.PSObject.Properties['root_run_id']
            if ($null -eq $existingRootRunIdProperty -or [string]$existingRootRunIdProperty.Value -cne $RootRunId) {
                throw "既有 ScopePlan SHA-256 紀錄的 root run 不一致：record=$([string](Get-OptionalObjectProperty -Object $existingRecord -Name 'root_run_id'))；expected=$RootRunId"
            }
        }
        return $recordPath
    }

    $resolvedScopePlanPath = Resolve-AbsolutePath -Path $ScopePlanPath
    $record = [ordered]@{
        dispatch_slug   = $DispatchSlug
        line_slug       = $LineSlug
        scope_plan_path = $resolvedScopePlanPath
        sha256          = Get-FileSha256 -Path $resolvedScopePlanPath
        created_at_utc  = [datetime]::UtcNow.ToString('o')
        root_run_id     = if ([string]::IsNullOrWhiteSpace($RootRunId)) { $null } else { $RootRunId }
    }
    Write-Utf8NoBom -Path $recordPath -Content (($record | ConvertTo-Json -Depth 8) + "`n")
    return $recordPath
}

function Test-ScopePlanHashRecord {
    param(
        [Parameter(Mandatory)]
        [string]$SourceHistoryRoot,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$ScopePlanPath,

        [string]$ExpectedRootRunId
    )

    $recordPath = Get-ScopePlanHashRecordPath -SourceHistoryRoot $SourceHistoryRoot -DispatchSlug $DispatchSlug
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
        throw "續行缺少 ScopePlan SHA-256 紀錄：$recordPath"
    }

    try {
        $record = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "ScopePlan SHA-256 紀錄無法解析：$recordPath；$($_.Exception.Message)"
    }
    foreach ($requiredProperty in @('dispatch_slug', 'line_slug', 'scope_plan_path', 'sha256', 'created_at_utc')) {
        if ($null -eq $record.PSObject.Properties[$requiredProperty] -or [string]::IsNullOrWhiteSpace([string]$record.$requiredProperty)) {
            throw "ScopePlan SHA-256 紀錄缺少必要欄位：$requiredProperty"
        }
    }

    $resolvedScopePlanPath = Resolve-AbsolutePath -Path $ScopePlanPath
    $recordScopePlanPath = Resolve-AbsolutePath -Path ([string]$record.scope_plan_path)
    if (-not [string]::Equals([string]$record.dispatch_slug, $DispatchSlug, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$record.line_slug, $LineSlug, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "ScopePlan SHA-256 紀錄的 dispatchSlug 或 lineSlug 不一致：$recordPath"
    }
    if (-not [string]::Equals($recordScopePlanPath, $resolvedScopePlanPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "ScopePlan SHA-256 紀錄的路徑不一致：record=$recordScopePlanPath；requested=$resolvedScopePlanPath"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRootRunId)) {
        $rootRunIdProperty = $record.PSObject.Properties['root_run_id']
        if ($null -eq $rootRunIdProperty -or [string]$rootRunIdProperty.Value -cne $ExpectedRootRunId) {
            throw "ScopePlan SHA-256 紀錄的 root run 不一致：record=$([string]$record.root_run_id)；expected=$ExpectedRootRunId"
        }
    }

    $actualHash = Get-FileSha256 -Path $resolvedScopePlanPath
    if (-not [string]::Equals([string]$record.sha256, $actualHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "ScopePlan SHA-256 不一致：record=$($record.sha256)；actual=$actualHash"
    }
    return $true
}

function Test-ScopePlanCompleteness {
    param(
        [AllowNull()]
        [object]$ScopePlan
    )

    if ($null -eq $ScopePlan) {
        return $false
    }

    foreach ($requiredName in @('dispatch_slug', 'dispatch_kind', 'task_type', 'requested_profile', 'session_mode', 'primary_remaining_percent', 'primary_reserve_percent', 'primary_budget_percent', 'estimate_percent', 'estimate_source', 'unit_kind', 'requested_units', 'selected_units', 'deferred_units', 'decision', 'decision_reason')) {
        if ($null -eq $ScopePlan.PSObject.Properties[$requiredName]) {
            return $false
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$ScopePlan.dispatch_slug) -or
        [string]::IsNullOrWhiteSpace([string]$ScopePlan.dispatch_kind) -or
        [string]::IsNullOrWhiteSpace([string]$ScopePlan.task_type) -or
        [string]::IsNullOrWhiteSpace([string]$ScopePlan.requested_profile) -or
        [string]::IsNullOrWhiteSpace([string]$ScopePlan.session_mode) -or
        [string]::IsNullOrWhiteSpace([string]$ScopePlan.unit_kind) -or
        [string]::IsNullOrWhiteSpace([string]$ScopePlan.estimate_source)) {
        return $false
    }

    if ($null -ne $ScopePlan.estimate_percent) {
        try {
            $estimateValue = [double]$ScopePlan.estimate_percent
        }
        catch {
            return $false
        }
        if ([double]::IsNaN($estimateValue) -or [double]::IsInfinity($estimateValue) -or $estimateValue -lt 0) {
            return $false
        }
    }
    if ([string]$ScopePlan.estimate_source -eq 'not-required-above-threshold' -and $null -ne $ScopePlan.estimate_percent) {
        return $false
    }
    if ([string]$ScopePlan.estimate_source -in @('calibration-p75', 'p75', 'conservative-default') -and $null -eq $ScopePlan.estimate_percent) {
        return $false
    }
    if ([string]$ScopePlan.estimate_source -eq 'bounded-single-unit' -and $null -ne $ScopePlan.estimate_percent) {
        return $false
    }

    if ($ScopePlan.unit_kind -notin @('workflow-phase', 'resource-target', 'advisor-evidence-question') -or
        $ScopePlan.decision -notin @('full', 'scoped', 'blocked-insufficient-budget', 'blocked-no-estimate', 'blocked-no-fresh-quota', 'user-decision-required')) {
        return $false
    }
    if ([string]$ScopePlan.task_type -eq 'advisor-consult') {
        foreach ($advisorProperty in @('activation_mode', 'authorization_source', 'reserve_bypassed', 'minimum_unit_over_budget', 'stop_after_selected_units', 'advisor_unit_estimate_percent')) {
            if ($null -eq $ScopePlan.PSObject.Properties[$advisorProperty]) {
                return $false
            }
        }
        if ([string]$ScopePlan.activation_mode -notin @('automatic-quota', 'user-authorized', 'none')) {
            return $false
        }
        if ($null -ne $ScopePlan.authorization_source -and [string]$ScopePlan.authorization_source -notin @('automatic-quota', 'user-explicit')) {
            return $false
        }
        if ($ScopePlan.reserve_bypassed -isnot [bool] -or $ScopePlan.minimum_unit_over_budget -isnot [bool]) {
            return $false
        }
    }

    $stopAfterSelectedProperty = $ScopePlan.PSObject.Properties['stop_after_selected_units']
    if ($null -ne $stopAfterSelectedProperty -and $stopAfterSelectedProperty.Value -isnot [bool]) {
        return $false
    }
    $quotaFreshnessProperty = $ScopePlan.PSObject.Properties['quota_freshness']
    if ($null -ne $quotaFreshnessProperty -and [string]$quotaFreshnessProperty.Value -notin @('fresh', 'stale', 'unknown')) {
        return $false
    }
    $quotaStateProperty = $ScopePlan.PSObject.Properties['quota_state']
    if ($null -ne $quotaStateProperty -and [string]$quotaStateProperty.Value -notin @('Valid', 'SnapshotUnavailable', 'ServiceRejected', 'PostResetNoSnapshot', 'SnapshotExpired', 'Invalid')) {
        return $false
    }

    $requestedUnits = @($ScopePlan.requested_units | ForEach-Object { [string]$_ })
    $selectedUnits = @($ScopePlan.selected_units | ForEach-Object { [string]$_ })
    $deferredUnits = @($ScopePlan.deferred_units | ForEach-Object { [string]$_ })
    $hasBlankSelected = @($selectedUnits | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
    $hasBlankDeferred = @($deferredUnits | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
    if ($requestedUnits.Count -eq 0 -or $hasBlankSelected -or $hasBlankDeferred) {
        return $false
    }

    $requestedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $selectedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $deferredSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($unit in $requestedUnits) {
        if (-not $requestedSet.Add($unit)) {
            return $false
        }
    }
    foreach ($unit in $selectedUnits) {
        if (-not $selectedSet.Add($unit) -or -not $requestedSet.Contains($unit)) {
            return $false
        }
    }
    foreach ($unit in $deferredUnits) {
        if (-not $deferredSet.Add($unit) -or -not $requestedSet.Contains($unit) -or $selectedSet.Contains($unit)) {
            return $false
        }
    }
    if ($selectedUnits.Count + $deferredUnits.Count -ne $requestedUnits.Count) {
        return $false
    }
    foreach ($unit in $requestedUnits) {
        if (-not $selectedSet.Contains($unit) -and -not $deferredSet.Contains($unit)) {
            return $false
        }
    }
    if ([string]$ScopePlan.task_type -eq 'advisor-consult') {
        for ($index = 0; $index -lt $selectedUnits.Count; $index++) {
            if (-not [string]::Equals($selectedUnits[$index], $requestedUnits[$index], [System.StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }
        }
        for ($index = 0; $index -lt $deferredUnits.Count; $index++) {
            $requestedIndex = $selectedUnits.Count + $index
            if (-not [string]::Equals($deferredUnits[$index], $requestedUnits[$requestedIndex], [System.StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }
        }
    }

    try {
        $budget = [double]$ScopePlan.primary_budget_percent
        $remaining = [double]$ScopePlan.primary_remaining_percent
        $reserve = [double]$ScopePlan.primary_reserve_percent
    }
    catch {
        return $false
    }
    if ([double]::IsNaN($budget) -or [double]::IsInfinity($budget) -or $budget -lt 0 -or
        [double]::IsNaN($remaining) -or [double]::IsInfinity($remaining) -or $remaining -lt 0 -or
        [double]::IsNaN($reserve) -or [double]::IsInfinity($reserve) -or $reserve -lt 0) {
        return $false
    }

    switch ([string]$ScopePlan.decision) {
        'full' {
            return $selectedUnits.Count -eq $requestedUnits.Count -and $deferredUnits.Count -eq 0
        }
        'scoped' {
            return $selectedUnits.Count -gt 0 -and $deferredUnits.Count -gt 0
        }
        'blocked-insufficient-budget' { return $selectedUnits.Count -eq 0 }
        'blocked-no-estimate' { return $selectedUnits.Count -eq 0 }
        'blocked-no-fresh-quota' { return $selectedUnits.Count -eq 0 }
        'user-decision-required' { return $selectedUnits.Count -eq 0 }
    }
    return $false
}

function Test-ContinuationScopePlan {
    param(
        [Parameter(Mandatory)]
        [psobject]$ScopePlan,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [string]$DispatchKind,

        [Parameter(Mandatory)]
        [string]$TaskType,

        [Parameter(Mandatory)]
        [string]$RequestedProfile,

        [Parameter(Mandatory)]
        [string]$UnitKind,

        [Parameter(Mandatory)]
        [string[]]$Units
    )

    if (-not (Test-ScopePlanCompleteness -ScopePlan $ScopePlan)) {
        return $false
    }
    $selectedUnits = @($ScopePlan.selected_units | ForEach-Object { [string]$_ })
    $deferredUnits = @($ScopePlan.deferred_units | ForEach-Object { [string]$_ })
    $continuationUnits = @($selectedUnits + $deferredUnits)
    if (-not (Test-StringArrayEqual -Left $continuationUnits -Right $ScopePlan.requested_units) -or
        [string]::IsNullOrWhiteSpace([string]$ScopePlan.decision) -or
        [string]::IsNullOrWhiteSpace([string]$ScopePlan.estimate_source)) {
        return $false
    }
    if (-not [string]::Equals([string]$ScopePlan.dispatch_slug, $DispatchSlug, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$ScopePlan.dispatch_kind, $DispatchKind, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$ScopePlan.task_type, $TaskType, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$ScopePlan.requested_profile, $RequestedProfile, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$ScopePlan.unit_kind, $UnitKind, [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]$ScopePlan.session_mode -notin @('cold-start', 'continuation') -or
        -not (Test-StringArrayEqual -Left $ScopePlan.requested_units -Right $Units)) {
        return $false
    }
    return $true
}

function New-ContinuationScopePlanSubset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$ParentScopePlan,

        [Parameter(Mandatory)]
        [string[]]$RequestedUnits,

        [Parameter(Mandatory)]
        [string]$ParentScopePlanPath,

        [Parameter(Mandatory)]
        [string]$ParentScopePlanSha256,

        [Parameter(Mandatory)]
        [string]$ParentRunId
    )

    if (-not (Test-ScopePlanCompleteness -ScopePlan $ParentScopePlan)) {
        throw '續行的父 ScopePlan 不完整，拒絕建立子集。'
    }
    if ($null -eq $RequestedUnits -or $RequestedUnits.Count -eq 0) {
        throw 'ContinueFromScopePlan 必須提供至少一個 RequestedUnit。'
    }

    $parentUnits = @($ParentScopePlan.requested_units | ForEach-Object { [string]$_ })
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $previousParentIndex = -1
    foreach ($requestedUnit in @($RequestedUnits)) {
        if ([string]::IsNullOrWhiteSpace($requestedUnit)) {
            throw 'ContinueFromScopePlan 的 RequestedUnit 不可為空白。'
        }
        if (-not $seen.Add([string]$requestedUnit)) {
            throw ('ContinueFromScopePlan 的 RequestedUnit 不可重複：' + [string]$requestedUnit)
        }
        $parentIndex = -1
        for ($index = 0; $index -lt $parentUnits.Count; $index++) {
            if ([string]::Equals($parentUnits[$index], [string]$requestedUnit, [System.StringComparison]::OrdinalIgnoreCase)) {
                $parentIndex = $index
                break
            }
        }
        if ($parentIndex -lt 0) {
            throw ('ContinueFromScopePlan 的 RequestedUnit 不在父集合：' + [string]$requestedUnit)
        }
        if ($parentIndex -le $previousParentIndex) {
            throw 'ContinueFromScopePlan 的 RequestedUnit 必須維持父 ScopePlan 宣告順序。'
        }
        $previousParentIndex = $parentIndex
    }

    $child = $ParentScopePlan | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $child.requested_units = @($RequestedUnits | ForEach-Object { [string]$_ })
    $child.selected_units = @($RequestedUnits | ForEach-Object { [string]$_ })
    $child.deferred_units = @()
    $child.decision = 'full'
    $child.decision_reason = 'continuation subset 已依父 ScopePlan 宣告順序建立。'
    $child.session_mode = 'continuation'
    $child.stop_after_selected_units = $false
    $child | Add-Member -MemberType NoteProperty -Name 'parent_scope_plan_path' -Value (Resolve-AbsolutePath -Path $ParentScopePlanPath) -Force
    $child | Add-Member -MemberType NoteProperty -Name 'parent_scope_plan_sha256' -Value $ParentScopePlanSha256 -Force
    $child | Add-Member -MemberType NoteProperty -Name 'parent_run_id' -Value $ParentRunId -Force
    $child | Add-Member -MemberType NoteProperty -Name 'selection_classification' -Value 'subset' -Force
    $child.scope_plan_fingerprint = Get-ScopePlanFingerprint -ScopePlan $child
    return $child
}

function Get-LatestSafePointMessage {
    param(
        [Parameter(Mandatory)]
        [string]$EventPath,

        [AllowNull()]
        [string]$TaskType
    )

    $latest = ''
    if (-not (Test-Path -LiteralPath $EventPath -PathType Leaf)) {
        return $latest
    }
    foreach ($line in Get-Content -LiteralPath $EventPath -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }
        $item = Get-OptionalObjectProperty -Object $event -Name 'item'
        if ($null -eq $item -or (Get-OptionalObjectProperty -Object $item -Name 'type') -ne 'agent_message') {
            continue
        }
        $message = Get-OptionalObjectProperty -Object $item -Name 'text'
        if ($message -is [string] -and (Test-SafePointMessage -Message $message -TaskType $TaskType)) {
            $latest = $message
        }
    }
    return $latest
}

function Test-SafePointMessage {
    param(
        [AllowNull()]
        [string]$Message,

        [AllowNull()]
        [string]$TaskType
    )

    if ([string]::IsNullOrWhiteSpace($Message) -or -not $Message.Contains('## 中斷保全結論')) {
        return $false
    }
    $sectionMatch = [regex]::Match($Message, '(?ms)^##\s+中斷保全結論\s*\r?\n(?<body>.*?)(?=^##\s|\z)')
    if (-not $sectionMatch.Success -or [string]::IsNullOrWhiteSpace($sectionMatch.Groups['body'].Value)) {
        return $false
    }
    $body = $sectionMatch.Groups['body'].Value
    $requiredPatterns = @(
            '(?m)已確認結論\s*[:：]\s*\S+',
            '(?m)證據位置\s*[:：]\s*\S+',
            '(?m)實際覆蓋範圍\s*[:：]\s*\S+'
        )
    if ($TaskType -eq 'advisor-consult') {
        $requiredPatterns += '(?m)已完成單位\s*[:：]\s*\S+'
    }
    foreach ($requiredPattern in $requiredPatterns) {
        if ($body -notmatch $requiredPattern) {
            return $false
        }
    }
    return $true
}

function Write-BudgetMonitorRecord {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$Record
    )

    Add-AtomicJsonLine -Path $Path -Content (($Record | ConvertTo-Json -Depth 20 -Compress))
}

function Get-AdvisorCompletionPartition {
    param(
        [AllowNull()]
        [string]$Message,

        [AllowNull()]
        [object]$SelectedUnits,

        [AllowNull()]
        [object]$DeferredUnits
    )

    $unknownResult = [ordered]@{
        status            = 'unknown'
        completed_units   = @('unknown')
        incomplete_units  = @('unknown')
        reason            = 'safe point 缺少 advisor 的已完成單位欄位，無法推論完成範圍。'
    }
    if ([string]::IsNullOrWhiteSpace($Message) -or -not (Test-SafePointMessage -Message $Message -TaskType 'advisor-consult')) {
        return $unknownResult
    }

    $sectionMatch = [regex]::Match($Message, '(?ms)^##\s+中斷保全結論\s*\r?\n(?<body>.*?)(?=^##\s|\z)')
    if (-not $sectionMatch.Success) {
        return $unknownResult
    }
    $completedFieldPattern = '(?m)^\s*已完成單位\s*[:：]\s*(?<value>[^\r\n]+)\s*$'
    $completedFieldMatches = [regex]::Matches($sectionMatch.Groups['body'].Value, $completedFieldPattern)
    if ($completedFieldMatches.Count -ne 1) {
        return [ordered]@{
            status            = 'invalid'
            completed_units   = @('unknown')
            incomplete_units  = @('unknown')
            reason            = 'advisor safe point 的已完成單位欄位必須恰好宣告一次。'
        }
    }

    $selected = @($SelectedUnits | ForEach-Object { ([string]$_).Trim() })
    $deferred = @($DeferredUnits | ForEach-Object { ([string]$_).Trim() })
    $completedValue = $completedFieldMatches[0].Groups['value'].Value.Trim()
    $completed = New-Object System.Collections.Generic.List[string]
    if (-not [string]::Equals($completedValue, '無', [System.StringComparison]::OrdinalIgnoreCase)) {
        foreach ($unit in @($completedValue -split '[,;；、，\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            if ($unit -notmatch '^question-[A-Za-z0-9][A-Za-z0-9_-]*$') {
                return [ordered]@{
                    status            = 'invalid'
                    completed_units   = @('unknown')
                    incomplete_units  = @('unknown')
                    reason            = "advisor safe point 的已完成單位格式無效：$unit"
                }
            }
            if ($completed.Contains($unit)) {
                return [ordered]@{
                    status            = 'invalid'
                    completed_units   = @('unknown')
                    incomplete_units  = @('unknown')
                    reason            = "advisor safe point 的已完成單位不可重複：$unit"
                }
            }
            $completed.Add($unit)
        }
    }

    $selectedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $deferredSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($unit in $selected) { $null = $selectedSet.Add($unit) }
    foreach ($unit in $deferred) { $null = $deferredSet.Add($unit) }
    foreach ($unit in $completed) {
        if ($deferredSet.Contains($unit)) {
            return [ordered]@{
                status            = 'invalid'
                completed_units   = @('unknown')
                incomplete_units  = @('unknown')
                reason            = "advisor safe point 不可將 deferred 單位標記為已完成：$unit"
            }
        }
        if (-not $selectedSet.Contains($unit)) {
            return [ordered]@{
                status            = 'invalid'
                completed_units   = @('unknown')
                incomplete_units  = @('unknown')
                reason            = "advisor safe point 的已完成單位不在 selected units：$unit"
            }
        }
    }

    $incomplete = @($selected | Where-Object { -not $completed.Contains($_) }) + @($deferred)
    return [ordered]@{
        status            = 'valid'
        completed_units   = @($completed.ToArray())
        incomplete_units  = @($incomplete)
        reason            = '已完成單位僅依 safe point 欄位解析，且符合 selected／deferred partition。'
    }
}

function Write-AdvisorConsultReport {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [string]$EvidencePackPath,

        [Parameter(Mandatory)]
        [string]$EvidencePackSha256,

        [Nullable[int64]]$EvidencePackLength,

        [Parameter(Mandatory)]
        [string]$FinalMessage,

        [Parameter(Mandatory)]
        [string]$Status,

        [AllowNull()]
        [object]$BudgetMonitor,

        [AllowNull()]
        [object]$RequiredOutputGate,

        [AllowNull()]
        [object]$ScopePlan,

        [AllowNull()]
        [object]$InterruptionStatus
    )

    $fullPath = Resolve-AbsolutePath -Path $Path
    $reportRoot = Join-Path -Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $fullPath))) -ChildPath ''
    $reportParent = Split-Path -Parent $fullPath
    New-Item -ItemType Directory -Path $reportParent -Force | Out-Null
    $message = if ([string]::IsNullOrWhiteSpace($FinalMessage)) { '尚未取得執行端結案訊息。' } else { $FinalMessage.Trim() }
    $declaredOutput = @()
    $presentOutput = @()
    $missingOutput = @()
    $gateValid = $false
    if ($null -ne $RequiredOutputGate) {
        $declaredProperty = $RequiredOutputGate.PSObject.Properties['required']
        $presentProperty = $RequiredOutputGate.PSObject.Properties['present']
        $missingProperty = $RequiredOutputGate.PSObject.Properties['missing']
        $validProperty = $RequiredOutputGate.PSObject.Properties['valid']
        if ($null -ne $declaredProperty) { $declaredOutput = @($declaredProperty.Value) }
        if ($null -ne $presentProperty) { $presentOutput = @($presentProperty.Value) }
        if ($null -ne $missingProperty) { $missingOutput = @($missingProperty.Value) }
        if ($null -ne $validProperty) { $gateValid = [bool]$validProperty.Value }
    }
    $gateObject = [ordered]@{
        declared = $declaredOutput
        present = $presentOutput
        missing = $missingOutput
        valid = $gateValid
    }
    $requestedUnits = if ($null -eq $ScopePlan) { @() } else { @($ScopePlan.requested_units) }
    $selectedUnits = if ($null -eq $ScopePlan) { @() } else { @($ScopePlan.selected_units) }
    $deferredUnits = if ($null -eq $ScopePlan) { @() } else { @($ScopePlan.deferred_units) }
    $completionPartition = Get-AdvisorCompletionPartition -Message $FinalMessage -SelectedUnits $selectedUnits -DeferredUnits $deferredUnits
    $completedUnits = @($completionPartition.completed_units)
    $incompleteUnits = @($completionPartition.incomplete_units)
    $activationMode = if ($null -eq $ScopePlan) { 'none' } else { [string]$ScopePlan.activation_mode }
    $authorizationSource = if ($null -eq $ScopePlan) { $null } else { $ScopePlan.authorization_source }
    $reserveBypassed = if ($null -eq $ScopePlan) { $false } else { [bool]$ScopePlan.reserve_bypassed }
    $unitEstimate = if ($null -eq $ScopePlan) { $null } else { $ScopePlan.advisor_unit_estimate_percent }
    $hardLimit = if ($null -eq $ScopePlan) { $null } else { $ScopePlan.advisor_hard_limit_percent }
    $content = @(
        ('# Advisor consult report')
        ''
        ('- line-slug: ' + $LineSlug)
        ('- dispatch-slug: ' + $DispatchSlug)
        ('- status: ' + $Status)
        ('- evidence-pack: ' + $EvidencePackPath)
        ('- evidence-pack-sha256: ' + $EvidencePackSha256)
        ('- evidence-pack-length: ' + $(if ($null -eq $EvidencePackLength) { '<unknown>' } else { [string]$EvidencePackLength }))
        ('- activation-mode: ' + $activationMode)
        ('- authorization-source: ' + $(if ($null -eq $authorizationSource) { '<null>' } else { [string]$authorizationSource }))
        ('- reserve-bypassed: ' + [string]$reserveBypassed)
        ('- advisor-hard-limit-percent: ' + $(if ($null -eq $hardLimit) { '<null>' } else { [string]$hardLimit }))
        ('- advisor-unit-estimate-percent: ' + $(if ($null -eq $unitEstimate) { '<null>' } else { [string]$unitEstimate }))
        ''
        '## 中斷保全結論'
        ''
        $message
        ''
        '## 證據支持'
        ''
        ('- evidence pack 已通過 schema、line slug、dispatch slug 與 SHA-256 驗證：' + $EvidencePackSha256)
        ''
        '## 推論'
        ''
        '- 僅依 evidence pack 與執行端訊息整理，未加入 repository 探索結果。'
        ''
        '## 未決問題'
        ''
        '- 由 Claude 端依證據支持內容決定是否採用本報告。'
        ''
        '## Required output gate'
        ''
        ('- declared: ' + (($declaredOutput -join '; ')))
        ('- present: ' + (($presentOutput -join '; ')))
        ('- missing: ' + (($missingOutput -join '; ')))
        ('- valid: ' + [string]$gateValid)
        ''
        '## ScopePlan units'
        ''
        ('- requested: ' + (($requestedUnits | ForEach-Object { [string]$_ }) -join '; '))
        ('- selected: ' + (($selectedUnits | ForEach-Object { [string]$_ }) -join '; '))
        ('- deferred: ' + (($deferredUnits | ForEach-Object { [string]$_ }) -join '; '))
        ('- completion-partition-status: ' + [string]$completionPartition.status)
        ('- completion-partition-reason: ' + [string]$completionPartition.reason)
        ('- completed: ' + (($completedUnits | ForEach-Object { [string]$_ }) -join '; '))
        ('- incomplete: ' + (($incompleteUnits | ForEach-Object { [string]$_ }) -join '; '))
        ('- decision: ' + $(if ($null -eq $ScopePlan) { '<null>' } else { [string]$ScopePlan.decision }))
        ('- primary-budget-percent: ' + $(if ($null -eq $ScopePlan) { '<null>' } else { [string]$ScopePlan.primary_budget_percent }))
        ('- primary-reserve-percent: ' + $(if ($null -eq $ScopePlan) { '<null>' } else { [string]$ScopePlan.primary_reserve_percent }))
        ''
        '## Interruption status'
        ''
        (($InterruptionStatus | ConvertTo-Json -Depth 20))
        ''
        '## Budget monitor'
        ''
        ('```json')
        (($BudgetMonitor | ConvertTo-Json -Depth 20))
        '```'
        ''
    ) -join "`r`n"
    Write-Utf8NoBom -Path $fullPath -Content $content
    return $fullPath
}

function Get-CalibrationRecords {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $record = $line | ConvertFrom-Json -ErrorAction Stop
            $records.Add($record)
        }
        catch {
            throw "額度校準紀錄格式錯誤：$Path；$($_.Exception.Message)"
        }
    }

    return @($records.ToArray())
}

function Add-AtomicJsonLine {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList @($false)
    $bytes = $encoding.GetBytes($Content + [Environment]::NewLine)
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $stream = $null
        try {
            $stream = New-Object System.IO.FileStream(
                $Path,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::Read
            )
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            return
        }
        catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "JSONL 互斥追加逾時：$Path；$($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds 100
        }
        finally {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "JSONL 互斥追加失敗：$Path"
}



function Get-ManifestProperty {
    param(
        [Parameter(Mandatory)]
        [psobject]$Manifest,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Manifest.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or -not ($property.Value -is [string])) {
        throw "line.json 缺少欄位：$Name"
    }

    return $property.Value
}

function Read-LineManifest {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$LineSlug
    )

    $sourceLineRoot = Join-Path -Path $SourceRoot -ChildPath (Join-Path -Path '.local\ai-sessions\handoff' -ChildPath $LineSlug)
    $manifestPath = Join-Path -Path $sourceLineRoot -ChildPath 'line.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "找不到 LineContext manifest：$manifestPath"
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "line.json 格式錯誤：$manifestPath；$($_.Exception.Message)"
    }

    $schema = Get-ManifestProperty -Manifest $manifest -Name 'schema'
    $manifestLineSlug = Get-ManifestProperty -Manifest $manifest -Name 'line-slug'
    if ($schema -ne 'ai-sessions.line.v1') {
        throw "line.json schema 不符：$manifestPath；實際值：$schema"
    }
    if ($manifestLineSlug -ne $LineSlug) {
        throw "line.json line-slug 與輸入不一致：$manifestPath；實際值：$manifestLineSlug；輸入值：$LineSlug"
    }

    return [pscustomobject]@{
        Path           = $manifestPath
        SourceLineRoot = $sourceLineRoot
        Manifest       = $manifest
    }
}

function Get-KeyValueFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $values = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match '^([^=]+)=(.*)$') {
            $values[$matches[1]] = $matches[2]
        }
    }

    return [pscustomobject]$values
}

function Get-WindowsProcessSnapshot {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessId,

        [Parameter(Mandatory)]
        [hashtable]$ProcessesById
    )

    if (-not $ProcessesById.ContainsKey($ProcessId)) {
        return $null
    }

    return $ProcessesById[$ProcessId]
}

function Get-WindowsProcessSnapshots {
    param(
        [switch]$FailOnError
    )

    $snapshots = @{}
    $unconfirmedProcesses = New-Object System.Collections.Generic.List[object]
    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    }
    catch {
        throw "無法查詢 Win32_Process 以驗證 PID 身分：$($_.Exception.Message)"
    }

    foreach ($process in $processes) {
        $missingFields = New-Object System.Collections.Generic.List[string]
        $conversionFailures = New-Object System.Collections.Generic.List[string]
        $processId = 0
        $parentProcessId = 0
        $reportedProcessId = '<missing>'
        $reportedParentProcessId = '<missing>'
        $name = $null
        $creationUtc = $null

        $nameProperty = $process.PSObject.Properties['Name']
        if ($null -eq $nameProperty) {
            $missingFields.Add('Name')
        }
        else {
            try {
                if ($null -eq $nameProperty.Value) {
                    throw '值為 null。'
                }
                $nameValue = [string]$nameProperty.Value
                if ([string]::IsNullOrWhiteSpace($nameValue)) {
                    throw '值為空白。'
                }
                $name = [System.IO.Path]::GetFileNameWithoutExtension($nameValue)
            }
            catch {
                $conversionFailures.Add('Name')
            }
        }

        $creationProperty = $process.PSObject.Properties['CreationDate']
        if ($null -eq $creationProperty) {
            $missingFields.Add('CreationDate')
        }
        else {
            try {
                if ($null -eq $creationProperty.Value) {
                    throw '值為 null。'
                }
                $creationUtc = ([datetime]$creationProperty.Value).ToUniversalTime()
            }
            catch {
                $conversionFailures.Add('CreationDate')
            }
        }

        $processIdProperty = $process.PSObject.Properties['ProcessId']
        if ($null -eq $processIdProperty) {
            $missingFields.Add('ProcessId')
        }
        else {
            try {
                if ($null -eq $processIdProperty.Value -or -not [int]::TryParse([string]$processIdProperty.Value, [ref]$processId) -or $processId -le 0) {
                    throw '無法轉換為正整數。'
                }
            }
            catch {
                $conversionFailures.Add('ProcessId')
                $processId = 0
            }
            if ($null -eq $processIdProperty.Value) {
                $reportedProcessId = '<null>'
            }
            else {
                $reportedProcessId = [string]$processIdProperty.Value
            }
        }

        $parentProcessIdProperty = $process.PSObject.Properties['ParentProcessId']
        if ($null -eq $parentProcessIdProperty) {
            $missingFields.Add('ParentProcessId')
        }
        else {
            try {
                if ($null -eq $parentProcessIdProperty.Value -or -not [int]::TryParse([string]$parentProcessIdProperty.Value, [ref]$parentProcessId) -or $parentProcessId -lt 0) {
                    throw '無法轉換為非負整數。'
                }
            }
            catch {
                $conversionFailures.Add('ParentProcessId')
                $parentProcessId = 0
            }
            if ($null -eq $parentProcessIdProperty.Value) {
                $reportedParentProcessId = '<null>'
            }
            else {
                $reportedParentProcessId = [string]$parentProcessIdProperty.Value
            }
        }

        $identityStatus = 'confirmed'
        if ($conversionFailures.Count -gt 0) {
            $identityStatus = 'unconfirmable'
        }
        elseif ($missingFields.Count -gt 0) {
            $identityStatus = 'missing-field'
        }

        $snapshot = [pscustomobject]@{
            ProcessId             = if ($processId -gt 0) { $processId } else { $null }
            ParentProcessId       = $parentProcessId
            ReportedProcessId     = $reportedProcessId
            ReportedParentProcessId = $reportedParentProcessId
            ProcessName           = $name
            CreationUtc           = $creationUtc
            IdentityStatus        = $identityStatus
            IdentityMissingFields = @($missingFields.ToArray())
            IdentityFailureFields = @($conversionFailures.ToArray())
        }

        if ($processId -gt 0) {
            $snapshots[$processId] = $snapshot
        }

        if ($identityStatus -ne 'confirmed' -and $processId -gt 0) {
            $unconfirmedProcesses.Add($snapshot)
        }
    }

    return [pscustomobject]@{
        ById               = $snapshots
        UnconfirmedProcesses = @($unconfirmedProcesses.ToArray())
    }
}

function Format-UnconfirmedProcessDetails {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Processes
    )

    $details = New-Object System.Collections.Generic.List[string]
    foreach ($process in @($Processes)) {
        $processIdText = '<unknown>'
        $processIdProperty = $process.PSObject.Properties['ProcessId']
        if ($null -ne $processIdProperty -and $null -ne $processIdProperty.Value) {
            $processIdText = [string]$processIdProperty.Value
        }
        else {
            $reportedProcessIdProperty = $process.PSObject.Properties['ReportedProcessId']
            if ($null -ne $reportedProcessIdProperty -and -not [string]::IsNullOrWhiteSpace([string]$reportedProcessIdProperty.Value)) {
                $processIdText = [string]$reportedProcessIdProperty.Value
            }
        }

        $identityStatusText = '<unknown>'
        $identityStatusProperty = $process.PSObject.Properties['IdentityStatus']
        if ($null -ne $identityStatusProperty) {
            $identityStatusText = [string]$identityStatusProperty.Value
        }

        $missingFields = @()
        $missingFieldsProperty = $process.PSObject.Properties['IdentityMissingFields']
        if ($null -ne $missingFieldsProperty) {
            $missingFields = @($missingFieldsProperty.Value)
        }
        $failureFields = @()
        $failureFieldsProperty = $process.PSObject.Properties['IdentityFailureFields']
        if ($null -ne $failureFieldsProperty) {
            $failureFields = @($failureFieldsProperty.Value)
        }

        $missingFieldsText = if ($missingFields.Count -gt 0) { $missingFields -join ',' } else { '<none>' }
        $failureFieldsText = if ($failureFields.Count -gt 0) { $failureFields -join ',' } else { '<none>' }
        $details.Add(('pid={0}; identity-status={1}; missing-fields={2}; conversion-failure-fields={3}' -f $processIdText, $identityStatusText, $missingFieldsText, $failureFieldsText))
    }

    return @($details.ToArray())
}

function Get-UnixProcessSnapshot {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessId
    )

    $psPath = Get-CommandPath -Name 'ps'
    $result = Invoke-ExternalCommand -FileName $psPath -WorkingDirectory (Get-Location).Path -Arguments @('-o', 'pid=,ppid=,pgid=,comm=', '-p', [string]$ProcessId) -AllowFailure
    if ($result.ExitCode -ne 0) {
        if ($result.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($result.StdOut) -and [string]::IsNullOrWhiteSpace($result.StdErr)) {
            return $null
        }
        throw "無法查詢 Unix PID $ProcessId：exit code $($result.ExitCode)；$($result.StdErr.Trim())"
    }

    $line = @($result.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($line)) {
        return $null
    }

    $fields = $line.Trim() -split '\s+', 4
    if ($fields.Count -lt 4) {
        throw "Unix PID 查詢結果格式錯誤：$($result.StdOut.Trim())"
    }

    $parsedPid = 0
    $parsedParentId = 0
    $parsedGroupId = 0
    if (-not [int]::TryParse($fields[0], [ref]$parsedPid) -or $parsedPid -ne $ProcessId -or -not [int]::TryParse($fields[1], [ref]$parsedParentId) -or $parsedParentId -lt 0 -or -not [int]::TryParse($fields[2], [ref]$parsedGroupId) -or $parsedGroupId -le 0) {
        throw "Unix PID 查詢結果無法取得有效 PID、parent PID 或 process group id：$($result.StdOut.Trim())"
    }
    $processName = $fields[3].Trim()
    if ([string]::IsNullOrWhiteSpace($processName)) {
        throw "Unix PID 查詢結果缺少 process name：$($result.StdOut.Trim())"
    }

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $creationUtc = $process.StartTime.ToUniversalTime()
    }
    catch {
        throw "無法取得 Unix PID $ProcessId 的建立時間：$($_.Exception.Message)"
    }

    return [pscustomobject]@{
        ProcessId             = $parsedPid
        ParentProcessId       = $parsedParentId
        ProcessName           = $processName
        CreationUtc           = $creationUtc
        ProcessGroupId        = $parsedGroupId
        IdentityStatus        = 'confirmed'
        IdentityMissingFields = @()
        IdentityFailureFields = @()
        IdentityVerified      = $true
    }
}

function Get-UnixProcessGroupMemberIds {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessGroupId
    )

    if ($ProcessGroupId -le 0) {
        throw "process-group-id 必須為正整數：$ProcessGroupId"
    }

    $psPath = Get-CommandPath -Name 'ps'
    $result = Invoke-ExternalCommand -FileName $psPath -WorkingDirectory (Get-Location).Path -Arguments @('-e', '-o', 'pid=,pgid=')
    $members = New-Object System.Collections.Generic.List[int]
    foreach ($line in @($result.StdOut -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $fields = $line.Trim() -split '\s+'
        if ($fields.Count -lt 2) {
            throw "Unix process group 查詢結果格式錯誤：$line"
        }
        $processId = 0
        $groupId = 0
        if (-not [int]::TryParse($fields[0], [ref]$processId) -or -not [int]::TryParse($fields[1], [ref]$groupId)) {
            throw "Unix process group 查詢結果無法解析：$line"
        }
        if ($groupId -eq $ProcessGroupId) {
            $members.Add($processId)
        }
    }

    return @($members.ToArray())
}

function Test-RecordedProcessIdentityFields {
    param(
        [Parameter(Mandatory)]
        [psobject]$Record
    )

    $recordNameProperty = $Record.PSObject.Properties['root-process-name']
    $recordStartedProperty = $Record.PSObject.Properties['root-started-at-utc']
    if ($null -eq $recordNameProperty -or $null -eq $recordStartedProperty -or [string]::IsNullOrWhiteSpace([string]$recordNameProperty.Value) -or [string]::IsNullOrWhiteSpace([string]$recordStartedProperty.Value)) {
        return $false
    }

    try {
        $null = ([datetime]$recordStartedProperty.Value).ToUniversalTime()
    }
    catch {
        return $false
    }

    return $true
}

function Test-RecordedIdentityEvidence {
    param(
        [Parameter(Mandatory)]
        [psobject]$Record
    )

    if (-not (Test-RecordedProcessIdentityFields -Record $Record)) {
        return $false
    }

    $verifiedProperty = $Record.PSObject.Properties['identity-verified']
    return $null -ne $verifiedProperty -and [string]::Equals([string]$verifiedProperty.Value, 'true', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-RecordedProcessIdentity {
    param(
        [Parameter(Mandatory)]
        [psobject]$Record,

        [Parameter(Mandatory)]
        [psobject]$Snapshot
    )

    if (-not (Test-RecordedProcessIdentityFields -Record $Record)) {
        return $false
    }

    $recordNameProperty = $Record.PSObject.Properties['root-process-name']
    $recordStartedProperty = $Record.PSObject.Properties['root-started-at-utc']

    if (-not [string]::Equals(
            ([System.IO.Path]::GetFileNameWithoutExtension([string]$recordNameProperty.Value)),
            $Snapshot.ProcessName,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    try {
        $recordStartedUtc = ([datetime]$recordStartedProperty.Value).ToUniversalTime()
    }
    catch {
        return $false
    }

    if ($null -eq $Snapshot.CreationUtc) {
        return $false
    }

    return [math]::Abs(($recordStartedUtc - $Snapshot.CreationUtc).TotalSeconds) -le 1
}

function Test-RecordedUnixProcessIdentity {
    param(
        [Parameter(Mandatory)]
        [psobject]$Record,

        [Parameter(Mandatory)]
        [psobject]$Snapshot
    )

    $groupProperty = $Record.PSObject.Properties['process-group-id']
    if ($null -eq $groupProperty) {
        return $false
    }

    $recordGroupId = 0
    if (-not [int]::TryParse([string]$groupProperty.Value, [ref]$recordGroupId) -or $recordGroupId -le 0) {
        return $false
    }

    if ($recordGroupId -ne $Snapshot.ProcessGroupId) {
        return $false
    }

    $identityStatusProperty = $Snapshot.PSObject.Properties['IdentityStatus']
    $identityVerifiedProperty = $Snapshot.PSObject.Properties['IdentityVerified']
    if ($null -eq $identityStatusProperty -or $identityStatusProperty.Value -ne 'confirmed' -or $null -eq $identityVerifiedProperty -or $identityVerifiedProperty.Value -ne $true) {
        return $false
    }

    return Test-RecordedProcessIdentity -Record $Record -Snapshot $Snapshot
}

function Get-DescendantProcessIds {
    param(
        [Parameter(Mandatory)]
        [int]$RootProcessId,

        [Parameter(Mandatory)]
        [hashtable]$ProcessesById,

        [switch]$ConfirmedOnly
    )

    $descendants = New-Object System.Collections.Generic.List[int]
    $pending = New-Object System.Collections.Generic.Queue[int]
    $pending.Enqueue($RootProcessId)
    while ($pending.Count -gt 0) {
        $parentId = $pending.Dequeue()
        foreach ($snapshot in $ProcessesById.Values) {
            $identityStatus = $snapshot.PSObject.Properties['IdentityStatus']
            if ($ConfirmedOnly -and ($null -eq $identityStatus -or $identityStatus.Value -ne 'confirmed')) {
                continue
            }
            if ($snapshot.ParentProcessId -eq $parentId -and -not $descendants.Contains($snapshot.ProcessId)) {
                $descendants.Add($snapshot.ProcessId)
                $pending.Enqueue($snapshot.ProcessId)
            }
        }
    }

    return @($descendants.ToArray())
}

function Get-PidCheckResult {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [ValidateSet('readonly', 'write')]
        [string]$WriteMode
    )

    $historyRoot = Join-Path -Path $SourceRoot -ChildPath '.local\ai-sessions\history'
    $records = @()
    if (Test-Path -LiteralPath $historyRoot -PathType Container) {
        $records = @(Get-ChildItem -LiteralPath $historyRoot -Filter 'codex-pid-*.txt' -File -ErrorAction Stop)
    }

    $active = New-Object System.Collections.Generic.List[object]
    $unconfirmedRecords = New-Object System.Collections.Generic.List[object]
    $unconfirmedProcesses = @()
    $processesById = @{}
    if ((Test-IsWindowsPlatform) -and $records.Count -gt 0) {
        $snapshotResult = Get-WindowsProcessSnapshots -FailOnError
        $processesById = $snapshotResult.ById
        $unconfirmedProcesses = @($snapshotResult.UnconfirmedProcesses)
    }

    foreach ($recordFile in $records) {
        $record = Get-KeyValueFile -Path $recordFile.FullName
        $workRootProperty = $record.PSObject.Properties['work-root']
        $lineProperty = $record.PSObject.Properties['line-slug']
        $rootPidProperty = $record.PSObject.Properties['root-pid']
        if ($null -eq $rootPidProperty) {
            $rootPidProperty = $record.PSObject.Properties['pid']
        }
        if ($null -eq $workRootProperty -or $null -eq $lineProperty -or $null -eq $rootPidProperty) {
            continue
        }
        try {
            $recordWorkRoot = Resolve-AbsolutePath -Path ([string]$workRootProperty.Value)
        }
        catch {
            continue
        }
        if (-not [string]::Equals($recordWorkRoot, $SourceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ([string]$lineProperty.Value -ne $LineSlug) {
            continue
        }

        $rootPid = 0
        if (-not [int]::TryParse([string]$rootPidProperty.Value, [ref]$rootPid) -or $rootPid -le 0) {
            continue
        }

        $recordMode = 'write'
        $modeProperty = $record.PSObject.Properties['write-mode']
        if ($null -ne $modeProperty -and [string]$modeProperty.Value -eq 'readonly') {
            $recordMode = 'readonly'
        }

            $isActive = $false
            $identityVerified = $false
            $liveProcessIds = @()
            if (Test-IsWindowsPlatform) {
                $rootSnapshot = Get-WindowsProcessSnapshot -ProcessId $rootPid -ProcessesById $processesById
                if ($null -ne $rootSnapshot) {
                    if ($rootSnapshot.IdentityStatus -ne 'confirmed') {
                    $dispatchProperty = $record.PSObject.Properties['dispatch-slug']
                    $unconfirmedRecords.Add([pscustomobject]@{
                            Path             = $recordFile.FullName
                            RootPid          = $rootPid
                            DispatchSlug     = if ($null -ne $dispatchProperty) { [string]$dispatchProperty.Value } else { '' }
                            IdentityStatus   = $rootSnapshot.IdentityStatus
                            MissingFields    = @($rootSnapshot.IdentityMissingFields)
                            FailureFields    = @($rootSnapshot.IdentityFailureFields)
                            TerminationScope = 'none'
                            StatusMessage    = '根程序身分無法確認，未阻塞派工且未列入終止對象。'
                        })
                    }
                    elseif (-not ([string]::Equals([string](Get-OptionalObjectProperty -Object $record -Name 'identity-verified'), 'true', [StringComparison]::OrdinalIgnoreCase))) {
                        $dispatchProperty = $record.PSObject.Properties['dispatch-slug']
                        $unconfirmedRecords.Add([pscustomobject]@{
                                Path             = $recordFile.FullName
                                RootPid          = $rootPid
                                DispatchSlug     = if ($null -ne $dispatchProperty) { [string]$dispatchProperty.Value } else { '' }
                                IdentityStatus   = 'record-identity-unconfirmed'
                                MissingFields    = @('identity-verified')
                                FailureFields    = @()
                                TerminationScope = 'none'
                                StatusMessage    = 'PID 紀錄標示身分未確認，程序仍存在時阻擋後續派工。'
                            })
                    }
                    elseif (Test-RecordedProcessIdentity -Record $record -Snapshot $rootSnapshot) {
                        $identityVerified = $true
                        $isActive = $true
                        $liveProcessIds = @(Get-DescendantProcessIds -RootProcessId $rootPid -ProcessesById $processesById -ConfirmedOnly)
                    }
                    else {
                        $dispatchProperty = $record.PSObject.Properties['dispatch-slug']
                        $unconfirmedRecords.Add([pscustomobject]@{
                                Path             = $recordFile.FullName
                                RootPid          = $rootPid
                                DispatchSlug     = if ($null -ne $dispatchProperty) { [string]$dispatchProperty.Value } else { '' }
                                IdentityStatus   = 'record-identity-mismatch'
                                MissingFields    = @()
                                FailureFields    = @('root-process-name', 'root-started-at-utc')
                                TerminationScope = 'none'
                                StatusMessage    = 'PID 紀錄與目前程序身分不一致，程序仍存在時阻擋後續派工。'
                            })
                    }
                }
            else {
                $dispatchProperty = $record.PSObject.Properties['dispatch-slug']
                $unconfirmedRecords.Add([pscustomobject]@{
                        Path             = $recordFile.FullName
                        RootPid          = $rootPid
                        DispatchSlug     = if ($null -ne $dispatchProperty) { [string]$dispatchProperty.Value } else { '' }
                        IdentityStatus   = 'root-process-absent'
                        MissingFields    = @()
                        FailureFields    = @()
                        TerminationScope = 'none'
                        StatusMessage    = '記錄的根程序已不存在，視為該次派遣已結束，未阻塞派工且未列入終止對象。'
                    })
            }
        }
        else {
            $groupProperty = $record.PSObject.Properties['process-group-id']
            if ($null -ne $groupProperty) {
                $recordGroupId = 0
                $groupValid = [int]::TryParse([string]$groupProperty.Value, [ref]$recordGroupId) -and $recordGroupId -gt 0
                $unixSnapshot = Get-UnixProcessSnapshot -ProcessId $rootPid
                if ($null -ne $unixSnapshot -and $groupValid -and (Test-RecordedUnixProcessIdentity -Record $record -Snapshot $unixSnapshot)) {
                    $identityVerified = $true
                    $liveProcessIds = @(Get-UnixProcessGroupMemberIds -ProcessGroupId $recordGroupId)
                    $isActive = $liveProcessIds.Count -gt 0
                }
                elseif ($null -eq $unixSnapshot -and $groupValid -and (Test-RecordedIdentityEvidence -Record $record)) {
                    $liveProcessIds = @(Get-UnixProcessGroupMemberIds -ProcessGroupId $recordGroupId)
                    $identityVerified = $liveProcessIds.Count -gt 0
                    $isActive = $identityVerified
                }
            }
        }

        if ($isActive -and $identityVerified) {
            $dispatchProperty = $record.PSObject.Properties['dispatch-slug']
            $dispatchValue = ''
            if ($null -ne $dispatchProperty) {
                $dispatchValue = [string]$dispatchProperty.Value
            }
            $active.Add([pscustomobject]@{
                    Path           = $recordFile.FullName
                    RootPid        = $rootPid
                    DispatchSlug   = $dispatchValue
                    WriteMode      = $recordMode
                    LiveProcessIds  = $liveProcessIds
                    IdentityVerified = $identityVerified
                    IdentityStatus = 'confirmed'
                })
        }
    }

    $activeArray = @($active.ToArray())
    $writeConflict = @($activeArray | Where-Object { $_.WriteMode -eq 'write' }).Count -gt 0
    $readonlyCount = @($activeArray | Where-Object { $_.WriteMode -eq 'readonly' }).Count
    $blocked = $false
    $reason = ''
    if ($WriteMode -eq 'write' -and ($writeConflict -or $readonlyCount -gt 0)) {
        $blocked = $true
        $reason = '同線已有活躍派遣，write 模式必須互斥。'
    }
    elseif ($WriteMode -eq 'readonly' -and $writeConflict) {
        $blocked = $true
        $reason = '同線已有 write 派遣，readonly 不得共用寫入面。'
    }
    elseif ($WriteMode -eq 'readonly' -and $readonlyCount -ge 2) {
        $blocked = $true
        $reason = '同線 readonly 活躍數已達上限 2。'
    }

    return [ordered]@{
        Checked         = $true
        Blocked         = $blocked
        Reason          = $reason
        ActiveCount     = $active.Count
        ActiveRecords   = $activeArray
        ReadonlyCount   = $readonlyCount
        WriteCount      = @($activeArray | Where-Object { $_.WriteMode -eq 'write' }).Count
        UnconfirmedProcesses = @($unconfirmedProcesses)
        UnconfirmedRecords = @($unconfirmedRecords.ToArray())
        IdentityRule    = 'Windows 以 root-process-name、root-started-at-utc 與 Win32_Process 比對；Unix 依記錄的 process group 與根程序核對。'
    }
}

function Initialize-TemporaryGitRepository {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot
    )

    $gitignorePath = Join-Path -Path $SourceRoot -ChildPath '.gitignore'
    if (-not (Test-Path -LiteralPath $gitignorePath -PathType Leaf)) {
        Write-Utf8NoBom -Path $gitignorePath -Content "bin/`nobj/`nnode_modules/`n.env`n.local/`n"
    }

    $null = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments @('init')
    $null = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments @('add', '--all')
    $null = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments @('-c', 'user.name=codex-dispatch', '-c', 'user.email=codex-dispatch@local', 'commit', '--allow-empty', '-m', 'chore: initialize dispatch fixture')

    $markerPath = Join-Path -Path $SourceRoot -ChildPath '.local\ai-sessions\agent-created-git.marker'
    $markerContent = @(
        'schema=codex-dispatch.temp-git.v1'
        'created-by=codex-dispatch'
        ('work-root=' + $SourceRoot)
        ('created-at-utc=' + [datetime]::UtcNow.ToString('o'))
    ) -join "`n"
    Write-Utf8NoBom -Path $markerPath -Content ($markerContent + "`n")

    return [ordered]@{
        GitOrigin  = 'agent-created'
        MarkerPath = $markerPath
    }
}

function Get-GitRepositoryState {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot
    )

    $existingState = Get-ExistingGitRepositoryState -SourceRoot $SourceRoot
    if ($existingState.IsRepository) {
        return [ordered]@{
            GitOrigin  = 'existing'
            MarkerPath = ''
        }
    }

    return Initialize-TemporaryGitRepository -SourceRoot $SourceRoot
}

function Get-ExistingGitRepositoryState {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot
    )

    $probe = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments @('-C', $SourceRoot, 'rev-parse', '--is-inside-work-tree') -AllowFailure
    if ($probe.ExitCode -eq 0 -and $probe.StdOut.Trim() -eq 'true') {
        return [ordered]@{
            IsRepository = $true
            GitOrigin    = 'existing'
            MarkerPath   = ''
        }
    }

    $notRepository = $probe.StdErr -match '(?i)not a git repository|不是 git 儲存庫'
    if ($probe.ExitCode -ne 0 -and $notRepository) {
        return [ordered]@{
            IsRepository = $false
            GitOrigin    = 'not-a-repository'
            MarkerPath   = ''
        }
    }

    throw "Git 前置探針失敗，未判定為可初始化的目錄。exit code $($probe.ExitCode)：$($probe.StdErr.Trim())"
}

function Get-GitOutputLines {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return @()
    }

    $nul = [char]0
    $values = @($Text -split $nul | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($values.Count -eq 1 -and $values[0] -notmatch [string]$nul) {
        $values = @($values[0] -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    return @($values | ForEach-Object { $_.TrimEnd("`r", "`n") })
}

function Get-TrackedPathState {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string[]]$TargetPath
    )

    $states = New-Object System.Collections.Generic.List[object]
    foreach ($target in $TargetPath) {
        $fullPath = Resolve-SourceTargetPath -Path $target -Root $SourceRoot
        $relativePath = Get-RelativePathFromRoot -Path $fullPath -Root $SourceRoot
        $trackedResult = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments @('ls-files', '--error-unmatch', '--', $relativePath) -AllowFailure
        $isTracked = $false
        if ($trackedResult.ExitCode -eq 0) {
            if ([string]::IsNullOrWhiteSpace($trackedResult.StdOut)) {
                throw "git ls-files 成功但未回傳 tracked 路徑：$relativePath"
            }
            $isTracked = $true
        }
        elseif ($trackedResult.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($trackedResult.StdOut) -and $trackedResult.StdErr -match '(?i)did not match any file|did not match any files|not match any file') {
            $isTracked = $false
        }
        else {
            throw "git ls-files 探針失敗，無法判定 tracked 狀態：$relativePath；exit code $($trackedResult.ExitCode)；$($trackedResult.StdErr.Trim())"
        }

        $ignoredResult = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments @('check-ignore', '--quiet', '--no-index', '--', $relativePath) -AllowFailure
        if ($ignoredResult.ExitCode -eq 0) {
            $isIgnored = $true
        }
        elseif ($ignoredResult.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($ignoredResult.StdErr)) {
            $isIgnored = $false
        }
        else {
            throw "git check-ignore 探針失敗，無法判定 ignored 狀態：$relativePath；exit code $($ignoredResult.ExitCode)；$($ignoredResult.StdErr.Trim())"
        }

        $states.Add([pscustomobject]@{
                InputPath    = $target
                FullPath     = $fullPath
                RelativePath = $relativePath
                Exists       = Test-Path -LiteralPath $fullPath
                IsTracked    = $isTracked
                IsIgnored     = $isIgnored
                IsNewOutput   = -not $isTracked
            })
    }

    return @($states.ToArray())
}

function Get-NonGitTargetState {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string[]]$TargetPath
    )

    $states = New-Object System.Collections.Generic.List[object]
    foreach ($target in $TargetPath) {
        $fullPath = Resolve-SourceTargetPath -Path $target -Root $SourceRoot
        $states.Add([pscustomobject]@{
                InputPath    = $target
                FullPath     = $fullPath
                RelativePath = Get-RelativePathFromRoot -Path $fullPath -Root $SourceRoot
                Exists       = Test-Path -LiteralPath $fullPath
                IsTracked    = $false
                IsIgnored    = $false
                IsNewOutput  = -not (Test-Path -LiteralPath $fullPath)
            })
    }

    return @($states.ToArray())
}

function Get-RequiredPreflightProperty {
    param(
        [Parameter(Mandatory)]
        [psobject]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or -not ($property.Value -is [string]) -or [string]::IsNullOrWhiteSpace($property.Value)) {
        throw "Preflight 輸出缺少必要欄位：$Name"
    }

    return $property.Value
}

function Apply-SourceCarryIn {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$DispatchRoot
    )

    $diffResult = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments @('diff', 'HEAD', '--binary', '--no-ext-diff', '--')
    $trackedPatch = $diffResult.StdOut
    $untrackedResult = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments @('ls-files', '--others', '--exclude-standard', '-z')
    $untrackedFiles = @(Get-GitOutputLines -Text $untrackedResult.StdOut)
    $copiedFiles = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrEmpty($trackedPatch)) {
        $applyResult = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('apply', '--whitespace=nowarn', '--recount', '-') -StandardInput $trackedPatch -AllowFailure
        if ($applyResult.ExitCode -ne 0) {
            throw "套用來源 tracked patch 失敗，來源變更已保留。$($applyResult.StdErr.Trim())"
        }
    }

    foreach ($relativePath in $untrackedFiles) {
        $sourcePath = Resolve-SourceTargetPath -Path $relativePath -Root $SourceRoot
        $destinationPath = Resolve-SourceTargetPath -Path $relativePath -Root $DispatchRoot
        if (-not (Test-PathWithinRoot -Path $sourcePath -Root $SourceRoot) -or -not (Test-PathWithinRoot -Path $destinationPath -Root $DispatchRoot)) {
            throw "未追蹤檔案路徑超出根目錄界線：$relativePath"
        }
        if (Test-Path -LiteralPath $destinationPath) {
            throw "未追蹤檔案目的路徑已存在，停止避免覆寫：$destinationPath"
        }
        $destinationParent = Split-Path -Parent $destinationPath
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force:$false
        $copiedFiles.Add($relativePath)
    }

    return [ordered]@{
        TrackedPatchApplied = -not [string]::IsNullOrEmpty($trackedPatch)
        TrackedPatchLength  = $trackedPatch.Length
        UntrackedFiles      = @($untrackedFiles)
        CopiedFiles         = @($copiedFiles.ToArray())
    }
}

function Get-DispatchSnapshotPath {
    [CmdletBinding()]
    param([string]$Root, [string]$Path)

    if ([string]::IsNullOrEmpty($Path) -or $Path.Contains('\') -or $Path.Contains(':') -or [IO.Path]::IsPathRooted($Path) -or @($Path.Split('/') | Where-Object { $_ -in @('', '.', '..', '.git') }).Count -gt 0) {
        throw "Baseline 相對路徑異常：$Path"
    }
    $rootPath = Resolve-AbsolutePath $Root
    $current = $rootPath
    foreach ($part in @('') + $Path.Split('/')) {
        if ($part.Length -gt 0) { $current = Join-Path $current $part }
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Baseline 不支援重解析點：$Path" }
        }
    }
    if (-not (Test-PathWithinRoot $current $rootPath)) { throw "Baseline 路徑超出工作樹：$Path" }
    return $current
}

function Get-DispatchWorkingTreeModes {
    [CmdletBinding()]
    param([string]$DispatchRoot)

    $result = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('diff-files', '--raw', '-z', '--')
    $parts = @($result.StdOut.Split([char]0) | Where-Object { $_.Length -gt 0 })
    if (($parts.Count % 2) -ne 0) { throw 'Baseline Git working tree mode 輸出格式異常。' }

    $modes = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    for ($index = 0; $index -lt $parts.Count; $index += 2) {
        $header = $parts[$index]
        $path = $parts[$index + 1]
        if ($header -notmatch '^:(?<oldMode>[0-7]{6}) (?<newMode>[0-7]{6}) (?<oldObject>[0-9a-fA-F]{40,64}) (?<newObject>[0-9a-fA-F]{40,64}) (?<status>[A-Z])$' -or [string]::IsNullOrEmpty($path)) {
            throw 'Baseline Git working tree mode 輸出格式異常。'
        }
        if ($Matches.newMode -in @('100644', '100755')) {
            $modes[$path] = $Matches.newMode
        }
    }

    return $modes
}

function Get-DispatchFileSnapshot {
    [CmdletBinding()]
    param([string]$DispatchRoot, [string]$BaseSha)

    if ($BaseSha -notmatch '^[a-fA-F0-9]{7,64}$') { throw 'Baseline baseSha 格式異常。' }
    $paths = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
    $modes = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $tree = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('ls-tree', '-r', '-z', $BaseSha, '--')
    foreach ($entry in $tree.StdOut.Split([char]0)) {
        if ($entry.Length -eq 0) { continue }
        $separator = $entry.IndexOf("`t")
        if ($separator -lt 0) { throw 'Baseline Git tree 輸出格式異常。' }
        $header = $entry.Substring(0, $separator).Split(' ')
        $path = $entry.Substring($separator + 1)
        if ($header.Count -ne 3 -or $header[0] -notin @('100644', '100755') -or $header[1] -ne 'blob') { throw "Baseline 不支援 Git kind：$path" }
        $null = $paths.Add($path)
        $modes[$path] = $header[0]
    }
    $index = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('ls-files', '--stage', '-z')
    foreach ($entry in $index.StdOut.Split([char]0)) {
        if ($entry.Length -eq 0) { continue }
        $separator = $entry.IndexOf("`t")
        if ($separator -lt 0) { throw 'Baseline Git index 輸出格式異常。' }
        $header = $entry.Substring(0, $separator).Split(' ')
        $path = $entry.Substring($separator + 1)
        if ($header.Count -ne 3 -or $header[0] -notin @('100644', '100755') -or $header[2] -ne '0') { throw "Baseline 不支援 Git kind 或未解決 index：$path" }
        $null = $paths.Add($path)
        $modes[$path] = $header[0]
    }
    $workingTreeModes = Get-DispatchWorkingTreeModes -DispatchRoot $DispatchRoot
    $untracked = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('ls-files', '--others', '--exclude-standard', '-z')
    foreach ($path in $untracked.StdOut.Split([char]0)) {
        if ($path.Length -eq 0) { continue }
        $null = $paths.Add($path)
        if (-not $modes.ContainsKey($path)) { $modes[$path] = '100644' }
    }
    foreach ($path in $paths) {
        $fullPath = Get-DispatchSnapshotPath -Root $DispatchRoot -Path $path
        $exists = Test-Path -LiteralPath $fullPath
        $length = 0L
        $hash = $null
        if ($exists) {
            $item = Get-Item -LiteralPath $fullPath -Force
            if ($item.PSIsContainer) { throw "Baseline 不支援目錄 kind：$path" }
            $length = $item.Length
            $hash = Get-FileSha256 $fullPath
        }
        $gitMode = $modes[$path]
        if ($workingTreeModes.ContainsKey($path)) { $gitMode = $workingTreeModes[$path] }
        [pscustomobject]@{ path = $path; kind = 'file'; exists = [bool]$exists; byte_length = $length; sha256 = $hash; git_mode = $gitMode }
    }
}

function New-DispatchBaseline {
    [CmdletBinding()]
    param(
        [string]$SourceRoot, [string]$DispatchRoot,
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$LineSlug,
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$DispatchSlug,
        [string]$BaseSha
    )

    $record = [ordered]@{
        schema = 'ai-sessions.dispatch-baseline.v1'
        baseline_id = [guid]::NewGuid().ToString('D')
        line_slug = $LineSlug
        dispatch_slug = $DispatchSlug
        source_root = Resolve-AbsolutePath $SourceRoot
        dispatch_root = Resolve-AbsolutePath $DispatchRoot
        base_sha = $BaseSha
        created_at_utc = [datetime]::UtcNow.ToString('o')
        files = @(Get-DispatchFileSnapshot -DispatchRoot $DispatchRoot -BaseSha $BaseSha)
    }
    $directory = Join-Path (Join-Path (Join-Path $record.source_root '.local/ai-sessions/history') $LineSlug) 'baselines'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $path = Join-Path $directory ($DispatchSlug + '-' + $record.baseline_id + '.json')
    $temporaryPath = Join-Path $directory ([guid]::NewGuid().ToString('D') + '.tmp')
    Write-Utf8NoBom $temporaryPath (($record | ConvertTo-Json -Depth 12) + "`n")
    [IO.File]::Move((ConvertTo-FileSystemApiPath -Path $temporaryPath), (ConvertTo-FileSystemApiPath -Path $path))
    return [pscustomobject]@{ Path = $path; Sha256 = Get-FileSha256 $path }
}

function Read-DispatchBaseline {
    [CmdletBinding()]
    param([string]$Path, [string]$Sha256, [string]$SourceRoot, [string]$DispatchRoot, [string]$LineSlug, [string]$DispatchSlug, [string]$BaseSha)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw '缺少有效 Baseline 路徑或 SHA-256。' }
    $pathValue = Resolve-AbsolutePath $Path
    if ((Get-FileSha256 $pathValue) -ine $Sha256) { throw 'Baseline SHA-256 不一致。' }
    $record = ConvertFrom-DispatchJson -Content (Get-Content -LiteralPath $pathValue -Raw -Encoding UTF8)
    if ($null -eq $record -or $record -isnot [pscustomobject]) { throw 'Baseline 必須為 JSON object。' }
    foreach ($name in @('schema', 'baseline_id', 'line_slug', 'dispatch_slug', 'source_root', 'dispatch_root', 'base_sha', 'created_at_utc')) {
        $property = $record.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($property.Value)) { throw "Baseline 欄位異常：$name" }
    }
    $id = [guid]::Empty
    $created = [datetimeoffset]::MinValue
    if (-not [guid]::TryParseExact($record.baseline_id, 'D', [ref]$id) -or $record.created_at_utc -notmatch '^\d{4}-\d{2}-\d{2}T.*(?:Z|\+00:00)$' -or -not [datetimeoffset]::TryParse($record.created_at_utc, [ref]$created) -or $created.Offset -ne [timespan]::Zero) { throw 'Baseline ID 或 UTC 時間異常。' }
    if ($record.schema -cne 'ai-sessions.dispatch-baseline.v1' -or $record.line_slug -cne $LineSlug -or $record.dispatch_slug -cne $DispatchSlug -or $record.base_sha -cne $BaseSha) { throw 'Baseline schema／line／dispatch／baseSha 不一致。' }
    foreach ($entry in @(@('source_root', $SourceRoot), @('dispatch_root', $DispatchRoot))) {
        if (-not [string]::Equals($record.($entry[0]), (Resolve-AbsolutePath $entry[1]), [StringComparison]::OrdinalIgnoreCase)) { throw 'Baseline roots 不一致。' }
    }
    $directory = Join-Path (Join-Path (Join-Path (Resolve-AbsolutePath $SourceRoot) '.local/ai-sessions/history') $LineSlug) 'baselines'
    $expectedPath = Join-Path $directory ($DispatchSlug + '-' + $record.baseline_id + '.json')
    if (-not [string]::Equals($pathValue, $expectedPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'Baseline 路徑與身分不一致。' }
    $filesProperty = $record.PSObject.Properties['files']
    if ($null -eq $filesProperty -or $filesProperty.Value -isnot [array]) { throw 'Baseline files 必須為陣列。' }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $previousPath = $null
    foreach ($file in $record.files) {
        if ($null -eq $file -or $file -isnot [pscustomobject]) { throw 'Baseline file 必須為 object。' }
        foreach ($name in @('path', 'kind', 'exists', 'byte_length', 'sha256', 'git_mode')) {
            if ($null -eq $file.PSObject.Properties[$name]) { throw "Baseline file 缺少欄位：$name" }
        }
        if ($file.path -isnot [string] -or -not $seen.Add($file.path) -or ($null -ne $previousPath -and [string]::CompareOrdinal($previousPath, $file.path) -ge 0)) { throw 'Baseline file 路徑重複或未排序。' }
        $null = Get-DispatchSnapshotPath -Root $DispatchRoot -Path $file.path
        $previousPath = $file.path
        if ($file.kind -cne 'file' -or $file.exists -isnot [bool] -or $file.git_mode -cnotin @('100644', '100755') -or ($file.byte_length -isnot [int] -and $file.byte_length -isnot [long]) -or $file.byte_length -lt 0) { throw "Baseline file kind／狀態異常：$($file.path)" }
        if ($file.exists) {
            if ($file.sha256 -isnot [string] -or $file.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Baseline file hash 異常：$($file.path)" }
        }
        elseif ($null -ne $file.sha256 -or $file.byte_length -ne 0) { throw "Baseline absent 欄位異常：$($file.path)" }
    }
    return $record
}

function Get-DispatchIncrementalChanges {
    [CmdletBinding()]
    param([psobject]$Baseline, [string]$DispatchRoot)

    $before = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $after = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $paths = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
    foreach ($file in $Baseline.files) { $before[$file.path] = $file; $null = $paths.Add($file.path) }
    foreach ($file in @(Get-DispatchFileSnapshot -DispatchRoot $DispatchRoot -BaseSha $Baseline.base_sha)) { $after[$file.path] = $file; $null = $paths.Add($file.path) }
    foreach ($path in $paths) {
        $old = if ($before.ContainsKey($path)) { $before[$path] } else { $null }
        $new = if ($after.ContainsKey($path)) { $after[$path] } else { $null }
        $oldExists = $null -ne $old -and $old.exists
        $newExists = $null -ne $new -and $new.exists
        if ($oldExists -ne $newExists -or ($oldExists -and ($old.kind -cne $new.kind -or $old.git_mode -cne $new.git_mode -or $old.byte_length -ne $new.byte_length -or $old.sha256 -ine $new.sha256))) { $path }
    }
}

function Resolve-DispatchBaselineBinding {
    [CmdletBinding()]
    param([psobject]$Preflight, [string]$SourceRoot, [string]$DispatchRoot, [string]$LineSlug, [string]$DispatchSlug, [string]$BaseSha, [string]$Path, [string]$Sha256)

    if ($null -ne $Preflight) {
        foreach ($entry in @(@('sourceRoot', $SourceRoot), @('executionRoot', $DispatchRoot), @('dispatchRoot', $DispatchRoot))) {
            if (-not [string]::Equals((Get-RequiredPreflightProperty $Preflight $entry[0]), (Resolve-AbsolutePath $entry[1]), [StringComparison]::OrdinalIgnoreCase)) { throw 'Baseline Preflight roots 不一致。' }
        }
        foreach ($entry in @(@('lineSlug', $LineSlug), @('dispatchSlug', $DispatchSlug), @('baseSha', $BaseSha))) {
            if ((Get-RequiredPreflightProperty $Preflight $entry[0]) -cne $entry[1]) { throw 'Baseline Preflight 身分或 baseSha 不一致。' }
        }
        $boundPath = Get-RequiredPreflightProperty $Preflight 'baselinePath'
        $boundHash = Get-RequiredPreflightProperty $Preflight 'baselineSha256'
        if ((-not [string]::IsNullOrWhiteSpace($Path) -and -not [string]::Equals((Resolve-AbsolutePath $Path), $boundPath, [StringComparison]::OrdinalIgnoreCase)) -or (-not [string]::IsNullOrWhiteSpace($Sha256) -and $Sha256 -ine $boundHash)) { throw 'Baseline 顯式輸入與 Preflight 不一致。' }
        $Path = $boundPath
        $Sha256 = $boundHash
    }
    $record = Read-DispatchBaseline -Path $Path -Sha256 $Sha256 -SourceRoot $SourceRoot -DispatchRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -BaseSha $BaseSha
    return [pscustomobject]@{ Path = Resolve-AbsolutePath $Path; Sha256 = $Sha256; Record = $record }
}

function ConvertTo-CanonicalAclFlagList {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    $rawValues = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        if ($null -eq $item) {
            continue
        }
        foreach ($part in ([string]$item -split ',')) {
            $trimmed = $part.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed) -and -not $rawValues.Contains($trimmed)) {
                $rawValues.Add($trimmed)
            }
        }
    }
    $orderedNames = @('ObjectInherit', 'ContainerInherit', 'InheritOnly', 'NoPropagateInherit')
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($name in $orderedNames) {
        if ($rawValues -contains $name) {
            $result.Add($name)
        }
    }
    foreach ($valueName in $rawValues) {
        if ($orderedNames -notcontains $valueName) {
            $result.Add($valueName)
        }
    }
    return @($result.ToArray())
}

function ConvertTo-CanonicalAclRights {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'Unknown'
    }
    if ($Value -match 'FullControl') {
        return 'F'
    }
    if ($Value -match 'Modify') {
        return 'M'
    }
    if ($Value -match 'ReadAndExecute') {
        return 'RX'
    }
    if ($Value -match 'Read') {
        return 'R'
    }
    if ($Value -match 'Write') {
        return 'W'
    }
    return (($Value -replace '\s+', '') -replace ',', '+')
}

function Get-AclIdentityResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Identity
    )

    if ($Identity -notmatch '^S-\d-\d+(?:-\d+)+$') {
        return 'resolved'
    }
    try {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($Identity)
        $null = $sid.Translate([System.Security.Principal.NTAccount])
        return 'resolved'
    }
    catch {
        return 'unresolved'
    }
}

function Get-CanonicalAclEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Entry
    )

    $identity = [string](Get-DispatchJsonProperty -Object $Entry -Name 'identity')
    $accessType = [string](Get-DispatchJsonProperty -Object $Entry -Name 'access_control_type')
    $rights = [string](Get-DispatchJsonProperty -Object $Entry -Name 'rights')
    $inheritance = ConvertTo-CanonicalAclFlagList -Value (Get-DispatchJsonProperty -Object $Entry -Name 'inheritance_flags')
    $propagation = ConvertTo-CanonicalAclFlagList -Value (Get-DispatchJsonProperty -Object $Entry -Name 'propagation_flags')
    $identityResolution = [string](Get-DispatchJsonProperty -Object $Entry -Name 'identity_resolution')
    if ([string]::IsNullOrWhiteSpace($identityResolution)) {
        $identityResolution = Get-AclIdentityResolution -Identity $identity
    }
    $canonicalParts = New-Object System.Collections.Generic.List[string]
    foreach ($flag in @($inheritance)) {
        switch ($flag) {
            'ObjectInherit' { $canonicalParts.Add('(OI)') }
            'ContainerInherit' { $canonicalParts.Add('(CI)') }
            'InheritOnly' { $canonicalParts.Add('(IO)') }
            'NoPropagateInherit' { $canonicalParts.Add('(NP)') }
            default { $canonicalParts.Add('(' + $flag + ')') }
        }
    }
    foreach ($flag in @($propagation)) {
        if ($flag -notin @('None', '')) {
            switch ($flag) {
                'InheritOnly' { $canonicalParts.Add('(IO)') }
                'NoPropagateInherit' { $canonicalParts.Add('(NP)') }
                default { $canonicalParts.Add('(' + $flag + ')') }
            }
        }
    }
    $canonicalParts.Add('(' + (ConvertTo-CanonicalAclRights -Value $rights) + ')')
    $canonical = ($canonicalParts -join '')
    return [ordered]@{
        identity = $identity
        identity_resolution = $identityResolution
        access_control_type = $accessType
        rights = $rights
        inheritance_flags = $inheritance
        propagation_flags = $propagation
        is_inherited = [bool](Get-DispatchJsonProperty -Object $Entry -Name 'is_inherited')
        canonical = $canonical
    }
}

function Get-AclEntryFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Entry
    )

    $existing = [string](Get-DispatchJsonProperty -Object $Entry -Name 'fingerprint')
    if ($existing -match '^[a-fA-F0-9]{64}$') {
        return $existing.ToLowerInvariant()
    }
    $canonicalEntry = Get-CanonicalAclEntry -Entry $Entry
    return Get-JsonSha256 -Value $canonicalEntry
}

function New-SandboxAclEvidenceDocument {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Entries = @(),

        [Parameter(Mandatory)]
        [ValidateSet('pending', 'captured', 'no_match', 'unknown', 'failed', 'rejected')]
        [string]$CaptureStatus,

        [bool]$NormalCompletion = $false,

        [bool]$ContinuationAllowed = $false,

        [AllowEmptyString()]
        [string]$CapturedAtUtc,

        [AllowEmptyString()]
        [string]$Error
    )

    $entryValues = @($Entries | Where-Object { $null -ne $_ })
    if ($CaptureStatus -eq 'pending' -and $entryValues.Count -gt 0) {
        throw 'SandboxAclEvidencePendingCannotContainEntries：pending evidence 不得包含 gate accepted entry。'
    }
    $terminalStatus = $CaptureStatus -in @('captured', 'no_match', 'unknown', 'failed', 'rejected')
    $capturedAtValue = if (-not $terminalStatus) {
        $null
    }
    elseif ([string]::IsNullOrWhiteSpace($CapturedAtUtc)) {
        [DateTime]::UtcNow.ToString('o')
    }
    else {
        $CapturedAtUtc
    }
    $evidenceFingerprint = if ($entryValues.Count -eq 0) { $null } else { Get-JsonSha256 -Value @($entryValues) }
    return [ordered]@{
        capture_status = $CaptureStatus
        entries = @($entryValues)
        captured_at_utc = $capturedAtValue
        fingerprint = $evidenceFingerprint
        error = if ([string]::IsNullOrWhiteSpace($Error)) { $null } else { $Error }
        normal_completion = $NormalCompletion
        continuation_allowed = $ContinuationAllowed -and $CaptureStatus -eq 'captured'
    }
}

function Get-ExplicitAclSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolvedPath = Resolve-AbsolutePath -Path $Path
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
        return [ordered]@{
            status = 'unknown'
            path = $resolvedPath
            fingerprint = $null
            entries = @()
            explicit_entries = @()
            captured_at_utc = [datetime]::UtcNow.ToString('o')
            error = 'ACL 目標目錄不存在。'
        }
    }
    try {
        $acl = Get-Acl -LiteralPath $resolvedPath -ErrorAction Stop
        $entries = @(
            $acl.Access |
                Where-Object { -not $_.IsInherited } |
                ForEach-Object {
                    $rawEntry = [ordered]@{
                        identity = [string]$_.IdentityReference.Value
                        access_control_type = [string]$_.AccessControlType
                        rights = [string]$_.FileSystemRights
                        inheritance_flags = [string]$_.InheritanceFlags
                        propagation_flags = [string]$_.PropagationFlags
                        is_inherited = [bool]$_.IsInherited
                    }
                    $canonicalEntry = Get-CanonicalAclEntry -Entry $rawEntry
                    $rawEntry.identity_resolution = $canonicalEntry.identity_resolution
                    $rawEntry.canonical = $canonicalEntry.canonical
                    $rawEntry.fingerprint = Get-JsonSha256 -Value ([ordered]@{
                            identity = $canonicalEntry.identity
                            identity_resolution = $canonicalEntry.identity_resolution
                            access_control_type = $canonicalEntry.access_control_type
                            rights = $canonicalEntry.rights
                            inheritance_flags = @($canonicalEntry.inheritance_flags)
                            propagation_flags = @($canonicalEntry.propagation_flags)
                            canonical = $canonicalEntry.canonical
                        })
                    $rawEntry
                } |
                Sort-Object -Property @{ Expression = { $_.identity } }, @{ Expression = { $_.access_control_type } }, @{ Expression = { $_.rights } }, @{ Expression = { $_.inheritance_flags } }, @{ Expression = { $_.propagation_flags } }
        )
        return [ordered]@{
            status = 'known'
            path = $resolvedPath
            fingerprint = Get-JsonSha256 -Value @($entries)
            entries = @($entries)
            explicit_entries = @($entries)
            captured_at_utc = [datetime]::UtcNow.ToString('o')
            error = $null
        }
    }
    catch {
        return [ordered]@{
            status = 'failed'
            path = $resolvedPath
            fingerprint = $null
            entries = @()
            explicit_entries = @()
            captured_at_utc = [datetime]::UtcNow.ToString('o')
            error = $_.Exception.Message
        }
    }
}

function Get-SandboxAclSnapshotEntries {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Snapshot
    )

    if ($null -eq $Snapshot) {
        return @()
    }
    $entries = @((Get-DispatchJsonProperty -Object $Snapshot -Name 'entries') | Where-Object { $null -ne $_ })
    if ($entries.Count -eq 0) {
        $entries = @((Get-DispatchJsonProperty -Object $Snapshot -Name 'explicit_entries') | Where-Object { $null -ne $_ })
    }
    return @($entries | Where-Object { $null -ne $_ })
}

function Get-SandboxAclFingerprintArray {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Entries = @()
    )

    return @($Entries | Where-Object { $null -ne $_ } | ForEach-Object { Get-AclEntryFingerprint -Entry $_ } | Sort-Object)
}

function Test-SandboxAclFingerprintSetEqual {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Left = @(),

        [AllowEmptyCollection()]
        [object[]]$Right = @()
    )

    $leftValues = @(Get-SandboxAclFingerprintArray -Entries $Left)
    $rightValues = @(Get-SandboxAclFingerprintArray -Entries $Right)
    if ($leftValues.Count -ne $rightValues.Count) {
        return $false
    }
    for ($index = 0; $index -lt $leftValues.Count; $index++) {
        if (-not [string]::Equals([string]$leftValues[$index], [string]$rightValues[$index], [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    return $true
}

function Get-SandboxAclExtraEntries {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$BaselineEntries = @(),

        [AllowEmptyCollection()]
        [object[]]$SnapshotEntries = @()
    )

    $remaining = @{}
    foreach ($entry in @($BaselineEntries)) {
        $fingerprint = Get-AclEntryFingerprint -Entry $entry
        if ($remaining.ContainsKey($fingerprint)) {
            $remaining[$fingerprint] = [int]$remaining[$fingerprint] + 1
        }
        else {
            $remaining[$fingerprint] = 1
        }
    }
    $extraEntries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in @($SnapshotEntries)) {
        $fingerprint = Get-AclEntryFingerprint -Entry $entry
        if ($remaining.ContainsKey($fingerprint) -and [int]$remaining[$fingerprint] -gt 0) {
            $remaining[$fingerprint] = [int]$remaining[$fingerprint] - 1
        }
        else {
            $extraEntries.Add($entry)
        }
    }
    return @($extraEntries.ToArray())
}

function Get-SandboxAclMissingEntries {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$BaselineEntries = @(),

        [AllowEmptyCollection()]
        [object[]]$SnapshotEntries = @()
    )

    $remaining = @{}
    foreach ($entry in @($SnapshotEntries)) {
        $fingerprint = Get-AclEntryFingerprint -Entry $entry
        if ($remaining.ContainsKey($fingerprint)) {
            $remaining[$fingerprint] = [int]$remaining[$fingerprint] + 1
        }
        else {
            $remaining[$fingerprint] = 1
        }
    }
    $missingEntries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in @($BaselineEntries)) {
        $fingerprint = Get-AclEntryFingerprint -Entry $entry
        if ($remaining.ContainsKey($fingerprint) -and [int]$remaining[$fingerprint] -gt 0) {
            $remaining[$fingerprint] = [int]$remaining[$fingerprint] - 1
        }
        else {
            $missingEntries.Add($entry)
        }
    }
    return @($missingEntries.ToArray())
}

function Get-SandboxAclInspectEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Record,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [bool]$NormalCompletion
    )

    $existingEvidence = Get-DispatchJsonProperty -Object $Record -Name 'sandbox_acl_evidence'
    $existingStatus = if ($null -eq $existingEvidence) { '' } else { [string](Get-DispatchJsonProperty -Object $existingEvidence -Name 'capture_status') }
    if ($existingStatus -in @('captured', 'no_match', 'unknown', 'failed', 'rejected')) {
        return $existingEvidence
    }
    if (-not $NormalCompletion) {
        return New-SandboxAclEvidenceDocument -Entries @() -CaptureStatus 'pending' -NormalCompletion $false -ContinuationAllowed $false
    }

    $postSnapshot = Get-ExplicitAclSnapshot -Path $ExecutionRoot
    $postStatus = [string](Get-DispatchJsonProperty -Object $postSnapshot -Name 'status')
    if ($postStatus -eq 'unknown') {
        return New-SandboxAclEvidenceDocument -Entries @() -CaptureStatus 'unknown' -NormalCompletion $true -ContinuationAllowed $false -Error ([string](Get-DispatchJsonProperty -Object $postSnapshot -Name 'error'))
    }
    if ($postStatus -eq 'failed') {
        return New-SandboxAclEvidenceDocument -Entries @() -CaptureStatus 'failed' -NormalCompletion $true -ContinuationAllowed $false -Error ([string](Get-DispatchJsonProperty -Object $postSnapshot -Name 'error'))
    }
    if ($postStatus -ne 'known') {
        return New-SandboxAclEvidenceDocument -Entries @() -CaptureStatus 'failed' -NormalCompletion $true -ContinuationAllowed $false -Error 'ACL post-completion snapshot 狀態無法驗證。'
    }

    $postEntries = @(Get-SandboxAclSnapshotEntries -Snapshot $postSnapshot)
    $baseline = Get-DispatchJsonProperty -Object $Record -Name 'sandbox_acl_baseline'
    $baselineStatus = if ($null -eq $baseline) { '' } else { [string](Get-DispatchJsonProperty -Object $baseline -Name 'status') }
    if ($null -eq $baseline -or $baselineStatus -ne 'known') {
        return New-SandboxAclEvidenceDocument -Entries @($postEntries) -CaptureStatus 'rejected' -NormalCompletion $true -ContinuationAllowed $false -Error 'RunRecord 缺少可驗證的 sandbox ACL baseline。'
    }

    $previousRunId = [string](Get-DispatchJsonProperty -Object $Record -Name 'previous_run_id')
    if ([string]::IsNullOrWhiteSpace($previousRunId)) {
        $previousRunId = [string](Get-DispatchJsonProperty -Object $Record -Name 'resume_anchor_run_id')
    }
    if (-not [string]::IsNullOrWhiteSpace($previousRunId)) {
        try {
            $runDirectory = Get-DispatchRunDirectory -SourceRoot ([string](Get-DispatchJsonProperty -Object $Record -Name 'source_root')) -LineSlug ([string](Get-DispatchJsonProperty -Object $Record -Name 'line_slug')) -DispatchSlug ([string](Get-DispatchJsonProperty -Object $Record -Name 'dispatch_slug'))
            $previousPath = Join-Path $runDirectory ($previousRunId + '.json')
            $previousRecord = Read-DispatchRunRecord -Path $previousPath -SourceRoot ([string](Get-DispatchJsonProperty -Object $Record -Name 'source_root')) -ExecutionRoot $ExecutionRoot -LineSlug ([string](Get-DispatchJsonProperty -Object $Record -Name 'line_slug')) -DispatchSlug ([string](Get-DispatchJsonProperty -Object $Record -Name 'dispatch_slug'))
            $previousEvidence = Get-DispatchJsonProperty -Object $previousRecord -Name 'sandbox_acl_evidence'
            $previousStatus = if ($null -eq $previousEvidence) { '' } else { [string](Get-DispatchJsonProperty -Object $previousEvidence -Name 'capture_status') }
            $previousEntries = if ($null -eq $previousEvidence) { @() } else { @((Get-DispatchJsonProperty -Object $previousEvidence -Name 'entries')) }
            if ($previousStatus -eq 'captured' -and (Test-SandboxAclFingerprintSetEqual -Left $postEntries -Right $previousEntries)) {
                return New-SandboxAclEvidenceDocument -Entries @($postEntries) -CaptureStatus 'captured' -NormalCompletion $true -ContinuationAllowed $true
            }
            return New-SandboxAclEvidenceDocument -Entries @($postEntries) -CaptureStatus 'rejected' -NormalCompletion $true -ContinuationAllowed $false -Error '續行 post-completion ACL 與前輪 captured fingerprint 集合不一致。'
        }
        catch {
            return New-SandboxAclEvidenceDocument -Entries @($postEntries) -CaptureStatus 'rejected' -NormalCompletion $true -ContinuationAllowed $false -Error ('續行 ACL evidence 無法讀取前輪 captured record：' + $_.Exception.Message)
        }
    }

    $baselineEntries = @(Get-SandboxAclSnapshotEntries -Snapshot $baseline)
    $missingBaselineEntries = @(Get-SandboxAclMissingEntries -BaselineEntries $baselineEntries -SnapshotEntries $postEntries)
    if ($missingBaselineEntries.Count -gt 0) {
        return New-SandboxAclEvidenceDocument -Entries @($postEntries) -CaptureStatus 'rejected' -NormalCompletion $true -ContinuationAllowed $false -Error 'post-completion ACL 缺少 baseline entry，存在未預期的消失差異。'
    }
    if (Test-SandboxAclFingerprintSetEqual -Left $postEntries -Right $baselineEntries) {
        return New-SandboxAclEvidenceDocument -Entries @($postEntries) -CaptureStatus 'no_match' -NormalCompletion $true -ContinuationAllowed $false -Error $null
    }
    $extraEntries = @(Get-SandboxAclExtraEntries -BaselineEntries $baselineEntries -SnapshotEntries $postEntries)
    if ($extraEntries.Count -eq 1) {
        $candidate = $extraEntries[0]
        $candidateCanonical = [string](Get-DispatchJsonProperty -Object $candidate -Name 'canonical')
        $candidateResolution = [string](Get-DispatchJsonProperty -Object $candidate -Name 'identity_resolution')
        if ($candidateResolution -eq 'unresolved' -and $candidateCanonical -ceq '(OI)(CI)(M)') {
            return New-SandboxAclEvidenceDocument -Entries @($postEntries) -CaptureStatus 'captured' -NormalCompletion $true -ContinuationAllowed $true
        }
    }
    return New-SandboxAclEvidenceDocument -Entries @($postEntries) -CaptureStatus 'rejected' -NormalCompletion $true -ContinuationAllowed $false -Error 'post-completion ACL 與 baseline 差異未符合單筆 unresolved (OI)(CI)(M) 契約。'
}

function Get-WorktreeAclGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$WriteMode,

        [AllowNull()]
        [psobject]$ContinuationRecord
    )

    $sourcePath = Resolve-AbsolutePath -Path $SourceRoot
    $executionPath = Resolve-AbsolutePath -Path $ExecutionRoot
    if ([string]::Equals($sourcePath, $executionPath, [StringComparison]::OrdinalIgnoreCase)) {
        return [ordered]@{
            status = 'not-applicable'
            rejection_code = $null
            source = [ordered]@{ status = 'not-applicable'; path = $sourcePath; fingerprint = $null; explicit_entries = @() }
            dispatch = [ordered]@{ status = 'not-applicable'; path = $executionPath; fingerprint = $null; explicit_entries = @() }
            residue = @()
            raw_residue = @()
            accepted_sandbox_entries = @()
            allowed_sandbox_entries = @()
            sandbox_evidence_status = 'not-applicable'
            sandbox_acl_baseline = $null
            sandbox_acl_evidence = $null
            write_mode = $WriteMode
        }
    }

    $sourceAcl = Get-ExplicitAclSnapshot -Path $sourcePath
    $dispatchAcl = Get-ExplicitAclSnapshot -Path $executionPath
    if ($sourceAcl.status -eq 'unknown' -or $dispatchAcl.status -eq 'unknown') {
        return [ordered]@{
            status = 'unknown'
            rejection_code = 'WorktreeAclUnknown'
            source = $sourceAcl
            dispatch = $dispatchAcl
            residue = @()
            raw_residue = @()
            accepted_sandbox_entries = @()
            allowed_sandbox_entries = @()
            sandbox_evidence_status = 'unknown'
            sandbox_acl_baseline = if ($null -eq $ContinuationRecord) { $null } else { Get-DispatchJsonProperty -Object $ContinuationRecord -Name 'sandbox_acl_baseline' }
            sandbox_acl_evidence = if ($null -eq $ContinuationRecord) { $null } else { Get-DispatchJsonProperty -Object $ContinuationRecord -Name 'sandbox_acl_evidence' }
            write_mode = $WriteMode
        }
    }
    if ($sourceAcl.status -eq 'failed' -or $dispatchAcl.status -eq 'failed') {
        return [ordered]@{
            status = 'failed'
            rejection_code = 'WorktreeAclReadFailed'
            source = $sourceAcl
            dispatch = $dispatchAcl
            residue = @()
            raw_residue = @()
            accepted_sandbox_entries = @()
            allowed_sandbox_entries = @()
            sandbox_evidence_status = 'failed'
            sandbox_acl_baseline = if ($null -eq $ContinuationRecord) { $null } else { Get-DispatchJsonProperty -Object $ContinuationRecord -Name 'sandbox_acl_baseline' }
            sandbox_acl_evidence = if ($null -eq $ContinuationRecord) { $null } else { Get-DispatchJsonProperty -Object $ContinuationRecord -Name 'sandbox_acl_evidence' }
            write_mode = $WriteMode
        }
    }

    $sourceKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($sourceAcl.explicit_entries)) {
        $null = $sourceKeys.Add((Get-AclEntryFingerprint -Entry $entry))
    }
    $residue = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in @($dispatchAcl.explicit_entries)) {
        if (-not $sourceKeys.Contains((Get-AclEntryFingerprint -Entry $entry))) {
            $residue.Add($entry)
        }
    }
    $rawResidue = @($residue.ToArray())
    $allowedSandboxEntries = New-Object System.Collections.Generic.List[object]
    $acceptedSandboxEntries = New-Object System.Collections.Generic.List[object]
    $allowedFingerprints = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $evidence = $null
    if ($null -ne $ContinuationRecord) {
        $evidence = Get-DispatchJsonProperty -Object $ContinuationRecord -Name 'sandbox_acl_evidence'
    }
    $evidenceCaptureStatus = if ($null -eq $evidence) { '' } else { [string](Get-DispatchJsonProperty -Object $evidence -Name 'capture_status') }
    $hasUsableEvidence = $null -ne $evidence -and
        $evidenceCaptureStatus -ceq 'captured' -and
        [bool](Get-DispatchJsonProperty -Object $evidence -Name 'normal_completion') -and
        [bool](Get-DispatchJsonProperty -Object $evidence -Name 'continuation_allowed')
    if ($null -ne $ContinuationRecord -and $evidenceCaptureStatus -eq 'rejected' -and $rawResidue.Count -gt 0) {
        return [ordered]@{
            status = 'residue'
            rejection_code = 'WorktreeAclResidue'
            source = $sourceAcl
            dispatch = $dispatchAcl
            residue = @($rawResidue)
            raw_residue = @($rawResidue)
            accepted_sandbox_entries = @()
            allowed_sandbox_entries = @()
            sandbox_evidence_status = 'rejected'
            sandbox_acl_baseline = Get-DispatchJsonProperty -Object $ContinuationRecord -Name 'sandbox_acl_baseline'
            sandbox_acl_evidence = $evidence
            write_mode = $WriteMode
        }
    }
    if ($null -ne $ContinuationRecord -and -not $hasUsableEvidence) {
        return [ordered]@{
            status = 'continuation-denied'
            rejection_code = 'WorktreeAclContinuationDenied'
            source = $sourceAcl
            dispatch = $dispatchAcl
            residue = @($rawResidue)
            raw_residue = @($rawResidue)
            accepted_sandbox_entries = @()
            allowed_sandbox_entries = @()
            sandbox_evidence_status = if ([string]::IsNullOrWhiteSpace($evidenceCaptureStatus)) { 'none' } else { $evidenceCaptureStatus }
            sandbox_acl_baseline = Get-DispatchJsonProperty -Object $ContinuationRecord -Name 'sandbox_acl_baseline'
            sandbox_acl_evidence = $evidence
            write_mode = $WriteMode
        }
    }
    if ($hasUsableEvidence) {
        $allowedEntriesForComparison = @((Get-DispatchJsonProperty -Object $evidence -Name 'entries'))
        $dispatchEntriesForComparison = @(Get-SandboxAclSnapshotEntries -Snapshot $dispatchAcl)
        $extraWhitelistEntries = @(Get-SandboxAclExtraEntries -BaselineEntries $allowedEntriesForComparison -SnapshotEntries $dispatchEntriesForComparison)
        $missingWhitelistEntries = @(Get-SandboxAclMissingEntries -BaselineEntries $allowedEntriesForComparison -SnapshotEntries $dispatchEntriesForComparison)
        if ($extraWhitelistEntries.Count -gt 0 -or $missingWhitelistEntries.Count -gt 0) {
            return [ordered]@{
                status = 'residue'
                rejection_code = 'WorktreeAclResidue'
                source = $sourceAcl
                dispatch = $dispatchAcl
                residue = @($rawResidue)
                raw_residue = @($rawResidue)
                accepted_sandbox_entries = @()
                allowed_sandbox_entries = @($allowedEntriesForComparison)
                sandbox_evidence_status = 'rejected'
                sandbox_acl_baseline = Get-DispatchJsonProperty -Object $ContinuationRecord -Name 'sandbox_acl_baseline'
                sandbox_acl_evidence = $evidence
                write_mode = $WriteMode
            }
        }
    }
    if ($hasUsableEvidence) {
        foreach ($entry in @((Get-DispatchJsonProperty -Object $evidence -Name 'entries'))) {
            if ($null -eq $entry) {
                continue
            }
            $allowedSandboxEntries.Add($entry)
            $null = $allowedFingerprints.Add((Get-AclEntryFingerprint -Entry $entry))
        }
        foreach ($entry in $rawResidue) {
            if ($allowedFingerprints.Contains((Get-AclEntryFingerprint -Entry $entry))) {
                $acceptedSandboxEntries.Add($entry)
            }
        }
    }
    elseif ($null -eq $ContinuationRecord -and $rawResidue.Count -eq 1) {
        $candidate = $rawResidue[0]
        $canonical = [string](Get-DispatchJsonProperty -Object $candidate -Name 'canonical')
        $identityResolution = [string](Get-DispatchJsonProperty -Object $candidate -Name 'identity_resolution')
        if ($identityResolution -eq 'unresolved' -and $canonical -ceq '(OI)(CI)(M)') {
            $acceptedSandboxEntries.Add($candidate)
            $allowedSandboxEntries.Add($candidate)
        }
    }
    $acceptedFingerprintSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($acceptedEntry in @($acceptedSandboxEntries.ToArray())) {
        $null = $acceptedFingerprintSet.Add((Get-AclEntryFingerprint -Entry $acceptedEntry))
    }
    $unauthorizedResidue = @($rawResidue | Where-Object {
            -not $acceptedFingerprintSet.Contains((Get-AclEntryFingerprint -Entry $_))
        })
    $evidenceStatus = if ($hasUsableEvidence) { 'continuation-allowed' } elseif ($acceptedSandboxEntries.Count -gt 0) { 'pending' } elseif ($rawResidue.Count -eq 0) { 'none' } else { 'rejected' }
    $status = if ($unauthorizedResidue.Count -eq 0) { 'clean' } else { 'residue' }
    return [ordered]@{
        status = $status
        rejection_code = if ($status -eq 'residue') { 'WorktreeAclResidue' } else { $null }
        source = $sourceAcl
        dispatch = $dispatchAcl
        residue = @($unauthorizedResidue)
        raw_residue = @($rawResidue)
        accepted_sandbox_entries = @($acceptedSandboxEntries.ToArray())
        allowed_sandbox_entries = @($allowedSandboxEntries.ToArray())
        sandbox_evidence_status = $evidenceStatus
        sandbox_acl_baseline = if ($null -eq $ContinuationRecord) { $null } else { Get-DispatchJsonProperty -Object $ContinuationRecord -Name 'sandbox_acl_baseline' }
        sandbox_acl_evidence = $evidence
        write_mode = $WriteMode
    }
}


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
    New-Item -ItemType Directory -Path (Split-Path -Parent $lockPath) -Force | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        try {
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

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [string[]]$TargetPath = @(),

        [string]$HashProperty = 'result_sha256',

        [AllowEmptyString()]
        [string]$ExpectedExistingSha256,

        [switch]$RequireAbsent,

        [string]$AbsentErrorCode = 'DispatchResultBindingConflict'
    )

    $resolvedPath = Resolve-DispatchOutputPath -CandidatePath $Path -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath @($TargetPath)
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
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
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
        Write-Utf8NoBom -Path $temporaryPath -Content ((ConvertTo-Json -InputObject $Document -Depth 40) + "`n")
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
            [System.IO.File]::Replace((ConvertTo-FileSystemApiPath -Path $temporaryPath), $resolvedFileApiPath, [System.Management.Automation.Language.NullString]::Value)
        }
        elseif ([System.IO.Directory]::Exists($resolvedFileApiPath)) {
            throw "Dispatch result 目的路徑不是檔案：$resolvedPath"
        }
        else {
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

        [ValidateSet('validation', 'preflight', 'before-snapshot', 'prepare', 'start')]
        [string]$FailedStage = 'preflight',

        [bool]$ProcessStarted = $false,

        [string[]]$TargetPath = @()
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
        $dispatchStageBinding = Get-DispatchScriptVariableValue -Name 'DispatchStageBinding'
        if ($null -ne $dispatchStageBinding) {
            $null = Assert-DispatchStageBinding -Binding $dispatchStageBinding -Stage 'prepare' -SourceRoot $rootInfo.SourceRoot -ExecutionRoot $rootInfo.ExecutionRoot -DispatchRoot $rootInfo.DispatchRoot -LineSlug $rootInfo.LineSlug -DispatchSlug $rootInfo.DispatchSlug -TargetPath @($guardTargetPathValue) -ResultPath $ResultPath -PreflightResultPath $PreflightResultPath -PrepareResultPath $PrepareResultPath -QuotaBeforePath $QuotaBeforePath -QuotaAfterPath $QuotaAfterPath
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
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
            $temporaryPath = Join-Path -Path $destinationParent -ChildPath ([guid]::NewGuid().ToString('D') + '.prepare.tmp')
            $temporaryPaths.Add($temporaryPath)
            $temporaryByDestination[$destinationPath] = $temporaryPath
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
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
        foreach ($committedPath in @($committedPaths.ToArray())) {
            if (Test-Path -LiteralPath $committedPath) {
                Remove-Item -LiteralPath $committedPath -Force -ErrorAction SilentlyContinue
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
                }
            }
            else {
                $resultDocument = $failureDocument
            }
        }
        if ($null -ne $resultDocument) {
            $failureResult = New-PrepareOperationResult -Document $resultDocument -ResultPathValue $resultPathValue -ResultSha256Value ([string]$resultSha256Value) -ErrorCode $failureCode -ErrorMessage $originalMessage
            $operationException = New-Object System.InvalidOperationException($originalMessage)
            $operationException.Data['operationResult'] = $failureResult
            throw $operationException
        }
        throw
    }
}

function Invoke-Preflight {
    if ([string]::IsNullOrWhiteSpace($SourceRoot) -or [string]::IsNullOrWhiteSpace($DispatchRoot) -or [string]::IsNullOrWhiteSpace($LineSlug) -or [string]::IsNullOrWhiteSpace($DispatchSlug)) {
        throw 'Preflight 必須提供 SourceRoot、DispatchRoot、LineSlug 與 DispatchSlug。'
    }
    if ($null -eq $TargetPath -or $TargetPath.Count -eq 0) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestMissingField' -Message 'Preflight 的 target_path 至少需要一項。' -Field 'target_path' -Detail ([ordered]@{ count = 0 })
    }
    for ($targetIndex = 0; $targetIndex -lt $TargetPath.Count; $targetIndex++) {
        $targetPathValue = [string]$TargetPath[$targetIndex]
        if ([string]::IsNullOrWhiteSpace($targetPathValue)) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message ("Preflight 的 target_path 第 {0} 項不可為空白。" -f $targetIndex) -Field 'target_path' -Detail ([ordered]@{ index = $targetIndex })
        }
        if (-not (Test-DispatchFullyQualifiedPath -Path $targetPathValue)) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidPath' -Message ("Preflight 的 target_path 第 {0} 項必須是完整絕對路徑。" -f $targetIndex) -Field 'target_path' -Detail ([ordered]@{ index = $targetIndex; expected = 'fully-qualified path'; received = $targetPathValue })
        }
    }

    $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
    $dispatchRootPath = Resolve-AbsolutePath -Path $DispatchRoot
    if (-not (Test-Path -LiteralPath $sourceRootPath -PathType Container)) {
        throw "sourceRoot 不存在或不是目錄：$sourceRootPath"
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
    if ($pidCheck.Blocked) {
        throw "PID 並行檢查拒絕派遣：$($pidCheck.Reason)"
    }

    $gitProbeState = $null
    $targetStates = @()
    $worktreeCreated = $WriteMode -eq 'readonly'
    if ($WriteMode -eq 'write') {
        $gitProbeState = Get-ExistingGitRepositoryState -SourceRoot $sourceRootPath
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

    $executionRootPath = $sourceRootPath
    $carryInManifest = [ordered]@{
        TrackedPatchApplied = $false
        TrackedPatchLength  = 0
        UntrackedFiles      = @()
        CopiedFiles         = @()
    }

    $gitState = $null
    $baseShaValue = ''
    $baseline = $null
    if ($worktreeCreated) {
        if ($null -ne $gitProbeState -and $gitProbeState.IsRepository) {
            $gitState = [ordered]@{
                GitOrigin  = 'existing'
                MarkerPath = ''
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
        New-Item -ItemType Directory -Path $dispatchParent -Force | Out-Null
        $worktreeResult = Invoke-GitCommand -WorkingDirectory $sourceRootPath -Arguments @('worktree', 'add', '--detach', $dispatchRootPath, $baseShaValue) -AllowFailure
        if ($worktreeResult.ExitCode -ne 0) {
            throw "建立 dispatch worktree 失敗：$($worktreeResult.StdErr.Trim())"
        }
        $executionRootPath = $dispatchRootPath
        $carryInManifest = Apply-SourceCarryIn -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath
        $baseline = New-DispatchBaseline -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -BaseSha $baseShaValue
    }
    elseif ($WriteMode -eq 'write' -and $null -ne $gitProbeState -and $gitProbeState.IsRepository) {
        $gitState = [ordered]@{
            GitOrigin  = 'existing'
            MarkerPath = ''
        }
    }
    else {
        $gitState = [ordered]@{
            GitOrigin  = 'not-applicable'
            MarkerPath = ''
        }
    }

    $executionHandoffRoot = Join-Path -Path $executionRootPath -ChildPath '.local\ai-sessions\handoff'
    $executionReportRoot = Join-Path -Path $executionRootPath -ChildPath '.local\ai-sessions\report'
    $executionHistoryRoot = Join-Path -Path $executionRootPath -ChildPath '.local\ai-sessions\history'
    $executionScratchRoot = Join-Path -Path $executionRootPath -ChildPath '.local\ai-sessions\scratch'
    $dispatchLineRoot = Join-Path -Path $executionHandoffRoot -ChildPath $LineSlug
    $reportLineRoot = Join-Path -Path $executionReportRoot -ChildPath $LineSlug
    New-Item -ItemType Directory -Path $executionHandoffRoot, $executionReportRoot, $executionHistoryRoot, $executionScratchRoot, $dispatchLineRoot, $reportLineRoot -Force | Out-Null

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
        markerPath      = $gitState.MarkerPath
        baseSha         = $baseShaValue
        worktreeCreated = $worktreeCreated
        carryInManifest = $carryInManifest
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
        $script:DispatchRoot = $dispatchRootPath
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
        $quotaBeforePathValue = Get-OrCreateQuotaSnapshot -Path $requestedQuotaBeforePath -SnapshotPath ([string]$stageBinding.quota_before_path) -CodexHome $CodexHome -HistoryRoot $historyRoot -Purpose 'before' -Required
        $quotaBeforePathValue = Resolve-AbsolutePath -Path $quotaBeforePathValue
        if (-not [string]::Equals($quotaBeforePathValue, [string]$stageBinding.quota_before_path, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'DispatchStageBindingConflict：QuotaBeforePath 未沿用既有 stage binding。'
        }
        $quotaBeforeSha256Value = Get-FileSha256 -Path $quotaBeforePathValue
        $script:DispatchQuotaBeforeSha256 = $quotaBeforeSha256Value
        $script:QuotaBeforePath = $quotaBeforePathValue
        $completedStages.Add('before-snapshot')

        $failedStage = 'prepare'
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
        $writtenResult = Write-DispatchAtomicJsonDocument -Path $resultPathValue -Document $result -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
        $result.result_path = $writtenResult.Path
        $result.result_sha256 = $writtenResult.Hash
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
        $failureResult.failure_receipt_sha256 = $null
        if (-not [string]::IsNullOrWhiteSpace($failureReceiptPathValue)) {
            try {
                $receiptSourceRoot = if ([string]::IsNullOrWhiteSpace($sourceRootPath)) { [string]$SourceRoot } else { $sourceRootPath }
                $receiptExecutionRoot = if ([string]::IsNullOrWhiteSpace($executionRootPath)) { $receiptSourceRoot } else { $executionRootPath }
                $receiptDispatchRoot = if ([string]::IsNullOrWhiteSpace($DispatchRoot)) { $null } else { [string]$DispatchRoot }
                $writtenReceipt = Write-DispatchFailureReceipt -Path $failureReceiptPathValue -LineSlug ([string]$LineSlug) -DispatchSlug ([string]$DispatchSlug) -DispatchExecutionId $dispatchToken -ErrorCode $errorCode -ErrorMessage $failureException.Message -SourceRoot $receiptSourceRoot -ExecutionRoot $receiptExecutionRoot -DispatchRoot $receiptDispatchRoot -FailedStage $failedStage -ProcessStarted $processStarted -TargetPath @($TargetPath)
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

function Get-CodexExecutablePath {
    param(
        [string]$ConfiguredPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) {
            $path = Resolve-AbsolutePath -Path $ConfiguredPath
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Codex 執行檔不存在：$path"
            }
            return $path
        }

        return Get-CommandPath -Name $ConfiguredPath
    }

    if (Test-IsWindowsPlatform) {
        return Get-CommandPath -Name 'codex.cmd'
    }

    return Get-CommandPath -Name 'codex'
}

function Get-PreflightData {
    if (-not [string]::IsNullOrWhiteSpace($PreflightResultPath)) {
        $path = Resolve-AbsolutePath -Path $PreflightResultPath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "找不到 Preflight 輸出：$path"
        }
        try {
            return ConvertFrom-DispatchJson -Content (Get-Content -LiteralPath $path -Raw -Encoding UTF8)
        }
        catch {
            throw "Preflight 輸出格式錯誤：$path；$($_.Exception.Message)"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionRoot)) {
        throw 'Start 必須提供 PreflightResultPath 或 ExecutionRoot。'
    }
    return [pscustomobject]@{
        sourceRoot    = $SourceRoot
        dispatchRoot  = $DispatchRoot
        executionRoot = $ExecutionRoot
        lineSlug      = $LineSlug
        dispatchSlug  = $DispatchSlug
        writeMode     = $WriteMode
    }
}

function ConvertTo-CmdArgument {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    return '"' + $Value.Replace('"', '\"') + '"'
}

function New-CodexLauncher {
    param(
        [Parameter(Mandatory)]
        [string]$CodexExecutable,

        [Parameter(Mandatory)]
        [string[]]$CodexArguments,

        [Parameter(Mandatory)]
        [string]$PromptPath,

        [Parameter(Mandatory)]
        [string]$EventPath,

        [Parameter(Mandatory)]
        [string]$ErrorPath,

        [Parameter(Mandatory)]
        [string]$HistoryRoot,

        [string]$LauncherPath,

        [string]$ExitSidecarPath,

        [string]$LineSlug,

        [string]$DispatchSlug,

        [string]$RunId
    )

    $timestamp = [datetime]::UtcNow.ToString('yyyyMMdd_HHmmss_fff')
    if (Test-IsWindowsPlatform) {
        if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
            $LauncherPath = Join-Path -Path $HistoryRoot -ChildPath ('codex-launch-' + $timestamp + '.cmd')
        }
        $argumentsText = ($CodexArguments | ForEach-Object { ConvertTo-CmdArgument -Value $_ }) -join ' '
        $contentLines = @(
            '@echo off'
            ('call ' + (ConvertTo-CmdArgument -Value $CodexExecutable) + ' ' + $argumentsText + ' < ' + (ConvertTo-CmdArgument -Value $PromptPath) + ' > ' + (ConvertTo-CmdArgument -Value $EventPath) + ' 2> ' + (ConvertTo-CmdArgument -Value $ErrorPath))
        )
        if (-not [string]::IsNullOrWhiteSpace($ExitSidecarPath)) {
            $sidecarLiteral = $ExitSidecarPath.Replace("'", "''")
            $lineSlugLiteral = $LineSlug.Replace("'", "''")
            $dispatchSlugLiteral = $DispatchSlug.Replace("'", "''")
            $runIdLiteral = $RunId.Replace("'", "''")
            $powershellCommand = "`$ErrorActionPreference='Stop';`$p='$sidecarLiteral';`$d=[IO.Path]::GetDirectoryName(`$p);`$t=Join-Path `$d ([guid]::NewGuid().ToString('D')+'.exit.tmp');try{`$o=[ordered]@{schema='ai-sessions.dispatch-exit.v1';line_slug='$lineSlugLiteral';dispatch_slug='$dispatchSlugLiteral';run_id='$runIdLiteral';process_exit_code=[int]`$env:CODEX_DISPATCH_EXIT_CODE;exit_code_status='known'};`$e=New-Object Text.UTF8Encoding(`$false);[IO.File]::WriteAllText(`$t,(`$o|ConvertTo-Json -Compress),`$e);if([IO.File]::Exists(`$p)){[IO.File]::Replace(`$t,`$p,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move(`$t,`$p)}}catch{if([IO.File]::Exists(`$t)){[IO.File]::Delete(`$t)};exit 1}"
            $contentLines += @(
                'set "_codex_exit=%errorlevel%"'
                'set "CODEX_DISPATCH_EXIT_CODE=%_codex_exit%"'
                ('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ' + (ConvertTo-CmdArgument -Value $powershellCommand))
                'set "_sidecar_write_exit=%errorlevel%"'
                'if not "%_sidecar_write_exit%"=="0" exit /b %_codex_exit%'
            )
        }
        $contentLines += 'exit /b %_codex_exit%'
        if ([string]::IsNullOrWhiteSpace($ExitSidecarPath)) {
            $contentLines[$contentLines.Count - 1] = 'exit /b %errorlevel%'
        }
        $content = $contentLines -join "`r`n"
        Write-Utf8NoBom -Path $LauncherPath -Content ($content + "`r`n")
        return [pscustomobject]@{
            Path      = $LauncherPath
            FileName  = Join-Path -Path $env:SystemRoot -ChildPath 'System32\cmd.exe'
            Arguments = @('/d', '/c', 'call', $LauncherPath)
        }
    }

    if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
        $LauncherPath = Join-Path -Path $HistoryRoot -ChildPath ('codex-launch-' + $timestamp + '.sh')
    }
    $argumentsText = ($CodexArguments | ForEach-Object {
            "'" + $_.Replace("'", "'\\''") + "'"
        }) -join ' '
    $codexCommandLine = ("'" + $CodexExecutable.Replace("'", "'\\''") + "'") + ' ' + $argumentsText + ' < ' + ("'" + $PromptPath.Replace("'", "'\\''") + "'") + ' > ' + ("'" + $EventPath.Replace("'", "'\\''") + "'") + ' 2> ' + ("'" + $ErrorPath.Replace("'", "'\\''") + "'")
    $contentLines = @(
        '#!/bin/sh'
        $codexCommandLine
    )
    if (-not [string]::IsNullOrWhiteSpace($ExitSidecarPath)) {
        $sidecarShellPath = "'" + $ExitSidecarPath.Replace("'", "'\\''") + "'"
        $sidecarJsonTemplate = '{"schema":"ai-sessions.dispatch-exit.v1","line_slug":"' + $LineSlug.Replace("'", "'\\''") + '","dispatch_slug":"' + $DispatchSlug.Replace("'", "'\\''") + '","run_id":"' + $RunId.Replace("'", "'\\''") + '","process_exit_code":%s,"exit_code_status":"known"}'
        $contentLines += @(
            '_codex_exit=$?'
            ('_sidecar_path=' + $sidecarShellPath)
            '_sidecar_dir=$(dirname -- "$_sidecar_path")'
            '_sidecar_tmp="$_sidecar_dir/.codex-exit-$$.tmp"'
            ("printf '" + $sidecarJsonTemplate + "\n' " + '"$_codex_exit"' + ' > ' + '"$_sidecar_tmp"')
            '_sidecar_write_exit=$?'
            'if [ "$_sidecar_write_exit" -eq 0 ]; then mv -f -- "$_sidecar_tmp" "$_sidecar_path"; _sidecar_write_exit=$?; fi'
            'if [ "$_sidecar_write_exit" -ne 0 ]; then rm -f -- "$_sidecar_tmp"; fi'
            'exit "$_codex_exit"'
        )
    }
    else {
        $contentLines[1] = 'exec ' + $contentLines[1]
    }
    $content = $contentLines -join "`n"
    Write-Utf8NoBom -Path $LauncherPath -Content ($content + "`n")
    $null = Invoke-ExternalCommand -FileName (Get-CommandPath -Name 'chmod') -WorkingDirectory $HistoryRoot -Arguments @('+x', $LauncherPath)
    return [pscustomobject]@{
        Path      = $LauncherPath
        FileName  = Get-CommandPath -Name 'setsid'
        Arguments = @($LauncherPath)
    }
}

function Get-StartedProcessSnapshot {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessId
    )

    if (-not (Test-IsWindowsPlatform)) {
        $snapshot = Get-UnixProcessSnapshot -ProcessId $ProcessId
        if ($null -eq $snapshot) {
            return $null
        }
        return $snapshot
    }

    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $snapshotResult = Get-WindowsProcessSnapshots -FailOnError
        $snapshots = $snapshotResult.ById
        if ($snapshots.ContainsKey($ProcessId)) {
            $snapshot = $snapshots[$ProcessId]
            if ($snapshot.IdentityStatus -eq 'confirmed' -and $null -ne $snapshot.CreationUtc) {
                $snapshot | Add-Member -MemberType NoteProperty -Name IdentityVerified -Value $true -Force
                return $snapshot
            }
            if ($snapshot.IdentityStatus -ne 'confirmed') {
                $snapshot | Add-Member -MemberType NoteProperty -Name IdentityVerified -Value $false -Force
                return $snapshot
            }
        }
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $process) {
            break
        }
        Start-Sleep -Milliseconds 150
    }

    return $null
}

function Get-ProcessExitCodeIfExited {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process
    )

    try {
        if ($Process.HasExited) {
            return [int]$Process.ExitCode
        }
    }
    catch {
        return $null
    }

    return $null
}


function Ensure-StartEvidenceFiles {
    param(
        [Parameter(Mandatory)]
        [string[]]$Path
    )

    foreach ($evidencePath in $Path) {
        if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
            Write-Utf8NoBom -Path $evidencePath -Content ''
        }
    }
}

function Write-StartPidRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [Parameter(Mandatory)][ValidateSet('readonly', 'write')][string]$WriteMode,
        [AllowNull()][psobject]$Snapshot
    )

    $processName = [string](Get-OptionalObjectProperty -Object $Snapshot -Name 'ProcessName')
    if ([string]::IsNullOrWhiteSpace($processName)) { $processName = 'unknown' }
    $parentProcessId = [string](Get-OptionalObjectProperty -Object $Snapshot -Name 'ParentProcessId')
    if ([string]::IsNullOrWhiteSpace($parentProcessId)) { $parentProcessId = 'unknown' }
    $startedAtUtc = 'unknown'
    $creationUtc = Get-OptionalObjectProperty -Object $Snapshot -Name 'CreationUtc'
    if ($null -ne $creationUtc) {
        try {
            $startedAtUtc = ([datetime]$creationUtc).ToUniversalTime().ToString('o')
        }
        catch {
            $startedAtUtc = 'unknown'
        }
    }
    $identityStatus = [string](Get-OptionalObjectProperty -Object $Snapshot -Name 'IdentityStatus')
    if ([string]::IsNullOrWhiteSpace($identityStatus)) { $identityStatus = 'unknown' }
    $identityVerified = [string](Get-OptionalObjectProperty -Object $Snapshot -Name 'IdentityVerified')
    if (-not [string]::Equals($identityVerified, 'true', [StringComparison]::OrdinalIgnoreCase)) { $identityVerified = 'false' }
    $processGroupId = [string](Get-OptionalObjectProperty -Object $Snapshot -Name 'ProcessGroupId')
    if ([string]::IsNullOrWhiteSpace($processGroupId)) { $processGroupId = 'unknown' }

    $pidContent = @(
        ('pid=' + $ProcessId)
        ('root-pid=' + $ProcessId)
        ('root-process-name=' + $processName)
        ('root-parent-pid=' + $parentProcessId)
        ('root-started-at-utc=' + $startedAtUtc)
        ('identity-status=' + $identityStatus)
        ('identity-verified=' + $identityVerified)
        ('process-tree-scope=' + $(if (Test-IsWindowsPlatform) { 'pid-and-descendants' } else { 'process-group' }))
        ('process-tree-query=' + $(if (Test-IsWindowsPlatform) { 'Win32_Process.ParentProcessId' } else { 'ps PGID 成員' }))
        ('process-group-id=' + $processGroupId)
        ('work-root=' + $SourceRoot)
        ('line-slug=' + $LineSlug)
        ('dispatch-slug=' + $DispatchSlug)
        ('write-mode=' + $WriteMode)
        ('started-at-utc=' + [datetime]::UtcNow.ToString('o'))
    ) -join "`n"
    Write-Utf8NoBom -Path $Path -Content ($pidContent + "`n")
}

function New-ProcessTreeCleanupResult {
    param(
        [Parameter(Mandatory)]
        [string]$CleanupStatus,

        [Parameter(Mandatory)]
        [bool]$TerminationExecuted,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$ErrorMessage
    )

    return [pscustomobject]@{
        CleanupStatus       = $CleanupStatus
        TerminationExecuted = $TerminationExecuted
        ErrorMessage        = $ErrorMessage
    }
}

function Stop-VerifiedProcessTree {
    param(
        [Parameter(Mandatory)]
        [psobject]$Snapshot
    )

    $verifiedProperty = $Snapshot.PSObject.Properties['IdentityVerified']
    if ($null -eq $verifiedProperty -or $verifiedProperty.Value -ne $true) {
        throw '拒絕終止進程。缺少同一次啟動時已通過的身分驗證證據。'
    }

    $terminationExecuted = $false
    if (Test-IsWindowsPlatform) {
        $taskkillPath = Get-CommandPath -Name 'taskkill.exe'
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            $currentResult = Get-WindowsProcessSnapshots -FailOnError
            $unconfirmedProcesses = @($currentResult.UnconfirmedProcesses)
            if ($unconfirmedProcesses.Count -gt 0) {
                $details = @(Format-UnconfirmedProcessDetails -Processes $unconfirmedProcesses)
                return New-ProcessTreeCleanupResult -CleanupStatus 'unverified-processes-remain' -TerminationExecuted $terminationExecuted -ErrorMessage ("未執行進程終止，存在無法確認的存活程序：" + ($details -join ' | '))
            }

            $current = $currentResult.ById
            $rootPresent = $current.ContainsKey($Snapshot.ProcessId)
            if ($rootPresent) {
                $currentRoot = $current[$Snapshot.ProcessId]
                if ($currentRoot.IdentityStatus -ne 'confirmed') {
                    throw "無法確認根程序身分，未完成收尾：root-pid=$($Snapshot.ProcessId); identity-status=$($currentRoot.IdentityStatus); failure-fields=$($currentRoot.IdentityFailureFields -join ','); missing-fields=$($currentRoot.IdentityMissingFields -join ',')"
                }
                if (-not [string]::Equals($currentRoot.ProcessName, $Snapshot.ProcessName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw '拒絕終止 PID。根程序身分與啟動時不一致，視為 PID 重用。'
                }
                if ($null -eq $currentRoot.CreationUtc -or [math]::Abs(($currentRoot.CreationUtc - $Snapshot.CreationUtc).TotalSeconds) -gt 1) {
                    throw '拒絕終止 PID。根程序建立時間與啟動時不一致，視為 PID 重用。'
                }
            }

            $descendantIds = @(Get-DescendantProcessIds -RootProcessId $Snapshot.ProcessId -ProcessesById $current -ConfirmedOnly)
            if (-not $rootPresent -and $descendantIds.Count -eq 0) {
                break
            }

            $targetIds = New-Object System.Collections.Generic.List[int]
            if ($rootPresent) {
                $targetIds.Add($Snapshot.ProcessId)
            }
            foreach ($descendantId in $descendantIds) {
                if (-not $targetIds.Contains($descendantId)) {
                    $targetIds.Add($descendantId)
                }
            }

            foreach ($targetId in $targetIds) {
                $killArguments = New-Object System.Collections.Generic.List[string]
                $killArguments.Add('/PID')
                $killArguments.Add([string]$targetId)
                $killArguments.Add('/T')
                $killArguments.Add('/F')
                $killResult = Invoke-ExternalCommand -FileName $taskkillPath -WorkingDirectory (Get-Location).Path -Arguments @($killArguments.ToArray()) -AllowFailure
                $terminationExecuted = $true
                if ($killResult.ExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($killResult.StdErr)) {
                    [Console]::Error.WriteLine(('taskkill PID {0} 回傳 exit code {1}：{2}' -f $targetId, $killResult.ExitCode, $killResult.StdErr.Trim()))
                }
            }

            Start-Sleep -Milliseconds 150
        }

        $remainingResult = Get-WindowsProcessSnapshots -FailOnError
        $remainingUnconfirmedProcesses = @($remainingResult.UnconfirmedProcesses)
        if ($remainingUnconfirmedProcesses.Count -gt 0) {
            $details = @(Format-UnconfirmedProcessDetails -Processes $remainingUnconfirmedProcesses)
            return New-ProcessTreeCleanupResult -CleanupStatus 'unverified-processes-remain' -TerminationExecuted $terminationExecuted -ErrorMessage ("終止後回查仍有無法確認的存活程序：" + ($details -join ' | '))
        }

        $remaining = $remainingResult.ById
        $remainingDescendants = @(Get-DescendantProcessIds -RootProcessId $Snapshot.ProcessId -ProcessesById $remaining -ConfirmedOnly)
        if ($remaining.ContainsKey($Snapshot.ProcessId) -or $remainingDescendants.Count -gt 0) {
            throw "終止後仍有已確認的同一進程樹程序存活：root-pid=$($Snapshot.ProcessId); descendants=$($remainingDescendants -join ',')"
        }
        if ($terminationExecuted) {
            return New-ProcessTreeCleanupResult -CleanupStatus 'verified-tree-terminated' -TerminationExecuted $true -ErrorMessage $null
        }
        return New-ProcessTreeCleanupResult -CleanupStatus 'already-terminated' -TerminationExecuted $false -ErrorMessage $null
    }

    if ($null -eq $Snapshot.PSObject.Properties['ProcessGroupId'] -or $Snapshot.ProcessGroupId -le 0) {
        throw '拒絕終止 Unix 進程。缺少已驗證的 process-group-id。'
    }

    $killPath = Get-CommandPath -Name 'kill'
    $currentRoot = Get-UnixProcessSnapshot -ProcessId $Snapshot.ProcessId
    if ($null -ne $currentRoot) {
        if (-not (Test-RecordedUnixProcessIdentity -Record ([pscustomobject]@{
                        'root-process-name'   = $Snapshot.ProcessName
                        'root-started-at-utc' = $Snapshot.CreationUtc.ToString('o')
                        'process-group-id'    = [string]$Snapshot.ProcessGroupId
            }) -Snapshot $currentRoot)) {
            throw '拒絕終止 Unix PID。根程序身分或 process group 與啟動時不一致。'
        }
    }
    else {
        $verifiedProperty = $Snapshot.PSObject.Properties['IdentityVerified']
        if ($null -eq $verifiedProperty -or $verifiedProperty.Value -ne $true) {
            throw '拒絕終止 Unix 進程。根程序消失且沒有已通過的身分驗證證據。'
        }
        $existingMembers = @(Get-UnixProcessGroupMemberIds -ProcessGroupId $Snapshot.ProcessGroupId)
        if ($existingMembers.Count -eq 0) {
            return New-ProcessTreeCleanupResult -CleanupStatus 'already-terminated' -TerminationExecuted $false -ErrorMessage $null
        }
    }

    $null = Invoke-ExternalCommand -FileName $killPath -WorkingDirectory (Get-Location).Path -Arguments @('-TERM', '--', '-' + [string]$Snapshot.ProcessGroupId) -AllowFailure
    $terminationExecuted = $true
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $members = @(Get-UnixProcessGroupMemberIds -ProcessGroupId $Snapshot.ProcessGroupId)
        if ($members.Count -eq 0) {
            return New-ProcessTreeCleanupResult -CleanupStatus 'verified-tree-terminated' -TerminationExecuted $true -ErrorMessage $null
        }
        Start-Sleep -Milliseconds 150
    }

    $null = Invoke-ExternalCommand -FileName $killPath -WorkingDirectory (Get-Location).Path -Arguments @('-KILL', '--', '-' + [string]$Snapshot.ProcessGroupId) -AllowFailure
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $members = @(Get-UnixProcessGroupMemberIds -ProcessGroupId $Snapshot.ProcessGroupId)
        if ($members.Count -eq 0) {
            return New-ProcessTreeCleanupResult -CleanupStatus 'verified-tree-terminated' -TerminationExecuted $true -ErrorMessage $null
        }
        Start-Sleep -Milliseconds 150
    }

    $members = @(Get-UnixProcessGroupMemberIds -ProcessGroupId $Snapshot.ProcessGroupId)
    if ($members.Count -gt 0) {
        throw "終止後仍有 Unix process group 成員存活：process-group-id=$($Snapshot.ProcessGroupId); members=$($members -join ',')"
    }
}

function Test-QuotaResetWindowChanged {
    param(
        [Parameter(Mandatory)]
        [psobject]$BeforeSnapshot,

        [Parameter(Mandatory)]
        [psobject]$AfterSnapshot,

        [ValidateSet('primary', 'secondary')]
        [string]$WindowName = 'primary'
    )

    $resetWindowToleranceSeconds = 60
    $beforeWindow = $null
    $afterWindow = $null
    if ($BeforeSnapshot -is [System.Collections.IDictionary]) {
        if ($BeforeSnapshot.Contains($WindowName)) {
            $beforeWindow = $BeforeSnapshot[$WindowName]
        }
    }
    else {
        $beforeWindowProperty = $BeforeSnapshot.PSObject.Properties[$WindowName]
        if ($null -ne $beforeWindowProperty) {
            $beforeWindow = $beforeWindowProperty.Value
        }
    }
    if ($AfterSnapshot -is [System.Collections.IDictionary]) {
        if ($AfterSnapshot.Contains($WindowName)) {
            $afterWindow = $AfterSnapshot[$WindowName]
        }
    }
    else {
        $afterWindowProperty = $AfterSnapshot.PSObject.Properties[$WindowName]
        if ($null -ne $afterWindowProperty) {
            $afterWindow = $afterWindowProperty.Value
        }
    }
    if ($null -eq $beforeWindow -or $null -eq $afterWindow) {
        return $true
    }

    $beforeUsedPercent = $null
    $afterUsedPercent = $null
    $beforeResetsAt = $null
    $afterResetsAt = $null
    if ($beforeWindow -is [System.Collections.IDictionary]) {
        if ($beforeWindow.Contains('used_percent')) {
            $beforeUsedPercent = $beforeWindow['used_percent']
        }
        if ($beforeWindow.Contains('resets_at')) {
            $beforeResetsAt = $beforeWindow['resets_at']
        }
    }
    else {
        $beforeUsedPercentProperty = $beforeWindow.PSObject.Properties['used_percent']
        if ($null -ne $beforeUsedPercentProperty) {
            $beforeUsedPercent = $beforeUsedPercentProperty.Value
        }
        $beforeResetsAtProperty = $beforeWindow.PSObject.Properties['resets_at']
        if ($null -ne $beforeResetsAtProperty) {
            $beforeResetsAt = $beforeResetsAtProperty.Value
        }
    }
    if ($afterWindow -is [System.Collections.IDictionary]) {
        if ($afterWindow.Contains('used_percent')) {
            $afterUsedPercent = $afterWindow['used_percent']
        }
        if ($afterWindow.Contains('resets_at')) {
            $afterResetsAt = $afterWindow['resets_at']
        }
    }
    else {
        $afterUsedPercentProperty = $afterWindow.PSObject.Properties['used_percent']
        if ($null -ne $afterUsedPercentProperty) {
            $afterUsedPercent = $afterUsedPercentProperty.Value
        }
        $afterResetsAtProperty = $afterWindow.PSObject.Properties['resets_at']
        if ($null -ne $afterResetsAtProperty) {
            $afterResetsAt = $afterResetsAtProperty.Value
        }
    }
    if ($null -eq $beforeUsedPercent -or $null -eq $afterUsedPercent -or $null -eq $beforeResetsAt -or $null -eq $afterResetsAt) {
        return $true
    }

    $usedPercentDecreased = [double]$afterUsedPercent -lt [double]$beforeUsedPercent
    $resetWindowChanged = [math]::Abs([double]$afterResetsAt - [double]$beforeResetsAt) -gt $resetWindowToleranceSeconds

    return $usedPercentDecreased -or $resetWindowChanged
}

function Invoke-AdvisorBudgetMonitor {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory)]
        [psobject]$StartedSnapshot,

        [Parameter(Mandatory)]
        [string]$EventPath,

        [Parameter(Mandatory)]
        [string]$MonitorPath,

        [Parameter(Mandatory)]
        [psobject]$BeforeSnapshot,

        [Parameter(Mandatory)]
        [string]$AfterSnapshotPath,

        [Parameter(Mandatory)]
        [string]$AfterSnapshotSha256,

        [string]$CodexHome,

        [Parameter(Mandatory)]
        [double]$PrimaryBudgetPercent,

        [Parameter(Mandatory)]
        [int]$AbortGraceSeconds,

        [ValidateRange(0.1, 3600)]
        [double]$SnapshotRefreshIntervalSeconds = 30
    )

    $monitor = [ordered]@{
        state = 'running'
        stopRequested = $false
        safePointFound = $false
        safePointMissing = $false
        abortReason = $null
        observedPrimaryDeltaPercent = $null
        terminalSnapshotTaken = $false
        afterSnapshotPath = $AfterSnapshotPath
        afterSnapshotSha256 = $AfterSnapshotSha256
        snapshotUpdateCount = 0
    }
    Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
            event = 'monitor.started'
            recorded_at_utc = [datetime]::UtcNow.ToString('o')
            primary_budget_percent = $PrimaryBudgetPercent
            after_snapshot_path = $AfterSnapshotPath
            after_snapshot_sha256 = $AfterSnapshotSha256
            snapshot_refresh_interval_seconds = $SnapshotRefreshIntervalSeconds
        })

    $nextSnapshotRefreshAtUtc = [DateTime]::UtcNow.AddSeconds($SnapshotRefreshIntervalSeconds)
    $consecutiveSnapshotFailures = 0
    while (-not $Process.HasExited) {
        if ([DateTime]::UtcNow -ge $nextSnapshotRefreshAtUtc) {
            $snapshotRefreshSucceeded = $false
            try {
                $afterSnapshotUpdate = Update-AdvisorAfterSnapshotFromCodex -Path $AfterSnapshotPath -ExpectedSha256 ([string]$monitor.afterSnapshotSha256) -CodexHome $CodexHome
                $monitor.afterSnapshotSha256 = [string]$afterSnapshotUpdate.Sha256
                $monitor.snapshotUpdateCount = [int]$monitor.snapshotUpdateCount + 1
                $afterSnapshot = Read-QuotaSnapshot -Path $AfterSnapshotPath
                $delta = Get-QuotaSnapshotDelta -Before $BeforeSnapshot -After $afterSnapshot
                $snapshotRefreshSucceeded = $true
                $consecutiveSnapshotFailures = 0
                $nextSnapshotRefreshAtUtc = [DateTime]::UtcNow.AddSeconds($SnapshotRefreshIntervalSeconds)
                $monitor.observedPrimaryDeltaPercent = $delta
                Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                        event = 'monitor.snapshot-updated'
                        recorded_at_utc = [datetime]::UtcNow.ToString('o')
                        after_snapshot_path = $AfterSnapshotPath
                        after_snapshot_sha256 = $monitor.afterSnapshotSha256
                        snapshot_update_count = $monitor.snapshotUpdateCount
                        observed_primary_delta_percent = $delta
                    })
                if (Test-QuotaResetWindowChanged -BeforeSnapshot $BeforeSnapshot -AfterSnapshot $afterSnapshot) {
                    $monitor.state = 'CrossReset'
                    $monitor.abortReason = 'primary-reset-window-changed'
                    Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                            event = 'monitor.cross-reset'
                            recorded_at_utc = [datetime]::UtcNow.ToString('o')
                            state = $monitor.state
                            before_primary_resets_at = $BeforeSnapshot.primary.resets_at
                            after_primary_resets_at = $afterSnapshot.primary.resets_at
                            observed_primary_delta_percent = $delta
                            after_snapshot_path = $AfterSnapshotPath
                            after_snapshot_sha256 = $monitor.afterSnapshotSha256
                        })
                    return $monitor
                }
                if ($delta -gt $PrimaryBudgetPercent -or [double]$afterSnapshot.primary.remaining_percent -lt ([double]$BeforeSnapshot.primary.remaining_percent - $PrimaryBudgetPercent)) {
                        $monitor.stopRequested = $true
                        $monitor.abortReason = 'primary-budget-percent-exceeded'
                        $monitor.state = 'stop-requested'
                        Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                                event = 'stop-request'
                                recorded_at_utc = [datetime]::UtcNow.ToString('o')
                                observed_primary_delta_percent = $delta
                                primary_budget_percent = $PrimaryBudgetPercent
                                after_snapshot_path = $AfterSnapshotPath
                                after_snapshot_sha256 = $monitor.afterSnapshotSha256
                            })
                        $safePointMessage = ''
                        $safePointDeadline = [DateTime]::UtcNow.AddSeconds($AbortGraceSeconds)
                        do {
                            $safePointMessage = Get-LatestSafePointMessage -EventPath $EventPath -TaskType 'advisor-consult'
                            if (-not [string]::IsNullOrWhiteSpace($safePointMessage)) {
                                $monitor.safePointFound = $true
                                Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                                        event = 'safe-point-found'
                                        recorded_at_utc = [datetime]::UtcNow.ToString('o')
                                        message_length = $safePointMessage.Length
                                    })
                                break
                            }
                            if ($Process.HasExited) {
                                break
                            }
                            Start-Sleep -Milliseconds 100
                        } while ([DateTime]::UtcNow -lt $safePointDeadline)
                        if (-not $monitor.safePointFound) {
                            $monitor.safePointMissing = $true
                            Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                                    event = 'safe-point-missing'
                                    recorded_at_utc = [datetime]::UtcNow.ToString('o')
                                    abort_grace_seconds = $AbortGraceSeconds
                                })
                        }
                        try {
                            $cleanupResult = Stop-VerifiedProcessTree -Snapshot $StartedSnapshot
                            $monitor.state = if ($cleanupResult.CleanupStatus -eq 'verified-tree-terminated' -or $cleanupResult.CleanupStatus -eq 'already-terminated') { 'AbortedByBudget' } else { 'IdentityUnverified' }
                            if ($monitor.state -eq 'IdentityUnverified') {
                            }
                            Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                                    event = 'budget-monitor.completed'
                                    recorded_at_utc = [datetime]::UtcNow.ToString('o')
                                    state = $monitor.state
                                    cleanup_status = $cleanupResult.CleanupStatus
                                    cleanup_error = $cleanupResult.ErrorMessage
                                    safe_point_missing = $monitor.safePointMissing
                                })
                            return $monitor
                        }
                        catch {
                            $monitor.state = 'IdentityUnverified'
                            $monitor.abortReason = $_.Exception.Message
                            Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                                    event = 'monitor.identity-unverified'
                                    recorded_at_utc = [datetime]::UtcNow.ToString('o')
                                    state = $monitor.state
                                    cleanup_status = 'not-terminated'
                                    termination_executed = $false
                                    evidence_preserved = $true
                                    error = $_.Exception.Message
                                    safe_point_missing = $monitor.safePointMissing
                                })
                            return $monitor
                        }
                    }
            }
            catch {
                $failureMessage = $_.Exception.Message
                if ($snapshotRefreshSucceeded) {
                    $monitor.state = 'SnapshotFailed'
                    $monitor.abortReason = $failureMessage
                    Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                            event = 'monitor.snapshot-failed'
                            recorded_at_utc = [datetime]::UtcNow.ToString('o')
                            state = $monitor.state
                            terminal_snapshot = $false
                            snapshot_refresh_succeeded = $true
                            retry_scheduled = $false
                            error = $failureMessage
                            after_snapshot_path = $AfterSnapshotPath
                            after_snapshot_sha256 = $monitor.afterSnapshotSha256
                            snapshot_update_count = $monitor.snapshotUpdateCount
                        })
                    return $monitor
                }
                $consecutiveSnapshotFailures++
                $processExitedAfterFailure = $Process.HasExited
                $stopAfterFailures = $consecutiveSnapshotFailures -ge 3 -and -not $processExitedAfterFailure
                $nextSnapshotRefreshAtUtc = [DateTime]::UtcNow.AddSeconds($SnapshotRefreshIntervalSeconds)
                if ($stopAfterFailures) {
                    $monitor.state = 'SnapshotFailed'
                    $monitor.stopRequested = $true
                    $monitor.abortReason = 'after-snapshot-refresh-failed-three-times'
                }
                Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                        event = 'monitor.snapshot-failed'
                        recorded_at_utc = [datetime]::UtcNow.ToString('o')
                        state = if ($stopAfterFailures) { 'SnapshotFailed' } else { 'retrying' }
                        terminal_snapshot = $false
                        consecutive_failures = $consecutiveSnapshotFailures
                        retry_scheduled = -not $stopAfterFailures -and -not $processExitedAfterFailure
                        stop_requested = $stopAfterFailures
                        error = $failureMessage
                        after_snapshot_path = $AfterSnapshotPath
                        after_snapshot_sha256 = $monitor.afterSnapshotSha256
                        snapshot_update_count = $monitor.snapshotUpdateCount
                    })
                if ($processExitedAfterFailure) {
                    break
                }
                if ($stopAfterFailures) {
                    try {
                        $cleanupResult = Stop-VerifiedProcessTree -Snapshot $StartedSnapshot
                        if ($cleanupResult.CleanupStatus -notin @('verified-tree-terminated', 'already-terminated')) {
                            $monitor.state = 'IdentityUnverified'
                            $monitor.abortReason = [string]$cleanupResult.ErrorMessage
                            Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                                    event = 'monitor.identity-unverified'
                                    recorded_at_utc = [datetime]::UtcNow.ToString('o')
                                    state = $monitor.state
                                    cleanup_status = $cleanupResult.CleanupStatus
                                    termination_executed = [bool]$cleanupResult.TerminationExecuted
                                    evidence_preserved = $true
                                    error = $monitor.abortReason
                                })
                            return $monitor
                        }
                        if (-not $Process.HasExited) {
                            $Process.WaitForExit()
                        }
                        Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                                event = 'budget-monitor.completed'
                                recorded_at_utc = [datetime]::UtcNow.ToString('o')
                                state = $monitor.state
                                termination_reason = 'after-snapshot-refresh-failed-three-times'
                                cleanup_status = $cleanupResult.CleanupStatus
                                cleanup_error = $cleanupResult.ErrorMessage
                                after_snapshot_path = $AfterSnapshotPath
                                after_snapshot_sha256 = $monitor.afterSnapshotSha256
                            })
                        return $monitor
                    }
                    catch {
                        $monitor.state = 'IdentityUnverified'
                        $monitor.abortReason = $_.Exception.Message
                        Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                                event = 'monitor.identity-unverified'
                                recorded_at_utc = [datetime]::UtcNow.ToString('o')
                                state = $monitor.state
                                cleanup_status = 'not-terminated'
                                termination_executed = $false
                                evidence_preserved = $true
                                error = $_.Exception.Message
                            })
                        return $monitor
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 100
    }

    try {
        $terminalSnapshotUpdate = Update-AdvisorAfterSnapshotFromCodex -Path $AfterSnapshotPath -ExpectedSha256 ([string]$monitor.afterSnapshotSha256) -CodexHome $CodexHome
        $monitor.afterSnapshotSha256 = [string]$terminalSnapshotUpdate.Sha256
        $terminalAfterSnapshot = Read-QuotaSnapshot -Path $AfterSnapshotPath
        $terminalDelta = Get-QuotaSnapshotDelta -Before $BeforeSnapshot -After $terminalAfterSnapshot
        $monitor.observedPrimaryDeltaPercent = $terminalDelta
        $monitor.terminalSnapshotTaken = $true
        if (Test-QuotaResetWindowChanged -BeforeSnapshot $BeforeSnapshot -AfterSnapshot $terminalAfterSnapshot) {
            $monitor.state = 'CrossReset'
            $monitor.abortReason = 'primary-reset-window-changed'
            Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                    event = 'monitor.cross-reset'
                    recorded_at_utc = [datetime]::UtcNow.ToString('o')
                    state = $monitor.state
                    terminal_snapshot = $true
                    before_primary_resets_at = $BeforeSnapshot.primary.resets_at
                    after_primary_resets_at = $terminalAfterSnapshot.primary.resets_at
                    observed_primary_delta_percent = $terminalDelta
                    after_snapshot_path = $AfterSnapshotPath
                    after_snapshot_sha256 = $monitor.afterSnapshotSha256
                })
            return $monitor
        }
        $terminalBudgetExceeded = $terminalDelta -gt $PrimaryBudgetPercent -or [double]$terminalAfterSnapshot.primary.remaining_percent -lt ([double]$BeforeSnapshot.primary.remaining_percent - $PrimaryBudgetPercent)
        Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                event = 'monitor.terminal-snapshot'
                recorded_at_utc = [datetime]::UtcNow.ToString('o')
                primary_budget_percent = $PrimaryBudgetPercent
                observed_primary_delta_percent = $terminalDelta
                before_primary_remaining_percent = $BeforeSnapshot.primary.remaining_percent
                after_primary_remaining_percent = $terminalAfterSnapshot.primary.remaining_percent
                over_budget = $terminalBudgetExceeded
                after_snapshot_path = $AfterSnapshotPath
                after_snapshot_sha256 = $monitor.afterSnapshotSha256
            })
        if ($terminalBudgetExceeded) {
            $monitor.stopRequested = $true
            $monitor.state = 'AbortedByBudget'
            $monitor.abortReason = 'primary-budget-percent-exceeded-after-process-exit'
            Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                    event = 'monitor.terminal-budget-exceeded'
                    recorded_at_utc = [datetime]::UtcNow.ToString('o')
                    state = $monitor.state
                    terminal_snapshot = $true
                    observed_primary_delta_percent = $terminalDelta
                    primary_budget_percent = $PrimaryBudgetPercent
                    before_primary_remaining_percent = $BeforeSnapshot.primary.remaining_percent
                    after_primary_remaining_percent = $terminalAfterSnapshot.primary.remaining_percent
                    after_snapshot_path = $AfterSnapshotPath
                    after_snapshot_sha256 = $monitor.afterSnapshotSha256
                })
            Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
            event = 'budget-monitor.completed'
            recorded_at_utc = [datetime]::UtcNow.ToString('o')
            state = $monitor.state
            terminal_snapshot = $true
            abort_reason = $monitor.abortReason
            after_snapshot_path = $AfterSnapshotPath
            after_snapshot_sha256 = $monitor.afterSnapshotSha256
                })
            return $monitor
        }
    }
    catch {
        $monitor.state = 'SnapshotFailed'
        $monitor.abortReason = $_.Exception.Message
        Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                event = 'monitor.snapshot-failed'
                recorded_at_utc = [datetime]::UtcNow.ToString('o')
                state = $monitor.state
                terminal_snapshot = $true
                error = $_.Exception.Message
                after_snapshot_path = $AfterSnapshotPath
                after_snapshot_sha256 = $monitor.afterSnapshotSha256
                snapshot_update_count = $monitor.snapshotUpdateCount
            })
        return $monitor
    }

    $monitor.state = 'completed'
    Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
            event = 'monitor.completed'
            recorded_at_utc = [datetime]::UtcNow.ToString('o')
            state = $monitor.state
            terminal_snapshot = $monitor.terminalSnapshotTaken
            after_snapshot_path = $AfterSnapshotPath
            after_snapshot_sha256 = $monitor.afterSnapshotSha256
        })
    return $monitor
}

function Format-StartEvidencePath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return '<未解析>'
    }

    $exists = $false
    try {
        $exists = Test-Path -LiteralPath $Path
    }
    catch {
        $exists = $false
    }

    return ('{0} (exists={1})' -f $Path, $exists)
}

function New-StartFailureEvidenceMessage {
    param(
        [string]$Phase,
        [string]$EventPath,
        [string]$ErrorPath,
        [string]$LastMessagePath,
        [string]$ThreadPath,
        [string]$PidPath,
        [string]$LauncherPath,
        [Nullable[int]]$ProcessExitCode,
        [string]$CleanupStatus,
        [string]$CleanupError,
        [string]$RelaySource,
        [Nullable[bool]]$RelayTimedOut,
        [Nullable[int]]$RelayTimeoutSeconds
    )

    $processExitText = if ($null -eq $ProcessExitCode) { 'not-started-or-unknown' } else { [string]$ProcessExitCode }
    $cleanupErrorText = if ([string]::IsNullOrWhiteSpace($CleanupError)) { '<none>' } else { $CleanupError }
    $relaySourceText = if ([string]::IsNullOrWhiteSpace($RelaySource)) { '<none>' } else { $RelaySource }
    $relayTimedOutText = if ($null -eq $RelayTimedOut) { '<none>' } else { [string]$RelayTimedOut }
    $relayTimeoutSecondsText = if ($null -eq $RelayTimeoutSeconds) { '<none>' } else { [string]$RelayTimeoutSeconds }
    return ('phase={0}; source={1}; timedOut={2}; timeoutSeconds={3}; eventStreamPath={4}; errorStreamPath={5}; lastMessagePath={6}; threadIdPath={7}; pidRecordPath={8}; launcherPath={9}; processExitCode={10}; cleanupStatus={11}; cleanupError={12}' -f `
        $Phase,
        $relaySourceText,
        $relayTimedOutText,
        $relayTimeoutSecondsText,
        (Format-StartEvidencePath -Path $EventPath),
        (Format-StartEvidencePath -Path $ErrorPath),
        (Format-StartEvidencePath -Path $LastMessagePath),
        (Format-StartEvidencePath -Path $ThreadPath),
        (Format-StartEvidencePath -Path $PidPath),
        (Format-StartEvidencePath -Path $LauncherPath),
        $processExitText,
        $CleanupStatus,
        $cleanupErrorText)
}

function Get-QuotaProbeRolloutFiles {
    param(
        [string]$CodexHomePath
    )

    if ([string]::IsNullOrWhiteSpace($CodexHomePath)) {
        throw 'QuotaProbe 缺少 CodexHome，無法核對 rollout 證據。'
    }

    $sessionsPath = Join-Path -Path $CodexHomePath -ChildPath 'sessions'
    if (-not (Test-Path -LiteralPath $sessionsPath -PathType Container)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $sessionsPath -Recurse -File -Filter 'rollout-*.jsonl' |
            ForEach-Object {
                [pscustomobject]@{
                    Path             = $_.FullName
                    Length           = [int64]$_.Length
                    LastWriteTimeUtc = $_.LastWriteTimeUtc
                }
            }
    )
}

function Resolve-QuotaProbeCodexHome {
    param(
        [string]$ConfiguredCodexHome
    )

    $configuredPath = $ConfiguredCodexHome
    if ([string]::IsNullOrWhiteSpace($configuredPath)) {
        $configuredPath = $env:CODEX_HOME
    }
    if ([string]::IsNullOrWhiteSpace($configuredPath)) {
        $userProfile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
        if ([string]::IsNullOrWhiteSpace($userProfile)) {
            throw '無法判定使用者 Profile 路徑，請提供 CodexHome 或設定 CODEX_HOME。'
        }
        $configuredPath = Join-Path -Path $userProfile -ChildPath '.codex'
    }

    $path = Resolve-AbsolutePath -Path $configuredPath
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "CodexHome 不存在或不是目錄：$path"
    }

    return $path
}

function Invoke-QuotaProbe {
    if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
        throw 'QuotaProbe 必須提供 SourceRoot。'
    }
    if ([string]::IsNullOrWhiteSpace($ExecutionRoot)) {
        throw 'QuotaProbe 必須提供 ExecutionRoot。'
    }
    if ([string]::IsNullOrWhiteSpace($LineSlug)) {
        throw 'QuotaProbe 必須提供 LineSlug。'
    }
    if ([string]::IsNullOrWhiteSpace($DispatchSlug)) {
        throw 'QuotaProbe 必須提供 DispatchSlug。'
    }
    $recoverableQuotaStates = @('PostResetNoSnapshot', 'SnapshotExpired', 'ServiceRejected')

    if ($recoverableQuotaStates -notcontains $InitialQuotaState) {
        throw "QuotaProbe 僅允許回復 $($recoverableQuotaStates -join '、')，收到：$InitialQuotaState"
    }
    if ($ProbeAttempt -gt 1) {
        throw "QuotaProbe 已限制為一次，拒絕 probeAttempt=$ProbeAttempt。"
    }
    if ([string]::IsNullOrWhiteSpace($PromptPath)) {
        throw 'QuotaProbe 必須提供 PromptPath。'
    }

    $requestedProfileValue = [string]$Profile
    $effectiveProfileValue = 'default'

    $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
    $executionRootPath = Resolve-AbsolutePath -Path $ExecutionRoot
    if (-not (Test-Path -LiteralPath $sourceRootPath -PathType Container)) {
        throw "SourceRoot 不存在或不是目錄：$sourceRootPath"
    }
    if (-not (Test-Path -LiteralPath $executionRootPath -PathType Container)) {
        throw "ExecutionRoot 不存在或不是目錄：$executionRootPath"
    }
    if (-not (Test-PathWithinRoot -Path $executionRootPath -Root $sourceRootPath) -and $executionRootPath -ne $sourceRootPath) {
        if ([string]::IsNullOrWhiteSpace($DispatchRoot) -or (Resolve-AbsolutePath -Path $DispatchRoot) -ne $executionRootPath) {
            throw 'QuotaProbe 的 ExecutionRoot 未通過 SourceRoot／DispatchRoot 界線驗證。'
        }
    }

    $promptPathValue = Resolve-AbsolutePath -Path $PromptPath
    if (-not (Test-Path -LiteralPath $promptPathValue -PathType Leaf)) {
        throw "Prompt 檔案不存在：$promptPathValue"
    }

    $historyRoot = Join-Path -Path $executionRootPath -ChildPath ('.local\ai-sessions\history\' + $LineSlug)
    New-Item -ItemType Directory -Path $historyRoot -Force | Out-Null
    $recoveryPath = Join-Path -Path $historyRoot -ChildPath ('quota-recovery-' + $DispatchSlug + '.json')
    if (Test-Path -LiteralPath $recoveryPath -PathType Leaf) {
        throw "QuotaProbe 回復紀錄已存在，拒絕再次執行：$recoveryPath"
    }

    $codexHomePath = Resolve-QuotaProbeCodexHome -ConfiguredCodexHome $CodexHome
    $timestamp = [datetime]::UtcNow.ToString('yyyyMMdd_HHmmss_fff')
    $eventPath = Join-Path -Path $historyRoot -ChildPath ('quota-probe-' + $timestamp + '.jsonl')
    $errorPath = Join-Path -Path $historyRoot -ChildPath ('quota-probe-' + $timestamp + '.stderr.log')
    $lastMessagePath = Join-Path -Path $historyRoot -ChildPath ('quota-probe-last-message-' + $timestamp + '.md')
    $threadPath = Join-Path -Path $historyRoot -ChildPath ('quota-probe-thread-' + $DispatchSlug + '.txt')
    $pidPath = Join-Path -Path $historyRoot -ChildPath ('quota-probe-pid-' + $timestamp + '.txt')
    if (Test-IsWindowsPlatform) {
        $launcherPath = Join-Path -Path $historyRoot -ChildPath ('quota-probe-launch-' + $timestamp + '.cmd')
    }
    else {
        $launcherPath = Join-Path -Path $historyRoot -ChildPath ('quota-probe-launch-' + $timestamp + '.sh')
    }

    if ($InitialQuotaState -eq 'ServiceRejected') {
        $serviceRejection = $null
        $rejectionSnapshot = $null
        if (-not [string]::IsNullOrWhiteSpace($QuotaBeforePath) -and (Test-Path -LiteralPath (Resolve-AbsolutePath -Path $QuotaBeforePath) -PathType Leaf)) {
            try {
                $rejectionSnapshot = Read-QuotaSnapshot -Path $QuotaBeforePath
                $serviceRejection = Get-QuotaSnapshotServiceRejection -Snapshot $rejectionSnapshot
            }
            catch {
            }
        }
        if ($null -eq $serviceRejection) {
            $rejectionPath = if ([string]::IsNullOrWhiteSpace($QuotaBeforePath)) { $null } else { Resolve-AbsolutePath -Path $QuotaBeforePath }
            $rejectionHash = if ($null -eq $rejectionPath -or -not (Test-Path -LiteralPath $rejectionPath -PathType Leaf)) { $null } else { Get-FileSha256 -Path $rejectionPath }
            $rejectionObservedAt = if ($null -eq $rejectionSnapshot) { [DateTimeOffset]::UtcNow.ToString('o') } else { [string](Get-DispatchJsonProperty -Object $rejectionSnapshot -Name 'captured_at_utc') }
            if ([string]::IsNullOrWhiteSpace($rejectionObservedAt)) {
                $rejectionObservedAt = [DateTimeOffset]::UtcNow.ToString('o')
            }
            $rejectionResetAt = $null
            if ($null -ne $rejectionSnapshot) {
                $rejectionResetAt = Get-DispatchJsonProperty -Object (Get-DispatchJsonProperty -Object $rejectionSnapshot -Name 'primary') -Name 'resets_at'
            }
            $serviceRejection = [ordered]@{
                status              = 'quota-rejected'
                window              = 'unknown'
                reason_code         = 'service-rejection'
                observed_at_utc     = $rejectionObservedAt
                raw_evidence_path   = if ($null -eq $rejectionPath) { '<quota-before-not-provided>' } else { $rejectionPath }
                raw_evidence_sha256 = if ($null -eq $rejectionHash) { '<quota-before-hash-not-provided>' } else { $rejectionHash }
                resets_at           = $rejectionResetAt
                retry_allowed       = $false
            }
        }
        $noRetryRecord = [ordered]@{
            schema             = 'quota-recovery.v1'
            operation          = 'QuotaProbe'
            lineSlug           = $LineSlug
            dispatchSlug       = $DispatchSlug
            initialQuotaState  = $InitialQuotaState
            profile             = $effectiveProfileValue
            requested_profile   = $requestedProfileValue
            effective_profile   = $effectiveProfileValue
            triggerWindow      = $TriggerWindow
            probeAttempt       = $ProbeAttempt
            probeAttemptLimit  = 1
            probeEvidence      = [ordered]@{
                eventStreamPath    = $eventPath
                stderrPath         = $errorPath
                lastMessagePath    = $lastMessagePath
                threadIdPath       = $threadPath
                pidRecordPath      = $pidPath
                launcherPath       = $launcherPath
                codexPath          = $null
                processStarted     = $false
                requested_profile  = $requestedProfileValue
                effective_profile  = $effectiveProfileValue
                serviceRejection   = $serviceRejection
            }
            service_rejection   = $serviceRejection
            retryResult         = [ordered]@{
                status        = 'not-allowed-service-rejection'
                attempted     = $false
                retry_allowed = $false
                attemptLimit  = 0
                command       = $null
                result        = '已收到明確 service rejection，等待 reset 或新 quota evidence。'
            }
            finalStatus        = 'service-rejected-no-retry'
            createdAtUtc       = [datetime]::UtcNow.ToString('o')
        }
        Write-Utf8NoBom -Path $recoveryPath -Content (($noRetryRecord | ConvertTo-Json -Depth 12) + "`n")
        return [ordered]@{
            operation          = 'QuotaProbe'
            success            = $false
            lineSlug           = $LineSlug
            dispatchSlug       = $DispatchSlug
            initialQuotaState  = $InitialQuotaState
            profile             = $effectiveProfileValue
            requested_profile   = $requestedProfileValue
            effective_profile   = $effectiveProfileValue
            triggerWindow      = $TriggerWindow
            probeAttempt       = $ProbeAttempt
            probeAttemptLimit  = 1
            processStarted     = $false
            service_rejection  = $serviceRejection
            recoveryRecordPath = $recoveryPath
            retryRequired      = $false
            retryResult        = $noRetryRecord.retryResult
            finalStatus        = $noRetryRecord.finalStatus
        }
    }

    if ($InitialQuotaState -in @('PostResetNoSnapshot', 'SnapshotExpired')) {
        $quotaRefreshPath = New-QuotaSnapshotPath -HistoryRoot $historyRoot -Purpose 'source-refresh' -DispatchSlug $DispatchSlug

        $quotaRefreshPath = Set-QuotaSnapshotFromCodex -Path $quotaRefreshPath -CodexHome $codexHomePath
        $quotaRefreshSnapshot = Read-QuotaSnapshot -Path $quotaRefreshPath
        $quotaRefreshState = [string](Get-DispatchJsonProperty -Object $quotaRefreshSnapshot -Name 'state')
        $quotaRefreshFreshness = Get-QuotaSnapshotFreshness -Snapshot $quotaRefreshSnapshot
        if ($quotaRefreshState -ne 'Valid' -or
            $quotaRefreshFreshness -ne 'fresh' -or
            -not (Test-QuotaSnapshotHasObservations -Snapshot $quotaRefreshSnapshot)) {
            throw ('即時額度來源未產生有效且新鮮的 quota snapshot；QuotaProbe 未啟動。state={0}; freshness={1}' -f
                $quotaRefreshState,
                $quotaRefreshFreshness)
        }

        $quotaRefreshRecord = [ordered]@{
            schema             = 'quota-recovery.v1'
            operation          = 'QuotaProbe'
            lineSlug           = $LineSlug
            dispatchSlug       = $DispatchSlug
            initialQuotaState  = $InitialQuotaState
            profile            = $effectiveProfileValue
            requested_profile  = $requestedProfileValue
            effective_profile  = $effectiveProfileValue
            triggerWindow      = $TriggerWindow
            probeAttempt       = $ProbeAttempt
            probeAttemptLimit  = 1
            probeEvidence      = [ordered]@{
                processStarted        = $false
                quotaSnapshotPath     = $quotaRefreshPath
                quotaSnapshotSha256   = Get-FileSha256 -Path $quotaRefreshPath
                quotaSnapshotState    = $quotaRefreshState
                quotaSnapshotFreshness = $quotaRefreshFreshness
            }
            retryResult        = [ordered]@{
                status        = 'not-required-live-quota-source'
                attempted     = $false
                retry_allowed = $false
                attemptLimit  = 0
                command       = $null
                result        = '即時 quota source 已取得有效快照，不需要啟動 QuotaProbe。'
            }
            finalStatus        = 'quota-source-refreshed-no-probe'
            createdAtUtc       = [datetime]::UtcNow.ToString('o')
        }
        Write-Utf8NoBom -Path $recoveryPath -Content (($quotaRefreshRecord | ConvertTo-Json -Depth 12) + "`n")
        return [ordered]@{
            operation          = 'QuotaProbe'
            success            = $true
            lineSlug           = $LineSlug
            dispatchSlug       = $DispatchSlug
            initialQuotaState  = $InitialQuotaState
            profile            = $effectiveProfileValue
            requested_profile  = $requestedProfileValue
            effective_profile  = $effectiveProfileValue
            triggerWindow      = $TriggerWindow
            probeAttempt       = $ProbeAttempt
            probeAttemptLimit  = 1
            processStarted     = $false
            quotaSnapshotPath  = $quotaRefreshPath
            quotaSnapshotSha256 = $quotaRefreshRecord.probeEvidence.quotaSnapshotSha256
            recoveryRecordPath = $recoveryPath
            retryRequired      = $false
            retryResult        = $quotaRefreshRecord.retryResult
            finalStatus        = $quotaRefreshRecord.finalStatus
        }
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
            'ThreadModelMismatch',
            'ThreadModelUnknown',
            'NoValidResumeAnchor',
            'ProfileEvidenceUnknown',
            'BudgetMonitorStopped',
            'QuotaStop',
            'ThreadRelayTimeout',
            'ProcessIdentityUnknown',
            'CodexLaunchFailed',
            'ParentOptionsMismatch',
            'ParentOptionsUnknown',
            'WorktreeAclResidue',
            'WorktreeAclUnknown',
            'WorktreeAclReadFailed',
            'WorktreeAclContinuationDenied',
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
            'QuotaServiceRejected')) {
        if ($text.Contains($code)) {
            return $code
        }
    }
    if ($text -match 'ScopePlan 阻擋派工') {
        return 'QuotaStop'
    }
    if ($Phase -eq 'thread-relay-not-ready') {
        return 'ThreadRelayTimeout'
    }
    if ($Phase -eq 'identity-unverified') {
        return 'ProcessIdentityUnknown'
    }
    if ($Phase -in @('aborted-by-budget', 'cross-reset')) {
        return 'BudgetMonitorStopped'
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
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
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
    $record = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $pathValue)
    if ($null -eq $record -or $record -isnot [pscustomobject]) { throw 'RunRecord 必須為 JSON object。' }
    foreach ($name in @('previous_run_id', 'requested_thread_id', 'thread_id', 'baseline_path', 'baseline_sha256', 'baseline_resolution', 'attempt_parent_run_id', 'resume_anchor_run_id', 'failure', 'resume_diagnostics', 'model_evidence', 'reasoning_effort_evidence', 'started_at_utc', 'thread_id_path', 'launcher_path', 'process_exit_code_sidecar_path', 'prompt_path', 'prompt_source_path', 'prompt_source_sha256', 'prompt_transfer_path', 'prompt_transfer_sha256', 'inspect_result_path', 'profile_config_path', 'codex_home', 'effective_codex_home', 'evidence_pack_path', 'evidence_pack_sha256', 'evidence_pack_length', 'skipped_attempts', 'parent_options', 'parent_options_sha256', 'parent_options_status', 'scope_plan_parent_path', 'scope_plan_parent_sha256', 'scope_plan_parent_run_id', 'scope_plan_root_run_id', 'scope_plan_selection', 'acl_gate', 'sandbox_acl_baseline', 'sandbox_acl_evidence', 'unknown_interruption', 'prepare_result_path', 'prepare_result_sha256', 'prepare_status', 'quota_before_path', 'quota_before_sha256', 'quota_before_captured_at_utc', 'quota_before_freshness', 'quota_after_path', 'quota_after_sha256', 'request_path', 'request_sha256', 'request_operation')) {
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
    $sandboxBaseline = Get-DispatchJsonProperty -Object $record -Name 'sandbox_acl_baseline'
    if ($null -ne $sandboxBaseline) {
        $baselineStatus = [string](Get-DispatchJsonProperty -Object $sandboxBaseline -Name 'status')
        if ($baselineStatus -notin @('known', 'unknown', 'failed')) {
            throw 'RunRecord sandbox_acl_baseline status 異常。'
        }
        $baselinePath = [string](Get-DispatchJsonProperty -Object $sandboxBaseline -Name 'path')
        if ([string]::IsNullOrWhiteSpace($baselinePath) -or -not [string]::Equals((Resolve-AbsolutePath $baselinePath), (Resolve-AbsolutePath $ExecutionRoot), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'RunRecord sandbox_acl_baseline path 必須指向 executionRoot。'
        }
        $baselineEntries = @((Get-DispatchJsonProperty -Object $sandboxBaseline -Name 'entries') | Where-Object { $null -ne $_ })
        if ($baselineEntries.Count -eq 0) {
            $baselineEntries = @((Get-DispatchJsonProperty -Object $sandboxBaseline -Name 'explicit_entries') | Where-Object { $null -ne $_ })
        }
        foreach ($entry in $baselineEntries) {
            if ($null -eq $entry) {
                throw 'RunRecord sandbox_acl_baseline entries 不得包含 null。'
            }
            foreach ($name in @('identity', 'identity_resolution', 'rights', 'canonical', 'fingerprint')) {
                $value = Get-DispatchJsonProperty -Object $entry -Name $name
                if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
                    throw ('RunRecord sandbox_acl_baseline entry 缺少欄位：' + $name)
                }
            }
            if ([string](Get-DispatchJsonProperty -Object $entry -Name 'identity_resolution') -notin @('resolved', 'unresolved')) {
                throw 'RunRecord sandbox_acl_baseline identity_resolution 異常。'
            }
            if ([string](Get-DispatchJsonProperty -Object $entry -Name 'fingerprint') -notmatch '^[a-fA-F0-9]{64}$') {
                throw 'RunRecord sandbox_acl_baseline entry fingerprint 異常。'
            }
        }
        $baselineFingerprint = [string](Get-DispatchJsonProperty -Object $sandboxBaseline -Name 'fingerprint')
        if ($baselineStatus -eq 'known' -and $baselineFingerprint -notmatch '^[a-fA-F0-9]{64}$') {
            throw 'RunRecord sandbox_acl_baseline fingerprint 異常。'
        }
        if ($baselineStatus -in @('unknown', 'failed') -and [string]::IsNullOrWhiteSpace([string](Get-DispatchJsonProperty -Object $sandboxBaseline -Name 'error'))) {
            throw 'RunRecord sandbox_acl_baseline 失敗狀態缺少 error。'
        }
        $baselineCapturedAt = [string](Get-DispatchJsonProperty -Object $sandboxBaseline -Name 'captured_at_utc')
        $baselineCapturedAtValue = [DateTimeOffset]::MinValue
        if ([string]::IsNullOrWhiteSpace($baselineCapturedAt) -or -not [DateTimeOffset]::TryParse($baselineCapturedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$baselineCapturedAtValue)) {
            throw 'RunRecord sandbox_acl_baseline captured_at_utc 異常。'
        }
    }
    $sandboxEvidence = Get-DispatchJsonProperty -Object $record -Name 'sandbox_acl_evidence'
    if ($null -ne $sandboxEvidence) {
        $captureStatus = [string](Get-DispatchJsonProperty -Object $sandboxEvidence -Name 'capture_status')
        if ($captureStatus -notin @('pending', 'captured', 'no_match', 'unknown', 'failed', 'rejected')) {
            throw 'RunRecord sandbox_acl_evidence capture_status 異常。'
        }
        $normalCompletion = Get-DispatchJsonProperty -Object $sandboxEvidence -Name 'normal_completion'
        $continuationAllowed = Get-DispatchJsonProperty -Object $sandboxEvidence -Name 'continuation_allowed'
        if ($normalCompletion -isnot [bool] -or $continuationAllowed -isnot [bool]) {
            throw 'RunRecord sandbox_acl_evidence completion 欄位必須為 boolean。'
        }
        if ($continuationAllowed -and -not $normalCompletion) {
            throw 'RunRecord sandbox_acl_evidence 不得在未正常完成時允許續行。'
        }
        $evidenceEntries = @((Get-DispatchJsonProperty -Object $sandboxEvidence -Name 'entries') | Where-Object { $null -ne $_ })
        if ($captureStatus -eq 'pending' -and $evidenceEntries.Count -gt 0) {
            throw 'RunRecord sandbox_acl_evidence pending 不得包含 entries。'
        }
        $capturedAt = [string](Get-DispatchJsonProperty -Object $sandboxEvidence -Name 'captured_at_utc')
        $capturedAtValue = [DateTimeOffset]::MinValue
        if ($captureStatus -ne 'pending' -and ([string]::IsNullOrWhiteSpace($capturedAt) -or -not [DateTimeOffset]::TryParse($capturedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$capturedAtValue))) {
            throw 'RunRecord sandbox_acl_evidence captured_at_utc 異常。'
        }
        $evidenceFingerprint = [string](Get-DispatchJsonProperty -Object $sandboxEvidence -Name 'fingerprint')
        if (-not [string]::IsNullOrWhiteSpace($evidenceFingerprint) -and $evidenceFingerprint -notmatch '^[a-fA-F0-9]{64}$') {
            throw 'RunRecord sandbox_acl_evidence fingerprint 異常。'
        }
        if ($captureStatus -eq 'captured' -and (-not $normalCompletion -or -not $continuationAllowed)) {
            throw 'RunRecord captured sandbox_acl_evidence 必須為正常完成且允許續行。'
        }
        foreach ($entry in $evidenceEntries) {
            if ($null -eq $entry) {
                throw 'RunRecord sandbox_acl_evidence entries 不得包含 null。'
            }
            foreach ($name in @('identity', 'identity_resolution', 'rights', 'canonical', 'fingerprint')) {
                $value = Get-DispatchJsonProperty -Object $entry -Name $name
                if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
                    throw ('RunRecord sandbox_acl_evidence entry 缺少欄位：' + $name)
                }
            }
            if ([string](Get-DispatchJsonProperty -Object $entry -Name 'identity_resolution') -notin @('resolved', 'unresolved')) {
                throw 'RunRecord sandbox_acl_evidence identity_resolution 異常。'
            }
            if ([string](Get-DispatchJsonProperty -Object $entry -Name 'fingerprint') -notmatch '^[a-fA-F0-9]{64}$') {
                throw 'RunRecord sandbox_acl_evidence fingerprint 異常。'
            }
        }
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
    $activeRecords = @()
    $unconfirmedRecords = @()
    if ($null -ne $pidCheck) {
        $activeValue = Get-DispatchJsonProperty -Object $pidCheck -Name 'ActiveRecords'
        $unconfirmedValue = Get-DispatchJsonProperty -Object $pidCheck -Name 'UnconfirmedRecords'
        if ($null -ne $activeValue) { $activeRecords = @($activeValue) }
        if ($null -ne $unconfirmedValue) { $unconfirmedRecords = @($unconfirmedValue) }
    }
    $blockingUnconfirmedRecords = @(
        $unconfirmedRecords | Where-Object {
            $recordDispatchSlug = [string](Get-OptionalObjectProperty -Object $_ -Name 'DispatchSlug')
            $identityStatus = [string](Get-OptionalObjectProperty -Object $_ -Name 'IdentityStatus')
            $recordDispatchSlug -eq $DispatchSlug -and $identityStatus -ne 'root-process-absent'
        }
    )
    if (@($activeRecords | Where-Object { $_.DispatchSlug -eq $DispatchSlug }).Count -gt 0 -or $blockingUnconfirmedRecords.Count -gt 0) {
        throw '最新 failed attempt 仍有 active 或未確認的程序，拒絕 cold-start。'
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
        if ($candidate.launch_state -eq 'launch-failed' -and $classification.classification -ne 'actual-start') { continue }
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
    $activeRecords = @()
    $unconfirmedRecords = @()
    if ($null -ne $pidCheck) {
        $activeValue = Get-DispatchJsonProperty -Object $pidCheck -Name 'ActiveRecords'
        $unconfirmedValue = Get-DispatchJsonProperty -Object $pidCheck -Name 'UnconfirmedRecords'
        if ($null -ne $activeValue) { $activeRecords = @($activeValue) }
        if ($null -ne $unconfirmedValue) { $unconfirmedRecords = @($unconfirmedValue) }
    }
    if (@($activeRecords | Where-Object { $_.DispatchSlug -eq $DispatchSlug }).Count -gt 0 -or @($unconfirmedRecords | Where-Object { $_.DispatchSlug -eq $DispatchSlug -and $_.IdentityStatus -ne 'root-process-absent' }).Count -gt 0) { throw '鏈尾仍執行中或程序身分無法確認。' }
    if (-not (Test-Path -LiteralPath $anchor.pid_record_path -PathType Leaf) -and -not $anchorEvents.Terminal) { throw '鏈尾缺少 PID 停止證據。' }
    if (-not [string]::IsNullOrWhiteSpace($LastMessagePath) -and -not [string]::Equals((Resolve-AbsolutePath $LastMessagePath), $anchor.last_message_path, [StringComparison]::OrdinalIgnoreCase)) { throw '續行顯式 last-message 與鏈尾不一致。' }
    $message = Get-Content -LiteralPath $anchor.last_message_path -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($message)) { throw '續行 last-message 為空。' }
    if (-not $anchorEvents.Completed) {
        foreach ($name in @('已確認結論', '未完成單位', '證據位置')) {
            $match = [regex]::Match($message, ('(?m)^[ \t-]*' + [regex]::Escape($name) + '[ \t]*[:：][ \t]*(?<value>[^\r\n]+)\r?$'))
            if (-not $match.Success -or [string]::IsNullOrWhiteSpace($match.Groups['value'].Value)) { throw "續行 last-message 缺少必要交接欄位：$name" }
        }
    }
    $skippedAttempts = @(
        @($chain.ToArray()) |
            Where-Object { $startClassifications[$_.run_id].classification -eq 'unstarted-sandbox' } |
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
        ResumeThreadId = $ResumeThreadId
    }
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
        for ($index = 0; $index -lt $tokens.Count; $index++) {
            if ([string]::Equals([string]$tokens[$index], $RequiredIdentifier, [System.StringComparison]::Ordinal)) {
                $requiredIndex = $index
                break
            }
        }
    }

    $dispatchMatch = [regex]::Match($messageText, '(?i)(?:dispatchSlug|dispatch_slug)[ \t]*[:=][ \t]*(?<value>[a-z0-9]+(?:-[a-z0-9]+)*)')
    $lineMatch = [regex]::Match($messageText, '(?i)(?:lineSlug|line_slug)[ \t]*[:=][ \t]*(?<value>[a-z0-9]+(?:-[a-z0-9]+)*)')
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
    if ($null -ne $runRecord) {
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

function Invoke-Start {
    $preflight = $null
    $sourceRootPath = $null
    $executionRootPath = $null
    $lineSlugValue = $null
    $dispatchSlugValue = $null
    $writeModeValue = 'readonly'
    $promptSourcePathValue = $null
    $promptSourceSha256Value = $null
    $promptTransferPathValue = $null
    $promptTransferSha256Value = $null
    $promptPathValue = $null
    $inspectResultPathValue = $null
    $codexExecutable = $null
    $historyRoot = $null
    $sourceHistoryRoot = $null
    $eventPath = $null
    $errorPath = $null
    $lastMessagePathValue = $null
    $threadPath = $null
    $pidPath = $null
    $launcherPath = $null
    $exitSidecarPathValue = $null
    $launcher = $null
    $startInfo = $null
    $process = $null
    $relay = $null
    $startedSnapshot = $null
    $startedSnapshotError = $null
    $processStarted = $false
    $skipProcessCleanup = $false
    $phase = 'preparation'
    $cleanupStatus = 'not-started'
    $cleanupError = $null
    $requestedProfileValue = $Profile
    $effectiveProfileValue = $Profile
    $sessionModeValue = $SessionMode
    $advisorActivationDecision = $null
    $activationModeValue = 'none'
    $authorizationSourceValue = $null
    $primaryRemainingPercentValue = $null
    $requiredSourceValue = $null
    $dispatchKindValue = $DispatchKind
    $beforeSnapshotPathValue = $null
    $beforeSnapshotObject = $null
    $afterSnapshotPathValue = $QuotaAfterPath
    $afterSnapshotSha256Value = $null
    $scopePlan = $null
    $scopePlanPathValue = $null
    $scopePlanParentPathValue = $null
    $scopePlanParentSha256Value = $null
    $scopePlanParentRunIdValue = $null
    $scopePlanRootRunIdValue = $null
    $scopePlanSelectionValue = 'root'
    $continuationContextPath = $null
    $continuationContextMessage = $null
    $previousRun = $null
    $runRecord = $null
    $runRecordPathValue = $null
    $latestColdStartFailure = $null
    $attemptParentRunIdValue = $null
    $resumeAnchorRunIdValue = $null
    $skippedAttemptsValue = @()
    $parentOptionsModel = $null
    $parentOptionsGate = $null
    $processGate = $null
    $aclGate = $null
    $sandboxAclBaseline = $null
    $sandboxAclEvidence = $null
    $effectiveCodexHomePath = $null
    $prepareBinding = $null
    $prepareResultPathValue = $null
    $prepareResultSha256Value = $null
    $prepareStatusValue = $null
    $beforeSnapshotSha256Value = $null
    $beforeSnapshotCapturedAtUtcValue = $null
    $baselineBinding = $null
    $baselineResolution = $null
    $baselineQueryPathValue = $null
    $baselineQuerySha256Value = $null
    $baselineQueryLocationValue = $null
    $runId = [guid]::NewGuid().ToString('D')
    $evidencePackInfo = $null
    $requestedModelEvidence = $null
    $requestedReasoningEffortEvidence = $null
    $resolvedModelEvidence = $null
    $resolvedReasoningEffortEvidence = $null
    $modelEvidence = $null
    $profileConfigPathValue = $null
    $profileConfigSha256AtCompare = $null
    $codexHomeEvidencePath = $null
    $resolvedModelValue = $null
    $resolvedReasoningEffortValue = $null
    $resumeDiagnostics = $null
    $startedAtUtcValue = $null
    $preflightPathValue = $null
    $preflightSha256Value = $null
    $createdAtUtcValue = $null
    $failureReasonCode = $null
    $interruptionSafeguardApplied = $true
    $budgetMonitorStatus = [ordered]@{
        state = 'not-started'
        stopRequested = $false
        safePointFound = $false
        safePointMissing = $false
        abortReason = $null
    }
    $monitorPathValue = $BudgetMonitorPath

    try {
    $preflight = Get-PreflightData
    if ([string]::IsNullOrWhiteSpace($PreflightResultPath)) {
        throw 'Start 必須提供 PreflightResultPath，供 RunRecord 綁定原始證據。'
    }
    $sourceRootValue = Get-RequiredPreflightProperty -Object $preflight -Name 'sourceRoot'
    $executionRootValue = Get-RequiredPreflightProperty -Object $preflight -Name 'executionRoot'
    $lineSlugValue = Get-RequiredPreflightProperty -Object $preflight -Name 'lineSlug'
    $dispatchSlugValue = Get-RequiredPreflightProperty -Object $preflight -Name 'dispatchSlug'
    $writeModeValue = 'readonly'
    $writeModeProperty = $preflight.PSObject.Properties['writeMode']
    if ($null -ne $writeModeProperty) {
        if (-not ($writeModeProperty.Value -is [string])) {
            throw 'Preflight 輸出欄位 writeMode 必須為字串。'
        }
        if (-not [string]::IsNullOrWhiteSpace($writeModeProperty.Value)) {
            $writeModeValue = $writeModeProperty.Value
        }
    }
    $dispatchKindProperty = $preflight.PSObject.Properties['dispatchKind']
    if ([string]::IsNullOrWhiteSpace($dispatchKindValue) -and $null -ne $dispatchKindProperty) {
        $dispatchKindValue = [string]$dispatchKindProperty.Value
    }
    if ([string]::IsNullOrWhiteSpace($dispatchKindValue)) {
        $dispatchKindValue = 'resource'
    }
    if ($TaskType -eq 'advisor-consult' -and [string]::IsNullOrWhiteSpace($AdvisorRequestSource)) {
        $AdvisorRequestSource = 'automatic-quota'
    }
    $sourceRootPath = Resolve-AbsolutePath -Path $sourceRootValue
    $executionRootPath = Resolve-AbsolutePath -Path $executionRootValue
    if (-not (Test-Path -LiteralPath $executionRootPath -PathType Container)) {
        throw "executionRoot 不存在或不是目錄：$executionRootPath"
    }
    $dispatchStageBinding = Get-DispatchScriptVariableValue -Name 'DispatchStageBinding'
    if ($null -ne $dispatchStageBinding) {
        $dispatchRootForBinding = [string](Get-DispatchJsonProperty -Object $preflight -Name 'dispatchRoot')
        if ([string]::IsNullOrWhiteSpace($dispatchRootForBinding)) {
            $dispatchRootForBinding = $DispatchRoot
        }
        $null = Assert-DispatchStageBinding -Binding $dispatchStageBinding -Stage 'start' -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -DispatchRoot $dispatchRootForBinding -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -TargetPath @($TargetPath) -ResultPath $ResultPath -PreflightResultPath $PreflightResultPath -PrepareResultPath $PrepareResultPath -QuotaBeforePath $QuotaBeforePath -QuotaAfterPath $QuotaAfterPath
    }
    if (-not (Test-PathWithinRoot -Path $executionRootPath -Root $sourceRootPath) -and $executionRootPath -ne $sourceRootPath) {
        $dispatchRootValue = $preflight.PSObject.Properties['dispatchRoot']
            if ($null -eq $dispatchRootValue -or -not ($dispatchRootValue.Value -is [string]) -or $dispatchRootValue.Value -ne $executionRootPath) {
                throw 'executionRoot 未通過 sourceRoot／dispatchRoot 界線驗證。'
            }
    }
    if ([string]::IsNullOrWhiteSpace($PromptPath)) {
        throw 'Start 必須提供 PromptPath。'
    }
    $promptSourcePathValue = Resolve-AbsolutePath -Path $PromptPath
    if (-not (Test-PathWithinRoot -Path $promptSourcePathValue -Root $sourceRootPath) -and -not (Test-PathWithinRoot -Path $promptSourcePathValue -Root $executionRootPath)) {
        throw ('PromptSourceBoundary：Prompt 必須位於 sourceRoot 或 executionRoot 內；received=' + $promptSourcePathValue + '; sourceRoot=' + $sourceRootPath + '; executionRoot=' + $executionRootPath)
    }
    if (-not (Test-Path -LiteralPath $promptSourcePathValue -PathType Leaf)) {
        throw "Prompt 檔案不存在：$promptSourcePathValue"
    }
    $promptPathValue = $promptSourcePathValue

    $historyRoot = Join-Path -Path $executionRootPath -ChildPath '.local\ai-sessions\history'
    $sourceHistoryRoot = Join-Path -Path $sourceRootPath -ChildPath '.local\ai-sessions\history'
    $effectiveCodexHomePath = Resolve-CodexHomeForEvidence -CodexHomePath $CodexHome
    $preflightPreparePathProperty = $preflight.PSObject.Properties['prepareResultPath']
    $preflightPrepareShaProperty = $preflight.PSObject.Properties['prepareResultSha256']
    $preflightPreparePathValue = if ($null -eq $preflightPreparePathProperty -or $null -eq $preflightPreparePathProperty.Value) { $null } else { [string]$preflightPreparePathProperty.Value }
    $preflightPrepareShaValue = if ($null -eq $preflightPrepareShaProperty -or $null -eq $preflightPrepareShaProperty.Value) { $null } else { [string]$preflightPrepareShaProperty.Value }
    if (-not [string]::IsNullOrWhiteSpace($PrepareResultPath) -and -not [string]::IsNullOrWhiteSpace($preflightPreparePathValue) -and -not [string]::Equals((Resolve-AbsolutePath -Path $PrepareResultPath), (Resolve-AbsolutePath -Path $preflightPreparePathValue), [System.StringComparison]::OrdinalIgnoreCase)) {
        $phase = 'preparation'
        throw 'PrepareArtifactMismatch：Start 的 PrepareResultPath 與 Preflight result 不一致。'
    }
    if (-not [string]::IsNullOrWhiteSpace($PrepareResultPath)) {
        $prepareResultPathValue = Resolve-AbsolutePath -Path $PrepareResultPath
    }
    elseif (-not [string]::IsNullOrWhiteSpace($preflightPreparePathValue)) {
        $prepareResultPathValue = Resolve-AbsolutePath -Path $preflightPreparePathValue
    }
    if ([string]::Equals($sourceRootPath, $executionRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (-not [string]::IsNullOrWhiteSpace($prepareResultPathValue)) {
            $prepareBinding = Resolve-PrepareResultBinding -Path $prepareResultPathValue -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -ExpectedSha256 $preflightPrepareShaValue
            if ($prepareBinding.Status -ne 'not-required') {
                $phase = 'preparation'
                throw 'PrepareArtifactMismatch：direct-write 的 Prepare result status 必須是 not-required。'
            }
        }
        else {
            $directPrepareRootInfo = Get-PrepareRootInfo -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -DispatchRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue
            $directPrepareDocument = New-PrepareDocument -RootInfo $directPrepareRootInfo -Status 'not-required' -RequestPathValue $null -RequestSha256Value $null -EffectiveCodexHome $effectiveCodexHomePath -Artifacts @() -ErrorValue $null
            $directPreparePath = Get-PrepareResultTargetPath -RootInfo $directPrepareRootInfo -PrepareResultPathValue $null -ResultPathValue $null
            $directPrepareWritten = Write-PrepareResultDocument -Path $directPreparePath -Document $directPrepareDocument
            $prepareResultPathValue = $directPrepareWritten.Path
            $prepareResultSha256Value = $directPrepareWritten.Sha256
            $prepareBinding = [pscustomobject]@{
                Path               = $directPrepareWritten.Path
                Sha256             = $directPrepareWritten.Sha256
                Status             = 'not-required'
                Document           = $directPrepareWritten.Document
                Artifacts          = @()
                EffectiveCodexHome = $effectiveCodexHomePath
            }
        }
        if ($null -ne $prepareBinding) {
            $prepareResultPathValue = $prepareBinding.Path
            $prepareResultSha256Value = $prepareBinding.Sha256
            $prepareStatusValue = $prepareBinding.Status
        }
        else {
            $prepareStatusValue = 'not-required'
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($prepareResultPathValue)) {
            $phase = 'preparation'
            throw 'PrepareRequired：worktree Start 必須提供 status=Prepared 的 PrepareResultPath。'
        }
        $prepareBinding = Resolve-PrepareResultBinding -Path $prepareResultPathValue -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -ExpectedSha256 $preflightPrepareShaValue
        if ($prepareBinding.Status -ne 'Prepared') {
            $phase = 'preparation'
            throw 'PrepareArtifactMismatch：worktree Start 的 Prepare result status 必須是 Prepared。'
        }
        $prepareResultSha256Value = $prepareBinding.Sha256
        $prepareStatusValue = $prepareBinding.Status
    }
    $runDirectory = Get-DispatchRunDirectory -SourceRoot $sourceRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue
    if ([string]::IsNullOrWhiteSpace($ResumeThreadId)) {
        $latestColdStartFailure = Resolve-LatestColdStartFailure -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue
        if ($null -ne $latestColdStartFailure) {
            $attemptParentRunIdValue = $latestColdStartFailure.run_id
        }
    }
    $timestamp = [datetime]::UtcNow.ToString('yyyyMMdd_HHmmss_fff') + '-' + $runId
    $eventPath = Join-Path -Path $historyRoot -ChildPath ('codex-exec-' + $timestamp + '.jsonl')
    $errorPath = Join-Path -Path $historyRoot -ChildPath ('codex-exec-' + $timestamp + '.stderr.log')
    $exitSidecarPathValue = Join-Path -Path $historyRoot -ChildPath ('codex-exit-' + $timestamp + '.json')
    $exitSidecarPathValue = Resolve-DispatchOutputPath -CandidatePath $exitSidecarPathValue -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
    $generatedLastMessagePath = Join-Path $historyRoot ('codex-last-message-' + $timestamp + '.md')
    $lastMessagePathValue = $generatedLastMessagePath
    if (-not [string]::IsNullOrWhiteSpace($ResumeThreadId)) {
        $previousRun = Resolve-PreviousDispatchRun -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -ResumeThreadId $ResumeThreadId -LastMessagePath $LastMessagePath
        $attemptParentRunIdValue = $previousRun.ChainTailRecord.run_id
        $resumeAnchorRunIdValue = $previousRun.AnchorRecord.run_id
        $skippedAttemptsValue = @($previousRun.SkippedAttempts)
        $continuationContextPath = $previousRun.AnchorRecord.last_message_path
        $continuationContextMessage = $previousRun.Message
    }
    elseif (-not [string]::IsNullOrWhiteSpace($LastMessagePath)) {
        $lastMessagePathValue = Resolve-AbsolutePath $LastMessagePath
    }
    $sandboxValue = if ($TaskType -eq 'advisor-consult') { 'read-only' } else { 'workspace-write' }
    $anchorParentOptions = $null
    if ($null -ne $previousRun) {
        $anchorParentOptions = Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'parent_options'
        if ($null -eq $anchorParentOptions) {
            $phase = 'preparation'
            throw 'ParentOptionsUnknown：anchor RunRecord 缺少 parent_options，拒絕以當次呼叫重建續行選項。'
        }
    }
    $parentOptionsResolution = Resolve-ParentOptionsForStart -Profile $effectiveProfileValue -ProfileProvided ([bool]$script:ProfileExplicit) -Sandbox $sandboxValue -WorkingDirectory $executionRootPath -AddDirectory $AddDirectory -Search ([bool]$Search) -AddDirectoryProvided ([bool]$script:AddDirectoryExplicit) -SearchProvided ([bool]$script:SearchExplicit) -CodexParentOption $CodexParentOption -CodexParentOptionProvided ([bool]$script:CodexParentOptionExplicit) -Anchor $anchorParentOptions
    if (-not [string]::IsNullOrWhiteSpace([string]$parentOptionsResolution.code)) {
        $phase = 'preparation'
        throw ($parentOptionsResolution.code + '：父層選項差異欄位=' + (($parentOptionsResolution.differences) -join ','))
    }
    $parentOptionsModel = $parentOptionsResolution.model
    $effectiveProfileValue = [string](Get-DispatchJsonProperty -Object $parentOptionsModel -Name 'profile')
    Assert-AdvisorContract -RequestedProfile $effectiveProfileValue -TaskType $TaskType -DispatchKind $dispatchKindValue -WriteMode $writeModeValue
    if (-not (Test-PathWithinRoot $lastMessagePathValue $executionRootPath)) { throw 'LastMessagePath 必須位於 executionRoot 內。' }
    if (Test-Path -LiteralPath $lastMessagePathValue) { throw 'LastMessagePath 已存在，拒絕覆寫證據。' }
    $threadPath = $ThreadIdPath
    if ([string]::IsNullOrWhiteSpace($threadPath)) {
        $threadPath = Join-Path -Path $historyRoot -ChildPath ('codex-thread-' + $dispatchSlugValue + '.txt')
    }
    else {
        $threadPath = Resolve-AbsolutePath -Path $threadPath
    }
    $pidPath = $PidRecordPath
    if ([string]::IsNullOrWhiteSpace($pidPath)) {
        $pidPath = Join-Path -Path $sourceHistoryRoot -ChildPath ('codex-pid-' + $timestamp + '.txt')
    }
    else {
        $pidPath = Resolve-AbsolutePath -Path $pidPath
    }
    if (Test-IsWindowsPlatform) {
        $launcherPath = Join-Path -Path $historyRoot -ChildPath ('codex-launch-' + $timestamp + '.cmd')
    }
    else {
        $launcherPath = Join-Path -Path $historyRoot -ChildPath ('codex-launch-' + $timestamp + '.sh')
    }
    New-Item -ItemType Directory -Path $historyRoot, $sourceHistoryRoot -Force | Out-Null
    $promptTransfer = Copy-DispatchPromptToExecutionHistory -PromptPath $promptSourcePathValue -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -HistoryRoot $historyRoot -Timestamp $timestamp
    $promptTransferPathValue = $promptTransfer.Path
    $promptSourceSha256Value = $promptTransfer.SourceSha256
    $promptTransferSha256Value = $promptTransfer.DestinationSha256
    $promptPathValue = Resolve-DispatchOutputPath -CandidatePath (Join-Path -Path $historyRoot -ChildPath ('codex-prompt-' + $timestamp + '.md')) -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
    $inspectResultPathValue = Resolve-DispatchOutputPath -CandidatePath (Join-Path -Path $historyRoot -ChildPath ('inspect-result-' + $dispatchSlugValue + '-' + $timestamp + '.json')) -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
    $preflightPathValue = Resolve-AbsolutePath -Path $PreflightResultPath
    $preflightSha256Value = Get-FileSha256 -Path $preflightPathValue
    $createdAtUtcValue = [datetime]::UtcNow.ToString('o')
    $isWorktreeStart = -not [string]::Equals($sourceRootPath, $executionRootPath, [StringComparison]::OrdinalIgnoreCase)
    if ($isWorktreeStart) {
        $baselinePathProperty = $preflight.PSObject.Properties['baselinePath']
        $baselineSha256Property = $preflight.PSObject.Properties['baselineSha256']
        $baselineQueryPathValue = if ($null -eq $baselinePathProperty -or $null -eq $baselinePathProperty.Value) { $null } else { [string]$baselinePathProperty.Value }
        $baselineQuerySha256Value = if ($null -eq $baselineSha256Property -or $null -eq $baselineSha256Property.Value) { $null } else { [string]$baselineSha256Property.Value }
        $baselineQueryLocationValue = 'Preflight.baselinePath,Preflight.baselineSha256'
        $baselineResolution = [ordered]@{
            status = 'pending'
            requested_path = $baselineQueryPathValue
            requested_sha256 = $baselineQuerySha256Value
            query_location = $baselineQueryLocationValue
            path = $null
            sha256 = $null
            error = $null
        }
    }
    else {
        $baselineQueryLocationValue = 'direct-write'
        $baselineResolution = [ordered]@{
            status = 'not-applicable'
            requested_path = $null
            requested_sha256 = $null
            query_location = $baselineQueryLocationValue
            path = $null
            sha256 = $null
            error = $null
        }
    }
    $runRecord = [pscustomobject]@{
        schema = 'ai-sessions.dispatch-run.v1'
        run_id = $runId
        dispatch_slug = $dispatchSlugValue
        line_slug = $lineSlugValue
        source_root = $sourceRootPath
        execution_root = $executionRootPath
        previous_run_id = if ($null -eq $previousRun) { $null } else { $previousRun.AnchorRecord.run_id }
        attempt_parent_run_id = $attemptParentRunIdValue
        resume_anchor_run_id = $resumeAnchorRunIdValue
        skipped_attempts = @($skippedAttemptsValue)
        requested_thread_id = if ([string]::IsNullOrWhiteSpace($ResumeThreadId)) { $null } else { $ResumeThreadId }
        thread_id = $null
        event_stream_path = $eventPath
        last_message_path = $lastMessagePathValue
        scope_plan_path = $null
        scope_plan_sha256 = $null
        scope_plan_parent_path = $null
        scope_plan_parent_sha256 = $null
        scope_plan_parent_run_id = $null
        scope_plan_root_run_id = $null
        scope_plan_selection = 'root'
        preflight_result_path = $preflightPathValue
        preflight_sha256 = $preflightSha256Value
        prepare_result_path = $prepareResultPathValue
        prepare_result_sha256 = $prepareResultSha256Value
        prepare_status = $prepareStatusValue
        created_at_utc = $createdAtUtcValue
        started_at_utc = $null
        launch_state = 'prepared'
        failure = $null
        resume_diagnostics = $null
        model_evidence = ConvertTo-DispatchEvidenceGroup -Evidence $null -Field 'model'
        reasoning_effort_evidence = ConvertTo-DispatchEvidenceGroup -Evidence $null -Field 'model_reasoning_effort'
        baseline_path = $null
        baseline_sha256 = $null
        baseline_resolution = $baselineResolution
        pid_record_path = $pidPath
        thread_id_path = $threadPath
        launcher_path = $launcherPath
        process_exit_code_sidecar_path = $exitSidecarPathValue
        prompt_path = $promptPathValue
        prompt_source_path = $promptSourcePathValue
        prompt_source_sha256 = $promptSourceSha256Value
        prompt_transfer_path = $promptTransferPathValue
        prompt_transfer_sha256 = $promptTransferSha256Value
        inspect_result_path = $inspectResultPathValue
        profile_config_path = $null
        codex_home = $effectiveCodexHomePath
        effective_codex_home = $effectiveCodexHomePath
        evidence_pack_path = $null
        evidence_pack_sha256 = $null
        evidence_pack_length = $null
        advisor_request_source = $AdvisorRequestSource
        advisor_activation_decision = $null
        advisor_activation_granted = $false
        advisor_activation_notice = $null
        advisor_hard_limit_percent = $null
        advisor_unit_estimate_percent = $null
        activationMode = $activationModeValue
        authorizationSource = $authorizationSourceValue
        primaryRemainingPercent = $primaryRemainingPercentValue
        requiredSource = $requiredSourceValue
        parent_options = $null
        parent_options_sha256 = $null
        parent_options_status = 'unknown'
        acl_gate = $null
        sandbox_acl_baseline = $null
        sandbox_acl_evidence = $null
         quota_before_path = $null
         quota_before_sha256 = $null
         quota_before_captured_at_utc = $null
         quota_before_freshness = $null
         quota_before_observations = $null
         quota_before_service_rejection = $null
         quota_after_path = $null
         quota_after_sha256 = $null
         request_path = if ($null -eq $script:RequestContext) { $null } else { [string]$script:RequestContext.path }
         request_sha256 = if ($null -eq $script:RequestContext) { $null } else { [string]$script:RequestContext.sha256 }
         request_operation = if ($null -eq $script:RequestContext) { $null } else { [string](Get-DispatchJsonProperty -Object $script:RequestContext.document -Name 'operation') }
     }
    try {
        $runRecordPathValue = Write-DispatchRunRecord -Record $runRecord
    }
    catch {
        $runRecord = $null
        throw
    }
    if ($isWorktreeStart) {
        try {
            $baselineBinding = Resolve-DispatchBaselineBinding -Preflight $preflight -SourceRoot $sourceRootPath -DispatchRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -BaseSha (Get-RequiredPreflightProperty $preflight 'baseSha')
            $baselineResolution.status = 'confirmed'
            $baselineResolution.path = $baselineBinding.Path
            $baselineResolution.sha256 = $baselineBinding.Sha256
            $baselineResolution.error = $null
        }
        catch {
            $failureReasonCode = 'BaselineUnknown'
            $baselineResolution.status = 'failed'
            $baselineResolution.path = $null
            $baselineResolution.sha256 = $null
            $baselineResolution.error = $_.Exception.Message
            throw
        }
    }
    $codexExecutable = Get-CodexExecutablePath -ConfiguredPath $CodexPath
    $startProcessResult = Get-PidCheckResult -SourceRoot $sourceRootPath -LineSlug $lineSlugValue -WriteMode $writeModeValue
    $startActiveRecords = @()
    $startUnconfirmedRecords = @()
    if ($null -ne $startProcessResult) {
        $startActiveValue = Get-DispatchJsonProperty -Object $startProcessResult -Name 'ActiveRecords'
        $startUnconfirmedValue = Get-DispatchJsonProperty -Object $startProcessResult -Name 'UnconfirmedRecords'
        if ($null -ne $startActiveValue) {
            $startActiveRecords = @($startActiveValue | Where-Object { [string](Get-DispatchJsonProperty -Object $_ -Name 'DispatchSlug') -eq $dispatchSlugValue })
        }
        if ($null -ne $startUnconfirmedValue) {
            $startUnconfirmedRecords = @($startUnconfirmedValue | Where-Object {
                    [string](Get-DispatchJsonProperty -Object $_ -Name 'DispatchSlug') -eq $dispatchSlugValue -and
                    [string](Get-DispatchJsonProperty -Object $_ -Name 'IdentityStatus') -ne 'root-process-absent'
                })
        }
    }
    $processGate = [ordered]@{
        status = if ($null -eq $startProcessResult) { 'unknown' } elseif (@($startActiveRecords).Count -gt 0) { 'alive' } elseif (@($startUnconfirmedRecords).Count -gt 0) { 'unknown' } elseif ([bool](Get-DispatchJsonProperty -Object $startProcessResult -Name 'Blocked')) { 'alive' } else { 'stopped' }
        pid_check = $startProcessResult
        active_records = @($startActiveRecords)
        unconfirmed_records = @($startUnconfirmedRecords)
        stopped_evidence = $null -ne $startProcessResult -and @($startActiveRecords).Count -eq 0 -and @($startUnconfirmedRecords).Count -eq 0 -and -not [bool](Get-DispatchJsonProperty -Object $startProcessResult -Name 'Blocked')
    }
    if ($processGate.status -ne 'stopped') {
        $phase = 'preparation'
        throw ('ProcessAlive：Start process gate 未確認 stopped；evidence=' + (ConvertTo-Json -InputObject $processGate -Depth 20 -Compress))
    }
    $continuationAclRecord = if ($null -eq $previousRun) { $null } else { $previousRun.LatestActualStartRecord }
    if ($null -ne $previousRun -and $null -eq $continuationAclRecord) {
        $phase = 'preparation'
        throw 'WorktreeAclContinuationDenied：續行沒有可作為 ACL 錨點的 actual-start RunRecord。'
    }
    $aclGate = Get-WorktreeAclGate -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -WriteMode $writeModeValue -ContinuationRecord $continuationAclRecord
    if ($aclGate.status -in @('residue', 'unknown', 'failed', 'continuation-denied')) {
        $phase = 'preparation'
        throw ($aclGate.rejection_code + '：ACL gate status=' + $aclGate.status)
    }
    if ($aclGate.status -eq 'not-applicable') {
        $sandboxAclEvidence = $null
    }
    else {
        $sandboxAclEvidence = New-SandboxAclEvidenceDocument -Entries @() -CaptureStatus 'pending' -NormalCompletion $false -ContinuationAllowed $false
    }

    if (-not [string]::IsNullOrWhiteSpace($ResumeThreadId)) {
        $sessionModeValue = 'continuation'
    }
    $requestedModelEvidence = New-RequestedDispatchEvidence -Value $Model -Field 'Model'
    $requestedReasoningEffortEvidence = New-RequestedDispatchEvidence -Value $ReasoningEffort -Field 'ReasoningEffort'
    $effectiveCodexHomePath = Resolve-CodexHomeForEvidence -CodexHomePath $CodexHome
    $codexHomeEvidencePath = $effectiveCodexHomePath
    $profileConfigPathValue = Resolve-ProfileConfigPath -CodexHome $codexHomeEvidencePath -Profile $effectiveProfileValue
    $profileEvidence = Read-ProfileModelEvidence -ConfigPath $profileConfigPathValue -Profile $effectiveProfileValue
    $resolvedModelEvidence = $profileEvidence.model
    $resolvedReasoningEffortEvidence = $profileEvidence.reasoning_effort
    $profileConfigSha256AtCompare = $profileEvidence.config_sha256
    $resolvedModelValue = Get-DispatchEvidenceValue -Evidence $resolvedModelEvidence
    $resolvedReasoningEffortValue = Get-DispatchEvidenceValue -Evidence $resolvedReasoningEffortEvidence
    $requestedModelValue = Get-DispatchEvidenceValue -Evidence $requestedModelEvidence
    $requestedReasoningEffortValue = Get-DispatchEvidenceValue -Evidence $requestedReasoningEffortEvidence
    if ($null -ne $requestedModelValue -and $null -ne $resolvedModelValue -and -not [string]::Equals($requestedModelValue, $resolvedModelValue, [StringComparison]::Ordinal)) {
        $phase = 'profile-evidence'
        throw "RequestedResolutionMismatch：requested model=$requestedModelValue；resolved model=$resolvedModelValue。"
    }
    if ($null -ne $requestedReasoningEffortValue -and $null -ne $resolvedReasoningEffortValue -and -not [string]::Equals($requestedReasoningEffortValue, $resolvedReasoningEffortValue, [StringComparison]::Ordinal)) {
        $phase = 'profile-evidence'
        throw "RequestedResolutionMismatch：requested reasoning effort=$requestedReasoningEffortValue；resolved reasoning effort=$resolvedReasoningEffortValue。"
    }
    $modelEvidence = New-ModelEvidence -RequestedModel $requestedModelEvidence -ResolvedModel $resolvedModelEvidence -RuntimeModel $null -RequestedReasoningEffort $requestedReasoningEffortEvidence -ResolvedReasoningEffort $resolvedReasoningEffortEvidence -RuntimeReasoningEffort $null
    if ($null -ne $previousRun) {
        $resumeDiagnostics = Compare-ResumeThreadModel -AnchorRecord $previousRun.AnchorRecord -CurrentModelEvidence $resolvedModelEvidence -CodexHome $codexHomeEvidencePath
        if ($resumeDiagnostics.status -ne 'match') {
            $phase = 'preparation'
            throw ($resumeDiagnostics.reason_code + '：Resume model 比對未通過。')
        }
    }
    if ($TaskType -eq 'advisor-consult') {
        if ($dispatchKindValue -ne 'resource') {
            throw 'AdvisorImplementationProfileRejected：advisor-consult 必須使用 DispatchKind=resource。'
        }
        if ($writeModeValue -ne 'readonly') {
            throw 'AdvisorImplementationProfileRejected：advisor-consult 必須使用 read-only 派遣。'
        }
        if ([string]::IsNullOrWhiteSpace($EvidencePackPath)) {
            throw 'RequiredParameterMissing：advisor-consult 必須提供 EvidencePackPath。'
        }
        if ([string]::IsNullOrWhiteSpace($AdvisorConsultReportPath)) {
            throw 'RequiredParameterMissing：advisor-consult 必須提供 AdvisorConsultReportPath。'
        }
        $AdvisorConsultReportPath = Get-AdvisorConsultReportPath -Path $AdvisorConsultReportPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue
        if ([string]::IsNullOrWhiteSpace($QuotaAfterPath)) {
            throw 'RequiredParameterMissing：advisor-consult 必須提供可在執行期間更新的 QuotaAfterPath。'
        }
        $effectiveAddDirectory = @((Get-DispatchJsonProperty -Object $parentOptionsModel -Name 'add_directory'))
        if ($effectiveAddDirectory.Count -gt 0) {
            throw 'AdvisorImplementationProfileRejected：advisor-consult 不允許額外 --add-dir，執行端只可讀取 evidence pack。'
        }
        $evidencePackInfo = Test-AdvisorEvidencePack -Path $EvidencePackPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue
        $evidenceHashPath = Join-Path -Path $historyRoot -ChildPath ('evidence-pack-' + $dispatchSlugValue + '.sha256')
        Write-Utf8NoBom -Path $evidenceHashPath -Content ($evidencePackInfo.sha256 + "`n")
        $evidenceLengthPath = Join-Path -Path $historyRoot -ChildPath ('evidence-pack-' + $dispatchSlugValue + '.length')
        Write-Utf8NoBom -Path $evidenceLengthPath -Content ([string]$evidencePackInfo.length + "`n")
    }
    if ($TaskType -ne 'advisor-consult' -and -not [string]::IsNullOrWhiteSpace($AdvisorConsultReportPath)) {
        throw 'AdvisorConsultReportPath 只適用 TaskType=advisor-consult。'
    }
    if ($TaskType -ne 'advisor-consult' -and -not [string]::IsNullOrWhiteSpace($EvidencePackPath)) {
        throw 'EvidencePackPath 只適用 TaskType=advisor-consult。'
    }

    if ($null -ne $dispatchStageBinding) {
        $beforeSnapshotPathValue = Resolve-AbsolutePath -Path ([string](Get-DispatchJsonProperty -Object $dispatchStageBinding -Name 'quota_before_path'))
        if (-not [string]::Equals($beforeSnapshotPathValue, (Resolve-AbsolutePath -Path $QuotaBeforePath), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'DispatchStageBindingConflict：Start QuotaBeforePath 與 stage binding 不一致。'
        }
        $beforeSnapshotSha256Value = Get-FileSha256 -Path $beforeSnapshotPathValue
        $expectedBeforeSnapshotSha256 = [string](Get-DispatchScriptVariableValue -Name 'DispatchQuotaBeforeSha256')
        if ($expectedBeforeSnapshotSha256 -notmatch '^[a-fA-F0-9]{64}$' -or
            -not [string]::Equals($beforeSnapshotSha256Value, $expectedBeforeSnapshotSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'QuotaBeforeSnapshotHashMismatch：Dispatch 建立的 before quota snapshot SHA-256 與 Start 讀取結果不一致。'
        }
        $beforeSnapshotObject = Read-QuotaSnapshot -Path $beforeSnapshotPathValue
    }
    else {
        $beforeSnapshotPathValue = Get-OrCreateQuotaSnapshot -Path $QuotaBeforePath -CodexHome $effectiveCodexHomePath -HistoryRoot $historyRoot -Purpose 'before' -Required
        $beforeSnapshotObject = Read-QuotaSnapshot -Path $beforeSnapshotPathValue
        $beforeSnapshotSha256Value = Get-FileSha256 -Path $beforeSnapshotPathValue
    }
    $beforeSnapshotCapturedAtUtcValue = [string](Get-DispatchJsonProperty -Object $beforeSnapshotObject -Name 'captured_at_utc')
    if ([string]::IsNullOrWhiteSpace($beforeSnapshotCapturedAtUtcValue)) {
        $beforeSnapshotCapturedAtUtcValue = $null
    }
    $beforeSnapshotFreshnessValue = Get-QuotaSnapshotFreshness -Snapshot $beforeSnapshotObject
    $beforeSnapshotObservationsValue = Get-DispatchJsonProperty -Object $beforeSnapshotObject -Name 'observations'
    $beforeSnapshotServiceRejectionValue = Get-QuotaSnapshotServiceRejection -Snapshot $beforeSnapshotObject
    $calibrationPathValue = $CalibrationPath
    if ([string]::IsNullOrWhiteSpace($calibrationPathValue)) {
        $calibrationPathValue = Join-Path -Path $sourceRootPath -ChildPath '.local\ai-sessions\history\quota-calibration.jsonl'
    }
    if ($TaskType -eq 'advisor-consult') {
        $afterSnapshot = New-AdvisorAfterSnapshot -CallerPath $QuotaAfterPath -ExecutionRoot $executionRootPath -HistoryRoot $historyRoot -CodexHome $effectiveCodexHomePath
        $afterSnapshotPathValue = [string]$afterSnapshot.Path
        $afterSnapshotSha256Value = [string]$afterSnapshot.Sha256
    }
    if ($TaskType -eq 'advisor-consult') {
        $advisorCalibration = Get-CalibrationEstimate -Path $calibrationPathValue -ModelEvidence $resolvedModelEvidence -ReasoningEffortEvidence $resolvedReasoningEffortEvidence -Model $resolvedModelValue -Profile $requestedProfileValue -SessionMode $sessionModeValue -TaskType $TaskType
        $advisorEstimate = if ($null -ne $advisorCalibration.estimate) { [double]$advisorCalibration.estimate } else { [double](Get-ConservativeEstimate -TaskType $TaskType) }
        $advisorActivationDecision = Get-AdvisorActivationDecision -QuotaSnapshot $beforeSnapshotObject -State ([string](Get-DispatchJsonProperty -Object $beforeSnapshotObject -Name 'state')) -EstimatePercent $advisorEstimate -RequestSource $AdvisorRequestSource -HasFreshObservations ($beforeSnapshotFreshnessValue -eq 'fresh' -and (Test-QuotaSnapshotHasObservations -Snapshot $beforeSnapshotObject)) -ServiceRejected ($null -ne $beforeSnapshotServiceRejectionValue)
        $activationModeValue = [string](Get-OptionalObjectProperty -Object $advisorActivationDecision -Name 'activationMode')
        if ([string]::IsNullOrWhiteSpace($activationModeValue)) {
            $activationModeValue = 'none'
        }
        $authorizationSourceValue = Get-OptionalObjectProperty -Object $advisorActivationDecision -Name 'authorizationSource'
        $primaryRemainingPercentValue = Get-OptionalObjectProperty -Object $advisorActivationDecision -Name 'remainingPercent'
        $requiredSourceValue = Get-OptionalObjectProperty -Object $advisorActivationDecision -Name 'requiredAuthorization'
        if (-not [bool]$advisorActivationDecision.granted) {
            $failureReasonCode = [string]$advisorActivationDecision.reasonCode
            throw ($failureReasonCode + '：' + [string]$advisorActivationDecision.notice + '; process_started=false')
        }
    }
    $unitKindValue = Get-DefaultUnitKind -DispatchKind $dispatchKindValue -UnitKind $UnitKind -TaskType $TaskType
    $units = @(Get-DispatchUnitList -RequestedUnit $RequestedUnit -DispatchKind $dispatchKindValue -UnitKind $unitKindValue -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -EvidencePackPath $EvidencePackPath -EvidenceQuestionUnits $(if ($null -eq $evidencePackInfo) { $null } else { @($evidencePackInfo.question_units) }) -TargetPath $TargetPath)
    $scopePlanPathValue = $ScopePlanPath
    if ($ContinueFromScopePlan -and [string]::IsNullOrWhiteSpace($ResumeThreadId)) {
        throw 'ContinueFromScopePlan 僅允許在存在有效 AnchorRecord 的續行中使用。'
    }
    if ($ContinueFromScopePlan -and -not [string]::Equals($SessionMode, 'continuation', [StringComparison]::Ordinal)) {
        throw 'ContinueFromScopePlan 僅允許在 SessionMode=continuation 時使用。'
    }
    if (-not [string]::IsNullOrWhiteSpace($ResumeThreadId) -and [string]::IsNullOrWhiteSpace($scopePlanPathValue)) {
        throw '續行必須提供既有 ScopePlanPath，禁止重新建立 ScopePlan。'
    }
    if ([string]::IsNullOrWhiteSpace($scopePlanPathValue)) {
        $scopePlanPathValue = Join-Path -Path $historyRoot -ChildPath ('scope-plan-' + $dispatchSlugValue + '-' + $timestamp + '.json')
    }
    else {
        $scopePlanPathValue = Resolve-AbsolutePath -Path $scopePlanPathValue
        if (-not (Test-PathWithinRoot -Path $scopePlanPathValue -Root $executionRootPath)) {
            throw "ScopePlanPath 必須位於 executionRoot 內：$scopePlanPathValue"
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ResumeThreadId)) {
        $anchorScopePlanPath = [string](Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'scope_plan_path')
        $anchorScopePlanSha256 = [string](Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'scope_plan_sha256')
        if ([string]::IsNullOrWhiteSpace($anchorScopePlanPath) -or [string]::IsNullOrWhiteSpace($anchorScopePlanSha256)) {
            throw '續行 AnchorRecord 缺少 ScopePlan 路徑或 SHA-256。'
        }
        $anchorScopePlanPath = Resolve-AbsolutePath -Path $anchorScopePlanPath
        if (-not (Test-PathWithinRoot -Path $anchorScopePlanPath -Root $executionRootPath)) {
            throw "AnchorRecord ScopePlan 必須位於 executionRoot 內：$anchorScopePlanPath"
        }
        $anchorScopePlanCurrentSha256 = Get-FileSha256 -Path $anchorScopePlanPath
        if (-not [string]::Equals($anchorScopePlanPath, $scopePlanPathValue, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($anchorScopePlanSha256, $anchorScopePlanCurrentSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw '續行 ScopePlan 與前輪 RunRecord 不一致。'
        }
        $anchorScopePlanRootRunId = [string](Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'scope_plan_root_run_id')
        $witnessScopePlanPath = $anchorScopePlanPath
        $rootScopePlanRecord = Get-DispatchJsonProperty -Object $previousRun -Name 'ScopePlanRootRecord'
        if ($null -ne $rootScopePlanRecord -and -not [string]::IsNullOrWhiteSpace([string](Get-DispatchJsonProperty -Object $rootScopePlanRecord -Name 'scope_plan_path'))) {
            $witnessScopePlanPath = Resolve-AbsolutePath -Path ([string](Get-DispatchJsonProperty -Object $rootScopePlanRecord -Name 'scope_plan_path'))
        }
        if (-not [string]::IsNullOrWhiteSpace($anchorScopePlanRootRunId) -and
            $null -ne $rootScopePlanRecord -and
            -not [string]::Equals([string](Get-DispatchJsonProperty -Object $rootScopePlanRecord -Name 'run_id'), $anchorScopePlanRootRunId, [StringComparison]::OrdinalIgnoreCase)) {
            throw '續行 ScopePlan root run 與 AnchorRecord 不一致。'
        }
        $hashRecordParameters = @{
            SourceHistoryRoot = $sourceHistoryRoot
            DispatchSlug      = $dispatchSlugValue
            LineSlug          = $lineSlugValue
            ScopePlanPath     = $witnessScopePlanPath
        }
        if (-not [string]::IsNullOrWhiteSpace($anchorScopePlanRootRunId)) {
            $hashRecordParameters.ExpectedRootRunId = $anchorScopePlanRootRunId
        }
        $null = Test-ScopePlanHashRecord @hashRecordParameters
        $existingScopePlan = Read-ScopePlanFile -Path $anchorScopePlanPath
        if ($ContinueFromScopePlan) {
            if (-not [string]::Equals($SessionMode, 'continuation', [StringComparison]::Ordinal)) {
                throw 'ContinueFromScopePlan 僅允許在 SessionMode=continuation 時使用。'
            }
            if (-not (Test-ContinuationScopePlan -ScopePlan $existingScopePlan -DispatchSlug $dispatchSlugValue -DispatchKind $dispatchKindValue -TaskType $TaskType -RequestedProfile $requestedProfileValue -UnitKind $unitKindValue -Units @($existingScopePlan.requested_units))) {
                throw '續行的父 ScopePlan 不存在、欄位不完整或與目前派工契約不一致。'
            }
            $scopePlanParentPathValue = $anchorScopePlanPath
            $scopePlanParentSha256Value = $anchorScopePlanSha256
            $scopePlanParentRunIdValue = [string](Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'run_id')
            $scopePlanRootRunIdValue = if ([string]::IsNullOrWhiteSpace($anchorScopePlanRootRunId)) { $scopePlanParentRunIdValue } else { $anchorScopePlanRootRunId }
            $scopePlanSelectionValue = 'subset'
            $scopePlanPathValue = Join-Path -Path $historyRoot -ChildPath ('scope-plan-' + $dispatchSlugValue + '-' + $runId + '-subset.json')
            $scopePlan = New-ContinuationScopePlanSubset -ParentScopePlan $existingScopePlan -RequestedUnits $units -ParentScopePlanPath $anchorScopePlanPath -ParentScopePlanSha256 $anchorScopePlanSha256 -ParentRunId $scopePlanParentRunIdValue
            Write-Utf8NoBom -Path $scopePlanPathValue -Content (($scopePlan | ConvertTo-Json -Depth 30) + "`n")
        }
        else {
            if (-not (Test-ContinuationScopePlan -ScopePlan $existingScopePlan -DispatchSlug $dispatchSlugValue -DispatchKind $dispatchKindValue -TaskType $TaskType -RequestedProfile $requestedProfileValue -UnitKind $unitKindValue -Units $units)) {
                throw '續行的 ScopePlan 不存在、欄位不完整或與目前派工契約不一致。'
            }
            $scopePlan = $existingScopePlan
            $scopePlanParentPathValue = Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'scope_plan_parent_path'
            $scopePlanParentSha256Value = Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'scope_plan_parent_sha256'
            $scopePlanParentRunIdValue = Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'scope_plan_parent_run_id'
            if ([string]::IsNullOrWhiteSpace([string]$scopePlanParentPathValue)) {
                $scopePlanParentPathValue = $null
            }
            if ([string]::IsNullOrWhiteSpace([string]$scopePlanParentSha256Value)) {
                $scopePlanParentSha256Value = $null
            }
            if ([string]::IsNullOrWhiteSpace([string]$scopePlanParentRunIdValue)) {
                $scopePlanParentRunIdValue = $null
            }
            $scopePlanRootRunIdValue = if ([string]::IsNullOrWhiteSpace($anchorScopePlanRootRunId)) { [string](Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'run_id') } else { $anchorScopePlanRootRunId }
            $scopePlanSelectionValue = [string](Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'scope_plan_selection')
            if ([string]::IsNullOrWhiteSpace($scopePlanSelectionValue)) {
                $scopePlanSelectionValue = 'root'
            }
        }
    }
    else {
        $scopePlan = New-ScopePlan -DispatchSlug $dispatchSlugValue -DispatchKind $dispatchKindValue -TaskType $TaskType -RequestedProfile $requestedProfileValue -SessionMode $sessionModeValue -BeforeSnapshot (Read-QuotaSnapshot -Path $beforeSnapshotPathValue) -CalibrationPath $calibrationPathValue -Units $units -UnitKind $unitKindValue -RequestedBudgetPercent $PrimaryBudgetPercent -RequestedReservePercent $PrimaryReservePercent -Model $resolvedModelValue -ModelEvidence $resolvedModelEvidence -ReasoningEffortEvidence $resolvedReasoningEffortEvidence -ActivationDecision $advisorActivationDecision
        $scopePlan.scope_plan_fingerprint = Get-ScopePlanFingerprint -ScopePlan $scopePlan
        Write-Utf8NoBom -Path $scopePlanPathValue -Content (($scopePlan | ConvertTo-Json -Depth 20) + "`n")
        $scopePlanRootRunIdValue = $runId
        if ($null -ne $latestColdStartFailure) {
            $inheritedRootRunId = [string](Get-DispatchJsonProperty -Object $latestColdStartFailure -Name 'scope_plan_root_run_id')
            if ([string]::IsNullOrWhiteSpace($inheritedRootRunId)) {
                $inheritedRootRunId = [string](Get-DispatchJsonProperty -Object $latestColdStartFailure -Name 'run_id')
            }
            if ([string]::IsNullOrWhiteSpace($inheritedRootRunId)) {
                $phase = 'preparation'
                throw 'ScopePlanRootRunIdMissing：同 slug cold-start 重試缺少可沿用的 root run id。'
            }
            $scopePlanRootRunIdValue = $inheritedRootRunId
        }
        $scopePlanSelectionValue = 'root'
        $null = Write-ScopePlanHashRecordIfMissing -SourceHistoryRoot $sourceHistoryRoot -DispatchSlug $dispatchSlugValue -LineSlug $lineSlugValue -ScopePlanPath $scopePlanPathValue -RootRunId $scopePlanRootRunIdValue
    }
    if ($scopePlan.decision -eq 'blocked-no-estimate' -or $scopePlan.decision -eq 'blocked-insufficient-budget' -or $scopePlan.decision -eq 'blocked-no-fresh-quota' -or $scopePlan.decision -eq 'user-decision-required') {
        throw "ScopePlan 阻擋派工：decision=$($scopePlan.decision); reason=$($scopePlan.decision_reason)"
    }
    if ($TaskType -eq 'advisor-consult') {
        if ([string]::IsNullOrWhiteSpace($monitorPathValue)) {
            $monitorPathValue = Join-Path -Path $historyRoot -ChildPath ('quota-monitor-' + $dispatchSlugValue + '-' + $timestamp + '.jsonl')
        }
        else {
            $monitorPathValue = Resolve-AbsolutePath -Path $monitorPathValue
            if (-not (Test-PathWithinRoot -Path $monitorPathValue -Root $executionRootPath)) {
                throw "BudgetMonitorPath 必須位於 executionRoot 內：$monitorPathValue"
            }
        }
    }

    if ($null -eq $advisorActivationDecision) {
        $advisorActivationDecision = [ordered]@{
            activationMode      = 'none'
            granted              = $false
            authorizationSource  = $null
            notice               = ''
        }
    }

    $promptDirectives = New-Object System.Collections.Generic.List[string]
    $promptDirectives.Add(
        '[中斷保全]' + [Environment]::NewLine +
        '本次工作必須可在任意中斷點交付已確認結果。開始主要探索前，先寫出目前已確認的結論、證據位置與尚未確認項目。每完成一個範圍單位，更新一次「已確認結論」與「實際覆蓋範圍」。收到中止要求時，先保存已確認結論、證據位置、未完成單位與不應推論的內容，再結束本次工作。不得以未執行的單位補寫結論。' + [Environment]::NewLine +
        '結案訊息一律以下列三行結尾，中止與正常完成都適用，讓後續續行取得交接資料。每行為單行鍵值對，值不得為空；沒有未完成單位時填「無」。' + [Environment]::NewLine +
        '已確認結論：<一句話>' + [Environment]::NewLine +
        '未完成單位：<清單或「無」>' + [Environment]::NewLine +
        '證據位置：<絕對路徑或檔案:行號>'
    )
    $promptDirectives.Add(('[ScopePlan]' + [Environment]::NewLine + ($scopePlan | ConvertTo-Json -Depth 20)))
    if (-not [string]::IsNullOrWhiteSpace($ResumeThreadId)) {
        $promptDirectives.Add(
            '[續行交接資料]' + [Environment]::NewLine +
            ('前輪 last-message 路徑：' + $continuationContextPath + [Environment]::NewLine) +
            '前輪已確認結論、未完成單位與證據位置如下，必須沿用且不得重建 ScopePlan：' + [Environment]::NewLine +
            $continuationContextMessage.Trim()
        )
    }
    if ($TaskType -eq 'advisor-consult') {
        $promptDirectives.Add((New-AdvisorInlineEvidenceDirective -EvidencePackInfo $evidencePackInfo))
    }
    $promptPathValue = New-DispatchPrompt -PromptPath $promptTransferPathValue -HistoryRoot $historyRoot -Timestamp $timestamp -Directive @($promptDirectives.ToArray()) -OutputPath $promptPathValue
    if (-not (Test-PathWithinRoot -Path $promptPathValue -Root $executionRootPath)) {
        throw ('PromptPath 必須位於 executionRoot 內；received=' + $promptPathValue + '; executionRoot=' + $executionRootPath)
    }
    if ($TaskType -eq 'advisor-consult') {
        $promptContentForVerification = Read-DispatchUtf8Text -Path $promptPathValue
        $inlineGate = Test-AdvisorInlineEvidenceDirective -PromptContent $promptContentForVerification -EvidencePackInfo $evidencePackInfo
        if (-not $inlineGate.valid) {
            $phase = 'evidence-pack-inline'
            throw ('EvidencePackInlineMismatch：' + $inlineGate.reason)
        }
    }

    $codexArguments = New-Object System.Collections.Generic.List[string]
    $codexArguments.Add('--cd')
    $codexWorkingRoot = $executionRootPath
    if ($null -ne $evidencePackInfo) {
        $codexWorkingRoot = Split-Path -Parent $evidencePackInfo.sandboxPath
    }
    $codexArguments.Add($codexWorkingRoot)
    $codexArguments.Add('--sandbox')
    $codexArguments.Add($(if ($TaskType -eq 'advisor-consult') { 'read-only' } else { 'workspace-write' }))
    $codexArguments.Add('--profile')
    $codexArguments.Add($effectiveProfileValue)
    $effectiveAddDirectory = @((Get-DispatchJsonProperty -Object $parentOptionsModel -Name 'add_directory'))
    foreach ($directory in $effectiveAddDirectory) {
            $directoryPath = Resolve-AbsolutePath -Path $directory
            if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) {
                throw "--add-dir 目錄不存在：$directoryPath"
            }
            $codexArguments.Add('--add-dir')
            $codexArguments.Add($directoryPath)
    }
    $effectiveSearch = [bool](Get-DispatchJsonProperty -Object $parentOptionsModel -Name 'search')
    if ($effectiveSearch) {
        $codexArguments.Add('--search')
    }
    $effectiveCodexParentOption = @((Get-DispatchJsonProperty -Object $parentOptionsModel -Name 'codex_parent_option'))
    foreach ($option in $effectiveCodexParentOption) {
            if ([string]::IsNullOrWhiteSpace($option)) {
                throw 'CodexParentOption 不可包含空白選項。'
            }
            $codexArguments.Add($option)
    }
    $codexArguments.Add('exec')
    if (-not [string]::IsNullOrWhiteSpace($ResumeThreadId)) {
        $codexArguments.Add('resume')
        $codexArguments.Add($ResumeThreadId)
    }
    $codexArguments.Add('--json')
    $codexArguments.Add('--output-last-message')
    $codexArguments.Add($lastMessagePathValue)
    $codexArguments.Add('-')

    if ($null -ne $previousRun) {
        $profileConfigSha256AfterCompare = $null
        if ([string]::IsNullOrWhiteSpace($profileConfigPathValue) -or -not (Test-Path -LiteralPath $profileConfigPathValue -PathType Leaf)) {
            $phase = 'preparation'
            throw 'ProfileEvidenceUnknown：Resume compare 後找不到 Profile 設定檔，無法重新確認 SHA-256。'
        }
        try {
            $profileConfigSha256AfterCompare = Get-FileSha256 -Path $profileConfigPathValue
        }
        catch {
            $phase = 'preparation'
            throw ('ProfileEvidenceUnknown：Resume compare 後無法重新計算 Profile 設定檔 SHA-256：' + $_.Exception.Message)
        }
        if ([string]::IsNullOrWhiteSpace($profileConfigSha256AtCompare) -or -not [string]::Equals($profileConfigSha256AtCompare, $profileConfigSha256AfterCompare, [StringComparison]::OrdinalIgnoreCase)) {
            $phase = 'preparation'
            throw ('ProfileEvidenceUnknown：Resume compare 後 Profile 設定檔已變更；compare-sha256={0}; current-sha256={1}' -f $profileConfigSha256AtCompare, $profileConfigSha256AfterCompare)
        }
    }

    $launcher = New-CodexLauncher -CodexExecutable $codexExecutable -CodexArguments @($codexArguments.ToArray()) -PromptPath $promptPathValue -EventPath $eventPath -ErrorPath $errorPath -HistoryRoot $historyRoot -LauncherPath $launcherPath -ExitSidecarPath $exitSidecarPathValue -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -RunId $runId
    $launcherPath = $launcher.Path
    $startInfo = New-ProcessStartInfo -FileName $launcher.FileName -WorkingDirectory $executionRootPath -Arguments @($launcher.Arguments)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $startedSnapshot = $null
    $processStarted = $false
    if (-not [string]::Equals($sourceRootPath, $executionRootPath, [StringComparison]::OrdinalIgnoreCase)) {
        if ($null -eq $baselineBinding) {
            throw 'BaselineUnknown：worktree Start 缺少已驗證 Baseline。'
        }
        if ($null -ne $previousRun -and (-not [string]::Equals($previousRun.AnchorRecord.baseline_path, $baselineBinding.Path, [StringComparison]::OrdinalIgnoreCase) -or $previousRun.AnchorRecord.baseline_sha256 -ine $baselineBinding.Sha256)) { throw 'Resume 必須沿用前輪 Baseline。' }
    }
    $runRecord.scope_plan_path = $scopePlanPathValue
    $runRecord.scope_plan_sha256 = Get-FileSha256 -Path $scopePlanPathValue
    $runRecord.scope_plan_parent_path = $scopePlanParentPathValue
    $runRecord.scope_plan_parent_sha256 = $scopePlanParentSha256Value
    $runRecord.scope_plan_parent_run_id = $scopePlanParentRunIdValue
    $runRecord.scope_plan_root_run_id = if ([string]::IsNullOrWhiteSpace($scopePlanRootRunIdValue)) { $runId } else { $scopePlanRootRunIdValue }
    $runRecord.scope_plan_selection = $scopePlanSelectionValue
    $runRecord.model_evidence = $modelEvidence.model
    $runRecord.reasoning_effort_evidence = $modelEvidence.reasoning_effort
    $runRecord.profile_config_path = $profileConfigPathValue
    $runRecord.codex_home = $codexHomeEvidencePath
    $runRecord.effective_codex_home = $effectiveCodexHomePath
    $runRecord.prepare_result_path = $prepareResultPathValue
    $runRecord.prepare_result_sha256 = $prepareResultSha256Value
    $runRecord.prepare_status = $prepareStatusValue
    $runRecord.parent_options = $parentOptionsModel
    $runRecord.parent_options_sha256 = $parentOptionsModel.fingerprint
    $runRecord.parent_options_status = 'confirmed'
    $runRecord.acl_gate = $aclGate
    $runRecord.sandbox_acl_baseline = $sandboxAclBaseline
    $runRecord.sandbox_acl_evidence = $sandboxAclEvidence
    $runRecord.quota_before_path = $beforeSnapshotPathValue
    $runRecord.quota_before_sha256 = $beforeSnapshotSha256Value
    $runRecord.quota_before_captured_at_utc = $beforeSnapshotCapturedAtUtcValue
    $runRecord.quota_before_freshness = $beforeSnapshotFreshnessValue
    $runRecord.quota_before_observations = $beforeSnapshotObservationsValue
    $runRecord.quota_before_service_rejection = $beforeSnapshotServiceRejectionValue
    $runRecord.quota_after_path = $afterSnapshotPathValue
    $runRecord.quota_after_sha256 = $afterSnapshotSha256Value
    $runRecord.evidence_pack_path = if ($null -eq $evidencePackInfo) { $null } else { $evidencePackInfo.path }
    $runRecord.evidence_pack_sha256 = if ($null -eq $evidencePackInfo) { $null } else { $evidencePackInfo.sha256 }
    $runRecord.evidence_pack_length = if ($null -eq $evidencePackInfo) { $null } else { [int64]$evidencePackInfo.length }
    $runRecord.advisor_request_source = $AdvisorRequestSource
    $runRecord.advisor_activation_decision = if ($null -eq $advisorActivationDecision) { $null } else { Get-OptionalObjectProperty -Object $advisorActivationDecision -Name 'activationMode' }
    $runRecord.advisor_activation_granted = if ($null -eq $advisorActivationDecision) { $false } else { [bool](Get-OptionalObjectProperty -Object $advisorActivationDecision -Name 'granted') }
    $runRecord.advisor_activation_notice = if ($null -eq $advisorActivationDecision) { $null } else { Get-OptionalObjectProperty -Object $advisorActivationDecision -Name 'notice' }
    $runRecord.advisor_hard_limit_percent = if ($null -eq $advisorActivationDecision) { $null } else { Get-OptionalObjectProperty -Object $advisorActivationDecision -Name 'hardLimitPercent' }
    $runRecord.advisor_unit_estimate_percent = if ($null -eq $scopePlan) { $null } else { Get-OptionalObjectProperty -Object $scopePlan -Name 'advisor_unit_estimate_percent' }
    $runRecord.activationMode = $activationModeValue
    $runRecord.authorizationSource = $authorizationSourceValue
    $runRecord.primaryRemainingPercent = $primaryRemainingPercentValue
    $runRecord.requiredSource = $requiredSourceValue
    $runRecord.resume_diagnostics = $resumeDiagnostics
    $runRecord.attempt_parent_run_id = $attemptParentRunIdValue
    $runRecord.resume_anchor_run_id = $resumeAnchorRunIdValue
    $runRecord.skipped_attempts = @($skippedAttemptsValue)
    $runRecord.baseline_path = if ($null -ne $baselineBinding) { $baselineBinding.Path } else { $null }
    $runRecord.baseline_sha256 = if ($null -ne $baselineBinding) { $baselineBinding.Sha256 } else { $null }
    $runRecord.baseline_resolution = $baselineResolution
    if ($isWorktreeStart) {
        try {
            $sandboxAclBaseline = Get-ExplicitAclSnapshot -Path $executionRootPath
        }
        catch {
            $sandboxAclBaseline = [ordered]@{
                status = 'failed'
                path = $executionRootPath
                fingerprint = $null
                explicit_entries = @()
                error = $_.Exception.Message
            }
        }
        $runRecord.sandbox_acl_baseline = $sandboxAclBaseline
        if ($sandboxAclBaseline.status -eq 'unknown') {
            $failureReasonCode = 'WorktreeAclUnknown'
            throw ('WorktreeAclUnknown：Start spawn 前無法取得 sandbox ACL baseline：' + [string]$sandboxAclBaseline.error)
        }
        if ($sandboxAclBaseline.status -eq 'failed') {
            $failureReasonCode = 'WorktreeAclReadFailed'
            throw ('WorktreeAclReadFailed：Start spawn 前讀取 sandbox ACL baseline 失敗：' + [string]$sandboxAclBaseline.error)
        }
    if ($sandboxAclBaseline.status -ne 'known') {
            $failureReasonCode = 'WorktreeAclReadFailed'
            throw 'WorktreeAclReadFailed：Start spawn 前 sandbox ACL baseline 狀態無法驗證。'
        }
        $sandboxAclEvidence = New-SandboxAclEvidenceDocument -Entries @() -CaptureStatus 'pending' -NormalCompletion $false -ContinuationAllowed $false
        $runRecord.sandbox_acl_evidence = $sandboxAclEvidence
    }
    $runRecord.prompt_path = $promptPathValue
    $runRecord.prompt_source_path = $promptSourcePathValue
    $runRecord.prompt_source_sha256 = $promptSourceSha256Value
    $runRecord.prompt_transfer_path = $promptTransferPathValue
    $runRecord.prompt_transfer_sha256 = $promptTransferSha256Value
    $runRecord.inspect_result_path = $inspectResultPathValue
    $null = Write-DispatchRunRecord -Record $runRecord -Update
    $null = Read-DispatchRunRecord -Path $runRecordPathValue -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue
        if (-not $process.Start()) {
            throw 'Codex 啟動失敗。'
        }
        $processStarted = $true
        try {
            $startedSnapshot = Get-StartedProcessSnapshot -ProcessId $process.Id
        }
        catch {
            $startedSnapshotError = $_.Exception.Message
            $startedSnapshot = $null
        }
        Write-StartPidRecord -Path $pidPath -ProcessId $process.Id -SourceRoot $sourceRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -WriteMode $writeModeValue -Snapshot $startedSnapshot
        if (-not [string]::IsNullOrWhiteSpace($startedSnapshotError)) {
            $phase = 'identity-unverified'
            throw "無法取得 Codex 根程序身分，PID $($process.Id) snapshot 查詢失敗：$startedSnapshotError"
        }
        if ($null -eq $startedSnapshot) {
            $phase = 'identity-unverified'
            throw "無法取得 Codex 根程序身分，PID $($process.Id) 未通過驗證。"
        }
        if ($startedSnapshot.IdentityStatus -ne 'confirmed' -or $startedSnapshot.IdentityVerified -ne $true) {
            $phase = 'identity-unverified'
            throw "Codex 根程序身分無法確認，拒絕以未驗證程序收尾：PID $($process.Id); identity-status=$($startedSnapshot.IdentityStatus); failure-fields=$($startedSnapshot.IdentityFailureFields -join ','); missing-fields=$($startedSnapshot.IdentityMissingFields -join ',')"
        }
        if (-not (Test-IsWindowsPlatform)) {
            if ($null -eq $startedSnapshot.PSObject.Properties['ProcessGroupId'] -or $startedSnapshot.ProcessGroupId -le 0) {
                $phase = 'identity-unverified'
                throw "無法取得 Codex 根程序的 process group，PID $($process.Id) 未通過驗證。"
            }
        }
        $startedAtUtcValue = [datetime]::UtcNow.ToString('o')
        $runRecord.started_at_utc = $startedAtUtcValue

        $relay = Wait-ForThreadRelay -EventPath $eventPath -ThreadPath $threadPath -TimeoutSeconds 5
        $relayReady = [bool](Get-DispatchJsonProperty -Object $relay -Name 'ready')
        if (-not $relayReady) {
            if ([string]::IsNullOrWhiteSpace($ResumeThreadId)) {
                $phase = 'thread-relay-not-ready'
                throw ('thread relay not-ready：逾時 {0} 秒仍未取得本次 launch 的 thread.started；保留事件流與 relay 證據。' -f $relay.timeoutSeconds)
            }
            $runRecord.thread_id = $ResumeThreadId
        }
        else {
            if ([string]::IsNullOrWhiteSpace($relay.threadId)) {
                $phase = 'thread-relay-not-ready'
                throw 'thread relay not-ready：本次 launch relay 標記 ready 但未提供 threadId。'
            }
            if (-not [string]::IsNullOrWhiteSpace($ResumeThreadId) -and $relay.threadId -cne $ResumeThreadId) {
                throw 'thread relay 與 ResumeThreadId 不一致。'
            }
            $runRecord.thread_id = $relay.threadId
            $null = Get-DispatchRunEvents $runRecord
        }
        $runRecord.launch_state = 'started'
        $runRecord.prompt_path = $promptPathValue
        $runRecord.prompt_source_path = $promptSourcePathValue
        $runRecord.prompt_source_sha256 = $promptSourceSha256Value
        $runRecord.prompt_transfer_path = $promptTransferPathValue
        $runRecord.prompt_transfer_sha256 = $promptTransferSha256Value
        $runRecord.inspect_result_path = $inspectResultPathValue
        $null = Write-DispatchRunRecord -Record $runRecord -Update
        $inspectResult = Write-DispatchInspectResultBinding -Path $inspectResultPathValue -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -ProcessStarted $true -RunRecordPath $runRecordPathValue -EventStreamPath $eventPath -ScopePlanPath $scopePlanPathValue -QuotaBeforePath $beforeSnapshotPathValue -QuotaBeforeSha256 $beforeSnapshotSha256Value -ProcessExitCodeSidecarPath $exitSidecarPathValue
        $inspectResultPathValue = $inspectResult.Path
        $budgetMonitorStatus.state = 'running'
        if ($TaskType -eq 'advisor-consult') {
            $budgetMonitorStatus = Invoke-AdvisorBudgetMonitor -Process $process -StartedSnapshot $startedSnapshot -EventPath $eventPath -MonitorPath $monitorPathValue -BeforeSnapshot $beforeSnapshotObject -AfterSnapshotPath (Resolve-AbsolutePath -Path $afterSnapshotPathValue) -AfterSnapshotSha256 $afterSnapshotSha256Value -CodexHome $CodexHome -PrimaryBudgetPercent ([double]$scopePlan.primary_budget_percent) -AbortGraceSeconds $AbortGraceSeconds
            $afterSnapshotSha256Value = [string]$budgetMonitorStatus.afterSnapshotSha256
            $runRecord.quota_after_path = $afterSnapshotPathValue
            $runRecord.quota_after_sha256 = $afterSnapshotSha256Value
            $null = Write-DispatchRunRecord -Record $runRecord -Update
            if ($budgetMonitorStatus.state -eq 'AbortedByBudget') {
                $phase = 'aborted-by-budget'
                throw "advisor-consult 已由 BudgetMonitor 中止：$($budgetMonitorStatus.state)"
            }
            if ($budgetMonitorStatus.state -eq 'IdentityUnverified') {
                $skipProcessCleanup = $true
                $phase = 'identity-unverified'
                throw 'advisor-consult BudgetMonitor 無法確認進程身分，保留未清理證據且不再終止程序。'
            }
            if ($budgetMonitorStatus.state -eq 'CrossReset') {
                $phase = 'cross-reset'
                throw 'advisor-consult BudgetMonitor 偵測到 primary reset window 變更，停止監看並拒絕校準。'
            }
            if ($budgetMonitorStatus.state -eq 'SnapshotFailed') {
                throw 'advisor-consult BudgetMonitor 無法取得有效 after quota snapshot。'
            }
        }
        $phase = 'started'

        return [ordered]@{
            operation        = 'Start'
            processStarted   = $true
            runId            = $runId
            runRecordPath    = $runRecordPathValue
            sourceRoot       = $sourceRootPath
            executionRoot    = $executionRootPath
            lineSlug         = $lineSlugValue
            dispatchSlug     = $dispatchSlugValue
            requestedProfile = $requestedProfileValue
            profile          = $effectiveProfileValue
            profileDowngraded = $false
            interruptionSafeguardApplied = $interruptionSafeguardApplied
            downgradeInstructionApplied = $interruptionSafeguardApplied
            model            = $resolvedModelValue
            reasoningEffort  = $resolvedReasoningEffortValue
            requestedModel   = $requestedModelEvidence
            requestedReasoningEffort = $requestedReasoningEffortEvidence
            resolvedModel    = $resolvedModelEvidence
            resolvedReasoningEffort = $resolvedReasoningEffortEvidence
            modelEvidence    = $modelEvidence
            reasoningEffortEvidence = $modelEvidence.reasoning_effort
            taskType         = $TaskType
            sessionMode      = $sessionModeValue
            advisorRequestSource       = $AdvisorRequestSource
            advisorActivationDecision = $advisorActivationDecision.activationMode
            advisorActivationGranted  = $advisorActivationDecision.granted
            advisorActivationNotice   = $advisorActivationDecision.notice
            activationMode    = $activationModeValue
            authorizationSource = $authorizationSourceValue
            primaryRemainingPercent = $primaryRemainingPercentValue
            requiredSource    = $requiredSourceValue
            resumeThreadId   = $ResumeThreadId
            rootPid          = $process.Id
            pidRecordPath    = $pidPath
            eventStreamPath  = $eventPath
            stderrPath       = $errorPath
             errorStreamPath  = $errorPath
             lastMessagePath  = $lastMessagePathValue
             promptPath       = $promptPathValue
             promptSourcePath = $promptSourcePathValue
             promptSourceSha256 = $promptSourceSha256Value
             promptTransferPath = $promptTransferPathValue
             promptTransferSha256 = $promptTransferSha256Value
             inspectResultPath = $inspectResultPathValue
             threadIdPath     = $threadPath
             threadId         = $runRecord.thread_id
             threadRelay      = $relay
             relayDiagnostics = Get-DispatchJsonProperty -Object $relay -Name 'relay_diagnostics'
             relayReady       = $relayReady
             scopePlanPath    = $scopePlanPathValue
             scopePlan         = $scopePlan
             prepareResultPath  = $prepareResultPathValue
             prepareResultSha256 = $prepareResultSha256Value
             prepareStatus       = $prepareStatusValue
             quotaBeforePath  = $beforeSnapshotPathValue
            quotaAfterPath   = $afterSnapshotPathValue
            quotaAfterSha256 = $afterSnapshotSha256Value
            evidencePackPath = if ($null -eq $evidencePackInfo) { $null } else { $evidencePackInfo.path }
            evidencePackSandboxPath = if ($null -eq $evidencePackInfo) { $null } else { $evidencePackInfo.sandboxPath }
            evidencePackSha256 = if ($null -eq $evidencePackInfo) { $null } else { $evidencePackInfo.sha256 }
            evidencePackLength = if ($null -eq $evidencePackInfo) { $null } else { [int64]$evidencePackInfo.length }
            profileConfigPath = $profileConfigPathValue
            codexHome = $codexHomeEvidencePath
            effectiveCodexHome = $effectiveCodexHomePath
            parentOptions = $parentOptionsModel
            parentOptionsSha256 = if ($null -eq $parentOptionsModel) { $null } else { $parentOptionsModel.fingerprint }
            aclGate = $aclGate
            sandboxAclEvidence = $sandboxAclEvidence
            startedAtUtc = $startedAtUtcValue
            resumeDiagnostics = $resumeDiagnostics
            budgetMonitorPath = $monitorPathValue
             budgetMonitor     = $budgetMonitorStatus
             quotaBeforeSha256 = $beforeSnapshotSha256Value
             quotaBeforeCapturedAtUtc = $beforeSnapshotCapturedAtUtcValue
             quotaBeforeFreshness = $beforeSnapshotFreshnessValue
             quotaBeforeObservations = $beforeSnapshotObservationsValue
             quotaBeforeServiceRejection = $beforeSnapshotServiceRejectionValue
            launcherPath     = $launcher.Path
            processExitCodeSidecarPath = $exitSidecarPathValue
            codexPath        = $codexExecutable
            codexArguments   = @($codexArguments.ToArray())
            processTreeScope = if (Test-IsWindowsPlatform) { 'pid-and-descendants' } else { 'process-group' }
        }
    }
    catch {
        $originalMessage = $_.Exception.Message
        $processExitCodeValue = $null
        if ($null -ne $process) {
            $processExitCodeValue = Get-ProcessExitCodeIfExited -Process $process
        }
        if ($null -ne $startedSnapshot) {
            if ($skipProcessCleanup) {
                $cleanupStatus = 'not-attempted-identity-unverified'
                $cleanupError = '身分驗證例外後保留進程與未清理證據。'
            }
            elseif ($startedSnapshot.IdentityVerified -eq $true) {
                try {
                    $cleanupResult = Stop-VerifiedProcessTree -Snapshot $startedSnapshot
                    $cleanupStatus = $cleanupResult.CleanupStatus
                    $cleanupError = $cleanupResult.ErrorMessage
                }
                catch {
                    $cleanupStatus = 'verified-tree-cleanup-failed'
                    $cleanupError = $_.Exception.Message
                }
            }
            else {
                $cleanupStatus = 'not-attempted-unconfirmed-identity'
            }
        }
        elseif ($processStarted) {
            $cleanupStatus = 'not-attempted-no-identity'
        }
        if ($null -ne $process) {
            $processExitCodeValue = Get-ProcessExitCodeIfExited -Process $process
        }
        if ($processStarted) {
            try {
                $evidencePaths = @($eventPath, $errorPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                Ensure-StartEvidenceFiles -Path @($evidencePaths)
            }
            catch {
                if ([string]::IsNullOrWhiteSpace($cleanupError)) {
                    $cleanupError = '建立 Start 失敗證據檔案失敗：' + $_.Exception.Message
                }
                else {
                    $cleanupError = $cleanupError + '；建立 Start 失敗證據檔案失敗：' + $_.Exception.Message
                }
            }
        }
        $relaySourceValue = $null
        $relayTimedOutValue = $null
        $relayTimeoutSecondsValue = $null
        if ($null -ne $relay) {
            if ($relay -is [System.Collections.IDictionary]) {
                if ($relay.Contains('source')) {
                    $relaySourceValue = [string]$relay['source']
                }
                if ($relay.Contains('timedOut')) {
                    $relayTimedOutValue = [bool]$relay['timedOut']
                }
                if ($relay.Contains('timeoutSeconds')) {
                    $relayTimeoutSecondsValue = [int]$relay['timeoutSeconds']
                }
            }
            else {
                $relaySourceValue = [string](Get-OptionalObjectProperty -Object $relay -Name 'source')
                $relayTimedOutProperty = $relay.PSObject.Properties['timedOut']
                if ($null -ne $relayTimedOutProperty) {
                    $relayTimedOutValue = [bool]$relayTimedOutProperty.Value
                }
                $relayTimeoutSecondsProperty = $relay.PSObject.Properties['timeoutSeconds']
                if ($null -ne $relayTimeoutSecondsProperty) {
                    $relayTimeoutSecondsValue = [int]$relayTimeoutSecondsProperty.Value
                }
            }
        }
        $evidenceMessage = New-StartFailureEvidenceMessage -Phase $phase -EventPath $eventPath -ErrorPath $errorPath -LastMessagePath $lastMessagePathValue -ThreadPath $threadPath -PidPath $pidPath -LauncherPath $launcherPath -ProcessExitCode $processExitCodeValue -CleanupStatus $cleanupStatus -CleanupError $cleanupError -RelaySource $relaySourceValue -RelayTimedOut $relayTimedOutValue -RelayTimeoutSeconds $relayTimeoutSecondsValue
        $failurePhase = $phase
        if (-not $processStarted -and [string]::IsNullOrWhiteSpace([string]$scopePlanPathValue)) {
            $failurePhase = 'preparation'
        }
        $failureObservation = [ordered]@{
            process_started = $processStarted
            process_exit_code = $processExitCodeValue
            cleanup_status = $cleanupStatus
            cleanup_error = $cleanupError
            relay_source = $relaySourceValue
            relay_timed_out = $relayTimedOutValue
            relay_timeout_seconds = $relayTimeoutSecondsValue
            budget_monitor = $budgetMonitorStatus
            failure_stage = $phase
        }
        $failure = New-DispatchFailureRecord -Phase $failurePhase -Message $originalMessage -ReasonCode $failureReasonCode -ProcessStarted $processStarted -ProcessExitCode $processExitCodeValue -EventPath $eventPath -ErrorPath $errorPath -LastMessagePath $lastMessagePathValue -ThreadPath $threadPath -PidPath $pidPath -LauncherPath $launcherPath -RolloutPaths @() -Observation $failureObservation
        $failure.activationMode = $activationModeValue
        $failure.authorizationSource = $authorizationSourceValue
        $failure.primaryRemainingPercent = $primaryRemainingPercentValue
        $failure.requiredSource = $requiredSourceValue
        $recordWriteError = $null
        if ($null -ne $runRecord -and -not [string]::IsNullOrWhiteSpace($runRecordPathValue)) {
            try {
                $runRecord.event_stream_path = $eventPath
                $runRecord.last_message_path = $lastMessagePathValue
                $runRecord.thread_id_path = $threadPath
                $runRecord.launcher_path = $launcherPath
                $runRecord.process_exit_code_sidecar_path = $exitSidecarPathValue
                $runRecord.prompt_path = $promptPathValue
                $runRecord.prompt_source_path = $promptSourcePathValue
                $runRecord.prompt_source_sha256 = $promptSourceSha256Value
                $runRecord.prompt_transfer_path = $promptTransferPathValue
                $runRecord.prompt_transfer_sha256 = $promptTransferSha256Value
                $runRecord.inspect_result_path = $inspectResultPathValue
                $runRecord.pid_record_path = $pidPath
                $runRecord.attempt_parent_run_id = $attemptParentRunIdValue
                $runRecord.resume_anchor_run_id = $resumeAnchorRunIdValue
                $runRecord.skipped_attempts = @($skippedAttemptsValue)
                $runRecord.resume_diagnostics = $resumeDiagnostics
                $runRecord.started_at_utc = $startedAtUtcValue
                if ($null -ne $modelEvidence) {
                    $runRecord.model_evidence = $modelEvidence.model
                    $runRecord.reasoning_effort_evidence = $modelEvidence.reasoning_effort
                }
                if (-not [string]::IsNullOrWhiteSpace($profileConfigPathValue)) { $runRecord.profile_config_path = $profileConfigPathValue }
                if (-not [string]::IsNullOrWhiteSpace($codexHomeEvidencePath)) { $runRecord.codex_home = $codexHomeEvidencePath }
                if (-not [string]::IsNullOrWhiteSpace($effectiveCodexHomePath)) { $runRecord.effective_codex_home = $effectiveCodexHomePath }
                if (-not [string]::IsNullOrWhiteSpace($prepareResultPathValue)) { $runRecord.prepare_result_path = $prepareResultPathValue }
                if (-not [string]::IsNullOrWhiteSpace($prepareResultSha256Value)) { $runRecord.prepare_result_sha256 = $prepareResultSha256Value }
                if (-not [string]::IsNullOrWhiteSpace($prepareStatusValue)) { $runRecord.prepare_status = $prepareStatusValue }
                if ($null -ne $parentOptionsModel) {
                    $runRecord.parent_options = $parentOptionsModel
                    $runRecord.parent_options_sha256 = $parentOptionsModel.fingerprint
                    $runRecord.parent_options_status = 'confirmed'
                }
                if ($null -ne $aclGate) { $runRecord.acl_gate = $aclGate }
                if ($null -ne $sandboxAclBaseline) { $runRecord.sandbox_acl_baseline = $sandboxAclBaseline }
                if ($null -ne $sandboxAclEvidence) { $runRecord.sandbox_acl_evidence = $sandboxAclEvidence }
                if (-not [string]::IsNullOrWhiteSpace($beforeSnapshotPathValue) -and (Test-Path -LiteralPath $beforeSnapshotPathValue -PathType Leaf)) {
                    $runRecord.quota_before_path = $beforeSnapshotPathValue
                    $runRecord.quota_before_sha256 = Get-FileSha256 -Path $beforeSnapshotPathValue
                    $runRecord.quota_before_captured_at_utc = $beforeSnapshotCapturedAtUtcValue
                }
                if ($null -ne $evidencePackInfo) {
                    $runRecord.evidence_pack_path = $evidencePackInfo.path
                    $runRecord.evidence_pack_sha256 = $evidencePackInfo.sha256
                    $runRecord.evidence_pack_length = [int64]$evidencePackInfo.length
                }
                if (-not [string]::IsNullOrWhiteSpace($scopePlanPathValue) -and (Test-Path -LiteralPath $scopePlanPathValue -PathType Leaf)) {
                    $runRecord.scope_plan_path = $scopePlanPathValue
                    $runRecord.scope_plan_sha256 = Get-FileSha256 -Path $scopePlanPathValue
                    $runRecord.scope_plan_parent_path = $scopePlanParentPathValue
                    $runRecord.scope_plan_parent_sha256 = $scopePlanParentSha256Value
                    $runRecord.scope_plan_parent_run_id = $scopePlanParentRunIdValue
                    $runRecord.scope_plan_root_run_id = if ([string]::IsNullOrWhiteSpace($scopePlanRootRunIdValue)) { $runId } else { $scopePlanRootRunIdValue }
                    $runRecord.scope_plan_selection = $scopePlanSelectionValue
                }
                else {
                    $runRecord.scope_plan_path = $null
                    $runRecord.scope_plan_sha256 = $null
                    $runRecord.scope_plan_parent_path = $null
                    $runRecord.scope_plan_parent_sha256 = $null
                    $runRecord.scope_plan_parent_run_id = $null
                    $runRecord.scope_plan_root_run_id = $null
                    $runRecord.scope_plan_selection = 'root'
                }
                if ($null -ne $baselineBinding) {
                    $runRecord.baseline_path = $baselineBinding.Path
                    $runRecord.baseline_sha256 = $baselineBinding.Sha256
                }
                if ($null -ne $baselineResolution) {
                    $runRecord.baseline_resolution = $baselineResolution
                }
                $runRecord.activationMode = $activationModeValue
                $runRecord.authorizationSource = $authorizationSourceValue
                $runRecord.primaryRemainingPercent = $primaryRemainingPercentValue
                $runRecord.requiredSource = $requiredSourceValue
                $runRecord.failure = $failure
                $runRecord.launch_state = 'launch-failed'
                $null = Write-DispatchRunRecord -Record $runRecord -Update
                $null = Read-DispatchRunRecord -Path $runRecordPathValue -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue
            }
            catch {
                $recordWriteError = $_.Exception.Message
                $runRecordPathValue = $null
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($recordWriteError)) {
            $failure.write_error = $recordWriteError
        }
        $failureResult = [ordered]@{
            operation = 'Start'
            runId = $runId
            runRecordPath = $runRecordPathValue
            prepareResultPath = $prepareResultPathValue
            prepareResultSha256 = $prepareResultSha256Value
            prepareStatus = $prepareStatusValue
            effectiveCodexHome = $effectiveCodexHomePath
            success = $false
            outputValid = $false
            processStarted = $processStarted
            processExitCode = $processExitCodeValue
            errorCode = $failure.reason_code
            error = $originalMessage
            activationMode = $activationModeValue
            authorizationSource = $authorizationSourceValue
            primaryRemainingPercent = $primaryRemainingPercentValue
            requiredSource = $requiredSourceValue
            failure = $failure
            modelEvidence = if ($null -eq $modelEvidence) { $null } else { $modelEvidence }
            reasoningEffortEvidence = if ($null -eq $modelEvidence) { $null } else { $modelEvidence.reasoning_effort }
            resumeDiagnostics = $resumeDiagnostics
            evidence = $evidenceMessage
            eventStreamPath = $eventPath
            errorStreamPath = $errorPath
            lastMessagePath = $lastMessagePathValue
            threadIdPath = $threadPath
            pidRecordPath = $pidPath
            launcherPath = $launcherPath
            processExitCodeSidecarPath = $exitSidecarPathValue
            promptPath = $promptPathValue
            promptSourcePath = $promptSourcePathValue
            promptSourceSha256 = $promptSourceSha256Value
            promptTransferPath = $promptTransferPathValue
            promptTransferSha256 = $promptTransferSha256Value
            inspectResultPath = $inspectResultPathValue
        }
        $operationException = New-Object System.Exception($originalMessage + "`nStart 失敗證據：" + $evidenceMessage)
        $operationException = Write-DispatchOperationFailureResult -Exception $operationException -Result $failureResult
        throw $operationException
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Get-EventPropertyValue {
    param(
        [Parameter(Mandatory)]
        [psobject]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Test-UsageObject {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or -not ($Value -is [pscustomobject])) {
        return $false
    }

    $requiredNames = @('input_tokens', 'output_tokens')
    foreach ($requiredName in $requiredNames) {
        $property = $Value.PSObject.Properties[$requiredName]
        if ($null -eq $property) {
            return $false
        }
    }

    $numericTypes = @(
        [System.Byte], [System.SByte], [System.Int16], [System.UInt16], [System.Int32], [System.UInt32], [System.Int64], [System.UInt64],
        [single], [double], [decimal]
    )
    foreach ($property in @($Value.PSObject.Properties)) {
        if ($null -eq $property.Value -or $property.Value -is [bool] -or $property.Value.GetType() -notin $numericTypes -or [double]$property.Value -lt 0) {
            return $false
        }
    }

    return @($Value.PSObject.Properties).Count -gt 0
}

function ConvertTo-ComparableDispatchMessage {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Message)

    $normalized = $Message.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($normalized.Length -gt 0 -and $normalized[0] -eq [char]0xFEFF) {
        $normalized = $normalized.Substring(1)
    }
    return $normalized.TrimEnd([char[]]@([char]10))
}

function ConvertTo-DispatchInt32Value {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Field
    )

    $numericTypes = @(
        [System.Byte], [System.SByte], [System.Int16], [System.UInt16], [System.Int32], [System.UInt32], [System.Int64], [System.UInt64],
        [single], [double], [decimal]
    )
    if ($null -eq $Value -or $Value -is [bool] -or $Value.GetType() -notin $numericTypes) {
        throw ('{0} 必須是 Int32 整數。' -f $Field)
    }

    try {
        $decimalValue = [decimal]$Value
    }
    catch {
        throw ('{0} 必須是 Int32 整數。' -f $Field)
    }
    if ($decimalValue -ne [decimal]::Truncate($decimalValue) -or $decimalValue -lt [decimal][int]::MinValue -or $decimalValue -gt [decimal][int]::MaxValue) {
        throw ('{0} 必須是 Int32 整數。' -f $Field)
    }

    return [int]$decimalValue
}

function Set-DispatchJsonPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Value
    )

    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
    else {
        $property.Value = $Value
    }
}

function Throw-DispatchInspectBindingFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Code,

        [Parameter(Mandatory)]
        [string]$Message,

        [AllowEmptyString()]
        [string]$DispatchResultPath,

        [AllowNull()]
        [object]$Detail
    )

    $detailValue = if ($null -eq $Detail) { [ordered]@{} } else { $Detail }
    $result = [ordered]@{
        operation = 'Inspect'
        status = 'failed'
        success = $false
        outputValid = $false
        errorCode = $Code
        error = $Message
        dispatchResultPath = if ([string]::IsNullOrWhiteSpace($DispatchResultPath)) { $null } else { $DispatchResultPath }
        processExitCode = $null
        processExitCodeSource = 'sidecar-unavailable'
        dispatchBinding = $detailValue
    }
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['errorCode'] = $Code
    $exception.Data['operationResult'] = $result
    throw $exception
}

function Read-DispatchExitSidecar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [string]$RunId
    )

    $pathValue = Resolve-AbsolutePath -Path $Path
    $historyRoot = Join-Path (Resolve-AbsolutePath -Path $ExecutionRoot) '.local\ai-sessions\history'
    if (-not (Test-PathWithinRoot -Path $pathValue -Root $historyRoot)) {
        throw "Dispatch exit sidecar 必須位於 execution history：$pathValue"
    }
    if ([IO.Path]::GetFileName($pathValue) -notmatch '^codex-exit-.+\.json$') {
        throw "Dispatch exit sidecar 檔名不符 per-run contract：$pathValue"
    }
    if (-not [System.IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $pathValue))) {
        throw "Dispatch exit sidecar 不存在：$pathValue"
    }

    $bytesBefore = [IO.File]::ReadAllBytes($pathValue)
    if ($bytesBefore.Length -ge 3 -and $bytesBefore[0] -eq 239 -and $bytesBefore[1] -eq 187 -and $bytesBefore[2] -eq 191) {
        throw "Dispatch exit sidecar 必須是 UTF-8 無 BOM：$pathValue"
    }
    $hashBefore = Get-DispatchByteArraySha256 -Bytes $bytesBefore
    try {
        $encoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
        $content = $encoding.GetString($bytesBefore)
        $document = ConvertFrom-DispatchJson -Content $content
    }
    catch {
        throw "Dispatch exit sidecar JSON 無法解析：$pathValue；$($_.Exception.Message)"
    }
    $bytesAfter = [IO.File]::ReadAllBytes($pathValue)
    $hashAfter = Get-DispatchByteArraySha256 -Bytes $bytesAfter
    if (-not [string]::Equals($hashBefore, $hashAfter, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Dispatch exit sidecar 在讀取期間變更：$pathValue"
    }
    if ($null -eq $document -or $document -isnot [psobject] -or $document -is [string] -or $document -is [ValueType]) {
        throw "Dispatch exit sidecar 根節點必須是 JSON object：$pathValue"
    }
    foreach ($name in @('schema', 'line_slug', 'dispatch_slug', 'run_id', 'process_exit_code', 'exit_code_status')) {
        if ($null -eq $document.PSObject.Properties[$name]) {
            throw "Dispatch exit sidecar 缺少欄位：$name"
        }
    }
    if ([string]$document.schema -cne 'ai-sessions.dispatch-exit.v1') {
        throw 'Dispatch exit sidecar schema 不符。'
    }
    if ([string]$document.line_slug -cne $LineSlug -or [string]$document.dispatch_slug -cne $DispatchSlug) {
        throw 'Dispatch exit sidecar line／dispatch 不一致。'
    }
    $parsedRunId = [guid]::Empty
    if ([string]$document.run_id -cne $RunId -or -not [guid]::TryParseExact([string]$document.run_id, 'D', [ref]$parsedRunId)) {
        throw 'Dispatch exit sidecar run_id 不一致或格式錯誤。'
    }
    if ([string]$document.exit_code_status -cne 'known') {
        throw 'Dispatch exit sidecar exit_code_status 必須是 known。'
    }
    $processExitCode = ConvertTo-DispatchInt32Value -Value $document.process_exit_code -Field 'process_exit_code'
    return [pscustomobject]@{
        Path = $pathValue
        Sha256 = $hashBefore
        ProcessExitCode = $processExitCode
        Document = $document
    }
}

function Resolve-DispatchInspectBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DispatchResultPathValue,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [string[]]$TargetPath = @()
    )

    try {
        $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
        $executionRootPath = Resolve-AbsolutePath -Path $ExecutionRoot
        $resultPath = Resolve-AbsolutePath -Path $DispatchResultPathValue
    }
    catch {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('Dispatch result path 或 root 無法解析：' + $_.Exception.Message) -DispatchResultPath $DispatchResultPathValue
    }
    if (-not [System.IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $resultPath))) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('找不到 Dispatch result：' + $resultPath) -DispatchResultPath $resultPath
    }
    $historyRoots = @(
        (Join-Path $sourceRootPath '.local\ai-sessions\history'),
        (Join-Path $executionRootPath '.local\ai-sessions\history')
    )
    if (-not (@($historyRoots | Where-Object { Test-PathWithinRoot -Path $resultPath -Root $_ }).Count -gt 0)) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('Dispatch result 必須位於 source 或 execution history：' + $resultPath) -DispatchResultPath $resultPath
    }
    try {
        $resultFileSha256AtRead = Get-FileSha256 -Path $resultPath
    }
    catch {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('Dispatch result 雜湊無法讀取：' + $_.Exception.Message) -DispatchResultPath $resultPath
    }

    try {
        $document = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $resultPath)
    }
    catch {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('Dispatch result JSON 無法解析：' + $_.Exception.Message) -DispatchResultPath $resultPath
    }
    if ($null -eq $document -or $document -isnot [psobject] -or $document -is [string] -or $document -is [ValueType]) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'Dispatch result 根節點必須是 JSON object。' -DispatchResultPath $resultPath
    }
    $resultHash = [string](Get-DispatchJsonProperty -Object $document -Name 'result_sha256')
    if ($resultHash -notmatch '^[a-fA-F0-9]{64}$') {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'Dispatch result 缺少有效 result_sha256。' -DispatchResultPath $resultPath
    }
    try {
        $computedResultHash = Get-PrepareDocumentFingerprint -Document $document
    }
    catch {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('Dispatch result 雜湊無法計算：' + $_.Exception.Message) -DispatchResultPath $resultPath
    }
    if (-not [string]::Equals($resultHash, $computedResultHash, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'Dispatch result result_sha256 不一致。' -DispatchResultPath $resultPath -Detail ([ordered]@{ expected = $computedResultHash; received = $resultHash })
    }
    if ([string](Get-DispatchJsonProperty -Object $document -Name 'schema') -cne 'ai-sessions.dispatch-result.v1' -or
        [string](Get-DispatchJsonProperty -Object $document -Name 'operation') -cne 'Dispatch' -or
        [string](Get-DispatchJsonProperty -Object $document -Name 'line_slug') -cne $LineSlug -or
        [string](Get-DispatchJsonProperty -Object $document -Name 'dispatch_slug') -cne $DispatchSlug) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'Dispatch result schema／operation／line／dispatch 不一致。' -DispatchResultPath $resultPath
    }
    if ((Get-DispatchJsonProperty -Object $document -Name 'process_started') -isnot [bool] -or -not [bool](Get-DispatchJsonProperty -Object $document -Name 'process_started')) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'Dispatch result 必須是 process_started=true 的結果。' -DispatchResultPath $resultPath
    }
    $binding = Get-DispatchJsonProperty -Object $document -Name 'inspect_binding'
    if ($null -eq $binding -or $binding -isnot [psobject] -or $binding -is [string] -or $binding -is [ValueType]) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'Dispatch result 缺少 inspect_binding object。' -DispatchResultPath $resultPath
    }

    $bindingPaths = [ordered]@{}
    foreach ($name in @('run_record_path', 'event_stream_path', 'scope_plan_path', 'quota_before_path', 'process_exit_code_sidecar_path')) {
        $value = Get-DispatchJsonProperty -Object $binding -Name $name
        if ($null -eq $value -or $value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$value)) {
            Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('inspect_binding 缺少有效路徑：' + $name) -DispatchResultPath $resultPath -Detail ([ordered]@{ field = $name })
        }
        try {
            $resolvedValue = Resolve-AbsolutePath -Path ([string]$value)
        }
        catch {
            Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('inspect_binding 路徑無法解析：' + $name) -DispatchResultPath $resultPath -Detail ([ordered]@{ field = $name; error = $_.Exception.Message })
        }
        if (-not [string]::Equals($resolvedValue, [string]$value, [StringComparison]::OrdinalIgnoreCase)) {
            Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('inspect_binding 路徑未正規化：' + $name) -DispatchResultPath $resultPath -Detail ([ordered]@{ field = $name; value = $value })
        }
        $bindingPaths[$name] = $resolvedValue
    }
    $quotaBeforeSha256 = [string](Get-DispatchJsonProperty -Object $binding -Name 'quota_before_sha256')
    if ($quotaBeforeSha256 -notmatch '^[a-fA-F0-9]{64}$') {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'inspect_binding 缺少有效 quota_before_sha256。' -DispatchResultPath $resultPath
    }
    $resultQuotaBeforePath = [string](Get-DispatchJsonProperty -Object $document -Name 'quota_before_path')
    $resultQuotaBeforeSha256 = [string](Get-DispatchJsonProperty -Object $document -Name 'quota_before_sha256')
    if ([string]::IsNullOrWhiteSpace($resultQuotaBeforePath) -or
        -not [string]::Equals((Resolve-AbsolutePath -Path $resultQuotaBeforePath), $bindingPaths.quota_before_path, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($resultQuotaBeforeSha256, $quotaBeforeSha256, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'Dispatch result 與 inspect_binding quota before path／SHA-256 不一致。' -DispatchResultPath $resultPath
    }
    $evidencePosition = Get-DispatchJsonProperty -Object $document -Name 'evidence_position'
    if ($null -ne $evidencePosition) {
        $evidenceQuotaBeforePath = [string](Get-DispatchJsonProperty -Object $evidencePosition -Name 'quota_before_path')
        $evidenceQuotaBeforeSha256 = [string](Get-DispatchJsonProperty -Object $evidencePosition -Name 'quota_before_sha256')
        if ([string]::IsNullOrWhiteSpace($evidenceQuotaBeforePath) -or
            -not [string]::Equals((Resolve-AbsolutePath -Path $evidenceQuotaBeforePath), $bindingPaths.quota_before_path, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($evidenceQuotaBeforeSha256, $quotaBeforeSha256, [StringComparison]::OrdinalIgnoreCase)) {
            Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'Dispatch evidence quota before path／SHA-256 不一致。' -DispatchResultPath $resultPath
        }
    }
    if (-not (Test-PathWithinRoot -Path $bindingPaths.run_record_path -Root (Join-Path $sourceRootPath '.local\ai-sessions\history'))) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'inspect_binding RunRecord 超出 source history。' -DispatchResultPath $resultPath
    }
    if (-not (Test-PathWithinRoot -Path $bindingPaths.event_stream_path -Root (Join-Path $executionRootPath '.local\ai-sessions\history'))) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'inspect_binding event stream 超出 execution history。' -DispatchResultPath $resultPath
    }
    if (-not (Test-PathWithinRoot -Path $bindingPaths.scope_plan_path -Root $executionRootPath)) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'inspect_binding ScopePlan 超出 execution root。' -DispatchResultPath $resultPath
    }
    if (-not (Test-PathWithinRoot -Path $bindingPaths.process_exit_code_sidecar_path -Root (Join-Path $executionRootPath '.local\ai-sessions\history'))) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'inspect_binding exit sidecar 超出 execution history。' -DispatchResultPath $resultPath
    }
    if (-not (Test-PathWithinRoot -Path $bindingPaths.quota_before_path -Root $sourceRootPath) -and -not (Test-PathWithinRoot -Path $bindingPaths.quota_before_path -Root $executionRootPath)) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'inspect_binding quota before 超出 source／execution root。' -DispatchResultPath $resultPath
    }

    try {
        $record = Read-DispatchRunRecord -Path $bindingPaths.run_record_path -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    }
    catch {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('Dispatch result RunRecord binding 無效：' + $_.Exception.Message) -DispatchResultPath $resultPath -Detail ([ordered]@{ run_record_path = $bindingPaths.run_record_path })
    }
    $recordComparisons = @(
        [pscustomobject]@{ Name = 'event_stream_path'; Expected = $record.event_stream_path; Actual = $bindingPaths.event_stream_path }
        [pscustomobject]@{ Name = 'scope_plan_path'; Expected = $record.scope_plan_path; Actual = $bindingPaths.scope_plan_path }
        [pscustomobject]@{ Name = 'process_exit_code_sidecar_path'; Expected = $record.process_exit_code_sidecar_path; Actual = $bindingPaths.process_exit_code_sidecar_path }
        [pscustomobject]@{ Name = 'quota_before_path'; Expected = $record.quota_before_path; Actual = $bindingPaths.quota_before_path }
    )
    foreach ($comparison in $recordComparisons) {
        if ([string]::IsNullOrWhiteSpace([string]$comparison.Expected) -or -not [string]::Equals((Resolve-AbsolutePath -Path ([string]$comparison.Expected)), $comparison.Actual, [StringComparison]::OrdinalIgnoreCase)) {
            Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('Dispatch result 與 RunRecord binding 不一致：' + $comparison.Name) -DispatchResultPath $resultPath -Detail ([ordered]@{ field = $comparison.Name; run_record = $comparison.Expected; dispatch_result = $comparison.Actual })
        }
    }
    $recordQuotaBeforeSha256 = [string](Get-DispatchJsonProperty -Object $record -Name 'quota_before_sha256')
    if ($recordQuotaBeforeSha256 -notmatch '^[a-fA-F0-9]{64}$' -or
        -not [string]::Equals($recordQuotaBeforeSha256, $quotaBeforeSha256, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'Dispatch result 與 RunRecord quota before SHA-256 binding 不一致。' -DispatchResultPath $resultPath
    }
    try {
        $actualQuotaBeforeSha256 = Get-FileSha256 -Path $bindingPaths.quota_before_path
    }
    catch {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('quota before snapshot 雜湊無法讀取：' + $_.Exception.Message) -DispatchResultPath $resultPath
    }
    if (-not [string]::Equals($actualQuotaBeforeSha256, $quotaBeforeSha256, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'quota before snapshot SHA-256 與 Dispatch／RunRecord binding 不一致。' -DispatchResultPath $resultPath -Detail ([ordered]@{ expected = $quotaBeforeSha256; actual = $actualQuotaBeforeSha256 })
    }

    $sidecar = $null
    try {
        $sidecar = Read-DispatchExitSidecar -Path $bindingPaths.process_exit_code_sidecar_path -ExecutionRoot $executionRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId ([string]$record.run_id)
    }
    catch {
        Throw-DispatchInspectBindingFailure -Code 'DispatchExitCodeUnavailable' -Message ('Dispatch exit sidecar 無法取得：' + $_.Exception.Message) -DispatchResultPath $resultPath -Detail ([ordered]@{ sidecar_path = $bindingPaths.process_exit_code_sidecar_path; run_id = $record.run_id })
    }

    $bindingProcessExitCode = $null
    $bindingProcessExitProperty = $binding.PSObject.Properties['process_exit_code']
    if ($null -ne $bindingProcessExitProperty -and $null -ne $bindingProcessExitProperty.Value) {
        try {
            $bindingProcessExitCode = ConvertTo-DispatchInt32Value -Value $bindingProcessExitProperty.Value -Field 'inspect_binding.process_exit_code'
        }
        catch {
            Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message $_.Exception.Message -DispatchResultPath $resultPath
        }
    }
    $explicitProcessExitCode = $null
    if (Test-DispatchInvocationParameterBound -Name 'ProcessExitCode') {
        $explicitValue = Get-DispatchInvocationParameterValue -Name 'ProcessExitCode'
        if ($null -eq $explicitValue) {
            Throw-DispatchInspectBindingFailure -Code 'DispatchExitCodeMismatch' -Message '命令列顯式 ProcessExitCode 為 null，無法與 sidecar 一致。' -DispatchResultPath $resultPath -Detail ([ordered]@{ sidecar = $sidecar.ProcessExitCode; explicit = $null })
        }
        try {
            $explicitProcessExitCode = ConvertTo-DispatchInt32Value -Value $explicitValue -Field 'ProcessExitCode'
        }
        catch {
            Throw-DispatchInspectBindingFailure -Code 'DispatchExitCodeMismatch' -Message $_.Exception.Message -DispatchResultPath $resultPath
        }
    }
    if (($null -ne $bindingProcessExitCode -and $bindingProcessExitCode -ne $sidecar.ProcessExitCode) -or ($null -ne $explicitProcessExitCode -and $explicitProcessExitCode -ne $sidecar.ProcessExitCode)) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchExitCodeMismatch' -Message 'Dispatch exit sidecar 與既有 ProcessExitCode 不一致。' -DispatchResultPath $resultPath -Detail ([ordered]@{ sidecar = $sidecar.ProcessExitCode; result_binding = $bindingProcessExitCode; explicit = $explicitProcessExitCode })
    }

    try {
        Set-DispatchJsonPropertyValue -Object $binding -Name 'process_exit_code' -Value $sidecar.ProcessExitCode
        Set-DispatchJsonPropertyValue -Object $binding -Name 'process_exit_code_source' -Value 'sidecar'
        Set-DispatchJsonPropertyValue -Object $binding -Name 'sidecar_sha256' -Value $sidecar.Sha256
        $null = Write-DispatchAtomicJsonDocument -Path $resultPath -Document $document -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath) -ExpectedExistingSha256 $resultFileSha256AtRead
    }
    catch {
        $bindingWriteErrorCode = [string]$_.Exception.Data['errorCode']
        if ([string]::IsNullOrWhiteSpace($bindingWriteErrorCode)) {
            $bindingWriteErrorCode = 'DispatchResultBindingWriteFailed'
        }
        Throw-DispatchInspectBindingFailure -Code $bindingWriteErrorCode -Message ('Dispatch result binding 更新失敗：' + $_.Exception.Message) -DispatchResultPath $resultPath -Detail ([ordered]@{ sidecar_path = $sidecar.Path; expected_result_sha256 = $resultFileSha256AtRead })
    }

    return [pscustomobject]@{
        Path = $resultPath
        Document = $document
        Record = $record
        EventStreamPath = $bindingPaths.event_stream_path
        RunRecordPath = $bindingPaths.run_record_path
        ScopePlanPath = $bindingPaths.scope_plan_path
        QuotaBeforePath = $bindingPaths.quota_before_path
        QuotaBeforeSha256 = $quotaBeforeSha256
        SidecarPath = $sidecar.Path
        SidecarSha256 = $sidecar.Sha256
        ProcessExitCode = $sidecar.ProcessExitCode
        ProcessExitCodeSource = 'sidecar'
    }
}

function Invoke-Inspect {
    $modelEvidence = $null
    $sandboxAclEvidence = $null
    $requiredOutputGate = $null
    $evidencePackInfo = $null
    $runtimeModelEvidence = $null
    $runtimeReasoningEffortEvidence = $null
    $diagnosis = $null
    $dispatchInspectBinding = $null
    $dispatchResultPathValue = $null
    $processExitCodeSource = 'explicit'
    $processExitCodeSidecarPath = $null
    $processExitCodeSidecarSha256 = $null
    if ([string]::IsNullOrWhiteSpace($RequiredIdentifier)) {
        throw 'Inspect 必須提供 RequiredIdentifier。'
    }
    if (-not [string]::IsNullOrWhiteSpace($DispatchResultPath)) {
        if ([string]::IsNullOrWhiteSpace($SourceRoot) -or [string]::IsNullOrWhiteSpace($ExecutionRoot) -or
            [string]::IsNullOrWhiteSpace($LineSlug) -or [string]::IsNullOrWhiteSpace($DispatchSlug)) {
            Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message '使用 DispatchResultPath 時必須同時提供 SourceRoot、ExecutionRoot、LineSlug 與 DispatchSlug。' -DispatchResultPath $DispatchResultPath
        }
        $dispatchInspectBinding = Resolve-DispatchInspectBinding -DispatchResultPathValue $DispatchResultPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -TargetPath @($TargetPath)
        $dispatchResultPathValue = $dispatchInspectBinding.Path
        $bindingPathArguments = @(
            [pscustomobject]@{ Name = 'RunRecordPath'; Expected = $dispatchInspectBinding.RunRecordPath }
            [pscustomobject]@{ Name = 'EventStreamPath'; Expected = $dispatchInspectBinding.EventStreamPath }
            [pscustomobject]@{ Name = 'ScopePlanPath'; Expected = $dispatchInspectBinding.ScopePlanPath }
            [pscustomobject]@{ Name = 'QuotaBeforePath'; Expected = $dispatchInspectBinding.QuotaBeforePath }
        )
        foreach ($bindingPathArgument in $bindingPathArguments) {
            if (Test-DispatchInvocationParameterBound -Name $bindingPathArgument.Name) {
                $receivedPath = Get-DispatchInvocationParameterValue -Name $bindingPathArgument.Name
                if ($null -eq $receivedPath -or [string]::IsNullOrWhiteSpace([string]$receivedPath)) {
                    Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ($bindingPathArgument.Name + ' 不可在 Dispatch binding 模式中為空。') -DispatchResultPath $dispatchResultPathValue -Detail ([ordered]@{ field = $bindingPathArgument.Name })
                }
                try {
                    $resolvedReceivedPath = Resolve-AbsolutePath -Path ([string]$receivedPath)
                }
                catch {
                    Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ($bindingPathArgument.Name + ' 無法解析：' + $_.Exception.Message) -DispatchResultPath $dispatchResultPathValue -Detail ([ordered]@{ field = $bindingPathArgument.Name; value = $receivedPath })
                }
                if (-not [string]::Equals($resolvedReceivedPath, [string]$bindingPathArgument.Expected, [StringComparison]::OrdinalIgnoreCase)) {
                    Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ($bindingPathArgument.Name + ' 與 Dispatch result binding 不一致。') -DispatchResultPath $dispatchResultPathValue -Detail ([ordered]@{ field = $bindingPathArgument.Name; expected = $bindingPathArgument.Expected; received = $resolvedReceivedPath })
                }
            }
            Set-Variable -Name $bindingPathArgument.Name -Scope Local -Value ([string]$bindingPathArgument.Expected)
        }
        Set-Variable -Name 'ProcessExitCode' -Scope Local -Value ([Nullable[int]]$dispatchInspectBinding.ProcessExitCode)
        $processExitCodeSource = [string]$dispatchInspectBinding.ProcessExitCodeSource
        $processExitCodeSidecarPath = [string]$dispatchInspectBinding.SidecarPath
        $processExitCodeSidecarSha256 = [string]$dispatchInspectBinding.SidecarSha256
    }
    if ([string]::IsNullOrWhiteSpace($DispatchSlug)) {
        throw 'Inspect 必須提供 DispatchSlug。'
    }
    if ([string]::IsNullOrWhiteSpace($LineSlug)) {
        throw 'Inspect 必須提供 LineSlug。'
    }
    if ([string]::IsNullOrWhiteSpace($EventStreamPath)) {
        throw 'Inspect 必須提供 EventStreamPath。'
    }
    if ($null -eq $ProcessExitCode) {
        throw 'Inspect 必須提供 ProcessExitCode。'
    }
    $eventPath = Resolve-AbsolutePath -Path $EventStreamPath
    $eventEvidence = Get-DispatchEventEvidence -EventPath $eventPath
    $serviceRejectionEvidence = Convert-EventEvidenceToServiceRejection -EventEvidence $eventEvidence
    $inspectRun = Resolve-InspectDispatchRun -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -EventStreamPath $eventPath -ScopePlanPath $ScopePlanPath -RunRecordPath $RunRecordPath
    if ($inspectRun.Record.launch_state -eq 'launch-failed') {
        $failure = Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'failure'
        $failureOriginalOutput = Get-DispatchJsonProperty -Object $failure -Name 'original_output'
        $diagnosis = [ordered]@{
            status = 'failed'
            reason_code = [string](Get-DispatchJsonProperty -Object $failure -Name 'reason_code')
            observation = Get-DispatchJsonProperty -Object $failure -Name 'observation'
            original_output = $failureOriginalOutput
        }
        $failureErrorPath = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'error_stream_path')
        $failureStderr = ''
        if ([string]::IsNullOrWhiteSpace($failureErrorPath)) {
            $failureErrorPath = [string](Get-DispatchJsonProperty -Object $failureOriginalOutput -Name 'stderr').path
        }
        if (-not [string]::IsNullOrWhiteSpace($failureErrorPath) -and (Test-Path -LiteralPath $failureErrorPath -PathType Leaf)) {
            $failureStderr = Get-Content -LiteralPath $failureErrorPath -Raw -Encoding UTF8
        }
        return [ordered]@{
            operation = 'Inspect'
            runId = $inspectRun.Record.run_id
            runRecordPath = $inspectRun.Path
            lastMessageConsistency = 'NotApplicable'
            finalMessageSource = 'none'
            eventStreamPath = $eventPath
            errorStreamPath = if ([string]::IsNullOrWhiteSpace($failureErrorPath)) { $null } else { $failureErrorPath }
            processExitCode = [int]$ProcessExitCode
            processExitCodeSource = $processExitCodeSource
            processExitCodeSidecarPath = $processExitCodeSidecarPath
            processExitCodeSidecarSha256 = $processExitCodeSidecarSha256
            dispatchResultPath = $dispatchResultPathValue
            eventCount = 0
            lastEventType = 'none'
            threadId = $null
            completed = $false
            success = $false
            turnFailedReason = [string](Get-DispatchJsonProperty -Object $failure -Name 'message')
            finalMessage = $null
            outputValid = $false
            diagnosis = $diagnosis
            failure = $failure
            eventEvidence = $eventEvidence
            service_rejection = $serviceRejectionEvidence
            retry_allowed = if ($null -eq $serviceRejectionEvidence) { $null } else { $false }
            modelEvidence = Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'model_evidence'
            reasoningEffortEvidence = Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'reasoning_effort_evidence'
            stderr = $failureStderr
        }
    }
    if (-not [System.IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $eventPath))) {
        throw "事件流檔案不存在：$eventPath"
    }

    $events = New-Object System.Collections.Generic.List[object]
    $malformedLines = New-Object System.Collections.Generic.List[object]
    $rawEventLines = New-Object System.Collections.Generic.List[string]
    $threadIds = New-Object System.Collections.Generic.List[string]
    $lineNumber = 0
    foreach ($line in ((Read-DispatchUtf8Text -Path $eventPath) -split '\r?\n')) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $rawEventLines.Add($line)
        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $malformedLines.Add([pscustomobject]@{
                    LineNumber = $lineNumber
                    Raw        = $line
                    Error      = $_.Exception.Message
                })
            continue
        }
        $typeProperty = if ($null -eq $event) { $null } else { $event.PSObject.Properties['type'] }
        $typeValue = if ($null -eq $typeProperty) { $null } else { $typeProperty.Value }
        if ($null -eq $event -or $null -eq $typeProperty -or -not ($typeValue -is [string]) -or [string]::IsNullOrWhiteSpace($typeValue)) {
            $malformedLines.Add([pscustomobject]@{
                    LineNumber = $lineNumber
                    Raw        = $line
                    Error      = '事件流缺少 type。'
                })
            continue
        }
        $events.Add($event)
    }
    if ($malformedLines.Count -gt 0) {
        $details = @($malformedLines | ForEach-Object { "line=$($_.LineNumber); error=$($_.Error); raw=$($_.Raw)" }) -join "`n"
        $malformedMessage = "事件流包含無法解析的行，已保留其餘可解析事件，Inspect 以非零結束碼停止：`n$details"
        $malformedStderr = if (-not [string]::IsNullOrWhiteSpace($ErrorStreamPath) -and (Test-Path -LiteralPath $ErrorStreamPath -PathType Leaf)) { Get-Content -LiteralPath $ErrorStreamPath -Raw -Encoding UTF8 } else { '' }
        $malformedDiagnosis = New-DispatchInspectDiagnosis -ReasonCode 'Unknown' -Observation '事件流包含無法解析的 raw line。' -EventStreamPath $eventPath -ErrorStreamPath $ErrorStreamPath -RawEventLines @($rawEventLines.ToArray()) -Stderr $malformedStderr
        $malformedResult = [ordered]@{
            operation = 'Inspect'
            runId = $inspectRun.Record.run_id
            runRecordPath = $inspectRun.Path
            success = $false
            outputValid = $false
            errorCode = 'Unknown'
            error = $malformedMessage
            diagnosis = $malformedDiagnosis
            eventEvidence = $eventEvidence
            service_rejection = $serviceRejectionEvidence
            retry_allowed = if ($null -eq $serviceRejectionEvidence) { $null } else { $false }
            eventStreamPath = $eventPath
            errorStreamPath = $ErrorStreamPath
            processExitCode = [int]$ProcessExitCode
            processExitCodeSource = $processExitCodeSource
            processExitCodeSidecarPath = $processExitCodeSidecarPath
            processExitCodeSidecarSha256 = $processExitCodeSidecarSha256
            dispatchResultPath = $dispatchResultPathValue
        }
        $malformedException = New-Object System.Exception($malformedMessage)
        $malformedException = Write-DispatchOperationFailureResult -Exception $malformedException -Result $malformedResult
        throw $malformedException
    }
    if ($events.Count -eq 0) {
        $emptyMessage = '事件流沒有可解析的事件。'
        $emptyStderr = if (-not [string]::IsNullOrWhiteSpace($ErrorStreamPath) -and (Test-Path -LiteralPath $ErrorStreamPath -PathType Leaf)) { Get-Content -LiteralPath $ErrorStreamPath -Raw -Encoding UTF8 } else { '' }
        $emptyDiagnosis = New-DispatchInspectDiagnosis -ReasonCode 'Unknown' -Observation '事件流沒有可解析的 raw event。' -EventStreamPath $eventPath -ErrorStreamPath $ErrorStreamPath -RawEventLines @($rawEventLines.ToArray()) -Stderr $emptyStderr
        $emptyResult = [ordered]@{
            operation = 'Inspect'
            runId = $inspectRun.Record.run_id
            runRecordPath = $inspectRun.Path
            success = $false
            outputValid = $false
            errorCode = 'Unknown'
            error = $emptyMessage
            diagnosis = $emptyDiagnosis
            eventEvidence = $eventEvidence
            service_rejection = $serviceRejectionEvidence
            retry_allowed = if ($null -eq $serviceRejectionEvidence) { $null } else { $false }
            eventStreamPath = $eventPath
            errorStreamPath = $ErrorStreamPath
            processExitCode = [int]$ProcessExitCode
            processExitCodeSource = $processExitCodeSource
            processExitCodeSidecarPath = $processExitCodeSidecarPath
            processExitCodeSidecarSha256 = $processExitCodeSidecarSha256
            dispatchResultPath = $dispatchResultPathValue
        }
        $emptyException = New-Object System.Exception($emptyMessage)
        $emptyException = Write-DispatchOperationFailureResult -Exception $emptyException -Result $emptyResult
        throw $emptyException
    }

    $eventTailType = [string](Get-EventPropertyValue -Object $events[$events.Count - 1] -Name 'type')
    if ($eventTailType -eq 'turn.started' -and [int]$ProcessExitCode -ne 0) {
        $unknownStderr = ''
        if (-not [string]::IsNullOrWhiteSpace($ErrorStreamPath) -and (Test-Path -LiteralPath $ErrorStreamPath -PathType Leaf)) {
            $unknownStderr = Get-Content -LiteralPath $ErrorStreamPath -Raw -Encoding UTF8
        }
        $recordWriteMode = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'write_mode')
        if ([string]::IsNullOrWhiteSpace($recordWriteMode)) {
            $recordWriteMode = if ([string]::Equals((Resolve-AbsolutePath -Path $SourceRoot), (Resolve-AbsolutePath -Path $ExecutionRoot), [StringComparison]::OrdinalIgnoreCase)) { 'direct-write' } else { 'worktree' }
        }
        $unknownAclGate = Get-WorktreeAclGate -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -WriteMode $recordWriteMode -ContinuationRecord $inspectRun.Record
        $diagnosis = New-DispatchInspectDiagnosis -ReasonCode 'InterruptedUnknown' -Observation '事件流在 turn.started 後沒有後續事件，且 process exit code 非零。' -EventStreamPath $eventPath -ErrorStreamPath $ErrorStreamPath -RawEventLines @($rawEventLines.ToArray()) -Stderr $unknownStderr
        $unknownInterruption = [ordered]@{
            status = 'InterruptedUnknown'
            cold_start_recommended = $true
            last_event_type = $eventTailType
            process_exit_code = [int]$ProcessExitCode
            event_tail = @($rawEventLines.ToArray() | Select-Object -Last 3)
            acl_gate = $unknownAclGate
        }
        if ($null -eq $inspectRun.Record.PSObject.Properties['unknown_interruption']) {
            $inspectRun.Record | Add-Member -MemberType NoteProperty -Name 'unknown_interruption' -Value $unknownInterruption
        }
        else {
            $inspectRun.Record.unknown_interruption = $unknownInterruption
        }
        $null = Write-DispatchRunRecord -Record $inspectRun.Record -Update
        return [ordered]@{
            operation = 'Inspect'
            runId = $inspectRun.Record.run_id
            runRecordPath = $inspectRun.Path
            lastMessageConsistency = 'NotApplicable'
            finalMessageSource = 'none'
            eventStreamPath = $eventPath
            errorStreamPath = $ErrorStreamPath
            processExitCode = [int]$ProcessExitCode
            processExitCodeSource = $processExitCodeSource
            processExitCodeSidecarPath = $processExitCodeSidecarPath
            processExitCodeSidecarSha256 = $processExitCodeSidecarSha256
            eventCount = $events.Count
            lastEventType = $eventTailType
            threadId = [string](Get-EventPropertyValue -Object $events[0] -Name 'thread_id')
            completed = $false
            success = $false
            turnFailedReason = ''
            finalMessage = $null
            outputValid = $false
            diagnosis = $diagnosis
            cold_start_recommended = $true
            recoveryState = 'InterruptedUnknown'
            unknownInterruption = $unknownInterruption
            eventEvidence = $eventEvidence
            service_rejection = $serviceRejectionEvidence
            retry_allowed = if ($null -eq $serviceRejectionEvidence) { $null } else { $false }
            stderr = $unknownStderr
        }
    }

    $threadId = ''
    $finalEventMessage = ''
    $lastAgentMessage = ''
    $usage = $null
    foreach ($event in $events) {
        $eventType = Get-EventPropertyValue -Object $event -Name 'type'
        if ($eventType -eq 'thread.started') {
            $threadIdValue = Get-EventPropertyValue -Object $event -Name 'thread_id'
            if ($null -eq $threadIdValue -or -not ($threadIdValue -is [string]) -or [string]::IsNullOrWhiteSpace($threadIdValue)) {
                throw 'thread.started.thread_id 必須為非空字串。'
            }
            $parsedThreadId = [guid]::Empty
            if (-not [guid]::TryParse($threadIdValue, [ref]$parsedThreadId)) {
                throw "事件流 thread.started.thread_id 必須為 UUID：$threadIdValue"
            }
            $threadIds.Add($threadIdValue)
        }
        $item = Get-EventPropertyValue -Object $event -Name 'item'
        if ($null -ne $item) {
            $itemType = Get-EventPropertyValue -Object $item -Name 'type'
            if ($eventType -eq 'item.completed' -and ($itemType -is [string]) -and $itemType -eq 'agent_message') {
                $textValue = Get-EventPropertyValue -Object $item -Name 'text'
                if ($null -eq $textValue -or -not ($textValue -is [string]) -or [string]::IsNullOrWhiteSpace($textValue)) {
                    throw 'agent_message.text 必須為非空字串。'
                }
                $lastAgentMessage = $textValue
            }
        }
        if ($eventType -eq 'turn.completed') {
            $usage = Get-EventPropertyValue -Object $event -Name 'usage'
        }
        if ($eventType -eq 'error') {
            $messageValue = Get-EventPropertyValue -Object $event -Name 'message'
            if ($null -ne $messageValue) {
                if (-not ($messageValue -is [string])) {
                    throw 'error.message 必須為字串。'
                }
                $finalEventMessage = $messageValue
            }
        }
    }

    $lastEvent = $events[$events.Count - 1]
    $lastEventType = Get-EventPropertyValue -Object $lastEvent -Name 'type'
    if ($lastEventType -ne 'turn.completed' -and $lastEventType -ne 'turn.failed') {
        throw "事件流最後事件不是必要的 turn.completed 或 turn.failed：$lastEventType"
    }

    $distinctThreadIds = @($threadIds.ToArray() | Sort-Object -Unique)
    if ($distinctThreadIds.Count -gt 1) {
        throw "事件流包含不同 thread id：$($distinctThreadIds -join ',')"
    }
    if ($distinctThreadIds.Count -eq 0) {
        throw '事件流缺少 thread.started.thread_id。'
    }
    $threadId = $distinctThreadIds[0]

    $recordModelEvidence = Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'model_evidence'
    $recordReasoningEffortEvidence = Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'reasoning_effort_evidence'
    $modelEvidenceGroup = ConvertTo-DispatchEvidenceGroup -Evidence $recordModelEvidence -Field 'model'
    $effortEvidenceGroup = ConvertTo-DispatchEvidenceGroup -Evidence $recordReasoningEffortEvidence -Field 'model_reasoning_effort'
    $runtimeCodexHome = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'codex_home')
    if ([string]::IsNullOrWhiteSpace($runtimeCodexHome)) {
        $runtimeCodexHome = $CodexHome
    }
    $runtimeStartedAt = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'started_at_utc')
    $runtimeEvidence = Get-RuntimeModelEvidence -CodexHome $runtimeCodexHome -ThreadId $threadId -StartedAtUtc $runtimeStartedAt
    $runtimeModelEvidence = $runtimeEvidence.model
    $runtimeReasoningEffortEvidence = $runtimeEvidence.reasoning_effort
    $modelEvidenceGroup.runtime_verifiable = $runtimeModelEvidence
    $effortEvidenceGroup.runtime_verifiable = $runtimeReasoningEffortEvidence
    $modelEvidence = [ordered]@{
        evidence_contract = 'codex-dispatch.model-evidence.v1'
        model = $modelEvidenceGroup
        reasoning_effort = $effortEvidenceGroup
    }
    if ($null -eq $inspectRun.Record.PSObject.Properties['model_evidence']) {
        $inspectRun.Record | Add-Member -MemberType NoteProperty -Name 'model_evidence' -Value $modelEvidenceGroup
    }
    else {
        $inspectRun.Record.model_evidence = $modelEvidenceGroup
    }
    if ($null -eq $inspectRun.Record.PSObject.Properties['reasoning_effort_evidence']) {
        $inspectRun.Record | Add-Member -MemberType NoteProperty -Name 'reasoning_effort_evidence' -Value $effortEvidenceGroup
    }
    else {
        $inspectRun.Record.reasoning_effort_evidence = $effortEvidenceGroup
    }
    $null = Write-DispatchRunRecord -Record $inspectRun.Record -Update

    if ([string]::IsNullOrWhiteSpace($lastAgentMessage)) {
        throw '事件流缺少必要的最後 agent_message。'
    }

    if ($lastEventType -eq 'turn.completed') {
        $usageProperty = $lastEvent.PSObject.Properties['usage']
        if ($null -eq $usageProperty -or -not (Test-UsageObject -Value $usageProperty.Value)) {
            throw '事件流缺少 turn.completed.usage。'
        }
    }

    $turnFailedReason = ''
    if ($lastEventType -eq 'turn.failed') {
        $errorObject = Get-EventPropertyValue -Object $lastEvent -Name 'error'
        if ($null -ne $errorObject) {
            $errorMessage = Get-EventPropertyValue -Object $errorObject -Name 'message'
            if ($null -ne $errorMessage) {
                if (-not ($errorMessage -is [string])) {
                    throw 'turn.failed.error.message 必須為字串。'
                }
                $turnFailedReason = $errorMessage
            }
        }
        if ([string]::IsNullOrWhiteSpace($turnFailedReason)) {
            $turnFailedReason = $finalEventMessage
        }
    }
    $inspectStderr = ''
    if (-not [string]::IsNullOrWhiteSpace($ErrorStreamPath) -and (Test-Path -LiteralPath $ErrorStreamPath -PathType Leaf)) {
        $inspectStderr = Get-Content -LiteralPath $ErrorStreamPath -Raw -Encoding UTF8
    }
    if ($lastEventType -eq 'turn.failed' -or [int]$ProcessExitCode -ne 0) {
        $diagnosisReasonCode = if ([string]::IsNullOrWhiteSpace($turnFailedReason)) { 'Unknown' } else { 'CodexLaunchFailed' }
        $diagnosisObservation = if ([string]::IsNullOrWhiteSpace($turnFailedReason)) {
            if ($lastEventType -eq 'turn.failed') { 'turn.failed 沒有提供可解析的 error.message。' } else { 'process exit code 非零，但事件流沒有可確認的錯誤原因。' }
        }
        else {
            '事件流提供 turn.failed error.message。'
        }
        $diagnosis = New-DispatchInspectDiagnosis -ReasonCode $diagnosisReasonCode -Observation $diagnosisObservation -EventStreamPath $eventPath -ErrorStreamPath $ErrorStreamPath -RawEventLines @($rawEventLines.ToArray()) -Stderr $inspectStderr
    }

    $finalMessage = $lastAgentMessage
    $finalMessageIdentity = Get-DispatchFinalMessageIdentity -Message $finalMessage -RequiredIdentifier $RequiredIdentifier -DispatchSlug $DispatchSlug -LineSlug $LineSlug -Source $eventPath
    $explicitMessagePath = -not [string]::IsNullOrWhiteSpace($LastMessagePath)
    $messagePath = $inspectRun.Record.last_message_path
    $lastMessageConsistency = 'Missing'
    if ($explicitMessagePath -and -not [string]::Equals((Resolve-AbsolutePath $LastMessagePath), $messagePath, [StringComparison]::OrdinalIgnoreCase)) {
        $lastMessageConsistency = 'BindingMismatch'
    }
    else {
        $externalMessage = ''
        if (Test-Path -LiteralPath $messagePath -PathType Leaf) {
            $utf8 = New-Object Text.UTF8Encoding($false, $true)
            $externalMessage = $utf8.GetString([IO.File]::ReadAllBytes($messagePath))
        }
        if ([string]::IsNullOrWhiteSpace($externalMessage)) {
            if ($explicitMessagePath) { throw '明確指定的 last-message 缺失或空白。' }
        }
        elseif ([string]::Equals((ConvertTo-ComparableDispatchMessage $finalMessage), (ConvertTo-ComparableDispatchMessage $externalMessage), [StringComparison]::Ordinal)) {
            $lastMessageConsistency = 'Match'
        }
        else {
            $lastMessageConsistency = 'Mismatch'
        }
    }

    $outputValid = $lastMessageConsistency -in @('Match', 'Missing') -and $finalMessageIdentity.valid
    if (-not $finalMessageIdentity.valid -and $null -eq $diagnosis) {
        $identityObservation = ($finalMessageIdentity.mismatches | ForEach-Object {
                '{0}: expected={1}; received={2}' -f [string]$_.field, [string]$_.expected, [string]$_.received
            }) -join '; '
        $diagnosis = New-DispatchInspectDiagnosis -ReasonCode 'FinalMessageIdentityMismatch' -Observation $identityObservation -EventStreamPath $eventPath -ErrorStreamPath $ErrorStreamPath -RawEventLines @($rawEventLines.ToArray()) -Stderr $inspectStderr
        $diagnosis.identity_mismatches = @($finalMessageIdentity.mismatches)
    }
    if ($TaskType -eq 'advisor-consult') {
        $inspectEvidencePath = $EvidencePackPath
        if ([string]::IsNullOrWhiteSpace($inspectEvidencePath)) {
            $inspectEvidencePath = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'evidence_pack_path')
        }
        if ([string]::IsNullOrWhiteSpace($inspectEvidencePath)) {
            throw 'EvidencePackMissing：advisor-consult Inspect 缺少 EvidencePackPath。'
        }
        $evidencePackInfo = Test-AdvisorEvidencePack -Path $inspectEvidencePath -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        $evidenceHashRecordPath = Join-Path -Path (Split-Path -Parent $eventPath) -ChildPath ('evidence-pack-' + $DispatchSlug + '.sha256')
        $evidenceLengthRecordPath = Join-Path -Path (Split-Path -Parent $eventPath) -ChildPath ('evidence-pack-' + $DispatchSlug + '.length')
        if (-not (Test-Path -LiteralPath $evidenceHashRecordPath -PathType Leaf)) {
            throw 'EvidencePackInvalid：evidence pack 缺少 Start SHA-256 紀錄。'
        }
        $expectedHash = (Get-Content -LiteralPath $evidenceHashRecordPath -Raw -Encoding UTF8).Trim()
        if ([string]::IsNullOrWhiteSpace($expectedHash) -or -not [string]::Equals($expectedHash, $evidencePackInfo.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'EvidencePackInlineMismatch：evidence pack SHA-256 在 Start 與 Inspect 之間變更。'
        }
        if (-not (Test-Path -LiteralPath $evidenceLengthRecordPath -PathType Leaf)) {
            throw 'EvidencePackInvalid：evidence pack 缺少 Start length 紀錄。'
        }
        $expectedLengthText = (Get-Content -LiteralPath $evidenceLengthRecordPath -Raw -Encoding UTF8).Trim()
        $expectedLength = [int64]0
        if (-not [int64]::TryParse($expectedLengthText, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$expectedLength) -or $expectedLength -ne [int64]$evidencePackInfo.length) {
            throw 'EvidencePackInlineMismatch：evidence pack length 在 Start 與 Inspect 之間變更。'
        }
        $requiredOutputGate = Test-RequiredOutputSections -Message $finalMessage -RequiredOutput $evidencePackInfo.required_output
        if (-not $requiredOutputGate.valid) {
            $outputValid = $false
            if ($null -eq $diagnosis) {
                $diagnosis = New-DispatchInspectDiagnosis -ReasonCode 'EvidencePackRequiredOutputInvalid' -Observation '最後訊息缺少 evidence pack 宣告的 required output section 或 body。' -EventStreamPath $eventPath -ErrorStreamPath $ErrorStreamPath -RawEventLines @($rawEventLines.ToArray()) -Stderr $inspectStderr
            }
        }
    }
    $threadRelay = $null
    if (-not [string]::IsNullOrWhiteSpace($ThreadIdPath)) {
        $threadRelay = Set-ThreadIdFromEventStream -EventPath $eventPath -ThreadPath (Resolve-AbsolutePath -Path $ThreadIdPath) -RequireThreadId
    }

    $executionResult = [ordered]@{
        completed        = $lastEventType -eq 'turn.completed'
        success          = $lastEventType -eq 'turn.completed' -and [int]$ProcessExitCode -eq 0 -and $outputValid
        lastEventType    = $lastEventType
        processExitCode  = [int]$ProcessExitCode
        turnFailedReason = $turnFailedReason
        outputValid      = $outputValid
    }
    if ($null -ne $serviceRejectionEvidence) {
        $executionResult.service_rejection = $serviceRejectionEvidence
        $executionResult.retry_allowed = $false
        $executionResult.success = $false
        if ([string]::IsNullOrWhiteSpace([string]$executionResult.turnFailedReason)) {
            $executionResult.turnFailedReason = 'quota service rejection'
        }
        if ($null -eq $diagnosis -or [string](Get-OptionalObjectProperty -Object $diagnosis -Name 'reason_code') -ne 'QuotaServiceRejected') {
            $diagnosis = New-DispatchInspectDiagnosis -ReasonCode 'QuotaServiceRejected' -Observation '事件流包含 quota service rejection，禁止自動 retry。' -EventStreamPath $eventPath -ErrorStreamPath $ErrorStreamPath -RawEventLines @($rawEventLines.ToArray()) -Stderr $inspectStderr
        }
    }
    $scopePlan = Read-ScopePlanFile -Path $ScopePlanPath
    $advisorCompletionPartition = $null
    if ($TaskType -eq 'advisor-consult') {
        $advisorCompletionPartition = Get-AdvisorCompletionPartition -Message $finalMessage -SelectedUnits @($scopePlan.selected_units) -DeferredUnits @($scopePlan.deferred_units)
        if ($advisorCompletionPartition.status -eq 'invalid') {
            $outputValid = $false
            $executionResult.outputValid = $false
            $executionResult.success = $false
            if ($null -eq $diagnosis) {
                $diagnosis = New-DispatchInspectDiagnosis -ReasonCode 'AdvisorCompletedUnitsInvalid' -Observation ([string]$advisorCompletionPartition.reason) -EventStreamPath $eventPath -ErrorStreamPath $ErrorStreamPath -RawEventLines @($rawEventLines.ToArray()) -Stderr $inspectStderr
            }
        }
    }
    $snapshotFailure = $null
    $beforeSnapshotSha256Value = $null
    if ([string]::IsNullOrWhiteSpace($QuotaBeforePath)) {
        $snapshotFailure = 'Inspect 缺少 before quota snapshot。'
    }
    try {
        $resolvedQuotaBeforePath = Resolve-AbsolutePath -Path $QuotaBeforePath
        $recordQuotaBeforePath = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'quota_before_path')
        if ([string]::IsNullOrWhiteSpace($recordQuotaBeforePath) -or
            -not [string]::Equals($resolvedQuotaBeforePath, (Resolve-AbsolutePath -Path $recordQuotaBeforePath), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Inspect quota before path 與 RunRecord 不一致。'
        }
        $beforeSnapshot = Read-QuotaSnapshot -Path $QuotaBeforePath
        $beforeSnapshotSha256Value = Get-FileSha256 -Path $QuotaBeforePath
        $recordQuotaBeforeSha256 = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'quota_before_sha256')
        if ($recordQuotaBeforeSha256 -notmatch '^[a-fA-F0-9]{64}$' -or
            -not [string]::Equals($beforeSnapshotSha256Value, $recordQuotaBeforeSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Inspect quota before SHA-256 與 RunRecord 不一致。'
        }
        if ($null -ne $dispatchInspectBinding -and
            -not [string]::Equals($beforeSnapshotSha256Value, [string]$dispatchInspectBinding.QuotaBeforeSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Inspect quota before SHA-256 與 Dispatch result 不一致。'
        }
    }
    catch {
        $snapshotFailure = 'Inspect before quota snapshot 無效：' + $_.Exception.Message
    }
    $recordQuotaAfterPath = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'quota_after_path')
    $recordQuotaAfterSha256 = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'quota_after_sha256')
    $afterSnapshotPathValue = if ([string]::IsNullOrWhiteSpace($recordQuotaAfterPath)) { $QuotaAfterPath } else { $recordQuotaAfterPath }
    $afterSnapshotSha256Value = $null
    try {
        if ([string]::IsNullOrWhiteSpace($afterSnapshotPathValue) -and (-not [string]::IsNullOrWhiteSpace($CodexHome) -or -not [string]::IsNullOrWhiteSpace($env:CODEX_HOME))) {
            $historyRoot = Join-Path -Path (Resolve-AbsolutePath -Path $ExecutionRoot) -ChildPath '.local\ai-sessions\history'
            $afterSnapshotPathValue = Get-OrCreateQuotaSnapshot -Path $null -CodexHome $CodexHome -HistoryRoot $historyRoot -Purpose 'after' -Required
        }
        if (-not [string]::IsNullOrWhiteSpace($afterSnapshotPathValue)) {
            $afterSnapshotPathValue = Resolve-AbsolutePath -Path $afterSnapshotPathValue
            if (-not (Test-PathWithinRoot -Path $afterSnapshotPathValue -Root $ExecutionRoot) -and -not (Test-PathWithinRoot -Path $afterSnapshotPathValue -Root $SourceRoot)) {
                throw "Inspect after quota snapshot 超出 source／execution root：$afterSnapshotPathValue"
            }
            $afterSnapshotSha256Value = Get-FileSha256 -Path $afterSnapshotPathValue
            if (-not [string]::IsNullOrWhiteSpace($recordQuotaAfterSha256) -and
                ($recordQuotaAfterSha256 -notmatch '^[a-fA-F0-9]{64}$' -or -not [string]::Equals($afterSnapshotSha256Value, $recordQuotaAfterSha256, [StringComparison]::OrdinalIgnoreCase))) {
                throw 'Inspect after quota SHA-256 與 RunRecord 不一致。'
            }
        }
    }
    catch {
        $snapshotFailure = 'Inspect after quota snapshot 取得失敗：' + $_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($afterSnapshotPathValue)) {
        $snapshotFailure = 'Inspect 缺少 after quota snapshot。'
    }
    try {
        $afterSnapshot = Read-QuotaSnapshot -Path $afterSnapshotPathValue
    }
    catch {
        $snapshotFailure = 'Inspect after quota snapshot 無效：' + $_.Exception.Message
    }
    $interruptionStatus = [ordered]@{
        applied = $true
        safePointPresent = -not [string]::IsNullOrWhiteSpace((Get-LatestSafePointMessage -EventPath $eventPath -TaskType $TaskType))
        sessionMode = $SessionMode
    }
    $budgetMonitor = $null
    $budgetMonitorRejected = $false
    $budgetMonitorRejectionReason = ''
    if (-not [string]::IsNullOrWhiteSpace($BudgetMonitorPath)) {
        $budgetMonitorPathValue = Resolve-AbsolutePath -Path $BudgetMonitorPath
        if (-not (Test-Path -LiteralPath $budgetMonitorPathValue -PathType Leaf)) {
            $budgetMonitorRejected = $true
            $budgetMonitorRejectionReason = "BudgetMonitor 檔案不存在或不是檔案：$budgetMonitorPathValue"
        }
        else {
            try {
                $budgetMonitor = @(Get-Content -LiteralPath $budgetMonitorPathValue -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop })
                if ($budgetMonitor.Count -eq 0) {
                    $budgetMonitorRejected = $true
                    $budgetMonitorRejectionReason = "BudgetMonitor 檔案沒有可解析的 JSON：$budgetMonitorPathValue"
                }
            }
            catch {
                $budgetMonitorRejected = $true
                $budgetMonitorRejectionReason = "BudgetMonitor 無法讀取或解析 JSON：$budgetMonitorPathValue；$($_.Exception.Message)"
                $budgetMonitor = $null
            }
        }
    }
    foreach ($monitorRecord in @($budgetMonitor)) {
        $monitorState = [string](Get-OptionalObjectProperty -Object $monitorRecord -Name 'state')
        $monitorEvent = [string](Get-OptionalObjectProperty -Object $monitorRecord -Name 'event')
        $terminalSnapshotFailure = $monitorEvent -eq 'monitor.snapshot-failed' -and
            ($monitorState -ne 'retrying' -or [bool](Get-OptionalObjectProperty -Object $monitorRecord -Name 'terminal_snapshot'))
        if ($monitorState -eq 'AbortedByBudget' -or $monitorState -eq 'SnapshotFailed' -or $monitorEvent -eq 'monitor.terminal-budget-exceeded' -or $terminalSnapshotFailure) {
            $budgetMonitorRejected = $true
            if ([string]::IsNullOrWhiteSpace($budgetMonitorRejectionReason)) {
                if ($monitorState -eq 'SnapshotFailed' -or $terminalSnapshotFailure) {
                    $budgetMonitorRejectionReason = 'BudgetMonitor 偵測到 snapshot 失敗。'
                }
                else {
                    $budgetMonitorRejectionReason = 'BudgetMonitor 偵測到行程結束後超出 primary budget。'
                }
            }
            break
        }
    }
    if ($budgetMonitorRejected) {
        $executionResult.success = $false
        $executionResult.budgetMonitorRejected = $true
        if ([string]::IsNullOrWhiteSpace($executionResult.turnFailedReason)) {
            $executionResult.turnFailedReason = $budgetMonitorRejectionReason
        }
    }
    $existingSandboxEvidence = Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'sandbox_acl_evidence'
    if ($null -ne $existingSandboxEvidence) {
        $normalCompletion = $lastEventType -eq 'turn.completed' -and [int]$ProcessExitCode -eq 0
        $inspectSandboxEvidence = Get-SandboxAclInspectEvidence -Record $inspectRun.Record -ExecutionRoot $ExecutionRoot -NormalCompletion $normalCompletion
        $inspectRun.Record.sandbox_acl_evidence = $inspectSandboxEvidence
        $sandboxAclEvidence = $inspectSandboxEvidence
        $null = Write-DispatchRunRecord -Record $inspectRun.Record -Update
    }
    $advisorReportPathValue = $AdvisorConsultReportPath
    if ($TaskType -eq 'advisor-consult') {
        if ($null -eq $scopePlan -or $scopePlan.task_type -ne 'advisor-consult') {
            throw 'advisor-consult Inspect 缺少一致的 ScopePlan。'
        }
        if ([string]::IsNullOrWhiteSpace($advisorReportPathValue)) {
            throw 'advisor-consult Inspect 必須提供 AdvisorConsultReportPath。'
        }
        $advisorReportPathValue = Get-AdvisorConsultReportPath -Path $advisorReportPathValue -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        $evidencePathValue = $evidencePackInfo.path
        $advisorStatus = if ($executionResult.success) { 'completed' } else { 'failed' }
        $advisorReportWrittenPath = Write-AdvisorConsultReport -Path $advisorReportPathValue -LineSlug $LineSlug -DispatchSlug $DispatchSlug -EvidencePackPath $evidencePathValue -EvidencePackSha256 $evidencePackInfo.sha256 -EvidencePackLength $evidencePackInfo.length -FinalMessage $finalMessage -Status $advisorStatus -BudgetMonitor $budgetMonitor -RequiredOutputGate $requiredOutputGate -ScopePlan $scopePlan -InterruptionStatus $interruptionStatus
    }

    $result = [ordered]@{
        operation        = 'Inspect'
        status           = 'inspected'
        runId            = $inspectRun.Record.run_id
        runRecordPath    = $inspectRun.Path
        lastMessageConsistency = $lastMessageConsistency
        finalMessageSource = 'event-stream'
        eventStreamPath  = $eventPath
        processExitCode  = [int]$ProcessExitCode
        process_exit_code = [int]$ProcessExitCode
        eventCount       = $events.Count
        lastEventType    = $lastEventType
        threadId         = $threadId
        completed        = $executionResult.completed
        success          = $executionResult.success
        turnFailedReason = $executionResult.turnFailedReason
        finalMessage     = $finalMessage
        finalMessageIdentity = $finalMessageIdentity
        outputValid      = $outputValid
        modelEvidence    = $modelEvidence
        reasoningEffortEvidence = $modelEvidence.reasoning_effort
        runtimeRolloutPaths = $runtimeEvidence.rollout_paths
        requiredOutput   = $requiredOutputGate
        usage            = $usage
        eventEvidence   = $eventEvidence
        service_rejection = $serviceRejectionEvidence
        retry_allowed   = if ($null -eq $serviceRejectionEvidence) { $null } else { $false }
        threadIdPath     = $ThreadIdPath
        threadRelay      = $threadRelay
        quotaBeforePath  = $QuotaBeforePath
        quotaBeforeSha256 = $beforeSnapshotSha256Value
        quotaAfterPath   = $afterSnapshotPathValue
        quotaAfterSha256 = $afterSnapshotSha256Value
        dispatchResultPath = $dispatchResultPathValue
        processExitCodeSource = $processExitCodeSource
        processExitCodeSidecarPath = $processExitCodeSidecarPath
        processExitCodeSidecarSha256 = $processExitCodeSidecarSha256
        afterSnapshot    = if ($null -eq $afterSnapshot) { $null } else { $afterSnapshot.values }
        snapshotFailure  = if ([string]::IsNullOrWhiteSpace($snapshotFailure)) { $null } else { $snapshotFailure }
        scopePlan        = $scopePlan
        budgetMonitorRejected = $budgetMonitorRejected
        advisorConsultReportPath = if ($TaskType -eq 'advisor-consult') { $advisorReportWrittenPath } else { $null }
         diagnosis        = $diagnosis
         sandboxAclEvidence = $sandboxAclEvidence
         stderr           = $inspectStderr
    }
    return $result
}

function Get-NameOnlyList {
    param(
        [Parameter(Mandatory)]
        [psobject]$Result
    )

    if ($Result.ExitCode -ne 0) {
        throw "Git 差異蒐集失敗，exit code $($Result.ExitCode)：$($Result.StdErr.Trim())"
    }

    return @(Get-GitOutputLines -Text $Result.StdOut | Sort-Object -Unique)
}

function Convert-ReportPathForComparison {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$DispatchRoot
    )

    $normalized = $Path.Trim().Trim('`', '"', "'").Replace('\', '/')
    if ([System.IO.Path]::IsPathRooted($normalized) -and (Test-PathWithinRoot -Path $normalized -Root $DispatchRoot)) {
        return (Get-RelativePathFromRoot -Path $normalized -Root $DispatchRoot).Replace('\', '/')
    }
    return $normalized
}

function Convert-ComparisonPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $normalized = $Path.Trim().Trim('`', '"', "'").Replace('\', '/')
    while ($normalized.StartsWith('./', [System.StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(2)
    }
    return $normalized
}


function Split-MarkdownTableRow {
    param(
        [Parameter(Mandatory)]
        [string]$Line
    )

    $cells = New-Object 'System.Collections.Generic.List[string]'
    $current = ''
    $characters = $Line.ToCharArray()
    for ($index = 0; $index -lt $characters.Length; $index++) {
        $character = [string]$characters[$index]
        if ($character -eq '\' -and $index + 1 -lt $characters.Length -and [string]$characters[$index + 1] -eq '|') {
            $current += '|'
            $index++
            continue
        }
        if ($character -eq '|') {
            $cells.Add($current)
            $current = ''
            continue
        }
        $current += $character
    }
    $cells.Add($current)

    $trimmedLine = $Line.Trim()
    if ($trimmedLine.StartsWith('|') -and $cells.Count -gt 0 -and $cells[0] -eq '') {
        $cells.RemoveAt(0)
    }
    if ($trimmedLine.EndsWith('|') -and $cells.Count -gt 0 -and $cells[$cells.Count - 1] -eq '') {
        $cells.RemoveAt($cells.Count - 1)
    }

    return @($cells | ForEach-Object { $_.Trim() })
}

function Get-TrimmedSectionLines {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Section
    )

    $rawLines = [regex]::Split($Section, '\r?\n')
    $firstIndex = 0
    while ($firstIndex -lt $rawLines.Count -and [string]::IsNullOrWhiteSpace($rawLines[$firstIndex])) {
        $firstIndex++
    }

    $lastIndex = $rawLines.Count - 1
    while ($lastIndex -ge $firstIndex -and [string]::IsNullOrWhiteSpace($rawLines[$lastIndex])) {
        $lastIndex--
    }

    $lines = New-Object 'System.Collections.Generic.List[object]'
    for ($index = $firstIndex; $index -le $lastIndex; $index++) {
        $lines.Add([pscustomobject]@{
                Text       = [string]$rawLines[$index]
                LineNumber = $index + 1
            })
    }

    return @($lines.ToArray())
}

function Add-InvalidSectionContent {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$InvalidSectionContent,

        [Parameter(Mandatory)]
        [string]$Heading,

        [Parameter(Mandatory)]
        [string]$LineNumber,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Line
    )

    $sectionPrefix = $Heading + '#'
    foreach ($existing in $InvalidSectionContent) {
        if ($existing.StartsWith($sectionPrefix, [System.StringComparison]::Ordinal)) {
            return
        }
    }

    $displayLine = if ($Line.Length -gt 80) { $Line.Substring(0, 80) } else { $Line }
    $InvalidSectionContent.Add(('{0}#{1}={2}' -f $Heading, $LineNumber, $displayLine))
}

function Get-RequirementIdsFromSummary {
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$SummaryPath
    )

    $summaryIds = New-Object 'System.Collections.Generic.List[int]'
    $missingSections = New-Object 'System.Collections.Generic.List[string]'
    $invalidSummaryHeaders = New-Object 'System.Collections.Generic.List[string]'
    $invalidSummaryRows = New-Object 'System.Collections.Generic.List[string]'
    $emptySummaryFieldIds = New-Object 'System.Collections.Generic.List[string]'
    $invalidSectionContent = New-Object 'System.Collections.Generic.List[string]'
    $duplicateSummarySections = New-Object 'System.Collections.Generic.List[string]'
    $emptySectionCount = 0
    $expectedHeaders = @('#', '項目', '內容')
    $fieldNames = @('#', '項目', '內容')

    foreach ($heading in @('程式面項目', '功能面項目')) {
        $headingPattern = '(?m)^##[ \t]+' + [regex]::Escape($heading) + '[ \t]*\r?$'
        $headingMatches = [regex]::Matches($Content, $headingPattern)
        if ($headingMatches.Count -eq 0) {
            $missingSections.Add($heading)
            continue
        }

        if ($headingMatches.Count -gt 1) {
            $duplicateSummarySections.Add(('{0}:{1}={2}' -f [System.IO.Path]::GetFileName($SummaryPath), $heading, $headingMatches.Count))
        }

        $sectionPattern = '(?ms)^##[ \t]+' + [regex]::Escape($heading) + '[ \t]*\r?\n(?<section>.*?)(?=^##[ \t]|\z)'
        $sectionMatches = [regex]::Matches($Content, $sectionPattern)
        foreach ($sectionMatch in $sectionMatches) {
            $sectionLabel = '{0}:{1}' -f [System.IO.Path]::GetFileName($SummaryPath), $heading
            $sectionLines = @(Get-TrimmedSectionLines -Section $sectionMatch.Groups['section'].Value)
            if ($sectionLines.Count -eq 1 -and [string]::Equals($sectionLines[0].Text.Trim(), '無', [System.StringComparison]::Ordinal)) {
                $emptySectionCount++
                continue
            }

            if ($sectionLines.Count -eq 0) {
                $invalidSummaryHeaders.Add($heading)
                Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading $sectionLabel -LineNumber 'EOF' -Line '缺少表格資料列'
                continue
            }

            $headerLine = $sectionLines[0]
            $headerCells = @(Split-MarkdownTableRow -Line $headerLine.Text)
            $headerValid = $headerCells.Count -eq $expectedHeaders.Count
            if ($headerValid) {
                for ($headerIndex = 0; $headerIndex -lt $expectedHeaders.Count; $headerIndex++) {
                    if (-not [string]::Equals($headerCells[$headerIndex], $expectedHeaders[$headerIndex], [System.StringComparison]::Ordinal)) {
                        $headerValid = $false
                        break
                    }
                }
            }
            if (-not $headerValid) {
                $invalidSummaryHeaders.Add($heading)
                Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading $sectionLabel -LineNumber ([string]$headerLine.LineNumber) -Line $headerLine.Text
            }

            $separatorValid = $false
            if ($sectionLines.Count -gt 1) {
                $separatorLine = $sectionLines[1]
                $separatorCells = @(Split-MarkdownTableRow -Line $separatorLine.Text)
                $separatorValid = $separatorCells.Count -eq $expectedHeaders.Count
                if ($separatorValid) {
                    foreach ($separatorCell in $separatorCells) {
                        if ($separatorCell -notmatch '^:?-{3,}:?$') {
                            $separatorValid = $false
                            break
                        }
                    }
                }
                if (-not $separatorValid) {
                    $invalidSummaryHeaders.Add($heading)
                    Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading $sectionLabel -LineNumber ([string]$separatorLine.LineNumber) -Line $separatorLine.Text
                }
            }
            else {
                $invalidSummaryHeaders.Add($heading)
                Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading $sectionLabel -LineNumber 'EOF' -Line '缺少表格分隔列'
            }

            $dataRowIndex = 0
            if ($separatorValid) {
                for ($lineIndex = 2; $lineIndex -lt $sectionLines.Count; $lineIndex++) {
                    $dataLine = $sectionLines[$lineIndex]
                    if ([string]::IsNullOrWhiteSpace($dataLine.Text)) {
                        Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading $sectionLabel -LineNumber ([string]$dataLine.LineNumber) -Line $dataLine.Text
                        continue
                    }

                    $dataRowIndex++
                    $dataCells = @(Split-MarkdownTableRow -Line $dataLine.Text)
                    if ($dataCells.Count -le 1 -or $dataLine.Text.IndexOf('|') -lt 0) {
                        Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading $sectionLabel -LineNumber ([string]$dataLine.LineNumber) -Line $dataLine.Text
                        continue
                    }

                    if ($dataCells.Count -ne $expectedHeaders.Count) {
                        $invalidSummaryRows.Add(('{0}#{1}' -f $heading, $dataRowIndex))
                        Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading $sectionLabel -LineNumber ([string]$dataLine.LineNumber) -Line $dataLine.Text
                        continue
                    }

                    $idCell = $dataCells[0]
                    $rowLabel = if ($idCell -match '^\d+$') { $idCell } else { 'row' + $dataRowIndex }
                    $rowValid = $true
                    for ($fieldIndex = 0; $fieldIndex -lt $dataCells.Count; $fieldIndex++) {
                        if ([string]::IsNullOrWhiteSpace($dataCells[$fieldIndex])) {
                            $emptySummaryFieldIds.Add(('{0}#{1}:{2}' -f $heading, $rowLabel, $fieldNames[$fieldIndex]))
                            $rowValid = $false
                        }
                    }

                    if ($idCell -match '^\d+$') {
                        $summaryIds.Add([int]$idCell)
                    }
                    else {
                        $invalidSummaryRows.Add(('{0}#{1}' -f $heading, $dataRowIndex))
                        $rowValid = $false
                    }

                    if (-not $rowValid) {
                        Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading $sectionLabel -LineNumber ([string]$dataLine.LineNumber) -Line $dataLine.Text
                    }
                }
            }

            if ($dataRowIndex -eq 0) {
                $invalidSummaryHeaders.Add($heading)
                Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading $sectionLabel -LineNumber 'EOF' -Line '缺少表格資料列'
            }
        }
    }

    if ($missingSections.Count -gt 0) {
        throw "需求摘要缺少必要節。missingSections=$($missingSections -join ','); summaryPath=$SummaryPath"
    }

    $duplicateSummaryIds = @($summaryIds | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { [int]$_.Name } | Sort-Object -Unique)
    $invalidSummaryHeaders = @($invalidSummaryHeaders | Sort-Object -Unique)
    $invalidSummaryRows = @($invalidSummaryRows | Sort-Object -Unique)
    $emptySummaryFieldIds = @($emptySummaryFieldIds | Sort-Object -Unique)
    $invalidSectionContent = @($invalidSectionContent | Sort-Object -Unique)
    $duplicateSummarySections = @($duplicateSummarySections | Sort-Object -Unique)
    if ($duplicateSummarySections.Count -gt 0 -or
        $invalidSectionContent.Count -gt 0 -or
        $invalidSummaryHeaders.Count -gt 0 -or
        $invalidSummaryRows.Count -gt 0 -or
        $emptySummaryFieldIds.Count -gt 0) {
        throw "需求摘要結構不一致。duplicateSummarySections=$($duplicateSummarySections -join ','); invalidSectionContent=$($invalidSectionContent -join ','); invalidSummaryHeader=$($invalidSummaryHeaders -join ','); invalidSummaryRows=$($invalidSummaryRows -join ','); emptySummaryFieldIds=$($emptySummaryFieldIds -join ','); duplicateSummaryIds=$($duplicateSummaryIds -join ','); summaryPath=$SummaryPath"
    }
    if ($summaryIds.Count -eq 0) {
        throw "需求摘要未解析到任何需求編號：$SummaryPath"
    }
    if ($duplicateSummaryIds.Count -gt 0) {
        throw "需求摘要編號重複。duplicateSummaryIds=$($duplicateSummaryIds -join ','); summaryPath=$SummaryPath"
    }

    return @($summaryIds | Sort-Object -Unique)
}

function Get-RequirementTableRows {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Section,

        [Parameter(Mandatory)]
        [string]$ReportName,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$InvalidColumnCountRows,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$EmptyFieldIds,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$InvalidRequirementCells,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$InvalidHeader

        ,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$InvalidSectionContent

        ,

        [AllowNull()]
        [System.Collections.Generic.List[string]]$InvalidStatusFields
    )

    $expectedHeaders = @('需求', '驗收方向', 'T-code', '實際行為', '證據', '狀態')
    $fieldNames = @('需求', '驗收方向', 'T-code', '實際行為', '證據', '狀態')
    $sectionLabel = '{0}:需求對照' -f $ReportName
    $sectionLines = @(Get-TrimmedSectionLines -Section $Section)
    if ($sectionLines.Count -lt 2) {
        $InvalidHeader.Add($ReportName + ':header-or-separator')
        if ($sectionLines.Count -eq 1) {
            Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber ([string]$sectionLines[0].LineNumber) -Line $sectionLines[0].Text
        }
        else {
            Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber 'EOF' -Line '缺少需求對照表格'
        }
        return @()
    }

    $headerLine = $sectionLines[0]
    $headerCells = @(Split-MarkdownTableRow -Line $headerLine.Text)
    $headerValid = $headerCells.Count -eq $expectedHeaders.Count
    if ($headerValid) {
        for ($index = 0; $index -lt $expectedHeaders.Count; $index++) {
            if (-not [string]::Equals($headerCells[$index], $expectedHeaders[$index], [System.StringComparison]::Ordinal)) {
                $headerValid = $false
                break
            }
        }
    }
    if (-not $headerValid) {
        $InvalidHeader.Add($ReportName + ':header')
        Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber ([string]$headerLine.LineNumber) -Line $headerLine.Text
    }

    $separatorLine = $sectionLines[1]
    $separatorCells = @(Split-MarkdownTableRow -Line $separatorLine.Text)
    $separatorValid = $separatorCells.Count -eq $expectedHeaders.Count
    if ($separatorValid) {
        foreach ($separatorCell in $separatorCells) {
            if ($separatorCell -notmatch '^:?-{3,}:?$') {
                $separatorValid = $false
                break
            }
        }
    }
    if (-not $separatorValid) {
        $InvalidHeader.Add($ReportName + ':separator')
        Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber ([string]$separatorLine.LineNumber) -Line $separatorLine.Text
    }

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $dataRowIndex = 0
    for ($lineIndex = 2; $lineIndex -lt $sectionLines.Count; $lineIndex++) {
        $line = $sectionLines[$lineIndex]
        if ([string]::IsNullOrWhiteSpace($line.Text)) {
            Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber ([string]$line.LineNumber) -Line $line.Text
            continue
        }

        $dataRowIndex++
        $cells = @(Split-MarkdownTableRow -Line $line.Text)
        if ($cells.Count -ne $expectedHeaders.Count) {
            $InvalidColumnCountRows.Add(('{0}#{1}' -f $ReportName, $dataRowIndex))
            Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber ([string]$line.LineNumber) -Line $line.Text
            continue
        }

        $requirementCell = $cells[0]
        $requirementLabel = if ($requirementCell -match '^#\d+$') { $requirementCell } else { 'row' + $dataRowIndex }
        $rowValid = $true
        for ($index = 0; $index -lt $cells.Count; $index++) {
            if ([string]::IsNullOrWhiteSpace($cells[$index])) {
                $EmptyFieldIds.Add(('{0}:{1}' -f $requirementLabel, $fieldNames[$index]))
                $rowValid = $false
            }
        }

        if ($requirementCell -notmatch '^#\d+$') {
            $InvalidRequirementCells.Add(('{0}#{1}:{2}' -f $ReportName, $dataRowIndex, $requirementCell))
            Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber ([string]$line.LineNumber) -Line $line.Text
            continue
        }

        $id = [int]$requirementCell.Substring(1)
        $status = $cells[5]
        if ($status -notin @('已交付', '部分交付', '未交付', '排除（design.md §8）')) {
            $rowValid = $false
            if ($null -ne $InvalidStatusFields) {
                $InvalidStatusFields.Add(('{0}#{1}:狀態={2}' -f $ReportName, $dataRowIndex, $status))
            }
        }
        if (-not $rowValid) {
            Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading '需求對照' -LineNumber ([string]$line.LineNumber) -Line $line.Text
        }
        $rows.Add([pscustomobject]@{
                Id       = $id
                Evidence = $cells[4]
                Status   = $status
            })
    }

    if ($dataRowIndex -eq 0) {
        Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber 'EOF' -Line '缺少需求對照資料列'
    }

    return @($rows.ToArray())
}

function Get-RequirementMap {
    param(
        [AllowEmptyString()]
        [string]$RequirementSummaryPath,

        [Parameter(Mandatory)]
        [string[]]$ReportPath
    )

    $summaryDisplayPath = if ([string]::IsNullOrWhiteSpace($RequirementSummaryPath)) { '<empty>' } else { $RequirementSummaryPath }
    if ([string]::IsNullOrWhiteSpace($RequirementSummaryPath)) {
        throw "workflow Collect 必須提供 RequirementSummaryPath：$summaryDisplayPath"
    }

    $summaryFullPath = Resolve-AbsolutePath -Path $RequirementSummaryPath
    if (-not (Test-Path -LiteralPath $summaryFullPath -PathType Leaf)) {
        throw "找不到需求摘要：$summaryFullPath"
    }

    $summarySha256Before = Get-FileSha256 -Path $summaryFullPath
    $summaryContent = Get-Content -LiteralPath $summaryFullPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($summaryContent)) {
        throw "需求摘要為空：$summaryFullPath"
    }

    $requirementIds = @(Get-RequirementIdsFromSummary -Content $summaryContent -SummaryPath $summaryFullPath)
    $summarySha256After = Get-FileSha256 -Path $summaryFullPath
    if (-not [string]::Equals($summarySha256Before, $summarySha256After, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "需求摘要在 Collect 解析期間變更。contractVersion=$script:WorkflowCollectContractVersion; summaryPath=$summaryFullPath; beforeSha256=$summarySha256Before; afterSha256=$summarySha256After"
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $invalidColumnCountRows = New-Object 'System.Collections.Generic.List[string]'
    $emptyFieldIds = New-Object 'System.Collections.Generic.List[string]'
    $invalidRequirementCells = New-Object 'System.Collections.Generic.List[string]'
    $invalidStatusFields = New-Object 'System.Collections.Generic.List[string]'
    $invalidHeader = New-Object 'System.Collections.Generic.List[string]'
    $invalidSectionContent = New-Object 'System.Collections.Generic.List[string]'
    $duplicateRequirementSections = New-Object 'System.Collections.Generic.List[string]'
    $reportEvidence = New-Object 'System.Collections.Generic.List[object]'
    $statusCounts = [ordered]@{
        '已交付'          = 0
        '部分交付'        = 0
        '未交付'          = 0
        '排除（design.md §8）' = 0
    }
    $validStatuses = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($status in $statusCounts.Keys) {
        [void]$validStatuses.Add([string]$status)
    }

    foreach ($report in @($ReportPath)) {
        $reportFullPath = Resolve-AbsolutePath -Path $report
        if (-not (Test-Path -LiteralPath $reportFullPath -PathType Leaf)) {
            throw "找不到結案報告：$reportFullPath"
        }

        $reportSha256Before = Get-FileSha256 -Path $reportFullPath
        $reportContent = Get-Content -LiteralPath $reportFullPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($reportContent)) {
            throw "結案報告為空：$reportFullPath"
        }

        $reportName = [System.IO.Path]::GetFileName($reportFullPath)
        $requirementHeadingMatches = [regex]::Matches($reportContent, '(?m)^##[ \t]+需求對照[ \t]*\r?$')
        if ($requirementHeadingMatches.Count -eq 0) {
            throw "結案報告缺少需求對照節：$reportFullPath"
        }

        if ($requirementHeadingMatches.Count -gt 1) {
            $duplicateRequirementSections.Add(('{0}={1}' -f $reportName, $requirementHeadingMatches.Count))
            $reportSha256After = Get-FileSha256 -Path $reportFullPath
            if (-not [string]::Equals($reportSha256Before, $reportSha256After, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "結案報告在 Collect 解析期間變更。contractVersion=$script:WorkflowCollectContractVersion; reportPath=$reportFullPath; beforeSha256=$reportSha256Before; afterSha256=$reportSha256After"
            }
            $reportEvidence.Add([ordered]@{ path = $reportFullPath; sha256 = $reportSha256After; row_count = 0 })
            continue
        }

        $requirementMatch = [regex]::Match($reportContent, '(?ms)^##[ \t]+需求對照[ \t]*\r?\n(?<section>.*?)(?=^##[ \t]|\z)')
        if (-not $requirementMatch.Success) {
            throw "結案報告缺少需求對照節：$reportFullPath"
        }

        $reportRows = @(Get-RequirementTableRows -Section $requirementMatch.Groups['section'].Value -ReportName $reportName -InvalidColumnCountRows $invalidColumnCountRows -EmptyFieldIds $emptyFieldIds -InvalidRequirementCells $invalidRequirementCells -InvalidHeader $invalidHeader -InvalidSectionContent $invalidSectionContent -InvalidStatusFields $invalidStatusFields)
        foreach ($row in $reportRows) {
            $status = $row.Status
            if ($validStatuses.Contains($status)) {
                $statusCounts[$status] = [int]$statusCounts[$status] + 1
            }
            $rows.Add($row)
        }
        $reportSha256After = Get-FileSha256 -Path $reportFullPath
        if (-not [string]::Equals($reportSha256Before, $reportSha256After, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "結案報告在 Collect 解析期間變更。contractVersion=$script:WorkflowCollectContractVersion; reportPath=$reportFullPath; beforeSha256=$reportSha256Before; afterSha256=$reportSha256After"
        }
        $reportEvidence.Add([ordered]@{ path = $reportFullPath; sha256 = $reportSha256After; row_count = $reportRows.Count })
    }

    $reportedIds = @($rows | ForEach-Object { $_.Id } | Sort-Object -Unique)
    $missingRequirementIds = @($requirementIds | Where-Object { $reportedIds -notcontains $_ } | Sort-Object)
    $duplicateRequirementIds = @($rows | Group-Object -Property Id | Where-Object { $_.Count -gt 1 } | ForEach-Object { [int]$_.Name } | Sort-Object)
    $unknownRequirementIds = @($reportedIds | Where-Object { $requirementIds -notcontains $_ } | Sort-Object)
    $invalidStatusIds = @($rows | Where-Object { -not $validStatuses.Contains($_.Status) } | ForEach-Object { $_.Id } | Sort-Object -Unique)
    $duplicateRequirementSections = @($duplicateRequirementSections | Sort-Object -Unique)
    $invalidStatusFields = @($invalidStatusFields | Sort-Object -Unique)
    $invalidSectionContent = @($invalidSectionContent | Sort-Object -Unique)

    if ($duplicateRequirementSections.Count -gt 0 -or
        $invalidSectionContent.Count -gt 0 -or
        $missingRequirementIds.Count -gt 0 -or
        $duplicateRequirementIds.Count -gt 0 -or
        $unknownRequirementIds.Count -gt 0 -or
        $invalidColumnCountRows.Count -gt 0 -or
        $emptyFieldIds.Count -gt 0 -or
        $invalidRequirementCells.Count -gt 0 -or
        $invalidHeader.Count -gt 0 -or
        $invalidStatusFields.Count -gt 0 -or
        $invalidStatusIds.Count -gt 0) {
        throw "需求對照結構不一致。contractVersion=$script:WorkflowCollectContractVersion; duplicateRequirementSections=$($duplicateRequirementSections -join ','); invalidSectionContent=$($invalidSectionContent -join ','); missingRequirementIds=$($missingRequirementIds -join ','); duplicateRequirementIds=$($duplicateRequirementIds -join ','); unknownRequirementIds=$($unknownRequirementIds -join ','); invalidColumnCountRows=$($invalidColumnCountRows -join ','); emptyFieldIds=$($emptyFieldIds -join ','); invalidRequirementCells=$($invalidRequirementCells -join ','); invalidHeader=$($invalidHeader -join ','); invalidStatusFields=$($invalidStatusFields -join ','); invalidStatusIds=$($invalidStatusIds -join ',')"
    }

    return [ordered]@{
        contractVersion = $script:WorkflowCollectContractVersion
        summaryPath     = $summaryFullPath
        summarySha256   = $summarySha256After
        requirementIds  = @($requirementIds)
        reportEvidence  = @($reportEvidence.ToArray())
        reportRowCount  = $rows.Count
        statusCounts    = $statusCounts
    }
}

function Get-ReportReferencedPaths {
    param(
        [Parameter(Mandatory)]
        [string[]]$ReportPath,

        [Parameter(Mandatory)]
        [string]$DispatchRoot
    )

    $references = New-Object System.Collections.Generic.List[string]
    foreach ($report in $ReportPath) {
        $reportFullPath = Resolve-AbsolutePath -Path $report
        if (-not (Test-Path -LiteralPath $reportFullPath -PathType Leaf)) {
            throw "找不到結案報告：$reportFullPath"
        }
        $content = Get-Content -LiteralPath $reportFullPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($content)) {
            throw "結案報告為空：$reportFullPath"
        }
        $phaseMatch = [regex]::Match($content, '(?ms)^##\s+Phase 對照\s*$\r?\n(?<section>.*?)(?=^##\s|\z)')
        if (-not $phaseMatch.Success) {
            throw "結案報告缺少 Phase 對照節：$reportFullPath"
        }
        $section = $phaseMatch.Groups['section'].Value
        foreach ($match in [regex]::Matches($section, '`([^`]+)`')) {
            $candidate = Convert-ReportPathForComparison -Path $match.Groups[1].Value -DispatchRoot $DispatchRoot
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $references.Add($candidate)
            }
        }
    }

    return @($references | Sort-Object -Unique)
}

function Get-DirectWriteFileEvidence {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$EvidenceName
    )

    $fullPath = Resolve-AbsolutePath -Path $Path
    if (-not (Test-PathWithinRoot -Path $fullPath -Root $SourceRoot)) {
        throw "direct-write 的 $EvidenceName 超出 sourceRoot：$fullPath"
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "direct-write 缺少 $EvidenceName 檔案證據：$fullPath"
    }

    $file = Get-Item -LiteralPath $fullPath -Force
    if ($file.Length -le 0) {
        throw "direct-write 的 $EvidenceName 檔案為空：$fullPath"
    }

    $hash = Get-FileSha256 -Path $fullPath
    return [ordered]@{
        path             = $fullPath
        relativePath     = Get-RelativePathFromRoot -Path $fullPath -Root $SourceRoot
        length           = [int64]$file.Length
        lastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
        sha256           = $hash
    }
}

function Invoke-DirectWriteCollect {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$DispatchRoot,

        [AllowEmptyString()]
        [string]$BaseSha,

        [AllowNull()]
        [object]$Preflight,

        [string]$PreflightPath,

        [string]$RequestPath,

        [string]$RunRecordPath,

        [AllowEmptyString()]
        [string]$RequiredIdentifier,

        [Parameter(Mandatory)]
        [ValidateSet('workflow', 'resource')]
        [string]$DispatchKind,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$TargetStates,

        [Parameter(Mandatory)]
        [string[]]$ReportPath,

        [AllowNull()]
        [object]$RequirementMap,

        [string]$ReviewerReportPath,

        [string]$LineSlug,

        [string]$DispatchSlug
    )

    $identityValidation = $null
    $hasReviewerReport = -not [string]::IsNullOrWhiteSpace($ReviewerReportPath)
    $hasRequest = -not [string]::IsNullOrWhiteSpace($RequestPath)
    $hasRunRecord = -not [string]::IsNullOrWhiteSpace($RunRecordPath)
    $isFullCollection = $hasRequest -and $hasRunRecord
    $collectMode = if ($hasReviewerReport -and -not $isFullCollection) { 'structural-only' } else { 'full' }
    $identityRequested = if ($hasReviewerReport) {
        $isFullCollection
    }
    else {
        $hasRequest -or $hasRunRecord
    }
    if ($identityRequested) {
        $identityValidation = Test-DispatchCollectIdentity -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -DispatchRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RequiredIdentifier $RequiredIdentifier -BaseSha $BaseSha -Preflight $Preflight -PreflightPath $PreflightPath -RequestPath $RequestPath -RunRecordPath $RunRecordPath -ReviewerReportPath $ReviewerReportPath
        if (-not $identityValidation.valid) {
            $identityFailureResult = [ordered]@{
                operation          = 'Collect'
                collectionMode     = 'direct-write'
                sourceRoot         = $SourceRoot
                executionRoot      = $ExecutionRoot
                dispatchRoot       = $DispatchRoot
                baseSha            = $BaseSha
                dispatchKind       = $DispatchKind
                reportPaths        = @($ReportPath)
                reportEvidence     = @()
                collect_mode       = $collectMode
                identityMismatches = @($identityValidation.differences)
                identity           = $identityValidation
                reviewerFindings   = $identityValidation.reviewer_report
                outputValid        = $false
                worktreeRemoved    = $false
            }
            if ($DispatchKind -eq 'workflow') {
                $identityFailureResult.requirementMap = $RequirementMap
            }
            Throw-DispatchIdentityCollectFailure -Result $identityFailureResult
        }
    }

    if ($TargetStates.Count -eq 0) {
        throw 'direct-write 的 Preflight 輸出缺少核准輸出清單 targetStates。'
    }

    $approvedOutputs = New-Object System.Collections.Generic.List[object]
    foreach ($targetState in @($TargetStates)) {
        $fullPathProperty = $targetState.PSObject.Properties['FullPath']
        if ($null -eq $fullPathProperty -or [string]::IsNullOrWhiteSpace([string]$fullPathProperty.Value)) {
            throw 'direct-write 的 targetStates 缺少有效 FullPath。'
        }
        $inputPathProperty = $targetState.PSObject.Properties['InputPath']
        $inputPath = if ($null -ne $inputPathProperty) { [string]$inputPathProperty.Value } else { '' }
        $approvedOutputs.Add([ordered]@{
                inputPath = $inputPath
                evidence  = Get-DirectWriteFileEvidence -Path ([string]$fullPathProperty.Value) -SourceRoot $SourceRoot -EvidenceName '核准輸出'
            })
    }

    $reportEvidence = New-Object System.Collections.Generic.List[object]
    foreach ($report in @($ReportPath)) {
        $reportEvidence.Add((Get-DirectWriteFileEvidence -Path $report -SourceRoot $SourceRoot -EvidenceName '結案報告'))
    }
    $reviewerFindings = Get-ReviewerFindingsForCollect -Path $ReviewerReportPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -WriteLedger:$isFullCollection

    $result = [ordered]@{
        operation          = 'Collect'
        status             = 'collected'
        collectionMode     = 'direct-write'
        sourceRoot         = $SourceRoot
        executionRoot      = $ExecutionRoot
        dispatchRoot       = $DispatchRoot
        baseSha            = $BaseSha
        dispatchKind       = $DispatchKind
        worktreeCreated    = $false
        approvedOutputs    = @($approvedOutputs.ToArray())
        reportPaths        = @($ReportPath | ForEach-Object { Resolve-AbsolutePath -Path $_ })
        reportEvidence     = @($reportEvidence.ToArray())
        trackedDiff        = @()
        stagedDiff         = @()
        untrackedFiles     = @()
        allFiles           = @()
        reportReferences   = @()
        missingFromReport  = @()
        unexpectedInReport = @()
        itemChecks         = @()
        collect_mode       = $collectMode
        reviewerFindings   = $reviewerFindings
        identity           = $identityValidation
        outputValid        = $true
        worktreeRemoved    = $false
    }

    if ($DispatchKind -eq 'workflow') {
        $result.requirementMap = $RequirementMap
    }

    if ($null -ne $reviewerFindings -and $reviewerFindings.valid -ne $true) {
        Throw-ReviewerFindingCollectFailure -Result $result
    }

    return $result
}

function Invoke-Collect {
    if ($null -eq $ReportPath -or $ReportPath.Count -eq 0) {
        throw 'Collect 必須提供至少一個 ReportPath。'
    }
    if ([string]::IsNullOrWhiteSpace($DispatchKind)) {
        throw 'Collect 必須提供 DispatchKind。'
    }

    $collectDispatchRoot = ''
    $collectRequestPath = ''
    $collectRunRecordPath = ''
    $collectRequiredIdentifier = ''
    $collectReviewerReportPath = ''
    foreach ($optionalVariable in @(
            [ordered]@{ name = 'DispatchRoot'; target = 'collectDispatchRoot' }
            [ordered]@{ name = 'RequestPath'; target = 'collectRequestPath' }
            [ordered]@{ name = 'RunRecordPath'; target = 'collectRunRecordPath' }
            [ordered]@{ name = 'RequiredIdentifier'; target = 'collectRequiredIdentifier' }
            [ordered]@{ name = 'ReviewerReportPath'; target = 'collectReviewerReportPath' }
        )) {
        $optionalValue = Get-Variable -Name $optionalVariable.name -ErrorAction SilentlyContinue
        if ($null -ne $optionalValue) {
            Set-Variable -Name $optionalVariable.target -Value ([string]$optionalValue.Value) -Scope Local
        }
    }

    $requirementMap = $null
    if ($DispatchKind -eq 'workflow') {
        $requirementMap = Get-RequirementMap -RequirementSummaryPath $RequirementSummaryPath -ReportPath $ReportPath
    }

    $preflight = $null
    $worktreeCreated = $true
    if (-not [string]::IsNullOrWhiteSpace($PreflightResultPath)) {
        $preflight = Get-PreflightData
        $operationProperty = $preflight.PSObject.Properties['operation']
        if ($null -ne $operationProperty -and [string]$operationProperty.Value -ne 'Preflight') {
            throw 'Collect 的 PreflightResultPath 必須指向 Preflight 輸出。'
        }
        $preflightSourceRoot = Resolve-AbsolutePath -Path (Get-RequiredPreflightProperty -Object $preflight -Name 'sourceRoot')
        $preflightExecutionRoot = Resolve-AbsolutePath -Path (Get-RequiredPreflightProperty -Object $preflight -Name 'executionRoot')
        $worktreeProperty = $preflight.PSObject.Properties['worktreeCreated']
        if ($null -eq $worktreeProperty -or $worktreeProperty.Value -isnot [bool]) {
            throw 'Collect 的 Preflight 輸出缺少布林欄位 worktreeCreated。'
        }
        $worktreeCreated = [bool]$worktreeProperty.Value
        if (-not $worktreeCreated) {
            if (-not [string]::Equals($preflightSourceRoot, $preflightExecutionRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'direct-write 的 Preflight 輸出必須讓 executionRoot 等於 sourceRoot。'
            }
            $baseProperty = $preflight.PSObject.Properties['baseSha']
            if ($null -eq $baseProperty -or -not [string]::IsNullOrEmpty([string]$baseProperty.Value)) {
                throw 'direct-write 的 Preflight 輸出必須保留空 baseSha，不得偽造 Git 基準。'
            }
            $targetStatesProperty = $preflight.PSObject.Properties['targetStates']
            if ($null -eq $targetStatesProperty) {
                throw 'direct-write 的 Preflight 輸出缺少 targetStates。'
            }
            $preflightDispatchRootProperty = $preflight.PSObject.Properties['dispatchRoot']
            $directDispatchRoot = if ($null -ne $preflightDispatchRootProperty -and -not [string]::IsNullOrWhiteSpace([string]$preflightDispatchRootProperty.Value)) {
                [string]$preflightDispatchRootProperty.Value
            }
            elseif (-not [string]::IsNullOrWhiteSpace($collectDispatchRoot)) {
                $collectDispatchRoot
            }
            else {
                $preflightSourceRoot
            }
            $preflightBaseShaProperty = $preflight.PSObject.Properties['baseSha']
            $directBaseSha = if ($null -eq $preflightBaseShaProperty) { '' } else { [string]$preflightBaseShaProperty.Value }
            return Invoke-DirectWriteCollect -SourceRoot $preflightSourceRoot -ExecutionRoot $preflightExecutionRoot -DispatchRoot $directDispatchRoot -BaseSha $directBaseSha -Preflight $preflight -PreflightPath $PreflightResultPath -RequestPath $collectRequestPath -RunRecordPath $collectRunRecordPath -RequiredIdentifier $collectRequiredIdentifier -DispatchKind $DispatchKind -TargetStates @($targetStatesProperty.Value) -ReportPath $ReportPath -RequirementMap $requirementMap -ReviewerReportPath $collectReviewerReportPath -LineSlug (Get-RequiredPreflightProperty -Object $preflight -Name 'lineSlug') -DispatchSlug (Get-RequiredPreflightProperty -Object $preflight -Name 'dispatchSlug')
        }

        $preflightDispatchRootProperty = $preflight.PSObject.Properties['dispatchRoot']
        if ([string]::IsNullOrWhiteSpace($DispatchRoot) -and $null -ne $preflightDispatchRootProperty) {
            $DispatchRoot = [string]$preflightDispatchRootProperty.Value
        }
        $preflightBaseShaProperty = $preflight.PSObject.Properties['baseSha']
        if ([string]::IsNullOrWhiteSpace($BaseSha) -and $null -ne $preflightBaseShaProperty) {
            $BaseSha = [string]$preflightBaseShaProperty.Value
        }
    }

    if (-not $worktreeCreated -or [string]::IsNullOrWhiteSpace($DispatchRoot) -or [string]::IsNullOrWhiteSpace($BaseSha)) {
        throw 'Collect 必須提供 worktree 的 DispatchRoot 與 BaseSha，或提供 worktreeCreated=false 的 PreflightResultPath。'
    }

    $dispatchRootPath = Resolve-AbsolutePath -Path $DispatchRoot
    if (-not (Test-Path -LiteralPath $dispatchRootPath -PathType Container)) {
        throw "dispatchRoot 不存在或不是目錄：$dispatchRootPath"
    }
    $baseResult = Invoke-GitCommand -WorkingDirectory $dispatchRootPath -Arguments @('rev-parse', '--verify', $BaseSha) -AllowFailure
    if ($baseResult.ExitCode -ne 0) {
        throw "baseSha 不存在於 dispatchRoot：$BaseSha"
    }
    $trackedDiff = @(Get-NameOnlyList -Result (Invoke-GitCommand -WorkingDirectory $dispatchRootPath -Arguments @('diff', $BaseSha, '--name-only', '-z', '--')))
    $stagedDiff = @(Get-NameOnlyList -Result (Invoke-GitCommand -WorkingDirectory $dispatchRootPath -Arguments @('diff', '--cached', '--name-only', '-z', '--')))
    $untrackedFiles = @(Get-NameOnlyList -Result (Invoke-GitCommand -WorkingDirectory $dispatchRootPath -Arguments @('ls-files', '--others', '--exclude-standard', '-z')))
    $baselineSourceRoot = $SourceRoot
    $baselineLineSlug = $LineSlug
    $baselineDispatchSlug = $DispatchSlug
    if ($null -ne $preflight) {
        foreach ($entry in @(@('sourceRoot', $SourceRoot), @('lineSlug', $LineSlug), @('dispatchSlug', $DispatchSlug))) {
            $value = Get-RequiredPreflightProperty $preflight $entry[0]
            if (-not [string]::IsNullOrWhiteSpace($entry[1]) -and $value -cne $entry[1]) { throw 'Collect 顯式身分與 Preflight 不一致。' }
        }
        $baselineSourceRoot = $preflightSourceRoot
        $baselineLineSlug = Get-RequiredPreflightProperty $preflight 'lineSlug'
        $baselineDispatchSlug = Get-RequiredPreflightProperty $preflight 'dispatchSlug'
    }
    $baselineBinding = Resolve-DispatchBaselineBinding -Preflight $preflight -SourceRoot $baselineSourceRoot -DispatchRoot $dispatchRootPath -LineSlug $baselineLineSlug -DispatchSlug $baselineDispatchSlug -BaseSha $BaseSha -Path $BaselinePath -Sha256 $BaselineSha256
    $dispatchDiff = @(Get-DispatchIncrementalChanges -Baseline $baselineBinding.Record -DispatchRoot $dispatchRootPath)
    $allFiles = @($dispatchDiff)
    $indexTracked = @(Get-NameOnlyList -Result (Invoke-GitCommand -WorkingDirectory $dispatchRootPath -Arguments @('ls-files', '-z')))
    $reportReferences = @()
    $missingFromReport = @()
    $unexpectedInReport = @()
    $matchesArray = @()
    $reportEvidence = @()
    $normalizedReportReferences = @()
    if ($DispatchKind -eq 'workflow') {
        $reportReferences = @(Get-ReportReferencedPaths -ReportPath $ReportPath -DispatchRoot $dispatchRootPath)
        $matches = New-Object System.Collections.Generic.List[object]
        $normalizedAllFiles = @($allFiles | ForEach-Object { Convert-ComparisonPath -Path $_ } | Sort-Object -Unique)
        $normalizedReportReferences = @($reportReferences | ForEach-Object { Convert-ComparisonPath -Path $_ } | Sort-Object -Unique)
        foreach ($file in $normalizedAllFiles) {
            $normalizedFile = $file
            $inReport = $normalizedReportReferences -contains $normalizedFile
            $matches.Add([pscustomobject]@{
                    Path      = $normalizedFile
                    InReport  = $inReport
                    IsStaged  = @($stagedDiff | ForEach-Object { Convert-ComparisonPath -Path $_ }) -contains $normalizedFile
                    IsTracked = @($indexTracked | ForEach-Object { Convert-ComparisonPath -Path $_ }) -contains $normalizedFile
                })
        }
        $matchesArray = @($matches.ToArray())
        $missingFromReport = @($matchesArray | Where-Object { -not $_.InReport } | ForEach-Object { $_.Path })
        $unexpectedInReport = @($normalizedReportReferences | Where-Object { $normalizedAllFiles -notcontains $_ })
        if ($missingFromReport.Count -gt 0 -or $unexpectedInReport.Count -gt 0) {
            throw "差異清單與結案報告不一致。missingFromReport=$($missingFromReport -join ','); unexpectedInReport=$($unexpectedInReport -join ',')"
        }
    }
    else {
        $reportEvidenceList = New-Object System.Collections.Generic.List[object]
        foreach ($report in @($ReportPath)) {
            $reportEvidenceList.Add((Get-DirectWriteFileEvidence -Path $report -SourceRoot $dispatchRootPath -EvidenceName '結案報告'))
        }
        $reportEvidence = @($reportEvidenceList.ToArray())
    }

    $identityValidation = $null
    $hasReviewerReport = -not [string]::IsNullOrWhiteSpace($ReviewerReportPath)
    $hasRequest = -not [string]::IsNullOrWhiteSpace($RequestPath)
    $hasRunRecord = -not [string]::IsNullOrWhiteSpace($RunRecordPath)
    $isFullCollection = $hasRequest -and $hasRunRecord
    $collectMode = if ($hasReviewerReport -and -not $isFullCollection) { 'structural-only' } else { 'full' }
    $identityRequested = if ($hasReviewerReport) {
        $isFullCollection
    }
    else {
        $hasRequest -or $hasRunRecord
    }
    if ($identityRequested) {
        $identityValidation = Test-DispatchCollectIdentity -SourceRoot $baselineSourceRoot -ExecutionRoot $dispatchRootPath -DispatchRoot $dispatchRootPath -LineSlug $baselineLineSlug -DispatchSlug $baselineDispatchSlug -RequiredIdentifier $RequiredIdentifier -BaseSha $BaseSha -Preflight $preflight -PreflightPath $PreflightResultPath -RequestPath $RequestPath -RunRecordPath $RunRecordPath -ReviewerReportPath $ReviewerReportPath
        if (-not $identityValidation.valid) {
            $identityFailureResult = [ordered]@{
                operation          = 'Collect'
                dispatchRoot       = $dispatchRootPath
                baseSha            = $BaseSha
                dispatchKind       = $DispatchKind
                reportPaths        = @($ReportPath | ForEach-Object { Resolve-AbsolutePath -Path $_ })
                reportReferences   = @($normalizedReportReferences)
                missingFromReport  = @($missingFromReport)
                unexpectedInReport = @($unexpectedInReport)
                itemChecks         = $matchesArray
                reportEvidence     = @($reportEvidence)
                collect_mode       = $collectMode
                identityMismatches = @($identityValidation.differences)
                identity           = $identityValidation
                reviewerFindings   = $identityValidation.reviewer_report
                outputValid        = $false
                worktreeRemoved    = $false
            }
            if ($DispatchKind -eq 'workflow') {
                $identityFailureResult.requirementMap = $requirementMap
            }
            Throw-DispatchIdentityCollectFailure -Result $identityFailureResult
        }
    }
    $reviewerFindings = Get-ReviewerFindingsForCollect -Path $ReviewerReportPath -SourceRoot $baselineSourceRoot -ExecutionRoot $dispatchRootPath -LineSlug $baselineLineSlug -DispatchSlug $baselineDispatchSlug -WriteLedger:$isFullCollection

    $result = [ordered]@{
        operation          = 'Collect'
        status             = 'collected'
        dispatchRoot       = $dispatchRootPath
        baseSha            = $BaseSha
        dispatchKind       = $DispatchKind
        trackedDiff        = @($trackedDiff)
        stagedDiff         = @($stagedDiff)
        untrackedFiles     = @($untrackedFiles)
        allFiles           = @($allFiles)
        dispatchDiff       = @($dispatchDiff)
        baselinePath       = $baselineBinding.Path
        baselineSha256     = $baselineBinding.Sha256
        reportPaths        = @($ReportPath | ForEach-Object { Resolve-AbsolutePath -Path $_ })
        reportReferences   = @($normalizedReportReferences)
        missingFromReport  = @($missingFromReport)
        unexpectedInReport = @($unexpectedInReport)
        itemChecks         = $matchesArray
        reportEvidence     = @($reportEvidence)
        collect_mode       = $collectMode
        outputValid        = $true
        reviewerFindings   = $reviewerFindings
        identity           = $identityValidation
        worktreeRemoved    = $false
    }

    if ($DispatchKind -eq 'workflow') {
        $result.requirementMap = $requirementMap
    }

    if ($null -ne $reviewerFindings -and $reviewerFindings.valid -ne $true) {
        Throw-ReviewerFindingCollectFailure -Result $result
    }

    return $result
}

function New-CleanupOperationResult {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$SourceRoot,
        [AllowEmptyString()][string]$DispatchRoot,
        [AllowEmptyString()][string]$LineSlug,
        [AllowEmptyString()][string]$DispatchSlug
    )

    return [ordered]@{
        schema             = 'ai-sessions.dispatch-cleanup-result.v1'
        operation          = 'Cleanup'
        line_slug          = $LineSlug
        dispatch_slug      = $DispatchSlug
        source_root        = $SourceRoot
        dispatch_root      = $DispatchRoot
        source_files       = @()
        destination_files  = @()
        files              = @()
        errors             = @()
        worktree_removed   = $false
        status              = 'preflight-rejected'
        failure_code       = $null
        error              = $null
        inventory          = [ordered]@{
            report_root = $null
            referenced_paths = @()
            source_count = 0
        }
    }
}

function New-CleanupIdentityMismatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Field,
        [AllowNull()][object]$Expected,
        [AllowNull()][object]$Received,
        [Parameter(Mandatory)][string]$Source
    )

    return [ordered]@{
        field    = $Field
        expected = $Expected
        received = $Received
        source   = $Source
    }
}

function Throw-CleanupOperationFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Result,
        [Parameter(Mandatory)][ValidateSet('preflight-rejected', 'preservation-failed', 'removal-failed')][string]$Status,
        [Parameter(Mandatory)][string]$FailureCode,
        [Parameter(Mandatory)][string]$Message,
        [AllowNull()][object]$Detail
    )

    $Result.status = $Status
    $Result.failure_code = $FailureCode
    $Result.error = $Message
    if ($null -eq $Detail) {
        $Result.errors = @()
    }
    else {
        $Result.errors = @($Detail)
    }
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['errorCode'] = $FailureCode
    $exception.Data['operationResult'] = $Result
    throw $exception
}

function Get-CleanupPropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string[]]$Names
    )

    foreach ($name in @($Names)) {
        $property = if ($null -eq $Object) { $null } else { $Object.PSObject.Properties[[string]$name] }
        if ($null -ne $property) {
            return $property.Value
        }
        if ($Object -is [System.Collections.IDictionary] -and $Object.Contains([string]$name)) {
            return $Object[[string]$name]
        }
    }
    return $null
}

function Read-CleanupJsonDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $resolvedPath = Resolve-AbsolutePath -Path $Path
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw ('Cleanup' + $Name + 'Missing：找不到檔案：' + $resolvedPath)
    }
    try {
        $document = ConvertFrom-DispatchJson -Content (Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8)
    }
    catch {
        throw ('Cleanup' + $Name + 'Invalid：JSON 無法解析：' + $resolvedPath + '；' + $_.Exception.Message)
    }
    if ($null -eq $document -or $document -isnot [psobject]) {
        throw ('Cleanup' + $Name + 'Invalid：根節點必須是 JSON object：' + $resolvedPath)
    }
    return [pscustomobject]@{ Path = $resolvedPath; Document = $document }
}

function Get-CleanupRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $resolvedPath = Resolve-AbsolutePath -Path $Path
    $resolvedRoot = (Resolve-AbsolutePath -Path $Root).TrimEnd('\', '/')
    if (-not (Test-PathWithinRoot -Path $resolvedPath -Root $resolvedRoot) -or [string]::Equals($resolvedPath, $resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('CleanupSourceBoundary：來源路徑超出 dispatch worktree：' + $resolvedPath)
    }
    return $resolvedPath.Substring($resolvedRoot.Length).TrimStart([char[]]@([char]92, [char]47)).Replace('\', '/')
}

function Add-CleanupInventoryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Inventory,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Seen,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DispatchRoot,
        [Parameter(Mandatory)][string]$SourceName
    )

    $resolvedPath = Resolve-AbsolutePath -Path $Path
    if (-not (Test-PathWithinRoot -Path $resolvedPath -Root $DispatchRoot) -or [string]::Equals($resolvedPath, (Resolve-AbsolutePath $DispatchRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw ('CleanupSourceBoundary：' + $SourceName + ' 不屬於 dispatch worktree：' + $resolvedPath)
    }
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw ('CleanupSourceMissing：找不到 ' + $SourceName + '：' + $resolvedPath)
    }
    $item = Get-Item -LiteralPath $resolvedPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw ('CleanupSourceBoundary：不允許保存 reparse point：' + $resolvedPath)
    }
    $key = $resolvedPath.ToLowerInvariant()
    if ($Seen.Add($key)) {
        $Inventory.Add([ordered]@{
                source_path = $resolvedPath
                relative_path = Get-CleanupRelativePath -Path $resolvedPath -Root $DispatchRoot
                source_name = $SourceName
            })
    }
}

function Get-CleanupRecordReferencedPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Record
    )

    $pathNames = @(
        'event_stream_path', 'last_message_path', 'preflight_result_path', 'pid_record_path',
        'thread_id_path', 'launcher_path', 'process_exit_code_sidecar_path', 'prompt_path',
        'prompt_source_path', 'prompt_transfer_path', 'inspect_result_path', 'evidence_pack_path',
        'request_path', 'scope_plan_path', 'scope_plan_parent_path', 'baseline_path',
        'prepare_result_path', 'quota_before_path', 'quota_after_path',
        'budget_monitor_path'
    )
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($name in $pathNames) {
        $value = Get-CleanupPropertyValue -Object $Record -Names @($name)
        if ($null -ne $value -and $value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            $paths.Add([string]$value)
        }
    }
    return @($paths.ToArray())
}

function Get-CleanupInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DispatchRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [AllowEmptyString()][string]$RunRecordPath,
        [AllowEmptyCollection()][string[]]$EvidencePath
    )

    $inventory = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $reportRoot = Join-Path (Join-Path (Resolve-AbsolutePath $DispatchRoot) '.local\ai-sessions\report') $LineSlug
    if (Test-Path -LiteralPath $reportRoot -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $reportRoot -File -Recurse -Force)) {
            Add-CleanupInventoryPath -Inventory $inventory -Seen $seen -Path $file.FullName -DispatchRoot $DispatchRoot -SourceName '同線報告'
        }
    }

    $record = $null
    $recordPathValue = $null
    $recordReferencedPaths = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($RunRecordPath)) {
        $recordPathValue = Resolve-AbsolutePath -Path $RunRecordPath
        $expectedRunRoot = Join-Path (Join-Path (Join-Path (Resolve-AbsolutePath $DispatchRoot) '.local\ai-sessions\history') $LineSlug) (Join-Path 'runs' $DispatchSlug)
        if (-not [string]::Equals((Split-Path -Parent $recordPathValue), (Resolve-AbsolutePath $expectedRunRoot), [StringComparison]::OrdinalIgnoreCase)) {
            throw ('CleanupRunRecordBoundary：RunRecord 路徑不屬於目前 line／dispatch：' + $recordPathValue)
        }
        $recordDocument = Read-CleanupJsonDocument -Path $recordPathValue -Name 'RunRecord'
        $record = $recordDocument.Document
        foreach ($entry in @(
                [pscustomobject]@{ field = 'line_slug'; expected = $LineSlug; received = [string](Get-CleanupPropertyValue -Object $record -Names @('line_slug', 'lineSlug')) },
                [pscustomobject]@{ field = 'dispatch_slug'; expected = $DispatchSlug; received = [string](Get-CleanupPropertyValue -Object $record -Names @('dispatch_slug', 'dispatchSlug')) },
                [pscustomobject]@{ field = 'source_root'; expected = (Resolve-AbsolutePath $SourceRoot); received = [string](Get-CleanupPropertyValue -Object $record -Names @('source_root', 'sourceRoot')) },
                [pscustomobject]@{ field = 'execution_root'; expected = (Resolve-AbsolutePath $DispatchRoot); received = [string](Get-CleanupPropertyValue -Object $record -Names @('execution_root', 'executionRoot')) }
            )) {
            $received = [string]$entry.received
            if ($entry.field -in @('source_root', 'execution_root') -and -not [string]::IsNullOrWhiteSpace($received)) {
                try { $received = Resolve-AbsolutePath -Path $received } catch { }
            }
            if (-not [string]::Equals([string]$entry.expected, $received, [StringComparison]::OrdinalIgnoreCase)) {
                $mismatch = New-CleanupIdentityMismatch -Field ('run_record.' + $entry.field) -Expected $entry.expected -Received $received -Source $recordPathValue
                throw ('CleanupIdentityMismatch：' + (ConvertTo-Json -InputObject $mismatch -Compress -Depth 10))
            }
        }
        Add-CleanupInventoryPath -Inventory $inventory -Seen $seen -Path $recordPathValue -DispatchRoot $DispatchRoot -SourceName 'RunRecord'
        foreach ($path in @(Get-CleanupRecordReferencedPaths -Record $record)) {
            $resolvedReferencedPath = Resolve-AbsolutePath -Path $path
            if (Test-PathWithinRoot -Path $resolvedReferencedPath -Root $DispatchRoot) {
                $recordReferencedPaths.Add($resolvedReferencedPath)
                if (Test-Path -LiteralPath $resolvedReferencedPath -PathType Leaf) {
                    Add-CleanupInventoryPath -Inventory $inventory -Seen $seen -Path $resolvedReferencedPath -DispatchRoot $DispatchRoot -SourceName ('RunRecord.' + $path)
                }
            }
        }
    }

    foreach ($evidence in @($EvidencePath)) {
        if ([string]::IsNullOrWhiteSpace([string]$evidence)) {
            throw 'CleanupEvidenceInvalid：EvidencePath 不可為空。'
        }
        $resolvedEvidence = Resolve-AbsolutePath -Path ([string]$evidence)
        if (-not (Test-PathWithinRoot -Path $resolvedEvidence -Root $DispatchRoot)) {
            throw ('CleanupSourceBoundary：EvidencePath 不屬於 dispatch worktree：' + $resolvedEvidence)
        }
        $referenced = @($recordReferencedPaths | Where-Object { [string]::Equals($_, $resolvedEvidence, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if (-not $referenced) {
            throw ('CleanupEvidenceUnreferenced：EvidencePath 未被目前 RunRecord 引用：' + $resolvedEvidence)
        }
        Add-CleanupInventoryPath -Inventory $inventory -Seen $seen -Path $resolvedEvidence -DispatchRoot $DispatchRoot -SourceName 'EvidencePath'
    }

    return [pscustomobject]@{
        report_root = $reportRoot
        run_record = $record
        run_record_path = $recordPathValue
        referenced_paths = @($recordReferencedPaths.ToArray())
        items = @($inventory.ToArray())
    }
}

function Test-CleanupUtf8Readback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if (@('.md', '.json', '.jsonl', '.log', '.txt') -notcontains $extension) {
        return [ordered]@{ status = 'not-applicable'; error = $null }
    }
    try {
        $encoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
        $null = [IO.File]::ReadAllText((ConvertTo-FileSystemApiPath -Path (Resolve-AbsolutePath $Path)), $encoding)
        return [ordered]@{ status = 'passed'; error = $null }
    }
    catch {
        return [ordered]@{ status = 'failed'; error = $_.Exception.Message }
    }
}

function Preserve-CleanupFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Item,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DispatchRoot
    )

    $sourcePath = [string]$Item.source_path
    $destinationPath = Join-Path (Resolve-AbsolutePath $SourceRoot) ([string]$Item.relative_path -replace '/', '\')
    if (-not (Test-PathWithinRoot -Path $destinationPath -Root $SourceRoot)) {
        throw ('CleanupDestinationBoundary：destination 超出 sourceRoot：' + $destinationPath)
    }
    $bytes = [IO.File]::ReadAllBytes((ConvertTo-FileSystemApiPath -Path $sourcePath))
    $sourceHashBefore = Get-DispatchByteArraySha256 -Bytes $bytes
    $parent = Split-Path -Parent $destinationPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $destinationExists = [IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $destinationPath))
    $destinationIsDirectory = [IO.Directory]::Exists((ConvertTo-FileSystemApiPath -Path $destinationPath))
    if ($destinationIsDirectory) {
        throw ('CleanupDestinationConflict：destination 是目錄：' + $destinationPath)
    }
    if ($destinationExists) {
        $existingHash = Get-FileSha256 -Path $destinationPath
        if (-not [string]::Equals($existingHash, $sourceHashBefore, [StringComparison]::OrdinalIgnoreCase)) {
            throw ('CleanupDestinationConflict：destination SHA-256 不同：' + $destinationPath)
        }
    }
    else {
        $temporaryPath = Join-Path $parent ([guid]::NewGuid().ToString('N') + '.cleanup.tmp')
        try {
            [IO.File]::WriteAllBytes((ConvertTo-FileSystemApiPath -Path $temporaryPath), $bytes)
            if ([IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $destinationPath))) {
                $existingHash = Get-FileSha256 -Path $destinationPath
                if (-not [string]::Equals($existingHash, $sourceHashBefore, [StringComparison]::OrdinalIgnoreCase)) {
                    throw ('CleanupDestinationConflict：destination 在保存期間建立且內容不同：' + $destinationPath)
                }
            }
            else {
                [IO.File]::Move((ConvertTo-FileSystemApiPath -Path $temporaryPath), (ConvertTo-FileSystemApiPath -Path $destinationPath))
            }
        }
        finally {
            if ([IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $temporaryPath))) {
                [IO.File]::Delete((ConvertTo-FileSystemApiPath -Path $temporaryPath))
            }
        }
    }
    $sourceHashAfter = Get-FileSha256 -Path $sourcePath
    if (-not [string]::Equals($sourceHashBefore, $sourceHashAfter, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('SourceChangedDuringPreservation：來源在保存期間變更：' + $sourcePath)
    }
    $destinationHash = Get-FileSha256 -Path $destinationPath
    if (-not [string]::Equals($sourceHashAfter, $destinationHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('CleanupHashMismatch：destination SHA-256 不一致：' + $destinationPath)
    }
    $readback = Test-CleanupUtf8Readback -Path $destinationPath
    if ($readback.status -eq 'failed') {
        throw ('CleanupReadbackFailed：destination UTF-8 readback 失敗：' + $destinationPath + '；' + $readback.error)
    }
    return [ordered]@{
        source_path = $sourcePath
        destination_path = $destinationPath
        relative_path = [string]$Item.relative_path
        source_sha256 = $sourceHashAfter
        destination_sha256 = $destinationHash
        length = [int64]$bytes.Length
        readback = $readback
        status = 'preserved'
    }
}

function Invoke-Cleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $result = New-CleanupOperationResult -SourceRoot ([string]$SourceRoot) -DispatchRoot ([string]$DispatchRoot) -LineSlug ([string]$LineSlug) -DispatchSlug ([string]$DispatchSlug)
    try {
        if ([string]::IsNullOrWhiteSpace($SourceRoot) -or [string]::IsNullOrWhiteSpace($DispatchRoot) -or [string]::IsNullOrWhiteSpace($LineSlug) -or [string]::IsNullOrWhiteSpace($DispatchSlug)) {
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupRequiredParameterMissing' -Message 'Cleanup 必須提供 SourceRoot、DispatchRoot、LineSlug 與 DispatchSlug。'
        }
        if ($LineSlug -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or $DispatchSlug -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupIdentityInvalid' -Message 'Cleanup 的 line／dispatch slug 格式不符。'
        }
        if ([string]::IsNullOrWhiteSpace($PreflightResultPath)) {
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupPreflightResultRequired' -Message 'Cleanup 必須提供 PreflightResultPath，未取得 Preflight result 時拒絕移除 worktree。'
        }
        $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
        $dispatchRootPath = Resolve-AbsolutePath -Path $DispatchRoot
        $result.source_root = $sourceRootPath
        $result.dispatch_root = $dispatchRootPath
        if (-not (Test-Path -LiteralPath $sourceRootPath -PathType Container)) {
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupSourceRootMissing' -Message ('sourceRoot 不存在或不是目錄：' + $sourceRootPath)
        }
        $expectedDispatchRoot = Resolve-AbsolutePath -Path (Join-Path $sourceRootPath (Join-Path '.local\ai-sessions\worktrees' $DispatchSlug))
        if (-not [string]::Equals($dispatchRootPath, $expectedDispatchRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $mismatch = New-CleanupIdentityMismatch -Field 'dispatch_root' -Expected $expectedDispatchRoot -Received $dispatchRootPath -Source 'Cleanup CLI'
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupDispatchRootBoundary' -Message ('CleanupPreflightRejected：dispatchRoot 不符合 exact worktree boundary。') -Detail $mismatch
        }
        if (-not (Test-Path -LiteralPath $dispatchRootPath -PathType Container)) {
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupDispatchRootMissing' -Message ('dispatchRoot 不存在：' + $dispatchRootPath)
        }
        $worktreeList = Invoke-GitCommand -WorkingDirectory $sourceRootPath -Arguments @('worktree', 'list', '--porcelain') -AllowFailure
        if ($worktreeList.ExitCode -ne 0) {
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupGitRegistrationUnavailable' -Message ('無法取得 Git worktree registration：' + $worktreeList.StdErr)
        }
        $registered = $false
        foreach ($line in ([string]$worktreeList.StdOut -split "`r?`n")) {
            if (-not $line.StartsWith('worktree ', [StringComparison]::Ordinal)) { continue }
            $registeredPath = $line.Substring('worktree '.Length).Trim()
            if ([string]::Equals((Resolve-AbsolutePath $registeredPath), $dispatchRootPath, [StringComparison]::OrdinalIgnoreCase)) {
                $registered = $true
                break
            }
        }
        if (-not $registered) {
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupWorktreeNotRegistered' -Message ('dispatchRoot 未在 Git worktree registration 中：' + $dispatchRootPath)
        }

        if (-not [string]::IsNullOrWhiteSpace($PreflightResultPath)) {
            $preflight = Read-CleanupJsonDocument -Path $PreflightResultPath -Name 'Preflight'
            foreach ($entry in @(
                    [pscustomobject]@{ field = 'source_root'; expected = $sourceRootPath; received = [string](Get-CleanupPropertyValue -Object $preflight.Document -Names @('sourceRoot', 'source_root')) },
                    [pscustomobject]@{ field = 'dispatch_root'; expected = $dispatchRootPath; received = [string](Get-CleanupPropertyValue -Object $preflight.Document -Names @('dispatchRoot', 'dispatch_root')) },
                    [pscustomobject]@{ field = 'line_slug'; expected = $LineSlug; received = [string](Get-CleanupPropertyValue -Object $preflight.Document -Names @('lineSlug', 'line_slug')) },
                    [pscustomobject]@{ field = 'dispatch_slug'; expected = $DispatchSlug; received = [string](Get-CleanupPropertyValue -Object $preflight.Document -Names @('dispatchSlug', 'dispatch_slug')) }
                )) {
                $received = $entry.received
                if ($entry.field -in @('source_root', 'dispatch_root') -and -not [string]::IsNullOrWhiteSpace([string]$received)) { try { $received = Resolve-AbsolutePath -Path $received } catch { } }
                if (-not [string]::Equals([string]$entry.expected, [string]$received, [StringComparison]::OrdinalIgnoreCase)) {
                    $mismatch = New-CleanupIdentityMismatch -Field ('preflight.' + $entry.field) -Expected $entry.expected -Received $received -Source $preflight.Path
                    Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupIdentityMismatch' -Message 'CleanupPreflightRejected：Preflight identity 不一致。' -Detail $mismatch
                }
            }
        }

        $inventory = Get-CleanupInventory -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunRecordPath $RunRecordPath -EvidencePath @($EvidencePath)
        $result.inventory = [ordered]@{
            report_root = $inventory.report_root
            run_record_path = $inventory.run_record_path
            referenced_paths = @($inventory.referenced_paths)
            source_count = @($inventory.items).Count
        }
        $result.source_files = @($inventory.items | ForEach-Object { $_.source_path })
        $result.destination_files = @($inventory.items | ForEach-Object { Join-Path $sourceRootPath ($_.relative_path -replace '/', '\') })
        $preserved = New-Object System.Collections.Generic.List[object]
        foreach ($item in @($inventory.items)) {
            try {
                $preserved.Add((Preserve-CleanupFile -Item $item -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath))
            }
            catch {
                $code = if ($_.Exception.Message -match '^([A-Za-z][A-Za-z0-9]+)：') { $Matches[1] } else { 'CleanupPreservationFailed' }
                Throw-CleanupOperationFailure -Result $result -Status 'preservation-failed' -FailureCode $code -Message $_.Exception.Message -Detail ([ordered]@{ field = 'file'; expected = 'preserved'; received = $item.source_path; source = $item.source_path })
            }
        }
        $result.files = @($preserved.ToArray())
        if (-not $PSCmdlet.ShouldProcess($dispatchRootPath, '移除 exact dispatch worktree')) {
            Throw-CleanupOperationFailure -Result $result -Status 'removal-failed' -FailureCode 'CleanupWhatIf' -Message 'Cleanup 因 WhatIf 未執行 worktree 移除。'
        }
        $removeResult = Invoke-GitCommand -WorkingDirectory $sourceRootPath -Arguments @('worktree', 'remove', '--force', '--', $dispatchRootPath) -AllowFailure
        if ($removeResult.ExitCode -ne 0) {
            $result.removal = [ordered]@{ command = 'git worktree remove --force -- ' + $dispatchRootPath; exit_code = $removeResult.ExitCode; stderr = $removeResult.StdErr }
            $result.status = 'removal-failed'
            $result.failure_code = 'CleanupWorktreeRemovalFailed'
            $result.error = 'CleanupWorktreeRemovalFailed：Git worktree remove 失敗。'
            return $result
        }
        $afterList = Invoke-GitCommand -WorkingDirectory $sourceRootPath -Arguments @('worktree', 'list', '--porcelain') -AllowFailure
        $stillRegistered = $false
        if ($afterList.ExitCode -eq 0) {
            foreach ($line in ([string]$afterList.StdOut -split "`r?`n")) {
                if (-not $line.StartsWith('worktree ', [StringComparison]::Ordinal)) { continue }
                if ([string]::Equals((Resolve-AbsolutePath $line.Substring('worktree '.Length).Trim()), $dispatchRootPath, [StringComparison]::OrdinalIgnoreCase)) { $stillRegistered = $true; break }
            }
        }
        if ($afterList.ExitCode -ne 0 -or $stillRegistered -or (Test-Path -LiteralPath $dispatchRootPath)) {
            $result.removal = [ordered]@{ exit_code = $afterList.ExitCode; registered_after = $stillRegistered; path_exists_after = Test-Path -LiteralPath $dispatchRootPath; stderr = $afterList.StdErr }
            $result.status = 'removal-failed'
            $result.failure_code = 'CleanupRemovalVerificationFailed'
            $result.error = 'CleanupRemovalVerificationFailed：worktree 移除後回查未通過。'
            return $result
        }
        $result.removal = [ordered]@{ exit_code = 0; registered_after = $false; path_exists_after = $false }
        $result.worktree_removed = $true
        $result.status = 'completed'
        $result.failure_code = $null
        return $result
    }
    catch {
        if ($null -ne $_.Exception.Data['operationResult']) {
            throw
        }
        $detail = [ordered]@{
            field = 'cleanup'
            expected = 'operation success'
            received = $_.Exception.Message
            source = 'Cleanup'
            exception_type = $_.Exception.GetType().FullName
            stack = $_.ScriptStackTrace
        }
        Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupPreflightFailed' -Message $_.Exception.Message -Detail $detail
    }
}

function Write-OperationResult {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Result
    )

    $json = ConvertTo-Json -InputObject $Result -Depth 12
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        $guardSourceRoot = Get-DispatchScriptVariableValue -Name 'SourceRoot'
        $guardExecutionRoot = Get-DispatchScriptVariableValue -Name 'ExecutionRoot'
        $guardTargetPath = @(Get-DispatchScriptVariableValue -Name 'TargetPath')
        $resolvedResultPath = Resolve-DispatchOutputPath -CandidatePath $ResultPath -SourceRoot ([string]$guardSourceRoot) -ExecutionRoot ([string]$guardExecutionRoot) -TargetPath $guardTargetPath
        $persistResult = $true
        $errorCode = [string](Get-DispatchResultPropertyValue -Object $Result -Names @('errorCode', 'error_code'))
        $prepareResultPath = [string](Get-DispatchResultPropertyValue -Object $Result -Names @('prepareResultPath', 'prepare_result_path'))
        if ($errorCode -ceq 'PrepareResultCollision' -and -not [string]::IsNullOrWhiteSpace($prepareResultPath)) {
            try {
                $resolvedPrepareResultPath = Resolve-AbsolutePath -Path $prepareResultPath
                if ([string]::Equals($resolvedResultPath, $resolvedPrepareResultPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $persistResult = $false
                }
            }
            catch {
                $persistResult = $false
            }
        }
        if ($persistResult) {
            Write-Utf8NoBom -Path $resolvedResultPath -Content ($json + "`n")
        }
    }
    Write-Output $json
}

function Get-DispatchOperationExitCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Operation,

        [AllowNull()]
        [object]$Result
    )

    if ($Operation -ieq 'Dispatch' -and [string](Get-DispatchResultPropertyValue -Object $Result -Names @('status')) -ceq 'failed') {
        return 1
    }

    if ($Operation -ieq 'Inspect') {
        $nativeExitCode = Get-DispatchResultPropertyValue -Object $Result -Names @('processExitCode', 'process_exit_code')
        if ($null -ne $nativeExitCode) {
            return [int]$nativeExitCode
        }
    }

    return 0
}

try {
    $null = Apply-DispatchRequest
    Assert-DispatchSessionMode
    $result = switch ($Operation) {
        'Preflight' { Invoke-Preflight }
        'Prepare'   { Invoke-Prepare -GuardTargetPath @($TargetPath) }
        'Start'     { Invoke-Start }
        'Inspect'   { Invoke-Inspect }
        'Dispatch'  {
            $dispatchResult = Invoke-Dispatch
            $script:ResultPath = $null
            $dispatchResult
        }
        'Collect'   { Invoke-Collect }
        'Cleanup'   { Invoke-Cleanup }
        'QuotaProbe' { Invoke-QuotaProbe }
        default     { throw "不支援的 operation：$Operation" }
    }
    if ($null -ne $script:RequestContext -and $result -is [System.Collections.IDictionary]) {
        $result.dispatch_request = Get-DispatchRequestEvidence
    }
    $dispatchExitCode = Get-DispatchOperationExitCode -Operation $Operation -Result $result
    Write-OperationResult -Result $result
    exit $dispatchExitCode
}
catch {
    $operationResultProperty = $_.Exception.Data['operationResult']
    if ($null -ne $operationResultProperty -and $operationResultProperty -is [System.Collections.IDictionary]) {
        Write-OperationResult -Result $operationResultProperty
    }
    [Console]::Error.WriteLine(('Invoke-CodexDispatch.ps1 失敗：{0}' -f $_.Exception.Message))
    exit 1
}
