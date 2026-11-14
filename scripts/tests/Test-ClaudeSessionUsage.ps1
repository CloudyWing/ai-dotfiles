#Requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:TEMP ('claude-usage-test-' + [guid]::NewGuid().ToString('N'))
$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'Get-ClaudeSessionUsage.ps1'
function Assert-Equal($Actual, $Expected, [string]$Name) { if ($Actual -ne $Expected) { throw "$Name expected [$Expected], got [$Actual]" } }
function Invoke-Usage([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $output = & pwsh -NoProfile -File $script @Arguments 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    $values = @{}
    foreach ($line in $output) { if ("$line" -match '^([^=]+)=(.*)$') { $values[$Matches[1]] = $Matches[2] } }
    return @{ code = $code; values = $values; output = ($output -join "`n") }
}
function Write-Lines([string]$Path, [string[]]$Lines) { [IO.File]::WriteAllLines($Path, $Lines, (New-Object Text.UTF8Encoding($false))) }
try {
    $projectName = 'C--fixture-project'
    $project = Join-Path $root $projectName
    $sub = Join-Path $project 'session1\subagents'
    New-Item -ItemType Directory -Path $sub -Force | Out-Null
    $main = Join-Path $project 'session1.jsonl'
    $u = '"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":'
    Write-Lines $main @(('{"type":"assistant","message":{"id":"a","usage":{' + $u + '1}}}'), ('{"type":"assistant","message":{"id":"a","usage":{' + $u + '5}}}'), ('{"type":"assistant","message":{"usage":{' + $u + '7}}}'), ('{"type":"user","message":{"usage":{' + $u + '99}}}'), '{"usage":')
    Write-Lines (Join-Path $sub 'agent-a.jsonl') @('{"type":"assistant","message":{"id":"s","usage":{' + $u + '10}}}')
    Write-Lines (Join-Path $sub 'agent-b.jsonl') @('{"type":"assistant","message":{"id":"s","usage":{' + $u + '20}}}')
    Write-Lines (Join-Path $sub 'agent-b.meta.json') @('{"usage":{"output_tokens":999}}')
    Write-Lines (Join-Path $sub 'agent-b.prefix.json') @('{"usage":{"output_tokens":999}}')
    $result = Invoke-Usage @('-TranscriptPath', $main)
    Assert-Equal $result.code 0 'path exit'
    foreach ($pair in @(@('main_input_tokens','2'),@('main_cache_write_tokens','4'),@('main_cache_read_tokens','6'),@('main_output_tokens','12'),@('main_usage_lines','3'),@('main_distinct_message_ids','1'),@('main_deduped_lines','1'),@('main_no_id_lines','1'),@('main_invalid_lines','1'),@('subagent_files','2'),@('subagents_input_tokens','1'),@('subagents_cache_write_tokens','2'),@('subagents_cache_read_tokens','3'),@('subagents_output_tokens','20'),@('subagents_deduped_lines','1'),@('total_input_tokens','3'),@('total_cache_write_tokens','6'),@('total_cache_read_tokens','9'),@('total_output_tokens','32'))) { Assert-Equal $result.values[$pair[0]] $pair[1] $pair[0] }
    if ($result.values.ContainsKey('scope')) { throw 'Unexpected scope key.' }
    $id = Invoke-Usage @('-SessionId', 'session1', '-ProjectsRoot', $root)
    $latest = Invoke-Usage @('-WorkRoot', 'C:\fixture\project', '-Latest', '-ProjectsRoot', $root)
    Assert-Equal $id.code 0 'id exit'; Assert-Equal $latest.code 0 'latest exit'
    Assert-Equal $id.values.subagents_dir $result.values.subagents_dir 'id directory'
    Assert-Equal $latest.values.subagents_dir $result.values.subagents_dir 'latest directory'
    $none = Join-Path $project 'none.jsonl'
    Write-Lines $none @('{"type":"assistant","message":{"usage":{' + $u + '4}}}')
    $r = Invoke-Usage @('-TranscriptPath', $none)
    Assert-Equal $r.code 0 'none exit'; Assert-Equal $r.values.subagents_status 'none' 'none status'; Assert-Equal $r.values.subagent_files '0' 'none files'; Assert-Equal $r.values.total_output_tokens '4' 'none total'
    Write-Lines $none @('{"type":"assistant","message":{"usage":{"output_tokens":4}}}', '{"type":"assistant","message":{"usage":{"input_tokens":2,"output_tokens":1}}}')
    $r = Invoke-Usage @('-TranscriptPath', $none)
    Assert-Equal $r.values.main_status 'unknown' 'unknown status'; Assert-Equal $r.values.main_cache_write_tokens 'unknown' 'unknown field'; Assert-Equal $r.values.main_input_tokens '2' 'partial field'; Assert-Equal $r.values.main_missing_input_tokens '1' 'partial count'
    Write-Lines $none @(('{"type":"assistant","message":{"usage":{' + $u + '4}}}'), '{"type":"assistant","message":{"usage":{"output_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}}')
    $r = Invoke-Usage @('-TranscriptPath', $none)
    Assert-Equal $r.values.main_status 'partial' 'partial status'; Assert-Equal $r.values.total_status 'partial' 'partial total'
    Write-Lines $none @()
    $r = Invoke-Usage @('-TranscriptPath', $none)
    Assert-Equal $r.values.main_status 'unknown' 'empty status'; Assert-Equal $r.values.total_output_tokens 'unknown' 'empty total'
    Write-Lines $none @('{"type":"user","message":{"content":"no usage"}}')
    $emptySub = Join-Path $project 'none\subagents'
    New-Item -ItemType Directory -Path $emptySub -Force | Out-Null
    Write-Lines (Join-Path $emptySub 'agent-empty.jsonl') @('{"type":"user"}')
    $r = Invoke-Usage @('-TranscriptPath', $none)
    Assert-Equal $r.values.main_usage_lines '0' 'no usage'; Assert-Equal $r.values.subagents_status 'unknown' 'empty subagent status'; Assert-Equal $r.values.subagent_files '1' 'empty subagent file'
    $r = Invoke-Usage @('-TranscriptPath', (Join-Path $project 'missing.jsonl'))
    Assert-Equal $r.code 1 'missing exit'
    if ($r.values.ContainsKey('main_status')) { throw 'Missing file emitted main status.' }
    Write-Output 'PASS: Claude session usage fixtures'
    exit 0
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
