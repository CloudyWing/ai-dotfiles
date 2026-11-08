#Requires -Version 5.1
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
        (Get-NextStepSummary @('`[派工判定: 不派] P1 規則檔撰寫', '實作 Phase 1 至 9。其餘')) -eq '實作 Phase 1 至 9。' -and
        (Get-NextStepSummary @('00. 最新進度：X。下一步派 Y。')) -eq '最新進度：X。' -and
        (Get-NextStepSummary @('P5（instructions.md T023 到 T025）待使用者同意；之後驗收。')) -eq 'P5（instructions.md T023 到 T025）待使用者同意；之後驗收。'
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
    $executorLines = @($actual.lines | Where-Object { $_.NextStop -match '^(Developer 派工|派工判定|P\d+[=＝:：])' })
    if ($executorLines.Count -eq 0) { Write-Output 'SKIP C12 樣本不足' }
    else { Test-Case C12 { @($executorLines | Where-Object { $_.NextStepSummary -match '^(Developer 派工|派工判定|P\d+[=＝:：])' }).Count -eq 0 } }
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
    Test-Case C20 { $emptyResult.ExitCode -eq 0 -and (($original.PSObject.Properties.Name -join ',') -eq 'schema,generatedAtUtc,scannedRoots,warnings,workRoots,lines,quota') -and $original.schema -eq 'ai-agents.line-status.v1' -and (($original | Select-Object * -ExcludeProperty generatedAtUtc | ConvertTo-Json -Depth 6) -eq ($emptyForce | Select-Object * -ExcludeProperty generatedAtUtc | ConvertTo-Json -Depth 6)) }
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
        $keys = 'Name,CodexHome,State,PrimaryRemaining,PrimaryResetsAtLocal,SecondaryRemaining,SecondaryResetsAtLocal,Error,ErrorKind,ErrorReason'
        $code -eq 0 -and @($quotaJson.quota).Count -eq 2 -and ($raw -join '') -notmatch '[^\u0000-\u007f]' -and @($quotaJson.quota | Where-Object { ($_.PSObject.Properties.Name -join ',') -eq $keys -and $_.ErrorKind -eq 'auth-expired' -and $_.Error -match '失敗：' }).Count -eq 2
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
