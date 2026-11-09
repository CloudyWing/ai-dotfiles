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
            [IO.File]::WriteAllText($configPath, ("[windows]`nsandbox = `"elevated`"`n`n[projects.'" + $Root.ToLowerInvariant() + "']`ntrust_level = `"trusted`"`n"), $utf8NoBom)
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
        $null -eq $evidence.rejection_kind -and $null -eq (Convert-EventEvidenceToServiceRejection -EventEvidence ([pscustomobject]$evidence)) -and -not (Test-DispatchAccountFailoverEligible -EventEvidence $evidence)
    }
    Test-Case E06 {
        $rate = FxEvents -Directory $eventDir -Name 'rate' -Event @([ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'rate limit exceeded' } })
        $http429 = FxEvents -Directory $eventDir -Name 'http429' -Event @([ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'HTTP 429 Too many requests' } })
        $rateEvidence = Get-DispatchEventEvidence -EventPath $rate.event
        $http429Evidence = Get-DispatchEventEvidence -EventPath $http429.event
        $null -eq $rateEvidence.rejection_kind -and $rateEvidence.usage_limit -and $null -eq $http429Evidence.rejection_kind -and $http429Evidence.usage_limit -and
        $null -ne (Convert-EventEvidenceToServiceRejection -EventEvidence ([pscustomobject]$http429Evidence)) -and -not (Test-DispatchAccountFailoverEligible -EventEvidence $http429Evidence)
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
        $null -eq $plainEvidence.rejection_kind -and $null -eq $doneEvidence.rejection_kind -and $null -eq $missing.rejection_kind -and $missing.item_event_count -eq 0 -and
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
        $unauthorizedStep.Contains('重新登入') -and $modelStep.Contains('model') -and $usageStep.Contains('額度') -and @($unauthorizedStep, $modelStep, $usageStep | Select-Object -Unique).Count -eq 3
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
}
finally {
    $env:CODEX_HOME = $originalCodexHomeEnv
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output "PASSED: $($script:passed)"
Write-Output "FAILED: $($script:failed)"
if ($script:failed -gt 0) { exit 1 }
exit 0
