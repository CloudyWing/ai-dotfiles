#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$script:DispatchEntryScriptRoot = $scriptsRoot
foreach ($module in @('common-runtime', 'git-baseline', 'dispatch-scope', 'dispatch-evidence', 'quota-observation', 'advisor-evidence', 'process-identity', 'reviewer-contract', 'run-recovery', 'prepare-stage', 'dispatch-lifecycle', 'start-lifecycle', 'inspect-lifecycle', 'collect-contract', 'cleanup', 'Invoke-DispatchConcurrency')) {
    . (Join-Path $scriptsRoot ('dispatch\' + $module + '.ps1'))
}

$script:failed = 0
$script:passed = 0
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('fx-failover-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$null = New-Item -ItemType Directory -Path $tempRoot -Force
$originalCodexHomeEnv = $env:CODEX_HOME
$sentinel = 'SENTINEL-' + [guid]::NewGuid().ToString('N')

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

function FxThrows {
    param([scriptblock]$Action)
    try { $null = & $Action } catch { return [string]$_.Exception.Message }
    return $null
}

function FxNewDir {
    param([string]$Name)
    $path = Join-Path $tempRoot ($Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $null = New-Item -ItemType Directory -Path $path -Force
    return $path
}

function FxNewAccountHome {
    param([string]$Root, [string]$Name, [ValidateSet('login', 'none', 'empty')][string]$Login = 'login', [string[]]$ProfileConfig = @('scan'))
    $path = Join-Path $Root $Name
    $null = New-Item -ItemType Directory -Path $path -Force
    if ($Login -eq 'login') { [IO.File]::WriteAllBytes((Join-Path $path 'auth.json'), $utf8NoBom.GetBytes('{ not json ' + $sentinel + [char]0 + ' }')) }
    elseif ($Login -eq 'empty') { [IO.File]::WriteAllBytes((Join-Path $path 'auth.json'), [byte[]]@()) }
    foreach ($profileName in $ProfileConfig) { [IO.File]::WriteAllText((Join-Path $path ($profileName + '.config.toml')), 'model = "fixture-model"', $utf8NoBom) }
    return $path
}

function FxWriteMachine {
    param([string]$Root, [object[]]$Account)
    $path = Join-Path $Root 'machine.json'
    $machine = [ordered]@{ schema = 'ai-agents.machine.v1'; codex_accounts = @($Account | ForEach-Object { [ordered]@{ name = $_.name; codex_home = $_.codex_home } }) }
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $machine -Depth 10), $utf8NoBom)
    return $path
}

function FxNewRequestFixture {
    param([string]$Slug = 'fx-job', [bool]$SlugInDispatchRoot = $true)
    $root = FxNewDir -Name 'src'
    $lineSlug = 'fx-line'
    $history = Join-Path $root ('.local\ai-sessions\history\' + $lineSlug)
    $null = New-Item -ItemType Directory -Path $history -Force
    $promptPath = Join-Path $root 'prompt.md'
    $targetPath = Join-Path $root 'target.txt'
    [IO.File]::WriteAllText($promptPath, 'fixture prompt', $utf8NoBom)
    [IO.File]::WriteAllText($targetPath, 'fixture target', $utf8NoBom)
    $dispatchRoot = if ($SlugInDispatchRoot) { Join-Path $root ('.local\ai-sessions\worktrees\' + $Slug) } else { Join-Path $root '.local\ai-sessions\worktrees\fixed-root' }
    $document = [ordered]@{
        schema = 'ai-sessions.dispatch-request.v1'
        operation = 'Dispatch'
        line_slug = $lineSlug
        dispatch_slug = $Slug
        source_root = $root
        dispatch_root = $dispatchRoot
        profile = 'scan'
        write_mode = 'readonly'
        dispatch_kind = 'resource'
        prompt_path = $promptPath
        target_path = @($targetPath)
        task_type = 'script-change'
        unit_kind = 'resource-target'
        requested_unit = @($targetPath)
        failure_receipt_path = (Join-Path $history ('failure-receipt-' + $Slug + '.json'))
        result_path = (Join-Path $history ('dispatch-result-' + $Slug + '.json'))
        prepare_artifacts = @([ordered]@{ source = $promptPath; destination = (Join-Path $dispatchRoot 'prompt-copy.md'); sha256 = ('0' * 64); purpose = 'fixture' })
    }
    $requestPath = Join-Path $history ('dispatch-request-' + $Slug + '.json')
    [IO.File]::WriteAllText($requestPath, ((ConvertTo-Json -InputObject $document -Depth 20) + "`n"), $utf8NoBom)
    return [pscustomobject]@{ root = $root; line = $lineSlug; slug = $Slug; history = $history; request_path = $requestPath; document = $document; prompt_path = $promptPath; target_path = $targetPath }
}

function FxEvents {
    param([string]$Directory, [string]$Name, [object[]]$Event, [string]$Stderr = '')
    $eventPath = Join-Path $Directory ($Name + '.jsonl')
    $errorPath = Join-Path $Directory ($Name + '.stderr.txt')
    [IO.File]::WriteAllText($eventPath, ((@($Event | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 10 -Compress })) -join "`n"), $utf8NoBom)
    [IO.File]::WriteAllText($errorPath, $Stderr, $utf8NoBom)
    return [pscustomobject]@{ event = $eventPath; error = $errorPath }
}

# 以替換縫模擬子程序。每個嘗試依帳號名稱查 $script:FxBehavior 的腳本表。
$script:FxAttemptLog = New-Object 'System.Collections.Generic.List[object]'
$script:FxBehavior = @{}
$script:FxEventFixture = @{}
$realAttemptProcess = ${function:Invoke-DispatchAttemptProcess}
function Invoke-DispatchAttemptProcess {
    [CmdletBinding()]
    param([string]$RequestPath, [string]$CodexHome, [string[]]$ForwardArgument = @(), [string]$ResultPathHint)
    $requestDocument = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($RequestPath, [Text.Encoding]::UTF8))
    $accountName = Split-Path -Leaf $CodexHome
    $null = $script:FxAttemptLog.Add([pscustomobject]@{ request_path = $RequestPath; codex_home = $CodexHome; account = $accountName; slug = [string]$requestDocument.dispatch_slug; document = $requestDocument; forward = @($ForwardArgument) })
    $behavior = $script:FxBehavior[$accountName]
    if ($null -eq $behavior) { $behavior = 'completed' }
    $result = FxMakeResult -Behavior $behavior -Slug ([string]$requestDocument.dispatch_slug)
    return [pscustomobject]@{ exit_code = $(if ($null -ne $result -and [string]$result.status -eq 'completed') { 0 } else { 1 }); stdout = ''; stderr = ''; result = $result; result_path = $null }
}

function FxMakeResult {
    param([string]$Behavior, [string]$Slug)
    $base = [ordered]@{ schema = 'ai-sessions.dispatch-result.v1'; operation = 'Dispatch'; dispatch_slug = $Slug; result_path = ('C:\fx\result-' + $Slug + '.json') }
    switch -Regex ($Behavior) {
        '^completed$' { $base.status = 'completed'; return [pscustomobject]$base }
        '^reject:(?<kind>[a-z-]+)$' {
            $base.status = 'failed'; $base.error_code = 'CodexTurnFailed'
            $base.account_failover = [ordered]@{ eligible = $true; rejection_kind = $Matches['kind']; item_event_count = 0 }
            return [pscustomobject]$base
        }
        '^reject-progress$' {
            $base.status = 'failed'; $base.error_code = 'CodexTurnFailed'
            $base.account_failover = [ordered]@{ eligible = $false; rejection_kind = 'model-not-supported'; item_event_count = 3 }
            return [pscustomobject]$base
        }
        '^plain-fail$' {
            $base.status = 'failed'; $base.error_code = 'CodexTurnFailed'
            $base.account_failover = [ordered]@{ eligible = $false; rejection_kind = $null; item_event_count = 0 }
            return [pscustomobject]$base
        }
        '^events:(?<name>[a-z0-9-]+)$' {
            # 以登錄的事件流經實際分類函式產生 account_failover，涵蓋「事件流到外層」的完整路徑。
            $eventFixtureName = $Matches['name']
            $evidence = Get-DispatchEventEvidence -EventPath $script:FxEventFixture[$eventFixtureName] -ProcessExitCode 1
            $base.account_failover = New-DispatchAccountFailoverEvidence -EventEvidence $evidence
            if ([string]$evidence.last_event_type -ceq 'turn.completed') { $base.status = 'completed'; return [pscustomobject]$base }
            $base.status = 'failed'; $base.error_code = 'CodexTurnFailed'
            return [pscustomobject]$base
        }
        '^started$' { $base.status = 'started'; return [pscustomobject]$base }
        '^launch-fail$' { $base.status = 'failed'; $base.error_code = 'DispatchStartFailed'; $base.error = 'fixture launch failure'; return [pscustomobject]$base }
        '^no-inspect$' { $base.status = 'failed'; $base.error_code = 'DispatchInspectFailed'; return [pscustomobject]$base }
        '^unparsable$' { return $null }
        '^admission$' { $base.status = 'failed'; $base.error_code = 'DispatchAdmissionWriteLimit'; return [pscustomobject]$base }
    }
    throw ('未知的替換縫行為：' + $Behavior)
}

function FxReset {
    $script:FxAttemptLog.Clear()
    $script:FxBehavior = @{}
}

# 換帳號外層會以來源專案根目錄做信任唯讀預檢，fixture 帳號需帶含該專案小寫路徑的信任段。
function FxEnsureTrust {
    param([string]$MachinePath, [string]$Root)
    $machine = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($MachinePath, [Text.Encoding]::UTF8))
    foreach ($account in @($machine.codex_accounts)) {
        $configPath = Join-Path $account.codex_home 'config.toml'
        if (-not (Test-Path -LiteralPath $configPath)) {
            [IO.File]::WriteAllText($configPath, ("[windows]`nsandbox = `"mxc`"`n`n[projects.'" + $Root.ToLowerInvariant() + "']`ntrust_level = `"trusted`"`n"), $utf8NoBom)
        }
    }
}

function FxRunFailover {
    param([object]$Fixture, [string]$MachinePath, [hashtable]$Behavior, [System.Collections.IDictionary]$Bound = $null)
    FxReset
    FxEnsureTrust -MachinePath $MachinePath -Root $Fixture.root
    foreach ($key in $Behavior.Keys) { $script:FxBehavior[$key] = $Behavior[$key] }
    $outcome = [ordered]@{ result = $null; error = $null; summary = $null; summary_path = $null }
    try { $outcome.result = Invoke-DispatchAccountFailover -RequestPath $Fixture.request_path -Profile 'scan' -MachineConfigPath $MachinePath -BoundParameter $Bound }
    catch { $outcome.error = [string]$_.Exception.Message }
    $summaryPath = Join-Path $Fixture.history ('dispatch-account-failover-' + $Fixture.slug + '.json')
    $outcome.summary_path = $summaryPath
    if (Test-Path -LiteralPath $summaryPath -PathType Leaf) { $outcome.summary = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($summaryPath, [Text.Encoding]::UTF8)) }
    return [pscustomobject]$outcome
}

function FxAccounts {
    param([string]$Root, [string[]]$Name, [string]$Login = 'login')
    $accounts = @(foreach ($accountName in $Name) { [pscustomobject]@{ name = $accountName; codex_home = (FxNewAccountHome -Root $Root -Name $accountName -Login $Login) } })
    return ,$accounts
}

try {
    # ---------- 登入判定與候選清單 ----------
    $rootA = FxNewDir -Name 'cand'
    $acctMissing = FxNewAccountHome -Root $rootA -Name 'acct-a' -Login none
    $acctOk = FxNewAccountHome -Root $rootA -Name 'acct-b' -Login login
    $acctEmpty = FxNewAccountHome -Root $rootA -Name 'acct-c' -Login empty
    $acctNoProfile = FxNewAccountHome -Root $rootA -Name 'acct-d' -Login login -ProfileConfig @()
    $acctLast = FxNewAccountHome -Root $rootA -Name 'acct-e' -Login login
    $machineA = FxWriteMachine -Root $rootA -Account @(
        [pscustomobject]@{ name = 'a'; codex_home = $acctMissing }, [pscustomobject]@{ name = 'b'; codex_home = $acctOk },
        [pscustomobject]@{ name = 'c'; codex_home = $acctEmpty }, [pscustomobject]@{ name = 'd'; codex_home = $acctNoProfile },
        [pscustomobject]@{ name = 'e'; codex_home = $acctLast })
    Test-Case L01 {
        $set = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $machineA
        (@($set.candidates | ForEach-Object { $_.name }) -join ',') -ceq 'b,e' -and
        (@($set.skipped | ForEach-Object { $_.name + ':' + $_.reason_code }) -join ',') -ceq 'a:LoginFileMissing,c:LoginFileEmpty,d:ProfileConfigMissing'
    }
    Test-Case L02 {
        $set = Get-CodexDispatchAccountCandidates -Profile '' -MachineConfigPath $machineA
        (@($set.candidates | ForEach-Object { $_.name }) -join ',') -ceq 'b,d,e'
    }
    Test-Case L03 {
        $set = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $machineA
        $skipA = @($set.skipped)[0]
        $skipA.login_file_path -ieq (Join-Path $acctMissing 'auth.json') -and $null -eq $skipA.login_file_length -and $null -eq $skipA.login_file_last_write_utc -and
        @($set.skipped)[1].login_file_length -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]@($set.skipped)[1].login_file_last_write_utc)
    }
    Test-Case L04 {
        $order = @('z-last', 'm-mid', 'a-first')
        $root = FxNewDir -Name 'order'
        $accounts = FxAccounts -Root $root -Name $order
        $machine = FxWriteMachine -Root $root -Account $accounts
        $set = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $machine
        (@($set.candidates | ForEach-Object { $_.name }) -join ',') -ceq ($order -join ',')
    }
    Test-Case L05 {
        $directoryAsLogin = FxNewAccountHome -Root $rootA -Name 'acct-dir' -Login none
        $null = New-Item -ItemType Directory -Path (Join-Path $directoryAsLogin 'auth.json') -Force
        $login = Test-CodexAccountLoggedIn -AccountHome $directoryAsLogin
        -not $login.logged_in -and $login.reason_code -ceq 'LoginFileMissing'
    }

    # ---------- 不讀憑證與不讀 models_cache ----------
    Test-Case N01 {
        $login = Test-CodexAccountLoggedIn -AccountHome $acctOk
        $serialized = ConvertTo-Json -InputObject $login -Depth 5
        $login.logged_in -and $null -eq $login.reason_code -and $login.login_file_length -gt 0 -and -not $serialized.Contains($sentinel) -and
        -not (ConvertTo-Json -InputObject (Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $machineA) -Depth 6).Contains($sentinel)
    }
    Test-Case N02 {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsRoot 'dispatch\dispatch-evidence.ps1'), [ref]$tokens, [ref]$errors)
        $functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Test-CodexAccountLoggedIn', 'Get-CodexDispatchAccountCandidates') }, $true))
        $forbidden = 'ReadAllText|ReadAllBytes|ReadAllLines|Get-Content|OpenRead|StreamReader|OpenText|FileStream|models_cache'
        $functions.Count -eq 2 -and @($functions | Where-Object { $_.Body.Extent.Text -match $forbidden }).Count -eq 0
    }
    Test-Case N03 {
        $root = FxNewDir -Name 'cache'
        $accounts = FxAccounts -Root $root -Name @('c-one', 'c-two')
        foreach ($account in $accounts) { [IO.File]::WriteAllText((Join-Path $account.codex_home 'models_cache.json'), '{"models":[{"slug":"other-model"}]}', $utf8NoBom) }
        $machine = FxWriteMachine -Root $root -Account $accounts
        $set = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $machine
        @($set.candidates).Count -eq 2 -and @($set.skipped).Count -eq 0
    }

    # ---------- 帳號選擇 ----------
    Test-Case S01 {
        $shapes = @()
        foreach ($count in 1, 2, 3) {
            $root = FxNewDir -Name ('count' + $count)
            $accounts = FxAccounts -Root $root -Name @(1..$count | ForEach-Object { 'n' + $_ })
            $machine = FxWriteMachine -Root $root -Account $accounts
            $selection = Resolve-CodexAccountSelection -Profile 'scan' -MachineConfigPath $machine
            $shapes += , @(@($selection.PSObject.Properties.Name | Sort-Object) -join '|')
            if ($selection.Mode -cne 'auto' -or $selection.AccountName -cne 'n1' -or $selection.CodexHome -ine $accounts[0].codex_home -or @($selection.Candidates).Count -ne $count -or @($selection.Skipped).Count -ne 0) { throw ('帳號數 ' + $count + ' 的選擇結果不符。') }
        }
        @($shapes | Select-Object -Unique).Count -eq 1
    }
    Test-Case S02 {
        $root = FxNewDir -Name 'skipfirst'
        $first = FxNewAccountHome -Root $root -Name 'first' -Login none
        $second = FxNewAccountHome -Root $root -Name 'second' -Login login
        $machine = FxWriteMachine -Root $root -Account @([pscustomobject]@{ name = 'first'; codex_home = $first }, [pscustomobject]@{ name = 'second'; codex_home = $second })
        $selection = Resolve-CodexAccountSelection -Profile 'scan' -MachineConfigPath $machine
        $selection.AccountName -ceq 'second' -and @($selection.Skipped).Count -eq 1 -and @($selection.Skipped)[0].reason_code -ceq 'LoginFileMissing'
    }
    Test-Case S03 {
        $root = FxNewDir -Name 'allout'
        $a = FxNewAccountHome -Root $root -Name 'a1' -Login none
        $b = FxNewAccountHome -Root $root -Name 'b1' -Login empty
        $machine = FxWriteMachine -Root $root -Account @([pscustomobject]@{ name = 'a1'; codex_home = $a }, [pscustomobject]@{ name = 'b1'; codex_home = $b })
        $message = FxThrows { Resolve-CodexAccountSelection -Profile 'scan' -MachineConfigPath $machine }
        $message -match '^CodexAccountsAllUnavailable：' -and $message.Contains('a1:LoginFileMissing') -and $message.Contains('b1:LoginFileEmpty')
    }
    Test-Case S04 {
        $root = FxNewDir -Name 'explicit'
        $ok = FxNewAccountHome -Root $root -Name 'ok' -Login login
        $bad = FxNewAccountHome -Root $root -Name 'bad' -Login none
        $machine = FxWriteMachine -Root $root -Account @([pscustomobject]@{ name = 'ok'; codex_home = $ok }, [pscustomobject]@{ name = 'bad'; codex_home = $bad })
        $selected = Resolve-CodexAccountSelection -CodexHomePath $ok -Profile 'scan' -MachineConfigPath $machine
        $message = FxThrows { Resolve-CodexAccountSelection -CodexHomePath $bad -Profile 'scan' -MachineConfigPath $machine }
        $selected.Mode -ceq 'explicit' -and $selected.AccountName -ceq 'ok' -and $selected.CodexHome -ieq $ok -and
        $message -match '^CodexAccountNotLoggedIn：bad; LoginFileMissing; ' -and $message.Contains((Join-Path $bad 'auth.json'))
    }
    Test-Case S05 {
        $root = FxNewDir -Name 'unreg'
        $registered = FxNewAccountHome -Root $root -Name 'reg' -Login login
        $other = FxNewAccountHome -Root $root -Name 'other' -Login none
        $machine = FxWriteMachine -Root $root -Account @([pscustomobject]@{ name = 'reg'; codex_home = $registered })
        $emptyMachine = Join-Path $root 'empty.json'
        [IO.File]::WriteAllText($emptyMachine, '{"schema":"ai-agents.machine.v1","codex_accounts":[]}', $utf8NoBom)
        $notListed = Resolve-CodexAccountSelection -CodexHomePath $other -Profile 'scan' -MachineConfigPath $machine
        $emptyList = Resolve-CodexAccountSelection -CodexHomePath $other -Profile 'scan' -MachineConfigPath $emptyMachine
        $env:CODEX_HOME = $other
        try { $fallback = Resolve-CodexAccountSelection -Profile 'scan' -MachineConfigPath $emptyMachine } finally { $env:CODEX_HOME = $originalCodexHomeEnv }
        $notListed.Mode -ceq 'unregistered' -and $null -eq $notListed.AccountName -and $emptyList.Mode -ceq 'unregistered' -and $null -eq $emptyList.AccountName -and
        $fallback.Mode -ceq 'unregistered' -and $null -eq $fallback.AccountName -and $fallback.CodexHome -ieq $other
    }
    Test-Case S06 {
        $root = FxNewDir -Name 'explicit-profile'
        $noProfile = FxNewAccountHome -Root $root -Name 'np' -Login login -ProfileConfig @()
        $machine = FxWriteMachine -Root $root -Account @([pscustomobject]@{ name = 'np'; codex_home = $noProfile })
        $message = FxThrows { Resolve-CodexAccountSelection -CodexHomePath $noProfile -Profile 'scan' -MachineConfigPath $machine }
        $message -match '^ProfileEvidenceUnknown：'
    }

    # ---------- 事件分類 ----------
    $eventDir = FxNewDir -Name 'events'
    $modelMessage = "The 'gpt-6.1-terra' model is not supported when using Codex with a ChatGPT account"
    Test-Case E01 {
        $files = FxEvents -Directory $eventDir -Name 'model-event' -Event @([ordered]@{ type = 'turn.started' }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = $modelMessage } })
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
        $rejection = Convert-EventEvidenceToServiceRejection -EventEvidence ([pscustomobject]$evidence)
        $evidence.rejection_kind -ceq 'model-not-supported' -and $evidence.item_event_count -eq 0 -and $null -ne $rejection -and $rejection.reason_code -ceq 'model-not-supported' -and $rejection.retry_allowed -eq $false -and
        (Test-DispatchAccountFailoverEligible -EventEvidence $evidence) -and (Get-DispatchFailureReasonCode -Message 'QuotaServiceRejected service rejection' -Phase 'started') -ceq 'QuotaServiceRejected'
    }
    Test-Case E02 {
        $files = FxEvents -Directory $eventDir -Name 'model-stderr' -Event @([ordered]@{ type = 'thread.started'; thread_id = [guid]::NewGuid().ToString() }, [ordered]@{ type = 'turn.started' }) -Stderr ("ERROR: " + $modelMessage)
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
        $rejection = Convert-EventEvidenceToServiceRejection -EventEvidence ([pscustomobject]$evidence)
        $evidence.rejection_kind -ceq 'model-not-supported' -and $rejection.reason_code -ceq 'model-not-supported' -and $rejection.raw_evidence_path -ieq $files.error -and (Test-DispatchAccountFailoverEligible -EventEvidence $evidence)
    }
    Test-Case E03 {
        $files = FxEvents -Directory $eventDir -Name 'unauth' -Event @([ordered]@{ type = 'error'; message = 'unexpected status 401 Unauthorized' }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'unexpected status 401 Unauthorized' } })
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
        $stderrOnly = FxEvents -Directory $eventDir -Name 'unauth-stderr' -Event @([ordered]@{ type = 'turn.started' }) -Stderr '2026-11-09T08:51:23.033927Z ERROR codex_core::client: Reconnecting... 401 Unauthorized'
        $stderrEvidence = Get-DispatchEventEvidence -EventPath $stderrOnly.event -ErrorStreamPath $stderrOnly.error
        $evidence.rejection_kind -ceq 'unauthorized' -and $stderrEvidence.rejection_kind -ceq 'unauthorized' -and (Convert-EventEvidenceToServiceRejection -EventEvidence ([pscustomobject]$evidence)).reason_code -ceq 'unauthorized'
    }
    Test-Case E04 {
        $files = FxEvents -Directory $eventDir -Name 'usage' -Event @([ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'You hit your usage limit' } })
        $evidence = Get-DispatchEventEvidence -EventPath $files.event
        $rejection = Convert-EventEvidenceToServiceRejection -EventEvidence ([pscustomobject]$evidence)
        $evidence.rejection_kind -ceq 'usage-limit' -and $evidence.usage_limit -and $rejection.reason_code -ceq 'usage-limit' -and (Test-DispatchAccountFailoverEligible -EventEvidence $evidence)
    }
    Test-Case E05 {
        $files = FxEvents -Directory $eventDir -Name 'feature' -Event @([ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'the feature is not supported' } }) -Stderr 'feature flag is not supported by this build'
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
        # 「feature is not supported」不含 model，不是 model-not-supported；尚無 item 進度的終局失敗歸為 unclassified，仍不產生 service_rejection。
        $evidence.rejection_kind -cne 'model-not-supported' -and $evidence.rejection_kind -ceq 'unclassified' -and $null -eq (Convert-EventEvidenceToServiceRejection -EventEvidence ([pscustomobject]$evidence)) -and (Test-DispatchAccountFailoverEligible -EventEvidence $evidence)
    }
    Test-Case E06 {
        $rate = FxEvents -Directory $eventDir -Name 'rate' -Event @([ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'rate limit exceeded' } })
        $http429 = FxEvents -Directory $eventDir -Name 'http429' -Event @([ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'HTTP 429 Too many requests' } })
        $rateEvidence = Get-DispatchEventEvidence -EventPath $rate.event
        $http429Evidence = Get-DispatchEventEvidence -EventPath $http429.event
        $rateEvidence.rejection_kind -ceq 'rate-limited' -and $rateEvidence.usage_limit -and $http429Evidence.rejection_kind -ceq 'rate-limited' -and $http429Evidence.usage_limit -and
        $null -ne (Convert-EventEvidenceToServiceRejection -EventEvidence ([pscustomobject]$http429Evidence)) -and (Test-DispatchAccountFailoverEligible -EventEvidence $rateEvidence) -and (Test-DispatchAccountFailoverEligible -EventEvidence $http429Evidence)
    }
    Test-Case E07 {
        $files = FxEvents -Directory $eventDir -Name 'progress' -Event @([ordered]@{ type = 'item.started'; item = [ordered]@{ type = 'command_execution' } }, [ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'agent_message'; text = 'partial' } }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = $modelMessage } })
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
        $evidence.rejection_kind -ceq 'model-not-supported' -and $evidence.item_event_count -eq 2 -and -not (Test-DispatchAccountFailoverEligible -EventEvidence $evidence)
    }
    Test-Case E08 {
        $files = FxEvents -Directory $eventDir -Name 'plain' -Event @([ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'sandbox command failed' } })
        $completed = FxEvents -Directory $eventDir -Name 'done' -Event @([ordered]@{ type = 'turn.completed' })
        $plainEvidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
        $doneEvidence = Get-DispatchEventEvidence -EventPath $completed.event -ErrorStreamPath $completed.error
        $missing = Get-DispatchEventEvidence -EventPath (Join-Path $eventDir 'absent.jsonl')
        # 本地失敗由詞彙表（G4）排除：終局失敗訊息存在但命中詞彙表，不產生 unclassified。缺事件檔且無 stderr 時 G1 不成立。
        $null -eq $plainEvidence.rejection_kind -and $plainEvidence.terminal_failure.message -ceq 'sandbox command failed' -and $null -eq $doneEvidence.rejection_kind -and $null -eq $missing.rejection_kind -and $null -eq $missing.terminal_failure -and $missing.item_event_count -eq 0 -and
        -not (Test-DispatchAccountFailoverEligible -EventEvidence $plainEvidence) -and -not (Test-DispatchAccountFailoverEligible -EventEvidence $null)
    }
    Test-Case E09 {
        (Get-DispatchFailureReasonCode -Message 'CodexAccountNotLoggedIn：a; LoginFileMissing; C:\x\auth.json' -Phase 'preflight') -ceq 'CodexAccountNotLoggedIn' -and
        (Get-DispatchFailureReasonCode -Message 'CodexAccountsAllUnavailable：a:LoginFileMissing:C:\x' -Phase 'preflight') -ceq 'CodexAccountsAllUnavailable'
    }
    Test-Case E10 {
        $unauthorizedStep = Get-DispatchRejectionRecommendedNextStep -RejectionKind 'unauthorized'
        $modelStep = Get-DispatchRejectionRecommendedNextStep -RejectionKind 'model-not-supported'
        $usageStep = Get-DispatchRejectionRecommendedNextStep -RejectionKind 'usage-limit'
        $accountHome = 'C:\fx-home\acct-a'
        $expectedCommand = "powershell.exe -NoProfile -Command '`$env:CODEX_HOME = ''" + $accountHome + "''; codex login'"
        $unauthorizedWithHome = Get-DispatchRejectionRecommendedNextStep -RejectionKind 'unauthorized' -CodexHome $accountHome
        $modelWithHome = Get-DispatchRejectionRecommendedNextStep -RejectionKind 'model-not-supported' -CodexHome $accountHome
        $usageWithHome = Get-DispatchRejectionRecommendedNextStep -RejectionKind 'usage-limit' -CodexHome $accountHome
        $unauthorizedStep.Contains('重新登入') -and $modelStep.Contains('model') -and $usageStep.Contains('額度') -and @($unauthorizedStep, $modelStep, $usageStep | Select-Object -Unique).Count -eq 3 -and
        $unauthorizedStep.Contains('account_failover.relogin_command') -and $unauthorizedStep.Contains('attempts[].relogin_command') -and -not $unauthorizedStep.Contains('codex login') -and
        $unauthorizedWithHome.Contains('重新登入命令：' + $expectedCommand) -and $unauthorizedWithHome.Contains('重新登入') -and
        -not $modelStep.Contains('codex login') -and -not $usageStep.Contains('codex login') -and -not $modelWithHome.Contains('codex login') -and -not $usageWithHome.Contains('codex login') -and
        -not (Get-DispatchRejectionObservation -RejectionKind 'model-not-supported' -CodexHome $accountHome).Contains('codex login') -and -not (Get-DispatchRejectionObservation -RejectionKind 'usage-limit' -CodexHome $accountHome).Contains('codex login') -and
        (Get-DispatchRejectionObservation -RejectionKind 'unauthorized' -CodexHome $accountHome).Contains($expectedCommand) -and -not (Get-DispatchRejectionObservation -RejectionKind 'unauthorized').Contains('codex login')
    }
    # F-004 stderr 錯誤行守衛：只有 Codex 錯誤行（時間 ERROR target: 訊息，或 ERROR: 訊息）才做拒絕比對；
    # 工具執行失敗（codex_core::tools::）會回顯被執行的命令列，不屬服務端拒絕。
    $echoToolLine = '2026-11-09T09:00:58.993011Z ERROR codex_core::tools::router: error=exec_command failed: CreateProcess { message: "Rejected(\"`rg -n \\\"Unauthorized|401\\\" skills`\") rejected: blocked by policy" }'
    $mcpNoiseLine = '2026-11-09T08:51:23.026988Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed'
    Test-Case E11 {
        $completedEvents = @([ordered]@{ type = 'turn.started' }, [ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'agent_message'; text = 'done' } }, [ordered]@{ type = 'turn.completed' })
        $stderr = ($mcpNoiseLine, $echoToolLine, 'rg -n "Unauthorized|401" skills\codex-dispatch', '2026-11-09T09:01:00.000000Z INFO codex_core::client: 401 Unauthorized is documented here', 'The model gpt-x is not supported (plain text, not an error line)') -join "`n"
        $files = FxEvents -Directory $eventDir -Name 'success-noise' -Event $completedEvents -Stderr $stderr
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
        $null -eq $evidence.rejection_kind -and @($evidence.rejection_evidence).Count -eq 0 -and $evidence.event_state -ceq 'completed' -and
        $null -eq (Convert-EventEvidenceToServiceRejection -EventEvidence ([pscustomobject]$evidence)) -and -not (Test-DispatchAccountFailoverEligible -EventEvidence $evidence)
    }
    Test-Case E12 {
        $unauthLine = '2026-11-09T09:02:00.123456Z ERROR codex_core::client: unexpected status 401 Unauthorized: Missing bearer or basic authentication in header'
        $files = FxEvents -Directory $eventDir -Name 'stderr-401' -Event @([ordered]@{ type = 'turn.started' }) -Stderr ($mcpNoiseLine + "`n" + $echoToolLine + "`n" + $unauthLine)
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
        $rejection = Convert-EventEvidenceToServiceRejection -EventEvidence ([pscustomobject]$evidence)
        $evidence.rejection_kind -ceq 'unauthorized' -and @($evidence.rejection_evidence).Count -eq 1 -and $evidence.rejection_evidence[0].raw_line -ceq $unauthLine -and
        $rejection.reason_code -ceq 'unauthorized' -and (Test-DispatchAccountFailoverEligible -EventEvidence $evidence)
    }
    Test-Case E13 {
        $modelLine = '2026-11-09T09:03:00.000001Z ERROR codex_core::client: ' + $modelMessage
        $files = FxEvents -Directory $eventDir -Name 'stderr-model' -Event @([ordered]@{ type = 'turn.started' }) -Stderr ($echoToolLine + "`n" + $modelLine)
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
        $rejection = Convert-EventEvidenceToServiceRejection -EventEvidence ([pscustomobject]$evidence)
        $evidence.rejection_kind -ceq 'model-not-supported' -and @($evidence.rejection_evidence).Count -eq 1 -and $rejection.reason_code -ceq 'model-not-supported' -and (Test-DispatchAccountFailoverEligible -EventEvidence $evidence)
    }
    Test-Case E14 {
        $files = FxEvents -Directory $eventDir -Name 'usage-with-noise' -Event @([ordered]@{ type = 'turn.started' }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'You hit your usage limit' } }) -Stderr ($mcpNoiseLine + "`n" + $echoToolLine)
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
        $rejection = Convert-EventEvidenceToServiceRejection -EventEvidence ([pscustomobject]$evidence)
        $evidence.rejection_kind -ceq 'usage-limit' -and $evidence.usage_limit -and $rejection.reason_code -ceq 'usage-limit' -and (Test-DispatchAccountFailoverEligible -EventEvidence $evidence)
    }
    Test-Case E15 {
        $accept = @(
            '2026-11-09T09:02:00Z ERROR codex_core::client: x', '2026-11-09T09:02:00.5+08:00 ERROR codex_core::client: x', 'ERROR: x', '  ERROR: x'
        ) | ForEach-Object { Test-DispatchErrorStreamErrorLine -Line $_ }
        $reject = @(
            $echoToolLine, '2026-11-09T09:02:00Z ERROR codex_core::tools::unified_exec: x', '2026-11-09T09:02:00Z WARN codex_core::client: x', 'ERROR codex_core::client: x', 'noERROR: x', '', 'rg -n "401"'
        ) | ForEach-Object { Test-DispatchErrorStreamErrorLine -Line $_ }
        @($accept | Where-Object { $_ -eq $true }).Count -eq 4 -and @($reject | Where-Object { $_ -eq $false }).Count -eq 7
    }

    # ---------- 未分類拒絕與 rate-limited ----------
    function FxEventsFromLine {
        param([string]$Directory, [string]$Name, [string[]]$Line, [string]$Stderr = '')
        $eventPath = Join-Path $Directory ($Name + '.jsonl')
        $errorPath = Join-Path $Directory ($Name + '.stderr.txt')
        [IO.File]::WriteAllText($eventPath, (($Line -join "`n") + "`n"), $utf8NoBom)
        [IO.File]::WriteAllText($errorPath, $Stderr, $utf8NoBom)
        return [pscustomobject]@{ event = $eventPath; error = $errorPath }
    }
    # P1 實測 cloudy-wing 的 scan 事件流原文（見 dispatch-account-resilience 證據），逐字保留；
    # 被拒前有一筆 item.type 為 error 的 item.completed（model metadata 警告）。
    $cloudyWingScanLine = @(
        '{"type":"thread.started","thread_id":"01a1c5de-5fa7-79f2-9e4a-c43dd7aacd33"}',
        '{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for `gpt-6.1-terra` not found. Defaulting to fallback metadata; this can degrade performance and cause issues."}}',
        '{"type":"turn.started"}',
        '{"type":"error","message":"The ''gpt-6.1-terra'' model is not supported when using Codex with a ChatGPT account."}',
        '{"type":"turn.failed","error":{"message":"The ''gpt-6.1-terra'' model is not supported when using Codex with a ChatGPT account."}}'
    )
    $cloudyWingDeepReviewLine = @(
        '{"type":"thread.started","thread_id":"01a1c5de-9f15-7052-92fa-66695c6f58df"}',
        '{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for `gpt-6.1-sol` not found. Defaulting to fallback metadata; this can degrade performance and cause issues."}}',
        '{"type":"turn.started"}',
        '{"type":"error","message":"The ''gpt-6.1-sol'' model is not supported when using Codex with a ChatGPT account."}',
        '{"type":"turn.failed","error":{"message":"The ''gpt-6.1-sol'' model is not supported when using Codex with a ChatGPT account."}}'
    )
    function FxFailedTurnEvents {
        param([string]$Name, [string]$Message, [object[]]$Prefix = @())
        return FxEvents -Directory $eventDir -Name $Name -Event (@([ordered]@{ type = 'thread.started'; thread_id = [guid]::NewGuid().ToString() }, [ordered]@{ type = 'turn.started' }) + @($Prefix) + @([ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = $Message } }))
    }
    Test-Case E15-AR {
        $files = FxFailedTurnEvents -Name 'forbidden' -Message '403 Forbidden'
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
        $failover = New-DispatchAccountFailoverEvidence -EventEvidence $evidence
        $evidence.rejection_kind -ceq 'unclassified' -and $evidence.item_event_count -eq 0 -and (Test-DispatchAccountFailoverEligible -EventEvidence $evidence) -and $evidence.usage_limit -eq $false -and
        $null -eq (Convert-EventEvidenceToServiceRejection -EventEvidence ([pscustomobject]$evidence)) -and
        $evidence.terminal_failure.event_type -ceq 'turn.failed' -and $evidence.terminal_failure.message -ceq '403 Forbidden' -and $evidence.terminal_failure.source -ceq 'event-stream' -and
        @($evidence.rejection_evidence).Count -eq 1 -and $evidence.rejection_evidence[0].rejection_kind -ceq 'unclassified' -and $evidence.rejection_evidence[0].source -ceq 'event-stream' -and $evidence.rejection_evidence[0].raw_line.Length -le 500 -and
        $failover.eligible -eq $true -and $failover.rejection_kind -ceq 'unclassified' -and $failover.message_excerpt -ceq '403 Forbidden' -and $failover.evidence_source -ceq 'event-stream'
    }
    Test-Case E16 {
        $files = FxFailedTurnEvents -Name 'payment' -Message 'payment required'
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
        $evidence.rejection_kind -ceq 'unclassified' -and (Test-DispatchAccountFailoverEligible -EventEvidence $evidence) -and $null -eq (Convert-EventEvidenceToServiceRejection -EventEvidence ([pscustomobject]$evidence))
    }
    Test-Case E17 {
        $files = FxFailedTurnEvents -Name 'unknown-text' -Message 'Something unexpected happened'
        $long = FxFailedTurnEvents -Name 'unknown-long' -Message ('Something unexpected happened ' + ('x' * 800))
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
        $longEvidence = Get-DispatchEventEvidence -EventPath $long.event -ErrorStreamPath $long.error
        $evidence.rejection_kind -ceq 'unclassified' -and (Test-DispatchAccountFailoverEligible -EventEvidence $evidence) -and $longEvidence.terminal_failure.message.Length -eq 500 -and $longEvidence.rejection_evidence[0].raw_line.Length -le 500
    }
    Test-Case E18 {
        $files = FxFailedTurnEvents -Name 'http429-turn' -Message 'HTTP 429'
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
        $rejection = Convert-EventEvidenceToServiceRejection -EventEvidence ([pscustomobject]$evidence)
        $evidence.rejection_kind -ceq 'rate-limited' -and $evidence.usage_limit -and (Test-DispatchAccountFailoverEligible -EventEvidence $evidence) -and $null -ne $rejection -and $rejection.retry_allowed -eq $false
    }
    Test-Case E19 {
        $dir = FxNewDir -Name 'e19'
        $stderrOnly = Join-Path $dir 'only.stderr.txt'
        [IO.File]::WriteAllText($stderrOnly, 'ERROR: upstream rejected', $utf8NoBom)
        $evidence = Get-DispatchEventEvidence -EventPath (Join-Path $dir 'absent.jsonl') -ErrorStreamPath $stderrOnly -ProcessExitCode 1
        $tracing = FxEvents -Directory $dir -Name 'started-only' -Event @([ordered]@{ type = 'thread.started'; thread_id = [guid]::NewGuid().ToString() }, [ordered]@{ type = 'turn.started' }) -Stderr ('2026-11-09T09:02:00.123456Z ERROR codex_core::client: upstream rejected' + "`n" + '2026-11-09T09:02:01Z ERROR codex_core::client: Reconnecting... 5/5 (connection failed)')
        $tracingEvidence = Get-DispatchEventEvidence -EventPath $tracing.event -ErrorStreamPath $tracing.error -ProcessExitCode 1
        $evidence.rejection_kind -ceq 'unclassified' -and (Test-DispatchAccountFailoverEligible -EventEvidence $evidence) -and $evidence.terminal_failure.source -ceq 'error-stream' -and $evidence.terminal_failure.message -ceq 'upstream rejected' -and
        $evidence.rejection_evidence[0].source -ceq 'error-stream' -and $evidence.rejection_evidence[0].raw_line -ceq 'ERROR: upstream rejected' -and -not [string]::IsNullOrWhiteSpace([string]$evidence.rejection_evidence[0].sha256) -and
        $tracingEvidence.rejection_kind -ceq 'unclassified' -and $tracingEvidence.terminal_failure.message -ceq 'upstream rejected' -and (Test-DispatchAccountFailoverEligible -EventEvidence $tracingEvidence)
    }
    Test-Case E20 {
        $allIneligible = $true
        $index = 0
        foreach ($message in @('sandbox command failed', 'apply_patch failed', 'ENOENT', 'failed to spawn')) {
            $index++
            $files = FxFailedTurnEvents -Name ('local-' + $index) -Message $message
            $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
            if ((Test-DispatchAccountFailoverEligible -EventEvidence $evidence) -or $null -ne $evidence.rejection_kind -or $evidence.item_event_count -ne 0) { throw ('本地失敗被判為可換帳號：' + $message) }
        }
        $allIneligible
    }
    Test-Case E20-vocabulary {
        # 本地失敗詞彙表每個詞各一個正向案例：命中者不換帳號。
        $vocabulary = @(
            'sandbox denied the write', 'command failed', 'command exited', 'command not found', 'process exited with code 2', 'exit status 1', 'apply_patch rejected', 'patch failed to apply',
            'tool call rejected', 'tool execution error', 'codex_core::tools::router error', 'ENOENT', 'EACCES', 'EPERM', 'no such file or directory', 'cannot find the path specified',
            'cannot find file x.txt', 'the file is used by another process', 'failed to start', 'failed to launch', 'failed to spawn', 'spawn error'
        )
        $index = 0
        foreach ($message in $vocabulary) {
            $index++
            $files = FxFailedTurnEvents -Name ('vocab-' + $index) -Message $message
            $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
            if ((Test-DispatchAccountFailoverEligible -EventEvidence $evidence) -or $null -ne $evidence.rejection_kind) { throw ('詞彙表案例被判為可換帳號：' + $message) }
        }
        $true
    }
    Test-Case E21 {
        # 暫時性事件：重連後完成、只有重連 error 事件而無終局事件、終局失敗訊息為重連、stderr 只有重連行，皆不換帳號。
        $reconnectThenDone = FxEvents -Directory $eventDir -Name 'reconnect-done' -Event @([ordered]@{ type = 'turn.started' }, [ordered]@{ type = 'error'; message = 'Reconnecting... 5/5 (connection failed)' }, [ordered]@{ type = 'turn.completed' })
        $reconnectOnly = FxEvents -Directory $eventDir -Name 'reconnect-only' -Event @([ordered]@{ type = 'turn.started' }, [ordered]@{ type = 'error'; message = 'Reconnecting... 5/5 (connection failed)' })
        $reconnectFailed = FxFailedTurnEvents -Name 'reconnect-failed' -Message 'Reconnecting... 5/5 (connection failed)'
        $reconnectStderr = FxEvents -Directory $eventDir -Name 'reconnect-stderr' -Event @([ordered]@{ type = 'turn.started' }) -Stderr '2026-11-09T09:02:01Z ERROR codex_core::client: Reconnecting... 5/5 (connection failed)'
        $first = Get-DispatchEventEvidence -EventPath $reconnectThenDone.event -ErrorStreamPath $reconnectThenDone.error -ProcessExitCode 0
        $second = Get-DispatchEventEvidence -EventPath $reconnectOnly.event -ErrorStreamPath $reconnectOnly.error -ProcessExitCode 1
        $third = Get-DispatchEventEvidence -EventPath $reconnectFailed.event -ErrorStreamPath $reconnectFailed.error -ProcessExitCode 1
        $fourth = Get-DispatchEventEvidence -EventPath $reconnectStderr.event -ErrorStreamPath $reconnectStderr.error -ProcessExitCode 1
        $metadataOnly = FxFailedTurnEvents -Name 'metadata-failed' -Message 'Model metadata for `gpt-x` not found. Defaulting to fallback metadata.'
        $fifth = Get-DispatchEventEvidence -EventPath $metadataOnly.event -ErrorStreamPath $metadataOnly.error -ProcessExitCode 1
        foreach ($evidence in @($first, $second, $third, $fourth, $fifth)) {
            if ((Test-DispatchAccountFailoverEligible -EventEvidence $evidence) -or $null -ne $evidence.rejection_kind -or $null -ne $evidence.terminal_failure) { throw '暫時性事件被判為可換帳號。' }
        }
        $true
    }
    Test-Case E22 {
        $files = FxFailedTurnEvents -Name 'progress-then-403' -Message '403 Forbidden' -Prefix @([ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'agent_message'; text = 'partial' } })
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
        $evidence.item_event_count -eq 1 -and $null -eq $evidence.rejection_kind -and -not (Test-DispatchAccountFailoverEligible -EventEvidence $evidence)
    }
    Test-Case E23 {
        $dir = FxNewDir -Name 'e23'
        $errorPath = Join-Path $dir 'only.stderr.txt'
        [IO.File]::WriteAllText($errorPath, 'ERROR: upstream rejected', $utf8NoBom)
        $zero = Get-DispatchEventEvidence -EventPath (Join-Path $dir 'absent.jsonl') -ErrorStreamPath $errorPath -ProcessExitCode 0
        $unknown = Get-DispatchEventEvidence -EventPath (Join-Path $dir 'absent.jsonl') -ErrorStreamPath $errorPath
        $null -eq $zero.rejection_kind -and $null -eq $unknown.rejection_kind -and -not (Test-DispatchAccountFailoverEligible -EventEvidence $zero) -and -not (Test-DispatchAccountFailoverEligible -EventEvidence $unknown)
    }
    Test-Case E24 {
        # P1 實測分支 B：deep-review 的原文同為 model not supported，既有 kind 命中並可換帳號。
        $files = FxEventsFromLine -Directory $eventDir -Name 'cloudy-deep-review' -Line $cloudyWingDeepReviewLine
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error -ProcessExitCode 1
        $evidence.rejection_kind -ceq 'model-not-supported' -and $evidence.item_event_count -eq 0 -and (Test-DispatchAccountFailoverEligible -EventEvidence $evidence)
    }
    Test-Case E25 {
        $files = FxFailedTurnEvents -Name 'unclassified-no-rejection' -Message 'Something unexpected happened'
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsRoot 'dispatch\run-recovery.ps1'), [ref]$tokens, [ref]$errors)
        $kindList = @(Get-DispatchServiceRejectionKindList)
        $runRecoveryText = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'dispatch\run-recovery.ps1'), [Text.Encoding]::UTF8)
        $evidence.rejection_kind -ceq 'unclassified' -and $null -eq (Convert-EventEvidenceToServiceRejection -EventEvidence ([pscustomobject]$evidence)) -and $errors.Count -eq 0 -and
        $kindList -contains 'unauthorized' -and $kindList -contains 'model-not-supported' -and $kindList -contains 'subscription-inactive' -and $kindList -notcontains 'unclassified' -and $kindList -notcontains 'rate-limited' -and
        $runRecoveryText -notmatch '未分類不換帳號'
    }
    Test-Case E26 {
        $files = FxEventsFromLine -Directory $eventDir -Name 'cloudy-scan' -Line $cloudyWingScanLine
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error -ProcessExitCode 1
        $evidence.rejection_kind -ceq 'model-not-supported' -and $evidence.item_event_count -eq 0 -and (Test-DispatchAccountFailoverEligible -EventEvidence $evidence) -and
        (Convert-EventEvidenceToServiceRejection -EventEvidence ([pscustomobject]$evidence)).reason_code -ceq 'model-not-supported'
    }
    Test-Case E27 {
        foreach ($itemType in @('agent_message', 'command_execution')) {
            $files = FxFailedTurnEvents -Name ('work-' + $itemType) -Message '403 Forbidden' -Prefix @([ordered]@{ type = 'item.completed'; item = [ordered]@{ type = $itemType; text = 'work' } })
            $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
            if ($evidence.item_event_count -ne 1 -or (Test-DispatchAccountFailoverEligible -EventEvidence $evidence)) { throw ('實際工作項目後的失敗被判為可換帳號：' + $itemType) }
        }
        $true
    }
    Test-Case E28 {
        # 串流中斷屬可重試類，不視為帳號問題。
        $files = FxFailedTurnEvents -Name 'stream-disconnect' -Message 'stream disconnected before completion: error sending request'
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
        $evidence.server_stream_disconnect -eq $true -and $null -eq $evidence.rejection_kind -and -not (Test-DispatchAccountFailoverEligible -EventEvidence $evidence)
    }
    Test-Case E30 {
        # 重連訊息帶 429 不是 rate-limited 證據（負向）；重連之後的終局 429 拒絕仍為 rate-limited（正向）。
        $reconnectOnly = FxEvents -Directory $eventDir -Name 'reconnect-429-only' -Event @([ordered]@{ type = 'turn.started' }, [ordered]@{ type = 'error'; message = 'Reconnecting... 1/5 (HTTP 429)' })
        $reconnectThenFailed = FxFailedTurnEvents -Name 'reconnect-429-then-failed' -Message 'HTTP 429 Too Many Requests' -Prefix @([ordered]@{ type = 'error'; message = 'Reconnecting... 1/5 (HTTP 429)' })
        $terminal429 = FxFailedTurnEvents -Name 'terminal-429' -Message 'HTTP 429'
        $negative = Get-DispatchEventEvidence -EventPath $reconnectOnly.event -ErrorStreamPath $reconnectOnly.error -ProcessExitCode 1
        $positive = Get-DispatchEventEvidence -EventPath $reconnectThenFailed.event -ErrorStreamPath $reconnectThenFailed.error -ProcessExitCode 1
        $terminal = Get-DispatchEventEvidence -EventPath $terminal429.event -ErrorStreamPath $terminal429.error -ProcessExitCode 1
        $null -eq $negative.rejection_kind -and -not (Test-DispatchAccountFailoverEligible -EventEvidence $negative) -and
        $positive.rejection_kind -ceq 'rate-limited' -and (Test-DispatchAccountFailoverEligible -EventEvidence $positive) -and
        $terminal.rejection_kind -ceq 'rate-limited' -and (Test-DispatchAccountFailoverEligible -EventEvidence $terminal)
    }
    Test-Case E31 {
        # 本地失敗詞彙以完整訊息比對：前 600 字為一般文字、尾端才出現 ENOENT 或 sandbox command failed 時仍屬本地失敗，不換帳號；輸出證據仍截斷為 500 字。
        $allIneligible = $true
        foreach ($tail in @('ENOENT', 'sandbox command failed')) {
            $files = FxFailedTurnEvents -Name ('long-local-' + ($tail -replace '\W', '')) -Message (('Something unexpected happened ' * 25) + $tail)
            $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error -ProcessExitCode 1
            if ((Test-DispatchAccountFailoverEligible -EventEvidence $evidence) -or $null -ne $evidence.rejection_kind -or $evidence.terminal_failure.message.Length -ne 500) { throw ('長訊息尾端的本地失敗被判為可換帳號：' + $tail) }
        }
        $stderr = FxEvents -Directory $eventDir -Name 'long-local-stderr' -Event @([ordered]@{ type = 'turn.started' }) -Stderr ('ERROR: ' + ('Something unexpected happened ' * 25) + 'ENOENT')
        $stderrEvidence = Get-DispatchEventEvidence -EventPath $stderr.event -ErrorStreamPath $stderr.error -ProcessExitCode 1
        $plain = FxFailedTurnEvents -Name 'long-plain' -Message (('Something unexpected happened ' * 25) + 'end')
        $plainEvidence = Get-DispatchEventEvidence -EventPath $plain.event -ErrorStreamPath $plain.error -ProcessExitCode 1
        $null -eq $stderrEvidence.rejection_kind -and $plainEvidence.rejection_kind -ceq 'unclassified' -and (Test-DispatchAccountFailoverEligible -EventEvidence $plainEvidence)
    }
    Test-Case E29 {
        # item.type 為 error 的 item.started 與 item.completed 是警告，不算 item 進度；其他 item 型別照算。
        $files = FxFailedTurnEvents -Name 'error-items' -Message 'Something unexpected happened' -Prefix @([ordered]@{ type = 'item.started'; item = [ordered]@{ type = 'error'; message = 'warning' } }, [ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'error'; message = 'warning' } })
        $counted = FxFailedTurnEvents -Name 'error-and-work' -Message 'Something unexpected happened' -Prefix @([ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'error'; message = 'warning' } }, [ordered]@{ type = 'item.started'; item = [ordered]@{ type = 'command_execution' } })
        $noItemObject = FxEvents -Directory $eventDir -Name 'item-without-object' -Event @([ordered]@{ type = 'item.completed' }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'Something unexpected happened' } })
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error
        $countedEvidence = Get-DispatchEventEvidence -EventPath $counted.event -ErrorStreamPath $counted.error
        $noItemEvidence = Get-DispatchEventEvidence -EventPath $noItemObject.event -ErrorStreamPath $noItemObject.error
        $evidence.item_event_count -eq 0 -and (Test-DispatchAccountFailoverEligible -EventEvidence $evidence) -and $countedEvidence.item_event_count -eq 1 -and -not (Test-DispatchAccountFailoverEligible -EventEvidence $countedEvidence) -and $noItemEvidence.item_event_count -eq 1
    }

    # ---------- 換帳號外層 ----------
    Test-Case F01 {
        $fixture = FxNewRequestFixture -Slug 'fx-one'
        $accounts = FxAccounts -Root $fixture.root -Name @('acc-a', 'acc-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acc-a' = 'reject:model-not-supported'; 'acc-b' = 'completed' }
        $second = $script:FxAttemptLog[1]
        $derived = $second.document
        $script:FxAttemptLog.Count -eq 2 -and [string]$run.result.status -ceq 'completed' -and $second.slug -ceq 'fx-one-r2' -and
        $derived.dispatch_root -ceq $fixture.document.dispatch_root.Replace('fx-one', 'fx-one-r2') -and
        $derived.failure_receipt_path -ceq $fixture.document.failure_receipt_path.Replace('fx-one', 'fx-one-r2') -and
        $derived.result_path -ceq $fixture.document.result_path.Replace('fx-one', 'fx-one-r2') -and
        $derived.prepare_artifacts[0].destination -ceq $fixture.document.prepare_artifacts[0].destination.Replace('fx-one', 'fx-one-r2') -and
        $derived.prompt_path -ceq $fixture.prompt_path -and @($derived.target_path)[0] -ceq $fixture.target_path -and $derived.source_root -ceq $fixture.root -and
        $second.request_path -ieq (Join-Path $fixture.history 'dispatch-request-fx-one-r2.json') -and $script:FxAttemptLog[0].request_path -ieq $fixture.request_path -and
        $script:FxAttemptLog[0].slug -ceq 'fx-one' -and $second.codex_home -ieq $accounts[1].codex_home
    }
    Test-Case F02 {
        $fixture = FxNewRequestFixture -Slug 'fx-three'
        $accounts = FxAccounts -Root $fixture.root -Name @('acc-a', 'acc-b', 'acc-c')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acc-a' = 'reject:unauthorized'; 'acc-b' = 'reject:usage-limit'; 'acc-c' = 'completed' }
        $outcomes = @($run.summary.attempts | ForEach-Object { $_.outcome + ':' + $_.rejection_kind })
        $script:FxAttemptLog.Count -eq 3 -and [string]$run.result.status -ceq 'completed' -and ($outcomes -join ',') -ceq 'rejected:unauthorized,rejected:usage-limit,completed:' -and
        (@($script:FxAttemptLog | ForEach-Object { $_.slug }) -join ',') -ceq 'fx-three,fx-three-r2,fx-three-r3' -and -not [bool]$run.summary.all_unavailable
    }
    foreach ($count in 1, 2, 3) {
        Test-Case ('F03-' + $count) {
            $fixture = FxNewRequestFixture -Slug ('fx-all' + $count)
            $names = @(1..$count | ForEach-Object { 'acc-' + $_ })
            $accounts = FxAccounts -Root $fixture.root -Name $names
            $machine = FxWriteMachine -Root $fixture.root -Account $accounts
            $behavior = @{}
            foreach ($name in $names) { $behavior[$name] = 'reject:model-not-supported' }
            $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior $behavior
            $homes = @($run.summary.attempts | ForEach-Object { $_.codex_home })
            $script:FxAttemptLog.Count -eq $count -and @($run.summary.attempts).Count -eq $count -and @($homes | Select-Object -Unique).Count -eq $count -and [bool]$run.summary.all_unavailable -and
            [int]$run.summary.final_attempt -eq $count -and [string]$run.result.status -ceq 'failed' -and [bool]$run.result.account_failover_summary.all_unavailable -and
            [string]$run.result.account_failover_summary.error_code -ceq 'CodexAccountsAllUnavailable' -and [int]$run.result.account_failover_summary.attempt_count -eq $count
        }
    }
    Test-Case F04 {
        $fixture = FxNewRequestFixture -Slug 'fx-none'
        $accounts = FxAccounts -Root $fixture.root -Name @('acc-a', 'acc-b') -Login none
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{}
        $run.error -match '^CodexAccountsAllUnavailable：' -and $run.error.Contains('acc-a:LoginFileMissing') -and $script:FxAttemptLog.Count -eq 0 -and
        [bool]$run.summary.all_unavailable -and @($run.summary.attempts).Count -eq 0 -and $null -eq $run.summary.final_attempt -and @($run.summary.skipped).Count -eq 2
    }
    Test-Case F05 {
        $fixture = FxNewRequestFixture -Slug 'fx-plain'
        $accounts = FxAccounts -Root $fixture.root -Name @('acc-a', 'acc-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acc-a' = 'plain-fail' }
        $script:FxAttemptLog.Count -eq 1 -and [string]$run.result.status -ceq 'failed' -and @($run.summary.attempts).Count -eq 1 -and $run.summary.attempts[0].outcome -ceq 'failed' -and -not [bool]$run.summary.all_unavailable
    }
    Test-Case F06 {
        $fixture = FxNewRequestFixture -Slug 'fx-progress'
        $accounts = FxAccounts -Root $fixture.root -Name @('acc-a', 'acc-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acc-a' = 'reject-progress' }
        $script:FxAttemptLog.Count -eq 1 -and $run.summary.attempts[0].outcome -ceq 'failed' -and [int]$run.summary.attempts[0].item_event_count -eq 3
    }
    Test-Case F07 {
        $fixture = FxNewRequestFixture -Slug 'fx-noinspect'
        $accounts = FxAccounts -Root $fixture.root -Name @('acc-a', 'acc-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $missing = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acc-a' = 'no-inspect' }
        $missingCount = $script:FxAttemptLog.Count
        $fixture2 = FxNewRequestFixture -Slug 'fx-unparsable'
        $accounts2 = FxAccounts -Root $fixture2.root -Name @('acc-a', 'acc-b')
        $machine2 = FxWriteMachine -Root $fixture2.root -Account $accounts2
        $unparsable = FxRunFailover -Fixture $fixture2 -MachinePath $machine2 -Behavior @{ 'acc-a' = 'unparsable' }
        $missingCount -eq 1 -and [string]$missing.result.error_code -ceq 'DispatchInspectFailed' -and $script:FxAttemptLog.Count -eq 1 -and
        [string]$unparsable.result.error_code -ceq 'DispatchAccountFailoverAttemptFailed' -and $unparsable.summary.attempts[0].outcome -ceq 'failed'
    }
    Test-Case F08 {
        $fixture = FxNewRequestFixture -Slug 'fx-fixedroot' -SlugInDispatchRoot $false
        $accounts = FxAccounts -Root $fixture.root -Name @('acc-a', 'acc-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acc-a' = 'reject:model-not-supported'; 'acc-b' = 'completed' }
        $script:FxAttemptLog.Count -eq 1 -and $run.summary.skipped_reason -ceq 'AccountFailoverNotDerivable' -and -not [bool]$run.summary.all_unavailable -and [string]$run.result.status -ceq 'failed' -and
        -not (Test-Path -LiteralPath (Join-Path $fixture.history 'dispatch-request-fx-fixedroot-r2.json'))
    }
    Test-Case F09 {
        $fixture = FxNewRequestFixture -Slug 'fx-admission'
        $accounts = FxAccounts -Root $fixture.root -Name @('acc-a', 'acc-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acc-a' = 'admission'; 'acc-b' = 'completed' }
        $script:FxAttemptLog.Count -eq 1 -and [string]$run.result.error_code -ceq 'DispatchAdmissionWriteLimit' -and $run.summary.attempts[0].outcome -ceq 'failed'
    }
    Test-Case F10 {
        $fixture = FxNewRequestFixture -Slug 'fx-collide'
        $accounts = FxAccounts -Root $fixture.root -Name @('acc-a')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $first = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acc-a' = 'completed' }
        $firstCount = $script:FxAttemptLog.Count
        $second = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acc-a' = 'completed' }
        $firstCount -eq 1 -and [string]$first.result.status -ceq 'completed' -and $second.error -match 'DispatchAccountFailoverSummaryCollision' -and $script:FxAttemptLog.Count -eq 0
    }
    Test-Case F11 {
        $fixture = FxNewRequestFixture -Slug 'fx-summary'
        $accounts = FxAccounts -Root $fixture.root -Name @('acc-a', 'acc-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acc-a' = 'reject:usage-limit'; 'acc-b' = 'completed' }
        $bytes = [IO.File]::ReadAllBytes($run.summary_path)
        $noBom = -not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
        $names = @($run.summary.PSObject.Properties.Name)
        $required = @('schema', 'line_slug', 'dispatch_slug', 'candidates', 'skipped', 'attempts', 'all_unavailable', 'final_attempt')
        $attemptNames = @($run.summary.attempts[0].PSObject.Properties.Name)
        $attemptRequired = @('attempt', 'dispatch_slug', 'account_name', 'codex_home', 'outcome', 'rejection_kind', 'item_event_count', 'dispatch_root', 'result_path')
        $secondWrite = FxThrows { Write-DispatchAccountFailoverSummary -Path $run.summary_path -SourceRoot $fixture.root -Document ([ordered]@{ schema = 'x' }) }
        $noBom -and $run.summary.schema -ceq 'ai-sessions.dispatch-account-failover.v1' -and @($required | Where-Object { $names -notcontains $_ }).Count -eq 0 -and
        @($attemptRequired | Where-Object { $attemptNames -notcontains $_ }).Count -eq 0 -and $run.summary.line_slug -ceq 'fx-line' -and $run.summary.dispatch_slug -ceq 'fx-summary' -and
        @($run.summary.candidates).Count -eq 2 -and $run.summary.attempts[0].account_name -ceq 'acc-a' -and $null -ne $secondWrite -and $secondWrite.Contains('DispatchAccountFailoverSummaryCollision') -and
        -not $run.summary_path.Contains('.tmp') -and -not [bool](Get-ChildItem -LiteralPath $fixture.history -Filter '*.dispatch.tmp' -ErrorAction SilentlyContinue)
    }
    Test-Case F12 {
        $fixture = FxNewRequestFixture -Slug 'fx-forward'
        $accounts = FxAccounts -Root $fixture.root -Name @('acc-a', 'acc-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $bound = [ordered]@{
            Operation = 'Dispatch'; RequestPath = $fixture.request_path; CodexPath = 'C:\tools\codex.cmd'; DispatchSlug = 'fx-forward'
            ResultPath = (Join-Path $fixture.history 'dispatch-result-fx-forward.json'); SourceRoot = $fixture.root; WaitForCompletion = [switch]$true
        }
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acc-a' = 'reject:model-not-supported'; 'acc-b' = 'completed' } -Bound $bound
        $first = @($script:FxAttemptLog[0].forward)
        $second = @($script:FxAttemptLog[1].forward)
        ($first -join '|').Contains('-DispatchSlug|fx-forward') -and ($second -join '|').Contains('-DispatchSlug|fx-forward-r2') -and ($second -join '|').Contains('dispatch-result-fx-forward-r2.json') -and
        $second -contains '-WaitForCompletion' -and $second -contains 'C:\tools\codex.cmd' -and $second -notcontains '-RequestPath' -and $second -notcontains '-CodexHome' -and $second -notcontains '-NoAccountFailover' -and [string]$run.result.status -ceq 'completed'
    }
    # F-006 子程序無可解析結果時，process_started 依該次嘗試的 RunRecord 判定，無依據時為 $null。
    function FxWriteAttemptRunRecord {
        param([object]$Fixture, [hashtable]$Record)
        $runDirectory = Join-Path $Fixture.history ('runs\' + $Fixture.slug)
        $null = New-Item -ItemType Directory -Path $runDirectory -Force
        [IO.File]::WriteAllText((Join-Path $runDirectory ($Record.run_id + '.json')), (ConvertTo-Json -InputObject $Record -Depth 10), $utf8NoBom)
    }
    Test-Case F13 {
        $fixture = FxNewRequestFixture -Slug 'fx-nores-unknown'
        $accounts = FxAccounts -Root $fixture.root -Name @('acc-a', 'acc-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acc-a' = 'unparsable' }
        [string]$run.result.error_code -ceq 'DispatchAccountFailoverAttemptFailed' -and [string]$run.result.status -ceq 'failed' -and
        $run.result.Contains('process_started') -and $null -eq $run.result.process_started
    }
    Test-Case F14 {
        $fixture = FxNewRequestFixture -Slug 'fx-nores-started'
        FxWriteAttemptRunRecord -Fixture $fixture -Record @{ run_id = 'run-1'; launch_state = 'started' }
        $accounts = FxAccounts -Root $fixture.root -Name @('acc-a', 'acc-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acc-a' = 'unparsable' }
        [string]$run.result.error_code -ceq 'DispatchAccountFailoverAttemptFailed' -and $run.result.process_started -eq $true
    }
    Test-Case F15 {
        $fixture = FxNewRequestFixture -Slug 'fx-nores-prestart'
        FxWriteAttemptRunRecord -Fixture $fixture -Record @{ run_id = 'run-1'; launch_state = 'launch-failed'; failure = @{ phase = 'preparation'; observation = @{ process_started = $false; failure_stage = 'preparation' } } }
        $accounts = FxAccounts -Root $fixture.root -Name @('acc-a', 'acc-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acc-a' = 'unparsable' }
        [string]$run.result.error_code -ceq 'DispatchAccountFailoverAttemptFailed' -and $run.result.process_started -eq $false -and $null -ne $run.result.process_started
    }
    Test-Case F16 {
        $fixture = FxNewRequestFixture -Slug 'fx-nores-ambiguous'
        FxWriteAttemptRunRecord -Fixture $fixture -Record @{ run_id = 'run-1'; launch_state = 'launch-failed' }
        $accounts = FxAccounts -Root $fixture.root -Name @('acc-a', 'acc-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acc-a' = 'unparsable' }
        $null -eq $run.result.process_started
    }

    Test-Case F15-AR {
        $fixture = FxNewRequestFixture -Slug 'fx-unclass'
        $accounts = FxAccounts -Root $fixture.root -Name @('acct-a', 'acct-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acct-a' = 'reject:unclassified'; 'acct-b' = 'completed' }
        $outcomes = @($run.summary.attempts | ForEach-Object { $_.outcome + ':' + $_.rejection_kind })
        $script:FxAttemptLog.Count -eq 2 -and [string]$run.result.status -ceq 'completed' -and ($outcomes -join ',') -ceq 'rejected:unclassified,completed:' -and -not [bool]$run.summary.all_unavailable
    }
    Test-Case F16-AR {
        $fixture = FxNewRequestFixture -Slug 'fx-unclass-all'
        $accounts = FxAccounts -Root $fixture.root -Name @('acct-a', 'acct-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acct-a' = 'reject:unclassified'; 'acct-b' = 'reject:unclassified' }
        $script:FxAttemptLog.Count -eq 2 -and [bool]$run.summary.all_unavailable -and [string]$run.result.status -ceq 'failed' -and [string]$run.result.account_failover_summary.error_code -ceq 'CodexAccountsAllUnavailable' -and
        (@($run.summary.attempts | ForEach-Object { $_.rejection_kind }) -join ',') -ceq 'unclassified,unclassified'
    }
    Test-Case F17 {
        # 已有 item 進度後的失敗（真實事件流經分類函式）不換帳號。
        $files = FxFailedTurnEvents -Name 'f17-progress' -Message '403 Forbidden' -Prefix @([ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'agent_message'; text = 'partial' } })
        $script:FxEventFixture['f17'] = $files.event
        $fixture = FxNewRequestFixture -Slug 'fx-reject-progress'
        $accounts = FxAccounts -Root $fixture.root -Name @('acct-a', 'acct-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acct-a' = 'events:f17'; 'acct-b' = 'completed' }
        $script:FxAttemptLog.Count -eq 1 -and $run.summary.attempts[0].outcome -ceq 'failed' -and [int]$run.summary.attempts[0].item_event_count -eq 1 -and [string]$run.result.status -ceq 'failed'
    }
    Test-Case F24 {
        # P1 實測事件流（含 item.type 為 error 的 item.completed）經實際分類，外層換到 acct-b 並完成。
        $files = FxEventsFromLine -Directory $eventDir -Name 'f24-cloudy-scan' -Line $cloudyWingScanLine
        $script:FxEventFixture['f24'] = $files.event
        $fixture = FxNewRequestFixture -Slug 'fx-cloudy-scan'
        $accounts = FxAccounts -Root $fixture.root -Name @('acct-a', 'acct-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acct-a' = 'events:f24'; 'acct-b' = 'completed' }
        $outcomes = @($run.summary.attempts | ForEach-Object { $_.outcome + ':' + $_.rejection_kind })
        $script:FxAttemptLog.Count -eq 2 -and [string]$run.result.status -ceq 'completed' -and ($outcomes -join ',') -ceq 'rejected:model-not-supported,completed:' -and $script:FxAttemptLog[1].account -ceq 'acct-b'
    }

    function FxLoginCommand {
        param([string]$AccountHome)
        return "powershell.exe -NoProfile -Command '`$env:CODEX_HOME = ''" + $AccountHome + "''; codex login'"
    }
    Test-Case F18 {
        $fixture = FxNewRequestFixture -Slug 'fx-relogin'
        $accounts = FxAccounts -Root $fixture.root -Name @('acct-a', 'acct-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acct-a' = 'reject:unauthorized'; 'acct-b' = 'completed' }
        $expected = FxLoginCommand -AccountHome $accounts[0].codex_home
        $commands = @($run.result.account_failover_summary.relogin_commands)
        $script:FxAttemptLog.Count -eq 2 -and $run.summary.attempts[0].relogin_command -ieq $expected -and $null -eq $run.summary.attempts[1].relogin_command -and
        $commands.Count -eq 1 -and $commands[0].account_name -ceq 'acct-a' -and $commands[0].command -ieq $expected -and @($run.summary.relogin_commands).Count -eq 1 -and $run.summary.relogin_commands[0].command -ieq $expected
    }
    Test-Case F19 {
        $fixture = FxNewRequestFixture -Slug 'fx-relogin-all'
        $accounts = FxAccounts -Root $fixture.root -Name @('acct-a', 'acct-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $stderrWriter = New-Object IO.StringWriter
        $previousError = [Console]::Error
        [Console]::SetError($stderrWriter)
        try { $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acct-a' = 'reject:unauthorized'; 'acct-b' = 'reject:unauthorized' } }
        finally { [Console]::SetError($previousError) }
        $stderrText = $stderrWriter.ToString()
        $first = FxLoginCommand -AccountHome $accounts[0].codex_home
        $second = FxLoginCommand -AccountHome $accounts[1].codex_home
        [bool]$run.summary.all_unavailable -and $stderrText.Contains('CodexAccountsAllUnavailable') -and $stderrText.ToLowerInvariant().Contains('重新登入：acct-a: '.ToLowerInvariant() + $first.ToLowerInvariant()) -and $stderrText.ToLowerInvariant().Contains('重新登入：acct-b: '.ToLowerInvariant() + $second.ToLowerInvariant()) -and
        @($run.result.account_failover_summary.relogin_commands).Count -eq 2
    }
    Test-Case F20 {
        # 登入檔缺少而略過的帳號同樣附重新登入命令；全部帳號不可用時例外訊息追加重新登入行。
        $fixture = FxNewRequestFixture -Slug 'fx-relogin-skipped'
        $root = $fixture.root
        $missing = [pscustomobject]@{ name = 'acct-a'; codex_home = (FxNewAccountHome -Root $root -Name 'acct-a' -Login none) }
        $ok = [pscustomobject]@{ name = 'acct-b'; codex_home = (FxNewAccountHome -Root $root -Name 'acct-b' -Login login) }
        $machine = FxWriteMachine -Root $root -Account @($missing, $ok)
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acct-b' = 'completed' }
        $skippedCommand = @($run.summary.skipped | Where-Object { $_.name -ceq 'acct-a' })[0].relogin_command
        $resultSkipped = @($run.result.account_failover_summary.skipped | Where-Object { $_.name -ceq 'acct-a' })[0]
        $fixtureNone = FxNewRequestFixture -Slug 'fx-relogin-none'
        $noneAccounts = FxAccounts -Root $fixtureNone.root -Name @('acc-a', 'acc-b') -Login none
        $noneMachine = FxWriteMachine -Root $fixtureNone.root -Account $noneAccounts
        $none = FxRunFailover -Fixture $fixtureNone -MachinePath $noneMachine -Behavior @{}
        $skippedCommand -ieq (FxLoginCommand -AccountHome $missing.codex_home) -and $resultSkipped.relogin_command -ieq $skippedCommand -and
        @($run.summary.relogin_commands | Where-Object { $_.account_name -ceq 'acct-a' }).Count -eq 1 -and @($run.summary.skipped | Where-Object { $_.name -ceq 'acct-b' }).Count -eq 0 -and
        $none.error -match '^CodexAccountsAllUnavailable：' -and $none.error.Contains('acc-a:LoginFileMissing') -and $none.error.ToLowerInvariant().Contains(('重新登入：acc-a: ' + (FxLoginCommand -AccountHome $noneAccounts[0].codex_home)).ToLowerInvariant()) -and
        $none.error.ToLowerInvariant().Contains(('acc-b: ' + (FxLoginCommand -AccountHome $noneAccounts[1].codex_home)).ToLowerInvariant())
    }
    Test-Case X04 {
        # 登入命令函式：路徑含單引號以四個單引號跳脫，非絕對路徑與空值不輸出命令，輸出不含 auth.json。
        $quoted = Get-CodexAccountLoginCommand -CodexHome "C:\it's\home"
        $plain = Get-CodexAccountLoginCommand -CodexHome 'C:\plain\home'
        $null -ne $quoted -and $quoted.Contains("''C:\it''''s\home''") -and $plain -ceq (FxLoginCommand -AccountHome 'C:\plain\home') -and $null -eq (Get-CodexAccountLoginCommand -CodexHome 'relative\home') -and $null -eq (Get-CodexAccountLoginCommand -CodexHome '') -and -not $plain.Contains('auth.json')
    }

    # ---------- 衍生 Request 與 slug 改寫 ----------
    Test-Case D01 {
        $fixture = FxNewRequestFixture -Slug 'a'
        $derived = New-DispatchAttemptRequest -Document (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($fixture.request_path, [Text.Encoding]::UTF8))) -Attempt 2
        $derived.derivable -and $derived.dispatch_slug -ceq 'a-r2' -and $derived.dispatch_slug -cmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -and
        $derived.document.dispatch_root.Contains('worktrees\a-r2') -and $derived.document.source_root -ceq $fixture.root -and $derived.document.line_slug -ceq 'fx-line' -and $derived.document.prompt_path -ceq $fixture.prompt_path
    }
    Test-Case D02 {
        $document = [pscustomobject]@{ dispatch_slug = 'job'; dispatch_root = 'C:\w\job'; result_path = 'C:\h\result-job.json'; failure_receipt_path = 'C:\h\receipt-job.json'; unrelated = 'C:\w\job'; prepare_artifacts = @([pscustomobject]@{ destination = 'C:\w\job\x.md' }, [pscustomobject]@{ destination = 'C:\w\elsewhere\y.md' }) }
        $derived = New-DispatchAttemptRequest -Document $document -Attempt 3
        -not $derived.derivable -and $null -eq $derived.document -and (@($derived.missing_fields) -join ',') -ceq 'prepare_artifacts[1].destination' -and $document.dispatch_root -ceq 'C:\w\job'
    }
    Test-Case D03 {
        $replaced = Convert-DispatchSlugText -Text 'C:\data\job\scripts\dispatch-result-job-x.json' -OldSlug 'job' -NewSlug 'job-r2'
        $replaced -ceq 'C:\data\job-r2\scripts\dispatch-result-job-r2-x.json' -and -not (Test-DispatchSlugText -Text 'C:\data\jobless' -Slug 'job')
    }

    # ---------- 入口條件 ----------
    $entryRoot = FxNewDir -Name 'entry'
    $entryAccounts = FxAccounts -Root $entryRoot -Name @('e1', 'e2')
    $entryMachine = FxWriteMachine -Root $entryRoot -Account $entryAccounts
    $emptyMachineEntry = Join-Path $entryRoot 'empty.json'
    [IO.File]::WriteAllText($emptyMachineEntry, '{"schema":"ai-agents.machine.v1","codex_accounts":[]}', $utf8NoBom)
    Test-Case P01 {
        (Test-DispatchAccountFailoverApplicable -CodexHome '' -WaitForCompletion $true -SessionMode 'cold-start' -NoAccountFailover $false -MachineConfigPath $entryMachine) -and
        -not (Test-DispatchAccountFailoverApplicable -CodexHome $entryAccounts[0].codex_home -WaitForCompletion $true -SessionMode 'cold-start' -NoAccountFailover $false -MachineConfigPath $entryMachine) -and
        -not (Test-DispatchAccountFailoverApplicable -CodexHome '' -WaitForCompletion $false -SessionMode 'cold-start' -NoAccountFailover $false -MachineConfigPath $entryMachine) -and
        -not (Test-DispatchAccountFailoverApplicable -CodexHome '' -WaitForCompletion $true -SessionMode 'continuation' -NoAccountFailover $false -MachineConfigPath $entryMachine) -and
        -not (Test-DispatchAccountFailoverApplicable -CodexHome '' -WaitForCompletion $true -SessionMode 'cold-start' -NoAccountFailover $true -MachineConfigPath $entryMachine) -and
        -not (Test-DispatchAccountFailoverApplicable -CodexHome '' -WaitForCompletion $true -SessionMode 'cold-start' -NoAccountFailover $false -MachineConfigPath $emptyMachineEntry) -and
        -not (Test-DispatchAccountFailoverApplicable -CodexHome '' -WaitForCompletion $true -SessionMode 'cold-start' -NoAccountFailover $false -BoundParameter ([ordered]@{ TargetPath = @('a', 'b') }) -MachineConfigPath $entryMachine)
    }
    Test-Case P02 {
        $badMachine = Join-Path $entryRoot 'bad.json'
        [IO.File]::WriteAllText($badMachine, '{"schema":"ai-agents.machine.v1","codex_accounts":"invalid"}', $utf8NoBom)
        -not (Test-DispatchAccountFailoverApplicable -CodexHome '' -WaitForCompletion $true -SessionMode 'cold-start' -NoAccountFailover $false -MachineConfigPath $badMachine)
    }
    Test-Case P03 {
        $tokens = $null; $errors = $null
        $entryPath = Join-Path $scriptsRoot 'Invoke-CodexDispatch.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($entryPath, [ref]$tokens, [ref]$errors)
        $switchParam = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'NoAccountFailover' })
        $isSwitch = $switchParam.Count -eq 1 -and @($switchParam[0].StaticType.Name) -contains 'SwitchParameter'
        $switchAst = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.SwitchStatementAst] -and $node.Condition.Extent.Text -eq '$Operation' }, $true))
        $dispatchClause = $null
        foreach ($clause in $switchAst[0].Clauses) { if ($clause.Item1.Extent.Text -eq "'Dispatch'") { $dispatchClause = $clause.Item2 } }
        $text = $dispatchClause.Extent.Text
        $scopeText = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'dispatch\dispatch-scope.ps1'), [Text.Encoding]::UTF8)
        $isSwitch -and $errors.Count -eq 0 -and $text.Contains('Invoke-DispatchWithAccountFailover') -and $text.Contains('-NoAccountFailover:$NoAccountFailover') -and $scopeText -notmatch 'no_account_failover'
    }
    Test-Case P04 {
        # 入口 Dispatch 分支呼叫的 Invoke-DispatchWithAccountFailover：四種不換帳號的情形都只走單次 Dispatch，且不產生摘要檔。
        $fixture = FxNewRequestFixture -Slug 'fx-entry'
        $script:FxDispatchCalls = 0
        $script:FxFailoverCalls = 0
        function Invoke-Dispatch { $script:FxDispatchCalls++; return [ordered]@{ status = 'failed'; account_failover = [ordered]@{ eligible = $true; rejection_kind = 'model-not-supported'; item_event_count = 0 } } }
        function Invoke-DispatchAccountFailover { param($RequestPath, $Profile, $MachineConfigPath, $BoundParameter) $script:FxFailoverCalls++; return [ordered]@{ status = 'failed' } }
        $savedState = @{ CodexHome = (Get-DispatchScriptVariableValue -Name 'CodexHome'); SessionMode = (Get-DispatchScriptVariableValue -Name 'SessionMode'); Wait = (Get-DispatchScriptVariableValue -Name 'DispatchWaitForCompletion'); Bound = (Get-DispatchScriptVariableValue -Name 'InvocationBoundParameters'); RequestPath = (Get-DispatchScriptVariableValue -Name 'RequestPath'); Profile = (Get-DispatchScriptVariableValue -Name 'Profile') }
        try {
            $script:RequestPath = $fixture.request_path
            $script:Profile = 'scan'
            $script:InvocationBoundParameters = [ordered]@{}
            $summaryPath = Join-Path $fixture.history 'dispatch-account-failover-fx-entry.json'
            $situations = @(
                @{ home = $entryAccounts[0].codex_home; wait = $true; mode = 'cold-start'; skip = $false },
                @{ home = ''; wait = $false; mode = 'cold-start'; skip = $false },
                @{ home = ''; wait = $true; mode = 'continuation'; skip = $false },
                @{ home = ''; wait = $true; mode = 'cold-start'; skip = $true }
            )
            foreach ($situation in $situations) {
                $script:CodexHome = $situation.home
                $script:SessionMode = $situation.mode
                $script:DispatchWaitForCompletion = $situation.wait
                $script:FxDispatchCalls = 0; $script:FxFailoverCalls = 0
                $dispatched = Invoke-DispatchWithAccountFailover -NoAccountFailover:([bool]$situation.skip) -MachineConfigPath $entryMachine
                if ($script:FxDispatchCalls -ne 1 -or $script:FxFailoverCalls -ne 0 -or [string]$dispatched.status -cne 'failed' -or $dispatched.account_failover.eligible -ne $true -or (Test-Path -LiteralPath $summaryPath)) { throw ('入口條件未維持單次 Dispatch：' + (ConvertTo-Json -InputObject $situation -Compress)) }
            }
            $script:CodexHome = ''; $script:SessionMode = 'cold-start'; $script:DispatchWaitForCompletion = $true
            $script:FxDispatchCalls = 0; $script:FxFailoverCalls = 0
            $null = Invoke-DispatchWithAccountFailover -MachineConfigPath $entryMachine
            $script:FxFailoverCalls -eq 1 -and $script:FxDispatchCalls -eq 0
        }
        finally {
            $script:CodexHome = $savedState.CodexHome; $script:SessionMode = $savedState.SessionMode; $script:DispatchWaitForCompletion = $savedState.Wait
            $script:InvocationBoundParameters = $savedState.Bound; $script:RequestPath = $savedState.RequestPath; $script:Profile = $savedState.Profile
        }
    }

    # ---------- 陣列參數與換帳號外層 ----------
    function FxApplicable {
        param([System.Collections.IDictionary]$Bound, [object]$RequestDocument)
        return Test-DispatchAccountFailoverApplicable -CodexHome '' -WaitForCompletion $true -SessionMode 'cold-start' -NoAccountFailover $false -BoundParameter $Bound -RequestDocument $RequestDocument -MachineConfigPath $entryMachine
    }
    $arrayRequest = [pscustomobject]@{ target_path = @('a', 'b'); add_directory = @('d1'); codex_parent_option = @('o1', 'o2'); requested_unit = @('u1', 'u2') }
    Test-Case P05 {
        $fx = FxNewRequestFixture -Slug 'fx-p05'
        (FxApplicable -Bound ([ordered]@{ TargetPath = @('a', 'b') }) -RequestDocument $arrayRequest) -and (FxApplicable -Bound ([ordered]@{ TargetPath = @($fx.target_path) }) -RequestDocument $fx.document)
    }
    Test-Case P06 {
        (FxApplicable -Bound ([ordered]@{ AddDirectory = @('d1') }) -RequestDocument $arrayRequest) -and
        (FxApplicable -Bound ([ordered]@{ CodexParentOption = @('o1', 'o2') }) -RequestDocument $arrayRequest) -and
        (FxApplicable -Bound ([ordered]@{ RequestedUnit = @('u1', 'u2') }) -RequestDocument $arrayRequest) -and
        (FxApplicable -Bound ([ordered]@{ TargetPath = @('a', 'b'); AddDirectory = @('d1'); CodexParentOption = @('o1', 'o2'); RequestedUnit = @('u1', 'u2'); Search = [switch]$true; Profile = 'scan' }) -RequestDocument $arrayRequest)
    }
    Test-Case P07 {
        $partial = [pscustomobject]@{ target_path = @('a', 'b') }
        -not (FxApplicable -Bound ([ordered]@{ AddDirectory = @('d1') }) -RequestDocument $partial) -and -not (FxApplicable -Bound ([ordered]@{ RequestedUnit = @('u1') }) -RequestDocument $partial) -and
        -not (FxApplicable -Bound ([ordered]@{ TargetPath = @('a', 'b') }) -RequestDocument ([pscustomobject]@{ add_directory = @('d1') })) -and -not (FxApplicable -Bound ([ordered]@{ TargetPath = @('a', 'b') }) -RequestDocument $null)
    }
    Test-Case P08 {
        -not (FxApplicable -Bound ([ordered]@{ TargetPath = @('a', 'c') }) -RequestDocument $arrayRequest) -and -not (FxApplicable -Bound ([ordered]@{ TargetPath = @('a') }) -RequestDocument $arrayRequest) -and
        -not (FxApplicable -Bound ([ordered]@{ TargetPath = @('a', 'b'); AddDirectory = @('other') }) -RequestDocument $arrayRequest) -and -not (FxApplicable -Bound ([ordered]@{ TargetPath = @('A', 'B') }) -RequestDocument $arrayRequest) -and
        -not (FxApplicable -Bound ([ordered]@{ LiteralValues = @('x') }) -RequestDocument ([pscustomobject]@{ literal_values = @('x') })) -and
        -not (Test-DispatchAccountFailoverApplicable -CodexHome '' -WaitForCompletion $true -SessionMode 'cold-start' -NoAccountFailover $false -BoundParameter ([ordered]@{ TargetPath = @('a', 'b') }) -MachineConfigPath $entryMachine)
    }
    Test-Case P09 {
        # 入口 Invoke-DispatchWithAccountFailover：陣列綁定參數與 Request 一致時走換帳號外層，不一致時維持單次 Dispatch。
        $fixture = FxNewRequestFixture -Slug 'fx-array-entry'
        $script:FxDispatchCalls = 0
        $script:FxFailoverCalls = 0
        function Invoke-Dispatch { $script:FxDispatchCalls++; return [ordered]@{ status = 'failed' } }
        function Invoke-DispatchAccountFailover { param($RequestPath, $Profile, $MachineConfigPath, $BoundParameter) $script:FxFailoverCalls++; return [ordered]@{ status = 'failed' } }
        $savedState = @{ CodexHome = (Get-DispatchScriptVariableValue -Name 'CodexHome'); SessionMode = (Get-DispatchScriptVariableValue -Name 'SessionMode'); Wait = (Get-DispatchScriptVariableValue -Name 'DispatchWaitForCompletion'); Bound = (Get-DispatchScriptVariableValue -Name 'InvocationBoundParameters'); RequestPath = (Get-DispatchScriptVariableValue -Name 'RequestPath'); Profile = (Get-DispatchScriptVariableValue -Name 'Profile') }
        try {
            $script:RequestPath = $fixture.request_path
            $script:Profile = 'scan'
            $script:CodexHome = ''; $script:SessionMode = 'cold-start'; $script:DispatchWaitForCompletion = $true
            $script:InvocationBoundParameters = [ordered]@{ TargetPath = @($fixture.target_path); RequestedUnit = @($fixture.target_path) }
            $null = Invoke-DispatchWithAccountFailover -MachineConfigPath $entryMachine
            $matched = ($script:FxFailoverCalls -eq 1 -and $script:FxDispatchCalls -eq 0)
            $script:FxDispatchCalls = 0; $script:FxFailoverCalls = 0
            $script:InvocationBoundParameters = [ordered]@{ TargetPath = @($fixture.target_path, 'C:\other\extra.txt') }
            $null = Invoke-DispatchWithAccountFailover -MachineConfigPath $entryMachine
            $matched -and $script:FxFailoverCalls -eq 0 -and $script:FxDispatchCalls -eq 1
        }
        finally {
            $script:CodexHome = $savedState.CodexHome; $script:SessionMode = $savedState.SessionMode; $script:DispatchWaitForCompletion = $savedState.Wait
            $script:InvocationBoundParameters = $savedState.Bound; $script:RequestPath = $savedState.RequestPath; $script:Profile = $savedState.Profile
        }
    }
    Test-Case F21 {
        $fixture = FxNewRequestFixture -Slug 'fx-array-bound'
        $accounts = FxAccounts -Root $fixture.root -Name @('acct-a', 'acct-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $bound = [ordered]@{ TargetPath = @($fixture.target_path); RequestedUnit = @($fixture.target_path); Profile = 'scan' }
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acct-a' = 'reject:unauthorized'; 'acct-b' = 'completed' } -Bound $bound
        $script:FxAttemptLog.Count -eq 2 -and [string]$run.result.status -ceq 'completed' -and $script:FxAttemptLog[1].account -ceq 'acct-b'
    }
    Test-Case F22 {
        $fixture = FxNewRequestFixture -Slug 'fx-array-forward'
        $accounts = FxAccounts -Root $fixture.root -Name @('acct-a', 'acct-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $bound = [ordered]@{ TargetPath = @($fixture.target_path); RequestedUnit = @($fixture.target_path); AddDirectory = @('C:\fx\dir'); Profile = 'scan' }
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acct-a' = 'reject:unauthorized'; 'acct-b' = 'completed' } -Bound $bound
        $first = @($script:FxAttemptLog[0].forward)
        $second = @($script:FxAttemptLog[1].forward)
        $script:FxAttemptLog.Count -eq 2 -and $first -notcontains '-TargetPath' -and $second -notcontains '-TargetPath' -and $second -notcontains '-RequestedUnit' -and $second -notcontains '-AddDirectory' -and
        -not ($second -join '|').Contains($fixture.target_path) -and $second -contains '-Profile' -and $second -contains 'scan'
    }

    # ---------- model 不支援記憶（帳號健康狀態檔） ----------
    function FxHealthSetup {
        param([string]$Name, [string[]]$Account = @('h-a', 'h-b'))
        $root = FxNewDir -Name $Name
        $accounts = FxAccounts -Root $root -Name $Account
        $machine = FxWriteMachine -Root $root -Account $accounts
        return [pscustomobject]@{ root = $root; accounts = $accounts; machine = $machine; path = (Get-CodexAccountHealthPath -MachineConfigPath $machine) }
    }
    function FxRegisterHealth {
        param([object]$Setup, [int]$Index, [DateTimeOffset]$Now, [string]$Model = 'fixture-model')
        return Register-CodexAccountHealth -AccountName $Setup.accounts[$Index].name -CodexHome $Setup.accounts[$Index].codex_home -Profile 'scan' -Model $Model -ReasonCode 'model-not-supported' -Evidence ([ordered]@{ dispatch_slug = 'fx'; run_record_path = 'C:\fx\run.json'; event_stream_path = 'C:\fx\events.jsonl' }) -MachineConfigPath $Setup.machine -NowUtc $Now
    }
    $healthNow = [DateTimeOffset]::new(2026, 11, 10, 8, 0, 0, [TimeSpan]::Zero)
    Test-Case H01 {
        $setup = FxHealthSetup -Name 'h01'
        $null = FxRegisterHealth -Setup $setup -Index 0 -Now $healthNow
        $document = ConvertFrom-DispatchJson -Content ([IO.File]::ReadAllText($setup.path, [Text.Encoding]::UTF8))
        $entry = @($document.entries)[0]
        $recorded = [DateTimeOffset]::Parse([string]$entry.recorded_at_utc, [Globalization.CultureInfo]::InvariantCulture)
        $expires = [DateTimeOffset]::Parse([string]$entry.expires_at_utc, [Globalization.CultureInfo]::InvariantCulture)
        $bytes = [IO.File]::ReadAllBytes($setup.path)
        (Split-Path -Parent $setup.path) -ieq (Split-Path -Parent $setup.machine) -and (Split-Path -Leaf $setup.path) -ceq 'codex-account-health.json' -and $document.schema -ceq 'ai-agents.codex-account-health.v1' -and @($document.entries).Count -eq 1 -and
        $entry.account_name -ceq 'h-a' -and $entry.codex_home -ieq $setup.accounts[0].codex_home -and $entry.profile -ceq 'scan' -and $entry.model -ceq 'fixture-model' -and $entry.reason_code -ceq 'model-not-supported' -and
        ($expires - $recorded) -eq [TimeSpan]::FromHours(24) -and $recorded -eq $healthNow -and $entry.evidence.dispatch_slug -ceq 'fx' -and -not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
    }
    Test-Case H02 {
        $setup = FxHealthSetup -Name 'h02'
        $null = FxRegisterHealth -Setup $setup -Index 0 -Now $healthNow
        $set = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $setup.machine -NowUtc $healthNow.AddHours(1)
        $skipA = @($set.skipped | Where-Object { $_.name -ceq 'h-a' })[0]
        (@($set.candidates | ForEach-Object { $_.name }) -join ',') -ceq 'h-b' -and $skipA.reason_code -ceq 'ModelNotSupportedRecorded' -and $skipA.detail.Contains('fixture-model') -and $skipA.detail.Contains('前略過') -and $null -eq $skipA.config_path -and
        (Format-CodexAccountSkippedSummary -Skipped @($set.skipped)).Contains('h-a:ModelNotSupportedRecorded:' + $healthNow.AddHours(24).UtcDateTime.ToString('o'))
    }
    Test-Case H03 {
        $setup = FxHealthSetup -Name 'h03'
        $null = FxRegisterHealth -Setup $setup -Index 0 -Now $healthNow
        $before = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $setup.machine -NowUtc $healthNow.AddHours(24).AddSeconds(-1)
        $at = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $setup.machine -NowUtc $healthNow.AddHours(24)
        $after = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $setup.machine -NowUtc $healthNow.AddHours(24).AddSeconds(1)
        (@($before.candidates | ForEach-Object { $_.name }) -join ',') -ceq 'h-b' -and (@($at.candidates | ForEach-Object { $_.name }) -join ',') -ceq 'h-a,h-b' -and (@($after.candidates | ForEach-Object { $_.name }) -join ',') -ceq 'h-a,h-b' -and @($after.skipped).Count -eq 0
    }
    Test-Case H04 {
        $setup = FxHealthSetup -Name 'h04'
        $null = FxRegisterHealth -Setup $setup -Index 0 -Now $healthNow
        $null = FxRegisterHealth -Setup $setup -Index 1 -Now $healthNow.AddHours(-2)
        $set = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $setup.machine -NowUtc $healthNow.AddHours(1)
        $tied = FxHealthSetup -Name 'h04-tie'
        $null = FxRegisterHealth -Setup $tied -Index 0 -Now $healthNow
        $null = FxRegisterHealth -Setup $tied -Index 1 -Now $healthNow
        $tiedSet = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $tied.machine -NowUtc $healthNow.AddHours(1)
        @($set.candidates).Count -eq 1 -and $set.candidates[0].name -ceq 'h-b' -and $set.candidates[0].health_override -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$set.candidates[0].override_detail) -and
        @($set.skipped | Where-Object { $_.name -ceq 'h-b' }).Count -eq 0 -and @($set.skipped | Where-Object { $_.name -ceq 'h-a' }).Count -eq 1 -and
        @($tiedSet.candidates).Count -eq 1 -and $tiedSet.candidates[0].name -ceq 'h-a' -and
        @((Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath (FxHealthSetup -Name 'h04-none').machine).candidates | Where-Object { $null -ne $_.PSObject.Properties['health_override'] }).Count -eq 0
    }
    Test-Case H05 {
        $setup = FxHealthSetup -Name 'h05'
        $files = FxFailedTurnEvents -Name 'h05-model' -Message $modelMessage
        $evidence = Get-DispatchEventEvidence -EventPath $files.event -ErrorStreamPath $files.error -ProcessExitCode 1
        $failover = New-DispatchAccountFailoverEvidence -EventEvidence $evidence
        $record = [pscustomobject]@{ codex_account_name = 'h-a'; codex_home = $setup.accounts[0].codex_home; parent_options = [pscustomobject]@{ profile = 'scan' } }
        $update = Update-DispatchAccountHealthFromInspect -Record $record -EventEvidence $evidence -AccountFailover $failover -ProcessExitCode 1 -DispatchSlug 'h05' -RunRecordPath 'C:\fx\run.json' -EventStreamPath $files.event -MachineConfigPath $setup.machine -NowUtc $healthNow
        $stored = @((Read-CodexAccountHealth -MachineConfigPath $setup.machine -NowUtc $healthNow.AddHours(1)).entries)
        # 其他拒絕種類與已有 item 進度的失敗不記錄；寫入失敗只回傳 error，不丟例外。
        $other = FxFailedTurnEvents -Name 'h05-other' -Message '403 Forbidden'
        $otherEvidence = Get-DispatchEventEvidence -EventPath $other.event -ErrorStreamPath $other.error -ProcessExitCode 1
        $otherUpdate = Update-DispatchAccountHealthFromInspect -Record $record -EventEvidence $otherEvidence -AccountFailover (New-DispatchAccountFailoverEvidence -EventEvidence $otherEvidence) -ProcessExitCode 1 -MachineConfigPath $setup.machine -NowUtc $healthNow
        $blocker = Join-Path $setup.root 'blocker-file'
        [IO.File]::WriteAllText($blocker, 'x', $utf8NoBom)
        $failedUpdate = Update-DispatchAccountHealthFromInspect -Record $record -EventEvidence $evidence -AccountFailover $failover -ProcessExitCode 1 -MachineConfigPath (Join-Path $blocker 'sub\machine.json') -NowUtc $healthNow
        $inspectText = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'dispatch\inspect-lifecycle.ps1'), [Text.Encoding]::UTF8)
        $update.action -ceq 'registered' -and $null -eq $update.error -and $stored.Count -eq 1 -and $stored[0].account_name -ceq 'h-a' -and $stored[0].model -ceq 'fixture-model' -and $stored[0].profile -ceq 'scan' -and
        $otherUpdate.action -ceq 'none' -and @((Read-CodexAccountHealth -MachineConfigPath $setup.machine -NowUtc $healthNow.AddHours(1)).entries).Count -eq 1 -and
        $failedUpdate.action -ceq 'none' -and -not [string]::IsNullOrWhiteSpace([string]$failedUpdate.error) -and
        $inspectText.Contains('Update-DispatchAccountHealthFromInspect -Record $inspectRun.Record') -and $inspectText.Contains("health_record_error")
    }
    Test-Case H06 {
        $setup = FxHealthSetup -Name 'h06'
        $null = FxRegisterHealth -Setup $setup -Index 0 -Now $healthNow
        $null = FxRegisterHealth -Setup $setup -Index 1 -Now $healthNow
        $done = FxEvents -Directory $eventDir -Name 'h06-done' -Event @([ordered]@{ type = 'turn.started' }, [ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'agent_message'; text = 'ok' } }, [ordered]@{ type = 'turn.completed' })
        $evidence = Get-DispatchEventEvidence -EventPath $done.event -ErrorStreamPath $done.error -ProcessExitCode 0
        $failover = New-DispatchAccountFailoverEvidence -EventEvidence $evidence
        $record = [pscustomobject]@{ codex_account_name = 'h-a'; codex_home = $setup.accounts[0].codex_home; parent_options = [pscustomobject]@{ profile = 'scan' } }
        $nonZero = Update-DispatchAccountHealthFromInspect -Record $record -EventEvidence $evidence -AccountFailover $failover -ProcessExitCode 1 -MachineConfigPath $setup.machine -NowUtc $healthNow
        $afterNonZero = @((Read-CodexAccountHealth -MachineConfigPath $setup.machine -NowUtc $healthNow.AddHours(1)).entries).Count
        $update = Update-DispatchAccountHealthFromInspect -Record $record -EventEvidence $evidence -AccountFailover $failover -ProcessExitCode 0 -MachineConfigPath $setup.machine -NowUtc $healthNow
        $remaining = @((Read-CodexAccountHealth -MachineConfigPath $setup.machine -NowUtc $healthNow.AddHours(1)).entries)
        $nonZero.action -ceq 'none' -and $afterNonZero -eq 2 -and $update.action -ceq 'cleared' -and $remaining.Count -eq 1 -and $remaining[0].account_name -ceq 'h-b'
    }
    Test-Case H07 {
        # 記錄後再次派遣：被記錄的帳號不會啟動。
        $fixture = FxNewRequestFixture -Slug 'fx-health-skip'
        $accounts = FxAccounts -Root $fixture.root -Name @('acct-a', 'acct-b')
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        $null = Register-CodexAccountHealth -AccountName 'acct-a' -CodexHome $accounts[0].codex_home -Profile 'scan' -Model 'fixture-model' -ReasonCode 'model-not-supported' -MachineConfigPath $machine
        $run = FxRunFailover -Fixture $fixture -MachinePath $machine -Behavior @{ 'acct-a' = 'reject:model-not-supported'; 'acct-b' = 'completed' }
        $skippedSummary = @($run.summary.skipped | Where-Object { $_.name -ceq 'acct-a' })
        $script:FxAttemptLog.Count -eq 1 -and $script:FxAttemptLog[0].account -ceq 'acct-b' -and [string]$run.result.status -ceq 'completed' -and $skippedSummary.Count -eq 1 -and $skippedSummary[0].reason_code -ceq 'ModelNotSupportedRecorded' -and
        @($run.result.account_failover_summary.skipped | Where-Object { $_.reason_code -ceq 'ModelNotSupportedRecorded' }).Count -eq 1
    }
    Test-Case H08 {
        $setup = FxHealthSetup -Name 'h08'
        $null = Register-CodexAccountHealth -AccountName 'h-a' -CodexHome $setup.accounts[0].codex_home -Profile 'scan' -Model 'fixture-model' -ReasonCode 'model-not-supported' -MachineConfigPath $setup.machine
        $selection = Resolve-CodexAccountSelection -Profile 'scan' -MachineConfigPath $setup.machine
        $evidence = New-DispatchAccountSelectionEvidence -AccountSelection $selection
        $lifecycleText = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'dispatch\dispatch-lifecycle.ps1'), [Text.Encoding]::UTF8)
        $skip = @($evidence.skipped | Where-Object { $_.name -ceq 'h-a' })
        $evidence.mode -ceq 'auto' -and $evidence.account_name -ceq 'h-b' -and $skip.Count -eq 1 -and $skip[0].reason_code -ceq 'ModelNotSupportedRecorded' -and ([string]$skip[0].detail).Contains('fixture-model') -and
        $lifecycleText.Contains('$result.account_selection = New-DispatchAccountSelectionEvidence') -and $lifecycleText.Contains('$failureResult.account_selection = New-DispatchAccountSelectionEvidence')
    }
    Test-Case H09 {
        # 檔位改用其他 model 後，舊記錄的鍵不符而不生效。
        $setup = FxHealthSetup -Name 'h09'
        $null = FxRegisterHealth -Setup $setup -Index 0 -Now $healthNow
        $before = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $setup.machine -NowUtc $healthNow.AddHours(1)
        [IO.File]::WriteAllText((Join-Path $setup.accounts[0].codex_home 'scan.config.toml'), 'model = "another-model"', $utf8NoBom)
        $after = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $setup.machine -NowUtc $healthNow.AddHours(1)
        $otherProfile = Get-CodexDispatchAccountCandidates -Profile 'review' -MachineConfigPath $setup.machine -NowUtc $healthNow.AddHours(1)
        (@($before.candidates | ForEach-Object { $_.name }) -join ',') -ceq 'h-b' -and (@($after.candidates | ForEach-Object { $_.name }) -join ',') -ceq 'h-a,h-b' -and @($after.skipped).Count -eq 0 -and $otherProfile.candidates.Count -eq 0
    }
    Test-Case H10 {
        $setup = FxHealthSetup -Name 'h10'
        $garbage = 'this is { not json'
        [IO.File]::WriteAllText($setup.path, $garbage, $utf8NoBom)
        $read = Read-CodexAccountHealth -MachineConfigPath $setup.machine -NowUtc $healthNow
        $set = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $setup.machine -NowUtc $healthNow
        $unchanged = [IO.File]::ReadAllText($setup.path, [Text.Encoding]::UTF8) -ceq $garbage
        $schemaMismatch = FxHealthSetup -Name 'h10-schema'
        [IO.File]::WriteAllText($schemaMismatch.path, '{"schema":"other.v1","entries":[]}', $utf8NoBom)
        $mismatchRead = Read-CodexAccountHealth -MachineConfigPath $schemaMismatch.machine -NowUtc $healthNow
        $unparsableTime = FxHealthSetup -Name 'h10-time'
        $timeEntry = [ordered]@{ account_name = 'h-a'; codex_home = $unparsableTime.accounts[0].codex_home; profile = 'scan'; model = 'fixture-model'; reason_code = 'model-not-supported'; recorded_at_utc = 'not-a-time'; expires_at_utc = 'not-a-time' }
        [IO.File]::WriteAllText($unparsableTime.path, (ConvertTo-Json -InputObject ([ordered]@{ schema = 'ai-agents.codex-account-health.v1'; entries = @($timeEntry) }) -Depth 5), $utf8NoBom)
        $timeSet = Get-CodexDispatchAccountCandidates -Profile 'scan' -MachineConfigPath $unparsableTime.machine -NowUtc $healthNow
        # 損毀檔在寫入時先備份再以新內容替換。
        $null = FxRegisterHealth -Setup $setup -Index 0 -Now $healthNow
        $backups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $setup.path) -Filter 'codex-account-health.json.invalid-*' -File)
        $read.state_file_invalid -eq $true -and @($read.entries).Count -eq 0 -and (@($set.candidates | ForEach-Object { $_.name }) -join ',') -ceq 'h-a,h-b' -and $unchanged -and $mismatchRead.state_file_invalid -eq $true -and
        (@($timeSet.candidates | ForEach-Object { $_.name }) -join ',') -ceq 'h-a,h-b' -and $backups.Count -eq 1 -and [IO.File]::ReadAllText($backups[0].FullName, [Text.Encoding]::UTF8) -ceq $garbage -and @((Read-CodexAccountHealth -MachineConfigPath $setup.machine -NowUtc $healthNow.AddHours(1)).entries).Count -eq 1
    }
    Test-Case H11 {
        $setup = FxHealthSetup -Name 'h11'
        $null = Register-CodexAccountHealth -AccountName 'h-a' -CodexHome $setup.accounts[0].codex_home -Profile 'scan' -Model 'fixture-model' -ReasonCode 'model-not-supported' -MachineConfigPath $setup.machine
        $selected = Resolve-CodexAccountSelection -CodexHomePath $setup.accounts[0].codex_home -Profile 'scan' -MachineConfigPath $setup.machine
        $selected.Mode -ceq 'explicit' -and $selected.AccountName -ceq 'h-a' -and $selected.CodexHome -ieq $setup.accounts[0].codex_home
    }
    Test-Case H12 {
        $setup = FxHealthSetup -Name 'h12'
        $before = [IO.File]::ReadAllBytes($setup.machine)
        $null = FxRegisterHealth -Setup $setup -Index 0 -Now $healthNow
        $after = [IO.File]::ReadAllBytes($setup.machine)
        $accounts = @(Read-CodexAccountConfiguration -MachineConfigPath $setup.machine)
        $machineJson = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($setup.machine, [Text.Encoding]::UTF8))
        $before.Length -eq $after.Length -and (@(Compare-Object -ReferenceObject $before -DifferenceObject $after).Count -eq 0) -and $accounts.Count -eq 2 -and @($machineJson.codex_accounts | Where-Object { @($_.PSObject.Properties).Count -ne 2 }).Count -eq 0
    }
    Test-Case H13 {
        # 同鍵重寫只留一筆並刷新時間；寫入時移除已過期項目；Clear 對不符的鍵不寫檔。
        $setup = FxHealthSetup -Name 'h13'
        $null = FxRegisterHealth -Setup $setup -Index 0 -Now $healthNow
        $null = FxRegisterHealth -Setup $setup -Index 1 -Now $healthNow
        $null = FxRegisterHealth -Setup $setup -Index 0 -Now $healthNow.AddHours(10)
        $entries = @((Read-CodexAccountHealth -MachineConfigPath $setup.machine -NowUtc $healthNow.AddHours(11)).entries)
        $refreshed = @($entries | Where-Object { $_.account_name -ceq 'h-a' })[0]
        $null = FxRegisterHealth -Setup $setup -Index 0 -Now $healthNow.AddHours(30)
        $pruned = @((Read-CodexAccountHealth -MachineConfigPath $setup.machine -NowUtc $healthNow.AddHours(31)).entries)
        $bytesBefore = [IO.File]::ReadAllBytes($setup.path)
        $cleared = Clear-CodexAccountHealth -AccountName 'h-a' -CodexHome $setup.accounts[0].codex_home -Profile 'review' -Model 'fixture-model' -MachineConfigPath $setup.machine -NowUtc $healthNow.AddHours(31)
        $bytesAfter = [IO.File]::ReadAllBytes($setup.path)
        $entries.Count -eq 2 -and [DateTimeOffset]::Parse([string]$refreshed.recorded_at_utc, [Globalization.CultureInfo]::InvariantCulture) -eq $healthNow.AddHours(10) -and $pruned.Count -eq 1 -and $pruned[0].account_name -ceq 'h-a' -and
        -not $cleared -and $bytesBefore.Length -eq $bytesAfter.Length -and @(Compare-Object -ReferenceObject $bytesBefore -DifferenceObject $bytesAfter).Count -eq 0 -and -not (Clear-CodexAccountHealth -AccountName 'h-a' -CodexHome 'C:\none' -Profile 'scan' -Model $null -MachineConfigPath (Join-Path (FxNewDir -Name 'h13-empty') 'machine.json'))
    }

    # ---------- 背景模式換帳號（Inspect 綁定模式） ----------
    function FxNewBackgroundFixture {
        param([string]$Slug = 'fx-bg', [string[]]$Account = @('acct-a', 'acct-b', 'acct-c'), [string]$SessionMode = '')
        $fixture = FxNewRequestFixture -Slug $Slug
        $document = [ordered]@{}
        foreach ($key in $fixture.document.Keys) { $document[$key] = $fixture.document[$key] }
        $document.background = $true
        if (-not [string]::IsNullOrWhiteSpace($SessionMode)) { $document.session_mode = $SessionMode }
        [IO.File]::WriteAllText($fixture.request_path, ((ConvertTo-Json -InputObject $document -Depth 20) + "`n"), $utf8NoBom)
        $accounts = FxAccounts -Root $fixture.root -Name $Account
        $machine = FxWriteMachine -Root $fixture.root -Account $accounts
        FxEnsureTrust -MachinePath $machine -Root $fixture.root
        return [pscustomobject]@{ fixture = $fixture; accounts = $accounts; machine = $machine; slug = $Slug }
    }
    function FxNewBackgroundAttempt {
        # 為一次背景嘗試建立 Dispatch 結果文件與 RunRecord，回傳 Inspect 結果。
        param([object]$Background, [string]$Slug, [int]$AccountIndex, [string]$RequestPath, [string]$Kind = 'unclassified', [bool]$Eligible = $true, [bool]$IsBackground = $true, [bool]$Auto = $true, [object]$Handoff = $null, [bool]$WithBinding = $true, [string]$Mode = '')
        $fixture = $Background.fixture
        $account = $Background.accounts[$AccountIndex]
        $resultPath = Join-Path $fixture.history ('dispatch-result-' + $Slug + '.json')
        $resultDocument = [ordered]@{ schema = 'ai-sessions.dispatch-result.v1'; operation = 'Dispatch'; status = 'failed'; background = $IsBackground; dispatch_slug = $Slug; dispatch_root = (Join-Path $fixture.root ('.local\ai-sessions\worktrees\' + $Slug)) }
        if ($Auto) { $resultDocument.account_selection = [ordered]@{ mode = 'auto'; account_name = $account.name; skipped = @() } }
        # 背景鏈的衍生嘗試以顯式 CodexHome 啟動，Dispatch 結果記為 explicit 並帶帳號名稱（與 Resolve-CodexAccountSelection 的實際輸出同構）。
        if (-not [string]::IsNullOrWhiteSpace($Mode)) { $resultDocument.account_selection = [ordered]@{ mode = $Mode; account_name = $account.name; skipped = @() } }
        [IO.File]::WriteAllText($resultPath, (ConvertTo-Json -InputObject $resultDocument -Depth 10), $utf8NoBom)
        $runId = [guid]::NewGuid().ToString('D')
        $record = [pscustomobject]@{
            schema = 'ai-sessions.dispatch-run.v1'; run_id = $runId; dispatch_slug = $Slug; line_slug = $fixture.line; source_root = $fixture.root; execution_root = $fixture.root
            codex_account_name = $account.name; codex_home = $account.codex_home; request_path = $RequestPath; parent_options = [pscustomobject]@{ profile = 'scan' }; launch_state = 'started'
        }
        if ($null -ne $Handoff) { $record | Add-Member -MemberType NoteProperty -Name 'account_failover_handoff' -Value $Handoff }
        $recordPath = Write-DispatchRunRecord -Record $record
        $inspect = [ordered]@{ operation = 'Inspect'; runRecordPath = $recordPath; processExitCode = 1; account_failover = [ordered]@{ eligible = $Eligible; rejection_kind = $Kind; item_event_count = $(if ($Eligible) { 0 } else { 2 }) } }
        if ($WithBinding) { $inspect.dispatchResultPath = $resultPath }
        return $inspect
    }
    function FxBackgroundRecord {
        param([object]$Inspect)
        return ConvertFrom-DispatchJson -Content ([IO.File]::ReadAllText([string]$Inspect.runRecordPath, [Text.Encoding]::UTF8))
    }
    function FxBackgroundSummary {
        param([object]$Background, [string]$OriginSlug = '')
        if ([string]::IsNullOrWhiteSpace($OriginSlug)) { $OriginSlug = $Background.slug }
        $path = Join-Path $Background.fixture.history ('dispatch-account-failover-' + $OriginSlug + '.json')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        return ConvertFrom-DispatchJson -Content ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))
    }
    Test-Case B01 {
        $bg = FxNewBackgroundFixture -Slug 'fx-bg1'
        FxReset
        $script:FxBehavior['acct-b'] = 'started'
        $inspect = FxNewBackgroundAttempt -Background $bg -Slug 'fx-bg1' -AccountIndex 0 -RequestPath $bg.fixture.request_path
        $result = Invoke-InspectBackgroundAccountFailover -InspectResult $inspect -MachineConfigPath $bg.machine
        $started = $script:FxAttemptLog[0]
        $script:FxAttemptLog.Count -eq 1 -and $started.codex_home -ieq $bg.accounts[1].codex_home -and $started.slug -ceq 'fx-bg1-r2' -and $started.request_path -ieq (Join-Path $bg.fixture.history 'dispatch-request-fx-bg1-r2.json') -and
        $result.account_failover_handoff.state -ceq 'started' -and $result.account_failover_handoff.to_account -ceq 'acct-b' -and $result.account_failover_handoff.next_dispatch_slug -ceq 'fx-bg1-r2' -and (Test-Path -LiteralPath $result.account_failover_handoff.next_request_path -PathType Leaf)
    }
    Test-Case B02 {
        $bg = FxNewBackgroundFixture -Slug 'fx-bg2'
        FxReset
        $script:FxBehavior['acct-b'] = 'started'
        $inspect = FxNewBackgroundAttempt -Background $bg -Slug 'fx-bg2' -AccountIndex 0 -RequestPath $bg.fixture.request_path
        $null = Invoke-InspectBackgroundAccountFailover -InspectResult $inspect -MachineConfigPath $bg.machine
        $handoff = (FxBackgroundRecord -Inspect $inspect).account_failover_handoff
        $handoff.state -ceq 'started' -and $handoff.from_account -ceq 'acct-a' -and $handoff.to_account -ceq 'acct-b' -and $handoff.next_dispatch_slug -ceq 'fx-bg2-r2' -and $handoff.rejection_kind -ceq 'unclassified' -and -not [string]::IsNullOrWhiteSpace([string]$handoff.handed_off_at_utc) -and
        -not [string]::IsNullOrWhiteSpace([string]$handoff.next_request_path) -and -not [string]::IsNullOrWhiteSpace([string]$handoff.summary_path)
    }
    Test-Case B03 {
        $bg = FxNewBackgroundFixture -Slug 'fx-bg3'
        FxReset
        $script:FxBehavior['acct-b'] = 'started'
        $inspect = FxNewBackgroundAttempt -Background $bg -Slug 'fx-bg3' -AccountIndex 0 -RequestPath $bg.fixture.request_path
        $null = Invoke-InspectBackgroundAccountFailover -InspectResult $inspect -MachineConfigPath $bg.machine
        $summary = FxBackgroundSummary -Background $bg
        $summary.schema -ceq 'ai-sessions.dispatch-account-failover.v1' -and $summary.mode -ceq 'background' -and $summary.dispatch_slug -ceq 'fx-bg3' -and @($summary.attempts).Count -eq 2 -and
        $summary.attempts[0].account_name -ceq 'acct-a' -and $summary.attempts[0].outcome -ceq 'rejected' -and $summary.attempts[0].rejection_kind -ceq 'unclassified' -and $summary.attempts[1].account_name -ceq 'acct-b' -and $summary.attempts[1].outcome -ceq 'started' -and $summary.attempts[1].dispatch_slug -ceq 'fx-bg3-r2' -and
        [int]$summary.final_attempt -eq 2 -and -not [bool]$summary.all_unavailable
    }
    Test-Case B04 {
        # 啟動後再被拒：第二次 Inspect 鏈到下一個帳號，已嘗試帳號不重複。
        $bg = FxNewBackgroundFixture -Slug 'fx-bg4'
        FxReset
        $script:FxBehavior['acct-b'] = 'started'
        $script:FxBehavior['acct-c'] = 'started'
        $first = FxNewBackgroundAttempt -Background $bg -Slug 'fx-bg4' -AccountIndex 0 -RequestPath $bg.fixture.request_path
        $firstResult = Invoke-InspectBackgroundAccountFailover -InspectResult $first -MachineConfigPath $bg.machine
        $second = FxNewBackgroundAttempt -Background $bg -Slug 'fx-bg4-r2' -AccountIndex 1 -RequestPath $firstResult.account_failover_handoff.next_request_path -Kind 'rate-limited' -Mode 'explicit'
        $secondResult = Invoke-InspectBackgroundAccountFailover -InspectResult $second -MachineConfigPath $bg.machine
        $summary = FxBackgroundSummary -Background $bg
        $names = @($summary.attempts | ForEach-Object { $_.account_name })
        $script:FxAttemptLog.Count -eq 2 -and $script:FxAttemptLog[1].codex_home -ieq $bg.accounts[2].codex_home -and $script:FxAttemptLog[1].slug -ceq 'fx-bg4-r3' -and $secondResult.account_failover_handoff.state -ceq 'started' -and $secondResult.account_failover_handoff.to_account -ceq 'acct-c' -and
        @($names | Select-Object -Unique).Count -eq 3 -and ($names -join ',') -ceq 'acct-a,acct-b,acct-c' -and $summary.attempts[1].outcome -ceq 'rejected' -and $summary.attempts[1].rejection_kind -ceq 'rate-limited' -and $summary.attempts[2].outcome -ceq 'started' -and
        -not (Test-Path -LiteralPath (Join-Path $bg.fixture.history 'dispatch-account-failover-fx-bg4-r2.json'))
    }
    Test-Case B05 {
        $bg = FxNewBackgroundFixture -Slug 'fx-bg5' -Account @('acct-a', 'acct-b')
        FxReset
        $script:FxBehavior['acct-b'] = 'started'
        $first = FxNewBackgroundAttempt -Background $bg -Slug 'fx-bg5' -AccountIndex 0 -RequestPath $bg.fixture.request_path
        $firstResult = Invoke-InspectBackgroundAccountFailover -InspectResult $first -MachineConfigPath $bg.machine
        $second = FxNewBackgroundAttempt -Background $bg -Slug 'fx-bg5-r2' -AccountIndex 1 -RequestPath $firstResult.account_failover_handoff.next_request_path -Mode 'explicit'
        $secondResult = Invoke-InspectBackgroundAccountFailover -InspectResult $second -MachineConfigPath $bg.machine
        $summary = FxBackgroundSummary -Background $bg
        $script:FxAttemptLog.Count -eq 1 -and $secondResult.account_failover_handoff.state -ceq 'exhausted' -and [string]$secondResult.error_code -ceq 'CodexAccountsAllUnavailable' -and [bool]$summary.all_unavailable -and
        (FxBackgroundRecord -Inspect $second).account_failover_handoff.state -ceq 'exhausted'
    }
    Test-Case B06 {
        $bg = FxNewBackgroundFixture -Slug 'fx-bg6'
        FxReset
        $script:FxBehavior['acct-b'] = 'started'
        $inspect = FxNewBackgroundAttempt -Background $bg -Slug 'fx-bg6' -AccountIndex 0 -RequestPath $bg.fixture.request_path -Kind 'unauthorized'
        $result = Invoke-InspectBackgroundAccountFailover -InspectResult $inspect -MachineConfigPath $bg.machine
        $expected = FxLoginCommand -AccountHome $bg.accounts[0].codex_home
        $summary = FxBackgroundSummary -Background $bg
        $result.account_failover_handoff.relogin_command -ieq $expected -and (FxBackgroundRecord -Inspect $inspect).account_failover_handoff.relogin_command -ieq $expected -and $summary.attempts[0].relogin_command -ieq $expected -and @($summary.relogin_commands).Count -eq 1
    }
    Test-Case B07 {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsRoot 'Invoke-CodexDispatch.ps1'), [ref]$tokens, [ref]$errors)
        $switchAst = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.SwitchStatementAst] -and $node.Condition.Extent.Text -eq '$Operation' }, $true))
        $inspectClause = $null
        foreach ($clause in $switchAst[0].Clauses) { if ($clause.Item1.Extent.Text -eq "'Inspect'") { $inspectClause = $clause.Item2 } }
        $dispatchClause = $null
        foreach ($clause in $switchAst[0].Clauses) { if ($clause.Item1.Extent.Text -eq "'Dispatch'") { $dispatchClause = $clause.Item2 } }
        $lifecycleText = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'dispatch\dispatch-lifecycle.ps1'), [Text.Encoding]::UTF8)
        $ast2 = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsRoot 'dispatch\dispatch-lifecycle.ps1'), [ref]$tokens, [ref]$errors)
        $dispatchFunction = @($ast2.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Dispatch' }, $true))[0]
        $errors.Count -eq 0 -and $inspectClause.Extent.Text.Contains('Invoke-InspectBackgroundAccountFailover') -and $inspectClause.Extent.Text.Contains('-NoAccountFailover:$NoAccountFailover') -and $inspectClause.Extent.Text.Contains('Invoke-Inspect') -and
        -not $dispatchClause.Extent.Text.Contains('Invoke-InspectBackgroundAccountFailover') -and -not $dispatchFunction.Body.Extent.Text.Contains('Invoke-InspectBackgroundAccountFailover')
    }
    Test-Case B08 {
        # 去重：同一個被拒嘗試連續兩次 Inspect，只啟動一次，第二次回報 already-handed-off。
        $bg = FxNewBackgroundFixture -Slug 'fx-bg8'
        FxReset
        $script:FxBehavior['acct-b'] = 'started'
        $inspect = FxNewBackgroundAttempt -Background $bg -Slug 'fx-bg8' -AccountIndex 0 -RequestPath $bg.fixture.request_path
        $first = Invoke-InspectBackgroundAccountFailover -InspectResult $inspect -MachineConfigPath $bg.machine
        $again = [ordered]@{ operation = 'Inspect'; runRecordPath = $inspect.runRecordPath; dispatchResultPath = $inspect.dispatchResultPath; account_failover = [ordered]@{ eligible = $true; rejection_kind = 'unclassified'; item_event_count = 0 } }
        $second = Invoke-InspectBackgroundAccountFailover -InspectResult $again -MachineConfigPath $bg.machine
        $script:FxAttemptLog.Count -eq 1 -and $first.account_failover_handoff.state -ceq 'started' -and $second.account_failover_handoff.state -ceq 'already-handed-off' -and $second.account_failover_handoff.next_dispatch_slug -ceq 'fx-bg8-r2' -and @((FxBackgroundSummary -Background $bg).attempts).Count -eq 2
    }
    Test-Case B09 {
        $scenarios = @(
            @{ name = 'no-account-failover'; noFailover = $true },
            @{ name = 'explicit-home'; auto = $false },
            @{ name = 'foreground'; background = $false },
            @{ name = 'item-progress'; eligible = $false },
            @{ name = 'continuation'; sessionMode = 'continuation' }
        )
        $index = 0
        foreach ($scenario in $scenarios) {
            $index++
            $sessionMode = if ($scenario.ContainsKey('sessionMode')) { [string]$scenario.sessionMode } else { '' }
            $bg = FxNewBackgroundFixture -Slug ('fx-bg9-' + $index) -SessionMode $sessionMode
            FxReset
            $auto = if ($scenario.ContainsKey('auto')) { [bool]$scenario.auto } else { $true }
            $background = if ($scenario.ContainsKey('background')) { [bool]$scenario.background } else { $true }
            $eligible = if ($scenario.ContainsKey('eligible')) { [bool]$scenario.eligible } else { $true }
            $noFailover = $scenario.ContainsKey('noFailover')
            $inspect = FxNewBackgroundAttempt -Background $bg -Slug ('fx-bg9-' + $index) -AccountIndex 0 -RequestPath $bg.fixture.request_path -Eligible $eligible -IsBackground $background -Auto $auto
            $result = Invoke-InspectBackgroundAccountFailover -InspectResult $inspect -NoAccountFailover:$noFailover -MachineConfigPath $bg.machine
            if ($result.account_failover_handoff.state -cne 'not-applicable' -or $script:FxAttemptLog.Count -ne 0 -or $null -ne (FxBackgroundSummary -Background $bg -OriginSlug ('fx-bg9-' + $index)) -or $null -ne (FxBackgroundRecord -Inspect $inspect).PSObject.Properties['account_failover_handoff']) { throw ('應為 not-applicable 且未啟動：' + $scenario.name + '；state=' + $result.account_failover_handoff.state) }
        }
        $true
    }
    Test-Case B10 {
        $bg = FxNewBackgroundFixture -Slug 'fx-bg10'
        FxReset
        $inspect = FxNewBackgroundAttempt -Background $bg -Slug 'fx-bg10' -AccountIndex 0 -RequestPath $bg.fixture.request_path -WithBinding $false
        $result = Invoke-InspectBackgroundAccountFailover -InspectResult $inspect -MachineConfigPath $bg.machine
        $result.account_failover_handoff.state -ceq 'not-applicable' -and $result.account_failover_handoff.reason -ceq 'no-dispatch-result-binding' -and $script:FxAttemptLog.Count -eq 0
    }
    Test-Case B11 {
        # claimed 但沒有 started（行程在寫入之間中斷）：回報 handoff-incomplete，不自動重啟。
        $bg = FxNewBackgroundFixture -Slug 'fx-bg11'
        FxReset
        $claimed = [pscustomobject]@{ state = 'claimed'; from_account = 'acct-a'; to_account = 'acct-b'; next_dispatch_slug = 'fx-bg11-r2'; next_request_path = (Join-Path $bg.fixture.history 'dispatch-request-fx-bg11-r2.json') }
        $inspect = FxNewBackgroundAttempt -Background $bg -Slug 'fx-bg11' -AccountIndex 0 -RequestPath $bg.fixture.request_path -Handoff $claimed
        $result = Invoke-InspectBackgroundAccountFailover -InspectResult $inspect -MachineConfigPath $bg.machine
        $result.account_failover_handoff.state -ceq 'handoff-incomplete' -and $result.account_failover_handoff.next_request_path -ieq $claimed.next_request_path -and $script:FxAttemptLog.Count -eq 0
    }
    Test-Case B12 {
        # 啟動失敗：記錄 launch-failed，不重試同一帳號，也不自動再換第三個帳號。
        $bg = FxNewBackgroundFixture -Slug 'fx-bg12'
        FxReset
        $script:FxBehavior['acct-b'] = 'launch-fail'
        $inspect = FxNewBackgroundAttempt -Background $bg -Slug 'fx-bg12' -AccountIndex 0 -RequestPath $bg.fixture.request_path
        $result = Invoke-InspectBackgroundAccountFailover -InspectResult $inspect -MachineConfigPath $bg.machine
        $again = [ordered]@{ operation = 'Inspect'; runRecordPath = $inspect.runRecordPath; dispatchResultPath = $inspect.dispatchResultPath; account_failover = [ordered]@{ eligible = $true; rejection_kind = 'unclassified'; item_event_count = 0 } }
        $second = Invoke-InspectBackgroundAccountFailover -InspectResult $again -MachineConfigPath $bg.machine
        $script:FxAttemptLog.Count -eq 1 -and $result.account_failover_handoff.state -ceq 'launch-failed' -and $result.account_failover_handoff.error.Contains('fixture launch failure') -and $second.account_failover_handoff.state -ceq 'launch-failed' -and (FxBackgroundSummary -Background $bg).attempts[1].outcome -ceq 'launch-failed'
    }
    Test-Case B13 {
        # 衍生 Request 已存在（併發的另一個 Inspect 已宣告）：不重複啟動。
        $bg = FxNewBackgroundFixture -Slug 'fx-bg13'
        FxReset
        $collidingPath = Join-Path $bg.fixture.history 'dispatch-request-fx-bg13-r2.json'
        [IO.File]::WriteAllText($collidingPath, '{}', $utf8NoBom)
        $inspect = FxNewBackgroundAttempt -Background $bg -Slug 'fx-bg13' -AccountIndex 0 -RequestPath $bg.fixture.request_path
        $result = Invoke-InspectBackgroundAccountFailover -InspectResult $inspect -MachineConfigPath $bg.machine
        $result.account_failover_handoff.state -ceq 'handoff-incomplete' -and $script:FxAttemptLog.Count -eq 0 -and [IO.File]::ReadAllText($collidingPath) -ceq '{}'
    }
    Test-Case B15 {
        # 三個帳號鏈到耗盡：第二、第三次拒絕的結果皆為 explicit（背景鏈以顯式 CodexHome 啟動），第三次被拒時回報 exhausted 與 CodexAccountsAllUnavailable。
        $bg = FxNewBackgroundFixture -Slug 'fx-bg15'
        FxReset
        $script:FxBehavior['acct-b'] = 'started'
        $script:FxBehavior['acct-c'] = 'started'
        $first = FxNewBackgroundAttempt -Background $bg -Slug 'fx-bg15' -AccountIndex 0 -RequestPath $bg.fixture.request_path
        $firstResult = Invoke-InspectBackgroundAccountFailover -InspectResult $first -MachineConfigPath $bg.machine
        $second = FxNewBackgroundAttempt -Background $bg -Slug 'fx-bg15-r2' -AccountIndex 1 -RequestPath $firstResult.account_failover_handoff.next_request_path -Mode 'explicit'
        $secondResult = Invoke-InspectBackgroundAccountFailover -InspectResult $second -MachineConfigPath $bg.machine
        $third = FxNewBackgroundAttempt -Background $bg -Slug 'fx-bg15-r3' -AccountIndex 2 -RequestPath $secondResult.account_failover_handoff.next_request_path -Mode 'explicit'
        $thirdResult = Invoke-InspectBackgroundAccountFailover -InspectResult $third -MachineConfigPath $bg.machine
        $summary = FxBackgroundSummary -Background $bg
        $script:FxAttemptLog.Count -eq 2 -and $secondResult.account_failover_handoff.state -ceq 'started' -and $secondResult.account_failover_handoff.to_account -ceq 'acct-c' -and
        $thirdResult.account_failover_handoff.state -ceq 'exhausted' -and [string]$thirdResult.error_code -ceq 'CodexAccountsAllUnavailable' -and [bool]$summary.all_unavailable -and @($summary.attempts).Count -eq 3 -and
        (FxBackgroundRecord -Inspect $third).account_failover_handoff.state -ceq 'exhausted'
    }
    Test-Case B16 {
        # 負向：使用者自行指定 -CodexHome 的背景派遣（mode=explicit，背景摘要檔沒有記錄該 slug）被拒時不換帳號；
        # 鏈的 slug 但帳號與摘要不符、或沒有背景摘要檔時同樣不換。
        $scenarios = @(
            @{ name = 'user-explicit'; slug = 'fx-bg16a'; resultSlug = 'fx-bg16a'; accountIndex = 0 },
            @{ name = 'chain-slug-without-summary'; slug = 'fx-bg16b'; resultSlug = 'fx-bg16b-r2'; accountIndex = 1 },
            @{ name = 'chain-account-mismatch'; slug = 'fx-bg16c'; resultSlug = 'fx-bg16c-r2'; accountIndex = 2; withSummary = $true }
        )
        foreach ($scenario in $scenarios) {
            $bg = FxNewBackgroundFixture -Slug $scenario.slug
            FxReset
            $script:FxBehavior['acct-b'] = 'started'
            if ($scenario.ContainsKey('withSummary')) {
                $first = FxNewBackgroundAttempt -Background $bg -Slug $scenario.slug -AccountIndex 0 -RequestPath $bg.fixture.request_path
                $null = Invoke-InspectBackgroundAccountFailover -InspectResult $first -MachineConfigPath $bg.machine
                $script:FxAttemptLog.Clear()
            }
            $inspect = FxNewBackgroundAttempt -Background $bg -Slug $scenario.resultSlug -AccountIndex $scenario.accountIndex -RequestPath $bg.fixture.request_path -Mode 'explicit'
            $result = Invoke-InspectBackgroundAccountFailover -InspectResult $inspect -MachineConfigPath $bg.machine
            if ($result.account_failover_handoff.state -cne 'not-applicable' -or $result.account_failover_handoff.reason -cne 'explicit-codex-home' -or $script:FxAttemptLog.Count -ne 0 -or $null -ne (FxBackgroundRecord -Inspect $inspect).PSObject.Properties['account_failover_handoff']) {
                throw ('應為 not-applicable／explicit-codex-home 且未啟動：' + $scenario.name + '；state=' + $result.account_failover_handoff.state + '；reason=' + $result.account_failover_handoff.reason)
            }
        }
        $true
    }
    Test-Case B14 {
        # 動態探針：實際以 Invoke-CodexDispatch.ps1 -Operation Inspect 單發，輸出含 account_failover_handoff。
        # 腳本與模組複製到暫存目錄，在複本的最後載入模組附加 Invoke-Inspect 替身（回傳被拒的背景嘗試），
        # 其餘（入口 switch、Invoke-InspectBackgroundAccountFailover、候選與 Request 衍生、子程序啟動）走實際程式碼。
        # 下一帳號的子程序以不屬於 git repo 的假來源啟動，會在啟動 Codex 前失敗，不會呼叫真實 Codex。
        $bg = FxNewBackgroundFixture -Slug 'fx-bg14' -Account @('acct-a', 'acct-b')
        $probeRoot = FxNewDir -Name 'bg-probe'
        $scriptsCopy = Join-Path $probeRoot 'scripts'
        $null = New-Item -ItemType Directory -Path $scriptsCopy -Force
        Copy-Item -LiteralPath (Join-Path $scriptsRoot 'dispatch') -Destination (Join-Path $scriptsCopy 'dispatch') -Recurse
        Copy-Item -LiteralPath (Join-Path $scriptsRoot 'Invoke-CodexDispatch.ps1') -Destination $scriptsCopy
        $null = New-Item -ItemType Directory -Path (Join-Path $probeRoot '.local') -Force
        Copy-Item -LiteralPath $bg.machine -Destination (Join-Path $probeRoot '.local\machine.json')
        $inspect = FxNewBackgroundAttempt -Background $bg -Slug 'fx-bg14' -AccountIndex 0 -RequestPath $bg.fixture.request_path
        $stub = "`r`nfunction Invoke-Inspect { return [ordered]@{ operation = 'Inspect'; runRecordPath = '" + ([string]$inspect.runRecordPath).Replace("'", "''") + "'; dispatchResultPath = '" + ([string]$inspect.dispatchResultPath).Replace("'", "''") + "'; processExitCode = 1; account_failover = [ordered]@{ eligible = `$true; rejection_kind = 'unclassified'; item_event_count = 0 } } }`r`n"
        $cleanupCopy = Join-Path $scriptsCopy 'dispatch\cleanup.ps1'
        [IO.File]::AppendAllText($cleanupCopy, $stub, (New-Object Text.UTF8Encoding($true)))
        $hostPath = (Get-Process -Id $PID).Path
        $output = (& $hostPath -NoProfile -NonInteractive -File (Join-Path $scriptsCopy 'Invoke-CodexDispatch.ps1') -Operation Inspect -DispatchResultPath ([string]$inspect.dispatchResultPath) 2>$null | Out-String)
        $firstBrace = $output.IndexOf('{')
        $lastBrace = $output.LastIndexOf('}')
        $parsed = $null
        if ($firstBrace -ge 0 -and $lastBrace -gt $firstBrace) { $parsed = ConvertFrom-DispatchJson -Content $output.Substring($firstBrace, $lastBrace - $firstBrace + 1) }
        $null -ne $parsed -and $null -ne $parsed.PSObject.Properties['account_failover_handoff'] -and $parsed.account_failover_handoff.to_account -ceq 'acct-b' -and $parsed.account_failover_handoff.state -cin @('started', 'launch-failed') -and
        $parsed.account_failover_handoff.next_dispatch_slug -ceq 'fx-bg14-r2' -and (Test-Path -LiteralPath $parsed.account_failover_handoff.next_request_path -PathType Leaf)
    }

    # ---------- 真實子程序執行器 ----------
    Test-Case R01 {
        $fakeRoot = FxNewDir -Name 'fake entry'
        $fakeEntry = Join-Path $fakeRoot 'Invoke-CodexDispatch.ps1'
        $fakeText = @'
param([string]$Operation, [string]$RequestPath, [string]$CodexHome, [switch]$NoAccountFailover, [string]$Extra, [string]$Mode)
$status = if ($Mode -eq 'fail') { 'failed' } else { 'completed' }
Write-Output 'noise before json'
Write-Output (ConvertTo-Json -InputObject ([ordered]@{ operation = $Operation; request = $RequestPath; codex_home = $CodexHome; no_failover = [bool]$NoAccountFailover; extra = $Extra; status = $status; result_path = $null }) -Depth 5)
if ($status -eq 'failed') { exit 1 }
exit 0
'@
        [IO.File]::WriteAllText($fakeEntry, $fakeText, $utf8NoBom)
        $previousRoot = $script:DispatchEntryScriptRoot
        $script:DispatchEntryScriptRoot = $fakeRoot
        try {
            $ok = & $realAttemptProcess -RequestPath (Join-Path $fakeRoot 'req with space.json') -CodexHome (Join-Path $fakeRoot 'home dir') -ForwardArgument @('-Extra', 'a "quoted" value')
            $failed = & $realAttemptProcess -RequestPath (Join-Path $fakeRoot 'r.json') -CodexHome (Join-Path $fakeRoot 'h') -ForwardArgument @('-Mode', 'fail')
        }
        finally { $script:DispatchEntryScriptRoot = $previousRoot }
        $ok.exit_code -eq 0 -and $ok.result.status -ceq 'completed' -and $ok.result.no_failover -eq $true -and $ok.result.operation -ceq 'Dispatch' -and $ok.result.request -ceq (Join-Path $fakeRoot 'req with space.json') -and
        $ok.result.codex_home -ceq (Join-Path $fakeRoot 'home dir') -and $ok.result.extra -ceq 'a "quoted" value' -and $failed.exit_code -eq 1 -and $failed.result.status -ceq 'failed'
    }

    # ---------- 非 Git 唯讀派遣代寫報告（路徑守衛） ----------
    Test-Case W01 {
        # 第 7 欄指向 tracked 檔案時被 Resolve-DispatchOutputPath 拒絕，保留守衛的錯誤碼，檔案內容不變。
        $root = FxNewDir -Name 'w01-repo'
        $trackedFile = Join-Path $root 'tracked-report.md'
        [IO.File]::WriteAllText($trackedFile, 'tracked original', $utf8NoBom)
        & git -C $root init --quiet 2>&1 | Out-Null
        & git -C $root add tracked-report.md 2>&1 | Out-Null
        & git -C $root -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit --quiet -m fixture 2>&1 | Out-Null
        $preflight = Join-Path $root 'preflight.json'
        [IO.File]::WriteAllText($preflight, '{"gitOrigin":"not-applicable"}', $utf8NoBom)
        $record = [pscustomobject]@{ source_root = $root; execution_root = $root; preflight_result_path = $preflight }
        $tracked = Write-DispatchNonGitReadonlyReport -TaskType 'script-change' -WriteMode 'readonly' -RunRecord $record -ReportPath @($trackedFile) -FinalMessage 'changed' -SecretExposureSuspected $false -SourceRoot $root -ExecutionRoot $root
        $fresh = Write-DispatchNonGitReadonlyReport -TaskType 'script-change' -WriteMode 'readonly' -RunRecord $record -ReportPath @((Join-Path $root 'fresh-report.md')) -FinalMessage 'fresh' -SecretExposureSuspected $false -SourceRoot $root -ExecutionRoot $root
        $tracked.status -ceq 'skipped' -and $tracked.reason -ceq 'DispatchOutputTrackedTarget' -and [IO.File]::ReadAllText($trackedFile, [Text.Encoding]::UTF8) -ceq 'tracked original' -and $fresh.status -ceq 'written' -and [IO.File]::ReadAllText((Join-Path $root 'fresh-report.md'), [Text.Encoding]::UTF8) -ceq 'fresh'
    }

    # ---------- admission 釋放 ----------
    Test-Case M01 {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = (Get-Process -Id $PID).Path
        $startInfo.Arguments = '-NoProfile -Command exit 0'
        $startInfo.UseShellExecute = $false
        $child = [Diagnostics.Process]::Start($startInfo)
        $name = $child.ProcessName
        $startTime = $child.StartTime.ToUniversalTime().ToString('o')
        $childId = $child.Id
        $child.WaitForExit()
        $entry = [pscustomobject]@{ caller_session_fingerprint = 'fx-caller'; process_id = $childId; process_name = $name; process_start_time_utc = $startTime; line_slug = 'fx-line'; dispatch_slug = 'fx-first'; write_mode = 'write'; write_paths = @(); state = 'active' }
        $ledger = [pscustomobject]@{ Path = (Join-Path $tempRoot 'admission\ledger.json'); Document = [pscustomobject]@{ entries = @($entry) } }
        $before = FxThrows { Assert-DispatchAdmissionAllowed -Ledger $ledger -CallerSessionFingerprint 'fx-caller' -LineSlug 'fx-line' -DispatchSlug 'fx-first-r2' -WriteMode 'write' -WritePaths @() }
        $changed = Update-DispatchAdmissionOwnerStates -Ledger $ledger
        $after = FxThrows { Assert-DispatchAdmissionAllowed -Ledger $ledger -CallerSessionFingerprint 'fx-caller' -LineSlug 'fx-line' -DispatchSlug 'fx-first-r2' -WriteMode 'write' -WritePaths @() }
        $before -match 'DispatchAdmissionWriteLimit' -and $changed -and $entry.state -ceq 'finished' -and $null -eq $after
    }

    # ---------- 檔案編碼與來源掃描 ----------
    Test-Case X01 {
        $files = @('scripts\Invoke-CodexDispatch.ps1', 'scripts\dispatch\dispatch-evidence.ps1', 'scripts\dispatch\run-recovery.ps1', 'scripts\dispatch\dispatch-lifecycle.ps1', 'scripts\dispatch\inspect-lifecycle.ps1', 'scripts\dispatch\prepare-stage.ps1', 'scripts\tests\Test-DispatchAccountFailover.ps1', 'scripts\tests\Test-DispatchRecoveryBinding.ps1')
        $repoRoot = Split-Path -Parent $scriptsRoot
        foreach ($relative in $files) {
            $path = Join-Path $repoRoot $relative
            $bytes = [IO.File]::ReadAllBytes($path)
            if (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) { throw ($relative + ' 不是 UTF-8 with BOM。') }
            $tokens = $null; $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            if ($errors.Count -gt 0) { throw ($relative + ' 無法解析：' + $errors[0].Message) }
        }
        $true
    }
    Test-Case X02 {
        $production = @(Get-ChildItem -LiteralPath $scriptsRoot -Filter '*.ps1' -File -Recurse | Where-Object { $_.FullName -notmatch '\\tests\\' })
        $cacheHits = @($production | Where-Object { [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) -match 'models_cache' })
        $loginHits = @($production | Where-Object { [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) -match 'auth\.json' } | ForEach-Object { $_.Name } | Sort-Object)
        $cacheHits.Count -eq 0 -and (@($loginHits | Where-Object { $_ -notin @('Get-CodexQuota.ps1', 'dispatch-evidence.ps1') }).Count -eq 0)
    }
    Test-Case X03 {
        $text = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'dispatch\inspect-lifecycle.ps1'), [Text.Encoding]::UTF8)
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsRoot 'dispatch\inspect-lifecycle.ps1'), [ref]$tokens, [ref]$errors)
        $inspect = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Inspect' }, $true))[0]
        $body = $inspect.Body.Extent.Text
        [regex]::Matches($body, 'account_failover = \$accountFailover').Count -ge 4 -and $body.Contains('-ErrorStreamPath $inspectErrorStreamPath') -and $body.Contains('Get-DispatchRejectionRecommendedNextStep')
    }
    Test-Case X03-AR {
        # drift 測試：New-CodexDispatchAccount.ps1 輸出的登入命令樣板與共用函式一致。
        $creatorText = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'New-CodexDispatchAccount.ps1'), [Text.Encoding]::UTF8)
        $templateMatch = [regex]::Match($creatorText, 'Write-Host \("(?<template>powershell\.exe -NoProfile -Command [^"]*)" -f \$escaped\)')
        if (-not $templateMatch.Success) { throw '找不到 New-CodexDispatchAccount.ps1 的登入命令樣板。' }
        $template = $templateMatch.Groups['template'].Value.Replace('`$', '$')
        $sample = 'C:\drift\acct'
        $quotedSample = "C:\drift\it's"
        ($template -f $sample) -ceq (Get-CodexAccountLoginCommand -CodexHome $sample) -and ($template -f $quotedSample.Replace("'", "''''")) -ceq (Get-CodexAccountLoginCommand -CodexHome $quotedSample)
    }
}
finally {
    $env:CODEX_HOME = $originalCodexHomeEnv
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output "PASSED: $($script:passed)"
Write-Output "FAILED: $($script:failed)"
if ($script:failed -gt 0) { exit 1 }
exit 0
