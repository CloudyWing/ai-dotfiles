#Requires -Version 7.0
# MCP 登記腳本（Register-McpServer.ps1）的實際內容：mcp-lab 與 infra-lab 登記到 Claude Code 使用者層，FlaUI.Mcp 的指令寫入 Codex 桌面版設定檔，以及三者的唯讀檢查。
# 由 Register-McpServer.ps1 在版本判斷之後以 dot-source 載入，只定義函式，不在載入時執行任何動作。
# 本檔使用 lib\claude-user-config.ps1 的函式（範本讀取、登記計畫、Claude CLI 呼叫、WSL 與連接埠探測），
# 以及 codex-run\45-profile-sync.ps1 的 Read-CodexAccountConfigState、Test-CodexMcpServerMentioned（讀取 TOML 設定檔的編碼與行尾、判斷伺服器是否可能已被定義）。
# 寫入邊界：Claude 端只經 claude mcp add（Invoke-ClaudeMcpStep）；Codex 設定檔只在 Set-FlaUIMcpCommand（桌面版）與 Set-FlaUIMcpAccountCommand（.local\machine.json 登記的派工帳號）內寫入，
# 兩者都只新增或更新 [mcp_servers.flaui-mcp] 的 command（派工帳號缺少該表時依 Setup 複製的形式追加整張表，含 enabled = false），其餘位元組不變；
# 每個檔案寫入前各備份一份（同一次執行共用一個備份目錄，以相對路徑區分來源），寫入前確認原檔自讀取後未被改動，設定檔是連結時寫入連結指向的實際檔案；
# 不建立設定檔，不刪除 .codex 目錄下的任何檔案（暫存檔只在寫入流程內建立並取代原檔）。
# 派工帳號的清單取自 dispatch\dispatch-evidence.ps1 的 Read-CodexAccountConfiguration，呼叫端須先載入 dispatch\common-runtime.ps1、git-baseline.ps1 與 dispatch-evidence.ps1。

function Get-FlaUIMcpState {
    # 讀取 Codex 桌面版設定檔（只讀），判定 [mcp_servers.flaui-mcp] 的狀態。
    # Kind：config-missing（檔案不存在）、unreadable（讀不到或不是合法 UTF-8）、present（有 command，且為可處理的單行字串）、
    # present-unsupported（有 command 但寫法無法確定語意，例如多行字串或值後面有註解）、no-command（表存在但沒有 command）、
    # ambiguous（可能已用其他寫法定義該伺服器）、absent（沒有定義）。
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)

    $name = 'flaui-mcp'
    $state = Read-CodexAccountConfigState -Path $ConfigPath
    $result = [ordered]@{ Kind = 'absent'; Text = $state.text; HasBom = $state.has_bom; Newline = $state.newline; Error = $state.error; CommandValue = $null; ValueIndex = -1; ValueLength = 0; ValueStyle = 'literal'; HeaderEnd = -1 }
    if (-not $state.exists) { $result.Kind = 'config-missing'; return [pscustomobject]$result }
    if ($null -ne $state.error) { $result.Kind = 'unreadable'; return [pscustomobject]$result }

    $escaped = [regex]::Escape($name)
    $header = '^[ \t]*\[[ \t]*mcp_servers[ \t]*\.[ \t]*(?:"' + $escaped + '"|''' + $escaped + '''|' + $escaped + ')[ \t]*\][ \t]*(?:#[^\r\n]*)?\r?\n'
    $table = [regex]::Match($state.text, '(?ms)(?<header>' + $header + ')(?<body>.*?)(?=^[ \t]*\[|\z)')
    if (-not $table.Success) {
        if (Test-CodexMcpServerMentioned -Text $state.text -Name $name) { $result.Kind = 'ambiguous' }
        return [pscustomobject]$result
    }
    $result.HeaderEnd = $table.Groups['header'].Index + $table.Groups['header'].Length
    $bodyGroup = $table.Groups['body']
    $commandMatch = [regex]::Match($bodyGroup.Value, '(?m)^(?<prefix>[ \t]*command[ \t]*=[ \t]*)(?<value>.+?)[ \t]*\r?$')
    if (-not $commandMatch.Success) { $result.Kind = 'no-command'; return [pscustomobject]$result }

    $valueGroup = $commandMatch.Groups['value']
    $token = $valueGroup.Value
    $parsed = $null
    if ($token -cmatch "^'([^']*)'$") { $parsed = $Matches[1]; $result.ValueStyle = 'literal' }
    elseif ($token -cmatch '^"((?:[^"\\]|\\[\\"])*)"$') { $parsed = ($Matches[1] -replace '\\(["\\])', '$1'); $result.ValueStyle = 'basic' }
    if ($null -eq $parsed) { $result.Kind = 'present-unsupported'; return [pscustomobject]$result }
    $result.Kind = 'present'
    $result.CommandValue = $parsed
    $result.ValueIndex = $bodyGroup.Index + $valueGroup.Index
    $result.ValueLength = $valueGroup.Length
    return [pscustomobject]$result
}

function ConvertTo-FlaUITomlString {
    # 路徑的 TOML 字串：預設為單引號的字面字串（Windows 路徑不需要跳脫）；路徑含單引號或控制字元，或原值為雙引號字串時用基本字串。
    param([Parameter(Mandatory)][string]$Value, [ValidateSet('literal', 'basic')][string]$Style = 'literal')

    if ($Style -eq 'literal' -and -not $Value.Contains("'") -and $Value -notmatch '[\x00-\x1f]') { return "'" + $Value + "'" }
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Get-FlaUICommandEdit {
    # 依 Get-FlaUIMcpState 的狀態計算 command 的改寫結果，只處理表已存在的兩種情形（保留其餘位元組）：
    # present 只取代值的位置與長度，no-command 在表頭下插入一行。其他狀態回傳 $null（表不存在，由呼叫端決定追加的內容）。
    # 回傳 Status（unchanged 或 updated）與 NewText。
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$ExecutablePath
    )

    if ($State.Kind -eq 'present') {
        if ([string]::Equals($State.CommandValue, $ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Status = 'unchanged'; NewText = $State.Text }
        }
        $token = ConvertTo-FlaUITomlString -Value $ExecutablePath -Style $State.ValueStyle
        return [pscustomobject]@{ Status = 'updated'; NewText = ($State.Text.Substring(0, $State.ValueIndex) + $token + $State.Text.Substring($State.ValueIndex + $State.ValueLength)) }
    }
    if ($State.Kind -eq 'no-command') {
        return [pscustomobject]@{ Status = 'updated'; NewText = $State.Text.Insert($State.HeaderEnd, ('command = ' + (ConvertTo-FlaUITomlString -Value $ExecutablePath) + $State.Newline)) }
    }
    return $null
}

function Invoke-FlaUIConfigWrite {
    # 寫入流程：備份讀到的原檔位元組、確認原檔未被改動後取代（或原地寫入硬連結）、讀回比對。呼叫端已通過 ShouldProcess，並已決定寫入目標（Resolve-ConfigWriteTarget）。
    # 回傳 Status（written、changed、failed）、Message、BackupPath。
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)]$WriteTarget,
        [Parameter(Mandatory)][string]$NewText,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)]$BackupContext,
        [Parameter(Mandatory)][string]$BackupRelativePath,
        [Parameter(Mandatory)][string]$Operation
    )

    $backupPath = $null
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $bom = [byte[]](0xEF, 0xBB, 0xBF)
        # 嚴格 UTF-8 解碼的文字重新編碼會得到原檔的位元組（Read-CodexAccountConfigState 對無效位元組與 NUL 不回傳文字）。
        # 以 if 運算式賦值會把空陣列列舉成 $null（0 位元組的檔案），改為逐步賦值，空檔維持空陣列。
        [byte[]]$originalBytes = $encoding.GetBytes($State.Text)
        [byte[]]$newBytes = $encoding.GetBytes($NewText)
        if ($State.HasBom) { $originalBytes = [byte[]]($bom + $originalBytes); $newBytes = [byte[]]($bom + $newBytes) }
        $backupPath = Save-ConfigFileBackup -Context $BackupContext -BackupRoot $BackupRoot -RelativePath $BackupRelativePath -Bytes $originalBytes -SourcePath $ConfigPath -Operation $Operation
        $writeStatus = Write-ConfigFileGuarded -Path $WriteTarget.Path -ExpectedBytes $originalBytes -NewBytes $newBytes -InPlace:$WriteTarget.InPlace
        if ($writeStatus -ceq 'changed') {
            return [pscustomobject]@{ Status = 'changed'; Message = "$ConfigPath 在讀取之後被其他程式改動，為避免遺失該次變更，未寫入。確認沒有程式正在寫入該檔後重新執行"; BackupPath = $backupPath }
        }
    }
    catch {
        return [pscustomobject]@{ Status = 'failed'; Message = ("寫入失敗：{0}" -f $_.Exception.Message); BackupPath = $backupPath }
    }
    return [pscustomobject]@{ Status = 'written'; Message = ''; BackupPath = $backupPath }
}

function Set-FlaUIMcpCommand {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$BackupRoot,
        # 同一次執行的備份共用一個目錄；省略時本次呼叫自成一個。
        $BackupContext
    )

    # 回傳 Status：added（新增表）、updated（更新 command）、unchanged、whatif、invalid-path、executable-missing、config-missing、blocked、unresolved、changed、failed；
    # 只有 added 與 updated 寫入檔案。任何無法確定的狀態一律不寫。
    $outcome = { param($Status, $Message, $BackupPath) [pscustomobject]@{ Status = $Status; Message = $Message; BackupPath = $BackupPath } }
    if ($null -eq $BackupContext) { $BackupContext = New-ConfigBackupContext }

    if (-not [IO.Path]::IsPathFullyQualified($ExecutablePath)) {
        return (& $outcome 'invalid-path' "FlaUI.Mcp 的路徑 $ExecutablePath 不是完整的絕對路徑，寫入設定檔會因啟動時的工作目錄不同而找不到，未寫入" $null)
    }
    if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
        return (& $outcome 'executable-missing' "找不到 FlaUI.Mcp 執行檔 $ExecutablePath，未寫入。依 README 取得並解壓後重新執行，或以 -FlaUIPath 指定實際位置" $null)
    }
    $state = Get-FlaUIMcpState -ConfigPath $ConfigPath
    switch ($state.Kind) {
        'config-missing' { return (& $outcome 'config-missing' "Codex 桌面版設定檔 $ConfigPath 不存在，腳本不建立設定檔，未寫入。先啟動一次 Codex 桌面版讓它建立設定檔，或自行建立後重新執行" $null) }
        'unreadable' { return (& $outcome 'blocked' ("Codex 桌面版設定檔 $ConfigPath 讀取失敗，未寫入：" + $state.Error) $null) }
        'ambiguous' { return (& $outcome 'blocked' "Codex 桌面版設定檔 $ConfigPath 已有或可能已有 flaui-mcp 的定義，但偵測不到標準的 [mcp_servers.flaui-mcp] 表，未寫入。請自行確認並設定 command" $null) }
        'present-unsupported' { return (& $outcome 'blocked' "Codex 桌面版設定檔 $ConfigPath 的 [mcp_servers.flaui-mcp] 已有 command，但寫法不是單行字串或值後面有其他內容，無法確定語意，未寫入。請自行修改 command" $null) }
    }

    $edit = Get-FlaUICommandEdit -State $state -ExecutablePath $ExecutablePath
    if ($null -ne $edit -and $edit.Status -eq 'unchanged') {
        return (& $outcome 'unchanged' 'flaui-mcp 的 command 已是指定的執行檔路徑，未寫入' $null)
    }
    if ($null -ne $edit) { $newText = $edit.NewText; $status = $edit.Status }
    else {
        $newline = $state.Newline
        $append = ''
        if ($state.Text.Length -gt 0 -and -not $state.Text.EndsWith("`n")) { $append += $newline }
        $append += $newline + '[mcp_servers.flaui-mcp]' + $newline + ('command = ' + (ConvertTo-FlaUITomlString -Value $ExecutablePath)) + $newline + 'startup_timeout_sec = 60.0' + $newline
        $newText = $state.Text + $append
        $status = 'added'
    }

    $writeTarget = Resolve-ConfigWriteTarget -Path $ConfigPath
    if (-not $writeTarget.Ok) {
        return (& $outcome 'unresolved' ("Codex 桌面版設定檔 $ConfigPath 的寫入目標無法確定，未寫入：" + $writeTarget.Message) $null)
    }
    if (-not $PSCmdlet.ShouldProcess($ConfigPath, 'Codex 桌面版設定檔的 flaui-mcp：寫入 command')) {
        return (& $outcome 'whatif' ("預演：將在 $ConfigPath 的 [mcp_servers.flaui-mcp] " + $(if ($status -eq 'added') { '新增 command 與 startup_timeout_sec' } else { '更新 command' }) + '，未寫入任何檔案') $null)
    }

    $written = Invoke-FlaUIConfigWrite -State $state -ConfigPath $ConfigPath -WriteTarget $writeTarget -NewText $newText -BackupRoot $BackupRoot -BackupContext $BackupContext -BackupRelativePath 'desktop\config.toml' -Operation '寫入 Codex 桌面版 flaui-mcp 的 command'
    if ($written.Status -ne 'written') { return (& $outcome $written.Status $written.Message $written.BackupPath) }
    $message = if ($status -eq 'added') { "已在 $ConfigPath 新增 [mcp_servers.flaui-mcp]" } else { "已更新 $ConfigPath 的 flaui-mcp command" }
    return (& $outcome $status $message $written.BackupPath)
}

function Set-FlaUIMcpAccountCommand {
    # 派工帳號目錄 config.toml 的 flaui-mcp：表已存在時只改 command（其餘位元組含 enabled = false 與 startup_timeout_sec 不變）；
    # 沒有該表時依 Setup 複製的形式追加整張表（command、startup_timeout_sec 取自來源，並加 enabled = false，由 Get-CodexMcpAccountBlock 組出）。
    # 回傳 AccountName、Status（added、updated、unchanged、whatif、config-missing、blocked、unresolved、changed、failed）、Message、BackupPath。
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$AccountName,
        [Parameter(Mandatory)][string]$AccountHome,
        [Parameter(Mandatory)][string]$ExecutablePath,
        # 追加整張表時 command 與 startup_timeout_sec 的來源（Codex 桌面版 config.toml）。
        [Parameter(Mandatory)][string]$SourceConfigPath,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)]$BackupContext
    )

    $outcome = { param($Status, $Message, $BackupPath) [pscustomobject]@{ AccountName = $AccountName; Status = $Status; Message = $Message; BackupPath = $BackupPath } }
    $configPath = Join-Path $AccountHome 'config.toml'
    $label = "派工帳號 $AccountName 的設定檔 $configPath"
    $state = Get-FlaUIMcpState -ConfigPath $configPath
    switch ($state.Kind) {
        'config-missing' { return (& $outcome 'config-missing' "$label 不存在，腳本不建立設定檔，已略過此帳號。請以 scripts\New-CodexDispatchAccount.ps1 補齊帳號的 config.toml 後重新執行" $null) }
        'unreadable' { return (& $outcome 'blocked' ("$label 讀取失敗，已略過此帳號：" + $state.Error) $null) }
        'ambiguous' { return (& $outcome 'blocked' "$label 已有或可能已有 flaui-mcp 的定義，但偵測不到標準的 [mcp_servers.flaui-mcp] 表，已略過此帳號。請自行確認並設定 command" $null) }
        'present-unsupported' { return (& $outcome 'blocked' "$label 的 [mcp_servers.flaui-mcp] 已有 command，但寫法不是單行字串或值後面有其他內容，無法確定語意，已略過此帳號。請自行修改 command" $null) }
    }

    $edit = Get-FlaUICommandEdit -State $state -ExecutablePath $ExecutablePath
    if ($null -ne $edit -and $edit.Status -eq 'unchanged') {
        return (& $outcome 'unchanged' "$label 的 flaui-mcp command 已是指定的執行檔路徑，未寫入" $null)
    }
    $newText = $null
    $status = $null
    if ($null -ne $edit) { $newText = $edit.NewText; $status = $edit.Status }
    else { $status = 'added' }

    $writeTarget = Resolve-ConfigWriteTarget -Path $configPath
    if (-not $writeTarget.Ok) {
        return (& $outcome 'unresolved' ("$label 的寫入目標無法確定，已略過此帳號：" + $writeTarget.Message) $null)
    }
    if (-not $PSCmdlet.ShouldProcess($configPath, "派工帳號 $AccountName 的 flaui-mcp：寫入 command")) {
        return (& $outcome 'whatif' ("預演：將在 $label 的 [mcp_servers.flaui-mcp] " + $(if ($status -eq 'added') { '追加整張表（含 enabled = false）' } else { '更新 command' }) + '，未寫入任何檔案') $null)
    }
    if ($status -eq 'added') {
        $sourceState = Read-CodexAccountConfigState -Path $SourceConfigPath
        $sourceText = if ($sourceState.exists -and $null -eq $sourceState.error) { $sourceState.text } else { $null }
        $built = Get-CodexMcpAccountBlock -Name 'flaui-mcp' -SourceText $sourceText -SourceConfigPath $SourceConfigPath -ConfigPath $configPath
        if ($built.action -ceq 'source-missing') { return (& $outcome 'blocked' ($built.detail + '（已略過此帳號）') $null) }
        $newText = $state.Text + (ConvertTo-CodexMcpAccountAppendText -ExistingText $state.Text -Newline $state.Newline -Block @(, $built.lines))
    }

    $written = Invoke-FlaUIConfigWrite -State $state -ConfigPath $configPath -WriteTarget $writeTarget -NewText $newText -BackupRoot $BackupRoot -BackupContext $BackupContext -BackupRelativePath ('accounts\' + $AccountName + '\config.toml') -Operation ("寫入派工帳號 $AccountName 的 flaui-mcp")
    if ($written.Status -ne 'written') { return (& $outcome $written.Status ("$label：" + $written.Message) $written.BackupPath) }
    $message = if ($status -eq 'added') { "已在 $configPath 追加 [mcp_servers.flaui-mcp]（enabled = false）" } else { "已更新 $configPath 的 flaui-mcp command" }
    return (& $outcome $status $message $written.BackupPath)
}

function Get-FlaUIRegisteredAccount {
    # .local\machine.json 登記的派工帳號。檔案不存在或沒有 codex_accounts 時為空；登記內容不合法時 Error 有值（原因取自 Read-CodexAccountConfiguration）。
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$MachineConfigPath)

    $result = [pscustomobject]@{ Accounts = @(); Error = $null }
    if ([string]::IsNullOrWhiteSpace($MachineConfigPath)) { return $result }
    try { $result.Accounts = @(Read-CodexAccountConfiguration -MachineConfigPath $MachineConfigPath) }
    catch { $result.Error = $_.Exception.Message }
    return $result
}

function New-McpCheckItem {
    param([string]$Target, [string]$Name, [string]$Status, [string]$Expected, [string]$Detail = '')
    return [pscustomobject]@{ Target = $Target; Name = $Name; Status = $Status; Expected = $Expected; Detail = $Detail }
}

function Get-FlaUIMcpCheckItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [System.Collections.Generic.List[string]]$Note
    )

    $state = Get-FlaUIMcpState -ConfigPath $ConfigPath
    $expected = '[mcp_servers.flaui-mcp] 的 command 為 ' + $ExecutablePath
    $item = switch ($state.Kind) {
        'config-missing' { New-McpCheckItem -Target 'flaui' -Name 'flaui-mcp' -Status 'missing' -Expected $expected -Detail ("Codex 桌面版設定檔 $ConfigPath 不存在；腳本不建立設定檔，先啟動一次 Codex 桌面版") }
        'unreadable' { New-McpCheckItem -Target 'flaui' -Name 'flaui-mcp' -Status 'unknown' -Expected $expected -Detail ('設定檔無法讀取：' + $state.Error) }
        'ambiguous' { New-McpCheckItem -Target 'flaui' -Name 'flaui-mcp' -Status 'unknown' -Expected $expected -Detail '設定檔可能已用其他寫法定義 flaui-mcp，無法判定' }
        'present-unsupported' { New-McpCheckItem -Target 'flaui' -Name 'flaui-mcp' -Status 'unknown' -Expected $expected -Detail 'command 的寫法無法確定語意（不是單行字串或值後面有其他內容）' }
        'absent' { New-McpCheckItem -Target 'flaui' -Name 'flaui-mcp' -Status 'missing' -Expected $expected -Detail '設定檔沒有 [mcp_servers.flaui-mcp]；執行 Register-McpServer.ps1 -FlaUI 寫入' }
        'no-command' { New-McpCheckItem -Target 'flaui' -Name 'flaui-mcp' -Status 'missing' -Expected $expected -Detail '[mcp_servers.flaui-mcp] 沒有 command；執行 Register-McpServer.ps1 -FlaUI 寫入' }
        default {
            if ([string]::Equals($state.CommandValue, $ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase)) { New-McpCheckItem -Target 'flaui' -Name 'flaui-mcp' -Status 'ok' -Expected $expected }
            else { New-McpCheckItem -Target 'flaui' -Name 'flaui-mcp' -Status 'mismatch' -Expected $expected -Detail ('command 為 ' + $state.CommandValue + '，與指定的執行檔路徑不同；以 Register-McpServer.ps1 -FlaUI 更新，或以 -FlaUIPath 指定目前使用的路徑') }
        }
    }
    if ($null -ne $Note -and -not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
        $Note.Add('FlaUI.Mcp 執行檔不存在於 ' + $ExecutablePath + '；依 README 取得並解壓。執行檔不存在不影響本檢查的結果。')
    }
    return $item
}

function Get-FlaUIAccountCheckItem {
    # 各派工帳號的 flaui-mcp command 是否與 Codex 桌面版設定檔的 command 一致（只讀）。不一致、缺少或無法判定都不是 ok，項目名稱帶帳號名稱。
    # 沒有登記帳號時只在備註說明；登記內容不合法時回傳一個無法判定的項目。
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$MachineConfigPath,
        [Parameter(Mandatory)][string]$DesktopConfigPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Note
    )

    $registered = Get-FlaUIRegisteredAccount -MachineConfigPath $MachineConfigPath
    if ($null -ne $registered.Error) {
        return @(New-McpCheckItem -Target 'flaui' -Name 'flaui-mcp（派工帳號）' -Status 'unknown' -Expected '派工帳號登記可讀取' -Detail ('派工帳號登記無法讀取：' + $registered.Error))
    }
    if ($registered.Accounts.Count -eq 0) {
        $Note.Add('沒有登記的派工帳號（.local\machine.json 不存在或沒有 codex_accounts），只檢查桌面版，未檢查帳號目錄的 flaui-mcp。')
        return @()
    }
    $desktop = Get-FlaUIMcpState -ConfigPath $DesktopConfigPath
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($account in $registered.Accounts) {
        $name = 'flaui-mcp（派工帳號 ' + $account.name + '）'
        $expected = '[mcp_servers.flaui-mcp] 的 command 與桌面版相同'
        if ($desktop.Kind -ne 'present') {
            $items.Add((New-McpCheckItem -Target 'flaui' -Name $name -Status 'unknown' -Expected $expected -Detail '桌面版設定檔沒有可比對的 flaui-mcp command，無法判定帳號是否一致'))
            continue
        }
        $accountPath = Join-Path $account.codex_home 'config.toml'
        $state = Get-FlaUIMcpState -ConfigPath $accountPath
        $item = switch ($state.Kind) {
            'config-missing' { New-McpCheckItem -Target 'flaui' -Name $name -Status 'missing' -Expected $expected -Detail ("帳號設定檔 $accountPath 不存在；腳本不建立設定檔，請以 scripts\New-CodexDispatchAccount.ps1 補齊帳號的 config.toml") }
            'unreadable' { New-McpCheckItem -Target 'flaui' -Name $name -Status 'unknown' -Expected $expected -Detail ("帳號設定檔 $accountPath 無法讀取：" + $state.Error) }
            'ambiguous' { New-McpCheckItem -Target 'flaui' -Name $name -Status 'unknown' -Expected $expected -Detail ("帳號設定檔 $accountPath 可能已用其他寫法定義 flaui-mcp，無法判定") }
            'present-unsupported' { New-McpCheckItem -Target 'flaui' -Name $name -Status 'unknown' -Expected $expected -Detail ("帳號設定檔 $accountPath 的 command 寫法無法確定語意") }
            'absent' { New-McpCheckItem -Target 'flaui' -Name $name -Status 'missing' -Expected $expected -Detail ("帳號設定檔 $accountPath 沒有 [mcp_servers.flaui-mcp]；執行 Register-McpServer.ps1 -FlaUI 寫入") }
            'no-command' { New-McpCheckItem -Target 'flaui' -Name $name -Status 'missing' -Expected $expected -Detail ("帳號設定檔 $accountPath 的 [mcp_servers.flaui-mcp] 沒有 command；執行 Register-McpServer.ps1 -FlaUI 寫入") }
            default {
                if ([string]::Equals($state.CommandValue, $desktop.CommandValue, [System.StringComparison]::OrdinalIgnoreCase)) { New-McpCheckItem -Target 'flaui' -Name $name -Status 'ok' -Expected $expected }
                else { New-McpCheckItem -Target 'flaui' -Name $name -Status 'mismatch' -Expected $expected -Detail ('派工帳號 ' + $account.name + ' 的 command 為 ' + $state.CommandValue + '，桌面版為 ' + $desktop.CommandValue + '；執行 Register-McpServer.ps1 -FlaUI 更新帳號') }
            }
        }
        $items.Add($item)
    }
    return @($items.ToArray())
}

function Get-ClaudeMcpCheckItem {
    # Claude Code 使用者層的 MCP 登記（只讀）。Group 為 mcp-lab 與 infra-lab 的子集。
    # mcp-lab 服務是否啟動只對 127.0.0.1 的埠做連線探測，不送請求內容，結果只寫入備註；infra-lab 選取時另檢查 WSL 是否存在。
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('mcp-lab', 'infra-lab')][string[]]$Group,
        [Parameter(Mandatory)][string]$McpTemplatePath,
        [Parameter(Mandatory)][string]$UserMcpPath,
        [AllowNull()][AllowEmptyString()][string]$InfraLabDistro,
        [AllowNull()][AllowEmptyString()][string]$InfraLabWslRepo,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Note
    )

    $target =if ($Group.Count -eq 1) { $Group[0] } else { 'claude' }
    try { $template = @(Read-ClaudeMcpTemplate -Path $McpTemplatePath) }
    catch { return @(New-McpCheckItem -Target $target -Name 'MCP 範本' -Status 'unknown' -Expected 'MCP 範本可讀取' -Detail $_.Exception.Message) }
    $template = @($template | Where-Object { ($Group -contains 'mcp-lab' -and $_.Type -eq 'http') -or ($Group -contains 'infra-lab' -and $_.Type -eq 'stdio') })

    $items = New-Object 'System.Collections.Generic.List[object]'
    $registered = Get-ClaudeUserMcpServer -Path $UserMcpPath
    if ($null -ne $registered.Error) {
        $items.Add((New-McpCheckItem -Target $target -Name '使用者層登記' -Status 'unknown' -Expected '使用者層登記可讀取' -Detail ('使用者層登記檔無法讀取（原因：' + $registered.Error + '）')))
    }
    else {
        $plan = @(Get-ClaudeMcpPlan -Template $template -Existing $registered.Servers -Distro $InfraLabDistro -WslRepo $InfraLabWslRepo)
        foreach ($server in $template) {
            $planItem = @($plan | Where-Object { $_.Name -ceq $server.Name })[0]
            $targetName = if ($server.Type -eq 'http') { 'mcp-lab' } else { 'infra-lab' }
            $expectedText = if ($server.Type -eq 'http') { $server.Url } else { 'stdio，經 ' + $server.Command + ' 啟動' }
            switch ($planItem.Action) {
                'unchanged' { $items.Add((New-McpCheckItem -Target $targetName -Name $server.Name -Status 'ok' -Expected $expectedText)) }
                'differs' { $items.Add((New-McpCheckItem -Target $targetName -Name $server.Name -Status 'mismatch' -Expected $expectedText -Detail (Get-ClaudeMcpPlanMessage -Item $planItem))) }
                default {
                    $detail = if ($server.Type -eq 'http') { '未登記；執行 Register-McpServer.ps1 -McpLab 登記' } else { '未登記；執行 Register-McpServer.ps1 -InfraLab -InfraLabDistro <發行版> -InfraLabWslRepo <WSL 內路徑> 登記（值取自 WSL 內 task mcp:config 印出的命令）' }
                    $items.Add((New-McpCheckItem -Target $targetName -Name $server.Name -Status 'missing' -Expected $expectedText -Detail $detail))
                }
            }
        }
    }

    if ($Group -contains 'mcp-lab') {
        try {
            $httpServers = @($template | Where-Object { $_.Type -eq 'http' })
            $ports = @($httpServers | ForEach-Object { ([uri]$_.Url).Port } | Sort-Object -Unique)
            if ($ports.Count -gt 0) {
                $openMap = Get-TcpPortOpenMap -Port $ports -TimeoutMs 500
                $closedNames = @($httpServers | Where-Object { -not $openMap[([uri]$_.Url).Port] } | ForEach-Object { $_.Name })
                if ($closedNames.Count -gt 0) {
                    $Note.Add(('mcp-lab 的 ' + $closedNames.Count + ' 個埠無回應（' + ($closedNames -join '、') + '）；依 mcp-lab repo 的 README 啟動服務。服務未啟動不影響本檢查的結果。'))
                }
            }
        }
        catch { $Note.Add('mcp-lab 服務的連接埠探測失敗：' + $_.Exception.Message) }
    }
    if ($Group -contains 'infra-lab') {
        if ((Get-WslStatus) -ceq 'ok') { $items.Add((New-McpCheckItem -Target 'infra-lab' -Name 'wsl' -Status 'ok' -Expected 'wsl --status 結束碼 0')) }
        else { $items.Add((New-McpCheckItem -Target 'infra-lab' -Name 'wsl' -Status 'missing' -Expected 'wsl --status 結束碼 0' -Detail '找不到可用的 WSL（找不到 wsl 命令，或 wsl --status 的結束碼非零）；以系統管理員身分執行 wsl --install 並重新開機，詳見 https://learn.microsoft.com/windows/wsl/install')) }
    }
    return @($items.ToArray())
}

function Invoke-McpRegistrationCheck {
    # 唯讀檢查：回報所選項目是否已登記，不寫入任何檔案。全部符合回傳 0，否則回傳 1；備註（服務未啟動、執行檔不存在）不影響結果。
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('mcp-lab', 'infra-lab', 'flaui')][string[]]$Target,
        [Parameter(Mandatory)][string]$McpTemplatePath,
        [Parameter(Mandatory)][string]$UserMcpPath,
        [Parameter(Mandatory)][string]$CodexConfigPath,
        [Parameter(Mandatory)][string]$FlaUIPath,
        [AllowNull()][AllowEmptyString()][string]$InfraLabDistro,
        [AllowNull()][AllowEmptyString()][string]$InfraLabWslRepo,
        # .local\machine.json 的路徑；FlaUI 檢查時一併檢查其 codex_accounts 登記的派工帳號。省略或檔案不存在時只檢查桌面版。
        [AllowNull()][AllowEmptyString()][string]$MachineConfigPath
    )

    $notes = New-Object 'System.Collections.Generic.List[string]'
    $items = New-Object 'System.Collections.Generic.List[object]'
    $claudeGroups = @($Target | Where-Object { $_ -ne 'flaui' })
    if ($claudeGroups.Count -gt 0) {
        foreach ($item in @(Get-ClaudeMcpCheckItem -Group $claudeGroups -McpTemplatePath $McpTemplatePath -UserMcpPath $UserMcpPath -InfraLabDistro $InfraLabDistro -InfraLabWslRepo $InfraLabWslRepo -Note $notes)) { $items.Add($item) }
    }
    if ($Target -contains 'flaui') {
        $items.Add((Get-FlaUIMcpCheckItem -ConfigPath $CodexConfigPath -ExecutablePath $FlaUIPath -Note $notes))
        foreach ($accountItem in @(Get-FlaUIAccountCheckItem -MachineConfigPath $MachineConfigPath -DesktopConfigPath $CodexConfigPath -Note $notes)) { $items.Add($accountItem) }
    }

    $label = @{ ok = '符合'; missing = '缺少'; mismatch = '內容不符'; unknown = '無法判定' }
    Write-Host "`n>>> MCP 登記唯讀檢查：只讀取現況，不寫入任何檔案。" -ForegroundColor Cyan
    foreach ($group in @('mcp-lab', 'infra-lab', 'flaui', 'claude')) {
        $groupItems = @($items | Where-Object { $_.Target -ceq $group })
        if ($groupItems.Count -eq 0) { continue }
        Write-Host ("`n" + $(switch ($group) { 'mcp-lab' { 'mcp-lab（Claude Code）' } 'infra-lab' { 'infra-lab（Claude Code）' } 'flaui' { 'FlaUI.Mcp（Codex 桌面版與派工帳號）' } default { 'Claude Code' } })) -ForegroundColor Cyan
        foreach ($item in $groupItems) {
            $color = switch ($item.Status) { 'ok' { 'DarkGreen' } 'unknown' { 'Yellow' } default { 'Red' } }
            $line = '  [' + $label[$item.Status] + '] ' + $item.Name
            if ($item.Status -cne 'ok') {
                if (-not [string]::IsNullOrEmpty($item.Expected)) { $line += '；預期：' + $item.Expected }
                if (-not [string]::IsNullOrEmpty($item.Detail)) { $line += '；' + $item.Detail }
            }
            Write-Host $line -ForegroundColor $color
        }
    }
    foreach ($noteText in $notes) { Write-Host ("`n備註：" + $noteText) -ForegroundColor DarkGray }
    $notOk = @($items | Where-Object { $_.Status -cne 'ok' }).Count
    Write-Host ''
    Write-Host ('統計：共 {0} 項，符合 {1}、其他 {2}。' -f $items.Count, ($items.Count - $notOk), $notOk) -ForegroundColor $(if ($notOk -eq 0) { 'Green' } else { 'Yellow' })
    if ($notOk -gt 0) { return 1 }
    return 0
}

function Invoke-McpRegistration {
    # 登記所選項目，只寫設定。回傳 Problems（沒有完成的項目數，腳本以此決定結束碼）與各項結果。
    # differs（已登記但與範本不同）只回報、保留現有登記，不算問題；失敗、缺值、FlaUI 執行檔或設定檔不存在、設定檔寫法無法確定算問題。
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateSet('mcp-lab', 'infra-lab', 'flaui')][string[]]$Target,
        [Parameter(Mandatory)][string]$McpTemplatePath,
        [Parameter(Mandatory)][string]$UserMcpPath,
        [Parameter(Mandatory)][string]$CodexConfigPath,
        [Parameter(Mandatory)][string]$FlaUIPath,
        [Parameter(Mandatory)][string]$BackupRoot,
        [AllowNull()][AllowEmptyString()][string]$InfraLabDistro,
        [AllowNull()][AllowEmptyString()][string]$InfraLabWslRepo,
        # .local\machine.json 的路徑；FlaUI 寫入完成後一併處理其 codex_accounts 登記的派工帳號。省略或檔案不存在時只處理桌面版。
        [AllowNull()][AllowEmptyString()][string]$MachineConfigPath
    )

    $problems = 0
    $claudeResults = @()
    $flauiResult = $null
    $accountResults = @()
    $backupContext = New-ConfigBackupContext
    $claudeGroups = @($Target | Where-Object { $_ -ne 'flaui' })
    if ($claudeGroups.Count -gt 0) {
        Write-Host "`n>>> 正在登記 Claude Code 的 MCP 伺服器（$($claudeGroups -join '、')）..." -ForegroundColor Cyan
        try {
            if ($claudeGroups -contains 'infra-lab' -and (Get-WslStatus) -cne 'ok') {
                Write-Warning '找不到可用的 WSL（找不到 wsl 命令，或 wsl --status 的結束碼非零）。登記只寫設定，仍會繼續；infra-lab 要等 WSL 可用才能啟動。'
            }
            $claudeResults = @(Invoke-ClaudeMcpStep -McpTemplatePath $McpTemplatePath -UserMcpPath $UserMcpPath -InfraLabDistro $InfraLabDistro -InfraLabWslRepo $InfraLabWslRepo -Group $claudeGroups -WhatIf:$WhatIfPreference)
            $problems += @($claudeResults | Where-Object { $_.Status -in @('failed', 'needs-values') }).Count
        }
        catch {
            Write-Warning $_.Exception.Message
            $problems++
        }
    }
    if ($Target -contains 'flaui') {
        Write-Host "`n>>> 正在寫入 Codex 桌面版的 flaui-mcp 指令..." -ForegroundColor Cyan
        $flauiResult = Set-FlaUIMcpCommand -ConfigPath $CodexConfigPath -ExecutablePath $FlaUIPath -BackupRoot $BackupRoot -BackupContext $backupContext -WhatIf:$WhatIfPreference
        switch ($flauiResult.Status) {
            { $_ -in @('added', 'updated') } { Write-Host ('  ✅  ' + $flauiResult.Message) -ForegroundColor DarkGreen; if ($flauiResult.BackupPath) { Write-Host ('    原檔備份：' + $flauiResult.BackupPath) } }
            'unchanged' { Write-Host ('  ' + $flauiResult.Message) -ForegroundColor DarkGray }
            'whatif' { Write-Host ('  ' + $flauiResult.Message) }
            default { Write-Warning $flauiResult.Message; $problems++ }
        }

        # 摘要的內容：桌面版的結果與派工帳號的件數。訊息只含路徑、帳號名稱與原因，不印出設定檔的其他內容。
        $desktopLabel = switch ($flauiResult.Status) { 'added' { '新增' } 'updated' { '更新' } 'unchanged' { '未變更' } 'whatif' { '預覽（未寫入）' } default { '未完成' } }
        $accountSummary = '派工帳號 未處理'
        $accountUpdated = 0
        $accountUnchanged = 0
        $accountSkipped = 0
        $accountPreview = 0

        # 派工帳號：桌面版已是指定路徑（寫入、已相符或預演）時才處理，讓帳號與桌面版一致；桌面版沒有完成時不動帳號，避免兩邊分歧。
        if ($flauiResult.Status -in @('added', 'updated', 'unchanged', 'whatif')) {
            $registered = Get-FlaUIRegisteredAccount -MachineConfigPath $MachineConfigPath
            if ($null -ne $registered.Error) {
                Write-Warning ('派工帳號登記無法讀取，桌面版已處理完成，但全部派工帳號都沒有更新。原因：' + $registered.Error + "。請修正登記檔 ${MachineConfigPath}（主 checkout 的 .local\machine.json）的登記，或補回該帳號目錄，之後重新執行同一個命令。")
                $accountSummary = '派工帳號 全部略過（登記無法讀取）'
                $problems++
            }
            elseif ($registered.Accounts.Count -eq 0) {
                Write-Host '  沒有登記的派工帳號（.local\machine.json 不存在或沒有 codex_accounts），只處理桌面版。' -ForegroundColor DarkGray
                $accountSummary = '派工帳號 沒有登記'
            }
            else {
                Write-Host "`n>>> 正在處理派工帳號的 flaui-mcp 指令..." -ForegroundColor Cyan
                $accountList = New-Object 'System.Collections.Generic.List[object]'
                foreach ($account in $registered.Accounts) {
                    $accountResult = Set-FlaUIMcpAccountCommand -AccountName $account.name -AccountHome $account.codex_home -ExecutablePath $FlaUIPath -SourceConfigPath $CodexConfigPath -BackupRoot $BackupRoot -BackupContext $backupContext -WhatIf:$WhatIfPreference
                    $accountList.Add($accountResult)
                    switch ($accountResult.Status) {
                        { $_ -in @('added', 'updated') } { $accountUpdated++; Write-Host ('  ✅  ' + $accountResult.Message) -ForegroundColor DarkGreen; if ($accountResult.BackupPath) { Write-Host ('    原檔備份：' + $accountResult.BackupPath) } }
                        'unchanged' { $accountUnchanged++; Write-Host ('  ' + $accountResult.Message) -ForegroundColor DarkGray }
                        'whatif' { $accountPreview++; Write-Host ('  ' + $accountResult.Message) }
                        default {
                            $accountSkipped++
                            Write-Warning ("派工帳號 $($account.name) 被略過，其他帳號照常處理。原因：" + $accountResult.Message)
                            $problems++
                        }
                    }
                }
                $accountResults = @($accountList.ToArray())
                $accountSummary = if ($WhatIfPreference) { "派工帳號 預覽將更新 $accountPreview、未變更 $accountUnchanged、略過 $accountSkipped" } else { "派工帳號 已更新 $accountUpdated、未變更 $accountUnchanged、略過 $accountSkipped" }
            }
        }
        else {
            Write-Warning '桌面版的 flaui-mcp 沒有完成，派工帳號沒有被更動。請排除上面桌面版的問題後，重新執行同一個命令。'
        }
        $summaryPrefix = if ($WhatIfPreference) { 'FlaUI 摘要（預覽，沒有寫入任何檔案）' } else { 'FlaUI 摘要' }
        Write-Host ("`n${summaryPrefix}：桌面版 $desktopLabel；$accountSummary。") -ForegroundColor $(if ($problems -eq 0) { 'Green' } else { 'Yellow' })
    }
    return [pscustomobject]@{ Problems = $problems; ClaudeResults = $claudeResults; FlaUIResult = $flauiResult; AccountResults = $accountResults }
}
