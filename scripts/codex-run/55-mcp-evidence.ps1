#Requires -Version 7.0
# 測試取證的 MCP 證據：Codex 入口（70-run.ps1）與 Claude 執行紀錄（Write-ClaudeRunRecord.ps1）共用。
# Get-RunDirectoryFileState 與 Get-RunOutputArtifact 比對輸出目錄與 .playwright-mcp 的檔案；
# Get-ClaudeMcpToolCallSummary 讀 ai-agents-hooks 寫下的 MCP 工具呼叫紀錄檔，彙整成與 Codex 事件流（Get-RunMcpToolCallSummary）同欄位的次數與伺服器。
# 依賴 00-common.ps1（New-RunError）。

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

function ConvertTo-McpCallUtc {
    # 呼叫紀錄的 ts_utc。ConvertFrom-Json 可能已把 ISO 字串轉成 DateTime，兩種形式都轉成 UTC；無法解析時回傳 $null。
    param($Value)

    try {
        if ($Value -is [DateTime]) {
            if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
            return $Value.ToUniversalTime()
        }
        if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $null }
        $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        return [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, $styles).UtcDateTime
    }
    catch { return $null }
}

function Read-McpCallRecordDirectory {
    # 讀一個 agent 目錄（或 _main）下的呼叫紀錄檔。回傳 Valid（Path、Time、ToolName、Server、Status）與 Skipped（無法剖析、欄位缺少、時間不可解析，或檔案內 agent_id 與所在目錄不符的檔案件數）。
    # ExpectedAgentId：agent 目錄傳目錄名稱，檔案內的 agent_id 須與它完全相同；_main 目錄傳 $null，檔案內的 agent_id 須為 null 或不存在。不符者放錯目錄，歸屬不可信，計入 Skipped。
    param(
        [Parameter(Mandatory)][string]$Directory,
        [AllowNull()][AllowEmptyString()][string]$ExpectedAgentId
    )

    $valid = New-Object 'System.Collections.Generic.List[object]'
    $skipped = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
        # -NoEnumerate：根層為單元素陣列時保留陣列，不展開成其中的物件，使下方的 IDictionary 檢查把它計入 skipped。
        try { $parsed = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file.FullName, (New-Object System.Text.UTF8Encoding -ArgumentList @($false)))) -AsHashtable -Depth 10 -NoEnumerate }
        catch { $skipped++; continue }
        if ($parsed -isnot [System.Collections.IDictionary]) { $skipped++; continue }
        # 在分支內直接指派，不以 if 運算式的輸出指派：運算式輸出會把單元素陣列展開成純量，使 ["agent-a"] 誤通過字串檢查。
        $recordedAgent = $null
        if ($parsed.Contains('agent_id')) { $recordedAgent = $parsed['agent_id'] }
        if ([string]::IsNullOrEmpty($ExpectedAgentId)) { if ($null -ne $recordedAgent) { $skipped++; continue } }
        elseif ($recordedAgent -isnot [string] -or $recordedAgent -cne $ExpectedAgentId) { $skipped++; continue }
        # 與 agent_id 相同，各欄位在分支內直接指派，保留原始型別；陣列等非字串值在下方的型別檢查計入 skipped。
        $rawTime = $null; $tool = $null; $server = $null; $status = $null
        if ($parsed.Contains('ts_utc')) { $rawTime = $parsed['ts_utc'] }
        if ($parsed.Contains('tool_name')) { $tool = $parsed['tool_name'] }
        if ($parsed.Contains('server')) { $server = $parsed['server'] }
        if ($parsed.Contains('status')) { $status = $parsed['status'] }
        $time = $null
        if ($rawTime -is [string] -or $rawTime -is [DateTime]) { $time = ConvertTo-McpCallUtc -Value $rawTime }
        if ($null -eq $time -or $status -isnot [string] -or $tool -isnot [string] -or [string]::IsNullOrWhiteSpace($tool) -or $server -isnot [string] -or [string]::IsNullOrWhiteSpace($server) -or $status -cnotin @('completed', 'failed')) { $skipped++; continue }
        $valid.Add([pscustomobject]@{ Path = $file.FullName; Time = $time; ToolName = $tool; Server = $server; Status = $status })
    }
    return [pscustomobject]@{ Valid = @($valid.ToArray()); Skipped = $skipped }
}

function Get-ClaudeMcpToolCallSummary {
    [CmdletBinding()]
    param(
        # ai-agents-hooks 寫呼叫紀錄的根目錄（<LOCALAPPDATA>\ai-agents\mcp-calls）。省略、空白或目錄不存在時視為沒有任何紀錄。
        [AllowNull()][AllowEmptyString()][string]$CallRoot,
        [Parameter(Mandatory)][DateTime]$StartedUtc,
        [Parameter(Mandatory)][DateTime]$EndedUtc,
        # 取證者的 agent id（Agent 工具結果的 agentId）。省略時由時間窗內唯一有紀錄的 agent 目錄判定。_main 不是有效的 agent id，以 ClaudeRunAgentIdReserved（結束碼 2）拒絕。
        [AllowNull()][AllowEmptyString()][string]$AgentId,
        # 只作退路：沒有任何 agent 目錄有紀錄時，改取主執行緒（_main）在時間窗內的紀錄，attribution 為 window。
        [switch]$AllowWindowAttribution
    )

    # 回傳 Summary（completed、failed、servers、tools、attribution、calls、skipped；與 Codex 的 mcp_tool_calls 同名欄位，tools、attribution、calls、skipped 為 Claude 專有）
    # 與 AdoptedFiles（已彙整進 Summary 的呼叫紀錄檔，供呼叫端在紀錄寫出後刪除）。
    # attribution：agent（依 agent id 歸屬）、window（只靠時間窗的 _main 退路）、none（沒有任何紀錄）。
    # 時間窗外的紀錄與未採用的其他 agent 的檔案不計入、不採用。多個 agent 在時間窗內都有紀錄且未指定 AgentId 時，以 ClaudeRunAgentAmbiguous（結束碼 2）拒絕並列出候選。
    $adopted = New-Object 'System.Collections.Generic.List[object]'
    $skipped = 0
    $attribution = 'none'
    $startedUtcValue = $StartedUtc.ToUniversalTime()
    $endedUtcValue = $EndedUtc.ToUniversalTime()
    $inWindow = { param($records) @($records | Where-Object { $_.Time -ge $startedUtcValue -and $_.Time -le $endedUtcValue }) }

    # AgentId 的驗證不依賴紀錄根目錄是否存在，使無紀錄時明示的無效或保留 id 同樣被拒絕。
    if (-not [string]::IsNullOrEmpty($AgentId)) {
        if ($AgentId -cnotmatch '^[A-Za-z0-9_-]{1,128}$') { throw (New-RunError -Code 'ClaudeRunAgentIdInvalid' -Message ('agent id 格式無效：' + $AgentId) -ExitCode 2) }
        # _main 是主執行緒（沒有 agent_id 的事件）的目錄，不是 agent；Windows 目錄名不分大小寫，一併拒絕不同大小寫的寫法。
        if ($AgentId -ieq '_main') { throw (New-RunError -Code 'ClaudeRunAgentIdReserved' -Message 'ClaudeRunAgentIdReserved：_main 是主執行緒的紀錄目錄，不能當作 agent id；主執行緒的紀錄只能經 -AllowWindowAttribution 取得，歸屬為 window。' -ExitCode 2) }
    }

    if (-not [string]::IsNullOrWhiteSpace($CallRoot) -and [IO.Directory]::Exists($CallRoot)) {
        if (-not [string]::IsNullOrEmpty($AgentId)) {
            $agentDirectory = Join-Path $CallRoot $AgentId
            if ([IO.Directory]::Exists($agentDirectory)) {
                # 檔案內的 agent_id 與目錄名稱比對；目錄名稱取磁碟上的實際拼法。
                $actualName = @(Get-ChildItem -LiteralPath $CallRoot -Directory | Where-Object { $_.Name -ieq $AgentId } | ForEach-Object { $_.Name })[0]
                $read = Read-McpCallRecordDirectory -Directory $agentDirectory -ExpectedAgentId $actualName
                $skipped += $read.Skipped
                foreach ($record in (& $inWindow $read.Valid)) { $adopted.Add($record) }
                if ($adopted.Count -gt 0) { $attribution = 'agent' }
            }
        }
        else {
            $agentRecords = [ordered]@{}
            $agentSkipped = [ordered]@{}
            foreach ($directory in @(Get-ChildItem -LiteralPath $CallRoot -Directory | Where-Object { $_.Name -ine '_main' } | Sort-Object -Property Name)) {
                $read = Read-McpCallRecordDirectory -Directory $directory.FullName -ExpectedAgentId $directory.Name
                $agentSkipped[$directory.Name] = $read.Skipped
                $windowed = @(& $inWindow $read.Valid)
                if ($windowed.Count -gt 0) { $agentRecords[$directory.Name] = $windowed }
            }
            if ($agentRecords.Count -gt 1) {
                throw (New-RunError -Code 'ClaudeRunAgentAmbiguous' -Message ('ClaudeRunAgentAmbiguous：時間窗內有多個 agent 的 MCP 呼叫紀錄，無法判定哪一個是取證者：' + (@($agentRecords.Keys) -join '、') + '。以 -AgentId 指定後重新 End（紀錄維持未結束）。') -ExitCode 2)
            }
            if ($agentRecords.Count -eq 1) {
                $only = @($agentRecords.Keys)[0]
                foreach ($record in $agentRecords[$only]) { $adopted.Add($record) }
                $skipped += $agentSkipped[$only]
                $attribution = 'agent'
            }
            else {
                foreach ($name in $agentSkipped.Keys) { $skipped += $agentSkipped[$name] }
                $mainDirectory = Join-Path $CallRoot '_main'
                if ($AllowWindowAttribution -and [IO.Directory]::Exists($mainDirectory)) {
                    $read = Read-McpCallRecordDirectory -Directory $mainDirectory -ExpectedAgentId $null
                    $skipped += $read.Skipped
                    foreach ($record in (& $inWindow $read.Valid)) { $adopted.Add($record) }
                    if ($adopted.Count -gt 0) { $attribution = 'window' }
                }
            }
        }
    }

    $completed = @($adopted | Where-Object { $_.Status -ceq 'completed' }).Count
    $failed = @($adopted | Where-Object { $_.Status -ceq 'failed' }).Count
    $servers = [string[]]@($adopted | ForEach-Object { $_.Server } | Sort-Object -Unique -CaseSensitive)
    $tools = [string[]]@($adopted | ForEach-Object { $_.ToolName } | Sort-Object -Unique -CaseSensitive)
    $calls = @($adopted | Sort-Object -Property Time, ToolName | ForEach-Object {
            [ordered]@{ ts_utc = $_.Time.ToString('o', [Globalization.CultureInfo]::InvariantCulture); tool_name = $_.ToolName; status = $_.Status }
        })
    $summary = [ordered]@{ completed = $completed; failed = $failed; servers = $servers; tools = $tools; attribution = $attribution; calls = $calls; skipped = $skipped }
    return [pscustomobject]@{ Summary = $summary; AdoptedFiles = [string[]]@($adopted | ForEach-Object { $_.Path }) }
}
