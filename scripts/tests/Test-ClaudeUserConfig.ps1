#Requires -Version 7.0
[CmdletBinding()]
param()

# scripts/lib/claude-user-config.ps1 的測試：MCP 範本與登記計畫、官方外掛安裝流程、settings.json 合併與保護步驟、WSL 與連接埠探測。
# 以同名函式替身取代 lib 定義的 Invoke-ClaudeCli、Get-ClaudeList、Get-ClaudeProperty，所有檔案操作都在暫存目錄內進行，不碰真實的使用者設定。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$libPath = Join-Path $repoRoot 'scripts\lib\claude-user-config.ps1'
$mcpTemplatePath = Join-Path $repoRoot 'templates\claude-mcp-servers.json'
$settingsTemplatePath = Join-Path $repoRoot 'templates\claude-settings.shared.json'
$tempBase = Join-Path (Join-Path $env:LOCALAPPDATA 'Temp') ('claude-user-config-' + [guid]::NewGuid().ToString('N'))
$failed = 0
$passed = 0
$skipped = 0

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
        # 測試以 [pscustomobject]@{ Skip = '原因' } 表示環境條件不具備（例如沒有建立符號連結的權限）而略過。
        if ($result -is [pscustomobject] -and $null -ne $result.PSObject.Properties['Skip']) {
            $script:skipped++
            Write-Output "SKIP $Id $($result.Skip)"
            return
        }
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
  "theme": "dark",
  "tui": "fullscreen",
  "list": ["a", "b"],
  "enabledPlugins": {
    "microsoft-docs@claude-plugins-official": true,
    "ai-agents-hooks@ai-agents-local": true
  },
  "nested": { "inner": { "level": "x" } }
}
'@
}

function New-ExistingSettingsText {
    return @'
{
  "theme": "light",
  "model": "user-model",
  "customKey": { "nested": [1, 2, { "deep": true }] },
  "permissions": {
    "allow": ["Bash(echo *)", "WebSearch"],
    "deny": ["Read(**/auth.json)"],
    "additionalDirectories": ["extra-dir"]
  },
  "skipDangerousModePermissionPrompt": true,
  "list": ["z"],
  "enabledPlugins": { "microsoft-docs@claude-plugins-official": false },
  "nothing": null,
  "stamp": "2026-11-18T10:00:00Z",
  "emptyArray": [],
  "emptyObject": {}
}
'@
}

function Test-DirectoryHasClaude {
    param([string]$Directory)
    foreach ($name in @('claude.exe', 'claude.cmd', 'claude.bat', 'claude.ps1', 'claude')) {
        if (Test-Path -LiteralPath (Join-Path $Directory $name) -PathType Leaf -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

$originalPath = $env:PATH
try {
    New-Item -ItemType Directory -Path $tempBase -Force | Out-Null

    # 假的 claude：步驟函式以 Get-Command claude 判斷 CLI 是否存在，測試需要在沒裝 Claude Code 的電腦也能跑，且不能呼叫到真實的 CLI。
    # PATH 移除所有含 claude 執行檔的目錄，只留這個假的；假 claude 被呼叫時以結束碼 99 與錯誤訊息失敗。實際的 CLI 呼叫一律由 Invoke-ClaudeCli 與 Get-ClaudeList 替身取代。
    $fakeClaudeDirectory = Join-Path $tempBase 'fake-claude-bin'
    New-Item -ItemType Directory -Path $fakeClaudeDirectory -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $fakeClaudeDirectory 'claude.cmd'), "@echo off`r`necho fake claude must not be called 1>&2`r`nexit /b 99`r`n", (New-Object System.Text.UTF8Encoding($false)))
    $pathWithoutClaude = @($originalPath -split ';' | Where-Object { $_ -ne '' -and -not (Test-DirectoryHasClaude -Directory $_) })
    $env:PATH = (@($fakeClaudeDirectory) + $pathWithoutClaude) -join ';'

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
    Test-Case 'I04 已安裝未啟用，且 settings.json 沒有把它設為 false（沒有該項目、值為 true 或不是布林 false）時只呼叫 enable' {
        Reset-Stubs
        $script:ListHandler = {
            param($Arguments)
            if ($Arguments -contains 'marketplace') { , @([pscustomobject]@{ name = 'claude-plugins-official' }) }
            else { , @([pscustomobject]@{ id = 'microsoft-docs@claude-plugins-official'; enabled = $false }) }
        }
        $expected = Join-Arguments @('plugin', 'enable', 'microsoft-docs@claude-plugins-official')
        $withoutSettings = Install-ClaudeOfficialPlugin -PluginId 'microsoft-docs@claude-plugins-official'
        $withoutSettingsCalls = @($script:CliCalls | ForEach-Object { Join-Arguments $_ })
        $verdicts = @()
        foreach ($settingsText in @('{"theme":"x"}', '{"enabledPlugins":{"other@x":false}}', '{"enabledPlugins":{"microsoft-docs@claude-plugins-official":true}}', '{"enabledPlugins":{"microsoft-docs@claude-plugins-official":"false"}}')) {
            Reset-Stubs
            $script:ListHandler = {
                param($Arguments)
                if ($Arguments -contains 'marketplace') { , @([pscustomobject]@{ name = 'claude-plugins-official' }) }
                else { , @([pscustomobject]@{ id = 'microsoft-docs@claude-plugins-official'; enabled = $false }) }
            }
            $settingsPath = Join-Path (New-TestDirectory) 'settings.json'
            Write-TestFile $settingsPath $settingsText
            $result = Install-ClaudeOfficialPlugin -PluginId 'microsoft-docs@claude-plugins-official' -SettingsPath $settingsPath
            $verdicts += ($result.Status -eq 'enabled' -and $script:CliCalls.Count -eq 1 -and (Join-Arguments $script:CliCalls[0]) -ceq $expected)
        }
        $withoutSettings.Status -eq 'enabled' -and $withoutSettingsCalls.Count -eq 1 -and $withoutSettingsCalls[0] -ceq $expected -and @($verdicts | Where-Object { -not $_ }).Count -eq 0
    }
    Test-Case 'I08 settings.json 把官方外掛設為 false（已安裝未啟用）時不執行 enable，回傳 user-disabled，零次 CLI 呼叫' {
        Reset-Stubs
        $script:ListHandler = {
            param($Arguments)
            if ($Arguments -contains 'marketplace') { , @([pscustomobject]@{ name = 'claude-plugins-official' }) }
            else { , @([pscustomobject]@{ id = 'microsoft-docs@claude-plugins-official'; enabled = $false }) }
        }
        $settingsPath = Join-Path (New-TestDirectory) 'settings.json'
        Write-TestFile $settingsPath '{"enabledPlugins":{"microsoft-docs@claude-plugins-official":false}}'
        $hash = Get-TestHash $settingsPath
        $result = Install-ClaudeOfficialPlugin -PluginId 'microsoft-docs@claude-plugins-official' -SettingsPath $settingsPath
        $result.Status -eq 'user-disabled' -and $script:CliCalls.Count -eq 0 -and (Get-TestHash $settingsPath) -ceq $hash
    }
    Test-Case 'I09 settings.json 把官方外掛設為 false（尚未安裝）時也不安裝、不新增 marketplace，零次 CLI 呼叫' {
        Reset-Stubs
        $script:ListHandler = { param($Arguments) , @() }
        $settingsPath = Join-Path (New-TestDirectory) 'settings.json'
        Write-TestFile $settingsPath '{"enabledPlugins":{"microsoft-docs@claude-plugins-official":false}}'
        $result = Install-ClaudeOfficialPlugin -PluginId 'microsoft-docs@claude-plugins-official' -SettingsPath $settingsPath
        $result.Status -eq 'user-disabled' -and $script:CliCalls.Count -eq 0
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
    Test-Case 'I07 marketplace add 結束碼非零時立即停止，回報 CLI 原始輸出，不執行 plugin install' {
        Reset-Stubs
        $script:ListHandler = { param($Arguments) , @() }
        $rawOutput = "x Failed to add marketplace`r`nerror: Filename too long`r`nfatal: unable to checkout working tree"
        $script:CliHandler = { param($Arguments) [pscustomobject]@{ ExitCode = 1; Output = $rawOutput } }.GetNewClosure()
        $result = Install-ClaudeOfficialPlugin -PluginId 'microsoft-docs@claude-plugins-official'
        $result.Status -eq 'failed' -and $script:CliCalls.Count -eq 1 -and (Join-Arguments $script:CliCalls[0]) -ceq (Join-Arguments @('plugin', 'marketplace', 'add', 'anthropics/claude-plugins-official')) -and
        $result.Message.Contains('Filename too long') -and $result.Message.Contains('fatal: unable to checkout working tree') -and @($script:CliCalls | Where-Object { $_ -contains 'install' }).Count -eq 0
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
        $result.Status -eq 'merged' -and $after.theme -ceq 'light' -and $after.tui -ceq 'fullscreen' -and $after.model -ceq 'user-model' -and $after.nested.inner.level -ceq 'x' -and
        $after.customKey.nested[2].deep -eq $true -and $after.permissions.additionalDirectories[0] -ceq 'extra-dir' -and
        @($kept | ForEach-Object { $_.Path }) -contains 'theme' -and (($result.Changes | ConvertTo-Json -Depth 4) -notmatch 'light')
    }
    Test-Case 'S03 陣列鍵保留既有內容不合併；permissions 與 skipDangerousModePermissionPrompt 原樣不變，Changes 不含這兩個鍵' {
        $fixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $before = (Read-ClaudeSettingsFile -Path $fixture.Settings).Object
        $result = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        $after = (Read-ClaudeSettingsFile -Path $fixture.Settings).Object
        $paths = @($result.Changes | ForEach-Object { $_.Path })
        ((@($after.list) -join '|') -ceq 'z') -and $paths -contains 'list' -and
        (Test-ClaudeUserConfigJsonEqual $before.permissions $after.permissions) -and $after.skipDangerousModePermissionPrompt -eq $true -and
        @($paths | Where-Object { $_ -match '^permissions|^skipDangerousModePermissionPrompt' }).Count -eq 0
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

    # ---- 受保護寫入：取代前確認原檔未被改動（GW01、GW02、S17）、連結（GW03 至 GW05、S18、S19）、備份取自讀到的位元組（GW06） ----
    function Get-TestTemporaryFile {
        param([string]$Directory)
        return , @(Get-ChildItem -LiteralPath $Directory -Force | Where-Object { $_.Name -like '*.tmp-*' })
    }
    Test-Case 'GW01 Write-ConfigFileGuarded：原檔與讀取時相同才寫入並讀回；不同時回傳 changed，原檔保留改動後的內容，不留暫存檔' {
        $directory = New-TestDirectory
        $path = Join-Path $directory 'a.bin'
        [IO.File]::WriteAllBytes($path, [byte[]](1, 2, 3))
        $written = Write-ConfigFileGuarded -Path $path -ExpectedBytes ([byte[]](1, 2, 3)) -NewBytes ([byte[]](9, 9))
        $afterWritten = [Convert]::ToHexString([IO.File]::ReadAllBytes($path))
        [IO.File]::WriteAllBytes($path, [byte[]](5, 5))
        $changed = Write-ConfigFileGuarded -Path $path -ExpectedBytes ([byte[]](9, 9)) -NewBytes ([byte[]](7, 7, 7))
        $written -ceq 'written' -and $afterWritten -ceq '0909' -and $changed -ceq 'changed' -and [Convert]::ToHexString([IO.File]::ReadAllBytes($path)) -ceq '0505' -and (Get-TestTemporaryFile -Directory $directory).Count -eq 0
    }
    Test-Case 'GW02 Write-ConfigFileGuarded：預期檔案不存在（建立新檔）時，目標已出現就回傳 changed 且不覆寫；原檔為空檔也能比對' {
        $directory = New-TestDirectory
        $path = Join-Path $directory 'new.bin'
        $created = Write-ConfigFileGuarded -Path $path -ExpectedBytes $null -NewBytes ([byte[]](1))
        [IO.File]::WriteAllBytes($path, [byte[]](2))
        $raced = Write-ConfigFileGuarded -Path $path -ExpectedBytes $null -NewBytes ([byte[]](3))
        $emptyPath = Join-Path $directory 'empty.bin'
        [IO.File]::WriteAllBytes($emptyPath, [byte[]]@())
        $fromEmpty = Write-ConfigFileGuarded -Path $emptyPath -ExpectedBytes ([byte[]]@()) -NewBytes ([byte[]](4))
        $created -ceq 'written' -and $raced -ceq 'changed' -and [Convert]::ToHexString([IO.File]::ReadAllBytes($path)) -ceq '02' -and $fromEmpty -ceq 'written' -and [Convert]::ToHexString([IO.File]::ReadAllBytes($emptyPath)) -ceq '04' -and (Get-TestTemporaryFile -Directory $directory).Count -eq 0
    }
    Test-Case 'GW03 Resolve-ConfigWriteTarget：一般檔案為本身；目錄不是可寫入的檔案；硬連結要求原地寫入' {
        $directory = New-TestDirectory
        $plain = Join-Path $directory 'plain.txt'
        [IO.File]::WriteAllBytes($plain, [byte[]](1))
        $hardLink = Join-Path $directory 'hard.txt'
        $null = New-Item -ItemType HardLink -Path $hardLink -Target $plain
        $asPlain = Resolve-ConfigWriteTarget -Path $plain
        $asDirectory = Resolve-ConfigWriteTarget -Path $directory
        $asHard = Resolve-ConfigWriteTarget -Path $hardLink
        $asMissing = Resolve-ConfigWriteTarget -Path (Join-Path $directory 'none.txt')
        $asPlain.Ok -and $asPlain.Path -ceq $plain -and $asHard.Ok -and $asHard.InPlace -and -not $asDirectory.Ok -and -not $asMissing.Ok
    }
    Test-Case 'GW04 Resolve-ConfigWriteTarget 解析連結鏈：相對目標、多層連結、連結指向不存在的目標、無法解析目標的重分析點，後兩者回報不可寫入（以替身模擬 Get-Item，不需要建立符號連結的權限）' {
        $baseDirectory = Join-Path (New-TestDirectory) 'dot'
        $linkPath = Join-Path $baseDirectory 'link.toml'
        $secondLink = Join-Path $baseDirectory 'link2.toml'
        $realPath = Join-Path $baseDirectory 'real\config.toml'
        $danglingLink = Join-Path $baseDirectory 'dangling.toml'
        $opaqueLink = Join-Path $baseDirectory 'opaque.toml'
        $items = @{
            $linkPath      = [pscustomobject]@{ PSIsContainer = $false; Attributes = [IO.FileAttributes]::ReparsePoint; LinkType = 'SymbolicLink'; Target = @('real\config.toml') }
            $secondLink    = [pscustomobject]@{ PSIsContainer = $false; Attributes = [IO.FileAttributes]::ReparsePoint; LinkType = 'SymbolicLink'; Target = @($linkPath) }
            $realPath      = [pscustomobject]@{ PSIsContainer = $false; Attributes = [IO.FileAttributes]::Archive; LinkType = $null; Target = $null }
            $danglingLink  = [pscustomobject]@{ PSIsContainer = $false; Attributes = [IO.FileAttributes]::ReparsePoint; LinkType = 'SymbolicLink'; Target = @('gone\config.toml') }
            $opaqueLink    = [pscustomobject]@{ PSIsContainer = $false; Attributes = [IO.FileAttributes]::ReparsePoint; LinkType = $null; Target = $null }
        }
        function Get-Item {
            param([string]$LiteralPath, [switch]$Force, $ErrorAction)
            if (-not $items.ContainsKey($LiteralPath)) { throw "not found: $LiteralPath" }
            return $items[$LiteralPath]
        }
        $relative = Resolve-ConfigWriteTarget -Path $linkPath
        $chained = Resolve-ConfigWriteTarget -Path $secondLink
        $dangling = Resolve-ConfigWriteTarget -Path $danglingLink
        $opaque = Resolve-ConfigWriteTarget -Path $opaqueLink
        $relative.Ok -and $relative.Path -ceq $realPath -and -not $relative.InPlace -and $chained.Ok -and $chained.Path -ceq $realPath -and -not $dangling.Ok -and $dangling.Message.Length -gt 0 -and -not $opaque.Ok -and $opaque.Message.Contains('無法解析目標')
    }
    Test-Case 'GW05 Save-ConfigFileBackup：同一個 Context 的各檔案共用一個備份目錄並以相對路徑區分，內容取自傳入的位元組，manifest.txt 每個檔案一行；另一個 Context 取得不同的目錄' {
        $root = Join-Path (New-TestDirectory) 'backups'
        $context = New-ConfigBackupContext
        $first = Save-ConfigFileBackup -Context $context -BackupRoot $root -RelativePath 'desktop\config.toml' -Bytes ([byte[]](1, 2)) -SourcePath 'X:\a\config.toml' -Operation '操作甲'
        $second = Save-ConfigFileBackup -Context $context -BackupRoot $root -RelativePath 'accounts\acct\config.toml' -Bytes ([byte[]](3)) -SourcePath 'X:\b\config.toml' -Operation '操作乙'
        $other = New-ConfigBackupContext
        $third = Save-ConfigFileBackup -Context $other -BackupRoot $root -RelativePath 'settings.json' -Bytes ([byte[]](4)) -SourcePath 'X:\c\settings.json' -Operation '操作丙'
        $manifest = @(Get-Content -LiteralPath (Join-Path $context.Directory 'manifest.txt'))
        (Split-Path -Parent (Split-Path -Parent $first)) -ceq $context.Directory -and (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $second))) -ceq $context.Directory -and
        [Convert]::ToHexString([IO.File]::ReadAllBytes($first)) -ceq '0102' -and [Convert]::ToHexString([IO.File]::ReadAllBytes($second)) -ceq '03' -and
        $manifest.Count -eq 2 -and $manifest[0].Contains('X:\a\config.toml') -and $manifest[0].Contains('操作甲') -and $manifest[1].Contains('X:\b\config.toml') -and
        $other.Directory -cne $context.Directory -and (Split-Path -Parent $third) -ceq $other.Directory
    }
    Test-Case 'GW07 Save-ConfigFileBackup 接受 0 位元組（空陣列與 $null）：備份出 0 位元組的檔案並正常記錄 manifest' {
        $root = Join-Path (New-TestDirectory) 'backups'
        $context = New-ConfigBackupContext
        $fromEmpty = Save-ConfigFileBackup -Context $context -BackupRoot $root -RelativePath 'a\config.toml' -Bytes ([byte[]]@()) -SourcePath 'X:\a\config.toml' -Operation '空檔'
        $fromNull = Save-ConfigFileBackup -Context $context -BackupRoot $root -RelativePath 'b\config.toml' -Bytes $null -SourcePath 'X:\b\config.toml' -Operation '空檔'
        (Get-Item -LiteralPath $fromEmpty).Length -eq 0 -and (Get-Item -LiteralPath $fromNull).Length -eq 0 -and @(Get-Content -LiteralPath (Join-Path $context.Directory 'manifest.txt')).Count -eq 2
    }
    Test-Case 'GW06 備份內容是讀到的位元組：讀取後原檔被改動時，備份仍是讀取時的內容（取代前再由比對攔下）' {
        $fixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $originalHash = Get-TestHash $fixture.Settings
        $originalSave = ${function:Save-ConfigFileBackup}
        function Save-ConfigFileBackup {
            param($Context, $BackupRoot, $RelativePath, $Bytes, $SourcePath, $Operation)
            [IO.File]::AppendAllText($SourcePath, "`n", (New-Object System.Text.UTF8Encoding($false)))
            return (& $originalSave -Context $Context -BackupRoot $BackupRoot -RelativePath $RelativePath -Bytes $Bytes -SourcePath $SourcePath -Operation $Operation)
        }
        $result = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        $result.Status -eq 'changed' -and (Get-TestHash $result.BackupPath) -ceq $originalHash
    }
    Test-Case 'S17 讀取之後原檔被其他程式改動時不寫入：回報 changed，改動後的內容保留，備份仍是讀取時的內容，不留暫存檔' {
        $fixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $originalHash = Get-TestHash $fixture.Settings
        $originalSave = ${function:Save-ConfigFileBackup}
        function Save-ConfigFileBackup {
            # 模擬備份之後、取代之前有其他程式寫入（附加一個空白，內容仍是合法的 JSON）。
            param($Context, $BackupRoot, $RelativePath, $Bytes, $SourcePath, $Operation)
            $path = & $originalSave -Context $Context -BackupRoot $BackupRoot -RelativePath $RelativePath -Bytes $Bytes -SourcePath $SourcePath -Operation $Operation
            [IO.File]::AppendAllText($SourcePath, ' ', (New-Object System.Text.UTF8Encoding($false)))
            return $path
        }
        $result = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        $text = [IO.File]::ReadAllText($fixture.Settings)
        $result.Status -eq 'changed' -and $result.Message.Contains('被其他程式改動') -and $text.EndsWith('} ') -and $text.Contains('"theme": "light"') -and -not $text.Contains('ai-agents-hooks') -and
        (Get-TestHash $result.BackupPath) -ceq $originalHash -and (Get-TestTemporaryFile -Directory (Split-Path -Parent $fixture.Settings)).Count -eq 0
    }
    Test-Case 'S18 settings.json 是符號連結時寫入連結指向的實際檔案：連結仍是連結，目標檔內容更新，備份是目標檔的原內容（沒有建立符號連結的權限時略過）' {
        $directory = New-TestDirectory
        $realPath = Join-Path $directory 'dotfiles\settings.json'
        $linkPath = Join-Path $directory 'claude\settings.json'
        Write-TestFile $realPath (New-ExistingSettingsText)
        New-Item -ItemType Directory -Path (Split-Path -Parent $linkPath) -Force | Out-Null
        try { $null = New-Item -ItemType SymbolicLink -Path $linkPath -Target $realPath -ErrorAction Stop }
        catch { return [pscustomobject]@{ Skip = '沒有建立符號連結的權限' } }
        $templatePath = Join-Path $directory 'settings.shared.json'
        Write-TestFile $templatePath (New-SettingsTemplateText)
        $originalHash = Get-TestHash $realPath
        $result = Invoke-ClaudeSettingsApply -SettingsPath $linkPath -TemplatePath $templatePath -BackupRoot (Join-Path $directory 'backups')
        $linkItem = Get-Item -LiteralPath $linkPath -Force
        $result.Status -eq 'merged' -and ($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -and (Get-TestHash $realPath) -cne $originalHash -and
        $null -ne (Read-ClaudeSettingsFile -Path $realPath).Object.enabledPlugins.PSObject.Properties['ai-agents-hooks@ai-agents-local'] -and (Get-TestHash $result.BackupPath) -ceq $originalHash
    }
    Test-Case 'S19 settings.json 是硬連結時原地寫入，連結關係保留：另一個名稱看到相同的新內容，備份是原內容' {
        $directory = New-TestDirectory
        $realPath = Join-Path $directory 'dotfiles\settings.json'
        $linkPath = Join-Path $directory 'claude\settings.json'
        Write-TestFile $realPath (New-ExistingSettingsText)
        New-Item -ItemType Directory -Path (Split-Path -Parent $linkPath) -Force | Out-Null
        $null = New-Item -ItemType HardLink -Path $linkPath -Target $realPath
        $templatePath = Join-Path $directory 'settings.shared.json'
        Write-TestFile $templatePath (New-SettingsTemplateText)
        $originalHash = Get-TestHash $realPath
        $result = Invoke-ClaudeSettingsApply -SettingsPath $linkPath -TemplatePath $templatePath -BackupRoot (Join-Path $directory 'backups')
        $result.Status -eq 'merged' -and (Get-TestHash $realPath) -ceq (Get-TestHash $linkPath) -and (Get-TestHash $realPath) -cne $originalHash -and [string](Get-Item -LiteralPath $linkPath -Force).LinkType -ceq 'HardLink' -and
        (Get-TestHash $result.BackupPath) -ceq $originalHash -and (Get-TestTemporaryFile -Directory (Split-Path -Parent $linkPath)).Count -eq 0
    }
    Test-Case 'S20 寫入目標無法確定（連結指向不存在的目標等）時回報 unresolved，不備份、不寫入' {
        $fixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $hash = Get-TestHash $fixture.Settings
        function Resolve-ConfigWriteTarget {
            param([string]$Path)
            return [pscustomobject]@{ Ok = $false; Path = $Path; InPlace = $false; Message = '連結指向不存在的目標' }
        }
        $result = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        $result.Status -eq 'unresolved' -and $result.Message.Contains('連結指向不存在的目標') -and (Get-TestHash $fixture.Settings) -ceq $hash -and -not (Test-Path -LiteralPath $fixture.Backups)
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

    # ---- Setup 步驟 8d、8e、8f 的內容（輸出與略過條件） ----
    function Invoke-Captured {
        param([scriptblock]$Action)
        $captured = [pscustomobject]@{ Result = @(); Warnings = @(); Info = @(); Error = $null }
        try {
            $stream = @(& $Action 3>&1 6>&1)
            $captured.Warnings = @($stream | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
            $captured.Info = @($stream | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
            $captured.Result = @($stream | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] -and $_ -isnot [System.Management.Automation.InformationRecord] })
        }
        catch { $captured.Error = $_.Exception.Message }
        return $captured
    }

    function Invoke-WithoutClaude {
        # PATH 只含一個空目錄，使 Get-Command claude 找不到命令。
        param([scriptblock]$Action)
        $savedPath = $env:PATH
        $emptyDirectory = New-TestDirectory
        try { $env:PATH = $emptyDirectory; return (Invoke-Captured -Action $Action) }
        finally { $env:PATH = $savedPath }
    }

    function New-UserMcpFile {
        param([string[]]$Exclude = @())
        $directory = New-TestDirectory
        $path = Join-Path $directory 'claude.json'
        $existing = New-ExistingRegistrations -Template $template
        foreach ($name in $Exclude) { $existing.Remove($name) }
        Write-TestFile $path (@{ mcpServers = $existing } | ConvertTo-Json -Depth 8)
        return $path
    }

    Test-Case 'ST01 官方外掛步驟：marketplace 與外掛都缺少時依序 add、install，輸出外掛名稱' {
        Reset-Stubs
        $script:ListHandler = { param($Arguments) , @() }
        $captured = Invoke-Captured { Invoke-ClaudeOfficialPluginStep -SettingsTemplatePath $settingsTemplatePath }
        $null -eq $captured.Error -and $captured.Result.Count -eq 1 -and $captured.Result[0].Status -eq 'installed' -and $script:CliCalls.Count -eq 2 -and (($captured.Info -join "`n") -match 'microsoft-docs@claude-plugins-official')
    }
    Test-Case 'ST02 官方外掛步驟：marketplace add 失敗時以警告回報 CLI 原始輸出，不執行 install' {
        Reset-Stubs
        $script:ListHandler = { param($Arguments) , @() }
        $script:CliHandler = { param($Arguments) [pscustomobject]@{ ExitCode = 1; Output = 'Filename too long raw output' } }
        $captured = Invoke-Captured { Invoke-ClaudeOfficialPluginStep -SettingsTemplatePath $settingsTemplatePath }
        $null -eq $captured.Error -and $captured.Result[0].Status -eq 'failed' -and $script:CliCalls.Count -eq 1 -and (($captured.Warnings -join "`n") -match 'Filename too long raw output')
    }
    Test-Case 'ST03 官方外掛步驟：找不到 claude 時擲出例外且零次呼叫；範本不存在時無動作' {
        Reset-Stubs
        $noClaude = Invoke-WithoutClaude { Invoke-ClaudeOfficialPluginStep -SettingsTemplatePath $settingsTemplatePath }
        $noTemplate = Invoke-Captured { Invoke-ClaudeOfficialPluginStep -SettingsTemplatePath (Join-Path (New-TestDirectory) 'none.json') }
        $noClaude.Error -match '找不到 claude CLI' -and $script:CliCalls.Count -eq 0 -and $null -eq $noTemplate.Error -and $noTemplate.Result.Count -eq 0
    }
    $allPluginsInstalled = {
        param($Arguments)
        , @([pscustomobject]@{ id = 'ai-agents-hooks@ai-agents-local'; enabled = $true }, [pscustomobject]@{ id = 'line-status-board@ai-agents-local'; enabled = $true }, [pscustomobject]@{ id = 'microsoft-docs@claude-plugins-official'; enabled = $true })
    }
    Test-Case 'F01 PATH 上只有假的 claude：Get-Command 找到的是測試的假命令，不會呼叫到真實的 CLI' {
        $found = @(Get-Command -Name 'claude' -CommandType Application -All -ErrorAction SilentlyContinue)
        $found.Count -eq 1 -and $found[0].Source.StartsWith($fakeClaudeDirectory, [StringComparison]::OrdinalIgnoreCase)
    }
    Test-Case 'ST04 settings 步驟：不存在時建立並輸出新增路徑；-WhatIf 不寫檔' {
        Reset-Stubs
        $script:ListHandler = $allPluginsInstalled
        $fixture = New-SettingsFixture
        Copy-Item -LiteralPath $settingsTemplatePath -Destination $fixture.Template -Force
        $whatIf = Invoke-Captured { Invoke-ClaudeSettingsStep -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups -WhatIf }
        $existedAfterWhatIf = Test-Path -LiteralPath $fixture.Settings
        $captured = Invoke-Captured { Invoke-ClaudeSettingsStep -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups }
        $null -eq $whatIf.Error -and -not $existedAfterWhatIf -and $null -eq $captured.Error -and $captured.Result[0].Status -eq 'created' -and (Test-Path -LiteralPath $fixture.Settings) -and (($captured.Info -join "`n") -match '新增：enabledPlugins')
    }
    Test-Case 'ST05 settings 步驟：找不到 claude、範本不存在時擲出例外；資料異常時以警告回報且不寫檔' {
        Reset-Stubs
        $script:ListHandler = $allPluginsInstalled
        $fixture = New-SettingsFixture
        $noClaude = Invoke-WithoutClaude { Invoke-ClaudeSettingsStep -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups }
        $noTemplate = Invoke-Captured { Invoke-ClaudeSettingsStep -SettingsPath $fixture.Settings -TemplatePath (Join-Path $fixture.Directory 'none.json') -BackupRoot $fixture.Backups }
        New-Item -ItemType Directory -Path (Split-Path -Parent $fixture.Settings) -Force | Out-Null
        [IO.File]::WriteAllBytes($fixture.Settings, (& $refusedInputs['bom']))
        $hash = Get-TestHash $fixture.Settings
        $refused = Invoke-Captured { Invoke-ClaudeSettingsStep -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups }
        $noClaude.Error -match '找不到 claude CLI' -and $noTemplate.Error -match '找不到 settings 範本' -and $null -eq $refused.Error -and $refused.Result[0].Status -eq 'refused' -and
        (($refused.Warnings -join "`n") -match '無法安全合併') -and (Get-TestHash $fixture.Settings) -ceq $hash -and -not (Test-Path -LiteralPath $fixture.Backups)
    }
    Test-Case 'ST06 MCP 步驟：只對缺少的項目呼叫 mcp add，輸出登記名稱與重新啟動 Session 的說明' {
        Reset-Stubs
        $userMcp = New-UserMcpFile -Exclude @('mcp-docker', 'infra-lab')
        $captured = Invoke-Captured { Invoke-ClaudeMcpStep -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo }
        $info = $captured.Info -join "`n"
        $null -eq $captured.Error -and $script:CliCalls.Count -eq 2 -and @($captured.Result | Where-Object { $_.Status -eq 'added' }).Count -eq 2 -and $info -match 'MCP 登記：mcp-docker' -and $info -match 'MCP 登記：infra-lab' -and
        $info -match '10 項已登記且與範本相符' -and $info -match '重新啟動 Claude Code'
    }
    Test-Case 'ST07 MCP 步驟：infra-lab 缺值時警告 needs-values 且不呼叫；未新登記時不印重新啟動說明' {
        Reset-Stubs
        $userMcp = New-UserMcpFile -Exclude @('infra-lab')
        $captured = Invoke-Captured { Invoke-ClaudeMcpStep -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -InfraLabDistro '' -InfraLabWslRepo '' }
        $null -eq $captured.Error -and $script:CliCalls.Count -eq 0 -and (($captured.Warnings -join "`n") -match '-InfraLabDistro') -and (($captured.Info -join "`n") -notmatch '重新啟動 Claude Code')
    }
    Test-Case 'ST08 MCP 步驟：差異只回報不覆寫，警告不含現有值；-WhatIf 零次呼叫' {
        Reset-Stubs
        $userMcp = New-UserMcpFile
        $json = [IO.File]::ReadAllText($userMcp).Replace('9840', '19999')
        Write-TestFile $userMcp $json
        $differs = Invoke-Captured { Invoke-ClaudeMcpStep -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo }
        $emptyMcp = New-UserMcpFile -Exclude ($template | ForEach-Object { $_.Name })
        $whatIf = Invoke-Captured { Invoke-ClaudeMcpStep -McpTemplatePath $mcpTemplatePath -UserMcpPath $emptyMcp -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo -WhatIf }
        $null -eq $differs.Error -and (($differs.Warnings -join "`n") -match 'claude mcp remove mcp-reader --scope user') -and (($differs.Warnings -join "`n") -notmatch '19999') -and
        $null -eq $whatIf.Error -and $script:CliCalls.Count -eq 0 -and @($whatIf.Result | Where-Object { $_.Status -eq 'whatif' }).Count -eq 12
    }
    Test-Case 'ST09 MCP 步驟：登記檔無法讀取、範本無效或找不到 claude 時擲出例外且零次呼叫；登記檔不存在時全部登記' {
        Reset-Stubs
        $directory = New-TestDirectory
        Write-TestFile (Join-Path $directory 'bad.json') '{ not json'
        $unreadable = Invoke-Captured { Invoke-ClaudeMcpStep -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path $directory 'bad.json') -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo }
        $badTemplate = Invoke-Captured { Invoke-ClaudeMcpStep -McpTemplatePath (Join-Path $directory 'none.json') -UserMcpPath (Join-Path $directory 'none-user.json') -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo }
        $noClaude = Invoke-WithoutClaude { Invoke-ClaudeMcpStep -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path $directory 'none-user.json') -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo }
        $zeroCalls = $script:CliCalls.Count -eq 0
        $fresh = Invoke-Captured { Invoke-ClaudeMcpStep -McpTemplatePath $mcpTemplatePath -UserMcpPath (Join-Path $directory 'none-user.json') -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo }
        $unreadable.Error -match '無法讀取' -and $badTemplate.Error -match '找不到 MCP 範本' -and $noClaude.Error -match '找不到 claude CLI' -and $zeroCalls -and $script:CliCalls.Count -eq 12 -and @($fresh.Result | Where-Object { $_.Status -eq 'added' }).Count -eq 12
    }

    Test-Case 'ST10 MCP 步驟的 -Group：只處理所選群組，未選的伺服器不登記；省略時處理範本全部' {
        Reset-Stubs
        $emptyMcp = New-UserMcpFile -Exclude ($template | ForEach-Object { $_.Name })
        $lab = Invoke-Captured { Invoke-ClaudeMcpStep -McpTemplatePath $mcpTemplatePath -UserMcpPath $emptyMcp -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo -Group @('mcp-lab') }
        $labCalls = $script:CliCalls.Count
        $labNames = @($script:CliCalls | ForEach-Object { $_[6] })
        Reset-Stubs
        $infra = Invoke-Captured { Invoke-ClaudeMcpStep -McpTemplatePath $mcpTemplatePath -UserMcpPath $emptyMcp -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo -Group @('infra-lab') }
        $infraCalls = $script:CliCalls.Count
        $infraName = $script:CliCalls[0][6]
        Reset-Stubs
        $both = Invoke-Captured { Invoke-ClaudeMcpStep -McpTemplatePath $mcpTemplatePath -UserMcpPath $emptyMcp -InfraLabDistro $infraLabDistro -InfraLabWslRepo $infraLabRepo -Group @('mcp-lab', 'infra-lab') }
        $null -eq $lab.Error -and $labCalls -eq 11 -and ($labNames -notcontains 'infra-lab') -and $null -eq $infra.Error -and $infraCalls -eq 1 -and $infraName -ceq 'infra-lab' -and $script:CliCalls.Count -eq 12
    }
    Test-Case 'ST11 MCP 步驟的 -Group infra-lab 缺值時警告 needs-values 且不呼叫；已登記的其他伺服器不受影響' {
        Reset-Stubs
        $userMcp = New-UserMcpFile -Exclude @('infra-lab')
        $captured = Invoke-Captured { Invoke-ClaudeMcpStep -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcp -InfraLabDistro '' -InfraLabWslRepo '' -Group @('infra-lab') }
        $null -eq $captured.Error -and $script:CliCalls.Count -eq 0 -and @($captured.Result).Count -eq 1 -and $captured.Result[0].Status -eq 'needs-values' -and (($captured.Warnings -join "`n") -match '重新執行登記腳本')
    }

    # ---- 外掛安裝失敗時 settings.json 不寫入該外掛的 enabledPlugins ----
    Test-Case 'PL01 外掛未安裝（安裝失敗或略過）時，settings 步驟略過該外掛的 enabledPlugins 並在警告說明原因，其餘項目照常寫入' {
        Reset-Stubs
        $script:ListHandler = { param($Arguments) , @([pscustomobject]@{ id = 'ai-agents-hooks@ai-agents-local'; enabled = $true }, [pscustomobject]@{ id = 'line-status-board@ai-agents-local'; enabled = $true }) }
        $fixture = New-SettingsFixture
        Copy-Item -LiteralPath $settingsTemplatePath -Destination $fixture.Template -Force
        $captured = Invoke-Captured { Invoke-ClaudeSettingsStep -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups }
        $written = Read-ClaudeSettingsFile -Path $fixture.Settings
        $plugins = $written.Object.enabledPlugins
        $null -eq $captured.Error -and $captured.Result[0].Status -eq 'created' -and $null -ne $plugins.PSObject.Properties['ai-agents-hooks@ai-agents-local'] -and $null -ne $plugins.PSObject.Properties['line-status-board@ai-agents-local'] -and
        $null -eq $plugins.PSObject.Properties['microsoft-docs@claude-plugins-official'] -and @($captured.Warnings | Where-Object { $_.Contains('microsoft-docs@claude-plugins-official') -and $_.Contains('外掛尚未安裝') }).Count -eq 1 -and
        @($captured.Result[0].Skipped).Count -eq 1
    }
    Test-Case 'PL02 已有 settings.json 且外掛未安裝：既有內容與使用者值不變，只略過該項；重跑（外掛補裝後）才補上' {
        Reset-Stubs
        $script:ListHandler = { param($Arguments) , @([pscustomobject]@{ id = 'ai-agents-hooks@ai-agents-local'; enabled = $true }, [pscustomobject]@{ id = 'line-status-board@ai-agents-local'; enabled = $true }) }
        $fixture = New-SettingsFixture -ExistingText '{"theme":"light","enabledPlugins":{"ai-agents-hooks@ai-agents-local":true,"line-status-board@ai-agents-local":true}}'
        Copy-Item -LiteralPath $settingsTemplatePath -Destination $fixture.Template -Force
        $hash = Get-TestHash $fixture.Settings
        $first = Invoke-Captured { Invoke-ClaudeSettingsStep -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups }
        $afterFirst = Read-ClaudeSettingsFile -Path $fixture.Settings
        $firstUnchanged = $first.Result[0].Status -eq 'unchanged' -and (Get-TestHash $fixture.Settings) -ceq $hash -and $null -eq $afterFirst.Object.enabledPlugins.PSObject.Properties['microsoft-docs@claude-plugins-official']
        $script:ListHandler = $allPluginsInstalled
        $second = Invoke-Captured { Invoke-ClaudeSettingsStep -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups }
        $afterSecond = Read-ClaudeSettingsFile -Path $fixture.Settings
        $firstUnchanged -and $second.Result[0].Status -eq 'merged' -and $afterSecond.Object.enabledPlugins.'microsoft-docs@claude-plugins-official' -eq $true -and $afterSecond.Object.theme -ceq 'light'
    }
    Test-Case 'PL03 無法讀取已安裝的外掛清單時，範本內的外掛全部略過並說明原因，不寫入 settings.json' {
        Reset-Stubs
        $script:ListHandler = { param($Arguments) throw 'plugin list failed' }
        $fixture = New-SettingsFixture
        Copy-Item -LiteralPath $settingsTemplatePath -Destination $fixture.Template -Force
        $captured = Invoke-Captured { Invoke-ClaudeSettingsStep -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups }
        $null -eq $captured.Error -and @($captured.Result[0].Skipped).Count -eq 3 -and @($captured.Warnings | Where-Object { $_.Contains('無法讀取已安裝的外掛清單') -and $_.Contains('plugin list failed') }).Count -eq 3 -and -not (Test-Path -LiteralPath $fixture.Settings)
    }
    Test-Case 'PL04 -WhatIf 預演不做外掛篩選，列出完整的將新增項目' {
        Reset-Stubs
        $fixture = New-SettingsFixture
        Copy-Item -LiteralPath $settingsTemplatePath -Destination $fixture.Template -Force
        $captured = Invoke-Captured { Invoke-ClaudeSettingsStep -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups -WhatIf }
        $null -eq $captured.Error -and $captured.Result[0].Status -eq 'whatif' -and @($captured.Result[0].Skipped).Count -eq 0 -and $captured.Warnings.Count -eq 0 -and -not (Test-Path -LiteralPath $fixture.Settings)
    }
    Test-Case 'PL05 Invoke-ClaudeSettingsApply -ExcludePluginId：排除項目不寫入；全部排除時不建立檔案；未列在範本的識別不影響' {
        $fixture = New-SettingsFixture
        Copy-Item -LiteralPath $settingsTemplatePath -Destination $fixture.Template -Force
        $partial = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups -ExcludePluginId @('microsoft-docs@claude-plugins-official', 'not-in-template@x')
        $written = (Read-ClaudeSettingsFile -Path $fixture.Settings).Object
        $other = New-SettingsFixture
        Copy-Item -LiteralPath $settingsTemplatePath -Destination $other.Template -Force
        $all = Invoke-ClaudeSettingsApply -SettingsPath $other.Settings -TemplatePath $other.Template -BackupRoot $other.Backups -ExcludePluginId @('ai-agents-hooks@ai-agents-local', 'line-status-board@ai-agents-local', 'microsoft-docs@claude-plugins-official')
        $partial.Status -eq 'created' -and @($partial.Skipped).Count -eq 1 -and @($written.enabledPlugins.PSObject.Properties).Count -eq 2 -and $all.Status -eq 'unchanged' -and @($all.Skipped).Count -eq 3 -and -not (Test-Path -LiteralPath $other.Settings)
    }

    # ---- 使用者在 settings.json 把官方外掛設為 false：Setup 不安裝、不啟用，只回報 ----
    Test-Case 'ST12 官方外掛步驟：settings.json 把外掛設為 false 時不呼叫 CLI（無 enable、無 install），輸出你已停用的說明，結果為 user-disabled；沒有 false 時照常啟用' {
        Reset-Stubs
        $script:ListHandler = {
            param($Arguments)
            if ($Arguments -contains 'marketplace') { , @([pscustomobject]@{ name = 'claude-plugins-official' }) }
            else { , @([pscustomobject]@{ id = 'microsoft-docs@claude-plugins-official'; enabled = $false }) }
        }
        $disabledPath = Join-Path (New-TestDirectory) 'settings.json'
        Write-TestFile $disabledPath '{"enabledPlugins":{"microsoft-docs@claude-plugins-official":false}}'
        $disabled = Invoke-Captured { Invoke-ClaudeOfficialPluginStep -SettingsTemplatePath $settingsTemplatePath -SettingsPath $disabledPath }
        $disabledCalls = $script:CliCalls.Count
        $enabledPath = Join-Path (New-TestDirectory) 'settings.json'
        Write-TestFile $enabledPath '{"theme":"x"}'
        $enabled = Invoke-Captured { Invoke-ClaudeOfficialPluginStep -SettingsTemplatePath $settingsTemplatePath -SettingsPath $enabledPath }
        $null -eq $disabled.Error -and $disabled.Result[0].Status -eq 'user-disabled' -and $disabledCalls -eq 0 -and (($disabled.Info -join "`n") -match '你已在 settings\.json') -and (($disabled.Info -join "`n") -notmatch '✅') -and
        $null -eq $enabled.Error -and $enabled.Result[0].Status -eq 'enabled' -and $script:CliCalls.Count -eq 1
    }
    Test-Case 'PL06 settings 步驟：被使用者設為 false 且未安裝的外掛不算安裝失敗：沒有略過警告，值保持 false，其餘項目照常新增' {
        Reset-Stubs
        $script:ListHandler = { param($Arguments) , @([pscustomobject]@{ id = 'ai-agents-hooks@ai-agents-local'; enabled = $true }, [pscustomobject]@{ id = 'line-status-board@ai-agents-local'; enabled = $true }) }
        $fixture = New-SettingsFixture -ExistingText '{"theme":"light","enabledPlugins":{"microsoft-docs@claude-plugins-official":false}}'
        Copy-Item -LiteralPath $settingsTemplatePath -Destination $fixture.Template -Force
        $captured = Invoke-Captured { Invoke-ClaudeSettingsStep -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups }
        $after = (Read-ClaudeSettingsFile -Path $fixture.Settings).Object
        $skippedWarnings = @($captured.Warnings | Where-Object { $_.Contains('microsoft-docs@claude-plugins-official') })
        $null -eq $captured.Error -and $captured.Result[0].Status -eq 'merged' -and $skippedWarnings.Count -eq 0 -and @($captured.Result[0].Skipped).Count -eq 0 -and
        $after.enabledPlugins.'microsoft-docs@claude-plugins-official' -eq $false -and $after.enabledPlugins.'ai-agents-hooks@ai-agents-local' -eq $true
    }
    Test-Case 'ST13 settings 步驟：讀取後原檔被改動（changed）與寫入目標無法確定（unresolved）都以警告回報原因，結果帶對應狀態' {
        Reset-Stubs
        $script:ListHandler = $allPluginsInstalled
        $changedFixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $unresolvedFixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $unresolvedHash = Get-TestHash $unresolvedFixture.Settings
        $originalSave = ${function:Save-ConfigFileBackup}
        function Save-ConfigFileBackup {
            param($Context, $BackupRoot, $RelativePath, $Bytes, $SourcePath, $Operation)
            $path = & $originalSave -Context $Context -BackupRoot $BackupRoot -RelativePath $RelativePath -Bytes $Bytes -SourcePath $SourcePath -Operation $Operation
            [IO.File]::AppendAllText($SourcePath, ' ', (New-Object System.Text.UTF8Encoding($false)))
            return $path
        }
        $changed = Invoke-Captured { Invoke-ClaudeSettingsStep -SettingsPath $changedFixture.Settings -TemplatePath $changedFixture.Template -BackupRoot $changedFixture.Backups }
        function Resolve-ConfigWriteTarget {
            param([string]$Path)
            return [pscustomobject]@{ Ok = $false; Path = $Path; InPlace = $false; Message = '連結指向不存在的目標' }
        }
        $unresolved = Invoke-Captured { Invoke-ClaudeSettingsStep -SettingsPath $unresolvedFixture.Settings -TemplatePath $unresolvedFixture.Template -BackupRoot $unresolvedFixture.Backups }
        $changed.Result[0].Status -eq 'changed' -and (($changed.Warnings -join "`n") -match '被其他程式改動') -and $unresolved.Result[0].Status -eq 'unresolved' -and (($unresolved.Warnings -join "`n") -match '連結指向不存在的目標') -and (Get-TestHash $unresolvedFixture.Settings) -ceq $unresolvedHash
    }

    # ---- 不支援 -DateKind 的 PowerShell（7.5 以前）不改寫既有的 settings.json ----
    # 以同名函式替身讓 Test-ClaudeUserConfigDateKindSupported 回傳 false，模擬 7.0 至 7.4。
    Test-Case 'DK01 不支援 -DateKind 時，改寫既有 settings.json 的步驟回報 refused 並說明需升級 PowerShell，檔案與備份目錄不變' {
        $fixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $hash = Get-TestHash $fixture.Settings
        function Test-ClaudeUserConfigDateKindSupported { return $false }
        $result = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        $result.Status -eq 'refused' -and $result.Message.Contains('7.5') -and $result.Message.Contains('winget upgrade Microsoft.PowerShell') -and (Get-TestHash $fixture.Settings) -ceq $hash -and -not (Test-Path -LiteralPath $fixture.Backups) -and
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $fixture.Settings) -Filter '*.tmp-*').Count -eq 0
    }
    Test-Case 'DK02 不支援 -DateKind 時，settings 步驟以警告輸出升級說明；沒有既有檔案時（不存在改寫風險）仍可建立' {
        Reset-Stubs
        $script:ListHandler = $allPluginsInstalled
        $existing = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $fresh = New-SettingsFixture
        function Test-ClaudeUserConfigDateKindSupported { return $false }
        $refused = Invoke-Captured { Invoke-ClaudeSettingsStep -SettingsPath $existing.Settings -TemplatePath $existing.Template -BackupRoot $existing.Backups }
        $created = Invoke-Captured { Invoke-ClaudeSettingsStep -SettingsPath $fresh.Settings -TemplatePath $fresh.Template -BackupRoot $fresh.Backups }
        $refused.Result[0].Status -eq 'refused' -and @($refused.Warnings | Where-Object { $_.Contains('PowerShell 7.5') }).Count -eq 1 -and $created.Result[0].Status -eq 'created'
    }
    Test-Case 'DK03 支援 -DateKind 的版本（目前執行的 pwsh）不受限：既有 settings.json 照常合併' {
        $supported = Test-ClaudeUserConfigDateKindSupported
        $fixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $result = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        ($supported -and $result.Status -eq 'merged') -or (-not $supported -and $result.Status -eq 'refused')
    }
    Test-Case 'DK04 不支援 -DateKind 時，settings.json 已含範本全部項目（不需改寫）回報 unchanged，沒有警告，檔案與備份目錄不變；需要新增項目時才 refused' {
        Reset-Stubs
        $script:ListHandler = $allPluginsInstalled
        $complete = New-SettingsFixture -ExistingText (New-SettingsTemplateText)
        $needsRewrite = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        $hash = Get-TestHash $complete.Settings
        function Test-ClaudeUserConfigDateKindSupported { return $false }
        $apply = Invoke-ClaudeSettingsApply -SettingsPath $complete.Settings -TemplatePath $complete.Template -BackupRoot $complete.Backups
        $step = Invoke-Captured { Invoke-ClaudeSettingsStep -SettingsPath $complete.Settings -TemplatePath $complete.Template -BackupRoot $complete.Backups }
        $refused = Invoke-ClaudeSettingsApply -SettingsPath $needsRewrite.Settings -TemplatePath $needsRewrite.Template -BackupRoot $needsRewrite.Backups
        $apply.Status -eq 'unchanged' -and $step.Result[0].Status -eq 'unchanged' -and $step.Warnings.Count -eq 0 -and (Get-TestHash $complete.Settings) -ceq $hash -and -not (Test-Path -LiteralPath $complete.Backups) -and $refused.Status -eq 'refused'
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
    Test-Case 'G04 寫入檔案的 API 只出現在 Invoke-ClaudeSettingsApply 與受保護寫入的兩個函式（Save-ConfigFileBackup、Write-ConfigFileGuarded）內；刪除只針對暫存檔' {
        $allowed = @('Invoke-ClaudeSettingsApply', 'Save-ConfigFileBackup', 'Write-ConfigFileGuarded') | ForEach-Object { Get-FunctionRange -Name $_ }
        $hits = @($tokens | Where-Object { $_.Text -match 'Set-Content|WriteAllText|WriteAllBytes|AppendAllText|Out-File|Add-Content|Move-Item|Remove-Item|Copy-Item|New-Item|\bMove\b' })
        $outside = @($hits | Where-Object { $hit = $_; @($allowed | Where-Object { $hit.Extent.StartOffset -ge $_.StartOffset -and $hit.Extent.EndOffset -le $_.EndOffset }).Count -eq 0 })
        Assert-True ($hits.Count -gt 0) '沒有找到任何寫入 API，檢查失效'
        Assert-True ($outside.Count -eq 0) ('允許的函式之外的寫入 API：' + (($outside | ForEach-Object { $_.Text + '@' + $_.Extent.StartLineNumber }) -join ','))
        $removeLines = @($libText -split "`r?`n" | Where-Object { $_ -match 'Remove-Item|\.Delete\(|\[IO\.File\]::Delete' })
        $removeLines.Count -eq 1 -and $removeLines[0].Contains('$temporaryPath')
    }
    Test-Case 'G05 .claude.json 字串只出現在 Get-ClaudeUserMcpServer 與檔頭註解' {
        $reader = Get-FunctionRange -Name 'Get-ClaudeUserMcpServer'
        $hits = @($tokens | Where-Object { $_.Kind -ne 'Comment' -and $_.Text -match '\.claude\.json' })
        $outside = @($hits | Where-Object { $_.Extent.StartOffset -lt $reader.StartOffset -or $_.Extent.EndOffset -gt $reader.EndOffset })
        Assert-True ($hits.Count -gt 0) '沒有找到 .claude.json 的引用，檢查失效'
        $outside.Count -eq 0
    }
    Test-Case 'G06 取代檔案使用建在實際目標旁的暫存檔與覆寫式 Move；settings.json 的寫入經過連結解析與取代前比對' {
        $guard = (Get-FunctionRange -Name 'Write-ConfigFileGuarded').Text
        $apply = (Get-FunctionRange -Name 'Invoke-ClaudeSettingsApply').Text
        $guard -match '\$Path \+ ''\.tmp-''' -and $guard -match '\[IO\.File\]::Move\(\$temporaryPath, \$Path, \$true\)' -and $apply -match 'Resolve-ConfigWriteTarget' -and $apply -match 'Write-ConfigFileGuarded' -and $apply -notmatch 'Copy-Item'
    }
    Test-Case 'G07 lib 沒有針對 permissions 或 skipDangerousModePermissionPrompt 的特殊處理（授權由使用者自行設定）' {
        $libText -cnotmatch 'permissions|skipDangerousModePermissionPrompt'
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

    # ---- settings 共用範本內容掃描 ----
    # 使用者決定：範本與 Setup 不寫入、不修改 permissions 與 skipDangerousModePermissionPrompt，偏好類的鍵（model、effortLevel、modelSettings、advisorModel）不進範本。
    $settingsTemplateText = [IO.File]::ReadAllText($settingsTemplatePath)
    $settingsTemplateRead = Read-ClaudeSettingsFile -Path $settingsTemplatePath
    function Get-AllPropertyName {
        param($Node)
        if (Test-ClaudeUserConfigJsonObject $Node) {
            foreach ($property in $Node.PSObject.Properties) { $property.Name; Get-AllPropertyName $property.Value }
        }
        elseif ($Node -is [array]) { foreach ($item in $Node) { Get-AllPropertyName $item } }
    }
    Test-Case 'T03 settings 範本可剖析、無 BOM，頂層只有 enabledPlugins，內容為三個外掛且皆為 true' {
        $bytes = [IO.File]::ReadAllBytes($settingsTemplatePath)
        $plugins = $settingsTemplateRead.Object.enabledPlugins
        $names = @($plugins.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
        $null -eq $settingsTemplateRead.Error -and -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) -and ((@($settingsTemplateRead.Object.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') -ceq 'enabledPlugins') -and
        ($names -join ',') -ceq 'ai-agents-hooks@ai-agents-local,line-status-board@ai-agents-local,microsoft-docs@claude-plugins-official' -and @($plugins.PSObject.Properties | Where-Object { $_.Value -ne $true }).Count -eq 0
    }
    Test-Case 'T04 settings 範本不含授權、偏好與機器專屬的鍵，也不含磁碟機路徑、使用者目錄或權杖樣式' {
        $forbidden = @('permissions', 'allow', 'ask', 'deny', 'skipDangerousModePermissionPrompt', 'model', 'effortLevel', 'modelSettings', 'advisorModel', 'extraKnownMarketplaces', 'pluginConfigs', 'additionalDirectories', 'hooks', 'env', 'apiKeyHelper')
        $present = @(Get-AllPropertyName $settingsTemplateRead.Object | Where-Object { $forbidden -ccontains $_ })
        Assert-True ($present.Count -eq 0) ('範本含不允許的鍵：' + ($present -join ','))
        $settingsTemplateText -cnotmatch '[A-Za-z]:[\\/]|%USERPROFILE%|/home/|Bearer|[Tt]oken|ghp_|sk-'
    }
    Test-Case 'T05 必裝官方外掛只有 microsoft-docs，github 與 context7 不在範本內' {
        $required = @(Get-ClaudeRequiredOfficialPlugin -TemplatePath $settingsTemplatePath)
        $required.Count -eq 1 -and $required[0] -ceq 'microsoft-docs@claude-plugins-official' -and $settingsTemplateText -notmatch 'github|context7'
    }
    Test-Case 'T06 以真實範本合併：既有的 permissions、skipDangerousModePermissionPrompt、model 與機器專屬鍵原樣不變，Changes 只涉及 enabledPlugins' {
        $fixture = New-SettingsFixture -ExistingText (New-ExistingSettingsText)
        Copy-Item -LiteralPath $settingsTemplatePath -Destination $fixture.Template -Force
        $before = (Read-ClaudeSettingsFile -Path $fixture.Settings).Object
        $result = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        $after = (Read-ClaudeSettingsFile -Path $fixture.Settings).Object
        $paths = @($result.Changes | ForEach-Object { $_.Path })
        $result.Status -eq 'merged' -and (Test-ClaudeSettingsPreserved -Before $before -After $after) -and (Test-ClaudeUserConfigJsonEqual $before.permissions $after.permissions) -and
        $after.model -ceq 'user-model' -and $after.skipDangerousModePermissionPrompt -eq $true -and $after.enabledPlugins.'microsoft-docs@claude-plugins-official' -eq $false -and
        @($paths | Where-Object { $_ -notmatch '^enabledPlugins' }).Count -eq 0 -and $paths -contains 'enabledPlugins.ai-agents-hooks@ai-agents-local'
    }
    Test-Case 'T07 以真實範本在沒有 settings.json 的環境套用：建立的內容與範本一致，且不含 permissions' {
        $fixture = New-SettingsFixture
        Copy-Item -LiteralPath $settingsTemplatePath -Destination $fixture.Template -Force
        $result = Invoke-ClaudeSettingsApply -SettingsPath $fixture.Settings -TemplatePath $fixture.Template -BackupRoot $fixture.Backups
        $written = Read-ClaudeSettingsFile -Path $fixture.Settings
        $result.Status -eq 'created' -and (Test-ClaudeUserConfigJsonEqual $written.Object $settingsTemplateRead.Object) -and $null -eq $written.Object.PSObject.Properties['permissions']
    }
}
finally {
    $env:PATH = $originalPath
    if (Test-Path -LiteralPath $tempBase) { Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output "PASSED: $passed"
Write-Output "FAILED: $failed"
Write-Output "SKIPPED: $skipped"
if ($failed -gt 0) { exit 1 }
exit 0
