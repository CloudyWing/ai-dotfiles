#Requires -Version 7.0
# 被審內容雜湊。依賴 00-common.ps1。
# Git 來源記 HEAD 與目標路徑的差異雜湊，非 Git 來源（或目標在 repo 外）記目標路徑的內容雜湊。範圍僅限派遣檔 targets。

function Invoke-RunGitBytes {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$Argument
    )

    # 執行 git 並以位元組取回 stdout。回傳 ExitCode、Bytes 與 Stderr（UTF-8 解碼的文字）。GIT_OPTIONAL_LOCKS=0 避免唯讀查詢改動 index。
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'git'
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $true
    foreach ($item in @('-c', 'core.quotepath=off') + $Argument) { [void]$startInfo.ArgumentList.Add($item) }
    $startInfo.EnvironmentVariables['GIT_OPTIONAL_LOCKS'] = '0'
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        $stdout = New-Object System.IO.MemoryStream
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $stderr = New-Object System.IO.MemoryStream
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        $process.StandardInput.Close()
        $process.WaitForExit()
        $null = [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Bytes = $stdout.ToArray(); Stderr = (New-Object System.Text.UTF8Encoding -ArgumentList @($false)).GetString($stderr.ToArray()) }
    }
    finally {
        $process.Dispose()
    }
}

function Get-RunRelativeLabel {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $separators = [char[]]@('\', '/')
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd($separators)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd($separators)
    if ($fullPath.StartsWith($fullRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { return $fullPath.Substring($fullRoot.Length + 1).Replace('\', '/') }
    return $fullPath.Replace('\', '/')
}

function Test-RunPathExcluded {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][string[]]$ExcludeRoot = @()
    )

    foreach ($excluded in $ExcludeRoot) {
        if (Test-RunPathUnder -Path $Path -Root $excluded) { return $true }
    }
    return $false
}

function Get-RunTargetFileLine {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$LabelRoot,
        [AllowEmptyCollection()][string[]]$ExcludeRoot = @()
    )

    # 目標為檔案時回傳一行，為目錄時遞迴列舉。檔名符合機密樣式者略過，.git 目錄略過。
    # junction 與符號連結（reparse point）不跟隨，只記一行 reparse-point 標記，避免指向祖先的連結造成無限遞迴或雜湊範圍外的內容。
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $reparseEntries = New-Object 'System.Collections.Generic.List[string]'
    $trimmed = $Target.TrimEnd('\', '/')
    if ([IO.File]::Exists($trimmed)) {
        $files = @($trimmed)
    }
    elseif ([IO.Directory]::Exists($trimmed)) {
        $files = New-Object 'System.Collections.Generic.List[string]'
        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($trimmed)
        while ($pending.Count -gt 0) {
            $directory = $pending.Pop()
            foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
                $name = [IO.Path]::GetFileName($child)
                if (([IO.File]::GetAttributes($child) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $reparseEntries.Add($child)
                }
                elseif ([IO.Directory]::Exists($child)) {
                    if ($name -cne '.git') { $pending.Push($child) }
                }
                else { $files.Add($child) }
            }
        }
    }
    else {
        $files = @()
    }
    foreach ($file in $files) {
        if (Test-RunDenyPatternName -Name ([IO.Path]::GetFileName($file))) { continue }
        if (Test-RunPathExcluded -Path $file -ExcludeRoot $ExcludeRoot) { continue }
        $hash = try { Get-RunSha256File -Path $file } catch { 'unreadable' }
        $lines.Add((Get-RunRelativeLabel -Path $file -Root $LabelRoot) + ' ' + $hash)
    }
    foreach ($entry in $reparseEntries) {
        if (Test-RunDenyPatternName -Name ([IO.Path]::GetFileName($entry))) { continue }
        if (Test-RunPathExcluded -Path $entry -ExcludeRoot $ExcludeRoot) { continue }
        $lines.Add((Get-RunRelativeLabel -Path $entry -Root $LabelRoot) + ' reparse-point')
    }
    return @($lines.ToArray())
}

function Get-RunSourceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string[]]$Target,

        # 不納入雜湊的目錄（例如該次派遣自己的報告目錄，其中的紀錄與輸出在執行期間必然變動）。
        [string[]]$ExcludeRoot = @()
    )

    # 回傳 mode、head、diff_sha256、content_sha256。不適用的欄位為 $null。
    $repoRoot = $null
    try {
        $probe = Invoke-RunGitBytes -WorkingDirectory $ExecutionRoot -Argument @('rev-parse', '--show-toplevel')
        if ($probe.ExitCode -eq 0) { $repoRoot = [IO.Path]::GetFullPath(([Text.Encoding]::UTF8.GetString($probe.Bytes)).Trim()) }
    }
    catch { $repoRoot = $null }

    $repoTargets = New-Object 'System.Collections.Generic.List[string]'
    $otherTargets = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in $Target) {
        if ($null -ne $repoRoot -and (Test-RunPathUnder -Path $item -Root $repoRoot)) { $repoTargets.Add($item) } else { $otherTargets.Add($item) }
    }

    $head = $null
    $diffHash = $null
    $contentHash = $null
    if ($repoTargets.Count -gt 0) {
        $headResult = Invoke-RunGitBytes -WorkingDirectory $repoRoot -Argument @('rev-parse', 'HEAD')
        $head = if ($headResult.ExitCode -eq 0) { ([Text.Encoding]::UTF8.GetString($headResult.Bytes)).Trim() } else { 'no-commit' }
        $pathspec = @('--') + @($repoTargets.ToArray())
        $diff = Invoke-RunGitBytes -WorkingDirectory $repoRoot -Argument (@('diff', 'HEAD', '--binary', '--no-ext-diff') + $pathspec)
        $untracked = Invoke-RunGitBytes -WorkingDirectory $repoRoot -Argument (@('ls-files', '--others', '--exclude-standard', '-z') + $pathspec)
        $untrackedLines = New-Object 'System.Collections.Generic.List[string]'
        foreach ($relative in ([Text.Encoding]::UTF8.GetString($untracked.Bytes) -split "`0")) {
            if ([string]::IsNullOrEmpty($relative)) { continue }
            if (Test-RunDenyPatternName -Name ([IO.Path]::GetFileName($relative))) { continue }
            $full = Join-Path $repoRoot $relative
            if (Test-RunPathExcluded -Path $full -ExcludeRoot $ExcludeRoot) { continue }
            $hash = try { Get-RunSha256File -Path $full } catch { 'unreadable' }
            $untrackedLines.Add($relative + ' ' + $hash)
        }
        $untrackedLines.Sort([StringComparer]::Ordinal)
        $untrackedBytes = (New-Object System.Text.UTF8Encoding -ArgumentList @($false)).GetBytes(($untrackedLines -join "`n"))
        $combined = New-Object System.IO.MemoryStream
        $combined.Write($diff.Bytes, 0, $diff.Bytes.Length)
        $combined.Write($untrackedBytes, 0, $untrackedBytes.Length)
        $diffHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($combined.ToArray())).ToLowerInvariant()
    }
    if ($otherTargets.Count -gt 0) {
        $lines = New-Object 'System.Collections.Generic.List[string]'
        foreach ($item in $otherTargets) {
            foreach ($line in (Get-RunTargetFileLine -Target $item -LabelRoot $ExecutionRoot -ExcludeRoot $ExcludeRoot)) { $lines.Add($line) }
        }
        $lines.Sort([StringComparer]::Ordinal)
        $contentHash = Get-RunSha256Text -Text ($lines -join "`n")
    }
    $mode = if ($repoTargets.Count -gt 0 -and $otherTargets.Count -gt 0) { 'git+content' } elseif ($repoTargets.Count -gt 0) { 'git' } else { 'content' }
    return [pscustomobject]@{ mode = $mode; head = $head; diff_sha256 = $diffHash; content_sha256 = $contentHash }
}

function Get-RunInventorySecretPattern {
    # 盤點檔不提供內容的檔名樣式：派工共用的機密樣式再加 *.pfx，去重。
    return [string[]]@(@(Get-RunDenyPattern) + @('*.pfx') | Select-Object -Unique)
}

function Invoke-RunInventoryGit {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$Argument
    )

    # 盤點用的 git 命令：結束碼非 0 時以 RunWorktreeInventoryFailed 拋出，訊息含命令參數與 stderr。回傳 stdout 文字。
    $result = Invoke-RunGitBytes -WorkingDirectory $WorkingDirectory -Argument $Argument
    if ($result.ExitCode -ne 0) {
        throw (New-RunError -Code 'RunWorktreeInventoryFailed' -Message ('git ' + ($Argument -join ' ') + ' 結束碼 ' + $result.ExitCode + '：' + ([string]$result.Stderr).Trim()) -ExitCode 1)
    }
    return (New-Object System.Text.UTF8Encoding -ArgumentList @($false)).GetString($result.Bytes)
}

function Write-RunWorktreeInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string[]]$Target,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        # 不列入未追蹤清單的目錄（例如該次派遣自己的報告目錄）。
        [string[]]$ExcludeRoot = @()
    )

    # 在沙盒外執行審查需要工作樹或索引的 git 命令，結果寫成檔案供審查者直接讀取。
    # 回傳 path、sha256、bytes、head。任一 git 命令失敗時拋出 RunWorktreeInventoryFailed，且不寫出檔案。
    $emptyText = '（無）'
    $repoRoot = $null
    try {
        $probe = Invoke-RunGitBytes -WorkingDirectory $ExecutionRoot -Argument @('rev-parse', '--show-toplevel')
        if ($probe.ExitCode -eq 0) { $repoRoot = [IO.Path]::GetFullPath(([Text.Encoding]::UTF8.GetString($probe.Bytes)).Trim()) }
    }
    catch { $repoRoot = $null }

    $repoTargets = New-Object 'System.Collections.Generic.List[string]'
    $otherTargets = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in $Target) {
        if ($null -ne $repoRoot -and (Test-RunPathUnder -Path $item -Root $repoRoot)) { $repoTargets.Add($item) } else { $otherTargets.Add($item) }
    }

    $repositoryText = '無'
    $headText = '無'
    $changes = $emptyText
    $staged = $emptyText
    $untracked = $emptyText
    $diffContent = $emptyText
    if ($repoTargets.Count -gt 0) {
        $repositoryText = $repoRoot
        $pathspec = @('--') + @($repoTargets.ToArray())
        $secretPatterns = @(Get-RunInventorySecretPattern)
        $headResult = Invoke-RunGitBytes -WorkingDirectory $repoRoot -Argument @('rev-parse', '--verify', '-q', 'HEAD')
        if ($headResult.ExitCode -eq 0) { $headText = ([Text.Encoding]::UTF8.GetString($headResult.Bytes)).Trim() }
        elseif ($headResult.ExitCode -eq 1) { $headText = 'no-commit' }
        else { throw (New-RunError -Code 'RunWorktreeInventoryFailed' -Message ('git rev-parse --verify -q HEAD 結束碼 ' + $headResult.ExitCode + '：' + ([string]$headResult.Stderr).Trim()) -ExitCode 1) }

        if ($headText -cne 'no-commit') {
            $changes = Invoke-RunInventoryGit -WorkingDirectory $repoRoot -Argument (@('diff', 'HEAD', '--name-status', '-M', '--no-ext-diff') + $pathspec)
            $staged = Invoke-RunInventoryGit -WorkingDirectory $repoRoot -Argument (@('diff', '--cached', '--name-status', '-M', 'HEAD', '--no-ext-diff') + $pathspec)
            $excludeSpec = @($secretPatterns | ForEach-Object { ':(exclude,glob,icase)**/' + $_ })
            $diffContent = Invoke-RunInventoryGit -WorkingDirectory $repoRoot -Argument (@('diff', 'HEAD', '-M', '--no-ext-diff', '--no-color') + $pathspec + $excludeSpec)
        }
        else {
            $cached = Invoke-RunInventoryGit -WorkingDirectory $repoRoot -Argument (@('ls-files', '--cached', '-z') + $pathspec)
            $cachedLines = @($cached -split "`0" | Where-Object { -not [string]::IsNullOrEmpty($_) } | ForEach-Object { 'A' + "`t" + $_ })
            $changes = $cachedLines -join "`n"
            $staged = $changes
            $diffContent = 'HEAD 不存在，已暫存與未追蹤的目標整份視為新增，直接讀取檔案。'
        }

        $others = Invoke-RunInventoryGit -WorkingDirectory $repoRoot -Argument (@('ls-files', '--others', '--exclude-standard', '-z') + $pathspec)
        $untrackedLines = New-Object 'System.Collections.Generic.List[string]'
        foreach ($relative in ($others -split "`0")) {
            if ([string]::IsNullOrEmpty($relative)) { continue }
            if (Test-RunPathExcluded -Path (Join-Path $repoRoot $relative) -ExcludeRoot $ExcludeRoot) { continue }
            $name = [IO.Path]::GetFileName($relative)
            $isSecret = $false
            foreach ($pattern in $secretPatterns) { if ($name -like $pattern) { $isSecret = $true; break } }
            $untrackedLines.Add($(if ($isSecret) { $relative + '（機密樣式，不提供內容）' } else { $relative }))
        }
        $untrackedLines.Sort([StringComparer]::Ordinal)
        $untracked = $untrackedLines -join "`n"
    }

    $normalize = {
        param([string]$Text)
        $trimmed = $Text.TrimEnd([char[]]@("`r", "`n"))
        if ([string]::IsNullOrWhiteSpace($trimmed)) { return $emptyText }
        return $trimmed
    }
    $outside = $otherTargets -join "`n"
    $lines = @(
        '# 工作樹盤點'
        ''
        '- schema: ai-agents.worktree-inventory.v1'
        ('- repository: ' + $repositoryText)
        ('- head: ' + $headText)
        ('- generated_utc: ' + [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture))
        ''
        '## 相對 HEAD 的變更'
        ''
        (& $normalize $changes)
        ''
        '## 已暫存'
        ''
        (& $normalize $staged)
        ''
        '## 未追蹤'
        ''
        (& $normalize $untracked)
        ''
        '## repository 外的目標'
        ''
        (& $normalize $outside)
        ''
        '## 差異內容'
        ''
        (& $normalize $diffContent)
    )
    $bytes = (New-Object System.Text.UTF8Encoding -ArgumentList @($false)).GetBytes((($lines -join "`n") + "`n"))
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath))
    if (-not [IO.Directory]::Exists($directory)) { $null = [IO.Directory]::CreateDirectory($directory) }
    [IO.File]::WriteAllBytes($OutputPath, $bytes)
    return [pscustomobject]@{
        path = $OutputPath
        sha256 = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        bytes = [long]$bytes.Length
        head = $headText
    }
}
