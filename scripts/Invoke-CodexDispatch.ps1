#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Preflight', 'Start', 'Inspect', 'Collect')]
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

    [string]$Profile = 'default',

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
    $result = Invoke-ExternalCommand -FileName $psPath -WorkingDirectory (Get-Location).Path -Arguments @('-o', 'pid=,pgid=,comm=', '-p', [string]$ProcessId) -AllowFailure
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

    $fields = $line.Trim() -split '\s+', 3
    if ($fields.Count -lt 3) {
        throw "Unix PID 查詢結果格式錯誤：$($result.StdOut.Trim())"
    }

    $parsedPid = 0
    $parsedGroupId = 0
    if (-not [int]::TryParse($fields[0], [ref]$parsedPid) -or $parsedPid -ne $ProcessId -or -not [int]::TryParse($fields[1], [ref]$parsedGroupId) -or $parsedGroupId -le 0) {
        throw "Unix PID 查詢結果無法取得有效 PID 或 process group id：$($result.StdOut.Trim())"
    }

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $creationUtc = $process.StartTime.ToUniversalTime()
    }
    catch {
        throw "無法取得 Unix PID $ProcessId 的建立時間：$($_.Exception.Message)"
    }

    return [pscustomobject]@{
        ProcessId       = $parsedPid
        ParentProcessId = 0
        ProcessName     = $fields[2].Trim()
        CreationUtc     = $creationUtc
        ProcessGroupId  = $parsedGroupId
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
                $liveProcessIds = @(Get-DescendantProcessIds -RootProcessId $rootPid -ProcessesById $processesById -ConfirmedOnly)
                if ($liveProcessIds.Count -gt 0 -and (Test-RecordedIdentityEvidence -Record $record)) {
                    $identityVerified = $true
                    $isActive = $true
                }
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
        $snapshot | Add-Member -MemberType NoteProperty -Name IdentityVerified -Value $true -Force
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
    $phase = 'preparation'
    $cleanupStatus = 'not-started'
    $cleanupError = $null

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
            profile          = $Profile
            resumeThreadId   = $ResumeThreadId
            rootPid          = $process.Id
            pidRecordPath    = $pidPath
            eventStreamPath  = $eventPath
            stderrPath       = $errorPath
            errorStreamPath  = $errorPath
            lastMessagePath  = $lastMessagePathValue
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
        [byte], [sbyte], [short], [ushort], [int], [uint], [long], [ulong],
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

    return [ordered]@{
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

function Invoke-Collect {
    if ([string]::IsNullOrWhiteSpace($DispatchRoot) -or [string]::IsNullOrWhiteSpace($BaseSha)) {
        throw 'Collect 必須提供 DispatchRoot 與 BaseSha。'
    }
    if ($null -eq $ReportPath -or $ReportPath.Count -eq 0) {
        throw 'Collect 必須提供至少一個 ReportPath。'
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

    return [ordered]@{
        operation          = 'Collect'
        dispatchRoot       = $dispatchRootPath
        baseSha            = $BaseSha
        trackedDiff        = @($trackedDiff)
        stagedDiff         = @($stagedDiff)
        untrackedFiles     = @($untrackedFiles)
        allFiles           = @($allFiles)
        reportPaths        = @($ReportPath | ForEach-Object { Resolve-AbsolutePath -Path $_ })
        reportReferences   = @($reportReferences)
        missingFromReport  = @($missingFromReport)
        unexpectedInReport = @($unexpectedInReport)
        itemChecks         = $matchesArray
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
        default     { throw "不支援的 operation：$Operation" }
    }
    Write-OperationResult -Result $result
    exit 0
}
catch {
    [Console]::Error.WriteLine(('Invoke-CodexDispatch.ps1 失敗：{0}' -f $_.Exception.Message))
    exit 1
}
