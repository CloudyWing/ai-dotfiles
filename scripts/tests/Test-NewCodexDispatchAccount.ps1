#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $scriptsRoot 'New-CodexDispatchAccount.ps1')

$script:failed = 0
$script:passed = 0
$script:skipped = 0
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nc-account-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$null = New-Item -ItemType Directory -Path $tempRoot -Force

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

function NcNewDir {
    param([string]$Name)
    $path = Join-Path $tempRoot ($Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $null = New-Item -ItemType Directory -Path $path -Force
    return $path
}

function NcSha256 {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '') }
    finally { $sha.Dispose() }
}

function NcCanSymlink {
    $dir = NcNewDir -Name 'symlink-probe'
    [IO.File]::WriteAllText((Join-Path $dir 'target.txt'), 'x', $utf8NoBom)
    try { $null = New-Item -ItemType SymbolicLink -Path (Join-Path $dir 'link.txt') -Target (Join-Path $dir 'target.txt') -ErrorAction Stop; return $true }
    catch { return $false }
}

# 建立來源 Codex home（四個檔位設定檔）。
function NcNewEnv {
    param([string]$Name, [bool]$MachineDirectory)
    $root = NcNewDir -Name $Name
    $source = Join-Path $root 'source-codex'
    $null = New-Item -ItemType Directory -Path $source -Force
    foreach ($file in @('review.config.toml', 'scan.config.toml', 'content.config.toml', 'advisor.config.toml')) { [IO.File]::WriteAllText((Join-Path $source $file), 'x', $utf8NoBom) }
    $homeRoot = Join-Path $root 'homes'
    $null = New-Item -ItemType Directory -Path $homeRoot -Force
    $machineDir = Join-Path $root 'machine'
    if ($MachineDirectory) { $null = New-Item -ItemType Directory -Path $machineDir -Force }
    return [pscustomobject]@{ root = $root; source = $source; home_root = $homeRoot; machine_dir = $machineDir; machine_path = (Join-Path $machineDir 'machine.json'); account_home = (Join-Path $homeRoot '.codex-acct') }
}

function NcRun {
    param([object]$Env, [string[]]$ProjectPath = @(), [switch]$WhatIfRun)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $exception = $null
    try {
        if ($WhatIfRun) {
            New-CodexAccount -Name 'acct' -HomeRoot $Env.home_root -SourceCodex $Env.source -MachinePath $Env.machine_path -ProjectPath $ProjectPath -WhatIf 6>&1 | ForEach-Object { $null = $lines.Add([string]$_) }
        }
        else {
            New-CodexAccount -Name 'acct' -HomeRoot $Env.home_root -SourceCodex $Env.source -MachinePath $Env.machine_path -ProjectPath $ProjectPath 6>&1 | ForEach-Object { $null = $lines.Add([string]$_) }
        }
    }
    catch { $exception = $_.Exception }
    return [pscustomobject]@{ lines = @($lines.ToArray()); exception = $exception }
}

function NcListing {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '<absent>' }
    return (@(Get-ChildItem -LiteralPath $Path -Force | ForEach-Object { $_.Name + ':' + $(if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { 'link' } elseif ($_.PSIsContainer) { 'dir' } else { 'file' }) } | Sort-Object) -join '|')
}

$canSymlink = NcCanSymlink

try {
    # ---------- 搬移等價：Get-AccountConfigPlan 與 T149 基準逐例相同 ----------
    $fixtureDirectory = NcNewDir -Name 'plan'
    $planCases = @(
        @{ name = 'empty-file'; bytes = [byte[]]@(); keys = @('c:\x'); changed = $true; missing = 'c:\x'; sha = 'F74ECFE029C4136A41061DAB6413E4DB0E443D4569B190BD5DF86E3508991EF0'; length = 69 },
        @{ name = 'missing-file'; bytes = $null; keys = @('c:\x'); changed = $true; missing = 'c:\x'; sha = 'F74ECFE029C4136A41061DAB6413E4DB0E443D4569B190BD5DF86E3508991EF0'; length = 69 },
        @{ name = 'windows-lf'; text = "[windows]`nsandbox = `"elevated`"`n"; keys = @('c:\x'); changed = $true; missing = 'c:\x'; sha = '97F464F81E58957C73A3A1EACD0DE3803805EC5E4AD3DF18F23CBED5A477521D'; length = 74 },
        @{ name = 'project-trusted'; text = "[windows]`nsandbox = `"elevated`"`n`n[projects.'c:\x']`ntrust_level = `"trusted`"`n"; keys = @('c:\x'); changed = $false; missing = ''; sha = '97F464F81E58957C73A3A1EACD0DE3803805EC5E4AD3DF18F23CBED5A477521D'; length = 74 },
        @{ name = 'project-add-crlf'; text = "model = `"m`"`r`n`r`n[windows]`r`nsandbox = `"elevated`"`r`n`r`n[projects.'c:\x']`r`ntrust_level = `"trusted`"`r`n"; keys = @('c:\x', 'c:\y'); changed = $true; missing = 'c:\y'; sha = '2198CF6FAE0672DE8B69245B0255B705949CBCEC2FDA58ECBAC7203A16C0C7B0'; length = 140 },
        @{ name = 'no-trailing-nl'; text = "model = `"m`"`n[other]`na = 1"; keys = @('c:\x'); changed = $true; missing = 'c:\x'; sha = 'A36734AE7782935F0F793FD2D693F088E6BCE5F6168C025F56C86C548A394DDA'; length = 95 },
        @{ name = 'no-windows-multi'; text = "# comment`nmodel = `"m`"`n"; keys = @('c:\a', 'c:\b'); changed = $true; missing = 'c:\a|c:\b'; sha = 'BDEA723EBFC5FD8121E430CBE8F8E42C764EABEDAC6DC1190EAD5C28D0318A69'; length = 134 },
        @{ name = 'mxc-lf'; text = "[windows]`nsandbox = `"mxc`"`n"; keys = @('c:\x'); changed = $true; missing = 'c:\x'; sha = 'F74ECFE029C4136A41061DAB6413E4DB0E443D4569B190BD5DF86E3508991EF0'; length = 69 },
        @{ name = 'mxc-project-trusted'; text = "[windows]`nsandbox = `"mxc`"`n`n[projects.'c:\x']`ntrust_level = `"trusted`"`n"; keys = @('c:\x'); changed = $false; missing = ''; sha = 'F74ECFE029C4136A41061DAB6413E4DB0E443D4569B190BD5DF86E3508991EF0'; length = 69 },
        @{ name = 'mxc-add-crlf'; text = "model = `"m`"`r`n`r`n[windows]`r`nsandbox = `"mxc`"`r`n"; keys = @('c:\y'); changed = $true; missing = 'c:\y'; sha = '36E2ADEC2CFD95DFA84F279610E48A0AFD72EF36DEBF6F0B617542C481A7BD8C'; length = 89 }
    )
    foreach ($case in $planCases) {
        $caseName = $case.name
        Test-Case ('N01-' + $caseName) {
            $path = Join-Path $fixtureDirectory ($case.name + '.toml')
            if ($case.name -ne 'missing-file') {
                [byte[]]$bytes = @()
                if ($case.ContainsKey('text')) { $bytes = $utf8NoBom.GetBytes($case.text) }
                [IO.File]::WriteAllBytes($path, $bytes)
            }
            $plan = Get-AccountConfigPlan -Path $path -Keys $case.keys
            [bool]$plan.Changed -eq $case.changed -and (@($plan.Missing) -join '|') -ceq $case.missing -and (NcSha256 -Bytes ([byte[]]$plan.Bytes)) -ceq $case.sha -and $plan.Bytes.Length -eq $case.length -and ($null -eq $plan.Original) -eq ($case.name -eq 'missing-file')
        }
    }
    foreach ($throwCase in @(
            @{ name = 'unsupported-multiline'; text = "x = `"`"`"abc`"`"`"`n"; code = 'CodexAccountConfigUnsupported' },
            @{ name = 'untrusted-project'; text = "[windows]`nsandbox = `"elevated`"`n`n[projects.'c:\x']`ntrust_level = `"untrusted`"`n"; code = 'CodexAccountConfigUnsupported' },
            @{ name = 'duplicate-project'; text = "[projects.'c:\x']`ntrust_level = `"trusted`"`n[projects.'c:\x']`ntrust_level = `"trusted`"`n"; code = 'CodexAccountConfigUnsupported' })) {
        $throwName = $throwCase.name
        Test-Case ('N01-' + $throwName) {
            $path = Join-Path $fixtureDirectory ($throwCase.name + '.toml')
            [IO.File]::WriteAllBytes($path, $utf8NoBom.GetBytes($throwCase.text))
            $exception = $null
            try { $null = Get-AccountConfigPlan -Path $path -Keys @('c:\x') } catch { $exception = $_.Exception }
            $null -ne $exception -and [string]$exception.Data['reasonCode'] -ceq $throwCase.code -and $exception.Message -match ('^' + $throwCase.code + '：') -and $exception.Message -match ':\d+'
        }
    }
    Test-Case 'N01-link' {
        $directory = NcNewDir -Name 'plan-link'
        $target = Join-Path $directory 'target'
        $null = New-Item -ItemType Directory -Path $target -Force
        $configPath = Join-Path $directory 'config.toml'
        $null = New-Item -ItemType Junction -Path $configPath -Target $target
        $exception = $null
        try { $null = Get-AccountConfigPlan -Path $configPath -Keys @('c:\x') } catch { $exception = $_.Exception }
        $null -ne $exception -and [string]$exception.Data['reasonCode'] -ceq 'CodexAccountConfigLinked' -and $exception.Message.Contains('LinkType=Junction') -and $exception.Message.Contains('Target=') -and $exception.Message.Contains('預期：一般檔案')
    }
    Test-Case 'N02' {
        # 共用函式只定義在共用程式庫，建立腳本只載入不重複定義。
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsRoot 'New-CodexDispatchAccount.ps1'), [ref]$null, [ref]$null)
        $defined = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { $_.Name })
        $moved = @('Get-AccountPath', 'Get-AccountItem', 'Set-AccountAtomicFile', 'Read-AccountTomlValue', 'Test-AccountTomlAssignment', 'Get-AccountConfigPlan')
        @($moved | Where-Object { $defined -contains $_ }).Count -eq 0 -and $defined -contains 'Test-AccountLinkPlan' -and $defined -contains 'New-CodexAccount'
    }

    # ---------- 預檢無半成品 ----------
    $conflictCases = @(
        @{ id = 'profile-link-type'; setup = { param($e) $other = Join-Path $e.root 'other-profile'; $null = New-Item -ItemType Directory -Path $other -Force; $null = New-Item -ItemType Junction -Path (Join-Path $e.account_home 'scan.config.toml') -Target $other }; expect = @('連結類型或目標衝突', 'scan.config.toml', 'LinkType=Junction', 'Target=', '預期：LinkType=SymbolicLink') },
        @{ id = 'config-link'; setup = { param($e) $other = Join-Path $e.root 'other-config'; $null = New-Item -ItemType Directory -Path $other -Force; $null = New-Item -ItemType Junction -Path (Join-Path $e.account_home 'config.toml') -Target $other }; expect = @('CodexAccountConfigLinked', 'config.toml', 'LinkType=Junction', 'Target=', '預期：一般檔案') },
        @{ id = 'profile-directory'; setup = { param($e) $null = New-Item -ItemType Directory -Path (Join-Path $e.account_home 'scan.config.toml') -Force }; expect = @('profile 類型錯誤', 'scan.config.toml', '一般目錄', '預期：LinkType=SymbolicLink') }
    )
    foreach ($conflict in $conflictCases) {
        $conflictId = $conflict.id
        Test-Case ('P01-' + $conflictId) {
            $results = @()
            foreach ($machineDirectoryExists in @($true, $false)) {
                $environment = NcNewEnv -Name ('pre-' + $conflict.id) -MachineDirectory $machineDirectoryExists
                $null = New-Item -ItemType Directory -Path $environment.account_home -Force
                & $conflict.setup $environment
                $homeBefore = NcListing -Path $environment.account_home
                $machineBefore = NcListing -Path $environment.machine_dir
                $run = NcRun -Env $environment -ProjectPath @()
                $homeAfter = NcListing -Path $environment.account_home
                $message = if ($null -eq $run.exception) { '' } else { [string]$run.exception.Message }
                $expectedAll = $true
                foreach ($fragment in $conflict.expect) { if (-not $message.Contains($fragment)) { $expectedAll = $false } }
                $configPath = Join-Path $environment.account_home 'config.toml'
                $configIsLink = $conflict.id -eq 'config-link'
                $results += [pscustomobject]@{
                    exists = $machineDirectoryExists
                    ok = ($null -ne $run.exception -and $expectedAll -and (@($run.lines | Where-Object { $_.StartsWith('failed: preflight:') }).Count -eq 1) -and ($homeBefore -ceq $homeAfter) -and ($machineBefore -ceq (NcListing -Path $environment.machine_dir)) -and
                        -not (Test-Path -LiteralPath $environment.machine_path) -and ($configIsLink -or -not (Test-Path -LiteralPath $configPath)) -and -not (@($run.lines | Where-Object { $_ -match '\[created\]|\[repaired\]' }).Count -gt 0))
                    message = $message
                }
            }
            $bad = @($results | Where-Object { -not $_.ok })
            if ($bad.Count -gt 0) { throw ('預檢失敗：machine 目錄存在=' + $bad[0].exists + '；訊息=' + $bad[0].message) }
            $true
        }
    }
    Test-Case 'P02' {
        # 具體訊息：含找到的 LinkType 與 Target、預期類型與目標、只刪連結的修法，不含 Remove-Item -Recurse。
        $environment = NcNewEnv -Name 'msg' -MachineDirectory $true
        $null = New-Item -ItemType Directory -Path $environment.account_home -Force
        $other = Join-Path $environment.root 'wrong-target'
        $null = New-Item -ItemType Directory -Path $other -Force
        $null = New-Item -ItemType Junction -Path (Join-Path $environment.account_home 'scan.config.toml') -Target $other
        $run = NcRun -Env $environment
        $message = [string]$run.exception.Message
        $message.Contains('LinkType=Junction') -and $message.Contains('Target=' + $other) -and $message.Contains('預期：LinkType=SymbolicLink，Target=' + (Join-Path $environment.source 'scan.config.toml')) -and $message.Contains("(Get-Item -LiteralPath '" + (Join-Path $environment.account_home 'scan.config.toml') + "' -Force).Delete()") -and
        -not $message.Contains('Remove-Item -Recurse') -and -not $message.Contains('Remove-Item')
    }
    Test-Case 'P03' {
        # Test-AccountLinkPlan 為唯讀：乾淨的 home 回傳空清單，衝突時回傳每一項。
        $environment = NcNewEnv -Name 'plan-link' -MachineDirectory $true
        $clean = @(Test-AccountLinkPlan -AccountHome $environment.account_home -Source $environment.source)
        $null = New-Item -ItemType Directory -Path $environment.account_home -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $environment.account_home 'review.config.toml') -Force
        $other = Join-Path $environment.root 'x'
        $null = New-Item -ItemType Directory -Path $other -Force
        $null = New-Item -ItemType Junction -Path (Join-Path $environment.account_home 'scan.config.toml') -Target $other
        $listing = NcListing -Path $environment.account_home
        $conflicts = @(Test-AccountLinkPlan -AccountHome $environment.account_home -Source $environment.source)
        $clean.Count -eq 0 -and $conflicts.Count -eq 2 -and $listing -ceq (NcListing -Path $environment.account_home)
    }

    # ---------- -ProjectPath ----------
    Test-Case 'T01' {
        $environment = NcNewEnv -Name 'noproject' -MachineDirectory $false
        $run = NcRun -Env $environment -ProjectPath @() -WhatIfRun
        $null -eq $run.exception -and (@($run.lines | Where-Object { $_.StartsWith('trust（未預先信任專案，派工時自動補上）') }).Count -eq 1) -and -not ($run.lines -join "`n").Contains('派工前請' + '指定專案') -and
        -not (Test-Path -LiteralPath $environment.account_home) -and -not (Test-Path -LiteralPath $environment.machine_dir)
    }
    Test-Case 'T02' {
        $environment = NcNewEnv -Name 'withproject' -MachineDirectory $true
        $projectA = Join-Path $environment.root 'Project-A'
        $projectB = Join-Path $environment.root 'Project-B'
        $null = New-Item -ItemType Directory -Path $projectA -Force
        $null = New-Item -ItemType Directory -Path $projectB -Force
        $run = NcRun -Env $environment -ProjectPath @($projectA, $projectB, $projectA) -WhatIfRun
        $trustLines = @($run.lines | Where-Object { $_.StartsWith('trust: ') })
        $null -eq $run.exception -and $trustLines.Count -eq 2 -and $trustLines[0].Contains($projectA.ToLowerInvariant()) -and $trustLines[1].Contains($projectB.ToLowerInvariant()) -and -not ($run.lines -join "`n").Contains('未預先信任專案')
    }
    if ($canSymlink) {
        Test-Case 'T03' {
            $environment = NcNewEnv -Name 'create-empty' -MachineDirectory $true
            $run = NcRun -Env $environment -ProjectPath @()
            $configText = [IO.File]::ReadAllText((Join-Path $environment.account_home 'config.toml'), [Text.Encoding]::UTF8)
            $sandboxNames = @('.sandbox', '.sandbox-bin', '.sandbox-secrets', '.sandbox_migration')
            $sandboxPresent = @($sandboxNames | Where-Object { $null -ne (Get-Item -LiteralPath (Join-Path $environment.account_home $_) -Force -ErrorAction SilentlyContinue) })
            $null -eq $run.exception -and $configText.Contains('[windows]') -and $configText.Contains("sandbox = `"mxc`"") -and -not $configText.Contains('elevated') -and -not $configText.Contains('[projects') -and (@($run.lines | Where-Object { $_.StartsWith('trust（未預先信任專案，派工時自動補上）') }).Count -eq 1) -and (Test-Path -LiteralPath $environment.machine_path) -and
            $sandboxPresent.Count -eq 0 -and (NcListing -Path $environment.account_home) -ceq 'advisor.config.toml:link|config.toml:file|content.config.toml:link|review.config.toml:link|scan.config.toml:link'
        }
        Test-Case 'T05' {
            # 帳號 home 既有的 .sandbox 連結不被檢查、改名或刪除；來源 home 缺 .sandbox* 不影響建立。
            $environment = NcNewEnv -Name 'create-existing-sandbox' -MachineDirectory $true
            $null = New-Item -ItemType Directory -Path $environment.account_home -Force
            $sandboxTarget = Join-Path $environment.root 'legacy-sandbox-target'
            $null = New-Item -ItemType Directory -Path $sandboxTarget -Force
            $sandboxLink = Join-Path $environment.account_home '.sandbox'
            $null = New-Item -ItemType Junction -Path $sandboxLink -Target $sandboxTarget
            $run = NcRun -Env $environment -ProjectPath @()
            $linkItem = Get-Item -LiteralPath $sandboxLink -Force
            $backups = @(Get-ChildItem -LiteralPath $environment.account_home -Force | Where-Object { $_.Name -like '.sandbox*.bak-*' })
            $null -eq $run.exception -and $linkItem.LinkType -ceq 'Junction' -and [string]::Equals((($linkItem.Target | Select-Object -First 1) -replace '^\\\?\?\\', ''), $sandboxTarget, [StringComparison]::OrdinalIgnoreCase) -and $backups.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $sandboxTarget '.')) -and
            (Test-Path -LiteralPath (Join-Path $environment.account_home 'config.toml'))
        }
        Test-Case 'T04' {
            $environment = NcNewEnv -Name 'create-projects' -MachineDirectory $true
            $projectA = Join-Path $environment.root 'Project-A'
            $projectB = Join-Path $environment.root 'Project-B'
            $null = New-Item -ItemType Directory -Path $projectA -Force
            $null = New-Item -ItemType Directory -Path $projectB -Force
            $run = NcRun -Env $environment -ProjectPath @($projectA, $projectB)
            $configText = [IO.File]::ReadAllText((Join-Path $environment.account_home 'config.toml'), [Text.Encoding]::UTF8)
            $null -eq $run.exception -and $configText.Contains("[projects.'" + $projectA.ToLowerInvariant() + "']") -and $configText.Contains("[projects.'" + $projectB.ToLowerInvariant() + "']") -and ([regex]::Matches($configText, '\[projects\.')).Count -eq 2
        }
    }
    else {
        Skip-Case 'T03' '無建立 Symbolic Link 權限，略過需要建立連結的完整建立案例。'
        Skip-Case 'T04' '無建立 Symbolic Link 權限，略過需要建立連結的完整建立案例。'
        Skip-Case 'T05' '無建立 Symbolic Link 權限，略過需要建立連結的完整建立案例。'
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
