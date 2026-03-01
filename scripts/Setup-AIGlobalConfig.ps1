# ----------------------------------------------------------------
# Setup-AiGlobalConfig.ps1 - AI 全域設定連結自動化 (全版本相容驗證版)
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
$commitRules = "$configRoot\rules\commit.instructions.md"
$skillsPath = "$configRoot\skills"
$promptsPath = "$configRoot\prompts"
$rulesPath = "$configRoot\rules"

# 3. 實體檔案檢查
if (!(Test-Path $mainInstructions)) {
    Write-Host "ERROR: 找不到 $mainInstructions" -ForegroundColor Red
    return
}
if (!(Test-Path $commitRules)) {
    Write-Host "ERROR: 找不到 $commitRules" -ForegroundColor Red
    return
}

# 4. 準備工具目錄
$geminiDir = "$env:USERPROFILE\.gemini"
$agyDir = "$env:USERPROFILE\.gemini\antigravity"
$agyWorkflowsDir = "$env:USERPROFILE\.gemini\antigravity\global_workflows"
foreach ($dir in @($geminiDir, $agyDir)) {
    if (!(Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
}

# 5. 符號連結輔助函式
function Set-SymbolicLink {
    param (
        [string]$LinkPath,
        [string]$TargetPath,
        [string]$ItemType = "SymbolicLink"
    )
    if (Test-Path $LinkPath) {
        $existing = Get-Item $LinkPath -Force
        if ($existing.Attributes -match "ReparsePoint") {
            Remove-Item $LinkPath -Force
        }
        else {
            Write-Host "  ⚠️  略過：$LinkPath 已存在且非符號連結，請手動移除後重新執行。" -ForegroundColor Yellow
            return
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
$geminiMd = "$geminiDir\GEMINI.md"
if (Test-Path $geminiMd) {
    Remove-Item $geminiMd -Force
}
New-Item -ItemType SymbolicLink -Path $geminiMd -Target $mainInstructions -Force | Out-Null
Write-Host "  ✅  ~/.gemini/GEMINI.md  →  $mainInstructions" -ForegroundColor DarkGreen

# Antigravity：global_workflows → prompts/
Set-SymbolicLink -LinkPath $agyWorkflowsDir -TargetPath $promptsPath

# Antigravity：skills/ → ~/.ai-agents/skills/
Set-SymbolicLink -LinkPath "$agyDir\skills" -TargetPath $skillsPath

# Copilot：建立根目錄
$copilotDir = "$env:USERPROFILE\.copilot"
if (!(Test-Path $copilotDir)) { New-Item $copilotDir -ItemType Directory -Force | Out-Null }

# Copilot：skills/、prompts/、rules/ 三個連結
Set-SymbolicLink -LinkPath "$copilotDir\skills"  -TargetPath $skillsPath
Set-SymbolicLink -LinkPath "$copilotDir\prompts" -TargetPath $promptsPath
Set-SymbolicLink -LinkPath "$copilotDir\rules"   -TargetPath $rulesPath

# 6. 驗證回饋
Write-Host "`n>>> 設定完成！詳細連結路徑如下：" -ForegroundColor Green
Write-Host "----------------------------------------------------------------"

# 使用計算屬性，同時相容 PS 5.1 (.Target) 與 PS 7 (.LinkTarget)
$allDirs = @($geminiDir, $copilotDir)
foreach ($dir in $allDirs) {
    Get-ChildItem -Path $dir -Force -Recurse |
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
Write-Host "  - Antigravity skills → ~/.ai-agents/skills/（和 Copilot 共用）"
Write-Host "  - Antigravity global_workflows → ~/.ai-agents/prompts/（Prompt = Workflow）"
Write-Host "  - ~/.copilot/skills/ 和 ~/.copilot/prompts/ 連結至 ~/.ai-agents/ 對應目錄"
Write-Host "  - ~/.copilot/rules/ 連結至 ~/.ai-agents/rules/（確保相對路徑可解析）"
Write-Host "  - Visual Studio 不支援全域設定，需在各專案下放置 .github/"
