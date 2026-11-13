#Requires -Version 7.0
<#
.SYNOPSIS
    檢查進版控的 .md 與 .toml 是否含本機磁碟機絕對路徑。
.DESCRIPTION
    預設掃描 staged 的新增行；加 -All 掃描全部受控檔。有違規時輸出 <相對路徑>:<行號>: <token>
    並以退出碼 1 結束。.local 目錄與 *.local.md 不檢查。偵測規則見 hooks/lib/doc-path-check.ps1。
.PARAMETER RepoRoot
    被掃描的 repo 根目錄。預設為目前目錄的 git rev-parse --show-toplevel。
.PARAMETER All
    掃描 git ls-files 列出的全部檔案，不限 staged 新增行。
.PARAMETER Extension
    要檢查的副檔名，預設 .md 與 .toml。
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,

    [switch]$All,

    [string[]]$Extension = @('.md', '.toml')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# $PSScriptRoot 指本腳本所在的 .githooks，與 -RepoRoot（被掃描的 repo）無關。
. (Join-Path $PSScriptRoot '..\claude-plugins\ai-agents-hooks\hooks\lib\doc-path-check.ps1')

function Invoke-GitCommand {
    param(
        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string[]]$GitArgument
    )

    $output = & git -C $WorkingDirectory -c core.quotepath=false @GitArgument
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgument -join ' ') 失敗，退出碼 $LASTEXITCODE（工作目錄 $WorkingDirectory）"
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Test-TargetExtension {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string[]]$Allowed
    )

    $actual = [System.IO.Path]::GetExtension($Path)
    foreach ($item in $Allowed) {
        $normalized = if ($item.StartsWith('.')) { $item } else { '.' + $item }
        if ($actual -ieq $normalized) {
            return $true
        }
    }
    return $false
}

function Get-StagedAddedLine {
    param(
        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    $diff = Invoke-GitCommand -WorkingDirectory $WorkingDirectory -GitArgument @('diff', '--cached', '-U0', '--no-color', '--src-prefix=a/', '--dst-prefix=b/', '--diff-filter=ACMR')
    $currentPath = $null
    $inHunk = $false
    $lineNumber = 0

    foreach ($row in $diff) {
        if ($row.StartsWith('diff --git ')) {
            $currentPath = $null
            $inHunk = $false
            continue
        }

        if (-not $inHunk) {
            if ($row.StartsWith('+++ ')) {
                $target = $row.Substring(4)
                if ($target -eq '/dev/null') {
                    $currentPath = $null
                }
                elseif ($target.StartsWith('b/')) {
                    # 路徑含空白時 git 會在行尾附加 Tab。
                    $currentPath = $target.Substring(2).TrimEnd("`t")
                }
                else {
                    throw "無法解析 git diff 的目標路徑，不略過檔案：$row`n路徑含雙引號、反斜線或控制字元時，git 會以引號包住路徑輸出。請將該檔改名為不含這些字元的名稱後再 commit。"
                }
                continue
            }
            if ($row.StartsWith('@@ ')) {
                if ($row -notmatch '^@@ -\d+(?:,\d+)? \+(?<start>\d+)(?:,\d+)? @@') {
                    throw "無法解析 git diff 的 hunk 標頭：$row"
                }
                $lineNumber = [int]$Matches['start']
                $inHunk = $true
            }
            # 標頭區其餘行（--- 、index、mode 等）不含內容。
            continue
        }

        if ($row.StartsWith('@@ ')) {
            if ($row -notmatch '^@@ -\d+(?:,\d+)? \+(?<start>\d+)(?:,\d+)? @@') {
                throw "無法解析 git diff 的 hunk 標頭：$row"
            }
            $lineNumber = [int]$Matches['start']
            continue
        }

        if ($row.StartsWith('+')) {
            if ($null -ne $currentPath) {
                [pscustomobject]@{ Path = $currentPath; LineNumber = $lineNumber; Text = $row.Substring(1) }
            }
            $lineNumber++
        }
    }
}

function Get-TrackedFileLine {
    param(
        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    $files = Invoke-GitCommand -WorkingDirectory $WorkingDirectory -GitArgument @('ls-files')
    foreach ($relative in $files) {
        $full = Join-Path $WorkingDirectory $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            continue
        }
        if (-not (Test-TargetExtension -Path $relative -Allowed $Extension)) {
            continue
        }
        if (Test-LocalPathExcludedFile -Path $relative) {
            continue
        }

        $lines = [System.IO.File]::ReadAllLines($full, [System.Text.UTF8Encoding]::new($false))
        for ($index = 0; $index -lt $lines.Count; $index++) {
            [pscustomobject]@{ Path = $relative; LineNumber = $index + 1; Text = $lines[$index] }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Invoke-GitCommand -WorkingDirectory (Get-Location).Path -GitArgument @('rev-parse', '--show-toplevel') | Select-Object -First 1)
}

$candidates = if ($All) {
    Get-TrackedFileLine -WorkingDirectory $RepoRoot
}
else {
    Get-StagedAddedLine -WorkingDirectory $RepoRoot | Where-Object {
        (Test-TargetExtension -Path $_.Path -Allowed $Extension) -and -not (Test-LocalPathExcludedFile -Path $_.Path)
    }
}

$violationCount = 0
foreach ($candidate in $candidates) {
    foreach ($token in @(Find-LocalPathViolation -Text $candidate.Text)) {
        Write-Output ('{0}:{1}: {2}' -f $candidate.Path, $candidate.LineNumber, $token)
        $violationCount++
    }
}

if ($violationCount -gt 0) {
    Write-Host ''
    Write-Host "共 $violationCount 處本機磁碟機絕對路徑，無法進版控。依 doc-placement skill 改寫："
    Write-Host '  - 路徑用佔位符，例如 C:\<使用者>\...、<sourceRoot>\.local\...，或改為相對路徑。'
    Write-Host '  - 必須記錄實際路徑時，寫入 AGENTS.local.md、CONTEXT.local.md 或 .local 目錄。'
    exit 1
}

exit 0
