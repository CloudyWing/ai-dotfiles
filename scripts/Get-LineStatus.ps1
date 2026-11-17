#Requires -Version 7.0

<#
.SYNOPSIS
彙整各 work-root 的線狀態、Git 狀態與 Codex 額度，唯讀輸出。

.DESCRIPTION
掃描 work-root 清單下的 .local\ai-sessions\handoff\*\line.json，讀取同線
report\<lineSlug>\handoff-checkpoint.md 的檢查點類型與下一站，加上該 work-root 的
分支、未 commit 檔案數、相對主分支與 upstream 的 ahead/behind，以及 machine.json
codex_accounts 各帳號的額度摘要。

另彙整 Invoke-CodexRun.ps1 在各 work-root 的 report\<lineSlug>\runs\ 寫出的執行紀錄：
執行中、已超過時限（最後活動在 24 小時內）與最近結束的派工，以及各登記帳號最近一次的結果與
codex-account-health.json 中未過期的不支援 model 項目。

腳本不寫入任何檔案。Git 以 --no-optional-locks 執行，避免 status 更新 index。
執行紀錄只讀 *.record.json 與同名 events.jsonl 的最後寫入時間，不讀事件內容與報告。

.PARAMETER WorkRoot
要掃描的 work-root 清單，可含萬用字元或以分號分隔。預設包含 .ai-agents、.ai-agents.wt 與 Desktop worktree 目錄。

.PARAMETER MachineConfigPath
machine.json 路徑，讀取其中的 codex_accounts。

.PARAMETER ForceWorkRoot
以分號分隔的路徑清單，不展開萬用字元。即使沒有 handoff 目錄仍列出 work-root 並納入 scannedRoots；不存在或非資料夾者略過。

.PARAMETER WithCheckpointOnly
只列出有 handoff-checkpoint.md 的線。

.PARAMETER SkipQuota
不查詢 Codex 額度。

.PARAMETER AsJson
輸出 JSON，供面板或其他工具讀取。
#>
[CmdletBinding()]
param(
    [string[]]$WorkRoot = @(
        (Join-Path -Path $env:USERPROFILE -ChildPath '.ai-agents'),
        (Join-Path -Path $env:USERPROFILE -ChildPath '.ai-agents.wt\*'),
        (Join-Path -Path $env:USERPROFILE -ChildPath '.ai-agents\.claude\worktrees\*'),
        'D:\Programming\Projects\.claude-worktrees\.ai-agents\*'
    ),

    [string]$MachineConfigPath = (Join-Path -Path $env:USERPROFILE -ChildPath '.ai-agents\.local\machine.json'),

    [string[]]$ForceWorkRoot = @(),

    [switch]$WithCheckpointOnly,

    [switch]$SkipQuota,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WorkRoot = @($WorkRoot | ForEach-Object { $_ -split ';' } | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
$ForceWorkRoot = @($ForceWorkRoot | ForEach-Object { $_ -split ';' } | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
if ($WorkRoot.Count -eq 0) {
    $WorkRoot = @(
        (Join-Path -Path $env:USERPROFILE -ChildPath '.ai-agents'),
        (Join-Path -Path $env:USERPROFILE -ChildPath '.ai-agents.wt\*'),
        (Join-Path -Path $env:USERPROFILE -ChildPath '.ai-agents\.claude\worktrees\*'),
        'D:\Programming\Projects\.claude-worktrees\.ai-agents\*'
    )
}
$script:Warnings = New-Object 'System.Collections.Generic.List[string]'
# 仍無結果且最後活動已超過 24 小時的派工不再列出，與新入口記錄帳號不支援 model 的保留時間相同。
$script:AbandonAfterSeconds = 24 * 60 * 60
# 紀錄自帶時限時，近期事件門檻的下限，與新入口 Invoke-CodexRunMain 預設的回合結束寬限相同。
$script:MinSilenceSeconds = 60

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [string]$WorkingDirectory,

        [int]$TimeoutSeconds = 60
    )

    $startInfo = New-Object -TypeName System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = ($ArgumentList | ForEach-Object { ConvertTo-CommandLineArgument -Value $_ }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }

    $process = New-Object -TypeName System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            throw ('{0} 逾時（{1} 秒）' -f $FilePath, $TimeoutSeconds)
        }
        $process.WaitForExit()

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdoutTask.Result
            StdErr   = $stderrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

function ConvertTo-CommandLineArgument {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value -notmatch '[\s"]' -and $Value.Length -gt 0) {
        return $Value
    }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')

    return '"' + $escaped + '"'
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $allArguments = @('--no-optional-locks', '-C', $Root) + $Arguments

    return Invoke-ExternalCommand -FilePath 'git' -ArgumentList $allArguments
}

function Resolve-WorkRootList {
    param(
        [Parameter(Mandatory)]
        [string[]]$Patterns
    )

    $resolved = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($pattern in $Patterns) {
        $items = @(Get-Item -Path $pattern -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer })
        foreach ($item in $items) {
            $fullName = $item.FullName.TrimEnd('\')
            if (-not $resolved.Contains($fullName)) {
                $resolved.Add($fullName)
            }
        }
    }

    return , $resolved.ToArray()
}

function Resolve-ForceRootList {
    param([string[]]$Paths)

    $list = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($path in $Paths) {
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($null -eq $item -or -not $item.PSIsContainer) { continue }
        $fullName = $item.FullName.TrimEnd('\')
        if ($list -notcontains $fullName) { $list.Add($fullName) }
    }
    return , $list.ToArray()
}

function Get-MainBranchName {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $originHead = Invoke-Git -Root $Root -Arguments @('symbolic-ref', '--short', 'refs/remotes/origin/HEAD')
    if ($originHead.ExitCode -eq 0) {
        $name = $originHead.StdOut.Trim() -replace '^origin/', ''
        $local = Invoke-Git -Root $Root -Arguments @('rev-parse', '--verify', '-q', ('refs/heads/' + $name))
        if ($local.ExitCode -eq 0) {
            return $name
        }

        throw ('origin/HEAD 指向 {0}，但本機沒有該分支' -f $name)
    }

    foreach ($candidate in @('main', 'master')) {
        $local = Invoke-Git -Root $Root -Arguments @('rev-parse', '--verify', '-q', ('refs/heads/' + $candidate))
        if ($local.ExitCode -eq 0) {
            return $candidate
        }
    }

    throw '無法判定主分支（origin/HEAD、main、master 皆不存在）'
}

function Get-AheadBehind {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$BaseRef
    )

    $counts = Invoke-Git -Root $Root -Arguments @('rev-list', '--left-right', '--count', ($BaseRef + '...HEAD'))
    if ($counts.ExitCode -ne 0) {
        throw ('rev-list {0}...HEAD 失敗：{1}' -f $BaseRef, $counts.StdErr.Trim())
    }
    $parts = $counts.StdOut.Trim() -split '\s+'

    return [pscustomobject]@{
        Behind = [int]$parts[0]
        Ahead  = [int]$parts[1]
    }
}

function Get-WorkRootGitStatus {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $status = [ordered]@{
        Path             = $Root
        IsLinkedWorktree = $null
        Branch           = $null
        MainBranch       = $null
        DirtyCount       = $null
        MainAhead        = $null
        MainBehind       = $null
        Upstream         = $null
        UpstreamAhead    = $null
        UpstreamBehind   = $null
        Error            = $null
    }

    try {
        $inside = Invoke-Git -Root $Root -Arguments @('rev-parse', '--is-inside-work-tree')
        if ($inside.ExitCode -ne 0 -or $inside.StdOut.Trim() -ne 'true') {
            throw '不是 Git 工作樹'
        }

        $gitDir = Invoke-Git -Root $Root -Arguments @('rev-parse', '--git-dir')
        $commonDir = Invoke-Git -Root $Root -Arguments @('rev-parse', '--git-common-dir')
        if ($gitDir.ExitCode -ne 0 -or $commonDir.ExitCode -ne 0) { throw '無法取得 Git 目錄' }
        $gitPath = [IO.Path]::GetFullPath([IO.Path]::Combine($Root, $gitDir.StdOut.Trim()))
        $commonPath = [IO.Path]::GetFullPath([IO.Path]::Combine($Root, $commonDir.StdOut.Trim()))
        $status.IsLinkedWorktree = -not [string]::Equals($gitPath, $commonPath, [StringComparison]::OrdinalIgnoreCase)

        $branch = Invoke-Git -Root $Root -Arguments @('branch', '--show-current')
        $status.Branch = $branch.StdOut.Trim()
        if ([string]::IsNullOrEmpty($status.Branch)) {
            $status.Branch = '(detached)'
        }

        $porcelain = Invoke-Git -Root $Root -Arguments @('status', '--porcelain')
        if ($porcelain.ExitCode -ne 0) {
            throw ('git status 失敗：{0}' -f $porcelain.StdErr.Trim())
        }
        $status.DirtyCount = @($porcelain.StdOut -split "`n" | Where-Object { $_.Trim().Length -gt 0 }).Count

        $status.MainBranch = Get-MainBranchName -Root $Root
        $mainCounts = Get-AheadBehind -Root $Root -BaseRef ('refs/heads/' + $status.MainBranch)
        $status.MainAhead = $mainCounts.Ahead
        $status.MainBehind = $mainCounts.Behind

        $upstream = Invoke-Git -Root $Root -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
        if ($upstream.ExitCode -eq 0) {
            $status.Upstream = $upstream.StdOut.Trim()
            $upstreamCounts = Get-AheadBehind -Root $Root -BaseRef '@{upstream}'
            $status.UpstreamAhead = $upstreamCounts.Ahead
            $status.UpstreamBehind = $upstreamCounts.Behind
        }
    }
    catch {
        $status.Error = $_.Exception.Message
    }

    return [pscustomobject]$status
}

function Get-NextStepSummary {
    param([AllowEmptyCollection()][string[]]$Parts)

    foreach ($part in $Parts) {
        # 判定行只接受新格式「[派工] 」與舊格式「[派工判定: 」開頭，一般敘述即使以「派工判定」起頭也不略過。
        $lead = $part -replace '^\s*(?:\d+[.、)）]\s*)?', ''
        if ($lead -match '^`?\[(?:派工\] |派工判定: )') { continue }
        $value = $part -replace '^[`\[\s]+', '' -replace '^\d+[.、)）]\s*', ''
        if ($value -match '^(Developer 派工|P\d+[=＝:：])') { continue }
        $value = ($value -replace '\s+', ' ').Trim()
        if (-not $value) { continue }
        $end = $value.IndexOf('。')
        if ($end -ge 0) { $value = $value.Substring(0, $end + 1) }
        if ($value.Length -gt 160) { $value = $value.Substring(0, 159) + '…' }
        return $value
    }
    return $null
}

function Get-CheckpointSummary {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $summary = [ordered]@{
        Path            = $Path
        Type            = $null
        NextStop        = $null
        NextStepSummary = $null
        UpdatedUtc      = $null
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $summary.UpdatedUtc = (Get-Item -LiteralPath $Path).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)

    foreach ($line in $lines) {
        if ($line -match '^\s*-\s*檢查點類型[：:]\s*(.+)$') {
            $summary.Type = $Matches[1].Trim()
            break
        }
        if ($line -match '^\s*\|\s*檢查點類型\s*\|\s*(.+?)\s*\|\s*$') {
            $summary.Type = $Matches[1].Trim()
            break
        }
    }

    $nextStopIndexes = @(for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^\s*-\s*下一站[：:]') {
                $index
            }
        })
    if ($nextStopIndexes.Count -gt 0) {
        $lastIndex = $nextStopIndexes[-1]
        $parts = New-Object -TypeName System.Collections.Generic.List[string]
        $value = ($lines[$lastIndex] -replace '^\s*-\s*下一站[：:]\s*', '').Trim()
        if ($value.Length -gt 0) {
            $parts.Add($value)
        }
        for ($index = $lastIndex + 1; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -notmatch '^\s+\S') {
                break
            }
            $parts.Add(($lines[$index].Trim() -replace '^[-*]\s*', ''))
        }
        $summary.NextStop = $parts -join ' / '
        $summary.NextStepSummary = Get-NextStepSummary -Parts @($parts.ToArray())
    }
    else {
        $tableLine = @($lines | Where-Object { $_ -match '^\s*\|\s*下一站\s*\|' })
        if ($tableLine.Count -gt 0 -and $tableLine[0] -match '^\s*\|\s*下一站\s*\|\s*(.+?)\s*\|\s*$') {
            $summary.NextStop = $Matches[1].Trim()
            $summary.NextStepSummary = Get-NextStepSummary -Parts @($summary.NextStop)
        }
        else {
            $isInSection = $false
            $parts = New-Object -TypeName System.Collections.Generic.List[string]
            foreach ($line in $lines) {
                if ($line -match '^#{2,}\s*下一站') {
                    $isInSection = $true
                    continue
                }
                if ($isInSection -and $line -match '^#{1,}\s') {
                    break
                }
                if ($isInSection -and $line.Trim().Length -gt 0) {
                    $parts.Add(($line.Trim() -replace '^[-*]\s*', ''))
                }
            }
            if ($parts.Count -gt 0) {
                $summary.NextStop = $parts -join ' / '
                $summary.NextStepSummary = Get-NextStepSummary -Parts @($parts.ToArray())
            }
        }
    }

    return [pscustomobject]$summary
}

function Get-LineRecord {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [System.IO.FileInfo]$LineFile
    )

    $record = [ordered]@{
        LineSlug             = $LineFile.Directory.Name
        Kind                 = $null
        SemanticLabel        = $null
        WorkRoot             = $Root
        CheckpointType       = $null
        NextStop             = $null
        NextStepSummary      = $null
        CheckpointUpdatedUtc = $null
        Error                = $null
    }

    try {
        $line = Get-Content -LiteralPath $LineFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $slugProperty = $line.PSObject.Properties['line-slug']
        if ($null -ne $slugProperty -and -not [string]::IsNullOrWhiteSpace([string]$slugProperty.Value)) {
            $record.LineSlug = [string]$slugProperty.Value
        }
        $kindProperty = $line.PSObject.Properties['kind']
        if ($null -ne $kindProperty -and -not [string]::IsNullOrWhiteSpace([string]$kindProperty.Value)) {
            $record.Kind = [string]$kindProperty.Value
        }
        else {
            $record.Kind = 'workflow'
        }
        $labelProperty = $line.PSObject.Properties['semantic-label']
        if ($null -ne $labelProperty) {
            $record.SemanticLabel = [string]$labelProperty.Value
        }
    }
    catch {
        $record.Error = ('line.json 解析失敗：{0}' -f $_.Exception.Message)
    }

    $checkpointPath = Join-Path -Path $Root -ChildPath ('.local\ai-sessions\report\{0}\handoff-checkpoint.md' -f $LineFile.Directory.Name)
    try {
        $checkpoint = Get-CheckpointSummary -Path $checkpointPath
        if ($null -ne $checkpoint) {
            $record.CheckpointType = $checkpoint.Type
            $record.NextStop = $checkpoint.NextStop
            $record.NextStepSummary = $checkpoint.NextStepSummary
            $record.CheckpointUpdatedUtc = $checkpoint.UpdatedUtc
        }
    }
    catch {
        $record.Error = ('handoff-checkpoint.md 解析失敗：{0}' -f $_.Exception.Message)
    }

    return [pscustomobject]$record
}

function Get-QuotaFailureInfo {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$StdErr,

        [Nullable[int]]$ExitCode,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Message
    )

    $kind = 'other'
    $reason = $null
    if ($StdErr -match 'HttpFailure; status=401(?!\d)') {
        $kind = 'auth-expired'
        $reason = '登入失效'
    }
    elseif ($StdErr -match 'QuotaApiServiceRejected') {
        $kind = 'limit-reached'
        $reason = '已達上限'
    }
    elseif ($StdErr -match 'category=DnsFailure') {
        $reason = '無法解析 chatgpt.com'
    }
    elseif ($StdErr -match 'category=Timeout') {
        $reason = '查詢逾時'
    }
    elseif ($StdErr -match 'category=ConnectionFailure') {
        $reason = '無法連線 chatgpt.com'
    }
    elseif ($StdErr -match 'HttpFailure; status=(\d+)') {
        $reason = '服務回應 HTTP {0}' -f $Matches[1]
    }
    elseif ($StdErr -match 'AuthenticationDataUnavailable') {
        $reason = '找不到登入資料'
    }
    elseif ($Message -match '逾時（') {
        $reason = '查詢逾時（10 秒）'
    }
    else {
        $detail = if ([string]::IsNullOrWhiteSpace($StdErr)) { $Message } else { $StdErr }
        if (-not [string]::IsNullOrWhiteSpace($detail)) {
            $reason = ($detail -split "`r?`n", 2)[0].Trim()
            $reason = $reason -replace '^exit \d+[：:]\s*', ''
            $reason = $reason -replace '^Get-CodexQuota\.ps1 \S+[：:]\s*', ''
            $reason = $reason.Trim()
            if ($reason.Length -gt 80) { $reason = $reason.Substring(0, 80) }
        }
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $reason = '未取得錯誤訊息（exit {0}）' -f $ExitCode
        }
    }

    return [pscustomobject]@{ Kind = $kind; Reason = $reason }
}

function Get-QuotaSummary {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$CodexHome,

        [Parameter(Mandatory)]
        [string]$QuotaScriptPath
    )

    $summary = [ordered]@{
        Name                   = $Name
        CodexHome              = $CodexHome
        State                  = 'unknown'
        PrimaryRemaining       = $null
        PrimaryResetsAtLocal   = $null
        PrimaryWindowMinutes   = $null
        SecondaryRemaining     = $null
        SecondaryResetsAtLocal = $null
        Error                  = $null
        ErrorKind              = $null
        ErrorReason            = $null
    }

    try {
        $hostPath = (Get-Process -Id $PID).Path
        $quotedScriptPath = $QuotaScriptPath.Replace("'", "''")
        $quotedCodexHome = $CodexHome.Replace("'", "''")
        $command = '[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); $LASTEXITCODE = $null; & ''{0}'' -CodexHome ''{1}''; if ($null -eq $LASTEXITCODE) {{ exit 1 }}; exit $LASTEXITCODE' -f $quotedScriptPath, $quotedCodexHome
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $result = Invoke-ExternalCommand -FilePath $hostPath -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-EncodedCommand', $encodedCommand
        ) -TimeoutSeconds 10
        if ($result.ExitCode -ne 0) {
            $failure = Get-QuotaFailureInfo -StdErr $result.StdErr -ExitCode $result.ExitCode
            $summary.Error = 'exit {0}：{1}' -f $result.ExitCode, $result.StdErr.Trim()
            $summary.ErrorKind = $failure.Kind
            $summary.ErrorReason = $failure.Reason
            return [pscustomobject]$summary
        }

        $values = @{}
        foreach ($line in ($result.StdOut -split "`r?`n")) {
            if ($line -match '^([a-z_]+)=(.*)$') {
                $values[$Matches[1]] = $Matches[2]
            }
        }
        if (-not $values.ContainsKey('primary_remaining_percent')) {
            throw '輸出缺少 primary_remaining_percent'
        }

        $summary.State = 'ok'
        $summary.PrimaryRemaining = [double]::Parse($values['primary_remaining_percent'], [System.Globalization.CultureInfo]::InvariantCulture)
        $summary.PrimaryResetsAtLocal = $values['primary_resets_at_local']
        if ($values.ContainsKey('primary_window_minutes')) {
            $windowMinutes = 0L
            if ([int64]::TryParse($values['primary_window_minutes'], [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$windowMinutes)) {
                $summary.PrimaryWindowMinutes = $windowMinutes
            }
        }
        if ($values.ContainsKey('secondary_remaining_percent')) {
            $summary.SecondaryRemaining = [double]::Parse($values['secondary_remaining_percent'], [System.Globalization.CultureInfo]::InvariantCulture)
            $summary.SecondaryResetsAtLocal = $values['secondary_resets_at_local']
        }
    }
    catch {
        $failure = Get-QuotaFailureInfo -Message $_.Exception.Message
        $summary.State = 'unknown'
        $summary.Error = $_.Exception.Message
        $summary.ErrorKind = $failure.Kind
        $summary.ErrorReason = $failure.Reason
    }

    return [pscustomobject]$summary
}

function Get-CodexAccountList {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $message = '找不到 machine.json：{0}' -f $Path
        if ($AsJson) { $script:Warnings.Add($message) } else { Write-Warning $message }
        return , @()
    }

    $machine = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $accountsProperty = $machine.PSObject.Properties['codex_accounts']
    if ($null -eq $accountsProperty -or $null -eq $accountsProperty.Value) {
        return , @()
    }

    return , @($accountsProperty.Value)
}

function Format-QuotaWindowText {
    param(
        [AllowNull()]
        [object]$State,

        [AllowNull()]
        [object]$Remaining,

        [AllowNull()]
        [object]$ResetsAtLocal,

        [Parameter(Mandatory)]
        [string]$WindowName
    )

    if ($null -ne $Remaining) {
        return ('{0}% (reset {1})' -f $Remaining, $ResetsAtLocal)
    }
    if ([string]$State -eq 'ok' -and $WindowName -eq 'secondary') {
        return '無週視窗'
    }

    return '-'
}

function Format-Cell {
    param(
        [AllowNull()]
        [object]$Value,

        [int]$MaxLength = 0
    )

    if ($null -eq $Value) {
        return '-'
    }
    $text = ([string]$Value) -replace '\s+', ' '
    if ($MaxLength -gt 0 -and $text.Length -gt $MaxLength) {
        return $text.Substring(0, $MaxLength - 1) + '…'
    }

    return $text
}

function Get-ObjectValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($Object -isnot [pscustomobject]) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }

    return $property.Value
}

function ConvertTo-UtcDateTime {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).UtcDateTime }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $parsed = [DateTimeOffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([DateTimeOffset]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed.UtcDateTime
    }

    return $null
}

function ConvertTo-IsoUtcText {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) { return $null }

    return ([DateTime]$Value).ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-TextOrNull {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or $Value -is [pscustomobject] -or $Value -is [array]) { return $null }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    return $text
}

function Get-DispatchLimit {
    param(
        [Parameter(Mandatory)]
        [string]$RunScriptPath
    )

    # 逾時與回合結束寬限取自新入口 Invoke-CodexRunMain 的參數預設值，讀不到時為 $null。
    $limit = [ordered]@{
        TimeoutSeconds      = $null
        TurnEndGraceSeconds = $null
    }
    try {
        if (Test-Path -LiteralPath $RunScriptPath -PathType Leaf) {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($RunScriptPath, [ref]$tokens, [ref]$parseErrors)
            $function = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-CodexRunMain'
                }, $true)
            if ($null -ne $function -and $null -ne $function.Body.ParamBlock) {
                foreach ($parameter in $function.Body.ParamBlock.Parameters) {
                    $name = $parameter.Name.VariablePath.UserPath
                    $default = $parameter.DefaultValue
                    if ($limit.Contains($name) -and $default -is [System.Management.Automation.Language.ConstantExpressionAst] -and $default.Value -is [int] -and $default.Value -gt 0) {
                        $limit[$name] = [int]$default.Value
                    }
                }
            }
        }
    }
    catch {
        $limit.TimeoutSeconds = $null
        $limit.TurnEndGraceSeconds = $null
    }

    return [pscustomobject]$limit
}

function ConvertTo-NumberOrNull {
    param(
        [AllowNull()]
        [object]$Value
    )

    # 只接受 JSON 數值；字串、布林、日期、物件與無法轉成有限 double 的值都視為沒有該欄位。
    if ($null -eq $Value -or $Value -is [bool]) { return $null }
    $isNumber = $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single] -or
        $Value -is [int16] -or $Value -is [byte] -or $Value -is [System.Numerics.BigInteger]
    if (-not $isNumber) { return $null }
    try {
        $number = [double]$Value
    }
    catch {
        return $null
    }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $null }

    return $number
}

function ConvertTo-CountOrNull {
    param(
        [AllowNull()]
        [object]$Value,

        [int]$Minimum = 0
    )

    $number = ConvertTo-NumberOrNull -Value $Value
    if ($null -eq $number -or $number -lt $Minimum -or $number -gt [int]::MaxValue -or [math]::Floor($number) -ne $number) { return $null }

    return [int]$number
}

function Get-DispatchRunRecord {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$RecordFile,

        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [DateTime]$NowUtc,

        [Parameter(Mandatory)]
        [object]$Limit,

        [Nullable[DateTime]]$LastEventUtc
    )

    # 位置一律取自紀錄檔所在目錄；紀錄內的路徑欄位在檔案搬移後會失效，不使用。
    $suffix = '.record.json'
    $baseName = $RecordFile.Name.Substring(0, $RecordFile.Name.Length - $suffix.Length)
    $run = [ordered]@{
        RunKey            = $baseName
        LineSlug          = $RecordFile.Directory.Parent.Name
        DispatchSlug      = $null
        TaskType          = $null
        Profile           = $null
        Account           = $null
        Model             = $null
        WorkRoot          = $Root
        State             = 'invalid'
        LimitSource       = $null
        StartedUtc        = $null
        EndedUtc          = $null
        DurationSeconds   = $null
        LastEventUtc      = ConvertTo-IsoUtcText -Value $LastEventUtc
        RecordUpdatedUtc  = ConvertTo-IsoUtcText -Value $RecordFile.LastWriteTimeUtc
        Result            = $null
        FailureReason     = $null
        RejectionKind     = $null
        LimitResetLocal   = $null
        TerminatedByEntry = $null
        ItemEventCount    = $null
        ReportExists      = $null
        ReviewReportValid = $null
        Error             = $null
    }

    try {
        $record = Get-Content -LiteralPath $RecordFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($record -isnot [pscustomobject]) { throw '內容不是物件' }

        $runKey = ConvertTo-TextOrNull -Value (Get-ObjectValue -Object $record -Name 'run_key')
        if ($null -ne $runKey) { $run.RunKey = $runKey }
        $lineSlug = ConvertTo-TextOrNull -Value (Get-ObjectValue -Object $record -Name 'line_slug')
        if ($null -ne $lineSlug) { $run.LineSlug = $lineSlug }
        $run.DispatchSlug = ConvertTo-TextOrNull -Value (Get-ObjectValue -Object $record -Name 'dispatch_slug')
        $run.TaskType = ConvertTo-TextOrNull -Value (Get-ObjectValue -Object $record -Name 'task_type')
        $run.Profile = ConvertTo-TextOrNull -Value (Get-ObjectValue -Object $record -Name 'profile')
        $run.Account = ConvertTo-TextOrNull -Value (Get-ObjectValue -Object (Get-ObjectValue -Object $record -Name 'account') -Name 'name')
        $run.Model = ConvertTo-TextOrNull -Value (Get-ObjectValue -Object $record -Name 'model')
        $run.Result = ConvertTo-TextOrNull -Value (Get-ObjectValue -Object $record -Name 'result')
        $run.FailureReason = ConvertTo-TextOrNull -Value (Get-ObjectValue -Object $record -Name 'failure_reason')
        $run.RejectionKind = ConvertTo-TextOrNull -Value (Get-ObjectValue -Object $record -Name 'rejection_kind')
        # ConvertFrom-Json 會把 ISO 8601 字串轉成 DateTime，輸出前還原成帶時區位移的 ISO 文字。
        $limitReset = Get-ObjectValue -Object $record -Name 'limit_reset_local'
        if ($limitReset -is [datetime]) { if ($limitReset.Kind -eq [DateTimeKind]::Utc) { $limitReset = $limitReset.ToLocalTime() }; $run.LimitResetLocal = $limitReset.ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture) }
        elseif ($limitReset -is [string] -and -not [string]::IsNullOrWhiteSpace($limitReset)) { $run.LimitResetLocal = $limitReset }
        $run.TerminatedByEntry = ConvertTo-TextOrNull -Value (Get-ObjectValue -Object $record -Name 'terminated_by_entry')

        # 單一欄位型別或數值不符時只略過該欄位，不讓整筆紀錄作廢。
        $run.ItemEventCount = ConvertTo-CountOrNull -Value (Get-ObjectValue -Object $record -Name 'item_event_count')
        $duration = ConvertTo-NumberOrNull -Value (Get-ObjectValue -Object $record -Name 'duration_seconds')
        if ($null -ne $duration -and $duration -ge 0) { $run.DurationSeconds = [math]::Round($duration, 1) }
        $reportExists = Get-ObjectValue -Object (Get-ObjectValue -Object $record -Name 'report') -Name 'exists'
        if ($reportExists -is [bool]) { $run.ReportExists = $reportExists }
        $reviewValid = Get-ObjectValue -Object (Get-ObjectValue -Object $record -Name 'review_report_check') -Name 'valid'
        if ($reviewValid -is [bool]) { $run.ReviewReportValid = $reviewValid }

        $started = ConvertTo-UtcDateTime -Value (Get-ObjectValue -Object $record -Name 'started_utc')
        if ($null -eq $started) { throw '缺少 started_utc' }
        $run.StartedUtc = ConvertTo-IsoUtcText -Value $started
        $run.EndedUtc = ConvertTo-IsoUtcText -Value (ConvertTo-UtcDateTime -Value (Get-ObjectValue -Object $record -Name 'ended_utc'))

        if ($null -ne $run.Result) {
            $run.State = 'ended'
        }
        else {
            # 紀錄帶有該次實際套用的時限時優先採用，只帶其中一欄時另一欄取入口預設值；兩者都沒有時以入口預設值為輔，並以距最後事件的時間為主。
            $recordTimeout = ConvertTo-CountOrNull -Value (Get-ObjectValue -Object $record -Name 'timeout_seconds') -Minimum 1
            $recordGrace = ConvertTo-CountOrNull -Value (Get-ObjectValue -Object $record -Name 'turn_end_grace_seconds') -Minimum 0
            $limitSeconds = $null
            $silenceSeconds = $null
            if ($null -ne $recordTimeout -or $null -ne $recordGrace) {
                $timeout = if ($null -ne $recordTimeout) { $recordTimeout } else { $Limit.TimeoutSeconds }
                $grace = if ($null -ne $recordGrace) { $recordGrace } elseif ($null -ne $Limit.TurnEndGraceSeconds) { $Limit.TurnEndGraceSeconds } else { 0 }
                if ($null -ne $timeout) {
                    $run.LimitSource = 'record'
                    $limitSeconds = $timeout + $grace
                    # 入口在總時限後還要終止行程並寫入結果，近期事件的門檻不低於入口預設的回合結束寬限。
                    $silenceSeconds = [math]::Max($grace, $script:MinSilenceSeconds)
                }
            }
            if ($null -eq $limitSeconds -and $null -ne $Limit.TimeoutSeconds -and $null -ne $Limit.TurnEndGraceSeconds) {
                $run.LimitSource = 'default'
                $limitSeconds = $Limit.TimeoutSeconds + $Limit.TurnEndGraceSeconds
                $silenceSeconds = $limitSeconds
            }

            $run.State = 'running'
            $lastActivity = if ($null -ne $LastEventUtc -and $LastEventUtc -gt $started) { [DateTime]$LastEventUtc } else { $started }
            $sinceActivity = ($NowUtc - $lastActivity).TotalSeconds
            if ($sinceActivity -gt $script:AbandonAfterSeconds) {
                # 不論時限是否已知，最後活動超過 24 小時且仍無結果的紀錄不再列出。
                $run.State = 'abandoned'
            }
            elseif ($null -ne $limitSeconds -and ($NowUtc - $started).TotalSeconds -gt $limitSeconds -and $sinceActivity -gt $silenceSeconds) {
                $run.State = 'overdue'
            }
        }
    }
    catch {
        $run.State = 'invalid'
        $run.Error = ('執行紀錄無法讀取：{0}' -f (($_.Exception.Message -split "`r?`n", 2)[0]))
    }

    return [pscustomobject]$run
}

function Get-AccountHealthEntryList {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [DateTime]$NowUtc
    )

    # 只回傳未過期且欄位齊全的項目；檔案不存在時為空集合，無法解析時擲出例外由呼叫端轉成警告。
    $entries = New-Object -TypeName System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }

    $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string](Get-ObjectValue -Object $document -Name 'schema') -cne 'ai-agents.codex-account-health.v1') {
        throw 'schema 不符'
    }
    foreach ($entry in @(Get-ObjectValue -Object $document -Name 'entries')) {
        $accountName = ConvertTo-TextOrNull -Value (Get-ObjectValue -Object $entry -Name 'account_name')
        $expires = ConvertTo-UtcDateTime -Value (Get-ObjectValue -Object $entry -Name 'expires_at_utc')
        if ($null -eq $accountName -or $null -eq $expires -or $expires -le $NowUtc) { continue }
        $entries.Add([pscustomobject]@{
                Account      = $accountName
                Profile      = ConvertTo-TextOrNull -Value (Get-ObjectValue -Object $entry -Name 'profile')
                Model        = ConvertTo-TextOrNull -Value (Get-ObjectValue -Object $entry -Name 'model')
                ReasonCode   = ConvertTo-TextOrNull -Value (Get-ObjectValue -Object $entry -Name 'reason_code')
                ExpiresAtUtc = ConvertTo-IsoUtcText -Value $expires
            })
    }

    return $entries.ToArray()
}

function Get-DispatchRunRank {
    param(
        [Parameter(Mandatory)]
        [object]$Run
    )

    # 同名紀錄出現在多個 root 時的取捨：已結束優先，其次執行中與超過時限，再其次停留過久，最後無法讀取。
    switch ([string]$Run.State) {
        'ended' { return 4 }
        'running' { return 3 }
        'overdue' { return 3 }
        'abandoned' { return 2 }
        default { return 1 }
    }
}

function Test-RunRecordOpen {
    param(
        [Parameter(Mandatory)]
        [object[]]$Items
    )

    # 不解析 JSON，只以文字判斷紀錄是否尚無結果，供筆數上限之外的紀錄決定是否仍要讀取。
    foreach ($item in $Items) {
        try {
            if ([regex]::IsMatch([System.IO.File]::ReadAllText($item.File.FullName), '"result"\s*:\s*null')) { return $true }
        }
        catch {
            continue
        }
    }

    return $false
}

function Get-DispatchSummary {
    param(
        [AllowEmptyCollection()]
        [string[]]$Roots,

        [AllowEmptyCollection()]
        [string[]]$AccountNames,

        [Parameter(Mandatory)]
        [string]$HealthPath,

        [Parameter(Mandatory)]
        [string]$RunScriptPath,

        [DateTime]$NowUtc = [DateTime]::UtcNow,

        [int]$ReadLimit = 40,

        [int]$EndedLimit = 10
    )

    $warnings = New-Object -TypeName System.Collections.Generic.List[string]
    $limit = Get-DispatchLimit -RunScriptPath $RunScriptPath
    if ($null -eq $limit.TimeoutSeconds -or $null -eq $limit.TurnEndGraceSeconds) {
        $warnings.Add('讀不到派工的逾時設定，無法判斷派工是否已超過時限')
    }

    $suffix = '.record.json'
    $groups = New-Object -TypeName 'System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $Roots) {
        $reportRoot = Join-Path -Path $root -ChildPath '.local\ai-sessions\report'
        if (-not (Test-Path -LiteralPath $reportRoot -PathType Container)) { continue }
        foreach ($lineDirectory in @(Get-ChildItem -LiteralPath $reportRoot -Directory -ErrorAction SilentlyContinue)) {
            $runsDirectory = Join-Path -Path $lineDirectory.FullName -ChildPath 'runs'
            if (-not (Test-Path -LiteralPath $runsDirectory -PathType Container)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $runsDirectory -File -Filter ('*' + $suffix) -ErrorAction SilentlyContinue)) {
                if (-not $file.Name.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) { continue }
                $eventsPath = Join-Path -Path $file.DirectoryName -ChildPath ($file.Name.Substring(0, $file.Name.Length - $suffix.Length) + '.events.jsonl')
                $eventsUtc = $null
                if (Test-Path -LiteralPath $eventsPath -PathType Leaf) { $eventsUtc = [System.IO.File]::GetLastWriteTimeUtc($eventsPath) }
                $activity = $file.LastWriteTimeUtc
                if ($null -ne $eventsUtc -and $eventsUtc -gt $activity) { $activity = $eventsUtc }
                if (-not $groups.ContainsKey($file.Name)) { $groups[$file.Name] = New-Object -TypeName System.Collections.Generic.List[object] }
                $groups[$file.Name].Add([pscustomobject]@{ File = $file; Root = $root; EventsUtc = $eventsUtc; Activity = $activity })
            }
        }
    }

    # 讀取順序以紀錄或事件檔的最後寫入時間為準。最近一個總時限內有活動的紀錄，以及 24 小時內尚無結果的紀錄一律讀取，不受筆數上限排擠。
    $recentSeconds = if ($null -ne $limit.TimeoutSeconds -and $null -ne $limit.TurnEndGraceSeconds) { $limit.TimeoutSeconds + $limit.TurnEndGraceSeconds } else { 0 }
    $orderedGroups = @($groups.Values | ForEach-Object {
            $items = $_
            [pscustomobject]@{ Items = $items; Activity = (@($items | ForEach-Object { $_.Activity }) | Sort-Object -Descending | Select-Object -First 1) }
        } | Sort-Object -Property Activity -Descending)
    $selected = @(for ($index = 0; $index -lt $orderedGroups.Count; $index++) {
            $group = $orderedGroups[$index]
            $age = ($NowUtc - $group.Activity).TotalSeconds
            if ($index -lt $ReadLimit -or $age -le $recentSeconds) { $group }
            elseif ($age -le $script:AbandonAfterSeconds -and (Test-RunRecordOpen -Items $group.Items.ToArray())) { $group }
        })

    $runs = @(foreach ($group in $selected) {
            $parsed = @($group.Items | ForEach-Object {
                    $run = Get-DispatchRunRecord -RecordFile $_.File -Root $_.Root -NowUtc $NowUtc -Limit $limit -LastEventUtc $_.EventsUtc
                    [pscustomobject]@{ Run = $run; Rank = (Get-DispatchRunRank -Run $run); Activity = $_.Activity }
                })
            (@($parsed | Sort-Object -Property @{ Expression = { $_.Rank }; Descending = $true }, @{ Expression = { $_.Activity }; Descending = $true }) | Select-Object -First 1).Run
        })
    $open = @($runs | Where-Object { $_.State -eq 'running' -or $_.State -eq 'overdue' } | Sort-Object -Property StartedUtc -Descending)
    $closed = @($runs | Where-Object { $_.State -eq 'ended' -or $_.State -eq 'invalid' } | Sort-Object -Property RecordUpdatedUtc -Descending | Select-Object -First $EndedLimit)

    $health = @()
    try {
        $health = @(Get-AccountHealthEntryList -Path $HealthPath -NowUtc $NowUtc)
    }
    catch {
        $warnings.Add('帳號狀態檔無法讀取，未顯示不支援的 model')
    }

    $accounts = @(foreach ($accountName in $AccountNames) {
            if ([string]::IsNullOrWhiteSpace($accountName)) { continue }
            $last = @($runs | Where-Object { $_.State -eq 'ended' -and [string]::Equals([string]$_.Account, $accountName, [StringComparison]::OrdinalIgnoreCase) } |
                    Sort-Object -Property @{ Expression = { if ($null -eq $_.EndedUtc) { $_.RecordUpdatedUtc } else { $_.EndedUtc } }; Descending = $true } |
                    Select-Object -First 1)
            $lastRun = if ($last.Count -gt 0) { $last[0] } else { $null }
            [pscustomobject][ordered]@{
                Name              = $accountName
                LastResult        = if ($null -ne $lastRun) { $lastRun.Result } else { $null }
                LastFailureReason = if ($null -ne $lastRun) { $lastRun.FailureReason } else { $null }
                LastRejectionKind = if ($null -ne $lastRun) { $lastRun.RejectionKind } else { $null }
                LastLimitResetLocal = if ($null -ne $lastRun) { $lastRun.LimitResetLocal } else { $null }
                LastEndedUtc      = if ($null -ne $lastRun) { if ($null -eq $lastRun.EndedUtc) { $lastRun.RecordUpdatedUtc } else { $lastRun.EndedUtc } } else { $null }
                Unsupported       = @($health | Where-Object { [string]::Equals([string]$_.Account, $accountName, [StringComparison]::OrdinalIgnoreCase) } |
                        ForEach-Object { [pscustomobject][ordered]@{ Profile = $_.Profile; Model = $_.Model; ExpiresAtUtc = $_.ExpiresAtUtc } })
            }
        })

    return [pscustomobject][ordered]@{
        timeoutSeconds      = $limit.TimeoutSeconds
        turnEndGraceSeconds = $limit.TurnEndGraceSeconds
        totalCount          = $groups.Count
        runs                = @($open) + @($closed)
        accounts            = $accounts
        warnings            = @($warnings.ToArray())
        error               = $null
        errorDetail         = $null
    }
}

function ConvertTo-AsciiJson {
    param([string]$Json)
    return [regex]::Replace($Json, '[^\u0000-\u007F]', [System.Text.RegularExpressions.MatchEvaluator]{ param($match) '\u{0:x4}' -f [int][char]$match.Value[0] })
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $roots = Resolve-WorkRootList -Patterns $WorkRoot
        $forcedRoots = Resolve-ForceRootList -Paths $ForceWorkRoot
        foreach ($forcedRoot in $forcedRoots) {
            if (@($roots) -notcontains $forcedRoot) { $roots = @($roots) + $forcedRoot }
        }
        $gitStatuses = @()
        $lineRecords = New-Object -TypeName System.Collections.Generic.List[object]

        foreach ($root in $roots) {
            $handoffRoot = Join-Path -Path $root -ChildPath '.local\ai-sessions\handoff'
            $hasHandoff = Test-Path -LiteralPath $handoffRoot -PathType Container
            if (-not $hasHandoff -and $forcedRoots -notcontains $root) {
                Write-Verbose ('略過（沒有 handoff 目錄）：{0}' -f $root)
                continue
            }

            $gitStatuses += Get-WorkRootGitStatus -Root $root
            if (-not $hasHandoff) {
                Write-Verbose ('略過線資料（沒有 handoff 目錄）：{0}' -f $root)
                continue
            }
            $lineFiles = @(Get-ChildItem -LiteralPath $handoffRoot -Directory | ForEach-Object {
                    $candidate = Join-Path -Path $_.FullName -ChildPath 'line.json'
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                        Get-Item -LiteralPath $candidate
                    }
                })
            foreach ($lineFile in $lineFiles) {
                $record = Get-LineRecord -Root $root -LineFile $lineFile
                if ($WithCheckpointOnly -and $null -eq $record.CheckpointType -and $null -eq $record.CheckpointUpdatedUtc) {
                    continue
                }
                $lineRecords.Add($record)
            }
        }

        $quotaSummaries = @()
        $accountList = @()
        if (-not $SkipQuota) {
            $quotaScript = Join-Path -Path $PSScriptRoot -ChildPath 'Get-CodexQuota.ps1'
            $accountList = @(Get-CodexAccountList -Path $MachineConfigPath | ForEach-Object { $_ })
            foreach ($account in $accountList) {
                $quotaSummaries += Get-QuotaSummary -Name ([string]$account.name) -CodexHome ([string]$account.codex_home) -QuotaScriptPath $quotaScript
            }
        }

        # 派工彙整失敗只影響派工區塊，不讓整份輸出失敗。
        try {
            if ($SkipQuota -and (Test-Path -LiteralPath $MachineConfigPath -PathType Leaf)) {
                $accountList = @(Get-CodexAccountList -Path $MachineConfigPath | ForEach-Object { $_ })
            }
            $accountNames = @($accountList | ForEach-Object { [string](Get-ObjectValue -Object $_ -Name 'name') } | Where-Object { $_.Length -gt 0 })
            $dispatchSummary = Get-DispatchSummary -Roots @($roots) -AccountNames $accountNames `
                -HealthPath (Join-Path -Path (Split-Path -Parent $MachineConfigPath) -ChildPath 'codex-account-health.json') `
                -RunScriptPath (Join-Path -Path $PSScriptRoot -ChildPath 'codex-run\70-run.ps1')
        }
        catch {
            $dispatchSummary = [pscustomobject][ordered]@{
                timeoutSeconds      = $null
                turnEndGraceSeconds = $null
                totalCount          = 0
                runs                = @()
                accounts            = @()
                warnings            = @()
                error               = '派工紀錄無法彙整，請按「重新整理」再試一次'
                errorDetail         = (($_.Exception.Message -split "`r?`n", 2)[0])
            }
        }

        $sortedLines = @($lineRecords | Sort-Object -Property @(
                @{ Expression = { $_.WorkRoot }; Descending = $false },
                @{ Expression = { if ($null -eq $_.CheckpointUpdatedUtc) { '' } else { $_.CheckpointUpdatedUtc } }; Descending = $true },
                @{ Expression = { $_.LineSlug }; Descending = $false }
            ))

        if ($AsJson) {
            $document = [ordered]@{
                schema         = 'ai-agents.line-status.v1'
                generatedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
                scannedRoots   = @($roots)
                warnings       = @($script:Warnings.ToArray())
                workRoots      = @($gitStatuses)
                lines          = $sortedLines
                quota          = @($quotaSummaries)
                dispatch       = $dispatchSummary
            }
            Write-Output (ConvertTo-AsciiJson -Json ($document | ConvertTo-Json -Depth 6))
            exit 0
        }

        Write-Output '== Work-roots'
        $gitStatuses | ForEach-Object {
            $upstreamText = '-'
            if ($null -ne $_.Upstream) {
                $upstreamText = ('{0} +{1}/-{2}' -f $_.Upstream, $_.UpstreamAhead, $_.UpstreamBehind)
            }
            $mainText = '-'
            if ($null -ne $_.MainBranch -and $null -ne $_.MainAhead) {
                $mainText = ('{0} +{1}/-{2}' -f $_.MainBranch, $_.MainAhead, $_.MainBehind)
            }
            [pscustomobject]@{
                WorkRoot = $_.Path
                Branch   = Format-Cell -Value $_.Branch
                Dirty    = Format-Cell -Value $_.DirtyCount
                VsMain   = $mainText
                Upstream = $upstreamText
                Error    = Format-Cell -Value $_.Error -MaxLength 50
            }
        } | Format-Table -AutoSize | Out-String -Width 400 | Write-Output

        Write-Output ('== Lines ({0})' -f $sortedLines.Count)
        $sortedLines | ForEach-Object {
            $updated = '-'
            if ($null -ne $_.CheckpointUpdatedUtc) {
                $updated = ([DateTime]::Parse($_.CheckpointUpdatedUtc, [System.Globalization.CultureInfo]::InvariantCulture)).ToLocalTime().ToString('MM-dd HH:mm')
            }
            [pscustomobject]@{
                LineSlug   = $_.LineSlug
                Kind       = Format-Cell -Value $_.Kind
                Checkpoint = Format-Cell -Value $_.CheckpointType -MaxLength 30
                Updated    = $updated
                NextStop   = Format-Cell -Value $_.NextStop -MaxLength 70
                WorkRoot   = Split-Path -Leaf $_.WorkRoot
            }
        } | Format-Table -AutoSize | Out-String -Width 400 | Write-Output

        Write-Output ('== Dispatch ({0})' -f $dispatchSummary.totalCount)
        if ($null -ne $dispatchSummary.error) {
            Write-Output $dispatchSummary.error
        }
        @($dispatchSummary.runs) | ForEach-Object {
            [pscustomobject]@{
                Line     = Format-Cell -Value $_.LineSlug
                Type     = Format-Cell -Value $_.TaskType
                Account  = Format-Cell -Value $_.Account
                Model    = Format-Cell -Value $_.Model
                State    = $_.State
                Started  = Format-Cell -Value $_.StartedUtc
                Seconds  = Format-Cell -Value $_.DurationSeconds
                Result   = Format-Cell -Value $_.Result
                Reason   = Format-Cell -Value $(if ($null -ne $_.RejectionKind) { $_.RejectionKind } elseif ($null -ne $_.FailureReason) { $_.FailureReason } else { $_.Error }) -MaxLength 40
                WorkRoot = Split-Path -Leaf $_.WorkRoot
            }
        } | Format-Table -AutoSize | Out-String -Width 400 | Write-Output
        @($dispatchSummary.warnings) | ForEach-Object { Write-Output $_ }

        if (-not $SkipQuota) {
            Write-Output '== Codex quota'
            $quotaSummaries | ForEach-Object {
                [pscustomobject]@{
                    Account   = $_.Name
                    State     = $_.State
                    Primary   = Format-QuotaWindowText -State $_.State -Remaining $_.PrimaryRemaining -ResetsAtLocal $_.PrimaryResetsAtLocal -WindowName 'primary'
                    Secondary = Format-QuotaWindowText -State $_.State -Remaining $_.SecondaryRemaining -ResetsAtLocal $_.SecondaryResetsAtLocal -WindowName 'secondary'
                    Error     = Format-Cell -Value $_.Error -MaxLength 60
                }
            } | Format-Table -AutoSize | Out-String -Width 400 | Write-Output
        }

        exit 0
    }
    catch {
        [Console]::Error.WriteLine(('Get-LineStatus.ps1 失敗：{0}' -f $_.Exception.Message))
        exit 1
    }
}
