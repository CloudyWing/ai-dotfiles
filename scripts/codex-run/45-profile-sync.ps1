#Requires -Version 7.0
# Codex 檔位設定檔：由執行者登錄表產生、與帳號目錄比對、建立與檢查連結。
# 不依賴其他 codex-run 模組。由 Invoke-CodexRun.ps1 依檔名排序載入，也由 .githooks\Update-CodexProfiles.ps1、
# Setup-AIGlobalConfig.ps1 與 New-CodexDispatchAccount.ps1 直接 dot-source。
# 登錄表的讀取與結構驗證由本檔載入的 scripts\lib\executor-registry.ps1 提供，與選派入口 Select-DispatchExecutor.ps1 共用同一組函式。

$script:CodexProfileGeneratedRelativePath = 'scripts\codex-profiles'
$script:CodexProfileRegistryRelativePath = 'scripts\dispatch\executor-registry.json'

function New-CodexProfileError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message
    )

    $exception = New-Object System.InvalidOperationException -ArgumentList @($Code + '：' + $Message)
    $exception.Data['Code'] = $Code
    return $exception
}

# 以本檔所在位置為基準載入登錄表共用函式檔；不存在或無法解析時以 CodexProfileSpecInvalid 失敗，不繼續載入。
$script:CodexProfileRegistryLibraryPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\lib\executor-registry.ps1'))
try {
    if (-not [IO.File]::Exists($script:CodexProfileRegistryLibraryPath)) { throw ('檔案不存在：' + $script:CodexProfileRegistryLibraryPath) }
    . $script:CodexProfileRegistryLibraryPath
}
catch {
    throw (New-CodexProfileError -Code 'CodexProfileSpecInvalid' -Message ('無法載入登錄表共用函式檔 ' + $script:CodexProfileRegistryLibraryPath + '：' + $_.Exception.Message))
}

function ConvertTo-CodexProfileQuoted {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    # PowerShell 單引號字串，供輸出可貼上的修正命令。
    return "'" + $Text.Replace("'", "''") + "'"
}

function Get-CodexProfileRepoRoot {
    [CmdletBinding()]
    param()

    # 本檔位於 <repo>\scripts\codex-run。
    return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}

function Get-CodexProfileRegistryPath {
    [CmdletBinding()]
    param([string]$RepoRoot = (Get-CodexProfileRepoRoot))

    return (Join-Path $RepoRoot $script:CodexProfileRegistryRelativePath)
}

function Get-CodexProfileGeneratedDirectory {
    [CmdletBinding()]
    param([string]$RepoRoot = (Get-CodexProfileRepoRoot))

    return (Join-Path $RepoRoot $script:CodexProfileGeneratedRelativePath)
}

function Get-CodexProfileFileName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Profile)

    return ($Profile + '.config.toml')
}

function Read-CodexProfileRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RegistryPath)

    # 以共用函式 Read-ExecutorRegistry 讀取並驗證登錄表（與選派入口同一份驗證）。
    # 檔案不存在、不是 JSON 或結構不合法時以 CodexProfileSpecInvalid 失敗，訊息附共用驗證的錯誤碼與原因。
    try {
        return (Read-ExecutorRegistry -Path $RegistryPath)
    }
    catch {
        if (-not $_.Exception.Data.Contains('Code')) { throw }
        throw (New-CodexProfileError -Code 'CodexProfileSpecInvalid' -Message ('登錄表驗證失敗：' + $_.Exception.Message))
    }
}

function Get-CodexRetiredProfileName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RegistryPath)

    # 已退役的檔位名稱只存在登錄表的 retiredProfiles。
    return [string[]]@((Read-CodexProfileRegistry -RegistryPath $RegistryPath).RetiredProfiles)
}

function Get-CodexProfileName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RegistryPath)

    # 登錄表內 Codex 執行者的檔位名稱（派遣檔的檔位名稱檢查用），依 order 排序。
    $registry = Read-CodexProfileRegistry -RegistryPath $RegistryPath
    return [string[]]@($registry.Executors | Where-Object { $_.Platform -ceq 'codex' } | ForEach-Object { $_.Profile })
}

function Read-CodexProfileSpec {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RegistryPath)

    # 回傳每個 Codex 執行者的檔位規格（依 order 排序）。資料取自已驗證的登錄表物件，欄位缺漏或值不合法由共用驗證失敗。
    $registry = Read-CodexProfileRegistry -RegistryPath $RegistryPath
    $specs = foreach ($executor in @($registry.Executors | Where-Object { $_.Platform -ceq 'codex' })) {
        [pscustomobject]@{
            ExecutorId = [string]$executor.Id
            Profile = [string]$executor.Profile
            FileName = (Get-CodexProfileFileName -Profile ([string]$executor.Profile))
            Model = [string]$executor.ProfileSettings['model']
            Effort = [string]$executor.ProfileSettings['effort']
            SubagentModel = [string]$executor.ProfileSettings['subagentModel']
            SubagentEffort = [string]$executor.ProfileSettings['subagentEffort']
        }
    }
    if (@($specs).Count -eq 0) {
        throw (New-CodexProfileError -Code 'CodexProfileSpecInvalid' -Message '登錄表沒有任何 platform 為 codex 的執行者。')
    }
    return @($specs)
}

function Get-CodexProfileExpectedContent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Spec)

    # 決定性內容：不含時間、機器路徑或使用者名稱。換行為 LF，寫檔時由 ConvertTo-CodexProfileFileBytes 轉為 CRLF。
    foreach ($value in @($Spec.ExecutorId, $Spec.Model, $Spec.Effort, $Spec.SubagentModel, $Spec.SubagentEffort)) {
        if ($value -isnot [string] -or $value -cmatch '[\r\n]') { throw (New-CodexProfileError -Code 'CodexProfileSpecInvalid' -Message '產生檔內容的欄位值不得為空或含換行。') }
    }
    $lines = @(
        ('# 此檔由 ' + ($script:CodexProfileRegistryRelativePath.Replace('\', '/')) + ' 的執行者 ' + $Spec.ExecutorId + ' 產生，請勿手動編輯；修改請改登錄表。')
        ('model = "' + $Spec.Model + '"')
        ('model_reasoning_effort = "' + $Spec.Effort + '"')
        ''
        '[agents]'
        'enabled = true'
        ('default_subagent_model = "' + $Spec.SubagentModel + '"')
        ('default_subagent_reasoning_effort = "' + $Spec.SubagentEffort + '"')
    )
    return (($lines -join "`n") + "`n")
}

function ConvertTo-CodexProfileFileBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)

    # UTF-8 無 BOM、CRLF，與 .gitattributes 的 eol=crlf 檢出結果一致。
    $normalized = $Text.Replace("`r`n", "`n").Replace("`n", "`r`n")
    return (New-Object System.Text.UTF8Encoding -ArgumentList @($false)).GetBytes($normalized)
}

function ConvertTo-CodexProfileNormalizedText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $text = (New-Object System.Text.UTF8Encoding -ArgumentList @($false)).GetString($Bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return $text.Replace("`r`n", "`n")
}

function Read-CodexProfileFileText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    # 讀不到（不存在、斷鏈、被鎖）回傳 $null；比對時 CRLF 與 LF 視為相同。
    try {
        if (-not [IO.File]::Exists($Path)) { return $null }
        return (ConvertTo-CodexProfileNormalizedText -Bytes ([IO.File]::ReadAllBytes($Path)))
    }
    catch { return $null }
}

function Sync-CodexProfileGeneratedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [switch]$CheckOnly
    )

    # 依登錄表寫出（或只檢查）每個檔位的產生檔，並移除輸出目錄內登錄表未列出的 *.config.toml。
    # 內容未變時不改檔。回傳 Changes 陣列，每項含 path 與 action（created、updated、removed）。
    $specs = @(Read-CodexProfileSpec -RegistryPath $RegistryPath)
    $changes = New-Object 'System.Collections.Generic.List[object]'
    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        if (-not $CheckOnly) { $null = New-Item -ItemType Directory -Path $OutputDirectory -Force }
    }
    foreach ($spec in $specs) {
        $path = Join-Path $OutputDirectory $spec.FileName
        $bytes = ConvertTo-CodexProfileFileBytes -Text (Get-CodexProfileExpectedContent -Spec $spec)
        $exists = [IO.File]::Exists($path)
        if ($exists -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ceq [Convert]::ToBase64String($bytes)) { continue }
        $changes.Add([pscustomobject]@{ path = $path; action = $(if ($exists) { 'updated' } else { 'created' }) })
        if (-not $CheckOnly) { [IO.File]::WriteAllBytes($path, $bytes) }
    }
    if (Test-Path -LiteralPath $OutputDirectory -PathType Container) {
        $expectedNames = @($specs | ForEach-Object { $_.FileName })
        foreach ($file in @(Get-ChildItem -LiteralPath $OutputDirectory -Filter '*.config.toml' -File)) {
            if ($expectedNames -ccontains $file.Name) { continue }
            $changes.Add([pscustomobject]@{ path = $file.FullName; action = 'removed' })
            if (-not $CheckOnly) { Remove-Item -LiteralPath $file.FullName -Force }
        }
    }
    return @($changes.ToArray())
}

function Get-CodexProfileMainCheckoutRoot {
    [CmdletBinding()]
    param([string]$RepoRoot = (Get-CodexProfileRepoRoot))

    # 主 checkout 根目錄：帳號目錄的連結一律指向主 checkout 的產生檔，不指向線工作樹。
    # 以 git common dir 的上一層取得；解不出時回傳 RepoRoot。
    try {
        $output = @(& git -C $RepoRoot rev-parse --path-format=absolute --git-common-dir 2>$null)
        if ($LASTEXITCODE -eq 0 -and $output.Count -gt 0) {
            $commonDirectory = ([string]$output[0]).Trim()
            if ((Split-Path -Leaf $commonDirectory) -ceq '.git') { return [IO.Path]::GetFullPath((Split-Path -Parent $commonDirectory)) }
        }
    }
    catch { $null = $_ }
    return $RepoRoot
}


function Get-CodexProfileLinkState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LinkPath,
        [Parameter(Mandatory)][string]$TargetPath
    )

    # 唯讀。state 為 missing（不存在）、ok（指向預期目標的 Symbolic Link）、wrong-target（連結但類型或目標不符）、
    # not-link（一般檔案或目錄）。fix_commands 是可整行貼到 pwsh 執行的命令，fix_note 是命令之外的說明；本函式不改任何檔案。
    $quotedLink = ConvertTo-CodexProfileQuoted -Text $LinkPath
    $quotedTarget = ConvertTo-CodexProfileQuoted -Text $TargetPath
    $createCommand = 'New-Item -ItemType SymbolicLink -Path ' + $quotedLink + ' -Target ' + $quotedTarget
    $createNote = '建立 Symbolic Link 需要系統管理員身分的 pwsh。'
    $item = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
    $state = 'missing'
    $actual = $null
    $kind = $null
    $commands = @($createCommand)
    $note = $createNote
    if ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $kind = [string]$item.LinkType
            $actual = (@($item.Target) -join '')
            $resolved = $null
            if ($kind -ceq 'SymbolicLink' -and -not [string]::IsNullOrWhiteSpace($actual)) {
                $candidate = $actual
                if (-not [IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path (Split-Path -Parent $LinkPath) $candidate }
                $resolved = [IO.Path]::GetFullPath($candidate)
            }
            if ($null -ne $resolved -and [string]::Equals($resolved, [IO.Path]::GetFullPath($TargetPath), [StringComparison]::OrdinalIgnoreCase)) {
                $state = 'ok'
                $commands = @()
                $note = $null
            }
            else {
                $state = 'wrong-target'
                $commands = @(('Remove-Item -LiteralPath ' + $quotedLink), $createCommand)
                $note = 'Remove-Item 只移除連結本身。' + $createNote
            }
        }
        else {
            $state = 'not-link'
            $kind = if ($item.PSIsContainer) { 'Directory' } else { 'File' }
            $commands = @(('Move-Item -LiteralPath ' + $quotedLink + ' -Destination ' + (ConvertTo-CodexProfileQuoted -Text ($LinkPath + '.bak'))), $createCommand)
            $note = '先確認該' + $(if ($item.PSIsContainer) { '目錄' } else { '檔案' }) + '內容不需保留；Move-Item 只改名不刪除。' + $createNote
        }
    }
    return [pscustomobject]@{
        state = $state
        path = $LinkPath
        expected_target = $TargetPath
        actual_target = $actual
        kind = $kind
        fix_commands = [string[]]$commands
        fix_note = $note
    }
}


function Format-CodexProfileFixLine {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$Command = @(),
        [AllowNull()][string]$Note
    )

    # 可整段貼到 pwsh 的行：說明以 # 開頭成為註解，每個命令各自一行。
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($Note)) { $lines.Add('# ' + $Note) }
    foreach ($commandLine in @($Command)) { $lines.Add($commandLine) }
    return @($lines.ToArray())
}

function Get-CodexProfileAccountState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccountHome,
        [Parameter(Mandatory)][string]$ProfileDirectory,
        [Parameter(Mandatory)][object[]]$Spec
    )

    # 比對現況（唯讀）：回傳帳號目錄內每個檔位檔對 repo 產生檔的連結狀態。
    $states = foreach ($item in $Spec) {
        $state = Get-CodexProfileLinkState -LinkPath (Join-Path $AccountHome $item.FileName) -TargetPath (Join-Path $ProfileDirectory $item.FileName)
        $state | Add-Member -NotePropertyName profile -NotePropertyValue $item.Profile -PassThru
    }
    return @($states)
}

function New-CodexProfileLink {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$LinkPath,
        [Parameter(Mandatory)][string]$TargetPath
    )

    # 只在 LinkPath 不存在時建立 Symbolic Link，從不覆蓋既有檔案或連結。回傳建立前的狀態物件加 action。
    $before = Get-CodexProfileLinkState -LinkPath $LinkPath -TargetPath $TargetPath
    $action = 'ok'
    if ($before.state -ceq 'missing') {
        if (-not [IO.File]::Exists($TargetPath)) {
            $action = 'target-missing'
        }
        elseif ($PSCmdlet.ShouldProcess($LinkPath, '建立 Symbolic Link')) {
            try {
                $null = New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath -ErrorAction Stop
                $action = 'created'
            }
            catch {
                $action = 'create-failed'
                $before | Add-Member -NotePropertyName error -NotePropertyValue $_.Exception.Message
            }
        }
        else { $action = 'would-create' }
    }
    elseif ($before.state -cne 'ok') { $action = 'blocked' }
    $before | Add-Member -NotePropertyName action -NotePropertyValue $action -Force
    return $before
}

function New-CodexProfileAccountLink {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$AccountHome,
        [Parameter(Mandatory)][string]$ProfileDirectory,
        [Parameter(Mandatory)][object[]]$Spec
    )

    # 建立缺少的連結，其餘（已正確、被擋）只回報。action：ok、created、would-create、blocked、target-missing、create-failed。
    $results = foreach ($item in $Spec) {
        $result = New-CodexProfileLink -LinkPath (Join-Path $AccountHome $item.FileName) -TargetPath (Join-Path $ProfileDirectory $item.FileName) -WhatIf:$WhatIfPreference
        $result | Add-Member -NotePropertyName profile -NotePropertyValue $item.Profile -PassThru
    }
    return @($results)
}

function Get-CodexProfileResidue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RetiredName
    )

    # 目錄內已退役的檔位設定檔（含連結）。名單由呼叫端取自登錄表 retiredProfiles。只列出，不刪除。
    $found = foreach ($name in $RetiredName) {
        $path = Join-Path $Directory ($name + '.config.toml')
        if ($null -ne (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue)) { $path }
    }
    return @($found)
}

function Test-CodexProfileConsistency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][string]$GeneratedDirectory,
        [Parameter(Mandatory)][string[]]$AccountHome,
        [Parameter(Mandatory)][string]$Profile,
        [string]$TreeRegistryPath
    )

    # 唯讀。檢查 repo 產生檔是否等於登錄表預期內容，以及每個帳號目錄的該檔位檔內容是否等於 repo 產生檔，
    # 帳號目錄的檔位檔必須是指向該產生檔的 Symbolic Link（一般檔案即使內容相同也判不一致，不允許單機覆寫）。repo 指主 checkout（連結的目標所在）。
    # 指定 TreeRegistryPath（入口所在工作樹的登錄表，與主 checkout 不同時）時，另確認該登錄表此檔位的設定已落地到主 checkout 的產生檔。
    # 回傳 findings，每項含 code、path、detail、fix_commands、fix_note。沒有不一致時回傳空陣列。
    $findings = New-Object 'System.Collections.Generic.List[object]'
    $specs = @(Read-CodexProfileSpec -RegistryPath $RegistryPath)
    $spec = @($specs | Where-Object { $_.Profile -ceq $Profile })
    if ($spec.Count -eq 0) {
        $findings.Add([pscustomobject]@{ code = 'ProfileNotInRegistry'; path = $RegistryPath; detail = ('登錄表沒有檔位 ' + $Profile); fix_commands = [string[]]@(); fix_note = '改用登錄表內已有的檔位，或在登錄表新增該檔位的執行者。' })
        return @($findings.ToArray())
    }
    $spec = $spec[0]
    $hookPath = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $RegistryPath))) '.githooks\Update-CodexProfiles.ps1'
    $hookCommands = [string[]]@('pwsh -NoProfile -File ' + (ConvertTo-CodexProfileQuoted -Text $hookPath))
    $generatedPath = Join-Path $GeneratedDirectory $spec.FileName
    $generatedText = Read-CodexProfileFileText -Path $generatedPath
    $expectedText = Get-CodexProfileExpectedContent -Spec $spec
    if ($null -eq $generatedText) {
        $findings.Add([pscustomobject]@{ code = 'GeneratedMissing'; path = $generatedPath; detail = 'repo 產生檔不存在。'; fix_commands = $hookCommands; fix_note = '在登錄表所在的 repo 重新產生，並隨登錄表一起 commit。' })
        return @($findings.ToArray())
    }
    if ($generatedText -cne $expectedText) {
        $findings.Add([pscustomobject]@{ code = 'GeneratedStale'; path = $generatedPath; detail = 'repo 產生檔與登錄表預期內容不同。'; fix_commands = $hookCommands; fix_note = '重新產生後隨登錄表一起 commit。' })
    }
    if (-not [string]::IsNullOrWhiteSpace($TreeRegistryPath) -and -not [string]::Equals([IO.Path]::GetFullPath($TreeRegistryPath), [IO.Path]::GetFullPath($RegistryPath), [StringComparison]::OrdinalIgnoreCase)) {
        try {
            $treeSpec = @(Read-CodexProfileSpec -RegistryPath $TreeRegistryPath | Where-Object { $_.Profile -ceq $Profile })
            if ($treeSpec.Count -eq 0) {
                $findings.Add([pscustomobject]@{ code = 'TreeRegistryNotLanded'; path = $TreeRegistryPath; detail = ('此工作樹的登錄表有檔位設定與主 checkout 不同：工作樹登錄表沒有檔位 ' + $Profile + '，登錄表變更尚未落地到主 checkout。'); fix_commands = [string[]]@(); fix_note = '先把工作樹的登錄表與產生檔落地到主 checkout，或還原工作樹的登錄表後重試。' })
            }
            elseif ((Get-CodexProfileExpectedContent -Spec $treeSpec[0]) -cne $generatedText) {
                $findings.Add([pscustomobject]@{ code = 'TreeRegistryNotLanded'; path = $TreeRegistryPath; detail = ('此工作樹的登錄表中檔位 ' + $Profile + ' 的設定與主 checkout 的產生檔不同：工作樹的登錄表變更尚未落地到主 checkout。'); fix_commands = [string[]]@(); fix_note = '先把工作樹的登錄表與產生檔落地到主 checkout，或還原工作樹的登錄表後重試。' })
            }
        }
        catch {
            $findings.Add([pscustomobject]@{ code = 'TreeRegistryInvalid'; path = $TreeRegistryPath; detail = ('無法讀取此工作樹的登錄表：' + $_.Exception.Message); fix_commands = [string[]]@(); fix_note = '修正工作樹的登錄表後重試。' })
        }
    }
    foreach ($accountPath in $AccountHome) {
        $path = Join-Path $accountPath $spec.FileName
        $link = Get-CodexProfileLinkState -LinkPath $path -TargetPath $generatedPath
        $text = Read-CodexProfileFileText -Path $path
        if ($null -eq $text) {
            $detail = if ($link.state -ceq 'missing') { '帳號目錄沒有檔位設定檔。' } else { '帳號目錄的檔位設定檔無法讀取（' + $link.state + '）。' }
            $findings.Add([pscustomobject]@{ code = 'ProfileFileMissing'; path = $path; detail = $detail; fix_commands = $link.fix_commands; fix_note = $link.fix_note })
            continue
        }
        if ($text -cne $generatedText) {
            $findings.Add([pscustomobject]@{ code = 'ProfileFileDrift'; path = $path; detail = '帳號目錄的檔位設定檔內容與 repo 產生檔不一致（' + $link.state + '）。'; fix_commands = $link.fix_commands; fix_note = $link.fix_note })
        }
        elseif ($link.state -ceq 'wrong-target') {
            $findings.Add([pscustomobject]@{ code = 'ProfileLinkWrongTarget'; path = $path; detail = ('內容相同，但連結指向 ' + $link.actual_target + '，預期指向 ' + $generatedPath + '。'); fix_commands = $link.fix_commands; fix_note = $link.fix_note })
        }
        elseif ($link.state -ceq 'not-link') {
            $findings.Add([pscustomobject]@{ code = 'ProfileFileNotLink'; path = $path; detail = '內容與 repo 產生檔相同，但帳號目錄的檔位設定檔是一般檔案；必須是指向 repo 產生檔的 Symbolic Link，不允許單機覆寫。'; fix_commands = $link.fix_commands; fix_note = $link.fix_note })
        }
    }
    return @($findings.ToArray())
}
