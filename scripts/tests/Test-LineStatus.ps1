#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name Microsoft.PowerShell.Utility
$scriptPath = Join-Path $PSScriptRoot '..\Get-LineStatus.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('line-status-' + [guid]::NewGuid().ToString('N'))
$hostPath = (Get-Process -Id $PID).Path
$failed = 0

function Test-Case {
    param([string]$Id, [scriptblock]$Check)
    try {
        if (-not (& $Check)) { throw '條件不成立' }
        Write-Output "PASS $Id"
    }
    catch {
        $script:failed++
        Write-Output "FAIL $Id $($_.Exception.Message)"
    }
}

function New-FakeQuotaScript {
    param(
        [string]$Path,
        [string]$Body
    )

    $content = "param([string]`$CodexHome)`r`n" + $Body + "`r`n"
    [IO.File]::WriteAllText($Path, $content, (New-Object Text.UTF8Encoding($true)))
    return $Path
}

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $text = [IO.File]::ReadAllText((Resolve-Path $scriptPath).Path)
    Test-Case C01 {
        $bytes = [IO.File]::ReadAllBytes((Resolve-Path $scriptPath).Path)
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $scriptPath).Path, [ref]$tokens, [ref]$errors)
        $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191 -and $errors.Count -eq 0
    }
    Test-Case C02 { $text -notmatch 'Set-Content|Add-Content|Out-File|New-Item|Remove-Item|Copy-Item|Move-Item|Rename-Item|Set-ItemProperty|Tee-Object|Export-|\[IO\.File\]::(?:Write|Append|Create|Delete|Move|Copy)|WriteAllText|>>' }
    Test-Case C03 { ([regex]::Matches($text, "'git'")).Count -eq 1 -and $text -match '(?s)function Invoke-Git.*?--no-optional-locks.*?Invoke-ExternalCommand -FilePath ''git''' }
    . $scriptPath
    Test-Case C04 {
        (Get-NextStepSummary @('Developer 派工：P1=Codex、P2=Codex', 'Reviewer 審查本輪 diff。之後驗收。')) -eq 'Reviewer 審查本輪 diff。' -and
        (Get-NextStepSummary @('`[派工] 自己做（需要對話脈絡）：P1 規則檔撰寫', '實作 Phase 1 至 9。其餘')) -eq '實作 Phase 1 至 9。' -and
        (Get-NextStepSummary @('`[派工判定: 不派] P1 規則檔撰寫', '實作 Phase 1 至 9。其餘')) -eq '實作 Phase 1 至 9。' -and
        (Get-NextStepSummary @('00. 最新進度：X。下一步派 Y。')) -eq '最新進度：X。' -and
        (Get-NextStepSummary @('P5（instructions.md T023 到 T025）待使用者同意；之後驗收。')) -eq 'P5（instructions.md T023 到 T025）待使用者同意；之後驗收。'
    }
    Test-Case C04b {
        (Get-NextStepSummary @('派工判定規則已確認，接著整理文件。', '進入下一階段。')) -eq '派工判定規則已確認，接著整理文件。' -and
        (Get-NextStepSummary @('派工] 後續整理文件。')) -eq '派工] 後續整理文件。' -and
        (Get-NextStepSummary @('[派工]沒有空白的一般敘述。')) -eq '派工]沒有空白的一般敘述。' -and
        (Get-NextStepSummary @('1. [派工] 自己做（小改動）：P1', '實作 Phase 1。')) -eq '實作 Phase 1。' -and
        $null -eq (Get-NextStepSummary @('[派工判定: 不派] P1 規則檔撰寫'))
    }
    Test-Case C05 { $null -eq (Get-NextStepSummary @('Developer 派工：P1=Codex')) -and $null -eq (Get-NextStepSummary @('P1：E=是、T=是。', 'P2：E=是')) -and $null -eq (Get-NextStepSummary @()) }

    $repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $top = (& git -C $repo rev-parse --show-toplevel).Trim()
    if ($LASTEXITCODE -ne 0) { throw '無法取得 Git 工作樹' }
    $common = (& git -C $repo rev-parse --git-common-dir).Trim()
    if ($LASTEXITCODE -ne 0) { throw '無法取得 Git 共用目錄' }
    $main = [IO.Directory]::GetParent([IO.Path]::GetFullPath([IO.Path]::Combine($repo, $common))).FullName
    $linked = $null
    if (-not [string]::Equals($top, $main, [StringComparison]::OrdinalIgnoreCase)) { $linked = $top }
    else {
        $worktrees = @(& git -C $repo worktree list --porcelain)
        if ($LASTEXITCODE -ne 0) { throw '無法列出 Git 工作樹' }
        foreach ($entry in $worktrees) {
            if ($entry -match '^worktree (.+)$' -and -not [string]::Equals($Matches[1], $main, [StringComparison]::OrdinalIgnoreCase)) { $linked = $Matches[1]; break }
        }
    }
    if ($null -eq $linked) { Write-Output 'SKIP C06a 無 linked worktree' }
    else {
        $raw = & $hostPath -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkRoot "$main;$linked" -SkipQuota -AsJson
        $code = $LASTEXITCODE
        $gitJson = ($raw -join "`n") | ConvertFrom-Json
        $mainStatus = @($gitJson.workRoots | Where-Object { $_.Path -eq $main })
        $linkedStatus = @($gitJson.workRoots | Where-Object { $_.Path -eq $linked })
        if ($mainStatus.Count -eq 0) { $mainStatus = @(Get-WorkRootGitStatus -Root $main) }
        if ($linkedStatus.Count -eq 0) { $linkedStatus = @(Get-WorkRootGitStatus -Root $linked) }
        $mainProbe = Invoke-Git -Root $main -Arguments @('rev-parse', '--is-inside-work-tree')
        if ($mainProbe.ExitCode -ne 0 -and $mainProbe.StdErr -match 'Permission denied') {
            Test-Case C06aLinked { $code -eq 0 -and @($gitJson.scannedRoots).Count -eq 2 -and $linkedStatus[0].IsLinkedWorktree -eq $true }
            Write-Output 'SKIP C06aMain sandbox 拒絕存取主工作樹'
        }
        else { Test-Case C06a { $code -eq 0 -and @($gitJson.scannedRoots).Count -eq 2 -and $mainStatus[0].IsLinkedWorktree -eq $false -and $linkedStatus[0].IsLinkedWorktree -eq $true } }
    }
    foreach ($root in @($tempRoot)) {
        $handoff = Join-Path $root '.local\ai-sessions\handoff\fixture-line'
        $report = Join-Path $root '.local\ai-sessions\report\fixture-line'
        New-Item -ItemType Directory -Force -Path $handoff, $report | Out-Null
        [IO.File]::WriteAllText((Join-Path $handoff 'line.json'), '{"line-slug":"fixture-line"}', (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $report 'handoff-checkpoint.md'), "- 下一站：Developer 派工：P1=Codex`r`n  - Reviewer 審查本輪 diff。之後驗收。", (New-Object Text.UTF8Encoding($false)))
    }
    $raw = & $hostPath -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkRoot $tempRoot -SkipQuota -AsJson
    $code = $LASTEXITCODE
    $json = ($raw -join "`n") | ConvertFrom-Json
    Test-Case C06b { $code -eq 0 -and @($json.lines | Where-Object { $_.NextStepSummary -eq 'Reviewer 審查本輪 diff。' -and $_.NextStop -match 'Developer 派工' }).Count -eq 1 }
    Test-Case C07 { ($raw -join '') -notmatch '[^\u0000-\u007f]' -and $json.lines[0].NextStepSummary -match '[\u4e00-\u9fff]' }
    $raw = & $hostPath -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkRoot (Join-Path $tempRoot 'nope') -MachineConfigPath (Join-Path $tempRoot 'missing.json') -AsJson
    $empty = ($raw -join "`n") | ConvertFrom-Json
    Test-Case C08 { ($raw -join "`n").TrimStart().StartsWith('{') -and @($empty.warnings).Count -eq 1 -and @($empty.quota).Count -eq 0 }
    Test-Case C09 { $LASTEXITCODE -eq 0 -and @($empty.lines).Count -eq 0 -and @($empty.workRoots).Count -eq 0 -and @($empty.scannedRoots).Count -eq 0 }
    $raw = & $hostPath -NoProfile -ExecutionPolicy Bypass -File $scriptPath -SkipQuota -AsJson
    $actual = ($raw -join "`n") | ConvertFrom-Json
    if (-not (Test-Path (Join-Path $env:USERPROFILE '.ai-agents'))) { Write-Output 'SKIP C10 .ai-agents 不存在' }
    else {
        Test-Case C10 { $LASTEXITCODE -eq 0 -and (-not (Test-Path (Join-Path $env:USERPROFILE '.ai-agents\.claude\worktrees')) -or @($actual.scannedRoots | Where-Object { $_ -like (Join-Path $env:USERPROFILE '.ai-agents\.claude\worktrees\*') }).Count -gt 0) }
        if ($PSScriptRoot -like (Join-Path $env:USERPROFILE '.ai-agents\.claude\worktrees\status-board-p2*')) {
            Test-Case C10Line { @($actual.lines | Where-Object { $_.LineSlug -eq 'status-board-p2' }).Count -gt 0 }
        }
        else { Write-Output 'SKIP C10Line 非 status-board-p2 worktree' }
    }
    Test-Case C11 { @($actual.scannedRoots | Where-Object { $_ -match 'YunXin' }).Count -eq 0 }
    $executorLines = @($actual.lines | Where-Object { $_.NextStop -match '^`?\[(?:派工\] |派工判定: )|^(?:Developer 派工|P\d+[=＝:：])' })
    if ($executorLines.Count -eq 0) { Write-Output 'SKIP C12 樣本不足' }
    else { Test-Case C12 { @($executorLines | Where-Object { $_.NextStepSummary -match '^`?\[(?:派工\] |派工判定: )|^(?:Developer 派工|P\d+[=＝:：])' }).Count -eq 0 } }
    $raw = & $hostPath -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkRoot ';' -SkipQuota -AsJson
    $code = $LASTEXITCODE
    $fallback = ($raw -join "`n") | ConvertFrom-Json
    Test-Case C13 { $code -eq 0 -and (($fallback.scannedRoots -join ';') -eq ($actual.scannedRoots -join ';')) }

    $noHandoff = $null
    foreach ($name in @('claude-plugins', 'scripts', 'skills', 'docs')) {
        $candidate = Join-Path $repo $name
        if ((Test-Path -LiteralPath $candidate -PathType Container) -and -not (Test-Path -LiteralPath (Join-Path $candidate '.local\ai-sessions\handoff') -PathType Container)) {
            $noHandoff = (Get-Item -LiteralPath $candidate).FullName.TrimEnd('\')
            break
        }
    }
    $literal = Join-Path $tempRoot 'repo[1]'
    $plain = Join-Path $tempRoot 'plain'
    New-Item -ItemType Directory -Path $literal, $plain | Out-Null
    if ($null -eq $noHandoff) { Write-Output 'SKIP C14 C14g C15 C16 無可用夾具' }
    else {
        $probe = Invoke-Git -Root $noHandoff -Arguments @('rev-parse', '--is-inside-work-tree')
        $indexPath = $null
        $beforeHash = $null
        if ($probe.ExitCode -eq 0 -and $probe.StdErr -notmatch 'Permission denied') {
            $dir = Invoke-Git -Root $noHandoff -Arguments @('rev-parse', '--git-dir')
            $commonDir = Invoke-Git -Root $noHandoff -Arguments @('rev-parse', '--git-common-dir')
            $gitPath = [IO.Path]::GetFullPath([IO.Path]::Combine($noHandoff, $dir.StdOut.Trim()))
            $commonPath = [IO.Path]::GetFullPath([IO.Path]::Combine($noHandoff, $commonDir.StdOut.Trim()))
            $indexPath = Join-Path $gitPath 'index'
            if (Test-Path -LiteralPath $indexPath) { $beforeHash = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash }
        }
        $raw = & $hostPath -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkRoot $tempRoot -ForceWorkRoot $noHandoff -SkipQuota -AsJson
        $code = $LASTEXITCODE
        $forced = ($raw -join "`n") | ConvertFrom-Json
        $row = @($forced.workRoots | Where-Object { $_.Path -eq $noHandoff })
        Test-Case C14 { $code -eq 0 -and $row.Count -eq 1 -and @($forced.scannedRoots | Where-Object { $_ -eq $noHandoff }).Count -eq 1 -and @($forced.lines | Where-Object { $_.WorkRoot -eq $noHandoff }).Count -eq 0 }
        if ($null -eq $indexPath) { Write-Output 'SKIP C14g Git 資料無法讀取' }
        else {
            $afterHash = $null
            if (Test-Path -LiteralPath $indexPath) { $afterHash = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash }
            Test-Case C14g { $dir.ExitCode -eq 0 -and $commonDir.ExitCode -eq 0 -and $null -eq $row[0].Error -and -not [string]::IsNullOrEmpty($row[0].Branch) -and $row[0].IsLinkedWorktree -eq (-not [string]::Equals($gitPath, $commonPath, [StringComparison]::OrdinalIgnoreCase)) -and $beforeHash -eq $afterHash }
        }
        $raw = & $hostPath -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkRoot "$tempRoot;$noHandoff" -SkipQuota -AsJson
        $unforced = ($raw -join "`n") | ConvertFrom-Json
        Test-Case C15 { $LASTEXITCODE -eq 0 -and @($unforced.workRoots | Where-Object { $_.Path -eq $noHandoff }).Count -eq 0 -and @($unforced.scannedRoots | Where-Object { $_ -eq $noHandoff }).Count -eq 1 }
        $raw = & $hostPath -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkRoot $noHandoff -ForceWorkRoot "$noHandoff;$($noHandoff.ToUpperInvariant())" -SkipQuota -AsJson
        $dedup = ($raw -join "`n") | ConvertFrom-Json
        $raw = & $hostPath -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkRoot $tempRoot -ForceWorkRoot $tempRoot -SkipQuota -AsJson
        $dedupLines = ($raw -join "`n") | ConvertFrom-Json
        Test-Case C16 { @($dedup.scannedRoots | Where-Object { $_ -eq $noHandoff }).Count -eq 1 -and @($dedup.workRoots | Where-Object { $_.Path -eq $noHandoff }).Count -eq 1 -and @($dedupLines.lines | Where-Object { $_.LineSlug -eq 'fixture-line' }).Count -eq 1 }
    }
    $none = Join-Path $tempRoot 'nope'
    $raw = & $hostPath -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkRoot $none -ForceWorkRoot (Join-Path $tempRoot '*') -SkipQuota -AsJson
    $wild = ($raw -join "`n") | ConvertFrom-Json
    $wildCode = $LASTEXITCODE
    $raw = & $hostPath -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkRoot $none -ForceWorkRoot (Join-Path $tempRoot 'missing') -SkipQuota -AsJson
    $missing = ($raw -join "`n") | ConvertFrom-Json
    Test-Case C17 { $wildCode -eq 0 -and $LASTEXITCODE -eq 0 -and @($wild.scannedRoots).Count -eq 0 -and @($wild.workRoots).Count -eq 0 -and @($wild.warnings).Count -eq 0 -and @($missing.scannedRoots).Count -eq 0 -and @($missing.workRoots).Count -eq 0 -and @($missing.warnings).Count -eq 0 }
    $raw = & $hostPath -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkRoot $none -ForceWorkRoot $literal -SkipQuota -AsJson
    $literalResult = ($raw -join "`n") | ConvertFrom-Json
    Test-Case C18 { $LASTEXITCODE -eq 0 -and @($literalResult.scannedRoots | Where-Object { $_ -eq $literal }).Count -eq 1 -and @($literalResult.workRoots | Where-Object { $_.Path -eq $literal }).Count -eq 1 }
    $raw = & $hostPath -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkRoot $none -ForceWorkRoot $plain -SkipQuota -AsJson
    $plainResult = ($raw -join "`n") | ConvertFrom-Json
    Test-Case C19 { $LASTEXITCODE -eq 0 -and @($plainResult.workRoots).Count -eq 1 -and $plainResult.workRoots[0].Path -eq $plain -and $null -ne $plainResult.workRoots[0].Error -and $null -eq $plainResult.workRoots[0].DirtyCount }
    $raw = & $hostPath -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkRoot $tempRoot -SkipQuota -AsJson
    $original = ($raw -join "`n") | ConvertFrom-Json
    $encodedCommand = "& '" + $scriptPath.Replace("'", "''") + "' -WorkRoot '" + $tempRoot.Replace("'", "''") + "' -ForceWorkRoot '' -SkipQuota -AsJson"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($encodedCommand))
    $emptyResult = Invoke-ExternalCommand -FilePath $hostPath -ArgumentList @('-NoProfile', '-EncodedCommand', $encodedCommand)
    $emptyForce = $emptyResult.StdOut | ConvertFrom-Json
    Test-Case C20 { $emptyResult.ExitCode -eq 0 -and (($original.PSObject.Properties.Name -join ',') -eq 'schema,generatedAtUtc,scannedRoots,warnings,workRoots,lines,quota,dispatch') -and $original.schema -eq 'ai-agents.line-status.v1' -and (($original | Select-Object * -ExcludeProperty generatedAtUtc | ConvertTo-Json -Depth 6) -eq ($emptyForce | Select-Object * -ExcludeProperty generatedAtUtc | ConvertTo-Json -Depth 6)) }
    Test-Case C21 {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $scriptPath).Path, [ref]$tokens, [ref]$errors)
        (($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) -join ',') -eq 'WorkRoot,MachineConfigPath,ForceWorkRoot,WithCheckpointOnly,SkipQuota,AsJson' -and $ast.ParamBlock.Parameters[2].StaticType -eq [string[]]
    }

    $fakeQuotaPath = Join-Path $tempRoot 'Fake-Quota.ps1'
    $fakeCodexHome = Join-Path $tempRoot 'fake-codex-home'
    Test-Case C22 {
        $null = New-FakeQuotaScript -Path $fakeQuotaPath -Body "[Console]::Error.WriteLine('Get-CodexQuota.ps1 失敗：QuotaApiFailure; category=HttpFailure; status=401'); exit 1"
        $summary = Get-QuotaSummary -Name 'a' -CodexHome $fakeCodexHome -QuotaScriptPath $fakeQuotaPath
        $summary.State -eq 'unknown' -and $summary.ErrorKind -eq 'auth-expired' -and $summary.ErrorReason -eq '登入失效' -and $summary.Error.Contains('失敗：') -and -not $summary.Error.Contains([string][char]0xfffd)
    }
    Test-Case C23 {
        $null = New-FakeQuotaScript -Path $fakeQuotaPath -Body "[Console]::Error.WriteLine('QuotaApiServiceRejected; refusal flags are present.'); exit 1"
        $summary = Get-QuotaSummary -Name 'a' -CodexHome $fakeCodexHome -QuotaScriptPath $fakeQuotaPath
        $summary.State -eq 'unknown' -and $summary.ErrorKind -eq 'limit-reached' -and $summary.ErrorReason -eq '已達上限'
    }
    Test-Case C24 {
        $cases = @(
            @{ Text = 'category=DnsFailure'; Reason = '無法解析 chatgpt.com' },
            @{ Text = 'category=Timeout'; Reason = '查詢逾時' },
            @{ Text = 'category=ConnectionFailure'; Reason = '無法連線 chatgpt.com' },
            @{ Text = 'category=HttpFailure; status=500'; Reason = '服務回應 HTTP 500' },
            @{ Text = 'AuthenticationDataUnavailable'; Reason = '找不到登入資料' }
        )
        $valid = $true
        foreach ($case in $cases) {
            $failure = Get-QuotaFailureInfo -StdErr $case.Text -ExitCode 1
            if ($failure.Kind -ne 'other' -or $failure.Reason -ne $case.Reason) { $valid = $false }
        }
        $timeout = Get-QuotaFailureInfo -Message '子行程逾時（10 秒）'
        $fallback = Get-QuotaFailureInfo -StdErr "exit 1：Get-CodexQuota.ps1 失敗：自訂原因`r`n第二行" -ExitCode 1
        $long = Get-QuotaFailureInfo -StdErr ('x' * 81) -ExitCode 1
        $priority = Get-QuotaFailureInfo -StdErr 'QuotaApiServiceRejected; HttpFailure; status=401' -ExitCode 1
        $null = New-FakeQuotaScript -Path $fakeQuotaPath -Body "[Console]::Out.WriteLine('primary_remaining_percent=invalid'); exit 0"
        $parseFailure = Get-QuotaSummary -Name 'a' -CodexHome $fakeCodexHome -QuotaScriptPath $fakeQuotaPath
        $valid -and $timeout.Kind -eq 'other' -and $timeout.Reason -eq '查詢逾時（10 秒）' -and $fallback.Reason -eq '自訂原因' -and $long.Reason.Length -eq 80 -and $priority.Kind -eq 'auth-expired' -and $parseFailure.State -eq 'unknown' -and $parseFailure.ErrorKind -eq 'other' -and -not [string]::IsNullOrWhiteSpace($parseFailure.ErrorReason)
    }
    Test-Case C25 {
        $failure = Get-QuotaFailureInfo -StdErr 'category=HttpFailure; status=4011' -ExitCode 1
        $failure.Kind -eq 'other' -and $failure.Reason -eq '服務回應 HTTP 4011'
    }
    Test-Case C26 {
        $null = New-FakeQuotaScript -Path $fakeQuotaPath -Body 'exit 1'
        $summary = Get-QuotaSummary -Name 'a' -CodexHome $fakeCodexHome -QuotaScriptPath $fakeQuotaPath
        $summary.State -eq 'unknown' -and $summary.ErrorKind -eq 'other' -and $summary.ErrorReason -eq '未取得錯誤訊息（exit 1）'
    }
    Test-Case C27 {
        $null = New-FakeQuotaScript -Path $fakeQuotaPath -Body "throw 'fixture failure'"
        $summary = Get-QuotaSummary -Name 'a' -CodexHome $fakeCodexHome -QuotaScriptPath $fakeQuotaPath
        $summary.State -eq 'unknown' -and $summary.ErrorKind -eq 'other' -and $summary.Error -match '^exit 1：'
    }
    Test-Case C28 {
        $null = New-FakeQuotaScript -Path $fakeQuotaPath -Body "[Console]::Out.WriteLine('primary_remaining_percent=12.5'); [Console]::Out.WriteLine('primary_resets_at_local=2026-01-01 12:00'); exit 0"
        $summary = Get-QuotaSummary -Name 'a' -CodexHome $fakeCodexHome -QuotaScriptPath $fakeQuotaPath
        $summary.State -eq 'ok' -and $summary.PrimaryRemaining -eq 12.5 -and $summary.PrimaryResetsAtLocal -eq '2026-01-01 12:00' -and $null -eq $summary.Error -and $null -eq $summary.ErrorKind -and $null -eq $summary.ErrorReason
    }
    Test-Case C29 {
        $quotedPath = Join-Path $tempRoot "it's quota.ps1"
        $quotedHome = Join-Path $tempRoot "it's-home"
        $body = @'
if ($CodexHome -notmatch "it's-home$") { [Console]::Error.WriteLine('CodexHome mismatch'); exit 1 }
[Console]::Out.WriteLine('primary_remaining_percent=33')
exit 0
'@
        $null = New-FakeQuotaScript -Path $quotedPath -Body $body
        $summary = Get-QuotaSummary -Name 'a' -CodexHome $quotedHome -QuotaScriptPath $quotedPath
        $summary.State -eq 'ok' -and $summary.PrimaryRemaining -eq 33 -and $summary.CodexHome -eq $quotedHome
    }
    Test-Case C28b {
        $null = New-FakeQuotaScript -Path $fakeQuotaPath -Body "[Console]::Out.WriteLine('primary_remaining_percent=40'); [Console]::Out.WriteLine('primary_window_minutes=43200'); [Console]::Out.WriteLine('secondary_window=none'); exit 0"
        $summary = Get-QuotaSummary -Name 'a' -CodexHome $fakeCodexHome -QuotaScriptPath $fakeQuotaPath
        $summary.State -eq 'ok' -and $summary.PrimaryWindowMinutes -eq 43200 -and $summary.PrimaryWindowMinutes -is [int64] -and $null -eq $summary.SecondaryRemaining
    }
    Test-Case C28c {
        $null = New-FakeQuotaScript -Path $fakeQuotaPath -Body "[Console]::Out.WriteLine('primary_remaining_percent=40'); [Console]::Out.WriteLine('primary_window_minutes=300'); [Console]::Out.WriteLine('secondary_remaining_percent=70'); exit 0"
        $summary = Get-QuotaSummary -Name 'a' -CodexHome $fakeCodexHome -QuotaScriptPath $fakeQuotaPath
        $summary.State -eq 'ok' -and $summary.PrimaryWindowMinutes -eq 300 -and $summary.SecondaryRemaining -eq 70
    }
    Test-Case C28d {
        $null = New-FakeQuotaScript -Path $fakeQuotaPath -Body "[Console]::Out.WriteLine('primary_remaining_percent=40'); exit 0"
        $summary = Get-QuotaSummary -Name 'a' -CodexHome $fakeCodexHome -QuotaScriptPath $fakeQuotaPath
        $summary.State -eq 'ok' -and $null -eq $summary.PrimaryWindowMinutes
    }
    Test-Case C28e {
        $null = New-FakeQuotaScript -Path $fakeQuotaPath -Body "[Console]::Out.WriteLine('primary_remaining_percent=40'); [Console]::Out.WriteLine('primary_window_minutes=abc'); exit 0"
        $summary = Get-QuotaSummary -Name 'a' -CodexHome $fakeCodexHome -QuotaScriptPath $fakeQuotaPath
        $summary.State -eq 'ok' -and $null -eq $summary.PrimaryWindowMinutes
    }
    Test-Case C28f {
        $null = New-FakeQuotaScript -Path $fakeQuotaPath -Body "[Console]::Error.WriteLine('Get-CodexQuota.ps1 失敗：QuotaApiFailure; category=Timeout; timeout_seconds=30'); exit 1"
        $summary = Get-QuotaSummary -Name 'a' -CodexHome $fakeCodexHome -QuotaScriptPath $fakeQuotaPath
        $summary.State -eq 'unknown' -and $null -eq $summary.PrimaryWindowMinutes
    }
    Test-Case C30 {
        $bundle = Join-Path $tempRoot 'bundle'
        $emptyRoot = Join-Path $tempRoot 'empty-root'
        New-Item -ItemType Directory -Path $bundle, $emptyRoot | Out-Null
        $copiedScript = Join-Path $bundle 'Get-LineStatus.ps1'
        Copy-Item -LiteralPath $scriptPath -Destination $copiedScript
        $null = New-FakeQuotaScript -Path (Join-Path $bundle 'Get-CodexQuota.ps1') -Body "[Console]::Error.WriteLine('Get-CodexQuota.ps1 失敗：QuotaApiFailure; category=HttpFailure; status=401'); exit 1"
        $machinePath = Join-Path $bundle 'machine.json'
        $machine = @{ codex_accounts = @(@{ name = 'a'; codex_home = $fakeCodexHome }, @{ name = 'b'; codex_home = $fakeCodexHome }) } | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText($machinePath, $machine, (New-Object Text.UTF8Encoding($false)))
        $raw = & $hostPath -NoProfile -ExecutionPolicy Bypass -File $copiedScript -WorkRoot $emptyRoot -MachineConfigPath $machinePath -AsJson
        $code = $LASTEXITCODE
        $quotaJson = ($raw -join "`n") | ConvertFrom-Json
        $keys = 'Name,CodexHome,State,PrimaryRemaining,PrimaryResetsAtLocal,PrimaryWindowMinutes,SecondaryRemaining,SecondaryResetsAtLocal,Error,ErrorKind,ErrorReason'
        $code -eq 0 -and @($quotaJson.quota).Count -eq 2 -and ($raw -join '') -notmatch '[^\u0000-\u007f]' -and @($quotaJson.quota | Where-Object { ($_.PSObject.Properties.Name -join ',') -eq $keys -and $_.ErrorKind -eq 'auth-expired' -and $_.Error -match '失敗：' }).Count -eq 2
    }
    # 派工執行紀錄彙整（Invoke-CodexRun.ps1 的 runs\*.record.json）
    $dispatchNow = [DateTime]::new(2026, 11, 16, 12, 0, 0, [DateTimeKind]::Utc)
    $dispatchMain = Join-Path $tempRoot 'dispatch-main'
    $dispatchTree = Join-Path $tempRoot 'dispatch-tree'
    $dispatchEmpty = Join-Path $tempRoot 'dispatch-empty'
    $runScript = Join-Path $PSScriptRoot '..\codex-run\70-run.ps1'
    $noBom = New-Object Text.UTF8Encoding($false)
    function New-RunFixture {
        param([string]$Root, [string]$Line, [string]$RunKey, [hashtable]$Fields, [string]$RawText, [Nullable[DateTime]]$EventsUtc, [Nullable[DateTime]]$RecordUtc)
        $runs = Join-Path $Root ".local\ai-sessions\report\$Line\runs"
        New-Item -ItemType Directory -Force -Path $runs | Out-Null
        $path = Join-Path $runs ($RunKey + '.record.json')
        $text = $RawText
        if ([string]::IsNullOrEmpty($text)) {
            $record = [ordered]@{ schema = 'ai-agents.codex-run-record.v1'; run_key = $RunKey; line_slug = $Line; dispatch_slug = 'fx'; task_type = 'review'; profile = 'review'; account = @{ name = 'acct-a'; codex_home = 'C:\x' }; model = 'model-x'; started_utc = '2026-11-16T11:00:00.0000000Z'; ended_utc = $null; duration_seconds = $null; result = $null; failure_reason = $null; terminated_by_entry = $null; rejection_kind = $null; item_event_count = $null; future_field = @{ nested = 1 } }
            foreach ($key in $Fields.Keys) { $record[$key] = $Fields[$key] }
            $text = $record | ConvertTo-Json -Depth 6
        }
        [IO.File]::WriteAllText($path, $text, $noBom)
        if ($null -ne $RecordUtc) { [IO.File]::SetLastWriteTimeUtc($path, $RecordUtc) }
        if ($null -ne $EventsUtc) {
            $events = Join-Path $runs ($RunKey + '.events.jsonl')
            [IO.File]::WriteAllText($events, '{"type":"turn.started"}', $noBom)
            [IO.File]::SetLastWriteTimeUtc($events, $EventsUtc)
        }
    }
    New-Item -ItemType Directory -Path $dispatchEmpty | Out-Null
    $healthMissing = Join-Path $tempRoot 'no-health.json'
    $none = Get-DispatchSummary -Roots @($dispatchEmpty, (Join-Path $tempRoot 'dispatch-absent')) -AccountNames @() -HealthPath $healthMissing -RunScriptPath $runScript -NowUtc $dispatchNow
    Test-Case D01 { $none.totalCount -eq 0 -and @($none.runs).Count -eq 0 -and @($none.accounts).Count -eq 0 -and $null -eq $none.error -and $none.timeoutSeconds -eq 1800 -and $none.turnEndGraceSeconds -eq 60 -and @($none.warnings).Count -eq 0 }

    # 執行中：最近有事件、事件間隔數分鐘、超過預設時限但仍有事件（以較大 -TimeoutSeconds 發動）
    New-RunFixture -Root $dispatchTree -Line 'line-tree' -RunKey 'run-tree' -Fields @{ started_utc = '2026-11-16T11:50:00.0000000Z' } -EventsUtc $dispatchNow.AddSeconds(-10) -RecordUtc $dispatchNow.AddMinutes(-10)
    New-RunFixture -Root $dispatchTree -Line 'line-tree' -RunKey 'run-gap' -Fields @{ started_utc = '2026-11-16T11:40:00.0000000Z' } -EventsUtc $dispatchNow.AddSeconds(-200) -RecordUtc $dispatchNow.AddMinutes(-20)
    New-RunFixture -Root $dispatchMain -Line 'line-main' -RunKey 'run-long-alive' -Fields @{ started_utc = '2026-11-16T10:00:00.0000000Z' } -EventsUtc $dispatchNow.AddSeconds(-30) -RecordUtc $dispatchNow.AddMinutes(-120)
    # 超過時限：預設時限與事件皆過久；紀錄自帶時限且已超過；紀錄自帶較大時限而尚未超過；停留超過 24 小時
    New-RunFixture -Root $dispatchMain -Line 'line-main' -RunKey 'run-overdue' -Fields @{ started_utc = '2026-11-16T11:00:00.0000000Z' } -EventsUtc $dispatchNow.AddMinutes(-55) -RecordUtc $dispatchNow.AddMinutes(-60)
    New-RunFixture -Root $dispatchMain -Line 'line-main' -RunKey 'run-own-limit' -Fields @{ started_utc = '2026-11-16T11:45:00.0000000Z'; timeout_seconds = 600; turn_end_grace_seconds = 60 } -EventsUtc $dispatchNow.AddMinutes(-5) -RecordUtc $dispatchNow.AddMinutes(-15)
    New-RunFixture -Root $dispatchMain -Line 'line-main' -RunKey 'run-own-long' -Fields @{ started_utc = '2026-11-16T10:30:00.0000000Z'; timeout_seconds = 7200; turn_end_grace_seconds = 60 } -EventsUtc $dispatchNow.AddMinutes(-40) -RecordUtc $dispatchNow.AddMinutes(-90)
    New-RunFixture -Root $dispatchMain -Line 'line-main' -RunKey 'run-abandoned' -Fields @{ started_utc = '2026-11-13T12:00:00.0000000Z' } -RecordUtc $dispatchNow.AddDays(-3)
    # 紀錄只帶其中一個時限欄位，或寬限為 0
    New-RunFixture -Root $dispatchMain -Line 'line-main' -RunKey 'run-only-timeout' -Fields @{ started_utc = '2026-11-16T11:15:00.0000000Z'; timeout_seconds = 600 } -EventsUtc $dispatchNow.AddSeconds(-20) -RecordUtc $dispatchNow.AddMinutes(-45)
    New-RunFixture -Root $dispatchMain -Line 'line-main' -RunKey 'run-only-silent' -Fields @{ started_utc = '2026-11-16T11:15:30.0000000Z'; timeout_seconds = 600 } -EventsUtc $dispatchNow.AddMinutes(-5) -RecordUtc $dispatchNow.AddMinutes(-45)
    New-RunFixture -Root $dispatchMain -Line 'line-main' -RunKey 'run-grace0' -Fields @{ started_utc = '2026-11-16T11:16:00.0000000Z'; timeout_seconds = 600; turn_end_grace_seconds = 0 } -EventsUtc $dispatchNow.AddSeconds(-5) -RecordUtc $dispatchNow.AddMinutes(-44)
    # 已結束與異常紀錄
    New-RunFixture -Root $dispatchMain -Line 'line-main' -RunKey 'run-ok' -Fields @{ ended_utc = '2026-11-16T11:10:00.0000000Z'; duration_seconds = 600.04; result = 'success'; item_event_count = 12; report = @{ exists = $true; bytes = 10 }; review_report_check = @{ valid = $true; errors = @() } } -RecordUtc $dispatchNow.AddMinutes(-50)
    New-RunFixture -Root $dispatchMain -Line 'line-main' -RunKey 'run-rejected' -Fields @{ account = @{ name = 'acct-b' }; ended_utc = '2026-11-16T11:20:00.0000000Z'; duration_seconds = 15.7; result = 'rejected'; failure_reason = 'usage-limit'; rejection_kind = 'usage-limit'; item_event_count = 0 } -RecordUtc $dispatchNow.AddMinutes(-40)
    New-RunFixture -Root $dispatchMain -Line 'line-main' -RunKey 'run-timeout' -Fields @{ ended_utc = '2026-11-16T11:30:00.0000000Z'; duration_seconds = 1800.2; result = 'failed'; failure_reason = 'timeout'; terminated_by_entry = 'timeout' } -RecordUtc $dispatchNow.AddMinutes(-30)
    New-RunFixture -Root $dispatchMain -Line 'line-bad' -RunKey 'run-corrupt' -RawText '{ "run_key": "run-corrupt", ' -RecordUtc $dispatchNow.AddMinutes(-70)
    New-RunFixture -Root $dispatchMain -Line 'line-bad' -RunKey 'run-sparse' -RawText '{ "result": "success" }' -RecordUtc $dispatchNow.AddMinutes(-80)
    New-RunFixture -Root $dispatchMain -Line 'line-bad' -RunKey 'run-minimal' -RawText '{ "started_utc": "2026-11-16T10:00:00Z", "result": "success", "account": "not-an-object", "duration_seconds": "n/a", "item_event_count": 1e30 }' -RecordUtc $dispatchNow.AddMinutes(-90)
    New-RunFixture -Root $dispatchMain -Line 'line-bad' -RunKey 'run-badtypes' -RawText '{ "started_utc": "2026-11-16T10:00:00Z", "result": "failed", "failure_reason": "timeout", "item_event_count": "2026-01-01T00:00:00Z", "duration_seconds": -5, "timeout_seconds": "x" }' -RecordUtc $dispatchNow.AddMinutes(-91)
    # 同名紀錄：主 checkout 有已結束的版本，線工作樹留著執行中的舊快照，已結束者優先
    New-RunFixture -Root $dispatchTree -Line 'line-tree' -RunKey 'run-dup' -Fields @{ started_utc = '2026-11-16T11:55:00.0000000Z' } -EventsUtc $dispatchNow.AddMinutes(-4) -RecordUtc $dispatchNow.AddMinutes(-5)
    New-RunFixture -Root $dispatchMain -Line 'line-tree' -RunKey 'run-dup' -Fields @{ started_utc = '2026-11-16T11:55:00.0000000Z'; ended_utc = '2026-11-16T11:57:00.0000000Z'; result = 'success' } -RecordUtc $dispatchNow.AddMinutes(-95)
    $healthPath = Join-Path $tempRoot 'codex-account-health.json'
    $healthEntries = @(
        @{ account_name = 'acct-b'; codex_home = 'C:\x'; profile = 'review'; model = 'model-x'; reason_code = 'model-not-supported'; recorded_at_utc = '2026-11-16T00:00:00Z'; expires_at_utc = '2026-11-17T00:00:00Z' },
        @{ account_name = 'acct-b'; codex_home = 'C:\x'; profile = 'scan'; model = 'model-old'; reason_code = 'model-not-supported'; recorded_at_utc = '2026-11-14T00:00:00Z'; expires_at_utc = '2026-11-15T00:00:00Z' },
        @{ account_name = 'acct-z'; profile = 'review'; expires_at_utc = '2026-11-17T00:00:00Z' },
        @{ profile = 'broken' }
    )
    [IO.File]::WriteAllText($healthPath, (@{ schema = 'ai-agents.codex-account-health.v1'; entries = $healthEntries } | ConvertTo-Json -Depth 5), $noBom)
    $fixtureRoots = @($dispatchMain, $dispatchTree)
    $fixtureFileCount = @(Get-ChildItem -LiteralPath $fixtureRoots -Recurse -File).Count
    $beforeFiles = @(Get-ChildItem -LiteralPath $fixtureRoots -Recurse -File | ForEach-Object { $_.FullName + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks }) -join "`n"
    $summary = Get-DispatchSummary -Roots @($dispatchTree, $dispatchMain, $dispatchEmpty) -AccountNames @('acct-a', 'ACCT-B', 'acct-unused') -HealthPath $healthPath -RunScriptPath $runScript -NowUtc $dispatchNow
    $byKey = @{}
    foreach ($item in @($summary.runs)) { $byKey[$item.RunKey] = $item }
    $order = @($summary.runs | ForEach-Object { $_.RunKey }) -join ','
    Test-Case D02 { $summary.totalCount -eq 18 -and $null -eq $summary.error -and $order -eq 'run-tree,run-own-limit,run-gap,run-grace0,run-only-silent,run-only-timeout,run-overdue,run-own-long,run-long-alive,run-timeout,run-rejected,run-ok,run-corrupt,run-sparse,run-minimal,run-badtypes,run-dup' }
    Test-Case D03 { $byKey['run-tree'].State -eq 'running' -and $byKey['run-tree'].LastEventUtc -eq '2026-11-16T11:59:50Z' -and $byKey['run-tree'].StartedUtc -eq '2026-11-16T11:50:00Z' -and $byKey['run-tree'].Account -eq 'acct-a' -and $byKey['run-tree'].Model -eq 'model-x' -and $byKey['run-tree'].TaskType -eq 'review' -and $null -eq $byKey['run-tree'].Result -and $byKey['run-tree'].LimitSource -eq 'default' -and -not ($byKey['run-tree'].PSObject.Properties.Name -contains 'IsQuiet') }
    Test-Case D04 { $byKey['run-gap'].State -eq 'running' -and $byKey['run-gap'].LastEventUtc -eq '2026-11-16T11:56:40Z' -and $byKey['run-long-alive'].State -eq 'running' -and $byKey['run-own-long'].State -eq 'running' -and $byKey['run-own-long'].LimitSource -eq 'record' }
    Test-Case D05 { $byKey['run-ok'].State -eq 'ended' -and $byKey['run-ok'].Result -eq 'success' -and $byKey['run-ok'].DurationSeconds -eq 600 -and $byKey['run-ok'].EndedUtc -eq '2026-11-16T11:10:00Z' -and $byKey['run-ok'].ItemEventCount -eq 12 -and $byKey['run-ok'].ReportExists -eq $true -and $byKey['run-ok'].ReviewReportValid -eq $true -and $null -eq $byKey['run-ok'].LastEventUtc }
    Test-Case D06 { $byKey['run-rejected'].State -eq 'ended' -and $byKey['run-rejected'].Result -eq 'rejected' -and $byKey['run-rejected'].RejectionKind -eq 'usage-limit' -and $byKey['run-rejected'].Account -eq 'acct-b' -and $byKey['run-rejected'].ItemEventCount -eq 0 }
    Test-Case D07 { $byKey['run-timeout'].State -eq 'ended' -and $byKey['run-timeout'].Result -eq 'failed' -and $byKey['run-timeout'].FailureReason -eq 'timeout' -and $byKey['run-timeout'].TerminatedByEntry -eq 'timeout' }
    Test-Case D08 { $byKey['run-overdue'].State -eq 'overdue' -and $byKey['run-overdue'].LimitSource -eq 'default' -and $byKey['run-overdue'].LastEventUtc -eq '2026-11-16T11:05:00Z' -and $byKey['run-own-limit'].State -eq 'overdue' -and $byKey['run-own-limit'].LimitSource -eq 'record' -and -not $byKey.ContainsKey('run-abandoned') }
    Test-Case D19 { $byKey['run-only-timeout'].State -eq 'running' -and $byKey['run-only-timeout'].LimitSource -eq 'record' -and $byKey['run-only-silent'].State -eq 'overdue' -and $byKey['run-only-silent'].LimitSource -eq 'record' -and $byKey['run-grace0'].State -eq 'running' -and $byKey['run-grace0'].LimitSource -eq 'record' }
    Test-Case D09 { $byKey['run-corrupt'].State -eq 'invalid' -and $byKey['run-corrupt'].Error -match '^執行紀錄無法讀取' -and $byKey['run-corrupt'].LineSlug -eq 'line-bad' }
    $all = Get-DispatchSummary -Roots @($dispatchTree, $dispatchMain) -AccountNames @() -HealthPath $healthMissing -RunScriptPath $runScript -NowUtc $dispatchNow -EndedLimit 50
    $allKey = @{}
    foreach ($item in @($all.runs)) { $allKey[$item.RunKey] = $item }
    Test-Case D10 { $allKey['run-sparse'].State -eq 'invalid' -and $allKey['run-sparse'].Error -match 'started_utc' -and $allKey['run-minimal'].State -eq 'ended' -and $null -eq $allKey['run-minimal'].Account -and $null -eq $allKey['run-minimal'].DurationSeconds -and $null -eq $allKey['run-minimal'].ItemEventCount -and $allKey['run-badtypes'].State -eq 'ended' -and $allKey['run-badtypes'].Result -eq 'failed' -and $null -eq $allKey['run-badtypes'].ItemEventCount -and $null -eq $allKey['run-badtypes'].DurationSeconds }
    Test-Case D11 { $byKey['run-tree'].WorkRoot -eq $dispatchTree -and $byKey['run-gap'].WorkRoot -eq $dispatchTree -and $byKey['run-ok'].WorkRoot -eq $dispatchMain -and $allKey['run-dup'].State -eq 'ended' -and $allKey['run-dup'].WorkRoot -eq $dispatchMain -and $allKey['run-dup'].LineSlug -eq 'line-tree' -and @($all.runs | Where-Object { $_.RunKey -eq 'run-dup' }).Count -eq 1 }
    $accountA = @($summary.accounts | Where-Object { $_.Name -eq 'acct-a' })[0]
    $accountB = @($summary.accounts | Where-Object { $_.Name -eq 'ACCT-B' })[0]
    $accountUnused = @($summary.accounts | Where-Object { $_.Name -eq 'acct-unused' })[0]
    Test-Case D12 { @($summary.accounts).Count -eq 3 -and $accountA.LastResult -eq 'success' -and $accountA.LastEndedUtc -eq '2026-11-16T11:57:00Z' -and @($accountA.Unsupported).Count -eq 0 -and $accountB.LastResult -eq 'rejected' -and $accountB.LastRejectionKind -eq 'usage-limit' -and @($accountB.Unsupported).Count -eq 1 -and $accountB.Unsupported[0].Model -eq 'model-x' -and $accountB.Unsupported[0].Profile -eq 'review' -and $null -eq $accountUnused.LastResult -and @($accountUnused.Unsupported).Count -eq 0 }
    # 筆數上限只限制最近一個總時限以外的紀錄；執行中與超過時限者不被排擠
    $limited = Get-DispatchSummary -Roots @($dispatchTree, $dispatchMain) -AccountNames @() -HealthPath $healthMissing -RunScriptPath $runScript -NowUtc $dispatchNow -ReadLimit 1 -EndedLimit 1
    $limitedKeys = @($limited.runs | ForEach-Object { $_.RunKey })
    Test-Case D13 { $limited.totalCount -eq 18 -and @('run-tree', 'run-gap', 'run-long-alive', 'run-own-limit', 'run-own-long', 'run-overdue', 'run-only-timeout', 'run-only-silent', 'run-grace0' | Where-Object { $limitedKeys -notcontains $_ }).Count -eq 0 -and $limitedKeys -notcontains 'run-minimal' }
    $brokenHealth = Join-Path $tempRoot 'broken-health.json'
    [IO.File]::WriteAllText($brokenHealth, '{ not json', $noBom)
    $noLimit = Get-DispatchSummary -Roots @($dispatchMain) -AccountNames @('acct-b') -HealthPath $brokenHealth -RunScriptPath (Join-Path $tempRoot 'missing-run.ps1') -NowUtc $dispatchNow
    $noLimitKey = @{}
    foreach ($item in @($noLimit.runs)) { $noLimitKey[$item.RunKey] = $item }
    Test-Case D14 { $null -eq $noLimit.timeoutSeconds -and $null -eq $noLimit.turnEndGraceSeconds -and @($noLimit.warnings).Count -eq 2 -and $noLimitKey['run-overdue'].State -eq 'running' -and $null -eq $noLimitKey['run-overdue'].LimitSource -and $noLimitKey['run-own-limit'].State -eq 'overdue' -and -not $noLimitKey.ContainsKey('run-abandoned') -and $noLimitKey['run-only-silent'].State -eq 'overdue' -and $noLimitKey['run-only-silent'].LimitSource -eq 'record' -and $noLimitKey['run-only-timeout'].State -eq 'running' -and @($noLimit.accounts[0].Unsupported).Count -eq 0 -and $noLimit.accounts[0].LastResult -eq 'rejected' }
    $dispatchMachine = Join-Path $tempRoot 'machine.json'
    [IO.File]::WriteAllText($dispatchMachine, (@{ codex_accounts = @(@{ name = 'acct-a'; codex_home = 'C:\x' }) } | ConvertTo-Json -Depth 4), $noBom)
    $raw = & $hostPath -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkRoot "$dispatchMain;$dispatchTree" -ForceWorkRoot $dispatchTree -MachineConfigPath $dispatchMachine -SkipQuota -AsJson
    $code = $LASTEXITCODE
    $dispatchJson = ($raw -join "`n") | ConvertFrom-Json
    Test-Case D15 { $code -eq 0 -and ($raw -join '') -notmatch '[^\u0000-\u007f]' -and $dispatchJson.dispatch.totalCount -eq 18 -and $dispatchJson.dispatch.timeoutSeconds -eq 1800 -and @($dispatchJson.dispatch.accounts).Count -eq 1 -and $dispatchJson.dispatch.accounts[0].Name -eq 'acct-a' -and @($dispatchJson.dispatch.accounts[0].Unsupported).Count -eq 0 -and $null -eq $dispatchJson.dispatch.error -and @($dispatchJson.lines).Count -eq 0 }
    $rawText = & $hostPath -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkRoot "$dispatchMain;$dispatchTree" -MachineConfigPath $dispatchMachine -SkipQuota
    $textCode = $LASTEXITCODE
    Test-Case D16 { $textCode -eq 0 -and ($rawText -join "`n") -match '== Dispatch \(18\)' -and ($rawText -join "`n") -match 'line-main' }
    $afterFiles = @(Get-ChildItem -LiteralPath $fixtureRoots -Recurse -File | ForEach-Object { $_.FullName + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks }) -join "`n"
    Test-Case D17 { $beforeFiles -eq $afterFiles -and @(Get-ChildItem -LiteralPath $fixtureRoots -Recurse -File).Count -eq $fixtureFileCount }
    Test-Case D18 {
        $numbers = @((ConvertTo-CountOrNull -Value 3), (ConvertTo-CountOrNull -Value 3.5), (ConvertTo-CountOrNull -Value 1e30), (ConvertTo-CountOrNull -Value -1), (ConvertTo-CountOrNull -Value '3'), (ConvertTo-CountOrNull -Value $true), (ConvertTo-CountOrNull -Value ([DateTime]::UtcNow)), (ConvertTo-CountOrNull -Value 0 -Minimum 1))
        ($numbers[0] -eq 3) -and (@($numbers | Select-Object -Skip 1 | Where-Object { $null -ne $_ }).Count -eq 0) -and $null -eq (ConvertTo-NumberOrNull -Value ([double]::NaN))
    }
    Test-Case C31 { $script:failed -eq 0 }
}
catch {
    $failed++
    Write-Output "FAIL setup $($_.Exception.Message)"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
Write-Output "FAILED: $failed"
if ($failed -gt 0) { exit 1 }
exit 0
