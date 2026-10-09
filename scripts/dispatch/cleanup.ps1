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
        inventory          = [ordered]@{
            report_root = $null
            referenced_paths = @()
            source_count = 0
        }
    }
}

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
        [AllowNull()][object]$Detail
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
    throw $exception
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
        'prepare_result_path', 'quota_before_path', 'quota_after_path', 'quota_observation_path',
        'budget_monitor_path', 'interruption_checkpoint_path'
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

function Get-CleanupInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DispatchRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [AllowEmptyString()][string]$RunRecordPath,
        [AllowEmptyCollection()][string[]]$EvidencePath,
        [AllowEmptyCollection()][string[]]$ReportPath = @()
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

function Test-CleanupUtf8Readback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if (@('.md', '.json', '.jsonl', '.log', '.txt') -notcontains $extension) {
        return [ordered]@{ status = 'not-applicable'; error = $null }
    }
    try {
        $encoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
        $null = [IO.File]::ReadAllText((ConvertTo-FileSystemApiPath -Path (Resolve-AbsolutePath $Path)), $encoding)
        return [ordered]@{ status = 'passed'; error = $null }
    }
    catch {
        return [ordered]@{ status = 'failed'; error = $_.Exception.Message }
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

function Compare-CleanupReportVersion {
    [CmdletBinding()]
    param([string]$IncomingPath, [string]$DestinationPath, [string]$SourceRoot, [string]$LineSlug, [string]$DispatchSlug)

    $incoming = Get-CleanupReportVersion -Path $IncomingPath -SourceRoot $SourceRoot -LineSlug $LineSlug -KnownDispatchSlug $DispatchSlug
    $destination = Get-CleanupReportVersion -Path $DestinationPath -SourceRoot $SourceRoot -LineSlug $LineSlug -KnownDispatchSlug ''
    $kind = ''; $comparison = 0
    if ($null -ne $incoming.started_at -and $null -ne $destination.started_at -and $incoming.dispatch_slug -cne $destination.dispatch_slug) {
        $kind = 'run-record-started-at-utc'; $comparison = [DateTimeOffset]::Compare($incoming.started_at, $destination.started_at)
    }
    elseif ($incoming.round -gt 0 -and $destination.round -gt 0) {
        $kind = 'report-manifest-round'; $comparison = $incoming.round.CompareTo($destination.round)
    }
    if ($comparison -eq 0) { throw ('CleanupReportVersionUnknown：無法判斷固定報告新舊，保留 worktree。incoming=' + $IncomingPath + '; destination=' + $DestinationPath) }
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
    $archivePath = $null
    $versionDecision = $null
    if ($destinationExists) {
        $existingHash = Get-FileSha256 -Path $destinationPath
        if ([string]$Item.relative_path -cmatch '^\.local/ai-sessions/report/[a-z0-9]+(?:-[a-z0-9]+)*/exceptions\.md$') {
            $strictUtf8 = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
            $sourceText = $strictUtf8.GetString($bytes)
            $destinationText = [IO.File]::ReadAllText((ConvertTo-FileSystemApiPath -Path $destinationPath), $strictUtf8)
            $mergedText = Join-CleanupExceptionBlocks -SourceText $sourceText -DestinationText $destinationText
            $expectedDestinationHash = $existingHash
            if ($null -ne $mergedText) {
                $mergedBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($mergedText)
                $expectedDestinationHash = Get-DispatchByteArraySha256 -Bytes $mergedBytes
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
                    [IO.File]::Replace((ConvertTo-FileSystemApiPath -Path $temporaryPath), (ConvertTo-FileSystemApiPath -Path $destinationPath), (ConvertTo-FileSystemApiPath -Path $backupPath))
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
            [string]$Item.relative_path -cmatch '^\.local/ai-sessions/report/(?:[a-z0-9]+(?:-[a-z0-9]+)*/(?:review-report|frontend-reviewer-report|contract-auditor-report)|dispatch-report-[a-z0-9]+(?:-[a-z0-9]+)*)\.md$') {
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
                    [IO.File]::Replace((ConvertTo-FileSystemApiPath -Path $temporaryPath), (ConvertTo-FileSystemApiPath -Path $destinationPath), (ConvertTo-FileSystemApiPath -Path $archivePath))
                    $archiveHash = $existingHash
                }
                else {
                    [IO.File]::Move((ConvertTo-FileSystemApiPath -Path $temporaryPath), (ConvertTo-FileSystemApiPath -Path $archivePath))
                    $archiveHash = $sourceHashBefore
                    $expectedDestinationHash = $existingHash
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
    if (-not [string]::Equals($sourceHashBefore, $sourceHashAfter, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('SourceChangedDuringPreservation：來源在保存期間變更：' + $sourcePath)
    }
    $destinationHash = Get-FileSha256 -Path $destinationPath
    if (-not [string]::Equals($expectedDestinationHash, $destinationHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('CleanupHashMismatch：destination SHA-256 不一致：' + $destinationPath)
    }
    $readback = Test-CleanupUtf8Readback -Path $destinationPath
    if ($readback.status -eq 'failed') {
        throw ('CleanupReadbackFailed：destination UTF-8 readback 失敗：' + $destinationPath + '；' + $readback.error)
    }
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
    $path = Resolve-AbsolutePath $FailureReceiptPath
    $sourceHistory = Join-Path (Join-Path $SourceRoot '.local\ai-sessions\history') $LineSlug
    $dispatchHistory = Join-Path (Join-Path $DispatchRoot '.local\ai-sessions\history') $LineSlug
    if (-not (Test-PathWithinRoot $path $sourceHistory) -and -not (Test-PathWithinRoot $path $dispatchHistory)) { throw ('CleanupFailureReceiptBoundary：' + $path) }
    Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $path
    $receipt = (Read-CleanupJsonDocument -Path $path -Name 'FailureReceipt').Document
    foreach ($pair in @(@('schema','ai-sessions.dispatch-failure-receipt.v1'), @('source_root',$SourceRoot), @('dispatch_root',$DispatchRoot), @('execution_root',$DispatchRoot), @('line_slug',$LineSlug), @('dispatch_slug',$DispatchSlug))) {
        if ([string](Get-CleanupPropertyValue -Object $receipt -Names @($pair[0])) -cne [string]$pair[1]) { throw ('CleanupIdentityMismatch：failure receipt 的 ' + $pair[0] + ' 不符。') }
    }
    $started = Get-CleanupPropertyValue -Object $receipt -Names @('process_started')
    return ($started -is [bool] -and -not $started)
}

function Invoke-Cleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $result = New-CleanupOperationResult -SourceRoot ([string]$SourceRoot) -DispatchRoot ([string]$DispatchRoot) -LineSlug ([string]$LineSlug) -DispatchSlug ([string]$DispatchSlug)
    $admissionLock = $null
    $admissionLedger = $null
    $admissionOwner = $null
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
        $residualRecovery = -not $registered -and (Test-CleanupRemovalReceipt -Path $removalReceiptPath -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug)
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
        $unstarted = Test-CleanupUnstartedProof -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunRecordPath ([string]$RunRecordPath) -FailureReceiptPath $failureReceiptValue -HasPreflight $hasPreflight
        if (-not $hasPreflight -and $hasRunRecord -and (Test-CleanupUnstartedRunRecordEventStreamPresent -Path ([string]$RunRecordPath) -SourceRoot $sourceRootPath -ExecutionRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug)) {
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupPreflightResultRequired' -Message 'Cleanup 缺少有效的 Preflight 或未啟動證據；無 RunRecord 的 Preflight-only 清理要求 worktree history 不含 event stream 與 thread 檔。'
        }
        if (-not $hasPreflight -and -not $unstarted -and -not $residualRecovery) {
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupPreflightResultRequired' -Message 'Cleanup 缺少有效的 Preflight 或未啟動證據；無 RunRecord 的 Preflight-only 清理要求 worktree history 不含 event stream 與 thread 檔。'
        }

        $preflightOnlyMissingProof = -not $hasRunRecord -and (-not $hasPreflight -or -not $unstarted)
        if (-not $residualRecovery -and $preflightOnlyMissingProof) {
            Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode 'CleanupPreflightResultRequired' -Message 'Cleanup 缺少有效的 Preflight 或未啟動證據；無 RunRecord 的 Preflight-only 清理要求 worktree history 不含 event stream 與 thread 檔。'
        }

        if ($null -ne $script:CallerSessionIdentity) {
            $admissionLock = Open-DispatchAdmissionLock -SourceRoot $sourceRootPath
            $admissionLedger = Read-DispatchAdmissionLedger -Lock $admissionLock
            $knownOwners = @($admissionLedger.Document.entries | Where-Object { [string]$_.dispatch_slug -ceq $DispatchSlug })
            if ($knownOwners.Count -gt 0 -or (-not $unstarted -and -not $residualRecovery)) {
                $admissionOwner = Assert-DispatchRecoveryOwner -Lock $admissionLock -Ledger $admissionLedger -CallerIdentity $script:CallerSessionIdentity -SourceRoot $sourceRootPath -ExecutionRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunRecordPath $RunRecordPath
            }
        }
        Assert-CleanupStopped -SourceRoot $sourceRootPath -DispatchSlug $DispatchSlug -LineSlug $LineSlug -Owner $admissionOwner

        try {
            $inventory = Get-CleanupInventory -SourceRoot $sourceRootPath -DispatchRoot $dispatchRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunRecordPath $RunRecordPath -EvidencePath $EvidencePath -ReportPath @(Get-DispatchScriptVariableValue -Name 'ReportPath')
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
            $admissionOwner.state = 'cleaned'
            $admissionOwner | Add-Member -MemberType NoteProperty -Name 'cleaned_at_utc' -Value ([DateTime]::UtcNow.ToString('o')) -Force
            $null = Write-DispatchAdmissionLedger -Lock $admissionLock -Ledger $admissionLedger
        }
        $result.worktree_removed = $true
        $result.status = 'completed'
        $result.failure_code = $null
        $null = Write-DispatchAtomicJsonDocument -Path $removalReceiptPath -Document $result -SourceRoot $sourceRootPath -ExecutionRoot $sourceRootPath -TargetPath @()
        return $result
    }
    catch {
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
        $failureCode = if ($null -ne $_.Exception.Data['errorCode']) { [string]$_.Exception.Data['errorCode'] } else { 'CleanupPreflightFailed' }
        Throw-CleanupOperationFailure -Result $result -Status 'preflight-rejected' -FailureCode $failureCode -Message $_.Exception.Message -Detail $detail
    }
    finally {
        Close-DispatchAdmissionLock -Lock $admissionLock
    }
}
