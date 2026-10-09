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
            return ConvertFrom-DispatchJson -Content (Get-Content -LiteralPath $path -Raw -Encoding UTF8)
        }
        catch {
            throw "Preflight 輸出格式錯誤：$path；$($_.Exception.Message)"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionRoot)) {
        throw 'Start 必須提供 PreflightResultPath 或 ExecutionRoot。續行請由 Dispatch result 的 preflightResultPath（preflight_result_path）取得。'
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

function New-TargetsOutsideRepositoryPromptDirective {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Preflight
    )

    $targetPaths = @(Get-DispatchResultPropertyValue -Object $Preflight -Names @('targetsOutsideRepository'))
    if ($targetPaths.Count -eq 0) {
        return $null
    }

    $pathList = @($targetPaths | ForEach-Object { '- ' + [string]$_ }) -join [Environment]::NewLine
    return '[唯讀目標讀取方式]' + [Environment]::NewLine +
        '以下目標不在 dispatch worktree repository 內或已被 gitignore 排除。請直接讀取列出的檔案，不經 Git 狀態盤點：' + [Environment]::NewLine +
        $pathList
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

        [string]$LauncherPath,

        [string]$ExitSidecarPath,

        [string]$LineSlug,

        [string]$DispatchSlug,

        [string]$RunId,

        [AllowEmptyString()]
        [string]$SourceRoot,

        [AllowEmptyString()]
        [string]$ExecutionRoot,

        [string[]]$TargetPath
    )

    $timestamp = [datetime]::UtcNow.ToString('yyyyMMdd_HHmmss_fff')
    if (Test-IsWindowsPlatform) {
        if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
            $LauncherPath = Join-Path -Path $HistoryRoot -ChildPath ('codex-launch-' + $timestamp + '.cmd')
        }
        $argumentsText = ($CodexArguments | ForEach-Object { ConvertTo-CmdArgument -Value $_ }) -join ' '
        $contentLines = @(
            '@echo off'
            ('call ' + (ConvertTo-CmdArgument -Value $CodexExecutable) + ' ' + $argumentsText + ' < ' + (ConvertTo-CmdArgument -Value $PromptPath) + ' > ' + (ConvertTo-CmdArgument -Value $EventPath) + ' 2> ' + (ConvertTo-CmdArgument -Value $ErrorPath))
        )
        if (-not [string]::IsNullOrWhiteSpace($ExitSidecarPath)) {
            $sidecarLiteral = $ExitSidecarPath.Replace("'", "''")
            $lineSlugLiteral = $LineSlug.Replace("'", "''")
            $dispatchSlugLiteral = $DispatchSlug.Replace("'", "''")
            $runIdLiteral = $RunId.Replace("'", "''")
            $powershellCommand = "`$ErrorActionPreference='Stop';`$p='$sidecarLiteral';`$d=[IO.Path]::GetDirectoryName(`$p);`$t=Join-Path `$d ([guid]::NewGuid().ToString('D')+'.exit.tmp');try{`$o=[ordered]@{schema='ai-sessions.dispatch-exit.v1';line_slug='$lineSlugLiteral';dispatch_slug='$dispatchSlugLiteral';run_id='$runIdLiteral';process_exit_code=[int]`$env:CODEX_DISPATCH_EXIT_CODE;exit_code_status='known'};`$e=New-Object Text.UTF8Encoding(`$false);[IO.File]::WriteAllText(`$t,(`$o|ConvertTo-Json -Compress),`$e);if([IO.File]::Exists(`$p)){[IO.File]::Replace(`$t,`$p,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move(`$t,`$p)}}catch{if([IO.File]::Exists(`$t)){[IO.File]::Delete(`$t)};exit 1}"
            $contentLines += @(
                'set "_codex_exit=%errorlevel%"'
                'set "CODEX_DISPATCH_EXIT_CODE=%_codex_exit%"'
                ('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ' + (ConvertTo-CmdArgument -Value $powershellCommand))
                'set "_sidecar_write_exit=%errorlevel%"'
                'if not "%_sidecar_write_exit%"=="0" exit /b %_codex_exit%'
            )
        }
        $contentLines += 'exit /b %_codex_exit%'
        if ([string]::IsNullOrWhiteSpace($ExitSidecarPath)) {
            $contentLines[$contentLines.Count - 1] = 'exit /b %errorlevel%'
        }
        $content = $contentLines -join "`r`n"
        Write-Utf8NoBom -Path $LauncherPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath -Content ($content + "`r`n")
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
    $codexCommandLine = ("'" + $CodexExecutable.Replace("'", "'\\''") + "'") + ' ' + $argumentsText + ' < ' + ("'" + $PromptPath.Replace("'", "'\\''") + "'") + ' > ' + ("'" + $EventPath.Replace("'", "'\\''") + "'") + ' 2> ' + ("'" + $ErrorPath.Replace("'", "'\\''") + "'")
    $contentLines = @(
        '#!/bin/sh'
        $codexCommandLine
    )
    if (-not [string]::IsNullOrWhiteSpace($ExitSidecarPath)) {
        $sidecarShellPath = "'" + $ExitSidecarPath.Replace("'", "'\\''") + "'"
        $sidecarJsonTemplate = '{"schema":"ai-sessions.dispatch-exit.v1","line_slug":"' + $LineSlug.Replace("'", "'\\''") + '","dispatch_slug":"' + $DispatchSlug.Replace("'", "'\\''") + '","run_id":"' + $RunId.Replace("'", "'\\''") + '","process_exit_code":%s,"exit_code_status":"known"}'
        $contentLines += @(
            '_codex_exit=$?'
            ('_sidecar_path=' + $sidecarShellPath)
            '_sidecar_dir=$(dirname -- "$_sidecar_path")'
            '_sidecar_tmp="$_sidecar_dir/.codex-exit-$$.tmp"'
            ("printf '" + $sidecarJsonTemplate + "\n' " + '"$_codex_exit"' + ' > ' + '"$_sidecar_tmp"')
            '_sidecar_write_exit=$?'
            'if [ "$_sidecar_write_exit" -eq 0 ]; then mv -f -- "$_sidecar_tmp" "$_sidecar_path"; _sidecar_write_exit=$?; fi'
            'if [ "$_sidecar_write_exit" -ne 0 ]; then rm -f -- "$_sidecar_tmp"; fi'
            'exit "$_codex_exit"'
        )
    }
    else {
        $contentLines[1] = 'exec ' + $contentLines[1]
    }
    $content = $contentLines -join "
"
    Write-Utf8NoBom -Path $LauncherPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath -Content ($content + "
")
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

function Ensure-StartEvidenceFiles {
    param(
        [Parameter(Mandatory)]
        [string[]]$Path,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [string[]]$TargetPath = @()
    )

    foreach ($evidencePath in $Path) {
        $resolvedEvidencePath = Resolve-DispatchOutputPath -CandidatePath $evidencePath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
        if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
            Write-Utf8NoBom -Path $resolvedEvidencePath -Content '' -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
        }
    }
}

function Write-StartPidRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ExecutionRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [Parameter(Mandatory)][ValidateSet('readonly', 'write')][string]$WriteMode,
        [AllowNull()][psobject]$Snapshot,
        [AllowNull()][string]$CallerSessionFingerprint,
        [AllowNull()][string]$CallerSessionSource
    )

    $processName = [string](Get-OptionalObjectProperty -Object $Snapshot -Name 'ProcessName')
    if ([string]::IsNullOrWhiteSpace($processName)) { $processName = 'unknown' }
    $parentProcessId = [string](Get-OptionalObjectProperty -Object $Snapshot -Name 'ParentProcessId')
    $parentProcessIdAvailable = Get-OptionalObjectProperty -Object $Snapshot -Name 'ParentProcessIdAvailable'
    if ([string]::IsNullOrWhiteSpace($parentProcessId) -or ($null -ne $parentProcessIdAvailable -and -not [bool]$parentProcessIdAvailable)) { $parentProcessId = 'unknown' }
    $startedAtUtc = 'unknown'
    $creationUtc = Get-OptionalObjectProperty -Object $Snapshot -Name 'CreationUtc'
    if ($null -ne $creationUtc) {
        try {
            $startedAtUtc = ([datetime]$creationUtc).ToUniversalTime().ToString('o')
        }
        catch {
            $startedAtUtc = 'unknown'
        }
    }
    $identityStatus = [string](Get-OptionalObjectProperty -Object $Snapshot -Name 'IdentityStatus')
    if ([string]::IsNullOrWhiteSpace($identityStatus)) { $identityStatus = 'unknown' }
    $identityVerified = [string](Get-OptionalObjectProperty -Object $Snapshot -Name 'IdentityVerified')
    if (-not [string]::Equals($identityVerified, 'true', [StringComparison]::OrdinalIgnoreCase)) { $identityVerified = 'false' }
    $processGroupId = [string](Get-OptionalObjectProperty -Object $Snapshot -Name 'ProcessGroupId')
    if ([string]::IsNullOrWhiteSpace($processGroupId)) { $processGroupId = 'unknown' }
    if ([string]::IsNullOrWhiteSpace($CallerSessionFingerprint) -and $null -ne $script:CallerSessionIdentity) {
        $CallerSessionFingerprint = [string]$script:CallerSessionIdentity.Fingerprint
        $CallerSessionSource = [string]$script:CallerSessionIdentity.Source
    }

    $pidContent = @(
        ('pid=' + $ProcessId)
        ('root-pid=' + $ProcessId)
        ('root-process-name=' + $processName)
        ('root-parent-pid=' + $parentProcessId)
        ('root-started-at-utc=' + $startedAtUtc)
        ('identity-status=' + $identityStatus)
        ('identity-verified=' + $identityVerified)
        ('process-tree-scope=' + $(if (Test-IsWindowsPlatform) { 'pid-and-descendants' } else { 'process-group' }))
        ('process-tree-query=' + $(if (-not (Test-IsWindowsPlatform)) { 'ps PGID 成員' } elseif ($null -ne $parentProcessIdAvailable -and -not [bool]$parentProcessIdAvailable) { 'unavailable (.NET fallback)' } else { 'Win32_Process.ParentProcessId' }))
        ('process-group-id=' + $processGroupId)
        ('work-root=' + $SourceRoot)
        ('line-slug=' + $LineSlug)
        ('dispatch-slug=' + $DispatchSlug)
        ('write-mode=' + $WriteMode)
        ('caller-session-fingerprint=' + $(if ([string]::IsNullOrWhiteSpace($CallerSessionFingerprint)) { 'unknown' } else { $CallerSessionFingerprint }))
        ('caller-session-source=' + $(if ([string]::IsNullOrWhiteSpace($CallerSessionSource)) { 'unknown' } else { $CallerSessionSource }))
        ('started-at-utc=' + [datetime]::UtcNow.ToString('o'))
    ) -join "
"
    Write-Utf8NoBom -Path $Path -Content ($pidContent + "
") -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath @()
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
            $queryStatus = [string](Get-OptionalObjectProperty -Object $currentResult -Name 'QueryStatus')
            if ($queryStatus -eq 'unavailable') {
                return New-ProcessTreeCleanupResult -CleanupStatus 'unverified-processes-remain' -TerminationExecuted $terminationExecuted -ErrorMessage ('未執行進程終止；程序查詢來源皆不可用：' + [string](Get-OptionalObjectProperty -Object $currentResult -Name 'RawQueryError'))
            }
            $parentProcessIdsAvailable = Get-OptionalObjectProperty -Object $currentResult -Name 'ParentProcessIdsAvailable'
            if ($null -ne $parentProcessIdsAvailable -and -not [bool]$parentProcessIdsAvailable) {
                return New-ProcessTreeCleanupResult -CleanupStatus 'unverified-processes-remain' -TerminationExecuted $terminationExecuted -ErrorMessage ('未執行進程終止；備援查詢沒有父程序資訊：' + [string](Get-OptionalObjectProperty -Object $currentResult -Name 'RawQueryError'))
            }
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
        $remainingQueryStatus = [string](Get-OptionalObjectProperty -Object $remainingResult -Name 'QueryStatus')
        if ($remainingQueryStatus -eq 'unavailable') {
            return New-ProcessTreeCleanupResult -CleanupStatus 'unverified-processes-remain' -TerminationExecuted $terminationExecuted -ErrorMessage ('終止後無法確認程序樹狀態；程序查詢來源皆不可用：' + [string](Get-OptionalObjectProperty -Object $remainingResult -Name 'RawQueryError'))
        }
        $remainingParentIdsAvailable = Get-OptionalObjectProperty -Object $remainingResult -Name 'ParentProcessIdsAvailable'
        if ($null -ne $remainingParentIdsAvailable -and -not [bool]$remainingParentIdsAvailable) {
            return New-ProcessTreeCleanupResult -CleanupStatus 'unverified-processes-remain' -TerminationExecuted $terminationExecuted -ErrorMessage ('終止後無法確認程序樹狀態；備援查詢沒有父程序資訊：' + [string](Get-OptionalObjectProperty -Object $remainingResult -Name 'RawQueryError'))
        }
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
        [string]$CleanupError,
        [string]$RelaySource,
        [Nullable[bool]]$RelayTimedOut,
        [Nullable[int]]$RelayTimeoutSeconds
    )

    $processExitText = if ($null -eq $ProcessExitCode) { 'not-started-or-unknown' } else { [string]$ProcessExitCode }
    $cleanupErrorText = if ([string]::IsNullOrWhiteSpace($CleanupError)) { '<none>' } else { $CleanupError }
    $relaySourceText = if ([string]::IsNullOrWhiteSpace($RelaySource)) { '<none>' } else { $RelaySource }
    $relayTimedOutText = if ($null -eq $RelayTimedOut) { '<none>' } else { [string]$RelayTimedOut }
    $relayTimeoutSecondsText = if ($null -eq $RelayTimeoutSeconds) { '<none>' } else { [string]$RelayTimeoutSeconds }
    return ('phase={0}; source={1}; timedOut={2}; timeoutSeconds={3}; eventStreamPath={4}; errorStreamPath={5}; lastMessagePath={6}; threadIdPath={7}; pidRecordPath={8}; launcherPath={9}; processExitCode={10}; cleanupStatus={11}; cleanupError={12}' -f `
        $Phase,
        $relaySourceText,
        $relayTimedOutText,
        $relayTimeoutSecondsText,
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

function Initialize-DispatchOutputFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$HistoryRoot,

        [AllowEmptyString()]
        [string]$SourceRoot,

        [AllowEmptyString()]
        [string]$ExecutionRoot,

        [string[]]$TargetPath
    )

    $resolvedPath = Resolve-DispatchOutputPath -CandidatePath $Path -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    $parentPath = Split-Path -Parent $resolvedPath
    $null = New-DispatchOutputDirectory -Path $parentPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    Assert-DispatchOutputPathNoReparsePoint -Root $HistoryRoot -Path $resolvedPath

    if (Test-Path -LiteralPath $resolvedPath) {
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
            Throw-DispatchOutputFailure -Code 'DispatchOutputTargetCollision' -Message "Start output target is not a file: $resolvedPath"
        }
    }
    else {
        Write-Utf8NoBom -Path $resolvedPath -Content '' -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    }

    Assert-DispatchOutputPathNoReparsePoint -Root $HistoryRoot -Path $resolvedPath
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        Throw-DispatchOutputFailure -Code 'DispatchOutputTargetCollision' -Message "Start output target was not created: $resolvedPath"
    }

    return $resolvedPath
}

function New-DispatchStartHashClaim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ExecutionRoot,
        [Parameter(Mandatory)][string]$SourceHistoryRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [Parameter(Mandatory)][string]$ScopePlanPath,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$RootRunId,
        [string[]]$TargetPath
    )

    $lock = Open-DispatchAdmissionLock -SourceRoot $SourceRoot
    try {
        $path = Get-ScopePlanHashRecordPath -SourceHistoryRoot $SourceHistoryRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $path
        $existed = Test-Path -LiteralPath $path -PathType Leaf
        $path = Write-ScopePlanHashRecordIfMissing -SourceHistoryRoot $SourceHistoryRoot -DispatchSlug $DispatchSlug -LineSlug $LineSlug -ScopePlanPath $ScopePlanPath -RootRunId $RootRunId -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
        $record = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $path)
        if ([string]$record.root_run_id -cne $RootRunId) { throw 'ScopePlan root run 與本次 Start 不一致。' }
        return [pscustomobject]@{ Path = $path; Created = -not $existed; Sha256 = Get-FileSha256 -Path $path; RunId = $RunId; RootRunId = $RootRunId }
    }
    finally { Close-DispatchAdmissionLock -Lock $lock }
}

function Invoke-Start {
    $script:DispatchAdmissionStartedPid = 0
    $script:DispatchAdmissionSnapshotError = $null
    $preflight = $null
    $sourceRootPath = $null
    $executionRootPath = $null
    $lineSlugValue = $null
    $dispatchSlugValue = $null
    $writeModeValue = 'readonly'
    $promptSourcePathValue = $null
    $promptSourceSha256Value = $null
    $promptTransferPathValue = $null
    $promptTransferSha256Value = $null
    $promptPathValue = $null
    $inspectResultPathValue = $null
    $codexExecutable = $null
    $historyRoot = $null
    $sourceHistoryRoot = $null
    $eventPath = $null
    $errorPath = $null
    $lastMessagePathValue = $null
    $threadPath = $null
    $pidPath = $null
    $launcherPath = $null
    $exitSidecarPathValue = $null
    $launcher = $null
    $startInfo = $null
    $process = $null
    $relay = $null
    $startedSnapshot = $null
    $startedSnapshotError = $null
    $processStarted = $false
    $waitForProcessExit = $false
    $waitForProcessExitVariable = Get-Variable -Scope Script -Name 'WaitForStartProcessExit' -ErrorAction SilentlyContinue
    if ($null -ne $waitForProcessExitVariable) {
        $waitForProcessExit = [bool]$waitForProcessExitVariable.Value
    }
    $skipProcessCleanup = $false
    $phase = 'preparation'
    $cleanupStatus = 'not-started'
    $cleanupError = $null
    $requestedProfileValue = $Profile
    $effectiveProfileValue = $Profile
    $sessionModeValue = $SessionMode
    $advisorActivationDecision = $null
    $activationModeValue = 'none'
    $authorizationSourceValue = $null
    $primaryRemainingPercentValue = $null
    $requiredSourceValue = $null
    $dispatchKindValue = $DispatchKind
    $beforeSnapshotPathValue = $null
    $beforeSnapshotObject = $null
    $afterSnapshotPathValue = if ([string]::IsNullOrWhiteSpace($QuotaAfterPath)) { $null } else { $QuotaAfterPath }
    $afterSnapshotSha256Value = $null
    $scopePlan = $null
    $scopePlanPathValue = $null
    $scopePlanParentPathValue = $null
    $scopePlanParentSha256Value = $null
    $scopePlanParentRunIdValue = $null
    $scopePlanRootRunIdValue = $null
    $createdScopePlanHashPath = $null
    $createdScopePlanHashSha256 = $null
    $scopePlanSelectionValue = 'root'
    $continuationContextPath = $null
    $continuationContextMessage = $null
    $continuationHandoffSourceType = $null
    $previousRun = $null
    $runRecord = $null
    $runRecordPathValue = $null
    $interruptionCheckpointPathValue = $null
    $latestColdStartFailure = $null
    $attemptParentRunIdValue = $null
    $resumeAnchorRunIdValue = $null
    $skippedAttemptsValue = @()
    $parentOptionsModel = $null
    $parentOptionsGate = $null
    $processGate = $null
    $effectiveCodexHomePath = $null
    $prepareBinding = $null
    $prepareResultPathValue = $null
    $prepareResultSha256Value = $null
    $prepareStatusValue = $null
    $beforeSnapshotSha256Value = $null
    $beforeSnapshotCapturedAtUtcValue = $null
    $baselineBinding = $null
    $baselineResolution = $null
    $baselineQueryPathValue = $null
    $baselineQuerySha256Value = $null
    $baselineQueryLocationValue = $null
    $runId = [guid]::NewGuid().ToString('D')
    $evidencePackInfo = $null
    $requestedModelEvidence = $null
    $requestedReasoningEffortEvidence = $null
    $resolvedModelEvidence = $null
    $resolvedReasoningEffortEvidence = $null
    $modelEvidence = $null
    $profileConfigPathValue = $null
    $profileConfigSha256AtCompare = $null
    $codexHomeEvidencePath = $null
    $resolvedModelValue = $null
    $resolvedReasoningEffortValue = $null
    $resumeDiagnostics = $null
    $startedAtUtcValue = $null
    $preflightPathValue = $null
    $preflightSha256Value = $null
    $createdAtUtcValue = $null
    $failureReasonCode = $null
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
    if ([string]::IsNullOrWhiteSpace($PreflightResultPath)) {
        throw 'Start 必須提供 PreflightResultPath，供 RunRecord 綁定原始證據。續行請由 Dispatch result 的 preflightResultPath（preflight_result_path）取得。'
    }
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
    if ($TaskType -eq 'advisor-consult' -and $AdvisorRequestSource -ne 'user-explicit') {
        throw 'AdvisorAuthorizationRequired：advisor-consult 必須由呼叫端明確提供 user-explicit 授權；process_started=false'
    }
    $sourceRootPath = Resolve-AbsolutePath -Path $sourceRootValue
    $executionRootPath = Resolve-AbsolutePath -Path $executionRootValue
    if (-not (Test-Path -LiteralPath $executionRootPath -PathType Container)) {
        throw "executionRoot 不存在或不是目錄：$executionRootPath"
    }
    $dispatchStageBinding = Get-DispatchScriptVariableValue -Name 'DispatchStageBinding'
    if ($null -ne $dispatchStageBinding) {
        $dispatchRootForBinding = [string](Get-DispatchJsonProperty -Object $preflight -Name 'dispatchRoot')
        if ([string]::IsNullOrWhiteSpace($dispatchRootForBinding)) {
            $dispatchRootForBinding = $DispatchRoot
        }
        $null = Assert-DispatchStageBinding -Binding $dispatchStageBinding -Stage 'start' -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -DispatchRoot $dispatchRootForBinding -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -TargetPath @($TargetPath) -ResultPath $ResultPath -PreflightResultPath $PreflightResultPath -PrepareResultPath $PrepareResultPath -QuotaBeforePath $QuotaBeforePath -QuotaAfterPath $QuotaAfterPath
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
    $promptSourcePathValue = Resolve-AbsolutePath -Path $PromptPath
    if (-not (Test-PathWithinRoot -Path $promptSourcePathValue -Root $sourceRootPath) -and -not (Test-PathWithinRoot -Path $promptSourcePathValue -Root $executionRootPath)) {
        throw ('PromptSourceBoundary：Prompt 必須位於 sourceRoot 或 executionRoot 內；received=' + $promptSourcePathValue + '; sourceRoot=' + $sourceRootPath + '; executionRoot=' + $executionRootPath)
    }
    if (-not (Test-Path -LiteralPath $promptSourcePathValue -PathType Leaf)) {
        throw "Prompt 檔案不存在：$promptSourcePathValue"
    }
    $promptPathValue = $promptSourcePathValue

    $historyRoot = Join-Path -Path $executionRootPath -ChildPath '.local\ai-sessions\history'
    $sourceHistoryRoot = Join-Path -Path $sourceRootPath -ChildPath '.local\ai-sessions\history'
    $effectiveCodexHomePath = Resolve-CodexHomeForEvidence -CodexHomePath $CodexHome
    $preflightPreparePathProperty = $preflight.PSObject.Properties['prepareResultPath']
    $preflightPrepareShaProperty = $preflight.PSObject.Properties['prepareResultSha256']
    $preflightPreparePathValue = if ($null -eq $preflightPreparePathProperty -or $null -eq $preflightPreparePathProperty.Value) { $null } else { [string]$preflightPreparePathProperty.Value }
    $preflightPrepareShaValue = if ($null -eq $preflightPrepareShaProperty -or $null -eq $preflightPrepareShaProperty.Value) { $null } else { [string]$preflightPrepareShaProperty.Value }
    if (-not [string]::IsNullOrWhiteSpace($PrepareResultPath) -and -not [string]::IsNullOrWhiteSpace($preflightPreparePathValue) -and -not [string]::Equals((Resolve-AbsolutePath -Path $PrepareResultPath), (Resolve-AbsolutePath -Path $preflightPreparePathValue), [System.StringComparison]::OrdinalIgnoreCase)) {
        $phase = 'preparation'
        throw 'PrepareArtifactMismatch：Start 的 PrepareResultPath 與 Preflight result 不一致。'
    }
    if (-not [string]::IsNullOrWhiteSpace($PrepareResultPath)) {
        $prepareResultPathValue = Resolve-AbsolutePath -Path $PrepareResultPath
    }
    elseif (-not [string]::IsNullOrWhiteSpace($preflightPreparePathValue)) {
        $prepareResultPathValue = Resolve-AbsolutePath -Path $preflightPreparePathValue
    }
    if ([string]::Equals($sourceRootPath, $executionRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (-not [string]::IsNullOrWhiteSpace($prepareResultPathValue)) {
            $prepareBinding = Resolve-PrepareResultBinding -Path $prepareResultPathValue -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -ExpectedSha256 $preflightPrepareShaValue
            if ($prepareBinding.Status -ne 'not-required') {
                $phase = 'preparation'
                throw 'PrepareArtifactMismatch：direct-write 的 Prepare result status 必須是 not-required。'
            }
        }
        else {
            $directPrepareRootInfo = Get-PrepareRootInfo -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -DispatchRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue
            $directPrepareDocument = New-PrepareDocument -RootInfo $directPrepareRootInfo -Status 'not-required' -RequestPathValue $null -RequestSha256Value $null -EffectiveCodexHome $effectiveCodexHomePath -Artifacts @() -ErrorValue $null
            $directPreparePath = Get-PrepareResultTargetPath -RootInfo $directPrepareRootInfo -PrepareResultPathValue $null -ResultPathValue $null
            $directPrepareWritten = Write-PrepareResultDocument -Path $directPreparePath -Document $directPrepareDocument
            $prepareResultPathValue = $directPrepareWritten.Path
            $prepareResultSha256Value = $directPrepareWritten.Sha256
            $prepareBinding = [pscustomobject]@{
                Path               = $directPrepareWritten.Path
                Sha256             = $directPrepareWritten.Sha256
                Status             = 'not-required'
                Document           = $directPrepareWritten.Document
                Artifacts          = @()
                EffectiveCodexHome = $effectiveCodexHomePath
            }
        }
        if ($null -ne $prepareBinding) {
            $prepareResultPathValue = $prepareBinding.Path
            $prepareResultSha256Value = $prepareBinding.Sha256
            $prepareStatusValue = $prepareBinding.Status
        }
        else {
            $prepareStatusValue = 'not-required'
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($prepareResultPathValue)) {
            $phase = 'preparation'
            throw 'PrepareRequired：worktree Start 必須提供 status=Prepared 的 PrepareResultPath。續行請由 Dispatch result 的 prepareResultPath（prepare_result_path）取得。'
        }
        $prepareBinding = Resolve-PrepareResultBinding -Path $prepareResultPathValue -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -ExpectedSha256 $preflightPrepareShaValue
        if ($prepareBinding.Status -ne 'Prepared') {
            $phase = 'preparation'
            throw 'PrepareArtifactMismatch：worktree Start 的 Prepare result status 必須是 Prepared。'
        }
        $prepareResultSha256Value = $prepareBinding.Sha256
        $prepareStatusValue = $prepareBinding.Status
    }
    $runDirectory = Get-DispatchRunDirectory -SourceRoot $sourceRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue
    if ([string]::IsNullOrWhiteSpace($ResumeThreadId)) {
        $latestColdStartFailure = Resolve-LatestColdStartFailure -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue
        if ($null -ne $latestColdStartFailure) {
            $attemptParentRunIdValue = $latestColdStartFailure.run_id
        }
    }
    $timestamp = [datetime]::UtcNow.ToString('yyyyMMdd_HHmmss_fff') + '-' + $runId
    $eventPath = Join-Path -Path $historyRoot -ChildPath ('codex-exec-' + $timestamp + '.jsonl')
    $errorPath = Join-Path -Path $historyRoot -ChildPath ('codex-exec-' + $timestamp + '.stderr.log')
    $exitSidecarPathValue = Join-Path -Path $historyRoot -ChildPath ('codex-exit-' + $timestamp + '.json')
    $exitSidecarPathValue = Resolve-DispatchOutputPath -CandidatePath $exitSidecarPathValue -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
    $generatedLastMessagePath = Join-Path $historyRoot ('codex-last-message-' + $timestamp + '.md')
    $lastMessagePathValue = $generatedLastMessagePath
    if (-not [string]::IsNullOrWhiteSpace($ResumeThreadId)) {
        $previousRun = Resolve-PreviousDispatchRun -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -ResumeThreadId $ResumeThreadId -LastMessagePath $LastMessagePath
        $attemptParentRunIdValue = $previousRun.ChainTailRecord.run_id
        $resumeAnchorRunIdValue = $previousRun.AnchorRecord.run_id
        $skippedAttemptsValue = @($previousRun.SkippedAttempts)
        $continuationContextPath = Get-DispatchJsonProperty -Object $previousRun -Name 'HandoffPath'
        if ($null -eq $continuationContextPath) {
            $continuationContextPath = $previousRun.AnchorRecord.last_message_path
        }
        $continuationContextMessage = $previousRun.Message
        $continuationHandoffSourceType = Get-DispatchJsonProperty -Object $previousRun -Name 'HandoffSourceType'
        if ($null -eq $continuationHandoffSourceType) {
            $continuationHandoffSourceType = 'last-message'
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($LastMessagePath)) {
        $lastMessagePathValue = Resolve-AbsolutePath $LastMessagePath
    }
    $directReadonly = $writeModeValue -eq 'readonly' -and [string](Get-DispatchJsonProperty -Object $preflight -Name 'gitOrigin') -eq 'not-applicable' -and [string]::Equals($sourceRootPath, $executionRootPath, [StringComparison]::OrdinalIgnoreCase)
    $sandboxValue = if ($TaskType -eq 'advisor-consult' -or $directReadonly) { 'read-only' } else { 'workspace-write' }
    $anchorParentOptions = $null
    if ($null -ne $previousRun) {
        $anchorParentOptions = Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'parent_options'
        if ($null -eq $anchorParentOptions) {
            $phase = 'preparation'
            throw 'ParentOptionsUnknown：anchor RunRecord 缺少 parent_options，拒絕以當次呼叫重建續行選項。'
        }
    }
    $parentOptionsResolution = Resolve-ParentOptionsForStart -Profile $effectiveProfileValue -ProfileProvided ([bool]$script:ProfileExplicit) -Sandbox $sandboxValue -WorkingDirectory $executionRootPath -AddDirectory $AddDirectory -Search ([bool]$Search) -AddDirectoryProvided ([bool]$script:AddDirectoryExplicit) -SearchProvided ([bool]$script:SearchExplicit) -CodexParentOption $CodexParentOption -CodexParentOptionProvided ([bool]$script:CodexParentOptionExplicit) -Anchor $anchorParentOptions
    if (-not [string]::IsNullOrWhiteSpace([string]$parentOptionsResolution.code)) {
        $phase = 'preparation'
        throw ($parentOptionsResolution.code + '：父層選項差異欄位=' + (($parentOptionsResolution.differences) -join ','))
    }
    $parentOptionsModel = $parentOptionsResolution.model
    $effectiveProfileValue = [string](Get-DispatchJsonProperty -Object $parentOptionsModel -Name 'profile')
    Assert-AdvisorContract -RequestedProfile $effectiveProfileValue -TaskType $TaskType -DispatchKind $dispatchKindValue -WriteMode $writeModeValue
    if (-not (Test-PathWithinRoot $lastMessagePathValue $executionRootPath)) { throw 'LastMessagePath 必須位於 executionRoot 內。' }
    $lastMessagePathValue = Resolve-DispatchOutputPath -CandidatePath $lastMessagePathValue -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
    if (Test-Path -LiteralPath $lastMessagePathValue) { throw 'LastMessagePath 已存在，拒絕覆寫證據。' }
    $threadPath = $ThreadIdPath
    if ([string]::IsNullOrWhiteSpace($threadPath)) {
        $threadPath = Join-Path -Path $historyRoot -ChildPath ('codex-thread-' + $dispatchSlugValue + '.txt')
    }
    else {
        $threadPath = Resolve-AbsolutePath -Path $threadPath
    }
    $threadPath = Resolve-DispatchOutputPath -CandidatePath $threadPath -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
    $pidPath = $PidRecordPath
    if ([string]::IsNullOrWhiteSpace($pidPath)) {
        $pidPath = Join-Path -Path $sourceHistoryRoot -ChildPath ('codex-pid-' + $timestamp + '.txt')
    }
    else {
        $pidPath = Resolve-AbsolutePath -Path $pidPath
    }
    $pidPath = Resolve-DispatchOutputPath -CandidatePath $pidPath -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
    if (Test-IsWindowsPlatform) {
        $launcherPath = Join-Path -Path $historyRoot -ChildPath ('codex-launch-' + $timestamp + '.cmd')
    }
    else {
        $launcherPath = Join-Path -Path $historyRoot -ChildPath ('codex-launch-' + $timestamp + '.sh')
    }
    $null = New-DispatchOutputDirectory -Path $historyRoot -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
    $null = New-DispatchOutputDirectory -Path $sourceHistoryRoot -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
    $promptTransfer = Copy-DispatchPromptToExecutionHistory -PromptPath $promptSourcePathValue -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -HistoryRoot $historyRoot -Timestamp $timestamp
    $promptTransferPathValue = $promptTransfer.Path
    $promptSourceSha256Value = $promptTransfer.SourceSha256
    $promptTransferSha256Value = $promptTransfer.DestinationSha256
    $promptPathValue = Resolve-DispatchOutputPath -CandidatePath (Join-Path -Path $historyRoot -ChildPath ('codex-prompt-' + $timestamp + '.md')) -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
    $inspectResultPathValue = Resolve-DispatchOutputPath -CandidatePath (Join-Path -Path $historyRoot -ChildPath ('inspect-result-' + $dispatchSlugValue + '-' + $timestamp + '.json')) -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
    $preflightPathValue = Resolve-AbsolutePath -Path $PreflightResultPath
    $preflightSha256Value = Get-FileSha256 -Path $preflightPathValue
    $createdAtUtcValue = [datetime]::UtcNow.ToString('o')
    $isWorktreeStart = -not [string]::Equals($sourceRootPath, $executionRootPath, [StringComparison]::OrdinalIgnoreCase)
    if ($isWorktreeStart) {
        $baselinePathProperty = $preflight.PSObject.Properties['baselinePath']
        $baselineSha256Property = $preflight.PSObject.Properties['baselineSha256']
        $baselineQueryPathValue = if ($null -eq $baselinePathProperty -or $null -eq $baselinePathProperty.Value) { $null } else { [string]$baselinePathProperty.Value }
        $baselineQuerySha256Value = if ($null -eq $baselineSha256Property -or $null -eq $baselineSha256Property.Value) { $null } else { [string]$baselineSha256Property.Value }
        $baselineQueryLocationValue = 'Preflight.baselinePath,Preflight.baselineSha256'
        $baselineResolution = [ordered]@{
            status = 'pending'
            requested_path = $baselineQueryPathValue
            requested_sha256 = $baselineQuerySha256Value
            query_location = $baselineQueryLocationValue
            path = $null
            sha256 = $null
            error = $null
        }
    }
    else {
        $baselineQueryLocationValue = 'direct-write'
        $baselineResolution = [ordered]@{
            status = 'not-applicable'
            requested_path = $null
            requested_sha256 = $null
            query_location = $baselineQueryLocationValue
            path = $null
            sha256 = $null
            error = $null
        }
    }
    $runRecord = [pscustomobject]@{
        schema = 'ai-sessions.dispatch-run.v1'
        run_id = $runId
        dispatch_slug = $dispatchSlugValue
        line_slug = $lineSlugValue
        source_root = $sourceRootPath
        execution_root = $executionRootPath
        previous_run_id = if ($null -eq $previousRun) { $null } else { $previousRun.AnchorRecord.run_id }
        attempt_parent_run_id = $attemptParentRunIdValue
        resume_anchor_run_id = $resumeAnchorRunIdValue
        skipped_attempts = @($skippedAttemptsValue)
        requested_thread_id = if ([string]::IsNullOrWhiteSpace($ResumeThreadId)) { $null } else { $ResumeThreadId }
        thread_id = $null
        event_stream_path = $eventPath
        error_stream_path = $errorPath
        last_message_path = $lastMessagePathValue
        continuation_handoff_source_type = $continuationHandoffSourceType
        interruption_checkpoint_path = $null
        scope_plan_path = $null
        scope_plan_sha256 = $null
        scope_plan_parent_path = $null
        scope_plan_parent_sha256 = $null
        scope_plan_parent_run_id = $null
        scope_plan_root_run_id = $null
        scope_plan_selection = 'root'
        preflight_result_path = $preflightPathValue
        preflight_sha256 = $preflightSha256Value
        prepare_result_path = $prepareResultPathValue
        prepare_result_sha256 = $prepareResultSha256Value
        prepare_status = $prepareStatusValue
        created_at_utc = $createdAtUtcValue
        started_at_utc = $null
        launch_state = 'prepared'
        failure = $null
        resume_diagnostics = $null
        model_evidence = ConvertTo-DispatchEvidenceGroup -Evidence $null -Field 'model'
        reasoning_effort_evidence = ConvertTo-DispatchEvidenceGroup -Evidence $null -Field 'model_reasoning_effort'
        baseline_path = $null
        baseline_sha256 = $null
        baseline_resolution = $baselineResolution
        pid_record_path = $pidPath
        thread_id_path = $threadPath
        launcher_path = $launcherPath
        process_exit_code_sidecar_path = $exitSidecarPathValue
        prompt_path = $promptPathValue
        prompt_source_path = $promptSourcePathValue
        prompt_source_sha256 = $promptSourceSha256Value
        prompt_transfer_path = $promptTransferPathValue
        prompt_transfer_sha256 = $promptTransferSha256Value
        inspect_result_path = $inspectResultPathValue
        profile_config_path = $null
        codex_home = $effectiveCodexHomePath
        effective_codex_home = $effectiveCodexHomePath
        evidence_pack_path = $null
        evidence_pack_sha256 = $null
        evidence_pack_length = $null
        advisor_request_source = $AdvisorRequestSource
        advisor_activation_decision = $null
        advisor_activation_granted = $false
        advisor_activation_notice = $null
        advisor_hard_limit_percent = $null
        advisor_unit_estimate_percent = $null
        activationMode = $activationModeValue
        authorizationSource = $authorizationSourceValue
        primaryRemainingPercent = $primaryRemainingPercentValue
        requiredSource = $requiredSourceValue
        parent_options = $null
        parent_options_sha256 = $null
        parent_options_status = 'unknown'
         quota_before_path = $null
         quota_before_sha256 = $null
         quota_before_captured_at_utc = $null
         quota_before_freshness = $null
         quota_before_observations = $null
         quota_before_service_rejection = $null
         quota_after_path = $null
         quota_after_sha256 = $null
         quota_observation_state = $null
         quota_observation_path = $null
         quota_observation_write_failures = @()
        request_path = if ($null -eq $script:RequestContext) { $null } else { [string]$script:RequestContext.path }
        request_sha256 = if ($null -eq $script:RequestContext) { $null } else { [string]$script:RequestContext.sha256 }
        request_operation = if ($null -eq $script:RequestContext) { $null } else { [string](Get-DispatchJsonProperty -Object $script:RequestContext.document -Name 'operation') }
        caller_session_fingerprint = if ($null -eq $script:CallerSessionIdentity) { $null } else { [string]$script:CallerSessionIdentity.Fingerprint }
        caller_session_source = if ($null -eq $script:CallerSessionIdentity) { $null } else { [string]$script:CallerSessionIdentity.Source }
     }
    try {
        $runRecordPathValue = Write-DispatchRunRecord -Record $runRecord
    }
    catch {
        $runRecord = $null
        throw
    }
    if ($isWorktreeStart) {
        try {
            $baselineBinding = Resolve-DispatchBaselineBinding -Preflight $preflight -SourceRoot $sourceRootPath -DispatchRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -BaseSha (Get-RequiredPreflightProperty $preflight 'baseSha')
            $baselineResolution.status = 'confirmed'
            $baselineResolution.path = $baselineBinding.Path
            $baselineResolution.sha256 = $baselineBinding.Sha256
            $baselineResolution.error = $null
        }
        catch {
            $failureReasonCode = 'BaselineUnknown'
            $baselineResolution.status = 'failed'
            $baselineResolution.path = $null
            $baselineResolution.sha256 = $null
            $baselineResolution.error = $_.Exception.Message
            throw
        }
    }
    $codexExecutable = Get-CodexExecutablePath -ConfiguredPath $CodexPath
    $startProcessResult = Get-PidCheckResult -SourceRoot $sourceRootPath -LineSlug $lineSlugValue -WriteMode $writeModeValue
    $startBlockingPidRecords = @(Get-BlockingDispatchPidRecords -PidCheckResult $startProcessResult -DispatchSlug $dispatchSlugValue)
    $startActiveRecords = @($startBlockingPidRecords | Where-Object { $_.IdentityStatus -eq 'confirmed' })
    $startUnconfirmedRecords = @($startBlockingPidRecords | Where-Object { $_.IdentityStatus -ne 'confirmed' })
    $processGate = [ordered]@{
        status = if ($null -eq $startProcessResult) { 'unknown' } elseif (@($startActiveRecords).Count -gt 0) { 'alive' } elseif (@($startUnconfirmedRecords).Count -gt 0) { 'unknown' } elseif ([bool](Get-DispatchJsonProperty -Object $startProcessResult -Name 'Blocked')) { 'alive' } else { 'stopped' }
        pid_check = $startProcessResult
        active_records = @($startActiveRecords)
        unconfirmed_records = @($startUnconfirmedRecords)
        stopped_evidence = $null -ne $startProcessResult -and @($startActiveRecords).Count -eq 0 -and @($startUnconfirmedRecords).Count -eq 0 -and -not [bool](Get-DispatchJsonProperty -Object $startProcessResult -Name 'Blocked')
    }
    if ($processGate.status -ne 'stopped') {
        $phase = 'preparation'
        if ($startBlockingPidRecords.Count -gt 0) {
            $failureReasonCode = 'ProcessAlive'
            throw (New-DispatchPidIdentityBlockedMessage -DispatchSlug $dispatchSlugValue -Records $startBlockingPidRecords)
        }
        throw ('ProcessAlive：Start process gate 未確認 stopped；evidence=' + (ConvertTo-Json -InputObject $processGate -Depth 20 -Compress))
    }
    if (-not [string]::IsNullOrWhiteSpace($ResumeThreadId)) {
        $sessionModeValue = 'continuation'
    }
    $requestedModelEvidence = New-RequestedDispatchEvidence -Value $Model -Field 'Model'
    $requestedReasoningEffortEvidence = New-RequestedDispatchEvidence -Value $ReasoningEffort -Field 'ReasoningEffort'
    $effectiveCodexHomePath = Resolve-CodexHomeForEvidence -CodexHomePath $CodexHome
    $codexHomeEvidencePath = $effectiveCodexHomePath
    $profileConfigPathValue = Resolve-ProfileConfigPath -CodexHome $codexHomeEvidencePath -Profile $effectiveProfileValue
    $profileEvidence = Read-ProfileModelEvidence -ConfigPath $profileConfigPathValue -Profile $effectiveProfileValue
    $resolvedModelEvidence = $profileEvidence.model
    $resolvedReasoningEffortEvidence = $profileEvidence.reasoning_effort
    $profileConfigSha256AtCompare = $profileEvidence.config_sha256
    $resolvedModelValue = Get-DispatchEvidenceValue -Evidence $resolvedModelEvidence
    $resolvedReasoningEffortValue = Get-DispatchEvidenceValue -Evidence $resolvedReasoningEffortEvidence
    $requestedModelValue = Get-DispatchEvidenceValue -Evidence $requestedModelEvidence
    $requestedReasoningEffortValue = Get-DispatchEvidenceValue -Evidence $requestedReasoningEffortEvidence
    $modelEvidence = New-ModelEvidence -RequestedModel $requestedModelEvidence -ResolvedModel $resolvedModelEvidence -RuntimeModel $null -RequestedReasoningEffort $requestedReasoningEffortEvidence -ResolvedReasoningEffort $resolvedReasoningEffortEvidence -RuntimeReasoningEffort $null
    if ($null -ne $requestedModelValue -and $null -ne $resolvedModelValue -and -not [string]::Equals($requestedModelValue, $resolvedModelValue, [StringComparison]::Ordinal)) {
        $phase = 'profile-evidence'
        throw "RequestedResolutionMismatch：requested model=$requestedModelValue；resolved model=$resolvedModelValue。"
    }
    if ($null -ne $requestedReasoningEffortValue -and $null -ne $resolvedReasoningEffortValue -and -not [string]::Equals($requestedReasoningEffortValue, $resolvedReasoningEffortValue, [StringComparison]::Ordinal)) {
        $phase = 'profile-evidence'
        throw "RequestedResolutionMismatch：requested reasoning effort=$requestedReasoningEffortValue；resolved reasoning effort=$resolvedReasoningEffortValue。"
    }
    if ($TaskType -eq 'advisor-consult') {
        if ($dispatchKindValue -ne 'resource') {
            throw 'AdvisorImplementationProfileRejected：advisor-consult 必須使用 DispatchKind=resource。'
        }
        if ($writeModeValue -ne 'readonly') {
            throw 'AdvisorImplementationProfileRejected：advisor-consult 必須使用 read-only 派遣。'
        }
        if ([string]::IsNullOrWhiteSpace($EvidencePackPath)) {
            throw 'RequiredParameterMissing：advisor-consult 必須提供 EvidencePackPath。'
        }
        if ([string]::IsNullOrWhiteSpace($AdvisorConsultReportPath)) {
            throw 'RequiredParameterMissing：advisor-consult 必須提供 AdvisorConsultReportPath。'
        }
        $AdvisorConsultReportPath = Get-AdvisorConsultReportPath -Path $AdvisorConsultReportPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue
        if ([string]::IsNullOrWhiteSpace($QuotaAfterPath)) {
            throw 'RequiredParameterMissing：advisor-consult 必須提供可在執行期間更新的 QuotaAfterPath。'
        }
        $effectiveAddDirectory = @((Get-DispatchJsonProperty -Object $parentOptionsModel -Name 'add_directory'))
        if ($effectiveAddDirectory.Count -gt 0) {
            throw 'AdvisorImplementationProfileRejected：advisor-consult 不允許額外 --add-dir，執行端只可讀取 evidence pack。'
        }
        $evidencePackInfo = Test-AdvisorEvidencePack -Path $EvidencePackPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue
        $evidenceHashPath = Join-Path -Path $historyRoot -ChildPath ('evidence-pack-' + $dispatchSlugValue + '.sha256')
        $evidenceLengthPath = Join-Path -Path $historyRoot -ChildPath ('evidence-pack-' + $dispatchSlugValue + '.length')
    }
    if ($TaskType -ne 'advisor-consult' -and -not [string]::IsNullOrWhiteSpace($AdvisorConsultReportPath)) {
        throw 'AdvisorConsultReportPath 只適用 TaskType=advisor-consult。'
    }
    if ($TaskType -ne 'advisor-consult' -and -not [string]::IsNullOrWhiteSpace($EvidencePackPath)) {
        throw 'EvidencePackPath 只適用 TaskType=advisor-consult。'
    }

    if ($null -ne $dispatchStageBinding) {
        $beforeSnapshotPathValue = Resolve-AbsolutePath -Path ([string](Get-DispatchJsonProperty -Object $dispatchStageBinding -Name 'quota_before_path'))
        if (-not [string]::Equals($beforeSnapshotPathValue, (Resolve-AbsolutePath -Path $QuotaBeforePath), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'DispatchStageBindingConflict：Start QuotaBeforePath 與 stage binding 不一致。'
        }
        $beforeSnapshotSha256Value = Get-FileSha256 -Path $beforeSnapshotPathValue
        $expectedBeforeSnapshotSha256 = [string](Get-DispatchScriptVariableValue -Name 'DispatchQuotaBeforeSha256')
        if ($expectedBeforeSnapshotSha256 -notmatch '^[a-fA-F0-9]{64}$' -or
            -not [string]::Equals($beforeSnapshotSha256Value, $expectedBeforeSnapshotSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'QuotaBeforeSnapshotHashMismatch：Dispatch 建立的 before quota snapshot SHA-256 與 Start 讀取結果不一致。'
        }
        $beforeSnapshotObject = Read-QuotaSnapshot -Path $beforeSnapshotPathValue
    }
    else {
        $beforeSnapshotPathValue = Get-OrCreateQuotaSnapshot -Path $QuotaBeforePath -CodexHome $effectiveCodexHomePath -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath) -HistoryRoot $historyRoot -Purpose 'before' -Required
        $beforeSnapshotObject = Read-QuotaSnapshot -Path $beforeSnapshotPathValue
        $beforeSnapshotSha256Value = Get-FileSha256 -Path $beforeSnapshotPathValue
    }
    $beforeSnapshotCapturedAtUtcValue = [string](Get-DispatchJsonProperty -Object $beforeSnapshotObject -Name 'captured_at_utc')
    if ([string]::IsNullOrWhiteSpace($beforeSnapshotCapturedAtUtcValue)) {
        $beforeSnapshotCapturedAtUtcValue = $null
    }
    $beforeSnapshotFreshnessValue = Get-QuotaSnapshotFreshness -Snapshot $beforeSnapshotObject
    $beforeSnapshotObservationsValue = Get-DispatchJsonProperty -Object $beforeSnapshotObject -Name 'observations'
    $beforeSnapshotServiceRejectionValue = Get-QuotaSnapshotServiceRejection -Snapshot $beforeSnapshotObject

    if ($TaskType -eq 'advisor-consult') {
        $afterSnapshot = New-AdvisorAfterSnapshot -CallerPath $QuotaAfterPath -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath) -HistoryRoot $historyRoot -CodexHome $effectiveCodexHomePath
        $afterSnapshotPathValue = [string]$afterSnapshot.Path
        $afterSnapshotSha256Value = [string]$afterSnapshot.Sha256
    }
    if ($TaskType -eq 'advisor-consult') {
        $advisorActivationDecision = Get-AdvisorActivationDecision -RequestSource $AdvisorRequestSource
        $activationModeValue = [string](Get-OptionalObjectProperty -Object $advisorActivationDecision -Name 'activationMode')
        if ([string]::IsNullOrWhiteSpace($activationModeValue)) {
            $activationModeValue = 'none'
        }
        $authorizationSourceValue = Get-OptionalObjectProperty -Object $advisorActivationDecision -Name 'authorizationSource'
        $primaryRemainingPercentValue = Get-DispatchJsonProperty -Object (Get-DispatchJsonProperty -Object $beforeSnapshotObject -Name 'primary') -Name 'remaining_percent'
        $requiredSourceValue = Get-OptionalObjectProperty -Object $advisorActivationDecision -Name 'requiredAuthorization'
        if (-not [bool]$advisorActivationDecision.granted) {
            $failureReasonCode = [string]$advisorActivationDecision.reasonCode
            throw ($failureReasonCode + '：' + [string]$advisorActivationDecision.notice + '; process_started=false')
        }
    }
    $unitKindValue = Get-DefaultUnitKind -DispatchKind $dispatchKindValue -UnitKind $UnitKind -TaskType $TaskType
    $units = @(Get-DispatchUnitList -RequestedUnit $RequestedUnit -DispatchKind $dispatchKindValue -UnitKind $unitKindValue -ExecutionRoot $executionRootPath -SourceRoot $sourceRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -EvidencePackPath $EvidencePackPath -EvidenceQuestionUnits $(if ($null -eq $evidencePackInfo) { $null } else { @($evidencePackInfo.question_units) }) -TargetPath $TargetPath)
    $scopePlanPathValue = $ScopePlanPath
    if ($ContinueFromScopePlan -and [string]::IsNullOrWhiteSpace($ResumeThreadId)) {
        throw 'ContinueFromScopePlan 僅允許在存在有效 AnchorRecord 的續行中使用。'
    }
    if ($ContinueFromScopePlan -and -not [string]::Equals($SessionMode, 'continuation', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ContinueFromScopePlan 僅允許在 SessionMode=continuation 時使用。'
    }
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
        $anchorScopePlanPath = [string](Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'scope_plan_path')
        $anchorScopePlanSha256 = [string](Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'scope_plan_sha256')
        if ([string]::IsNullOrWhiteSpace($anchorScopePlanPath) -or [string]::IsNullOrWhiteSpace($anchorScopePlanSha256)) {
            throw '續行 AnchorRecord 缺少 ScopePlan 路徑或 SHA-256。'
        }
        $anchorScopePlanPath = Resolve-AbsolutePath -Path $anchorScopePlanPath
        if (-not (Test-PathWithinRoot -Path $anchorScopePlanPath -Root $executionRootPath)) {
            throw "AnchorRecord ScopePlan 必須位於 executionRoot 內：$anchorScopePlanPath"
        }
        $anchorScopePlanCurrentSha256 = Get-FileSha256 -Path $anchorScopePlanPath
        if (-not [string]::Equals($anchorScopePlanPath, $scopePlanPathValue, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($anchorScopePlanSha256, $anchorScopePlanCurrentSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw '續行 ScopePlan 與前輪 RunRecord 不一致。'
        }
        $anchorScopePlanRootRunId = [string](Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'scope_plan_root_run_id')
        $witnessScopePlanPath = $anchorScopePlanPath
        $rootScopePlanRecord = Get-DispatchJsonProperty -Object $previousRun -Name 'ScopePlanRootRecord'
        $rootStartClassification = if ($null -eq $rootScopePlanRecord) { $null } else { Get-DispatchRunRecordStartClassification -Record $rootScopePlanRecord }
        if ($null -ne $rootScopePlanRecord -and $rootStartClassification.classification -ne 'unstarted-sandbox' -and -not [string]::IsNullOrWhiteSpace([string](Get-DispatchJsonProperty -Object $rootScopePlanRecord -Name 'scope_plan_path'))) {
            $witnessScopePlanPath = Resolve-AbsolutePath -Path ([string](Get-DispatchJsonProperty -Object $rootScopePlanRecord -Name 'scope_plan_path'))
        }
        if (-not [string]::IsNullOrWhiteSpace($anchorScopePlanRootRunId) -and
            $null -ne $rootScopePlanRecord -and
            -not [string]::Equals([string](Get-DispatchJsonProperty -Object $rootScopePlanRecord -Name 'run_id'), $anchorScopePlanRootRunId, [StringComparison]::OrdinalIgnoreCase)) {
            throw '續行 ScopePlan root run 與 AnchorRecord 不一致。'
        }
        $hashRecordParameters = @{
            SourceHistoryRoot = $sourceHistoryRoot
            DispatchSlug      = $dispatchSlugValue
            LineSlug          = $lineSlugValue
            ScopePlanPath     = $witnessScopePlanPath
        }
        if (-not [string]::IsNullOrWhiteSpace($anchorScopePlanRootRunId)) {
            $hashRecordParameters.ExpectedRootRunId = $anchorScopePlanRootRunId
        }
        $null = Test-ScopePlanHashRecord @hashRecordParameters
        $existingScopePlan = Read-ScopePlanFile -Path $anchorScopePlanPath
        if ($ContinueFromScopePlan) {
            if (-not [string]::Equals($SessionMode, 'continuation', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'ContinueFromScopePlan 僅允許在 SessionMode=continuation 時使用。'
            }
            if (-not (Test-ContinuationScopePlan -ScopePlan $existingScopePlan -DispatchSlug $dispatchSlugValue -DispatchKind $dispatchKindValue -TaskType $TaskType -RequestedProfile $requestedProfileValue -UnitKind $unitKindValue -Units @($existingScopePlan.requested_units))) {
                throw '續行的父 ScopePlan 不存在、欄位不完整或與目前派工契約不一致。'
            }
            $scopePlanParentPathValue = $anchorScopePlanPath
            $scopePlanParentSha256Value = $anchorScopePlanSha256
            $scopePlanParentRunIdValue = [string](Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'run_id')
            $scopePlanRootRunIdValue = if ([string]::IsNullOrWhiteSpace($anchorScopePlanRootRunId)) { $scopePlanParentRunIdValue } else { $anchorScopePlanRootRunId }
            $scopePlanSelectionValue = 'subset'
            $scopePlanPathValue = Join-Path -Path $historyRoot -ChildPath ('scope-plan-' + $dispatchSlugValue + '-' + $runId + '-subset.json')
            $scopePlan = New-ContinuationScopePlanSubset -ParentScopePlan $existingScopePlan -RequestedUnits $units -ParentScopePlanPath $anchorScopePlanPath -ParentScopePlanSha256 $anchorScopePlanSha256 -ParentRunId $scopePlanParentRunIdValue
            Write-Utf8NoBom -Path $scopePlanPathValue -Content (($scopePlan | ConvertTo-Json -Depth 30) + "
") -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
        }
        else {
            if ($TaskType -eq 'advisor-consult' -and -not (Test-StringArrayEqual -Left @($existingScopePlan.requested_units) -Right @($units))) {
                throw 'AdvisorContinuationQuestionSetMismatch：advisor-consult 續談不可新增或變更 question ID；請以新 dispatchSlug 建立新的派遣。'
            }
            if (-not (Test-ContinuationScopePlan -ScopePlan $existingScopePlan -DispatchSlug $dispatchSlugValue -DispatchKind $dispatchKindValue -TaskType $TaskType -RequestedProfile $requestedProfileValue -UnitKind $unitKindValue -Units $units)) {
                throw '續行的 ScopePlan 不存在、欄位不完整或與目前派工契約不一致。'
            }
            $scopePlan = $existingScopePlan
            $scopePlanParentPathValue = Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'scope_plan_parent_path'
            $scopePlanParentSha256Value = Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'scope_plan_parent_sha256'
            $scopePlanParentRunIdValue = Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'scope_plan_parent_run_id'
            if ([string]::IsNullOrWhiteSpace([string]$scopePlanParentPathValue)) {
                $scopePlanParentPathValue = $null
            }
            if ([string]::IsNullOrWhiteSpace([string]$scopePlanParentSha256Value)) {
                $scopePlanParentSha256Value = $null
            }
            if ([string]::IsNullOrWhiteSpace([string]$scopePlanParentRunIdValue)) {
                $scopePlanParentRunIdValue = $null
            }
            $scopePlanRootRunIdValue = if ([string]::IsNullOrWhiteSpace($anchorScopePlanRootRunId)) { [string](Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'run_id') } else { $anchorScopePlanRootRunId }
            $scopePlanSelectionValue = [string](Get-DispatchJsonProperty -Object $previousRun.AnchorRecord -Name 'scope_plan_selection')
            if ([string]::IsNullOrWhiteSpace($scopePlanSelectionValue)) {
                $scopePlanSelectionValue = 'root'
            }
        }
    }
    else {
        $scopePlan = New-ScopePlan -DispatchSlug $dispatchSlugValue -DispatchKind $dispatchKindValue -TaskType $TaskType -RequestedProfile $requestedProfileValue -SessionMode $sessionModeValue -BeforeSnapshot (Read-QuotaSnapshot -Path $beforeSnapshotPathValue) -Units $units -UnitKind $unitKindValue -RequestedBudgetPercent $PrimaryBudgetPercent -RequestedReservePercent $PrimaryReservePercent -ModelEvidence $resolvedModelEvidence -ReasoningEffortEvidence $resolvedReasoningEffortEvidence -ActivationDecision $advisorActivationDecision
        if (-not (Test-ScopePlanCompleteness -ScopePlan $scopePlan)) {
            $phase = 'preparation'
            throw 'ScopePlanInvalid：ScopePlan 必須涵蓋 Request 宣告的完整單位清單。'
        }
        $scopePlan.scope_plan_fingerprint = Get-ScopePlanFingerprint -ScopePlan $scopePlan
        Write-Utf8NoBom -Path $scopePlanPathValue -Content (($scopePlan | ConvertTo-Json -Depth 20) + "
") -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
        $scopePlanRootRunIdValue = $runId
        if ($null -ne $latestColdStartFailure) {
            $inheritedRootRunId = [string](Get-DispatchJsonProperty -Object $latestColdStartFailure -Name 'scope_plan_root_run_id')
            if ([string]::IsNullOrWhiteSpace($inheritedRootRunId)) {
                $inheritedRootRunId = [string](Get-DispatchJsonProperty -Object $latestColdStartFailure -Name 'run_id')
            }
            if ([string]::IsNullOrWhiteSpace($inheritedRootRunId)) {
                $phase = 'preparation'
                throw 'ScopePlanRootRunIdMissing：同 slug cold-start 重試缺少可沿用的 root run id。'
            }
            $scopePlanRootRunIdValue = $inheritedRootRunId
        }
        $scopePlanSelectionValue = 'root'
        $hashClaim = New-DispatchStartHashClaim -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -SourceHistoryRoot $sourceHistoryRoot -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -ScopePlanPath $scopePlanPathValue -RunId $runId -RootRunId $scopePlanRootRunIdValue -TargetPath @($TargetPath)
        if ($hashClaim.Created -and $hashClaim.RunId -ceq $runId -and $hashClaim.RootRunId -ceq $scopePlanRootRunIdValue) {
            $createdScopePlanHashPath = $hashClaim.Path
            $createdScopePlanHashSha256 = $hashClaim.Sha256
        }
    }

    if ($null -ne $evidencePackInfo) {
        Write-Utf8NoBom -Path $evidenceHashPath -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath) -Content ($evidencePackInfo.sha256 + "
")
        Write-Utf8NoBom -Path $evidenceLengthPath -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath) -Content ([string]$evidencePackInfo.length + "
")
    }

    $interruptionSelectedUnitsValue = Get-DispatchJsonProperty -Object $scopePlan -Name 'selected_units'
    $interruptionSelectedUnits = @($interruptionSelectedUnitsValue | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    if ($interruptionSelectedUnits.Count -gt 0) {
        $interruptionCheckpointPathValue = Get-DispatchInterruptionCheckpointPath -SourceRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -RunId $runId
        $initialInterruptionCheckpoint = New-DispatchInterruptionCheckpointDocument -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -RunId $runId -SelectedUnits $interruptionSelectedUnits -ScopePlanPath $scopePlanPathValue -RunRecordPath $runRecordPathValue -EventStreamPath $eventPath
        $null = Write-DispatchAtomicJsonDocument -Path $interruptionCheckpointPathValue -Document $initialInterruptionCheckpoint -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
    }

    if ($TaskType -eq 'advisor-consult') {
        $monitorHistoryRoot = Join-Path -Path $historyRoot -ChildPath $lineSlugValue
        if ([string]::IsNullOrWhiteSpace($monitorPathValue)) {
            $monitorPathValue = Get-QuotaObservationPath -LineHistoryRoot $monitorHistoryRoot -DispatchSlug $dispatchSlugValue
        }
        else {
            $monitorPathValue = Resolve-AbsolutePath -Path $monitorPathValue
            if (-not (Test-PathWithinRoot -Path $monitorPathValue -Root $monitorHistoryRoot)) {
                throw "BudgetMonitorPath 必須位於 line history 內：$monitorPathValue"
            }
        }
        $monitorPathValue = Resolve-DispatchOutputPath -CandidatePath $monitorPathValue -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
        if (-not (Test-PathWithinRoot -Path $monitorPathValue -Root $monitorHistoryRoot)) {
            throw "BudgetMonitorPath 必須位於 line history 內：$monitorPathValue"
        }
    }

    if ($null -eq $advisorActivationDecision) {
        $advisorActivationDecision = [ordered]@{
            activationMode      = 'none'
            granted              = $false
            authorizationSource  = $null
            notice               = ''
        }
    }

    $promptDirectives = New-Object System.Collections.Generic.List[string]
    $promptRequiredIdentifier = Get-DispatchRequiredIdentifier -ConfiguredIdentifier ([string]$RequiredIdentifier) -DispatchKind ([string]$DispatchKind) -TaskType ([string]$TaskType) -EvidencePackPath ([string]$EvidencePackPath) -TargetPath @($TargetPath)
    $outsideRepositoryDirective = New-TargetsOutsideRepositoryPromptDirective -Preflight $preflight
    if (-not [string]::IsNullOrWhiteSpace($outsideRepositoryDirective)) {
        $promptDirectives.Add($outsideRepositoryDirective)
    }
    $promptDirectives.Add(
        '[中斷保全]' + [Environment]::NewLine +
        '本次工作必須可在任意中斷點交付已確認結果。開始主要探索前，先寫出目前已確認的結論、證據位置與尚未確認項目。每完成一個範圍單位，更新一次「已確認結論」與「實際覆蓋範圍」。收到中止要求時，先保存已確認結論、證據位置、未完成單位與不應推論的內容，再結束本次工作。不得以未執行的單位補寫結論。' + [Environment]::NewLine +
        '中斷檢查點不可寫時，改以結案訊息三行交付，不得以此停止工作。' + [Environment]::NewLine +
        '結案訊息一律以下列三行結尾，中止與正常完成都適用，讓後續續行取得交接資料。每行為單行鍵值對，值不得為空；沒有未完成單位時填「無」。' + [Environment]::NewLine +
        '已確認結論：<一句話>' + [Environment]::NewLine +
        '未完成單位：<清單或「無」>' + [Environment]::NewLine +
        '證據位置：<絕對路徑或檔案:行號>'
    )
    if (-not [string]::IsNullOrWhiteSpace($interruptionCheckpointPathValue)) {
        $promptDirectives.Add(
            '[逐單位中斷保全檔]' + [Environment]::NewLine +
            ('每完成一個 ScopePlan.selected_units 單位，立即原子更新此 JSON 檔；開始時已建立全數未完成的初始檔：' + $interruptionCheckpointPathValue + [Environment]::NewLine) +
            'schema 固定為 ai-sessions.dispatch-interruption-checkpoint.v1，包含 line_slug、dispatch_slug、run_id、selected_units、confirmed_units、incomplete_units、source_locations、updated_at_utc。confirmed_units 每筆含 unit、confirmed_result、evidence_locations。unit 必須逐字符合 selected_units；只有實際完成的單位可列入 confirmed_units，每筆都要有具體結論與絕對證據位置。incomplete_units 必須是 selected_units 扣除 confirmed_units 後的原順序單位。deferred_units 與其他未選單位不得列入，也不得寫入結論。寫入每個單位後再繼續下一單位。此檔供 Inspect 與 Collect 回收；結案訊息仍須保留前述三行協定。'
        )
    }
    $promptDirectives.Add('最後訊息最末三行必須為純文字，使用半形冒號且值不加標記：' + [Environment]::NewLine + ('requiredIdentifier: ' + $promptRequiredIdentifier) + [Environment]::NewLine + ('dispatchSlug: ' + $DispatchSlug) + [Environment]::NewLine + ('lineSlug: ' + $LineSlug))
    $promptDirectives.Add(('[ScopePlan]' + [Environment]::NewLine + ($scopePlan | ConvertTo-Json -Depth 20)))
    if (-not [string]::IsNullOrWhiteSpace($ResumeThreadId)) {
        $promptDirectives.Add(
            '[續行交接資料]' + [Environment]::NewLine +
            ('前輪交接來源：' + $continuationHandoffSourceType + [Environment]::NewLine) +
            ('前輪交接路徑：' + $continuationContextPath + [Environment]::NewLine) +
            '前輪已確認結論、未完成單位與證據位置如下，必須沿用且不得重建 ScopePlan：' + [Environment]::NewLine +
            $continuationContextMessage.Trim()
        )
    }
    if ($TaskType -eq 'advisor-consult') {
        $promptDirectives.Add((New-AdvisorInlineEvidenceDirective -EvidencePackInfo $evidencePackInfo))
    }
    $promptPathValue = New-DispatchPrompt -PromptPath $promptTransferPathValue -HistoryRoot $historyRoot -Timestamp $timestamp -Directive @($promptDirectives.ToArray()) -OutputPath $promptPathValue
    if (-not (Test-PathWithinRoot -Path $promptPathValue -Root $executionRootPath)) {
        throw ('PromptPath 必須位於 executionRoot 內；received=' + $promptPathValue + '; executionRoot=' + $executionRootPath)
    }
    if ($TaskType -eq 'advisor-consult') {
        $promptContentForVerification = Read-DispatchUtf8Text -Path $promptPathValue
        $inlineGate = Test-AdvisorInlineEvidenceDirective -PromptContent $promptContentForVerification -EvidencePackInfo $evidencePackInfo
        if (-not $inlineGate.valid) {
            $phase = 'evidence-pack-inline'
            throw ('EvidencePackInlineMismatch：' + $inlineGate.reason)
        }
    }

    $codexArguments = New-Object System.Collections.Generic.List[string]
    $codexArguments.Add('--cd')
    $codexWorkingRoot = $executionRootPath
    if ($null -ne $evidencePackInfo) {
        $codexWorkingRoot = Split-Path -Parent $evidencePackInfo.sandboxPath
    }
    $codexArguments.Add($codexWorkingRoot)
    $codexArguments.Add('--sandbox')
    $codexArguments.Add($sandboxValue)
    $codexArguments.Add('--profile')
    $codexArguments.Add($effectiveProfileValue)
    $effectiveAddDirectory = @((Get-DispatchJsonProperty -Object $parentOptionsModel -Name 'add_directory'))
    foreach ($directory in $effectiveAddDirectory) {
            $directoryPath = Resolve-AbsolutePath -Path $directory
            if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) {
                throw "--add-dir 目錄不存在：$directoryPath"
            }
            $codexArguments.Add('--add-dir')
            $codexArguments.Add($directoryPath)
    }
    $effectiveSearch = [bool](Get-DispatchJsonProperty -Object $parentOptionsModel -Name 'search')
    if ($effectiveSearch) {
        $codexArguments.Add('--search')
    }
    $effectiveCodexParentOption = @((Get-DispatchJsonProperty -Object $parentOptionsModel -Name 'codex_parent_option'))
    foreach ($option in $effectiveCodexParentOption) {
            if ([string]::IsNullOrWhiteSpace($option)) {
                throw 'CodexParentOption 不可包含空白選項。'
            }
            $codexArguments.Add($option)
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

    $eventPath = Initialize-DispatchOutputFile -Path $eventPath -HistoryRoot $historyRoot -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
    $errorPath = Initialize-DispatchOutputFile -Path $errorPath -HistoryRoot $historyRoot -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
    $launcher = New-CodexLauncher -CodexExecutable $codexExecutable -CodexArguments @($codexArguments.ToArray()) -PromptPath $promptPathValue -EventPath $eventPath -ErrorPath $errorPath -HistoryRoot $historyRoot -LauncherPath $launcherPath -ExitSidecarPath $exitSidecarPathValue -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -RunId $runId -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
    $launcherPath = $launcher.Path
    $startInfo = New-ProcessStartInfo -FileName $launcher.FileName -WorkingDirectory $executionRootPath -Arguments @($launcher.Arguments)
    if ($null -ne $previousRun) {
        $profileConfigSha256AfterCompare = $null
        if ([string]::IsNullOrWhiteSpace($profileConfigPathValue) -or -not (Test-Path -LiteralPath $profileConfigPathValue -PathType Leaf)) {
            $phase = 'preparation'
            throw 'ProfileEvidenceUnknown：Resume compare 後找不到 Profile 設定檔，無法重新確認 SHA-256。'
        }
        try {
            $profileConfigSha256AfterCompare = Get-FileSha256 -Path $profileConfigPathValue
        }
        catch {
            $phase = 'preparation'
            throw ('ProfileEvidenceUnknown：Resume compare 後無法重新計算 Profile 設定檔 SHA-256：' + $_.Exception.Message)
        }
        if ([string]::IsNullOrWhiteSpace($profileConfigSha256AtCompare) -or -not [string]::Equals($profileConfigSha256AtCompare, $profileConfigSha256AfterCompare, [StringComparison]::OrdinalIgnoreCase)) {
            $phase = 'preparation'
            throw ('ProfileEvidenceUnknown：Resume compare 後 Profile 設定檔已變更；compare-sha256={0}; current-sha256={1}' -f $profileConfigSha256AtCompare, $profileConfigSha256AfterCompare)
        }
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $startedSnapshot = $null
    $processStarted = $false
    if (-not [string]::Equals($sourceRootPath, $executionRootPath, [StringComparison]::OrdinalIgnoreCase)) {
        if ($null -eq $baselineBinding) {
            throw 'BaselineUnknown：worktree Start 缺少已驗證 Baseline。'
        }
        if ($null -ne $previousRun -and (-not [string]::Equals($previousRun.AnchorRecord.baseline_path, $baselineBinding.Path, [StringComparison]::OrdinalIgnoreCase) -or $previousRun.AnchorRecord.baseline_sha256 -ine $baselineBinding.Sha256)) { throw 'Resume 必須沿用前輪 Baseline。' }
    }
    $runRecord.scope_plan_path = $scopePlanPathValue
    $runRecord.scope_plan_sha256 = Get-FileSha256 -Path $scopePlanPathValue
    $runRecord.scope_plan_parent_path = $scopePlanParentPathValue
    $runRecord.scope_plan_parent_sha256 = $scopePlanParentSha256Value
    $runRecord.scope_plan_parent_run_id = $scopePlanParentRunIdValue
    $runRecord.scope_plan_root_run_id = if ([string]::IsNullOrWhiteSpace($scopePlanRootRunIdValue)) { $runId } else { $scopePlanRootRunIdValue }
    $runRecord.scope_plan_selection = $scopePlanSelectionValue
    $runRecord.interruption_checkpoint_path = $interruptionCheckpointPathValue
    $runRecord.model_evidence = $modelEvidence.model
    $runRecord.reasoning_effort_evidence = $modelEvidence.reasoning_effort
    $runRecord.profile_config_path = $profileConfigPathValue
    $runRecord.codex_home = $codexHomeEvidencePath
    $runRecord.effective_codex_home = $effectiveCodexHomePath
    $runRecord.prepare_result_path = $prepareResultPathValue
    $runRecord.prepare_result_sha256 = $prepareResultSha256Value
    $runRecord.prepare_status = $prepareStatusValue
    $runRecord.parent_options = $parentOptionsModel
    $runRecord.parent_options_sha256 = $parentOptionsModel.fingerprint
    $runRecord.parent_options_status = 'confirmed'
    $runRecord.quota_before_path = $beforeSnapshotPathValue
    $runRecord.quota_before_sha256 = $beforeSnapshotSha256Value
    $runRecord.quota_before_captured_at_utc = $beforeSnapshotCapturedAtUtcValue
    $runRecord.quota_before_freshness = $beforeSnapshotFreshnessValue
    $runRecord.quota_before_observations = $beforeSnapshotObservationsValue
    $runRecord.quota_before_service_rejection = $beforeSnapshotServiceRejectionValue
    $runRecord.quota_after_path = $afterSnapshotPathValue
    $runRecord.quota_after_sha256 = $afterSnapshotSha256Value
    $runRecord.evidence_pack_path = if ($null -eq $evidencePackInfo) { $null } else { $evidencePackInfo.path }
    $runRecord.evidence_pack_sha256 = if ($null -eq $evidencePackInfo) { $null } else { $evidencePackInfo.sha256 }
    $runRecord.evidence_pack_length = if ($null -eq $evidencePackInfo) { $null } else { [int64]$evidencePackInfo.length }
    $runRecord.advisor_request_source = $AdvisorRequestSource
    $runRecord.advisor_activation_decision = if ($null -eq $advisorActivationDecision) { $null } else { Get-OptionalObjectProperty -Object $advisorActivationDecision -Name 'activationMode' }
    $runRecord.advisor_activation_granted = if ($null -eq $advisorActivationDecision) { $false } else { [bool](Get-OptionalObjectProperty -Object $advisorActivationDecision -Name 'granted') }
    $runRecord.advisor_activation_notice = if ($null -eq $advisorActivationDecision) { $null } else { Get-OptionalObjectProperty -Object $advisorActivationDecision -Name 'notice' }
    $runRecord.advisor_hard_limit_percent = if ($null -eq $advisorActivationDecision) { $null } else { Get-OptionalObjectProperty -Object $advisorActivationDecision -Name 'hardLimitPercent' }
    $runRecord.advisor_unit_estimate_percent = if ($null -eq $scopePlan) { $null } else { Get-OptionalObjectProperty -Object $scopePlan -Name 'advisor_unit_estimate_percent' }
    $runRecord.activationMode = $activationModeValue
    $runRecord.authorizationSource = $authorizationSourceValue
    $runRecord.primaryRemainingPercent = $primaryRemainingPercentValue
    $runRecord.requiredSource = $requiredSourceValue
    $runRecord.resume_diagnostics = $resumeDiagnostics
    $runRecord.attempt_parent_run_id = $attemptParentRunIdValue
    $runRecord.resume_anchor_run_id = $resumeAnchorRunIdValue
    $runRecord.skipped_attempts = @($skippedAttemptsValue)
    $runRecord.baseline_path = if ($null -ne $baselineBinding) { $baselineBinding.Path } else { $null }
    $runRecord.baseline_sha256 = if ($null -ne $baselineBinding) { $baselineBinding.Sha256 } else { $null }
    $runRecord.baseline_resolution = $baselineResolution
    $runRecord.prompt_path = $promptPathValue
    $runRecord.prompt_source_path = $promptSourcePathValue
    $runRecord.prompt_source_sha256 = $promptSourceSha256Value
    $runRecord.prompt_transfer_path = $promptTransferPathValue
    $runRecord.prompt_transfer_sha256 = $promptTransferSha256Value
    $runRecord.inspect_result_path = $inspectResultPathValue
    $null = Write-DispatchRunRecord -Record $runRecord -Update
    $null = Read-DispatchRunRecord -Path $runRecordPathValue -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue
        if ($null -ne $script:CallerSessionIdentity) {
            $script:DispatchAdmissionStartedPid = 0
            $script:DispatchAdmissionSnapshotError = $null
            $startWritePaths = Get-DispatchAdmissionWritePaths -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -WriteMode $writeModeValue -TargetPath @($TargetPath) -AddDirectory @($AddDirectory)
            $admissionStart = Invoke-DispatchAdmissionStart `
                -SourceRoot $sourceRootPath `
                -CallerIdentity $script:CallerSessionIdentity `
                -LineSlug $lineSlugValue `
                -DispatchSlug $dispatchSlugValue `
                -WriteMode $writeModeValue `
                -WritePaths @($startWritePaths) `
                -PidCheckAction {
                    $check = Get-PidCheckResult -SourceRoot $sourceRootPath -LineSlug $lineSlugValue -WriteMode $writeModeValue
                    $blocking = @(Get-BlockingDispatchPidRecords -PidCheckResult $check -DispatchSlug $dispatchSlugValue)
                    return [pscustomobject]@{ Blocked = $blocking.Count -gt 0; BlockingRecords = $blocking; PidCheckResult = $check }
                } `
                -StartAction {
                    if (-not $process.Start()) { throw 'Codex 啟動失敗。' }
                    $script:DispatchAdmissionStartedPid = [int]$process.Id
                    $snapshot = $null
                    try {
                        $snapshot = Get-StartedProcessSnapshot -ProcessId $process.Id
                    }
                    catch {
                        $script:DispatchAdmissionSnapshotError = $_.Exception.Message
                    }
                    Write-StartPidRecord -Path $pidPath -ProcessId $process.Id -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -WriteMode $writeModeValue -Snapshot $snapshot -CallerSessionFingerprint ([string]$script:CallerSessionIdentity.Fingerprint) -CallerSessionSource ([string]$script:CallerSessionIdentity.Source)
                    $creationUtc = Get-OptionalObjectProperty -Object $snapshot -Name 'CreationUtc'
                    return [pscustomobject]@{
                        ProcessId = [int]$process.Id
                        ProcessName = [string](Get-OptionalObjectProperty -Object $snapshot -Name 'ProcessName')
                        ProcessStartTimeUtc = if ($null -eq $creationUtc) { '' } else { ([datetime]$creationUtc).ToUniversalTime().ToString('o') }
                        Snapshot = $snapshot
                        RunRecordPath = $runRecordPathValue
                        PidRecordPath = $pidPath
                    }
                }
            $startedInfo = $admissionStart.Process
            $startedSnapshot = $startedInfo.Snapshot
            $startedSnapshotError = [string]$script:DispatchAdmissionSnapshotError
            $processStarted = $true
        }
        else {
            if (-not $process.Start()) {
                throw 'Codex 啟動失敗。'
            }
            $processStarted = $true
            try {
                $startedSnapshot = Get-StartedProcessSnapshot -ProcessId $process.Id
            }
            catch {
                $startedSnapshotError = $_.Exception.Message
                $startedSnapshot = $null
            }
            Write-StartPidRecord -Path $pidPath -ProcessId $process.Id -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -WriteMode $writeModeValue -Snapshot $startedSnapshot
        }
        if (-not [string]::IsNullOrWhiteSpace($startedSnapshotError)) {
            $phase = 'identity-unverified'
            throw "無法取得 Codex 根程序身分，PID $($process.Id) snapshot 查詢失敗：$startedSnapshotError"
        }
        if ($null -eq $startedSnapshot) {
            $phase = 'identity-unverified'
            throw "無法取得 Codex 根程序身分，PID $($process.Id) 未通過驗證。"
        }
        if ($startedSnapshot.IdentityStatus -ne 'confirmed' -or $startedSnapshot.IdentityVerified -ne $true) {
            $phase = 'identity-unverified'
            throw "Codex 根程序身分無法確認，拒絕以未驗證程序收尾：PID $($process.Id); identity-status=$($startedSnapshot.IdentityStatus); failure-fields=$($startedSnapshot.IdentityFailureFields -join ','); missing-fields=$($startedSnapshot.IdentityMissingFields -join ',')"
        }
        if (-not (Test-IsWindowsPlatform)) {
            if ($null -eq $startedSnapshot.PSObject.Properties['ProcessGroupId'] -or $startedSnapshot.ProcessGroupId -le 0) {
                $phase = 'identity-unverified'
                throw "無法取得 Codex 根程序的 process group，PID $($process.Id) 未通過驗證。"
            }
        }
        $startedAtUtcValue = [datetime]::UtcNow.ToString('o')
        $runRecord.started_at_utc = $startedAtUtcValue

        $relay = Wait-ForThreadRelay -EventPath $eventPath -ThreadPath $threadPath -TimeoutSeconds 5
        $relayReady = [bool](Get-DispatchJsonProperty -Object $relay -Name 'ready')
        if (-not $relayReady) {
            if ([string]::IsNullOrWhiteSpace($ResumeThreadId)) {
                $phase = 'thread-relay-not-ready'
                throw ('thread relay not-ready：逾時 {0} 秒仍未取得本次 launch 的 thread.started；保留事件流與 relay 證據。' -f $relay.timeoutSeconds)
            }
            $runRecord.thread_id = $ResumeThreadId
        }
        else {
            if ([string]::IsNullOrWhiteSpace($relay.threadId)) {
                $phase = 'thread-relay-not-ready'
                throw 'thread relay not-ready：本次 launch relay 標記 ready 但未提供 threadId。'
            }
            if (-not [string]::IsNullOrWhiteSpace($ResumeThreadId) -and $relay.threadId -cne $ResumeThreadId) {
                throw 'thread relay 與 ResumeThreadId 不一致。'
            }
            $runRecord.thread_id = $relay.threadId
            $null = Get-DispatchRunEvents $runRecord
        }
        $runRecord.launch_state = 'started'
        $runRecord.prompt_path = $promptPathValue
        $runRecord.prompt_source_path = $promptSourcePathValue
        $runRecord.prompt_source_sha256 = $promptSourceSha256Value
        $runRecord.prompt_transfer_path = $promptTransferPathValue
        $runRecord.prompt_transfer_sha256 = $promptTransferSha256Value
        $runRecord.inspect_result_path = $inspectResultPathValue
        $null = Write-DispatchRunRecord -Record $runRecord -Update
        $inspectResult = Write-DispatchInspectResultBinding -Path $inspectResultPathValue -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue -ProcessStarted $true -RunRecordPath $runRecordPathValue -EventStreamPath $eventPath -ScopePlanPath $scopePlanPathValue -QuotaBeforePath $beforeSnapshotPathValue -QuotaBeforeSha256 $beforeSnapshotSha256Value -ProcessExitCodeSidecarPath $exitSidecarPathValue
        $inspectResultPathValue = $inspectResult.Path
        $budgetMonitorStatus.state = 'running'
        if ($TaskType -eq 'advisor-consult') {
            $budgetMonitorStatus = Invoke-AdvisorBudgetMonitor -Process $process -StartedSnapshot $startedSnapshot -EventPath $eventPath -MonitorPath $monitorPathValue -BeforeSnapshot $beforeSnapshotObject -AfterSnapshotPath (Resolve-AbsolutePath -Path $afterSnapshotPathValue) -AfterSnapshotSha256 $afterSnapshotSha256Value -CodexHome $CodexHome -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath) -ScopePlan $scopePlan
            $afterSnapshotSha256Value = [string]$budgetMonitorStatus.afterSnapshotSha256
            $runRecord.quota_after_path = $afterSnapshotPathValue
            $runRecord.quota_after_sha256 = $afterSnapshotSha256Value
            $runRecord.quota_observation_state = [string]$budgetMonitorStatus.lastSnapshotState
            $runRecord.quota_observation_path = $monitorPathValue
            $runRecord.quota_observation_write_failures = @($budgetMonitorStatus.writeFailures)
            $null = Write-DispatchRunRecord -Record $runRecord -Update
        }
        if ($waitForProcessExit -and -not $process.HasExited) {
            $process.WaitForExit()
            $process.Refresh()
        }
        $phase = 'started'

        return [ordered]@{
            operation        = 'Start'
            processStarted   = $true
            processEnded     = $process.HasExited
            processExitCode  = if ($process.HasExited) { [int]$process.ExitCode } else { $null }
            runId            = $runId
            runRecordPath    = $runRecordPathValue
            interruptionCheckpointPath = $interruptionCheckpointPathValue
            sourceRoot       = $sourceRootPath
            executionRoot    = $executionRootPath
            lineSlug         = $lineSlugValue
            dispatchSlug     = $dispatchSlugValue
            requestedProfile = $requestedProfileValue
            profile          = $effectiveProfileValue
            profileDowngraded = $false
            interruptionSafeguardApplied = $interruptionSafeguardApplied
            downgradeInstructionApplied = $interruptionSafeguardApplied
            model            = $resolvedModelValue
            reasoningEffort  = $resolvedReasoningEffortValue
            requestedModel   = $requestedModelEvidence
            requestedReasoningEffort = $requestedReasoningEffortEvidence
            resolvedModel    = $resolvedModelEvidence
            resolvedReasoningEffort = $resolvedReasoningEffortEvidence
            modelEvidence    = $modelEvidence
            reasoningEffortEvidence = $modelEvidence.reasoning_effort
            taskType         = $TaskType
            sessionMode      = $sessionModeValue
            advisorRequestSource       = $AdvisorRequestSource
            advisorActivationDecision = $advisorActivationDecision.activationMode
            advisorActivationGranted  = $advisorActivationDecision.granted
            advisorActivationNotice   = $advisorActivationDecision.notice
            activationMode    = $activationModeValue
            authorizationSource = $authorizationSourceValue
            primaryRemainingPercent = $primaryRemainingPercentValue
            requiredSource    = $requiredSourceValue
            resumeThreadId   = $ResumeThreadId
            rootPid          = $process.Id
            pidRecordPath    = $pidPath
            eventStreamPath  = $eventPath
            stderrPath       = $errorPath
             errorStreamPath  = $errorPath
             lastMessagePath  = $lastMessagePathValue
             promptPath       = $promptPathValue
             promptSourcePath = $promptSourcePathValue
             promptSourceSha256 = $promptSourceSha256Value
             promptTransferPath = $promptTransferPathValue
             promptTransferSha256 = $promptTransferSha256Value
             inspectResultPath = $inspectResultPathValue
             threadIdPath     = $threadPath
             threadId         = $runRecord.thread_id
             threadRelay      = $relay
             relayDiagnostics = Get-DispatchJsonProperty -Object $relay -Name 'relay_diagnostics'
             relayReady       = $relayReady
             scopePlanPath    = $scopePlanPathValue
             scopePlan         = $scopePlan
             prepareResultPath  = $prepareResultPathValue
             prepareResultSha256 = $prepareResultSha256Value
             prepareStatus       = $prepareStatusValue
             quotaBeforePath  = $beforeSnapshotPathValue
            quotaAfterPath   = $afterSnapshotPathValue
            quotaAfterSha256 = $afterSnapshotSha256Value
            evidencePackPath = if ($null -eq $evidencePackInfo) { $null } else { $evidencePackInfo.path }
            evidencePackSandboxPath = if ($null -eq $evidencePackInfo) { $null } else { $evidencePackInfo.sandboxPath }
            evidencePackSha256 = if ($null -eq $evidencePackInfo) { $null } else { $evidencePackInfo.sha256 }
            evidencePackLength = if ($null -eq $evidencePackInfo) { $null } else { [int64]$evidencePackInfo.length }
            profileConfigPath = $profileConfigPathValue
            codexHome = $codexHomeEvidencePath
            effectiveCodexHome = $effectiveCodexHomePath
            parentOptions = $parentOptionsModel
            parentOptionsSha256 = if ($null -eq $parentOptionsModel) { $null } else { $parentOptionsModel.fingerprint }
            startedAtUtc = $startedAtUtcValue
            resumeDiagnostics = $resumeDiagnostics
            budgetMonitorPath = $monitorPathValue
             budgetMonitor     = $budgetMonitorStatus
             quotaBeforeSha256 = $beforeSnapshotSha256Value
             quotaBeforeCapturedAtUtc = $beforeSnapshotCapturedAtUtcValue
             quotaBeforeFreshness = $beforeSnapshotFreshnessValue
             quotaBeforeObservations = $beforeSnapshotObservationsValue
             quotaBeforeServiceRejection = $beforeSnapshotServiceRejectionValue
            launcherPath     = $launcher.Path
            processExitCodeSidecarPath = $exitSidecarPathValue
            codexPath        = $codexExecutable
            codexArguments   = @($codexArguments.ToArray())
            processTreeScope = if (Test-IsWindowsPlatform) { 'pid-and-descendants' } else { 'process-group' }
        }
    }
    catch {
        $admissionStartedPidVariable = Get-Variable -Name 'DispatchAdmissionStartedPid' -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $admissionStartedPidVariable -and [int]$admissionStartedPidVariable.Value -gt 0) {
            $processStarted = $true
        }
        $originalMessage = $_.Exception.Message
        if (-not $processStarted -and -not [string]::IsNullOrWhiteSpace($createdScopePlanHashPath)) {
            $hashAdmissionLock = $null
            try {
                $hashAdmissionLock = Open-DispatchAdmissionLock -SourceRoot $sourceRootPath
                $hashLedger = Read-DispatchAdmissionLedger -Lock $hashAdmissionLock
                $hashOwners = @($hashLedger.Document.entries | Where-Object { [string]$_.dispatch_slug -ceq $dispatchSlugValue })
                if ($hashOwners.Count -gt 0) {
                    throw "ScopePlan SHA-256 紀錄已有准入擁有者，保留待確認：$createdScopePlanHashPath"
                }
                Assert-DispatchOutputPathNoReparsePoint -Root $sourceRootPath -Path $createdScopePlanHashPath
                if (Test-Path -LiteralPath $createdScopePlanHashPath -PathType Leaf) {
                    $hashRecord = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $createdScopePlanHashPath)
                    if ([string]$hashRecord.dispatch_slug -cne $dispatchSlugValue -or
                        [string]$hashRecord.line_slug -cne $lineSlugValue -or
                        [string]$hashRecord.scope_plan_path -cne $scopePlanPathValue -or
                        [string]$hashRecord.root_run_id -cne $scopePlanRootRunIdValue -or
                        [string](Get-FileSha256 -Path $createdScopePlanHashPath) -cne $createdScopePlanHashSha256) {
                        throw "ScopePlan SHA-256 紀錄已變更，保留待確認：$createdScopePlanHashPath"
                    }
                    Remove-Item -LiteralPath $createdScopePlanHashPath -Force -ErrorAction Stop
                }
            }
            catch {
                $cleanupError = '清理本次 ScopePlan SHA-256 紀錄失敗：' + $_.Exception.Message
            }
            finally {
                Close-DispatchAdmissionLock -Lock $hashAdmissionLock
            }
        }
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
                Ensure-StartEvidenceFiles -Path @($evidencePaths) -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath)
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
        $relaySourceValue = $null
        $relayTimedOutValue = $null
        $relayTimeoutSecondsValue = $null
        if ($null -ne $relay) {
            if ($relay -is [System.Collections.IDictionary]) {
                if ($relay.Contains('source')) {
                    $relaySourceValue = [string]$relay['source']
                }
                if ($relay.Contains('timedOut')) {
                    $relayTimedOutValue = [bool]$relay['timedOut']
                }
                if ($relay.Contains('timeoutSeconds')) {
                    $relayTimeoutSecondsValue = [int]$relay['timeoutSeconds']
                }
            }
            else {
                $relaySourceValue = [string](Get-OptionalObjectProperty -Object $relay -Name 'source')
                $relayTimedOutProperty = $relay.PSObject.Properties['timedOut']
                if ($null -ne $relayTimedOutProperty) {
                    $relayTimedOutValue = [bool]$relayTimedOutProperty.Value
                }
                $relayTimeoutSecondsProperty = $relay.PSObject.Properties['timeoutSeconds']
                if ($null -ne $relayTimeoutSecondsProperty) {
                    $relayTimeoutSecondsValue = [int]$relayTimeoutSecondsProperty.Value
                }
            }
        }
        $evidenceMessage = New-StartFailureEvidenceMessage -Phase $phase -EventPath $eventPath -ErrorPath $errorPath -LastMessagePath $lastMessagePathValue -ThreadPath $threadPath -PidPath $pidPath -LauncherPath $launcherPath -ProcessExitCode $processExitCodeValue -CleanupStatus $cleanupStatus -CleanupError $cleanupError -RelaySource $relaySourceValue -RelayTimedOut $relayTimedOutValue -RelayTimeoutSeconds $relayTimeoutSecondsValue
        $failurePhase = $phase
        if (-not $processStarted -and [string]::IsNullOrWhiteSpace([string]$scopePlanPathValue)) {
            $failurePhase = 'preparation'
        }
        $failureObservation = [ordered]@{
            process_started = $processStarted
            process_exit_code = $processExitCodeValue
            cleanup_status = $cleanupStatus
            cleanup_error = $cleanupError
            relay_source = $relaySourceValue
            relay_timed_out = $relayTimedOutValue
            relay_timeout_seconds = $relayTimeoutSecondsValue
            budget_monitor = $budgetMonitorStatus
            failure_stage = $phase
        }
        $failure = New-DispatchFailureRecord -Phase $failurePhase -Message $originalMessage -ReasonCode $failureReasonCode -ProcessStarted $processStarted -ProcessExitCode $processExitCodeValue -EventPath $eventPath -ErrorPath $errorPath -LastMessagePath $lastMessagePathValue -ThreadPath $threadPath -PidPath $pidPath -LauncherPath $launcherPath -RolloutPaths @() -Observation $failureObservation
        $failure.activationMode = $activationModeValue
        $failure.authorizationSource = $authorizationSourceValue
        $failure.primaryRemainingPercent = $primaryRemainingPercentValue
        $failure.requiredSource = $requiredSourceValue
        $recordWriteError = $null
        if ($null -ne $runRecord -and -not [string]::IsNullOrWhiteSpace($runRecordPathValue)) {
            try {
                $runRecord.event_stream_path = $eventPath
                $runRecord.last_message_path = $lastMessagePathValue
                $runRecord.thread_id_path = $threadPath
                $runRecord.launcher_path = $launcherPath
                $runRecord.process_exit_code_sidecar_path = $exitSidecarPathValue
                $runRecord.prompt_path = $promptPathValue
                $runRecord.prompt_source_path = $promptSourcePathValue
                $runRecord.prompt_source_sha256 = $promptSourceSha256Value
                $runRecord.prompt_transfer_path = $promptTransferPathValue
                $runRecord.prompt_transfer_sha256 = $promptTransferSha256Value
                $runRecord.inspect_result_path = $inspectResultPathValue
                $runRecord.pid_record_path = $pidPath
                $runRecord.attempt_parent_run_id = $attemptParentRunIdValue
                $runRecord.resume_anchor_run_id = $resumeAnchorRunIdValue
                $runRecord.skipped_attempts = @($skippedAttemptsValue)
                $runRecord.resume_diagnostics = $resumeDiagnostics
                $runRecord.started_at_utc = $startedAtUtcValue
                if ($null -ne $modelEvidence) {
                    $runRecord.model_evidence = $modelEvidence.model
                    $runRecord.reasoning_effort_evidence = $modelEvidence.reasoning_effort
                }
                if (-not [string]::IsNullOrWhiteSpace($profileConfigPathValue)) { $runRecord.profile_config_path = $profileConfigPathValue }
                if (-not [string]::IsNullOrWhiteSpace($codexHomeEvidencePath)) { $runRecord.codex_home = $codexHomeEvidencePath }
                if (-not [string]::IsNullOrWhiteSpace($effectiveCodexHomePath)) { $runRecord.effective_codex_home = $effectiveCodexHomePath }
                if (-not [string]::IsNullOrWhiteSpace($prepareResultPathValue)) { $runRecord.prepare_result_path = $prepareResultPathValue }
                if (-not [string]::IsNullOrWhiteSpace($prepareResultSha256Value)) { $runRecord.prepare_result_sha256 = $prepareResultSha256Value }
                if (-not [string]::IsNullOrWhiteSpace($prepareStatusValue)) { $runRecord.prepare_status = $prepareStatusValue }
                if ($null -ne $parentOptionsModel) {
                    $runRecord.parent_options = $parentOptionsModel
                    $runRecord.parent_options_sha256 = $parentOptionsModel.fingerprint
                    $runRecord.parent_options_status = 'confirmed'
                }
                if (-not [string]::IsNullOrWhiteSpace($beforeSnapshotPathValue) -and (Test-Path -LiteralPath $beforeSnapshotPathValue -PathType Leaf)) {
                    $runRecord.quota_before_path = $beforeSnapshotPathValue
                    $runRecord.quota_before_sha256 = Get-FileSha256 -Path $beforeSnapshotPathValue
                    $runRecord.quota_before_captured_at_utc = $beforeSnapshotCapturedAtUtcValue
                }
                if ($null -ne $evidencePackInfo) {
                    $runRecord.evidence_pack_path = $evidencePackInfo.path
                    $runRecord.evidence_pack_sha256 = $evidencePackInfo.sha256
                    $runRecord.evidence_pack_length = [int64]$evidencePackInfo.length
                }
                if (-not [string]::IsNullOrWhiteSpace($scopePlanPathValue) -and (Test-Path -LiteralPath $scopePlanPathValue -PathType Leaf)) {
                    $runRecord.scope_plan_path = $scopePlanPathValue
                    $runRecord.scope_plan_sha256 = Get-FileSha256 -Path $scopePlanPathValue
                    $runRecord.scope_plan_parent_path = $scopePlanParentPathValue
                    $runRecord.scope_plan_parent_sha256 = $scopePlanParentSha256Value
                    $runRecord.scope_plan_parent_run_id = $scopePlanParentRunIdValue
                    $runRecord.scope_plan_root_run_id = if ([string]::IsNullOrWhiteSpace($scopePlanRootRunIdValue)) { $runId } else { $scopePlanRootRunIdValue }
                    $runRecord.scope_plan_selection = $scopePlanSelectionValue
                }
                else {
                    $runRecord.scope_plan_path = $null
                    $runRecord.scope_plan_sha256 = $null
                    $runRecord.scope_plan_parent_path = $null
                    $runRecord.scope_plan_parent_sha256 = $null
                    $runRecord.scope_plan_parent_run_id = $null
                    $runRecord.scope_plan_root_run_id = $null
                    $runRecord.scope_plan_selection = 'root'
                }
                if ($null -ne $baselineBinding) {
                    $runRecord.baseline_path = $baselineBinding.Path
                    $runRecord.baseline_sha256 = $baselineBinding.Sha256
                }
                if ($null -ne $baselineResolution) {
                    $runRecord.baseline_resolution = $baselineResolution
                }
                $runRecord.activationMode = $activationModeValue
                $runRecord.authorizationSource = $authorizationSourceValue
                $runRecord.primaryRemainingPercent = $primaryRemainingPercentValue
                $runRecord.requiredSource = $requiredSourceValue
                $runRecord.failure = $failure
                $runRecord.launch_state = 'launch-failed'
                $null = Write-DispatchRunRecord -Record $runRecord -Update
                $null = Read-DispatchRunRecord -Path $runRecordPathValue -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $lineSlugValue -DispatchSlug $dispatchSlugValue
            }
            catch {
                $recordWriteError = $_.Exception.Message
                $runRecordPathValue = $null
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($recordWriteError)) {
            $failure.write_error = $recordWriteError
        }
        $failureResult = [ordered]@{
            operation = 'Start'
            runId = $runId
            runRecordPath = $runRecordPathValue
            prepareResultPath = $prepareResultPathValue
            prepareResultSha256 = $prepareResultSha256Value
            prepareStatus = $prepareStatusValue
            effectiveCodexHome = $effectiveCodexHomePath
            success = $false
            outputValid = $false
            processStarted = $processStarted
            processExitCode = $processExitCodeValue
            errorCode = $failure.reason_code
            error = $originalMessage
            activationMode = $activationModeValue
            authorizationSource = $authorizationSourceValue
            primaryRemainingPercent = $primaryRemainingPercentValue
            requiredSource = $requiredSourceValue
            failure = $failure
            modelEvidence = if ($null -eq $modelEvidence) { $null } else { $modelEvidence }
            reasoningEffortEvidence = if ($null -eq $modelEvidence) { $null } else { $modelEvidence.reasoning_effort }
            resumeDiagnostics = $resumeDiagnostics
            evidence = $evidenceMessage
            eventStreamPath = $eventPath
            errorStreamPath = $errorPath
            lastMessagePath = $lastMessagePathValue
            threadIdPath = $threadPath
            pidRecordPath = $pidPath
            launcherPath = $launcherPath
            processExitCodeSidecarPath = $exitSidecarPathValue
            promptPath = $promptPathValue
            promptSourcePath = $promptSourcePathValue
            promptSourceSha256 = $promptSourceSha256Value
            promptTransferPath = $promptTransferPathValue
            promptTransferSha256 = $promptTransferSha256Value
            inspectResultPath = $inspectResultPathValue
        }
        $operationException = New-Object System.Exception($originalMessage + "`nStart 失敗證據：" + $evidenceMessage)
        $operationException = Write-DispatchOperationFailureResult -Exception $operationException -Result $failureResult
        throw $operationException
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}
