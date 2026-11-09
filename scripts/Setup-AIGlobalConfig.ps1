#Requires -Version 5.1

# ----------------------------------------------------------------
# Setup-AIGlobalConfig.ps1 - AI 全域設定連結自動化（收斂式安裝 / 含斷鍊清除）
# 支援 -WhatIf 預覽；相容 Windows PowerShell 5.1 與 PowerShell 7+。
# ----------------------------------------------------------------

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force,
    [switch]$EnableLongPaths
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows 長路徑檢查
function Set-WindowsLongPaths {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$Enable,
        [bool]$IsAdministrator
    )

    $registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
    $enableCommand = "New-ItemProperty -Path '$registryPath' -Name LongPathsEnabled -PropertyType DWord -Value 1 -Force"
    if ($Enable -and -not $IsAdministrator) {
        throw "啟用長路徑需要系統管理員權限。請以系統管理員身分執行：$enableCommand"
    }

    $properties = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
    $property = $properties.PSObject.Properties['LongPathsEnabled']
    if ($null -ne $property -and $property.Value -eq 1) {
        Write-Host '  ✅ Windows 長路徑已啟用。' -ForegroundColor DarkGreen
        return
    }

    Write-Warning "Windows 長路徑未啟用；派工 worktree 內的 NuGet 套件路徑可能超過 260 字元。啟用命令：$enableCommand。需重新登入或重開機才生效。"
    if ($Enable -and $PSCmdlet.ShouldProcess("$registryPath\LongPathsEnabled", '啟用 Windows 長路徑')) {
        New-ItemProperty -LiteralPath $registryPath -Name LongPathsEnabled -PropertyType DWord -Value 1 -Force | Out-Null
        Write-Host '  ✅ 已設定 Windows 長路徑；需重新登入或重開機才生效。' -ForegroundColor DarkGreen
    }
}

if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
    $longPathPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdministrator = $longPathPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Set-WindowsLongPaths -Enable:$EnableLongPaths -IsAdministrator $isAdministrator
}
# 1. 管理員權限檢查
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "此腳本必須以『系統管理員身分』執行！" -ErrorAction Continue
    exit 1
}

# 2. 定義路徑：刻意寫死，與內容層 instructions.md / skill 的 ~/.ai-agents/ 引用共用同一不變量
$configRoot = "$env:USERPROFILE\.ai-agents"
$configRootDisplay = $configRoot.Replace($env:USERPROFILE, '~')
$mainInstructions = Join-Path $configRoot "instructions.md"
$gitGlobalExcludes = Join-Path $configRoot "git-global-excludes"

# 3. 實體檔案與原始目錄檢查
if (!(Test-Path $mainInstructions)) {
    Write-Error "找不到 $mainInstructions" -ErrorAction Continue
    Write-Error "請確認腳本位於 <configRoot>\scripts\ 之下。" -ErrorAction Continue
    exit 1
}

if (!(Test-Path $gitGlobalExcludes)) {
    Write-Error "找不到機器層排除清單 $gitGlobalExcludes" -ErrorAction Continue
    exit 1
}

# 4. 準備工具目錄
$claudeDir = "$env:USERPROFILE\.claude"
$codexDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { "$env:USERPROFILE\.codex" }
$agentsDir = "$env:USERPROFILE\.agents"
foreach ($dir in @($claudeDir, $codexDir, $agentsDir)) {
    if (!(Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
}

# 5. 連結清單：增減工具改這張表即可。Source 為 configRoot 下相對路徑
$desired = @(
    @{ Link = "$claudeDir\CLAUDE.md"; Source = "instructions.md" }
    @{ Link = "$claudeDir\skills";    Source = "skills" }
    @{ Link = "$claudeDir\agents";    Source = "agents\claude" }
    @{ Link = "$codexDir\AGENTS.md";  Source = "instructions.md" }
    @{ Link = "$codexDir\agents";     Source = "agents\codex" }
    @{ Link = "$agentsDir\skills";    Source = "skills" }
)

# 斷鍊清除的掃描範圍，含現役與已退役工具根目錄
$sweepRoots = @(
    $claudeDir
    $codexDir
    $agentsDir
    "$env:USERPROFILE\.copilot"   # 已退役
    "$env:USERPROFILE\.gemini"    # 已退役（含 antigravity 子目錄）
)

# 6. 建立符號連結：先刪後建，不覆蓋真實檔案
function Set-SymbolicLink {
    param (
        [string]$LinkPath,
        [string]$TargetPath,
        [string]$ItemType = "SymbolicLink",
        [switch]$Force
    )

    # 來源不存在則略過，不動既有連結
    if (!(Test-Path $TargetPath)) {
        Write-Host "  ⚠️  略過：來源不存在 $TargetPath" -ForegroundColor Yellow
        return
    }

    # 偵測斷鍊：Test-Path 對斷鍊回傳 false，需改用 Get-Item / Get-ChildItem
    $existing = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
    if (-not $existing) {
        $parent = Split-Path $LinkPath
        $leaf = Split-Path $LinkPath -Leaf
        if (Test-Path $parent) {
            $existing = Get-ChildItem -Path $parent -Filter $leaf -Force -ErrorAction SilentlyContinue
        }
    }

    if ($existing) {
        if ($existing.Attributes -match "ReparsePoint") {
            $existingTargetValue = $null
            if ($null -ne $existing.PSObject.Properties['Target']) {
                $existingTargetValue = $existing.Target
            }
            if ($null -eq $existingTargetValue -and $null -ne $existing.PSObject.Properties['LinkTarget']) {
                $existingTargetValue = $existing.LinkTarget
            }
            $existingTargetText = @($existingTargetValue) -join ''
            $resolvedExistingTarget = $null
            if (-not [string]::IsNullOrWhiteSpace($existingTargetText)) {
                if ([System.IO.Path]::IsPathRooted($existingTargetText)) {
                    $resolvedExistingTarget = [System.IO.Path]::GetFullPath($existingTargetText)
                }
                else {
                    $resolvedExistingTarget = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $LinkPath) $existingTargetText))
                }
                $existingTargetRoot = [System.IO.Path]::GetPathRoot($resolvedExistingTarget)
                if (-not [System.String]::Equals($resolvedExistingTarget, $existingTargetRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $resolvedExistingTarget = $resolvedExistingTarget.TrimEnd([char[]]@([char]92, [char]47))
                }
            }
            $resolvedTargetPath = [System.IO.Path]::GetFullPath($TargetPath)
            $targetRoot = [System.IO.Path]::GetPathRoot($resolvedTargetPath)
            if (-not [System.String]::Equals($resolvedTargetPath, $targetRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $resolvedTargetPath = $resolvedTargetPath.TrimEnd([char[]]@([char]92, [char]47))
            }
            if ($null -ne $resolvedExistingTarget -and [System.String]::Equals($resolvedExistingTarget, $resolvedTargetPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Host "  ✅  already-correct：$LinkPath → $resolvedTargetPath" -ForegroundColor DarkGreen
                return
            }
            if (-not $Force) {
                $displayExistingTarget = if ([string]::IsNullOrWhiteSpace($existingTargetText)) { '(無法讀取目標)' } else { $existingTargetText }
                Write-Warning ("既有連結指向 '{0}'，預期來源為 '{1}'；略過。加上 -Force 才會取代。" -f $displayExistingTarget, $resolvedTargetPath)
                return
            }
            $displayExistingTarget = if ([string]::IsNullOrWhiteSpace($existingTargetText)) { '(無法讀取目標)' } else { $existingTargetText }
            Write-Host ("  ⚠️  變更前連結目標：{0} → {1}" -f $LinkPath, $displayExistingTarget) -ForegroundColor Yellow
            Remove-Item -LiteralPath $existing.FullName -Force
        }
        else {
            # 空目錄可安全替換為符號連結
            $isEmptyDir = ($existing -is [System.IO.DirectoryInfo]) -and
            ((Get-ChildItem -Path $existing.FullName -Force | Measure-Object).Count -eq 0)
            if ($isEmptyDir) {
                Remove-Item -LiteralPath $existing.FullName -Force
            }
            else {
                Write-Host "  ⚠️  略過：$LinkPath 已存在且非符號連結，請手動移除後重新執行。" -ForegroundColor Yellow
                return
            }
        }
    }

    New-Item -ItemType $ItemType -Path $LinkPath -Target $TargetPath -Force | Out-Null
    if (-not $WhatIfPreference) {
        Write-Host "  ✅  $($LinkPath.Replace($env:USERPROFILE, '~'))  →  $TargetPath" -ForegroundColor DarkGreen
    }
}

function Set-GitGlobalExcludesFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$TargetPath,

        [switch]$Force
    )

    $existingValue = (& git config --global --get core.excludesFile 2>$null | Out-String).TrimEnd()
    $readExitCode = $LASTEXITCODE
    if ($readExitCode -gt 1) {
        throw "讀取 core.excludesFile 失敗，結束碼：$readExitCode"
    }
    if ($readExitCode -eq 1) {
        $existingValue = ''
    }

    $resolvedTargetPath = [System.IO.Path]::GetFullPath($TargetPath)
    $sameTarget = [string]::IsNullOrWhiteSpace($existingValue)
    if (-not $sameTarget) {
        try {
            $resolvedExistingValue = [System.IO.Path]::GetFullPath($existingValue)
            $sameTarget = [System.String]::Equals($resolvedExistingValue, $resolvedTargetPath, [System.StringComparison]::OrdinalIgnoreCase)
        }
        catch {
            $sameTarget = $false
        }
    }

    if (-not $sameTarget -and -not $Force) {
        Write-Warning ("core.excludesFile 已設定為 '{0}'；略過設定。加上 -Force 才會覆寫。" -f $existingValue)
        return
    }
    if (-not $sameTarget) {
        Write-Host ("core.excludesFile 變更前值：{0}" -f $existingValue) -ForegroundColor Yellow
    }

    if (-not $PSCmdlet.ShouldProcess($resolvedTargetPath, '設定 core.excludesFile')) {
        return
    }
    & git config --global core.excludesFile $resolvedTargetPath
    if ($LASTEXITCODE -ne 0) {
        throw "設定 core.excludesFile 失敗，結束碼：$LASTEXITCODE"
    }

    $configuredValue = (& git config --global --get core.excludesFile 2>$null | Out-String).TrimEnd()
    if ($LASTEXITCODE -ne 0) {
        throw "讀取 core.excludesFile 失敗，結束碼：$LASTEXITCODE"
    }
    if (-not [System.String]::Equals([System.IO.Path]::GetFullPath($configuredValue), $resolvedTargetPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "core.excludesFile 設定值不符，實際值：$configuredValue"
    }
    Write-Host "  ✅  core.excludesFile → $configuredValue" -ForegroundColor DarkGreen
}

# 7. 建立現役連結（逐條收斂）
Write-Host "`n>>> 正在建立符號連結..." -ForegroundColor Cyan
foreach ($entry in $desired) {
    $target = Join-Path $configRoot $entry.Source
    Set-SymbolicLink -LinkPath $entry.Link -TargetPath $target -Force:$Force
}

# 8. 清除斷鍊孤兒：只刪「指向 configRoot 但來源已不存在」者；仍能解析的連結保留
Write-Host "`n>>> 正在清除斷鍊孤兒..." -ForegroundColor Cyan
$rootPrefix = $configRoot.TrimEnd('\')
$rootPrefixWithSeparator = $rootPrefix + [System.IO.Path]::DirectorySeparatorChar
$orphans = foreach ($root in ($sweepRoots | Sort-Object -Unique)) {
    if (!(Test-Path $root)) { continue }
    Get-ChildItem -Path $root -Recurse -Depth 3 -Force -ErrorAction SilentlyContinue |
    Where-Object {
        if (-not ($_.Attributes -match 'ReparsePoint')) { return $false }
        $t = if ($_.Target) { $_.Target } else { $_.LinkTarget }
        $t = ($t -join '')
        # 路徑分隔符邊界可避免 .ai-agents-backup 被誤判為 .ai-agents 的子路徑，防止清除根目錄外的 link。
        $isWithinConfigRoot = [System.String]::Equals($t, $rootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            $t.StartsWith($rootPrefixWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $isWithinConfigRoot) { return $false }
        -not (Test-Path -LiteralPath $t)   # 僅保留斷鍊者
    }
}
$orphans = @($orphans)
foreach ($o in $orphans) {
    $t = if ($o.Target) { $o.Target } else { $o.LinkTarget }
    Remove-Item -LiteralPath $o.FullName -Force
    if (-not $WhatIfPreference) {
        Write-Host "  🧹  已清除斷鍊：$($o.FullName.Replace($env:USERPROFILE, '~'))  ↛  $($t -join '')" -ForegroundColor Magenta
    }
}
if ($orphans.Count -eq 0 -and -not $WhatIfPreference) {
    Write-Host "  （無斷鍊孤兒）" -ForegroundColor DarkGray
}

# 8b. 註冊 Claude Code plugin
function Invoke-ClaudeCli {
    param([string[]]$Arguments)
    $claude = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $claude) { return $null }
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $claude.Source @Arguments 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } finally { $ErrorActionPreference = $previousPreference }
}

function Get-ClaudeList {
    param([string[]]$Arguments)
    $result = Invoke-ClaudeCli $Arguments
    if ($null -eq $result -or $result.ExitCode -ne 0) { throw "Claude CLI 查詢失敗：$($result.Output)" }
    try { $parsed = ConvertFrom-Json -InputObject $result.Output -ErrorAction Stop } catch { throw "Claude CLI JSON 解析失敗：$($result.Output)" }
    if ($result.Output.TrimStart() -notmatch '^\[') { throw 'Claude CLI 清單格式不符。' }
    return ,@($parsed)
}

function Get-ClaudeProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

$claudeMarketplaceRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'claude-plugins'
$claudePluginEnabled = $false
try {
    if ($null -eq (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue) -or -not (Test-Path -LiteralPath (Join-Path $claudeMarketplaceRoot '.claude-plugin\marketplace.json') -PathType Leaf)) { throw '找不到 claude CLI 或 marketplace 清單，略過 plugin 註冊。' }
    $manifest = Get-Content -LiteralPath (Join-Path $claudeMarketplaceRoot '.claude-plugin\marketplace.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $specs = @()
    foreach ($entry in @($manifest.plugins)) {
        if ($entry.source -isnot [string] -or -not $entry.source.StartsWith('./') -or [string]::IsNullOrWhiteSpace([string]$entry.name)) { throw 'marketplace plugin 的 name 或 source 不正確。' }
        $specs += [pscustomobject]@{ Name = [string]$entry.name; Id = ([string]$entry.name + '@ai-agents-local'); Directory = (Join-Path $claudeMarketplaceRoot $entry.source.Substring(2)) }
    }
    if ($specs.Count -eq 0 -or @($specs | Where-Object { $_.Name -eq 'ai-agents-hooks' }).Count -ne 1) { throw 'marketplace plugin 清單為空或缺少 ai-agents-hooks。' }
    $result = Invoke-ClaudeCli @('plugin', 'validate', $claudeMarketplaceRoot)
    if ($null -eq $result -or $result.ExitCode -ne 0) { throw "marketplace 驗證失敗：$($result.Output)" }
    $claudePluginSpecs = @()
    foreach ($spec in $specs) {
        $result = Invoke-ClaudeCli @('plugin', 'validate', $spec.Directory)
        if ($null -eq $result -or $result.ExitCode -ne 0) {
            if ($spec.Name -eq 'ai-agents-hooks') { throw "plugin 驗證失敗：$($result.Output)" }
            Write-Warning ("plugin {0} 驗證失敗：{1}" -f $spec.Id, $result.Output)
            continue
        }
        $claudePluginSpecs += $spec
    }
    $marketplaces = Get-ClaudeList @('plugin', 'marketplace', 'list', '--json')
    $existing = @($marketplaces | Where-Object { (Get-ClaudeProperty $_ 'name') -eq 'ai-agents-local' -or (Get-ClaudeProperty $_ 'id') -eq 'ai-agents-local' })
    if ($existing.Count -gt 1) { throw 'marketplace 清單含重複名稱。' }
    $needsAdd = $existing.Count -eq 0
    if ($existing.Count -eq 1) {
        $source = Get-ClaudeProperty $existing[0] 'source'
        $sourcePath = if ($source -is [string] -and [IO.Path]::IsPathRooted($source)) { $source } else { Get-ClaudeProperty $source 'path' }
        if ([string]::IsNullOrWhiteSpace([string]$sourcePath)) { $sourcePath = Get-ClaudeProperty $existing[0] 'installLocation' }
        if ([string]::IsNullOrWhiteSpace([string]$sourcePath)) { throw '無法判定 marketplace 來源路徑。' }
        $same = [string]::Equals([IO.Path]::GetFullPath($sourcePath).TrimEnd('\','/'), [IO.Path]::GetFullPath($claudeMarketplaceRoot).TrimEnd('\','/'), [StringComparison]::OrdinalIgnoreCase)
        if (-not $same) {
            if (-not $Force) { throw "marketplace 來源為 $sourcePath；使用 -Force 才能改指。" }
            if ($PSCmdlet.ShouldProcess('ai-agents-local', '備份 plugin 資料並移除 marketplace')) {
                $dataPath = Join-Path $claudeDir 'plugins\data\ai-agents-hooks-ai-agents-local'
                if (Test-Path -LiteralPath $dataPath -PathType Container) {
                    $backupPath = Join-Path $configRoot ('.local\ai-sessions\backups\' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '\plugin-data')
                    New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
                    Copy-Item -LiteralPath $dataPath -Destination $backupPath -Recurse -Force
                    Write-Host "plugin-data: 備份至 $backupPath"
                } else { Write-Host 'plugin-data: 無資料目錄' }
                $result = Invoke-ClaudeCli @('plugin', 'marketplace', 'remove', 'ai-agents-local')
                if ($result.ExitCode -ne 0) { throw "marketplace remove 失敗：$($result.Output)" }
                $needsAdd = $true
            } else { throw 'WhatIf：略過 marketplace 改指。' }
        }
    }
    if ($needsAdd -and $PSCmdlet.ShouldProcess($claudeMarketplaceRoot, '加入 Claude marketplace')) {
        $result = Invoke-ClaudeCli @('plugin', 'marketplace', 'add', $claudeMarketplaceRoot)
        if ($result.ExitCode -ne 0) { throw "marketplace add 失敗：$($result.Output)" }
    }
    if ($needsAdd -and $WhatIfPreference) { throw 'WhatIf：略過 plugin 安裝。' }
    $plugins = Get-ClaudeList @('plugin', 'list', '--json')
    foreach ($spec in $claudePluginSpecs) {
        try {
            $installed = @($plugins | Where-Object { (Get-ClaudeProperty $_ 'id') -eq $spec.Id -or (Get-ClaudeProperty $_ 'name') -eq $spec.Id })
            if ($installed.Count -gt 1) { throw 'plugin 清單含重複識別。' }
            if ($installed.Count -eq 0) {
                if ($PSCmdlet.ShouldProcess($spec.Id, '安裝 plugin')) {
                    $result = Invoke-ClaudeCli @('plugin', 'install', $spec.Id, '--scope', 'user')
                    if ($result.ExitCode -ne 0) { throw "plugin install 失敗：$($result.Output)" }
                }
            } elseif ((Get-ClaudeProperty $installed[0] 'enabled') -eq $false) {
                if ($PSCmdlet.ShouldProcess($spec.Id, '啟用 plugin')) {
                    $result = Invoke-ClaudeCli @('plugin', 'enable', $spec.Id)
                    if ($result.ExitCode -ne 0) { throw "plugin enable 失敗：$($result.Output)" }
                }
            } elseif ((Get-ClaudeProperty $installed[0] 'enabled') -ne $true) { throw '無法判定 plugin 啟用狀態。' }
        } catch {
            if ($spec.Name -eq 'ai-agents-hooks') { throw }
            Write-Warning ("plugin {0} 處理失敗：{1}" -f $spec.Id, $_.Exception.Message)
        }
    }
    $plugins = Get-ClaudeList @('plugin', 'list', '--json')
    foreach ($spec in $claudePluginSpecs) {
        $enabled = @($plugins | Where-Object { ((Get-ClaudeProperty $_ 'id') -eq $spec.Id -or (Get-ClaudeProperty $_ 'name') -eq $spec.Id) -and (Get-ClaudeProperty $_ 'enabled') -eq $true })
        if ($spec.Name -eq 'ai-agents-hooks') { $claudePluginEnabled = $enabled.Count -eq 1 }
        if ($enabled.Count -eq 1) { Write-Host ("plugin: {0} enabled" -f $spec.Id) } else { Write-Warning ("plugin: {0} 尚未啟用。" -f $spec.Id) }
    }
} catch { Write-Warning $_.Exception.Message }

# 8c. 移除舊 hook 註冊
function Remove-ClaudeLegacyHook {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$SettingsPath, [string]$BackupRoot)

    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        Write-Host 'legacy-hook: none'
        return
    }
    try {
        $originalHash = (Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256).Hash
        $settings = [IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json -ErrorAction Stop
        $hooksProperty = $settings.PSObject.Properties['hooks']
        if ($null -eq $hooksProperty -or $null -eq $hooksProperty.Value) { Write-Host 'legacy-hook: none'; return }
        $postProperty = $hooksProperty.Value.PSObject.Properties['PostToolUse']
        if ($null -eq $postProperty) { Write-Host 'legacy-hook: none'; return }
        $removed = 0
        $groups = @()
        foreach ($group in @($postProperty.Value)) {
            $itemsProperty = $group.PSObject.Properties['hooks']
            if ($null -eq $itemsProperty) { $groups += $group; continue }
            $items = @()
            $groupRemoved = 0
            foreach ($item in @($itemsProperty.Value)) {
                $command = Get-ClaudeProperty $item 'command'
                $arguments = Get-ClaudeProperty $item 'args'
                $text = ((@($command) + @($arguments)) -join ' ').Replace('\', '/')
                # 此路徑用來辨識舊 hook 項目。
                if ($text -like '*scripts/hooks/post-edit-write-hook.ps1*') { $removed++; $groupRemoved++ } else { $items += $item }
            }
            if ($items.Count -gt 0 -or $groupRemoved -eq 0) { $itemsProperty.Value = $items; $groups += $group }
        }
        if ($removed -eq 0) { Write-Host 'legacy-hook: none'; return }
        if (-not $PSCmdlet.ShouldProcess($SettingsPath, '移除舊 Claude hook')) { return }
        $backupDirectory = Join-Path $BackupRoot (Get-Date -Format 'yyyyMMdd_HHmmss')
        New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
        $backup = Join-Path $backupDirectory 'settings.json'
        Copy-Item -LiteralPath $SettingsPath -Destination $backup
        [IO.File]::WriteAllText((Join-Path $backupDirectory 'manifest.txt'), ((Get-Date -Format o) + " | $SettingsPath | 移除舊 hook`n"), (New-Object Text.UTF8Encoding($false)))
        if ($groups.Count -gt 0) { $postProperty.Value = $groups } else { $hooksProperty.Value.PSObject.Properties.Remove('PostToolUse') }
        if (@($hooksProperty.Value.PSObject.Properties).Count -eq 0) { $settings.PSObject.Properties.Remove('hooks') }
        if ((Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256).Hash -ne $originalHash) { Write-Warning 'settings.json 已變更，略過舊 hook 清理。'; return }
        $expected = $settings | ConvertTo-Json -Depth 32 -Compress
        try {
            [IO.File]::WriteAllText($SettingsPath, ($settings | ConvertTo-Json -Depth 32), (New-Object Text.UTF8Encoding($false)))
            $actual = ([IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json -ErrorAction Stop) | ConvertTo-Json -Depth 32 -Compress
            if ($actual -cne $expected) { throw 'settings.json 語意驗證失敗。' }
        } catch {
            Copy-Item -LiteralPath $backup -Destination $SettingsPath -Force
            throw
        }
        Write-Host "legacy-hook: removed $removed entry"
    } catch { Write-Warning ("舊 hook 清理失敗：" + $_.Exception.Message) }
}
if ($claudePluginEnabled) {
    Remove-ClaudeLegacyHook -SettingsPath (Join-Path $claudeDir 'settings.json') -BackupRoot (Join-Path $configRoot '.local\ai-sessions\backups') -WhatIf:$WhatIfPreference
}

# 9. 設定 Git Hooks 路徑
Write-Host "`n>>> 正在設定 Git Hooks..." -ForegroundColor Cyan
if ($PSCmdlet.ShouldProcess("$configRoot", "設定 core.hooksPath → .githooks")) {
    git -C $configRoot config core.hooksPath .githooks
    if ($LASTEXITCODE -ne 0) {
        throw "設定 core.hooksPath 失敗，結束碼：$LASTEXITCODE"
    }
    Write-Host "  ✅  core.hooksPath → .githooks" -ForegroundColor DarkGreen
}

# 10. 設定機器層 Git 排除清單
Write-Host "`n>>> 正在設定 Git 機器層排除清單..." -ForegroundColor Cyan
Set-GitGlobalExcludesFile -TargetPath $gitGlobalExcludes -Force:$Force

# 11. 驗證回饋
if ($WhatIfPreference) { return }

Write-Host "`n>>> 設定完成！詳細連結路徑如下：" -ForegroundColor Green
Write-Host "----------------------------------------------------------------"

# 相容 PS 5.1 (.Target) 與 PS 7 (.LinkTarget)
$allDirs = @($claudeDir, $codexDir, $agentsDir)
foreach ($dir in $allDirs) {
    Get-ChildItem -Path $dir -Force |
    Where-Object { $_.Attributes -match "ReparsePoint" } |
    Select-Object `
    @{Name = "工具入口 (Entry)"; Expression = { $_.FullName.Replace($env:USERPROFILE, "~") } },
    @{Name = "指向來源 (Source)"; Expression = {
            if ($_.Target) { $_.Target } else { $_.LinkTarget }
        }
    } |
    Format-Table -AutoSize
}

Write-Host "----------------------------------------------------------------"

Write-Host ""
Write-Host "注意事項：" -ForegroundColor Yellow
Write-Host "  - 設定來源目錄為 $configRootDisplay/"
Write-Host "  - 專案層範本位於 $configRootDisplay/templates/，可搭配 project-setup skill 建立 AGENTS.md 與相關宣告"
Write-Host "  - Roslyn C# Script 位於 $configRootDisplay/scripts/*.csx，需先執行 dotnet tool install -g dotnet-script"
Write-Host "  - 機器層 Git 排除清單位於 $configRootDisplay/git-global-excludes"
Write-Host "  - Claude Code 透過 ~/.claude/CLAUDE.md 符號連結讀取"
Write-Host "  - Claude Code skills → $configRootDisplay/skills/"
Write-Host "  - Claude Code agents → $configRootDisplay/agents/claude/"
Write-Host "  - Claude Code plugin 由本機 marketplace 提供，包含 ai-agents-hooks@ai-agents-local 與 line-status-board@ai-agents-local，原始碼位於 $($claudeMarketplaceRoot.Replace($env:USERPROFILE, '~'))"
Write-Host "  - Codex 透過 ~/.codex/AGENTS.md 符號連結讀取（或以 CODEX_HOME 指定路徑）"
Write-Host "  - Codex agents → $configRootDisplay/agents/codex/"
Write-Host "  - Codex skills → ~/.agents/skills/"

# 12. Codex 執行環境檢查
Write-Host "`n>>> 檢查 Codex 執行環境..." -ForegroundColor Cyan

$codexCommand = Get-Command codex -ErrorAction SilentlyContinue
$codexVersion = $null
if ($null -eq $codexCommand) {
    Write-Warning "  ⚠️ 找不到 PATH 上的 codex。"
    Write-Host "  請執行下列指令安裝 Codex CLI："
    Write-Host ('  npm' + ' i -g @openai/codex')
    Write-Host "  參考 README.md §3「Codex CLI 前置需求」。"
}
else {
    $codexVersionOutput = (& codex --version 2>&1 | Out-String).Trim()
    $codexVersionExitCode = $LASTEXITCODE
    if ($codexVersionExitCode -ne 0) {
        Write-Warning "  ⚠️ codex --version 執行失敗，結束碼：$codexVersionExitCode。輸出：$codexVersionOutput"
    }
    else {
        $versionMatch = [regex]::Match($codexVersionOutput, '\d+\.\d+\.\d+')
        if (-not $versionMatch.Success) {
            Write-Warning "  ⚠️ 無法從 codex --version 解析版本：$codexVersionOutput"
        }
        else {
            $codexVersion = [version]$versionMatch.Value
            Write-Host "  ✅ Codex CLI 可用：$codexVersionOutput" -ForegroundColor DarkGreen
        }
    }
}

# 帳號清單只作存在診斷，設定與登入由使用者維護。
. (Join-Path $PSScriptRoot 'dispatch\common-runtime.ps1')
. (Join-Path $PSScriptRoot 'dispatch\git-baseline.ps1')
. (Join-Path $PSScriptRoot 'dispatch\dispatch-evidence.ps1')
try {
    $machineAccounts = @(Read-CodexAccountConfiguration -MachineConfigPath (Join-Path $configRoot '.local\machine.json'))
    foreach ($account in $machineAccounts) {
        Write-Host ('  Codex 帳號 ' + $account.name + '：' + $account.codex_home)
        $accountConfigPath = Join-Path $account.codex_home 'config.toml'
        if (-not (Test-Path -LiteralPath $accountConfigPath -PathType Leaf)) {
            Write-Warning ('  帳號 ' + $account.name + ' 缺少 ' + $accountConfigPath + '。請依 README.md §3 人工準備；基礎 config 必要鍵待使用者驗證。')
        }
        $accountProfileNames = @(Get-CodexDispatchProfileNames)
        foreach ($linkStatus in @(Get-CodexAccountProfileLinkStatus -AccountHome $account.codex_home -CodexDirectory $codexDir -ProfileName $accountProfileNames)) {
            if ($linkStatus.state -cne 'ok') {
                Write-Warning ('  帳號 ' + $account.name + ' 的檔位設定檔 ' + $linkStatus.name + ' 狀態為 ' + $linkStatus.state + '：' + $linkStatus.path + '，預期為指向 ' + $linkStatus.expected_target + ' 的 Symbolic Link。請依 README.md §3 人工建立連結；腳本不會修改帳號目錄。')
            }
        }
        if (Test-CodexLegacyDefaultProfile -Directory $account.codex_home) {
            $accountLegacyDefaultPath = Join-Path $account.codex_home ('default' + '.config.toml')
            Write-Warning ('  帳號 ' + $account.name + ' 殘留已停用的檔位設定檔：' + $accountLegacyDefaultPath + '。派工不再讀取，腳本不會刪除；請以 Remove-Item -LiteralPath 只移除該連結本身。')
        }
    }
}
catch {
    Write-Warning ($_.Exception.Message + '。請修正本機帳號清單；保留原預設目錄，未切換帳號。')
}

$codexConfigPath = Join-Path $codexDir "config.toml"
$legacyProfileName = 'deep' + '.config.toml'
$legacyProfilePath = Join-Path $codexDir $legacyProfileName
$legacyDefaultName = 'default' + '.config.toml'
$legacyDefaultPath = Join-Path $codexDir $legacyDefaultName
$legacyDefaultDetected = $false
$maxEffortMatches = @()

# 缺少的檔位設定檔依下表建立初始內容。檔案建立後屬本機設定，Setup 不再改寫。
$codexProfileDefaults = [ordered]@{
    'review'      = [ordered]@{ model = 'gpt-6.1-terra'; effort = 'high' }
    'deep-review' = [ordered]@{ model = 'gpt-6.1-sol'; effort = 'high' }
    'scan'        = [ordered]@{ model = 'gpt-6.1-terra'; effort = 'medium' }
    'advisor'     = [ordered]@{ model = 'gpt-6.1-sol'; effort = 'high' }
}
$codexProfileAgentsLines = @(
    '[agents]'
    'enabled = true'
    'default_subagent_model = "gpt-6-luna"'
    'default_subagent_reasoning_effort = "max"'
)
$requiredProfileNames = @(Get-CodexDispatchProfileNames)
$missingProfiles = @()
$createdProfiles = @()
$profileConflictDetected = $false

if (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) {
    Write-Host "  ✅ Codex 基礎設定檔存在：$codexConfigPath" -ForegroundColor DarkGreen
}
else {
    Write-Warning "  ⚠️ 找不到 Codex 設定檔：$codexConfigPath"
}

$legacyProfilePresent = Test-Path -LiteralPath $legacyProfilePath -PathType Leaf
foreach ($profileName in $requiredProfileNames) {
    $profileFileName = $profileName + '.config.toml'
    $profilePath = Join-Path $codexDir $profileFileName
    if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
        continue
    }
    if ($null -ne (Get-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue)) {
        Write-Warning "  ⚠️ $profilePath 已存在但不是可讀取的檔案（例如斷鏈或目錄）。腳本不會修改，請人工處理。"
        $missingProfiles += $profileFileName
        continue
    }
    if ($profileName -ceq 'advisor' -and $legacyProfilePresent) {
        # 舊檔名存在時由下方的重新命名指引處理，不另建 advisor.config.toml。
        $missingProfiles += $profileFileName
        continue
    }
    if (-not $codexProfileDefaults.Contains($profileName)) {
        Write-Warning "  ⚠️ Setup 沒有 $profileName 檔位的初始值，未建立 $profilePath。"
        $missingProfiles += $profileFileName
        continue
    }
    $profileDefault = $codexProfileDefaults[$profileName]
    $profileLines = @(
        "# Codex 檔位 $profileName。Setup 提供初始值，檔案建立後屬本機設定，可人工調整。"
        ('model = "' + $profileDefault.model + '"')
        ('model_reasoning_effort = "' + $profileDefault.effort + '"')
        ''
    ) + $codexProfileAgentsLines
    $profileBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(($profileLines -join [Environment]::NewLine) + [Environment]::NewLine)
    $profileCreatedByThisRun = $false
    try {
        $profileStream = [System.IO.File]::Open($profilePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $profileCreatedByThisRun = $true
        try {
            $profileStream.Write($profileBytes, 0, $profileBytes.Length)
        }
        finally {
            $profileStream.Dispose()
        }
        $createdProfiles += $profileFileName
        Write-Host "  ✅ 已建立 Codex 檔位設定檔：$profilePath" -ForegroundColor DarkGreen
    }
    catch {
        if ($profileCreatedByThisRun) {
            # 本次建立後寫入失敗，移除不完整的檔案，避免被當成已存在的設定檔。
            Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
        }
        elseif (Test-Path -LiteralPath $profilePath -PathType Leaf) {
            # 另一個 Setup 同時建立了同名檔案，視為已存在。
            continue
        }
        Write-Warning "  ⚠️ 無法建立 Codex 檔位設定檔 $profilePath：$($_.Exception.Message)"
        $missingProfiles += $profileFileName
    }
}

foreach ($profileName in (Get-CodexDispatchProfileNames)) {
    $scanProfilePath = Join-Path $codexDir ($profileName + '.config.toml')
    if (Test-Path -LiteralPath $scanProfilePath -PathType Leaf) {
        $maxEffortMatches += @(Select-String -LiteralPath $scanProfilePath -Pattern '^\s*model_reasoning_effort\s*=\s*["'']max["'']\s*$')
    }
}

$minimumMaxVersion = [version]'0.147.0'
if ($maxEffortMatches.Count -eq 0) {
    Write-Host "  ✅ 未偵測到需要檢查版本相容性的 max effort 設定。" -ForegroundColor DarkGreen
}
elseif ($null -eq $codexVersion) {
    Write-Warning "  ⚠️ 設定檔含 max effort，但目前無法取得 Codex 版本，請參考 README.md §8「疑難排解」。"
}
elseif ($codexVersion -lt $minimumMaxVersion) {
    Write-Warning "  ⚠️ Codex $codexVersion 不支援設定檔中的 max effort。請更新至不低於 $minimumMaxVersion 的版本，並參考 README.md §8「疑難排解」。"
}
else {
    Write-Host "  ✅ Codex $codexVersion 與 max effort 相容。" -ForegroundColor DarkGreen
}

if ($createdProfiles.Count -gt 0) {
    Write-Host "  ✅ 已依初始值建立缺少的 Codex 檔位設定檔：$($createdProfiles -join ', ')。建立後可人工調整，Setup 不會覆寫。" -ForegroundColor DarkGreen
}

$legacyDefaultDetected = Test-CodexLegacyDefaultProfile -Directory $codexDir
if ($legacyDefaultDetected) {
    Write-Warning "  ⚠️ 偵測到已停用的檔位設定檔 $legacyDefaultPath（default 檔位已移除，派工不再讀取）。腳本不會自動搬移或刪除；請先以 Remove-Item -LiteralPath 移除各帳號目錄內指向它的連結（只移除連結本身），再自行決定是否刪除此檔。對照規則見 skills/codex-dispatch/references/start.md 的「檔位用途與新舊對照」。"
}

if ($legacyProfilePresent) {
    if (-not (Test-Path -LiteralPath (Join-Path $codexDir 'advisor.config.toml') -PathType Leaf)) {
        Write-Warning "  ⚠️ 偵測到舊設定檔 $legacyProfileName。請將其重新命名為 advisor.config.toml 後重新執行 Setup。腳本不會自動搬移或刪除檔案。"
    }
    else {
        $profileConflictDetected = $true
        Write-Warning "  ⚠️ 偵測到 $legacyProfileName 與 advisor.config.toml 同時存在，設定檔發生衝突。請人工處理後再重新執行 Setup。腳本不會自動搬移或刪除檔案。"
    }
}

if ($missingProfiles.Count -gt 0) {
    Write-Warning "  ⚠️ Codex 檔位設定檔缺件：$($missingProfiles -join ', ')。請參考 README.md §3「Codex CLI 前置需求」。"
}
elseif (-not $profileConflictDetected) {
    Write-Host "  ✅ Codex 檔位設定檔（$($requiredProfileNames -join '、')）均存在。" -ForegroundColor DarkGreen
}
