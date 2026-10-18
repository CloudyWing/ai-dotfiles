#Requires -Version 5.1

# ----------------------------------------------------------------
# Setup-AIGlobalConfig.ps1 - AI 全域設定連結自動化（收斂式安裝 / 含斷鍊清除）
# 支援 -WhatIf 預覽；相容 Windows PowerShell 5.1 與 PowerShell 7+。
# ----------------------------------------------------------------

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
Write-Host "  - Claude Code Hook 腳本位於 $configRootDisplay/scripts/hooks/，由 ~/.claude/settings.json 直接引用"
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
        foreach ($fileName in @('config.toml','default.config.toml','advisor.config.toml')) {
            $accountConfigPath = Join-Path $account.codex_home $fileName
            if (-not (Test-Path -LiteralPath $accountConfigPath -PathType Leaf)) {
                Write-Warning ('  帳號 ' + $account.name + ' 缺少 ' + $accountConfigPath + '。請依 README.md §3 人工準備；基礎 config 必要鍵待使用者驗證。')
            }
        }
        $accountIntensivePath = Join-Path $account.codex_home 'intensive.config.toml'
        if (Test-Path -LiteralPath $accountIntensivePath -PathType Leaf) {
            Write-Host ('  已偵測到選用設定檔：' + $accountIntensivePath)
        }
    }
}
catch {
    Write-Warning ($_.Exception.Message + '。請修正本機帳號清單；保留原預設目錄，未切換帳號。')
}

$codexConfigPath = Join-Path $codexDir "config.toml"
$defaultProfilePath = Join-Path $codexDir "default.config.toml"
$advisorProfilePath = Join-Path $codexDir "advisor.config.toml"
$intensiveProfilePath = Join-Path $codexDir "intensive.config.toml"
$legacyProfileName = 'deep' + '.config.toml'
$legacyProfilePath = Join-Path $codexDir $legacyProfileName
$maxEffortMatches = @()
if (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) {
    Write-Host "  ✅ Codex 基礎設定檔存在：$codexConfigPath" -ForegroundColor DarkGreen
}
else {
    Write-Warning "  ⚠️ 找不到 Codex 設定檔：$codexConfigPath"
}
if (Test-Path -LiteralPath $defaultProfilePath -PathType Leaf) {
    $maxEffortMatches = @(Select-String -LiteralPath $defaultProfilePath -Pattern '^\s*model_reasoning_effort\s*=\s*["'']max["'']\s*$')
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

$missingProfiles = @()
$profileConflictDetected = $false
if (-not (Test-Path -LiteralPath $defaultProfilePath -PathType Leaf)) {
    $missingProfiles += 'default.config.toml'
}
if (-not (Test-Path -LiteralPath $advisorProfilePath -PathType Leaf)) {
    $missingProfiles += 'advisor.config.toml'
}
if (Test-Path -LiteralPath $intensiveProfilePath -PathType Leaf) {
    Write-Host "  ✅ 已偵測到選用 Codex 檔位設定檔：$intensiveProfilePath" -ForegroundColor DarkGreen
}

if (Test-Path -LiteralPath $legacyProfilePath -PathType Leaf) {
    if (-not (Test-Path -LiteralPath $advisorProfilePath -PathType Leaf)) {
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
    Write-Host "  ✅ Codex 預設檔位與 advisor.config.toml 均存在。" -ForegroundColor DarkGreen
}
