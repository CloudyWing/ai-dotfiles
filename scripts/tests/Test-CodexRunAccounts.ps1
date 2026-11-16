#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$moduleRoot = Join-Path $scriptsRoot 'codex-run'
. (Join-Path $PSScriptRoot 'codex-run-fixtures\TestHelpers.ps1')
foreach ($module in @('00-common.ps1', '40-accounts.ps1')) { . (Join-Path $moduleRoot $module) }
$savedCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME')

try {
    $root = New-TestDirectory -Name 'accounts'
    $repo = New-TestGitRepository -Directory $root -WithWorktree
    $homesRoot = Join-Path $root 'homes'
    $homeA = New-TestAccountHome -Root $homesRoot -Name 'acct-a' -Profile 'review' -Model 'gpt-a'
    $homeB = New-TestAccountHome -Root $homesRoot -Name 'acct-b' -Profile 'review' -Model 'gpt-b'
    $mainLocal = Join-Path $repo.Root '.local'
    $machinePath = New-TestMachineConfig -Directory $mainLocal -Account @(@{ name = 'acct-a'; codex_home = $homeA }, @{ name = 'acct-b'; codex_home = $homeB })
    $healthPath = Join-Path $mainLocal 'codex-account-health.json'
    $lockPath = Join-Path $mainLocal 'codex-account.lock'
    $worktreeLocal = Join-Path $repo.Worktree '.local'
    $nameOf = { param($items) , @($items | ForEach-Object { $_.name }) }

    Test-Case 'RESOLVE-WORKTREE 從 linked worktree 與主 checkout 解出同一個主 checkout 的 machine.json' {
        $fromWorktree = Resolve-RunMachineConfigPath -StartDirectory $repo.Worktree
        $fromMain = Resolve-RunMachineConfigPath -StartDirectory $repo.Root
        Assert-True ($fromWorktree -ieq $machinePath) ('worktree 解出 ' + $fromWorktree + '，預期 ' + $machinePath)
        Assert-True ($fromMain -ieq $machinePath) ('主 checkout 解出 ' + $fromMain)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $worktreeLocal 'machine.json'))) 'worktree 不應有 machine.json（前置條件）'
    }
    Test-Case 'RESOLVE-UNRESOLVED 解不出主 checkout 時丟 RunMachineConfigUnresolved（結束碼 4），不回退' {
        $plain = New-TestDirectory -Name 'plain'
        # GIT_CEILING_DIRECTORIES 使 git 不往上層目錄找 repo，暫存目錄即使位於某個 repo 之內也能構造非 repo 的情境。
        $savedCeiling = [Environment]::GetEnvironmentVariable('GIT_CEILING_DIRECTORIES')
        [Environment]::SetEnvironmentVariable('GIT_CEILING_DIRECTORIES', (Split-Path -Parent $plain))
        try {
            $null = @(& git -C $plain rev-parse --git-common-dir 2>&1)
            Assert-True ($LASTEXITCODE -ne 0) '前置條件不成立：即使設定 GIT_CEILING_DIRECTORIES，git 仍把暫存目錄視為 repo。'
            $caught = Assert-Throws -Code 'RunMachineConfigUnresolved' -Script { Resolve-RunMachineConfigPath -StartDirectory $plain }
            Assert-Equal 4 ([int]$caught.Data['ExitCode'])
        }
        finally { [Environment]::SetEnvironmentVariable('GIT_CEILING_DIRECTORIES', $savedCeiling) }
    }
    Test-Case 'CANDIDATE-ORDER 從 worktree 位置選帳號：回傳兩個帳號，順序為登記順序' {
        $path = Resolve-RunMachineConfigPath -StartDirectory $repo.Worktree
        $selection = Get-RunAccountCandidate -Profile 'review' -MachineConfigPath $path
        Assert-Equal @('acct-a', 'acct-b') (& $nameOf $selection.candidates)
        Assert-Equal 0 (@($selection.skipped).Count)
        Assert-Equal @('gpt-a', 'gpt-b') @($selection.candidates | ForEach-Object { $_.model })
    }
    Test-Case 'HEALTH-REGISTER model-not-supported 記錄後 24 小時內略過該帳號，狀態檔位於主 checkout 的 .local' {
        $entry = Register-RunAccountHealth -AccountName 'acct-a' -CodexHome $homeA -Profile 'review' -Model 'gpt-a' -ReasonCode 'model-not-supported' -Evidence ([ordered]@{ dispatch_slug = 'x' }) -MachineConfigPath $machinePath
        Assert-True (Test-Path -LiteralPath $healthPath) '狀態檔不在主 checkout 的 .local'
        $document = Get-Content -LiteralPath $healthPath -Raw | ConvertFrom-Json
        Assert-Equal 'ai-agents.codex-account-health.v1' $document.schema
        $saved = @($document.entries)[0]
        foreach ($field in @('account_name', 'codex_home', 'profile', 'model', 'reason_code', 'recorded_at_utc', 'expires_at_utc', 'evidence')) {
            Assert-True ($null -ne $saved.PSObject.Properties[$field]) ('缺少欄位 ' + $field)
        }
        Assert-True (([DateTimeOffset]::Parse($saved.expires_at_utc, [Globalization.CultureInfo]::InvariantCulture) - [DateTimeOffset]::Parse($saved.recorded_at_utc, [Globalization.CultureInfo]::InvariantCulture)).TotalHours -eq 24) '效期應為 24 小時'
        $selection = Get-RunAccountCandidate -Profile 'review' -MachineConfigPath $machinePath
        Assert-Equal @('acct-b') (& $nameOf $selection.candidates)
        Assert-Equal @('ModelNotSupportedRecorded') @($selection.skipped | ForEach-Object { $_.reason_code })
        Assert-True ($null -ne $entry) '應回傳寫入的項目'
    }
    Test-Case 'HEALTH-LINKED-WORKTREE linked worktree 的 .local 沒有產生健康狀態檔與鎖檔' {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $worktreeLocal 'codex-account-health.json'))) 'worktree 出現 codex-account-health.json'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $worktreeLocal 'codex-account.lock'))) 'worktree 出現 codex-account.lock'
        Assert-True (Test-Path -LiteralPath $lockPath) '鎖檔應位於主 checkout 的 .local'
    }
    Test-Case 'HEALTH-OTHER-MODEL 記錄的 model 與帳號目前 model 不同時不略過' {
        $null = Register-RunAccountHealth -AccountName 'acct-b' -CodexHome $homeB -Profile 'review' -Model 'gpt-old' -ReasonCode 'model-not-supported' -MachineConfigPath $machinePath
        $selection = Get-RunAccountCandidate -Profile 'review' -MachineConfigPath $machinePath
        Assert-Equal @('acct-b') (& $nameOf $selection.candidates)
        $null = Clear-RunAccountHealth -AccountName 'acct-b' -CodexHome $homeB -Profile 'review' -Model 'gpt-old' -MachineConfigPath $machinePath
    }
    Test-Case 'HEALTH-CLEAR Clear-RunAccountHealth 移除符合鍵的項目，找不到時不寫檔' {
        Assert-True (Clear-RunAccountHealth -AccountName 'acct-a' -CodexHome $homeA -Profile 'review' -Model 'gpt-a' -MachineConfigPath $machinePath)
        $selection = Get-RunAccountCandidate -Profile 'review' -MachineConfigPath $machinePath
        Assert-Equal @('acct-a', 'acct-b') (& $nameOf $selection.candidates)
        $before = (Get-Item -LiteralPath $healthPath).LastWriteTimeUtc
        Assert-True (-not (Clear-RunAccountHealth -AccountName 'acct-a' -CodexHome $homeA -Profile 'review' -Model 'gpt-a' -MachineConfigPath $machinePath))
        Assert-Equal $before.Ticks ((Get-Item -LiteralPath $healthPath).LastWriteTimeUtc.Ticks) '不含該鍵時不應重寫檔案'
    }
    Test-Case 'HEALTH-ALL-SKIPPED 全部帳號都被健康狀態略過時回傳記錄時間最早者' {
        $now = [DateTimeOffset]::UtcNow
        $null = Register-RunAccountHealth -AccountName 'acct-b' -CodexHome $homeB -Profile 'review' -Model 'gpt-b' -ReasonCode 'model-not-supported' -MachineConfigPath $machinePath -NowUtc $now.AddHours(-1)
        $null = Register-RunAccountHealth -AccountName 'acct-a' -CodexHome $homeA -Profile 'review' -Model 'gpt-a' -ReasonCode 'model-not-supported' -MachineConfigPath $machinePath -NowUtc $now.AddHours(-3)
        $selection = Get-RunAccountCandidate -Profile 'review' -MachineConfigPath $machinePath
        Assert-Equal @('acct-a') (& $nameOf $selection.candidates)
        Assert-Equal $true $selection.candidates[0].health_override
        Assert-Equal @('acct-b') (& $nameOf $selection.skipped)
        $null = Clear-RunAccountHealth -AccountName 'acct-a' -CodexHome $homeA -Profile 'review' -Model 'gpt-a' -MachineConfigPath $machinePath
        $null = Clear-RunAccountHealth -AccountName 'acct-b' -CodexHome $homeB -Profile 'review' -Model 'gpt-b' -MachineConfigPath $machinePath
    }
    Test-Case 'HEALTH-EXPIRED 已過期的項目被忽略' {
        $null = Register-RunAccountHealth -AccountName 'acct-a' -CodexHome $homeA -Profile 'review' -Model 'gpt-a' -ReasonCode 'model-not-supported' -MachineConfigPath $machinePath -NowUtc ([DateTimeOffset]::UtcNow.AddHours(-25))
        $state = Read-RunAccountHealth -MachineConfigPath $machinePath
        Assert-Equal 0 (@($state.entries).Count)
        Assert-Equal @('acct-a', 'acct-b') (& $nameOf (Get-RunAccountCandidate -Profile 'review' -MachineConfigPath $machinePath).candidates)
        $null = Register-RunAccountHealth -AccountName 'acct-a' -CodexHome $homeA -Profile 'review' -Model 'gpt-a' -ReasonCode 'model-not-supported' -MachineConfigPath $machinePath -NowUtc ([DateTimeOffset]::UtcNow.AddHours(-26))
        $null = Clear-RunAccountHealth -AccountName 'acct-a' -CodexHome $homeA -Profile 'review' -Model 'gpt-a' -MachineConfigPath $machinePath -NowUtc ([DateTimeOffset]::UtcNow.AddHours(-26))
    }
    Test-Case 'FALLBACK-MODEL-LIST 提供備援 model 時，候選的 models 為主要 model 後接備援 model，model 為第一項' {
        $selection = Get-RunAccountCandidate -Profile 'review' -MachineConfigPath $machinePath -FallbackModel @('fb-1', 'fb-2', 'gpt-a')
        Assert-Equal @('acct-a', 'acct-b') (& $nameOf $selection.candidates)
        Assert-Equal @('gpt-a', 'fb-1', 'fb-2') @($selection.candidates[0].models)
        Assert-Equal 'gpt-a' $selection.candidates[0].model
        Assert-Equal 'gpt-a' $selection.candidates[0].primary_model
        Assert-Equal @('gpt-b', 'fb-1', 'fb-2', 'gpt-a') @($selection.candidates[1].models)
        $plain = Get-RunAccountCandidate -Profile 'review' -MachineConfigPath $machinePath
        Assert-Equal @('gpt-a') @($plain.candidates[0].models) '未提供備援 model 時只有主要 model'
    }
    Test-Case 'FALLBACK-MODEL-PRIMARY-UNSUPPORTED 主要 model 被記為不支援時，帳號不被略過，改用第一個未被記為不支援的備援 model' {
        $null = Register-RunAccountHealth -AccountName 'acct-a' -CodexHome $homeA -Profile 'review' -Model 'gpt-a' -ReasonCode 'model-not-supported' -MachineConfigPath $machinePath
        $selection = Get-RunAccountCandidate -Profile 'review' -MachineConfigPath $machinePath -FallbackModel @('fb-1', 'fb-2')
        Assert-Equal @('acct-a', 'acct-b') (& $nameOf $selection.candidates)
        Assert-Equal 'fb-1' $selection.candidates[0].model
        Assert-Equal @('fb-1', 'fb-2') @($selection.candidates[0].models)
        Assert-Equal 'gpt-a' $selection.candidates[0].primary_model
        Assert-Equal 0 (@($selection.skipped).Count)
        $null = Register-RunAccountHealth -AccountName 'acct-a' -CodexHome $homeA -Profile 'review' -Model 'fb-1' -ReasonCode 'model-not-supported' -MachineConfigPath $machinePath
        $selection = Get-RunAccountCandidate -Profile 'review' -MachineConfigPath $machinePath -FallbackModel @('fb-1', 'fb-2')
        Assert-Equal 'fb-2' $selection.candidates[0].model
        $without = Get-RunAccountCandidate -Profile 'review' -MachineConfigPath $machinePath
        Assert-Equal @('acct-b') (& $nameOf $without.candidates) '沒有備援 model 時照舊略過該帳號'
    }
    Test-Case 'FALLBACK-MODEL-ALL-UNSUPPORTED 主要與全部備援 model 都被記為不支援時才略過該帳號，略過說明列出每個 model' {
        $null = Register-RunAccountHealth -AccountName 'acct-a' -CodexHome $homeA -Profile 'review' -Model 'fb-2' -ReasonCode 'model-not-supported' -MachineConfigPath $machinePath
        $selection = Get-RunAccountCandidate -Profile 'review' -MachineConfigPath $machinePath -FallbackModel @('fb-1', 'fb-2')
        Assert-Equal @('acct-b') (& $nameOf $selection.candidates)
        Assert-Equal @('ModelNotSupportedRecorded') @($selection.skipped | ForEach-Object { $_.reason_code })
        foreach ($name in @('gpt-a', 'fb-1', 'fb-2')) { Assert-True ([string]$selection.skipped[0].detail).Contains('model ' + $name + ' ') ('略過說明缺少 ' + $name) }
        foreach ($name in @('gpt-a', 'fb-1', 'fb-2')) { $null = Clear-RunAccountHealth -AccountName 'acct-a' -CodexHome $homeA -Profile 'review' -Model $name -MachineConfigPath $machinePath }
        Assert-Equal 0 (@((Read-RunAccountHealth -MachineConfigPath $machinePath).entries).Count)
    }
    Test-Case 'HEALTH-SAME-KEY 同鍵再次記錄時取代原項目，不累積重複項' {
        $null = Register-RunAccountHealth -AccountName 'acct-a' -CodexHome $homeA -Profile 'review' -Model 'gpt-a' -ReasonCode 'model-not-supported' -MachineConfigPath $machinePath
        $null = Register-RunAccountHealth -AccountName 'acct-a' -CodexHome $homeA -Profile 'review' -Model 'gpt-a' -ReasonCode 'model-not-supported' -MachineConfigPath $machinePath
        Assert-Equal 1 (@((Read-RunAccountHealth -MachineConfigPath $machinePath).entries).Count)
        $null = Clear-RunAccountHealth -AccountName 'acct-a' -CodexHome $homeA -Profile 'review' -Model 'gpt-a' -MachineConfigPath $machinePath
    }
    Test-Case 'HEALTH-DAMAGED 損毀的健康狀態檔視為空集合，Register 時備份原檔，不丟例外' {
        Write-TestUtf8 -Path $healthPath -Text '{ broken json'
        $state = Read-RunAccountHealth -MachineConfigPath $machinePath
        Assert-Equal $true $state.state_file_invalid
        Assert-Equal 0 (@($state.entries).Count)
        Assert-Equal @('acct-a', 'acct-b') (& $nameOf (Get-RunAccountCandidate -Profile 'review' -MachineConfigPath $machinePath).candidates)
        $null = Register-RunAccountHealth -AccountName 'acct-a' -CodexHome $homeA -Profile 'review' -Model 'gpt-a' -ReasonCode 'model-not-supported' -MachineConfigPath $machinePath
        $backups = @(Get-ChildItem -LiteralPath $mainLocal -Filter 'codex-account-health.json.invalid-*')
        Assert-Equal 1 ($backups.Count) '應有一份 .invalid- 備份'
        Assert-Equal '{ broken json' ((Get-Content -LiteralPath $backups[0].FullName -Raw).Trim())
        Assert-Equal 1 (@((Read-RunAccountHealth -MachineConfigPath $machinePath).entries).Count)
        $null = Clear-RunAccountHealth -AccountName 'acct-a' -CodexHome $homeA -Profile 'review' -Model 'gpt-a' -MachineConfigPath $machinePath
        Write-TestUtf8 -Path $healthPath -Text '{"schema":"other","entries":[]}'
        Assert-Equal $true (Read-RunAccountHealth -MachineConfigPath $machinePath).state_file_invalid
        Write-TestUtf8 -Path $healthPath -Text '{"schema":"ai-agents.codex-account-health.v1","entries":[{"account_name":"x"}]}'
        Assert-Equal $true (Read-RunAccountHealth -MachineConfigPath $machinePath).state_file_invalid
        Remove-Item -LiteralPath $healthPath -Force
    }
    Test-Case 'LOGIN-CHECK Test-RunAccountLoggedIn 只依存在與長度判定，內容非 JSON 也算已登入' {
        $odd = New-TestAccountHome -Root $homesRoot -Name 'odd' -Login missing
        Write-TestUtf8 -Path (Join-Path $odd 'auth.json') -Text 'not json at all'
        Assert-Equal $true (Test-RunAccountLoggedIn -AccountHome $odd).logged_in
        $missing = New-TestAccountHome -Root $homesRoot -Name 'missing-login' -Login missing
        $emptyHome = New-TestAccountHome -Root $homesRoot -Name 'empty-login' -Login empty
        $r1 = Test-RunAccountLoggedIn -AccountHome $missing
        $r2 = Test-RunAccountLoggedIn -AccountHome $emptyHome
        Assert-Equal 'LoginFileMissing' $r1.reason_code
        Assert-Equal 'LoginFileEmpty' $r2.reason_code
        Assert-Equal $false $r1.logged_in
    }
    Test-Case 'SKIP-REASONS 缺登入檔、登入檔為空、缺檔位設定檔的帳號被略過並附登入命令' {
        $loginMissing = New-TestAccountHome -Root $homesRoot -Name 'skip-missing' -Login missing
        $loginEmpty = New-TestAccountHome -Root $homesRoot -Name 'skip-empty' -Login empty
        $noProfile = New-TestAccountHome -Root $homesRoot -Name 'skip-noprofile' -NoProfileConfig
        $skipMachine = New-TestMachineConfig -Directory (New-TestDirectory -Name 'skipmachine') -Account @(
            @{ name = 'skip-missing'; codex_home = $loginMissing }, @{ name = 'skip-empty'; codex_home = $loginEmpty }, @{ name = 'skip-noprofile'; codex_home = $noProfile }, @{ name = 'acct-ok'; codex_home = $homeA })
        $selection = Get-RunAccountCandidate -Profile 'review' -MachineConfigPath $skipMachine
        Assert-Equal @('acct-ok') (& $nameOf $selection.candidates)
        Assert-Equal @('LoginFileMissing', 'LoginFileEmpty', 'ProfileConfigMissing') @($selection.skipped | ForEach-Object { $_.reason_code })
        $summary = Format-RunAccountSkippedSummary -Skipped $selection.skipped
        Assert-True $summary.Contains('$env:CODEX_HOME=''' + $loginMissing + '''; codex login') '缺登入檔應附登入命令'
        Assert-True $summary.Contains('$env:CODEX_HOME=''' + $loginEmpty + '''; codex login') '登入檔為空應附登入命令'
        Assert-True (-not $summary.Contains($noProfile + '''; codex login')) '缺檔位設定檔不需要登入命令'
    }
    Test-Case 'NOT-REGISTERED 無登記（缺檔、空陣列、無 codex_accounts）時 CodexAccountsNotRegistered，輸出不含 CODEX_HOME 與 ~\.codex' {
        $trap = Join-Path $root 'trap-codex-home'
        $null = New-Item -ItemType Directory -Path $trap -Force
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $trap)
        $empty = New-TestMachineConfig -Directory (New-TestDirectory -Name 'emptymachine') -Account @()
        $noProperty = Join-Path (New-TestDirectory -Name 'nopropmachine') 'machine.json'
        Write-TestUtf8 -Path $noProperty -Text '{"schema":"ai-agents.machine.v1","machine_id":"x"}'
        foreach ($path in @((Join-Path (New-TestDirectory -Name 'nomachine') 'machine.json'), $empty, $noProperty)) {
            $caught = Assert-Throws -Code 'CodexAccountsNotRegistered' -Script { Get-RunAccountCandidate -Profile 'review' -MachineConfigPath $path }
            Assert-True (-not $caught.Message.Contains($trap)) '訊息含 CODEX_HOME 環境變數的路徑'
            Assert-True (-not $caught.Message.Contains('.codex')) '訊息含 ~\.codex'
            Assert-Equal 4 ([int]$caught.Data['ExitCode'])
        }
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $savedCodexHome)
    }
    Test-Case 'CONFIG-INVALID 重複名稱、重複目錄、不合法名稱、相對與不存在的目錄以 CodexAccountConfigurationInvalid 拒絕' {
        $dir = New-TestDirectory -Name 'invalidmachine'
        $cases = @(
            @(@{ name = 'dup'; codex_home = $homeA }, @{ name = 'DUP'; codex_home = $homeB }),
            @(@{ name = 'one'; codex_home = $homeA }, @{ name = 'two'; codex_home = ($homeA + '\') }),
            @(@{ name = 'Bad_Name'; codex_home = $homeA }),
            @(@{ name = 'rel'; codex_home = 'homes\acct-a' }),
            @(@{ name = 'ghost'; codex_home = (Join-Path $homesRoot 'does-not-exist') })
        )
        foreach ($case in $cases) {
            $path = New-TestMachineConfig -Directory $dir -Account $case
            $null = Assert-Throws -Code 'CodexAccountConfigurationInvalid' -Script { Read-RunAccount -MachineConfigPath $path }
        }
        Write-TestUtf8 -Path (Join-Path $dir 'machine.json') -Text '{"schema":"ai-agents.machine.v1","codex_accounts":[{"name":"x","codex_home":"C:\\x","extra":1}]}'
        $null = Assert-Throws -Code 'CodexAccountConfigurationInvalid' -Script { Read-RunAccount -MachineConfigPath (Join-Path $dir 'machine.json') }
    }
    Test-Case 'PROFILE-MODEL Get-RunProfileModel 讀頂層 model，其他段落內的 model 字樣不被誤讀' {
        $dir = New-TestDirectory -Name 'models'
        Write-TestUtf8 -Path (Join-Path $dir 'review.config.toml') -Text "model_reasoning_effort = `"high`"`nmodel = `"top-model`" # 註解`n`n[agents]`nmodel = `"agent-model`"`n"
        Assert-Equal 'top-model' (Get-RunProfileModel -CodexHome $dir -Profile 'review')
        Write-TestUtf8 -Path (Join-Path $dir 'scan.config.toml') -Text "[agents]`nmodel = `"agent-model`"`n"
        Assert-True ($null -eq (Get-RunProfileModel -CodexHome $dir -Profile 'scan')) '段落內的 model 不應被讀成頂層'
        Write-TestUtf8 -Path (Join-Path $dir 'content.config.toml') -Text "model = 'literal-model'`n"
        Assert-Equal 'literal-model' (Get-RunProfileModel -CodexHome $dir -Profile 'content')
        Write-TestUtf8 -Path (Join-Path $dir 'advisor.config.toml') -Text "model_reasoning_effort = `"high`"`n"
        Assert-True ($null -eq (Get-RunProfileModel -CodexHome $dir -Profile 'advisor')) 'model_reasoning_effort 不應被誤讀為 model'
        Assert-True ($null -eq (Get-RunProfileModel -CodexHome $dir -Profile 'absent')) '檔案不存在時為 null'
    }
    Test-Case 'RELOGIN-COMMAND 登入命令為 PowerShell 版，路徑含單引號時跳脫，非絕對路徑不輸出' {
        Assert-Equal '$env:CODEX_HOME=''C:\x y\h''; codex login' (Get-RunReloginCommand -CodexHome 'C:\x y\h')
        Assert-Equal '$env:CODEX_HOME=''C:\a''''b''; codex login' (Get-RunReloginCommand -CodexHome "C:\a'b")
        Assert-True ($null -eq (Get-RunReloginCommand -CodexHome 'relative\h'))
        Assert-True ($null -eq (Get-RunReloginCommand -CodexHome ''))
        Assert-True (-not (Get-RunReloginCommand -CodexHome 'C:\h').Contains('power' + 'shell.exe')) '命令不得呼叫 Windows PowerShell'
    }
    Test-Case 'LOCK-TIMEOUT 鎖被持有時逾時丟 CodexAccountLockTimeout，釋放後可取得' {
        $lockFile = Join-Path (New-TestDirectory -Name 'lock') 'codex-account.lock'
        $held = Open-RunAccountLock -LockPath $lockFile
        try {
            $null = Assert-Throws -Code 'CodexAccountLockTimeout' -Script { Open-RunAccountLock -LockPath $lockFile -MaxAttempts 2 -DelayMilliseconds 10 }
        }
        finally { $held.Stream.Dispose() }
        $again = Open-RunAccountLock -LockPath $lockFile -MaxAttempts 2 -DelayMilliseconds 10
        $again.Stream.Dispose()
    }
    Test-Case 'NO-LEGACY-REFERENCE 帳號模組不引用現行模組，也不讀取 CODEX_HOME 環境變數' {
        $text = Get-Content -LiteralPath (Join-Path $moduleRoot '40-accounts.ps1') -Raw
        Assert-True (-not [regex]::IsMatch($text, 'scripts/dispatch|dispatch-evidence|common-runtime|\$env:CODEX_HOME\s*(?!=\s*'')')) '發現不允許的引用'
        Assert-True (-not $text.Contains('GetEnvironmentVariable')) '不應讀取環境變數'
    }
}
finally {
    [Environment]::SetEnvironmentVariable('CODEX_HOME', $savedCodexHome)
    $exitCode = Complete-TestRun
}
exit $exitCode
