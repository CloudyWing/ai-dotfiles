#Requires -Version 7.0
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
    # 以原始位元組取得 hook 的 stdout，供斷言提醒輸出的編碼與 BOM。stdin 以無 BOM 的 UTF-8 送入。
    function Invoke-Hook([string]$Json) {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = 'pwsh'
        $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $hook + '"'
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
    function Read-Rows([string]$SessionName) {
        return @(Get-Content -LiteralPath (Join-Path $root ('turn-guard\' + $SessionName + '.jsonl')) -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
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
    $firstFailureRows = @(Get-Content -LiteralPath (Join-Path $root 'turn-guard\test.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Send-EventExpectReminder $failure (Get-ReminderText $firstFailureRows[5].fingerprint.text 2)
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
    foreach ($sourceLine in ($source -split '\r?\n')) { if ($sourceLine -match 'reminded|\$reminder' -and $sourceLine -match 'evidence') { throw "reminder condition references evidence: $sourceLine" } }
    # 並行壓力：同一 session 由多個行程同時寫入，檔案不得斷行，指紋次數不得少算。
    $workerCount = 8; $perWorker = 5
    $stressSession = 'stress'
    $stressPath = Join-Path $root 'turn-guard\stress.jsonl'
    Send-Event ('{"session_id":"' + $stressSession + '","hook_event_name":"UserPromptSubmit","prompt":"p"}')
    $workerScript = Join-Path $root 'stress-worker.ps1'
    [IO.File]::WriteAllText($workerScript, @'
param([string]$Hook, [int]$Count, [string]$Id, [string]$ErrorFile, [string]$ReminderFile)
$json = '{"session_id":"stress","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"stress cmd"},"error":"stress failure"}'
for ($i = 0; $i -lt $Count; $i++) {
    $output = $json | & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Hook 2>&1
    if ($LASTEXITCODE -ne 0) { [IO.File]::AppendAllText($ErrorFile, "worker $Id exit=$LASTEXITCODE output=$output`n"); continue }
    if (@($output).Count -eq 0) { continue }
    # 同指紋第 2 次會輸出提醒，其餘 stdout 非空一律視為失敗；提醒內容由測試主體驗證。
    $text = (@($output) -join "`n")
    if (@($output).Count -eq 1 -and $text -match '^\{"hookSpecificOutput":\{"hookEventName":"PostToolUseFailure","additionalContext":".*"\}\}$') { [IO.File]::AppendAllText($ReminderFile, $text + "`n") }
    else { [IO.File]::AppendAllText($ErrorFile, "worker $Id unexpected output=$text`n") }
}
'@, (New-Object Text.UTF8Encoding($true)))
    $workerErrors = Join-Path $root 'stress-worker-errors.txt'
    $workerReminders = Join-Path $root 'stress-worker-reminders.txt'
    $workers = @()
    try {
        for ($w = 0; $w -lt $workerCount; $w++) {
            $workers += Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"' + $workerScript + '"'),'-Hook',('"' + $hook + '"'),'-Count',$perWorker,'-Id',$w,'-ErrorFile',('"' + $workerErrors + '"'),'-ReminderFile',('"' + $workerReminders + '"'))
        }
        foreach ($worker in $workers) { if (-not $worker.WaitForExit(120000)) { throw 'stress worker timeout' } }
    } finally {
        foreach ($worker in $workers) { if (-not $worker.HasExited) { & taskkill.exe /T /F /PID $worker.Id 2>&1 | Out-Null; try { [void]$worker.WaitForExit(10000) } catch { } } }
    }
    if (Test-Path -LiteralPath $workerErrors) { throw ('stress worker failure: ' + [IO.File]::ReadAllText($workerErrors)) }
    $stressLines = @(Get-Content -LiteralPath $stressPath)
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
    if (-not (Test-Path -LiteralPath $workerReminders)) { throw 'stress reminder output missing' }
    $stressReminderLines = @(Get-Content -LiteralPath $workerReminders | Where-Object { $_ -ne '' })
    if ($stressReminderLines.Count -ne 1) { throw "stress reminder output count mismatch: $($stressReminderLines.Count)" }
    $stressReminder = $stressReminderLines[0] | ConvertFrom-Json
    if ($stressReminder.hookSpecificOutput.hookEventName -ne 'PostToolUseFailure' -or $stressReminder.hookSpecificOutput.additionalContext -cne (Get-ReminderText $stressReminded[0].fingerprint.text 2)) { throw 'stress reminder content mismatch' }
    # 取鎖逾時：鎖被他人持有時，hook 不寫 session 紀錄，只在 errors.jsonl 留下 lock_timeout。
    $lockSession = 'locktimeout'
    $lockSessionPath = Join-Path $root 'turn-guard\locktimeout.jsonl'
    [IO.File]::WriteAllText($lockSessionPath, '{"event":"PostToolUse","turn":1,"class":"read"}' + "`n")
    $errorsPath = Join-Path $root 'turn-guard\errors.jsonl'
    $errorsBefore = @(Get-Content -LiteralPath $errorsPath).Count
    $held = New-Object IO.FileStream((Join-Path $root 'turn-guard\locktimeout.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $lockTimer = [Diagnostics.Stopwatch]::StartNew()
    try { Send-Event ('{"session_id":"' + $lockSession + '","hook_event_name":"PostToolUse","tool_name":"Read"}') } finally { $held.Dispose() }
    $lockTimer.Stop()
    if ($lockTimer.ElapsedMilliseconds -ge 10000) { throw "lock timeout took too long: $($lockTimer.ElapsedMilliseconds) ms" }
    if (@(Get-Content -LiteralPath $lockSessionPath).Count -ne 1) { throw 'session record written without lock' }
    $errorRows = @(Get-Content -LiteralPath $errorsPath | ForEach-Object { $_ | ConvertFrom-Json })
    $timeoutRows = @($errorRows | Select-Object -Skip $errorsBefore)
    if ($timeoutRows.Count -ne 1 -or $timeoutRows[0].type -ne 'lock_timeout' -or $timeoutRows[0].session_id -ne $lockSession) { throw 'lock_timeout error record missing' }
    Write-Host "Lock timeout elapsed: $($lockTimer.ElapsedMilliseconds) ms"
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
