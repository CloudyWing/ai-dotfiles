#Requires -Version 7.0
# 權限設定參數、exec 引數組成、MXC 偵測與 codex 執行檔解析。依賴 00-common.ps1、20-process.ps1。

$script:RunPermissionProfileName = 'dispatch_review'
$script:RunGlobScanMaxDepth = 6

function Get-RunCodexPath {
    [CmdletBinding()]
    param(
        [string]$ConfiguredPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        if (-not [IO.Path]::IsPathFullyQualified($ConfiguredPath) -or -not [IO.File]::Exists($ConfiguredPath)) {
            throw (New-RunError -Code 'RunCodexNotFound' -Message ('codex 執行檔不存在：' + $ConfiguredPath) -ExitCode 3)
        }
        return $ConfiguredPath
    }
    $name = if ([OperatingSystem]::IsWindows()) { 'codex.cmd' } else { 'codex' }
    $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        throw (New-RunError -Code 'RunCodexNotFound' -Message ('PATH 上找不到 ' + $name + '。') -ExitCode 3)
    }
    return [string]$command.Source
}

function Test-RunMxc {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CodexPath,

        [Parameter(Mandatory)]
        [string]$CodexHome,

        [ValidateRange(1, 600)]
        [int]$TimeoutSeconds = 120
    )

    # 以 codex sandbox 執行一個無害命令偵測 MXC，不呼叫服務端。stdout 含 MXC_OK 且結束碼 0 才算可用。
    $arguments = @('-c', 'windows.sandbox="mxc"', 'sandbox', '--include-managed-config', '--permission-profile', ':workspace', '--', 'cmd.exe', '/d', '/c', 'echo', 'MXC_OK')
    $startInfo = New-RunProcessStartInfo -FileName $CodexPath -Argument $arguments -WorkingDirectory ([IO.Path]::GetTempPath())
    $null = Remove-RunSecretEnvironmentVariable -StartInfo $startInfo
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $CodexHome
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        try {
            $null = Invoke-RunWithoutStdHandleInheritance -ScriptBlock { $process.Start() }
        }
        catch {
            return $false
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { $null = $_ }
            return $false
        }
        $process.WaitForExit()
        # 孫行程若握著輸出管線，Result 會無限期阻塞；最多再等 5 秒，取不到輸出視為探針失敗。
        if (-not $stdoutTask.Wait(5000)) { return $false }
        return ($process.ExitCode -eq 0) -and $stdoutTask.Result.Contains('MXC_OK')
    }
    finally {
        $process.Dispose()
    }
}

function Assert-RunPermissionArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Argument
    )

    # 同時傳入 --sandbox 會改用舊式沙盒設定，使權限設定失效。
    foreach ($item in $Argument) {
        if ($item -ceq '--sandbox' -or $item -ceq '-s' -or $item.StartsWith('--sandbox=', [StringComparison]::Ordinal)) {
            throw (New-RunError -Code 'RunPermissionArgumentInvalid' -Message '參數含 --sandbox，會改用舊式沙盒設定。' -ExitCode 3)
        }
    }
}

function Get-RunProjectDocFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StartDirectory
    )

    # Codex 建立 session 時從工作目錄往上找專案說明檔（AGENTS.override.md、AGENTS.md），到含 .git 的專案根目錄為止；
    # 找不到 .git 時只看工作目錄本身。讀取這些檔案受權限設定限制，因此只開放實際存在的那幾個檔案為 read。
    # 工作目錄本身（輸出目錄）已是可讀可寫，不列入。
    $separators = [char[]]@('\', '/')
    $start = [IO.Path]::GetFullPath($StartDirectory).TrimEnd($separators)
    $chain = New-Object 'System.Collections.Generic.List[string]'
    $current = $start
    $found = $false
    while ($true) {
        $chain.Add($current)
        if (Test-Path -LiteralPath (Join-Path $current '.git')) { $found = $true; break }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrEmpty($parent) -or $parent.Length -le 2) { break }
        $current = $parent.TrimEnd($separators)
    }
    $files = New-Object 'System.Collections.Generic.List[string]'
    if ($found) {
        foreach ($directory in @($chain | Select-Object -Skip 1)) {
            foreach ($name in @('AGENTS.override.md', 'AGENTS.md')) {
                $candidate = Join-Path $directory $name
                if ([IO.File]::Exists($candidate)) { $files.Add($candidate) }
            }
        }
    }
    return [string[]]@($files.ToArray())
}

function Get-RunPermissionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$OutputDirectory,

        [string]$AiAgentsRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ai-agents'),

        # 該線的報告目錄。審查第 2 輪以上要讀前輪報告，因此列入可讀範圍。
        [string]$ReportLineRoot,

        # 依 task_type 追加的可讀根目錄，例如影像產生時選定帳號的 generated_images。
        [AllowEmptyCollection()]
        [string[]]$ExtraReadRoot = @(),

        # 不開放工作目錄：可讀與可寫根目錄都只有輸出目錄，其餘路徑參數不使用。evidence-only 的顧問使用，--cd 同樣指向輸出目錄。
        [switch]$OutputOnly,

        # 以檔案單位開放唯讀的檔案（例如測試環境資料檔，位於可讀根目錄之外）。不開放其所在目錄。
        [AllowEmptyCollection()]
        [string[]]$ReadFile = @()
    )

    $separators = [char[]]@('\', '/')
    $normalized = @()
    $pathList = @($ExecutionRoot, $AiAgentsRoot, $OutputDirectory)
    if (-not [string]::IsNullOrWhiteSpace($ReportLineRoot)) { $pathList += $ReportLineRoot }
    $pathList += @($ExtraReadRoot | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($OutputOnly) { $pathList = @($OutputDirectory, $OutputDirectory, $OutputDirectory) }
    foreach ($path in $pathList) {
        if (-not [IO.Path]::IsPathFullyQualified($path)) {
            throw (New-RunError -Code 'RunPermissionArgumentInvalid' -Message ('權限設定的路徑必須是絕對路徑：' + $path) -ExitCode 3)
        }
        $full = [IO.Path]::GetFullPath($path).TrimEnd($separators)
        if ($full.Length -le 2 -or $full -match "['`"\x00-\x1f]") {
            throw (New-RunError -Code 'RunPermissionArgumentInvalid' -Message ('權限設定不接受磁碟根目錄或含引號、控制字元的路徑：' + $path) -ExitCode 3)
        }
        $normalized += $full
    }
    # 路徑相同（不分大小寫）時只保留一份，避免 filesystem 內出現重複的 TOML 鍵。
    $readRoots = New-Object 'System.Collections.Generic.List[string]'
    # 第 3 項是輸出目錄（可寫），其餘都是可讀根目錄。
    $candidates = @($normalized[0], $normalized[1])
    if ($normalized.Count -gt 3) { $candidates += @($normalized[3..($normalized.Count - 1)]) }
    if ($OutputOnly) { $candidates = @($normalized[2]) }
    foreach ($candidate in $candidates) {
        if (@($readRoots | Where-Object { [string]::Equals($_, $candidate, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) { $readRoots.Add($candidate) }
    }
    $plan = [pscustomobject]@{
        name = $script:RunPermissionProfileName
        read_roots = [string[]]@($readRoots.ToArray())
        write_roots = [string[]]@($normalized[2])
        deny_patterns = [string[]]@(Get-RunDenyPattern)
        glob_scan_max_depth = $script:RunGlobScanMaxDepth
    }
    # OutputOnly 只多開放 Codex 啟動時會載入的專案說明檔（檔案單位的 read），不開放其所在目錄。其他類型的計畫不含此欄位。
    $explicitReadFiles = New-Object 'System.Collections.Generic.List[string]'
    foreach ($file in @($ReadFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if (-not [IO.Path]::IsPathFullyQualified($file)) {
            throw (New-RunError -Code 'RunPermissionArgumentInvalid' -Message ('權限設定的路徑必須是絕對路徑：' + $file) -ExitCode 3)
        }
        $fullFile = [IO.Path]::GetFullPath($file)
        if ($fullFile -match "['`"\x00-\x1f]") {
            throw (New-RunError -Code 'RunPermissionArgumentInvalid' -Message ('權限設定不接受含引號、控制字元的路徑：' + $file) -ExitCode 3)
        }
        $explicitReadFiles.Add($fullFile)
    }
    # 不含 read_files 欄位的計畫維持原形（只有 OutputOnly 或有明確檔案時才加）。
    if ($OutputOnly -or $explicitReadFiles.Count -gt 0) {
        $readFiles = New-Object 'System.Collections.Generic.List[string]'
        if ($OutputOnly) { foreach ($doc in @(Get-RunProjectDocFile -StartDirectory $OutputDirectory)) { $readFiles.Add($doc) } }
        foreach ($fullFile in $explicitReadFiles) {
            if (@($readFiles | Where-Object { [string]::Equals($_, $fullFile, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) { $readFiles.Add($fullFile) }
        }
        $plan | Add-Member -NotePropertyName read_files -NotePropertyValue ([string[]]@($readFiles.ToArray()))
    }
    return $plan
}

function New-RunPermissionArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$OutputDirectory,

        [string]$AiAgentsRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ai-agents'),

        [string]$ReportLineRoot,

        [AllowEmptyCollection()]
        [string[]]$ExtraReadRoot = @(),

        [switch]$OutputOnly,

        [AllowEmptyCollection()]
        [string[]]$ReadFile = @()
    )

    # 路徑以 TOML literal 鍵（單引號）表達，避免反斜線與 cmd.exe 的引號轉手問題。
    # 禁止讀取的樣式放在 :workspace_roots 之下，相對於 --cd 指定的工作目錄，沙盒行程啟動時列舉一次。
    # 工作目錄之外的可讀根目錄（~\.ai-agents、report_line_root、ExtraReadRoot）以「該目錄為鍵的子表」表達：「.」為 read，並附同一組 deny 樣式。
    # 子表寫法經 codex sandbox 實測可使這些目錄內的機密樣式檔被拒；只給 "read" 字串時機密樣式檔可讀。
    $plan = Get-RunPermissionPlan -ExecutionRoot $ExecutionRoot -OutputDirectory $OutputDirectory -AiAgentsRoot $AiAgentsRoot -ReportLineRoot $ReportLineRoot -ExtraReadRoot $ExtraReadRoot -OutputOnly:$OutputOnly -ReadFile $ReadFile
    $entries = New-Object 'System.Collections.Generic.List[string]'
    $entries.Add('":minimal"="read"')
    $entries.Add('glob_scan_max_depth=' + $plan.glob_scan_max_depth)
    $denyEntries = @($plan.deny_patterns | ForEach-Object { '"**/' + $_ + '"="deny"' })
    $emittedRoots = New-Object 'System.Collections.Generic.List[string]'
    # OutputOnly 的可讀根目錄即輸出目錄，由下方的 write 項涵蓋，不另列 read 項（同一路徑不可有兩個 TOML 鍵）。
    foreach ($path in @($plan.read_roots | Where-Object { -not $OutputOnly })) {
        # 在已列出根目錄之下的路徑已被涵蓋，不重複加。執行目錄（第一項）一律列出。
        if (@($emittedRoots | Where-Object { Test-RunPathUnder -Path $path -Root $_ }).Count -gt 0) { continue }
        if ($emittedRoots.Count -eq 0) { $entries.Add("'" + $path + "'=`"read`"") }
        else { $entries.Add("'" + $path + "'={`".`"=`"read`", " + ($denyEntries -join ', ') + '}') }
        $emittedRoots.Add($path)
    }
    foreach ($path in $plan.write_roots) { $entries.Add("'" + $path + "'=`"write`"") }
    if ($null -ne $plan.PSObject.Properties['read_files']) { foreach ($file in @($plan.read_files)) { $entries.Add("'" + $file + "'=`"read`"") } }
    $workspaceEntries = New-Object 'System.Collections.Generic.List[string]'
    $workspaceEntries.Add('"."="read"')
    foreach ($denyEntry in $denyEntries) { $workspaceEntries.Add($denyEntry) }
    $entries.Add('":workspace_roots"={' + ($workspaceEntries -join ', ') + '}')
    $filesystem = '{' + ($entries -join ', ') + '}'

    $arguments = [string[]]@(
        '-c', 'windows.sandbox="mxc"',
        '-c', ('default_permissions="' + $plan.name + '"'),
        '-c', ('permissions.' + $plan.name + '.filesystem=' + $filesystem)
    )
    Assert-RunPermissionArgument -Argument $arguments
    return $arguments
}

function New-RunExecArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$Profile,

        [Parameter(Mandatory)]
        [string]$OutputDirectory,

        [Parameter(Mandatory)]
        [string]$LastMessagePath,

        [Parameter(Mandatory)]
        [bool]$IsGitRepository,

        [string]$AiAgentsRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ai-agents'),

        [string]$ReportLineRoot,

        # 備援 model。提供時以 -c model= 覆寫檔位設定檔的 model，其餘設定沿用檔位。
        [string]$ModelOverride,

        [AllowEmptyCollection()]
        [string[]]$ExtraReadRoot = @(),

        # 加 --search（Codex 的官方查證工具，不開 shell 網路）。屬父層選項，放在 exec 之前。
        [switch]$Search,

        # 不開放工作目錄，--cd 指向輸出目錄（ExecutionRoot 參數請傳輸出目錄）。
        [switch]$OutputOnly,

        [AllowEmptyCollection()]
        [string[]]$ReadFile = @()
    )

    # 父層選項（--cd、--profile、-c、--search）在 exec 之前；exec 之後為 --json、--output-last-message，prompt 以 - 從 stdin 讀入。
    $arguments = New-Object 'System.Collections.Generic.List[string]'
    $arguments.Add('--cd')
    $arguments.Add($ExecutionRoot)
    $arguments.Add('--profile')
    $arguments.Add($Profile)
    if (-not [string]::IsNullOrWhiteSpace($ModelOverride)) {
        if ($ModelOverride -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            throw (New-RunError -Code 'RunModelOverrideInvalid' -Message ('備援 model 名稱不合法：' + $ModelOverride) -ExitCode 2)
        }
        $arguments.Add('-c')
        $arguments.Add('model="' + $ModelOverride + '"')
    }
    foreach ($item in (New-RunPermissionArgument -ExecutionRoot $ExecutionRoot -OutputDirectory $OutputDirectory -AiAgentsRoot $AiAgentsRoot -ReportLineRoot $ReportLineRoot -ExtraReadRoot $ExtraReadRoot -OutputOnly:$OutputOnly -ReadFile $ReadFile)) { $arguments.Add($item) }
    if ($Search) { $arguments.Add('--search') }
    $arguments.Add('exec')
    if (-not $IsGitRepository) { $arguments.Add('--skip-git-repo-check') }
    $arguments.Add('--json')
    $arguments.Add('--output-last-message')
    $arguments.Add($LastMessagePath)
    $arguments.Add('-')
    $result = [string[]]@($arguments.ToArray())
    Assert-RunPermissionArgument -Argument $result
    return $result
}
