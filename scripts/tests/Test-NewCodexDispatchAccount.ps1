#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $scriptsRoot 'New-CodexDispatchAccount.ps1')
. (Join-Path $scriptsRoot 'dispatch/common-runtime.ps1')
. (Join-Path $scriptsRoot 'dispatch/git-baseline.ps1')
. (Join-Path $scriptsRoot 'dispatch/dispatch-evidence.ps1')

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
    foreach ($file in @(Get-AccountProfileFileName)) { [IO.File]::WriteAllText((Join-Path $source $file), 'x', $utf8NoBom) }
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
            New-CodexAccount -Name 'acct' -HomeRoot $Env.home_root -SourceCodex $Env.source -ProfileSourceDirectory $Env.source -MachinePath $Env.machine_path -ProjectPath $ProjectPath -WhatIf 6>&1 | ForEach-Object { $null = $lines.Add([string]$_) }
        }
        else {
            New-CodexAccount -Name 'acct' -HomeRoot $Env.home_root -SourceCodex $Env.source -ProfileSourceDirectory $Env.source -MachinePath $Env.machine_path -ProjectPath $ProjectPath 6>&1 | ForEach-Object { $null = $lines.Add([string]$_) }
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

    # ---------- 共用程式庫其餘仍使用的函式 ----------
    Test-Case 'L01 Get-AccountPath 去除結尾分隔符但不改磁碟機根目錄' {
        $trimmed = Get-AccountPath (Join-Path $tempRoot 'a\b\')
        $root = [IO.Path]::GetPathRoot($tempRoot)
        $trimmed -ceq (Join-Path $tempRoot 'a\b') -and (Get-AccountPath $root) -ceq $root
    }
    Test-Case 'L02 Get-AccountItemDescription 區分不存在、一般檔案與一般目錄' {
        $dir = NcNewDir -Name 'desc'
        $file = Join-Path $dir 'f.txt'
        [IO.File]::WriteAllText($file, 'x', $utf8NoBom)
        $missing = Get-AccountItemDescription -Path (Join-Path $dir 'none')
        $fileDesc = Get-AccountItemDescription -Path $file
        $dirDesc = Get-AccountItemDescription -Path $dir
        $missing.kind -ceq 'Missing' -and -not $missing.exists -and $fileDesc.kind -ceq 'File' -and $fileDesc.text -ceq '一般檔案' -and $dirDesc.kind -ceq 'Directory' -and $dirDesc.text -ceq '一般目錄'
    }
    if ($canSymlink) { Test-Case 'L03 Get-AccountItemDescription 描述連結的類型與目標' {
        $dir = NcNewDir -Name 'desc-link'
        $target = Join-Path $dir 'target.txt'
        [IO.File]::WriteAllText($target, 'x', $utf8NoBom)
        $link = Join-Path $dir 'link.txt'
        $null = New-Item -ItemType SymbolicLink -Path $link -Target $target
        $desc = Get-AccountItemDescription -Path $link
        $desc.kind -ceq 'Link' -and $desc.link_type -ceq 'SymbolicLink' -and $desc.text.Contains('LinkType=SymbolicLink') -and $desc.text.Contains('Target=')
    } }
    Test-Case 'L04 Get-AccountLinkRepairHint 轉義單引號並同時提示連結與一般項目的處理' {
        $hint = Get-AccountLinkRepairHint -Path "C:\x\it's"
        $hint.Contains("it''s") -and $hint.Contains('只刪除連結') -and $hint.Contains('人工移走')
    }
    Test-Case 'L05 Set-AccountAtomicFile 建立新檔、以相符的原始內容取代、-WhatIf 不寫入' {
        $dir = NcNewDir -Name 'atomic'
        $path = Join-Path $dir 'config.toml'
        $first = $utf8NoBom.GetBytes('a = 1')
        $second = $utf8NoBom.GetBytes('a = 2')
        Set-AccountAtomicFile -Path $path -Bytes $first -Original $null
        $created = [IO.File]::ReadAllText($path)
        Set-AccountAtomicFile -Path $path -Bytes $second -Original $first
        $replaced = [IO.File]::ReadAllText($path)
        Set-AccountAtomicFile -Path $path -Bytes $first -Original $second -WhatIf *>$null
        $afterWhatIf = [IO.File]::ReadAllText($path)
        $leftover = @(Get-ChildItem -LiteralPath $dir -Force | Where-Object { $_.Name -ne 'config.toml' }).Count
        $created -ceq 'a = 1' -and $replaced -ceq 'a = 2' -and $afterWhatIf -ceq 'a = 2' -and $leftover -eq 0
    }
    Test-Case 'L06 Set-AccountAtomicFile 原始內容與現況不符時以 CodexAccountConfigChanged 拒絕且不留暫存檔' {
        $dir = NcNewDir -Name 'atomic-changed'
        $path = Join-Path $dir 'config.toml'
        [IO.File]::WriteAllText($path, 'external', $utf8NoBom)
        $exception = $null
        try { Set-AccountAtomicFile -Path $path -Bytes $utf8NoBom.GetBytes('new') -Original $utf8NoBom.GetBytes('old') } catch { $exception = $_.Exception }
        $leftover = @(Get-ChildItem -LiteralPath $dir -Force | Where-Object { $_.Name -ne 'config.toml' }).Count
        $null -ne $exception -and [string]$exception.Data['reasonCode'] -ceq 'CodexAccountConfigChanged' -and [IO.File]::ReadAllText($path) -ceq 'external' -and $leftover -eq 0
    }

    # ---------- Read-CodexAccountConfiguration（Setup 與 setup-check 的帳號登記讀取）----------
    function NcReadAccounts {
        param([string]$MachineJson, [switch]$NoFile)
        $dir = NcNewDir -Name 'machine'
        $path = Join-Path $dir 'machine.json'
        if (-not $NoFile) { [IO.File]::WriteAllText($path, $MachineJson, $utf8NoBom) }
        $result = $null
        $exception = $null
        try { $result = @(Read-CodexAccountConfiguration -MachineConfigPath $path) } catch { $exception = $_.Exception }
        return [pscustomobject]@{ result = $result; exception = $exception; dir = $dir }
    }
    function NcMachineJson {
        param([object[]]$Accounts, [string]$Schema = 'ai-agents.machine.v1')
        return (ConvertTo-Json -InputObject ([ordered]@{ schema = $Schema; codex_accounts = @($Accounts) }) -Depth 5)
    }
    Test-Case 'R01 Read-CodexAccountConfiguration 合法登記回傳名稱與帳號目錄，檔案不存在或沒有 codex_accounts 時回傳空' {
        $home1 = NcNewDir -Name 'acct-a'
        $home2 = NcNewDir -Name 'acct-b'
        $ok = NcReadAccounts -MachineJson (NcMachineJson -Accounts @([ordered]@{ name = 'unreal-wing'; codex_home = $home1 }, [ordered]@{ name = 'cloudy-wing'; codex_home = $home2 }))
        $noFile = NcReadAccounts -NoFile
        $noAccounts = NcReadAccounts -MachineJson '{ "schema": "ai-agents.machine.v1" }'
        $null -eq $ok.exception -and $ok.result.Count -eq 2 -and $ok.result[0].name -ceq 'unreal-wing' -and $ok.result[0].codex_home -ieq $home1 -and $ok.result[1].name -ceq 'cloudy-wing' -and $null -eq $noFile.exception -and $noFile.result.Count -eq 0 -and $null -eq $noAccounts.exception -and $noAccounts.result.Count -eq 0
    }
    $invalidAccountCases = @(
        @{ id = 'duplicate-name'; build = { param($h) NcMachineJson -Accounts @([ordered]@{ name = 'dup'; codex_home = $h[0] }, [ordered]@{ name = 'dup'; codex_home = $h[1] }) } },
        @{ id = 'duplicate-home'; build = { param($h) NcMachineJson -Accounts @([ordered]@{ name = 'one'; codex_home = $h[0] }, [ordered]@{ name = 'two'; codex_home = $h[0] }) } },
        @{ id = 'invalid-name'; build = { param($h) NcMachineJson -Accounts @([ordered]@{ name = 'Bad_Name'; codex_home = $h[0] }) } },
        @{ id = 'relative-home'; build = { param($h) NcMachineJson -Accounts @([ordered]@{ name = 'rel'; codex_home = 'relative\home' }) } },
        @{ id = 'missing-home'; build = { param($h) NcMachineJson -Accounts @([ordered]@{ name = 'gone'; codex_home = (Join-Path $h[0] 'not-created') }) } },
        @{ id = 'extra-property'; build = { param($h) NcMachineJson -Accounts @([ordered]@{ name = 'extra'; codex_home = $h[0]; note = 'x' }) } },
        @{ id = 'not-array'; build = { param($h) ('{ "schema": "ai-agents.machine.v1", "codex_accounts": { "name": "a" } }') } },
        @{ id = 'wrong-schema'; build = { param($h) NcMachineJson -Accounts @([ordered]@{ name = 'one'; codex_home = $h[0] }) -Schema 'other.v1' } }
    )
    foreach ($invalidCase in $invalidAccountCases) {
        $invalidId = $invalidCase.id
        $invalidBuild = $invalidCase.build
        Test-Case ('R02-' + $invalidId + ' Read-CodexAccountConfiguration 以 CodexAccountConfigurationInvalid 拒絕') {
            $homes = @((NcNewDir -Name 'acct-x'), (NcNewDir -Name 'acct-y'))
            $read = NcReadAccounts -MachineJson (& $invalidBuild $homes)
            $null -ne $read.exception -and $read.exception.Message.StartsWith('CodexAccountConfigurationInvalid：')
        }
    }
    if ($canSymlink) {
        Test-Case 'R03 Read-CodexAccountConfiguration 帳號目錄含連結時以 CodexAccountConfigurationInvalid 拒絕' {
            $realHome = NcNewDir -Name 'acct-real'
            $linkHome = Join-Path (NcNewDir -Name 'acct-link-parent') 'home'
            $null = New-Item -ItemType SymbolicLink -Path $linkHome -Target $realHome
            $read = NcReadAccounts -MachineJson (NcMachineJson -Accounts @([ordered]@{ name = 'linked'; codex_home = $linkHome }))
            $null -ne $read.exception -and $read.exception.Message.StartsWith('CodexAccountConfigurationInvalid：')
        }
    }
    else { Skip-Case 'R03' '沒有建立 Symbolic Link 的權限，無法建立含連結的帳號目錄。' }

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

    # ---------- 中途失敗：只回復本次建立的項目 ----------
    function Invoke-FailingCreate {
        param([object]$Env, [int]$FailOnLink = 2)
        # 以替身 New-Item 讓第 $FailOnLink 個 Symbolic Link 建立失敗；其餘連結以一般檔案占位，使流程可走到失敗點。
        $script:linkCounter = 0
        function New-Item {
            [CmdletBinding()]
            param([string]$ItemType, [string]$Path, [string]$Target, [switch]$Force, [string]$Name, $Value)
            if ($ItemType -ceq 'SymbolicLink') {
                $script:linkCounter++
                if ($script:linkCounter -ge $FailOnLink) { throw '用戶端沒有所需的權限。' }
                [IO.File]::WriteAllText($Path, 'link-placeholder')
                return
            }
            Microsoft.PowerShell.Management\New-Item @PSBoundParameters
        }
        return (NcRun -Env $Env)
    }
    Test-Case 'RB01 連結建立到一半失敗：本次建立的連結、config.toml 與帳號目錄都回復，既有的 machine 目錄不動，machine.json 沒有寫入' {
        $environment = NcNewEnv -Name 'rollback-fresh' -MachineDirectory $true
        $machineBefore = NcListing -Path $environment.machine_dir
        $run = Invoke-FailingCreate -Env $environment
        $text = $run.lines -join "`n"
        $null -ne $run.exception -and -not (Test-Path -LiteralPath $environment.account_home) -and ($machineBefore -ceq (NcListing -Path $environment.machine_dir)) -and -not (Test-Path -LiteralPath $environment.machine_path) -and
        $text.Contains('rolled-back') -and $text.Contains('已回復本次建立的項目') -and $text.Contains('failed: profiles')
    }
    Test-Case 'RB02 machine 目錄也是本次建立：失敗後一併移除（空目錄）' {
        $environment = NcNewEnv -Name 'rollback-nomachine' -MachineDirectory $false
        $run = Invoke-FailingCreate -Env $environment
        $null -ne $run.exception -and -not (Test-Path -LiteralPath $environment.account_home) -and -not (Test-Path -LiteralPath $environment.machine_dir)
    }
    Test-Case 'RB03 帳號目錄與 config.toml 原本就存在：只移除本次建立的連結，既有的目錄、config.toml 與其他檔案不動' {
        $environment = NcNewEnv -Name 'rollback-existing' -MachineDirectory $true
        $null = New-Item -ItemType Directory -Path $environment.account_home -Force
        $configPath = Join-Path $environment.account_home 'config.toml'
        [IO.File]::WriteAllText($configPath, "[windows]`nsandbox = `"mxc`"`n", $utf8NoBom)
        $keepPath = Join-Path $environment.account_home 'keep.txt'
        [IO.File]::WriteAllText($keepPath, 'keep', $utf8NoBom)
        $configSha = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
        $run = Invoke-FailingCreate -Env $environment
        $left = @(Get-ChildItem -LiteralPath $environment.account_home -Force | ForEach-Object { $_.Name } | Sort-Object)
        $null -ne $run.exception -and ($left -join '|') -ceq 'config.toml|keep.txt' -and (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ceq $configSha -and -not (Test-Path -LiteralPath $environment.machine_path)
    }
    if ($canSymlink) { Test-Case 'RB04 回復只動本次建立的連結：帳號目錄內本次之前就存在的連結不被移除' {
        $environment = NcNewEnv -Name 'rollback-prelink' -MachineDirectory $true
        $null = New-Item -ItemType Directory -Path $environment.account_home -Force
        $firstName = @(Get-AccountProfileFileName)[0]
        $preLinkTarget = Join-Path $environment.source $firstName
        $preLinkPath = Join-Path $environment.account_home $firstName
        $null = New-Item -ItemType SymbolicLink -Path $preLinkPath -Target $preLinkTarget
        $run = Invoke-FailingCreate -Env $environment
        $null -ne $run.exception -and $null -ne (Get-Item -LiteralPath $preLinkPath -Force -ErrorAction SilentlyContinue)
    } } else { Skip-Case 'RB04' '沒有建立 Symbolic Link 的權限，無法預先放置既有連結。' }

    # ---------- -ProjectPath ----------
    Test-Case 'T01' {
        $environment = NcNewEnv -Name 'noproject' -MachineDirectory $false
        $run = NcRun -Env $environment -ProjectPath @() -WhatIfRun
        $null -eq $run.exception -and (@($run.lines | Where-Object { $_.StartsWith('trust（未預先信任專案，須要時以 -ProjectPath 預先加入）') }).Count -eq 1) -and -not ($run.lines -join "`n").Contains('派工前請' + '指定專案') -and
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
            $null -eq $run.exception -and $configText.Contains('[windows]') -and $configText.Contains("sandbox = `"mxc`"") -and -not $configText.Contains('elevated') -and -not $configText.Contains('[projects') -and (@($run.lines | Where-Object { $_.StartsWith('trust（未預先信任專案，須要時以 -ProjectPath 預先加入）') }).Count -eq 1) -and (Test-Path -LiteralPath $environment.machine_path) -and
            $sandboxPresent.Count -eq 0 -and (NcListing -Path $environment.account_home) -ceq ((@(@(Get-AccountProfileFileName) | ForEach-Object { $_ + ':link' }) + @('config.toml:file') | Sort-Object) -join '|')
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
