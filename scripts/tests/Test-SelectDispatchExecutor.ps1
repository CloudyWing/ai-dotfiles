#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\Select-DispatchExecutor.ps1')).Path
$registryPath = (Resolve-Path (Join-Path $PSScriptRoot '..\dispatch\executor-registry.json')).Path
$libraryPath = (Resolve-Path (Join-Path $PSScriptRoot '..\lib\executor-registry.ps1')).Path
$evidencePath = (Resolve-Path (Join-Path $PSScriptRoot '..\dispatch\dispatch-evidence.ps1')).Path
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
        $text -notmatch 'CodexProfileNames' -and $text -notmatch "'review', 'scan', 'content', 'advisor'"
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
        (@($edit.requiredFlags) -join ',') -eq 'E,T' -and (@($review.requiredFlags) -join ',') -eq '' -and $review.crossFamily -eq $true -and (@($review.degradable) -join ',') -eq 'family'
    }
    Test-Case D04 {
        $advise = @($describe.Json.types | Where-Object { $_.name -eq 'advise' })[0]
        $advise.crossFamily -eq $true -and (@($advise.degradable) -join ',') -eq 'family'
    }
    Test-Case D05 {
        $content = @($describe.Json.executors | Where-Object { $_.id -eq 'codex-content' })[0]
        $scan = @($describe.Json.executors | Where-Object { $_.id -eq 'codex-scan' })[0]
        $deep = @($describe.Json.executors | Where-Object { $_.id -eq 'codex-deep-review' })
        $null -ne $content -and (@($content.accepts) -join ',') -eq 'generate,factcheck' -and (@($content.tags) -join ',') -eq 'web,image-gen' -and $deep.Count -eq 0 -and (@($scan.accepts) -join ',') -eq 'test'
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

    # 每類任務的選派
    Test-Case P01 { Assert-Selected '-Type edit -E true -T false' 'haiku' }
    Test-Case P02 { Assert-Selected '-Type edit -E true -T true' 'sonnet' }
    Test-Case P03 { Assert-Selected '-Type edit -E false -T false' 'sonnet' }
    Test-Case P04 { Assert-Selected '-Type edit -E false -T true' 'sonnet' }
    Test-Case P05 { Assert-Selected '-Type edit -E true -T false -Tags build-test' 'haiku' }
    Test-Case P06 { Assert-Selected '-Type survey' 'sonnet' }
    Test-Case P07 { Assert-Selected '-Type test' 'codex-scan' }
    Test-Case P08 { Assert-Selected '-Type test -Tags browse' 'codex-scan' }
    Test-Case P09 { Assert-Selected '-Type test -Tags desktop-control' 'codex-scan' }
    Test-Case P10 { Assert-Selected '-Type generate' 'codex-content' }
    Test-Case P11 { Assert-Selected '-Type factcheck' 'codex-content' }
    Test-Case P12 { Assert-Selected '-Type review -ImplementerFamily claude' 'codex-review' }
    Test-Case P14 { Assert-Selected '-Type advise -ImplementerFamily claude' 'codex-advisor' 'needs-authorization' 20 }
    Test-Case P15 { Assert-Selected '-Type advise -Authorized -ImplementerFamily claude' 'codex-advisor' }
    Test-Case P16 { Assert-Selected '-Type review -ImplementerFamily codex' 'sonnet' }
    Test-Case P17 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type generate')
        (@($r.Json.labels.tags) -join ',') -eq 'image-gen' -and $r.Json.executor.profile -eq 'content' -and $r.Json.executor.platform -eq 'codex' -and $null -eq $r.Json.executor.PSObject.Properties['model']
    }
    Test-Case P18 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type edit -E true -T false')
        $r.Json.executor.model -eq 'haiku' -and $r.Json.executor.platform -eq 'claude' -and $null -eq $r.Json.executor.PSObject.Properties['profile'] -and $r.Json.requiresUserDecision -eq $false
    }
    Test-Case P19 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type test -Tags browse,desktop-control')
        $r.ExitCode -eq 0 -and $r.Json.executor.id -eq 'codex-scan' -and (@($r.Json.labels.tags) -join ',') -eq 'browse,desktop-control'
    }
    Test-Case P20 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type test -Tags web')
        $r.ExitCode -eq 0 -and $r.Json.executor.id -eq 'codex-scan' -and @($r.Json.considered | Where-Object { $_.id -eq 'sonnet' })[0].reason -eq 'eligible-lower-priority'
    }

    Test-Case P21 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type advise -ImplementerFamily claude -Offline codex-advisor')
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'degraded' -and $r.Json.executor.id -eq 'sonnet' -and @($r.Json.degradations) -contains '同家族審查' -and $r.Json.dispatchLine.Contains('降級=同家族審查')
    }
    Test-Case P22 {
        $r = Invoke-Selector -Arguments ((Split-Args '-Type test') + @('-Offline', 'codex-scan,codex-content,codex-review,codex-advisor'))
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -eq 'sonnet'
    }
    Test-Case P23 {
        $r = Invoke-Selector -Arguments ((Split-Args '-Type test -Tags build-test') + @('-Offline', 'codex-scan,codex-content,codex-review,codex-advisor'))
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -eq 'sonnet'
    }

    Test-Case P24 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type generate')
        $r.ExitCode -eq 0 -and $r.Json.executor.id -eq 'codex-content' -and $r.Json.executor.profile -eq 'content'
    }
    Test-Case P25 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type factcheck')
        $r.ExitCode -eq 0 -and $r.Json.executor.id -eq 'codex-content' -and $r.Json.executor.profile -eq 'content'
    }
    Test-Case P26 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type test')
        $r.ExitCode -eq 0 -and $r.Json.executor.id -eq 'codex-scan' -and @($r.Json.considered | Where-Object { $_.id -eq 'codex-content' })[0].reason -eq 'type-not-accepted'
    }
    Test-Case P27 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type test -Tags image-gen')
        $r.ExitCode -eq 22 -and $r.Json.reason -eq 'no-eligible-executor'
    }
    Test-Case P28 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude')
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -eq 'codex-review' -and @($r.Json.considered).Count -eq @($registryRaw.executors).Count -and @($r.Json.considered | Where-Object { $_.id -eq 'codex-deep-review' }).Count -eq 0
    }

    # opus 在一般選擇中永不被選
    $opusCases = @(
        '-Type edit -E true -T false', '-Type edit -E true -T true', '-Type edit -E false -T false', '-Type edit -E false -T true',
        '-Type survey', '-Type test', '-Type generate', '-Type factcheck',
        '-Type review -ImplementerFamily claude', '-Type review -ImplementerFamily codex', '-Type advise -Authorized -ImplementerFamily claude'
    )
    Test-Case O01 {
        foreach ($case in $opusCases) {
            $r = Invoke-Selector -Arguments (Split-Args $case)
            if ($r.Json.executor -and $r.Json.executor.id -eq 'opus') { throw "opus 被選：$case" }
            if (@($r.Json.considered | Where-Object { $_.id -eq 'opus' })[0].reason -ne 'escalation-only') { throw "opus 排除原因不是 escalation-only：$case" }
        }
        $true
    }
    Test-Case O02 {
        foreach ($case in @('-Type edit -E false -T true', '-Type survey', '-Type factcheck', '-Type review -ImplementerFamily claude')) {
            $r = Invoke-Selector -Arguments ((Split-Args $case) + @('-Offline', 'haiku,codex-scan,codex-content,codex-review,codex-advisor,sonnet'))
            if ($r.ExitCode -ne 22 -or $r.Json.status -ne 'stopped' -or $null -ne $r.Json.executor) { throw "離線後仍有執行者：$case" }
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
    Test-Case V16 { Assert-Rejected '-Type survey -EscalateFrom ghost' 'SelectorExecutorUnknown' }
    Test-Case V17 { Assert-Rejected '-Type edit -E true -T false -Offline sonnet,ghost' 'SelectorExecutorUnknown' }
    Test-Case V18 { Assert-Rejected '-Type generate -Tags write' 'SelectorTagNotAllowed' }

    Test-Case V19 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type test -Offline codex-scan codex-review')
        $r.ExitCode -eq 2 -and $r.StdErr.StartsWith('SelectorParameterBinding') -and $r.StdErr.Contains('-Offline codex-scan,codex-review') -and $r.StdErr -notmatch 'SelectorFlagNotAllowed' -and $r.StdErr -notmatch '旗標 E' -and [string]::IsNullOrWhiteSpace($r.StdOut)
    }
    Test-Case V20 { Assert-Rejected '-Type advise' 'SelectorFamilyRequired' }
    Test-Case V21 {
        # 逗號連接的多值仍正常綁定，多個 -Tags 位置參數同樣回報參數綁定錯誤。
        $ok = Invoke-Selector -Arguments (Split-Args '-Type test -Tags browse,desktop-control')
        $bad = Invoke-Selector -Arguments (Split-Args '-Type test -Tags browse desktop-control')
        $ok.ExitCode -eq 0 -and $bad.ExitCode -eq 2 -and $bad.StdErr.StartsWith('SelectorParameterBinding')
    }

    Test-Case V22 { Assert-Rejected '-Type review -Deep true -ImplementerFamily claude' 'SelectorFlagRemoved' }
    Test-Case V23 { Assert-Rejected '-Type review -Deep false -ImplementerFamily claude' 'SelectorFlagRemoved' }
    Test-Case V24 { Assert-Rejected '-Type edit -E true -T false -Deep true' 'SelectorFlagRemoved' }

    # 離線改派
    Test-Case F01 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude -Offline codex-review')
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'degraded' -and $r.Json.executor.id -eq 'sonnet' -and @($r.Json.degradations) -contains '同家族審查'
    }
    Test-Case F03 {
        foreach ($case in @('-Type test -Tags browse', '-Type test -Tags desktop-control')) {
            $r = Invoke-Selector -Arguments ((Split-Args $case) + @('-Offline', 'codex-scan'))
            if ($r.ExitCode -ne 22 -or $r.Json.status -ne 'stopped' -or $r.Json.reason -ne 'offline' -or $null -ne $r.Json.executor) { throw "未停止：$case" }
        }
        $generate = Invoke-Selector -Arguments ((Split-Args '-Type generate') + @('-Offline', 'codex-content'))
        if ($generate.ExitCode -ne 22 -or $generate.Json.status -ne 'stopped' -or $generate.Json.reason -ne 'offline' -or $null -ne $generate.Json.executor) { throw '-Type generate 離線未停止' }
        $true
    }
    Test-Case F04 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type factcheck -Offline codex-content')
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -eq 'sonnet' -and @($r.Json.degradations).Count -eq 0
    }
    Test-Case F05 {
        foreach ($case in @('-Type advise -ImplementerFamily claude', '-Type advise -Authorized -ImplementerFamily claude')) {
            $r = Invoke-Selector -Arguments ((Split-Args $case) + @('-Offline', 'codex-advisor'))
            if ($r.ExitCode -ne 0 -or $r.Json.status -ne 'degraded' -or $r.Json.executor.id -ne 'sonnet' -or @($r.Json.degradations) -notcontains '同家族審查') { throw "非降級為 Sonnet：$case" }
        }
        $true
    }
    $allCodex = 'codex-scan,codex-content,codex-review,codex-advisor'
    Test-Case F06 {
        $test = Invoke-Selector -Arguments ((Split-Args '-Type test -Tags browse') + @('-Offline', $allCodex))
        $generate = Invoke-Selector -Arguments ((Split-Args '-Type generate') + @('-Offline', $allCodex))
        $factcheck = Invoke-Selector -Arguments ((Split-Args '-Type factcheck') + @('-Offline', $allCodex))
        $review = Invoke-Selector -Arguments ((Split-Args '-Type review -ImplementerFamily claude') + @('-Offline', $allCodex))
        $advise = Invoke-Selector -Arguments ((Split-Args '-Type advise -ImplementerFamily claude') + @('-Offline', $allCodex))
        $test.ExitCode -eq 22 -and $test.Json.status -eq 'stopped' -and
        $generate.ExitCode -eq 22 -and $generate.Json.status -eq 'stopped' -and
        $factcheck.ExitCode -eq 0 -and $factcheck.Json.executor.id -eq 'sonnet' -and @($factcheck.Json.degradations).Count -eq 0 -and
        $review.ExitCode -eq 0 -and $review.Json.status -eq 'degraded' -and $review.Json.executor.id -eq 'sonnet' -and
        $advise.ExitCode -eq 0 -and $advise.Json.status -eq 'degraded' -and $advise.Json.executor.id -eq 'sonnet' -and @($advise.Json.degradations) -contains '同家族審查'
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
        $r = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude -Offline codex-review,sonnet')
        $r.ExitCode -eq 22 -and $r.Json.status -eq 'stopped' -and $r.Json.reason -eq 'offline'
    }
    Test-Case F10 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude -Offline codex-review')
        $reasons = @{}
        foreach ($row in $r.Json.considered) { $reasons[$row.id] = $row.reason }
        $reasons['codex-review'] -eq 'offline' -and $reasons['sonnet'] -eq 'degraded' -and $reasons['codex-content'] -eq 'type-not-accepted'
    }

    Test-Case F11 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type factcheck -Offline codex-scan')
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -eq 'codex-content'
    }
    Test-Case F12 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type generate -Offline codex-scan')
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -eq 'codex-content'
    }

    # 升級路徑
    Test-Case E01 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type edit -E true -T false -EscalateFrom haiku')
        $r.ExitCode -eq 10 -and $r.Json.status -eq 'escalation-candidate' -and $r.Json.executor.id -eq 'sonnet' -and $r.Json.requiresUserDecision -eq $true
    }
    Test-Case E02 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type edit -E true -T false -EscalateFrom sonnet')
        $r.ExitCode -eq 10 -and $r.Json.executor.id -eq 'opus' -and $r.Json.requiresUserDecision -eq $true
    }
    Test-Case E03 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type edit -E true -T false -EscalateFrom opus')
        $r.ExitCode -eq 22 -and $r.Json.status -eq 'stopped' -and $r.Json.reason -eq 'no-escalation' -and $null -eq $r.Json.executor
    }
    Test-Case E04 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type edit -E true -T false -EscalateFrom haiku -Offline sonnet')
        $r.ExitCode -eq 10 -and $r.Json.executor.id -eq 'opus'
    }
    Test-Case E05 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type edit -E true -T false -EscalateFrom haiku -Offline sonnet,opus')
        $r.ExitCode -eq 22 -and $r.Json.reason -eq 'no-escalation'
    }
    Test-Case E06 {
        $scan = Invoke-Selector -Arguments (Split-Args '-Type test -EscalateFrom codex-scan')
        $review = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude -EscalateFrom codex-review')
        $scan.ExitCode -eq 22 -and $scan.Json.reason -eq 'no-escalation' -and $review.ExitCode -eq 22 -and $review.Json.reason -eq 'no-escalation'
    }
    Test-Case E07 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type survey -EscalateFrom sonnet')
        $r.ExitCode -eq 10 -and $r.Json.executor.id -eq 'opus'
    }
    Test-Case E08 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type test -EscalateFrom haiku')
        $r.ExitCode -eq 10 -and $r.Json.status -eq 'escalation-candidate' -and $r.Json.executor.id -eq 'sonnet'
    }
    Test-Case E09 {
        $same = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude -EscalateFrom sonnet')
        $same.ExitCode -eq 10 -and $same.Json.status -eq 'escalation-candidate' -and $same.Json.executor.id -eq 'opus' -and $same.Json.requiresUserDecision -eq $true -and
        @($same.Json.degradations) -contains '同家族審查' -and $same.Json.dispatchLine.Contains('降級=同家族審查')
    }
    Test-Case E10 {
        $cross = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily codex -EscalateFrom sonnet')
        $edit = Invoke-Selector -Arguments (Split-Args '-Type edit -E true -T false -EscalateFrom sonnet')
        $cross.ExitCode -eq 10 -and $cross.Json.executor.id -eq 'opus' -and @($cross.Json.degradations).Count -eq 0 -and -not $cross.Json.dispatchLine.Contains('降級') -and
        $edit.ExitCode -eq 10 -and $edit.Json.executor.id -eq 'opus' -and @($edit.Json.degradations).Count -eq 0
    }

    # 登錄表驗證失敗（暫存複本）
    Test-Case R01 {
        $path = New-RegistryCopy 'dup-id' { param($r) $r.executors[1].id = 'haiku'; $r.executors[0].escalatesTo = $null }
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
    Test-Case R04 {
        $path = New-RegistryCopy 'cycle' { param($r) (Get-ExecutorNode $r 'opus').escalatesTo = 'haiku' }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R05 {
        $path = New-RegistryCopy 'offline-keys' { param($r) $node = Get-ExecutorNode $r 'codex-content'; $node.onOffline = [pscustomobject]@{ generate = 'stop' } }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R06 {
        $retired = [string]@($registryRaw.retiredProfiles)[0]
        $path = New-RegistryCopy 'profile-retired' { param($r) (Get-ExecutorNode $r 'codex-scan').profile = $retired }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R07 {
        # 退役名單完全由登錄表的 retiredProfiles 決定：改名單後，原名單內的名稱可用，新名單內的名稱被拒絕。
        $path = New-RegistryCopy 'retired-custom' { param($r) $r.retiredProfiles = @('zzz-retired'); (Get-ExecutorNode $r 'codex-scan').profile = 'zzz-retired' }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
        $path2 = New-RegistryCopy 'retired-custom-ok' { param($r) $r.retiredProfiles = @('zzz-retired'); (Get-ExecutorNode $r 'codex-scan').profile = 'implement' }
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
    Test-Case R13 {
        $path = New-RegistryCopy 'fallback-no-peer' { param($r) (Get-ExecutorNode $r 'codex-content').onOffline.generate = 'fallback' }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R14 {
        $path = New-RegistryCopy 'degrade-no-degradable' { param($r) (Get-ExecutorNode $r 'codex-content').onOffline.factcheck = 'degrade' }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R15 {
        $path = New-RegistryCopy 'unknown-type' { param($r) (Get-ExecutorNode $r 'sonnet').accepts = @('edit', 'survey', 'review', 'factcheck', 'dream') }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R16 {
        $path = New-RegistryCopy 'when-flag' { param($r) (Get-ExecutorNode $r 'codex-scan').when = [pscustomobject]@{ Deep = $true } }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R17 {
        $path = New-RegistryCopy 'dangling-escalation' { param($r) (Get-ExecutorNode $r 'haiku').escalatesTo = 'nobody' }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R18 {
        $path = New-RegistryCopy 'self-cycle' { param($r) (Get-ExecutorNode $r 'sonnet').escalatesTo = 'sonnet' }
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
        $path = New-RegistryCopy 'no-effort' { param($r) (Get-ExecutorNode $r 'codex-scan').profileSettings.PSObject.Properties.Remove('effort') }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R19C {
        $path = New-RegistryCopy 'bad-model-value' { param($r) (Get-ExecutorNode $r 'codex-review').profileSettings.model = 'x"; [evil]' }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R19D {
        $path = New-RegistryCopy 'duplicate-profile' { param($r) (Get-ExecutorNode $r 'codex-content').profile = 'review' }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R19E {
        # 新增檔位只改登錄表即可通過驗證（不再有腳本內白名單）。
        $path = New-RegistryCopy 'new-profile' { param($r) (Get-ExecutorNode $r 'codex-content').profile = 'content-2' }
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

    # 決定性
    Test-Case X01 {
        foreach ($case in @('-Type edit -E true -T false -Label 範例', '-Type review -ImplementerFamily claude -Offline codex-review', '-Type advise -ImplementerFamily claude', '-Type test -Tags browse -Offline codex-scan', '-Type edit -E true -T false -EscalateFrom haiku')) {
            $first = Invoke-Selector -Arguments (Split-Args $case)
            $second = Invoke-Selector -Arguments (Split-Args $case)
            if ($first.StdOut -cne $second.StdOut -or $first.ExitCode -ne $second.ExitCode) { throw "輸出不一致：$case" }
        }
        $a = Invoke-Selector -Arguments @('-Describe')
        $b = Invoke-Selector -Arguments @('-Describe')
        $a.StdOut -ceq $b.StdOut
    }
    Test-Case X02 {
        $a = Invoke-Selector -Arguments (Split-Args '-Type survey -Offline codex-scan,codex-review')
        $b = Invoke-Selector -Arguments (Split-Args '-Type survey -Offline codex-review,codex-scan')
        $a.StdOut -ceq $b.StdOut -or ($a.Json.executor.id -eq $b.Json.executor.id -and $a.ExitCode -eq $b.ExitCode)
    }
    Test-Case X03 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type survey')
        $r.StdOut -notmatch '[^\u0000-\u007F]' -and $r.Json.schema -eq 'ai-agents.executor-selection.v1' -and @($r.Json.considered).Count -eq @($registryRaw.executors).Count
    }

    # dispatchLine 格式
    Test-Case L01 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type edit -E true -T false')
        $r.Json.dispatchLine -ceq '[派工判定: 登錄表→haiku] type=edit E=是 T=否 執行者=Haiku subagent'
    }
    Test-Case L02 {
        $r = Invoke-Selector -Arguments @('-Type', 'edit', '-E', 'false', '-T', 'true', '-Label', 'P3 重構')
        $r.Json.dispatchLine -ceq '[派工判定: 登錄表→sonnet] P3 重構 type=edit E=否 T=是 執行者=Sonnet subagent'
    }
    Test-Case L03 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude')
        $r.Json.dispatchLine -ceq '[派工判定: 登錄表→codex-review] type=review 執行者=Codex review' -and $r.Json.dispatchLine -notmatch ' E=| T='
    }
    Test-Case L04 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude -Offline codex-review')
        $r.Json.dispatchLine -ceq '[派工判定: 登錄表→sonnet] type=review 執行者=Sonnet subagent 降級=同家族審查'
    }
    Test-Case L05 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type advise -ImplementerFamily claude')
        $r.Json.dispatchLine -ceq '[派工判定: 登錄表→待授權] type=advise 執行者=Codex advisor'
    }
    Test-Case L06 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type advise -ImplementerFamily claude -Offline codex-advisor')
        $r.Json.dispatchLine -ceq '[派工判定: 登錄表→sonnet] type=advise 執行者=Sonnet subagent 降級=同家族審查'
    }
    Test-Case L07 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type generate -Offline codex-content')
        $r.Json.dispatchLine -ceq '[派工判定: 登錄表→停止] type=generate 執行者=無'
    }
    Test-Case L08 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type edit -E true -T false -EscalateFrom haiku')
        $r.Json.dispatchLine -ceq '[派工判定: 登錄表→升級候選 sonnet] type=edit E=是 T=否 執行者=Sonnet subagent'
    }
    Test-Case L09 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type test')
        $r.Json.dispatchLine -ceq '[派工判定: 登錄表→codex-scan] type=test 執行者=Codex scan'
    }

    Test-Case L10 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type generate')
        $r.Json.dispatchLine -ceq '[派工判定: 登錄表→codex-content] type=generate 執行者=Codex content'
    }
    Test-Case L11 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type factcheck')
        $r.Json.dispatchLine -ceq '[派工判定: 登錄表→codex-content] type=factcheck 執行者=Codex content'
    }

    # 登錄表 entry 欄位（審查類切到新入口，其餘 Codex 類維持現行入口）
    Test-Case EN01 {
        $r = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude')
        $r.ExitCode -eq 0 -and $r.Json.executor.id -ceq 'codex-review' -and $r.Json.executor.entry -ceq 'scripts/Invoke-CodexRun.ps1' -and $r.Json.executor.profile -ceq 'review'
    }
    Test-Case EN02 {
        $cases = @(
            @('-Type test', 'codex-scan'), @('-Type generate', 'codex-content'), @('-Type factcheck', 'codex-content'),
            @('-Type advise -ImplementerFamily claude -Authorized', 'codex-advisor'))
        @($cases | Where-Object {
                $r = Invoke-Selector -Arguments (Split-Args $_[0])
                -not ($r.ExitCode -eq 0 -and $r.Json.executor.id -ceq $_[1] -and $r.Json.executor.entry -ceq 'scripts/Invoke-CodexDispatch.ps1')
            }).Count -eq 0
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
        $switchedBack = New-RegistryCopy 'entry-switch-back' { param($r) (Get-ExecutorNode $r 'codex-review').entry = 'scripts/Invoke-CodexDispatch.ps1' }
        $r = Invoke-Selector -Arguments (Split-Args '-Type review -ImplementerFamily claude') -Registry $switchedBack
        $r.ExitCode -eq 0 -and $r.Json.executor.id -ceq 'codex-review' -and $r.Json.executor.entry -ceq 'scripts/Invoke-CodexDispatch.ps1' -and $r.Json.dispatchLine -ceq '[派工判定: 登錄表→codex-review] type=review 執行者=Codex review'
    }
    # EN09 的對照基準：登錄表首次出現 entry 欄位之前的最後一個 commit（登錄表的 entry 變更尚未 commit 時為 HEAD）。
    # 找不到基準或 git 不可用時，該案例標示為不適用並說明原因，不計入通過或失敗的斷言數。
    function Get-EntryBaseline {
        param([string]$Repository)

        try {
            $registryRelative = 'scripts/dispatch/executor-registry.json'
            $headText = (& git -C $Repository show ('HEAD:' + $registryRelative) 2>$null) -join "`n"
            if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Commit = $null; Reason = '無法讀取 HEAD 的登錄表。' } }
            if ($headText -notmatch '"entry"') {
                $head = @(& git -C $Repository rev-parse HEAD 2>$null)
                if ($LASTEXITCODE -ne 0 -or $head.Count -eq 0) { return [pscustomobject]@{ Commit = $null; Reason = '無法取得 HEAD。' } }
                return [pscustomobject]@{ Commit = ([string]$head[0]).Trim(); Reason = $null }
            }
            $introduced = @(& git -C $Repository log '-S"entry"' --diff-filter=M --format=%H --reverse -- $registryRelative 2>$null)
            if ($LASTEXITCODE -ne 0 -or $introduced.Count -eq 0) { return [pscustomobject]@{ Commit = $null; Reason = '歷史中找不到登錄表首次出現 entry 欄位的 commit。' } }
            $parent = @(& git -C $Repository rev-parse (([string]$introduced[0]).Trim() + '^') 2>$null)
            if ($LASTEXITCODE -ne 0 -or $parent.Count -eq 0) { return [pscustomobject]@{ Commit = $null; Reason = '首次出現 entry 的 commit 沒有父 commit。' } }
            return [pscustomobject]@{ Commit = ([string]$parent[0]).Trim(); Reason = $null }
        }
        catch {
            return [pscustomobject]@{ Commit = $null; Reason = ('git 不可用：' + $_.Exception.Message) }
        }
    }
    $entryBaseline = Get-EntryBaseline -Repository (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    if ($null -eq $entryBaseline.Commit) { Write-Output ('N/A EN09 不適用：' + $entryBaseline.Reason) }
    else {
        Test-Case EN09 {
            # 與新增 entry 之前的輸出對照：新舊輸出都移除 entry 與 profileSettings 後逐字相同。基準 commit 見上方 Get-EntryBaseline。
            $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $baselineCommit = $entryBaseline.Commit
            $oldRoot = Join-Path $tempRoot 'baseline'
            $null = New-Item -ItemType Directory -Path (Join-Path $oldRoot 'dispatch') -Force
            $oldScript = Join-Path $oldRoot 'Select-DispatchExecutor.ps1'
            $oldRegistry = Join-Path $oldRoot 'dispatch\executor-registry.json'
            Save-GitBlob -Repository $repoRoot -Spec ($baselineCommit + ':scripts/Select-DispatchExecutor.ps1') -Destination $oldScript
            Save-GitBlob -Repository $repoRoot -Spec ($baselineCommit + ':scripts/dispatch/executor-registry.json') -Destination $oldRegistry
            # 新入口用的登錄表是基準登錄表補上新欄位（entry、profileSettings、codexEfforts、retiredProfiles）的版本，
            # 兩邊資料相同，結果不受出貨登錄表增減執行者或檔位影響。
            $augmented = Get-Content -LiteralPath $oldRegistry -Raw -Encoding UTF8 | ConvertFrom-Json
            $augmented | Add-Member -NotePropertyName codexEfforts -NotePropertyValue @('low', 'medium', 'high', 'max')
            $augmented | Add-Member -NotePropertyName retiredProfiles -NotePropertyValue @()
            foreach ($row in @($augmented.executors | Where-Object { $_.platform -ceq 'codex' })) {
                $row | Add-Member -NotePropertyName entry -NotePropertyValue 'scripts/Invoke-CodexDispatch.ps1'
                $row | Add-Member -NotePropertyName profileSettings -NotePropertyValue ([pscustomobject]@{ model = 'm'; effort = 'low'; subagentModel = 's'; subagentEffort = 'low' })
            }
            $augmentedPath = Join-Path $oldRoot 'augmented-registry.json'
            [IO.File]::WriteAllText($augmentedPath, ($augmented | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
            $specs = @('-Type review -ImplementerFamily claude', '-Type test', '-Type generate', '-Type factcheck', '-Type advise -ImplementerFamily claude -Authorized', '-Type survey', '-Type edit -E true -T false', '-Describe', '-Type review -ImplementerFamily claude -Offline codex-review')
            $mismatch = @()
            foreach ($spec in $specs) {
                $specArguments = @(Split-Args $spec)
                $oldText = (& $hostPath -NoProfile -NonInteractive -File $oldScript @specArguments -RegistryPath $oldRegistry 2>$null) -join "`n"
                $new = (Invoke-Selector -Arguments (Split-Args $spec) -Registry $augmentedPath).Json
                $old = $oldText | ConvertFrom-Json
                foreach ($document in @($old, $new)) {
                    if ($null -ne $document.PSObject.Properties['executor'] -and $null -ne $document.executor) { [void]$document.executor.PSObject.Properties.Remove('entry') }
                    if ($null -ne $document.PSObject.Properties['executors']) { foreach ($row in @($document.executors)) { [void]$row.PSObject.Properties.Remove('entry'); [void]$row.PSObject.Properties.Remove('profileSettings') } }
                }
                if (($old | ConvertTo-Json -Depth 10 -Compress) -cne ($new | ConvertTo-Json -Depth 10 -Compress)) { $mismatch += $spec }
            }
            if ($mismatch.Count -gt 0) { throw ('與基準輸出不同：' + ($mismatch -join '; ')) }
            $true
        }
    }

    # 結束碼與 stderr 格式彙整
    Test-Case Z01 {
        $codes = @{}
        $codes[0] = (Invoke-Selector -Arguments (Split-Args '-Type survey')).ExitCode
        $codes[10] = (Invoke-Selector -Arguments (Split-Args '-Type survey -EscalateFrom sonnet')).ExitCode
        $codes[20] = (Invoke-Selector -Arguments (Split-Args '-Type advise -ImplementerFamily claude')).ExitCode
        # 出貨登錄表的 advise 離線為 degrade，exit 21 以 Sonnet 不受理 advise 且 codex-advisor 設為 wait-reset 的暫存複本取得。
        $waitResetRegistry = New-RegistryCopy 'wait-reset' { param($r) (Get-ExecutorNode $r 'sonnet').accepts = @('edit', 'survey', 'review', 'factcheck', 'test'); (Get-ExecutorNode $r 'codex-advisor').onOffline.advise = 'wait-reset' }
        $codes[21] = (Invoke-Selector -Arguments (Split-Args '-Type advise -ImplementerFamily claude -Offline codex-advisor') -Registry $waitResetRegistry).ExitCode
        $codes[22] = (Invoke-Selector -Arguments (Split-Args '-Type generate -Offline codex-content')).ExitCode
        $codes[2] = (Invoke-Selector -Arguments (Split-Args '-Type nope')).ExitCode
        $codes[3] = (Invoke-Selector -Arguments (Split-Args '-Type survey') -Registry (Join-Path $tempRoot 'absent.json')).ExitCode
        @(@(0, 10, 20, 21, 22, 2, 3) | Where-Object { $codes[$_] -ne $_ }).Count -eq 0
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
