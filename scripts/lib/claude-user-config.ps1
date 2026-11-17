#Requires -Version 7.0
# Claude Code 使用者層設定模組：MCP 登記範本與計畫、官方外掛安裝、settings.json 合併、前置軟體與連接埠探測。
# 由 Setup-AIGlobalConfig.ps1 在版本判斷之後以 dot-source 載入，只定義函式，不在載入時執行任何動作。
# 本檔使用 Setup 已定義的 Invoke-ClaudeCli、Get-ClaudeList、Get-ClaudeProperty。
# 寫入邊界：MCP 登記只經 Claude CLI 的 mcp add 子命令；使用者層登記檔只做唯讀讀取，且一律以 -AsHashTable 剖析（該檔含僅大小寫不同的鍵）。
# 檔案寫入只發生在 Invoke-ClaudeSettingsApply（備份、manifest.txt、暫存檔與取代 settings.json）。

function ConvertFrom-ClaudeUserConfigJson {
    # 統一的 JSON 剖析：根為陣列時不展開；支援 DateKind 的版本以字串保留日期樣式的值，避免序列化時改寫格式。
    param(
        [Parameter(Mandatory)][string]$Text,
        [switch]$AsHashTable
    )

    $parameters = @{ InputObject = $Text; NoEnumerate = $true; ErrorAction = 'Stop' }
    if ($AsHashTable) { $parameters['AsHashTable'] = $true }
    if ((Get-Command -Name 'ConvertFrom-Json').Parameters.ContainsKey('DateKind')) { $parameters['DateKind'] = 'String' }
    return ConvertFrom-Json @parameters
}

function Test-ClaudeUserConfigJsonObject {
    # -is [pscustomobject] 對以 PSObject 包裝的陣列也為 true，改以實際型別判定。
    param($Value)
    return ($null -ne $Value) -and ($Value.GetType().FullName -ceq 'System.Management.Automation.PSCustomObject')
}

function Test-ClaudeUserConfigJsonNumber {
    param($Value)
    return ($null -ne $Value) -and ($Value -is [ValueType]) -and ($Value -isnot [bool]) -and ($Value -isnot [datetime]) -and ($Value -isnot [char])
}

function Test-ClaudeUserConfigJsonEqual {
    param($Left, $Right)

    if ($null -eq $Left -and $null -eq $Right) { return $true }
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    if (Test-ClaudeUserConfigJsonObject $Left) {
        if (-not (Test-ClaudeUserConfigJsonObject $Right)) { return $false }
        $leftNames = @($Left.PSObject.Properties | ForEach-Object { $_.Name })
        $rightNames = @($Right.PSObject.Properties | ForEach-Object { $_.Name })
        if ($leftNames.Count -ne $rightNames.Count) { return $false }
        foreach ($name in $leftNames) {
            if ($rightNames -cnotcontains $name) { return $false }
            if (-not (Test-ClaudeUserConfigJsonEqual $Left.PSObject.Properties[$name].Value $Right.PSObject.Properties[$name].Value)) { return $false }
        }
        return $true
    }
    if ($Left -is [array]) {
        if ($Right -isnot [array] -or $Left.Count -ne $Right.Count) { return $false }
        for ($i = 0; $i -lt $Left.Count; $i++) {
            if (-not (Test-ClaudeUserConfigJsonEqual $Left[$i] $Right[$i])) { return $false }
        }
        return $true
    }
    if ($Left -is [string]) { return ($Right -is [string]) -and ($Left -ceq $Right) }
    if ($Left -is [bool]) { return ($Right -is [bool]) -and ($Left -eq $Right) }
    if (Test-ClaudeUserConfigJsonNumber $Left) { return (Test-ClaudeUserConfigJsonNumber $Right) -and ([double]$Left -eq [double]$Right) }
    return $Left -ceq $Right
}

function Copy-ClaudeUserConfigNode {
    # 深層複製 ConvertFrom-Json 產生的節點（物件、陣列、純量），回傳新節點，不共用參考。
    param($Node)

    if ($null -eq $Node) { return $null }
    if (Test-ClaudeUserConfigJsonObject $Node) {
        $copy = [pscustomobject]@{}
        foreach ($property in $Node.PSObject.Properties) {
            $copy | Add-Member -NotePropertyName $property.Name -NotePropertyValue (Copy-ClaudeUserConfigNode $property.Value)
        }
        return $copy
    }
    if ($Node -is [array]) {
        $items = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $Node) { $items.Add((Copy-ClaudeUserConfigNode $item)) }
        return , $items.ToArray()
    }
    return $Node
}

function Read-ClaudeMcpTemplate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "找不到 MCP 範本：$Path" }
    try { $document = ConvertFrom-ClaudeUserConfigJson -Text ([IO.File]::ReadAllText($Path)) -AsHashTable }
    catch { throw "MCP 範本無法剖析為 JSON：$($_.Exception.Message)" }
    if ($document -isnot [System.Collections.IDictionary] -or -not $document.ContainsKey('servers') -or $document['servers'] -isnot [array]) {
        throw 'MCP 範本的根必須是含 servers 陣列的物件。'
    }

    $allowedKeys = @('name', 'type', 'url', 'command', 'args')
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $servers = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $document['servers']) {
        if ($entry -isnot [System.Collections.IDictionary]) { throw 'MCP 範本的 servers 項目必須是物件。' }
        foreach ($key in $entry.Keys) {
            if ($allowedKeys -cnotcontains $key) { throw "MCP 範本含不允許的欄位：$key" }
        }
        $name = if ($entry.ContainsKey('name')) { $entry['name'] } else { $null }
        if ($name -isnot [string] -or $name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\z') { throw 'MCP 範本的 name 缺少或格式不正確。' }
        if (-not $seen.Add($name)) { throw "MCP 範本的名稱重複：$name" }
        $type = if ($entry.ContainsKey('type')) { $entry['type'] } else { $null }
        if ($type -ceq 'http') {
            $url = if ($entry.ContainsKey('url')) { $entry['url'] } else { $null }
            if ($url -isnot [string] -or $url -cnotmatch '^http://127\.0\.0\.1:\d{2,5}/mcp\z') { throw "MCP 範本 $name 的 url 必須是 http://127.0.0.1:<埠號>/mcp。" }
            if ($entry.ContainsKey('command') -or $entry.ContainsKey('args')) { throw "MCP 範本 $name 為 http，不得含 command 或 args。" }
            $servers.Add([pscustomobject]@{ Name = $name; Type = 'http'; Url = $url; Command = $null; Args = @() })
        }
        elseif ($type -ceq 'stdio') {
            $command = if ($entry.ContainsKey('command')) { $entry['command'] } else { $null }
            $arguments = if ($entry.ContainsKey('args')) { $entry['args'] } else { $null }
            if ($command -isnot [string] -or [string]::IsNullOrWhiteSpace($command)) { throw "MCP 範本 $name 缺少 command。" }
            if ($arguments -isnot [array] -or $arguments.Count -eq 0) { throw "MCP 範本 $name 缺少 args。" }
            foreach ($argument in $arguments) {
                if ($argument -isnot [string]) { throw "MCP 範本 $name 的 args 只能是字串。" }
            }
            if ($entry.ContainsKey('url')) { throw "MCP 範本 $name 為 stdio，不得含 url。" }
            $servers.Add([pscustomobject]@{ Name = $name; Type = 'stdio'; Url = $null; Command = $command; Args = @($arguments) })
        }
        else { throw "MCP 範本 $name 的 type 必須是 http 或 stdio。" }
    }
    return $servers.ToArray()
}

function Get-ClaudeUserMcpServer {
    [CmdletBinding()]
    param([string]$Path = (Join-Path $env:USERPROFILE '.claude.json'))

    $result = [pscustomobject]@{ Exists = $false; Servers = @{}; Error = $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    $result.Exists = $true
    try { $document = ConvertFrom-ClaudeUserConfigJson -Text ([IO.File]::ReadAllText($Path)) -AsHashTable }
    catch { $result.Error = 'parse'; return $result }
    if ($document -isnot [System.Collections.IDictionary]) { $result.Error = 'not-object'; return $result }
    if (-not $document.ContainsKey('mcpServers')) { return $result }
    $servers = $document['mcpServers']
    if ($servers -isnot [System.Collections.IDictionary]) { $result.Error = 'not-object'; return $result }
    $result.Servers = $servers
    return $result
}

function Test-ClaudeMcpInfraLabValue {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Distro,
        [AllowNull()][AllowEmptyString()][string]$WslRepo
    )

    # 白名單之外的字元一律拒絕（含空白、引號、反斜線、& | < > ^ %、控制字元）。claude 可能是 .cmd 外殼，避免命令列注入。
    # 結尾以 \z 判定，$ 會放行結尾的換行。
    if ([string]::IsNullOrEmpty($Distro) -or [string]::IsNullOrEmpty($WslRepo)) { return $false }
    if ($Distro -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z') { return $false }
    if ($WslRepo -cnotmatch '^/[A-Za-z0-9._/@+~-]{0,255}\z') { return $false }
    if ($WslRepo.EndsWith('/')) { return $false }
    return $true
}

function Get-ClaudeMcpEntryValue {
    # 取使用者層登記項目的欄位值；項目不是物件或欄位不存在時回傳 $null。
    param($Entry, [string]$Name)

    if ($Entry -isnot [System.Collections.IDictionary]) { return $null }
    if (-not $Entry.Contains($Name)) { return $null }
    return $Entry[$Name]
}

function Get-ClaudeMcpStdioArguments {
    # 以範本的 args 代入佔位符，回傳實際要傳給伺服器命令的引數。
    param($Server, [string]$Distro, [string]$WslRepo)

    $values = New-Object 'System.Collections.Generic.List[string]'
    foreach ($argument in $Server.Args) {
        $values.Add($argument.Replace('{distro}', $Distro).Replace('{wslRepo}', $WslRepo))
    }
    return $values.ToArray()
}

function Get-ClaudeMcpPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Template,
        [AllowNull()]$Existing,
        [AllowNull()][AllowEmptyString()][string]$Distro,
        [AllowNull()][AllowEmptyString()][string]$WslRepo
    )

    $plan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($server in $Template) {
        $name = $server.Name
        $differing = New-Object 'System.Collections.Generic.List[string]'
        $action = 'unchanged'
        $arguments = $null
        $exists = ($null -ne $Existing) -and ($Existing -is [System.Collections.IDictionary]) -and $Existing.Contains($name)

        if ($server.Type -eq 'http') {
            if (-not $exists) {
                $action = 'add'
                $arguments = @('mcp', 'add', '--transport', 'http', '--scope', 'user', $name, $server.Url)
            }
            else {
                $entry = $Existing[$name]
                $entryType = Get-ClaudeMcpEntryValue $entry 'type'
                $entryUrl = Get-ClaudeMcpEntryValue $entry 'url'
                if ($entryType -isnot [string] -or $entryType -cne 'http') { $differing.Add('type') }
                if ($entryUrl -isnot [string] -or $entryUrl -ne $server.Url) { $differing.Add('url') }
            }
        }
        else {
            $valuesValid = Test-ClaudeMcpInfraLabValue -Distro $Distro -WslRepo $WslRepo
            if (-not $exists) {
                if ($valuesValid) {
                    $action = 'add'
                    $arguments = @('mcp', 'add', '--transport', 'stdio', '--scope', 'user', $name, '--', $server.Command) + @(Get-ClaudeMcpStdioArguments -Server $server -Distro $Distro -WslRepo $WslRepo)
                }
                else { $action = 'needs-values' }
            }
            else {
                $entry = $Existing[$name]
                $entryType = Get-ClaudeMcpEntryValue $entry 'type'
                $entryCommand = Get-ClaudeMcpEntryValue $entry 'command'
                $entryArgs = Get-ClaudeMcpEntryValue $entry 'args'
                if ($entryType -isnot [string] -or $entryType -cne 'stdio') { $differing.Add('type') }
                $commandLeaf = if ($entryCommand -is [string]) { $entryCommand.Replace('/', '\').Split('\')[-1] } else { $null }
                if ($null -eq $commandLeaf -or $commandLeaf -ine $server.Command) { $differing.Add('command') }
                $argsShapeOk = ($entryArgs -is [array]) -and ($entryArgs.Count -eq 5)
                if ($argsShapeOk) {
                    foreach ($item in $entryArgs) { if ($item -isnot [string]) { $argsShapeOk = $false } }
                }
                if ($argsShapeOk) {
                    $argsShapeOk = ($entryArgs[0] -ceq '-d') -and ($entryArgs[2] -ceq '-e') -and ($entryArgs[3] -ceq 'bash') -and
                    $entryArgs[4].StartsWith('/') -and $entryArgs[4].EndsWith('/scripts/mcp.sh')
                }
                $argsMatchesProvided = $true
                if ($argsShapeOk) {
                    if (-not [string]::IsNullOrEmpty($Distro) -and $entryArgs[1] -cne $Distro) { $argsMatchesProvided = $false }
                    if (-not [string]::IsNullOrEmpty($WslRepo) -and $entryArgs[4] -cne ($WslRepo + '/scripts/mcp.sh')) { $argsMatchesProvided = $false }
                }
                if (-not $argsShapeOk -or -not $argsMatchesProvided) { $differing.Add('args') }
            }
        }

        if ($action -eq 'unchanged' -and $differing.Count -gt 0) { $action = 'differs' }
        $plan.Add([pscustomobject]@{
                Name           = $name
                Action         = $action
                DifferingField = $differing.ToArray()
                Arguments      = $arguments
            })
    }
    return $plan.ToArray()
}

function Get-ClaudeMcpPlanMessage {
    # differs 與 needs-values 的固定說明文字，不印出現有值（現有值可能含使用者加入的權杖）。
    param([Parameter(Mandatory)]$Item)

    if ($Item.Action -eq 'differs') {
        $fields = @($Item.DifferingField) -join '、'
        return "$($Item.Name) 的 $fields 與範本不同，保留現有登記；要改用範本時，先執行 claude mcp remove $($Item.Name) --scope user 再重跑 Setup"
    }
    if ($Item.Action -eq 'needs-values') {
        return "$($Item.Name) 尚未登記，且缺少或未通過驗證的 -InfraLabDistro、-InfraLabWslRepo；值取自在 WSL 內執行 task mcp:config 時印出的命令，補上兩個參數後重跑 Setup"
    }
    return ''
}

function Invoke-ClaudeMcpRegister {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object[]]$Plan)

    $results = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $Plan) {
        if ($item.Action -ne 'add') {
            $results.Add([pscustomobject]@{ Name = $item.Name; Status = $item.Action; Message = (Get-ClaudeMcpPlanMessage -Item $item) })
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($item.Name, '登記 MCP 伺服器（使用者層）')) {
            $results.Add([pscustomobject]@{ Name = $item.Name; Status = 'whatif'; Message = '預演，未執行' })
            continue
        }
        try {
            $outcome = Invoke-ClaudeCli -Arguments $item.Arguments
            if ($null -eq $outcome) { throw '找不到 claude 命令。' }
            if ($outcome.ExitCode -ne 0) { throw ("結束碼 {0}：{1}" -f $outcome.ExitCode, $outcome.Output.Trim()) }
            $results.Add([pscustomobject]@{ Name = $item.Name; Status = 'added'; Message = '' })
        }
        catch {
            $results.Add([pscustomobject]@{ Name = $item.Name; Status = 'failed'; Message = $_.Exception.Message })
        }
    }
    return $results.ToArray()
}

function Get-ClaudeRequiredOfficialPlugin {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TemplatePath)

    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) { return @() }
    $template = ConvertFrom-ClaudeUserConfigJson -Text ([IO.File]::ReadAllText($TemplatePath)) -AsHashTable
    if ($template -isnot [System.Collections.IDictionary] -or -not $template.Contains('enabledPlugins')) { return @() }
    $plugins = $template['enabledPlugins']
    if ($plugins -isnot [System.Collections.IDictionary]) { return @() }
    $required = New-Object 'System.Collections.Generic.List[string]'
    foreach ($id in $plugins.Keys) {
        if ($plugins[$id] -is [bool] -and $plugins[$id] -and ([string]$id).EndsWith('@claude-plugins-official', [System.StringComparison]::OrdinalIgnoreCase)) {
            $required.Add([string]$id)
        }
    }
    return $required.ToArray()
}

function Install-ClaudeOfficialPlugin {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$PluginId)

    $marketplaceName = 'claude-plugins-official'
    $skipped = $false
    try {
        $marketplaces = Get-ClaudeList @('plugin', 'marketplace', 'list', '--json')
        $marketplaceFound = @($marketplaces | Where-Object { (Get-ClaudeProperty $_ 'name') -eq $marketplaceName }).Count -gt 0
        if (-not $marketplaceFound) {
            if ($PSCmdlet.ShouldProcess($marketplaceName, '新增官方 marketplace')) {
                $outcome = Invoke-ClaudeCli -Arguments @('plugin', 'marketplace', 'add', 'anthropics/claude-plugins-official')
                if ($null -eq $outcome -or $outcome.ExitCode -ne 0) { throw ("plugin marketplace add 失敗：{0}" -f $(if ($null -eq $outcome) { '找不到 claude 命令。' } else { $outcome.Output.Trim() })) }
            }
            else { $skipped = $true }
        }

        $plugins = Get-ClaudeList @('plugin', 'list', '--json')
        $installed = @($plugins | Where-Object { (Get-ClaudeProperty $_ 'id') -eq $PluginId })
        if ($installed.Count -eq 0) {
            if (-not $PSCmdlet.ShouldProcess($PluginId, '安裝外掛')) { return [pscustomobject]@{ Status = 'whatif'; Message = '預演，未執行' } }
            $outcome = Invoke-ClaudeCli -Arguments @('plugin', 'install', $PluginId, '--scope', 'user')
            if ($null -eq $outcome -or $outcome.ExitCode -ne 0) { throw ("plugin install 失敗：{0}" -f $(if ($null -eq $outcome) { '找不到 claude 命令。' } else { $outcome.Output.Trim() })) }
            return [pscustomobject]@{ Status = 'installed'; Message = '' }
        }
        if ((Get-ClaudeProperty $installed[0] 'enabled') -ne $true) {
            if (-not $PSCmdlet.ShouldProcess($PluginId, '啟用外掛')) { return [pscustomobject]@{ Status = 'whatif'; Message = '預演，未執行' } }
            $outcome = Invoke-ClaudeCli -Arguments @('plugin', 'enable', $PluginId)
            if ($null -eq $outcome -or $outcome.ExitCode -ne 0) { throw ("plugin enable 失敗：{0}" -f $(if ($null -eq $outcome) { '找不到 claude 命令。' } else { $outcome.Output.Trim() })) }
            return [pscustomobject]@{ Status = 'enabled'; Message = '' }
        }
        if ($skipped) { return [pscustomobject]@{ Status = 'whatif'; Message = '預演，未執行' } }
        return [pscustomobject]@{ Status = 'unchanged'; Message = '' }
    }
    catch {
        return [pscustomobject]@{ Status = 'failed'; Message = $_.Exception.Message }
    }
}

function Read-ClaudeSettingsFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $result = [pscustomobject]@{ Exists = $false; Object = $null; Error = $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    $result.Exists = $true
    try { $bytes = [IO.File]::ReadAllBytes($Path) }
    catch { $result.Error = 'parse'; return $result }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $result.Error = 'bom'; return $result }
    try { $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) }
    catch { $result.Error = 'encoding'; return $result }
    try { $document = ConvertFrom-ClaudeUserConfigJson -Text $text }
    catch { $result.Error = 'parse'; return $result }
    if (-not (Test-ClaudeUserConfigJsonObject $document)) { $result.Error = 'not-object'; return $result }
    $result.Object = $document
    return $result
}

function Merge-ClaudeSettingsObject {
    # 把範本物件合併進目標物件（就地修改目標）：只新增、不刪除、不改寫既有值。
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)]$Template,
        [string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Changes
    )

    $appendArrayPaths = @('permissions.allow', 'permissions.deny', 'permissions.ask')
    foreach ($templateProperty in $Template.PSObject.Properties) {
        $name = $templateProperty.Name
        $templateValue = $templateProperty.Value
        $childPath = if ([string]::IsNullOrEmpty($Path)) { $name } else { "$Path.$name" }
        $existingProperty = $Target.PSObject.Properties[$name]

        if ($null -eq $existingProperty) {
            $Target | Add-Member -NotePropertyName $name -NotePropertyValue (Copy-ClaudeUserConfigNode $templateValue)
            $Changes.Add([pscustomobject]@{ Kind = 'add'; Path = $childPath })
            continue
        }
        $existingValue = $existingProperty.Value

        if (Test-ClaudeUserConfigJsonObject $templateValue) {
            if (Test-ClaudeUserConfigJsonObject $existingValue) {
                Merge-ClaudeSettingsObject -Target $existingValue -Template $templateValue -Path $childPath -Changes $Changes
            }
            else { $Changes.Add([pscustomobject]@{ Kind = 'kept-differs'; Path = $childPath }) }
        }
        elseif ($templateValue -is [array]) {
            if ($existingValue -isnot [array]) {
                $Changes.Add([pscustomobject]@{ Kind = 'kept-differs'; Path = $childPath })
            }
            elseif ($appendArrayPaths -contains $childPath) {
                $merged = New-Object 'System.Collections.Generic.List[object]'
                foreach ($item in $existingValue) { $merged.Add($item) }
                foreach ($item in $templateValue) {
                    $present = $false
                    foreach ($current in $merged) {
                        if (Test-ClaudeUserConfigJsonEqual $current $item) { $present = $true; break }
                    }
                    if ($present) { continue }
                    $merged.Add((Copy-ClaudeUserConfigNode $item))
                    $Changes.Add([pscustomobject]@{ Kind = 'add'; Path = ('{0}[{1}]' -f $childPath, ($merged.Count - 1)) })
                }
                $existingProperty.Value = $merged.ToArray()
            }
            elseif (-not (Test-ClaudeUserConfigJsonEqual $existingValue $templateValue)) {
                $Changes.Add([pscustomobject]@{ Kind = 'kept-differs'; Path = $childPath })
            }
        }
        else {
            if (-not (Test-ClaudeUserConfigJsonEqual $existingValue $templateValue)) {
                $Changes.Add([pscustomobject]@{ Kind = 'kept-differs'; Path = $childPath })
            }
        }
    }
}

function Get-ClaudeSettingsPlan {
    [CmdletBinding()]
    param(
        [AllowNull()]$Existing,
        [Parameter(Mandatory)]$Template
    )

    if (-not (Test-ClaudeUserConfigJsonObject $Template)) { throw 'settings 範本必須是物件。' }
    if ($null -ne $Existing -and -not (Test-ClaudeUserConfigJsonObject $Existing)) { throw '既有 settings 必須是物件或 $null。' }
    $result = if ($null -eq $Existing) { [pscustomobject]@{} } else { Copy-ClaudeUserConfigNode $Existing }
    $changes = New-Object 'System.Collections.Generic.List[object]'
    Merge-ClaudeSettingsObject -Target $result -Template $Template -Path '' -Changes $changes
    return [pscustomobject]@{ Result = $result; Changes = $changes.ToArray() }
}

function Test-ClaudeSettingsPreserved {
    [CmdletBinding()]
    param(
        [AllowNull()]$Before,
        [AllowNull()]$After
    )

    # Before 的每個葉值在 After 同路徑皆存在且相等；陣列時 Before 的元素依序為 After 的前綴。After 可以多出鍵與陣列尾端項目。
    if ($null -eq $Before) { return $true }
    if (Test-ClaudeUserConfigJsonObject $Before) {
        if (-not (Test-ClaudeUserConfigJsonObject $After)) { return $false }
        foreach ($property in $Before.PSObject.Properties) {
            $afterProperty = $After.PSObject.Properties[$property.Name]
            if ($null -eq $afterProperty) { return $false }
            if (-not (Test-ClaudeSettingsPreserved -Before $property.Value -After $afterProperty.Value)) { return $false }
        }
        return $true
    }
    if ($Before -is [array]) {
        if ($After -isnot [array] -or $After.Count -lt $Before.Count) { return $false }
        for ($i = 0; $i -lt $Before.Count; $i++) {
            if (-not (Test-ClaudeUserConfigJsonEqual $Before[$i] $After[$i])) { return $false }
        }
        return $true
    }
    return (Test-ClaudeUserConfigJsonEqual $Before $After)
}

function Invoke-ClaudeSettingsApply {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SettingsPath,
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$BackupRoot
    )

    $outcome = { param($Status, $Changes, $BackupPath, $Message) [pscustomobject]@{ Status = $Status; Changes = @($Changes); BackupPath = $BackupPath; Message = $Message } }

    $template = Read-ClaudeSettingsFile -Path $TemplatePath
    if (-not $template.Exists -or $null -ne $template.Error) {
        $reason = if (-not $template.Exists) { '不存在' } else { $template.Error }
        return (& $outcome 'failed' @() $null "settings 範本無法使用：$reason")
    }

    $current = Read-ClaudeSettingsFile -Path $SettingsPath
    if ($null -ne $current.Error) {
        return (& $outcome 'refused' @() $null "settings.json 無法安全合併（原因：$($current.Error)），未寫入任何檔案")
    }

    try {
        $plan = Get-ClaudeSettingsPlan -Existing $(if ($current.Exists) { $current.Object } else { $null }) -Template $template.Object
        $changes = @($plan.Changes)
        $additions = @($changes | Where-Object { $_.Kind -eq 'add' })
        if ($current.Exists -and $additions.Count -eq 0) { return (& $outcome 'unchanged' $changes $null '') }

        $json = $plan.Result | ConvertTo-Json -Depth 32
        $reparsed = ConvertFrom-ClaudeUserConfigJson -Text $json
        $baseline = if ($current.Exists) { $current.Object } else { $template.Object }
        if (-not (Test-ClaudeSettingsPreserved -Before $baseline -After $reparsed)) {
            return (& $outcome 'failed' $changes $null '序列化後的內容驗證失敗（既有內容未完整保留），未寫入任何檔案')
        }
    }
    catch {
        return (& $outcome 'failed' @() $null ("合併失敗：{0}" -f $_.Exception.Message))
    }

    if (-not $PSCmdlet.ShouldProcess($SettingsPath, '套用 settings 範本')) {
        return (& $outcome 'whatif' $changes $null '預演，未寫入任何檔案')
    }

    $backupPath = $null
    $temporaryPath = $null
    try {
        $directory = Split-Path -Parent $SettingsPath
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }

        if ($current.Exists) {
            $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $backupDirectory = Join-Path $BackupRoot $stamp
            $suffix = 0
            while (Test-Path -LiteralPath $backupDirectory) { $suffix++; $backupDirectory = Join-Path $BackupRoot ('{0}_{1}' -f $stamp, $suffix) }
            New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
            $backupPath = Join-Path $backupDirectory 'settings.json'
            Copy-Item -LiteralPath $SettingsPath -Destination $backupPath
            if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw '備份檔寫入後不存在。' }
            $manifestLine = ((Get-Date -Format o) + " | $SettingsPath | 套用 settings 範本`n")
            [IO.File]::WriteAllText((Join-Path $backupDirectory 'manifest.txt'), $manifestLine, (New-Object System.Text.UTF8Encoding($false)))
        }

        $temporaryPath = Join-Path $directory ('settings.json.tmp-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($temporaryPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        [IO.File]::Move($temporaryPath, $SettingsPath, $true)
        $temporaryPath = $null
    }
    catch {
        if ($null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
        return (& $outcome 'failed' $changes $backupPath ("寫入失敗：{0}" -f $_.Exception.Message))
    }
    $status = if ($current.Exists) { 'merged' } else { 'created' }
    return (& $outcome $status $changes $backupPath '')
}

function Get-WslStatus {
    [CmdletBinding()]
    param([string]$WslPath)

    # 只用結束碼判定（wsl 輸出為 UTF-16，不解析）；--status 不啟動發行版。
    if ([string]::IsNullOrEmpty($WslPath)) {
        $command = Get-Command -Name 'wsl' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) { return 'missing' }
        $WslPath = $command.Source
    }
    if (-not (Test-Path -LiteralPath $WslPath -PathType Leaf)) { return 'missing' }
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $WslPath --status *> $null
        if ($LASTEXITCODE -eq 0) { return 'ok' }
        return 'missing'
    }
    catch { return 'missing' }
    finally { $ErrorActionPreference = $previousPreference }
}

function Get-TcpPortOpenMap {
    # 同時對 127.0.0.1 的多個連接埠發起連線，再一次等待；不送任何請求內容。回傳 連接埠 → 是否可連線 的 hashtable。
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int[]]$Port,
        [int]$TimeoutMs = 500
    )

    $clients = @{}
    $tasks = @{}
    $map = @{}
    try {
        foreach ($item in $Port) {
            $client = New-Object System.Net.Sockets.TcpClient
            $clients[$item] = $client
            $tasks[$item] = $client.ConnectAsync('127.0.0.1', $item)
        }
        try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($tasks.Values), $TimeoutMs) }
        catch { }
        foreach ($item in $Port) {
            $map[$item] = ($tasks[$item].Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) -and $clients[$item].Connected
        }
    }
    finally {
        foreach ($client in $clients.Values) { $client.Dispose() }
    }
    return $map
}

function Test-TcpPortOpen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 500
    )

    return [bool](Get-TcpPortOpenMap -Port @($Port) -TimeoutMs $TimeoutMs)[$Port]
}
