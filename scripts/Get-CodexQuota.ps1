#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$CodexHome = $env:CODEX_HOME
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
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -First 20
    )

    $fileIndex = 0
    foreach ($file in $rolloutFiles) {
        $fileIndex++
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
                            SourceLastWriteTime = $file.LastWriteTimeUtc
                            RecordIndex         = $recordIndex
                            FileIndex            = $fileIndex
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

try {
    $codexHomePath = Get-CodexHomeDirectory -ConfiguredCodexHome $CodexHome
    $sessionsPath = Join-Path -Path $codexHomePath -ChildPath 'sessions'
    $currentUnixTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $candidates = @(Get-RolloutSnapshotCandidate -SessionsPath $sessionsPath)
    $selectedSnapshots = @{}

    foreach ($windowName in @('primary', 'secondary')) {
        $futureCandidates = @(
            $candidates | Where-Object {
                $_.WindowName -eq $windowName -and $_.ResetsAt -gt $currentUnixTime
            }
        )

        if ($futureCandidates.Count -eq 0) {
            throw "找不到有效額度快照：$windowName 視窗在最近 20 個 rollout 檔沒有 resets_at 大於目前時間的候選。掃描路徑：$sessionsPath"
        }

        $maxResetsAt = ($futureCandidates | Measure-Object -Property ResetsAt -Maximum).Maximum
        $currentWindowCandidates = @(
            $futureCandidates | Where-Object { $_.ResetsAt -eq $maxResetsAt }
        )
        $selectedSnapshot = $currentWindowCandidates |
            Sort-Object -Property @(
                @{ Expression = 'SourceLastWriteTime'; Descending = $true }
                @{ Expression = 'RecordIndex'; Descending = $true }
                @{ Expression = 'FileIndex'; Descending = $true }
            ) |
            Select-Object -First 1

        if ($null -eq $selectedSnapshot) {
            throw "找不到有效額度快照：無法選出 $windowName 視窗的最大 resets_at 候選。"
        }

        $selectedSnapshots[$windowName] = $selectedSnapshot
    }

    Write-QuotaWindow -WindowName 'primary' -Snapshot $selectedSnapshots['primary'] -CurrentUnixTime $currentUnixTime
    Write-QuotaWindow -WindowName 'secondary' -Snapshot $selectedSnapshots['secondary'] -CurrentUnixTime $currentUnixTime
    exit 0
}
catch {
    [Console]::Error.WriteLine(('Get-CodexQuota.ps1 失敗：{0}' -f $_.Exception.Message))
    exit 1
}
