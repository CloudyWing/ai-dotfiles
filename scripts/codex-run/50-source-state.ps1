#Requires -Version 7.0
# 被審內容雜湊。依賴 00-common.ps1。
# Git 來源記 HEAD 與目標路徑的差異雜湊，非 Git 來源（或目標在 repo 外）記目標路徑的內容雜湊。範圍僅限派遣檔 targets。

function Invoke-RunGitBytes {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$Argument
    )

    # 執行 git 並以位元組取回 stdout。回傳 ExitCode 與 Bytes。GIT_OPTIONAL_LOCKS=0 避免唯讀查詢改動 index。
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
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
        $process.StandardInput.Close()
        $process.WaitForExit()
        $null = [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Bytes = $stdout.ToArray() }
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
