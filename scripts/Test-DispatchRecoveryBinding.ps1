#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet(1, 2, 3, 4, 5, 6, 7, 8)]
    [int]$Phase = 1,

    [switch]$Child,

    [AllowEmptyString()]
    [string]$ProbeDate,

    [AllowEmptyString()]
    [string]$ProbeEmpty,

    [AllowEmptyString()]
    [string]$ProbeWhitespace,

    [AllowEmptyString()]
    [string]$ProbeText
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$sourcePath = Join-Path $PSScriptRoot 'Invoke-CodexDispatch.ps1'
$activeSourcePaths = @(
    $sourcePath,
    (Join-Path $PSScriptRoot 'Setup-AIGlobalConfig.ps1'),
    (Join-Path $PSScriptRoot 'Get-CodexQuota.ps1'),
    (Join-Path $root 'instructions.md'),
    (Join-Path $root 'skills\codex-dispatch\SKILL.md'),
    (Join-Path $root 'README.md'),
    $PSCommandPath
)
$phase1RemovalTerms = @(
    ('[ValidateSet(' + "'default', 'deep'" + ')]'),
    ('d' + 'eep' + '-consult'),
    ('d' + 'eep' + '-evidence-pack'),
    ('d' + 'eep' + '_hard_limit_percent'),
    ('d' + 'eep' + '.config.toml'),
    ('Deep' + 'RequestSource'),
    ('Deep' + 'ConsultReportPath'),
    ('Get-' + 'Deep' + 'ConsultReportPath'),
    ('Get-' + 'Deep' + 'CycleDecision'),
    ('New-' + 'Deep' + 'InlineEvidenceDirective'),
    ('Test-' + 'Deep' + 'InlineEvidenceDirective'),
    ('Write-' + 'Deep' + 'ConsultReport'),
    ('Invoke-' + 'Deep' + 'BudgetMonitor'),
    ('Test-' + 'EvidencePack'),
    ('deep' + '-consult.evidence.v1'),
    ('[' + 'deep' + ' 諮詢確認]')
)
$phase2RemovalTerms = @(
    ('[ValidateSet(' + "'default', 'deep'" + ')]'),
    ('deep' + '-consult'),
    ('deep' + '-evidence-pack'),
    ('deep' + '_hard_limit_percent'),
    ('deep' + '.config.toml'),
    ('Deep' + 'RequestSource'),
    ('Deep' + 'ConsultReportPath'),
    ('deep' + 'RequestSource'),
    ('deep' + 'ConsultReportPath'),
    ('Get-' + 'Deep' + 'ConsultReportPath'),
    ('Get-' + 'Deep' + 'CycleDecision'),
    ('deep' + 'CycleDecision'),
    ('deep' + 'CycleGatePassed'),
    ('deep' + 'CycleNotice'),
    ('New-' + 'Deep' + 'InlineEvidenceDirective'),
    ('Test-' + 'Deep' + 'InlineEvidenceDirective'),
    ('Write-' + 'Deep' + 'ConsultReport'),
    ('Invoke-' + 'Deep' + 'BudgetMonitor'),
    ('Test-' + 'EvidencePack'),
    ('deep' + '-consult.evidence.v1'),
    ('[' + 'deep' + ' 諮詢確認]'),
    ('[' + 'deep' + ' 週期位置告知]')
)

function Assert-ActiveSourceNotFound {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [string[]]$Terms
    )

    foreach ($term in $Terms) {
        foreach ($path in $activeSourcePaths) {
            $matches = @(Select-String -LiteralPath $path -SimpleMatch -Pattern $term)
            Assert-True ($matches.Count -eq 0) ("{0} active source 仍找到 `{1}`：{2}" -f $Label, $term, $path)
        }
    }
}

function ConvertTo-ProcessArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    $builder = New-Object System.Text.StringBuilder
    $null = $builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]0x5c) {
            $backslashCount++
            continue
        }
        if ($character -eq [char]0x22) {
            if ($backslashCount -gt 0) {
                $null = $builder.Append(('\' * ($backslashCount * 2)))
            }
            $null = $builder.Append('\"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            $null = $builder.Append(('\' * $backslashCount))
            $backslashCount = 0
        }
        $null = $builder.Append($character)
    }
    if ($backslashCount -gt 0) {
        $null = $builder.Append(('\' * ($backslashCount * 2)))
    }
    $null = $builder.Append('"')
    return $builder.ToString()
}

function Invoke-TestChildProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HostPath,

        [Parameter(Mandatory)]
        [string]$HostLabel,

        [Parameter(Mandatory)]
        [int]$PhaseNumber,

        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$DateValue,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$EmptyValue,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$WhitespaceValue,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$TextValue
    )

    $arguments = @(
        '-NoProfile'
        '-File'
        $ScriptPath
        '-Phase'
        [string]$PhaseNumber
        '-Child'
        '-ProbeDate'
        $DateValue
        '-ProbeEmpty'
        $EmptyValue
        '-ProbeWhitespace'
        $WhitespaceValue
        '-ProbeText'
        $TextValue
    )
    $argumentText = ($arguments | ForEach-Object { ConvertTo-ProcessArgument -Value ([string]$_) }) -join ' '
    $commandText = $HostPath + ' ' + $argumentText
    $start = [DateTimeOffset]::UtcNow
    $process = New-Object System.Diagnostics.Process
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $HostPath
        $startInfo.Arguments = $argumentText
        $startInfo.WorkingDirectory = (Get-Location).Path
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        if ($HostLabel -eq 'powershell.exe') {
            $windowsPowerShellModulePaths = New-Object System.Collections.Generic.List[string]
            foreach ($modulePath in @(
                    (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Modules'),
                    (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
                    (Join-Path $env:WINDIR 'system32\WindowsPowerShell\v1.0\Modules'))) {
                if (-not [string]::IsNullOrWhiteSpace($modulePath)) {
                    $windowsPowerShellModulePaths.Add($modulePath)
                }
            }
            $startInfo.EnvironmentVariables['PSModulePath'] = $windowsPowerShellModulePaths -join ';'
        }
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $startInfo.StandardOutputEncoding = $utf8
        $startInfo.StandardErrorEncoding = $utf8
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw 'Process.Start() 回傳 false。'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = $process.ExitCode
        $finish = [DateTimeOffset]::UtcNow
        return [pscustomobject]@{
            label = $HostLabel
            host_path = $HostPath
            command = $commandText
            start_utc = $start.ToString('o')
            finish_utc = $finish.ToString('o')
            duration_ms = [math]::Round(($finish - $start).TotalMilliseconds, 3)
            exit_code = $exitCode
            stdout = $stdout
            stderr = $stderr
            launch_error = $null
        }
    }
    catch {
        $finish = [DateTimeOffset]::UtcNow
        return [pscustomobject]@{
            label = $HostLabel
            host_path = $HostPath
            command = $commandText
            start_utc = $start.ToString('o')
            finish_utc = $finish.ToString('o')
            duration_ms = [math]::Round(($finish - $start).TotalMilliseconds, 3)
            exit_code = 1
            stdout = ''
            stderr = ''
            launch_error = $_.Exception.Message
        }
    }
    finally {
        $process.Dispose()
    }
}

function Test-ChildSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$ChildResult,

        [Parameter(Mandatory)]
        [string]$ExpectedDate,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ExpectedEmpty,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ExpectedWhitespace,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ExpectedText
    )

    if (-not [string]::IsNullOrWhiteSpace($ChildResult.launch_error)) {
        return [pscustomobject]@{ valid = $false; reason = 'child launch failed: ' + $ChildResult.launch_error }
    }
    $summaryMatch = [regex]::Match($ChildResult.stdout, '(?m)^TOTAL:\s+(?<total>\d+);\s+FAILED:\s+(?<failed>\d+);')
    if (-not $summaryMatch.Success) {
        return [pscustomobject]@{ valid = $false; reason = 'child summary missing' }
    }
    $expectedProbeLines = @(
        'PROBE_DATE_ECHO: <' + $ExpectedDate + '>'
        'PROBE_EMPTY_ECHO: <' + $ExpectedEmpty + '>'
        'PROBE_WHITESPACE_ECHO: <' + $ExpectedWhitespace + '>'
        'PROBE_TEXT_ECHO: <' + $ExpectedText + '>'
    )
    foreach ($line in $expectedProbeLines) {
        if (-not $ChildResult.stdout.Contains($line)) {
            return [pscustomobject]@{ valid = $false; reason = 'probe mismatch: ' + $line }
        }
    }
    if ([int]$ChildResult.exit_code -ne 0 -or [int]$summaryMatch.Groups['failed'].Value -ne 0) {
        return [pscustomobject]@{ valid = $false; reason = 'child reported failure' }
    }
    return [pscustomobject]@{ valid = $true; reason = 'child passed ' + $summaryMatch.Groups['total'].Value + ' cases' }
}

if (-not $Child) {
    $probeDateValue = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
    $probeEmptyValue = ''
    $probeWhitespaceValue = '  '
    $probeTextValue = '  中文，逗號,$literal  '
    $scriptPathValue = [IO.Path]::GetFullPath($PSCommandPath)
    $hostDefinitions = @(
        [pscustomobject]@{ Label = 'powershell.exe'; Name = 'powershell.exe' }
        [pscustomobject]@{ Label = 'pwsh'; Name = 'pwsh' }
    )
    $aggregateResults = New-Object System.Collections.Generic.List[object]
    $aggregateFailed = $false
    Write-Output ('AGGREGATE: Phase ' + $Phase)
    foreach ($hostDefinition in $hostDefinitions) {
        $command = Get-Command -Name $hostDefinition.Name -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            $missing = [pscustomobject]@{
                label = $hostDefinition.Label
                host_path = $hostDefinition.Name
                command = '<missing host>'
                start_utc = [DateTimeOffset]::UtcNow.ToString('o')
                finish_utc = [DateTimeOffset]::UtcNow.ToString('o')
                duration_ms = 0
                exit_code = 1
                stdout = ''
                stderr = ''
                launch_error = '找不到執行環境。'
            }
            $aggregateResults.Add($missing)
            $aggregateFailed = $true
            continue
        }
        $hostPath = if (-not [string]::IsNullOrWhiteSpace($command.Source)) { $command.Source } else { $command.Path }
        $childResult = Invoke-TestChildProcess -HostPath $hostPath -HostLabel $hostDefinition.Label -PhaseNumber $Phase -ScriptPath $scriptPathValue -DateValue $probeDateValue -EmptyValue $probeEmptyValue -WhitespaceValue $probeWhitespaceValue -TextValue $probeTextValue
        $aggregateResults.Add($childResult)
        $summary = Test-ChildSummary -ChildResult $childResult -ExpectedDate $probeDateValue -ExpectedEmpty $probeEmptyValue -ExpectedWhitespace $probeWhitespaceValue -ExpectedText $probeTextValue
        $childResult | Add-Member NoteProperty summary_valid $summary.valid
        $childResult | Add-Member NoteProperty summary_reason $summary.reason
        if (-not $summary.valid) { $aggregateFailed = $true }
    }
    $crossHostAclFingerprintStatus = 'not-applicable'
    $crossHostAclFingerprintDetail = ''
    if ($Phase -ge 4) {
        $fingerprints = New-Object System.Collections.Generic.List[string]
        foreach ($childResult in $aggregateResults) {
            $match = [regex]::Match([string]$childResult.stdout, '(?m)^REAL_ACL_EMPTY_FINGERPRINT:\s+(?<fingerprint>[a-f0-9]{64})\s*$')
            if (-not $match.Success) {
                $crossHostAclFingerprintStatus = 'FAIL'
                $crossHostAclFingerprintDetail = 'child 缺少 REAL_ACL_EMPTY_FINGERPRINT。'
                $aggregateFailed = $true
                continue
            }
            $fingerprints.Add($match.Groups['fingerprint'].Value)
        }
        if ($fingerprints.Count -eq $aggregateResults.Count -and @($fingerprints.ToArray() | Select-Object -Unique).Count -eq 1) {
            $crossHostAclFingerprintStatus = 'PASS'
            $crossHostAclFingerprintDetail = $fingerprints[0]
        }
        elseif ($crossHostAclFingerprintStatus -ne 'FAIL') {
            $crossHostAclFingerprintStatus = 'FAIL'
            $crossHostAclFingerprintDetail = 'powershell.exe 與 pwsh 的 fingerprint 不一致。'
            $aggregateFailed = $true
        }
    }
    foreach ($childResult in $aggregateResults) {
        Write-Output ('ENVIRONMENT: ' + $childResult.label)
        Write-Output ('COMMAND: ' + $childResult.command)
        Write-Output ('START_UTC: ' + $childResult.start_utc)
        Write-Output ('FINISH_UTC: ' + $childResult.finish_utc)
        Write-Output ('DURATION_MS: ' + $childResult.duration_ms)
        Write-Output ('EXIT_CODE: ' + $childResult.exit_code)
        Write-Output ('SUMMARY: ' + $(if ($childResult.summary_valid) { 'PASS' } else { 'FAIL' }) + ' ' + $childResult.summary_reason)
        Write-Output 'STDOUT_BEGIN'
        Write-Output ([string]$childResult.stdout)
        Write-Output 'STDOUT_END'
        Write-Output 'STDERR_BEGIN'
        Write-Output ([string]$childResult.stderr)
        if (-not [string]::IsNullOrWhiteSpace($childResult.launch_error)) { Write-Output ('LAUNCH_ERROR: ' + $childResult.launch_error) }
        Write-Output 'STDERR_END'
    }
    Write-Output ('CROSS_HOST_ACL_EMPTY_FINGERPRINT: ' + $crossHostAclFingerprintStatus + ' ' + $crossHostAclFingerprintDetail)
    if ($aggregateFailed) { exit 1 }
    exit 0
}

$fixtureRoot = Join-Path $root ('.local/ai-sessions/scratch/r-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
$script:caseCount = 0
$script:failures = 0

function Invoke-Case {
    [CmdletBinding()]
    param([string]$Name, [scriptblock]$Action, [switch]$Reject, [string]$ErrorPattern)
    $script:caseCount++
    $expected = if ($Reject) { 'reject' } else { 'pass' }
    $actual = 'pass'
    $detail = ''
    try { & $Action | Out-Null } catch { $actual = 'reject'; $detail = $_.Exception.Message }
    $result = if ($actual -eq $expected) { 'PASS' } else { 'FAIL' }
    if ($Reject -and -not [string]::IsNullOrWhiteSpace($ErrorPattern) -and $detail -notmatch $ErrorPattern) { $result = 'FAIL' }
    if ($result -eq 'FAIL') { $script:failures++ }
    Write-Output "CASE: $Name
EXPECTED: $expected
ACTUAL: $actual $detail
RESULT: $result"
}

function Assert-True {
    [CmdletBinding()]
    param([bool]$Value, [string]$Message)
    if (-not $Value) { throw $Message }
}

if ($Child) {
    Write-Output ('PROBE_DATE_ECHO: <' + $ProbeDate + '>')
    Write-Output ('PROBE_EMPTY_ECHO: <' + $ProbeEmpty + '>')
    Write-Output ('PROBE_WHITESPACE_ECHO: <' + $ProbeWhitespace + '>')
    Write-Output ('PROBE_TEXT_ECHO: <' + $ProbeText + '>')
    Invoke-Case '跨程序參數與 UTC 日期 probe' {
        $parsedDate = [datetime]::MinValue
        $dateParsed = [datetime]::TryParseExact(
            $ProbeDate,
            'yyyy-MM-ddTHH:mm:ss.fffffffZ',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$parsedDate)
        Assert-True $dateParsed 'probe 日期格式不符。'
        Assert-True ($ProbeEmpty -ceq '') 'probe 空字串遺失。'
        Assert-True ($ProbeWhitespace -ceq '  ') 'probe 空白字串遺失。'
        Assert-True ($ProbeText -ceq '  中文，逗號,$literal  ') 'probe Unicode、標點或 literal 內容遺失。'
    }
}

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
Invoke-Case 'Windows PowerShell AST' { Assert-True ($parseErrors.Count -eq 0) ($parseErrors | Out-String) }
foreach ($path in @($sourcePath, $PSCommandPath)) {
    Invoke-Case ('BOM ' + [IO.Path]::GetFileName($path)) {
        $bytes = [IO.File]::ReadAllBytes($path)
        Assert-True ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) '缺少 UTF-8 BOM。'
        Assert-True ([IO.File]::ReadAllText($path) -notmatch '(?<!\r)\n|\r(?!\n)') '存在非 CRLF 行尾。'
    }
}
if ($parseErrors.Count -gt 0) { exit 1 }
$functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false))
foreach ($function in $functions) {
    $definition = $function.Extent.Text
    if ($function.Name -in @('Invoke-Start', 'Invoke-QuotaProbe')) {
        $definition = $definition.Replace('$process = New-Object System.Diagnostics.Process', '$process = New-TestProcess')
    }
    . ([scriptblock]::Create($definition))
}

$initialLineRoot = Join-Path $fixtureRoot '.local/ai-sessions/handoff/line-a'
New-Item -ItemType Directory -Path $initialLineRoot -Force | Out-Null
Write-Utf8NoBom -Path (Join-Path $initialLineRoot 'line.json') -Content (([ordered]@{ schema = 'ai-sessions.line.v1'; 'line-slug' = 'line-a' } | ConvertTo-Json) + "`n")

# 僅替換外部程序、額度與 launcher 邊界，保留 Start／Inspect 控制流程及紀錄 I/O。
$script:mutateProfileAfterCompare = $false
$script:profileMutationPath = $null
$script:profileMutationContent = $null
$script:startSnapshotMode = 'confirmed'
$script:quotaFixtureFailure = $false
$script:aclFixtureStatus = 'clean'
$script:scopePlanFixtureDecision = 'full'
$script:launcherFixtureFailure = $false
$script:quotaSnapshotPathOverride = $null
$script:dispatchUnitListOverride = $null
$script:advisorStartPromptMode = $false
$script:phase8CapturedActivation = $null
$script:phase8CapturedScopePlan = $null
$script:quotaProbeCaptureArguments = $false
$script:quotaProbeCapturedArguments = @()
$script:quotaProbeCodexHome = $null
$script:quotaProbeStartCalls = 0
$script:InvocationBoundParameters = [ordered]@{}
$script:RequestContext = $null
$script:RequestPrepareArtifacts = @()
$script:AddDirectoryExplicit = $false
$script:SearchExplicit = $false
$script:CodexParentOptionExplicit = $false
$script:ProfileExplicit = $false
function Get-PidCheckResult { param($SourceRoot, $LineSlug, $WriteMode) return $script:pidResult }
function Get-WorktreeAclGate {
    param($SourceRoot, $ExecutionRoot, $WriteMode)
    if ([string]::Equals([string]$SourceRoot, [string]$ExecutionRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return [ordered]@{ status = 'not-applicable'; rejection_code = $null; source = @{}; dispatch = @{}; residue = @(); write_mode = $WriteMode }
    }
    if ($script:aclFixtureStatus -eq 'residue') {
        return [ordered]@{ status = 'residue'; rejection_code = 'WorktreeAclResidue'; source = @{}; dispatch = @{}; residue = @([ordered]@{ identity = 'fixture'; rights = 'Modify' }); write_mode = $WriteMode }
    }
    if ($script:aclFixtureStatus -eq 'unknown') {
        return [ordered]@{ status = 'unknown'; rejection_code = 'WorktreeAclUnknown'; source = @{}; dispatch = @{}; residue = @(); write_mode = $WriteMode }
    }
    return [ordered]@{ status = 'clean'; rejection_code = $null; source = @{}; dispatch = @{}; residue = @(); write_mode = $WriteMode }
}
function Get-CodexExecutablePath { param($ConfiguredPath) return 'fixture-codex' }
function Get-OrCreateQuotaSnapshot {
    param($Path, $CodexHome, $HistoryRoot, $Purpose, [switch]$Required)
    if ($script:quotaFixtureFailure) { throw 'quota fixture failure' }
    if (-not [string]::IsNullOrWhiteSpace($script:quotaSnapshotPathOverride)) {
        return $script:quotaSnapshotPathOverride
    }
    $quotaPath = Join-Path $fixtureRoot 'quota.json'
    if (-not (Test-Path -LiteralPath $quotaPath -PathType Leaf)) {
        Write-Utf8NoBom -Path $quotaPath -Content '{}'
    }
    return $quotaPath
}
function Read-QuotaSnapshot { param($Path) return [pscustomobject]@{ values = @{} } }
function Read-ScopePlanFile { param($Path) return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
function Set-QuotaSnapshotFromCodex { param($Path, $CodexHome) return $Path }
function Get-DispatchUnitList {
    param($RequestedUnit, $DispatchKind, $UnitKind, $ExecutionRoot, $LineSlug, $EvidencePackPath, $EvidenceQuestionUnits, $TargetPath)
    if ($null -ne $script:dispatchUnitListOverride) {
        return @($script:dispatchUnitListOverride)
    }
    return 'Phase 1'
}
function New-ScopePlan {
    if ($script:scopePlanFixtureDecision -ne 'full') {
        return [pscustomobject]@{
            decision = $script:scopePlanFixtureDecision
            decision_reason = 'fixture scope plan rejection'
            scope_plan_fingerprint = 'fixture'
            primary_budget_percent = 0
            selected_units = @()
            deferred_units = @('Phase 1')
        }
    }
    return [pscustomobject]@{ decision = 'full'; scope_plan_fingerprint = 'fixture' }
}
function Get-ScopePlanFingerprint { param($ScopePlan) return 'fixture' }
function Test-ContinuationScopePlan { return $true }
function New-DispatchPrompt {
    param($PromptPath, $HistoryRoot, $Timestamp, $Directive)
    if ($script:advisorStartPromptMode) {
        $content = Get-Content -LiteralPath $PromptPath -Raw -Encoding UTF8
        $content = $content.TrimEnd() + [Environment]::NewLine + (@($Directive) -join [Environment]::NewLine) + [Environment]::NewLine
        Write-Utf8NoBom -Path $PromptPath -Content $content
    }
    return $PromptPath
}
function New-CodexLauncher {
    param($CodexExecutable, $CodexArguments, $PromptPath, $EventPath, $ErrorPath, $HistoryRoot, $LauncherPath)
    if ($script:quotaProbeCaptureArguments) {
        $script:quotaProbeCapturedArguments = @($CodexArguments)
        $script:quotaProbeEventPath = $EventPath
        $script:quotaProbeErrorPath = $ErrorPath
        $script:quotaProbeLauncherPath = $LauncherPath
        Write-TestEvents -Path $EventPath -Thread $script:testThread
        Write-Utf8NoBom -Path $ErrorPath -Content ''
        Write-Utf8NoBom -Path $LauncherPath -Content 'fixture launcher'
        $lastMessageIndex = [Array]::IndexOf([string[]]$CodexArguments, '--output-last-message')
        if ($lastMessageIndex -ge 0 -and $lastMessageIndex + 1 -lt @($CodexArguments).Count) {
            Write-Utf8NoBom -Path $CodexArguments[$lastMessageIndex + 1] -Content 'QuotaProbe fixture'
        }
        $rolloutDirectory = Join-Path $script:quotaProbeCodexHome 'sessions/phase8'
        New-Item -ItemType Directory -Path $rolloutDirectory -Force | Out-Null
        Write-Utf8NoBom -Path (Join-Path $rolloutDirectory 'rollout-phase8-f017.jsonl') -Content '{"type":"fixture"}'
    }
    if ($script:launcherFixtureFailure) {
        throw 'fixture launcher failure'
    }
    if ($script:mutateProfileAfterCompare) {
        Write-Utf8NoBom -Path $script:profileMutationPath -Content $script:profileMutationContent
        $script:mutateProfileAfterCompare = $false
    }
    return [pscustomobject]@{ Path = $LauncherPath; FileName = 'fixture'; Arguments = @() }
}
function New-ProcessStartInfo { return [pscustomobject]@{ EnvironmentVariables = @{} } }
function New-TestProcess {
    $process = [pscustomobject]@{ StartInfo = $null; Id = 123; HasExited = $true; ExitCode = 0 }
    $process | Add-Member ScriptMethod Start {
        if ($script:quotaProbeCaptureArguments) {
            $script:quotaProbeStartCalls++
            return $true
        }
        $script:startCalls++
        $records = @(Get-ChildItem (Get-DispatchRunDirectory $SourceRoot $LineSlug $DispatchSlug) -Filter '*.json')
        Assert-True ($records.Count -gt 0) 'process.Start 前沒有紀錄。'
        $states = @($records | ForEach-Object { (Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).launch_state })
        Assert-True ($states -contains 'prepared') 'process.Start 前沒有 prepared。'
        if ($script:failLaunch) { throw 'fixture launch failure' }
        return $true
    }
    $process | Add-Member ScriptMethod WaitForExit { }
    $process | Add-Member ScriptMethod Dispose { }
    return $process
}
function Get-StartedProcessSnapshot {
    param($ProcessId)
    switch ($script:startSnapshotMode) {
        'missing' { return $null }
        'unconfirmed' { return [pscustomobject]@{ IdentityStatus = 'unknown'; IdentityVerified = $false; ProcessName = 'fixture'; ParentProcessId = 1; CreationUtc = [datetime]::UtcNow; IdentityFailureFields = @('fixture'); IdentityMissingFields = @() } }
        default { return [pscustomobject]@{ IdentityStatus = 'confirmed'; IdentityVerified = $true; ProcessName = 'fixture'; ParentProcessId = 1; CreationUtc = [datetime]::UtcNow } }
    }
}
function Wait-ForThreadRelay {
    param($EventPath, $ThreadPath, $TimeoutSeconds)
    Write-TestEvents -Path $EventPath -Thread $script:testThread
    if ($script:relayFailure) { return [pscustomobject]@{ threadId = ''; timeoutSeconds = 5; source = 'fixture'; timedOut = $true } }
    return [pscustomobject]@{ threadId = $script:testThread; timeoutSeconds = 5; source = 'fixture'; timedOut = $false }
}
function Stop-VerifiedProcessTree { return [pscustomobject]@{ CleanupStatus = 'fixture'; ErrorMessage = '' } }
function Get-ProcessExitCodeIfExited { param($Process) return 0 }
function Add-CalibrationObservation { param($ExecutionResult) $script:observedExecution = $ExecutionResult; return $null }

function Write-TestEvents {
    [CmdletBinding()]
    param([string]$Path, [string]$Thread, [string]$Terminal = 'turn.completed')
    $events = @(
        @{ type = 'thread.started'; thread_id = $Thread }
        @{ type = 'item.completed'; item = @{ type = 'agent_message'; text = 'design.md dispatch-a line-a' } }
        @{ type = $Terminal; usage = @{ input_tokens = 1; output_tokens = 1 } }
    )
    Write-Utf8NoBom $Path (($events | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 }) -join "
")
}

function New-TestRun {
    [CmdletBinding()]
    param([string]$Line = 'line-a', [string]$Dispatch = 'dispatch-a', [psobject]$Previous = $null)
    $id = [guid]::NewGuid().ToString('D')
    $createdAt = [datetime]::UtcNow.ToString('o')
    $history = Join-Path $fixtureRoot '.local/ai-sessions/history'
    New-Item -ItemType Directory -Path $history -Force | Out-Null
    $preflightPath = Join-Path $history ($Line + '-' + $Dispatch + '-preflight.json')
    $scope = Join-Path $history ($Line + '-' + $Dispatch + '-scope.json')
    $eventPath = Join-Path $history ($id + '.jsonl')
    $lastMessagePath = Join-Path $history ($id + '.md')
    $pidPath = Join-Path $history ($id + '.pid')
    $fixtureParentOptions = New-ParentOptionsModel -Profile 'default' -Sandbox 'workspace-write' -WorkingDirectory $fixtureRoot -AddDirectory @() -Search $false -CodexParentOption @()
    $fixtureModelEvidence = New-ModelEvidence -RequestedModel (New-RequestedDispatchEvidence -Value $null -Field 'Model') -ResolvedModel (New-ConfirmedDispatchEvidence -Value 'fixture-model' -Source 'profile-config' -Field 'model') -RuntimeModel (New-ConfirmedDispatchEvidence -Value 'fixture-model' -Source 'rollout' -Field 'payload.model') -RequestedReasoningEffort (New-RequestedDispatchEvidence -Value $null -Field 'ReasoningEffort') -ResolvedReasoningEffort (New-ConfirmedDispatchEvidence -Value 'high' -Source 'profile-config' -Field 'model_reasoning_effort') -RuntimeReasoningEffort (New-ConfirmedDispatchEvidence -Value 'high' -Source 'rollout' -Field 'payload.effort')
    if (-not (Test-Path $preflightPath)) { Write-Utf8NoBom $preflightPath (([ordered]@{ sourceRoot = $fixtureRoot; executionRoot = $fixtureRoot; lineSlug = $Line; dispatchSlug = $Dispatch; writeMode = 'readonly' } | ConvertTo-Json)) }
    if (-not (Test-Path $scope)) { Write-Utf8NoBom $scope '{}' }
    $record = [pscustomobject]@{
        schema = 'ai-sessions.dispatch-run.v1'; run_id = $id; line_slug = $Line; dispatch_slug = $Dispatch
        source_root = $fixtureRoot; execution_root = $fixtureRoot
        previous_run_id = if ($null -eq $Previous) { $null } else { $Previous.run_id }
        attempt_parent_run_id = if ($null -eq $Previous) { $null } else { $Previous.run_id }
        resume_anchor_run_id = $null
        skipped_attempts = @()
        requested_thread_id = if ($null -eq $Previous) { $null } else { $Previous.thread_id }
        thread_id = $script:testThread; event_stream_path = $eventPath; last_message_path = $lastMessagePath
        scope_plan_path = $scope; scope_plan_sha256 = Get-FileSha256 $scope
        preflight_result_path = $preflightPath; preflight_sha256 = Get-FileSha256 $preflightPath
        launch_state = 'started'; created_at_utc = $createdAt; started_at_utc = $createdAt
        failure = $null; resume_diagnostics = $null
        model_evidence = $fixtureModelEvidence.model; reasoning_effort_evidence = $fixtureModelEvidence.reasoning_effort
        profile_config_path = $null; codex_home = $null
        evidence_pack_path = $null; evidence_pack_sha256 = $null; evidence_pack_length = $null
        prompt_path = $null; launcher_path = $null; thread_id_path = $null
        baseline_path = $null; baseline_sha256 = $null; pid_record_path = $pidPath
        parent_options = $fixtureParentOptions; parent_options_sha256 = $fixtureParentOptions.fingerprint; parent_options_status = 'confirmed'
        effective_codex_home = $null; acl_gate = $null; recovery_handoff_id = $null; recovery_handoff_path = $null; recovery_handoff_sha256 = $null
        quota_before_path = $null; quota_before_sha256 = $null
    }
    Write-TestEvents $record.event_stream_path $record.thread_id
    Write-Utf8NoBom $record.last_message_path 'A completed'
    Write-Utf8NoBom $record.pid_record_path 'fixture stopped'
    $null = Write-DispatchRunRecord $record
    return $record
}

function New-TestHandoffValidationContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Record,

        [Parameter(Mandatory)]
        [psobject]$ScopePlan,

        [AllowNull()]
        [object[]]$AuthorizedUnits
    )

    $runDirectory = Get-DispatchRunDirectory $fixtureRoot $Record.line_slug $Record.dispatch_slug
    $chain = Get-RecoveryChainModel -LatestRecord $Record -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug $Record.line_slug -DispatchSlug $Record.dispatch_slug
    $resolvedAuthorizedUnits = New-Object 'System.Object[]' 0
    if ($null -ne $AuthorizedUnits) {
        $resolvedAuthorizedUnits = @($AuthorizedUnits)
    }
    if ($resolvedAuthorizedUnits.Count -eq 0) {
        $requestedUnits = Get-DispatchJsonProperty -Object $ScopePlan -Name 'requested_units'
        if ($null -ne $requestedUnits) {
            $resolvedAuthorizedUnits = @($requestedUnits)
        }
        else {
            $resolvedAuthorizedUnits = @((Get-DispatchJsonProperty -Object $ScopePlan -Name 'selected_units')) + @((Get-DispatchJsonProperty -Object $ScopePlan -Name 'deferred_units'))
        }
    }
    return [ordered]@{
        current_record = $Record
        current_chain = $chain
        current_run_record_path = Join-Path $runDirectory ($Record.run_id + '.json')
        current_event_path = $Record.event_stream_path
        scope_path = $Record.scope_plan_path
        scope_hash = Get-FileSha256 $Record.scope_plan_path
        scope_plan = $ScopePlan
        baseline_path = $null
        baseline_hash = $null
        baseline_status = 'not-applicable'
        process_gate = [ordered]@{ status = 'stopped'; pid_check = @{}; active_records = @(); stopped_evidence = $true }
        acl_gate = Get-WorktreeAclGate -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -WriteMode 'direct-write'
        model_evidence = [ordered]@{
            resolved = Get-DispatchJsonProperty -Object $Record.model_evidence -Name 'resolved'
            reasoning_effort = Get-DispatchJsonProperty -Object $Record.reasoning_effort_evidence -Name 'resolved'
        }
        resume_diagnostics = $null
        parent_options = $Record.parent_options
        authorized_units = @($resolvedAuthorizedUnits)
        target_paths_provided = $false
        target_paths = @()
        dispatch_order_path = 'not-specified'
        dispatch_order_hash = $null
    }
}

function Set-TestHandoffDocumentHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [psobject]$Document
    )

    $Document.handoff_sha256 = $null
    $canonicalDocument = [ordered]@{}
    foreach ($property in @($Document.PSObject.Properties)) {
        if ($property.Name -ne 'handoff_sha256') {
            $canonicalDocument[$property.Name] = $property.Value
        }
    }
    $Document.handoff_sha256 = Get-JsonSha256 -Value $canonicalDocument
    Write-Utf8NoBom -Path $Path -Content (($Document | ConvertTo-Json -Depth 40) + [string][char]10)
}

$script:testThread = [guid]::NewGuid().ToString('D')
$script:relayFailure = $false
$script:pidResult = @{ ActiveRecords = @(); UnconfirmedRecords = @(); Blocked = $false; Reason = '' }
$a = New-TestRun
$b = New-TestRun -Line 'line-b' -Dispatch 'dispatch-b'
$c = New-TestRun -Dispatch 'dispatch-c'
$binding = @{ SourceRoot = $fixtureRoot; ExecutionRoot = $fixtureRoot; LineSlug = 'line-a'; DispatchSlug = 'dispatch-a' }
$resume = $binding.Clone()
$resume.ResumeThreadId = $script:testThread
$aPath = Join-Path (Get-DispatchRunDirectory $fixtureRoot 'line-a' 'dispatch-a') ($a.run_id + '.json')

Invoke-Case 'RunRecord 真實 JSON 日期往返維持字串' {
    $roundTrip = Read-DispatchRunRecord -Path $aPath @binding
    Assert-True ($roundTrip.created_at_utc -is [string] -and $roundTrip.created_at_utc -ceq $a.created_at_utc) 'JSON 日期往返型別或值不一致。'
}

Invoke-Case '跨線 B／同線 C 較新訊息仍選 A' {
    (Get-Item $b.last_message_path).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(1)
    (Get-Item $c.last_message_path).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(2)
    $selected = Resolve-PreviousDispatchRun @resume
    Assert-True ($selected.Record.run_id -eq $a.run_id -and $selected.Message -eq 'A completed') '選錯派遣。'
}
Invoke-Case '缺紀錄拒絕' -Reject { Resolve-PreviousDispatchRun -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug 'missing' -DispatchSlug 'missing' -ResumeThreadId $script:testThread }
Invoke-Case '錯 thread 拒絕' -Reject { $bad = $resume.Clone(); $bad.ResumeThreadId = [guid]::NewGuid().ToString('D'); Resolve-PreviousDispatchRun @bad }
Invoke-Case '顯式其他輪路徑拒絕' -Reject { Resolve-PreviousDispatchRun @resume -LastMessagePath $c.last_message_path }
Invoke-Case '顯式鏈尾路徑接受' { Resolve-PreviousDispatchRun @resume -LastMessagePath $a.last_message_path }
Invoke-Case '空訊息拒絕' -Reject -ErrorPattern 'last-message 為空' {
    try { Write-Utf8NoBom $a.last_message_path ' '; Resolve-PreviousDispatchRun @resume } finally { Write-Utf8NoBom $a.last_message_path 'A completed' }
}
Invoke-Case 'prepared 唯一 thread 事件可驗證' {
    try { $a.launch_state = 'prepared'; $a.thread_id = $null; $null = Write-DispatchRunRecord $a -Update; Resolve-PreviousDispatchRun @resume } finally { $a.launch_state = 'started'; $a.thread_id = $script:testThread; $null = Write-DispatchRunRecord $a -Update }
}
Invoke-Case '中斷輪三個保全欄位可續行' {
    try {
        Write-TestEvents $a.event_stream_path $script:testThread 'turn.failed'
        Write-Utf8NoBom $a.last_message_path "已確認結論：完成部分
未完成單位：Phase 2
證據位置：fixture"
        Resolve-PreviousDispatchRun @resume
    } finally { Write-TestEvents $a.event_stream_path $script:testThread; Write-Utf8NoBom $a.last_message_path 'A completed' }
}
Invoke-Case '中斷輪缺保全欄位拒絕' -Reject {
    try { Write-TestEvents $a.event_stream_path $script:testThread 'turn.failed'; Resolve-PreviousDispatchRun @resume } finally { Write-TestEvents $a.event_stream_path $script:testThread }
}
Invoke-Case '不可解析事件拒絕' -Reject {
    try { Write-Utf8NoBom $a.event_stream_path '{bad'; Resolve-PreviousDispatchRun @resume } finally { Write-TestEvents $a.event_stream_path $script:testThread }
}
Invoke-Case '事件 type 非字串拒絕' -Reject -ErrorPattern 'type' {
    try {
        $lines = @(Get-Content $a.event_stream_path)
        $invalid = @{ type = 123; item = @{ type = 'agent_message'; text = 'design.md dispatch-a line-a' } } | ConvertTo-Json -Compress -Depth 5
        Write-Utf8NoBom $a.event_stream_path (($lines[0], $invalid, $lines[2]) -join "
")
        Resolve-PreviousDispatchRun @resume
    } finally { Write-TestEvents $a.event_stream_path $script:testThread }
}
Invoke-Case '缺事件拒絕' -Reject {
    try { Move-Item $a.event_stream_path ($a.event_stream_path + '.saved'); Resolve-PreviousDispatchRun @resume } finally { Move-Item ($a.event_stream_path + '.saved') $a.event_stream_path }
}
Invoke-Case '執行中鏈尾拒絕' -Reject {
    try { $script:pidResult.ActiveRecords = @([pscustomobject]@{ DispatchSlug = 'dispatch-a' }); Resolve-PreviousDispatchRun @resume } finally { $script:pidResult.ActiveRecords = @() }
}
Invoke-Case '身分不明鏈尾拒絕' -Reject {
    try { $script:pidResult.UnconfirmedRecords = @([pscustomobject]@{ DispatchSlug = 'dispatch-a'; IdentityStatus = 'unknown' }); Resolve-PreviousDispatchRun @resume } finally { $script:pidResult.UnconfirmedRecords = @() }
}
Invoke-Case '雜湊竄改拒絕' -Reject {
    try { Write-Utf8NoBom $a.scope_plan_path '{ }'; Resolve-PreviousDispatchRun @resume } finally { Write-Utf8NoBom $a.scope_plan_path '{}' }
}
Invoke-Case '欄位異常拒絕' -Reject -ErrorPattern 'launch_state 異常' {
    try { $a.launch_state = 'invalid'; $null = Write-DispatchRunRecord $a -Update; Resolve-PreviousDispatchRun @resume } finally { $a.launch_state = 'started'; $null = Write-DispatchRunRecord $a -Update }
}
$a2 = New-TestRun -Previous $a
Invoke-Case '同 dispatch 第二輪選鏈尾' { Assert-True ((Resolve-PreviousDispatchRun @resume).Record.run_id -eq $a2.run_id) '未選鏈尾。' }
Invoke-Case '顯式同 dispatch 前輪拒絕' -Reject { Resolve-PreviousDispatchRun @resume -LastMessagePath $a.last_message_path }
Invoke-Case '斷鏈拒絕' -Reject -ErrorPattern '唯一鏈尾|斷鏈' {
    $detachedId = [guid]::NewGuid().ToString('D')
    try { $a2.previous_run_id = $detachedId; $a2.attempt_parent_run_id = $detachedId; $null = Write-DispatchRunRecord $a2 -Update; Resolve-PreviousDispatchRun @resume } finally { $a2.previous_run_id = $a.run_id; $a2.attempt_parent_run_id = $a.run_id; $null = Write-DispatchRunRecord $a2 -Update }
}
Invoke-Case '循環拒絕' -Reject -ErrorPattern '唯一鏈尾|循環' {
    try { $a.previous_run_id = $a2.run_id; $a.requested_thread_id = $script:testThread; $null = Write-DispatchRunRecord $a -Update; Resolve-PreviousDispatchRun @resume } finally { $a.previous_run_id = $null; $a.requested_thread_id = $null; $null = Write-DispatchRunRecord $a -Update }
}
$branch = New-TestRun
Invoke-Case '多鏈尾拒絕' -Reject { Resolve-PreviousDispatchRun @resume }

Invoke-Case 'Inspect 隱式精確事件定位' {
    $found = Resolve-InspectDispatchRun @binding -EventStreamPath $a.event_stream_path -ScopePlanPath $a.scope_plan_path
    Assert-True ($found.Record.run_id -eq $a.run_id) 'Inspect 定位不符。'
}
Invoke-Case 'Inspect 顯式其他紀錄拒絕' -Reject { Resolve-InspectDispatchRun @binding -EventStreamPath $c.event_stream_path -ScopePlanPath $a.scope_plan_path -RunRecordPath $aPath }
Invoke-Case 'Inspect 錯 roots 拒絕' -Reject { $bad = $binding.Clone(); $bad.ExecutionRoot = $root; Resolve-InspectDispatchRun @bad -EventStreamPath $a.event_stream_path -ScopePlanPath $a.scope_plan_path }
Invoke-Case 'Inspect 錯 ScopePlan 拒絕' -Reject { Resolve-InspectDispatchRun @binding -EventStreamPath $a.event_stream_path -ScopePlanPath $c.scope_plan_path }

function Write-ReviewerFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][psobject]$Manifest,
        [string[]]$CurrentIds,
        [ValidateSet('Standards', 'Standards 缺陷審查', '需求對照核對', 'Spec')]
        [string]$CurrentHeading = 'Spec',
        [string[]]$PreviousProse = @()
    )

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(
            '# Reviewer fixture',
            '',
            '## 總覽',
            '',
            '本報告供 finding manifest validator fixture 使用。',
            '',
            '## Finding manifest',
            '',
            '```json',
            ($Manifest | ConvertTo-Json -Depth 10),
            '```',
            ''
        )) {
        $lines.Add($line)
    }
    if ($PreviousProse.Count -gt 0) {
        $lines.Add('## 前輪 finding 狀態')
        $lines.Add('')
        foreach ($line in @($PreviousProse)) {
            $lines.Add($line)
        }
        $lines.Add('')
    }
    foreach ($heading in @('Standards', 'Standards 缺陷審查', '需求對照核對', 'Spec')) {
        $lines.Add('## ' + $heading)
        $lines.Add('')
        $lines.Add($heading + ' current findings。')
        if ($heading -ceq $CurrentHeading) {
            foreach ($id in @($CurrentIds)) {
                $lines.Add(('- [{0}] fixture current finding' -f $id))
            }
        }
        $lines.Add('')
    }
    Write-Utf8NoBom -Path $Path -Content (($lines.ToArray() -join "
") + "
")
}

function New-ReviewerManifest {
    [CmdletBinding()]
    param(
        [object[]]$CurrentFindings = @(),
        [object[]]$PreviousStatus = @(),
        [int]$PreviousClosed = 0,
        [int]$PreviousOpen = 0,
        [int]$CurrentNew = 0,
        [int]$CurrentOpen = 0,
        [ValidateSet('pass', 'fail')][string]$Conclusion = 'pass'
    )

    return [ordered]@{
        schema = 'codex-dispatch.review-findings.v1'
        current_findings = @($CurrentFindings)
        previous_status = @($PreviousStatus)
        counts = [ordered]@{
            previous_closed = $PreviousClosed
            previous_open = $PreviousOpen
            current_new = $CurrentNew
            current_open = $CurrentOpen
        }
        conclusion = $Conclusion
    }
}

$reviewerRoot = Join-Path $fixtureRoot 'reviewer'
New-Item -ItemType Directory -Path $reviewerRoot -Force | Out-Null
Invoke-Case 'Reviewer manifest 零 finding 通過' {
    $path = Join-Path $reviewerRoot 'zero.md'
    $manifest = New-ReviewerManifest
    Write-ReviewerFixture -Path $path -Manifest $manifest
    $result = Test-ReviewerFindingReport -Path $path
    Assert-True ($result.valid -and $result.conclusion -eq 'pass' -and $result.current_open_count -eq 0 -and $result.previous_closed_count -eq 0 -and $result.previous_open_count -eq 0) '零 finding manifest 驗證異常。'
}
Invoke-Case 'Reviewer manifest carried 與 current new 分開計數' {
    $path = Join-Path $reviewerRoot 'carried-new.md'
    $current = @(
        [ordered]@{ id = 'F-001'; axis = 'Standards'; status = 'open'; severity = 'Major'; disposition = 'carried'; summary = 'carried major' },
        [ordered]@{ id = 'F-002'; axis = 'Spec'; status = 'open'; severity = 'Minor'; disposition = 'new'; summary = 'new minor' }
    )
    $previous = @(
        [ordered]@{ id = 'F-001'; status = 'open'; severity = 'Major' }
    )
    $manifest = New-ReviewerManifest -CurrentFindings $current -PreviousStatus $previous -PreviousOpen 1 -CurrentNew 1 -CurrentOpen 2 -Conclusion fail
    Write-ReviewerFixture -Path $path -Manifest $manifest -CurrentIds @('F-001', 'F-002') -PreviousProse @('- [F-001] [Major] 未閉合 — carried fixture')
    $result = Test-ReviewerFindingReport -Path $path
    Assert-True ($result.valid -and $result.previous_open_count -eq 1 -and $result.current_new_count -eq 1 -and $result.current_open_count -eq 2 -and $result.conclusion -eq 'fail') '歷史與 current new 計數未分離。'
}
Invoke-Case 'Reviewer manifest duplicate ID 不增加計數' {
    $path = Join-Path $reviewerRoot 'duplicate.md'
    $finding = [ordered]@{ id = 'F-001'; axis = 'Spec'; status = 'open'; severity = 'Minor'; disposition = 'new'; summary = 'duplicate fixture' }
    $manifest = New-ReviewerManifest -CurrentFindings @($finding, $finding) -CurrentNew 1 -CurrentOpen 1 -Conclusion pass
    Write-ReviewerFixture -Path $path -Manifest $manifest -CurrentIds @('F-001', 'F-001')
    $result = Test-ReviewerFindingReport -Path $path
    Assert-True ($result.valid -and $result.current_new_count -eq 1 -and $result.current_open_count -eq 1 -and $result.duplicate_ids -contains 'F-001') '重複 ID 計數或診斷異常。'
}
Invoke-Case 'Reviewer 只有 Minor 時 conclusion pass' {
    $path = Join-Path $reviewerRoot 'minor.md'
    $finding = [ordered]@{ id = 'F-003'; axis = 'Standards'; status = 'open'; severity = 'Minor'; disposition = 'new'; summary = 'minor fixture' }
    $manifest = New-ReviewerManifest -CurrentFindings @($finding) -CurrentNew 1 -CurrentOpen 1 -Conclusion pass
    Write-ReviewerFixture -Path $path -Manifest $manifest -CurrentIds @('F-003')
    $result = Test-ReviewerFindingReport -Path $path
    Assert-True ($result.valid -and $result.conclusion -eq 'pass' -and $result.current_finding_count -eq 1) 'Minor severity gate 異常。'
}
Invoke-Case 'Reviewer current prose 與空 manifest 矛盾' {
    $path = Join-Path $reviewerRoot 'prose-mismatch.md'
    $manifest = New-ReviewerManifest
    Write-ReviewerFixture -Path $path -Manifest $manifest -CurrentIds @('F-004')
    $result = Test-ReviewerFindingReport -Path $path
    Assert-True (-not $result.valid -and $result.inconsistencies -match 'prose finding missing') 'prose 與 manifest 矛盾未拒絕。'
}
Invoke-Case 'Reviewer previous prose 與 previous_status 不一致' -Reject -ErrorPattern 'previous prose finding missing from previous_status' {
    $path = Join-Path $reviewerRoot 'previous-prose-mismatch.md'
    $previous = @([ordered]@{ id = 'F-008'; status = 'open'; severity = 'Major' })
    $manifest = New-ReviewerManifest -PreviousStatus $previous -PreviousOpen 1
    Write-ReviewerFixture -Path $path -Manifest $manifest -PreviousProse @('- [F-009] [Major] 未閉合 — previous prose mismatch')
    $result = Test-ReviewerFindingReport -Path $path
    if ($result.valid) { throw 'previous prose mismatch unexpectedly valid' }
    throw ($result.inconsistencies -join '; ')
}
Invoke-Case 'Reviewer carried severity 與 previous_status 衝突' -Reject -ErrorPattern 'carried finding severity conflicts with previous_status' {
    $path = Join-Path $reviewerRoot 'carried-severity-conflict.md'
    $finding = [ordered]@{ id = 'F-010'; axis = 'Standards'; status = 'open'; severity = 'Major'; disposition = 'carried'; summary = 'carried severity conflict' }
    $previous = @([ordered]@{ id = 'F-010'; status = 'open'; severity = 'Minor' })
    $manifest = New-ReviewerManifest -CurrentFindings @($finding) -PreviousStatus $previous -PreviousOpen 1 -CurrentOpen 1 -Conclusion fail
    Write-ReviewerFixture -Path $path -Manifest $manifest -CurrentIds @('F-010') -PreviousProse @('- [F-010] [Minor] 未閉合 — carried severity conflict')
    $result = Test-ReviewerFindingReport -Path $path
    if ($result.valid) { throw 'carried severity conflict unexpectedly valid' }
    throw ($result.inconsistencies -join '; ')
}
Invoke-Case 'Reviewer 非法 axis 拒絕' -Reject -ErrorPattern 'axis invalid' {
    $path = Join-Path $reviewerRoot 'invalid-axis.md'
    $finding = [ordered]@{ id = 'F-011'; axis = 'Other'; status = 'open'; severity = 'Minor'; disposition = 'new'; summary = 'invalid axis' }
    $manifest = New-ReviewerManifest -CurrentFindings @($finding) -CurrentNew 1 -CurrentOpen 1 -Conclusion pass
    Write-ReviewerFixture -Path $path -Manifest $manifest -CurrentIds @('F-011')
    $result = Test-ReviewerFindingReport -Path $path
    if ($result.valid) { throw 'invalid axis unexpectedly valid' }
    throw ($result.inconsistencies -join '; ')
}
Invoke-Case 'Reviewer Standards 缺陷審查 heading finding 通過' {
    $path = Join-Path $reviewerRoot 'standards-defect-heading.md'
    $finding = [ordered]@{ id = 'F-012'; axis = 'Standards'; status = 'open'; severity = 'Minor'; disposition = 'new'; summary = 'standards defect heading' }
    $manifest = New-ReviewerManifest -CurrentFindings @($finding) -CurrentNew 1 -CurrentOpen 1 -Conclusion pass
    Write-ReviewerFixture -Path $path -Manifest $manifest -CurrentIds @('F-012') -CurrentHeading 'Standards 缺陷審查'
    $result = Test-ReviewerFindingReport -Path $path
    Assert-True ($result.valid -and $result.current_open_count -eq 1) 'Standards 缺陷審查 heading 未納入 current prose。'
}
Invoke-Case 'Reviewer current carried 缺 previous open 拒絕' -Reject {
    $path = Join-Path $reviewerRoot 'invalid-carried.md'
    $finding = [ordered]@{ id = 'F-005'; axis = 'Spec'; status = 'open'; severity = 'Major'; disposition = 'carried'; summary = 'invalid carried' }
    $manifest = New-ReviewerManifest -CurrentFindings @($finding) -CurrentOpen 1 -Conclusion fail
    Write-ReviewerFixture -Path $path -Manifest $manifest -CurrentIds @('F-005')
    $result = Test-ReviewerFindingReport -Path $path
    if ($result.valid) { throw 'invalid carried manifest unexpectedly valid' }
    throw ($result.inconsistencies -join '; ')
}
Invoke-Case 'Reviewer duplicate 欄位衝突拒絕' -Reject {
    $path = Join-Path $reviewerRoot 'conflict.md'
    $first = [ordered]@{ id = 'F-006'; axis = 'Spec'; status = 'open'; severity = 'Minor'; disposition = 'new'; summary = 'first' }
    $second = [ordered]@{ id = 'F-006'; axis = 'Spec'; status = 'open'; severity = 'Major'; disposition = 'new'; summary = 'conflict' }
    $manifest = New-ReviewerManifest -CurrentFindings @($first, $second) -CurrentNew 1 -CurrentOpen 1 -Conclusion fail
    Write-ReviewerFixture -Path $path -Manifest $manifest -CurrentIds @('F-006')
    $result = Test-ReviewerFindingReport -Path $path
    if ($result.valid) { throw 'conflicting duplicate manifest unexpectedly valid' }
    throw ($result.inconsistencies -join '; ')
}
Invoke-Case 'Collect direct-write 接入 reviewerFindings' {
    $outputPath = Join-Path $reviewerRoot 'approved.txt'
    $closurePath = Join-Path $reviewerRoot 'closure.md'
    $reviewerPath = Join-Path $reviewerRoot 'collect.md'
    Write-Utf8NoBom -Path $outputPath -Content 'approved output'
    Write-Utf8NoBom -Path $closurePath -Content '# Fixture closure'
    $finding = [ordered]@{ id = 'F-007'; axis = 'Spec'; status = 'open'; severity = 'Minor'; disposition = 'new'; summary = 'collect fixture' }
    $manifest = New-ReviewerManifest -CurrentFindings @($finding) -CurrentNew 1 -CurrentOpen 1 -Conclusion pass
    Write-ReviewerFixture -Path $reviewerPath -Manifest $manifest -CurrentIds @('F-007')
    $preflightPath = Join-Path $reviewerRoot 'preflight.json'
    $preflight = [ordered]@{
        operation = 'Preflight'
        sourceRoot = $fixtureRoot
        executionRoot = $fixtureRoot
        lineSlug = 'line-a'
        dispatchSlug = 'reviewer-collect'
        worktreeCreated = $false
        baseSha = ''
        targetStates = @([ordered]@{ FullPath = $outputPath; InputPath = 'approved.txt' })
    }
    Write-Utf8NoBom -Path $preflightPath -Content ($preflight | ConvertTo-Json -Depth 8)
    $SourceRoot = $fixtureRoot
    $ExecutionRoot = $fixtureRoot
    $DispatchKind = 'resource'
    $LineSlug = 'line-a'
    $DispatchSlug = 'reviewer-collect'
    $PreflightResultPath = $preflightPath
    $ReportPath = @($closurePath)
    $ReviewerReportPath = $reviewerPath
    $result = Invoke-Collect
    Assert-True ($result.reviewerFindings.valid -and $result.reviewerFindings.conclusion -eq 'pass' -and $result.outputValid) 'Collect reviewerFindings 輸出異常。'
}
Invoke-Case 'Collect reviewer report 結構無效以非零結束' -Reject -ErrorPattern 'Reviewer report 結構無效' {
    $SourceRoot = $fixtureRoot
    $ExecutionRoot = $fixtureRoot
    $DispatchKind = 'resource'
    $LineSlug = 'line-a'
    $DispatchSlug = 'invalid-collect'
    $invalidTargetPath = Join-Path $reviewerRoot 'direct-invalid-approved.txt'
    $invalidClosurePath = Join-Path $reviewerRoot 'direct-invalid-collect-closure.md'
    $PreflightResultPath = Join-Path $reviewerRoot 'direct-invalid-collect-preflight.json'
    Write-Utf8NoBom -Path $invalidTargetPath -Content 'direct invalid fixture output'
    Write-Utf8NoBom -Path $invalidClosurePath -Content '# Direct invalid fixture closure'
    $directPreflight = [ordered]@{
        operation = 'Preflight'
        sourceRoot = $fixtureRoot
        executionRoot = $fixtureRoot
        lineSlug = 'line-a'
        dispatchSlug = 'invalid-collect'
        worktreeCreated = $false
        baseSha = ''
        targetStates = @([ordered]@{ FullPath = $invalidTargetPath; InputPath = 'direct-invalid-approved.txt' })
    }
    Write-Utf8NoBom -Path $PreflightResultPath -Content ($directPreflight | ConvertTo-Json -Depth 8)
    $ReportPath = @($invalidClosurePath)
    $ReviewerReportPath = Join-Path $reviewerRoot 'prose-mismatch.md'
    Invoke-Collect
}
Invoke-Case 'Collect invalid reviewer report 輸出 reviewerFindings 且 exit 非零' {
    $invalidReviewerPath = Join-Path $reviewerRoot 'prose-mismatch.md'
    $invalidPreflightPath = Join-Path $reviewerRoot 'invalid-collect-preflight.json'
    $invalidClosurePath = Join-Path $reviewerRoot 'invalid-collect-closure.md'
    $invalidResultPath = Join-Path $reviewerRoot 'invalid-collect-result.json'
    $invalidTargetPath = Join-Path $reviewerRoot 'invalid-approved.txt'
    Write-Utf8NoBom -Path $invalidClosurePath -Content '# Fixture closure'
    Write-Utf8NoBom -Path $invalidTargetPath -Content 'invalid fixture output'
    $invalidPreflight = [ordered]@{
        operation = 'Preflight'
        sourceRoot = $fixtureRoot
        executionRoot = $fixtureRoot
        lineSlug = 'line-a'
        dispatchSlug = 'invalid-collect'
        worktreeCreated = $false
        baseSha = ''
        targetStates = @([ordered]@{ FullPath = $invalidTargetPath; InputPath = 'invalid-approved.txt' })
    }
    Write-Utf8NoBom -Path $invalidPreflightPath -Content ($invalidPreflight | ConvertTo-Json -Depth 8)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $cliOutput = @(& powershell.exe -NoProfile -File $sourcePath -Operation Collect -DispatchKind resource -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -PreflightResultPath $invalidPreflightPath -ReportPath $invalidClosurePath -ReviewerReportPath $invalidReviewerPath -ResultPath $invalidResultPath 2>&1)
        $cliExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    Assert-True ($cliExitCode -ne 0) ('invalid Reviewer report 應以非零結束：' + ($cliOutput -join [Environment]::NewLine))
    Assert-True (Test-Path -LiteralPath $invalidResultPath -PathType Leaf) 'invalid Reviewer report 未輸出結果檔。'
    $invalidResult = Get-Content -LiteralPath $invalidResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (-not $invalidResult.outputValid -and $null -ne $invalidResult.reviewerFindings -and -not $invalidResult.reviewerFindings.valid -and @($invalidResult.reviewerFindings.inconsistencies).Count -gt 0) 'invalid Reviewer report 缺少結構化 reviewerFindings。'
}

# 初始化入口參數，避免測試程序的動態範圍遺漏 CLI 預設值。
foreach ($parameter in $ast.ParamBlock.Parameters) {
    $name = $parameter.Name.VariablePath.UserPath
    if ($null -ne $parameter.DefaultValue) { Set-Variable -Name $name -Value (& ([scriptblock]::Create($parameter.DefaultValue.Extent.Text))) }
    else { Set-Variable -Name $name -Value $null }
}
$SourceRoot = $fixtureRoot
$ExecutionRoot = $fixtureRoot
$LineSlug = 'line-a'
$DispatchSlug = 'dispatch-a'
$startCodexHome = Join-Path $fixtureRoot 'start-codex-home'
New-Item -ItemType Directory -Path $startCodexHome -Force | Out-Null
Write-Utf8NoBom (Join-Path $startCodexHome 'config.toml') "model = 'fixture-model'
model_reasoning_effort = 'high'
"
$CodexHome = $startCodexHome
$EventStreamPath = $a.event_stream_path
$ScopePlanPath = $a.scope_plan_path
$RequiredIdentifier = 'design.md'
$ProcessExitCode = 0
$QuotaBeforePath = Join-Path $fixtureRoot 'before.json'
$QuotaAfterPath = Join-Path $fixtureRoot 'after.json'
Write-Utf8NoBom $a.last_message_path 'design.md dispatch-a line-a'
Invoke-Case 'Inspect 最終輸出包含 runId 與 runRecordPath' {
    $result = Invoke-Inspect
    Assert-True ($result.runId -eq $a.run_id -and $result.runRecordPath -eq $aPath -and $result.success) 'Inspect 最終輸出異常。'
}
Invoke-Case 'Phase 1 advisor active source removal' {
    Assert-ActiveSourceNotFound -Label 'Phase 1' -Terms $phase1RemovalTerms
}

if ($Phase -ge 2) {
    $profileFixtureRoot = Join-Path $fixtureRoot 'profile-evidence'
    $profileSessionsRoot = Join-Path $profileFixtureRoot 'sessions/2026/09/14'
    New-Item -ItemType Directory -Path $profileSessionsRoot -Force | Out-Null
    $defaultProfilePath = Join-Path $profileFixtureRoot 'config.toml'
    Write-Utf8NoBom -Path $defaultProfilePath -Content ((@(
        'model = "fixture-model"'
        'model_reasoning_effort = "high"'
        ''
        '[agents]'
        'default_subagent_model = "subagent-model"'
        'default_subagent_reasoning_effort = "low"'
    )) -join "
")
    Invoke-Case 'Profile top-level model／effort evidence' {
        $profileEvidence = Read-ProfileModelEvidence -ConfigPath $defaultProfilePath -Profile 'default'
        Assert-True ((Get-DispatchEvidenceValue -Evidence $profileEvidence.model) -ceq 'fixture-model' -and $profileEvidence.model.line -eq 1) 'Profile model evidence 異常。'
        Assert-True ((Get-DispatchEvidenceValue -Evidence $profileEvidence.reasoning_effort) -ceq 'high' -and $profileEvidence.reasoning_effort.line -eq 2) 'Profile effort evidence 異常。'
        Assert-True ($profileEvidence.model.source -eq 'profile-config' -and $profileEvidence.reasoning_effort.source -eq 'profile-config') 'Profile evidence source 異常。'
    }
    Invoke-Case 'Profile agents 欄位不冒充主派工值' {
        $profileEvidence = Read-ProfileModelEvidence -ConfigPath $defaultProfilePath -Profile 'default'
        Assert-True ((Get-DispatchEvidenceValue -Evidence $profileEvidence.model) -cne 'subagent-model' -and (Get-DispatchEvidenceValue -Evidence $profileEvidence.reasoning_effort) -cne 'low') '讀取了 agents table 的 subagent 值。'
    }
    Invoke-Case 'Profile 缺檔與 top-level 衝突轉 unknown' {
        $missing = Read-ProfileModelEvidence -ConfigPath (Join-Path $profileFixtureRoot 'missing.toml') -Profile 'default'
        Assert-True ($missing.model.status -eq 'unknown' -and $missing.reasoning_effort.status -eq 'unknown') '缺檔未轉 unknown。'
        $conflictPath = Join-Path $profileFixtureRoot 'conflict.toml'
        $conflictContent = @(
            'model = "one"'
            'model = "two"'
            'model_reasoning_effort = "high"'
        ) -join "
"
        Write-Utf8NoBom -Path $conflictPath -Content ($conflictContent + "
")
        $conflict = Read-ProfileModelEvidence -ConfigPath $conflictPath -Profile 'default'
        Assert-True ($conflict.model.status -eq 'unknown' -and $conflict.model.source -eq 'profile-config-conflict') '衝突 assignment 未轉 unknown。'
    }
    Invoke-Case 'Profile 不支援名稱回傳 unknown path' {
        Assert-True ($null -eq (Resolve-ProfileConfigPath -CodexHome $profileFixtureRoot -Profile 'unsupported')) '不支援 Profile 建立了替代路徑。'
    }

    $rolloutThread = [guid]::NewGuid().ToString('D')
    $rolloutPath = Join-Path $profileSessionsRoot 'rollout-fixture.jsonl'
    $rolloutEvents = @(
        [ordered]@{ type = 'session_meta'; payload = [ordered]@{ session_id = $rolloutThread } }
        [ordered]@{ type = 'turn_context'; timestamp = '2026-09-14T00:00:01.0000000Z'; payload = [ordered]@{ model = 'fixture-model'; effort = 'high' } }
    )
    Write-Utf8NoBom -Path $rolloutPath -Content (($rolloutEvents | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 }) -join "
")
    Invoke-Case 'Rollout exact session 與 runtime evidence' {
        $runtime = Get-RuntimeModelEvidence -CodexHome $profileFixtureRoot -ThreadId $rolloutThread -StartedAtUtc '2026-09-14T00:00:00.0000000Z'
        Assert-True ((Get-DispatchEvidenceValue -Evidence $runtime.model) -ceq 'fixture-model' -and (Get-DispatchEvidenceValue -Evidence $runtime.reasoning_effort) -ceq 'high') 'runtime model／effort evidence 異常。'
        Assert-True ($runtime.model.source -eq 'rollout' -and @($runtime.rollout_paths).Count -eq 1) 'runtime rollout source 異常。'
    }
    Invoke-Case 'Rollout 非 exact session 轉 unknown' {
        $runtime = Get-RuntimeModelEvidence -CodexHome $profileFixtureRoot -ThreadId ([guid]::NewGuid().ToString('D')) -StartedAtUtc '2026-09-14T00:00:00.0000000Z'
        Assert-True ($runtime.model.status -eq 'unknown' -and $runtime.model.source -eq 'rollout-session-not-found') '非 exact session 被採用。'
    }
    Invoke-Case 'Rollout 多筆值衝突轉 unknown' {
        $conflictRolloutPath = Join-Path $profileSessionsRoot 'rollout-conflict.jsonl'
        $conflictEvents = @(
            [ordered]@{ type = 'session_meta'; payload = [ordered]@{ id = $rolloutThread } }
            [ordered]@{ type = 'turn_context'; timestamp = '2026-09-14T00:00:02.0000000Z'; payload = [ordered]@{ model = 'fixture-model'; effort = 'high' } }
            [ordered]@{ type = 'turn_context'; timestamp = '2026-09-14T00:00:03.0000000Z'; payload = [ordered]@{ model = 'other-model'; effort = 'high' } }
        )
        Write-Utf8NoBom -Path $conflictRolloutPath -Content (($conflictEvents | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 }) -join "
")
        $runtime = Get-RuntimeModelEvidence -CodexHome $profileFixtureRoot -ThreadId $rolloutThread -StartedAtUtc '2026-09-14T00:00:00.0000000Z'
        Assert-True ($runtime.model.status -eq 'unknown' -and $runtime.model.source -eq 'rollout-values-conflict') 'runtime 衝突未轉 unknown。'
    }
    Invoke-Case 'Requested omitted 不影響 evidence pair 判定' {
        $requested = New-RequestedDispatchEvidence -Value $null -Field 'Model'
        $resolved = New-ConfirmedDispatchEvidence -Value 'fixture-model' -Source 'profile-config' -Field 'model'
        $runtime = New-ConfirmedDispatchEvidence -Value 'fixture-model' -Source 'rollout' -Field 'payload.model'
        $group = New-ModelEvidence -RequestedModel $requested -ResolvedModel $resolved -RuntimeModel $runtime -RequestedReasoningEffort (New-RequestedDispatchEvidence -Value $null -Field 'ReasoningEffort') -ResolvedReasoningEffort (New-ConfirmedDispatchEvidence -Value 'high' -Source 'profile-config' -Field 'model_reasoning_effort') -RuntimeReasoningEffort (New-ConfirmedDispatchEvidence -Value 'high' -Source 'rollout' -Field 'payload.effort')
        Assert-True ($group.model.requested.status -eq 'unknown' -and (Test-DispatchEvidencePair -EvidenceGroup $group.model).eligible) 'requested unknown 錯誤使 evidence pair 失格。'
    }
    Invoke-Case 'Calibration unknown 與 resolved runtime mismatch 不收樣' {
        $unknown = New-ModelEvidence -RequestedModel (New-RequestedDispatchEvidence -Value $null -Field 'Model') -ResolvedModel (New-UnknownDispatchEvidence -Field 'model' -Reason 'fixture unknown') -RuntimeModel (New-UnknownDispatchEvidence -Field 'payload.model' -Reason 'fixture unknown') -RequestedReasoningEffort (New-RequestedDispatchEvidence -Value $null -Field 'ReasoningEffort') -ResolvedReasoningEffort (New-UnknownDispatchEvidence -Field 'model_reasoning_effort' -Reason 'fixture unknown') -RuntimeReasoningEffort (New-UnknownDispatchEvidence -Field 'payload.effort' -Reason 'fixture unknown')
        $estimate = Get-CalibrationEstimate -Path (Join-Path $fixtureRoot 'missing-calibration.jsonl') -ModelEvidence $unknown.model -ReasoningEffortEvidence $unknown.reasoning_effort -Profile 'default' -SessionMode 'cold-start' -TaskType 'script-change'
        Assert-True ($null -eq $estimate.estimate -and $estimate.source -eq 'evidence-unknown') 'unknown evidence 被轉成 calibration estimate。'
        $mismatch = New-ModelEvidence -RequestedModel (New-RequestedDispatchEvidence -Value $null -Field 'Model') -ResolvedModel (New-ConfirmedDispatchEvidence -Value 'fixture-model' -Source 'profile-config' -Field 'model') -RuntimeModel (New-ConfirmedDispatchEvidence -Value 'other-model' -Source 'rollout' -Field 'payload.model') -RequestedReasoningEffort (New-RequestedDispatchEvidence -Value $null -Field 'ReasoningEffort') -ResolvedReasoningEffort (New-ConfirmedDispatchEvidence -Value 'high' -Source 'profile-config' -Field 'model_reasoning_effort') -RuntimeReasoningEffort (New-ConfirmedDispatchEvidence -Value 'high' -Source 'rollout' -Field 'payload.effort')
        Assert-True (-not (Test-DispatchEvidencePair -EvidenceGroup $mismatch.model).eligible) 'resolved／runtime mismatch 仍可收樣。'
    }

    $phase2EvidenceRoot = Join-Path $fixtureRoot 'advisor-evidence'
    New-Item -ItemType Directory -Path $phase2EvidenceRoot -Force | Out-Null
    $phase2EvidencePackPath = Join-Path $phase2EvidenceRoot 'pack.md'
    $evidencePackContent = @(
        'schema: advisor-consult.evidence.v1'
        'line-slug: line-a'
        'dispatch-slug: phase-2'
        ''
        '## 目標段落'
        ''
        'source: design.md:1'
        'excerpt: fixture evidence pack'
        ''
        '## 已知結論'
        ''
        'conclusion: fixture conclusion'
        ''
        '## 待答問題'
        ''
        'question-001: fixture question'
        'question-002: fixture second question'
        'required-output: ## 中斷保全結論; ## 證據支持; ## 推論; ## 未決問題'
        'output-rules: 每一個問題需以 question-<id> 回報完成狀態'
        ''
        '## 可能反證'
        ''
        'counterexample: fixture counterexample'
        ''
        '## 邊界'
        ''
        'boundary: fixture boundary'
        ''
        '- allowed-input: this evidence pack only'
        '- forbidden-action: source exploration, repository scan, file mutation, external dispatch'
    ) -join "
"
    Write-Utf8NoBom -Path $phase2EvidencePackPath -Content ($evidencePackContent + "
")
    Invoke-Case 'Evidence pack required-output 與 inline hash length' {
        $pack = Test-AdvisorEvidencePack -Path $phase2EvidencePackPath -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug 'phase-2'
        $directive = New-AdvisorInlineEvidenceDirective -EvidencePackInfo $pack
        $inline = Test-AdvisorInlineEvidenceDirective -PromptContent $directive -EvidencePackInfo $pack
        Assert-True ($pack.length -gt 0 -and $pack.sha256 -match '^[a-f0-9]{64}$' -and @($pack.required_output).Count -eq 4 -and @($pack.question_units).Count -eq 2 -and $inline.valid) 'inline advisor evidence pack contract 異常。'
    }
    Invoke-Case 'Evidence pack required-output 缺失或重複拒絕' -Reject {
        $invalidPackPath = Join-Path $phase2EvidenceRoot 'invalid.md'
        Write-Utf8NoBom -Path $invalidPackPath -Content ($evidencePackContent -replace '(?m)^required-output:.*\r?\n', '')
        Test-AdvisorEvidencePack -Path $invalidPackPath -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug 'phase-2'
    }
    Invoke-Case 'Inline evidence 截短拒絕' {
        $pack = Test-AdvisorEvidencePack -Path $phase2EvidencePackPath -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug 'phase-2'
        $directive = New-AdvisorInlineEvidenceDirective -EvidencePackInfo $pack
        $truncated = $directive.Replace($pack.content, $pack.content.Substring(0, [Math]::Max(1, $pack.content.Length - 8)))
        $inline = Test-AdvisorInlineEvidenceDirective -PromptContent $truncated -EvidencePackInfo $pack
        Assert-True (-not $inline.valid -and -not $inline.has_full_content) '截短 inline evidence 未拒絕。'
    }
    Invoke-Case 'Required output heading body gate' {
        $required = @('## 中斷保全結論', '## 證據支持', '## 推論', '## 未決問題')
        $validGate = Test-RequiredOutputSections -Message "## 中斷保全結論
completed
## 證據支持
supported
## 推論
inferred
## 未決問題
none" -RequiredOutput $required
        $invalidGate = Test-RequiredOutputSections -Message "## 中斷保全結論

## 證據支持
supported" -RequiredOutput $required
        Assert-True ($validGate.valid -and $invalidGate.missing -contains '## 中斷保全結論' -and $invalidGate.missing -contains '## 推論') 'required output body gate 異常。'
    }
    Invoke-Case 'Event diagnostic model 保留原文' {
        $diagnosticPath = Join-Path $phase2EvidenceRoot 'diagnostic.jsonl'
        Write-Utf8NoBom -Path $diagnosticPath -Content '{"type":"turn.failed","error":{"message":"recorded with model fixture-model"}}'
        $diagnostic = Get-OriginalThreadModelEvidence -AnchorRecord ([pscustomobject]@{ event_stream_path = $diagnosticPath })
        Assert-True ($diagnostic.status -eq 'confirmed' -and $diagnostic.value -ceq 'fixture-model' -and $diagnostic.raw_line.Contains('recorded with model fixture-model')) '原始 model diagnostic 未保留。'
    }

    Invoke-Case 'Inspect 事件權威與一致性成功' {
        $result = Invoke-Inspect
        Assert-True ($result.success -and $result.outputValid -and $result.lastMessageConsistency -eq 'Match' -and $result.finalMessageSource -eq 'event-stream' -and $script:observedExecution.success) '成功 gate 不一致。'
    }
    Invoke-Case 'Inspect BOM CRLF CR 與尾端換行可正規化' {
        try {
            $events = @(
                @{ type = 'thread.started'; thread_id = $script:testThread }
                @{ type = 'item.completed'; item = @{ type = 'agent_message'; text = "design.md
dispatch-a
line-a" } }
                @{ type = 'turn.completed'; usage = @{ input_tokens = 1; output_tokens = 1 } }
            )
            Write-Utf8NoBom $a.event_stream_path (($events | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 }) -join "
")
            Write-Utf8NoBom $a.last_message_path ([char]0xFEFF + "design.md
dispatch-a
line-a

")
            Assert-True ((Invoke-Inspect).success) '允許的換行差異被拒絕。'
        } finally { Write-TestEvents $a.event_stream_path $script:testThread; Write-Utf8NoBom $a.last_message_path 'design.md dispatch-a line-a' }
    }
    foreach ($message in @('design.md dispatch-a line-a ', 'Design.md dispatch-a line-a', "design.md dispatch-a

line-a")) {
        Invoke-Case ('Inspect 保留空格大小寫段落差異 ' + $message) {
            try {
                Write-Utf8NoBom $a.last_message_path $message
                $result = Invoke-Inspect
                Assert-True (-not $result.success -and -not $result.outputValid -and $result.lastMessageConsistency -eq 'Mismatch' -and -not $script:observedExecution.success -and $result.finalMessage -ceq 'design.md dispatch-a line-a') '不一致仍成功或改用外部訊息。'
            } finally { Write-Utf8NoBom $a.last_message_path 'design.md dispatch-a line-a' }
        }
    }
    Invoke-Case 'Inspect 同 dispatch 前輪即使相同內容仍拒絕' {
        $EventStreamPath = $a2.event_stream_path
        $LastMessagePath = $a.last_message_path
        $result = Invoke-Inspect
        Assert-True (-not $result.success -and $result.lastMessageConsistency -eq 'BindingMismatch' -and -not $script:observedExecution.success) '前輪路徑未拒絕。'
    }
    Invoke-Case 'Inspect 僅移除一個 BOM' {
        try {
            Write-Utf8NoBom $a.last_message_path ([string][char]0xFEFF + [char]0xFEFF + 'design.md dispatch-a line-a')
            Assert-True ((Invoke-Inspect).lastMessageConsistency -eq 'Mismatch') '移除了兩個 BOM。'
        } finally { Write-Utf8NoBom $a.last_message_path 'design.md dispatch-a line-a' }
    }
    Invoke-Case 'Inspect 識別字僅在外部不成功' {
        $RequiredIdentifier = 'external-only'
        try { Write-Utf8NoBom $a.last_message_path 'external-only design.md dispatch-a line-a'; Assert-True (-not (Invoke-Inspect).success) '採用外部識別字。' }
        finally { Write-Utf8NoBom $a.last_message_path 'design.md dispatch-a line-a' }
    }
    Invoke-Case 'Inspect 省略外部缺檔可使用事件' {
        try {
            Move-Item $a.last_message_path ($a.last_message_path + '.saved')
            $result = Invoke-Inspect
            Assert-True ($result.success -and $result.lastMessageConsistency -eq 'Missing') '省略缺檔未使用事件。'
        } finally { Move-Item ($a.last_message_path + '.saved') $a.last_message_path }
    }
    Invoke-Case 'Inspect 顯式缺檔拒絕' -Reject -ErrorPattern '缺失或空白' {
        $LastMessagePath = $a.last_message_path
        try { Move-Item $a.last_message_path ($a.last_message_path + '.saved'); Invoke-Inspect }
        finally { Move-Item ($a.last_message_path + '.saved') $a.last_message_path }
    }
    Invoke-Case 'Inspect 顯式空白拒絕' -Reject -ErrorPattern '缺失或空白' {
        $LastMessagePath = $a.last_message_path
        try { Write-Utf8NoBom $a.last_message_path ' '; Invoke-Inspect }
        finally { Write-Utf8NoBom $a.last_message_path 'design.md dispatch-a line-a' }
    }
    Invoke-Case 'Inspect 缺事件訊息拒絕' -Reject -ErrorPattern '最後 agent_message' {
        try {
            $lines = Get-Content $a.event_stream_path | Where-Object { $_ -notmatch 'agent_message' }
            Write-Utf8NoBom $a.event_stream_path ($lines -join "
")
            Invoke-Inspect
        } finally { Write-TestEvents $a.event_stream_path $script:testThread }
    }
    Invoke-Case 'Inspect 未完成訊息不取代最後完整訊息' {
        try {
            $lines = @(Get-Content $a.event_stream_path)
            $incomplete = @{ type = 'item.updated'; item = @{ type = 'agent_message'; text = 'incomplete' } } | ConvertTo-Json -Depth 5 -Compress
            Write-Utf8NoBom $a.event_stream_path (($lines[0..1] + $incomplete + $lines[2]) -join "
")
            Assert-True ((Invoke-Inspect).success) '採用尚未完成的訊息。'
        } finally { Write-TestEvents $a.event_stream_path $script:testThread }
    }
    Invoke-Case 'Inspect 一致仍受 exit code gate 約束' { $ProcessExitCode = 1; Assert-True (-not (Invoke-Inspect).success) 'exit code gate 被略過。' }
    Invoke-Case 'Inspect 一致仍受 turn.failed gate 約束' {
        try { Write-TestEvents $a.event_stream_path $script:testThread 'turn.failed'; Assert-True (-not (Invoke-Inspect).success) 'turn gate 被略過。' }
        finally { Write-TestEvents $a.event_stream_path $script:testThread }
    }
    Invoke-Case 'Inspect 靜態移除外部優先與檢查 success gate' {
        $inspectText = ($functions | Where-Object { $_.Name -eq 'Invoke-Inspect' }).Extent.Text
        Assert-True ($inspectText -notmatch '\$finalMessage = Get-Content' -and $inspectText.Contains('$finalMessage = $lastAgentMessage') -and $inspectText.Contains('-and $outputValid')) '外部優先或 success 缺漏。'
    }
    Invoke-Case 'Inspect 不一致校準觀測不得 eligible' {
        . ([scriptblock]::Create(($functions | Where-Object { $_.Name -eq 'Add-CalibrationObservation' }).Extent.Text))
        function Test-ScopePlanCompleteness { return $true }
        function Test-QuotaResetWindowChanged { return $false }
        function Get-QuotaSnapshotDelta { return 1 }
        function Test-QuotaSnapshotFresh { return $true }
        function Add-AtomicJsonLine { param($Path, $Content) $script:calibrationRecord = ConvertFrom-DispatchJson $Content }
        function Get-CalibrationRecords { return @() }
        $arguments = @{ SourceRoot = $fixtureRoot; LineSlug = 'line-a'; DispatchSlug = 'dispatch-a'; Profile = 'default'; Model = 'fixture'; ReasoningEffort = 'high'; TaskType = 'fixture'; SessionMode = 'cold-start'; Usage = [pscustomobject]@{ input_tokens = 1; output_tokens = 1 }; ScopePlan = @{ primary_budget_percent = 10 }; BudgetMonitor = @() }
        $good = Add-CalibrationObservation @arguments -ExecutionResult ([pscustomobject]@{ completed = $true; processExitCode = 0; success = $true; outputValid = $true })
        Assert-True $good.calibrationEligible ('正向校準 fixture 未通過。' + ($script:calibrationRecord | ConvertTo-Json -Depth 8 -Compress))
        foreach ($state in @('Mismatch', 'BindingMismatch')) {
            $bad = Add-CalibrationObservation @arguments -ExecutionResult ([pscustomobject]@{ completed = $true; processExitCode = 0; success = $false; outputValid = $false })
            Assert-True (-not $bad.calibrationEligible -and -not $script:calibrationRecord.calibration_eligible) ($state + ' 仍被列入校準。')
        }
    }
}
$DispatchSlug = 'start-case'
$PreflightResultPath = Join-Path $fixtureRoot 'start-preflight.json'
Write-Utf8NoBom $PreflightResultPath ((@{ sourceRoot = $fixtureRoot; executionRoot = $fixtureRoot; lineSlug = $LineSlug; dispatchSlug = $DispatchSlug; writeMode = 'readonly' } | ConvertTo-Json))
$PromptPath = Join-Path $fixtureRoot 'prompt.md'
Write-Utf8NoBom $PromptPath 'fixture'
$ScopePlanPath = $null
$script:startCalls = 0
$script:failLaunch = $false
Invoke-Case 'Start prepared → started 與唯一事件路徑' {
    $script:startedResult = Invoke-Start
    $record = Read-DispatchRunRecord -Path $script:startedResult.runRecordPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    $record.model_evidence.runtime_verifiable = New-ConfirmedDispatchEvidence -Value 'fixture-model' -Source 'rollout' -Field 'payload.model'
    $null = Write-DispatchRunRecord -Record $record -Update
    Assert-True ($record.launch_state -eq 'started' -and $record.thread_id -eq $script:testThread -and $record.event_stream_path.Contains($record.run_id)) 'Start 紀錄不符。'
}
Invoke-Case 'Start 啟動失敗保存 launch-failed' {
    $script:failLaunch = $true
    $DispatchSlug = 'failure-case'
    $PreflightResultPath = Join-Path $fixtureRoot 'failure-preflight.json'
    Write-Utf8NoBom $PreflightResultPath ((@{ sourceRoot = $fixtureRoot; executionRoot = $fixtureRoot; lineSlug = $LineSlug; dispatchSlug = $DispatchSlug } | ConvertTo-Json))
    $caught = $false
    $failureMessage = ''
    try { Invoke-Start } catch { $failureMessage = $_.Exception.Message; $caught = $failureMessage.Contains('fixture launch failure') }
    Assert-True $caught ('未到達模擬啟動失敗。' + $failureMessage)
    $recordPath = @(Get-ChildItem (Get-DispatchRunDirectory $fixtureRoot $LineSlug $DispatchSlug) -Filter '*.json')[0].FullName
    $record = Read-DispatchRunRecord -Path $recordPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    Assert-True ($record.launch_state -eq 'launch-failed') '未保存失敗紀錄。'
    $script:failLaunch = $false
}
Invoke-Case 'Start prepared 落檔失敗不得啟動' {
    $before = $script:startCalls
    $DispatchSlug = 'blocked-write'
    $PreflightResultPath = Join-Path $fixtureRoot 'blocked-preflight.json'
    Write-Utf8NoBom $PreflightResultPath ((@{ sourceRoot = $fixtureRoot; executionRoot = $fixtureRoot; lineSlug = $LineSlug; dispatchSlug = $DispatchSlug } | ConvertTo-Json))
    $directory = Get-DispatchRunDirectory $fixtureRoot $LineSlug $DispatchSlug
    Write-Utf8NoBom $directory 'block directory'
    $caught = $false
    try { Invoke-Start } catch { $caught = $true }
    Assert-True ($caught -and $script:startCalls -eq $before) '落檔失敗仍啟動。'
}
Invoke-Case 'Start 已有紀錄拒絕另建首輪' -Reject -ErrorPattern '同派遣最新 RunRecord|同派遣已有 RunRecord' { Invoke-Start }
Invoke-Case 'Start 自訂既有 last-message 拒絕覆寫' -Reject -ErrorPattern 'LastMessagePath 已存在' {
    $DispatchSlug = 'existing-output'
    $PreflightResultPath = Join-Path $fixtureRoot 'existing-preflight.json'
    Write-Utf8NoBom $PreflightResultPath ((@{ sourceRoot = $fixtureRoot; executionRoot = $fixtureRoot; lineSlug = $LineSlug; dispatchSlug = $DispatchSlug } | ConvertTo-Json))
    $LastMessagePath = $a.last_message_path
    Invoke-Start
}
Invoke-Case 'Start Resume 建立新輪並保留前輪訊息' {
    $ResumeThreadId = $script:testThread
    $ScopePlanPath = $script:startedResult.scopePlanPath
    $LastMessagePath = $script:startedResult.lastMessagePath
    Write-Utf8NoBom $LastMessagePath '前輪成果'
    $result = Invoke-Start
    $record = Read-DispatchRunRecord -Path $result.runRecordPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    Assert-True ($record.previous_run_id -eq $script:startedResult.runId -and $record.last_message_path -ne $LastMessagePath -and (Get-Content $LastMessagePath -Raw -Encoding UTF8) -eq '前輪成果') '續行覆寫或未綁定前輪。'
}
Invoke-Case 'Start relay 失敗保留 launch-failed 與事件' {
    $DispatchSlug = 'relay-failure'
    $PreflightResultPath = Join-Path $fixtureRoot 'relay-preflight.json'
    Write-Utf8NoBom $PreflightResultPath ((@{ sourceRoot = $fixtureRoot; executionRoot = $fixtureRoot; lineSlug = $LineSlug; dispatchSlug = $DispatchSlug } | ConvertTo-Json))
    $script:relayFailure = $true
    $caught = $false
    try { Invoke-Start } catch { $caught = $_.Exception.Message.Contains('thread relay not-ready') } finally { $script:relayFailure = $false }
    Assert-True $caught '未到達 relay 失敗路徑。'
    $path = @(Get-ChildItem (Get-DispatchRunDirectory $fixtureRoot $LineSlug $DispatchSlug) -Filter '*.json')[0].FullName
    $record = Read-DispatchRunRecord -Path $path -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    Assert-True ($record.launch_state -eq 'launch-failed' -and (Test-Path $record.event_stream_path)) 'relay 失敗未保存紀錄或事件。'
}
$startText = ($functions | Where-Object { $_.Name -eq 'Invoke-Start' }).Extent.Text
Invoke-Case '移除修改時間排序與檔名反推' {
    Assert-True ($startText -notmatch 'LastWriteTimeUtc|continuationTimestamp|previousLastMessages|GetFileNameWithoutExtension') '舊路徑殘留。'
    Assert-True ($startText.Contains('Resolve-PreviousDispatchRun') -and $startText.Contains('-LastMessagePath $LastMessagePath')) '顯式路徑未共用驗證。'
}
Invoke-Case 'Phase 2 advisor active source removal' {
    Assert-ActiveSourceNotFound -Label 'Phase 2' -Terms $phase2RemovalTerms
}

if ($Phase -ge 3) {
    function New-Phase3FailedRecord {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][psobject]$Record,
            [Parameter(Mandatory)][string]$Message,
            [switch]$PreparationWithoutScope
        )

        $Record.launch_state = 'launch-failed'
        $Record.started_at_utc = $null
        if ($PreparationWithoutScope) {
            $Record.scope_plan_path = $null
            $Record.scope_plan_sha256 = $null
        }
        $Record.failure = New-DispatchFailureRecord -Phase 'preparation' -Message $Message -ProcessStarted $false -EventPath $Record.event_stream_path -ErrorPath $null -LastMessagePath $Record.last_message_path -ThreadPath $null -PidPath $Record.pid_record_path -LauncherPath $null -RolloutPaths @() -Observation ([ordered]@{ process_started = $false; process_exit_code = $null; fixture = $true })
        $null = Write-DispatchRunRecord -Record $Record -Update
        return Read-DispatchRunRecord -Path (Join-Path (Get-DispatchRunDirectory $fixtureRoot $Record.line_slug $Record.dispatch_slug) ($Record.run_id + '.json')) -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug $Record.line_slug -DispatchSlug $Record.dispatch_slug
    }

    Invoke-Case 'Phase 3 preparation failure 建立 failed envelope' {
        $DispatchSlug = 'phase3-prep-failure'
        $PreflightResultPath = Join-Path $fixtureRoot 'phase3-prep-preflight.json'
        $PromptPath = Join-Path $fixtureRoot 'phase3-prep-prompt.md'
        Write-Utf8NoBom -Path $PreflightResultPath -Content (([ordered]@{ sourceRoot = $fixtureRoot; executionRoot = $fixtureRoot; lineSlug = $LineSlug; dispatchSlug = $DispatchSlug; writeMode = 'readonly' } | ConvertTo-Json))
        Write-Utf8NoBom -Path $PromptPath -Content 'fixture'
        $Model = 'wrong-model'
        $beforeStartCalls = $script:startCalls
        $caughtException = $null
        try { Invoke-Start } catch { $caughtException = $_.Exception }
        Assert-True ($null -ne $caughtException) '準備失敗未回傳例外。'
        $operationResult = $caughtException.Data['operationResult']
        Assert-True ($null -ne $operationResult -and $operationResult.errorCode -eq 'RequestedResolutionMismatch' -and -not $operationResult.processStarted) '準備失敗未回傳結構化結果。'
        $recordPath = @(
            Get-ChildItem (Get-DispatchRunDirectory $fixtureRoot $LineSlug $DispatchSlug) -Filter '*.json' -File |
                Where-Object {
                    $candidate = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    $candidate.launch_state -eq 'launch-failed'
                } |
                Select-Object -First 1
        )[0].FullName
        $record = Read-DispatchRunRecord -Path $recordPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        Assert-True ($record.launch_state -eq 'launch-failed' -and $record.failure.phase -eq 'preparation' -and $record.failure.reason_code -eq 'RequestedResolutionMismatch' -and $null -eq $record.scope_plan_path -and $record.failure.original_output.raw_message.Contains('wrong-model') -and $script:startCalls -eq $beforeStartCalls) '準備失敗 envelope 欄位或啟動 gate 異常。'
    }

    $phase3ColdSeed = New-TestRun -Line 'line-a' -Dispatch 'phase3-cold-start'
    $phase3ColdSeed = New-Phase3FailedRecord -Record $phase3ColdSeed -Message 'phase3 cold-start seed failure' -PreparationWithoutScope
    Invoke-Case 'latest failed 允許新的 cold-start 並保留舊紀錄' {
        $DispatchSlug = 'phase3-cold-start'
        $PreflightResultPath = $phase3ColdSeed.preflight_result_path
        $PromptPath = Join-Path $fixtureRoot 'phase3-cold-prompt.md'
        $ScopePlanPath = $null
        $ResumeThreadId = $null
        $LastMessagePath = $null
        Write-Utf8NoBom -Path $PromptPath -Content 'fixture'
        $latest = Resolve-LatestColdStartFailure -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        Assert-True ($latest.run_id -eq $phase3ColdSeed.run_id) 'latest failed gate 未選到最新失敗。'
        $result = Invoke-Start
        $records = @(Get-ChildItem (Get-DispatchRunDirectory $fixtureRoot $LineSlug $DispatchSlug) -Filter '*.json' -File | ForEach-Object { Read-DispatchRunRecord -Path $_.FullName -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug })
        $newRecord = @($records | Where-Object { $_.run_id -cne $phase3ColdSeed.run_id -and $_.launch_state -eq 'started' })[0]
        $oldRecord = @($records | Where-Object { $_.run_id -ceq $phase3ColdSeed.run_id })[0]
        Assert-True ($records.Count -eq 2 -and $result.runId -eq $newRecord.run_id -and $newRecord.previous_run_id -eq $null -and $newRecord.attempt_parent_run_id -eq $phase3ColdSeed.run_id -and $oldRecord.failure.message -ceq 'phase3 cold-start seed failure') 'cold-start 未沿用 failed attempt 或覆寫舊紀錄。'
    }

    $phase3RootAbsentSeed = New-TestRun -Line 'line-a' -Dispatch 'phase3-root-absent'
    $phase3RootAbsentSeed = New-Phase3FailedRecord -Record $phase3RootAbsentSeed -Message 'phase3 root absent seed failure' -PreparationWithoutScope
    Invoke-Case 'latest failed root-process-absent 視為已結束' {
        $script:pidResult.ActiveRecords = @()
        $script:pidResult.UnconfirmedRecords = @([pscustomobject]@{ DispatchSlug = 'phase3-root-absent'; IdentityStatus = 'root-process-absent' })
        try {
            $latest = Resolve-LatestColdStartFailure -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug 'phase3-root-absent'
            Assert-True ($latest.run_id -eq $phase3RootAbsentSeed.run_id) 'root-process-absent 未被視為已結束。'
        }
        finally {
            $script:pidResult.UnconfirmedRecords = @()
        }
    }

    function Invoke-Phase3IdentityFailureCase {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$CaseDispatchSlug,
            [Parameter(Mandatory)][ValidateSet('missing', 'unconfirmed')][string]$SnapshotMode
        )

        $DispatchSlug = $CaseDispatchSlug
        $PreflightResultPath = Join-Path $fixtureRoot ($CaseDispatchSlug + '-preflight.json')
        $PromptPath = Join-Path $fixtureRoot ($CaseDispatchSlug + '-prompt.md')
        $CodexHome = $startCodexHome
        $Model = $null
        $ReasoningEffort = $null
        $ResumeThreadId = $null
        $ScopePlanPath = $null
        $LastMessagePath = $null
        Write-Utf8NoBom -Path $PreflightResultPath -Content (([ordered]@{ sourceRoot = $fixtureRoot; executionRoot = $fixtureRoot; lineSlug = $LineSlug; dispatchSlug = $CaseDispatchSlug; writeMode = 'readonly' } | ConvertTo-Json))
        Write-Utf8NoBom -Path $PromptPath -Content 'fixture'
        $script:startSnapshotMode = $SnapshotMode
        $caughtException = $null
        try { Invoke-Start } catch { $caughtException = $_.Exception } finally { $script:startSnapshotMode = 'confirmed' }
        $operationResult = if ($null -eq $caughtException) { $null } else { $caughtException.Data['operationResult'] }
        $recordPath = @(
            Get-ChildItem (Get-DispatchRunDirectory $fixtureRoot $LineSlug $CaseDispatchSlug) -Filter '*.json' -File |
                Where-Object {
                    $candidate = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    $candidate.launch_state -eq 'launch-failed'
                } |
                Select-Object -First 1
        )[0].FullName
        $record = Read-DispatchRunRecord -Path $recordPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $CaseDispatchSlug
        $pidLines = Get-Content -LiteralPath $record.pid_record_path -Encoding UTF8
        $pidText = $pidLines -join [Environment]::NewLine
        Assert-True ($null -ne $operationResult -and $operationResult.processStarted -and $operationResult.errorCode -eq 'ProcessIdentityUnknown' -and $record.failure.reason_code -eq 'ProcessIdentityUnknown' -and (Test-Path -LiteralPath $record.pid_record_path -PathType Leaf) -and $pidText -match '(?m)^identity-verified=false\r?$' -and $pidText -match '(?m)^identity-status=.*\r?$') ($SnapshotMode + ' 未保存未確認身分 PID 紀錄。')
        $script:pidResult.UnconfirmedRecords = @([pscustomobject]@{ DispatchSlug = $CaseDispatchSlug; IdentityStatus = 'record-identity-unconfirmed' })
        $blocked = $false
        try { Resolve-LatestColdStartFailure -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $CaseDispatchSlug | Out-Null } catch { $blocked = $true }
        $script:pidResult.UnconfirmedRecords = @()
        Assert-True $blocked ($SnapshotMode + ' 身分未確認程序未阻擋下一次 cold-start。')
    }
    Invoke-Case 'Start 身分驗證失敗保存未確認 PID 並阻擋 cold-start' {
        Invoke-Phase3IdentityFailureCase -CaseDispatchSlug 'phase3-identity-failure' -SnapshotMode 'unconfirmed'
    }
    Invoke-Case 'Start snapshot 缺失保存未確認 PID 並阻擋 cold-start' {
        Invoke-Phase3IdentityFailureCase -CaseDispatchSlug 'phase3-snapshot-missing' -SnapshotMode 'missing'
    }

    $phase3ChainAnchor = New-TestRun -Line 'line-a' -Dispatch 'phase3-failed-chain'
    $phase3FailedOne = New-TestRun -Line 'line-a' -Dispatch 'phase3-failed-chain' -Previous $phase3ChainAnchor
    $phase3FailedOne = New-Phase3FailedRecord -Record $phase3FailedOne -Message 'phase3 failed attempt one'
    $phase3FailedTwo = New-TestRun -Line 'line-a' -Dispatch 'phase3-failed-chain' -Previous $phase3FailedOne
    $phase3FailedTwo = New-Phase3FailedRecord -Record $phase3FailedTwo -Message 'phase3 failed attempt two'
    Invoke-Case 'Resume chain 跳過連續 failed attempts 並回到 anchor' {
        $chain = Resolve-PreviousDispatchRun -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug 'phase3-failed-chain' -ResumeThreadId $script:testThread
        Assert-True ($chain.AnchorRecord.run_id -eq $phase3ChainAnchor.run_id -and $chain.ChainTailRecord.run_id -eq $phase3FailedTwo.run_id -and @($chain.SkippedAttempts).Count -eq 2 -and $chain.SkippedAttempts[0].run_id -eq $phase3FailedOne.run_id -and $chain.SkippedAttempts[1].reason_code -ceq $phase3FailedTwo.failure.reason_code) 'failed chain skip 或 anchor 回溯異常。'
    }

    $phase3MismatchAnchor = New-TestRun -Line 'line-a' -Dispatch 'phase3-model-mismatch'
    $phase3MismatchHome = Join-Path $fixtureRoot 'phase3-mismatch-home'
    New-Item -ItemType Directory -Path $phase3MismatchHome -Force | Out-Null
    Write-Utf8NoBom -Path (Join-Path $phase3MismatchHome 'config.toml') -Content "model = 'other-model'
model_reasoning_effort = 'high'
"
    Invoke-Case 'Resume model mismatch 在 process.Start 前阻擋' {
        $DispatchSlug = 'phase3-model-mismatch'
        $PreflightResultPath = $phase3MismatchAnchor.preflight_result_path
        $PromptPath = Join-Path $fixtureRoot 'phase3-model-mismatch-prompt.md'
        $CodexHome = $phase3MismatchHome
        $ResumeThreadId = $phase3MismatchAnchor.thread_id
        $ScopePlanPath = $phase3MismatchAnchor.scope_plan_path
        $LastMessagePath = $phase3MismatchAnchor.last_message_path
        Write-Utf8NoBom -Path $PromptPath -Content 'fixture'
        $beforeStartCalls = $script:startCalls
        $caughtException = $null
        try { Invoke-Start } catch { $caughtException = $_.Exception }
        $operationResult = if ($null -eq $caughtException) { $null } else { $caughtException.Data['operationResult'] }
        $recordPath = @(
            Get-ChildItem (Get-DispatchRunDirectory $fixtureRoot $LineSlug $DispatchSlug) -Filter '*.json' -File |
                Where-Object {
                    $candidate = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    $candidate.launch_state -eq 'launch-failed'
                } |
                Select-Object -First 1
        )[0].FullName
        $record = Read-DispatchRunRecord -Path $recordPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        Assert-True ($null -ne $operationResult -and $operationResult.errorCode -eq 'ThreadModelMismatch' -and -not $operationResult.processStarted -and $record.failure.reason_code -eq 'ThreadModelMismatch' -and $record.resume_diagnostics.status -eq 'mismatch' -and $record.attempt_parent_run_id -eq $phase3MismatchAnchor.run_id -and $record.resume_anchor_run_id -eq $phase3MismatchAnchor.run_id -and $script:startCalls -eq $beforeStartCalls) 'ThreadModelMismatch 未在 process.Start 前結構化阻擋。'
    }

    $phase3ProfileAnchor = New-TestRun -Line 'line-a' -Dispatch 'phase3-profile-change'
    $phase3ProfileHome = Join-Path $fixtureRoot 'phase3-profile-change-home'
    $phase3ProfileConfigPath = Join-Path $phase3ProfileHome 'config.toml'
    New-Item -ItemType Directory -Path $phase3ProfileHome -Force | Out-Null
    $phase3ProfileConfigContent = "model = 'fixture-model'
model_reasoning_effort = 'high'
"
    Write-Utf8NoBom -Path $phase3ProfileConfigPath -Content $phase3ProfileConfigContent
    Invoke-Case 'Resume compare 後設定檔變更在 launcher 前阻擋' {
        $DispatchSlug = 'phase3-profile-change'
        $PreflightResultPath = $phase3ProfileAnchor.preflight_result_path
        $PromptPath = Join-Path $fixtureRoot 'phase3-profile-change-prompt.md'
        $CodexHome = $phase3ProfileHome
        $ResumeThreadId = $phase3ProfileAnchor.thread_id
        $ScopePlanPath = $phase3ProfileAnchor.scope_plan_path
        $LastMessagePath = $phase3ProfileAnchor.last_message_path
        Write-Utf8NoBom -Path $PromptPath -Content 'fixture'
        $script:profileMutationPath = $phase3ProfileConfigPath
        $script:profileMutationContent = $phase3ProfileConfigContent + "# changed after compare
"
        $script:mutateProfileAfterCompare = $true
        $beforeStartCalls = $script:startCalls
        $caughtException = $null
        try { Invoke-Start } catch { $caughtException = $_.Exception } finally {
            $script:mutateProfileAfterCompare = $false
            Write-Utf8NoBom -Path $phase3ProfileConfigPath -Content $phase3ProfileConfigContent
        }
        $operationResult = if ($null -eq $caughtException) { $null } else { $caughtException.Data['operationResult'] }
        $recordPath = @(
            Get-ChildItem (Get-DispatchRunDirectory $fixtureRoot $LineSlug $DispatchSlug) -Filter '*.json' -File |
                Where-Object {
                    $candidate = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    $candidate.launch_state -eq 'launch-failed'
                } |
                Select-Object -First 1
        )[0].FullName
        $record = Read-DispatchRunRecord -Path $recordPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        Assert-True ($null -ne $operationResult -and $operationResult.errorCode -eq 'ProfileEvidenceUnknown' -and -not $operationResult.processStarted -and $record.failure.reason_code -eq 'ProfileEvidenceUnknown' -and $record.failure.phase -eq 'preparation' -and $script:startCalls -eq $beforeStartCalls) 'Profile config hash recheck 未在 process.Start 前阻擋。'
    }

    $phase3UnknownAnchor = New-TestRun -Line 'line-a' -Dispatch 'phase3-model-unknown'
    $phase3UnknownRecordPath = Join-Path (Get-DispatchRunDirectory $fixtureRoot 'line-a' 'phase3-model-unknown') ($phase3UnknownAnchor.run_id + '.json')
    $phase3UnknownRecord = Read-DispatchRunRecord -Path $phase3UnknownRecordPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug 'phase3-model-unknown'
    $phase3UnknownRecord.model_evidence.runtime_verifiable = New-UnknownDispatchEvidence -Field 'payload.model' -Reason 'phase3 unknown model' -Source 'fixture-unknown'
    $null = Write-DispatchRunRecord -Record $phase3UnknownRecord -Update
    Invoke-Case 'Resume model unknown 不臆測並阻擋' {
        $DispatchSlug = 'phase3-model-unknown'
        $PreflightResultPath = $phase3UnknownAnchor.preflight_result_path
        $PromptPath = Join-Path $fixtureRoot 'phase3-model-unknown-prompt.md'
        $CodexHome = $startCodexHome
        $ResumeThreadId = $phase3UnknownAnchor.thread_id
        $ScopePlanPath = $phase3UnknownAnchor.scope_plan_path
        $LastMessagePath = $phase3UnknownAnchor.last_message_path
        Write-Utf8NoBom -Path $PromptPath -Content 'fixture'
        $caughtException = $null
        try { Invoke-Start } catch { $caughtException = $_.Exception }
        $operationResult = if ($null -eq $caughtException) { $null } else { $caughtException.Data['operationResult'] }
        Assert-True ($null -ne $operationResult -and $operationResult.errorCode -eq 'ThreadModelUnknown' -and -not $operationResult.processStarted) 'ThreadModelUnknown 未保留 unknown 狀態。'
    }

    $phase3FailedInspect = New-TestRun -Line 'line-a' -Dispatch 'phase3-failed-inspect'
    $phase3FailedInspect = New-Phase3FailedRecord -Record $phase3FailedInspect -Message 'phase3 failed inspect without event' -PreparationWithoutScope
    Remove-Item -LiteralPath $phase3FailedInspect.event_stream_path -Force
    Invoke-Case 'Inspect failed Record 直接回傳 diagnosis' {
        $SourceRoot = $fixtureRoot
        $ExecutionRoot = $fixtureRoot
        $LineSlug = 'line-a'
        $DispatchSlug = 'phase3-failed-inspect'
        $EventStreamPath = $phase3FailedInspect.event_stream_path
        $ScopePlanPath = $null
        $RunRecordPath = Join-Path (Get-DispatchRunDirectory $fixtureRoot $LineSlug $DispatchSlug) ($phase3FailedInspect.run_id + '.json')
        $ProcessExitCode = 1
        $result = Invoke-Inspect
        Assert-True (-not $result.success -and $result.diagnosis.reason_code -eq $phase3FailedInspect.failure.reason_code -and $result.calibration.calibrationEligible -eq $false -and $result.errorStreamPath -eq $null) 'failed Inspect 未直接輸出 diagnosis。'
    }

    $phase3UnknownInspect = New-TestRun -Line 'line-a' -Dispatch 'phase3-unknown-inspect'
    $phase3UnknownInspectPath = Join-Path (Get-DispatchRunDirectory $fixtureRoot 'line-a' 'phase3-unknown-inspect') ($phase3UnknownInspect.run_id + '.json')
    Invoke-Case 'turn.failed 無原因使用 Unknown 並保留 raw event' {
        $unknownEvents = @(
            [ordered]@{ type = 'thread.started'; thread_id = $script:testThread }
            [ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'agent_message'; text = 'design.md phase3-unknown-inspect line-a' } }
            [ordered]@{ type = 'turn.failed'; error = [ordered]@{} }
        )
        Write-Utf8NoBom -Path $phase3UnknownInspect.event_stream_path -Content (($unknownEvents | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 }) -join "
")
        $SourceRoot = $fixtureRoot
        $ExecutionRoot = $fixtureRoot
        $LineSlug = 'line-a'
        $DispatchSlug = 'phase3-unknown-inspect'
        $EventStreamPath = $phase3UnknownInspect.event_stream_path
        $ScopePlanPath = $phase3UnknownInspect.scope_plan_path
        $RunRecordPath = $phase3UnknownInspectPath
        $ProcessExitCode = 1
        $RequiredIdentifier = 'design.md'
        $result = Invoke-Inspect
        $rawLines = @($result.diagnosis.original_output.raw_event_lines)
        Assert-True (-not $result.success -and $result.diagnosis.reason_code -eq 'Unknown' -and $result.turnFailedReason -eq '' -and @($rawLines | Where-Object { $_.Contains('"type":"turn.failed"') }).Count -eq 1) 'turn.failed unknown diagnosis 或 raw event 遺失。'
        $errorEvents = @(
            [ordered]@{ type = 'thread.started'; thread_id = $script:testThread }
            [ordered]@{ type = 'error'; message = 'fixture raw failure' }
            [ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'agent_message'; text = 'design.md phase3-unknown-inspect line-a' } }
            [ordered]@{ type = 'turn.failed'; error = [ordered]@{} }
        )
        Write-Utf8NoBom -Path $phase3UnknownInspect.event_stream_path -Content (($errorEvents | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 }) -join "
")
        $resultWithError = Invoke-Inspect
        Assert-True ($resultWithError.diagnosis.reason_code -eq 'CodexLaunchFailed' -and $resultWithError.turnFailedReason -ceq 'fixture raw failure' -and @($resultWithError.diagnosis.original_output.raw_event_lines | Where-Object { $_.Contains('fixture raw failure') }).Count -eq 1) 'turn.failed raw error 未進入 diagnosis。'
    }
}
if ($Phase -ge 3) {
    # Git 替身只提供狀態與路徑清單，baseline 與 Collect 使用真實檔案和 JSON。
    function Invoke-GitCommand {
        param($WorkingDirectory, $Arguments, $StandardInput, [switch]$AllowFailure)
        $command = $Arguments -join ' '
        $output = ''
        if ($Arguments[0] -eq 'ls-tree') {
            $output = (@($gitTree.Keys | Sort-Object | ForEach-Object { $gitTree[$_] + ' blob ' + ('a' * 40) + "`t" + $_ }) -join [char]0) + [char]0
        }
        elseif ($command -eq 'ls-files --stage -z') {
            $output = (@($gitIndex.Keys | Sort-Object | ForEach-Object { $gitIndex[$_] + ' ' + ('b' * 40) + " 0`t" + $_ }) -join [char]0) + [char]0
        }
        elseif ($command -eq 'diff-files --raw -z --') {
            $output = (@($gitWorkingTree.Keys | Sort-Object | ForEach-Object { ':' + $gitIndex[$_] + ' ' + $gitWorkingTree[$_] + ' ' + ('a' * 40) + ' ' + ('0' * 40) + ' M' + [char]0 + $_ }) -join [char]0)
            if ($gitWorkingTree.Count -gt 0) { $output += [char]0 }
        }
        elseif ($command -eq 'ls-files --others --exclude-standard -z') { $output = (@($gitUntracked) -join [char]0) + [char]0 }
        elseif ($command -eq 'ls-files -z') { $output = (@($gitIndex.Keys) -join [char]0) + [char]0 }
        elseif ($Arguments[0] -eq 'rev-parse') { $output = $BaseSha }
        elseif ($Arguments[0] -eq 'diff' -and $Arguments -contains '--cached') { $output = (@($gitStaged) -join [char]0) + [char]0 }
        elseif ($Arguments[0] -eq 'diff') { $output = (@($gitChanged) -join [char]0) + [char]0 }
        elseif ($Arguments[0] -eq 'worktree') { New-Item -ItemType Directory -Path $Arguments[3] -Force | Out-Null }
        else { throw ('未定義 Git fixture：' + $command) }
        return [pscustomobject]@{ ExitCode = 0; StdOut = $output; StdErr = '' }
    }
    function Get-RequirementMap { return [ordered]@{ fixture = $true } }
    function Invoke-BaselineCase {
        param([string]$Name, [scriptblock]$Scenario, [switch]$Reject, [string]$ErrorPattern)
        $SourceRoot = $fixtureRoot
        $LineSlug = 'line-a'
        $DispatchSlug = 'd' + $script:caseCount
        $DispatchRoot = Join-Path $fixtureRoot $DispatchSlug
        $ExecutionRoot = $DispatchRoot
        $BaseSha = 'a' * 40
        $gitTree = @{ 'A.txt' = '100644'; 'deleted.txt' = '100644' }
        $gitIndex = @{ 'A.txt' = '100644'; 'deleted.txt' = '100644' }
        $gitWorkingTree = @{}
        $gitUntracked = @('U.txt')
        $gitChanged = @('A.txt', 'deleted.txt')
        $gitStaged = @()
        $aFile = Join-Path $DispatchRoot 'A.txt'
        $uFile = Join-Path $DispatchRoot 'U.txt'
        Write-Utf8NoBom $aFile 'carry-in tracked'
        Write-Utf8NoBom $uFile 'carry-in untracked'
        $baseline = New-DispatchBaseline -SourceRoot $SourceRoot -DispatchRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -BaseSha $BaseSha
        $prepareRootInfo = Get-PrepareRootInfo -SourceRoot $SourceRoot -ExecutionRoot $DispatchRoot -DispatchRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        $prepareSourcePath = Join-Path $prepareRootInfo.SourceLineRoot 'line.json'
        $prepareDestinationPath = Join-Path $prepareRootInfo.DispatchLineRoot 'line.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $prepareDestinationPath) -Force | Out-Null
        Copy-Item -LiteralPath $prepareSourcePath -Destination $prepareDestinationPath -Force
        $prepareHash = Get-FileSha256 -Path $prepareSourcePath
        $prepareArtifact = [ordered]@{
            source = $prepareSourcePath
            destination = $prepareDestinationPath
            purpose = 'fixture line manifest'
            destination_root = 'dispatch-line-root'
            expected_sha256 = $prepareHash
            source_sha256 = $prepareHash
            destination_sha256 = $prepareHash
        }
        $prepareDocument = New-PrepareDocument -RootInfo $prepareRootInfo -Status 'Prepared' -RequestPathValue '' -RequestSha256Value '' -EffectiveCodexHome (Resolve-CodexHomeForEvidence -CodexHomePath $null) -Artifacts @($prepareArtifact) -ErrorValue $null
        $fixturePrepareResultPath = Join-Path $prepareRootInfo.HistoryLineRoot ('prepare-' + $DispatchSlug + '.json')
        $prepareWritten = Write-PrepareResultDocument -Path $fixturePrepareResultPath -Document $prepareDocument
        $preflightObject = [pscustomobject]@{ operation = 'Preflight'; sourceRoot = $SourceRoot; executionRoot = $DispatchRoot; dispatchRoot = $DispatchRoot; lineSlug = $LineSlug; dispatchSlug = $DispatchSlug; worktreeCreated = $true; baseSha = $BaseSha; baselinePath = $baseline.Path; baselineSha256 = $baseline.Sha256; writeMode = 'write'; prepareResultPath = $prepareWritten.Path; prepareResultSha256 = $prepareWritten.Sha256 }
        $PreflightResultPath = Join-Path $DispatchRoot '.local/ai-sessions/history/preflight.json'
        Write-Utf8NoBom $PreflightResultPath ($preflightObject | ConvertTo-Json -Depth 5)
        $BaselinePath = $null
        $BaselineSha256 = $null
        $DispatchKind = 'workflow'
        $ReportPath = @(Join-Path $DispatchRoot '.local/ai-sessions/report/closure.md')
        Write-Utf8NoBom $ReportPath[0] "# Fixture

## Phase 對照

無
"
        Invoke-Case -Name $Name -Action $Scenario -Reject:$Reject -ErrorPattern $ErrorPattern
    }
    Invoke-BaselineCase 'Baseline JSON 日期往返與 absent 狀態' {
        $record = Read-DispatchBaseline -Path $baseline.Path -Sha256 $baseline.Sha256 -SourceRoot $SourceRoot -DispatchRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -BaseSha $BaseSha
        Assert-True ($record.created_at_utc -is [string] -and @($record.files).Count -eq 3 -and -not ($record.files | Where-Object path -eq 'deleted.txt').exists) 'Baseline 日期或刪除狀態遺失。'
    }
    Invoke-BaselineCase 'Collect dirty tracked 與 untracked 未改動全部排除' {
        $result = Invoke-Collect
        Assert-True ($result.allFiles -is [array] -and $result.allFiles.Count -eq 0 -and $result.dispatchDiff.Count -eq 0 -and $result.trackedDiff -contains 'A.txt' -and $result.untrackedFiles -contains 'U.txt') 'Carry-in 被納入或診斷資料遺失。'
    }
    foreach ($content in @('carry-in tracked plus dispatch', 'original HEAD content', '')) {
        Invoke-BaselineCase ('Collect 同 tracked 新增刪減或回復內容 ' + $content) {
            Write-Utf8NoBom $aFile $content
            Write-Utf8NoBom $ReportPath[0] "# Fixture

## Phase 對照

- Phase 3：``A.txt``
"
            $result = Invoke-Collect
            Assert-True ($result.allFiles.Count -eq 1 -and $result.allFiles[0] -ceq 'A.txt' -and $result.itemChecks[0].IsTracked) '同檔差異未納入。'
        }
    }
    Invoke-BaselineCase 'Collect carry-in untracked 修改後納入' {
        Write-Utf8NoBom $uFile 'dispatch untracked'
        Write-Utf8NoBom $ReportPath[0] "# Fixture

## Phase 對照

- Phase 3：``U.txt``
"
        $result = Invoke-Collect
        Assert-True ($result.allFiles.Count -eq 1 -and $result.allFiles[0] -eq 'U.txt' -and -not $result.itemChecks[0].IsTracked) '未追蹤同檔差異未納入。'
    }
    Invoke-BaselineCase 'Collect 新增未追蹤檔案' {
        $gitUntracked = @('U.txt', 'new.txt')
        Write-Utf8NoBom (Join-Path $DispatchRoot 'new.txt') 'new'
        Write-Utf8NoBom $ReportPath[0] ((@(
            '# Fixture'
            ''
            '## Phase 對照'
            ''
            '- Phase 3：`new.txt`'
        ) -join [Environment]::NewLine) + [Environment]::NewLine)
        Assert-True ((Invoke-Collect).allFiles[0] -eq 'new.txt') '新增未追蹤未納入。'
    }
    Invoke-BaselineCase 'Collect 刪除 tracked 與 untracked' {
        Move-Item $aFile (Join-Path $DispatchRoot '.local/A.saved')
        Move-Item $uFile (Join-Path $DispatchRoot '.local/U.saved')
        $gitUntracked = @()
        Write-Utf8NoBom $ReportPath[0] "# Fixture

## Phase 對照

- Phase 3：``A.txt``、``U.txt``
"
        Assert-True (((Invoke-Collect).allFiles -join ',') -ceq 'A.txt,U.txt') '刪檔未納入。'
    }
    Invoke-BaselineCase 'Collect 更名視為刪除加新增' {
        Move-Item $aFile (Join-Path $DispatchRoot 'renamed.txt')
        $gitUntracked = @('U.txt', 'renamed.txt')
        Write-Utf8NoBom $ReportPath[0] ((@(
            '# Fixture'
            ''
            '## Phase 對照'
            ''
            '- Phase 3：`A.txt`、`renamed.txt`'
        ) -join [Environment]::NewLine) + [Environment]::NewLine)
        Assert-True (((Invoke-Collect).allFiles -join ',') -ceq 'A.txt,renamed.txt') '更名差異遺失。'
    }
    Invoke-BaselineCase 'Collect 僅 staging 不新增差異' {
        $gitIndex['U.txt'] = '100644'
        $gitUntracked = @()
        $gitStaged = @('A.txt', 'U.txt')
        Assert-True ((Invoke-Collect).allFiles.Count -eq 0) 'staging 被當作內容修改。'
    }
    Invoke-BaselineCase 'Collect Git mode 變更納入' {
        $gitIndex['A.txt'] = '100755'
        Write-Utf8NoBom $ReportPath[0] "# Fixture

## Phase 對照

- Phase 3：``A.txt``
"
        Assert-True ((Invoke-Collect).allFiles[0] -eq 'A.txt') 'Git mode 變更未納入。'
    }
    Invoke-BaselineCase 'Collect working tree mode 變更且 index mode 未變納入' {
        $gitWorkingTree['A.txt'] = '100755'
        Write-Utf8NoBom $ReportPath[0] "# Fixture

## Phase 對照

- Phase 3：``A.txt``
"
        $result = Invoke-Collect
        Assert-True ($result.dispatchDiff -contains 'A.txt' -and $result.allFiles -contains 'A.txt') 'working tree mode 變更未納入。'
    }
    Invoke-BaselineCase 'Collect missingFromReport 使用淨差異' -Reject -ErrorPattern 'missingFromReport=A.txt' { Write-Utf8NoBom $aFile 'dispatch'; Invoke-Collect }
    Invoke-BaselineCase 'Collect unexpectedInReport 拒絕未改 carry-in' -Reject -ErrorPattern 'unexpectedInReport=A.txt' {
        Write-Utf8NoBom $ReportPath[0] "# Fixture

## Phase 對照

- Phase 3：``A.txt``
"
        Invoke-Collect
    }
    Invoke-BaselineCase 'Collect baseline 缺檔拒絕' -Reject { Move-Item $baseline.Path ($baseline.Path + '.saved'); Invoke-Collect }
    Invoke-BaselineCase 'Collect baseline 竄改拒絕' -Reject -ErrorPattern 'SHA-256 不一致' { Write-Utf8NoBom $baseline.Path '{}'; Invoke-Collect }
    Invoke-BaselineCase 'Collect baseline 缺欄位拒絕' -Reject -ErrorPattern 'baselinePath' {
        $preflightObject.PSObject.Properties.Remove('baselinePath')
        Write-Utf8NoBom $PreflightResultPath ($preflightObject | ConvertTo-Json)
        Invoke-Collect
    }
    Invoke-BaselineCase 'Collect 顯式 baseline 與 Preflight 衝突拒絕' -Reject -ErrorPattern '顯式輸入與 Preflight' { $BaselineSha256 = '0' * 64; Invoke-Collect }
    Invoke-BaselineCase 'Collect 錯 roots 拒絕' -Reject -ErrorPattern 'roots 不一致' {
        $record = ConvertFrom-DispatchJson (Get-Content $baseline.Path -Raw -Encoding UTF8)
        $record.dispatch_root = $SourceRoot
        Write-Utf8NoBom $baseline.Path ($record | ConvertTo-Json -Depth 8)
        $preflightObject.baselineSha256 = Get-FileSha256 $baseline.Path
        Write-Utf8NoBom $PreflightResultPath ($preflightObject | ConvertTo-Json)
        Invoke-Collect
    }
    Invoke-BaselineCase 'Collect 不提供 Preflight 可明確綁定 baseline' {
        $PreflightResultPath = $null
        $BaselinePath = $baseline.Path
        $BaselineSha256 = $baseline.Sha256
        Assert-True ((Invoke-Collect).allFiles.Count -eq 0) '顯式 baseline 無法回收。'
    }
    Invoke-BaselineCase 'Baseline 空檔案集合仍可讀取' {
        $gitTree = @{}
        $gitIndex = @{}
        $gitUntracked = @()
        $empty = New-DispatchBaseline -SourceRoot $SourceRoot -DispatchRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -BaseSha $BaseSha
        $record = Read-DispatchBaseline -Path $empty.Path -Sha256 $empty.Sha256 -SourceRoot $SourceRoot -DispatchRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -BaseSha $BaseSha
        Assert-True ($record.files -is [array] -and $record.files.Count -eq 0) '空集合 JSON 型別異常。'
    }
    Invoke-BaselineCase 'Baseline 拒絕重解析點父目錄' -Reject -ErrorPattern '不支援重解析點' {
        $target = Join-Path $fixtureRoot ('j' + $script:caseCount)
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Write-Utf8NoBom (Join-Path $target 'outside.txt') 'outside'
        New-Item -ItemType Junction -Path (Join-Path $DispatchRoot 'link') -Target $target | Out-Null
        $gitUntracked = @('U.txt', 'link/outside.txt')
        Get-DispatchFileSnapshot -DispatchRoot $DispatchRoot -BaseSha $BaseSha
    }
    Invoke-BaselineCase 'Baseline schema 異常即使 hash 相符也拒絕' -Reject -ErrorPattern 'schema／line／dispatch／baseSha' {
        $record = ConvertFrom-DispatchJson (Get-Content $baseline.Path -Raw -Encoding UTF8)
        $record.schema = 'invalid'
        Write-Utf8NoBom $baseline.Path ($record | ConvertTo-Json -Depth 8)
        $preflightObject.baselineSha256 = Get-FileSha256 $baseline.Path
        Write-Utf8NoBom $PreflightResultPath ($preflightObject | ConvertTo-Json)
        Invoke-Collect
    }
    Invoke-BaselineCase 'Collect 無 Preflight 且缺 baseline 不回退 baseSha' -Reject -ErrorPattern '缺少有效 Baseline' { $PreflightResultPath = $null; Invoke-Collect }
    foreach ($mode in @('120000', '160000')) {
        Invoke-BaselineCase ('Baseline 拒絕 symlink 或 submodule mode ' + $mode) -Reject -ErrorPattern '不支援 Git kind' {
            $gitIndex['A.txt'] = $mode
            Get-DispatchFileSnapshot -DispatchRoot $DispatchRoot -BaseSha $BaseSha
        }
    }
    Invoke-BaselineCase 'Baseline 拒絕 traversal 路徑' -Reject -ErrorPattern '相對路徑異常' { $gitUntracked += '../outside.txt'; Get-DispatchFileSnapshot -DispatchRoot $DispatchRoot -BaseSha $BaseSha }
    Invoke-BaselineCase 'Baseline NUL 保留含 tab 路徑與原始位元組' {
        $special = "tab`tname.txt"
        $gitUntracked = @('U.txt', $special)
        # Windows 不允許 tab 檔名，路徑解析以 Git 替身與檔案邊界替身驗證。
        function Get-DispatchSnapshotPath { param($Root, $Path) if ($Path -ceq $special) { return $uFile }; return Join-Path $Root $Path }
        $snapshot = @(Get-DispatchFileSnapshot -DispatchRoot $DispatchRoot -BaseSha $BaseSha)
        Assert-True (@($snapshot | Where-Object { $_.path -ceq $special }).Count -eq 1) 'NUL 路徑被拆開。'
        [IO.File]::WriteAllBytes($uFile, [byte[]]@(0, 255, 13, 10))
        $snapshot = @(Get-DispatchFileSnapshot -DispatchRoot $DispatchRoot -BaseSha $BaseSha)
        Assert-True (($snapshot | Where-Object path -eq 'U.txt').sha256 -eq (Get-FileSha256 $uFile)) '原始位元組雜湊不一致。'
    }
    Invoke-BaselineCase 'Start 與 Resume 沿用同一 baseline' {
        $ScopePlanPath = $null
        $LastMessagePath = $null
        $ResumeThreadId = $null
        $PromptPath = Join-Path $DispatchRoot '.local/prompt.md'
        Write-Utf8NoBom $PromptPath 'fixture'
        $started = Invoke-Start
        $run = Read-DispatchRunRecord -Path $started.runRecordPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        $run.model_evidence.runtime_verifiable = New-ConfirmedDispatchEvidence -Value 'fixture-model' -Source 'rollout' -Field 'payload.model'
        $null = Write-DispatchRunRecord -Record $run -Update
        Assert-True ($run.baseline_path -eq $baseline.Path -and $run.baseline_sha256 -eq $baseline.Sha256) 'Start 未綁定 baseline。'
        Write-Utf8NoBom $started.lastMessagePath 'completed'
        Write-Utf8NoBom $aFile 'dispatch phase 1'
        $ResumeThreadId = $script:testThread
        $ScopePlanPath = $started.scopePlanPath
        $resumed = Invoke-Start
        $next = Read-DispatchRunRecord -Path $resumed.runRecordPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        Assert-True ($next.baseline_path -eq $run.baseline_path -and $next.baseline_sha256 -eq $run.baseline_sha256 -and $next.previous_run_id -eq $run.run_id) 'Resume 重建 baseline。'
    }
    Invoke-BaselineCase 'Start worktree 缺 baseline 不得啟動' {
        $ScopePlanPath = $null
        $LastMessagePath = $null
        $PromptPath = Join-Path $DispatchRoot '.local/prompt.md'
        Write-Utf8NoBom $PromptPath 'fixture'
        $preflightObject.PSObject.Properties.Remove('baselinePath')
        Write-Utf8NoBom $PreflightResultPath ($preflightObject | ConvertTo-Json)
        $beforeCalls = $script:startCalls
        $caught = $false
        try { Invoke-Start } catch { $caught = $_.Exception.Message.Contains('baselinePath') }
        Assert-True ($caught -and $script:startCalls -eq $beforeCalls) '缺 baseline 仍啟動。'
    }
    Invoke-BaselineCase 'Preflight 在 carry-in 後建立 baseline 並保留 baseSha' {
        function Read-LineManifest { return [pscustomobject]@{ SourceLineRoot = $fixtureRoot } }
        function Get-PidCheckResult { return [pscustomobject]@{ Blocked = $false } }
        function Get-ExistingGitRepositoryState { return [pscustomobject]@{ IsRepository = $true } }
        function Get-TrackedPathState { return [pscustomobject]@{ IsTracked = $true } }
        function Apply-SourceCarryIn {
            param($SourceRoot, $DispatchRoot)
            Write-Utf8NoBom (Join-Path $DispatchRoot 'A.txt') 'carry-in applied'
            Write-Utf8NoBom (Join-Path $DispatchRoot 'U.txt') 'carry-in untracked'
            return [ordered]@{ TrackedPatchApplied = $true }
        }
        $DispatchSlug = 'pf' + $script:caseCount
        $DispatchRoot = Join-Path $SourceRoot ('.local/ai-sessions/worktrees/' + $DispatchSlug)
        $WriteMode = 'write'
        $TargetPath = @('A.txt')
        $result = Invoke-Preflight
        $record = Read-DispatchBaseline -Path $result.baselinePath -Sha256 $result.baselineSha256 -SourceRoot $SourceRoot -DispatchRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -BaseSha $BaseSha
        Assert-True ($result.baseSha -eq $BaseSha -and ($record.files | Where-Object path -eq 'A.txt').sha256 -eq (Get-FileSha256 (Join-Path $DispatchRoot 'A.txt'))) 'baseline 未捕捉 carry-in。'
    }
    Invoke-BaselineCase 'Collect direct-write 不要求 baseline 並維持原分支' {
        $preflightObject.worktreeCreated = $false
        $preflightObject.executionRoot = $SourceRoot
        $preflightObject.baseSha = ''
        $preflightObject | Add-Member NoteProperty targetStates @()
        Write-Utf8NoBom $PreflightResultPath ($preflightObject | ConvertTo-Json)
        function Invoke-DirectWriteCollect { return [ordered]@{ directWrite = $true } }
        Assert-True ((Invoke-Collect).directWrite) 'direct-write 未保留。'
    }
    Invoke-Case 'Phase 3 移除 baseSha 歸屬與保留入口綁定' {
        $collectText = ($functions | Where-Object Name -eq 'Invoke-Collect').Extent.Text
        $preflightText = ($functions | Where-Object Name -eq 'Invoke-Preflight').Extent.Text
        Assert-True (-not $collectText.Contains('$allFiles = @($trackedDiff + $untrackedFiles') -and $collectText.Contains('$allFiles = @($dispatchDiff)') -and $collectText.Contains('Resolve-DispatchBaselineBinding')) '舊歸屬路徑殘留。'
        Assert-True ($preflightText.IndexOf('Apply-SourceCarryIn') -lt $preflightText.IndexOf('New-DispatchBaseline') -and $preflightText -notmatch "'commit'") 'baseline 建立順序或 commit 約束不符。'
    }
}
if ($Phase -ge 4) {
    Invoke-Case 'Phase 4 parent options 保存 fingerprint 與 literal arrays' {
        $parent = New-ParentOptionsModel -Profile 'default' -Sandbox 'workspace-write' -WorkingDirectory $fixtureRoot -AddDirectory @('C:\work\comma,name\空白 路徑\$literal', 'C:\中文 路徑') -Search $true -CodexParentOption @('--model=gpt-5.6-luna', '--note=中文 $literal,with,comma')
        $same = Compare-ParentOptions -Current $parent -Anchor $parent
        $changed = New-ParentOptionsModel -Profile 'default' -Sandbox 'workspace-write' -WorkingDirectory $fixtureRoot -AddDirectory @('C:\work\comma,name\空白 路徑\$literal', 'C:\中文 路徑') -Search $true -CodexParentOption @('--model=gpt-5.6-luna', '--note=changed')
        $mismatch = Compare-ParentOptions -Current $changed -Anchor $parent
        Assert-True ($parent.fingerprint -match '^[a-f0-9]{64}$' -and $same.matches -and -not $mismatch.matches -and $mismatch.code -eq 'ParentOptionsMismatch' -and ($mismatch.differences -contains 'codex_parent_option')) 'parent_options fingerprint 或逐欄 mismatch 異常。'
    }

    Invoke-Case 'Phase 4 direct-write ACL gate 為 not-applicable' {
        $acl = Get-WorktreeAclGate -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -WriteMode 'write'
        Assert-True ($acl.status -eq 'not-applicable' -and $null -eq $acl.rejection_code) 'direct-write ACL gate 狀態異常。'
    }
    Invoke-Case 'Phase 4 worktree ACL residue gate 拒絕' {
        $script:aclFixtureStatus = 'residue'
        try {
            $acl = Get-WorktreeAclGate -SourceRoot $fixtureRoot -ExecutionRoot (Join-Path $fixtureRoot 'dispatch-worktree') -WriteMode 'worktree'
            Assert-True ($acl.status -eq 'residue' -and $acl.rejection_code -eq 'WorktreeAclResidue' -and @($acl.residue).Count -eq 1) 'ACL residue gate 未保留 normalized residue。'
        }
        finally {
            $script:aclFixtureStatus = 'clean'
        }
    }
    Invoke-Case 'Phase 4 worktree ACL unknown gate 拒絕' {
        $script:aclFixtureStatus = 'unknown'
        try {
            $acl = Get-WorktreeAclGate -SourceRoot $fixtureRoot -ExecutionRoot (Join-Path $fixtureRoot 'dispatch-worktree') -WriteMode 'worktree'
            Assert-True ($acl.status -eq 'unknown' -and $acl.rejection_code -eq 'WorktreeAclUnknown') 'ACL unknown gate 狀態異常。'
        }
        finally {
            $script:aclFixtureStatus = 'clean'
        }
    }
    Invoke-Case 'Phase 4 continuation omitted parent options restores anchor' {
        $anchorOptions = New-ParentOptionsModel -Profile 'default' -Sandbox 'workspace-write' -WorkingDirectory $fixtureRoot -AddDirectory @('C:\comma,name\空白 路徑\$literal', 'C:\中文 路徑') -Search $true -CodexParentOption @('--note=中文 $literal,with,comma')
        $restored = Resolve-ParentOptionsForStart -Profile 'default' -Sandbox 'workspace-write' -WorkingDirectory $fixtureRoot -AddDirectory $null -Search $false -CodexParentOption $null -Anchor $anchorOptions
        Assert-True ($restored.restored -and $null -eq $restored.code -and (Compare-ParentOptions -Current $restored.model -Anchor $anchorOptions).matches) '續行未從 anchor 還原省略的父層選項。'
    }

    Invoke-Case 'Phase 4 T001 anchor=advisor 顯式 Profile default 與 request profile 都拒絕 mismatch' {
        $advisorAnchorRun = New-TestRun -Line 'line-a' -Dispatch 'phase4-profile-anchor'
        $advisorAnchorRun.parent_options = New-ParentOptionsModel -Profile 'advisor' -Sandbox 'read-only' -WorkingDirectory $fixtureRoot -AddDirectory @() -Search $false -CodexParentOption @()
        $advisorAnchorRun.parent_options_sha256 = $advisorAnchorRun.parent_options.fingerprint
        $advisorAnchorRun.parent_options_status = 'confirmed'
        $advisorAnchorRunPath = Write-DispatchRunRecord -Record $advisorAnchorRun -Update
        $advisorAnchorRecord = Read-DispatchRunRecord -Path $advisorAnchorRunPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug 'phase4-profile-anchor'
        $advisorAnchor = $advisorAnchorRecord.parent_options
        $explicitMismatch = Resolve-ParentOptionsForStart -Profile 'default' -ProfileProvided $true -Sandbox 'read-only' -WorkingDirectory $fixtureRoot -AddDirectory @() -Search $false -AddDirectoryProvided $false -SearchProvided $false -CodexParentOption @() -CodexParentOptionProvided $false -Anchor $advisorAnchor
        Assert-True ($explicitMismatch.code -eq 'ParentOptionsMismatch' -and $explicitMismatch.differences -contains 'profile') 'anchor=advisor 且顯式 Profile default 未拒絕。'
        $omittedRestore = Resolve-ParentOptionsForStart -Profile 'default' -ProfileProvided $false -Sandbox 'read-only' -WorkingDirectory $fixtureRoot -AddDirectory @() -Search $false -AddDirectoryProvided $false -SearchProvided $false -CodexParentOption @() -CodexParentOptionProvided $false -Anchor $advisorAnchor
        Assert-True ($omittedRestore.code -eq $null -and $omittedRestore.model.profile -eq 'advisor') '省略 Profile 未從 advisor anchor 還原。'

        $profileRequestPath = Join-Path $fixtureRoot 'phase4-profile-request.json'
        $profileRequest = [ordered]@{
            schema = 'ai-sessions.dispatch-request.v1'
            operation = 'Start'
            line_slug = 'line-a'
            dispatch_slug = 'phase4-profile-request'
            profile = 'default'
        }
        Write-Utf8NoBom -Path $profileRequestPath -Content (($profileRequest | ConvertTo-Json -Depth 10) + "`n")
        try {
            $script:RequestPath = $profileRequestPath
            $script:Operation = 'Start'
            $script:LineSlug = 'line-a'
            $script:DispatchSlug = 'phase4-profile-request'
            $script:Profile = 'default'
            $script:ProfileExplicit = $false
            $script:InvocationBoundParameters = [ordered]@{
                RequestPath = $profileRequestPath
                Operation = 'Start'
                LineSlug = 'line-a'
                DispatchSlug = 'phase4-profile-request'
            }
            $requestContext = Apply-DispatchRequest
            $requestMismatch = Resolve-ParentOptionsForStart -Profile $script:Profile -ProfileProvided ([bool]$script:ProfileExplicit) -Sandbox 'read-only' -WorkingDirectory $fixtureRoot -AddDirectory @() -Search $false -AddDirectoryProvided $false -SearchProvided $false -CodexParentOption @() -CodexParentOptionProvided $false -Anchor $advisorAnchor
            Assert-True ($requestContext.field_presence.profile -and $script:ProfileExplicit -and $requestMismatch.code -eq 'ParentOptionsMismatch' -and $requestMismatch.differences -contains 'profile') 'request profile 未視為顯式父層選項。'
        }
        finally {
            $script:RequestPath = $null
            $script:RequestContext = $null
            $script:Profile = 'default'
            $script:ProfileExplicit = $false
            $script:InvocationBoundParameters = [ordered]@{}
        }
    }

    $productionAclGateAst = $functions | Where-Object { $_.Name -eq 'Get-WorktreeAclGate' } | Select-Object -First 1
    if ($null -eq $productionAclGateAst) {
        throw 'Phase 4 找不到 production function：Get-WorktreeAclGate'
    }
    $productionAclGateDefinition = $productionAclGateAst.Extent.Text.Replace('function Get-WorktreeAclGate', 'function Invoke-ProductionWorktreeAclGate')
    . ([scriptblock]::Create($productionAclGateDefinition))

    $phase4RealAclRoot = Join-Path $fixtureRoot 'phase4-real-acl'
    $phase4RealSourceRoot = Join-Path $phase4RealAclRoot 'source'
    $phase4RealDispatchRoot = Join-Path $phase4RealAclRoot 'dispatch'
    $phase4RealExplicitRoot = Join-Path $phase4RealAclRoot 'explicit'
    $phase4RealUnknownRoot = Join-Path $phase4RealAclRoot 'missing'
    New-Item -ItemType Directory -Path $phase4RealSourceRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $phase4RealDispatchRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $phase4RealExplicitRoot -Force | Out-Null
    $script:phase4RealAclRuleStatus = 'not-attempted'
    $script:phase4RealEmptyAclFingerprint = $null

    Invoke-Case 'Phase 4 production ACL 空 explicit entries snapshot known 與 gate clean' {
        $sourceSnapshot = Get-ExplicitAclSnapshot -Path $phase4RealSourceRoot
        $sourceSnapshotAgain = Get-ExplicitAclSnapshot -Path $phase4RealSourceRoot
        $dispatchSnapshot = Get-ExplicitAclSnapshot -Path $phase4RealDispatchRoot
        $gate = Invoke-ProductionWorktreeAclGate -SourceRoot $phase4RealSourceRoot -ExecutionRoot $phase4RealDispatchRoot -WriteMode 'worktree'
        Assert-True ($sourceSnapshot.status -eq 'known' -and $dispatchSnapshot.status -eq 'known' -and @($sourceSnapshot.explicit_entries).Count -eq 0 -and @($dispatchSnapshot.explicit_entries).Count -eq 0) '真實新建目錄未得到 known 空 explicit_entries。'
        Assert-True ($sourceSnapshot.fingerprint -match '^[a-f0-9]{64}$' -and $sourceSnapshot.fingerprint -eq $sourceSnapshotAgain.fingerprint -and $sourceSnapshot.fingerprint -eq $dispatchSnapshot.fingerprint) '空 explicit_entries fingerprint 不穩定。'
        Assert-True ($gate.status -eq 'clean' -and $gate.rejection_code -eq $null -and @($gate.residue).Count -eq 0) '真實空 ACL worktree 未得到 clean gate。'
        $script:phase4RealEmptyAclFingerprint = [string]$sourceSnapshot.fingerprint
    }

    Invoke-Case 'Phase 4 production ACL 真實 explicit ACE fingerprint 穩定與 residue' {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $rule = New-Object -TypeName 'System.Security.AccessControl.FileSystemAccessRule' -ArgumentList @(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::ReadAndExecute,
            [System.Security.AccessControl.InheritanceFlags]::None,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl = Get-Acl -LiteralPath $phase4RealExplicitRoot -ErrorAction Stop
        $ruleApplied = $false
        try {
            $acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $phase4RealExplicitRoot -AclObject $acl -ErrorAction Stop
            $ruleApplied = $true
            $script:phase4RealAclRuleStatus = 'created'
        }
        catch {
            $script:phase4RealAclRuleStatus = 'permission-unavailable: ' + $_.Exception.Message
        }

        if ($ruleApplied) {
            $firstSnapshot = Get-ExplicitAclSnapshot -Path $phase4RealExplicitRoot
            $secondSnapshot = Get-ExplicitAclSnapshot -Path $phase4RealExplicitRoot
            $gate = Invoke-ProductionWorktreeAclGate -SourceRoot $phase4RealSourceRoot -ExecutionRoot $phase4RealExplicitRoot -WriteMode 'worktree'
            Assert-True ($firstSnapshot.status -eq 'known' -and @($firstSnapshot.explicit_entries).Count -gt 0 -and $firstSnapshot.fingerprint -match '^[a-f0-9]{64}$' -and $firstSnapshot.fingerprint -eq $secondSnapshot.fingerprint) '真實 explicit ACE fingerprint 不穩定。'
            Assert-True ($gate.status -eq 'residue' -and $gate.rejection_code -eq 'WorktreeAclResidue' -and @($gate.residue).Count -gt 0) '真實 ACL residue 未被 gate 拒絕。'
        }
        else {
            $fallbackSourceSnapshot = Get-ExplicitAclSnapshot -Path $phase4RealSourceRoot
            $fallbackDispatchSnapshot = Get-ExplicitAclSnapshot -Path $phase4RealDispatchRoot
            $fallbackGate = Invoke-ProductionWorktreeAclGate -SourceRoot $phase4RealSourceRoot -ExecutionRoot $phase4RealDispatchRoot -WriteMode 'worktree'
            Assert-True ($fallbackSourceSnapshot.status -eq 'known' -and $fallbackDispatchSnapshot.status -eq 'known' -and @($fallbackSourceSnapshot.explicit_entries).Count -eq 0 -and @($fallbackDispatchSnapshot.explicit_entries).Count -eq 0 -and $fallbackGate.status -eq 'clean') 'ACL 權限不足時的真實空目錄 fallback 驗證失敗。'
        }
    }

    Invoke-Case 'Phase 4 production ACL 不存在目錄維持 unknown' {
        $snapshot = Get-ExplicitAclSnapshot -Path $phase4RealUnknownRoot
        $gate = Invoke-ProductionWorktreeAclGate -SourceRoot $phase4RealSourceRoot -ExecutionRoot $phase4RealUnknownRoot -WriteMode 'worktree'
        Assert-True ($snapshot.status -eq 'unknown' -and $snapshot.error -match '不存在' -and $gate.status -eq 'unknown' -and $gate.rejection_code -eq 'WorktreeAclUnknown') '真實不存在目錄 unknown 案例退化。'
    }
    Write-Output ('REAL_ACL_EMPTY_FINGERPRINT: ' + [string]$script:phase4RealEmptyAclFingerprint)
    Write-Output ('REAL_ACL_RULE_STATUS: ' + $script:phase4RealAclRuleStatus)

    $phase4LineRoot = Join-Path $fixtureRoot '.local/ai-sessions/handoff/line-a'
    New-Item -ItemType Directory -Path $phase4LineRoot -Force | Out-Null
    Write-Utf8NoBom -Path (Join-Path $phase4LineRoot 'line.json') -Content (([ordered]@{ schema = 'ai-sessions.line.v1'; 'line-slug' = 'line-a' } | ConvertTo-Json) + "
")
    $phase4HandoffRecord = New-TestRun -Line 'line-a' -Dispatch 'phase4-handoff'
    $phase4Scope = [ordered]@{ dispatch_slug = 'phase4-handoff'; selected_units = @('unit-1'); deferred_units = @('unit-2'); scope_plan_fingerprint = 'fixture' }
    Write-Utf8NoBom -Path $phase4HandoffRecord.scope_plan_path -Content (($phase4Scope | ConvertTo-Json -Depth 8) + "
")
    $phase4HandoffRecord.scope_plan_sha256 = Get-FileSha256 $phase4HandoffRecord.scope_plan_path
    $null = Write-DispatchRunRecord -Record $phase4HandoffRecord -Update
    Write-Utf8NoBom -Path $phase4HandoffRecord.event_stream_path -Content (([ordered]@{ type = 'error'; message = 'usage-limit reached' } | ConvertTo-Json -Compress) + "
")
    Remove-Item -LiteralPath $phase4HandoffRecord.last_message_path -Force -ErrorAction SilentlyContinue
    Invoke-Case 'Phase 4 usage-limit no last-message 建立 RecoveryReady Handoff' {
        $SourceRoot = $fixtureRoot
        $ExecutionRoot = $fixtureRoot
        $LineSlug = 'line-a'
        $DispatchSlug = 'phase4-handoff'
        $RunRecordPath = Join-Path (Get-DispatchRunDirectory $fixtureRoot $LineSlug $DispatchSlug) ($phase4HandoffRecord.run_id + '.json')
        $WriteMode = 'write'
        $ProcessExitCode = 1
        $RecoveryHandoffPath = Join-Path $fixtureRoot '.local/ai-sessions/history/line-a/recovery-handoff-phase4-handoff-aabbccddeeff00112233445566778899.json'
        $RebuildReason = 'usage-limit-no-last-message'
        $result = Invoke-RecoveryHandoff
        $handoff = Read-RecoveryHandoff -Path $result.recoveryHandoffPath -SourceRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        Assert-True ($result.recoveryStatus -eq 'ready' -and $result.deliverableAcceptance.status -eq 'pending' -and $handoff.Document.deliverable_acceptance.status -ne 'accepted' -and $handoff.Document.event_evidence.event_state -eq 'quota-rejected') 'RecoveryHandoff 未分離 recovery eligibility 與 acceptance。'
    }
    Invoke-Case 'Phase 4 Handoff collision 不覆寫既有 evidence' -Reject -ErrorPattern 'RecoveryHandoffCollision' {
        $SourceRoot = $fixtureRoot
        $ExecutionRoot = $fixtureRoot
        $LineSlug = 'line-a'
        $DispatchSlug = 'phase4-handoff'
        $RunRecordPath = Join-Path (Get-DispatchRunDirectory $fixtureRoot $LineSlug $DispatchSlug) ($phase4HandoffRecord.run_id + '.json')
        $WriteMode = 'write'
        $ProcessExitCode = 1
        $RecoveryHandoffPath = Join-Path $fixtureRoot '.local/ai-sessions/history/line-a/recovery-handoff-phase4-handoff-aabbccddeeff00112233445566778899.json'
        $RebuildReason = 'usage-limit-no-last-message'
        Invoke-RecoveryHandoff
    }
    Invoke-Case 'Phase 4 Handoff hash changed／cross-line 拒絕' -Reject -ErrorPattern 'RecoveryHandoffHashMismatch|CrossLine' {
        $handoffPath = Join-Path $fixtureRoot '.local/ai-sessions/history/line-a/recovery-handoff-phase4-handoff-aabbccddeeff00112233445566778899.json'
        $handoffContent = Get-Content -LiteralPath $handoffPath -Raw -Encoding UTF8
        Write-Utf8NoBom -Path $handoffPath -Content ($handoffContent + "
")
        Read-RecoveryHandoff -Path $handoffPath -SourceRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug 'phase4-handoff'
    }
    Invoke-Case 'Phase 4 completion claim 不得寫入 accepted' -Reject -ErrorPattern 'RecoveryHandoffUnsupportedCompletion' {
        $completionRecord = New-TestRun -Line 'line-a' -Dispatch 'phase4-completion-claim'
        Write-Utf8NoBom -Path $completionRecord.last_message_path -Content 'deliverable_acceptance: accepted'
        $SourceRoot = $fixtureRoot
        $ExecutionRoot = $fixtureRoot
        $LineSlug = 'line-a'
        $DispatchSlug = 'phase4-completion-claim'
        $RunRecordPath = Join-Path (Get-DispatchRunDirectory $fixtureRoot $LineSlug $DispatchSlug) ($completionRecord.run_id + '.json')
        $ProcessExitCode = 0
        $RecoveryHandoffPath = Join-Path $fixtureRoot '.local/ai-sessions/history/line-a/recovery-handoff-phase4-completion-claim-00112233445566778899aabbccddeeff.json'
        $result = Invoke-RecoveryHandoff
        Assert-True ($result.recoveryStatus -eq 'blocked' -and $result.recoveryEligibility.rejection_codes -contains 'RecoveryHandoffUnsupportedCompletion') 'completion claim 未被標記為 blocked。'
        throw 'RecoveryHandoffUnsupportedCompletion: fixture rejection assertion'
    }
    Invoke-Case 'Phase 4 unknown termination 診斷與 cold-start 建議' {
        $unknownRecord = New-TestRun -Line 'line-a' -Dispatch 'phase4-unknown-interruption'
        $unknownEvents = @(
            [ordered]@{ type = 'thread.started'; thread_id = $script:testThread }
            [ordered]@{ type = 'turn.started' }
        )
        Write-Utf8NoBom -Path $unknownRecord.event_stream_path -Content (($unknownEvents | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 }) -join "
")
        $SourceRoot = $fixtureRoot
        $ExecutionRoot = $fixtureRoot
        $LineSlug = 'line-a'
        $DispatchSlug = 'phase4-unknown-interruption'
        $EventStreamPath = $unknownRecord.event_stream_path
        $RunRecordPath = Join-Path (Get-DispatchRunDirectory $fixtureRoot $LineSlug $DispatchSlug) ($unknownRecord.run_id + '.json')
        $ScopePlanPath = $unknownRecord.scope_plan_path
        $RequiredIdentifier = 'design.md'
        $ProcessExitCode = 1
        $result = Invoke-Inspect
        Assert-True (-not $result.success -and $result.diagnosis.reason_code -eq 'InterruptedUnknown' -and $result.cold_start_recommended -eq $true -and $result.lastEventType -eq 'turn.started') 'unknown interruption 未輸出 cold-start 建議。'
    }

    Invoke-Case 'Phase 4 F-001 ACL rejection precedence precedes model comparison' {
        $startTextForOrder = ($functions | Where-Object { $_.Name -eq 'Invoke-Start' }).Extent.Text
        $aclIndex = $startTextForOrder.IndexOf('$aclGate = Get-WorktreeAclGate')
        $modelIndex = $startTextForOrder.IndexOf('$resumeDiagnostics = Compare-ResumeThreadModel')
        Assert-True ($aclIndex -ge 0 -and $modelIndex -ge 0 -and $aclIndex -lt $modelIndex) 'Start gate 順序未維持 process → ACL → model。'

        $script:phase4RealAclRuleStatus = 'not-attempted'
        $phase4F001Gate = Invoke-ProductionWorktreeAclGate -SourceRoot $phase4RealSourceRoot -ExecutionRoot $phase4RealExplicitRoot -WriteMode 'worktree'
        Assert-True ($phase4F001Gate.status -in @('residue', 'clean', 'unknown') -and $phase4RealSourceRoot -ne $phase4RealExplicitRoot) 'F-001 ACL gate 未使用真實 worktree roots。'
    }

    Invoke-Case 'Phase 4 F-002 InterruptedUnknown worktree 不可作為 resume anchor' -Reject -ErrorPattern 'InterruptedUnknownResumeRejected' {
        $unknownResumeRecord = New-TestRun -Line 'line-a' -Dispatch 'phase4-unknown-resume'
        $unknownResumeEvents = @(
            [ordered]@{ type = 'thread.started'; thread_id = $script:testThread }
            [ordered]@{ type = 'turn.started' }
        )
        Write-Utf8NoBom -Path $unknownResumeRecord.event_stream_path -Content (($unknownResumeEvents | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 }) -join [Environment]::NewLine)
        $unknownResumeRecord.launch_state = 'started'
        $null = Write-DispatchRunRecord -Record $unknownResumeRecord -Update
        $SourceRoot = $fixtureRoot
        $ExecutionRoot = $fixtureRoot
        $LineSlug = 'line-a'
        $DispatchSlug = 'phase4-unknown-resume'
        $EventStreamPath = $unknownResumeRecord.event_stream_path
        $RunRecordPath = Join-Path (Get-DispatchRunDirectory $fixtureRoot $LineSlug $DispatchSlug) ($unknownResumeRecord.run_id + '.json')
        $ScopePlanPath = $unknownResumeRecord.scope_plan_path
        $ProcessExitCode = 1
        $inspectResult = Invoke-Inspect
        Assert-True ($inspectResult.recoveryState -eq 'InterruptedUnknown' -and $inspectResult.cold_start_recommended) 'InterruptedUnknown 未先建立固定 cold-start 訊號。'
        $resumeArgs = @{
            SourceRoot = $fixtureRoot
            ExecutionRoot = $fixtureRoot
            LineSlug = 'line-a'
            DispatchSlug = 'phase4-unknown-resume'
            ResumeThreadId = $script:testThread
        }
        Resolve-PreviousDispatchRun @resumeArgs
    }

    Invoke-Case 'Phase 4 F-002 較早有效 anchor 加較晚 InterruptedUnknown 時整條鏈拒絕' {
        $chainAnchorRecord = New-TestRun -Line 'line-a' -Dispatch 'phase4-unknown-chain'
        $chainUnknownRecord = New-TestRun -Line 'line-a' -Dispatch 'phase4-unknown-chain' -Previous $chainAnchorRecord
        $chainScope = [ordered]@{
            dispatch_slug = 'phase4-unknown-chain'
            decision = 'full'
            selected_units = @('unit-1')
            deferred_units = @()
            requested_units = @('unit-1')
            scope_plan_fingerprint = 'fixture'
        }
        Write-Utf8NoBom -Path $chainAnchorRecord.scope_plan_path -Content (($chainScope | ConvertTo-Json -Depth 8) + "`n")
        $chainScopeHash = Get-FileSha256 -Path $chainAnchorRecord.scope_plan_path
        $chainAnchorRecord.scope_plan_sha256 = $chainScopeHash
        $chainUnknownRecord.scope_plan_sha256 = $chainScopeHash
        $null = Write-DispatchRunRecord -Record $chainAnchorRecord -Update
        $null = Write-DispatchRunRecord -Record $chainUnknownRecord -Update
        $chainUnknownEvents = @(
            [ordered]@{ type = 'thread.started'; thread_id = $script:testThread }
            [ordered]@{ type = 'turn.started' }
        )
        Write-Utf8NoBom -Path $chainUnknownRecord.event_stream_path -Content (($chainUnknownEvents | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 }) -join [Environment]::NewLine)
        $chainUnknownRecord.launch_state = 'started'
        $null = Write-DispatchRunRecord -Record $chainUnknownRecord -Update
        $SourceRoot = $fixtureRoot
        $ExecutionRoot = $fixtureRoot
        $LineSlug = 'line-a'
        $DispatchSlug = 'phase4-unknown-chain'
        $EventStreamPath = $chainUnknownRecord.event_stream_path
        $RunRecordPath = Join-Path (Get-DispatchRunDirectory $fixtureRoot $LineSlug $DispatchSlug) ($chainUnknownRecord.run_id + '.json')
        $ScopePlanPath = $chainUnknownRecord.scope_plan_path
        $ProcessExitCode = 1
        $inspectResult = Invoke-Inspect
        Assert-True ($inspectResult.recoveryState -eq 'InterruptedUnknown' -and $inspectResult.cold_start_recommended) '鏈尾 InterruptedUnknown 未建立 cold-start 訊號。'
        $latestRecord = Read-DispatchRunRecord -Path $RunRecordPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        $resumeArgs = @{
            SourceRoot = $fixtureRoot
            ExecutionRoot = $fixtureRoot
            LineSlug = $LineSlug
            DispatchSlug = $DispatchSlug
            ResumeThreadId = $script:testThread
        }
        $resumeException = $null
        try {
            Resolve-PreviousDispatchRun @resumeArgs
        }
        catch {
            $resumeException = $_.Exception
        }
        $resumeGate = if ($null -eq $resumeException) { $null } else { $resumeException.Data['recoveryResumeGate'] }
        Assert-True ($null -ne $resumeException -and $resumeException.Message -match 'InterruptedUnknownResumeRejected' -and $null -ne $resumeGate -and $resumeGate.process_started -eq $false -and $resumeGate.cold_start_recommended -eq $true) '較早有效 anchor 被錯誤選用，未拒絕含 InterruptedUnknown 的整條鏈。'

        $WriteMode = 'write'
        $RebuildReason = 'unknown-interruption'
        $RecoveryHandoffPath = Join-Path $fixtureRoot '.local/ai-sessions/history/line-a/recovery-handoff-phase4-unknown-chain-44444444444444444444444444444444.json'
        $handoffResult = Invoke-RecoveryHandoff
        Assert-True ($handoffResult.recoveryStatus -eq 'blocked' -and $handoffResult.recoveryEligibility.rejection_codes -contains 'InterruptedUnknownResumeRejected' -and $handoffResult.processStarted -eq $false -and $handoffResult.coldStartRecommended -eq $true) 'RecoveryHandoff 未沿用整條鏈的 InterruptedUnknown 拒絕判定。'
        $handoffDocument = (Read-RecoveryHandoff -Path $handoffResult.recoveryHandoffPath -SourceRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug).Document
        $scopeObject = ConvertFrom-DispatchJson -Content (Get-Content -LiteralPath $latestRecord.scope_plan_path -Raw -Encoding UTF8)
        $context = New-TestHandoffValidationContext -Record $latestRecord -ScopePlan $scopeObject
        $handoffValidationException = $null
        try {
            Resolve-RecoveryHandoffBinding -Path $handoffResult.recoveryHandoffPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -ValidationContext $context
        }
        catch {
            $handoffValidationException = $_.Exception
        }
        $handoffGate = if ($null -eq $handoffValidationException) { $null } else { $handoffValidationException.Data['recoveryHandoffGate'] }
        Assert-True ($null -ne $handoffValidationException -and $handoffValidationException.Message -match 'InterruptedUnknownResumeRejected' -and $null -ne $handoffGate -and $handoffGate.process_started -eq $false) 'Start revalidation 未使用相同的 InterruptedUnknown 拒絕判定。'
    }

    Invoke-Case 'Phase 4 F-003 ready 但 RunRecord chain 不自洽時拒絕' -Reject -ErrorPattern 'RecoveryHandoffNoChain' {
        $chainRecord = New-TestRun -Line 'line-a' -Dispatch 'phase4-chain-mismatch'
        $chainScope = [ordered]@{
            dispatch_slug = 'phase4-chain-mismatch'
            decision = 'full'
            selected_units = @('unit-1')
            deferred_units = @()
            requested_units = @('unit-1')
            scope_plan_fingerprint = 'fixture'
        }
        Write-Utf8NoBom -Path $chainRecord.scope_plan_path -Content (($chainScope | ConvertTo-Json -Depth 8) + [string][char]10)
        $chainRecord.scope_plan_sha256 = Get-FileSha256 $chainRecord.scope_plan_path
        $null = Write-DispatchRunRecord -Record $chainRecord -Update
        Write-Utf8NoBom -Path $chainRecord.event_stream_path -Content (([ordered]@{ type = 'error'; message = 'usage-limit reached' } | ConvertTo-Json -Compress) + [string][char]10)
        Remove-Item -LiteralPath $chainRecord.last_message_path -Force -ErrorAction SilentlyContinue
        $SourceRoot = $fixtureRoot
        $ExecutionRoot = $fixtureRoot
        $LineSlug = 'line-a'
        $DispatchSlug = 'phase4-chain-mismatch'
        $RunRecordPath = Join-Path (Get-DispatchRunDirectory $fixtureRoot $LineSlug $DispatchSlug) ($chainRecord.run_id + '.json')
        $WriteMode = 'write'
        $ProcessExitCode = 1
        $RebuildReason = 'usage-limit-no-last-message'
        $RecoveryHandoffPath = Join-Path $fixtureRoot '.local/ai-sessions/history/line-a/recovery-handoff-phase4-chain-mismatch-11111111111111111111111111111111.json'
        $handoffResult = Invoke-RecoveryHandoff
        $handoffDocument = (Read-RecoveryHandoff -Path $handoffResult.recoveryHandoffPath -SourceRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug).Document
        $handoffDocument.run_chain.anchor_run_id = [guid]::NewGuid().ToString('D')
        Set-TestHandoffDocumentHash -Path $handoffResult.recoveryHandoffPath -Document $handoffDocument
        $context = New-TestHandoffValidationContext -Record $chainRecord -ScopePlan (ConvertFrom-DispatchJson (Get-Content -LiteralPath $chainRecord.scope_plan_path -Raw -Encoding UTF8))
        Resolve-RecoveryHandoffBinding -Path $handoffResult.recoveryHandoffPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -ValidationContext $context
    }

    Invoke-Case 'Phase 4 F-003 all launch-failed chain emits RecoveryHandoffNoChain' {
        $noAnchorRecord = New-TestRun -Line 'line-a' -Dispatch 'phase4-no-anchor'
        $noAnchorRecord = New-Phase3FailedRecord -Record $noAnchorRecord -Message 'fixture launch-failed' -PreparationWithoutScope
        $SourceRoot = $fixtureRoot
        $ExecutionRoot = $fixtureRoot
        $LineSlug = 'line-a'
        $DispatchSlug = 'phase4-no-anchor'
        $RunRecordPath = Join-Path (Get-DispatchRunDirectory $fixtureRoot $LineSlug $DispatchSlug) ($noAnchorRecord.run_id + '.json')
        $WriteMode = 'write'
        $ProcessExitCode = 1
        $RebuildReason = 'launch-failed'
        $RecoveryHandoffPath = Join-Path $fixtureRoot '.local/ai-sessions/history/line-a/recovery-handoff-phase4-no-anchor-22222222222222222222222222222222.json'
        $handoffResult = Invoke-RecoveryHandoff
        Assert-True ($handoffResult.recoveryStatus -eq 'blocked' -and $handoffResult.recoveryEligibility.rejection_codes -contains 'RecoveryHandoffNoChain') '全 launch-failed chain 未輸出 RecoveryHandoffNoChain。'
    }

    Invoke-Case 'Phase 4 F-003 Handoff authorization 擴大 units 時拒絕' -Reject -ErrorPattern 'RecoveryHandoffAuthorizationExpansion' {
        $authorizationRecord = New-TestRun -Line 'line-a' -Dispatch 'phase4-authorization-expansion'
        $authorizationScope = [ordered]@{
            dispatch_slug = 'phase4-authorization-expansion'
            decision = 'full'
            selected_units = @('unit-1')
            deferred_units = @()
            requested_units = @('unit-1')
            scope_plan_fingerprint = 'fixture'
        }
        Write-Utf8NoBom -Path $authorizationRecord.scope_plan_path -Content (($authorizationScope | ConvertTo-Json -Depth 8) + [string][char]10)
        $authorizationRecord.scope_plan_sha256 = Get-FileSha256 $authorizationRecord.scope_plan_path
        $null = Write-DispatchRunRecord -Record $authorizationRecord -Update
        Write-Utf8NoBom -Path $authorizationRecord.event_stream_path -Content (([ordered]@{ type = 'error'; message = 'usage-limit reached' } | ConvertTo-Json -Compress) + [string][char]10)
        Remove-Item -LiteralPath $authorizationRecord.last_message_path -Force -ErrorAction SilentlyContinue
        $SourceRoot = $fixtureRoot
        $ExecutionRoot = $fixtureRoot
        $LineSlug = 'line-a'
        $DispatchSlug = 'phase4-authorization-expansion'
        $RunRecordPath = Join-Path (Get-DispatchRunDirectory $fixtureRoot $LineSlug $DispatchSlug) ($authorizationRecord.run_id + '.json')
        $WriteMode = 'write'
        $ProcessExitCode = 1
        $RebuildReason = 'usage-limit-no-last-message'
        $RecoveryHandoffPath = Join-Path $fixtureRoot '.local/ai-sessions/history/line-a/recovery-handoff-phase4-authorization-expansion-33333333333333333333333333333333.json'
        $handoffResult = Invoke-RecoveryHandoff
        $handoffDocument = (Read-RecoveryHandoff -Path $handoffResult.recoveryHandoffPath -SourceRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug).Document
        $handoffDocument.authorization.requested_units = @('unit-1', 'unit-2')
        Set-TestHandoffDocumentHash -Path $handoffResult.recoveryHandoffPath -Document $handoffDocument
        $scopeObject = ConvertFrom-DispatchJson (Get-Content -LiteralPath $authorizationRecord.scope_plan_path -Raw -Encoding UTF8)
        $context = New-TestHandoffValidationContext -Record $authorizationRecord -ScopePlan $scopeObject
        Resolve-RecoveryHandoffBinding -Path $handoffResult.recoveryHandoffPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -ValidationContext $context
    }
}
if ($Phase -ge 5) {
    foreach ($functionName in @('Get-RequirementIdsFromSummary', 'Get-RequirementTableRows', 'Get-RequirementMap')) {
        $definitionAst = $functions | Where-Object { $_.Name -eq $functionName } | Select-Object -First 1
        . ([scriptblock]::Create($definitionAst.Extent.Text))
    }
    $script:WorkflowCollectContractVersion = 'workflow-collect-v1'

    $phase5RequestPath = Join-Path $fixtureRoot 'phase5-dispatch-request.json'
    $phase5TargetPath = 'C:\work\comma,name\空白 路徑\$literal'
    $phase5AddDirectories = @('C:\dir,with,comma ; C:\中文 路徑', 'C:\dollar\$value')
    $phase5ParentOptions = @('--model=gpt-5.6-luna', '--note=中文 $literal,with,comma')
    $phase5LiteralValues = @($phase5TargetPath, $phase5AddDirectories[0], $phase5ParentOptions[1])
    $phase5RequestDocument = [ordered]@{
        schema               = 'ai-sessions.dispatch-request.v1'
        operation            = 'Start'
        line_slug            = 'line-a'
        dispatch_slug        = 'phase5-request'
        target_path          = @($phase5TargetPath)
        add_directory       = @($phase5AddDirectories)
        search               = $true
        codex_parent_option = @($phase5ParentOptions)
        literal_values      = @($phase5LiteralValues)
    }
    Write-Utf8NoBom -Path $phase5RequestPath -Content (($phase5RequestDocument | ConvertTo-Json -Depth 10) + "
")

    Invoke-Case 'Phase 5 request file 保留 count、order、原文與 SHA-256' {
        $request = Read-DispatchRequest -Path $phase5RequestPath
        Assert-True ($request.schema -ceq 'ai-sessions.dispatch-request.v1' -and $request.length -gt 0 -and $request.sha256 -match '^[a-f0-9]{64}$') 'request schema 或檔案 hash 缺失。'
        Assert-True ((Compare-DispatchStringArrays -Left $request.values.target_path -Right @($phase5TargetPath)) -and $request.values.target_path[0] -ceq $phase5TargetPath) 'target_path 原文或順序遺失。'
        Assert-True ((Compare-DispatchStringArrays -Left $request.values.add_directory -Right $phase5AddDirectories) -and $request.values.add_directory.Count -eq 2) 'add_directory count、順序或原文遺失。'
        Assert-True ((Compare-DispatchStringArrays -Left $request.values.codex_parent_option -Right $phase5ParentOptions) -and $request.values.codex_parent_option[1] -ceq $phase5ParentOptions[1]) 'codex_parent_option 原文或順序遺失。'
        Assert-True ((Compare-DispatchStringArrays -Left $request.values.literal_values -Right $phase5LiteralValues) -and $request.literal_values_sha256 -eq (Get-DispatchStringArraySha256 -Values $phase5LiteralValues)) 'literal_values hash 不一致。'
    }

    Invoke-Case 'Phase 5 request file 套用後維持 CLI 與 parent option 顯式狀態' {
        $script:RequestPath = $phase5RequestPath
        $script:Operation = 'Start'
        $script:LineSlug = 'line-a'
        $script:DispatchSlug = 'phase5-request'
        $script:TargetPath = @($phase5TargetPath)
        $script:AddDirectory = @($phase5AddDirectories)
        $script:Search = $true
        $script:CodexParentOption = @($phase5ParentOptions)
        $script:InvocationBoundParameters = [ordered]@{
            RequestPath = $script:RequestPath
            Operation = $script:Operation
            LineSlug = $script:LineSlug
            DispatchSlug = $script:DispatchSlug
            TargetPath = @($script:TargetPath)
            AddDirectory = @($script:AddDirectory)
            Search = $true
            CodexParentOption = @($script:CodexParentOption)
        }
        $script:AddDirectoryExplicit = $true
        $script:SearchExplicit = $true
        $script:CodexParentOptionExplicit = $true
        $applied = Apply-DispatchRequest
        Assert-True ($applied.sha256 -eq (Get-FileSha256 -Path $phase5RequestPath) -and $script:RequestLiteralValues.Count -eq 3 -and $script:RequestPrepareArtifacts.Count -eq 0) 'request context 套用或 literal_values 保存異常。'
    }

    Invoke-Case 'Phase 5 request／CLI mismatch 在 process start 前拒絕' -Reject -ErrorPattern 'DispatchRequestMismatch|add_directory|process_started' {
        $script:InvocationBoundParameters['AddDirectory'] = @('C:\different')
        $script:AddDirectory = @('C:\different')
        Apply-DispatchRequest
    }

    $phase5UnknownFieldPath = Join-Path $fixtureRoot 'phase5-request-unknown.json'
    $phase5UnknownDocument = [ordered]@{}
    foreach ($property in $phase5RequestDocument.GetEnumerator()) { $phase5UnknownDocument[$property.Key] = $property.Value }
    $phase5UnknownDocument.unknown_field = 'reject'
    Write-Utf8NoBom -Path $phase5UnknownFieldPath -Content (($phase5UnknownDocument | ConvertTo-Json -Depth 10) + "
")
    Invoke-Case 'Phase 5 request schema unknown field 拒絕' -Reject -ErrorPattern 'DispatchRequestUnknownField|unknown_field' {
        Read-DispatchRequest -Path $phase5UnknownFieldPath
    }

    $phase5NullElementPath = Join-Path $fixtureRoot 'phase5-request-null.json'
    $phase5NullDocument = [ordered]@{}
    foreach ($property in $phase5RequestDocument.GetEnumerator()) { $phase5NullDocument[$property.Key] = $property.Value }
    $phase5NullDocument.add_directory = @($phase5AddDirectories[0], $null)
    Write-Utf8NoBom -Path $phase5NullElementPath -Content (($phase5NullDocument | ConvertTo-Json -Depth 10) + "
")
    Invoke-Case 'Phase 5 request array null element 拒絕' -Reject -ErrorPattern 'DispatchRequestNullArrayElement|add_directory' {
        Read-DispatchRequest -Path $phase5NullElementPath
    }

    $phase5MissingIdentityPath = Join-Path $fixtureRoot 'phase5-request-missing-line.json'
    $phase5MissingIdentityDocument = [ordered]@{}
    foreach ($property in $phase5RequestDocument.GetEnumerator()) {
        if ($property.Key -ne 'line_slug') { $phase5MissingIdentityDocument[$property.Key] = $property.Value }
    }
    Write-Utf8NoBom -Path $phase5MissingIdentityPath -Content (($phase5MissingIdentityDocument | ConvertTo-Json -Depth 10) + "
")
    Invoke-Case 'Phase 5 request 缺少 line identity 拒絕' -Reject -ErrorPattern 'DispatchRequestMissingField|line_slug' {
        Read-DispatchRequest -Path $phase5MissingIdentityPath
    }

    $phase5SummaryPath = Join-Path $fixtureRoot 'phase5-requirement-summary.md'
    $phase5SummaryLines = @(
        '# Phase 5 summary'
        ''
        '## 程式面項目'
        ''
        '| # | 項目 | 內容 |'
        '| --- | --- | --- |'
        '| 1 | 程式項目 1 | 驗收方向 1 |'
        '| 2 | 程式項目 2 | 驗收方向 2 |'
        '| 3 | 程式項目 3 | 驗收方向 3 |'
        '| 4 | 程式項目 4 | 驗收方向 4 |'
        '| 5 | 程式項目 5 | 驗收方向 5 |'
        '| 6 | 程式項目 6 | 驗收方向 6 |'
        '| 7 | 程式項目 7 | 驗收方向 7 |'
        ''
        '## 功能面項目'
        ''
        '| # | 項目 | 內容 |'
        '| --- | --- | --- |'
        '| 8 | 功能項目 8 | 驗收方向 8 |'
        '| 9 | 功能項目 9 | 驗收方向 9 |'
    )
    Write-Utf8NoBom -Path $phase5SummaryPath -Content (($phase5SummaryLines -join "
") + "
")
    $phase5ReportPath = Join-Path $fixtureRoot 'phase5-report.md'
    $phase5ReportLines = @(
        '# Phase 5 report'
        ''
        '## 需求對照'
        ''
        '| 需求 | 驗收方向 | T-code | 實際行為 | 證據 | 狀態 |'
        '| --- | --- | --- | --- | --- | --- |'
        '| #1 | 驗收 #1 | T001 | 行為 #1 | evidence-1 | 已交付 |'
        '| #2 | 驗收 #2 | T002 | 行為 #2 | evidence-2 | 已交付 |'
        '| #3 | 驗收 #3 | T003 | 行為 #3 | evidence-3 | 已交付 |'
        '| #4 | 驗收 #4 | T005 | 行為 #4 | evidence-4 | 已交付 |'
        '| #5 | 驗收 #5 | T006 | 行為 #5 | evidence-5 | 部分交付 |'
        '| #6 | 驗收 #6 | T008 | 行為 #6 | evidence-6 | 未交付 |'
        '| #7 | 驗收 #7 | T011 | 行為 #7 | evidence-7 | 已交付 |'
        '| #8 | 驗收 #8 | T002 | 行為 #8 | evidence-8 | 已交付 |'
        '| #9 | 驗收 #9 | T007 | 行為 #9 | evidence-9 | 排除（design.md §8） |'
    )
    Write-Utf8NoBom -Path $phase5ReportPath -Content (($phase5ReportLines -join "
") + "
")

    Invoke-Case 'Phase 5 Collect parser positive contract 與 status 通過' {
        $map = Get-RequirementMap -RequirementSummaryPath $phase5SummaryPath -ReportPath @($phase5ReportPath)
        Assert-True ($map.contractVersion -ceq 'workflow-collect-v1' -and $map.summarySha256 -eq (Get-FileSha256 -Path $phase5SummaryPath) -and $map.reportEvidence.Count -eq 1 -and $map.reportEvidence[0].row_count -eq 9 -and $map.reportRowCount -eq 9) 'Collect contract version、hash 或 row count 不一致。'
        Assert-True ([int]$map.statusCounts['已交付'] -eq 6 -and [int]$map.statusCounts['部分交付'] -eq 1 -and [int]$map.statusCounts['未交付'] -eq 1 -and [int]$map.statusCounts['排除（design.md §8）'] -eq 1) 'Collect 合法 status 統計不一致。'
    }

    $phase5SummaryUnknownHeaderPath = Join-Path $fixtureRoot 'phase5-summary-unknown-header.md'
    $phase5SummaryUnknownText = [IO.File]::ReadAllText($phase5SummaryPath).Replace('| # | 項目 | 內容 |', '| # | 項目 | 未知表頭 |')
    Write-Utf8NoBom -Path $phase5SummaryUnknownHeaderPath -Content $phase5SummaryUnknownText
    Invoke-Case 'Phase 5 summary 未知表頭與欄位診斷' -Reject -ErrorPattern 'invalidSummaryHeader|程式面項目' {
        Get-RequirementMap -RequirementSummaryPath $phase5SummaryUnknownHeaderPath -ReportPath @($phase5ReportPath)
    }

    $phase5ColumnCountPath = Join-Path $fixtureRoot 'phase5-report-column-count.md'
    $phase5ColumnCountText = [IO.File]::ReadAllText($phase5ReportPath).Replace('| #1 | 驗收 #1 | T001 | 行為 #1 | evidence-1 | 已交付 |', '| #1 | 驗收 #1 | T001 | 行為 #1 | evidence-1 |')
    Write-Utf8NoBom -Path $phase5ColumnCountPath -Content $phase5ColumnCountText
    Invoke-Case 'Phase 5 report 欄位數錯誤指出 row' -Reject -ErrorPattern 'invalidColumnCountRows=.*phase5-report-column-count.md#1' {
        Get-RequirementMap -RequirementSummaryPath $phase5SummaryPath -ReportPath @($phase5ColumnCountPath)
    }

    $phase5InvalidStatusPath = Join-Path $fixtureRoot 'phase5-report-invalid-status.md'
    $phase5InvalidStatusText = [IO.File]::ReadAllText($phase5ReportPath).Replace('| #1 | 驗收 #1 | T001 | 行為 #1 | evidence-1 | 已交付 |', '| #1 | 驗收 #1 | T001 | 行為 #1 | evidence-1 | 非法狀態 |')
    Write-Utf8NoBom -Path $phase5InvalidStatusPath -Content $phase5InvalidStatusText
    Invoke-Case 'Phase 5 report 非法狀態指出 row 與 field' -Reject -ErrorPattern 'invalidStatusFields=.*phase5-report-invalid-status.md#1:狀態' {
        Get-RequirementMap -RequirementSummaryPath $phase5SummaryPath -ReportPath @($phase5InvalidStatusPath)
    }

    $phase5DuplicateIdPath = Join-Path $fixtureRoot 'phase5-report-duplicate-id.md'
    $phase5DuplicateIdText = [IO.File]::ReadAllText($phase5ReportPath).Replace('| #2 | 驗收 #2 | T002 | 行為 #2 | evidence-2 | 已交付 |', '| #1 | 驗收 #2 | T002 | 行為 #2 | evidence-2 | 已交付 |')
    Write-Utf8NoBom -Path $phase5DuplicateIdPath -Content $phase5DuplicateIdText
    Invoke-Case 'Phase 5 report 重複需求編號指出 duplicate' -Reject -ErrorPattern 'duplicateRequirementIds=1' {
        Get-RequirementMap -RequirementSummaryPath $phase5SummaryPath -ReportPath @($phase5DuplicateIdPath)
    }
}
if ($Phase -ge 6) {
    function Set-Phase6PrepareRequest {
        param(
            [Parameter(Mandatory)][string]$Dispatch,
            [Parameter(Mandatory)][string]$Source,
            [Parameter(Mandatory)][string]$Destination,
            [Parameter(Mandatory)][string]$Hash,
            [Parameter(Mandatory)][string]$ResultPath
        )

        $requestPath = Join-Path $fixtureRoot ('phase6-request-' + $Dispatch + '.json')
        $requestDocument = [ordered]@{
            schema = 'ai-sessions.dispatch-request.v1'
            operation = 'Prepare'
            line_slug = 'line-a'
            dispatch_slug = $Dispatch
            prepare_artifacts = @([ordered]@{
                    source = $Source
                    destination = $Destination
                    sha256 = $Hash
                    purpose = 'phase6 explicit artifact'
                })
        }
        Write-Utf8NoBom -Path $requestPath -Content ((ConvertTo-Json -InputObject $requestDocument -Depth 10) + "`n")
        $script:RequestPath = $requestPath
        $script:RequestContext = Read-DispatchRequest -Path $requestPath
        $script:RequestPrepareArtifacts = @($script:RequestContext.prepare_artifacts)
        $script:SourceRoot = $fixtureRoot
        $script:ExecutionRoot = $phase6DispatchRoot
        $script:DispatchRoot = $phase6DispatchRoot
        $script:LineSlug = 'line-a'
        $script:DispatchSlug = $Dispatch
        $script:ResultPath = $ResultPath
        $script:PrepareResultPath = $null
        $script:CodexHome = $null
        $script:WriteMode = 'write'
        return $requestPath
    }

    $phase6DispatchRoot = Join-Path $fixtureRoot '.local/ai-sessions/worktrees/phase6-prepare'
    New-Item -ItemType Directory -Path $phase6DispatchRoot -Force | Out-Null
    $phase6SourcePath = Join-Path $phase4LineRoot 'phase6-input.txt'
    $phase6SourceContent = 'phase6 source content'
    Write-Utf8NoBom -Path $phase6SourcePath -Content $phase6SourceContent
    $phase6SourceHash = Get-FileSha256 -Path $phase6SourcePath
    $phase6DestinationPath = Join-Path $phase6DispatchRoot '.local/ai-sessions/handoff/line-a/phase6-input.txt'
    $phase6PrepareResultPath = Join-Path $phase6DispatchRoot '.local/ai-sessions/history/line-a/phase6-prepare-result.json'

    Set-Phase6PrepareRequest -Dispatch 'phase6-prepare' -Source $phase6SourcePath -Destination $phase6DestinationPath -Hash $phase6SourceHash -ResultPath $phase6PrepareResultPath | Out-Null
    Invoke-Case 'Phase 6 Prepare source／destination SHA-256 與 Prepared result' {
        $phase6PrepareOutputs = @(Invoke-Prepare)
        $phase6PrepareNames = New-Object System.Collections.Generic.List[string]
        foreach ($prepareOutput in $phase6PrepareOutputs) {
            if ($prepareOutput -is [System.Collections.IDictionary]) {
                foreach ($key in @($prepareOutput.Keys)) { $phase6PrepareNames.Add([string]$key) }
            }
            else {
                foreach ($property in @($prepareOutput.PSObject.Properties)) { $phase6PrepareNames.Add([string]$property.Name) }
            }
        }
        $phase6PrepareNames = @($phase6PrepareNames.ToArray() | Sort-Object -Unique)
        Assert-True ($phase6PrepareOutputs.Count -eq 1 -and $phase6PrepareNames -contains 'prepareResultPath') ('Prepare operation result shape 異常：count=' + $phase6PrepareOutputs.Count + '; types=' + (($phase6PrepareOutputs | ForEach-Object { $_.GetType().FullName }) -join ',') + '; properties=' + ($phase6PrepareNames -join ','))
        $script:phase6Prepared = $phase6PrepareOutputs[0]
        $binding = Resolve-PrepareResultBinding -Path $script:phase6Prepared.prepareResultPath -SourceRoot $fixtureRoot -ExecutionRoot $phase6DispatchRoot -LineSlug 'line-a' -DispatchSlug 'phase6-prepare' -ExpectedSha256 $script:phase6Prepared.prepareResultSha256
        Assert-True ($script:phase6Prepared.status -eq 'Prepared' -and $binding.Status -eq 'Prepared' -and $binding.Artifacts.Count -eq 1) 'Prepare result 未標記 Prepared。'
        Assert-True ((Get-FileSha256 -Path $phase6SourcePath) -eq (Get-FileSha256 -Path $phase6DestinationPath) -and (Get-Content -LiteralPath $phase6DestinationPath -Raw -Encoding UTF8) -eq $phase6SourceContent) 'Prepare artifact source／destination 內容或 hash 不一致。'
        Assert-True ($binding.Document.effective_codex_home -eq (Resolve-CodexHomeForEvidence -CodexHomePath $null)) 'Prepare result 未保存有效 CodexHome。'
    }

    $phase6MinimalDispatchRoot = Join-Path $fixtureRoot '.local/ai-sessions/worktrees/phase6-minimal-request'
    $phase6MinimalDestinationPath = Join-Path $phase6MinimalDispatchRoot '.local/ai-sessions/handoff/line-a/minimal-input.txt'
    $phase6MinimalRequestPath = Join-Path $fixtureRoot 'phase6-minimal-request.json'
    $phase6MinimalResultPath = Join-Path $phase6MinimalDispatchRoot '.local/ai-sessions/history/line-a/prepare-result.json'
    Invoke-Case 'Phase 6 最小 request 實際執行 Prepare exit 0' {
        $minimalRequest = [ordered]@{
            schema = 'ai-sessions.dispatch-request.v1'
            operation = 'Prepare'
            line_slug = 'line-a'
            dispatch_slug = 'phase6-minimal-request'
            prepare_artifacts = @([ordered]@{
                    source = $phase6SourcePath
                    destination = $phase6MinimalDestinationPath
                    sha256 = $phase6SourceHash
                    purpose = 'minimal Prepare regression'
                })
        }
        Write-Utf8NoBom -Path $phase6MinimalRequestPath -Content (($minimalRequest | ConvertTo-Json -Depth 10) + "`n")
        New-Item -ItemType Directory -Path $phase6MinimalDispatchRoot -Force | Out-Null
        $hostPath = if ($PSVersionTable.PSEdition -eq 'Desktop') {
            Join-Path $PSHOME 'powershell.exe'
        }
        else {
            $hostCommand = Get-Command -Name 'pwsh' -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($hostCommand.Source)) { $hostCommand.Path } else { $hostCommand.Source }
        }
        $arguments = @(
            '-NoProfile'
            '-File'
            $sourcePath
            '-Operation'
            'Prepare'
            '-SourceRoot'
            $fixtureRoot
            '-ExecutionRoot'
            $phase6MinimalDispatchRoot
            '-DispatchRoot'
            $phase6MinimalDispatchRoot
            '-LineSlug'
            'line-a'
            '-DispatchSlug'
            'phase6-minimal-request'
            '-WriteMode'
            'write'
            '-RequestPath'
            $phase6MinimalRequestPath
            '-ResultPath'
            $phase6MinimalResultPath
        )
        $processOutput = @(& $hostPath @arguments 2>&1)
        $processExitCode = $LASTEXITCODE
        $script:phase6MinimalPrepareOutput = ($processOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        Assert-True ($processExitCode -eq 0) ('最小 request Prepare exit code 異常：' + $processExitCode + '; output=' + $script:phase6MinimalPrepareOutput)
        Assert-True (Test-Path -LiteralPath $phase6MinimalResultPath -PathType Leaf) '最小 request Prepare 未寫出結果檔。'
        $minimalResult = Get-Content -LiteralPath $phase6MinimalResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($minimalResult.status -eq 'Prepared' -and @($minimalResult.artifacts).Count -eq 1 -and (Test-Path -LiteralPath $phase6MinimalDestinationPath -PathType Leaf)) '最小 request Prepare 結果或 artifact 不符。'
        Assert-True ($script:phase6MinimalPrepareOutput -match '"dispatch_request"' -and $script:phase6MinimalPrepareOutput -match '"count"\s*:\s*0') '最小 request 缺少陣列的 evidence 未正確序列化。'
    }

    $phase6DirectResultPath = Join-Path $fixtureRoot '.local/ai-sessions/history/line-a/phase6-direct-result.json'
    Invoke-Case 'Phase 6 direct-write Prepare not-required' {
        $script:RequestContext = $null
        $script:RequestPrepareArtifacts = @()
        $script:RequestPath = $null
        $script:SourceRoot = $fixtureRoot
        $script:ExecutionRoot = $fixtureRoot
        $script:DispatchRoot = $fixtureRoot
        $script:LineSlug = 'line-a'
        $script:DispatchSlug = 'phase6-direct'
        $script:ResultPath = $phase6DirectResultPath
        $script:PrepareResultPath = $null
        $script:CodexHome = $null
        $script:phase6DirectResult = Invoke-Prepare
        $directBinding = Resolve-PrepareResultBinding -Path $script:phase6DirectResult.prepareResultPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug 'phase6-direct' -ExpectedSha256 $script:phase6DirectResult.prepareResultSha256
        Assert-True ($script:phase6DirectResult.status -eq 'not-required' -and $directBinding.Status -eq 'not-required' -and $directBinding.Artifacts.Count -eq 0) 'direct-write 未產生 not-required result。'
    }

    Invoke-Case 'Phase 6 CodexHome fallback 寫入 Prepare result' {
        $hadCodexHome = Test-Path Env:CODEX_HOME
        $oldCodexHome = $env:CODEX_HOME
        try {
            Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
            $expectedCodexHome = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.codex'
            $actualCodexHome = Resolve-CodexHomeForEvidence -CodexHomePath $null
            Assert-True ($actualCodexHome -eq (Resolve-AbsolutePath -Path $expectedCodexHome)) 'CodexHome fallback 順序或有效值異常。'
            Assert-True ($script:phase6DirectResult.effectiveCodexHome -eq $actualCodexHome) 'direct-write result 未保存 fallback CodexHome。'
        }
        finally {
            if ($hadCodexHome) { $env:CODEX_HOME = $oldCodexHome } else { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
        }
    }

    $phase6PreflightSourceDocument = Join-Path $phase4LineRoot 'design.md'
    $phase6PreflightSourceContent = 'phase6 preflight source document'
    Write-Utf8NoBom -Path $phase6PreflightSourceDocument -Content $phase6PreflightSourceContent
    $phase6PreflightDispatchRoot = Join-Path $fixtureRoot '.local/ai-sessions/worktrees/phase6-preflight'
    function Get-ExistingGitRepositoryState { return [pscustomobject]@{ IsRepository = $false } }
    Invoke-Case 'Phase 6 Preflight verify-only 不複製交接物' {
        $preflightText = ($functions | Where-Object { $_.Name -eq 'Invoke-Preflight' }).Extent.Text
        Assert-True (-not $preflightText.Contains('Copy-Item') -and -not $preflightText.Contains('handoffFileName')) 'Preflight 仍包含交接物複製路徑。'
        $script:SourceRoot = $fixtureRoot
        $script:DispatchRoot = $phase6PreflightDispatchRoot
        $script:ExecutionRoot = $null
        $script:LineSlug = 'line-a'
        $script:DispatchSlug = 'phase6-preflight'
        $script:TargetPath = @('phase6-preflight-target.txt')
        $script:WriteMode = 'write'
        $script:PrepareResultPath = $null
        $preflightResult = Invoke-Preflight
        Assert-True ($preflightResult.prepareStatus -eq 'not-required' -and (Get-Content -LiteralPath $phase6PreflightSourceDocument -Raw -Encoding UTF8) -eq $phase6PreflightSourceContent) 'Preflight verify-only 改寫了來源交接物。'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $phase6PreflightDispatchRoot '.local/ai-sessions/handoff/line-a/design.md'))) 'Preflight 不應建立 worktree 交接物副本。'
    }

    $phase6MissingSourcePath = Join-Path $phase4LineRoot 'phase6-missing.txt'
    Set-Phase6PrepareRequest -Dispatch 'phase6-missing-source' -Source $phase6MissingSourcePath -Destination (Join-Path $phase6DispatchRoot '.local/ai-sessions/handoff/line-a/missing.txt') -Hash $phase6SourceHash -ResultPath (Join-Path $phase6DispatchRoot '.local/ai-sessions/history/line-a/missing-result.json') | Out-Null
    Invoke-Case 'Phase 6 Prepare missing artifact 拒絕' -Reject -ErrorPattern 'PrepareArtifactMismatch|不存在' {
        Invoke-Prepare
    }

    $phase6EmptyArtifactsDispatch = 'phase6-empty-artifacts-failure'
    $phase6EmptyArtifactsResultPath = Join-Path $phase6DispatchRoot ('.local/ai-sessions/history/line-a/' + $phase6EmptyArtifactsDispatch + '-result.json')
    Set-Phase6PrepareRequest -Dispatch $phase6EmptyArtifactsDispatch -Source $phase6MissingSourcePath -Destination (Join-Path $phase6DispatchRoot '.local/ai-sessions/handoff/line-a/empty-artifacts.txt') -Hash $phase6SourceHash -ResultPath $phase6EmptyArtifactsResultPath | Out-Null
    Invoke-Case 'Phase 6 規劃前 Prepare failure artifacts 為空陣列' {
        $caughtException = $null
        try {
            Invoke-Prepare
        }
        catch {
            $caughtException = $_.Exception
        }
        Assert-True ($null -ne $caughtException) '規劃前 Prepare failure 未回傳例外。'
        $failureDocument = Get-Content -LiteralPath $phase6EmptyArtifactsResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($failureDocument.status -eq 'PrepareFailed' -and @($failureDocument.artifacts).Count -eq 0) '規劃前 Prepare failure artifacts 未序列化為空陣列。'
    }

    $phase6OutsideSourcePath = Join-Path $fixtureRoot 'phase6-outside-source.txt'
    Write-Utf8NoBom -Path $phase6OutsideSourcePath -Content 'outside source'
    Set-Phase6PrepareRequest -Dispatch 'phase6-source-boundary' -Source $phase6OutsideSourcePath -Destination (Join-Path $phase6DispatchRoot '.local/ai-sessions/handoff/line-a/outside-source.txt') -Hash $phase6SourceHash -ResultPath (Join-Path $phase6DispatchRoot '.local/ai-sessions/history/line-a/source-boundary-result.json') | Out-Null
    Invoke-Case 'Phase 6 Prepare source boundary 拒絕' -Reject -ErrorPattern 'PrepareArtifactMismatch|source line root' {
        Invoke-Prepare
    }

    $phase6OutsideDestinationPath = Join-Path $fixtureRoot 'phase6-outside-destination.txt'
    Set-Phase6PrepareRequest -Dispatch 'phase6-destination-boundary' -Source $phase6SourcePath -Destination $phase6OutsideDestinationPath -Hash $phase6SourceHash -ResultPath (Join-Path $phase6DispatchRoot '.local/ai-sessions/history/line-a/destination-boundary-result.json') | Out-Null
    Invoke-Case 'Phase 6 Prepare destination boundary 拒絕' -Reject -ErrorPattern 'PrepareArtifactMismatch|允許 root' {
        Invoke-Prepare
    }

    Invoke-Case 'Phase 6 destination hash changed 拒絕' -Reject -ErrorPattern 'PrepareArtifactMismatch|hash 不一致' {
        Write-Utf8NoBom -Path $phase6DestinationPath -Content 'changed destination'
        try {
            Resolve-PrepareResultBinding -Path $script:phase6Prepared.prepareResultPath -SourceRoot $fixtureRoot -ExecutionRoot $phase6DispatchRoot -LineSlug 'line-a' -DispatchSlug 'phase6-prepare' -ExpectedSha256 $script:phase6Prepared.prepareResultSha256
        }
        finally {
            Write-Utf8NoBom -Path $phase6DestinationPath -Content $phase6SourceContent
        }
    }

    Invoke-Case 'Phase 6 Prepare result missing 拒絕' -Reject -ErrorPattern 'PreparedResultMissing' {
        Resolve-PrepareResultBinding -Path (Join-Path $phase6DispatchRoot '.local/ai-sessions/history/line-a/missing-prepare-result.json') -SourceRoot $fixtureRoot -ExecutionRoot $phase6DispatchRoot -LineSlug 'line-a' -DispatchSlug 'phase6-prepare'
    }

    Invoke-Case 'Phase 6 Prepare result hash changed 拒絕' -Reject -ErrorPattern 'PrepareArtifactMismatch|hash 不一致' {
        $originalResultContent = Get-Content -LiteralPath $script:phase6Prepared.prepareResultPath -Raw -Encoding UTF8
        try {
            Write-Utf8NoBom -Path $script:phase6Prepared.prepareResultPath -Content ($originalResultContent + "`n")
            Resolve-PrepareResultBinding -Path $script:phase6Prepared.prepareResultPath -SourceRoot $fixtureRoot -ExecutionRoot $phase6DispatchRoot -LineSlug 'line-a' -DispatchSlug 'phase6-prepare' -ExpectedSha256 $script:phase6Prepared.prepareResultSha256
        }
        finally {
            Write-Utf8NoBom -Path $script:phase6Prepared.prepareResultPath -Content $originalResultContent
        }
    }

    $phase6StartDispatchRoot = Join-Path $fixtureRoot '.local/ai-sessions/worktrees/phase6-start-missing'
    New-Item -ItemType Directory -Path $phase6StartDispatchRoot -Force | Out-Null
    $phase6StartPreflightPath = Join-Path $fixtureRoot 'phase6-start-missing-preflight.json'
    Write-Utf8NoBom -Path $phase6StartPreflightPath -Content (([ordered]@{ sourceRoot = $fixtureRoot; executionRoot = $phase6StartDispatchRoot; dispatchRoot = $phase6StartDispatchRoot; lineSlug = 'line-a'; dispatchSlug = 'phase6-start-missing'; writeMode = 'write' } | ConvertTo-Json) + "`n")
    $phase6MissingPromptPath = Join-Path $fixtureRoot 'phase6-missing-prompt.md'
    Write-Utf8NoBom -Path $phase6MissingPromptPath -Content 'phase6 missing prepared prompt'
    Invoke-Case 'Phase 6 worktree Start 缺少 Prepared 不建立 process' -Reject -ErrorPattern 'PrepareRequired' {
        $script:SourceRoot = $fixtureRoot
        $script:ExecutionRoot = $phase6StartDispatchRoot
        $script:DispatchRoot = $phase6StartDispatchRoot
        $script:LineSlug = 'line-a'
        $script:DispatchSlug = 'phase6-start-missing'
        $script:PreflightResultPath = $phase6StartPreflightPath
        $script:PrepareResultPath = $null
        $script:PromptPath = $phase6MissingPromptPath
        $beforeStartCalls = $script:startCalls
        try { Invoke-Start }
        finally { Assert-True ($script:startCalls -eq $beforeStartCalls) 'Prepare gate 失敗後仍建立 Codex process。' }
    }

    $phase6QuotaFailurePreflightPath = Join-Path $fixtureRoot 'phase6-quota-failure-preflight.json'
    Write-Utf8NoBom -Path $phase6QuotaFailurePreflightPath -Content (([ordered]@{ sourceRoot = $fixtureRoot; executionRoot = $fixtureRoot; lineSlug = 'line-a'; dispatchSlug = 'phase6-quota-failure'; writeMode = 'readonly' } | ConvertTo-Json) + "`n")
    $phase6PromptPath = Join-Path $fixtureRoot 'phase6-prompt.md'
    Write-Utf8NoBom -Path $phase6PromptPath -Content 'phase6 prompt'
    Invoke-Case 'Phase 6 quota-before 失敗不建立 process' -Reject -ErrorPattern 'quota fixture failure' {
        $script:SourceRoot = $fixtureRoot
        $script:ExecutionRoot = $fixtureRoot
        $script:DispatchRoot = $fixtureRoot
        $script:LineSlug = 'line-a'
        $script:DispatchSlug = 'phase6-quota-failure'
        $script:PreflightResultPath = $phase6QuotaFailurePreflightPath
        $script:PromptPath = $phase6PromptPath
        $script:PrepareResultPath = $null
        $script:QuotaBeforePath = $null
        $script:CodexHome = $null
        $script:quotaFixtureFailure = $true
        $beforeStartCalls = $script:startCalls
        try { Invoke-Start }
        finally {
            $script:quotaFixtureFailure = $false
            Assert-True ($script:startCalls -eq $beforeStartCalls) 'quota-before 失敗後仍建立 Codex process。'
        }
    }

    Invoke-BaselineCase 'Phase 6 worktree ScopePlan preparation failure 保存 launch-failed RunRecord' {
        $phase6WorktreeFailurePromptPath = Join-Path $DispatchRoot '.local/prompt.md'
        Write-Utf8NoBom -Path $phase6WorktreeFailurePromptPath -Content 'phase6 worktree ScopePlan failure prompt'
        $script:SourceRoot = $fixtureRoot
        $script:ExecutionRoot = $DispatchRoot
        $script:DispatchRoot = $DispatchRoot
        $script:LineSlug = $LineSlug
        $script:DispatchSlug = $DispatchSlug
        $script:PreflightResultPath = $PreflightResultPath
        $script:PromptPath = $phase6WorktreeFailurePromptPath
        $script:PrepareResultPath = $fixturePrepareResultPath
        $script:QuotaBeforePath = $null
        $script:QuotaAfterPath = $null
        $script:ScopePlanPath = $null
        $script:CodexHome = $startCodexHome
        $script:Model = $null
        $script:ReasoningEffort = $null
        $script:Profile = 'default'
        $script:TaskType = 'unspecified'
        $script:DispatchKind = 'workflow'
        $script:SessionMode = 'cold-start'
        $script:ResumeThreadId = $null
        $script:LastMessagePath = $null
        $script:ThreadIdPath = $null
        $script:PidRecordPath = $null
        $script:AddDirectory = $null
        $script:Search = $false
        $script:CodexParentOption = $null
        $script:InvocationBoundParameters = [ordered]@{}
        $script:AddDirectoryExplicit = $false
        $script:SearchExplicit = $false
        $script:CodexParentOptionExplicit = $false
        $script:scopePlanFixtureDecision = 'blocked-no-fresh-quota'
        $beforeStartCalls = $script:startCalls
        $caughtException = $null
        try {
            try {
                Invoke-Start
            }
            catch {
                $caughtException = $_.Exception
            }
            $operationResult = if ($null -eq $caughtException) { $null } else { $caughtException.Data['operationResult'] }
            Assert-True ($null -ne $operationResult -and -not $operationResult.processStarted -and $operationResult.errorCode -eq 'QuotaStop') 'ScopePlan preparation failure 未回傳結構化結果。'
            $recordPath = [string]$operationResult.runRecordPath
            Assert-True (-not [string]::IsNullOrWhiteSpace($recordPath) -and (Test-Path -LiteralPath $recordPath -PathType Leaf)) 'ScopePlan preparation failure 未保存 RunRecord。'
            $record = Read-DispatchRunRecord -Path $recordPath -SourceRoot $fixtureRoot -ExecutionRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
            $writeError = Get-DispatchJsonProperty -Object $record.failure -Name 'write_error'
            Assert-True ($record.launch_state -eq 'launch-failed' -and $record.failure.phase -eq 'preparation' -and -not [string]::IsNullOrWhiteSpace($record.baseline_path) -and $record.baseline_sha256 -match '^[a-f0-9]{64}$' -and $null -eq $writeError -and $script:startCalls -eq $beforeStartCalls) 'ScopePlan preparation failure RunRecord 缺少 Baseline 或仍有寫入錯誤。'
        }
        finally {
            $script:scopePlanFixtureDecision = 'full'
        }
    }

    Invoke-BaselineCase 'Phase 6 T009 baseline 缺失仍保存 launch-failed RunRecord 且不啟動 process' {
        $preflightDocument = ConvertFrom-DispatchJson -Content (Get-Content -LiteralPath $PreflightResultPath -Raw -Encoding UTF8)
        $preflightDocument.PSObject.Properties.Remove('baselinePath')
        $preflightDocument.PSObject.Properties.Remove('baselineSha256')
        Write-Utf8NoBom -Path $PreflightResultPath -Content (($preflightDocument | ConvertTo-Json -Depth 10) + "`n")
        $missingBaselinePromptPath = Join-Path $DispatchRoot '.local/prompt-missing-baseline.md'
        Write-Utf8NoBom -Path $missingBaselinePromptPath -Content 'phase6 missing baseline prompt'
        $script:SourceRoot = $fixtureRoot
        $script:ExecutionRoot = $DispatchRoot
        $script:DispatchRoot = $DispatchRoot
        $script:LineSlug = $LineSlug
        $script:DispatchSlug = $DispatchSlug
        $script:PreflightResultPath = $PreflightResultPath
        $script:PromptPath = $missingBaselinePromptPath
        $script:PrepareResultPath = $fixturePrepareResultPath
        $script:QuotaBeforePath = $null
        $script:QuotaAfterPath = $null
        $script:ScopePlanPath = $null
        $script:CodexHome = $null
        $script:Model = $null
        $script:ReasoningEffort = $null
        $script:Profile = 'default'
        $script:ProfileExplicit = $false
        $script:TaskType = 'unspecified'
        $script:DispatchKind = 'workflow'
        $script:SessionMode = 'cold-start'
        $script:ResumeThreadId = $null
        $script:LastMessagePath = $null
        $script:ThreadIdPath = $null
        $script:PidRecordPath = $null
        $script:AddDirectory = $null
        $script:Search = $false
        $script:CodexParentOption = $null
        $script:InvocationBoundParameters = [ordered]@{}
        $script:AddDirectoryExplicit = $false
        $script:SearchExplicit = $false
        $script:CodexParentOptionExplicit = $false
        $script:scopePlanFixtureDecision = 'full'
        $beforeStartCalls = $script:startCalls
        $caughtException = $null
        try {
            try {
                Invoke-Start
            }
            catch {
                $caughtException = $_.Exception
            }
            $operationResult = if ($null -eq $caughtException) { $null } else { $caughtException.Data['operationResult'] }
            Assert-True ($null -ne $operationResult -and -not $operationResult.processStarted -and $operationResult.errorCode -eq 'BaselineUnknown') 'baseline 缺失未回傳結構化 BaselineUnknown 結果。'
            $recordPath = [string]$operationResult.runRecordPath
            Assert-True (-not [string]::IsNullOrWhiteSpace($recordPath) -and (Test-Path -LiteralPath $recordPath -PathType Leaf)) 'baseline 缺失未保存 RunRecord。'
            $rawRecord = ConvertFrom-DispatchJson -Content (Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8)
            $baselineResolution = $rawRecord.baseline_resolution
            Assert-True ($rawRecord.launch_state -eq 'launch-failed' -and $rawRecord.failure.reason_code -eq 'BaselineUnknown' -and $baselineResolution.status -eq 'failed' -and -not [string]::IsNullOrWhiteSpace($baselineResolution.error) -and $baselineResolution.query_location -eq 'Preflight.baselinePath,Preflight.baselineSha256' -and $script:startCalls -eq $beforeStartCalls) 'baseline 缺失 RunRecord 未保存失敗原因／查詢位置或仍啟動 process。'
            $validatedRecord = Read-DispatchRunRecord -Path $recordPath -SourceRoot $fixtureRoot -ExecutionRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
            Assert-True ($validatedRecord.launch_state -eq 'launch-failed') 'baseline 缺失 RunRecord 無法通過 validator。'
        }
        finally {
            $script:scopePlanFixtureDecision = 'full'
        }
    }

    function Invoke-Phase6RealGit {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$WorkingDirectory,
            [Parameter(Mandatory)][string[]]$Arguments
        )

        $output = @(& git -C $WorkingDirectory @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        $outputText = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        if ($exitCode -ne 0) {
            throw ('Git fixture command failed, exit=' + $exitCode + '; output=' + $outputText)
        }
        return $outputText
    }

    Invoke-Case 'Phase 6 T010 真實 Git worktree 套用 carry-in 且不複製交接物' {
        $null = Get-Command -Name 'git' -ErrorAction Stop
        $realGitRoot = Join-Path $fixtureRoot 'phase6-real-git'
        $realSourceRoot = Join-Path $realGitRoot 'source'
        $realDispatchRoot = Join-Path $realSourceRoot '.local/ai-sessions/worktrees/phase6-real-git'
        $realLineRoot = Join-Path $realSourceRoot '.local/ai-sessions/handoff/line-real'
        New-Item -ItemType Directory -Path $realSourceRoot, $realLineRoot -Force | Out-Null
        Write-Utf8NoBom -Path (Join-Path $realSourceRoot '.gitignore') -Content ".local/`n"
        Write-Utf8NoBom -Path (Join-Path $realSourceRoot 'tracked.txt') -Content 'HEAD content'
        $null = Invoke-Phase6RealGit -WorkingDirectory $realSourceRoot -Arguments @('init', '--quiet')
        $null = Invoke-Phase6RealGit -WorkingDirectory $realSourceRoot -Arguments @('config', 'user.email', 'phase6@example.invalid')
        $null = Invoke-Phase6RealGit -WorkingDirectory $realSourceRoot -Arguments @('config', 'user.name', 'Phase 6 Fixture')
        $null = Invoke-Phase6RealGit -WorkingDirectory $realSourceRoot -Arguments @('add', '--', '.gitignore', 'tracked.txt')
        $null = Invoke-Phase6RealGit -WorkingDirectory $realSourceRoot -Arguments @('commit', '--quiet', '-m', 'phase6 initial')
        Write-Utf8NoBom -Path (Join-Path $realSourceRoot 'tracked.txt') -Content 'carry-in tracked content'
        Write-Utf8NoBom -Path (Join-Path $realSourceRoot 'carry-in.txt') -Content 'carry-in untracked content'
        Write-Utf8NoBom -Path (Join-Path $realLineRoot 'line.json') -Content (([ordered]@{ schema = 'ai-sessions.line.v1'; 'line-slug' = 'line-real' } | ConvertTo-Json) + "`n")
        Write-Utf8NoBom -Path (Join-Path $realLineRoot 'requirement-summary.md') -Content '# Real Git requirement fixture'
        Write-Utf8NoBom -Path (Join-Path $realLineRoot 'design.md') -Content '# Real Git design fixture'
        $hostPath = if ($PSVersionTable.PSEdition -eq 'Desktop') {
            Join-Path $PSHOME 'powershell.exe'
        }
        else {
            $hostCommand = Get-Command -Name 'pwsh' -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($hostCommand.Source)) { $hostCommand.Path } else { $hostCommand.Source }
        }
        $realArguments = @(
            '-NoProfile'
            '-File'
            $sourcePath
            '-Operation'
            'Preflight'
            '-SourceRoot'
            $realSourceRoot
            '-DispatchRoot'
            $realDispatchRoot
            '-LineSlug'
            'line-real'
            '-DispatchSlug'
            'phase6-real-git'
            '-WriteMode'
            'write'
            '-TargetPath'
            'tracked.txt'
        )
        $realOutput = @(& $hostPath @realArguments 2>&1)
        $realExitCode = $LASTEXITCODE
        $realOutputText = ($realOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        Assert-True ($realExitCode -eq 0) ('真實 Git Preflight exit code 異常：' + $realExitCode + '; output=' + $realOutputText)
        $realResult = ConvertFrom-DispatchJson -Content $realOutputText
        $carryIn = $realResult.carryInManifest
        Assert-True ($realResult.worktreeCreated -eq $true -and $carryIn.TrackedPatchApplied -eq $true -and $carryIn.UntrackedFiles -contains 'carry-in.txt' -and $carryIn.CopiedFiles -contains 'carry-in.txt') '真實 Git worktree 未套用 tracked patch 或 untracked carry-in。'
        $realTrackedPath = Join-Path $realDispatchRoot 'tracked.txt'
        $realUntrackedPath = Join-Path $realDispatchRoot 'carry-in.txt'
        Assert-True ((Get-Content -LiteralPath $realTrackedPath -Raw -Encoding UTF8) -eq 'carry-in tracked content' -and (Get-Content -LiteralPath $realUntrackedPath -Raw -Encoding UTF8) -eq 'carry-in untracked content') 'carry-in 內容未進入真實 worktree。'
        foreach ($handoffFile in @('line.json', 'requirement-summary.md', 'design.md')) {
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $realDispatchRoot ('.local/ai-sessions/handoff/line-real/' + $handoffFile)) -PathType Leaf)) ('Preflight 不應複製交接物：' + $handoffFile)
        }
        Assert-True ($realResult.baselinePath -and (Test-Path -LiteralPath $realResult.baselinePath -PathType Leaf) -and $realResult.baselineSha256 -match '^[a-f0-9]{64}$') '真實 Git Preflight 未建立 Baseline。'
    }

    $phase6StartSuccessPreflightPath = Join-Path $fixtureRoot 'phase6-start-success-preflight.json'
    Write-Utf8NoBom -Path $phase6StartSuccessPreflightPath -Content (([ordered]@{ sourceRoot = $fixtureRoot; executionRoot = $fixtureRoot; lineSlug = 'line-a'; dispatchSlug = 'phase6-start-success'; writeMode = 'readonly' } | ConvertTo-Json) + "`n")
    Invoke-Case 'Phase 6 Start 自動 quota-before 與 RunRecord binding' {
        $hadCodexHome = Test-Path Env:CODEX_HOME
        $oldCodexHome = $env:CODEX_HOME
        try {
            Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
            $script:SourceRoot = $fixtureRoot
            $script:ExecutionRoot = $fixtureRoot
            $script:DispatchRoot = $fixtureRoot
            $script:LineSlug = 'line-a'
            $script:DispatchSlug = 'phase6-start-success'
            $script:PreflightResultPath = $phase6StartSuccessPreflightPath
            $script:PromptPath = $phase6PromptPath
            $script:PrepareResultPath = $null
            $script:QuotaBeforePath = $null
            $script:CodexHome = $null
            $script:ResumeThreadId = $null
            $script:LastMessagePath = $null
            $script:ThreadIdPath = $null
            $script:PidRecordPath = $null
            $script:ScopePlanPath = $null
            $script:QuotaAfterPath = $null
            $script:DispatchKind = 'workflow'
            $script:TaskType = 'unspecified'
            $script:Profile = 'default'
            $script:SessionMode = 'cold-start'
            $script:AddDirectory = $null
            $script:Search = $false
            $script:CodexParentOption = $null
            $script:InvocationBoundParameters = [ordered]@{}
            $script:AddDirectoryExplicit = $false
            $script:SearchExplicit = $false
            $script:CodexParentOptionExplicit = $false
            $startResult = Invoke-Start
            $record = Read-DispatchRunRecord -Path $startResult.runRecordPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug 'phase6-start-success'
            $fallbackCodexHome = Resolve-CodexHomeForEvidence -CodexHomePath $null
            Assert-True ($startResult.quotaBeforePath -and (Test-Path -LiteralPath $startResult.quotaBeforePath -PathType Leaf) -and $startResult.quotaBeforeSha256 -match '^[a-f0-9]{64}$') 'Start 未建立 quota-before path／hash。'
            Assert-True ($startResult.effectiveCodexHome -eq $fallbackCodexHome -and $record.effective_codex_home -eq $fallbackCodexHome) 'Start 未將 fallback CodexHome 寫入結果與 RunRecord。'
            Assert-True ($record.quota_before_path -eq $startResult.quotaBeforePath -and $record.quota_before_sha256 -eq $startResult.quotaBeforeSha256 -and $record.prepare_status -eq 'not-required') 'RunRecord quota-before 或 Prepare binding 欄位不一致。'
        }
        finally {
            if ($hadCodexHome) { $env:CODEX_HOME = $oldCodexHome } else { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
        }
    }
}
if ($Phase -ge 7) {
    foreach ($functionName in @(
            'Read-QuotaSnapshot',
            'Test-QuotaSnapshotFresh',
            'Test-QuotaSnapshotHasObservations',
            'Get-QuotaSnapshotFreshness',
            'Get-QuotaSnapshotServiceRejection',
            'Get-QuotaSnapshotServiceRejectionEvidence',
            'Get-AdvisorActivationDecision',
            'New-ScopePlan',
            'Get-ScopePlanFingerprint',
            'Test-ScopePlanCompleteness',
            'Get-CalibrationRecords',
            'Add-AtomicJsonLine',
            'Add-CalibrationObservation',
            'Invoke-QuotaProbe'
        )) {
        $definitionAst = $functions | Where-Object { $_.Name -eq $functionName } | Select-Object -First 1
        if ($null -eq $definitionAst) {
            throw "Phase 7 找不到 production function：$functionName"
        }
        $definitionText = $definitionAst.Extent.Text
        if ($functionName -eq 'Invoke-QuotaProbe') {
            $definitionText = $definitionText.Replace('$process = New-Object System.Diagnostics.Process', '$process = New-TestProcess')
        }
        . ([scriptblock]::Create($definitionText))
    }

    function Write-Phase7JsonLines {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][object[]]$Objects
        )

        $lines = @($Objects | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress })
        Write-Utf8NoBom -Path $Path -Content (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
    }

    function Invoke-Phase7QuotaScript {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$CodexHomePath,
            [Parameter(Mandatory)][string]$SnapshotPath
        )

        $quotaScriptPath = Join-Path $PSScriptRoot 'Get-CodexQuota.ps1'
        $hostPath = if ($PSVersionTable.PSEdition -eq 'Desktop') {
            Join-Path $PSHOME 'powershell.exe'
        }
        else {
            $hostCommand = Get-Command -Name 'pwsh' -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($hostCommand.Source)) { $hostCommand.Path } else { $hostCommand.Source }
        }
        $arguments = @(
            '-NoProfile'
            '-File'
            $quotaScriptPath
            '-CodexHome'
            $CodexHomePath
            '-SnapshotPath'
            $SnapshotPath
        )
        $output = & $hostPath @arguments 2>&1
        return [pscustomobject]@{
            exit_code = $LASTEXITCODE
            output = @($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
            host_path = $hostPath
            script_path = $quotaScriptPath
        }
    }

    $phase7Root = Join-Path $fixtureRoot 'phase7-quota'
    $phase7CodexHome = Join-Path $phase7Root 'codex-home'
    $phase7SessionsPath = Join-Path $phase7CodexHome 'sessions'
    New-Item -ItemType Directory -Path $phase7SessionsPath -Force | Out-Null
    $phase7RolloutPath = Join-Path $phase7SessionsPath 'rollout-phase7.jsonl'
    $phase7ValidSnapshotPath = Join-Path $phase7Root 'valid-snapshot.json'
    $phase7RejectedSnapshotPath = Join-Path $phase7Root 'rejected-snapshot.json'
    $phase7Now = [DateTimeOffset]::UtcNow
    $phase7PrimaryReset = $phase7Now.AddHours(2).ToUnixTimeSeconds()
    $phase7SecondaryReset = $phase7Now.AddDays(5).ToUnixTimeSeconds()
    $phase7ValidEvent = [ordered]@{
        timestamp = $phase7Now.ToString('o')
        payload = [ordered]@{
            rate_limits = [ordered]@{
                primary = [ordered]@{ used_percent = 40; window_minutes = 120; resets_at = $phase7PrimaryReset }
                secondary = [ordered]@{ used_percent = 50; window_minutes = 10080; resets_at = $phase7SecondaryReset }
            }
        }
    }
    Write-Phase7JsonLines -Path $phase7RolloutPath -Objects @($phase7ValidEvent)
    $script:phase7ValidQuotaResult = $null
    $script:phase7ValidDocument = $null
    $script:phase7ValidSnapshot = $null
    Invoke-Case 'Phase 7 Get-CodexQuota 保存 observation 與 freshness' {
        $script:phase7ValidQuotaResult = Invoke-Phase7QuotaScript -CodexHomePath $phase7CodexHome -SnapshotPath $phase7ValidSnapshotPath
        Assert-True ($script:phase7ValidQuotaResult.exit_code -eq 0 -and (Test-Path -LiteralPath $phase7ValidSnapshotPath -PathType Leaf)) ('quota snapshot 建立失敗：' + $script:phase7ValidQuotaResult.output)
        $script:phase7ValidDocument = Get-Content -LiteralPath $phase7ValidSnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:phase7ValidSnapshot = Read-QuotaSnapshot -Path $phase7ValidSnapshotPath
        Assert-True ($script:phase7ValidDocument.schema -eq 'ai-sessions.quota-snapshot.v1' -and $script:phase7ValidDocument.state -eq 'Valid') 'quota snapshot schema 或 state 不符。'
        Assert-True ($script:phase7ValidDocument.observations.primary.used_percent -eq 40 -and $script:phase7ValidDocument.observations.primary.remaining_percent -eq 60 -and $script:phase7ValidDocument.observations.secondary.used_percent -eq 50 -and $script:phase7ValidDocument.observations.secondary.remaining_percent -eq 50) 'last observed 百分比未保存。'
        Assert-True ($script:phase7ValidDocument.observations.primary.freshness -eq 'fresh' -and $script:phase7ValidDocument.observations.secondary.freshness -eq 'fresh' -and -not [string]::IsNullOrWhiteSpace([string]$script:phase7ValidDocument.captured_at_utc)) 'freshness 或 captured time 未保存。'
        Assert-True ($script:phase7ValidDocument.observations.primary.source -match 'Get-CodexQuota\.ps1' -and $script:phase7ValidSnapshot.serviceRejection -eq $null -and (Get-QuotaSnapshotFreshness -Snapshot $script:phase7ValidSnapshot) -eq 'fresh') 'observation source 或 freshness reader 異常。'
    }

    $phase7RejectionEvent = [ordered]@{
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        type = 'error'
        message = 'usage-limit'
        window = 'primary'
    }
    Write-Phase7JsonLines -Path $phase7RolloutPath -Objects @($phase7ValidEvent, $phase7RejectionEvent)
    $script:phase7RejectedQuotaResult = $null
    $script:phase7RejectedDocument = $null
    $script:phase7RejectedSnapshot = $null
    Invoke-Case 'Phase 7 usage-limit 保留 observation 並保存 service rejection' {
        $script:phase7RejectedQuotaResult = Invoke-Phase7QuotaScript -CodexHomePath $phase7CodexHome -SnapshotPath $phase7RejectedSnapshotPath
        Assert-True ($script:phase7RejectedQuotaResult.exit_code -eq 0 -and (Test-Path -LiteralPath $phase7RejectedSnapshotPath -PathType Leaf)) ('service rejection snapshot 建立失敗：' + $script:phase7RejectedQuotaResult.output)
        $script:phase7RejectedDocument = Get-Content -LiteralPath $phase7RejectedSnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:phase7RejectedSnapshot = Read-QuotaSnapshot -Path $phase7RejectedSnapshotPath
        $rejection = $script:phase7RejectedSnapshot.serviceRejection
        Assert-True ($script:phase7RejectedDocument.state -eq 'Valid' -and $null -ne $rejection -and $rejection.status -eq 'quota-rejected' -and $rejection.reason_code -eq 'usage-limit' -and $rejection.retry_allowed -eq $false) 'service_rejection contract 未保存。'
        Assert-True ($script:phase7RejectedDocument.primary.used_percent -eq 40 -and $script:phase7RejectedDocument.primary.remaining_percent -eq 60 -and $script:phase7RejectedDocument.observations.primary.used_percent -eq 40 -and $script:phase7RejectedDocument.observations.primary.remaining_percent -eq 60) 'usage-limit 覆寫 last observed quota。'
        Assert-True ($script:phase7RejectedDocument.observations.primary.observed_at_utc -eq $script:phase7ValidDocument.observations.primary.observed_at_utc -and $script:phase7RejectedDocument.observations.primary.source -eq $script:phase7ValidDocument.observations.primary.source -and $rejection.raw_evidence_path -eq $phase7RolloutPath -and $rejection.raw_evidence_sha256 -match '^[a-f0-9]{64}$') 'observation 時間、來源或 raw evidence hash 未保留。'
    }

    function Invoke-Phase7ServiceRejectionRegression {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$CaseName,
            [Parameter(Mandatory)][object]$AdditionalEvent,
            [Parameter(Mandatory)][bool]$ExpectRejection,
            [string]$ExpectedReasonCode,
            [string]$ExpectedWindow
        )

        $root = Join-Path $phase7Root ('a3-' + $CaseName)
        $caseCodexHome = Join-Path $root 'codex-home'
        $sessions = Join-Path $caseCodexHome 'sessions'
        $snapshotPath = Join-Path $root 'snapshot.json'
        $rolloutPath = Join-Path $sessions ('rollout-' + $CaseName + '.jsonl')
        New-Item -ItemType Directory -Path $sessions -Force | Out-Null
        Write-Phase7JsonLines -Path $rolloutPath -Objects @($phase7ValidEvent, $AdditionalEvent)
        $result = Invoke-Phase7QuotaScript -CodexHomePath $caseCodexHome -SnapshotPath $snapshotPath
        Assert-True ($result.exit_code -eq 0 -and (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) ($CaseName + ' quota snapshot 建立失敗：' + $result.output)
        $document = Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($ExpectRejection) {
            Assert-True ($null -ne $document.service_rejection -and $document.service_rejection.reason_code -eq $ExpectedReasonCode -and $document.service_rejection.window -eq $ExpectedWindow) ($CaseName + ' 未保存預期 service rejection。')
        }
        else {
            Assert-True ($null -eq $document.service_rejection) ($CaseName + ' 將非錯誤紀錄誤判為 service rejection。')
        }
        return $document
    }

    Invoke-Case 'Phase 7 A3(g) compacted 文字不產生 service rejection' {
        $compactedEvent = [ordered]@{
            timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            type = 'compacted'
            content = 'usage-limit 事件記為 service_rejection；secondary'
        }
        $null = Invoke-Phase7ServiceRejectionRegression -CaseName 'g-compacted' -AdditionalEvent $compactedEvent -ExpectRejection $false
    }

    Invoke-Case 'Phase 7 A3(h) response_item 使用者訊息不產生 service rejection' {
        $responseItemEvent = [ordered]@{
            timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            type = 'response_item'
            payload = [ordered]@{
                type = 'message'
                role = 'user'
                content = '429 rate limit'
            }
        }
        $null = Invoke-Phase7ServiceRejectionRegression -CaseName 'h-response-item' -AdditionalEvent $responseItemEvent -ExpectRejection $false
    }

    Invoke-Case 'Phase 7 A3(i) structured error usage-limit 仍產生 rejection' {
        $errorEvent = [ordered]@{
            timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            type = 'error'
            message = 'usage-limit'
            window = 'primary'
        }
        $null = Invoke-Phase7ServiceRejectionRegression -CaseName 'i-error' -AdditionalEvent $errorEvent -ExpectRejection $true -ExpectedReasonCode 'usage-limit' -ExpectedWindow 'primary'
    }

    Invoke-Case 'Phase 7 A3(j) token_count reached type 取 secondary window' {
        $tokenCountEvent = [ordered]@{
            timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            type = 'token_count'
            payload = [ordered]@{
                rate_limits = [ordered]@{
                    rate_limit_reached_type = 'secondary'
                    secondary = [ordered]@{ resets_at = $phase7SecondaryReset }
                }
            }
        }
        $null = Invoke-Phase7ServiceRejectionRegression -CaseName 'j-token-count' -AdditionalEvent $tokenCountEvent -ExpectRejection $true -ExpectedReasonCode 'rate-limit' -ExpectedWindow 'secondary'
    }

    Invoke-Case 'Phase 7 F-007 structured error code separator 與 reason code' {
        foreach ($case in @(
                [pscustomobject]@{ name = 'k-usage-underscore'; code = 'usage_limit_reached'; reason = 'usage-limit' },
                [pscustomobject]@{ name = 'l-rate-hyphen'; code = 'rate-limit-exceeded'; reason = 'rate-limit' },
                [pscustomobject]@{ name = 'm-quota-hyphen'; code = 'quota-exceeded'; reason = 'quota-exceeded' },
                [pscustomobject]@{ name = 'n-too-many-underscore'; code = 'too_many_requests'; reason = 'too-many-requests' },
                [pscustomobject]@{ name = 'o-http-429'; code = '429'; reason = 'too-many-requests' }
            )) {
            $structuredCodeEvent = [ordered]@{
                timestamp = [DateTimeOffset]::UtcNow.ToString('o')
                type = 'turn.failed'
                error = [ordered]@{
                    code = $case.code
                    message = 'structured error fixture'
                }
                window = 'primary'
            }
            $document = Invoke-Phase7ServiceRejectionRegression -CaseName $case.name -AdditionalEvent $structuredCodeEvent -ExpectRejection $true -ExpectedReasonCode $case.reason -ExpectedWindow 'primary'
            Assert-True ($document.service_rejection.reason_code -eq $case.reason) ('F-007 ' + $case.code + ' reason code 不符。')
        }
    }

    $phase7StaleRoot = Join-Path $phase7Root 'stale'
    $phase7StaleHome = Join-Path $phase7StaleRoot 'codex-home'
    $phase7StaleSessionsPath = Join-Path $phase7StaleHome 'sessions'
    New-Item -ItemType Directory -Path $phase7StaleSessionsPath -Force | Out-Null
    $phase7StaleEvent = [ordered]@{
        timestamp = [DateTimeOffset]::UtcNow.AddMinutes(-45).ToString('o')
        payload = [ordered]@{
            rate_limits = [ordered]@{
                primary = [ordered]@{ used_percent = 70; window_minutes = 120; resets_at = $phase7PrimaryReset }
                secondary = [ordered]@{ used_percent = 60; window_minutes = 10080; resets_at = $phase7SecondaryReset }
            }
        }
    }
    $phase7StaleRolloutPath = Join-Path $phase7StaleSessionsPath 'rollout-phase7-stale.jsonl'
    $phase7StaleSnapshotPath = Join-Path $phase7StaleRoot 'stale-snapshot.json'
    Write-Phase7JsonLines -Path $phase7StaleRolloutPath -Objects @($phase7StaleEvent)
    $script:phase7StaleSnapshot = $null
    Invoke-Case 'Phase 7 stale observation 不宣稱 realtime' {
        $staleResult = Invoke-Phase7QuotaScript -CodexHomePath $phase7StaleHome -SnapshotPath $phase7StaleSnapshotPath
        Assert-True ($staleResult.exit_code -eq 0 -and (Test-Path -LiteralPath $phase7StaleSnapshotPath -PathType Leaf)) ('stale snapshot 建立失敗：' + $staleResult.output)
        $script:phase7StaleSnapshot = Read-QuotaSnapshot -Path $phase7StaleSnapshotPath
        Assert-True ((Get-QuotaSnapshotFreshness -Snapshot $script:phase7StaleSnapshot) -eq 'stale' -and $script:phase7StaleSnapshot.primary.remaining_percent -eq 30 -and $script:phase7StaleSnapshot.observations.primary.freshness -eq 'stale') 'stale observation 被誤標 fresh 或百分比遺失。'
    }

    $phase7UnknownSnapshotPath = Join-Path $phase7Root 'unknown-snapshot.json'
    $phase7UnknownDocument = [ordered]@{
        schema = 'ai-sessions.quota-snapshot.v1'
        state = 'Valid'
        captured_at_utc = $phase7Now.ToString('o')
        primary = [ordered]@{ used_percent = 40; remaining_percent = 60; window_minutes = 120; resets_at = $phase7PrimaryReset; source_file = 'legacy-rollout.jsonl' }
        secondary = [ordered]@{ used_percent = 50; remaining_percent = 50; window_minutes = 10080; resets_at = $phase7SecondaryReset; source_file = 'legacy-rollout.jsonl' }
    }
    Write-Utf8NoBom -Path $phase7UnknownSnapshotPath -Content (($phase7UnknownDocument | ConvertTo-Json -Depth 12) + "`n")
    Invoke-Case 'Phase 7 舊 snapshot 缺少 observation 時正規化為 unknown' {
        $unknownSnapshot = Read-QuotaSnapshot -Path $phase7UnknownSnapshotPath
        Assert-True ((Get-QuotaSnapshotFreshness -Snapshot $unknownSnapshot) -eq 'unknown' -and -not (Test-QuotaSnapshotFresh -Snapshot $unknownSnapshot) -and $unknownSnapshot.primary.remaining_percent -eq 60 -and $unknownSnapshot.observations.primary.remaining_percent -eq 60) '舊 snapshot 未保留 last observed 或被誤判 fresh。'
    }

    $phase7LowSnapshotPath = Join-Path $phase7Root 'low-snapshot.json'
    $phase7LowObservedAt = [DateTimeOffset]::UtcNow.ToString('o')
    $phase7LowDocument = [ordered]@{
        schema = 'ai-sessions.quota-snapshot.v1'
        state = 'Valid'
        captured_at_utc = $phase7LowObservedAt
        primary = [ordered]@{ used_percent = 80; remaining_percent = 20; window_minutes = 120; resets_at = $phase7PrimaryReset; source_file = 'phase7-low.jsonl' }
        secondary = [ordered]@{ used_percent = 90; remaining_percent = 10; window_minutes = 10080; resets_at = $phase7SecondaryReset; source_file = 'phase7-low.jsonl' }
        observations = [ordered]@{
            primary = [ordered]@{ used_percent = 80; remaining_percent = 20; observed_at_utc = $phase7LowObservedAt; source = 'phase7-low.jsonl'; freshness = 'fresh'; window = 'primary'; resets_at = $phase7PrimaryReset }
            secondary = [ordered]@{ used_percent = 90; remaining_percent = 10; observed_at_utc = $phase7LowObservedAt; source = 'phase7-low.jsonl'; freshness = 'fresh'; window = 'secondary'; resets_at = $phase7SecondaryReset }
        }
        service_rejection = $null
    }
    Write-Utf8NoBom -Path $phase7LowSnapshotPath -Content (($phase7LowDocument | ConvertTo-Json -Depth 12) + "`n")
    $script:phase7LowSnapshot = Read-QuotaSnapshot -Path $phase7LowSnapshotPath
    Invoke-Case 'Phase 7 default 低額度無 calibration 採 bounded single-unit' {
        $plan = New-ScopePlan -DispatchSlug 'phase7-default-low' -DispatchKind 'workflow' -TaskType 'script-change' -RequestedProfile 'default' -SessionMode 'cold-start' -BeforeSnapshot $script:phase7LowSnapshot -CalibrationPath (Join-Path $phase7Root 'missing-calibration.jsonl') -Units @('unit-1', 'unit-2') -UnitKind 'workflow-phase' -Model $null -ModelEvidence $null -ReasoningEffortEvidence $null
        Assert-True ($plan.decision -eq 'scoped' -and @($plan.selected_units).Count -eq 1 -and $plan.selected_units[0] -eq 'unit-1' -and @($plan.deferred_units).Count -eq 1 -and $plan.estimate_source -eq 'bounded-single-unit' -and $plan.primary_reserve_percent -eq 0 -and $plan.primary_budget_percent -eq 20 -and $plan.stop_after_selected_units -eq $true -and $plan.decision -ne 'user-decision-required') 'default 低額度 ScopePlan 未固定第一個 declared unit 或未套用 reserve 0。'
    }

    $phase7ModelEvidence = New-ConfirmedDispatchEvidence -Value 'fixture-model' -Source 'phase7-profile' -Field 'model'
    $phase7EffortEvidence = New-ConfirmedDispatchEvidence -Value 'high' -Source 'phase7-profile' -Field 'model_reasoning_effort'
    $phase7ModelGroup = [ordered]@{
        requested = New-RequestedDispatchEvidence -Value $null -Field 'Model'
        resolved = $phase7ModelEvidence
        runtime_verifiable = New-ConfirmedDispatchEvidence -Value 'fixture-model' -Source 'phase7-rollout' -Field 'payload.model'
    }
    $phase7EffortGroup = [ordered]@{
        requested = New-RequestedDispatchEvidence -Value $null -Field 'ReasoningEffort'
        resolved = $phase7EffortEvidence
        runtime_verifiable = New-ConfirmedDispatchEvidence -Value 'high' -Source 'phase7-rollout' -Field 'payload.effort'
    }
    $phase7CalibrationPath = Join-Path $phase7Root 'advisor-calibration.jsonl'
    $phase7CalibrationRecords = @(
        [ordered]@{ calibration_eligible = $true; profile = 'advisor'; session_mode = 'cold-start'; task_type = 'advisor-consult'; group = [ordered]@{ model = 'fixture-model'; reasoning_effort = 'high' }; model_evidence = $phase7ModelGroup; reasoning_effort_evidence = $phase7EffortGroup; observed_primary_delta_percent = 8 }
        [ordered]@{ calibration_eligible = $true; profile = 'advisor'; session_mode = 'cold-start'; task_type = 'advisor-consult'; group = [ordered]@{ model = 'fixture-model'; reasoning_effort = 'high' }; model_evidence = $phase7ModelGroup; reasoning_effort_evidence = $phase7EffortGroup; observed_primary_delta_percent = 10 }
        [ordered]@{ calibration_eligible = $true; profile = 'advisor'; session_mode = 'cold-start'; task_type = 'advisor-consult'; group = [ordered]@{ model = 'fixture-model'; reasoning_effort = 'high' }; model_evidence = $phase7ModelGroup; reasoning_effort_evidence = $phase7EffortGroup; observed_primary_delta_percent = 12 }
        [ordered]@{ calibration_eligible = $true; profile = 'advisor'; session_mode = 'cold-start'; task_type = 'advisor-consult'; group = [ordered]@{ model = 'fixture-model'; reasoning_effort = 'high' }; model_evidence = $phase7ModelGroup; reasoning_effort_evidence = $phase7EffortGroup; observed_primary_delta_percent = 14 }
        [ordered]@{ calibration_eligible = $true; profile = 'advisor'; session_mode = 'cold-start'; task_type = 'advisor-consult'; group = [ordered]@{ model = 'fixture-model'; reasoning_effort = 'high' }; model_evidence = $phase7ModelGroup; reasoning_effort_evidence = $phase7EffortGroup; observed_primary_delta_percent = 16 }
    )
    Write-Phase7JsonLines -Path $phase7CalibrationPath -Objects $phase7CalibrationRecords
    $script:phase7AdvisorPlan = $null
    Invoke-Case 'Phase 7 advisor calibration P75、reserve 與 hard limit' {
        $script:phase7AdvisorPlan = New-ScopePlan -DispatchSlug 'phase7-advisor' -DispatchKind 'resource' -TaskType 'advisor-consult' -RequestedProfile 'advisor' -SessionMode 'cold-start' -BeforeSnapshot $script:phase7ValidSnapshot -CalibrationPath $phase7CalibrationPath -Units @('question-001', 'question-002') -UnitKind 'advisor-evidence-question' -Model 'fixture-model' -ModelEvidence $phase7ModelEvidence -ReasoningEffortEvidence $phase7EffortEvidence
        $script:phase7AdvisorPlan.scope_plan_fingerprint = Get-ScopePlanFingerprint -ScopePlan $script:phase7AdvisorPlan
        Assert-True ($script:phase7AdvisorPlan.estimate_source -eq 'p75' -and $script:phase7AdvisorPlan.estimate_percent -eq 14 -and $script:phase7AdvisorPlan.primary_reserve_percent -ge 30 -and $script:phase7AdvisorPlan.advisor_hard_limit_percent -eq 17.5 -and $script:phase7AdvisorPlan.advisor_unit_estimate_percent -eq 7) 'advisor calibration P75、reserve 或 unit estimate 異常。'
    }

    $phase7D5CalibrationPath = Join-Path $phase7Root 'quota-calibration.jsonl'
    $phase7D5NoMatchCalibrationPath = Join-Path $phase7Root 'quota-calibration-no-match.jsonl'
    $phase7D5OtherModelEvidence = New-ConfirmedDispatchEvidence -Value 'other-model' -Source 'phase7-d5-profile' -Field 'model'
    $phase7D5OtherModelGroup = [ordered]@{
        requested = New-RequestedDispatchEvidence -Value $null -Field 'Model'
        resolved = $phase7D5OtherModelEvidence
        runtime_verifiable = New-ConfirmedDispatchEvidence -Value 'other-model' -Source 'phase7-d5-rollout' -Field 'payload.model'
    }
    $phase7D5OtherModelRecord = [ordered]@{
        calibration_eligible = $true
        profile = 'advisor'
        session_mode = 'cold-start'
        task_type = 'advisor-consult'
        group = [ordered]@{ model = 'other-model'; reasoning_effort = 'high' }
        model_evidence = $phase7D5OtherModelGroup
        reasoning_effort_evidence = $phase7EffortGroup
        observed_primary_delta_percent = 18
    }
    Write-Phase7JsonLines -Path $phase7D5CalibrationPath -Objects @($phase7D5OtherModelRecord)
    Write-Phase7JsonLines -Path $phase7D5NoMatchCalibrationPath -Objects @($phase7D5OtherModelRecord)

    $phase7D5HighSnapshotPath = Join-Path $phase7Root 'd5-primary-68-snapshot.json'
    $phase7D5HighObservedAt = [DateTimeOffset]::UtcNow.ToString('o')
    $phase7D5HighDocument = [ordered]@{
        schema = 'ai-sessions.quota-snapshot.v1'
        state = 'Valid'
        captured_at_utc = $phase7D5HighObservedAt
        primary = [ordered]@{ used_percent = 32; remaining_percent = 68; window_minutes = 120; resets_at = $phase7PrimaryReset; source_file = 'quota-calibration.jsonl' }
        secondary = [ordered]@{ used_percent = 50; remaining_percent = 50; window_minutes = 10080; resets_at = $phase7SecondaryReset; source_file = 'quota-calibration.jsonl' }
        observations = [ordered]@{
            primary = [ordered]@{ used_percent = 32; remaining_percent = 68; observed_at_utc = $phase7D5HighObservedAt; source = 'quota-calibration.jsonl'; freshness = 'fresh'; window = 'primary'; resets_at = $phase7PrimaryReset }
            secondary = [ordered]@{ used_percent = 50; remaining_percent = 50; observed_at_utc = $phase7D5HighObservedAt; source = 'quota-calibration.jsonl'; freshness = 'fresh'; window = 'secondary'; resets_at = $phase7SecondaryReset }
        }
        service_rejection = $null
    }
    Write-Utf8NoBom -Path $phase7D5HighSnapshotPath -Content (($phase7D5HighDocument | ConvertTo-Json -Depth 12) + "`n")
    $phase7D5HighSnapshot = Read-QuotaSnapshot -Path $phase7D5HighSnapshotPath

    $phase7D5LowSnapshotPath = Join-Path $phase7Root 'd5-primary-40-snapshot.json'
    $phase7D5LowObservedAt = [DateTimeOffset]::UtcNow.ToString('o')
    $phase7D5LowDocument = [ordered]@{
        schema = 'ai-sessions.quota-snapshot.v1'
        state = 'Valid'
        captured_at_utc = $phase7D5LowObservedAt
        primary = [ordered]@{ used_percent = 60; remaining_percent = 40; window_minutes = 120; resets_at = $phase7PrimaryReset; source_file = 'quota-calibration.jsonl' }
        secondary = [ordered]@{ used_percent = 50; remaining_percent = 50; window_minutes = 10080; resets_at = $phase7SecondaryReset; source_file = 'quota-calibration.jsonl' }
        observations = [ordered]@{
            primary = [ordered]@{ used_percent = 60; remaining_percent = 40; observed_at_utc = $phase7D5LowObservedAt; source = 'quota-calibration.jsonl'; freshness = 'fresh'; window = 'primary'; resets_at = $phase7PrimaryReset }
            secondary = [ordered]@{ used_percent = 50; remaining_percent = 50; observed_at_utc = $phase7D5LowObservedAt; source = 'quota-calibration.jsonl'; freshness = 'fresh'; window = 'secondary'; resets_at = $phase7SecondaryReset }
        }
        service_rejection = $null
    }
    Write-Utf8NoBom -Path $phase7D5LowSnapshotPath -Content (($phase7D5LowDocument | ConvertTo-Json -Depth 12) + "`n")
    $phase7D5LowSnapshot = Read-QuotaSnapshot -Path $phase7D5LowSnapshotPath

    Invoke-Case 'Phase 7 D5 fresh 無同分組樣本使用 conservative-default' {
        $plan = New-ScopePlan -DispatchSlug 'phase7-d5-primary-68' -DispatchKind 'resource' -TaskType 'advisor-consult' -RequestedProfile 'advisor' -SessionMode 'cold-start' -BeforeSnapshot $phase7D5HighSnapshot -CalibrationPath $phase7D5CalibrationPath -Units @('question-001') -UnitKind 'advisor-evidence-question' -Model 'fixture-model' -ModelEvidence $phase7ModelEvidence -ReasoningEffortEvidence $phase7EffortEvidence
        Assert-True ($plan.quota_freshness -eq 'fresh' -and $plan.quota_state -eq 'Valid' -and $plan.decision -eq 'full' -and @($plan.selected_units).Count -eq 1 -and $plan.estimate_source -eq 'conservative-default' -and $plan.estimate_percent -eq 24 -and $plan.primary_budget_percent -eq 30 -and $plan.advisor_hard_limit_percent -eq 30) 'D5 primary 68% 未使用 advisor conservative-default 或 budget／hard limit 異常。'
    }

    Invoke-Case 'Phase 7 D5 primary 40% advisor scope plan 保留授權前條件' {
        $plan = New-ScopePlan -DispatchSlug 'phase7-d5-primary-40' -DispatchKind 'resource' -TaskType 'advisor-consult' -RequestedProfile 'advisor' -SessionMode 'cold-start' -BeforeSnapshot $phase7D5LowSnapshot -CalibrationPath $phase7D5CalibrationPath -Units @('question-001') -UnitKind 'advisor-evidence-question' -Model 'fixture-model' -ModelEvidence $phase7ModelEvidence -ReasoningEffortEvidence $phase7EffortEvidence
        Assert-True ($plan.decision -eq 'blocked-insufficient-budget' -and $plan.primary_budget_percent -eq 10 -and $plan.estimate_source -eq 'conservative-default' -and $plan.estimate_percent -eq 24 -and $plan.advisor_hard_limit_percent -eq 30 -and @($plan.selected_units).Count -eq 0) 'D5 primary 40% advisor ScopePlan 未保留未授權時的阻擋結果。'
    }

    Write-Phase7JsonLines -Path $phase7D5CalibrationPath -Objects $phase7CalibrationRecords
    Invoke-Case 'Phase 7 D5 同分組 eligible 樣本優先使用 P75' {
        $plan = New-ScopePlan -DispatchSlug 'phase7-d5-p75' -DispatchKind 'resource' -TaskType 'advisor-consult' -RequestedProfile 'advisor' -SessionMode 'cold-start' -BeforeSnapshot $phase7D5HighSnapshot -CalibrationPath $phase7D5CalibrationPath -Units @('question-001') -UnitKind 'advisor-evidence-question' -Model 'fixture-model' -ModelEvidence $phase7ModelEvidence -ReasoningEffortEvidence $phase7EffortEvidence
        Assert-True ($plan.decision -eq 'full' -and $plan.estimate_source -eq 'p75' -and $plan.estimate_percent -eq 14 -and $plan.estimate_percent -ne 24 -and $plan.primary_budget_percent -eq 17.5) 'D5 同分組 eligible 樣本未優先使用 P75。'
    }

    $phase7ScopePlanDefinition = ($functions | Where-Object { $_.Name -eq 'New-ScopePlan' } | Select-Object -First 1).Extent.Text
    Invoke-Case 'Phase 7 D5 conservative estimate null 仍為 blocked-no-estimate' {
        $unknownEstimate = Get-ConservativeEstimate -TaskType 'unknown-task-type'
        $isolatedPlan = & {
            param($definition, $snapshot, $calibrationPath, $modelEvidence, $effortEvidence)
            function Get-ConservativeEstimate {
                param([string]$TaskType)
                return $null
            }
            . ([scriptblock]::Create($definition))
            return (New-ScopePlan -DispatchSlug 'phase7-d5-unknown-estimate' -DispatchKind 'resource' -TaskType 'advisor-consult' -RequestedProfile 'advisor' -SessionMode 'cold-start' -BeforeSnapshot $snapshot -CalibrationPath $calibrationPath -Units @('question-001') -UnitKind 'advisor-evidence-question' -Model 'fixture-model' -ModelEvidence $modelEvidence -ReasoningEffortEvidence $effortEvidence)
        } $phase7ScopePlanDefinition $phase7D5HighSnapshot $phase7D5NoMatchCalibrationPath $phase7ModelEvidence $phase7EffortEvidence
        Assert-True ($null -eq $unknownEstimate -and $isolatedPlan.decision -eq 'blocked-no-estimate' -and @($isolatedPlan.selected_units).Count -eq 0) '未知 task type 或 conservative estimate null 未維持 blocked-no-estimate。'
    }

    $phase7UnavailableSnapshotPath = Join-Path $phase7Root 'unavailable-snapshot.json'
    $phase7UnavailableDocument = [ordered]@{
        schema = 'ai-sessions.quota-snapshot.v1'
        state = 'SnapshotUnavailable'
        captured_at_utc = $null
        primary = $null
        secondary = $null
        observations = $null
        service_rejection = $null
        error = 'no observation fixture'
    }
    Write-Utf8NoBom -Path $phase7UnavailableSnapshotPath -Content (($phase7UnavailableDocument | ConvertTo-Json -Depth 12) + "`n")
    $script:phase7UnavailableSnapshot = Read-QuotaSnapshot -Path $phase7UnavailableSnapshotPath
    Invoke-Case 'Phase 7 無 observation 輸出 SnapshotUnavailable' {
        $defaultPlan = New-ScopePlan -DispatchSlug 'phase7-unavailable-default' -DispatchKind 'workflow' -TaskType 'script-change' -RequestedProfile 'default' -SessionMode 'cold-start' -BeforeSnapshot $script:phase7UnavailableSnapshot -CalibrationPath $null -Units @('unit-1', 'unit-2') -UnitKind 'workflow-phase' -Model $null -ModelEvidence $null -ReasoningEffortEvidence $null
        $advisorPlan = New-ScopePlan -DispatchSlug 'phase7-unavailable-advisor' -DispatchKind 'resource' -TaskType 'advisor-consult' -RequestedProfile 'advisor' -SessionMode 'cold-start' -BeforeSnapshot $script:phase7UnavailableSnapshot -CalibrationPath $null -Units @('question-001') -UnitKind 'advisor-evidence-question' -Model $null -ModelEvidence $null -ReasoningEffortEvidence $null
        Assert-True ($defaultPlan.quota_state -eq 'SnapshotUnavailable' -and $defaultPlan.decision -eq 'blocked-no-fresh-quota' -and $advisorPlan.decision -eq 'blocked-no-fresh-quota' -and @($defaultPlan.selected_units).Count -eq 0 -and @($advisorPlan.selected_units).Count -eq 0) '無 observation 未安全阻擋 ScopePlan。'
    }

    Invoke-Case 'Phase 7 stale advisor 要求 fresh quota 並保留 reserve' {
        $staleAdvisorPlan = New-ScopePlan -DispatchSlug 'phase7-stale-advisor' -DispatchKind 'resource' -TaskType 'advisor-consult' -RequestedProfile 'advisor' -SessionMode 'cold-start' -BeforeSnapshot $script:phase7StaleSnapshot -CalibrationPath $null -Units @('question-001') -UnitKind 'advisor-evidence-question' -Model $null -ModelEvidence $null -ReasoningEffortEvidence $null
        Assert-True ($staleAdvisorPlan.quota_freshness -eq 'stale' -and $staleAdvisorPlan.decision -eq 'blocked-no-fresh-quota' -and $staleAdvisorPlan.primary_reserve_percent -ge 30 -and $staleAdvisorPlan.estimate_source -eq 'blocked-no-fresh-quota') 'stale advisor 未阻擋或未保留 reserve gate。'
    }

    Invoke-Case 'Phase 7 service rejection ScopePlan 保留觀測且禁止 retry' {
        $rejectedPlan = New-ScopePlan -DispatchSlug 'phase7-rejected-plan' -DispatchKind 'workflow' -TaskType 'script-change' -RequestedProfile 'default' -SessionMode 'cold-start' -BeforeSnapshot $script:phase7RejectedSnapshot -CalibrationPath $null -Units @('unit-1') -UnitKind 'workflow-phase' -Model $null -ModelEvidence $null -ReasoningEffortEvidence $null
        Assert-True ($rejectedPlan.quota_state -eq 'ServiceRejected' -and $rejectedPlan.decision -eq 'blocked-no-fresh-quota' -and $rejectedPlan.retry_allowed -eq $false -and $rejectedPlan.primary_remaining_percent -eq 60 -and $rejectedPlan.service_rejection.reason_code -eq 'usage-limit') 'service rejection ScopePlan 狀態或 retry gate 異常。'
    }

    $phase7SupersededRoot = Join-Path $phase7Root 'superseded'
    $phase7SupersededHome = Join-Path $phase7SupersededRoot 'codex-home'
    $phase7SupersededSessionsPath = Join-Path $phase7SupersededHome 'sessions'
    New-Item -ItemType Directory -Path $phase7SupersededSessionsPath -Force | Out-Null
    $phase7SupersededRolloutPath = Join-Path $phase7SupersededSessionsPath 'rollout-phase7-superseded.jsonl'
    $phase7SupersededSnapshotPath = Join-Path $phase7SupersededRoot 'superseded-snapshot.json'
    $phase7SupersededRejectionAt = [DateTimeOffset]::UtcNow.AddMinutes(-2)
    $phase7SupersededObservationAt = [DateTimeOffset]::UtcNow.AddMinutes(-1)
    $phase7SupersededRejectionEvent = [ordered]@{
        timestamp = $phase7SupersededRejectionAt.ToString('o')
        type = 'error'
        message = 'usage-limit'
        window = 'primary'
    }
    $phase7SupersededFreshEvent = [ordered]@{
        timestamp = $phase7SupersededObservationAt.ToString('o')
        payload = [ordered]@{
            rate_limits = [ordered]@{
                primary = [ordered]@{ used_percent = 41; window_minutes = 120; resets_at = $phase7PrimaryReset }
                secondary = [ordered]@{ used_percent = 51; window_minutes = 10080; resets_at = $phase7SecondaryReset }
            }
        }
    }
    Write-Phase7JsonLines -Path $phase7SupersededRolloutPath -Objects @($phase7SupersededRejectionEvent, $phase7SupersededFreshEvent)
    $script:phase7SupersededSnapshot = $null
    Invoke-Case 'Phase 7 rejection 後較晚 fresh observation 取代 service rejection' {
        $supersededResult = Invoke-Phase7QuotaScript -CodexHomePath $phase7SupersededHome -SnapshotPath $phase7SupersededSnapshotPath
        Assert-True ($supersededResult.exit_code -eq 0 -and (Test-Path -LiteralPath $phase7SupersededSnapshotPath -PathType Leaf)) ('fresh observation 取代 rejection 時 snapshot 建立失敗：' + $supersededResult.output)
        $supersededDocument = Get-Content -LiteralPath $phase7SupersededSnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:phase7SupersededSnapshot = Read-QuotaSnapshot -Path $phase7SupersededSnapshotPath
        $supersededEvidence = Get-QuotaSnapshotServiceRejectionEvidence -Snapshot $script:phase7SupersededSnapshot
        $supersededPlan = New-ScopePlan -DispatchSlug 'phase7-superseded-plan' -DispatchKind 'workflow' -TaskType 'script-change' -RequestedProfile 'default' -SessionMode 'cold-start' -BeforeSnapshot $script:phase7SupersededSnapshot -CalibrationPath $null -Units @('unit-1') -UnitKind 'workflow-phase' -Model $null -ModelEvidence $null -ReasoningEffortEvidence $null
        Assert-True ($supersededDocument.state -eq 'Valid' -and $null -eq $supersededDocument.service_rejection -and $null -eq $script:phase7SupersededSnapshot.serviceRejection -and $supersededEvidence.superseded -eq $true) 'fresh observation 後仍保留 active service rejection。'
        Assert-True ($supersededEvidence.reason_code -eq 'usage-limit' -and $supersededEvidence.raw_evidence_path -eq $phase7SupersededRolloutPath -and $supersededEvidence.raw_evidence_sha256 -match '^[a-f0-9]{64}$' -and $supersededEvidence.superseded_by_observation.source_path -eq $phase7SupersededRolloutPath) '原始 rejection audit evidence 未獨立保存。'
        Assert-True ($supersededPlan.quota_state -eq 'Valid' -and $supersededPlan.decision -eq 'full' -and $supersededPlan.retry_allowed -eq $null -and $supersededPlan.primary_remaining_percent -eq 59) 'fresh observation 後 ScopePlan 仍阻擋或使用舊額度。'
    }

    $phase7ProbePromptPath = Join-Path $phase7Root 'probe-prompt.md'
    Write-Utf8NoBom -Path $phase7ProbePromptPath -Content 'phase7 quota probe prompt'
    $phase7ProbeVariableNames = @('SourceRoot', 'ExecutionRoot', 'DispatchRoot', 'LineSlug', 'DispatchSlug', 'PromptPath', 'CodexHome', 'InitialQuotaState', 'QuotaBeforePath', 'ProbeAttempt', 'TriggerWindow', 'Profile', 'AdvisorRequestSource', 'SecondaryDaysToReset', 'SecondaryRemainingPercent', 'AddDirectory', 'Search', 'CodexParentOption', 'CodexPath')
    $script:phase7SavedVariables = [ordered]@{}
    foreach ($name in $phase7ProbeVariableNames) {
        $variable = Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue
        $script:phase7SavedVariables[$name] = if ($null -eq $variable) { $null } else { $variable.Value }
    }
    Invoke-Case 'Phase 7 explicit service rejection 不自動啟動或 retry' {
        try {
            $script:SourceRoot = $phase7Root
            $script:ExecutionRoot = $phase7Root
            $script:DispatchRoot = $phase7Root
            $script:LineSlug = 'line-a'
            $script:DispatchSlug = 'phase7-service-rejection'
            $script:PromptPath = $phase7ProbePromptPath
            $script:CodexHome = $phase7CodexHome
            $script:InitialQuotaState = 'ServiceRejected'
            $script:QuotaBeforePath = $phase7RejectedSnapshotPath
            $script:ProbeAttempt = 1
            $script:TriggerWindow = 'primary'
            $script:Profile = 'default'
            $script:AdvisorRequestSource = $null
            $script:SecondaryDaysToReset = $null
            $script:SecondaryRemainingPercent = $null
            $script:AddDirectory = $null
            $script:Search = $false
            $script:CodexParentOption = $null
            $script:CodexPath = $null
            $beforeStartCalls = $script:startCalls
            $probeResult = Invoke-QuotaProbe
            $recoveryPath = $probeResult.recoveryRecordPath
            $recovery = Get-Content -LiteralPath $recoveryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-True (-not $probeResult.success -and -not $probeResult.processStarted -and -not $probeResult.retryRequired -and $probeResult.service_rejection.retry_allowed -eq $false -and $recovery.retryResult.attempted -eq $false -and $recovery.retryResult.retry_allowed -eq $false -and $recovery.finalStatus -eq 'service-rejected-no-retry' -and $script:startCalls -eq $beforeStartCalls) 'explicit service rejection 仍啟動 process 或 retry。'
        }
        finally {
            foreach ($name in $phase7ProbeVariableNames) {
                Set-Variable -Scope Script -Name $name -Value $script:phase7SavedVariables[$name]
            }
        }
    }

    $phase7CalibrationAfterPath = Join-Path $phase7Root 'calibration-after.json'
    [IO.File]::Copy($phase7ValidSnapshotPath, $phase7CalibrationAfterPath, $true)
    $phase7MismatchedPlan = $script:phase7AdvisorPlan | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $phase7MismatchedPlan.scope_plan_fingerprint = '0000000000000000000000000000000000000000000000000000000000000000'
    $phase7ExecutionResult = [pscustomobject]@{ completed = $true; processExitCode = 0; success = $true; outputValid = $true }
    $phase7Usage = [pscustomobject]@{ input_tokens = 1; output_tokens = 1 }
    $phase7InterruptionStatus = [ordered]@{ applied = $true; sessionMode = 'cold-start' }
    Invoke-Case 'Phase 7 ScopePlan fingerprint 改變時 calibration ineligible' {
        $calibrationResult = Add-CalibrationObservation -SourceRoot $phase7Root -Path (Join-Path $phase7Root 'fingerprint-mismatch.jsonl') -LineSlug 'line-a' -DispatchSlug 'phase7-fingerprint-mismatch' -Profile 'advisor' -Model 'fixture-model' -ReasoningEffort 'high' -ModelEvidence $phase7ModelEvidence -ReasoningEffortEvidence $phase7EffortEvidence -TaskType 'advisor-consult' -SessionMode 'cold-start' -Usage $phase7Usage -ExecutionResult $phase7ExecutionResult -QuotaBeforePath $phase7ValidSnapshotPath -QuotaAfterPath $phase7CalibrationAfterPath -ScopePlan $phase7MismatchedPlan -InterruptionStatus $phase7InterruptionStatus -BudgetMonitor @()
        $record = @(Get-CalibrationRecords -Path (Join-Path $phase7Root 'fingerprint-mismatch.jsonl'))[0]
        Assert-True (-not $calibrationResult.calibrationEligible -and -not $record.calibration_checks.scope_plan_fingerprint_match) 'ScopePlan fingerprint mismatch 未標記 calibration ineligible。'
    }

    Invoke-Case 'Phase 7 before／after 同一路徑時 calibration ineligible' {
        $calibrationResult = Add-CalibrationObservation -SourceRoot $phase7Root -Path (Join-Path $phase7Root 'same-path.jsonl') -LineSlug 'line-a' -DispatchSlug 'phase7-same-snapshot-path' -Profile 'advisor' -Model 'fixture-model' -ReasoningEffort 'high' -ModelEvidence $phase7ModelEvidence -ReasoningEffortEvidence $phase7EffortEvidence -TaskType 'advisor-consult' -SessionMode 'cold-start' -Usage $phase7Usage -ExecutionResult $phase7ExecutionResult -QuotaBeforePath $phase7ValidSnapshotPath -QuotaAfterPath $phase7ValidSnapshotPath -ScopePlan $script:phase7AdvisorPlan -InterruptionStatus $phase7InterruptionStatus -BudgetMonitor @()
        $record = @(Get-CalibrationRecords -Path (Join-Path $phase7Root 'same-path.jsonl'))[0]
        Assert-True (-not $calibrationResult.calibrationEligible -and -not $record.calibration_checks.snapshot_paths_stable) 'before／after 相同來源未標記 calibration ineligible。'
    }
}

if ($Phase -ge 8) {
        foreach ($functionName in @(
            'Get-DispatchUnitList',
            'Get-AdvisorActivationDecision',
            'Get-AdvisorEvidenceQuestionUnits',
            'Test-AdvisorEvidencePack',
            'New-ScopePlan',
            'Test-ContinuationScopePlan',
            'Write-AdvisorConsultReport',
            'Get-DispatchEventEvidence',
            'Convert-EventEvidenceToServiceRejection',
            'Get-DispatchFailureReasonCode',
            'New-DispatchFailureRecord')) {
        $definitionAst = $functions | Where-Object { $_.Name -eq $functionName } | Select-Object -First 1
        if ($null -eq $definitionAst) {
            throw "Phase 8 找不到 production function：$functionName"
        }
        . ([scriptblock]::Create($definitionAst.Extent.Text))
    }

    $phase8ProductionScopePlanDefinition = (Get-Command -Name New-ScopePlan -CommandType Function).ScriptBlock
    function New-ScopePlan {
        param(
            [string]$DispatchSlug,
            [string]$DispatchKind,
            [string]$TaskType,
            [string]$RequestedProfile,
            [string]$SessionMode,
            [psobject]$BeforeSnapshot,
            [string]$CalibrationPath,
            [string[]]$Units,
            [string]$UnitKind,
            [Nullable[double]]$RequestedBudgetPercent,
            [Nullable[double]]$RequestedReservePercent,
            [string]$Model,
            [AllowNull()][object]$ModelEvidence,
            [AllowNull()][object]$ReasoningEffortEvidence,
            [AllowNull()][object]$ActivationDecision
        )

        $script:phase8CapturedActivation = $ActivationDecision
        $result = @(& $script:phase8ProductionScopePlanDefinition @PSBoundParameters)
        $plan = if ($result.Count -eq 1) { $result[0] } else { $result[$result.Count - 1] }
        $script:phase8CapturedScopePlan = $plan
        return ,$plan
    }

    function New-Phase8QuotaSnapshot {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][double]$PrimaryRemainingPercent
        )

        $observedAt = [DateTimeOffset]::UtcNow
        $primaryReset = $observedAt.AddHours(2).ToUnixTimeSeconds()
        $secondaryReset = $observedAt.AddDays(5).ToUnixTimeSeconds()
        $primaryUsed = 100.0 - $PrimaryRemainingPercent
        $document = [ordered]@{
            schema = 'ai-sessions.quota-snapshot.v1'
            state = 'Valid'
            captured_at_utc = $observedAt.ToString('o')
            primary = [ordered]@{ used_percent = $primaryUsed; remaining_percent = $PrimaryRemainingPercent; window_minutes = 120; resets_at = $primaryReset; source_file = 'phase8-start.jsonl' }
            secondary = [ordered]@{ used_percent = 50; remaining_percent = 50; window_minutes = 10080; resets_at = $secondaryReset; source_file = 'phase8-start.jsonl' }
            observations = [ordered]@{
                primary = [ordered]@{ used_percent = $primaryUsed; remaining_percent = $PrimaryRemainingPercent; observed_at_utc = $observedAt.ToString('o'); source = 'phase8-start.jsonl'; freshness = 'fresh'; window = 'primary'; resets_at = $primaryReset }
                secondary = [ordered]@{ used_percent = 50; remaining_percent = 50; observed_at_utc = $observedAt.ToString('o'); source = 'phase8-start.jsonl'; freshness = 'fresh'; window = 'secondary'; resets_at = $secondaryReset }
            }
            service_rejection = $null
        }
        Write-Utf8NoBom -Path $Path -Content (($document | ConvertTo-Json -Depth 12) + "`r`n")
        return $Path
    }

    $phase8Root = Join-Path $fixtureRoot 'phase8-regressions'
    New-Item -ItemType Directory -Path $phase8Root -Force | Out-Null

    function New-Phase8RegressionArtifacts {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$CaseRoot,
            [Parameter(Mandatory)][string]$DispatchSlug
        )

        New-Item -ItemType Directory -Path $CaseRoot -Force | Out-Null
        $quotaSnapshotPath = Join-Path $CaseRoot 'quota-snapshot.json'
        $evidencePackPath = Join-Path $CaseRoot 'evidence-pack.md'
        $finalMessagePath = Join-Path $CaseRoot 'final-message.md'
        $null = New-Phase8QuotaSnapshot -Path $quotaSnapshotPath -PrimaryRemainingPercent 80
        $packLines = @($evidencePackContent -split '\r?\n' | ForEach-Object {
                if ($_ -match '^dispatch-slug:') {
                    'dispatch-slug: ' + $DispatchSlug
                }
                else {
                    $_
                }
            })
        Write-Utf8NoBom -Path $evidencePackPath -Content (($packLines -join [Environment]::NewLine) + [Environment]::NewLine)
        $finalMessage = @(
            '## 中斷保全結論'
            '已確認結論：Phase 1 fixture 已寫入 quota snapshot 與 evidence pack。'
            '證據位置：' + $quotaSnapshotPath + '; ' + $evidencePackPath + '; ' + $finalMessagePath
            '實際覆蓋範圍：Phase 1 Setup profile 檢查回歸。'
            '已完成單位：question-001'
            '## 證據支持'
            'fixture evidence'
            '## 推論'
            'fixture inference'
            '## 未決問題'
            '無'
        ) -join [Environment]::NewLine
        Write-Utf8NoBom -Path $finalMessagePath -Content ($finalMessage + [Environment]::NewLine)
        return [pscustomobject]@{
            quota_snapshot_path = $quotaSnapshotPath
            evidence_pack_path = $evidencePackPath
            final_message_path = $finalMessagePath
        }
    }

    function Invoke-SetupProfileCheck {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$CodexDirectory
        )

        $setupPath = Join-Path $PSScriptRoot 'Setup-AIGlobalConfig.ps1'
        $setupContent = Get-Content -LiteralPath $setupPath -Raw -Encoding UTF8
        $sectionMarker = '$codexConfigPath = Join-Path'
        $sectionStart = $setupContent.IndexOf($sectionMarker, [StringComparison]::Ordinal)
        if ($sectionStart -lt 0) {
            throw '找不到 Setup profile 檢查段。'
        }
        $section = $setupContent.Substring($sectionStart)
        $codexDir = $CodexDirectory
        $codexVersion = $null
        $minimumMaxVersion = [version]'0.147.0'
        $legacyProfileName = 'deep' + '.config.toml'
        $legacyProfilePath = Join-Path $codexDir $legacyProfileName
        $profileConflictDetected = $false
        $hostMessages = New-Object System.Collections.Generic.List[string]
        $warningMessages = New-Object System.Collections.Generic.List[string]

        function Write-Host {
            param(
                [AllowNull()][object]$Object,
                [ConsoleColor]$ForegroundColor,
                [switch]$NoNewline
            )
            [void]$hostMessages.Add([string]$Object)
        }

        function Write-Warning {
            param(
                [Parameter(Position = 0)][AllowEmptyString()][string]$Message
            )
            [void]$warningMessages.Add($Message)
        }

        $resultMarker = [Environment]::NewLine +
            '$profileCheckResult = [pscustomobject]@{' +
            ' profile_check_result = $true;' +
            ' missing_profiles = @($missingProfiles);' +
            ' profile_conflict_detected = $profileConflictDetected;' +
            ' legacy_profile_name = $legacyProfileName;' +
            ' legacy_profile_path = $legacyProfilePath;' +
            ' codex_config_path = $codexConfigPath;' +
            ' advisor_profile_path = $advisorProfilePath' +
            '};' +
            '$profileCheckResult'
        $sectionResult = @(& ([scriptblock]::Create($section + $resultMarker)))
        $profileResult = @($sectionResult | Where-Object {
                $null -ne $_ -and $null -ne $_.PSObject.Properties['profile_check_result']
            } | Select-Object -Last 1)
        if ($profileResult.Count -ne 1) {
            throw 'Setup profile 檢查段未回傳結果。'
        }
        return [pscustomobject]@{
            missing_profiles = @($profileResult[0].missing_profiles)
            profile_conflict_detected = [bool]$profileResult[0].profile_conflict_detected
            legacy_profile_name = [string]$profileResult[0].legacy_profile_name
            legacy_profile_path = [string]$profileResult[0].legacy_profile_path
            codex_config_path = [string]$profileResult[0].codex_config_path
            advisor_profile_path = [string]$profileResult[0].advisor_profile_path
            host_messages = @($hostMessages.ToArray())
            warning_messages = @($warningMessages.ToArray())
        }
    }

    function Invoke-Phase8StartPreparation {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$CaseName,
            [Parameter(Mandatory)][double]$PrimaryRemainingPercent,
            [AllowNull()][string]$AdvisorRequestSourceValue,
            [switch]$OmitAdvisorConsultReportPath
        )

        $startRoot = Join-Path $fixtureRoot ('p8-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $codexHome = Join-Path $startRoot 'codex-home'
        $handoffLineRoot = Join-Path $startRoot '.local\ai-sessions\handoff\line-a'
        $reportRoot = Join-Path $startRoot '.local\ai-sessions\report\line-a'
        New-Item -ItemType Directory -Path $codexHome, $handoffLineRoot, $reportRoot -Force | Out-Null
        Write-Utf8NoBom -Path (Join-Path $handoffLineRoot 'line.json') -Content (([ordered]@{ schema = 'ai-sessions.line.v1'; 'line-slug' = 'line-a' } | ConvertTo-Json -Depth 4) + "`r`n")
        $dispatchSlug = 'phase8-start-' + $CaseName
        $configPath = Join-Path $codexHome 'advisor.config.toml'
        $promptPath = Join-Path $startRoot 'prompt.md'
        $packPath = Join-Path $startRoot 'evidence.md'
        $preflightPath = Join-Path $startRoot 'preflight.json'
        $beforePath = Join-Path $startRoot 'quota-before.json'
        $afterPath = Join-Path $startRoot 'quota-after.json'
        $reportPath = Join-Path $reportRoot ('advisor-consult-' + $dispatchSlug + '.md')
        $calibrationPath = Join-Path $startRoot 'missing-calibration.jsonl'
        $packLines = @($evidencePackContent -split '\r?\n' | ForEach-Object {
                if ($_ -match '^dispatch-slug:') {
                    'dispatch-slug: ' + $dispatchSlug
                }
                elseif ($_ -match '^question-002:') {
                    $_
                    'question-003: fixture third question'
                }
                else {
                    $_
                }
            })
        $packContent = ($packLines -join [Environment]::NewLine) + [Environment]::NewLine
        Write-Utf8NoBom -Path $configPath -Content "model = 'fixture-model'`r`nmodel_reasoning_effort = 'high'`r`n"
        Write-Utf8NoBom -Path $promptPath -Content 'fixture advisor prompt'
        Write-Utf8NoBom -Path $packPath -Content $packContent
        Write-Utf8NoBom -Path $preflightPath -Content (([ordered]@{
                    sourceRoot = $startRoot
                    executionRoot = $startRoot
                    dispatchRoot = $startRoot
                    lineSlug = 'line-a'
                    dispatchSlug = $dispatchSlug
                    writeMode = 'readonly'
                    dispatchKind = 'resource'
                } | ConvertTo-Json -Depth 12) + "`r`n")
        $null = New-Phase8QuotaSnapshot -Path $beforePath -PrimaryRemainingPercent $PrimaryRemainingPercent
        $null = New-Phase8QuotaSnapshot -Path $afterPath -PrimaryRemainingPercent $PrimaryRemainingPercent

        $script:SourceRoot = $startRoot
        $script:ExecutionRoot = $startRoot
        $script:DispatchRoot = $startRoot
        $script:LineSlug = 'line-a'
        $script:DispatchSlug = $dispatchSlug
        $script:DispatchKind = 'resource'
        $script:TaskType = 'advisor-consult'
        $script:WriteMode = 'readonly'
        $script:SessionMode = 'cold-start'
        $script:Profile = 'advisor'
        $script:ProfileExplicit = $true
        $script:Model = $null
        $script:ReasoningEffort = $null
        $script:CodexHome = $codexHome
        $script:CodexPath = $null
        $script:CodexParentOption = $null
        $script:AddDirectory = $null
        $script:Search = $false
        $script:RequestedUnit = $null
        $script:UnitKind = 'advisor-evidence-question'
        $script:PrimaryBudgetPercent = $null
        $script:PrimaryReservePercent = $null
        $script:PreflightResultPath = $preflightPath
        $script:PromptPath = $promptPath
        $script:EvidencePackPath = $packPath
        $script:AdvisorConsultReportPath = if ($OmitAdvisorConsultReportPath) { $null } else { $reportPath }
        $script:ResultPath = $null
        $script:PrepareResultPath = $null
        $script:QuotaBeforePath = $beforePath
        $script:QuotaAfterPath = $afterPath
        $script:CalibrationPath = $calibrationPath
        $script:BudgetMonitorPath = $null
        $script:ScopePlanPath = $null
        $script:LastMessagePath = $null
        $script:ResumeThreadId = $null
        $script:RecoveryHandoffPath = $null
        $script:RequestPath = $null
        $script:InitialQuotaState = 'Valid'
        $script:AdvisorRequestSource = $AdvisorRequestSourceValue
        $script:InvocationBoundParameters = [ordered]@{}
        $script:RequestContext = $null
        $script:RequestPrepareArtifacts = @()
        $script:pidResult = @{ ActiveRecords = @(); UnconfirmedRecords = @(); Blocked = $false; Reason = '' }
        $script:quotaSnapshotPathOverride = $beforePath
        $script:dispatchUnitListOverride = @('question-001', 'question-002', 'question-003')
        $script:advisorStartPromptMode = $true
        $script:launcherFixtureFailure = $true
        $script:phase8CapturedActivation = $null
        $script:phase8CapturedScopePlan = $null
        $caughtException = $null
        $operationResult = $null
        try {
            $null = Invoke-Start
        }
        catch {
            $caughtException = $_.Exception
            $operationResult = $caughtException.Data['operationResult']
        }
        $runRecord = $null
        if ($null -ne $operationResult -and -not [string]::IsNullOrWhiteSpace([string]$operationResult.runRecordPath) -and (Test-Path -LiteralPath $operationResult.runRecordPath -PathType Leaf)) {
            $runRecord = Get-Content -LiteralPath $operationResult.runRecordPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        $result = [pscustomobject]@{
            case_name = $CaseName
            root = $startRoot
            before_path = $beforePath
            exception = $caughtException
            operation_result = $operationResult
            activation = $script:phase8CapturedActivation
            scope_plan = $script:phase8CapturedScopePlan
            run_record = $runRecord
        }
        $script:advisorStartPromptMode = $false
        $script:launcherFixtureFailure = $false
        $script:quotaSnapshotPathOverride = $null
        $script:dispatchUnitListOverride = $null
        return $result
    }

    Invoke-Case 'Phase 8 advisor 契約矩陣與拒絕碼' {
        Assert-AdvisorContract -RequestedProfile 'advisor' -TaskType 'advisor-consult' -DispatchKind 'resource' -WriteMode 'readonly'
        foreach ($case in @(
                [ordered]@{ profile = 'advisor'; task = 'script-change'; kind = 'resource'; mode = 'readonly'; code = 'AdvisorImplementationProfileRejected' }
                [ordered]@{ profile = 'advisor'; task = 'advisor-consult'; kind = 'workflow'; mode = 'readonly'; code = 'AdvisorImplementationProfileRejected' }
                [ordered]@{ profile = 'advisor'; task = 'advisor-consult'; kind = 'resource'; mode = 'write'; code = 'AdvisorImplementationProfileRejected' }
                [ordered]@{ profile = 'default'; task = 'advisor-consult'; kind = 'resource'; mode = 'readonly'; code = 'AdvisorProfileRequired' })) {
            $caught = $null
            try {
                Assert-AdvisorContract -RequestedProfile $case.profile -TaskType $case.task -DispatchKind $case.kind -WriteMode $case.mode
            }
            catch {
                $caught = $_.Exception.Message
            }
            Assert-True ($null -ne $caught -and $caught.Contains($case.code)) ('契約拒絕碼不符：' + ($case | ConvertTo-Json -Compress))
        }
    }

    Invoke-Case 'Phase 8 F-009 Setup 缺少 default 設定檔不宣稱雙檔完整' {
        $caseRoot = Join-Path $phase8Root 'f009-missing-default'
        $artifacts = New-Phase8RegressionArtifacts -CaseRoot $caseRoot -DispatchSlug 'phase8-f009-missing-default'
        $advisorPath = Join-Path $caseRoot 'advisor.config.toml'
        Write-Utf8NoBom -Path $advisorPath -Content "model = 'fixture-model'`r`nmodel_reasoning_effort = 'high'`r`n"
        $missing = Invoke-SetupProfileCheck -CodexDirectory $caseRoot
        $successMessage = '  ✅ Codex 預設檔位與 advisor.config.toml 均存在。'
        $warningOutput = @($missing.warning_messages) -join [Environment]::NewLine
        $hostOutput = @($missing.host_messages) -join [Environment]::NewLine
        Assert-True ((Test-Path -LiteralPath $artifacts.quota_snapshot_path -PathType Leaf) -and (Test-Path -LiteralPath $artifacts.evidence_pack_path -PathType Leaf) -and (Test-Path -LiteralPath $artifacts.final_message_path -PathType Leaf)) 'F-009 fixture 未實際寫入 quota snapshot、evidence pack 或 final message。'
        Assert-True (@($missing.missing_profiles) -contains 'config.toml' -and $warningOutput.Contains('config.toml')) ('缺少 config.toml 未列入 missingProfiles。warnings=' + $warningOutput)
        Assert-True (-not $hostOutput.Contains($successMessage)) ('缺少 config.toml 仍輸出雙檔成功訊息。host=' + $hostOutput)

        $configPath = Join-Path $caseRoot 'config.toml'
        Write-Utf8NoBom -Path $configPath -Content "model = 'fixture-model'`r`nmodel_reasoning_effort = 'high'`r`n"
        $complete = Invoke-SetupProfileCheck -CodexDirectory $caseRoot
        $completeHostOutput = @($complete.host_messages) -join [Environment]::NewLine
        Assert-True (@($complete.missing_profiles).Count -eq 0 -and $completeHostOutput.Contains($successMessage)) ('兩個設定檔都存在時未輸出成功訊息。host=' + $completeHostOutput)
    }

    Invoke-Case 'Phase 8 F-010 active source guard 覆蓋完整來源與舊識別字' {
        $requiredPaths = @(
            $sourcePath
            (Join-Path $PSScriptRoot 'Setup-AIGlobalConfig.ps1')
            (Join-Path $PSScriptRoot 'Get-CodexQuota.ps1')
            (Join-Path $root 'instructions.md')
            (Join-Path $root 'skills\codex-dispatch\SKILL.md')
            (Join-Path $root 'README.md')
            $PSCommandPath
        )
        foreach ($requiredPath in $requiredPaths) {
            $normalizedRequiredPath = [IO.Path]::GetFullPath($requiredPath)
            $pathFound = @($activeSourcePaths | Where-Object {
                    [String]::Equals([IO.Path]::GetFullPath([string]$_), $normalizedRequiredPath, [StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0
            Assert-True $pathFound ('active source 缺少指定來源：' + $requiredPath)
        }

        $expectedPhase1Terms = @(
            ('[' + 'ValidateSet(' + "'default', 'deep'" + ')]')
            ('d' + 'eep' + '-consult')
            ('d' + 'eep' + '-evidence-pack')
            ('d' + 'eep' + '-consult.evidence.v1')
            ('Deep' + 'RequestSource')
            ('Deep' + 'ConsultReportPath')
            ('Get-' + 'Deep' + 'ConsultReportPath')
            ('New-' + 'Deep' + 'InlineEvidenceDirective')
            ('Test-' + 'Deep' + 'InlineEvidenceDirective')
            ('Write-' + 'Deep' + 'ConsultReport')
            ('Invoke-' + 'Deep' + 'BudgetMonitor')
            ('d' + 'eep' + '.config.toml')
            ('[' + 'deep' + ' 諮詢確認]')
        )
        foreach ($term in $expectedPhase1Terms) {
            Assert-True (@($phase1RemovalTerms | Where-Object { $_ -ceq $term }).Count -eq 1) ('Phase 1 搜尋詞缺少：' + $term)
            Assert-True (@($phase2RemovalTerms | Where-Object { $_ -ceq $term }).Count -eq 1) ('Phase 2 未沿用 Phase 1 搜尋詞：' + $term)
        }
        foreach ($term in @(
                ('deep' + 'RequestSource')
                ('deep' + 'CycleDecision')
                ('deep' + 'CycleGatePassed')
                ('deep' + 'CycleNotice')
                ('deep' + 'ConsultReportPath')
                ('deep' + '_hard_limit_percent')
                ('[' + 'deep' + ' 週期位置告知]'))) {
            Assert-True (@($phase2RemovalTerms | Where-Object { $_ -ceq $term }).Count -eq 1) ('Phase 2 搜尋詞缺少：' + $term)
        }

        $probePath = Join-Path $phase8Root 'f010-active-source-probe.md'
        $probeTerm = 'Write-' + 'Deep' + 'ConsultReport'
        Write-Utf8NoBom -Path $probePath -Content $probeTerm
        $previousActiveSourcePaths = @($script:activeSourcePaths)
        try {
            $script:activeSourcePaths = @($previousActiveSourcePaths + $probePath)
            $caught = $null
            try { Assert-ActiveSourceNotFound -Label 'F-010 probe' -Terms @($probeTerm) }
            catch { $caught = $_.Exception.Message }
            Assert-True ($null -ne $caught -and $caught.Contains($probePath) -and $caught.Contains($probeTerm)) 'active source guard 未對新增來源的舊識別字回報匹配。'
        }
        finally {
            $script:activeSourcePaths = $previousActiveSourcePaths
        }
    }

    Invoke-Case 'Phase 8 F-013 Setup 舊設定檔殘留與新舊衝突指引' {
        $caseRoot = Join-Path $phase8Root 'f013-legacy-profile'
        $artifacts = New-Phase8RegressionArtifacts -CaseRoot $caseRoot -DispatchSlug 'phase8-f013-legacy-profile'
        $configPath = Join-Path $caseRoot 'config.toml'
        $advisorPath = Join-Path $caseRoot 'advisor.config.toml'
        $legacyName = 'deep' + '.config.toml'
        $legacyPath = Join-Path $caseRoot $legacyName
        $profileContent = "model = 'fixture-model'`r`nmodel_reasoning_effort = 'high'`r`n"
        Write-Utf8NoBom -Path $configPath -Content $profileContent
        Write-Utf8NoBom -Path $legacyPath -Content $profileContent

        $renameGuidance = Invoke-SetupProfileCheck -CodexDirectory $caseRoot
        $renameOutput = (@($renameGuidance.warning_messages) + @($renameGuidance.host_messages)) -join [Environment]::NewLine
        $successMessage = '  ✅ Codex 預設檔位與 advisor.config.toml 均存在。'
        Assert-True ($renameOutput.Contains($legacyName) -and $renameOutput.Contains('重新命名') -and -not $renameOutput.Contains($successMessage)) ('舊設定檔殘留未提供重新命名指引。output=' + $renameOutput)
        Assert-True ((Test-Path -LiteralPath $legacyPath -PathType Leaf) -and -not (Test-Path -LiteralPath $advisorPath -PathType Leaf)) '舊設定檔殘留案例被自動搬移或刪除。'

        Write-Utf8NoBom -Path $advisorPath -Content $profileContent
        $conflict = Invoke-SetupProfileCheck -CodexDirectory $caseRoot
        $conflictOutput = (@($conflict.warning_messages) + @($conflict.host_messages)) -join [Environment]::NewLine
        Assert-True ($conflict.profile_conflict_detected -and $conflictOutput.Contains($legacyName) -and $conflictOutput.Contains('衝突') -and $conflictOutput.Contains('人工處理') -and -not $conflictOutput.Contains($successMessage)) ('新舊設定檔並存未停止成功訊息或提供人工處理指引。output=' + $conflictOutput)
        Assert-True ((Test-Path -LiteralPath $legacyPath -PathType Leaf) -and (Test-Path -LiteralPath $advisorPath -PathType Leaf)) '設定檔衝突案例自動搬移或刪除了檔案。'
        Assert-True ((Test-Path -LiteralPath $artifacts.quota_snapshot_path -PathType Leaf) -and (Test-Path -LiteralPath $artifacts.evidence_pack_path -PathType Leaf) -and (Test-Path -LiteralPath $artifacts.final_message_path -PathType Leaf)) 'F-013 fixture 未實際寫入 quota snapshot、evidence pack 或 final message。'
    }

    Invoke-Case 'Phase 8 F-001 advisor activation 嚴格檢查 snapshot state' {
        $expiredSnapshot = $script:phase7ValidSnapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $expiredSnapshot.state = 'SnapshotExpired'
        $automaticExpired = Get-AdvisorActivationDecision -QuotaSnapshot $expiredSnapshot -State 'SnapshotExpired' -EstimatePercent 24 -RequestSource 'automatic-quota' -HasFreshObservations $true -ServiceRejected $false
        $explicitExpired = Get-AdvisorActivationDecision -QuotaSnapshot $expiredSnapshot -State 'SnapshotExpired' -EstimatePercent 24 -RequestSource 'user-explicit' -HasFreshObservations $true -ServiceRejected $false
        Assert-True (-not $automaticExpired.granted -and -not $explicitExpired.granted -and $automaticExpired.reasonCode -eq 'blocked-no-fresh-quota' -and $explicitExpired.reasonCode -eq 'blocked-no-fresh-quota') 'SnapshotExpired 在 fresh observation 下仍授予 advisor activation。'
    }

    Invoke-Case 'Phase 8 advisor activation automatic、user explicit 與低額度' {
        $automatic = Get-AdvisorActivationDecision -QuotaSnapshot $script:phase7ValidSnapshot -EstimatePercent 24 -RequestSource 'automatic-quota' -HasFreshObservations $true -ServiceRejected $false
        Assert-True ($automatic.granted -and $automatic.activationMode -eq 'automatic-quota' -and $automatic.authorizationSource -eq 'automatic-quota' -and -not $automatic.reserveBypassed) 'automatic-quota advisor activation 未通過。'
        $denied = Get-AdvisorActivationDecision -QuotaSnapshot $script:phase7LowSnapshot -EstimatePercent 24 -RequestSource 'automatic-quota' -HasFreshObservations $true -ServiceRejected $false
        Assert-True (-not $denied.granted -and $denied.reasonCode -eq 'AdvisorAuthorizationRequired' -and $denied.activationMode -eq 'none') '低額度 automatic-quota 未要求 user-explicit。'
        $authorized = Get-AdvisorActivationDecision -QuotaSnapshot $script:phase7LowSnapshot -EstimatePercent 24 -RequestSource 'user-explicit' -HasFreshObservations $true -ServiceRejected $false
        Assert-True ($authorized.granted -and $authorized.activationMode -eq 'user-authorized' -and $authorized.reserveBypassed -and $authorized.minimumUnitOverBudget) 'user-explicit 低額度未略過 reserve 或保留最小單位授權。'
    }

    Invoke-Case 'Phase 8 A1(a) 缺漏來源走 automatic-quota activation' {
        $absent = Invoke-Phase8StartPreparation -CaseName 'a-absent' -PrimaryRemainingPercent 80 -AdvisorRequestSourceValue $null
        $explicit = Invoke-Phase8StartPreparation -CaseName 'a-explicit-automatic' -PrimaryRemainingPercent 80 -AdvisorRequestSourceValue 'automatic-quota'
        foreach ($case in @($absent, $explicit)) {
            $operationResult = $case.operation_result
            $diagnostic = [ordered]@{ error = if ($null -eq $operationResult) { $null } else { $operationResult.error }; error_code = if ($null -eq $operationResult) { $null } else { $operationResult.errorCode }; activation = $case.activation; scope_plan = $case.scope_plan; exception = if ($null -eq $case.exception) { $null } else { $case.exception.Message } } | ConvertTo-Json -Depth 12 -Compress
            Assert-True ($null -ne $operationResult -and $operationResult.errorCode -ne 'RequiredParameterMissing' -and -not $operationResult.processStarted) ($case.case_name + ' 仍將缺漏 AdvisorRequestSource 視為 RequiredParameterMissing。diagnostic=' + $diagnostic)
            Assert-True ($null -ne $case.activation -and $case.activation.activationMode -eq 'automatic-quota' -and $case.activation.authorizationSource -eq 'automatic-quota') ($case.case_name + ' 未進入 automatic-quota activation。diagnostic=' + $diagnostic)
            Assert-True ($null -ne $case.run_record -and $case.run_record.advisor_request_source -eq 'automatic-quota') ($case.case_name + ' 未在 RunRecord 標記 automatic-quota。')
            Assert-True (-not (Test-Path -LiteralPath ([string]$operationResult.pidRecordPath) -PathType Leaf) -and -not (Test-Path -LiteralPath ([string]$operationResult.eventStreamPath) -PathType Leaf)) ($case.case_name + ' 啟動失敗前建立 PID 或 event stream。')
        }
        Assert-True ($absent.activation.activationMode -eq $explicit.activation.activationMode -and $absent.activation.authorizationSource -eq $explicit.activation.authorizationSource) '缺漏來源與顯式 automatic-quota 行為不一致。'
    }

    Invoke-Case 'Phase 8 A1(b) 缺漏來源低額度回報 AdvisorAuthorizationRequired' {
        $case = Invoke-Phase8StartPreparation -CaseName 'b-insufficient' -PrimaryRemainingPercent 20 -AdvisorRequestSourceValue $null
        $operationResult = $case.operation_result
        Assert-True ($null -ne $operationResult -and $operationResult.errorCode -eq 'AdvisorAuthorizationRequired' -and -not $operationResult.processStarted -and [string]$operationResult.error -match 'AdvisorAuthorizationRequired') '缺漏來源低額度未回報 AdvisorAuthorizationRequired。'
        Assert-True (-not (Test-Path -LiteralPath ([string]$operationResult.pidRecordPath) -PathType Leaf) -and -not (Test-Path -LiteralPath ([string]$operationResult.eventStreamPath) -PathType Leaf)) 'AdvisorAuthorizationRequired 拒絕前建立 PID 或 event stream。'
    }

    Invoke-Case 'Phase 8 F-014 automatic-quota 拒絕保存 activation metadata' {
        $beforeStartCalls = $script:startCalls
        $case = Invoke-Phase8StartPreparation -CaseName 'f014-automatic-insufficient' -PrimaryRemainingPercent 20 -AdvisorRequestSourceValue 'automatic-quota'
        $operationResult = $case.operation_result
        $runRecord = $case.run_record
        $failure = if ($null -eq $runRecord) { $null } else { $runRecord.failure }
        $expectedFields = $null -ne $operationResult -and
            $operationResult.errorCode -eq 'AdvisorAuthorizationRequired' -and
            -not $operationResult.processStarted -and
            $operationResult.activationMode -eq 'none' -and
            $operationResult.authorizationSource -eq $null -and
            $operationResult.primaryRemainingPercent -eq 20 -and
            $operationResult.requiredSource -eq 'user-explicit'
        Assert-True $expectedFields ('F-014 Start failure summary 缺少 activation metadata：' + ($operationResult | ConvertTo-Json -Depth 12 -Compress))
        Assert-True ($null -ne $runRecord -and $runRecord.activationMode -eq 'none' -and $runRecord.authorizationSource -eq $null -and $runRecord.primaryRemainingPercent -eq 20 -and $runRecord.requiredSource -eq 'user-explicit') 'F-014 RunRecord top-level activation metadata 缺失。'
        Assert-True ($null -ne $failure -and $failure.activationMode -eq 'none' -and $failure.authorizationSource -eq $null -and $failure.primaryRemainingPercent -eq 20 -and $failure.requiredSource -eq 'user-explicit') 'F-014 RunRecord.failure activation metadata 缺失。'
        Assert-True ($script:startCalls -eq $beforeStartCalls) 'F-014 AdvisorAuthorizationRequired 仍嘗試啟動 process。'
    }

    Invoke-Case 'Phase 8 A1(c) 缺少 AdvisorConsultReportPath 仍為 RequiredParameterMissing' {
        $case = Invoke-Phase8StartPreparation -CaseName 'c-report-missing' -PrimaryRemainingPercent 80 -AdvisorRequestSourceValue $null -OmitAdvisorConsultReportPath
        $operationResult = $case.operation_result
        $diagnostic = [ordered]@{ error = if ($null -eq $operationResult) { $null } else { $operationResult.error }; error_code = if ($null -eq $operationResult) { $null } else { $operationResult.errorCode }; exception = if ($null -eq $case.exception) { $null } else { $case.exception.Message } } | ConvertTo-Json -Depth 8 -Compress
        Assert-True ($null -ne $operationResult -and $operationResult.errorCode -eq 'RequiredParameterMissing' -and [string]$operationResult.error -match 'AdvisorConsultReportPath' -and -not $operationResult.processStarted) ('缺少 AdvisorConsultReportPath 未保留 RequiredParameterMissing。diagnostic=' + $diagnostic)
    }

    Invoke-Case 'Phase 8 A2(d) user-authorized 預算使用 primary remaining' {
        $case = Invoke-Phase8StartPreparation -CaseName 'd-user-50' -PrimaryRemainingPercent 50 -AdvisorRequestSourceValue 'user-explicit'
        $plan = $case.scope_plan
        Assert-True ($null -ne $plan -and $plan.activation_mode -eq 'user-authorized' -and $plan.primary_reserve_percent -eq 0 -and $plan.primary_budget_percent -eq 50 -and $plan.advisor_hard_limit_percent -eq 30 -and @($plan.selected_units).Count -eq 3 -and @($plan.deferred_units).Count -eq 0) 'user-authorized primary 50% 未使用完整剩餘額度或 hard limit 錯誤限制 budget。'
    }

    Invoke-Case 'Phase 8 F-005 A2(e) user-authorized 低額度取最長前綴' {
        $case = Invoke-Phase8StartPreparation -CaseName 'e-user-10' -PrimaryRemainingPercent 10 -AdvisorRequestSourceValue 'user-explicit'
        $plan = $case.scope_plan
        Assert-True ($null -ne $plan -and $plan.activation_mode -eq 'user-authorized' -and $plan.primary_reserve_percent -eq 0 -and $plan.primary_budget_percent -eq 10 -and $plan.advisor_hard_limit_percent -eq 30 -and $plan.decision -eq 'scoped' -and @($plan.selected_units).Count -eq 1 -and $plan.selected_units[0] -eq 'question-001' -and @($plan.deferred_units).Count -eq 2 -and $plan.deferred_units[0] -eq 'question-002' -and $plan.deferred_units[1] -eq 'question-003' -and -not $plan.minimum_unit_over_budget -and $plan.stop_after_selected_units) 'F-005 user-authorized primary 10% 在第一個問題可容納時誤標記 minimum unit over budget。'
    }

    Invoke-Case 'Phase 8 A2(f) automatic-quota 維持 hard limit budget' {
        $case = Invoke-Phase8StartPreparation -CaseName 'f-automatic-80' -PrimaryRemainingPercent 80 -AdvisorRequestSourceValue 'automatic-quota'
        $plan = $case.scope_plan
        Assert-True ($null -ne $plan -and $plan.activation_mode -eq 'automatic-quota' -and $plan.primary_reserve_percent -eq 30 -and $plan.primary_budget_percent -eq 30 -and $plan.advisor_hard_limit_percent -eq 30) 'automatic-quota primary 80% 未維持 min(hardLimit, remaining - reserve) budget。'
    }

    Invoke-Case 'Phase 8 A2 decision_reason 不使用等待指示' {
        $scopePlanSource = ($functions | Where-Object { $_.Name -eq 'New-ScopePlan' } | Select-Object -First 1).Extent.Text
        Assert-True ($scopePlanSource -notmatch '等待 primary_resets_at 或使用者決定' -and $scopePlanSource -notmatch '等待 primary reset') 'New-ScopePlan 仍含 primary reset 等待指示。'
        $unauthorized = New-ScopePlan -DispatchSlug 'phase8-advisor-unauthorized-reason' -DispatchKind 'resource' -TaskType 'advisor-consult' -RequestedProfile 'advisor' -SessionMode 'cold-start' -BeforeSnapshot $script:phase7LowSnapshot -CalibrationPath (Join-Path $phase7Root 'missing-phase8-unauthorized-reason-calibration.jsonl') -Units @('question-001') -UnitKind 'advisor-evidence-question' -Model $null -ModelEvidence $null -ReasoningEffortEvidence $null
        Assert-True ($unauthorized.decision -eq 'blocked-insufficient-budget' -and $unauthorized.decision_reason -match 'AdvisorAuthorizationRequired' -and $unauthorized.decision_reason -notmatch '等待') 'advisor 未授權 ScopePlan 說明未指向 AdvisorAuthorizationRequired。'
    }

    Invoke-Case 'Phase 8 default zero remaining 最小單位且不繞過 advisor gate' {
        $defaultZeroSnapshot = $script:phase7LowSnapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $defaultZeroSnapshot.observations.primary.remaining_percent = 0
        $defaultZeroSnapshot.observations.primary.used_percent = 100
        $defaultZeroSnapshot.primary.remaining_percent = 0
        $defaultZeroSnapshot.primary.used_percent = 100
        $defaultZeroPlan = New-ScopePlan -DispatchSlug 'phase8-default-zero' -DispatchKind 'workflow' -TaskType 'script-change' -RequestedProfile 'default' -SessionMode 'cold-start' -BeforeSnapshot $defaultZeroSnapshot -CalibrationPath (Join-Path $phase7Root 'missing-phase8-default-calibration.jsonl') -Units @('unit-1', 'unit-2') -UnitKind 'workflow-phase' -Model $null -ModelEvidence $null -ReasoningEffortEvidence $null
        Assert-True ($defaultZeroPlan.decision -eq 'scoped' -and $defaultZeroPlan.primary_reserve_percent -eq 0 -and $defaultZeroPlan.primary_budget_percent -eq 0 -and @($defaultZeroPlan.selected_units).Count -eq 1 -and $defaultZeroPlan.selected_units[0] -eq 'unit-1' -and @($defaultZeroPlan.deferred_units).Count -eq 1 -and $defaultZeroPlan.stop_after_selected_units -and $defaultZeroPlan.decision -ne 'blocked-insufficient-budget' -and $defaultZeroPlan.decision -ne 'user-decision-required' -and $defaultZeroPlan.decision_reason -notmatch '等待') 'default zero remaining 未建立最小 ScopePlan，或產生不允許的等待決策。'
        $advisorGateCaught = $null
        try { Assert-AdvisorContract -RequestedProfile 'default' -TaskType 'advisor-consult' -DispatchKind 'resource' -WriteMode 'readonly' }
        catch { $advisorGateCaught = $_.Exception.Message }
        Assert-True ($null -ne $advisorGateCaught -and $advisorGateCaught.Contains('AdvisorProfileRequired')) 'default zero remaining 路徑繞過 advisor profile gate。'
    }

    Invoke-Case 'Phase 8 F-006 service rejection 停止派工並保存 QuotaServiceRejected' {
        Assert-True ($null -ne $script:phase7RejectedSnapshot -and $null -ne $script:phase7RejectedDocument) 'F-006 缺少 Phase 7 service rejection fixture。'
        $caseRoot = Join-Path $phase8Root 'f006-service-rejection'
        $artifacts = New-Phase8RegressionArtifacts -CaseRoot $caseRoot -DispatchSlug 'phase8-f006-service-rejection'
        Write-Utf8NoBom -Path $artifacts.quota_snapshot_path -Content (($script:phase7RejectedDocument | ConvertTo-Json -Depth 20) + "`r`n")
        $eventPath = Join-Path $caseRoot 'event-stream.jsonl'
        $errorPath = Join-Path $caseRoot 'stderr.log'
        $lastMessagePath = Join-Path $caseRoot 'last-message.md'
        $threadPath = Join-Path $caseRoot 'thread-id.txt'
        $pidPath = Join-Path $caseRoot 'pid.json'
        $launcherPath = Join-Path $caseRoot 'launcher.json'
        Write-Phase7JsonLines -Path $eventPath -Objects @([ordered]@{ type = 'turn.failed'; error = [ordered]@{ code = 'usage_limit_reached' } })
        Write-Utf8NoBom -Path $errorPath -Content 'service rejection fixture'
        Write-Utf8NoBom -Path $lastMessagePath -Content 'ScopePlan service rejection fixture'
        Write-Utf8NoBom -Path $threadPath -Content 'thread-f006'
        Write-Utf8NoBom -Path $pidPath -Content '{"pid":0}'
        Write-Utf8NoBom -Path $launcherPath -Content '{"launcher":"fixture"}'
        $f006Plan = New-ScopePlan -DispatchSlug 'phase8-f006-service-rejection' -DispatchKind 'workflow' -TaskType 'script-change' -RequestedProfile 'default' -SessionMode 'cold-start' -BeforeSnapshot $script:phase7RejectedSnapshot -CalibrationPath (Join-Path $phase7Root 'missing-phase8-f006-calibration.jsonl') -Units @('Phase 3') -UnitKind 'workflow-phase' -Model $null -ModelEvidence $null -ReasoningEffortEvidence $null
        $f006Message = 'ScopePlan 阻擋派工：decision=' + [string]$f006Plan.decision + '; reason=quota service rejection 已保留 last observation。'
        $f006Failure = New-DispatchFailureRecord -Phase 'preparation' -Message $f006Message -ProcessStarted $false -ProcessExitCode $null -EventPath $eventPath -ErrorPath $errorPath -LastMessagePath $lastMessagePath -ThreadPath $threadPath -PidPath $pidPath -LauncherPath $launcherPath -RolloutPaths @($eventPath)
        Assert-True ($f006Plan.quota_state -eq 'ServiceRejected' -and $f006Plan.decision -eq 'blocked-no-fresh-quota' -and $f006Plan.retry_allowed -eq $false -and $f006Failure.reason_code -eq 'QuotaServiceRejected') 'F-006 service rejection 未停止派工或未回傳 QuotaServiceRejected。'
        Assert-True ((Test-Path -LiteralPath $artifacts.quota_snapshot_path -PathType Leaf) -and (Test-Path -LiteralPath $artifacts.evidence_pack_path -PathType Leaf) -and (Test-Path -LiteralPath $artifacts.final_message_path -PathType Leaf) -and $f006Failure.original_output.event_stream.exists) 'F-006 fixture 未保存 quota snapshot、evidence pack、final message 或 event evidence。'
    }

    Invoke-Case 'Phase 8 A4 command_execution 輸出與不可解析文字不產生 usage-limit' {
        $commandEvidencePath = Join-Path $phase8Root 'a4-command-output.jsonl'
        $commandEvent = [ordered]@{
            timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            type = 'item.completed'
            item = [ordered]@{
                type = 'command_execution'
                command = 'Write-Output usage_limit_reached'
                aggregated_output = 'usage_limit_reached'
            }
        }
        Write-Phase7JsonLines -Path $commandEvidencePath -Objects @($commandEvent)
        Add-Content -LiteralPath $commandEvidencePath -Value 'not-json usage_limit_reached' -Encoding UTF8
        $commandEvidence = Get-DispatchEventEvidence -EventPath $commandEvidencePath
        Assert-True ($commandEvidence.usage_limit -eq $false -and @($commandEvidence.usage_limit_evidence).Count -eq 0 -and $commandEvidence.last_event_type -eq 'item.completed') 'A4 將 command_execution 輸出或不可解析文字誤判為 usage-limit。'
    }

    Invoke-Case 'Phase 8 A4 turn.failed usage-limit 結構化事件仍產生 rejection' {
        $failedEvidencePath = Join-Path $phase8Root 'a4-turn-failed.jsonl'
        $failedEvent = [ordered]@{
            timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            type = 'turn.failed'
            error = [ordered]@{
                code = 'usage_limit_reached'
                message = 'usage limit reached'
            }
        }
        Write-Phase7JsonLines -Path $failedEvidencePath -Objects @($failedEvent)
        $failedEvidence = Get-DispatchEventEvidence -EventPath $failedEvidencePath
        $failedRejection = Convert-EventEvidenceToServiceRejection -EventEvidence $failedEvidence
        Assert-True ($failedEvidence.usage_limit -eq $true -and @($failedEvidence.usage_limit_evidence).Count -eq 1 -and $failedEvidence.usage_limit_evidence[0].reason_code -eq 'usage-limit' -and $failedRejection.reason_code -eq 'usage-limit' -and $failedRejection.retry_allowed -eq $false) 'A4 真實 turn.failed usage-limit 事件未產生 usage-limit service rejection。'
    }

    Invoke-Case 'Phase 8 F-015 Inspect service rejection 使用 QuotaServiceRejected' {
        $caseRoot = Join-Path $phase8Root 'f015-inspect-service-rejection'
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $record = New-TestRun -Line 'line-a' -Dispatch 'phase8-f015-inspect'
        $recordPath = Join-Path (Get-DispatchRunDirectory $fixtureRoot 'line-a' 'phase8-f015-inspect') ($record.run_id + '.json')
        $scopePlan = New-ScopePlan -DispatchSlug 'phase8-f015-inspect' -DispatchKind 'workflow' -TaskType 'script-change' -RequestedProfile 'default' -SessionMode 'cold-start' -BeforeSnapshot $script:phase7ValidSnapshot -CalibrationPath (Join-Path $caseRoot 'calibration.jsonl') -Units @('Phase 3') -UnitKind 'workflow-phase' -Model 'fixture-model' -ModelEvidence $null -ReasoningEffortEvidence $null
        Write-Utf8NoBom -Path $record.scope_plan_path -Content (($scopePlan | ConvertTo-Json -Depth 20) + "`r`n")
        $record.scope_plan_sha256 = Get-FileSha256 -Path $record.scope_plan_path
        $null = Write-DispatchRunRecord -Record $record -Update
        Write-Phase7JsonLines -Path $record.event_stream_path -Objects @(
            [ordered]@{ type = 'thread.started'; thread_id = $script:testThread }
            [ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'agent_message'; text = 'design.md phase8-f015-inspect line-a' } }
            [ordered]@{ type = 'turn.failed'; error = [ordered]@{ code = 'usage_limit_reached'; message = 'usage limit reached' } }
        )
        Write-Utf8NoBom -Path $record.last_message_path -Content 'design.md phase8-f015-inspect line-a'
        $errorPath = Join-Path $caseRoot 'stderr.log'
        Write-Utf8NoBom -Path $errorPath -Content 'structured quota rejection fixture'
        $beforePath = Join-Path $caseRoot 'quota-before.json'
        $afterPath = Join-Path $caseRoot 'quota-after.json'
        $null = New-Phase8QuotaSnapshot -Path $beforePath -PrimaryRemainingPercent 80
        $null = New-Phase8QuotaSnapshot -Path $afterPath -PrimaryRemainingPercent 79
        $previousValues = [ordered]@{
            SourceRoot = $SourceRoot
            ExecutionRoot = $ExecutionRoot
            LineSlug = $LineSlug
            DispatchSlug = $DispatchSlug
            CodexHome = $CodexHome
            EventStreamPath = $EventStreamPath
            ScopePlanPath = $ScopePlanPath
            RequiredIdentifier = $RequiredIdentifier
            ProcessExitCode = $ProcessExitCode
            QuotaBeforePath = $QuotaBeforePath
            QuotaAfterPath = $QuotaAfterPath
            CalibrationPath = $CalibrationPath
            ErrorStreamPath = $ErrorStreamPath
            RunRecordPath = $RunRecordPath
            Profile = $Profile
            TaskType = $TaskType
            SessionMode = $SessionMode
        }
        try {
            $SourceRoot = $fixtureRoot
            $ExecutionRoot = $fixtureRoot
            $LineSlug = 'line-a'
            $DispatchSlug = 'phase8-f015-inspect'
            $CodexHome = $startCodexHome
            $EventStreamPath = $record.event_stream_path
            $ScopePlanPath = $record.scope_plan_path
            $RequiredIdentifier = 'design.md'
            $ProcessExitCode = 1
            $QuotaBeforePath = $beforePath
            $QuotaAfterPath = $afterPath
            $CalibrationPath = Join-Path $caseRoot 'calibration.jsonl'
            $ErrorStreamPath = $errorPath
            $RunRecordPath = $recordPath
            $Profile = 'default'
            $TaskType = 'script-change'
            $SessionMode = 'cold-start'
            $result = Invoke-Inspect
        }
        finally {
            $SourceRoot = $previousValues.SourceRoot
            $ExecutionRoot = $previousValues.ExecutionRoot
            $LineSlug = $previousValues.LineSlug
            $DispatchSlug = $previousValues.DispatchSlug
            $CodexHome = $previousValues.CodexHome
            $EventStreamPath = $previousValues.EventStreamPath
            $ScopePlanPath = $previousValues.ScopePlanPath
            $RequiredIdentifier = $previousValues.RequiredIdentifier
            $ProcessExitCode = $previousValues.ProcessExitCode
            $QuotaBeforePath = $previousValues.QuotaBeforePath
            $QuotaAfterPath = $previousValues.QuotaAfterPath
            $CalibrationPath = $previousValues.CalibrationPath
            $ErrorStreamPath = $previousValues.ErrorStreamPath
            $RunRecordPath = $previousValues.RunRecordPath
            $Profile = $previousValues.Profile
            $TaskType = $previousValues.TaskType
            $SessionMode = $previousValues.SessionMode
        }
        $inspectDiagnosisValid = -not $result.success -and $result.service_rejection.reason_code -eq 'usage-limit' -and $result.diagnosis.reason_code -eq 'QuotaServiceRejected'
        $inspectDiagnosisDiagnostic = if ($inspectDiagnosisValid) { 'pass' } else { $result | ConvertTo-Json -Depth 16 -Compress }
        Assert-True $inspectDiagnosisValid ('F-015 Inspect diagnosis reason code 不符：' + $inspectDiagnosisDiagnostic)
        Assert-True ((Test-Path -LiteralPath $record.event_stream_path -PathType Leaf) -and (Test-Path -LiteralPath $recordPath -PathType Leaf) -and (Test-Path -LiteralPath $beforePath -PathType Leaf) -and (Test-Path -LiteralPath $afterPath -PathType Leaf)) 'F-015 fixture 未保存事件流、RunRecord 或 quota snapshot。'
    }

    Invoke-Case 'Phase 8 F-017 QuotaProbe advisor requested profile 強制 effective default' {
        $caseRoot = Join-Path $phase8Root 'f017-quotaprobe-effective-default'
        $codexHome = Join-Path $caseRoot 'codex-home'
        $promptPath = Join-Path $caseRoot 'prompt.md'
        $snapshotPath = Join-Path $caseRoot 'quota-before.json'
        New-Item -ItemType Directory -Path (Join-Path $codexHome 'sessions') -Force | Out-Null
        Write-Utf8NoBom -Path $promptPath -Content 'QuotaProbe fixture prompt'
        $null = New-Phase8QuotaSnapshot -Path $snapshotPath -PrimaryRemainingPercent 60
        $previousValues = [ordered]@{
            SourceRoot = $SourceRoot
            DispatchRoot = $DispatchRoot
            ExecutionRoot = $ExecutionRoot
            LineSlug = $LineSlug
            DispatchSlug = $DispatchSlug
            Profile = $Profile
            InitialQuotaState = $InitialQuotaState
            TriggerWindow = $TriggerWindow
            ProbeAttempt = $ProbeAttempt
            CodexHome = $CodexHome
            CodexPath = $CodexPath
            PromptPath = $PromptPath
            AddDirectory = $AddDirectory
            Search = $Search
            CodexParentOption = $CodexParentOption
            AdvisorRequestSource = $AdvisorRequestSource
            QuotaBeforePath = $QuotaBeforePath
        }
        $script:quotaProbeCaptureArguments = $true
        $script:quotaProbeCapturedArguments = @()
        $script:quotaProbeCodexHome = $codexHome
        $script:quotaProbeStartCalls = 0
        try {
            $SourceRoot = $caseRoot
            $DispatchRoot = $caseRoot
            $ExecutionRoot = $caseRoot
            $LineSlug = 'line-a'
            $DispatchSlug = 'phase8-f017-quotaprobe'
            $Profile = 'advisor'
            $InitialQuotaState = 'PostResetNoSnapshot'
            $TriggerWindow = 'primary'
            $ProbeAttempt = 1
            $CodexHome = $codexHome
            $CodexPath = $null
            $PromptPath = $promptPath
            $AddDirectory = $null
            $Search = $false
            $CodexParentOption = $null
            $AdvisorRequestSource = $null
            $QuotaBeforePath = $snapshotPath
            $probeResult = Invoke-QuotaProbe
        }
        finally {
            $script:quotaProbeCaptureArguments = $false
            $script:quotaProbeCodexHome = $null
            $SourceRoot = $previousValues.SourceRoot
            $DispatchRoot = $previousValues.DispatchRoot
            $ExecutionRoot = $previousValues.ExecutionRoot
            $LineSlug = $previousValues.LineSlug
            $DispatchSlug = $previousValues.DispatchSlug
            $Profile = $previousValues.Profile
            $InitialQuotaState = $previousValues.InitialQuotaState
            $TriggerWindow = $previousValues.TriggerWindow
            $ProbeAttempt = $previousValues.ProbeAttempt
            $CodexHome = $previousValues.CodexHome
            $CodexPath = $previousValues.CodexPath
            $PromptPath = $previousValues.PromptPath
            $AddDirectory = $previousValues.AddDirectory
            $Search = $previousValues.Search
            $CodexParentOption = $previousValues.CodexParentOption
            $AdvisorRequestSource = $previousValues.AdvisorRequestSource
            $QuotaBeforePath = $previousValues.QuotaBeforePath
        }
        $recovery = Get-Content -LiteralPath $probeResult.recoveryRecordPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($probeResult.success -and $probeResult.processStarted -and $script:quotaProbeStartCalls -eq 1 -and @($probeResult.codexArguments) -notcontains '--profile' -and $probeResult.requested_profile -eq 'advisor' -and $probeResult.effective_profile -eq 'default') ('F-017 Start result 或 codex arguments 不符：' + ($probeResult | ConvertTo-Json -Depth 16 -Compress))
        Assert-True ($recovery.requested_profile -eq 'advisor' -and $recovery.effective_profile -eq 'default' -and @($recovery.probeEvidence.codexArguments) -notcontains '--profile' -and (Test-Path -LiteralPath $script:quotaProbeEventPath -PathType Leaf) -and (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) 'F-017 recovery record、event stream 或 quota snapshot 未保存 requested/effective profile。'
    }

    Invoke-Case 'Phase 8 A4 payload.type 結構化錯誤事件仍可判定' {
        $payloadEvidencePath = Join-Path $phase8Root 'a4-payload-type.jsonl'
        $payloadEvent = [ordered]@{
            timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            type = 'response'
            payload = [ordered]@{
                type = 'turn_failed'
                error = [ordered]@{
                    code = 'rate-limit-exceeded'
                }
            }
        }
        Write-Phase7JsonLines -Path $payloadEvidencePath -Objects @($payloadEvent)
        $payloadEvidence = Get-DispatchEventEvidence -EventPath $payloadEvidencePath
        $payloadRejection = Convert-EventEvidenceToServiceRejection -EventEvidence $payloadEvidence
        Assert-True ($payloadEvidence.usage_limit -eq $true -and $payloadRejection.reason_code -eq 'rate-limit') 'A4 payload.type 結構化錯誤事件未判定為 rate-limit。'
    }

    Invoke-Case 'Phase 8 F-003 required-output 續行拒絕' -Reject -ErrorPattern 'C25 EvidencePackRequiredOutputInvalid' {
        $continuationPath = Join-Path $phase7Root 'phase8-required-output-continuation.md'
        $continuationContent = [regex]::Replace($evidencePackContent, '(?m)^(required-output:[^\r\n]*\r?\n)', ('$1' + 'unmarked continuation' + [Environment]::NewLine))
        Write-Utf8NoBom -Path $continuationPath -Content $continuationContent
        Test-AdvisorEvidencePack -Path $continuationPath -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug 'phase-2'
    }

    Invoke-Case 'Phase 8 F-003 required-output 重複宣告拒絕' -Reject -ErrorPattern 'C25 EvidencePackRequiredOutputInvalid' {
        $duplicatePath = Join-Path $phase7Root 'phase8-required-output-duplicate.md'
        $requiredLine = [regex]::Match($evidencePackContent, '(?m)^required-output:[^\r\n]*\r?\n').Value
        Write-Utf8NoBom -Path $duplicatePath -Content $evidencePackContent.Replace($requiredLine, $requiredLine + $requiredLine)
        Test-AdvisorEvidencePack -Path $duplicatePath -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug 'phase-2'
    }

    Invoke-Case 'Phase 8 F-003 required-output 冒號後換行接縮排 heading 拒絕' -Reject -ErrorPattern 'C25 EvidencePackRequiredOutputInvalid' {
        $wrappedPath = Join-Path $phase7Root 'phase8-required-output-wrapped-heading.md'
        $wrappedContent = [regex]::Replace($evidencePackContent, '(?m)^required-output:[ \t]*(?<value>[^\r\n]*)(?=\r?$)', ('required-output:' + [Environment]::NewLine + '  ${value}'))
        Assert-True ($wrappedContent -match '(?m)^required-output:\r?$' -and $wrappedContent -match '(?m)^  ## 中斷保全結論') 'F-003 fixture 未產生冒號後換行接縮排 heading 的宣告。'
        Write-Utf8NoBom -Path $wrappedPath -Content $wrappedContent
        Test-AdvisorEvidencePack -Path $wrappedPath -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug 'phase-2'
    }

    Invoke-Case 'Phase 8 A6 required-output 低層子標題保留於 body' {
        $required = @('## 推論')
        $message = @(
            '## 推論'
            '### question-001｜已完成'
            'question-001 content'
        ) -join [Environment]::NewLine
        $result = Test-RequiredOutputSections -Message $message -RequiredOutput $required
        $section = @($result.sections | Where-Object { $_.heading -ceq '## 推論' })[0]
        Assert-True ($result.valid -and $section.present -and $section.body_non_empty) ('低層子標題未保留於 required section body：' + ($result | ConvertTo-Json -Depth 8 -Compress))
    }

    Invoke-Case 'Phase 8 A6 required-output 同層 heading 使 body 維持空白' {
        $required = @('## 推論')
        $message = @(
            '## 推論'
            '## 未決問題'
            'unresolved'
        ) -join [Environment]::NewLine
        $result = Test-RequiredOutputSections -Message $message -RequiredOutput $required
        $section = @($result.sections | Where-Object { $_.heading -ceq '## 推論' })[0]
        Assert-True (-not $result.valid -and $result.missing -contains '## 推論' -and -not $section.body_non_empty) ('同層 heading 後的空 body 未被拒絕：' + ($result | ConvertTo-Json -Depth 8 -Compress))
    }

    Invoke-Case 'Phase 8 A6 T208 案例 1 finalMessage required-output 通過' {
        $message = @(
            '## 中斷保全結論'
            '已完成 question-001、question-002、question-003。'
            '## 證據支持'
            'T208 advisor finalMessage required-output fixture。'
            '## 推論'
            '### question-001｜已完成'
            'question-001 content'
            '### question-002｜已完成'
            'question-002 content'
            '### question-003｜已完成'
            'question-003 content'
            '## 未決問題'
            '無'
            '已確認結論：三個問題的 required-output 內容均已完成驗證。'
            '未完成單位：無'
            '證據位置：Test-DispatchRecoveryBinding.ps1'
        ) -join [Environment]::NewLine
        $required = @('## 中斷保全結論', '## 證據支持', '## 推論', '## 未決問題')
        $result = Test-RequiredOutputSections -Message $message -RequiredOutput $required
        $section = @($result.sections | Where-Object { $_.heading -ceq '## 推論' })[0]
        Assert-True ($result.valid -and $section.present -and $section.body_non_empty) ('T208 finalMessage required-output 驗證失敗：' + ($result | ConvertTo-Json -Depth 8 -Compress))
    }

    Invoke-Case 'Phase 8 evidence question ID、required-output 與 C25' {
        $units = @(Get-AdvisorEvidenceQuestionUnits -QuestionSection "question-001: first`r`nquestion-alpha: second`r`nrequired-output: ## A; ## B`r`noutput-rules: each question")
        Assert-True ($units.Count -eq 2 -and $units[0] -eq 'question-001' -and $units[1] -eq 'question-alpha') 'advisor question ID 順序或形式異常。'
        $invalidOutputPath = Join-Path $phase7Root 'phase8-invalid-output.md'
        $invalidOutput = $evidencePackContent -replace '(?m)^required-output:.*\r?\n', "required-output: 說明文字`r`n"
        Write-Utf8NoBom -Path $invalidOutputPath -Content ($invalidOutput + "`r`n")
        $caught = $null
        try { Test-AdvisorEvidencePack -Path $invalidOutputPath -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug 'phase-2' }
        catch { $caught = $_.Exception.Message }
        Assert-True ($null -ne $caught -and $caught.Contains('C25 EvidencePackRequiredOutputInvalid')) 'required-output 無效未回報 C25。'
    }

    Invoke-Case 'Phase 8 F-004 RequestedUnit 必須符合 evidence pack 順序' -Reject -ErrorPattern 'EvidencePackUnitOrderMismatch' {
        Get-DispatchUnitList -RequestedUnit @('question-002', 'question-001') -DispatchKind 'resource' -UnitKind 'advisor-evidence-question' -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -EvidencePackPath $phase2EvidencePackPath -EvidenceQuestionUnits @('question-001', 'question-002') -TargetPath @()
    }

    Invoke-Case 'Phase 8 F-004 RequestedUnit 不可跳過 evidence pack 問題' -Reject -ErrorPattern 'EvidencePackUnitOrderMismatch' {
        Get-DispatchUnitList -RequestedUnit @('question-001', 'question-003') -DispatchKind 'resource' -UnitKind 'advisor-evidence-question' -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -EvidencePackPath $phase2EvidencePackPath -EvidenceQuestionUnits @('question-001', 'question-002', 'question-003') -TargetPath @()
    }

    Invoke-Case 'Phase 8 F-004 ScopePlan selected prefix 與 deferred suffix' {
        $partitionSnapshot = $script:phase7LowSnapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $partitionActivation = Get-AdvisorActivationDecision -QuotaSnapshot $partitionSnapshot -EstimatePercent 24 -RequestSource 'user-explicit' -HasFreshObservations $true -ServiceRejected $false
        $partitionPlan = New-ScopePlan -DispatchSlug 'phase8-f004-partition' -DispatchKind 'resource' -TaskType 'advisor-consult' -RequestedProfile 'advisor' -SessionMode 'cold-start' -BeforeSnapshot $partitionSnapshot -CalibrationPath (Join-Path $phase7Root 'missing-phase8-f004-calibration.jsonl') -Units @('question-001', 'question-002') -UnitKind 'advisor-evidence-question' -Model $null -ModelEvidence $null -ReasoningEffortEvidence $null -ActivationDecision $partitionActivation
        $invalidPartition = $partitionPlan | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $invalidPartition.selected_units = @('question-002')
        $invalidPartition.deferred_units = @('question-001')
        Assert-True (-not (Test-ScopePlanCompleteness -ScopePlan $invalidPartition) -and -not (Test-ContinuationScopePlan -ScopePlan $invalidPartition -DispatchSlug 'phase8-f004-partition' -DispatchKind 'resource' -TaskType 'advisor-consult' -RequestedProfile 'advisor' -UnitKind 'advisor-evidence-question' -Units @('question-001', 'question-002'))) 'F-004 ScopePlan 未拒絕非 prefix／suffix 的 selected 與 deferred partition。'
    }

    Invoke-Case 'Phase 8 F-002 advisor safe point 必須宣告已完成單位' {
        $f2Snapshot = $script:phase7LowSnapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $f2Activation = Get-AdvisorActivationDecision -QuotaSnapshot $f2Snapshot -EstimatePercent 24 -RequestSource 'user-explicit' -HasFreshObservations $true -ServiceRejected $false
        $f2Plan = New-ScopePlan -DispatchSlug 'phase8-f002-partition' -DispatchKind 'resource' -TaskType 'advisor-consult' -RequestedProfile 'advisor' -SessionMode 'cold-start' -BeforeSnapshot $f2Snapshot -CalibrationPath (Join-Path $phase7Root 'missing-phase8-f002-calibration.jsonl') -Units @('question-001', 'question-002') -UnitKind 'advisor-evidence-question' -Model $null -ModelEvidence $null -ReasoningEffortEvidence $null -ActivationDecision $f2Activation
        $missingCompletedUnitsMessage = @(
            '## 中斷保全結論'
            '已確認結論：fixture conclusion'
            '證據位置：fixture.md:1'
            '實際覆蓋範圍：question-001'
        ) -join [Environment]::NewLine
        Assert-True (-not (Test-SafePointMessage -Message $missingCompletedUnitsMessage -TaskType 'advisor-consult')) 'F-002 缺少已完成單位欄位仍被視為 advisor safe point。'

        $missingReportPath = Join-Path $phase7Root 'advisor-consult-phase8-missing-completed.md'
        $missingReport = Write-AdvisorConsultReport -Path $missingReportPath -LineSlug 'line-a' -DispatchSlug 'phase8-advisor-missing-completed' -EvidencePackPath $phase2EvidencePackPath -EvidencePackSha256 'fixture-sha256' -EvidencePackLength 1 -FinalMessage $missingCompletedUnitsMessage -Status 'completed' -BudgetMonitor @() -RequiredOutputGate ([pscustomobject]@{ required = @(); present = @(); missing = @(); valid = $true }) -ScopePlan $f2Plan -InterruptionStatus ([ordered]@{ applied = $true; safePointPresent = $false })
        $missingReportContent = Get-Content -LiteralPath $missingReport -Raw -Encoding UTF8
        Assert-True ($missingReportContent.Contains('- completed: unknown') -and $missingReportContent.Contains('- incomplete: unknown')) 'F-002 缺少已完成單位時仍從訊息文字推論 completion partition。'

        $deferredMessage = @(
            '## 中斷保全結論'
            '已確認結論：fixture conclusion'
            '證據位置：fixture.md:1'
            '實際覆蓋範圍：question-001'
            '已完成單位：question-002'
        ) -join [Environment]::NewLine
        $deferredPartition = Get-AdvisorCompletionPartition -Message $deferredMessage -SelectedUnits @('question-001') -DeferredUnits @('question-002')
        Assert-True ($deferredPartition.status -eq 'invalid' -and $deferredPartition.completed_units[0] -eq 'unknown' -and $deferredPartition.incomplete_units[0] -eq 'unknown') 'F-002 未拒絕將 deferred unit 標記為已完成。'
    }

    Invoke-Case 'Phase 8 advisor 最長前綴與 report partition' {
        $zeroSnapshot = $script:phase7LowSnapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $zeroSnapshot.observations.primary.remaining_percent = 0
        $zeroSnapshot.observations.primary.used_percent = 100
        $zeroSnapshot.primary.remaining_percent = 0
        $zeroSnapshot.primary.used_percent = 100
        $activation = Get-AdvisorActivationDecision -QuotaSnapshot $zeroSnapshot -EstimatePercent 24 -RequestSource 'user-explicit' -HasFreshObservations $true -ServiceRejected $false
        $plan = New-ScopePlan -DispatchSlug 'phase8-advisor-partition' -DispatchKind 'resource' -TaskType 'advisor-consult' -RequestedProfile 'advisor' -SessionMode 'cold-start' -BeforeSnapshot $zeroSnapshot -CalibrationPath (Join-Path $phase7Root 'missing-phase8-calibration.jsonl') -Units @('question-001', 'question-002') -UnitKind 'advisor-evidence-question' -Model $null -ModelEvidence $null -ReasoningEffortEvidence $null -ActivationDecision $activation
        Assert-True ($plan.activation_mode -eq 'user-authorized' -and $plan.authorization_source -eq 'user-explicit' -and $plan.primary_reserve_percent -eq 0 -and $plan.primary_budget_percent -eq 0 -and $plan.minimum_unit_over_budget -and @($plan.selected_units).Count -eq 1 -and $plan.selected_units[0] -eq 'question-001' -and $plan.deferred_units[0] -eq 'question-002' -and $plan.stop_after_selected_units) 'advisor ScopePlan 未依宣告順序保留最小單位。'
        $reportPath = Join-Path $phase7Root 'advisor-consult-phase8.md'
        $finalMessage = "## 中斷保全結論`r`n已確認結論：question-001 completed`r`n證據位置：fixture.md:1`r`n實際覆蓋範圍：question-001`r`n已完成單位：question-001`r`n## 證據支持`r`nsupported`r`n## 推論`r`ninferred`r`n## 未決問題`r`nnone"
        $gate = [pscustomobject]@{ required = @('## 中斷保全結論', '## 證據支持', '## 推論', '## 未決問題'); present = @('## 中斷保全結論', '## 證據支持', '## 推論', '## 未決問題'); missing = @(); valid = $true }
        $written = Write-AdvisorConsultReport -Path $reportPath -LineSlug 'line-a' -DispatchSlug 'phase8-advisor-partition' -EvidencePackPath $phase2EvidencePackPath -EvidencePackSha256 'fixture-sha256' -EvidencePackLength 1 -FinalMessage $finalMessage -Status 'completed' -BudgetMonitor @() -RequiredOutputGate $gate -ScopePlan $plan -InterruptionStatus ([ordered]@{ applied = $true; safePointPresent = $true })
        $report = Get-Content -LiteralPath $written -Raw -Encoding UTF8
        Assert-True ($report.Contains('- activation-mode: user-authorized') -and $report.Contains('- authorization-source: user-explicit') -and $report.Contains('- completed: question-001') -and $report.Contains('- incomplete: question-002') -and $report.Contains('## Interruption status') -and $report.Contains('## Budget monitor')) 'advisor report 未保存 activation、units 或保全欄位。'
    }
}

Write-Output "TOTAL: $script:caseCount; FAILED: $script:failures; FIXTURES: $fixtureRoot"
if ($script:failures -gt 0) { exit 1 }
exit 0
