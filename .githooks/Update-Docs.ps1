# ----------------------------------------------------------------
# Update-Docs.ps1 - 自動產生 docs/*.md 索引表格
# ----------------------------------------------------------------

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = Split-Path -Parent $PSScriptRoot
$docsDir = Join-Path $repoRoot "docs"
$claudeAgentsDir = Join-Path $repoRoot "agents\claude"
$codexAgentsDir  = Join-Path $repoRoot "agents\codex"
$skillsDir = Join-Path $repoRoot "skills"
$personaAgents = @("Clarify", "Implement", "Debug", "Editor", "Propose")

function Get-FrontMatterValue {
    param (
        [string[]]$Content,
        [string]$Key
    )

    $pattern = "^\s*${Key}:\s*(.+?)\s*$"
    foreach ($line in $Content) {
        if ($line -match $pattern) {
            return $matches[1].Trim("'`"")
        }
    }

    return $null
}

function Get-TomlValue {
    param (
        [string[]]$Content,
        [string]$Key
    )

    $pattern = "^\s*${Key}\s*=\s*`"?(.+?)`"?\s*$"
    foreach ($line in $Content) {
        if ($line -match $pattern) {
            return $matches[1].Trim('"')
        }
    }

    return $null
}

function Write-DocFile {
    param (
        [string]$Path,
        [string[]]$Lines
    )

    $content = ($Lines -join "`n") + "`n"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $content, $encoding)
}

function Get-AgentType {
    param (
        [string]$Name
    )

    if ($personaAgents -contains $Name) {
        return "Persona"
    }

    return "sub-agent"
}

# 1. 產生 docs/agents.md
$claudeRows = Get-ChildItem -LiteralPath $claudeAgentsDir -File -Filter "*.md" |
    Sort-Object Name |
    ForEach-Object {
        $content = Get-Content -LiteralPath $_.FullName -Encoding UTF8
        $name = Get-FrontMatterValue -Content $content -Key "name"
        $description = Get-FrontMatterValue -Content $content -Key "description"
        $agentType = Get-AgentType -Name $name
        "| ``$name`` | $agentType / Claude | $description |"
    }

$codexRows = Get-ChildItem -LiteralPath $codexAgentsDir -File -Filter "*.toml" |
    Sort-Object Name |
    ForEach-Object {
        $content = Get-Content -LiteralPath $_.FullName -Encoding UTF8
        $name = Get-TomlValue -Content $content -Key "name"
        $description = Get-TomlValue -Content $content -Key "description"
        $agentType = Get-AgentType -Name $name
        "| ``$name`` | $agentType / Codex | $description |"
    }

Write-DocFile -Path (Join-Path $docsDir "agents.md") -Lines (@(
    "# 內建 Agent 清單",
    "",
    "| Agent | 類型 / 平台 | 用途 |",
    "| --- | --- | --- |"
) + $claudeRows + $codexRows)

# 2. 產生 docs/skills.md
# 類型判斷：disable-model-invocation: true → 指令型（使用者手動觸發）
#           未設定或 false              → 知識型（Claude 依上下文自動載入）
$skillRows = Get-ChildItem -LiteralPath $skillsDir -Directory |
    Sort-Object Name |
    ForEach-Object {
        $skillFile = Join-Path $_.FullName "SKILL.md"
        if (-not (Test-Path -LiteralPath $skillFile)) { return }
        $content = Get-Content -LiteralPath $skillFile -Encoding UTF8
        $name = Get-FrontMatterValue -Content $content -Key "name"
        $description = Get-FrontMatterValue -Content $content -Key "description"
        $disableInvocation = Get-FrontMatterValue -Content $content -Key "disable-model-invocation"
        $type = if ($disableInvocation -eq "true") { "指令型" } else { "知識型" }
        "| ``$name`` | $type | $description |"
    }

Write-DocFile -Path (Join-Path $docsDir "skills.md") -Lines (@(
    "# 內建 Skill 清單",
    "",
    "| Skill | 類型 | 用途 |",
    "| --- | --- | --- |"
) + $skillRows)

# 3. 納入本次 commit
git -C $repoRoot add "docs/agents.md" "docs/skills.md"

Write-Host "docs/*.md 已更新並暫存。" -ForegroundColor Green
