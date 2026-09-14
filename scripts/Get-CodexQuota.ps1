#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$CodexHome = $env:CODEX_HOME,

    [string]$SnapshotPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CodexHomeDirectory {
    param(
        [string]$ConfiguredCodexHome
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredCodexHome)) {
        return [System.IO.Path]::GetFullPath($ConfiguredCodexHome)
    }

    $userProfile = [System.Environment]::GetFolderPath(
        [System.Environment+SpecialFolder]::UserProfile
    )
    if ([string]::IsNullOrWhiteSpace($userProfile)) {
        throw '無法判定使用者 Profile 路徑，請設定 CODEX_HOME。'
    }

    return (Join-Path -Path $userProfile -ChildPath '.codex')
}

function Get-RolloutSnapshotCandidate {
    param(
        [Parameter(Mandatory)]
        [string]$SessionsPath
    )

    if (-not (Test-Path -LiteralPath $SessionsPath -PathType Container)) {
        throw "找不到 Codex sessions 目錄：$SessionsPath"
    }

    $rolloutFiles = @(
        Get-ChildItem -LiteralPath $SessionsPath -Recurse -File -Filter 'rollout-*.jsonl' |
            Sort-Object -Property Name -Descending |
            Select-Object -First 20
    )

    foreach ($file in $rolloutFiles) {
        $recordIndex = 0

        try {
            foreach ($line in Get-Content -LiteralPath $file.FullName -Encoding UTF8) {
                $recordIndex++
                if ([string]::IsNullOrWhiteSpace($line)) {
                    continue
                }

                try {
                    $record = $line | ConvertFrom-Json -ErrorAction Stop
                    if ($null -eq $record) {
                        continue
                    }

                    $timestampProperty = $record.PSObject.Properties['timestamp']
                    if ($null -eq $timestampProperty -or $null -eq $timestampProperty.Value) {
                        continue
                    }

                    try {
                        $eventTimestamp = [DateTimeOffset]$timestampProperty.Value
                        $eventTimestampUnix = $eventTimestamp.ToUnixTimeSeconds()
                    }
                    catch {
                        continue
                    }

                    if ($eventTimestampUnix -le 0) {
                        continue
                    }

                    $payloadProperty = $record.PSObject.Properties['payload']
                    if ($null -eq $payloadProperty -or $null -eq $payloadProperty.Value) {
                        continue
                    }

                    $payload = $payloadProperty.Value
                    $rateLimitsProperty = $payload.PSObject.Properties['rate_limits']
                    if ($null -eq $rateLimitsProperty -or $null -eq $rateLimitsProperty.Value) {
                        continue
                    }

                    $rateLimits = $rateLimitsProperty.Value
                    foreach ($windowName in @('primary', 'secondary')) {
                        $windowProperty = $rateLimits.PSObject.Properties[$windowName]
                        if ($null -eq $windowProperty -or $null -eq $windowProperty.Value) {
                            continue
                        }

                        $window = $windowProperty.Value
                        $usedProperty = $window.PSObject.Properties['used_percent']
                        $minutesProperty = $window.PSObject.Properties['window_minutes']
                        $resetProperty = $window.PSObject.Properties['resets_at']
                        if (
                            $null -eq $usedProperty -or
                            $null -eq $minutesProperty -or
                            $null -eq $resetProperty
                        ) {
                            continue
                        }

                        try {
                            $usedPercent = [double]$usedProperty.Value
                            $windowMinutesValue = [double]$minutesProperty.Value
                            $resetsAtValue = [double]$resetProperty.Value
                        }
                        catch {
                            continue
                        }

                        if (
                            [double]::IsNaN($usedPercent) -or
                            [double]::IsInfinity($usedPercent) -or
                            $usedPercent -lt 0 -or
                            $usedPercent -gt 100 -or
                            [double]::IsNaN($windowMinutesValue) -or
                            [double]::IsInfinity($windowMinutesValue) -or
                            $windowMinutesValue -le 0 -or
                            [math]::Truncate($windowMinutesValue) -ne $windowMinutesValue -or
                            [double]::IsNaN($resetsAtValue) -or
                            [double]::IsInfinity($resetsAtValue) -or
                            $resetsAtValue -le 0 -or
                            [math]::Truncate($resetsAtValue) -ne $resetsAtValue
                        ) {
                            continue
                        }

                        [pscustomobject]@{
                             WindowName          = $windowName
                             UsedPercent         = $usedPercent
                             WindowMinutes       = [int64]$windowMinutesValue
                             ResetsAt            = [int64]$resetsAtValue
                             SourceFile          = $file.Name
                             SourcePath          = $file.FullName
                             EventTimestamp      = $eventTimestamp
                             EventTimestampUnix  = $eventTimestampUnix
                             RecordIndex         = $recordIndex
                        }
                    }
                }
                catch {
                    continue
                }
            }
        }
        catch {
            Write-Verbose (
                '略過無法讀取的 rollout 檔：{0}。原因：{1}' -f
                $file.FullName,
                $_.Exception.Message
            )
        }
    }
}

function Get-FileSha256 {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        $sha256.Dispose()
    }
}

function Get-ObjectPropertyValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string[]]$Names
    )

    if ($null -eq $Object) {
        return $null
    }
    foreach ($name in $Names) {
        if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($name)) {
            if ($null -ne $Object[$name]) {
                return $Object[$name]
            }
            continue
        }
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            return $property.Value
        }
    }
    return $null
}

function Get-RolloutServiceRejection {
    param(
        [Parameter(Mandatory)]
        [string]$SessionsPath
    )

    if (-not (Test-Path -LiteralPath $SessionsPath -PathType Container)) {
        return $null
    }

    $rejections = New-Object System.Collections.Generic.List[object]
    $hashByPath = @{}
    $rolloutFiles = @(
        Get-ChildItem -LiteralPath $SessionsPath -Recurse -File -Filter 'rollout-*.jsonl' |
            Sort-Object -Property Name -Descending |
            Select-Object -First 20
    )
    foreach ($file in $rolloutFiles) {
        try {
            if (-not $hashByPath.ContainsKey($file.FullName)) {
                $hashByPath[$file.FullName] = Get-FileSha256 -Path $file.FullName
            }
            $recordIndex = 0
            foreach ($line in Get-Content -LiteralPath $file.FullName -Encoding UTF8) {
                $recordIndex++
                if ([string]::IsNullOrWhiteSpace($line) -or $line -notmatch '(?i)(?:usage|rate)[\s_-]*limit(?:ed| exceeded|\b)|quota\s+exceeded|too\s+many\s+requests|\b429\b') {
                    continue
                }

                $record = $null
                try {
                    $record = $line | ConvertFrom-Json -ErrorAction Stop
                }
                catch {
                }
                $timestampValue = Get-ObjectPropertyValue -Object $record -Names @('timestamp', 'created_at', 'observed_at_utc')
                $observedAtUtc = [DateTimeOffset]::UtcNow
                if ($null -ne $timestampValue) {
                    try {
                        $observedAtUtc = [DateTimeOffset]$timestampValue
                    }
                    catch {
                    }
                }
                $reasonCode = 'quota-rejected'
                if ($line -match '(?i)usage[\s_-]*limit(?:ed| exceeded|\b)') {
                    $reasonCode = 'usage-limit'
                }
                elseif ($line -match '(?i)rate[\s_-]*limit(?:ed| exceeded|\b)') {
                    $reasonCode = 'rate-limit'
                }
                elseif ($line -match '(?i)quota\s+exceeded') {
                    $reasonCode = 'quota-exceeded'
                }
                elseif ($line -match '(?i)too\s+many\s+requests|\b429\b') {
                    $reasonCode = 'too-many-requests'
                }

                $windowName = 'unknown'
                if ($line -match '(?i)secondary') {
                    $windowName = 'secondary'
                }
                elseif ($line -match '(?i)primary') {
                    $windowName = 'primary'
                }
                $payload = Get-ObjectPropertyValue -Object $record -Names @('payload', 'error', 'data')
                $rateLimits = Get-ObjectPropertyValue -Object $payload -Names @('rate_limits', 'rateLimits')
                $windowObject = if ($windowName -in @('primary', 'secondary')) { Get-ObjectPropertyValue -Object $rateLimits -Names @($windowName) } else { $null }
                $resetValue = Get-ObjectPropertyValue -Object $windowObject -Names @('resets_at', 'reset_at', 'resetAt')
                $resetAt = $null
                if ($null -ne $resetValue) {
                    try {
                        $resetAt = [int64]$resetValue
                    }
                    catch {
                    }
                }

                $rejections.Add([pscustomobject]@{
                        Status              = 'quota-rejected'
                        Window              = $windowName
                        ReasonCode          = $reasonCode
                        ObservedAtUtc       = $observedAtUtc
                        RawEvidencePath     = $file.FullName
                        RawEvidenceFileName = $file.Name
                        RawEvidenceSha256   = $hashByPath[$file.FullName]
                        ResetsAt            = $resetAt
                        RetryAllowed        = $false
                        RecordIndex         = $recordIndex
                    })
            }
        }
        catch {
            Write-Verbose ('略過無法讀取的 service rejection rollout 檔：{0}。原因：{1}' -f $file.FullName, $_.Exception.Message)
        }
    }

    if ($rejections.Count -eq 0) {
        return $null
    }
    return @(
        $rejections.ToArray() |
            Sort-Object -Property @(
                @{ Expression = 'ObservedAtUtc'; Descending = $true }
                @{ Expression = 'RecordIndex'; Descending = $true }
                @{ Expression = 'RawEvidencePath'; Descending = $true }
            ) |
            Select-Object -First 1
    )[0]
}

function Get-ObservationFreshness {
    param(
        [Parameter(Mandatory)]
        [DateTimeOffset]$ObservedAtUtc,

        [int]$MaxAgeMinutes = 30
    )

    $ageMinutes = ([DateTimeOffset]::UtcNow - $ObservedAtUtc).TotalMinutes
    if ($ageMinutes -ge 0 -and $ageMinutes -le $MaxAgeMinutes) {
        return 'fresh'
    }
    if ($ageMinutes -gt $MaxAgeMinutes) {
        return 'stale'
    }
    return 'unknown'
}

function New-QuotaObservation {
    param(
        [Parameter(Mandatory)]
        [string]$WindowName,

        [Parameter(Mandatory)]
        [pscustomobject]$Candidate
    )

    return [ordered]@{
        used_percent      = [double]$Candidate.UsedPercent
        remaining_percent = 100.0 - [double]$Candidate.UsedPercent
        observed_at_utc   = $Candidate.EventTimestamp.ToUniversalTime().ToString('o')
        source            = 'Get-CodexQuota.ps1:' + [string]$Candidate.SourcePath
        freshness         = Get-ObservationFreshness -ObservedAtUtc $Candidate.EventTimestamp.ToUniversalTime()
        window            = $WindowName
        resets_at         = [int64]$Candidate.ResetsAt
    }
}

function ConvertTo-ServiceRejectionDocumentValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$ServiceRejection,

        [switch]$IncludeAudit
    )

    if ($null -eq $ServiceRejection) {
        return $null
    }

    $rawEvidencePath = [string](Get-ObjectPropertyValue -Object $ServiceRejection -Names @('raw_evidence_path', 'RawEvidencePath'))
    $rawEvidenceFile = [string](Get-ObjectPropertyValue -Object $ServiceRejection -Names @('raw_evidence_file', 'RawEvidenceFileName'))
    if ([string]::IsNullOrWhiteSpace($rawEvidenceFile) -and -not [string]::IsNullOrWhiteSpace($rawEvidencePath)) {
        $rawEvidenceFile = Split-Path -Leaf $rawEvidencePath
    }

    $observedAtValue = Get-ObjectPropertyValue -Object $ServiceRejection -Names @('observed_at_utc', 'ObservedAtUtc')
    $observedAtText = if ($null -eq $observedAtValue) { '' } else { [string]$observedAtValue }
    try {
        $observedAtText = ([DateTimeOffset]$observedAtValue).ToUniversalTime().ToString('o')
    }
    catch {
    }

    $document = [ordered]@{
        status              = [string](Get-ObjectPropertyValue -Object $ServiceRejection -Names @('status', 'Status'))
        window              = [string](Get-ObjectPropertyValue -Object $ServiceRejection -Names @('window', 'Window'))
        reason_code         = [string](Get-ObjectPropertyValue -Object $ServiceRejection -Names @('reason_code', 'ReasonCode'))
        observed_at_utc     = $observedAtText
        raw_evidence_path   = $rawEvidencePath
        raw_evidence_sha256 = [string](Get-ObjectPropertyValue -Object $ServiceRejection -Names @('raw_evidence_sha256', 'RawEvidenceSha256'))
        resets_at           = Get-ObjectPropertyValue -Object $ServiceRejection -Names @('resets_at', 'ResetsAt')
        retry_allowed       = [bool](Get-ObjectPropertyValue -Object $ServiceRejection -Names @('retry_allowed', 'RetryAllowed'))
    }

    if ($IncludeAudit) {
        $supersededValue = Get-ObjectPropertyValue -Object $ServiceRejection -Names @('superseded')
        $supersededByValue = Get-ObjectPropertyValue -Object $ServiceRejection -Names @('superseded_by_observation')
        $supersededByDocument = $null
        if ($null -ne $supersededByValue) {
            $supersededObservedAtValue = Get-ObjectPropertyValue -Object $supersededByValue -Names @('observed_at_utc')
            $supersededObservedAtText = if ($null -eq $supersededObservedAtValue) { $null } else { [string]$supersededObservedAtValue }
            try {
                $supersededObservedAtText = ([DateTimeOffset]$supersededObservedAtValue).ToUniversalTime().ToString('o')
            }
            catch {
            }
            $recordIndexValue = Get-ObjectPropertyValue -Object $supersededByValue -Names @('record_index')
            $supersededByDocument = [ordered]@{
                window          = [string](Get-ObjectPropertyValue -Object $supersededByValue -Names @('window'))
                observed_at_utc = $supersededObservedAtText
                source_file     = [string](Get-ObjectPropertyValue -Object $supersededByValue -Names @('source_file'))
                source_path     = [string](Get-ObjectPropertyValue -Object $supersededByValue -Names @('source_path'))
                freshness       = [string](Get-ObjectPropertyValue -Object $supersededByValue -Names @('freshness'))
                record_index    = if ($null -eq $recordIndexValue) { $null } else { [int64]$recordIndexValue }
            }
        }
        $document['raw_evidence_file'] = $rawEvidenceFile
        $document['superseded'] = if ($null -eq $supersededValue) { $false } else { [bool]$supersededValue }
        $document['superseded_by_observation'] = $supersededByDocument
    }

    return $document
}

function Resolve-ServiceRejectionState {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$ServiceRejection,

        [AllowEmptyCollection()]
        [object[]]$Candidates
    )

    if ($null -eq $ServiceRejection) {
        return [pscustomobject]@{
            Active   = $null
            Evidence = $null
        }
    }

    $evidence = ConvertTo-ServiceRejectionDocumentValue -ServiceRejection $ServiceRejection -IncludeAudit
    $observedAtValue = Get-ObjectPropertyValue -Object $ServiceRejection -Names @('observed_at_utc', 'ObservedAtUtc')
    $observedAtUtc = [DateTimeOffset]::MinValue
    try {
        $observedAtUtc = [DateTimeOffset]$observedAtValue
    }
    catch {
        return [pscustomobject]@{
            Active   = $ServiceRejection
            Evidence = $evidence
        }
    }

    $rejectionWindow = [string](Get-ObjectPropertyValue -Object $ServiceRejection -Names @('window', 'Window'))
    $rejectionPath = [string](Get-ObjectPropertyValue -Object $ServiceRejection -Names @('raw_evidence_path', 'RawEvidencePath'))
    $rejectionFile = [string](Get-ObjectPropertyValue -Object $ServiceRejection -Names @('raw_evidence_file', 'RawEvidenceFileName'))
    if ([string]::IsNullOrWhiteSpace($rejectionFile) -and -not [string]::IsNullOrWhiteSpace($rejectionPath)) {
        $rejectionFile = Split-Path -Leaf $rejectionPath
    }

    $supersedingCandidates = @(
        foreach ($candidate in @($Candidates)) {
            if ($null -eq $candidate) {
                continue
            }
            if ($rejectionWindow -in @('primary', 'secondary') -and [string]$candidate.WindowName -ne $rejectionWindow) {
                continue
            }

            $candidatePath = [string]$candidate.SourcePath
            $candidateFile = [string]$candidate.SourceFile
            $sameSource = -not [string]::IsNullOrWhiteSpace($rejectionPath) -and
                [string]::Equals($candidatePath, $rejectionPath, [StringComparison]::OrdinalIgnoreCase)
            $newerRollout = $false
            if (-not $sameSource -and -not [string]::IsNullOrWhiteSpace($rejectionFile) -and -not [string]::IsNullOrWhiteSpace($candidateFile)) {
                $newerRollout = [StringComparer]::OrdinalIgnoreCase.Compare($candidateFile, $rejectionFile) -gt 0
            }
            if (-not $sameSource -and -not $newerRollout) {
                continue
            }

            try {
                $candidateObservedAtUtc = ([DateTimeOffset]$candidate.EventTimestamp).ToUniversalTime()
                if ($candidateObservedAtUtc -le $observedAtUtc -or (Get-ObservationFreshness -ObservedAtUtc $candidateObservedAtUtc) -ne 'fresh') {
                    continue
                }
            }
            catch {
                continue
            }
            $candidate
        }
    )
    $supersedingCandidate = $supersedingCandidates |
        Sort-Object -Property @(
            @{ Expression = 'EventTimestamp'; Descending = $true }
            @{ Expression = 'RecordIndex'; Descending = $true }
            @{ Expression = 'SourceFile'; Descending = $true }
        ) |
        Select-Object -First 1

    if ($null -eq $supersedingCandidate) {
        return [pscustomobject]@{
            Active   = $ServiceRejection
            Evidence = $evidence
        }
    }

    $supersedingTimestamp = ([DateTimeOffset]$supersedingCandidate.EventTimestamp).ToUniversalTime()
    $evidence['superseded'] = $true
    $evidence['superseded_by_observation'] = [ordered]@{
        window          = [string]$supersedingCandidate.WindowName
        observed_at_utc = $supersedingTimestamp.ToString('o')
        source_file     = [string]$supersedingCandidate.SourceFile
        source_path     = [string]$supersedingCandidate.SourcePath
        freshness       = 'fresh'
        record_index    = [int64]$supersedingCandidate.RecordIndex
    }
    return [pscustomobject]@{
        Active   = $null
        Evidence = $evidence
    }
}

function New-UnknownQuotaObservation {
    param(
        [Parameter(Mandatory)]
        [string]$WindowName,

        [AllowNull()]
        [object]$Window
    )

    if ($null -eq $Window) {
        return [ordered]@{
            used_percent      = $null
            remaining_percent = $null
            observed_at_utc   = $null
            source            = 'snapshot-unavailable'
            freshness         = 'unknown'
            window            = $WindowName
            resets_at         = $null
        }
    }
    return [ordered]@{
        used_percent      = [double]$Window.used_percent
        remaining_percent = [double]$Window.remaining_percent
        observed_at_utc   = $null
        source            = [string]$Window.source_file
        freshness         = 'unknown'
        window            = $WindowName
        resets_at         = [int64]$Window.resets_at
    }
}

function Get-PreviousQuotaDocument {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Format-InvariantNumber {
    param(
        [Parameter(Mandatory)]
        [double]$Value
    )

    return $Value.ToString('0.########', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-InvariantInteger {
    param(
        [Parameter(Mandatory)]
        [int64]$Value
    )

    return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Write-QuotaWindow {
    param(
        [Parameter(Mandatory)]
        [string]$WindowName,

        [Parameter(Mandatory)]
        [pscustomobject]$Snapshot,

        [Parameter(Mandatory)]
        [int64]$CurrentUnixTime
    )

    $prefix = $WindowName + '_'
    $remainingPercent = 100.0 - [double]$Snapshot.UsedPercent
    $daysToReset = (
        [double]$Snapshot.ResetsAt - [double]$CurrentUnixTime
    ) / 86400.0
    $windowDays = [double]$Snapshot.WindowMinutes / 1440.0
    $resetsAtLocal = [DateTimeOffset]::FromUnixTimeSeconds([long]$Snapshot.ResetsAt).ToLocalTime().ToString(
        'yyyy-MM-dd HH:mm',
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    Write-Output ($prefix + 'used_percent=' + (Format-InvariantNumber -Value $Snapshot.UsedPercent))
    Write-Output ($prefix + 'remaining_percent=' + (Format-InvariantNumber -Value $remainingPercent))
    Write-Output ($prefix + 'days_to_reset=' + (Format-InvariantNumber -Value $daysToReset))
    Write-Output ($prefix + 'window_minutes=' + (Format-InvariantInteger -Value $Snapshot.WindowMinutes))
    Write-Output ($prefix + 'window_days=' + (Format-InvariantNumber -Value $windowDays))
    Write-Output ($prefix + 'resets_at=' + (Format-InvariantInteger -Value $Snapshot.ResetsAt))
    Write-Output ($prefix + 'resets_at_local=' + $resetsAtLocal)
    Write-Output ($prefix + 'source_file=' + $Snapshot.SourceFile)
}

function Write-QuotaSnapshotDocument {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$State,

        [Parameter(Mandatory)]
        [int64]$CurrentUnixTime,

        [AllowNull()]
        [object]$Primary,

        [AllowNull()]
        [object]$Secondary,

        [string]$ErrorMessage,

        [AllowNull()]
        [object]$Observations,

        [AllowNull()]
        [object]$ServiceRejection,

        [AllowNull()]
        [object]$ServiceRejectionEvidence,

        [AllowNull()]
        [object]$PreviousDocument,

        [string]$CodexHomePath
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $normalizedServiceRejection = ConvertTo-ServiceRejectionDocumentValue -ServiceRejection $ServiceRejection
    $normalizedServiceRejectionEvidence = $null
    if ($null -ne $ServiceRejectionEvidence) {
        $normalizedServiceRejectionEvidence = ConvertTo-ServiceRejectionDocumentValue -ServiceRejection $ServiceRejectionEvidence -IncludeAudit
    }
    elseif ($null -ne $ServiceRejection) {
        $normalizedServiceRejectionEvidence = ConvertTo-ServiceRejectionDocumentValue -ServiceRejection $ServiceRejection -IncludeAudit
    }
    elseif ($null -ne $PreviousDocument) {
        $previousEvidenceProperty = $PreviousDocument.PSObject.Properties['service_rejection_evidence']
        if ($null -ne $previousEvidenceProperty -and $null -ne $previousEvidenceProperty.Value) {
            $normalizedServiceRejectionEvidence = ConvertTo-ServiceRejectionDocumentValue -ServiceRejection $previousEvidenceProperty.Value -IncludeAudit
        }
    }
    $document = [ordered]@{
        schema          = 'ai-sessions.quota-snapshot.v1'
        captured_at_utc = $null
        state           = $State
        primary         = $null
        secondary       = $null
        observations    = $null
        service_rejection = $normalizedServiceRejection
        service_rejection_evidence = $normalizedServiceRejectionEvidence
        error           = if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $null } else { $ErrorMessage }
        codex_home      = if ([string]::IsNullOrWhiteSpace($CodexHomePath)) { $null } else { $CodexHomePath }
    }
    foreach ($window in @(
            [pscustomobject]@{ Name = 'primary'; Value = $Primary }
            [pscustomobject]@{ Name = 'secondary'; Value = $Secondary }
        )) {
        if ($null -eq $window.Value) {
            continue
        }
        $daysToReset = ([double]$window.Value.ResetsAt - [double]$CurrentUnixTime) / 86400.0
        $windowDays = [double]$window.Value.WindowMinutes / 1440.0
        $document[$window.Name] = [ordered]@{
            used_percent      = [double]$window.Value.UsedPercent
            remaining_percent = 100.0 - [double]$window.Value.UsedPercent
            window_minutes    = [int64]$window.Value.WindowMinutes
            resets_at         = [int64]$window.Value.ResetsAt
            source_file       = [string]$window.Value.SourceFile
            days_to_reset     = $daysToReset
            window_days       = $windowDays
        }
    }
    if ($null -eq $document.primary -and $null -ne $PreviousDocument) {
        $previousPrimary = $PreviousDocument.PSObject.Properties['primary']
        if ($null -ne $previousPrimary -and $null -ne $previousPrimary.Value) {
            $document.primary = $previousPrimary.Value
        }
    }
    if ($null -eq $document.secondary -and $null -ne $PreviousDocument) {
        $previousSecondary = $PreviousDocument.PSObject.Properties['secondary']
        if ($null -ne $previousSecondary -and $null -ne $previousSecondary.Value) {
            $document.secondary = $previousSecondary.Value
        }
    }
    if ($null -ne $Observations) {
        $document.observations = $Observations
    }
    elseif ($null -ne $PreviousDocument) {
        $previousObservations = $PreviousDocument.PSObject.Properties['observations']
        if ($null -ne $previousObservations -and $null -ne $previousObservations.Value) {
            $document.observations = $previousObservations.Value
        }
        else {
            $document.observations = [ordered]@{
                primary   = New-UnknownQuotaObservation -WindowName 'primary' -Window $document.primary
                secondary = New-UnknownQuotaObservation -WindowName 'secondary' -Window $document.secondary
            }
        }
    }
    if ($null -ne $document.observations) {
        $capturedCandidates = New-Object System.Collections.Generic.List[DateTimeOffset]
        foreach ($windowName in @('primary', 'secondary')) {
            $observation = Get-ObjectPropertyValue -Object $document.observations -Names @($windowName)
            if ($null -eq $observation) {
                continue
            }
            $observedAtValue = Get-ObjectPropertyValue -Object $observation -Names @('observed_at_utc')
            if ($null -eq $observedAtValue -or [string]::IsNullOrWhiteSpace([string]$observedAtValue)) {
                continue
            }
            try {
                $capturedCandidates.Add([DateTimeOffset]$observedAtValue)
            }
            catch {
            }
        }
        if ($capturedCandidates.Count -gt 0) {
            $document.captured_at_utc = ($capturedCandidates | Sort-Object | Select-Object -Last 1).ToUniversalTime().ToString('o')
        }
    }
    if ($null -eq $document.captured_at_utc -and $null -ne $PreviousDocument) {
        $previousCaptured = $PreviousDocument.PSObject.Properties['captured_at_utc']
        if ($null -ne $previousCaptured -and -not [string]::IsNullOrWhiteSpace([string]$previousCaptured.Value)) {
            $document.captured_at_utc = [string]$previousCaptured.Value
        }
    }
    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList @($false)
    [System.IO.File]::WriteAllText($Path, (($document | ConvertTo-Json -Depth 8) + "`r`n"), $encoding)
}

function Get-QuotaWindowDecision {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Candidates,

        [Parameter(Mandatory)]
        [string]$WindowName,

        [Parameter(Mandatory)]
        [int64]$CurrentUnixTime
    )

    $windowCandidates = @(
        $Candidates | Where-Object { $_.WindowName -eq $WindowName }
    )
    $recentCandidates = @(
        $windowCandidates | Where-Object {
            ([double]$CurrentUnixTime - [double]$_.EventTimestampUnix) -ge 0 -and
            ([double]$CurrentUnixTime - [double]$_.EventTimestampUnix) -le ([double]$_.WindowMinutes * 60.0)
        }
    )
    $futureCandidates = @(
        $recentCandidates | Where-Object { $_.ResetsAt -gt $CurrentUnixTime }
    )
    $preResetCandidates = @(
        $recentCandidates | Where-Object {
            [double]$_.EventTimestampUnix -lt [double]$_.ResetsAt -and
            [double]$_.ResetsAt -le [double]$CurrentUnixTime
        }
    )

    if ($futureCandidates.Count -gt 0) {
        $validCandidates = @($futureCandidates)
        $chronologicalCandidates = @(
            $validCandidates |
                Sort-Object -Property @(
                    @{ Expression = 'EventTimestamp'; Descending = $false }
                    @{ Expression = 'RecordIndex'; Descending = $false }
                    @{ Expression = 'SourceFile'; Descending = $false }
                )
        )
        $jumpPointUnix = $null

        for ($candidateIndex = 1; $candidateIndex -lt $chronologicalCandidates.Count; $candidateIndex++) {
            $candidate = $chronologicalCandidates[$candidateIndex]

            $earlierCandidate = $chronologicalCandidates[$candidateIndex - 1]
            $isLaterEvent = (
                [double]$candidate.EventTimestampUnix -gt
                [double]$earlierCandidate.EventTimestampUnix
            )
            $hasNotCrossedReset = (
                [double]$candidate.EventTimestampUnix -lt
                [double]$earlierCandidate.ResetsAt
            )
            $usedPercentDecreased = (
                [double]$candidate.UsedPercent -lt
                [double]$earlierCandidate.UsedPercent
            )

            if ($isLaterEvent -and $hasNotCrossedReset -and $usedPercentDecreased) {
                if (
                    $null -eq $jumpPointUnix -or
                    [double]$candidate.EventTimestampUnix -gt [double]$jumpPointUnix
                ) {
                    $jumpPointUnix = [int64]$candidate.EventTimestampUnix
                }
            }
        }

        $validCandidates = @(
            $validCandidates | Where-Object {
                ($null -eq $jumpPointUnix -or [double]$_.EventTimestampUnix -ge [double]$jumpPointUnix)
            }
        )

        if ($validCandidates.Count -gt 0) {
            # 以額度事件時間排序與判斷新鮮度，避免後續追加事件改變來源檔案時間。
            $selectedSnapshot = $validCandidates |
                Sort-Object -Property @(
                    @{ Expression = 'EventTimestamp'; Descending = $true }
                    @{ Expression = 'RecordIndex'; Descending = $true }
                    @{ Expression = 'SourceFile'; Descending = $true }
                ) |
                Select-Object -First 1

            if ($null -ne $selectedSnapshot) {
                return [pscustomobject]@{
                    WindowName             = $WindowName
                    State                  = 'Valid'
                    SelectedSnapshot      = $selectedSnapshot
                    StructuralCandidateCount = $windowCandidates.Count
                    RecentCandidateCount   = $recentCandidates.Count
                    FutureCandidateCount   = $futureCandidates.Count
                    PreResetCandidateCount = $preResetCandidates.Count
                    JumpPointUnix          = $jumpPointUnix
                }
            }
        }

        return [pscustomobject]@{
            WindowName             = $WindowName
            State                  = 'SnapshotUnavailable'
            SelectedSnapshot       = $null
            StructuralCandidateCount = $windowCandidates.Count
            RecentCandidateCount   = $recentCandidates.Count
            FutureCandidateCount   = $futureCandidates.Count
            PreResetCandidateCount = $preResetCandidates.Count
            JumpPointUnix          = $jumpPointUnix
            Reason                 = '跳變失效化後沒有可選候選。'
        }
    }

    if ($preResetCandidates.Count -gt 0) {
        return [pscustomobject]@{
            WindowName             = $WindowName
            State                  = 'PostResetNoSnapshot'
            SelectedSnapshot       = $null
            StructuralCandidateCount = $windowCandidates.Count
            RecentCandidateCount   = $recentCandidates.Count
            FutureCandidateCount   = $futureCandidates.Count
            PreResetCandidateCount = $preResetCandidates.Count
            JumpPointUnix          = $null
        }
    }

    $state = if ($windowCandidates.Count -gt 0) { 'SnapshotExpired' } else { 'SnapshotUnavailable' }
    return [pscustomobject]@{
        WindowName             = $WindowName
        State                  = $state
        SelectedSnapshot       = $null
        StructuralCandidateCount = $windowCandidates.Count
        RecentCandidateCount   = $recentCandidates.Count
        FutureCandidateCount   = $futureCandidates.Count
        PreResetCandidateCount = $preResetCandidates.Count
        JumpPointUnix          = $null
    }
}

$windowDecisions = $null
$previousDocument = $null
$serviceRejection = $null
$serviceRejectionEvidence = $null
$codexHomePath = $null

try {
    $windowDecisions = New-Object System.Collections.Generic.List[object]
    $codexHomePath = Get-CodexHomeDirectory -ConfiguredCodexHome $CodexHome
    $sessionsPath = Join-Path -Path $codexHomePath -ChildPath 'sessions'
    $previousDocument = Get-PreviousQuotaDocument -Path $SnapshotPath
    $serviceRejection = $null
    $currentUnixTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $candidates = @(Get-RolloutSnapshotCandidate -SessionsPath $sessionsPath)
    $serviceRejection = Get-RolloutServiceRejection -SessionsPath $sessionsPath
    $selectedSnapshots = @{}
    foreach ($windowName in @('primary', 'secondary')) {
        $decision = Get-QuotaWindowDecision -Candidates $candidates -WindowName $windowName -CurrentUnixTime $currentUnixTime
        $windowDecisions.Add($decision)
        if ($decision.State -eq 'Valid') {
            $selectedSnapshots[$windowName] = $decision.SelectedSnapshot
        }
    }
    $serviceRejectionResolution = Resolve-ServiceRejectionState -ServiceRejection $serviceRejection -Candidates @($selectedSnapshots.Values)
    $serviceRejection = $serviceRejectionResolution.Active
    $serviceRejectionEvidence = $serviceRejectionResolution.Evidence

    $failedDecisions = @($windowDecisions | Where-Object { $_.State -ne 'Valid' })
    if ($failedDecisions.Count -gt 0) {
        # 失效視窗附上最新候選的來源與時間差。缺少這項時，呼叫端只知道判定失敗，
        # 無從分辨是「資料過期、跑一次 Codex 即可回復」或「解析前提已壞」。
        $stateDetails = @(
            $failedDecisions | ForEach-Object {
                $failedWindowName = $_.WindowName
                $detail = 'quota_state={0} window={1}' -f $_.State, $failedWindowName
                $latestCandidate = @(
                    $candidates |
                        Where-Object { $_.WindowName -eq $failedWindowName } |
                        Sort-Object -Property @(
                            @{ Expression = 'EventTimestamp'; Descending = $true }
                            @{ Expression = 'RecordIndex'; Descending = $true }
                        ) |
                        Select-Object -First 1
                )

                if ($latestCandidate.Count -gt 0) {
                    $ageMinutes = ([double]$currentUnixTime - [double]$latestCandidate[0].EventTimestampUnix) / 60.0
                    $detail += ' latest_source_file={0} latest_event_age_minutes={1} window_minutes={2}' -f
                        $latestCandidate[0].SourceFile,
                        (Format-InvariantNumber -Value $ageMinutes),
                        (Format-InvariantInteger -Value $latestCandidate[0].WindowMinutes)
                }
                else {
                    $detail += ' latest_source_file=none'
                }

                $detail
            }
        ) -join '; '
        # 回復提示只在解析可信、僅資料過期時才成立。SnapshotUnavailable 連結構有效候選都沒有，
        # 附上提示會把「前提已壞」誤導成「跑一次 Codex 就好」。
        # 判定條件是「全部失效視窗都可回復」。取「任一」會在 primary 為 SnapshotExpired、
        # secondary 為 SnapshotUnavailable 時仍附提示，但探針解決不了 SnapshotUnavailable。
        $recoverableStates = @('PostResetNoSnapshot', 'SnapshotExpired')
        $allStatesRecoverable = @(
            $failedDecisions | Where-Object { $recoverableStates -notcontains $_.State }
        ).Count -eq 0
        $message = "額度快照狀態無法進入門檻判定：$stateDetails；掃描路徑：$sessionsPath"
        if ($null -ne $serviceRejection) {
            $message += '；service rejection 已保存，禁止無條件 retry：' + $serviceRejection.ReasonCode
        }

        if ($allStatesRecoverable) {
            $message += '；於本機執行一次 codex exec 產生新 rollout 後重讀即可回復。'
        }

        throw $message
    }

    if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
        $snapshotFullPath = [System.IO.Path]::GetFullPath($SnapshotPath)
        $observations = [ordered]@{
            primary   = New-QuotaObservation -WindowName 'primary' -Candidate $selectedSnapshots['primary']
            secondary = New-QuotaObservation -WindowName 'secondary' -Candidate $selectedSnapshots['secondary']
        }
        Write-QuotaSnapshotDocument -Path $snapshotFullPath -State 'Valid' -CurrentUnixTime $currentUnixTime -Primary $selectedSnapshots['primary'] -Secondary $selectedSnapshots['secondary'] -Observations $observations -ServiceRejection $serviceRejection -ServiceRejectionEvidence $serviceRejectionEvidence -PreviousDocument $previousDocument -CodexHomePath $codexHomePath
    }

    Write-QuotaWindow -WindowName 'primary' -Snapshot $selectedSnapshots['primary'] -CurrentUnixTime $currentUnixTime
    Write-QuotaWindow -WindowName 'secondary' -Snapshot $selectedSnapshots['secondary'] -CurrentUnixTime $currentUnixTime
    if ($null -ne $serviceRejection) {
        Write-Output ('service_rejection_status=' + $serviceRejection.Status)
        Write-Output ('service_rejection_window=' + $serviceRejection.Window)
        Write-Output ('service_rejection_reason_code=' + $serviceRejection.ReasonCode)
        Write-Output ('service_rejection_raw_evidence_path=' + $serviceRejection.RawEvidencePath)
        Write-Output ('service_rejection_raw_evidence_sha256=' + $serviceRejection.RawEvidenceSha256)
        Write-Output 'service_rejection_retry_allowed=false'
    }
    exit 0
}
catch {
    if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
        try {
            $failureState = 'SnapshotUnavailable'
            if ($null -ne $windowDecisions -and $windowDecisions.Count -gt 0) {
                $failedDecision = @($windowDecisions | Where-Object { $_.State -ne 'Valid' } | Select-Object -First 1)
                if ($failedDecision.Count -gt 0) {
                    $failureState = [string]$failedDecision[0].State
                }
            }
            $failureServiceRejection = $serviceRejection
            if ($null -eq $failureServiceRejection -and $null -ne $previousDocument) {
                $previousServiceRejection = $previousDocument.PSObject.Properties['service_rejection']
                if ($null -ne $previousServiceRejection) {
                    $failureServiceRejection = $previousServiceRejection.Value
                }
            }
            $failureServiceRejectionEvidence = $serviceRejectionEvidence
            if ($null -eq $failureServiceRejectionEvidence -and $null -ne $previousDocument) {
                $previousServiceRejectionEvidence = $previousDocument.PSObject.Properties['service_rejection_evidence']
                if ($null -ne $previousServiceRejectionEvidence) {
                    $failureServiceRejectionEvidence = $previousServiceRejectionEvidence.Value
                }
            }
            if ($null -eq $failureServiceRejectionEvidence -and $null -ne $failureServiceRejection) {
                $failureServiceRejectionEvidence = ConvertTo-ServiceRejectionDocumentValue -ServiceRejection $failureServiceRejection -IncludeAudit
            }
            if ($null -ne $failureServiceRejection) {
                $failureState = 'ServiceRejected'
            }
            Write-QuotaSnapshotDocument -Path ([System.IO.Path]::GetFullPath($SnapshotPath)) -State $failureState -CurrentUnixTime ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Primary $null -Secondary $null -ErrorMessage $_.Exception.Message -ServiceRejection $failureServiceRejection -ServiceRejectionEvidence $failureServiceRejectionEvidence -PreviousDocument $previousDocument -CodexHomePath $codexHomePath
        }
        catch {
            [Console]::Error.WriteLine(('quota snapshot 寫入失敗：{0}' -f $_.Exception.Message))
        }
    }
    [Console]::Error.WriteLine(('Get-CodexQuota.ps1 失敗：{0}' -f $_.Exception.Message))
    exit 1
}
