#Requires -Version 7.0
<#
.SYNOPSIS
為 Claude 執行者（以 Agent 工具派生的 subagent）的一次審查或測試取證寫出執行紀錄，與 Invoke-CodexRun.ps1 的紀錄放在同一個 runs 目錄。

.DESCRIPTION
Claude 沒有入口行程可記錄，因此由協調者在派生前後各呼叫一次。
-Action Start：讀取並驗證派遣檔、建立輸出目錄、保存派生前的來源狀態，寫出 ended_utc 為 null 的紀錄初稿。
初稿同時記下 Start 當時的基準：派遣檔雜湊、targets、execution_root、report_check 與 report_line_root。
-Action End：以初稿記下的基準（不是目前的派遣檔內容）保存派生後的來源狀態，判定 source_changed、報告是否存在，以及（審查類型）報告的 finding manifest，補完紀錄。
紀錄檔欄位名稱與 Codex 的 *.record.json 相同，Get-LineCost.ps1 讀同一個目錄。Claude 沒有的欄位（account、usage、事件流、沙盒權限）填 null，
executor_platform 為 claude；token 用量取不到，不推算。

result 表示這次審查能否收下（收件資格）；Codex 紀錄的 result 是子行程的執行結果，Claude 沒有子行程，兩者語意不同。
result 為 success 的條件：來源未變、派遣檔雜湊與 Start 時相同、報告存在且非空，且 Start 時的 report_check 為 review-manifest 時 manifest 有效。
否則為 failed，failure_reason 為 source-changed、dispatch-changed、report-missing 或 review-report-invalid（依序判定，取第一個成立者）。
End 時 targets 已被刪除或來源狀態無法計算，視為來源已變：source_changed 為 true、source_state_end 為 null，紀錄照常寫出。
來源狀態計算拋出例外時，例外訊息寫入紀錄的 source_state_error 並在 stderr 輸出一行，結果判定不變。
紀錄一律寫出，結束碼 0 為 success，1 為 failed，2 為輸入無效或狀態不允許。End 時派遣檔已無法讀取或驗證時以結束碼 2 拒絕，還原派遣檔後可再次 End。
同一個 dispatchSlug 與執行者的 Start 與 End 以 runs 目錄內的排他鎖序列化；已有未結束的紀錄時，Start 以結束碼 2 拒絕，先對該次執行 End，再重新 Start。
紀錄與輸出目錄已存在時不沿用，改用新的 run id 重試，仍碰撞則以結束碼 1 拒絕。
來源快照只涵蓋派遣檔 targets，不涵蓋 targets 以外的寫入，Claude 審查者沒有沙盒限制寫入範圍。

審查類型的 Start 另在輸出目錄寫出 worktree-inventory.md（由 Write-RunWorktreeInventory 產生），紀錄加 worktree_inventory（path、sha256、bytes、head、sha256_end、error），End 時 path 非 null 才填 sha256_end，不影響 result。
盤點產生失敗（RunWorktreeInventoryFailed）時 Start 不停止：stderr 輸出一行警告，紀錄的 worktree_inventory 為 path、sha256、bytes、head、sha256_end 皆 null 且 error 為錯誤訊息，stdout 不帶 worktree_inventory_path 而帶 worktree_inventory_error，結束碼 0；其他錯誤照舊往外拋。

測試取證類型（task_type 為 test，經 Playwright MCP 或 FlaUI.Mcp 操作）的紀錄另有三個欄位，欄位名稱與 Codex 的 test 紀錄相同，其他類型為 null：
mcp_tool_calls（completed、failed、servers，另有 Claude 專有的 tools、attribution、calls、skipped）、artifacts（輸出目錄內報告以外的檔案）、mcp_stray_output（工作目錄根下 .playwright-mcp 在 Start 與 End 之間新增或變動的檔案）。
mcp_tool_calls 取自 ai-agents-hooks 在每次 MCP 工具呼叫寫下的紀錄檔（<LOCALAPPDATA>\ai-agents\mcp-calls\<agent id 或 _main>\<tool_use_id>.json，只含歸屬與結果狀態，不含工具輸入輸出），
只取時間在 started_utc 到本次 End 時間之間者，歸屬依 -AgentId；省略 -AgentId 時採用時間窗內唯一有紀錄的 agent，有多個時以結束碼 2（ClaudeRunAgentAmbiguous）拒絕、紀錄維持未結束，補 -AgentId 後重跑 End。
沒有任何紀錄檔時 completed 與 failed 為 0、attribution 為 none，不改變 result，由回收規則退回。-AllowWindowAttribution 是退路：沒有任何 agent 有紀錄時改取主執行緒（_main）的紀錄，attribution 為 window，只靠時間窗歸屬。
紀錄寫出之後刪除已採用的呼叫紀錄檔；Start 記下 .playwright-mcp 的檔案狀態，來源狀態雜湊排除該目錄。

stdout 輸出 ASCII 跳脫的 JSON（action、run_key、record_path、output_dir、report_path，Start 另有 model，審查類型另有 worktree_inventory_path 或（盤點失敗時）worktree_inventory_error；End 另有 result、failure_reason、source_changed、dispatch_changed、review_report_check，測試取證另有 mcp_tool_calls 摘要）。
診斷與錯誤寫 stderr。

.PARAMETER Action
Start 或 End。

.PARAMETER DispatchFile
派遣檔的絕對路徑（範本為 templates\dispatch\run-order.md），與 Codex 審查者使用同一份。

.PARAMETER ExecutorId
登錄表內平台為 claude 的執行者 id。

.PARAMETER RegistryPath
執行者登錄表路徑，測試與診斷用。預設為 scripts\dispatch\executor-registry.json。

.PARAMETER AiAgentsRoot
派遣檔 role_file 可位於其下的根目錄，測試與診斷用。預設為使用者目錄下的 .ai-agents。

.PARAMETER AgentId
End 時使用，測試取證類型的取證者 agent id（Agent 工具結果的 agentId）。省略時由呼叫紀錄的時間窗判定。不可為 _main（主執行緒的紀錄目錄），否則以結束碼 2（ClaudeRunAgentIdReserved）拒絕、紀錄維持未結束；主執行緒的紀錄只能經 -AllowWindowAttribution 取得。

.PARAMETER McpCallRoot
MCP 工具呼叫紀錄檔的根目錄，測試用。預設為 <LOCALAPPDATA>\ai-agents\mcp-calls。

.PARAMETER AllowWindowAttribution
End 時使用，只作退路：沒有任何 agent 有呼叫紀錄時改取主執行緒（_main）在時間窗內的紀錄，attribution 為 window。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Start', 'End')]
    [string]$Action,

    [Parameter(Mandatory)]
    [string]$DispatchFile,

    [Parameter(Mandatory)]
    [string]$ExecutorId,

    [string]$RegistryPath,

    [string]$AiAgentsRoot,

    [string]$AgentId,

    [string]$McpCallRoot,

    [switch]$AllowWindowAttribution
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)

$moduleRoot = Join-Path $PSScriptRoot 'codex-run'
foreach ($module in @('00-common.ps1', '10-order.ps1', '35-review-check.ps1', '45-profile-sync.ps1', '50-source-state.ps1', '55-mcp-evidence.ps1')) {
    . (Join-Path $moduleRoot $module)
}

function ConvertTo-RecordIsoTime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][DateTime]$Value)

    return $Value.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-UtcDateTime {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Value)

    # ConvertFrom-Json 會把 ISO 時間字串轉成 DateTime（Kind 為 Local 或 Utc），字串則視為 UTC。兩種輸入都不受本機時區影響。
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        return $Value.ToUniversalTime()
    }
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, $styles).UtcDateTime
}

function Find-OpenClaudeRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunsDirectory,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [Parameter(Mandatory)][string]$Executor
    )

    # 同一 dispatchSlug 與執行者、ended_utc 為 null 的紀錄。讀不懂的檔案視為未結束，避免在狀態不明時再開始。
    $prefix = $DispatchSlug + '-' + $Executor + '-'
    $open = New-Object 'System.Collections.Generic.List[object]'
    if (-not [IO.Directory]::Exists($RunsDirectory)) { return @() }
    foreach ($file in @(Get-ChildItem -LiteralPath $RunsDirectory -File -Filter '*.record.json' | Where-Object { $_.Name.StartsWith($prefix, [StringComparison]::Ordinal) } | Sort-Object -Property Name)) {
        try {
            $record = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file.FullName, (New-Object System.Text.UTF8Encoding -ArgumentList @($false)))) -AsHashtable -Depth 20
        }
        catch {
            $open.Add([pscustomobject]@{ Path = $file.FullName; Record = $null })
            continue
        }
        if ($record -is [System.Collections.IDictionary] -and $record['executor_platform'] -ceq 'claude' -and $record['executor_id'] -ceq $Executor -and $record['dispatch_slug'] -ceq $DispatchSlug -and $null -eq $record['ended_utc']) {
            $open.Add([pscustomobject]@{ Path = $file.FullName; Record = $record })
        }
    }
    return @($open.ToArray())
}

function Test-StartBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Record)

    # End 以初稿的基準核對，初稿缺少基準欄位時不能判定，拒絕而不猜測。
    if ($Record -isnot [System.Collections.IDictionary]) { return $false }
    foreach ($key in @('targets', 'report_check', 'execution_root', 'report_line_root', 'report_path', 'started_utc')) {
        if (-not $Record.Contains($key)) { return $false }
    }
    if ($Record['dispatch_file'] -isnot [System.Collections.IDictionary] -or [string]::IsNullOrWhiteSpace([string]$Record['dispatch_file']['sha256'])) { return $false }
    if ($Record['source_state_start'] -isnot [System.Collections.IDictionary]) { return $false }
    if ($null -eq $Record['targets'] -or $Record['targets'] -is [string] -or $Record['targets'] -isnot [System.Collections.IEnumerable] -or @($Record['targets']).Count -eq 0) { return $false }
    return $true
}

$lock = $null
try {
    if ($ExecutorId -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw (New-RunError -Code 'ClaudeRunExecutorInvalid' -Message ('執行者 id 格式無效：' + $ExecutorId) -ExitCode 2) }
    $registryFile = $RegistryPath
    if ([string]::IsNullOrWhiteSpace($registryFile)) { $registryFile = Join-Path $PSScriptRoot 'dispatch\executor-registry.json' }
    try { $registry = Read-ExecutorRegistry -Path $registryFile }
    catch { throw (New-RunError -Code 'ClaudeRunRegistryInvalid' -Message ('無法讀取執行者登錄表：' + $_.Exception.Message) -ExitCode 2) }
    if (-not $registry.ById.ContainsKey($ExecutorId)) { throw (New-RunError -Code 'ClaudeRunExecutorUnknown' -Message ('登錄表沒有執行者：' + $ExecutorId) -ExitCode 2) }
    $executor = $registry.ById[$ExecutorId]
    if ($executor.Platform -cne 'claude') { throw (New-RunError -Code 'ClaudeRunExecutorNotClaude' -Message ('執行者 ' + $ExecutorId + ' 的平台是 ' + $executor.Platform + '，本腳本只記錄 Claude 執行者；Codex 執行者由 Invoke-CodexRun.ps1 記錄。') -ExitCode 2) }

    $dispatchPath = [IO.Path]::GetFullPath($DispatchFile)
    $order = Read-RunDispatchFile -Path $dispatchPath
    $runsDirectory = Join-Path $order.report_line_root 'runs'
    $lockPath = Join-Path $runsDirectory ($order.dispatch_slug + '-' + $ExecutorId + '.lock')

    if ($Action -ceq 'Start') {
        if ($executor.Accepts -cnotcontains $order.task_type) { throw (New-RunError -Code 'ClaudeRunTaskTypeNotAccepted' -Message ('執行者 ' + $ExecutorId + ' 不受理 ' + $order.task_type + ' 類型。') -ExitCode 2) }
        # 目標、role_file 與必讀檔必須存在，只在 Start 檢查；End 時目標被刪除是要記錄的結果，不是拒絕的理由。
        $preStartArgument = @{ Order = $order }
        if (-not [string]::IsNullOrWhiteSpace($AiAgentsRoot)) { $preStartArgument['AiAgentsRoot'] = $AiAgentsRoot }
        Test-RunPreStart @preStartArgument

        $lock = Enter-RunFileLock -Path $lockPath
        $open = @(Find-OpenClaudeRecord -RunsDirectory $runsDirectory -DispatchSlug $order.dispatch_slug -Executor $ExecutorId)
        if ($open.Count -gt 0) {
            throw (New-RunError -Code 'ClaudeRunAlreadyStarted' -Message ('同一派遣與執行者已有未結束的紀錄：' + $open[0].Path + '。先對該次執行 -Action End，再重新 Start。') -ExitCode 2)
        }
        $runId = $null
        for ($attempt = 0; $attempt -lt 5 -and $null -eq $runId; $attempt++) {
            $candidate = New-RunId
            $candidateKey = $order.dispatch_slug + '-' + $ExecutorId + '-' + $candidate
            if (-not [IO.Directory]::Exists((Join-Path $runsDirectory $candidateKey)) -and -not [IO.File]::Exists((Join-Path $runsDirectory ($candidateKey + '.record.json')))) { $runId = $candidate }
        }
        if ($null -eq $runId) { throw (New-RunError -Code 'ClaudeRunIdCollision' -Message ('連續取得的 run id 都已存在於 ' + $runsDirectory + '，未建立紀錄。') -ExitCode 1) }
        $runKey = $order.dispatch_slug + '-' + $ExecutorId + '-' + $runId
        $outputDirectory = Join-Path $runsDirectory $runKey
        $recordPath = Join-Path $runsDirectory ($runKey + '.record.json')
        $reportPath = Join-Path $outputDirectory $order.report_name
        $null = [IO.Directory]::CreateDirectory($outputDirectory)
        # 審查：Claude 審查者同樣讀入口產生的工作樹盤點檔。只有 RunWorktreeInventoryFailed 不停止 Start：警告後續行並在紀錄記下錯誤，其他錯誤照舊往外拋。
        $worktreeInventory = $null
        $inventoryError = $null
        $inventoryAttempted = ($order.task_type -ceq 'review')
        if ($inventoryAttempted) {
            $inventoryFile = Join-Path $outputDirectory 'worktree-inventory.md'
            try {
                $worktreeInventory = Write-RunWorktreeInventory -ExecutionRoot $order.execution_root -Target @($order.targets) -OutputPath $inventoryFile -ExcludeRoot @($order.report_line_root)
            }
            catch {
                if (-not ($_.Exception.Data.Contains('Code') -and [string]$_.Exception.Data['Code'] -ceq 'RunWorktreeInventoryFailed')) { throw }
                $inventoryError = $_.Exception.Message
                $worktreeInventory = $null
                if ([IO.File]::Exists($inventoryFile)) { [IO.File]::Delete($inventoryFile) }
                [Console]::Error.WriteLine('[claude-run-record] 工作樹盤點檔產生失敗，Start 照常完成且不提供盤點檔：' + $inventoryError)
            }
        }
        $startedAt = [DateTime]::UtcNow
        # 測試取證：Playwright MCP 的檔案可能寫到工作目錄根下的 .playwright-mcp（明確檔名或登記未設輸出目錄時），不納入來源雜湊，另以 mcp_stray_output 記錄 Start 與 End 之間新增或變動的檔案。
        $isTest = ($order.task_type -ceq 'test')
        $sourceExclude = @($order.report_line_root)
        $strayState = $null
        if ($isTest) {
            $strayMcpOutput = Join-Path $order.execution_root '.playwright-mcp'
            $sourceExclude += $strayMcpOutput
            $strayBefore = Get-RunDirectoryFileState -Path $strayMcpOutput
            $strayState = [ordered]@{ path = $strayMcpOutput; ok = $strayBefore.ok; files = $strayBefore.files; error = $strayBefore.error }
        }
        $sourceStart = Get-RunSourceState -ExecutionRoot $order.execution_root -Target $order.targets -ExcludeRoot $sourceExclude
        $record = [ordered]@{
            schema = 'ai-agents.claude-run-record.v1'
            executor_platform = 'claude'
            executor_id = $ExecutorId
            run_key = $runKey
            run_id = $runId
            line_slug = $order.line_slug
            dispatch_slug = $order.dispatch_slug
            task_type = $order.task_type
            profile = $order.profile
            cycle_id = if ($null -eq $order.cycle) { $null } else { [string]$order.cycle.id }
            cycle_round = if ($null -eq $order.cycle) { $null } else { [long]$order.cycle.round }
            cycle_role = if ($null -eq $order.cycle) { $null } else { [string]$order.cycle.role }
            dispatch_file = [ordered]@{ path = $order.dispatch_file_path; sha256 = (Get-RunSha256File -Path $dispatchPath) }
            targets = @($order.targets)
            report_check = [string]$order.task_setting.report_check
            report_line_root = $order.report_line_root
            account = $null
            model = $executor.Model
            model_source = $null
            execution_root = $order.execution_root
            output_dir = $outputDirectory
            report_path = $reportPath
            started_utc = ConvertTo-RecordIsoTime -Value $startedAt
            timeout_seconds = $null
            turn_end_grace_seconds = $null
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
            last_message = $null
            events_path = $null
            stderr_path = $null
            report = $null
            review_report_check = $null
            permission = $null
            mcp_tool_calls = $null
            artifacts = $null
            mcp_stray_output = $null
        }
        if ($isTest) { $record['mcp_stray_state_start'] = $strayState }
        $startOutput = [ordered]@{ action = 'Start'; run_key = $runKey; record_path = $recordPath; output_dir = $outputDirectory; report_path = $reportPath; model = $executor.Model }
        if ($null -ne $worktreeInventory) {
            $record['worktree_inventory'] = [ordered]@{ path = $worktreeInventory.path; sha256 = $worktreeInventory.sha256; bytes = $worktreeInventory.bytes; head = $worktreeInventory.head; sha256_end = $null; error = $null }
            $startOutput['worktree_inventory_path'] = $worktreeInventory.path
        }
        elseif ($inventoryAttempted) {
            $record['worktree_inventory'] = [ordered]@{ path = $null; sha256 = $null; bytes = $null; head = $null; sha256_end = $null; error = $inventoryError }
            $startOutput['worktree_inventory_error'] = $inventoryError
        }
        Write-RunJsonAtomic -Path $recordPath -InputObject $record -Depth 8
        $lock.Dispose()
        $lock = $null
        [Console]::Out.WriteLine((ConvertTo-AsciiJson -InputObject $startOutput -Depth 4 -Compress))
        exit 0
    }

    # End：只對恰好一份未結束的紀錄動作，並以該紀錄記下的 Start 基準核對。
    $notStarted = New-RunError -Code 'ClaudeRunNotStarted' -Message ('找不到未結束的紀錄（dispatchSlug ' + $order.dispatch_slug + '、執行者 ' + $ExecutorId + '）。請先 -Action Start。') -ExitCode 2
    if (-not [IO.Directory]::Exists($runsDirectory)) { throw $notStarted }
    $lock = Enter-RunFileLock -Path $lockPath
    $open = @(Find-OpenClaudeRecord -RunsDirectory $runsDirectory -DispatchSlug $order.dispatch_slug -Executor $ExecutorId)
    if ($open.Count -eq 0) { throw $notStarted }
    if ($open.Count -gt 1 -or $null -eq $open[0].Record) { throw (New-RunError -Code 'ClaudeRunAmbiguous' -Message ('未結束的紀錄不只一份或無法讀取，請人工處理：' + (($open | ForEach-Object { $_.Path }) -join '；')) -ExitCode 2) }
    $recordPath = $open[0].Path
    $record = $open[0].Record
    if (-not (Test-StartBaseline -Record $record)) { throw (New-RunError -Code 'ClaudeRunRecordIncomplete' -Message ('未結束的紀錄缺少 Start 基準欄位，無法核對，請人工處理：' + $recordPath) -ExitCode 2) }
    $endedAt = [DateTime]::UtcNow

    $dispatchEndHash = Get-RunSha256File -Path $dispatchPath
    $dispatchChanged = ($dispatchEndHash -cne [string]$record['dispatch_file']['sha256'])

    # 目標在 Start 之後被刪除或狀態無法計算時，視為來源已變並照常寫出紀錄。
    $sourceChanged = $false
    $sourceEnd = $null
    $sourceStateError = $null
    $isTest = ([string]$record['task_type'] -ceq 'test')
    $strayMcpOutput = $null
    $sourceExclude = @([string]$record['report_line_root'])
    if ($isTest) {
        $strayMcpOutput = [IO.Path]::Combine([string]$record['execution_root'], '.playwright-mcp')
        $sourceExclude += $strayMcpOutput
    }

    # 測試取證：MCP 工具呼叫彙整。多個 agent 在時間窗內都有紀錄而未指定 -AgentId 時在這裡以結束碼 2 拒絕，紀錄維持未結束。
    $mcpToolCalls = $null
    $adoptedCallFiles = @()
    $artifacts = $null
    $mcpStrayOutput = $null
    if ($isTest) {
        if ([string]::IsNullOrWhiteSpace($McpCallRoot) -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $McpCallRoot = Join-Path $env:LOCALAPPDATA 'ai-agents\mcp-calls' }
        $callSummary = Get-ClaudeMcpToolCallSummary -CallRoot $McpCallRoot -StartedUtc (ConvertTo-UtcDateTime -Value $record['started_utc']) -EndedUtc $endedAt -AgentId $AgentId -AllowWindowAttribution:$AllowWindowAttribution
        $mcpToolCalls = $callSummary.Summary
        $adoptedCallFiles = @($callSummary.AdoptedFiles)
        $artifacts = Get-RunOutputArtifact -OutputDirectory ([string]$record['output_dir']) -ReportName ([IO.Path]::GetFileName([string]$record['report_path']))
        $strayBefore = if ($record.Contains('mcp_stray_state_start') -and $record['mcp_stray_state_start'] -is [System.Collections.IDictionary]) { $record['mcp_stray_state_start'] } else { $null }
        $strayAfter = Get-RunDirectoryFileState -Path $strayMcpOutput
        if ($null -ne $strayBefore -and $strayBefore['ok'] -eq $true -and $strayBefore['files'] -is [System.Collections.IDictionary] -and $strayAfter.ok) {
            $beforeFiles = $strayBefore['files']
            $strayChanged = @($strayAfter.files.Keys | Where-Object { -not $beforeFiles.Contains($_) -or [string]$beforeFiles[$_] -cne [string]$strayAfter.files[$_] } | Sort-Object)
            $mcpStrayOutput = [ordered]@{ path = $strayMcpOutput; state = 'determined'; exists = ($strayChanged.Count -gt 0); files = [string[]]$strayChanged; error = $null }
        }
        else {
            # 列舉失敗或 Start 沒有可比對的基準時無法判定是否有本次殘留：exists 為 null，state 為 indeterminate，回收時人工檢查該目錄。
            $strayError = if ($null -eq $strayBefore) { 'Start 沒有記下 .playwright-mcp 的檔案狀態' } elseif ($strayBefore['ok'] -ne $true) { [string]$strayBefore['error'] } else { [string]$strayAfter.error }
            [Console]::Error.WriteLine('[claude-run-record] 無法判定 ' + $strayMcpOutput + ' 的殘留狀態：' + $strayError)
            $mcpStrayOutput = [ordered]@{ path = $strayMcpOutput; state = 'indeterminate'; exists = $null; files = [string[]]@(); error = $strayError }
        }
    }

    try {
        $sourceEnd = Get-RunSourceState -ExecutionRoot ([string]$record['execution_root']) -Target ([string[]]@($record['targets'])) -ExcludeRoot $sourceExclude
        # 逐欄比對，不依賴 JSON 鍵順序（讀回的紀錄是 hashtable）。
        foreach ($key in @('mode', 'head', 'diff_sha256', 'content_sha256')) {
            if ([string]$record['source_state_start'][$key] -cne [string]$sourceEnd.$key) { $sourceChanged = $true }
        }
    }
    catch {
        $sourceEnd = $null
        $sourceChanged = $true
        $sourceStateError = $_.Exception.Message
        [Console]::Error.WriteLine('[claude-run-record] 來源狀態計算失敗，視為來源已變：' + $sourceStateError)
    }
    foreach ($target in @($record['targets'])) {
        if (-not ([IO.File]::Exists([string]$target) -or [IO.Directory]::Exists([string]$target))) { $sourceChanged = $true }
    }

    $reportPath = [string]$record['report_path']
    $reportInfo = New-Object System.IO.FileInfo -ArgumentList @($reportPath)
    $reviewCheck = $null
    if ($reportInfo.Exists -and $reportInfo.Length -gt 0 -and [string]$record['report_check'] -ceq 'review-manifest') {
        $checked = Test-RunReviewReport -ReportPath $reportPath
        $reviewCheck = [ordered]@{ valid = $checked.valid; errors = @($checked.errors) }
    }
    $failureReason = $null
    if ($sourceChanged) { $failureReason = 'source-changed' }
    elseif ($dispatchChanged) { $failureReason = 'dispatch-changed' }
    elseif (-not $reportInfo.Exists -or $reportInfo.Length -eq 0) { $failureReason = 'report-missing' }
    elseif ($null -ne $reviewCheck -and -not $reviewCheck.valid) { $failureReason = 'review-report-invalid' }
    $result = if ($null -eq $failureReason) { 'success' } else { 'failed' }
    $startedAt = ConvertTo-UtcDateTime -Value $record['started_utc']

    $record['ended_utc'] = ConvertTo-RecordIsoTime -Value $endedAt
    $record['duration_seconds'] = [Math]::Round(($endedAt - $startedAt).TotalSeconds, 1)
    $record['dispatch_file']['sha256_end'] = $dispatchEndHash
    $record['source_state_end'] = $sourceEnd
    if ($null -ne $sourceStateError) { $record['source_state_error'] = $sourceStateError }
    $record['source_changed'] = $sourceChanged
    $record['result'] = $result
    $record['failure_reason'] = $failureReason
    $record['report'] = [ordered]@{ exists = $reportInfo.Exists; bytes = if ($reportInfo.Exists) { $reportInfo.Length } else { 0 } }
    $record['review_report_check'] = $reviewCheck
    if ($isTest) {
        $record['mcp_tool_calls'] = $mcpToolCalls
        $record['artifacts'] = $artifacts
        $record['mcp_stray_output'] = $mcpStrayOutput
    }
    if ($record.Contains('worktree_inventory') -and $record['worktree_inventory'] -is [System.Collections.IDictionary]) {
        # 盤點檔在執行期間被改或被刪時只記錄不一致（sha256_end 與 sha256 不同或為 null），不影響 result。
        # 盤點產生失敗時 path 為 null，sha256_end 維持 null。
        if ($null -ne $record['worktree_inventory']['path']) {
            $inventoryPath = [string]$record['worktree_inventory']['path']
            $inventoryEnd = try { if ([IO.File]::Exists($inventoryPath)) { Get-RunSha256File -Path $inventoryPath } else { $null } } catch { $null }
            $record['worktree_inventory']['sha256_end'] = $inventoryEnd
        }
    }
    Write-RunJsonAtomic -Path $recordPath -InputObject $record -Depth 8
    # 已採用的呼叫紀錄檔內容已在紀錄的 calls，紀錄寫出之後刪除，避免累積；刪除失敗只警告。未採用的其他 agent 的檔案不動。
    foreach ($adoptedFile in $adoptedCallFiles) {
        try { [IO.File]::Delete($adoptedFile) }
        catch { [Console]::Error.WriteLine('[claude-run-record] 無法刪除已採用的呼叫紀錄檔 ' + $adoptedFile + '：' + $_.Exception.Message) }
    }
    $lock.Dispose()
    $lock = $null
    $endOutput = [ordered]@{
        action = 'End'; run_key = $record['run_key']; record_path = $recordPath; output_dir = $record['output_dir']; report_path = $reportPath
        result = $result; failure_reason = $failureReason; source_changed = $sourceChanged; dispatch_changed = $dispatchChanged; review_report_check = $reviewCheck
    }
    if ($isTest) { $endOutput['mcp_tool_calls'] = [ordered]@{ completed = $mcpToolCalls.completed; failed = $mcpToolCalls.failed; servers = $mcpToolCalls.servers; attribution = $mcpToolCalls.attribution } }
    [Console]::Out.WriteLine((ConvertTo-AsciiJson -InputObject $endOutput -Depth 6 -Compress))
    exit $(if ($result -ceq 'success') { 0 } else { 1 })
}
catch {
    $exception = $_.Exception
    if ($null -ne $lock) { $lock.Dispose() }
    if ($exception.Data.Contains('Code')) {
        [Console]::Error.WriteLine('[claude-run-record] ' + $exception.Message)
        exit ([int]$exception.Data['ExitCode'])
    }
    [Console]::Error.WriteLine('[claude-run-record] 未預期的錯誤：' + $exception.Message)
    exit 1
}
