function Add-AtomicJsonLine {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content,

        [AllowEmptyString()]
        [string]$SourceRoot,

        [AllowEmptyString()]
        [string]$ExecutionRoot,

        [string[]]$TargetPath
    )

    $context = Get-DispatchOutputPathContext -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    $resolvedPath = Resolve-DispatchOutputPathFromContext -CandidatePath $Path -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
    $parent = Split-Path -Parent $resolvedPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        $null = New-DispatchOutputDirectory -Path $parent -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
    }
    $resolvedPath = Resolve-DispatchOutputPathFromContext -CandidatePath $resolvedPath -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList @($false)
    $bytes = $encoding.GetBytes($Content + [Environment]::NewLine)
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $stream = $null
        try {
            $resolvedPath = Resolve-DispatchOutputPathFromContext -CandidatePath $resolvedPath -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
            $stream = New-Object System.IO.FileStream(
                $resolvedPath,
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

function Test-CimNativeErrorCodeFallbackEligible {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$NativeErrorCode
    )

    $accessDeniedNativeErrorCode = [int][Microsoft.Management.Infrastructure.NativeErrorCode]::AccessDenied
    return ($NativeErrorCode -eq $accessDeniedNativeErrorCode)
}

function Test-WindowsProcessQueryFallbackEligible {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Exception]$Exception
    )

    $fallbackCriteria = @{
        ExceptionTypes = @(
            [System.UnauthorizedAccessException].FullName,
            [System.TimeoutException].FullName
        )
        CimExceptionType = 'Microsoft.Management.Infrastructure.CimException'
        HResultCodes = @('80070005', '80041003', '80041069', '80043001', '800705B4')
    }

    $currentException = $Exception
    while ($null -ne $currentException) {
        if ($currentException.GetType().FullName -in $fallbackCriteria.ExceptionTypes) {
            return $true
        }

        if ($currentException.GetType().FullName -ceq $fallbackCriteria.CimExceptionType) {
            if (Test-CimNativeErrorCodeFallbackEligible -NativeErrorCode ([int]$currentException.NativeErrorCode)) {
                return $true
            }
        }

        $hresultBytes = [System.BitConverter]::GetBytes([int]$currentException.HResult)
        $hresultCode = [System.BitConverter]::ToUInt32($hresultBytes, 0).ToString('X8')
        if ($hresultCode -in $fallbackCriteria.HResultCodes) {
            return $true
        }

        $currentException = $currentException.InnerException
    }

    return $false
}

function Format-WindowsProcessQueryError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Exception]$Exception
    )

    $hresultBytes = [System.BitConverter]::GetBytes([int]$Exception.HResult)
    $hresultCode = [System.BitConverter]::ToUInt32($hresultBytes, 0).ToString('X8')
    $statusCodeProperty = $Exception.PSObject.Properties['StatusCode']
    $statusCode = if ($null -eq $statusCodeProperty) { 'unavailable' } else { [string]$statusCodeProperty.Value }

    return ('{0}; HRESULT=0x{1}; StatusCode={2}; Message={3}' -f $Exception.GetType().FullName, $hresultCode, $statusCode, $Exception.Message)
}

function Get-DotNetWindowsProcessSnapshots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CimError
    )

    $snapshots = @{}
    $unconfirmedProcesses = New-Object System.Collections.Generic.List[object]
    $enumerationError = $null
    try {
        $processes = [System.Diagnostics.Process]::GetProcesses()
    }
    catch {
        $enumerationError = $_.Exception.Message
        return [pscustomobject]@{
            ById = $snapshots
            UnconfirmedProcesses = @()
            QueryStatus = 'unavailable'
            ProcessQuerySource = 'unavailable'
            RawQueryError = ('Win32_Process: ' + $CimError + '; System.Diagnostics.Process: ' + $enumerationError)
            ParentProcessIdsAvailable = $false
        }
    }

    foreach ($process in $processes) {
        $processId = 0
        $processName = $null
        $creationUtc = $null
        $missingFields = New-Object System.Collections.Generic.List[string]
        $failureFields = New-Object System.Collections.Generic.List[string]
        try {
            try {
                $processId = [int]$process.Id
                if ($processId -le 0) { throw 'PID 必須大於零。' }
            }
            catch {
                $failureFields.Add('ProcessId')
            }
            try {
                $processName = [string]$process.ProcessName
                if ([string]::IsNullOrWhiteSpace($processName)) { throw '程序名稱為空白。' }
            }
            catch {
                $failureFields.Add('ProcessName')
            }
            try {
                $creationUtc = ([datetime]$process.StartTime).ToUniversalTime()
            }
            catch {
                $failureFields.Add('StartTime')
            }

            $identityStatus = 'confirmed'
            if ($failureFields.Count -gt 0) {
                $identityStatus = 'unconfirmable'
            }
            elseif ($missingFields.Count -gt 0) {
                $identityStatus = 'missing-field'
            }
            $snapshot = [pscustomobject]@{
                ProcessId = if ($processId -gt 0) { $processId } else { $null }
                ParentProcessId = 0
                ReportedProcessId = if ($processId -gt 0) { [string]$processId } else { '<unknown>' }
                ReportedParentProcessId = '<unavailable>'
                ProcessName = $processName
                CreationUtc = $creationUtc
                IdentityStatus = $identityStatus
                IdentityMissingFields = @($missingFields.ToArray())
                IdentityFailureFields = @($failureFields.ToArray())
                ProcessQuerySource = 'dotnet'
                RawQueryError = $CimError
                ParentProcessIdAvailable = $false
                ParentIdentityStatus = 'unconfirmed'
            }
            if ($processId -gt 0) {
                $snapshots[$processId] = $snapshot
                if ($identityStatus -ne 'confirmed') {
                    $unconfirmedProcesses.Add($snapshot)
                }
            }
        }
        finally {
            if ($null -ne $process) {
                $process.Dispose()
            }
        }
    }

    return [pscustomobject]@{
        ById = $snapshots
        UnconfirmedProcesses = @($unconfirmedProcesses.ToArray())
        QueryStatus = 'available'
        ProcessQuerySource = 'dotnet'
        RawQueryError = $CimError
        ParentProcessIdsAvailable = $false
    }
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
        $cimException = $_.Exception
        $cimError = Format-WindowsProcessQueryError -Exception $cimException
        if (-not (Test-WindowsProcessQueryFallbackEligible -Exception $cimException)) {
            return [pscustomobject]@{
                ById = $snapshots
                UnconfirmedProcesses = @()
                QueryStatus = 'unavailable'
                ProcessQuerySource = 'unavailable'
                RawQueryError = ('Win32_Process: ' + $cimError)
                ParentProcessIdsAvailable = $false
            }
        }

        try {
            return Get-DotNetWindowsProcessSnapshots -CimError $cimError
        }
        catch {
            return [pscustomobject]@{
                ById = $snapshots
                UnconfirmedProcesses = @()
                QueryStatus = 'unavailable'
                ProcessQuerySource = 'unavailable'
                RawQueryError = ('Win32_Process: ' + $cimError + '; System.Diagnostics.Process: ' + $_.Exception.Message)
                ParentProcessIdsAvailable = $false
            }
        }
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
            ProcessQuerySource    = 'cim'
            RawQueryError         = $null
            ParentProcessIdAvailable = ($parentProcessIdProperty -ne $null -and $conversionFailures -notcontains 'ParentProcessId' -and $missingFields -notcontains 'ParentProcessId')
            ParentIdentityStatus  = if ($parentProcessIdProperty -ne $null -and $conversionFailures -notcontains 'ParentProcessId' -and $missingFields -notcontains 'ParentProcessId') { 'confirmed' } else { 'unconfirmed' }
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
        QueryStatus = 'available'
        ProcessQuerySource = 'cim'
        RawQueryError = $null
        ParentProcessIdsAvailable = $true
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

    $line = @($result.StdOut -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -First 1
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
    foreach ($line in @($result.StdOut -split '\r?\n')) {
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
            $parentProcessIdAvailable = $snapshot.PSObject.Properties['ParentProcessIdAvailable']
            if ($null -ne $parentProcessIdAvailable -and $parentProcessIdAvailable.Value -ne $true) {
                continue
            }
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
    $processQueryStatus = 'available'
    $processQuerySource = if (Test-IsWindowsPlatform) { 'cim' } else { 'unix' }
    $rawProcessQueryError = $null
    $parentProcessIdsAvailable = $true
    if ((Test-IsWindowsPlatform) -and $records.Count -gt 0) {
        $snapshotResult = Get-WindowsProcessSnapshots -FailOnError
        $processesById = $snapshotResult.ById
        $unconfirmedProcesses = @($snapshotResult.UnconfirmedProcesses)
        $processQueryStatus = [string](Get-OptionalObjectProperty -Object $snapshotResult -Name 'QueryStatus')
        if ([string]::IsNullOrWhiteSpace($processQueryStatus)) { $processQueryStatus = 'available' }
        $processQuerySource = [string](Get-OptionalObjectProperty -Object $snapshotResult -Name 'ProcessQuerySource')
        if ([string]::IsNullOrWhiteSpace($processQuerySource)) { $processQuerySource = 'cim' }
        $rawProcessQueryError = [string](Get-OptionalObjectProperty -Object $snapshotResult -Name 'RawQueryError')
        $parentProcessAvailabilityValue = Get-OptionalObjectProperty -Object $snapshotResult -Name 'ParentProcessIdsAvailable'
        $parentProcessIdsAvailable = if ($null -eq $parentProcessAvailabilityValue) { $true } else { [bool]$parentProcessAvailabilityValue }
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
                            ParentTreeStatus = if ($parentProcessIdsAvailable) { 'confirmed' } else { 'unconfirmed' }
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
                                ParentTreeStatus = if ($parentProcessIdsAvailable) { 'confirmed' } else { 'unconfirmed' }
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
                            ProcessQuerySource = $processQuerySource
                            ParentTreeStatus = if ($parentProcessIdsAvailable) { 'confirmed' } else { 'unconfirmed' }
                            StatusMessage    = 'PID 紀錄與目前程序身分不一致，視為 PID 重用；不阻擋後續派工，也不列入終止對象。'
                        })
                    }
                }
                elseif ($processQueryStatus -eq 'unavailable') {
                    $dispatchProperty = $record.PSObject.Properties['dispatch-slug']
                    $unconfirmedRecords.Add([pscustomobject]@{
                            Path = $recordFile.FullName
                            RootPid = $rootPid
                            DispatchSlug = if ($null -ne $dispatchProperty) { [string]$dispatchProperty.Value } else { '' }
                            IdentityStatus = 'process-query-unavailable'
                            MissingFields = @('ProcessId', 'ProcessName', 'StartTime')
                            FailureFields = @('Win32_Process', 'System.Diagnostics.Process')
                            TerminationScope = 'none'
                            ProcessQuerySource = $processQuerySource
                            ParentTreeStatus = 'unconfirmed'
                            RawQueryError = $rawProcessQueryError
                            StatusMessage = '程序查詢遭拒或失敗；狀態未知，不得判定程序已結束。'
                        })
                }
                else {
                $dispatchProperty = $record.PSObject.Properties['dispatch-slug']
                    $rootAbsentStatus = if ($parentProcessIdsAvailable) { 'root-process-absent' } else { 'parent-process-info-unavailable' }
                    $parentTreeStatus = if ($parentProcessIdsAvailable) { 'not-applicable' } else { 'unconfirmed' }
                    $statusMessage = if ($parentProcessIdsAvailable) {
                        '記錄的根程序已不存在，視為該次派遣已結束，未阻塞派工且未列入終止對象。'
                    }
                    else {
                        '備援快照缺少父程序資訊，無法確認記錄的根程序已結束；阻擋准入與清理。'
                    }
                    $unconfirmedRecords.Add([pscustomobject]@{
                        Path             = $recordFile.FullName
                        RootPid          = $rootPid
                        DispatchSlug     = if ($null -ne $dispatchProperty) { [string]$dispatchProperty.Value } else { '' }
                        IdentityStatus   = $rootAbsentStatus
                        MissingFields    = if ($parentProcessIdsAvailable) { @() } else { @('ParentProcessId') }
                        FailureFields    = @()
                        TerminationScope = 'none'
                        ProcessQuerySource = $processQuerySource
                        ParentTreeStatus = $parentTreeStatus
                        RawQueryError    = $rawProcessQueryError
                        StatusMessage    = $statusMessage
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
    $readonlyCount = @($activeArray | Where-Object { $_.WriteMode -eq 'readonly' }).Count
    $writeCount = @($activeArray | Where-Object { $_.WriteMode -eq 'write' }).Count
    $blocked = $false
    $reason = ''
    if ((Test-IsWindowsPlatform) -and $records.Count -gt 0 -and $processQueryStatus -eq 'unavailable') {
        $blocked = $true
        $reason = '程序查詢來源皆不可用，無法確認既有派遣是否仍在執行。'
    }
    elseif ((Test-IsWindowsPlatform) -and @($unconfirmedRecords.ToArray() | Where-Object { [string]$_.ParentTreeStatus -eq 'unconfirmed' }).Count -gt 0) {
        $blocked = $true
        $reason = '.NET 備援未提供父程序資訊，無法確認既有程序樹狀態。'
    }
    $callerIdentityVariable = Get-Variable -Name 'CallerSessionIdentity' -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $callerIdentityVariable -or $null -eq $callerIdentityVariable.Value) {
        $writeConflict = $writeCount -gt 0
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
    }

    return [ordered]@{
        Checked         = $true
        Blocked         = $blocked
        Reason          = $reason
        ActiveCount     = $active.Count
        ActiveRecords   = $activeArray
        ReadonlyCount   = $readonlyCount
        WriteCount      = $writeCount
        UnconfirmedProcesses = @($unconfirmedProcesses)
        UnconfirmedRecords = @($unconfirmedRecords.ToArray())
        ProcessQueryStatus = $processQueryStatus
        ProcessQuerySource = $processQuerySource
        RawProcessQueryError = $rawProcessQueryError
        ParentProcessIdsAvailable = $parentProcessIdsAvailable
        IdentityRule    = 'Windows 以 root-process-name、root-started-at-utc 與 Win32_Process 比對；Unix 依記錄的 process group 與根程序核對。'
    }
}

function Get-BlockingDispatchPidRecords {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$PidCheckResult,

        [Parameter(Mandatory)]
        [string]$DispatchSlug
    )

    $blockingRecords = New-Object System.Collections.Generic.List[object]
    if ($null -eq $PidCheckResult) {
        return @()
    }

    $activeRecords = Get-DispatchJsonProperty -Object $PidCheckResult -Name 'ActiveRecords'
    foreach ($record in @($activeRecords)) {
        if ([string](Get-DispatchJsonProperty -Object $record -Name 'DispatchSlug') -ne $DispatchSlug) {
            continue
        }
        $recordPath = [string](Get-DispatchJsonProperty -Object $record -Name 'Path')
        $blockingRecords.Add([pscustomobject]@{
                Path           = if ([string]::IsNullOrWhiteSpace($recordPath)) { '<unknown-record>' } else { $recordPath }
                IdentityStatus = 'confirmed'
            })
    }

    $unconfirmedRecords = Get-DispatchJsonProperty -Object $PidCheckResult -Name 'UnconfirmedRecords'
    foreach ($record in @($unconfirmedRecords)) {
        if ([string](Get-DispatchJsonProperty -Object $record -Name 'DispatchSlug') -ne $DispatchSlug) {
            continue
        }
        $identityStatus = [string](Get-DispatchJsonProperty -Object $record -Name 'IdentityStatus')
        $parentTreeStatus = [string](Get-DispatchJsonProperty -Object $record -Name 'ParentTreeStatus')
        if ($identityStatus -in @('root-process-absent', 'record-identity-mismatch') -and $parentTreeStatus -ne 'unconfirmed') {
            continue
        }
        $recordPath = [string](Get-DispatchJsonProperty -Object $record -Name 'Path')
        $blockingRecords.Add([pscustomobject]@{
                Path           = if ([string]::IsNullOrWhiteSpace($recordPath)) { '<unknown-record>' } else { $recordPath }
                IdentityStatus = if ([string]::IsNullOrWhiteSpace($identityStatus)) { 'unknown' } else { $identityStatus }
            })
    }

    return @($blockingRecords.ToArray())
}

function New-DispatchPidIdentityBlockedMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [object[]]$Records
    )

    $recordEvidence = New-Object System.Collections.Generic.List[string]
    foreach ($record in $Records) {
        $recordPath = [string](Get-DispatchJsonProperty -Object $record -Name 'Path')
        $identityStatus = [string](Get-DispatchJsonProperty -Object $record -Name 'IdentityStatus')
        if ([string]::IsNullOrWhiteSpace($recordPath)) { $recordPath = '<unknown-record>' }
        if ([string]::IsNullOrWhiteSpace($identityStatus)) { $identityStatus = 'unknown' }
        $recordEvidence.Add(('record={0}; state={1}' -f $recordPath, $identityStatus))
    }

    return ('ProcessIdentityBlocked：dispatch_slug={0}; {1}' -f $DispatchSlug, ($recordEvidence -join '; '))
}
