#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
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
