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
            FallbackModels = [string[]]@($executor.ProfileSettings['fallbackModels'])
            McpServers = @($executor.ProfileSettings['mcpServers'].Values)
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
    # 備援 model 由入口以 -c model= 套用，Codex 不從本檔讀取；寫成註解使產生檔完整反映登錄表，派工前比對因此涵蓋備援清單。
    $fallbackModels = Get-ExecutorRegistryList -Object $Spec -Name 'FallbackModels'
    foreach ($value in $fallbackModels) {
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or $value -cmatch '[\r\n]') { throw (New-CodexProfileError -Code 'CodexProfileSpecInvalid' -Message '產生檔內容的欄位值不得為空或含換行。') }
    }
    $lines = @(
        ('# 此檔由 ' + ($script:CodexProfileRegistryRelativePath.Replace('\', '/')) + ' 的執行者 ' + $Spec.ExecutorId + ' 產生，請勿手動編輯；修改請改登錄表。')
        if ($fallbackModels.Count -gt 0) { '# 備援 model（依序，主要 model 在帳號不被支援時由派工入口改用）：' + ($fallbackModels -join '、') }
        ('model = "' + $Spec.Model + '"')
        ('model_reasoning_effort = "' + $Spec.Effort + '"')
        ''
        '[agents]'
        'enabled = true'
        ('default_subagent_model = "' + $Spec.SubagentModel + '"')
        ('default_subagent_reasoning_effort = "' + $Spec.SubagentEffort + '"')
    )
    # MCP 伺服器：只有登錄表為該檔位宣告 mcpServers 時才輸出，其他檔位的內容不受影響。
    # 核准模式固定 approve（codex exec 的核准政策為 never，未設定時 MCP 工具被拒）。enabled = true 覆寫帳號 config.toml 以 enabled = false 提供的同名表。
    $quote = { param($Value) '"' + $Value + '"' }
    foreach ($server in @(Get-ExecutorRegistryProperty -Object $Spec -Name 'McpServers')) {
        $lines += ''
        $lines += ('[mcp_servers.' + $server.Name + ']')
        if ($null -ne $server.Command) { $lines += ('command = ' + (& $quote $server.Command)) }
        if (@($server.Args).Count -gt 0) { $lines += ('args = [' + ((@($server.Args) | ForEach-Object { & $quote $_ }) -join ', ') + ']') }
        if (@($server.EnvVars).Count -gt 0) { $lines += ('env_vars = [' + ((@($server.EnvVars) | ForEach-Object { & $quote $_ }) -join ', ') + ']') }
        $lines += 'enabled = true'
        $lines += 'default_tools_approval_mode = "approve"'
        $lines += ('enabled_tools = [' + ((@($server.EnabledTools) | ForEach-Object { & $quote $_ }) -join ', ') + ']')
    }
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

function Get-CodexMcpLocalCommandServer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Spec)

    # 登錄表為該檔位宣告、但省略 command 的 MCP 伺服器名稱（指令路徑因機器而異，由帳號目錄的 config.toml 提供）。
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($server in @(Get-ExecutorRegistryProperty -Object $Spec -Name 'McpServers')) {
        if ($null -eq $server.Command) { $names.Add([string]$server.Name) }
    }
    return [string[]]@($names.ToArray())
}

function Read-CodexAccountConfigState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    # 讀取帳號目錄的 config.toml（只讀）。回傳 exists、text（不含 BOM）、has_bom、newline（原檔的行尾，沒有換行時為 CRLF）、error。
    # 檔案不存在（exists = $false）不是錯誤；存在但讀不到或不是合法 UTF-8 時 error 有值，呼叫端不得寫檔。
    $result = [ordered]@{ exists = $false; text = ''; has_bom = $false; newline = "`r`n"; error = $null }
    try {
        if (-not [IO.File]::Exists($Path)) { return [pscustomobject]$result }
        $result.exists = $true
        $bytes = [IO.File]::ReadAllBytes($Path)
        # NUL 位元組表示不是 UTF-8（例如無 BOM 的 UTF-16），編碼不明，不得當成文字處理或寫入。
        if ([Array]::IndexOf($bytes, [byte]0) -ge 0) { throw '內容含 NUL 位元組，編碼不明（可能是 UTF-16）' }
        $result.has_bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $offset = if ($result.has_bom) { 3 } else { 0 }
        $result.text = (New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)).GetString($bytes, $offset, $bytes.Length - $offset)
        if ($result.text.Contains("`r`n")) { $result.newline = "`r`n" }
        elseif ($result.text.Contains("`n")) { $result.newline = "`n" }
    }
    catch { $result.error = $_.Exception.Message }
    return [pscustomobject]$result
}

function Test-CodexMcpServerMentioned {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Name
    )

    # 帳號 config.toml 是否可能已定義該 MCP 伺服器。標準表頭（可帶行尾註解、可引號）、點分鍵、行內表，以及 [mcp_servers] 父表或
    # mcp_servers = { ... } 內以子鍵定義的寫法都算；無法確定時回傳 $true（呼叫端回報 blocked，不追加以免產生重複表）。
    $escaped = [regex]::Escape($Name)
    foreach ($line in ($Text -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('#')) { continue }
        if ($trimmed -match '^\[\s*mcp_servers\s*\]\s*(#.*)?$') { return $true }
        if ($trimmed -match '^mcp_servers\s*=') { return $true }
        if ($trimmed -match 'mcp_servers' -and $trimmed -match ('(?<![A-Za-z0-9_-])' + $escaped + '(?![A-Za-z0-9_-])')) { return $true }
    }
    return $false
}

function Get-CodexMcpAccountConfigFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccountHome,
        [Parameter(Mandatory)][object]$Spec
    )

    # 讀取帳號目錄的 config.toml（只讀），回傳該檔位需要而缺少 command 的伺服器名稱。
    # 檔位檔只放 enabled、核准模式與工具清單，缺少帳號端的 command 時 Codex 載入該檔位設定會失敗（invalid transport）。
    # 讀不到檔案內容時無法確認 command，視為全部缺少。表頭可帶行尾註解與引號；行內表等其他寫法偵測不到 command，視為缺少。
    $required = @(Get-CodexMcpLocalCommandServer -Spec $Spec)
    if ($required.Count -eq 0) { return [string[]]@() }
    $state = Read-CodexAccountConfigState -Path (Join-Path $AccountHome 'config.toml')
    if ($null -ne $state.error) { return [string[]]$required }
    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $required) {
        $escaped = [regex]::Escape($name)
        $header = '^[ \t]*\[[ \t]*mcp_servers[ \t]*\.[ \t]*(?:"' + $escaped + '"|''' + $escaped + '''|' + $escaped + ')[ \t]*\][ \t]*(?:#[^\r\n]*)?\r?\n'
        $found = $false
        $table = [regex]::Match($state.text, '(?ms)' + $header + '(?<body>.*?)(?=^[ \t]*\[|\z)')
        if ($table.Success -and $table.Groups['body'].Value -match '(?m)^[ \t]*command[ \t]*=[ \t]*\S') { $found = $true }
        if (-not $found) { $missing.Add($name) }
    }
    return [string[]]@($missing.ToArray())
}

function Get-CodexMcpAccountBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        # 來源（Codex Desktop 的 config.toml）的文字；來源不存在或讀不到時為 $null。
        [AllowNull()][string]$SourceText,
        [Parameter(Mandatory)][string]$SourceConfigPath,
        [Parameter(Mandatory)][string]$ConfigPath
    )

    # 由來源的 [mcp_servers.<名稱>] 組出帳號 config.toml 要追加的表：command 與 startup_timeout_sec 取自來源，並加 enabled = false。
    # 回傳 action（block 或 source-missing）、detail（source-missing 時說明原因）、lines（表的各行，第一行為空行）。
    $table = if ($null -ne $SourceText) { [regex]::Match($SourceText, '(?ms)^\[mcp_servers\.' + [regex]::Escape($Name) + '\][ \t]*\r?\n(?<body>.*?)(?=^\[|\z)') } else { $null }
    $commandLine = $null
    $commandUnusable = $null
    $timeoutLine = $null
    if ($null -ne $table -and $table.Success) {
        $commandMatch = [regex]::Match($table.Groups['body'].Value, '(?m)^[ \t]*command[ \t]*=[ \t]*(?<value>.+?)[ \t]*\r?$')
        if ($commandMatch.Success) {
            # 只複製單行的基本字串或字面字串；多行字串（""" 或 '''）、值後面還有其他內容（行尾註解等）無法確定語意，視為來源沒有可用的 command。
            $commandValue = $commandMatch.Groups['value'].Value
            if ($commandValue -cmatch '^"(?:[^"\\]|\\.)*"$' -or $commandValue -cmatch "^'[^']*'$") { $commandLine = 'command = ' + $commandValue }
            else { $commandUnusable = $commandValue }
        }
        $timeoutMatch = [regex]::Match($table.Groups['body'].Value, '(?m)^[ \t]*startup_timeout_sec[ \t]*=[ \t]*(?<value>[0-9.]+)[ \t]*\r?$')
        if ($timeoutMatch.Success) { $timeoutLine = 'startup_timeout_sec = ' + $timeoutMatch.Groups['value'].Value }
    }
    if ($null -eq $commandLine -and $null -ne $commandUnusable) {
        return [pscustomobject]@{ action = 'source-missing'; lines = [string[]]@(); detail = ($SourceConfigPath + ' 的 [mcp_servers.' + $Name + '] command 不是單行的基本字串或字面字串（多行字串或值後面還有其他內容），Setup 無法確定其語意，不複製；請在 ' + $ConfigPath + ' 自行加入該表（command 加 enabled = false）後重跑 Setup。') }
    }
    if ($null -eq $commandLine) {
        return [pscustomobject]@{ action = 'source-missing'; lines = [string[]]@(); detail = ($SourceConfigPath + ' 沒有 [mcp_servers.' + $Name + '] 的 command；請先在 Codex Desktop 設定該 MCP 伺服器，或在 ' + $ConfigPath + ' 自行加入該表（command 加 enabled = false）後重跑 Setup。') }
    }
    $block = @('', ('[mcp_servers.' + $Name + ']'), $commandLine)
    if ($null -ne $timeoutLine) { $block += $timeoutLine }
    $block += 'enabled = false'
    return [pscustomobject]@{ action = 'block'; lines = [string[]]$block; detail = '' }
}

function ConvertTo-CodexMcpAccountAppendText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExistingText,
        [Parameter(Mandatory)][string]$Newline,
        # 每個元素是一個表的各行（Get-CodexMcpAccountBlock 的 lines）。
        [Parameter(Mandatory)][object[]]$Block
    )

    # 追加到帳號 config.toml 檔尾的文字：原檔沒有以換行結尾時先補一個換行，各表沿用原檔的行尾。
    $appendText = ''
    if ($ExistingText.Length -gt 0 -and -not $ExistingText.EndsWith("`n")) { $appendText += $Newline }
    foreach ($lines in $Block) { $appendText += ((@($lines) -join $Newline) + $Newline) }
    return $appendText
}

function Set-CodexMcpAccountConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$AccountHome,
        [Parameter(Mandatory)][object]$Spec,
        # 指令路徑的來源（Codex Desktop 的 config.toml）。只讀，只取登錄表指名之伺服器的 command 與 startup_timeout_sec 兩行。
        [Parameter(Mandatory)][string]$SourceConfigPath
    )

    # 檔位檔只啟用 MCP 伺服器，指令路徑因機器而異，由帳號目錄 config.toml 以 enabled = false 提供（其他檔位不會載入它）。
    # 這個函式會寫使用者的帳號設定檔，任何無法確定的狀態都選擇不寫：帳號 config.toml 讀不到或不是合法 UTF-8、已可能定義該伺服器
    # （含表頭帶註解、引號鍵、行內表、父表寫法）、來源沒有 command，一律不寫檔。
    # 只在缺少時於檔尾追加（AppendAllText，原檔的 BOM 與既有內容原封不動，追加段沿用原檔的行尾），一次寫入全部缺少的表。
    # 回傳每個伺服器的結果：action 為 ok、added、would-add、source-missing 或 blocked，detail 說明原因。
    $results = New-Object 'System.Collections.Generic.List[object]'
    $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
    $configPath = Join-Path $AccountHome 'config.toml'
    $state = Read-CodexAccountConfigState -Path $configPath
    $missing = @(Get-CodexMcpAccountConfigFinding -AccountHome $AccountHome -Spec $Spec)
    $sourceText = $null
    try { if ([IO.File]::Exists($SourceConfigPath)) { $sourceText = [IO.File]::ReadAllText($SourceConfigPath, $utf8) } } catch { $sourceText = $null }
    $newline = $state.newline
    $blocks = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in @(Get-CodexMcpLocalCommandServer -Spec $Spec)) {
        if ($missing -cnotcontains $name) {
            $results.Add([pscustomobject]@{ server = $name; action = 'ok'; detail = '帳號目錄已有 command' })
            continue
        }
        if ($null -ne $state.error) {
            $results.Add([pscustomobject]@{ server = $name; action = 'blocked'; detail = ($configPath + ' 讀取失敗，Setup 不寫檔：' + $state.error) })
            continue
        }
        if (-not $state.exists) {
            # 帳號目錄沒有 config.toml：不新建只含 MCP 表的檔案（缺少基礎設定的帳號本來就不會被派工入口選用），維持略過並要求使用者先準備。
            $results.Add([pscustomobject]@{ server = $name; action = 'blocked'; detail = ($configPath + ' 不存在，Setup 不新建只含 MCP 表的 config.toml；請以 scripts\New-CodexDispatchAccount.ps1 補齊帳號的 config.toml 後重跑 Setup，說明見 README.md「Codex 派工環境」。') })
            continue
        }
        if (Test-CodexMcpServerMentioned -Text $state.text -Name $name) {
            $results.Add([pscustomobject]@{ server = $name; action = 'blocked'; detail = ($configPath + ' 已有或可能已有 mcp_servers 的 ' + $name + ' 定義，但偵測不到 command，Setup 不改既有內容；請自行補上 command 並設 enabled = false。') })
            continue
        }
        $built = Get-CodexMcpAccountBlock -Name $name -SourceText $sourceText -SourceConfigPath $SourceConfigPath -ConfigPath $configPath
        if ($built.action -ceq 'source-missing') {
            $results.Add([pscustomobject]@{ server = $name; action = 'source-missing'; detail = $built.detail })
            continue
        }
        $blocks.Add([pscustomobject]@{ name = $name; lines = $built.lines })
    }
    if ($blocks.Count -eq 0) { return @($results.ToArray()) }
    if (-not $PSCmdlet.ShouldProcess($configPath, ('追加 ' + (@($blocks | ForEach-Object { '[mcp_servers.' + $_.name + ']' }) -join '、') + '（enabled = false）'))) {
        foreach ($block in $blocks) { $results.Add([pscustomobject]@{ server = $block.name; action = 'would-add'; detail = ($configPath + ' 將追加 [mcp_servers.' + $block.name + ']') }) }
        return @($results.ToArray())
    }
    $appendText = ConvertTo-CodexMcpAccountAppendText -ExistingText $state.text -Newline $newline -Block @($blocks | ForEach-Object { , $_.lines })
    try {
        [IO.File]::AppendAllText($configPath, $appendText, $utf8)
    }
    catch {
        foreach ($block in $blocks) { $results.Add([pscustomobject]@{ server = $block.name; action = 'blocked'; detail = ($configPath + ' 追加失敗：' + $_.Exception.Message) }) }
        return @($results.ToArray())
    }
    foreach ($block in $blocks) { $results.Add([pscustomobject]@{ server = $block.name; action = 'added'; detail = ($configPath + ' 已追加 [mcp_servers.' + $block.name + ']（enabled = false）') }) }
    return @($results.ToArray())
}

function Invoke-CodexMcpAccountSetup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$AccountName,
        [Parameter(Mandatory)][string]$AccountHome,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Spec,
        [Parameter(Mandatory)][string]$SourceConfigPath
    )

    # Setup 對一個派工帳號處理全部需要帳號端 command 的 MCP 伺服器。回傳 blocked（需要使用者處理的項目數，Setup 併入阻塞計數）與
    # messages（level 為 info、success 或 warning，text 為輸出內容），輸出由 Setup 負責，本函式不寫主控台。
    $messages = New-Object 'System.Collections.Generic.List[object]'
    $blocked = 0
    foreach ($mcpSpec in @($Spec | Where-Object { @(Get-CodexMcpLocalCommandServer -Spec $_).Count -gt 0 })) {
        foreach ($result in @(Set-CodexMcpAccountConfig -AccountHome $AccountHome -Spec $mcpSpec -SourceConfigPath $SourceConfigPath -WhatIf:$WhatIfPreference)) {
            switch ($result.action) {
                'ok' { $messages.Add([pscustomobject]@{ level = 'success'; text = ('帳號 ' + $AccountName + ' 的 MCP 伺服器 ' + $result.server + ' 已有 command') }) }
                'added' { $messages.Add([pscustomobject]@{ level = 'success'; text = $result.detail }) }
                'would-add' { $messages.Add([pscustomobject]@{ level = 'info'; text = $result.detail }) }
                default {
                    $messages.Add([pscustomobject]@{ level = 'warning'; text = ('帳號 ' + $AccountName + '：' + $result.detail) })
                    $blocked++
                }
            }
        }
    }
    return [pscustomobject]@{ blocked = $blocked; messages = @($messages.ToArray()) }
}
