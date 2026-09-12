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

        [string]$ErrorMessage
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $document = [ordered]@{
        schema         = 'quota-snapshot.v1'
        captured_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        state          = $State
        primary        = $null
        secondary      = $null
        error          = if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $null } else { $ErrorMessage }
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

try {
    $windowDecisions = New-Object System.Collections.Generic.List[object]
    $codexHomePath = Get-CodexHomeDirectory -ConfiguredCodexHome $CodexHome
    $sessionsPath = Join-Path -Path $codexHomePath -ChildPath 'sessions'
    $currentUnixTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $candidates = @(Get-RolloutSnapshotCandidate -SessionsPath $sessionsPath)
    $selectedSnapshots = @{}
    foreach ($windowName in @('primary', 'secondary')) {
        $decision = Get-QuotaWindowDecision -Candidates $candidates -WindowName $windowName -CurrentUnixTime $currentUnixTime
        $windowDecisions.Add($decision)
        if ($decision.State -eq 'Valid') {
            $selectedSnapshots[$windowName] = $decision.SelectedSnapshot
        }
    }

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

        if ($allStatesRecoverable) {
            $message += '；於本機執行一次 codex exec 產生新 rollout 後重讀即可回復。'
        }

        throw $message
    }

    if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
        $snapshotFullPath = [System.IO.Path]::GetFullPath($SnapshotPath)
        Write-QuotaSnapshotDocument -Path $snapshotFullPath -State 'Valid' -CurrentUnixTime $currentUnixTime -Primary $selectedSnapshots['primary'] -Secondary $selectedSnapshots['secondary']
    }

    Write-QuotaWindow -WindowName 'primary' -Snapshot $selectedSnapshots['primary'] -CurrentUnixTime $currentUnixTime
    Write-QuotaWindow -WindowName 'secondary' -Snapshot $selectedSnapshots['secondary'] -CurrentUnixTime $currentUnixTime
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
            Write-QuotaSnapshotDocument -Path ([System.IO.Path]::GetFullPath($SnapshotPath)) -State $failureState -CurrentUnixTime ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Primary $null -Secondary $null -ErrorMessage $_.Exception.Message
        }
        catch {
            [Console]::Error.WriteLine(('quota snapshot 寫入失敗：{0}' -f $_.Exception.Message))
        }
    }
    [Console]::Error.WriteLine(('Get-CodexQuota.ps1 失敗：{0}' -f $_.Exception.Message))
    exit 1
}
