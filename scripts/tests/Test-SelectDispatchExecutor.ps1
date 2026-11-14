#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\Select-DispatchExecutor.ps1')).Path
$registryPath = (Resolve-Path (Join-Path $PSScriptRoot '..\dispatch\executor-registry.json')).Path
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
    param([string[]]$Arguments = @(), [string]$Registry)

    $all = @('-NoProfile', '-NonInteractive', '-File', $scriptPath) + $Arguments
    if (-not [string]::IsNullOrWhiteSpace($Registry)) { $all += @('-RegistryPath', $Registry) }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $hostPath
    $startInfo.Arguments = ($all | ForEach-Object { ConvertTo-QuotedArgument -Value $_ }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
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
    Test-Case S01 {
        $bytes = [IO.File]::ReadAllBytes($scriptPath)
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191 -and $errors.Count -eq 0
    }
    Test-Case S02 { $text -match '(?m)^#Requires -Version 7\.0' -and $text -match '(?m)^Set-StrictMode -Version Latest' }
    Test-Case S03 { $text -notmatch 'Set-Content|Add-Content|Out-File|New-Item|Remove-Item|Copy-Item|Move-Item|Rename-Item|Tee-Object|Export-|Invoke-WebRequest|Invoke-RestMethod|\$env:|GetEnvironmentVariable|WriteAllText|>>' }
    Test-Case S04 {
        $bytes = [IO.File]::ReadAllBytes($registryPath)
        $registryJson = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
        -not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) -and $registryJson.schema -eq 'ai-agents.executor-registry.v1'
    }
    Test-Case S05 {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($evidencePath, [ref]$tokens, [ref]$errors)
        $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CodexDispatchProfileNames' }, $true)
        Invoke-Expression $function.Extent.Text
        $names = @(Get-CodexDispatchProfileNames)
        $literal = [regex]::Match($text, "CodexProfileNames = @\(([^)]*)\)").Groups[1].Value -replace "'", '' -replace '\s', ''
        ($names -join ',') -ceq 'review,scan,content,advisor' -and $literal -ceq ($names -join ',')
    }

    # 出貨登錄表：詞彙與 -Describe
    $describe = Invoke-Selector -Arguments @('-Describe')
    Test-Case D01 {
        $d = $describe.Json
        $describe.ExitCode -eq 0 -and @($d.tags.hard).Count -eq 6 -and @($d.tags.constraint).Count -eq 2 -and (@($d.tags.hard).Count + @($d.tags.constraint).Count) -le 8 -and
        @($d.executors).Count -eq 7 -and @($d.types).Count -eq 7 -and (@($d.flags) -join ',') -eq 'E,T'
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
    Test-Case D03 {
        $profiles = @($describe.Json.executors | Where-Object { $_.platform -eq 'codex' } | ForEach-Object { $_.profile })
        ($profiles -join ',') -eq 'scan,review,content,advisor'
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
        $r.ExitCode -eq 0 -and $r.Json.status -eq 'selected' -and $r.Json.executor.id -eq 'codex-review' -and @($r.Json.considered).Count -eq 7 -and @($r.Json.considered | Where-Object { $_.id -eq 'codex-deep-review' }).Count -eq 0
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
        $path = New-RegistryCopy 'profile-implement' { param($r) (Get-ExecutorNode $r 'codex-scan').profile = 'implement' }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
    }
    Test-Case R07 {
        $path = New-RegistryCopy 'profile-intensive' { param($r) (Get-ExecutorNode $r 'codex-scan').profile = 'intensive' }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
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
        $path = New-RegistryCopy 'profile-deep-review' { param($r) (Get-ExecutorNode $r 'codex-review').profile = 'deep-review' }
        Assert-Rejected '-Type survey' 'SelectorRegistryInvalid' 3 $path
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
        $r.StdOut -notmatch '[^\u0000-\u007F]' -and $r.Json.schema -eq 'ai-agents.executor-selection.v1' -and @($r.Json.considered).Count -eq 7
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
