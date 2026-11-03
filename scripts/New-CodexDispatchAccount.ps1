#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateScript({ $_ -cmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' })]
    [string]$Name,
    [string[]]$ProjectPath = @(),
    [switch]$IncludeIntensive
)

function Get-AccountPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -ne [IO.Path]::GetPathRoot($full)) { $full = $full.TrimEnd([char[]]@('\', '/')) }
    return $full
}

function Get-AccountItem {
    param([string]$Path)
    return Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Write-AccountStatus {
    param([string]$Item, [string]$Path, [string]$Status)
    Write-Host ("{0}: {1} [{2}]" -f $Item, $Path, $Status)
}

function Set-AccountAtomicFile {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path, [byte[]]$Bytes, [byte[]]$Original)
    if (-not $PSCmdlet.ShouldProcess($Path, '寫入檔案')) { return }
    $temp = Join-Path (Split-Path -Parent $Path) ('.account-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temp, $Bytes)
        if ($null -eq $Original) {
            [IO.File]::Move($temp, $Path)
        } else {
            $current = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
            try {
                $sha = [Security.Cryptography.SHA256]::Create()
                try {
                    if ([Convert]::ToBase64String($sha.ComputeHash($current)) -cne [Convert]::ToBase64String($sha.ComputeHash($Original))) { throw "檔案已由外部修改：$Path" }
                } finally { $sha.Dispose() }
                [IO.File]::Replace($temp, $Path, [System.Management.Automation.Language.NullString]::Value)
            } finally { $current.Dispose() }
        }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Read-AccountTomlValue {
    param([string]$Text, [ref]$Offset)
    while ($Offset.Value -lt $Text.Length -and $Text[$Offset.Value] -in @(' ', "`t")) { $Offset.Value++ }
    if ($Offset.Value -ge $Text.Length) { return $false }
    $remaining = $Text.Substring($Offset.Value)
    $first = $Text[$Offset.Value]
    if ($first -eq '[' -or $first -eq '{') {
        $isTable = $first -eq '{'
        $closing = if ($isTable) { '}' } else { ']' }
        $Offset.Value++
        while ($true) {
            while ($Offset.Value -lt $Text.Length -and $Text[$Offset.Value] -in @(' ', "`t")) { $Offset.Value++ }
            if ($Offset.Value -ge $Text.Length) { return $false }
            if ($Text[$Offset.Value] -eq $closing) { $Offset.Value++; return $true }
            if ($isTable) {
                $keyMatch = [regex]::Match($Text.Substring($Offset.Value), '^[A-Za-z0-9_-]+\s*=\s*')
                if (-not $keyMatch.Success) { return $false }
                $Offset.Value += $keyMatch.Length
            }
            if (-not (Read-AccountTomlValue -Text $Text -Offset $Offset)) { return $false }
            while ($Offset.Value -lt $Text.Length -and $Text[$Offset.Value] -in @(' ', "`t")) { $Offset.Value++ }
            if ($Offset.Value -ge $Text.Length) { return $false }
            if ($Text[$Offset.Value] -eq $closing) { $Offset.Value++; return $true }
            if ($Text[$Offset.Value] -ne ',') { return $false }
            $Offset.Value++
            if ($isTable) {
                $next = $Offset.Value
                while ($next -lt $Text.Length -and $Text[$next] -in @(' ', "`t")) { $next++ }
                if ($next -ge $Text.Length -or $Text[$next] -eq $closing) { return $false }
            }
        }
    }
    $pattern = if ($first -eq '"') { '^"(?:[^"\\\x00-\x1f]|\\(?:["\\btnfr]|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}))*"' }
    elseif ($first -eq "'") { "^'[^'\x00-\x1f]*'" }
    else { '^(?:true|false|0x[0-9a-fA-F](?:_?[0-9a-fA-F])*|0o[0-7](?:_?[0-7])*|0b[01](?:_?[01])*|[+-]?(?:inf|nan|(?:0|[1-9](?:_?[0-9])*)(?:\.[0-9](?:_?[0-9])*)?(?:[eE][+-]?[0-9](?:_?[0-9])*)?))' }
    $match = [regex]::Match($remaining, $pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) { return $false }
    $Offset.Value += $match.Length
    return $true
}

function Test-AccountTomlAssignment {
    param([string]$Line)
    $assignment = [regex]::Match($Line, '^\s*[A-Za-z0-9_-]+\s*=\s*')
    if (-not $assignment.Success) { return $false }
    $offset = $assignment.Length
    if (-not (Read-AccountTomlValue -Text $Line -Offset ([ref]$offset))) { return $false }
    while ($offset -lt $Line.Length -and $Line[$offset] -in @(' ', "`t")) { $offset++ }
    return $offset -eq $Line.Length -or $Line[$offset] -eq '#'
}

function Get-AccountConfigPlan {
    param([string]$Path, [string[]]$Keys)
    $item = Get-AccountItem $Path
    $original = $null
    $text = ''
    if ($null -ne $item) {
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "config 類型錯誤：$Path" }
        $original = [IO.File]::ReadAllBytes($Path)
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        $text = $utf8.GetString($original)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    }
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $windowsCount = 0; $sandboxCount = 0; $section = ''; $projects = @{}
    $lineNumber = 0
    foreach ($line in ($text -split '\r?\n')) {
        $lineNumber++
        if ($line.Contains('"""') -or $line.Contains("'''")) { throw "不支援的 TOML 寫法：$Path`:$lineNumber" }
        if ($line -match '^\s*(#.*)?$') { continue }
        if ($line -cmatch '^\s*\[windows\]\s*(#.*)?$') { $windowsCount++; $section = 'windows'; continue }
        if ($line -cmatch "^\s*\[projects\.'([^']+)'\]\s*(#.*)?$") {
            $key = $Matches[1].ToLowerInvariant()
            if (-not [IO.Path]::IsPathRooted($key) -or $projects.ContainsKey($key)) { throw "重複或無效的 project 段落：$Path`:$lineNumber" }
            $projects[$key] = @{ count = 0; trusted = $false }; $section = 'project:' + $key; continue
        }
        if ($line -cmatch '^\s*\[') {
            if ($line -match '^\s*\[\s*projects\b' -or $line -cnotmatch '^\s*\[[A-Za-z0-9_.-]+\]\s*(#.*)?$') { throw "無法辨識的段落：$Path`:$lineNumber" }
            $section = 'other'; continue
        }
        if ($section -eq '' -and $line -cmatch '^\s*(windows|projects)\s*=') { throw "不支援的 TOML 寫法：$Path`:$lineNumber" }
        if ($section -eq 'windows' -and $line -cmatch '^\s*sandbox\s*=') {
            $sandboxCount++
            if ($line -cnotmatch '^\s*sandbox\s*=\s*"elevated"\s*(#.*)?$') { throw "無效 sandbox 設定：$Path`:$lineNumber" }
            continue
        }
        if ($section.StartsWith('project:') -and $line -cmatch '^\s*trust_level\s*=') {
            $entry = $projects[$section.Substring(8)]; $entry.count++
            $entry.trusted = $line -cmatch '^\s*trust_level\s*=\s*"trusted"\s*(#.*)?$'
            continue
        }
        if (-not (Test-AccountTomlAssignment $line)) { throw "不支援的 TOML 寫法：$Path`:$lineNumber" }
    }
    if ($windowsCount -gt 1 -or ($windowsCount -eq 1 -and $sandboxCount -ne 1)) { throw "windows 段落不完整或重複：$Path" }
    foreach ($entry in $projects.Values) { if ($entry.count -ne 1 -or -not $entry.trusted) { throw "project trust 設定不完整或衝突：$Path" } }
    $append = ''
    if ($windowsCount -eq 0) { $append += "[windows]${newline}sandbox = `"elevated`"${newline}" }
    $missing = @($Keys | Where-Object { -not $projects.ContainsKey($_) })
    foreach ($key in $missing) { $append += "${newline}[projects.'$key']${newline}trust_level = `"trusted`"${newline}" }
    if ($append -and $text -and -not $text.EndsWith("`n")) { $append = $newline + $append }
    [byte[]]$base = @()
    if ($null -ne $original) { $base = $original }
    $extra = [Text.Encoding]::UTF8.GetBytes($append)
    $bytes = New-Object byte[] ($base.Length + $extra.Length)
    [Array]::Copy($base, 0, $bytes, 0, $base.Length); [Array]::Copy($extra, 0, $bytes, $base.Length, $extra.Length)
    return @{ Original = $original; Bytes = $bytes; Changed = ($append.Length -gt 0); Missing = $missing }
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

function Set-AccountLink {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path, [string]$Target, [string]$Type, [string]$StatusName = $Type)
    $item = Get-AccountItem $Path; $status = 'created'; $backup = $null
    if ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            if ($item.LinkType -ne $Type) { throw "連結類型或目標衝突：$Path" }
            $linkTarget = $item.Target -join ''
            if (-not [IO.Path]::IsPathRooted($linkTarget)) { $linkTarget = Join-Path (Split-Path -Parent (Get-AccountPath $Path)) $linkTarget }
            if (-not [string]::Equals((Get-AccountPath $linkTarget), (Get-AccountPath $Target), [StringComparison]::OrdinalIgnoreCase)) { throw "連結類型或目標衝突：$Path" }
            Write-AccountStatus $StatusName $Path 'exists'; return
        }
        $backup = $Path + '.bak-' + (Get-Date -Format 'yyyyMMdd_HHmmss')
        if ($null -ne (Get-AccountItem $backup)) { throw "備份已存在：$backup" }
        $status = 'repaired'
    }
    if (-not $PSCmdlet.ShouldProcess($Path, "建立 $Type")) { Write-AccountStatus $StatusName $Path 'skipped'; return }
    if ($null -ne $backup) {
        if ($item.PSIsContainer) { [IO.Directory]::Move($Path, $backup) } else { [IO.File]::Move($Path, $backup) }
    }
    try { $null = New-Item -ItemType $Type -Path $Path -Target $Target }
    catch { throw "建立 $Type 失敗：$Path；備份：$backup；$($_.Exception.Message)。請以具備建立 Symbolic Link 權限的 PowerShell 重新執行。" }
    Write-AccountStatus $StatusName $Path $status
}

function New-CodexAccount {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateScript({ $_ -cmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' })][string]$Name,
        [Parameter(Mandatory)][string]$HomeRoot,
        [Parameter(Mandatory)][string]$SourceCodex,
        [Parameter(Mandatory)][string]$MachinePath,
        [string[]]$ProjectPath = @(), [switch]$IncludeIntensive
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw '僅支援 Windows。' }
    $accountHomePath = Get-AccountPath (Join-Path $HomeRoot ('.codex-' + $Name))
    $source = Get-AccountPath $SourceCodex
    if ([string]::Equals($accountHomePath, $source, [StringComparison]::OrdinalIgnoreCase)) { throw '不得登記來源 Codex home。' }
    $machineDir = Split-Path -Parent $MachinePath
    $machineDirItem = Get-AccountItem $machineDir
    if ($null -ne $machineDirItem -and (-not $machineDirItem.PSIsContainer -or ($machineDirItem.Attributes -band [IO.FileAttributes]::ReparsePoint))) { throw "machine 目錄類型錯誤：$machineDir" }
    if ($null -eq $machineDirItem) {
        $preflightNames = @('.sandbox', '.sandbox-bin', '.sandbox-secrets')
        foreach ($namePart in $preflightNames) { if (-not (Test-Path -LiteralPath (Join-Path $source $namePart) -PathType Container)) { throw "來源目錄不存在：$namePart" } }
        $preflightProfiles = @('.sandbox_migration', 'implement.config.toml', 'review.config.toml', 'deep-review.config.toml', 'scan.config.toml', 'advisor.config.toml')
        if ($IncludeIntensive) { $preflightProfiles += 'intensive.config.toml' }
        foreach ($namePart in $preflightProfiles) { if (-not (Test-Path -LiteralPath (Join-Path $source $namePart) -PathType Leaf)) { throw "來源檔案不存在：$namePart" } }
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
        $null = Get-AccountMachinePlan $MachinePath $Name $accountHomePath
        if ($PSCmdlet.ShouldProcess($machineDir, '建立 machine 目錄')) {
            $null = New-Item -ItemType Directory -Path $machineDir
            Write-AccountStatus 'machine 目錄' $machineDir 'created'
        } else { Write-AccountStatus 'machine 目錄（將建立）' $machineDir 'skipped' }
    }
    $lock = $null; $step = 'preflight'; $lockCreated = $false; $completed = $false
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
        $sourceNames = @('.sandbox', '.sandbox-bin', '.sandbox-secrets')
        foreach ($namePart in $sourceNames) { if (-not (Test-Path -LiteralPath (Join-Path $source $namePart) -PathType Container)) { throw "來源目錄不存在：$namePart" } }
        $profiles = @('implement.config.toml', 'review.config.toml', 'deep-review.config.toml', 'scan.config.toml', 'advisor.config.toml')
        if ($IncludeIntensive) { $profiles += 'intensive.config.toml' }
        foreach ($namePart in @('.sandbox_migration') + $profiles) { if (-not (Test-Path -LiteralPath (Join-Path $source $namePart) -PathType Leaf)) { throw "來源檔案不存在：$namePart" } }
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
        $step = 'home'
        if ($null -eq $homeItem) {
            if ($PSCmdlet.ShouldProcess($accountHomePath, '建立帳號目錄')) { $null = New-Item -ItemType Directory -Path $accountHomePath; Write-AccountStatus 'home' $accountHomePath 'created' } else { Write-AccountStatus 'home' $accountHomePath 'skipped' }
        } else { Write-AccountStatus 'home' $accountHomePath 'exists' }
        $step = 'config'
        if ($config.Changed) {
            Set-AccountAtomicFile -Path $configPath -Bytes $config.Bytes -Original $config.Original -WhatIf:$WhatIfPreference
            $status = if ($WhatIfPreference) { 'skipped' } elseif ($null -eq $config.Original) { 'created' } else { 'repaired' }
            Write-AccountStatus 'config' $configPath $status
        } else { Write-AccountStatus 'config' $configPath 'exists' }
        if ($keys.Count -eq 0) { Write-AccountStatus 'trust（派工前請指定專案）' $configPath 'skipped' }
        foreach ($key in $keys) { $status = if ($WhatIfPreference) { 'skipped' } elseif ($config.Missing -contains $key) { 'created' } else { 'exists' }; Write-AccountStatus 'trust' $key $status }
        $step = 'sandbox'
        foreach ($namePart in $sourceNames) { Set-AccountLink -Path (Join-Path $accountHomePath $namePart) -Target (Join-Path $source $namePart) -Type Junction -WhatIf:$WhatIfPreference }
        Set-AccountLink -Path (Join-Path $accountHomePath '.sandbox_migration') -Target (Join-Path $source '.sandbox_migration') -Type SymbolicLink -WhatIf:$WhatIfPreference
        $step = 'profiles'
        foreach ($profile in @('implement.config.toml', 'review.config.toml', 'deep-review.config.toml', 'scan.config.toml', 'advisor.config.toml', 'intensive.config.toml')) {
            $dest = Join-Path $accountHomePath $profile
            if ($profile -eq 'intensive.config.toml' -and -not $IncludeIntensive) { Write-AccountStatus 'profile' $dest 'skipped'; continue }
            $item = Get-AccountItem $dest
            if ($null -ne $item -and $item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "profile 類型錯誤：$dest" }
            Set-AccountLink -Path $dest -Target (Join-Path $source $profile) -Type SymbolicLink -StatusName 'profile' -WhatIf:$WhatIfPreference
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
    } catch { Write-Host ("failed: {0}: {1}" -f $step, $_.Exception.Message); throw }
    finally {
        if ($null -ne $lock) { $lock.Dispose() }
        if ($lockCreated -and -not $completed) { try { [IO.File]::Delete($lockPath) } catch { } }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    try {
        if ([string]::IsNullOrWhiteSpace($Name)) { throw '必須指定 -Name。' }
        $profileRoot = [Environment]::GetFolderPath('UserProfile')
        New-CodexAccount -Name $Name -HomeRoot $profileRoot -SourceCodex (Join-Path $profileRoot '.codex') -MachinePath (Join-Path (Split-Path -Parent $PSScriptRoot) '.local\machine.json') -ProjectPath $ProjectPath -IncludeIntensive:$IncludeIntensive -WhatIf:$WhatIfPreference
        exit 0
    } catch { Write-Error -ErrorRecord $_ -ErrorAction Continue; exit 1 }
}
