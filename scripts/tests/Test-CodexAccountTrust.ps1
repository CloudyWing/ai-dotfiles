#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$script:DispatchEntryScriptRoot = $scriptsRoot
$moduleNames = @('common-runtime', 'git-baseline', 'dispatch-scope', 'dispatch-evidence', 'quota-observation', 'advisor-evidence', 'process-identity', 'reviewer-contract', 'run-recovery', 'prepare-stage', 'dispatch-lifecycle', 'start-lifecycle', 'inspect-lifecycle', 'collect-contract', 'cleanup', 'Invoke-DispatchConcurrency')
foreach ($module in $moduleNames) {
    . (Join-Path $scriptsRoot ('dispatch\' + $module + '.ps1'))
}

$script:failed = 0
$script:passed = 0
$script:skipped = 0
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tr-trust-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$null = New-Item -ItemType Directory -Path $tempRoot -Force
$sentinel = 'SENTINEL-' + [guid]::NewGuid().ToString('N')
$hostPath = (Get-Process -Id $PID).Path

function Test-Case {
    param([string]$Id, [scriptblock]$Check)
    try {
        if (-not (& $Check)) { throw '條件不成立' }
        $script:passed++
        Write-Output "PASS $Id"
    }
    catch {
        $script:failed++
        Write-Output "FAIL $Id $($_.Exception.Message)"
    }
}

function Skip-Case {
    param([string]$Id, [string]$Reason)
    $script:skipped++
    Write-Output "SKIP $Id $Reason"
}

function TrCatch {
    param([scriptblock]$Action)
    try { $null = & $Action } catch { return $_.Exception }
    return $null
}

function TrNewDir {
    param([string]$Name)
    $path = Join-Path $tempRoot ($Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $null = New-Item -ItemType Directory -Path $path -Force
    return $path
}

function TrBytes {
    param([string]$Path)
    return ,[IO.File]::ReadAllBytes($Path)
}

function TrSameBytes {
    param([byte[]]$Left, [byte[]]$Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($i = 0; $i -lt $Left.Length; $i++) { if ($Left[$i] -ne $Right[$i]) { return $false } }
    return $true
}

function TrTrustText {
    param([string[]]$Key = @(), [bool]$Windows = $true, [string]$Newline = "`n")
    $text = ''
    if ($Windows) { $text += 'model = "fixture"' + $Newline + $Newline + '[windows]' + $Newline + 'sandbox = "mxc"' + $Newline }
    foreach ($item in $Key) { $text += $Newline + "[projects.'" + $item + "']" + $Newline + 'trust_level = "trusted"' + $Newline }
    return $text
}

function TrNewHome {
    param([string]$Root, [string]$Name, [AllowNull()][object]$Config = '', [string]$Login = 'login')
    $path = Join-Path $Root $Name
    $null = New-Item -ItemType Directory -Path $path -Force
    if ($Login -eq 'login') { [IO.File]::WriteAllBytes((Join-Path $path 'auth.json'), $utf8NoBom.GetBytes('{ not json ' + $sentinel + [char]0 + ' }')) }
    [IO.File]::WriteAllText((Join-Path $path 'scan.config.toml'), 'model = "fixture-model"', $utf8NoBom)
    if ($null -ne $Config) { [IO.File]::WriteAllText((Join-Path $path 'config.toml'), $Config, $utf8NoBom) }
    return $path
}

function TrMakeJunctionConfig {
    param([string]$AccountHome)
    $target = Join-Path $AccountHome 'junction-target'
    $null = New-Item -ItemType Directory -Path $target -Force
    [IO.File]::WriteAllText((Join-Path $target 'marker.txt'), 'marker', $utf8NoBom)
    $null = New-Item -ItemType Junction -Path (Join-Path $AccountHome 'config.toml') -Target $target
    return $target
}

function TrWriteMachine {
    param([string]$Path, [object[]]$Account)
    $machine = [ordered]@{ schema = 'ai-agents.machine.v1'; codex_accounts = @($Account | ForEach-Object { [ordered]@{ name = $_.name; codex_home = $_.codex_home } }) }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $machine -Depth 10), $utf8NoBom)
    return $Path
}

function TrAccount {
    param([string]$Name, [string]$AccountHome)
    return [pscustomobject]@{ name = $Name; codex_home = $AccountHome }
}

function TrSelection {
    param([string]$AccountHome, [string]$Name = 'acc', [string]$Mode = 'explicit', [object[]]$Skipped = @())
    return [pscustomobject]@{ CodexHome = $AccountHome; AccountName = $Name; Mode = $Mode; Candidates = @(); Skipped = @($Skipped) }
}

function TrNewRequest {
    param([string]$Root, [string]$Slug = 'tr-job')
    $lineSlug = 'tr-line'
    $history = Join-Path $Root ('.local\ai-sessions\history\' + $lineSlug)
    $handoff = Join-Path $Root ('.local\ai-sessions\handoff\' + $lineSlug)
    $null = New-Item -ItemType Directory -Path $history -Force
    $null = New-Item -ItemType Directory -Path $handoff -Force
    $dispatchRoot = Join-Path $Root ('.local\ai-sessions\worktrees\' + $Slug)
    $promptPath = Join-Path $Root 'prompt.md'
    $targetPath = Join-Path $Root 'target.txt'
    $lineContext = @(
        'LineContext:'
        ('lineSlug=' + $lineSlug)
        ('sourceRoot=' + $Root)
        ('sourceLineRoot=' + $handoff)
        ('dispatchRoot=' + $dispatchRoot)
        ('dispatchLineRoot=' + (Join-Path $dispatchRoot ('.local\ai-sessions\handoff\' + $lineSlug)))
        ('reportLineRoot=' + (Join-Path $dispatchRoot ('.local\ai-sessions\report\' + $lineSlug)))
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $handoff 'line.json'), ((ConvertTo-Json -InputObject ([ordered]@{ schema = 'ai-sessions.line.v1'; 'line-slug' = $lineSlug; kind = 'workflow' }) -Depth 5) + "`n"), $utf8NoBom)
    [IO.File]::WriteAllText($promptPath, ($lineContext + "`n`n" + 'fixture prompt'), $utf8NoBom)
    [IO.File]::WriteAllText($targetPath, 'fixture target', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $handoff ('dispatch-order-' + $Slug + '.md')), ("## 3. 目標物件`n`n- " + $targetPath + "`n`n## 4. 任務內容`n`ntask`n`n## 5. 驗收條件`n`nx`n"), $utf8NoBom)
    $document = [ordered]@{
        schema = 'ai-sessions.dispatch-request.v1'
        operation = 'Dispatch'
        line_slug = $lineSlug
        dispatch_slug = $Slug
        source_root = $Root
        dispatch_root = $dispatchRoot
        profile = 'scan'
        write_mode = 'readonly'
        dispatch_kind = 'resource'
        prompt_path = $promptPath
        target_path = @($targetPath)
        task_type = 'script-change'
        session_mode = 'cold-start'
        unit_kind = 'resource-target'
        requested_unit = @($targetPath)
        failure_receipt_path = (Join-Path $history ('failure-receipt-' + $Slug + '.json'))
        result_path = (Join-Path $history ('dispatch-result-' + $Slug + '.json'))
        prepare_artifacts = @([ordered]@{ source = $promptPath; destination = (Join-Path $dispatchRoot 'prompt-copy.md'); sha256 = ('0' * 64); purpose = 'fixture' })
    }
    $requestPath = Join-Path $history ('dispatch-request-' + $Slug + '.json')
    [IO.File]::WriteAllText($requestPath, ((ConvertTo-Json -InputObject $document -Depth 20) + "`n"), $utf8NoBom)
    return [pscustomobject]@{ root = $Root; line = $lineSlug; slug = $Slug; history = $history; request_path = $requestPath; document = $document }
}

# 子程序入口：複製 scripts 到暫存目錄，使 .local\machine.json 與入口腳本的相對位置和正式配置相同。
function TrNewE2E {
    param([string]$Name)
    $envRoot = TrNewDir -Name $Name
    $null = & robocopy.exe $scriptsRoot (Join-Path $envRoot 'scripts') /E /XD tests /NFL /NDL /NJH /NJS /NP
    $source = Join-Path $envRoot 'src'
    $null = New-Item -ItemType Directory -Path $source -Force
    return [pscustomobject]@{ root = $envRoot; source = $source; entry = (Join-Path $envRoot 'scripts\Invoke-CodexDispatch.ps1'); machine = (Join-Path $envRoot '.local\machine.json'); homes = (Join-Path $envRoot 'homes') }
}

function TrRunProcess {
    param([string]$FileName, [string[]]$Argument)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FileName
    $startInfo.Arguments = (@($Argument | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $utf8NoBom
    $startInfo.StandardErrorEncoding = $utf8NoBom
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $result = [pscustomobject]@{ exit_code = [int]$process.ExitCode; stdout = $stdoutTask.Result; stderr = $stderrTask.Result }
    $process.Dispose()
    return $result
}

function TrRunDispatch {
    param([object]$E2E, [object]$Request, [string[]]$ExtraArgument = @())
    $arguments = @('-NoProfile', '-NonInteractive', '-File', $E2E.entry, '-Operation', 'Dispatch', '-RequestPath', $Request.request_path) + @($ExtraArgument)
    $run = TrRunProcess -FileName $hostPath -Argument $arguments
    $result = $null
    $text = $run.stdout
    $first = $text.IndexOf('{')
    $last = $text.LastIndexOf('}')
    if ($first -ge 0 -and $last -gt $first) { try { $result = ConvertFrom-Json -InputObject $text.Substring($first, $last - $first + 1) } catch { $result = $null } }
    return [pscustomobject]@{ exit_code = $run.exit_code; stdout = $run.stdout; stderr = $run.stderr; result = $result }
}

function TrSourceKey {
    param([string]$Root)
    return $Root.ToLowerInvariant()
}

try {
    # ---------- 已信任不改檔 ----------
    Test-Case A01 {
        $root = TrNewDir -Name 'src'
        $acctHome = TrNewHome -Root $root -Name 'h1' -Config (TrTrustText -Key @((TrSourceKey $root)))
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @(TrAccount 'a' $acctHome)
        $configPath = Join-Path $acctHome 'config.toml'
        $before = TrBytes $configPath
        $time = (Get-Item -LiteralPath $configPath).LastWriteTimeUtc
        $result = Confirm-CodexAccountProjectTrust -AccountSelection (TrSelection -AccountHome $acctHome) -SourceRoot $root -MachineConfigPath $machine
        $after = TrBytes $configPath
        $result.action -ceq 'already-trusted' -and $null -eq $result.reason_code -and (TrSameBytes $before $after) -and (Get-Item -LiteralPath $configPath).LastWriteTimeUtc -eq $time -and
        $result.config_sha256_before -ceq $result.config_sha256_after -and -not [string]::IsNullOrWhiteSpace($result.config_sha256_before) -and $result.trust_key -ceq (TrSourceKey $root) -and -not $result.windows_section_added
    }

    # ---------- 缺少時補上 ----------
    Test-Case A02 {
        $root = TrNewDir -Name 'src'
        $original = TrTrustText -Key @() -Windows $true
        $acctHome = TrNewHome -Root $root -Name 'h1' -Config $original
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @(TrAccount 'a' $acctHome)
        $configPath = Join-Path $acctHome 'config.toml'
        $before = TrBytes $configPath
        $result = Confirm-CodexAccountProjectTrust -AccountSelection (TrSelection -AccountHome $acctHome) -SourceRoot $root -MachineConfigPath $machine
        $after = TrBytes $configPath
        $text = [IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8)
        $prefixKept = $after.Length -gt $before.Length -and (TrSameBytes $before ([byte[]]@($after[0..($before.Length - 1)])))
        $added = $text.Substring($original.Length)
        $result.action -ceq 'added' -and -not $result.windows_section_added -and $prefixKept -and
        $added -ceq ("`n[projects.'" + (TrSourceKey $root) + "']`ntrust_level = `"trusted`"`n") -and
        ([regex]::Matches($text, '\[projects\.')).Count -eq 1 -and $result.config_sha256_before -cne $result.config_sha256_after
    }
    Test-Case A03 {
        $results = @()
        foreach ($variant in @('', ('model = "x"' + "`n"))) {
            $root = TrNewDir -Name 'src'
            $acctHome = TrNewHome -Root $root -Name 'h1' -Config $variant
            $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @(TrAccount 'a' $acctHome)
            $result = Confirm-CodexAccountProjectTrust -AccountSelection (TrSelection -AccountHome $acctHome) -SourceRoot $root -MachineConfigPath $machine
            $text = [IO.File]::ReadAllText((Join-Path $acctHome 'config.toml'), [Text.Encoding]::UTF8)
            $results += [pscustomobject]@{ action = $result.action; windows = $result.windows_section_added; starts = $text.StartsWith($variant); windowsCount = ([regex]::Matches($text, '\[windows\]')).Count; projects = ([regex]::Matches($text, '\[projects\.')).Count; mxc = $text.Contains("[windows]`nsandbox = `"mxc`"`n"); elevated = $text.Contains('elevated') }
        }
        @($results | Where-Object { $_.action -ceq 'added' -and $_.windows -and $_.starts -and $_.windowsCount -eq 1 -and $_.projects -eq 1 -and $_.mxc -and -not $_.elevated }).Count -eq 2
    }

    # ---------- 只信任專案根目錄 ----------
    Test-Case B01 {
        $root = TrNewDir -Name 'Mixed-Case-Src'
        $upper = $root.ToUpperInvariant()
        $acctHome = TrNewHome -Root $root -Name 'h1' -Config (TrTrustText -Key @())
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @(TrAccount 'a' $acctHome)
        $result = Confirm-CodexAccountProjectTrust -AccountSelection (TrSelection -AccountHome $acctHome) -SourceRoot $upper -MachineConfigPath $machine
        $text = [IO.File]::ReadAllText((Join-Path $acctHome 'config.toml'), [Text.Encoding]::UTF8)
        $result.trust_key -ceq $root.ToLowerInvariant() -and $text.Contains("[projects.'" + $root.ToLowerInvariant() + "']") -and -not $text.Contains($upper)
    }
    Test-Case B02 {
        $root = TrNewDir -Name 'src'
        $acctHome = TrNewHome -Root $root -Name 'h1' -Config (TrTrustText -Key @())
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @(TrAccount 'a' $acctHome)
        $null = Confirm-CodexAccountProjectTrust -AccountSelection (TrSelection -AccountHome $acctHome) -SourceRoot $root -MachineConfigPath $machine
        $text = [IO.File]::ReadAllText((Join-Path $acctHome 'config.toml'), [Text.Encoding]::UTF8)
        $keys = @([regex]::Matches($text, "\[projects\.'([^']+)'\]") | ForEach-Object { $_.Groups[1].Value })
        $ancestor = Split-Path -Parent $root
        $ancestorHits = 0
        while ($ancestor) {
            if ($keys -contains $ancestor.ToLowerInvariant()) { $ancestorHits++ }
            $parent = Split-Path -Parent $ancestor
            if ($parent -eq $ancestor) { break }
            $ancestor = $parent
        }
        $keys.Count -eq 1 -and $keys[0] -ceq $root.ToLowerInvariant() -and $ancestorHits -eq 0
    }
    Test-Case B03 {
        # linked worktree 的信任鍵為 git 主工作樹根（Codex 以主工作樹根判定信任）。
        $base = TrNewDir -Name 'git'
        $main = Join-Path $base 'Main-Repo'
        $linked = Join-Path $base 'linked-checkout'
        $worktreeGitDir = Join-Path $main '.git\worktrees\wt1'
        $null = New-Item -ItemType Directory -Path $worktreeGitDir -Force
        $null = New-Item -ItemType Directory -Path $linked -Force
        [IO.File]::WriteAllText((Join-Path $main '.git\HEAD'), 'ref: refs/heads/main', $utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $worktreeGitDir 'gitdir'), (($linked + '\.git').Replace('\', '/') + "`n"), $utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $worktreeGitDir 'commondir'), "../..`n", $utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $linked '.git'), ('gitdir: ' + $worktreeGitDir.Replace('\', '/') + "`n"), $utf8NoBom)
        $fromLinked = Resolve-CodexProjectTrustKey -SourceRoot $linked
        $fromMain = Resolve-CodexProjectTrustKey -SourceRoot $main
        $acctHome = TrNewHome -Root $base -Name 'h1' -Config (TrTrustText -Key @())
        $machine = TrWriteMachine -Path (Join-Path $base 'm\machine.json') -Account @(TrAccount 'a' $acctHome)
        $result = Confirm-CodexAccountProjectTrust -AccountSelection (TrSelection -AccountHome $acctHome) -SourceRoot $linked -MachineConfigPath $machine
        $text = [IO.File]::ReadAllText((Join-Path $acctHome 'config.toml'), [Text.Encoding]::UTF8)
        $fromLinked.trust_key -ceq $main.ToLowerInvariant() -and $fromLinked.trust_root_kind -ceq 'main-worktree' -and $fromMain.trust_key -ceq $main.ToLowerInvariant() -and $fromMain.trust_root_kind -ceq 'source-root' -and
        $result.trust_key -ceq $main.ToLowerInvariant() -and $text.Contains("[projects.'" + $main.ToLowerInvariant() + "']") -and -not $text.Contains($linked.ToLowerInvariant())
    }
    Test-Case B04 {
        $base = TrNewDir -Name 'badgit'
        $checkout = Join-Path $base 'checkout'
        $null = New-Item -ItemType Directory -Path (Join-Path $base 'elsewhere') -Force
        $null = New-Item -ItemType Directory -Path $checkout -Force
        [IO.File]::WriteAllText((Join-Path $checkout '.git'), ('gitdir: ' + (Join-Path $base 'elsewhere').Replace('\', '/') + "`n"), $utf8NoBom)
        $exception = TrCatch { Resolve-CodexProjectTrustKey -SourceRoot $checkout }
        $null -ne $exception -and $exception.Message -match '^CodexProjectPathUnsupported：' -and [string]$exception.Data['errorCode'] -ceq 'CodexProjectPathUnsupported'
    }

    # ---------- 候選階段：略過分類（唯讀） ----------
    $rootC = TrNewDir -Name 'cand'
    $srcC = Join-Path $rootC 'src'
    $null = New-Item -ItemType Directory -Path $srcC -Force
    $keyC = TrSourceKey $srcC
    $okHome = TrNewHome -Root $rootC -Name 'ok' -Config (TrTrustText -Key @($keyC))
    $linkHome = TrNewHome -Root $rootC -Name 'link' -Config $null
    $linkTarget = TrMakeJunctionConfig -AccountHome $linkHome
    $dirHome = TrNewHome -Root $rootC -Name 'dir' -Config $null
    $null = New-Item -ItemType Directory -Path (Join-Path $dirHome 'config.toml') -Force
    $missHome = TrNewHome -Root $rootC -Name 'miss' -Config $null
    $tripleHome = TrNewHome -Root $rootC -Name 'triple' -Config ('x = """a"""' + "`n")
    $sectionHome = TrNewHome -Root $rootC -Name 'section' -Config ("[windows]`nsandbox = `"elevated`"`n`n[a b]`nx = 1`n")
    $dupHome = TrNewHome -Root $rootC -Name 'dup' -Config ("[projects.'c:\other']`ntrust_level = `"trusted`"`n[projects.'c:\other']`ntrust_level = `"trusted`"`n")
    $untrustedHome = TrNewHome -Root $rootC -Name 'untrusted' -Config ("[windows]`nsandbox = `"elevated`"`n`n[projects.'" + $keyC + "']`ntrust_level = `"untrusted`"`n")
    $noLoginHome = TrNewHome -Root $rootC -Name 'nologin' -Config (TrTrustText -Key @($keyC)) -Login none
    $machineC = TrWriteMachine -Path (Join-Path $rootC 'm\machine.json') -Account @(
        (TrAccount 'ok' $okHome), (TrAccount 'link' $linkHome), (TrAccount 'dir' $dirHome), (TrAccount 'miss' $missHome), (TrAccount 'triple' $tripleHome),
        (TrAccount 'section' $sectionHome), (TrAccount 'dup' $dupHome), (TrAccount 'untrusted' $untrustedHome), (TrAccount 'nologin' $noLoginHome))
    $fileSnapshotBefore = @{}
    foreach ($snapshotHome in @($okHome, $tripleHome, $sectionHome, $dupHome, $untrustedHome)) { $fileSnapshotBefore[$snapshotHome] = TrBytes (Join-Path $snapshotHome 'config.toml') }
    $candidateSet = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $machineC -SourceRoot $srcC
    Test-Case C01 {
        (@($candidateSet.candidates | ForEach-Object { $_.name }) -join ',') -ceq 'ok' -and
        (@($candidateSet.skipped | ForEach-Object { $_.name + ':' + $_.reason_code }) -join ',') -ceq 'link:TrustConfigLinked,dir:TrustConfigLinked,miss:TrustConfigMissing,triple:TrustConfigUnsupported,section:TrustConfigUnsupported,dup:TrustConfigUnsupported,untrusted:TrustConfigUnsupported,nologin:LoginFileMissing'
    }
    Test-Case C02 {
        $linkSkip = @($candidateSet.skipped | Where-Object { $_.name -ceq 'link' })[0]
        $dirSkip = @($candidateSet.skipped | Where-Object { $_.name -ceq 'dir' })[0]
        $linkSkip.detail.Contains('LinkType=Junction') -and $linkSkip.detail.Contains('Target=') -and $linkSkip.detail.Contains('junction-target') -and $linkSkip.config_path -ieq (Join-Path $linkHome 'config.toml') -and
        -not [string]::IsNullOrWhiteSpace($dirSkip.detail) -and $dirSkip.config_path -ieq (Join-Path $dirHome 'config.toml')
    }
    Test-Case C03 {
        $unsupported = @($candidateSet.skipped | Where-Object { $_.reason_code -ceq 'TrustConfigUnsupported' })
        $unsupported.Count -eq 4 -and @($unsupported | Where-Object { $_.detail -notmatch ':\d+' }).Count -eq 0 -and
        @($unsupported | Where-Object { $_.name -ceq 'triple' })[0].detail -match ':1$' -and @($unsupported | Where-Object { $_.name -ceq 'untrusted' })[0].detail -match ':5$'
    }
    Test-Case C04 {
        # 被略過的帳號不改寫：位元組、連結類型與連結目標不變。
        $unchanged = $true
        foreach ($snapshotHome in $fileSnapshotBefore.Keys) { if (-not (TrSameBytes $fileSnapshotBefore[$snapshotHome] (TrBytes (Join-Path $snapshotHome 'config.toml')))) { $unchanged = $false } }
        $linkItem = Get-Item -LiteralPath (Join-Path $linkHome 'config.toml') -Force
        $unchanged -and $linkItem.LinkType -ceq 'Junction' -and (Test-Path -LiteralPath (Join-Path $linkTarget 'marker.txt')) -and (Test-Path -LiteralPath (Join-Path $dirHome 'config.toml') -PathType Container) -and -not (Test-Path -LiteralPath (Join-Path $missHome 'config.toml'))
    }
    Test-Case C05 {
        # 登入類略過項目的 config_path 與 detail 為 null；既有欄位不變。
        $loginSkip = @($candidateSet.skipped | Where-Object { $_.name -ceq 'nologin' })[0]
        $names = @($loginSkip.PSObject.Properties.Name)
        $null -eq $loginSkip.config_path -and $null -eq $loginSkip.detail -and @('name', 'codex_home', 'reason_code', 'login_file_path', 'login_file_length', 'login_file_last_write_utc', 'config_path', 'detail' | Where-Object { $names -notcontains $_ }).Count -eq 0
    }
    Test-Case C06 {
        # 未提供 -SourceRoot 時行為與 P10 相同，不做信任預檢。
        $legacy = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $machineC
        (@($legacy.candidates | ForEach-Object { $_.name }) -join ',') -ceq 'ok,link,dir,miss,triple,section,dup,untrusted' -and @($legacy.skipped).Count -eq 1
    }
    Test-Case C07 {
        $summary = Format-CodexAccountSkippedSummary -Skipped @($candidateSet.skipped)
        $summary.Contains('link:TrustConfigLinked:' + (Join-Path $linkHome 'config.toml')) -and $summary.Contains('nologin:LoginFileMissing:' + (Join-Path $noLoginHome 'auth.json'))
    }

    # 帳號健康狀態（model 不支援記憶）與信任預檢並存：登入、檔位設定檔與信任判定的略過原因優先，健康狀態只作用於其餘帳號。
    $healthRecordedAt = [DateTimeOffset]::new(2026, 11, 10, 8, 0, 0, [TimeSpan]::Zero)
    Test-Case C08 {
        $healthPath = Get-CodexAccountHealthPath -MachineConfigPath $machineC
        try {
            $null = Register-CodexAccountHealth -AccountName 'ok' -CodexHome $okHome -Profile 'scan' -Model 'fixture-model' -ReasonCode 'model-not-supported' -MachineConfigPath $machineC -NowUtc $healthRecordedAt
            $null = Register-CodexAccountHealth -AccountName 'link' -CodexHome $linkHome -Profile 'scan' -Model 'fixture-model' -ReasonCode 'model-not-supported' -MachineConfigPath $machineC -NowUtc $healthRecordedAt
            $overridden = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $machineC -SourceRoot $srcC -NowUtc $healthRecordedAt.AddHours(1)
            $expired = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $machineC -SourceRoot $srcC -NowUtc $healthRecordedAt.AddHours(25)
            $linkSkip = @($overridden.skipped | Where-Object { $_.name -ceq 'link' })[0]
            # 信任可用的帳號只剩 ok 且被記錄時，仍實際嘗試一次；其餘帳號維持原略過原因。
            (@($overridden.candidates | ForEach-Object { $_.name }) -join ',') -ceq 'ok' -and $overridden.candidates[0].health_override -eq $true -and @($overridden.skipped | Where-Object { $_.name -ceq 'ok' }).Count -eq 0 -and
            $linkSkip.reason_code -ceq 'TrustConfigLinked' -and (@($overridden.skipped | ForEach-Object { $_.name + ':' + $_.reason_code }) -join ',') -ceq (@($candidateSet.skipped | ForEach-Object { $_.name + ':' + $_.reason_code }) -join ',') -and
            (@($expired.candidates | ForEach-Object { $_.name }) -join ',') -ceq 'ok' -and $null -eq $expired.candidates[0].PSObject.Properties['health_override']
        }
        finally { if (Test-Path -LiteralPath $healthPath) { Remove-Item -LiteralPath $healthPath -Force } }
    }
    Test-Case C09 {
        # 沒有狀態檔時結果與既有案例相同（C01），呼叫形狀不變。
        $plain = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $machineC -SourceRoot $srcC
        -not (Test-Path -LiteralPath (Get-CodexAccountHealthPath -MachineConfigPath $machineC)) -and (@($plain.candidates | ForEach-Object { $_.name }) -join ',') -ceq 'ok' -and @($plain.skipped).Count -eq @($candidateSet.skipped).Count
    }

    # ---------- 指定 -CodexHome（explicit）遇到設定異常時直接拒絕 ----------
    Test-Case D01 {
        $selection = Resolve-CodexAccountSelection -CodexHomePath $linkHome -Profile 'scan' -MachineConfigPath $machineC -SourceRoot $srcC
        $exception = TrCatch { Confirm-CodexAccountProjectTrust -AccountSelection $selection -SourceRoot $srcC -MachineConfigPath $machineC }
        $selection.Mode -ceq 'explicit' -and $selection.AccountName -ceq 'link' -and $null -ne $exception -and $exception.Message -match '^CodexAccountConfigLinked：' -and $exception.Message.Contains('LinkType=Junction') -and $exception.Message.Contains('Target=') -and
        $exception.Message.Contains("(Get-Item -LiteralPath '") -and -not $exception.Message.Contains('Remove-Item -Recurse') -and [string]$exception.Data['errorCode'] -ceq 'CodexAccountConfigLinked' -and
        (Get-Item -LiteralPath (Join-Path $linkHome 'config.toml') -Force).LinkType -ceq 'Junction'
    }
    Test-Case D02 {
        $selection = Resolve-CodexAccountSelection -CodexHomePath $missHome -Profile 'scan' -MachineConfigPath $machineC -SourceRoot $srcC
        $exception = TrCatch { Confirm-CodexAccountProjectTrust -AccountSelection $selection -SourceRoot $srcC -MachineConfigPath $machineC }
        $null -ne $exception -and $exception.Message -match '^CodexAccountConfigMissing：' -and $exception.Message.Contains((Join-Path $missHome 'config.toml')) -and [string]$exception.Data['errorCode'] -ceq 'CodexAccountConfigMissing' -and -not (Test-Path -LiteralPath (Join-Path $missHome 'config.toml'))
    }
    Test-Case D03 {
        $codes = @()
        foreach ($case in @(@{ home = $tripleHome; line = ':1' }, @{ home = $sectionHome; line = ':5' }, @{ home = $dupHome; line = ':3' }, @{ home = $untrustedHome; line = ':5' })) {
            $before = TrBytes (Join-Path $case.home 'config.toml')
            $selection = TrSelection -AccountHome $case.home -Name 'x'
            $exception = TrCatch { Confirm-CodexAccountProjectTrust -AccountSelection $selection -SourceRoot $srcC -MachineConfigPath $machineC }
            $codes += [pscustomobject]@{ ok = ($null -ne $exception -and $exception.Message -match '^CodexAccountConfigUnsupported：' -and $exception.Message -match ':\d+' -and [string]$exception.Data['errorCode'] -ceq 'CodexAccountConfigUnsupported' -and (TrSameBytes $before (TrBytes (Join-Path $case.home 'config.toml')))) }
        }
        @($codes | Where-Object { -not $_.ok }).Count -eq 0
    }
    Test-Case D04 {
        $dirSelection = TrSelection -AccountHome $dirHome -Name 'dir'
        $exception = TrCatch { Confirm-CodexAccountProjectTrust -AccountSelection $dirSelection -SourceRoot $srcC -MachineConfigPath $machineC }
        $null -ne $exception -and $exception.Message -match '^CodexAccountConfigLinked：' -and (Test-Path -LiteralPath (Join-Path $dirHome 'config.toml') -PathType Container)
    }

    # ---------- sandbox 設定值：mxc 與 elevated 皆接受，缺 [windows] 補 mxc ----------
    $rootS = TrNewDir -Name 'sbx'
    $srcS = Join-Path $rootS 'src'
    $null = New-Item -ItemType Directory -Path $srcS -Force
    $keyS = TrSourceKey $srcS
    $sbxConfig = { param([string]$Value) ("[windows]`nsandbox = " + $Value + "`n`n[projects.'" + $keyS + "']`ntrust_level = `"trusted`"`n") }
    $sbxHomes = [ordered]@{
        mxc = TrNewHome -Root $rootS -Name 'mxc' -Config (& $sbxConfig '"mxc"')
        elevated = TrNewHome -Root $rootS -Name 'elevated' -Config (& $sbxConfig '"elevated"')
        unelevated = TrNewHome -Root $rootS -Name 'unelevated' -Config (& $sbxConfig '"unelevated"')
        upper = TrNewHome -Root $rootS -Name 'upper' -Config (& $sbxConfig '"MXC"')
        bare = TrNewHome -Root $rootS -Name 'bare' -Config (& $sbxConfig 'mxc')
    }
    $machineS = TrWriteMachine -Path (Join-Path $rootS 'm\machine.json') -Account @($sbxHomes.Keys | ForEach-Object { TrAccount $_ $sbxHomes[$_] })
    Test-Case S01 {
        $set = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $machineS -SourceRoot $srcS
        $unsupported = @($set.skipped | Where-Object { $_.reason_code -ceq 'TrustConfigUnsupported' })
        (@($set.candidates | ForEach-Object { $_.name }) -join ',') -ceq 'mxc,elevated' -and
        (@($set.skipped | ForEach-Object { $_.name + ':' + $_.reason_code }) -join ',') -ceq 'unelevated:TrustConfigUnsupported,upper:TrustConfigUnsupported,bare:TrustConfigUnsupported' -and
        @($unsupported | Where-Object { $_.detail -notmatch ':2$' }).Count -eq 0
    }
    Test-Case S02 {
        . (Get-CodexAccountConfigLibraryPath)
        $outcomes = @()
        foreach ($name in @('mxc', 'elevated')) {
            $path = Join-Path $sbxHomes[$name] 'config.toml'
            $plan = Get-AccountConfigPlan -Path $path -Keys @($keyS)
            $outcomes += [pscustomobject]@{ ok = (-not $plan.Changed -and -not $plan.WindowsAdded -and @($plan.Missing).Count -eq 0 -and (TrSameBytes $plan.Original (TrBytes $path)) -and (TrSameBytes $plan.Bytes (TrBytes $path))) }
        }
        @($outcomes | Where-Object { -not $_.ok }).Count -eq 0
    }
    Test-Case S03 {
        . (Get-CodexAccountConfigLibraryPath)
        $outcomes = @()
        foreach ($name in @('unelevated', 'upper', 'bare')) {
            $path = Join-Path $sbxHomes[$name] 'config.toml'
            $before = TrBytes $path
            $exception = TrCatch { Get-AccountConfigPlan -Path $path -Keys @($keyS) }
            $outcomes += [pscustomobject]@{ ok = ($null -ne $exception -and $exception.Message -match '^CodexAccountConfigUnsupported：' -and $exception.Message.Contains('無效 sandbox 設定') -and $exception.Message.Contains($path + ':2') -and [string]$exception.Data['reasonCode'] -ceq 'CodexAccountConfigUnsupported' -and [string]$exception.Data['detail'] -ceq ($path + ':2') -and (TrSameBytes $before (TrBytes $path))) }
        }
        @($outcomes | Where-Object { -not $_.ok }).Count -eq 0
    }
    Test-Case S04 {
        . (Get-CodexAccountConfigLibraryPath)
        $outcomes = @()
        foreach ($variant in @(@{ name = 'empty'; text = '' }, @{ name = 'other-keys'; text = ('model = "x"' + "`n") }, @{ name = 'missing-file'; text = $null })) {
            $dir = TrNewDir -Name ('sbx-' + $variant.name)
            $path = Join-Path $dir 'config.toml'
            if ($null -ne $variant.text) { [IO.File]::WriteAllText($path, $variant.text, $utf8NoBom) }
            $plan = Get-AccountConfigPlan -Path $path -Keys @()
            $text = $utf8NoBom.GetString($plan.Bytes)
            $outcomes += [pscustomobject]@{ ok = ($plan.Changed -and $plan.WindowsAdded -and ($null -eq $variant.text -or $text.StartsWith($variant.text)) -and $text.Contains("[windows]`nsandbox = `"mxc`"`n") -and -not $text.Contains('elevated')) }
        }
        @($outcomes | Where-Object { -not $_.ok }).Count -eq 0
    }

    # ---------- 改試下一個帳號 ----------
    Test-Case E01 {
        $root = TrNewDir -Name 'next'
        $src = Join-Path $root 'src'
        $null = New-Item -ItemType Directory -Path $src -Force
        $first = TrNewHome -Root $root -Name 'first' -Config $null
        $null = TrMakeJunctionConfig -AccountHome $first
        $second = TrNewHome -Root $root -Name 'second' -Config (TrTrustText -Key @())
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @((TrAccount 'first' $first), (TrAccount 'second' $second))
        $set = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $machine -SourceRoot $src
        $selection = Resolve-CodexAccountSelection -Profile 'scan' -MachineConfigPath $machine -SourceRoot $src
        $trust = Confirm-CodexAccountProjectTrust -AccountSelection $selection -SourceRoot $src -MachineConfigPath $machine
        $text = [IO.File]::ReadAllText((Join-Path $second 'config.toml'), [Text.Encoding]::UTF8)
        (@($set.candidates | ForEach-Object { $_.name }) -join ',') -ceq 'second' -and (@($set.skipped | ForEach-Object { $_.name + ':' + $_.reason_code }) -join ',') -ceq 'first:TrustConfigLinked' -and
        $selection.AccountName -ceq 'second' -and $selection.Mode -ceq 'auto' -and $trust.action -ceq 'added' -and $trust.account_name -ceq 'second' -and
        @($trust.skipped_accounts).Count -eq 1 -and $trust.skipped_accounts[0].name -ceq 'first' -and $trust.skipped_accounts[0].reason_code -ceq 'TrustConfigLinked' -and $trust.skipped_accounts[0].detail.Contains('LinkType=Junction') -and
        $text.Contains("[projects.'" + (TrSourceKey $src) + "']") -and (Get-Item -LiteralPath (Join-Path $first 'config.toml') -Force).LinkType -ceq 'Junction'
    }
    Test-Case E02 {
        $outcomes = @()
        foreach ($variant in @('missing', 'unsupported')) {
            $root = TrNewDir -Name ('next-' + $variant)
            $src = Join-Path $root 'src'
            $null = New-Item -ItemType Directory -Path $src -Force
            $firstConfig = if ($variant -eq 'missing') { $null } else { 'x = """a"""' + "`n" }
            $first = TrNewHome -Root $root -Name 'first' -Config $firstConfig
            $second = TrNewHome -Root $root -Name 'second' -Config (TrTrustText -Key @())
            $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @((TrAccount 'first' $first), (TrAccount 'second' $second))
            $selection = Resolve-CodexAccountSelection -Profile 'scan' -MachineConfigPath $machine -SourceRoot $src
            $expected = if ($variant -eq 'missing') { 'TrustConfigMissing' } else { 'TrustConfigUnsupported' }
            $outcomes += [pscustomobject]@{ ok = ($selection.AccountName -ceq 'second' -and @($selection.Skipped).Count -eq 1 -and @($selection.Skipped)[0].reason_code -ceq $expected -and -not (Test-Path -LiteralPath (Join-Path $first 'config.toml') -PathType Leaf -ErrorAction SilentlyContinue) -eq ($variant -eq 'missing')) }
        }
        @($outcomes | Where-Object { -not $_.ok }).Count -eq 0
    }
    Test-Case E03 {
        # 端對端：以子程序執行 Invoke-CodexDispatch 的 Dispatch，選第 2 個帳號並補信任，略過原因寫入 project_trust。
        $e2e = TrNewE2E -Name 'e2e-next'
        $first = TrNewHome -Root $e2e.homes -Name 'first' -Config $null
        $null = TrMakeJunctionConfig -AccountHome $first
        $second = TrNewHome -Root $e2e.homes -Name 'second' -Config (TrTrustText -Key @())
        $null = TrWriteMachine -Path $e2e.machine -Account @((TrAccount 'first' $first), (TrAccount 'second' $second))
        $request = TrNewRequest -Root $e2e.source
        $run = TrRunDispatch -E2E $e2e -Request $request
        $text = [IO.File]::ReadAllText((Join-Path $second 'config.toml'), [Text.Encoding]::UTF8)
        # 換帳號外層啟動子程序（explicit 模式）完成補寫，略過原因在外層 account_failover_summary.skipped。
        $null -ne $run.result -and $null -ne $run.result.project_trust -and $run.result.project_trust.action -ceq 'added' -and $run.result.project_trust.account_name -ceq 'second' -and
        $run.result.project_trust.trust_key -ceq (TrSourceKey $e2e.source) -and $run.result.account_failover_summary.attempt_count -eq 1 -and @($run.result.account_failover_summary.skipped).Count -eq 1 -and
        $run.result.account_failover_summary.skipped[0].name -ceq 'first' -and $run.result.account_failover_summary.skipped[0].reason_code -ceq 'TrustConfigLinked' -and $run.result.account_failover_summary.skipped[0].detail.Contains('LinkType=Junction') -and
        $text.Contains("[projects.'" + (TrSourceKey $e2e.source) + "']") -and (Get-Item -LiteralPath (Join-Path $first 'config.toml') -Force).LinkType -ceq 'Junction'
    }
    Test-Case E04 {
        # 端對端：不換帳號的單次派遣（-NoAccountFailover）由選帳號階段略過第 1 個，project_trust.skipped_accounts 記錄原因。
        $e2e = TrNewE2E -Name 'e2e-single'
        $first = TrNewHome -Root $e2e.homes -Name 'first' -Config $null
        $null = TrMakeJunctionConfig -AccountHome $first
        $second = TrNewHome -Root $e2e.homes -Name 'second' -Config (TrTrustText -Key @())
        $null = TrWriteMachine -Path $e2e.machine -Account @((TrAccount 'first' $first), (TrAccount 'second' $second))
        $request = TrNewRequest -Root $e2e.source
        $run = TrRunDispatch -E2E $e2e -Request $request -ExtraArgument @('-NoAccountFailover')
        $text = [IO.File]::ReadAllText((Join-Path $second 'config.toml'), [Text.Encoding]::UTF8)
        $null -ne $run.result -and $run.result.project_trust.action -ceq 'added' -and $run.result.project_trust.account_name -ceq 'second' -and @($run.result.project_trust.skipped_accounts).Count -eq 1 -and
        $run.result.project_trust.skipped_accounts[0].name -ceq 'first' -and $run.result.project_trust.skipped_accounts[0].reason_code -ceq 'TrustConfigLinked' -and $run.result.project_trust.skipped_accounts[0].detail.Contains('LinkType=Junction') -and
        $text.Contains("[projects.'" + (TrSourceKey $e2e.source) + "']") -and (Get-Item -LiteralPath (Join-Path $first 'config.toml') -Force).LinkType -ceq 'Junction' -and $null -eq (Get-Member -InputObject $run.result -Name 'account_failover_summary' -MemberType NoteProperty)
    }

    # ---------- 全部略過或拒絕 ----------
    Test-Case F01 {
        $root = TrNewDir -Name 'allskip'
        $src = Join-Path $root 'src'
        $null = New-Item -ItemType Directory -Path $src -Force
        $a = TrNewHome -Root $root -Name 'a' -Config (TrTrustText -Key @((TrSourceKey $src))) -Login none
        $b = TrNewHome -Root $root -Name 'b' -Config $null
        $null = TrMakeJunctionConfig -AccountHome $b
        $c = TrNewHome -Root $root -Name 'c' -Config $null
        $d = TrNewHome -Root $root -Name 'd' -Config ('x = """a"""' + "`n")
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @((TrAccount 'a' $a), (TrAccount 'b' $b), (TrAccount 'c' $c), (TrAccount 'd' $d))
        $exception = TrCatch { Resolve-CodexAccountSelection -Profile 'scan' -MachineConfigPath $machine -SourceRoot $src }
        $null -ne $exception -and $exception.Message -match '^CodexAccountsAllUnavailable：' -and $exception.Message.Contains('a:LoginFileMissing') -and $exception.Message.Contains('b:TrustConfigLinked:' + (Join-Path $b 'config.toml')) -and
        $exception.Message.Contains('c:TrustConfigMissing:' + (Join-Path $c 'config.toml')) -and $exception.Message.Contains('d:TrustConfigUnsupported:' + (Join-Path $d 'config.toml'))
    }

    $script:TrAttemptLog = New-Object 'System.Collections.Generic.List[object]'
    $script:TrAttemptBehavior = $null
    $realAttemptProcess = ${function:Invoke-DispatchAttemptProcess}
    function Invoke-DispatchAttemptProcess {
        [CmdletBinding()]
        param([string]$RequestPath, [string]$CodexHome, [string[]]$ForwardArgument = @(), [string]$ResultPathHint)
        $requestDocument = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($RequestPath, [Text.Encoding]::UTF8))
        $null = $script:TrAttemptLog.Add([pscustomobject]@{ codex_home = $CodexHome; slug = [string]$requestDocument.dispatch_slug })
        $result = & $script:TrAttemptBehavior $requestDocument $CodexHome
        return [pscustomobject]@{ exit_code = $(if ($null -ne $result -and [string]$result.status -eq 'completed') { 0 } else { 1 }); stdout = ''; stderr = ''; result = $result; result_path = $null }
    }
    function TrRunFailover {
        param([object]$Request, [string]$MachinePath, [scriptblock]$Behavior)
        $script:TrAttemptLog.Clear()
        $script:TrAttemptBehavior = $Behavior
        $outcome = [ordered]@{ result = $null; error = $null; summary = $null }
        try { $outcome.result = Invoke-DispatchAccountFailover -RequestPath $Request.request_path -Profile 'scan' -MachineConfigPath $MachinePath -BoundParameter $null }
        catch { $outcome.error = [string]$_.Exception.Message }
        $summaryPath = Join-Path $Request.history ('dispatch-account-failover-' + $Request.slug + '.json')
        if (Test-Path -LiteralPath $summaryPath -PathType Leaf) { $outcome.summary = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($summaryPath, [Text.Encoding]::UTF8)) }
        return [pscustomobject]$outcome
    }

    Test-Case F02 {
        # 換帳號外層：候選為 0（全部未登入或設定異常）時寫摘要檔，all_unavailable=true、attempts=[]、skipped 含信任類原因。
        $root = TrNewDir -Name 'f02'
        $src = Join-Path $root 'src'
        $null = New-Item -ItemType Directory -Path $src -Force
        $b = TrNewHome -Root $root -Name 'b' -Config $null
        $null = TrMakeJunctionConfig -AccountHome $b
        $c = TrNewHome -Root $root -Name 'c' -Config $null
        $d = TrNewHome -Root $root -Name 'd' -Config (TrTrustText -Key @((TrSourceKey $src))) -Login none
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @((TrAccount 'b' $b), (TrAccount 'c' $c), (TrAccount 'd' $d))
        $request = TrNewRequest -Root $src
        $run = TrRunFailover -Request $request -MachinePath $machine -Behavior { param($document, $accountHomeArg) throw '不應被呼叫' }
        $reasons = @($run.summary.skipped | ForEach-Object { $_.name + ':' + $_.reason_code }) -join ','
        $null -ne $run.summary -and [bool]$run.summary.all_unavailable -and @($run.summary.attempts).Count -eq 0 -and $reasons -ceq 'b:TrustConfigLinked,c:TrustConfigMissing,d:LoginFileMissing' -and
        $run.error -match '^CodexAccountsAllUnavailable：' -and $run.error.Contains('b:TrustConfigLinked:') -and $script:TrAttemptLog.Count -eq 0 -and $run.summary.schema -ceq 'ai-sessions.dispatch-account-failover.v1'
    }
    Test-Case F03 {
        # 候選 N 個全被服務端拒絕且另有被略過的帳號：attempts 恰 N 筆、all_unavailable=true、skipped 仍列出被略過的帳號。
        $root = TrNewDir -Name 'f03'
        $src = Join-Path $root 'src'
        $null = New-Item -ItemType Directory -Path $src -Force
        $key = TrSourceKey $src
        $skipHome = TrNewHome -Root $root -Name 'skipme' -Config $null
        $one = TrNewHome -Root $root -Name 'one' -Config (TrTrustText -Key @($key))
        $two = TrNewHome -Root $root -Name 'two' -Config (TrTrustText -Key @($key))
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @((TrAccount 'skipme' $skipHome), (TrAccount 'one' $one), (TrAccount 'two' $two))
        $request = TrNewRequest -Root $src
        $run = TrRunFailover -Request $request -MachinePath $machine -Behavior {
            param($document, $codexHome)
            [pscustomobject][ordered]@{ schema = 'ai-sessions.dispatch-result.v1'; operation = 'Dispatch'; dispatch_slug = [string]$document.dispatch_slug; result_path = ('C:\fx\r-' + $document.dispatch_slug + '.json'); status = 'failed'; error_code = 'CodexTurnFailed'
                account_failover = [ordered]@{ eligible = $true; rejection_kind = 'usage-limit'; item_event_count = 0 } }
        }
        @($run.summary.attempts).Count -eq 2 -and [bool]$run.summary.all_unavailable -and @($run.summary.skipped).Count -eq 1 -and $run.summary.skipped[0].name -ceq 'skipme' -and $run.summary.skipped[0].reason_code -ceq 'TrustConfigMissing' -and
        (@($run.summary.attempts | ForEach-Object { $_.account_name }) -join ',') -ceq 'one,two' -and $script:TrAttemptLog.Count -eq 2 -and $run.result.account_failover_summary.all_unavailable -eq $true -and
        @($run.result.account_failover_summary.skipped).Count -eq 1 -and $run.result.account_failover_summary.skipped[0].reason_code -ceq 'TrustConfigMissing' -and -not (Test-Path -LiteralPath (Join-Path $skipHome 'config.toml'))
    }

    # ---------- 換帳號逐帳號補上 ----------
    Test-Case G01 {
        $root = TrNewDir -Name 'g01'
        $src = Join-Path $root 'src'
        $null = New-Item -ItemType Directory -Path $src -Force
        $first = TrNewHome -Root $root -Name 'first' -Config (TrTrustText -Key @())
        $second = TrNewHome -Root $root -Name 'second' -Config (TrTrustText -Key @())
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @((TrAccount 'first' $first), (TrAccount 'second' $second))
        $script:TrG01Machine = $machine
        $request = TrNewRequest -Root $src
        $run = TrRunFailover -Request $request -MachinePath $machine -Behavior {
            param($document, $codexHome)
            # 模擬子程序：explicit 模式下 Invoke-Dispatch 於 Preflight 前確認該帳號信任，再依帳號回報服務端拒絕或完成。
            $selection = [pscustomobject]@{ CodexHome = $codexHome; AccountName = (Split-Path -Leaf $codexHome); Mode = 'explicit'; Candidates = @(); Skipped = @() }
            $trust = Confirm-CodexAccountProjectTrust -AccountSelection $selection -SourceRoot ([string]$document.source_root) -MachineConfigPath $script:TrG01Machine
            $base = [ordered]@{ schema = 'ai-sessions.dispatch-result.v1'; operation = 'Dispatch'; dispatch_slug = [string]$document.dispatch_slug; result_path = ('C:\fx\r-' + $document.dispatch_slug + '.json'); project_trust = $trust }
            if ((Split-Path -Leaf $codexHome) -ceq 'first') {
                $base.status = 'failed'; $base.error_code = 'CodexTurnFailed'; $base.account_failover = [ordered]@{ eligible = $true; rejection_kind = 'usage-limit'; item_event_count = 0 }
            }
            else { $base.status = 'completed' }
            [pscustomobject]$base
        }
        $key = TrSourceKey $src
        $firstText = [IO.File]::ReadAllText((Join-Path $first 'config.toml'), [Text.Encoding]::UTF8)
        $secondText = [IO.File]::ReadAllText((Join-Path $second 'config.toml'), [Text.Encoding]::UTF8)
        $script:TrAttemptLog.Count -eq 2 -and $firstText.Contains("[projects.'" + $key + "']") -and $secondText.Contains("[projects.'" + $key + "']") -and
        @($run.summary.attempts).Count -eq 2 -and $run.summary.attempts[0].project_trust.action -ceq 'added' -and $run.summary.attempts[0].project_trust.account_name -ceq 'first' -and
        $run.summary.attempts[1].project_trust.action -ceq 'added' -and $run.summary.attempts[1].project_trust.account_name -ceq 'second' -and [string]$run.result.status -ceq 'completed'
    }
    Test-Case G02 {
        # 嘗試階段設定被改壞：該次嘗試失敗，不改試下一個帳號；第 2 個帳號不被改寫。
        $root = TrNewDir -Name 'g02'
        $src = Join-Path $root 'src'
        $null = New-Item -ItemType Directory -Path $src -Force
        $first = TrNewHome -Root $root -Name 'first' -Config (TrTrustText -Key @())
        $second = TrNewHome -Root $root -Name 'second' -Config (TrTrustText -Key @())
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @((TrAccount 'first' $first), (TrAccount 'second' $second))
        $script:TrG02Machine = $machine
        $script:TrG02FirstHome = $first
        $secondBefore = TrBytes (Join-Path $second 'config.toml')
        $request = TrNewRequest -Root $src
        $run = TrRunFailover -Request $request -MachinePath $machine -Behavior {
            param($document, $codexHome)
            if ((Split-Path -Leaf $codexHome) -ceq 'first') {
                # 候選階段通過後、嘗試階段前，設定被改成連結。
                Remove-Item -LiteralPath (Join-Path $script:TrG02FirstHome 'config.toml') -Force
                $null = TrMakeJunctionConfig -AccountHome $script:TrG02FirstHome
            }
            $selection = [pscustomobject]@{ CodexHome = $codexHome; AccountName = (Split-Path -Leaf $codexHome); Mode = 'explicit'; Candidates = @(); Skipped = @() }
            $base = [ordered]@{ schema = 'ai-sessions.dispatch-result.v1'; operation = 'Dispatch'; dispatch_slug = [string]$document.dispatch_slug; result_path = ('C:\fx\r-' + $document.dispatch_slug + '.json') }
            try {
                $trust = Confirm-CodexAccountProjectTrust -AccountSelection $selection -SourceRoot ([string]$document.source_root) -MachineConfigPath $script:TrG02Machine
                $base.status = 'completed'; $base.project_trust = $trust
            }
            catch {
                $base.status = 'failed'; $base.error_code = [string]$_.Exception.Data['errorCode']; $base.project_trust = New-CodexProjectTrustRejection -AccountSelection $selection -Exception $_.Exception
            }
            [pscustomobject]$base
        }
        $eligible = Test-DispatchAccountFailoverEligible -EventEvidence ([pscustomobject]@{ rejection_kind = $null; item_event_count = 0 })
        $script:TrAttemptLog.Count -eq 1 -and @($run.summary.attempts).Count -eq 1 -and $run.summary.attempts[0].outcome -ceq 'failed' -and $run.summary.attempts[0].project_trust.action -ceq 'rejected' -and $run.summary.attempts[0].project_trust.reason_code -ceq 'CodexAccountConfigLinked' -and
        -not [bool]$run.summary.all_unavailable -and [string]$run.result.error_code -ceq 'CodexAccountConfigLinked' -and -not $eligible -and (TrSameBytes $secondBefore (TrBytes (Join-Path $second 'config.toml')))
    }
    Test-Case G03 {
        # 與 P10 一致：schema 與既有欄位不變，略過原因出現在 skipped 與 account_failover_summary.skipped。
        $root = TrNewDir -Name 'g03'
        $src = Join-Path $root 'src'
        $null = New-Item -ItemType Directory -Path $src -Force
        $skipHome = TrNewHome -Root $root -Name 'skipme' -Config ('x = """a"""' + "`n")
        $okHome2 = TrNewHome -Root $root -Name 'okay' -Config (TrTrustText -Key @((TrSourceKey $src)))
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @((TrAccount 'skipme' $skipHome), (TrAccount 'okay' $okHome2))
        $request = TrNewRequest -Root $src
        $run = TrRunFailover -Request $request -MachinePath $machine -Behavior {
            param($document, $codexHome)
            [pscustomobject][ordered]@{ schema = 'ai-sessions.dispatch-result.v1'; operation = 'Dispatch'; dispatch_slug = [string]$document.dispatch_slug; result_path = 'C:\fx\r.json'; status = 'completed' }
        }
        $names = @($run.summary.PSObject.Properties.Name)
        $required = @('schema', 'line_slug', 'dispatch_slug', 'candidates', 'skipped', 'attempts', 'all_unavailable', 'final_attempt', 'skipped_reason')
        $evidenceNames = @($run.result.account_failover_summary.Keys)
        $evidenceRequired = @('summary_path', 'attempt_count', 'all_unavailable', 'error_code', 'skipped_reason', 'skipped')
        $run.summary.schema -ceq 'ai-sessions.dispatch-account-failover.v1' -and @($required | Where-Object { $names -notcontains $_ }).Count -eq 0 -and @($evidenceRequired | Where-Object { $evidenceNames -notcontains $_ }).Count -eq 0 -and
        $run.summary.skipped[0].reason_code -ceq 'TrustConfigUnsupported' -and $run.result.account_failover_summary.skipped[0].reason_code -ceq 'TrustConfigUnsupported' -and $run.summary.attempts[0].account_name -ceq 'okay' -and @($run.summary.attempts).Count -eq 1
    }

    # ---------- 不處理的 home ----------
    Test-Case I01 {
        $root = TrNewDir -Name 'na'
        $src = Join-Path $root 'src'
        $null = New-Item -ItemType Directory -Path $src -Force
        $registered = TrNewHome -Root $root -Name 'reg' -Config (TrTrustText -Key @())
        $other = TrNewHome -Root $root -Name 'other' -Config (TrTrustText -Key @())
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @((TrAccount 'reg' $registered))
        $emptyMachine = Join-Path $root 'empty.json'
        [IO.File]::WriteAllText($emptyMachine, '{"schema":"ai-agents.machine.v1","codex_accounts":[]}', $utf8NoBom)
        $otherBefore = TrBytes (Join-Path $other 'config.toml')
        $unregistered = Resolve-CodexAccountSelection -CodexHomePath $other -Profile 'scan' -MachineConfigPath $machine -SourceRoot $src
        $emptyList = Resolve-CodexAccountSelection -CodexHomePath $other -Profile 'scan' -MachineConfigPath $emptyMachine -SourceRoot $src
        $first = Confirm-CodexAccountProjectTrust -AccountSelection $unregistered -SourceRoot $src -MachineConfigPath $machine
        $second = Confirm-CodexAccountProjectTrust -AccountSelection $emptyList -SourceRoot $src -MachineConfigPath $emptyMachine
        $unregistered.Mode -ceq 'unregistered' -and $emptyList.Mode -ceq 'unregistered' -and $first.action -ceq 'not-applicable' -and $first.reason_code -ceq 'unregistered' -and $second.action -ceq 'not-applicable' -and
        (TrSameBytes $otherBefore (TrBytes (Join-Path $other 'config.toml'))) -and -not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $machine) 'codex-account.lock'))
    }
    Test-Case I02 {
        $root = TrNewDir -Name 'defaulthome'
        $src = Join-Path $root 'src'
        $null = New-Item -ItemType Directory -Path $src -Force
        $defaultHome = TrNewHome -Root $root -Name 'default-codex' -Config (TrTrustText -Key @())
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @((TrAccount 'x' $defaultHome))
        $before = TrBytes (Join-Path $defaultHome 'config.toml')
        $selection = TrSelection -AccountHome $defaultHome -Name 'x'
        $result = Confirm-CodexAccountProjectTrust -AccountSelection $selection -SourceRoot $src -MachineConfigPath $machine -DefaultCodexHome ($defaultHome.ToUpperInvariant() + '\')
        $result.action -ceq 'not-applicable' -and $result.reason_code -ceq 'default-codex-home' -and (TrSameBytes $before (TrBytes (Join-Path $defaultHome 'config.toml')))
    }

    # ---------- 路徑 ----------
    Test-Case J01 {
        $root = TrNewDir -Name 'path'
        $acctHome = TrNewHome -Root $root -Name 'h1' -Config (TrTrustText -Key @())
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @(TrAccount 'a' $acctHome)
        $before = TrBytes (Join-Path $acctHome 'config.toml')
        $bad = @("C:\a'b", ('C:\a' + [char]7 + 'b'), 'relative\path', 'C:relative', '')
        $failures = @()
        foreach ($sourceRootValue in $bad) {
            $exception = TrCatch { Confirm-CodexAccountProjectTrust -AccountSelection (TrSelection -AccountHome $acctHome) -SourceRoot $sourceRootValue -MachineConfigPath $machine }
            if ($null -eq $exception -or $exception.Message -notmatch '^CodexProjectPathUnsupported：' -or [string]$exception.Data['errorCode'] -cne 'CodexProjectPathUnsupported') { $failures += $sourceRootValue }
        }
        $candidateException = TrCatch { Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $machine -SourceRoot "C:\a'b" }
        $failures.Count -eq 0 -and $null -ne $candidateException -and $candidateException.Message -match '^CodexProjectPathUnsupported：' -and (TrSameBytes $before (TrBytes (Join-Path $acctHome 'config.toml')))
    }

    # ---------- 帳號數無關 ----------
    Test-Case K01 {
        $shapes = @()
        foreach ($count in 1, 2, 3) {
            $root = TrNewDir -Name ('count' + $count)
            $src = Join-Path $root 'src'
            $null = New-Item -ItemType Directory -Path $src -Force
            $accounts = @(foreach ($index in 1..$count) { TrAccount ('n' + $index) (TrNewHome -Root $root -Name ('n' + $index) -Config (TrTrustText -Key @())) })
            $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account $accounts
            $selection = Resolve-CodexAccountSelection -Profile 'scan' -MachineConfigPath $machine -SourceRoot $src
            $result = Confirm-CodexAccountProjectTrust -AccountSelection $selection -SourceRoot $src -MachineConfigPath $machine
            if ($result.action -cne 'added' -or $result.account_name -cne 'n1') { throw ('帳號數 ' + $count + ' 的確認結果不符。') }
            $shapes += , (@($result.PSObject.Properties.Name) -join '|')
        }
        @($shapes | Select-Object -Unique).Count -eq 1
    }

    # ---------- 並行寫入不遺失 ----------
    $driverPath = Join-Path $tempRoot 'trust-driver.ps1'
    $driverText = @'
param([string]$ScriptsRoot, [string]$MachinePath, [string]$AccountHome, [string]$SourceRoot, [string]$OutPath, [int]$HoldMs)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:DispatchEntryScriptRoot = $ScriptsRoot
foreach ($module in @('common-runtime', 'dispatch-evidence')) { . (Join-Path $ScriptsRoot ('dispatch\' + $module + '.ps1')) }
function Invoke-CodexAccountTrustBeforeWrite { param([string]$ConfigPath, [int]$Attempt) Start-Sleep -Milliseconds $HoldMs }
try {
    $selection = [pscustomobject]@{ CodexHome = $AccountHome; AccountName = 'acc'; Mode = 'explicit'; Candidates = @(); Skipped = @() }
    $result = Confirm-CodexAccountProjectTrust -AccountSelection $selection -SourceRoot $SourceRoot -MachineConfigPath $MachinePath -DefaultCodexHome 'C:\nonexistent-default-home'
    [IO.File]::WriteAllText($OutPath, (ConvertTo-Json -InputObject $result -Depth 6), (New-Object Text.UTF8Encoding($false)))
    exit 0
}
catch {
    [IO.File]::WriteAllText($OutPath, (ConvertTo-Json -InputObject ([ordered]@{ error = $_.Exception.Message }) -Depth 4), (New-Object Text.UTF8Encoding($false)))
    exit 1
}
'@
    [IO.File]::WriteAllText($driverPath, $driverText, $utf8NoBom)
    function TrStartDriver {
        param([string]$Machine, [string]$AccountHome, [string]$Source, [string]$Out, [int]$HoldMs = 400)
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $hostPath
        $arguments = @('-NoProfile', '-NonInteractive', '-File', $driverPath, '-ScriptsRoot', $scriptsRoot, '-MachinePath', $Machine, '-AccountHome', $AccountHome, '-SourceRoot', $Source, '-OutPath', $Out, '-HoldMs', [string]$HoldMs)
        $startInfo.Arguments = (@($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' ')
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        return [System.Diagnostics.Process]::Start($startInfo)
    }
    Test-Case L01 {
        $root = TrNewDir -Name 'concurrent'
        $acctHome = TrNewHome -Root $root -Name 'h1' -Config (TrTrustText -Key @() -Windows $true)
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @(TrAccount 'a' $acctHome)
        $processes = @()
        $sources = @()
        foreach ($index in 1..4) {
            $source = Join-Path $root ('proj' + $index)
            $null = New-Item -ItemType Directory -Path $source -Force
            $sources += $source
            $processes += , (TrStartDriver -Machine $machine -AccountHome $acctHome -Source $source -Out (Join-Path $root ('out' + $index + '.json')))
        }
        foreach ($process in $processes) { $process.WaitForExit() }
        $exitCodes = @($processes | ForEach-Object { $_.ExitCode })
        $text = [IO.File]::ReadAllText((Join-Path $acctHome 'config.toml'), [Text.Encoding]::UTF8)
        $allKeysOnce = $true
        foreach ($source in $sources) { if (([regex]::Matches($text, [regex]::Escape("[projects.'" + $source.ToLowerInvariant() + "']"))).Count -ne 1) { $allKeysOnce = $false } }
        $actions = @(foreach ($index in 1..4) { (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $root ('out' + $index + '.json')), [Text.Encoding]::UTF8))).action })
        @($exitCodes | Where-Object { $_ -ne 0 }).Count -eq 0 -and $allKeysOnce -and ([regex]::Matches($text, '\[windows\]')).Count -eq 1 -and ([regex]::Matches($text, '\[projects\.')).Count -eq 4 -and @($actions | Where-Object { $_ -ceq 'added' }).Count -eq 4
    }
    Test-Case L02 {
        $root = TrNewDir -Name 'concurrent-same'
        $acctHome = TrNewHome -Root $root -Name 'h1' -Config (TrTrustText -Key @() -Windows $true)
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @(TrAccount 'a' $acctHome)
        $source = Join-Path $root 'same'
        $null = New-Item -ItemType Directory -Path $source -Force
        $processes = @()
        foreach ($index in 1..2) { $processes += , (TrStartDriver -Machine $machine -AccountHome $acctHome -Source $source -Out (Join-Path $root ('out' + $index + '.json'))) }
        foreach ($process in $processes) { $process.WaitForExit() }
        $text = [IO.File]::ReadAllText((Join-Path $acctHome 'config.toml'), [Text.Encoding]::UTF8)
        $actions = @(foreach ($index in 1..2) { (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $root ('out' + $index + '.json')), [Text.Encoding]::UTF8))).action }) | Sort-Object
        ($actions -join ',') -ceq 'added,already-trusted' -and ([regex]::Matches($text, '\[projects\.')).Count -eq 1
    }

    # ---------- 外部修改與寫入失敗 ----------
    Test-Case M01 {
        $root = TrNewDir -Name 'external'
        $src = Join-Path $root 'src'
        $null = New-Item -ItemType Directory -Path $src -Force
        $acctHome = TrNewHome -Root $root -Name 'h1' -Config (TrTrustText -Key @())
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @(TrAccount 'a' $acctHome)
        $script:TrHookCalls = 0
        $script:TrHookHome = $acctHome
        function Invoke-CodexAccountTrustBeforeWrite {
            param([string]$ConfigPath, [int]$Attempt)
            $script:TrHookCalls++
            if ($script:TrHookCalls -eq 1) { [IO.File]::AppendAllText($ConfigPath, "# external edit`n", $utf8NoBom) }
        }
        $result = Confirm-CodexAccountProjectTrust -AccountSelection (TrSelection -AccountHome $acctHome) -SourceRoot $src -MachineConfigPath $machine
        $text = [IO.File]::ReadAllText((Join-Path $acctHome 'config.toml'), [Text.Encoding]::UTF8)
        $result.action -ceq 'added' -and $script:TrHookCalls -eq 2 -and $text.Contains('# external edit') -and $text.Contains("[projects.'" + (TrSourceKey $src) + "']")
    }
    Test-Case M02 {
        $root = TrNewDir -Name 'external3'
        $src = Join-Path $root 'src'
        $null = New-Item -ItemType Directory -Path $src -Force
        $acctHome = TrNewHome -Root $root -Name 'h1' -Config (TrTrustText -Key @())
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @(TrAccount 'a' $acctHome)
        $script:TrHookCalls = 0
        function Invoke-CodexAccountTrustBeforeWrite {
            param([string]$ConfigPath, [int]$Attempt)
            $script:TrHookCalls++
            [IO.File]::AppendAllText($ConfigPath, ('# external edit ' + $script:TrHookCalls + "`n"), $utf8NoBom)
        }
        $exception = TrCatch { Confirm-CodexAccountProjectTrust -AccountSelection (TrSelection -AccountHome $acctHome) -SourceRoot $src -MachineConfigPath $machine }
        $text = [IO.File]::ReadAllText((Join-Path $acctHome 'config.toml'), [Text.Encoding]::UTF8)
        $null -ne $exception -and $exception.Message -match '^CodexAccountConfigChanged：' -and [string]$exception.Data['errorCode'] -ceq 'CodexAccountConfigChanged' -and $script:TrHookCalls -eq 3 -and
        $text.EndsWith("# external edit 3`n") -and -not $text.Contains('[projects.') -and @(Get-ChildItem -LiteralPath $acctHome -Filter '.account-*.tmp' -Force -ErrorAction SilentlyContinue).Count -eq 0
    }
    Test-Case M03 {
        $root = TrNewDir -Name 'readonly'
        $src = Join-Path $root 'src'
        $null = New-Item -ItemType Directory -Path $src -Force
        $acctHome = TrNewHome -Root $root -Name 'h1' -Config (TrTrustText -Key @())
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @(TrAccount 'a' $acctHome)
        $configPath = Join-Path $acctHome 'config.toml'
        $before = TrBytes $configPath
        Set-ItemProperty -LiteralPath $configPath -Name IsReadOnly -Value $true
        try { $exception = TrCatch { Confirm-CodexAccountProjectTrust -AccountSelection (TrSelection -AccountHome $acctHome) -SourceRoot $src -MachineConfigPath $machine } }
        finally { Set-ItemProperty -LiteralPath $configPath -Name IsReadOnly -Value $false }
        $null -ne $exception -and $exception.Message -match '^CodexAccountConfigWriteFailed：' -and [string]$exception.Data['errorCode'] -ceq 'CodexAccountConfigWriteFailed' -and (TrSameBytes $before (TrBytes $configPath)) -and
        @(Get-ChildItem -LiteralPath $acctHome -Filter '.account-*.tmp' -Force -ErrorAction SilentlyContinue).Count -eq 0
    }

    # ---------- 取鎖逾時 ----------
    Test-Case N01 {
        $root = TrNewDir -Name 'locktimeout'
        $src = Join-Path $root 'src'
        $null = New-Item -ItemType Directory -Path $src -Force
        $acctHome = TrNewHome -Root $root -Name 'h1' -Config (TrTrustText -Key @())
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @(TrAccount 'a' $acctHome)
        $lockPath = Join-Path (Split-Path -Parent $machine) 'codex-account.lock'
        $before = TrBytes (Join-Path $acctHome 'config.toml')
        $held = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { $exception = TrCatch { Confirm-CodexAccountProjectTrust -AccountSelection (TrSelection -AccountHome $acctHome) -SourceRoot $src -MachineConfigPath $machine -LockTimeoutSeconds 1 } }
        finally { $held.Dispose() }
        $afterAcquire = Confirm-CodexAccountProjectTrust -AccountSelection (TrSelection -AccountHome $acctHome) -SourceRoot $src -MachineConfigPath $machine
        $null -ne $exception -and $exception.Message -match '^CodexAccountTrustLockTimeout：' -and $exception.Message.Contains($lockPath) -and [string]$exception.Data['errorCode'] -ceq 'CodexAccountTrustLockTimeout' -and
        (Test-Path -LiteralPath $lockPath) -and $afterAcquire.action -ceq 'added' -and $before.Length -gt 0
    }

    # ---------- 不讀憑證 ----------
    Test-Case O01 {
        $root = TrNewDir -Name 'creds'
        $src = Join-Path $root 'src'
        $null = New-Item -ItemType Directory -Path $src -Force
        $acctHome = TrNewHome -Root $root -Name 'h1' -Config (TrTrustText -Key @())
        $machine = TrWriteMachine -Path (Join-Path $root 'm\machine.json') -Account @(TrAccount 'a' $acctHome)
        $authBefore = TrBytes (Join-Path $acctHome 'auth.json')
        $selection = Resolve-CodexAccountSelection -Profile 'scan' -MachineConfigPath $machine -SourceRoot $src
        $result = Confirm-CodexAccountProjectTrust -AccountSelection $selection -SourceRoot $src -MachineConfigPath $machine
        $serialized = ConvertTo-Json -InputObject @($result, $selection) -Depth 8
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsRoot 'dispatch\dispatch-evidence.ps1'), [ref]$tokens, [ref]$errors)
        $functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Confirm-CodexAccountProjectTrust', 'Resolve-CodexProjectTrustKey', 'Get-CodexTrustSkippedAccount', 'New-CodexProjectTrustRejection') }, $true))
        $gitRootFunction = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-CodexGitTrustRoot' }, $true))
        $forbidden = 'ReadAllText|ReadAllBytes|ReadAllLines|Get-Content|OpenRead|StreamReader|OpenText|auth\.json'
        $libraryText = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'dispatch\codex-account-config.ps1'), [Text.Encoding]::UTF8)
        $result.action -ceq 'added' -and -not $serialized.Contains($sentinel) -and (TrSameBytes $authBefore (TrBytes (Join-Path $acctHome 'auth.json'))) -and
        $functions.Count -eq 4 -and @($functions | Where-Object { $_.Body.Extent.Text -match $forbidden }).Count -eq 0 -and $gitRootFunction.Count -eq 1 -and $gitRootFunction[0].Body.Extent.Text -notmatch 'auth\.json' -and
        $libraryText -notmatch 'auth\.json' -and $libraryText -notmatch 'UserProfile|~\\\.codex|GetFolderPath'
    }

    # ---------- 失敗碼與 Dispatch 失敗結果 ----------
    Test-Case P01 {
        $codes = @('CodexAccountConfigMissing', 'CodexAccountConfigLinked', 'CodexAccountConfigUnsupported', 'CodexAccountConfigChanged', 'CodexAccountConfigWriteFailed', 'CodexAccountTrustLockTimeout', 'CodexProjectPathUnsupported')
        $wrong = @($codes | Where-Object { (Get-DispatchFailureReasonCode -Message ($_ + '：測試訊息') -Phase 'preflight') -cne $_ })
        $recoveryText = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'dispatch\run-recovery.ps1'), [Text.Encoding]::UTF8)
        $functionAst = [Management.Automation.Language.Parser]::ParseInput($recoveryText, [ref]$null, [ref]$null).Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-DispatchFailureReasonCode' }, $true)
        $listed = @($codes | Where-Object { $functionAst.Body.Extent.Text.Contains("'" + $_ + "'") })
        $wrong.Count -eq 0 -and $listed.Count -eq 7 -and -not (Test-DispatchAccountFailoverEligible -EventEvidence ([pscustomobject]@{ rejection_kind = $null; item_event_count = 0 }))
    }
    Test-Case P02 {
        # 端對端：指定 -CodexHome 的登記帳號 config.toml 為連結，Dispatch 於 preflight 階段失敗，project_trust 為 rejected。
        $e2e = TrNewE2E -Name 'e2e-reject'
        $broken = TrNewHome -Root $e2e.homes -Name 'broken' -Config $null
        $null = TrMakeJunctionConfig -AccountHome $broken
        $fine = TrNewHome -Root $e2e.homes -Name 'fine' -Config (TrTrustText -Key @())
        $fineBefore = TrBytes (Join-Path $fine 'config.toml')
        $null = TrWriteMachine -Path $e2e.machine -Account @((TrAccount 'broken' $broken), (TrAccount 'fine' $fine))
        $request = TrNewRequest -Root $e2e.source
        $run = TrRunDispatch -E2E $e2e -Request $request -ExtraArgument @('-CodexHome', $broken)
        $null -ne $run.result -and $run.exit_code -ne 0 -and $run.result.status -ceq 'failed' -and $run.result.failed_stage -ceq 'preflight' -and $run.result.error_code -ceq 'CodexAccountConfigLinked' -and
        $run.result.project_trust.action -ceq 'rejected' -and $run.result.project_trust.reason_code -ceq 'CodexAccountConfigLinked' -and $run.result.project_trust.account_name -ceq 'broken' -and $run.result.error.Contains('LinkType=Junction') -and
        (TrSameBytes $fineBefore (TrBytes (Join-Path $fine 'config.toml'))) -and (Get-Item -LiteralPath (Join-Path $broken 'config.toml') -Force).LinkType -ceq 'Junction'
    }
    Test-Case P03 {
        # 端對端：指定 -CodexHome 時只補該帳號，其他登記帳號不被改寫；同專案再派一次為 already-trusted。
        $e2e = TrNewE2E -Name 'e2e-explicit'
        $target = TrNewHome -Root $e2e.homes -Name 'target' -Config (TrTrustText -Key @())
        $other = TrNewHome -Root $e2e.homes -Name 'other' -Config (TrTrustText -Key @())
        $otherBefore = TrBytes (Join-Path $other 'config.toml')
        $null = TrWriteMachine -Path $e2e.machine -Account @((TrAccount 'target' $target), (TrAccount 'other' $other))
        $request = TrNewRequest -Root $e2e.source
        $firstRun = TrRunDispatch -E2E $e2e -Request $request -ExtraArgument @('-CodexHome', $target)
        $afterFirst = TrBytes (Join-Path $target 'config.toml')
        $secondRequest = TrNewRequest -Root $e2e.source -Slug 'tr-job-2'
        $secondRun = TrRunDispatch -E2E $e2e -Request $secondRequest -ExtraArgument @('-CodexHome', $target)
        $null -ne $firstRun.result -and $firstRun.result.project_trust.action -ceq 'added' -and $firstRun.result.project_trust.account_name -ceq 'target' -and $null -ne $secondRun.result -and $secondRun.result.project_trust.action -ceq 'already-trusted' -and
        (TrSameBytes $afterFirst (TrBytes (Join-Path $target 'config.toml'))) -and (TrSameBytes $otherBefore (TrBytes (Join-Path $other 'config.toml')))
    }

    Test-Case P04 {
        # 端對端：SourceRoot 含單引號時（全域性問題，不逐帳號略過），單次派遣於 preflight 階段以 CodexProjectPathUnsupported 失敗。
        $e2e = TrNewE2E -Name 'e2e-path'
        $acct = TrNewHome -Root $e2e.homes -Name 'acct' -Config (TrTrustText -Key @())
        $acctBefore = TrBytes (Join-Path $acct 'config.toml')
        $null = TrWriteMachine -Path $e2e.machine -Account @((TrAccount 'acct' $acct))
        $quotedSource = Join-Path $e2e.root "src'quoted"
        $null = New-Item -ItemType Directory -Path $quotedSource -Force
        $request = TrNewRequest -Root $quotedSource
        $run = TrRunDispatch -E2E $e2e -Request $request -ExtraArgument @('-NoAccountFailover')
        $null -ne $run.result -and $run.result.status -ceq 'failed' -and $run.result.failed_stage -ceq 'preflight' -and $run.result.error_code -ceq 'CodexProjectPathUnsupported' -and $run.result.project_trust.action -ceq 'rejected' -and
        $run.result.project_trust.reason_code -ceq 'CodexProjectPathUnsupported' -and (TrSameBytes $acctBefore (TrBytes (Join-Path $acct 'config.toml')))
    }

    # ---------- 插入點與結果記錄（原始碼） ----------
    Test-Case R01 {
        $lifecycle = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'dispatch\dispatch-lifecycle.ps1'), [Text.Encoding]::UTF8)
        $resolveIndex = $lifecycle.IndexOf('Resolve-CodexAccountSelection -CodexHomePath', [StringComparison]::Ordinal)
        $confirmIndex = $lifecycle.IndexOf('Confirm-CodexAccountProjectTrust', [StringComparison]::Ordinal)
        $preflightIndex = $lifecycle.IndexOf('$preflightResult = Invoke-Preflight', [StringComparison]::Ordinal)
        $receiptIndex = $lifecycle.IndexOf('$failureReceiptPathValue = Resolve-DispatchOutputPath', [StringComparison]::Ordinal)
        $resolveIndex -ge 0 -and $resolveIndex -lt $receiptIndex -and $receiptIndex -lt $confirmIndex -and $confirmIndex -lt $preflightIndex -and
        ([regex]::Matches($lifecycle, 'project_trust')).Count -ge 3 -and ([regex]::Matches($lifecycle, 'New-CodexProjectTrustRejection')).Count -ge 2 -and $lifecycle.Contains('$result.project_trust = $projectTrust') -and $lifecycle.Contains('$failureResult.project_trust = $projectTrust') -and $lifecycle.Contains('project_trust = $attemptProjectTrust') -and
        $lifecycle -match 'Resolve-CodexAccountSelection -CodexHomePath \$CodexHome -Profile \$Profile -SourceRoot' -and $lifecycle -match 'Get-CodexDispatchAccountCandidates -Profile \$profileValue -MachineConfigPath \$MachineConfigPath -SourceRoot' -and
        $lifecycle.Contains('ai-sessions.dispatch-account-failover.v1')
    }
    Test-Case R02 {
        $recovery = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'dispatch\run-recovery.ps1'), [Text.Encoding]::UTF8)
        $account = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'New-CodexDispatchAccount.ps1'), [Text.Encoding]::UTF8)
        $evidence = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'dispatch\dispatch-evidence.ps1'), [Text.Encoding]::UTF8)
        $library = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'dispatch\codex-account-config.ps1'), [Text.Encoding]::UTF8)
        $entry = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'Invoke-CodexDispatch.ps1'), [Text.Encoding]::UTF8)
        $libraryFunctions = @('Get-AccountConfigPlan', 'Read-AccountTomlValue', 'Test-AccountTomlAssignment', 'Set-AccountAtomicFile', 'Open-CodexAccountLock', 'Get-AccountItemDescription', 'Test-AccountTrustReadiness')
        $definedInLibrary = @($libraryFunctions | Where-Object { $library -match ('(?m)^function ' + [regex]::Escape($_) + ' ') })
        $definedInAccount = @($libraryFunctions | Where-Object { $account -match ('(?m)^function ' + [regex]::Escape($_) + ' ') })
        $definedInLibrary.Count -eq 7 -and $definedInAccount.Count -eq 0 -and $evidence.Contains('TrustConfigMissing') -and $evidence.Contains('TrustConfigLinked') -and $evidence.Contains('TrustConfigUnsupported') -and $library.Contains('TrustConfigMissing') -and
        $account.Contains('dispatch\codex-account-config.ps1') -and -not $entry.Contains('codex-account-config') -and $account -notmatch ('派工前請' + '指定專案') -and $account.Contains('派工時自動補上') -and
        -not $account.Contains('throw "連結類型或目標衝突' + '：$Path"') -and -not $account.Contains('throw "config 類型錯誤' + '：$Path"') -and -not $library.Contains('throw "config 類型錯誤' + '：$Path"')
    }
    Test-Case R03 {
        $text = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'dispatch\dispatch-modules.md'), [Text.Encoding]::UTF8)
        $tableRows = @($text -split "`r?`n" | Where-Object { $_ -match '^\| \d+ \|' })
        $tableRows.Count -eq 16 -and $text.Contains('codex-account-config.ps1') -and $text.Contains('Confirm-CodexAccountProjectTrust') -and @($tableRows | Where-Object { $_ -match 'codex-account-config' }).Count -eq 0
    }

    # ---------- 檔案編碼 ----------
    Test-Case X01 {
        $files = @('scripts\dispatch\codex-account-config.ps1', 'scripts\dispatch\dispatch-evidence.ps1', 'scripts\dispatch\dispatch-lifecycle.ps1', 'scripts\dispatch\run-recovery.ps1', 'scripts\New-CodexDispatchAccount.ps1',
            'scripts\tests\Test-CodexAccountTrust.ps1', 'scripts\tests\Test-NewCodexDispatchAccount.ps1', 'scripts\tests\Test-DispatchAccountFailover.ps1', 'scripts\tests\Test-DispatchRecoveryBinding.ps1')
        $repoRoot = Split-Path -Parent $scriptsRoot
        foreach ($relative in $files) {
            $path = Join-Path $repoRoot $relative
            $bytes = [IO.File]::ReadAllBytes($path)
            if (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) { throw ($relative + ' 不是 UTF-8 with BOM。') }
            if ([IO.File]::ReadAllText($path) -match '(?<!\r)\n|\r(?!\n)') { throw ($relative + ' 存在非 CRLF 行尾。') }
            $tokens = $null; $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            if ($errors.Count -gt 0) { throw ($relative + ' 無法解析：' + $errors[0].Message) }
        }
        $true
    }
}
finally {
    foreach ($leftover in @(Get-ChildItem -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $_.PSIsContainer })) {
        try { $leftover.Delete() } catch { }
    }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output "PASSED: $($script:passed)"
Write-Output "FAILED: $($script:failed)"
Write-Output "SKIPPED: $($script:skipped)"
if ($script:failed -gt 0) { exit 1 }
exit 0
