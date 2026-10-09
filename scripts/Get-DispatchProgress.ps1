#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$WorkRoot = (Split-Path -Parent $PSScriptRoot),

    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
    [string]$LineSlug,

    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
    [string]$DispatchSlug,

    [switch]$All
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function ConvertFrom-DispatchPidRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        $separator = $line.IndexOf('=')
        if ($separator -le 0) {
            continue
        }
        $key = $line.Substring(0, $separator).Trim()
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }
        $values[$key] = $line.Substring($separator + 1).Trim()
    }
    return $values
}

function ConvertTo-DispatchUtcTimestamp {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    $timestamp = [DateTimeOffset]::MinValue
    $parsed = [DateTimeOffset]::TryParse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$timestamp
    )
    if (-not $parsed) {
        return $null
    }
    return $timestamp.ToUniversalTime()
}

function Get-DispatchEventTimestamp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Event
    )

    foreach ($propertyName in @('timestamp', 'created_at_utc', 'createdAt', 'created_at')) {
        $property = $Event.PSObject.Properties[$propertyName]
        if ($null -eq $property) {
            continue
        }
        $timestamp = ConvertTo-DispatchUtcTimestamp -Value $property.Value
        if ($null -ne $timestamp) {
            return $timestamp
        }
    }
    return $null
}

function Get-DispatchRunEventPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HistoryRoot,

        [Parameter(Mandatory)]
        [string]$WorktreeRoot,

        [Parameter(Mandatory)]
        [string]$LineSlugValue,

        [Parameter(Mandatory)]
        [string]$DispatchSlugValue,

        [Parameter(Mandatory)]
        [string]$PidRecordPath
    )

    $runDirectory = Join-Path -Path (Join-Path -Path (Join-Path -Path $HistoryRoot -ChildPath $LineSlugValue) -ChildPath 'runs') -ChildPath $DispatchSlugValue
    if (Test-Path -LiteralPath $runDirectory -PathType Container) {
        $runRecords = @(Get-ChildItem -LiteralPath $runDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTimeUtc -Descending)
        $selectedRecord = $null
        foreach ($runRecordFile in $runRecords) {
            try {
                $runRecord = [IO.File]::ReadAllText($runRecordFile.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
            }
            catch {
                continue
            }
            if ([string](Get-DispatchObjectProperty -Object $runRecord -Name 'line_slug') -cne $LineSlugValue -or
                [string](Get-DispatchObjectProperty -Object $runRecord -Name 'dispatch_slug') -cne $DispatchSlugValue) {
                continue
            }
            $recordPidPath = [string](Get-DispatchObjectProperty -Object $runRecord -Name 'pid_record_path')
            if (-not [string]::IsNullOrWhiteSpace($recordPidPath) -and [string]::Equals([IO.Path]::GetFullPath($recordPidPath), [IO.Path]::GetFullPath($PidRecordPath), [StringComparison]::OrdinalIgnoreCase)) {
                $selectedRecord = $runRecord
                break
            }
            if ($null -eq $selectedRecord) {
                $selectedRecord = $runRecord
            }
        }
        if ($null -ne $selectedRecord) {
            $eventPath = [string](Get-DispatchObjectProperty -Object $selectedRecord -Name 'event_stream_path')
            if (-not [string]::IsNullOrWhiteSpace($eventPath)) {
                return [IO.Path]::GetFullPath($eventPath)
            }
        }
    }

    $pidFileName = [IO.Path]::GetFileName($PidRecordPath)
    $eventFileName = [regex]::Replace($pidFileName, '^codex-pid-', 'codex-exec-', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $eventFileName = [regex]::Replace($eventFileName, '\.txt$', '.jsonl', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($searchRoot in @($HistoryRoot, $WorktreeRoot)) {
        if (-not (Test-Path -LiteralPath $searchRoot -PathType Container)) {
            continue
        }
        $eventFile = Get-ChildItem -LiteralPath $searchRoot -Filter $eventFileName -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $eventFile) {
            return $eventFile.FullName
        }
    }
    return $null
}

function Get-DispatchObjectProperty {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-DispatchEventStreamSummary {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Path
    )

    $summary = [ordered]@{
        terminal_status = ''
        last_event_utc = $null
        last_agent_message = ''
        error_message = ''
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $summary
    }

    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $isCompleted = $line.StartsWith('{"type":"turn.completed"', [StringComparison]::Ordinal)
        $isFailed = $line.StartsWith('{"type":"turn.failed"', [StringComparison]::Ordinal)
        $event = $null
        try {
            $event = $line | ConvertFrom-Json
        }
        catch {
            continue
        }
        $eventTimestamp = Get-DispatchEventTimestamp -Event $event
        if ($null -ne $eventTimestamp) {
            $summary.last_event_utc = $eventTimestamp
        }
        if ($isCompleted) {
            $summary.terminal_status = 'completed'
        }
        elseif ($isFailed) {
            $summary.terminal_status = 'failed'
            $eventError = Get-DispatchObjectProperty -Object $event -Name 'error'
            $summary.error_message = [string](Get-DispatchObjectProperty -Object $eventError -Name 'message')
        }
        $item = Get-DispatchObjectProperty -Object $event -Name 'item'
        if ([string](Get-DispatchObjectProperty -Object $event -Name 'type') -ceq 'item.completed' -and
            [string](Get-DispatchObjectProperty -Object $item -Name 'type') -ceq 'agent_message') {
            $summary.last_agent_message = [string](Get-DispatchObjectProperty -Object $item -Name 'text')
        }
    }

    if ($null -eq $summary.last_event_utc) {
        $summary.last_event_utc = [DateTimeOffset]([IO.File]::GetLastWriteTimeUtc($Path))
    }
    return $summary
}

function Get-DispatchProcessState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$ProcessId,

        [AllowEmptyString()]
        [string]$ExpectedProcessName,

        [AllowEmptyString()]
        [string]$ExpectedStartedAtUtc
    )

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return [pscustomobject]@{ IsAlive = $false; IdentityStatus = 'process-absent' }
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedProcessName) -or [string]::IsNullOrWhiteSpace($ExpectedStartedAtUtc)) {
        return [pscustomobject]@{ IsAlive = $true; IdentityStatus = 'identity-unconfirmed' }
    }

    if (-not [string]::Equals([string]$process.ProcessName, $ExpectedProcessName, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ IsAlive = $false; IdentityStatus = 'pid-reused-process-name' }
    }

    $expectedStartedAt = ConvertTo-DispatchUtcTimestamp -Value $ExpectedStartedAtUtc
    if ($null -eq $expectedStartedAt) {
        return [pscustomobject]@{ IsAlive = $true; IdentityStatus = 'identity-unconfirmed' }
    }

    try {
        $actualStartedAt = [DateTimeOffset]$process.StartTime.ToUniversalTime()
    }
    catch {
        return [pscustomobject]@{ IsAlive = $true; IdentityStatus = 'identity-unconfirmed' }
    }

    if ([math]::Abs(($actualStartedAt - $expectedStartedAt).TotalSeconds) -gt 1) {
        return [pscustomobject]@{ IsAlive = $false; IdentityStatus = 'pid-reused-start-time' }
    }

    return [pscustomobject]@{ IsAlive = $true; IdentityStatus = 'confirmed' }
}

function ConvertTo-DispatchSummaryText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }
    $singleLine = [regex]::Replace($Text, '\s+', ' ').Trim()
    if ($singleLine.Length -gt 120) {
        return $singleLine.Substring(0, 120)
    }
    return $singleLine
}

function ConvertTo-DispatchTimeSpanText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [TimeSpan]$Value
    )

    return ($Value.Days.ToString([Globalization.CultureInfo]::InvariantCulture) + '.' + $Value.ToString('hh\:mm\:ss', [Globalization.CultureInfo]::InvariantCulture))
}

$workRootPath = [IO.Path]::GetFullPath($WorkRoot)
if (-not (Test-Path -LiteralPath $workRootPath -PathType Container)) {
    throw "WorkRoot 不存在或不是資料夾：$workRootPath"
}
$historyRoot = Join-Path -Path $workRootPath -ChildPath '.local\ai-sessions\history'
$worktreeRoot = Join-Path -Path $workRootPath -ChildPath '.local\ai-sessions\worktrees'
if (-not (Test-Path -LiteralPath $historyRoot -PathType Container)) {
    return
}

$nowUtc = [DateTimeOffset]::UtcNow
$progressRows = New-Object 'System.Collections.Generic.List[object]'
foreach ($pidRecordFile in @(Get-ChildItem -LiteralPath $historyRoot -Filter 'codex-pid-*.txt' -File -ErrorAction SilentlyContinue)) {
    $pidRecord = ConvertFrom-DispatchPidRecord -Path $pidRecordFile.FullName
    $lineSlugValue = [string]$pidRecord['line-slug']
    $dispatchSlugValue = [string]$pidRecord['dispatch-slug']
    if ([string]::IsNullOrWhiteSpace($lineSlugValue) -or [string]::IsNullOrWhiteSpace($dispatchSlugValue)) {
        continue
    }
    if (-not [string]::IsNullOrWhiteSpace($LineSlug) -and $lineSlugValue -cne $LineSlug) {
        continue
    }
    if (-not [string]::IsNullOrWhiteSpace($DispatchSlug) -and $dispatchSlugValue -cne $DispatchSlug) {
        continue
    }

    $rootPidValue = $pidRecord['root-pid']
    if ([string]::IsNullOrWhiteSpace([string]$rootPidValue)) {
        $rootPidValue = $pidRecord['pid']
    }
    $rootPid = 0
    $rootPidIdentityStatus = 'invalid-pid'
    if (-not [int]::TryParse([string]$rootPidValue, [ref]$rootPid) -or $rootPid -le 0) {
        $rootPidAlive = $false
        $rootPid = 0
    }
    else {
        $processState = Get-DispatchProcessState `
            -ProcessId $rootPid `
            -ExpectedProcessName ([string]$pidRecord['root-process-name']) `
            -ExpectedStartedAtUtc ([string]$pidRecord['root-started-at-utc'])
        $rootPidAlive = [bool]$processState.IsAlive
        $rootPidIdentityStatus = [string]$processState.IdentityStatus
    }

    $startedAtUtc = ConvertTo-DispatchUtcTimestamp -Value $pidRecord['started-at-utc']
    if ($null -eq $startedAtUtc) {
        $startedAtUtc = [DateTimeOffset]([IO.File]::GetLastWriteTimeUtc($pidRecordFile.FullName))
    }
    $eventPath = Get-DispatchRunEventPath -HistoryRoot $historyRoot -WorktreeRoot $worktreeRoot -LineSlugValue $lineSlugValue -DispatchSlugValue $dispatchSlugValue -PidRecordPath $pidRecordFile.FullName
    $eventSummary = Get-DispatchEventStreamSummary -Path $eventPath
    $lastEventUtc = $eventSummary.last_event_utc
    $lastEventAge = $null
    if ($null -ne $lastEventUtc) {
        $lastEventAge = $nowUtc - [DateTimeOffset]$lastEventUtc
        if ($lastEventAge.Ticks -lt 0) {
            $lastEventAge = [TimeSpan]::Zero
        }
    }

    $status = [string]$eventSummary.terminal_status
    if ([string]::IsNullOrWhiteSpace($status)) {
        if (-not $rootPidAlive) {
            $status = 'interrupted'
        }
        elseif ($null -ne $lastEventAge -and $lastEventAge.TotalMinutes -le 20) {
            $status = 'running'
        }
        else {
            $status = 'stale'
        }
    }
    if (-not $All -and $status -in @('completed', 'failed') -and ($null -eq $lastEventAge -or $lastEventAge.TotalHours -gt 24)) {
        continue
    }

    $elapsedEndUtc = if ($status -in @('completed', 'failed') -and $null -ne $lastEventUtc) { [DateTimeOffset]$lastEventUtc } else { $nowUtc }
    $elapsed = $elapsedEndUtc - $startedAtUtc
    if ($elapsed.Ticks -lt 0) {
        $elapsed = [TimeSpan]::Zero
    }
    $progressRows.Add([pscustomobject][ordered]@{
            dispatchSlug = $dispatchSlugValue
            lineSlug = $lineSlugValue
            startedAtLocal = $startedAtUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz', [Globalization.CultureInfo]::InvariantCulture)
            elapsed = ConvertTo-DispatchTimeSpanText -Value $elapsed
            lastEventAge = if ($null -eq $lastEventAge) { '' } else { ConvertTo-DispatchTimeSpanText -Value $lastEventAge }
            rootPidAlive = $rootPidAlive
            lastAgentMessageSummary = ConvertTo-DispatchSummaryText -Text ([string]$eventSummary.last_agent_message)
            status = $status
            errorMessageSummary = if ($status -eq 'failed') { ConvertTo-DispatchSummaryText -Text ([string]$eventSummary.error_message) } else { '' }
            rootPid = $rootPid
            rootPidIdentityStatus = $rootPidIdentityStatus
            eventStreamPath = [string]$eventPath
        })
}

$progressRows.ToArray() | Sort-Object -Property startedAtLocal, dispatchSlug
