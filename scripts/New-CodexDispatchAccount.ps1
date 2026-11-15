#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateScript({ $_ -cmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' })]
    [string]$Name,
    [string[]]$ProjectPath = @()
)

. (Join-Path $PSScriptRoot 'dispatch\codex-account-config.ps1')
. (Join-Path $PSScriptRoot 'codex-run\45-profile-sync.ps1')

function Get-AccountProfileFileName {
    # 檔位檔名的單一來源是執行者登錄表。
    return @(Read-CodexProfileSpec -RegistryPath (Get-CodexProfileRegistryPath) | ForEach-Object { $_.FileName })
}

function Write-AccountStatus {
    param([string]$Item, [string]$Path, [string]$Status)
    Write-Host ("{0}: {1} [{2}]" -f $Item, $Path, $Status)
}

function Get-AccountMachinePlan {
    param([string]$Path, [string]$Name, [string]$accountHomePath)
    $item = Get-AccountItem $Path; $original = $null; $exists = $false
    if ($null -eq $item) { $machine = [pscustomobject]@{ schema = 'ai-agents.machine.v1'; codex_accounts = @() } }
    else {
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "machine 類型錯誤：$Path" }
        $original = [IO.File]::ReadAllBytes($Path)
        $machine = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($original))
        if ($machine -isnot [pscustomobject] -or $null -eq $machine.PSObject.Properties['schema'] -or $machine.schema -cne 'ai-agents.machine.v1') { throw "machine schema 錯誤：$Path" }
        if ($null -eq $machine.PSObject.Properties['codex_accounts']) { $machine | Add-Member -NotePropertyName codex_accounts -NotePropertyValue @() }
        if ($machine.codex_accounts -isnot [array]) { throw 'codex_accounts 必須是陣列。' }
    }
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $homes = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($account in $machine.codex_accounts) {
        if ($account -isnot [pscustomobject] -or @($account.PSObject.Properties).Count -ne 2 -or $null -eq $account.PSObject.Properties['name'] -or $null -eq $account.PSObject.Properties['codex_home'] -or $account.name -isnot [string] -or $account.name -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or $account.codex_home -isnot [string] -or -not [IO.Path]::IsPathRooted($account.codex_home)) { throw '帳號登記格式錯誤。' }
        $accountHome = Get-AccountPath $account.codex_home
        $ancestor = $accountHome
        while ($ancestor) {
            $ancestorItem = Get-AccountItem $ancestor
            if ($null -eq $ancestorItem -or -not $ancestorItem.PSIsContainer -or ($ancestorItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "帳號路徑不存在或包含連結：$ancestor" }
            $parent = Split-Path -Parent $ancestor
            if ($parent -eq $ancestor) { break }
            $ancestor = $parent
        }
        if (-not $names.Add($account.name) -or -not $homes.Add($accountHome)) { throw '帳號登記重複。' }
        $sameName = [string]::Equals($Name, $account.name, [StringComparison]::OrdinalIgnoreCase)
        $sameHome = [string]::Equals($accountHomePath, $accountHome, [StringComparison]::OrdinalIgnoreCase)
        if ($sameName -xor $sameHome) { throw '帳號名稱或路徑與既有登記衝突。' }
        if ($sameName -and $sameHome) { $exists = $true }
    }
    if (-not $exists) { $machine.codex_accounts = @($machine.codex_accounts) + @([pscustomobject]@{ name = $Name; codex_home = $accountHomePath }) }
    $json = ConvertTo-Json -InputObject $machine -Depth 100
    $null = ConvertFrom-Json -InputObject $json
    return @{ Original = $original; Bytes = [Text.Encoding]::UTF8.GetBytes($json); Exists = $exists }
}

function Get-AccountLinkConflict {
    param([string]$Path, [string]$Target, [string]$Type)
    $item = Get-AccountItem $Path
    if ($null -eq $item -or -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
    $description = Get-AccountItemDescription -Path $Path
    $linkMatches = $item.LinkType -eq $Type
    if ($linkMatches) {
        $linkTarget = $item.Target -join ''
        if (-not [IO.Path]::IsPathRooted($linkTarget)) { $linkTarget = Join-Path (Split-Path -Parent (Get-AccountPath $Path)) $linkTarget }
        $linkMatches = [string]::Equals((Get-AccountPath $linkTarget), (Get-AccountPath $Target), [StringComparison]::OrdinalIgnoreCase)
    }
    if ($linkMatches) { return $null }
    return ("連結類型或目標衝突：$Path；找到：" + $description.text + "；預期：LinkType=$Type，Target=$Target。" + (Get-AccountLinkRepairHint -Path $Path))
}

function Get-AccountProfileTypeConflict {
    param([string]$Path, [string]$Target)
    $item = Get-AccountItem $Path
    if ($null -eq $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
    $description = Get-AccountItemDescription -Path $Path
    return ("profile 類型錯誤：$Path；找到：" + $description.text + "；預期：LinkType=SymbolicLink，Target=$Target。" + (Get-AccountLinkRepairHint -Path $Path))
}

function Test-AccountLinkPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AccountHome, [Parameter(Mandatory)][string]$Source, [string[]]$ProfileFileName = (Get-AccountProfileFileName))
    $conflicts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($profile in $ProfileFileName) {
        $dest = Join-Path $AccountHome $profile
        $target = Join-Path $Source $profile
        $conflict = Get-AccountProfileTypeConflict -Path $dest -Target $target
        if ($null -eq $conflict) { $conflict = Get-AccountLinkConflict -Path $dest -Target $target -Type SymbolicLink }
        if ($null -ne $conflict) { $conflicts.Add($conflict) }
    }
    return @($conflicts.ToArray())
}
function Set-AccountLink {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path, [string]$Target, [string]$Type, [string]$StatusName = $Type)
    if ([IO.Path]::GetFileName($Path) -ieq 'rules' -or [IO.Path]::GetFileName($Target) -ieq 'rules') { throw '禁止連結 rules 目錄。' }
    $item = Get-AccountItem $Path; $status = 'created'; $backup = $null
    if ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $conflict = Get-AccountLinkConflict -Path $Path -Target $Target -Type $Type
            if ($null -ne $conflict) { throw $conflict }
            Write-AccountStatus $StatusName $Path 'exists'; return 'exists'
        }
        $backup = $Path + '.bak-' + (Get-Date -Format 'yyyyMMdd_HHmmss')
        if ($null -ne (Get-AccountItem $backup)) { throw "備份已存在：$backup" }
        $status = 'repaired'
    }
    if (-not $PSCmdlet.ShouldProcess($Path, "建立 $Type")) { Write-AccountStatus $StatusName $Path 'skipped'; return 'skipped' }
    if ($null -ne $backup) {
        if ($item.PSIsContainer) { [IO.Directory]::Move($Path, $backup) } else { [IO.File]::Move($Path, $backup) }
    }
    try { $null = New-Item -ItemType $Type -Path $Path -Target $Target }
    catch { throw "建立 $Type 失敗：$Path；備份：$backup；$($_.Exception.Message)。請以具備建立 Symbolic Link 權限的 PowerShell 重新執行。" }
    Write-AccountStatus $StatusName $Path $status
    return $status
}

function Undo-AccountCreation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Created)

    # 失敗時只回復本次執行建立的項目（連結、config.toml、帳號目錄），由後往前。既有的東西一律不動；
    # 帳號目錄只在本次建立且已空時才移除。
    for ($index = $Created.Count - 1; $index -ge 0; $index--) {
        $entry = $Created[$index]
        try {
            $item = Get-AccountItem $entry.path
            if ($null -eq $item) { continue }
            if ($entry.kind -ceq 'home') {
                if ($item.PSIsContainer -and @(Get-ChildItem -LiteralPath $entry.path -Force).Count -eq 0) { [IO.Directory]::Delete($entry.path) }
                else { Write-AccountStatus 'home' $entry.path 'kept（不是空目錄，未移除）'; continue }
            }
            elseif (-not $item.PSIsContainer) { [IO.File]::Delete($entry.path) }
            else { continue }
            Write-AccountStatus $entry.kind $entry.path 'rolled-back'
        }
        catch { Write-AccountStatus $entry.kind $entry.path ('rollback-failed: ' + $_.Exception.Message) }
    }
}

function New-CodexAccount {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateScript({ $_ -cmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' })][string]$Name,
        [Parameter(Mandatory)][string]$HomeRoot,
        [Parameter(Mandatory)][string]$SourceCodex,
        [Parameter(Mandatory)][string]$MachinePath,
        [string[]]$ProjectPath = @(),
        [string]$ProfileSourceDirectory = (Get-CodexProfileGeneratedDirectory -RepoRoot (Get-CodexProfileMainCheckoutRoot))
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw '僅支援 Windows。' }
    $accountHomePath = Get-AccountPath (Join-Path $HomeRoot ('.codex-' + $Name))
    $source = Get-AccountPath $SourceCodex
    $profileSource = Get-AccountPath $ProfileSourceDirectory
    $profileFiles = @(Get-AccountProfileFileName)
    if ([string]::Equals($accountHomePath, $source, [StringComparison]::OrdinalIgnoreCase)) { throw '不得登記來源 Codex home。' }
    $machineDir = Split-Path -Parent $MachinePath
    $machineDirItem = Get-AccountItem $machineDir
    if ($null -ne $machineDirItem -and (-not $machineDirItem.PSIsContainer -or ($machineDirItem.Attributes -band [IO.FileAttributes]::ReparsePoint))) { throw "machine 目錄類型錯誤：$machineDir" }
    if ($null -eq $machineDirItem) {
        try {
            foreach ($namePart in $profileFiles) { if (-not (Test-Path -LiteralPath (Join-Path $profileSource $namePart) -PathType Leaf)) { throw "檔位產生檔不存在：$namePart（請先執行 .githooks\Update-CodexProfiles.ps1）" } }
            $preflightKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
            foreach ($project in $ProjectPath) {
                if (-not (Test-Path -LiteralPath $project -PathType Container)) { throw "專案目錄不存在：$project" }
                $key = (Get-AccountPath $project).ToLowerInvariant()
                if ($key -match "['\x00-\x1f\x7f]") { throw "專案路徑含不支援字元：$project" }
                $null = $preflightKeys.Add($key)
            }
            $preflightHome = Get-AccountItem $accountHomePath
            if ($null -ne $preflightHome -and (-not $preflightHome.PSIsContainer -or ($preflightHome.Attributes -band [IO.FileAttributes]::ReparsePoint))) { throw "帳號 home 類型錯誤：$accountHomePath" }
            $null = Get-AccountConfigPlan (Join-Path $accountHomePath 'config.toml') @($preflightKeys)
            $preflightLinkConflicts = @(Test-AccountLinkPlan -AccountHome $accountHomePath -Source $profileSource -ProfileFileName $profileFiles)
            if ($preflightLinkConflicts.Count -gt 0) { throw ($preflightLinkConflicts -join [Environment]::NewLine) }
            $null = Get-AccountMachinePlan $MachinePath $Name $accountHomePath
        } catch { Write-Host ("failed: preflight: {0}" -f $_.Exception.Message); throw }
        if ($PSCmdlet.ShouldProcess($machineDir, '建立 machine 目錄')) {
            $null = New-Item -ItemType Directory -Path $machineDir
            Write-AccountStatus 'machine 目錄' $machineDir 'created'
        } else { Write-AccountStatus 'machine 目錄（將建立）' $machineDir 'skipped' }
    }
    $lock = $null; $step = 'preflight'; $lockCreated = $false; $completed = $false
    $created = New-Object 'System.Collections.Generic.List[object]'
    $machineDirCreated = ($null -eq $machineDirItem)
    $lockPath = Join-Path $machineDir 'codex-account.lock'
    try {
        if (-not $WhatIfPreference) {
            try {
                $lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                $lockCreated = $true
            } catch [IO.IOException] {
                if (-not [IO.File]::Exists($lockPath)) { throw }
                $lock = [IO.File]::Open($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            }
        }
        foreach ($namePart in $profileFiles) { if (-not (Test-Path -LiteralPath (Join-Path $profileSource $namePart) -PathType Leaf)) { throw "檔位產生檔不存在：$namePart（請先執行 .githooks\Update-CodexProfiles.ps1）" } }
        $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($project in $ProjectPath) {
            if (-not (Test-Path -LiteralPath $project -PathType Container)) { throw "專案目錄不存在：$project" }
            $key = (Get-AccountPath $project).ToLowerInvariant()
            if ($key -match "['\x00-\x1f\x7f]") { throw "專案路徑含不支援字元：$project" }
            $null = $keys.Add($key)
        }
        $homeItem = Get-AccountItem $accountHomePath
        if ($null -ne $homeItem -and (-not $homeItem.PSIsContainer -or ($homeItem.Attributes -band [IO.FileAttributes]::ReparsePoint))) { throw "帳號 home 類型錯誤：$accountHomePath" }
        $configPath = Join-Path $accountHomePath 'config.toml'
        $config = Get-AccountConfigPlan $configPath @($keys)
        $machine = Get-AccountMachinePlan $MachinePath $Name $accountHomePath
        $linkConflicts = @(Test-AccountLinkPlan -AccountHome $accountHomePath -Source $profileSource -ProfileFileName $profileFiles)
        if ($linkConflicts.Count -gt 0) { throw ($linkConflicts -join [Environment]::NewLine) }
        $step = 'home'
        if ($null -eq $homeItem) {
            if ($PSCmdlet.ShouldProcess($accountHomePath, '建立帳號目錄')) { $null = New-Item -ItemType Directory -Path $accountHomePath; $created.Add([pscustomobject]@{ kind = 'home'; path = $accountHomePath }); Write-AccountStatus 'home' $accountHomePath 'created' } else { Write-AccountStatus 'home' $accountHomePath 'skipped' }
        } else { Write-AccountStatus 'home' $accountHomePath 'exists' }
        $step = 'config'
        if ($config.Changed) {
            Set-AccountAtomicFile -Path $configPath -Bytes $config.Bytes -Original $config.Original -WhatIf:$WhatIfPreference
            $status = if ($WhatIfPreference) { 'skipped' } elseif ($null -eq $config.Original) { 'created' } else { 'repaired' }
            if ($status -ceq 'created') { $created.Add([pscustomobject]@{ kind = 'config'; path = $configPath }) }
            Write-AccountStatus 'config' $configPath $status
        } else { Write-AccountStatus 'config' $configPath 'exists' }
        if ($keys.Count -eq 0) { Write-AccountStatus 'trust（未預先信任專案，派工時自動補上）' $configPath 'skipped' }
        foreach ($key in $keys) { $status = if ($WhatIfPreference) { 'skipped' } elseif ($config.Missing -contains $key) { 'created' } else { 'exists' }; Write-AccountStatus 'trust' $key $status }
        $step = 'profiles'
        foreach ($profile in $profileFiles) {
            $dest = Join-Path $accountHomePath $profile
            $profileConflict = Get-AccountProfileTypeConflict -Path $dest -Target (Join-Path $profileSource $profile)
            if ($null -ne $profileConflict) { throw $profileConflict }
            $linkStatus = Set-AccountLink -Path $dest -Target (Join-Path $profileSource $profile) -Type SymbolicLink -StatusName 'profile' -WhatIf:$WhatIfPreference
            if ($linkStatus -ceq 'created') { $created.Add([pscustomobject]@{ kind = 'profile'; path = $dest }) }
        }
        $step = 'machine'
        if ($machine.Exists) { Write-AccountStatus 'machine' $MachinePath 'exists' }
        else {
            Set-AccountAtomicFile -Path $MachinePath -Bytes $machine.Bytes -Original $machine.Original -WhatIf:$WhatIfPreference
            $status = if ($WhatIfPreference) { 'skipped' } elseif ($null -eq $machine.Original) { 'created' } else { 'repaired' }
            Write-AccountStatus 'machine' $MachinePath $status
        }
        $escaped = $accountHomePath.Replace("'", "''''")
        Write-Host ("powershell.exe -NoProfile -Command '`$env:CODEX_HOME = ''{0}''; codex login'" -f $escaped)
        Write-Host '帳號閒置過久 token 會失效，Get-CodexQuota.ps1 或派工回報 401 時，請以同一個登入命令重新登入。'
        $status = if ($WhatIfPreference) { 'skipped' } else { 'ready' }
        Write-AccountStatus 'account' $accountHomePath $status
        $completed = $true
    } catch {
        $failure = $_
        if ($created.Count -gt 0) { Undo-AccountCreation -Created $created }
        Write-Host ("failed: {0}: {1}" -f $step, $failure.Exception.Message)
        if ($created.Count -gt 0) { Write-Host '已回復本次建立的項目；既有的檔案與連結沒有動。修正原因後可重跑。' }
        throw
    }
    finally {
        if ($null -ne $lock) { $lock.Dispose() }
        if ($lockCreated -and -not $completed) { try { [IO.File]::Delete($lockPath) } catch { } }
        # 本次才建立的 machine 目錄：失敗後只在已空時移除。
        if ($machineDirCreated -and -not $completed -and -not $WhatIfPreference) { try { [IO.Directory]::Delete($machineDir) } catch { $null = $_ } }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    try {
        if ([string]::IsNullOrWhiteSpace($Name)) { throw '必須指定 -Name。' }
        $profileRoot = [Environment]::GetFolderPath('UserProfile')
        New-CodexAccount -Name $Name -HomeRoot $profileRoot -SourceCodex (Join-Path $profileRoot '.codex') -MachinePath (Join-Path (Get-CodexProfileMainCheckoutRoot) '.local\machine.json') -ProjectPath $ProjectPath -WhatIf:$WhatIfPreference
        exit 0
    } catch { Write-Error -ErrorRecord $_ -ErrorAction Continue; exit 1 }
}
