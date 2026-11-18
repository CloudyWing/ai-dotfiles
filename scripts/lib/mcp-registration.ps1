#Requires -Version 7.0
# MCP 登記腳本（Register-McpServer.ps1）的實際內容：mcp-lab 與 infra-lab 登記到 Claude Code 使用者層，FlaUI.Mcp 的指令寫入 Codex 桌面版設定檔，以及三者的唯讀檢查。
# 由 Register-McpServer.ps1 在版本判斷之後以 dot-source 載入，只定義函式，不在載入時執行任何動作。
# 本檔使用 lib\claude-user-config.ps1 的函式（範本讀取、登記計畫、Claude CLI 呼叫、WSL 與連接埠探測），
# 以及 codex-run\45-profile-sync.ps1 的 Read-CodexAccountConfigState、Test-CodexMcpServerMentioned（讀取 TOML 設定檔的編碼與行尾、判斷伺服器是否可能已被定義）。
# 寫入邊界：Claude 端只經 claude mcp add（Invoke-ClaudeMcpStep）；Codex 桌面版設定檔只在 Set-FlaUIMcpCommand 內寫入，寫入前備份，
# 只新增或更新 [mcp_servers.flaui-mcp] 的 command，其餘位元組不變；不建立設定檔，不刪除 .codex 目錄下的任何檔案（暫存檔只在該函式內建立並取代原檔）。

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

function Set-FlaUIMcpCommand {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$BackupRoot
    )

    # 回傳 Status：added（新增表）、updated（更新 command）、unchanged、whatif、executable-missing、config-missing、blocked、failed；
    # 只有 added 與 updated 寫入檔案。任何無法確定的狀態一律不寫。
    $outcome = { param($Status, $Message, $BackupPath) [pscustomobject]@{ Status = $Status; Message = $Message; BackupPath = $BackupPath } }

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

    $newline = $state.Newline
    $text = $state.Text
    $newText = $null
    $status = $null
    if ($state.Kind -eq 'present') {
        if ([string]::Equals($state.CommandValue, $ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return (& $outcome 'unchanged' 'flaui-mcp 的 command 已是指定的執行檔路徑，未寫入' $null)
        }
        $token = ConvertTo-FlaUITomlString -Value $ExecutablePath -Style $state.ValueStyle
        $newText = $text.Substring(0, $state.ValueIndex) + $token + $text.Substring($state.ValueIndex + $state.ValueLength)
        $status = 'updated'
    }
    elseif ($state.Kind -eq 'no-command') {
        $newText = $text.Insert($state.HeaderEnd, ('command = ' + (ConvertTo-FlaUITomlString -Value $ExecutablePath) + $newline))
        $status = 'updated'
    }
    else {
        $append = ''
        if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $append += $newline }
        $append += $newline + '[mcp_servers.flaui-mcp]' + $newline + ('command = ' + (ConvertTo-FlaUITomlString -Value $ExecutablePath)) + $newline + 'startup_timeout_sec = 60.0' + $newline
        $newText = $text + $append
        $status = 'added'
    }

    if (-not $PSCmdlet.ShouldProcess($ConfigPath, 'Codex 桌面版設定檔的 flaui-mcp：寫入 command')) {
        return (& $outcome 'whatif' ("預演：將在 $ConfigPath 的 [mcp_servers.flaui-mcp] " + $(if ($status -eq 'added') { '新增 command 與 startup_timeout_sec' } else { '更新 command' }) + '，未寫入任何檔案') $null)
    }

    $backupPath = $null
    $temporaryPath = $null
    try {
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $backupDirectory = Join-Path $BackupRoot $stamp
        $suffix = 0
        while (Test-Path -LiteralPath $backupDirectory) { $suffix++; $backupDirectory = Join-Path $BackupRoot ('{0}_{1}' -f $stamp, $suffix) }
        New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
        $backupPath = Join-Path $backupDirectory 'config.toml'
        Copy-Item -LiteralPath $ConfigPath -Destination $backupPath
        if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw '備份檔寫入後不存在。' }
        $manifestLine = ((Get-Date -Format o) + " | $ConfigPath | 寫入 Codex 桌面版 flaui-mcp 的 command`n")
        [IO.File]::WriteAllText((Join-Path $backupDirectory 'manifest.txt'), $manifestLine, (New-Object System.Text.UTF8Encoding($false)))

        $encoding = New-Object System.Text.UTF8Encoding($false)
        $bodyBytes = $encoding.GetBytes($newText)
        $bytes = if ($state.HasBom) { [byte[]](0xEF, 0xBB, 0xBF) + $bodyBytes } else { $bodyBytes }
        $temporaryPath = $ConfigPath + '.tmp-' + [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllBytes($temporaryPath, $bytes)
        [IO.File]::Move($temporaryPath, $ConfigPath, $true)
        $temporaryPath = $null
        $written = [IO.File]::ReadAllBytes($ConfigPath)
        if ([Convert]::ToBase64String($written) -cne [Convert]::ToBase64String($bytes)) { throw '寫入後讀回的內容與預期不同，請以備份還原。' }
    }
    catch {
        if ($null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
        return (& $outcome 'failed' ("寫入失敗：{0}" -f $_.Exception.Message) $backupPath)
    }
    $message = if ($status -eq 'added') { "已在 $ConfigPath 新增 [mcp_servers.flaui-mcp]" } else { "已更新 $ConfigPath 的 flaui-mcp command" }
    return (& $outcome $status $message $backupPath)
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
        [AllowNull()][AllowEmptyString()][string]$InfraLabWslRepo
    )

    $notes = New-Object 'System.Collections.Generic.List[string]'
    $items = New-Object 'System.Collections.Generic.List[object]'
    $claudeGroups = @($Target | Where-Object { $_ -ne 'flaui' })
    if ($claudeGroups.Count -gt 0) {
        foreach ($item in @(Get-ClaudeMcpCheckItem -Group $claudeGroups -McpTemplatePath $McpTemplatePath -UserMcpPath $UserMcpPath -InfraLabDistro $InfraLabDistro -InfraLabWslRepo $InfraLabWslRepo -Note $notes)) { $items.Add($item) }
    }
    if ($Target -contains 'flaui') { $items.Add((Get-FlaUIMcpCheckItem -ConfigPath $CodexConfigPath -ExecutablePath $FlaUIPath -Note $notes)) }

    $label = @{ ok = '符合'; missing = '缺少'; mismatch = '內容不符'; unknown = '無法判定' }
    Write-Host "`n>>> MCP 登記唯讀檢查：只讀取現況，不寫入任何檔案。" -ForegroundColor Cyan
    foreach ($group in @('mcp-lab', 'infra-lab', 'flaui', 'claude')) {
        $groupItems = @($items | Where-Object { $_.Target -ceq $group })
        if ($groupItems.Count -eq 0) { continue }
        Write-Host ("`n" + $(switch ($group) { 'mcp-lab' { 'mcp-lab（Claude Code）' } 'infra-lab' { 'infra-lab（Claude Code）' } 'flaui' { 'FlaUI.Mcp（Codex 桌面版）' } default { 'Claude Code' } })) -ForegroundColor Cyan
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
        [AllowNull()][AllowEmptyString()][string]$InfraLabWslRepo
    )

    $problems = 0
    $claudeResults = @()
    $flauiResult = $null
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
        $flauiResult = Set-FlaUIMcpCommand -ConfigPath $CodexConfigPath -ExecutablePath $FlaUIPath -BackupRoot $BackupRoot -WhatIf:$WhatIfPreference
        switch ($flauiResult.Status) {
            { $_ -in @('added', 'updated') } { Write-Host ('  ✅  ' + $flauiResult.Message) -ForegroundColor DarkGreen; if ($flauiResult.BackupPath) { Write-Host ('    原檔備份：' + $flauiResult.BackupPath) } }
            'unchanged' { Write-Host ('  ' + $flauiResult.Message) -ForegroundColor DarkGray }
            'whatif' { Write-Host ('  ' + $flauiResult.Message) }
            default { Write-Warning $flauiResult.Message; $problems++ }
        }
        if ($flauiResult.Status -in @('added', 'updated', 'whatif')) {
            Write-Host '  Setup 會把桌面版的 flaui-mcp 指令複製到派工帳號目錄；帳號目錄已有 command 時不會更新，見 README。'
        }
    }
    return [pscustomobject]@{ Problems = $problems; ClaudeResults = $claudeResults; FlaUIResult = $flauiResult }
}
