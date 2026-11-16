#Requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('turn-guard-test-' + [guid]::NewGuid().ToString('N'))
# 判定邏輯在 hooks\core\turn-guard.ts，由 tests\run-hook.ts 以命令型 hook 的 stdin 與 stdout 形式執行。
$pluginRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'claude-plugins\ai-agents-hooks'
$runHook = Join-Path $pluginRoot 'tests\run-hook.ts'
$hook = Join-Path $pluginRoot 'hooks\core\turn-guard.ts'
$hookMode = 'turn-guard'
$previous = $env:CLAUDE_PLUGIN_DATA
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $env:CLAUDE_PLUGIN_DATA = $root
    # 以原始位元組取得 hook 的 stdout，供斷言提醒輸出的編碼與 BOM。stdin 以無 BOM 的 UTF-8 送入。
    function Invoke-Hook([string]$Json) {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = 'node'
        $psi.Arguments = '--no-warnings "' + $runHook + '" ' + $hookMode
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($psi)
        try {
            $errorTask = $process.StandardError.ReadToEndAsync()
            $outputStream = New-Object IO.MemoryStream
            $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($outputStream)
            $inputBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Json)
            $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(60000)) { try { $process.Kill() } catch { }; throw 'hook process timeout' }
            $copyTask.Wait(); $errorTask.Wait()
            return [pscustomobject]@{ExitCode=$process.ExitCode;Stdout=$outputStream.ToArray();Stderr=$errorTask.Result}
        } finally { $process.Dispose() }
    }
    function Send-Event([string]$Json) {
        $result = Invoke-Hook $Json
        if ($result.ExitCode -ne 0 -or $result.Stdout.Length -ne 0 -or $result.Stderr.Length -ne 0) { throw "hook output or exit failure: exit=$($result.ExitCode) stdout=$([Text.Encoding]::UTF8.GetString($result.Stdout)) stderr=$($result.Stderr)" }
    }
    function Get-ReminderText([string]$FingerprintText, [int]$Repeat) {
        return '同一失敗已在本 turn 重複 ' + $Repeat + ' 次：' + $FingerprintText + '。下一次嘗試前先說明為什麼這次會成功；說不出來就停下並回報。'
    }
    # 送出一筆預期會提醒的事件，斷言 stdout 為單一純 ASCII、無 BOM 的 JSON 物件，回傳解析後的 additionalContext。
    function Send-EventExpectReminder([string]$Json, [string]$ExpectedText) {
        $result = Invoke-Hook $Json
        if ($result.ExitCode -ne 0 -or $result.Stderr.Length -ne 0) { throw "reminder exit or stderr failure: exit=$($result.ExitCode) stderr=$($result.Stderr)" }
        $bytes = $result.Stdout
        if ($bytes.Length -eq 0) { throw 'reminder stdout is empty' }
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { throw 'reminder stdout has BOM' }
        foreach ($b in $bytes) { if ($b -ge 128) { throw 'reminder stdout contains non-ASCII byte' } }
        $outText = [Text.Encoding]::ASCII.GetString($bytes)
        if ($outText.Trim() -notmatch '^\{.*\}$' -or @($outText.Trim() -split '\r?\n').Count -ne 1) { throw "reminder stdout is not a single json object: $outText" }
        try { $parsed = $outText | ConvertFrom-Json -ErrorAction Stop } catch { throw "reminder stdout is not valid json: $outText" }
        $names = @($parsed.PSObject.Properties.Name)
        if ($names.Count -ne 1 -or $names[0] -ne 'hookSpecificOutput') { throw 'reminder top-level shape mismatch' }
        $specific = $parsed.hookSpecificOutput
        $specificNames = @($specific.PSObject.Properties.Name | Sort-Object)
        if ($specificNames.Count -ne 2 -or $specificNames[0] -ne 'additionalContext' -or $specificNames[1] -ne 'hookEventName') { throw 'reminder hookSpecificOutput shape mismatch' }
        if ($specific.hookEventName -ne 'PostToolUseFailure') { throw 'reminder hookEventName mismatch' }
        if ($specific.additionalContext -cne $ExpectedText) { throw "reminder text mismatch: $($specific.additionalContext)" }
    }
    # 每個模組實例寫自己的檔（<名稱>.<實例>.jsonl 與輪替的 <名稱>.<實例>.<段>.jsonl），另有命令型 hook 時期的 <名稱>.jsonl。
    function Get-LogFiles([string]$Name, [string]$Root = $root) {
        $directory = Join-Path $Root 'turn-guard'
        if (-not (Test-Path -LiteralPath $directory)) { return @() }
        return @(Get-ChildItem -LiteralPath $directory -File | Where-Object { $_.Name -cmatch ('^' + [regex]::Escape($Name) + '(\.[A-Za-z0-9]+(\.[0-9]+)?)?\.jsonl$') } | Sort-Object { $_.Name.Length }, Name)
    }
    # 依紀錄時間合併同名的全部檔；沒有 ts 的列排在最前，同時間的列保留檔內順序。ts 以字串取出，避免 ConvertFrom-Json 轉成日期。
    function Read-Lines([string]$Name, [string]$Root = $root) {
        $items = @(foreach ($file in (Get-LogFiles $Name $Root)) {
            foreach ($line in @(Get-Content -LiteralPath $file.FullName -Encoding UTF8)) {
                $match = [regex]::Match($line, '"ts":"([^"]+)"')
                [pscustomobject]@{ ts = $(if ($match.Success) { $match.Groups[1].Value } else { '' }); line = $line }
            }
        })
        return @($items | Sort-Object -Stable -Property @{ Expression = { $_.ts }; Ascending = $true } | ForEach-Object { $_.line })
    }
    function Read-Rows([string]$SessionName, [string]$Root = $root) {
        return @(Read-Lines $SessionName $Root | ForEach-Object { $_ | ConvertFrom-Json })
    }
    function Test-NotReminded($Row) {
        return ($null -eq $Row.PSObject.Properties['reminded']) -or ($Row.reminded -eq $false)
    }
    Send-Event '{"session_id":"test","hook_event_name":"UserPromptSubmit","prompt":"private prompt marker"}'
    Send-Event '{"session_id":"test","hook_event_name":"PostToolUse","tool_name":"Read"}'
    Send-Event '{"session_id":"test","hook_event_name":"PostToolUse","tool_name":"Grep"}'
    Send-Event '{"session_id":"test","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}'
    Send-Event '{"session_id":"test","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"cat x > y"}}'
    $failure = '{"session_id":"test","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"bad token=abc123 Bearer xyz"},"error":"failed"}'
    Send-Event $failure
    # 同一 turn 同一 agent 的第 2 次相同失敗會注入提醒，需自 fingerprint.text 推得預期文案。
    $firstFailureRows = Read-Rows 'test'
    Send-EventExpectReminder $failure (Get-ReminderText $firstFailureRows[5].fingerprint.text 2)
    Send-Event '{"session_id":"test","hook_event_name":"Stop"}'
    Send-Event '{"session_id":"test","hook_event_name":"UserPromptSubmit","prompt":"second"}'
    $rows = Read-Rows 'test'
    if ($rows.Count -ne 9 -or $rows[3].counts.evidence -ne 3 -or $rows[4].class -ne 'other' -or $rows[6].fingerprint.repeat -ne 2 -or -not $rows[7].turn_end -or @($rows[7].fingerprints).Count -ne 1 -or $rows[8].turn -ne 2 -or $rows[8].counts.evidence -ne 0) { throw 'event sequence mismatch' }
    foreach ($row in $rows) { if ($row.v -ne 1 -or $null -ne $row.PSObject.Properties['rev']) { throw 'schema version mismatch' } }
    $text = (Read-Lines 'test') -join "`n"
    if ($text -match 'private prompt marker|token=abc123|Bearer xyz' -or $rows[6].fingerprint.text -notmatch '<redacted>') { throw 'sensitive data mismatch' }
    Send-Event '{"session_id":"negative","hook_event_name":"PostToolUse","tool_name":"PowerShell","tool_input":{"command":"Remove-Item x"}}'
    $negative = (Read-Rows 'negative')[-1]
    if ($negative.class -ne 'other' -or $negative.counts.readonly_cmd -ne 0) { throw 'mutating command classified readonly' }
    Send-Event '{"session_id":"normalize","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"echo 12345678-1234-1234-1234-123456789abc 2026-11-03T12:13:14Z 12345"},"error":"failure"}'
    $normalized = (Read-Rows 'normalize')[-1]
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
        $last = (Read-Rows 'commands')[-1]
        if ($last.class -ne $case.expected) { throw "command classification failed: $($case.command)" }
    }
    $secretEvent = @{session_id='secrets';hook_event_name='PostToolUseFailure';tool_name='Bash';tool_input=@{command='Authorization: Bearer sensitive-token Bearer another-secret'};error='2026-11-02T16:16:05 2026-11-02 16:16:05.123'} | ConvertTo-Json -Compress
    Send-Event $secretEvent
    $secret = (Read-Rows 'secrets')[-1]
    if ($secret.fingerprint.text -match 'sensitive-token|another-secret|2026-11-02' -or ([regex]::Matches($secret.fingerprint.text,'<ts>')).Count -ne 2) { throw 'authorization or timestamp redaction failed' }
    $longPath = Join-Path $root 'turn-guard\long.jsonl'
    $lines = New-Object 'System.Collections.Generic.List[string]'
    for ($i=0; $i -lt 4998; $i++) { $lines.Add('{"event":"PostToolUse","turn":1,"class":"read"}') }
    $lines.Add('{"event":"UserPromptSubmit","turn":2}')
    $lines.Add('{"event":"PostToolUse","turn":2,"class":"search"}')
    [IO.File]::WriteAllLines($longPath,$lines,(New-Object Text.UTF8Encoding($false)))
    Send-Event '{"session_id":"long","hook_event_name":"PostToolUse","tool_name":"Read"}'
    $long = (Read-Rows 'long')[-1]
    if ($long.hook_ms -ge 1000 -or $long.counts.search -ne 1 -or $long.counts.read -ne 1) { throw "long session failed: $($long.hook_ms) ms" }
    $sharedPath = Join-Path $root 'turn-guard\shared.jsonl'
    [IO.File]::WriteAllText($sharedPath,'')
    $shared = New-Object IO.FileStream($sharedPath,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
    try { Send-Event '{"session_id":"shared","hook_event_name":"PostToolUse","tool_name":"Read"}' } finally { $shared.Dispose() }
    $sharedRecord=(Read-Rows 'shared')[-1]
    if ($sharedRecord.counts.read -ne 1) { throw 'shared read failed' }
    $source=[IO.File]::ReadAllText($hook)
    $attemptFile=Join-Path $root 'read-attempts.txt'
    $failedPath=Join-Path $root 'turn-guard\readfailure.jsonl'
    $failedOriginal='{"event":"PostToolUse","turn":8,"class":"read"}' + "`n"
    [IO.File]::WriteAllText($failedPath,$failedOriginal)
    # 讀取失敗以環境變數注入：轉接器讀取 readfailure.jsonl 時一律失敗，每次在 read-attempts.txt 追加一個 x。
    $env:TURN_GUARD_TEST_READ_FAILURE = 'readfailure.jsonl|' + $attemptFile
    try { Send-Event '{"session_id":"readfailure","hook_event_name":"PostToolUse","tool_name":"Grep"}' } finally { $env:TURN_GUARD_TEST_READ_FAILURE = $null }
    $readErrors=@(Read-Rows 'errors' | Where-Object type -eq 'read_failed')
    # 讀取連續失敗三次時，本筆紀錄仍寫入（寫在本實例自己的檔）並標記 read_failed，讀不到的既有檔保持原樣。
    if ((Get-LogFiles 'readfailure').Count -ne 2) { throw 'read failure did not continue recording' }
    $failedRecord=(Read-Rows 'readfailure')[-1]
    if ([IO.File]::ReadAllText($failedPath) -cne $failedOriginal -or $failedRecord.turn -ne 0 -or $failedRecord.counts.read -ne 0 -or $failedRecord.counts.search -ne 1 -or $readErrors.Count -ne 1 -or [IO.File]::ReadAllText($attemptFile) -ne 'xxx') { throw 'read failure fallback failed' }
    if ($failedRecord.read_failed -ne $true -or $readErrors[0].session_id -ne 'readfailure' -or $readErrors[0].event -ne 'PostToolUse') { throw 'read failure fallback not marked' }
    if ($null -ne (Read-Rows 'test')[0].PSObject.Properties['read_failed']) { throw 'normal record marked read_failed' }
    $recoverPath = Join-Path $root 'turn-guard\recover.jsonl'
    [IO.File]::WriteAllLines($recoverPath, @(
        '{"event":"UserPromptSubmit","turn":1}',
        '{"event":"UserPromptSubmit","turn":2}',
        '{"event":"PostToolUseFailure","turn":2,"class":"other","fingerprint":{"hash":"abc","text":"t","repeat":1}}',
        '{"event":"PostToolUseFailure","turn":2,"class":"other","fingerprint":{"hash":"abc","text":"t","repeat":2}}',
        '{"event":"PostToolUseFailure","turn":0,"class":"other","read_failed":true,"fingerprint":{"hash":"abc","text":"t","repeat":1}}'
    ), (New-Object Text.UTF8Encoding($false)))
    Send-Event '{"session_id":"recover","hook_event_name":"Stop"}'
    $recovered = (Read-Rows 'recover')[-1]
    $recoveredFp = @($recovered.fingerprints | Where-Object hash -eq 'abc')
    if ($recovered.turn -ne 2 -or $recovered.counts.failure -ne 3 -or $recoveredFp.Count -ne 1 -or $recoveredFp[0].repeat -ne 3 -or $null -ne $recovered.PSObject.Properties['read_failed']) { throw 'read recovery did not recompute turn and repeat' }
    Send-Event ''
    Send-Event 'invalid'
    Send-Event '{"hook_event_name":"Stop"}'
    if ((Read-Rows 'errors').Count -ne 4) { throw 'invalid input mismatch' }
    foreach ($file in @((Get-LogFiles 'test') + (Get-LogFiles 'errors') | ForEach-Object FullName)) { $bytes=[IO.File]::ReadAllBytes($file); if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { throw 'unexpected BOM' } }
    # 讀取持續失敗時仍持續運作：每個事件都寫到新段並標記 read_failed，同一失敗第 2 次照常提醒；讀取恢復後合併各段重算。
    $persistOriginal = '{"event":"PostToolUse","turn":3,"class":"read"}' + "`n"
    $persistPath = Join-Path $root 'turn-guard\persistfail.jsonl'
    [IO.File]::WriteAllText($persistPath, $persistOriginal)
    $persistAttempts = Join-Path $root 'persist-attempts.txt'
    $persistFailure = '{"session_id":"persistfail","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"persist cmd"},"error":"persist failure"}'
    $env:TURN_GUARD_TEST_READ_FAILURE = 'persistfail.jsonl|' + $persistAttempts
    try {
        Send-Event $persistFailure
        Send-EventExpectReminder $persistFailure (Get-ReminderText 'Bash|persist cmd|persist failure' 2)
    } finally { $env:TURN_GUARD_TEST_READ_FAILURE = $null }
    $persistRows = @(Read-Rows 'persistfail' | Where-Object { $_.event -eq 'PostToolUseFailure' })
    if ([IO.File]::ReadAllText($persistPath) -cne $persistOriginal -or $persistRows.Count -ne 2 -or @($persistRows | Where-Object { $null -eq $_.PSObject.Properties['read_failed'] -or $_.read_failed -ne $true }).Count -ne 0 -or $persistRows[1].fingerprint.repeat -ne 2 -or $persistRows[1].reminded -ne $true) { throw 'persistent read failure stopped recording or reminding' }
    $persistErrors = @(Read-Rows 'errors' | Where-Object { $_.type -eq 'read_failed' -and $_.session_id -eq 'persistfail' })
    if ($persistErrors.Count -ne 2) { throw "persistent read failure errors mismatch: $($persistErrors.Count)" }
    Send-Event '{"session_id":"persistfail","hook_event_name":"Stop"}'
    $persistStop = (Read-Rows 'persistfail')[-1]
    if ($null -ne $persistStop.PSObject.Properties['read_failed'] -or $persistStop.counts.read -ne 1 -or $persistStop.counts.failure -ne 2 -or @($persistStop.fingerprints)[0].repeat -ne 2) { throw 'recovered read did not merge parts' }
    # 達到讀取上限（4 MiB）的 session 檔：不改動該檔，紀錄寫到新段，保護照常運作。
    $oversizePath = Join-Path $root 'turn-guard\oversize.jsonl'
    $oversizeLine = '{"event":"PostToolUse","turn":1,"class":"read","pad":"' + ('x' * 1000) + '"}'
    [IO.File]::WriteAllText($oversizePath, ((@($oversizeLine) * 4300) -join "`n") + "`n")
    $oversizeHash = (Get-FileHash -LiteralPath $oversizePath -Algorithm SHA256).Hash
    if ((Get-Item -LiteralPath $oversizePath).Length -le 4MB) { throw 'oversize fixture is not over the read limit' }
    $oversizeFailure = '{"session_id":"oversize","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"big cmd"},"error":"big failure"}'
    Send-Event $oversizeFailure
    Send-EventExpectReminder $oversizeFailure (Get-ReminderText 'Bash|big cmd|big failure' 2)
    $oversizeRows = @(Read-Rows 'oversize' | Where-Object { $_.event -eq 'PostToolUseFailure' })
    if ((Get-FileHash -LiteralPath $oversizePath -Algorithm SHA256).Hash -ne $oversizeHash -or $oversizeRows.Count -ne 2 -or $oversizeRows[1].read_failed -ne $true -or $oversizeRows[1].reminded -ne $true) { throw 'oversize session stopped recording or changed the oversize file' }
    if (@(Read-Rows 'errors' | Where-Object { $_.type -eq 'read_failed' -and $_.session_id -eq 'oversize' }).Count -ne 2) { throw 'oversize read failure not recorded' }
    # 輪替：本實例的檔加上新紀錄會超過 1 MiB 時改寫下一段，舊段不動；turn 與計數跨檔合併（含命令型 hook 時期的檔）。
    $rotatePath = Join-Path $root 'turn-guard\rotate.jsonl'
    [IO.File]::WriteAllText($rotatePath, '{"event":"UserPromptSubmit","turn":1}' + "`n" + ((@('{"event":"PostToolUse","turn":1,"class":"read"}') * 100) -join "`n") + "`n")
    $rotateHash = (Get-FileHash -LiteralPath $rotatePath -Algorithm SHA256).Hash
    $rotateCount = 2200
    $rotateEvent = '{"session_id":"rotate","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"' + ('c' * 300) + '"},"error":"' + ('e' * 300) + '"}'
    $hookMode = 'turn-guard-batch'
    try { $rotateBatch = Invoke-Hook ('[' + ((@($rotateEvent) * $rotateCount) -join ',') + ']') } finally { $hookMode = 'turn-guard' }
    if ($rotateBatch.ExitCode -ne 0 -or $rotateBatch.Stderr.Length -ne 0) { throw "rotation batch failure: exit=$($rotateBatch.ExitCode) stderr=$($rotateBatch.Stderr)" }
    $rotateOwn = @(Get-LogFiles 'rotate' | Where-Object { $_.Name -ne 'rotate.jsonl' })
    $rotateRows = @(Read-Rows 'rotate' | Where-Object { $_.event -eq 'PostToolUseFailure' })
    if ((Get-FileHash -LiteralPath $rotatePath -Algorithm SHA256).Hash -ne $rotateHash -or $rotateOwn.Count -lt 2 -or @($rotateOwn | Where-Object { $_.Length -gt 1MB }).Count -ne 0) { throw "rotation did not split the own log: $(@($rotateOwn | ForEach-Object { $_.Name + '=' + $_.Length }) -join ', ')" }
    $rotateLast = $rotateRows[-1]
    if ($rotateRows.Count -ne $rotateCount -or $rotateLast.turn -ne 1 -or $rotateLast.counts.read -ne 100 -or $rotateLast.counts.failure -ne $rotateCount -or $rotateLast.fingerprint.repeat -ne $rotateCount -or @($rotateRows | Where-Object { $null -ne $_.PSObject.Properties['reminded'] -and $_.reminded -eq $true }).Count -ne 1) { throw 'rotation lost records or counts across files' }
    Write-Host "Rotation: $rotateCount records in $($rotateOwn.Count) own parts"
    # errors.jsonl 達到讀取上限：錯誤紀錄寫在本實例自己的 errors.<實例>.jsonl，不讀也不改動既有的 errors.jsonl。
    $errorRoot = Join-Path $root 'error-limit'
    New-Item -ItemType Directory -Path (Join-Path $errorRoot 'turn-guard') -Force | Out-Null
    $bigErrors = Join-Path $errorRoot 'turn-guard\errors.jsonl'
    $bigErrorLine = '{"type":"hook_error","message":"' + ('z' * 1000) + '"}'
    [IO.File]::WriteAllText($bigErrors, ((@($bigErrorLine) * 4300) -join "`n") + "`n")
    $bigErrorsHash = (Get-FileHash -LiteralPath $bigErrors -Algorithm SHA256).Hash
    $env:CLAUDE_PLUGIN_DATA = $errorRoot
    try { Send-Event 'invalid' } finally { $env:CLAUDE_PLUGIN_DATA = $root }
    $newErrors = @(Get-LogFiles 'errors' $errorRoot | Where-Object { $_.Name -ne 'errors.jsonl' })
    if ((Get-FileHash -LiteralPath $bigErrors -Algorithm SHA256).Hash -ne $bigErrorsHash -or $newErrors.Count -ne 1 -or (Get-Content -LiteralPath $newErrors[0].FullName | ConvertFrom-Json).type -ne 'stdin_invalid') { throw 'errors log over the read limit stopped recording' }
    # 重複失敗提醒：第 1 次無輸出，第 2 次提醒一次，第 3 次以後不重複提醒。
    $remindFailure = '{"session_id":"remind","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"reminder cmd"},"error":"reminder failure"}'
    Send-Event '{"session_id":"remind","hook_event_name":"UserPromptSubmit","prompt":"p"}'
    Send-Event $remindFailure
    $remindText = (Read-Rows 'remind')[1].fingerprint.text
    if ($remindText -ne 'Bash|reminder cmd|reminder failure') { throw "unexpected fingerprint text: $remindText" }
    Send-EventExpectReminder $remindFailure (Get-ReminderText $remindText 2)
    Send-Event $remindFailure
    $remindRows = Read-Rows 'remind'
    if ($remindRows.Count -ne 4 -or $remindRows[1].fingerprint.repeat -ne 1 -or -not (Test-NotReminded $remindRows[1])) { throw 'first failure must not remind' }
    if ($remindRows[2].fingerprint.repeat -ne 2 -or $remindRows[2].reminded -ne $true -or $remindRows[2].fingerprint.text -ne $remindText) { throw 'second failure must be marked reminded' }
    if ($remindRows[3].fingerprint.repeat -ne 3 -or -not (Test-NotReminded $remindRows[3])) { throw 'third failure must not remind again' }
    # 不同指紋各自計數，其他事件在任何情況下 stdout 皆為空（Send-Event 斷言 stdout 為空）。
    $otherFailure = '{"session_id":"remind","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"other cmd"},"error":"other failure"}'
    Send-Event $otherFailure
    Send-Event '{"session_id":"remind","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"reminder cmd"}}'
    Send-Event '{"session_id":"remind","hook_event_name":"Stop"}'
    $remindRows = Read-Rows 'remind'
    if ($remindRows[4].fingerprint.repeat -ne 1 -or -not (Test-NotReminded $remindRows[4])) { throw 'different fingerprint must count separately' }
    $remindStop = $remindRows[6]
    if (-not $remindStop.turn_end -or @($remindStop.fingerprints).Count -ne 2 -or ($remindStop.fingerprints | Where-Object text -eq $remindText).repeat -ne 3) { throw 'stop summary mismatch' }
    foreach ($row in @($remindRows[0], $remindRows[5], $remindRows[6])) { if (-not (Test-NotReminded $row)) { throw "non-failure event marked reminded: $($row.event)" } }
    # 新 turn 後相同指紋重新從 1 起算。
    Send-Event '{"session_id":"remind","hook_event_name":"UserPromptSubmit","prompt":"next"}'
    Send-Event $remindFailure
    $remindRows = Read-Rows 'remind'
    if ($remindRows[-1].turn -ne 2 -or $remindRows[-1].fingerprint.repeat -ne 1 -or -not (Test-NotReminded $remindRows[-1])) { throw 'new turn must restart fingerprint count' }
    # 非 ASCII 指紋文字（含 surrogate pair）以 \uXXXX 跳脫輸出，解析後內容與紀錄一致。
    $cjkFailure = '{"session_id":"remindcjk","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"測試 😀 cmd"},"error":"失敗 failure"}'
    Send-Event '{"session_id":"remindcjk","hook_event_name":"UserPromptSubmit","prompt":"p"}'
    Send-Event $cjkFailure
    $cjkText = (Read-Rows 'remindcjk')[1].fingerprint.text
    if ($cjkText -notmatch '測試' -or $cjkText -notmatch '失敗') { throw "unexpected cjk fingerprint text: $cjkText" }
    Send-EventExpectReminder $cjkFailure (Get-ReminderText $cjkText 2)
    # 指紋計數以 turn 加 agent_id 分開：subagent 的失敗不讓主 Session 收到提醒，提醒只注入觸發它的 agent。
    $mainFailure = '{"session_id":"agents","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"agent cmd"},"error":"agent failure"}'
    $subFailure = '{"session_id":"agents","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"agent cmd"},"error":"agent failure","agent_id":"sub-a"}'
    $subBFailure = '{"session_id":"agents","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"agent cmd"},"error":"agent failure","agent_id":"sub-b"}'
    Send-Event '{"session_id":"agents","hook_event_name":"UserPromptSubmit","prompt":"p"}'
    Send-Event $mainFailure
    Send-Event $subFailure
    Send-Event $subBFailure
    $agentRows = Read-Rows 'agents'
    if ($agentRows[1].fingerprint.repeat -ne 1 -or $agentRows[2].fingerprint.repeat -ne 1 -or $agentRows[3].fingerprint.repeat -ne 1) { throw 'agent fingerprint counts must start separately' }
    $agentText = $agentRows[1].fingerprint.text
    Send-EventExpectReminder $subFailure (Get-ReminderText $agentText 2)
    $agentRows = Read-Rows 'agents'
    if ($agentRows[4].agent_id -ne 'sub-a' -or $agentRows[4].fingerprint.repeat -ne 2 -or $agentRows[4].reminded -ne $true) { throw 'subagent second failure must remind sub-a' }
    if ($null -ne $agentRows[1].agent_id -or $agentRows[1].fingerprint.repeat -ne 1) { throw 'main session count changed by subagent failures' }
    Send-EventExpectReminder $mainFailure (Get-ReminderText $agentText 2)
    Send-Event '{"session_id":"agents","hook_event_name":"Stop"}'
    $agentStop = (Read-Rows 'agents')[-1]
    if (@($agentStop.fingerprints).Count -ne 1 -or @($agentStop.fingerprints)[0].repeat -ne 2) { throw 'stop summary must list main session fingerprints only' }
    # 提醒條件只依指紋次數，唯讀取證計數（evidence）不參與輸出判定。
    if ($source -match '唯讀取證') { throw 'hook source must not contain read-evidence reminder' }
    foreach ($sourceLine in ($source -split '\r?\n')) { if ($sourceLine -match 'reminded|reminder' -and $sourceLine -match 'evidence') { throw "reminder condition references evidence: $sourceLine" } }
    # 並行壓力：同一 session 的多個事件在同一行程內同時送出，檔案不得斷行，指紋次數不得少算。
    # 函式型 hook 在引擎行程內執行，同一 session 的事件都經過同一個行程。
    $workerCount = 8; $perWorker = 5
    $stressSession = 'stress'
    Send-Event ('{"session_id":"' + $stressSession + '","hook_event_name":"UserPromptSubmit","prompt":"p"}')
    $stressEvent = '{"session_id":"stress","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"stress cmd"},"error":"stress failure"}'
    $hookMode = 'turn-guard-batch'
    try { $batch = Invoke-Hook ('[' + ((@($stressEvent) * ($workerCount * $perWorker)) -join ',') + ']') } finally { $hookMode = 'turn-guard' }
    if ($batch.ExitCode -ne 0 -or $batch.Stderr.Length -ne 0) { throw "stress batch failure: exit=$($batch.ExitCode) stderr=$($batch.Stderr)" }
    $stressReminderLines = @([Text.Encoding]::ASCII.GetString($batch.Stdout) -split '\r?\n' | Where-Object { $_ -ne '' })
    foreach ($line in $stressReminderLines) { if ($line -notmatch '^\{"hookSpecificOutput":\{"hookEventName":"PostToolUseFailure","additionalContext":".*"\}\}$') { throw "stress unexpected output=$line" } }
    $stressLines = Read-Lines 'stress'
    $expectedTotal = 1 + $workerCount * $perWorker
    if ($stressLines.Count -ne $expectedTotal) { throw "stress line count mismatch: $($stressLines.Count) vs $expectedTotal" }
    $stressRows = @(foreach ($line in $stressLines) { try { $line | ConvertFrom-Json } catch { throw "stress line is not valid json: $line" } })
    $stressFailures = @($stressRows | Where-Object { $_.event -eq 'PostToolUseFailure' })
    $repeats = @($stressFailures | ForEach-Object { [int]$_.fingerprint.repeat } | Sort-Object)
    $expectedRepeats = @(1..($workerCount * $perWorker))
    if ($stressFailures.Count -ne $workerCount * $perWorker -or $repeats.Count -ne $expectedRepeats.Count -or (Compare-Object $repeats $expectedRepeats)) { throw "stress repeat set mismatch: $($repeats -join ',')" }
    if (@($stressRows | Where-Object { $_.turn -ne 1 }).Count -ne 0) { throw 'stress turn mismatch' }
    # 並行情境下同指紋只在第 2 次提醒一次，紀錄的 reminded 與 worker 收到的 stdout 各只有一筆。
    $stressReminded = @($stressFailures | Where-Object { $null -ne $_.PSObject.Properties['reminded'] -and $_.reminded -eq $true })
    if ($stressReminded.Count -ne 1 -or $stressReminded[0].fingerprint.repeat -ne 2) { throw 'stress reminder record mismatch' }
    if ($stressReminderLines.Count -ne 1) { throw "stress reminder output count mismatch: $($stressReminderLines.Count)" }
    $stressReminder = $stressReminderLines[0] | ConvertFrom-Json
    if ($stressReminder.hookSpecificOutput.hookEventName -ne 'PostToolUseFailure' -or $stressReminder.hookSpecificOutput.additionalContext -cne (Get-ReminderText $stressReminded[0].fingerprint.text 2)) { throw 'stress reminder content mismatch' }
    # 多行程同時寫同一 session：8 個行程並行，每個事件由一個新的 node 行程（各自一個模組實例）處理。
    # 驗證的範圍是「各實例只寫自己的檔，同時寫入時任何一筆紀錄都不遺失」；並未讓兩個持續存活的實例並行處理同一 session，
    # 存活實例的記憶體路徑由同一行程的 batch 案例與 register.test.ts 涵蓋。並行時彼此看不到對方尚未寫入的紀錄，提醒次數不在此斷言。
    $procSession = 'stressproc'
    Send-Event ('{"session_id":"' + $procSession + '","hook_event_name":"UserPromptSubmit","prompt":"p"}')
    $procWorker = Join-Path $root 'stress-worker.ps1'
    [IO.File]::WriteAllText($procWorker, @'
param([string]$RunHook, [int]$Count, [string]$Id, [string]$ErrorFile)
$json = '{"session_id":"stressproc","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"stress cmd ' + $Id + '"},"error":"stress failure"}'
for ($i = 0; $i -lt $Count; $i++) {
    $output = $json | & node --no-warnings $RunHook turn-guard 2>&1
    if ($LASTEXITCODE -ne 0) { [IO.File]::AppendAllText($ErrorFile, "worker $Id exit=$LASTEXITCODE output=$output`n"); continue }
    $text = (@($output) -join "`n")
    if ($text -ne '' -and $text -notmatch '^\{"hookSpecificOutput":\{"hookEventName":"PostToolUseFailure","additionalContext":".*"\}\}$') { [IO.File]::AppendAllText($ErrorFile, "worker $Id unexpected output=$text`n") }
}
'@, (New-Object Text.UTF8Encoding($true)))
    $procErrors = Join-Path $root 'stress-proc-errors.txt'
    $procWorkers = @()
    try {
        for ($w = 0; $w -lt $workerCount; $w++) {
            $procWorkers += Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"' + $procWorker + '"'),'-RunHook',('"' + $runHook + '"'),'-Count',$perWorker,'-Id',$w,'-ErrorFile',('"' + $procErrors + '"'))
        }
        foreach ($worker in $procWorkers) { if (-not $worker.WaitForExit(180000)) { throw 'stress worker timeout' } }
    } finally {
        foreach ($worker in $procWorkers) { if (-not $worker.HasExited) { & taskkill.exe /T /F /PID $worker.Id 2>&1 | Out-Null; try { [void]$worker.WaitForExit(10000) } catch { } } }
    }
    if (Test-Path -LiteralPath $procErrors) { throw ('stress worker failure: ' + [IO.File]::ReadAllText($procErrors)) }
    $procLines = Read-Lines $procSession
    $procRows = @(foreach ($line in $procLines) { try { $line | ConvertFrom-Json } catch { throw "stress line is not valid json: $line" } })
    $procFiles = Get-LogFiles $procSession
    if ($procRows.Count -ne 1 + $workerCount * $perWorker -or @($procRows | Where-Object { $_.event -eq 'PostToolUseFailure' }).Count -ne $workerCount * $perWorker) { throw "cross-process stress lost records: $($procRows.Count) in $($procFiles.Count) files" }
    $procReminded = @($procRows | Where-Object { $null -ne $_.PSObject.Properties['reminded'] -and $_.reminded -eq $true }).Count
    Write-Host "Multi-process writers (one new process per event): $($procRows.Count) records in $($procFiles.Count) files, $procReminded reminded"
    # 遺留的鎖檔：命令型 hook 留下的 .lock 檔被他人持有時，進程內版本不使用它，照常寫入且不產生 lock_timeout。
    $lockSession = 'locktimeout'
    $lockSessionPath = Join-Path $root 'turn-guard\locktimeout.jsonl'
    [IO.File]::WriteAllText($lockSessionPath, '{"event":"PostToolUse","turn":1,"class":"read"}' + "`n")
    $errorsBefore = (Read-Rows 'errors').Count
    $held = New-Object IO.FileStream((Join-Path $root 'turn-guard\locktimeout.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $lockTimer = [Diagnostics.Stopwatch]::StartNew()
    try { Send-Event ('{"session_id":"' + $lockSession + '","hook_event_name":"PostToolUse","tool_name":"Read"}') } finally { $held.Dispose() }
    $lockTimer.Stop()
    if ($lockTimer.ElapsedMilliseconds -ge 10000) { throw "stale lock wait took too long: $($lockTimer.ElapsedMilliseconds) ms" }
    if ((Read-Lines $lockSession).Count -ne 2) { throw 'session record not written beside a stale lock file' }
    $errorRows = Read-Rows 'errors'
    $timeoutRows = @($errorRows | Select-Object -Skip $errorsBefore)
    if ($timeoutRows.Count -ne 0) { throw 'stale lock file produced an error record' }
    Write-Host "Stale lock elapsed: $($lockTimer.ElapsedMilliseconds) ms"
    $env:CLAUDE_PLUGIN_DATA = $null
    $cwd=Join-Path $root 'cwd'; New-Item -ItemType Directory -Path $cwd | Out-Null
    $before=@(Get-ChildItem -LiteralPath $root -Recurse -Force | ForEach-Object FullName | Sort-Object)
    Push-Location $cwd
    try { Send-Event '{"session_id":"disabled","hook_event_name":"Stop"}' } finally { Pop-Location }
    $after=@(Get-ChildItem -LiteralPath $root -Recurse -Force | ForEach-Object FullName | Sort-Object)
    if (Compare-Object $before $after) { throw 'unset data created files in temp or current directory' }
    Write-Host "Long session hook_ms: $($long.hook_ms)"
    Write-Host 'Turn guard tests passed.'
} finally {
    $env:CLAUDE_PLUGIN_DATA = $previous
    try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop } catch { Write-Warning "temp cleanup failed: $root" }
}
exit 0
