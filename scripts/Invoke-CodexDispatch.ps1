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

    [switch]$DowngradeInstruction,

    [string]$QuotaBeforePath,

    [string]$QuotaAfterPath,

    [string]$CalibrationPath,

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

    $values = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $snapshotPath -Encoding UTF8) {
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
        path   = $snapshotPath
        values = $values
    }
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

        [string]$QuotaAfterPath
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

    $beforeSnapshot = Read-QuotaSnapshot -Path $QuotaBeforePath
    $afterSnapshot = Read-QuotaSnapshot -Path $QuotaAfterPath
    $modelLabel = if ([string]::IsNullOrWhiteSpace($Model)) { 'unlabeled' } else { $Model }
    $taskTypeLabel = if ([string]::IsNullOrWhiteSpace($TaskType)) { 'unspecified' } else { $TaskType }
    $sessionModeLabel = if ([string]::IsNullOrWhiteSpace($SessionMode)) { 'unspecified' } else { $SessionMode }
    $hasMarkedModel = $modelLabel -ne 'unlabeled'
    $hasMarkedTaskType = $taskTypeLabel -ne 'unspecified'
    $hasSnapshots = $null -ne $beforeSnapshot -and $null -ne $afterSnapshot
    $hasUsage = Test-UsageObject -Value $Usage
    $eligible = $hasMarkedModel -and $hasMarkedTaskType -and $hasSnapshots -and $hasUsage

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
        }
        task_type             = $taskTypeLabel
        reasoning_effort     = $ReasoningEffort
        calibration_eligible  = $eligible
        'turn.completed.usage' = $Usage
        usage                 = $Usage
        dispatch_before_snapshot = if ($null -eq $beforeSnapshot) { $null } else { $beforeSnapshot.values }
        dispatch_after_snapshot  = if ($null -eq $afterSnapshot) { $null } else { $afterSnapshot.values }
        execution_result      = $ExecutionResult
    }
    Append-Utf8NoBom -Path $calibrationPath -Content (($record | ConvertTo-Json -Depth 16 -Compress))

    $matchingRecords = @(Get-CalibrationRecords -Path $calibrationPath | Where-Object {
            $_.calibration_eligible -eq $true -and
            $_.model -eq $modelLabel -and
            $_.profile -eq $Profile -and
            $_.session_mode -eq $sessionModeLabel
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
    }
    if ($recommendationReady) {
        $calibrationStatus.recommendationSignal = '主 Agent 可提出新門檻，須先取得使用者確認；腳本不自動更新規則。'
    }

    return $calibrationStatus
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

        if ($identityStatus -ne 'confirmed') {
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
    if ($InitialQuotaState -ne 'PostResetNoSnapshot') {
        throw "QuotaProbe 僅允許回復 PostResetNoSnapshot，收到：$InitialQuotaState"
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
    if ($DowngradeInstruction -and -not [string]::IsNullOrWhiteSpace($ResumeThreadId)) {
        throw 'Start 拒絕互斥參數：DowngradeInstruction 不得與 ResumeThreadId 同時使用。deep 續行遇低額度時，唯一合法出口是攜帶完整交接的新 cold-start 預設檔位派遣。'
    }

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
    $phase = 'preparation'
    $cleanupStatus = 'not-started'
    $cleanupError = $null
    $requestedProfileValue = $Profile
    $effectiveProfileValue = $Profile
    $sessionModeValue = $SessionMode
    $deepCycleDecision = $null
    $downgradeApplied = $false

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
    if ([string]::IsNullOrWhiteSpace($lastMessagePathValue)) {
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
    if (-not $DowngradeInstruction) {
        $deepCycleDecision = Get-DeepCycleDecision -RequestedProfile $requestedProfileValue -RequestSource $DeepRequestSource -DaysToReset $SecondaryDaysToReset -RemainingPercent $SecondaryRemainingPercent
    }
    else {
        $deepCycleDecision = [ordered]@{
            applicable       = $false
            requestSource    = $DeepRequestSource
            gatePassed       = $null
            daysToReset      = $SecondaryDaysToReset
            remainingPercent = $SecondaryRemainingPercent
            notice           = '額度低於目標門檻，已改用預設檔位。'
        }
        $effectiveProfileValue = 'default'
        $downgradeApplied = $true
    }

    $promptDirectives = New-Object System.Collections.Generic.List[string]
    if ($DowngradeInstruction) {
        $promptDirectives.Add(
            '[額度降級指示]' + [Environment]::NewLine +
            '本次派工使用預設檔位，因有效額度快照低於目標門檻。請先交付已確認的結果，明確標明實際覆蓋範圍；即使額度不足，也不得在零產出的情況下中斷。'
        )
    }
    if ($null -ne $deepCycleDecision -and $deepCycleDecision.applicable -and $DeepRequestSource -eq 'user-explicit') {
        $promptDirectives.Add(('[deep 週期位置告知]' + [Environment]::NewLine + $deepCycleDecision.notice + ' 請在回報中保留此週期位置與剩餘額度。'))
    }
    $promptPathValue = New-DispatchPrompt -PromptPath $promptPathValue -HistoryRoot $historyRoot -Timestamp $timestamp -Directive @($promptDirectives.ToArray())

    $codexArguments = New-Object System.Collections.Generic.List[string]
    $codexArguments.Add('--cd')
    $codexArguments.Add($executionRootPath)
    $codexArguments.Add('--sandbox')
    $codexArguments.Add('workspace-write')
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
        Write-Utf8NoBom -Path $threadPath -Content ''
        $phase = 'started'

        return [ordered]@{
            operation        = 'Start'
            sourceRoot       = $sourceRootPath
            executionRoot    = $executionRootPath
            lineSlug         = $lineSlugValue
            dispatchSlug     = $dispatchSlugValue
            requestedProfile = $requestedProfileValue
            profile          = $effectiveProfileValue
            profileDowngraded = $downgradeApplied
            downgradeInstructionApplied = $DowngradeInstruction.IsPresent
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
            if ($startedSnapshot.IdentityVerified -eq $true) {
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
        if ($eventType -eq 'thread.started' -and [string]::IsNullOrWhiteSpace($threadId)) {
            $threadIdValue = Get-EventPropertyValue -Object $event -Name 'thread_id'
            if ($null -eq $threadIdValue -or -not ($threadIdValue -is [string]) -or [string]::IsNullOrWhiteSpace($threadIdValue)) {
                throw 'thread.started.thread_id 必須為非空字串。'
            }
            $threadId = $threadIdValue
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

    if ([string]::IsNullOrWhiteSpace($threadId)) {
        throw '事件流缺少 thread.started.thread_id。'
    }

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
    if (-not [string]::IsNullOrWhiteSpace($ThreadIdPath) -and -not [string]::IsNullOrWhiteSpace($threadId)) {
        Write-Utf8NoBom -Path (Resolve-AbsolutePath -Path $ThreadIdPath) -Content ($threadId + "`n")
    }

    $executionResult = [ordered]@{
        completed        = $lastEventType -eq 'turn.completed'
        success          = $lastEventType -eq 'turn.completed' -and [int]$ProcessExitCode -eq 0
        lastEventType    = $lastEventType
        processExitCode  = [int]$ProcessExitCode
        turnFailedReason = $turnFailedReason
        outputValid      = $outputValid
    }
    $calibrationResult = Add-CalibrationObservation -SourceRoot $SourceRoot -Path $CalibrationPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -Profile $Profile -Model $Model -ReasoningEffort $ReasoningEffort -TaskType $TaskType -SessionMode $SessionMode -Usage $usage -ExecutionResult $executionResult -QuotaBeforePath $QuotaBeforePath -QuotaAfterPath $QuotaAfterPath

    $result = [ordered]@{
        operation        = 'Inspect'
        eventStreamPath  = $eventPath
        processExitCode  = [int]$ProcessExitCode
        eventCount       = $events.Count
        lastEventType    = $lastEventType
        threadId         = $threadId
        completed        = $lastEventType -eq 'turn.completed'
        success          = $lastEventType -eq 'turn.completed' -and [int]$ProcessExitCode -eq 0
        turnFailedReason = $turnFailedReason
        finalMessage     = $finalMessage
        outputValid      = $outputValid
        usage            = $usage
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

    $normalized = $Path.Trim().Trim('`', '"', "'").Replace('/', '\')
    if ([System.IO.Path]::IsPathRooted($normalized) -and (Test-PathWithinRoot -Path $normalized -Root $DispatchRoot)) {
        return (Get-RelativePathFromRoot -Path $normalized -Root $DispatchRoot).Replace('/', '\')
    }
    return $normalized
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

    $hash = Get-FileHash -LiteralPath $fullPath -Algorithm SHA256
    return [ordered]@{
        path             = $fullPath
        relativePath     = Get-RelativePathFromRoot -Path $fullPath -Root $SourceRoot
        length           = [int64]$file.Length
        lastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
        sha256           = $hash.Hash
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
        [string[]]$ReportPath
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

    return [ordered]@{
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
}

function Invoke-Collect {
    if ($null -eq $ReportPath -or $ReportPath.Count -eq 0) {
        throw 'Collect 必須提供至少一個 ReportPath。'
    }
    if ([string]::IsNullOrWhiteSpace($DispatchKind)) {
        throw 'Collect 必須提供 DispatchKind。'
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
            return Invoke-DirectWriteCollect -SourceRoot $preflightSourceRoot -ExecutionRoot $preflightExecutionRoot -DispatchKind $DispatchKind -TargetStates @($targetStatesProperty.Value) -ReportPath $ReportPath
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
    if ($DispatchKind -eq 'workflow') {
        $reportReferences = @(Get-ReportReferencedPaths -ReportPath $ReportPath -DispatchRoot $dispatchRootPath)
        $matches = New-Object System.Collections.Generic.List[object]
        foreach ($file in $allFiles) {
            $normalizedFile = $file.Replace('/', '\')
            $inReport = $reportReferences -contains $normalizedFile
            $matches.Add([pscustomobject]@{
                    Path      = $normalizedFile
                    InReport  = $inReport
                    IsStaged  = $stagedDiff -contains $file
                    IsTracked = $trackedDiff -contains $file
                })
        }
        $matchesArray = @($matches.ToArray())
        $missingFromReport = @($matchesArray | Where-Object { -not $_.InReport } | ForEach-Object { $_.Path })
        $unexpectedInReport = @($reportReferences | Where-Object { $allFiles -notcontains $_ })
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

    return [ordered]@{
        operation          = 'Collect'
        dispatchRoot       = $dispatchRootPath
        baseSha            = $BaseSha
        dispatchKind       = $DispatchKind
        trackedDiff        = @($trackedDiff)
        stagedDiff         = @($stagedDiff)
        untrackedFiles     = @($untrackedFiles)
        allFiles           = @($allFiles)
        reportPaths        = @($ReportPath | ForEach-Object { Resolve-AbsolutePath -Path $_ })
        reportReferences   = @($reportReferences)
        missingFromReport  = @($missingFromReport)
        unexpectedInReport = @($unexpectedInReport)
        itemChecks         = $matchesArray
        reportEvidence     = @($reportEvidence)
        outputValid        = $true
        worktreeRemoved    = $false
    }
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
