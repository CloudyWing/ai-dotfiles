#Requires -Version 5.1

# ----------------------------------------------------------------
# Setup-AIGlobalConfig.ps1 - AI 全域設定連結自動化（收斂式安裝 / 含斷鍊清除）
# 支援 -WhatIf 預覽與 -Check 唯讀檢查（只回報現況與是否符合預期，不建立、不修改、不刪除）；只支援 PowerShell 7 以上，於 Windows PowerShell 5.1 啟動時印出安裝指引並以非零結束碼結束。
# ----------------------------------------------------------------

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force,
    [switch]$EnableLongPaths,
    [switch]$Check,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 版本判斷：Setup 只支援 PowerShell 7 以上。
# 檔首維持 #Requires -Version 5.1，使 Windows PowerShell 5.1 能執行到這裡並印出安裝指引。
# 本檔本體必須維持 5.1 可解析，不得使用 7 專屬語法；下方 dot-source 的模組含 #Requires -Version 7.0，只能在此判斷之後載入。
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error ("Setup-AIGlobalConfig.ps1 只支援 PowerShell 7 以上，目前版本為 {0}。" -f $PSVersionTable.PSVersion) -ErrorAction Continue
    Write-Error "請先安裝 PowerShell 7：winget install Microsoft.PowerShell" -ErrorAction Continue
    Write-Error "安裝後以系統管理員身分開啟 pwsh 重新執行本腳本。" -ErrorAction Continue
    exit 1
}

# -Check 是唯讀模式：不接受會改動系統的參數；-AsJson 只輸出 -Check 的結果。
if ($AsJson -and -not $Check) {
    Write-Error "-AsJson 只能與 -Check 一起使用。" -ErrorAction Continue
    exit 1
}
if ($Check -and ($Force -or $EnableLongPaths)) {
    Write-Error "-Check 為唯讀模式，不能與 -Force 或 -EnableLongPaths 一起使用。" -ErrorAction Continue
    exit 1
}

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

if (-not $Check -and [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
    $longPathPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdministrator = $longPathPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Set-WindowsLongPaths -Enable:$EnableLongPaths -IsAdministrator $isAdministrator
}
# 1. 管理員權限檢查
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $Check -and -not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "此腳本必須以『系統管理員身分』執行！" -ErrorAction Continue
    exit 1
}

# 2. 定義路徑：刻意寫死，與內容層 instructions.md / skill 的 ~/.ai-agents/ 引用共用同一不變量
$configRoot = "$env:USERPROFILE\.ai-agents"
$configRootDisplay = $configRoot.Replace($env:USERPROFILE, '~')
$mainInstructions = Join-Path $configRoot "instructions.md"
$gitGlobalExcludes = Join-Path $configRoot "git-global-excludes"

# 3. 實體檔案與原始目錄檢查
if (-not $Check -and !(Test-Path $mainInstructions)) {
    Write-Error "找不到 $mainInstructions" -ErrorAction Continue
    Write-Error "請確認腳本位於 <configRoot>\scripts\ 之下。" -ErrorAction Continue
    exit 1
}

if (-not $Check -and !(Test-Path $gitGlobalExcludes)) {
    Write-Error "找不到機器層排除清單 $gitGlobalExcludes" -ErrorAction Continue
    exit 1
}

# 4. 準備工具目錄
$claudeDir = "$env:USERPROFILE\.claude"
$codexDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { "$env:USERPROFILE\.codex" }
$agentsDir = "$env:USERPROFILE\.agents"
foreach ($dir in @($claudeDir, $codexDir, $agentsDir)) {
    if (-not $Check -and !(Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
}

# 5. 連結清單：增減工具改這張表即可。Source 為 configRoot 下相對路徑
$desired = @(
    @{ Link = "$claudeDir\CLAUDE.md"; Source = "instructions.md" }
    @{ Link = "$claudeDir\skills";    Source = "skills" }
    @{ Link = "$claudeDir\agents";    Source = "agents\claude" }
    @{ Link = "$claudeDir\rules";     Source = "rules\claude" }
    @{ Link = "$codexDir\AGENTS.md";  Source = "instructions.md" }
    @{ Link = "$codexDir\agents";     Source = "agents\codex" }
    @{ Link = "$agentsDir\skills";    Source = "skills" }
)

# 其餘預期狀態：執行模式與 -Check 都讀這幾個值，不另存第二份。
$expectedHooksPath = '.githooks'
$claudeMarketplaceRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'claude-plugins'
# 此路徑用來辨識舊 hook 項目。
$legacyHookPattern = '*scripts/hooks/post-edit-write-hook.ps1*'
# Claude 使用者層設定：settings.json 共用範本與 settings.json 的位置（執行模式的官方外掛與 settings 步驟和 -Check 共用）。
$claudeSettingsTemplatePath = Join-Path $configRoot 'templates\claude-settings.shared.json'
$claudeSettingsPath = Join-Path $claudeDir 'settings.json'

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

# Claude Code 使用者層設定模組（Claude CLI 呼叫函式、官方外掛安裝、settings.json 合併；執行模式與 -Check 共用）：只定義函式，須在版本判斷之後載入。
. (Join-Path $PSScriptRoot 'lib\claude-user-config.ps1')

function Get-ClaudePluginSpec {
    param([string]$MarketplaceRoot)
    $manifest = Get-Content -LiteralPath (Join-Path $MarketplaceRoot '.claude-plugin\marketplace.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $specs = @()
    foreach ($entry in @($manifest.plugins)) {
        if ($entry.source -isnot [string] -or -not $entry.source.StartsWith('./') -or [string]::IsNullOrWhiteSpace([string]$entry.name)) { throw 'marketplace plugin 的 name 或 source 不正確。' }
        $specs += [pscustomobject]@{ Name = [string]$entry.name; Id = ([string]$entry.name + '@ai-agents-local'); Directory = (Join-Path $MarketplaceRoot $entry.source.Substring(2)) }
    }
    if ($specs.Count -eq 0 -or @($specs | Where-Object { $_.Name -eq 'ai-agents-hooks' }).Count -ne 1) { throw 'marketplace plugin 清單為空或缺少 ai-agents-hooks。' }
    return $specs
}

# 斷鍊孤兒：指向 configRoot 但來源已不存在的連結（執行模式的 8 與 -Check 共用）
function Get-BrokenConfigLink {
    param([string[]]$SweepRoot, [string]$ConfigRoot)
    $rootPrefix = $ConfigRoot.TrimEnd('\')
    $rootPrefixWithSeparator = $rootPrefix + [System.IO.Path]::DirectorySeparatorChar
    $found = foreach ($root in ($SweepRoot | Sort-Object -Unique)) {
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
    return @($found)
}

# -Check：唯讀檢查，用上面的預期狀態比對現況後結束，不進入下方任何會改動系統的步驟。
if ($Check) {
    # 共用模組（只定義函式）：須在版本判斷之後載入；執行模式在步驟 12 的檔位設定檔段才載入。
    . (Join-Path $PSScriptRoot 'codex-run\45-profile-sync.ps1')
    . (Join-Path $PSScriptRoot 'dispatch\common-runtime.ps1')
    . (Join-Path $PSScriptRoot 'dispatch\git-baseline.ps1')
    . (Join-Path $PSScriptRoot 'dispatch\dispatch-evidence.ps1')
    . (Join-Path $PSScriptRoot 'lib\setup-check.ps1')
    $checkExitCode = Invoke-SetupCheck -Expected @{
        ConfigRoot           = $configRoot
        MainInstructions     = $mainInstructions
        GitExcludesFile      = $gitGlobalExcludes
        ToolDirectories      = @($claudeDir, $codexDir, $agentsDir)
        ClaudeDirectory      = $claudeDir
        Links                = $desired
        SweepRoots           = $sweepRoots
        MarketplaceRoot      = $claudeMarketplaceRoot
        HooksPath            = $expectedHooksPath
        LegacyHookPattern    = $legacyHookPattern
        SettingsPath        = $claudeSettingsPath
        SettingsTemplatePath = $claudeSettingsTemplatePath
    } -AsJson:$AsJson
    exit $checkExitCode
}

# 7. 建立現役連結（逐條收斂）
Write-Host "`n>>> 正在建立符號連結..." -ForegroundColor Cyan
foreach ($entry in $desired) {
    $target = Join-Path $configRoot $entry.Source
    Set-SymbolicLink -LinkPath $entry.Link -TargetPath $target -Force:$Force
}

# 8. 清除斷鍊孤兒：只刪「指向 configRoot 但來源已不存在」者；仍能解析的連結保留
Write-Host "`n>>> 正在清除斷鍊孤兒..." -ForegroundColor Cyan
$orphans = @(Get-BrokenConfigLink -SweepRoot $sweepRoots -ConfigRoot $configRoot)
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
$claudePluginEnabled = $false
try {
    if ($null -eq (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue) -or -not (Test-Path -LiteralPath (Join-Path $claudeMarketplaceRoot '.claude-plugin\marketplace.json') -PathType Leaf)) { throw '找不到 claude CLI 或 marketplace 清單，略過 plugin 註冊。' }
    $specs = @(Get-ClaudePluginSpec -MarketplaceRoot $claudeMarketplaceRoot)
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
                if ($text -like $legacyHookPattern) { $removed++; $groupRemoved++ } else { $items += $item }
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

# 8d、8e. Claude 使用者層設定：官方外掛、settings.json 共用範本。
# 步驟內容與輸出在 lib\claude-user-config.ps1，這裡只呼叫；各步驟失敗只警告，不中斷其餘步驟，也不改變結束碼（與 8b 相同）。
# 授權（permissions）與偏好類的設定不在範本內，由使用者自行設定。MCP 伺服器（mcp-lab、infra-lab、FlaUI）的登記不在 Setup，由 scripts\Register-McpServer.ps1 處理。

# 8d. 必裝的官方外掛（清單取自 settings 範本 enabledPlugins 中的官方 marketplace 項目）
Write-Host "`n>>> 正在處理 Claude 官方外掛..." -ForegroundColor Cyan
try { Invoke-ClaudeOfficialPluginStep -SettingsTemplatePath $claudeSettingsTemplatePath -SettingsPath $claudeSettingsPath -WhatIf:$WhatIfPreference | Out-Null }
catch { Write-Warning $_.Exception.Message }

# 8e. 套用 settings.json 共用範本（只新增缺少的項目，不覆寫既有值；寫入前備份；尚未安裝的外掛略過其 enabledPlugins 項目）
Write-Host "`n>>> 正在套用 Claude settings.json 共用範本..." -ForegroundColor Cyan
# 讀取後檔案被其他程式改動（changed）或寫入目標無法確定（unresolved）時沒有寫入，Setup 在最後以非零結束碼提醒重跑；其他略過與失敗維持只警告。
$claudeSettingsNotWritten = $false
try {
    $claudeSettingsResult = Invoke-ClaudeSettingsStep -SettingsPath $claudeSettingsPath -TemplatePath $claudeSettingsTemplatePath -BackupRoot (Join-Path $configRoot '.local\ai-sessions\backups') -WhatIf:$WhatIfPreference
    if ($null -ne $claudeSettingsResult -and $claudeSettingsResult.Status -in @('changed', 'unresolved')) { $claudeSettingsNotWritten = $true }
}
catch { Write-Warning $_.Exception.Message }

# 9. 設定 Git Hooks 路徑
Write-Host "`n>>> 正在設定 Git Hooks..." -ForegroundColor Cyan
if ($PSCmdlet.ShouldProcess("$configRoot", "設定 core.hooksPath → $expectedHooksPath")) {
    git -C $configRoot config core.hooksPath $expectedHooksPath
    if ($LASTEXITCODE -ne 0) {
        throw "設定 core.hooksPath 失敗，結束碼：$LASTEXITCODE"
    }
    Write-Host "  ✅  core.hooksPath → $expectedHooksPath" -ForegroundColor DarkGreen
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
Write-Host "  - Claude Code rules → $configRootDisplay/rules/claude/（只在 Claude 端載入的常駐規則）"
Write-Host "  - Claude Code plugin 由本機 marketplace 提供，包含 ai-agents-hooks@ai-agents-local 與 line-status-board@ai-agents-local，原始碼位於 $($claudeMarketplaceRoot.Replace($env:USERPROFILE, '~'))"
Write-Host "  - mcp-lab、infra-lab 與 FlaUI.Mcp 的 MCP 登記不在 Setup 處理，安裝並啟動後執行 $configRootDisplay/scripts/Register-McpServer.ps1，說明見 README.md"
Write-Host "  - Claude Code settings.json 只套用共用範本（$configRootDisplay/templates/claude-settings.shared.json）中缺少的項目，不覆寫既有值；授權（permissions）與偏好類設定不在範本內，由你自行設定。寫入前的原檔備份在 $configRootDisplay/.local/ai-sessions/backups/"
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

# 載入共用模組（只定義函式）：須在版本判斷之後載入。
. (Join-Path $PSScriptRoot 'codex-run\45-profile-sync.ps1')
. (Join-Path $PSScriptRoot 'dispatch\common-runtime.ps1')
. (Join-Path $PSScriptRoot 'dispatch\git-baseline.ps1')
. (Join-Path $PSScriptRoot 'dispatch\dispatch-evidence.ps1')

# 檔位設定檔：登錄表是唯一來源，產生檔放在來源 checkout 的 scripts\codex-profiles（由 pre-commit 產生並進版控）。
# Setup 把各派工帳號目錄的檔位檔建成指向產生檔的 Symbolic Link，並比對現況。
# 「建立連結」與「比對現況」是 45-profile-sync.ps1 內可分開呼叫的函式（New-CodexProfileAccountLink、Get-CodexProfileAccountState）。
# 帳號目錄已有一般檔案或指向別處的連結時不覆蓋，只列出狀態與使用者要執行的命令。
$profileBlockedCount = 0
$profileSpecs = @()
$profileGeneratedDirectory = Get-CodexProfileGeneratedDirectory -RepoRoot $configRoot
try {
    $profileSpecs = @(Read-CodexProfileSpec -RegistryPath (Get-CodexProfileRegistryPath -RepoRoot $configRoot))
}
catch {
    Write-Warning ('  讀取登錄表的檔位設定失敗：' + $_.Exception.Message)
    $profileBlockedCount++
}
$profileLinkCommands = New-Object 'System.Collections.Generic.List[string]'
# 建立連結前先確認 repo 內的產生檔與登錄表一致（缺檔、內容過期或有多餘檔案都算不一致），否則連到過期設定。
$profileGeneratedStale = $false
$profileResidueCommands = New-Object 'System.Collections.Generic.List[string]'
$retiredProfileNames = @()
if ($profileSpecs.Count -gt 0) {
    $retiredProfileNames = @(Get-CodexRetiredProfileName -RegistryPath (Get-CodexProfileRegistryPath -RepoRoot $configRoot))
    $staleChanges = @(Sync-CodexProfileGeneratedFile -RegistryPath (Get-CodexProfileRegistryPath -RepoRoot $configRoot) -OutputDirectory $profileGeneratedDirectory -CheckOnly)
    if ($staleChanges.Count -gt 0) {
        $profileGeneratedStale = $true
        $profileBlockedCount++
        foreach ($staleChange in $staleChanges) { Write-Warning ('  檔位產生檔與登錄表不一致（' + $staleChange.action + '）：' + $staleChange.path) }
        Write-Warning '  未建立任何檔位設定檔連結。請先在登錄表所在的 checkout 重新產生並 commit，再重跑 Setup。'
        $profileLinkCommands.Add('# 重新產生檔位設定檔（不需要系統管理員）')
        $profileLinkCommands.Add('pwsh -NoProfile -File ' + (ConvertTo-CodexProfileQuoted -Text (Join-Path $configRoot '.githooks\Update-CodexProfiles.ps1')))
    }
}
$machineAccounts = @()
$machineReadFailed = $false
try {
    $machineAccounts = @(Read-CodexAccountConfiguration -MachineConfigPath (Join-Path $configRoot '.local\machine.json'))
}
catch {
    $machineReadFailed = $true
    $profileBlockedCount++
    Write-Warning ('  讀取 .local\machine.json 的帳號登記失敗：' + $_.Exception.Message + '。請修正該檔後重跑 Setup；本次沒有建立任何檔位設定檔連結。')
}
foreach ($account in $machineAccounts) {
    Write-Host ('  Codex 帳號 ' + $account.name + '：' + $account.codex_home)
    $accountConfigPath = Join-Path $account.codex_home 'config.toml'
    if (-not (Test-Path -LiteralPath $accountConfigPath -PathType Leaf)) {
        Write-Warning ('  帳號 ' + $account.name + ' 缺少 ' + $accountConfigPath + '。請依 README.md §3 人工準備；基礎 config 必要鍵待使用者驗證。')
    }
    if ($profileSpecs.Count -eq 0 -or $profileGeneratedStale) { continue }
    $linkResults = @(New-CodexProfileAccountLink -AccountHome $account.codex_home -ProfileDirectory $profileGeneratedDirectory -Spec $profileSpecs -WhatIf:$WhatIfPreference)
    foreach ($linkResult in $linkResults) {
        switch ($linkResult.action) {
            'ok' { Write-Host ('  ✅ ' + $linkResult.path + ' 已指向 ' + $linkResult.expected_target) -ForegroundColor DarkGreen }
            'created' { Write-Host ('  ✅ 已建立連結 ' + $linkResult.path + ' → ' + $linkResult.expected_target) -ForegroundColor DarkGreen }
            'would-create' { Write-Host ('  將建立連結 ' + $linkResult.path + ' → ' + $linkResult.expected_target) }
            'target-missing' {
                Write-Warning ('  ' + $linkResult.path + ' 未建立：repo 產生檔不存在 ' + $linkResult.expected_target)
                $profileBlockedCount++
            }
            'create-failed' {
                Write-Warning ('  ' + $linkResult.path + ' 建立連結失敗：' + $linkResult.error + '。已建立的連結保留（它們是正確狀態，不回復），修正原因後重跑 Setup 即可補完；建立 Symbolic Link 需要系統管理員身分的 pwsh。')
                $profileBlockedCount++
            }
            default {
                $actualText = $linkResult.kind
                if ($null -ne $linkResult.actual_target) { $actualText = $linkResult.kind + ' → ' + $linkResult.actual_target }
                Write-Warning ('  帳號 ' + $account.name + ' 的檔位設定檔 ' + $linkResult.path + ' 狀態為 ' + $linkResult.state + '（' + $actualText + '），預期為指向 ' + $linkResult.expected_target + ' 的 Symbolic Link。Setup 不覆蓋既有檔案或連結。')
                $profileLinkCommands.Add('# 帳號 ' + $account.name + ' 的 ' + $linkResult.path)
                foreach ($fixLine in @(Format-CodexProfileFixLine -Command $linkResult.fix_commands -Note $linkResult.fix_note)) { $profileLinkCommands.Add($fixLine) }
                $profileBlockedCount++
            }
        }
    }
    foreach ($residuePath in @(Get-CodexProfileResidue -Directory $account.codex_home -RetiredName $retiredProfileNames)) {
        Write-Warning ('  帳號 ' + $account.name + ' 殘留已退役的檔位設定檔：' + $residuePath + '。派工不再讀取，腳本不會刪除；移除命令列在最後。')
        $profileResidueCommands.Add('Remove-Item -LiteralPath ' + (ConvertTo-CodexProfileQuoted -Text $residuePath))
    }
    # 測試取證檔位的 MCP 伺服器：指令路徑因機器而異，缺少時從 Codex Desktop 的 config.toml 讀取並以 enabled = false 追加到帳號 config.toml。
    $mcpOutcome = Invoke-CodexMcpAccountSetup -AccountName $account.name -AccountHome $account.codex_home -Spec $profileSpecs -SourceConfigPath (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\config.toml') -WhatIf:$WhatIfPreference
    foreach ($mcpMessage in @($mcpOutcome.messages)) {
        switch ($mcpMessage.level) {
            'success' { Write-Host ('  ✅ ' + $mcpMessage.text) -ForegroundColor DarkGreen }
            'info' { Write-Host ('  ' + $mcpMessage.text) }
            default { Write-Warning ('  ' + $mcpMessage.text) }
        }
    }
    $profileBlockedCount += [int]$mcpOutcome.blocked
}
if ($machineAccounts.Count -eq 0 -and -not $machineReadFailed) {
    Write-Warning '  沒有登記的派工帳號，未建立檔位設定檔連結。請先以 New-CodexDispatchAccount.ps1 登記帳號。'
}

# ~\.codex 是 Codex 桌面版自己的目錄。派工只讀帳號目錄的連結，此處的檔位檔不再被使用，只列出，不刪除。
$codexConfigPath = Join-Path $codexDir 'config.toml'
if (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) {
    Write-Host "  ✅ Codex 基礎設定檔存在：$codexConfigPath" -ForegroundColor DarkGreen
}
else {
    Write-Warning "  ⚠️ 找不到 Codex 設定檔：$codexConfigPath"
}
$desktopActivePaths = @()
foreach ($profileSpec in $profileSpecs) {
    $desktopProfilePath = Join-Path $codexDir $profileSpec.FileName
    if ($null -ne (Get-Item -LiteralPath $desktopProfilePath -Force -ErrorAction SilentlyContinue)) { $desktopActivePaths += $desktopProfilePath }
}
# 登錄表內現行檔位的檔案：已登記派工帳號且連結都已改接時才可移除；沒有登記派工帳號時，舊入口回退使用這些檔案，不可移除。
if ($desktopActivePaths.Count -gt 0) {
    if ($machineReadFailed -or $profileBlockedCount -gt 0) {
        Write-Warning ('  ' + $codexDir + ' 內有現行檔位的設定檔（' + ($desktopActivePaths -join '、') + '）。帳號目錄的連結尚未全部就緒，先不要移除。')
    }
    elseif ($machineAccounts.Count -eq 0) {
        Write-Warning ('  ' + $codexDir + ' 內有現行檔位的設定檔（' + ($desktopActivePaths -join '、') + '）。沒有登記派工帳號時，舊入口回退使用這些檔案，請不要移除；要移除前先以 New-CodexDispatchAccount.ps1 登記派工帳號並重跑 Setup。')
    }
    else {
        Write-Host ('  ' + $codexDir + ' 內有派工不再讀取的檔位設定檔：' + ($desktopActivePaths -join '、') + '。各帳號目錄的連結都已就緒，可自行移除，命令列在最後。') -ForegroundColor Yellow
        foreach ($desktopActivePath in $desktopActivePaths) { $profileResidueCommands.Add('Remove-Item -LiteralPath ' + (ConvertTo-CodexProfileQuoted -Text $desktopActivePath)) }
    }
}
foreach ($desktopResiduePath in @(Get-CodexProfileResidue -Directory $codexDir -RetiredName $retiredProfileNames)) {
    Write-Warning ('  ' + $codexDir + ' 殘留已退役的檔位設定檔：' + $desktopResiduePath + '。派工不再讀取，腳本不會刪除；移除命令列在最後。')
    $profileResidueCommands.Add('Remove-Item -LiteralPath ' + (ConvertTo-CodexProfileQuoted -Text $desktopResiduePath))
}

# max effort 需要 Codex 0.147.0 以上，依登錄表內的設定判斷。
$minimumMaxVersion = [version]'0.147.0'
$maxEffortProfiles = @($profileSpecs | Where-Object { $_.Effort -ceq 'max' -or $_.SubagentEffort -ceq 'max' })
if ($maxEffortProfiles.Count -eq 0) {
    Write-Host "  ✅ 登錄表未使用需要檢查版本相容性的 max effort。" -ForegroundColor DarkGreen
}
elseif ($null -eq $codexVersion) {
    Write-Warning "  ⚠️ 登錄表含 max effort，但目前無法取得 Codex 版本，請確認 codex 已安裝且在 PATH 中。"
}
elseif ($codexVersion -lt $minimumMaxVersion) {
    Write-Warning "  ⚠️ Codex $codexVersion 不支援登錄表中的 max effort。請更新至不低於 $minimumMaxVersion 的版本。"
}
else {
    Write-Host "  ✅ Codex $codexVersion 與 max effort 相容。" -ForegroundColor DarkGreen
}

if ($profileLinkCommands.Count -gt 0) {
    Write-Host ''
    Write-Host '以下帳號目錄的檔位設定檔需要由你處理，每一行可直接貼到系統管理員 pwsh 執行（# 開頭為說明），處理後重新執行 Setup：' -ForegroundColor Yellow
    foreach ($profileLinkCommand in $profileLinkCommands) { Write-Host $profileLinkCommand }
}
if ($profileResidueCommands.Count -gt 0) {
    Write-Host ''
    Write-Host '以下為可自行執行的清理命令（每行一個，只移除所列的連結或檔案本身）：' -ForegroundColor Yellow
    foreach ($residueCommand in $profileResidueCommands) { Write-Host $residueCommand }
}
if ($profileBlockedCount -gt 0) {
    Write-Warning "  ⚠️ Codex 檔位設定檔尚未全部就緒（$profileBlockedCount 項），請依上列訊息處理。"
    exit 1
}
if ($claudeSettingsNotWritten) {
    Write-Warning '  ⚠️ Claude settings.json 沒有寫入（原因見上方 8e 的警告），請處理後重跑 Setup。'
    exit 1
}
Write-Host "  ✅ Codex 檔位設定檔（$(($profileSpecs | ForEach-Object { $_.Profile }) -join '、')）均已指向 repo 產生檔。" -ForegroundColor DarkGreen
