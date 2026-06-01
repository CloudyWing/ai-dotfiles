# ----------------------------------------------------------------
# Setup-AIGlobalConfig.ps1 - AI 全域設定連結自動化（收斂式安裝 / 含斷鍊清除）
# 支援 -WhatIf 預覽；相容 Windows PowerShell 5.1 與 PowerShell 7+。
# ----------------------------------------------------------------

[CmdletBinding(SupportsShouldProcess)]
param()

# 1. 管理員權限檢查
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: 此腳本必須以『系統管理員身分』執行！" -ForegroundColor Red
    return
}

# 2. 定義路徑：刻意寫死，與內容層 instructions.md / skill 的 ~/.ai-agents/ 引用共用同一不變量
$configRoot = "$env:USERPROFILE\.ai-agents"
$configRootDisplay = $configRoot.Replace($env:USERPROFILE, '~')
$mainInstructions = Join-Path $configRoot "instructions.md"

# 3. 實體檔案與原始目錄檢查
if (!(Test-Path $mainInstructions)) {
    Write-Host "ERROR: 找不到 $mainInstructions" -ForegroundColor Red
    Write-Host "       請確認腳本位於 <configRoot>\scripts\ 之下。" -ForegroundColor Red
    return
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
        [string]$ItemType = "SymbolicLink"
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

# 7. 建立現役連結（逐條收斂）
Write-Host "`n>>> 正在建立符號連結..." -ForegroundColor Cyan
foreach ($entry in $desired) {
    $target = Join-Path $configRoot $entry.Source
    Set-SymbolicLink -LinkPath $entry.Link -TargetPath $target
}

# 8. 清除斷鍊孤兒：只刪「指向 configRoot 但來源已不存在」者；仍能解析的連結保留
Write-Host "`n>>> 正在清除斷鍊孤兒..." -ForegroundColor Cyan
$rootPrefix = $configRoot.TrimEnd('\')
$orphans = foreach ($root in ($sweepRoots | Sort-Object -Unique)) {
    if (!(Test-Path $root)) { continue }
    Get-ChildItem -Path $root -Recurse -Depth 3 -Force -ErrorAction SilentlyContinue |
    Where-Object {
        if (-not ($_.Attributes -match 'ReparsePoint')) { return $false }
        $t = if ($_.Target) { $_.Target } else { $_.LinkTarget }
        $t = ($t -join '')
        if (-not $t.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
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
    Write-Host "  ✅  core.hooksPath → .githooks" -ForegroundColor DarkGreen
}

# 10. 驗證回饋
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
Write-Host "  - Claude Code 透過 ~/.claude/CLAUDE.md 符號連結讀取"
Write-Host "  - Claude Code skills → $configRootDisplay/skills/"
Write-Host "  - Claude Code agents → $configRootDisplay/agents/claude/"
Write-Host "  - Claude Code Hook 腳本位於 $configRootDisplay/scripts/hooks/，由 ~/.claude/settings.json 直接引用"
Write-Host "  - Codex 透過 ~/.codex/AGENTS.md 符號連結讀取（或以 CODEX_HOME 指定路徑）"
Write-Host "  - Codex agents → $configRootDisplay/agents/codex/"
Write-Host "  - Codex skills → ~/.agents/skills/"
Write-Host "  - Codex Hook 腳本範本位於 $configRootDisplay/scripts/hooks/codex-hooks.json，需手動複製至 ~/.codex/hooks.json 並調整路徑"
