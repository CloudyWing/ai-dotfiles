#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$timer = [Diagnostics.Stopwatch]::StartNew()
$event = $null
$directory = $null
# 清單只收錄確認不改變狀態的命令。
$readCommands = @('ls','dir','cat','type','head','tail','rg','grep','find','wc','stat','Get-Content','Get-ChildItem','Get-Item','Select-String','Test-Path','Get-Command','Measure-Object','Resolve-Path','Split-Path','Join-Path')
function Get-Value($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}
# git branch 只有查詢型旗標時才視為唯讀；出現分支名稱或其他選項即屬寫入。
function Test-ReadOnlyGitBranch([string]$Part) {
    $flags = @('-a','--all','-r','--remotes','-v','-vv','--verbose','-l','--list','--show-current','--no-color','--color','--column','--no-column')
    $valueFlags = @('--list','-l','--contains','--no-contains','--merged','--no-merged','--points-at','--sort','--format')
    $unquoted = [regex]::Replace($Part, '"([^"]*)"|''([^'']*)''', { param($m) ($m.Groups[1].Value + $m.Groups[2].Value) -replace '\s+', '' })
    $tokens = @(($unquoted -split '\s+') | Select-Object -Skip 2 | Where-Object { $_ -ne '' })
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i]
        if ($token -cmatch '^(--contains|--no-contains|--merged|--no-merged|--points-at|--sort|--format)=') { continue }
        if ($flags -ccontains $token) { if ($valueFlags -ccontains $token -and $i + 1 -lt $tokens.Count -and $tokens[$i + 1] -notlike '-*') { $i++ }; continue }
        if ($valueFlags -ccontains $token) { if ($i + 1 -lt $tokens.Count) { $i++ }; continue }
        return $false
    }
    return $true
}
function Test-ReadOnly([string]$Command) {
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    foreach ($part in ($Command -split '&&|\|\||[;|\r\n]')) {
        $part = $part.Trim() -replace '^&\s+', ''
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        if ($part -match '(?i)^(?:cd|Set-Location|pushd)\s+(?:"[^"]+"|''[^'']+''|\S+)\s*$') { continue }
        $part = $part -replace '^cd\s+\S+\s+', ''
        if ($part -match '(?i)>|\b(?:out-file|set-content|add-content|remove-\S*|set-\S*|new-\S*|move-\S*|copy-\S*|rm|mv|cp|mkdir)\b') { return $false }
        if ($readCommands -contains ($part -split '\s+')[0]) { continue }
        if ($part -match '^git\s+(status|log|diff|show|rev-parse|ls-files)(\s|$)') { continue }
        if ($part -match '^git\s+branch(\s|$)' -and (Test-ReadOnlyGitBranch $part)) { continue }
        if ($part -match '^git\s+config\s+--get(\s|$)' -or $part -match '^sed\s+-n(\s|$)') { continue }
        return $false
    }
    return $true
}
function Get-Normalized([string]$Value) {
    $value = $Value.Trim() -replace '\s+', ' ' -replace '\\', '/'
    $value = $value -replace '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', '<guid>'
    $value = $value -replace '\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)?', '<ts>' -replace '\d{4,}', '#'
    $value = $value -replace '(?i)Bearer\s+[^\s"'']+', '<redacted>' -replace '(?i)(token|password|passwd|secret|api[-_]?key|authorization)\s*[=:]\s*\S+', '<redacted>'
    if ($value.Length -gt 200) { return $value.Substring(0,200) }
    return $value
}
function Write-Record([string]$Path, $Record) {
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($Record | ConvertTo-Json -Compress -Depth 8) + "`n")
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            return
        } catch { if ($attempt -lt 2) { Start-Sleep -Milliseconds 20 } }
    }
    throw 'record_write_failed'
}
try {
    if ([string]::IsNullOrWhiteSpace($env:CLAUDE_PLUGIN_DATA)) { exit 0 }
    $directory = Join-Path $env:CLAUDE_PLUGIN_DATA 'turn-guard'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    [Console]::InputEncoding = [Text.Encoding]::UTF8
    $inputText = [Console]::In.ReadToEnd()
    try { $inputObject = $inputText | ConvertFrom-Json -ErrorAction Stop } catch { throw 'stdin_invalid' }
    if ($null -eq $inputObject -or $null -eq $inputObject.PSObject.Properties['session_id']) { throw 'stdin_invalid' }
    $session = $inputObject.PSObject.Properties['session_id'].Value
    if ($session -isnot [string] -or $session -notmatch '^[A-Za-z0-9_-]+$') { throw 'stdin_invalid' }
    $event = Get-Value $inputObject 'hook_event_name'
    $path = Join-Path $directory ($session + '.jsonl')
    $turn = 0; $promptCount = 0; $readFailed = $false
    $currentLines = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path -LiteralPath $path) {
        $readSucceeded = $false
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            try {
                $currentLines.Clear(); $promptCount = 0
                $stream = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try {
                    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
                    try {
                        while ($null -ne ($line = $reader.ReadLine())) {
                            if ($line -match '"event"\s*:\s*"UserPromptSubmit"') {
                                try { $candidate = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                                if ((Get-Value $candidate 'event') -eq 'UserPromptSubmit') { $promptCount++; $currentLines.Clear() }
                            }
                            $currentLines.Add($line)
                        }
                    } finally { $reader.Dispose() }
                } finally { $stream.Dispose() }
                $readSucceeded = $true; break
            } catch { if ($attempt -lt 2) { Start-Sleep -Milliseconds 20 } }
        }
        if (-not $readSucceeded) {
            $currentLines.Clear(); $promptCount = 0; $readFailed = $true
            try { Write-Record (Join-Path $directory 'errors.jsonl') ([ordered]@{ts=[datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH':'mm':'ss.fff'Z'",[Globalization.CultureInfo]::InvariantCulture);session_id=$session;event=$event;type='read_failed';message='session read failed after three attempts'}) } catch { }
        }
    }
    $current = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in $currentLines) {
        try { $row = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $current.Add($row)
    }
    # turn 與指紋次數一律由紀錄重算，不沿用已寫入的值，避免讀取失敗的退路數值延續到後續事件。
    $turn = $promptCount
    $counts = [ordered]@{read=0;search=0;readonly_cmd=0;other=0;failure=0;evidence=0}
    $fingerprints = [ordered]@{}
    if ($event -eq 'UserPromptSubmit') { $turn = $promptCount + 1; $current.Clear() }
    foreach ($row in $current) {
        $class = Get-Value $row 'class'; if ($null -ne $class -and $counts.Contains($class)) { $counts[$class]++ }
        if ((Get-Value $row 'event') -eq 'PostToolUseFailure') {
            $counts.failure++; $fp = Get-Value $row 'fingerprint'
            if ($null -ne $fp) {
                $key = [string]$fp.hash
                $count = 1; if ($fingerprints.Contains($key)) { $count = [int]$fingerprints[$key].repeat + 1 }
                $fingerprints[$key] = [ordered]@{hash=$key;text=[string]$fp.text;repeat=$count}
            }
        }
    }
    $record = [ordered]@{v=1;ts=[datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH':'mm':'ss.fff'Z'",[Globalization.CultureInfo]::InvariantCulture);session_id=$session;event=$event;turn=$turn;cwd=(Get-Value $inputObject 'cwd');agent_id=(Get-Value $inputObject 'agent_id')}
    if ($readFailed) { $record.read_failed = $true }
    if ($event -eq 'UserPromptSubmit') { $record.prompt_chars = ([string](Get-Value $inputObject 'prompt')).Length }
    if ($event -in @('PostToolUse','PostToolUseFailure')) {
        $tool = [string](Get-Value $inputObject 'tool_name'); $inputData = Get-Value $inputObject 'tool_input'
        $class = switch ($tool) { 'Read' {'read'} 'Grep' {'search'} 'Glob' {'search'} {$_ -in @('Bash','PowerShell')} { if (Test-ReadOnly ([string](Get-Value $inputData 'command'))) {'readonly_cmd'} else {'other'} } default {'other'} }
        $counts[$class]++; $record.tool=$tool; $record.class=$class
        if ($event -eq 'PostToolUseFailure') {
            $counts.failure++
            $subject = switch ($tool) { {$_ -in @('Bash','PowerShell')} {Get-Value $inputData 'command'} {$_ -in @('Read','Edit','Write')} {Get-Value $inputData 'file_path'} {$_ -in @('Grep','Glob')} {Get-Value $inputData 'pattern'} default {''} }
            if ($subject -isnot [string]) { $subject = '' }
            $errorText = Get-Value $inputObject 'error'; if ($errorText -isnot [string]) { $errorText = '' }
            $firstLine = @($errorText -split '[\r\n]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
            $errorLine = if ($firstLine.Count -gt 0) { $firstLine[0] } else { '' }
            $text = $tool + '|' + (Get-Normalized $subject) + '|' + (Get-Normalized $errorLine)
            $sha = [Security.Cryptography.SHA256]::Create(); try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','').ToLowerInvariant().Substring(0,12) } finally { $sha.Dispose() }
            $repeat = 1; if ($fingerprints.Contains($hash)) { $repeat = [int]$fingerprints[$hash].repeat + 1 }
            $fp = [ordered]@{hash=$hash;text=$text;repeat=$repeat}; $fingerprints[$hash]=$fp; $record.fingerprint=$fp
            $interrupt = Get-Value $inputObject 'is_interrupt'
            $record.is_interrupt = if ($interrupt -is [bool]) { $interrupt } else { $null }
        }
    }
    $counts.evidence = $counts.read + $counts.search + $counts.readonly_cmd; $record.counts=$counts
    if ($event -eq 'Stop') { $record.fingerprints=@($fingerprints.Values); $record.turn_end=$true }
    $record.hook_ms=$timer.ElapsedMilliseconds
    Write-Record $path $record
} catch {
    if ($null -ne $directory) {
        try {
            $message = $_.Exception.Message
            if ($message.Length -gt 200) { $message = $message.Substring(0, 200) }
            $type = if ($message -eq 'stdin_invalid') { 'stdin_invalid' } else { 'hook_error' }
            Write-Record (Join-Path $directory 'errors.jsonl') ([ordered]@{ts=[datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH':'mm':'ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture);event=$event;type=$type;message=$message})
        } catch { }
    }
}
exit 0
