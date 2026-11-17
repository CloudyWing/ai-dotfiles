#Requires -Version 7.0
[CmdletBinding()]
param()

# scripts/lib/claude-user-config.ps1 的測試：MCP 範本與登記計畫、官方外掛安裝流程、settings.json 合併與保護步驟、WSL 與連接埠探測。
# 以同名函式替身取代 Setup 定義的 Invoke-ClaudeCli、Get-ClaudeList、Get-ClaudeProperty，所有檔案操作都在暫存目錄內進行，不碰真實的使用者設定。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$libPath = Join-Path $repoRoot 'scripts\lib\claude-user-config.ps1'
$mcpTemplatePath = Join-Path $repoRoot 'templates\claude-mcp-servers.json'
$tempBase = Join-Path (Join-Path $env:LOCALAPPDATA 'Temp') ('claude-user-config-' + [guid]::NewGuid().ToString('N'))
$failed = 0
$passed = 0

. $libPath

# 替身：記錄呼叫並由測試指定回應。
$script:CliCalls = New-Object 'System.Collections.Generic.List[object]'
$script:CliHandler = { param($Arguments) [pscustomobject]@{ ExitCode = 0; Output = '' } }
$script:ListHandler = { param($Arguments) , @() }

function Invoke-ClaudeCli {
    param([string[]]$Arguments)
    $script:CliCalls.Add($Arguments)
    return (& $script:CliHandler $Arguments)
}

function Get-ClaudeList {
    param([string[]]$Arguments)
    return (& $script:ListHandler $Arguments)
}

function Get-ClaudeProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-Case {
    param([string]$Id, [scriptblock]$Check)
    try {
        $output = @(& $Check)
        $result = if ($output.Count -gt 0) { $output[-1] } else { $false }
        if (-not $result) { throw '條件不成立' }
        $script:passed++
        Write-Output "PASS $Id"
    }
    catch {
        $script:failed++
        Write-Output "FAIL $Id $($_.Exception.Message)"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Reset-Stubs {
    $script:CliCalls.Clear()
    $script:CliHandler = { param($Arguments) [pscustomobject]@{ ExitCode = 0; Output = '' } }
    $script:ListHandler = { param($Arguments) , @() }
}

function New-TestDirectory {
    $path = Join-Path $tempBase ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Write-TestFile {
    param([string]$Path, [string]$Text)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-TestHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Join-Arguments {
    param([object[]]$Arguments)
    return (@($Arguments) -join [char]0)
}

function Test-Throws {
    param([scriptblock]$Action)
    try { & $Action | Out-Null } catch { return $true }
    return $false
}

$infraLabDistro = 'Ubuntu-test'
$infraLabRepo = '/work/infra-lab'
$httpNames = @('mcp-sql-server', 'mcp-oracle', 'mcp-elasticsearch', 'mcp-redis', 'mcp-mosquitto', 'mcp-rabbitmq', 'mcp-mailpit', 'mcp-reader', 'mcp-oidc', 'mcp-api-contract', 'mcp-docker')

function New-ExistingRegistrations {
    # 依範本建立「全部已登記且形狀相符」的既有登記，項目形狀與 claude mcp add 實際寫入的相同。
    param([object[]]$Template)
    $existing = @{}
    foreach ($server in $Template) {
        if ($server.Type -eq 'http') { $existing[$server.Name] = [ordered]@{ type = 'http'; url = $server.Url } }
        else { $existing[$server.Name] = [ordered]@{ type = 'stdio'; command = 'wsl.exe'; args = @('-d', $infraLabDistro, '-e', 'bash', ($infraLabRepo + '/scripts/mcp.sh')); env = [ordered]@{} } }
    }
    return $existing
}

function New-SettingsTemplateText {
    return @'
{
  "model": "opus",
  "theme": "dark",
  "tui": "fullscreen",
  "permissions": {
    "allow": ["WebSearch", "Bash(git status *)"],
    "ask": ["Read(**/.env)"],
    "deny": ["Read(**/auth.json)"]
  },
  "enabledPlugins": {
    "microsoft-docs@claude-plugins-official": true,
    "ai-agents-hooks@ai-agents-local": true
  },
  "modelSettings": { "model-a": { "effortLevel": "medium" } }
}
'@
}

function New-ExistingSettingsText {
    return @'
{
  "model": "sonnet",
  "customKey": { "nested": [1, 2, { "deep": true }] },
  "permissions": {
    "allow": ["Bash(echo *)", "WebSearch"],
    "additionalDirectories": ["extra-dir"]
  },
  "enabledPlugins": { "microsoft-docs@claude-plugins-official": false },
  "nothing": null,
  "stamp": "2026-11-18T10:00:00Z",
  "emptyArray": [],
  "emptyObject": {}
}
'@
}

try {
    New-Item -ItemType Directory -Path $tempBase -Force | Out-Null

    # ---- 範本讀取與驗證 ----
    $template = $null
    Test-Case 'M01 真實範本回傳 12 個伺服器，名稱集合為 11 個 http 加 infra-lab' {
        $script:template = @(Read-ClaudeMcpTemplate -Path $mcpTemplatePath)
        Assert-True ($script:template.Count -eq 12) '數量不是 12'
        $expected = @($httpNames) + @('infra-lab')
        Assert-True (((@($script:template | ForEach-Object { $_.Name }) | Sort-Object) -join ',') -ceq (($expected | Sort-Object) -join ',')) '名稱集合不符'
        Assert-True (@($script:template | Where-Object { $_.Type -eq 'stdio' }).Count -eq 1) 'stdio 數量不是 1'
        $true
    }
    $template = @(Read-ClaudeMcpTemplate -Path $mcpTemplatePath)
    Test-Case 'M02 名稱重複時擲出例外' {
        $path = Join-Path (New-TestDirectory) 't.json'
        Write-TestFile $path '{"servers":[{"name":"a","type":"http","url":"http://127.0.0.1:9800/mcp"},{"name":"A","type":"http","url":"http://127.0.0.1:9801/mcp"}]}'
        Test-Throws { Read-ClaudeMcpTemplate -Path $path }
    }
    Test-Case 'M03 多餘欄位（headers）擲出例外' {
        $path = Join-Path (New-TestDirectory) 't.json'
        Write-TestFile $path '{"servers":[{"name":"a","type":"http","url":"http://127.0.0.1:9800/mcp","headers":{"x":"y"}}]}'
        Test-Throws { Read-ClaudeMcpTemplate -Path $path }
    }
    Test-Case 'M04 非 127.0.0.1 的 url 擲出例外' {
        $path = Join-Path (New-TestDirectory) 't.json'
        Write-TestFile $path '{"servers":[{"name":"a","type":"http","url":"http://example.test:9800/mcp"}]}'
        Test-Throws { Read-ClaudeMcpTemplate -Path $path }
    }
    Test-Case 'M05 url 結尾帶換行擲出例外' {
        $path = Join-Path (New-TestDirectory) 't.json'
        Write-TestFile $path ('{"servers":[{"name":"a","type":"http","url":"http://127.0.0.1:9800/mcp\n"}]}')
        Test-Throws { Read-ClaudeMcpTemplate -Path $path }
    }
    Test-Case 'M06 stdio 缺少 args、http 含 command 皆擲出例外' {
        $path = Join-Path (New-TestDirectory) 't.json'
        Write-TestFile $path '{"servers":[{"name":"a","type":"stdio","command":"wsl.exe"}]}'
        $first = Test-Throws { Read-ClaudeMcpTemplate -Path $path }
        Write-TestFile $path '{"servers":[{"name":"a","type":"http","url":"http://127.0.0.1:9800/mcp","command":"x"}]}'
        $first -and (Test-Throws { Read-ClaudeMcpTemplate -Path $path })
    }
    Test-Case 'M07 範本不存在、無法剖析、缺少 servers 皆擲出例外' {
        $directory = New-TestDirectory
        $missing = Test-Throws { Read-ClaudeMcpTemplate -Path (Join-Path $directory 'none.json') }
        Write-TestFile (Join-Path $directory 'bad.json') '{ not json'
        Write-TestFile (Join-Path $directory 'noservers.json') '{"a":1}'
        $missing -and (Test-Throws { Read-ClaudeMcpTemplate -Path (Join-Path $directory 'bad.json') }) -and (Test-Throws { Read-ClaudeMcpTemplate -Path (Join-Path $directory 'noservers.json') })
    }

    # ---- 使用者層登記檔讀取 ----
    Test-Case 'U01 含大小寫不同鍵的 projects 仍能讀取 mcpServers' {
        $path = Join-Path (New-TestDirectory) 'claude.json'
        Write-TestFile $path '{"projects":{"X:/p":{"a":1},"x:/p":{"b":2}},"mcpServers":{"mcp-reader":{"type":"http","url":"http://127.0.0.1:9840/mcp"}}}'
        $result = Get-ClaudeUserMcpServer -Path $path
        $result.Exists -and $null -eq $result.Error -and $result.Servers.Count -eq 1 -and $result.Servers.ContainsKey('mcp-reader')
    }
    Test-Case 'U02 無法剖析時回報 parse' {
        $path = Join-Path (New-TestDirectory) 'claude.json'
        Write-TestFile $path '{ not json'
        $result = Get-ClaudeUserMcpServer -Path $path
        $result.Exists -and $result.Error -ceq 'parse' -and $result.Servers.Count -eq 0
    }
    Test-Case 'U03 mcpServers 不是物件時回報 not-object' {
        $path = Join-Path (New-TestDirectory) 'claude.json'
        Write-TestFile $path '{"mcpServers":["a"]}'
        (Get-ClaudeUserMcpServer -Path $path).Error -ceq 'not-object'
    }
    Test-Case 'U04 檔案不存在時 Exists 為 false 且 Servers 為空' {
        $result = Get-ClaudeUserMcpServer -Path (Join-Path (New-TestDirectory) 'none.json')
        (-not $result.Exists) -and $null -eq $result.Error -and $result.Servers.Count -eq 0
    }
    Test-Case 'U05 根為陣列時回報 not-object；沒有 mcpServers 鍵時視為無登記' {
        $directory = New-TestDirectory
        Write-TestFile (Join-Path $directory 'a.json') '[1,2]'
        Write-TestFile (Join-Path $directory 'b.json') '{"other":1}'
        $a = Get-ClaudeUserMcpServer -Path (Join-Path $directory 'a.json')
        $b = Get-ClaudeUserMcpServer -Path (Join-Path $directory 'b.json')
        $a.Error -ceq 'not-object' -and $b.Exists -and $null -eq $b.Error -and $b.Servers.Count -eq 0
    }

    # ---- infra-lab 值驗證 ----
    Test-Case 'V01 合法值通過' {
        (Test-ClaudeMcpInfraLabValue -Distro 'Ubuntu-24.04' -WslRepo '/work/infra-lab') -and (Test-ClaudeMcpInfraLabValue -Distro 'a' -WslRepo '/a') -and (Test-ClaudeMcpInfraLabValue -Distro 'Debian_x' -WslRepo '/opt/a.b/c@d+e~f-g')
    }
    Test-Case 'V02 含空白、引號、特殊字元、換行、結尾換行的值被拒絕' {
        $badDistros = @('Ubuntu 24', 'Ubuntu"', "Ubuntu'", 'a&b', 'a|b', 'a<b', 'a>b', 'a^b', 'a%b', 'a\b', "a`nb", "Ubuntu`n", "Ubuntu`r", "a`0b", '-Ubuntu', '.Ubuntu', '')
        foreach ($value in $badDistros) { Assert-True (-not (Test-ClaudeMcpInfraLabValue -Distro $value -WslRepo '/work/r')) ("Distro 應被拒絕：" + ($value | ConvertTo-Json -Compress)) }
        $badRepos = @('/work/a b', '/work/a"b', '/work/a&b', '/work/a\b', '/work/a%b', "/work/a`nb", "/work/repo`n", '/work/repo/', '/', 'work/repo', '', '/work/a|b', '/work/a<b', '/work/a>b', '/work/a^b', "/work/a'b")
        foreach ($value in $badRepos) { Assert-True (-not (Test-ClaudeMcpInfraLabValue -Distro 'Ubuntu' -WslRepo $value)) ("WslRepo 應被拒絕：" + ($value | ConvertTo-Json -Compress)) }
        $true
    }
    Test-Case 'V03 超過長度上限被拒絕，剛好在上限內通過' {
        (-not (Test-ClaudeMcpInfraLabValue -Distro ('a' * 65) -WslRepo '/work/r')) -and (Test-ClaudeMcpInfraLabValue -Distro ('a' * 64) -WslRepo '/work/r') -and
        (-not (Test-ClaudeMcpInfraLabValue -Distro 'Ubuntu' -WslRepo ('/' + ('a' * 256)))) -and (Test-ClaudeMcpInfraLabValue -Distro 'Ubuntu' -WslRepo ('/' + ('a' * 255)))
    }

    # ---- 登記計畫 ----
    Test-Case 'P01 全空時 11 個 http 為 add，infra-lab 在有合法值時為 add' {
        $plan = @(Get-ClaudeMcpPlan -Template $template -Existing @{} -Distro $infraLabDistro -WslRepo $infraLabRepo)
        $plan.Count -eq 12 -and @($plan | Where-Object { $_.Action -eq 'add' }).Count -eq 12
    }
    Test-Case 'P02 全空且缺少或未通過驗證的值時 infra-lab 為 needs-values，其餘 11 項不受影響' {
        $none = @(Get-ClaudeMcpPlan -Template $template -Existing @{} -Distro $null -WslRepo $null)
        $bad = @(Get-ClaudeMcpPlan -Template $template -Existing @{} -Distro 'a b' -WslRepo $infraLabRepo)
        ($none | Where-Object { $_.Name -eq 'infra-lab' }).Action -eq 'needs-values' -and ($bad | Where-Object { $_.Name -eq 'infra-lab' }).Action -eq 'needs-values' -and
        @($none | Where-Object { $_.Action -eq 'add' }).Count -eq 11 -and $null -eq ($none | Where-Object { $_.Name -eq 'infra-lab' }).Arguments
    }
    Test-Case 'P03 全部已登記且形狀相符時全為 unchanged（含未提供值）' {
        $existing = New-ExistingRegistrations -Template $template
        $withValues = @(Get-ClaudeMcpPlan -Template $template -Existing $existing -Distro $infraLabDistro -WslRepo $infraLabRepo)
        $withoutValues = @(Get-ClaudeMcpPlan -Template $template -Existing $existing)
        @($withValues | Where-Object { $_.Action -ne 'unchanged' }).Count -eq 0 -and @($withoutValues | Where-Object { $_.Action -ne 'unchanged' }).Count -eq 0
    }
    Test-Case 'P04 既有 url 不同時為 differs，DifferingField 含 url 且計畫不含任何現有值' {
        $existing = New-ExistingRegistrations -Template $template
        $existing['mcp-reader'] = [ordered]@{ type = 'http'; url = 'http://127.0.0.1:19999/mcp' }
        $plan = @(Get-ClaudeMcpPlan -Template $template -Existing $existing -Distro $infraLabDistro -WslRepo $infraLabRepo)
        $item = $plan | Where-Object { $_.Name -eq 'mcp-reader' }
        $serialized = $plan | ConvertTo-Json -Depth 6
        $item.Action -eq 'differs' -and @($item.DifferingField) -contains 'url' -and @($item.DifferingField) -notcontains 'type' -and $serialized -notmatch '19999'
    }
    Test-Case 'P05 既有登記多出 headers 鍵時仍為 unchanged；url 大小寫不同不算差異' {
        $existing = New-ExistingRegistrations -Template $template
        $existing['mcp-reader'] = [ordered]@{ type = 'http'; url = 'HTTP://127.0.0.1:9840/MCP'; headers = [ordered]@{ Authorization = 'placeholder' } }
        (Get-ClaudeMcpPlan -Template $template -Existing $existing | Where-Object { $_.Name -eq 'mcp-reader' }).Action -eq 'unchanged'
    }
    Test-Case 'P06 infra-lab 形狀不符時為 differs' {
        $existing = New-ExistingRegistrations -Template $template
        $shapes = @(
            [ordered]@{ type = 'stdio'; command = 'wsl.exe'; args = @('-d', 'x', '-e', 'bash') },
            [ordered]@{ type = 'stdio'; command = 'wsl.exe'; args = @('-d', 'x', '-e', 'sh', '/a/scripts/mcp.sh') },
            [ordered]@{ type = 'stdio'; command = 'wsl.exe'; args = @('-d', 'x', '-e', 'bash', '/a/scripts/other.sh') },
            [ordered]@{ type = 'stdio'; command = 'cmd.exe'; args = @('-d', 'x', '-e', 'bash', '/a/scripts/mcp.sh') },
            [ordered]@{ type = 'http'; url = 'http://127.0.0.1:9/mcp' }
        )
        foreach ($shape in $shapes) {
            $existing['infra-lab'] = $shape
            $item = Get-ClaudeMcpPlan -Template $template -Existing $existing | Where-Object { $_.Name -eq 'infra-lab' }
            Assert-True ($item.Action -eq 'differs') ('形狀未被判為 differs：' + ($shape | ConvertTo-Json -Compress))
        }
        $true
    }
    Test-Case 'P07 使用者另外加入的其他登記不進入計畫，計畫只含範本的名稱' {
        $existing = New-ExistingRegistrations -Template $template
        $existing['user-own-server'] = [ordered]@{ type = 'http'; url = 'http://127.0.0.1:1/mcp' }
        $plan = @(Get-ClaudeMcpPlan -Template $template -Existing $existing)
        $plan.Count -eq 12 -and @($plan | Where-Object { $_.Name -eq 'user-own-server' }).Count -eq 0
    }
    Test-Case 'P08 提供的 Distro 或 WslRepo 與既有登記不同時為 differs；相同時為 unchanged' {
        $existing = New-ExistingRegistrations -Template $template
        $differentDistro = Get-ClaudeMcpPlan -Template $template -Existing $existing -Distro 'Other' -WslRepo $infraLabRepo | Where-Object { $_.Name -eq 'infra-lab' }
        $differentRepo = Get-ClaudeMcpPlan -Template $template -Existing $existing -Distro $infraLabDistro -WslRepo '/other' | Where-Object { $_.Name -eq 'infra-lab' }
        $same = Get-ClaudeMcpPlan -Template $template -Existing $existing -Distro $infraLabDistro -WslRepo $infraLabRepo | Where-Object { $_.Name -eq 'infra-lab' }
        $differentDistro.Action -eq 'differs' -and $differentRepo.Action -eq 'differs' -and @($differentRepo.DifferingField) -contains 'args' -and $same.Action -eq 'unchanged'
    }
    Test-Case 'P09 add 的引數陣列與設計逐元素相同' {
        $plan = @(Get-ClaudeMcpPlan -Template $template -Existing @{} -Distro $infraLabDistro -WslRepo $infraLabRepo)
        $http = $plan | Where-Object { $_.Name -eq 'mcp-reader' }
        $stdio = $plan | Where-Object { $_.Name -eq 'infra-lab' }
        $expectedHttp = @('mcp', 'add', '--transport', 'http', '--scope', 'user', 'mcp-reader', 'http://127.0.0.1:9840/mcp')
        $expectedStdio = @('mcp', 'add', '--transport', 'stdio', '--scope', 'user', 'infra-lab', '--', 'wsl.exe', '-d', $infraLabDistro, '-e', 'bash', ($infraLabRepo + '/scripts/mcp.sh'))
        (Join-Arguments $http.Arguments) -ceq (Join-Arguments $expectedHttp) -and (Join-Arguments $stdio.Arguments) -ceq (Join-Arguments $expectedStdio)
    }
    Test-Case 'P10 既有 type 不同為 differs 且 DifferingField 含 type；既有項目不是物件時為 differs' {
        $existing = New-ExistingRegistrations -Template $template
        $existing['mcp-oidc'] = [ordered]@{ type = 'stdio'; url = 'http://127.0.0.1:9850/mcp' }
        $existing['mcp-redis'] = 'not-an-object'
        $plan = @(Get-ClaudeMcpPlan -Template $template -Existing $existing)
        $oidc = $plan | Where-Object { $_.Name -eq 'mcp-oidc' }
        $redis = $plan | Where-Object { $_.Name -eq 'mcp-redis' }
        @($oidc.DifferingField) -contains 'type' -and $redis.Action -eq 'differs'
    }

    # ---- 登記執行 ----
    Test-Case 'R01 只對 add 呼叫 Invoke-ClaudeCli，引數與計畫相同' {
        Reset-Stubs
        $existing = New-ExistingRegistrations -Template $template
        $existing.Remove('mcp-docker'); $existing.Remove('infra-lab')
        $existing['mcp-oidc'] = [ordered]@{ type = 'http'; url = 'http://127.0.0.1:1/mcp' }
        $plan = @(Get-ClaudeMcpPlan -Template $template -Existing $existing -Distro $infraLabDistro -WslRepo $infraLabRepo)
        $results = @(Invoke-ClaudeMcpRegister -Plan $plan)
        $script:CliCalls.Count -eq 2 -and (Join-Arguments $script:CliCalls[0]) -ceq (Join-Arguments @('mcp', 'add', '--transport', 'http', '--scope', 'user', 'mcp-docker', 'http://127.0.0.1:9860/mcp')) -and
        ($results | Where-Object { $_.Name -eq 'mcp-docker' }).Status -eq 'added' -and ($results | Where-Object { $_.Name -eq 'infra-lab' }).Status -eq 'added' -and
        ($results | Where-Object { $_.Name -eq 'mcp-oidc' }).Status -eq 'differs' -and ($results | Where-Object { $_.Name -eq 'mcp-reader' }).Status -eq 'unchanged'
    }
    Test-Case 'R02 以更新後的 Existing 重新計畫時零次呼叫（重跑不產生重複登記）' {
        Reset-Stubs
        $existing = @{}
        $first = @(Get-ClaudeMcpPlan -Template $template -Existing $existing -Distro $infraLabDistro -WslRepo $infraLabRepo)
        [void](Invoke-ClaudeMcpRegister -Plan $first)
        $firstCalls = $script:CliCalls.Count
        $script:CliCalls.Clear()
        $updated = New-ExistingRegistrations -Template $template
        $second = @(Get-ClaudeMcpPlan -Template $template -Existing $updated -Distro $infraLabDistro -WslRepo $infraLabRepo)
        [void](Invoke-ClaudeMcpRegister -Plan $second)
        $firstCalls -eq 12 -and $script:CliCalls.Count -eq 0
    }
    Test-Case 'R03 -WhatIf 時零次呼叫' {
        Reset-Stubs
        $plan = @(Get-ClaudeMcpPlan -Template $template -Existing @{} -Distro $infraLabDistro -WslRepo $infraLabRepo)
        $results = @(Invoke-ClaudeMcpRegister -Plan $plan -WhatIf)
        $script:CliCalls.Count -eq 0 -and $results.Count -eq 12 -and @($results | Where-Object { $_.Status -eq 'whatif' }).Count -eq 12
    }
    Test-Case 'R04 替身回傳非零時該項為 failed，其餘項目仍執行' {
        Reset-Stubs
        $script:CliHandler = { param($Arguments) if ($Arguments -contains 'mcp-oracle') { [pscustomobject]@{ ExitCode = 1; Output = 'boom' } } else { [pscustomobject]@{ ExitCode = 0; Output = '' } } }
        $plan = @(Get-ClaudeMcpPlan -Template $template -Existing @{} -Distro $infraLabDistro -WslRepo $infraLabRepo)
        $results = @(Invoke-ClaudeMcpRegister -Plan $plan)
        $failedItem = $results | Where-Object { $_.Name -eq 'mcp-oracle' }
        $script:CliCalls.Count -eq 12 -and $failedItem.Status -eq 'failed' -and $failedItem.Message -match 'boom' -and @($results | Where-Object { $_.Status -eq 'added' }).Count -eq 11
    }
    Test-Case 'R05 claude 不存在（替身回傳 null）時為 failed；differs 與 needs-values 的訊息不含現有值' {
        Reset-Stubs
        $script:CliHandler = { param($Arguments) $null }
        $plan = @(Get-ClaudeMcpPlan -Template $template -Existing @{} -Distro $null -WslRepo $null)
        $results = @(Invoke-ClaudeMcpRegister -Plan $plan)
        $needs = $results | Where-Object { $_.Name -eq 'infra-lab' }
        $existing = New-ExistingRegistrations -Template $template
        $existing['mcp-reader'] = [ordered]@{ type = 'http'; url = 'http://127.0.0.1:19999/mcp'; headers = [ordered]@{ Authorization = 'secret-placeholder' } }
        $differsResult = @(Invoke-ClaudeMcpRegister -Plan @(Get-ClaudeMcpPlan -Template $template -Existing $existing)) | Where-Object { $_.Name -eq 'mcp-reader' }
        @($results | Where-Object { $_.Status -eq 'failed' }).Count -eq 11 -and $needs.Status -eq 'needs-values' -and $needs.Message -match '-InfraLabDistro' -and
        $differsResult.Status -eq 'differs' -and $differsResult.Message -match 'claude mcp remove mcp-reader --scope user' -and $differsResult.Message -notmatch '19999|secret-placeholder'
    }

    # ---- 官方外掛 ----
    Test-Case 'I01 Get-ClaudeRequiredOfficialPlugin 只回傳官方 marketplace 且為 true 的項目；範本不存在時回傳空陣列' {
        $directory = New-TestDirectory
        $path = Join-Path $directory 'settings.shared.json'
        Write-TestFile $path '{"enabledPlugins":{"microsoft-docs@claude-plugins-official":true,"github@claude-plugins-official":false,"ai-agents-hooks@ai-agents-local":true}}'
        $found = @(Get-ClaudeRequiredOfficialPlugin -TemplatePath $path)
        $missing = @(Get-ClaudeRequiredOfficialPlugin -TemplatePath (Join-Path $directory 'none.json'))
        $found.Count -eq 1 -and $found[0] -ceq 'microsoft-docs@claude-plugins-official' -and $missing.Count -eq 0
    }
    Test-Case 'I02 marketplace 缺少時依序呼叫 marketplace add 與 install' {
        Reset-Stubs
        $script:ListHandler = { param($Arguments) , @() }
        $result = Install-ClaudeOfficialPlugin -PluginId 'microsoft-docs@claude-plugins-official'
        $result.Status -eq 'installed' -and $script:CliCalls.Count -eq 2 -and
        (Join-Arguments $script:CliCalls[0]) -ceq (Join-Arguments @('plugin', 'marketplace', 'add', 'anthropics/claude-plugins-official')) -and
        (Join-Arguments $script:CliCalls[1]) -ceq (Join-Arguments @('plugin', 'install', 'microsoft-docs@claude-plugins-official', '--scope', 'user'))
    }
    Test-Case 'I03 已安裝且啟用時零次寫入呼叫，結果為 unchanged' {
        Reset-Stubs
        $script:ListHandler = {
            param($Arguments)
            if ($Arguments -contains 'marketplace') { , @([pscustomobject]@{ name = 'claude-plugins-official' }) }
            else { , @([pscustomobject]@{ id = 'microsoft-docs@claude-plugins-official'; enabled = $true }) }
        }
        $result = Install-ClaudeOfficialPlugin -PluginId 'microsoft-docs@claude-plugins-official'
        $result.Status -eq 'unchanged' -and $script:CliCalls.Count -eq 0
    }
    Test-Case 'I04 已安裝未啟用時只呼叫 enable' {
        Reset-Stubs
        $script:ListHandler = {
            param($Arguments)
            if ($Arguments -contains 'marketplace') { , @([pscustomobject]@{ name = 'claude-plugins-official' }) }
            else { , @([pscustomobject]@{ id = 'microsoft-docs@claude-plugins-official'; enabled = $false }) }
        }
        $result = Install-ClaudeOfficialPlugin -PluginId 'microsoft-docs@claude-plugins-official'
        $result.Status -eq 'enabled' -and $script:CliCalls.Count -eq 1 -and (Join-Arguments $script:CliCalls[0]) -ceq (Join-Arguments @('plugin', 'enable', 'microsoft-docs@claude-plugins-official'))
    }
    Test-Case 'I05 清單查詢失敗或安裝非零時為 failed 且不再嘗試後續步驟' {
        Reset-Stubs
        $script:ListHandler = { param($Arguments) throw 'list failed' }
        $first = Install-ClaudeOfficialPlugin -PluginId 'microsoft-docs@claude-plugins-official'
        $firstCalls = $script:CliCalls.Count
        Reset-Stubs
        $script:ListHandler = { param($Arguments) , @() }
        $script:CliHandler = { param($Arguments) if ($Arguments -contains 'install') { [pscustomobject]@{ ExitCode = 1; Output = 'install boom' } } else { [pscustomobject]@{ ExitCode = 0; Output = '' } } }
        $second = Install-ClaudeOfficialPlugin -PluginId 'microsoft-docs@claude-plugins-official'
        $first.Status -eq 'failed' -and $firstCalls -eq 0 -and $second.Status -eq 'failed' -and $second.Message -match 'install boom'
    }
    Test-Case 'I06 -WhatIf 時零次呼叫' {
        Reset-Stubs
        $script:ListHandler = { param($Arguments) , @() }
        $result = Install-ClaudeOfficialPlugin -PluginId 'microsoft-docs@claude-plugins-official' -WhatIf
        $result.Status -eq 'whatif' -and $script:CliCalls.Count -eq 0
    }

    # ---- settings 合併 ----
    function New-SettingsFixture {
        param($ExistingText)
        $directory = New-TestDirectory
        $fixture = [pscustomobject]@{
            Directory = $directory
            Settings  = Join-Path $directory 'claude\settings.json'
            Template  = Join-Path $directory 'settings.shared.json'
            Backups   = Join-Path $directory 'backups'
        }
        Write-TestFile $fixture.Template (New-SettingsTemplateText)
        if ($null -ne $ExistingText) { Write-TestFile $fixture.Settings $ExistingText }
        return $fixture
    }

    Test-Case 'S01 檔案不存在時建立，內容與範本一致，不備份' {
        $fixture = New-SettingsFixture
        $result = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        $written = Read-ClaudeSettingsFile -Path $fixture.Settings
        $templateRead = Read-ClaudeSettingsFile -Path $fixture.Template
        $result.Status -eq 'created' -and $null -eq $written.Error -and (Test-ClaudeUserConfigJsonEqual $written.Object $templateRead.Object) -and -not (Test-Path -LiteralPath $fixture.Backups) -and
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $fixture.Settings) -Filter '*.tmp-*').Count -eq 0
    }
    Test-Case 'S02 已有檔案時保留未知鍵與使用者純量值，kept-differs 只列路徑' {
        $fixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $result = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        $after = (Read-ClaudeSettingsFile -Path $fixture.Settings).Object
        $kept = @($result.Changes | Where-Object { $_.Kind -eq 'kept-differs' })
        $result.Status -eq 'merged' -and $after.model -ceq 'sonnet' -and $after.theme -ceq 'dark' -and $after.tui -ceq 'fullscreen' -and
        $after.customKey.nested[2].deep -eq $true -and $after.permissions.additionalDirectories[0] -ceq 'extra-dir' -and
        @($kept | ForEach-Object { $_.Path }) -contains 'model' -and (($result.Changes | ConvertTo-Json -Depth 4) -notmatch 'sonnet')
    }
    Test-Case 'S03 permissions 陣列附加且不重複，既有順序不變' {
        $fixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $null = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        $after = (Read-ClaudeSettingsFile -Path $fixture.Settings).Object
        ((@($after.permissions.allow) -join '|') -ceq 'Bash(echo *)|WebSearch|Bash(git status *)') -and ((@($after.permissions.ask) -join '|') -ceq 'Read(**/.env)') -and ((@($after.permissions.deny) -join '|') -ceq 'Read(**/auth.json)')
    }
    Test-Case 'S04 enabledPlugins 既有的 false 保留，缺少的項目新增' {
        $fixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $null = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        $after = (Read-ClaudeSettingsFile -Path $fixture.Settings).Object
        $after.enabledPlugins.'microsoft-docs@claude-plugins-official' -eq $false -and $after.enabledPlugins.'ai-agents-hooks@ai-agents-local' -eq $true
    }
    Test-Case 'S05 第二次執行回報 unchanged，檔案雜湊與修改時間不變，不產生新備份' {
        $fixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $null = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        $hash = Get-TestHash $fixture.Settings
        $time = (Get-Item -LiteralPath $fixture.Settings).LastWriteTimeUtc.Ticks
        $backupCount = @(Get-ChildItem -LiteralPath $fixture.Backups).Count
        Start-Sleep -Milliseconds 1100
        $second = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        $second.Status -eq 'unchanged' -and (Get-TestHash $fixture.Settings) -ceq $hash -and (Get-Item -LiteralPath $fixture.Settings).LastWriteTimeUtc.Ticks -eq $time -and @(Get-ChildItem -LiteralPath $fixture.Backups).Count -eq $backupCount
    }
    Test-Case 'S06 合併成功時備份與 manifest.txt 存在，備份內容與原檔位元組相同' {
        $fixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $originalHash = Get-TestHash $fixture.Settings
        $result = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        $manifest = Join-Path (Split-Path -Parent $result.BackupPath) 'manifest.txt'
        (Test-Path -LiteralPath $result.BackupPath) -and (Get-TestHash $result.BackupPath) -ceq $originalHash -and (Test-Path -LiteralPath $manifest) -and
        ([IO.File]::ReadAllText($manifest) -match '套用 settings 範本') -and (Get-TestHash $fixture.Settings) -cne $originalHash
    }
    Test-Case 'S07 -WhatIf 不產生備份、不改檔，仍列出 Changes' {
        $fixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $hash = Get-TestHash $fixture.Settings
        $result = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups -WhatIf
        $created = Invoke-ClaudeSettingsApply -SettingsPath (Join-Path $fixture.Directory 'new\settings.json') -TemplatePath $fixture.Template -BackupRoot $fixture.Backups -WhatIf
        $result.Status -eq 'whatif' -and @($result.Changes).Count -gt 0 -and (Get-TestHash $fixture.Settings) -ceq $hash -and -not (Test-Path -LiteralPath $fixture.Backups) -and
        $created.Status -eq 'whatif' -and -not (Test-Path -LiteralPath (Join-Path $fixture.Directory 'new\settings.json'))
    }
    Test-Case 'S08 巢狀深度超過 ConvertTo-Json 預設深度的內容完整保留（-Depth 32 未截斷）' {
        $deep = '"leaf"'
        for ($i = 0; $i -lt 10; $i++) { $deep = '{"level' + $i + '":' + $deep + ',"sibling' + $i + '":[1,{"x":true}]}' }
        $fixture = New-SettingsFixture -ExistingText ('{"deep":' + $deep + '}')
        $before = (Read-ClaudeSettingsFile -Path $fixture.Settings).Object
        $result = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        $after = (Read-ClaudeSettingsFile -Path $fixture.Settings).Object
        $result.Status -eq 'merged' -and (Test-ClaudeSettingsPreserved -Before $before -After $after) -and ((($after.deep | ConvertTo-Json -Depth 32) -ceq ($before.deep | ConvertTo-Json -Depth 32)))
    }
    Test-Case 'S09 日期樣式字串、空陣列、空物件與 null 經合併後不被改寫' {
        $fixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $null = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        $after = (Read-ClaudeSettingsFile -Path $fixture.Settings).Object
        $after.stamp -is [string] -and $after.stamp -ceq '2026-11-18T10:00:00Z' -and $after.emptyArray -is [array] -and $after.emptyArray.Count -eq 0 -and
        (Test-ClaudeUserConfigJsonObject $after.emptyObject) -and @($after.emptyObject.PSObject.Properties).Count -eq 0 -and $null -eq $after.nothing -and $null -ne $after.PSObject.Properties['nothing']
    }
    Test-Case 'S10 Test-ClaudeSettingsPreserved 對遺失既有鍵、改值、截短陣列回傳 false，對新增鍵與陣列尾端附加回傳 true' {
        $before = '{"a":{"b":1},"c":[1,2],"d":"x"}' | ConvertFrom-Json
        $lostKey = '{"a":{},"c":[1,2],"d":"x"}' | ConvertFrom-Json
        $changedValue = '{"a":{"b":2},"c":[1,2],"d":"x"}' | ConvertFrom-Json
        $shortArray = '{"a":{"b":1},"c":[1],"d":"x"}' | ConvertFrom-Json
        $extended = '{"a":{"b":1,"z":0},"c":[1,2,3],"d":"x","e":1}' | ConvertFrom-Json
        $truncatedToString = '{"a":"{ b: 1 }","c":[1,2],"d":"x"}' | ConvertFrom-Json
        (-not (Test-ClaudeSettingsPreserved -Before $before -After $lostKey)) -and (-not (Test-ClaudeSettingsPreserved -Before $before -After $changedValue)) -and (-not (Test-ClaudeSettingsPreserved -Before $before -After $shortArray)) -and
        (-not (Test-ClaudeSettingsPreserved -Before $before -After $truncatedToString)) -and (Test-ClaudeSettingsPreserved -Before $before -After $extended)
    }
    Test-Case 'S11 驗證失敗時回報 failed 且不寫檔、不備份' {
        $fixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $hash = Get-TestHash $fixture.Settings
        function Test-ClaudeSettingsPreserved { param($Before, $After) return $false }
        $result = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        $result.Status -eq 'failed' -and (Get-TestHash $fixture.Settings) -ceq $hash -and -not (Test-Path -LiteralPath $fixture.Backups) -and @(Get-ChildItem -LiteralPath (Split-Path -Parent $fixture.Settings) -Filter '*.tmp-*').Count -eq 0
    }
    Test-Case 'S12 暫存檔取代失敗時回報 failed，原檔未改動且暫存檔被刪除' {
        $fixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $hash = Get-TestHash $fixture.Settings
        # 原檔設為唯讀：讀取與備份都成功，取代時失敗。
        Set-ItemProperty -LiteralPath $fixture.Settings -Name IsReadOnly -Value $true
        try { $result = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups }
        finally { Set-ItemProperty -LiteralPath $fixture.Settings -Name IsReadOnly -Value $false }
        $result.Status -eq 'failed' -and (Get-TestHash $fixture.Settings) -ceq $hash -and @(Get-ChildItem -LiteralPath (Split-Path -Parent $fixture.Settings) -Filter '*.tmp-*').Count -eq 0
    }
    Test-Case 'S13 範本不存在或無法剖析時回報 failed 且不寫任何檔案' {
        $fixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $hash = Get-TestHash $fixture.Settings
        $missing = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath (Join-Path $fixture.Directory 'none.json') -BackupRoot $fixture.Backups
        Write-TestFile $fixture.Template '{ not json'
        $broken = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        $missing.Status -eq 'failed' -and $broken.Status -eq 'failed' -and (Get-TestHash $fixture.Settings) -ceq $hash -and -not (Test-Path -LiteralPath $fixture.Backups)
    }

    # ---- settings 資料異常：5 種輸入各回報 refused，雜湊不變且不產生備份 ----
    $refusedInputs = [ordered]@{
        'bom'        = { [byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes('{"a":1}') }
        'encoding'   = { [byte[]](0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xFF, 0xFE, 0x22, 0x7D) }
        'parse'      = { [Text.Encoding]::UTF8.GetBytes('{ "a": ') }
        'not-object' = { [Text.Encoding]::UTF8.GetBytes('["a"]') }
        'duplicate'  = { [Text.Encoding]::UTF8.GetBytes('{"a":1,"A":2}') }
    }
    foreach ($key in $refusedInputs.Keys) {
        $bytesFactory = $refusedInputs[$key]
        Test-Case "S14 資料異常（$key）回報 refused，檔案雜湊不變，不產生備份" {
            $fixture = New-SettingsFixture
            New-Item -ItemType Directory -Path (Split-Path -Parent $fixture.Settings) -Force | Out-Null
            [IO.File]::WriteAllBytes($fixture.Settings, (& $bytesFactory))
            $hash = Get-TestHash $fixture.Settings
            $result = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
            $result.Status -eq 'refused' -and (Get-TestHash $fixture.Settings) -ceq $hash -and -not (Test-Path -LiteralPath $fixture.Backups) -and @(Get-ChildItem -LiteralPath (Split-Path -Parent $fixture.Settings) -Filter '*.tmp-*').Count -eq 0
        }
    }
    Test-Case 'S15 Read-ClaudeSettingsFile 對 5 種輸入回報對應的 Error 值' {
        $expected = @{ bom = 'bom'; encoding = 'encoding'; parse = 'parse'; 'not-object' = 'not-object'; duplicate = 'parse' }
        foreach ($key in $refusedInputs.Keys) {
            $path = Join-Path (New-TestDirectory) 's.json'
            [IO.File]::WriteAllBytes($path, (& $refusedInputs[$key]))
            Assert-True ((Read-ClaudeSettingsFile -Path $path).Error -ceq $expected[$key]) "Error 不符：$key"
        }
        $true
    }
    Test-Case 'S16 Get-ClaudeSettingsPlan 是純函式：不改動輸入的既有物件與範本' {
        $existing = New-ExistingSettingsText | ConvertFrom-Json
        $templateObject = New-SettingsTemplateText | ConvertFrom-Json
        $existingSnapshot = $existing | ConvertTo-Json -Depth 32 -Compress
        $templateSnapshot = $templateObject | ConvertTo-Json -Depth 32 -Compress
        $plan = Get-ClaudeSettingsPlan -Existing $existing -Template $templateObject
        ($existing | ConvertTo-Json -Depth 32 -Compress) -ceq $existingSnapshot -and ($templateObject | ConvertTo-Json -Depth 32 -Compress) -ceq $templateSnapshot -and
        @($plan.Changes | Where-Object { $_.Kind -eq 'add' }).Count -gt 0 -and (Get-ClaudeSettingsPlan -Existing $null -Template $templateObject).Result.theme -ceq 'dark'
    }

    # ---- WSL 狀態 ----
    $wslDirectory = New-TestDirectory
    Write-TestFile (Join-Path $wslDirectory 'wsl-ok.cmd') "@echo off`r`nexit /b 0`r`n"
    Write-TestFile (Join-Path $wslDirectory 'wsl-fail.cmd') "@echo off`r`nexit /b 1`r`n"
    Test-Case 'W01 結束碼 0 的 wsl 命令為 ok' { (Get-WslStatus -WslPath (Join-Path $wslDirectory 'wsl-ok.cmd')) -ceq 'ok' }
    Test-Case 'W02 結束碼非零的 wsl 命令為 missing' { (Get-WslStatus -WslPath (Join-Path $wslDirectory 'wsl-fail.cmd')) -ceq 'missing' }
    Test-Case 'W03 路徑不存在為 missing' { (Get-WslStatus -WslPath (Join-Path $wslDirectory 'none.cmd')) -ceq 'missing' }

    # ---- 連接埠探測 ----
    Test-Case 'X01 本機有監聽的連接埠為 true，關閉後為 false' {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $open = Test-TcpPortOpen -Port $port -TimeoutMs 2000
        $listener.Stop()
        $closed = Test-TcpPortOpen -Port $port -TimeoutMs 2000
        $open -and -not $closed
    }
    Test-Case 'X02 批次探測同時回傳多個連接埠的結果，且總耗時不超過單一逾時的數倍' {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $openPort = $listener.LocalEndpoint.Port
        $closedListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $closedListener.Start()
        $closedPort = $closedListener.LocalEndpoint.Port
        $closedListener.Stop()
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $map = Get-TcpPortOpenMap -Port @($openPort, $closedPort) -TimeoutMs 1000
        $watch.Stop()
        $listener.Stop()
        $map[$openPort] -and -not $map[$closedPort] -and $watch.ElapsedMilliseconds -lt 3000
    }

    # ---- 靜態檢查 ----
    $libText = [IO.File]::ReadAllText($libPath)
    $libBytes = [IO.File]::ReadAllBytes($libPath)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($libPath, [ref]$tokens, [ref]$parseErrors)
    function Get-FunctionRange {
        param([string]$Name)
        $function = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true) | Select-Object -First 1
        return $function.Extent
    }
    Test-Case 'G01 lib 沒有語法錯誤，檔首為 BOM 與 #Requires -Version 7.0' {
        $firstLine = ($libText.TrimStart([char]0xFEFF) -split "`r?`n")[0]
        $parseErrors.Count -eq 0 -and $libBytes[0] -eq 0xEF -and $libBytes[1] -eq 0xBB -and $libBytes[2] -eq 0xBF -and $firstLine -ceq '#Requires -Version 7.0'
    }
    Test-Case 'G02 lib 只定義函式，頂層沒有可執行陳述式' {
        $topLevel = @($ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] })
        $topLevel.Count -eq 0 -and $null -eq $ast.ParamBlock
    }
    Test-Case 'G03 lib 不使用連線型的 claude mcp 查詢命令' {
        $libText -notmatch 'claude mcp (list|get)' -and $libText -notmatch "'mcp',\s*'(list|get)'"
    }
    Test-Case 'G04 寫入檔案的 API 只出現在 Invoke-ClaudeSettingsApply 內' {
        $apply = Get-FunctionRange -Name 'Invoke-ClaudeSettingsApply'
        $hits = @($tokens | Where-Object { $_.Text -match 'Set-Content|WriteAllText|WriteAllBytes|Out-File|Add-Content|Move-Item|Remove-Item|Copy-Item|New-Item' })
        $outside = @($hits | Where-Object { $_.Extent.StartOffset -lt $apply.StartOffset -or $_.Extent.EndOffset -gt $apply.EndOffset })
        Assert-True ($hits.Count -gt 0) '沒有找到任何寫入 API，檢查失效'
        Assert-True ($outside.Count -eq 0) ('Invoke-ClaudeSettingsApply 之外的寫入 API：' + (($outside | ForEach-Object { $_.Text + '@' + $_.Extent.StartLineNumber }) -join ','))
        $true
    }
    Test-Case 'G05 .claude.json 字串只出現在 Get-ClaudeUserMcpServer 與檔頭註解' {
        $reader = Get-FunctionRange -Name 'Get-ClaudeUserMcpServer'
        $hits = @($tokens | Where-Object { $_.Kind -ne 'Comment' -and $_.Text -match '\.claude\.json' })
        $outside = @($hits | Where-Object { $_.Extent.StartOffset -lt $reader.StartOffset -or $_.Extent.EndOffset -gt $reader.EndOffset })
        Assert-True ($hits.Count -gt 0) '沒有找到 .claude.json 的引用，檢查失效'
        $outside.Count -eq 0
    }
    Test-Case 'G06 取代 settings.json 使用同目錄暫存檔與覆寫式 Move' {
        $libText -match 'settings\.json\.tmp-' -and $libText -match '\[IO\.File\]::Move\(\$temporaryPath, \$SettingsPath, \$true\)'
    }

    # ---- MCP 範本內容掃描 ----
    $mcpTemplateText = [IO.File]::ReadAllText($mcpTemplatePath)
    Test-Case 'T01 MCP 範本不含 headers、env、Bearer、token、磁碟機路徑或 /home/' {
        # 磁碟機路徑樣式要求冒號後為反斜線，或為「單一字母加冒號加斜線」且字母前不是其他英文字母（排除 http:// 的 p://）。
        $mcpTemplateText -cnotmatch 'headers|"env"|Bearer|token|(?<![A-Za-z])[A-Za-z]:[\\/]|[A-Za-z]:\\|/home/'
    }
    Test-Case 'T02 MCP 範本的佔位符只有 {distro} 與 {wslRepo}，檔案無 BOM' {
        $placeholders = @([regex]::Matches($mcpTemplateText, '\{[A-Za-z]+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        $bytes = [IO.File]::ReadAllBytes($mcpTemplatePath)
        ($placeholders -join ',') -ceq '{distro},{wslRepo}' -and -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)
    }
}
finally {
    if (Test-Path -LiteralPath $tempBase) { Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output "PASSED: $passed"
Write-Output "FAILED: $failed"
if ($failed -gt 0) { exit 1 }
exit 0
