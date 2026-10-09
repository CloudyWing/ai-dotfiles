function New-DispatchAdmissionFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message
    )

    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['errorCode'] = $Code
    throw $exception
}

function Get-DispatchCallerSessionIdentity {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$RequestCallerSessionId,
        [bool]$RequestCallerSessionIdProvided,
        [AllowNull()][string]$CliCallerSessionId,
        [bool]$CliCallerSessionIdProvided
    )

    $callerSessionId = $null
    $callerSessionSource = $null
    if ($RequestCallerSessionIdProvided) {
        $callerSessionId = $RequestCallerSessionId
        $callerSessionSource = 'request'
    }
    elseif ($CliCallerSessionIdProvided) {
        $callerSessionId = $CliCallerSessionId
        $callerSessionSource = 'cli'
    }
    else {
        $claudeSessionId = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_SESSION_ID')
        if (-not [string]::IsNullOrWhiteSpace($claudeSessionId)) {
            $callerSessionId = $claudeSessionId
            $callerSessionSource = 'env-claude'
        }
        else {
            $codexThreadId = [Environment]::GetEnvironmentVariable('CODEX_THREAD_ID')
            if (-not [string]::IsNullOrWhiteSpace($codexThreadId)) {
                $callerSessionId = $codexThreadId
                $callerSessionSource = 'env-codex'
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($callerSessionId)) {
        New-DispatchAdmissionFailure -Code 'CallerSessionIdMissing' -Message 'CallerSessionIdRequired：Request、CLI 參數及支援的環境變數皆未提供 caller Session ID。'
    }
    if ($callerSessionId.Length -gt 4096) {
        New-DispatchAdmissionFailure -Code 'CallerSessionIdInvalid' -Message 'CallerSessionIdInvalid：caller Session ID 長度超過上限。'
    }

    $fingerprintInput = 'codex-dispatch-caller-session-v1:' + $callerSessionId
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($fingerprintInput)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fingerprint = ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }

    return [pscustomobject]@{
        Fingerprint = $fingerprint
        Source = $callerSessionSource
    }
}

function Get-DispatchAdmissionPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceRoot)

    $sourceRootPath = [System.IO.Path]::GetFullPath($SourceRoot)
    $historyRoot = Join-Path $sourceRootPath '.local\ai-sessions\history'
    return [pscustomobject]@{
        SourceRoot = $sourceRootPath
        HistoryRoot = $historyRoot
        LedgerPath = Join-Path $historyRoot 'dispatch-admission-ledger.json'
        LockPath = Join-Path $historyRoot 'dispatch-admission.lock'
    }
}

function Open-DispatchAdmissionLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )

    $paths = Get-DispatchAdmissionPaths -SourceRoot $SourceRoot
    Assert-DispatchOutputPathNoReparsePoint -Root $paths.SourceRoot -Path $paths.LockPath
    $null = [System.IO.Directory]::CreateDirectory($paths.HistoryRoot)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $stream = [System.IO.FileStream]::new(
                $paths.LockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            return [pscustomobject]@{
                SourceRoot = $paths.SourceRoot
                HistoryRoot = $paths.HistoryRoot
                LedgerPath = $paths.LedgerPath
                LockPath = $paths.LockPath
                Stream = $stream
                Acquired = $true
            }
        }
        catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 100
        }
        catch [System.UnauthorizedAccessException] {
            New-DispatchAdmissionFailure -Code 'DispatchAdmissionLockUnavailable' -Message ('DispatchAdmissionLockUnavailable：無法取得 source root 獨占鎖。' + $paths.LockPath)
        }
    }

    New-DispatchAdmissionFailure -Code 'DispatchAdmissionLockTimeout' -Message ('DispatchAdmissionLockTimeout：等待 source root 獨占鎖逾時。' + $paths.LockPath)
}

function Close-DispatchAdmissionLock {
    [CmdletBinding()]
    param([AllowNull()][object]$Lock)

    if ($null -ne $Lock -and $null -ne $Lock.Stream) {
        $Lock.Stream.Dispose()
        $Lock.Acquired = $false
    }
}

function Get-DispatchAdmissionFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($stream)
        return ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Read-DispatchAdmissionLedger {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Lock)

    if ($null -eq $Lock.Stream -or -not $Lock.Acquired) {
        New-DispatchAdmissionFailure -Code 'DispatchAdmissionLockRequired' -Message 'DispatchAdmissionLockRequired：讀取 ledger 前必須持有獨占鎖。'
    }

    $ledgerPath = [string]$Lock.LedgerPath
    $sha256 = Get-DispatchAdmissionFileSha256 -Path $ledgerPath
    if ($null -eq $sha256) {
        return [pscustomobject]@{
            Path = $ledgerPath
            Sha256 = $null
            Document = [pscustomobject]@{
                schema = 'ai-sessions.dispatch-admission.v1'
                updated_at_utc = [DateTime]::UtcNow.ToString('o')
                entries = @()
            }
        }
    }

    try {
        $document = [System.IO.File]::ReadAllText($ledgerPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        New-DispatchAdmissionFailure -Code 'DispatchAdmissionLedgerUnverifiable' -Message ('DispatchAdmissionLedgerUnverifiable：ledger JSON 無法解析。' + $ledgerPath)
    }
    if ($null -eq $document -or [string]$document.schema -cne 'ai-sessions.dispatch-admission.v1' -or $null -eq $document.PSObject.Properties['entries']) {
        New-DispatchAdmissionFailure -Code 'DispatchAdmissionLedgerUnverifiable' -Message ('DispatchAdmissionLedgerUnverifiable：ledger schema 或 entries 欄位無效。' + $ledgerPath)
    }
    return [pscustomobject]@{
        Path = $ledgerPath
        Sha256 = $sha256
        Document = $document
    }
}

function Write-DispatchAdmissionLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Lock,
        [Parameter(Mandatory)][object]$Ledger
    )

    if ($null -eq $Lock.Stream -or -not $Lock.Acquired) {
        New-DispatchAdmissionFailure -Code 'DispatchAdmissionLockRequired' -Message 'DispatchAdmissionLockRequired：寫入 ledger 前必須持有獨占鎖。'
    }

    $currentSha256 = Get-DispatchAdmissionFileSha256 -Path ([string]$Ledger.Path)
    $expectedSha256 = $Ledger.Sha256
    if (($null -eq $expectedSha256 -and $null -ne $currentSha256) -or ($null -ne $expectedSha256 -and -not [string]::Equals([string]$currentSha256, [string]$expectedSha256, [System.StringComparison]::OrdinalIgnoreCase))) {
        New-DispatchAdmissionFailure -Code 'DispatchAdmissionLedgerChanged' -Message ('DispatchAdmissionLedgerChanged：ledger 在鎖定期間仍發生 fingerprint 漂移。' + [string]$Ledger.Path)
    }

    $Ledger.Document.updated_at_utc = [DateTime]::UtcNow.ToString('o')
    $json = ConvertTo-Json -InputObject $Ledger.Document -Depth 30
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $temporaryPath = Join-Path ([string]$Lock.HistoryRoot) ('.dispatch-admission-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backupPath = Join-Path ([string]$Lock.HistoryRoot) ('.dispatch-admission-' + [guid]::NewGuid().ToString('N') + '.bak')
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $encoding)
        $confirmedSha256 = Get-DispatchAdmissionFileSha256 -Path ([string]$Ledger.Path)
        if (($null -eq $expectedSha256 -and $null -ne $confirmedSha256) -or ($null -ne $expectedSha256 -and -not [string]::Equals([string]$confirmedSha256, [string]$expectedSha256, [System.StringComparison]::OrdinalIgnoreCase))) {
            New-DispatchAdmissionFailure -Code 'DispatchAdmissionLedgerChanged' -Message ('DispatchAdmissionLedgerChanged：ledger 在替換前發生 fingerprint 漂移。' + [string]$Ledger.Path)
        }
        if ($null -eq $expectedSha256) {
            if (Test-Path -LiteralPath ([string]$Ledger.Path)) {
                New-DispatchAdmissionFailure -Code 'DispatchAdmissionLedgerChanged' -Message ('DispatchAdmissionLedgerChanged：ledger 已被其他寫入者建立。' + [string]$Ledger.Path)
            }
            [System.IO.File]::Move($temporaryPath, [string]$Ledger.Path)
        }
        else {
            [System.IO.File]::Replace($temporaryPath, [string]$Ledger.Path, $backupPath)
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                [System.IO.File]::Delete($backupPath)
            }
        }
        $Ledger.Sha256 = Get-DispatchAdmissionFileSha256 -Path ([string]$Ledger.Path)
        return $Ledger.Sha256
    }
    finally {
        foreach ($temporaryFile in @($temporaryPath, $backupPath)) {
            if (Test-Path -LiteralPath $temporaryFile -PathType Leaf) {
                [System.IO.File]::Delete($temporaryFile)
            }
        }
    }
}

function Get-DispatchAdmissionOwnerState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Entry)

    $pidValue = 0
    if (-not [int]::TryParse([string]$Entry.process_id, [ref]$pidValue) -or $pidValue -le 0) { return 'unknown' }
    $startTimeValue = $Entry.process_start_time_utc
    $processStartTimeUtc = [DateTime]::MinValue
    if ($startTimeValue -is [DateTimeOffset]) {
        $processStartTimeUtc = $startTimeValue.UtcDateTime
    }
    elseif ($startTimeValue -is [DateTime]) {
        $processStartTimeUtc = $startTimeValue.ToUniversalTime()
    }
    else {
        $parsedStartTime = [DateTimeOffset]::MinValue
        $dateStyles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        if (-not [DateTimeOffset]::TryParse([string]$startTimeValue, [System.Globalization.CultureInfo]::InvariantCulture, $dateStyles, [ref]$parsedStartTime)) { return 'unknown' }
        $processStartTimeUtc = $parsedStartTime.UtcDateTime
    }
    if ([string]::IsNullOrWhiteSpace([string]$Entry.process_name)) { return 'unknown' }
    try {
        $process = [System.Diagnostics.Process]::GetProcessById($pidValue)
        if ($process.HasExited) { return 'ended' }
        $actualName = $process.ProcessName
        $actualStartTime = $process.StartTime.ToUniversalTime()
    }
    catch [System.ArgumentException] {
        return 'ended'
    }
    catch {
        return 'unknown'
    }
    if (-not [string]::Equals($actualName, [string]$Entry.process_name, [System.StringComparison]::OrdinalIgnoreCase)) { return 'pid-reused' }
    if ([Math]::Abs(($actualStartTime - $processStartTimeUtc).TotalSeconds) -gt 1) { return 'pid-reused' }
    return 'active'
}

function Update-DispatchAdmissionOwnerStates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Ledger)

    $changed = $false
    foreach ($entry in @($Ledger.Document.entries)) {
        if ([string]$entry.state -notin @('active', 'finished', 'cleaned', 'failed')) {
            New-DispatchAdmissionFailure -Code 'DispatchAdmissionOwnerUnknown' -Message 'DispatchAdmissionOwnerUnknown：ledger 含無法判讀的 owner 狀態，拒絕 admission 與 Cleanup。'
        }
        if ([string]$entry.state -ne 'active') { continue }
        $ownerState = Get-DispatchAdmissionOwnerState -Entry $entry
        if ($ownerState -eq 'unknown') {
            New-DispatchAdmissionFailure -Code 'DispatchAdmissionOwnerUnknown' -Message ('DispatchAdmissionOwnerUnknown：無法確認舊 owner process identity，拒絕 admission 與 Cleanup。dispatch_slug=' + [string]$entry.dispatch_slug)
        }
        if ($ownerState -in @('ended', 'pid-reused')) {
            $entry.state = 'finished'
            $entry | Add-Member -MemberType NoteProperty -Name 'finished_at_utc' -Value ([DateTime]::UtcNow.ToString('o')) -Force
            $entry | Add-Member -MemberType NoteProperty -Name 'finish_reason' -Value $ownerState -Force
            $changed = $true
        }
    }
    return $changed
}

function ConvertTo-DispatchAdmissionCanonicalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        New-DispatchAdmissionFailure -Code 'DispatchAdmissionPathInvalid' -Message 'DispatchAdmissionPathInvalid：write path 不可為空白。'
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        New-DispatchAdmissionFailure -Code 'DispatchAdmissionPathInvalid' -Message 'DispatchAdmissionPathInvalid：write path 無法正規化。'
    }
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $root.Length) { return $fullPath.TrimEnd([char[]]@('\', '/')) }
    return $fullPath
}

function Test-DispatchAdmissionPathOverlap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    $leftPath = ConvertTo-DispatchAdmissionCanonicalPath -Path $Left
    $rightPath = ConvertTo-DispatchAdmissionCanonicalPath -Path $Right
    $comparison = if (Test-IsWindowsPlatform) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if ([string]::Equals($leftPath, $rightPath, $comparison)) { return $true }
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $leftPrefix = $leftPath.TrimEnd([char[]]@('\', '/')) + $separator
    $rightPrefix = $rightPath.TrimEnd([char[]]@('\', '/')) + $separator
    return $leftPath.StartsWith($rightPrefix, $comparison) -or $rightPath.StartsWith($leftPrefix, $comparison)
}

function Get-DispatchAdmissionWritePaths {
    [CmdletBinding()]
    param(
        [string]$SourceRoot,
        [string]$ExecutionRoot,
        [ValidateSet('readonly', 'write')][string]$WriteMode,
        [string[]]$TargetPath = @(),
        [string[]]$AddDirectory = @()
    )

    $paths = New-Object 'System.Collections.Generic.List[object]'
    foreach ($directory in @($AddDirectory)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$directory)) {
            $paths.Add([pscustomobject]@{ path = (ConvertTo-DispatchAdmissionCanonicalPath -Path ([string]$directory)); kind = 'add-directory' })
        }
    }
    if ($WriteMode -eq 'write' -and -not [string]::IsNullOrWhiteSpace($SourceRoot) -and -not [string]::IsNullOrWhiteSpace($ExecutionRoot)) {
        $sourcePath = ConvertTo-DispatchAdmissionCanonicalPath -Path $SourceRoot
        $executionPath = ConvertTo-DispatchAdmissionCanonicalPath -Path $ExecutionRoot
        if ([string]::Equals($sourcePath, $executionPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            foreach ($target in @($TargetPath)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$target)) {
                    $paths.Add([pscustomobject]@{ path = (ConvertTo-DispatchAdmissionCanonicalPath -Path ([string]$target)); kind = 'direct-write' })
                }
            }
        }
    }
    return ,@($paths.ToArray())
}

function Assert-DispatchAdmissionAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Ledger,
        [Parameter(Mandatory)][string]$CallerSessionFingerprint,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$LineSlug,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$DispatchSlug,
        [Parameter(Mandatory)][ValidateSet('readonly', 'write')][string]$WriteMode,
        [object[]]$WritePaths = @()
    )

    $activeEntries = @($Ledger.Document.entries | Where-Object { [string]$_.state -eq 'active' })
    $callerEntries = @($activeEntries | Where-Object { [string]$_.caller_session_fingerprint -ceq $CallerSessionFingerprint })
    if ($WriteMode -eq 'write' -and @($callerEntries | Where-Object { [string]$_.write_mode -eq 'write' }).Count -ge 1) {
        New-DispatchAdmissionFailure -Code 'DispatchAdmissionWriteLimit' -Message ('DispatchAdmissionWriteLimit：同一 caller 已有 write admission。line_slug=' + $LineSlug)
    }
    if ($WriteMode -eq 'readonly' -and @($callerEntries | Where-Object { [string]$_.write_mode -eq 'readonly' }).Count -ge 2) {
        New-DispatchAdmissionFailure -Code 'DispatchAdmissionReadonlyLimit' -Message ('DispatchAdmissionReadonlyLimit：同一 caller 的 readonly admission 已達上限 2。line_slug=' + $LineSlug)
    }

    $historyRoot = Split-Path -Parent $Ledger.Path
    $newLineHistory = Join-Path $historyRoot $LineSlug
    foreach ($newPath in @($WritePaths | Where-Object { $null -ne $_ })) {
        $newPathIsHistoryAddDirectory = [string]$newPath.kind -ne 'direct-write' -and
            (Test-PathWithinRoot -Path ([string]$newPath.path) -Root $newLineHistory)
        foreach ($entry in $activeEntries) {
            if ([string]$entry.dispatch_slug -ceq $DispatchSlug) { continue }
            $existingLineHistory = Join-Path $historyRoot ([string]$entry.line_slug)
            foreach ($existingPath in @($entry.write_paths | Where-Object { $null -ne $_ })) {
                $existingPathIsHistoryAddDirectory = [string]$existingPath.kind -ne 'direct-write' -and
                    (Test-PathWithinRoot -Path ([string]$existingPath.path) -Root $existingLineHistory)
                $existingDirectWriteIsInNewHistory = [string]$existingPath.kind -eq 'direct-write' -and
                    (Test-PathWithinRoot -Path ([string]$existingPath.path) -Root $newLineHistory)
                $newDirectWriteIsInExistingHistory = [string]$newPath.kind -eq 'direct-write' -and
                    (Test-PathWithinRoot -Path ([string]$newPath.path) -Root $existingLineHistory)
                if ($newPathIsHistoryAddDirectory -and -not $existingDirectWriteIsInNewHistory) { continue }
                if ($existingPathIsHistoryAddDirectory -and -not $newDirectWriteIsInExistingHistory) { continue }
                if ([string]$newPath.kind -ne 'direct-write' -and [string]$existingPath.kind -ne 'direct-write') { continue }
                if (Test-DispatchAdmissionPathOverlap -Left ([string]$newPath.path) -Right ([string]$existingPath.path)) {
                    New-DispatchAdmissionFailure -Code 'DispatchAdmissionPathConflict' -Message ('DispatchAdmissionPathConflict：write path 與既有 admission 重疊。dispatch_slug=' + [string]$entry.dispatch_slug)
                }
            }
        }
    }
}

function Get-DispatchAdmissionPidProperty {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-DispatchAdmissionPidRecordRegistered {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Ledger,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][object]$Record
    )

    $recordDispatchSlug = [string](Get-DispatchAdmissionPidProperty -Object $Record -Name 'DispatchSlug')
    $recordPath = [string](Get-DispatchAdmissionPidProperty -Object $Record -Name 'Path')
    if ([string]::IsNullOrWhiteSpace($recordDispatchSlug) -or [string]::IsNullOrWhiteSpace($recordPath)) {
        return $false
    }

    foreach ($entry in @($Ledger.Document.entries)) {
        if ([string]$entry.state -cne 'active' -or
            [string]$entry.line_slug -cne $LineSlug -or
            [string]$entry.dispatch_slug -cne $recordDispatchSlug) {
            continue
        }
        $registeredPath = [string](Get-DispatchAdmissionProperty -Object $entry -Name 'pid_record_path')
        if ([string]::IsNullOrWhiteSpace($registeredPath)) { continue }
        if ([string]::Equals($registeredPath, $recordPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Assert-DispatchAdmissionLegacyPidOccupancy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Ledger,
        [AllowNull()][object]$PidCheckResult,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][ValidateSet('readonly', 'write')][string]$WriteMode
    )

    if ($null -eq $PidCheckResult) { return }
    $pidCheck = Get-DispatchAdmissionPidProperty -Object $PidCheckResult -Name 'PidCheckResult'
    if ($null -eq $pidCheck) { $pidCheck = $PidCheckResult }
    $activeRecords = Get-DispatchAdmissionPidProperty -Object $pidCheck -Name 'ActiveRecords'
    $unconfirmedRecords = Get-DispatchAdmissionPidProperty -Object $pidCheck -Name 'UnconfirmedRecords'
    if ($null -eq $activeRecords -and $null -eq $unconfirmedRecords) { return }

    $legacyActive = New-Object 'System.Collections.Generic.List[object]'
    $legacyUnconfirmed = New-Object 'System.Collections.Generic.List[object]'
    foreach ($record in @($activeRecords)) {
        $recordLineSlug = [string](Get-DispatchAdmissionPidProperty -Object $record -Name 'LineSlug')
        if (-not [string]::IsNullOrWhiteSpace($recordLineSlug) -and $recordLineSlug -cne $LineSlug) { continue }
        if (-not (Test-DispatchAdmissionPidRecordRegistered -Ledger $Ledger -LineSlug $LineSlug -Record $record)) {
            $legacyActive.Add($record)
        }
    }
    foreach ($record in @($unconfirmedRecords)) {
        $recordLineSlug = [string](Get-DispatchAdmissionPidProperty -Object $record -Name 'LineSlug')
        if (-not [string]::IsNullOrWhiteSpace($recordLineSlug) -and $recordLineSlug -cne $LineSlug) { continue }
        $identityStatus = [string](Get-DispatchAdmissionPidProperty -Object $record -Name 'IdentityStatus')
        if ($identityStatus -in @('root-process-absent', 'record-identity-mismatch')) { continue }
        if (-not (Test-DispatchAdmissionPidRecordRegistered -Ledger $Ledger -LineSlug $LineSlug -Record $record)) {
            $legacyUnconfirmed.Add($record)
        }
    }

    if ($legacyUnconfirmed.Count -gt 0) {
        $details = foreach ($record in $legacyUnconfirmed) {
            $recordPath = [string](Get-DispatchAdmissionPidProperty -Object $record -Name 'Path')
            if ([string]::IsNullOrWhiteSpace($recordPath)) { $recordPath = '<unknown-record>' }
            $recordDispatchSlug = [string](Get-DispatchAdmissionPidProperty -Object $record -Name 'DispatchSlug')
            $identityStatus = [string](Get-DispatchAdmissionPidProperty -Object $record -Name 'IdentityStatus')
            if ([string]::IsNullOrWhiteSpace($identityStatus)) { $identityStatus = 'unknown' }
            'path=' + $recordPath + '; dispatch_slug=' + $recordDispatchSlug + '; identity_status=' + $identityStatus
        }
        New-DispatchAdmissionFailure -Code 'DispatchAdmissionPidConflict' -Message ('DispatchAdmissionPidConflict：同線未登記 PID 身分無法確認，拒絕 admission。' + ($details -join '；'))
    }

    $legacyWriteCount = 0
    $legacyReadonlyCount = 0
    foreach ($record in $legacyActive) {
        $recordMode = [string](Get-DispatchAdmissionPidProperty -Object $record -Name 'WriteMode')
        if ($recordMode -ceq 'readonly') {
            $legacyReadonlyCount++
        }
        else {
            $legacyWriteCount++
        }
    }

    $occupancyConflict = ($WriteMode -eq 'write' -and $legacyActive.Count -gt 0) -or
        ($WriteMode -eq 'readonly' -and ($legacyWriteCount -gt 0 -or $legacyReadonlyCount -ge 2))
    if ($occupancyConflict) {
        $details = foreach ($record in $legacyActive) {
            $recordPath = [string](Get-DispatchAdmissionPidProperty -Object $record -Name 'Path')
            if ([string]::IsNullOrWhiteSpace($recordPath)) { $recordPath = '<unknown-record>' }
            $recordDispatchSlug = [string](Get-DispatchAdmissionPidProperty -Object $record -Name 'DispatchSlug')
            $identityStatus = [string](Get-DispatchAdmissionPidProperty -Object $record -Name 'IdentityStatus')
            if ([string]::IsNullOrWhiteSpace($identityStatus)) { $identityStatus = 'confirmed' }
            'path=' + $recordPath + '; dispatch_slug=' + $recordDispatchSlug + '; identity_status=' + $identityStatus
        }
        New-DispatchAdmissionFailure -Code 'DispatchAdmissionPidConflict' -Message ('DispatchAdmissionPidConflict：同線未登記 PID 紀錄依佔用規則拒絕 admission。' + ($details -join '；'))
    }
}

function Assert-DispatchAdmission {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][object]$CallerIdentity,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [Parameter(Mandatory)][ValidateSet('readonly', 'write')][string]$WriteMode,
        [string[]]$TargetPath = @(),
        [string[]]$AddDirectory = @(),
        [string]$ExecutionRoot
    )

    $lock = Open-DispatchAdmissionLock -SourceRoot $SourceRoot
    try {
        $ledger = Read-DispatchAdmissionLedger -Lock $lock
        $changed = Update-DispatchAdmissionOwnerStates -Ledger $ledger
        $writePaths = Get-DispatchAdmissionWritePaths -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -WriteMode $WriteMode -TargetPath $TargetPath -AddDirectory $AddDirectory
        Assert-DispatchAdmissionAllowed -Ledger $ledger -CallerSessionFingerprint ([string]$CallerIdentity.Fingerprint) -LineSlug $LineSlug -DispatchSlug $DispatchSlug -WriteMode $WriteMode -WritePaths $writePaths
        if ($changed) { $null = Write-DispatchAdmissionLedger -Lock $lock -Ledger $ledger }
        return [pscustomobject]@{
            allowed = $true
            caller_session_fingerprint = [string]$CallerIdentity.Fingerprint
            caller_session_source = [string]$CallerIdentity.Source
            write_paths = @($writePaths)
        }
    }
    finally {
        Close-DispatchAdmissionLock -Lock $lock
    }
}

function Invoke-DispatchAdmissionStart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][object]$CallerIdentity,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [Parameter(Mandatory)][ValidateSet('readonly', 'write')][string]$WriteMode,
        [object[]]$WritePaths = @(),
        [Parameter(Mandatory)][scriptblock]$PidCheckAction,
        [Parameter(Mandatory)][scriptblock]$StartAction
    )

    $lock = Open-DispatchAdmissionLock -SourceRoot $SourceRoot
    $startedProcess = $null
    $ledger = $null
    try {
        $ledger = Read-DispatchAdmissionLedger -Lock $lock
        $null = Update-DispatchAdmissionOwnerStates -Ledger $ledger
        Assert-DispatchAdmissionAllowed -Ledger $ledger -CallerSessionFingerprint ([string]$CallerIdentity.Fingerprint) -LineSlug $LineSlug -DispatchSlug $DispatchSlug -WriteMode $WriteMode -WritePaths $WritePaths
        $pidResult = & $PidCheckAction
        Assert-DispatchAdmissionLegacyPidOccupancy -Ledger $ledger -PidCheckResult $pidResult -LineSlug $LineSlug -WriteMode $WriteMode
        $blockedProperty = if ($pidResult -is [System.Collections.IDictionary]) { $pidResult['Blocked'] } else { Get-DispatchAdmissionProperty -Object $pidResult -Name 'Blocked' }
        if ($null -ne $pidResult -and [bool]$blockedProperty) {
            New-DispatchAdmissionFailure -Code 'DispatchAdmissionPidConflict' -Message ('DispatchAdmissionPidConflict：同一 dispatchSlug 已有無法續行的程序紀錄。dispatch_slug=' + $DispatchSlug)
        }
        $startedProcess = & $StartAction
        if ($null -eq $startedProcess -or [int]$startedProcess.ProcessId -le 0) {
            New-DispatchAdmissionFailure -Code 'DispatchAdmissionProcessIdentityUnknown' -Message ('DispatchAdmissionProcessIdentityUnknown：Start 未回傳可驗證的 process identity。dispatch_slug=' + $DispatchSlug)
        }
        $entries = New-Object 'System.Collections.Generic.List[object]'
        foreach ($entry in @($ledger.Document.entries)) { $entries.Add($entry) }
        $entries.Add([pscustomobject]@{
                caller_session_fingerprint = [string]$CallerIdentity.Fingerprint
                caller_session_source = [string]$CallerIdentity.Source
                process_id = [int]$startedProcess.ProcessId
                process_name = [string]$startedProcess.ProcessName
                process_start_time_utc = [string]$startedProcess.ProcessStartTimeUtc
                line_slug = $LineSlug
                dispatch_slug = $DispatchSlug
                write_mode = $WriteMode
                write_paths = @($WritePaths)
                state = 'active'
                admitted_at_utc = [DateTime]::UtcNow.ToString('o')
                run_record_path = [string](Get-DispatchAdmissionProperty -Object $startedProcess -Name 'RunRecordPath')
                pid_record_path = [string](Get-DispatchAdmissionProperty -Object $startedProcess -Name 'PidRecordPath')
            })
        $ledger.Document.entries = @($entries.ToArray())
        $null = Write-DispatchAdmissionLedger -Lock $lock -Ledger $ledger
        return [pscustomobject]@{
            Process = $startedProcess
            caller_session_fingerprint = [string]$CallerIdentity.Fingerprint
            caller_session_source = [string]$CallerIdentity.Source
            admission_status = 'admitted'
        }
    }
    catch {
        $admissionException = $_.Exception
        $startedProcessId = 0
        if ($null -ne $startedProcess) {
            $startedProcessId = [int]$startedProcess.ProcessId
        }
        else {
            $startedPidVariable = Get-Variable -Name 'DispatchAdmissionStartedPid' -Scope Script -ErrorAction SilentlyContinue
            if ($null -ne $startedPidVariable) { $startedProcessId = [int]$startedPidVariable.Value }
        }
        if ($startedProcessId -gt 0) {
            $admissionException.Data['admission_process_started'] = $true
            $admissionException.Data['admission_process_id'] = $startedProcessId
            if ($null -eq $startedProcess -and $null -ne $ledger) {
                try {
                    $processName = ''
                    $processStartTimeUtc = ''
                    try {
                        $process = [System.Diagnostics.Process]::GetProcessById($startedProcessId)
                        if (-not $process.HasExited) {
                            $processName = [string]$process.ProcessName
                            $processStartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
                        }
                    }
                    catch {
                    }
                    $entries = New-Object 'System.Collections.Generic.List[object]'
                    foreach ($entry in @($ledger.Document.entries)) { $entries.Add($entry) }
                    $entries.Add([pscustomobject]@{
                            caller_session_fingerprint = [string]$CallerIdentity.Fingerprint
                            caller_session_source = [string]$CallerIdentity.Source
                            process_id = $startedProcessId
                            process_name = $processName
                            process_start_time_utc = $processStartTimeUtc
                            line_slug = $LineSlug
                            dispatch_slug = $DispatchSlug
                            write_mode = $WriteMode
                            write_paths = @($WritePaths)
                            state = 'active'
                            admitted_at_utc = [DateTime]::UtcNow.ToString('o')
                            run_record_path = ''
                            pid_record_path = ''
                        })
                    $ledger.Document.entries = @($entries.ToArray())
                    $null = Write-DispatchAdmissionLedger -Lock $lock -Ledger $ledger
                }
                catch {
                    $admissionException.Data['admission_owner_record_write_failed'] = $true
                }
            }
        }
        throw
    }
    finally {
        Close-DispatchAdmissionLock -Lock $lock
    }
}

function Get-DispatchAdmissionProperty {
    [CmdletBinding()]
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-DispatchRecoveryNeverStarted {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Record)

    if ([string](Get-DispatchAdmissionProperty -Object $Record -Name 'launch_state') -cne 'launch-failed') { return $false }
    $failure = Get-DispatchAdmissionProperty -Object $Record -Name 'failure'
    $observation = Get-DispatchAdmissionProperty -Object $failure -Name 'observation'
    $started = Get-DispatchAdmissionProperty -Object $observation -Name 'process_started'
    if ($started -isnot [bool] -or $started) { return $false }
    if (-not [string]::IsNullOrWhiteSpace([string](Get-DispatchAdmissionProperty -Object $Record -Name 'started_at_utc'))) { return $false }
    return $true
}

function Test-DispatchUnstartedRecoveryHistoryEmpty {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExecutionRoot, [Parameter(Mandatory)][string]$DispatchSlug)

    $historyRoot = Join-Path $ExecutionRoot '.local\ai-sessions\history'
    Assert-DispatchOutputPathNoReparsePoint -Root $ExecutionRoot -Path $historyRoot
    if (-not (Test-Path -LiteralPath $historyRoot)) { return $true }
    $historyItem = Get-Item -LiteralPath $historyRoot -Force -ErrorAction Stop
    if (-not $historyItem.PSIsContainer) { return $false }

    $pendingDirectories = New-Object 'System.Collections.Generic.Stack[string]'
    $pendingDirectories.Push($historyRoot)
    while ($pendingDirectories.Count -gt 0) {
        $directory = $pendingDirectories.Pop()
        try {
            $items = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)
        }
        catch {
            return $false
        }
        foreach ($item in $items) {
            Assert-DispatchOutputPathNoReparsePoint -Root $ExecutionRoot -Path $item.FullName
            if ($item.PSIsContainer) {
                $pendingDirectories.Push($item.FullName)
                continue
            }
            if ($item.Name -match '^codex-exec-.*\.jsonl$' -or
                [string]::Equals($item.Name, ('codex-thread-' + $DispatchSlug + '.txt'), [StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }
        }
    }
    return $true
}

function Read-DispatchUnstartedRecoveryRecord {
    [CmdletBinding()]
    param([string]$Path, [string]$SourceRoot, [string]$ExecutionRoot, [string]$LineSlug, [string]$DispatchSlug)

    $resolved = Resolve-AbsolutePath $Path
    $runRoot = Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    if (-not [string]::Equals((Split-Path -Parent $resolved), $runRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'RunRecord 路徑不屬於指定 line／dispatch。' }
    Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $resolved
    $record = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $resolved)
    if (-not (Test-DispatchRecoveryNeverStarted -Record $record)) { return $null }
    foreach ($pair in @(@('schema','ai-sessions.dispatch-run.v1'), @('line_slug',$LineSlug), @('dispatch_slug',$DispatchSlug))) {
        if ([string](Get-DispatchAdmissionProperty -Object $record -Name $pair[0]) -cne [string]$pair[1]) { throw ('DispatchAdmissionOwnerUnverifiable：未啟動 RunRecord 的 ' + $pair[0] + ' 不符。') }
    }
    foreach ($pair in @(@('source_root',$SourceRoot), @('execution_root',$ExecutionRoot))) {
        $value = [string](Get-DispatchAdmissionProperty -Object $record -Name $pair[0])
        if ([string]::IsNullOrWhiteSpace($value) -or -not [string]::Equals((Resolve-AbsolutePath $value), (Resolve-AbsolutePath $pair[1]), [StringComparison]::OrdinalIgnoreCase)) { throw ('DispatchAdmissionOwnerUnverifiable：未啟動 RunRecord 的 ' + $pair[0] + ' 不符。') }
    }
    $id = [string](Get-DispatchAdmissionProperty -Object $record -Name 'run_id')
    $parsedId = [guid]::Empty
    $created = [DateTimeOffset]::MinValue
    if (-not [guid]::TryParseExact($id, 'D', [ref]$parsedId) -or [IO.Path]::GetFileName($resolved) -cne ($id + '.json') -or
        -not [DateTimeOffset]::TryParse([string](Get-DispatchAdmissionProperty -Object $record -Name 'created_at_utc'), [ref]$created)) { throw 'DispatchAdmissionOwnerUnverifiable：未啟動 RunRecord 的 run_id 或建立時間不符。' }
    $pidPath = [string](Get-DispatchAdmissionProperty -Object $record -Name 'pid_record_path')
    if (-not [string]::IsNullOrWhiteSpace($pidPath)) {
        if (-not (Test-PathWithinRoot -Path $pidPath -Root (Join-Path $SourceRoot '.local\ai-sessions\history'))) { throw 'CleanupRunRecordBoundary：未啟動紀錄的 PID path 越界。' }
        Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $pidPath
    }
    if (-not (Test-DispatchUnstartedRecoveryHistoryEmpty -ExecutionRoot $ExecutionRoot -DispatchSlug $DispatchSlug)) { return $null }
    return $record
}

function Assert-DispatchRecoveryOwner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Lock,
        [Parameter(Mandatory)][object]$Ledger,
        [Parameter(Mandatory)][object]$CallerIdentity,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ExecutionRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [AllowNull()][string]$RunRecordPath
    )

    $knownDispatch = @($Ledger.Document.entries | Where-Object { [string]$_.dispatch_slug -ceq $DispatchSlug })
    if ($knownDispatch.Count -gt 0) {
        return Assert-DispatchAdmissionOwner -Lock $Lock -Ledger $Ledger -CallerIdentity $CallerIdentity -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunRecordPath $RunRecordPath
    }
    if ([string]::IsNullOrWhiteSpace($RunRecordPath)) {
        New-DispatchAdmissionFailure -Code 'DispatchAdmissionOwnerUnverifiable' -Message ('DispatchAdmissionOwnerUnverifiable：舊派工缺少 RunRecord。dispatch_slug=' + $DispatchSlug)
    }

    Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $RunRecordPath
    $unstartedRecord = Read-DispatchUnstartedRecoveryRecord -Path $RunRecordPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    if ($null -ne $unstartedRecord) { return $null }
    $record = Read-DispatchRunRecord -Path $RunRecordPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    $cutover = [DateTimeOffset]::ParseExact('2026-10-02T21:53:06Z', 'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    $created = [DateTimeOffset]::MinValue
    $started = [DateTimeOffset]::MinValue
    if ([string]$record.launch_state -cne 'started' -or
        $null -ne $record.PSObject.Properties['caller_session_fingerprint'] -or
        -not [DateTimeOffset]::TryParse([string]$record.created_at_utc, [ref]$created) -or
        -not [DateTimeOffset]::TryParse([string]$record.started_at_utc, [ref]$started) -or
        $created -ge $cutover -or $started -ge $cutover -or $started -lt $created) {
        New-DispatchAdmissionFailure -Code 'DispatchAdmissionOwnerUnverifiable' -Message ('DispatchAdmissionOwnerUnverifiable：RunRecord 無法證明派工在 C17 前啟動。dispatch_slug=' + $DispatchSlug)
    }

    $historyRoot = Join-Path (Resolve-AbsolutePath -Path $SourceRoot) '.local\ai-sessions\history'
    $pidPath = Resolve-AbsolutePath -Path ([string]$record.pid_record_path)
    Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $pidPath
    if (-not [string]::Equals((Split-Path -Parent $pidPath), $historyRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $pidPath -PathType Leaf)) {
        New-DispatchAdmissionFailure -Code 'DispatchAdmissionOwnerUnverifiable' -Message ('DispatchAdmissionOwnerUnverifiable：舊派工 PID 紀錄位置或內容不完整。dispatch_slug=' + $DispatchSlug)
    }
    $pidRecord = Get-KeyValueFile -Path $pidPath
    foreach ($field in @('pid', 'root-pid', 'root-process-name', 'root-started-at-utc', 'identity-status', 'identity-verified', 'process-tree-scope', 'work-root', 'line-slug', 'dispatch-slug', 'write-mode', 'started-at-utc')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-DispatchAdmissionProperty -Object $pidRecord -Name $field))) {
            New-DispatchAdmissionFailure -Code 'DispatchAdmissionOwnerUnverifiable' -Message ('DispatchAdmissionOwnerUnverifiable：舊派工 PID 紀錄缺少欄位。dispatch_slug=' + $DispatchSlug + '; field=' + $field)
        }
    }
    $rootPidText = [string](Get-DispatchAdmissionProperty -Object $pidRecord -Name 'root-pid')
    $rootPid = 0
    $recordPid = 0
    $pidStarted = [DateTimeOffset]::MinValue
    $rootStarted = [DateTimeOffset]::MinValue
    if (-not [int]::TryParse($rootPidText, [ref]$rootPid) -or $rootPid -le 0 -or
        -not [int]::TryParse([string](Get-DispatchAdmissionProperty -Object $pidRecord -Name 'pid'), [ref]$recordPid) -or $recordPid -ne $rootPid -or
        -not [DateTimeOffset]::TryParse([string](Get-DispatchAdmissionProperty -Object $pidRecord -Name 'started-at-utc'), [ref]$pidStarted) -or
        -not [DateTimeOffset]::TryParse([string](Get-DispatchAdmissionProperty -Object $pidRecord -Name 'root-started-at-utc'), [ref]$rootStarted) -or
        $pidStarted.Offset -ne [TimeSpan]::Zero -or $rootStarted.Offset -ne [TimeSpan]::Zero -or
        $pidStarted -lt $created -or $pidStarted -gt $started -or $rootStarted -lt $created -or $rootStarted -gt $pidStarted -or
        [string](Get-DispatchAdmissionProperty -Object $pidRecord -Name 'identity-status') -cne 'confirmed' -or
        [string](Get-DispatchAdmissionProperty -Object $pidRecord -Name 'identity-verified') -notmatch '^(?i:true)$' -or
        [string](Get-DispatchAdmissionProperty -Object $pidRecord -Name 'process-tree-scope') -cne 'pid-and-descendants' -or
        -not [string]::Equals([string](Get-DispatchAdmissionProperty -Object $pidRecord -Name 'work-root'), (Resolve-AbsolutePath -Path $SourceRoot), [StringComparison]::OrdinalIgnoreCase) -or
        [string](Get-DispatchAdmissionProperty -Object $pidRecord -Name 'line-slug') -cne $LineSlug -or
        [string](Get-DispatchAdmissionProperty -Object $pidRecord -Name 'dispatch-slug') -cne $DispatchSlug -or
        $null -ne (Get-DispatchAdmissionProperty -Object $pidRecord -Name 'caller-session-fingerprint')) {
        New-DispatchAdmissionFailure -Code 'DispatchAdmissionOwnerUnverifiable' -Message ('DispatchAdmissionOwnerUnverifiable：舊派工 PID 紀錄身分不符。dispatch_slug=' + $DispatchSlug)
    }
    return $null
}

function Assert-DispatchAdmissionOwner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Lock,
        [Parameter(Mandatory)][object]$Ledger,
        [Parameter(Mandatory)][object]$CallerIdentity,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [AllowNull()][string]$RunRecordPath
    )

    $null = Update-DispatchAdmissionOwnerStates -Ledger $Ledger
    $matches = @($Ledger.Document.entries | Where-Object { [string]$_.line_slug -ceq $LineSlug -and [string]$_.dispatch_slug -ceq $DispatchSlug })
    if ($matches.Count -eq 0) {
        New-DispatchAdmissionFailure -Code 'DispatchAdmissionOwnerUnverifiable' -Message ('DispatchAdmissionOwnerUnverifiable：找不到對應的 caller owner 記錄。dispatch_slug=' + $DispatchSlug)
    }
    $entry = $matches[-1]
    if ([string]$entry.caller_session_fingerprint -cne [string]$CallerIdentity.Fingerprint) {
        New-DispatchAdmissionFailure -Code 'DispatchAdmissionOwnerMismatch' -Message ('DispatchAdmissionOwnerMismatch：Cleanup／Collect caller owner 不符。dispatch_slug=' + $DispatchSlug)
    }
    if (-not [string]::IsNullOrWhiteSpace($RunRecordPath)) {
        if (-not (Test-Path -LiteralPath $RunRecordPath -PathType Leaf)) {
            New-DispatchAdmissionFailure -Code 'DispatchAdmissionOwnerUnverifiable' -Message ('DispatchAdmissionOwnerUnverifiable：RunRecord 不存在。dispatch_slug=' + $DispatchSlug)
        }
        try {
            $runRecord = [System.IO.File]::ReadAllText($RunRecordPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        }
        catch {
            New-DispatchAdmissionFailure -Code 'DispatchAdmissionOwnerUnverifiable' -Message ('DispatchAdmissionOwnerUnverifiable：RunRecord 無法解析。dispatch_slug=' + $DispatchSlug)
        }
        if ([string]$runRecord.caller_session_fingerprint -cne [string]$CallerIdentity.Fingerprint) {
            New-DispatchAdmissionFailure -Code 'DispatchAdmissionOwnerMismatch' -Message ('DispatchAdmissionOwnerMismatch：RunRecord owner 不符。dispatch_slug=' + $DispatchSlug)
        }
    }
    return $entry
}

function Get-DispatchAdmissionContainedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath)

    if ([System.IO.Path]::IsPathRooted($RelativePath) -or [string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath.IndexOf([char]0) -ge 0 -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        New-DispatchAdmissionFailure -Code 'DispatchCollectPathInvalid' -Message 'DispatchCollectPathInvalid：Collect 相對路徑越界或格式無效。'
    }
    $rootPath = [System.IO.Path]::GetFullPath($Root)
    $volumeRoot = [System.IO.Path]::GetPathRoot($rootPath)
    if (-not [string]::Equals($rootPath, $volumeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rootPath = $rootPath.TrimEnd([char[]]@('\', '/'))
    }
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootPath ($RelativePath -replace '/', '\')))
    $comparison = if (Test-IsWindowsPlatform) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $rootPrefix = if ($rootPath.EndsWith([System.IO.Path]::DirectorySeparatorChar.ToString(), [System.StringComparison]::Ordinal) -or $rootPath.EndsWith([System.IO.Path]::AltDirectorySeparatorChar.ToString(), [System.StringComparison]::Ordinal)) { $rootPath } else { $rootPath + [System.IO.Path]::DirectorySeparatorChar }
    if (-not $candidate.StartsWith($rootPrefix, $comparison)) {
        New-DispatchAdmissionFailure -Code 'DispatchCollectPathInvalid' -Message 'DispatchCollectPathInvalid：Collect 相對路徑超出 root。'
    }

    $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        New-DispatchAdmissionFailure -Code 'DispatchCollectPathInvalid' -Message 'DispatchCollectPathInvalid：Collect root 為 reparse point，拒絕寫入。'
    }
    $relativeSegments = $candidate.Substring($rootPrefix.Length).Split([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar), [System.StringSplitOptions]::RemoveEmptyEntries)
    $currentPath = $rootPath
    foreach ($segment in $relativeSegments) {
        $currentPath = Join-Path $currentPath $segment
        if (-not (Test-Path -LiteralPath $currentPath)) { break }
        $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            New-DispatchAdmissionFailure -Code 'DispatchCollectPathInvalid' -Message ('DispatchCollectPathInvalid：Collect 路徑包含 reparse point，拒絕寫入。path=' + $currentPath)
        }
    }
    return $candidate
}

function Get-DispatchAdmissionBaselineFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Baseline, [Parameter(Mandatory)][string]$RelativePath)

    foreach ($file in @($Baseline.files)) {
        if ([string]::Equals([string]$file.path, $RelativePath, [System.StringComparison]::OrdinalIgnoreCase)) { return $file }
    }
    return $null
}

function Get-DispatchAdmissionTargetState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ exists = $false; sha256 = $null }
    }
    return [pscustomobject]@{ exists = $true; sha256 = Get-DispatchAdmissionFileSha256 -Path $Path }
}

function Invoke-DispatchSourceIntegration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DispatchRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Path,
        [Parameter(Mandatory)][object]$Baseline,
        [Parameter(Mandatory)][object]$CallerIdentity,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [AllowNull()][string]$RunRecordPath
    )

    $sourceRootPath = [System.IO.Path]::GetFullPath($SourceRoot)
    $dispatchRootPath = [System.IO.Path]::GetFullPath($DispatchRoot)
    $lock = Open-DispatchAdmissionLock -SourceRoot $sourceRootPath
    $operations = New-Object 'System.Collections.Generic.List[object]'
    $applied = New-Object 'System.Collections.Generic.List[object]'
    $integrationCommitted = $false
    $cleanupWarnings = New-Object 'System.Collections.Generic.List[string]'
    try {
        $ledger = Read-DispatchAdmissionLedger -Lock $lock
        $owner = Assert-DispatchRecoveryOwner -Lock $lock -Ledger $ledger -CallerIdentity $CallerIdentity -SourceRoot $sourceRootPath -ExecutionRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunRecordPath $RunRecordPath
        $relativePaths = @($Path | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
        foreach ($relativePath in $relativePaths) {
            $baselineFile = Get-DispatchAdmissionBaselineFile -Baseline $Baseline -RelativePath $relativePath
            if ($null -eq $baselineFile) {
                New-DispatchAdmissionFailure -Code 'DispatchCollectBaselineMissing' -Message ('DispatchCollectBaselineMissing：baseline 缺少預定整合路徑。path=' + $relativePath)
            }
            $sourcePath = Get-DispatchAdmissionContainedPath -Root $sourceRootPath -RelativePath $relativePath
            $dispatchPath = Get-DispatchAdmissionContainedPath -Root $dispatchRootPath -RelativePath $relativePath
            $expectedExists = [bool]$baselineFile.exists
            $expectedSha256 = if ($expectedExists) { [string]$baselineFile.sha256 } else { $null }
            $sourceState = Get-DispatchAdmissionTargetState -Path $sourcePath
            if ([bool]$sourceState.exists -ne $expectedExists -or ($expectedExists -and [string]$sourceState.sha256 -ine $expectedSha256)) {
                New-DispatchAdmissionFailure -Code 'DispatchSourceDrift' -Message ('DispatchSourceDrift：來源路徑自 baseline 後已變更，保留 dispatch worktree。path=' + $relativePath)
            }
            $dispatchState = Get-DispatchAdmissionTargetState -Path $dispatchPath
            if (-not $expectedExists -and -not $dispatchState.exists) { continue }
            if ($expectedExists -and $dispatchState.exists -and [string]$dispatchState.sha256 -ieq $expectedSha256) { continue }
            $kind = if (-not $dispatchState.exists) { 'delete' } elseif (-not $expectedExists) { 'add' } else { 'replace' }
            $operations.Add([pscustomobject]@{
                    relative_path = $relativePath
                    source_path = $sourcePath
                    dispatch_path = $dispatchPath
                    expected_exists = $expectedExists
                    expected_sha256 = $expectedSha256
                    kind = $kind
                })
        }

        foreach ($operation in $operations) {
            $parent = Split-Path -Parent ([string]$operation.source_path)
            $null = [System.IO.Directory]::CreateDirectory($parent)
            if ($operation.kind -eq 'delete') {
                $backupPath = Join-Path $parent ('.dispatch-collect-' + [guid]::NewGuid().ToString('N') + '.bak')
                $sourceState = Get-DispatchAdmissionTargetState -Path ([string]$operation.source_path)
                if (-not $sourceState.exists -or [string]$sourceState.sha256 -ine [string]$operation.expected_sha256) {
                    New-DispatchAdmissionFailure -Code 'DispatchSourceDrift' -Message ('DispatchSourceDrift：刪除前來源 fingerprint 已變更，保留 dispatch worktree。path=' + [string]$operation.relative_path)
                }
                [System.IO.File]::Move([string]$operation.source_path, $backupPath)
                $applied.Add([pscustomobject]@{ operation = $operation; backup_path = $backupPath; kind = 'delete' })
            }
            else {
                $temporaryPath = Join-Path $parent ('.dispatch-collect-' + [guid]::NewGuid().ToString('N') + '.tmp')
                $backupPath = Join-Path $parent ('.dispatch-collect-' + [guid]::NewGuid().ToString('N') + '.bak')
                $sourceState = Get-DispatchAdmissionTargetState -Path ([string]$operation.source_path)
                if ([bool]$sourceState.exists -ne [bool]$operation.expected_exists -or ([bool]$operation.expected_exists -and [string]$sourceState.sha256 -ine [string]$operation.expected_sha256)) {
                    New-DispatchAdmissionFailure -Code 'DispatchSourceDrift' -Message ('DispatchSourceDrift：替換前來源 fingerprint 已變更，保留 dispatch worktree。path=' + [string]$operation.relative_path)
                }
                [System.IO.File]::WriteAllBytes($temporaryPath, [System.IO.File]::ReadAllBytes([string]$operation.dispatch_path))
                if ($operation.expected_exists) {
                    [System.IO.File]::Replace($temporaryPath, [string]$operation.source_path, $backupPath)
                    $applied.Add([pscustomobject]@{ operation = $operation; backup_path = $backupPath; kind = 'replace' })
                }
                else {
                    [System.IO.File]::Move($temporaryPath, [string]$operation.source_path)
                    $applied.Add([pscustomobject]@{ operation = $operation; backup_path = $null; kind = 'add' })
                }
            }
        }

        $integrationCommitted = $true
        foreach ($item in $applied) {
            if (-not [string]::IsNullOrWhiteSpace([string]$item.backup_path) -and (Test-Path -LiteralPath ([string]$item.backup_path) -PathType Leaf)) {
                try {
                    [System.IO.File]::Delete([string]$item.backup_path)
                }
                catch {
                    $cleanupWarnings.Add([string]$item.backup_path)
                }
            }
        }
        return [pscustomobject]@{
            status = 'applied'
            caller_session_fingerprint = [string]$CallerIdentity.Fingerprint
            caller_session_source = [string]$CallerIdentity.Source
            line_slug = $LineSlug
            dispatch_slug = $DispatchSlug
            source_root = $sourceRootPath
            applied_paths = @($operations | ForEach-Object { [string]$_.relative_path })
            cleanup_warnings = @($cleanupWarnings.ToArray())
            worktree_preserved = $true
        }
    }
    catch {
        for ($index = $applied.Count - 1; -not $integrationCommitted -and $index -ge 0; $index--) {
            $item = $applied[$index]
            $sourcePath = [string]$item.operation.source_path
            try {
                switch ([string]$item.kind) {
                    'add' {
                        if (Test-Path -LiteralPath $sourcePath -PathType Leaf) { [System.IO.File]::Delete($sourcePath) }
                    }
                    'replace' {
                        if (Test-Path -LiteralPath ([string]$item.backup_path) -PathType Leaf) {
                            [System.IO.File]::Replace([string]$item.backup_path, $sourcePath, $null)
                        }
                    }
                    'delete' {
                        if (Test-Path -LiteralPath ([string]$item.backup_path) -PathType Leaf) {
                            [System.IO.File]::Move([string]$item.backup_path, $sourcePath)
                        }
                    }
                }
            }
            catch {
                $_.Exception.Data['sourceIntegrationRollbackFailed'] = $true
            }
        }
        throw
    }
    finally {
        Close-DispatchAdmissionLock -Lock $lock
    }
}
