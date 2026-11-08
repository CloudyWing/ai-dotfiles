#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$Root,

    [ValidateSet('all', 'worktrees', 'lines')]
    [string]$Target = 'all',

    [switch]$SessionsFromStdin,
    [string]$ConfirmPlan,
    [string[]]$ClosedLine = @(),
    [ValidateRange(0, 365000)]
    [int]$ClosedAfterDays = 14,
    [ValidateRange(0, 365000)]
    [int]$BackupMinAgeDays = 14,
    [ValidateRange(0, [long]::MaxValue)]
    [long]$LargeFileBytes = 1048576,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$script:SessionRoot = '.local\ai-sessions'
$script:LogExtensions = @('.txt', '.log', '.bin', '.out', '.err', '.jsonl')
$script:ReservedNames = @('line.json', 'requirement-summary.md', 'design.md')
$script:ClosedLines = @($ClosedLine | ForEach-Object { $_ -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$script:ReferenceGaps = [Collections.Generic.List[string]]::new()
$script:ReparseCache = [Collections.Generic.Dictionary[string, bool]]::new([StringComparer]::OrdinalIgnoreCase)
$script:PidRecordCache = @{}
$script:RunRecordCache = @{}

function Get-FullPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::Equals($full, $root, [StringComparison]::OrdinalIgnoreCase)) { return $root }
    return $full.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Test-PathWithin {
    [CmdletBinding()]
    param([string]$Path, [string]$Parent, [switch]$OrEqual)

    $childPath = Get-FullPath $Path
    $parentPath = Get-FullPath $Parent
    if ($OrEqual -and [string]::Equals($childPath, $parentPath, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = if ($parentPath.EndsWith([IO.Path]::DirectorySeparatorChar)) { $parentPath } else { $parentPath + [IO.Path]::DirectorySeparatorChar }
    return $childPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-ReparsePath {
    [CmdletBinding()]
    param([string]$Path, [string]$Boundary)

    $current = Get-FullPath $Path
    $boundaryPath = Get-FullPath $Boundary
    if (-not (Test-PathWithin $current $boundaryPath -OrEqual)) { return $true }
    $visited = [Collections.Generic.List[string]]::new()
    $isLeaf = $true
    $result = $null
    while ($null -eq $result) {
        $key = $boundaryPath + '|' + $current
        $cached = $false
        if (-not $isLeaf -and $script:ReparseCache.TryGetValue($key, [ref]$cached)) { $result = $cached; break }
        try {
            $attributes = [IO.File]::GetAttributes($current)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $result = $true; break }
        }
        catch [IO.FileNotFoundException] { }
        catch [IO.DirectoryNotFoundException] { }
        catch { $result = $true; break }
        if (-not $isLeaf) { $visited.Add($key) }
        if ([string]::Equals($current, $boundaryPath, [StringComparison]::OrdinalIgnoreCase)) { $result = $false; break }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { $result = $true; break }
        $current = $parent.FullName
        $isLeaf = $false
    }
    foreach ($key in $visited) { $script:ReparseCache[$key] = $result }
    return $result
}

function Clear-PlanCaches {
    [CmdletBinding()]
    param()

    $script:ReparseCache.Clear()
    $script:PidRecordCache.Clear()
    $script:RunRecordCache.Clear()
}

function Clear-ItemCaches {
    [CmdletBinding()]
    param()

    # 確認流程逐項重新驗證時，只清連結點與 PID 紀錄快取（PID 存活狀態由 Get-PidState 每次現查）。
    # RunRecord 紀錄不屬於被刪除的對象，整次確認只讀一次。
    $script:ReparseCache.Clear()
    $script:PidRecordCache.Clear()
}

function Get-SafeEntries {
    [CmdletBinding()]
    param([string]$Path, [string]$Boundary, [string[]]$Exclude = @(), [Collections.Generic.List[string]]$Inaccessible = $null)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $start = Get-FullPath $Path
    $pending = [Collections.Generic.Stack[object]]::new()
    try {
        if (Test-ReparsePath $start $Boundary) {
            [pscustomobject]@{ Path = $start; IsLink = $true; IsDirectory = $false; Length = 0 }
            return
        }
        $pending.Push((Get-Item -LiteralPath $start -Force))
    }
    catch {
        if ($null -ne $Inaccessible) { $Inaccessible.Add($start) }
        return
    }
    while ($pending.Count -gt 0) {
        $entry = $pending.Pop()
        $current = $entry.FullName
        if (@($Exclude | Where-Object { [string]::Equals($_, $current, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }
        $children = @()
        try {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                [pscustomobject]@{ Path = $current; IsLink = $true; IsDirectory = $false; Length = 0 }
                continue
            }
            if (-not $entry.PSIsContainer) {
                [pscustomobject]@{ Path = $current; IsLink = $false; IsDirectory = $false; Length = [long]$entry.Length }
                continue
            }
            $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)
        }
        catch {
            if ($null -ne $Inaccessible) { $Inaccessible.Add($current) }
            continue
        }
        foreach ($child in $children) { $pending.Push($child) }
    }
}

function Format-InaccessibleReason {
    [CmdletBinding()]
    param([string[]]$Paths, [string]$Base)

    $first = [IO.Path]::GetRelativePath($Base, $Paths[0])
    return "含 $($Paths.Count) 個無法讀取的項目（例：$first）"
}

function Test-PreservedFile {
    [CmdletBinding()]
    param([string]$Path, [string]$SessionBase)

    $relative = [IO.Path]::GetRelativePath($SessionBase, $Path).Replace('/', '\')
    if ($relative -match '(?i)^handoff\\[^\\]+\\(?:line\.json|requirement-summary\.md|design\.md)$') { return $true }
    return [IO.Path]::GetFileName($Path) -match '(?i)^(?:dispatch-order-.*\.md|dispatch-report-.*\.md|cost-ledger\.md)$'
}

function Invoke-Git {
    [CmdletBinding()]
    param([string]$WorkRoot, [string[]]$Arguments)

    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = 'git'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in @('--no-optional-locks', '-C', $WorkRoot) + $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw '無法啟動 git' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout.GetAwaiter().GetResult(); StdErr = $stderr.GetAwaiter().GetResult() }
    }
    finally { $process.Dispose() }
}

function Get-MainBranchName {
    [CmdletBinding()]
    param([string]$WorkRoot)

    $remote = Invoke-Git $WorkRoot @('symbolic-ref', '--short', 'refs/remotes/origin/HEAD')
    if ($remote.ExitCode -eq 0) {
        $name = $remote.StdOut.Trim() -replace '^origin/', ''
        if ((Invoke-Git $WorkRoot @('rev-parse', '--verify', '-q', ('refs/heads/' + $name))).ExitCode -eq 0) { return $name }
        return $null
    }
    foreach ($name in @('main', 'master')) {
        if ((Invoke-Git $WorkRoot @('rev-parse', '--verify', '-q', ('refs/heads/' + $name))).ExitCode -eq 0) { return $name }
    }
    return $null
}

function Get-Repository {
    [CmdletBinding()]
    param([string]$WorkRoot)

    $list = Invoke-Git $WorkRoot @('worktree', 'list', '--porcelain')
    if ($list.ExitCode -ne 0) { return $null }
    $entries = [Collections.Generic.List[object]]::new()
    $entry = $null
    foreach ($line in ($list.StdOut -split "`r?`n")) {
        if ($line -match '^worktree (.+)$') {
            if ($null -ne $entry) { $entries.Add([pscustomobject]$entry) }
            $entry = @{ Path = Get-FullPath $Matches[1]; Branch = $null; Locked = $false; Prunable = $false }
        }
        elseif ($null -ne $entry -and $line -match '^branch refs/heads/(.+)$') { $entry.Branch = $Matches[1] }
        elseif ($null -ne $entry -and $line -match '^locked(?: |$)') { $entry.Locked = $true }
        elseif ($null -ne $entry -and $line -match '^prunable(?: |$)') { $entry.Prunable = $true }
    }
    if ($null -ne $entry) { $entries.Add([pscustomobject]$entry) }
    if ($entries.Count -eq 0) { return $null }
    $mainRoot = $entries[0].Path
    $mainBranch = Get-MainBranchName $mainRoot
    $merged = @()
    $mergedKnown = $false
    if ($null -ne $mainBranch) {
        $result = Invoke-Git $mainRoot @('branch', '--merged', $mainBranch, '--format=%(refname:short)')
        if ($result.ExitCode -eq 0) { $merged = @($result.StdOut -split "`r?`n" | Where-Object { $_ }); $mergedKnown = $true }
    }
    $features = $null
    $featureResult = Invoke-Git $mainRoot @('for-each-ref', '--format=%(refname:short)', 'refs/heads/feature/')
    if ($featureResult.ExitCode -eq 0) { $features = [Collections.Generic.HashSet[string]]::new([string[]]@($featureResult.StdOut -split "`r?`n" | Where-Object { $_ }), [StringComparer]::Ordinal) }
    return [pscustomobject]@{ Main = $mainRoot; MainBranch = $mainBranch; Merged = $merged; MergedKnown = $mergedKnown; Features = $features; Entries = $entries.ToArray() }
}

function Get-PropertyValue {
    [CmdletBinding()]
    param([object]$Value, [string]$Name)

    if ($null -eq $Value) { return $null }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return ,$property.Value
}

function Get-SessionState {
    [CmdletBinding()]
    param([switch]$FromStdin)

    if (-not $FromStdin) { return [pscustomobject]@{ Known = $false; Sessions = @() } }
    $reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.UTF8Encoding]::new($false, $true))
    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{ Known = $false; Sessions = @() } }
    $data = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    $sessions = Get-PropertyValue $data 'sessions'
    if ($null -eq $sessions) { return [pscustomobject]@{ Known = $false; Sessions = @() } }
    if ($sessions -isnot [array]) { throw 'Session 清單格式錯誤' }
    return [pscustomobject]@{ Known = $true; Sessions = @($sessions) }
}

function Test-ActiveSession {
    [CmdletBinding()]
    param([object]$Session)

    return (Get-PropertyValue $Session 'isArchived') -ne $true
}

function Test-SameFile {
    [CmdletBinding()]
    param([string]$Left, [string]$Right, [string]$LeftBoundary, [string]$RightBoundary)

    if (-not (Test-Path -LiteralPath $Left -PathType Leaf) -or -not (Test-Path -LiteralPath $Right -PathType Leaf)) { return $false }
    if ((Test-ReparsePath $Left $LeftBoundary) -or (Test-ReparsePath $Right $RightBoundary)) { return $false }
    return (Get-FileHash -LiteralPath $Left -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $Right -Algorithm SHA256).Hash
}

function Get-LineClosure {
    [CmdletBinding()]
    param([string]$WorkRoot, [string]$Slug, [object]$Repository, [object]$SessionState)

    $reasons = [Collections.Generic.List[string]]::new()
    $linePath = Join-Path $WorkRoot "$script:SessionRoot\handoff\$Slug\line.json"
    try {
        if (Test-ReparsePath $linePath $WorkRoot) { throw '連結點' }
        $manifest = Get-Content -LiteralPath $linePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ((Get-PropertyValue $manifest 'line-slug') -ne $Slug) { throw '線識別不符' }
    }
    catch { $reasons.Add('線登記資料無法判定') }
    $explicit = $script:ClosedLines -contains $Slug
    if (-not $explicit) {
        $checkpoint = Join-Path $WorkRoot "$script:SessionRoot\report\$Slug\handoff-checkpoint.md"
        if (-not (Test-Path -LiteralPath $checkpoint -PathType Leaf) -or (Test-ReparsePath $checkpoint $WorkRoot)) { $reasons.Add('缺少結案檢查點') }
        else {
            try {
                $type = $null
                foreach ($line in @(Get-Content -LiteralPath $checkpoint -Encoding UTF8)) {
                    if ($line -match '^\s*-\s*檢查點類型[：:]\s*(.+)$' -or $line -match '^\s*\|\s*檢查點類型\s*\|\s*(.+?)\s*\|\s*$') { $type = $Matches[1] -replace '`', '' -replace '[（(].*$', ''; $type = $type.Trim(); break }
                }
                if ($null -eq $type -or ($type -notmatch '^developer-collected' -and $type -ne '結案')) { $reasons.Add('檢查點尚未結案') }
                if (([DateTime]::UtcNow - (Get-Item -LiteralPath $checkpoint).LastWriteTimeUtc).TotalDays -lt $ClosedAfterDays) { $reasons.Add("檢查點未滿 $ClosedAfterDays 天") }
            }
            catch { $reasons.Add('檢查點無法讀取') }
        }
    }
    if (-not $SessionState.Known) { $reasons.Add('未取得 Session 清單') }
    elseif (@($SessionState.Sessions | Where-Object { (Test-ActiveSession $_) -and (Get-PropertyValue $_ 'name') -eq $Slug }).Count -gt 0) { $reasons.Add('同名 Session 使用中') }
    if (-not $explicit) {
        if ($null -eq $Repository -or -not $Repository.MergedKnown -or $null -eq $Repository.Features) { $reasons.Add('分支狀態無法判定') }
        elseif ($Repository.Features.Contains('feature/' + $Slug) -and $Repository.Merged -notcontains ('feature/' + $Slug)) { $reasons.Add('工作線分支尚未合入主分支') }
        if ($null -ne $Repository -and -not [string]::Equals($WorkRoot, $Repository.Main, [StringComparison]::OrdinalIgnoreCase)) {
            foreach ($name in $script:ReservedNames) {
                $local = Join-Path $WorkRoot "$script:SessionRoot\handoff\$Slug\$name"
                if ((Test-Path -LiteralPath $local -PathType Leaf) -and -not (Test-SameFile $local (Join-Path $Repository.Main "$script:SessionRoot\handoff\$Slug\$name") $WorkRoot $Repository.Main)) { $reasons.Add("主工作樹缺少相同的 $name") }
            }
        }
    }
    return [pscustomobject]@{ Closed = ($reasons.Count -eq 0); Reasons = $reasons.ToArray() }
}

function Get-PidRecords {
    [CmdletBinding()]
    param([string[]]$Roots)

    $cacheKey = (@($Roots | Select-Object -Unique) | ForEach-Object { $_.ToLowerInvariant() }) -join '|'
    if ($script:PidRecordCache.ContainsKey($cacheKey)) { return $script:PidRecordCache[$cacheKey] }
    $records = [Collections.Generic.List[object]]::new()
    foreach ($workRoot in @($Roots | Select-Object -Unique)) {
        $history = Join-Path $workRoot "$script:SessionRoot\history"
        if (-not (Test-Path -LiteralPath $history -PathType Container)) { continue }
        if (Test-ReparsePath $history $workRoot) { $records.Add([pscustomobject]@{ Invalid = $true; Data = @{}; Path = $history }); continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $history -Filter 'codex-pid-*.txt' -File -Force)) {
            $data = @{}
            try {
                if (Test-ReparsePath $file.FullName $workRoot) { throw '連結點' }
                $stream = [IO.FileStream]::new($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                try {
                    $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true))
                    try { $content = $reader.ReadToEnd() } finally { $reader.Dispose() }
                }
                finally { $stream.Dispose() }
                foreach ($line in ($content -split "`r?`n")) { if ($line -match '^([^=]+)=(.*)$') { $data[$Matches[1].Trim()] = $Matches[2].Trim() } }
                $records.Add([pscustomobject]@{ Invalid = $false; Data = $data; Path = $file.FullName })
            }
            catch { $records.Add([pscustomobject]@{ Invalid = $true; Data = @{}; Path = $file.FullName }) }
        }
    }
    $script:PidRecordCache[$cacheKey] = $records.ToArray()
    return $script:PidRecordCache[$cacheKey]
}

function Get-PidState {
    [CmdletBinding()]
    param([hashtable]$Data)

    foreach ($key in @('root-pid', 'root-process-name', 'root-started-at-utc', 'dispatch-slug')) {
        if (-not $Data.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($Data[$key])) { return 'unknown' }
    }
    $processId = 0
    $started = [DateTimeOffset]::MinValue
    if (-not [int]::TryParse($Data['root-pid'], [ref]$processId) -or $processId -le 0 -or -not [DateTimeOffset]::TryParse($Data['root-started-at-utc'], [ref]$started)) { return 'unknown' }
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return 'ended' }
    try {
        if ([string]::Equals($process.ProcessName, $Data['root-process-name'], [StringComparison]::OrdinalIgnoreCase) -and [Math]::Abs(($process.StartTime.ToUniversalTime() - $started.UtcDateTime).TotalSeconds) -le 2) { return 'active' }
        return 'ended'
    }
    catch { return 'unknown' }
}

function Get-DispatchUseReasons {
    [CmdletBinding()]
    param([string]$Path, [string]$Name, [bool]$IsDispatch, [string[]]$Roots)

    $reasons = [Collections.Generic.List[string]]::new()
    foreach ($record in @(Get-PidRecords $Roots)) {
        if ($record.Invalid) { $reasons.Add('派工使用狀態無法判定'); continue }
        $data = $record.Data
        $matchesPath = $false
        if ($data.ContainsKey('work-root') -and -not [string]::IsNullOrWhiteSpace($data['work-root'])) {
            try { $matchesPath = [string]::Equals((Get-FullPath $data['work-root']), $Path, [StringComparison]::OrdinalIgnoreCase) } catch { $reasons.Add('派工使用狀態無法判定') }
        }
        if (-not $matchesPath -and -not ($IsDispatch -and $data.ContainsKey('dispatch-slug') -and $data['dispatch-slug'] -eq $Name)) { continue }
        switch (Get-PidState $data) {
            'active' { $reasons.Add("派工使用中（$($data['dispatch-slug'])）") }
            'unknown' { $reasons.Add('派工使用狀態無法判定') }
        }
    }
    return @($reasons | Select-Object -Unique)
}

function Get-DispatchOwner {
    [CmdletBinding()]
    param([string]$WorkRoot, [string]$Path, [string]$Name)

    $owners = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $invalid = $false
    $runKey = $WorkRoot.ToLowerInvariant()
    if (-not $script:RunRecordCache.ContainsKey($runKey)) {
        Write-Verbose "載入 RunRecord：$WorkRoot"
        $byRoot = [Collections.Generic.Dictionary[string, Collections.Generic.HashSet[string]]]::new([StringComparer]::OrdinalIgnoreCase)
        $runInvalid = $false
        $history = Join-Path $WorkRoot "$script:SessionRoot\history"
        if (Test-Path -LiteralPath $history -PathType Container) {
            foreach ($lineDir in @(Get-ChildItem -LiteralPath $history -Directory -Force)) {
                $runs = Join-Path $lineDir.FullName 'runs'
                if (-not (Test-Path -LiteralPath $runs -PathType Container)) { continue }
                if (Test-ReparsePath $runs $WorkRoot) { $runInvalid = $true; continue }
                foreach ($dispatch in @(Get-ChildItem -LiteralPath $runs -Directory -Force)) {
                    foreach ($record in @(Get-ChildItem -LiteralPath $dispatch.FullName -Filter '*.json' -File -Force)) {
                        try {
                            if (Test-ReparsePath $record.FullName $WorkRoot) { throw '連結點' }
                            $data = Get-Content -LiteralPath $record.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                            $executionRoot = Get-PropertyValue $data 'execution_root'
                            $slug = Get-PropertyValue $data 'line_slug'
                            if ([string]::IsNullOrWhiteSpace($executionRoot) -or $slug -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw '缺少欄位或線識別無效' }
                            $rootKey = Get-FullPath $executionRoot
                            if (-not $byRoot.ContainsKey($rootKey)) { $byRoot[$rootKey] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
                            $null = $byRoot[$rootKey].Add($slug)
                        }
                        catch { $runInvalid = $true }
                    }
                }
            }
        }
        $script:RunRecordCache[$runKey] = [pscustomobject]@{ Invalid = $runInvalid; Owners = $byRoot }
    }
    $runCache = $script:RunRecordCache[$runKey]
    if ($runCache.Invalid) { $invalid = $true }
    if ($runCache.Owners.ContainsKey($Path)) { foreach ($runSlug in $runCache.Owners[$Path]) { $null = $owners.Add($runSlug) } }
    foreach ($record in @(Get-PidRecords @($WorkRoot))) {
        if ($record.Invalid) { $invalid = $true; continue }
        if ($record.Data.ContainsKey('dispatch-slug') -and $record.Data['dispatch-slug'] -eq $Name) {
            if (-not $record.Data.ContainsKey('line-slug') -or $record.Data['line-slug'] -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { $invalid = $true }
            else { $null = $owners.Add($record.Data['line-slug']) }
        }
    }
    $values = @($owners | Sort-Object)
    if ($invalid) { return [pscustomobject]@{ Slug = $null; Reason = '所屬線無法判定' } }
    if ($values.Count -eq 0) { return [pscustomobject]@{ Slug = $null; Reason = '無法判定所屬線' } }
    if ($values.Count -gt 1) { return [pscustomobject]@{ Slug = $null; Reason = "所屬線不一致（$($values -join '、')）" } }
    return [pscustomobject]@{ Slug = $values[0]; Reason = $null }
}

function Test-TextLog {
    [CmdletBinding()]
    param([string]$Path)

    $file = Get-Item -LiteralPath $Path -Force
    if ($script:LogExtensions -notcontains $file.Extension.ToLowerInvariant() -or $file.Length -lt $LargeFileBytes) { return $false }
    $stream = [IO.File]::OpenRead($Path)
    try {
        $buffer = [byte[]]::new(4096)
        $count = $stream.Read($buffer, 0, $buffer.Length)
        for ($index = 0; $index -lt $count; $index++) { if ($buffer[$index] -eq 0) { return $false } }
        return $true
    }
    finally { $stream.Dispose() }
}

function Get-UnpreservedFiles {
    [CmdletBinding()]
    param([string]$Path, [string]$SourceRoot)

    $unpreserved = [Collections.Generic.List[string]]::new()
    foreach ($area in @('handoff', 'report', 'inputs', 'ui-demo', 'screenshots', 'style-baselines')) {
        $directory = Join-Path $Path "$script:SessionRoot\$area"
        $gaps = [Collections.Generic.List[string]]::new()
        foreach ($entry in @(Get-SafeEntries $directory $Path -Inaccessible $gaps)) {
            $relative = [IO.Path]::GetRelativePath($Path, $entry.Path)
            if ($entry.IsLink) { $unpreserved.Add($relative); continue }
            if ($area -eq 'report' -and (Test-TextLog $entry.Path)) { continue }
            if (-not (Test-SameFile $entry.Path (Join-Path $SourceRoot $relative) $Path $SourceRoot)) { $unpreserved.Add($relative) }
        }
        foreach ($gap in $gaps) { $unpreserved.Add([IO.Path]::GetRelativePath($Path, $gap)) }
    }
    return $unpreserved.ToArray()
}

function Get-ReferenceIndex {
    [CmdletBinding()]
    param([string[]]$Roots)

    $index = @{}
    $allowed = @('.md', '.txt', '.json', '.yml', '.yaml', '.csv', '.ps1')
    $script:ReferenceGaps.Clear()
    foreach ($workRoot in $Roots) {
        $base = Join-Path $workRoot $script:SessionRoot
        $sources = [Collections.Generic.List[object]]::new()
        $inputGaps = [Collections.Generic.List[string]]::new()
        foreach ($entry in @(Get-SafeEntries (Join-Path $base 'inputs') $workRoot -Inaccessible $inputGaps)) {
            if (-not $entry.IsLink -and $entry.Length -le 2MB -and $allowed -contains [IO.Path]::GetExtension($entry.Path).ToLowerInvariant()) { $sources.Add([pscustomobject]@{ Path = $entry.Path; Owner = 'inputs' }) }
        }
        foreach ($gap in $inputGaps) { $script:ReferenceGaps.Add($gap) }
        foreach ($area in @('handoff', 'report')) {
            $areaPath = Join-Path $base $area
            if (-not (Test-Path -LiteralPath $areaPath -PathType Container) -or (Test-ReparsePath $areaPath $workRoot)) { continue }
            try { $lineDirectories = @(Get-ChildItem -LiteralPath $areaPath -Directory -Force) }
            catch { $script:ReferenceGaps.Add($areaPath); continue }
            foreach ($line in $lineDirectories) {
                if (Test-ReparsePath $line.FullName $workRoot) { continue }
                try { $lineFiles = @(Get-ChildItem -LiteralPath $line.FullName -File -Force) }
                catch { $script:ReferenceGaps.Add($line.FullName); continue }
                foreach ($file in $lineFiles) {
                    if (Test-ReparsePath $file.FullName $workRoot) { continue }
                    if ($file.Extension -eq '.md' -or ($area -eq 'handoff' -and $file.Extension -eq '.json')) { $sources.Add([pscustomobject]@{ Path = $file.FullName; Owner = $line.Name }) }
                }
            }
        }
        foreach ($source in $sources) {
            try { $text = [IO.File]::ReadAllText($source.Path).Replace('\\', '\').Replace('/', '\') }
            catch { $script:ReferenceGaps.Add($source.Path); continue }
            $pattern = '(?i)(?:[a-z]:\\|\.local\\ai-sessions\\)[^\s"''`<>|*?()（）]+'
            foreach ($match in [regex]::Matches($text, $pattern)) {
                if (Test-TemplateMatch $text $match) { continue }
                $value = $match.Value.TrimEnd([char[]]@('\', '.', ',', ';', ':', '，', '。', '、')).ToLowerInvariant()
                if (-not $index.ContainsKey($value)) { $index[$value] = [Collections.Generic.List[object]]::new() }
                $index[$value].Add([pscustomobject]@{ Source = $source.Path; Owner = $source.Owner })
            }
        }
    }
    return $index
}

function Test-TemplateMatch {
    [CmdletBinding()]
    param([string]$Text, [Text.RegularExpressions.Match]$Match)

    $before = $Match.Index
    if ($before -ge 2 -and $Text[$before - 1] -eq '\' -and $Text[$before - 2] -eq '>') { return $true }
    $end = $Match.Index + $Match.Length
    if ($end -ge $Text.Length) { return $false }
    $last = [string]$Match.Value[$Match.Length - 1]
    $next = [string]$Text[$end]
    if ($next -in @('<', '>')) { return $last -in @('\', '-', '_') }
    if ($next -in @('*', '?')) {
        if ($last -eq '\') { return $true }
        $following = if ($end + 1 -lt $Text.Length) { [string]$Text[$end + 1] } else { '' }
        return $following -match '^[\w.\\-]$'
    }
    return $false
}

function Get-ReferenceSource {
    [CmdletBinding()]
    param([string]$Path, [string]$WorkRoot, [string]$Owner, [hashtable]$Index)

    $base = Get-FullPath (Join-Path $WorkRoot $script:SessionRoot)
    $current = Get-FullPath $Path
    while (Test-PathWithin $current $base) {
        if ([IO.Path]::GetRelativePath($base, $current).Split([char[]]@('\', '/')).Count -lt 2) { break }
        $absolute = $current.Replace('/', '\').ToLowerInvariant()
        $relative = [IO.Path]::GetRelativePath($WorkRoot, $current).Replace('/', '\').ToLowerInvariant()
        foreach ($key in @($absolute, $relative)) {
            if (-not $Index.ContainsKey($key)) { continue }
            foreach ($reference in $Index[$key]) {
                if ($reference.Owner -eq $Owner -and $Owner -ne 'inputs') { continue }
                return $reference.Source
            }
        }
        $current = [IO.Directory]::GetParent($current).FullName
    }
    return $null
}

function New-CleanupItem {
    [CmdletBinding()]
    param([string]$Id, [string]$Kind, [string]$WorkRoot, [string]$Path, [string]$Name, [AllowNull()][object]$Slug, [AllowNull()][object]$Category, [string]$Status, [string[]]$Reasons, [object[]]$Files, [int]$ProtectedCount = 0, [object]$Tracked = $null, [object]$Untracked = $null, [object]$Entry = $null, [object]$Repository = $null)

    $size = [long]0
    foreach ($file in $Files) { $size += [long]$file.Length }
    return [pscustomobject]@{
        id = $Id; kind = $Kind; root = $WorkRoot; path = $Path; name = $Name; lineSlug = $Slug; category = $Category
        status = $Status; reasons = @($Reasons); sizeBytes = $size; fileCount = @($Files).Count; protectedFileCount = $ProtectedCount
        trackedChangeCount = $Tracked; untrackedCount = $Untracked; files = @($Files); entry = $Entry; repository = $Repository
    }
}

function Get-WorkingTreeChanges {
    [CmdletBinding()]
    param([string]$Path)

    $status = Invoke-Git $Path @('status', '--porcelain=v1', '--untracked-files=all')
    if ($status.ExitCode -ne 0) { return [pscustomobject]@{ Tracked = $null; Untracked = $null } }
    $lines = @($status.StdOut -split "`r?`n" | Where-Object { $_ })
    return [pscustomobject]@{ Tracked = @($lines | Where-Object { -not $_.StartsWith('??') }).Count; Untracked = @($lines | Where-Object { $_.StartsWith('??') }).Count }
}

function Get-WorktreeItems {
    [CmdletBinding()]
    param([string[]]$Roots, [hashtable]$Repositories, [object]$SessionState)

    $candidates = [Collections.Generic.List[object]]::new()
    $registered = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($rootPath in $Roots) {
        $repository = $Repositories[$rootPath]
        if ($null -eq $repository) { continue }
        foreach ($entry in $repository.Entries) { $registered[$entry.Path] = $entry }
    }
    foreach ($rootPath in $Roots) {
        $repository = $Repositories[$rootPath]
        if ($null -eq $repository) { continue }
        foreach ($entry in $repository.Entries) {
            if ([string]::Equals($entry.Path, $repository.Main, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $parent = [IO.Directory]::GetParent($entry.Path)
            $dispatchParent = Get-FullPath (Join-Path $rootPath "$script:SessionRoot\worktrees")
            $isDispatch = $null -ne $parent -and [string]::Equals($parent.FullName, $dispatchParent, [StringComparison]::OrdinalIgnoreCase)
            $isOrdinary = [string]::Equals($entry.Path, $rootPath, [StringComparison]::OrdinalIgnoreCase) -and $entry.Path -notmatch '(?i)[\\/]\.local[\\/]ai-sessions[\\/]worktrees[\\/]'
            if (-not $isDispatch -and -not $isOrdinary) { continue }
            if (@($candidates | Where-Object { $_.entry.Path -eq $entry.Path }).Count -gt 0) { continue }
            $candidates.Add([pscustomobject]@{ entry = $entry; root = $rootPath; repository = $repository; isDispatch = $isDispatch; registered = $true })
        }
        $dispatchParent = Join-Path $rootPath "$script:SessionRoot\worktrees"
        if ((Test-Path -LiteralPath $dispatchParent -PathType Container) -and -not (Test-ReparsePath $dispatchParent $rootPath)) {
            foreach ($directory in @(Get-ChildItem -LiteralPath $dispatchParent -Directory -Force)) {
                $path = Get-FullPath $directory.FullName
                if ($registered.ContainsKey($path)) { continue }
                $entry = [pscustomobject]@{ Path = $path; Branch = $null; Locked = $false; Prunable = $false }
                $candidates.Add([pscustomobject]@{ entry = $entry; root = $rootPath; repository = $repository; isDispatch = $true; registered = $false })
            }
        }
    }
    $items = [Collections.Generic.List[object]]::new()
    foreach ($candidate in @($candidates | Sort-Object { $_.entry.Path.Length } -Descending)) {
        try { $items.Add((Get-WorktreeItem $candidate $items $registered $SessionState)) }
        catch {
            $failure = ($_.Exception.Message -split "`r?`n")[0]
            $kind = if ($candidate.isDispatch) { 'dispatchWorktree' } else { 'worktree' }
            $items.Add((New-CleanupItem "$($kind.ToLowerInvariant()):$($candidate.entry.Path.ToLowerInvariant())" $kind $candidate.root $candidate.entry.Path ([IO.Path]::GetFileName($candidate.entry.Path)) $null $null 'needs-review' @("無法評估：$failure") @() 0 $null $null $candidate.entry $candidate.repository))
        }
    }
    return $items.ToArray()
}

function Get-WorktreeItem {
    [CmdletBinding()]
    param([object]$Candidate, [Collections.Generic.List[object]]$Items, [object]$Registered, [object]$SessionState)

    $entry = $candidate.entry
    $path = $entry.Path
    $name = [IO.Path]::GetFileName($path)
    $kind = if ($candidate.isDispatch) { 'dispatchWorktree' } else { 'worktree' }
    $reasons = [Collections.Generic.List[string]]::new()
    $slug = $null
    if (-not $candidate.registered) { $reasons.Add('未登記為 worktree') }
    if ($entry.Locked) { $reasons.Add('worktree 已鎖定') }
    if ($entry.Prunable -or -not (Test-Path -LiteralPath $path -PathType Container)) { $reasons.Add('worktree 已遺失') }
    if ((Test-Path -LiteralPath $path) -and (Test-ReparsePath $path $candidate.root) -and $candidate.isDispatch) { $reasons.Add('worktree 路徑為連結點') }
    $changes = if ($candidate.registered -and (Test-Path -LiteralPath $path -PathType Container)) { Get-WorkingTreeChanges $path } else { [pscustomobject]@{ Tracked = $null; Untracked = $null } }
    if (-not $candidate.isDispatch) {
        if ($null -eq $changes.Tracked) { $reasons.Add('改動數無法取得') }
        else {
            if ($changes.Tracked -gt 0) { $reasons.Add("未 commit 改動 $($changes.Tracked) 個") }
            if ($changes.Untracked -gt 0) { $reasons.Add("未追蹤檔案 $($changes.Untracked) 個") }
        }
        if ($null -eq $entry.Branch -or $entry.Branch -eq $candidate.repository.MainBranch -or -not $candidate.repository.MergedKnown -or $candidate.repository.Merged -notcontains $entry.Branch) { $reasons.Add('分支未合入主分支或無法判定') }
    }
    if (-not $SessionState.Known) { $reasons.Add('未取得 Session 清單') }
    else {
        foreach ($session in $SessionState.Sessions) {
            $cwd = Get-PropertyValue $session 'cwd'
            if ((Test-ActiveSession $session) -and $cwd -is [string] -and -not [string]::IsNullOrWhiteSpace($cwd)) {
                try { if (Test-PathWithin $cwd $path -OrEqual) { $reasons.Add('Session 使用中'); break } } catch { $reasons.Add('Session 路徑無法判定'); break }
            }
        }
    }
    $pidRoots = if ($candidate.isDispatch) { @($candidate.root, $path) } else { @($path, $candidate.repository.Main) }
    foreach ($reason in @(Get-DispatchUseReasons $path $name $candidate.isDispatch $pidRoots)) { $reasons.Add($reason) }
    if ($candidate.isDispatch -and $candidate.registered) {
        $owner = Get-DispatchOwner $candidate.root $path $name
        if ($null -ne $owner.Reason) { $reasons.Add($owner.Reason) }
        else {
            $slug = $owner.Slug
            $closure = Get-LineClosure $candidate.root $slug $candidate.repository $SessionState
            foreach ($reason in $closure.Reasons) { $reasons.Add("所屬線未結案：$reason") }
            $missing = @(Get-UnpreservedFiles $path $candidate.root)
            if ($missing.Count -gt 0) { $reasons.Add("$($missing.Count) 個報告或交接檔尚未保存回來源（例：$($missing[0])）") }
        }
    }
    if (-not $candidate.isDispatch -and (Test-Path -LiteralPath $path -PathType Container)) {
        $handoff = Join-Path $path "$script:SessionRoot\handoff"
        if ((Test-Path -LiteralPath $handoff -PathType Container) -and (Test-ReparsePath $handoff $path)) { $reasons.Add('線交接目錄為連結點') }
        elseif (Test-Path -LiteralPath $handoff -PathType Container) {
            foreach ($line in @(Get-ChildItem -LiteralPath $handoff -Directory -Force)) {
                if (-not (Test-Path -LiteralPath (Join-Path $line.FullName 'line.json') -PathType Leaf)) { continue }
                $closure = Get-LineClosure $path $line.Name $candidate.repository $SessionState
                if (-not $closure.Closed) { $reasons.Add("內含未結案線 $($line.Name)") }
                foreach ($reserved in $script:ReservedNames) {
                    $local = Join-Path $line.FullName $reserved
                    if ((Test-Path -LiteralPath $local -PathType Leaf) -and -not (Test-SameFile $local (Join-Path $candidate.repository.Main "$script:SessionRoot\handoff\$($line.Name)\$reserved") $path $candidate.repository.Main)) { $reasons.Add("線 $($line.Name) 的 $reserved 未保存") }
                }
            }
        }
        foreach ($area in @('inputs', 'ui-demo', 'screenshots', 'style-baselines')) {
            $directory = Join-Path $path "$script:SessionRoot\$area"
            if ((Test-Path -LiteralPath $directory) -and ((Test-ReparsePath $directory $path) -or @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop).Count -gt 0)) { $reasons.Add("含需保留素材 $area") }
        }
    }
    $nested = @($candidate.repository.Entries | Where-Object { Test-PathWithin $_.Path $path })
    $blocked = @($nested | Where-Object { $nestedPath = $_.Path; @($items | Where-Object { $_.path -eq $nestedPath -and $_.status -eq 'cleanable' }).Count -eq 0 })
    if ($blocked.Count -gt 0) { $reasons.Add("內含 $($blocked.Count) 個無法清理的 worktree") }
    $innerWorktrees = Join-Path $path "$script:SessionRoot\worktrees"
    if (Test-Path -LiteralPath $innerWorktrees -PathType Container) {
        if (Test-ReparsePath $innerWorktrees $path) { $reasons.Add('內含無法判定的 worktree 目錄') }
        else {
            $unregistered = @(Get-ChildItem -LiteralPath $innerWorktrees -Directory -Force | Where-Object { -not $registered.ContainsKey((Get-FullPath $_.FullName)) })
            if ($unregistered.Count -gt 0) { $reasons.Add("內含 $($unregistered.Count) 個未登記為 worktree 的資料夾") }
        }
    }
    $nestedPaths = @($nested | ForEach-Object { $_.Path })
    $gaps = [Collections.Generic.List[string]]::new()
    $files = if (Test-Path -LiteralPath $path) { @(Get-SafeEntries $path $path $nestedPaths -Inaccessible $gaps | Where-Object { -not $_.IsLink }) } else { @() }
    if ($gaps.Count -gt 0) { $reasons.Add((Format-InaccessibleReason $gaps.ToArray() $path)) }
    $status = if ($reasons.Count -eq 0) { 'cleanable' } else { 'needs-review' }
    $display = if ($null -ne $slug) { "$name（$slug）" } else { $name }
    return New-CleanupItem "$($kind.ToLowerInvariant()):$($path.ToLowerInvariant())" $kind $candidate.root $path $display $slug $null $status @($reasons | Select-Object -Unique) $files 0 $changes.Tracked $changes.Untracked $entry $candidate.repository
}

function Add-FileCategory {
    [CmdletBinding()]
    param([Collections.Generic.List[object]]$Items, [string]$WorkRoot, [string]$Slug, [string]$Category, [object[]]$Candidates, [hashtable]$ReferenceIndex, [string[]]$Gaps = @())

    $sessionBase = Join-Path $WorkRoot $script:SessionRoot
    $files = [Collections.Generic.List[object]]::new()
    $protected = [Collections.Generic.List[string]]::new()
    foreach ($entry in $Candidates) {
        if (Test-PreservedFile $entry.Path $sessionBase) { continue }
        if ($entry.IsLink -or (Test-ReparsePath $entry.Path $WorkRoot)) { $protected.Add('連結點'); continue }
        $source = Get-ReferenceSource $entry.Path $WorkRoot $Slug $ReferenceIndex
        if ($null -ne $source) { $protected.Add("被 $source 引用"); continue }
        $files.Add($entry)
    }
    $unreadable = [Collections.Generic.List[string]]::new()
    if ($Gaps.Count -gt 0) { $unreadable.Add((Format-InaccessibleReason $Gaps $sessionBase)) }
    if ($files.Count -gt 0 -and $script:ReferenceGaps.Count -gt 0) { $unreadable.Add('引用來源' + (Format-InaccessibleReason $script:ReferenceGaps.ToArray() $sessionBase)) }
    if ($files.Count -eq 0 -and $protected.Count -eq 0 -and $unreadable.Count -eq 0) { return }
    $status = if ($unreadable.Count -gt 0) { 'needs-review' } elseif ($files.Count -gt 0) { 'cleanable' } else { 'protected' }
    $area = switch ($Category) { 'history' { 'history' } 'handoff-extras' { 'handoff' } 'report-logs' { 'report' } }
    $path = Join-Path $WorkRoot "$script:SessionRoot\$area\$Slug"
    $id = "lineartifacts:$($WorkRoot.ToLowerInvariant()):$Slug`:$Category"
    $reasons = @($protected | Select-Object -Unique) + $unreadable.ToArray()
    $Items.Add((New-CleanupItem $id 'lineArtifacts' $WorkRoot $path "$Slug · $Category" $Slug $Category $status $reasons $files.ToArray() $protected.Count))
}

function Add-LineArtifacts {
    [CmdletBinding()]
    param([Collections.Generic.List[object]]$Items, [string]$RootPath, [string]$Base, [object]$Line, [object]$Repository, [object]$SessionState, [hashtable]$ReferenceIndex)

    if (-not (Test-Path -LiteralPath (Join-Path $Line.FullName 'line.json') -PathType Leaf)) { return }
    $slug = $Line.Name
    $closure = Get-LineClosure $RootPath $slug $Repository $SessionState
    if (-not $closure.Closed) {
        $protectedFiles = @(
            foreach ($area in @('handoff', 'report', 'history')) {
                Get-SafeEntries (Join-Path $Base "$area\$slug") $RootPath | Where-Object { -not $_.IsLink }
            }
        )
        $Items.Add((New-CleanupItem "lineartifacts:$($RootPath.ToLowerInvariant()):$slug`:all" 'lineArtifacts' $RootPath $Line.FullName $slug $slug 'all' 'protected' $closure.Reasons $protectedFiles $protectedFiles.Count))
        return
    }
    $historyGaps = [Collections.Generic.List[string]]::new()
    $historyFiles = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-SafeEntries (Join-Path $Base "history\$slug") $RootPath -Inaccessible $historyGaps)) { $historyFiles.Add($file) }
    foreach ($record in @(Get-PidRecords @($RootPath))) {
        if ($record.Invalid -or -not $record.Data.ContainsKey('line-slug') -or $record.Data['line-slug'] -ne $slug -or -not $record.Data.ContainsKey('root-pid')) { continue }
        $processId = 0
        if (-not [int]::TryParse($record.Data['root-pid'], [ref]$processId) -or $processId -le 0 -or $null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) { continue }
        foreach ($file in @(Get-SafeEntries $record.Path $RootPath)) { $historyFiles.Add($file) }
        $suffix = [IO.Path]::GetFileNameWithoutExtension($record.Path) -replace '^codex-pid-', ''
        $eventPath = Join-Path (Split-Path -Parent $record.Path) "codex-exec-$suffix.jsonl"
        foreach ($file in @(Get-SafeEntries $eventPath $RootPath)) { $historyFiles.Add($file) }
        if ($record.Data.ContainsKey('dispatch-slug') -and $record.Data['dispatch-slug'] -match '^[a-zA-Z0-9_-]+$') {
            $thread = Join-Path (Split-Path -Parent $record.Path) "codex-thread-$($record.Data['dispatch-slug']).txt"
            foreach ($file in @(Get-SafeEntries $thread $RootPath)) { $historyFiles.Add($file) }
        }
    }
    Add-FileCategory $Items $RootPath $slug 'history' @($historyFiles | Sort-Object Path -Unique) $ReferenceIndex $historyGaps.ToArray()
    $extraGaps = [Collections.Generic.List[string]]::new()
    $extras = @()
    foreach ($child in @(Get-ChildItem -LiteralPath $Line.FullName -Force)) {
        if ($script:ReservedNames -contains $child.Name) { continue }
        $extras += @(Get-SafeEntries $child.FullName $RootPath -Inaccessible $extraGaps)
    }
    Add-FileCategory $Items $RootPath $slug 'handoff-extras' $extras $ReferenceIndex $extraGaps.ToArray()
    $reportGaps = [Collections.Generic.List[string]]::new()
    $logs = [Collections.Generic.List[object]]::new()
    $review = [Collections.Generic.List[object]]::new()
    $reviewReasons = [Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-SafeEntries (Join-Path $Base "report\$slug") $RootPath -Inaccessible $reportGaps)) {
        if ($file.IsLink) { $logs.Add($file); continue }
        if ($file.Length -lt $LargeFileBytes) { continue }
        if ($script:LogExtensions -notcontains [IO.Path]::GetExtension($file.Path).ToLowerInvariant()) { $review.Add($file); $reviewReasons.Add('大檔類型不在可清理清單') }
        elseif (-not (Test-TextLog $file.Path)) { $review.Add($file); $reviewReasons.Add('不是文字檔') }
        else { $logs.Add($file) }
    }
    Add-FileCategory $Items $RootPath $slug 'report-logs' $logs.ToArray() $ReferenceIndex $reportGaps.ToArray()
    if ($review.Count -gt 0) {
        $Items.Add((New-CleanupItem "lineartifacts:$($RootPath.ToLowerInvariant()):$slug`:report-logs:review" 'lineArtifacts' $RootPath (Join-Path $Base "report\$slug") "$slug · report-logs" $slug 'report-logs' 'needs-review' @($reviewReasons | Select-Object -Unique) $review.ToArray()))
    }
}

function Get-BackupStamp {
    [CmdletBinding()]
    param([IO.DirectoryInfo]$Directory)

    $stamp = [DateTime]::MinValue
    if ([DateTime]::TryParseExact($Directory.Name, 'yyyyMMdd_HHmmss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$stamp)) { return $stamp }
    return $Directory.LastWriteTime
}

function Add-BackupItem {
    [CmdletBinding()]
    param([Collections.Generic.List[object]]$Items, [string]$RootPath, [IO.DirectoryInfo]$Directory, [hashtable]$ReferenceIndex)

    $sessionBase = Join-Path $RootPath $script:SessionRoot
    $gaps = [Collections.Generic.List[string]]::new()
    $entries = @(Get-SafeEntries $Directory.FullName $RootPath -Inaccessible $gaps)
    $files = @($entries | Where-Object { -not (Test-PreservedFile $_.Path $sessionBase) })
    $reasons = [Collections.Generic.List[string]]::new()
    if (([DateTime]::Now - (Get-BackupStamp $Directory)).TotalDays -lt $BackupMinAgeDays) { $reasons.Add("未滿 $BackupMinAgeDays 天") }
    foreach ($file in $files) {
        if ($file.IsLink) { $reasons.Add('連結點'); continue }
        $source = Get-ReferenceSource $file.Path $RootPath '' $ReferenceIndex
        if ($null -ne $source) { $reasons.Add("被 $source 引用") }
    }
    if ($files.Count -eq 0 -and $entries.Count -gt 0) { $reasons.Add('僅含保留清單檔案') }
    $unreadable = [Collections.Generic.List[string]]::new()
    if ($gaps.Count -gt 0) { $unreadable.Add((Format-InaccessibleReason $gaps.ToArray() $sessionBase)) }
    if ($files.Count -gt 0 -and $script:ReferenceGaps.Count -gt 0) { $unreadable.Add('引用來源' + (Format-InaccessibleReason $script:ReferenceGaps.ToArray() $sessionBase)) }
    $status = if ($reasons.Count -gt 0) { 'protected' } elseif ($unreadable.Count -gt 0) { 'needs-review' } else { 'cleanable' }
    $allReasons = @($reasons | Select-Object -Unique) + $unreadable.ToArray()
    $Items.Add((New-CleanupItem "backup:$($Directory.FullName.ToLowerInvariant())" 'backup' $RootPath $Directory.FullName $Directory.Name $null $null $status $allReasons @($files | Where-Object { -not $_.IsLink }) $(if ($status -eq 'protected') { $files.Count } else { 0 })))
}

function Get-LineItems {
    [CmdletBinding()]
    param([string[]]$Roots, [hashtable]$Repositories, [object]$SessionState, [hashtable]$ReferenceIndex)

    $items = [Collections.Generic.List[object]]::new()
    foreach ($rootPath in $Roots) {
        $base = Join-Path $rootPath $script:SessionRoot
        $handoff = Join-Path $base 'handoff'
        if ((Test-Path -LiteralPath $handoff -PathType Container) -and -not (Test-ReparsePath $handoff $rootPath)) {
            foreach ($line in @(Get-ChildItem -LiteralPath $handoff -Directory -Force)) {
                try { Add-LineArtifacts $items $rootPath $base $line $Repositories[$rootPath] $SessionState $ReferenceIndex }
                catch {
                    $failure = ($_.Exception.Message -split "`r?`n")[0]
                    $items.Add((New-CleanupItem "lineartifacts:$($rootPath.ToLowerInvariant()):$($line.Name)`:all" 'lineArtifacts' $rootPath $line.FullName $line.Name $line.Name 'all' 'needs-review' @("無法評估：$failure") @()))
                }
            }
        }
        $backups = Join-Path $base 'backups'
        if ((Test-Path -LiteralPath $backups -PathType Container) -and -not (Test-ReparsePath $backups $rootPath)) {
            foreach ($directory in @(Get-ChildItem -LiteralPath $backups -Directory -Force)) {
                try { Add-BackupItem $items $rootPath $directory $ReferenceIndex }
                catch {
                    $failure = ($_.Exception.Message -split "`r?`n")[0]
                    $items.Add((New-CleanupItem "backup:$($directory.FullName.ToLowerInvariant())" 'backup' $rootPath $directory.FullName $directory.Name $null $null 'needs-review' @("無法評估：$failure") @()))
                }
            }
        }
    }
    return $items.ToArray()
}

function Get-CleanupPlan {
    [CmdletBinding()]
    param([string[]]$Roots, [object]$SessionState)

    Clear-PlanCaches
    $repositories = @{}
    $warnings = [Collections.Generic.List[string]]::new()
    foreach ($rootPath in $Roots) {
        $repositories[$rootPath] = Get-Repository $rootPath
        if ($null -eq $repositories[$rootPath]) { $warnings.Add("無法取得 Git 工作樹：$rootPath") }
    }
    $items = [Collections.Generic.List[object]]::new()
    $references = @{}
    if ($Target -in @('all', 'worktrees')) {
        foreach ($item in @(Get-WorktreeItems $Roots $repositories $SessionState)) { $items.Add($item) }
    }
    if ($Target -in @('all', 'lines')) {
        $references = Get-ReferenceIndex $Roots
        foreach ($item in @(Get-LineItems $Roots $repositories $SessionState $references)) { $items.Add($item) }
    }
    $cleanable = @($items | Where-Object { $_.status -eq 'cleanable' } | Sort-Object id)
    $identity = @($cleanable | ForEach-Object { "$($_.id)|$($_.fileCount)|$($_.sizeBytes)" }) -join "`n"
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant()
    $bytes = [long]0
    foreach ($item in $cleanable) { $bytes += $item.sizeBytes }
    return [pscustomobject]@{
        schema = 'ai-agents.work-overview-cleanup.v1'; mode = 'list'; generatedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        planId = $hash; sessionsKnown = $SessionState.Known; items = $items.ToArray()
        totals = [pscustomobject]@{ cleanableCount = $cleanable.Count; cleanableBytes = $bytes; needsReviewCount = @($items | Where-Object { $_.status -eq 'needs-review' }).Count; protectedCount = @($items | Where-Object { $_.status -eq 'protected' }).Count }
        warnings = $warnings.ToArray(); result = $null; repositories = $repositories; referenceIndex = $references
    }
}

function Remove-DispatchWorktree {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param([string]$WorkRoot, [string]$Path)

    if ($PSCmdlet.ShouldProcess($Path, '移除已確認的 dispatch worktree')) {
        $result = Invoke-Git $WorkRoot @('worktree', 'remove', '--force', $Path)
        if ($result.ExitCode -ne 0) { throw $result.StdErr.Trim() }
    }
}

function Remove-OrdinaryWorktree {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param([string]$WorkRoot, [string]$Path)

    if ($PSCmdlet.ShouldProcess($Path, '移除已確認的 worktree')) {
        $result = Invoke-Git $WorkRoot @('worktree', 'remove', $Path)
        if ($result.ExitCode -ne 0) { throw $result.StdErr.Trim() }
    }
}

function Remove-CleanupFiles {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param([object]$Item, [hashtable]$ReferenceIndex)

    $deletedBytes = [long]0
    $deletedCount = 0
    $failures = [Collections.Generic.List[string]]::new()
    $base = Get-FullPath (Join-Path $Item.root $script:SessionRoot)
    foreach ($file in $Item.files) {
        try {
            $path = Get-FullPath $file.Path
            if (-not (Test-PathWithin $path $base) -or (Test-ReparsePath $path $Item.root)) { throw '路徑越界或為連結點' }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw '狀態已變更' }
            if (Test-PreservedFile $path $base) { throw '保留清單' }
            if ($null -ne (Get-ReferenceSource $path $Item.root $Item.lineSlug $ReferenceIndex)) { throw '檔案已被引用' }
            $length = (Get-Item -LiteralPath $path -Force).Length
            if ($PSCmdlet.ShouldProcess($path, '刪除已確認的檔案')) { [IO.File]::Delete($path); $deletedBytes += $length; $deletedCount++ }
        }
        catch { $failures.Add("$($file.Path)：$($_.Exception.Message)") }
    }
    $stop = switch ($Item.kind) {
        'backup' { Join-Path $base 'backups' }
        default {
            switch ($Item.category) {
                'history' { Join-Path $base 'history' }
                'handoff-extras' { Join-Path $base "handoff\$($Item.lineSlug)" }
                'report-logs' { Join-Path $base "report\$($Item.lineSlug)" }
            }
        }
    }
    $directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($Item.kind -eq 'backup') { $null = $directories.Add($Item.path) }
    foreach ($file in $Item.files) {
        $parent = [IO.Directory]::GetParent($file.Path)
        while ($null -ne $parent -and (Test-PathWithin $parent.FullName $stop)) { $null = $directories.Add($parent.FullName); $parent = $parent.Parent }
    }
    foreach ($directory in @($directories | Sort-Object Length -Descending)) {
        try {
            if ((Test-Path -LiteralPath $directory -PathType Container) -and -not (Test-ReparsePath $directory $Item.root) -and @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0 -and $PSCmdlet.ShouldProcess($directory, '移除空目錄')) { [IO.Directory]::Delete($directory, $false) }
        }
        catch { $failures.Add("$directory：$($_.Exception.Message)") }
    }
    return [pscustomobject]@{ Bytes = $deletedBytes; Count = $deletedCount; Failures = $failures.ToArray() }
}

function Confirm-PlannedItem {
    [CmdletBinding()]
    param([object]$Planned, [object]$Plan, [object]$SessionState, [hashtable]$ClosureCache)

    Clear-ItemCaches
    if ($Planned.kind -in @('worktree', 'dispatchWorktree')) {
        $repository = Get-Repository $Planned.root
        if ($null -eq $repository) { throw '狀態已變更' }
        $entry = @($repository.Entries | Where-Object { [string]::Equals($_.Path, $Planned.path, [StringComparison]::OrdinalIgnoreCase) })
        if ($entry.Count -ne 1) { throw '狀態已變更' }
        $registered = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($known in $repository.Entries) { $registered[$known.Path] = $known }
        $candidate = [pscustomobject]@{ entry = $entry[0]; root = $Planned.root; repository = $repository; isDispatch = ($Planned.kind -eq 'dispatchWorktree'); registered = $true }
        $current = Get-WorktreeItem $candidate ([Collections.Generic.List[object]]::new()) $registered $SessionState
        if ($current.id -ne $Planned.id -or $current.status -ne 'cleanable') { throw '狀態已變更' }
        return $current
    }
    if ($Planned.kind -eq 'lineArtifacts') {
        $key = "$($Planned.root.ToLowerInvariant())|$($Planned.lineSlug)"
        if (-not $ClosureCache.ContainsKey($key)) { $ClosureCache[$key] = Get-LineClosure $Planned.root $Planned.lineSlug $Plan.repositories[$Planned.root] $SessionState }
        if (-not $ClosureCache[$key].Closed) { throw '狀態已變更' }
    }
    elseif ($Planned.kind -eq 'backup') {
        if (-not (Test-Path -LiteralPath $Planned.path -PathType Container) -or ([DateTime]::Now - (Get-BackupStamp (Get-Item -LiteralPath $Planned.path -Force))).TotalDays -lt $BackupMinAgeDays) { throw '狀態已變更' }
    }
    return $Planned
}

function Remove-CleanupPlan {
    [CmdletBinding()]
    param([object]$Plan, [object]$SessionState)

    $deleted = [Collections.Generic.List[object]]::new()
    $failed = [Collections.Generic.List[object]]::new()
    $failedWorktrees = [Collections.Generic.List[string]]::new()
    $closureCache = @{}
    $freed = [long]0
    $ordered = @($Plan.items | Where-Object { $_.status -eq 'cleanable' -and $_.kind -in @('worktree', 'dispatchWorktree') } | Sort-Object { $_.path.Length } -Descending) + @($Plan.items | Where-Object { $_.status -eq 'cleanable' -and $_.kind -notin @('worktree', 'dispatchWorktree') })
    foreach ($planned in $ordered) {
        try {
            if ($planned.kind -in @('worktree', 'dispatchWorktree') -and @($failedWorktrees | Where-Object { Test-PathWithin $_ $planned.path }).Count -gt 0) { throw '狀態已變更' }
            $item = Confirm-PlannedItem $planned $Plan $SessionState $closureCache
            if ($item.kind -eq 'dispatchWorktree') { Remove-DispatchWorktree $item.root $item.path }
            elseif ($item.kind -eq 'worktree') { Remove-OrdinaryWorktree $item.repository.Main $item.path }
            else {
                $fileResult = Remove-CleanupFiles $item $Plan.referenceIndex
                $freed += $fileResult.Bytes
                if ($fileResult.Count -gt 0 -or ($item.kind -eq 'backup' -and $fileResult.Failures.Count -eq 0)) { $deleted.Add([pscustomobject]@{ id = $item.id; bytes = $fileResult.Bytes }) }
                if ($fileResult.Failures.Count -gt 0) { $failed.Add([pscustomobject]@{ id = $item.id; reason = $fileResult.Failures -join '；' }) }
                continue
            }
            $freed += $planned.sizeBytes
            $deleted.Add([pscustomobject]@{ id = $item.id; bytes = $planned.sizeBytes })
            if ($null -ne $item.entry.Branch) {
                $branch = Invoke-Git $item.repository.Main @('branch', '-d', $item.entry.Branch)
                if ($branch.ExitCode -ne 0) { $Plan.warnings += "無法刪除分支 $($item.entry.Branch)：$($branch.StdErr.Trim())" }
            }
        }
        catch {
            if ($planned.kind -in @('worktree', 'dispatchWorktree')) { $failedWorktrees.Add($planned.path) }
            $failed.Add([pscustomobject]@{ id = $planned.id; reason = $_.Exception.Message })
        }
    }
    return [pscustomobject]@{ deleted = $deleted.ToArray(); failed = $failed.ToArray(); freedBytes = $freed }
}

function Write-CleanupPlan {
    [CmdletBinding()]
    param([object]$Plan, [switch]$Json)

    if ($Json) {
        $publicItems = @($Plan.items | Select-Object id, kind, root, path, name, lineSlug, category, status, reasons, sizeBytes, fileCount, protectedFileCount, trackedChangeCount, untrackedCount)
        $output = [ordered]@{ schema = $Plan.schema; mode = $Plan.mode; generatedAtUtc = $Plan.generatedAtUtc; planId = $Plan.planId; sessionsKnown = $Plan.sessionsKnown; items = $publicItems; totals = $Plan.totals; warnings = $Plan.warnings; result = $Plan.result }
        $jsonText = ConvertTo-Json -InputObject $output -Depth 20 -Compress
        return [regex]::Replace($jsonText, '[^\u0000-\u007F]', [Text.RegularExpressions.MatchEvaluator]{ param($match) '\u{0:x4}' -f [int][char]$match.Value[0] })
    }
    Write-Output "清理計畫 $($Plan.planId)"
    foreach ($item in $Plan.items) {
        $detail = if ($item.kind -in @('worktree', 'dispatchWorktree') -and $null -eq $item.trackedChangeCount) { '改動數無法取得' } elseif ($item.kind -in @('worktree', 'dispatchWorktree')) { "未 commit 改動 $($item.trackedChangeCount) 個、未追蹤 $($item.untrackedCount) 個" } else { '' }
        Write-Output ("{0} | {1} | {2} bytes | {3} | {4}" -f $item.name, $item.status, $item.sizeBytes, ($item.reasons -join '；'), $detail)
    }
    if ($null -ne $Plan.result) { Write-Output "已釋放 $($Plan.result.freedBytes) bytes；失敗 $($Plan.result.failed.Count) 項" }
}

$mutex = $null
$ownsMutex = $false
try {
    $roots = [Collections.Generic.List[string]]::new()
    foreach ($part in $Root) {
        foreach ($value in ($part -split ';')) {
            $value = $value.Trim()
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            if (-not [IO.Path]::IsPathFullyQualified($value)) { throw "Root 必須是絕對路徑：$value" }
            $path = Get-FullPath $value
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Root 不存在：$path" }
            if (Test-ReparsePath $path $path) { throw "Root 不可為連結點：$path" }
            if (@($roots | Where-Object { [string]::Equals($_, $path, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) { $roots.Add($path) }
        }
    }
    if ($roots.Count -eq 0) { throw '至少需要一個 Root' }
    $mutex = [Threading.Mutex]::new($false, 'Global\ai-agents-work-overview-cleanup')
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { [Console]::Error.WriteLine('另一個清理程序執行中'); exit 4 }
    $sessionState = Get-SessionState -FromStdin:$SessionsFromStdin
    $plan = Get-CleanupPlan $roots.ToArray() $sessionState
    if ($PSBoundParameters.ContainsKey('ConfirmPlan')) {
        if ($ConfirmPlan -cne $plan.planId) { [Console]::Error.WriteLine('清單已變更，請重新列出'); exit 3 }
        $plan.mode = 'delete'
        $plan.result = Remove-CleanupPlan $plan $sessionState
    }
    Write-CleanupPlan $plan -Json:$AsJson
    if ($null -ne $plan.result -and $plan.result.failed.Count -gt 0) { exit 2 }
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
