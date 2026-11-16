#Requires -Version 7.0
# 帳號登記、登入檢查、檔位 model、健康狀態與帳號選擇。依賴 00-common.ps1。
# machine.json、codex-account-health.json、codex-account.lock 位於主 checkout 的 .local，
# 與現行派工入口共用同一份狀態；本檔只實作格式，不載入現行入口的任何程式。

function Resolve-RunMachineConfigPath {
    [CmdletBinding()]
    param(
        [string]$StartDirectory = (Split-Path -Parent $PSScriptRoot)
    )

    # 以 git common dir 解出主 checkout，入口位於線工作樹或主 checkout 時得到同一個路徑。
    # 解不出時不回退到入口所在工作樹，也不使用 CODEX_HOME 環境變數或 ~\.codex。
    $commonDirectory = $null
    try {
        $output = @(& git -C $StartDirectory rev-parse --path-format=absolute --git-common-dir 2>$null)
        if ($LASTEXITCODE -eq 0 -and $output.Count -gt 0) { $commonDirectory = ([string]$output[0]).Trim() }
    }
    catch { $commonDirectory = $null }
    if ([string]::IsNullOrWhiteSpace($commonDirectory)) {
        throw (New-RunError -Code 'RunMachineConfigUnresolved' -Message ('無法從 ' + $StartDirectory + ' 解出主 checkout。') -ExitCode 4)
    }
    $commonDirectory = [IO.Path]::GetFullPath($commonDirectory).TrimEnd('\', '/')
    if ([IO.Path]::GetFileName($commonDirectory) -cne '.git') {
        throw (New-RunError -Code 'RunMachineConfigUnresolved' -Message ('git common dir 不是 .git 目錄：' + $commonDirectory) -ExitCode 4)
    }
    $mainRoot = Split-Path -Parent $commonDirectory
    return Join-Path $mainRoot '.local\machine.json'
}

function Read-RunAccount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MachineConfigPath
    )

    if (-not [IO.File]::Exists($MachineConfigPath)) {
        throw (New-RunError -Code 'CodexAccountsNotRegistered' -Message ('找不到帳號登記檔：' + $MachineConfigPath) -ExitCode 4)
    }
    $accounts = New-Object 'System.Collections.Generic.List[object]'
    try {
        $machine = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($MachineConfigPath, (New-Object System.Text.UTF8Encoding -ArgumentList @($false))))
        $accountsProperty = if ($machine -is [pscustomobject]) { $machine.PSObject.Properties['codex_accounts'] } else { $null }
        if ($null -ne $accountsProperty) {
            if ([string]$machine.schema -cne 'ai-agents.machine.v1' -or $accountsProperty.Value -isnot [array]) {
                throw 'codex_accounts 必須是 ai-agents.machine.v1 的陣列。'
            }
            $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            $homes = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $accountsProperty.Value) {
                if ($null -eq $entry -or $entry -isnot [pscustomobject] -or @($entry.PSObject.Properties).Count -ne 2 -or
                    $null -eq $entry.PSObject.Properties['name'] -or $null -eq $entry.PSObject.Properties['codex_home'] -or
                    $entry.name -isnot [string] -or $entry.name -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or
                    $entry.codex_home -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($entry.codex_home)) {
                    throw '帳號項目須只有合法名稱與絕對 codex_home。'
                }
                $homePath = [IO.Path]::GetFullPath($entry.codex_home).TrimEnd('\', '/')
                if (-not [IO.Directory]::Exists($homePath)) { throw ('帳號目錄不存在：' + $entry.name + '；' + $homePath) }
                if (-not $names.Add($entry.name) -or -not $homes.Add($homePath)) { throw ('帳號名稱或目錄重複：' + $entry.name + '；' + $homePath) }
                $accounts.Add([pscustomobject]@{ name = [string]$entry.name; codex_home = $homePath })
            }
        }
    }
    catch {
        throw (New-RunError -Code 'CodexAccountConfigurationInvalid' -Message $_.Exception.Message -ExitCode 4)
    }
    if ($accounts.Count -eq 0) {
        throw (New-RunError -Code 'CodexAccountsNotRegistered' -Message ($MachineConfigPath + ' 沒有登記任何 codex_accounts。') -ExitCode 4)
    }
    return @($accounts.ToArray())
}

function Test-RunAccountLoggedIn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AccountHome
    )

    # 只看 auth.json 的存在、長度與修改時間，不讀內容。
    $loginFilePath = Join-Path $AccountHome 'auth.json'
    $loginFile = New-Object System.IO.FileInfo -ArgumentList @($loginFilePath)
    $length = $null
    $lastWrite = $null
    $reasonCode = 'LoginFileMissing'
    if ($loginFile.Exists) {
        $length = [int64]$loginFile.Length
        $lastWrite = $loginFile.LastWriteTimeUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        $reasonCode = if ($length -gt 0) { $null } else { 'LoginFileEmpty' }
    }
    return [pscustomobject]@{
        logged_in = ($null -eq $reasonCode)
        reason_code = $reasonCode
        login_file_path = $loginFilePath
        login_file_length = $length
        login_file_last_write_utc = $lastWrite
    }
}

function Get-RunProfileModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CodexHome,

        [Parameter(Mandatory)]
        [string]$Profile
    )

    # 取 <檔位>.config.toml 頂層（第一個 [ 之前）的 model 字串。找不到、無法解析、值衝突時回傳 $null。
    $configPath = Join-Path $CodexHome ($Profile + '.config.toml')
    if (-not [IO.File]::Exists($configPath)) { return $null }
    try {
        $content = (New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)).GetString([IO.File]::ReadAllBytes($configPath))
    }
    catch { return $null }
    $values = New-Object 'System.Collections.Generic.List[string]'
    $lineIndex = 0
    foreach ($line in ([regex]::Split($content, '\r?\n'))) {
        $current = $line
        if ($lineIndex -eq 0 -and $current.Length -gt 0 -and $current[0] -eq [char]0xFEFF) { $current = $current.Substring(1) }
        $lineIndex++
        if ($current -match '^\s*\[') { break }
        $match = [regex]::Match($current, '^\s*model\s*=\s*(?<value>.*?)(?:\s+#.*)?$')
        if (-not $match.Success) { continue }
        $raw = $match.Groups['value'].Value.Trim()
        if ($raw -match '^"(?<q>(?:[^"\\]|\\.)*)"$') { $values.Add($Matches['q'].Replace('\"', '"').Replace('\\', '\')) }
        elseif ($raw -match "^'(?<q>[^']*)'$") { $values.Add($Matches['q']) }
        else { return $null }
    }
    if ($values.Count -eq 0 -or [string]::IsNullOrWhiteSpace($values[0])) { return $null }
    foreach ($value in $values) { if ($value -cne $values[0]) { return $null } }
    return $values[0]
}

function Open-RunAccountLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LockPath,

        [ValidateRange(1, 100)]
        [int]$MaxAttempts = 10,

        [ValidateRange(1, 5000)]
        [int]$DelayMilliseconds = 100
    )

    # 以獨佔開啟鎖檔取得鎖，取不到時重試，逾時丟 CodexAccountLockTimeout。呼叫端以 Stream.Dispose() 釋放。
    $directory = Split-Path -Parent $LockPath
    if (-not [IO.Directory]::Exists($directory)) { $null = [IO.Directory]::CreateDirectory($directory) }
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $stream = New-Object System.IO.FileStream -ArgumentList @($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            return [pscustomobject]@{ Stream = $stream; LockPath = $LockPath }
        }
        catch [System.IO.IOException] {
            if ($attempt -lt $MaxAttempts) { Start-Sleep -Milliseconds $DelayMilliseconds }
        }
    }
    throw (New-RunError -Code 'CodexAccountLockTimeout' -Message ('等待帳號鎖逾時：' + $LockPath) -ExitCode 4)
}

function Get-RunAccountHealthPath {
    param([Parameter(Mandatory)][string]$MachineConfigPath)

    return Join-Path (Split-Path -Parent $MachineConfigPath) 'codex-account-health.json'
}

function ConvertTo-RunHealthTime {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return [DateTimeOffset]$Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]::new(([DateTime]$Value).ToUniversalTime()) }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed }
    return $null
}

function Test-RunHealthKeyMatch {
    param(
        [Parameter(Mandatory)][object]$Entry,
        [AllowNull()][AllowEmptyString()][string]$AccountName,
        [AllowNull()][AllowEmptyString()][string]$CodexHome,
        [AllowNull()][AllowEmptyString()][string]$Profile,
        [AllowNull()][AllowEmptyString()][string]$Model
    )

    # 比對「帳號、codex_home、檔位、model」。任一邊沒有記錄 model 時視為相符。
    $homeText = if ([string]::IsNullOrWhiteSpace($CodexHome)) { '' } else { $CodexHome.TrimEnd('\', '/') }
    $entryHome = ([string](Get-RunJsonProperty -Object $Entry -Name 'codex_home')).TrimEnd('\', '/')
    if (-not [string]::Equals([string](Get-RunJsonProperty -Object $Entry -Name 'account_name'), [string]$AccountName, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not [string]::Equals($entryHome, $homeText, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not [string]::Equals([string](Get-RunJsonProperty -Object $Entry -Name 'profile'), [string]$Profile, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $entryModel = [string](Get-RunJsonProperty -Object $Entry -Name 'model')
    if ([string]::IsNullOrWhiteSpace($entryModel) -or [string]::IsNullOrWhiteSpace($Model)) { return $true }
    return [string]::Equals($entryModel, $Model, [StringComparison]::OrdinalIgnoreCase)
}

function Read-RunAccountHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MachineConfigPath,

        [DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow
    )

    # 回傳未過期的項目。檔案不存在時為空集合；無法解析、schema 不符或任一項目缺必要欄位時整份視為空集合並標示 state_file_invalid。
    $path = Get-RunAccountHealthPath -MachineConfigPath $MachineConfigPath
    $active = New-Object 'System.Collections.Generic.List[object]'
    $invalid = $false
    if ([IO.File]::Exists($path)) {
        try {
            $document = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding -ArgumentList @($false))))
            $entriesProperty = if ($document -is [pscustomobject]) { $document.PSObject.Properties['entries'] } else { $null }
            if ($null -eq $entriesProperty -or [string](Get-RunJsonProperty -Object $document -Name 'schema') -cne 'ai-agents.codex-account-health.v1') {
                throw 'schema 不符。'
            }
            foreach ($entry in @($entriesProperty.Value)) {
                $complete = $null -ne $entry -and $entry -is [pscustomobject]
                if ($complete) {
                    foreach ($name in @('account_name', 'codex_home', 'profile', 'reason_code', 'recorded_at_utc', 'expires_at_utc')) {
                        if ([string]::IsNullOrWhiteSpace([string](Get-RunJsonProperty -Object $entry -Name $name))) { $complete = $false }
                    }
                }
                if (-not $complete) { throw '項目缺必要欄位或不是物件。' }
                $expires = ConvertTo-RunHealthTime -Value (Get-RunJsonProperty -Object $entry -Name 'expires_at_utc')
                if ($null -ne $expires -and $expires -gt $NowUtc) { $active.Add($entry) }
            }
        }
        catch {
            $invalid = $true
            $active.Clear()
        }
    }
    return [pscustomobject]@{ path = $path; entries = @($active.ToArray()); state_file_invalid = $invalid }
}

function Register-RunAccountHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccountName,
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$Profile,
        [AllowNull()][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory)][string]$ReasonCode,
        [AllowNull()][object]$Evidence = $null,
        [Parameter(Mandatory)][string]$MachineConfigPath,
        [DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow
    )

    # 鎖內讀寫。損毀檔先備份為 <檔名>.invalid-<時間戳>；同鍵項目取代；原子寫入；記錄 24 小時。
    $path = Get-RunAccountHealthPath -MachineConfigPath $MachineConfigPath
    $lock = Open-RunAccountLock -LockPath (Join-Path (Split-Path -Parent $path) 'codex-account.lock')
    try {
        $kept = New-Object 'System.Collections.Generic.List[object]'
        if ([IO.File]::Exists($path)) {
            $current = Read-RunAccountHealth -MachineConfigPath $MachineConfigPath -NowUtc $NowUtc
            if ([bool]$current.state_file_invalid) {
                $backupPath = $path + '.invalid-' + $NowUtc.UtcDateTime.ToString('yyyyMMddHHmmssfff', [Globalization.CultureInfo]::InvariantCulture)
                [IO.File]::Copy($path, $backupPath, $true)
            }
            else {
                foreach ($existing in @($current.entries)) {
                    if (-not (Test-RunHealthKeyMatch -Entry $existing -AccountName $AccountName -CodexHome $CodexHome -Profile $Profile -Model $Model)) { $kept.Add($existing) }
                }
            }
        }
        $recorded = $NowUtc.ToUniversalTime()
        $entry = [ordered]@{
            account_name = $AccountName
            codex_home = $CodexHome
            profile = $Profile
            model = if ([string]::IsNullOrWhiteSpace($Model)) { $null } else { $Model }
            reason_code = $ReasonCode
            recorded_at_utc = $recorded.UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            expires_at_utc = $recorded.AddHours(24).UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            evidence = $Evidence
        }
        $kept.Add([pscustomobject]$entry)
        Write-RunJsonAtomic -Path $path -InputObject ([ordered]@{ schema = 'ai-agents.codex-account-health.v1'; entries = @($kept.ToArray()) }) -Depth 8
        return [pscustomobject]$entry
    }
    finally {
        $lock.Stream.Dispose()
    }
}

function Clear-RunAccountHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccountName,
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$Profile,
        [AllowNull()][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory)][string]$MachineConfigPath,
        [DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow
    )

    # 派遣成功時移除符合鍵的項目。狀態檔不存在或不含該鍵時不寫檔，回傳 $false。
    $path = Get-RunAccountHealthPath -MachineConfigPath $MachineConfigPath
    if (-not [IO.File]::Exists($path)) { return $false }
    $peek = Read-RunAccountHealth -MachineConfigPath $MachineConfigPath -NowUtc $NowUtc
    if ([bool]$peek.state_file_invalid -or @($peek.entries | Where-Object { Test-RunHealthKeyMatch -Entry $_ -AccountName $AccountName -CodexHome $CodexHome -Profile $Profile -Model $Model }).Count -eq 0) { return $false }
    $lock = Open-RunAccountLock -LockPath (Join-Path (Split-Path -Parent $path) 'codex-account.lock')
    try {
        $current = Read-RunAccountHealth -MachineConfigPath $MachineConfigPath -NowUtc $NowUtc
        if ([bool]$current.state_file_invalid) { return $false }
        $remaining = @($current.entries | Where-Object { -not (Test-RunHealthKeyMatch -Entry $_ -AccountName $AccountName -CodexHome $CodexHome -Profile $Profile -Model $Model) })
        Write-RunJsonAtomic -Path $path -InputObject ([ordered]@{ schema = 'ai-agents.codex-account-health.v1'; entries = @($remaining) }) -Depth 8
        return $true
    }
    finally {
        $lock.Stream.Dispose()
    }
}

function Get-RunAccountCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Profile,

        [Parameter(Mandatory)]
        [string]$MachineConfigPath,

        # 檔位的備援 model（依序），取自登錄表 profileSettings.fallbackModels。
        [AllowEmptyCollection()]
        [string[]]$FallbackModel = @(),

        [DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow
    )

    # 依登記順序逐帳號檢查登入檔、檔位設定檔與健康狀態。帳號的可用 model 為「檔位設定檔的主要 model、備援 model」依序扣掉
    # 被記為不支援者，候選的 models 為這份清單，model 為其第一項；清單為空才略過該帳號。
    # 所有可用帳號都被記為不支援時，取記錄時間最早者以主要 model 實際嘗試一次。
    $candidates = New-Object 'System.Collections.Generic.List[object]'
    $skipped = New-Object 'System.Collections.Generic.List[object]'
    $recordedHealth = New-Object 'System.Collections.Generic.List[object]'
    $healthEntries = @((Read-RunAccountHealth -MachineConfigPath $MachineConfigPath -NowUtc $NowUtc).entries)
    foreach ($account in @(Read-RunAccount -MachineConfigPath $MachineConfigPath)) {
        $login = Test-RunAccountLoggedIn -AccountHome $account.codex_home
        $skipReason = $null
        $skipDetail = $null
        $recordedAt = $null
        $model = $null
        if (-not [bool]$login.logged_in) {
            $skipReason = [string]$login.reason_code
        }
        elseif (-not [IO.File]::Exists((Join-Path $account.codex_home ($Profile + '.config.toml')))) {
            $skipReason = 'ProfileConfigMissing'
        }
        else {
            $model = Get-RunProfileModel -CodexHome $account.codex_home -Profile $Profile
            $modelChain = New-Object 'System.Collections.Generic.List[object]'
            $modelChain.Add($model)
            foreach ($fallback in @($FallbackModel)) {
                if (-not [string]::IsNullOrWhiteSpace($fallback) -and $modelChain -cnotcontains $fallback) { $modelChain.Add($fallback) }
            }
            $usableModels = New-Object 'System.Collections.Generic.List[object]'
            $details = New-Object 'System.Collections.Generic.List[string]'
            foreach ($chainModel in $modelChain) {
                $matched = $null
                foreach ($healthEntry in $healthEntries) {
                    if (Test-RunHealthKeyMatch -Entry $healthEntry -AccountName $account.name -CodexHome $account.codex_home -Profile $Profile -Model $chainModel) { $matched = $healthEntry; break }
                }
                if ($null -eq $matched) { $usableModels.Add($chainModel); continue }
                $matchedAt = ConvertTo-RunHealthTime -Value (Get-RunJsonProperty -Object $matched -Name 'recorded_at_utc')
                if ($null -eq $recordedAt -or ($null -ne $matchedAt -and $matchedAt -lt $recordedAt)) { $recordedAt = $matchedAt }
                $recordedModel = [string](Get-RunJsonProperty -Object $matched -Name 'model')
                if ([string]::IsNullOrWhiteSpace($recordedModel)) { $recordedModel = '(未記錄)' }
                $details.Add('model ' + $recordedModel + ' 於 ' + [string](Get-RunJsonProperty -Object $matched -Name 'recorded_at_utc') + ' 被服務端拒絕，' + [string](Get-RunJsonProperty -Object $matched -Name 'expires_at_utc') + ' 前略過')
            }
            if ($usableModels.Count -eq 0) {
                $skipReason = 'ModelNotSupportedRecorded'
                $skipDetail = $details -join '；'
            }
        }
        if ($null -eq $skipReason) {
            $candidates.Add([pscustomobject]@{ name = $account.name; codex_home = $account.codex_home; model = $usableModels[0]; models = @($usableModels.ToArray()); primary_model = $model; health_override = $false })
            continue
        }
        $item = [pscustomobject]@{
            name = $account.name
            codex_home = $account.codex_home
            reason_code = $skipReason
            login_file_path = $login.login_file_path
            login_file_length = $login.login_file_length
            detail = $skipDetail
        }
        $skipped.Add($item)
        if ($skipReason -ceq 'ModelNotSupportedRecorded') {
            $recordedHealth.Add([pscustomobject]@{ item = $item; recorded_at = $recordedAt; order = $recordedHealth.Count; model = $model })
        }
    }
    if ($candidates.Count -eq 0 -and $recordedHealth.Count -gt 0) {
        $oldest = @($recordedHealth.ToArray() | Sort-Object -Property @{ Expression = { if ($null -eq $_.recorded_at) { [DateTimeOffset]::MinValue } else { $_.recorded_at } } }, @{ Expression = { $_.order } })[0]
        $null = $skipped.Remove($oldest.item)
        $candidates.Add([pscustomobject]@{ name = $oldest.item.name; codex_home = $oldest.item.codex_home; model = $oldest.model; models = @($oldest.model); primary_model = $oldest.model; health_override = $true })
    }
    return [pscustomobject]@{ candidates = @($candidates.ToArray()); skipped = @($skipped.ToArray()) }
}

function Get-RunReloginCommand {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$CodexHome
    )

    # PowerShell 版重新登入命令。路徑含單引號時以兩個單引號跳脫；非絕對路徑不輸出命令。
    if ([string]::IsNullOrWhiteSpace($CodexHome) -or -not [IO.Path]::IsPathFullyQualified($CodexHome)) { return $null }
    return ('$env:CODEX_HOME=''' + $CodexHome.Replace("'", "''") + '''; codex login')
}

function Format-RunAccountSkippedSummary {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Skipped = @()
    )

    # 各帳號略過原因與需要重新登入者的命令，供 CodexAccountsAllUnavailable 的訊息使用。
    if (@($Skipped).Count -eq 0) { return '無已登記帳號' }
    $parts = foreach ($item in $Skipped) {
        $text = [string]$item.name + ':' + [string]$item.reason_code
        if (-not [string]::IsNullOrWhiteSpace([string]$item.detail)) { $text += ':' + [string]$item.detail }
        if ($item.reason_code -ceq 'LoginFileMissing' -or $item.reason_code -ceq 'LoginFileEmpty') {
            $text += '；重新登入：' + (Get-RunReloginCommand -CodexHome ([string]$item.codex_home))
        }
        $text
    }
    return ($parts -join '; ')
}
