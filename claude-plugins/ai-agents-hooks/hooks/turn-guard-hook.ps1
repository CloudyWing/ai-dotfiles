#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$timer = [Diagnostics.Stopwatch]::StartNew()
$event = $null
$directory = $null
function Write-Record([string]$Path, $Record) {
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($Record | ConvertTo-Json -Compress -Depth 8) + "`n")
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            return
        } catch { if ($attempt -lt 2) { Start-Sleep -Milliseconds 20 } }
    }
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
    $eventProperty = $inputObject.PSObject.Properties['hook_event_name']
    if ($null -ne $eventProperty) { $event = $eventProperty.Value }
    $tool = $null
    $toolProperty = $inputObject.PSObject.Properties['tool_name']
    if ($null -ne $toolProperty) { $tool = $toolProperty.Value }
    Write-Record (Join-Path $directory ($session + '.jsonl')) ([ordered]@{v=0;rev='p3-b';ts=[datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH':'mm':'ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture);session_id=$session;event=$event;tool=$tool;hook_ms=$timer.ElapsedMilliseconds})
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
