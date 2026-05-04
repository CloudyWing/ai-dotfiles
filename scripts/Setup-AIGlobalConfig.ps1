# ----------------------------------------------------------------
# Setup-AIGlobalConfig.ps1 - AI 全域設定連結自動化 (全版本相容驗證版)
# ----------------------------------------------------------------

# 1. 管理員權限檢查
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: 此腳本必須以『系統管理員身分』執行！" -ForegroundColor Red
    return
}

# 2. 定義路徑 (來源：~/.ai-agents/)
$configRoot = "$env:USERPROFILE\.ai-agents"
$mainInstructions = "$configRoot\instructions.md"
$skillsPath = "$configRoot\skills"
$claudeAgentsPath = "$configRoot\agents\claude"
$codexAgentsPath  = "$configRoot\agents\codex"

# 3. 實體檔案與原始目錄檢查
if (!(Test-Path $mainInstructions)) {
    Write-Host "ERROR: 找不到 $mainInstructions" -ForegroundColor Red
    return
}

# 4. 準備工具目錄
$geminiDir = "$env:USERPROFILE\.gemini"
$agyDir = "$env:USERPROFILE\.gemini\antigravity"
$claudeDir = "$env:USERPROFILE\.claude"
$codexDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { "$env:USERPROFILE\.codex" }
$agentsDir = "$env:USERPROFILE\.agents"
$agentsSkillsDir = "$agentsDir\skills"
foreach ($dir in @($geminiDir, $agyDir, $claudeDir, $codexDir, $agentsDir)) {
    if (!(Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
}

# 5. 符號連結輔助函式
function Set-SymbolicLink {
    param (
        [string]$LinkPath,
        [string]$TargetPath,
        [string]$ItemType = "SymbolicLink"
    )

    # 支援偵測斷鍊 (Broken Symlink)：Test-Path 會對斷鍊回傳 false，需改用 Get-Item / Get-ChildItem
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

    if (Test-Path $TargetPath) {
        New-Item -ItemType $ItemType -Path $LinkPath -Target $TargetPath -Force | Out-Null
        Write-Host "  ✅  $($LinkPath.Replace($env:USERPROFILE, '~'))  →  $TargetPath" -ForegroundColor DarkGreen
    }
    else {
        Write-Host "  ⚠️  略過：來源不存在 $TargetPath" -ForegroundColor Yellow
    }
}

# 6. 建立符號連結
Write-Host "`n>>> 正在建立符號連結..." -ForegroundColor Cyan

# Gemini CLI：全域規則（單一檔案連結）
Set-SymbolicLink -LinkPath "$geminiDir\GEMINI.md" -TargetPath $mainInstructions

# Antigravity：skills/ → ~/.ai-agents/skills/
Set-SymbolicLink -LinkPath "$agyDir\skills" -TargetPath $skillsPath

# Claude Code：全域記憶（CLAUDE.md）
Set-SymbolicLink -LinkPath "$claudeDir\CLAUDE.md" -TargetPath $mainInstructions

# Claude Code：skills/ → ~/.ai-agents/skills/
Set-SymbolicLink -LinkPath "$claudeDir\skills" -TargetPath $skillsPath

# Claude Code：agents/ → ~/.ai-agents/agents/claude/
Set-SymbolicLink -LinkPath "$claudeDir\agents" -TargetPath $claudeAgentsPath

# Codex：全域規則（AGENTS.md）
Set-SymbolicLink -LinkPath "$codexDir\AGENTS.md" -TargetPath $mainInstructions

# Codex：agents/ → ~/.ai-agents/agents/codex/
Set-SymbolicLink -LinkPath "$codexDir\agents" -TargetPath $codexAgentsPath

# Codex：~/.agents/skills/ → ~/.ai-agents/skills/
Set-SymbolicLink -LinkPath $agentsSkillsDir -TargetPath $skillsPath

# 7. 設定 Git Hooks 路徑
Write-Host "`n>>> 正在設定 Git Hooks..." -ForegroundColor Cyan
git -C $configRoot config core.hooksPath .githooks
Write-Host "  ✅  core.hooksPath → .githooks" -ForegroundColor DarkGreen

# 8. 驗證回饋
Write-Host "`n>>> 設定完成！詳細連結路徑如下：" -ForegroundColor Green
Write-Host "----------------------------------------------------------------"

# 使用計算屬性，同時相容 PS 5.1 (.Target) 與 PS 7 (.LinkTarget)
$allDirs = @($geminiDir, $agyDir, $claudeDir, $codexDir, $agentsDir)
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
Write-Host "  - 設定來源目錄為 ~/.ai-agents/"
Write-Host "  - Gemini CLI 透過 ~/.gemini/GEMINI.md 符號連結讀取"
Write-Host "  - Antigravity skills → ~/.ai-agents/skills/"
Write-Host "  - Claude Code 透過 ~/.claude/CLAUDE.md 符號連結讀取"
Write-Host "  - Claude Code skills → ~/.ai-agents/skills/"
Write-Host "  - Claude Code agents → ~/.ai-agents/agents/claude/"
Write-Host "  - Claude Code Hook 腳本位於 ~/.ai-agents/scripts/hooks/，由 ~/.claude/settings.json 直接引用"
Write-Host "  - Codex 透過 ~/.codex/AGENTS.md 符號連結讀取（或以 CODEX_HOME 指定路徑）"
Write-Host "  - Codex agents → ~/.ai-agents/agents/codex/"
Write-Host "  - Codex skills → ~/.agents/skills/"
Write-Host "  - Codex Hook 腳本範本位於 ~/.ai-agents/scripts/hooks/codex-hooks.json，需手動複製至 ~/.codex/hooks.json 並調整路徑"
