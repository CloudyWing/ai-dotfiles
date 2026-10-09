#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('P1', 'H1', 'H3', 'H4', 'Q1', 'Q2', 'Q3', 'Q4', 'Q5', 'R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'All')]
    [string]$Unit = 'All',

    [string]$FixtureBaseRootPath = 'C:\tmp'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
foreach ($module in @('common-runtime', 'git-baseline', 'dispatch-scope', 'dispatch-evidence', 'quota-observation', 'advisor-evidence', 'process-identity', 'reviewer-contract', 'run-recovery', 'prepare-stage', 'dispatch-lifecycle', 'start-lifecycle', 'inspect-lifecycle', 'collect-contract', 'cleanup', 'Invoke-DispatchConcurrency')) {
    . (Join-Path $scriptsRoot ('dispatch\' + $module + '.ps1'))
}

function Assert-P1B3 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-P1B3FixtureName {
    [CmdletBinding()]
    param([ValidatePattern('^[a-z][a-z0-9]{0,7}$')][string]$Code = 'f')
    return ($Code + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}

function Get-P1B3FixturePathPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FixtureRoot, [string]$DispatchSlug = 'q', [string]$LineSlug = 'a')
    $history = Join-Path $FixtureRoot ('.local\ai-sessions\worktrees\' + $DispatchSlug + '\.local\ai-sessions\history\' + $LineSlug)
    $deepest = Join-Path $history ('interruption-checkpoint-' + $DispatchSlug + '-' + [guid]::Empty.ToString('D') + '.json')
    if ($deepest.Length -gt 240) { throw ('Expected deepest path length: {0} characters; limit: 240; fixture root: {1}.' -f $deepest.Length, $FixtureRoot) }
    return [pscustomobject]@{ FixtureRoot = $FixtureRoot; LongestPath = $deepest; EstimatedPathLength = $deepest.Length }
}

function Invoke-P1 {
    if (-not (Test-IsWindowsPlatform)) {
        throw 'P1 process-query fallback cases require Windows.'
    }

    $savedDotNetSnapshots = (Get-Command Get-DotNetWindowsProcessSnapshots -CommandType Function).ScriptBlock
    $savedCimFunction = Get-Command Get-CimInstance -CommandType Function -ErrorAction SilentlyContinue
    $script:P1FallbackCalls = 0
    $script:P1CimException = $null
    Set-Item -Path Function:Get-DotNetWindowsProcessSnapshots -Value {
        param([string]$CimError)
        $script:P1FallbackCalls++
        return [pscustomobject]@{
            ById = @{}
            UnconfirmedProcesses = @()
            QueryStatus = 'available'
            ProcessQuerySource = 'dotnet'
            RawQueryError = $CimError
            ParentProcessIdsAvailable = $false
        }
    }
    Set-Item -Path Function:Get-CimInstance -Value { throw $script:P1CimException }

    try {
        $script:P1CimException = [System.UnauthorizedAccessException]::new('access denied fixture')
        $accessDenied = Get-WindowsProcessSnapshots
        Assert-P1B3 ($accessDenied.QueryStatus -ceq 'available' -and $script:P1FallbackCalls -eq 1 -and $accessDenied.RawQueryError.Contains('HRESULT=0x80070005')) 'UnauthorizedAccessException did not use the .NET fallback or preserve its HRESULT.'

        $script:P1CimException = [System.TimeoutException]::new('timeout fixture')
        $timeout = Get-WindowsProcessSnapshots
        Assert-P1B3 ($timeout.QueryStatus -ceq 'available' -and $script:P1FallbackCalls -eq 2) 'A process-query timeout did not use the .NET fallback.'

        $script:P1CimException = [System.Runtime.InteropServices.COMException]::new('HRESULT fallback fixture', -2147217405)
        $hresultAccessDenied = Get-WindowsProcessSnapshots
        Assert-P1B3 ($hresultAccessDenied.QueryStatus -ceq 'available' -and $script:P1FallbackCalls -eq 3 -and $hresultAccessDenied.RawQueryError.Contains('HRESULT=0x80041003')) 'The 0x80041003 HRESULT did not use the .NET fallback or preserve its error code.'

        $script:P1CimException = [System.InvalidOperationException]::new('InvalidNamespace fixture')
        $invalidNamespace = Get-WindowsProcessSnapshots
        Assert-P1B3 ($invalidNamespace.QueryStatus -ceq 'unavailable' -and $script:P1FallbackCalls -eq 3 -and $invalidNamespace.RawQueryError.Contains('InvalidNamespace fixture')) 'InvalidNamespace used the .NET fallback or lost its original error.'

        $script:P1CimException = [System.Exception]::new('access denied text without a refusal code')
        $textOnlyFailure = Get-WindowsProcessSnapshots
        Assert-P1B3 ($textOnlyFailure.QueryStatus -ceq 'unavailable' -and $script:P1FallbackCalls -eq 3) 'An error message alone caused fallback without an eligible exception type or HRESULT.'
    }
    finally {
        Set-Item -Path Function:Get-DotNetWindowsProcessSnapshots -Value $savedDotNetSnapshots
        Remove-Variable -Scope Script -Name P1CimException -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name P1FallbackCalls -ErrorAction SilentlyContinue
        if ($null -ne $savedCimFunction) {
            Set-Item -Path Function:Get-CimInstance -Value $savedCimFunction.ScriptBlock
        }
        else {
            Remove-Item -Path Function:Get-CimInstance -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-H1 {
    if (-not (Test-IsWindowsPlatform)) {
        throw 'H1 fallback cases require Windows.'
    }

    $fixtureBaseRoot = [IO.Path]::GetFullPath($FixtureBaseRootPath)
    $fixtureRoot = Join-Path $fixtureBaseRoot (New-P1B3FixtureName -Code 'h1')
    $null = Get-P1B3FixturePathPlan -FixtureRoot $fixtureRoot -DispatchSlug 'h1-current' -LineSlug 'h1'
    if (-not (Test-PathWithinRoot -Path $fixtureRoot -Root $fixtureBaseRoot)) {
        throw 'H1 fixture path escaped FixtureBaseRootPath.'
    }
    $null = [IO.Directory]::CreateDirectory($fixtureRoot)
    $savedDotNetSnapshots = (Get-Command Get-DotNetWindowsProcessSnapshots -CommandType Function).ScriptBlock
    $savedWindowsSnapshots = (Get-Command Get-WindowsProcessSnapshots -CommandType Function).ScriptBlock
    $savedCimFunction = Get-Command Get-CimInstance -CommandType Function -ErrorAction SilentlyContinue
    $currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
    try {
        Import-Module CimCmdlets -ErrorAction Stop

        $nativeErrorCodeCases = @(
            [pscustomobject]@{
                Name = 'AccessDenied'
                Value = [Microsoft.Management.Infrastructure.NativeErrorCode]::AccessDenied
                Expected = $true
            }
            [pscustomobject]@{
                Name = 'Failed'
                Value = [Microsoft.Management.Infrastructure.NativeErrorCode]::Failed
                Expected = $false
            }
            [pscustomobject]@{
                Name = 'InvalidOperationTimeout'
                Value = [Microsoft.Management.Infrastructure.NativeErrorCode]::InvalidOperationTimeout
                Expected = $false
            }
        )
        foreach ($nativeErrorCodeCase in $nativeErrorCodeCases) {
            $nativeErrorCodeEligible = Test-CimNativeErrorCodeFallbackEligible -NativeErrorCode ([int]$nativeErrorCodeCase.Value)
            Assert-P1B3 ($nativeErrorCodeEligible -eq $nativeErrorCodeCase.Expected) ('NativeErrorCode.{0} fallback eligibility was {1}; expected {2}.' -f $nativeErrorCodeCase.Name, $nativeErrorCodeEligible, $nativeErrorCodeCase.Expected)
        }

        $hresultCases = @(
            [pscustomobject]@{ Code = '80070005'; Expected = $true }
            [pscustomobject]@{ Code = '80041003'; Expected = $true }
            [pscustomobject]@{ Code = '80041069'; Expected = $true }
            [pscustomobject]@{ Code = '80043001'; Expected = $true }
            [pscustomobject]@{ Code = '800705B4'; Expected = $true }
            [pscustomobject]@{ Code = '8004106F'; Expected = $false }
            [pscustomobject]@{ Code = '8004100E'; Expected = $false }
        )
        foreach ($hresultCase in $hresultCases) {
            $hresultValue = [Convert]::ToUInt32($hresultCase.Code, 16)
            $hresult = [BitConverter]::ToInt32([BitConverter]::GetBytes($hresultValue), 0)
            $hresultException = [System.Runtime.InteropServices.COMException]::new(('HRESULT 0x' + $hresultCase.Code), $hresult)
            $hresultEligible = Test-WindowsProcessQueryFallbackEligible -Exception $hresultException
            Assert-P1B3 ($hresultEligible -eq $hresultCase.Expected) ('HRESULT 0x{0} fallback eligibility was {1}; expected {2}.' -f $hresultCase.Code, $hresultEligible, $hresultCase.Expected)
        }

        $unauthorizedAccessException = [System.UnauthorizedAccessException]::new('access denied fixture')
        Assert-P1B3 (Test-WindowsProcessQueryFallbackEligible -Exception $unauthorizedAccessException) 'UnauthorizedAccessException was not eligible for the .NET fallback.'

        $timeoutException = [System.TimeoutException]::new('timeout fixture')
        Assert-P1B3 (Test-WindowsProcessQueryFallbackEligible -Exception $timeoutException) 'TimeoutException was not eligible for the .NET fallback.'

        $invalidOperationException = [System.InvalidOperationException]::new('generic invalid operation fixture')
        Assert-P1B3 (-not (Test-WindowsProcessQueryFallbackEligible -Exception $invalidOperationException)) 'InvalidOperationException was incorrectly eligible for the .NET fallback.'

        $currentProcessId = $currentProcess.Id
        $currentProcessName = $currentProcess.ProcessName
        $currentStartTime = $currentProcess.StartTime.ToUniversalTime()
        function Get-CimInstance {
            throw [UnauthorizedAccessException]::new('Win32_Process access denied fixture')
        }

        $fallback = Get-WindowsProcessSnapshots
        Assert-P1B3 ($fallback.QueryStatus -ceq 'available') 'CIM refusal did not fall back to a queryable .NET process snapshot.'
        Assert-P1B3 ($fallback.ProcessQuerySource -ceq 'dotnet') 'Fallback source was not recorded as dotnet.'
        Assert-P1B3 ($fallback.RawQueryError -match 'Win32_Process access denied fixture') 'Raw CIM error was not preserved.'
        Assert-P1B3 ($fallback.ById.ContainsKey($currentProcessId)) 'The current process was missing from the .NET fallback.'
        $snapshot = $fallback.ById[$currentProcessId]
        Assert-P1B3 ($snapshot.IdentityStatus -ceq 'confirmed' -and $snapshot.ProcessName -ceq $currentProcessName) 'The current process identity was not confirmed by PID and name.'
        Assert-P1B3 ($snapshot.CreationUtc -is [datetime] -and [math]::Abs(($snapshot.CreationUtc.ToUniversalTime() - $currentStartTime).TotalSeconds) -le 1) 'The .NET start time did not match within the existing one-second tolerance.'
        Assert-P1B3 (-not $snapshot.ParentProcessIdAvailable -and $snapshot.ParentIdentityStatus -ceq 'unconfirmed') 'The .NET fallback incorrectly confirmed parent-process data.'

        $record = [pscustomobject]@{
            'root-pid' = [string]$currentProcessId
            'root-process-name' = $currentProcessName
            'root-started-at-utc' = $currentStartTime.ToString('o')
            'identity-status' = 'confirmed'
            'identity-verified' = 'true'
        }
        Assert-P1B3 (Test-RecordedProcessIdentity -Record $record -Snapshot $snapshot) 'A matching PID/name/start-time identity did not pass.'
        $reusedRecord = [pscustomobject]@{
            'root-pid' = [string]$currentProcessId
            'root-process-name' = $currentProcessName
            'root-started-at-utc' = $currentStartTime.AddSeconds(2).ToString('o')
            'identity-status' = 'confirmed'
            'identity-verified' = 'true'
        }
        Assert-P1B3 (-not (Test-RecordedProcessIdentity -Record $reusedRecord -Snapshot $snapshot)) 'A reused PID with a different start time passed identity verification.'

        $rootHistory = Join-Path $fixtureRoot '.local\ai-sessions\history'
        $null = [IO.Directory]::CreateDirectory($rootHistory)
        $pidRecordPath = Join-Path $rootHistory 'codex-pid-h1.txt'
        $pidRecord = @(
            ('pid=' + $currentProcessId)
            ('root-pid=' + $currentProcessId)
            ('root-process-name=' + $currentProcessName)
            ('root-started-at-utc=' + $currentStartTime.ToString('o'))
            'identity-status=confirmed'
            'identity-verified=true'
            'process-group-id=unknown'
            ('work-root=' + $fixtureRoot)
            'line-slug=h1'
            'dispatch-slug=h1-denied'
            'write-mode=readonly'
        ) -join [Environment]::NewLine
        [IO.File]::WriteAllText($pidRecordPath, $pidRecord + [Environment]::NewLine, (New-Object Text.UTF8Encoding($true)))

        Set-Item -Path Function:Get-DotNetWindowsProcessSnapshots -Value ([scriptblock]::Create("param([string]`$CimError) throw [UnauthorizedAccessException]::new('System.Diagnostics.Process access denied fixture')"))
        $unavailable = Get-WindowsProcessSnapshots
        Assert-P1B3 ($unavailable.QueryStatus -ceq 'unavailable' -and $unavailable.ProcessQuerySource -ceq 'unavailable') 'Both denied process-query sources did not return unavailable.'
        Assert-P1B3 ($unavailable.RawQueryError -match 'Win32_Process access denied fixture' -and $unavailable.RawQueryError -match 'System.Diagnostics.Process access denied fixture') 'The raw errors from both denied query sources were not preserved.'

        $script:CallerSessionIdentity = $null
        $pidCheck = Get-PidCheckResult -SourceRoot $fixtureRoot -LineSlug 'h1' -WriteMode readonly
        Assert-P1B3 ($pidCheck.ProcessQueryStatus -ceq 'unavailable' -and $pidCheck.Blocked) 'A denied process query did not block as unknown.'
        Assert-P1B3 (@($pidCheck.UnconfirmedRecords | Where-Object { $_.IdentityStatus -ceq 'process-query-unavailable' }).Count -eq 1) 'An unavailable query was not retained as an unconfirmed record.'
        Assert-P1B3 (@(Get-BlockingDispatchPidRecords -PidCheckResult $pidCheck -DispatchSlug 'h1-denied').Count -eq 1) 'A denied query was treated as an ended process.'

        $unconfirmedRootPath = Join-Path $rootHistory 'codex-pid-h1-root-unconfirmed.txt'
        $unconfirmedRecordPath = Join-Path $rootHistory 'codex-pid-h1-record-unconfirmed.txt'
        $unconfirmedRootRecord = @(
            ('pid=' + $currentProcessId)
            ('root-pid=' + $currentProcessId)
            ('root-process-name=' + $currentProcessName)
            ('root-started-at-utc=' + $currentStartTime.ToString('o'))
            'identity-status=unconfirmed'
            'identity-verified=true'
            'process-group-id=unknown'
            ('work-root=' + $fixtureRoot)
            'line-slug=h1'
            'dispatch-slug=h1-root-unconfirmed'
            'write-mode=readonly'
        ) -join [Environment]::NewLine
        $unconfirmedRecord = @(
            ('pid=' + ($currentProcessId + 100000))
            ('root-pid=' + ($currentProcessId + 100000))
            ('root-process-name=' + $currentProcessName)
            ('root-started-at-utc=' + $currentStartTime.ToString('o'))
            'identity-status=confirmed'
            'identity-verified=false'
            'process-group-id=unknown'
            ('work-root=' + $fixtureRoot)
            'line-slug=h1'
            'dispatch-slug=h1-record-unconfirmed'
            'write-mode=readonly'
        ) -join [Environment]::NewLine
        [IO.File]::WriteAllText($unconfirmedRootPath, $unconfirmedRootRecord + [Environment]::NewLine, (New-Object Text.UTF8Encoding($true)))
        [IO.File]::WriteAllText($unconfirmedRecordPath, $unconfirmedRecord + [Environment]::NewLine, (New-Object Text.UTF8Encoding($true)))

        $snapshotById = @{}
        $snapshotById[$currentProcessId] = [pscustomobject]@{
            ProcessId = $currentProcessId
            ProcessName = $currentProcessName
            CreationUtc = $currentStartTime
            IdentityStatus = 'identity-unconfirmed'
            IdentityMissingFields = @()
            IdentityFailureFields = @('ProcessName')
            ParentProcessIdAvailable = $false
            ParentIdentityStatus = 'unconfirmed'
        }
        $recordSnapshotProcessId = $currentProcessId + 100000
        $snapshotById[$recordSnapshotProcessId] = [pscustomobject]@{
            ProcessId = $recordSnapshotProcessId
            ProcessName = $currentProcessName
            CreationUtc = $currentStartTime
            IdentityStatus = 'confirmed'
            IdentityMissingFields = @()
            IdentityFailureFields = @()
            ParentProcessIdAvailable = $false
            ParentIdentityStatus = 'unconfirmed'
        }
        $script:H1MockProcessSnapshotResult = [pscustomobject]@{
            ById = $snapshotById
            UnconfirmedProcesses = @()
            QueryStatus = 'available'
            ProcessQuerySource = 'dotnet'
            RawQueryError = 'Win32_Process access denied fixture'
            ParentProcessIdsAvailable = $false
        }
        Set-Item -Path Function:Get-WindowsProcessSnapshots -Value {
            param([switch]$FailOnError)
            return $script:H1MockProcessSnapshotResult
        }
        $Error.Clear()
        $parentUnconfirmedCheck = Get-PidCheckResult -SourceRoot $fixtureRoot -LineSlug 'h1' -WriteMode readonly
        $parentUnconfirmedRecords = @($parentUnconfirmedCheck.UnconfirmedRecords | Where-Object { $_.DispatchSlug -in @('h1-root-unconfirmed', 'h1-record-unconfirmed') })
        Assert-P1B3 ($parentUnconfirmedCheck.Blocked) 'An unknown parent-process tree did not block the admission decision.'
        Assert-P1B3 ($parentUnconfirmedRecords.Count -eq 2 -and @($parentUnconfirmedRecords | Where-Object { $_.ParentTreeStatus -cne 'unconfirmed' }).Count -eq 0) 'Unconfirmed PID records did not retain ParentTreeStatus.'
        Assert-P1B3 ($Error.Count -eq 0) 'PID identity evaluation emitted a property lookup error for an unconfirmed record.'
        Set-Item -Path Function:Get-WindowsProcessSnapshots -Value $savedWindowsSnapshots
        Remove-Variable -Scope Script -Name H1MockProcessSnapshotResult -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $unconfirmedRootPath, $unconfirmedRecordPath -Force

        $absentProcessId = 2147483000
        $absentPidRecord = @(
            ('pid=' + $absentProcessId)
            ('root-pid=' + $absentProcessId)
            ('root-process-name=' + $currentProcessName)
            ('root-started-at-utc=' + $currentStartTime.ToString('o'))
            'identity-status=confirmed'
            'identity-verified=true'
            'process-group-id=unknown'
            ('work-root=' + $fixtureRoot)
            'line-slug=h1'
            'dispatch-slug=h1-absent'
            'write-mode=readonly'
        ) -join [Environment]::NewLine
        [IO.File]::WriteAllText($pidRecordPath, $absentPidRecord + [Environment]::NewLine, (New-Object Text.UTF8Encoding($true)))
        Set-Item -Path Function:Get-DotNetWindowsProcessSnapshots -Value ([scriptblock]::Create("param([string]`$CimError) return [pscustomobject]@{ ById = @{}; UnconfirmedProcesses = @(); QueryStatus = 'available'; ProcessQuerySource = 'dotnet'; RawQueryError = `$CimError; ParentProcessIdsAvailable = `$false }"))
        $absentCheck = Get-PidCheckResult -SourceRoot $fixtureRoot -LineSlug 'h1' -WriteMode readonly
        $absentRecord = @($absentCheck.UnconfirmedRecords | Where-Object { $_.DispatchSlug -ceq 'h1-absent' })
        $absentBlockers = @(Get-BlockingDispatchPidRecords -PidCheckResult $absentCheck -DispatchSlug 'h1-absent')
        Assert-P1B3 ($absentCheck.ProcessQueryStatus -ceq 'available' -and $absentCheck.ProcessQuerySource -ceq 'dotnet' -and $absentCheck.Blocked) 'A fallback snapshot without parent-process data did not block an absent root PID.'
        Assert-P1B3 ($absentRecord.Count -eq 1 -and $absentRecord[0].IdentityStatus -ceq 'parent-process-info-unavailable' -and $absentRecord[0].ParentTreeStatus -ceq 'unconfirmed') 'A fallback snapshot without parent-process data was reported as root-process-absent or not-applicable.'
        Assert-P1B3 ($absentBlockers.Count -eq 1) 'The unconfirmed absent root PID was omitted from the blocking record set.'

        $startAdmission = Get-PidCheckResult -SourceRoot $fixtureRoot -LineSlug 'h1' -WriteMode readonly
        $startBlockingRecords = @(Get-BlockingDispatchPidRecords -PidCheckResult $startAdmission -DispatchSlug 'h1-absent')
        $startText = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'dispatch\start-lifecycle.ps1'))
        Assert-P1B3 ($startAdmission.Blocked -and $startBlockingRecords.Count -eq 1 -and $startText.Contains('$startProcessResult = Get-PidCheckResult') -and $startText.Contains("if (`$processGate.status -ne 'stopped')")) 'Start same-line PID admission did not block the unconfirmed root process.'

        $cleanupBlocked = $false
        try {
            Assert-CleanupStopped -SourceRoot $fixtureRoot -DispatchSlug 'h1-absent' -LineSlug 'h1' -Owner $null
        }
        catch {
            $cleanupBlocked = $_.Exception.Message.Contains('ProcessIdentityBlocked')
        }
        Assert-P1B3 $cleanupBlocked 'Cleanup Assert-CleanupStopped accepted an absent root PID from a fallback snapshot without parent-process data.'

        $savedRunRecordList = (Get-Command Get-DispatchRunRecordList -CommandType Function).ScriptBlock
        $savedRunClassification = (Get-Command Get-DispatchRunRecordStartClassification -CommandType Function).ScriptBlock
        $script:H1MockRunRecord = [pscustomobject]@{
            created_at_utc = [DateTime]::UtcNow.ToString('o')
            run_id = [guid]::NewGuid().ToString('D')
            launch_state = 'launch-failed'
        }
        Set-Item -Path Function:Get-DispatchRunRecordList -Value {
            param([string]$SourceRoot, [string]$ExecutionRoot, [string]$LineSlug, [string]$DispatchSlug)
            return @($script:H1MockRunRecord)
        }
        Set-Item -Path Function:Get-DispatchRunRecordStartClassification -Value {
            param([psobject]$Record)
            return [pscustomobject]@{ classification = 'unstarted-sandbox' }
        }
        try {
            $recoveryBlocked = $false
            try {
                $null = Resolve-LatestColdStartFailure -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug 'h1' -DispatchSlug 'h1-absent'
            }
            catch {
                $recoveryBlocked = $_.Exception.Message.Contains('ProcessIdentityBlocked')
            }
            Assert-P1B3 $recoveryBlocked 'Recovery accepted a fallback snapshot with missing parent-process data and an absent root PID.'
        }
        finally {
            Set-Item -Path Function:Get-DispatchRunRecordList -Value $savedRunRecordList
            Set-Item -Path Function:Get-DispatchRunRecordStartClassification -Value $savedRunClassification
            Remove-Variable -Scope Script -Name H1MockRunRecord -ErrorAction SilentlyContinue
        }

        Set-Item -Path Function:Get-CimInstance -Value { return @() }
        $normalCimAbsent = Get-PidCheckResult -SourceRoot $fixtureRoot -LineSlug 'h1' -WriteMode readonly
        Assert-P1B3 ($normalCimAbsent.ProcessQueryStatus -ceq 'available' -and $normalCimAbsent.ProcessQuerySource -ceq 'cim' -and -not $normalCimAbsent.Blocked) 'A normal CIM snapshot with an absent root PID no longer preserves the root-process-absent behavior.'
        Assert-P1B3 (@($normalCimAbsent.UnconfirmedRecords | Where-Object { $_.DispatchSlug -ceq 'h1-absent' -and $_.IdentityStatus -ceq 'root-process-absent' -and $_.ParentTreeStatus -ceq 'not-applicable' }).Count -eq 1) 'A normal CIM snapshot did not retain root-process-absent with ParentTreeStatus=not-applicable.'
        Assert-P1B3 (@(Get-BlockingDispatchPidRecords -PidCheckResult $normalCimAbsent -DispatchSlug 'h1-absent').Count -eq 0) 'A root PID absent from a normal CIM snapshot remained in the blocking record set.'
        Set-Item -Path Function:Get-CimInstance -Value { throw [UnauthorizedAccessException]::new('Win32_Process access denied fixture') }

        $childSnapshot = [pscustomobject]@{
            ProcessId = $currentProcessId + 100000
            ParentProcessId = $currentProcessId
            ProcessName = 'fixture-child'
            CreationUtc = $currentStartTime
            IdentityStatus = 'confirmed'
            ParentProcessIdAvailable = $false
        }
        $tree = @{}
        $tree[$currentProcessId] = $snapshot
        $tree[$childSnapshot.ProcessId] = $childSnapshot
        Assert-P1B3 (@(Get-DescendantProcessIds -RootProcessId $currentProcessId -ProcessesById $tree -ConfirmedOnly).Count -eq 0) 'A parent-dependent descendant result passed without confirmed parent data.'
        $snapshot | Add-Member -MemberType NoteProperty -Name IdentityVerified -Value $true -Force
        $cleanup = Stop-VerifiedProcessTree -Snapshot $snapshot
        Assert-P1B3 (-not $cleanup.TerminationExecuted -and $cleanup.CleanupStatus -ceq 'unverified-processes-remain') 'Tree cleanup claimed success when the fallback could not verify parent identities.'
    }
    finally {
        Set-Item -Path Function:Get-DotNetWindowsProcessSnapshots -Value $savedDotNetSnapshots
        Set-Item -Path Function:Get-WindowsProcessSnapshots -Value $savedWindowsSnapshots
        Remove-Variable -Scope Script -Name H1MockProcessSnapshotResult -ErrorAction SilentlyContinue
        if ($null -ne $savedCimFunction) {
            Set-Item -Path Function:Get-CimInstance -Value $savedCimFunction.ScriptBlock
        }
        else {
            Remove-Item -Path Function:Get-CimInstance -ErrorAction SilentlyContinue
        }
        $currentProcess.Dispose()
        if ([IO.Directory]::Exists($fixtureRoot)) {
            if (-not (Test-PathWithinRoot -Path $fixtureRoot -Root $fixtureBaseRoot)) {
                throw 'H1 fixture cleanup path escaped FixtureBaseRootPath.'
            }
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
        }
    }
}

function Invoke-H3 {
    $fixtureBaseRoot = [IO.Path]::GetFullPath($FixtureBaseRootPath)
    $fixtureRoot = Join-Path $fixtureBaseRoot (New-P1B3FixtureName -Code 'h3')
    $null = Get-P1B3FixturePathPlan -FixtureRoot $fixtureRoot -DispatchSlug 'h3-readonly' -LineSlug 'h3-line'
    if (-not (Test-PathWithinRoot -Path $fixtureRoot -Root $fixtureBaseRoot)) {
        throw 'H3 fixture path escaped FixtureBaseRootPath.'
    }
    $null = [IO.Directory]::CreateDirectory($fixtureRoot)
    try {
        $runId = [guid]::NewGuid().ToString('D')
        $selectedUnits = @('Phase 1', 'Phase 2')
        $checkpointPath = Get-DispatchInterruptionCheckpointPath -SourceRoot $fixtureRoot -LineSlug 'h3-line' -DispatchSlug 'h3-readonly' -RunId $runId
        Assert-P1B3 (-not [IO.File]::Exists($checkpointPath)) 'H3 fixture unexpectedly has a writable interruption checkpoint.'

        $evidencePath = Join-Path $fixtureRoot 'evidence.md'
        [IO.File]::WriteAllText($evidencePath, "confirmed fixture evidence`r`n", (New-Object Text.UTF8Encoding($false)))
        $sourcePaths = @(
            (Join-Path $fixtureRoot 'scope-plan.json')
            (Join-Path $fixtureRoot 'run-record.json')
            (Join-Path $fixtureRoot '.local\ai-sessions\history\codex-exec-h3.jsonl')
        )
        $initialCheckpoint = New-DispatchInterruptionCheckpointDocument -LineSlug 'h3-line' -DispatchSlug 'h3-readonly' -RunId $runId -SelectedUnits $selectedUnits -ScopePlanPath $sourcePaths[0] -RunRecordPath $sourcePaths[1] -EventStreamPath $sourcePaths[2]
        $null = Write-DispatchAtomicJsonDocument -Path $checkpointPath -Document $initialCheckpoint -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -TargetPath @()
        $initial = Get-DispatchInterruptionCheckpoint -Path $checkpointPath -SourceRoot $fixtureRoot -LineSlug 'h3-line' -DispatchSlug 'h3-readonly' -RunId $runId -SelectedUnits $selectedUnits -SourcePath $sourcePaths
        Assert-P1B3 ($initial.status -ceq 'available' -and @($initial.confirmed_units).Count -eq 0 -and (Compare-DispatchStringArrays -Left @($initial.incomplete_units) -Right $selectedUnits)) 'H3 initial checkpoint did not contain all selected units as incomplete.'

        $completedMessage = @(
            '已確認結論：Phase 1 與 Phase 2 的唯讀中斷保全交付已由結案訊息補足。'
            '未完成單位：無'
            ('證據位置：' + $evidencePath + ':1')
            'requiredIdentifier: design.md'
            'dispatchSlug: h3-readonly'
            'lineSlug: h3-line'
        ) -join [Environment]::NewLine
        $completed = Get-DispatchInterruptionCheckpointWithMessageFallback -Path $checkpointPath -SourceRoot $fixtureRoot -LineSlug 'h3-line' -DispatchSlug 'h3-readonly' -RunId $runId -SelectedUnits $selectedUnits -Message $completedMessage -SourcePath $sourcePaths
        Assert-P1B3 ($completed.status -ceq 'available' -and $completed.source -ceq 'agent-message') ('Inspect fallback did not identify the final message as its source: ' + ($completed | ConvertTo-Json -Depth 10 -Compress))
        Assert-P1B3 (@($completed.confirmed_units).Count -eq 2 -and $completed.confirmed_units[0].unit -ceq 'Phase 1' -and $completed.confirmed_units[1].unit -ceq 'Phase 2') 'Inspect fallback did not recover every confirmed selected unit.'
        Assert-P1B3 (@($completed.incomplete_units).Count -eq 0) 'Inspect fallback did not recover the empty incomplete-unit list.'
        Assert-P1B3 ($completed.confirmed_units[0].evidence_locations[0] -ceq ($evidencePath + ':1')) 'Inspect fallback did not preserve the final-message evidence location.'

        $incompleteMessage = $completedMessage.Replace('未完成單位：無', '未完成單位：Phase 2')
        $incomplete = Get-DispatchInterruptionCheckpointWithMessageFallback -Path $checkpointPath -SourceRoot $fixtureRoot -LineSlug 'h3-line' -DispatchSlug 'h3-readonly' -RunId $runId -SelectedUnits $selectedUnits -Message $incompleteMessage -SourcePath $sourcePaths
        Assert-P1B3 (@($incomplete.confirmed_units).Count -eq 1 -and [string]$incomplete.confirmed_units[0].unit -ceq 'Phase 1' -and @($incomplete.incomplete_units).Count -eq 1 -and [string]$incomplete.incomplete_units[0] -ceq 'Phase 2') 'Inspect fallback did not split the confirmed and incomplete selected units.'

        $checkpointWithProgress = New-DispatchInterruptionCheckpointDocument -LineSlug 'h3-line' -DispatchSlug 'h3-readonly' -RunId $runId -SelectedUnits $selectedUnits -ScopePlanPath $sourcePaths[0] -RunRecordPath $sourcePaths[1] -EventStreamPath $sourcePaths[2]
        $checkpointWithProgress.confirmed_units = @([ordered]@{
                unit = 'Phase 1'
                confirmed_result = 'Checkpoint 已確認 Phase 1。'
                evidence_locations = @($evidencePath + ':1')
            })
        $checkpointWithProgress.incomplete_units = @('Phase 2')
        $null = Write-DispatchAtomicJsonDocument -Path $checkpointPath -Document $checkpointWithProgress -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -TargetPath @()
        $authoritativeFile = Get-DispatchInterruptionCheckpointWithMessageFallback -Path $checkpointPath -SourceRoot $fixtureRoot -LineSlug 'h3-line' -DispatchSlug 'h3-readonly' -RunId $runId -SelectedUnits $selectedUnits -Message $completedMessage -SourcePath $sourcePaths
        Assert-P1B3 (@($authoritativeFile.confirmed_units).Count -eq 1 -and [string]$authoritativeFile.confirmed_units[0].unit -ceq 'Phase 1' -and (Compare-DispatchStringArrays -Left @($authoritativeFile.incomplete_units) -Right @('Phase 2'))) 'A checkpoint with confirmed units was overwritten by the final message.'

        $null = Write-DispatchAtomicJsonDocument -Path $checkpointPath -Document $initialCheckpoint -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -TargetPath @()
        $malformedMessage = @(
            '已確認結論：訊息格式測試。'
            '未完成單位：無'
        ) -join [Environment]::NewLine
        $malformedFallback = Get-DispatchInterruptionCheckpointWithMessageFallback -Path $checkpointPath -SourceRoot $fixtureRoot -LineSlug 'h3-line' -DispatchSlug 'h3-readonly' -RunId $runId -SelectedUnits $selectedUnits -Message $malformedMessage -SourcePath $sourcePaths
        Assert-P1B3 ($malformedFallback.status -ceq 'available' -and @($malformedFallback.confirmed_units).Count -eq 0 -and (Compare-DispatchStringArrays -Left @($malformedFallback.incomplete_units) -Right $selectedUnits) -and -not [string]::IsNullOrWhiteSpace([string]$malformedFallback.message_fallback_error)) 'A malformed final message changed the initial checkpoint contents.'

        Remove-Item -LiteralPath $checkpointPath -Force
        $unavailableFallback = Get-DispatchInterruptionCheckpointWithMessageFallback -Path $checkpointPath -SourceRoot $fixtureRoot -LineSlug 'h3-line' -DispatchSlug 'h3-readonly' -RunId $runId -SelectedUnits $selectedUnits -Message $completedMessage -SourcePath $sourcePaths
        Assert-P1B3 ($unavailableFallback.status -ceq 'available' -and $unavailableFallback.source -ceq 'agent-message' -and @($unavailableFallback.confirmed_units).Count -eq 2) 'A valid final message no longer fills an unavailable checkpoint.'

        $startText = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'dispatch\start-lifecycle.ps1'))
        $inspectText = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'dispatch\inspect-lifecycle.ps1'))
        Assert-P1B3 ($startText.Contains('中斷檢查點不可寫時，改以結案訊息三行交付，不得以此停止工作。')) 'Start prompt is missing the readonly checkpoint fallback directive.'
        Assert-P1B3 ($inspectText.Contains('Get-DispatchInterruptionCheckpointWithMessageFallback') -and $inspectText.Contains('interruptionCheckpointSource')) 'Inspect is not wired to return message fallback data.'
        $nonterminalBranch = [regex]::Match($inspectText, "(?s)if \(\`$lastEventType -notin @\('turn\.completed', 'turn\.failed'\)\) \{(?<branch>.*?)\n    if \(\[string\]::IsNullOrWhiteSpace\(\`$lastAgentMessage\)")
        Assert-P1B3 ($nonterminalBranch.Success -and $nonterminalBranch.Groups['branch'].Value.Contains('Get-DispatchInterruptionCheckpointWithMessageFallback') -and $nonterminalBranch.Groups['branch'].Value.Contains('-Message $lastAgentMessage')) 'Inspect nonterminal events do not pass their last agent message through the checkpoint fallback.'
    }
    finally {
        if ([IO.Directory]::Exists($fixtureRoot)) {
            if (-not (Test-PathWithinRoot -Path $fixtureRoot -Root $fixtureBaseRoot)) {
                throw 'H3 fixture cleanup path escaped FixtureBaseRootPath.'
            }
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
        }
    }
}

function Invoke-H4 {
    $fixtureBaseRoot = [IO.Path]::GetFullPath($FixtureBaseRootPath)
    $fixtureRoot = Join-Path $fixtureBaseRoot (New-P1B3FixtureName -Code 'h4')
    $null = Get-P1B3FixturePathPlan -FixtureRoot $fixtureRoot -LineSlug 'h4-line'
    if (-not (Test-PathWithinRoot -Path $fixtureRoot -Root $fixtureBaseRoot)) {
        throw 'H4 fixture path escaped FixtureBaseRootPath.'
    }
    $null = [IO.Directory]::CreateDirectory($fixtureRoot)
    $fixtures = New-Object 'System.Collections.Generic.List[object]'
    $newFixture = {
        param([string]$Name)

        $source = Join-Path $fixtureRoot (New-P1B3FixtureName)
        $lineSlug = 'h4-line'
        $dispatchSlug = New-P1B3FixtureName -Code 'h4'
        $null = Get-P1B3FixturePathPlan -FixtureRoot $source -DispatchSlug $dispatchSlug -LineSlug $lineSlug
        $dispatch = Join-Path $source ('.local\ai-sessions\worktrees\' + $dispatchSlug)
        $null = [IO.Directory]::CreateDirectory($source)
        [IO.File]::WriteAllText((Join-Path $source 'README.md'), 'h4 fixture', (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $source '.gitignore'), ".local/`r`n", (New-Object Text.UTF8Encoding($false)))
        $null = Invoke-GitCommand -WorkingDirectory $source -Arguments @('init')
        $null = Invoke-GitCommand -WorkingDirectory $source -Arguments @('add', 'README.md', '.gitignore')
        $null = Invoke-GitCommand -WorkingDirectory $source -Arguments @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'fixture')
        $null = Invoke-GitCommand -WorkingDirectory $source -Arguments @('worktree', 'add', '--detach', $dispatch, 'HEAD')

        $history = Join-Path $dispatch ('.local\ai-sessions\history\' + $lineSlug)
        $preflight = Join-Path $history ('preflight-result-' + $dispatchSlug + '.json')
        $preflightDocument = [ordered]@{
            sourceRoot = $source
            dispatchRoot = $dispatch
            executionRoot = $dispatch
            lineSlug = $lineSlug
            dispatchSlug = $dispatchSlug
            worktreeCreated = $true
        }
        $null = [IO.Directory]::CreateDirectory($history)
        [IO.File]::WriteAllText($preflight, ($preflightDocument | ConvertTo-Json -Depth 10) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        $manifestPath = Join-Path $source ('.local\ai-sessions\handoff\' + $lineSlug + '\line.json')
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $manifestPath))
        [IO.File]::WriteAllText($manifestPath, '{"schema":"ai-sessions.line.v1","line-slug":"h4-line"}' + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))

        $script:SourceRoot = $source
        $script:DispatchRoot = $dispatch
        $script:ExecutionRoot = $dispatch
        $script:LineSlug = $lineSlug
        $script:DispatchSlug = $dispatchSlug
        $script:PreflightResultPath = $preflight
        $script:RunRecordPath = ''
        $script:EvidencePath = @()
        $script:ReportPath = @()
        $script:FailureReceiptPath = ''
        $script:TargetPath = @()
        $script:CallerSessionIdentity = Get-DispatchCallerSessionIdentity -CliCallerSessionId 'h4-fixture' -CliCallerSessionIdProvided $true
        return [pscustomobject]@{ Source = $source; Dispatch = $dispatch; Preflight = $preflight; LineSlug = $lineSlug; Slug = $dispatchSlug }
    }

    try {
        $accepted = & $newFixture 'preflight-only'
        $fixtures.Add($accepted)
        Assert-P1B3 (Test-PathWithinRoot -Path $accepted.Preflight -Root (Join-Path $accepted.Dispatch ('.local\ai-sessions\history\' + $accepted.LineSlug))) 'H4 Preflight fixture is not in dispatch worktree same-line history.'
        $acceptedResult = Invoke-Cleanup -Confirm:$false
        Assert-P1B3 ($acceptedResult.worktree_removed -and -not [IO.Directory]::Exists($accepted.Dispatch)) 'A registered Preflight-only worktree without RunRecord was not cleaned through Cleanup.'

        foreach ($artifact in @('event', 'thread')) {
            $f = & $newFixture ('reject-' + $artifact)
            $fixtures.Add($f)
            $artifactPath = if ($artifact -ceq 'event') {
                Join-Path $f.Dispatch '.local\ai-sessions\history\codex-exec-h4-fixture.jsonl'
            }
            else {
                Join-Path $f.Dispatch ('.local\ai-sessions\history\codex-thread-' + $f.Slug + '.txt')
            }
            $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $artifactPath))
            [IO.File]::WriteAllText($artifactPath, 'artifact proves Start may have begun', (New-Object Text.UTF8Encoding($false)))
            $rejected = $false
            try { $null = Invoke-Cleanup -Confirm:$false }
            catch { $rejected = $_.Exception.Data['errorCode'] -ceq 'CleanupPreflightResultRequired' }
            $registration = Invoke-GitCommand -WorkingDirectory $f.Source -Arguments @('worktree', 'list', '--porcelain')
            Assert-P1B3 ($rejected -and [IO.File]::Exists((Join-Path $f.Dispatch 'README.md')) -and $registration.StdOut.Contains($f.Dispatch.Replace('\', '/'))) ('Preflight-only Cleanup accepted or deregistered a worktree containing ' + $artifact + ' evidence.')
            [IO.File]::Delete($artifactPath)
            $retryResult = Invoke-Cleanup -Confirm:$false
            Assert-P1B3 ($retryResult.worktree_removed) ('Preflight-only Cleanup could not retry after removing the fixture ' + $artifact + ' evidence.')
        }

        $boundary = & $newFixture 'boundary'
        $fixtures.Add($boundary)
        $outsideHistory = Join-Path (Join-Path $fixtureRoot 'outside-source-root') 'history'
        $outsidePreflight = Join-Path $outsideHistory ('preflight-result-' + $boundary.Slug + '.json')
        $null = [IO.Directory]::CreateDirectory($outsideHistory)
        $outsideDocument = [ordered]@{
            sourceRoot = $boundary.Source
            dispatchRoot = $boundary.Dispatch
            executionRoot = $boundary.Dispatch
            lineSlug = $boundary.LineSlug
            dispatchSlug = $boundary.Slug
            worktreeCreated = $true
        }
        [IO.File]::WriteAllText($outsidePreflight, ($outsideDocument | ConvertTo-Json -Depth 10) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        $script:PreflightResultPath = $outsidePreflight
        $boundaryRejected = $false
        try { $null = Invoke-Cleanup -Confirm:$false }
        catch { $boundaryRejected = $_.Exception.Message -match 'CleanupPreflightBoundary' }
        Assert-P1B3 ($boundaryRejected -and [IO.File]::Exists((Join-Path $boundary.Dispatch 'README.md'))) 'Cleanup accepted a Preflight result outside SourceRoot.'
        $script:PreflightResultPath = $boundary.Preflight
        Assert-P1B3 ((Invoke-Cleanup -Confirm:$false).worktree_removed) 'Cleanup did not accept the restored same-line Preflight result.'

        $owner = & $newFixture 'owner-mismatch'
        $fixtures.Add($owner)
        $lock = Open-DispatchAdmissionLock -SourceRoot $owner.Source
        try {
            $ledger = Read-DispatchAdmissionLedger -Lock $lock
            $ledger.Document.entries = @([pscustomobject]@{ line_slug = $owner.LineSlug; dispatch_slug = $owner.Slug; state = 'finished'; caller_session_fingerprint = ('a' * 64) })
            $null = Write-DispatchAdmissionLedger -Lock $lock -Ledger $ledger
        }
        finally { Close-DispatchAdmissionLock -Lock $lock }
        $ownerRejected = $false
        try { $null = Invoke-Cleanup -Confirm:$false }
        catch { $ownerRejected = $_.Exception.Message -match 'DispatchAdmissionOwnerMismatch' }
        Assert-P1B3 ($ownerRejected -and [IO.File]::Exists((Join-Path $owner.Dispatch 'README.md'))) 'A recorded different owner was allowed to clean a Preflight-only worktree.'
        $lock = Open-DispatchAdmissionLock -SourceRoot $owner.Source
        try {
            $ledger = Read-DispatchAdmissionLedger -Lock $lock
            $ledger.Document.entries = @()
            $null = Write-DispatchAdmissionLedger -Lock $lock -Ledger $ledger
        }
        finally { Close-DispatchAdmissionLock -Lock $lock }
        Assert-P1B3 ((Invoke-Cleanup -Confirm:$false).worktree_removed) 'Owner-mismatch fixture did not clean after restoring the unowned pre-start state.'
    }
    finally {
        foreach ($f in $fixtures) {
            if ([IO.Directory]::Exists($f.Dispatch)) {
                foreach ($artifact in @((Join-Path $f.Dispatch '.local\ai-sessions\history\codex-exec-h4-fixture.jsonl'), (Join-Path $f.Dispatch ('.local\ai-sessions\history\codex-thread-' + $f.Slug + '.txt')))) {
                    if ([IO.File]::Exists($artifact) -and (Test-PathWithinRoot -Path $artifact -Root $f.Dispatch)) { [IO.File]::Delete($artifact) }
                }
                $script:SourceRoot = $f.Source
                $script:DispatchRoot = $f.Dispatch
                $script:ExecutionRoot = $f.Dispatch
                $script:LineSlug = $f.LineSlug
                $script:DispatchSlug = $f.Slug
                $script:PreflightResultPath = $f.Preflight
                $script:RunRecordPath = ''
                $script:EvidencePath = @()
                $script:ReportPath = @()
                $script:FailureReceiptPath = ''
                $script:TargetPath = @()
                try { $null = Invoke-Cleanup -Confirm:$false } catch { }
            }
        }
        $remainingWorktrees = @($fixtures | Where-Object { [IO.Directory]::Exists($_.Dispatch) })
        if ($remainingWorktrees.Count -eq 0 -and [IO.Directory]::Exists($fixtureRoot)) {
            if (-not (Test-PathWithinRoot -Path ([IO.Path]::GetFullPath($fixtureRoot)) -Root $fixtureBaseRoot)) {
                throw 'H4 fixture cleanup path escaped FixtureBaseRootPath.'
            }
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
        }
        elseif ($remainingWorktrees.Count -gt 0) {
            throw ('H4 fixture cleanup left registered worktrees intact for inspection: ' + (($remainingWorktrees | ForEach-Object { $_.Dispatch }) -join '; '))
        }
    }
}

function Write-P2BText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    if ([IO.Path]::GetFullPath($Path).Length -gt 240) { throw ('Fixture path exceeds 240 characters: ' + $Path) }
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Invoke-P2BEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    $hostPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $startInfo = New-ProcessStartInfo -FileName $hostPath -Arguments (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $scriptsRoot 'Invoke-CodexDispatch.ps1')) + $Arguments) -WorkingDirectory $scriptsRoot -RedirectOutput
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        Assert-P1B3 ($null -ne $exitCode) 'P2-B child exit code is null.'
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        Write-Output ('COMMAND: ' + $hostPath + ' ' + ($startInfo.Arguments))
        Write-Output ('EXIT: ' + $exitCode)
        Write-Output ('STDOUT: ' + $stdout)
        Write-Output ('STDERR: ' + $stderr)
        return [pscustomobject]@{ ExitCode = $exitCode; Stdout = $stdout; Stderr = $stderr; Document = (ConvertFrom-DispatchJson -Content $stdout) }
    }
    finally { $process.Dispose() }
}

function New-P2BFixture {
    [CmdletBinding()]
    param([switch]$DirectWrite, [switch]$RequirementMapFixture, [switch]$Advisor)
    $fixtureBase = [IO.Path]::GetFullPath($FixtureBaseRootPath)
    $source = Join-Path $fixtureBase (New-P1B3FixtureName -Code 'p2b')
    $null = Get-P1B3FixturePathPlan -FixtureRoot $source
    Assert-P1B3 (Test-PathWithinRoot $source $fixtureBase) 'P2-B fixture escaped its base root.'
    $slug = 'q'
    $line = 'a'
    $dispatch = Join-Path $source '.local\ai-sessions\worktrees\q'
    $handoff = Join-Path $source '.local\ai-sessions\handoff\a'
    $history = Join-Path $source '.local\ai-sessions\history\a'
    $codexHome = Join-Path $source 'ch'
    $thread = [guid]::NewGuid().ToString('D')
    Write-P2BText (Join-Path $handoff 'line.json') '{"schema":"ai-sessions.line.v1","line-slug":"a"}'
    Write-P2BText (Join-Path $handoff 'requirement-summary.md') "# Fixture`r`n"
    if ($RequirementMapFixture) {
        Write-P2BText (Join-Path $handoff 'requirement-summary.md') "# Fixture`r`n`r`n## 程式面項目`r`n`r`n| # | 項目 | 內容 |`r`n| --- | --- | --- |`r`n| 1 | Fixture | Preserve original target |`r`n`r`n## 功能面項目`r`n`r`n| # | 項目 | 內容 |`r`n| --- | --- | --- |`r`n| 22 | Fixture | Checkpoint recovery |`r`n"
    }
    Write-P2BText (Join-Path $handoff 'design.md') "# Fixture`r`n`r`n#### Phase 2 fixture`r`n"
    Write-P2BText (Join-Path $source 'prompt.md') "Fixture only.`r`n"
    Write-P2BText (Join-Path $source 'target.txt') "Fixture target.`r`n"
    Write-P2BText (Join-Path $source '.gitignore') ".local/`r`nch/`r`ncodex.cmd`r`nrequest.json`r`n"
    Write-P2BText (Join-Path $codexHome 'default.config.toml') "model = `"fixture-model`"`r`nmodel_reasoning_effort = `"high`"`r`n"
    if ($Advisor) {
        Write-P2BText (Join-Path $codexHome 'advisor.config.toml') "model = `"fixture-model`"`r`nmodel_reasoning_effort = `"high`"`r`n"
        $pack = @('schema: advisor-consult.evidence.v1', 'line-slug: a', 'dispatch-slug: q', '## 目標段落', 'source: target.txt:1', 'excerpt: Fixture target.', '## 已知結論', 'conclusion: fixture conclusion', '## 待答問題', 'question-001: fixture question', 'required-output: ## 中斷保全結論; ## 證據支持; ## 推論; ## 未決問題', 'output-rules: Answer question-001.', '## 可能反證', 'counterexample: fixture counterexample', '## 邊界', 'boundary: fixture boundary', '- allowed-input: this evidence pack only', '- forbidden-action: source exploration, repository scan, file mutation, external dispatch') -join "`r`n"
        Write-P2BText (Join-Path $handoff 'pack.md') ($pack + "`r`n")
    }
    $now = [DateTimeOffset]::UtcNow
    $quota = [ordered]@{ schema = 'ai-sessions.quota-snapshot.v1'; state = 'Valid'; captured_at_utc = $now.ToString('o'); primary = @{ used_percent = 20; remaining_percent = 80; window_minutes = 300; resets_at = $now.AddHours(2).ToUnixTimeSeconds(); source_file = 'fixture' }; secondary = @{ used_percent = 10; remaining_percent = 90; window_minutes = 10080; resets_at = $now.AddDays(5).ToUnixTimeSeconds(); source_file = 'fixture' } }
    $quotaPath = Join-Path $history 'qb.json'
    Write-P2BText $quotaPath ($quota | ConvertTo-Json -Depth 10)
    $rollout = @{ timestamp = $now.ToString('o'); payload = @{ rate_limits = @{ primary = $quota.primary; secondary = $quota.secondary } } }
    Write-P2BText (Join-Path $codexHome 'sessions\fixture.jsonl') ($rollout | ConvertTo-Json -Compress -Depth 10)
    $message = "design.md q a"
    $cmdText = @('@echo off', ':findLastMessage', 'if "%~1"=="" goto emitEvents', 'if /I "%~1"=="--output-last-message" goto writeLastMessage', 'shift', 'goto findLastMessage', ':writeLastMessage', ('>"%~2" echo ' + $message), ':emitEvents', ('echo {"type":"thread.started","thread_id":"' + $thread + '"}'), ('echo {"type":"item.completed","item":{"type":"agent_message","text":"' + $message + '"}}'), 'echo {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}', 'powershell.exe -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 1"', 'exit /b 0') -join "`r`n"
    if ($RequirementMapFixture) {
        $finalMessage = "requiredIdentifier: design.md`ndispatchSlug: q`nlineSlug: a"
        $agentEvent = @{ type = 'item.completed'; item = @{ type = 'agent_message'; text = $finalMessage } } | ConvertTo-Json -Compress -Depth 5
        $lastMessageCommands = @('>"%~2" echo requiredIdentifier: design.md', '>>"%~2" echo dispatchSlug: q', '>>"%~2" echo lineSlug: a') -join "`r`n"
        $cmdText = $cmdText.Replace(('>"%~2" echo ' + $message), $lastMessageCommands)
        $cmdText = $cmdText.Replace(('echo {"type":"item.completed","item":{"type":"agent_message","text":"' + $message + '"}}'), ('echo ' + $agentEvent))
    }
    if ($Advisor) {
        $messageLines = @('## 中斷保全結論', '已確認結論：fixture question answered.', '實際覆蓋範圍：question-001', '已完成單位：question-001', '證據位置：pack.md q a', '## 證據支持', 'fixture evidence', '## 推論', 'fixture inference', '## 未決問題', '無')
        $messageText = $messageLines -join "`n"
        $eventLines = @(
            (@{ type = 'thread.started'; thread_id = $thread } | ConvertTo-Json -Compress),
            (@{ type = 'item.completed'; item = @{ type = 'agent_message'; text = $messageText } } | ConvertTo-Json -Compress -Depth 5),
            '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
        ) -join "`n"
        $stubCode = '$ErrorActionPreference = ''Stop''; $ProgressPreference = ''SilentlyContinue''; $encoding = [Text.UTF8Encoding]::new($false); [Console]::OutputEncoding = $encoding; $message = ''' + $messageText.Replace("'", "''") + '''; [IO.File]::WriteAllText($env:FIXTURE_LAST_MESSAGE_PATH, $message, $encoding); $stream = [Console]::OpenStandardOutput(); $bytes = $encoding.GetBytes(''' + ($eventLines + "`n").Replace("'", "''") + '''); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush(); [Threading.Thread]::Sleep(1000); exit 0'
        $encodedStub = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($stubCode))
        $cmdText = @('@echo off', ':findLastMessage', 'if "%~1"=="" exit /b 1', 'if /I "%~1"=="--output-last-message" goto emitEvents', 'shift', 'goto findLastMessage', ':emitEvents', 'set "FIXTURE_LAST_MESSAGE_PATH=%~2"', ('powershell.exe -NoProfile -NonInteractive -EncodedCommand ' + $encodedStub), 'exit /b %errorlevel%') -join "`r`n"
    }
    Write-P2BText (Join-Path $source 'codex.cmd') ($cmdText + "`r`n")
    if (-not $DirectWrite) {
        & git -C $source init --quiet
        Assert-P1B3 ($LASTEXITCODE -eq 0) 'P2-B fixture git init failed.'
        & git -C $source add -- target.txt prompt.md .gitignore
        Assert-P1B3 ($LASTEXITCODE -eq 0) 'P2-B fixture git add failed.'
        & git -C $source -c user.name=fixture -c user.email=fixture@example.invalid commit --no-verify --quiet -m fixture
        Assert-P1B3 ($LASTEXITCODE -eq 0) 'P2-B fixture git commit failed.'
    }
    $request = [ordered]@{ schema = 'ai-sessions.dispatch-request.v1'; operation = 'Dispatch'; source_root = $source; dispatch_root = $dispatch; line_slug = $line; dispatch_slug = $slug; caller_session_id = 'p2b-fixture'; write_mode = 'write'; dispatch_kind = 'workflow'; target_path = @((Join-Path $source 'target.txt')); prompt_path = (Join-Path $source 'prompt.md'); task_type = 'implement'; session_mode = 'cold-start'; unit_kind = 'workflow-phase'; failure_receipt_path = (Join-Path $history 'failure.json'); quota_before_path = $quotaPath }
    if ($Advisor) {
        $request.write_mode = 'readonly'
        $request.dispatch_kind = 'resource'
        $request.task_type = 'advisor-consult'
        $request.unit_kind = 'advisor-evidence-question'
        $request.profile = 'advisor'
        $request.advisor_request_source = 'user-explicit'
        $request.requested_unit = @('question-001')
        $request.evidence_pack_path = Join-Path $dispatch '.local\ai-sessions\history\a\pack.md'
        $request.prepare_artifacts = @([ordered]@{ source = (Join-Path $handoff 'pack.md'); destination = $request.evidence_pack_path; sha256 = (Get-FileSha256 (Join-Path $handoff 'pack.md')); purpose = 'Advisor fixture evidence pack' })
        $request.advisor_consult_report_path = Join-Path $dispatch '.local\ai-sessions\report\a\advisor-consult-q.md'
        $request.quota_after_path = Join-Path $dispatch '.local\ai-sessions\history\a\qa.json'
        $request.background = $true
    }
    $requestPath = Join-Path $source 'request.json'
    Write-P2BText $requestPath ($request | ConvertTo-Json -Depth 20)
    $launchArguments = @('-Operation', 'Dispatch', '-RequestPath', $requestPath, '-CodexHome', $codexHome, '-CodexPath', (Join-Path $source 'codex.cmd'))
    $output = @(Invoke-P2BEntry -Arguments $launchArguments)
    $output | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
    $run = $output[-1]
    if ($Advisor) {
        Assert-P1B3 ($run.ExitCode -eq 0 -and $run.Document.status -ceq 'started') ('Advisor background Dispatch failed: ' + $run.Stderr + $run.Stdout)
        $advisorRecord = Read-DispatchRunRecord -Path $run.Document.inspect_binding.run_record_path -SourceRoot $source -ExecutionRoot $dispatch -LineSlug 'a' -DispatchSlug 'q'
        $null = Wait-DispatchExitAndTerminalEvent -ExecutionRoot $dispatch -SourceRoot $source -LineSlug 'a' -DispatchSlug 'q' -WriteMode 'readonly' -RunRecordPath $run.Document.inspect_binding.run_record_path -EventStreamPath $advisorRecord.event_stream_path -SidecarPath $advisorRecord.process_exit_code_sidecar_path
    }
    else {
        Assert-P1B3 ($run.ExitCode -eq 0 -and $run.Document.status -ceq 'completed') ('P2-B cold Dispatch failed: ' + $run.Stderr + $run.Stdout)
    }
    $execution = if ($DirectWrite) { $source } else { $dispatch }
    $longest = @(Get-ChildItem -LiteralPath $source -Recurse -Force -File | Sort-Object { $_.FullName.Length } -Descending)[0].FullName.Length
    Assert-P1B3 ($longest -le 240) ('P2-B fixture exceeds 240 characters: ' + $longest)
    return [pscustomobject]@{ Source = $source; Dispatch = $dispatch; Execution = $execution; Request = $request; RequestPath = $requestPath; Arguments = $launchArguments; Result = $run.Document; Thread = $thread }
}

function Remove-P2BFixture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Fixture)
    if ([IO.File]::Exists((Join-Path $Fixture.Dispatch '.git'))) {
        $cleanupOutput = @(Invoke-P2BEntry -Arguments @('-Operation', 'Cleanup', '-SourceRoot', $Fixture.Source, '-DispatchRoot', $Fixture.Dispatch, '-LineSlug', 'a', '-DispatchSlug', 'q', '-CallerSessionId', 'p2b-fixture', '-PreflightResultPath', $Fixture.Result.preflight_result_path, '-RunRecordPath', $Fixture.Result.inspect_binding.run_record_path))
        $cleanupOutput | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
        if ($cleanupOutput[-1].ExitCode -ne 0) {
            Write-Output ('FIXTURE-PRESERVED: ' + $Fixture.Source + '; Cleanup refused removal; no process absence was inferred.')
            return
        }
    }
    $resolved = [IO.Path]::GetFullPath($Fixture.Source)
    Assert-P1B3 (Test-PathWithinRoot $resolved ([IO.Path]::GetFullPath($FixtureBaseRootPath))) 'P2-B removal escaped fixture base.'
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Invoke-Q1 {
    $output = @(New-P2BFixture)
    $output | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
    $f = $output[-1]
    try {
        foreach ($stage in @('preflight', 'prepare')) {
            $path = [string]$f.Result.($stage + '_result_path')
            Assert-P1B3 ([IO.File]::Exists($path)) ($stage + ' default result is missing.')
            Assert-P1B3 ((Get-FileSha256 $path) -ceq [string]$f.Result.($stage + '_result_sha256')) ($stage + ' hash does not match Dispatch result.')
            Assert-P1B3 (Test-PathWithinRoot $path (Join-Path $f.Execution '.local\ai-sessions\history\a')) ($stage + ' default result is outside same-line history.')
        }
        Assert-P1B3 (Test-PathWithinRoot $f.Result.preflight_result_path $f.Source) 'Preflight result escaped SourceRoot.'
        Write-Output 'CASE: Q1 omitted stage paths persist matching SHA-256; PASS'
    }
    finally { Remove-P2BFixture $f }
}

function Invoke-Q2 {
    $output = @(New-P2BFixture)
    $output | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
    $f = $output[-1]
    try {
        $anchor = ConvertFrom-DispatchJson -Content ([IO.File]::ReadAllText($f.Result.inspect_binding.run_record_path))
        $requestPath = Join-Path $f.Source 'resume.json'
        Write-P2BText $requestPath (@{ schema = 'ai-sessions.dispatch-request.v1'; operation = 'Start'; line_slug = 'a'; dispatch_slug = 'q'; target_path = @((Join-Path $f.Source 'target.txt')) } | ConvertTo-Json -Depth 10)
        $resumeOutput = @(Invoke-P2BEntry -Arguments @('-Operation', 'Start', '-RequestPath', $requestPath, '-SourceRoot', $f.Source, '-ExecutionRoot', $f.Execution, '-DispatchRoot', $f.Dispatch, '-PreflightResultPath', $f.Result.preflight_result_path, '-PrepareResultPath', $f.Result.prepare_result_path, '-PromptPath', (Join-Path $f.Source 'prompt.md'), '-ResumeThreadId', $f.Thread, '-ScopePlanPath', $anchor.scope_plan_path, '-DispatchKind', 'workflow', '-TaskType', 'implement', '-SessionMode', 'Continuation', '-UnitKind', 'workflow-phase', '-CallerSessionId', 'p2b-fixture', '-CodexHome', (Join-Path $f.Source 'ch'), '-CodexPath', (Join-Path $f.Source 'codex.cmd')))
        $resumeOutput | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
        $resume = $resumeOutput[-1]
        Assert-P1B3 ($resume.ExitCode -eq 0 -and $resume.Document.processStarted) 'Q2 Start did not accept Dispatch-recorded stage paths for same-worktree resume.'
        $record = ConvertFrom-DispatchJson -Content ([IO.File]::ReadAllText($resume.Document.runRecordPath))
        Assert-P1B3 ($record.preflight_result_path -ceq $f.Result.preflight_result_path -and $record.prepare_result_path -ceq $f.Result.prepare_result_path -and $record.prepare_result_sha256 -ceq $f.Result.prepare_result_sha256) 'Q2 resumed RunRecord did not bind the original stage results.'
        $deadline = [datetime]::UtcNow.AddSeconds(30)
        while (-not [IO.File]::Exists($record.process_exit_code_sidecar_path)) {
            if ([datetime]::UtcNow -gt $deadline) { throw 'Q2 fixture launcher did not record process completion.' }
            Start-Sleep -Milliseconds 100
        }
        $sidecar = ConvertFrom-DispatchJson -Content ([IO.File]::ReadAllText($record.process_exit_code_sidecar_path))
        Assert-P1B3 ($sidecar.process_exit_code -eq 0) 'Q2 fixture launcher exited with failure.'
        $f.Result.inspect_binding.run_record_path = $resume.Document.runRecordPath
        Write-Output 'CASE: Q2 Dispatch-recorded paths support Start same-worktree resume; PASS'
    }
    finally { Remove-P2BFixture $f }
}

function Invoke-Q3 {
    foreach ($directWrite in @($false, $true)) {
        $output = @(New-P2BFixture -DirectWrite:$directWrite -RequirementMapFixture)
        $output | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
        $f = $output[-1]
        try {
            $recordPath = $f.Result.inspect_binding.run_record_path
            $record = ConvertFrom-DispatchJson -Content ([IO.File]::ReadAllText($recordPath))
            $checkpointPath = $record.interruption_checkpoint_path
            $expected = Get-DispatchInterruptionCheckpointPath -SourceRoot $f.Execution -LineSlug 'a' -DispatchSlug 'q' -RunId $record.run_id
            Assert-P1B3 ($checkpointPath -ceq $expected -and [IO.File]::Exists($checkpointPath)) 'Q3 Start did not initialize checkpoint in ExecutionRoot history.'
            $prompt = [IO.File]::ReadAllText($record.prompt_path)
            Assert-P1B3 ($prompt.Contains($checkpointPath)) 'Q3 Start prompt did not instruct the executor to update its writable checkpoint.'
            $checkpoint = ConvertFrom-DispatchJson -Content ([IO.File]::ReadAllText($checkpointPath))
            $checkpoint.confirmed_units = @(@{ unit = 'Phase 2'; confirmed_result = 'Fixture target verified.'; evidence_locations = @((Join-Path $f.Execution 'target.txt')) })
            $checkpoint.incomplete_units = @()
            $checkpoint.updated_at_utc = [datetime]::UtcNow.ToString('o')
            $null = Write-DispatchAtomicJsonDocument -Path $checkpointPath -Document $checkpoint -SourceRoot $f.Execution -ExecutionRoot $f.Execution -TargetPath @()
            $inspectArguments = @('-Operation', 'Inspect', '-SourceRoot', $f.Source, '-ExecutionRoot', $f.Execution, '-LineSlug', 'a', '-DispatchSlug', 'q', '-RunRecordPath', $recordPath, '-EventStreamPath', $record.event_stream_path, '-LastMessagePath', $record.last_message_path, '-ScopePlanPath', $record.scope_plan_path, '-ProcessExitCode', '0', '-RequiredIdentifier', 'design.md', '-TaskType', 'implement')
            $inspectOutput = @(Invoke-P2BEntry -Arguments $inspectArguments)
            $inspectOutput | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
            $inspect = $inspectOutput[-1]
            Assert-P1B3 ($inspect.ExitCode -eq 0 -and @($inspect.Document.interruptionCheckpoint.confirmed_units).Count -eq 1) 'Q3 Inspect did not return executor-confirmed checkpoint data.'
            $report = Join-Path $f.Execution '.local\ai-sessions\report\a\fixture.md'
            Write-P2BText $report "# Fixture report`r`n`r`n## Phase 對照`r`n`r`n## 需求對照`r`n`r`n| 需求 | 驗收方向 | T-code | 實際行為 | 證據 | 狀態 |`r`n| --- | --- | --- | --- | --- | --- |`r`n| #22 | Fixture | T056 | Updated checkpoint | ${checkpointPath}:1 | 已交付 |`r`n範圍外（本輪不要求交付）：#1`r`n"
            $preflight = ConvertFrom-DispatchJson -Content ([IO.File]::ReadAllText($f.Result.preflight_result_path))
            $collectArguments = @('-Operation', 'Collect', '-SourceRoot', $f.Source, '-ExecutionRoot', $f.Execution, '-DispatchRoot', $f.Dispatch, '-LineSlug', 'a', '-DispatchSlug', 'q', '-PreflightResultPath', $f.Result.preflight_result_path, '-RunRecordPath', $recordPath, '-RequestPath', $f.RequestPath, '-RequirementSummaryPath', (Join-Path $f.Source '.local\ai-sessions\handoff\a\requirement-summary.md'), '-SelectedRequirement', '#22', '-DispatchKind', 'workflow', '-ReportPath', $report)
            if (-not $directWrite) { $collectArguments += @('-BaseSha', $preflight.baseSha) }
            $collectOutput = @(Invoke-P2BEntry -Arguments $collectArguments)
            $collectOutput | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
            $collect = $collectOutput[-1]
            Assert-P1B3 ($collect.ExitCode -eq 0 -and @($collect.Document.interruptionCheckpoint.confirmed_units).Count -eq 1) 'Q3 Collect did not return updated checkpoint contents.'
            Write-Output ('CASE: Q3 ' + $(if ($directWrite) { 'direct-write keeps sourceRoot' } else { 'worktree uses writable executionRoot' }) + ' checkpoint read by Inspect and Collect; PASS')
            if (-not $directWrite) {
                $legacyPath = Get-DispatchInterruptionCheckpointPath -SourceRoot $f.Source -LineSlug 'a' -DispatchSlug 'q' -RunId $record.run_id
                $null = Write-DispatchAtomicJsonDocument -Path $legacyPath -Document $checkpoint -SourceRoot $f.Source -ExecutionRoot $f.Execution -TargetPath @()
                $record.interruption_checkpoint_path = $legacyPath
                $null = Write-DispatchRunRecord -Record $record -Update
                $legacyCollect = Get-CollectInterruptionCheckpoint -SourceRoot $f.Source -ExecutionRoot $f.Execution -LineSlug 'a' -DispatchSlug 'q' -RunRecordPath $recordPath
                Assert-P1B3 ($legacyCollect.status -ceq 'available' -and @($legacyCollect.confirmed_units).Count -eq 1) 'Q3 legacy sourceRoot RunRecord checkpoint is no longer readable by Collect.'
                $legacyInspectOutput = @(Invoke-P2BEntry -Arguments $inspectArguments)
                $legacyInspectOutput | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
                Assert-P1B3 ($legacyInspectOutput[-1].ExitCode -eq 0 -and @($legacyInspectOutput[-1].Document.interruptionCheckpoint.confirmed_units).Count -eq 1) 'Q3 legacy sourceRoot RunRecord checkpoint is no longer readable by Inspect.'
                [IO.File]::Delete($legacyPath)
                $record.interruption_checkpoint_path = $checkpointPath
                $null = Write-DispatchRunRecord -Record $record -Update
                $cleanupOutput = @(Invoke-P2BEntry -Arguments @('-Operation', 'Cleanup', '-SourceRoot', $f.Source, '-DispatchRoot', $f.Dispatch, '-LineSlug', 'a', '-DispatchSlug', 'q', '-CallerSessionId', 'p2b-fixture', '-PreflightResultPath', $f.Result.preflight_result_path, '-RunRecordPath', $recordPath))
                $cleanupOutput | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
                Assert-P1B3 ($cleanupOutput[-1].ExitCode -eq 0 -and $cleanupOutput[-1].Document.worktree_removed) 'Q3 Cleanup did not remove the verified completed fixture worktree.'
                Assert-P1B3 ([IO.File]::Exists($legacyPath)) 'Q3 Cleanup did not preserve executionRoot checkpoint in source history.'
                $preserved = ConvertFrom-DispatchJson -Content ([IO.File]::ReadAllText($legacyPath))
                Assert-P1B3 (@($preserved.confirmed_units).Count -eq 1 -and $preserved.confirmed_units[0].confirmed_result -ceq 'Fixture target verified.') 'Q3 Cleanup did not preserve the updated checkpoint contents.'
                Write-Output 'CASE: Q3 legacy sourceRoot checkpoint remains readable; Cleanup preserves updated checkpoint; PASS'
            }
        }
        finally { Remove-P2BFixture $f }
    }
}

function Invoke-Q4 {
    $fixtureBase = [IO.Path]::GetFullPath($FixtureBaseRootPath)
    $fixtureRoot = Join-Path $fixtureBase (New-P1B3FixtureName -Code 'q4')
    $null = Get-P1B3FixturePathPlan -FixtureRoot $fixtureRoot -DispatchSlug 'q4'
    Assert-P1B3 (Test-PathWithinRoot $fixtureRoot $fixtureBase) 'Q4 fixture escaped its base root.'
    $savedWriter = (Get-Command Write-PrepareResultDocument -CommandType Function).ScriptBlock
    $script:Q4WriterCalls = 0
    try {
        Write-P2BText (Join-Path $fixtureRoot '.local\ai-sessions\handoff\a\line.json') '{"schema":"ai-sessions.line.v1","line-slug":"a"}'
        $script:SourceRoot = $fixtureRoot
        $script:ExecutionRoot = $fixtureRoot
        $script:DispatchRoot = $fixtureRoot
        $script:LineSlug = 'a'
        $script:DispatchSlug = 'q4'
        $script:CodexHome = Join-Path $fixtureRoot 'ch'
        $script:RequestContext = $null
        $script:RequestPath = ''
        $script:RequestPrepareArtifacts = @()
        $script:CallerSessionIdentity = $null
        $script:DispatchStageBinding = $null
        $script:PrepareResultPath = Join-Path $fixtureRoot '.local\ai-sessions\history\a\prepare.json'
        $script:ResultPath = ''
        $script:PreflightResultPath = ''
        $script:QuotaBeforePath = ''
        $script:QuotaAfterPath = ''
        $script:WriteMode = 'write'
        $script:AddDirectory = @()
        $script:TargetPath = @()
        Set-Item -Path Function:Write-PrepareResultDocument -Value {
            param([string]$Path, [object]$Document, [string]$GuardSourceRoot, [string]$GuardExecutionRoot, [string[]]$GuardTargetPath, [switch]$RequireAbsent)
            $script:Q4WriterCalls++
            if ($script:Q4WriterCalls -eq 1) { throw [IO.IOException]::new('Initial writer failure fixture.') }
            throw [IO.IOException]::new('FAKE_SECRET_VALUE')
        }
        $operationResult = $null
        try { $null = Invoke-Prepare }
        catch { $operationResult = $_.Exception.Data['operationResult'] }
        Assert-P1B3 ($script:Q4WriterCalls -eq 2 -and $null -ne $operationResult) 'Q4 did not reach the failed PrepareFailed document writer.'
        Assert-P1B3 ($operationResult.prepareResultWriteFailure.code -ceq 'PrepareResultWriteFailed' -and $operationResult.prepareResultWriteFailure.path -ceq $script:PrepareResultPath) 'Q4 operation result did not identify the second writer failure code and target path.'
        Assert-P1B3 ($null -eq $operationResult.prepareResultSha256) 'Q4 failed writer retained a Prepare result SHA-256.'
        Assert-P1B3 (-not ($operationResult | ConvertTo-Json -Depth 20).Contains('FAKE_SECRET_VALUE')) 'Q4 second writer exception leaked into operation result.'
        Assert-P1B3 ($script:PrepareResultPath.Length -le 240) 'Q4 fixture exceeds the 240-character bound.'
        Write-Output 'CASE: Q4 PrepareFailed writer failure returns sanitized code and path with null SHA-256; PASS'
    }
    finally {
        Set-Item -Path Function:Write-PrepareResultDocument -Value $savedWriter
        if ([IO.Directory]::Exists($fixtureRoot)) {
            Assert-P1B3 (Test-PathWithinRoot ([IO.Path]::GetFullPath($fixtureRoot)) $fixtureBase) 'Q4 fixture removal escaped its base root.'
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
        }
    }
}


function Invoke-Q5 {
    $skillPath = Join-Path (Split-Path -Parent $scriptsRoot) 'skills\codex-dispatch\SKILL.md'
    $skill = [IO.File]::ReadAllText($skillPath)
    $continuation = ($skill -split '## 續 session 與跨介面接手', 2)[1] -split '### 中止與安全關閉', 2
    Assert-P1B3 ($continuation[0].Contains('Start -ResumeThreadId') -and $continuation[0].Contains('preflight_result_path') -and $continuation[0].Contains('prepare_result_path') -and $continuation[0].Contains('session_mode=Continuation') -and $continuation[0].Contains('continue_from_scope_plan')) 'Q5 does not document both continuation routes and their stage result parameter sources.'
    Assert-P1B3 ($continuation[0].Contains('executionRoot') -and $continuation[0].Contains('direct-write') -and $continuation[0].Contains('Inspect') -and $continuation[0].Contains('Collect') -and $continuation[0].Contains('Cleanup')) 'Q5 checkpoint location and lifecycle readers/writer are not documented.'
    Assert-P1B3 ($skill.Contains('prepareResultWriteFailure.code=PrepareResultWriteFailed') -and $skill.Contains('prepareResultWriteFailure.path') -and $skill.Contains('prepareResultSha256=null')) 'Q5 does not document the sanitized failed Prepare result write.'
    Write-Output 'CASE: Q5 Skill documents two continuation routes, stage parameter sources, checkpoint lifecycle, and failed Prepare writer result; PASS'
}

function Invoke-R1 {
    $output = @(New-P2BFixture)
    $output | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
    $f = $output[-1]
    $holder = $null
    try {
        $recordPath = $f.Result.inspect_binding.run_record_path
        $record = ConvertFrom-DispatchJson -Content ([IO.File]::ReadAllText($recordPath))
        $holderPath = Join-Path $f.Source 'hold.ps1'
        $readyPath = Join-Path $f.Source 'ready.txt'
        $releasePath = Join-Path $f.Source 'release.txt'
        $holderScript = @'
param([string]$EventPath, [string]$MessagePath, [string]$SidecarPath, [string]$ReadyPath, [string]$ReleasePath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$handles = New-Object 'Collections.Generic.List[object]'
try {
    foreach ($path in @($EventPath, $MessagePath, $SidecarPath)) {
        $handles.Add([IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Write, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)))
    }
    [IO.File]::WriteAllText($ReadyPath, 'ready')
    $deadline = [datetime]::UtcNow.AddSeconds(60)
    while (-not [IO.File]::Exists($ReleasePath)) {
        if ([datetime]::UtcNow -gt $deadline) { throw 'Holder release timeout.' }
        Start-Sleep -Milliseconds 50
    }
}
finally { foreach ($handle in $handles) { $handle.Dispose() } }
'@
        [IO.File]::WriteAllText($holderPath, $holderScript, (New-Object Text.UTF8Encoding($true)))
        $hostPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $holderInfo = New-ProcessStartInfo -FileName $hostPath -WorkingDirectory $f.Source -Arguments @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $holderPath, $record.event_stream_path, $record.last_message_path, $record.process_exit_code_sidecar_path, $readyPath, $releasePath) -RedirectOutput
        $holder = New-Object Diagnostics.Process
        $holder.StartInfo = $holderInfo
        $null = $holder.Start()
        $holder.StandardInput.Close()
        $holderError = $holder.StandardError.ReadToEndAsync()
        $deadline = [datetime]::UtcNow.AddSeconds(15)
        while (-not [IO.File]::Exists($readyPath)) {
            if ($holder.HasExited -or [datetime]::UtcNow -gt $deadline) { throw 'R1 holder did not acquire its handles.' }
            Start-Sleep -Milliseconds 50
        }
        $beforeHash = Get-FileSha256 $record.event_stream_path
        $inspectOutput = @(Invoke-P2BEntry -Arguments @('-Operation', 'Inspect', '-SourceRoot', $f.Source, '-ExecutionRoot', $f.Execution, '-LineSlug', 'a', '-DispatchSlug', 'q', '-RunRecordPath', $recordPath, '-EventStreamPath', $record.event_stream_path, '-LastMessagePath', $record.last_message_path, '-ScopePlanPath', $record.scope_plan_path, '-ProcessExitCode', '0', '-RequiredIdentifier', 'design.md', '-TaskType', 'implement'))
        $inspectOutput | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
        Assert-P1B3 ($inspectOutput[-1].ExitCode -eq 0 -and $inspectOutput[-1].Document.success) 'R1 Inspect failed while another process held writable evidence handles.'
        Assert-P1B3 ((Get-FileSha256 $record.event_stream_path) -ceq $beforeHash) 'R1 evidence hash changed during shared reads.'
        Assert-P1B3 (-not $holder.HasExited) 'R1 writer exited before Inspect completed.'
        Write-Output 'CASE: R1 Inspect completes with independent writable event, last-message and exit-sidecar handles; PASS'
    }
    finally {
        if ($null -ne $holder) {
            [IO.File]::WriteAllText($releasePath, 'release')
            Assert-P1B3 ($holder.WaitForExit(65000)) 'R1 holder did not exit after release.'
            $holder.WaitForExit()
            Assert-P1B3 ($holder.ExitCode -eq 0) ('R1 holder failed: ' + $holderError.GetAwaiter().GetResult())
            $holder.Dispose()
        }
        Remove-P2BFixture $f
    }
}

function Invoke-R2 {
    foreach ($legacy in @($false, $true)) {
        $output = @(New-P2BFixture)
        $output | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
        $f = $output[-1]
        try {
            $recordPath = $f.Result.inspect_binding.run_record_path
            $record = Read-DispatchRunRecord -Path $recordPath -SourceRoot $f.Source -ExecutionRoot $f.Execution -LineSlug 'a' -DispatchSlug 'q'
            Assert-P1B3 (-not [string]::IsNullOrWhiteSpace([string]$record.error_stream_path)) 'R2 Start did not record top-level error_stream_path.'
            $errorPath = $record.error_stream_path
            $preservedPath = Join-Path $f.Source (Get-CleanupRelativePath -Path $errorPath -Root $f.Execution)
            Write-P2BText $errorPath 'FAKE_SECRET_VALUE'
            $expectedHash = Get-FileSha256 $errorPath
            if ($legacy) {
                $record.PSObject.Properties.Remove('error_stream_path')
                $null = Write-DispatchRunRecord -Record $record -Update
                $null = Read-DispatchRunRecord -Path $recordPath -SourceRoot $f.Source -ExecutionRoot $f.Execution -LineSlug 'a' -DispatchSlug 'q'
            }
            $cleanupOutput = @(Invoke-P2BEntry -Arguments @('-Operation', 'Cleanup', '-SourceRoot', $f.Source, '-DispatchRoot', $f.Dispatch, '-LineSlug', 'a', '-DispatchSlug', 'q', '-CallerSessionId', 'p2b-fixture', '-PreflightResultPath', $f.Result.preflight_result_path, '-RunRecordPath', $recordPath))
            $cleanupOutput | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
            Assert-P1B3 ($cleanupOutput[-1].ExitCode -eq 0 -and $cleanupOutput[-1].Document.worktree_removed) 'R2 Cleanup failed for a completed worktree dispatch.'
            if ($legacy) {
                Write-Output 'CASE: R2 legacy RunRecord without error_stream_path still reads and cleans up; PASS'
            }
            else {
                Assert-P1B3 ([IO.File]::Exists($preservedPath) -and (Get-FileSha256 $preservedPath) -ceq $expectedHash) 'R2 Cleanup did not preserve stderr bytes in source history.'
                Write-Output 'CASE: R2 Cleanup preserves top-level RunRecord stderr in source history; PASS'
            }
        }
        finally { Remove-P2BFixture $f }
    }
}

function Invoke-R3 {
    $output = @(New-P2BFixture -Advisor)
    $output | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
    $f = $output[-1]
    try {
        $recordPath = $f.Result.inspect_binding.run_record_path
        $record = Read-DispatchRunRecord -Path $recordPath -SourceRoot $f.Source -ExecutionRoot $f.Execution -LineSlug 'a' -DispatchSlug 'q'
        $plan = Get-Content -LiteralPath $record.scope_plan_path -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-P1B3 ($plan.task_type -ceq 'advisor-consult' -and $plan.requested_profile -ceq 'advisor') 'R3 fixture did not execute an advisor dispatch.'
        $expected = @{}
        foreach ($extension in @('sha256', 'length')) {
            $path = Join-Path $f.Execution ('.local\ai-sessions\history\evidence-pack-q.' + $extension)
            Assert-P1B3 ([IO.File]::Exists($path)) ('R3 Start did not write ' + $extension + ' sidecar.')
            $expected[$extension] = Get-FileSha256 $path
        }
        $nonAdvisor = [pscustomobject]@{ execution_root = $f.Execution; dispatch_slug = 'q'; evidence_pack_path = $null }
        Assert-P1B3 (@(Get-CleanupRecordReferencedPaths -Record $nonAdvisor).Count -eq 0) 'R3 derived advisor sidecars for a non-advisor RunRecord.'
        $cleanupOutput = @(Invoke-P2BEntry -Arguments @('-Operation', 'Cleanup', '-SourceRoot', $f.Source, '-DispatchRoot', $f.Dispatch, '-LineSlug', 'a', '-DispatchSlug', 'q', '-CallerSessionId', 'p2b-fixture', '-PreflightResultPath', $f.Result.preflight_result_path, '-RunRecordPath', $recordPath))
        $cleanupOutput | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
        Assert-P1B3 ($cleanupOutput[-1].ExitCode -eq 0 -and $cleanupOutput[-1].Document.worktree_removed) 'R3 advisor Cleanup failed.'
        foreach ($extension in @('sha256', 'length')) {
            $path = Join-Path $f.Source ('.local\ai-sessions\history\evidence-pack-q.' + $extension)
            Assert-P1B3 ([IO.File]::Exists($path) -and (Get-FileSha256 $path) -ceq $expected[$extension]) ('R3 Cleanup lost or changed ' + $extension + ' sidecar.')
        }
        Write-Output 'CASE: R3 advisor Cleanup preserves hash and length sidecars; PASS'
        Write-Output 'CASE: R3 non-advisor RunRecord does not acquire sidecar references; PASS'
    }
    finally { Remove-P2BFixture $f }
}

function Invoke-R4 {
    $tokens = $null
    $parseErrors = $null
    $startAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsRoot 'dispatch\start-lifecycle.ps1'), [ref]$tokens, [ref]$parseErrors)
    Assert-P1B3 (@($parseErrors).Count -eq 0) 'R4 Start preparation could not be parsed.'
    $resumeBlock = $startAst.Find({ param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains('$previousRun = Resolve-PreviousDispatchRun') }, $true)
    $preparation = @($resumeBlock.Clauses[0].Item2.Statements | Select-Object -Skip 1 | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine
    foreach ($shape in @('legacy', 'legacy-with-thread', 'checkpoint')) {
        $anchor = [pscustomobject]@{ run_id = 'FAKE_RUN_ID'; last_message_path = 'FAKE_LAST_MESSAGE_PATH' }
        $previousRun = [pscustomobject]@{ AnchorRecord = $anchor; ChainTailRecord = $anchor; SkippedAttempts = @(); Message = 'FAKE_HANDOFF_MESSAGE' }
        if ($shape -eq 'legacy-with-thread') { $previousRun | Add-Member -NotePropertyName ResumeThreadId -NotePropertyValue 'FAKE_THREAD_ID' }
        if ($shape -eq 'checkpoint') {
            $previousRun | Add-Member -NotePropertyName HandoffPath -NotePropertyValue 'FAKE_CHECKPOINT_PATH'
            $previousRun | Add-Member -NotePropertyName HandoffSourceType -NotePropertyValue 'interruption-checkpoint'
        }
        . ([scriptblock]::Create($preparation))
        if ($shape -eq 'checkpoint') {
            Assert-P1B3 ($continuationContextPath -ceq 'FAKE_CHECKPOINT_PATH' -and $continuationHandoffSourceType -ceq 'interruption-checkpoint') 'R4 Start lost the validated checkpoint handoff.'
        }
        else {
            Assert-P1B3 ($continuationContextPath -ceq $anchor.last_message_path -and $continuationHandoffSourceType -ceq 'last-message') 'R4 Start rejected a legacy resolver result or lost its anchor handoff.'
        }
        Assert-P1B3 ($continuationContextMessage -ceq 'FAKE_HANDOFF_MESSAGE' -and $resumeAnchorRunIdValue -ceq $anchor.run_id) 'R4 Start changed the handoff message or anchor identity.'
        Write-Output ('CASE: R4 actual Start preparation handoff shape ' + $shape + '; PASS')
    }
    foreach ($missingCheckpoint in @($false, $true)) {
        $output = @(New-P2BFixture)
        $output | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
        $f = $output[-1]
        try {
            $anchor = Read-DispatchRunRecord -Path $f.Result.inspect_binding.run_record_path -SourceRoot $f.Source -ExecutionRoot $f.Execution -LineSlug 'a' -DispatchSlug 'q'
            Write-P2BText $anchor.event_stream_path ((@{ type = 'thread.started'; thread_id = $f.Thread } | ConvertTo-Json -Compress) + "`r`n" + '{"type":"turn.failed","error":{"message":"fixture interrupted"}}' + "`r`n")
            Remove-Item -LiteralPath $anchor.last_message_path -Force
            if ($missingCheckpoint) {
                Remove-Item -LiteralPath $anchor.interruption_checkpoint_path -Force
            }
            else {
                $checkpointBytes = [IO.File]::ReadAllBytes($anchor.interruption_checkpoint_path)
                Write-P2BText $anchor.interruption_checkpoint_path '{"secret":"FAKE_SECRET_VALUE"'
                $rejected = $false
                try { $null = Resolve-PreviousDispatchRun -SourceRoot $f.Source -ExecutionRoot $f.Execution -LineSlug 'a' -DispatchSlug 'q' -ResumeThreadId $f.Thread }
                catch {
                    $rejected = $_.Exception.Data['errorCode'] -ceq 'ResumeHandoffUnavailable' -and $_.Exception.Message.Contains($anchor.last_message_path) -and $_.Exception.Message.Contains($anchor.interruption_checkpoint_path) -and -not $_.Exception.Message.Contains('FAKE_SECRET_VALUE')
                }
                Assert-P1B3 $rejected 'R4 invalid checkpoint was accepted or exposed invalid content.'
                [IO.File]::WriteAllBytes($anchor.interruption_checkpoint_path, $checkpointBytes)
                Write-Output 'CASE: R4 invalid checkpoint uses fixed rejection without raw content; PASS'
            }
            $requestPath = Join-Path $f.Source 'resume.json'
            Write-P2BText $requestPath (@{ schema = 'ai-sessions.dispatch-request.v1'; operation = 'Start'; line_slug = 'a'; dispatch_slug = 'q'; target_path = @((Join-Path $f.Source 'target.txt')) } | ConvertTo-Json -Depth 10)
            $resumeOutput = @(Invoke-P2BEntry -Arguments @('-Operation', 'Start', '-RequestPath', $requestPath, '-SourceRoot', $f.Source, '-ExecutionRoot', $f.Execution, '-DispatchRoot', $f.Dispatch, '-PreflightResultPath', $f.Result.preflight_result_path, '-PrepareResultPath', $f.Result.prepare_result_path, '-PromptPath', (Join-Path $f.Source 'prompt.md'), '-ResumeThreadId', $f.Thread, '-ScopePlanPath', $anchor.scope_plan_path, '-DispatchKind', 'workflow', '-TaskType', 'implement', '-SessionMode', 'Continuation', '-UnitKind', 'workflow-phase', '-CallerSessionId', 'p2b-fixture', '-CodexHome', (Join-Path $f.Source 'ch'), '-CodexPath', (Join-Path $f.Source 'codex.cmd')))
            $resumeOutput | Where-Object { $_ -is [string] } | ForEach-Object { Write-Output $_ }
            $resume = $resumeOutput[-1]
            if ($missingCheckpoint) {
                Assert-P1B3 ($resume.ExitCode -ne 0 -and $resume.Document.errorCode -ceq 'ResumeHandoffUnavailable' -and -not $resume.Document.processStarted -and $resume.Document.error.Contains($anchor.last_message_path) -and $resume.Document.error.Contains($anchor.interruption_checkpoint_path)) 'R4 missing handoff did not reject Start with fixed code and both paths.'
                Write-Output 'CASE: R4 missing last-message and checkpoint rejects Start with fixed code; PASS'
            }
            else {
                Assert-P1B3 ($resume.ExitCode -eq 0 -and $resume.Document.processStarted) 'R4 valid interruption checkpoint did not pass Start.'
                $record = Read-DispatchRunRecord -Path $resume.Document.runRecordPath -SourceRoot $f.Source -ExecutionRoot $f.Execution -LineSlug 'a' -DispatchSlug 'q'
                Assert-P1B3 ($record.continuation_handoff_source_type -is [string] -and $record.continuation_handoff_source_type -ceq 'interruption-checkpoint') 'R4 resumed RunRecord did not record checkpoint source type.'
                $prompt = Read-DispatchUtf8Text -Path $record.prompt_path
                Assert-P1B3 ($prompt.Contains($anchor.interruption_checkpoint_path) -and $prompt.Contains('尚無已確認完成單位。') -and $prompt.Contains('未完成單位：Phase 2')) 'R4 prompt lost checkpoint source or inferred completed units.'
                $null = Wait-DispatchExitAndTerminalEvent -ExecutionRoot $f.Execution -SourceRoot $f.Source -LineSlug 'a' -DispatchSlug 'q' -WriteMode 'write' -RunRecordPath $resume.Document.runRecordPath -EventStreamPath $record.event_stream_path -SidecarPath $record.process_exit_code_sidecar_path
                $f.Result.inspect_binding.run_record_path = $resume.Document.runRecordPath
                Write-Output 'CASE: R4 turn.failed resumes from validated checkpoint without last-message; PASS'
            }
        }
        finally { Remove-P2BFixture $f }
    }
}

function Invoke-R5 {
    $bindingPath = Join-Path $PSScriptRoot 'Test-DispatchRecoveryBinding.ps1'
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($bindingPath, [ref]$tokens, [ref]$parseErrors)
    Assert-P1B3 (@($parseErrors).Count -eq 0) 'R5 Binding AST parse failed.'
    foreach ($name in @('New-BindingFixtureName', 'Get-BindingFixturePathPlan')) {
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true)
        Assert-P1B3 ($null -ne $definition) ('R5 missing helper: ' + $name)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    foreach ($prefix in @('P1B3', 'Binding')) {
        $nameCommand = 'New-' + $prefix + 'FixtureName'
        $planCommand = 'Get-' + $prefix + 'FixturePathPlan'
        $name = & $nameCommand -Code 'f'
        Assert-P1B3 ($name -cmatch '^f-[0-9a-f]{8}$') ('R5 fixture name is not short GUID8: ' + $prefix)
        $fixture = Join-Path ([IO.Path]::GetFullPath($FixtureBaseRootPath)) $name
        $plan = & $planCommand -FixtureRoot $fixture -DispatchSlug 'q' -LineSlug 'a'
        Assert-P1B3 ($plan.EstimatedPathLength -le 240 -and -not [IO.Directory]::Exists($fixture)) ('R5 planner created fixture or exceeded limit: ' + $prefix)
        $rejected = $false
        try { $null = & $planCommand -FixtureRoot (Join-Path $fixture ('x' * 160)) -DispatchSlug 'q' -LineSlug 'a' }
        catch { $rejected = $_.Exception.Message.Contains('limit: 240') }
        Assert-P1B3 $rejected ('R5 long fixture was not rejected before creation: ' + $prefix)
        Write-Output ('CASE: R5 ' + $prefix + ' short GUID8 fixture and 240-character pre-creation guard; PASS')
    }
    $fixture = Join-Path ([IO.Path]::GetFullPath($FixtureBaseRootPath)) (New-BindingFixtureName -Code 'p')
    $relative = '.local\ai-sessions\history\line-a\quota-source-refresh-phase7-refresh-post-reset-00000000_000000_000-' + [guid]::Empty.ToString('N') + '.json.api-request.json'
    $plan = Get-BindingFixturePathPlan -FixtureRoot $fixture -KnownDeepestRelativePath $relative
    Assert-P1B3 ($plan.LongestPath -ceq (Join-Path $fixture $relative) -and $plan.EstimatedPathLength -le 240) 'R5 known producer path budget failed.'
    $longRoot = Join-Path $fixture ('x' * 160)
    $rejected = $false
    try { $null = Get-BindingFixturePathPlan -FixtureRoot $longRoot -KnownDeepestRelativePath $relative }
    catch { $rejected = $_.Exception.Message.Contains('limit: 240') }
    Assert-P1B3 $rejected 'R5 known producer path was not rejected before fixture creation.'
    $intentional = Get-BindingFixturePathPlan -FixtureRoot $longRoot -KnownDeepestRelativePath $relative -AllowIntentionalLongPath
    Assert-P1B3 ($intentional.EstimatedPathLength -gt 260 -and -not [IO.Directory]::Exists($longRoot)) 'R5 explicit intentional-long-path exemption failed.'
    Assert-P1B3 ($null -eq $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-BindingFixturePaths' }, $true)) 'R5 recursive fixture guard remains.'
    Write-Output 'CASE: R5 known deepest path budget and explicit intentional-long-path exemption; PASS'
}

function Invoke-R6 {
    $skillPath = Join-Path (Split-Path -Parent $scriptsRoot) 'skills\codex-dispatch\SKILL.md'
    $skill = Read-DispatchUtf8Text -Path $skillPath
    Assert-P1B3 ($skill.Contains('FileShare.ReadWrite') -and $skill.Contains('FileShare.Delete') -and $skill.Contains('維持讀取前後雜湊核對')) 'R6 shared-reading contract is missing.'
    Assert-P1B3 ($skill.Contains('舊 RunRecord 未記錄 `error_stream_path` 時仍可讀取與清理') -and -not $skill.Contains('stderr 不在保存清單')) 'R6 stderr preservation contract is stale.'
    Assert-P1B3 ($skill.Contains('history\evidence-pack-<dispatchSlug>.sha256') -and -not $skill.Contains('sidecar 不在保存清單')) 'R6 advisor sidecar preservation contract is stale.'
    Assert-P1B3 ($skill.Contains('continuation_handoff_source_type') -and $skill.Contains('ResumeHandoffUnavailable') -and $skill.Contains('interruption-checkpoint')) 'R6 continuation handoff contract is missing.'
    $fixture = Join-Path ([IO.Path]::GetFullPath($FixtureBaseRootPath)) (New-P1B3FixtureName -Code 'r6')
    $null = Get-P1B3FixturePathPlan -FixtureRoot $fixture
    $history = Join-Path $fixture '.local\ai-sessions\history'
    $stderr = Join-Path $history 'fake.stderr.log'
    $record = [pscustomobject]@{ error_stream_path = $stderr; evidence_pack_path = Join-Path $history 'a\pack.md'; execution_root = $fixture; dispatch_slug = 'q' }
    $references = @(Get-CleanupRecordReferencedPaths -Record $record)
    Assert-P1B3 ($references -contains $stderr -and $references -contains (Join-Path $history 'evidence-pack-q.sha256') -and $references -contains (Join-Path $history 'evidence-pack-q.length')) 'R6 documented preservation paths differ from Cleanup behavior.'
    Write-Output 'CASE: R6 Skill preservation and continuation facts match implemented contracts; PASS'
}

switch ($Unit) {
    'P1' { Invoke-P1 }
    'H1' { Invoke-H1 }
    'H3' { Invoke-H3 }
    'H4' { Invoke-H4 }
    'Q1' { Invoke-Q1 }
    'Q2' { Invoke-Q2 }
    'Q3' { Invoke-Q3 }
    'Q4' { Invoke-Q4 }
    'Q5' { Invoke-Q5 }
    'R1' { Invoke-R1 }
    'R2' { Invoke-R2 }
    'R3' { Invoke-R3 }
    'R4' { Invoke-R4 }
    'R5' { Invoke-R5 }
    'R6' { Invoke-R6 }
    'All' {
        Invoke-P1
        Invoke-H1
        Invoke-H3
        Invoke-H4
        Invoke-Q1
        Invoke-Q2
        Invoke-Q3
        Invoke-Q4
        Invoke-Q5
        Invoke-R1
        Invoke-R2
        Invoke-R3
        Invoke-R4
        Invoke-R5
        Invoke-R6
    }
}

Write-Output ('UNIT: ' + $Unit + '; STATUS: PASS')
