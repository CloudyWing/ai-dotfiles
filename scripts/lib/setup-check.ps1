#Requires -Version 7.0
# Setup-AIGlobalConfig.ps1 -Check 的比對與輸出：只讀取現況並與預期比對，不建立、不修改、不刪除任何東西。
# 由 Setup 在 -Check 時以 dot-source 載入，預期狀態（連結清單、掃描範圍、hooksPath 等）由 Setup 的同一份變數傳入。
# 本檔使用 Setup 已定義的 Get-BrokenConfigLink、Get-ClaudePluginSpec，
# 已載入的檔位設定檔模組函式（Read-CodexProfileSpec、Sync-CodexProfileGeneratedFile、Get-CodexProfileAccountState、Read-CodexAccountConfiguration 等），
# 以及 lib\claude-user-config.ps1 的唯讀函式（Invoke-ClaudeCli、Get-ClaudeList、Get-ClaudeProperty、Read-ClaudeSettingsFile、Get-ClaudeSettingsPlan、
# Get-ClaudeRequiredOfficialPlugin）。不呼叫任何寫入函式。

$script:SetupCheckStatusLabel = @{
    'ok'           = '符合'
    'missing'      = '缺少'
    'wrong-target' = '指向錯誤位置'
    'mismatch'     = '內容不符'
    'unknown'      = '無法判定'
}

$script:SetupCheckCategoryLabel = [ordered]@{
    'prerequisite'          = '前置軟體'
    'long-paths'            = 'Windows 長路徑'
    'config-root'           = '設定來源檔案'
    'tool-dir'              = '工具目錄'
    'link'                  = '符號連結'
    'orphan'                = '斷鍊孤兒'
    'plugin-marketplace'    = 'Claude plugin marketplace'
    'plugin'                = 'Claude plugin'
    'legacy-hook'           = '舊 hook 註冊'
    'claude-settings'       = 'Claude settings.json 共用設定'
    'git-hooks-path'        = 'Git core.hooksPath'
    'git-excludes'          = 'Git core.excludesFile'
    'codex-machine'         = 'Codex 派工帳號登記'
    'codex-profile-generated' = 'Codex 檔位產生檔'
    'codex-profile-link'    = 'Codex 檔位設定檔連結'
    'codex-mcp-command'     = 'Codex 帳號的 MCP 指令'
}

function New-SetupCheckItem {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][string]$Expected,
        [AllowNull()][string]$Actual,
        [Parameter(Mandatory)][ValidateSet('ok', 'missing', 'wrong-target', 'mismatch', 'unknown')][string]$Status,
        [string]$Detail = ''
    )

    return [pscustomobject]@{
        category = $Category
        path     = $Path
        expected = $Expected
        actual   = $Actual
        status   = $Status
        label    = $script:SetupCheckStatusLabel[$Status]
        detail   = $Detail
    }
}

function ConvertTo-SetupCheckFullPath {
    param([string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if (-not [System.String]::Equals($full, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $full = $full.TrimEnd([char[]]@([char]92, [char]47))
    }
    return $full
}

function Test-SetupCheckLink {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$LinkPath,
        [Parameter(Mandatory)][string]$TargetPath
    )

    # 與 Set-SymbolicLink 相同的現況判讀：Get-Item 讀不到斷鍊時改用 Get-ChildItem 找。
    $existing = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
    if (-not $existing) {
        $parent = Split-Path $LinkPath
        $leaf = Split-Path $LinkPath -Leaf
        if (Test-Path $parent) {
            $existing = Get-ChildItem -Path $parent -Filter $leaf -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        }
    }
    if (-not (Test-Path -LiteralPath $TargetPath)) {
        return (New-SetupCheckItem -Category $Category -Path $LinkPath -Expected $TargetPath -Actual $null -Status 'unknown' -Detail '預期來源不存在，無法判定（Setup 會略過此連結）')
    }
    if (-not $existing) {
        return (New-SetupCheckItem -Category $Category -Path $LinkPath -Expected $TargetPath -Actual $null -Status 'missing' -Detail '連結不存在')
    }
    if (-not ($existing.Attributes -match 'ReparsePoint')) {
        return (New-SetupCheckItem -Category $Category -Path $LinkPath -Expected $TargetPath -Actual $null -Status 'wrong-target' -Detail '路徑存在但不是符號連結（一般檔案或目錄）')
    }
    $targetValue = $null
    if ($null -ne $existing.PSObject.Properties['Target']) { $targetValue = $existing.Target }
    if ($null -eq $targetValue -and $null -ne $existing.PSObject.Properties['LinkTarget']) { $targetValue = $existing.LinkTarget }
    $targetText = @($targetValue) -join ''
    if ([string]::IsNullOrWhiteSpace($targetText)) {
        return (New-SetupCheckItem -Category $Category -Path $LinkPath -Expected $TargetPath -Actual $null -Status 'unknown' -Detail '無法讀取連結目標')
    }
    $resolved = if ([System.IO.Path]::IsPathRooted($targetText)) { $targetText } else { Join-Path (Split-Path -Parent $LinkPath) $targetText }
    $same = [System.String]::Equals((ConvertTo-SetupCheckFullPath -Path $resolved), (ConvertTo-SetupCheckFullPath -Path $TargetPath), [System.StringComparison]::OrdinalIgnoreCase)
    if ($same) {
        return (New-SetupCheckItem -Category $Category -Path $LinkPath -Expected $TargetPath -Actual $targetText -Status 'ok')
    }
    return (New-SetupCheckItem -Category $Category -Path $LinkPath -Expected $TargetPath -Actual $targetText -Status 'wrong-target' -Detail '連結指向其他位置')
}

function Get-SetupCheckGitValue {
    param([string[]]$GitArgument)

    # 回傳 @{ ExitCode; Value }；不寫入任何設定。Git 無法啟動（例如 PATH 找不到）時 ExitCode 為 -1，交由各呼叫端的 unknown 分支處理。
    try {
        $output = (& git @GitArgument 2>$null | Out-String).TrimEnd()
        return @{ ExitCode = $LASTEXITCODE; Value = $output }
    }
    catch {
        return @{ ExitCode = -1; Value = $_.Exception.Message }
    }
}

function Get-SetupCheckLongPathItem {
    $registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
    try {
        $properties = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
        $property = $properties.PSObject.Properties['LongPathsEnabled']
        if ($null -ne $property -and $property.Value -eq 1) {
            return (New-SetupCheckItem -Category 'long-paths' -Path "$registryPath\LongPathsEnabled" -Expected '1' -Actual '1' -Status 'ok')
        }
        $actual = if ($null -eq $property) { $null } else { [string]$property.Value }
        return (New-SetupCheckItem -Category 'long-paths' -Path "$registryPath\LongPathsEnabled" -Expected '1' -Actual $actual -Status 'missing' -Detail '未啟用；以系統管理員身分執行 Setup -EnableLongPaths 可啟用')
    }
    catch {
        return (New-SetupCheckItem -Category 'long-paths' -Path "$registryPath\LongPathsEnabled" -Expected '1' -Actual $null -Status 'unknown' -Detail ('讀取登錄失敗：' + $_.Exception.Message))
    }
}

function Get-SetupCheckPluginItem {
    param([hashtable]$Expected)

    $items = New-Object 'System.Collections.Generic.List[object]'
    $marketplaceRoot = $Expected.MarketplaceRoot
    $marketplaceName = 'ai-agents-local'
    $unknownReason = $null
    $specs = @()
    if ($null -eq (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue)) {
        $unknownReason = '找不到 claude CLI'
    }
    elseif (-not (Test-Path -LiteralPath (Join-Path $marketplaceRoot '.claude-plugin\marketplace.json') -PathType Leaf)) {
        $unknownReason = '找不到 marketplace 清單'
    }
    else {
        try { $specs = @(Get-ClaudePluginSpec -MarketplaceRoot $marketplaceRoot) }
        catch { $unknownReason = $_.Exception.Message }
    }
    if ($null -ne $unknownReason) {
        $items.Add((New-SetupCheckItem -Category 'plugin-marketplace' -Path $marketplaceName -Expected $marketplaceRoot -Actual $null -Status 'unknown' -Detail $unknownReason))
        return @($items.ToArray())
    }

    $marketplaceReadable = $false
    try {
        $marketplaces = Get-ClaudeList @('plugin', 'marketplace', 'list', '--json')
        $marketplaceReadable = $true
        $existing = @($marketplaces | Where-Object { (Get-ClaudeProperty $_ 'name') -eq $marketplaceName -or (Get-ClaudeProperty $_ 'id') -eq $marketplaceName })
        if ($existing.Count -eq 0) {
            $items.Add((New-SetupCheckItem -Category 'plugin-marketplace' -Path $marketplaceName -Expected $marketplaceRoot -Actual $null -Status 'missing' -Detail 'marketplace 未註冊'))
        }
        elseif ($existing.Count -gt 1) {
            $items.Add((New-SetupCheckItem -Category 'plugin-marketplace' -Path $marketplaceName -Expected $marketplaceRoot -Actual $null -Status 'unknown' -Detail 'marketplace 清單含重複名稱'))
        }
        else {
            $source = Get-ClaudeProperty $existing[0] 'source'
            $sourcePath = if ($source -is [string] -and [IO.Path]::IsPathRooted($source)) { $source } else { Get-ClaudeProperty $source 'path' }
            if ([string]::IsNullOrWhiteSpace([string]$sourcePath)) { $sourcePath = Get-ClaudeProperty $existing[0] 'installLocation' }
            if ([string]::IsNullOrWhiteSpace([string]$sourcePath)) {
                $items.Add((New-SetupCheckItem -Category 'plugin-marketplace' -Path $marketplaceName -Expected $marketplaceRoot -Actual $null -Status 'unknown' -Detail '無法判定 marketplace 來源路徑'))
            }
            elseif ([string]::Equals((ConvertTo-SetupCheckFullPath -Path $sourcePath), (ConvertTo-SetupCheckFullPath -Path $marketplaceRoot), [StringComparison]::OrdinalIgnoreCase)) {
                $items.Add((New-SetupCheckItem -Category 'plugin-marketplace' -Path $marketplaceName -Expected $marketplaceRoot -Actual ([string]$sourcePath) -Status 'ok'))
            }
            else {
                $items.Add((New-SetupCheckItem -Category 'plugin-marketplace' -Path $marketplaceName -Expected $marketplaceRoot -Actual ([string]$sourcePath) -Status 'wrong-target' -Detail 'marketplace 來源指向其他位置'))
            }
        }
    }
    catch {
        $items.Add((New-SetupCheckItem -Category 'plugin-marketplace' -Path $marketplaceName -Expected $marketplaceRoot -Actual $null -Status 'unknown' -Detail $_.Exception.Message))
    }

    $plugins = $null
    $pluginReason = $null
    if (-not $marketplaceReadable) { $pluginReason = '無法讀取 marketplace 清單，plugin 狀態無法判定' }
    else {
        try { $plugins = Get-ClaudeList @('plugin', 'list', '--json') }
        catch { $pluginReason = $_.Exception.Message }
    }
    # 本機 marketplace 的 plugin，加上 settings 範本列為必裝的官方外掛（範本不存在時沒有官方外掛項目）。
    $pluginIds = New-Object 'System.Collections.Generic.List[string]'
    foreach ($spec in $specs) { $pluginIds.Add($spec.Id) }
    $officialReason = $null
    try { foreach ($officialId in @(Get-ClaudeRequiredOfficialPlugin -TemplatePath $Expected.SettingsTemplatePath)) { $pluginIds.Add($officialId) } }
    catch { $officialReason = 'settings 範本無法讀取：' + $_.Exception.Message }
    if ($null -ne $officialReason) {
        $items.Add((New-SetupCheckItem -Category 'plugin' -Path $Expected.SettingsTemplatePath -Expected '必裝官方外掛清單可讀取' -Actual $null -Status 'unknown' -Detail $officialReason))
    }
    foreach ($pluginId in $pluginIds) {
        $isOfficial = $pluginId.EndsWith('@claude-plugins-official', [System.StringComparison]::OrdinalIgnoreCase)
        $installHint = if ($isOfficial) { '；重新執行 Setup 會安裝' } else { '' }
        if ($null -ne $pluginReason) {
            $items.Add((New-SetupCheckItem -Category 'plugin' -Path $pluginId -Expected 'enabled' -Actual $null -Status 'unknown' -Detail $pluginReason))
            continue
        }
        $installed = @($plugins | Where-Object { (Get-ClaudeProperty $_ 'id') -eq $pluginId -or (Get-ClaudeProperty $_ 'name') -eq $pluginId })
        if ($installed.Count -eq 0 -and $isOfficial -and $Expected.ContainsKey('ClaudeDirectory') -and (Test-ClaudePluginUserDisabled -SettingsPath (Join-Path $Expected.ClaudeDirectory 'settings.json') -PluginId $pluginId)) {
            # 使用者在 settings.json 把官方外掛設為 false 且尚未安裝：Setup 不會安裝，視為符合。
            $items.Add((New-SetupCheckItem -Category 'plugin' -Path $pluginId -Expected 'enabled' -Actual 'disabled' -Status 'ok' -Detail '使用者已在 settings.json 的 enabledPlugins 設為 false，Setup 不會安裝'))
        }
        elseif ($installed.Count -eq 0) {
            $items.Add((New-SetupCheckItem -Category 'plugin' -Path $pluginId -Expected 'enabled' -Actual $null -Status 'missing' -Detail ('未安裝' + $installHint)))
        }
        elseif ($installed.Count -gt 1) {
            $items.Add((New-SetupCheckItem -Category 'plugin' -Path $pluginId -Expected 'enabled' -Actual $null -Status 'unknown' -Detail 'plugin 清單含重複識別'))
        }
        elseif ((Get-ClaudeProperty $installed[0] 'enabled') -eq $true) {
            $items.Add((New-SetupCheckItem -Category 'plugin' -Path $pluginId -Expected 'enabled' -Actual 'enabled' -Status 'ok'))
        }
        elseif ((Get-ClaudeProperty $installed[0] 'enabled') -eq $false -and $isOfficial -and $Expected.ContainsKey('ClaudeDirectory') -and (Test-ClaudePluginUserDisabled -SettingsPath (Join-Path $Expected.ClaudeDirectory 'settings.json') -PluginId $pluginId)) {
            # 使用者在 settings.json 把官方外掛設為 false 是他的決定，Setup 不會重新啟用，不算缺少。
            $items.Add((New-SetupCheckItem -Category 'plugin' -Path $pluginId -Expected 'enabled' -Actual 'disabled' -Status 'ok' -Detail '你已在 settings.json 的 enabledPlugins 設為 false，Setup 不會啟用'))
        }
        elseif ((Get-ClaudeProperty $installed[0] 'enabled') -eq $false) {
            $items.Add((New-SetupCheckItem -Category 'plugin' -Path $pluginId -Expected 'enabled' -Actual 'disabled' -Status 'missing' -Detail ('已安裝但未啟用' + $installHint)))
        }
        else {
            $items.Add((New-SetupCheckItem -Category 'plugin' -Path $pluginId -Expected 'enabled' -Actual $null -Status 'unknown' -Detail '無法判定 plugin 啟用狀態'))
        }
    }
    return @($items.ToArray())
}

function Get-SetupCheckLegacyHookItem {
    param([hashtable]$Expected)

    $settingsPath = Join-Path $Expected.ClaudeDirectory 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return (New-SetupCheckItem -Category 'legacy-hook' -Path $settingsPath -Expected '無舊 hook 項目' -Actual '無設定檔' -Status 'ok')
    }
    try {
        $settings = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json -ErrorAction Stop
        $count = 0
        $hooksProperty = $settings.PSObject.Properties['hooks']
        if ($null -ne $hooksProperty -and $null -ne $hooksProperty.Value) {
            $postProperty = $hooksProperty.Value.PSObject.Properties['PostToolUse']
            if ($null -ne $postProperty) {
                foreach ($group in @($postProperty.Value)) {
                    $itemsProperty = $group.PSObject.Properties['hooks']
                    if ($null -eq $itemsProperty) { continue }
                    foreach ($item in @($itemsProperty.Value)) {
                        $text = ((@(Get-ClaudeProperty $item 'command') + @(Get-ClaudeProperty $item 'args')) -join ' ').Replace('\', '/')
                        if ($text -like $Expected.LegacyHookPattern) { $count++ }
                    }
                }
            }
        }
        if ($count -eq 0) {
            return (New-SetupCheckItem -Category 'legacy-hook' -Path $settingsPath -Expected '無舊 hook 項目' -Actual '無' -Status 'ok')
        }
        return (New-SetupCheckItem -Category 'legacy-hook' -Path $settingsPath -Expected '無舊 hook 項目' -Actual ([string]$count + ' 筆') -Status 'mismatch' -Detail 'settings.json 仍有舊 hook 註冊，Setup 會在 plugin 啟用後移除')
    }
    catch {
        return (New-SetupCheckItem -Category 'legacy-hook' -Path $settingsPath -Expected '無舊 hook 項目' -Actual $null -Status 'unknown' -Detail ('讀取 settings.json 失敗：' + $_.Exception.Message))
    }
}

function Get-SetupCheckGitItem {
    param([hashtable]$Expected)

    $items = New-Object 'System.Collections.Generic.List[object]'
    $configRoot = $Expected.ConfigRoot
    $hooksPath = $Expected.HooksPath
    $isRepo = $false
    $gitUnavailable = $false
    if (Test-Path -LiteralPath $configRoot -PathType Container) {
        $probe = Get-SetupCheckGitValue -GitArgument @('-C', $configRoot, 'rev-parse', '--git-dir')
        $isRepo = ($probe.ExitCode -eq 0)
        $gitUnavailable = ($probe.ExitCode -eq -1)
    }
    if (-not $isRepo) {
        $hooksDetail = if ($gitUnavailable) { '無法執行 git，無法讀取 core.hooksPath' } else { '設定來源目錄不是 git 工作樹，無法讀取 core.hooksPath' }
        $items.Add((New-SetupCheckItem -Category 'git-hooks-path' -Path $configRoot -Expected $hooksPath -Actual $null -Status 'unknown' -Detail $hooksDetail))
    }
    else {
        $hooks = Get-SetupCheckGitValue -GitArgument @('-C', $configRoot, 'config', '--local', '--get', 'core.hooksPath')
        if ($hooks.ExitCode -eq 1) {
            $items.Add((New-SetupCheckItem -Category 'git-hooks-path' -Path $configRoot -Expected $hooksPath -Actual $null -Status 'missing' -Detail 'core.hooksPath 未設定'))
        }
        elseif ($hooks.ExitCode -ne 0) {
            $items.Add((New-SetupCheckItem -Category 'git-hooks-path' -Path $configRoot -Expected $hooksPath -Actual $null -Status 'unknown' -Detail ('讀取 core.hooksPath 失敗，結束碼：' + $hooks.ExitCode)))
        }
        elseif ($hooks.Value -ceq $hooksPath) {
            $items.Add((New-SetupCheckItem -Category 'git-hooks-path' -Path $configRoot -Expected $hooksPath -Actual $hooks.Value -Status 'ok'))
        }
        else {
            $items.Add((New-SetupCheckItem -Category 'git-hooks-path' -Path $configRoot -Expected $hooksPath -Actual $hooks.Value -Status 'wrong-target' -Detail 'core.hooksPath 指向其他位置'))
        }
    }

    $excludesPath = $Expected.GitExcludesFile
    $excludes = Get-SetupCheckGitValue -GitArgument @('config', '--global', '--get', 'core.excludesFile')
    if ($excludes.ExitCode -eq 1) {
        $items.Add((New-SetupCheckItem -Category 'git-excludes' -Path 'core.excludesFile' -Expected $excludesPath -Actual $null -Status 'missing' -Detail 'core.excludesFile 未設定'))
    }
    elseif ($excludes.ExitCode -ne 0) {
        $items.Add((New-SetupCheckItem -Category 'git-excludes' -Path 'core.excludesFile' -Expected $excludesPath -Actual $null -Status 'unknown' -Detail ('讀取 core.excludesFile 失敗，結束碼：' + $excludes.ExitCode)))
    }
    else {
        $same = $false
        try { $same = [System.String]::Equals([System.IO.Path]::GetFullPath($excludes.Value), [System.IO.Path]::GetFullPath($excludesPath), [System.StringComparison]::OrdinalIgnoreCase) } catch { $same = $false }
        if ($same) {
            $items.Add((New-SetupCheckItem -Category 'git-excludes' -Path 'core.excludesFile' -Expected $excludesPath -Actual $excludes.Value -Status 'ok'))
        }
        else {
            $items.Add((New-SetupCheckItem -Category 'git-excludes' -Path 'core.excludesFile' -Expected $excludesPath -Actual $excludes.Value -Status 'wrong-target' -Detail 'core.excludesFile 指向其他位置'))
        }
    }
    return @($items.ToArray())
}

function Get-SetupCheckCodexItem {
    param(
        [hashtable]$Expected,
        [System.Collections.Generic.List[string]]$Note
    )

    $items = New-Object 'System.Collections.Generic.List[object]'
    $configRoot = $Expected.ConfigRoot
    $registryPath = Get-CodexProfileRegistryPath -RepoRoot $configRoot
    $generatedDirectory = Get-CodexProfileGeneratedDirectory -RepoRoot $configRoot

    $specs = @()
    $specError = $null
    try { $specs = @(Read-CodexProfileSpec -RegistryPath $registryPath) }
    catch { $specError = $_.Exception.Message }

    $accounts = @()
    $machinePath = Join-Path $configRoot '.local\machine.json'
    $machineError = $null
    try { $accounts = @(Read-CodexAccountConfiguration -MachineConfigPath $machinePath) }
    catch { $machineError = $_.Exception.Message }
    if ($null -ne $machineError) {
        $items.Add((New-SetupCheckItem -Category 'codex-machine' -Path $machinePath -Expected '帳號登記可讀取' -Actual $null -Status 'unknown' -Detail $machineError))
    }

    if ($null -ne $specError) {
        $items.Add((New-SetupCheckItem -Category 'codex-profile-generated' -Path $registryPath -Expected '登錄表可讀取' -Actual $null -Status 'unknown' -Detail $specError))
        return @($items.ToArray())
    }

    $changes = @()
    try { $changes = @(Sync-CodexProfileGeneratedFile -RegistryPath $registryPath -OutputDirectory $generatedDirectory -CheckOnly) }
    catch {
        $items.Add((New-SetupCheckItem -Category 'codex-profile-generated' -Path $generatedDirectory -Expected '產生檔與登錄表一致' -Actual $null -Status 'unknown' -Detail $_.Exception.Message))
        $changes = $null
    }
    if ($null -ne $changes) {
        if ($changes.Count -eq 0) {
            $items.Add((New-SetupCheckItem -Category 'codex-profile-generated' -Path $generatedDirectory -Expected '產生檔與登錄表一致' -Actual '一致' -Status 'ok'))
        }
        foreach ($change in $changes) {
            $status = if ($change.action -ceq 'created') { 'missing' } else { 'mismatch' }
            $items.Add((New-SetupCheckItem -Category 'codex-profile-generated' -Path $change.path -Expected '與登錄表一致' -Actual $change.action -Status $status -Detail ('產生檔與登錄表不一致（' + $change.action + '）；須在登錄表所在 checkout 重新產生')))
        }
    }

    if ($null -eq $machineError -and $accounts.Count -eq 0) {
        $Note.Add('沒有登記的派工帳號（.local\machine.json 無 codex_accounts），未檢查帳號目錄的檔位設定檔連結。')
    }
    foreach ($account in $accounts) {
        foreach ($state in @(Get-CodexProfileAccountState -AccountHome $account.codex_home -ProfileDirectory $generatedDirectory -Spec $specs)) {
            $path = $state.path
            switch ($state.state) {
                'ok' { $items.Add((New-SetupCheckItem -Category 'codex-profile-link' -Path $path -Expected $state.expected_target -Actual $state.actual_target -Status 'ok' -Detail ('帳號 ' + $account.name))) }
                'missing' { $items.Add((New-SetupCheckItem -Category 'codex-profile-link' -Path $path -Expected $state.expected_target -Actual $null -Status 'missing' -Detail ('帳號 ' + $account.name + '；連結不存在'))) }
                default {
                    $actual = if ($null -ne $state.actual_target) { [string]$state.actual_target } else { [string]$state.kind }
                    $items.Add((New-SetupCheckItem -Category 'codex-profile-link' -Path $path -Expected $state.expected_target -Actual $actual -Status 'wrong-target' -Detail ('帳號 ' + $account.name + '；狀態 ' + $state.state)))
                }
            }
        }
        # 登錄表宣告 mcpServers 而省略 command 的伺服器：指令由帳號目錄 config.toml 提供（enabled = false），缺少時該檔位載入失敗。
        foreach ($spec in $specs) {
            foreach ($serverName in @(Get-CodexMcpLocalCommandServer -Spec $spec)) {
                $configPath = Join-Path $account.codex_home 'config.toml'
                if (@(Get-CodexMcpAccountConfigFinding -AccountHome $account.codex_home -Spec $spec) -ccontains $serverName) {
                    $items.Add((New-SetupCheckItem -Category 'codex-mcp-command' -Path $configPath -Expected ('[mcp_servers.' + $serverName + '] 含 command') -Actual $null -Status 'missing' -Detail ('帳號 ' + $account.name + '；檔位 ' + $spec.Profile + ' 缺少指令，重跑 Setup 補上')))
                }
                else {
                    $items.Add((New-SetupCheckItem -Category 'codex-mcp-command' -Path $configPath -Expected ('[mcp_servers.' + $serverName + '] 含 command') -Actual '有' -Status 'ok' -Detail ('帳號 ' + $account.name)))
                }
            }
        }
    }
    return @($items.ToArray())
}

function Get-SetupCheckPrerequisiteItem {
    # 前置軟體：pwsh 7、git、Claude Code CLI。缺少時 detail 附補救方式。登入狀態沒有唯讀的判定方式，不在檢查範圍。WSL 只有 infra-lab 的登記需要，由 Register-McpServer.ps1 -Check 檢查。
    $items = New-Object 'System.Collections.Generic.List[object]'
    $version = $PSVersionTable.PSVersion
    if ($version.Major -ge 7) {
        $items.Add((New-SetupCheckItem -Category 'prerequisite' -Path 'pwsh' -Expected '7 以上' -Actual $version.ToString() -Status 'ok'))
    }
    else {
        $items.Add((New-SetupCheckItem -Category 'prerequisite' -Path 'pwsh' -Expected '7 以上' -Actual $version.ToString() -Status 'mismatch' -Detail '安裝 PowerShell 7：winget install Microsoft.PowerShell'))
    }

    $gitFound = $null -ne (Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue)
    if ($gitFound) { $items.Add((New-SetupCheckItem -Category 'prerequisite' -Path 'git' -Expected '可執行' -Actual '找到' -Status 'ok')) }
    else { $items.Add((New-SetupCheckItem -Category 'prerequisite' -Path 'git' -Expected '可執行' -Actual $null -Status 'missing' -Detail '找不到 git；安裝命令：winget install Git.Git')) }

    $claudeFound = $null -ne (Get-Command -Name 'claude' -CommandType Application -ErrorAction SilentlyContinue)
    if ($claudeFound) { $items.Add((New-SetupCheckItem -Category 'prerequisite' -Path 'claude' -Expected '可執行' -Actual '找到' -Status 'ok')) }
    else { $items.Add((New-SetupCheckItem -Category 'prerequisite' -Path 'claude' -Expected '可執行' -Actual $null -Status 'missing' -Detail '找不到 Claude Code CLI；安裝命令：winget install Anthropic.ClaudeCode，安裝後自行登入')) }
    return @($items.ToArray())
}

function Get-SetupCheckClaudeSettingsItem {
    # settings.json 共用部分：範本的每個頂層鍵一項。與範本值不同的項目由使用者保留，只寫入備註；授權與偏好不在範本內。
    param(
        [hashtable]$Expected,
        [System.Collections.Generic.List[string]]$Note
    )

    $templatePath = $Expected.SettingsTemplatePath
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        $Note.Add('settings 共用範本不存在（' + $templatePath + '），未檢查 settings.json 的共用部分。')
        return @()
    }
    $template = Read-ClaudeSettingsFile -Path $templatePath
    if ($null -ne $template.Error) {
        return @(New-SetupCheckItem -Category 'claude-settings' -Path $templatePath -Expected 'settings 範本可讀取' -Actual $null -Status 'unknown' -Detail ('settings 範本無法讀取（原因：' + $template.Error + '）'))
    }
    $settings = Read-ClaudeSettingsFile -Path $Expected.SettingsPath
    if (-not $settings.Exists) {
        return @(New-SetupCheckItem -Category 'claude-settings' -Path $Expected.SettingsPath -Expected '含範本的共用設定' -Actual $null -Status 'missing' -Detail 'settings.json 不存在；重新執行 Setup 會依範本建立')
    }
    if ($null -ne $settings.Error) {
        return @(New-SetupCheckItem -Category 'claude-settings' -Path $Expected.SettingsPath -Expected '含範本的共用設定' -Actual $null -Status 'unknown' -Detail ('settings.json 無法讀取（原因：' + $settings.Error + '）；Setup 不會改寫無法讀取的 settings.json'))
    }

    $items = New-Object 'System.Collections.Generic.List[object]'
    $plan = Get-ClaudeSettingsPlan -Existing $settings.Object -Template $template.Object
    foreach ($property in $template.Object.PSObject.Properties) {
        $key = $property.Name
        $missingPaths = @($plan.Changes | Where-Object { $_.Kind -eq 'add' -and ($_.Path -ceq $key -or $_.Path.StartsWith($key + '.') -or $_.Path.StartsWith($key + '[')) } | ForEach-Object { $_.Path })
        $itemPath = 'settings.json#' + $key
        if ($missingPaths.Count -eq 0) { $items.Add((New-SetupCheckItem -Category 'claude-settings' -Path $itemPath -Expected '含範本的設定' -Actual '符合' -Status 'ok')) }
        else { $items.Add((New-SetupCheckItem -Category 'claude-settings' -Path $itemPath -Expected '含範本的設定' -Actual $null -Status 'missing' -Detail ('缺少：' + ($missingPaths -join '、') + '；重新執行 Setup 套用範本'))) }
    }
    $keptPaths = @($plan.Changes | Where-Object { $_.Kind -eq 'kept-differs' } | ForEach-Object { $_.Path })
    if ($keptPaths.Count -gt 0) {
        $Note.Add('settings.json 以下項目的值與範本不同，Setup 保留你的值，不視為缺少：' + ($keptPaths -join '、') + '。')
    }
    return @($items.ToArray())
}

function Invoke-SetupCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Expected,
        [switch]$AsJson
    )

    $items = New-Object 'System.Collections.Generic.List[object]'
    $notes = New-Object 'System.Collections.Generic.List[string]'

    foreach ($item in @(Get-SetupCheckPrerequisiteItem)) { $items.Add($item) }
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $items.Add((Get-SetupCheckLongPathItem))
    }

    foreach ($sourcePath in @($Expected.MainInstructions, $Expected.GitExcludesFile)) {
        if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
            $items.Add((New-SetupCheckItem -Category 'config-root' -Path $sourcePath -Expected '檔案存在' -Actual '存在' -Status 'ok'))
        }
        else {
            $items.Add((New-SetupCheckItem -Category 'config-root' -Path $sourcePath -Expected '檔案存在' -Actual $null -Status 'missing' -Detail '設定來源檔案不存在'))
        }
    }

    foreach ($directory in $Expected.ToolDirectories) {
        if (Test-Path -LiteralPath $directory -PathType Container) {
            $items.Add((New-SetupCheckItem -Category 'tool-dir' -Path $directory -Expected '目錄存在' -Actual '存在' -Status 'ok'))
        }
        else {
            $items.Add((New-SetupCheckItem -Category 'tool-dir' -Path $directory -Expected '目錄存在' -Actual $null -Status 'missing' -Detail '工具目錄不存在'))
        }
    }

    foreach ($entry in $Expected.Links) {
        $items.Add((Test-SetupCheckLink -Category 'link' -LinkPath $entry.Link -TargetPath (Join-Path $Expected.ConfigRoot $entry.Source)))
    }

    $orphans = @(Get-BrokenConfigLink -SweepRoot $Expected.SweepRoots -ConfigRoot $Expected.ConfigRoot)
    if ($orphans.Count -eq 0) {
        $items.Add((New-SetupCheckItem -Category 'orphan' -Path ($Expected.SweepRoots -join '; ') -Expected '無斷鍊孤兒' -Actual '無' -Status 'ok'))
    }
    foreach ($orphan in $orphans) {
        $target = (@(if ($orphan.Target) { $orphan.Target } else { $orphan.LinkTarget }) -join '')
        $items.Add((New-SetupCheckItem -Category 'orphan' -Path $orphan.FullName -Expected '連結已移除或來源存在' -Actual $target -Status 'wrong-target' -Detail '指向 configRoot 但來源已不存在'))
    }

    foreach ($item in @(Get-SetupCheckPluginItem -Expected $Expected)) { $items.Add($item) }
    $items.Add((Get-SetupCheckLegacyHookItem -Expected $Expected))
    foreach ($item in @(Get-SetupCheckClaudeSettingsItem -Expected $Expected -Note $notes)) { $items.Add($item) }
    foreach ($item in @(Get-SetupCheckGitItem -Expected $Expected)) { $items.Add($item) }
    foreach ($item in @(Get-SetupCheckCodexItem -Expected $Expected -Note $notes)) { $items.Add($item) }

    $summary = [ordered]@{ total = $items.Count }
    foreach ($status in @('ok', 'missing', 'wrong-target', 'mismatch', 'unknown')) {
        $summary[$status] = @($items | Where-Object { $_.status -ceq $status }).Count
    }
    $allOk = ($summary['ok'] -eq $summary['total'])

    if ($AsJson) {
        $result = [ordered]@{
            mode    = 'check'
            allOk   = $allOk
            summary = $summary
            items   = @($items.ToArray())
            notes   = @($notes.ToArray())
        }
        Write-Host ($result | ConvertTo-Json -Depth 6)
        if ($allOk) { return 0 } else { return 1 }
    }

    $userProfile = [string]$env:USERPROFILE
    $display = { param($text) if ([string]::IsNullOrEmpty($text) -or [string]::IsNullOrEmpty($userProfile)) { $text } else { $text.Replace($userProfile, '~') } }
    Write-Host ("`n>>> Setup 唯讀檢查（-Check）：只讀取現況，不建立、不修改、不刪除任何東西。") -ForegroundColor Cyan
    foreach ($category in $script:SetupCheckCategoryLabel.Keys) {
        $group = @($items | Where-Object { $_.category -ceq $category })
        if ($group.Count -eq 0) { continue }
        Write-Host ("`n" + $script:SetupCheckCategoryLabel[$category]) -ForegroundColor Cyan
        foreach ($item in $group) {
            $color = switch ($item.status) { 'ok' { 'DarkGreen' } 'unknown' { 'Yellow' } default { 'Red' } }
            $line = '  [' + $item.label + '] ' + (& $display $item.path)
            if ($item.status -cne 'ok') {
                if (-not [string]::IsNullOrEmpty($item.expected)) { $line += '；預期：' + (& $display $item.expected) }
                if (-not [string]::IsNullOrEmpty($item.actual)) { $line += '；實際：' + (& $display $item.actual) }
                if (-not [string]::IsNullOrEmpty($item.detail)) { $line += '；' + $item.detail }
            }
            Write-Host $line -ForegroundColor $color
        }
    }
    foreach ($noteText in $notes) { Write-Host ("`n備註：" + $noteText) -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host ('統計：共 {0} 項，符合 {1}、缺少 {2}、指向錯誤位置 {3}、內容不符 {4}、無法判定 {5}。' -f $summary['total'], $summary['ok'], $summary['missing'], $summary['wrong-target'], $summary['mismatch'], $summary['unknown']) -ForegroundColor $(if ($allOk) { 'Green' } else { 'Yellow' })
    if (-not $allOk) { Write-Host '有項目不符或無法判定；重新執行 Setup（系統管理員 pwsh）可補齊缺少的項目。' -ForegroundColor Yellow }
    if ($allOk) { return 0 } else { return 1 }
}
