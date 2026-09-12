#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Preflight', 'Start', 'Inspect', 'Collect', 'QuotaProbe')]
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

    [string]$PreflightResultPath,

    [string]$CodexPath,

    [string]$PromptPath,

    [ValidateSet('default', 'deep')]
    [string]$Profile = 'default',

    [ValidateSet('Valid', 'PostResetNoSnapshot', 'SnapshotExpired', 'SnapshotUnavailable')]
    [string]$InitialQuotaState = 'PostResetNoSnapshot',

    [ValidateSet('primary', 'secondary', 'both', 'unknown')]
    [string]$TriggerWindow = 'unknown',

    [ValidateRange(1, 2)]
    [int]$ProbeAttempt = 1,

    [string]$CodexHome,

    [string]$Model = 'gpt-5.6-luna',

    [string]$ReasoningEffort = 'xhigh',

    [string]$TaskType = 'unspecified',

    [ValidateSet('cold-start', 'continuation')]
    [string]$SessionMode = 'cold-start',

    [ValidateSet('agent-proposal', 'user-explicit')]
    [string]$DeepRequestSource,

    [Nullable[double]]$SecondaryDaysToReset,

    [Nullable[double]]$SecondaryRemainingPercent,

    [Alias('DowngradeInstruction')]
    [switch]$InterruptionSafeguard,

    [string]$QuotaBeforePath,

    [string]$QuotaAfterPath,

    [string]$CalibrationPath,

    [string]$ScopePlanPath,

    [string[]]$RequestedUnit,

    [ValidateSet('workflow-phase', 'resource-target', 'deep-evidence-pack')]
    [string]$UnitKind,

    [ValidateRange(0, 100)]
    [Nullable[double]]$PrimaryBudgetPercent,

    [ValidateRange(0, 100)]
    [Nullable[double]]$PrimaryReservePercent,

    [string]$EvidencePackPath,

    [string]$DeepConsultReportPath,

    [ValidateRange(5, 60)]
    [int]$AbortGraceSeconds = 30,

    [string]$BudgetMonitorPath,

    [string[]]$AddDirectory,

    [switch]$Search,

    [string[]]$CodexParentOption,

    [string]$ResumeThreadId,

    [string]$EventStreamPath,

    [string]$ErrorStreamPath,

    [string]$LastMessagePath,

    [string]$ThreadIdPath,

    [string]$PidRecordPath,

    [Parameter(Mandatory = $false)]
    [Nullable[int]]$ProcessExitCode,

    [string]$RequiredIdentifier,

    [string]$BaseSha,

    [ValidateSet('workflow', 'resource')]
    [string]$DispatchKind,

    [string]$RequirementSummaryPath,

    [string[]]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsWindowsPlatform {
    return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
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
            $startInfo.StandardOutputEncoding = $utf8NoBom
            $startInfo.StandardErrorEncoding = $utf8NoBom
        }
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
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "無法啟動外部命令：$FileName"
        }

        if ($null -ne $StandardInput) {
            $process.StandardInput.Write($StandardInput)
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
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Append-Utf8NoBom {
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
    [System.IO.File]::AppendAllText($Path, $Content + [Environment]::NewLine, $encoding)
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
        if ($null -eq $schemaProperty -or $schemaProperty.Value -ne 'quota-snapshot.v1') {
            throw "額度快照 schema 不支援：$snapshotPath"
        }
        if ($null -eq $stateProperty -or $stateProperty.Value -ne 'Valid') {
            $stateValue = if ($null -eq $stateProperty) { '<missing>' } else { [string]$stateProperty.Value }
            throw "額度快照 state 不可用：$snapshotPath；quota_state=$stateValue"
        }

        $windowValues = [ordered]@{}
        $windowObjects = [ordered]@{}
        foreach ($windowName in @('primary', 'secondary')) {
            $windowProperty = $document.PSObject.Properties[$windowName]
            if ($null -eq $windowProperty -or $null -eq $windowProperty.Value) {
                throw "額度快照缺少視窗：$snapshotPath；$windowName"
            }

            $window = $windowProperty.Value
            foreach ($requiredName in @('used_percent', 'remaining_percent', 'window_minutes', 'resets_at', 'source_file')) {
                $requiredProperty = $window.PSObject.Properties[$requiredName]
                if ($null -eq $requiredProperty -or $null -eq $requiredProperty.Value -or ([string]$requiredName -eq 'source_file' -and [string]::IsNullOrWhiteSpace([string]$requiredProperty.Value))) {
                    throw "額度快照缺少欄位：$snapshotPath；$windowName.$requiredName"
                }
            }

            $usedPercent = [double]$window.used_percent
            $remainingPercent = [double]$window.remaining_percent
            $windowMinutes = [int64]$window.window_minutes
            $resetsAt = [int64]$window.resets_at
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

        $capturedAtUtc = $null
        $capturedAtValid = $true
        $capturedAtProperty = $document.PSObject.Properties['captured_at_utc']
        if ($null -ne $capturedAtProperty -and -not [string]::IsNullOrWhiteSpace([string]$capturedAtProperty.Value)) {
            try {
                $capturedAtUtc = [DateTimeOffset]$capturedAtProperty.Value
            }
            catch {
                $capturedAtValid = $false
            }
        }
        elseif ($null -eq $capturedAtProperty -or [string]::IsNullOrWhiteSpace([string]$capturedAtProperty.Value)) {
            $capturedAtValid = $false
        }

        return [ordered]@{
            path          = $snapshotPath
            schema        = 'quota-snapshot.v1'
            state         = if ($capturedAtValid) { 'Valid' } else { 'Invalid' }
            capturedAtUtc = $capturedAtUtc
            values        = $windowValues
            primary       = $windowObjects['primary']
            secondary     = $windowObjects['secondary']
            document      = $document
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
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Test-QuotaSnapshotFresh {
    param(
        [Parameter(Mandatory)]
        [psobject]$Snapshot,

        [int]$MaxAgeMinutes = 30
    )

    if ($Snapshot.state -ne 'Valid' -or $null -eq $Snapshot.capturedAtUtc) {
        return $false
    }
    $ageMinutes = ([DateTimeOffset]::UtcNow - [DateTimeOffset]$Snapshot.capturedAtUtc).TotalMinutes
    return $ageMinutes -ge 0 -and $ageMinutes -le $MaxAgeMinutes
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

function Get-DeepCycleDecision {
    param(
        [Parameter(Mandatory)]
        [string]$RequestedProfile,

        [string]$RequestSource,

        [Nullable[double]]$DaysToReset,

        [Nullable[double]]$RemainingPercent,

        [switch]$AllowUnknownForUserExplicit
    )

    if ($RequestedProfile -ne 'deep') {
        return [ordered]@{
            applicable       = $false
            requestSource    = $RequestSource
            gatePassed       = $null
            daysToReset      = $DaysToReset
            remainingPercent = $RemainingPercent
            notice           = ''
        }
    }

    if ([string]::IsNullOrWhiteSpace($RequestSource)) {
        throw '使用 deep 時必須明確指定 DeepRequestSource，區分主 Agent 主動提議與使用者明示要求。'
    }
    if ($null -eq $DaysToReset -or $null -eq $RemainingPercent) {
        if ($RequestSource -eq 'user-explicit' -and $AllowUnknownForUserExplicit) {
            return [ordered]@{
                applicable       = $true
                requestSource    = $RequestSource
                gatePassed       = $null
                cycleDataKnown   = $false
                daysToReset      = $DaysToReset
                remainingPercent = $RemainingPercent
                notice           = 'secondary 週期位置與剩餘額度尚未知；QuotaProbe 尚未取得重設後新快照。使用者明示要求 deep，保留 deep 檔位授權，暫不套用週期位置 gate。'
            }
        }
        throw '使用 deep 時必須提供 SecondaryDaysToReset 與 SecondaryRemainingPercent。'
    }
    if ($DaysToReset -lt 0 -or $RemainingPercent -lt 0 -or $RemainingPercent -gt 100) {
        throw "deep 週期位置或剩餘額度無效：days_to_reset=$DaysToReset; remaining_percent=$RemainingPercent"
    }

    $gatePassed = $DaysToReset -le 2 -and $RemainingPercent -ge 40
    $notice = 'secondary 距重設 {0} 天、剩餘 {1}%；' -f $DaysToReset, $RemainingPercent
    if ($RequestSource -eq 'agent-proposal' -and -not $gatePassed) {
        throw "主 Agent 主動提議 deep 已被週期位置 gate 擋下：$notice 需要 days_to_reset <= 2 且 remaining_percent >= 40。"
    }
    if ($RequestSource -eq 'user-explicit') {
        $notice = $notice + '使用者明示要求 deep，週期位置 gate 不阻擋本次派遣。'
    }

    return [ordered]@{
        applicable       = $true
        requestSource    = $RequestSource
        gatePassed       = $gatePassed
        cycleDataKnown   = $true
        daysToReset      = $DaysToReset
        remainingPercent = $RemainingPercent
        notice           = $notice
    }
}

function Get-ConservativeEstimate {
    param(
        [Parameter(Mandatory)]
        [string]$TaskType
    )

    switch ($TaskType.ToLowerInvariant()) {
        'deep-consult' { return 24.0 }
        'readonly-review' { return 7.0 }
        'review' { return 7.0 }
        'script-change' { return 14.0 }
        default { return $null }
    }
}

function Get-CalibrationEstimate {
    param(
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Model,

        [Parameter(Mandatory)]
        [string]$Profile,

        [Parameter(Mandatory)]
        [string]$SessionMode,

        [Parameter(Mandatory)]
        [string]$TaskType
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [ordered]@{
            estimate = $null
            source   = 'none'
            sampleCount = 0
        }
    }

    $records = @(Get-CalibrationRecords -Path $Path | Where-Object {
            $_.calibration_eligible -eq $true -and
            $_.model -eq $Model -and
            $_.profile -eq $Profile -and
            $_.session_mode -eq $SessionMode -and
            $_.task_type -eq $TaskType -and
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
        }
    }

    return [ordered]@{
        estimate = $null
        source   = 'insufficient-samples'
        sampleCount = $deltas.Count
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

        [string[]]$TargetPath
    )

    $units = New-Object System.Collections.Generic.List[string]
    if ($null -ne $RequestedUnit -and $RequestedUnit.Count -gt 0) {
        foreach ($unit in $RequestedUnit) {
            if ([string]::IsNullOrWhiteSpace($unit)) {
                throw 'RequestedUnit 不可包含空白項目。'
            }
            $units.Add($unit.Trim())
        }
    }
    elseif ($UnitKind -eq 'deep-evidence-pack' -or $EvidencePackPath) {
        $units.Add('evidence-pack')
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

    if ($null -eq $Snapshot -or $Snapshot.state -ne 'Valid') {
        return $false
    }

    return [double]$Snapshot.primary.remaining_percent -ge 30.0 -and
        [double]$Snapshot.secondary.remaining_percent -ge 15.0
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
    if ($TaskType -eq 'deep-consult') {
        return 'deep-evidence-pack'
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

        [Parameter(Mandatory)]
        [string]$Model
    )

    if ($null -eq $BeforeSnapshot -or $BeforeSnapshot.state -ne 'Valid') {
        throw 'ScopePlan 必須使用有效的 before quota snapshot。'
    }
    if (-not (Test-QuotaSnapshotFresh -Snapshot $BeforeSnapshot)) {
        throw 'ScopePlan 必須使用含有效 captured_at_utc 且仍新鮮的 before quota snapshot。'
    }
    if ($Units.Count -eq 0) {
        throw 'ScopePlan 不可使用空的單位清單。'
    }

    $remaining = [double]$BeforeSnapshot.primary.remaining_percent
    if ($TaskType -eq 'deep-consult') {
        if ($null -eq $RequestedReservePercent) {
            $reserve = 30.0
        }
        else {
            $reserve = [math]::Max(30.0, [double]$RequestedReservePercent)
        }
    }
    else {
        $reserve = if ($null -eq $RequestedReservePercent) { 30.0 } else { [double]$RequestedReservePercent }
    }
    $calibration = Get-CalibrationEstimate -Path $CalibrationPath -Model $Model -Profile $RequestedProfile -SessionMode $SessionMode -TaskType $TaskType
    $conservative = Get-ConservativeEstimate -TaskType $TaskType
    $estimate = $null
    $estimateSource = 'none'
    if ($null -ne $calibration.estimate) {
        $estimate = [math]::Max([double]$calibration.estimate, $(if ($null -eq $conservative) { 0.0 } else { [double]$conservative }))
        $estimateSource = $calibration.source
    }
    elseif ($null -ne $conservative) {
        $estimate = [double]$conservative
        $estimateSource = 'conservative-default'
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
    }

    if ($TaskType -ne 'deep-consult' -and $RequestedProfile -eq 'default' -and (Test-DefaultProfileThreshold -Snapshot $BeforeSnapshot)) {
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

    if ($null -eq $estimate) {
        if ($TaskType -eq 'deep-consult') {
            $plan.decision_reason = 'deep-consult 找不到同分組 eligible 校準樣本，也沒有 task type 保守量級。'
        }
        else {
            $plan.decision = 'user-decision-required'
            $plan.decision_reason = '額度低於目標檔位門檻，且找不到同分組 eligible 校準樣本或 task type 保守量級，需要使用者決定等待 primary_resets_at 或調整範圍。'
        }
        return $plan
    }

    $hardLimit = if ($TaskType -eq 'deep-consult') { [double]$estimate * 1.25 } else { [double]::PositiveInfinity }
    $remainingBudget = $remaining - $reserve
    $budget = if ($null -eq $RequestedBudgetPercent) { $remainingBudget } else { [double]$RequestedBudgetPercent }
    if ($TaskType -eq 'deep-consult') {
        $budget = [math]::Min($hardLimit, $remainingBudget)
    }
    else {
        $budget = [math]::Min($budget, $remainingBudget)
    }
    $plan.primary_budget_percent = $budget

    if ($budget -le 0) {
        $plan.decision = 'blocked-insufficient-budget'
        $plan.decision_reason = 'primary 預估保留門檻後沒有可用預算，等待 primary_resets_at 或使用者決定。'
        return $plan
    }

    $selected = New-Object System.Collections.Generic.List[string]
    $consumed = 0.0
    foreach ($unit in $Units) {
        if ($consumed + [double]$estimate -le $budget) {
            $selected.Add($unit)
            $consumed += [double]$estimate
        }
        else {
            break
        }
    }
    $plan.selected_units = @($selected.ToArray())
    $plan.deferred_units = @($Units | Where-Object { $plan.selected_units -notcontains $_ })
    if ($plan.selected_units.Count -eq 0) {
        $plan.decision = 'blocked-insufficient-budget'
        $plan.decision_reason = '第一個最小單位超出可用預算，等待 primary_resets_at 或使用者決定。'
    }
    elseif ($plan.selected_units.Count -eq $Units.Count) {
        $plan.decision = 'full'
        $plan.decision_reason = '完整單位清單可容納於保留門檻後的有效預算。'
    }
    else {
        $plan.decision = 'scoped'
        $plan.decision_reason = '依宣告順序取可容納的最長前綴，延後未選單位。'
    }
    if ($TaskType -eq 'deep-consult') {
        $plan.deep_hard_limit_percent = $hardLimit
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

        [string[]]$Directive
    )

    if ($null -eq $Directive -or $Directive.Count -eq 0) {
        return $PromptPath
    }

    $promptContent = Get-Content -LiteralPath $PromptPath -Raw -Encoding UTF8
    $derivedPromptPath = Join-Path -Path $HistoryRoot -ChildPath ('codex-prompt-' + $Timestamp + '.md')
    $suffix = "`n`n" + ($Directive -join "`n`n") + "`n"
    Write-Utf8NoBom -Path $derivedPromptPath -Content ($promptContent + $suffix)
    return $derivedPromptPath
}

function Get-OrCreateQuotaSnapshot {
    param(
        [string]$Path,

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
            throw "找不到 $Purpose quota snapshot：$resolvedPath"
        }
        $null = Read-QuotaSnapshot -Path $resolvedPath
        return $resolvedPath
    }

    $configuredHome = $CodexHome
    if ([string]::IsNullOrWhiteSpace($configuredHome)) {
        $configuredHome = $env:CODEX_HOME
    }
    if ([string]::IsNullOrWhiteSpace($configuredHome)) {
        if ($Required) {
            throw "$Purpose 需要 quota snapshot，請提供 QuotaBeforePath 或 CodexHome。"
        }
        return $null
    }

    $snapshotPath = Join-Path -Path $HistoryRoot -ChildPath ('quota-' + $Purpose.ToLowerInvariant() + '-' + [datetime]::UtcNow.ToString('yyyyMMdd_HHmmss_fff') + '.json')
    $quotaScript = Join-Path -Path $PSScriptRoot -ChildPath 'Get-CodexQuota.ps1'
    if (-not (Test-Path -LiteralPath $quotaScript -PathType Leaf)) {
        throw "找不到額度快照腳本：$quotaScript"
    }
    if ([string]::IsNullOrWhiteSpace($CodexHome)) {
        $quotaOutput = & $quotaScript -SnapshotPath $snapshotPath 2>&1
    }
    else {
        $quotaOutput = & $quotaScript -CodexHome $CodexHome -SnapshotPath $snapshotPath 2>&1
    }
    $quotaExitCode = $LASTEXITCODE
    if ($quotaExitCode -ne 0 -or -not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
        $details = ($quotaOutput | Out-String).Trim()
        throw "$Purpose quota snapshot 失敗，exit code $quotaExitCode。$details"
    }
    $null = Read-QuotaSnapshot -Path $snapshotPath
    return $snapshotPath
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
        throw 'quota snapshot 更新需要 CodexHome 或 CODEX_HOME。'
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

function Get-DeepConsultReportPath {
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
        throw "DeepConsultReportPath 必須位於同線 report root 內：$fullPath"
    }
    $expectedName = 'deep-consult-' + $DispatchSlug + '.md'
    if (-not [string]::Equals([System.IO.Path]::GetFileName($fullPath), $expectedName, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "DeepConsultReportPath 檔名必須為 $expectedName：$fullPath"
    }
    return $fullPath
}

function Test-EvidencePack {
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
            '(?m)^schema:\s*deep-consult\.evidence\.v1\s*$',
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
    if ($sectionBodies['待答問題'] -notmatch '(?m)^\s*question:\s*\S+' -or
        $sectionBodies['待答問題'] -notmatch '(?m)^\s*required-output:\s*\S+') {
        throw 'evidence pack 待答問題必須包含非空 question 與 required-output。'
    }

    $hash = Get-FileSha256 -Path $fullPath
    $sandboxRoot = Join-Path -Path $ExecutionRoot -ChildPath ('.local\ai-sessions\scratch\deep-consult\' + $DispatchSlug)
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
            threadId = $existingId
            relayed  = $false
            source   = 'existing-or-not-ready'
        }
    }
    $eventId = $distinctIds[0]
    if (-not [string]::IsNullOrWhiteSpace($existingId) -and $existingId -ne $eventId) {
        throw "thread id 衝突：既有=$existingId；事件流=$eventId"
    }
    if ([string]::IsNullOrWhiteSpace($existingId)) {
        Write-Utf8NoBom -Path $threadPathValue -Content ($eventId + "`n")
        return [ordered]@{
            threadId = $eventId
            relayed  = $true
            source   = 'thread.started'
        }
    }
    return [ordered]@{
        threadId = $existingId
        relayed  = $false
        source   = 'existing'
    }
}

function Wait-ForThreadRelay {
    param(
        [Parameter(Mandatory)]
        [string]$EventPath,

        [Parameter(Mandatory)]
        [string]$ThreadPath,

        [int]$TimeoutSeconds = 5
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $relay = Set-ThreadIdFromEventStream -EventPath $EventPath -ThreadPath $ThreadPath
        if (-not [string]::IsNullOrWhiteSpace($relay.threadId)) {
            return $relay
        }
        if (Test-Path -LiteralPath $EventPath -PathType Leaf) {
            $eventContent = Get-Content -LiteralPath $EventPath -Raw -Encoding UTF8
            if ($eventContent -match '(?m)"type"\s*:\s*"turn\.(completed|failed)"') {
                break
            }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    $finalRelay = Set-ThreadIdFromEventStream -EventPath $EventPath -ThreadPath $ThreadPath
    if ([string]::IsNullOrWhiteSpace($finalRelay.threadId)) {
        return [ordered]@{
            threadId = ''
            relayed = $false
            source = 'not-ready'
            ready = $false
            timedOut = $true
            timeoutSeconds = $TimeoutSeconds
        }
    }
    return $finalRelay
}

function Read-ScopePlanFile {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    $fullPath = Resolve-AbsolutePath -Path $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "找不到 ScopePlan：$fullPath"
    }
    try {
        $plan = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
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

function Test-ScopePlanContinuationFields {
    param(
        [Parameter(Mandatory)]
        [psobject]$OriginalScopePlan,

        [Parameter(Mandatory)]
        [psobject]$ContinuationScopePlan
    )

    foreach ($propertyName in @('selected_units', 'deferred_units')) {
        if (-not (Test-StringArrayEqual -Left $OriginalScopePlan.$propertyName -Right $ContinuationScopePlan.$propertyName)) {
            return $false
        }
    }
    if (-not [string]::Equals([string]$OriginalScopePlan.decision, [string]$ContinuationScopePlan.decision, [System.StringComparison]::Ordinal)) {
        return $false
    }
    if (-not [string]::Equals([string]$OriginalScopePlan.estimate_source, [string]$ContinuationScopePlan.estimate_source, [System.StringComparison]::Ordinal)) {
        return $false
    }
    $originalEstimate = Get-OptionalObjectProperty -Object $OriginalScopePlan -Name 'estimate_percent'
    $continuationEstimate = Get-OptionalObjectProperty -Object $ContinuationScopePlan -Name 'estimate_percent'
    if ($null -eq $originalEstimate -or $null -eq $continuationEstimate) {
        return $null -eq $originalEstimate -and $null -eq $continuationEstimate
    }
    try {
        return [math]::Abs([double]$originalEstimate - [double]$continuationEstimate) -le 0.000001
    }
    catch {
        return $false
    }
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
    $json = $fingerprintInput | ConvertTo-Json -Depth 20 -Compress
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
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "找不到要計算 SHA-256 的檔案：$resolvedPath"
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($resolvedPath)
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
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
        [string]$ScopePlanPath
    )

    $recordPath = Get-ScopePlanHashRecordPath -SourceHistoryRoot $SourceHistoryRoot -DispatchSlug $DispatchSlug
    if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
        return $recordPath
    }

    $resolvedScopePlanPath = Resolve-AbsolutePath -Path $ScopePlanPath
    $record = [ordered]@{
        dispatch_slug   = $DispatchSlug
        line_slug       = $LineSlug
        scope_plan_path = $resolvedScopePlanPath
        sha256          = Get-FileSha256 -Path $resolvedScopePlanPath
        created_at_utc  = [datetime]::UtcNow.ToString('o')
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
        [string]$ScopePlanPath
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
    if ([string]$ScopePlan.estimate_source -in @('calibration-p75', 'conservative-default') -and $null -eq $ScopePlan.estimate_percent) {
        return $false
    }

    if ($ScopePlan.unit_kind -notin @('workflow-phase', 'resource-target', 'deep-evidence-pack') -or
        $ScopePlan.decision -notin @('full', 'scoped', 'blocked-insufficient-budget', 'blocked-no-estimate', 'user-decision-required')) {
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
        $ScopePlan.session_mode -ne 'cold-start' -or
        -not (Test-StringArrayEqual -Left $ScopePlan.requested_units -Right $Units)) {
        return $false
    }
    return $true
}

function Get-LatestSafePointMessage {
    param(
        [Parameter(Mandatory)]
        [string]$EventPath
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
        if ($message -is [string] -and (Test-SafePointMessage -Message $message)) {
            $latest = $message
        }
    }
    return $latest
}

function Test-SafePointMessage {
    param(
        [AllowNull()]
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Message) -or -not $Message.Contains('## 中斷保全結論')) {
        return $false
    }
    $sectionMatch = [regex]::Match($Message, '(?ms)^##\s+中斷保全結論\s*\r?\n(?<body>.*?)(?=^##\s|\z)')
    if (-not $sectionMatch.Success -or [string]::IsNullOrWhiteSpace($sectionMatch.Groups['body'].Value)) {
        return $false
    }
    $body = $sectionMatch.Groups['body'].Value
    foreach ($requiredPattern in @(
            '(?m)已確認結論\s*[:：]\s*\S+',
            '(?m)證據位置\s*[:：]\s*\S+',
            '(?m)實際覆蓋範圍\s*[:：]\s*\S+'
        )) {
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

function Write-DeepConsultReport {
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

        [Parameter(Mandatory)]
        [string]$FinalMessage,

        [Parameter(Mandatory)]
        [string]$Status,

        [AllowNull()]
        [object]$BudgetMonitor
    )

    $fullPath = Resolve-AbsolutePath -Path $Path
    $reportRoot = Join-Path -Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $fullPath))) -ChildPath ''
    $reportParent = Split-Path -Parent $fullPath
    New-Item -ItemType Directory -Path $reportParent -Force | Out-Null
    $message = if ([string]::IsNullOrWhiteSpace($FinalMessage)) { '尚未取得執行端結案訊息。' } else { $FinalMessage.Trim() }
    $content = @(
        ('# Deep consult report')
        ''
        ('- line-slug: ' + $LineSlug)
        ('- dispatch-slug: ' + $DispatchSlug)
        ('- status: ' + $Status)
        ('- evidence-pack: ' + $EvidencePackPath)
        ('- evidence-pack-sha256: ' + $EvidencePackSha256)
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
                throw "校準紀錄互斥追加逾時：$Path；$($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds 100
        }
        finally {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "校準紀錄互斥追加失敗：$Path"
}

function Add-CalibrationObservation {
    param(
        [string]$SourceRoot,

        [string]$Path,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [string]$Profile,

        [Parameter(Mandatory)]
        [string]$Model,

        [Parameter(Mandatory)]
        [string]$ReasoningEffort,

        [Parameter(Mandatory)]
        [string]$TaskType,

        [Parameter(Mandatory)]
        [string]$SessionMode,

        [AllowNull()]
        [object]$Usage,

        [Parameter(Mandatory)]
        [psobject]$ExecutionResult,

        [string]$QuotaBeforePath,

        [string]$QuotaAfterPath,

        [AllowNull()]
        [object]$ScopePlan,

        [AllowNull()]
        [object]$InterruptionStatus,

        [AllowNull()]
        [object]$BudgetMonitor
    )

    $calibrationPath = $Path
    if ([string]::IsNullOrWhiteSpace($calibrationPath)) {
        if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
            return $null
        }
        $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
        $calibrationPath = Join-Path -Path $sourceRootPath -ChildPath '.local\ai-sessions\history\quota-calibration.jsonl'
    }
    else {
        $calibrationPath = Resolve-AbsolutePath -Path $calibrationPath
        if (-not [string]::IsNullOrWhiteSpace($SourceRoot) -and -not (Test-PathWithinRoot -Path $calibrationPath -Root $SourceRoot)) {
            throw "額度校準紀錄必須位於 sourceRoot 內：$calibrationPath"
        }
    }

    $beforeSnapshot = $null
    $afterSnapshot = $null
    $snapshotFailure = ''
    try {
        $beforeSnapshot = Read-QuotaSnapshot -Path $QuotaBeforePath
    }
    catch {
        $snapshotFailure = 'before: ' + $_.Exception.Message
    }
    try {
        $afterSnapshot = Read-QuotaSnapshot -Path $QuotaAfterPath
    }
    catch {
        if ([string]::IsNullOrWhiteSpace($snapshotFailure)) {
            $snapshotFailure = 'after: ' + $_.Exception.Message
        }
        else {
            $snapshotFailure = $snapshotFailure + '; after: ' + $_.Exception.Message
        }
    }
    $modelLabel = if ([string]::IsNullOrWhiteSpace($Model)) { 'unlabeled' } else { $Model }
    $taskTypeLabel = if ([string]::IsNullOrWhiteSpace($TaskType)) { 'unspecified' } else { $TaskType }
    $sessionModeLabel = if ([string]::IsNullOrWhiteSpace($SessionMode)) { 'unspecified' } else { $SessionMode }
    $hasMarkedModel = $modelLabel -ne 'unlabeled'
    $hasMarkedTaskType = $taskTypeLabel -ne 'unspecified'
    $hasSnapshots = $null -ne $beforeSnapshot -and $null -ne $afterSnapshot
    $hasUsage = Test-UsageObject -Value $Usage
    $sameResetWindow = $false
    $nonNegativeDelta = $false
    $deltaWithinLimit = $false
    $scopePlanComplete = Test-ScopePlanCompleteness -ScopePlan $ScopePlan
    $observedDelta = $null
    if ($hasSnapshots) {
        $sameResetWindow = [double]$afterSnapshot.primary.resets_at -eq [double]$beforeSnapshot.primary.resets_at -and [double]$afterSnapshot.secondary.resets_at -eq [double]$beforeSnapshot.secondary.resets_at
        $observedDelta = Get-QuotaSnapshotDelta -Before $beforeSnapshot -After $afterSnapshot
        $nonNegativeDelta = $observedDelta -ge 0
    }
    $deltaLimits = New-Object System.Collections.Generic.List[double]
    $monitorAllowsCalibration = $true
    if ($scopePlanComplete) {
        try {
            $scopeBudget = [double]$ScopePlan.primary_budget_percent
            if ($scopeBudget -ge 0 -and -not [double]::IsInfinity($scopeBudget) -and -not [double]::IsNaN($scopeBudget)) {
                $deltaLimits.Add($scopeBudget)
            }
            $deepHardLimit = Get-OptionalObjectProperty -Object $ScopePlan -Name 'deep_hard_limit_percent'
            if ($null -ne $deepHardLimit) {
                $deepHardLimitValue = [double]$deepHardLimit
                if ($deepHardLimitValue -ge 0 -and -not [double]::IsInfinity($deepHardLimitValue) -and -not [double]::IsNaN($deepHardLimitValue)) {
                    $deltaLimits.Add($deepHardLimitValue)
                }
            }
        }
        catch {
            $scopePlanComplete = $false
        }
    }
    foreach ($monitorRecord in @($BudgetMonitor)) {
        $monitorState = [string](Get-OptionalObjectProperty -Object $monitorRecord -Name 'state')
        if ($monitorState -in @('CrossReset', 'IdentityUnverified', 'SnapshotFailed', 'AbortedByBudget')) {
            $monitorAllowsCalibration = $false
        }
        $monitorEvent = [string](Get-OptionalObjectProperty -Object $monitorRecord -Name 'event')
        if ($monitorEvent -in @('monitor.cross-reset', 'monitor.identity-unverified', 'monitor.snapshot-failed', 'monitor.terminal-budget-exceeded')) {
            $monitorAllowsCalibration = $false
        }
        $monitorBudget = Get-OptionalObjectProperty -Object $monitorRecord -Name 'primary_budget_percent'
        if ($null -ne $monitorBudget) {
            try {
                $monitorBudgetValue = [double]$monitorBudget
                if ($monitorBudgetValue -ge 0 -and -not [double]::IsInfinity($monitorBudgetValue) -and -not [double]::IsNaN($monitorBudgetValue)) {
                    $deltaLimits.Add($monitorBudgetValue)
                }
            }
            catch {
                continue
            }
        }
    }
    if ($null -ne $observedDelta -and $deltaLimits.Count -gt 0) {
        $deltaUpperBound = [double]($deltaLimits | Measure-Object -Minimum).Minimum
        $deltaWithinLimit = $observedDelta -le ($deltaUpperBound + 0.000001)
    }
    $freshSnapshots = $hasSnapshots -and (Test-QuotaSnapshotFresh -Snapshot $beforeSnapshot) -and (Test-QuotaSnapshotFresh -Snapshot $afterSnapshot)
    $executionCompleted = $null -ne $ExecutionResult -and $ExecutionResult.completed -eq $true -and [int]$ExecutionResult.processExitCode -eq 0
    $eligible = $hasMarkedModel -and $hasMarkedTaskType -and $hasSnapshots -and $freshSnapshots -and $sameResetWindow -and $nonNegativeDelta -and $deltaWithinLimit -and $monitorAllowsCalibration -and $hasUsage -and $executionCompleted -and $scopePlanComplete

    $record = [ordered]@{
        schema                = 'codex-dispatch.quota-calibration.v1'
        recorded_at_utc       = [datetime]::UtcNow.ToString('o')
        line_slug             = $LineSlug
        dispatch_slug         = $DispatchSlug
        model                 = $modelLabel
        profile               = $Profile
        session_mode          = $sessionModeLabel
        group                 = [ordered]@{
            model        = $modelLabel
            profile      = $Profile
            session_mode = $sessionModeLabel
            task_type    = $taskTypeLabel
        }
        task_type             = $taskTypeLabel
        reasoning_effort     = $ReasoningEffort
        calibration_eligible  = $eligible
        calibration_checks    = [ordered]@{
            same_reset_window = $sameResetWindow
            scope_plan_complete = $scopePlanComplete
            delta_within_limit = $deltaWithinLimit
            monitor_allows_calibration = $monitorAllowsCalibration
            delta_upper_bound = if ($deltaLimits.Count -eq 0) { $null } else { [double]($deltaLimits | Measure-Object -Minimum).Minimum }
        }
        'turn.completed.usage' = $Usage
        usage                 = $Usage
        dispatch_before_snapshot = if ($null -eq $beforeSnapshot) { $null } else { $beforeSnapshot.values }
        dispatch_after_snapshot  = if ($null -eq $afterSnapshot) { $null } else { $afterSnapshot.values }
        observed_primary_delta_percent = $observedDelta
        scope_plan           = $ScopePlan
        interruption_status = $InterruptionStatus
        budget_monitor       = $BudgetMonitor
        snapshot_failure     = if ([string]::IsNullOrWhiteSpace($snapshotFailure)) { $null } else { $snapshotFailure }
        execution_result     = $ExecutionResult
    }
    Add-AtomicJsonLine -Path $calibrationPath -Content (($record | ConvertTo-Json -Depth 20 -Compress))

    $matchingRecords = @(Get-CalibrationRecords -Path $calibrationPath | Where-Object {
            $_.calibration_eligible -eq $true -and
            $_.model -eq $modelLabel -and
            $_.profile -eq $Profile -and
            $_.session_mode -eq $sessionModeLabel -and
            $_.task_type -eq $taskTypeLabel -and
            $null -ne $_.observed_primary_delta_percent
        })
    $recommendationReady = $matchingRecords.Count -ge 5
    $calibrationStatus = [ordered]@{
        path                          = $calibrationPath
        recordWritten                 = $true
        calibrationEligible           = $eligible
        group                         = $record.group
        sampleCount                   = $matchingRecords.Count
        thresholdRecommendationReady = $recommendationReady
        automaticThresholdUpdate      = $false
        observedPrimaryDeltaPercent   = $observedDelta
        snapshotFailure               = if ([string]::IsNullOrWhiteSpace($snapshotFailure)) { $null } else { $snapshotFailure }
    }
    if ($recommendationReady) {
        $calibrationStatus.recommendationSignal = '主 Agent 可提出新門檻，須先取得使用者確認；腳本不自動更新規則。'
    }

    return $calibrationStatus
}

function Add-SnapshotFailureCalibrationObservation {
    param(
        [string]$SourceRoot,

        [string]$Path,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [string]$Profile,

        [Parameter(Mandatory)]
        [string]$Model,

        [Parameter(Mandatory)]
        [string]$ReasoningEffort,

        [Parameter(Mandatory)]
        [string]$TaskType,

        [Parameter(Mandatory)]
        [string]$SessionMode,

        [AllowNull()]
        [object]$Usage,

        [Parameter(Mandatory)]
        [psobject]$ExecutionResult,

        [string]$QuotaBeforePath,

        [string]$QuotaAfterPath,

        [AllowNull()]
        [object]$ScopePlan,

        [Parameter(Mandatory)]
        [string]$Failure
    )

    $interruptionStatus = [ordered]@{
        applied = $true
        snapshot_failure = $Failure
        calibration_eligible = $false
        sessionMode = $SessionMode
    }
    try {
        $result = Add-CalibrationObservation -SourceRoot $SourceRoot -Path $Path -LineSlug $LineSlug -DispatchSlug $DispatchSlug -Profile $Profile -Model $Model -ReasoningEffort $ReasoningEffort -TaskType $TaskType -SessionMode $SessionMode -Usage $Usage -ExecutionResult $ExecutionResult -QuotaBeforePath $QuotaBeforePath -QuotaAfterPath $QuotaAfterPath -ScopePlan $ScopePlan -InterruptionStatus $interruptionStatus -BudgetMonitor $null
        if ($null -eq $result -or $result.recordWritten -ne $true -or $result.calibrationEligible -ne $false) {
            throw '校準失敗觀測未寫入或未標記 calibration_eligible=false。'
        }
        return $result
    }
    catch {
        throw ('{0}；snapshot_failure 觀測寫入失敗：{1}' -f $Failure, $_.Exception.Message)
    }
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
                elseif (Test-RecordedProcessIdentity -Record $record -Snapshot $rootSnapshot) {
                    $identityVerified = $true
                    $isActive = $true
                    $liveProcessIds = @(Get-DescendantProcessIds -RootProcessId $rootPid -ProcessesById $processesById -ConfirmedOnly)
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

function Invoke-Preflight {
    if ([string]::IsNullOrWhiteSpace($SourceRoot) -or [string]::IsNullOrWhiteSpace($DispatchRoot) -or [string]::IsNullOrWhiteSpace($LineSlug) -or [string]::IsNullOrWhiteSpace($DispatchSlug)) {
        throw 'Preflight 必須提供 SourceRoot、DispatchRoot、LineSlug 與 DispatchSlug。'
    }
    if ($null -eq $TargetPath -or $TargetPath.Count -eq 0) {
        throw 'Preflight 必須提供至少一個 TargetPath。'
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
    foreach ($handoffFileName in @('line.json', 'requirement-summary.md', 'design.md')) {
        $sourceHandoffPath = Join-Path -Path $manifestInfo.SourceLineRoot -ChildPath $handoffFileName
        $dispatchHandoffPath = Join-Path -Path $dispatchLineRoot -ChildPath $handoffFileName
        if ((Test-Path -LiteralPath $sourceHandoffPath -PathType Leaf) -and -not [string]::Equals($sourceHandoffPath, $dispatchHandoffPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            Copy-Item -LiteralPath $sourceHandoffPath -Destination $dispatchHandoffPath -Force
        }
    }

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
        targetStates    = @($targetStates)
        sourceLineRoot  = $manifestInfo.SourceLineRoot
        dispatchLineRoot = $dispatchLineRoot
        reportLineRoot  = $reportLineRoot
        pidCheck        = $pidCheck
    }

    return $result
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
            return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
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

        [string]$LauncherPath
    )

    $timestamp = [datetime]::UtcNow.ToString('yyyyMMdd_HHmmss_fff')
    if (Test-IsWindowsPlatform) {
        if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
            $LauncherPath = Join-Path -Path $HistoryRoot -ChildPath ('codex-launch-' + $timestamp + '.cmd')
        }
        $argumentsText = ($CodexArguments | ForEach-Object { ConvertTo-CmdArgument -Value $_ }) -join ' '
        $content = @(
            '@echo off'
            ('call ' + (ConvertTo-CmdArgument -Value $CodexExecutable) + ' ' + $argumentsText + ' < ' + (ConvertTo-CmdArgument -Value $PromptPath) + ' > ' + (ConvertTo-CmdArgument -Value $EventPath) + ' 2> ' + (ConvertTo-CmdArgument -Value $ErrorPath))
            'exit /b %errorlevel%'
        ) -join "`r`n"
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
    $content = @(
        '#!/bin/sh'
        ('exec ' + ("'" + $CodexExecutable.Replace("'", "'\\''") + "'") + ' ' + $argumentsText + ' < ' + ("'" + $PromptPath.Replace("'", "'\\''") + "'") + ' > ' + ("'" + $EventPath.Replace("'", "'\\''") + "'") + ' 2> ' + ("'" + $ErrorPath.Replace("'", "'\\''") + "'"))
    ) -join "`n"
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

function Stop-StartedProcessHandle {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [psobject]$StartedSnapshot
    )

    $exitCode = Get-ProcessExitCodeIfExited -Process $Process
    if ($null -ne $exitCode) {
        return
    }

    if (Test-IsWindowsPlatform) {
        if ($null -eq $StartedSnapshot -or $StartedSnapshot.IdentityVerified -ne $true) {
            throw 'PowerShell 5.1 fallback 缺少已驗證的進程身分，拒絕終止並明示未完成收尾。'
        }
        $null = Stop-VerifiedProcessTree -Snapshot $StartedSnapshot
        return
    }

    $killMethods = @($Process.GetType().GetMethods() | Where-Object {
            $_.Name -eq 'Kill' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType -eq [bool]
        })
    if ($killMethods.Count -gt 0) {
        $Process.Kill($true)
        $Process.WaitForExit()
        return
    }

    if ($null -eq $StartedSnapshot -or $StartedSnapshot.IdentityVerified -ne $true) {
        throw '進程終止 fallback 缺少已驗證的進程身分，拒絕終止並明示未完成收尾。'
    }
    $null = Stop-VerifiedProcessTree -Snapshot $StartedSnapshot
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

function Invoke-DeepBudgetMonitor {
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

        [string]$CodexHome,

        [Parameter(Mandatory)]
        [double]$PrimaryBudgetPercent,

        [Parameter(Mandatory)]
        [int]$AbortGraceSeconds
    )

    $monitor = [ordered]@{
        state = 'running'
        stopRequested = $false
        safePointFound = $false
        safePointMissing = $false
        abortReason = $null
        observedPrimaryDeltaPercent = $null
        calibrationEligible = $true
        terminalSnapshotTaken = $false
    }
    Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
            event = 'monitor.started'
            recorded_at_utc = [datetime]::UtcNow.ToString('o')
            primary_budget_percent = $PrimaryBudgetPercent
        })

    while (-not $Process.HasExited) {
        try {
            $null = Set-QuotaSnapshotFromCodex -Path $AfterSnapshotPath -CodexHome $CodexHome
            $afterSnapshot = Read-QuotaSnapshot -Path $AfterSnapshotPath
            $delta = Get-QuotaSnapshotDelta -Before $BeforeSnapshot -After $afterSnapshot
            $monitor.observedPrimaryDeltaPercent = $delta
            if ([double]$afterSnapshot.primary.resets_at -ne [double]$BeforeSnapshot.primary.resets_at) {
                $monitor.state = 'CrossReset'
                $monitor.calibrationEligible = $false
                $monitor.abortReason = 'primary-reset-window-changed'
                Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                        event = 'monitor.cross-reset'
                        recorded_at_utc = [datetime]::UtcNow.ToString('o')
                        state = $monitor.state
                        calibration_eligible = $false
                        before_primary_resets_at = $BeforeSnapshot.primary.resets_at
                        after_primary_resets_at = $afterSnapshot.primary.resets_at
                        observed_primary_delta_percent = $delta
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
                        })
                    $safePointMessage = ''
                    $safePointDeadline = [DateTime]::UtcNow.AddSeconds($AbortGraceSeconds)
                    do {
                        $safePointMessage = Get-LatestSafePointMessage -EventPath $EventPath
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
                            $monitor.calibrationEligible = $false
                        }
                        Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                                event = 'budget-monitor.completed'
                                recorded_at_utc = [datetime]::UtcNow.ToString('o')
                                state = $monitor.state
                                calibration_eligible = $monitor.calibrationEligible
                                cleanup_status = $cleanupResult.CleanupStatus
                                cleanup_error = $cleanupResult.ErrorMessage
                                safe_point_missing = $monitor.safePointMissing
                            })
                        return $monitor
                    }
                    catch {
                        $monitor.state = 'IdentityUnverified'
                        $monitor.calibrationEligible = $false
                        $monitor.abortReason = $_.Exception.Message
                        Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                                event = 'monitor.identity-unverified'
                                recorded_at_utc = [datetime]::UtcNow.ToString('o')
                                state = $monitor.state
                                calibration_eligible = $false
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
            $monitor.state = 'SnapshotFailed'
            $monitor.calibrationEligible = $false
            $monitor.abortReason = $_.Exception.Message
            Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                    event = 'monitor.snapshot-failed'
                    recorded_at_utc = [datetime]::UtcNow.ToString('o')
                    error = $_.Exception.Message
                })
            return $monitor
        }
        Start-Sleep -Milliseconds 100
    }

    try {
        $null = Set-QuotaSnapshotFromCodex -Path $AfterSnapshotPath -CodexHome $CodexHome
        $terminalAfterSnapshot = Read-QuotaSnapshot -Path $AfterSnapshotPath
        $terminalDelta = Get-QuotaSnapshotDelta -Before $BeforeSnapshot -After $terminalAfterSnapshot
        $monitor.observedPrimaryDeltaPercent = $terminalDelta
        $monitor.terminalSnapshotTaken = $true
        if ([double]$terminalAfterSnapshot.primary.resets_at -ne [double]$BeforeSnapshot.primary.resets_at) {
            $monitor.state = 'CrossReset'
            $monitor.calibrationEligible = $false
            $monitor.abortReason = 'primary-reset-window-changed'
            Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                    event = 'monitor.cross-reset'
                    recorded_at_utc = [datetime]::UtcNow.ToString('o')
                    state = $monitor.state
                    calibration_eligible = $false
                    terminal_snapshot = $true
                    before_primary_resets_at = $BeforeSnapshot.primary.resets_at
                    after_primary_resets_at = $terminalAfterSnapshot.primary.resets_at
                    observed_primary_delta_percent = $terminalDelta
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
            })
        if ($terminalBudgetExceeded) {
            $monitor.stopRequested = $true
            $monitor.state = 'AbortedByBudget'
            $monitor.calibrationEligible = $false
            $monitor.abortReason = 'primary-budget-percent-exceeded-after-process-exit'
            Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                    event = 'monitor.terminal-budget-exceeded'
                    recorded_at_utc = [datetime]::UtcNow.ToString('o')
                    state = $monitor.state
                    calibration_eligible = $false
                    terminal_snapshot = $true
                    observed_primary_delta_percent = $terminalDelta
                    primary_budget_percent = $PrimaryBudgetPercent
                    before_primary_remaining_percent = $BeforeSnapshot.primary.remaining_percent
                    after_primary_remaining_percent = $terminalAfterSnapshot.primary.remaining_percent
                })
            Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                    event = 'budget-monitor.completed'
                    recorded_at_utc = [datetime]::UtcNow.ToString('o')
                    state = $monitor.state
                    calibration_eligible = $monitor.calibrationEligible
                    terminal_snapshot = $true
                    abort_reason = $monitor.abortReason
                })
            return $monitor
        }
    }
    catch {
        $monitor.state = 'SnapshotFailed'
        $monitor.calibrationEligible = $false
        $monitor.abortReason = $_.Exception.Message
        Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
                event = 'monitor.snapshot-failed'
                recorded_at_utc = [datetime]::UtcNow.ToString('o')
                state = $monitor.state
                calibration_eligible = $false
                terminal_snapshot = $true
                error = $_.Exception.Message
            })
        return $monitor
    }

    $monitor.state = 'completed'
    Write-BudgetMonitorRecord -Path $MonitorPath -Record ([ordered]@{
            event = 'monitor.completed'
            recorded_at_utc = [datetime]::UtcNow.ToString('o')
            state = $monitor.state
            terminal_snapshot = $monitor.terminalSnapshotTaken
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
        [string]$CleanupError
    )

    $processExitText = if ($null -eq $ProcessExitCode) { 'not-started-or-unknown' } else { [string]$ProcessExitCode }
    $cleanupErrorText = if ([string]::IsNullOrWhiteSpace($CleanupError)) { '<none>' } else { $CleanupError }
    return ('phase={0}; eventStreamPath={1}; errorStreamPath={2}; lastMessagePath={3}; threadIdPath={4}; pidRecordPath={5}; launcherPath={6}; processExitCode={7}; cleanupStatus={8}; cleanupError={9}' -f `
        $Phase,
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

function Get-QuotaProbeRolloutSourcePaths {
    param(
        [AllowEmptyCollection()]
        [object[]]$BeforeFiles,

        [AllowEmptyCollection()]
        [object[]]$AfterFiles
    )

    $beforeByPath = @{}
    foreach ($file in @($BeforeFiles)) {
        $beforeByPath[$file.Path] = $file
    }

    return @(
        @($AfterFiles) |
            Where-Object {
                $previous = $beforeByPath[$_.Path]
                $null -eq $previous -or
                $_.Length -gt $previous.Length -or
                $_.LastWriteTimeUtc -gt $previous.LastWriteTimeUtc
            } |
            Sort-Object -Property LastWriteTimeUtc -Descending |
            ForEach-Object { $_.Path }
    )
}

function Get-QuotaProbeEvidenceFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$EvidenceName
    )

    $evidencePath = Resolve-AbsolutePath -Path $Path
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
        throw "QuotaProbe 缺少 $EvidenceName 證據檔案：$evidencePath"
    }

    $evidenceFile = Get-Item -LiteralPath $evidencePath -Force
    if ($evidenceFile.Length -le 0) {
        throw "QuotaProbe 的 $EvidenceName 證據檔案為空：$evidencePath"
    }

    $evidenceContent = Get-Content -LiteralPath $evidencePath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($evidenceContent)) {
        throw "QuotaProbe 的 $EvidenceName 證據內容為空：$evidencePath"
    }

    return $evidenceFile
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

function Test-QuotaProbeUsageObject {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or -not ($Value -is [pscustomobject])) {
        return $false
    }

    foreach ($requiredName in @('input_tokens', 'output_tokens')) {
        if ($null -eq $Value.PSObject.Properties[$requiredName]) {
            return $false
        }
    }

    $numericTypes = @(
        [System.Byte], [System.SByte], [System.Int16], [System.UInt16],
        [System.Int32], [System.UInt32], [System.Int64], [System.UInt64],
        [System.Single], [System.Double], [System.Decimal]
    )
    foreach ($property in @($Value.PSObject.Properties)) {
        if ($null -eq $property.Value -or $property.Value -is [bool] -or $property.Value.GetType() -notin $numericTypes -or [double]$property.Value -lt 0) {
            return $false
        }
    }

    return @($Value.PSObject.Properties).Count -gt 0
}

function Get-QuotaProbeEventSummary {
    param(
        [Parameter(Mandatory)]
        [string]$EventPath
    )

    if (-not (Test-Path -LiteralPath $EventPath -PathType Leaf)) {
        throw "QuotaProbe 事件流檔案不存在：$EventPath"
    }

    $events = New-Object System.Collections.Generic.List[object]
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $EventPath -Encoding UTF8) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "QuotaProbe 事件流第 $lineNumber 行格式錯誤：$($_.Exception.Message)"
        }

        $typeProperty = if ($null -eq $event) { $null } else { $event.PSObject.Properties['type'] }
        if ($null -eq $typeProperty -or -not ($typeProperty.Value -is [string]) -or [string]::IsNullOrWhiteSpace($typeProperty.Value)) {
            throw "QuotaProbe 事件流第 $lineNumber 行缺少 type。"
        }
        $events.Add($event)
    }

    if ($events.Count -eq 0) {
        throw 'QuotaProbe 事件流沒有可解析的事件。'
    }

    $threadId = ''
    $threadIds = New-Object System.Collections.Generic.List[string]
    foreach ($event in $events) {
        if ($event.type -eq 'thread.started' -and [string]::IsNullOrWhiteSpace($threadId)) {
            $threadIdValue = $event.PSObject.Properties['thread_id']
            if ($null -eq $threadIdValue -or -not ($threadIdValue.Value -is [string]) -or [string]::IsNullOrWhiteSpace($threadIdValue.Value)) {
                throw 'QuotaProbe 的 thread.started.thread_id 必須為非空字串。'
            }
            $threadId = $threadIdValue.Value
        }
    }

    if ([string]::IsNullOrWhiteSpace($threadId)) {
        throw 'QuotaProbe 事件流缺少 thread.started.thread_id。'
    }

    $lastEvent = $events[$events.Count - 1]
    $lastEventType = [string]$lastEvent.type
    if ($lastEventType -ne 'turn.completed') {
        throw "QuotaProbe 事件流最後事件不是 turn.completed：$lastEventType"
    }

    $usageProperty = $lastEvent.PSObject.Properties['usage']
    if ($null -eq $usageProperty -or -not (Test-QuotaProbeUsageObject -Value $usageProperty.Value)) {
        throw 'QuotaProbe 事件流缺少 turn.completed.usage。'
    }

    return [ordered]@{
        eventCount      = $events.Count
        lastEventType   = $lastEventType
        threadId        = $threadId
        usage           = $usageProperty.Value
        completed       = $true
    }
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
    # 探針的作用是讓 Codex 寫出一筆新 rollout，新快照的正確性只來自該筆新記錄，與探針前的狀態無關。
    # 因此可回復的狀態以「解析是否可信」區分：SnapshotExpired 代表解析正常、僅資料過期，屬探針要解決的
    # 對象；SnapshotUnavailable 代表連一筆結構有效候選都讀不到，前提本身可能已壞，探針成功也讀不回來。
    $recoverableQuotaStates = @('PostResetNoSnapshot', 'SnapshotExpired')

    if ($recoverableQuotaStates -notcontains $InitialQuotaState) {
        throw "QuotaProbe 僅允許回復 $($recoverableQuotaStates -join '、')，收到：$InitialQuotaState"
    }
    if ($ProbeAttempt -gt 1) {
        throw "QuotaProbe 已限制為一次，拒絕 probeAttempt=$ProbeAttempt。"
    }
    if ([string]::IsNullOrWhiteSpace($PromptPath)) {
        throw 'QuotaProbe 必須提供 PromptPath。'
    }

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

    $beforeRolloutFiles = @(Get-QuotaProbeRolloutFiles -CodexHomePath $codexHomePath)
    $codexExecutable = $null
    $launcher = $null
    $startInfo = $null
    $process = $null
    $startedSnapshot = $null
    $processStarted = $false
    $processExitCodeValue = $null
    $probeSummary = $null
    $rolloutSourcePaths = @()
    $phase = 'preparation'
    $cleanupStatus = 'not-started'
    $cleanupError = $null

    try {
        $codexExecutable = Get-CodexExecutablePath -ConfiguredPath $CodexPath
        if ($Profile -eq 'deep') {
            $deepCycleDecision = Get-DeepCycleDecision -RequestedProfile $Profile -RequestSource $DeepRequestSource -DaysToReset $SecondaryDaysToReset -RemainingPercent $SecondaryRemainingPercent -AllowUnknownForUserExplicit
        }
        else {
            $deepCycleDecision = [ordered]@{
                applicable       = $false
                requestSource    = $DeepRequestSource
                gatePassed       = $null
                daysToReset      = $SecondaryDaysToReset
                remainingPercent = $SecondaryRemainingPercent
                notice           = ''
            }
        }

        $promptDirectives = @(
            '[QuotaProbe]' + [Environment]::NewLine +
            '本次執行只用於視窗重設後的額度回復探針。請勿修改任何目標物件、規則檔或設定檔；完成後只回報探針結果。'
        )
        if ($null -ne $deepCycleDecision -and $deepCycleDecision.applicable) {
            $promptDirectives += '[deep 週期位置告知]' + [Environment]::NewLine + $deepCycleDecision.notice
        }
        $probePromptPath = New-DispatchPrompt -PromptPath $promptPathValue -HistoryRoot $historyRoot -Timestamp $timestamp -Directive $promptDirectives

        $codexArguments = New-Object System.Collections.Generic.List[string]
        $codexArguments.Add('--cd')
        $codexArguments.Add($executionRootPath)
        $codexArguments.Add('--sandbox')
        $codexArguments.Add('workspace-write')
        if ($Profile -ne 'default') {
            $codexArguments.Add('--profile')
            $codexArguments.Add($Profile)
        }
        if ($null -ne $AddDirectory) {
            foreach ($directory in $AddDirectory) {
                $directoryPath = Resolve-AbsolutePath -Path $directory
                if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) {
                    throw "--add-dir 目錄不存在：$directoryPath"
                }
                $codexArguments.Add('--add-dir')
                $codexArguments.Add($directoryPath)
            }
        }
        if ($Search) {
            $codexArguments.Add('--search')
        }
        if ($null -ne $CodexParentOption) {
            foreach ($option in $CodexParentOption) {
                if ([string]::IsNullOrWhiteSpace($option)) {
                    throw 'CodexParentOption 不可包含空白選項。'
                }
                $codexArguments.Add($option)
            }
        }
        $codexArguments.Add('exec')
        $codexArguments.Add('--json')
        $codexArguments.Add('--output-last-message')
        $codexArguments.Add($lastMessagePath)
        $codexArguments.Add('-')

        $launcher = New-CodexLauncher -CodexExecutable $codexExecutable -CodexArguments @($codexArguments.ToArray()) -PromptPath $probePromptPath -EventPath $eventPath -ErrorPath $errorPath -HistoryRoot $historyRoot -LauncherPath $launcherPath
        $launcherPath = $launcher.Path
        $startInfo = New-ProcessStartInfo -FileName $launcher.FileName -WorkingDirectory $executionRootPath -Arguments @($launcher.Arguments)
        if ($null -ne $codexHomePath) {
            $startInfo.EnvironmentVariables['CODEX_HOME'] = $codexHomePath
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw 'QuotaProbe Codex 啟動失敗。'
        }
        $processStarted = $true
        $startedSnapshot = Get-StartedProcessSnapshot -ProcessId $process.Id
        if ($null -eq $startedSnapshot) {
            throw "無法取得 QuotaProbe 根程序身分，PID $($process.Id) 未通過驗證。"
        }
        if ($startedSnapshot.IdentityStatus -ne 'confirmed' -or $startedSnapshot.IdentityVerified -ne $true) {
            throw "QuotaProbe 根程序身分無法確認：PID $($process.Id); identity-status=$($startedSnapshot.IdentityStatus)"
        }

        $processGroupValue = ''
        if (-not (Test-IsWindowsPlatform)) {
            if ($null -eq $startedSnapshot.PSObject.Properties['ProcessGroupId'] -or $startedSnapshot.ProcessGroupId -le 0) {
                throw "無法取得 QuotaProbe process group，PID $($process.Id) 未通過驗證。"
            }
            $processGroupValue = [string]$startedSnapshot.ProcessGroupId
        }

        $pidContent = @(
            ('pid=' + $process.Id)
            ('root-pid=' + $process.Id)
            ('root-process-name=' + $startedSnapshot.ProcessName)
            ('root-parent-pid=' + $startedSnapshot.ParentProcessId)
            ('root-started-at-utc=' + $startedSnapshot.CreationUtc.ToString('o'))
            'identity-verified=true'
            ('process-tree-scope=' + $(if (Test-IsWindowsPlatform) { 'pid-and-descendants' } else { 'process-group' }))
            ('process-tree-query=' + $(if (Test-IsWindowsPlatform) { 'Win32_Process.ParentProcessId' } else { 'ps PGID 成員' }))
            ('process-group-id=' + $processGroupValue)
            ('work-root=' + $sourceRootPath)
            ('line-slug=' + $LineSlug)
            ('dispatch-slug=' + $DispatchSlug)
            'write-mode=readonly'
            ('started-at-utc=' + [datetime]::UtcNow.ToString('o'))
        ) -join "`n"
        Write-Utf8NoBom -Path $pidPath -Content ($pidContent + "`n")
        Write-Utf8NoBom -Path $threadPath -Content ''
        $phase = 'started'

        $process.WaitForExit()
        $processExitCodeValue = Get-ProcessExitCodeIfExited -Process $process
        if ($null -eq $processExitCodeValue) {
            throw 'QuotaProbe 無法取得 Codex process exit code。'
        }
        $phase = 'completed'
        Ensure-StartEvidenceFiles -Path @($eventPath, $errorPath)
        $probeSummary = Get-QuotaProbeEventSummary -EventPath $eventPath
        Write-Utf8NoBom -Path $threadPath -Content ($probeSummary.threadId + "`n")
        if ($processExitCodeValue -ne 0) {
            throw "QuotaProbe Codex 以非零 exit code 結束：$processExitCodeValue"
        }
        $null = Get-QuotaProbeEvidenceFile -Path $lastMessagePath -EvidenceName 'last-message'
        $rolloutSourcePaths = @(Get-QuotaProbeRolloutSourcePaths -BeforeFiles $beforeRolloutFiles -AfterFiles @(Get-QuotaProbeRolloutFiles -CodexHomePath $codexHomePath))
        if ($rolloutSourcePaths.Count -eq 0) {
            throw 'QuotaProbe 未觀測到新增或更新的 rollout 證據，拒絕回報 success=true。'
        }
        foreach ($rolloutSourcePath in $rolloutSourcePaths) {
            $null = Get-QuotaProbeEvidenceFile -Path $rolloutSourcePath -EvidenceName 'rollout'
        }

        $recoveryRecord = [ordered]@{
            schema              = 'quota-recovery.v1'
            operation           = 'QuotaProbe'
            lineSlug            = $LineSlug
            dispatchSlug        = $DispatchSlug
            initialQuotaState   = $InitialQuotaState
            profile             = $Profile
            deepRequestSource   = $DeepRequestSource
            deepCycleGatePassed = $deepCycleDecision.gatePassed
            secondaryDaysToReset = $deepCycleDecision.daysToReset
            secondaryRemainingPercent = $deepCycleDecision.remainingPercent
            deepCycleNotice     = $deepCycleDecision.notice
            initialWindowState  = [ordered]@{
                primary   = if ($TriggerWindow -eq 'primary' -or $TriggerWindow -eq 'both') { $InitialQuotaState } else { 'unknown' }
                secondary = if ($TriggerWindow -eq 'secondary' -or $TriggerWindow -eq 'both') { $InitialQuotaState } else { 'unknown' }
            }
            triggerWindow       = $TriggerWindow
            probeAttempt        = $ProbeAttempt
            probeAttemptLimit   = 1
            probeEvidence       = [ordered]@{
                eventStreamPath    = $eventPath
                stderrPath         = $errorPath
                lastMessagePath    = $lastMessagePath
                threadIdPath       = $threadPath
                pidRecordPath      = $pidPath
                launcherPath       = $launcher.Path
                codexPath          = $codexExecutable
                codexArguments     = @($codexArguments.ToArray())
                processExitCode    = $processExitCodeValue
                eventCount         = $probeSummary.eventCount
                lastEventType      = $probeSummary.lastEventType
                threadId           = $probeSummary.threadId
                rolloutSourcePath  = if ($rolloutSourcePaths.Count -gt 0) { $rolloutSourcePaths[0] } else { $null }
                rolloutSourcePaths = @($rolloutSourcePaths)
            }
            retryResult          = [ordered]@{
                status       = 'pending'
                attempted    = $false
                attemptLimit = 1
                command      = 'Get-CodexQuota.ps1 -CodexHome <fixture-or-configured-CODEX_HOME>'
                result       = 'QuotaProbe 完成後由呼叫端重試一次額度讀取。'
            }
            finalStatus         = 'probe-completed-awaiting-quota-retry'
            createdAtUtc        = [datetime]::UtcNow.ToString('o')
        }
        Write-Utf8NoBom -Path $recoveryPath -Content (($recoveryRecord | ConvertTo-Json -Depth 12) + "`n")

        return [ordered]@{
            operation          = 'QuotaProbe'
            success            = $true
            lineSlug           = $LineSlug
            dispatchSlug       = $DispatchSlug
            initialQuotaState  = $InitialQuotaState
            initialWindowState = [ordered]@{
                primary   = if ($TriggerWindow -eq 'primary' -or $TriggerWindow -eq 'both') { $InitialQuotaState } else { 'unknown' }
                secondary = if ($TriggerWindow -eq 'secondary' -or $TriggerWindow -eq 'both') { $InitialQuotaState } else { 'unknown' }
            }
            triggerWindow      = $TriggerWindow
            probeAttempt       = $ProbeAttempt
            probeAttemptLimit  = 1
            profile             = $Profile
            deepRequestSource   = $DeepRequestSource
            deepCycleGatePassed = $deepCycleDecision.gatePassed
            secondaryDaysToReset = $deepCycleDecision.daysToReset
            secondaryRemainingPercent = $deepCycleDecision.remainingPercent
            deepCycleNotice     = $deepCycleDecision.notice
            eventStreamPath    = $eventPath
            stderrPath         = $errorPath
            lastMessagePath    = $lastMessagePath
            threadIdPath       = $threadPath
            pidRecordPath      = $pidPath
            launcherPath       = $launcher.Path
            codexPath          = $codexExecutable
            codexArguments     = @($codexArguments.ToArray())
            processExitCode    = $processExitCodeValue
            threadId           = $probeSummary.threadId
            rolloutSourcePath  = if ($rolloutSourcePaths.Count -gt 0) { $rolloutSourcePaths[0] } else { $null }
            rolloutSourcePaths = @($rolloutSourcePaths)
            recoveryRecordPath = $recoveryPath
            retryRequired      = $true
            retryResult        = $recoveryRecord.retryResult
            finalStatus        = $recoveryRecord.finalStatus
        }
    }
    catch {
        $originalMessage = $_.Exception.Message
        $processExitCodeValue = if ($null -ne $process) { Get-ProcessExitCodeIfExited -Process $process } else { $null }
        if ($null -ne $startedSnapshot -and $startedSnapshot.IdentityVerified -eq $true -and $null -ne $processExitCodeValue) {
            $cleanupStatus = 'already-terminated'
        }
        elseif ($null -ne $startedSnapshot -and $startedSnapshot.IdentityVerified -eq $true) {
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
        elseif ($processStarted) {
            $cleanupStatus = 'not-attempted-unconfirmed-identity'
        }
        if ($processStarted) {
            try {
                Ensure-StartEvidenceFiles -Path @($eventPath, $errorPath)
            }
            catch {
                $cleanupError = if ([string]::IsNullOrWhiteSpace($cleanupError)) { $_.Exception.Message } else { $cleanupError + '；' + $_.Exception.Message }
            }
        }
        $rolloutSourcePaths = @(Get-QuotaProbeRolloutSourcePaths -BeforeFiles $beforeRolloutFiles -AfterFiles @(Get-QuotaProbeRolloutFiles -CodexHomePath $codexHomePath))
        $failureRecord = [ordered]@{
            schema             = 'quota-recovery.v1'
            operation          = 'QuotaProbe'
            lineSlug           = $LineSlug
            dispatchSlug       = $DispatchSlug
            initialQuotaState  = $InitialQuotaState
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
                codexPath          = $codexExecutable
                processExitCode    = $processExitCodeValue
                threadId           = if ($null -ne $probeSummary) { $probeSummary.threadId } else { $null }
                phase              = $phase
                cleanupStatus      = $cleanupStatus
                cleanupError       = $cleanupError
                rolloutSourcePath  = if ($rolloutSourcePaths.Count -gt 0) { $rolloutSourcePaths[0] } else { $null }
                rolloutSourcePaths = @($rolloutSourcePaths)
            }
            retryResult         = [ordered]@{
                status       = 'not-run'
                attempted    = $false
                attemptLimit = 1
                command      = 'Get-CodexQuota.ps1 -CodexHome <fixture-or-configured-CODEX_HOME>'
                result       = 'QuotaProbe 失敗，停止額度重試。'
            }
            finalStatus        = 'probe-failed'
            error              = $originalMessage
            createdAtUtc       = [datetime]::UtcNow.ToString('o')
        }
        try {
            Write-Utf8NoBom -Path $recoveryPath -Content (($failureRecord | ConvertTo-Json -Depth 12) + "`n")
        }
        catch {
            $originalMessage = $originalMessage + '；寫入 QuotaProbe 回復紀錄失敗：' + $_.Exception.Message
        }
        throw $originalMessage
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Invoke-Start {
    $preflight = $null
    $sourceRootPath = $null
    $executionRootPath = $null
    $lineSlugValue = $null
    $dispatchSlugValue = $null
    $writeModeValue = 'readonly'
    $promptPathValue = $null
    $codexExecutable = $null
    $historyRoot = $null
    $sourceHistoryRoot = $null
    $eventPath = $null
    $errorPath = $null
    $lastMessagePathValue = $null
    $threadPath = $null
    $pidPath = $null
    $launcherPath = $null
    $launcher = $null
    $startInfo = $null
    $process = $null
    $startedSnapshot = $null
    $processStarted = $false
    $skipProcessCleanup = $false
    $phase = 'preparation'
    $cleanupStatus = 'not-started'
    $cleanupError = $null
    $requestedProfileValue = $Profile
    $effectiveProfileValue = $Profile
    $sessionModeValue = $SessionMode
    $deepCycleDecision = $null
    $dispatchKindValue = $DispatchKind
    $beforeSnapshotPathValue = $null
    $beforeSnapshotObject = $null
    $afterSnapshotPathValue = $QuotaAfterPath
    $scopePlan = $null
    $scopePlanPathValue = $null
    $continuationContextPath = $null
    $continuationContextMessage = $null
    $evidencePackInfo = $null
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
    $sourceRootPath = Resolve-AbsolutePath -Path $sourceRootValue
    $executionRootPath = Resolve-AbsolutePath -Path $executionRootValue
    if (-not (Test-Path -LiteralPath $executionRootPath -PathType Container)) {
        throw "executionRoot 不存在或不是目錄：$executionRootPath"
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
    $promptPathValue = Resolve-AbsolutePath -Path $PromptPath
    if (-not (Test-Path -LiteralPath $promptPathValue -PathType Leaf)) {
        throw "Prompt 檔案不存在：$promptPathValue"
    }

    $historyRoot = Join-Path -Path $executionRootPath -ChildPath '.local\ai-sessions\history'
    $sourceHistoryRoot = Join-Path -Path $sourceRootPath -ChildPath '.local\ai-sessions\history'
    $timestamp = [datetime]::UtcNow.ToString('yyyyMMdd_HHmmss_fff')
    $eventPath = Join-Path -Path $historyRoot -ChildPath ('codex-exec-' + $timestamp + '.jsonl')
    $errorPath = Join-Path -Path $historyRoot -ChildPath ('codex-exec-' + $timestamp + '.stderr.log')
    $lastMessagePathValue = $LastMessagePath
    if (-not [string]::IsNullOrWhiteSpace($ResumeThreadId)) {
        if (-not [string]::IsNullOrWhiteSpace($LastMessagePath)) {
            $continuationContextPath = Resolve-AbsolutePath -Path $LastMessagePath
        }
        else {
            $previousLastMessages = @(Get-ChildItem -LiteralPath $historyRoot -Filter 'codex-last-message-*.md' -File | Sort-Object -Property LastWriteTimeUtc -Descending)
            if ($previousLastMessages.Count -eq 0) {
                throw '續行缺少前輪 last-message 交接資料。'
            }
            $continuationContextPath = $previousLastMessages[0].FullName
        }
        if (-not (Test-Path -LiteralPath $continuationContextPath -PathType Leaf)) {
            throw "續行 last-message 交接檔不存在：$continuationContextPath"
        }
        $continuationContextMessage = Get-Content -LiteralPath $continuationContextPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($continuationContextMessage)) {
            throw "續行 last-message 交接檔為空：$continuationContextPath"
        }

        # 三個保全欄位由中斷保全指示於中止路徑產生。正常完成的派遣沒有收到中止要求，
        # 結案訊息不含這些欄位，因此依前輪事件流的終止事件決定要求哪一組前置條件。
        # 前輪終止狀態無法判定時採保守處置，仍要求完整保全欄位。
        $previousRunCompleted = $false
        $continuationTimestamp = [regex]::Match(
            [System.IO.Path]::GetFileNameWithoutExtension($continuationContextPath),
            '^codex-last-message-(?<stamp>.+)$'
        )

        if ($continuationTimestamp.Success) {
            $previousEventPath = Join-Path -Path $historyRoot -ChildPath ('codex-exec-' + $continuationTimestamp.Groups['stamp'].Value + '.jsonl')

            if (Test-Path -LiteralPath $previousEventPath -PathType Leaf) {
                $previousEventLines = @(
                    Get-Content -LiteralPath $previousEventPath -Encoding UTF8 |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                )

                if ($previousEventLines.Count -gt 0) {
                    try {
                        $previousTerminalEvent = $previousEventLines[$previousEventLines.Count - 1] | ConvertFrom-Json
                        $previousRunCompleted = ($previousTerminalEvent.type -eq 'turn.completed')
                    }
                    catch {
                        $previousRunCompleted = $false
                    }
                }
            }
        }

        if (-not $previousRunCompleted) {
            foreach ($requiredContextText in @('已確認結論', '未完成單位', '證據位置')) {
                $contextPattern = '(?m)^[ \t-]*' + [regex]::Escape($requiredContextText) + '[ \t]*[:：][ \t]*(?<value>[^\r\n]+?)\s*$'
                $contextMatch = [regex]::Match($continuationContextMessage, $contextPattern)
                if (-not $contextMatch.Success -or [string]::IsNullOrWhiteSpace($contextMatch.Groups['value'].Value)) {
                    throw "續行 last-message 缺少必要交接欄位：$requiredContextText"
                }
            }
        }
        $lastMessagePathValue = Join-Path -Path $historyRoot -ChildPath ('codex-last-message-' + $timestamp + '.md')
    }
    elseif ([string]::IsNullOrWhiteSpace($lastMessagePathValue)) {
        $lastMessagePathValue = Join-Path -Path $historyRoot -ChildPath ('codex-last-message-' + $timestamp + '.md')
    }
    else {
        $lastMessagePathValue = Resolve-AbsolutePath -Path $lastMessagePathValue
    }
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
    $codexExecutable = Get-CodexExecutablePath -ConfiguredPath $CodexPath

    if (-not [string]::IsNullOrWhiteSpace($ResumeThreadId)) {
        $sessionModeValue = 'continuation'
    }
    if ($TaskType -eq 'deep-consult') {
        if ($dispatchKindValue -ne 'resource') {
            throw 'deep-consult 必須使用 DispatchKind=resource。'
        }
        if ($writeModeValue -ne 'readonly') {
            throw 'deep-consult 必須使用 read-only 派遣。'
        }
        if ([string]::IsNullOrWhiteSpace($EvidencePackPath)) {
            throw 'deep-consult 必須提供 EvidencePackPath。'
        }
        if ([string]::IsNullOrWhiteSpace($DeepConsultReportPath)) {
            throw 'deep-consult 必須提供 DeepConsultReportPath。'
        }
        $DeepConsultReportPath = Get-DeepConsultReportPath -Path $DeepConsultReportPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue
        if ([string]::IsNullOrWhiteSpace($QuotaAfterPath)) {
            throw 'deep-consult 必須提供可在執行期間更新的 QuotaAfterPath。'
        }
        if ($null -ne $AddDirectory -and $AddDirectory.Count -gt 0) {
            throw 'deep-consult 不允許額外 --add-dir，執行端只可讀取 evidence pack。'
        }
        $evidencePackInfo = Test-EvidencePack -Path $EvidencePackPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue
        $evidenceHashPath = Join-Path -Path $historyRoot -ChildPath ('evidence-pack-' + $dispatchSlugValue + '.sha256')
        Write-Utf8NoBom -Path $evidenceHashPath -Content ($evidencePackInfo.sha256 + "`n")
    }
    if ($TaskType -ne 'deep-consult' -and -not [string]::IsNullOrWhiteSpace($DeepConsultReportPath)) {
        throw 'DeepConsultReportPath 只適用 TaskType=deep-consult。'
    }
    if ($TaskType -ne 'deep-consult' -and -not [string]::IsNullOrWhiteSpace($EvidencePackPath)) {
        throw 'EvidencePackPath 只適用 TaskType=deep-consult。'
    }

    $beforeSnapshotPathValue = Get-OrCreateQuotaSnapshot -Path $QuotaBeforePath -CodexHome $CodexHome -HistoryRoot $historyRoot -Purpose 'before' -Required
    $beforeSnapshotObject = Read-QuotaSnapshot -Path $beforeSnapshotPathValue
    if ($TaskType -eq 'deep-consult') {
        $afterSnapshotPathValue = Resolve-AbsolutePath -Path $QuotaAfterPath
        if (-not (Test-PathWithinRoot -Path $afterSnapshotPathValue -Root $executionRootPath)) {
            throw "deep-consult QuotaAfterPath 必須位於 executionRoot 內：$afterSnapshotPathValue"
        }
        $afterSnapshotPathValue = Set-QuotaSnapshotFromCodex -Path $afterSnapshotPathValue -CodexHome $CodexHome
    }
    $calibrationPathValue = $CalibrationPath
    if ([string]::IsNullOrWhiteSpace($calibrationPathValue)) {
        $calibrationPathValue = Join-Path -Path $sourceRootPath -ChildPath '.local\ai-sessions\history\quota-calibration.jsonl'
    }
    $unitKindValue = Get-DefaultUnitKind -DispatchKind $dispatchKindValue -UnitKind $UnitKind -TaskType $TaskType
    $units = @(Get-DispatchUnitList -RequestedUnit $RequestedUnit -DispatchKind $dispatchKindValue -UnitKind $unitKindValue -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -EvidencePackPath $EvidencePackPath -TargetPath $TargetPath)
    $scopePlanPathValue = $ScopePlanPath
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
        $null = Test-ScopePlanHashRecord -SourceHistoryRoot $sourceHistoryRoot -DispatchSlug $dispatchSlugValue -LineSlug $lineSlugValue -ScopePlanPath $scopePlanPathValue
        $existingScopePlan = Read-ScopePlanFile -Path $scopePlanPathValue
        if (-not (Test-ContinuationScopePlan -ScopePlan $existingScopePlan -DispatchSlug $dispatchSlugValue -DispatchKind $dispatchKindValue -TaskType $TaskType -RequestedProfile $requestedProfileValue -UnitKind $unitKindValue -Units $units)) {
            throw '續行的 ScopePlan 不存在、欄位不完整或與目前派工契約不一致。'
        }
        $scopePlan = $existingScopePlan
    }
    else {
        $scopePlan = New-ScopePlan -DispatchSlug $dispatchSlugValue -DispatchKind $dispatchKindValue -TaskType $TaskType -RequestedProfile $requestedProfileValue -SessionMode $sessionModeValue -BeforeSnapshot (Read-QuotaSnapshot -Path $beforeSnapshotPathValue) -CalibrationPath $calibrationPathValue -Units $units -UnitKind $unitKindValue -RequestedBudgetPercent $PrimaryBudgetPercent -RequestedReservePercent $PrimaryReservePercent -Model $Model
        $scopePlan.scope_plan_fingerprint = Get-ScopePlanFingerprint -ScopePlan $scopePlan
        Write-Utf8NoBom -Path $scopePlanPathValue -Content (($scopePlan | ConvertTo-Json -Depth 20) + "`n")
        $null = Write-ScopePlanHashRecordIfMissing -SourceHistoryRoot $sourceHistoryRoot -DispatchSlug $dispatchSlugValue -LineSlug $lineSlugValue -ScopePlanPath $scopePlanPathValue
    }
    if ($scopePlan.decision -eq 'blocked-no-estimate' -or $scopePlan.decision -eq 'blocked-insufficient-budget' -or $scopePlan.decision -eq 'user-decision-required') {
        throw "ScopePlan 阻擋派工：decision=$($scopePlan.decision); reason=$($scopePlan.decision_reason)"
    }
    if ($TaskType -eq 'deep-consult') {
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

    if ($TaskType -ne 'deep-consult') {
        $deepCycleDecision = Get-DeepCycleDecision -RequestedProfile $requestedProfileValue -RequestSource $DeepRequestSource -DaysToReset $SecondaryDaysToReset -RemainingPercent $SecondaryRemainingPercent
    }
    else {
        $deepCycleDecision = [ordered]@{
            applicable       = $true
            requestSource    = $DeepRequestSource
            gatePassed       = $null
            daysToReset      = $SecondaryDaysToReset
            remainingPercent = $SecondaryRemainingPercent
            notice           = 'deep-consult 使用獨立額度門檻，僅以 evidence pack 與 primary reserve 判定。'
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
    if ($TaskType -eq 'deep-consult') {
        $promptDirectives.Add(
            '[deep-consult evidence-only]' + [Environment]::NewLine +
            ('只可讀取 evidence pack：' + $evidencePackInfo.sandboxPath + '。禁止 repository 探索、掃描、檔案變更與外部派遣。請先輸出 ## 中斷保全結論，再輸出證據支持、推論與未決問題。')
        )
    }
    if ($null -ne $deepCycleDecision -and $deepCycleDecision.applicable -and $DeepRequestSource -eq 'user-explicit') {
        $promptDirectives.Add(('[deep 週期位置告知]' + [Environment]::NewLine + $deepCycleDecision.notice + ' 請在回報中保留此週期位置與剩餘額度。'))
    }
    $promptPathValue = New-DispatchPrompt -PromptPath $promptPathValue -HistoryRoot $historyRoot -Timestamp $timestamp -Directive @($promptDirectives.ToArray())

    $codexArguments = New-Object System.Collections.Generic.List[string]
    $codexArguments.Add('--cd')
    $codexWorkingRoot = $executionRootPath
    if ($null -ne $evidencePackInfo) {
        $codexWorkingRoot = Split-Path -Parent $evidencePackInfo.sandboxPath
    }
    $codexArguments.Add($codexWorkingRoot)
    $codexArguments.Add('--sandbox')
    $codexArguments.Add($(if ($TaskType -eq 'deep-consult') { 'read-only' } else { 'workspace-write' }))
    if ($effectiveProfileValue -ne 'default') {
        $codexArguments.Add('--profile')
        $codexArguments.Add($effectiveProfileValue)
    }
    if ($null -ne $AddDirectory) {
        foreach ($directory in $AddDirectory) {
            $directoryPath = Resolve-AbsolutePath -Path $directory
            if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) {
                throw "--add-dir 目錄不存在：$directoryPath"
            }
            $codexArguments.Add('--add-dir')
            $codexArguments.Add($directoryPath)
        }
    }
    if ($Search) {
        $codexArguments.Add('--search')
    }
    if ($null -ne $CodexParentOption) {
        foreach ($option in $CodexParentOption) {
            if ([string]::IsNullOrWhiteSpace($option)) {
                throw 'CodexParentOption 不可包含空白選項。'
            }
            $codexArguments.Add($option)
        }
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

    $launcher = New-CodexLauncher -CodexExecutable $codexExecutable -CodexArguments @($codexArguments.ToArray()) -PromptPath $promptPathValue -EventPath $eventPath -ErrorPath $errorPath -HistoryRoot $historyRoot -LauncherPath $launcherPath
    $launcherPath = $launcher.Path
    $startInfo = New-ProcessStartInfo -FileName $launcher.FileName -WorkingDirectory $executionRootPath -Arguments @($launcher.Arguments)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $startedSnapshot = $null
    $processStarted = $false
        if (-not $process.Start()) {
            throw 'Codex 啟動失敗。'
        }
        $processStarted = $true
        $startedSnapshot = Get-StartedProcessSnapshot -ProcessId $process.Id
        if ($null -eq $startedSnapshot) {
            throw "無法取得 Codex 根程序身分，PID $($process.Id) 未通過驗證。"
        }
        if ($startedSnapshot.IdentityStatus -ne 'confirmed' -or $startedSnapshot.IdentityVerified -ne $true) {
            throw "Codex 根程序身分無法確認，拒絕以未驗證程序收尾：PID $($process.Id); identity-status=$($startedSnapshot.IdentityStatus); failure-fields=$($startedSnapshot.IdentityFailureFields -join ','); missing-fields=$($startedSnapshot.IdentityMissingFields -join ',')"
        }

        $processGroupValue = ''
        if (-not (Test-IsWindowsPlatform)) {
            if ($null -eq $startedSnapshot.PSObject.Properties['ProcessGroupId'] -or $startedSnapshot.ProcessGroupId -le 0) {
                throw "無法取得 Codex 根程序的 process group，PID $($process.Id) 未通過驗證。"
            }
            $processGroupValue = [string]$startedSnapshot.ProcessGroupId
        }

        $pidContent = @(
            ('pid=' + $process.Id)
            ('root-pid=' + $process.Id)
            ('root-process-name=' + $startedSnapshot.ProcessName)
            ('root-parent-pid=' + $startedSnapshot.ParentProcessId)
            ('root-started-at-utc=' + $startedSnapshot.CreationUtc.ToString('o'))
            'identity-verified=true'
            ('process-tree-scope=' + $(if (Test-IsWindowsPlatform) { 'pid-and-descendants' } else { 'process-group' }))
            ('process-tree-query=' + $(if (Test-IsWindowsPlatform) { 'Win32_Process.ParentProcessId' } else { 'ps PGID 成員' }))
            ('process-group-id=' + $processGroupValue)
            ('work-root=' + $sourceRootPath)
            ('line-slug=' + $lineSlugValue)
            ('dispatch-slug=' + $dispatchSlugValue)
            ('write-mode=' + $writeModeValue)
            ('started-at-utc=' + [datetime]::UtcNow.ToString('o'))
        ) -join "`n"
        Write-Utf8NoBom -Path $pidPath -Content ($pidContent + "`n")
        $relay = Wait-ForThreadRelay -EventPath $eventPath -ThreadPath $threadPath -TimeoutSeconds 5
        if ([string]::IsNullOrWhiteSpace($relay.threadId)) {
            $phase = 'thread-relay-not-ready'
            throw ('thread relay not-ready：逾時 {0} 秒仍未取得非空 threadId；保留事件流與 relay 證據。' -f $relay.timeoutSeconds)
        }
        $budgetMonitorStatus.state = 'running'
        if ($TaskType -eq 'deep-consult') {
            $budgetMonitorStatus = Invoke-DeepBudgetMonitor -Process $process -StartedSnapshot $startedSnapshot -EventPath $eventPath -MonitorPath $monitorPathValue -BeforeSnapshot $beforeSnapshotObject -AfterSnapshotPath (Resolve-AbsolutePath -Path $afterSnapshotPathValue) -CodexHome $CodexHome -PrimaryBudgetPercent ([double]$scopePlan.primary_budget_percent) -AbortGraceSeconds $AbortGraceSeconds
            if ($budgetMonitorStatus.state -eq 'AbortedByBudget') {
                $phase = 'aborted-by-budget'
                throw "deep-consult 已由 BudgetMonitor 中止：$($budgetMonitorStatus.state)"
            }
            if ($budgetMonitorStatus.state -eq 'IdentityUnverified') {
                $skipProcessCleanup = $true
                $phase = 'identity-unverified'
                throw 'deep-consult BudgetMonitor 無法確認進程身分，保留未清理證據且不再終止程序。'
            }
            if ($budgetMonitorStatus.state -eq 'CrossReset') {
                $phase = 'cross-reset'
                throw 'deep-consult BudgetMonitor 偵測到 primary reset window 變更，停止監看並拒絕校準。'
            }
            if ($budgetMonitorStatus.state -eq 'SnapshotFailed') {
                throw 'deep-consult BudgetMonitor 無法取得有效 after quota snapshot。'
            }
        }
        $phase = 'started'

        return [ordered]@{
            operation        = 'Start'
            sourceRoot       = $sourceRootPath
            executionRoot    = $executionRootPath
            lineSlug         = $lineSlugValue
            dispatchSlug     = $dispatchSlugValue
            requestedProfile = $requestedProfileValue
            profile          = $effectiveProfileValue
            profileDowngraded = $false
            interruptionSafeguardApplied = $interruptionSafeguardApplied
            downgradeInstructionApplied = $interruptionSafeguardApplied
            model            = $Model
            reasoningEffort  = $ReasoningEffort
            taskType         = $TaskType
            sessionMode      = $sessionModeValue
            deepRequestSource = $DeepRequestSource
            deepCycleGatePassed = $deepCycleDecision.gatePassed
            secondaryDaysToReset = $deepCycleDecision.daysToReset
            secondaryRemainingPercent = $deepCycleDecision.remainingPercent
            deepCycleNotice  = $deepCycleDecision.notice
            resumeThreadId   = $ResumeThreadId
            rootPid          = $process.Id
            pidRecordPath    = $pidPath
            eventStreamPath  = $eventPath
            stderrPath       = $errorPath
            errorStreamPath  = $errorPath
            lastMessagePath  = $lastMessagePathValue
            promptPath       = $promptPathValue
            threadIdPath     = $threadPath
            threadId         = $relay.threadId
            scopePlanPath    = $scopePlanPathValue
            scopePlan         = $scopePlan
            quotaBeforePath  = $beforeSnapshotPathValue
            quotaAfterPath   = $afterSnapshotPathValue
            evidencePackPath = if ($null -eq $evidencePackInfo) { $null } else { $evidencePackInfo.path }
            evidencePackSandboxPath = if ($null -eq $evidencePackInfo) { $null } else { $evidencePackInfo.sandboxPath }
            evidencePackSha256 = if ($null -eq $evidencePackInfo) { $null } else { $evidencePackInfo.sha256 }
            budgetMonitorPath = $monitorPathValue
            budgetMonitor     = $budgetMonitorStatus
            launcherPath     = $launcher.Path
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
        $evidenceMessage = New-StartFailureEvidenceMessage -Phase $phase -EventPath $eventPath -ErrorPath $errorPath -LastMessagePath $lastMessagePathValue -ThreadPath $threadPath -PidPath $pidPath -LauncherPath $launcherPath -ProcessExitCode $processExitCodeValue -CleanupStatus $cleanupStatus -CleanupError $cleanupError
        if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
            try {
                $failureResultPath = Resolve-AbsolutePath -Path $ResultPath
                $failureResult = [ordered]@{
                    operation = 'Start'
                    success = $false
                    error = $originalMessage
                    evidence = $evidenceMessage
                }
                Write-Utf8NoBom -Path $failureResultPath -Content (($failureResult | ConvertTo-Json -Depth 8) + "`n")
            }
            catch {
                if ([string]::IsNullOrWhiteSpace($cleanupError)) {
                    $cleanupError = '寫入 Start 失敗結果檔失敗：' + $_.Exception.Message
                }
                else {
                    $cleanupError = $cleanupError + '；寫入 Start 失敗結果檔失敗：' + $_.Exception.Message
                }
            }
        }
        throw "$originalMessage`nStart 失敗證據：$evidenceMessage"
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

function Invoke-Inspect {
    if ([string]::IsNullOrWhiteSpace($RequiredIdentifier)) {
        throw 'Inspect 必須提供 RequiredIdentifier。'
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
    if (-not (Test-Path -LiteralPath $eventPath -PathType Leaf)) {
        throw "事件流檔案不存在：$eventPath"
    }

    $events = New-Object System.Collections.Generic.List[object]
    $malformedLines = New-Object System.Collections.Generic.List[object]
    $threadIds = New-Object System.Collections.Generic.List[string]
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $eventPath -Encoding UTF8) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
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
        throw "事件流包含無法解析的行，已保留其餘可解析事件，Inspect 以非零結束碼停止：`n$details"
    }
    if ($events.Count -eq 0) {
        throw '事件流沒有可解析的事件。'
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
            $threadIds.Add($threadIdValue)
        }
        $item = Get-EventPropertyValue -Object $event -Name 'item'
        if ($null -ne $item) {
            $itemType = Get-EventPropertyValue -Object $item -Name 'type'
            if (($itemType -is [string]) -and $itemType -eq 'agent_message') {
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

    $finalMessage = ''
    if (-not [string]::IsNullOrWhiteSpace($LastMessagePath) -and (Test-Path -LiteralPath $LastMessagePath -PathType Leaf)) {
        $finalMessage = Get-Content -LiteralPath $LastMessagePath -Raw -Encoding UTF8
    }
    if ([string]::IsNullOrWhiteSpace($finalMessage)) {
        $finalMessage = $lastAgentMessage
    }

    $outputValid = -not [string]::IsNullOrWhiteSpace($finalMessage) -and $finalMessage.Contains($RequiredIdentifier) -and $finalMessage.Contains($DispatchSlug) -and $finalMessage.Contains($LineSlug)
    $threadRelay = $null
    if (-not [string]::IsNullOrWhiteSpace($ThreadIdPath)) {
        $threadRelay = Set-ThreadIdFromEventStream -EventPath $eventPath -ThreadPath (Resolve-AbsolutePath -Path $ThreadIdPath) -RequireThreadId
    }

    $executionResult = [ordered]@{
        completed        = $lastEventType -eq 'turn.completed'
        success          = $lastEventType -eq 'turn.completed' -and [int]$ProcessExitCode -eq 0
        lastEventType    = $lastEventType
        processExitCode  = [int]$ProcessExitCode
        turnFailedReason = $turnFailedReason
        outputValid      = $outputValid
    }
    $scopePlan = Read-ScopePlanFile -Path $ScopePlanPath
    if ([string]::IsNullOrWhiteSpace($QuotaBeforePath)) {
        $snapshotFailure = 'Inspect 缺少 before quota snapshot。'
        $null = Add-SnapshotFailureCalibrationObservation -SourceRoot $SourceRoot -Path $CalibrationPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -Profile $Profile -Model $Model -ReasoningEffort $ReasoningEffort -TaskType $TaskType -SessionMode $SessionMode -Usage $usage -ExecutionResult $executionResult -QuotaBeforePath $QuotaBeforePath -QuotaAfterPath $QuotaAfterPath -ScopePlan $scopePlan -Failure $snapshotFailure
        throw ($snapshotFailure + ' 已寫入 calibration_eligible=false 觀測。')
    }
    try {
        $beforeSnapshot = Read-QuotaSnapshot -Path $QuotaBeforePath
    }
    catch {
        $snapshotFailure = 'Inspect before quota snapshot 無效：' + $_.Exception.Message
        $null = Add-SnapshotFailureCalibrationObservation -SourceRoot $SourceRoot -Path $CalibrationPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -Profile $Profile -Model $Model -ReasoningEffort $ReasoningEffort -TaskType $TaskType -SessionMode $SessionMode -Usage $usage -ExecutionResult $executionResult -QuotaBeforePath $QuotaBeforePath -QuotaAfterPath $QuotaAfterPath -ScopePlan $scopePlan -Failure $snapshotFailure
        throw ($snapshotFailure + ' 已寫入 calibration_eligible=false 觀測。')
    }
    $afterSnapshotPathValue = $QuotaAfterPath
    try {
        if ([string]::IsNullOrWhiteSpace($afterSnapshotPathValue) -and (-not [string]::IsNullOrWhiteSpace($CodexHome) -or -not [string]::IsNullOrWhiteSpace($env:CODEX_HOME))) {
            $historyRoot = Join-Path -Path (Resolve-AbsolutePath -Path $ExecutionRoot) -ChildPath '.local\ai-sessions\history'
            $afterSnapshotPathValue = Get-OrCreateQuotaSnapshot -Path $null -CodexHome $CodexHome -HistoryRoot $historyRoot -Purpose 'after' -Required
        }
    }
    catch {
        $snapshotFailure = 'Inspect after quota snapshot 取得失敗：' + $_.Exception.Message
        $null = Add-SnapshotFailureCalibrationObservation -SourceRoot $SourceRoot -Path $CalibrationPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -Profile $Profile -Model $Model -ReasoningEffort $ReasoningEffort -TaskType $TaskType -SessionMode $SessionMode -Usage $usage -ExecutionResult $executionResult -QuotaBeforePath $QuotaBeforePath -QuotaAfterPath $afterSnapshotPathValue -ScopePlan $scopePlan -Failure $snapshotFailure
        throw ($snapshotFailure + ' 已寫入 calibration_eligible=false 觀測。')
    }
    if ([string]::IsNullOrWhiteSpace($afterSnapshotPathValue)) {
        $snapshotFailure = 'Inspect 缺少 after quota snapshot。'
        $null = Add-SnapshotFailureCalibrationObservation -SourceRoot $SourceRoot -Path $CalibrationPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -Profile $Profile -Model $Model -ReasoningEffort $ReasoningEffort -TaskType $TaskType -SessionMode $SessionMode -Usage $usage -ExecutionResult $executionResult -QuotaBeforePath $QuotaBeforePath -QuotaAfterPath $afterSnapshotPathValue -ScopePlan $scopePlan -Failure $snapshotFailure
        throw ($snapshotFailure + ' 已寫入 calibration_eligible=false 觀測。')
    }
    try {
        $afterSnapshot = Read-QuotaSnapshot -Path $afterSnapshotPathValue
    }
    catch {
        $snapshotFailure = 'Inspect after quota snapshot 無效：' + $_.Exception.Message
        $null = Add-SnapshotFailureCalibrationObservation -SourceRoot $SourceRoot -Path $CalibrationPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -Profile $Profile -Model $Model -ReasoningEffort $ReasoningEffort -TaskType $TaskType -SessionMode $SessionMode -Usage $usage -ExecutionResult $executionResult -QuotaBeforePath $QuotaBeforePath -QuotaAfterPath $afterSnapshotPathValue -ScopePlan $scopePlan -Failure $snapshotFailure
        throw ($snapshotFailure + ' 已寫入 calibration_eligible=false 觀測。')
    }
    $interruptionStatus = [ordered]@{
        applied = $true
        safePointPresent = -not [string]::IsNullOrWhiteSpace((Get-LatestSafePointMessage -EventPath $eventPath))
        sessionMode = $SessionMode
    }
    $budgetMonitor = $null
    if (-not [string]::IsNullOrWhiteSpace($BudgetMonitorPath) -and (Test-Path -LiteralPath $BudgetMonitorPath -PathType Leaf)) {
        $budgetMonitor = @(Get-Content -LiteralPath $BudgetMonitorPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop })
    }
    $budgetMonitorRejected = $false
    foreach ($monitorRecord in @($budgetMonitor)) {
        $monitorState = [string](Get-OptionalObjectProperty -Object $monitorRecord -Name 'state')
        $monitorEvent = [string](Get-OptionalObjectProperty -Object $monitorRecord -Name 'event')
        if ($monitorState -eq 'AbortedByBudget' -or $monitorEvent -eq 'monitor.terminal-budget-exceeded') {
            $budgetMonitorRejected = $true
            break
        }
    }
    if ($budgetMonitorRejected) {
        $executionResult.success = $false
        $executionResult.budgetMonitorRejected = $true
        if ([string]::IsNullOrWhiteSpace($executionResult.turnFailedReason)) {
            $executionResult.turnFailedReason = 'BudgetMonitor 偵測到行程結束後超出 primary budget。'
        }
    }
    $calibrationResult = Add-CalibrationObservation -SourceRoot $SourceRoot -Path $CalibrationPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -Profile $Profile -Model $Model -ReasoningEffort $ReasoningEffort -TaskType $TaskType -SessionMode $SessionMode -Usage $usage -ExecutionResult $executionResult -QuotaBeforePath $QuotaBeforePath -QuotaAfterPath $afterSnapshotPathValue -ScopePlan $scopePlan -InterruptionStatus $interruptionStatus -BudgetMonitor $budgetMonitor

    $deepReportPathValue = $DeepConsultReportPath
    if ($TaskType -eq 'deep-consult') {
        if ($null -eq $scopePlan -or $scopePlan.task_type -ne 'deep-consult') {
            throw 'deep-consult Inspect 缺少一致的 ScopePlan。'
        }
        if ([string]::IsNullOrWhiteSpace($deepReportPathValue)) {
            throw 'deep-consult Inspect 必須提供 DeepConsultReportPath。'
        }
        if ([string]::IsNullOrWhiteSpace($EvidencePackPath)) {
            throw 'deep-consult Inspect 必須提供 EvidencePackPath。'
        }
        $deepReportPathValue = Get-DeepConsultReportPath -Path $deepReportPathValue -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        $evidencePackInfo = Test-EvidencePack -Path $EvidencePackPath -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        $evidencePathValue = $evidencePackInfo.path
        $evidenceHash = Get-FileSha256 -Path $evidencePathValue
        $evidenceHashRecordPath = Join-Path -Path (Split-Path -Parent $eventPath) -ChildPath ('evidence-pack-' + $DispatchSlug + '.sha256')
        if (-not (Test-Path -LiteralPath $evidenceHashRecordPath -PathType Leaf)) {
            throw 'evidence pack 缺少 Start SHA-256 紀錄，拒絕成功 Inspect。'
        }
        $expectedHash = (Get-Content -LiteralPath $evidenceHashRecordPath -Raw -Encoding UTF8).Trim()
        if ([string]::IsNullOrWhiteSpace($expectedHash) -or -not [string]::Equals($expectedHash, $evidenceHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'evidence pack SHA-256 在 Start 與 Inspect 之間變更。'
        }
        $deepStatus = if ($executionResult.success) { 'completed' } else { 'failed' }
        $deepReportWrittenPath = Write-DeepConsultReport -Path $deepReportPathValue -LineSlug $LineSlug -DispatchSlug $DispatchSlug -EvidencePackPath $evidencePathValue -EvidencePackSha256 $evidenceHash -FinalMessage $finalMessage -Status $deepStatus -BudgetMonitor $budgetMonitor
    }

    $result = [ordered]@{
        operation        = 'Inspect'
        eventStreamPath  = $eventPath
        processExitCode  = [int]$ProcessExitCode
        eventCount       = $events.Count
        lastEventType    = $lastEventType
        threadId         = $threadId
        completed        = $executionResult.completed
        success          = $executionResult.success
        turnFailedReason = $executionResult.turnFailedReason
        finalMessage     = $finalMessage
        outputValid      = $outputValid
        usage            = $usage
        threadIdPath     = $ThreadIdPath
        threadRelay      = $threadRelay
        quotaBeforePath  = $QuotaBeforePath
        quotaAfterPath   = $afterSnapshotPathValue
        afterSnapshot    = $afterSnapshot.values
        scopePlan        = $scopePlan
        budgetMonitorRejected = $budgetMonitorRejected
        deepConsultReportPath = if ($TaskType -eq 'deep-consult') { $deepReportWrittenPath } else { $null }
        stderr           = if (-not [string]::IsNullOrWhiteSpace($ErrorStreamPath) -and (Test-Path -LiteralPath $ErrorStreamPath -PathType Leaf)) { Get-Content -LiteralPath $ErrorStreamPath -Raw -Encoding UTF8 } else { '' }
    }
    if ($null -ne $calibrationResult) {
        $result.calibration = $calibrationResult
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

function Get-RequirementSection {
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Heading
    )

    $headingPattern = '(?ms)^##[ \t]+' + [regex]::Escape($Heading) + '[ \t]*\r?\n(?<section>.*?)(?=^##[ \t]|\z)'
    $match = [regex]::Match($Content, $headingPattern)
    if (-not $match.Success) {
        return $null
    }

    return $match.Groups['section'].Value
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
        if ($status -eq '排除(design.md §8)') {
            $status = '排除（design.md §8）'
        }
        if ($status -notin @('已交付', '部分交付', '未交付', '排除（design.md §8）')) {
            $rowValid = $false
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

    $summaryContent = Get-Content -LiteralPath $summaryFullPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($summaryContent)) {
        throw "需求摘要為空：$summaryFullPath"
    }

    $requirementIds = @(Get-RequirementIdsFromSummary -Content $summaryContent -SummaryPath $summaryFullPath)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $invalidColumnCountRows = New-Object 'System.Collections.Generic.List[string]'
    $emptyFieldIds = New-Object 'System.Collections.Generic.List[string]'
    $invalidRequirementCells = New-Object 'System.Collections.Generic.List[string]'
    $invalidHeader = New-Object 'System.Collections.Generic.List[string]'
    $invalidSectionContent = New-Object 'System.Collections.Generic.List[string]'
    $duplicateRequirementSections = New-Object 'System.Collections.Generic.List[string]'
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
            continue
        }

        $requirementMatch = [regex]::Match($reportContent, '(?ms)^##[ \t]+需求對照[ \t]*\r?\n(?<section>.*?)(?=^##[ \t]|\z)')
        if (-not $requirementMatch.Success) {
            throw "結案報告缺少需求對照節：$reportFullPath"
        }

        $reportRows = @(Get-RequirementTableRows -Section $requirementMatch.Groups['section'].Value -ReportName $reportName -InvalidColumnCountRows $invalidColumnCountRows -EmptyFieldIds $emptyFieldIds -InvalidRequirementCells $invalidRequirementCells -InvalidHeader $invalidHeader -InvalidSectionContent $invalidSectionContent)
        foreach ($row in $reportRows) {
            $status = $row.Status
            if ($validStatuses.Contains($status)) {
                $statusCounts[$status] = [int]$statusCounts[$status] + 1
            }
            $rows.Add($row)
        }
    }

    $reportedIds = @($rows | ForEach-Object { $_.Id } | Sort-Object -Unique)
    $missingRequirementIds = @($requirementIds | Where-Object { $reportedIds -notcontains $_ } | Sort-Object)
    $duplicateRequirementIds = @($rows | Group-Object -Property Id | Where-Object { $_.Count -gt 1 } | ForEach-Object { [int]$_.Name } | Sort-Object)
    $unknownRequirementIds = @($reportedIds | Where-Object { $requirementIds -notcontains $_ } | Sort-Object)
    $invalidStatusIds = @($rows | Where-Object { -not $validStatuses.Contains($_.Status) } | ForEach-Object { $_.Id } | Sort-Object -Unique)
    $duplicateRequirementSections = @($duplicateRequirementSections | Sort-Object -Unique)
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
        $invalidStatusIds.Count -gt 0) {
        throw "需求對照結構不一致。duplicateRequirementSections=$($duplicateRequirementSections -join ','); invalidSectionContent=$($invalidSectionContent -join ','); missingRequirementIds=$($missingRequirementIds -join ','); duplicateRequirementIds=$($duplicateRequirementIds -join ','); unknownRequirementIds=$($unknownRequirementIds -join ','); invalidColumnCountRows=$($invalidColumnCountRows -join ','); emptyFieldIds=$($emptyFieldIds -join ','); invalidRequirementCells=$($invalidRequirementCells -join ','); invalidHeader=$($invalidHeader -join ','); invalidStatusIds=$($invalidStatusIds -join ',')"
    }

    return [ordered]@{
        summaryPath     = $summaryFullPath
        requirementIds  = @($requirementIds)
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
        [ValidateSet('workflow', 'resource')]
        [string]$DispatchKind,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$TargetStates,

        [Parameter(Mandatory)]
        [string[]]$ReportPath,

        [AllowNull()]
        [object]$RequirementMap
    )

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

    $result = [ordered]@{
        operation          = 'Collect'
        collectionMode     = 'direct-write'
        sourceRoot         = $SourceRoot
        executionRoot      = $ExecutionRoot
        dispatchRoot       = ''
        baseSha            = ''
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
        outputValid        = $true
        worktreeRemoved    = $false
    }

    if ($DispatchKind -eq 'workflow') {
        $result.requirementMap = $RequirementMap
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
            return Invoke-DirectWriteCollect -SourceRoot $preflightSourceRoot -ExecutionRoot $preflightExecutionRoot -DispatchKind $DispatchKind -TargetStates @($targetStatesProperty.Value) -ReportPath $ReportPath -RequirementMap $requirementMap
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
    $allFiles = @($trackedDiff + $untrackedFiles | Sort-Object -Unique)
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
                    IsTracked = @($trackedDiff | ForEach-Object { Convert-ComparisonPath -Path $_ }) -contains $normalizedFile
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

    $result = [ordered]@{
        operation          = 'Collect'
        dispatchRoot       = $dispatchRootPath
        baseSha            = $BaseSha
        dispatchKind       = $DispatchKind
        trackedDiff        = @($trackedDiff)
        stagedDiff         = @($stagedDiff)
        untrackedFiles     = @($untrackedFiles)
        allFiles           = @($allFiles)
        reportPaths        = @($ReportPath | ForEach-Object { Resolve-AbsolutePath -Path $_ })
        reportReferences   = @($normalizedReportReferences)
        missingFromReport  = @($missingFromReport)
        unexpectedInReport = @($unexpectedInReport)
        itemChecks         = $matchesArray
        reportEvidence     = @($reportEvidence)
        outputValid        = $true
        worktreeRemoved    = $false
    }

    if ($DispatchKind -eq 'workflow') {
        $result.requirementMap = $requirementMap
    }

    return $result
}

function Write-OperationResult {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Result
    )

    $json = $Result | ConvertTo-Json -Depth 12
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        Write-Utf8NoBom -Path (Resolve-AbsolutePath -Path $ResultPath) -Content ($json + "`n")
    }
    Write-Output $json
}

try {
    $result = switch ($Operation) {
        'Preflight' { Invoke-Preflight }
        'Start'     { Invoke-Start }
        'Inspect'   { Invoke-Inspect }
        'Collect'   { Invoke-Collect }
        'QuotaProbe' { Invoke-QuotaProbe }
        default     { throw "不支援的 operation：$Operation" }
    }
    Write-OperationResult -Result $result
    exit 0
}
catch {
    [Console]::Error.WriteLine(('Invoke-CodexDispatch.ps1 失敗：{0}' -f $_.Exception.Message))
    exit 1
}
