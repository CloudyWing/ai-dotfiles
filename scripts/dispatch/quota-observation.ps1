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
    foreach ($line in ($content -split '\r?\n')) {
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

function Get-AdvisorActivationDecision {
    param([Parameter(Mandatory)][ValidateSet('user-explicit')][string]$RequestSource)
    return [ordered]@{
        granted = $true
        activationMode = 'user-authorized'
        authorizationSource = $RequestSource
        reserveBypassed = $false
        minimumUnitOverBudget = $false
        reasonCode = $null
        notice = 'advisor 已由呼叫端提供使用者明確授權。'
        requiredAuthorization = $null
        hardLimitPercent = $null
        remainingPercent = $null
    }
}

function New-QuotaSnapshotPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HistoryRoot,

        [Parameter(Mandatory)]
        [ValidateSet('before', 'after', 'source-refresh', 'advisor-before', 'close')]
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

function Write-QuotaSnapshotUnavailable {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [AllowEmptyString()]
        [string]$SourceRoot,

        [AllowEmptyString()]
        [string]$ExecutionRoot,

        [string[]]$TargetPath,

        [Parameter(Mandatory)]
        [string]$Purpose,

        [string]$FailureClass = 'Unknown'
    )

    $resolvedPath = Resolve-DispatchOutputPathFromContext -CandidatePath $Path -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    $parentPath = Split-Path -Parent $resolvedPath
    if (-not [string]::IsNullOrWhiteSpace($parentPath)) {
        $null = New-DispatchOutputDirectory -Path $parentPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    }
    $resolvedPath = Resolve-DispatchOutputPathFromContext -CandidatePath $resolvedPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    $safeFailureClass = if ($FailureClass -match '^[A-Za-z][A-Za-z0-9.]*$') { $FailureClass } else { 'Unknown' }
    $capturedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $source = 'quota-source-unavailable'
    $document = [ordered]@{
        schema = 'quota-snapshot.v1'
        state = 'SnapshotUnavailable'
        captured_at_utc = $capturedAtUtc
        source_file = $source
        purpose = $Purpose
        failure_code = 'quota-snapshot-unavailable'
        failure_class = $safeFailureClass
        primary = $null
        secondary = $null
        observations = [ordered]@{
            primary = [ordered]@{
                used_percent = $null
                remaining_percent = $null
                observed_at_utc = $null
                source = $source
                freshness = 'unknown'
                window = 'primary'
                resets_at = $null
            }
            secondary = [ordered]@{
                used_percent = $null
                remaining_percent = $null
                observed_at_utc = $null
                source = $source
                freshness = 'unknown'
                window = 'secondary'
                resets_at = $null
            }
        }
        service_rejection = $null
        service_rejection_evidence = $null
    }
    $resolvedPath = Resolve-DispatchOutputPathFromContext -CandidatePath $resolvedPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    $writeSourceRoot = if ([string]::IsNullOrWhiteSpace($SourceRoot)) { [string](Get-DispatchScriptVariableValue -Name 'SourceRoot') } else { $SourceRoot }
    $writeExecutionRoot = if ([string]::IsNullOrWhiteSpace($ExecutionRoot)) { [string](Get-DispatchScriptVariableValue -Name 'ExecutionRoot') } else { $ExecutionRoot }
    Write-Utf8NoBom -Path $resolvedPath -Content (($document | ConvertTo-Json -Depth 12) + [Environment]::NewLine) -SourceRoot $writeSourceRoot -ExecutionRoot $writeExecutionRoot -TargetPath $TargetPath
    return $resolvedPath
}

function Get-CodexQuotaScriptPath {
    [CmdletBinding()]
    param()

    $entryRootVariable = Get-Variable -Name 'DispatchEntryScriptRoot' -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $entryRootVariable -or [string]::IsNullOrWhiteSpace([string]$entryRootVariable.Value)) {
        throw 'Dispatch entry directory is not initialized.'
    }

    return Join-Path -Path ([string]$entryRootVariable.Value) -ChildPath 'Get-CodexQuota.ps1'
}

function Set-QuotaSnapshotFromCodex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [AllowEmptyString()]
        [string]$SourceRoot,

        [AllowEmptyString()]
        [string]$ExecutionRoot,

        [string[]]$TargetPath,

        [string]$CodexHome
    )

    $context = Get-DispatchOutputPathContext -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    $SourceRoot = $context.SourceRoot
    $ExecutionRoot = $context.ExecutionRoot
    $TargetPath = $context.TargetPath
    $resolvedPath = Resolve-DispatchOutputPath -CandidatePath $Path -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
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

    $parentPath = Split-Path -Parent $resolvedPath
    if (-not [string]::IsNullOrWhiteSpace($parentPath)) {
        $null = New-DispatchOutputDirectory -Path $parentPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    }
    $resolvedPath = Resolve-DispatchOutputPathFromContext -CandidatePath $resolvedPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath

    $quotaScriptPath = Get-CodexQuotaScriptPath
    if (-not (Test-Path -LiteralPath $quotaScriptPath -PathType Leaf)) {
        throw "找不到額度快照腳本：$quotaScriptPath"
    }

    $hostPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ([string]::IsNullOrWhiteSpace($hostPath) -or -not (Test-Path -LiteralPath $hostPath -PathType Leaf)) {
        throw 'QuotaSnapshotHostUnavailable'
    }

    $null = & $hostPath -NoLogo -NoProfile -NonInteractive -File $quotaScriptPath -CodexHome $configuredHome -SnapshotPath $resolvedPath 2>&1
    $quotaExitCode = $LASTEXITCODE
    $snapshotExists = Test-Path -LiteralPath $resolvedPath -PathType Leaf
    if (-not $snapshotExists) {
        throw ('QuotaSnapshotUpdateFailed: exit_code={0}; output_file_exists={1}' -f $quotaExitCode, $snapshotExists)
    }

    $null = Read-QuotaSnapshot -Path $resolvedPath

    return $resolvedPath
}

function Get-OrCreateQuotaSnapshot {
    param(
        [string]$Path,

        [string]$SnapshotPath,

        [string]$CodexHome,

        [AllowEmptyString()]
        [string]$SourceRoot,

        [AllowEmptyString()]
        [string]$ExecutionRoot,

        [string[]]$TargetPath,

        [Parameter(Mandatory)]
        [string]$HistoryRoot,

        [Parameter(Mandatory)]
        [string]$Purpose,

        [switch]$Required
    )

    $context = Get-DispatchOutputPathContext -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    $SourceRoot = $context.SourceRoot
    $ExecutionRoot = $context.ExecutionRoot
    $TargetPath = $context.TargetPath
    $snapshotPathValue = if ([string]::IsNullOrWhiteSpace($SnapshotPath)) {
        New-QuotaSnapshotPath -HistoryRoot $HistoryRoot -Purpose $Purpose
    }
    else {
        Resolve-AbsolutePath -Path $SnapshotPath
    }
    $snapshotPathValue = Resolve-DispatchOutputPathFromContext -CandidatePath $snapshotPathValue -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    $callerPathValue = $null
    $callerPathFailure = $null
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        try {
            $callerPathValue = Resolve-AbsolutePath -Path $Path
        }
        catch {
            $callerPathFailure = $_.Exception
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($callerPathValue) -and
        [string]::Equals($callerPathValue, $snapshotPathValue, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'QuotaSnapshotPathReuseRejected：新 quota snapshot 不可沿用呼叫端提供的 QuotaBeforePath。'
    }

    try {
        if ($null -ne $callerPathFailure) {
            throw $callerPathFailure
        }
        if (-not [string]::IsNullOrWhiteSpace($callerPathValue)) {
            if (-not (Test-Path -LiteralPath $callerPathValue -PathType Leaf)) {
                throw 'CallerSnapshotUnavailable'
            }
            $null = Read-QuotaSnapshot -Path $callerPathValue
        }

        $configuredHome = $CodexHome
        if ([string]::IsNullOrWhiteSpace($configuredHome)) {
            $configuredHome = $env:CODEX_HOME
        }
        if ([string]::IsNullOrWhiteSpace($configuredHome)) {
            $configuredHome = Resolve-CodexHomeForEvidence -CodexHomePath $null
        }
        if ([string]::IsNullOrWhiteSpace($configuredHome)) {
            throw 'CodexHomeUnavailable'
        }

        return Set-QuotaSnapshotFromCodex -Path $snapshotPathValue -CodexHome $configuredHome -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    }
    catch {
        $snapshotFailure = $_.Exception
        if (Test-Path -LiteralPath $snapshotPathValue -PathType Leaf) {
            try {
                $null = Read-QuotaSnapshot -Path $snapshotPathValue
                return $snapshotPathValue
            }
            catch {
            }
        }
        return Write-QuotaSnapshotUnavailable -Path $snapshotPathValue -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath -Purpose $Purpose -FailureClass $snapshotFailure.GetType().Name
    }
}

function New-AdvisorAfterSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CallerPath,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [AllowEmptyString()]
        [string]$SourceRoot,

        [string[]]$TargetPath,

        [Parameter(Mandatory)]
        [string]$HistoryRoot,

        [string]$CodexHome
    )

    if ([string]::IsNullOrWhiteSpace($CallerPath)) {
        throw 'advisor-consult QuotaAfterPath 必須提供路徑。'
    }
    $callerPathValue = Resolve-AbsolutePath -Path $CallerPath
    if (-not (Test-PathWithinRoot -Path $callerPathValue -Root $ExecutionRoot)) {
        throw "advisor-consult QuotaAfterPath 必須位於 executionRoot 內：$callerPathValue"
    }

    $context = Get-DispatchOutputPathContext -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    $SourceRoot = $context.SourceRoot
    $ExecutionRoot = $context.ExecutionRoot
    $TargetPath = $context.TargetPath
    $snapshotPathValue = New-QuotaSnapshotPath -HistoryRoot $HistoryRoot -Purpose 'advisor-before'
    if (-not (Test-PathWithinRoot -Path $snapshotPathValue -Root $ExecutionRoot)) {
        throw "QuotaAfterSnapshotPathRejected：新 advisor snapshot 超出 executionRoot：$snapshotPathValue"
    }
    $snapshotPathValue = Get-OrCreateQuotaSnapshot -Path $callerPathValue -SnapshotPath $snapshotPathValue -CodexHome $CodexHome -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath -HistoryRoot $HistoryRoot -Purpose 'advisor-before' -Required
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

        [string]$CodexHome,

        [string]$SourceRoot,

        [string]$ExecutionRoot,

        [string[]]$TargetPath
    )

    if ($ExpectedSha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'QuotaAfterSnapshotOwnershipInvalid：預期 SHA-256 格式無效。'
    }

    $context = Get-DispatchOutputPathContext -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    $pathValue = Resolve-DispatchOutputPath -CandidatePath $Path -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
    if (-not (Test-Path -LiteralPath $pathValue -PathType Leaf)) {
        throw "QuotaAfterSnapshotMissing：本次執行建立的 after snapshot 不存在：$pathValue"
    }
    $currentSha256 = Get-FileSha256 -Path $pathValue
    if (-not [string]::Equals($currentSha256, $ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "QuotaAfterSnapshotChanged：after snapshot 已被外部變更；path=$pathValue; expected_sha256=$ExpectedSha256; actual_sha256=$currentSha256"
    }

    $parentPath = Split-Path -Parent $pathValue
    $temporaryName = '.' + [System.IO.Path]::GetFileName($pathValue) + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $temporaryPath = Resolve-DispatchOutputPath -CandidatePath (Join-Path -Path $parentPath -ChildPath $temporaryName) -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
    $backupName = '.' + [System.IO.Path]::GetFileName($pathValue) + '.' + [guid]::NewGuid().ToString('N') + '.bak'
    $backupPath = Resolve-DispatchOutputPath -CandidatePath (Join-Path -Path $parentPath -ChildPath $backupName) -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
    try {
        $null = Set-QuotaSnapshotFromCodex -Path $temporaryPath -CodexHome $CodexHome -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
        $admissionLock = $null
        try {
            if (-not [string]::IsNullOrWhiteSpace($SourceRoot)) {
                $admissionLock = Open-DispatchAdmissionLock -SourceRoot $SourceRoot
            }
            $currentSha256 = Get-FileSha256 -Path $pathValue
            if (-not [string]::Equals($currentSha256, $ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
                throw "QuotaAfterSnapshotChanged：after snapshot 在更新期間被外部變更；path=$pathValue; expected_sha256=$ExpectedSha256; actual_sha256=$currentSha256"
            }
            $temporaryPath = Resolve-DispatchOutputPath -CandidatePath $temporaryPath -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
            $pathValue = Resolve-DispatchOutputPath -CandidatePath $pathValue -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
            $backupPath = Resolve-DispatchOutputPath -CandidatePath $backupPath -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
            [System.IO.File]::Replace((ConvertTo-FileSystemApiPath -Path $temporaryPath), (ConvertTo-FileSystemApiPath -Path $pathValue), (ConvertTo-FileSystemApiPath -Path $backupPath))
        }
        finally {
            Close-DispatchAdmissionLock -Lock $admissionLock
        }
        $backupPath = Resolve-DispatchOutputPath -CandidatePath $backupPath -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
        [System.IO.File]::Delete((ConvertTo-FileSystemApiPath -Path $backupPath))
    }
    finally {
        try {
            $temporaryPath = Resolve-DispatchOutputPath -CandidatePath $temporaryPath -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                [System.IO.File]::Delete((ConvertTo-FileSystemApiPath -Path $temporaryPath))
            }
        }
        catch {
        }
        try {
            $backupPath = Resolve-DispatchOutputPath -CandidatePath $backupPath -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                [System.IO.File]::Delete((ConvertTo-FileSystemApiPath -Path $backupPath))
            }
        }
        catch {
        }
    }

    return [pscustomobject]@{
        Path   = $pathValue
        Sha256 = Get-FileSha256 -Path $pathValue
    }
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
        [object]$Record,

        [string]$SourceRoot,

        [string]$ExecutionRoot,

        [string[]]$TargetPath
    )

    Add-AtomicJsonLine -Path $Path -Content (($Record | ConvertTo-Json -Depth 20 -Compress)) -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
}

function Invoke-BudgetMonitorRecordWrite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$Record,

        [string]$SourceRoot,

        [string]$ExecutionRoot,

        [string[]]$TargetPath
    )

    try {
        Write-BudgetMonitorRecord -Path $Path -Record $Record -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
        return $null
    }
    catch {
        return [ordered]@{
            event = 'quota-observation.write-failed'
            recorded_at_utc = [datetime]::UtcNow.ToString('o')
            attempted_event = [string](Get-DispatchJsonProperty -Object $Record -Name 'event')
            terminal = Get-DispatchJsonProperty -Object $Record -Name 'terminal'
            path = $Path
            failure_class = $_.Exception.GetType().FullName
            failure_message = $_.Exception.Message
        }
    }
}

function Get-QuotaObservationPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LineHistoryRoot,

        [Parameter(Mandatory)]
        [string]$DispatchSlug
    )

    return Join-Path -Path $LineHistoryRoot -ChildPath ('quota-observations-' + $DispatchSlug + '.jsonl')
}

function Get-QuotaObservationProgress {
    param(
        [Parameter(Mandatory)]
        [string]$EventPath,

        [AllowNull()]
        [object]$ScopePlan,

        [Parameter(Mandatory)]
        [string]$TaskType
    )

    $usage = $null
    $eventCount = 0
    if (Test-Path -LiteralPath $EventPath -PathType Leaf) {
        foreach ($line in Get-Content -LiteralPath $EventPath -Encoding UTF8) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            $eventCount++
            try {
                $event = $line | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                continue
            }
            if ([string](Get-EventPropertyValue -Object $event -Name 'type') -in @('turn.completed', 'turn.failed')) {
                $eventUsage = Get-EventPropertyValue -Object $event -Name 'usage'
                if ($null -ne $eventUsage) {
                    $usage = $eventUsage
                }
            }
        }
    }

    $safePointMessage = Get-LatestSafePointMessage -EventPath $EventPath -TaskType $TaskType
    $selectedUnits = if ($null -eq $ScopePlan) { @() } else { @(Get-DispatchJsonProperty -Object $ScopePlan -Name 'selected_units') }
    $deferredUnits = if ($null -eq $ScopePlan) { @() } else { @(Get-DispatchJsonProperty -Object $ScopePlan -Name 'deferred_units') }
    $completion = Get-AdvisorCompletionPartition -Message $safePointMessage -SelectedUnits $selectedUnits -DeferredUnits $deferredUnits
    return [ordered]@{
        event_count = $eventCount
        usage = $usage
        confirmed_conclusions = if ([string]::IsNullOrWhiteSpace($safePointMessage)) { $null } else { $safePointMessage }
        completed_units = @($completion.completed_units)
        unfinished_units = @($completion.incomplete_units)
        completion_status = [string]$completion.status
    }
}

function Invoke-QuotaObservationSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExpectedSha256,

        [string]$CodexHome,

        [Parameter(Mandatory)]
        [string]$Purpose,

        [string]$SourceRoot,

        [string]$ExecutionRoot,

        [string[]]$TargetPath
    )

    try {
        $updatedSnapshot = Update-AdvisorAfterSnapshotFromCodex -Path $Path -ExpectedSha256 $ExpectedSha256 -CodexHome $CodexHome -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
        $snapshot = Read-QuotaSnapshot -Path $updatedSnapshot.Path
        return [pscustomobject]@{
            state = if ([string]$snapshot.state -eq 'Valid') { 'Valid' } else { 'unknown' }
            path = [string]$updatedSnapshot.Path
            sha256 = [string]$updatedSnapshot.Sha256
            actual_sha256 = [string]$updatedSnapshot.Sha256
            integrity_conflict = $false
            snapshot = $snapshot
            failure_class = $null
        }
    }
    catch {
        $failureClass = $_.Exception.GetType().Name
        $currentHash = $null
        $nextExpectedHash = $ExpectedSha256
        $integrityConflict = $false
        try {
            $currentHash = Get-FileSha256 -Path $Path
        }
        catch {
        }
        if ($currentHash -and [string]::Equals($currentHash, $ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
            try {
                $null = Write-QuotaSnapshotUnavailable -Path $Path -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath -Purpose $Purpose -FailureClass $failureClass
                $currentHash = Get-FileSha256 -Path $Path
                $nextExpectedHash = $currentHash
            }
            catch {
            }
        }
        elseif ($currentHash) {
            $integrityConflict = $true
        }
        $snapshot = $null
        try {
            $snapshot = Read-QuotaSnapshot -Path $Path
        }
        catch {
        }
        return [pscustomobject]@{
            state = 'unknown'
            path = $Path
            sha256 = $nextExpectedHash
            actual_sha256 = $currentHash
            integrity_conflict = $integrityConflict
            snapshot = $snapshot
            failure_class = $failureClass
        }
    }
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

        [string]$SourceRoot,

        [string]$ExecutionRoot,

        [string[]]$TargetPath,

        [double]$PrimaryBudgetPercent = 0,

        [int]$AbortGraceSeconds = 0,

        [AllowNull()]
        [object]$ScopePlan,

        [ValidateRange(0.1, 86400)]
        [double]$SnapshotRefreshIntervalSeconds = 1800
    )

    $monitor = [ordered]@{
        state = 'running'
        stopRequested = $false
        terminalSnapshotTaken = $false
        afterSnapshotPath = $AfterSnapshotPath
        afterSnapshotSha256 = $AfterSnapshotSha256
        snapshotUpdateCount = 0
        lastSnapshotState = 'unknown'
        writeFailures = @()
    }
    $writeFailure = Invoke-BudgetMonitorRecordWrite -Path $MonitorPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath -Record ([ordered]@{
            event = 'quota-observation.started'
            recorded_at_utc = [datetime]::UtcNow.ToString('o')
            state = 'running'
            after_snapshot_path = $AfterSnapshotPath
            snapshot_refresh_interval_seconds = $SnapshotRefreshIntervalSeconds
        })
    if ($null -ne $writeFailure) {
        $monitor.writeFailures += @($writeFailure)
    }

    $nextSnapshotRefreshAtUtc = [DateTime]::UtcNow.AddSeconds($SnapshotRefreshIntervalSeconds)
    while (-not $Process.HasExited) {
        if ([DateTime]::UtcNow -ge $nextSnapshotRefreshAtUtc) {
            $observation = Invoke-QuotaObservationSnapshot -Path $AfterSnapshotPath -ExpectedSha256 ([string]$monitor.afterSnapshotSha256) -CodexHome $CodexHome -Purpose 'long-task' -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
            $monitor.afterSnapshotSha256 = [string]$observation.sha256
            $monitor.snapshotUpdateCount = [int]$monitor.snapshotUpdateCount + 1
            $monitor.lastSnapshotState = [string]$observation.state
            $progress = Get-QuotaObservationProgress -EventPath $EventPath -ScopePlan $ScopePlan -TaskType 'advisor-consult'
            $snapshot = $observation.snapshot
            $writeFailure = Invoke-BudgetMonitorRecordWrite -Path $MonitorPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath -Record ([ordered]@{
                    event = 'quota.snapshot'
                    recorded_at_utc = [datetime]::UtcNow.ToString('o')
                    state = [string]$observation.state
                    failure_code = if ($observation.state -eq 'unknown') { 'quota-snapshot-unavailable' } else { $null }
                    failure_class = $observation.failure_class
                    terminal = $false
                    snapshot_update_count = $monitor.snapshotUpdateCount
                    after_snapshot_path = $AfterSnapshotPath
                    after_snapshot_sha256 = $monitor.afterSnapshotSha256
                    observed_after_snapshot_sha256 = Get-DispatchJsonProperty -Object $observation -Name 'actual_sha256'
                    after_snapshot_integrity_conflict = [bool](Get-DispatchJsonProperty -Object $observation -Name 'integrity_conflict')
                    primary = if ($null -eq $snapshot) { $null } else { $snapshot.primary }
                    secondary = if ($null -eq $snapshot) { $null } else { $snapshot.secondary }
                    progress = $progress
                })
            if ($null -ne $writeFailure) {
                $monitor.writeFailures += @($writeFailure)
            }
            $nextSnapshotRefreshAtUtc = [DateTime]::UtcNow.AddSeconds($SnapshotRefreshIntervalSeconds)
        }
        Start-Sleep -Milliseconds 250
    }

    $observation = Invoke-QuotaObservationSnapshot -Path $AfterSnapshotPath -ExpectedSha256 ([string]$monitor.afterSnapshotSha256) -CodexHome $CodexHome -Purpose 'close' -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    $monitor.afterSnapshotSha256 = [string]$observation.sha256
    $monitor.snapshotUpdateCount = [int]$monitor.snapshotUpdateCount + 1
    $monitor.lastSnapshotState = [string]$observation.state
    $monitor.terminalSnapshotTaken = $true
    $monitor.state = 'completed'
    $progress = Get-QuotaObservationProgress -EventPath $EventPath -ScopePlan $ScopePlan -TaskType 'advisor-consult'
    $snapshot = $observation.snapshot
    $writeFailure = Invoke-BudgetMonitorRecordWrite -Path $MonitorPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath -Record ([ordered]@{
            event = 'quota.snapshot'
            recorded_at_utc = [datetime]::UtcNow.ToString('o')
            state = [string]$observation.state
            failure_code = if ($observation.state -eq 'unknown') { 'quota-snapshot-unavailable' } else { $null }
            failure_class = $observation.failure_class
            terminal = $true
            snapshot_update_count = $monitor.snapshotUpdateCount
            after_snapshot_path = $AfterSnapshotPath
            after_snapshot_sha256 = $monitor.afterSnapshotSha256
            observed_after_snapshot_sha256 = Get-DispatchJsonProperty -Object $observation -Name 'actual_sha256'
            after_snapshot_integrity_conflict = [bool](Get-DispatchJsonProperty -Object $observation -Name 'integrity_conflict')
            primary = if ($null -eq $snapshot) { $null } else { $snapshot.primary }
            secondary = if ($null -eq $snapshot) { $null } else { $snapshot.secondary }
            progress = $progress
        })
    if ($null -ne $writeFailure) {
        $monitor.writeFailures += @($writeFailure)
    }
    return $monitor
}

function Resolve-CodexHomePath {
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

    $historyRoot = Resolve-DispatchOutputPath -CandidatePath (Join-Path -Path $executionRootPath -ChildPath ('.local\ai-sessions\history\' + $LineSlug)) -SourceRoot '' -ExecutionRoot $executionRootPath -TargetPath @()
    $null = New-DispatchOutputDirectory -Path $historyRoot -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath
    $historyRoot = Resolve-DispatchOutputPath -CandidatePath $historyRoot -SourceRoot '' -ExecutionRoot $executionRootPath -TargetPath @()
    $recoveryPath = Resolve-DispatchOutputPath -CandidatePath (Join-Path -Path $historyRoot -ChildPath ('quota-recovery-' + $DispatchSlug + '.json')) -SourceRoot '' -ExecutionRoot $executionRootPath -TargetPath @()
    if (Test-Path -LiteralPath $recoveryPath -PathType Leaf) {
        throw "QuotaProbe 回復紀錄已存在，拒絕再次執行：$recoveryPath"
    }

    $codexHomePath = Resolve-CodexHomePath -ConfiguredCodexHome $CodexHome
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
        $recoveryPath = Resolve-DispatchOutputPath -CandidatePath $recoveryPath -SourceRoot '' -ExecutionRoot $executionRootPath -TargetPath @()
        Write-Utf8NoBom -Path $recoveryPath -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @() -Content (($noRetryRecord | ConvertTo-Json -Depth 12) + "
")
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
        $recoveryPath = Resolve-DispatchOutputPath -CandidatePath $recoveryPath -SourceRoot '' -ExecutionRoot $executionRootPath -TargetPath @()
        Write-Utf8NoBom -Path $recoveryPath -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @() -Content (($quotaRefreshRecord | ConvertTo-Json -Depth 12) + "
")
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
