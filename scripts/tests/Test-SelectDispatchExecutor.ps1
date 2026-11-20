#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\Select-DispatchExecutor.ps1')).Path
$registryPath = (Resolve-Path (Join-Path $PSScriptRoot '..\dispatch\executor-registry.json')).Path
$libraryPath = (Resolve-Path (Join-Path $PSScriptRoot '..\lib\executor-registry.ps1')).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('select-executor-' + [guid]::NewGuid().ToString('N'))
$hostPath = (Get-Process -Id $PID).Path
$failed = 0
$passed = 0

function Test-Case {
    param([string]$Id, [scriptblock]$Check)
    try {
        if (-not (& $Check)) { throw '條件不成立' }
        $script:passed++
        Write-Output "PASS $Id"
    }
    catch {
        $script:failed++
        Write-Output "FAIL $Id $($_.Exception.Message)"
    }
}

function ConvertTo-QuotedArgument {
    param([AllowEmptyString()][string]$Value)

    if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-Selector {
    param([string[]]$Arguments = @(), [string]$Registry, [string]$WorkingDirectory)

    $all = @('-NoProfile', '-NonInteractive', '-File', $scriptPath) + $Arguments
    if (-not [string]::IsNullOrWhiteSpace($Registry)) { $all += @('-RegistryPath', $Registry) }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $hostPath
    $startInfo.Arguments = ($all | ForEach-Object { ConvertTo-QuotedArgument -Value $_ }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $startInfo.WorkingDirectory = $WorkingDirectory }
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill(); throw '選派入口逾時' }
        $process.WaitForExit()
        $json = $null
        $out = $stdoutTask.Result
        if (-not [string]::IsNullOrWhiteSpace($out)) { $json = $out | ConvertFrom-Json }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $out; StdErr = $stderrTask.Result; Json = $json }
    }
    finally {
        $process.Dispose()
    }
}

function Split-Args {
    param([string]$Text)

    return @($Text -split '\s+' | Where-Object { $_ -ne '' })
}

function New-RegistryCopy {
    param([string]$Name, [scriptblock]$Mutate)

    $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    & $Mutate $registry
    $path = Join-Path $tempRoot ($Name + '.json')
    [IO.File]::WriteAllText($path, ($registry | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    return $path
}

function Save-GitBlob {
    # 以位元組原樣取出 git 物件（經 PowerShell 管線會依主控台編碼轉碼而毀損 UTF-8）。
    param([string]$Repository, [string]$Spec, [string]$Destination)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'git'
    foreach ($item in @('-C', $Repository, 'show', $Spec)) { [void]$startInfo.ArgumentList.Add($item) }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $file = [IO.File]::Create($Destination)
        try { $process.StandardOutput.BaseStream.CopyTo($file) } finally { $file.Dispose() }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw ('git show ' + $Spec + ' 失敗') }
    }
    finally { $process.Dispose() }
}

function New-FixtureRegistry {
    # 自建的假登錄表，執行者與類型名稱都與出貨登錄表無關。選派規則的案例一律用它，出貨登錄表增減執行者不影響這些案例。
    # 候選排序的設計：probe 類型的優先條件為 net、gui，五位候選的排序值與優先條件滿足情形刻意相反，
    # 只依排序值會得到 charlie、delta、golf、echo，依規則應為 echo、delta、golf、charlie。
    param([string]$Name, [scriptblock]$Mutate)

    $registry = [pscustomobject]@{
        schema          = 'ai-agents.executor-registry.v1'
        tags            = [pscustomobject]@{ hard = @('write', 'run', 'net', 'gui'); constraint = @('family', 'gated') }
        flags           = @('E', 'T')
        codexEfforts    = @('low', 'medium', 'high')
        retiredProfiles = @('old')
        maxIncomplete   = 3
        types           = [pscustomobject]@{
            edit  = [pscustomobject]@{ requiredFlags = @('E', 'T'); impliedTags = @('write'); forbiddenTags = @() }
            look  = [pscustomobject]@{ requiredFlags = @(); impliedTags = @(); forbiddenTags = @('write') }
            check = [pscustomobject]@{ requiredFlags = @(); impliedTags = @(); forbiddenTags = @('write'); preferred = @('family') }
            probe = [pscustomobject]@{ requiredFlags = @(); impliedTags = @(); forbiddenTags = @('write'); preferred = @('net', 'gui') }
            ask   = [pscustomobject]@{ requiredFlags = @(); impliedTags = @(); forbiddenTags = @('write'); preferred = @('family') }
        }
        executors       = @(
            [pscustomobject]@{ id = 'alpha'; display = 'Alpha'; platform = 'claude'; model = 'm-alpha'; selfRepair = $false; family = 'claude'; accepts = @('edit'); tags = @('write', 'run'); when = [pscustomobject]@{ E = $true; T = $false }; order = 10; gated = $false }
            [pscustomobject]@{ id = 'bravo'; display = 'Bravo'; platform = 'codex'; profile = 'pb'; family = 'codex'; entry = 'scripts/Invoke-CodexRun.ps1'; profileSettings = [pscustomobject]@{ model = 'big'; effort = 'low'; subagentModel = 'tiny'; subagentEffort = 'low'; fallbackModels = @('mid', 'small') }; accepts = @('check'); tags = @(); when = [pscustomobject]@{}; order = 20; gated = $false }
            [pscustomobject]@{ id = 'foxtrot'; display = 'Foxtrot'; platform = 'codex'; profile = 'pf'; family = 'codex'; entry = 'scripts/Invoke-Other.ps1'; profileSettings = [pscustomobject]@{ model = 'big'; effort = 'high'; subagentModel = 'tiny'; subagentEffort = 'low' }; accepts = @('ask'); tags = @(); when = [pscustomobject]@{}; order = 25; gated = $true }
            [pscustomobject]@{ id = 'charlie'; display = 'Charlie'; platform = 'claude'; model = 'm-charlie'; selfRepair = $true; family = 'claude'; accepts = @('edit', 'look', 'check', 'probe', 'ask'); tags = @('write', 'run', 'gui'); when = [pscustomobject]@{}; order = 30; gated = $false }
            [pscustomobject]@{ id = 'delta'; display = 'Delta'; platform = 'claude'; model = 'm-delta'; selfRepair = $true; family = 'claude'; accepts = @('edit', 'look', 'check', 'probe'); tags = @('write', 'run', 'net'); when = [pscustomobject]@{}; order = 40; gated = $false }
            [pscustomobject]@{ id = 'golf'; display = 'Golf'; platform = 'claude'; model = 'm-golf'; selfRepair = $true; family = 'claude'; accepts = @('probe'); tags = @('net'); when = [pscustomobject]@{}; order = 45; gated = $false }
            [pscustomobject]@{ id = 'echo'; display = 'Echo'; platform = 'claude'; model = 'm-echo'; selfRepair = $true; family = 'claude'; accepts = @('probe'); tags = @('net', 'gui'); when = [pscustomobject]@{}; order = 50; gated = $false }
        )
    }
    if ($null -ne $Mutate) { & $Mutate $registry }
    $path = Join-Path $tempRoot ('fixture-' + $Name + '.json')
    [IO.File]::WriteAllText($path, ($registry | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    return $path
}

function Invoke-Fixture {
    param([string]$ArgumentText, [string]$Registry)

    return (Invoke-Selector -Arguments (Split-Args $ArgumentText) -Registry $Registry)
}

function Get-ExecutorNode {
    param($Registry, [string]$Id)

    return @($Registry.executors | Where-Object { $_.id -eq $Id })[0]
}

function Assert-Selected {
    param([string]$ArgumentText, [string]$ExpectedId, [string]$ExpectedStatus = 'selected', [int]$ExpectedExit = 0)

    $r = Invoke-Selector -Arguments (Split-Args $ArgumentText)
    return ($r.ExitCode -eq $ExpectedExit -and $r.Json.status -eq $ExpectedStatus -and $r.Json.executor.id -eq $ExpectedId)
}

function Assert-Rejected {
    param([string]$ArgumentText, [string]$Code, [int]$ExpectedExit = 2, [string]$Registry)

    $r = Invoke-Selector -Arguments (Split-Args $ArgumentText) -Registry $Registry
    return ($r.ExitCode -eq $ExpectedExit -and $r.StdErr.StartsWith($Code) -and [string]::IsNullOrWhiteSpace($r.StdOut))
}

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    # 檔案編碼與靜態性質
    $text = [IO.File]::ReadAllText($scriptPath)
    $libraryText = [IO.File]::ReadAllText($libraryPath)
    Test-Case S01 {
        $bytes = [IO.File]::ReadAllBytes($scriptPath)
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191 -and $errors.Count -eq 0
    }
    Test-Case S02 { $text -match '(?m)^#Requires -Version 7\.0' -and $text -match '(?m)^Set-StrictMode -Version Latest' }
    Test-Case S03 {
        # 選派入口與其唯一載入的共用函式檔都不寫檔、不呼叫網路、不讀取環境變數。
        $forbidden = 'Set-Content|Add-Content|Out-File|New-Item|Remove-Item|Copy-Item|Move-Item|Rename-Item|Tee-Object|Export-|Invoke-WebRequest|Invoke-RestMethod|\$env:|GetEnvironmentVariable|WriteAllText|>>'
        $text -notmatch $forbidden -and $libraryText -notmatch $forbidden
    }
    Test-Case S06 {
        # 選派入口只 dot-source 一個檔：以 $PSScriptRoot 為基準的 lib\executor-registry.ps1；共用函式檔本身不 dot-source 任何檔，也不含頂層陳述（只定義函式）。
        $selectorAst = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $dotSources = @($selectorAst.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot }, $true))
        $libraryAst = [Management.Automation.Language.Parser]::ParseFile($libraryPath, [ref]$null, [ref]$null)
        $libraryDotSources = @($libraryAst.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot }, $true))
        $libraryTopLevel = @($libraryAst.EndBlock.Statements | Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] })
        $dotSources.Count -eq 1 -and $dotSources[0].Extent.Text -ceq '. $script:RegistryLibraryPath' -and
        $text -match [regex]::Escape("`$script:RegistryLibraryPath = Join-Path -Path `$PSScriptRoot -ChildPath 'lib\executor-registry.ps1'") -and
        $text -notmatch '(?im)^\s*(Import-Module|using\s+module)' -and $libraryDotSources.Count -eq 0 -and $libraryTopLevel.Count -eq 0 -and
        $text -notmatch 'function (Read-ExecutorRegistry|ConvertTo-ExecutorRegistry|ConvertTo-ValidatedRegistry)\b'
    }
    Test-Case S07 {
        # 共用函式檔不存在或有語法錯誤時，選派入口以 SelectorRegistryLibraryUnavailable 結束碼 1 明確失敗，stdout 為空。
        # 共用函式檔與選派入口同在一處時，以絕對路徑從其他工作目錄執行可正常載入（載入以選派入口所在位置為基準）。
        $isolated = Join-Path $tempRoot 'isolated'
        $null = New-Item -ItemType Directory -Path (Join-Path $isolated 'lib') -Force
        $isolatedScript = Join-Path $isolated 'Select-DispatchExecutor.ps1'
        Copy-Item -LiteralPath $scriptPath -Destination $isolatedScript
        $saved = $script:scriptPath
        try {
            $script:scriptPath = $isolatedScript
            $missing = Invoke-Selector -Arguments (Split-Args '-Type survey') -Registry $registryPath
            Set-Content -LiteralPath (Join-Path $isolated 'lib\executor-registry.ps1') -Value 'function Read-ExecutorRegistry { ' -Encoding utf8
            $broken = Invoke-Selector -Arguments (Split-Args '-Type survey') -Registry $registryPath
            Copy-Item -LiteralPath $libraryPath -Destination (Join-Path $isolated 'lib\executor-registry.ps1') -Force
            $otherDirectory = Join-Path $tempRoot 'other-cwd'
            $null = New-Item -ItemType Directory -Path $otherDirectory -Force
            $loaded = Invoke-Selector -Arguments (Split-Args '-Type survey') -Registry $registryPath -WorkingDirectory $otherDirectory
        }
        finally { $script:scriptPath = $saved }
        $missing.ExitCode -eq 1 -and $missing.StdErr.StartsWith('SelectorRegistryLibraryUnavailable') -and [string]::IsNullOrWhiteSpace($missing.StdOut) -and
        $broken.ExitCode -eq 1 -and $broken.StdErr.StartsWith('SelectorRegistryLibraryUnavailable') -and [string]::IsNullOrWhiteSpace($broken.StdOut) -and
        $loaded.ExitCode -eq 0 -and $loaded.Json.executor.id -ceq 'sonnet'
    }
    Test-Case S04 {
        $bytes = [IO.File]::ReadAllBytes($registryPath)
        $registryJson = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
        -not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) -and $registryJson.schema -eq 'ai-agents.executor-registry.v1'
    }
    Test-Case S05 {
        # 檔位名稱不再於腳本內寫死白名單，只由登錄表決定。
        $text -notmatch 'CodexProfileNames' -and $text -notmatch "'review', 'test', 'factcheck', 'advisor'"
    }

    # 出貨登錄表：詞彙與 -Describe
    $describe = Invoke-Selector -Arguments @('-Describe')
    $registryRaw = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Case D01 {
        $d = $describe.Json
        $describe.ExitCode -eq 0 -and @($d.tags.hard).Count -eq 6 -and @($d.tags.constraint).Count -eq 2 -and (@($d.tags.hard).Count + @($d.tags.constraint).Count) -le 8 -and
        @($d.executors).Count -eq @($registryRaw.executors).Count -and @($d.types).Count -eq @($registryRaw.types.PSObject.Properties).Count -and (@($d.flags) -join ',') -eq 'E,T'
    }
    Test-Case D02 {
        $edit = @($describe.Json.types | Where-Object { $_.name -eq 'edit' })[0]
        $review = @($describe.Json.types | Where-Object { $_.name -eq 'review' })[0]
        (@($edit.requiredFlags) -join ',') -eq 'E,T' -and (@($review.requiredFlags) -join ',') -eq '' -and (@($review.preferred) -join ',') -eq 'family' -and @($edit.preferred).Count -eq 0 -and
        $null -eq $review.PSObject.Properties['crossFamily'] -and $null -eq $review.PSObject.Properties['degradable']
    }
    Test-Case D04 {
        $advise = @($describe.Json.types | Where-Object { $_.name -eq 'advise' })[0]
        @($advise.preferred).Count -eq 0 -and $advise.skippable -eq $true -and $describe.Json.maxIncomplete -eq $registryRaw.maxIncomplete
    }
    Test-Case D05 {
        $factcheckNode = @($describe.Json.executors | Where-Object { $_.id -eq 'codex-factcheck' })[0]
        $testNode = @($describe.Json.executors | Where-Object { $_.id -eq 'codex-test' })[0]
        $deep = @($describe.Json.executors | Where-Object { $_.id -eq 'codex-deep-review' })
        $null -ne $factcheckNode -and (@($factcheckNode.accepts) -join ',') -eq 'generate,factcheck' -and (@($factcheckNode.tags) -join ',') -eq 'web,image-gen' -and $deep.Count -eq 0 -and (@($testNode.accepts) -join ',') -eq 'test'
    }
    Test-Case D06 {
        # -Describe 輸出每個 Codex 執行者的檔位設定（逐欄等於登錄表），Claude 執行者沒有。
        $codex = @($describe.Json.executors | Where-Object { $_.platform -eq 'codex' })
        $claude = @($describe.Json.executors | Where-Object { $_.platform -eq 'claude' })
        $rawCodex = @($registryRaw.executors | Where-Object { $_.platform -ceq 'codex' })
        $same = $codex.Count -eq $rawCodex.Count
        foreach ($row in $codex) {
            $node = @($rawCodex | Where-Object { $_.id -ceq $row.id })[0]
            if ($null -eq $node -or $null -eq $row.profileSettings) { $same = $false; continue }
            foreach ($key in @('model', 'effort', 'subagentModel', 'subagentEffort')) { if ($row.profileSettings.$key -cne $node.profileSettings.$key) { $same = $false } }
        }
        $same -and (@($claude | Where-Object { $null -ne $_.PSObject.Properties['profileSettings'] }).Count -eq 0)
    }
    Test-Case D03 {
        $profiles = @($describe.Json.executors | Where-Object { $_.platform -eq 'codex' } | ForEach-Object { $_.profile })
        $expected = @($registryRaw.executors | Where-Object { $_.platform -ceq 'codex' } | ForEach-Object { $_.profile })
        $expected.Count -gt 0 -and ($profiles -join ',') -ceq ($expected -join ',')
    }
    Test-Case D07 {
        # design 類型：不要求旗標、禁用 write、沒有優先條件、不可略過；受理者依排序為 sonnet、opus。
        $design = @($describe.Json.types | Where-Object { $_.name -eq 'design' })[0]
        $acceptors = @($describe.Json.executors | Where-Object { @($_.accepts) -contains 'design' } | ForEach-Object { $_.id })
        $null -ne $design -and @($design.requiredFlags).Count -eq 0 -and (@($design.forbiddenTags) -join ',') -eq 'write' -and @($design.preferred).Count -eq 0 -and $design.skippable -eq $false -and
        ($acceptors -join ',') -ceq 'sonnet,opus'
    }
    Test-Case D08 {
        # -Describe 的 Claude 執行者含 selfRepair（haiku 為否，sonnet、opus 為是），Codex 執行者沒有。
        $byId = @{}
        foreach ($row in $describe.Json.executors) { $byId[$row.id] = $row }
        $codexRows = @($describe.Json.executors | Where-Object { $_.platform -eq 'codex' })
        $byId['haiku'].selfRepair -eq $false -and $byId['sonnet'].selfRepair -eq $true -and $byId['opus'].selfRepair -eq $true -and
        $codexRows.Count -gt 0 -and @($codexRows | Where-Object { $null -ne $_.PSObject.Properties['selfRepair'] }).Count -eq 0
    }

    # 每類任務的選派
    Test-Case P01 { Assert-Selected '-Type edit -E true -T false' 'haiku' }
    Test-Case P02 { Assert-Selected '-Type edit -E true -T true' 'sonnet' }
    Test-Case P03 { Assert-Selected '-Type edit -E false -T false' 'sonnet' }
    Test-Case P04 { Assert-Selected '-Type edit -E false -T true' 'sonnet' }
    Test-Case P05 { Assert-Selected '-Type edit -E true -T false -Tags build-test' 'haiku' }
    Test-Case P06 { Assert-Selected '-Type survey' 'sonnet' }
    Test-Case P07 { Assert-Selected '-Type test' 'codex-test' }
    Test-Case P08 { Assert-Selected '-Type test -Tags browse' 'codex-test' }
    Test-Case P09 { Assert-Selected '-Type test -Tags desktop-control' 'codex-test' }
    Test-Case P10 { Assert-Selected '-Type generate' 'codex-factcheck' }
    Test-Case P11 { Assert-Selected '-Type factcheck' 'codex-factcheck' }
    Test-Case P12 { Assert-Selected '-Type review -ImplementerFamily claude' 'codex-review' }
    Test-Case P14 { Assert-Selected '-Type advise -ImplementerFamily claude' 'codex-advisor' 'needs-authorization' 20 }
    Test-Case P15 { Assert-Selected '-Type advise -Authorized -ImplementerFamily claude' 'codex-advisor' }
    Test-Case P16 { Assert-Selected '-Type review -ImplementerFamily codex' 'sonnet' }
    Test-Case P17 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type generate')
        (@($r.Json.labels.tags) -join ',') -eq 'image-gen' -and $r.Json.executor.profile -eq 'factcheck' -and $r.Json.executor.platform -eq 'codex' -and $null -eq $r.Json.executor.PSObject.Properties['model']
    }
    Test-Case P18 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type edit -E true -T false')
        $r.Json.executor.model -eq 'haiku' -and $r.Json.executor.platform -eq 'claude' -and $null -eq $r.Json.executor.PSObject.Properties['profile'] -and $r.Json.requiresUserDecision -eq $false
    }
    Test-Case P19 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type test -Tags browse,desktop-control')
        $r.ExitCode -eq 0 -and $r.Json.executor.id -eq 'codex-test' -and (@($r.Json.labels.tags) -join ',') -eq 'browse,desktop-control'
    }
    Test-Case P20 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type test -Tags web')
        $r.ExitCode -eq 0 -and $r.Json.executor.id -eq 'codex-test' -and @($r.Json.considered | Where-Object { $_.id -eq 'sonnet' })[0].reason -eq 'eligible-lower-priority'
    }

    Test-Case P21 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type advise -ImplementerFamily claude -Offline codex-advisor')
        $r.ExitCode -eq 21 -and $r.Json.status -eq 'omitted' -and $r.Json.reason -eq 'offline' -and $null -eq $r.Json.executor -and -not $r.Json.requiresUserDecision
    }

    Test-Case P21C {
        # 類型特徵 skippable：只有登錄表宣告的類型得到 omitted，其他類型離線仍是 stopped
        $advise = @($registryRaw.types.PSObject.Properties | Where-Object { $null -ne $_.Value.PSObject.Properties['skippable'] -and $_.Value.skippable -eq $true } | ForEach-Object { $_.Name })
        $generate = Invoke-Selector -Arguments (Split-Args '-Type generate -Offline codex-factcheck')
        $browse = Invoke-Selector -Arguments (Split-Args '-Type test -Tags browse -Offline codex-test')
        ($advise -join ',') -eq 'advise' -and $generate.ExitCode -eq 22 -and $generate.Json.status -eq 'stopped' -and $browse.ExitCode -eq 22 -and $browse.Json.status -eq 'stopped'
    }

    Test-Case P21D {
        # 行為來自特徵而不是類型名稱：把 skippable 設到 generate，generate 離線得到 omitted；把 advise 的特徵拿掉，顧問離線回到 stopped
        $path = New-RegistryCopy 'skippable-moved' { param($r) $r.types.generate | Add-Member -NotePropertyName skippable -NotePropertyValue $true; $r.types.advise.PSObject.Properties.Remove('skippable') }
        $generate = Invoke-Selector -Arguments (Split-Args '-Type generate -Offline codex-factcheck') -Registry $path
        $advise = Invoke-Selector -Arguments (Split-Args '-Type advise -Offline codex-advisor') -Registry $path
        $generate.ExitCode -eq 21 -and $generate.Json.status -eq 'omitted' -and $advise.ExitCode -eq 22 -and $advise.Json.status -eq 'stopped'
    }

    Test-Case P21E {
        # 判定順序：skippable 類型在線時仍先回 needs-authorization 與 selected；候選因未完成次數達上限而用盡時也是 omitted。
        # 非 skippable 類型（review）同樣情況維持 needs-user-decision。
        $unauthorized = Invoke-Selector -Arguments (Split-Args '-Type advise')
        $authorized = Invoke-Selector -Arguments (Split-Args '-Type advise -Authorized')
        $exhausted = Invoke-Selector -Arguments ((Split-Args '-Type advise -Authorized') + @('-Incomplete', ('codex-advisor:' + $registryRaw.maxIncomplete)))
        $reviewLimit = ('codex-review:{0},sonnet:{0},opus:{0}' -f $registryRaw.maxIncomplete)
        $reviewExhausted = Invoke-Selector -Arguments ((Split-Args '-Type review -ImplementerFamily claude') + @('-Incomplete', $reviewLimit))
        $unauthorized.ExitCode -eq 20 -and $authorized.ExitCode -eq 0 -and $exhausted.ExitCode -eq 21 -and $exhausted.Json.status -eq 'omitted' -and $exhausted.Json.reason -eq 'all-candidates-exhausted' -and
        $reviewExhausted.ExitCode -eq 10 -and $reviewExhausted.Json.status -eq 'needs-user-decision'
    }

    Test-Case P21F {
        # skippable 為選填布林，未設定時為否；非布林值使登錄表無效
        $absent = New-RegistryCopy 'skippable-absent' { param($r) $r.types.advise.PSObject.Properties.Remove('skippable') }
        $falseValue = New-RegistryCopy 'skippable-false' { param($r) $r.types.advise.skippable = $false }
        $badText = New-RegistryCopy 'skippable-text' { param($r) $r.types.advise.skippable = 'true' }
        $badNumber = New-RegistryCopy 'skippable-number' { param($r) $r.types.advise.skippable = 1 }
        $a = Invoke-Selector -Arguments (Split-Args '-Type advise -Offline codex-advisor') -Registry $absent
        $b = Invoke-Selector -Arguments (Split-Args '-Type advise -Offline codex-advisor') -Registry $falseValue
        $a.Json.status -eq 'stopped' -and $b.Json.status -eq 'stopped' -and
        (Assert-Rejected '-Type advise' 'SelectorRegistryInvalid' 3 $badText) -and (Assert-Rejected '-Type advise' 'SelectorRegistryInvalid' 3 $badNumber)
    }

    Test-Case P21B {
        # advise 只有 Codex advisor 受理：所有 Claude 執行者都以 type-not-accepted 排除，離線時不選出任何執行者
        $r = Invoke-Selector -Arguments (Split-Args '-Type advise -ImplementerFamily claude -Offline codex-advisor')
        $claude = @($r.Json.considered | Where-Object { @('haiku', 'sonnet', 'opus') -contains $_.id })
        $claude.Count -eq 3 -and @($claude | Where-Object { $_.reason -ne 'type-not-accepted' }).Count -eq 0 -and (@($r.Json.candidates) -join ',') -eq 'codex-advisor'
    }
    Test-Case P22 {
        $r = Invoke-Selector -Arguments ((Split-Args '-Type test') + @('-Offline', 'codex-test,codex-factcheck,codex-review,codex-advisor'))
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -eq 'sonnet'
    }
    Test-Case P23 {
        $r = Invoke-Selector -Arguments ((Split-Args '-Type test -Tags build-test') + @('-Offline', 'codex-test,codex-factcheck,codex-review,codex-advisor'))
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -eq 'sonnet'
    }

    Test-Case P24 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type generate')
        $r.ExitCode -eq 0 -and $r.Json.executor.id -eq 'codex-factcheck' -and $r.Json.executor.profile -eq 'factcheck'
    }
    Test-Case P25 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type factcheck')
        $r.ExitCode -eq 0 -and $r.Json.executor.id -eq 'codex-factcheck' -and $r.Json.executor.profile -eq 'factcheck'
    }
    Test-Case P26 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type test')
        $r.ExitCode -eq 0 -and $r.Json.executor.id -eq 'codex-test' -and @($r.Json.considered | Where-Object { $_.id -eq 'codex-factcheck' })[0].reason -eq 'type-not-accepted'
    }
    Test-Case P27 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type test -Tags image-gen')
        $r.ExitCode -eq 22 -and $r.Json.reason -eq 'no-eligible-executor'
    }
    Test-Case P28 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude')
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -eq 'codex-review' -and @($r.Json.considered).Count -eq @($registryRaw.executors).Count -and @($r.Json.considered | Where-Object { $_.id -eq 'codex-deep-review' }).Count -eq 0
    }
    Test-Case P29 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type design')
        $reasons = @{}
        foreach ($row in $r.Json.considered) { $reasons[$row.id] = $row.reason }
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -ceq 'sonnet' -and -not [string]::IsNullOrWhiteSpace($r.Json.executor.model) -and
        (@($r.Json.candidates) -join ',') -ceq 'sonnet,opus' -and $reasons['haiku'] -ceq 'type-not-accepted' -and $reasons['codex-review'] -ceq 'type-not-accepted'
    }
    Test-Case P30 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type design -Offline sonnet')
        $r.ExitCode -eq 0 -and $r.Json.executor.id -ceq 'opus' -and (@($r.Json.skipped | ForEach-Object { $_.id + ':' + $_.reason }) -join ',') -ceq 'sonnet:offline'
    }
    Test-Case P31 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type design -Offline sonnet,opus')
        $r.ExitCode -eq 22 -and $r.Json.status -eq 'stopped' -and $r.Json.reason -eq 'offline' -and $null -eq $r.Json.executor
    }
    Test-Case P32 {
        # selfRepair 只出現在 Claude 執行者的 executor 節點，值取自登錄表。
        $haiku = Invoke-Selector -Arguments (Split-Args '-Type edit -E true -T false')
        $sonnetEdit = Invoke-Selector -Arguments (Split-Args '-Type edit -E true -T true')
        $survey = Invoke-Selector -Arguments (Split-Args '-Type survey')
        $codex = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude')
        $haiku.Json.executor.selfRepair -eq $false -and $sonnetEdit.Json.executor.selfRepair -eq $true -and $survey.Json.executor.selfRepair -eq $true -and
        $codex.Json.executor.id -ceq 'codex-review' -and $null -eq $codex.Json.executor.PSObject.Properties['selfRepair']
    }

    # 出貨登錄表的一般性質（不寫死執行者 id）：沒有離線與未完成時選中候選清單第一位；候選全部離線時停止。
    $generalCases = @(
        '-Type edit -E true -T false', '-Type edit -E true -T true', '-Type edit -E false -T false', '-Type edit -E false -T true',
        '-Type survey', '-Type design', '-Type test', '-Type generate', '-Type factcheck',
        '-Type review -ImplementerFamily claude', '-Type review -ImplementerFamily codex', '-Type advise -Authorized -ImplementerFamily claude'
    )
    Test-Case O01 {
        foreach ($case in $generalCases) {
            $r = Invoke-Selector -Arguments (Split-Args $case)
            if ($r.ExitCode -ne 0 -or $r.Json.executor.id -ne @($r.Json.candidates)[0]) { throw "未選中候選清單第一位：$case" }
            if (@($r.Json.skipped).Count -ne 0 -or @($r.Json.unmetPreferences).Count -ne 0) { throw "一般選派不應有略過或未滿足的優先條件：$case" }
        }
        $true
    }
    Test-Case O02 {
        foreach ($case in $generalCases) {
            $first = Invoke-Selector -Arguments (Split-Args $case)
            $r = Invoke-Selector -Arguments ((Split-Args $case) + @('-Offline', (@($first.Json.candidates) -join ',')))
            # 類型宣告 skippable 者回報 omitted（結束碼 21），其餘回報 stopped（結束碼 22）
            $typeName = ([regex]::Match($case, '-Type (\S+)')).Groups[1].Value
            $skippable = $null -ne $registryRaw.types.$typeName.PSObject.Properties['skippable'] -and $registryRaw.types.$typeName.skippable -eq $true
            $expectedStatus = if ($skippable) { 'omitted' } else { 'stopped' }
            $expectedExit = if ($skippable) { 21 } else { 22 }
            if ($r.ExitCode -ne $expectedExit -or $r.Json.status -ne $expectedStatus -or $r.Json.reason -ne 'offline' -or $null -ne $r.Json.executor) { throw "候選全部離線後仍有執行者：$case" }
        }
        $true
    }

    # 標註驗證失敗
    Test-Case V01 { Assert-Rejected '-Type bogus' 'SelectorTypeInvalid' }
    Test-Case V02 { Assert-Rejected '-E true' 'SelectorTypeInvalid' }
    Test-Case V03 { Assert-Rejected '-Type edit -T false' 'SelectorFlagMissing' }
    Test-Case V04 { Assert-Rejected '-Type edit -E true' 'SelectorFlagMissing' }
    Test-Case V05 { Assert-Rejected '-Type survey -E true' 'SelectorFlagNotAllowed' }
    Test-Case V06 { Assert-Rejected '-Type review -T false -ImplementerFamily claude' 'SelectorFlagNotAllowed' }
    Test-Case V08 { Assert-Rejected '-Type edit -E maybe -T false' 'SelectorFlagMissing' }
    Test-Case V09 { Assert-Rejected '-Type survey -Tags telepathy' 'SelectorTagInvalid' }
    Test-Case V10 { Assert-Rejected '-Type survey -Tags family' 'SelectorTagInvalid' }
    Test-Case V11 { Assert-Rejected '-Type survey -Tags write' 'SelectorTagNotAllowed' }
    Test-Case V12 { Assert-Rejected '-Type review -Tags write -ImplementerFamily claude' 'SelectorTagNotAllowed' }
    Test-Case V13 { Assert-Rejected '-Type review' 'SelectorFamilyRequired' }
    Test-Case V14 { Assert-Rejected '-Type review -ImplementerFamily gemini' 'SelectorFamilyRequired' }
    Test-Case V15 { Assert-Rejected '-Type survey -Offline ghost' 'SelectorExecutorUnknown' }
    Test-Case V16 { Assert-Rejected '-Type survey -EscalateFrom ghost' 'SelectorFlagRemoved' }
    Test-Case V17 { Assert-Rejected '-Type edit -E true -T false -Offline sonnet,ghost' 'SelectorExecutorUnknown' }
    Test-Case V18 { Assert-Rejected '-Type generate -Tags write' 'SelectorTagNotAllowed' }

    Test-Case V19 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type test -Offline codex-test codex-review')
        $r.ExitCode -eq 2 -and $r.StdErr.StartsWith('SelectorParameterBinding') -and $r.StdErr.Contains('-Offline codex-test,codex-review') -and $r.StdErr -notmatch 'SelectorFlagNotAllowed' -and $r.StdErr -notmatch '旗標 E' -and [string]::IsNullOrWhiteSpace($r.StdOut)
    }
    Test-Case V20 { Assert-Rejected '-Type review' 'SelectorFamilyRequired' }
    Test-Case V21 {
        # 逗號連接的多值仍正常綁定，多個 -Tags 位置參數同樣回報參數綁定錯誤。
        $ok = Invoke-Selector -Arguments (Split-Args '-Type test -Tags browse,desktop-control')
        $bad = Invoke-Selector -Arguments (Split-Args '-Type test -Tags browse desktop-control')
        $ok.ExitCode -eq 0 -and $bad.ExitCode -eq 2 -and $bad.StdErr.StartsWith('SelectorParameterBinding')
    }

    Test-Case V22 { Assert-Rejected '-Type review -Deep true -ImplementerFamily claude' 'SelectorFlagRemoved' }
    Test-Case V23 { Assert-Rejected '-Type review -Deep false -ImplementerFamily claude' 'SelectorFlagRemoved' }
    Test-Case V24 { Assert-Rejected '-Type edit -E true -T false -Deep true' 'SelectorFlagRemoved' }
    Test-Case V25 { Assert-Rejected '-Type design -Tags write' 'SelectorTagNotAllowed' }
    Test-Case V26 { Assert-Rejected '-Type design -E true' 'SelectorFlagNotAllowed' }

    # 離線改派
    Test-Case F01 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude -Offline codex-review')
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -eq 'sonnet' -and (@($r.Json.unmetPreferences) -join ',') -eq 'family' -and $null -eq $r.Json.PSObject.Properties['degradations']
    }
    Test-Case F03 {
        foreach ($case in @('-Type test -Tags browse', '-Type test -Tags desktop-control')) {
            $r = Invoke-Selector -Arguments ((Split-Args $case) + @('-Offline', 'codex-test'))
            if ($r.ExitCode -ne 22 -or $r.Json.status -ne 'stopped' -or $r.Json.reason -ne 'offline' -or $null -ne $r.Json.executor) { throw "未停止：$case" }
        }
        $generate = Invoke-Selector -Arguments ((Split-Args '-Type generate') + @('-Offline', 'codex-factcheck'))
        if ($generate.ExitCode -ne 22 -or $generate.Json.status -ne 'stopped' -or $generate.Json.reason -ne 'offline' -or $null -ne $generate.Json.executor) { throw '-Type generate 離線未停止' }
        $true
    }
    Test-Case F04 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type factcheck -Offline codex-factcheck')
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -eq 'sonnet' -and @($r.Json.unmetPreferences).Count -eq 0
    }
    Test-Case F05 {
        foreach ($case in @('-Type advise -ImplementerFamily claude', '-Type advise -Authorized -ImplementerFamily claude')) {
            $r = Invoke-Selector -Arguments ((Split-Args $case) + @('-Offline', 'codex-advisor'))
            if ($r.ExitCode -ne 21 -or $r.Json.status -ne 'omitted' -or $null -ne $r.Json.executor) { throw "顧問離線應回報 omitted 且不選任何執行者：$case" }
        }
        $true
    }
    $allCodex = 'codex-test,codex-factcheck,codex-review,codex-advisor'
    Test-Case F06 {
        $test = Invoke-Selector -Arguments ((Split-Args '-Type test -Tags browse') + @('-Offline', $allCodex))
        $generate = Invoke-Selector -Arguments ((Split-Args '-Type generate') + @('-Offline', $allCodex))
        $factcheck = Invoke-Selector -Arguments ((Split-Args '-Type factcheck') + @('-Offline', $allCodex))
        $review = Invoke-Selector -Arguments ((Split-Args '-Type review -ImplementerFamily claude') + @('-Offline', $allCodex))
        $advise = Invoke-Selector -Arguments ((Split-Args '-Type advise -ImplementerFamily claude') + @('-Offline', $allCodex))
        $test.ExitCode -eq 22 -and $test.Json.status -eq 'stopped' -and
        $generate.ExitCode -eq 22 -and $generate.Json.status -eq 'stopped' -and
        $factcheck.ExitCode -eq 0 -and $factcheck.Json.executor.id -eq 'sonnet' -and @($factcheck.Json.unmetPreferences).Count -eq 0 -and
        $review.ExitCode -eq 0 -and $review.Json.status -eq 'selected' -and $review.Json.executor.id -eq 'sonnet' -and
        $advise.ExitCode -eq 21 -and $advise.Json.status -eq 'omitted' -and $null -eq $advise.Json.executor
    }
    Test-Case F23 {
        foreach ($case in @('-Type test -Tags browse', '-Type test -Tags desktop-control', '-Type generate')) {
            $r = Invoke-Selector -Arguments ((Split-Args $case) + @('-Offline', $allCodex))
            if ($r.ExitCode -ne 22 -or $r.Json.status -ne 'stopped' -or $null -ne $r.Json.executor) { throw "全 Codex 離線時未停止：$case" }
        }
        $true
    }
    Test-Case F07 {
        $edit = Invoke-Selector -Arguments ((Split-Args '-Type edit -E true -T false') + @('-Offline', $allCodex))
        $survey = Invoke-Selector -Arguments ((Split-Args '-Type survey') + @('-Offline', $allCodex))
        $edit.Json.executor.id -eq 'haiku' -and $survey.Json.executor.id -eq 'sonnet'
    }
    Test-Case F08 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type edit -E true -T false -Offline haiku')
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -eq 'sonnet'
    }
    Test-Case F09 {
        # 前兩位候選離線時由候選清單的下一位承接；候選全部離線才停止。
        $first = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude')
        $candidates = @($first.Json.candidates)
        $r = Invoke-Selector -Arguments ((Split-Args '-Type review -ImplementerFamily claude') + @('-Offline', (@($candidates[0], $candidates[1]) -join ',')))
        $candidates.Count -ge 3 -and $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -eq $candidates[2] -and @($r.Json.skipped).Count -eq 2
    }
    Test-Case F10 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude -Offline codex-review')
        $reasons = @{}
        foreach ($row in $r.Json.considered) { $reasons[$row.id] = $row.reason }
        $reasons['codex-review'] -eq 'offline' -and $reasons['sonnet'] -eq 'selected' -and $reasons['codex-factcheck'] -eq 'type-not-accepted'
    }

    Test-Case F11 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type factcheck -Offline codex-test')
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -eq 'codex-factcheck'
    }
    Test-Case F12 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type generate -Offline codex-test')
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -eq 'codex-factcheck'
    }

    # 以下各組使用自建登錄表（New-FixtureRegistry），不依賴出貨登錄表的執行者。
    $fixture = New-FixtureRegistry 'base'

    # 必要條件與優先條件的比對
    Test-Case M01 {
        # 兩個優先條件逐項比較：先比 net，再比 gui，都相同才依排序值。
        $r = Invoke-Fixture '-Type probe' $fixture
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and (@($r.Json.candidates) -join ',') -eq 'echo,delta,golf,charlie' -and $r.Json.executor.id -eq 'echo' -and
        @($r.Json.unmetPreferences).Count -eq 0 -and (@($r.Json.labels.prefer) -join ',') -eq 'net,gui' -and $r.Json.reason -eq 'best-match'
    }
    Test-Case M02 {
        # 第一項優先條件的重要性高於第二項：delta 只滿足 net、charlie 只滿足 gui，delta 在前。
        $r = Invoke-Fixture '-Type probe -Offline echo' $fixture
        $r.Json.executor.id -eq 'delta' -and (@($r.Json.unmetPreferences) -join ',') -eq 'gui' -and $r.Json.dispatchLine -ceq '[派工] 交給 Delta：probe；未滿足優先條件 gui；已略過 echo（離線）'
    }
    Test-Case M03 {
        # 優先條件全部相同時依排序值：delta（40）與 golf（45）都只滿足 net。
        $r = Invoke-Fixture '-Type probe -Offline echo,delta' $fixture
        $r.Json.executor.id -eq 'golf' -and (@($r.Json.skipped | ForEach-Object { $_.id + ':' + $_.reason }) -join ',') -eq 'echo:offline,delta:offline'
    }
    Test-Case M04 {
        # 沒有優先條件的類型只依排序值；任務以 -Prefer 宣告後改變順序。
        $plain = Invoke-Fixture '-Type look' $fixture
        $prefer = Invoke-Fixture '-Type look -Prefer net' $fixture
        (@($plain.Json.candidates) -join ',') -eq 'charlie,delta' -and $plain.Json.executor.id -eq 'charlie' -and
        (@($prefer.Json.candidates) -join ',') -eq 'delta,charlie' -and $prefer.Json.executor.id -eq 'delta' -and (@($prefer.Json.labels.prefer) -join ',') -eq 'net'
    }
    Test-Case M05 {
        # -Prefer 接在類型的 preferred 之後，重複者不再加入；類型的優先條件仍先比較。
        $r = Invoke-Fixture '-Type probe -Prefer gui,run,net' $fixture
        (@($r.Json.labels.prefer) -join ',') -eq 'net,gui,run' -and (@($r.Json.candidates) -join ',') -eq 'echo,delta,golf,charlie'
    }
    Test-Case M06 {
        # 必要條件先於優先條件：-Tags 排除不具備的執行者，不論其優先條件多符合。
        $r = Invoke-Fixture '-Type probe -Tags gui' $fixture
        $reasons = @{}
        foreach ($row in $r.Json.considered) { $reasons[$row.id] = $row.reason }
        (@($r.Json.candidates) -join ',') -eq 'echo,charlie' -and $reasons['delta'] -eq 'tag-missing:gui' -and $reasons['golf'] -eq 'tag-missing:gui' -and $reasons['alpha'] -eq 'type-not-accepted'
    }
    Test-Case M07 {
        # 沒有任何執行者符合必要條件。
        $r = Invoke-Fixture '-Type look -Tags gui,net' $fixture
        $r.ExitCode -eq 22 -and $r.Json.status -eq 'stopped' -and $r.Json.reason -eq 'no-eligible-executor' -and @($r.Json.candidates).Count -eq 0
    }
    Test-Case M08 {
        # 跨家族是優先條件：Codex 可用時選 Codex，實作者為 codex 時同家族的 bravo 排到最後。
        $claude = Invoke-Fixture '-Type check -ImplementerFamily claude' $fixture
        $codex = Invoke-Fixture '-Type check -ImplementerFamily codex' $fixture
        $claude.Json.executor.id -eq 'bravo' -and @($claude.Json.unmetPreferences).Count -eq 0 -and (@($claude.Json.candidates) -join ',') -eq 'bravo,charlie,delta' -and
        $codex.Json.executor.id -eq 'charlie' -and (@($codex.Json.candidates) -join ',') -eq 'charlie,delta,bravo'
    }
    Test-Case M09 {
        Assert-Rejected '-Type look -Prefer telepathy' 'SelectorPreferInvalid' 2 $fixture
    }
    Test-Case M10 {
        Assert-Rejected '-Type look -Prefer gated' 'SelectorPreferInvalid' 2 $fixture
    }
    Test-Case M11 {
        # 任務自行宣告 family 優先條件時同樣必須提供實作者家族。
        (Assert-Rejected '-Type look -Prefer family' 'SelectorFamilyRequired' 2 $fixture) -and (Invoke-Fixture '-Type look -Prefer family -ImplementerFamily claude' $fixture).ExitCode -eq 0
    }

    # 不可用時的選派
    Test-Case U01 {
        # 首選不可用時選出下一位，狀態仍是 selected、結束碼 0，並標出未滿足的優先條件與被略過者。
        $r = Invoke-Fixture '-Type check -ImplementerFamily claude -Offline bravo' $fixture
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -eq 'charlie' -and (@($r.Json.unmetPreferences) -join ',') -eq 'family' -and
        $r.Json.requiresUserDecision -eq $false -and $null -eq $r.Json.PSObject.Properties['degradations'] -and
        $r.Json.dispatchLine -ceq '[派工] 交給 Charlie：check；找不到不同模型家族的執行者，改由同家族審查；已略過 bravo（離線）'
    }
    Test-Case U02 {
        # 選派入口不保存不可用狀態：下一次不帶 -Offline 的呼叫仍先選首選。
        $null = Invoke-Fixture '-Type check -ImplementerFamily claude -Offline bravo' $fixture
        $r = Invoke-Fixture '-Type check -ImplementerFamily claude' $fixture
        $r.Json.executor.id -eq 'bravo' -and @($r.Json.skipped).Count -eq 0 -and $r.Json.dispatchLine -ceq '[派工] 交給 Bravo：check'
    }
    Test-Case U03 {
        $r = Invoke-Fixture '-Type check -ImplementerFamily claude -Offline bravo,charlie,delta' $fixture
        $r.ExitCode -eq 22 -and $r.Json.status -eq 'stopped' -and $r.Json.reason -eq 'offline' -and $null -eq $r.Json.executor -and $r.Json.requiresUserDecision -eq $false -and
        $r.Json.dispatchLine -ceq '[派工] 停止，沒有可用的執行者：check；已略過 bravo（離線）、charlie（離線）、delta（離線）'
    }
    Test-Case U04 {
        # 需授權的首選不可用時，下一位不需授權即可承接；首選可用且未授權時仍為待授權。
        $offline = Invoke-Fixture '-Type ask -ImplementerFamily claude -Offline foxtrot' $fixture
        $gated = Invoke-Fixture '-Type ask -ImplementerFamily claude' $fixture
        $offline.ExitCode -eq 0 -and $offline.Json.executor.id -eq 'charlie' -and $gated.ExitCode -eq 20 -and $gated.Json.status -eq 'needs-authorization' -and $gated.Json.executor.id -eq 'foxtrot'
    }
    Test-Case U05 {
        # 輸出不再有 degraded 狀態、降級字樣與已移除的欄位。
        $r = Invoke-Fixture '-Type check -ImplementerFamily claude -Offline bravo' $fixture
        $r.StdOut -notmatch 'degrad' -and $r.Json.dispatchLine -notmatch '降級' -and $null -eq $r.Json.labels.PSObject.Properties['escalateFrom']
    }

    # 未完成次數與切換
    Test-Case I01 {
        # 未達上限不切換。
        $r = Invoke-Fixture '-Type edit -E true -T false -Incomplete alpha:2' $fixture
        $r.ExitCode -eq 0 -and $r.Json.executor.id -eq 'alpha' -and @($r.Json.skipped).Count -eq 0 -and $r.Json.labels.incomplete.alpha -eq 2
    }
    Test-Case I02 {
        # 達上限即自動換下一位，不需使用者決定。
        $r = Invoke-Fixture '-Type edit -E true -T false -Incomplete alpha:3' $fixture
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -eq 'charlie' -and $r.Json.requiresUserDecision -eq $false -and
        $r.Json.dispatchLine -ceq '[派工] 交給 Charlie：改檔，範圍已列明、不需建置測試；已略過 alpha（未完成次數已達上限）' -and
        @($r.Json.considered | Where-Object { $_.id -eq 'alpha' })[0].reason -eq 'incomplete-limit'
    }
    Test-Case I03 {
        $r = Invoke-Fixture '-Type edit -E true -T false -Incomplete alpha:3,charlie:4' $fixture
        $r.ExitCode -eq 0 -and $r.Json.executor.id -eq 'delta'
    }
    Test-Case I04 {
        # 最後一位也達上限：回傳需使用者決定，結束碼 10，沒有執行者。
        $r = Invoke-Fixture '-Type edit -E true -T false -Incomplete alpha:3,charlie:3,delta:3' $fixture
        $r.ExitCode -eq 10 -and $r.Json.status -eq 'needs-user-decision' -and $r.Json.reason -eq 'all-candidates-exhausted' -and $null -eq $r.Json.executor -and $r.Json.requiresUserDecision -eq $true -and
        $r.Json.dispatchLine -ceq '[派工] 需你決定，目前沒有可交付的執行者：改檔，範圍已列明、不需建置測試；已略過 alpha（未完成次數已達上限）、charlie（未完成次數已達上限）、delta（未完成次數已達上限）'
    }
    Test-Case I05 {
        # 不是候選的執行者的次數不影響結果（E=否時 alpha 不符合 when）。
        $r = Invoke-Fixture '-Type edit -E false -T true -Incomplete alpha:9' $fixture
        $r.ExitCode -eq 0 -and $r.Json.executor.id -eq 'charlie' -and @($r.Json.skipped).Count -eq 0
    }
    Test-Case I06 {
        # 離線與未完成並存：有人因未完成上限被略過且沒有人可選時為需使用者決定；全部只是離線時為停止。
        $mixed = Invoke-Fixture '-Type look -Offline charlie -Incomplete delta:3' $fixture
        $offline = Invoke-Fixture '-Type look -Offline charlie,delta' $fixture
        $mixed.ExitCode -eq 10 -and $mixed.Json.status -eq 'needs-user-decision' -and $offline.ExitCode -eq 22 -and $offline.Json.status -eq 'stopped'
    }
    Test-Case I07 {
        # 上限取自登錄表 maxIncomplete。
        $two = New-FixtureRegistry 'max-two' { param($r) $r.maxIncomplete = 2 }
        (Invoke-Fixture '-Type edit -E true -T false -Incomplete alpha:2' $two).Json.executor.id -eq 'charlie' -and (Invoke-Fixture '-Type edit -E true -T false -Incomplete alpha:1' $two).Json.executor.id -eq 'alpha'
    }
    Test-Case I08 {
        # 審查者換人：首選達上限後由同家族的下一位承接。
        $r = Invoke-Fixture '-Type check -ImplementerFamily claude -Incomplete bravo:3' $fixture
        $r.ExitCode -eq 0 -and $r.Json.executor.id -eq 'charlie' -and (@($r.Json.unmetPreferences) -join ',') -eq 'family'
    }
    Test-Case I09 { Assert-Rejected '-Type look -Incomplete charlie' 'SelectorIncompleteInvalid' 2 $fixture }
    Test-Case I10 { Assert-Rejected '-Type look -Incomplete charlie:x' 'SelectorIncompleteInvalid' 2 $fixture }
    Test-Case I11 { Assert-Rejected '-Type look -Incomplete ghost:1' 'SelectorExecutorUnknown' 2 $fixture }
    Test-Case I12 { Assert-Rejected '-Type look -Incomplete charlie:1,charlie:2' 'SelectorIncompleteInvalid' 2 $fixture }
    Test-Case I14 {
        # 同一 id 重複時即使次數相同也拒絕（以單一逗號連接的字串傳入）。
        $single = Invoke-Fixture '-Type look -Incomplete charlie:1,charlie:1' $fixture
        $single.ExitCode -eq 2 -and $single.StdErr.StartsWith('SelectorIncompleteInvalid') -and [string]::IsNullOrWhiteSpace($single.StdOut)
    }
    Test-Case I15 {
        # 次數的範圍為 0 至上限（999），與登錄表 maxIncomplete 的上限相同：邊界值可用，超過即拒絕並在訊息寫明範圍。
        $zero = Invoke-Fixture '-Type look -Incomplete charlie:0' $fixture
        $top = Invoke-Fixture '-Type look -Incomplete charlie:999' $fixture
        $over = Invoke-Fixture '-Type look -Incomplete charlie:1000' $fixture
        $huge = Invoke-Fixture '-Type look -Incomplete charlie:99999999999999999999' $fixture
        $negative = Invoke-Fixture '-Type look -Incomplete charlie:-1' $fixture
        $zero.ExitCode -eq 0 -and $zero.Json.executor.id -eq 'charlie' -and $zero.Json.labels.incomplete.charlie -eq 0 -and
        $top.ExitCode -eq 0 -and $top.Json.executor.id -eq 'delta' -and $top.Json.labels.incomplete.charlie -eq 999 -and
        $over.ExitCode -eq 2 -and $over.StdErr.StartsWith('SelectorIncompleteInvalid') -and $over.StdErr.Contains('999') -and
        $huge.ExitCode -eq 2 -and $huge.StdErr.StartsWith('SelectorIncompleteInvalid') -and
        $negative.ExitCode -eq 2 -and $negative.StdErr.StartsWith('SelectorIncompleteInvalid')
    }
    Test-Case I16 {
        # 登錄表 maxIncomplete 設為上限時，合法的 -Incomplete 次數可以到達這個門檻。
        $top = New-FixtureRegistry 'max-top' { param($r) $r.maxIncomplete = 999 }
        $below = Invoke-Fixture '-Type look -Incomplete charlie:998' $top
        $reached = Invoke-Fixture '-Type look -Incomplete charlie:999' $top
        $describe = Invoke-Selector -Arguments @('-Describe') -Registry $top
        $below.Json.executor.id -eq 'charlie' -and $reached.Json.executor.id -eq 'delta' -and $describe.Json.maxIncomplete -eq 999
    }
    Test-Case I13 {
        # -EscalateFrom 已移除，訊息指向 -Incomplete。
        $r = Invoke-Fixture '-Type edit -E true -T false -EscalateFrom alpha' $fixture
        $r.ExitCode -eq 2 -and $r.StdErr.StartsWith('SelectorFlagRemoved') -and $r.StdErr.Contains('-Incomplete') -and [string]::IsNullOrWhiteSpace($r.StdOut)
    }

    # 備援 model 與新欄位的登錄表驗證
    Test-Case B01 {
        $r = Invoke-Selector -Arguments @('-Describe') -Registry $fixture
        $bravo = @($r.Json.executors | Where-Object { $_.id -eq 'bravo' })[0]
        $foxtrot = @($r.Json.executors | Where-Object { $_.id -eq 'foxtrot' })[0]
        $r.ExitCode -eq 0 -and (@($bravo.profileSettings.fallbackModels) -join ',') -eq 'mid,small' -and @($foxtrot.profileSettings.fallbackModels).Count -eq 0 -and $r.Json.maxIncomplete -eq 3 -and
        $null -eq $bravo.PSObject.Properties['escalatesTo'] -and $null -eq $bravo.PSObject.Properties['escalationOnly']
    }
    Test-Case B03 {
        # 空陣列與省略都合法：preferred 為空陣列的類型沒有優先條件，fallbackModels 為空陣列的執行者沒有備援 model。
        $path = New-FixtureRegistry 'empty-arrays' { param($r) $r.types.check.preferred = @(); $r.executors[1].profileSettings.fallbackModels = @() }
        $describe = Invoke-Selector -Arguments @('-Describe') -Registry $path
        $check = @($describe.Json.types | Where-Object { $_.name -eq 'check' })[0]
        $bravo = @($describe.Json.executors | Where-Object { $_.id -eq 'bravo' })[0]
        $describe.ExitCode -eq 0 -and @($check.preferred).Count -eq 0 -and @($bravo.profileSettings.fallbackModels).Count -eq 0 -and (Invoke-Fixture '-Type check' $path).ExitCode -eq 0
    }
    Test-Case B02 {
        $invalid = [ordered]@{
            'fallback-dup'        = { param($r) $r.executors[1].profileSettings.fallbackModels = @('mid', 'mid') }
            'fallback-primary'    = { param($r) $r.executors[1].profileSettings.fallbackModels = @('big') }
            'fallback-bad-name'   = { param($r) $r.executors[1].profileSettings.fallbackModels = @('has space') }
            'max-zero'            = { param($r) $r.maxIncomplete = 0 }
            'max-over-limit'      = { param($r) $r.maxIncomplete = 1000 }
            'max-int64'           = { param($r) $r.maxIncomplete = 4294967296 }
            'max-string'          = { param($r) $r.maxIncomplete = '3' }
            'max-fraction'        = { param($r) $r.maxIncomplete = 2.5 }
            'preferred-scalar'    = { param($r) $r.types.check.preferred = 'family' }
            'fallback-scalar'     = { param($r) $r.executors[1].profileSettings.fallbackModels = 'mid' }
            'max-missing'         = { param($r) $r.PSObject.Properties.Remove('maxIncomplete') }
            'preferred-unknown'   = { param($r) $r.types.look | Add-Member -NotePropertyName preferred -NotePropertyValue @('telepathy') }
            'preferred-gated'     = { param($r) $r.types.look | Add-Member -NotePropertyName preferred -NotePropertyValue @('gated') }
            'preferred-dup'       = { param($r) $r.types.probe.preferred = @('net', 'net') }
            'type-no-executor'    = { param($r) $r.types | Add-Member -NotePropertyName orphan -NotePropertyValue ([pscustomobject]@{ requiredFlags = @(); impliedTags = @(); forbiddenTags = @() }) }
            'removed-crossfamily' = { param($r) $r.types.check | Add-Member -NotePropertyName crossFamily -NotePropertyValue $true }
            'removed-degradable'  = { param($r) $r.types.check | Add-Member -NotePropertyName degradable -NotePropertyValue @('family') }
            'removed-escalatesto' = { param($r) $r.executors[0] | Add-Member -NotePropertyName escalatesTo -NotePropertyValue 'charlie' }
            'removed-esc-only'    = { param($r) $r.executors[6] | Add-Member -NotePropertyName escalationOnly -NotePropertyValue $true }
            'removed-onoffline'   = { param($r) $r.executors[1] | Add-Member -NotePropertyName onOffline -NotePropertyValue ([pscustomobject]@{ check = 'stop' }) }
        }
        foreach ($name in $invalid.Keys) {
            $path = New-FixtureRegistry $name $invalid[$name]
            if (-not (Assert-Rejected '-Type look' 'SelectorRegistryInvalid' 3 $path)) { throw "登錄表應被判定無效：$name" }
        }
        $true
    }
    Test-Case B04 {
        # 假登錄表的 -Describe：Claude 執行者含 selfRepair，Codex 執行者沒有。
        $r = Invoke-Selector -Arguments @('-Describe') -Registry $fixture
        $byId = @{}
        foreach ($row in $r.Json.executors) { $byId[$row.id] = $row }
        $r.ExitCode -eq 0 -and $byId['alpha'].selfRepair -eq $false -and $byId['charlie'].selfRepair -eq $true -and $null -eq $byId['bravo'].PSObject.Properties['selfRepair']
    }

    # 登錄表驗證失敗（暫存複本）
    Test-Case R01 {
        $path = New-RegistryCopy 'dup-id' { param($r) $r.executors[1].id = $r.executors[0].id }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R02 {
        $path = New-RegistryCopy 'dup-order' { param($r) $r.executors[1].order = 10 }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R03 {
        $path = New-RegistryCopy 'tag-overflow' { param($r) $r.tags.hard = @($r.tags.hard) + @('extra-tag') }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R06 {
        $retired = [string]@($registryRaw.retiredProfiles)[0]
        $path = New-RegistryCopy 'profile-retired' { param($r) (Get-ExecutorNode $r 'codex-test').profile = $retired }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R07 {
        # 退役名單完全由登錄表的 retiredProfiles 決定：改名單後，原名單內的名稱可用，新名單內的名稱被拒絕。
        $path = New-RegistryCopy 'retired-custom' { param($r) $r.retiredProfiles = @('zzz-retired'); (Get-ExecutorNode $r 'codex-test').profile = 'zzz-retired' }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
        $path2 = New-RegistryCopy 'retired-custom-ok' { param($r) $r.retiredProfiles = @('zzz-retired'); (Get-ExecutorNode $r 'codex-test').profile = 'implement' }
        $r2 = Invoke-Selector -Arguments (Split-Args '-Describe') -Registry $path2
        $r2.ExitCode -eq 0
    }
    Test-Case R08 { Assert-Rejected '-Type survey' 'SelectorRegistryNotFound' 3 (Join-Path $tempRoot 'missing.json') }
    Test-Case R09 {
        $path = New-RegistryCopy 'empty-executors' { param($r) $r.executors = @() }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R10 {
        $path = Join-Path $tempRoot 'zero-bytes.json'
        [IO.File]::WriteAllBytes($path, [byte[]]@())
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R11 {
        $path = Join-Path $tempRoot 'not-json.json'
        [IO.File]::WriteAllText($path, '{ not json', (New-Object Text.UTF8Encoding($false)))
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R12 {
        $path = New-RegistryCopy 'unknown-tag' { param($r) (Get-ExecutorNode $r 'sonnet').tags = @('write', 'telepathy') }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R15 {
        $path = New-RegistryCopy 'unknown-type' { param($r) (Get-ExecutorNode $r 'sonnet').accepts = @('edit', 'survey', 'review', 'factcheck', 'dream') }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R16 {
        $path = New-RegistryCopy 'when-flag' { param($r) (Get-ExecutorNode $r 'codex-test').when = [pscustomobject]@{ Deep = $true } }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R19 {
        $path = New-RegistryCopy 'codex-no-profile' { param($r) $node = Get-ExecutorNode $r 'codex-advisor'; $node.PSObject.Properties.Remove('profile') }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R19A {
        $path = New-RegistryCopy 'no-profile-settings' { param($r) (Get-ExecutorNode $r 'codex-review').PSObject.Properties.Remove('profileSettings') }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R19B {
        $path = New-RegistryCopy 'no-effort' { param($r) (Get-ExecutorNode $r 'codex-test').profileSettings.PSObject.Properties.Remove('effort') }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R19C {
        $path = New-RegistryCopy 'bad-model-value' { param($r) (Get-ExecutorNode $r 'codex-review').profileSettings.model = 'x"; [evil]' }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R19D {
        $path = New-RegistryCopy 'duplicate-profile' { param($r) (Get-ExecutorNode $r 'codex-factcheck').profile = 'review' }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R19E {
        # 新增檔位只改登錄表即可通過驗證（不再有腳本內白名單）。
        $path = New-RegistryCopy 'new-profile' { param($r) (Get-ExecutorNode $r 'codex-factcheck').profile = 'factcheck-2' }
        $r = Invoke-Selector -Arguments (Split-Args '-Describe') -Registry $path
        $r.ExitCode -eq 0
    }
    Test-Case R19F {
        $path = New-RegistryCopy 'claude-with-settings' { param($r) (Get-ExecutorNode $r 'sonnet') | Add-Member -NotePropertyName profileSettings -NotePropertyValue ([pscustomobject]@{ model = 'm' }) }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R19G {
        $path = New-RegistryCopy 'platform-case' { param($r) (Get-ExecutorNode $r 'codex-review').platform = 'Codex' }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R19H {
        $path = New-RegistryCopy 'effort-not-allowed' { param($r) (Get-ExecutorNode $r 'codex-review').profileSettings.effort = 'turbo' }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R19I {
        $path = New-RegistryCopy 'subagent-effort-not-allowed' { param($r) (Get-ExecutorNode $r 'codex-review').profileSettings.subagentEffort = 'turbo' }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R19J {
        $path = New-RegistryCopy 'id-newline' { param($r) (Get-ExecutorNode $r 'codex-review').id = "codex-x`n[evil]" }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R19K {
        $path = New-RegistryCopy 'no-efforts-list' { param($r) $r.PSObject.Properties.Remove('codexEfforts') }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R20 {
        $path = New-RegistryCopy 'bad-schema' { param($r) $r.schema = 'ai-agents.executor-registry.v0' }
        Assert-Rejected '-Describe' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R21 {
        $path = New-RegistryCopy 'unchanged' { param($r) }
        $r = Invoke-Selector -Arguments (Split-Args '-Type edit -E true -T false') -Registry $path
        $r.ExitCode -eq 0 -and $r.Json.executor.id -eq 'haiku'
    }
    Test-Case R22 {
        $path = New-RegistryCopy 'haiku-demoted' { param($r) (Get-ExecutorNode $r 'haiku').order = 60 }
        $r = Invoke-Selector -Arguments (Split-Args '-Type edit -E true -T false') -Registry $path
        $r.ExitCode -eq 0 -and $r.Json.executor.id -eq 'sonnet'
    }
    Test-Case R23 {
        $path = New-RegistryCopy 'sonnet-first' { param($r) (Get-ExecutorNode $r 'sonnet').order = 5 }
        $r = Invoke-Selector -Arguments (Split-Args '-Type edit -E true -T false') -Registry $path
        $r.ExitCode -eq 0 -and $r.Json.executor.id -eq 'sonnet'
    }

    Test-Case R24 {
        $path = New-RegistryCopy 'no-retired-list' { param($r) $r.PSObject.Properties.Remove('retiredProfiles') ; (Get-ExecutorNode $r 'codex-review').profile = 'implement' }
        $r3 = Invoke-Selector -Arguments (Split-Args '-Describe') -Registry $path
        $r3.ExitCode -eq 0
    }
    Test-Case R25 {
        # Claude 執行者的 selfRepair 缺少或不是布林、Codex 執行者帶有 selfRepair，登錄表一律無效。
        $missing = New-RegistryCopy 'self-repair-missing' { param($r) [void](Get-ExecutorNode $r 'sonnet').PSObject.Properties.Remove('selfRepair') }
        $text = New-RegistryCopy 'self-repair-text' { param($r) (Get-ExecutorNode $r 'sonnet').selfRepair = 'true' }
        $number = New-RegistryCopy 'self-repair-number' { param($r) (Get-ExecutorNode $r 'sonnet').selfRepair = 1 }
        $nullValue = New-RegistryCopy 'self-repair-null' { param($r) (Get-ExecutorNode $r 'sonnet').selfRepair = $null }
        $onCodex = New-RegistryCopy 'self-repair-codex' { param($r) (Get-ExecutorNode $r 'codex-review') | Add-Member -NotePropertyName selfRepair -NotePropertyValue $true }
        (Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $missing) -and (Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $text) -and
        (Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $number) -and (Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $nullValue) -and
        (Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $onCodex) -and
        # 拒絕原因必須是 selfRepair，避免變體因其他欄位被拒而誤判通過。
        (@(@($missing, $text, $number, $nullValue, $onCodex) | Where-Object { (Invoke-Selector -Arguments (Split-Args '-Type survey') -Registry $_).StdErr -notmatch 'selfRepair' }).Count -eq 0)
    }

    # 決定性
    Test-Case X01 {
        foreach ($case in @('-Type edit -E true -T false -Label 範例', '-Type review -ImplementerFamily claude -Offline codex-review', '-Type advise -ImplementerFamily claude', '-Type test -Tags browse -Offline codex-test', '-Type edit -E true -T false -EscalateFrom haiku')) {
            $first = Invoke-Selector -Arguments (Split-Args $case)
            $second = Invoke-Selector -Arguments (Split-Args $case)
            if ($first.StdOut -cne $second.StdOut -or $first.ExitCode -ne $second.ExitCode) { throw "輸出不一致：$case" }
        }
        $a = Invoke-Selector -Arguments @('-Describe')
        $b = Invoke-Selector -Arguments @('-Describe')
        $a.StdOut -ceq $b.StdOut
    }
    Test-Case X02 {
        $a = Invoke-Selector -Arguments (Split-Args '-Type survey -Offline codex-test,codex-review')
        $b = Invoke-Selector -Arguments (Split-Args '-Type survey -Offline codex-review,codex-test')
        $a.StdOut -ceq $b.StdOut -or ($a.Json.executor.id -eq $b.Json.executor.id -and $a.ExitCode -eq $b.ExitCode)
    }
    Test-Case X03 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type survey')
        $r.StdOut -notmatch '[^\u0000-\u007F]' -and $r.Json.schema -eq 'ai-agents.executor-selection.v1' -and @($r.Json.considered).Count -eq @($registryRaw.executors).Count
    }

    # dispatchLine 格式
    Test-Case L01 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type edit -E true -T false')
        $r.Json.dispatchLine -ceq '[派工] 交給 Haiku subagent：改檔，範圍已列明、不需建置測試'
    }
    Test-Case L02 {
        $r = Invoke-Selector -Arguments @('-Type', 'edit', '-E', 'false', '-T', 'true', '-Label', 'P3 重構')
        $r.Json.dispatchLine -ceq '[派工] 交給 Sonnet subagent：P3 重構，改檔，範圍需自行探索、需要建置測試'
    }
    Test-Case L03 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude')
        $r.Json.dispatchLine -ceq '[派工] 交給 Codex review：審查' -and $r.Json.dispatchLine -notmatch ' E=| T='
    }
    Test-Case L04 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude -Offline codex-review')
        $r.Json.dispatchLine -ceq '[派工] 交給 Sonnet subagent：審查；找不到不同模型家族的執行者，改由同家族審查；已略過 codex-review（離線）'
    }
    Test-Case L05 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type advise -ImplementerFamily claude')
        $r.Json.dispatchLine -ceq '[派工] 等你授權後交給 Codex advisor：提供顧問意見'
    }
    Test-Case L06 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type advise -ImplementerFamily claude -Offline codex-advisor')
        $r.Json.dispatchLine -ceq '[派工] 不執行，沒有可用的執行者，這項工作可以不做：提供顧問意見；已略過 codex-advisor（離線）'
    }
    Test-Case L07 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type generate -Offline codex-factcheck')
        $r.Json.dispatchLine -ceq '[派工] 停止，沒有可用的執行者：產生影像；已略過 codex-factcheck（離線）'
    }
    Test-Case L09 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type test')
        $r.Json.dispatchLine -ceq '[派工] 交給 Codex test：測試取證'
    }

    Test-Case L10 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type generate')
        $r.Json.dispatchLine -ceq '[派工] 交給 Codex factcheck：產生影像'
    }
    Test-Case L11 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type factcheck')
        $r.Json.dispatchLine -ceq '[派工] 交給 Codex factcheck：事實查核'
    }
    Test-Case L12 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type design')
        $r.Json.dispatchLine -ceq '[派工] 交給 Sonnet subagent：設計起草'
    }
    Test-Case L13 {
        $r = Invoke-Selector -Arguments @('-Type', 'design', '-Label', 'P1 起草')
        $r.Json.dispatchLine -ceq '[派工] 交給 Sonnet subagent：P1 起草，設計起草'
    }

    # 登錄表 entry 欄位（審查、事實校閱、影像產生、顧問切到新入口，測試取證維持現行入口）
    Test-Case EN01 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude')
        $r.ExitCode -eq 0 -and $r.Json.executor.id -ceq 'codex-review' -and $r.Json.executor.entry -ceq 'scripts/Invoke-CodexRun.ps1' -and $r.Json.executor.profile -ceq 'review'
    }
    Test-Case EN02 {
        $cases = @(
            @('-Type test', 'codex-test', 'scripts/Invoke-CodexRun.ps1'), @('-Type generate', 'codex-factcheck', 'scripts/Invoke-CodexRun.ps1'),
            @('-Type factcheck', 'codex-factcheck', 'scripts/Invoke-CodexRun.ps1'), @('-Type advise -ImplementerFamily claude -Authorized', 'codex-advisor', 'scripts/Invoke-CodexRun.ps1'))
        @($cases | Where-Object {
                $r = Invoke-Selector -Arguments (Split-Args $_[0])
                -not ($r.ExitCode -eq 0 -and $r.Json.executor.id -ceq $_[1] -and $r.Json.executor.entry -ceq $_[2])
            }).Count -eq 0
    }
    Test-Case EN09 {
        # 測試取證：Codex test 只做 MCP 操作（browse、desktop-control、web），建置與測試命令（build-test）改由 Claude 執行者承接。
        $browse = Invoke-Selector -Arguments (Split-Args '-Type test -Tags browse')
        $desktop = Invoke-Selector -Arguments (Split-Args '-Type test -Tags desktop-control')
        $build = Invoke-Selector -Arguments (Split-Args '-Type test -Tags build-test')
        $browseBuild = Invoke-Selector -Arguments (Split-Args '-Type test -Tags browse,build-test')
        $browse.ExitCode -eq 0 -and $browse.Json.executor.id -ceq 'codex-test' -and $desktop.ExitCode -eq 0 -and $desktop.Json.executor.id -ceq 'codex-test' `
            -and $build.ExitCode -eq 0 -and $build.Json.executor.id -ceq 'sonnet' -and $browseBuild.ExitCode -ne 0 -and $browseBuild.Json.status -ceq 'stopped'
    }
    Test-Case EN10 {
        # 經 Invoke-CodexRun.ps1 的 test 全數離線時，入口以 -Tags browse 重新選派（Get-RunFallbackSelection）：瀏覽器與桌面取證沒有 Claude 替代者，必須是 stopped。
        $offline = @('-Offline', 'codex-test,codex-factcheck,codex-review,codex-advisor')
        $stopped = Invoke-Selector -Arguments ((Split-Args '-Type test -ImplementerFamily claude -Tags browse') + $offline)
        $desktopStopped = Invoke-Selector -Arguments ((Split-Args '-Type test -ImplementerFamily claude -Tags desktop-control') + $offline)
        $stopped.ExitCode -ne 0 -and $stopped.Json.status -ceq 'stopped' -and $null -eq $stopped.Json.executor `
            -and $desktopStopped.ExitCode -ne 0 -and $desktopStopped.Json.status -ceq 'stopped'
    }
    Test-Case EN03 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type survey')
        $r.ExitCode -eq 0 -and $r.Json.executor.platform -ceq 'claude' -and $null -eq $r.Json.executor.PSObject.Properties['entry']
    }
    Test-Case EN04 {
        $r = Invoke-Selector -Arguments (Split-Args '-Describe')
        $rows = @($r.Json.executors)
        $codexRows = @($rows | Where-Object { $_.platform -ceq 'codex' })
        $claudeRows = @($rows | Where-Object { $_.platform -ceq 'claude' })
        $entries = @($codexRows | ForEach-Object { $_.id + '=' + $_.entry })
        $rawEntries = @($registryRaw.executors | Where-Object { $_.platform -ceq 'codex' } | ForEach-Object { $_.id + '=' + $_.entry })
        $r.ExitCode -eq 0 -and $codexRows.Count -eq $rawEntries.Count -and @($claudeRows | Where-Object { $null -ne $_.PSObject.Properties['entry'] }).Count -eq 0 -and
        ($entries -join ',') -ceq ($rawEntries -join ',')
    }
    Test-Case EN05 {
        $missing = New-RegistryCopy 'entry-missing' { param($r) [void](Get-ExecutorNode $r 'codex-review').PSObject.Properties.Remove('entry') }
        Assert-Rejected -ArgumentText '-Type review -ImplementerFamily claude' -Code 'SelectorRegistryInvalid' -ExpectedExit 3 -Registry $missing
    }
    Test-Case EN06 {
        $traversal = New-RegistryCopy 'entry-traversal' { param($r) (Get-ExecutorNode $r 'codex-review').entry = '../x.ps1' }
        $spaced = New-RegistryCopy 'entry-space' { param($r) (Get-ExecutorNode $r 'codex-review').entry = 'scripts/a b.ps1' }
        $nested = New-RegistryCopy 'entry-nested' { param($r) (Get-ExecutorNode $r 'codex-review').entry = 'scripts/sub/x.ps1' }
        $notScript = New-RegistryCopy 'entry-ext' { param($r) (Get-ExecutorNode $r 'codex-review').entry = 'scripts/Invoke-CodexRun.cmd' }
        (Assert-Rejected -ArgumentText '-Type review -ImplementerFamily claude' -Code 'SelectorRegistryInvalid' -ExpectedExit 3 -Registry $traversal) -and
        (Assert-Rejected -ArgumentText '-Type review -ImplementerFamily claude' -Code 'SelectorRegistryInvalid' -ExpectedExit 3 -Registry $spaced) -and
        (Assert-Rejected -ArgumentText '-Type review -ImplementerFamily claude' -Code 'SelectorRegistryInvalid' -ExpectedExit 3 -Registry $nested) -and
        (Assert-Rejected -ArgumentText '-Type review -ImplementerFamily claude' -Code 'SelectorRegistryInvalid' -ExpectedExit 3 -Registry $notScript)
    }
    Test-Case EN07 {
        $claudeEntry = New-RegistryCopy 'entry-claude' { param($r) (Get-ExecutorNode $r 'sonnet') | Add-Member -NotePropertyName entry -NotePropertyValue 'scripts/Invoke-CodexRun.ps1' }
        Assert-Rejected -ArgumentText '-Type survey' -Code 'SelectorRegistryInvalid' -ExpectedExit 3 -Registry $claudeEntry
    }
    Test-Case EN08 {
        $switchedBack = New-RegistryCopy 'entry-switch-back' { param($r) (Get-ExecutorNode $r 'codex-review').entry = 'scripts/Invoke-Other.ps1' }
        $r = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude') -Registry $switchedBack
        $r.ExitCode -eq 0 -and $r.Json.executor.id -ceq 'codex-review' -and $r.Json.executor.entry -ceq 'scripts/Invoke-Other.ps1' -and $r.Json.dispatchLine -ceq '[派工] 交給 Codex review：審查'
    }
    # 結束碼與 stderr 格式彙整
    Test-Case Z01 {
        $codes = @{}
        $codes[0] = (Invoke-Fixture '-Type look' $fixture).ExitCode
        $codes[10] = (Invoke-Fixture '-Type look -Incomplete charlie:3,delta:3' $fixture).ExitCode
        $codes[20] = (Invoke-Fixture '-Type ask -ImplementerFamily claude' $fixture).ExitCode
        $codes[22] = (Invoke-Fixture '-Type look -Offline charlie,delta' $fixture).ExitCode
        $codes[2] = (Invoke-Fixture '-Type nope' $fixture).ExitCode
        $codes[3] = (Invoke-Selector -Arguments (Split-Args '-Type look') -Registry (Join-Path $tempRoot 'absent.json')).ExitCode
        @(@(0, 10, 20, 22, 2, 3) | Where-Object { $codes[$_] -ne $_ }).Count -eq 0
    }
}
catch {
    $failed++
    Write-Output "FAIL setup $($_.Exception.Message)"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
Write-Output "PASSED: $passed"
Write-Output "FAILED: $failed"
if ($failed -gt 0) { exit 1 }
exit 0
