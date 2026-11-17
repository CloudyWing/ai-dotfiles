#Requires -Version 7.0
# 一次發動的流程編排：派遣檔、啟動前檢查、MXC 偵測、逐帳號嘗試、紀錄、成本列與結果文件。
# 依賴 00 至 60 各模組，由 scripts\Invoke-CodexRun.ps1 載入。

function Write-RunDiagnostic {
    param([Parameter(Mandatory)][string]$Message)

    [Console]::Error.WriteLine($Message)
}

$script:RunEvidenceBeginPrefix = '<<<EVIDENCE-BEGIN'
$script:RunEvidenceEndMarker = '<<<EVIDENCE-END>>>'

function Get-RunEvidenceSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    # 一次讀入 evidence 檔：位元組長度、SHA-256 與解碼後的全文（去除 BOM）。內嵌與雜湊用同一份位元組，避免兩次讀取之間檔案被改。
    $bytes = [IO.File]::ReadAllBytes($Path)
    $text = (New-Object System.Text.UTF8Encoding -ArgumentList @($false)).GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return [pscustomobject]@{
        path = $Path
        bytes = [long]$bytes.Length
        sha256 = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        text = $text
    }
}

function Test-RunEvidenceInline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][object]$Evidence
    )

    # 取出 prompt 內嵌的 evidence 區段，與 evidence 檔全文逐字比對。
    $begin = $Prompt.IndexOf($script:RunEvidenceBeginPrefix, [StringComparison]::Ordinal)
    if ($begin -lt 0) { return $false }
    $lineEnd = $Prompt.IndexOf("`n", $begin, [StringComparison]::Ordinal)
    if ($lineEnd -lt 0) { return $false }
    $end = $Prompt.LastIndexOf("`n" + $script:RunEvidenceEndMarker, [StringComparison]::Ordinal)
    if ($end -lt $lineEnd) { return $false }
    $embedded = $Prompt.Substring($lineEnd + 1, $end - $lineEnd - 1)
    return $embedded -ceq [string]$Evidence.text
}

function Get-RunMissingQuestionId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReportPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$QuestionId
    )

    # 報告須含每一個題號（整個詞，前後不是字母數字、底線或連字號）。報告不存在時全部視為缺少。
    $text = if ([IO.File]::Exists($ReportPath)) { [IO.File]::ReadAllText($ReportPath, (New-Object System.Text.UTF8Encoding -ArgumentList @($false))) } else { '' }
    return [string[]]@($QuestionId | Where-Object { $text -cnotmatch ('(?<![A-Za-z0-9_-])' + [regex]::Escape($_) + '(?![A-Za-z0-9_-])') })
}

function Get-RunMcpToolCallSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EventStreamPath)

    # 事件流中已結束的 MCP 工具呼叫次數（item.completed 且 item.type 為 mcp_tool_call），依 item.status 分 completed 與 failed，並列出用到的伺服器。
    # 事件流不存在或無法解析的行略過。供測試取證確認 Codex 確實以 MCP 工具操作過。
    $completed = 0
    $failed = 0
    $servers = New-Object 'System.Collections.Generic.SortedSet[string]' -ArgumentList @([StringComparer]::Ordinal)
    if ([IO.File]::Exists($EventStreamPath)) {
        foreach ($line in [IO.File]::ReadLines($EventStreamPath)) {
            if ($line.IndexOf('mcp_tool_call', [StringComparison]::Ordinal) -lt 0) { continue }
            try { $parsed = ConvertFrom-Json -InputObject $line -Depth 20 } catch { continue }
            if ($parsed -isnot [pscustomobject] -or [string](Get-RunJsonProperty -Object $parsed -Name 'type') -cne 'item.completed') { continue }
            $item = Get-RunJsonProperty -Object $parsed -Name 'item'
            if ($item -isnot [pscustomobject] -or [string](Get-RunJsonProperty -Object $item -Name 'type') -cne 'mcp_tool_call') { continue }
            if ([string](Get-RunJsonProperty -Object $item -Name 'status') -ceq 'completed') { $completed++ } else { $failed++ }
            $server = [string](Get-RunJsonProperty -Object $item -Name 'server')
            if (-not [string]::IsNullOrWhiteSpace($server)) { $null = $servers.Add($server) }
        }
    }
    return [ordered]@{ completed = $completed; failed = $failed; servers = [string[]]@($servers) }
}

function Get-RunDirectoryFileState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    # 目錄內全部檔案的相對路徑對「長度|最後寫入時間」，目錄不存在時為空。供比對啟動前後哪些檔案是本次新增或變動。
    # 列舉失敗（例如子目錄沒有存取權限）不拋例外，回傳 ok = $false 與錯誤訊息，呼叫端標示狀態無法判定，不讓派遣失敗。
    $state = @{}
    try {
        if ([IO.Directory]::Exists($Path)) {
            $root = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
            foreach ($file in [IO.Directory]::EnumerateFiles($Path, '*', [IO.SearchOption]::AllDirectories)) {
                $info = New-Object System.IO.FileInfo -ArgumentList @($file)
                $state[[IO.Path]::GetFullPath($file).Substring($root.Length + 1).Replace('\', '/')] = [string]$info.Length + '|' + [string]$info.LastWriteTimeUtc.Ticks
            }
        }
    }
    catch { return [pscustomobject]@{ ok = $false; files = @{}; error = $_.Exception.Message } }
    return [pscustomobject]@{ ok = $true; files = $state; error = $null }
}

function Get-RunOutputArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$ReportName
    )

    # 輸出目錄內報告以外的檔案（截圖、頁面快照等），以相對於輸出目錄的路徑列出。
    if (-not [IO.Directory]::Exists($OutputDirectory)) { return [string[]]@() }
    $root = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\', '/')
    $files = foreach ($file in [IO.Directory]::EnumerateFiles($OutputDirectory, '*', [IO.SearchOption]::AllDirectories)) {
        $relative = [IO.Path]::GetFullPath($file).Substring($root.Length + 1).Replace('\', '/')
        if ($relative -cne $ReportName) { $relative }
    }
    return [string[]]@($files | Sort-Object)
}

function New-RunPrompt {
    param(
        [Parameter(Mandatory)][object]$Order,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$ReportPath,
        [AllowNull()][AllowEmptyString()][string]$ReviewerLine,
        [AllowNull()][object]$Evidence
    )

    # 「審查者:」（審查以外為「執行者:」）行由執行端照抄到報告「## 總覽」第一行，使報告標明實際執行者與 model。
    $executorLabel = [string]$Order.task_setting.executor_label
    if ($Order.task_setting.evidence_only) {
        # evidence-only：不開放任何檔案，evidence 全文內嵌，最後訊息由入口存成報告檔。
        $adviseLines = @(
            'LineContext'
            ('- lineSlug: ' + $Order.line_slug)
            ('輸出目錄: ' + $OutputDirectory)
            ('報告檔: ' + $ReportPath)
            if (-not [string]::IsNullOrWhiteSpace($ReviewerLine)) { $executorLabel + ': ' + $ReviewerLine }
            ''
            '你只依下列 evidence 內容回答，不讀取任何檔案，不執行命令。'
            '請在最後訊息中，對題號清單的每一個題號各用一個標題（例如 `## <題號>`）回答；入口把最後訊息存成報告檔，並檢查報告含每一個題號。'
            ('題號: ' + (@($Order.question_ids) -join ', '))
            ($script:RunEvidenceBeginPrefix + ' sha256=' + $Evidence.sha256 + ' bytes=' + $Evidence.bytes + '>>>')
        )
        return (($adviseLines -join "`n") + "`n" + $Evidence.text + "`n" + $script:RunEvidenceEndMarker + "`n")
    }
    $lines = @(
        'LineContext'
        ('- lineSlug: ' + $Order.line_slug)
        ('- dispatchLineRoot: ' + (Split-Path -Parent $Order.dispatch_file_path))
        ('- reportLineRoot: ' + $Order.report_line_root)
        ('- executionRoot: ' + $Order.execution_root)
        ('輸出目錄: ' + $OutputDirectory)
        ('報告檔: ' + $ReportPath)
        if (-not [string]::IsNullOrWhiteSpace($ReviewerLine)) { $executorLabel + ': ' + $ReviewerLine }
        ''
        ('請依角色規則檔 `' + $Order.role_file + '` 定義的角色，先完整讀取該檔，再讀取派遣檔 `' + $Order.dispatch_file_path + '` 依其內容執行。')
    )
    if ($Order.task_setting.mcp) {
        # 測試取證：命令唯讀，操作與取證只經 MCP 工具；受測對象由 Claude 端在派工前啟動。
        $lines += @(
            ''
            '測試取證規則：'
            '- 命令沙盒唯讀，不建置、不啟動或停止受測程式；受測對象已由 Claude 端啟動，只以 MCP 工具（網頁用 playwright，桌面用 flaui-mcp）操作與觀察。'
            ('- 截圖一律使用工具預設的自動命名，不指定檔名，檔案才會存入輸出目錄 ' + $OutputDirectory + '；報告逐一列出截圖檔名與對應的驗收條件。')
            '- 桌面操作先以 windows_attach 附加派遣檔指定的視窗，不要列舉桌面上其他視窗。'
            if (-not [string]::IsNullOrWhiteSpace([string]$Order.test_context_file)) { '- 測試環境資料檔: ' + $Order.test_context_file + '（登入帳號與資料重置方式，只依其內容操作）' }
        )
    }
    return (($lines -join "`n") + "`n")
}

function Test-RunGitRepository {
    param([Parameter(Mandatory)][string]$Directory)

    try {
        $probe = Invoke-RunGitBytes -WorkingDirectory $Directory -Argument @('rev-parse', '--is-inside-work-tree')
        return $probe.ExitCode -eq 0
    }
    catch { return $false }
}

function ConvertTo-RunIsoTime {
    param([Parameter(Mandatory)][DateTime]$Value)

    return $Value.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
}

function Invoke-RunAttempt {
    param(
        [Parameter(Mandatory)][object]$Order,
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][string]$CodexPath,
        [Parameter(Mandatory)][string]$MachineConfigPath,
        [Parameter(Mandatory)][string]$DispatchSha256,
        [Parameter(Mandatory)][bool]$IsGitRepository,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][int]$TurnEndGraceSeconds,
        [AllowNull()][AllowEmptyString()][string]$ExecutorDisplay,
        # 同一次發動第一次嘗試的 evidence 雜湊。之後的嘗試以此為基準，evidence 在嘗試之間被改或被刪時停止，不以新內容重跑。
        [AllowNull()][AllowEmptyString()][string]$EvidenceBaselineSha256
    )

    # 一個帳號搭配一個 model 的一次嘗試，各自有獨立的 runKey、輸出目錄、紀錄與成本列。
    # Candidate.model 是本次實際使用的 model；與 Candidate.primary_model 不同時為備援 model，以 -c model= 覆寫檔位設定。
    $modelSource = 'primary'
    $modelOverride = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Candidate.model) -and [string]$Candidate.model -cne [string]$Candidate.primary_model) {
        $modelSource = 'fallback'
        $modelOverride = [string]$Candidate.model
    }
    $reviewerLine = $null
    if (-not [string]::IsNullOrWhiteSpace($ExecutorDisplay)) {
        $reviewerLine = $ExecutorDisplay
        if (-not [string]::IsNullOrWhiteSpace([string]$Candidate.model)) { $reviewerLine += '；model: ' + [string]$Candidate.model + $(if ($modelSource -ceq 'fallback') { '（備援）' } else { '' }) }
    }
    $runId = New-RunId
    $runKey = $Order.dispatch_slug + '-' + $runId
    $runsDirectory = Join-Path $Order.report_line_root 'runs'
    $outputDirectory = Join-Path $runsDirectory $runKey
    $recordPath = Join-Path $runsDirectory ($runKey + '.record.json')
    $eventsPath = Join-Path $runsDirectory ($runKey + '.events.jsonl')
    $stderrPath = Join-Path $runsDirectory ($runKey + '.stderr.txt')
    $lastMessagePath = Join-Path $runsDirectory ($runKey + '.last-message.md')
    $reportPath = Join-Path $outputDirectory $Order.report_name

    # evidence-only：先讀 evidence 並組 prompt、比對內嵌內容，不一致時在建立任何檔案之前停止。
    $evidenceOnly = [bool]$Order.task_setting.evidence_only
    $evidenceStart = $null
    $prompt = $null
    if ($evidenceOnly) {
        if ([string]::IsNullOrEmpty($EvidenceBaselineSha256)) { $evidenceStart = Get-RunEvidenceSnapshot -Path $Order.evidence_file }
        else {
            try { $evidenceStart = Get-RunEvidenceSnapshot -Path $Order.evidence_file }
            catch { $evidenceStart = $null }
            if ($null -eq $evidenceStart -or $evidenceStart.sha256 -cne $EvidenceBaselineSha256) {
                throw (New-RunError -Code 'RunEvidenceChangedBetweenAttempts' -Message ('evidence 在換帳號或換 model 之前已被改動或刪除，已停止，未啟動 Codex：' + $Order.evidence_file) -ExitCode 2)
            }
        }
        $prompt = New-RunPrompt -Order $Order -OutputDirectory $outputDirectory -ReportPath $reportPath -ReviewerLine $reviewerLine -Evidence $evidenceStart
        if (-not (Test-RunEvidenceInline -Prompt $prompt -Evidence $evidenceStart)) {
            throw (New-RunError -Code 'RunEvidenceInlineMismatch' -Message ('prompt 內嵌的 evidence 與檔案內容不一致，已停止，未啟動 Codex：' + $Order.evidence_file) -ExitCode 2)
        }
    }
    $null = [IO.Directory]::CreateDirectory($outputDirectory)

    # 影像產生把選定帳號的 generated_images 列為可讀（影像先產在該處，再由 Codex 複製到輸出目錄）。
    # 目錄不存在時先建立，權限設定才有對應的目錄可授權。
    $extraReadRoots = @()
    if ($Order.task_setting.generated_images) {
        $generatedImages = Join-Path $Candidate.codex_home 'generated_images'
        $null = [IO.Directory]::CreateDirectory($generatedImages)
        $extraReadRoots += $generatedImages
    }
    $workingDirectory = if ($evidenceOnly) { $outputDirectory } else { $Order.execution_root }
    # 測試取證：測試環境資料檔以檔案單位開放唯讀；MCP 工具的輸出（Playwright 的自動命名截圖與快照）由環境變數導向輸出目錄，
    # 殘留在工作目錄根下的 .playwright-mcp 不納入來源雜湊（明確檔名的截圖仍可能寫到那裡，由 mcp_stray_output 記錄）。
    $readFiles = @()
    $extraEnvironment = @{}
    $sourceExcludeRoots = @($Order.report_line_root)
    $strayMcpOutput = Join-Path $Order.execution_root '.playwright-mcp'
    if ($Order.task_setting.mcp) {
        if (-not [string]::IsNullOrWhiteSpace([string]$Order.test_context_file)) { $readFiles = @([string]$Order.test_context_file) }
        $extraEnvironment['PLAYWRIGHT_MCP_OUTPUT_DIR'] = $outputDirectory
        $sourceExcludeRoots += $strayMcpOutput
    }
    # 啟動前記錄 .playwright-mcp 的檔案狀態，結束時只把本次新增或變動的檔案標為殘留（先前殘留或他人使用的檔案不算）。
    $strayBefore = if ($Order.task_setting.mcp) { Get-RunDirectoryFileState -Path $strayMcpOutput } else { $null }
    $plan = Get-RunPermissionPlan -ExecutionRoot $workingDirectory -OutputDirectory $outputDirectory -ReportLineRoot $Order.report_line_root -ExtraReadRoot $extraReadRoots -OutputOnly:$evidenceOnly -ReadFile $readFiles
    $permission = [ordered]@{ name = $plan.name; read_roots = @($plan.read_roots); write_roots = @($plan.write_roots); deny_patterns = @($plan.deny_patterns) }
    if ($null -ne $plan.PSObject.Properties['read_files']) { $permission['read_files'] = @($plan.read_files) }
    $startedAt = [DateTime]::UtcNow
    # evidence-only 的來源狀態是 evidence 檔的雜湊與長度（不讀工作目錄）；執行期間被改時 source_changed 為 true。
    $sourceStart = if ($evidenceOnly) { [ordered]@{ evidence_file = $Order.evidence_file; sha256 = $evidenceStart.sha256; bytes = $evidenceStart.bytes } }
    else { Get-RunSourceState -ExecutionRoot $Order.execution_root -Target $Order.targets -ExcludeRoot $sourceExcludeRoots }
    $record = [ordered]@{
        schema = 'ai-agents.codex-run-record.v1'
        run_key = $runKey
        run_id = $runId
        line_slug = $Order.line_slug
        dispatch_slug = $Order.dispatch_slug
        task_type = $Order.task_type
        profile = $Order.profile
        dispatch_file = [ordered]@{ path = $Order.dispatch_file_path; sha256 = $DispatchSha256 }
        account = [ordered]@{ name = $Candidate.name; codex_home = $Candidate.codex_home }
        model = $Candidate.model
        model_source = $modelSource
        execution_root = $Order.execution_root
        output_dir = $outputDirectory
        report_path = $reportPath
        started_utc = ConvertTo-RunIsoTime -Value $startedAt
        # 本次實際套用的時限。初稿就寫入，執行中的派工可由紀錄判斷是否已超過時限，不必推測入口的預設值。
        timeout_seconds = [int]$TimeoutSeconds
        turn_end_grace_seconds = [int]$TurnEndGraceSeconds
        ended_utc = $null
        duration_seconds = $null
        source_state_start = $sourceStart
        source_state_end = $null
        source_changed = $null
        exit_code = $null
        result = $null
        failure_reason = $null
        terminated_by_entry = $null
        rejection_kind = $null
        item_event_count = $null
        usage = $null
        last_message = [ordered]@{ path = $lastMessagePath; exists = $null; empty = $null }
        events_path = $eventsPath
        stderr_path = $stderrPath
        report = $null
        review_report_check = $null
        permission = $permission
    }
    if ($evidenceOnly) {
        $record['evidence'] = [ordered]@{ path = $Order.evidence_file; sha256 = $evidenceStart.sha256; bytes = $evidenceStart.bytes; inline_verified = $true; sha256_end = $null }
        $record['missing_question_ids'] = $null
        $record['question_check'] = $null
    }
    if ($Order.task_setting.mcp) {
        $record['test_context_file'] = if ([string]::IsNullOrWhiteSpace([string]$Order.test_context_file)) { $null } else { [string]$Order.test_context_file }
        $record['mcp_tool_calls'] = $null
        $record['artifacts'] = $null
        $record['mcp_stray_output'] = $null
    }
    try { Write-RunJsonAtomic -Path $recordPath -InputObject $record -Depth 8 }
    catch { throw (New-RunError -Code 'RunRecordWriteFailed' -Message ('執行紀錄初稿寫入失敗：' + $_.Exception.Message) -ExitCode 1) }

    $argument = New-RunExecArgument -ExecutionRoot $workingDirectory -Profile $Order.profile -OutputDirectory $outputDirectory -LastMessagePath $lastMessagePath -IsGitRepository ($IsGitRepository -and -not $evidenceOnly) -ReportLineRoot $Order.report_line_root -ModelOverride $modelOverride `
        -ExtraReadRoot $extraReadRoots -Search:([bool]$Order.task_setting.search) -OutputOnly:$evidenceOnly -ReadFile $readFiles
    if (-not $evidenceOnly) { $prompt = New-RunPrompt -Order $Order -OutputDirectory $outputDirectory -ReportPath $reportPath -ReviewerLine $reviewerLine }
    Write-RunDiagnostic ('[codex-run] 嘗試帳號 ' + $Candidate.name + $(if ($modelSource -ceq 'fallback') { '（備援 model ' + $modelOverride + '）' } else { '' }) + '，runKey ' + $runKey)
    $exitCode = -1
    $duration = 0.0
    $launchFailed = $false
    $terminatedBy = $null
    try {
        $process = Invoke-RunCodexProcess -CodexPath $CodexPath -Argument $argument -Prompt $prompt -CodexHome $Candidate.codex_home -EventStreamPath $eventsPath -StderrPath $stderrPath -WorkingDirectory $workingDirectory `
            -LastMessagePath $lastMessagePath -TimeoutSeconds $TimeoutSeconds -TurnEndGraceSeconds $TurnEndGraceSeconds -ExtraEnvironment $extraEnvironment
        $exitCode = [int]$process.ExitCode
        $duration = [double]$process.DurationSeconds
        $terminatedBy = $process.TerminatedBy
    }
    catch {
        if ($_.Exception.Data.Contains('Code')) { throw }
        $launchFailed = $true
        $duration = ([DateTime]::UtcNow - $startedAt).TotalSeconds
        Write-RunDiagnostic ('[codex-run] codex 行程無法啟動：' + $_.Exception.Message)
    }
    $endedAt = [DateTime]::UtcNow
    $evidenceEnd = $null
    if ($evidenceOnly) {
        # evidence 在執行期間被刪除或無法讀取時不拋例外（否則結束紀錄寫不出來），記為來源已變。
        try { $evidenceEnd = Get-RunEvidenceSnapshot -Path $Order.evidence_file }
        catch { $evidenceEnd = $null }
        $sourceEnd = if ($null -ne $evidenceEnd) { [ordered]@{ evidence_file = $Order.evidence_file; sha256 = $evidenceEnd.sha256; bytes = $evidenceEnd.bytes } }
        else { [ordered]@{ evidence_file = $Order.evidence_file; sha256 = $null; bytes = $null; unavailable = $true } }
    }
    else { $sourceEnd = Get-RunSourceState -ExecutionRoot $Order.execution_root -Target $Order.targets -ExcludeRoot $sourceExcludeRoots }
    $sourceChanged = (ConvertTo-Json -InputObject $sourceStart -Compress) -cne (ConvertTo-Json -InputObject $sourceEnd -Compress)

    if ($terminatedBy -ceq 'timeout') { Write-RunDiagnostic ('[codex-run] 超過總時限 ' + $TimeoutSeconds + ' 秒，已終止 codex 行程樹。') }
    if ($terminatedBy -ceq 'after-turn-end') { Write-RunDiagnostic ('[codex-run] 回合結束後 ' + $TurnEndGraceSeconds + ' 秒 codex 行程仍未結束，已由入口終止，結果依報告判定。') }
    # 被入口終止的行程，結束碼是終止所致，不拿來判讀事件流。
    $evidence = Get-RunEventEvidence -EventStreamPath $eventsPath -StderrPath $stderrPath -ExitCode $(if ($launchFailed -or $null -ne $terminatedBy) { $null } else { $exitCode })
    # 顧問的報告就是 Codex 的最後訊息，入口把它存成輸出目錄內的 report_name，後續判定與其他類型相同。
    if ($evidenceOnly -and [IO.File]::Exists($lastMessagePath) -and (New-Object System.IO.FileInfo -ArgumentList @($lastMessagePath)).Length -gt 0) {
        [IO.File]::Copy($lastMessagePath, $reportPath, $true)
    }
    $judged = Get-RunResult -ExitCode $exitCode -LastMessagePath $lastMessagePath -ReportPath $reportPath -Evidence $evidence -TimedOut:($terminatedBy -ceq 'timeout') -TerminatedAfterTurnEnd:($terminatedBy -ceq 'after-turn-end')
    $result = $judged.result
    $failureReason = $judged.failure_reason
    if ($launchFailed) { $result = 'failed'; $failureReason = 'launch-failed' }
    # 題號檢查：只要有報告內容可檢查就列出缺少的題號（不論結果）；沒有報告時為 unavailable，missing_question_ids 為 null。
    $missingQuestionIds = $null
    $questionCheck = $null
    if ($evidenceOnly) {
        $reportForCheck = New-Object System.IO.FileInfo -ArgumentList @($reportPath)
        if ($reportForCheck.Exists -and $reportForCheck.Length -gt 0) {
            $questionCheck = 'checked'
            $missingQuestionIds = [string[]]@(Get-RunMissingQuestionId -ReportPath $reportPath -QuestionId @($Order.question_ids))
        }
        else { $questionCheck = 'unavailable' }
        if ($result -ceq 'success' -and @($missingQuestionIds).Count -gt 0) { $result = 'failed'; $failureReason = 'questions-missing' }
        # evidence 在執行期間被改或被刪：不論回答是否齊備，結果為失敗（結束碼非零），報告不可信。
        if ($result -ceq 'success' -and $sourceChanged) { $result = 'failed'; $failureReason = 'source-changed' }
    }
    $reviewCheck = $null
    if ($result -ceq 'success' -and [string]$Order.task_setting.report_check -ceq 'review-manifest') {
        $checked = Test-RunReviewReport -ReportPath $reportPath
        $reviewCheck = [ordered]@{ valid = $checked.valid; errors = @($checked.errors) }
    }

    $healthError = $null
    try {
        if ($result -ceq 'rejected' -and $evidence.rejection_kind -ceq 'model-not-supported' -and (Test-RunFailoverEligible -Evidence $evidence)) {
            $null = Register-RunAccountHealth -AccountName $Candidate.name -CodexHome $Candidate.codex_home -Profile $Order.profile -Model $Candidate.model -ReasonCode 'model-not-supported' -MachineConfigPath $MachineConfigPath `
                -Evidence ([ordered]@{ dispatch_slug = $Order.dispatch_slug; run_key = $runKey; event_stream_path = $eventsPath })
        }
        elseif ($result -ceq 'success') {
            $null = Clear-RunAccountHealth -AccountName $Candidate.name -CodexHome $Candidate.codex_home -Profile $Order.profile -Model $Candidate.model -MachineConfigPath $MachineConfigPath
        }
    }
    catch {
        $healthError = $_.Exception.Message
        Write-RunDiagnostic ('[codex-run] 帳號健康狀態寫入失敗，不影響派遣結果：' + $healthError)
    }

    $lastMessageInfo = New-Object System.IO.FileInfo -ArgumentList @($lastMessagePath)
    $reportInfo = New-Object System.IO.FileInfo -ArgumentList @($reportPath)
    $record['ended_utc'] = ConvertTo-RunIsoTime -Value $endedAt
    $record['duration_seconds'] = $duration
    $record['source_state_end'] = $sourceEnd
    $record['source_changed'] = $sourceChanged
    $record['exit_code'] = if ($launchFailed) { $null } else { $exitCode }
    $record['result'] = $result
    $record['failure_reason'] = $failureReason
    $record['terminated_by_entry'] = $terminatedBy
    $record['rejection_kind'] = $evidence.rejection_kind
    $record['limit_reset_raw'] = $evidence.limit_reset_raw
    $record['limit_reset_local'] = $evidence.limit_reset_local
    $record['item_event_count'] = $evidence.item_event_count
    $record['usage'] = $evidence.usage
    $record['last_message'] = [ordered]@{ path = $lastMessagePath; exists = $lastMessageInfo.Exists; empty = (-not $lastMessageInfo.Exists) -or $lastMessageInfo.Length -eq 0 }
    $record['report'] = [ordered]@{ exists = $reportInfo.Exists; bytes = if ($reportInfo.Exists) { $reportInfo.Length } else { 0 } }
    $record['review_report_check'] = $reviewCheck
    if ($evidenceOnly) {
        $record['evidence']['sha256_end'] = if ($null -ne $evidenceEnd) { $evidenceEnd.sha256 } else { $null }
        $record['missing_question_ids'] = $missingQuestionIds
        $record['question_check'] = $questionCheck
    }
    $mcpToolCalls = $null
    $artifacts = $null
    $mcpStrayOutput = $null
    if ($Order.task_setting.mcp) {
        $mcpToolCalls = Get-RunMcpToolCallSummary -EventStreamPath $eventsPath
        $artifacts = Get-RunOutputArtifact -OutputDirectory $outputDirectory -ReportName $Order.report_name
        # 工作目錄根下的 .playwright-mcp 有檔案表示有截圖或快照沒有進輸出目錄（例如指定了明確檔名），回收時把它們移進輸出目錄或回報。
        $strayAfter = Get-RunDirectoryFileState -Path $strayMcpOutput
        if ($strayBefore.ok -and $strayAfter.ok) {
            $strayChanged = @($strayAfter.files.Keys | Where-Object { -not $strayBefore.files.ContainsKey($_) -or $strayBefore.files[$_] -cne $strayAfter.files[$_] } | Sort-Object)
            $mcpStrayOutput = [ordered]@{ path = $strayMcpOutput; state = 'determined'; exists = ($strayChanged.Count -gt 0); files = [string[]]$strayChanged; error = $null }
        }
        else {
            # 列舉失敗時無法判定是否有本次殘留：exists 為 null，state 為 indeterminate，並記下錯誤，回收時人工檢查該目錄。
            $strayError = if (-not $strayBefore.ok) { [string]$strayBefore.error } else { [string]$strayAfter.error }
            Write-RunDiagnostic ('[codex-run] 無法列舉 ' + $strayMcpOutput + '，殘留狀態無法判定：' + $strayError)
            $mcpStrayOutput = [ordered]@{ path = $strayMcpOutput; state = 'indeterminate'; exists = $null; files = [string[]]@(); error = $strayError }
        }
        $record['mcp_tool_calls'] = $mcpToolCalls
        $record['artifacts'] = $artifacts
        $record['mcp_stray_output'] = $mcpStrayOutput
    }
    try {
        Write-RunJsonAtomic -Path $recordPath -InputObject $record -Depth 8
        $null = Add-RunCostRow -LedgerPath (Join-Path $Order.report_line_root 'cost-ledger.md') -LineSlug $Order.line_slug -DispatchSlug $Order.dispatch_slug -RunId $runId `
            -Cycle $Order.cycle -DurationSeconds $duration -Usage $evidence.usage -ExitCode $exitCode -Result $result -TaskType $Order.task_type -AccountName $Candidate.name `
            -RejectionKind $evidence.rejection_kind -EndedUtc $endedAt
    }
    catch {
        throw (New-RunError -Code 'RunRecordWriteFailed' -Message ('執行紀錄或成本列寫入失敗，已完成的報告保留於 ' + $reportPath + '：' + $_.Exception.Message) -ExitCode 1)
    }

    $reloginCommand = $null
    if ($evidence.rejection_kind -ceq 'unauthorized') { $reloginCommand = Get-RunReloginCommand -CodexHome $Candidate.codex_home }
    $attemptResult = [ordered]@{
        run_key = $runKey
        account = $Candidate.name
        model = $Candidate.model
        model_source = $modelSource
        result = $result
        failure_reason = $failureReason
        rejection_kind = $evidence.rejection_kind
        record_path = $recordPath
        report_path = $reportPath
        last_message_path = $lastMessagePath
        events_path = $eventsPath
        stderr_path = $stderrPath
        source_changed = $sourceChanged
        review_report_check = $reviewCheck
        relogin_command = $reloginCommand
        failover_eligible = (Test-RunFailoverEligible -Evidence $evidence)
        health_error = $healthError
    }
    if ($Order.task_setting.mcp) {
        $attemptResult['mcp_tool_calls'] = $mcpToolCalls
        $attemptResult['artifacts'] = $artifacts
        $attemptResult['mcp_stray_output'] = $mcpStrayOutput
    }
    if ($evidenceOnly) {
        $attemptResult['evidence'] = $record['evidence']
        $attemptResult['missing_question_ids'] = $missingQuestionIds
        $attemptResult['question_check'] = $questionCheck
    }
    return [pscustomobject]$attemptResult
}

function Assert-RunProfileConsistency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Profile,

        [Parameter(Mandatory)]
        [string[]]$AccountHome,

        [Parameter(Mandatory)]
        [string]$ProfileSourceRoot
    )

    # 啟動 Codex 前只讀比對實際要使用的帳號：帳號目錄的檔位設定檔必須是指向主 checkout 產生檔的 Symbolic Link 且內容相同，
    # 產生檔等於主 checkout 登錄表的預期內容，入口所在工作樹的登錄表設定也已落地到主 checkout。
    # 不一致時停止，不改任何檔案，訊息列出可整行貼到 pwsh 的修正命令。
    try {
        $findings = @(Test-CodexProfileConsistency -RegistryPath (Get-CodexProfileRegistryPath -RepoRoot $ProfileSourceRoot) -GeneratedDirectory (Get-CodexProfileGeneratedDirectory -RepoRoot $ProfileSourceRoot) -AccountHome @($AccountHome) -Profile $Profile -TreeRegistryPath (Get-CodexProfileRegistryPath -RepoRoot (Get-CodexProfileRepoRoot)))
    }
    catch {
        throw (New-RunError -Code 'CodexProfileDrift' -Message ('無法比對檔位設定檔，已停止，未啟動 Codex，未改任何檔案：' + $_.Exception.Message) -ExitCode 2)
    }
    if ($findings.Count -eq 0) { return }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($finding in $findings) {
        $lines.Add('[' + $finding.code + '] ' + $finding.path + '：' + $finding.detail)
        foreach ($fixLine in @(Format-CodexProfileFixLine -Command $finding.fix_commands -Note $finding.fix_note)) { $lines.Add($fixLine) }
    }
    throw (New-RunError -Code 'CodexProfileDrift' -Message ('檔位 ' + $Profile + ' 的設定檔與主 checkout 的產生檔不一致，已停止，未啟動 Codex，未改任何檔案。以下每一行可直接貼到 pwsh 執行，# 開頭為說明：' + [Environment]::NewLine + ($lines -join [Environment]::NewLine)) -ExitCode 2)
}

function Assert-RunMcpAccountConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$AccountHome,
        [Parameter(Mandatory)][string]$ProfileSourceRoot
    )

    # 測試取證：檔位檔只啟用 MCP 伺服器，指令路徑因機器而異，由帳號目錄 config.toml 提供。缺少時 Codex 載入檔位設定失敗，
    # 這裡先只讀檢查並以 CodexMcpConfigMissing 停止，不啟動 Codex、不改檔。登錄表讀不到時略過，檔位設定的問題由 Assert-RunProfileConsistency 回報。
    try {
        $spec = @(Read-CodexProfileSpec -RegistryPath (Get-CodexProfileRegistryPath -RepoRoot $ProfileSourceRoot) | Where-Object { $_.Profile -ceq $Profile })
    }
    catch { return }
    if ($spec.Count -eq 0) { return }
    $missing = @(Get-CodexMcpAccountConfigFinding -AccountHome $AccountHome -Spec $spec[0])
    if ($missing.Count -eq 0) { return }
    $setupPath = Join-Path $ProfileSourceRoot 'scripts\Setup-AIGlobalConfig.ps1'
    throw (New-RunError -Code 'CodexMcpConfigMissing' -Message ('帳號目錄 ' + (Join-Path $AccountHome 'config.toml') + ' 缺少 MCP 伺服器 ' + ($missing -join '、') + ' 的 command，檔位 ' + $Profile + ' 無法載入，已停止，未啟動 Codex，未改任何檔案。重跑 Setup 補上（以 pwsh 執行）：' + [Environment]::NewLine + '& ' + (ConvertTo-CodexProfileQuoted -Text $setupPath)) -ExitCode 2)
}

function Get-RunProfileExecutor {
    param(
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$RegistryPath
    )

    # 登錄表內使用該檔位的 Codex 執行者（Id、Display、FallbackModels）。登錄表讀不到或沒有該檔位時回傳 $null，
    # 呼叫端視為沒有備援 model，也不產生下一位執行者；檔位設定本身的問題由派工前比對回報。
    try {
        $registry = Read-CodexProfileRegistry -RegistryPath $RegistryPath
        $executor = @($registry.Executors | Where-Object { $_.Platform -ceq 'codex' -and $_.Profile -ceq $Profile })
        if ($executor.Count -eq 0) { return $null }
        return [pscustomobject]@{ Id = [string]$executor[0].Id; Display = [string]$executor[0].Display; FallbackModels = [string[]]@($executor[0].ProfileSettings['fallbackModels']) }
    }
    catch { return $null }
}

function Get-RunFallbackSelection {
    param(
        [Parameter(Mandatory)][string]$TaskType,
        [Parameter(Mandatory)][string]$UnavailableExecutorId
    )

    # 全部帳號不可用時，以選派入口取得下一位執行者，協調者不必手動帶 -Offline 重新呼叫。
    # 實作者家族固定為 claude（Codex 不承擔實作）。不寫任何狀態，下一次新的派工照常先選 Codex。
    # 選派入口無法執行或輸出不是 JSON 時回傳 $null，呼叫端照常回報原錯誤。
    try {
        $selectorPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Select-DispatchExecutor.ps1'
        if (-not [IO.File]::Exists($selectorPath)) { throw ('找不到選派入口：' + $selectorPath) }
        $hostPath = (Get-Process -Id $PID).Path
        # 經本入口的 test 只做 MCP 臨場操作（瀏覽器、桌面），這些硬能力沒有 Claude 替代者，帶 browse 標籤使選派入口回傳 stopped。
        # 不含瀏覽器或桌面操作的測試（build-test）本來就不走本入口，由呼叫端以標籤選到 Claude 執行者。
        $selectorArguments = @('-Type', $TaskType, '-ImplementerFamily', 'claude', '-Offline', $UnavailableExecutorId)
        if ($TaskType -ceq 'test') { $selectorArguments += @('-Tags', 'browse') }
        $output = @(& $hostPath -NoProfile -NonInteractive -File $selectorPath @selectorArguments 2>$null)
        $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
        if ([string]::IsNullOrWhiteSpace($text)) { throw ('選派入口沒有輸出，結束碼 ' + $LASTEXITCODE) }
        return [ordered]@{ unavailable_executor = $UnavailableExecutorId; selection = (ConvertFrom-Json -InputObject $text) }
    }
    catch {
        Write-RunDiagnostic ('[codex-run] 無法取得下一位執行者，請以 -Offline ' + $UnavailableExecutorId + ' 手動呼叫選派入口：' + $_.Exception.Message)
        return $null
    }
}

function Invoke-CodexRunMain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DispatchFile,

        [string]$CodexPath,

        [string]$MachineConfigPath,

        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds = 1800,

        # 回合結束後的寬限秒數。入口不對外提供，供測試縮短。
        [ValidateRange(0, 3600)]
        [int]$TurnEndGraceSeconds = 60,

        # 檔位設定檔比對的 repo 根目錄（含 scripts\dispatch\executor-registry.json 與 scripts\codex-profiles）。測試與診斷用，預設為主 checkout（machine.json 所在 repo）。
        [string]$ProfileSourceRoot,

        # 略過派工前的檔位設定檔比對。測試與診斷用；略過時於 stderr 留下一行紀錄。
        [switch]$SkipProfileCheck
    )

    # 回傳 ExitCode 與 Document（ai-agents.codex-run-result.v1）。診斷行寫 stderr，結果文件由入口輸出到 stdout。
    $attempts = New-Object 'System.Collections.Generic.List[object]'
    $final = $null
    $fallback = $null
    $profileExecutor = $null
    $taskType = $null
    $errorInfo = $null
    $status = 'stopped'
    $exitCode = 1
    try {
        if (-not [OperatingSystem]::IsWindows()) {
            throw (New-RunError -Code 'RunPlatformUnsupported' -Message '新入口只支援 Windows（MXC 沙盒）。' -ExitCode 3)
        }
        $dispatchPath = [IO.Path]::GetFullPath($DispatchFile)
        $order = Read-RunDispatchFile -Path $dispatchPath
        Test-RunPreStart -Order $order
        $codex = Get-RunCodexPath -ConfiguredPath $CodexPath
        $machinePath = $MachineConfigPath
        if ([string]::IsNullOrWhiteSpace($machinePath)) { $machinePath = Resolve-RunMachineConfigPath }
        $profileRoot = $ProfileSourceRoot
        if ([string]::IsNullOrWhiteSpace($profileRoot)) { $profileRoot = Split-Path -Parent (Split-Path -Parent $machinePath) }
        # 備援 model 與執行者名稱取自主 checkout 的登錄表，與派工前比對使用同一份。
        $taskType = [string]$order.task_type
        $profileExecutor = Get-RunProfileExecutor -Profile $order.profile -RegistryPath (Get-CodexProfileRegistryPath -RepoRoot $profileRoot)
        $fallbackModels = if ($null -ne $profileExecutor) { [string[]]@($profileExecutor.FallbackModels) } else { [string[]]@() }
        $executorDisplay = if ($null -ne $profileExecutor) { [string]$profileExecutor.Display } else { $null }
        $selection = Get-RunAccountCandidate -Profile $order.profile -MachineConfigPath $machinePath -FallbackModel $fallbackModels
        if (@($selection.candidates).Count -eq 0 -and -not $SkipProfileCheck) {
            # 已登入的帳號因檔位設定檔缺失而被排除時，這是本機檔位設定問題，不是 Codex 帳號全數不可用；
            # 以 CodexProfileDrift 回報修正命令，避免呼叫端誤判為 Codex 離線而改派。
            $missingProfileHomes = @(@($selection.skipped) | Where-Object { $_.reason_code -ceq 'ProfileConfigMissing' } | ForEach-Object { [string]$_.codex_home })
            if ($missingProfileHomes.Count -gt 0) {
                Assert-RunProfileConsistency -Profile $order.profile -AccountHome $missingProfileHomes -ProfileSourceRoot $profileRoot
            }
        }
        if (@($selection.candidates).Count -eq 0) {
            throw (New-RunError -Code 'CodexAccountsAllUnavailable' -Message ('所有登記帳號都不可用：' + (Format-RunAccountSkippedSummary -Skipped $selection.skipped)) -ExitCode 4)
        }
        foreach ($skippedItem in @($selection.skipped)) {
            Write-RunDiagnostic ('[codex-run] 略過帳號 ' + $skippedItem.name + '：' + $skippedItem.reason_code)
        }
        if ($SkipProfileCheck) {
            Write-RunDiagnostic '[codex-run] 已略過檔位設定檔比對（-SkipProfileCheck）。'
        }
        else {
            # 只檢查實際要使用的帳號；換帳號後對新的候選帳號在使用前再檢查，未使用的候選帳號不一致不阻擋。
            Assert-RunProfileConsistency -Profile $order.profile -AccountHome ([string]$selection.candidates[0].codex_home) -ProfileSourceRoot $profileRoot
            if ($order.task_setting.mcp) { Assert-RunMcpAccountConfig -Profile $order.profile -AccountHome ([string]$selection.candidates[0].codex_home) -ProfileSourceRoot $profileRoot }
        }
        if (-not (Test-RunMxc -CodexPath $codex -CodexHome $selection.candidates[0].codex_home)) {
            throw (New-RunError -Code 'RunMxcUnavailable' -Message '偵測不到 MXC 沙盒（codex sandbox 探針失敗）。新入口不改用其他沙盒，也不在沒有沙盒的情況下啟動 Codex。' -ExitCode 3)
        }
        $null = [IO.Directory]::CreateDirectory((Join-Path $order.report_line_root 'runs'))
        $dispatchSha = Get-RunSha256File -Path $dispatchPath
        $isGit = Test-RunGitRepository -Directory $order.execution_root

        $lastAttempt = $null
        $exhausted = $false
        $candidateIndex = 0
        $evidenceBaseline = $null
        foreach ($candidate in @($selection.candidates)) {
            if ($candidateIndex -gt 0 -and -not $SkipProfileCheck) {
                Assert-RunProfileConsistency -Profile $order.profile -AccountHome ([string]$candidate.codex_home) -ProfileSourceRoot $profileRoot
                if ($order.task_setting.mcp) { Assert-RunMcpAccountConfig -Profile $order.profile -AccountHome ([string]$candidate.codex_home) -ProfileSourceRoot $profileRoot }
            }
            $candidateIndex++
            # 同一帳號依序嘗試可用的 model：被服務端以 model not supported 拒絕且尚無進度時改試下一個 model，
            # 其他拒絕種類（額度、未授權等）換 model 無效，改試下一個帳號。同一帳號的同一個 model 不重送。
            $settled = $false
            foreach ($model in @($candidate.models)) {
                $attemptCandidate = [pscustomobject]@{ name = $candidate.name; codex_home = $candidate.codex_home; model = $model; primary_model = $candidate.primary_model }
                $lastAttempt = Invoke-RunAttempt -Order $order -Candidate $attemptCandidate -CodexPath $codex -MachineConfigPath $machinePath -DispatchSha256 $dispatchSha -IsGitRepository $isGit -TimeoutSeconds $TimeoutSeconds -TurnEndGraceSeconds $TurnEndGraceSeconds -ExecutorDisplay $executorDisplay -EvidenceBaselineSha256 $evidenceBaseline
                if ($order.task_setting.evidence_only -and [string]::IsNullOrEmpty($evidenceBaseline)) { $evidenceBaseline = [string]$lastAttempt.evidence.sha256 }
                $attempts.Add([ordered]@{
                        run_key = $lastAttempt.run_key
                        account = $lastAttempt.account
                        model = $lastAttempt.model
                        result = $lastAttempt.result
                        rejection_kind = $lastAttempt.rejection_kind
                        record_path = $lastAttempt.record_path
                        relogin_command = $lastAttempt.relogin_command
                    })
                $final = [ordered]@{
                    run_key = $lastAttempt.run_key
                    model = $lastAttempt.model
                    model_source = $lastAttempt.model_source
                    report_path = $lastAttempt.report_path
                    record_path = $lastAttempt.record_path
                    last_message_path = $lastAttempt.last_message_path
                    events_path = $lastAttempt.events_path
                    stderr_path = $lastAttempt.stderr_path
                    source_changed = $lastAttempt.source_changed
                    review_report_check = $lastAttempt.review_report_check
                    relogin_command = $lastAttempt.relogin_command
                }
                if ($order.task_setting.mcp) {
                    $final['mcp_tool_calls'] = $lastAttempt.mcp_tool_calls
                    $final['artifacts'] = $lastAttempt.artifacts
                    $final['mcp_stray_output'] = $lastAttempt.mcp_stray_output
                }
                if ($order.task_setting.evidence_only) {
                    $final['evidence'] = $lastAttempt.evidence
                    $final['missing_question_ids'] = $lastAttempt.missing_question_ids
                    $final['question_check'] = $lastAttempt.question_check
                }
                if ($lastAttempt.result -ceq 'rejected' -and $lastAttempt.failover_eligible) {
                    $exhausted = $true
                    if ($lastAttempt.rejection_kind -ceq 'model-not-supported') { continue }
                    break
                }
                $exhausted = $false
                $settled = $true
                break
            }
            if ($settled) { break }
        }
        if ($exhausted) {
            throw (New-RunError -Code 'CodexAccountsExhausted' -Message ('所有候選帳號都被服務端拒絕：' + (@($attempts | ForEach-Object { $_.account + $(if ([string]::IsNullOrWhiteSpace([string]$_.model)) { '' } else { '(' + $_.model + ')' }) + ':' + $_.rejection_kind }) -join '; ')) -ExitCode 4)
        }
        $status = [string]$lastAttempt.result
        $exitCode = if ($status -ceq 'success') { 0 } else { 1 }
        if ($null -ne $lastAttempt.health_error) {
            $errorInfo = [ordered]@{ code = 'CodexAccountHealthWriteFailed'; message = [string]$lastAttempt.health_error; details = @() }
        }
    }
    catch {
        $exception = $_.Exception
        if ($exception.Data.Contains('Code')) {
            $errorInfo = [ordered]@{ code = [string]$exception.Data['Code']; message = $exception.Message; details = @($exception.Data['Details']) }
            $exitCode = [int]$exception.Data['ExitCode']
        }
        else {
            $errorInfo = [ordered]@{ code = 'RunUnexpectedError'; message = $exception.Message; details = @() }
            $exitCode = 1
        }
        $status = 'stopped'
        if (($errorInfo.code -ceq 'CodexAccountsAllUnavailable' -or $errorInfo.code -ceq 'CodexAccountsExhausted') -and $null -ne $profileExecutor -and -not [string]::IsNullOrWhiteSpace($taskType)) {
            $fallback = Get-RunFallbackSelection -TaskType $taskType -UnavailableExecutorId $profileExecutor.Id
        }
        $pathDetails = @(@($errorInfo.details) | Where-Object { $_ -is [pscustomobject] -and $null -ne $_.PSObject.Properties['path'] })
        if ($pathDetails.Count -gt 0) {
            # 訊息本文已含每個路徑，stderr 改為摘要加逐行明細，每個路徑只出現一次。
            Write-RunDiagnostic ('[codex-run] ' + $errorInfo.code + '：' + $pathDetails.Count + ' 個路徑不合格')
            foreach ($detail in $pathDetails) { Write-RunDiagnostic ('[codex-run]   ' + $detail.path + ' (' + $detail.reason + ')') }
        }
        else {
            Write-RunDiagnostic ('[codex-run] ' + $errorInfo.message)
        }
    }
    $document = [ordered]@{
        schema = 'ai-agents.codex-run-result.v1'
        status = $status
        exit_code = $exitCode
        error = $errorInfo
        attempts = @($attempts.ToArray())
        final = $final
        fallback = $fallback
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Document = $document }
}
