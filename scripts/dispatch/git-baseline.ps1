function Resolve-DispatchOutputPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$CandidatePath,

        [AllowEmptyString()]
        [string]$SourceRoot,

        [AllowEmptyString()]
        [string]$ExecutionRoot,

        [string[]]$TargetPath = @()
    )

    try {
        $resolvedCandidate = Resolve-AbsolutePath -Path $CandidatePath
    }
    catch {
        Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message ('candidate path 無法解析：' + $_.Exception.Message)
    }

    $candidateRoots = New-Object System.Collections.Generic.List[string]
    foreach ($rootValue in @($SourceRoot, $ExecutionRoot)) {
        if ([string]::IsNullOrWhiteSpace([string]$rootValue)) {
            continue
        }

        try {
            $resolvedRoot = Resolve-AbsolutePath -Path ([string]$rootValue)
        }
        catch {
            Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message ('root path 無法解析：' + $_.Exception.Message)
        }

        if (-not ($candidateRoots -contains $resolvedRoot)) {
            $candidateRoots.Add($resolvedRoot)
        }
    }

    if ($candidateRoots.Count -eq 0) {
        Throw-DispatchOutputFailure -Code 'DispatchOutputRootUnavailable' -Message '未提供可驗證的 SourceRoot 或 ExecutionRoot。'
    }

    $containedRoots = New-Object System.Collections.Generic.List[string]
    foreach ($rootValue in $candidateRoots.ToArray()) {
        if (Test-PathWithinRoot -Path $resolvedCandidate -Root $rootValue) {
            $containedRoots.Add($rootValue)
        }
    }
    if ($containedRoots.Count -eq 0) {
        Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message "candidate 不在 SourceRoot 或 ExecutionRoot 內：$resolvedCandidate"
    }

    foreach ($rootValue in $containedRoots.ToArray()) {
        if (-not (Test-Path -LiteralPath $rootValue -PathType Container)) {
            Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message "root 不存在或不是目錄：$rootValue"
        }

        Assert-DispatchOutputPathNoReparsePoint -Root $rootValue -Path $resolvedCandidate

        try {
            $gitState = Get-ExistingGitRepositoryState -SourceRoot $rootValue
        }
        catch {
            Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message ('Git tracked probe 無法判定：' + $_.Exception.Message)
        }

        if ($gitState.IsRepository -and -not (Test-Path -LiteralPath $resolvedCandidate -PathType Container)) {
            try {
                $trackedState = @(Get-TrackedPathState -SourceRoot $rootValue -TargetPath @($resolvedCandidate))
            }
            catch {
                Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message ('Git tracked probe 無法判定：' + $_.Exception.Message)
            }
            if (@($trackedState | Where-Object { $_.IsTracked }).Count -gt 0) {
                Throw-DispatchOutputFailure -Code 'DispatchOutputTrackedTarget' -Message "candidate 指向 tracked file：$resolvedCandidate"
            }
        }
    }

    $collisionRoot = if (-not [string]::IsNullOrWhiteSpace([string]$SourceRoot)) {
        Resolve-AbsolutePath -Path $SourceRoot
    }
    else {
        $candidateRoots[0]
    }
    foreach ($target in @($TargetPath)) {
        if ([string]::IsNullOrWhiteSpace([string]$target)) {
            continue
        }

        try {
            $resolvedTarget = Resolve-SourceTargetPath -Path ([string]$target) -Root $collisionRoot
        }
        catch {
            Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message ('TargetPath 無法解析：' + $_.Exception.Message)
        }
        if (Test-PathWithinRoot -Path $resolvedCandidate -Root $resolvedTarget) {
            Throw-DispatchOutputFailure -Code 'DispatchOutputTargetCollision' -Message "candidate 命中 TargetPath：$resolvedCandidate; target=$resolvedTarget"
        }
    }

    return $resolvedCandidate
}

function Assert-DispatchOutputPathNoReparsePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolvedRoot = Normalize-DispatchRootPath -Path $Root
    $resolvedPath = Resolve-AbsolutePath -Path $Path
    if (-not [string]::Equals($resolvedRoot, $resolvedPath, [System.StringComparison]::OrdinalIgnoreCase) -and -not (Test-PathWithinRoot -Path $resolvedPath -Root $resolvedRoot)) {
        Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message "candidate 不在 root 內：$resolvedPath"
    }
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message "root 不存在或不是目錄：$resolvedRoot"
    }

    $rootComponent = $resolvedRoot
    while (-not [string]::IsNullOrWhiteSpace($rootComponent)) {
        if (Test-Path -LiteralPath $rootComponent) {
            $componentItem = Get-Item -LiteralPath $rootComponent -Force -ErrorAction Stop
            if (($componentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message "root path 不可包含 ReparsePoint：$rootComponent"
            }
        }
        $parentComponent = Split-Path -Parent $rootComponent
        if ([string]::Equals($parentComponent, $rootComponent, [StringComparison]::OrdinalIgnoreCase)) { break }
        $rootComponent = $parentComponent
    }
    $currentPath = $resolvedRoot
    $rootItem = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message "root 不可為 ReparsePoint：$currentPath"
    }

    $relativePath = $resolvedPath.Substring($resolvedRoot.Length).TrimStart([char[]]@('\', '/'))
    foreach ($part in @($relativePath -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $currentPath = Join-Path -Path $currentPath -ChildPath $part
        if (Test-Path -LiteralPath $currentPath) {
            $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message "candidate path 不可包含 ReparsePoint：$currentPath"
            }
        }
    }
}

function Get-GitRepositoryState {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot
    )

    $existingState = Get-ExistingGitRepositoryState -SourceRoot $SourceRoot
    if ($existingState.IsRepository) {
        return [ordered]@{
            GitOrigin = 'existing'
        }
    }

    $exception = New-Object System.InvalidOperationException('SourceRootNotGitRepository：SourceRoot 不是 Git 儲存庫。請先自行在 SourceRoot 執行 git init，再執行 Preflight。')
    $exception.Data['errorCode'] = 'SourceRootNotGitRepository'
    throw $exception
}

function Get-ExistingGitRepositoryState {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot
    )

    $probe = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments @('-C', $SourceRoot, 'rev-parse', '--is-inside-work-tree') -AllowFailure
    if ($probe.ExitCode -eq 0 -and $probe.StdOut.Trim() -eq 'true') {
        return [ordered]@{
            IsRepository = $true
        }
    }

    $notRepository = $probe.StdErr -match '(?i)not a git repository|不是 git 儲存庫'
    if ($probe.ExitCode -ne 0 -and $notRepository) {
        return [ordered]@{
            IsRepository = $false
        }
    }

    throw "Git 前置探針失敗，未判定為可初始化的目錄。exit code $($probe.ExitCode)：$($probe.StdErr.Trim())"
}

function Get-GitOutputLines {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return @()
    }

    $nul = [char]0
    $values = @($Text -split $nul | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($values.Count -eq 1 -and $values[0] -notmatch [string]$nul) {
        $values = @($values[0] -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    return @($values | ForEach-Object { $_.TrimEnd([char[]]@([char]13, [char]10)) })
}

function Get-DispatchTargetKind {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InputPath,

        [Parameter(Mandatory)]
        [string]$FullPath,

        [Parameter(Mandatory)]
        [bool]$Exists
    )

    if ($Exists) {
        if (Test-Path -LiteralPath $FullPath -PathType Container) {
            return 'directory'
        }
        if (Test-Path -LiteralPath $FullPath -PathType Leaf) {
            return 'file'
        }
        throw "無法判定 target_path 的實際類型：$FullPath"
    }

    if ($InputPath.EndsWith([string][char]92, [StringComparison]::Ordinal) -or $InputPath.EndsWith([string][char]47, [StringComparison]::Ordinal)) {
        return 'directory'
    }

    return 'file'
}

function Get-TrackedPathState {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string[]]$TargetPath
    )

    $states = New-Object System.Collections.Generic.List[object]
    foreach ($target in $TargetPath) {
        $fullPath = Resolve-SourceTargetPath -Path $target -Root $SourceRoot
        $relativePath = (Get-RelativePathFromRoot -Path $fullPath -Root $SourceRoot).TrimEnd([char[]]@([char]92, [char]47))
        if ([string]::IsNullOrWhiteSpace($relativePath)) { $relativePath = '.' }
        $trackedResult = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments @('ls-files', '--error-unmatch', '--', $relativePath) -AllowFailure
        $isTracked = $false
        if ($trackedResult.ExitCode -eq 0) {
            if ([string]::IsNullOrWhiteSpace($trackedResult.StdOut)) {
                throw "git ls-files 成功但未回傳 tracked 路徑：$relativePath"
            }
            $isTracked = $true
        }
        elseif ($trackedResult.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($trackedResult.StdOut) -and $trackedResult.StdErr -match '(?i)did not match any file|did not match any files|not match any file') {
            $isTracked = $false
        }
        else {
            throw "git ls-files 探針失敗，無法判定 tracked 狀態：$relativePath；exit code $($trackedResult.ExitCode)；$($trackedResult.StdErr.Trim())"
        }

        $ignoredResult = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments @('check-ignore', '--quiet', '--no-index', '--', $relativePath) -AllowFailure
        if ($ignoredResult.ExitCode -eq 0) {
            $isIgnored = $true
        }
        elseif ($ignoredResult.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($ignoredResult.StdErr)) {
            $isIgnored = $false
        }
        else {
            throw "git check-ignore 探針失敗，無法判定 ignored 狀態：$relativePath；exit code $($ignoredResult.ExitCode)；$($ignoredResult.StdErr.Trim())"
        }

        $exists = Test-Path -LiteralPath $fullPath
        $targetKind = Get-DispatchTargetKind -InputPath $target -FullPath $fullPath -Exists $exists
        $states.Add([pscustomobject]@{
                InputPath    = $target
                FullPath     = $fullPath
                RelativePath = $relativePath
                Exists       = $exists
                TargetKind   = $targetKind
                IsTracked    = $isTracked
                IsIgnored     = $isIgnored
                IsNewOutput   = -not $isTracked
            })
    }

    return @($states.ToArray())
}

function Get-NonGitTargetState {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string[]]$TargetPath
    )

    $states = New-Object System.Collections.Generic.List[object]
    foreach ($target in $TargetPath) {
        $fullPath = Resolve-SourceTargetPath -Path $target -Root $SourceRoot
        $relativePath = (Get-RelativePathFromRoot -Path $fullPath -Root $SourceRoot).TrimEnd([char[]]@([char]92, [char]47))
        if ([string]::IsNullOrWhiteSpace($relativePath)) { $relativePath = '.' }
        $exists = Test-Path -LiteralPath $fullPath
        $targetKind = Get-DispatchTargetKind -InputPath $target -FullPath $fullPath -Exists $exists
        $states.Add([pscustomobject]@{
                InputPath    = $target
                FullPath     = $fullPath
                RelativePath = $relativePath
                Exists       = $exists
                TargetKind   = $targetKind
                IsTracked    = $false
                IsIgnored    = $false
                IsNewOutput  = -not (Test-Path -LiteralPath $fullPath)
            })
    }

    return @($states.ToArray())
}

function Get-RequiredPreflightProperty {
    param(
        [Parameter(Mandatory)]
        [psobject]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or -not ($property.Value -is [string]) -or [string]::IsNullOrWhiteSpace($property.Value)) {
        throw "Preflight 輸出缺少必要欄位：$Name"
    }

    return $property.Value
}

function Test-DispatchSecretPathName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $normalizedPath = $Path.Replace('\', '/').TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
        return $false
    }

    $fileName = $normalizedPath.Substring($normalizedPath.LastIndexOf('/') + 1)
    return $fileName -match '^(?i:(?:\.env(?:\..*)?|.*\.(?:pfx|pem|key)|secrets\..*))$'
}

function Apply-SourceCarryIn {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$DispatchRoot
    )

    $trackedFilesResult = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments @('diff', 'HEAD', '--name-only', '-z', '--no-ext-diff', '--no-renames', '--')
    $trackedFiles = @(Get-GitOutputLines -Text $trackedFilesResult.StdOut)
    $includedTrackedFiles = New-Object System.Collections.Generic.List[string]
    $excludedSecrets = New-Object System.Collections.Generic.List[string]
    foreach ($relativePath in $trackedFiles) {
        if (Test-DispatchSecretPathName -Path $relativePath) {
            $normalizedPath = $relativePath.Replace('\', '/')
            if (-not $excludedSecrets.Contains($normalizedPath)) {
                $excludedSecrets.Add($normalizedPath)
            }
            continue
        }

        $includedTrackedFiles.Add($relativePath)
    }

    $trackedPatch = ''
    if ($includedTrackedFiles.Count -gt 0) {
        $patchArguments = @('diff', 'HEAD', '--binary', '--no-ext-diff', '--no-renames', '--') + @($includedTrackedFiles.ToArray())
        $diffResult = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments $patchArguments
        $trackedPatch = $diffResult.StdOut
    }
    $untrackedResult = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments @('ls-files', '--others', '--exclude-standard', '-z')
    $untrackedFiles = @(Get-GitOutputLines -Text $untrackedResult.StdOut)
    $copiedFiles = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrEmpty($trackedPatch)) {
        $applyResult = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('apply', '--whitespace=nowarn', '--recount', '-') -StandardInput $trackedPatch -AllowFailure
        if ($applyResult.ExitCode -ne 0) {
            throw "套用來源 tracked patch 失敗，來源變更已保留。$($applyResult.StdErr.Trim())"
        }
    }

    foreach ($relativePath in $untrackedFiles) {
        if (Test-DispatchSecretPathName -Path $relativePath) {
            $normalizedPath = $relativePath.Replace('\', '/')
            if (-not $excludedSecrets.Contains($normalizedPath)) {
                $excludedSecrets.Add($normalizedPath)
            }
            continue
        }

        $sourcePath = Resolve-SourceTargetPath -Path $relativePath -Root $SourceRoot
        $destinationPath = Resolve-SourceTargetPath -Path $relativePath -Root $DispatchRoot
        if (-not (Test-PathWithinRoot -Path $sourcePath -Root $SourceRoot) -or -not (Test-PathWithinRoot -Path $destinationPath -Root $DispatchRoot)) {
            throw "未追蹤檔案路徑超出根目錄界線：$relativePath"
        }
        $destinationPath = Resolve-DispatchOutputPath -CandidatePath $destinationPath -SourceRoot '' -ExecutionRoot $DispatchRoot -TargetPath @()
        if (Test-Path -LiteralPath $destinationPath) {
            throw "未追蹤檔案目的路徑已存在，停止避免覆寫：$destinationPath"
        }
        $destinationParent = Split-Path -Parent $destinationPath
        $null = New-DispatchOutputDirectory -Path $destinationParent -SourceRoot $SourceRoot -ExecutionRoot $DispatchRoot -TargetPath @()
        $destinationPath = Resolve-DispatchOutputPath -CandidatePath $destinationPath -SourceRoot '' -ExecutionRoot $DispatchRoot -TargetPath @()
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force:$false
        $copiedFiles.Add($relativePath)
    }

    return [ordered]@{
        TrackedPatchApplied = -not [string]::IsNullOrEmpty($trackedPatch)
        TrackedPatchLength  = $trackedPatch.Length
        UntrackedFiles      = @($untrackedFiles)
        CopiedFiles         = @($copiedFiles.ToArray())
        excludedSecrets     = @($excludedSecrets.ToArray())
    }
}

function Get-DispatchSnapshotPath {
    [CmdletBinding()]
    param([string]$Root, [string]$Path)

    if ([string]::IsNullOrEmpty($Path) -or $Path.Contains('\') -or $Path.Contains(':') -or [IO.Path]::IsPathRooted($Path) -or @($Path.Split('/') | Where-Object { $_ -in @('', '.', '..', '.git') }).Count -gt 0) {
        throw "Baseline 相對路徑異常：$Path"
    }
    $rootPath = Resolve-AbsolutePath $Root
    $current = $rootPath
    foreach ($part in @('') + $Path.Split('/')) {
        if ($part.Length -gt 0) { $current = Join-Path $current $part }
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Baseline 不支援重解析點：$Path" }
        }
    }
    if (-not (Test-PathWithinRoot $current $rootPath)) { throw "Baseline 路徑超出工作樹：$Path" }
    return $current
}

function Get-DispatchWorkingTreeModes {
    [CmdletBinding()]
    param([string]$DispatchRoot)

    $result = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('diff-files', '--raw', '-z', '--')
    $parts = @($result.StdOut.Split([char]0) | Where-Object { $_.Length -gt 0 })
    if (($parts.Count % 2) -ne 0) { throw 'Baseline Git working tree mode 輸出格式異常。' }

    $modes = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    for ($index = 0; $index -lt $parts.Count; $index += 2) {
        $header = $parts[$index]
        $path = $parts[$index + 1]
        if ($header -notmatch '^:(?<oldMode>[0-7]{6}) (?<newMode>[0-7]{6}) (?<oldObject>[0-9a-fA-F]{40,64}) (?<newObject>[0-9a-fA-F]{40,64}) (?<status>[A-Z])$' -or [string]::IsNullOrEmpty($path)) {
            throw 'Baseline Git working tree mode 輸出格式異常。'
        }
        if ($Matches.newMode -in @('100644', '100755')) {
            $modes[$path] = $Matches.newMode
        }
    }

    return $modes
}

function Get-DispatchFileSnapshot {
    [CmdletBinding()]
    param([string]$DispatchRoot, [string]$BaseSha, [string[]]$ApprovedAbsentPath = @(), [switch]$IncludeApprovedAbsentPath)

    if ($BaseSha -notmatch '^[a-fA-F0-9]{7,64}$') { throw 'Baseline baseSha 格式異常。' }
    $paths = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
    $modes = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $tree = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('ls-tree', '-r', '-z', $BaseSha, '--')
    foreach ($entry in $tree.StdOut.Split([char]0)) {
        if ($entry.Length -eq 0) { continue }
        $separator = $entry.IndexOf("`t")
        if ($separator -lt 0) { throw 'Baseline Git tree 輸出格式異常。' }
        $header = $entry.Substring(0, $separator).Split(' ')
        $path = $entry.Substring($separator + 1)
        if ($header.Count -ne 3 -or $header[0] -notin @('100644', '100755') -or $header[1] -ne 'blob') { throw "Baseline 不支援 Git kind：$path" }
        $null = $paths.Add($path)
        $modes[$path] = $header[0]
    }
    $index = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('ls-files', '--stage', '-z')
    foreach ($entry in $index.StdOut.Split([char]0)) {
        if ($entry.Length -eq 0) { continue }
        $separator = $entry.IndexOf("`t")
        if ($separator -lt 0) { throw 'Baseline Git index 輸出格式異常。' }
        $header = $entry.Substring(0, $separator).Split(' ')
        $path = $entry.Substring($separator + 1)
        if ($header.Count -ne 3 -or $header[0] -notin @('100644', '100755') -or $header[2] -ne '0') { throw "Baseline 不支援 Git kind 或未解決 index：$path" }
        $null = $paths.Add($path)
        $modes[$path] = $header[0]
    }
    $workingTreeModes = Get-DispatchWorkingTreeModes -DispatchRoot $DispatchRoot
    $untracked = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('ls-files', '--others', '--exclude-standard', '-z')
    foreach ($path in $untracked.StdOut.Split([char]0)) {
        if ($path.Length -eq 0) { continue }
        $null = $paths.Add($path)
        if (-not $modes.ContainsKey($path)) { $modes[$path] = '100644' }
    }
    foreach ($path in @($ApprovedAbsentPath)) {
        $fullPath = Get-DispatchSnapshotPath -Root $DispatchRoot -Path $path
        if ($IncludeApprovedAbsentPath -or -not (Test-Path -LiteralPath $fullPath)) {
            if (Test-Path -LiteralPath $fullPath -PathType Container) { continue }
            $null = $paths.Add($path)
            if (-not $modes.ContainsKey($path)) { $modes[$path] = '100644' }
        }
    }
    foreach ($path in $paths) {
        $fullPath = Get-DispatchSnapshotPath -Root $DispatchRoot -Path $path
        $exists = Test-Path -LiteralPath $fullPath
        $length = 0L
        $hash = $null
        if ($exists) {
            $item = Get-Item -LiteralPath $fullPath -Force
            if ($item.PSIsContainer) { throw "Baseline 不支援目錄 kind：$path" }
            $length = $item.Length
            $hash = Get-FileSha256 $fullPath
        }
        $gitMode = $modes[$path]
        if ($workingTreeModes.ContainsKey($path)) { $gitMode = $workingTreeModes[$path] }
        [pscustomobject]@{ path = $path; kind = 'file'; exists = [bool]$exists; byte_length = $length; sha256 = $hash; git_mode = $gitMode }
    }
}

function New-DispatchBaseline {
    [CmdletBinding()]
    param(
        [string]$SourceRoot, [string]$DispatchRoot,
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$LineSlug,
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$DispatchSlug,
        [string]$BaseSha,
        [string[]]$TargetPath = @()
    )

    $approvedAbsentPaths = @($TargetPath | ForEach-Object {
        $sourcePath = Resolve-SourceTargetPath -Path $_ -Root $SourceRoot
        Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $sourcePath
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            $relativePath = (Get-RelativePathFromRoot -Path $sourcePath -Root $SourceRoot).Replace('\', '/').TrimEnd([char]'/')
            if (-not [string]::IsNullOrWhiteSpace($relativePath)) { $relativePath }
        }
    })
    $record = [ordered]@{
        schema = 'ai-sessions.dispatch-baseline.v1'
        baseline_id = [guid]::NewGuid().ToString('D')
        line_slug = $LineSlug
        dispatch_slug = $DispatchSlug
        source_root = Resolve-AbsolutePath $SourceRoot
        dispatch_root = Resolve-AbsolutePath $DispatchRoot
        base_sha = $BaseSha
        created_at_utc = [datetime]::UtcNow.ToString('o')
        files = @(Get-DispatchFileSnapshot -DispatchRoot $DispatchRoot -BaseSha $BaseSha -ApprovedAbsentPath $approvedAbsentPaths)
    }
    $directory = Join-Path (Join-Path (Join-Path $record.source_root '.local/ai-sessions/history') $LineSlug) 'baselines'
    $null = New-DispatchOutputDirectory -Path $directory -SourceRoot $SourceRoot -ExecutionRoot $DispatchRoot -TargetPath @()
    $path = Join-Path $directory ($DispatchSlug + '-' + $record.baseline_id + '.json')
    $temporaryPath = Join-Path $directory ([guid]::NewGuid().ToString('D') + '.tmp')
    Write-Utf8NoBom -Path $temporaryPath -Content (($record | ConvertTo-Json -Depth 12) + "`n") -SourceRoot $SourceRoot -ExecutionRoot $DispatchRoot -TargetPath @()
    $temporaryPath = Resolve-DispatchOutputPath -CandidatePath $temporaryPath -SourceRoot $SourceRoot -ExecutionRoot $DispatchRoot -TargetPath @()
    $path = Resolve-DispatchOutputPath -CandidatePath $path -SourceRoot $SourceRoot -ExecutionRoot $DispatchRoot -TargetPath @()
    [IO.File]::Move((ConvertTo-FileSystemApiPath -Path $temporaryPath), (ConvertTo-FileSystemApiPath -Path $path))
    return [pscustomobject]@{ Path = $path; Sha256 = Get-FileSha256 $path }
}

function Read-DispatchBaseline {
    [CmdletBinding()]
    param([string]$Path, [string]$Sha256, [string]$SourceRoot, [string]$DispatchRoot, [string]$LineSlug, [string]$DispatchSlug, [string]$BaseSha)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw '缺少有效 Baseline 路徑或 SHA-256。' }
    $pathValue = Resolve-AbsolutePath $Path
    if ((Get-FileSha256 $pathValue) -ine $Sha256) { throw 'Baseline SHA-256 不一致。' }
    $record = ConvertFrom-DispatchJson -Content (Get-Content -LiteralPath $pathValue -Raw -Encoding UTF8)
    if ($null -eq $record -or $record -isnot [pscustomobject]) { throw 'Baseline 必須為 JSON object。' }
    foreach ($name in @('schema', 'baseline_id', 'line_slug', 'dispatch_slug', 'source_root', 'dispatch_root', 'base_sha', 'created_at_utc')) {
        $property = $record.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($property.Value)) { throw "Baseline 欄位異常：$name" }
    }
    $id = [guid]::Empty
    $created = [datetimeoffset]::MinValue
    if (-not [guid]::TryParseExact($record.baseline_id, 'D', [ref]$id) -or $record.created_at_utc -notmatch '^\d{4}-\d{2}-\d{2}T.*(?:Z|\+00:00)$' -or -not [datetimeoffset]::TryParse($record.created_at_utc, [ref]$created) -or $created.Offset -ne [timespan]::Zero) { throw 'Baseline ID 或 UTC 時間異常。' }
    if ($record.schema -cne 'ai-sessions.dispatch-baseline.v1' -or $record.line_slug -cne $LineSlug -or $record.dispatch_slug -cne $DispatchSlug -or $record.base_sha -cne $BaseSha) { throw 'Baseline schema／line／dispatch／baseSha 不一致。' }
    foreach ($entry in @(@('source_root', $SourceRoot), @('dispatch_root', $DispatchRoot))) {
        if (-not [string]::Equals($record.($entry[0]), (Resolve-AbsolutePath $entry[1]), [StringComparison]::OrdinalIgnoreCase)) { throw 'Baseline roots 不一致。' }
    }
    $directory = Join-Path (Join-Path (Join-Path (Resolve-AbsolutePath $SourceRoot) '.local/ai-sessions/history') $LineSlug) 'baselines'
    $expectedPath = Join-Path $directory ($DispatchSlug + '-' + $record.baseline_id + '.json')
    if (-not [string]::Equals($pathValue, $expectedPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'Baseline 路徑與身分不一致。' }
    $filesProperty = $record.PSObject.Properties['files']
    if ($null -eq $filesProperty -or $filesProperty.Value -isnot [array]) { throw 'Baseline files 必須為陣列。' }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $previousPath = $null
    foreach ($file in $record.files) {
        if ($null -eq $file -or $file -isnot [pscustomobject]) { throw 'Baseline file 必須為 object。' }
        foreach ($name in @('path', 'kind', 'exists', 'byte_length', 'sha256', 'git_mode')) {
            if ($null -eq $file.PSObject.Properties[$name]) { throw "Baseline file 缺少欄位：$name" }
        }
        if ($file.path -isnot [string] -or -not $seen.Add($file.path) -or ($null -ne $previousPath -and [string]::CompareOrdinal($previousPath, $file.path) -ge 0)) { throw 'Baseline file 路徑重複或未排序。' }
        $null = Get-DispatchSnapshotPath -Root $DispatchRoot -Path $file.path
        $previousPath = $file.path
        if ($file.kind -cne 'file' -or $file.exists -isnot [bool] -or $file.git_mode -cnotin @('100644', '100755') -or ($file.byte_length -isnot [int] -and $file.byte_length -isnot [long]) -or $file.byte_length -lt 0) { throw "Baseline file kind／狀態異常：$($file.path)" }
        if ($file.exists) {
            if ($file.sha256 -isnot [string] -or $file.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Baseline file hash 異常：$($file.path)" }
        }
        elseif ($null -ne $file.sha256 -or $file.byte_length -ne 0) { throw "Baseline absent 欄位異常：$($file.path)" }
    }
    return $record
}

function Get-DispatchIncrementalChanges {
    [CmdletBinding()]
    param([psobject]$Baseline, [string]$DispatchRoot)

    $before = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $after = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $paths = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
    foreach ($file in $Baseline.files) { $before[$file.path] = $file; $null = $paths.Add($file.path) }
    $approvedAbsentPaths = @($Baseline.files | Where-Object { -not $_.exists } | ForEach-Object { [string]$_.path })
    foreach ($file in @(Get-DispatchFileSnapshot -DispatchRoot $DispatchRoot -BaseSha $Baseline.base_sha -ApprovedAbsentPath $approvedAbsentPaths -IncludeApprovedAbsentPath)) { $after[$file.path] = $file; $null = $paths.Add($file.path) }
    foreach ($path in $paths) {
        $old = if ($before.ContainsKey($path)) { $before[$path] } else { $null }
        $new = if ($after.ContainsKey($path)) { $after[$path] } else { $null }
        $oldExists = $null -ne $old -and $old.exists
        $newExists = $null -ne $new -and $new.exists
        if ($oldExists -ne $newExists -or ($oldExists -and ($old.kind -cne $new.kind -or $old.git_mode -cne $new.git_mode -or $old.byte_length -ne $new.byte_length -or $old.sha256 -ine $new.sha256))) { $path }
    }
}

function Resolve-DispatchBaselineBinding {
    [CmdletBinding()]
    param([psobject]$Preflight, [string]$SourceRoot, [string]$DispatchRoot, [string]$LineSlug, [string]$DispatchSlug, [string]$BaseSha, [string]$Path, [string]$Sha256)

    if ($null -ne $Preflight) {
        foreach ($entry in @(@('sourceRoot', $SourceRoot), @('executionRoot', $DispatchRoot), @('dispatchRoot', $DispatchRoot))) {
            if (-not [string]::Equals((Get-RequiredPreflightProperty $Preflight $entry[0]), (Resolve-AbsolutePath $entry[1]), [StringComparison]::OrdinalIgnoreCase)) { throw 'Baseline Preflight roots 不一致。' }
        }
        foreach ($entry in @(@('lineSlug', $LineSlug), @('dispatchSlug', $DispatchSlug), @('baseSha', $BaseSha))) {
            if ((Get-RequiredPreflightProperty $Preflight $entry[0]) -cne $entry[1]) { throw 'Baseline Preflight 身分或 baseSha 不一致。' }
        }
        $boundPath = Get-RequiredPreflightProperty $Preflight 'baselinePath'
        $boundHash = Get-RequiredPreflightProperty $Preflight 'baselineSha256'
        if ((-not [string]::IsNullOrWhiteSpace($Path) -and -not [string]::Equals((Resolve-AbsolutePath $Path), $boundPath, [StringComparison]::OrdinalIgnoreCase)) -or (-not [string]::IsNullOrWhiteSpace($Sha256) -and $Sha256 -ine $boundHash)) { throw 'Baseline 顯式輸入與 Preflight 不一致。' }
        $Path = $boundPath
        $Sha256 = $boundHash
    }
    $record = Read-DispatchBaseline -Path $Path -Sha256 $Sha256 -SourceRoot $SourceRoot -DispatchRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -BaseSha $BaseSha
    return [pscustomobject]@{ Path = Resolve-AbsolutePath $Path; Sha256 = $Sha256; Record = $record }
}
