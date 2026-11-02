#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('turn-guard-test-' + [guid]::NewGuid().ToString('N'))
$hook = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'claude-plugins\ai-agents-hooks\hooks\turn-guard-hook.ps1'
$previous = $env:CLAUDE_PLUGIN_DATA
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $env:CLAUDE_PLUGIN_DATA = $root
    function Send-Event([string]$Json) {
        $output = $Json | & powershell.exe -NoProfile -NonInteractive -File $hook 2>&1
        if ($LASTEXITCODE -ne 0 -or @($output).Count -ne 0) { throw "hook output or exit failure: $output" }
    }
    Send-Event '{"session_id":"test","hook_event_name":"UserPromptSubmit","prompt":"private prompt marker"}'
    Send-Event '{"session_id":"test","hook_event_name":"PostToolUse","tool_name":"Read"}'
    Send-Event '{"session_id":"test","hook_event_name":"PostToolUse","tool_name":"Grep"}'
    Send-Event '{"session_id":"test","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}'
    Send-Event '{"session_id":"test","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"cat x > y"}}'
    $failure = '{"session_id":"test","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"bad token=abc123 Bearer xyz"},"error":"failed"}'
    Send-Event $failure
    Send-Event $failure
    Send-Event '{"session_id":"test","hook_event_name":"Stop"}'
    Send-Event '{"session_id":"test","hook_event_name":"UserPromptSubmit","prompt":"second"}'
    $path = Join-Path $root 'turn-guard\test.jsonl'
    $rows = @(Get-Content -LiteralPath $path | ForEach-Object { $_ | ConvertFrom-Json })
    if ($rows.Count -ne 9 -or $rows[3].counts.evidence -ne 3 -or $rows[4].class -ne 'other' -or $rows[6].fingerprint.repeat -ne 2 -or -not $rows[7].turn_end -or @($rows[7].fingerprints).Count -ne 1 -or $rows[8].turn -ne 2 -or $rows[8].counts.evidence -ne 0) { throw 'event sequence mismatch' }
    foreach ($row in $rows) { if ($row.v -ne 1 -or $null -ne $row.PSObject.Properties['rev']) { throw 'schema version mismatch' } }
    $text = [IO.File]::ReadAllText($path)
    if ($text -match 'private prompt marker|token=abc123|Bearer xyz' -or $rows[6].fingerprint.text -notmatch '<redacted>') { throw 'sensitive data mismatch' }
    Send-Event '{"session_id":"negative","hook_event_name":"PostToolUse","tool_name":"PowerShell","tool_input":{"command":"Remove-Item x"}}'
    $negative = Get-Content (Join-Path $root 'turn-guard\negative.jsonl') | ConvertFrom-Json
    if ($negative.class -ne 'other' -or $negative.counts.readonly_cmd -ne 0) { throw 'mutating command classified readonly' }
    Send-Event '{"session_id":"normalize","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"echo 12345678-1234-1234-1234-123456789abc 2026-11-03T12:13:14Z 12345"},"error":"failure"}'
    $normalized = Get-Content (Join-Path $root 'turn-guard\normalize.jsonl') | ConvertFrom-Json
    if ($normalized.fingerprint.text -notmatch '<guid>' -or $normalized.fingerprint.text -notmatch '<ts>' -or $normalized.fingerprint.text -notmatch '#') { throw 'normalization mismatch' }
    $commands = @(
        @{command="git status`r`ngit log"; expected='readonly_cmd'},
        @{command="git status`n`ngit log"; expected='readonly_cmd'},
        @{command="git status &&`ngit log;"; expected='readonly_cmd'},
        @{command='cd X && git status'; expected='readonly_cmd'},
        @{command='Set-Location X; pushd X; git status'; expected='readonly_cmd'},
        @{command='cd X && rm a'; expected='other'},
        @{command='git branch'; expected='readonly_cmd'},
        @{command='git branch -vv'; expected='readonly_cmd'},
        @{command='git branch --list feat*'; expected='readonly_cmd'},
        @{command='git branch --contains HEAD'; expected='readonly_cmd'},
        @{command='git branch --format="%(refname) %(upstream)"'; expected='readonly_cmd'},
        @{command="git branch --list 'feat x*'"; expected='readonly_cmd'},
        @{command='git branch "new branch"'; expected='other'},
        @{command='git branch "--format=%(refname) %(upstream)"'; expected='readonly_cmd'},
        @{command="git branch '--contains=HEAD'"; expected='readonly_cmd'},
        @{command='git branch "--delete" x'; expected='other'},
        @{command='git branch review-probe'; expected='other'},
        @{command='git branch --delete review-probe'; expected='other'},
        @{command='git branch -M new-name'; expected='other'}
    )
    foreach ($case in $commands) {
        $event = @{session_id='commands';hook_event_name='PostToolUse';tool_name='PowerShell';tool_input=@{command=$case.command}} | ConvertTo-Json -Compress
        Send-Event $event
        $last = Get-Content (Join-Path $root 'turn-guard\commands.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
        if ($last.class -ne $case.expected) { throw "command classification failed: $($case.command)" }
    }
    $secretEvent = @{session_id='secrets';hook_event_name='PostToolUseFailure';tool_name='Bash';tool_input=@{command='Authorization: Bearer sensitive-token Bearer another-secret'};error='2026-11-02T16:16:05 2026-11-02 16:16:05.123'} | ConvertTo-Json -Compress
    Send-Event $secretEvent
    $secret = Get-Content (Join-Path $root 'turn-guard\secrets.jsonl') | ConvertFrom-Json
    if ($secret.fingerprint.text -match 'sensitive-token|another-secret|2026-11-02' -or ([regex]::Matches($secret.fingerprint.text,'<ts>')).Count -ne 2) { throw 'authorization or timestamp redaction failed' }
    $longPath = Join-Path $root 'turn-guard\long.jsonl'
    $lines = New-Object 'System.Collections.Generic.List[string]'
    for ($i=0; $i -lt 4998; $i++) { $lines.Add('{"event":"PostToolUse","turn":1,"class":"read"}') }
    $lines.Add('{"event":"UserPromptSubmit","turn":2}')
    $lines.Add('{"event":"PostToolUse","turn":2,"class":"search"}')
    [IO.File]::WriteAllLines($longPath,$lines,(New-Object Text.UTF8Encoding($false)))
    Send-Event '{"session_id":"long","hook_event_name":"PostToolUse","tool_name":"Read"}'
    $long = Get-Content $longPath | Select-Object -Last 1 | ConvertFrom-Json
    if ($long.hook_ms -ge 1000 -or $long.counts.search -ne 1 -or $long.counts.read -ne 1) { throw "long session failed: $($long.hook_ms) ms" }
    $sharedPath = Join-Path $root 'turn-guard\shared.jsonl'
    [IO.File]::WriteAllText($sharedPath,'')
    $shared = New-Object IO.FileStream($sharedPath,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
    try { Send-Event '{"session_id":"shared","hook_event_name":"PostToolUse","tool_name":"Read"}' } finally { $shared.Dispose() }
    $sharedRecord=Get-Content $sharedPath | ConvertFrom-Json
    if ($sharedRecord.counts.read -ne 1) { throw 'shared read failed' }
    $source=[IO.File]::ReadAllText($hook)
    $attemptFile=Join-Path $root 'read-attempts.txt'
    $injectedFailure="[IO.File]::AppendAllText('" + $attemptFile.Replace("'","''") + "','x'); throw 'injected read failure'"
    $injected=$source.Replace('$stream = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)', $injectedFailure)
    if ($source -ceq $injected) { throw 'read failure injection unavailable' }
    $realHook=$hook; $hook=Join-Path $root 'read-failure-hook.ps1'
    [IO.File]::WriteAllText($hook,$injected,(New-Object Text.UTF8Encoding($true)))
    $failedPath=Join-Path $root 'turn-guard\readfailure.jsonl'
    [IO.File]::WriteAllText($failedPath,'{"event":"PostToolUse","turn":8,"class":"read"}' + "`n")
    try { Send-Event '{"session_id":"readfailure","hook_event_name":"PostToolUse","tool_name":"Grep"}' } finally { $hook=$realHook }
    $failedRecord=Get-Content $failedPath | Select-Object -Last 1 | ConvertFrom-Json
    $readErrors=@(Get-Content (Join-Path $root 'turn-guard\errors.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object type -eq 'read_failed')
    if ($failedRecord.turn -ne 0 -or $failedRecord.counts.read -ne 0 -or $failedRecord.counts.search -ne 1 -or $readErrors.Count -ne 1 -or [IO.File]::ReadAllText($attemptFile) -ne 'xxx') { throw 'read failure fallback failed' }
    if ($failedRecord.read_failed -ne $true -or $readErrors[0].session_id -ne 'readfailure') { throw 'read failure fallback not marked' }
    if ($null -ne (Get-Content (Join-Path $root 'turn-guard\test.jsonl') | Select-Object -First 1 | ConvertFrom-Json).PSObject.Properties['read_failed']) { throw 'normal record marked read_failed' }
    $recoverPath = Join-Path $root 'turn-guard\recover.jsonl'
    [IO.File]::WriteAllLines($recoverPath, @(
        '{"event":"UserPromptSubmit","turn":1}',
        '{"event":"UserPromptSubmit","turn":2}',
        '{"event":"PostToolUseFailure","turn":2,"class":"other","fingerprint":{"hash":"abc","text":"t","repeat":1}}',
        '{"event":"PostToolUseFailure","turn":2,"class":"other","fingerprint":{"hash":"abc","text":"t","repeat":2}}',
        '{"event":"PostToolUseFailure","turn":0,"class":"other","read_failed":true,"fingerprint":{"hash":"abc","text":"t","repeat":1}}'
    ), (New-Object Text.UTF8Encoding($false)))
    Send-Event '{"session_id":"recover","hook_event_name":"Stop"}'
    $recovered = Get-Content $recoverPath | Select-Object -Last 1 | ConvertFrom-Json
    $recoveredFp = @($recovered.fingerprints | Where-Object hash -eq 'abc')
    if ($recovered.turn -ne 2 -or $recovered.counts.failure -ne 3 -or $recoveredFp.Count -ne 1 -or $recoveredFp[0].repeat -ne 3 -or $null -ne $recovered.PSObject.Properties['read_failed']) { throw 'read recovery did not recompute turn and repeat' }
    Send-Event ''
    Send-Event 'invalid'
    Send-Event '{"hook_event_name":"Stop"}'
    $errors = Join-Path $root 'turn-guard\errors.jsonl'
    if (@(Get-Content $errors).Count -ne 4) { throw 'invalid input mismatch' }
    foreach ($file in @($path,$errors)) { $bytes=[IO.File]::ReadAllBytes($file); if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { throw 'unexpected BOM' } }
    $env:CLAUDE_PLUGIN_DATA = $null
    $cwd=Join-Path $root 'cwd'; New-Item -ItemType Directory -Path $cwd | Out-Null
    $before=@(Get-ChildItem -LiteralPath $root -Recurse -Force | ForEach-Object FullName | Sort-Object)
    Push-Location $cwd
    try { Send-Event '{"session_id":"disabled","hook_event_name":"Stop"}' } finally { Pop-Location }
    $after=@(Get-ChildItem -LiteralPath $root -Recurse -Force | ForEach-Object FullName | Sort-Object)
    if (Compare-Object $before $after) { throw 'unset data created files in temp or current directory' }
    Write-Host "Long session hook_ms: $($long.hook_ms)"
    Write-Host 'Turn guard tests passed.'
} finally { $env:CLAUDE_PLUGIN_DATA = $previous }
exit 0
