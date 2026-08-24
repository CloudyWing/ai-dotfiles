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
                    $primaryProperty = $rateLimits.PSObject.Properties['primary']
                    if ($null -eq $primaryProperty -or $null -eq $primaryProperty.Value) {
                        continue
                    }

                    $primary = $primaryProperty.Value
                    $usedProperty = $primary.PSObject.Properties['used_percent']
                    $windowProperty = $primary.PSObject.Properties['window_minutes']
                    $resetProperty = $primary.PSObject.Properties['resets_at']
                    if (
                        $null -eq $usedProperty -or
                        $null -eq $windowProperty -or
                        $null -eq $resetProperty
                    ) {
                        continue
                    }

                    try {
                        $usedPercent = [double]$usedProperty.Value
                        $windowMinutes = [int64]$windowProperty.Value
                        $resetsAt = [int64]$resetProperty.Value
                    }
                    catch {
                        continue
                    }

                    if (
                        [double]::IsNaN($usedPercent) -or
                        [double]::IsInfinity($usedPercent) -or
                        $usedPercent -lt 0 -or
                        $usedPercent -gt 100 -or
                        $windowMinutes -le 0 -or
                        $resetsAt -le 0
                    ) {
                        continue
                    }

                    [pscustomobject]@{
                        UsedPercent         = $usedPercent
                        WindowMinutes       = $windowMinutes
                        ResetsAt            = $resetsAt
                        SourceFile          = $file.Name
                        SourceLastWriteTime = $file.LastWriteTimeUtc
                        RecordIndex         = $recordIndex
                        FileIndex            = $fileIndex
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

    return $Value.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture)
}

try {
    $codexHomePath = Get-CodexHomeDirectory -ConfiguredCodexHome $CodexHome
    $sessionsPath = Join-Path -Path $codexHomePath -ChildPath 'sessions'
    $currentUnixTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $candidates = @(Get-RolloutSnapshotCandidate -SessionsPath $sessionsPath)
    $futureCandidates = @(
        $candidates | Where-Object { $_.ResetsAt -gt $currentUnixTime }
    )

    if ($futureCandidates.Count -eq 0) {
        throw "找不到有效額度快照：最近 20 個 rollout 檔沒有 resets_at 大於目前時間的候選。掃描路徑：$sessionsPath"
    }

    $maxResetsAt = ($futureCandidates | Measure-Object -Property ResetsAt -Maximum).Maximum
    $currentWindowCandidates = @(
        $futureCandidates | Where-Object { $_.ResetsAt -eq $maxResetsAt }
    )
    $selectedSnapshot = $currentWindowCandidates |
        Sort-Object -Property SourceLastWriteTime, RecordIndex -Descending |
        Select-Object -First 1

    if ($null -eq $selectedSnapshot) {
        throw '找不到有效額度快照：無法選出最大 resets_at 的候選。'
    }

    $remainingPercent = 100.0 - [double]$selectedSnapshot.UsedPercent
    $daysToReset = (
        [double]$selectedSnapshot.ResetsAt - [double]$currentUnixTime
    ) / 86400.0
    $windowDays = [double]$selectedSnapshot.WindowMinutes / 1440.0
    $resetsAtLocal = [DateTimeOffset]::FromUnixTimeSeconds([long]$selectedSnapshot.ResetsAt).ToLocalTime().ToString(
        'yyyy-MM-dd HH:mm',
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    Write-Output ('used_percent={0}' -f (Format-InvariantNumber -Value $selectedSnapshot.UsedPercent))
    Write-Output ('remaining_percent={0}' -f (Format-InvariantNumber -Value $remainingPercent))
    Write-Output ('days_to_reset={0}' -f (Format-InvariantNumber -Value $daysToReset))
    Write-Output ('window_days={0}' -f (Format-InvariantNumber -Value $windowDays))
    Write-Output ('resets_at={0}' -f $selectedSnapshot.ResetsAt)
    Write-Output ('resets_at_local={0}' -f $resetsAtLocal)
    Write-Output ('source_file={0}' -f $selectedSnapshot.SourceFile)
    exit 0
}
catch {
    [Console]::Error.WriteLine(('Get-CodexQuota.ps1 失敗：{0}' -f $_.Exception.Message))
    exit 1
}
