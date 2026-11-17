#Requires -Version 7.0
# 事件流判讀、用量與結果判定。結果只依四項：結束碼、最後訊息、報告檔、服務端拒絕種類。依賴 00-common.ps1。

function Get-RunLocalFailurePattern {
    # 本地失敗詞彙：命中者視為本機執行失敗，不屬服務端拒絕，不觸發未分類換帳號。
    return '(?i)\bsandbox\b|\bcommand\s+(?:failed|exited|not\s+found)\b|\bexit(?:ed)?\s+(?:with\s+)?(?:code|status)\b|\bapply_patch\b|\bpatch\s+failed\b|\btool\s+(?:call|execution)\b|\bcodex_core::tools\b|\bENOENT\b|\bEACCES\b|\bEPERM\b|no\s+such\s+file|cannot\s+find\s+(?:the\s+)?(?:path|file)|used\s+by\s+another\s+process|\bfailed\s+to\s+(?:start|launch|spawn)\b|\bspawn\b|\bfailed\s+to\s+load\s+\S+\s+instructions\b'
}

function Get-RunTerminalFailureEventType {
    return [string[]]@('turn.failed', 'turn_failed', 'stream_error', 'turn_aborted')
}

function Get-RunAccountRejectionKind {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $null }
    if ($Text -match '(?i)\b401\b|\bunauthori[sz]ed\b') { return 'unauthorized' }
    if ($Text -match '(?i)\bmodel\b[^\r\n]{0,120}\bis\s+not\s+supported\b') { return 'model-not-supported' }
    return $null
}

function Test-RunErrorStreamErrorLine {
    param([AllowNull()][AllowEmptyString()][string]$Line)

    # Codex stderr 的錯誤行為「<ISO 8601 時間> ERROR <target>: <訊息>」或「ERROR: <訊息>」。
    # target 為 codex_core::tools:: 的錯誤是工具執行失敗，訊息會回顯被執行的命令列，不代表服務端拒絕。
    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }
    $tracing = [regex]::Match($Line, '^\s*\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?\s+ERROR\s+(?<target>[A-Za-z0-9_]+(?:::[A-Za-z0-9_]+)*):\s')
    if ($tracing.Success) {
        return -not $tracing.Groups['target'].Value.StartsWith('codex_core::tools::', [StringComparison]::Ordinal)
    }
    return [regex]::IsMatch($Line, '^\s*ERROR:\s')
}

function Get-RunErrorStreamLineMessage {
    param([AllowNull()][AllowEmptyString()][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return '' }
    $tracing = [regex]::Match($Line, '^\s*\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?\s+ERROR\s+[A-Za-z0-9_]+(?:::[A-Za-z0-9_]+)*:\s(?<message>.*)$')
    if ($tracing.Success) { return $tracing.Groups['message'].Value.Trim() }
    $plain = [regex]::Match($Line, '^\s*ERROR:\s(?<message>.*)$')
    if ($plain.Success) { return $plain.Groups['message'].Value.Trim() }
    return $Line.Trim()
}

function Get-RunEventMessageText {
    param([AllowNull()][object]$EventObject)

    $payload = Get-RunJsonProperty -Object $EventObject -Name 'payload'
    if ($null -eq $payload) { $payload = Get-RunJsonProperty -Object $EventObject -Name 'data' }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($source in @($EventObject, $payload)) {
        foreach ($name in @('message', 'reason', 'code')) {
            $value = Get-RunJsonProperty -Object $source -Name $name
            if ($null -ne $value) { $parts.Add([string]$value) }
        }
        $errorObject = Get-RunJsonProperty -Object $source -Name 'error'
        if ($errorObject -is [string]) {
            $parts.Add($errorObject)
        }
        elseif ($null -ne $errorObject) {
            foreach ($name in @('message', 'reason', 'code', 'type')) {
                $value = Get-RunJsonProperty -Object $errorObject -Name $name
                if ($null -ne $value) { $parts.Add([string]$value) }
            }
        }
    }
    return (($parts.ToArray()) -join ' ').Trim()
}

function Test-RunMessageExcluded {
    param([AllowNull()][AllowEmptyString()][string]$Message)

    # 暫時性重連訊息與 model metadata 警告不是終局失敗原因。
    if ([string]::IsNullOrWhiteSpace($Message)) { return $true }
    if ($Message -match '(?i)^\s*Reconnecting\b') { return $true }
    if ($Message -match '(?i)^\s*Model\s+metadata\b[^\r\n]*\bnot\s+found\b') { return $true }
    return $false
}

function ConvertTo-RunUsageNumber {
    param([AllowNull()][object]$Value)

    # 非負數值回傳 [long]，其餘（缺少、null、字串、布林、巢狀物件、負數）回傳 $null。
    $numericTypes = @([byte], [sbyte], [int16], [uint16], [int], [uint32], [long], [uint64], [single], [double], [decimal])
    if ($null -eq $Value -or $Value -is [bool] -or $Value.GetType() -notin $numericTypes -or [double]$Value -lt 0) { return $null }
    return [long]$Value
}

function Test-RunUsageObject {
    param([AllowNull()][object]$Value)

    # 只要求 input_tokens 與 output_tokens 為非負數值。其餘欄位（含上游日後新增的欄位）不影響判定，個別讀取時無效者記為 $null。
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) { return $false }
    foreach ($required in @('input_tokens', 'output_tokens')) {
        if ($null -eq (ConvertTo-RunUsageNumber -Value (Get-RunJsonProperty -Object $Value -Name $required))) { return $false }
    }
    return $true
}

function Test-RunUsageLimitText {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    return [regex]::IsMatch([string]$Text, '(?i)usage[\s_-]*limit(?:ed|[\s_-]*(?:reached|exceeded)|\b)')
}

function Get-RunUsageLimitReset {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    # 服務端的 usage limit 訊息以「try again at Nov 22nd, 2026 5:21 PM」給重設時間，沒有時區，視為執行機器的本地時間。
    # 只接受英文月名、有無序數後綴與逗號、12 小時制；其他寫法或不存在的日期回傳 $null，不猜測。
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $months = 'Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?'
    $match = [regex]::Match($Text, '(?i)\btry\s+again\s+at\s+(?<raw>(?<mon>' + $months + ')\.?\s+(?<day>\d{1,2})(?:st|nd|rd|th)?,?\s+(?<year>\d{4}),?\s+(?<hour>\d{1,2}):(?<minute>\d{2})\s*(?<ampm>[AP]M))\b')
    if (-not $match.Success) { return $null }
    $monthNumber = 1 + [array]::IndexOf(@('jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'), $match.Groups['mon'].Value.Substring(0, 3).ToLowerInvariant())
    $hour = [int]$match.Groups['hour'].Value
    if ($hour -lt 1 -or $hour -gt 12) { return $null }
    $hour = $hour % 12
    if ($match.Groups['ampm'].Value -imatch '^P') { $hour += 12 }
    try {
        $local = [DateTime]::new([int]$match.Groups['year'].Value, $monthNumber, [int]$match.Groups['day'].Value, $hour, [int]$match.Groups['minute'].Value, 0, [DateTimeKind]::Local)
    }
    catch { return $null }
    return [pscustomobject]@{ raw = $match.Groups['raw'].Value; local = $local.ToString('yyyy-MM-ddTHH:mm:sszzz', [Globalization.CultureInfo]::InvariantCulture) }
}

function Test-RunRateLimitText {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    # 暫時性重連訊息（Reconnecting...）不算。
    if ([regex]::IsMatch([string]$Text, '(?i)^\s*Reconnecting\b')) { return $false }
    return [regex]::IsMatch([string]$Text, '(?i)rate[\s_-]*limit(?:ed|[\s_-]*(?:reached|exceeded)|\b)|quota[\s_-]+exceeded|too[\s_-]+many[\s_-]+requests|\b429\b')
}

function Get-RunEventEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EventStreamPath,

        [string]$StderrPath,

        [Nullable[int]]$ExitCode = $null
    )

    # 回傳 rejection_kind、item_event_count、completed、usage，另附 last_event_type、unparsable_line_count 與 message_excerpt 供診斷。
    $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
    $lines = @()
    if ([IO.File]::Exists($EventStreamPath)) {
        $lines = @($utf8.GetString([IO.File]::ReadAllBytes($EventStreamPath)) -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $events = New-Object 'System.Collections.Generic.List[object]'
    $unparsable = 0
    foreach ($line in $lines) {
        try {
            $parsed = ConvertFrom-Json -InputObject $line -Depth 20
            if ($parsed -isnot [pscustomobject]) { throw 'not an object' }
            $events.Add($parsed)
        }
        catch { $unparsable++ }
    }

    $itemCount = 0
    $usageLimit = $false
    $limitReset = $null
    $nonTransientRateLimit = $false
    $accountKinds = New-Object 'System.Collections.Generic.List[string]'
    $lastUsage = $null
    $validUsageCount = 0
    $turnCompletedCount = 0
    $errorEventTypes = @('error', 'turn.failed', 'turn_failed', 'stream_error', 'turn_aborted')
    foreach ($event in $events) {
        $type = [string](Get-RunJsonProperty -Object $event -Name 'type')
        if ($type -ceq 'item.started' -or $type -ceq 'item.completed') {
            # item.type 為 error 的項目是警告（例如 Model metadata not found），不是實際工作項目；缺 item 物件的事件不計。
            $item = Get-RunJsonProperty -Object $event -Name 'item'
            if ($null -ne $item -and $item -is [pscustomobject] -and [string](Get-RunJsonProperty -Object $item -Name 'type') -cne 'error') { $itemCount++ }
        }
        if ($type -ceq 'turn.completed') {
            $turnCompletedCount++
            $usage = Get-RunJsonProperty -Object $event -Name 'usage'
            if (Test-RunUsageObject -Value $usage) { $validUsageCount++; $lastUsage = $usage }
        }
        $payload = Get-RunJsonProperty -Object $event -Name 'payload'
        if ($null -eq $payload) { $payload = Get-RunJsonProperty -Object $event -Name 'data' }
        $payloadType = [string](Get-RunJsonProperty -Object $payload -Name 'type')
        if ($errorEventTypes -cnotcontains $type -and $errorEventTypes -cnotcontains $payloadType) { continue }
        $messageText = Get-RunEventMessageText -EventObject $event
        $accountKind = Get-RunAccountRejectionKind -Text $messageText
        if ($null -ne $accountKind) { $accountKinds.Add($accountKind) }
        if (Test-RunUsageLimitText -Text $messageText) { $usageLimit = $true; if ($null -eq $limitReset) { $limitReset = Get-RunUsageLimitReset -Text $messageText } }
        elseif (Test-RunRateLimitText -Text $messageText) { $nonTransientRateLimit = $true }
    }
    $lastType = if ($events.Count -gt 0) { [string](Get-RunJsonProperty -Object $events[$events.Count - 1] -Name 'type') } else { $null }
    $completed = $lastType -ceq 'turn.completed'

    # stderr 的 ERROR 行：只取 Codex 錯誤行，工具失敗行排除。
    $stderrLines = @()
    if (-not [string]::IsNullOrWhiteSpace($StderrPath) -and [IO.File]::Exists($StderrPath)) {
        $stderrLines = @($utf8.GetString([IO.File]::ReadAllBytes($StderrPath)) -split '\r?\n' | Where-Object { Test-RunErrorStreamErrorLine -Line $_ })
        foreach ($errorLine in $stderrLines) {
            $accountKind = Get-RunAccountRejectionKind -Text $errorLine
            if ($null -ne $accountKind) { $accountKinds.Add($accountKind) }
            # 只出現在 stderr 的 usage limit 與 rate limit 同樣要被分類。
            $lineMessage = Get-RunErrorStreamLineMessage -Line $errorLine
            if (Test-RunUsageLimitText -Text $lineMessage) { $usageLimit = $true; if ($null -eq $limitReset) { $limitReset = Get-RunUsageLimitReset -Text $lineMessage } }
            elseif (Test-RunRateLimitText -Text $lineMessage) { $nonTransientRateLimit = $true }
        }
    }

    $terminalMessage = $null
    if ((Get-RunTerminalFailureEventType) -ccontains $lastType) {
        $text = Get-RunEventMessageText -EventObject $events[$events.Count - 1]
        if (-not (Test-RunMessageExcluded -Message $text)) { $terminalMessage = $text }
    }
    elseif (-not $completed -and $null -ne $ExitCode -and [int]$ExitCode -ne 0) {
        foreach ($errorLine in $stderrLines) {
            $text = Get-RunErrorStreamLineMessage -Line $errorLine
            if (-not (Test-RunMessageExcluded -Message $text)) { $terminalMessage = $errorLine }
        }
    }

    $kind = $null
    if ($usageLimit) { $kind = 'usage-limit' }
    elseif ($accountKinds -contains 'unauthorized') { $kind = 'unauthorized' }
    elseif ($accountKinds.Count -gt 0) { $kind = $accountKinds[0] }
    elseif ($nonTransientRateLimit -and -not $completed) { $kind = 'rate-limited' }
    elseif ($itemCount -eq 0 -and $null -ne $terminalMessage -and -not [regex]::IsMatch($terminalMessage, (Get-RunLocalFailurePattern))) { $kind = 'unclassified' }
    # 以 turn.completed 結束的執行不是被拒絕（例如 stderr 中暫時性重連的 401 行）。
    if ($completed) { $kind = $null }
    if ($kind -cne 'usage-limit') { $limitReset = $null }

    $usageStatus = if ($validUsageCount -gt 0) { 'recorded' } elseif ($turnCompletedCount -gt 0) { 'no-usage-field' } else { 'no-terminal-event' }
    $usageResult = [ordered]@{
        status = $usageStatus
        input_tokens = $null
        cached_input_tokens = $null
        output_tokens = $null
        reasoning_output_tokens = $null
    }
    if ($usageStatus -ceq 'recorded') {
        # turn.completed.usage 是 thread 的累計值，取最後一筆有效者，不逐筆加總。
        foreach ($field in @('input_tokens', 'cached_input_tokens', 'output_tokens', 'reasoning_output_tokens')) {
            $usageResult[$field] = ConvertTo-RunUsageNumber -Value (Get-RunJsonProperty -Object $lastUsage -Name $field)
        }
    }
    $excerpt = if ($null -eq $terminalMessage) { '' } else { $terminalMessage.Substring(0, [Math]::Min(300, $terminalMessage.Length)) }
    return [pscustomobject]@{
        rejection_kind = $kind
        limit_reset_raw = if ($null -ne $limitReset) { $limitReset.raw } else { $null }
        limit_reset_local = if ($null -ne $limitReset) { $limitReset.local } else { $null }
        item_event_count = $itemCount
        completed = $completed
        usage = [pscustomobject]$usageResult
        last_event_type = $lastType
        unparsable_line_count = $unparsable
        message_excerpt = $excerpt
    }
}

function Test-RunFailoverEligible {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Evidence
    )

    # 服務端拒絕且尚無任何工作項目進度時才換下一個帳號。
    if ($null -eq $Evidence) { return $false }
    if ([string]::IsNullOrWhiteSpace([string](Get-RunJsonProperty -Object $Evidence -Name 'rejection_kind'))) { return $false }
    $count = Get-RunJsonProperty -Object $Evidence -Name 'item_event_count'
    return $null -ne $count -and [int]$count -eq 0
}

function Get-RunResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$ExitCode,

        [string]$LastMessagePath,

        [string]$ReportPath,

        [Parameter(Mandatory)]
        [object]$Evidence,

        # 入口因總時限終止了子行程。
        [switch]$TimedOut,

        # 事件流已是 turn.completed 且最後訊息非空，子行程在寬限內未結束而由入口終止。被終止的結束碼不代表執行失敗，不納入判定。
        [switch]$TerminatedAfterTurnEnd
    )

    $rejectionKind = [string](Get-RunJsonProperty -Object $Evidence -Name 'rejection_kind')
    if (-not [string]::IsNullOrWhiteSpace($rejectionKind)) {
        return [pscustomobject]@{ result = 'rejected'; failure_reason = $rejectionKind }
    }
    if ($TimedOut) {
        return [pscustomobject]@{ result = 'failed'; failure_reason = 'timeout' }
    }
    if ($ExitCode -ne 0 -and -not $TerminatedAfterTurnEnd) {
        return [pscustomobject]@{ result = 'failed'; failure_reason = 'nonzero-exit' }
    }
    $lastMessageExists = -not [string]::IsNullOrWhiteSpace($LastMessagePath) -and [IO.File]::Exists($LastMessagePath) -and (New-Object System.IO.FileInfo -ArgumentList @($LastMessagePath)).Length -gt 0
    if (-not $lastMessageExists) {
        return [pscustomobject]@{ result = 'failed'; failure_reason = 'no-last-message' }
    }
    if ([string]::IsNullOrWhiteSpace($ReportPath) -or -not [IO.File]::Exists($ReportPath)) {
        return [pscustomobject]@{ result = 'failed'; failure_reason = 'report-missing' }
    }
    if ((New-Object System.IO.FileInfo -ArgumentList @($ReportPath)).Length -eq 0) {
        return [pscustomobject]@{ result = 'failed'; failure_reason = 'report-empty' }
    }
    return [pscustomobject]@{ result = 'success'; failure_reason = $null }
}
