#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Path')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Path')][string]$TranscriptPath,
    [Parameter(Mandatory, ParameterSetName = 'Id')][string]$SessionId,
    [Parameter(Mandatory, ParameterSetName = 'Latest')][string]$WorkRoot,
    [Parameter(Mandatory, ParameterSetName = 'Latest')][switch]$Latest,
    [Parameter(ParameterSetName = 'Id')][Parameter(ParameterSetName = 'Latest')][string]$ProjectsRoot = (Join-Path $env:USERPROFILE '.claude\projects')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-UsageGroup([string[]]$Paths, [bool]$IsNone) {
    $ids = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $anonymous = New-Object System.Collections.ArrayList
    $usageLines = 0; $deduped = 0; $invalid = 0
    foreach ($path in $Paths) {
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if (-not $line.Contains('"usage"')) { continue }
                try { $item = $line | ConvertFrom-Json } catch { $invalid++; continue }
                $message = Get-PropertyValue $item 'message'
                $usage = Get-PropertyValue $message 'usage'
                if ((Get-PropertyValue $item 'type') -ne 'assistant' -or $null -eq $usage -or $usage -isnot [pscustomobject]) { continue }
                $usageLines++
                $id = Get-PropertyValue $message 'id'
                if ($id -is [string] -and -not [string]::IsNullOrEmpty($id)) {
                    if ($ids.ContainsKey($id)) { $deduped++ }
                    $ids[$id] = $usage
                } else { [void]$anonymous.Add($usage) }
            }
        } finally { $reader.Dispose() }
    }
    $rows = @($ids.Values) + @($anonymous.ToArray())
    $fields = [ordered]@{ input_tokens = 'input_tokens'; cache_write_tokens = 'cache_creation_input_tokens'; cache_read_tokens = 'cache_read_input_tokens'; output_tokens = 'output_tokens' }
    $result = [ordered]@{ status = 'ok' }
    $missing = @{}
    foreach ($field in $fields.Keys) {
        [decimal]$sum = 0; $miss = 0
        foreach ($row in $rows) {
            $value = Get-PropertyValue $row $fields[$field]
            if ($null -ne $value -and ($value -is [int] -or $value -is [long] -or $value -is [bigint]) -and $value -ge 0) { $sum += $value } else { $miss++ }
        }
        $missing[$field] = $miss
        if ($IsNone) { $result[$field] = 0 }
        elseif ($rows.Count -eq 0 -or $miss -eq $rows.Count) { $result[$field] = 'unknown'; $result.status = 'unknown' }
        else { $result[$field] = $sum; if ($miss -gt 0 -and $result.status -eq 'ok') { $result.status = 'partial' } }
    }
    if ($IsNone) { $result.status = 'none' }
    $result.usage_lines = $usageLines
    $result.distinct_message_ids = $ids.Count
    $result.deduped_lines = $deduped
    $result.no_id_lines = $anonymous.Count
    $result.invalid_lines = $invalid
    foreach ($field in $fields.Keys) { $result["missing_$field"] = $missing[$field] }
    return $result
}

try {
    switch ($PSCmdlet.ParameterSetName) {
        'Path' { $file = Get-Item -LiteralPath $TranscriptPath }
        'Id' {
            if ($SessionId -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid session ID.' }
            $transcripts = @(Get-ChildItem -LiteralPath $ProjectsRoot -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Filter "$SessionId.jsonl" })
            if ($transcripts.Count -ne 1) { throw "Expected one transcript for session ID; found $($transcripts.Count)." }
            $file = $transcripts[0]
        }
        'Latest' {
            $project = $WorkRoot -replace '[^A-Za-z0-9-]', '-'
            $files = @(Get-ChildItem -LiteralPath (Join-Path $ProjectsRoot $project) -File -Filter '*.jsonl' | Sort-Object LastWriteTimeUtc -Descending)
            if ($files.Count -eq 0) { throw 'No transcript found.' }
            $file = $files[0]
        }
    }
    if ($file.PSIsContainer) { throw 'Transcript path is a directory.' }
    $session = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $subdir = Join-Path (Join-Path $file.DirectoryName $session) 'subagents'
    $subfiles = @()
    if (Test-Path -LiteralPath $subdir -PathType Container) {
        $subfiles = @(Get-ChildItem -LiteralPath $subdir -File | Where-Object { $_.Name -like 'agent-*.jsonl' -and $_.Extension -eq '.jsonl' })
        [Array]::Sort($subfiles, [System.Collections.Generic.Comparer[object]]::Create([System.Comparison[object]]{ param($a, $b) [string]::CompareOrdinal($a.Name, $b.Name) }))
    }
    $main = Get-UsageGroup @($file.FullName) $false
    $sub = Get-UsageGroup @($subfiles | ForEach-Object { $_.FullName }) ($subfiles.Count -eq 0)
    "transcript=$($file.FullName)"; "session_id=$session"; "last_write_time_utc=$($file.LastWriteTimeUtc.ToString('o'))"; "subagents_dir=$subdir"; "subagent_files=$($subfiles.Count)"
    foreach ($group in @(@('main', $main), @('subagents', $sub))) { foreach ($key in $group[1].Keys) { "$($group[0])_$key=$($group[1][$key])" } }
    $total = [ordered]@{ status = 'ok' }
    foreach ($key in @('input_tokens', 'cache_write_tokens', 'cache_read_tokens', 'output_tokens')) {
        if ($main[$key] -eq 'unknown' -or $sub[$key] -eq 'unknown') { $total[$key] = 'unknown'; $total.status = 'unknown' }
        else { $total[$key] = $main[$key] + $sub[$key] }
    }
    if ($total.status -eq 'ok' -and ($main.status -eq 'partial' -or $sub.status -eq 'partial')) { $total.status = 'partial' }
    foreach ($key in $total.Keys) { "total_$key=$($total[$key])" }
    exit 0
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
