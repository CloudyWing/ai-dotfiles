#Requires -Version 7.0

function New-CleanupOperationResult {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$SourceRoot,
        [AllowEmptyString()][string]$DispatchRoot,
        [AllowEmptyString()][string]$LineSlug,
        [AllowEmptyString()][string]$DispatchSlug
    )

    return [ordered]@{
        schema             = 'ai-sessions.dispatch-cleanup-result.v1'
        operation          = 'Cleanup'
        line_slug          = $LineSlug
        dispatch_slug      = $DispatchSlug
        source_root        = $SourceRoot
        dispatch_root      = $DispatchRoot
        source_files       = @()
        destination_files  = @()
        files              = @()
        errors             = @()
        worktree_removed   = $false
        status              = 'preflight-rejected'
        failure_code       = $null
        error              = $null
        owner_takeover     = [ordered]@{ used = $false; audit_path = $null; audit_sha256 = $null }
        unstarted_proof    = [ordered]@{ used = $false; basis = $null; audit_path = $null; audit_sha256 = $null }
        inventory          = [ordered]@{
            report_root = $null
            referenced_paths = @()
            source_count = 0
        }
    }
}

$script:CleanupFixedReportNames = @(
    @{ Name = 'review-report'; VersionUnknownFallback = $false }
    @{ Name = 'frontend-reviewer-report'; VersionUnknownFallback = $false }
    @{ Name = 'contract-auditor-report'; VersionUnknownFallback = $false }
    @{ Name = 'implement-closure-report'; VersionUnknownFallback = $true }
    @{ Name = 'support-engineer-report'; VersionUnknownFallback = $true }
    @{ Name = 'cleanup-review'; VersionUnknownFallback = $true }
)

function New-CleanupIdentityMismatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Field,
        [AllowNull()][object]$Expected,
        [AllowNull()][object]$Received,
        [Parameter(Mandatory)][string]$Source
    )

    return [ordered]@{
        field    = $Field
        expected = $Expected
        received = $Received
        source   = $Source
    }
}

function Throw-CleanupOperationFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Result,
        [Parameter(Mandatory)][ValidateSet('preflight-rejected', 'preservation-failed', 'removal-failed')][string]$Status,
        [Parameter(Mandatory)][string]$FailureCode,
        [Parameter(Mandatory)][string]$Message,
        [AllowNull()][object]$Detail,
        [AllowNull()][object]$TakeoverRejection
    )

    $Result.status = $Status
    $Result.failure_code = $FailureCode
    $Result.error = $Message
    if ($null -eq $Detail) {
        $Result.errors = @()
    }
    else {
        $Result.errors = @($Detail)
    }
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['errorCode'] = $FailureCode
    $exception.Data['operationResult'] = $Result
    if ($null -ne $TakeoverRejection) { $exception.Data['takeoverRejection'] = $TakeoverRejection }
    throw $exception
}

function New-CleanupPreflightRequiredFailure {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$PreflightPath, [AllowEmptyString()][string]$RunPath, [AllowNull()][object]$NeverLaunchedProof)

    $missing = @()
    if ([string]::IsNullOrWhiteSpace($PreflightPath)) { $missing += 'preflight_result_path' }
    if ([string]::IsNullOrWhiteSpace($RunPath)) { $missing += 'run_record_path' }
    $preflightDisplay = if ([string]::IsNullOrWhiteSpace($PreflightPath)) { '未提供' } else { $PreflightPath }
    $runDisplay = if ([string]::IsNullOrWhiteSpace($RunPath)) { '未提供' } else { $RunPath }
    $message = "Cleanup 缺少啟動前或未啟動證據。請在 Cleanup Request 補上 preflight_result_path（來源：Dispatch result 的 preflight_result_path）；Start 已失敗並寫入 launch-failed RunRecord 時改補 run_record_path（來源：Dispatch result 的 run_record_path 或 history\<lineSlug>\runs\<dispatchSlug>\）。Dispatch 在建立 worktree 後、寫出 Preflight result 前停止時，可由約定路徑或 dispatch_request_path 的 dispatch-request 以 U1 至 U4 判定；請勿手寫 Preflight result 或收據。目前 preflight_result_path=$preflightDisplay，run_record_path=$runDisplay"
    $detail = [ordered]@{ missing_request_fields = $missing }
    if ($null -ne $NeverLaunchedProof -and -not $NeverLaunchedProof.Accepted) {
        $message += '；未啟動判定未放行：' + (@($NeverLaunchedProof.Rejections | ForEach-Object { $_.message }) -join '；')
        $detail.unstarted_proof = [ordered]@{ evaluated = $true; failed_conditions = @($NeverLaunchedProof.Rejections) }
    }
    return [pscustomobject]@{ Message = $message; Detail = $detail }
}

function Get-CleanupPropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string[]]$Names
    )

    foreach ($name in @($Names)) {
        $property = if ($null -eq $Object) { $null } else { $Object.PSObject.Properties[[string]$name] }
        if ($null -ne $property) {
            return $property.Value
        }
        if ($Object -is [System.Collections.IDictionary] -and $Object.Contains([string]$name)) {
            return $Object[[string]$name]
        }
    }
    return $null
}

function Read-CleanupJsonDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $resolvedPath = Resolve-AbsolutePath -Path $Path
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw ('Cleanup' + $Name + 'Missing：找不到檔案：' + $resolvedPath)
    }
    try {
        $document = ConvertFrom-DispatchJson -Content (Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8)
    }
    catch {
        throw ('Cleanup' + $Name + 'Invalid：JSON 無法解析：' + $resolvedPath + '；' + $_.Exception.Message)
    }
    if ($null -eq $document -or $document -isnot [psobject]) {
        throw ('Cleanup' + $Name + 'Invalid：根節點必須是 JSON object：' + $resolvedPath)
    }
    return [pscustomobject]@{ Path = $resolvedPath; Document = $document }
}

function Get-CleanupRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $resolvedPath = Resolve-AbsolutePath -Path $Path
    $resolvedRoot = (Resolve-AbsolutePath -Path $Root).TrimEnd([char[]]@([char]92, [char]47))
    if (-not (Test-PathWithinRoot -Path $resolvedPath -Root $resolvedRoot) -or [string]::Equals($resolvedPath, $resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('CleanupSourceBoundary：來源路徑超出 dispatch worktree：' + $resolvedPath)
    }
    return $resolvedPath.Substring($resolvedRoot.Length).TrimStart([char[]]@([char]92, [char]47)).Replace('\', '/')
}

function Add-CleanupInventoryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Inventory,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Seen,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DispatchRoot,
        [Parameter(Mandatory)][string]$SourceName
    )

    $resolvedPath = Resolve-AbsolutePath -Path $Path
    if (-not (Test-PathWithinRoot -Path $resolvedPath -Root $DispatchRoot) -or [string]::Equals($resolvedPath, (Resolve-AbsolutePath $DispatchRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw ('CleanupSourceBoundary：' + $SourceName + ' 不屬於 dispatch worktree：' + $resolvedPath)
    }
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw ('CleanupSourceMissing：找不到 ' + $SourceName + '：' + $resolvedPath)
    }
    Assert-DispatchOutputPathNoReparsePoint -Root $DispatchRoot -Path $resolvedPath
    $item = Get-Item -LiteralPath $resolvedPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw ('CleanupSourceBoundary：不允許保存 reparse point：' + $resolvedPath)
    }
    $key = $resolvedPath.ToLowerInvariant()
    if ($Seen.Add($key)) {
        $Inventory.Add([ordered]@{
                source_path = $resolvedPath
                relative_path = Get-CleanupRelativePath -Path $resolvedPath -Root $DispatchRoot
                source_name = $SourceName
            })
    }
}

function Get-CleanupRecordReferencedPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Record
    )

    $pathNames = @(
        'event_stream_path', 'error_stream_path', 'last_message_path', 'preflight_result_path', 'pid_record_path',
        'thread_id_path', 'launcher_path', 'process_exit_code_sidecar_path', 'prompt_path',
        'prompt_source_path', 'prompt_transfer_path', 'inspect_result_path', 'evidence_pack_path',
        'request_path', 'scope_plan_path', 'scope_plan_parent_path', 'baseline_path',
        'prepare_result_path', 'interruption_checkpoint_path'
    )
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($name in $pathNames) {
        $value = Get-CleanupPropertyValue -Object $Record -Names @($name)
        if ($null -ne $value -and $value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            $paths.Add([string]$value)
        }
    }
    $packPath = [string](Get-CleanupPropertyValue -Object $Record -Names @('evidence_pack_path'))
    $executionRoot = [string](Get-CleanupPropertyValue -Object $Record -Names @('execution_root'))
    $dispatchSlug = [string](Get-CleanupPropertyValue -Object $Record -Names @('dispatch_slug'))
    if (-not [string]::IsNullOrWhiteSpace($packPath) -and -not [string]::IsNullOrWhiteSpace($executionRoot) -and -not [string]::IsNullOrWhiteSpace($dispatchSlug)) {
        $historyRoot = Join-Path (Resolve-AbsolutePath -Path $executionRoot) '.local\ai-sessions\history'
        $sidecarRoot = Split-Path -Parent (Resolve-AbsolutePath -Path $packPath)
        if (-not [string]::Equals($sidecarRoot, $historyRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $sidecarRoot = $historyRoot
        }
        foreach ($extension in @('sha256', 'length')) {
            $paths.Add((Join-Path $sidecarRoot ('evidence-pack-' + $dispatchSlug + '.' + $extension)))
        }
    }
    return @($paths.ToArray())
}

function Get-CleanupUnpreservedReportFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DispatchRoot,
        [Parameter(Mandatory)][string]$ReportRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$PreservedItems
    )

    if (-not (Test-Path -LiteralPath $ReportRoot -PathType Container)) { return @() }
    Assert-DispatchOutputPathNoReparsePoint -Root $DispatchRoot -Path $ReportRoot
    $preservedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $PreservedItems) {
        $null = $preservedPaths.Add((Resolve-AbsolutePath -Path ([string]$item.source_path)))
    }
    return @(Get-CleanupRemovalEntries -Root $ReportRoot | Where-Object {
        -not $_.PSIsContainer -and -not $preservedPaths.Contains((Resolve-AbsolutePath -Path $_.FullName))
    } | ForEach-Object { $_.FullName })
}

function Get-CleanupSiblingRunRecordPaths {
    [CmdletBinding()]
    param([string]$SourceRoot, [string]$LineSlug, [string]$DispatchSlug)

    $directory = Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    if (Test-Path -LiteralPath $directory -PathType Container) {
        Get-ChildItem -LiteralPath $directory -Filter '*.json' -File | ForEach-Object { $_.FullName }
    }
}

function Test-CleanupAlreadyPreservedFile {
    [CmdletBinding()]
    param([string]$Path, [string]$SourceRoot, [object[]]$AlreadyPreservedFiles)

    $resolved = Resolve-AbsolutePath -Path $Path
    $saved = @($AlreadyPreservedFiles | Where-Object { [string]::Equals([string]$_.source_path, $resolved, [StringComparison]::OrdinalIgnoreCase) })
    if ($saved.Count -ne 1 -or [string]$saved[0].source_sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [string]$saved[0].destination_sha256 -notmatch '^[a-fA-F0-9]{64}$') { return $false }
    $destination = Resolve-AbsolutePath -Path ([string]$saved[0].destination_path)
    if (-not (Test-PathWithinRoot -Path $destination -Root $SourceRoot)) { return $false }
    Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $destination
    return (Test-Path -LiteralPath $destination -PathType Leaf) -and (Get-FileSha256 -Path $destination) -ieq [string]$saved[0].destination_sha256
}

function Get-CleanupInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DispatchRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [AllowEmptyString()][string]$RunRecordPath,
        [AllowEmptyCollection()][string[]]$EvidencePath,
        [AllowEmptyCollection()][string[]]$ReportPath = @(),
        [AllowEmptyCollection()][object[]]$AlreadyPreservedFiles = @()
    )

    $inventory = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $reportRoot = Join-Path (Join-Path (Resolve-AbsolutePath $DispatchRoot) '.local\ai-sessions\report') $LineSlug
    Assert-DispatchOutputPathNoReparsePoint -Root $DispatchRoot -Path $reportRoot
    if (Test-Path -LiteralPath $reportRoot -PathType Container) {
        foreach ($file in @(Get-CleanupRemovalEntries -Root $reportRoot | Where-Object { -not $_.PSIsContainer })) {
            Add-CleanupInventoryPath -Inventory $inventory -Seen $seen -Path $file.FullName -DispatchRoot $DispatchRoot -SourceName '同線報告'
        }
    }

    $allReportsRoot = Split-Path -Parent $reportRoot
    $dispatchReport = Join-Path $allReportsRoot ('dispatch-report-' + $DispatchSlug + '.md')
    Assert-DispatchOutputPathNoReparsePoint -Root $DispatchRoot -Path $dispatchReport
    if (Test-Path -LiteralPath $dispatchReport -PathType Leaf) {
        Add-CleanupInventoryPath -Inventory $inventory -Seen $seen -Path $dispatchReport -DispatchRoot $DispatchRoot -SourceName '派遣報告'
    }
    foreach ($report in @($ReportPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        Assert-DispatchOutputPathNoReparsePoint -Root $DispatchRoot -Path $report
        if (-not (Test-Path -LiteralPath $report) -and (Test-CleanupAlreadyPreservedFile -Path $report -SourceRoot $SourceRoot -AlreadyPreservedFiles $AlreadyPreservedFiles)) { continue }
        if (Test-Path -LiteralPath $report -PathType Container) {
            foreach ($file in @(Get-CleanupRemovalEntries -Root $report | Where-Object { -not $_.PSIsContainer })) {
                Add-CleanupInventoryPath -Inventory $inventory -Seen $seen -Path $file.FullName -DispatchRoot $DispatchRoot -SourceName 'ReportPath'
            }
        }
        else { Add-CleanupInventoryPath -Inventory $inventory -Seen $seen -Path $report -DispatchRoot $DispatchRoot -SourceName 'ReportPath' }
    }

    $record = $null
    $recordPathValue = $null
    $recordReferencedPaths = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($RunRecordPath)) {
        $recordPathValue = Resolve-AbsolutePath -Path $RunRecordPath
        $sourceHistoryRoot = Join-Path (Resolve-AbsolutePath $SourceRoot) '.local\ai-sessions\history'
        $expectedRunRoot = Join-Path (Join-Path $sourceHistoryRoot $LineSlug) (Join-Path 'runs' $DispatchSlug)
        if (-not (Test-PathWithinRoot -Path $recordPathValue -Root $sourceHistoryRoot) -or -not [string]::Equals((Split-Path -Parent $recordPathValue), (Resolve-AbsolutePath $expectedRunRoot), [StringComparison]::OrdinalIgnoreCase)) {
            throw ('CleanupRunRecordBoundary：RunRecord 路徑不屬於目前 line／dispatch：' + $recordPathValue)
        }
        Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $recordPathValue
        $recordDocument = Read-CleanupJsonDocument -Path $recordPathValue -Name 'RunRecord'
        $record = $recordDocument.Document
        foreach ($entry in @(
                [pscustomobject]@{ field = 'line_slug'; expected = $LineSlug; received = [string](Get-CleanupPropertyValue -Object $record -Names @('line_slug', 'lineSlug')) },
                [pscustomobject]@{ field = 'dispatch_slug'; expected = $DispatchSlug; received = [string](Get-CleanupPropertyValue -Object $record -Names @('dispatch_slug', 'dispatchSlug')) },
                [pscustomobject]@{ field = 'source_root'; expected = (Resolve-AbsolutePath $SourceRoot); received = [string](Get-CleanupPropertyValue -Object $record -Names @('source_root', 'sourceRoot')) },
                [pscustomobject]@{ field = 'execution_root'; expected = (Resolve-AbsolutePath $DispatchRoot); received = [string](Get-CleanupPropertyValue -Object $record -Names @('execution_root', 'executionRoot')) }
            )) {
            $received = [string]$entry.received
            if ($entry.field -in @('source_root', 'execution_root') -and -not [string]::IsNullOrWhiteSpace($received)) {
                try { $received = Resolve-AbsolutePath -Path $received } catch { }
            }
            if (-not [string]::Equals([string]$entry.expected, $received, [StringComparison]::OrdinalIgnoreCase)) {
                $mismatch = New-CleanupIdentityMismatch -Field ('run_record.' + $entry.field) -Expected $entry.expected -Received $received -Source $recordPathValue
                throw ('CleanupIdentityMismatch：' + (ConvertTo-Json -InputObject $mismatch -Compress -Depth 10))
            }
        }
        foreach ($path in @(Get-CleanupRecordReferencedPaths -Record $record)) {
            $resolvedReferencedPath = Resolve-AbsolutePath -Path $path
            if (Test-PathWithinRoot -Path $resolvedReferencedPath -Root $DispatchRoot) {
                $recordReferencedPaths.Add($resolvedReferencedPath)
                if (Test-Path -LiteralPath $resolvedReferencedPath -PathType Leaf) {
                    Add-CleanupInventoryPath -Inventory $inventory -Seen $seen -Path $resolvedReferencedPath -DispatchRoot $DispatchRoot -SourceName ('RunRecord.' + $path)
                }
            }
        }
        foreach ($siblingPath in @(Get-CleanupSiblingRunRecordPaths -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug)) {
            if ([string]::Equals($siblingPath, $recordPathValue, [StringComparison]::OrdinalIgnoreCase)) { continue }
            try { $sibling = Read-DispatchRunRecord -Path $siblingPath -SourceRoot $SourceRoot -ExecutionRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug }
            catch { throw ('CleanupIdentityMismatch：sibling RunRecord 身分無效：' + $siblingPath + '；' + $_.Exception.Message) }
            foreach ($path in @(Get-CleanupRecordReferencedPaths -Record $sibling)) {
                $resolvedPath = Resolve-AbsolutePath -Path $path
                if (Test-PathWithinRoot -Path $resolvedPath -Root $DispatchRoot) {
                    $recordReferencedPaths.Add($resolvedPath)
                    if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
                        Add-CleanupInventoryPath -Inventory $inventory -Seen $seen -Path $resolvedPath -DispatchRoot $DispatchRoot -SourceName 'SiblingRunRecord'
                    }
                }
            }
        }
    }

    $requestedEvidence = if ($null -eq $EvidencePath -or $EvidencePath.Count -eq 0) { @($recordReferencedPaths.ToArray() | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) } else { @($EvidencePath) }
    foreach ($evidence in $requestedEvidence) {
        if ([string]::IsNullOrWhiteSpace([string]$evidence)) {
            throw 'CleanupEvidenceInvalid：EvidencePath 不可為空。'
        }
        $resolvedEvidence = Resolve-AbsolutePath -Path ([string]$evidence)
        if (-not (Test-PathWithinRoot -Path $resolvedEvidence -Root $DispatchRoot)) {
            throw ('CleanupSourceBoundary：EvidencePath 不屬於 dispatch worktree：' + $resolvedEvidence)
        }
        $referenced = @($recordReferencedPaths | Where-Object { [string]::Equals($_, $resolvedEvidence, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if (-not $referenced) {
            throw ('CleanupEvidenceUnreferenced：EvidencePath 未被目前 RunRecord 引用：' + $resolvedEvidence + '；可接受的檔案：' + ($recordReferencedPaths.ToArray() -join '; '))
        }
        if (-not (Test-Path -LiteralPath $resolvedEvidence -PathType Leaf) -and (Test-CleanupAlreadyPreservedFile -Path $resolvedEvidence -SourceRoot $SourceRoot -AlreadyPreservedFiles $AlreadyPreservedFiles)) { continue }
        Add-CleanupInventoryPath -Inventory $inventory -Seen $seen -Path $resolvedEvidence -DispatchRoot $DispatchRoot -SourceName 'EvidencePath'
    }

    $unpreservedReports = @(Get-CleanupUnpreservedReportFiles -DispatchRoot $DispatchRoot -ReportRoot $allReportsRoot -PreservedItems @($inventory.ToArray()))
    if ($unpreservedReports.Count -gt 0) {
        $exception = New-Object InvalidOperationException('CleanupReportUnpreserved：report 根目錄含未列入保存清單的檔案：' + ($unpreservedReports -join '; '))
        $exception.Data['errorCode'] = 'CleanupReportUnpreserved'
        $exception.Data['unpreservedPaths'] = $unpreservedReports
        throw $exception
    }
    return [pscustomobject]@{
        report_root = $reportRoot
        run_record = $record
        run_record_path = $recordPathValue
        referenced_paths = @($recordReferencedPaths.ToArray())
        items = @($inventory.ToArray())
    }
}

function ConvertTo-CleanupExceptionBlockText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $lines = @((($Text -replace "`r`n|`r", "`n").Split("`n")))
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $lines[$index] = $lines[$index].TrimEnd([char[]]@(' ', "`t"))
    }
    $last = $lines.Count - 1
    while ($last -ge 0 -and $lines[$last].Length -eq 0) { $last-- }
    if ($last -lt 0) { return '' }
    return ($lines[0..$last] -join "`n")
}

function Get-CleanupExceptionBlocks {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $lineNormalized = $Text -replace "`r`n|`r", "`n"
    $headings = [regex]::Matches($lineNormalized, '(?m)^## [^\n]*')
    $preamble = if ($headings.Count -eq 0) { $lineNormalized } else { $lineNormalized.Substring(0, $headings[0].Index) }
    $blocks = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $headings.Count; $index++) {
        $start = $headings[$index].Index
        $end = if ($index + 1 -lt $headings.Count) { $headings[$index + 1].Index } else { $lineNormalized.Length }
        $blockText = ConvertTo-CleanupExceptionBlockText -Text $lineNormalized.Substring($start, $end - $start)
        $title = ConvertTo-CleanupExceptionBlockText -Text $headings[$index].Value
        $blocks.Add([pscustomobject]@{ Title = $title; Text = $blockText })
    }
    return [pscustomobject]@{ Preamble = ConvertTo-CleanupExceptionBlockText -Text $preamble; Blocks = @($blocks.ToArray()) }
}

function Join-CleanupExceptionBlocks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceText,
        [Parameter(Mandatory)][AllowEmptyString()][string]$DestinationText
    )

    $source = Get-CleanupExceptionBlocks -Text $SourceText
    $destination = Get-CleanupExceptionBlocks -Text $DestinationText
    $sourceHeaderOnly = @($source.Preamble -split "`n" | Where-Object { $_ -notmatch '^(?:[ \t]*| {0,3}#[ \t]+.+)$' }).Count -eq 0
    $destinationHeaderOnly = @($destination.Preamble -split "`n" | Where-Object { $_ -notmatch '^(?:[ \t]*| {0,3}#[ \t]+.+)$' }).Count -eq 0
    if ($source.Preamble -cne $destination.Preamble -and -not ($sourceHeaderOnly -and $destinationHeaderOnly)) {
        throw 'CleanupExceptionsConflict：exceptions.md 的標題前內容不一致。'
    }
    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($block in @($destination.Blocks)) {
        $null = $known.Add($block.Text)
    }
    $seenSource = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $newBlocks = New-Object System.Collections.Generic.List[string]
    foreach ($block in @($source.Blocks)) {
        if (-not $seenSource.Add($block.Text)) { continue }
        if (-not $known.Add($block.Text)) { continue }
        $newBlocks.Add($block.Text)
    }
    if ($newBlocks.Count -eq 0) { return $null }
    $baseText = ($DestinationText -replace "`r`n|`r|`n", "`r`n").TrimEnd([char[]]@("`r", "`n"))
    $appended = @($newBlocks.ToArray() | ForEach-Object { $_ -replace "`n", "`r`n" }) -join "`r`n`r`n"
    if ($baseText.Length -eq 0) { return $appended + "`r`n" }
    return $baseText + "`r`n`r`n" + $appended + "`r`n"
}

function Get-CleanupReportVersion {
    [CmdletBinding()]
    param([string]$Path, [string]$SourceRoot, [string]$LineSlug, [string]$KnownDispatchSlug)

    $reportPath = ConvertTo-FileSystemApiPath -Path (Resolve-AbsolutePath -Path $Path)
    $text = [IO.File]::ReadAllText($reportPath, (New-Object Text.UTF8Encoding($false, $true)))
    $manifest = $null
    $section = [regex]::Match($text, '(?ms)^## Finding manifest[ \t]*\r?\n(?<section>.*?)(?=^## |\z)')
    if ($section.Success) {
        $json = [regex]::Matches($section.Groups['section'].Value, '(?ms)^```json[ \t]*\r?\n(?<json>.*?)^```[ \t]*\r?$')
        if ($json.Count -ne 1) { throw ('CleanupReportVersionUnknown：報告 manifest 格式不明：' + $Path) }
        $manifest = ConvertFrom-DispatchJson -Content $json[0].Groups['json'].Value
    }
    $slug = [string](Get-CleanupPropertyValue -Object $manifest -Names @('dispatch_slug'))
    $round = 0L
    $manifestLine = [string](Get-CleanupPropertyValue -Object $manifest -Names @('line_slug'))
    if ($null -ne $manifest) {
        if ([string](Get-CleanupPropertyValue -Object $manifest -Names @('schema')) -notin @('codex-dispatch.review-findings.v1','codex-dispatch.review-findings.v2') -or
            ($manifestLine -and $manifestLine -cne $LineSlug)) { throw ('CleanupReportVersionUnknown：報告 manifest 身分不符：' + $Path) }
        if (-not [long]::TryParse([string](Get-CleanupPropertyValue -Object $manifest -Names @('round')), [ref]$round) -or $round -lt 1) { $round = 0L }
    }
    if ([string]::IsNullOrWhiteSpace($slug)) {
        $ids = @([regex]::Matches($text, '(?m)dispatchSlug[=:][ \t]*([a-z0-9]+(?:-[a-z0-9]+)*)(?=[\s,，；;]|$)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        if ($ids.Count -eq 1) { $slug = $ids[0] }
        elseif (-not [string]::IsNullOrWhiteSpace($KnownDispatchSlug)) { $slug = $KnownDispatchSlug }
    }
    if ($KnownDispatchSlug -and $slug -and $slug -cne $KnownDispatchSlug) { throw ('CleanupReportVersionUnknown：報告所屬派遣不符：' + $Path) }
    $started = $null
    $recordPaths = @()
    if ($slug -match '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        $runRoot = Join-Path $SourceRoot ('.local\ai-sessions\history\' + $LineSlug + '\runs\' + $slug)
        Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $runRoot
        if (Test-Path -LiteralPath $runRoot -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $runRoot -Filter '*.json' -File)) {
                Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $file.FullName
                $record = (Read-CleanupJsonDocument -Path $file.FullName -Name 'RunRecord').Document
                if ([string](Get-CleanupPropertyValue $record @('schema')) -cne 'ai-sessions.dispatch-run.v1' -or
                    [string](Get-CleanupPropertyValue $record @('line_slug')) -cne $LineSlug -or
                    [string](Get-CleanupPropertyValue $record @('dispatch_slug')) -cne $slug -or
                    -not [string]::Equals([string](Get-CleanupPropertyValue $record @('source_root')), (Resolve-AbsolutePath $SourceRoot), [StringComparison]::OrdinalIgnoreCase)) { throw ('CleanupReportVersionUnknown：RunRecord 身分不符：' + $file.FullName) }
                $time = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse([string](Get-CleanupPropertyValue $record @('started_at_utc')), [ref]$time)) {
                    if ($null -eq $started -or $time -gt $started) { $started = $time; $recordPaths = @($file.FullName) }
                }
            }
        }
    }
    return [pscustomobject]@{ path = $Path; dispatch_slug = $slug; round = $round; started_at = $started; run_record_paths = $recordPaths }
}

function Test-CleanupReportVersionUnknownFallback {
    [CmdletBinding()]
    param([string]$FileName)

    return @($script:CleanupFixedReportNames | Where-Object { ($_.Name + '.md') -ceq $FileName -and $_.VersionUnknownFallback }).Count -gt 0
}

function Compare-CleanupReportVersion {
    [CmdletBinding()]
    param([string]$IncomingPath, [string]$DestinationPath, [string]$SourceRoot, [string]$LineSlug, [string]$DispatchSlug)

    try {
        $incoming = Get-CleanupReportVersion -Path $IncomingPath -SourceRoot $SourceRoot -LineSlug $LineSlug -KnownDispatchSlug $DispatchSlug
        $destination = Get-CleanupReportVersion -Path $DestinationPath -SourceRoot $SourceRoot -LineSlug $LineSlug -KnownDispatchSlug ''
    }
    catch {
        if ((Test-CleanupReportVersionUnknownFallback -FileName ([IO.Path]::GetFileName($IncomingPath))) -and $_.Exception.Message -like 'CleanupReportVersionUnknown*') {
            return [ordered]@{ basis = 'closure-version-unknown'; incoming = $null; destination = $null; incoming_newer = $false }
        }
        throw
    }
    $kind = ''; $comparison = 0
    if ($null -ne $incoming.started_at -and $null -ne $destination.started_at -and $incoming.dispatch_slug -cne $destination.dispatch_slug) {
        $kind = 'run-record-started-at-utc'; $comparison = [DateTimeOffset]::Compare($incoming.started_at, $destination.started_at)
    }
    elseif ($incoming.round -gt 0 -and $destination.round -gt 0) {
        $kind = 'report-manifest-round'; $comparison = $incoming.round.CompareTo($destination.round)
    }
    if ($comparison -eq 0) {
        if (Test-CleanupReportVersionUnknownFallback -FileName ([IO.Path]::GetFileName($IncomingPath))) {
            return [ordered]@{ basis = 'closure-version-unknown'; incoming = $incoming; destination = $destination; incoming_newer = $false }
        }
        throw ('CleanupReportVersionUnknown：無法判斷固定報告新舊，保留 worktree。incoming=' + $IncomingPath + '; destination=' + $DestinationPath)
    }
    return [ordered]@{ basis = $kind; incoming = $incoming; destination = $destination; incoming_newer = $comparison -gt 0 }
}

function Preserve-CleanupFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Item,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DispatchRoot,
        [string]$DispatchSlug
    )

    $sourcePath = [string]$Item.source_path
    $null = Get-CleanupRelativePath -Path $sourcePath -Root $DispatchRoot
    Assert-DispatchOutputPathNoReparsePoint -Root $DispatchRoot -Path $sourcePath
    $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
    $destinationPath = Join-Path $sourceRootPath ([string]$Item.relative_path -replace '/', '\')
    $destinationPath = Resolve-AbsolutePath -Path $destinationPath
    if (-not (Test-PathWithinRoot -Path $destinationPath -Root $sourceRootPath)) {
        throw ('CleanupDestinationBoundary：destination 超出 sourceRoot：' + $destinationPath)
    }
    Assert-DispatchOutputPathNoReparsePoint -Root $sourceRootPath -Path $destinationPath
    try {
        $bytes = [IO.File]::ReadAllBytes((ConvertTo-FileSystemApiPath -Path $sourcePath))
        $sourceHashBefore = Get-DispatchByteArraySha256 -Bytes $bytes
    }
    catch { throw ('CleanupSourceReadFailed：無法讀取或計算 SHA-256：' + $sourcePath + '；' + $_.Exception.Message) }
    $parent = Split-Path -Parent $destinationPath
    $null = New-DispatchOutputDirectory -Path $parent -SourceRoot $sourceRootPath -ExecutionRoot $DispatchRoot -TargetPath @()
    Assert-DispatchOutputPathNoReparsePoint -Root $sourceRootPath -Path $destinationPath
    $destinationExists = [IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $destinationPath))
    $destinationIsDirectory = [IO.Directory]::Exists((ConvertTo-FileSystemApiPath -Path $destinationPath))
    if ($destinationIsDirectory) {
        throw ('CleanupDestinationConflict：destination 是目錄：' + $destinationPath)
    }
    $expectedDestinationHash = $sourceHashBefore
    $expectedDestinationLength = [int64]$bytes.Length
    $archivePath = $null
    $versionDecision = $null
    if ($destinationExists) {
        $existingHash = Get-FileSha256 -Path $destinationPath
        $existingLength = [int64]([IO.FileInfo]::new((ConvertTo-FileSystemApiPath -Path $destinationPath))).Length
        if ([string]$Item.relative_path -cmatch '^\.local/ai-sessions/report/[a-z0-9]+(?:-[a-z0-9]+)*/exceptions\.md$') {
            $strictUtf8 = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
            $sourceText = $strictUtf8.GetString($bytes)
            $destinationText = [IO.File]::ReadAllText((ConvertTo-FileSystemApiPath -Path $destinationPath), $strictUtf8)
            $mergedText = Join-CleanupExceptionBlocks -SourceText $sourceText -DestinationText $destinationText
            $expectedDestinationHash = $existingHash
            $expectedDestinationLength = $existingLength
            if ($null -ne $mergedText) {
                $mergedBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($mergedText)
                $expectedDestinationHash = Get-DispatchByteArraySha256 -Bytes $mergedBytes
                $expectedDestinationLength = [int64]$mergedBytes.Length
                $temporaryPath = Join-Path $parent ([guid]::NewGuid().ToString('N') + '.cleanup.tmp')
                $backupPath = Join-Path $parent ([guid]::NewGuid().ToString('N') + '.cleanup.bak')
                try {
                    Assert-DispatchOutputPathNoReparsePoint -Root $sourceRootPath -Path $temporaryPath
                    Assert-DispatchOutputPathNoReparsePoint -Root $sourceRootPath -Path $backupPath
                    [IO.File]::WriteAllBytes((ConvertTo-FileSystemApiPath -Path $temporaryPath), $mergedBytes)
                    if ((Get-FileSha256 -Path $sourcePath) -ine $sourceHashBefore -or
                        (Get-FileSha256 -Path $destinationPath) -ine $existingHash) {
                        throw ('CleanupDestinationConflict：exceptions.md 在合併期間變更：' + $destinationPath)
                    }
                    Assert-DispatchOutputPathNoReparsePoint -Root $sourceRootPath -Path $destinationPath
                    $null = Invoke-FileReplaceWithRetry -Source $temporaryPath -Destination $destinationPath -BackupPath $backupPath
                }
                finally {
                    if ([IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $temporaryPath))) {
                        [IO.File]::Delete((ConvertTo-FileSystemApiPath -Path $temporaryPath))
                    }
                    if ([IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $backupPath))) {
                        [IO.File]::Delete((ConvertTo-FileSystemApiPath -Path $backupPath))
                    }
                }
            }
        }
        elseif ($existingHash -ine $sourceHashBefore -and
            [string]$Item.relative_path -cmatch ('^\.local/ai-sessions/report/(?:[a-z0-9]+(?:-[a-z0-9]+)*/(?:' + (($script:CleanupFixedReportNames | ForEach-Object { [regex]::Escape($_.Name) }) -join '|') + ')|dispatch-report-[a-z0-9]+(?:-[a-z0-9]+)*)\.md$')) {
            $lineMatch = [regex]::Match([string]$Item.relative_path, '^\.local/ai-sessions/report/([a-z0-9]+(?:-[a-z0-9]+)*)/')
            $reportLineSlug = if ($lineMatch.Success) { $lineMatch.Groups[1].Value } else { [string](Get-DispatchScriptVariableValue -Name 'LineSlug') }
            $versionDecision = Compare-CleanupReportVersion -IncomingPath $sourcePath -DestinationPath $destinationPath -SourceRoot $SourceRoot -LineSlug $reportLineSlug -DispatchSlug $DispatchSlug
            $archiveSlug = if ([string]::IsNullOrWhiteSpace($DispatchSlug)) { Split-Path -Leaf $DispatchRoot } else { $DispatchSlug }
            if ($archiveSlug -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw 'CleanupArchiveIdentityInvalid：封存 dispatch slug 格式不符。' }
            $archiveName = [IO.Path]::GetFileNameWithoutExtension($destinationPath) + '.' + $archiveSlug + '.' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ') + '.' + [guid]::NewGuid().ToString('N') + '.md'
            $archivePath = Join-Path $parent $archiveName
            $temporaryPath = Join-Path $parent ([guid]::NewGuid().ToString('N') + '.cleanup.tmp')
            try {
                Assert-DispatchOutputPathNoReparsePoint -Root $sourceRootPath -Path $archivePath
                Assert-DispatchOutputPathNoReparsePoint -Root $sourceRootPath -Path $temporaryPath
                [IO.File]::WriteAllBytes((ConvertTo-FileSystemApiPath -Path $temporaryPath), $bytes)
                if ((Get-FileSha256 -Path $sourcePath) -ine $sourceHashBefore -or
                    (Get-FileSha256 -Path $destinationPath) -ine $existingHash) {
                    throw ('CleanupDestinationConflict：固定報告在封存期間變更：' + $destinationPath)
                }
                if ($versionDecision.incoming_newer) {
                    $null = Invoke-FileReplaceWithRetry -Source $temporaryPath -Destination $destinationPath -BackupPath $archivePath
                    $archiveHash = $existingHash
                }
                else {
                    [IO.File]::Move((ConvertTo-FileSystemApiPath -Path $temporaryPath), (ConvertTo-FileSystemApiPath -Path $archivePath))
                    $archiveHash = $sourceHashBefore
                    $expectedDestinationHash = $existingHash
                    $expectedDestinationLength = $existingLength
                }
                if ((Get-FileSha256 -Path $archivePath) -ine $archiveHash) { throw ('CleanupHashMismatch：封存 SHA-256 不一致：' + $archivePath) }
            }
            finally {
                if ([IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $temporaryPath))) { [IO.File]::Delete((ConvertTo-FileSystemApiPath -Path $temporaryPath)) }
            }
        }
        elseif (-not [string]::Equals($existingHash, $sourceHashBefore, [StringComparison]::OrdinalIgnoreCase)) {
            throw ('CleanupDestinationConflict：destination SHA-256 不同：' + $destinationPath)
        }
    }
    else {
        $temporaryPath = Join-Path $parent ([guid]::NewGuid().ToString('N') + '.cleanup.tmp')
        try {
            Assert-DispatchOutputPathNoReparsePoint -Root $sourceRootPath -Path $temporaryPath
            Assert-DispatchOutputPathNoReparsePoint -Root $sourceRootPath -Path $destinationPath
            [IO.File]::WriteAllBytes((ConvertTo-FileSystemApiPath -Path $temporaryPath), $bytes)
            if ([IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $destinationPath))) {
                $existingHash = Get-FileSha256 -Path $destinationPath
                if (-not [string]::Equals($existingHash, $sourceHashBefore, [StringComparison]::OrdinalIgnoreCase)) {
                    throw ('CleanupDestinationConflict：destination 在保存期間建立且內容不同：' + $destinationPath)
                }
            }
            else {
                Assert-DispatchOutputPathNoReparsePoint -Root $sourceRootPath -Path $temporaryPath
                Assert-DispatchOutputPathNoReparsePoint -Root $sourceRootPath -Path $destinationPath
                [IO.File]::Move((ConvertTo-FileSystemApiPath -Path $temporaryPath), (ConvertTo-FileSystemApiPath -Path $destinationPath))
            }
        }
        finally {
            if ([IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $temporaryPath))) {
                [IO.File]::Delete((ConvertTo-FileSystemApiPath -Path $temporaryPath))
            }
        }
    }
    $sourceHashAfter = Get-FileSha256 -Path $sourcePath
    $sourceLengthAfter = [int64]([IO.FileInfo]::new((ConvertTo-FileSystemApiPath -Path $sourcePath))).Length
    if ($sourceLengthAfter -ne [int64]$bytes.Length -or -not [string]::Equals($sourceHashBefore, $sourceHashAfter, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('SourceChangedDuringPreservation：來源在保存期間變更：' + $sourcePath)
    }
    $destinationLength = [int64]([IO.FileInfo]::new((ConvertTo-FileSystemApiPath -Path $destinationPath))).Length
    if ($destinationLength -ne $expectedDestinationLength) {
        throw ('CleanupLengthMismatch：destination 長度不一致：' + $destinationPath)
    }
    $destinationHash = Get-FileSha256 -Path $destinationPath
    if (-not [string]::Equals($expectedDestinationHash, $destinationHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('CleanupHashMismatch：destination SHA-256 不一致：' + $destinationPath)
    }
    $readback = [ordered]@{ status = 'passed'; error = $null }
    return [ordered]@{
        source_path = $sourcePath
        destination_path = $destinationPath
        relative_path = [string]$Item.relative_path
        source_sha256 = $sourceHashAfter
        destination_sha256 = $destinationHash
        length = [int64]$bytes.Length
        readback = $readback
        status = 'preserved'
        archive_path = $archivePath
        version_decision = $versionDecision
    }
}

function Get-CleanupRemovalEntries {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        Assert-DispatchOutputPathNoReparsePoint -Root $Root -Path $directory
        foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            Assert-DispatchOutputPathNoReparsePoint -Root $Root -Path $entry.FullName
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw ('CleanupRemovalReparsePoint：' + $entry.FullName) }
            $entries.Add($entry)
            if ($entry.PSIsContainer) { $pending.Push($entry.FullName) }
        }
    }
    return @($entries.ToArray())
}

function Remove-CleanupWorktreeContents {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Root)

    $entries = @(Get-CleanupRemovalEntries -Root $Root)
    $handles = New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach ($entry in @($entries | Where-Object { -not $_.PSIsContainer })) {
            try { $handles.Add([IO.File]::Open($entry.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)) }
            catch { throw ('CleanupWorktreeRemovalFailed：檔案無法取得獨占存取：' + $entry.FullName + '；' + $_.Exception.Message) }
        }
    }
    finally { foreach ($handle in $handles) { $handle.Dispose() } }
    foreach ($entry in @($entries | Sort-Object -Property @{ Expression = { $_.FullName.Length }; Descending = $true })) {
        if ([string]::Equals($entry.FullName, (Join-Path $Root '.git'), [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not $PSCmdlet.ShouldProcess($entry.FullName, '清除已保存且程序已結束的 worktree 內容')) { continue }
        Assert-DispatchOutputPathNoReparsePoint -Root $Root -Path $entry.FullName
        try {
            if ($entry.PSIsContainer) { [IO.Directory]::Delete($entry.FullName, $false) }
            else {
                if (($entry.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) { [IO.File]::SetAttributes($entry.FullName, ($entry.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly))) }
                [IO.File]::Delete($entry.FullName)
            }
        }
        catch { throw ('CleanupWorktreeRemovalFailed：無法刪除：' + $entry.FullName + '；' + $_.Exception.Message) }
    }
}

function Test-CleanupRemovalReceipt {
    [CmdletBinding()]
    param([string]$Path, [string]$SourceRoot, [string]$DispatchRoot, [string]$LineSlug, [string]$DispatchSlug)

    Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $Path
    if (-not [IO.File]::Exists($Path)) { return $false }
    $receipt = (Read-CleanupJsonDocument -Path $Path -Name 'RemovalResult').Document
    foreach ($pair in @(@('schema','ai-sessions.dispatch-cleanup-result.v1'), @('source_root',$SourceRoot), @('dispatch_root',$DispatchRoot), @('line_slug',$LineSlug), @('dispatch_slug',$DispatchSlug), @('status','removal-failed'))) {
        if ([string](Get-CleanupPropertyValue -Object $receipt -Names @($pair[0])) -cne [string]$pair[1]) { return $false }
    }
    $removal = Get-CleanupPropertyValue -Object $receipt -Names @('removal')
    $registeredBefore = Get-CleanupPropertyValue -Object $removal -Names @('registered_before')
    $stopped = Get-CleanupPropertyValue -Object $removal -Names @('process_ended_verified')
    $fingerprint = [string](Get-CleanupPropertyValue -Object $removal -Names @('caller_session_fingerprint'))
    $caller = Get-DispatchScriptVariableValue -Name 'CallerSessionIdentity'
    $currentFingerprint = if ($null -eq $caller) { '' } else { [string]$caller.Fingerprint }
    if ($fingerprint -cne $currentFingerprint) { return $false }
    return ($registeredBefore -is [bool] -and $registeredBefore -and $stopped -is [bool] -and $stopped)
}

function Assert-CleanupStopped {
    [CmdletBinding()]
    param([string]$SourceRoot, [string]$DispatchSlug, [string]$LineSlug, [AllowNull()][object]$Owner)

    Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path (Join-Path $SourceRoot '.local\ai-sessions\history')
    $pidCheck = Get-PidCheckResult -SourceRoot $SourceRoot -LineSlug $LineSlug -WriteMode 'write'
    $blockers = @(Get-BlockingDispatchPidRecords -PidCheckResult $pidCheck -DispatchSlug $DispatchSlug)
    if ($blockers.Count -gt 0) { throw (New-DispatchPidIdentityBlockedMessage -DispatchSlug $DispatchSlug -Records $blockers) }
    if ($null -ne $Owner) {
        $state = Get-DispatchAdmissionOwnerState -Entry $Owner
        if ($state -notin @('ended','pid-reused')) { throw ('CleanupProcessNotEnded：owner process 尚未確認結束：' + $state) }
    }
}

function Test-CleanupUnstartedRunRecordEventStreamPresent {
    [CmdletBinding()]
    param([string]$Path, [string]$SourceRoot, [string]$ExecutionRoot, [string]$LineSlug, [string]$DispatchSlug)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $resolvedPath = Resolve-AbsolutePath -Path $Path
    $runRoot = Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    if (-not [string]::Equals((Split-Path -Parent $resolvedPath), $runRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'RunRecord 路徑不屬於指定 line／dispatch。' }
    Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $resolvedPath
    $record = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $resolvedPath)
    if ($null -eq $record -or $record -isnot [pscustomobject]) { throw 'RunRecord 必須為 JSON object。' }
    if (-not (Test-DispatchRecoveryNeverStarted -Record $record)) { return $false }
    foreach ($pair in @(@('schema','ai-sessions.dispatch-run.v1'), @('line_slug',$LineSlug), @('dispatch_slug',$DispatchSlug))) {
        if ([string](Get-CleanupPropertyValue -Object $record -Names @($pair[0])) -cne [string]$pair[1]) { throw ('DispatchAdmissionOwnerUnverifiable：未啟動 RunRecord 的 ' + $pair[0] + ' 不符。') }
    }
    foreach ($pair in @(@('source_root',$SourceRoot), @('execution_root',$ExecutionRoot))) {
        $value = [string](Get-CleanupPropertyValue -Object $record -Names @($pair[0]))
        if ([string]::IsNullOrWhiteSpace($value) -or -not [string]::Equals((Resolve-AbsolutePath $value), (Resolve-AbsolutePath $pair[1]), [StringComparison]::OrdinalIgnoreCase)) { throw ('DispatchAdmissionOwnerUnverifiable：未啟動 RunRecord 的 ' + $pair[0] + ' 不符。') }
    }
    $runId = [string](Get-CleanupPropertyValue -Object $record -Names @('run_id'))
    $parsedRunId = [guid]::Empty
    $createdAt = [DateTimeOffset]::MinValue
    if (-not [guid]::TryParseExact($runId, 'D', [ref]$parsedRunId) -or [IO.Path]::GetFileName($resolvedPath) -cne ($runId + '.json') -or
        -not [DateTimeOffset]::TryParse([string](Get-CleanupPropertyValue -Object $record -Names @('created_at_utc')), [ref]$createdAt)) { throw 'DispatchAdmissionOwnerUnverifiable：未啟動 RunRecord 的 run_id 或建立時間不符。' }
    $pidPath = [string](Get-CleanupPropertyValue -Object $record -Names @('pid_record_path'))
    if (-not [string]::IsNullOrWhiteSpace($pidPath)) {
        if (-not (Test-PathWithinRoot -Path $pidPath -Root (Join-Path $SourceRoot '.local\ai-sessions\history'))) { throw 'CleanupRunRecordBoundary：未啟動紀錄的 PID path 越界。' }
        Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $pidPath
    }
    $eventStreamPath = [string](Get-CleanupPropertyValue -Object $record -Names @('event_stream_path'))
    if ([string]::IsNullOrWhiteSpace($eventStreamPath)) { return $false }
    $resolvedEventStreamPath = Resolve-AbsolutePath -Path $eventStreamPath
    $historyRoot = Join-Path $ExecutionRoot '.local\ai-sessions\history'
    if (-not (Test-PathWithinRoot -Path $resolvedEventStreamPath -Root $historyRoot)) { throw ('CleanupRunRecordBoundary：未啟動紀錄的 event stream 越界：' + $resolvedEventStreamPath) }
    Assert-DispatchOutputPathNoReparsePoint -Root $ExecutionRoot -Path $resolvedEventStreamPath
    return [IO.File]::Exists($resolvedEventStreamPath)
}

function Read-CleanupFailureReceiptBinding {
    [CmdletBinding()]
    param([string]$SourceRoot, [string]$DispatchRoot, [string]$LineSlug, [string]$DispatchSlug, [string]$FailureReceiptPath)

    $path = Resolve-AbsolutePath $FailureReceiptPath
    $sourceHistory = Join-Path (Join-Path $SourceRoot '.local\ai-sessions\history') $LineSlug
    $dispatchHistory = Join-Path (Join-Path $DispatchRoot '.local\ai-sessions\history') $LineSlug
    if (-not (Test-PathWithinRoot $path $sourceHistory) -and -not (Test-PathWithinRoot $path $dispatchHistory)) { throw ('CleanupFailureReceiptBoundary：' + $path) }
    Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $path
    $receipt = (Read-CleanupJsonDocument -Path $path -Name 'FailureReceipt').Document
    foreach ($pair in @(@('schema','ai-sessions.dispatch-failure-receipt.v1'), @('source_root',$SourceRoot), @('dispatch_root',$DispatchRoot), @('execution_root',$DispatchRoot), @('line_slug',$LineSlug), @('dispatch_slug',$DispatchSlug))) {
        if ([string](Get-CleanupPropertyValue -Object $receipt -Names @($pair[0])) -cne [string]$pair[1]) { throw ('CleanupIdentityMismatch：failure receipt 的 ' + $pair[0] + ' 不符。') }
    }
    return $receipt
}

function Test-CleanupUnstartedProof {
    [CmdletBinding()]
    param([string]$SourceRoot, [string]$DispatchRoot, [string]$LineSlug, [string]$DispatchSlug, [string]$RunRecordPath, [string]$FailureReceiptPath, [bool]$HasPreflight)

    if (-not [string]::IsNullOrWhiteSpace($RunRecordPath)) {
        $record = Read-DispatchUnstartedRecoveryRecord -Path $RunRecordPath -SourceRoot $SourceRoot -ExecutionRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        if ($null -eq $record) { return $false }

        $eventStreamPath = [string](Get-CleanupPropertyValue -Object $record -Names @('event_stream_path'))
        if (-not [string]::IsNullOrWhiteSpace($eventStreamPath)) {
            $resolvedEventStreamPath = Resolve-AbsolutePath -Path $eventStreamPath
            $historyRoot = Join-Path $DispatchRoot '.local\ai-sessions\history'
            if (-not (Test-PathWithinRoot -Path $resolvedEventStreamPath -Root $historyRoot)) { return $false }
            Assert-DispatchOutputPathNoReparsePoint -Root $DispatchRoot -Path $resolvedEventStreamPath
            if (Test-Path -LiteralPath $resolvedEventStreamPath) { return $false }
        }

        return $true
    }
    if (-not (Test-DispatchUnstartedRecoveryHistoryEmpty -ExecutionRoot $DispatchRoot -DispatchSlug $DispatchSlug)) { return $false }
    $runRoot = Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $runRoot
    if ([IO.Directory]::Exists($runRoot) -and @(Get-ChildItem -LiteralPath $runRoot -File -Filter '*.json').Count -gt 0) { return $false }
    if ([string]::IsNullOrWhiteSpace($FailureReceiptPath)) { return $HasPreflight }
    $receipt = Read-CleanupFailureReceiptBinding -SourceRoot $SourceRoot -DispatchRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -FailureReceiptPath $FailureReceiptPath
    $started = Get-CleanupPropertyValue -Object $receipt -Names @('process_started')
    return ($started -is [bool] -and -not $started)
}

function Read-CleanupDispatchRequestBinding {
    [CmdletBinding()]
    param([string]$SourceRoot, [string]$DispatchRoot, [string]$LineSlug, [string]$DispatchSlug, [string]$Path)

    $resolvedPath = Resolve-AbsolutePath -Path $Path
    $sessionRoot = Join-Path $SourceRoot '.local\ai-sessions'
    if (-not (Test-PathWithinRoot -Path $resolvedPath -Root $sessionRoot)) { throw ('CleanupDispatchRequestBoundary：' + $resolvedPath) }
    try { Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $resolvedPath }
    catch { throw ('CleanupDispatchRequestBoundary：' + $resolvedPath + '；' + $_.Exception.Message) }
    $result = [ordered]@{ Accepted = $false; Reason = $null; Path = $resolvedPath; Sha256 = $null; Length = $null }
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        $result.Reason = 'dispatch-request 不存在：' + $resolvedPath
        return [pscustomobject]$result
    }
    try { $request = (Read-CleanupJsonDocument -Path $resolvedPath -Name 'DispatchRequest').Document }
    catch {
        $result.Reason = 'JSON 無法解析'
        return [pscustomobject]$result
    }
    if ([string](Get-CleanupPropertyValue $request @('schema')) -cne 'ai-sessions.dispatch-request.v1') { $result.Reason = 'schema 不符'; return [pscustomobject]$result }
    if ([string](Get-CleanupPropertyValue $request @('operation')) -ine 'Dispatch') { $result.Reason = 'operation 不是 Dispatch'; return [pscustomobject]$result }
    foreach ($pair in @(@('line_slug', $LineSlug), @('dispatch_slug', $DispatchSlug), @('source_root', $SourceRoot), @('dispatch_root', $DispatchRoot))) {
        $actual = [string](Get-CleanupPropertyValue $request @($pair[0]))
        $matchesIdentity = $false
        if ($pair[0] -in @('source_root', 'dispatch_root')) {
            if (-not [string]::IsNullOrWhiteSpace($actual)) {
                try { $matchesIdentity = (Resolve-AbsolutePath -Path $actual) -ieq (Resolve-AbsolutePath -Path $pair[1]) } catch { $matchesIdentity = $false }
            }
        }
        else { $matchesIdentity = $actual -ceq [string]$pair[1] }
        if (-not $matchesIdentity) {
            $result.Reason = $pair[0] + ' 不符（預期 ' + $pair[1] + '，實際 ' + $actual + '）'
            return [pscustomobject]$result
        }
    }
    $result.Sha256 = Get-FileSha256 -Path $resolvedPath
    $result.Length = (Get-Item -LiteralPath $resolvedPath).Length
    $result.Accepted = $true
    return [pscustomobject]$result
}

function Test-CleanupNeverLaunchedProof {
    [CmdletBinding()]
    param([string]$SourceRoot, [string]$DispatchRoot, [string]$LineSlug, [string]$DispatchSlug, [string]$FailureReceiptPath, [string]$DispatchRequestPath, [Parameter(Mandatory)][object]$AdmissionLock)

    $rejections = New-Object System.Collections.Generic.List[object]
    $alternatives = New-Object System.Collections.Generic.List[object]
    $historyRoot = Join-Path $DispatchRoot '.local\ai-sessions\history'
    $historyEmpty = Test-DispatchUnstartedRecoveryHistoryEmpty -ExecutionRoot $DispatchRoot -DispatchSlug $DispatchSlug
    if (-not $historyEmpty) {
        $rejections.Add([ordered]@{ id = 'U1'; message = ('U1 未通過：dispatch worktree 的 history 含 Codex 事件流（codex-exec-*.jsonl）或 codex-thread-' + $DispatchSlug + '.txt，或無法完整掃描：' + $historyRoot + '。已有啟動痕跡，不能視為未啟動。') })
    }
    $runRoot = Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $runRoot
    $runDirectoryExists = [IO.Directory]::Exists($runRoot)
    $runCount = 0
    $runReadable = $true
    if ($runDirectoryExists) {
        try { $runCount = @(Get-ChildItem -LiteralPath $runRoot -File -Filter '*.json' -ErrorAction Stop).Count }
        catch { $runReadable = $false }
    }
    $runEmpty = $runReadable -and $runCount -eq 0
    if (-not $runEmpty) {
        $countDisplay = if ($runReadable) { [string]$runCount } else { '無法確認數量的' }
        $rejections.Add([ordered]@{ id = 'U2'; message = ('U2 未通過：來源 runs\' + $DispatchSlug + '\ 已有 ' + $countDisplay + ' 筆 RunRecord 或無法完整掃描（' + $runRoot + '）。有 RunRecord 時請在 Cleanup 提供 run_record_path，由既有未啟動 RunRecord 判定處理。') })
    }

    $receiptReason = '未提供 -FailureReceiptPath'
    $receiptAccepted = $false
    $receiptPath = $null
    $receiptHash = $null
    $receiptLength = $null
    $receiptStatus = $null
    $receiptStarted = $null
    $dispatcherProcess = $null
    $dispatcherState = $null
    $receiptBlocksRequest = $false
    if (-not [string]::IsNullOrWhiteSpace($FailureReceiptPath)) {
        $receiptPath = Resolve-AbsolutePath -Path $FailureReceiptPath
        $sourceHistory = Join-Path (Join-Path $SourceRoot '.local\ai-sessions\history') $LineSlug
        $dispatchHistory = Join-Path (Join-Path $DispatchRoot '.local\ai-sessions\history') $LineSlug
        if (-not (Test-PathWithinRoot $receiptPath $sourceHistory) -and -not (Test-PathWithinRoot $receiptPath $dispatchHistory)) { throw ('CleanupFailureReceiptBoundary：' + $receiptPath) }
        Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $receiptPath
        if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { $receiptReason = '收據檔不存在' }
        else {
            $receipt = $null
            try { $receipt = Read-CleanupFailureReceiptBinding -SourceRoot $SourceRoot -DispatchRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -FailureReceiptPath $receiptPath }
            catch {
                if ($_.Exception.Message -match '^CleanupIdentityMismatch') { $receiptReason = $_.Exception.Message }
                elseif ($_.Exception.Message -match '^CleanupFailureReceipt(Invalid|Missing)') { $receiptReason = $_.Exception.Message }
                else { throw }
            }
            if ($null -ne $receipt) {
                $receiptStarted = Get-CleanupPropertyValue $receipt @('process_started')
                $receiptStatus = [string](Get-CleanupPropertyValue $receipt @('status'))
                $dispatcherProcess = Get-CleanupPropertyValue $receipt @('dispatcher_process')
                if ($receiptStarted -isnot [bool] -or $receiptStarted) { $receiptReason = '收據 process_started 不是 false' }
                elseif ($receiptStatus -cnotin @('pending', 'failed')) { $receiptReason = '收據 status=' + $receiptStatus }
                elseif ($null -eq $dispatcherProcess -and $receiptStatus -ceq 'pending') { $receiptReason = 'pending 收據缺少 dispatcher_process' }
                else {
                    if ($null -eq $dispatcherProcess) { $dispatcherState = 'not-recorded' }
                    else { try { $dispatcherState = Get-DispatchAdmissionOwnerState -Entry $dispatcherProcess } catch { $dispatcherState = 'unknown' } }
                    if ($dispatcherState -in @('ended', 'pid-reused', 'not-recorded')) {
                        $receiptHash = Get-FileSha256 -Path $receiptPath
                        $receiptLength = (Get-Item -LiteralPath $receiptPath).Length
                        $receiptAccepted = $true
                    }
                    else {
                        $receiptReason = 'dispatcher 程序仍在執行或狀態不明（' + $dispatcherState + '）'
                        $receiptBlocksRequest = $true
                    }
                }
            }
        }
    }
    if (-not $receiptAccepted) { $alternatives.Add([ordered]@{ basis = 'failure-receipt'; reason = $receiptReason }) }
    if ([string]::IsNullOrWhiteSpace($DispatchRequestPath)) {
        $DispatchRequestPath = Join-Path (Join-Path (Join-Path $SourceRoot '.local\ai-sessions\history') $LineSlug) ('dispatch-request-' + $DispatchSlug + '.json')
    }
    $requestBinding = Read-CleanupDispatchRequestBinding -SourceRoot $SourceRoot -DispatchRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -Path $DispatchRequestPath
    if (-not $requestBinding.Accepted) { $alternatives.Add([ordered]@{ basis = 'dispatch-request'; reason = $requestBinding.Reason }) }
    $basis = if ($receiptAccepted) { 'failure-receipt' } elseif ($receiptBlocksRequest) { $null } elseif ($requestBinding.Accepted) { 'dispatch-request' } else { $null }
    if ($null -eq $basis) {
        $blockedNote = if ($receiptBlocksRequest) { '收據顯示 dispatcher 仍在執行或狀態不明，不改用 dispatch-request。' } else { '' }
        $rejections.Add([ordered]@{ id = 'U3'; message = ('U3 未通過：找不到可採用的派遣紀錄。failure receipt：' + $receiptReason + '；dispatch-request：' + $requestBinding.Reason + '（' + $requestBinding.Path + '）。' + $blockedNote + 'dispatch-request 預設讀取 history\<lineSlug>\dispatch-request-<dispatchSlug>.json，可用 dispatch_request_path 指定其他位置。') })
    }
    $ledgerCount = 0
    $matchingEntries = @()
    $ledgerHash = $null
    $ledgerPath = [string]$AdmissionLock.LedgerPath
    $ledgerReadable = $true
    try {
        $ledger = Read-DispatchAdmissionLedger -Lock $AdmissionLock
        $ledgerHash = $ledger.Sha256
        $ledgerEntries = @($ledger.Document.entries)
        $ledgerCount = $ledgerEntries.Count
        $matchingEntries = @($ledgerEntries | Where-Object { [string](Get-CleanupPropertyValue $_ @('dispatch_slug')) -ceq $DispatchSlug })
    }
    catch { $ledgerReadable = $false }
    $ledgerEmpty = $ledgerReadable -and $matchingEntries.Count -eq 0
    if (-not $ledgerEmpty) {
        $reason = if ($ledgerReadable) { 'admission ledger 已有 dispatchSlug 的 entry（state=' + [string](Get-CleanupPropertyValue $matchingEntries[0] @('state')) + '，' + $ledgerPath + '）。ledger 記錄表示 Start 已進入啟動登記，請改走既有 owner 驗證與 -TakeoverOwner 流程。' } else { 'admission ledger 無法驗證（DispatchAdmissionLedgerUnverifiable）。' }
        $rejections.Add([ordered]@{ id = 'U4'; message = 'U4 未通過：' + $reason })
    }
    $conditions = [ordered]@{
        U1 = [ordered]@{ passed = [bool]$historyEmpty; history_root = $historyRoot }
        U2 = [ordered]@{ passed = [bool]$runEmpty; run_directory = $runRoot; directory_exists = $runDirectoryExists; json_count = $runCount }
        U3 = [ordered]@{ passed = ($null -ne $basis); basis = $basis; path = if ($basis -eq 'failure-receipt') { $receiptPath } else { $requestBinding.Path }; sha256 = if ($basis -eq 'failure-receipt') { $receiptHash } else { $requestBinding.Sha256 }; length = if ($basis -eq 'failure-receipt') { $receiptLength } else { $requestBinding.Length }; receipt_status = $receiptStatus; receipt_process_started = $receiptStarted; dispatcher_process = $dispatcherProcess; dispatcher_state = $dispatcherState }
        U4 = [ordered]@{ passed = [bool]$ledgerEmpty; ledger_path = $ledgerPath; ledger_sha256 = $ledgerHash; ledger_entry_count = $ledgerCount; entries_for_dispatch_slug = $matchingEntries.Count }
    }
    return [pscustomobject]@{ Accepted = ($rejections.Count -eq 0); Basis = $basis; Conditions = $conditions; Rejections = @($rejections.ToArray()); RejectedAlternatives = @($alternatives.ToArray()); Fingerprint = Get-JsonSha256 -Value $conditions }
}

function Test-CleanupTakeoverTerminal {
    [CmdletBinding()]
    param([string]$SourceRoot, [string]$DispatchRoot, [string]$LineSlug, [string]$DispatchSlug, [string]$RunRecordPath, [object]$Ledger)

    try {
        $records = @(Get-DispatchRunRecordList -SourceRoot $SourceRoot -ExecutionRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug | Sort-Object run_id)
        if ($records.Count -eq 0) { throw '缺少 RunRecord。' }
        $runRoot = Get-DispatchRunDirectory -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        $expectedPath = Resolve-AbsolutePath $RunRecordPath
        if (@($records | Where-Object { [string]::Equals((Join-Path $runRoot ($_.run_id + '.json')), $expectedPath, [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) { throw '指定的 RunRecord 不在派遣 run 集合。' }
        $byId = @{}
        foreach ($record in $records) { $byId[$record.run_id] = $record }
        foreach ($record in $records) {
            $seen = @{}
            $node = $record
            while ($null -ne $node) {
                if ($seen.ContainsKey($node.run_id)) { throw 'RunRecord 續行鏈循環。' }
                $seen[$node.run_id] = $true
                $parent = [string]$node.attempt_parent_run_id
                if ([string]::IsNullOrWhiteSpace($parent)) { break }
                if (-not $byId.ContainsKey($parent)) { throw 'RunRecord 續行鏈缺少 parent。' }
                if ([DateTimeOffset]::Parse($byId[$parent].created_at_utc) -gt [DateTimeOffset]::Parse($node.created_at_utc)) { throw 'RunRecord 續行鏈時間矛盾。' }
                $node = $byId[$parent]
            }
        }
    }
    catch { throw ('CleanupTakeoverIdentityInvalid：' + $_.Exception.Message) }

    $proofs = New-Object System.Collections.Generic.List[object]
    $processProofs = New-Object System.Collections.Generic.List[object]
    $hashes = New-Object System.Collections.Generic.List[object]
    $originalOwners = New-Object System.Collections.Generic.List[object]
    foreach ($owner in @(Get-CleanupOriginalOwners -Ledger $Ledger -LineSlug $LineSlug -DispatchSlug $DispatchSlug)) { $originalOwners.Add($owner) }
    foreach ($record in $records) {
        $path = Join-Path $runRoot ($record.run_id + '.json')
        $hashes.Add([ordered]@{ path = $path; sha256 = Get-FileSha256 $path })
        $originalOwners.Add([ordered]@{ source = $path; caller_session_fingerprint = Get-CleanupPropertyValue $record @('caller_session_fingerprint'); owner_status = if ([string]::IsNullOrWhiteSpace([string](Get-CleanupPropertyValue $record @('caller_session_fingerprint')))) { 'unverifiable' } else { 'recorded' } })
        $classification = Get-DispatchRunRecordStartClassification -Record $record
        if ($classification.classification -eq 'unstarted-sandbox') {
            if (-not (Test-CleanupUnstartedProof -SourceRoot $SourceRoot -DispatchRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunRecordPath $path -HasPreflight $true)) { throw 'CleanupTakeoverRunNotTerminal：未啟動證明不成立。' }
            $proofs.Add([ordered]@{ run_id = $record.run_id; classification = 'unstarted-sandbox' })
            continue
        }
        if ($record.launch_state -cne 'started' -or $null -ne (Get-CleanupPropertyValue $record @('unknown_interruption'))) { throw 'CleanupTakeoverRunNotTerminal：RunRecord 未有可信終態。' }
        $events = Get-DispatchEventEvidence -EventPath $record.event_stream_path
        foreach ($line in $events.raw_lines) {
            try { $event = ConvertFrom-DispatchJson -Content $line; if ([string]::IsNullOrWhiteSpace([string](Get-CleanupPropertyValue $event @('type')))) { throw '缺少事件類型。' } }
            catch { throw 'CleanupTakeoverRunNotTerminal：事件流格式無法確認。' }
        }
        if ($events.last_event_type -cnotin @('turn.completed', 'turn.failed')) { throw 'CleanupTakeoverRunNotTerminal：事件流缺少最後 terminal event。' }
        $hashes.Add([ordered]@{ path = $record.event_stream_path; sha256 = $events.sha256 })
        $exitPath = [string]$record.process_exit_code_sidecar_path
        if (-not [string]::IsNullOrWhiteSpace($exitPath)) {
            try { $exit = Read-DispatchExitSidecar -Path $exitPath -ExecutionRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId $record.run_id }
            catch { throw ('CleanupTakeoverRunNotTerminal：' + $_.Exception.Message) }
            $hashes.Add([ordered]@{ path = $exitPath; sha256 = $exit.Sha256 })
            $exitCode = $exit.ProcessExitCode
        }
        else {
            $exitPath = [string]$record.inspect_result_path
            if ([string]::IsNullOrWhiteSpace($exitPath) -or -not [IO.File]::Exists($exitPath)) { throw 'CleanupTakeoverRunNotTerminal：缺少可信 sidecar 或 Inspect。' }
            Assert-DispatchOutputPathNoReparsePoint -Root $DispatchRoot -Path $exitPath
            $inspectHash = Get-FileSha256 $exitPath
            $inspect = (Read-CleanupJsonDocument -Path $exitPath -Name 'Inspect').Document
            $eventProof = Get-CleanupPropertyValue $inspect @('eventEvidence')
            if ([string](Get-CleanupPropertyValue $inspect @('runId')) -cne $record.run_id -or
                [string](Get-CleanupPropertyValue $inspect @('runRecordPath')) -ine $path -or
                [string](Get-CleanupPropertyValue $inspect @('eventStreamPath')) -ine $record.event_stream_path -or
                [string](Get-CleanupPropertyValue $eventProof @('sha256')) -ine $events.sha256 -or
                [string](Get-CleanupPropertyValue $inspect @('lastEventType')) -cne $events.last_event_type -or
                [string](Get-CleanupPropertyValue $inspect @('processExitCodeSource')) -cne 'sidecar' -or (Get-FileSha256 $exitPath) -ine $inspectHash) { throw 'CleanupTakeoverRunNotTerminal：Inspect identity/hash 或退出來源無法確認。' }
            $exitCode = ConvertTo-DispatchInt32Value -Value (Get-CleanupPropertyValue $inspect @('processExitCode')) -Field 'processExitCode'
            $hashes.Add([ordered]@{ path = $exitPath; sha256 = $inspectHash })
        }
        $eventLines = @((Read-DispatchUtf8Text -Path $record.event_stream_path) -split '\r?\n')
        $terminalLine = $eventLines.Count
        while ($terminalLine -gt 0 -and [string]::IsNullOrWhiteSpace($eventLines[$terminalLine - 1])) { $terminalLine-- }
        $proofs.Add([ordered]@{ run_id = $record.run_id; classification = 'started-terminal'; event_path = $record.event_stream_path; event_sha256 = $events.sha256; terminal_event = $events.last_event_type; terminal_event_line = $terminalLine; exit_path = $exitPath; exit_code = $exitCode })
        $pidPath = [string]$record.pid_record_path
        if (-not [IO.File]::Exists($pidPath)) { throw 'CleanupTakeoverProcessUnverifiable：缺少 PID 記錄。' }
        Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $pidPath
        $pidRecord = Get-KeyValueFile -Path $pidPath
        foreach ($pair in @(@('work-root',$SourceRoot), @('line-slug',$LineSlug), @('dispatch-slug',$DispatchSlug), @('identity-verified','true'))) {
            if ([string](Get-CleanupPropertyValue $pidRecord @($pair[0])) -ine [string]$pair[1]) { throw ('CleanupTakeoverProcessUnverifiable：PID identity 不符。' + $pair[0]) }
        }
        $pidValue = 0
        $pidTime = [DateTimeOffset]::MinValue
        if (-not [int]::TryParse([string](Get-CleanupPropertyValue $pidRecord @('root-pid')), [ref]$pidValue) -or $pidValue -le 0 -or
            [string]::IsNullOrWhiteSpace([string](Get-CleanupPropertyValue $pidRecord @('root-process-name'))) -or
            -not [DateTimeOffset]::TryParse([string](Get-CleanupPropertyValue $pidRecord @('root-started-at-utc')), [ref]$pidTime)) { throw 'CleanupTakeoverProcessUnverifiable：PID 三鍵缺漏。' }
        if ([string](Get-CleanupPropertyValue $pidRecord @('identity-status')) -cne 'confirmed' -or
            [string](Get-CleanupPropertyValue $pidRecord @('process-tree-scope')) -cnotin @('pid-and-descendants','process-group')) { throw 'CleanupTakeoverProcessUnverifiable：PID 程序樹範圍無法確認。' }
        foreach ($owner in @($Ledger.Document.entries | Where-Object { [string]$_.line_slug -ceq $LineSlug -and [string]$_.dispatch_slug -ceq $DispatchSlug -and [string](Get-CleanupPropertyValue $_ @('pid_record_path')) -ieq $pidPath })) {
            $ownerTime = [DateTimeOffset]::MinValue
            $ownerTimeValue = $owner.process_start_time_utc
            $ownerTimeKnown = $true
            if ($ownerTimeValue -is [DateTimeOffset]) { $ownerTime = $ownerTimeValue }
            elseif ($ownerTimeValue -is [DateTime]) { $ownerTime = [DateTimeOffset]$ownerTimeValue.ToUniversalTime() }
            else {
                $dateStyles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
                $ownerTimeKnown = [DateTimeOffset]::TryParse([string]$ownerTimeValue, [Globalization.CultureInfo]::InvariantCulture, $dateStyles, [ref]$ownerTime)
            }
            if ([string]$owner.process_id -cne [string]$pidValue -or
                [string]$owner.process_name -ine [string](Get-CleanupPropertyValue $pidRecord @('root-process-name')) -or
                -not $ownerTimeKnown -or
                [Math]::Abs(($ownerTime - $pidTime).TotalSeconds) -gt 1) { throw 'CleanupTakeoverProcessUnverifiable：ledger 與 PID 三鍵不符。' }
        }
        $hashes.Add([ordered]@{ path = $pidPath; sha256 = Get-FileSha256 $pidPath })
        $processProofs.Add([ordered]@{ run_id = $record.run_id; pid_record_path = $pidPath; root_pid = $pidValue; root_process_name = Get-CleanupPropertyValue $pidRecord @('root-process-name'); root_started_at_utc = $pidTime.ToString('o'); status = 'ended-or-pid-reused' })
    }
    foreach ($owner in @($Ledger.Document.entries | Where-Object { [string]$_.line_slug -ceq $LineSlug -and [string]$_.dispatch_slug -ceq $DispatchSlug })) {
        Assert-CleanupStopped -SourceRoot $SourceRoot -DispatchSlug $DispatchSlug -LineSlug $LineSlug -Owner $owner
    }
    Assert-CleanupStopped -SourceRoot $SourceRoot -DispatchSlug $DispatchSlug -LineSlug $LineSlug -Owner $null
    return [ordered]@{ terminal_evidence = @($proofs.ToArray()); process_evidence = @($processProofs.ToArray()); evidence_hashes = @($hashes.ToArray()); original_owners = @($originalOwners.ToArray()) }
}

function Expand-CleanupTakeoverInventory {
    [CmdletBinding()]
    param([object]$Inventory, [object[]]$RunRecords, [string]$SourceRoot, [string]$DispatchRoot, [string]$LineSlug, [string]$DispatchSlug)

    $items = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Inventory.items)) { $items.Add($item); $null = $seen.Add($item.source_path) }
    foreach ($run in $RunRecords) {
        $record = Read-DispatchRunRecord -Path $run.path -SourceRoot $SourceRoot -ExecutionRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        foreach ($path in @(Get-CleanupRecordReferencedPaths -Record $record)) {
            if ((Test-PathWithinRoot -Path $path -Root $DispatchRoot) -and [IO.File]::Exists($path)) {
                Add-CleanupInventoryPath -Inventory $items -Seen $seen -Path $path -DispatchRoot $DispatchRoot -SourceName 'TakeoverRunRecord'
            }
        }
    }
    $Inventory.items = @($items.ToArray())
    return $Inventory
}

function Write-CleanupUnstartedAudit {
    [CmdletBinding()]
    param([string]$Path, [System.Collections.IDictionary]$Audit, [string]$SourceRoot, [string]$DispatchRoot, [switch]$RequireAbsent)

    $WhatIfPreference = $false

    try {
        $null = Write-DispatchAtomicJsonDocument -Path $Path -Document $Audit -SourceRoot $SourceRoot -ExecutionRoot $DispatchRoot -TargetPath @() -RequireAbsent:$RequireAbsent
        $saved = (Read-CleanupJsonDocument -Path $Path -Name 'UnstartedAudit').Document
        if (($saved | ConvertTo-Json -Depth 60 -Compress) -cne ($Audit | ConvertTo-Json -Depth 60 -Compress)) { throw '未啟動稽核紀錄回讀不一致。' }
        return Get-FileSha256 $Path
    }
    catch { throw ('CleanupUnstartedAuditWriteFailed：' + $_.Exception.Message) }
}

function Write-CleanupTakeoverAudit {
    [CmdletBinding()]
    param([string]$Path, [System.Collections.IDictionary]$Audit, [string]$SourceRoot, [string]$DispatchRoot)

    try {
        $null = Write-DispatchAtomicJsonDocument -Path $Path -Document $Audit -SourceRoot $SourceRoot -ExecutionRoot $DispatchRoot -TargetPath @()
        $saved = (Read-CleanupJsonDocument -Path $Path -Name 'TakeoverAudit').Document
        if (($saved | ConvertTo-Json -Depth 60 -Compress) -cne ($Audit | ConvertTo-Json -Depth 60 -Compress)) { throw '接手紀錄回讀不一致。' }
        return Get-FileSha256 $Path
    }
    catch { throw ('CleanupTakeoverAuditWriteFailed：' + $_.Exception.Message) }
}

function Invoke-Cleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $result = New-CleanupOperationResult -SourceRoot ([string]$SourceRoot) -DispatchRoot ([string]$DispatchRoot) -LineSlug ([string]$LineSlug) -DispatchSlug ([string]$DispatchSlug)
    $admissionLock = $null
    $admissionLedger = $null
    $admissionOwner = $null
    $takeoverAudit = $null
    $takeoverAuditPath = $null
    $unstartedAudit = $null
    $unstartedAuditPath = $null
    try {
        if ([string]::IsNullOrWhiteSpace($SourceRoot) -or [string]::IsNullOrWhiteSpace($DispatchRoot) -or [string]::IsNullOrWhiteSpace($LineSlug) -or [string]::IsNullOrWhiteSpace($DispatchSlug)) {
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupRequiredParameterMissing' -Message 'Cleanup 必須提供 SourceRoot、DispatchRoot、LineSlug 與 DispatchSlug。'
        }
        if ($LineSlug -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or $DispatchSlug -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupIdentityInvalid' -Message 'Cleanup 的 line／dispatch slug 格式不符。'
        }
        $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
        $dispatchRootPath = Resolve-AbsolutePath -Path $DispatchRoot
        $result.source_root = $sourceRootPath
        $result.dispatch_root = $dispatchRootPath
        if (-not (Test-Path -LiteralPath $sourceRootPath -PathType Container)) {
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupSourceRootMissing' -Message ('sourceRoot 不存在或不是目錄：' + $sourceRootPath)
        }
        $expectedDispatchRoot = Resolve-AbsolutePath -Path (Join-Path $sourceRootPath (Join-Path '.local\ai-sessions\worktrees' $DispatchSlug))
        if (-not [string]::Equals($dispatchRootPath, $expectedDispatchRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $mismatch = New-CleanupIdentityMismatch -Field 'dispatch_root' -Expected $expectedDispatchRoot -Received $dispatchRootPath -Source 'Cleanup CLI'
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupDispatchRootBoundary' -Message ('CleanupPreflightRejected：dispatchRoot 不符合 exact worktree boundary。') -Detail $mismatch
        }
        if (-not (Test-Path -LiteralPath $dispatchRootPath -PathType Container)) {
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupDispatchRootMissing' -Message ('dispatchRoot 不存在：' + $dispatchRootPath)
        }
        Assert-DispatchOutputPathNoReparsePoint -Root $sourceRootPath -Path $dispatchRootPath
        $removalReceiptPath = Join-Path (Join-Path (Join-Path $sourceRootPath '.local\ai-sessions\history') $LineSlug) ('cleanup-result-' + $DispatchSlug + '.json')
        $worktreeList = Invoke-GitCommand -WorkingDirectory $sourceRootPath -Arguments @('worktree', 'list', '--porcelain') -AllowFailure
        if ($worktreeList.ExitCode -ne 0) {
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupGitRegistrationUnavailable' -Message ('無法取得 Git worktree registration：' + $worktreeList.StdErr)
        }
        $registered = $false
        foreach ($line in ([string]$worktreeList.StdOut -split '\r?\n')) {
            if (-not $line.StartsWith('worktree ', [StringComparison]::Ordinal)) { continue }
            $registeredPath = $line.Substring('worktree '.Length).Trim()
            if ([string]::Equals((Resolve-AbsolutePath $registeredPath), $dispatchRootPath, [StringComparison]::OrdinalIgnoreCase)) {
                $registered = $true
                break
            }
        }
        $validRemovalReceipt = Test-CleanupRemovalReceipt -Path $removalReceiptPath -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        $residualRecovery = -not $registered -and $validRemovalReceipt
        $hasRemovalRetryProof = $false
        $alreadyPreservedFiles = @()
        if ($validRemovalReceipt) {
            $priorReceipt = (Read-CleanupJsonDocument -Path $removalReceiptPath -Name 'RemovalResult').Document
            if ([string](Get-CleanupPropertyValue -Object $priorReceipt -Names @('failure_code')) -ceq 'CleanupWorktreeRemovalFailed') {
                $hasRemovalRetryProof = $true
                $alreadyPreservedFiles = @(Get-CleanupPropertyValue -Object $priorReceipt -Names @('files'))
            }
        }
        if (-not $registered -and -not $residualRecovery) {
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupWorktreeNotRegistered' -Message ('dispatchRoot 未在 Git worktree registration 中：' + $dispatchRootPath)
        }

        $hasPreflight = -not [string]::IsNullOrWhiteSpace($PreflightResultPath) -and [IO.File]::Exists((Resolve-AbsolutePath $PreflightResultPath))
        if ($hasPreflight) {
            $preflightPathValue = Resolve-AbsolutePath $PreflightResultPath
            if (-not (Test-PathWithinRoot $preflightPathValue $sourceRootPath)) { throw ('CleanupPreflightBoundary：' + $preflightPathValue) }
            Assert-DispatchOutputPathNoReparsePoint -Root $sourceRootPath -Path $preflightPathValue
            $preflight = Read-CleanupJsonDocument -Path $PreflightResultPath -Name 'Preflight'
            foreach ($entry in @(
                    [pscustomobject]@{ field = 'source_root'; expected = $sourceRootPath; received = [string](Get-CleanupPropertyValue -Object $preflight.Document -Names @('sourceRoot', 'source_root')) },
                    [pscustomobject]@{ field = 'dispatch_root'; expected = $dispatchRootPath; received = [string](Get-CleanupPropertyValue -Object $preflight.Document -Names @('dispatchRoot', 'dispatch_root')) },
                    [pscustomobject]@{ field = 'line_slug'; expected = $LineSlug; received = [string](Get-CleanupPropertyValue -Object $preflight.Document -Names @('lineSlug', 'line_slug')) },
                    [pscustomobject]@{ field = 'dispatch_slug'; expected = $DispatchSlug; received = [string](Get-CleanupPropertyValue -Object $preflight.Document -Names @('dispatchSlug', 'dispatch_slug')) }
                )) {
                $received = $entry.received
                if ($entry.field -in @('source_root', 'dispatch_root') -and -not [string]::IsNullOrWhiteSpace([string]$received)) { try { $received = Resolve-AbsolutePath -Path $received } catch { } }
                if (-not [string]::Equals([string]$entry.expected, [string]$received, [StringComparison]::OrdinalIgnoreCase)) {
                    $mismatch = New-CleanupIdentityMismatch -Field ('preflight.' + $entry.field) -Expected $entry.expected -Received $received -Source $preflight.Path
                    Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupIdentityMismatch' -Message 'CleanupPreflightRejected：Preflight identity 不一致。' -Detail $mismatch
                }
            }
        }

        $failureReceiptValue = [string](Get-DispatchScriptVariableValue -Name 'FailureReceiptPath')
        $hasRunRecord = -not [string]::IsNullOrWhiteSpace([string]$RunRecordPath)
        $neverLaunched = $null
        if (-not $hasRemovalRetryProof -and -not $hasPreflight -and -not $hasRunRecord -and -not $residualRecovery) {
            if ($null -eq $admissionLock) { $admissionLock = Open-DispatchAdmissionLock -SourceRoot $sourceRootPath }
            $neverLaunched = Test-CleanupNeverLaunchedProof -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -FailureReceiptPath $failureReceiptValue -DispatchRequestPath ([string](Get-DispatchScriptVariableValue -Name 'DispatchRequestPath')) -AdmissionLock $admissionLock
        }
        $preflightFailure = New-CleanupPreflightRequiredFailure -PreflightPath ([string]$PreflightResultPath) -RunPath ([string]$RunRecordPath) -NeverLaunchedProof $neverLaunched
        $unstarted = if ($hasRemovalRetryProof) { $false } elseif ($null -ne $neverLaunched -and $neverLaunched.Accepted) { $true } else { Test-CleanupUnstartedProof -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunRecordPath ([string]$RunRecordPath) -FailureReceiptPath $failureReceiptValue -HasPreflight $hasPreflight }
        if (-not $hasRemovalRetryProof -and -not $hasPreflight -and $hasRunRecord -and (Test-CleanupUnstartedRunRecordEventStreamPresent -Path ([string]$RunRecordPath) -SourceRoot $sourceRootPath -ExecutionRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug)) {
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupPreflightResultRequired' -Message $preflightFailure.Message -Detail $preflightFailure.Detail
        }
        if (-not $hasRemovalRetryProof) {
            if (-not $hasPreflight -and -not $unstarted -and -not $residualRecovery) {
                Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupPreflightResultRequired' -Message $preflightFailure.Message -Detail $preflightFailure.Detail
            }

            $preflightOnlyMissingProof = -not $hasRunRecord -and -not ($null -ne $neverLaunched -and $neverLaunched.Accepted) -and (-not $hasPreflight -or -not $unstarted)
            if (-not $residualRecovery -and $preflightOnlyMissingProof) {
                Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupPreflightResultRequired' -Message $preflightFailure.Message -Detail $preflightFailure.Detail
            }
        }

        if ($null -ne $script:CallerSessionIdentity) {
            if ($null -eq $admissionLock) { $admissionLock = Open-DispatchAdmissionLock -SourceRoot $sourceRootPath }
            $admissionLedger = Read-DispatchAdmissionLedger -Lock $admissionLock
            $knownOwners = @($admissionLedger.Document.entries | Where-Object { [string]$_.dispatch_slug -ceq $DispatchSlug })
            if ($knownOwners.Count -gt 0 -or (-not $unstarted -and -not $residualRecovery)) {
                $proof = $null
                $terminalProof = if ([bool](Get-DispatchScriptVariableValue -Name 'TakeoverOwner')) { $null } else {
                    { param($code) Test-CleanupTakeoverTerminal -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunRecordPath $RunRecordPath -Ledger $admissionLedger }
                }
                try {
                    $admissionOwner = Assert-DispatchRecoveryOwner -Lock $admissionLock -Ledger $admissionLedger -CallerIdentity $script:CallerSessionIdentity -SourceRoot $sourceRootPath -ExecutionRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunRecordPath $RunRecordPath -TerminalTakeoverProof $terminalProof
                    $automaticTakeover = $null -ne $admissionOwner -and $null -ne $admissionOwner.PSObject.Properties['OwnerTakeover']
                    if ($automaticTakeover) { $proof = $admissionOwner.OwnerTakeover.proof; $ownerCode = $admissionOwner.OwnerTakeover.trigger_error_code }
                }
                catch {
                    $ownerCode = [string]$_.Exception.Data['errorCode']
                    if (-not [bool](Get-DispatchScriptVariableValue -Name 'TakeoverOwner') -or $ownerCode -notin @('DispatchAdmissionOwnerMismatch', 'DispatchAdmissionOwnerUnverifiable')) { throw }
                    $proof = Test-CleanupTakeoverTerminal -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunRecordPath $RunRecordPath -Ledger $admissionLedger
                    $automaticTakeover = $false
                }
                if ($null -ne $proof) {
                    $attemptId = [guid]::NewGuid().ToString('D')
                    $takeoverAuditPath = Join-Path (Split-Path -Parent $removalReceiptPath) ('cleanup-takeover-' + $DispatchSlug + '-' + $attemptId + '.json')
                    $takeoverAudit = [ordered]@{
                        schema = 'ai-sessions.cleanup-takeover.v1'; attempt_id = $attemptId; line_slug = $LineSlug; dispatch_slug = $DispatchSlug
                        source_root = $sourceRootPath; execution_root = $dispatchRootPath
                        run_record_paths = @($proof.evidence_hashes | Where-Object { (Split-Path -Parent $_.path) -ieq (Get-DispatchRunDirectory -SourceRoot $sourceRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug) })
                        new_owner_fingerprint = $script:CallerSessionIdentity.Fingerprint; new_owner_source = $script:CallerSessionIdentity.Source
                        original_owners = $proof.original_owners; trigger_error_code = $ownerCode; explicit_takeover = -not $automaticTakeover; automatic_takeover = $automaticTakeover
                        requested_at_utc = [DateTime]::UtcNow.ToString('o'); preserved_at_utc = $null; completed_at_utc = $null
                        terminal_evidence = $proof.terminal_evidence; process_evidence = $proof.process_evidence; evidence_hashes = $proof.evidence_hashes
                        preserved_files = @(); status = 'validated'; failure_code = $null
                    }
                    $result.owner_takeover.used = $true
                    $result.owner_takeover.audit_path = $takeoverAuditPath
                    $result.owner_takeover.audit_sha256 = Write-CleanupTakeoverAudit -Path $takeoverAuditPath -Audit $takeoverAudit -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath
                }
            }
        }
        Assert-CleanupStopped -SourceRoot $sourceRootPath -DispatchSlug $DispatchSlug -LineSlug $LineSlug -Owner $admissionOwner

        if ($null -ne $neverLaunched -and $neverLaunched.Accepted) {
            $attemptId = [guid]::NewGuid().ToString('D')
            $unstartedAuditPath = Join-Path (Split-Path -Parent $removalReceiptPath) ('cleanup-unstarted-' + $DispatchSlug + '-' + $attemptId + '.json')
            $unstartedAudit = [ordered]@{
                schema = 'ai-sessions.cleanup-unstarted-proof.v1'; attempt_id = $attemptId; line_slug = $LineSlug; dispatch_slug = $DispatchSlug
                source_root = $sourceRootPath; dispatch_root = $dispatchRootPath; basis = $neverLaunched.Basis
                caller_session_fingerprint = if ($null -eq $script:CallerSessionIdentity) { $null } else { [string]$script:CallerSessionIdentity.Fingerprint }
                requested_at_utc = [DateTime]::UtcNow.ToString('o'); completed_at_utc = $null; status = 'validated'; failure_code = $null
                conditions = $neverLaunched.Conditions; rejected_alternatives = @($neverLaunched.RejectedAlternatives); fingerprint = $neverLaunched.Fingerprint
            }
            $auditHash = Write-CleanupUnstartedAudit -Path $unstartedAuditPath -Audit $unstartedAudit -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -RequireAbsent
            $result.unstarted_proof = [ordered]@{ used = $true; basis = $neverLaunched.Basis; audit_path = $unstartedAuditPath; audit_sha256 = $auditHash }
        }

        if ($WhatIfPreference -and $null -ne $neverLaunched -and $neverLaunched.Accepted) {
            $null = $PSCmdlet.ShouldProcess($dispatchRootPath, '移除 exact dispatch worktree')
            Throw-CleanupOperationFailure -Result $result -Status 'removal-failed' -FailureCode 'CleanupWhatIf' -Message 'Cleanup 因 WhatIf 未執行 worktree 移除。'
        }

        try {
            $inventory = Get-CleanupInventory -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunRecordPath $RunRecordPath -EvidencePath $EvidencePath -ReportPath @(Get-DispatchScriptVariableValue -Name 'ReportPath') -AlreadyPreservedFiles $alreadyPreservedFiles
            if ($null -ne $takeoverAudit) { $inventory = Expand-CleanupTakeoverInventory -Inventory $inventory -RunRecords $takeoverAudit.run_record_paths -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug }
        }
        catch {
            if ([string]$_.Exception.Data['errorCode'] -eq 'CleanupReportUnpreserved') {
                Throw-CleanupOperationFailure -Result $result -Status 'preservation-failed' -FailureCode 'CleanupReportUnpreserved' -Message $_.Exception.Message -Detail @($_.Exception.Data['unpreservedPaths'])
            }
            throw
        }
        $result.inventory = [ordered]@{
            report_root = $inventory.report_root
            run_record_path = $inventory.run_record_path
            referenced_paths = @($inventory.referenced_paths)
            source_count = @($inventory.items).Count
        }
        $result.source_files = @($inventory.items | ForEach-Object { $_.source_path })
        $result.destination_files = @($inventory.items | ForEach-Object { Join-Path $sourceRootPath ($_.relative_path -replace '/', '\') })
        $preserved = New-Object System.Collections.Generic.List[object]
        foreach ($item in @($inventory.items)) {
            try {
                $preserved.Add((Preserve-CleanupFile -Item $item -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -DispatchSlug $DispatchSlug))
            }
            catch {
                $code = if ($_.Exception.Message -match '^([A-Za-z][A-Za-z0-9]+)：') { $Matches[1] } else { 'CleanupPreservationFailed' }
                Throw-CleanupOperationFailure -Result $result -Status 'preservation-failed' -FailureCode $code -Message $_.Exception.Message -Detail ([ordered]@{ field = 'file'; expected = 'preserved'; received = $item.source_path; source = $item.source_path })
            }
        }
        $result.files = @($preserved.ToArray())
        if ($null -ne $unstartedAudit) {
            $unstartedAudit.status = 'preserved'
            $result.unstarted_proof.audit_sha256 = Write-CleanupUnstartedAudit -Path $unstartedAuditPath -Audit $unstartedAudit -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath
        }
        if ($null -ne $takeoverAudit) {
            $takeoverAudit.preserved_files = $result.files
            $takeoverAudit.preserved_at_utc = [DateTime]::UtcNow.ToString('o')
            $takeoverAudit.status = 'preserved'
            $result.owner_takeover.audit_sha256 = Write-CleanupTakeoverAudit -Path $takeoverAuditPath -Audit $takeoverAudit -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath
        }
        if (-not $PSCmdlet.ShouldProcess($dispatchRootPath, '移除 exact dispatch worktree')) {
            Throw-CleanupOperationFailure -Result $result -Status 'removal-failed' -FailureCode 'CleanupWhatIf' -Message 'Cleanup 因 WhatIf 未執行 worktree 移除。'
        }
        $reportsRoot = Split-Path -Parent ([string]$inventory.report_root)
        $beforeRemovalHook = Get-DispatchScriptVariableValue -Name 'CleanupBeforeRemovalHook'
        if ($null -ne $beforeRemovalHook) { & $beforeRemovalHook $reportsRoot }
        try {
            $unpreservedReports = @(Get-CleanupUnpreservedReportFiles -DispatchRoot $dispatchRootPath -ReportRoot $reportsRoot -PreservedItems @($inventory.items))
        }
        catch {
            Throw-CleanupOperationFailure -Result $result -Status 'preservation-failed' -FailureCode 'CleanupReportUnpreserved' -Message ('CleanupReportUnpreserved：移除前重新盤點 report 根目錄失敗，保留 worktree。' + $_.Exception.Message) -Detail $_.Exception.Message
        }
        if ($unpreservedReports.Count -gt 0) {
            Throw-CleanupOperationFailure -Result $result -Status 'preservation-failed' -FailureCode 'CleanupReportUnpreserved' -Message ('CleanupReportUnpreserved：盤點後新增未列入保存清單的檔案，保留 worktree：' + ($unpreservedReports -join '; ')) -Detail @($unpreservedReports)
        }
        if ($null -ne $unstartedAudit) {
            $proofRecheck = Test-CleanupNeverLaunchedProof -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -FailureReceiptPath $failureReceiptValue -DispatchRequestPath ([string](Get-DispatchScriptVariableValue -Name 'DispatchRequestPath')) -AdmissionLock $admissionLock
            if (-not $proofRecheck.Accepted -or $proofRecheck.Fingerprint -cne $neverLaunched.Fingerprint) {
                Throw-CleanupOperationFailure -Result $result -Status 'removal-failed' -FailureCode 'CleanupUnstartedProofDrift' -Message 'CleanupUnstartedProofDrift：移除前未啟動證明變動，保留 worktree。'
            }
        }
        if ($null -ne $takeoverAudit) {
            $recheck = Test-CleanupTakeoverTerminal -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunRecordPath $RunRecordPath -Ledger $admissionLedger
            if (($recheck.evidence_hashes | ConvertTo-Json -Depth 30 -Compress) -cne ($takeoverAudit.evidence_hashes | ConvertTo-Json -Depth 30 -Compress)) { throw 'CleanupTakeoverIdentityInvalid：移除前 run 集合或終態證據漂移。' }
            $reInventory = Get-CleanupInventory -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunRecordPath $RunRecordPath -EvidencePath $EvidencePath -ReportPath @(Get-DispatchScriptVariableValue -Name 'ReportPath') -AlreadyPreservedFiles $alreadyPreservedFiles
            $reInventory = Expand-CleanupTakeoverInventory -Inventory $reInventory -RunRecords $takeoverAudit.run_record_paths -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug
            if ((@($reInventory.items | ForEach-Object { $_.source_path } | Sort-Object) -join "`n") -cne (@($inventory.items | ForEach-Object { $_.source_path } | Sort-Object) -join "`n")) { throw 'CleanupPreservationFailed：移除前保存清單漂移。' }
            foreach ($file in $result.files) {
                if ((Get-FileSha256 $file.source_path) -ine $file.source_sha256 -or (Get-FileSha256 $file.destination_path) -ine $file.destination_sha256) { throw 'CleanupPreservationFailed：移除前檔案雜湊漂移。' }
            }
            if ((Get-FileSha256 $takeoverAuditPath) -ine $result.owner_takeover.audit_sha256) { throw 'CleanupTakeoverAuditWriteFailed：移除前稽核檔漂移。' }
        }
        $result.status = 'removal-failed'
        $removalFingerprint = if ($null -eq $script:CallerSessionIdentity) { $null } else { [string]$script:CallerSessionIdentity.Fingerprint }
        $result.removal = [ordered]@{ registered_before = $true; process_ended_verified = $true; residual_recovery = $residualRecovery; caller_session_fingerprint = $removalFingerprint }
        $null = Write-DispatchAtomicJsonDocument -Path $removalReceiptPath -Document $result -SourceRoot $sourceRootPath -ExecutionRoot $dispatchRootPath -TargetPath @()
        try { Remove-CleanupWorktreeContents -Root $dispatchRootPath -Confirm:$false }
        catch {
            $result.failure_code = 'CleanupWorktreeRemovalFailed'
            $result.error = $_.Exception.Message
            $result.removal.error = $_.Exception.Message
            $null = Write-DispatchAtomicJsonDocument -Path $removalReceiptPath -Document $result -SourceRoot $sourceRootPath -ExecutionRoot $dispatchRootPath -TargetPath @()
            return $result
        }
        if ($registered) {
            $removeResult = Invoke-GitCommand -WorkingDirectory $sourceRootPath -Arguments @('worktree', 'remove', '--force', '--', $dispatchRootPath) -AllowFailure
        }
        else {
            try {
                $gitMarker = Join-Path $dispatchRootPath '.git'
                if ([IO.File]::Exists($gitMarker)) { [IO.File]::Delete($gitMarker) }
                [IO.Directory]::Delete($dispatchRootPath, $false)
                $removeResult = [pscustomobject]@{ ExitCode = 0; StdErr = '' }
            }
            catch { $removeResult = [pscustomobject]@{ ExitCode = 1; StdErr = $_.Exception.Message } }
        }
        if ($removeResult.ExitCode -ne 0) {
            $result.removal = [ordered]@{ command = 'git worktree remove --force -- ' + $dispatchRootPath; exit_code = $removeResult.ExitCode; stderr = $removeResult.StdErr; registered_before = $true; process_ended_verified = $true; caller_session_fingerprint = $removalFingerprint }
            $result.status = 'removal-failed'
            $result.failure_code = 'CleanupWorktreeRemovalFailed'
            $result.error = 'CleanupWorktreeRemovalFailed：' + $removeResult.StdErr
            $null = Write-DispatchAtomicJsonDocument -Path $removalReceiptPath -Document $result -SourceRoot $sourceRootPath -ExecutionRoot $dispatchRootPath -TargetPath @()
            return $result
        }
        $afterList = Invoke-GitCommand -WorkingDirectory $sourceRootPath -Arguments @('worktree', 'list', '--porcelain') -AllowFailure
        $stillRegistered = $false
        if ($afterList.ExitCode -eq 0) {
            foreach ($line in ([string]$afterList.StdOut -split '\r?\n')) {
                if (-not $line.StartsWith('worktree ', [StringComparison]::Ordinal)) { continue }
                if ([string]::Equals((Resolve-AbsolutePath $line.Substring('worktree '.Length).Trim()), $dispatchRootPath, [StringComparison]::OrdinalIgnoreCase)) { $stillRegistered = $true; break }
            }
        }
        if ($afterList.ExitCode -ne 0 -or $stillRegistered -or (Test-Path -LiteralPath $dispatchRootPath)) {
            $result.removal = [ordered]@{ exit_code = $afterList.ExitCode; registered_after = $stillRegistered; path_exists_after = Test-Path -LiteralPath $dispatchRootPath; stderr = $afterList.StdErr; registered_before = $true; process_ended_verified = $true; caller_session_fingerprint = $removalFingerprint }
            $result.status = 'removal-failed'
            $result.failure_code = 'CleanupRemovalVerificationFailed'
            $result.error = 'CleanupRemovalVerificationFailed：worktree 移除後回查未通過。'
            $null = Write-DispatchAtomicJsonDocument -Path $removalReceiptPath -Document $result -SourceRoot $sourceRootPath -ExecutionRoot $sourceRootPath -TargetPath @()
            return $result
        }
        $result.removal = [ordered]@{ exit_code = 0; registered_after = $false; path_exists_after = $false }
        if ($null -ne $admissionOwner) {
            $ledgerOwner = @($admissionLedger.Document.entries | Where-Object { [string]$_.line_slug -ceq $LineSlug -and [string]$_.dispatch_slug -ceq $DispatchSlug })[-1]
            $ledgerOwner.state = 'cleaned'
            $ledgerOwner | Add-Member -MemberType NoteProperty -Name 'cleaned_at_utc' -Value ([DateTime]::UtcNow.ToString('o')) -Force
            $null = Write-DispatchAdmissionLedger -Lock $admissionLock -Ledger $admissionLedger
        }
        $result.worktree_removed = $true
        $result.status = 'completed'
        $result.failure_code = $null
        if ($null -ne $unstartedAudit) {
            $unstartedAudit.status = 'completed'
            $unstartedAudit.completed_at_utc = [DateTime]::UtcNow.ToString('o')
            try { $result.unstarted_proof.audit_sha256 = Write-CleanupUnstartedAudit -Path $unstartedAuditPath -Audit $unstartedAudit -SourceRoot $sourceRootPath -DispatchRoot $sourceRootPath }
            catch { $result.status = 'removal-failed'; $result.failure_code = 'CleanupUnstartedAuditWriteFailed'; $result.error = $_.Exception.Message }
        }
        if ($null -ne $takeoverAudit) {
            $takeoverAudit.status = 'completed'
            $takeoverAudit.completed_at_utc = [DateTime]::UtcNow.ToString('o')
            try { $result.owner_takeover.audit_sha256 = Write-CleanupTakeoverAudit -Path $takeoverAuditPath -Audit $takeoverAudit -SourceRoot $sourceRootPath -DispatchRoot $sourceRootPath }
            catch {
                $result.status = 'removal-failed'
                $result.failure_code = 'CleanupTakeoverAuditFinalizeFailed'
                $result.error = $_.Exception.Message
            }
        }
        $null = Write-DispatchAtomicJsonDocument -Path $removalReceiptPath -Document $result -SourceRoot $sourceRootPath -ExecutionRoot $sourceRootPath -TargetPath @()
        return $result
    }
    catch {
        if ($null -ne $unstartedAudit -and -not $result.worktree_removed) {
            $unstartedAudit.status = 'failed'
            $unstartedAudit.failure_code = if ($null -ne $_.Exception.Data['errorCode']) { [string]$_.Exception.Data['errorCode'] } elseif ($_.Exception.Message -match '^([A-Za-z][A-Za-z0-9]+)：') { $Matches[1] } else { 'CleanupPreflightFailed' }
            try { $result.unstarted_proof.audit_sha256 = Write-CleanupUnstartedAudit -Path $unstartedAuditPath -Audit $unstartedAudit -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath } catch { }
        }
        if ($null -ne $takeoverAudit -and -not $result.worktree_removed) {
            $takeoverAudit.status = 'failed'
            $takeoverAudit.failure_code = if ($null -ne $_.Exception.Data['errorCode']) { [string]$_.Exception.Data['errorCode'] } elseif ($_.Exception.Message -match '^([A-Za-z][A-Za-z0-9]+)：') { $Matches[1] } else { 'CleanupPreflightFailed' }
            try { $result.owner_takeover.audit_sha256 = Write-CleanupTakeoverAudit -Path $takeoverAuditPath -Audit $takeoverAudit -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath } catch { }
        }
        if ($null -ne $_.Exception.Data['operationResult']) {
            throw
        }
        $detail = [ordered]@{
            field = 'cleanup'
            expected = 'operation success'
            received = $_.Exception.Message
            source = 'Cleanup'
            exception_type = $_.Exception.GetType().FullName
            stack = $_.ScriptStackTrace
        }
        $takeoverRejection = $_.Exception.Data['takeoverRejection']
        if ($null -ne $takeoverRejection) { $detail.takeover_rejection = $takeoverRejection }
        $failureCode = if ($null -ne $_.Exception.Data['errorCode']) { [string]$_.Exception.Data['errorCode'] } elseif ($_.Exception.Message -match '^(Cleanup[A-Za-z0-9]+)：') { $Matches[1] } else { 'CleanupPreflightFailed' }
        Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode $failureCode -Message $_.Exception.Message -Detail $detail -TakeoverRejection $takeoverRejection
    }
    finally {
        if ($null -ne $unstartedAudit -and -not $result.worktree_removed -and $unstartedAudit.status -cne 'failed') {
            $unstartedAudit.status = 'failed'
            $unstartedAudit.failure_code = $result.failure_code
            try { $result.unstarted_proof.audit_sha256 = Write-CleanupUnstartedAudit -Path $unstartedAuditPath -Audit $unstartedAudit -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath } catch { }
        }
        if ($null -ne $takeoverAudit -and -not $result.worktree_removed -and $takeoverAudit.status -cne 'failed') {
            $takeoverAudit.status = 'failed'
            $takeoverAudit.failure_code = $result.failure_code
            try { $result.owner_takeover.audit_sha256 = Write-CleanupTakeoverAudit -Path $takeoverAuditPath -Audit $takeoverAudit -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath } catch { }
        }
        Close-DispatchAdmissionLock -Lock $admissionLock
    }
}
