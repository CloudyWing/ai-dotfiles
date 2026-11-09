#Requires -Version 5.1

<#
.SYNOPSIS
彙整各 work-root 的線狀態、Git 狀態與 Codex 額度，唯讀輸出。

.DESCRIPTION
掃描 work-root 清單下的 .local\ai-sessions\handoff\*\line.json，讀取同線
report\<lineSlug>\handoff-checkpoint.md 的檢查點類型與下一站，加上該 work-root 的
分支、未 commit 檔案數、相對主分支與 upstream 的 ahead/behind，以及 machine.json
codex_accounts 各帳號的額度摘要。

腳本不寫入任何檔案。Git 以 --no-optional-locks 執行，避免 status 更新 index。
不讀取派工的 RunRecord、dispatch result 與 scope-plan 檔。

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
        $value = $part -replace '^[`\[\s]+', '' -replace '^\d+[.、)）]\s*', ''
        if ($value -match '^(Developer 派工|派工判定|P\d+[=＝:：])') { continue }
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
        if (-not $SkipQuota) {
            $quotaScript = Join-Path -Path $PSScriptRoot -ChildPath 'Get-CodexQuota.ps1'
            foreach ($account in (Get-CodexAccountList -Path $MachineConfigPath)) {
                $quotaSummaries += Get-QuotaSummary -Name ([string]$account.name) -CodexHome ([string]$account.codex_home) -QuotaScriptPath $quotaScript
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
