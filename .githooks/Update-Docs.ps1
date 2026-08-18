#Requires -Version 5.1

# ----------------------------------------------------------------
# Update-Docs.ps1 - 自動產生 docs/*.md 索引表格與 instructions.md Skill 索引
# ----------------------------------------------------------------

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = Split-Path -Parent $PSScriptRoot
$docsDir = Join-Path $repoRoot "docs"
$claudeAgentsDir = Join-Path $repoRoot "agents\claude"
$codexAgentsDir = Join-Path $repoRoot "agents\codex"
$skillsDir = Join-Path $repoRoot "skills"
$instructionsPath = Join-Path $repoRoot "instructions.md"
$personaAgents = @("Clarify", "Implement", "Editor", "Debug")

function Get-FrontMatterValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Content,

        [Parameter(Mandatory)]
        [string]$Key
    )

    $escapedKey = [regex]::Escape($Key)
    $pattern = "^\s*${escapedKey}:\s*(.+?)\s*$"
    $frontMatterStarted = $false
    $frontMatterClosed = $false
    $value = $null

    foreach ($line in $Content) {
        $trimmedLine = $line.Trim()
        if (-not $frontMatterStarted) {
            if ($trimmedLine -eq "---") {
                $frontMatterStarted = $true
            }
            elseif (-not [string]::IsNullOrWhiteSpace($line)) {
                break
            }

            continue
        }

        if ($trimmedLine -eq "---") {
            $frontMatterClosed = $true
            break
        }

        if (($null -eq $value) -and ($line -match $pattern)) {
            $value = $matches[1].Trim().Trim("'").Trim('"')
        }
    }

    if ($frontMatterClosed) {
        return $value
    }

    return $null
}

function Get-TomlValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Content,

        [Parameter(Mandatory)]
        [string]$Key
    )

    $escapedKey = [regex]::Escape($Key)
    $pattern = "^\s*${escapedKey}\s*=\s*`"?(.+?)`"?\s*$"
    foreach ($line in $Content) {
        if ($line -match $pattern) {
            return $matches[1].Trim('"')
        }
    }

    return $null
}

function Get-TomlMetaValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Content,

        [Parameter(Mandatory)]
        [string]$Key
    )

    $escapedKey = [regex]::Escape($Key)
    $pattern = "^\s*#\s*doc-meta:\s*${escapedKey}\s*=\s*`"?(.+?)`"?\s*$"
    foreach ($line in $Content) {
        if ($line -match $pattern) {
            return $matches[1].Trim('"')
        }
    }

    return $null
}

function Assert-CodexTomlTopLevelKey {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Content,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $allowedKeys = @("name", "description", "developer_instructions")
    $inMultilineString = $false

    foreach ($line in $Content) {
        # 多行字串內容不參與頂層鍵判定，避免 developer_instructions 內的文字被誤判。
        if ($inMultilineString) {
            if ($line -match '"""') {
                $inMultilineString = $false
            }

            continue
        }

        if ($line -match '^\s*([A-Za-z0-9_-]+)\s*=\s*(.*)$') {
            $key = $matches[1]
            $value = $matches[2]

            if ($allowedKeys -notcontains $key) {
                throw "Codex agent TOML 僅允許頂層鍵 $($allowedKeys -join '、')，發現 '$key'：$Path"
            }

            if (($value -like '"""*') -and ($value -notmatch '""".*"""')) {
                $inMultilineString = $true
            }
        }
    }
}

function ConvertTo-BooleanValue {
    [CmdletBinding()]
    param (
        [AllowNull()]
        [string]$Value,

        [Parameter(Mandatory)]
        [bool]$DefaultValue
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $DefaultValue
    }

    switch ($Value.ToLowerInvariant()) {
        "true" { return $true }
        "false" { return $false }
        default { throw "布林欄位值無效：$Value" }
    }
}

function Write-DocFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    $content = ($Lines -join "`n") + "`n"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $content, $encoding)
}

function Get-AgentType {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($personaAgents -contains $Name) {
        return "Persona"
    }

    return "sub-agent"
}

function Assert-AgentAudience {
    [CmdletBinding()]
    param (
        [AllowNull()]
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if (($Value -ne "agent") -and ($Value -ne "human")) {
        throw "Agent audience 必須為 agent 或 human：$Path"
    }

    return $Value
}

function Get-SkillMetadata {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [System.IO.DirectoryInfo]$Directory
    )

    $skillFile = Join-Path $Directory.FullName "SKILL.md"
    if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) {
        return $null
    }

    $content = Get-Content -LiteralPath $skillFile -Encoding UTF8
    $name = Get-FrontMatterValue -Content $content -Key "name"
    $description = Get-FrontMatterValue -Content $content -Key "description"
    $audience = Get-FrontMatterValue -Content $content -Key "audience"
    $disableModelInvocationText = Get-FrontMatterValue -Content $content -Key "disable-model-invocation"
    $allowImplicitInvocationText = Get-FrontMatterValue -Content $content -Key "policy.allow_implicit_invocation"

    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "Skill 缺少 name：$skillFile"
    }

    if ([string]::IsNullOrWhiteSpace($description)) {
        throw "Skill 缺少 description：$skillFile"
    }

    if (($audience -ne "agent") -and ($audience -ne "human")) {
        throw "Skill audience 必須為 agent 或 human：$skillFile"
    }

    [pscustomobject]@{
        Name = $name
        Description = $description
        Audience = $audience
        DisableModelInvocation = ConvertTo-BooleanValue -Value $disableModelInvocationText -DefaultValue $false
        AllowImplicitInvocation = ConvertTo-BooleanValue -Value $allowImplicitInvocationText -DefaultValue $true
        Path = $skillFile
    }
}

function Assert-SkillFrontMatterConsistency {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object[]]$Skills
    )

    $violations = New-Object 'System.Collections.Generic.List[string]'
    foreach ($skill in $Skills) {
        $expectedAllowImplicitInvocation = -not $skill.DisableModelInvocation
        if ($skill.AllowImplicitInvocation -ne $expectedAllowImplicitInvocation) {
            $message = "{0}：disable-model-invocation={1}，policy.allow_implicit_invocation={2}，預期為 {3}" -f `
                $skill.Path, $skill.DisableModelInvocation, $skill.AllowImplicitInvocation, $expectedAllowImplicitInvocation
            [void]$violations.Add($message)
        }
    }

    if ($violations.Count -gt 0) {
        throw "Skill frontmatter 一致性閘門失敗：`n$($violations -join "`n")"
    }
}

function Get-SkillRows {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object[]]$Skills
    )

    @($Skills | Sort-Object Name | ForEach-Object {
        $type = if ($_.DisableModelInvocation) { "指令型" } else { "知識型" }
        "| ``$($_.Name)`` | $type | $($_.Audience) | $($_.Description) |"
    })
}

function Update-SkillIndex {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object[]]$Skills,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $beginMarker = '<!-- SKILL-INDEX:BEGIN -->'
    $endMarker = '<!-- SKILL-INDEX:END -->'
    $instructionsContent = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
    $pattern = "(?s)" + [regex]::Escape($beginMarker) + ".*?" + [regex]::Escape($endMarker)
    $match = [regex]::Match($instructionsContent, $pattern)

    if (-not $match.Success) {
        throw "instructions.md 缺少 Skill 索引標記：$Path"
    }

    $indexLines = New-Object 'System.Collections.Generic.List[string]'
    [void]$indexLines.Add($beginMarker)
    foreach ($skill in ($Skills | Sort-Object Name)) {
        [void]$indexLines.Add("- ``$($skill.Name)``：$($skill.Description)")
    }
    [void]$indexLines.Add($endMarker)
    $replacement = $indexLines -join "`n"

    $updatedContent = $instructionsContent.Substring(0, $match.Index) +
        $replacement +
        $instructionsContent.Substring($match.Index + $match.Length)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $updatedContent, $encoding)
}

try {
    # 1. 讀取並驗證 Skill frontmatter。
    $skillMetadata = @(
        Get-ChildItem -LiteralPath $skillsDir -Directory |
            Sort-Object Name |
            ForEach-Object { Get-SkillMetadata -Directory $_ }
    )
    Assert-SkillFrontMatterConsistency -Skills $skillMetadata

    # 2. 產生 docs/agents.md。
    $claudeRows = @(
        Get-ChildItem -LiteralPath $claudeAgentsDir -File -Filter "*.md" |
            Sort-Object Name |
            ForEach-Object {
                $content = Get-Content -LiteralPath $_.FullName -Encoding UTF8
                $name = Get-FrontMatterValue -Content $content -Key "name"
                $description = Get-FrontMatterValue -Content $content -Key "description"
                $audience = Assert-AgentAudience -Value (Get-FrontMatterValue -Content $content -Key "audience") -Path $_.FullName
                $agentType = Get-AgentType -Name $name
                "| ``$name`` | $agentType / Claude | $audience | $description |"
            }
    )

    $codexRows = @(
        Get-ChildItem -LiteralPath $codexAgentsDir -File -Filter "*.toml" |
            Sort-Object Name |
            ForEach-Object {
                $content = Get-Content -LiteralPath $_.FullName -Encoding UTF8
                Assert-CodexTomlTopLevelKey -Content $content -Path $_.FullName
                $name = Get-TomlValue -Content $content -Key "name"
                $description = Get-TomlValue -Content $content -Key "description"
                $audience = Assert-AgentAudience -Value (Get-TomlMetaValue -Content $content -Key "audience") -Path $_.FullName
                $agentType = Get-AgentType -Name $name
                "| ``$name`` | $agentType / Codex | $audience | $description |"
            }
    )

    Write-DocFile -Path (Join-Path $docsDir "agents.md") -Lines (@(
        "# 內建 Agent 清單",
        "",
        "| Agent | 類型 / 平台 | 讀者 | 用途 |",
        "| --- | --- | --- | --- |"
    ) + $claudeRows + $codexRows)

    # 3. 產生 docs/skills.md，依觸發方式分組。
    $userInvokedSkills = @($skillMetadata | Where-Object { $_.DisableModelInvocation })
    $modelInvokedSkills = @($skillMetadata | Where-Object { -not $_.DisableModelInvocation })
    $skillHeader = @(
        "| Skill | 類型 | 讀者 | 用途 |",
        "| --- | --- | --- | --- |"
    )
    $skillLines = @(
        "# 內建 Skill 清單",
        "",
        "## user-invoked",
        ""
    ) + $skillHeader + (Get-SkillRows -Skills $userInvokedSkills) + @(
        "",
        "## model-invoked",
        ""
    ) + $skillHeader + (Get-SkillRows -Skills $modelInvokedSkills)
    Write-DocFile -Path (Join-Path $docsDir "skills.md") -Lines $skillLines

    # 4. 更新 instructions.md 的可機械比對 Skill 索引。
    Update-SkillIndex -Skills $skillMetadata -Path $instructionsPath

    # 5. 納入本次 commit。
    & git -C $repoRoot add "docs/agents.md" "docs/skills.md" "instructions.md"
    if ($LASTEXITCODE -ne 0) {
        throw "git add 失敗，結束碼：$LASTEXITCODE"
    }

    Write-Host "docs/*.md 與 instructions.md 已更新並暫存。" -ForegroundColor Green
    exit 0
}
catch {
    Write-Error -Message ("Update-Docs.ps1 失敗：{0}" -f $_.Exception.Message) -ErrorAction Continue
    exit 1
}
