#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet(1, 2, 3, 4, 5, 6, 7, 8, 9)]
    [int]$Phase = 1,

    [switch]$Child,

    [AllowEmptyString()]
    [string]$ProbeDate,

    [AllowEmptyString()]
    [string]$ProbeEmpty,

    [AllowEmptyString()]
    [string]$ProbeWhitespace,

    [AllowEmptyString()]
    [string]$ProbeText,

    [AllowEmptyString()]
    [string]$FixtureBaseRootPath
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

function Invoke-Phase9Process {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HostPath,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [AllowNull()]
        [hashtable]$EnvironmentVariables
    )

    $argumentText = ($Arguments | ForEach-Object { ConvertTo-ProcessArgument -Value ([string]$_) }) -join ' '
    $process = New-Object System.Diagnostics.Process
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $HostPath
    $startInfo.Arguments = $argumentText
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    if ($null -ne $EnvironmentVariables) {
        foreach ($environmentEntry in Get-ChildItem Env:) {
            $startInfo.EnvironmentVariables[[string]$environmentEntry.Name] = [string]$environmentEntry.Value
        }
        if ([string]::Equals([IO.Path]::GetFileName($HostPath), 'powershell.exe', [StringComparison]::OrdinalIgnoreCase)) {
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
        foreach ($key in $EnvironmentVariables.Keys) {
            $startInfo.EnvironmentVariables[[string]$key] = [string]$EnvironmentVariables[$key]
        }
    }
    $process.StartInfo = $startInfo
    $start = [DateTimeOffset]::UtcNow
    try {
        if (-not $process.Start()) {
            throw 'Phase 9 外部程序 Process.Start() 回傳 false。'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            host_path = $HostPath
            arguments = @($Arguments)
            command = $HostPath + ' ' + $argumentText
            start_utc = $start.ToString('o')
            finish_utc = [DateTimeOffset]::UtcNow.ToString('o')
            exit_code = $process.ExitCode
            stdout = $stdoutTask.Result
            stderr = $stderrTask.Result
        }
    }
    catch {
        return [pscustomobject]@{
            host_path = $HostPath
            arguments = @($Arguments)
            command = $HostPath + ' ' + $argumentText
            start_utc = $start.ToString('o')
            finish_utc = [DateTimeOffset]::UtcNow.ToString('o')
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
        [string]$TextValue,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$FixtureBaseRootPath
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
    if (-not [string]::IsNullOrWhiteSpace($FixtureBaseRootPath)) {
        $arguments += @(
            '-FixtureBaseRootPath'
            $FixtureBaseRootPath
        )
    }
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
    if ($ChildResult.PSObject.Properties.Name -contains 'repository_status_before' -and
        -not [string]::Equals([string]$ChildResult.repository_status_before, [string]$ChildResult.repository_status_after, [StringComparison]::Ordinal)) {
        return [pscustomobject]@{ valid = $false; reason = 'repository git status --short changed' }
    }
    if ($ChildResult.PSObject.Properties.Name -contains 'repository_worktree_before' -and
        -not [string]::Equals([string]$ChildResult.repository_worktree_before, [string]$ChildResult.repository_worktree_after, [StringComparison]::Ordinal)) {
        return [pscustomobject]@{ valid = $false; reason = 'repository git worktree list changed' }
    }
    return [pscustomobject]@{ valid = $true; reason = 'child passed ' + $summaryMatch.Groups['total'].Value + ' cases' }
}

function Invoke-Phase9RepositoryGitCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $gitOutput = & git -C $RepositoryRoot @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $outputLines = @($gitOutput | ForEach-Object { [string]$_ })
    $outputText = $outputLines -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        throw ('Phase 9 repository git command failed: git -C "' + $RepositoryRoot + '" ' + ($Arguments -join ' ') + [Environment]::NewLine + $outputText)
    }
    return $outputText
}

function Get-Phase9RepositoryBoundarySnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    return [ordered]@{
        git_status_short = Invoke-Phase9RepositoryGitCommand -RepositoryRoot $RepositoryRoot -Arguments @('status', '--short')
        git_worktree_list = Invoke-Phase9RepositoryGitCommand -RepositoryRoot $RepositoryRoot -Arguments @('worktree', 'list')
    }
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
        $repositoryBoundaryBefore = $null
        if ($Phase -eq 9) {
            $repositoryBoundaryBefore = Get-Phase9RepositoryBoundarySnapshot -RepositoryRoot $root
        }
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
            if ($Phase -eq 9) {
                $repositoryBoundaryAfter = Get-Phase9RepositoryBoundarySnapshot -RepositoryRoot $root
                $missing | Add-Member -MemberType NoteProperty -Name repository_status_before -Value ([string]$repositoryBoundaryBefore.git_status_short)
                $missing | Add-Member -MemberType NoteProperty -Name repository_status_after -Value ([string]$repositoryBoundaryAfter.git_status_short)
                $missing | Add-Member -MemberType NoteProperty -Name repository_worktree_before -Value ([string]$repositoryBoundaryBefore.git_worktree_list)
                $missing | Add-Member -MemberType NoteProperty -Name repository_worktree_after -Value ([string]$repositoryBoundaryAfter.git_worktree_list)
            }
            $aggregateResults.Add($missing)
            $aggregateFailed = $true
            continue
        }
        $hostPath = if (-not [string]::IsNullOrWhiteSpace($command.Source)) { $command.Source } else { $command.Path }
        $childResult = Invoke-TestChildProcess -HostPath $hostPath -HostLabel $hostDefinition.Label -PhaseNumber $Phase -ScriptPath $scriptPathValue -DateValue $probeDateValue -EmptyValue $probeEmptyValue -WhitespaceValue $probeWhitespaceValue -TextValue $probeTextValue -FixtureBaseRootPath $FixtureBaseRootPath
        if ($Phase -eq 9) {
            $repositoryBoundaryAfter = Get-Phase9RepositoryBoundarySnapshot -RepositoryRoot $root
            $childResult | Add-Member -MemberType NoteProperty -Name repository_status_before -Value ([string]$repositoryBoundaryBefore.git_status_short)
            $childResult | Add-Member -MemberType NoteProperty -Name repository_status_after -Value ([string]$repositoryBoundaryAfter.git_status_short)
            $childResult | Add-Member -MemberType NoteProperty -Name repository_worktree_before -Value ([string]$repositoryBoundaryBefore.git_worktree_list)
            $childResult | Add-Member -MemberType NoteProperty -Name repository_worktree_after -Value ([string]$repositoryBoundaryAfter.git_worktree_list)
        }
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
        if ($Phase -eq 9 -and $childResult.PSObject.Properties.Name -contains 'repository_status_before') {
            Write-Output 'REPOSITORY_GIT_STATUS_BEFORE_BEGIN'
            Write-Output ([string]$childResult.repository_status_before)
            Write-Output 'REPOSITORY_GIT_STATUS_BEFORE_END'
            Write-Output 'REPOSITORY_GIT_WORKTREE_BEFORE_BEGIN'
            Write-Output ([string]$childResult.repository_worktree_before)
            Write-Output 'REPOSITORY_GIT_WORKTREE_BEFORE_END'
            Write-Output 'REPOSITORY_GIT_STATUS_AFTER_BEGIN'
            Write-Output ([string]$childResult.repository_status_after)
            Write-Output 'REPOSITORY_GIT_STATUS_AFTER_END'
            Write-Output 'REPOSITORY_GIT_WORKTREE_AFTER_BEGIN'
            Write-Output ([string]$childResult.repository_worktree_after)
            Write-Output 'REPOSITORY_GIT_WORKTREE_AFTER_END'
        }
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

$fixtureBaseRoot = $root
if (-not [string]::IsNullOrWhiteSpace($FixtureBaseRootPath)) {
    if (-not (Test-Path -LiteralPath $FixtureBaseRootPath -PathType Container)) {
        throw ('指定的 fixture root 不存在：' + $FixtureBaseRootPath)
    }
    $fixtureBaseRoot = [IO.Path]::GetFullPath($FixtureBaseRootPath)
}
$fixtureRoot = Join-Path $fixtureBaseRoot ('.local/ai-sessions/scratch/r-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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

function Test-ByteArrayEqual {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [byte[]]$Left,

        [AllowNull()]
        [byte[]]$Right
    )

    if ($null -eq $Left -or $null -eq $Right) {
        return $null -eq $Left -and $null -eq $Right
    }
    if ($Left.Length -ne $Right.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) {
            return $false
        }
    }
    return $true
}

function Write-Phase9Evidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [AllowNull()]
        [object]$Value
    )

    [Console]::WriteLine('EVIDENCE_BEGIN: ' + $Label)
    [Console]::WriteLine((ConvertTo-Json -InputObject $Value -Depth 80))
    [Console]::WriteLine('EVIDENCE_END: ' + $Label)
}

function Assert-Phase9RepositoryGitStatusUnchanged {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Before,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$After
    )

    if (-not [string]::Equals($Before, $After, [StringComparison]::Ordinal)) {
        throw ('Phase 9 git status --short 前後不一致。' + [Environment]::NewLine + 'BEFORE:' + [Environment]::NewLine + $Before + [Environment]::NewLine + 'AFTER:' + [Environment]::NewLine + $After)
    }
    return [ordered]@{
        result = 'PASS'
        before = $Before
        after = $After
    }
}

function Invoke-Phase9GitCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $gitOutput = & git -C $RepositoryRoot @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $outputLines = @($gitOutput | ForEach-Object { [string]$_ })
    return [pscustomobject]@{
        command = 'git -C "' + $RepositoryRoot + '" ' + ($Arguments -join ' ')
        exit_code = $exitCode
        output = ($outputLines -join [Environment]::NewLine)
    }
}

function Assert-Phase9GitCommandSucceeded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Result
    )

    if ([int]$Result.exit_code -ne 0) {
        throw ('Git 命令失敗：' + [string]$Result.command + [Environment]::NewLine + [string]$Result.output)
    }
}

function ConvertTo-Phase9ComparablePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    while ($fullPath.Length -gt 3 -and ($fullPath.EndsWith('\') -or $fullPath.EndsWith('/'))) {
        $fullPath = $fullPath.Substring(0, $fullPath.Length - 1)
    }
    return $fullPath
}

function Test-Phase9GitWorktreeListed {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$WorktreeList,

        [Parameter(Mandatory)]
        [string]$WorktreePath
    )

    $expectedPath = ConvertTo-Phase9ComparablePath -Path $WorktreePath
    foreach ($line in ($WorktreeList -split "`r?`n")) {
        if (-not $line.StartsWith('worktree ')) {
            continue
        }
        $candidatePath = $line.Substring('worktree '.Length).Trim()
        if ([string]::IsNullOrWhiteSpace($candidatePath)) {
            continue
        }
        if ([string]::Equals((ConvertTo-Phase9ComparablePath -Path $candidatePath), $expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-Phase9GitWorktreeList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    $result = Invoke-Phase9GitCommand -RepositoryRoot $RepositoryRoot -Arguments @('worktree', 'list', '--porcelain')
    Assert-Phase9GitCommandSucceeded -Result $result
    return [string]$result.output
}

function Initialize-Phase9IsolatedGitRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$SourceScriptPath,

        [Parameter(Mandatory)]
        [string]$TargetRelativePath
    )

    $targetPath = Join-Path $SourceRoot $TargetRelativePath
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $targetPath) -Force
    $null = Copy-Item -LiteralPath $SourceScriptPath -Destination $targetPath -Force

    $initResult = Invoke-Phase9GitCommand -RepositoryRoot $SourceRoot -Arguments @('init')
    Assert-Phase9GitCommandSucceeded -Result $initResult
    $null = Invoke-Phase9GitCommand -RepositoryRoot $SourceRoot -Arguments @('config', 'user.name', 'Phase 9 Fixture')
    $null = Invoke-Phase9GitCommand -RepositoryRoot $SourceRoot -Arguments @('config', 'user.email', 'phase9-fixture@example.invalid')
    $addResult = Invoke-Phase9GitCommand -RepositoryRoot $SourceRoot -Arguments @('add', '--all')
    Assert-Phase9GitCommandSucceeded -Result $addResult
    $forceHistoryResult = Invoke-Phase9GitCommand -RepositoryRoot $SourceRoot -Arguments @('add', '--force', '--', '.local/ai-sessions/history')
    Assert-Phase9GitCommandSucceeded -Result $forceHistoryResult
    $commitResult = Invoke-Phase9GitCommand -RepositoryRoot $SourceRoot -Arguments @('commit', '-m', 'Initialize isolated Phase 9 source repository')
    Assert-Phase9GitCommandSucceeded -Result $commitResult
}

function Remove-Phase9GitWorktree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$DispatchRoot
    )

    $beforeList = Get-Phase9GitWorktreeList -RepositoryRoot $SourceRoot
    $registeredBefore = Test-Phase9GitWorktreeListed -WorktreeList $beforeList -WorktreePath $DispatchRoot
    $pathExistedBefore = Test-Path -LiteralPath $DispatchRoot -PathType Container
    $removeResult = $null
    if ($registeredBefore) {
        $removeResult = Invoke-Phase9GitCommand -RepositoryRoot $SourceRoot -Arguments @('worktree', 'remove', '--force', '--', $DispatchRoot)
    }
    $afterList = Get-Phase9GitWorktreeList -RepositoryRoot $SourceRoot
    $registeredAfter = Test-Phase9GitWorktreeListed -WorktreeList $afterList -WorktreePath $DispatchRoot
    $pathExistsAfter = Test-Path -LiteralPath $DispatchRoot -PathType Container
    return [ordered]@{
        source_root = $SourceRoot
        dispatch_root = $DispatchRoot
        path_existed_before = $pathExistedBefore
        registered_before = $registeredBefore
        remove_result = $removeResult
        registered_after = $registeredAfter
        path_exists_after = $pathExistsAfter
        removed = (-not $registeredAfter -and -not $pathExistsAfter)
        worktree_list_before = $beforeList
        worktree_list_after = $afterList
    }
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

$phase9ProductionFunctionDefinitions = @{}
foreach ($functionName in @('Invoke-Preflight', 'Invoke-Prepare', 'Invoke-Start', 'Add-CalibrationObservation', 'Get-DispatchRunRecordStartClassification', 'Get-WorktreeAclGate', 'New-ContinuationScopePlanSubset', 'New-ScopePlan', 'Test-ContinuationScopePlan', 'Test-ScopePlanHashRecord')) {
    $productionCommand = Get-Command -Name $functionName -CommandType Function -ErrorAction Stop
    $phase9ProductionFunctionDefinitions[$functionName] = $productionCommand.ScriptBlock
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
$script:profileIsolationProbe = $false
$script:profileIsolationCapturedArguments = @()
$script:profileIsolationCodexHome = $null
$script:profileIsolationRolloutPath = $null
$script:profileIsolationSelectedProfile = $null
$script:profileIsolationSelectedConfigPath = $null
$script:profileIsolationSelectedModel = $null
$script:profileIsolationSelectedEffort = $null
$script:profileIsolationLauncherPath = $null
$script:InvocationBoundParameters = [ordered]@{}
$script:RequestContext = $null
$script:RequestPrepareArtifacts = @()
$script:AddDirectoryExplicit = $false
$script:SearchExplicit = $false
$script:CodexParentOptionExplicit = $false
$script:ProfileExplicit = $false
$script:phase9RealDispatchGitSourceRoot = $null
$script:phase9RealDispatchGitRoot = $null
$script:phase9RealDispatchGitInitialized = $false
function Get-PidCheckResult { param($SourceRoot, $LineSlug, $WriteMode) return $script:pidResult }
function Get-WorktreeAclGate {
    param($SourceRoot, $ExecutionRoot, $WriteMode, $ContinuationRecord)
    if ([string]::Equals([string]$SourceRoot, [string]$ExecutionRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return [ordered]@{ status = 'not-applicable'; rejection_code = $null; source = @{}; dispatch = @{}; residue = @(); raw_residue = @(); accepted_sandbox_entries = @(); allowed_sandbox_entries = @(); sandbox_evidence_status = 'not-applicable'; write_mode = $WriteMode }
    }
    if ($script:aclFixtureStatus -eq 'residue') {
        return [ordered]@{ status = 'residue'; rejection_code = 'WorktreeAclResidue'; source = @{}; dispatch = @{}; residue = @([ordered]@{ identity = 'fixture'; rights = 'Modify' }); raw_residue = @([ordered]@{ identity = 'fixture'; rights = 'Modify' }); accepted_sandbox_entries = @(); allowed_sandbox_entries = @(); sandbox_evidence_status = 'rejected'; write_mode = $WriteMode }
    }
    if ($script:aclFixtureStatus -eq 'unknown') {
        return [ordered]@{ status = 'unknown'; rejection_code = 'WorktreeAclUnknown'; source = @{}; dispatch = @{}; residue = @(); raw_residue = @(); accepted_sandbox_entries = @(); allowed_sandbox_entries = @(); sandbox_evidence_status = 'unknown'; write_mode = $WriteMode }
    }
    return [ordered]@{ status = 'clean'; rejection_code = $null; source = @{}; dispatch = @{}; residue = @(); raw_residue = @(); accepted_sandbox_entries = @(); allowed_sandbox_entries = @(); sandbox_evidence_status = 'none'; write_mode = $WriteMode }
}
function Get-CodexExecutablePath { param($ConfiguredPath) return 'fixture-codex' }
function Get-OrCreateQuotaSnapshot {
    param($Path, $CodexHome, $HistoryRoot, $Purpose, [switch]$Required)
    if ($script:quotaFixtureFailure) { throw 'quota fixture failure' }
    if (-not [string]::IsNullOrWhiteSpace($script:quotaSnapshotPathOverride)) {
        if (-not (Test-Path -LiteralPath $script:quotaSnapshotPathOverride -PathType Leaf)) {
            $quotaParent = Split-Path -Parent $script:quotaSnapshotPathOverride
            New-Item -ItemType Directory -Path $quotaParent -Force | Out-Null
            $null = New-Phase8QuotaSnapshot -Path $script:quotaSnapshotPathOverride -PrimaryRemainingPercent 80
        }
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
    param($PromptPath, $HistoryRoot, $Timestamp, $Directive, $OutputPath)
    $targetPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) { $PromptPath } else { $OutputPath }
    if ($script:advisorStartPromptMode -or -not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $content = Read-DispatchUtf8Text -Path $PromptPath
        $content = $content.TrimEnd() + [Environment]::NewLine + (@($Directive) -join [Environment]::NewLine) + [Environment]::NewLine
        Write-Utf8NoBom -Path $targetPath -Content $content
    }
    return $targetPath
}
function New-CodexLauncher {
    param($CodexExecutable, $CodexArguments, $PromptPath, $EventPath, $ErrorPath, $HistoryRoot, $LauncherPath, $ExitSidecarPath, $LineSlug, $DispatchSlug, $RunId)
    if ($script:profileIsolationProbe) {
        $script:profileIsolationCapturedArguments = @($CodexArguments)
        $script:profileIsolationLauncherPath = $LauncherPath
        Write-Utf8NoBom -Path $ErrorPath -Content ''
        Write-Utf8NoBom -Path $LauncherPath -Content 'fixture launcher'
        $lastMessageIndex = [Array]::IndexOf([string[]]$CodexArguments, '--output-last-message')
        if ($lastMessageIndex -ge 0 -and $lastMessageIndex + 1 -lt @($CodexArguments).Count) {
            Write-Utf8NoBom -Path $CodexArguments[$lastMessageIndex + 1] -Content 'default profile isolation fixture'
        }
    }
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
        if ($script:profileIsolationProbe) {
            $actualArguments = @($script:profileIsolationCapturedArguments | ForEach-Object { [string]$_ })
            $profileIndex = [Array]::IndexOf([string[]]$actualArguments, '--profile')
            Assert-True ($profileIndex -ge 0 -and $profileIndex + 1 -lt $actualArguments.Count) 'profile isolation fixture 未從實際 launcher 引數取得 --profile。'
            $selectedProfile = $actualArguments[$profileIndex + 1]
            $selectedConfigPath = Resolve-ProfileConfigPath -CodexHome $script:profileIsolationCodexHome -Profile $selectedProfile
            Assert-True (-not [string]::IsNullOrWhiteSpace($selectedConfigPath)) 'profile isolation fixture 無法依實際 CodexHome 與 profile 解析設定檔。'
            $selectedEvidence = Read-ProfileModelEvidence -ConfigPath $selectedConfigPath -Profile $selectedProfile
            $selectedModel = [string](Get-DispatchEvidenceValue -Evidence $selectedEvidence.model)
            $selectedEffort = [string](Get-DispatchEvidenceValue -Evidence $selectedEvidence.reasoning_effort)
            Assert-True (-not [string]::IsNullOrWhiteSpace($selectedModel) -and -not [string]::IsNullOrWhiteSpace($selectedEffort)) 'profile isolation fixture 無法從實際選用的設定檔取得 model 與 reasoning effort。'
            $script:profileIsolationSelectedProfile = $selectedProfile
            $script:profileIsolationSelectedConfigPath = $selectedConfigPath
            $script:profileIsolationSelectedModel = $selectedModel
            $script:profileIsolationSelectedEffort = $selectedEffort
            $rolloutLines = @(
                ([ordered]@{ type = 'session_meta'; payload = [ordered]@{ session_id = $script:testThread } } | ConvertTo-Json -Compress -Depth 10)
                ([ordered]@{ type = 'turn_context'; timestamp = [DateTimeOffset]::UtcNow.AddSeconds(1).ToString('o'); payload = [ordered]@{ model = $selectedModel; effort = $selectedEffort } } | ConvertTo-Json -Compress -Depth 10)
            )
            Write-Utf8NoBom -Path $script:profileIsolationRolloutPath -Content (($rolloutLines -join "`r`n") + "`r`n")
            return $true
        }
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
function Invoke-GitCommand {
    param($WorkingDirectory, $Arguments, $StandardInput, [switch]$AllowFailure)
    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'fatal: not a git repository' }
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
    if ($script:relayFailure) { return [pscustomobject]@{ threadId = ''; existingThreadId = ''; ready = $false; eventObserved = $false; timeoutSeconds = 5; source = 'fixture'; timedOut = $true } }
    return [pscustomobject]@{ threadId = $script:testThread; existingThreadId = ''; ready = $true; eventObserved = $true; timeoutSeconds = 5; source = 'fixture'; timedOut = $false }
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
    $scopeWitnessPath = Get-ScopePlanHashRecordPath -SourceHistoryRoot $history -DispatchSlug $Dispatch
    $scopePlanRootRunId = $null
    if (Test-Path -LiteralPath $scopeWitnessPath -PathType Leaf) {
        $existingScopeWitness = Get-Content -LiteralPath $scopeWitnessPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $scopePlanRootRunId = [string](Get-DispatchJsonProperty -Object $existingScopeWitness -Name 'root_run_id')
    }
    if ([string]::IsNullOrWhiteSpace($scopePlanRootRunId) -and $null -ne $Previous) {
        $scopePlanRootRunId = [string]$Previous.scope_plan_root_run_id
    }
    if ([string]::IsNullOrWhiteSpace($scopePlanRootRunId)) {
        $scopePlanRootRunId = $id
    }
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
        scope_plan_parent_path = $null; scope_plan_parent_sha256 = $null; scope_plan_parent_run_id = $null
        scope_plan_root_run_id = $scopePlanRootRunId
        scope_plan_selection = 'root'
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
    $null = Write-ScopePlanHashRecordIfMissing -SourceHistoryRoot $history -DispatchSlug $Dispatch -LineSlug $Line -ScopePlanPath $scope -RootRunId $scopePlanRootRunId
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
    $manifest = New-ReviewerManifest
    Write-ReviewerFixture -Path $reviewerPath -Manifest $manifest
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
Write-Utf8NoBom (Join-Path $startCodexHome 'default.config.toml') "model = 'fixture-model'
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
function Invoke-GitCommand {
    param($WorkingDirectory, $Arguments, $StandardInput, [switch]$AllowFailure)
    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'fatal: not a git repository' }
}
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
    $defaultProfilePath = Join-Path $profileFixtureRoot 'default.config.toml'
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
    Write-Utf8NoBom -Path (Join-Path $phase3MismatchHome 'default.config.toml') -Content "model = 'other-model'
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
    $phase3ProfileConfigPath = Join-Path $phase3ProfileHome 'default.config.toml'
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
        $realGitRoots = @($script:phase9RealDispatchGitSourceRoot, $script:phase9RealDispatchGitRoot) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
        $isRealDispatchGit = @($realGitRoots | Where-Object { [string]::Equals([IO.Path]::GetFullPath($WorkingDirectory), [IO.Path]::GetFullPath([string]$_), [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if ($Arguments[0] -eq '-C' -and $Arguments.Count -ge 2 -and @($realGitRoots | Where-Object { [string]::Equals([IO.Path]::GetFullPath($Arguments[1]), [IO.Path]::GetFullPath([string]$_), [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
            $isRealDispatchGit = $true
        }
        if ($isRealDispatchGit) {
            if ($Arguments[0] -eq '-C' -and $Arguments.Count -ge 4 -and $Arguments[2] -eq 'rev-parse' -and $Arguments[3] -eq '--is-inside-work-tree') {
                if ($script:phase9RealDispatchGitInitialized) {
                    return [pscustomobject]@{ ExitCode = 0; StdOut = 'true'; StdErr = '' }
                }
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'fatal: not a git repository' }
            }
            elseif ($Arguments[0] -eq 'init') {
                $script:phase9RealDispatchGitInitialized = $true
            }
            elseif ($Arguments[0] -eq 'rev-parse') {
                $output = 'c' * 40
            }
            elseif ($Arguments[0] -eq 'ls-files' -and $Arguments -contains '--error-unmatch') {
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'error: pathspec did not match any file' }
            }
            elseif ($Arguments[0] -eq 'check-ignore' -and $Arguments -contains '--quiet') {
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = '' }
            }
            elseif ($Arguments -contains 'worktree') {
                $worktreeIndex = [Array]::IndexOf([string[]]$Arguments, 'worktree')
                $worktreePath = [string]$Arguments[$worktreeIndex + 3]
                New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
                New-Item -ItemType Directory -Path (Join-Path $worktreePath '.local\ai-sessions\history\line-real') -Force | Out-Null
                $sourcePromptPath = Join-Path $script:phase9RealDispatchGitSourceRoot 'dispatch-prompt.md'
                if (Test-Path -LiteralPath $sourcePromptPath -PathType Leaf) {
                    Copy-Item -LiteralPath $sourcePromptPath -Destination (Join-Path $worktreePath 'dispatch-prompt.md') -Force
                }
            }
            return [pscustomobject]@{ ExitCode = 0; StdOut = $output; StdErr = '' }
        }
        if ($Arguments[0] -eq '-C' -and $Arguments.Count -ge 4 -and $Arguments[2] -eq 'rev-parse' -and $Arguments[3] -eq '--is-inside-work-tree') {
            if ([string]::Equals([IO.Path]::GetFullPath($Arguments[1]), [IO.Path]::GetFullPath($root), [StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{ ExitCode = 0; StdOut = 'true'; StdErr = '' }
            }
            return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'fatal: not a git repository' }
        }
        elseif ($Arguments[0] -eq 'ls-files' -and $Arguments -contains '--error-unmatch') {
            $relative = [string]$Arguments[$Arguments.Count - 1]
            if ([string]::Equals([IO.Path]::GetFullPath($WorkingDirectory), [IO.Path]::GetFullPath($root), [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath (Join-Path $WorkingDirectory $relative) -PathType Leaf)) {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $relative + "`n"; StdErr = '' }
            }
            return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'error: pathspec did not match any file' }
        }
        elseif ($Arguments[0] -eq 'check-ignore' -and $Arguments -contains '--quiet') {
            return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = '' }
        }
        elseif ($Arguments[0] -eq 'ls-tree') {
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

    $phase4ReportLineRoot = Join-Path $fixtureRoot '.local/ai-sessions/report/line-a'
    New-Item -ItemType Directory -Path $phase4ReportLineRoot -Force | Out-Null
    $phase4ReportSourcePath = Join-Path $phase4ReportLineRoot 'phase4-report-input.txt'
    $phase4ReportSourceContent = 'phase4 report source content'
    Write-Utf8NoBom -Path $phase4ReportSourcePath -Content $phase4ReportSourceContent
    $phase4ReportSourceHash = Get-FileSha256 -Path $phase4ReportSourcePath
    $phase4ReportDestinationPath = Join-Path $phase6DispatchRoot '.local/ai-sessions/handoff/line-a/phase4-report-input.txt'
    $phase4ReportResultPath = Join-Path $phase6DispatchRoot '.local/ai-sessions/history/line-a/phase4-report-result.json'

    Invoke-Case 'Phase 4 T015 Prepare 接受同線 report source' {
        Set-Phase6PrepareRequest -Dispatch 'phase4-report-source' -Source $phase4ReportSourcePath -Destination $phase4ReportDestinationPath -Hash $phase4ReportSourceHash -ResultPath $phase4ReportResultPath | Out-Null
        $prepared = Invoke-Prepare
        $binding = Resolve-PrepareResultBinding -Path $prepared.prepareResultPath -SourceRoot $fixtureRoot -ExecutionRoot $phase6DispatchRoot -LineSlug 'line-a' -DispatchSlug 'phase4-report-source' -ExpectedSha256 $prepared.prepareResultSha256
        Assert-True ($prepared.status -eq 'Prepared' -and $binding.Status -eq 'Prepared' -and $binding.Artifacts.Count -eq 1) 'report source Prepare 未完成 Prepared binding。'
        Assert-True ($binding.Artifacts[0].destination_root -eq 'dispatch-line-root' -and (Get-Content -LiteralPath $phase4ReportDestinationPath -Raw -Encoding UTF8) -eq $phase4ReportSourceContent) 'report source artifact 未寫入 executionRoot。'
        Assert-True ($binding.Document.artifacts[0].source -eq (Resolve-AbsolutePath -Path $phase4ReportSourcePath)) 'Prepared result 未保留 report source 絕對路徑。'
        Set-Phase6PrepareRequest -Dispatch 'phase6-prepare' -Source $phase6SourcePath -Destination $phase6DestinationPath -Hash $phase6SourceHash -ResultPath $phase6PrepareResultPath | Out-Null
    }

    $phase4ReportOutsidePath = Join-Path $fixtureRoot 'phase4-outside-report.txt'
    Write-Utf8NoBom -Path $phase4ReportOutsidePath -Content 'outside report source'
    Invoke-Case 'Phase 4 T015 Prepare report source boundary 拒絕' -Reject -ErrorPattern 'PrepareArtifactMismatch|handoff/report line roots' {
        Set-Phase6PrepareRequest -Dispatch 'phase4-report-boundary' -Source $phase4ReportOutsidePath -Destination (Join-Path $phase6DispatchRoot '.local/ai-sessions/handoff/line-a/phase4-report-boundary.txt') -Hash $phase4ReportSourceHash -ResultPath (Join-Path $phase6DispatchRoot '.local/ai-sessions/history/line-a/phase4-report-boundary-result.json') | Out-Null
        Invoke-Prepare
    }

    Invoke-Case 'Phase 4 T015 report source reverse mutant 被辨識' {
        $productionText = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
        $fixedSourceRootCall = '$sourceRoot = Resolve-PrepareSourceRoot -Path $sourcePath -SourceRoots @($rootInfo.SourceLineRoots)'
        $oldSourceRootCall = '$sourceRoot = Resolve-PrepareSourceRoot -Path $sourcePath -SourceRoots @($rootInfo.SourceLineRoot)'
        Assert-True $productionText.Contains($fixedSourceRootCall) 'T015 reverse 找不到 SourceLineRoots production call。'
        $mutantText = $productionText.Replace($fixedSourceRootCall, $oldSourceRootCall)
        Assert-True ($mutantText -ne $productionText) 'T015 reverse mutant 未移除 report source root。'
        $mutantSlug = 'phase4-report-mutant'
        $mutantDispatchRoot = Join-Path $fixtureRoot ('.local/ai-sessions/worktrees/' + $mutantSlug)
        New-Item -ItemType Directory -Path $mutantDispatchRoot -Force | Out-Null
        $mutantDestination = Join-Path $mutantDispatchRoot '.local/ai-sessions/handoff/line-a/phase4-report-mutant.txt'
        $mutantResult = Join-Path $mutantDispatchRoot '.local/ai-sessions/history/line-a/phase4-report-mutant-result.json'
        $mutantRequestPath = Join-Path $fixtureRoot 'phase4-report-mutant-request.json'
        $mutantRequest = [ordered]@{
            schema = 'ai-sessions.dispatch-request.v1'
            operation = 'Prepare'
            line_slug = 'line-a'
            dispatch_slug = $mutantSlug
            prepare_artifacts = @([ordered]@{
                    source = $phase4ReportSourcePath
                    destination = $mutantDestination
                    sha256 = $phase4ReportSourceHash
                    purpose = 'T015 reverse mutant'
                })
        }
        Write-Utf8NoBom -Path $mutantRequestPath -Content (($mutantRequest | ConvertTo-Json -Depth 10) + "`n")
        $mutantPath = Join-Path $fixtureRoot 'phase4-report-source-mutant-Invoke-CodexDispatch.ps1'
        [IO.File]::WriteAllText($mutantPath, $mutantText, (New-Object Text.UTF8Encoding($true)))
        $mutantRun = Invoke-Phase9Process -HostPath ((Get-Command powershell.exe -ErrorAction Stop).Source) -Arguments @(
            '-NoProfile'
            '-File'
            $mutantPath
            '-Operation'
            'Prepare'
            '-RequestPath'
            $mutantRequestPath
            '-SourceRoot'
            $fixtureRoot
            '-ExecutionRoot'
            $mutantDispatchRoot
            '-DispatchRoot'
            $mutantDispatchRoot
            '-LineSlug'
            'line-a'
            '-DispatchSlug'
            $mutantSlug
            '-ResultPath'
            $mutantResult
        ) -WorkingDirectory $root -EnvironmentVariables @{}
        Assert-True ([int]$mutantRun.exit_code -ne 0 -and ([string]$mutantRun.stdout + [string]$mutantRun.stderr) -match 'PrepareArtifactMismatch|handoff/report line roots') ('T015 reverse mutant 未拒絕 report source：' + [string]$mutantRun.stdout + [string]$mutantRun.stderr)
        Assert-True (-not (Test-Path -LiteralPath $mutantDestination -PathType Leaf)) 'T015 reverse mutant 不應寫入 report source artifact。'
    }

    Invoke-Case 'Phase 4 T016 Prepare failure rollback 與 reverse mutant' {
        $rollbackSourceOne = Join-Path $phase4LineRoot 'phase4-rollback-one.txt'
        $rollbackSourceTwo = Join-Path $phase4LineRoot 'phase4-rollback-two.txt'
        Write-Utf8NoBom -Path $rollbackSourceOne -Content 'rollback source one'
        Write-Utf8NoBom -Path $rollbackSourceTwo -Content 'rollback source two'
        $rollbackProductionText = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
        $fixedFinalHashCall = '$finalHash = Get-FileSha256 -Path $destinationPath'
        $forcedFailureFinalHash = '$finalHash = (''0'' * 64)'
        Assert-True $rollbackProductionText.Contains($fixedFinalHashCall) 'T016 reverse 找不到 final hash production call。'
        $failureProbeText = $rollbackProductionText.Replace($fixedFinalHashCall, $forcedFailureFinalHash)
        $cleanupLoop = @(
            '        foreach ($committedPath in @($committedPaths.ToArray())) {',
            '            if (Test-Path -LiteralPath $committedPath) {',
            '                Remove-Item -LiteralPath $committedPath -Force -ErrorAction SilentlyContinue',
            '            }',
            '        }'
        ) -join "`r`n"
        $mutantCleanupLoop = @(
            '        foreach ($committedPath in @($committedPaths.ToArray())) {',
            '        }'
        ) -join "`r`n"
        Assert-True $failureProbeText.Contains($cleanupLoop) 'T016 reverse 找不到 committed path rollback cleanup。'
        $rollbackMutantText = $failureProbeText.Replace($cleanupLoop, $mutantCleanupLoop)
        Assert-True ($rollbackMutantText -ne $failureProbeText) 'T016 reverse mutant 未移除 rollback cleanup。'

        $invokeFailureProbe = {
            param([Parameter(Mandatory)][string]$ScriptText, [Parameter(Mandatory)][string]$Slug, [Parameter(Mandatory)][string]$Label)
            $caseDispatchRoot = Join-Path $fixtureRoot ('w-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            New-Item -ItemType Directory -Path $caseDispatchRoot -Force | Out-Null
            $caseRequestPath = Join-Path $fixtureRoot ($Label + '-request.json')
            $caseResultPath = Join-Path $caseDispatchRoot ('.local/ai-sessions/history/line-a/' + $Label + '-result.json')
            $caseDestinationOne = Join-Path $caseDispatchRoot ('.local/ai-sessions/handoff/line-a/' + $Label + '-one.txt')
            $caseDestinationTwo = Join-Path $caseDispatchRoot ('.local/ai-sessions/handoff/line-a/' + $Label + '-two.txt')
            $caseRequest = [ordered]@{
                schema = 'ai-sessions.dispatch-request.v1'
                operation = 'Prepare'
                line_slug = 'line-a'
                dispatch_slug = $Slug
                prepare_artifacts = @(
                    [ordered]@{
                        source = $rollbackSourceOne
                        destination = $caseDestinationOne
                        sha256 = Get-FileSha256 -Path $rollbackSourceOne
                        purpose = 'T016 first artifact'
                    }
                    [ordered]@{
                        source = $rollbackSourceTwo
                        destination = $caseDestinationTwo
                        sha256 = Get-FileSha256 -Path $rollbackSourceTwo
                        purpose = 'T016 second artifact'
                    }
                )
            }
            Write-Utf8NoBom -Path $caseRequestPath -Content (($caseRequest | ConvertTo-Json -Depth 12) + "`n")
            $caseScriptPath = Join-Path $fixtureRoot ($Label + '-Invoke-CodexDispatch.ps1')
            [IO.File]::WriteAllText($caseScriptPath, $ScriptText, (New-Object Text.UTF8Encoding($true)))
            $caseRun = Invoke-Phase9Process -HostPath ((Get-Command powershell.exe -ErrorAction Stop).Source) -Arguments @(
                '-NoProfile'
                '-File'
                $caseScriptPath
                '-Operation'
                'Prepare'
                '-RequestPath'
                $caseRequestPath
                '-SourceRoot'
                $fixtureRoot
                '-ExecutionRoot'
                $caseDispatchRoot
                '-DispatchRoot'
                $caseDispatchRoot
                '-LineSlug'
                'line-a'
                '-DispatchSlug'
                $Slug
                '-ResultPath'
                $caseResultPath
            ) -WorkingDirectory $root -EnvironmentVariables @{}
            return [pscustomobject]@{
                run = $caseRun
                result_path = $caseResultPath
                destination_one = $caseDestinationOne
                destination_two = $caseDestinationTwo
            }
        }

        $failureProbePath = Join-Path $fixtureRoot 'phase4-rollback-failure-probe-Invoke-CodexDispatch.ps1'
        [IO.File]::WriteAllText($failureProbePath, $failureProbeText, (New-Object Text.UTF8Encoding($true)))
        $normalFailure = & $invokeFailureProbe -ScriptText $failureProbeText -Slug ('rb-normal-' + [guid]::NewGuid().ToString('N').Substring(0, 6)) -Label 'rb-normal'
        Assert-True ([int]$normalFailure.run.exit_code -ne 0 -and -not (Test-Path -LiteralPath $normalFailure.destination_one -PathType Leaf) -and -not (Test-Path -LiteralPath $normalFailure.destination_two -PathType Leaf)) ('T016 production rollback 未清除已提交 artifact：' + [string]$normalFailure.run.stdout + [string]$normalFailure.run.stderr)
        $mutantFailure = & $invokeFailureProbe -ScriptText $rollbackMutantText -Slug ('rb-mutant-' + [guid]::NewGuid().ToString('N').Substring(0, 6)) -Label 'rb-mutant'
        Assert-True ([int]$mutantFailure.run.exit_code -ne 0 -and (Test-Path -LiteralPath $mutantFailure.destination_one -PathType Leaf)) ('T016 reverse mutant 未暴露缺少 rollback：' + [string]$mutantFailure.run.stdout + [string]$mutantFailure.run.stderr)
        Write-Phase9Evidence -Label 'T016_PREPARE_ROLLBACK_MUTANT' -Value ([ordered]@{
                production_failure = $normalFailure
                reverse_mutant_failure = $mutantFailure
                mutation = '將 Invoke-Prepare catch 的 committed artifact cleanup 改為空迴圈。'
        })
    }

    Invoke-Case 'Phase 4 T017 Collect current_open 與 conclusion pass 不一致時拒絕' {
        $collectSlug = 'phase4-collect-reviewer-gate'
        $collectOutputPath = Join-Path $reviewerRoot 'phase4-collect-output.txt'
        $collectClosurePath = Join-Path $reviewerRoot 'phase4-collect-closure.md'
        $collectReviewerPath = Join-Path $reviewerRoot 'phase4-current-open-pass.md'
        $collectPreflightPath = Join-Path $reviewerRoot 'phase4-collect-preflight.json'
        $collectResultPath = Join-Path $reviewerRoot 'phase4-collect-result.json'
        Write-Utf8NoBom -Path $collectOutputPath -Content 'phase4 collect output'
        Write-Utf8NoBom -Path $collectClosurePath -Content '# Phase 4 collect closure'
        $collectFinding = [ordered]@{ id = 'F-017'; axis = 'Standards'; status = 'open'; severity = 'Minor'; disposition = 'new'; summary = 'phase4 current open pass' }
        $collectManifest = New-ReviewerManifest -CurrentFindings @($collectFinding) -CurrentNew 1 -CurrentOpen 1 -Conclusion pass
        Write-ReviewerFixture -Path $collectReviewerPath -Manifest $collectManifest -CurrentIds @('F-017')
        $collectPreflight = [ordered]@{
            operation = 'Preflight'
            sourceRoot = $fixtureRoot
            executionRoot = $fixtureRoot
            lineSlug = 'line-a'
            dispatchSlug = $collectSlug
            worktreeCreated = $false
            baseSha = ''
            targetStates = @([ordered]@{ FullPath = $collectOutputPath; InputPath = 'phase4-collect-output.txt' })
        }
        Write-Utf8NoBom -Path $collectPreflightPath -Content (($collectPreflight | ConvertTo-Json -Depth 10) + "`n")
        $collectRun = Invoke-Phase9Process -HostPath ((Get-Command powershell.exe -ErrorAction Stop).Source) -Arguments @(
            '-NoProfile'
            '-File'
            $sourcePath
            '-Operation'
            'Collect'
            '-DispatchKind'
            'resource'
            '-SourceRoot'
            $fixtureRoot
            '-ExecutionRoot'
            $fixtureRoot
            '-PreflightResultPath'
            $collectPreflightPath
            '-ReportPath'
            $collectClosurePath
            '-ReviewerReportPath'
            $collectReviewerPath
            '-ResultPath'
            $collectResultPath
        ) -WorkingDirectory $root -EnvironmentVariables @{}
        Assert-True ([int]$collectRun.exit_code -ne 0) ('T017 production Collect 應拒絕不一致 reviewer manifest：' + [string]$collectRun.stdout + [string]$collectRun.stderr)
        $collectResultDocument = Get-Content -LiteralPath $collectResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True (-not $collectResultDocument.outputValid -and -not $collectResultDocument.reviewerFindings.valid -and $collectResultDocument.reviewerFindings.current_open_count -eq 1 -and (@($collectResultDocument.reviewerFindings.inconsistencies) -join ';') -match 'current_open>0') 'T017 Collect 未輸出結構化不一致 reviewerFindings。'

        $collectProductionText = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
        $fixedReviewerGate = "if ([int64]`$result.current_open_count -gt 0 -and [string]`$result.conclusion -ceq 'pass') {"
        $mutantReviewerGate = 'if ($false) {'
        Assert-True $collectProductionText.Contains($fixedReviewerGate) 'T017 reverse 找不到 reviewer current_open gate。'
        $collectMutantText = $collectProductionText.Replace($fixedReviewerGate, $mutantReviewerGate)
        Assert-True ($collectMutantText -ne $collectProductionText) 'T017 reverse mutant 未移除 current_open gate。'
        $collectMutantSlug = 'phase4-collect-reviewer-mutant'
        $collectMutantPreflightPath = Join-Path $reviewerRoot 'phase4-collect-mutant-preflight.json'
        $collectMutantResultPath = Join-Path $reviewerRoot 'phase4-collect-mutant-result.json'
        $collectMutantPreflight = [ordered]@{}
        foreach ($preflightProperty in $collectPreflight.Keys) {
            $collectMutantPreflight[$preflightProperty] = $collectPreflight[$preflightProperty]
        }
        $collectMutantPreflight.dispatchSlug = $collectMutantSlug
        Write-Utf8NoBom -Path $collectMutantPreflightPath -Content (($collectMutantPreflight | ConvertTo-Json -Depth 10) + "`n")
        $collectMutantPath = Join-Path $fixtureRoot 'phase4-collect-reviewer-mutant-Invoke-CodexDispatch.ps1'
        [IO.File]::WriteAllText($collectMutantPath, $collectMutantText, (New-Object Text.UTF8Encoding($true)))
        $collectMutantRun = Invoke-Phase9Process -HostPath ((Get-Command powershell.exe -ErrorAction Stop).Source) -Arguments @(
            '-NoProfile'
            '-File'
            $collectMutantPath
            '-Operation'
            'Collect'
            '-DispatchKind'
            'resource'
            '-SourceRoot'
            $fixtureRoot
            '-ExecutionRoot'
            $fixtureRoot
            '-PreflightResultPath'
            $collectMutantPreflightPath
            '-ReportPath'
            $collectClosurePath
            '-ReviewerReportPath'
            $collectReviewerPath
            '-ResultPath'
            $collectMutantResultPath
        ) -WorkingDirectory $root -EnvironmentVariables @{}
        $collectMutantResultDocument = Get-Content -LiteralPath $collectMutantResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ([int]$collectMutantRun.exit_code -eq 0 -and $collectMutantResultDocument.outputValid -and $collectMutantResultDocument.reviewerFindings.valid) ('T017 reverse mutant 未暴露 Collect gate 遺失：' + [string]$collectMutantRun.stdout + [string]$collectMutantRun.stderr)
        Write-Phase9Evidence -Label 'T017_COLLECT_REVIEWER_GATE_MUTANT' -Value ([ordered]@{
                production = [ordered]@{ run = $collectRun; result = $collectResultDocument }
                reverse_mutant = [ordered]@{ run = $collectMutantRun; result = $collectMutantResultDocument }
                mutation = '將 Collect 專用 current_open>0 且 conclusion=pass gate 改為永不成立。'
            })
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
    function Get-ExistingGitRepositoryState {
        param([string]$SourceRoot)
        if ([string]::Equals([IO.Path]::GetFullPath($SourceRoot), [IO.Path]::GetFullPath($root), [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ IsRepository = $true }
        }
        return [pscustomobject]@{ IsRepository = $false }
    }
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
    Invoke-Case 'Phase 6 Prepare source boundary 拒絕' -Reject -ErrorPattern 'PrepareArtifactMismatch|handoff/report line roots' {
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

    Invoke-Case 'Phase 5 T021 非法 SessionMode 回報收到值與合法值' {
        $phase5IllegalSessionPromptPath = Join-Path $fixtureRoot 'phase5-illegal-session-prompt.md'
        Write-Utf8NoBom -Path $phase5IllegalSessionPromptPath -Content 'phase5 illegal session mode probe'
        $illegalSessionRun = Invoke-Phase9Process -HostPath ((Get-Command powershell.exe -ErrorAction Stop).Source) -Arguments @(
            '-NoProfile'
            '-File'
            $sourcePath
            '-Operation'
            'Start'
            '-SourceRoot'
            $fixtureRoot
            '-ExecutionRoot'
            $fixtureRoot
            '-DispatchRoot'
            $fixtureRoot
            '-LineSlug'
            'line-a'
            '-DispatchSlug'
            'phase5-illegal-session'
            '-SessionMode'
            'invalid-session-mode'
            '-PromptPath'
            $phase5IllegalSessionPromptPath
        ) -WorkingDirectory $root -EnvironmentVariables @{}
        $illegalSessionOutput = ([string]$illegalSessionRun.stdout + [Environment]::NewLine + [string]$illegalSessionRun.stderr)
        Assert-True ([int]$illegalSessionRun.exit_code -ne 0 -and $illegalSessionOutput -match 'received=invalid-session-mode' -and $illegalSessionOutput -match 'cold-start' -and $illegalSessionOutput -match 'continuation') ('非法 SessionMode 未完整回報：' + $illegalSessionOutput)
    }

    $phase5PrepareRootInfo = Get-PrepareRootInfo -SourceRoot $fixtureRoot -ExecutionRoot $phase6DispatchRoot -DispatchRoot $phase6DispatchRoot -LineSlug 'line-a' -DispatchSlug 'phase5-result-path'
    $phase5OutsideResultPath = Join-Path $fixtureRoot 'phase5-outside-result.json'
    Invoke-Case 'Phase 5 T021 Prepare result boundary 錯誤包含診斷欄位' -Reject -ErrorPattern 'received_filename=phase5-outside-result\.json; resolved_path=.*allowed_destination_roots=.*correction=' {
        Get-PrepareResultTargetPath -RootInfo $phase5PrepareRootInfo -PrepareResultPathValue $phase5OutsideResultPath -ResultPathValue $null -TargetPathValue @()
    }

    $phase5InvalidResultPath = Join-Path $fixtureRoot ('phase5-invalid' + [char]0 + 'result.json')
    Invoke-Case 'Phase 5 T021 Prepare result unresolvable 錯誤包含診斷欄位' -Reject -ErrorPattern 'received_filename=.*; resolved_path=<unresolved>; allowed_destination_roots=.*; correction=' {
        Get-PrepareResultTargetPath -RootInfo $phase5PrepareRootInfo -PrepareResultPathValue $phase5InvalidResultPath -ResultPathValue $null -TargetPathValue @()
    }

    $phase5CollisionDispatch = 'phase5-result-collision'
    $phase5CollisionResultPath = Join-Path $phase6DispatchRoot '.local/ai-sessions/history/line-a/phase5-result-collision.json'
    $phase5CollisionDestinationPath = Join-Path $phase6DispatchRoot '.local/ai-sessions/handoff/line-a/phase5-result-collision.txt'
    New-Item -ItemType Directory -Path (Split-Path -Parent $phase5CollisionResultPath), (Split-Path -Parent $phase5CollisionDestinationPath) -Force | Out-Null
    $phase5CollisionSentinel = 'F-002 existing result sentinel: preserve every byte.'
    Write-Utf8NoBom -Path $phase5CollisionResultPath -Content $phase5CollisionSentinel
    Set-Phase6PrepareRequest -Dispatch $phase5CollisionDispatch -Source $phase6SourcePath -Destination $phase5CollisionDestinationPath -Hash $phase6SourceHash -ResultPath $phase5CollisionResultPath | Out-Null
    Invoke-Case 'Phase 5 T021 Prepare result collision 錯誤包含診斷欄位' -Reject -ErrorPattern 'PrepareResultCollision|received_filename=phase5-result-collision\.json; resolved_path=.*allowed_destination_roots=.*correction=' {
        Invoke-Prepare
    }

    if ($Phase -lt 9) {
        Invoke-Case 'Phase 5 F-002 Prepare result collision 不覆寫既有結果位元組' {
        $productionText = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
        $fixedFailureWriterCall = '                    $writtenFailure = Write-PrepareResultDocument -Path $resultPathValue -Document $failureDocument -GuardSourceRoot $rootInfo.SourceRoot -GuardExecutionRoot $rootInfo.ExecutionRoot -GuardTargetPath $guardTargetPathValue -RequireAbsent'
        $legacyFailureWriterCall = '                    $writtenFailure = Write-PrepareResultDocument -Path $resultPathValue -Document $failureDocument -GuardSourceRoot $rootInfo.SourceRoot -GuardExecutionRoot $rootInfo.ExecutionRoot -GuardTargetPath $guardTargetPathValue'
        Assert-True $productionText.Contains($fixedFailureWriterCall) 'F-002 reverse 找不到 RequireAbsent failure writer。'
        $mutantText = $productionText.Replace($fixedFailureWriterCall, $legacyFailureWriterCall)
        Assert-True ($mutantText -ne $productionText) 'F-002 reverse mutant 未移除 RequireAbsent。'
        $mutantPath = Join-Path $fixtureRoot 'phase5-f002-mutant-Invoke-CodexDispatch.ps1'
        [IO.File]::WriteAllText($mutantPath, $mutantText, (New-Object Text.UTF8Encoding($true)))
        $requestPath = Join-Path $fixtureRoot ('phase6-request-' + $phase5CollisionDispatch + '.json')
        $prepareArguments = @(
            '-NoProfile'
            '-File'
            $mutantPath
            '-Operation'
            'Prepare'
            '-SourceRoot'
            $fixtureRoot
            '-ExecutionRoot'
            $phase6DispatchRoot
            '-DispatchRoot'
            $phase6DispatchRoot
            '-LineSlug'
            'line-a'
            '-DispatchSlug'
            $phase5CollisionDispatch
            '-WriteMode'
            'write'
            '-RequestPath'
            $requestPath
            '-ResultPath'
            $phase5CollisionResultPath
        )
        $hostPath = (Get-Command powershell.exe -ErrorAction Stop).Source
        try {
            Write-Utf8NoBom -Path $phase5CollisionResultPath -Content $phase5CollisionSentinel
            $preFixBytes = [IO.File]::ReadAllBytes($phase5CollisionResultPath)
            $preFixSha256 = Get-FileSha256 -Path $phase5CollisionResultPath
            $preFixRun = Invoke-Phase9Process -HostPath $hostPath -Arguments $prepareArguments -WorkingDirectory $root -EnvironmentVariables @{}
            $preFixOutput = ([string]$preFixRun.stdout + [Environment]::NewLine + [string]$preFixRun.stderr).Trim()
            $preFixAfterBytes = [IO.File]::ReadAllBytes($phase5CollisionResultPath)
            $preFixAfterSha256 = Get-FileSha256 -Path $phase5CollisionResultPath
            $preFixChanged = -not (Test-ByteArrayEqual -Left $preFixBytes -Right $preFixAfterBytes)
            Assert-True ([int]$preFixRun.exit_code -ne 0 -and $preFixOutput -match 'PrepareResultCollision' -and $preFixChanged) ('F-002 pre-fix mutant 未暴露碰撞寫回：' + $preFixOutput)

            Write-Utf8NoBom -Path $phase5CollisionResultPath -Content $phase5CollisionSentinel
            $restoredBeforeBytes = [IO.File]::ReadAllBytes($phase5CollisionResultPath)
            $restoredBeforeSha256 = Get-FileSha256 -Path $phase5CollisionResultPath
            $restoredRun = Invoke-Phase9Process -HostPath $hostPath -Arguments @(
                '-NoProfile'
                '-File'
                $sourcePath
                '-Operation'
                'Prepare'
                '-SourceRoot'
                $fixtureRoot
                '-ExecutionRoot'
                $phase6DispatchRoot
                '-DispatchRoot'
                $phase6DispatchRoot
                '-LineSlug'
                'line-a'
                '-DispatchSlug'
                $phase5CollisionDispatch
                '-WriteMode'
                'write'
                '-RequestPath'
                $requestPath
                '-ResultPath'
                $phase5CollisionResultPath
            ) -WorkingDirectory $root -EnvironmentVariables @{}
            $restoredOutput = ([string]$restoredRun.stdout + [Environment]::NewLine + [string]$restoredRun.stderr).Trim()
            $restoredAfterBytes = [IO.File]::ReadAllBytes($phase5CollisionResultPath)
            $restoredAfterSha256 = Get-FileSha256 -Path $phase5CollisionResultPath
            $restoredUnchanged = Test-ByteArrayEqual -Left $restoredBeforeBytes -Right $restoredAfterBytes
            Assert-True ([int]$restoredRun.exit_code -ne 0 -and $restoredOutput -match 'PrepareResultCollision' -and $restoredUnchanged -and $restoredBeforeSha256 -eq $restoredAfterSha256) ('F-002 restored collision guard 未保留原始位元組：' + $restoredOutput)

            $script:phase5F002Evidence = [ordered]@{
                pre_fix_failure = [ordered]@{
                    exit_code = $preFixRun.exit_code
                    error = $preFixOutput
                    sentinel = $phase5CollisionSentinel
                    before_sha256 = $preFixSha256
                    after_sha256 = $preFixAfterSha256
                    bytes_changed = $preFixChanged
                    result = 'FAIL'
                }
                restored_pass = [ordered]@{
                    exit_code = $restoredRun.exit_code
                    error = $restoredOutput
                    sentinel = $phase5CollisionSentinel
                    before_sha256 = $restoredBeforeSha256
                    after_sha256 = $restoredAfterSha256
                    bytes_unchanged = $restoredUnchanged
                    result = 'PASS'
                }
                mutation = '移除 Prepare failure writer 的 RequireAbsent，模擬修正前 File.Replace 覆寫碰撞結果。'
            }
            Write-Phase9Evidence -Label 'F002_PRE_FIX_FAILURE' -Value $script:phase5F002Evidence.pre_fix_failure
            Write-Phase9Evidence -Label 'F002_RESTORED_PASS' -Value $script:phase5F002Evidence.restored_pass
        }
        finally {
            Write-Utf8NoBom -Path $phase5CollisionResultPath -Content $phase5CollisionSentinel
            Set-Phase6PrepareRequest -Dispatch 'phase6-prepare' -Source $phase6SourcePath -Destination $phase6DestinationPath -Hash $phase6SourceHash -ResultPath $phase6PrepareResultPath | Out-Null
        }
        }
    }

    Invoke-Case 'Phase 5 T021 Prepare result diagnostic reverse mutant 被辨識' {
        $diagnosticProductionText = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
        $fixedCollisionCall = '            Throw-PrepareValidationFailure -Code ''PrepareResultCollision'' -Message (''Prepare result 已存在，拒絕覆寫：'' + $diagnostic)'
        $legacyCollisionCall = '            Throw-PrepareValidationFailure -Code ''PrepareResultCollision'' -Message (''Prepare result 已存在，拒絕覆寫：'' + $resultPathValue)'
        Assert-True $diagnosticProductionText.Contains($fixedCollisionCall) 'T021 reverse 找不到 Prepare result diagnostic collision call。'
        $diagnosticMutantText = $diagnosticProductionText.Replace($fixedCollisionCall, $legacyCollisionCall)
        Assert-True ($diagnosticMutantText -ne $diagnosticProductionText) 'T021 reverse mutant 未移除 collision 診斷欄位。'
        $diagnosticMutantPath = Join-Path $fixtureRoot 'phase5-result-diagnostic-mutant-Invoke-CodexDispatch.ps1'
        [IO.File]::WriteAllText($diagnosticMutantPath, $diagnosticMutantText, (New-Object Text.UTF8Encoding($true)))
        $diagnosticMutantRun = Invoke-Phase9Process -HostPath ((Get-Command powershell.exe -ErrorAction Stop).Source) -Arguments @(
            '-NoProfile'
            '-File'
            $diagnosticMutantPath
            '-Operation'
            'Prepare'
            '-SourceRoot'
            $fixtureRoot
            '-ExecutionRoot'
            $phase6DispatchRoot
            '-DispatchRoot'
            $phase6DispatchRoot
            '-LineSlug'
            'line-a'
            '-DispatchSlug'
            $phase5CollisionDispatch
            '-WriteMode'
            'write'
            '-RequestPath'
            (Join-Path $fixtureRoot ('phase6-request-' + $phase5CollisionDispatch + '.json'))
            '-ResultPath'
            $phase5CollisionResultPath
        ) -WorkingDirectory $root -EnvironmentVariables @{}
        $diagnosticMutantOutput = ([string]$diagnosticMutantRun.stdout + [Environment]::NewLine + [string]$diagnosticMutantRun.stderr)
        Assert-True ([int]$diagnosticMutantRun.exit_code -ne 0 -and $diagnosticMutantOutput -notmatch 'received_filename=') ('T021 reverse mutant 未暴露診斷欄位缺失：' + $diagnosticMutantOutput)
        Write-Phase9Evidence -Label 'T021_PREPARE_RESULT_DIAGNOSTIC_MUTANT' -Value ([ordered]@{
                production = [ordered]@{ boundary = 'passed'; unresolvable = 'passed'; collision = 'passed' }
                reverse_mutant = [ordered]@{ exit_code = $diagnosticMutantRun.exit_code; output = $diagnosticMutantOutput }
                mutation = '將 PrepareResultCollision 的診斷訊息改回只輸出 result path。'
            })
        Set-Phase6PrepareRequest -Dispatch 'phase6-prepare' -Source $phase6SourcePath -Destination $phase6DestinationPath -Hash $phase6SourceHash -ResultPath $phase6PrepareResultPath | Out-Null
    }

    Invoke-Case 'Phase 5 T021 不存在的 dispatch worktree target 維持 direct-write' {
        $phase5NoWorktreeDispatchRoot = Join-Path $fixtureRoot '.local/ai-sessions/worktrees/phase5-no-worktree'
        $phase5NoWorktreeTargetPath = Join-Path $phase5NoWorktreeDispatchRoot 'new-target.txt'
        try {
            Assert-True (-not (Test-Path -LiteralPath $phase5NoWorktreeDispatchRoot)) 'T021 negative target fixture 不應預先存在。'
            $script:SourceRoot = $fixtureRoot
            $script:ExecutionRoot = $null
            $script:DispatchRoot = $phase5NoWorktreeDispatchRoot
            $script:LineSlug = 'line-a'
            $script:DispatchSlug = 'phase5-no-worktree'
            $script:TargetPath = @($phase5NoWorktreeTargetPath)
            $script:WriteMode = 'write'
            $script:PrepareResultPath = $null
            $phase5NoWorktreeResult = Invoke-Preflight
            Assert-True (-not [bool]$phase5NoWorktreeResult.worktreeCreated -and [string]::Equals([string]$phase5NoWorktreeResult.executionRoot, (Resolve-AbsolutePath -Path $fixtureRoot), [StringComparison]::OrdinalIgnoreCase) -and [string]::Equals([string]$phase5NoWorktreeResult.dispatchRoot, (Resolve-AbsolutePath -Path $phase5NoWorktreeDispatchRoot), [StringComparison]::OrdinalIgnoreCase)) ('不存在 dispatch worktree target 的 Preflight 分流異常：' + ($phase5NoWorktreeResult | ConvertTo-Json -Depth 20 -Compress))
        }
        finally {
            Set-Phase6PrepareRequest -Dispatch 'phase6-prepare' -Source $phase6SourcePath -Destination $phase6DestinationPath -Hash $phase6SourceHash -ResultPath $phase6PrepareResultPath | Out-Null
            $script:TargetPath = @()
        }
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
            values = [ordered]@{
                primary = [ordered]@{ used_percent = $primaryUsed; remaining_percent = $PrimaryRemainingPercent; resets_at = $primaryReset }
                secondary = [ordered]@{ used_percent = 50; remaining_percent = 50; resets_at = $secondaryReset }
            }
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
            ' default_profile_path = $defaultProfilePath;' +
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
            default_profile_path = [string]$profileResult[0].default_profile_path
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
        Assert-True (@($missing.missing_profiles) -contains 'default.config.toml' -and $warningOutput.Contains('default.config.toml')) ('缺少 default.config.toml 未列入 missingProfiles。warnings=' + $warningOutput)
        Assert-True (-not $hostOutput.Contains($successMessage)) ('缺少 default.config.toml 仍輸出雙檔成功訊息。host=' + $hostOutput)

        $defaultPath = Join-Path $caseRoot 'default.config.toml'
        Write-Utf8NoBom -Path $defaultPath -Content "model = 'fixture-model'`r`nmodel_reasoning_effort = 'high'`r`n"
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
        $defaultPath = Join-Path $caseRoot 'default.config.toml'
        $advisorPath = Join-Path $caseRoot 'advisor.config.toml'
        $legacyName = 'deep' + '.config.toml'
        $legacyPath = Join-Path $caseRoot $legacyName
        $profileContent = "model = 'fixture-model'`r`nmodel_reasoning_effort = 'high'`r`n"
        Write-Utf8NoBom -Path $configPath -Content $profileContent
        Write-Utf8NoBom -Path $defaultPath -Content $profileContent
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
        $probeArguments = @($probeResult.codexArguments | ForEach-Object { [string]$_ })
        $probeProfileIndex = [Array]::IndexOf([string[]]$probeArguments, '--profile')
        $probeProfileArgumentValid = $probeProfileIndex -ge 0 -and $probeProfileIndex + 1 -lt $probeArguments.Count -and $probeArguments[$probeProfileIndex + 1] -ceq 'default'
        Assert-True ($probeResult.success -and $probeResult.processStarted -and $script:quotaProbeStartCalls -eq 1 -and $probeProfileArgumentValid -and $probeResult.requested_profile -eq 'advisor' -and $probeResult.effective_profile -eq 'default') ('F-017 Start result 或 codex arguments 不符：' + ($probeResult | ConvertTo-Json -Depth 16 -Compress))
        $recoveryArguments = @($recovery.probeEvidence.codexArguments | ForEach-Object { [string]$_ })
        $recoveryProfileIndex = [Array]::IndexOf([string[]]$recoveryArguments, '--profile')
        $recoveryProfileArgumentValid = $recoveryProfileIndex -ge 0 -and $recoveryProfileIndex + 1 -lt $recoveryArguments.Count -and $recoveryArguments[$recoveryProfileIndex + 1] -ceq 'default'
        Assert-True ($recovery.requested_profile -eq 'advisor' -and $recovery.effective_profile -eq 'default' -and $recoveryProfileArgumentValid -and (Test-Path -LiteralPath $script:quotaProbeEventPath -PathType Leaf) -and (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) 'F-017 recovery record、event stream 或 quota snapshot 未保存 requested/effective profile。'
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

if ($Phase -ge 9) {
    $phase9RepositoryBoundaryStart = Get-Phase9RepositoryBoundarySnapshot -RepositoryRoot $root
    $phase9GitStatusBefore = [string]$phase9RepositoryBoundaryStart.git_status_short
    $phase9Root = Join-Path $fixtureRoot 'phase9'
    New-Item -ItemType Directory -Path $phase9Root -Force | Out-Null
    $sRealDispatchParent = Join-Path $fixtureBaseRoot 'p9-real'
    $sRealDispatchParentExistedBefore = Test-Path -LiteralPath $sRealDispatchParent -PathType Container
    $sRealDispatchParentBaselineEntries = @()
    if ($sRealDispatchParentExistedBefore) {
        $sRealDispatchParentBaselineEntries = @(Get-ChildItem -LiteralPath $sRealDispatchParent -Force | Select-Object -ExpandProperty Name)
    }
    New-Item -ItemType Directory -Path $sRealDispatchParent -Force | Out-Null

    $invokeDefaultProfileIsolationStart = {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$CaseRoot,
            [Parameter(Mandatory)][string]$RunName,
            [Parameter(Mandatory)][string]$DefaultModel,
            [Parameter(Mandatory)][string]$DefaultEffort,
            [Parameter(Mandatory)][string]$ApplicationModel,
            [Parameter(Mandatory)][string]$ApplicationEffort
        )

        $codexHome = Join-Path $CaseRoot 'codex-home'
        $sessionsRoot = Join-Path $codexHome 'sessions'
        $historyRoot = Join-Path $CaseRoot '.local\ai-sessions\history'
        $lineRoot = Join-Path $CaseRoot '.local\ai-sessions\handoff\line-a'
        $promptPath = Join-Path $CaseRoot ($RunName + '-prompt.md')
        $preflightPath = Join-Path $CaseRoot ($RunName + '-preflight.json')
        $quotaPath = Join-Path $CaseRoot ($RunName + '-quota-before.json')
        $scopePlanPath = Join-Path $historyRoot ($RunName + '-scope-plan.json')
        $defaultConfigPath = Join-Path $codexHome 'default.config.toml'
        $applicationConfigPath = Join-Path $codexHome 'config.toml'
        $rolloutPath = Join-Path $sessionsRoot ('rollout-' + $RunName + '.jsonl')
        $threadId = [guid]::NewGuid().ToString('D')

        New-Item -ItemType Directory -Path $sessionsRoot, $historyRoot, $lineRoot -Force | Out-Null
        Write-Utf8NoBom -Path (Join-Path $lineRoot 'line.json') -Content (([ordered]@{ schema = 'ai-sessions.line.v1'; 'line-slug' = 'line-a' } | ConvertTo-Json -Compress) + "`r`n")
        Write-Utf8NoBom -Path $promptPath -Content ('T003 default profile isolation: ' + $RunName)
        Write-Utf8NoBom -Path $preflightPath -Content (([ordered]@{
                    sourceRoot = $CaseRoot
                    dispatchRoot = $CaseRoot
                    executionRoot = $CaseRoot
                    lineSlug = 'line-a'
                    dispatchSlug = $RunName
                    writeMode = 'write'
                    dispatchKind = 'workflow'
                } | ConvertTo-Json -Depth 12) + "`r`n")
        $defaultContent = @(
            ('model = "' + $DefaultModel + '"')
            ('model_reasoning_effort = "' + $DefaultEffort + '"')
            ''
            '[agents]'
            'default_subagent_model = "synthetic-subagent"'
            'default_subagent_reasoning_effort = "low"'
        ) -join "`r`n"
        $applicationContent = @(
            ('model = "' + $ApplicationModel + '"')
            ('model_reasoning_effort = "' + $ApplicationEffort + '"')
            ''
            '[agents]'
            'default_subagent_model = "synthetic-subagent"'
            'default_subagent_reasoning_effort = "low"'
        ) -join "`r`n"
        Write-Utf8NoBom -Path $defaultConfigPath -Content ($defaultContent + "`r`n")
        Write-Utf8NoBom -Path $applicationConfigPath -Content ($applicationContent + "`r`n")
        $null = New-Phase8QuotaSnapshot -Path $quotaPath -PrimaryRemainingPercent 80

        $script:profileIsolationProbe = $true
        $script:profileIsolationCapturedArguments = @()
        $script:profileIsolationCodexHome = $codexHome
        $script:profileIsolationRolloutPath = $rolloutPath
        $script:profileIsolationSelectedProfile = $null
        $script:profileIsolationSelectedConfigPath = $null
        $script:profileIsolationSelectedModel = $null
        $script:profileIsolationSelectedEffort = $null
        $script:profileIsolationLauncherPath = $null
        $script:testThread = $threadId
        $script:quotaSnapshotPathOverride = $quotaPath
        $script:dispatchUnitListOverride = @('Phase 1')
        $script:pidResult = @{ ActiveRecords = @(); UnconfirmedRecords = @(); Blocked = $false; Reason = '' }
        $script:relayFailure = $false
        $script:failLaunch = $false
        $script:aclFixtureStatus = 'clean'
        $script:scopePlanFixtureDecision = 'full'
        $script:launcherFixtureFailure = $false
        $script:InvocationBoundParameters = [ordered]@{}
        $script:RequestContext = $null
        $script:RequestPrepareArtifacts = @()
        $script:SourceRoot = $CaseRoot
        $script:DispatchRoot = $CaseRoot
        $script:ExecutionRoot = $CaseRoot
        $script:LineSlug = 'line-a'
        $script:DispatchSlug = $RunName
        $script:WriteMode = 'write'
        $script:PreflightResultPath = $preflightPath
        $script:PrepareResultPath = $null
        $script:PromptPath = $promptPath
        $script:CodexHome = $codexHome
        $script:CodexPath = 'fixture-codex'
        $script:TargetPath = @()
        $script:ResumeThreadId = $null
        $script:LastMessagePath = $null
        $script:QuotaBeforePath = $quotaPath
        $script:QuotaAfterPath = $null
        $script:CalibrationPath = $null
        $script:ScopePlanPath = $scopePlanPath
        $script:ResultPath = $null
        $script:RunRecordPath = $null
        $script:ThreadIdPath = $null
        $script:PidRecordPath = $null
        $script:Profile = 'default'
        $script:Model = $null
        $script:ReasoningEffort = $null
        $script:TaskType = 'script-change'
        $script:SessionMode = 'cold-start'
        $script:DispatchKind = 'workflow'
        $script:UnitKind = 'workflow-phase'
        $script:RequestedUnit = 'Phase 1'
        $script:AddDirectory = $null
        $script:Search = $false
        $script:CodexParentOption = $null
        $script:EvidencePackPath = $null
        $script:AdvisorConsultReportPath = $null
        $script:AdvisorRequestSource = $null
        $script:BudgetMonitorPath = $null
        $script:RecoveryHandoffPath = $null
        $script:InitialQuotaState = 'Valid'
        $script:PrimaryBudgetPercent = 34
        $script:PrimaryReservePercent = 30
        $script:ProfileExplicit = $true
        $script:AddDirectoryExplicit = $false
        $script:SearchExplicit = $false
        $script:CodexParentOptionExplicit = $false
        $script:DispatchStageBinding = $null

        $startResult = Invoke-Start
        $runRecord = Get-Content -LiteralPath $startResult.runRecordPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $runtimeEvidence = Get-RuntimeModelEvidence -CodexHome $codexHome -ThreadId $startResult.threadId -StartedAtUtc $startResult.startedAtUtc
        $eventStream = Get-Content -LiteralPath $startResult.eventStreamPath -Raw -Encoding UTF8
        $stderr = Get-Content -LiteralPath $startResult.stderrPath -Raw -Encoding UTF8
        return [pscustomobject]@{
            run_name = $RunName
            case_root = $CaseRoot
            codex_home = $codexHome
            default_config_path = $defaultConfigPath
            application_config_path = $applicationConfigPath
            default_config_content = Get-Content -LiteralPath $defaultConfigPath -Raw -Encoding UTF8
            application_config_content = Get-Content -LiteralPath $applicationConfigPath -Raw -Encoding UTF8
            start_result = $startResult
            run_record = $runRecord
            runtime_evidence = $runtimeEvidence
            codex_arguments = @($script:profileIsolationCapturedArguments)
            event_stream = $eventStream
            stderr = $stderr
            exit_code = 0
            launcher_path = $script:profileIsolationLauncherPath
            selected_profile = $script:profileIsolationSelectedProfile
            selected_config_path = $script:profileIsolationSelectedConfigPath
            selected_model = $script:profileIsolationSelectedModel
            selected_effort = $script:profileIsolationSelectedEffort
            rollout_path = $rolloutPath
            thread_id = $threadId
        }
    }

    Invoke-Case 'Phase 9 T003 default profile isolation actual Start and reverse probe' {
        $caseRoot = Join-Path $phase9Root 't3'
        $defaultModelA = 'synthetic-default-model-a'
        $defaultEffortA = 'synthetic-default-effort-a'
        $applicationModelA = 'synthetic-application-model-a'
        $applicationEffortA = 'synthetic-application-effort-a'
        $defaultModelB = 'synthetic-default-model-b'
        $defaultEffortB = 'synthetic-default-effort-b'
        $applicationModelB = 'synthetic-application-model-b'
        $applicationEffortB = 'synthetic-application-effort-b'
        $profileIsolationVariableNames = @(
            'profileIsolationProbe', 'profileIsolationCapturedArguments', 'profileIsolationCodexHome', 'profileIsolationRolloutPath',
            'profileIsolationSelectedProfile', 'profileIsolationSelectedConfigPath', 'profileIsolationSelectedModel', 'profileIsolationSelectedEffort',
            'profileIsolationLauncherPath', 'testThread',
            'quotaSnapshotPathOverride', 'dispatchUnitListOverride', 'pidResult', 'relayFailure', 'failLaunch', 'aclFixtureStatus',
            'scopePlanFixtureDecision', 'launcherFixtureFailure', 'InvocationBoundParameters', 'RequestContext', 'RequestPrepareArtifacts',
            'SourceRoot', 'DispatchRoot', 'ExecutionRoot', 'LineSlug', 'DispatchSlug', 'WriteMode', 'PreflightResultPath',
            'PrepareResultPath', 'PromptPath', 'CodexHome', 'CodexPath', 'TargetPath', 'ResumeThreadId', 'LastMessagePath',
            'QuotaBeforePath', 'QuotaAfterPath', 'CalibrationPath', 'ScopePlanPath', 'ResultPath', 'RunRecordPath', 'ThreadIdPath',
            'PidRecordPath', 'Profile', 'Model', 'ReasoningEffort', 'TaskType', 'SessionMode', 'DispatchKind', 'UnitKind',
            'RequestedUnit', 'AddDirectory', 'Search', 'CodexParentOption', 'EvidencePackPath', 'AdvisorConsultReportPath',
            'AdvisorRequestSource', 'BudgetMonitorPath', 'RecoveryHandoffPath', 'InitialQuotaState', 'PrimaryBudgetPercent',
            'PrimaryReservePercent', 'ProfileExplicit', 'AddDirectoryExplicit', 'SearchExplicit', 'CodexParentOptionExplicit',
            'DispatchStageBinding'
        )
        $profileIsolationSavedVariables = @{}
        foreach ($variableName in $profileIsolationVariableNames) {
            $existingVariable = Get-Variable -Name $variableName -Scope Script -ErrorAction SilentlyContinue
            $profileIsolationSavedVariables[$variableName] = if ($null -eq $existingVariable) {
                [pscustomobject]@{ exists = $false; value = $null }
            }
            else {
                [pscustomobject]@{ exists = $true; value = $existingVariable.Value }
            }
        }
        $script:profileIsolationProbe = $false
        $profileResolverCommand = Get-Command -Name Resolve-ProfileConfigPath -CommandType Function -ErrorAction Stop
        $profileResolverOriginal = $profileResolverCommand.ScriptBlock
        $profileResolverDefinition = $profileResolverOriginal.ToString()
        $profileResolverMutantDefinition = $profileResolverDefinition.Replace("'default.config.toml'", "'config.toml'")
        Assert-True ($profileResolverMutantDefinition -ne $profileResolverDefinition) 'T003 無法建立 default resolver 的 config.toml mutant。'
        $profileResolverMutant = [scriptblock]::Create($profileResolverMutantDefinition)
        $profileResolverMutantApplied = $false
        try {
            $runA = & $invokeDefaultProfileIsolationStart -CaseRoot $caseRoot -RunName 'run-a' -DefaultModel $defaultModelA -DefaultEffort $defaultEffortA -ApplicationModel $applicationModelA -ApplicationEffort $applicationEffortA
            $defaultHashBefore = Get-FileSha256 -Path $runA.default_config_path
            $applicationHashBefore = Get-FileSha256 -Path $runA.application_config_path
            $defaultContentBefore = Get-Content -LiteralPath $runA.default_config_path -Raw -Encoding UTF8
            $applicationContentBefore = Get-Content -LiteralPath $runA.application_config_path -Raw -Encoding UTF8
            Assert-True ($defaultContentBefore.Contains('[agents]') -and $applicationContentBefore.Contains('[agents]')) 'T003 兩個設定檔都應保留 [agents]。'
            Assert-True ($defaultContentBefore.Contains($defaultModelA) -and $applicationContentBefore.Contains($applicationModelA) -and $defaultModelA -ne $applicationModelA) 'T003 fixture sentinel 未形成不同的 default 與 application 設定。'

            $runAArguments = @($runA.start_result.codexArguments | ForEach-Object { [string]$_ })
            $runAProfileIndex = [Array]::IndexOf([string[]]$runAArguments, '--profile')
            $runAProfileValid = $runAProfileIndex -ge 0 -and $runAProfileIndex + 1 -lt $runAArguments.Count -and $runAArguments[$runAProfileIndex + 1] -ceq 'default'
            $runAParentOptions = @($runA.start_result.parentOptions.codex_parent_option | ForEach-Object { [string]$_ })
            Assert-True ($runAProfileValid -and $runAParentOptions -notcontains '--profile') ('T003 run-a profile argument 或 codex_parent_option 不符：' + ($runA.start_result | ConvertTo-Json -Depth 30 -Compress))
            Assert-True ([String]::Equals([string]$runA.start_result.profileConfigPath, [string]$runA.default_config_path, [StringComparison]::OrdinalIgnoreCase) -and [String]::Equals([string]$runA.run_record.profile_config_path, [string]$runA.default_config_path, [StringComparison]::OrdinalIgnoreCase)) 'T003 run-a profile path 未指向 default.config.toml。'
            Assert-True ((Get-DispatchEvidenceValue -Evidence $runA.start_result.resolvedModel) -ceq $defaultModelA -and (Get-DispatchEvidenceValue -Evidence $runA.start_result.resolvedReasoningEffort) -ceq $defaultEffortA) 'T003 run-a profile evidence 未讀取 default sentinel。'
            Assert-True ((Get-DispatchEvidenceValue -Evidence $runA.runtime_evidence.model) -ceq $defaultModelA -and (Get-DispatchEvidenceValue -Evidence $runA.runtime_evidence.reasoning_effort) -ceq $defaultEffortA -and $runA.runtime_evidence.model.source -eq 'rollout' -and $runA.runtime_evidence.reasoning_effort.source -eq 'rollout') 'T003 run-a runtime evidence 未讀取 default sentinel。'

            $applicationContentAfterMutation = @(
                ('model = "' + $applicationModelB + '"')
                ('model_reasoning_effort = "' + $applicationEffortB + '"')
                ''
                '[agents]'
                'default_subagent_model = "synthetic-subagent"'
                'default_subagent_reasoning_effort = "low"'
            ) -join "`r`n"
            Write-Utf8NoBom -Path $runA.application_config_path -Content ($applicationContentAfterMutation + "`r`n")
            Assert-True ((Get-FileSha256 -Path $runA.default_config_path) -eq $defaultHashBefore -and (Get-FileSha256 -Path $runA.application_config_path) -ne $applicationHashBefore) 'T003 reverse fixture 未確認只修改 config.toml sentinel。'

            $runB = & $invokeDefaultProfileIsolationStart -CaseRoot $caseRoot -RunName 'run-b' -DefaultModel $defaultModelA -DefaultEffort $defaultEffortA -ApplicationModel $applicationModelB -ApplicationEffort $applicationEffortB
            $runBArguments = @($runB.start_result.codexArguments | ForEach-Object { [string]$_ })
            $runBProfileIndex = [Array]::IndexOf([string[]]$runBArguments, '--profile')
            $runBProfileValid = $runBProfileIndex -ge 0 -and $runBProfileIndex + 1 -lt $runBArguments.Count -and $runBArguments[$runBProfileIndex + 1] -ceq 'default'
            Assert-True ($runBProfileValid -and [String]::Equals([string]$runB.start_result.profileConfigPath, [string]$runB.default_config_path, [StringComparison]::OrdinalIgnoreCase) -and [String]::Equals([string]$runB.run_record.profile_config_path, [string]$runB.default_config_path, [StringComparison]::OrdinalIgnoreCase)) 'T003 run-b profile path 或顯式 profile 不符。'
            Assert-True ((Get-DispatchEvidenceValue -Evidence $runB.start_result.resolvedModel) -ceq $defaultModelA -and (Get-DispatchEvidenceValue -Evidence $runB.start_result.resolvedReasoningEffort) -ceq $defaultEffortA -and (Get-DispatchEvidenceValue -Evidence $runB.runtime_evidence.model) -ceq $defaultModelA -and (Get-DispatchEvidenceValue -Evidence $runB.runtime_evidence.reasoning_effort) -ceq $defaultEffortA) 'T003 修改 config.toml 後 default profile 或 runtime evidence 發生變化。'
            Assert-True ((Get-FileSha256 -Path $runB.default_config_path) -eq $defaultHashBefore -and (Get-Content -LiteralPath $runB.application_config_path -Raw -Encoding UTF8).Contains($applicationModelB) -and (Get-Content -LiteralPath $runB.application_config_path -Raw -Encoding UTF8).Contains('[agents]')) 'T003 run-b 未保留 default.config.toml 或 config.toml 的反向 fixture 狀態。'

            Set-Item -Path 'Function:\script:Resolve-ProfileConfigPath' -Value $profileResolverMutant
            $profileResolverMutantApplied = $true
            $mutantFailure = $null
            $mutantRun = $null
            try {
                $mutantRun = & $invokeDefaultProfileIsolationStart -CaseRoot $caseRoot -RunName 'resolver-mutant' -DefaultModel $defaultModelA -DefaultEffort $defaultEffortA -ApplicationModel $applicationModelB -ApplicationEffort $applicationEffortB
                Assert-True ([String]::Equals([string]$mutantRun.start_result.profileConfigPath, [string]$mutantRun.default_config_path, [StringComparison]::OrdinalIgnoreCase) -and (Get-DispatchEvidenceValue -Evidence $mutantRun.runtime_evidence.model) -ceq $defaultModelA -and (Get-DispatchEvidenceValue -Evidence $mutantRun.runtime_evidence.reasoning_effort) -ceq $defaultEffortA) 'T003 resolver mutant 使 runtime evidence 偏離 default 設定檔。'
            }
            catch {
                $mutantFailure = $_.Exception.Message
            }
            Assert-True (-not [string]::IsNullOrWhiteSpace($mutantFailure)) 'T003 resolver mutant 未被 runtime evidence 斷言拒絕。'
            Assert-True ([String]::Equals([string]$script:profileIsolationSelectedProfile, 'default', [StringComparison]::Ordinal) -and [String]::Equals([string]$script:profileIsolationSelectedConfigPath, [string]$runB.application_config_path, [StringComparison]::OrdinalIgnoreCase) -and [string]$script:profileIsolationSelectedModel -ceq $applicationModelB -and [string]$script:profileIsolationSelectedEffort -ceq $applicationEffortB) 'T003 resolver mutant 未使 rollout 讀取實際 config.toml sentinel。'
            $mutantOutput = [ordered]@{
                resolver_default_branch = 'temporarily changed from default.config.toml to config.toml'
                actual_launcher_profile = [string]$script:profileIsolationSelectedProfile
                actual_codex_home = [string]$script:profileIsolationCodexHome
                actual_resolved_config_path = [string]$script:profileIsolationSelectedConfigPath
                actual_rollout_model = [string]$script:profileIsolationSelectedModel
                actual_rollout_effort = [string]$script:profileIsolationSelectedEffort
                expected = 'runtime evidence assertion rejects config.toml sentinel'
                observed = 'reject'
                failure = [string]$mutantFailure
                rollout_path = [string]$script:profileIsolationRolloutPath
                exit_code = 1
            }

            Set-Item -Path 'Function:\script:Resolve-ProfileConfigPath' -Value $profileResolverOriginal
            $profileResolverMutantApplied = $false
            $runC = & $invokeDefaultProfileIsolationStart -CaseRoot $caseRoot -RunName 'restored' -DefaultModel $defaultModelA -DefaultEffort $defaultEffortA -ApplicationModel $applicationModelB -ApplicationEffort $applicationEffortB
            Assert-True ([String]::Equals([string]$runC.start_result.profileConfigPath, [string]$runC.default_config_path, [StringComparison]::OrdinalIgnoreCase) -and [String]::Equals([string]$runC.run_record.profile_config_path, [string]$runC.default_config_path, [StringComparison]::OrdinalIgnoreCase)) 'T003 還原 resolver 後 profile path 未回到 default.config.toml。'
            Assert-True ((Get-DispatchEvidenceValue -Evidence $runC.start_result.resolvedModel) -ceq $defaultModelA -and (Get-DispatchEvidenceValue -Evidence $runC.start_result.resolvedReasoningEffort) -ceq $defaultEffortA -and (Get-DispatchEvidenceValue -Evidence $runC.runtime_evidence.model) -ceq $defaultModelA -and (Get-DispatchEvidenceValue -Evidence $runC.runtime_evidence.reasoning_effort) -ceq $defaultEffortA) 'T003 還原 resolver 後 runtime evidence 未回到 default sentinel。'
            $restoredOutput = [ordered]@{
                resolver_default_branch = 'restored to default.config.toml'
                actual_launcher_profile = [string]$runC.selected_profile
                actual_codex_home = [string]$runC.codex_home
                actual_resolved_config_path = [string]$runC.selected_config_path
                actual_rollout_model = [string]$runC.selected_model
                actual_rollout_effort = [string]$runC.selected_effort
                expected = 'default sentinel'
                observed = 'pass'
                runtime_model = [string](Get-DispatchEvidenceValue -Evidence $runC.runtime_evidence.model)
                runtime_effort = [string](Get-DispatchEvidenceValue -Evidence $runC.runtime_evidence.reasoning_effort)
                profile_config_path = [string]$runC.start_result.profileConfigPath
                rollout_path = [string]$runC.rollout_path
                exit_code = 0
            }

            $reverseRoot = Join-Path $caseRoot 'reverse-config-only'
            $reverseHome = Join-Path $reverseRoot 'codex-home'
            New-Item -ItemType Directory -Path $reverseHome -Force | Out-Null
            $reverseConfigPath = Join-Path $reverseHome 'config.toml'
            Write-Utf8NoBom -Path $reverseConfigPath -Content "model = 'synthetic-legacy-default'`r`nmodel_reasoning_effort = 'synthetic-legacy-effort'`r`n`r`n[agents]`r`ndefault_subagent_model = 'synthetic-subagent'`r`n"
            $reverseResolvedPath = Resolve-ProfileConfigPath -CodexHome $reverseHome -Profile 'default'
            $reverseLegacyEvidence = Read-ProfileModelEvidence -ConfigPath $reverseConfigPath -Profile 'default'
            Assert-True ($null -eq $reverseResolvedPath -and (Get-DispatchEvidenceValue -Evidence $reverseLegacyEvidence.model) -ceq 'synthetic-legacy-default') 'T003 只保留 config.toml 的舊 fixture 未被 fixed resolver 拒絕。'
            $reverseOutput = [ordered]@{
                fixed_resolver_path = $reverseResolvedPath
                legacy_config_path = $reverseConfigPath
                legacy_config_evidence = $reverseLegacyEvidence
                result = 'fixed default resolver rejected config.toml-only fixture'
                exit_code = 0
            }
            $passOutput = [ordered]@{
                run_a = [ordered]@{
                    codex_home = [string]$runA.codex_home
                    default_config_path = [string]$runA.default_config_path
                    application_config_path = [string]$runA.application_config_path
                    default_config_content = [string]$runA.default_config_content
                    application_config_content = [string]$runA.application_config_content
                    start = [ordered]@{
                        profile = [string]$runA.start_result.profile
                        profile_config_path = [string]$runA.start_result.profileConfigPath
                        codex_arguments = @($runA.start_result.codexArguments | ForEach-Object { [string]$_ })
                        codex_parent_option = @($runA.start_result.parentOptions.codex_parent_option | ForEach-Object { [string]$_ })
                        resolved_model = [ordered]@{ value = [string](Get-DispatchEvidenceValue -Evidence $runA.start_result.resolvedModel); source = [string]$runA.start_result.resolvedModel.source }
                        resolved_reasoning_effort = [ordered]@{ value = [string](Get-DispatchEvidenceValue -Evidence $runA.start_result.resolvedReasoningEffort); source = [string]$runA.start_result.resolvedReasoningEffort.source }
                    }
                    run_record = [ordered]@{
                        profile_config_path = [string]$runA.run_record.profile_config_path
                        codex_parent_option = @($runA.run_record.parent_options.codex_parent_option | ForEach-Object { [string]$_ })
                    }
                    runtime_evidence = [ordered]@{
                        rollout_path = [string]$runA.rollout_path
                        model = [ordered]@{ value = [string](Get-DispatchEvidenceValue -Evidence $runA.runtime_evidence.model); source = [string]$runA.runtime_evidence.model.source }
                        reasoning_effort = [ordered]@{ value = [string](Get-DispatchEvidenceValue -Evidence $runA.runtime_evidence.reasoning_effort); source = [string]$runA.runtime_evidence.reasoning_effort.source }
                    }
                    event_stream = [string]$runA.event_stream
                    stderr = [string]$runA.stderr
                }
                run_b = [ordered]@{
                    codex_home = [string]$runB.codex_home
                    default_config_path = [string]$runB.default_config_path
                    application_config_path = [string]$runB.application_config_path
                    default_config_content = [string]$runB.default_config_content
                    application_config_content = [string]$runB.application_config_content
                    start = [ordered]@{
                        profile = [string]$runB.start_result.profile
                        profile_config_path = [string]$runB.start_result.profileConfigPath
                        codex_arguments = @($runB.start_result.codexArguments | ForEach-Object { [string]$_ })
                        codex_parent_option = @($runB.start_result.parentOptions.codex_parent_option | ForEach-Object { [string]$_ })
                        resolved_model = [ordered]@{ value = [string](Get-DispatchEvidenceValue -Evidence $runB.start_result.resolvedModel); source = [string]$runB.start_result.resolvedModel.source }
                        resolved_reasoning_effort = [ordered]@{ value = [string](Get-DispatchEvidenceValue -Evidence $runB.start_result.resolvedReasoningEffort); source = [string]$runB.start_result.resolvedReasoningEffort.source }
                    }
                    run_record = [ordered]@{
                        profile_config_path = [string]$runB.run_record.profile_config_path
                        codex_parent_option = @($runB.run_record.parent_options.codex_parent_option | ForEach-Object { [string]$_ })
                    }
                    runtime_evidence = [ordered]@{
                        rollout_path = [string]$runB.rollout_path
                        model = [ordered]@{ value = [string](Get-DispatchEvidenceValue -Evidence $runB.runtime_evidence.model); source = [string]$runB.runtime_evidence.model.source }
                        reasoning_effort = [ordered]@{ value = [string](Get-DispatchEvidenceValue -Evidence $runB.runtime_evidence.reasoning_effort); source = [string]$runB.runtime_evidence.reasoning_effort.source }
                    }
                    event_stream = [string]$runB.event_stream
                    stderr = [string]$runB.stderr
                }
                run_c = [ordered]@{
                    codex_home = [string]$runC.codex_home
                    default_config_path = [string]$runC.default_config_path
                    application_config_path = [string]$runC.application_config_path
                    selected_profile = [string]$runC.selected_profile
                    selected_config_path = [string]$runC.selected_config_path
                    selected_model = [string]$runC.selected_model
                    selected_effort = [string]$runC.selected_effort
                    start = [ordered]@{
                        profile = [string]$runC.start_result.profile
                        profile_config_path = [string]$runC.start_result.profileConfigPath
                        codex_arguments = @($runC.start_result.codexArguments | ForEach-Object { [string]$_ })
                        codex_parent_option = @($runC.start_result.parentOptions.codex_parent_option | ForEach-Object { [string]$_ })
                        resolved_model = [ordered]@{ value = [string](Get-DispatchEvidenceValue -Evidence $runC.start_result.resolvedModel); source = [string]$runC.start_result.resolvedModel.source }
                        resolved_reasoning_effort = [ordered]@{ value = [string](Get-DispatchEvidenceValue -Evidence $runC.start_result.resolvedReasoningEffort); source = [string]$runC.start_result.resolvedReasoningEffort.source }
                    }
                    run_record = [ordered]@{
                        profile_config_path = [string]$runC.run_record.profile_config_path
                        codex_parent_option = @($runC.run_record.parent_options.codex_parent_option | ForEach-Object { [string]$_ })
                    }
                    runtime_evidence = [ordered]@{
                        rollout_path = [string]$runC.rollout_path
                        model = [ordered]@{ value = [string](Get-DispatchEvidenceValue -Evidence $runC.runtime_evidence.model); source = [string]$runC.runtime_evidence.model.source }
                        reasoning_effort = [ordered]@{ value = [string](Get-DispatchEvidenceValue -Evidence $runC.runtime_evidence.reasoning_effort); source = [string]$runC.runtime_evidence.reasoning_effort.source }
                    }
                    exit_code = 0
                }
                default_config_hash_before = [string]$defaultHashBefore
                default_config_hash_after_application_mutation = [string](Get-FileSha256 -Path $runB.default_config_path)
                application_config_content_before = [string]$applicationContentBefore
                application_config_content_after = [string](Get-Content -LiteralPath $runB.application_config_path -Raw -Encoding UTF8)
                explicit_profile = '--profile default'
                parent_option_profile = 'absent from codex_parent_option'
                exit_code = 0
            }
            Write-Phase9Evidence -Label 'T003_DEFAULT_PROFILE_ISOLATION_MUTANT_FAIL' -Value $mutantOutput
            Write-Phase9Evidence -Label 'T003_DEFAULT_PROFILE_ISOLATION_RESTORED_PASS' -Value $restoredOutput
            Write-Phase9Evidence -Label 'T003_DEFAULT_PROFILE_ISOLATION_PASS' -Value $passOutput
            Write-Phase9Evidence -Label 'T003_DEFAULT_PROFILE_ISOLATION_REVERSE_PASS' -Value $reverseOutput
        }
        finally {
            if ($profileResolverMutantApplied) {
                Set-Item -Path 'Function:\script:Resolve-ProfileConfigPath' -Value $profileResolverOriginal
                $profileResolverMutantApplied = $false
            }
            $script:profileIsolationProbe = $false
            $script:profileIsolationCapturedArguments = @()
            $script:profileIsolationCodexHome = $null
            $script:profileIsolationRolloutPath = $null
            $script:profileIsolationSelectedProfile = $null
            $script:profileIsolationSelectedConfigPath = $null
            $script:profileIsolationSelectedModel = $null
            $script:profileIsolationSelectedEffort = $null
            $script:profileIsolationLauncherPath = $null
            foreach ($variableName in $profileIsolationVariableNames) {
                $savedVariable = $profileIsolationSavedVariables[$variableName]
                if ($savedVariable.exists) {
                    Set-Variable -Name $variableName -Scope Script -Value $savedVariable.value
                }
                else {
                    Set-Variable -Name $variableName -Scope Script -Value $null
                }
            }
        }
    }

    $aclFunctionAst = @($functions | Where-Object { $_.Name -eq 'Get-WorktreeAclGate' } | Select-Object -First 1)
    Assert-True ($aclFunctionAst.Count -eq 1) 'Phase 9 找不到 production Get-WorktreeAclGate AST。'
    $aclFunctionDefinition = $aclFunctionAst[0].Extent.Text -replace '^function Get-WorktreeAclGate', 'function Invoke-Phase9ProductionAclGate'
    . ([scriptblock]::Create($aclFunctionDefinition))

    $phase9AclSourceRoot = Join-Path $phase9Root 'acl-source'
    $phase9AclExecutionRoot = Join-Path $phase9Root 'acl-dispatch'
    New-Item -ItemType Directory -Path $phase9AclSourceRoot, $phase9AclExecutionRoot -Force | Out-Null
    $phase9SandboxEntry = [ordered]@{
        identity = 'S-1-5-21-100-200-300-400'
        identity_resolution = 'unresolved'
        access_control_type = 'Allow'
        rights = 'Modify'
        inheritance_flags = @('ObjectInherit', 'ContainerInherit')
        propagation_flags = @('None')
        is_inherited = $false
        canonical = '(OI)(CI)(M)'
        fingerprint = ('a' * 64)
    }
    $phase9ExtraAclEntry = [ordered]@{
        identity = 'S-1-5-21-100-200-300-401'
        identity_resolution = 'unresolved'
        access_control_type = 'Allow'
        rights = 'Read'
        inheritance_flags = @('ObjectInherit', 'ContainerInherit')
        propagation_flags = @('None')
        is_inherited = $false
        canonical = '(OI)(CI)(R)'
        fingerprint = ('b' * 64)
    }
    $script:phase9AclMode = 'sandbox'
    function Get-ExplicitAclSnapshot {
        param([string]$Path)
        if ($script:phase9AclMode -eq 'unknown') {
            return [ordered]@{ status = 'unknown'; path = $Path; fingerprint = $null; entries = @(); explicit_entries = @(); captured_at_utc = [datetime]::UtcNow.ToString('o'); error = 'fixture ACL read failure' }
        }
        $entries = if ([string]::Equals([IO.Path]::GetFullPath($Path), [IO.Path]::GetFullPath($phase9AclExecutionRoot), [StringComparison]::OrdinalIgnoreCase)) {
            if ($script:phase9AclMode -eq 'extra') { @($phase9SandboxEntry, $phase9ExtraAclEntry) } else { @($phase9SandboxEntry) }
        }
        else {
            @()
        }
        return [ordered]@{ status = 'known'; path = $Path; fingerprint = ('c' * 64); entries = @($entries); explicit_entries = @($entries); captured_at_utc = [datetime]::UtcNow.ToString('o'); error = $null }
    }

    Invoke-Case 'Phase 9 T003 launch-failed 分類與 ACL 錨點實證' {
        $classificationDispatch = 't003-start-classification'
        $classificationBase = New-TestRun -Line 'line-a' -Dispatch $classificationDispatch
        $classificationBase | Add-Member -MemberType NoteProperty -Name 'sandbox_acl_evidence' -Value ([ordered]@{
                capture_status = 'captured'
                entries = @($phase9SandboxEntry)
                captured_at_utc = [DateTime]::UtcNow.ToString('o')
                normal_completion = $true
                continuation_allowed = $true
            }) -Force
        $classificationBase.scope_plan_root_run_id = $classificationBase.run_id
        $classificationBase.scope_plan_selection = 'root'
        $null = Write-DispatchRunRecord -Record $classificationBase -Update

        $classificationFailure = New-TestRun -Line 'line-a' -Dispatch $classificationDispatch -Previous $classificationBase
        $classificationFailure.launch_state = 'launch-failed'
        $classificationFailure.started_at_utc = $null
        $classificationFailure.scope_plan_root_run_id = $classificationBase.run_id
        $classificationFailure.scope_plan_selection = 'root'
        $classificationFailure.failure = New-DispatchFailureRecord -Phase 'preparation' -Message 'T003 pre-start fixture failure' -ReasonCode 'T003FixturePreStartFailure' -ProcessStarted $false -EventPath $classificationFailure.event_stream_path -ErrorPath $null -LastMessagePath $classificationFailure.last_message_path -ThreadPath $null -PidPath $classificationFailure.pid_record_path -LauncherPath $null -RolloutPaths @() -Observation ([ordered]@{
                process_started = $false
                process_exit_code = $null
                failure_stage = 'preparation'
            })
        $classificationFailure | Add-Member -MemberType NoteProperty -Name 'sandbox_acl_evidence' -Value ([ordered]@{
                capture_status = 'captured'
                entries = @($phase9SandboxEntry)
                captured_at_utc = [DateTime]::UtcNow.ToString('o')
                normal_completion = $true
                continuation_allowed = $true
            }) -Force
        $null = Write-DispatchRunRecord -Record $classificationFailure -Update

        $productionAclFunction = $phase9ProductionFunctionDefinitions['Get-WorktreeAclGate']
        $fixtureAclFunction = (Get-Command -Name Get-WorktreeAclGate -CommandType Function -ErrorAction Stop).ScriptBlock
        try {
            Set-Item -Path Function:\Get-WorktreeAclGate -Value $productionAclFunction
            $preStartChain = Resolve-PreviousDispatchRun -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug $classificationDispatch -ResumeThreadId $script:testThread
            $preStartAclGate = Get-WorktreeAclGate -SourceRoot $phase9AclSourceRoot -ExecutionRoot $phase9AclExecutionRoot -WriteMode 'write' -ContinuationRecord $preStartChain.LatestActualStartRecord
            $preStartClassification = Get-DispatchRunRecordStartClassification -Record $preStartChain.ChainTailRecord
            Assert-True ($preStartClassification.classification -eq 'unstarted-sandbox' -and $preStartChain.AnchorRecord.run_id -eq $classificationBase.run_id -and $preStartChain.LatestActualStartRecord.run_id -eq $classificationBase.run_id -and $preStartAclGate.status -eq 'clean') ('pre-start launch-failed 未回退至 clean ACL 錨點：' + ($preStartAclGate | ConvertTo-Json -Depth 20 -Compress))
            Write-Phase9Evidence -Label 'T003_PRE_START_LAUNCH_FAILED_ACL_CLEAN' -Value ([ordered]@{
                    classification = $preStartClassification
                    chain_anchor_run_id = $preStartChain.AnchorRecord.run_id
                    latest_actual_start_run_id = $preStartChain.LatestActualStartRecord.run_id
                    acl_gate = $preStartAclGate
                })

            $classificationFailure.failure.observation.process_started = $true
            $classificationFailure.sandbox_acl_evidence = [ordered]@{
                capture_status = 'pending'
                entries = @()
                captured_at_utc = $null
                normal_completion = $false
                continuation_allowed = $false
            }
            $null = Write-DispatchRunRecord -Record $classificationFailure -Update
            $actualStartChain = Resolve-PreviousDispatchRun -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug $classificationDispatch -ResumeThreadId $script:testThread
            $actualStartAclGate = Get-WorktreeAclGate -SourceRoot $phase9AclSourceRoot -ExecutionRoot $phase9AclExecutionRoot -WriteMode 'write' -ContinuationRecord $actualStartChain.LatestActualStartRecord
            $actualStartClassification = Get-DispatchRunRecordStartClassification -Record $actualStartChain.ChainTailRecord
            Assert-True ($actualStartClassification.classification -eq 'actual-start' -and $actualStartClassification.process_started -and $actualStartChain.LatestActualStartRecord.run_id -eq $classificationFailure.run_id -and $actualStartAclGate.status -eq 'continuation-denied') ('process_started=true 被靜默略過或未進入 ACL evidence gate：' + ($actualStartAclGate | ConvertTo-Json -Depth 20 -Compress))
            Write-Phase9Evidence -Label 'T003_ACTUAL_START_FAILURE_ACL_EVIDENCE_REQUIRED' -Value ([ordered]@{
                    classification = $actualStartClassification
                    latest_actual_start_run_id = $actualStartChain.LatestActualStartRecord.run_id
                    acl_gate = $actualStartAclGate
                })
        }
        finally {
            Set-Item -Path Function:\Get-WorktreeAclGate -Value $fixtureAclFunction
        }
    }

    Invoke-Case 'Phase 9 T007 ScopePlan 有序子集與 root witness 實證' {
        $scopeDispatch = 't007-scope-plan-subset'
        $scopeRoot = Join-Path $phase9Root 't007-scope'
        New-Item -ItemType Directory -Path $scopeRoot -Force | Out-Null
        $parentScopePath = Join-Path $scopeRoot 'parent-scope-plan.json'
        $parentRunId = [guid]::NewGuid().ToString('D')
        $parentScope = [pscustomobject]@{
            dispatch_slug = $scopeDispatch
            dispatch_kind = 'workflow'
            task_type = 'script-change'
            requested_profile = 'default'
            session_mode = 'cold-start'
            primary_remaining_percent = 80
            primary_reserve_percent = 30
            primary_budget_percent = 50
            estimate_percent = $null
            estimate_source = 'not-required-above-threshold'
            unit_kind = 'workflow-phase'
            requested_units = @('Phase 1', 'Phase 2', 'Phase 3', 'Phase 4', 'Phase 5')
            selected_units = @('Phase 1', 'Phase 2', 'Phase 3', 'Phase 4', 'Phase 5')
            deferred_units = @()
            decision = 'full'
            decision_reason = 'fixture parent ScopePlan'
            stop_after_selected_units = $false
            scope_plan_fingerprint = 'fixture-parent'
        }
        Write-Utf8NoBom -Path $parentScopePath -Content (($parentScope | ConvertTo-Json -Depth 30) + "`n")
        $scopeWitnessPath = Write-ScopePlanHashRecordIfMissing -SourceHistoryRoot $scopeRoot -DispatchSlug $scopeDispatch -LineSlug 'line-a' -ScopePlanPath $parentScopePath -RootRunId $parentRunId
        $witnessBefore = Get-FileSha256 -Path $scopeWitnessPath
        $childScope = New-ContinuationScopePlanSubset -ParentScopePlan $parentScope -RequestedUnits @('Phase 1', 'Phase 4') -ParentScopePlanPath $parentScopePath -ParentScopePlanSha256 (Get-FileSha256 -Path $parentScopePath) -ParentRunId $parentRunId
        $childScopePath = Join-Path $scopeRoot 'child-scope-plan.json'
        Write-Utf8NoBom -Path $childScopePath -Content (($childScope | ConvertTo-Json -Depth 30) + "`n")
        $witnessAfter = Get-FileSha256 -Path $scopeWitnessPath
        $witnessValidation = Test-ScopePlanHashRecord -SourceHistoryRoot $scopeRoot -DispatchSlug $scopeDispatch -LineSlug 'line-a' -ScopePlanPath $parentScopePath -ExpectedRootRunId $parentRunId

        $externalUnitError = $null
        try {
            $null = New-ContinuationScopePlanSubset -ParentScopePlan $parentScope -RequestedUnits @('Phase 1', 'Phase 9') -ParentScopePlanPath $parentScopePath -ParentScopePlanSha256 (Get-FileSha256 -Path $parentScopePath) -ParentRunId $parentRunId
        }
        catch {
            $externalUnitError = $_.Exception.Message
        }
        $reorderedUnitError = $null
        try {
            $null = New-ContinuationScopePlanSubset -ParentScopePlan $parentScope -RequestedUnits @('Phase 4', 'Phase 1') -ParentScopePlanPath $parentScopePath -ParentScopePlanSha256 (Get-FileSha256 -Path $parentScopePath) -ParentRunId $parentRunId
        }
        catch {
            $reorderedUnitError = $_.Exception.Message
        }
        $subsetEvidence = [ordered]@{
            parent_requested_units = @($parentScope.requested_units)
            child_requested_units = @($childScope.requested_units)
            child_selected_units = @($childScope.selected_units)
            child_deferred_units = @($childScope.deferred_units)
            child_selection = [string]$childScope.selection_classification
            child_parent_scope_plan_path = [string]$childScope.parent_scope_plan_path
            child_parent_run_id = [string]$childScope.parent_run_id
            startup_candidate = [ordered]@{
                valid = $childScope.decision -eq 'full' -and @($childScope.selected_units).Count -eq 2 -and @($childScope.deferred_units).Count -eq 0
                requested_unit_count = @($childScope.requested_units).Count
            }
            root_witness = [ordered]@{
                path = $scopeWitnessPath
                before_sha256 = $witnessBefore
                after_sha256 = $witnessAfter
                unchanged = $witnessBefore -ceq $witnessAfter
                validation = [bool]$witnessValidation
            }
            external_unit_rejection = $externalUnitError
            reordered_unit_rejection = $reorderedUnitError
        }
        Assert-True ($subsetEvidence.startup_candidate.valid -and (($subsetEvidence.child_requested_units -join ',') -ceq 'Phase 1,Phase 4') -and (($subsetEvidence.child_selected_units -join ',') -ceq 'Phase 1,Phase 4') -and $subsetEvidence.root_witness.unchanged -and $subsetEvidence.root_witness.validation -and $externalUnitError -match '不在父集合' -and $reorderedUnitError -match '宣告順序') ('T007 ScopePlan 子集驗證異常：' + ($subsetEvidence | ConvertTo-Json -Depth 30 -Compress))
        Write-Phase9Evidence -Label 'T007_SCOPE_PLAN_SUBSET_MATRIX' -Value $subsetEvidence
    }

    function Invoke-Phase9MutantProbe {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [scriptblock]$Action
        )

        try {
            & $Action | Out-Null
            return [pscustomobject]@{ detected = $false; error = $null }
        }
        catch {
            return [pscustomobject]@{ detected = $true; error = $_.Exception.Message }
        }
    }

    function New-Phase9CompleteScopePlan {
        [CmdletBinding()]
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

        return [pscustomobject]@{
            dispatch_slug = $DispatchSlug
            dispatch_kind = $DispatchKind
            task_type = $TaskType
            requested_profile = $RequestedProfile
            session_mode = $SessionMode
            primary_remaining_percent = 80
            primary_reserve_percent = 30
            primary_budget_percent = 50
            estimate_percent = $null
            estimate_source = 'not-required-above-threshold'
            unit_kind = $UnitKind
            requested_units = @($Units)
            selected_units = @($Units)
            deferred_units = @()
            decision = 'full'
            decision_reason = 'Phase 9 complete ScopePlan fixture.'
            calibration_sample_count = 0
            resolved_model = $null
            resolved_reasoning_effort = $null
            quota_state = 'Valid'
            quota_freshness = 'fresh'
            quota_observation_available = $true
            service_rejection = $null
            retry_allowed = $null
            stop_after_selected_units = $false
            authorization_source = $null
            activation_mode = 'none'
            activation_granted = $false
            activation_notice = ''
            advisor_hard_limit_percent = $null
            advisor_unit_estimate_percent = $null
            reserve_bypassed = $false
            minimum_unit_over_budget = $false
            scope_plan_fingerprint = 'phase9-complete-fixture'
        }
    }

    function Invoke-Phase9ScopeContinuationScenario {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ScenarioRoot,

            [Parameter(Mandatory)]
            [string]$ScenarioSlug,

            [Parameter(Mandatory)]
            [string[]]$RootUnits,

            [Parameter(Mandatory)]
            [string[]]$FirstSubsetUnits,

            [Parameter(Mandatory)]
            [string[]]$SecondSubsetUnits,

            [Parameter(Mandatory)]
            [string[]]$ExternalUnits
        )

        $lineSlug = 'line-a'
        $historyRoot = Join-Path $ScenarioRoot '.local\ai-sessions\history'
        $lineHistoryRoot = Join-Path $historyRoot $lineSlug
        $preflightPath = Join-Path $ScenarioRoot ($ScenarioSlug + '-preflight.json')
        $promptPath = Join-Path $ScenarioRoot ($ScenarioSlug + '-prompt.md')
        $quotaPath = Join-Path $ScenarioRoot ($ScenarioSlug + '-quota.json')
        $codexHome = Join-Path $ScenarioRoot ($ScenarioSlug + '-codex-home')
        New-Item -ItemType Directory -Path $lineHistoryRoot, $codexHome -Force | Out-Null
        Write-Utf8NoBom -Path $preflightPath -Content (([ordered]@{
                    sourceRoot = $ScenarioRoot
                    dispatchRoot = $ScenarioRoot
                    executionRoot = $ScenarioRoot
                    lineSlug = $lineSlug
                    dispatchSlug = $ScenarioSlug
                    writeMode = 'readonly'
                    dispatchKind = 'workflow'
                } | ConvertTo-Json -Depth 12) + "`n")
        Write-Utf8NoBom -Path $promptPath -Content ('Phase 9 ScopePlan continuation fixture: ' + $ScenarioSlug)
        Write-Utf8NoBom -Path (Join-Path $codexHome 'default.config.toml') -Content "model = 'fixture-model'`r`nmodel_reasoning_effort = 'high'`r`n"
        $null = New-Phase8QuotaSnapshot -Path $quotaPath -PrimaryRemainingPercent 80

        $script:testThread = [guid]::NewGuid().ToString('D')
        $script:quotaSnapshotPathOverride = $quotaPath
        $script:dispatchUnitListOverride = @($RootUnits)
        $script:pidResult = @{ ActiveRecords = @(); UnconfirmedRecords = @(); Blocked = $false; Reason = '' }
        $script:relayFailure = $false
        $script:failLaunch = $false
        $script:aclFixtureStatus = 'clean'
        $script:scopePlanFixtureDecision = 'full'
        $script:launcherFixtureFailure = $false
        $script:InvocationBoundParameters = [ordered]@{}
        $script:RequestContext = $null
        $script:RequestPrepareArtifacts = @()
        $script:SourceRoot = $ScenarioRoot
        $script:DispatchRoot = $ScenarioRoot
        $script:ExecutionRoot = $ScenarioRoot
        $script:LineSlug = $lineSlug
        $script:DispatchSlug = $ScenarioSlug
        $script:WriteMode = 'readonly'
        $script:PreflightResultPath = $preflightPath
        $script:PrepareResultPath = $null
        $script:PromptPath = $promptPath
        $script:CodexHome = $codexHome
        $script:CodexPath = 'fixture-codex'
        $script:TargetPath = @()
        $script:ResumeThreadId = $null
        $script:LastMessagePath = $null
        $script:QuotaBeforePath = $quotaPath
        $script:QuotaAfterPath = $null
        $script:CalibrationPath = $null
        $script:ScopePlanPath = $null
        $script:ResultPath = $null
        $script:RunRecordPath = $null
        $script:EventStreamPath = $null
        $script:ErrorStreamPath = $null
        $script:ThreadIdPath = $null
        $script:PidRecordPath = $null
        $script:Profile = 'default'
        $script:Model = $null
        $script:ReasoningEffort = $null
        $script:TaskType = 'script-change'
        $script:SessionMode = 'cold-start'
        $script:ContinueFromScopePlan = $false
        $script:DispatchKind = 'workflow'
        $script:UnitKind = 'workflow-phase'
        $script:RequestedUnit = @($RootUnits)
        $script:AddDirectory = @()
        $script:Search = $false
        $script:CodexParentOption = @()
        $script:EvidencePackPath = $null
        $script:AdvisorConsultReportPath = $null
        $script:AdvisorRequestSource = $null
        $script:BudgetMonitorPath = $null
        $script:RecoveryHandoffPath = $null
        $script:PrimaryBudgetPercent = 50
        $script:PrimaryReservePercent = 30
        $script:ProcessExitCode = $null
        $script:RequiredIdentifier = 'design.md'
        $script:DispatchStageBinding = $null

        $rootResult = @(Invoke-Start)[0]
        $rootRecord = Read-DispatchRunRecord -Path $rootResult.runRecordPath -SourceRoot $ScenarioRoot -ExecutionRoot $ScenarioRoot -LineSlug $lineSlug -DispatchSlug $ScenarioSlug
        $rootRecord.model_evidence.runtime_verifiable = New-ConfirmedDispatchEvidence -Value 'fixture-model' -Source 'rollout' -Field 'payload.model'
        $null = Write-DispatchRunRecord -Record $rootRecord -Update
        $rootRecord = Read-DispatchRunRecord -Path $rootResult.runRecordPath -SourceRoot $ScenarioRoot -ExecutionRoot $ScenarioRoot -LineSlug $lineSlug -DispatchSlug $ScenarioSlug
        Write-Utf8NoBom -Path $rootResult.lastMessagePath -Content 'Phase 9 root completed.'
        $rootWitnessPath = Get-ScopePlanHashRecordPath -SourceHistoryRoot $historyRoot -DispatchSlug $ScenarioSlug
        $rootWitnessBefore = Get-FileSha256 -Path $rootWitnessPath

        $script:dispatchUnitListOverride = @($FirstSubsetUnits)
        $script:RequestedUnit = @($FirstSubsetUnits)
        $script:SessionMode = 'continuation'
        $script:ContinueFromScopePlan = $true
        $script:ResumeThreadId = $rootResult.threadId
        $script:ScopePlanPath = $rootResult.scopePlanPath
        $script:LastMessagePath = $rootResult.lastMessagePath
        $firstResult = @(Invoke-Start)[0]
        $firstRecord = Read-DispatchRunRecord -Path $firstResult.runRecordPath -SourceRoot $ScenarioRoot -ExecutionRoot $ScenarioRoot -LineSlug $lineSlug -DispatchSlug $ScenarioSlug
        $firstRecord.model_evidence.runtime_verifiable = New-ConfirmedDispatchEvidence -Value 'fixture-model' -Source 'rollout' -Field 'payload.model'
        $null = Write-DispatchRunRecord -Record $firstRecord -Update
        $firstRecord = Read-DispatchRunRecord -Path $firstResult.runRecordPath -SourceRoot $ScenarioRoot -ExecutionRoot $ScenarioRoot -LineSlug $lineSlug -DispatchSlug $ScenarioSlug
        Write-Utf8NoBom -Path $firstResult.lastMessagePath -Content 'Phase 9 first subset completed.'

        $script:dispatchUnitListOverride = @($SecondSubsetUnits)
        $script:RequestedUnit = @($SecondSubsetUnits)
        $script:ResumeThreadId = $firstResult.threadId
        $script:ScopePlanPath = $firstResult.scopePlanPath
        $script:LastMessagePath = $firstResult.lastMessagePath
        $secondResult = @(Invoke-Start)[0]
        $secondRecord = Read-DispatchRunRecord -Path $secondResult.runRecordPath -SourceRoot $ScenarioRoot -ExecutionRoot $ScenarioRoot -LineSlug $lineSlug -DispatchSlug $ScenarioSlug
        $secondRecord.model_evidence.runtime_verifiable = New-ConfirmedDispatchEvidence -Value 'fixture-model' -Source 'rollout' -Field 'payload.model'
        $null = Write-DispatchRunRecord -Record $secondRecord -Update
        $secondRecord = Read-DispatchRunRecord -Path $secondResult.runRecordPath -SourceRoot $ScenarioRoot -ExecutionRoot $ScenarioRoot -LineSlug $lineSlug -DispatchSlug $ScenarioSlug
        Write-Utf8NoBom -Path $secondResult.lastMessagePath -Content 'Phase 9 second subset completed.'

        $script:dispatchUnitListOverride = @($ExternalUnits)
        $script:RequestedUnit = @($ExternalUnits)
        $script:ResumeThreadId = $secondResult.threadId
        $script:ScopePlanPath = $secondResult.scopePlanPath
        $script:LastMessagePath = $secondResult.lastMessagePath
        $externalError = $null
        try {
            $null = Invoke-Start
        }
        catch {
            $externalError = $_.Exception.Message
        }
        $rootWitnessAfter = Get-FileSha256 -Path $rootWitnessPath

        $scenarioResult = [pscustomobject]@{
            root_result = $rootResult
            root_record = $rootRecord
            first_result = $firstResult
            first_record = $firstRecord
            second_result = $secondResult
            second_record = $secondRecord
            external_error = $externalError
            witness = [ordered]@{
                path = $rootWitnessPath
                before_sha256 = $rootWitnessBefore
                after_sha256 = $rootWitnessAfter
                unchanged = $rootWitnessBefore -ceq $rootWitnessAfter
            }
        }
        $script:ContinueFromScopePlan = $false
        $script:ResumeThreadId = $null
        $script:ScopePlanPath = $null
        $script:LastMessagePath = $null
        $script:SessionMode = 'cold-start'
        $script:RequestedUnit = @($RootUnits)
        $script:dispatchUnitListOverride = @($RootUnits)
        return $scenarioResult
    }

    Invoke-Case 'Phase 9 T007/T008 兩輪 ScopePlan 子集續行與 RunRecord 綁定' {
        $scenarioFunctionNames = @('New-ScopePlan', 'Test-ContinuationScopePlan', 'Invoke-Start')
        $scenarioOriginalFunctions = @{}
        foreach ($functionName in $scenarioFunctionNames) {
            $scenarioOriginalFunctions[$functionName] = (Get-Command -Name $functionName -CommandType Function -ErrorAction Stop).ScriptBlock
        }
        $productionStartFunction = $phase9ProductionFunctionDefinitions['Invoke-Start']
        $completeScopePlanFunction = Get-Command -Name New-Phase9CompleteScopePlan -CommandType Function -ErrorAction Stop
        try {
            Set-Item -Path Function:\New-ScopePlan -Value $completeScopePlanFunction.ScriptBlock
            Set-Item -Path Function:\Test-ContinuationScopePlan -Value $phase9ProductionFunctionDefinitions['Test-ContinuationScopePlan']
            Set-Item -Path Function:\Invoke-Start -Value $productionStartFunction
            $scenario = Invoke-Phase9ScopeContinuationScenario -ScenarioRoot $fixtureRoot -ScenarioSlug ('t007-two-round-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) -RootUnits @('Phase 1', 'Phase 2', 'Phase 3', 'Phase 4', 'Phase 5') -FirstSubsetUnits @('Phase 1', 'Phase 3', 'Phase 5') -SecondSubsetUnits @('Phase 3') -ExternalUnits @('Phase 2')
            $firstEvidence = [ordered]@{
                status = if ($scenario.first_result.processStarted) { 'PASS' } else { 'FAIL' }
                parent_requested_units = @($scenario.root_record.scope_plan_path | ForEach-Object { (Get-Content -LiteralPath $_ -Raw -Encoding UTF8 | ConvertFrom-Json).requested_units })
                child_requested_units = @((Get-Content -LiteralPath $scenario.first_record.scope_plan_path -Raw -Encoding UTF8 | ConvertFrom-Json).requested_units)
                child_selected_units = @((Get-Content -LiteralPath $scenario.first_record.scope_plan_path -Raw -Encoding UTF8 | ConvertFrom-Json).selected_units)
                process_started = [bool]$scenario.first_result.processStarted
                parent_scope_plan_path = [string]$scenario.first_record.scope_plan_parent_path
                parent_scope_plan_sha256 = [string]$scenario.first_record.scope_plan_parent_sha256
                parent_run_id = [string]$scenario.first_record.scope_plan_parent_run_id
                selection_classification = [string]$scenario.first_record.scope_plan_selection
            }
            $secondScope = Get-Content -LiteralPath $scenario.second_record.scope_plan_path -Raw -Encoding UTF8 | ConvertFrom-Json
            $secondEvidence = [ordered]@{
                status = if ($scenario.second_result.processStarted) { 'PASS' } else { 'FAIL' }
                parent_requested_units = @((Get-Content -LiteralPath $scenario.first_record.scope_plan_path -Raw -Encoding UTF8 | ConvertFrom-Json).requested_units)
                child_requested_units = @($secondScope.requested_units)
                child_selected_units = @($secondScope.selected_units)
                process_started = [bool]$scenario.second_result.processStarted
                parent_scope_plan_path = [string]$scenario.second_record.scope_plan_parent_path
                parent_scope_plan_sha256 = [string]$scenario.second_record.scope_plan_parent_sha256
                parent_run_id = [string]$scenario.second_record.scope_plan_parent_run_id
                selection_classification = [string]$scenario.second_record.scope_plan_selection
            }
            $externalEvidence = [ordered]@{
                status = if ([string]$scenario.external_error -match '不在父集合') { 'PASS' } else { 'FAIL' }
                declared_units = @('Phase 2')
                first_subset_units = @($firstEvidence.child_requested_units)
                outside_first_subset = @($firstEvidence.child_requested_units) -notcontains 'Phase 2'
                parent_units = @($secondEvidence.parent_requested_units)
                rejection = [string]$scenario.external_error
            }
            $duplicateError = $null
            try {
                $parentObject = Get-Content -LiteralPath $scenario.first_record.scope_plan_path -Raw -Encoding UTF8 | ConvertFrom-Json
                $null = New-ContinuationScopePlanSubset -ParentScopePlan $parentObject -RequestedUnits @('Phase 1', 'Phase 1') -ParentScopePlanPath $scenario.first_record.scope_plan_path -ParentScopePlanSha256 $scenario.first_record.scope_plan_sha256 -ParentRunId $scenario.first_record.run_id
            }
            catch {
                $duplicateError = $_.Exception.Message
            }
            Assert-True ($firstEvidence.status -eq 'PASS' -and (($firstEvidence.child_requested_units -join ',') -ceq 'Phase 1,Phase 3,Phase 5') -and $firstEvidence.selection_classification -eq 'subset' -and $firstEvidence.parent_run_id -eq $scenario.root_record.run_id) ('第一輪 5→3 子集續行或 RunRecord 綁定失敗：' + ($firstEvidence | ConvertTo-Json -Depth 30 -Compress))
            Assert-True ($secondEvidence.status -eq 'PASS' -and (($secondEvidence.parent_requested_units -join ',') -ceq 'Phase 1,Phase 3,Phase 5') -and (($secondEvidence.child_requested_units -join ',') -ceq 'Phase 3') -and $secondEvidence.selection_classification -eq 'subset' -and $secondEvidence.parent_run_id -eq $scenario.first_record.run_id) ('第二輪 3→1 子集續行或 RunRecord 綁定失敗：' + ($secondEvidence | ConvertTo-Json -Depth 30 -Compress))
            Assert-True ($externalEvidence.status -eq 'PASS' -and $externalEvidence.outside_first_subset -and $duplicateError -match '不可重複' -and $scenario.witness.unchanged) ('子集外部單位、重複單位或 root witness 驗證失敗：' + ($externalEvidence | ConvertTo-Json -Depth 30 -Compress) + '; duplicate=' + [string]$duplicateError + '; witness=' + ($scenario.witness | ConvertTo-Json -Depth 10 -Compress))

            $t008MutantDefinition = $productionStartFunction.ToString()
            foreach ($replacement in @(
                    [pscustomobject]@{ original = '$runRecord.scope_plan_parent_path = $scopePlanParentPathValue'; mutant = '$runRecord.scope_plan_parent_path = $null' }
                    [pscustomobject]@{ original = '$runRecord.scope_plan_parent_sha256 = $scopePlanParentSha256Value'; mutant = '$runRecord.scope_plan_parent_sha256 = $null' }
                    [pscustomobject]@{ original = '$runRecord.scope_plan_parent_run_id = $scopePlanParentRunIdValue'; mutant = '$runRecord.scope_plan_parent_run_id = $null' }
                    [pscustomobject]@{ original = '$runRecord.scope_plan_selection = $scopePlanSelectionValue'; mutant = '$runRecord.scope_plan_selection = ''root''' }
                )) {
                Assert-True ($t008MutantDefinition.Contains($replacement.original)) ('T008 無法建立 RunRecord 綁定 mutant：' + $replacement.original)
                $t008MutantDefinition = $t008MutantDefinition.Replace($replacement.original, $replacement.mutant)
            }
            $t008MutantProbe = $null
            try {
                Set-Item -Path Function:\Invoke-Start -Value ([scriptblock]::Create($t008MutantDefinition))
                $t008MutantProbe = Invoke-Phase9MutantProbe {
                    $mutantScenario = Invoke-Phase9ScopeContinuationScenario -ScenarioRoot $fixtureRoot -ScenarioSlug ('t008-binding-mutant-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) -RootUnits @('Phase 1', 'Phase 2', 'Phase 3', 'Phase 4', 'Phase 5') -FirstSubsetUnits @('Phase 1', 'Phase 3', 'Phase 5') -SecondSubsetUnits @('Phase 3') -ExternalUnits @('Phase 2')
                    $mutantRecord = $mutantScenario.first_record
                    Assert-True ([string]$mutantRecord.scope_plan_parent_path -eq [string]$scenario.first_record.scope_plan_parent_path -and [string]$mutantRecord.scope_plan_parent_sha256 -eq [string]$scenario.first_record.scope_plan_parent_sha256 -and [string]$mutantRecord.scope_plan_parent_run_id -eq [string]$scenario.first_record.scope_plan_parent_run_id -and [string]$mutantRecord.scope_plan_selection -eq [string]$scenario.first_record.scope_plan_selection) 'T008 RunRecord 父計畫綁定 mutant 未被鑑別。'
                }
            }
            finally {
                Set-Item -Path Function:\Invoke-Start -Value $productionStartFunction
            }
            Assert-True ($t008MutantProbe.detected) ('T008 RunRecord 父計畫綁定 mutant 未被鑑別：' + ($t008MutantProbe | ConvertTo-Json -Depth 10 -Compress))
            $t008RestoredScenario = Invoke-Phase9ScopeContinuationScenario -ScenarioRoot $fixtureRoot -ScenarioSlug ('t008-binding-restored-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) -RootUnits @('Phase 1', 'Phase 2', 'Phase 3', 'Phase 4', 'Phase 5') -FirstSubsetUnits @('Phase 1', 'Phase 3', 'Phase 5') -SecondSubsetUnits @('Phase 3') -ExternalUnits @('Phase 2')
            $t008RestoredScope = Get-Content -LiteralPath $t008RestoredScenario.first_record.scope_plan_path -Raw -Encoding UTF8 | ConvertFrom-Json
            $t008RestoredBinding = [ordered]@{
                parent_scope_plan_path = [string]$t008RestoredScenario.first_record.scope_plan_parent_path
                parent_scope_plan_sha256 = [string]$t008RestoredScenario.first_record.scope_plan_parent_sha256
                parent_run_id = [string]$t008RestoredScenario.first_record.scope_plan_parent_run_id
                selection_classification = [string]$t008RestoredScenario.first_record.scope_plan_selection
                process_started = [bool]$t008RestoredScenario.first_result.processStarted
            }
            $t008RestoredParentHash = Get-FileSha256 -Path $t008RestoredBinding.parent_scope_plan_path
            Assert-True ($t008RestoredBinding.process_started -and [string]$t008RestoredBinding.parent_scope_plan_path -eq [string]$t008RestoredScope.parent_scope_plan_path -and [string]$t008RestoredBinding.parent_scope_plan_sha256 -eq [string]$t008RestoredScope.parent_scope_plan_sha256 -and [string]$t008RestoredBinding.parent_scope_plan_sha256 -eq $t008RestoredParentHash -and [string]$t008RestoredBinding.parent_run_id -eq [string]$t008RestoredScenario.root_record.run_id -and $t008RestoredBinding.selection_classification -eq 'subset') ('T008 還原後 RunRecord 父計畫綁定不完整：' + ($t008RestoredBinding | ConvertTo-Json -Depth 10 -Compress))
            Write-Phase9Evidence -Label 'T007_FIRST_SUBSET_5_TO_3' -Value $firstEvidence
            Write-Phase9Evidence -Label 'T007_SECOND_SUBSET_3_TO_1' -Value $secondEvidence
            Write-Phase9Evidence -Label 'T007_EXTERNAL_AND_DUPLICATE_REJECTION' -Value ([ordered]@{ external = $externalEvidence; duplicate_rejection = $duplicateError; root_witness = $scenario.witness })
            Write-Phase9Evidence -Label 'T008_RUN_RECORD_SCOPE_BINDING' -Value ([ordered]@{ first = $firstEvidence; second = $secondEvidence; mutant = $t008MutantProbe; restored = $t008RestoredBinding })
        }
        finally {
            foreach ($functionName in $scenarioFunctionNames) {
                Set-Item -Path ('Function:' + $functionName) -Value $scenarioOriginalFunctions[$functionName]
            }
        }
    }

    Invoke-Case 'Phase 9 F-002 T001 至 T005 mutant 鑑別' {
        $t001BaseDocument = [ordered]@{
            schema = 'ai-sessions.dispatch-request.v1'
            operation = 'Preflight'
            line_slug = 'line-a'
            dispatch_slug = 'phase9-t001'
        }
        $collectT001Matrix = {
            $matrix = [ordered]@{}
            foreach ($field in @('schema', 'operation', 'line_slug', 'dispatch_slug')) {
                $missingDocument = $t001BaseDocument | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                $missingDocument.PSObject.Properties.Remove($field)
                $missingPath = Join-Path $phase9Root ('t001-missing-' + $field + '-' + [guid]::NewGuid().ToString('N') + '.json')
                Write-Utf8NoBom -Path $missingPath -Content (($missingDocument | ConvertTo-Json -Depth 20) + "`n")
                $missingFailure = $null
                try { $null = Read-DispatchRequest -Path $missingPath } catch { [void]($missingFailure = $_.Exception.Data['operationResult']) }

                $nullDocument = $t001BaseDocument | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                $nullDocument.PSObject.Properties[$field].Value = $null
                $nullPath = Join-Path $phase9Root ('t001-null-' + $field + '-' + [guid]::NewGuid().ToString('N') + '.json')
                Write-Utf8NoBom -Path $nullPath -Content (($nullDocument | ConvertTo-Json -Depth 20) + "`n")
                $nullFailure = $null
                try { $null = Read-DispatchRequest -Path $nullPath } catch { [void]($nullFailure = $_.Exception.Data['operationResult']) }

                $missingShape = if ($null -eq $missingFailure) { '' } else { $missingFailure | Select-Object code, error_code, reason_code, field, process_started, output_valid, detail | ConvertTo-Json -Depth 20 -Compress }
                $nullShape = if ($null -eq $nullFailure) { '' } else { $nullFailure | Select-Object code, error_code, reason_code, field, process_started, output_valid, detail | ConvertTo-Json -Depth 20 -Compress }
                $matrix[$field] = [ordered]@{
                    missing = $missingFailure
                    explicit_null = $nullFailure
                    same_error_shape = $missingShape -ceq $nullShape
                }
            }
            return $matrix
        }
        $t001Before = & $collectT001Matrix
        $t001RequiredOriginal = (Get-Command -Name Assert-DispatchRequestRequiredField -CommandType Function -ErrorAction Stop).ScriptBlock
        $t001ValueCheck = '$null -eq $property -or $null -eq $property.Value'
        $t001MissingOnlyCheck = '$null -eq $property'
        $t001MutantDefinition = $t001RequiredOriginal.ToString().Replace($t001ValueCheck, $t001MissingOnlyCheck)
        Assert-True ($t001MutantDefinition -cne $t001RequiredOriginal.ToString()) 'T001 無法建立僅檢查缺漏欄位的 mutant。'
        $t001MutantRequired = [scriptblock]::Create($t001MutantDefinition)
        $t001Probe = Invoke-Phase9MutantProbe {
            $nullDocument = [pscustomobject]@{ schema = $null }
            $mutantFailure = $null
            try { & $t001MutantRequired -Document $nullDocument -Name 'schema' -RequestPathValue 't001-mutant.json' } catch { $mutantFailure = $_ }
            Assert-True ($null -ne $mutantFailure) 'T001 missing-only mutant 接受顯式 null。'
        }
        $t001After = & $collectT001Matrix
        foreach ($field in $t001After.Keys) {
            Assert-True ($t001After[$field].missing.code -eq 'DispatchRequestMissingField' -and $t001After[$field].explicit_null.code -eq 'DispatchRequestMissingField' -and $t001After[$field].same_error_shape) ('T001 null／missing 錯誤形狀不一致：' + $field)
        }
        Assert-True ($t001Probe.detected) ('T001 null／missing mutant 未被鑑別：' + ($t001Probe | ConvertTo-Json -Depth 10 -Compress))

        $t002PromptPath = Join-Path $phase9Root 't002-prompt.md'
        Write-Utf8NoBom -Path $t002PromptPath -Content 'T002 fixture prompt.'
        $t002RequestPath = Join-Path $phase9Root 't002-request.json'
        $t002Document = [ordered]@{
            schema = 'ai-sessions.dispatch-request.v1'
            operation = 'Dispatch'
            line_slug = 'line-a'
            dispatch_slug = 'phase9-t002'
            source_root = $fixtureRoot
            dispatch_root = $fixtureRoot
            write_mode = 'readonly'
            dispatch_kind = 'workflow'
            target_path = @()
            prepare_artifacts = @()
            prompt_path = $t002PromptPath
            task_type = 'script-change'
            session_mode = 'continuation'
            unit_kind = 'workflow-phase'
            requested_unit = @('Phase 1')
            failure_receipt_path = (Join-Path $phase9Root 't002-failure.json')
            continue_from_scope_plan = $true
        }
        Write-Utf8NoBom -Path $t002RequestPath -Content (($t002Document | ConvertTo-Json -Depth 20) + "`n")
        $invokeT002Mismatch = {
            $script:RequestPath = $t002RequestPath
            $script:InvocationBoundParameters = [ordered]@{ Operation = 'Dispatch'; ContinueFromScopePlan = $false }
            $script:Operation = 'Dispatch'
            $failure = $null
            try { $null = Apply-DispatchRequest } catch { $failure = $_.Exception.Data['operationResult'] }
            return $failure
        }
        $t002Before = & $invokeT002Mismatch
        $t002BooleanOriginal = (Get-Command -Name Apply-DispatchRequestBooleanField -CommandType Function -ErrorAction Stop).ScriptBlock
        $t002Probe = $null
        try {
            Set-Item -Path Function:\Apply-DispatchRequestBooleanField -Value ([scriptblock]::Create("param([System.Collections.IDictionary]`$Context, [string]`$CliField, [string]`$RequestField) if ([bool]`$Context.dispatch_field_presence[`$RequestField]) { Set-Variable -Name `$CliField -Scope Script -Value ([bool]`$Context.dispatch_values[`$RequestField]) }"))
            $t002Probe = Invoke-Phase9MutantProbe {
                $failure = & $invokeT002Mismatch
                Assert-True ($null -ne $failure -and $failure.code -eq 'DispatchRequestMismatch' -and $failure.field -eq 'continue_from_scope_plan') 'T002 mismatch mutant 未被鑑別。'
            }
        }
        finally {
            Set-Item -Path Function:\Apply-DispatchRequestBooleanField -Value $t002BooleanOriginal
        }
        $t002After = & $invokeT002Mismatch
        Assert-True ($null -ne $t002Before -and $t002Before.code -eq 'DispatchRequestMismatch' -and $t002Before.field -eq 'continue_from_scope_plan' -and $null -ne $t002After -and $t002After.code -eq 'DispatchRequestMismatch' -and $t002Probe.detected) ('T002 continue_from_scope_plan／命令列 switch 鑑別失敗。')

        $t003Records = [ordered]@{}
        $t003Records.missing = [pscustomobject]@{ launch_state = 'launch-failed'; failure = [pscustomobject]@{ phase = 'preparation'; observation = [pscustomobject]@{ failure_stage = 'preparation' } } }
        $t003Records.non_boolean = [pscustomobject]@{ launch_state = 'launch-failed'; failure = [pscustomobject]@{ phase = 'preparation'; observation = [pscustomobject]@{ process_started = 'false'; failure_stage = 'preparation' } } }
        $t003Records.phase_conflict = [pscustomobject]@{ launch_state = 'launch-failed'; failure = [pscustomobject]@{ phase = 'execution'; observation = [pscustomobject]@{ process_started = $false; failure_stage = 'preparation' } } }
        $t003Classify = {
            $result = [ordered]@{}
            foreach ($name in $t003Records.Keys) { $result[$name] = Get-DispatchRunRecordStartClassification -Record $t003Records[$name] }
            return $result
        }
        $t003Before = & $t003Classify
        $t003ClassifierOriginal = (Get-Command -Name Get-DispatchRunRecordStartClassification -CommandType Function -ErrorAction Stop).ScriptBlock
        $t003Probe = $null
        try {
            Set-Item -Path Function:\Get-DispatchRunRecordStartClassification -Value ([scriptblock]::Create("param([psobject]`$Record) return [pscustomobject]@{ classification = 'unstarted-sandbox'; reason = 'T003 mutant'; process_started = `$false; phase = 'preparation'; failure_stage = 'preparation' }"))
            $t003Probe = Invoke-Phase9MutantProbe {
                $mutantResults = & $t003Classify
                foreach ($name in $mutantResults.Keys) { Assert-True ($mutantResults[$name].classification -eq 'unknown') ('T003 unknown mutant 未被鑑別：' + $name) }
            }
        }
        finally {
            Set-Item -Path Function:\Get-DispatchRunRecordStartClassification -Value $t003ClassifierOriginal
        }
        $t003After = & $t003Classify
        Assert-True (@($t003After.Values | Where-Object { $_.classification -ne 'unknown' }).Count -eq 0 -and $t003Probe.detected) ('T003 三種 unknown 情境或 mutant 鑑別失敗：' + ($t003After | ConvertTo-Json -Depth 20 -Compress))

        $t004OldMode = $script:SessionMode
        $t004OldContext = $script:RequestContext
        $t004Invoke = {
            $script:SessionMode = 'illegal-session-mode'
            $script:RequestContext = $null
            $message = ''
            try { Assert-DispatchSessionMode } catch { $message = $_.Exception.Message }
            return $message
        }
        $t004Before = & $t004Invoke
        $t004Original = (Get-Command -Name Assert-DispatchSessionMode -CommandType Function -ErrorAction Stop).ScriptBlock
        $t004Probe = $null
        try {
            Set-Item -Path Function:\Assert-DispatchSessionMode -Value ([scriptblock]::Create("throw 'illegal session mode'"))
            $t004Probe = Invoke-Phase9MutantProbe {
                $message = & $t004Invoke
                Assert-True ($message.Contains('received=illegal-session-mode') -and $message.Contains('valid_values=cold-start, continuation')) 'T004 invalid SessionMode 錯誤內容 mutant 未被鑑別。'
            }
        }
        finally {
            Set-Item -Path Function:\Assert-DispatchSessionMode -Value $t004Original
        }
        $t004After = & $t004Invoke
        $script:SessionMode = $t004OldMode
        $script:RequestContext = $t004OldContext
        Assert-True ($t004After.Contains('received=illegal-session-mode') -and $t004After.Contains('valid_values=cold-start, continuation') -and $t004Probe.detected) ('T004 invalid SessionMode 錯誤未保留 received 與合法集合。')

        $t005Dispatch = 'phase9-t005-no-actual-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $t005Record = New-TestRun -Line 'line-a' -Dispatch $t005Dispatch
        $t005Record.launch_state = 'launch-failed'
        $t005Record.started_at_utc = $null
        $t005Record.failure = New-DispatchFailureRecord -Phase 'preparation' -Message 'T005 no actual start fixture' -ReasonCode 'T005Fixture' -ProcessStarted $false -EventPath $t005Record.event_stream_path -ErrorPath $null -LastMessagePath $t005Record.last_message_path -ThreadPath $null -PidPath $t005Record.pid_record_path -LauncherPath $null -RolloutPaths @() -Observation ([ordered]@{ process_started = $false; process_exit_code = $null; failure_stage = 'preparation' })
        $null = Write-DispatchRunRecord -Record $t005Record -Update
        $t005Resume = @{ SourceRoot = $fixtureRoot; ExecutionRoot = $fixtureRoot; LineSlug = 'line-a'; DispatchSlug = $t005Dispatch; ResumeThreadId = $script:testThread; LastMessagePath = $null }
        $t005Invoke = {
            $failure = $null
            try { $null = Resolve-PreviousDispatchRun @t005Resume } catch { $failure = $_.Exception.Message }
            return $failure
        }
        $t005Before = & $t005Invoke
        $t005ClassifierOriginal = (Get-Command -Name Get-DispatchRunRecordStartClassification -CommandType Function -ErrorAction Stop).ScriptBlock
        $t005Probe = $null
        try {
            Set-Item -Path Function:\Get-DispatchRunRecordStartClassification -Value ([scriptblock]::Create("param([psobject]`$Record) return [pscustomobject]@{ classification = 'actual-start'; reason = 'T005 mutant'; process_started = `$true; phase = 'preparation'; failure_stage = 'preparation' }"))
            $t005Probe = Invoke-Phase9MutantProbe {
                $failure = & $t005Invoke
                Assert-True (-not [string]::IsNullOrWhiteSpace($failure) -and $failure.Contains('NoValidResumeAnchor')) 'T005 no-actual-start mutant 未被鑑別。'
            }
        }
        finally {
            Set-Item -Path Function:\Get-DispatchRunRecordStartClassification -Value $t005ClassifierOriginal
        }
        $t005After = & $t005Invoke
        Assert-True ($t005Before -match 'NoValidResumeAnchor' -and $t005After -match 'NoValidResumeAnchor' -and $t005Probe.detected) ('T005 no-actual-start 續行拒絕或 mutant 鑑別失敗：' + [string]$t005After)

        Write-Phase9Evidence -Label 'F002_T001_TO_T005_MUTANT_MATRIX' -Value ([ordered]@{
                T001 = [ordered]@{ before = $t001Before; mutant = $t001Probe; restored = $t001After }
                T002 = [ordered]@{ before = $t002Before; mutant = $t002Probe; restored = $t002After }
                T003 = [ordered]@{ before = $t003Before; mutant = $t003Probe; restored = $t003After }
                T004 = [ordered]@{ before = $t004Before; mutant = $t004Probe; restored = $t004After }
                T005 = [ordered]@{ before = $t005Before; mutant = $t005Probe; restored = $t005After }
            })
    }

    Invoke-Case 'Phase 9 F-002 T007 duplicate mutant 鑑別' {
        $parent = New-Phase9CompleteScopePlan -DispatchSlug 'phase9-t007-mutant' -DispatchKind 'workflow' -TaskType 'script-change' -RequestedProfile 'default' -SessionMode 'cold-start' -BeforeSnapshot ([pscustomobject]@{}) -Units @('Phase 1', 'Phase 2', 'Phase 3', 'Phase 4', 'Phase 5') -UnitKind 'workflow-phase'
        $parentPath = Join-Path $phase9Root 't007-mutant-parent.json'
        Write-Utf8NoBom -Path $parentPath -Content (($parent | ConvertTo-Json -Depth 30) + "`n")
        $parentHash = Get-FileSha256 -Path $parentPath
        $invalidRequests = @(
            [pscustomobject]@{ name = 'duplicate'; units = @('Phase 1', 'Phase 1'); pattern = '不可重複' }
            [pscustomobject]@{ name = 'external'; units = @('Phase 1', 'Phase 9'); pattern = '不在父集合' }
            [pscustomobject]@{ name = 'reordered'; units = @('Phase 3', 'Phase 1'); pattern = '宣告順序' }
        )
        $invokeInvalid = {
            $results = @()
            foreach ($request in $invalidRequests) {
                $message = ''
                try { $null = New-ContinuationScopePlanSubset -ParentScopePlan $parent -RequestedUnits $request.units -ParentScopePlanPath $parentPath -ParentScopePlanSha256 $parentHash -ParentRunId ([guid]::NewGuid().ToString('D')) } catch { $message = $_.Exception.Message }
                $results += [pscustomobject]@{ name = $request.name; message = $message; rejected = $message -match $request.pattern }
            }
            return $results
        }
        $before = & $invokeInvalid
        $original = (Get-Command -Name New-ContinuationScopePlanSubset -CommandType Function -ErrorAction Stop).ScriptBlock
        $probe = $null
        try {
            Set-Item -Path Function:\New-ContinuationScopePlanSubset -Value ([scriptblock]::Create("param([psobject]`$ParentScopePlan, [string[]]`$RequestedUnits, [string]`$ParentScopePlanPath, [string]`$ParentScopePlanSha256, [string]`$ParentRunId) return `$ParentScopePlan"))
            $probe = Invoke-Phase9MutantProbe {
                $mutantResults = & $invokeInvalid
                foreach ($item in $mutantResults) { Assert-True $item.rejected ('T007 invalid subset mutant 未被鑑別：' + $item.name) }
            }
        }
        finally {
            Set-Item -Path Function:\New-ContinuationScopePlanSubset -Value $original
        }
        $restored = & $invokeInvalid
        Assert-True (@($restored | Where-Object { -not $_.rejected }).Count -eq 0 -and $probe.detected) ('T007 duplicate／external／reordered mutant 鑑別失敗：' + ($restored | ConvertTo-Json -Depth 20 -Compress))
        Write-Phase9Evidence -Label 'F002_T007_INVALID_SUBSET_MUTANT' -Value ([ordered]@{ before = $before; mutant = $probe; restored = $restored })
    }

    Invoke-Case 'Phase 9 F-003 cold-start 重試沿用 root witness 後續行' {
        $dispatchSlug = 't003-cold-retry-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $preflightPath = Join-Path $fixtureRoot ($dispatchSlug + '-preflight.json')
        $promptPath = Join-Path $fixtureRoot ($dispatchSlug + '-prompt.md')
        $quotaPath = Join-Path $fixtureRoot ($dispatchSlug + '-quota.json')
        $codexHome = Join-Path $fixtureRoot ($dispatchSlug + '-codex-home')
        Write-Utf8NoBom -Path $preflightPath -Content (([ordered]@{
                    sourceRoot = $fixtureRoot
                    dispatchRoot = $fixtureRoot
                    executionRoot = $fixtureRoot
                    lineSlug = 'line-a'
                    dispatchSlug = $dispatchSlug
                    writeMode = 'readonly'
                    dispatchKind = 'workflow'
                } | ConvertTo-Json -Depth 12) + "`n")
        Write-Utf8NoBom -Path $promptPath -Content 'Phase 9 cold-start retry fixture.'
        New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
        Write-Utf8NoBom -Path (Join-Path $codexHome 'default.config.toml') -Content "model = 'fixture-model'`r`nmodel_reasoning_effort = 'high'`r`n"
        $null = New-Phase8QuotaSnapshot -Path $quotaPath -PrimaryRemainingPercent 80

        $script:testThread = [guid]::NewGuid().ToString('D')
        $script:quotaSnapshotPathOverride = $quotaPath
        $script:dispatchUnitListOverride = @('Phase 1')
        $script:pidResult = @{ ActiveRecords = @(); UnconfirmedRecords = @(); Blocked = $false; Reason = '' }
        $script:relayFailure = $false
        $script:failLaunch = $false
        $script:aclFixtureStatus = 'clean'
        $script:scopePlanFixtureDecision = 'full'
        $script:launcherFixtureFailure = $true
        $script:InvocationBoundParameters = [ordered]@{}
        $script:RequestContext = $null
        $script:RequestPrepareArtifacts = @()
        $script:SourceRoot = $fixtureRoot
        $script:DispatchRoot = $fixtureRoot
        $script:ExecutionRoot = $fixtureRoot
        $script:LineSlug = 'line-a'
        $script:DispatchSlug = $dispatchSlug
        $script:WriteMode = 'readonly'
        $script:PreflightResultPath = $preflightPath
        $script:PrepareResultPath = $null
        $script:PromptPath = $promptPath
        $script:CodexHome = $codexHome
        $script:CodexPath = 'fixture-codex'
        $script:TargetPath = @()
        $script:ResumeThreadId = $null
        $script:LastMessagePath = $null
        $script:QuotaBeforePath = $quotaPath
        $script:QuotaAfterPath = $null
        $script:CalibrationPath = $null
        $script:ScopePlanPath = $null
        $script:ResultPath = $null
        $script:RunRecordPath = $null
        $script:EventStreamPath = $null
        $script:ErrorStreamPath = $null
        $script:ThreadIdPath = $null
        $script:PidRecordPath = $null
        $script:Profile = 'default'
        $script:Model = $null
        $script:ReasoningEffort = $null
        $script:TaskType = 'script-change'
        $script:SessionMode = 'cold-start'
        $script:ContinueFromScopePlan = $false
        $script:DispatchKind = 'workflow'
        $script:UnitKind = 'workflow-phase'
        $script:RequestedUnit = @('Phase 1')
        $script:AddDirectory = @()
        $script:Search = $false
        $script:CodexParentOption = @()
        $script:EvidencePackPath = $null
        $script:AdvisorConsultReportPath = $null
        $script:AdvisorRequestSource = $null
        $script:BudgetMonitorPath = $null
        $script:RecoveryHandoffPath = $null
        $script:PrimaryBudgetPercent = 50
        $script:PrimaryReservePercent = 30
        $script:ProcessExitCode = $null
        $script:RequiredIdentifier = 'design.md'
        $script:DispatchStageBinding = $null

        $firstException = $null
        try {
            $null = Invoke-Start
        }
        catch {
            $firstException = $_.Exception
        }
        finally {
            $script:launcherFixtureFailure = $false
        }
        $firstRecordPath = @(
            Get-ChildItem -LiteralPath (Get-DispatchRunDirectory $fixtureRoot 'line-a' $dispatchSlug) -Filter '*.json' -File |
                Select-Object -First 1
        )[0].FullName
        $firstRecord = Read-DispatchRunRecord -Path $firstRecordPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug $dispatchSlug
        $firstClassification = Get-DispatchRunRecordStartClassification -Record $firstRecord
        $witnessPath = Get-ScopePlanHashRecordPath -SourceHistoryRoot (Join-Path $fixtureRoot '.local\ai-sessions\history') -DispatchSlug $dispatchSlug
        $witnessBefore = Get-FileSha256 -Path $witnessPath

        $script:SessionMode = 'cold-start'
        $script:ResumeThreadId = $null
        $script:LastMessagePath = $null
        $script:ScopePlanPath = $null
        $retryResult = @(Invoke-Start)[0]
        $retryRecord = Read-DispatchRunRecord -Path $retryResult.runRecordPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug $dispatchSlug
        $retryRecord.model_evidence.runtime_verifiable = New-ConfirmedDispatchEvidence -Value 'fixture-model' -Source 'rollout' -Field 'payload.model'
        $null = Write-DispatchRunRecord -Record $retryRecord -Update
        $retryRecord = Read-DispatchRunRecord -Path $retryResult.runRecordPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug $dispatchSlug
        $witnessAfterRetry = Get-FileSha256 -Path $witnessPath
        Write-Utf8NoBom -Path $retryResult.lastMessagePath -Content 'Phase 9 cold-start retry completed.'

        $script:SessionMode = 'continuation'
        $script:ContinueFromScopePlan = $false
        $script:ResumeThreadId = $retryResult.threadId
        $script:ScopePlanPath = $retryResult.scopePlanPath
        $script:LastMessagePath = $retryResult.lastMessagePath
        $continuationResult = @(Invoke-Start)[0]
        $continuationRecord = Read-DispatchRunRecord -Path $continuationResult.runRecordPath -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -LineSlug 'line-a' -DispatchSlug $dispatchSlug
        $witnessAfterContinuation = Get-FileSha256 -Path $witnessPath
        $evidence = [ordered]@{
            first_preflight_failure = [ordered]@{
                exception = if ($null -eq $firstException) { $null } else { $firstException.Message }
                launch_state = [string]$firstRecord.launch_state
                process_started = [bool]$firstRecord.failure.observation.process_started
                phase = [string]$firstRecord.failure.phase
                classification = $firstClassification
                root_run_id = [string]$firstRecord.scope_plan_root_run_id
            }
            cold_start_retry = [ordered]@{
                process_started = [bool]$retryResult.processStarted
                attempt_parent_run_id = [string]$retryRecord.attempt_parent_run_id
                root_run_id = [string]$retryRecord.scope_plan_root_run_id
                root_run_reused = [string]$retryRecord.scope_plan_root_run_id -ceq [string]$firstRecord.scope_plan_root_run_id
                witness_unchanged_after_retry = $witnessBefore -ceq $witnessAfterRetry
            }
            continuation = [ordered]@{
                process_started = [bool]$continuationResult.processStarted
                previous_run_id = [string]$continuationRecord.previous_run_id
                root_run_id = [string]$continuationRecord.scope_plan_root_run_id
                witness_unchanged_after_continuation = $witnessBefore -ceq $witnessAfterContinuation
                skipped_attempts = @($continuationRecord.skipped_attempts)
            }
            witness_path = $witnessPath
            witness_before_sha256 = $witnessBefore
            witness_after_retry_sha256 = $witnessAfterRetry
            witness_after_continuation_sha256 = $witnessAfterContinuation
        }
        Assert-True ($null -ne $firstException -and $evidence.first_preflight_failure.classification.classification -eq 'unstarted-sandbox' -and $evidence.cold_start_retry.process_started -and $evidence.cold_start_retry.root_run_reused -and $evidence.cold_start_retry.witness_unchanged_after_retry -and $evidence.continuation.process_started -and $evidence.continuation.previous_run_id -eq $retryRecord.run_id -and $evidence.continuation.witness_unchanged_after_continuation) ('F-003 cold-start retry／continuation witness 情境失敗：' + ($evidence | ConvertTo-Json -Depth 40 -Compress))
        Write-Phase9Evidence -Label 'F003_PRESTART_FAILURE_COLD_RETRY_CONTINUATION' -Value $evidence
    }

    $script:ContinueFromScopePlan = $false
    $script:ResumeThreadId = $null
    $script:ScopePlanPath = $null
    $script:LastMessagePath = $null
    $script:SessionMode = 'cold-start'

    Invoke-Case 'Phase 9 F-004 長路徑 Write、Hash 與 atomic JSON 直接案例' {
        $longDirectory = Join-Path $phase9Root 'f004-long-direct'
        while ($longDirectory.Length -lt 220) {
            $longDirectory = Join-Path $longDirectory ('segment-' + ('x' * 20))
        }
        New-Item -ItemType Directory -Path $longDirectory -Force | Out-Null
        $longTextPath = Join-Path $longDirectory ('payload-' + ('y' * 90) + '.txt')
        $longJsonPath = Join-Path $longDirectory ('atomic-' + ('z' * 90) + '.json')
        $textContent = 'F004 long path direct fixture.'
        Write-Utf8NoBom -Path $longTextPath -Content $textContent
        $textHash = Get-FileSha256 -Path $longTextPath
        $document = [ordered]@{ schema = 'fixture.f004.long-path.v1'; marker = 'long-path-direct'; result_sha256 = $null }
        $atomicResult = Write-DispatchAtomicJsonDocument -Path $longJsonPath -Document $document -SourceRoot $phase9Root -ExecutionRoot $phase9Root -TargetPath @() -HashProperty 'result_sha256' -RequireAbsent
        $atomicHash = Get-FileSha256 -Path $longJsonPath
        $apiTextPath = ConvertTo-FileSystemApiPath -Path $longTextPath
        $apiJsonPath = ConvertTo-FileSystemApiPath -Path $longJsonPath
        $atomicContent = [System.IO.File]::ReadAllText($apiJsonPath, [System.Text.Encoding]::UTF8)
        $atomicDocument = $atomicContent | ConvertFrom-Json
        $evidence = [ordered]@{
            text_path_length = $longTextPath.Length
            json_path_length = $longJsonPath.Length
            text_api_path = $apiTextPath
            json_api_path = $apiJsonPath
            text_hash = $textHash
            atomic_hash = $atomicHash
            atomic_result_sha256 = [string]$atomicDocument.result_sha256
            atomic_writer_sha256 = [string]$atomicResult.Sha256
            long_path_prefix_applied = $apiTextPath.StartsWith('\\?\', [StringComparison]::Ordinal) -and $apiJsonPath.StartsWith('\\?\', [StringComparison]::Ordinal)
            content_round_trip = [string]$atomicDocument.marker -ceq 'long-path-direct'
        }
        Assert-True ($evidence.text_path_length -gt 260 -and $evidence.json_path_length -gt 260 -and $evidence.long_path_prefix_applied -and $evidence.text_hash -match '^[a-f0-9]{64}$' -and $evidence.atomic_hash -match '^[a-f0-9]{64}$' -and $evidence.atomic_result_sha256 -match '^[a-f0-9]{64}$' -and $evidence.atomic_hash -eq $evidence.atomic_writer_sha256 -and $evidence.content_round_trip) ('F-004 長路徑直接案例失敗：' + ($evidence | ConvertTo-Json -Depth 20 -Compress))
        Write-Phase9Evidence -Label 'F004_LONG_PATH_DIRECT_CASE' -Value $evidence
    }

    Invoke-Case 'Phase 9 P1 A5 normal sandbox ACE continuation' {
        $script:phase9AclMode = 'sandbox'
        $firstGate = Invoke-Phase9ProductionAclGate -SourceRoot $phase9AclSourceRoot -ExecutionRoot $phase9AclExecutionRoot -WriteMode 'write'
        Assert-True ($firstGate.status -eq 'clean') ('sandbox ACE 未被 fallback 接受：' + ($firstGate | ConvertTo-Json -Depth 12 -Compress))
        Assert-True (@($firstGate.accepted_sandbox_entries).Count -eq 1) 'sandbox ACE 未記錄為 accepted_sandbox_entries。'
        $normalRecord = [pscustomobject]@{
            sandbox_acl_evidence = [pscustomobject]@{
                capture_status = 'captured'
                entries = @($phase9SandboxEntry)
                captured_at_utc = [DateTime]::UtcNow.ToString('o')
                normal_completion = $true
                continuation_allowed = $true
            }
        }
        $continuedGate = Invoke-Phase9ProductionAclGate -SourceRoot $phase9AclSourceRoot -ExecutionRoot $phase9AclExecutionRoot -WriteMode 'write' -ContinuationRecord $normalRecord
        Assert-True ($continuedGate.status -eq 'clean') '正常完成 RunRecord 的 whitelist 未允許同一 sandbox ACE。'
    }

    Invoke-Case 'Phase 9 P1 A5 forced termination residue' -Reject -ErrorPattern 'WorktreeAclResidue' {
        $script:phase9AclMode = 'extra'
        $gate = Invoke-Phase9ProductionAclGate -SourceRoot $phase9AclSourceRoot -ExecutionRoot $phase9AclExecutionRoot -WriteMode 'write'
        Assert-True ($gate.status -eq 'residue' -and $gate.rejection_code -eq 'WorktreeAclResidue') 'forced termination residue 未拒絕。'
        throw ('WorktreeAclResidue：' + ($gate | ConvertTo-Json -Depth 12 -Compress))
    }

    Invoke-Case 'Phase 9 P1 A5 extra residue and unknown ACL' -Reject -ErrorPattern 'WorktreeAclUnknown' {
        $script:phase9AclMode = 'unknown'
        $gate = Invoke-Phase9ProductionAclGate -SourceRoot $phase9AclSourceRoot -ExecutionRoot $phase9AclExecutionRoot -WriteMode 'write'
        Assert-True ($gate.status -eq 'unknown' -and $gate.rejection_code -eq 'WorktreeAclUnknown') 'ACL unknown 未保留拒絕狀態。'
        throw ('WorktreeAclUnknown：' + ($gate | ConvertTo-Json -Depth 12 -Compress))
    }

    Invoke-Case 'Phase 9 F-001 actual Start continuation reaches production ACL gate' {
        $f001FunctionNames = @('Get-WorktreeAclGate', 'Resolve-PreviousDispatchRun', 'Resolve-DispatchBaselineBinding', 'Resolve-PrepareResultBinding', 'Test-ScopePlanHashRecord', 'Get-DispatchUnitList', 'Test-ContinuationScopePlan')
        $f001OriginalFunctions = @{}
        foreach ($functionName in $f001FunctionNames) {
            $f001OriginalFunctions[$functionName] = (Get-Command -Name $functionName -CommandType Function -ErrorAction Stop).ScriptBlock
        }
        $previousTestThread = $script:testThread
        $previousQuotaOverride = $script:quotaSnapshotPathOverride
        $previousAclMode = $script:phase9AclMode
        $previousDispatchUnitOverride = $script:dispatchUnitListOverride
        $f001SourceRoot = $phase9AclSourceRoot
        $f001ExecutionRoot = $phase9AclExecutionRoot
        $f001LineSlug = 'line-a'
        $f001DispatchSlug = 'f001-start-chain'
        $f001Thread = [guid]::NewGuid().ToString('D')
        $f001HistoryRoot = Join-Path $f001ExecutionRoot '.local\ai-sessions\history'
        $f001LineHistoryRoot = Join-Path $f001HistoryRoot $f001LineSlug
        $f001ScopePath = Join-Path $f001LineHistoryRoot 'f001-scope.json'
        $f001PreparePath = Join-Path $f001LineHistoryRoot 'f001-prepare.json'
        $f001BaselinePath = Join-Path $f001LineHistoryRoot 'f001-baseline.json'
        $f001PreflightPath = Join-Path $f001LineHistoryRoot 'f001-preflight.json'
        $f001PromptPath = Join-Path $f001ExecutionRoot 'f001-prompt.md'
        $f001QuotaPath = Join-Path $f001SourceRoot 'f001-quota.json'
        $f001CodexHome = Join-Path $f001ExecutionRoot 'f001-codex-home'
        New-Item -ItemType Directory -Path $f001LineHistoryRoot, $f001CodexHome -Force | Out-Null
        Write-Utf8NoBom -Path $f001ScopePath -Content (([ordered]@{ decision = 'full'; requested_units = @('Phase 1'); selected_units = @('Phase 1'); deferred_units = @(); scope_plan_fingerprint = 'fixture' } | ConvertTo-Json -Depth 10) + "`n")
        Write-Utf8NoBom -Path $f001PreparePath -Content (([ordered]@{ operation = 'Prepare'; status = 'Prepared' } | ConvertTo-Json -Depth 10) + "`n")
        Write-Utf8NoBom -Path $f001BaselinePath -Content (([ordered]@{ schema = 'fixture.baseline.v1'; base_sha = ('a' * 40) } | ConvertTo-Json -Depth 10) + "`n")
        Write-Utf8NoBom -Path $f001PromptPath -Content 'f001 continuation prompt'
        $null = New-Phase8QuotaSnapshot -Path $f001QuotaPath -PrimaryRemainingPercent 80
        Write-Utf8NoBom -Path (Join-Path $f001CodexHome 'default.config.toml') -Content ('model = "fixture-model"' + "`r`n" + 'model_reasoning_effort = "high"' + "`r`n")
        $f001BaselineSha256 = Get-FileSha256 -Path $f001BaselinePath
        $f001PrepareSha256 = Get-FileSha256 -Path $f001PreparePath
        $f001ParentOptions = New-ParentOptionsModel -Profile 'default' -Sandbox 'workspace-write' -WorkingDirectory $f001ExecutionRoot -AddDirectory @() -Search $false -CodexParentOption @()
        $f001PreviousAnchor = [pscustomobject]@{
            schema = 'ai-sessions.dispatch-run.v1'
            run_id = [guid]::NewGuid().ToString('D')
            line_slug = $f001LineSlug
            dispatch_slug = $f001DispatchSlug
            source_root = $f001SourceRoot
            execution_root = $f001ExecutionRoot
            thread_id = $f001Thread
            last_message_path = Join-Path $f001LineHistoryRoot 'f001-previous-message.md'
            scope_plan_path = $f001ScopePath
            scope_plan_sha256 = Get-FileSha256 -Path $f001ScopePath
            baseline_path = $f001BaselinePath
            baseline_sha256 = $f001BaselineSha256
            model_evidence = $a.model_evidence
            reasoning_effort_evidence = $a.reasoning_effort_evidence
            parent_options = $f001ParentOptions
            sandbox_acl_evidence = [pscustomobject]@{
                capture_status = 'captured'
                entries = @($phase9SandboxEntry, $phase9ExtraAclEntry)
                captured_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
                normal_completion = $true
                continuation_allowed = $true
            }
        }
        Write-Utf8NoBom -Path $f001PreviousAnchor.last_message_path -Content 'f001 previous message'
        $f001PreviousRun = [pscustomobject]@{
            Record = $f001PreviousAnchor
            AnchorRecord = $f001PreviousAnchor
            ChainTailRecord = $f001PreviousAnchor
            LatestActualStartRecord = $f001PreviousAnchor
            LatestActualStartEvents = $null
            ScopePlanRootRecord = $f001PreviousAnchor
            Message = 'f001 previous message'
            SkippedAttempts = @()
        }
        $f001Preflight = [ordered]@{
            sourceRoot = $f001SourceRoot
            executionRoot = $f001ExecutionRoot
            dispatchRoot = $f001ExecutionRoot
            lineSlug = $f001LineSlug
            dispatchSlug = $f001DispatchSlug
            writeMode = 'write'
            baseSha = ('a' * 40)
            baselinePath = $f001BaselinePath
            baselineSha256 = $f001BaselineSha256
            prepareResultPath = $f001PreparePath
            prepareResultSha256 = $f001PrepareSha256
            prepareStatus = 'Prepared'
        }
        Write-Utf8NoBom -Path $f001PreflightPath -Content (($f001Preflight | ConvertTo-Json -Depth 20) + "`n")
        $f001ActualAclDefinition = $aclFunctionAst[0].Body.Extent.Text.Trim()
        $f001ActualAclDefinition = $f001ActualAclDefinition.Substring(1, $f001ActualAclDefinition.Length - 2)
        $f001CaptureStatement = '    $script:phase9F001AclCalls = @($script:phase9F001AclCalls) + @([pscustomobject]@{ continuation_present = $null -ne $ContinuationRecord })' + [Environment]::NewLine
        $f001ActualAclDefinition = $f001ActualAclDefinition.Replace('    $sourcePath = Resolve-AbsolutePath -Path $SourceRoot', $f001CaptureStatement + '    $sourcePath = Resolve-AbsolutePath -Path $SourceRoot')
        $f001StartAst = @($functions | Where-Object { $_.Name -eq 'Invoke-Start' } | Select-Object -First 1)
        Assert-True ($f001StartAst.Count -eq 1) 'F-001 找不到 production Invoke-Start AST。'
        $f001MutantStartDefinition = $f001StartAst[0].Extent.Text.Replace('$process = New-Object System.Diagnostics.Process', '$process = New-TestProcess').Replace('function Invoke-Start', 'function Invoke-Phase9MutantStart').Replace(' -ContinuationRecord $continuationAclRecord', '')
        try {
            Set-Item -Path Function:\Get-WorktreeAclGate -Value ([scriptblock]::Create($f001ActualAclDefinition))
            Set-Item -Path Function:\Resolve-PreviousDispatchRun -Value ([scriptblock]::Create('param($SourceRoot, $ExecutionRoot, $LineSlug, $DispatchSlug, $ResumeThreadId, $LastMessagePath) return $script:phase9F001PreviousRun'))
            Set-Item -Path Function:\Resolve-DispatchBaselineBinding -Value ([scriptblock]::Create('param($Preflight, $SourceRoot, $DispatchRoot, $LineSlug, $DispatchSlug, $BaseSha) return [pscustomobject]@{ Path = $script:phase9F001BaselinePath; Sha256 = $script:phase9F001BaselineSha256 }'))
            Set-Item -Path Function:\Resolve-PrepareResultBinding -Value ([scriptblock]::Create('param($Path, $SourceRoot, $ExecutionRoot, $LineSlug, $DispatchSlug, $ExpectedSha256) return [pscustomobject]@{ Path = $script:phase9F001PreparePath; Sha256 = $script:phase9F001PrepareSha256; Status = ''Prepared''; Document = [pscustomobject]@{ operation = ''Prepare''; status = ''Prepared'' }; Artifacts = @() }'))
            Set-Item -Path Function:\Test-ScopePlanHashRecord -Value ([scriptblock]::Create('param($SourceHistoryRoot, $DispatchSlug, $LineSlug, $ScopePlanPath) return $true'))
            Set-Item -Path Function:\Get-DispatchUnitList -Value ([scriptblock]::Create('param($RequestedUnit, $DispatchKind, $UnitKind, $ExecutionRoot, $LineSlug, $EvidencePackPath, $EvidenceQuestionUnits, $TargetPath) return @(''Phase 1'')'))
            Set-Item -Path Function:\Test-ContinuationScopePlan -Value ([scriptblock]::Create('param($ScopePlan, $DispatchSlug, $DispatchKind, $TaskType, $RequestedProfile, $UnitKind, $Units) return $true'))
            . ([scriptblock]::Create($f001MutantStartDefinition))
            $script:phase9F001PreviousRun = $f001PreviousRun
            $script:phase9F001BaselinePath = $f001BaselinePath
            $script:phase9F001BaselineSha256 = $f001BaselineSha256
            $script:phase9F001PreparePath = $f001PreparePath
            $script:phase9F001PrepareSha256 = $f001PrepareSha256
            $script:phase9F001AclCalls = @()
            $script:phase9AclMode = 'extra'
            $f001DirectAclGate = Get-WorktreeAclGate -SourceRoot $f001SourceRoot -ExecutionRoot $f001ExecutionRoot -WriteMode 'worktree' -ContinuationRecord $f001PreviousAnchor
            Assert-True ($null -ne $f001DirectAclGate -and [string](Get-DispatchJsonProperty -Object $f001DirectAclGate -Name 'status') -eq 'clean') ('F-001 actual ACL function direct call 未回傳 clean：' + ($f001DirectAclGate | ConvertTo-Json -Depth 20 -Compress))
            $script:phase9F001AclCalls = @()
            $script:dispatchUnitListOverride = @('Phase 1')
            $script:testThread = $f001Thread
            $script:quotaSnapshotPathOverride = $f001QuotaPath
            $script:startCalls = 0
            $script:failLaunch = $false
            $SourceRoot = $f001SourceRoot
            $ExecutionRoot = $f001ExecutionRoot
            $LineSlug = $f001LineSlug
            $DispatchSlug = $f001DispatchSlug
            $WriteMode = 'write'
            $PreflightResultPath = $f001PreflightPath
            $PrepareResultPath = $f001PreparePath
            $ScopePlanPath = $f001ScopePath
            $PromptPath = $f001PromptPath
            $CodexHome = $f001CodexHome
            $CodexPath = 'fixture-codex'
            $TargetPath = @('target.txt')
            $ResumeThreadId = $f001Thread
            $LastMessagePath = $null
            $QuotaBeforePath = $f001QuotaPath
            $QuotaAfterPath = $null
            $CalibrationPath = $null
            $TaskType = 'script-change'
            $DispatchKind = 'workflow'
            $Profile = 'default'
            $SessionMode = 'continuation'
            $Model = $null
            $ReasoningEffort = $null
            $AdvisorRequestSource = $null
            $EvidencePackPath = $null
            $AdvisorConsultReportPath = $null
            $PrimaryBudgetPercent = $null
            $PrimaryReservePercent = $null
            $AddDirectory = @()
            $Search = $false
            $CodexParentOption = @()
            $RequiredIdentifier = $null
            $RecoveryHandoffPath = $null
            $EventStreamPath = $null
            $ErrorStreamPath = $null
            $ThreadIdPath = $null
            $PidRecordPath = $null
            $RunRecordPath = $null
            $ProcessExitCode = $null
            $f001StartOutput = @(Invoke-Start)
            Assert-True ($f001StartOutput.Count -eq 1) ('F-001 Invoke-Start 輸出筆數不唯一：' + ($f001StartOutput | ConvertTo-Json -Depth 20 -Compress))
            $script:phase9F001ValidStart = $f001StartOutput[0]
            $f001ValidAclGate = Get-DispatchJsonProperty -Object $script:phase9F001ValidStart -Name 'aclGate'
            Assert-True ($script:phase9F001ValidStart.processStarted -and $null -ne $f001ValidAclGate -and [string](Get-DispatchJsonProperty -Object $f001ValidAclGate -Name 'status') -eq 'clean' -and @((Get-DispatchJsonProperty -Object $f001ValidAclGate -Name 'accepted_sandbox_entries')).Count -eq 2) ('F-001 actual Start 未通過 production ACL continuation：' + ($script:phase9F001ValidStart | ConvertTo-Json -Depth 20 -Compress))
            Assert-True ($script:phase9F001AclCalls.Count -eq 1 -and $script:phase9F001AclCalls[0].continuation_present) ('F-001 Invoke-Start 未以 continuation record 呼叫 production ACL gate：' + ($script:phase9F001AclCalls | ConvertTo-Json -Depth 10 -Compress))
            $f001ValidAclCalls = @($script:phase9F001AclCalls)
            $script:phase9F001AclCalls = @()
            $f001ReverseFailure = $null
            try {
                $null = Invoke-Phase9MutantStart
            }
            catch {
                $f001ReverseFailure = $_.Exception.Message
            }
            Assert-True (-not [string]::IsNullOrWhiteSpace($f001ReverseFailure) -and $f001ReverseFailure.Contains('WorktreeAclResidue') -and $script:phase9F001AclCalls.Count -eq 1 -and -not $script:phase9F001AclCalls[0].continuation_present) ('F-001 移除 continuation 接線後未拒絕：' + [string]$f001ReverseFailure)
            $f001ReverseAclCalls = @($script:phase9F001AclCalls)
            $script:phase9F001AclCalls = @()
            $f001RestoredStartOutput = @(Invoke-Start)
            Assert-True ($f001RestoredStartOutput.Count -eq 1) ('F-001 reverse 後還原 Invoke-Start 輸出筆數不唯一：' + ($f001RestoredStartOutput | ConvertTo-Json -Depth 20 -Compress))
            $f001RestoredStart = $f001RestoredStartOutput[0]
            $f001RestoredAclGate = Get-DispatchJsonProperty -Object $f001RestoredStart -Name 'aclGate'
            Assert-True ($f001RestoredStart.processStarted -and $null -ne $f001RestoredAclGate -and [string](Get-DispatchJsonProperty -Object $f001RestoredAclGate -Name 'status') -eq 'clean' -and @((Get-DispatchJsonProperty -Object $f001RestoredAclGate -Name 'accepted_sandbox_entries')).Count -eq 2) ('F-001 reverse 後還原 production Start 未通過 continuation：' + ($f001RestoredStart | ConvertTo-Json -Depth 20 -Compress))
            Assert-True ($script:phase9F001AclCalls.Count -eq 1 -and $script:phase9F001AclCalls[0].continuation_present) ('F-001 reverse 後還原 ACL gate 未收到 continuation record：' + ($script:phase9F001AclCalls | ConvertTo-Json -Depth 10 -Compress))
            $f001RestoredAclCalls = @($script:phase9F001AclCalls)
            $script:phase9F001Evidence = [pscustomobject]@{ valid = $script:phase9F001ValidStart; valid_acl_calls = $f001ValidAclCalls; reverse_acl_calls = $f001ReverseAclCalls; reverse_failure = $f001ReverseFailure; restored_after_reverse = $f001RestoredStart; restored_after_reverse_acl_calls = $f001RestoredAclCalls }
            Write-Phase9Evidence -Label 'F001_RESTORED_PASS' -Value ([ordered]@{ status = 'pass'; before_reverse = [ordered]@{ start = $script:phase9F001ValidStart; acl_calls = $f001ValidAclCalls }; after_reverse = [ordered]@{ start = $f001RestoredStart; acl_calls = $f001RestoredAclCalls } })
            Write-Phase9Evidence -Label 'F001_REVERSE_FAILURE' -Value ([ordered]@{ status = 'failed'; error = $f001ReverseFailure; acl_calls = $f001ReverseAclCalls })
        }
        finally {
            Set-Item -Path Function:\Get-WorktreeAclGate -Value $f001OriginalFunctions['Get-WorktreeAclGate']
            Set-Item -Path Function:\Resolve-PreviousDispatchRun -Value $f001OriginalFunctions['Resolve-PreviousDispatchRun']
            Set-Item -Path Function:\Resolve-DispatchBaselineBinding -Value $f001OriginalFunctions['Resolve-DispatchBaselineBinding']
            Set-Item -Path Function:\Resolve-PrepareResultBinding -Value $f001OriginalFunctions['Resolve-PrepareResultBinding']
            Set-Item -Path Function:\Test-ScopePlanHashRecord -Value $f001OriginalFunctions['Test-ScopePlanHashRecord']
            Set-Item -Path Function:\Get-DispatchUnitList -Value $f001OriginalFunctions['Get-DispatchUnitList']
            Set-Item -Path Function:\Test-ContinuationScopePlan -Value $f001OriginalFunctions['Test-ContinuationScopePlan']
            $script:testThread = $previousTestThread
            $script:quotaSnapshotPathOverride = $previousQuotaOverride
            $script:phase9AclMode = $previousAclMode
            $script:dispatchUnitListOverride = $previousDispatchUnitOverride
        }
    }

    $script:phase9AclMode = 'sandbox'

    Invoke-Case 'Phase 9 F-001 real Start RunRecord Inspect continuation matrix' {
        $f001ChainFunctionNames = @(
            'Get-WorktreeAclGate'
            'Get-ExplicitAclSnapshot'
            'Resolve-DispatchBaselineBinding'
            'Resolve-PrepareResultBinding'
            'Test-ScopePlanHashRecord'
            'Get-DispatchUnitList'
            'Test-ContinuationScopePlan'
            'Get-RuntimeModelEvidence'
            'Write-TestEvents'
        )
        $f001ChainOriginalFunctions = @{}
        foreach ($functionName in $f001ChainFunctionNames) {
            $f001ChainOriginalFunctions[$functionName] = (Get-Command -Name $functionName -CommandType Function -ErrorAction Stop).ScriptBlock
        }
        $f001ChainOriginalAclEvidence = (Get-Command -Name Get-SandboxAclInspectEvidence -CommandType Function -ErrorAction Stop).ScriptBlock
        $f001ChainMakeSnapshot = {
            param(
                [Parameter(Mandatory)][string]$Status,
                [AllowEmptyCollection()][object[]]$Entries = @(),
                [AllowEmptyString()][string]$ErrorMessage
            )
            $entryValues = @($Entries | Where-Object { $null -ne $_ })
            return [pscustomobject]@{
                status = $Status
                path = $null
                fingerprint = if ($Status -eq 'known') { Get-JsonSha256 -Value @($entryValues) } else { $null }
                entries = @($entryValues)
                explicit_entries = @($entryValues)
                captured_at_utc = [DateTime]::UtcNow.ToString('o')
                error = if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $null } else { $ErrorMessage }
            }
        }
        $f001ChainAclFunction = {
            param([string]$Path)
            $script:f001AclReadCount++
            if (@($script:f001AclQueue).Count -eq 0) {
                throw ('F-001 ACL fixture queue exhausted：' + $Path)
            }
            $next = $script:f001AclQueue[0]
            if (@($script:f001AclQueue).Count -eq 1) {
                $script:f001AclQueue = @()
            }
            else {
                $script:f001AclQueue = @($script:f001AclQueue | Select-Object -Skip 1)
            }
            $entries = @((Get-DispatchJsonProperty -Object $next -Name 'entries') | Where-Object { $null -ne $_ })
            $status = [string](Get-DispatchJsonProperty -Object $next -Name 'status')
            return [ordered]@{
                status = $status
                path = (Resolve-AbsolutePath -Path $Path)
                fingerprint = if ($status -eq 'known') { Get-JsonSha256 -Value @($entries) } else { $null }
                entries = @($entries)
                explicit_entries = @($entries)
                captured_at_utc = [string](Get-DispatchJsonProperty -Object $next -Name 'captured_at_utc')
                error = Get-DispatchJsonProperty -Object $next -Name 'error'
            }
        }
        $f001ChainEventFunction = {
            [CmdletBinding()]
            param([string]$Path, [string]$Thread, [string]$Terminal = 'turn.completed')
            $message = 'design.md ' + $script:f001EventDispatchSlug + ' ' + $script:f001EventLineSlug
            $events = New-Object System.Collections.Generic.List[object]
            $events.Add([ordered]@{ type = 'thread.started'; thread_id = $Thread })
            $events.Add([ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'agent_message'; text = $message } })
            if ($Terminal -eq 'turn.failed') {
                $events.Add([ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'fixture abnormal completion' } })
            }
            else {
                $events.Add([ordered]@{ type = 'turn.completed'; usage = [ordered]@{ input_tokens = 1; output_tokens = 1 } })
            }
            Write-Utf8NoBom -Path $Path -Content (($events | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 }) -join "`r`n")
        }
        $script:f001AclQueue = @()
        $script:f001AclReadCount = 0
        $script:f001EventDispatchSlug = ''
        $script:f001EventLineSlug = ''
        $script:f001Terminal = 'turn.completed'

        $f001ChainScenario = {
            param(
                [Parameter(Mandatory)][string]$Name,
                [Parameter(Mandatory)][string]$PostStatus,
                [AllowEmptyCollection()][object[]]$PostEntries = @(),
                [AllowEmptyString()][string]$PostError,
                [Parameter(Mandatory)][bool]$NormalCompletion,
                [Parameter(Mandatory)][bool]$ContinuationPass,
                [Parameter(Mandatory)][string]$ExpectedContinuationCode,
                [bool]$InspectContinuation,
                [bool]$InspectDuplicate
            )
            $scenarioRoot = Join-Path $phase9Root ('f1-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $sourceRoot = Join-Path $scenarioRoot 'source'
            $executionRoot = Join-Path $scenarioRoot 'dispatch'
            $lineSlug = 'line-a'
            $dispatchSlug = 'f001-' + $Name
            $historyRoot = Join-Path $executionRoot '.local\ai-sessions\history'
            $sourceHistoryRoot = Join-Path $sourceRoot '.local\ai-sessions\history'
            $lineHistoryRoot = Join-Path $sourceHistoryRoot ($lineSlug + '\runs\' + $dispatchSlug)
            $executionLineHistoryRoot = Join-Path $historyRoot $lineSlug
            $lineRoot = Join-Path $sourceRoot '.local\ai-sessions\handoff\line-a'
            $codexHome = Join-Path $executionRoot 'codex-home'
            $scopePath = Join-Path $historyRoot ($dispatchSlug + '-scope.json')
            $preparePath = Join-Path $historyRoot ($dispatchSlug + '-prepare.json')
            $baselinePath = Join-Path $historyRoot ($dispatchSlug + '-baseline.json')
            $preflightPath = Join-Path $historyRoot ($dispatchSlug + '-preflight.json')
            $quotaBeforePath = Join-Path $historyRoot ($dispatchSlug + '-quota-before.json')
            $quotaAfterPath = Join-Path $historyRoot ($dispatchSlug + '-quota-after.json')
            $calibrationPath = Join-Path $sourceHistoryRoot ($dispatchSlug + '-calibration.jsonl')
            $promptPath = Join-Path $executionRoot ($dispatchSlug + '-prompt.md')
            New-Item -ItemType Directory -Path $lineHistoryRoot, $executionLineHistoryRoot, $lineRoot, $codexHome, $historyRoot -Force | Out-Null
            Write-Utf8NoBom -Path (Join-Path $lineRoot 'line.json') -Content (([ordered]@{ schema = 'ai-sessions.line.v1'; 'line-slug' = $lineSlug } | ConvertTo-Json -Depth 10) + "`n")
            Write-Utf8NoBom -Path $promptPath -Content ('f001 chain ' + $Name)
            Write-Utf8NoBom -Path (Join-Path $codexHome 'default.config.toml') -Content ('model = "fixture-model"' + "`r`n" + 'model_reasoning_effort = "high"' + "`r`n")
            $rolloutRoot = Join-Path $codexHome 'sessions\f001'
            New-Item -ItemType Directory -Path $rolloutRoot -Force | Out-Null
            Write-Utf8NoBom -Path (Join-Path $rolloutRoot 'rollout.jsonl') -Content (([ordered]@{ type = 'session_meta'; payload = [ordered]@{ session_id = '' } } | ConvertTo-Json -Compress -Depth 10) + "`r`n" + ([ordered]@{ type = 'turn_context'; payload = [ordered]@{ model = 'fixture-model'; effort = 'high' } } | ConvertTo-Json -Compress -Depth 10) + "`r`n")
            Write-Utf8NoBom -Path $baselinePath -Content (([ordered]@{ schema = 'fixture.baseline.v1'; base_sha = ('a' * 40) } | ConvertTo-Json -Depth 10) + "`n")
            Write-Utf8NoBom -Path $preparePath -Content (([ordered]@{ operation = 'Prepare'; status = 'Prepared' } | ConvertTo-Json -Depth 10) + "`n")
            Write-Utf8NoBom -Path $scopePath -Content (([ordered]@{ decision = 'full'; requested_units = @('Phase 1'); selected_units = @('Phase 1'); deferred_units = @(); scope_plan_fingerprint = 'fixture' } | ConvertTo-Json -Depth 10) + "`n")
            $null = New-Phase8QuotaSnapshot -Path $quotaBeforePath -PrimaryRemainingPercent 80
            Copy-Item -LiteralPath $quotaBeforePath -Destination $quotaAfterPath -Force
            $baselineSha = Get-FileSha256 -Path $baselinePath
            $prepareSha = Get-FileSha256 -Path $preparePath
            $scopeSha = Get-FileSha256 -Path $scopePath
            $preflight = [ordered]@{
                sourceRoot = $sourceRoot
                executionRoot = $executionRoot
                dispatchRoot = $executionRoot
                lineSlug = $lineSlug
                dispatchSlug = $dispatchSlug
                writeMode = 'write'
                dispatchKind = 'workflow'
                baseSha = ('a' * 40)
                baselinePath = $baselinePath
                baselineSha256 = $baselineSha
                prepareResultPath = $preparePath
                prepareResultSha256 = $prepareSha
                prepareStatus = 'Prepared'
            }
            Write-Utf8NoBom -Path $preflightPath -Content (($preflight | ConvertTo-Json -Depth 20) + "`n")
            $thread = [guid]::NewGuid().ToString('D')
            $script:testThread = $thread
            $script:f001EventDispatchSlug = $dispatchSlug
            $script:f001EventLineSlug = $lineSlug
            $script:f001Terminal = if ($NormalCompletion) { 'turn.completed' } else { 'turn.failed' }
            $script:startCalls = 0
            $script:failLaunch = $false
            $script:startSnapshotMode = 'confirmed'
            $script:pidResult.ActiveRecords = @()
            $script:pidResult.UnconfirmedRecords = @()
            $script:pidResult.Blocked = $false
            $script:ProfileExplicit = $false
            $script:AddDirectoryExplicit = $false
            $script:SearchExplicit = $false
            $script:CodexParentOptionExplicit = $false
            $script:dispatchUnitListOverride = @('Phase 1')
            $script:quotaSnapshotPathOverride = $quotaBeforePath
            $script:f001CurrentBaselinePath = $baselinePath
            $script:f001CurrentBaselineSha256 = $baselineSha
            $script:f001CurrentPreparePath = $preparePath
            $script:f001CurrentPrepareSha256 = $prepareSha
            $emptySnapshot = & $f001ChainMakeSnapshot 'known' @() $null
            $gateSnapshot = & $f001ChainMakeSnapshot 'known' @($phase9SandboxEntry) $null
            $baselineSnapshot = & $f001ChainMakeSnapshot 'known' @() $null
            $script:f001AclQueue = @($emptySnapshot, $gateSnapshot, $baselineSnapshot)
            $postSnapshotStatus = if ($PostStatus -in @('captured', 'rejected', 'no_match')) { 'known' } else { $PostStatus }
            $SourceRoot = $sourceRoot
            $ExecutionRoot = $executionRoot
            $DispatchRoot = $executionRoot
            $LineSlug = $lineSlug
            $DispatchSlug = $dispatchSlug
            $WriteMode = 'write'
            $PreflightResultPath = $preflightPath
            $PrepareResultPath = $preparePath
            $ScopePlanPath = $scopePath
            $PromptPath = $promptPath
            $CodexHome = $codexHome
            $CodexPath = 'fixture-codex'
            $TargetPath = @('target.txt')
            $ResumeThreadId = $null
            $LastMessagePath = $null
            $QuotaBeforePath = $quotaBeforePath
            $QuotaAfterPath = $null
            $CalibrationPath = $calibrationPath
            $TaskType = 'script-change'
            $DispatchKind = 'workflow'
            $Profile = 'default'
            $SessionMode = 'cold-start'
            $Model = $null
            $ReasoningEffort = $null
            $AdvisorRequestSource = $null
            $EvidencePackPath = $null
            $AdvisorConsultReportPath = $null
            $PrimaryBudgetPercent = $null
            $PrimaryReservePercent = $null
            $AddDirectory = @()
            $Search = $false
            $CodexParentOption = @()
            $RequiredIdentifier = $null
            $RecoveryHandoffPath = $null
            $EventStreamPath = $null
            $ErrorStreamPath = $null
            $ThreadIdPath = $null
            $PidRecordPath = $null
            $RunRecordPath = $null
            $ProcessExitCode = $null
            $AbortGraceSeconds = 30
            $InvocationBoundParameters = [ordered]@{}
            New-Item -ItemType Directory -Path (Get-DispatchRunDirectory -SourceRoot $sourceRoot -LineSlug $lineSlug -DispatchSlug $dispatchSlug) -Force | Out-Null
            $firstStart = @(Invoke-Start)
            Assert-True ($firstStart.Count -eq 1 -and [bool](Get-DispatchJsonProperty -Object $firstStart[0] -Name 'processStarted')) ('F-001 ' + $Name + ' 首次 Start 未成功：' + ($firstStart | ConvertTo-Json -Depth 30 -Compress))
            $firstRecordPath = [string](Get-DispatchJsonProperty -Object $firstStart[0] -Name 'runRecordPath')
            $firstRecord = Read-DispatchRunRecord -Path $firstRecordPath -SourceRoot $sourceRoot -ExecutionRoot $executionRoot -LineSlug $lineSlug -DispatchSlug $dispatchSlug
            $firstEvidence = Get-DispatchJsonProperty -Object $firstRecord -Name 'sandbox_acl_evidence'
            $firstBaseline = Get-DispatchJsonProperty -Object $firstRecord -Name 'sandbox_acl_baseline'
            Assert-True ([string](Get-DispatchJsonProperty -Object $firstBaseline -Name 'status') -eq 'known' -and @((Get-DispatchJsonProperty -Object $firstBaseline -Name 'entries')).Count -eq 0) ('F-001 ' + $Name + ' baseline 未保存 Start spawn 前實際零筆 snapshot。')
            Assert-True ([string](Get-DispatchJsonProperty -Object $firstEvidence -Name 'capture_status') -eq 'pending' -and @((Get-DispatchJsonProperty -Object $firstEvidence -Name 'entries')).Count -eq 0) ('F-001 ' + $Name + ' Start pending evidence 含有 gate entry：' + ($firstEvidence | ConvertTo-Json -Depth 20 -Compress))
            $rolloutFile = Join-Path $rolloutRoot 'rollout.jsonl'
            $rolloutLines = @(
                ([ordered]@{ type = 'session_meta'; payload = [ordered]@{ session_id = $thread } } | ConvertTo-Json -Compress -Depth 10)
                ([ordered]@{ type = 'turn_context'; payload = [ordered]@{ model = 'fixture-model'; effort = 'high' } } | ConvertTo-Json -Compress -Depth 10)
            )
            Write-Utf8NoBom -Path $rolloutFile -Content (($rolloutLines -join "`r`n") + "`r`n")
            $script:f001AclQueue = if ($NormalCompletion) { @(& $f001ChainMakeSnapshot $postSnapshotStatus $PostEntries $PostError) } else { @() }
            $script:SourceRoot = $sourceRoot
            $script:ExecutionRoot = $executionRoot
            $script:LineSlug = $lineSlug
            $script:DispatchSlug = $dispatchSlug
            $script:DispatchResultPath = $null
            $script:EventStreamPath = [string](Get-DispatchJsonProperty -Object $firstRecord -Name 'event_stream_path')
            $script:RunRecordPath = $firstRecordPath
            $script:ScopePlanPath = [string](Get-DispatchJsonProperty -Object $firstRecord -Name 'scope_plan_path')
            $script:QuotaBeforePath = [string](Get-DispatchJsonProperty -Object $firstRecord -Name 'quota_before_path')
            $script:QuotaAfterPath = $quotaAfterPath
            $script:CalibrationPath = $calibrationPath
            $SourceRoot = $sourceRoot
            $ExecutionRoot = $executionRoot
            $LineSlug = $lineSlug
            $DispatchSlug = $dispatchSlug
            $DispatchResultPath = $null
            $EventStreamPath = [string](Get-DispatchJsonProperty -Object $firstRecord -Name 'event_stream_path')
            $RunRecordPath = $firstRecordPath
            $ScopePlanPath = [string](Get-DispatchJsonProperty -Object $firstRecord -Name 'scope_plan_path')
            $QuotaBeforePath = [string](Get-DispatchJsonProperty -Object $firstRecord -Name 'quota_before_path')
            $QuotaAfterPath = $quotaAfterPath
            $CalibrationPath = $calibrationPath
            $RequiredIdentifier = 'design.md'
            $script:RequiredIdentifier = 'design.md'
            $global:RequiredIdentifier = 'design.md'
            $script:ErrorStreamPath = $null
            $script:LastMessagePath = $null
            $script:ThreadIdPath = $null
            $script:EvidencePackPath = $null
            $script:BudgetMonitorPath = $null
            $script:AdvisorConsultReportPath = $null
            $script:Profile = 'default'
            $script:Model = 'fixture-model'
            $script:ReasoningEffort = 'high'
            $script:TaskType = 'script-change'
            $script:SessionMode = 'cold-start'
            $script:InvocationBoundParameters = [ordered]@{}
            $script:ProcessExitCode = if ($NormalCompletion) { 0 } else { 1 }
            $ProcessExitCode = if ($NormalCompletion) { 0 } else { 1 }
            $inspectResult = Invoke-Inspect
            $afterFirstRecord = Read-DispatchRunRecord -Path $firstRecordPath -SourceRoot $sourceRoot -ExecutionRoot $executionRoot -LineSlug $lineSlug -DispatchSlug $dispatchSlug
            $afterFirstEvidence = Get-DispatchJsonProperty -Object $afterFirstRecord -Name 'sandbox_acl_evidence'
            $expectedStatus = if ($NormalCompletion) { $PostStatus } else { 'pending' }
            Assert-True ([string](Get-DispatchJsonProperty -Object $afterFirstEvidence -Name 'capture_status') -eq $expectedStatus -and [bool](Get-DispatchJsonProperty -Object $afterFirstEvidence -Name 'continuation_allowed') -eq $ContinuationPass) (("F-001 {0} Inspect status 不符：expected={1}; actual={2}" -f $Name, $expectedStatus, ($afterFirstEvidence | ConvertTo-Json -Depth 20 -Compress)))
            if ($NormalCompletion -and $PostStatus -eq 'captured') {
                Assert-True (@((Get-DispatchJsonProperty -Object $afterFirstEvidence -Name 'entries')).Count -eq @($PostEntries).Count) ('F-001 ' + $Name + ' captured entries 未來自 post snapshot。')
            }
            $duplicateReadCount = $script:f001AclReadCount
            $duplicateEvidence = $null
            if ($InspectDuplicate) {
                $duplicateResult = Invoke-Inspect
                $duplicateRecord = Read-DispatchRunRecord -Path $firstRecordPath -SourceRoot $sourceRoot -ExecutionRoot $executionRoot -LineSlug $lineSlug -DispatchSlug $dispatchSlug
                $duplicateEvidence = Get-DispatchJsonProperty -Object $duplicateRecord -Name 'sandbox_acl_evidence'
                Assert-True ($script:f001AclReadCount -eq $duplicateReadCount -and [string](Get-DispatchJsonProperty -Object $duplicateEvidence -Name 'capture_status') -eq $expectedStatus -and [string](Get-DispatchJsonProperty -Object $duplicateEvidence -Name 'fingerprint') -eq [string](Get-DispatchJsonProperty -Object $afterFirstEvidence -Name 'fingerprint')) ('F-001 duplicate Inspect 非冪等：' + ($duplicateEvidence | ConvertTo-Json -Depth 20 -Compress))
            }
            $messagePath = [string](Get-DispatchJsonProperty -Object $afterFirstRecord -Name 'last_message_path')
            Write-Utf8NoBom -Path $messagePath -Content ('design.md ' + $dispatchSlug + ' ' + $lineSlug)
            $script:f001AclQueue = @(
                (& $f001ChainMakeSnapshot 'known' @() $null)
                (& $f001ChainMakeSnapshot 'known' @($phase9SandboxEntry) $null)
                (& $f001ChainMakeSnapshot 'known' @($phase9SandboxEntry) $null)
            )
            $ResumeThreadId = $thread
            $SessionMode = 'continuation'
            $script:SessionMode = 'continuation'
            $script:ProcessExitCode = $null
            $nextStart = @()
            $nextStartException = $null
            try {
                $nextStart = @(Invoke-Start)
            }
            catch {
                $nextStartException = $_.Exception
            }
            $nextStartObject = if ($nextStart.Count -eq 1) { $nextStart[0] } else { $null }
            if ($null -ne $nextStartException) {
                $operationResult = $nextStartException.Data['operationResult']
                if ($null -eq $operationResult) {
                    throw $nextStartException
                }
                $nextStartObject = $operationResult
            }
            $nextStartJson = if ($null -eq $nextStartObject) { '' } else { $nextStartObject | ConvertTo-Json -Depth 40 -Compress }
            if ($ContinuationPass) {
                Assert-True ($null -ne $nextStartObject -and [bool](Get-DispatchJsonProperty -Object $nextStartObject -Name 'processStarted')) ('F-001 ' + $Name + ' 預期續行通過但 Start 失敗：' + $nextStartJson)
            }
            else {
                Assert-True ($null -ne $nextStartObject -and -not [bool](Get-DispatchJsonProperty -Object $nextStartObject -Name 'processStarted') -and $nextStartJson.Contains($ExpectedContinuationCode)) ('F-001 ' + $Name + ' 預期拒絕但未回傳 ' + $ExpectedContinuationCode + '：' + $nextStartJson)
            }
            $secondEvidence = $null
            if ($ContinuationPass -and $InspectContinuation) {
                $secondRecordPath = [string](Get-DispatchJsonProperty -Object $nextStartObject -Name 'runRecordPath')
                $secondRecord = Read-DispatchRunRecord -Path $secondRecordPath -SourceRoot $sourceRoot -ExecutionRoot $executionRoot -LineSlug $lineSlug -DispatchSlug $dispatchSlug
                $secondPost = & $f001ChainMakeSnapshot $postSnapshotStatus $PostEntries $PostError
                $script:f001AclQueue = @($secondPost)
                $script:EventStreamPath = [string](Get-DispatchJsonProperty -Object $secondRecord -Name 'event_stream_path')
                $script:RunRecordPath = $secondRecordPath
                $script:ScopePlanPath = [string](Get-DispatchJsonProperty -Object $secondRecord -Name 'scope_plan_path')
                $script:QuotaBeforePath = [string](Get-DispatchJsonProperty -Object $secondRecord -Name 'quota_before_path')
                $EventStreamPath = [string](Get-DispatchJsonProperty -Object $secondRecord -Name 'event_stream_path')
                $RunRecordPath = $secondRecordPath
                $ScopePlanPath = [string](Get-DispatchJsonProperty -Object $secondRecord -Name 'scope_plan_path')
                $QuotaBeforePath = [string](Get-DispatchJsonProperty -Object $secondRecord -Name 'quota_before_path')
                $script:ProcessExitCode = 0
                $ProcessExitCode = 0
                $secondInspect = Invoke-Inspect
                $secondAfter = Read-DispatchRunRecord -Path $secondRecordPath -SourceRoot $sourceRoot -ExecutionRoot $executionRoot -LineSlug $lineSlug -DispatchSlug $dispatchSlug
                $secondEvidence = Get-DispatchJsonProperty -Object $secondAfter -Name 'sandbox_acl_evidence'
                Assert-True ([string](Get-DispatchJsonProperty -Object $secondEvidence -Name 'capture_status') -eq 'captured' -and [bool](Get-DispatchJsonProperty -Object $secondEvidence -Name 'continuation_allowed')) ('F-001 ' + $Name + ' 續行 Inspect 未保持 captured：' + ($secondEvidence | ConvertTo-Json -Depth 20 -Compress))
            }
            return [pscustomobject]@{
                scenario = $Name
                inspect_status = [string](Get-DispatchJsonProperty -Object $afterFirstEvidence -Name 'capture_status')
                continuation_allowed = [bool](Get-DispatchJsonProperty -Object $afterFirstEvidence -Name 'continuation_allowed')
                next_start = if ($null -eq $nextStartObject) { $null } else { [bool](Get-DispatchJsonProperty -Object $nextStartObject -Name 'processStarted') }
                next_start_error = if ($null -eq $nextStartObject) { $null } else { [string](Get-DispatchJsonProperty -Object (Get-DispatchJsonProperty -Object $nextStartObject -Name 'failure') -Name 'reason_code') }
                duplicate_status = if ($null -eq $duplicateEvidence) { $null } else { [string](Get-DispatchJsonProperty -Object $duplicateEvidence -Name 'capture_status') }
                second_inspect_status = if ($null -eq $secondEvidence) { $null } else { [string](Get-DispatchJsonProperty -Object $secondEvidence -Name 'capture_status') }
            }
        }

        try {
            Set-Item -Path Function:\Get-WorktreeAclGate -Value (Get-Command -Name Invoke-Phase9ProductionAclGate -CommandType Function).ScriptBlock
            Set-Item -Path Function:\Get-ExplicitAclSnapshot -Value $f001ChainAclFunction
            Set-Item -Path Function:\Write-TestEvents -Value $f001ChainEventFunction
            $f001RuntimeEvidenceFunction = {
                param($CodexHome, $ThreadId, $StartedAtUtc)
                return [ordered]@{
                    model = [ordered]@{ value = 'fixture-model'; status = 'confirmed' }
                    reasoning_effort = [ordered]@{ value = 'high'; status = 'confirmed' }
                    rollout_paths = @()
                }
            }
            Set-Item -Path Function:\Get-RuntimeModelEvidence -Value $f001RuntimeEvidenceFunction
            Set-Item -Path Function:\Resolve-DispatchBaselineBinding -Value ([scriptblock]::Create('param($Preflight, $SourceRoot, $DispatchRoot, $LineSlug, $DispatchSlug, $BaseSha) return [pscustomobject]@{ Path = $script:f001CurrentBaselinePath; Sha256 = $script:f001CurrentBaselineSha256 }'))
            Set-Item -Path Function:\Resolve-PrepareResultBinding -Value ([scriptblock]::Create('param($Path, $SourceRoot, $ExecutionRoot, $LineSlug, $DispatchSlug, $ExpectedSha256) return [pscustomobject]@{ Path = $script:f001CurrentPreparePath; Sha256 = $script:f001CurrentPrepareSha256; Status = ''Prepared''; Document = [pscustomobject]@{ operation = ''Prepare''; status = ''Prepared'' }; Artifacts = @() }'))
            Set-Item -Path Function:\Test-ScopePlanHashRecord -Value ([scriptblock]::Create('param($SourceHistoryRoot, $DispatchSlug, $LineSlug, $ScopePlanPath) return $true'))
            Set-Item -Path Function:\Get-DispatchUnitList -Value ([scriptblock]::Create('param($RequestedUnit, $DispatchKind, $UnitKind, $ExecutionRoot, $LineSlug, $EvidencePackPath, $EvidenceQuestionUnits, $TargetPath) return @(''Phase 1'')'))
            Set-Item -Path Function:\Test-ContinuationScopePlan -Value ([scriptblock]::Create('param($ScopePlan, $DispatchSlug, $DispatchKind, $TaskType, $RequestedProfile, $UnitKind, $Units) return $true'))
            $f001Results = New-Object System.Collections.Generic.List[object]
            $f001Results.Add((& $f001ChainScenario -Name 'first-captured' -PostStatus 'captured' -PostEntries @($phase9SandboxEntry) -NormalCompletion $true -ContinuationPass $true -ExpectedContinuationCode 'WorktreeAclResidue' -InspectDuplicate $false -InspectContinuation $false))
            $f001Results.Add((& $f001ChainScenario -Name 'continuation-captured' -PostStatus 'captured' -PostEntries @($phase9SandboxEntry) -NormalCompletion $true -ContinuationPass $true -ExpectedContinuationCode 'WorktreeAclResidue' -InspectDuplicate $false -InspectContinuation $true))
            $f001Results.Add((& $f001ChainScenario -Name 'zero-match' -PostStatus 'no_match' -PostEntries @() -NormalCompletion $true -ContinuationPass $false -ExpectedContinuationCode 'WorktreeAclContinuationDenied' -InspectDuplicate $false -InspectContinuation $false))
            $f001Results.Add((& $f001ChainScenario -Name 'acl-unknown' -PostStatus 'unknown' -PostEntries @() -PostError 'fixture ACL unknown' -NormalCompletion $true -ContinuationPass $false -ExpectedContinuationCode 'WorktreeAclContinuationDenied' -InspectDuplicate $false -InspectContinuation $false))
            $f001Results.Add((& $f001ChainScenario -Name 'acl-failed' -PostStatus 'failed' -PostEntries @() -PostError 'fixture ACL failed' -NormalCompletion $true -ContinuationPass $false -ExpectedContinuationCode 'WorktreeAclContinuationDenied' -InspectDuplicate $false -InspectContinuation $false))
            $f001Results.Add((& $f001ChainScenario -Name 'unauthorized-residue' -PostStatus 'rejected' -PostEntries @($phase9SandboxEntry, $phase9ExtraAclEntry) -PostError 'fixture unauthorized residue' -NormalCompletion $true -ContinuationPass $false -ExpectedContinuationCode 'WorktreeAclResidue' -InspectDuplicate $false -InspectContinuation $false))
            $f001Results.Add((& $f001ChainScenario -Name 'abnormal-completion' -PostStatus 'known' -PostEntries @($phase9SandboxEntry) -NormalCompletion $false -ContinuationPass $false -ExpectedContinuationCode 'WorktreeAclContinuationDenied' -InspectDuplicate $false -InspectContinuation $false))
            $f001Results.Add((& $f001ChainScenario -Name 'duplicate-inspect' -PostStatus 'captured' -PostEntries @($phase9SandboxEntry) -NormalCompletion $true -ContinuationPass $true -ExpectedContinuationCode 'WorktreeAclResidue' -InspectDuplicate $true -InspectContinuation $false))
            Assert-True ($f001Results.Count -eq 8) ('F-001 八情境結果數量錯誤：' + $f001Results.Count)
            $script:phase9F001ScenarioEvidence = @($f001Results.ToArray())
            Write-Phase9Evidence -Label 'F001_8_SCENARIOS' -Value $script:phase9F001ScenarioEvidence

            $reverseRecord = [pscustomobject]@{
                sandbox_acl_baseline = (& $f001ChainMakeSnapshot 'known' @() $null)
                sandbox_acl_evidence = [pscustomobject]@{ capture_status = 'pending'; entries = @(); captured_at_utc = $null; normal_completion = $false; continuation_allowed = $false }
                source_root = $phase9AclSourceRoot
                execution_root = $phase9AclExecutionRoot
                line_slug = 'line-a'
                dispatch_slug = 'f001-reverse'
                previous_run_id = $null
                resume_anchor_run_id = $null
            }
            $reverseSnapshotQueue = @((& $f001ChainMakeSnapshot 'known' @() $null), (& $f001ChainMakeSnapshot 'known' @($phase9SandboxEntry) $null))
            $script:f001AclQueue = @((& $f001ChainMakeSnapshot 'known' @($phase9SandboxEntry) $null))
            $reverseDefinition = "function Invoke-Phase9MutantInspectEvidence {`r`n" + (Get-Command -Name Get-SandboxAclInspectEvidence -CommandType Function).ScriptBlock.ToString() + "`r`n}"
            $reverseTarget = 'return New-SandboxAclEvidenceDocument -Entries @($postEntries) -CaptureStatus ''no_match'' -NormalCompletion $true -ContinuationAllowed $false -Error $null'
            $reverseReplacement = 'return New-SandboxAclEvidenceDocument -Entries @($script:f001ReverseGateEntries) -CaptureStatus ''captured'' -NormalCompletion $true -ContinuationAllowed $true'
            $reverseDefinition = $reverseDefinition.Replace($reverseTarget, $reverseReplacement)
            $script:f001ReverseGateEntries = @($phase9SandboxEntry)
            . ([scriptblock]::Create($reverseDefinition))
            $reverseSnapshot = & $f001ChainMakeSnapshot 'known' @() $null
            $script:f001AclQueue = @($reverseSnapshot)
            $mutantEvidence = Invoke-Phase9MutantInspectEvidence -Record $reverseRecord -ExecutionRoot $phase9AclExecutionRoot -NormalCompletion $true
            Assert-True ([string](Get-DispatchJsonProperty -Object $mutantEvidence -Name 'capture_status') -eq 'captured') ('F-001 reverse mutant 未顯示 gate entry 回填為 captured：' + ($mutantEvidence | ConvertTo-Json -Depth 20 -Compress))
            Set-Item -Path Function:\Get-SandboxAclInspectEvidence -Value $f001ChainOriginalAclEvidence
            $script:f001AclQueue = @($reverseSnapshot)
            $restoredEvidence = Get-SandboxAclInspectEvidence -Record $reverseRecord -ExecutionRoot $phase9AclExecutionRoot -NormalCompletion $true
            Assert-True ([string](Get-DispatchJsonProperty -Object $restoredEvidence -Name 'capture_status') -eq 'no_match' -and -not [bool](Get-DispatchJsonProperty -Object $restoredEvidence -Name 'continuation_allowed')) ('F-001 reverse 還原後未回到 no_match：' + ($restoredEvidence | ConvertTo-Json -Depth 20 -Compress))
            $script:phase9F001ReverseEvidence = [ordered]@{
                mutant = [ordered]@{ expected = 'no_match'; actual = $mutantEvidence; result = 'FAIL' }
                restored = [ordered]@{ expected = 'no_match'; actual = $restoredEvidence; result = 'PASS' }
                mutation = 'Inspect known zero-match branch replaced by gate accepted entry fallback.'
            }
            Write-Phase9Evidence -Label 'F001_REVERSE_FAILURE' -Value $script:phase9F001ReverseEvidence.mutant
            Write-Phase9Evidence -Label 'F001_RESTORED_PASS' -Value $script:phase9F001ReverseEvidence.restored
        }
        finally {
            foreach ($functionName in $f001ChainFunctionNames) {
                Set-Item -Path ('Function:' + $functionName) -Value $f001ChainOriginalFunctions[$functionName]
            }
            Set-Item -Path Function:\Get-SandboxAclInspectEvidence -Value $f001ChainOriginalAclEvidence
            $script:Model = $null
            $script:ReasoningEffort = $null
            $script:TaskType = $null
            $script:SessionMode = 'cold-start'
            $script:RequiredIdentifier = 'design.md'
            $script:ProcessExitCode = $null
            $script:InvocationBoundParameters = [ordered]@{}
            $global:Model = $null
            $global:ReasoningEffort = $null
            $global:RequiredIdentifier = 'design.md'
        }
    }

    Invoke-Case 'Phase 9 F-010 bidirectional baseline ACL comparison' {
        $originalAclSnapshot = (Get-Command -Name Get-ExplicitAclSnapshot -CommandType Function -ErrorAction Stop).ScriptBlock
        $entryA = [ordered]@{
            identity = 'A'
            identity_resolution = 'resolved'
            access_control_type = 'Allow'
            rights = 'Read'
            inheritance_flags = @('ObjectInherit', 'ContainerInherit')
            propagation_flags = @('None')
            is_inherited = $false
            canonical = '(OI)(CI)(R)'
            fingerprint = ('1' * 64)
        }
        $entryB = [ordered]@{
            identity = 'B'
            identity_resolution = 'resolved'
            access_control_type = 'Allow'
            rights = 'ReadAndExecute'
            inheritance_flags = @('ObjectInherit', 'ContainerInherit')
            propagation_flags = @('None')
            is_inherited = $false
            canonical = '(OI)(CI)(RX)'
            fingerprint = ('2' * 64)
        }
        $entryC = [ordered]@{
            identity = 'C'
            identity_resolution = 'unresolved'
            access_control_type = 'Allow'
            rights = 'Modify'
            inheritance_flags = @('ObjectInherit', 'ContainerInherit')
            propagation_flags = @('None')
            is_inherited = $false
            canonical = '(OI)(CI)(M)'
            fingerprint = ('3' * 64)
        }
        $script:phase9F010PostEntries = @($entryA, $entryC)
        $script:phase9F010SnapshotFunction = {
            param([string]$Path)
            return [ordered]@{
                status = 'known'
                path = (Resolve-AbsolutePath -Path $Path)
                fingerprint = Get-JsonSha256 -Value @($script:phase9F010PostEntries)
                entries = @($script:phase9F010PostEntries)
                explicit_entries = @($script:phase9F010PostEntries)
                captured_at_utc = [datetime]::UtcNow.ToString('o')
                error = $null
            }
        }
        try {
            Set-Item -Path Function:\Get-ExplicitAclSnapshot -Value $script:phase9F010SnapshotFunction
            $record = [pscustomobject]@{
                source_root = $phase9Root
                line_slug = 'line-a'
                dispatch_slug = 'f010-baseline-missing'
                previous_run_id = $null
                resume_anchor_run_id = $null
                sandbox_acl_baseline = [pscustomobject]@{
                    status = 'known'
                    entries = @($entryA, $entryB)
                    explicit_entries = @($entryA, $entryB)
                    fingerprint = Get-JsonSha256 -Value @($entryA, $entryB)
                }
                sandbox_acl_evidence = [pscustomobject]@{
                    capture_status = 'pending'
                    entries = @()
                    captured_at_utc = $null
                    normal_completion = $false
                    continuation_allowed = $false
                }
            }
            $missingEntriesOriginal = (Get-Command -Name Get-SandboxAclMissingEntries -CommandType Function -ErrorAction Stop).ScriptBlock
            $fixedEvidence = Get-SandboxAclInspectEvidence -Record $record -ExecutionRoot $phase9Root -NormalCompletion $true
            $oneWayExtraEntries = @(Get-SandboxAclExtraEntries -BaselineEntries @($entryA, $entryB) -SnapshotEntries @($entryA, $entryC))
            if ($oneWayExtraEntries.Count -ne 1 -or [string](Get-DispatchJsonProperty -Object $oneWayExtraEntries[0] -Name 'identity') -ne 'C') {
                throw ('F-010 單向差集 fixture 未形成 candidate C：' + ($oneWayExtraEntries | ConvertTo-Json -Depth 20 -Compress))
            }
            $script:phase9F010MissingEntriesMutant = {
                param($BaselineEntries, $SnapshotEntries)
                return @()
            }
            $reverseMutantEvidence = $null
            try {
                Set-Item -Path Function:\Get-SandboxAclMissingEntries -Value $script:phase9F010MissingEntriesMutant
                $reverseMutantEvidence = Get-SandboxAclInspectEvidence -Record $record -ExecutionRoot $phase9Root -NormalCompletion $true
            }
            finally {
                Set-Item -Path Function:\Get-SandboxAclMissingEntries -Value $missingEntriesOriginal
            }
            $restoredEvidence = Get-SandboxAclInspectEvidence -Record $record -ExecutionRoot $phase9Root -NormalCompletion $true
            $script:phase9F010PostEntries = @($entryA, $entryB, $entryC)
            $normalEvidence = Get-SandboxAclInspectEvidence -Record $record -ExecutionRoot $phase9Root -NormalCompletion $true
            $script:phase9F010Evidence = [ordered]@{
                failure_scenario = [ordered]@{
                    baseline = @('A', 'B')
                    post = @('A', 'C')
                    expected = 'rejected because baseline entry B is missing'
                }
                wrong_single_direction = $reverseMutantEvidence
                fixed_missing_baseline = $fixedEvidence
                reverse_mutant_failure = [ordered]@{
                    expected = 'rejected'
                    actual = $reverseMutantEvidence
                    result = 'FAIL'
                }
                restored_pass = [ordered]@{
                    expected = 'rejected'
                    actual = $restoredEvidence
                    result = 'PASS'
                }
                normal_first_run = [ordered]@{
                    baseline = @('A', 'B')
                    post = @('A', 'B', 'C')
                    evidence = $normalEvidence
                }
            }
            Write-Phase9Evidence -Label 'F010_BIDIRECTIONAL_COMPARISON' -Value $script:phase9F010Evidence
            Write-Phase9Evidence -Label 'F010_REVERSE_FAILURE' -Value $script:phase9F010Evidence.reverse_mutant_failure
            Write-Phase9Evidence -Label 'F010_RESTORED_PASS' -Value $script:phase9F010Evidence.restored_pass
            Assert-True ([string](Get-DispatchJsonProperty -Object $fixedEvidence -Name 'capture_status') -eq 'rejected' -and -not [bool](Get-DispatchJsonProperty -Object $fixedEvidence -Name 'continuation_allowed')) ('F-010 baseline entry 消失仍被 captured：' + ($fixedEvidence | ConvertTo-Json -Depth 20 -Compress))
            Assert-True ([string](Get-DispatchJsonProperty -Object $reverseMutantEvidence -Name 'capture_status') -eq 'captured') ('F-010 反向單向差集案例未重現 captured 失敗：' + ($reverseMutantEvidence | ConvertTo-Json -Depth 20 -Compress))
            Assert-True ([string](Get-DispatchJsonProperty -Object $restoredEvidence -Name 'capture_status') -eq 'rejected') ('F-010 還原雙向比較後未回到 rejected：' + ($restoredEvidence | ConvertTo-Json -Depth 20 -Compress))
            Assert-True ([string](Get-DispatchJsonProperty -Object $normalEvidence -Name 'capture_status') -eq 'captured' -and [bool](Get-DispatchJsonProperty -Object $normalEvidence -Name 'continuation_allowed')) ('F-010 正常首輪被雙向比較誤擋：' + ($normalEvidence | ConvertTo-Json -Depth 20 -Compress))
        }
        finally {
            Set-Item -Path Function:\Get-ExplicitAclSnapshot -Value $originalAclSnapshot
        }
    }

    Invoke-Case 'Phase 9 F-011 bidirectional continuation gate reaches actual Invoke-Start' {
        $f011FunctionNames = @(
            'Get-WorktreeAclGate'
            'Get-ExplicitAclSnapshot'
            'Resolve-PreviousDispatchRun'
            'Resolve-DispatchBaselineBinding'
            'Resolve-PrepareResultBinding'
            'Test-ScopePlanHashRecord'
            'Get-DispatchUnitList'
            'Test-ContinuationScopePlan'
            'Get-RuntimeModelEvidence'
            'Get-SandboxAclMissingEntries'
            'Invoke-Prepare'
        )
        $f011OriginalFunctions = @{}
        foreach ($functionName in $f011FunctionNames) {
            $f011OriginalFunctions[$functionName] = (Get-Command -Name $functionName -CommandType Function -ErrorAction Stop).ScriptBlock
        }
        $entryA = [ordered]@{
            identity = 'A'
            identity_resolution = 'resolved'
            access_control_type = 'Allow'
            rights = 'Read'
            inheritance_flags = @('ObjectInherit', 'ContainerInherit')
            propagation_flags = @('None')
            is_inherited = $false
            canonical = '(OI)(CI)(R)'
            fingerprint = ('4' * 64)
        }
        $entryB = [ordered]@{
            identity = 'B'
            identity_resolution = 'resolved'
            access_control_type = 'Allow'
            rights = 'ReadAndExecute'
            inheritance_flags = @('ObjectInherit', 'ContainerInherit')
            propagation_flags = @('None')
            is_inherited = $false
            canonical = '(OI)(CI)(RX)'
            fingerprint = ('5' * 64)
        }
        $f011Root = Join-Path $phase9Root 'f011-start'
        $f011SourceRoot = Join-Path $f011Root 'source'
        $f011ExecutionRoot = Join-Path $f011Root 'dispatch'
        $f011LineSlug = 'line-a'
        $f011DispatchSlug = 'f011-missing-whitelist'
        $f011HistoryRoot = Join-Path $f011ExecutionRoot '.local\ai-sessions\history\line-a'
        $f011SourceHistoryRoot = Join-Path $f011SourceRoot '.local\ai-sessions\history'
        $f011RunDirectory = Join-Path (Join-Path $f011SourceHistoryRoot 'line-a\runs') $f011DispatchSlug
        $f011LineRoot = Join-Path $f011SourceRoot '.local\ai-sessions\handoff\line-a'
        $f011ScopePath = Join-Path $f011HistoryRoot 'scope.json'
        $f011PreparePath = Join-Path $f011HistoryRoot 'prepare.json'
        $f011BaselinePath = Join-Path $f011HistoryRoot 'baseline.json'
        $f011PreflightPath = Join-Path $f011HistoryRoot 'preflight.json'
        $f011PromptPath = Join-Path $f011ExecutionRoot 'prompt.md'
        $f011QuotaPath = Join-Path $f011SourceRoot 'quota.json'
        $f011CodexHome = Join-Path $f011ExecutionRoot 'codex-home'
        $f011Thread = [guid]::NewGuid().ToString('D')
        New-Item -ItemType Directory -Path $f011RunDirectory, $f011HistoryRoot, $f011LineRoot, $f011CodexHome -Force | Out-Null
        Write-Utf8NoBom -Path (Join-Path $f011LineRoot 'line.json') -Content (([ordered]@{ schema = 'ai-sessions.line.v1'; 'line-slug' = $f011LineSlug } | ConvertTo-Json -Depth 10) + "`n")
        Write-Utf8NoBom -Path $f011ScopePath -Content (([ordered]@{ decision = 'full'; requested_units = @('Phase 1'); selected_units = @('Phase 1'); deferred_units = @(); scope_plan_fingerprint = 'fixture' } | ConvertTo-Json -Depth 10) + "`n")
        Write-Utf8NoBom -Path $f011PreparePath -Content (([ordered]@{ operation = 'Prepare'; status = 'Prepared' } | ConvertTo-Json -Depth 10) + "`n")
        Write-Utf8NoBom -Path $f011BaselinePath -Content (([ordered]@{ schema = 'fixture.baseline.v1'; base_sha = ('a' * 40) } | ConvertTo-Json -Depth 10) + "`n")
        Write-Utf8NoBom -Path $f011PromptPath -Content 'f011 continuation prompt'
        Write-Utf8NoBom -Path (Join-Path $f011CodexHome 'default.config.toml') -Content ('model = "fixture-model"' + "`r`n" + 'model_reasoning_effort = "high"' + "`r`n")
        $f011QuotaSnapshot = New-Phase8QuotaSnapshot -Path $f011QuotaPath -PrimaryRemainingPercent 80
        $f011BaselineSha256 = Get-FileSha256 -Path $f011BaselinePath
        $f011PrepareSha256 = Get-FileSha256 -Path $f011PreparePath
        $f011ScopeSha256 = Get-FileSha256 -Path $f011ScopePath
        $f011ParentOptions = New-ParentOptionsModel -Profile 'default' -Sandbox 'workspace-write' -WorkingDirectory $f011ExecutionRoot -AddDirectory @() -Search $false -CodexParentOption @()
        $f011PreviousMessagePath = Join-Path $f011HistoryRoot 'previous-message.md'
        Write-Utf8NoBom -Path $f011PreviousMessagePath -Content 'f011 previous message'
        $f011PreviousAnchor = [pscustomobject]@{
            schema = 'ai-sessions.dispatch-run.v1'
            run_id = [guid]::NewGuid().ToString('D')
            line_slug = $f011LineSlug
            dispatch_slug = $f011DispatchSlug
            source_root = $f011SourceRoot
            execution_root = $f011ExecutionRoot
            thread_id = $f011Thread
            last_message_path = $f011PreviousMessagePath
            scope_plan_path = $f011ScopePath
            scope_plan_sha256 = $f011ScopeSha256
            baseline_path = $f011BaselinePath
            baseline_sha256 = $f011BaselineSha256
            model_evidence = $a.model_evidence
            reasoning_effort_evidence = $a.reasoning_effort_evidence
            parent_options = $f011ParentOptions
            sandbox_acl_evidence = [pscustomobject]@{
                capture_status = 'captured'
                entries = @($entryA, $entryB)
                captured_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
                normal_completion = $true
                continuation_allowed = $true
            }
        }
        $f011PreviousRun = [pscustomobject]@{
            Record = $f011PreviousAnchor
            AnchorRecord = $f011PreviousAnchor
            ChainTailRecord = $f011PreviousAnchor
            LatestActualStartRecord = $f011PreviousAnchor
            LatestActualStartEvents = $null
            ScopePlanRootRecord = $f011PreviousAnchor
            Message = 'f011 previous message'
            SkippedAttempts = @()
        }
        $f011Preflight = [ordered]@{
            sourceRoot = $f011SourceRoot
            executionRoot = $f011ExecutionRoot
            dispatchRoot = $f011ExecutionRoot
            lineSlug = $f011LineSlug
            dispatchSlug = $f011DispatchSlug
            writeMode = 'write'
            dispatchKind = 'workflow'
            baseSha = ('a' * 40)
            baselinePath = $f011BaselinePath
            baselineSha256 = $f011BaselineSha256
            prepareResultPath = $f011PreparePath
            prepareResultSha256 = $f011PrepareSha256
            prepareStatus = 'Prepared'
        }
        Write-Utf8NoBom -Path $f011PreflightPath -Content (($f011Preflight | ConvertTo-Json -Depth 20) + "`n")
        $script:phase9F011SourceRoot = $f011SourceRoot
        $script:phase9F011ExecutionRoot = $f011ExecutionRoot
        $script:phase9F011SourceEntries = @($entryA)
        $script:phase9F011DispatchEntries = @($entryA, $entryB)
        $script:phase9F011PreviousRun = $f011PreviousRun
        $script:phase9F011CurrentBaselinePath = $f011BaselinePath
        $script:phase9F011CurrentBaselineSha256 = $f011BaselineSha256
        $script:phase9F011CurrentPreparePath = $f011PreparePath
        $script:phase9F011CurrentPrepareSha256 = $f011PrepareSha256
        $script:phase9F011SnapshotFunction = {
            param([string]$Path)
            $isExecutionRoot = [string]::Equals([IO.Path]::GetFullPath($Path), [IO.Path]::GetFullPath($script:phase9F011ExecutionRoot), [StringComparison]::OrdinalIgnoreCase)
            $entries = if ($isExecutionRoot) { @($script:phase9F011DispatchEntries) } else { @($script:phase9F011SourceEntries) }
            return [ordered]@{
                status = 'known'
                path = (Resolve-AbsolutePath -Path $Path)
                fingerprint = Get-JsonSha256 -Value @($entries)
                entries = @($entries)
                explicit_entries = @($entries)
                captured_at_utc = [datetime]::UtcNow.ToString('o')
                error = $null
            }
        }
        $f011OneWayGate = $null
        $f011FixedGate = $null
        $f011StartResult = $null
        try {
            Set-Item -Path Function:\Get-WorktreeAclGate -Value (Get-Command -Name Invoke-Phase9ProductionAclGate -CommandType Function).ScriptBlock
            Set-Item -Path Function:\Get-ExplicitAclSnapshot -Value $script:phase9F011SnapshotFunction
            Set-Item -Path Function:\Resolve-PreviousDispatchRun -Value ([scriptblock]::Create('param($SourceRoot, $ExecutionRoot, $LineSlug, $DispatchSlug, $ResumeThreadId, $LastMessagePath) return $script:phase9F011PreviousRun'))
            Set-Item -Path Function:\Resolve-DispatchBaselineBinding -Value ([scriptblock]::Create('param($Preflight, $SourceRoot, $DispatchRoot, $LineSlug, $DispatchSlug, $BaseSha) return [pscustomobject]@{ Path = $script:phase9F011CurrentBaselinePath; Sha256 = $script:phase9F011CurrentBaselineSha256 }'))
            Set-Item -Path Function:\Resolve-PrepareResultBinding -Value ([scriptblock]::Create('param($Path, $SourceRoot, $ExecutionRoot, $LineSlug, $DispatchSlug, $ExpectedSha256) return [pscustomobject]@{ Path = $script:phase9F011CurrentPreparePath; Sha256 = $script:phase9F011CurrentPrepareSha256; Status = ''Prepared''; Document = [pscustomobject]@{ operation = ''Prepare''; status = ''Prepared'' }; Artifacts = @() }'))
            Set-Item -Path Function:\Test-ScopePlanHashRecord -Value ([scriptblock]::Create('param($SourceHistoryRoot, $DispatchSlug, $LineSlug, $ScopePlanPath) return $true'))
            Set-Item -Path Function:\Get-DispatchUnitList -Value ([scriptblock]::Create('param($RequestedUnit, $DispatchKind, $UnitKind, $ExecutionRoot, $LineSlug, $EvidencePackPath, $EvidenceQuestionUnits, $TargetPath) return @(''Phase 1'')'))
            Set-Item -Path Function:\Test-ContinuationScopePlan -Value ([scriptblock]::Create('param($ScopePlan, $DispatchSlug, $DispatchKind, $TaskType, $RequestedProfile, $UnitKind, $Units) return $true'))
            Set-Item -Path Function:\Get-RuntimeModelEvidence -Value ([scriptblock]::Create('param($CodexHome, $ThreadId, $StartedAtUtc) return [ordered]@{ model = [ordered]@{ value = ''fixture-model''; status = ''confirmed'' }; reasoning_effort = [ordered]@{ value = ''high''; status = ''confirmed'' }; rollout_paths = @() }'))
            Set-Item -Path Function:\Invoke-Prepare -Value ([scriptblock]::Create('$script:phase9F011PrepareCalls++; throw ''F-011 fixture must reject before Invoke-Prepare.'''))
            $continuationRecord = [pscustomobject]@{ sandbox_acl_evidence = $f011PreviousAnchor.sandbox_acl_evidence }
            $script:phase9F011DispatchEntries = @($entryA, $entryB)
            $normalGate = Invoke-Phase9ProductionAclGate -SourceRoot $f011SourceRoot -ExecutionRoot $f011ExecutionRoot -WriteMode 'worktree' -ContinuationRecord $continuationRecord
            $script:phase9F011DispatchEntries = @($entryA)
            $f011FixedGate = Invoke-Phase9ProductionAclGate -SourceRoot $f011SourceRoot -ExecutionRoot $f011ExecutionRoot -WriteMode 'worktree' -ContinuationRecord $continuationRecord
            $f011MissingEntriesMutant = {
                param($BaselineEntries, $SnapshotEntries)
                return @()
            }
            Set-Item -Path Function:\Get-SandboxAclMissingEntries -Value $f011MissingEntriesMutant
            $f011ReverseMutantGate = Invoke-Phase9ProductionAclGate -SourceRoot $f011SourceRoot -ExecutionRoot $f011ExecutionRoot -WriteMode 'worktree' -ContinuationRecord $continuationRecord
            Set-Item -Path Function:\Get-SandboxAclMissingEntries -Value $f011OriginalFunctions['Get-SandboxAclMissingEntries']
            $f011RestoredGate = Invoke-Phase9ProductionAclGate -SourceRoot $f011SourceRoot -ExecutionRoot $f011ExecutionRoot -WriteMode 'worktree' -ContinuationRecord $continuationRecord
            $script:phase9F011DispatchEntries = @($entryA)
            $script:testThread = $f011Thread
            $script:startCalls = 0
            $script:phase9F011PrepareCalls = 0
            $script:failLaunch = $false
            $script:pidResult.ActiveRecords = @()
            $script:pidResult.UnconfirmedRecords = @()
            $script:pidResult.Blocked = $false
            $script:quotaSnapshotPathOverride = $f011QuotaSnapshot
            $script:phase9F011CurrentBaselinePath = $f011BaselinePath
            $script:phase9F011CurrentPreparePath = $f011PreparePath
            $SourceRoot = $f011SourceRoot
            $ExecutionRoot = $f011ExecutionRoot
            $DispatchRoot = $f011ExecutionRoot
            $LineSlug = $f011LineSlug
            $DispatchSlug = $f011DispatchSlug
            $WriteMode = 'write'
            $PreflightResultPath = $f011PreflightPath
            $PrepareResultPath = $f011PreparePath
            $ScopePlanPath = $f011ScopePath
            $PromptPath = $f011PromptPath
            $CodexHome = $f011CodexHome
            $CodexPath = 'fixture-codex'
            $TargetPath = @('target.txt')
            $ResumeThreadId = $f011Thread
            $LastMessagePath = $null
            $QuotaBeforePath = $f011QuotaSnapshot
            $QuotaAfterPath = $null
            $CalibrationPath = $null
            $TaskType = 'script-change'
            $DispatchKind = 'workflow'
            $Profile = 'default'
            $SessionMode = 'continuation'
            $Model = $null
            $ReasoningEffort = $null
            $AdvisorRequestSource = $null
            $EvidencePackPath = $null
            $AdvisorConsultReportPath = $null
            $PrimaryBudgetPercent = $null
            $PrimaryReservePercent = $null
            $AddDirectory = @()
            $Search = $false
            $CodexParentOption = @()
            $RequiredIdentifier = $null
            $RecoveryHandoffPath = $null
            $EventStreamPath = $null
            $ErrorStreamPath = $null
            $ThreadIdPath = $null
            $PidRecordPath = $null
            $RunRecordPath = $null
            $ProcessExitCode = $null
            $AbortGraceSeconds = 30
            $script:SessionMode = 'continuation'
            $script:ProfileExplicit = $false
            $script:AddDirectoryExplicit = $false
            $script:SearchExplicit = $false
            $script:CodexParentOptionExplicit = $false
            $script:InvocationBoundParameters = [ordered]@{}
            $startException = $null
            try {
                $f011StartOutput = @(Invoke-Start)
                if ($f011StartOutput.Count -eq 1) {
                    $f011StartResult = $f011StartOutput[0]
                }
            }
            catch {
                $startException = $_.Exception
                $f011StartResult = $startException.Data['operationResult']
            }
            $f011Records = @()
            if (Test-Path -LiteralPath $f011RunDirectory -PathType Container) {
                $f011Records = @(Get-ChildItem -LiteralPath $f011RunDirectory -Filter '*.json' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json })
            }
            $f011Failure = if ($null -eq $f011StartResult) { $null } else { Get-DispatchJsonProperty -Object $f011StartResult -Name 'failure' }
            $script:phase9F011Evidence = [ordered]@{
                failure_scenario = [ordered]@{
                    whitelist = @('A', 'B')
                    dispatch_acl = @('A')
                    expected = 'reject continuation before preparation proceeds to external start'
                }
                wrong_single_direction = $f011ReverseMutantGate
                normal_continuation = $normalGate
                fixed_missing_whitelist = $f011FixedGate
                reverse_mutant_failure = [ordered]@{
                    expected = 'residue'
                    actual = $f011ReverseMutantGate
                    result = 'FAIL'
                }
                restored_pass = [ordered]@{
                    expected = 'residue'
                    actual = $f011RestoredGate
                    result = 'PASS'
                }
                actual_invoke_start = [ordered]@{
                    process_started = if ($null -eq $f011StartResult) { $null } else { [bool](Get-DispatchJsonProperty -Object $f011StartResult -Name 'processStarted') }
                    external_start_calls = $script:startCalls
                    invoke_prepare_calls = $script:phase9F011PrepareCalls
                    run_record_states = @($f011Records | ForEach-Object { $_.launch_state })
                    error_code = if ($null -eq $f011StartResult) { $null } else { [string](Get-DispatchJsonProperty -Object $f011StartResult -Name 'errorCode') }
                    failure_stage = if ($null -eq $f011Failure) { $null } else { [string](Get-DispatchJsonProperty -Object (Get-DispatchJsonProperty -Object $f011Failure -Name 'observation') -Name 'failure_stage') }
                    exception = if ($null -eq $startException) { $null } else { $startException.Message }
                }
            }
            Write-Phase9Evidence -Label 'F011_BIDIRECTIONAL_CONTINUATION' -Value $script:phase9F011Evidence
            Write-Phase9Evidence -Label 'F011_REVERSE_FAILURE' -Value $script:phase9F011Evidence.reverse_mutant_failure
            Write-Phase9Evidence -Label 'F011_RESTORED_PASS' -Value $script:phase9F011Evidence.restored_pass
            Assert-True ([string](Get-DispatchJsonProperty -Object $normalGate -Name 'status') -eq 'clean') ('F-011 正常續行被雙向比較誤擋：' + ($normalGate | ConvertTo-Json -Depth 20 -Compress))
            Assert-True ([string](Get-DispatchJsonProperty -Object $f011FixedGate -Name 'status') -eq 'residue' -and [string](Get-DispatchJsonProperty -Object $f011FixedGate -Name 'rejection_code') -eq 'WorktreeAclResidue') ('F-011 whitelist entry 消失仍回傳 clean：' + ($f011FixedGate | ConvertTo-Json -Depth 20 -Compress))
            Assert-True ([string](Get-DispatchJsonProperty -Object $f011ReverseMutantGate -Name 'status') -eq 'clean') ('F-011 反向單向差集案例未重現 clean 失敗：' + ($f011ReverseMutantGate | ConvertTo-Json -Depth 20 -Compress))
            Assert-True ([string](Get-DispatchJsonProperty -Object $f011RestoredGate -Name 'status') -eq 'residue') ('F-011 還原雙向比較後未回到 residue：' + ($f011RestoredGate | ConvertTo-Json -Depth 20 -Compress))
            Assert-True ($null -ne $f011StartResult -and -not [bool](Get-DispatchJsonProperty -Object $f011StartResult -Name 'processStarted') -and $script:phase9F011PrepareCalls -eq 0 -and $script:startCalls -eq 0) ('F-011 真實 Invoke-Start 未在 Invoke-Prepare 或 external start 前拒絕：' + ($script:phase9F011Evidence.actual_invoke_start | ConvertTo-Json -Depth 20 -Compress))
        }
        finally {
            foreach ($functionName in $f011FunctionNames) {
                Set-Item -Path ('Function:' + $functionName) -Value $f011OriginalFunctions[$functionName]
            }
            $script:SessionMode = 'cold-start'
            $script:quotaSnapshotPathOverride = $null
            $script:InvocationBoundParameters = [ordered]@{}
        }
    }

    $writerFunctionAst = @($functions | Where-Object { $_.Name -eq 'Write-Utf8NoBom' } | Select-Object -First 1)
    Assert-True ($writerFunctionAst.Count -eq 1) 'Phase 9 找不到 production Write-Utf8NoBom AST。'
    $writerFunctionDefinition = $writerFunctionAst[0].Extent.Text -replace '^function Write-Utf8NoBom', 'function Invoke-Phase9OriginalWriteUtf8NoBom'
    . ([scriptblock]::Create($writerFunctionDefinition))
    $atomicFunctionAst = @($functions | Where-Object { $_.Name -eq 'Write-DispatchAtomicJsonDocument' } | Select-Object -First 1)
    Assert-True ($atomicFunctionAst.Count -eq 1) 'Phase 9 找不到 production Write-DispatchAtomicJsonDocument AST。'
    $atomicAfterCasInjection = @'
        if ($null -ne $script:phase9AtomicAfterCasHook) {
            & $script:phase9AtomicAfterCasHook
        }
'@
    $atomicFunctionDefinition = $atomicFunctionAst[0].Extent.Text -replace '^function Write-DispatchAtomicJsonDocument', 'function Invoke-Phase9ProductionAtomicWriter'
    $atomicInjectionMarker = '        if ([System.IO.File]::Exists($resolvedFileApiPath)) {'
    if (-not $atomicFunctionDefinition.Contains($atomicInjectionMarker)) {
        $atomicInjectionMarker = '        if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {'
    }
    Assert-True ($atomicFunctionDefinition.Contains($atomicInjectionMarker)) 'Phase 9 atomic production writer clone 缺少 CAS injection marker。'
    $atomicFunctionDefinition = $atomicFunctionDefinition.Replace($atomicInjectionMarker, ($atomicAfterCasInjection + $atomicInjectionMarker))
    try {
        . ([scriptblock]::Create($atomicFunctionDefinition))
    }
    catch {
        throw ('Phase 9 atomic production writer clone failed: ' + $_.Exception.Message + ' | script=' + $_.ScriptStackTrace)
    }
    $atomicMutantDefinition = $atomicFunctionDefinition.Replace('        $lock = Open-DispatchResultLock -ResolvedPath $resolvedPath', '        $lock = $null')
    $atomicMutantDefinition = $atomicMutantDefinition -replace '^function Invoke-Phase9ProductionAtomicWriter', 'function Invoke-Phase9MutantAtomicWriter'
    try {
        . ([scriptblock]::Create($atomicMutantDefinition))
    }
    catch {
        throw ('Phase 9 atomic mutant writer clone failed: ' + $_.Exception.Message + ' | script=' + $_.ScriptStackTrace)
    }
    $script:phase9CaptureOnly = $false
    $script:phase9CapturedWrites = New-Object System.Collections.Generic.List[object]
    $script:phase9AtomicAfterCasHook = $null
    $script:phase9CapturePath = $null
    $script:phase9CasMutationTargetPath = $null
    $script:phase9CasMutationDone = $false
    $script:phase9RealDispatchGitSourceRoot = $null
    $script:phase9RealDispatchGitRoot = $null
    $script:phase9RealDispatchGitInitialized = $false
    function Write-Utf8NoBom {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][AllowEmptyString()][string]$Content
        )
        if (-not $script:phase9CasMutationDone -and
            -not [string]::IsNullOrWhiteSpace($script:phase9CasMutationTargetPath) -and
            [IO.Path]::GetFileName($Path) -like '*.dispatch.tmp' -and
            (Test-Path -LiteralPath $script:phase9CasMutationTargetPath -PathType Leaf)) {
            $script:phase9CasMutationDone = $true
            $concurrentDocument = ConvertFrom-DispatchJson -Content (Get-Content -LiteralPath $script:phase9CasMutationTargetPath -Raw -Encoding UTF8)
            $concurrentDocument | Add-Member -MemberType NoteProperty -Name 'concurrent_marker' -Value 'phase9-cas-fixture' -Force
            $concurrentDocument.result_sha256 = Get-PrepareDocumentFingerprint -Document $concurrentDocument
            Invoke-Phase9OriginalWriteUtf8NoBom -Path $script:phase9CasMutationTargetPath -Content (($concurrentDocument | ConvertTo-Json -Depth 40) + "`n")
        }
        if ($script:phase9CaptureOnly -and [string]::Equals([IO.Path]::GetFullPath($Path), [IO.Path]::GetFullPath($script:phase9CapturePath), [StringComparison]::OrdinalIgnoreCase)) {
            $script:phase9CapturedWrites.Add([pscustomobject]@{ path = $Path; content = $Content })
            return
        }
        Invoke-Phase9OriginalWriteUtf8NoBom -Path $Path -Content $Content
    }

    Invoke-Case 'Phase 9 P2 output path local history allowed' {
        $allowedPath = Join-Path $phase9Root '.local\ai-sessions\history\allowed-result.json'
        $script:SourceRoot = $phase9Root
        $script:TargetPath = @()
        $script:ResultPath = $allowedPath
        $script:phase9CaptureOnly = $false
        $null = Write-OperationResult -Result ([ordered]@{ schema = 'fixture.result.v1'; status = 'ok' })
        Assert-True (Test-Path -LiteralPath $allowedPath -PathType Leaf) 'local history result 未寫入。'
        $bytes = [IO.File]::ReadAllBytes($allowedPath)
        Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'result file 不應含 BOM。'
    }

    Invoke-Case 'Phase 9 P2 non-local result path allowed' {
        $nonLocalRoot = Join-Path $phase9Root 'reviewer'
        New-Item -ItemType Directory -Path $nonLocalRoot -Force | Out-Null
        $nonLocalPath = Join-Path $nonLocalRoot 'non-local-result.json'
        $unmatchedTargetPath = Join-Path $phase9Root 'fixture-target.txt'
        $script:SourceRoot = $phase9Root
        $script:ExecutionRoot = $phase9Root
        $script:TargetPath = @($unmatchedTargetPath)
        $script:ResultPath = $nonLocalPath
        $script:phase9CaptureOnly = $false
        $writeSucceeded = $false
        $writeError = $null
        try {
            $null = Write-OperationResult -Result ([ordered]@{ schema = 'fixture.result.v1'; status = 'ok' })
            $writeSucceeded = Test-Path -LiteralPath $nonLocalPath -PathType Leaf
        }
        catch {
            $writeError = $_.Exception.Message
        }
        Assert-True $writeSucceeded ('DispatchOutputBoundary；write_succeeded=' + $writeSucceeded + '；result=FAIL；error=' + [string]$writeError)
        $writtenResult = Get-Content -LiteralPath $nonLocalPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($writtenResult.schema -eq 'fixture.result.v1' -and $writtenResult.status -eq 'ok') '非 .local 結果檔內容不符。'
    }

    Invoke-Case 'Phase 9 P2 tracked result path rejected' {
        $trackedPath = Join-Path $root 'scripts\Invoke-CodexDispatch.ps1'
        $beforeHash = Get-FileSha256 -Path $trackedPath
        $script:SourceRoot = $root
        $script:TargetPath = @($trackedPath)
        $script:ResultPath = $trackedPath
        $script:phase9CapturePath = $trackedPath
        $script:phase9CaptureOnly = $true
        $script:phase9CapturedWrites.Clear()
        $caught = $null
        try {
            $null = Write-OperationResult -Result ([ordered]@{ schema = 'fixture.result.v1'; status = 'should-reject' })
        }
        catch {
            $caught = $_.Exception
        }
        $afterHash = Get-FileSha256 -Path $trackedPath
        Assert-True ($null -ne $caught -and $caught.Message.Contains('DispatchOutputTrackedTarget')) 'tracked result path 未回傳明確拒絕碼。'
        Assert-True ($beforeHash -eq $afterHash -and $script:phase9CapturedWrites.Count -eq 0) 'tracked file 已被寫入或 temporary writer 已啟動。'
    }

    Invoke-Case 'Phase 9 P2 TargetPath result collision rejected' {
        $collisionRoot = Join-Path $phase9Root 'target-collision'
        New-Item -ItemType Directory -Path $collisionRoot -Force | Out-Null
        $collisionPath = Join-Path $collisionRoot 'result.json'
        $script:SourceRoot = $phase9Root
        $script:TargetPath = @($collisionRoot)
        $script:ResultPath = $collisionPath
        $script:phase9CapturePath = $collisionPath
        $script:phase9CaptureOnly = $true
        $script:phase9CapturedWrites.Clear()
        $caught = $null
        try {
            $null = Write-OperationResult -Result ([ordered]@{ schema = 'fixture.result.v1'; status = 'should-reject' })
        }
        catch {
            $caught = $_.Exception
        }
        Assert-True ($null -ne $caught -and $caught.Message.Contains('DispatchOutputTargetCollision')) 'TargetPath collision 未回傳明確拒絕碼。'
        Assert-True (-not (Test-Path -LiteralPath $collisionPath -PathType Leaf) -and $script:phase9CapturedWrites.Count -eq 0) 'TargetPath collision 已建立結果或 temporary file。'
    }

    $dispatchRequestPath = Join-Path $phase9Root 'dispatch-request.json'
    $dispatchResultPath = Join-Path $phase9Root '.local\ai-sessions\history\dispatch-result.json'
    $dispatchRequest = [ordered]@{
        schema = 'ai-sessions.dispatch-request.v1'
        operation = 'Dispatch'
        source_root = $phase9Root
        dispatch_root = (Join-Path $phase9Root 'dispatch-root')
        line_slug = 'line-a'
        dispatch_slug = 'phase9-dispatch'
        write_mode = 'readonly'
        dispatch_kind = 'workflow'
        prompt_path = (Join-Path $phase9Root 'dispatch-prompt.md')
        task_type = 'script-change'
        session_mode = 'cold-start'
        unit_kind = 'workflow-phase'
        requested_unit = @('Phase 1')
        failure_receipt_path = (Join-Path $phase9Root '.local\ai-sessions\history\failure-receipt.json')
        result_path = $dispatchResultPath
        preflight_result_path = (Join-Path $phase9Root '.local\ai-sessions\history\preflight.json')
        prepare_result_path = (Join-Path $phase9Root '.local\ai-sessions\history\prepare.json')
        quota_before_path = (Join-Path $phase9Root '.local\ai-sessions\history\quota-before.json')
        target_path = @('fixture-target.txt')
        prepare_artifacts = @()
    }
    $script:phase9CaptureOnly = $false
    Write-Utf8NoBom -Path $dispatchRequest.prompt_path -Content 'fixture dispatch prompt'
    Write-Utf8NoBom -Path $dispatchRequestPath -Content (($dispatchRequest | ConvertTo-Json -Depth 20) + "`n")

    $phase9RequiredDispatchFields = @(
        'source_root'
        'dispatch_root'
        'write_mode'
        'dispatch_kind'
        'target_path'
        'prepare_artifacts'
        'prompt_path'
        'task_type'
        'session_mode'
        'unit_kind'
        'requested_unit'
        'failure_receipt_path'
    )
    Invoke-Case 'Phase 9 F-005 actual Dispatch CLI rejects every missing field before external start' {
        $hostPath = (Get-Command powershell.exe -ErrorAction Stop).Source
        $counterPath = Join-Path $phase9Root 'f005-external-started.txt'
        $fakeCodexPath = Join-Path $phase9Root 'codex.cmd'
        Write-Utf8NoBom -Path $fakeCodexPath -Content ('@echo off' + "`r`n" + ('>"' + $counterPath + '" echo started') + "`r`n" + 'exit /b 0' + "`r`n")
        $pathValue = $phase9Root + ';' + [string]$env:PATH
        $runRecords = New-Object System.Collections.Generic.List[object]
        foreach ($field in $phase9RequiredDispatchFields) {
            $candidate = [ordered]@{}
            foreach ($propertyName in $dispatchRequest.Keys) {
                $candidate[$propertyName] = $dispatchRequest[$propertyName]
            }
            $candidate.Remove($field)
            $candidatePath = Join-Path $phase9Root ('dispatch-request-missing-' + $field + '.json')
            Write-Utf8NoBom -Path $candidatePath -Content (($candidate | ConvertTo-Json -Depth 20) + "`n")
            $run = Invoke-Phase9Process -HostPath $hostPath -Arguments @(
                '-NoProfile'
                '-File'
                $sourcePath
                '-Operation'
                'Dispatch'
                '-RequestPath'
                $candidatePath
            ) -WorkingDirectory $root -EnvironmentVariables @{ PATH = $pathValue }
            $runRecords.Add([pscustomobject]@{ field = $field; request_path = $candidatePath; run = $run })
            Assert-True ([int]$run.exit_code -ne 0) ('缺少 ' + $field + ' 時 CLI 應以非零結束。')
            Assert-True ([string]$run.stdout -match 'DispatchRequestMissingField' -or [string]$run.stderr -match 'DispatchRequestMissingField') ('缺少 ' + $field + ' 時未回傳 DispatchRequestMissingField：' + [string]$run.stdout + [string]$run.stderr)
            Assert-True (-not (Test-Path -LiteralPath $counterPath -PathType Leaf)) ('缺少 ' + $field + ' 時已啟動外部工作。')
        }
        Assert-True ($runRecords.Count -eq $phase9RequiredDispatchFields.Count) 'F-005 未逐一執行所有 required dispatch field 的實際 CLI 入口。'
        $script:phase9F005CliEvidence = @($runRecords.ToArray())
    }

    Invoke-Case 'Phase 9 F-005 reverse bypassed request validation is observable at CLI' {
        $readRequestAst = @($functions | Where-Object { $_.Name -eq 'Read-DispatchRequest' } | Select-Object -First 1)
        Assert-True ($readRequestAst.Count -eq 1) 'F-005 找不到 production Read-DispatchRequest AST。'
        $missingFieldThrow = 'Throw-DispatchRequestFailure -Code ''DispatchRequestMissingField'' -Message ("Dispatch request file 缺少必要欄位：{0}" -f $requiredDispatchField) -RequestPathValue $requestPathValue -Field $requiredDispatchField'
        $mutantSource = $readRequestAst[0].Extent.Text.Replace('function Read-DispatchRequest', 'function Read-DispatchRequest')
        Assert-True ($mutantSource.Contains($missingFieldThrow)) 'F-005 reverse fixture 找不到 required field rejection。'
        $mutantSource = $mutantSource.Replace($missingFieldThrow, '$null = $requiredDispatchField')
        $mutantPath = Join-Path $phase9Root 'f005-mutant-Invoke-CodexDispatch.ps1'
        $bomEncoding = New-Object System.Text.UTF8Encoding($true)
        [IO.File]::WriteAllText($mutantPath, (Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8).Replace($readRequestAst[0].Extent.Text, $mutantSource), $bomEncoding)
        $missingRequestPath = [string]$script:phase9F005CliEvidence[0].request_path
        $hostPath = (Get-Command powershell.exe -ErrorAction Stop).Source
        $pathValue = $phase9Root + ';' + [string]$env:PATH
        $reverseRun = Invoke-Phase9Process -HostPath $hostPath -Arguments @(
            '-NoProfile'
            '-File'
            $mutantPath
            '-Operation'
            'Dispatch'
            '-RequestPath'
            $missingRequestPath
        ) -WorkingDirectory $root -EnvironmentVariables @{ PATH = $pathValue }
        $reverseOutput = [string]$reverseRun.stdout + [string]$reverseRun.stderr
        Assert-True ([int]$reverseRun.exit_code -ne 0 -and $reverseOutput -match '"status"\s*:\s*"failed"' -and $reverseOutput -match '"failed_stage"\s*:\s*"validation"') ('F-005 reverse mutant did not expose the late validation regression：' + $reverseOutput)
        Assert-True ($reverseOutput -notmatch 'DispatchRequestMissingField') ('F-005 reverse mutant still rejected at request validation：' + $reverseOutput)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $phase9Root 'f005-external-started.txt') -PathType Leaf)) ('F-005 reverse mutant unexpectedly launched external work：' + $reverseOutput)
        $restoredRun = Invoke-Phase9Process -HostPath $hostPath -Arguments @(
            '-NoProfile'
            '-File'
            $sourcePath
            '-Operation'
            'Dispatch'
            '-RequestPath'
            $missingRequestPath
        ) -WorkingDirectory $root -EnvironmentVariables @{ PATH = $pathValue }
        $restoredOutput = [string]$restoredRun.stdout + [string]$restoredRun.stderr
        Assert-True ([int]$restoredRun.exit_code -ne 0 -and $restoredOutput -match 'DispatchRequestMissingField') ('F-005 restored production did not reject the request at the CLI boundary：' + $restoredOutput)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $phase9Root 'f005-external-started.txt') -PathType Leaf)) ('F-005 restored production launched external work：' + $restoredOutput)
        $script:phase9F005ReverseEvidence = [pscustomobject]@{
            mutant = $reverseRun
            restored = $restoredRun
            mutation = 'Read-DispatchRequest required dispatch field throw replaced with a no-op.'
        }
        Write-Phase9Evidence -Label 'F005_NORMAL_FAILURES' -Value @($script:phase9F005CliEvidence)
        Write-Phase9Evidence -Label 'F005_REVERSE_FAILURE' -Value $reverseRun
        Write-Phase9Evidence -Label 'F005_RESTORED_PASS' -Value $restoredRun
    }

    $invokeF009Case = {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][ValidateSet('existing', 'boundary', 'manifest')][string]$Scenario,
            [Parameter(Mandatory)][string]$ScriptPath,
            [switch]$ReceiptDirectory
        )

        $caseRoot = Join-Path $phase9Root ('f009-' + $Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $sourceRoot = Join-Path $caseRoot 'source'
        $lineRoot = Join-Path $sourceRoot '.local\ai-sessions\handoff\line-a'
        $sourceHistoryRoot = Join-Path $sourceRoot '.local\ai-sessions\history'
        $expectedDispatchRoot = Join-Path $sourceRoot ('.local\ai-sessions\worktrees\f009-' + $Name)
        $dispatchRoot = $expectedDispatchRoot
        if ($Scenario -eq 'boundary') {
            $dispatchRoot = Join-Path $caseRoot 'outside-dispatch-root'
        }
        $promptPath = Join-Path $sourceRoot 'dispatch-prompt.md'
        $targetPath = Join-Path $sourceRoot 'target.txt'
        $requestPath = Join-Path $caseRoot 'dispatch-request.json'
        $resultPath = Join-Path $sourceHistoryRoot ('f009-' + $Name + '-result.json')
        $preflightResultPath = Join-Path $sourceHistoryRoot ('f009-' + $Name + '-preflight.json')
        $prepareResultPath = Join-Path $sourceHistoryRoot ('f009-' + $Name + '-prepare.json')
        $quotaBeforePath = Join-Path $sourceHistoryRoot ('f009-' + $Name + '-quota-before.json')
        $receiptPath = Join-Path $sourceHistoryRoot ('f009-' + $Name + '-failure-receipt.json')
        $counterPath = Join-Path $caseRoot 'external-started.txt'
        $fakeCodexPath = Join-Path $caseRoot 'codex.cmd'

        New-Item -ItemType Directory -Path $sourceRoot, $lineRoot, $sourceHistoryRoot -Force | Out-Null
        Write-Utf8NoBom -Path $promptPath -Content ('F-009 ' + $Name + ' prompt')
        Write-Utf8NoBom -Path $targetPath -Content ('F-009 ' + $Name + ' target')
        if ($Scenario -eq 'manifest') {
            Write-Utf8NoBom -Path (Join-Path $lineRoot 'line.json') -Content '{invalid-json'
        }
        else {
            Write-Utf8NoBom -Path (Join-Path $lineRoot 'line.json') -Content (([ordered]@{ schema = 'ai-sessions.line.v1'; 'line-slug' = 'line-a' } | ConvertTo-Json -Depth 10) + "`n")
        }
        if ($Scenario -eq 'existing') {
            New-Item -ItemType Directory -Path $expectedDispatchRoot -Force | Out-Null
        }
        if ($ReceiptDirectory) {
            New-Item -ItemType Directory -Path $receiptPath -Force | Out-Null
        }
        Write-Utf8NoBom -Path $fakeCodexPath -Content (('@echo off' + "`r`n") + ('>"' + $counterPath + '" echo started' + "`r`n") + ('exit /b 0' + "`r`n"))

        $request = [ordered]@{
            schema = 'ai-sessions.dispatch-request.v1'
            operation = 'Dispatch'
            source_root = $sourceRoot
            dispatch_root = $dispatchRoot
            line_slug = 'line-a'
            dispatch_slug = 'f009-' + $Name
            profile = 'default'
            write_mode = 'readonly'
            dispatch_kind = 'workflow'
            target_path = @('target.txt')
            prepare_artifacts = @()
            prompt_path = $promptPath
            task_type = 'script-change'
            session_mode = 'cold-start'
            unit_kind = 'workflow-phase'
            requested_unit = @('Phase 1')
            failure_receipt_path = $receiptPath
            result_path = $resultPath
            preflight_result_path = $preflightResultPath
            prepare_result_path = $prepareResultPath
            quota_before_path = $quotaBeforePath
        }
        Write-Utf8NoBom -Path $requestPath -Content (($request | ConvertTo-Json -Depth 20) + "`n")

        $hostPath = (Get-Command powershell.exe -ErrorAction Stop).Source
        $run = Invoke-Phase9Process -HostPath $hostPath -Arguments @(
            '-NoProfile'
            '-File'
            $ScriptPath
            '-CodexPath'
            $fakeCodexPath
            '-Operation'
            'Dispatch'
            '-RequestPath'
            $requestPath
        ) -WorkingDirectory $root -EnvironmentVariables @{}
        $outputDocument = $null
        try {
            $outputDocument = ConvertFrom-Json -InputObject ([string]$run.stdout)
        }
        catch {
            $outputDocument = $null
        }
        $receiptDocument = $null
        if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
            try {
                $receiptDocument = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
            }
            catch {
                $receiptDocument = $null
            }
        }
        return [pscustomobject]@{
            name = $Name
            scenario = $Scenario
            request_path = $requestPath
            receipt_path = $receiptPath
            case_root = $caseRoot
            run = $run
            output_text = ([string]$run.stdout + [string]$run.stderr)
            output_document = $outputDocument
            receipt_document = $receiptDocument
            receipt_exists = Test-Path -LiteralPath $receiptPath -PathType Leaf
            receipt_directory_exists = Test-Path -LiteralPath $receiptPath -PathType Container
            start_counter_exists = Test-Path -LiteralPath $counterPath -PathType Leaf
        }
    }

    $assertF009Receipt = {
        param([psobject]$Record, [string]$Label)
        Assert-True ([string]$Record.run.command -match 'Operation.*Dispatch' -and [string]$Record.run.command -match 'RequestPath') ('F-009 ' + $Label + ' 未透過實際 Dispatch CLI 入口：' + [string]$Record.run.command)
        Assert-True ([int]$Record.run.exit_code -ne 0) ('F-009 ' + $Label + ' CLI failed envelope 未以非零結束碼回傳：' + [string]$Record.output_text)
        Assert-True ($null -ne $Record.output_document -and [string]$Record.output_document.status -eq 'failed' -and [string]$Record.output_document.failed_stage -eq 'preflight' -and -not [bool]$Record.output_document.process_started) ('F-009 ' + $Label + ' CLI failed envelope 欄位不符：' + [string]$Record.output_text)
        Assert-True ($Record.receipt_exists -and $null -ne $Record.receipt_document) ('F-009 ' + $Label + ' failure receipt missing：' + [string]$Record.output_text)
        $receipt = $Record.receipt_document
        Assert-True ([string]$receipt.schema -eq 'ai-sessions.dispatch-failure-receipt.v1' -and [string]$receipt.status -eq 'failed' -and [string]$receipt.failed_stage -eq 'preflight' -and -not [bool]$receipt.process_started) ('F-009 ' + $Label + ' receipt status contract 不符：' + ($receipt | ConvertTo-Json -Depth 20 -Compress))
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$receipt.error_code) -and -not [string]::IsNullOrWhiteSpace([string]$receipt.dispatch_slug)) ('F-009 ' + $Label + ' receipt 缺少 error_code 或 dispatch_slug：' + ($receipt | ConvertTo-Json -Depth 20 -Compress))
        $dispatchExecutionId = [guid]::Empty
        Assert-True ([Guid]::TryParse([string]$receipt.dispatch_execution_id, [ref]$dispatchExecutionId)) ('F-009 ' + $Label + ' receipt 缺少 dispatch_execution_id：' + ($receipt | ConvertTo-Json -Depth 20 -Compress))
        Assert-True ([bool]$receipt.failure_receipt_saved -and [string]::Equals([string]$receipt.failure_receipt_path, [string]$Record.receipt_path, [StringComparison]::OrdinalIgnoreCase)) ('F-009 ' + $Label + ' receipt saved metadata 不符：' + ($receipt | ConvertTo-Json -Depth 20 -Compress))
        Assert-True ($null -eq $receipt.PSObject.Properties['stage_binding']) ('F-009 ' + $Label + ' receipt 不得帶入 stage_binding。')
        Assert-True (-not [bool]$Record.start_counter_exists) ('F-009 ' + $Label + ' Preflight failure 已呼叫外部 Start。')
    }

    Invoke-Case 'Phase 9 F-009 actual Dispatch Preflight failure receipt matrix' {
        $f009NormalRecords = New-Object System.Collections.Generic.List[object]
        foreach ($scenario in @('existing', 'boundary', 'manifest')) {
            $record = & $invokeF009Case -Name ('normal-' + $scenario) -Scenario $scenario -ScriptPath $sourcePath
            & $assertF009Receipt $record ('normal-' + $scenario)
            $f009NormalRecords.Add($record)
        }
        $script:phase9F009NormalEvidence = @($f009NormalRecords.ToArray())
        Write-Phase9Evidence -Label 'F009_NORMAL_PASS' -Value $script:phase9F009NormalEvidence
    }

    Invoke-Case 'Phase 9 F-009 failure receipt persistence failure returns nonzero' {
        $persistenceRecord = & $invokeF009Case -Name 'normal-persistence' -Scenario 'existing' -ScriptPath $sourcePath -ReceiptDirectory
        Assert-True ([string]$persistenceRecord.run.command -match 'Operation.*Dispatch' -and [string]$persistenceRecord.run.command -match 'RequestPath') ('F-009 persistence 未透過實際 Dispatch CLI 入口：' + [string]$persistenceRecord.run.command)
        Assert-True ([int]$persistenceRecord.run.exit_code -ne 0) ('F-009 receipt persistence failure 未以非零結束：' + [string]$persistenceRecord.output_text)
        Assert-True ($null -ne $persistenceRecord.output_document -and [string]$persistenceRecord.output_document.error_code -eq 'DispatchFailureReceiptPersistenceFailed' -and -not [bool]$persistenceRecord.output_document.failure_receipt_saved -and -not [bool]$persistenceRecord.output_document.process_started) ('F-009 receipt persistence failure envelope 不符：' + [string]$persistenceRecord.output_text)
        Assert-True ($persistenceRecord.receipt_directory_exists -and -not $persistenceRecord.receipt_exists -and -not [bool]$persistenceRecord.start_counter_exists) ('F-009 receipt persistence failure 宣告了 receipt 或啟動外部工作。')
        $script:phase9F009PersistenceEvidence = $persistenceRecord
        Write-Phase9Evidence -Label 'F009_PERSISTENCE_FAILURE' -Value $persistenceRecord
    }

    Invoke-Case 'Phase 9 F-009 reverse execution-root receipt guard fails closed' {
        $productionText = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
        $receiptCondition = 'if (-not [string]::IsNullOrWhiteSpace($failureReceiptPathValue)) {'
        $mutantCondition = 'if (-not [string]::IsNullOrWhiteSpace($failureReceiptPathValue) -and -not [string]::IsNullOrWhiteSpace($executionRootPath)) {'
        Assert-True ($productionText.Contains($receiptCondition)) 'F-009 reverse 找不到 failure receipt writer 的 production guard。'
        $mutantText = $productionText.Replace($receiptCondition, $mutantCondition)
        Assert-True ($mutantText -ne $productionText) 'F-009 reverse mutant 未改變 executionRoot guard。'
        $mutantPath = Join-Path $phase9Root 'f009-mutant-Invoke-CodexDispatch.ps1'
        $bomEncoding = New-Object System.Text.UTF8Encoding($true)
        [IO.File]::WriteAllText($mutantPath, $mutantText, $bomEncoding)
        $reverseRecords = New-Object System.Collections.Generic.List[object]
        foreach ($scenario in @('existing', 'boundary', 'manifest')) {
            $record = & $invokeF009Case -Name ('reverse-' + $scenario) -Scenario $scenario -ScriptPath $mutantPath
            Assert-True ([string]$record.run.command -match 'Operation.*Dispatch' -and [string]$record.run.command -match 'RequestPath') ('F-009 reverse ' + $scenario + ' 未透過實際 Dispatch CLI 入口。')
            Assert-True ([int]$record.run.exit_code -ne 0 -and $null -ne $record.output_document -and [string]$record.output_document.status -eq 'failed' -and [string]$record.output_document.failed_stage -eq 'preflight') ('F-009 reverse ' + $scenario + ' 未留下 late failed envelope：' + [string]$record.output_text)
            Assert-True (-not $record.receipt_exists -and -not [bool]$record.start_counter_exists -and -not [bool]$record.output_document.failure_receipt_saved) ('F-009 reverse ' + $scenario + ' 意外宣告 failure receipt 已保存：' + [string]$record.output_text)
            $reverseRecords.Add($record)
        }
        $script:phase9F009ReverseEvidence = [ordered]@{ mutation = 'failure receipt writer additionally required executionRootPath to be non-empty'; records = @($reverseRecords.ToArray()) }
        Write-Phase9Evidence -Label 'F009_REVERSE_FAILURE' -Value $script:phase9F009ReverseEvidence
    }

    Invoke-Case 'Phase 9 F-009 restored receipt writer persists after reverse' {
        $restoredRecords = New-Object System.Collections.Generic.List[object]
        foreach ($scenario in @('existing', 'boundary', 'manifest')) {
            $record = & $invokeF009Case -Name ('restored-' + $scenario) -Scenario $scenario -ScriptPath $sourcePath
            & $assertF009Receipt $record ('restored-' + $scenario)
            $restoredRecords.Add($record)
        }
        $restoredPersistence = & $invokeF009Case -Name 'restored-persistence' -Scenario 'existing' -ScriptPath $sourcePath -ReceiptDirectory
        Assert-True ([int]$restoredPersistence.run.exit_code -ne 0 -and $null -ne $restoredPersistence.output_document -and [string]$restoredPersistence.output_document.error_code -eq 'DispatchFailureReceiptPersistenceFailed' -and -not [bool]$restoredPersistence.output_document.failure_receipt_saved -and -not [bool]$restoredPersistence.start_counter_exists) ('F-009 restored persistence failure contract 不符：' + [string]$restoredPersistence.output_text)
        $script:phase9F009RestoredEvidence = [ordered]@{ matrix = @($restoredRecords.ToArray()); persistence_failure = $restoredPersistence }
        Write-Phase9Evidence -Label 'F009_RESTORED_PASS' -Value $script:phase9F009RestoredEvidence
    }

    $invokeSRealDispatchCase = {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][string]$ScriptPath,
            [switch]$OmitQuotaBeforePath,
            [switch]$PrepareFailure,
            [switch]$CreateQuotaBeforePath
        )

        $caseSlug = 's' + [guid]::NewGuid().ToString('N').Substring(0, 6)
        $caseRoot = Join-Path $sRealDispatchParent $caseSlug
        $sourceRoot = $caseRoot
        $lineRoot = Join-Path $sourceRoot '.local\ai-sessions\handoff\a'
        $sourceHistoryRoot = Join-Path $sourceRoot '.local\ai-sessions\history\a'
        $dispatchRoot = Join-Path $sourceRoot ('.local\ai-sessions\worktrees\' + $caseSlug)
        $dispatchHistoryRoot = Join-Path $dispatchRoot '.local\ai-sessions\history\a'
        $promptSourcePath = Join-Path $sourceRoot 'dispatch-prompt.md'
        $promptPath = Join-Path $dispatchRoot 'dispatch-prompt.md'
        $targetPath = Join-Path $sourceRoot 'target.txt'
        $requestPath = Join-Path $caseRoot 'dispatch-request.json'
        $resultPath = Join-Path $dispatchHistoryRoot 'dispatch-result.json'
        $preflightResultPath = Join-Path $sourceRoot 'preflight-result.json'
        $prepareResultPath = Join-Path $dispatchHistoryRoot 'prepare.json'
        $quotaBeforePath = Join-Path $sourceHistoryRoot 'quota-before.json'
        $failureReceiptPath = Join-Path $sourceHistoryRoot 'failure-receipt.json'
        $artifactSourcePath = Join-Path $lineRoot 'artifact.txt'
        $artifactDestinationPath = Join-Path $dispatchHistoryRoot 'artifact.txt'
        $codexHome = Join-Path $caseRoot 'codex-home'
        $fakeCodexPath = Join-Path $caseRoot 'codex.cmd'
        $counterPath = Join-Path $caseRoot 'external-started.txt'
        $threadId = [guid]::NewGuid().ToString('D')

        New-Item -ItemType Directory -Path $sourceRoot, $lineRoot, $sourceHistoryRoot, $codexHome -Force | Out-Null
        Write-Utf8NoBom -Path $promptSourcePath -Content ('S finding dispatch prompt: ' + $Name)
        Write-Utf8NoBom -Path $targetPath -Content ('S finding target: ' + $Name)
        Write-Utf8NoBom -Path (Join-Path $lineRoot 'line.json') -Content (([ordered]@{ schema = 'ai-sessions.line.v1'; 'line-slug' = 'a' } | ConvertTo-Json -Depth 10) + "`n")
        Write-Utf8NoBom -Path $artifactSourcePath -Content ('S finding artifact: ' + $Name)
        Write-Utf8NoBom -Path (Join-Path $codexHome 'default.config.toml') -Content ('model = "fixture-model"' + "`r`n" + 'model_reasoning_effort = "high"' + "`r`n")

        $quotaTimestamp = [DateTimeOffset]::UtcNow.AddMinutes(-1)
        $quotaReset = $quotaTimestamp.AddHours(1).ToUnixTimeSeconds()
        $quotaRollout = [ordered]@{
            timestamp = $quotaTimestamp.ToString('o')
            payload = [ordered]@{
                rate_limits = [ordered]@{
                    primary = [ordered]@{ used_percent = 20; window_minutes = 300; resets_at = $quotaReset }
                    secondary = [ordered]@{ used_percent = 10; window_minutes = 10080; resets_at = $quotaReset }
                }
            }
        }
        $quotaSessionsPath = Join-Path $codexHome 'sessions'
        New-Item -ItemType Directory -Path $quotaSessionsPath -Force | Out-Null
        Write-Utf8NoBom -Path (Join-Path $quotaSessionsPath 'rollout-s-finding.jsonl') -Content (($quotaRollout | ConvertTo-Json -Compress -Depth 20) + "`n")

        $gitHostPath = (Get-Command git.exe -ErrorAction Stop).Source
        $gitInit = Invoke-Phase9Process -HostPath $gitHostPath -Arguments @('init') -WorkingDirectory $sourceRoot -EnvironmentVariables @{}
        Assert-True ([int]$gitInit.exit_code -eq 0) ('S finding fixture git init 失敗：' + [string]$gitInit.stdout + [string]$gitInit.stderr)
        $gitAdd = Invoke-Phase9Process -HostPath $gitHostPath -Arguments @('add', '--', 'target.txt', 'dispatch-prompt.md') -WorkingDirectory $sourceRoot -EnvironmentVariables @{}
        Assert-True ([int]$gitAdd.exit_code -eq 0) ('S finding fixture git add 失敗：' + [string]$gitAdd.stdout + [string]$gitAdd.stderr)
        $gitCommit = Invoke-Phase9Process -HostPath $gitHostPath -Arguments @('-c', 'user.name=phase9-s-finding', '-c', 'user.email=phase9-s-finding@example.invalid', 'commit', '--no-verify', '-m', 'phase9 S finding fixture') -WorkingDirectory $sourceRoot -EnvironmentVariables @{}
        Assert-True ([int]$gitCommit.exit_code -eq 0) ('S finding fixture git commit 失敗：' + [string]$gitCommit.stdout + [string]$gitCommit.stderr)

        if ($CreateQuotaBeforePath) {
            $null = New-Phase8QuotaSnapshot -Path $quotaBeforePath -PrimaryRemainingPercent 80
        }

        $fakeCodexLines = @(
            '@echo off'
            ('>"' + $counterPath + '" echo started')
            ('echo {"type":"thread.started","thread_id":"' + $threadId + '"}')
            ('echo {"type":"item.completed","item":{"type":"agent_message","text":"design.md ' + $Name + ' ' + $caseSlug + ' a"}}')
            'echo {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
            'powershell.exe -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 1"'
            'exit /b 0'
        )
        Write-Utf8NoBom -Path $fakeCodexPath -Content (($fakeCodexLines -join "`r`n") + "`r`n")

        $artifactDocument = [ordered]@{
            source = if ($PrepareFailure) { Join-Path $lineRoot 'missing-artifact.txt' } else { $artifactSourcePath }
            destination = $artifactDestinationPath
            sha256 = if ($PrepareFailure) { '0' * 64 } else { Get-FileSha256 -Path $artifactSourcePath }
            purpose = 'S finding Prepare fixture'
        }
        $request = [ordered]@{
            schema = 'ai-sessions.dispatch-request.v1'
            operation = 'Dispatch'
            source_root = $sourceRoot
            dispatch_root = $dispatchRoot
            line_slug = 'a'
            dispatch_slug = $caseSlug
            profile = 'default'
            write_mode = 'write'
            dispatch_kind = 'workflow'
            target_path = @('target.txt')
            prepare_artifacts = @($artifactDocument)
            prompt_path = $promptSourcePath
            task_type = 'script-change'
            session_mode = 'cold-start'
            unit_kind = 'workflow-phase'
            requested_unit = @('Phase 1')
            failure_receipt_path = $failureReceiptPath
            result_path = $resultPath
            preflight_result_path = $preflightResultPath
            prepare_result_path = $prepareResultPath
        }
        if (-not $OmitQuotaBeforePath) {
            $request.quota_before_path = $quotaBeforePath
        }
        Write-Utf8NoBom -Path $requestPath -Content (($request | ConvertTo-Json -Depth 20) + "`n")

        $hostPath = (Get-Command powershell.exe -ErrorAction Stop).Source
        $run = Invoke-Phase9Process -HostPath $hostPath -Arguments @(
            '-NoProfile'
            '-File'
            $ScriptPath
            '-CodexPath'
            $fakeCodexPath
            '-CodexHome'
            $codexHome
            '-Operation'
            'Dispatch'
            '-RequestPath'
            $requestPath
        ) -WorkingDirectory $root -EnvironmentVariables @{}
        $outputDocument = $null
        try {
            $outputDocument = ConvertFrom-Json -InputObject ([string]$run.stdout)
        }
        catch {
            $outputDocument = $null
        }
        $resultDocument = $null
        if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
            try {
                $resultDocument = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            }
            catch {
                $resultDocument = $null
            }
        }
        $receiptDocument = $null
        if (Test-Path -LiteralPath $failureReceiptPath -PathType Leaf) {
            try {
                $receiptDocument = Get-Content -LiteralPath $failureReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
            }
            catch {
                $receiptDocument = $null
            }
        }
        $sidecarPath = $null
        if ($null -ne $outputDocument -and $null -ne $outputDocument.inspect_binding) {
            $sidecarPath = [string]$outputDocument.inspect_binding.process_exit_code_sidecar_path
        }
        if (-not [string]::IsNullOrWhiteSpace($sidecarPath)) {
            for ($attempt = 1; $attempt -le 50; $attempt++) {
                if (Test-Path -LiteralPath $sidecarPath -PathType Leaf) {
                    break
                }
                Start-Sleep -Milliseconds 100
            }
        }
        $startResultPath = if ($null -eq $outputDocument -or $null -eq $outputDocument.stage_results -or $null -eq $outputDocument.stage_results.start) { $null } else { [string]$outputDocument.stage_results.start.path }
        $startResultDocument = $null
        if (-not [string]::IsNullOrWhiteSpace($startResultPath) -and (Test-Path -LiteralPath $startResultPath -PathType Leaf)) {
            try {
                $startResultDocument = Get-Content -LiteralPath $startResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            }
            catch {
                $startResultDocument = $null
            }
        }
        $inspectResultPath = if ($null -eq $startResultDocument) { $null } else { [string]$startResultDocument.inspectResultPath }
        $inspectResultDocument = $null
        if (-not [string]::IsNullOrWhiteSpace($inspectResultPath) -and [IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $inspectResultPath))) {
            try {
                $inspectResultDocument = ConvertFrom-Json -InputObject (Read-DispatchUtf8Text -Path $inspectResultPath)
            }
            catch {
                $inspectResultDocument = $null
            }
        }
        $runRecordPath = if ($null -eq $startResultDocument) { $null } else { [string]$startResultDocument.runRecordPath }
        $runRecordDocument = $null
        if (-not [string]::IsNullOrWhiteSpace($runRecordPath) -and (Test-Path -LiteralPath $runRecordPath -PathType Leaf)) {
            try {
                $runRecordDocument = Get-Content -LiteralPath $runRecordPath -Raw -Encoding UTF8 | ConvertFrom-Json
            }
            catch {
                $runRecordDocument = $null
            }
        }
        $eventStreamPath = if ($null -eq $startResultDocument) { $null } else { [string]$startResultDocument.eventStreamPath }
        $turnCompleted = $false
        if (-not [string]::IsNullOrWhiteSpace($eventStreamPath) -and (Test-Path -LiteralPath $eventStreamPath -PathType Leaf)) {
            $turnCompleted = (Get-Content -LiteralPath $eventStreamPath -Raw -Encoding UTF8).Contains('turn.completed')
        }
        return [pscustomobject]@{
            name = $Name
            dispatch_slug = $caseSlug
            case_root = $caseRoot
            request_path = $requestPath
            request = $request
            run = $run
            output_text = ([string]$run.stdout + [string]$run.stderr)
            output_document = $outputDocument
            result_path = $resultPath
            result_document = $resultDocument
            receipt_path = $failureReceiptPath
            receipt_document = $receiptDocument
            preflight_result_path = $preflightResultPath
            prepare_result_path = $prepareResultPath
            quota_before_path = $quotaBeforePath
            bound_quota_before_path = if ($null -eq $outputDocument) { $null } else { [string]$outputDocument.quota_before_path }
            sidecar_path = $sidecarPath
            sidecar_exists = -not [string]::IsNullOrWhiteSpace($sidecarPath) -and (Test-Path -LiteralPath $sidecarPath -PathType Leaf)
            external_start_exists = Test-Path -LiteralPath $counterPath -PathType Leaf
            quota_before_exists = Test-Path -LiteralPath $quotaBeforePath -PathType Leaf
            preflight_exists = Test-Path -LiteralPath $preflightResultPath -PathType Leaf
            prepare_exists = Test-Path -LiteralPath $prepareResultPath -PathType Leaf
            result_exists = Test-Path -LiteralPath $resultPath -PathType Leaf
            receipt_exists = Test-Path -LiteralPath $failureReceiptPath -PathType Leaf
            source_root = $sourceRoot
            dispatch_root = $dispatchRoot
            execution_root = $dispatchRoot
            prompt_source_path = $promptSourcePath
            codex_home = $codexHome
            start_result_path = $startResultPath
            start_result_document = $startResultDocument
            inspect_result_path = $inspectResultPath
            inspect_result_document = $inspectResultDocument
            run_record_path = $runRecordPath
            run_record_document = $runRecordDocument
            event_stream_path = $eventStreamPath
            turn_completed = $turnCompleted
        }
    }

    Invoke-Case 'Phase 9 S-1 real Dispatch omitted quota path reaches bound before snapshot, Prepare and Start' {
        $s1Normal = & $invokeSRealDispatchCase -Name 's1-omitted' -ScriptPath $sourcePath -OmitQuotaBeforePath
        Assert-True ([int]$s1Normal.run.exit_code -eq 0) ('S-1 omitted quota path CLI 未成功：' + [string]$s1Normal.output_text)
        Assert-True ($null -ne $s1Normal.output_document -and [string]$s1Normal.output_document.status -eq 'started') ('S-1 omitted quota path 未建立 started envelope：' + [string]$s1Normal.output_text)
        Assert-True (@($s1Normal.output_document.completed_stages) -contains 'preflight' -and @($s1Normal.output_document.completed_stages) -contains 'before-snapshot' -and @($s1Normal.output_document.completed_stages) -contains 'prepare' -and @($s1Normal.output_document.completed_stages) -contains 'start') ('S-1 omitted quota path 未完整通過 Prepare 與 Start：' + [string]$s1Normal.output_text)
        Assert-True (-not [string]::IsNullOrWhiteSpace($s1Normal.bound_quota_before_path) -and (Test-Path -LiteralPath $s1Normal.bound_quota_before_path -PathType Leaf) -and $s1Normal.result_document.quota_before_path -eq $s1Normal.bound_quota_before_path) ('S-1 未在 bound quota_before_path 建立快照：' + ($s1Normal | ConvertTo-Json -Depth 30 -Compress))

        $s1ExplicitMissing = & $invokeSRealDispatchCase -Name 's1-explicit-missing' -ScriptPath $sourcePath
        Assert-True ([int]$s1ExplicitMissing.run.exit_code -ne 0) ('S-1 explicit missing quota path 未以非零結束：' + [string]$s1ExplicitMissing.output_text)
        Assert-True ($null -ne $s1ExplicitMissing.output_document -and [string]$s1ExplicitMissing.output_document.status -eq 'failed' -and [string]$s1ExplicitMissing.output_document.failed_stage -eq 'before-snapshot') ('S-1 explicit missing quota path 未在 before-snapshot 失敗：' + [string]$s1ExplicitMissing.output_text)
        Assert-True (-not [bool]$s1ExplicitMissing.output_document.process_started -and -not $s1ExplicitMissing.external_start_exists -and -not $s1ExplicitMissing.quota_before_exists) ('S-1 explicit missing quota path 已進入 external Start 或建立不存在的快照：' + [string]$s1ExplicitMissing.output_text)

        $productionText = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
        $fixedSnapshotCall = '$quotaBeforePathValue = Set-QuotaSnapshotFromCodex -Path ([string]$stageBinding.quota_before_path) -CodexHome $CodexHome'
        $oldSnapshotCall = '$quotaBeforePathValue = Get-OrCreateQuotaSnapshot -Path ([string]$stageBinding.quota_before_path) -CodexHome $CodexHome -HistoryRoot $historyRoot -Purpose ''before'' -Required'
        Assert-True ($productionText.Contains($fixedSnapshotCall)) 'S-1 reverse 找不到省略 quota path 的 production snapshot writer。'
        $mutantText = $productionText.Replace($fixedSnapshotCall, $oldSnapshotCall)
        Assert-True ($mutantText -ne $productionText) 'S-1 reverse mutant 未恢復既有路徑驗證邏輯。'
        $mutantPath = Join-Path $phase9Root 's1-mutant-Invoke-CodexDispatch.ps1'
        $mutantQuotaScriptPath = Join-Path $phase9Root 'Get-CodexQuota.ps1'
        Copy-Item -LiteralPath (Join-Path $root 'scripts\Get-CodexQuota.ps1') -Destination $mutantQuotaScriptPath -Force
        $bomEncoding = New-Object System.Text.UTF8Encoding($true)
        [IO.File]::WriteAllText($mutantPath, $mutantText, $bomEncoding)
        $s1Reverse = & $invokeSRealDispatchCase -Name 's1-reverse' -ScriptPath $mutantPath -OmitQuotaBeforePath
        Assert-True ([int]$s1Reverse.run.exit_code -ne 0 -and $null -ne $s1Reverse.output_document -and [string]$s1Reverse.output_document.status -eq 'failed' -and [string]$s1Reverse.output_document.failed_stage -eq 'before-snapshot') ('S-1 reverse 未暴露 bound path 尚未存在的失敗：' + [string]$s1Reverse.output_text)
        Assert-True (-not [bool]$s1Reverse.output_document.process_started -and -not $s1Reverse.external_start_exists) ('S-1 reverse 意外進入 external Start：' + [string]$s1Reverse.output_text)
        $s1Restored = & $invokeSRealDispatchCase -Name 's1-restored' -ScriptPath $sourcePath -OmitQuotaBeforePath
        Assert-True ([int]$s1Restored.run.exit_code -eq 0 -and $null -ne $s1Restored.output_document -and [string]$s1Restored.output_document.status -eq 'started' -and (Test-Path -LiteralPath $s1Restored.bound_quota_before_path -PathType Leaf)) ('S-1 reverse 後還原 production 未重新通過：' + [string]$s1Restored.output_text)
        $script:phase9S1Evidence = [ordered]@{
            normal = $s1Normal
            explicit_missing = $s1ExplicitMissing
            reverse_failure = $s1Reverse
            restored = $s1Restored
            mutation = '將省略 quota_before_path 的 Set-QuotaSnapshotFromCodex 改回要求 bound path 已存在的 Get-OrCreateQuotaSnapshot。'
        }
        Write-Phase9Evidence -Label 'S001_PRE_FIX_FAILURE' -Value $s1Reverse
        Write-Phase9Evidence -Label 'S001_NORMAL_PASS' -Value ([ordered]@{ omitted = $s1Normal; explicit_missing = $s1ExplicitMissing })
        Write-Phase9Evidence -Label 'S001_REVERSE_FAILURE' -Value $s1Reverse
        Write-Phase9Evidence -Label 'S001_RESTORED_PASS' -Value $s1Restored
    }

    Invoke-Case 'Phase 9 S-2 real Dispatch exit code follows failed or started status' {
        $s2Preflight = & $invokeF009Case -Name 's2-preflight' -Scenario 'existing' -ScriptPath $sourcePath
        & $assertF009Receipt $s2Preflight 's2-preflight'
        $s2Before = & $invokeSRealDispatchCase -Name 's2-before' -ScriptPath $sourcePath
        Assert-True ([int]$s2Before.run.exit_code -ne 0 -and $null -ne $s2Before.output_document -and [string]$s2Before.output_document.status -eq 'failed' -and [string]$s2Before.output_document.failed_stage -eq 'before-snapshot') ('S-2 before-snapshot 失敗未以非零結束：' + [string]$s2Before.output_text)
        $s2Prepare = & $invokeSRealDispatchCase -Name 's2-prepare' -ScriptPath $sourcePath -CreateQuotaBeforePath -PrepareFailure
        Assert-True ([int]$s2Prepare.run.exit_code -ne 0 -and $null -ne $s2Prepare.output_document -and [string]$s2Prepare.output_document.status -eq 'failed' -and [string]$s2Prepare.output_document.failed_stage -eq 'prepare') ('S-2 Prepare 失敗未以非零結束：' + [string]$s2Prepare.output_text)
        $s2Success = & $invokeSRealDispatchCase -Name 's2-success' -ScriptPath $sourcePath -CreateQuotaBeforePath
        Assert-True ([int]$s2Success.run.exit_code -eq 0 -and $null -ne $s2Success.output_document -and [string]$s2Success.output_document.status -eq 'started') ('S-2 started 成功未以 0 結束：' + [string]$s2Success.output_text)

        $productionText = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
        $fixedExitBlock = "if (`$Operation -eq 'Dispatch' -and `$null -ne `$result -and [string]`$result.status -ceq 'failed') {`r`n        `$dispatchExitCode = 1`r`n    }"
        Assert-True ($productionText.Contains($fixedExitBlock)) 'S-2 reverse 找不到 Dispatch failed exit code production block。'
        $mutantExitBlock = $fixedExitBlock.Replace('$dispatchExitCode = 1', '$dispatchExitCode = 0')
        $mutantText = $productionText.Replace($fixedExitBlock, $mutantExitBlock)
        Assert-True ($mutantText -ne $productionText) 'S-2 reverse mutant 未改變 failed exit code。'
        $mutantPath = Join-Path $phase9Root 's2-mutant-Invoke-CodexDispatch.ps1'
        $bomEncoding = New-Object System.Text.UTF8Encoding($true)
        [IO.File]::WriteAllText($mutantPath, $mutantText, $bomEncoding)
        $s2Reverse = & $invokeSRealDispatchCase -Name 's2-reverse' -ScriptPath $mutantPath -CreateQuotaBeforePath -PrepareFailure
        Assert-True ([int]$s2Reverse.run.exit_code -eq 0 -and $null -ne $s2Reverse.output_document -and [string]$s2Reverse.output_document.status -eq 'failed' -and [string]$s2Reverse.output_document.failed_stage -eq 'prepare') ('S-2 reverse 未暴露 status=failed 與 exit 0 的回歸：' + [string]$s2Reverse.output_text)
        $s2Restored = & $invokeSRealDispatchCase -Name 's2-restored' -ScriptPath $sourcePath -CreateQuotaBeforePath -PrepareFailure
        Assert-True ([int]$s2Restored.run.exit_code -ne 0 -and $null -ne $s2Restored.output_document -and [string]$s2Restored.output_document.status -eq 'failed' -and [string]$s2Restored.output_document.failed_stage -eq 'prepare') ('S-2 reverse 後還原 production 未回到非零：' + [string]$s2Restored.output_text)
        $script:phase9S2Evidence = [ordered]@{
            preflight = $s2Preflight
            before_snapshot = $s2Before
            prepare = $s2Prepare
            success = $s2Success
            reverse_failure = $s2Reverse
            restored = $s2Restored
            mutation = '將 Dispatch status=failed 的 main switch 結束碼由 1 改為 0。'
        }
        Write-Phase9Evidence -Label 'S002_PRE_FIX_FAILURE' -Value ([ordered]@{ preflight = $s2Preflight; before_snapshot = $s2Before; prepare = $s2Prepare })
        Write-Phase9Evidence -Label 'S002_NORMAL_PASS' -Value ([ordered]@{ preflight = $s2Preflight; before_snapshot = $s2Before; prepare = $s2Prepare; success = $s2Success })
        Write-Phase9Evidence -Label 'S002_REVERSE_FAILURE' -Value $s2Reverse
        Write-Phase9Evidence -Label 'S002_RESTORED_PASS' -Value $s2Restored
    }

    Invoke-Case 'Phase 9 T010/T011 real Dispatch prompt transfer and direct Inspect binding' {
        $real = & $invokeSRealDispatchCase -Name 't010-t011' -ScriptPath $sourcePath -CreateQuotaBeforePath
        Assert-True ([int]$real.run.exit_code -eq 0 -and $null -ne $real.output_document -and [string]$real.output_document.status -eq 'started') ('T010 real Dispatch 未完成：' + [string]$real.output_text)
        Assert-True ($real.turn_completed) ('T010 real Dispatch 尚未取得 turn.completed：' + [string]$real.output_text)
        Assert-True ($null -ne $real.run_record_document) 'T010 real Dispatch 未讀取 RunRecord。'
        Assert-True (Test-PathWithinRoot -Path $real.run_record_document.prompt_path -Root $real.execution_root) ('T010 RunRecord prompt_path 未位於 executionRoot：' + ($real.run_record_document | ConvertTo-Json -Depth 20 -Compress))
        Assert-True (Test-Path -LiteralPath $real.run_record_document.prompt_path -PathType Leaf) 'T010 RunRecord prompt_path 不存在。'
        Assert-True (Test-PathWithinRoot -Path $real.run_record_document.prompt_source_path -Root $real.source_root) 'T010 prompt_source_path 未位於 sourceRoot。'
        Assert-True (Test-PathWithinRoot -Path $real.run_record_document.prompt_transfer_path -Root (Join-Path $real.execution_root '.local\ai-sessions\history')) 'T010 prompt_transfer_path 未位於 execution history。'
        Assert-True ($null -ne $real.inspect_result_path -and [IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $real.inspect_result_path))) 'T011 Start 未輸出可直接使用的 inspectResultPath。'
        Assert-True (Test-PathWithinRoot -Path $real.inspect_result_path -Root (Join-Path $real.execution_root '.local\ai-sessions\history')) 'T011 inspectResultPath 未位於 execution history。'

        $inspectHost = (Get-Command powershell.exe -ErrorAction Stop).Source
        $inspectRun = Invoke-Phase9Process -HostPath $inspectHost -Arguments @(
            '-NoProfile'
            '-File'
            $sourcePath
            '-CodexHome'
            $real.codex_home
            '-Operation'
            'Inspect'
            '-DispatchResultPath'
            $real.inspect_result_path
            '-SourceRoot'
            $real.source_root
            '-ExecutionRoot'
            $real.execution_root
            '-LineSlug'
            'a'
            '-DispatchSlug'
            $real.dispatch_slug
            '-RequiredIdentifier'
            'design.md'
        ) -WorkingDirectory $root -EnvironmentVariables @{}
        $inspectDocument = $null
        try {
            $inspectDocument = ConvertFrom-Json -InputObject ([string]$inspectRun.stdout)
        }
        catch {
            $inspectDocument = $null
        }
        Assert-True ([int]$inspectRun.exit_code -eq 0 -and $null -ne $inspectDocument -and [bool]$inspectDocument.success) ('T011 Start inspectResultPath 無法直接作為 Inspect 輸入：' + [string]$inspectRun.stdout + [string]$inspectRun.stderr)

        $inspectApiPath = ConvertTo-FileSystemApiPath -Path $real.inspect_result_path
        $originalInspectBytes = [IO.File]::ReadAllBytes($inspectApiPath)
        $inspectText = [Text.Encoding]::UTF8.GetString($originalInspectBytes)
        $tamperedInspectDocument = ConvertFrom-Json -InputObject $inspectText
        $tamperedInspectDocument.status = 'tampered'
        $tamperedInspectText = ($tamperedInspectDocument | ConvertTo-Json -Depth 40) + "`n"
        Assert-True ($tamperedInspectText -ne $inspectText) 'T011 stale binding mutant 未改變 Inspect result。'
        [IO.File]::WriteAllText($inspectApiPath, $tamperedInspectText, (New-Object Text.UTF8Encoding($false)))
        $staleInspectRun = Invoke-Phase9Process -HostPath $inspectHost -Arguments @(
            '-NoProfile'
            '-File'
            $sourcePath
            '-Operation'
            'Inspect'
            '-DispatchResultPath'
            $real.inspect_result_path
            '-SourceRoot'
            $real.source_root
            '-ExecutionRoot'
            $real.execution_root
            '-LineSlug'
            'a'
            '-DispatchSlug'
            $real.dispatch_slug
            '-RequiredIdentifier'
            'design.md'
        ) -WorkingDirectory $root -EnvironmentVariables @{}
        [IO.File]::WriteAllBytes($inspectApiPath, $originalInspectBytes)
        Assert-True ([int]$staleInspectRun.exit_code -ne 0 -and ([string]$staleInspectRun.stdout + [string]$staleInspectRun.stderr) -match 'DispatchResultBindingInvalid|result_sha256') ('T011 stale Inspect binding 未拒絕：' + [string]$staleInspectRun.stdout + [string]$staleInspectRun.stderr)

        $outsidePromptPath = Join-Path (Split-Path -Parent $real.source_root) ('outside-prompt-' + [guid]::NewGuid().ToString('N') + '.md')
        Write-Utf8NoBom -Path $outsidePromptPath -Content 'outside prompt'
        $outsideRejected = $false
        try {
            $null = Copy-DispatchPromptToExecutionHistory -PromptPath $outsidePromptPath -SourceRoot $real.source_root -ExecutionRoot $real.execution_root -HistoryRoot (Join-Path $real.execution_root '.local\ai-sessions\history') -Timestamp ('outside-' + [guid]::NewGuid().ToString('N'))
        }
        catch {
            $outsideRejected = $_.Exception.Message -match 'PromptSourceBoundary'
        }
        Assert-True $outsideRejected 'T010 sourceRoot 外 Prompt 未拒絕。'

        $collisionTimestamp = 'collision-' + [guid]::NewGuid().ToString('N')
        $collisionPath = Join-Path (Join-Path $real.execution_root '.local\ai-sessions\history') ('codex-prompt-source-' + $collisionTimestamp + '.md')
        Write-Utf8NoBom -Path $collisionPath -Content 'collision sentinel'
        $collisionRejected = $false
        try {
            $null = Copy-DispatchPromptToExecutionHistory -PromptPath $real.prompt_source_path -SourceRoot $real.source_root -ExecutionRoot $real.execution_root -HistoryRoot (Join-Path $real.execution_root '.local\ai-sessions\history') -Timestamp $collisionTimestamp
        }
        catch {
            $collisionRejected = $_.Exception.Message -match 'PromptTransferCollision'
        }
        Assert-True $collisionRejected 'T010 prompt transfer collision 未拒絕。'

        $hashTimestamp = 'hash-' + [guid]::NewGuid().ToString('N')
        $originalHashFunction = (Get-Command Get-FileSha256 -CommandType Function -ErrorAction Stop).ScriptBlock
        try {
            Set-Item -Path Function:\Get-FileSha256 -Value ([scriptblock]::Create(@'
param([Parameter(Mandatory)][string]$Path)
if ([IO.Path]::GetFileName($Path) -like 'codex-prompt-source-*') { return ('0' * 64) }
return & $script:phase9OriginalGetFileSha256 -Path $Path
'@))
            $script:phase9OriginalGetFileSha256 = $originalHashFunction
            $hashRejected = $false
            try {
                $null = Copy-DispatchPromptToExecutionHistory -PromptPath $real.prompt_source_path -SourceRoot $real.source_root -ExecutionRoot $real.execution_root -HistoryRoot (Join-Path $real.execution_root '.local\ai-sessions\history') -Timestamp $hashTimestamp
            }
            catch {
                $hashRejected = $_.Exception.Message -match 'PromptTransferHashMismatch'
            }
        }
        finally {
            Set-Item -Path Function:\Get-FileSha256 -Value $originalHashFunction
        }
        Assert-True $hashRejected 'T010 prompt transfer hash mismatch 未拒絕。'

        $productionText = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
        $inspectWriter = "return Write-DispatchAtomicJsonDocument -Path `$resolvedPath -Document `$document -SourceRoot `$SourceRoot -ExecutionRoot `$ExecutionRoot -TargetPath @() -RequireAbsent -AbsentErrorCode 'DispatchResultBindingCollision'"
        Assert-True $productionText.Contains($inspectWriter) 'T011 reverse 找不到 Inspect binding writer。'
        $inspectWriterMutant = 'return [pscustomobject]@{ Path = $resolvedPath; Sha256 = $null; Hash = $null; Document = $document }'
        $mutantText = $productionText.Replace($inspectWriter, $inspectWriterMutant)
        Assert-True ($mutantText -ne $productionText) 'T011 reverse mutant 未移除 Inspect binding writer。'
        $mutantPath = Join-Path $phase9Root 't011-mutant-Invoke-CodexDispatch.ps1'
        $bomEncoding = New-Object Text.UTF8Encoding($true)
        [IO.File]::WriteAllText($mutantPath, $mutantText, $bomEncoding)
        $mutantDispatch = & $invokeSRealDispatchCase -Name 't011-mutant' -ScriptPath $mutantPath -CreateQuotaBeforePath
        Assert-True ([int]$mutantDispatch.run.exit_code -eq 0 -and -not (Test-Path -LiteralPath $mutantDispatch.inspect_result_path -PathType Leaf)) ('T011 reverse 未暴露缺少 Inspect binding：' + [string]$mutantDispatch.output_text)

        $script:phase9T010T011Evidence = [ordered]@{
            real_dispatch = $real
            inspect = $inspectRun
            stale_binding = $staleInspectRun
            source_boundary = $outsideRejected
            collision = $collisionRejected
            hash_mismatch = $hashRejected
            mutation = '移除 Write-DispatchInspectResultBinding 的原子 writer；mutant Dispatch 未產生 inspectResultPath 指向的檔案。'
            mutant_dispatch = $mutantDispatch
        }
        Write-Phase9Evidence -Label 'T010_T011_REAL_DISPATCH_PASS' -Value ([ordered]@{ dispatch = $real; inspect = $inspectRun; run_record = $real.run_record_document })
        Write-Phase9Evidence -Label 'T010_T011_NEGATIVE_AND_MUTANT' -Value $script:phase9T010T011Evidence
        Write-Phase9Evidence -Label 'PHASE9_REAL_DISPATCH_RELAY_FIX' -Value ([ordered]@{
                production_wait_timeout_seconds = 5
                fixture_post_event_hold_seconds = 1
                production_wait_behavior_changed = $false
                fixture_real_dispatch_parent = $sRealDispatchParent
                fixture_worktree_location = 'repoRoot/p9-real/<caseSlug>/.local/ai-sessions/worktrees/<caseSlug>; new entries are removed before the final git status guard'
                affected_cases = @('S-1 omitted quota normal/restored', 'S-2 started success', 'T010/T011 real Dispatch')
                cause = 'Windows cmd.exe could not create the fixture stderr redirection path when the nested executionRoot path reached the MAX_PATH boundary, leaving the event stream empty. The fixture also held the process for five seconds, matching the production relay deadline; the hold is one second after this correction so the fixture observes a completed stream well before the deadline.'
                real_codex_impact = 'Production Wait-ForThreadRelay remains unchanged; real Codex event streaming is not altered.'
            })
    }

    Invoke-Case 'Phase 9 R-1/R-2/R-3 real source-root path shape distinguishes prompt boundary regression' {
        $invokeR123RealShapeCase = {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][string]$Name,
                [Parameter(Mandatory)][string]$ScriptPath,
                [switch]$SkipCleanup
            )

            $caseSlug = 'r13-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
            $testExecutionRoot = [IO.Path]::GetFullPath($root)
            $sourceRoot = Join-Path $sRealDispatchParent ('p-' + $caseSlug)
            $scratchRoot = Join-Path $sourceRoot ('.local\ai-sessions\scratch\' + $caseSlug)
            $dispatchRoot = Join-Path $sourceRoot ('.local\ai-sessions\worktrees\' + $caseSlug)
            $lineSlug = 'r13'
            $dispatchHistoryLineRoot = Join-Path $dispatchRoot ('.local\ai-sessions\history\' + $lineSlug)
            $promptSourcePath = Join-Path $scratchRoot 'prompt.md'
            $requestPath = Join-Path $scratchRoot 'request.json'
            $failureReceiptPath = Join-Path $scratchRoot 'failure-receipt.json'
            $resultPath = Join-Path $dispatchHistoryLineRoot 'dispatch-result.json'
            $quotaBeforePath = Join-Path (Join-Path $sourceRoot '.local\ai-sessions\history') ('quota-before-' + $caseSlug + '.json')
            $codexHome = Join-Path $scratchRoot 'codex-home'
            $rolloutRoot = Join-Path $codexHome 'sessions'
            $fakeCodexPath = Join-Path $scratchRoot 'codex.cmd'
            $externalStartedPath = Join-Path $scratchRoot 'external-started.txt'
            $threadId = [guid]::NewGuid().ToString('D')
            $targetRelativePath = 'scripts\Invoke-CodexDispatch.ps1'
            $lineManifestSourcePath = Join-Path $sourceRoot ('.local\ai-sessions\handoff\' + $lineSlug + '\line.json')
            $requirementSummarySourcePath = Join-Path $sourceRoot ('.local\ai-sessions\handoff\' + $lineSlug + '\requirement-summary.md')
            $lineManifestDestinationPath = Join-Path $dispatchRoot ('.local\ai-sessions\handoff\' + $lineSlug + '\line.json')
            $requirementSummaryDestinationPath = Join-Path $dispatchRoot ('.local\ai-sessions\handoff\' + $lineSlug + '\requirement-summary.md')
            $sourceRepoWorktreeBefore = Get-Phase9GitWorktreeList -RepositoryRoot $testExecutionRoot
            $isolatedRepoWorktreeBefore = $null
            $isolatedRepoWorktreeAfter = $null
            $worktreeCleanup = $null

            New-Item -ItemType Directory -Path $sourceRoot, $scratchRoot, $codexHome, $rolloutRoot, (Split-Path -Parent $quotaBeforePath) -Force | Out-Null
            New-Item -ItemType Directory -Path (Split-Path -Parent $lineManifestSourcePath) -Force | Out-Null
            $historyRootKeepPath = Join-Path (Split-Path -Parent $quotaBeforePath) '.phase9-history-root'
            Write-Utf8NoBom -Path $historyRootKeepPath -Content "Phase 9 isolated Git repository history root.`n"
            $historyLineRoot = Join-Path (Split-Path -Parent $quotaBeforePath) $lineSlug
            New-Item -ItemType Directory -Path $historyLineRoot -Force | Out-Null
            $historyLineKeepPath = Join-Path $historyLineRoot '.phase9-history-line'
            Write-Utf8NoBom -Path $historyLineKeepPath -Content "Phase 9 isolated Git repository history line.`n"
            Write-Utf8NoBom -Path $lineManifestSourcePath -Content (([ordered]@{
                        schema = 'ai-sessions.line.v1'
                        'line-slug' = $lineSlug
                        'semantic-label' = 'dispatch mechanism batch 2 R-1 R-2 R-3 path shape'
                        'created-at-utc' = [DateTime]::UtcNow.ToString('o')
                    } | ConvertTo-Json -Depth 10) + "`n")
            $requirementSummaryContent = @(
                '# Phase 9 R-1/R-2/R-3 requirement summary'
                ''
                '## 程式面項目'
                ''
                '| # | 項目 | 內容 |'
                '| --- | --- | --- |'
                '| 1 | Prompt 搬運 | Dispatch 啟動前搬運 prompt 至 executionRoot。 |'
                ''
                '## 功能面項目'
                ''
                '| # | 項目 | 內容 |'
                '| --- | --- | --- |'
                '| 2 | 真實 Dispatch | Start、RunRecord 與 Dispatch result 使用搬運後路徑。 |'
            ) -join "`r`n"
            Write-Utf8NoBom -Path $requirementSummarySourcePath -Content ($requirementSummaryContent + "`r`n")
            $requirementSummaryIds = @(Get-RequirementIdsFromSummary -Content $requirementSummaryContent -SummaryPath $requirementSummarySourcePath)
            Assert-True ($requirementSummaryIds.Count -eq 2 -and $requirementSummaryIds[0] -eq 1 -and $requirementSummaryIds[1] -eq 2) ('R-1/R-2/R-3 最小 requirement summary 無法由 Get-RequirementIdsFromSummary 解析：' + ($requirementSummaryIds -join ','))
            Initialize-Phase9IsolatedGitRepository -SourceRoot $sourceRoot -SourceScriptPath $sourcePath -TargetRelativePath $targetRelativePath
            $isolatedRepoWorktreeBefore = Get-Phase9GitWorktreeList -RepositoryRoot $sourceRoot
            Write-Utf8NoBom -Path $promptSourcePath -Content ('R-1/R-2/R-3 real source-root prompt: ' + $caseSlug)
            Write-Utf8NoBom -Path (Join-Path $codexHome 'default.config.toml') -Content ('model = "fixture-model"' + "`r`n" + 'model_reasoning_effort = "high"' + "`r`n")
            $null = New-Phase8QuotaSnapshot -Path $quotaBeforePath -PrimaryRemainingPercent 80
            $fakeCodexLines = @(
                '@echo off'
                ('>"' + $externalStartedPath + '" echo started')
                ('echo {"type":"thread.started","thread_id":"' + $threadId + '"}')
                ('echo {"type":"item.completed","item":{"type":"agent_message","text":"design.md ' + $caseSlug + ' dispatch-mechanism-batch2"}}')
                'echo {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
                'powershell.exe -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 5"'
                'exit /b 0'
            )
            Write-Utf8NoBom -Path $fakeCodexPath -Content (($fakeCodexLines -join "`r`n") + "`r`n")

            $request = [ordered]@{
                schema = 'ai-sessions.dispatch-request.v1'
                operation = 'Dispatch'
                source_root = $sourceRoot
                dispatch_root = $dispatchRoot
                line_slug = $lineSlug
                dispatch_slug = $caseSlug
                profile = 'default'
                write_mode = 'write'
                dispatch_kind = 'resource'
                target_path = @($targetRelativePath)
                prepare_artifacts = @(
                    [ordered]@{
                        source = $lineManifestSourcePath
                        destination = $lineManifestDestinationPath
                        sha256 = Get-FileSha256 -Path $lineManifestSourcePath
                        purpose = 'R-1/R-2/R-3 line manifest'
                    }
                    [ordered]@{
                        source = $requirementSummarySourcePath
                        destination = $requirementSummaryDestinationPath
                        sha256 = Get-FileSha256 -Path $requirementSummarySourcePath
                        purpose = 'R-1/R-2/R-3 requirement summary'
                    }
                )
                prompt_path = $promptSourcePath
                task_type = 'review'
                session_mode = 'cold-start'
                unit_kind = 'resource-target'
                requested_unit = @($targetRelativePath)
                failure_receipt_path = $failureReceiptPath
                result_path = $resultPath
                quota_before_path = $quotaBeforePath
            }
            Write-Utf8NoBom -Path $requestPath -Content (($request | ConvertTo-Json -Depth 30) + "`n")

            $caseResult = $null
            try {
                $hostPath = (Get-Command powershell.exe -ErrorAction Stop).Source
                $run = Invoke-Phase9Process -HostPath $hostPath -Arguments @(
                    '-NoProfile'
                    '-File'
                    $ScriptPath
                    '-CodexPath'
                    $fakeCodexPath
                    '-CodexHome'
                    $codexHome
                    '-Operation'
                    'Dispatch'
                    '-RequestPath'
                    $requestPath
                ) -WorkingDirectory $root -EnvironmentVariables @{}
                $outputDocument = $null
                try {
                    $outputDocument = ConvertFrom-Json -InputObject ([string]$run.stdout)
                }
                catch {
                    $outputDocument = $null
                }
                $resultDocument = $null
                if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
                    try {
                        $resultDocument = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    }
                    catch {
                        $resultDocument = $null
                    }
                }
                $receiptDocument = $null
                if (Test-Path -LiteralPath $failureReceiptPath -PathType Leaf) {
                    try {
                        $receiptDocument = Get-Content -LiteralPath $failureReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    }
                    catch {
                        $receiptDocument = $null
                    }
                }
                $startResultPath = if ($null -eq $outputDocument -or $null -eq $outputDocument.stage_results -or $null -eq $outputDocument.stage_results.start) { $null } else { [string]$outputDocument.stage_results.start.path }
                $startResultDocument = $null
                if (-not [string]::IsNullOrWhiteSpace($startResultPath) -and (Test-Path -LiteralPath $startResultPath -PathType Leaf)) {
                    try {
                        $startResultDocument = Get-Content -LiteralPath $startResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    }
                    catch {
                        $startResultDocument = $null
                    }
                }
                $runRecordPath = if ($null -eq $startResultDocument) { $null } else { [string]$startResultDocument.runRecordPath }
                $runRecordDocument = $null
                if (-not [string]::IsNullOrWhiteSpace($runRecordPath) -and (Test-Path -LiteralPath $runRecordPath -PathType Leaf)) {
                    try {
                        $runRecordDocument = Get-Content -LiteralPath $runRecordPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    }
                    catch {
                        $runRecordDocument = $null
                    }
                }
                $eventStreamPath = if ($null -eq $startResultDocument) { $null } else { [string]$startResultDocument.eventStreamPath }
                $turnCompleted = $false
                if (-not [string]::IsNullOrWhiteSpace($eventStreamPath) -and (Test-Path -LiteralPath $eventStreamPath -PathType Leaf)) {
                    $turnCompleted = (Get-Content -LiteralPath $eventStreamPath -Raw -Encoding UTF8).Contains('turn.completed')
                }
                $composedPromptPaths = @()
                $dispatchHistoryRoot = Join-Path $dispatchRoot '.local\ai-sessions\history'
                if (Test-Path -LiteralPath $dispatchHistoryRoot -PathType Container) {
                    $composedPromptPaths = @(Get-ChildItem -LiteralPath $dispatchHistoryRoot -Filter 'codex-prompt-*.md' -File -Recurse | Select-Object -ExpandProperty FullName)
                }
                $promptPathExistsBeforeCleanup = $false
                if ($null -ne $resultDocument -and -not [string]::IsNullOrWhiteSpace([string]$resultDocument.prompt_path)) {
                    $promptPathExistsBeforeCleanup = Test-Path -LiteralPath ([string]$resultDocument.prompt_path) -PathType Leaf
                }
                $caseResult = [pscustomobject]@{
                    name = $Name
                    line_slug = $lineSlug
                    dispatch_slug = $caseSlug
                    request_path = $requestPath
                    request = $request
                    test_execution_root = $testExecutionRoot
                    source_root = $sourceRoot
                    dispatch_root = $dispatchRoot
                    execution_root = $dispatchRoot
                    prompt_source_path = $promptSourcePath
                    composed_prompt_paths = $composedPromptPaths
                    prompt_path_exists_before_cleanup = $promptPathExistsBeforeCleanup
                    run = $run
                    output_text = ([string]$run.stdout + [string]$run.stderr)
                    output_document = $outputDocument
                    result_path = $resultPath
                    result_document = $resultDocument
                    receipt_path = $failureReceiptPath
                    receipt_document = $receiptDocument
                    receipt_exists = Test-Path -LiteralPath $failureReceiptPath -PathType Leaf
                    external_start_exists = Test-Path -LiteralPath $externalStartedPath -PathType Leaf
                    start_result_path = $startResultPath
                    start_result_document = $startResultDocument
                    run_record_path = $runRecordPath
                    run_record_document = $runRecordDocument
                    event_stream_path = $eventStreamPath
                    turn_completed = $turnCompleted
                }
            }
            finally {
                if ($SkipCleanup) {
                    $isolatedRepoWorktreeAfter = Get-Phase9GitWorktreeList -RepositoryRoot $sourceRoot
                    $worktreeCleanup = [ordered]@{
                        source_root = $sourceRoot
                        dispatch_root = $dispatchRoot
                        path_existed_before = $false
                        registered_before = $false
                        remove_result = $null
                        registered_after = Test-Phase9GitWorktreeListed -WorktreeList $isolatedRepoWorktreeAfter -WorktreePath $dispatchRoot
                        path_exists_after = Test-Path -LiteralPath $dispatchRoot -PathType Container
                        removed = $false
                        skipped = $true
                        worktree_list_before = $isolatedRepoWorktreeBefore
                        worktree_list_after = $isolatedRepoWorktreeAfter
                    }
                }
                else {
                    $worktreeCleanup = Remove-Phase9GitWorktree -SourceRoot $sourceRoot -DispatchRoot $dispatchRoot
                    $isolatedRepoWorktreeAfter = Get-Phase9GitWorktreeList -RepositoryRoot $sourceRoot
                }
                $sourceRepoWorktreeAfter = Get-Phase9GitWorktreeList -RepositoryRoot $testExecutionRoot
            }
            $caseResult | Add-Member -MemberType NoteProperty -Name source_repo_worktree_before -Value $sourceRepoWorktreeBefore
            $caseResult | Add-Member -MemberType NoteProperty -Name source_repo_worktree_after -Value $sourceRepoWorktreeAfter
            $caseResult | Add-Member -MemberType NoteProperty -Name isolated_repo_worktree_before -Value $isolatedRepoWorktreeBefore
            $caseResult | Add-Member -MemberType NoteProperty -Name isolated_repo_worktree_after -Value $isolatedRepoWorktreeAfter
            $caseResult | Add-Member -MemberType NoteProperty -Name worktree_cleanup -Value $worktreeCleanup
            return $caseResult
        }

        $assertR123WorktreeRegistry = {
            param([Parameter(Mandatory)][psobject]$CaseResult)
            Assert-True ([string]::Equals([string]$CaseResult.isolated_repo_worktree_before, [string]$CaseResult.isolated_repo_worktree_after, [StringComparison]::OrdinalIgnoreCase)) ('R-3 隔離 repo 的 git worktree list 前後不一致：' + ($CaseResult.worktree_cleanup | ConvertTo-Json -Depth 30 -Compress))
            Assert-True ([string]::Equals([string]$CaseResult.source_repo_worktree_before, [string]$CaseResult.source_repo_worktree_after, [StringComparison]::OrdinalIgnoreCase)) ('R-3 外層 repo 的 git worktree list 前後不一致：' + ($CaseResult.worktree_cleanup | ConvertTo-Json -Depth 30 -Compress))
        }

        $productionText = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
        $prelaunchPromptSync = '    $runRecord.prompt_path = $promptPathValue' + "`r`n" +
            '    $runRecord.prompt_source_path = $promptSourcePathValue' + "`r`n" +
            '    $runRecord.prompt_source_sha256 = $promptSourceSha256Value' + "`r`n" +
            '    $runRecord.prompt_transfer_path = $promptTransferPathValue' + "`r`n" +
            '    $runRecord.prompt_transfer_sha256 = $promptTransferSha256Value' + "`r`n" +
            '    $runRecord.inspect_result_path = $inspectResultPathValue' + "`r`n" +
            '    $null = Write-DispatchRunRecord -Record $runRecord -Update'
        $mutantPromptSync = $prelaunchPromptSync.Replace('$runRecord.prompt_path = $promptPathValue', '$runRecord.prompt_path = $promptSourcePathValue')
        Assert-True ($productionText.Contains($prelaunchPromptSync)) 'R-1/R-3 reverse 找不到 pre-launch prompt path sync。'
        Assert-True (-not $productionText.Contains($prelaunchPromptSync + "`r`n" + $prelaunchPromptSync)) 'R-1/R-3 reverse prompt path sync 區塊重複，無法安全建立 mutant。'
        $mutantText = $productionText.Replace($prelaunchPromptSync, $mutantPromptSync)
        Assert-True ($mutantText -ne $productionText) 'R-1/R-3 reverse mutant 未將 pre-launch prompt_path 改回 sourceRoot。'
        $mutantPath = Join-Path $phase9Root 'r1-r3-real-shape-mutant-Invoke-CodexDispatch.ps1'
        $bomEncoding = New-Object System.Text.UTF8Encoding($true)
        [IO.File]::WriteAllText($mutantPath, $mutantText, $bomEncoding)

        $preFix = & $invokeR123RealShapeCase -Name 'pre-fix' -ScriptPath $mutantPath
        $preFixDispatchResult = $preFix.result_document
        Assert-True ([int]$preFix.run.exit_code -ne 0 -and $null -ne $preFixDispatchResult -and [string]$preFixDispatchResult.status -eq 'failed' -and [string]$preFixDispatchResult.failed_stage -eq 'start' -and [string]$preFixDispatchResult.error -match 'RunRecord 證據超出 executionRoot：prompt_path') ('R-1/R-3 pre-fix 未重現 real path shape 邊界失敗：' + [string]$preFix.output_text)
        $sourceScratchRoot = Join-Path $preFix.source_root '.local\ai-sessions\scratch'
        Assert-True (Test-PathWithinRoot -Path $preFix.source_root -Root $preFix.test_execution_root) ('R-3 pre-fix sourceRoot 未位於測試 executionRoot 下的隔離目錄：' + ($preFix.request | ConvertTo-Json -Depth 20 -Compress))
        Assert-True (Test-PathWithinRoot -Path $preFix.dispatch_root -Root $preFix.test_execution_root) ('R-3 pre-fix dispatchRoot 未位於測試 executionRoot 下：' + ($preFix.request | ConvertTo-Json -Depth 20 -Compress))
        Assert-True (Test-PathWithinRoot -Path $preFix.request.prompt_path -Root $sourceScratchRoot) ('R-3 pre-fix prompt_path 未位於 sourceRoot scratch：' + ($preFix.request | ConvertTo-Json -Depth 20 -Compress))
        Assert-True ($preFix.request.dispatch_root -eq (Join-Path $preFix.source_root ('.local\ai-sessions\worktrees\' + $preFix.dispatch_slug))) ('R-3 pre-fix dispatch_root 未符合 sourceRoot worktrees 形態：' + ($preFix.request | ConvertTo-Json -Depth 20 -Compress))
        Assert-True ($preFix.receipt_exists -and $null -ne $preFix.receipt_document -and [bool]$preFixDispatchResult.failure_receipt_saved -and [string]$preFix.receipt_document.failed_stage -eq 'start' -and -not [bool]$preFix.receipt_document.process_started) ('R-2 pre-fix boundary failure 未保存 start failure receipt：' + [string]$preFix.output_text)
        Assert-True (@($preFix.composed_prompt_paths | Where-Object { Test-PathWithinRoot -Path $_ -Root $preFix.dispatch_root }).Count -gt 0) ('R-1/R-3 pre-fix 未留下 executionRoot 內的組合 Prompt：' + ($preFix | ConvertTo-Json -Depth 30 -Compress))
        Assert-True ([bool]$preFix.worktree_cleanup.removed -and -not [bool]$preFix.worktree_cleanup.registered_after) ('R-3 pre-fix 未清理隔離 git worktree：' + ($preFix.worktree_cleanup | ConvertTo-Json -Depth 30 -Compress))
        Assert-True ([string]::Equals([string]$preFix.source_repo_worktree_before, [string]$preFix.source_repo_worktree_after, [StringComparison]::OrdinalIgnoreCase)) ('R-3 pre-fix 改變來源 repo 的 git worktree list：' + ($preFix.worktree_cleanup | ConvertTo-Json -Depth 30 -Compress))
        Assert-True ([string]::Equals([string]$preFix.isolated_repo_worktree_before, [string]$preFix.isolated_repo_worktree_after, [StringComparison]::OrdinalIgnoreCase)) ('R-3 pre-fix 改變隔離 repo 的 git worktree list：' + ($preFix.worktree_cleanup | ConvertTo-Json -Depth 30 -Compress))

        $mutantA = $null
        $mutantAFailure = $null
        $mutantACleanup = $null
        try {
            $mutantA = & $invokeR123RealShapeCase -Name 'mutant-skip-cleanup' -ScriptPath $sourcePath -SkipCleanup
            try {
                & $assertR123WorktreeRegistry $mutantA
            }
            catch {
                $mutantAFailure = $_.Exception.Message
            }
        }
        finally {
            if ($null -ne $mutantA) {
                $mutantACleanup = Remove-Phase9GitWorktree -SourceRoot $mutantA.source_root -DispatchRoot $mutantA.dispatch_root
            }
        }
        Assert-True ($null -ne $mutantA -and [bool]$mutantA.worktree_cleanup.skipped -and [bool]$mutantA.worktree_cleanup.registered_after -and -not [string]::Equals([string]$mutantA.isolated_repo_worktree_before, [string]$mutantA.isolated_repo_worktree_after, [StringComparison]::OrdinalIgnoreCase)) ('R-3 mutant 甲 未造成隔離 repo worktree list 前後差異：' + ($mutantA | ConvertTo-Json -Depth 30 -Compress))
        Assert-True (-not [string]::IsNullOrWhiteSpace($mutantAFailure) -and $mutantAFailure -match '隔離 repo 的 git worktree list') ('R-3 mutant 甲 未被隔離 repo 清單斷言捕捉：' + ($mutantA | ConvertTo-Json -Depth 30 -Compress))
        Assert-True ($null -ne $mutantACleanup -and [bool]$mutantACleanup.removed -and -not [bool]$mutantACleanup.registered_after -and [string]::Equals([string]$mutantA.isolated_repo_worktree_before, [string]$mutantACleanup.worktree_list_after, [StringComparison]::OrdinalIgnoreCase)) ('R-3 mutant 甲 清理後仍有隔離 worktree 殘留：' + ($mutantACleanup | ConvertTo-Json -Depth 30 -Compress))
        $mutantAEvidence = [ordered]@{
            name = 'mutant-skip-cleanup'
            mutation = '跳過隔離 repo worktree 清理步驟。'
            result = 'FAIL'
            output = $mutantA.output_text
            assertion_failure = $mutantAFailure
            isolated_repo_worktree_list_before = $mutantA.isolated_repo_worktree_before
            isolated_repo_worktree_list_after_without_cleanup = $mutantA.isolated_repo_worktree_after
            outer_repo_worktree_list_before = $mutantA.source_repo_worktree_before
            outer_repo_worktree_list_after = $mutantA.source_repo_worktree_after
            cleanup = $mutantACleanup
        }

        $mutantB = $null
        $mutantBFailure = $null
        $mutantBCleanup = $null
        $mutantBCommonGitDirectoryResult = Invoke-Phase9GitCommand -RepositoryRoot $root -Arguments @('rev-parse', '--git-common-dir')
        Assert-Phase9GitCommandSucceeded -Result $mutantBCommonGitDirectoryResult
        $mutantBCommonGitDirectory = $mutantBCommonGitDirectoryResult.output.Trim()
        $mutantBCommonGitDirectoryPath = if ([IO.Path]::IsPathRooted($mutantBCommonGitDirectory)) {
            $mutantBCommonGitDirectory
        }
        else {
            Join-Path $root $mutantBCommonGitDirectory
        }
        $mutantBOuterRepoRoot = [IO.Directory]::GetParent([IO.Path]::GetFullPath($mutantBCommonGitDirectoryPath)).FullName
        $mutantBDispatchRoot = Join-Path $mutantBOuterRepoRoot ('.local\ai-sessions\worktrees\r13-mutant-outer-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $mutantBOuterWorktreeBefore = Get-Phase9GitWorktreeList -RepositoryRoot $mutantBOuterRepoRoot
        $mutantBOuterWorktreeAfter = $null
        $mutantBOuterWorktreeAfterCleanup = $null
        try {
            New-Item -ItemType Directory -Path (Split-Path -Parent $mutantBDispatchRoot) -Force | Out-Null
            $mutantBBaseShaResult = Invoke-Phase9GitCommand -RepositoryRoot $mutantBOuterRepoRoot -Arguments @('rev-parse', 'HEAD')
            Assert-Phase9GitCommandSucceeded -Result $mutantBBaseShaResult
            $mutantBBaseSha = $mutantBBaseShaResult.output.Trim()
            $mutantBPreviousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $mutantBAddResult = Invoke-Phase9GitCommand -RepositoryRoot $mutantBOuterRepoRoot -Arguments @('worktree', 'add', '--detach', $mutantBDispatchRoot, $mutantBBaseSha)
            }
            finally {
                $ErrorActionPreference = $mutantBPreviousErrorActionPreference
            }
            Assert-Phase9GitCommandSucceeded -Result $mutantBAddResult
            $mutantBOuterWorktreeAfter = Get-Phase9GitWorktreeList -RepositoryRoot $mutantBOuterRepoRoot
            $mutantBRequest = $preFix.request | ConvertTo-Json -Depth 30 | ConvertFrom-Json
            $mutantBRequest.source_root = $mutantBOuterRepoRoot
            $mutantBRequest.dispatch_root = $mutantBDispatchRoot
            $mutantB = [pscustomobject]@{
                name = 'mutant-dispatch-root-in-outer-repo'
                request = $mutantBRequest
                test_execution_root = $mutantBOuterRepoRoot
                source_root = $mutantBOuterRepoRoot
                dispatch_root = $mutantBDispatchRoot
                isolated_repo_worktree_before = $preFix.isolated_repo_worktree_before
                isolated_repo_worktree_after = $preFix.isolated_repo_worktree_after
                source_repo_worktree_before = $mutantBOuterWorktreeBefore
                source_repo_worktree_after = $mutantBOuterWorktreeAfter
                worktree_cleanup = $null
            }
            try {
                & $assertR123WorktreeRegistry $mutantB
            }
            catch {
                $mutantBFailure = $_.Exception.Message
            }
        }
        finally {
            $mutantBCleanup = Remove-Phase9GitWorktree -SourceRoot $mutantBOuterRepoRoot -DispatchRoot $mutantBDispatchRoot
            if (Test-Path -LiteralPath $mutantBDispatchRoot -PathType Container) {
                $mutantBOuterWorktreeRoot = Join-Path $mutantBOuterRepoRoot '.local\ai-sessions\worktrees'
                Assert-True (Test-PathWithinRoot -Path $mutantBDispatchRoot -Root $mutantBOuterWorktreeRoot) ('R-3 mutant 乙 清理目標超出外層 worktree root：' + $mutantBDispatchRoot)
                Remove-Item -LiteralPath $mutantBDispatchRoot -Recurse -Force
            }
            $mutantBOuterWorktreeAfterCleanup = Get-Phase9GitWorktreeList -RepositoryRoot $mutantBOuterRepoRoot
        }
        Assert-True ($null -ne $mutantB -and [string]$mutantB.request.dispatch_root -eq $mutantBDispatchRoot -and -not [string]::Equals([string]$mutantB.source_repo_worktree_before, [string]$mutantB.source_repo_worktree_after, [StringComparison]::OrdinalIgnoreCase)) ('R-3 mutant 乙 未造成外層 repo worktree list 前後差異：' + ($mutantB | ConvertTo-Json -Depth 30 -Compress))
        Assert-True (-not [string]::IsNullOrWhiteSpace($mutantBFailure) -and $mutantBFailure -match '外層 repo 的 git worktree list') ('R-3 mutant 乙 未被外層 repo 清單斷言捕捉：' + ($mutantB | ConvertTo-Json -Depth 30 -Compress))
        Assert-True ($null -ne $mutantBCleanup -and [bool]$mutantBCleanup.removed -and -not [bool]$mutantBCleanup.registered_after -and -not (Test-Path -LiteralPath $mutantBDispatchRoot -PathType Container) -and [string]::Equals([string]$mutantBOuterWorktreeBefore, [string]$mutantBOuterWorktreeAfterCleanup, [StringComparison]::OrdinalIgnoreCase)) ('R-3 mutant 乙 清理後仍有外層 worktree 或 registry 殘留：' + ($mutantBCleanup | ConvertTo-Json -Depth 30 -Compress))
        $mutantBEvidence = [ordered]@{
            name = 'mutant-dispatch-root-in-outer-repo'
            mutation = '將 dispatch_root 改到外層 repo 的 .local\\ai-sessions\\worktrees\\ 下，並在該外層 repo 註冊 worktree。'
            result = 'FAIL'
            output = $mutantBAddResult.output
            assertion_failure = $mutantBFailure
            request = $mutantB.request
            outer_repo_worktree_list_before = $mutantBOuterWorktreeBefore
            outer_repo_worktree_list_after_before_cleanup = $mutantBOuterWorktreeAfter
            outer_repo_worktree_list_after_cleanup = $mutantBOuterWorktreeAfterCleanup
            cleanup = $mutantBCleanup
        }

        $postFix = & $invokeR123RealShapeCase -Name 'post-fix' -ScriptPath $sourcePath
        $postFixDispatchResult = $postFix.result_document
        Assert-True ([int]$postFix.run.exit_code -eq 0 -and $null -ne $postFixDispatchResult -and [string]$postFixDispatchResult.status -eq 'started' -and $postFix.turn_completed) ('R-1/R-3 post-fix real path shape 未完成 turn.completed：' + [string]$postFix.output_text)
        Assert-True ($null -ne $postFix.start_result_document -and $null -ne $postFix.run_record_document) 'R-1 post-fix 缺少 Start result 或 RunRecord。'
        Assert-True (Test-PathWithinRoot -Path $postFix.source_root -Root $postFix.test_execution_root) ('R-3 post-fix sourceRoot 未位於測試 executionRoot 下的隔離目錄：' + ($postFix.request | ConvertTo-Json -Depth 20 -Compress))
        Assert-True (Test-PathWithinRoot -Path $postFix.dispatch_root -Root $postFix.test_execution_root) ('R-3 post-fix dispatchRoot 未位於測試 executionRoot 下：' + ($postFix.request | ConvertTo-Json -Depth 20 -Compress))
        Assert-True ([string]::Equals([string]$postFixDispatchResult.prompt_path, [string]$postFix.start_result_document.promptPath, [StringComparison]::OrdinalIgnoreCase) -and [string]::Equals([string]$postFix.start_result_document.promptPath, [string]$postFix.run_record_document.prompt_path, [StringComparison]::OrdinalIgnoreCase)) ('R-1 三層 prompt_path 未一致：' + ($postFix | ConvertTo-Json -Depth 30 -Compress))
        Assert-True (((Test-PathWithinRoot -Path $postFixDispatchResult.prompt_path -Root $postFix.execution_root) -and [bool]$postFix.prompt_path_exists_before_cleanup)) ('R-1 post-fix Dispatch prompt_path 不在 executionRoot：' + ($postFixDispatchResult | ConvertTo-Json -Depth 30 -Compress))
        Assert-True (((Test-PathWithinRoot -Path $postFix.start_result_document.promptSourcePath -Root $postFix.source_root) -and [string]::Equals([string]$postFix.start_result_document.promptSourcePath, [string]$postFix.prompt_source_path, [StringComparison]::OrdinalIgnoreCase))) 'R-1 post-fix promptSourcePath 未保留 sourceRoot scratch prompt。'
        Assert-True (Test-PathWithinRoot -Path $postFix.start_result_document.promptTransferPath -Root (Join-Path $postFix.execution_root '.local\ai-sessions\history')) 'R-1 post-fix promptTransferPath 未位於 execution history。'
        Assert-True ([string]::Equals([string]$postFixDispatchResult.prompt_transfer_path, [string]$postFix.start_result_document.promptTransferPath, [StringComparison]::OrdinalIgnoreCase)) 'R-1 Dispatch result 未保存搬運後 prompt transfer path。'
        Assert-True (-not $postFix.receipt_exists) ('R-2 post-fix success 不應產生 failure receipt：' + ($postFix | ConvertTo-Json -Depth 30 -Compress))
        Assert-True ([bool]$postFix.worktree_cleanup.removed -and -not [bool]$postFix.worktree_cleanup.registered_after) ('R-3 post-fix 未清理隔離 git worktree：' + ($postFix.worktree_cleanup | ConvertTo-Json -Depth 30 -Compress))
        Assert-True ([string]::Equals([string]$postFix.source_repo_worktree_before, [string]$postFix.source_repo_worktree_after, [StringComparison]::OrdinalIgnoreCase)) ('R-3 post-fix 改變來源 repo 的 git worktree list：' + ($postFix.worktree_cleanup | ConvertTo-Json -Depth 30 -Compress))
        Assert-True ([string]::Equals([string]$postFix.isolated_repo_worktree_before, [string]$postFix.isolated_repo_worktree_after, [StringComparison]::OrdinalIgnoreCase)) ('R-3 post-fix 改變隔離 repo 的 git worktree list：' + ($postFix.worktree_cleanup | ConvertTo-Json -Depth 30 -Compress))

        $script:phase9R123Evidence = [ordered]@{
            pre_fix = $preFix
            post_fix = $postFix
            mutation = '將 pre-launch RunRecord 的 prompt_path 從搬運後 executionRoot 路徑改回 sourceRoot scratch prompt_path。'
            path_shape = [ordered]@{
                test_execution_root = $postFix.test_execution_root
                source_root = $postFix.source_root
                dispatch_root_pattern = (Join-Path $postFix.source_root '.local\ai-sessions\worktrees\<dispatch-slug>')
                prompt_path_pattern = (Join-Path $postFix.source_root '.local\ai-sessions\scratch\<dispatch-slug>\prompt.md')
            }
            worktree_cleanup = [ordered]@{
                pre_fix = $preFix.worktree_cleanup
                post_fix = $postFix.worktree_cleanup
                source_repo_worktree_list_unchanged = [string]::Equals([string]$postFix.source_repo_worktree_before, [string]$postFix.source_repo_worktree_after, [StringComparison]::OrdinalIgnoreCase)
                source_repo_worktree_list_before = $postFix.source_repo_worktree_before
                source_repo_worktree_list_after = $postFix.source_repo_worktree_after
                isolated_repo_worktree_list_unchanged = [string]::Equals([string]$postFix.isolated_repo_worktree_before, [string]$postFix.isolated_repo_worktree_after, [StringComparison]::OrdinalIgnoreCase)
                isolated_repo_worktree_list_before = $postFix.isolated_repo_worktree_before
                isolated_repo_worktree_list_after = $postFix.isolated_repo_worktree_after
            }
            mutant_a = $mutantAEvidence
            mutant_b = $mutantBEvidence
            restored_pass = [ordered]@{
                result = 'PASS'
                output = $postFix.output_text
                source_repo_worktree_list_before = $postFix.source_repo_worktree_before
                source_repo_worktree_list_after = $postFix.source_repo_worktree_after
                isolated_repo_worktree_list_before = $postFix.isolated_repo_worktree_before
                isolated_repo_worktree_list_after = $postFix.isolated_repo_worktree_after
            }
        }
        Write-Phase9Evidence -Label 'R1_R2_R3_REAL_PATH_SHAPE_PRE_FIX_FAILURE' -Value ([ordered]@{ output = $preFix.output_text; result = $preFixDispatchResult; receipt = $preFix.receipt_document; request = $preFix.request; composed_prompt_paths = $preFix.composed_prompt_paths; worktree_cleanup = $preFix.worktree_cleanup; isolated_repo_worktree_list_before = $preFix.isolated_repo_worktree_before; isolated_repo_worktree_list_after = $preFix.isolated_repo_worktree_after; source_repo_worktree_list_before = $preFix.source_repo_worktree_before; source_repo_worktree_list_after = $preFix.source_repo_worktree_after; mutation = $script:phase9R123Evidence.mutation })
        Write-Phase9Evidence -Label 'R1_R2_R3_REAL_PATH_SHAPE_POST_FIX_PASS' -Value ([ordered]@{ output = $postFix.output_text; result = $postFixDispatchResult; start = $postFix.start_result_document; run_record = $postFix.run_record_document; request = $postFix.request; worktree_cleanup = $postFix.worktree_cleanup; source_repo_worktree_list_before = $postFix.source_repo_worktree_before; source_repo_worktree_list_after = $postFix.source_repo_worktree_after; isolated_repo_worktree_list_before = $postFix.isolated_repo_worktree_before; isolated_repo_worktree_list_after = $postFix.isolated_repo_worktree_after; mutation = $script:phase9R123Evidence.mutation })
        Write-Phase9Evidence -Label 'R1_R2_R3_WORKTREE_MUTANT_A_FAILURE' -Value $mutantAEvidence
        Write-Phase9Evidence -Label 'R1_R2_R3_WORKTREE_MUTANT_B_FAILURE' -Value $mutantBEvidence
        Write-Phase9Evidence -Label 'R1_R2_R3_WORKTREE_RESTORED_PASS' -Value $script:phase9R123Evidence.restored_pass
        Write-Phase9Evidence -Label 'R1_R2_R3_WORKTREE_CLEANUP' -Value $script:phase9R123Evidence.worktree_cleanup
    }

    $invokeS3ResumeCase = {
        [CmdletBinding()]
        param([switch]$Mutant)

        $caseSlug = 's3' + [guid]::NewGuid().ToString('N').Substring(0, 6)
        $caseRoot = Join-Path $sRealDispatchParent $caseSlug
        $historyRoot = Join-Path $caseRoot '.local\ai-sessions\history'
        $codexHome = Join-Path $caseRoot 'codex-home'
        $rolloutRoot = Join-Path $codexHome 'sessions'
        $configPath = Join-Path $codexHome 'default.config.toml'
        $preflightPath = Join-Path $historyRoot 's3-preflight.json'
        $scopePlanPath = Join-Path $historyRoot 's3-scope.json'
        $quotaBeforePath = Join-Path $historyRoot 's3-quota-before.json'
        $quotaAfterPath = Join-Path $historyRoot 's3-quota-after.json'
        $calibrationPath = Join-Path $historyRoot 's3-calibration.jsonl'
        $promptPath = Join-Path $caseRoot 's3-prompt.md'
        $targetPath = Join-Path $caseRoot 'target.txt'
        $threadIdPath = Join-Path $historyRoot ('codex-thread-' + $caseSlug + '.txt')
        $fakeCodexPath = Join-Path $caseRoot 'codex.cmd'
        $externalStartedPath = Join-Path $caseRoot 'external-started.txt'
        $threadId = [guid]::NewGuid().ToString('D')
        $runtimeTimestamp = [DateTimeOffset]::UtcNow.AddMinutes(1).ToString('o')
        $scriptVariableNames = @(
            'fixtureRoot', 'testThread', 'quotaSnapshotPathOverride', 'pidResult', 'relayFailure',
            'SourceRoot', 'ExecutionRoot', 'DispatchRoot', 'LineSlug', 'DispatchSlug', 'WriteMode',
            'PreflightResultPath', 'PrepareResultPath', 'PromptPath', 'CodexHome', 'CodexPath',
            'TargetPath', 'ResumeThreadId', 'LastMessagePath', 'QuotaBeforePath', 'QuotaAfterPath',
            'CalibrationPath', 'ScopePlanPath', 'ResultPath', 'RunRecordPath', 'EventStreamPath',
            'ErrorStreamPath', 'ThreadIdPath', 'PidRecordPath', 'ProcessExitCode', 'RequiredIdentifier',
            'Profile', 'Model', 'ReasoningEffort', 'TaskType', 'SessionMode', 'DispatchKind',
            'UnitKind', 'RequestedUnit', 'AddDirectory', 'Search', 'CodexParentOption',
            'RecoveryHandoffPath', 'BudgetMonitorPath', 'EvidencePackPath', 'AdvisorConsultReportPath',
            'AdvisorRequestSource', 'PrimaryBudgetPercent', 'PrimaryReservePercent', 'AbortGraceSeconds',
            'DispatchResultPath', 'InvocationBoundParameters', 'DispatchStageBinding', 'RequestContext',
            'ProfileExplicit', 'AddDirectoryExplicit', 'SearchExplicit', 'CodexParentOptionExplicit',
            's3PreviousRun', 's3PreviousMessage', 's3FakeCodexPath', 's3StopCalls', 's3StopSnapshots'
        )
        $savedVariables = @{}
        foreach ($variableName in $scriptVariableNames) {
            $existingVariable = Get-Variable -Name $variableName -Scope Script -ErrorAction SilentlyContinue
            $savedVariables[$variableName] = if ($null -eq $existingVariable) {
                [pscustomobject]@{ exists = $false; value = $null }
            }
            else {
                [pscustomobject]@{ exists = $true; value = $existingVariable.Value }
            }
        }
        $functionNames = @(
            'Invoke-Start', 'Invoke-Inspect', 'New-CodexLauncher', 'New-ProcessStartInfo',
            'Wait-ForThreadRelay', 'Set-ThreadIdFromEventStream', 'Get-DispatchRunEvents', 'Get-CodexExecutablePath',
            'Resolve-PreviousDispatchRun', 'Compare-ResumeThreadModel', 'Test-ScopePlanHashRecord',
            'Test-ContinuationScopePlan', 'Get-DispatchUnitList', 'Get-StartedProcessSnapshot',
            'Stop-VerifiedProcessTree', 'Add-CalibrationObservation', 'Get-RuntimeModelEvidence'
        )
        $savedFunctions = @{}
        foreach ($functionName in $functionNames) {
            $savedFunctions[$functionName] = (Get-Command -Name $functionName -CommandType Function -ErrorAction Stop).ScriptBlock
        }

        try {
            $script:fixtureRoot = $caseRoot
            $script:testThread = $threadId
            $script:quotaSnapshotPathOverride = $quotaBeforePath
            $script:pidResult = @{ ActiveRecords = @(); UnconfirmedRecords = @(); Blocked = $false; Reason = '' }
            $script:relayFailure = $false
            $script:s3StopCalls = 0
            $script:s3StopSnapshots = @()
            New-Item -ItemType Directory -Path $caseRoot, $historyRoot, $codexHome, $rolloutRoot -Force | Out-Null
            $lineManifestPath = Join-Path $caseRoot '.local\ai-sessions\handoff\a\line.json'
            New-Item -ItemType Directory -Path (Split-Path -Parent $lineManifestPath) -Force | Out-Null
            Write-Utf8NoBom -Path $lineManifestPath -Content (([ordered]@{ schema = 'ai-sessions.line.v1'; 'line-slug' = 'a' } | ConvertTo-Json -Compress) + "`r`n")
            Write-Utf8NoBom -Path $configPath -Content ('model = "fixture-model"' + "`r`n" + 'model_reasoning_effort = "high"' + "`r`n")
            Write-Utf8NoBom -Path $promptPath -Content ('S-3 continuation prompt: ' + $caseSlug)
            Write-Utf8NoBom -Path $targetPath -Content ('S-3 target: ' + $caseSlug)
            Write-Utf8NoBom -Path $threadIdPath -Content ($threadId + "`r`n")
            $rolloutLines = @(
                ([ordered]@{ type = 'session_meta'; payload = [ordered]@{ session_id = $threadId } } | ConvertTo-Json -Compress -Depth 10)
                ([ordered]@{ type = 'turn_context'; timestamp = $runtimeTimestamp; payload = [ordered]@{ model = 'fixture-model'; effort = 'high' } } | ConvertTo-Json -Compress -Depth 10)
            )
            Write-Utf8NoBom -Path (Join-Path $rolloutRoot 'rollout-s3-runtime.jsonl') -Content (($rolloutLines -join "`r`n") + "`r`n")
            $null = New-Phase8QuotaSnapshot -Path $quotaBeforePath -PrimaryRemainingPercent 80
            $null = New-Phase8QuotaSnapshot -Path $quotaAfterPath -PrimaryRemainingPercent 79

            $fakeCodexLines = @(
                '@echo off'
                ('>"' + $externalStartedPath + '" echo started')
                'powershell.exe -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 7"'
                ('echo {"type":"thread.started","thread_id":"' + $threadId + '"}')
                ('echo {"type":"item.completed","item":{"type":"agent_message","text":"design.md ' + $caseSlug + ' a"}}')
                'echo {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
                'exit /b 0'
            )
            Write-Utf8NoBom -Path $fakeCodexPath -Content (($fakeCodexLines -join "`r`n") + "`r`n")

            $previous = New-TestRun -Line 'a' -Dispatch $caseSlug
            $previous.thread_id = $threadId
            $previous.thread_id_path = $threadIdPath
            $previous.prompt_path = $promptPath
            $previous.profile_config_path = $configPath
            $previous.codex_home = $codexHome
            $previous.effective_codex_home = $codexHome
            $previous.quota_before_path = $quotaBeforePath
            $previous.quota_before_sha256 = Get-FileSha256 -Path $quotaBeforePath
            $previous | Add-Member -MemberType NoteProperty -Name quota_before_freshness -Value 'fresh' -Force
            $previous | Add-Member -MemberType NoteProperty -Name quota_before_captured_at_utc -Value ([DateTime]::UtcNow.ToString('o')) -Force
            $previous.launch_state = 'started'
            $previous.source_root = $caseRoot
            $previous.execution_root = $caseRoot
            $previous.last_message_path = Join-Path $historyRoot 's3-previous-last-message.md'
            Write-Utf8NoBom -Path $previous.last_message_path -Content ('已確認結論：前輪續行 anchor 已完成' + "`r`n" + '未完成單位：無' + "`r`n" + '證據位置：' + $previous.event_stream_path)

            $scopePlan = [ordered]@{
                schema = 'ai-sessions.scope-plan.v1'
                version = 1
                dispatch_slug = $caseSlug
                dispatch_kind = 'workflow'
                task_type = 'script-change'
                requested_profile = 'default'
                session_mode = 'continuation'
                unit_kind = 'workflow-phase'
                requested_units = @('Phase 1')
                selected_units = @('Phase 1')
                deferred_units = @()
                decision = 'full'
                decision_reason = 'S-3 real continuation fixture'
                primary_remaining_percent = 80
                primary_reserve_percent = 30
                primary_budget_percent = 50
                model = 'fixture-model'
                model_evidence = $previous.model_evidence
                reasoning_effort = 'high'
                reasoning_effort_evidence = $previous.reasoning_effort_evidence
                scope_plan_fingerprint = 'fixture'
            }
            Write-Utf8NoBom -Path $scopePlanPath -Content (($scopePlan | ConvertTo-Json -Depth 30) + "`r`n")
            $previous.scope_plan_path = $scopePlanPath
            $previous.scope_plan_sha256 = Get-FileSha256 -Path $scopePlanPath
            $previous.preflight_result_path = $preflightPath
            $previous.preflight_sha256 = $null
            $previous | Add-Member -MemberType NoteProperty -Name write_mode -Value 'write' -Force
            $null = Write-DispatchRunRecord -Record $previous -Update
            $script:s3PreviousRun = $previous
            $script:s3PreviousMessage = Get-Content -LiteralPath $previous.last_message_path -Raw -Encoding UTF8

            $preflight = [ordered]@{
                operation = 'Preflight'
                status = 'completed'
                sourceRoot = $caseRoot
                executionRoot = $caseRoot
                dispatchRoot = $caseRoot
                lineSlug = 'a'
                dispatchSlug = $caseSlug
                writeMode = 'write'
                prepareResultPath = $null
                prepareResultSha256 = $null
            }
            Write-Utf8NoBom -Path $preflightPath -Content (($preflight | ConvertTo-Json -Depth 20) + "`r`n")
            $previous.preflight_sha256 = Get-FileSha256 -Path $preflightPath
            $null = Write-DispatchRunRecord -Record $previous -Update

            $script:SourceRoot = $caseRoot
            $script:ExecutionRoot = $caseRoot
            $script:DispatchRoot = $caseRoot
            $script:LineSlug = 'a'
            $script:DispatchSlug = $caseSlug
            $script:WriteMode = 'write'
            $script:PreflightResultPath = $preflightPath
            $script:PrepareResultPath = $null
            $script:PromptPath = $promptPath
            $script:CodexHome = $codexHome
            $script:CodexPath = $fakeCodexPath
            $script:TargetPath = @('target.txt')
            $script:ResumeThreadId = $threadId
            $script:LastMessagePath = $null
            $script:QuotaBeforePath = $quotaBeforePath
            $script:QuotaAfterPath = $quotaAfterPath
            $script:CalibrationPath = $calibrationPath
            $script:ScopePlanPath = $scopePlanPath
            $script:ResultPath = $null
            $script:RunRecordPath = $null
            $script:EventStreamPath = $null
            $script:ErrorStreamPath = $null
            $script:ThreadIdPath = $threadIdPath
            $script:PidRecordPath = $null
            $script:ProcessExitCode = $null
            $script:RequiredIdentifier = 'design.md'
            $script:Profile = 'default'
            $script:Model = $null
            $script:ReasoningEffort = $null
            $script:TaskType = 'script-change'
            $script:SessionMode = 'continuation'
            $script:DispatchKind = 'workflow'
            $script:UnitKind = 'workflow-phase'
            $script:RequestedUnit = @('Phase 1')
            $script:AddDirectory = @()
            $script:Search = $false
            $script:CodexParentOption = @()
            $script:RecoveryHandoffPath = $null
            $script:BudgetMonitorPath = $null
            $script:EvidencePackPath = $null
            $script:AdvisorConsultReportPath = $null
            $script:AdvisorRequestSource = $null
            $script:PrimaryBudgetPercent = $null
            $script:PrimaryReservePercent = $null
            $script:AbortGraceSeconds = 30
            $script:DispatchResultPath = $null
            $script:InvocationBoundParameters = [ordered]@{}
            $script:DispatchStageBinding = $null
            $script:RequestContext = $null
            $script:ProfileExplicit = $false
            $script:AddDirectoryExplicit = $false
            $script:SearchExplicit = $false
            $script:CodexParentOptionExplicit = $false
            $script:s3FakeCodexPath = $fakeCodexPath

            $productionDefinitions = @{}
            foreach ($functionName in @('Invoke-Start', 'Invoke-Inspect', 'New-CodexLauncher', 'New-ProcessStartInfo', 'Wait-ForThreadRelay', 'Set-ThreadIdFromEventStream', 'Get-RuntimeModelEvidence')) {
                $functionAst = @($functions | Where-Object { $_.Name -eq $functionName } | Select-Object -First 1)
                Assert-True ($functionAst.Count -eq 1) ('S-3 找不到 production ' + $functionName + ' AST。')
                $productionBody = $functionAst[0].Body.Extent.Text
                Assert-True ($productionBody.Length -ge 2 -and $productionBody[0] -eq '{' -and $productionBody[$productionBody.Length - 1] -eq '}') ('S-3 production ' + $functionName + ' body 邊界異常。')
                $productionDefinitions[$functionName] = $productionBody.Substring(1, $productionBody.Length - 2)
            }
            Set-Item -Path Function:\New-CodexLauncher -Value ([scriptblock]::Create($productionDefinitions['New-CodexLauncher']))
            Set-Item -Path Function:\New-ProcessStartInfo -Value ([scriptblock]::Create($productionDefinitions['New-ProcessStartInfo']))
            Set-Item -Path Function:\Wait-ForThreadRelay -Value ([scriptblock]::Create($productionDefinitions['Wait-ForThreadRelay']))
            Set-Item -Path Function:\Set-ThreadIdFromEventStream -Value ([scriptblock]::Create($productionDefinitions['Set-ThreadIdFromEventStream']))
            Set-Item -Path Function:\Get-RuntimeModelEvidence -Value ([scriptblock]::Create($productionDefinitions['Get-RuntimeModelEvidence']))
            Set-Item -Path Function:\Invoke-Inspect -Value ([scriptblock]::Create($productionDefinitions['Invoke-Inspect']))
            Set-Item -Path Function:\Get-CodexExecutablePath -Value ([scriptblock]::Create('param($ConfiguredPath) return $script:s3FakeCodexPath'))
            Set-Item -Path Function:\Resolve-PreviousDispatchRun -Value ([scriptblock]::Create('param($SourceRoot, $ExecutionRoot, $LineSlug, $DispatchSlug, $ResumeThreadId, $LastMessagePath) return [pscustomobject]@{ Record = $script:s3PreviousRun; AnchorRecord = $script:s3PreviousRun; ChainTailRecord = $script:s3PreviousRun; LatestActualStartRecord = $script:s3PreviousRun; LatestActualStartEvents = $null; ScopePlanRootRecord = $script:s3PreviousRun; SkippedAttempts = @(); Message = $script:s3PreviousMessage; ResumeThreadId = $ResumeThreadId }'))
            Set-Item -Path Function:\Compare-ResumeThreadModel -Value ([scriptblock]::Create('param($AnchorRecord, $CurrentModelEvidence, $CodexHome) return [ordered]@{ status = ''match''; reason_code = $null; original_thread_model = $AnchorRecord.model_evidence; current_resolved_model = $CurrentModelEvidence }'))
            Set-Item -Path Function:\Test-ScopePlanHashRecord -Value ([scriptblock]::Create('param($SourceHistoryRoot, $DispatchSlug, $LineSlug, $ScopePlanPath) return $true'))
            Set-Item -Path Function:\Test-ContinuationScopePlan -Value ([scriptblock]::Create('param($ScopePlan, $DispatchSlug, $DispatchKind, $TaskType, $RequestedProfile, $UnitKind, $Units) return $true'))
            Set-Item -Path Function:\Get-DispatchUnitList -Value ([scriptblock]::Create('param($RequestedUnit, $DispatchKind, $UnitKind, $ExecutionRoot, $LineSlug, $EvidencePackPath, $EvidenceQuestionUnits, $TargetPath) return @(''Phase 1'')'))
            Set-Item -Path Function:\Stop-VerifiedProcessTree -Value ([scriptblock]::Create('param($Snapshot) $script:s3StopCalls++; $script:s3StopSnapshots += $Snapshot; return [pscustomobject]@{ CleanupStatus = ''fixture-observed''; ErrorMessage = $null }'))
            $calibrationDefinition = @'
param(
    [string]$SourceRoot,
    [string]$Path,
    [string]$LineSlug,
    [string]$DispatchSlug,
    [string]$Profile,
    [string]$Model,
    [string]$ReasoningEffort,
    [object]$ModelEvidence,
    [object]$ReasoningEffortEvidence,
    [string]$TaskType,
    [string]$SessionMode,
    [object]$Usage,
    [object]$ExecutionResult,
    [string]$QuotaBeforePath,
    [string]$QuotaAfterPath,
    [object]$ScopePlan,
    [object]$InterruptionStatus,
    [object]$BudgetMonitor,
    [Nullable[bool]]$BeforeSnapshotFreshAtStart,
    [string]$BeforeSnapshotCapturedAtStartUtc
)
return [ordered]@{ path = $Path; recordWritten = $true; calibrationEligible = $false; ineligibleReasons = @('S-3 fixture') }
'@
            Set-Item -Path Function:\Add-CalibrationObservation -Value ([scriptblock]::Create($calibrationDefinition))
            $startDefinition = $productionDefinitions['Invoke-Start']
            if ($Mutant) {
                $patchedRelayBlock = @(
                    '        $relay = Wait-ForThreadRelay -EventPath $eventPath -ThreadPath $threadPath -TimeoutSeconds 5'
                    '        $relayReady = [bool](Get-DispatchJsonProperty -Object $relay -Name ''ready'')'
                    '        if (-not $relayReady) {'
                    '            if ([string]::IsNullOrWhiteSpace($ResumeThreadId)) {'
                    '                $phase = ''thread-relay-not-ready'''
                    '                throw (''thread relay not-ready：逾時 {0} 秒仍未取得本次 launch 的 thread.started；保留事件流與 relay 證據。'' -f $relay.timeoutSeconds)'
                    '            }'
                    '            $runRecord.thread_id = $ResumeThreadId'
                    '        }'
                    '        else {'
                    '            if ([string]::IsNullOrWhiteSpace($relay.threadId)) {'
                    '                $phase = ''thread-relay-not-ready'''
                    '                throw ''thread relay not-ready：本次 launch relay 標記 ready 但未提供 threadId。'''
                    '            }'
                    '            if (-not [string]::IsNullOrWhiteSpace($ResumeThreadId) -and $relay.threadId -cne $ResumeThreadId) {'
                    '                throw ''thread relay 與 ResumeThreadId 不一致。'''
                    '            }'
                    '            $runRecord.thread_id = $relay.threadId'
                    '            $null = Get-DispatchRunEvents $runRecord'
                    '        }'
                ) -join "`r`n"
                $oldRelayBlock = @(
                    '        $relay = Wait-ForThreadRelay -EventPath $eventPath -ThreadPath $threadPath -TimeoutSeconds 5'
                    '        if ([string]::IsNullOrWhiteSpace($relay.threadId)) {'
                    '            $phase = ''thread-relay-not-ready'''
                    '            throw (''thread relay not-ready：逾時 {0} 秒仍未取得本次 launch 的 thread.started；保留事件流與 relay 證據。'' -f $relay.timeoutSeconds)'
                    '        }'
                    '        if (-not [string]::IsNullOrWhiteSpace($ResumeThreadId) -and $relay.threadId -cne $ResumeThreadId) {'
                    '            throw ''thread relay 與 ResumeThreadId 不一致。'''
                    '        }'
                    '        $runRecord.thread_id = $relay.threadId'
                    '        $null = Get-DispatchRunEvents $runRecord'
                ) -join "`r`n"
                Assert-True ($startDefinition.Contains($patchedRelayBlock)) 'S-3 reverse 找不到 patched relay readiness block。'
                $startDefinition = $startDefinition.Replace($patchedRelayBlock, $oldRelayBlock)
                Assert-True ($startDefinition -ne $productionDefinitions['Invoke-Start']) 'S-3 reverse Invoke-Start mutant 未恢復既有空事件流解析。'
                Set-Item -Path Function:\Wait-ForThreadRelay -Value ([scriptblock]::Create(@'
param([string]$EventPath, [string]$ThreadPath, [int]$TimeoutSeconds)
$existingThreadId = (Get-Content -LiteralPath $ThreadPath -Raw -Encoding UTF8).Trim()
return [pscustomobject]@{ threadId = $existingThreadId; existingThreadId = $existingThreadId; relayed = $false; ready = $true; eventObserved = $false; source = 'existing-or-not-ready'; timedOut = $false; timeoutSeconds = $TimeoutSeconds }
'@))
                Set-Item -Path Function:\Get-DispatchRunEvents -Value ([scriptblock]::Create(@'
param([psobject]$Record)
throw 'RunRecord 事件流為空。'
'@))
            }
            Set-Item -Path Function:\Invoke-Start -Value ([scriptblock]::Create($startDefinition))

            $startResult = $null
            $startException = $null
            $startObjects = @()
            $startErrors = @()
            $Error.Clear()
            try {
                $startObjects = @(Invoke-Start)
                if ($startObjects.Count -eq 1) {
                    $startResult = $startObjects[0]
                }
            }
            catch {
                $startException = $_.Exception
                $startResult = $startException.Data['operationResult']
            }
            $startErrors = @($Error | Select-Object -First 5 | ForEach-Object { $_.Exception.Message })
            $startOutputText = (@($startObjects | ForEach-Object {
                    if ($_ -is [string]) { $_ } else { $_ | ConvertTo-Json -Depth 20 -Compress }
                }) -join ' || ')

            $eventPath = if ($null -eq $startResult) { $null } else { [string](Get-DispatchJsonProperty -Object $startResult -Name 'eventStreamPath') }
            $sidecarPath = if ($null -eq $startResult) { $null } else { [string](Get-DispatchJsonProperty -Object $startResult -Name 'processExitCodeSidecarPath') }
            $initialEventLength = if ([string]::IsNullOrWhiteSpace($eventPath) -or -not (Test-Path -LiteralPath $eventPath -PathType Leaf)) { 0 } else { (Get-Item -LiteralPath $eventPath).Length }

            if (-not $Mutant) {
                Assert-True ($null -eq $startException -and $null -ne $startResult) ('S-3 normal Start 拋出例外：' + [string]$startException + '; outputCount=' + $startObjects.Count + '; output=' + $startOutputText + '; errors=' + ($startErrors -join ' | '))
                $threadRelay = Get-DispatchJsonProperty -Object $startResult -Name 'threadRelay'
                Assert-True ([bool](Get-DispatchJsonProperty -Object $startResult -Name 'processStarted')) ('S-3 normal processStarted=false：' + ($startResult | ConvertTo-Json -Depth 30 -Compress))
                Assert-True (-not [bool](Get-DispatchJsonProperty -Object $startResult -Name 'relayReady') -and [string](Get-DispatchJsonProperty -Object $threadRelay -Name 'source') -eq 'not-ready') ('S-3 normal relay 未回報 not-ready：' + ($startResult | ConvertTo-Json -Depth 30 -Compress))
                Assert-True ($initialEventLength -eq 0 -and (Test-Path -LiteralPath $externalStartedPath -PathType Leaf)) ('S-3 normal 啟動視窗內事件流非空或 launcher 未啟動：eventLength=' + $initialEventLength)
                $rootPid = [int](Get-DispatchJsonProperty -Object $startResult -Name 'rootPid')
                Assert-True ($null -ne (Get-Process -Id $rootPid -ErrorAction SilentlyContinue)) ('S-3 normal process tree 在啟動視窗內已消失：pid=' + $rootPid)
                $completed = $false
                for ($attempt = 1; $attempt -le 120; $attempt++) {
                    $eventReady = (Test-Path -LiteralPath $eventPath -PathType Leaf) -and ((Get-Item -LiteralPath $eventPath).Length -gt 0)
                    $sidecarReady = Test-Path -LiteralPath $sidecarPath -PathType Leaf
                    $rootAlive = $null -ne (Get-Process -Id $rootPid -ErrorAction SilentlyContinue)
                    if ($eventReady -and $sidecarReady -and -not $rootAlive) {
                        $completed = $true
                        break
                    }
                    Start-Sleep -Milliseconds 250
                }
                Assert-True $completed 'S-3 normal launcher 未在等待期限內完成事件流與 sidecar。'
                $runRecordPath = [string](Get-DispatchJsonProperty -Object $startResult -Name 'runRecordPath')
                $runRecord = Read-DispatchRunRecord -Path $runRecordPath -SourceRoot $caseRoot -ExecutionRoot $caseRoot -LineSlug 'a' -DispatchSlug $caseSlug
                $runEvents = Get-DispatchRunEvents -Record $runRecord
                Assert-True ($runEvents.Completed -and $runEvents.ThreadId -ceq $threadId) ('S-3 normal 完成後 RunRecord 事件證據不符：' + ($runEvents | ConvertTo-Json -Depth 20 -Compress))
                $finalMessage = 'design.md ' + $caseSlug + ' a'
                Write-Utf8NoBom -Path $runRecord.last_message_path -Content $finalMessage
                $script:EventStreamPath = $runRecord.event_stream_path
                $script:ErrorStreamPath = [string](Get-DispatchJsonProperty -Object $startResult -Name 'stderrPath')
                $script:RunRecordPath = $runRecordPath
                $script:ScopePlanPath = $scopePlanPath
                $script:QuotaBeforePath = $quotaBeforePath
                $script:QuotaAfterPath = $quotaAfterPath
                $script:ThreadIdPath = $threadIdPath
                $script:ProcessExitCode = 0
                $script:LastMessagePath = $null
                $script:TaskType = 'script-change'
                $script:SessionMode = 'continuation'
                $script:CalibrationPath = $calibrationPath
                $script:RequiredIdentifier = 'design.md'
                $script:Profile = 'default'
                $script:Model = 'fixture-model'
                $script:ReasoningEffort = 'high'
                $script:CodexHome = $codexHome
                $inspectResult = Invoke-Inspect
                $inspectModelEvidence = Get-DispatchJsonProperty -Object $inspectResult -Name 'modelEvidence'
                $runtimeModelEvidence = Get-DispatchJsonProperty -Object $inspectModelEvidence -Name 'model'
                $runtimeModelEvidence = Get-DispatchJsonProperty -Object $runtimeModelEvidence -Name 'runtime_verifiable'
                $runtimeEffortEvidence = Get-DispatchJsonProperty -Object $inspectModelEvidence -Name 'reasoning_effort'
                $runtimeEffortEvidence = Get-DispatchJsonProperty -Object $runtimeEffortEvidence -Name 'runtime_verifiable'
                Assert-True ([bool](Get-DispatchJsonProperty -Object $inspectResult -Name 'success') -and [bool](Get-DispatchJsonProperty -Object $inspectResult -Name 'outputValid')) ('S-3 normal 後續 Inspect 未成功：' + ($inspectResult | ConvertTo-Json -Depth 40 -Compress))
                Assert-True ([string](Get-DispatchJsonProperty -Object $runtimeModelEvidence -Name 'status') -eq 'confirmed' -and [string](Get-DispatchJsonProperty -Object $runtimeEffortEvidence -Name 'status') -eq 'confirmed') ('S-3 normal Inspect 未讀取 runtime model evidence：' + ($inspectResult | ConvertTo-Json -Depth 40 -Compress))
                return [pscustomobject]@{
                    case_root = $caseRoot
                    dispatch_slug = $caseSlug
                    start = $startResult
                    inspect = $inspectResult
                    initial_event_length = $initialEventLength
                    process_exited_after_inspect = $completed
                    stop_calls = $script:s3StopCalls
                    event_path = $eventPath
                    sidecar_path = $sidecarPath
                    run_record_path = $runRecordPath
                    runtime_model_evidence = $runtimeModelEvidence
                    runtime_effort_evidence = $runtimeEffortEvidence
                }
            }

            $failureText = if ($null -eq $startException) { '' } else { $startException.ToString() }
            if ($null -ne $startResult) {
                $failureText = $failureText + "`r`n" + ($startResult | ConvertTo-Json -Depth 40 -Compress)
            }
            Assert-True ($null -ne $startException -and $failureText.Contains('RunRecord 事件流為空')) ('S-3 reverse 未暴露舊版空事件流失敗：' + $failureText)
            Assert-True ($null -ne $startResult -and [bool](Get-DispatchJsonProperty -Object $startResult -Name 'processStarted') -and [int]$script:s3StopCalls -eq 1) ('S-3 reverse 未觀察到已啟動程序的 cleanup：' + $failureText)
            $failureRecord = Get-DispatchJsonProperty -Object (Get-DispatchJsonProperty -Object $startResult -Name 'failure') -Name 'observation'
            Assert-True ([string](Get-DispatchJsonProperty -Object $failureRecord -Name 'cleanup_status') -eq 'fixture-observed' -and $initialEventLength -eq 0) ('S-3 reverse cleanup 或初始空事件流證據不符：' + $failureText)
            $rootPid = if ($null -eq $startResult) { 0 } else { [int](Get-DispatchJsonProperty -Object $startResult -Name 'rootPid') }
            for ($attempt = 1; $attempt -le 80; $attempt++) {
                if ($rootPid -le 0 -or $null -eq (Get-Process -Id $rootPid -ErrorAction SilentlyContinue)) {
                    break
                }
                Start-Sleep -Milliseconds 250
            }
            return [pscustomobject]@{
                case_root = $caseRoot
                dispatch_slug = $caseSlug
                start = $startResult
                start_exception = $failureText
                initial_event_length = $initialEventLength
                stop_calls = $script:s3StopCalls
                event_path = $eventPath
                sidecar_path = $sidecarPath
                run_record_path = if ($null -eq $startResult) { $null } else { [string](Get-DispatchJsonProperty -Object $startResult -Name 'runRecordPath') }
            }
        }
        finally {
            foreach ($functionName in $functionNames) {
                Set-Item -Path ('Function:' + $functionName) -Value $savedFunctions[$functionName]
            }
            foreach ($variableName in $scriptVariableNames) {
                $savedVariable = $savedVariables[$variableName]
                if ($savedVariable.exists) {
                    Set-Variable -Name $variableName -Scope Script -Value $savedVariable.value
                }
                else {
                    Remove-Variable -Name $variableName -Scope Script -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Invoke-Case 'Phase 9 S-3 real continuation Start waits for new relay and Inspect reads runtime evidence' {
        $s3Normal = & $invokeS3ResumeCase
        Assert-True ([bool](Get-DispatchJsonProperty -Object $s3Normal.start -Name 'processStarted') -and -not [bool](Get-DispatchJsonProperty -Object $s3Normal.start -Name 'relayReady') -and $s3Normal.initial_event_length -eq 0 -and $s3Normal.stop_calls -eq 0) ('S-3 normal Start contract 不符：' + ($s3Normal | ConvertTo-Json -Depth 40 -Compress))
        Assert-True ([bool](Get-DispatchJsonProperty -Object $s3Normal.inspect -Name 'success') -and [string](Get-DispatchJsonProperty -Object $s3Normal.runtime_model_evidence -Name 'value') -eq 'fixture-model') ('S-3 後續 Inspect runtime evidence 不符：' + ($s3Normal | ConvertTo-Json -Depth 40 -Compress))
        $s3Reverse = & $invokeS3ResumeCase -Mutant
        Assert-True ($s3Reverse.stop_calls -eq 1 -and $s3Reverse.initial_event_length -eq 0 -and [string]$s3Reverse.start_exception -match 'RunRecord 事件流為空') ('S-3 reverse 未暴露舊版 relay race：' + ($s3Reverse | ConvertTo-Json -Depth 40 -Compress))
        $s3Restored = & $invokeS3ResumeCase
        Assert-True ($s3Restored.stop_calls -eq 0 -and $s3Restored.initial_event_length -eq 0 -and [bool](Get-DispatchJsonProperty -Object $s3Restored.inspect -Name 'success')) ('S-3 reverse 後還原 production 未通過：' + ($s3Restored | ConvertTo-Json -Depth 40 -Compress))
        $script:phase9S3Evidence = [ordered]@{
            normal = $s3Normal
            reverse_failure = $s3Reverse
            restored = $s3Restored
            mutation = '將 Invoke-Start 恢復為以既有 thread id 的非空值判定 relay ready，並在空事件流上呼叫 Get-DispatchRunEvents；Wait-ForThreadRelay 同步恢復為立即回傳既有 thread id。'
        }
        Write-Phase9Evidence -Label 'S003_PRE_FIX_FAILURE' -Value $s3Reverse
        Write-Phase9Evidence -Label 'S003_NORMAL_PASS' -Value $s3Normal
        Write-Phase9Evidence -Label 'S003_REVERSE_FAILURE' -Value $s3Reverse
        Write-Phase9Evidence -Label 'S003_RESTORED_PASS' -Value $s3Restored
    }

    $script:phase9DispatchCalls = New-Object System.Collections.Generic.List[string]
    $script:phase9DispatchFailure = $null
    $script:phase9DispatchStartCalls = 0
    function Invoke-Preflight {
        $script:phase9DispatchCalls.Add('preflight')
        if ($script:phase9DispatchFailure -eq 'preflight') { throw 'fixture preflight failure' }
        return [ordered]@{ operation = 'Preflight'; status = 'completed'; sourceRoot = $script:SourceRoot; executionRoot = $script:ExecutionRoot; dispatchRoot = $script:DispatchRoot; lineSlug = $script:LineSlug; dispatchSlug = $script:DispatchSlug }
    }
    function Invoke-Prepare {
        param([string[]]$GuardTargetPath)
        $script:phase9DispatchCalls.Add('prepare')
        if ($script:phase9DispatchFailure -eq 'prepare') { throw 'fixture prepare failure' }
        return [ordered]@{ operation = 'Prepare'; status = 'completed'; resultPath = $script:PrepareResultPath }
    }
    function Invoke-Start {
        $script:phase9DispatchCalls.Add('start')
        $script:phase9DispatchStartCalls++
        return [ordered]@{ operation = 'Start'; status = 'started'; processStarted = $true; runRecordPath = (Join-Path $script:ExecutionRoot 'run.json'); eventStreamPath = (Join-Path $script:ExecutionRoot 'events.jsonl'); scopePlanPath = (Join-Path $script:ExecutionRoot 'scope.json'); processExitCodeSidecarPath = (Join-Path $script:ExecutionRoot 'exit.json') }
    }

    Invoke-Case 'Phase 9 P3 one request dispatches four stages' {
        $script:SourceRoot = $phase9Root
        $script:ExecutionRoot = Join-Path $phase9Root 'execution'
        $script:DispatchRoot = $script:ExecutionRoot
        New-Item -ItemType Directory -Path $script:ExecutionRoot -Force | Out-Null
        $script:LineSlug = 'line-a'
        $script:DispatchSlug = 'phase9-dispatch'
        $script:DispatchKind = 'workflow'
        $script:TaskType = 'script-change'
        $script:SessionMode = 'cold-start'
        $script:WriteMode = 'write'
        $script:PreflightResultPath = Join-Path $phase9Root '.local\ai-sessions\history\preflight.json'
        $script:PrepareResultPath = Join-Path $phase9Root '.local\ai-sessions\history\prepare.json'
        $script:QuotaBeforePath = Join-Path $phase9Root '.local\ai-sessions\history\quota-before.json'
        $script:QuotaAfterPath = $null
        $script:ResultPath = $dispatchResultPath
        $script:RequestPath = $dispatchRequestPath
        $script:InvocationBoundParameters = [ordered]@{}
        $script:RequestContext = $null
        $script:phase9DispatchCalls.Clear()
        $script:phase9DispatchFailure = $null
        Write-Utf8NoBom -Path $script:QuotaBeforePath -Content '{}'
        $script:quotaSnapshotPathOverride = $script:QuotaBeforePath
        $null = Apply-DispatchRequest
        $dispatchResult = Invoke-Dispatch
        Assert-True ($dispatchResult.status -eq 'started' -and (($script:phase9DispatchCalls -join ',') -eq 'preflight,prepare,start')) 'Dispatch stage 順序或成功狀態不符。'
        Assert-True (Test-Path -LiteralPath $dispatchResultPath -PathType Leaf) 'Dispatch result 未寫入。'
    }

    Invoke-Case 'Phase 9 F-002 real Dispatch leaves Prepare binding unset during Preflight' {
        $realSourceRoot = Join-Path $phase9Root 's'
        $realLineRoot = Join-Path $realSourceRoot '.local\ai-sessions\handoff\l'
        $realPromptPath = Join-Path $realSourceRoot 'dispatch-prompt.md'
        $realTargetPaths = @(
            (Join-Path $realSourceRoot 'target-one.txt')
            (Join-Path $realSourceRoot 'target-two.txt')
        )
        $realDispatchSlug = 'd'
        $realDispatchRoot = Join-Path $realSourceRoot ('.local\ai-sessions\worktrees\' + $realDispatchSlug)
        $realExecutionPromptPath = Join-Path $realDispatchRoot 'dispatch-prompt.md'
        $realHistoryRoot = Join-Path $realDispatchRoot '.local\ai-sessions\history'
        $realSourceHistoryRoot = Join-Path $realSourceRoot '.local\ai-sessions\history\l'
        $realDispatchLineRoot = Join-Path $realDispatchRoot '.local\ai-sessions\handoff\l'
        $realArtifactSourcePath = Join-Path $realLineRoot 'artifact-source.txt'
        $realArtifactDestinationPath = Join-Path $realDispatchLineRoot 'artifact-destination.txt'
        $realRequestPath = Join-Path $phase9Root 'real-dispatch-request.json'
        $realResultPath = Join-Path $realHistoryRoot 'dispatch-result.json'
        $realPreflightResultPath = Join-Path $realHistoryRoot 'preflight.json'
        $realPrepareResultPath = Join-Path $realDispatchLineRoot 'prepare.json'
        $realQuotaBeforePath = Join-Path $realHistoryRoot 'quota-before.json'
        New-Item -ItemType Directory -Path $realLineRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $realSourceHistoryRoot -Force | Out-Null
        Write-Utf8NoBom -Path (Join-Path $realLineRoot 'line.json') -Content (([ordered]@{ schema = 'ai-sessions.line.v1'; 'line-slug' = 'l' } | ConvertTo-Json -Depth 10) + "`n")
        Write-Utf8NoBom -Path $realPromptPath -Content 'real dispatch prompt'
        Write-Utf8NoBom -Path $realArtifactSourcePath -Content 'real prepare artifact'
        $realRequest = [ordered]@{
            schema = 'ai-sessions.dispatch-request.v1'
            operation = 'Dispatch'
            source_root = $realSourceRoot
            dispatch_root = $realDispatchRoot
            line_slug = 'l'
            dispatch_slug = $realDispatchSlug
            profile = 'default'
            write_mode = 'readonly'
            dispatch_kind = 'workflow'
            target_path = $realTargetPaths
            prepare_artifacts = @([ordered]@{ source = $realArtifactSourcePath; destination = $realArtifactDestinationPath; sha256 = (Get-FileSha256 -Path $realArtifactSourcePath); purpose = 'real dispatch fixture' })
            prompt_path = $realPromptPath
            task_type = 'script-change'
            session_mode = 'cold-start'
            unit_kind = 'workflow-phase'
            requested_unit = @('Phase 1')
            failure_receipt_path = (Join-Path $realSourceRoot '.local\ai-sessions\history\l\failure-receipt.json')
            result_path = $realResultPath
            preflight_result_path = $realPreflightResultPath
            prepare_result_path = $realPrepareResultPath
            quota_before_path = $realQuotaBeforePath
        }
        Write-Utf8NoBom -Path $realRequestPath -Content (($realRequest | ConvertTo-Json -Depth 20) + "`n")

        $restoredFixtureFunctions = @{}
        foreach ($functionName in @('Invoke-Preflight', 'Invoke-Prepare', 'Invoke-Start')) {
            $restoredFixtureFunctions[$functionName] = (Get-Command -Name $functionName -CommandType Function -ErrorAction Stop).ScriptBlock
            Set-Item -Path ('Function:' + $functionName) -Value $phase9ProductionFunctionDefinitions[$functionName]
        }
        try {
            $script:SourceRoot = $null
            $script:ExecutionRoot = $null
            $script:DispatchRoot = $null
            $script:LineSlug = $null
            $script:DispatchSlug = $null
            $script:WriteMode = 'readonly'
            $script:TargetPath = @()
            $script:PromptPath = $null
            $script:ResultPath = $null
            $script:PreflightResultPath = $null
            $script:PrepareResultPath = $null
            $script:QuotaBeforePath = $null
            $script:QuotaAfterPath = $null
            $script:CodexHome = $null
            $script:RequestPath = $realRequestPath
            $script:RequestContext = $null
            $script:InvocationBoundParameters = [ordered]@{}
            $Model = $null
            $ReasoningEffort = $null
            $RequiredIdentifier = 'design.md'
            $SourceRoot = $null
            $ExecutionRoot = $null
            $DispatchRoot = $null
            $LineSlug = $null
            $DispatchSlug = $null
            $WriteMode = 'readonly'
            $TargetPath = @()
            $PromptPath = $null
            $ResultPath = $null
            $PreflightResultPath = $null
            $PrepareResultPath = $null
            $QuotaBeforePath = $null
            $QuotaAfterPath = $null
            $CodexHome = $null
            $ScopePlanPath = $null
            $EventStreamPath = $null
            $RunRecordPath = $null
            $global:Model = $null
            $global:ReasoningEffort = $null
            $script:quotaSnapshotPathOverride = $realQuotaBeforePath
            $script:phase9RealDispatchGitSourceRoot = $realSourceRoot
            $script:phase9RealDispatchGitRoot = $realDispatchRoot
            $script:phase9RealDispatchGitInitialized = $false
            $script:EvidencePackPath = $null
            $script:AdvisorConsultReportPath = $null
            $script:AdvisorRequestSource = $null
            $script:startSnapshotMode = 'confirmed'
            $script:failLaunch = $false
            $script:launcherFixtureFailure = $false
            $script:pidResult.ActiveRecords = @()
            $script:pidResult.UnconfirmedRecords = @()
            $script:quotaFixtureFailure = $false
            $script:aclFixtureStatus = 'clean'
            $script:scopePlanFixtureDecision = 'full'
            $script:dispatchUnitListOverride = $null
            $script:phase9DispatchFailure = $null
            $script:phase9CaptureOnly = $false
            $null = Apply-DispatchRequest
            $SourceRoot = $realSourceRoot
            $ExecutionRoot = $realDispatchRoot
            $DispatchRoot = $realDispatchRoot
            $LineSlug = 'l'
            $DispatchSlug = $realDispatchSlug
            $WriteMode = 'readonly'
            $TargetPath = $realTargetPaths
            $ResultPath = $realResultPath
            $PreflightResultPath = $realPreflightResultPath
            $PrepareResultPath = $realPrepareResultPath
            $QuotaBeforePath = $realQuotaBeforePath
            $PromptPath = $realPromptPath
            $realResult = Invoke-Dispatch
            Assert-True ($realResult.status -eq 'started' -and @($realResult.completed_stages).Count -eq 4 -and [string]::IsNullOrWhiteSpace([string]$realResult.failed_stage)) ('real Dispatch 未依序完成四階段：' + ($realResult | ConvertTo-Json -Depth 20 -Compress))
            Assert-True (Test-Path -LiteralPath $realResultPath -PathType Leaf) 'real Dispatch 未寫入 result。'
        }
        finally {
            foreach ($functionName in @('Invoke-Preflight', 'Invoke-Prepare', 'Invoke-Start')) {
                Set-Item -Path ('Function:' + $functionName) -Value $restoredFixtureFunctions[$functionName]
            }
            $script:RequestPath = $dispatchRequestPath
            $script:RequestContext = $null
            $script:InvocationBoundParameters = [ordered]@{}
            $script:quotaSnapshotPathOverride = Join-Path $phase9Root '.local\ai-sessions\history\quota-before.json'
            $script:phase9RealDispatchGitSourceRoot = $null
            $script:phase9RealDispatchGitRoot = $null
            $script:phase9RealDispatchGitInitialized = $false
            $script:EvidencePackPath = $null
            $script:AdvisorConsultReportPath = $null
            $script:AdvisorRequestSource = $null
            $null = Apply-DispatchRequest
        }
    }

    function Invoke-Phase9StageBindingDispatchCase {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [bool]$DifferentExecutionRoot,

            [Parameter(Mandatory)]
            [bool]$OmitPrepareResultPath
        )

        $caseName = 'stage-binding-' + $(if ($DifferentExecutionRoot) { 'different' } else { 'equal' }) + '-' + $(if ($OmitPrepareResultPath) { 'omitted' } else { 'explicit' })
        $caseSlug = 'f007-' + $(if ($DifferentExecutionRoot) { 'd' } else { 'e' }) + $(if ($OmitPrepareResultPath) { 'o' } else { 'x' })
        $caseSourceRoot = $phase9Root
        $caseExecutionRoot = if ($DifferentExecutionRoot) { Join-Path $phase9Root ($caseSlug + '-execution') } else { $caseSourceRoot }
        $caseDispatchRoot = Join-Path $caseSourceRoot ('.local\ai-sessions\worktrees\' + $caseSlug)
        $caseHistoryRoot = Join-Path $caseExecutionRoot '.local\ai-sessions\history'
        $caseRequestPath = Join-Path $phase9Root ($caseSlug + '-request.json')
        $caseResultPath = Join-Path $caseHistoryRoot 'dispatch-result.json'
        $casePreflightPath = Join-Path $caseHistoryRoot 'preflight.json'
        $casePreparePath = Join-Path $caseHistoryRoot 'prepare.json'
        $caseQuotaPath = Join-Path $caseHistoryRoot 'quota-before.json'
        New-Item -ItemType Directory -Path $caseExecutionRoot, $caseHistoryRoot -Force | Out-Null
        $caseRequest = [ordered]@{
            schema = 'ai-sessions.dispatch-request.v1'
            operation = 'Dispatch'
            source_root = $caseSourceRoot
            dispatch_root = $caseDispatchRoot
            line_slug = 'line-a'
            dispatch_slug = $caseSlug
            write_mode = 'write'
            dispatch_kind = 'workflow'
            prompt_path = $dispatchRequest.prompt_path
            task_type = 'script-change'
            session_mode = 'cold-start'
            unit_kind = 'workflow-phase'
            requested_unit = @('Phase 1')
            failure_receipt_path = (Join-Path $caseSourceRoot '.local\ai-sessions\history\line-a\failure-receipt.json')
            result_path = $caseResultPath
            preflight_result_path = $casePreflightPath
            quota_before_path = $caseQuotaPath
            target_path = @('fixture-target.txt')
            prepare_artifacts = @()
        }
        if (-not $OmitPrepareResultPath) {
            $caseRequest.prepare_result_path = $casePreparePath
        }
        Write-Utf8NoBom -Path $caseRequestPath -Content (($caseRequest | ConvertTo-Json -Depth 20) + "`n")
        $null = New-Phase8QuotaSnapshot -Path $caseQuotaPath -PrimaryRemainingPercent 80
        $script:SourceRoot = $caseSourceRoot
        $script:ExecutionRoot = $caseExecutionRoot
        $script:DispatchRoot = $caseDispatchRoot
        $script:LineSlug = 'line-a'
        $script:DispatchSlug = $caseName
        $script:WriteMode = 'write'
        $script:TargetPath = @('fixture-target.txt')
        $script:PromptPath = $dispatchRequest.prompt_path
        $script:ResultPath = $caseResultPath
        $script:PreflightResultPath = $casePreflightPath
        $script:PrepareResultPath = if ($OmitPrepareResultPath) { $null } else { $casePreparePath }
        $script:QuotaBeforePath = $caseQuotaPath
        $script:QuotaAfterPath = $null
        $script:RequestPath = $caseRequestPath
        $script:RequestContext = $null
        $script:InvocationBoundParameters = [ordered]@{}
        $script:quotaSnapshotPathOverride = $caseQuotaPath
        $script:phase9DispatchCalls.Clear()
        $script:phase9DispatchFailure = $null
        $script:phase9CaptureOnly = $false
        $script:scopePlanFixtureDecision = 'full'
        $null = Apply-DispatchRequest
        $dispatchResult = Invoke-Dispatch
        Assert-True ($dispatchResult.status -eq 'started' -and $dispatchResult.stage_binding.fingerprint -match '^[a-f0-9]{64}$') ('stage binding dispatch 未成功：' + ($dispatchResult | ConvertTo-Json -Depth 30 -Compress))
        $expectedPreparePath = [string]$dispatchResult.stage_binding.prepare_result_path
        if ($OmitPrepareResultPath) {
            $expectedHistoryLineRoot = Join-Path $caseHistoryRoot 'line-a'
            Assert-True (Test-PathWithinRoot -Path $expectedPreparePath -Root $expectedHistoryLineRoot) ('omitted prepare path 未在 post-Preflight execution history line root 產生：' + $expectedPreparePath)
        }
        else {
            Assert-True ([string]::Equals($expectedPreparePath, $casePreparePath, [StringComparison]::OrdinalIgnoreCase)) ('explicit prepare path 未沿用 binding：' + $expectedPreparePath)
        }
        $stagePaths = @(
            [string]$dispatchResult.preflight_result_path
            [string]$dispatchResult.prepare_result_path
            [string]$dispatchResult.start_result_path
        )
        foreach ($stagePath in $stagePaths) {
            Assert-True (Test-Path -LiteralPath $stagePath -PathType Leaf) ('stage binding output 不存在：' + $stagePath)
            $stageDocument = Get-Content -LiteralPath $stagePath -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-True ($stageDocument.stage_binding_fingerprint -eq $dispatchResult.stage_binding.fingerprint) ('stage binding fingerprint 不一致：' + $stagePath)
        }
        Assert-True ([string]::Equals([string]$dispatchResult.quota_before_path, $caseQuotaPath, [StringComparison]::OrdinalIgnoreCase)) 'quota-before 未沿用同一 stage binding 路徑。'
        Assert-True (($script:phase9DispatchCalls -join ',') -eq 'preflight,prepare,start') ('stage binding dispatch 順序異常：' + ($script:phase9DispatchCalls -join ','))
        return [pscustomobject]@{
            name = $caseName
            different_execution_root = $DifferentExecutionRoot
            omitted_prepare_result_path = $OmitPrepareResultPath
            request_path = $caseRequestPath
            result_path = $caseResultPath
            preflight_path = $casePreflightPath
            prepare_path = $expectedPreparePath
            dispatch_result = $dispatchResult
        }
    }

    Invoke-Case 'Phase 9 F-007 stage binding omitted prepare path with equal roots' {
        $script:phase9F007EqualOmitted = Invoke-Phase9StageBindingDispatchCase -DifferentExecutionRoot $false -OmitPrepareResultPath $true
    }
    Invoke-Case 'Phase 9 F-007 stage binding explicit prepare path with equal roots' {
        $script:phase9F007EqualExplicit = Invoke-Phase9StageBindingDispatchCase -DifferentExecutionRoot $false -OmitPrepareResultPath $false
    }
    Invoke-Case 'Phase 9 F-007 stage binding omitted prepare path with different roots' {
        $script:phase9F007DifferentOmitted = Invoke-Phase9StageBindingDispatchCase -DifferentExecutionRoot $true -OmitPrepareResultPath $true
    }
    Invoke-Case 'Phase 9 F-007 stage binding explicit prepare path with different roots' {
        $script:phase9F007DifferentExplicit = Invoke-Phase9StageBindingDispatchCase -DifferentExecutionRoot $true -OmitPrepareResultPath $false
    }
    Invoke-Case 'Phase 9 F-007 reverse wrong-root binding is rejected and restored binding passes' {
        $validCase = $script:phase9F007DifferentOmitted
        $validBinding = $validCase.dispatch_result.stage_binding
        $wrongPreparePath = Join-Path $phase9Root '.local\ai-sessions\history\wrong-root-prepare.json'
        $wrongBinding = New-DispatchStageBinding -SourceRoot ([string]$validBinding.source_root) -ExecutionRoot ([string]$validBinding.execution_root) -DispatchRoot ([string]$validBinding.dispatch_root) -LineSlug 'line-a' -DispatchSlug ([string]$validBinding.dispatch_slug) -TargetPath @('fixture-target.txt') -ResultPath ([string]$validBinding.result_path) -PreflightResultPath ([string]$validBinding.preflight_result_path) -PrepareResultPath $wrongPreparePath -QuotaBeforePath ([string]$validBinding.quota_before_path) -QuotaAfterPath ''
        $reverseFailure = $null
        try {
            $null = Assert-DispatchStageBinding -Binding $wrongBinding -Stage 'prepare' -SourceRoot ([string]$validBinding.source_root) -ExecutionRoot ([string]$validBinding.execution_root) -DispatchRoot ([string]$validBinding.dispatch_root) -LineSlug ([string]$validBinding.line_slug) -DispatchSlug ([string]$validBinding.dispatch_slug) -TargetPath @('fixture-target.txt') -ResultPath ([string]$validBinding.result_path) -PreflightResultPath ([string]$validBinding.preflight_result_path) -PrepareResultPath ([string]$validBinding.prepare_result_path) -QuotaBeforePath ([string]$validBinding.quota_before_path) -QuotaAfterPath ''
        }
        catch {
            $reverseFailure = $_.Exception
        }
        Assert-True ($null -ne $reverseFailure -and $reverseFailure.Message -match 'DispatchStageBindingConflict') ('wrong-root reverse 未被拒絕：' + [string]$reverseFailure)
        $restoredPass = Assert-DispatchStageBinding -Binding $validBinding -Stage 'prepare' -SourceRoot ([string]$validBinding.source_root) -ExecutionRoot ([string]$validBinding.execution_root) -DispatchRoot ([string]$validBinding.dispatch_root) -LineSlug ([string]$validBinding.line_slug) -DispatchSlug ([string]$validBinding.dispatch_slug) -TargetPath @('fixture-target.txt') -ResultPath ([string]$validBinding.result_path) -PreflightResultPath ([string]$validBinding.preflight_result_path) -PrepareResultPath ([string]$validBinding.prepare_result_path) -QuotaBeforePath ([string]$validBinding.quota_before_path) -QuotaAfterPath ''
        Assert-True $restoredPass '還原後 stage binding 未通過。'
        $script:phase9F007ReverseEvidence = [pscustomobject]@{ wrong_binding = $wrongBinding; failure = $reverseFailure.Message; restored_pass = $restoredPass }
        Write-Phase9Evidence -Label 'F007_NORMAL_PASS' -Value @($script:phase9F007EqualOmitted, $script:phase9F007EqualExplicit, $script:phase9F007DifferentOmitted, $script:phase9F007DifferentExplicit)
        Write-Phase9Evidence -Label 'F007_REVERSE_FAILURE' -Value ([ordered]@{ status = 'failed'; wrong_binding = $wrongBinding; error = $reverseFailure.Message })
        Write-Phase9Evidence -Label 'F007_RESTORED_PASS' -Value ([ordered]@{ status = 'pass'; binding = $validBinding; result = $restoredPass })
    }

    Invoke-Case 'Phase 9 P3 pre-Start stage failure does not launch' {
        $script:phase9DispatchCalls.Clear()
        $script:phase9DispatchStartCalls = 0
        $script:phase9DispatchFailure = 'prepare'
        $failureResult = Invoke-Dispatch
        Assert-True ($failureResult.status -eq 'failed' -and $failureResult.failed_stage -eq 'prepare' -and -not [bool]$failureResult.process_started) 'Prepare failure 未產生 failed envelope。'
        Assert-True ($script:phase9DispatchStartCalls -eq 0) 'Prepare failure 仍呼叫 Start。'
        $script:phase9DispatchFailure = $null
    }

    Invoke-Case 'Phase 9 P3 seven legacy operations remain' {
        foreach ($operationName in @('Preflight', 'Prepare', 'Start', 'Inspect', 'Collect', 'QuotaProbe', 'RecoveryHandoff')) {
            $legacyPath = Join-Path $phase9Root ('legacy-' + $operationName + '.json')
            $legacyDocument = [ordered]@{ schema = 'ai-sessions.dispatch-request.v1'; operation = $operationName; line_slug = 'line-a'; dispatch_slug = ('legacy-' + $operationName).ToLowerInvariant() }
            Write-Utf8NoBom -Path $legacyPath -Content (($legacyDocument | ConvertTo-Json -Depth 12) + "`n")
            $legacyContext = Read-DispatchRequest -Path $legacyPath
            Assert-True ([string]$legacyContext.document.operation -ceq $operationName) ('legacy operation parser 失敗：' + $operationName)
        }
    }

    $launcherFunctionAst = @($functions | Where-Object { $_.Name -eq 'New-CodexLauncher' } | Select-Object -First 1)
    Assert-True ($launcherFunctionAst.Count -eq 1) 'Phase 9 找不到 production New-CodexLauncher AST。'
    $launcherFunctionDefinition = $launcherFunctionAst[0].Extent.Text -replace '^function New-CodexLauncher', 'function Invoke-Phase9ProductionCodexLauncher'
    . ([scriptblock]::Create($launcherFunctionDefinition))
    Invoke-Case 'Phase 9 P3 Dispatch exit sidecar launcher contract' {
        $launcherPath = Join-Path $phase9Root 'codex-launcher.cmd'
        $eventPath = Join-Path $phase9Root 'events.jsonl'
        $errorPath = Join-Path $phase9Root 'errors.log'
        $historyPath = Join-Path $fixtureRoot '.local\ai-sessions\history'
        $sidecarPath = Join-Path $historyPath 'codex-exit-fixture-run.json'
        New-Item -ItemType Directory -Path $historyPath -Force | Out-Null
        $null = Invoke-Phase9ProductionCodexLauncher -CodexExecutable 'codex.exe' -CodexArguments @('exec') -PromptPath (Join-Path $phase9Root 'prompt.md') -EventPath $eventPath -ErrorPath $errorPath -HistoryRoot $historyPath -LauncherPath $launcherPath -ExitSidecarPath $sidecarPath -LineSlug 'line-a' -DispatchSlug 'phase9-dispatch' -RunId ([guid]::NewGuid().ToString('D'))
        $launcherContent = Get-Content -LiteralPath $launcherPath -Raw -Encoding UTF8
        Assert-True ($launcherContent.Contains('ai-sessions.dispatch-exit.v1') -and $launcherContent.Contains('process_exit_code') -and $launcherContent.Contains('exit /b')) 'Windows launcher 未保存並傳遞原始 exit code sidecar。'
    }

    Invoke-Case 'Phase 9 F-003 POSIX launcher uses printf format string for sidecar' {
        $launcherPath = Join-Path $phase9Root 'codex-launcher.sh'
        $eventPath = Join-Path $phase9Root 'posix-events.jsonl'
        $errorPath = Join-Path $phase9Root 'posix-errors.log'
        $historyPath = Join-Path $fixtureRoot '.local\ai-sessions\history'
        $sidecarPath = Join-Path $historyPath 'posix-exit-sidecar.json'
        $platformFunction = (Get-Command -Name Test-IsWindowsPlatform -CommandType Function -ErrorAction Stop).ScriptBlock
        $externalFunction = (Get-Command -Name Invoke-ExternalCommand -CommandType Function -ErrorAction Stop).ScriptBlock
        $commandPathFunction = (Get-Command -Name Get-CommandPath -CommandType Function -ErrorAction Stop).ScriptBlock
        function Invoke-Phase9NoopExternalCommand {
            param($FileName, $WorkingDirectory, $Arguments, [switch]$AllowFailure)
            return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }
        function Invoke-Phase9FixtureCommandPath {
            param([string]$Name)
            return (Get-Command -Name sh -ErrorAction Stop).Source
        }
        try {
            Set-Item -Path Function:\global:Test-IsWindowsPlatform -Value ([scriptblock]::Create('return $false'))
            Set-Item -Path Function:\global:Invoke-ExternalCommand -Value (Get-Command -Name Invoke-Phase9NoopExternalCommand -CommandType Function).ScriptBlock
            Set-Item -Path Function:\global:Get-CommandPath -Value (Get-Command -Name Invoke-Phase9FixtureCommandPath -CommandType Function).ScriptBlock
            $runId = '00000000-0000-0000-0000-000000000001'
            $null = Invoke-Phase9ProductionCodexLauncher -CodexExecutable '/usr/bin/codex' -CodexArguments @('exec') -PromptPath (Join-Path $phase9Root 'posix-prompt.md') -EventPath $eventPath -ErrorPath $errorPath -HistoryRoot $historyPath -LauncherPath $launcherPath -ExitSidecarPath $sidecarPath -LineSlug 'line-a' -DispatchSlug 'phase9-posix' -RunId $runId
            $launcherContent = Get-Content -LiteralPath $launcherPath -Raw -Encoding UTF8
            $sidecarTemplate = '{"schema":"ai-sessions.dispatch-exit.v1","line_slug":"line-a","dispatch_slug":"phase9-posix","run_id":"' + $runId + '","process_exit_code":%s,"exit_code_status":"known"}'
            $expectedPrintf = "printf '$sidecarTemplate\n' " + '"$_codex_exit"' + ' > ' + '"$_sidecar_tmp"'
            Assert-True ($launcherContent.Contains($expectedPrintf) -and -not $launcherContent.Contains("printf '%s\n' '")) ('POSIX launcher printf 格式不符：' + $launcherContent)
        }
        finally {
            Set-Item -Path Function:\global:Test-IsWindowsPlatform -Value $platformFunction
            Set-Item -Path Function:\global:Invoke-ExternalCommand -Value $externalFunction
            Set-Item -Path Function:\global:Get-CommandPath -Value $commandPathFunction
        }
    }

    $calibrationFunctionAst = @($functions | Where-Object { $_.Name -eq 'Add-CalibrationObservation' } | Select-Object -First 1)
    Assert-True ($calibrationFunctionAst.Count -eq 1) 'Phase 9 找不到 production Add-CalibrationObservation AST。'
    $calibrationBeforePath = Join-Path $phase9Root 'calibration-before.json'
    $calibrationAfterPath = Join-Path $phase9Root 'calibration-after.json'
    $calibrationStaleAfterPath = Join-Path $phase9Root 'calibration-after-stale.json'
    $calibrationPath = Join-Path $phase9Root '.local\ai-sessions\history\quota-calibration.jsonl'
    $null = New-Phase8QuotaSnapshot -Path $calibrationBeforePath -PrimaryRemainingPercent 80
    $null = New-Phase8QuotaSnapshot -Path $calibrationAfterPath -PrimaryRemainingPercent 79
    $staleAfterSnapshot = Get-Content -LiteralPath $calibrationAfterPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $staleObservedAt = [DateTimeOffset]::UtcNow.AddMinutes(-31).ToString('o')
    $staleAfterSnapshot.captured_at_utc = $staleObservedAt
    foreach ($windowName in @('primary', 'secondary')) {
        $staleObservation = Get-DispatchJsonProperty -Object $staleAfterSnapshot.observations -Name $windowName
        $staleObservation.observed_at_utc = $staleObservedAt
        $staleObservation.freshness = 'stale'
    }
    Write-Utf8NoBom -Path $calibrationStaleAfterPath -Content (($staleAfterSnapshot | ConvertTo-Json -Depth 20) + "`n")

    Invoke-Case 'Phase 9 F-003 Windows Dispatch CLI sidecar is produced by Start launcher' {
        $actualRoot = Join-Path $fixtureRoot 'w'
        $actualDispatchRoot = Join-Path $actualRoot '.local\ai-sessions\worktrees\x'
        $actualLineRoot = Join-Path $actualRoot '.local\ai-sessions\handoff\a'
        $actualHistoryRoot = Join-Path $actualDispatchRoot '.local\ai-sessions\history\a'
        $actualPromptSourcePath = Join-Path $actualRoot 'dispatch-prompt.md'
        $actualPromptPath = Join-Path $actualDispatchRoot 'dispatch-prompt.md'
        $actualTargetPath = Join-Path $actualRoot 'target.txt'
        $actualQuotaPath = Join-Path $actualRoot 'quota-before.json'
        $actualCodexHome = Join-Path $actualRoot 'codex-home'
        $actualCodexPath = Join-Path $actualRoot 'codex.cmd'
        $actualRequestPath = Join-Path $actualRoot 'dispatch-request.json'
        $actualResultPath = Join-Path $actualHistoryRoot 'dispatch-result.json'
        $actualInspectResultPath = Join-Path $actualRoot 'dispatch-inspect-result.json'
        $actualQuotaAfterPath = Join-Path $actualRoot 'quota-after.json'
        $actualCalibrationPath = Join-Path $actualHistoryRoot 'quota-calibration.jsonl'
        $actualPreflightResultPath = Join-Path $actualRoot 'preflight-result.json'
        $actualPrepareResultPath = Join-Path $actualHistoryRoot 'prepare.json'
        $actualArtifactSourcePath = Join-Path $actualLineRoot 'artifact.txt'
        $actualArtifactDestinationPath = Join-Path $actualHistoryRoot 'artifact.txt'
        New-Item -ItemType Directory -Path $actualRoot, $actualLineRoot, $actualCodexHome -Force | Out-Null
        Write-Utf8NoBom -Path $actualTargetPath -Content "actual Windows sidecar target`n"
        Write-Utf8NoBom -Path $actualPromptSourcePath -Content 'actual Windows sidecar dispatch prompt'
        $gitHostPath = (Get-Command git.exe -ErrorAction Stop).Source
        $gitInit = Invoke-Phase9Process -HostPath $gitHostPath -Arguments @('init') -WorkingDirectory $actualRoot -EnvironmentVariables @{}
        Assert-True ([int]$gitInit.exit_code -eq 0) ('實際 Windows Dispatch fixture git init 失敗：' + [string]$gitInit.stdout + [string]$gitInit.stderr)
        $gitAdd = Invoke-Phase9Process -HostPath $gitHostPath -Arguments @('add', '--', 'target.txt', 'dispatch-prompt.md') -WorkingDirectory $actualRoot -EnvironmentVariables @{}
        Assert-True ([int]$gitAdd.exit_code -eq 0) ('實際 Windows Dispatch fixture git add 失敗：' + [string]$gitAdd.stdout + [string]$gitAdd.stderr)
        $gitCommit = Invoke-Phase9Process -HostPath $gitHostPath -Arguments @('-c', 'user.name=phase9-fixture', '-c', 'user.email=phase9-fixture@example.invalid', 'commit', '--no-verify', '-m', 'phase9 fixture') -WorkingDirectory $actualRoot -EnvironmentVariables @{}
        Assert-True ([int]$gitCommit.exit_code -eq 0) ('實際 Windows Dispatch fixture git commit 失敗：' + [string]$gitCommit.stdout + [string]$gitCommit.stderr)
        Write-Utf8NoBom -Path (Join-Path $actualLineRoot 'line.json') -Content (([ordered]@{ schema = 'ai-sessions.line.v1'; 'line-slug' = 'a' } | ConvertTo-Json -Depth 10) + "`n")
        Write-Utf8NoBom -Path $actualArtifactSourcePath -Content 'actual Windows sidecar artifact'
        $actualArtifactSha256 = Get-FileSha256 -Path $actualArtifactSourcePath
        Write-Utf8NoBom -Path (Join-Path $actualCodexHome 'default.config.toml') -Content ('model = "fixture-model"' + "`r`n" + 'model_reasoning_effort = "high"' + "`r`n")
        Copy-Item -LiteralPath $calibrationBeforePath -Destination $actualQuotaPath -Force
        $actualThreadId = '00000000-0000-0000-0000-000000000009'
        $fakeCodexContent = @(
            '@echo off'
            ('echo {"type":"thread.started","thread_id":"' + $actualThreadId + '"}')
            'echo {"type":"item.completed","item":{"type":"agent_message","text":"design.md x a actual sidecar fixture"}}'
            'echo {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
            'powershell.exe -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 3"'
            'exit /b 0'
        ) -join "`r`n"
        Write-Utf8NoBom -Path $actualCodexPath -Content ($fakeCodexContent + "`r`n")
        $actualRequest = [ordered]@{
            schema = 'ai-sessions.dispatch-request.v1'
            operation = 'Dispatch'
            source_root = $actualRoot
            dispatch_root = $actualDispatchRoot
            line_slug = 'a'
            dispatch_slug = 'x'
            profile = 'default'
            write_mode = 'write'
            dispatch_kind = 'workflow'
            target_path = @('target.txt')
            prepare_artifacts = @([ordered]@{ source = $actualArtifactSourcePath; destination = $actualArtifactDestinationPath; sha256 = $actualArtifactSha256; purpose = 'actual Windows sidecar' })
            prompt_path = $actualPromptPath
            task_type = 'script-change'
            session_mode = 'cold-start'
            unit_kind = 'workflow-phase'
            requested_unit = @('Phase 1')
            failure_receipt_path = (Join-Path $actualRoot '.local\ai-sessions\history\a\failure-receipt.json')
            result_path = $actualResultPath
            preflight_result_path = $actualPreflightResultPath
            prepare_result_path = $actualPrepareResultPath
            quota_before_path = $actualQuotaPath
        }
        Write-Utf8NoBom -Path $actualRequestPath -Content (($actualRequest | ConvertTo-Json -Depth 20) + "`n")
        $hostPath = (Get-Command powershell.exe -ErrorAction Stop).Source
        $run = Invoke-Phase9Process -HostPath $hostPath -Arguments @(
            '-NoProfile'
            '-File'
            $sourcePath
            '-CodexPath'
            $actualCodexPath
            '-CodexHome'
            $actualCodexHome
            '-Operation'
            'Dispatch'
            '-RequestPath'
            $actualRequestPath
        ) -WorkingDirectory $root -EnvironmentVariables @{}
        Assert-True ([int]$run.exit_code -eq 0) ('實際 Windows Dispatch CLI 未成功：' + [string]$run.stdout + [string]$run.stderr)
        $dispatchResultFile = $null
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            if (Test-Path -LiteralPath $actualResultPath -PathType Leaf) {
                $dispatchResultFile = Get-Item -LiteralPath $actualResultPath
                break
            }
            Start-Sleep -Milliseconds 100
        }
        Assert-True ($null -ne $dispatchResultFile) ('實際 Windows Dispatch 未找到結果檔。CLI exit=' + [string]$run.exit_code + '; command=' + [string]$run.command + '; stdout=' + [string]$run.stdout + '; stderr=' + [string]$run.stderr)
        $dispatchDocument = Get-Content -LiteralPath $dispatchResultFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $startPath = [string]$dispatchDocument.start_result_path
        Assert-True ($dispatchDocument.status -eq 'started' -and [bool]$dispatchDocument.process_started -and $dispatchDocument.completed_stages -contains 'start') ('實際 Windows Dispatch 結果未完成 Start：' + ($dispatchDocument | ConvertTo-Json -Depth 20 -Compress))
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$dispatchDocument.inspect_binding.process_exit_code_sidecar_path)) 'Dispatch 結果未綁定 sidecar path。'
        $sidecarPath = [string]$dispatchDocument.inspect_binding.process_exit_code_sidecar_path
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            if (Test-Path -LiteralPath $sidecarPath -PathType Leaf) {
                break
            }
            Start-Sleep -Milliseconds 150
        }
        Assert-True (Test-Path -LiteralPath $sidecarPath -PathType Leaf) ('Windows launcher 未產生 sidecar：' + $sidecarPath)
        $sidecarDocument = Get-Content -LiteralPath $sidecarPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($sidecarDocument.schema -eq 'ai-sessions.dispatch-exit.v1' -and $sidecarDocument.process_exit_code -eq 0 -and $sidecarDocument.exit_code_status -eq 'known') ('Windows sidecar 內容不符：' + ($sidecarDocument | ConvertTo-Json -Depth 20 -Compress))
        Assert-True (Test-Path -LiteralPath $startPath -PathType Leaf) '實際 Windows Start stage result 不存在。'
        $startDocument = Get-Content -LiteralPath $startPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($startDocument.processExitCodeSidecarPath -eq $sidecarPath) 'Start stage 未保存相同 sidecar path。'
        Copy-Item -LiteralPath $calibrationAfterPath -Destination $actualQuotaAfterPath -Force
        $inspectRun = Invoke-Phase9Process -HostPath $hostPath -Arguments @(
            '-NoProfile'
            '-File'
            $sourcePath
            '-Operation'
            'Inspect'
            '-DispatchResultPath'
            $actualResultPath
            '-SourceRoot'
            $actualRoot
            '-ExecutionRoot'
            $actualDispatchRoot
            '-LineSlug'
            'a'
            '-DispatchSlug'
            'x'
            '-RequiredIdentifier'
            'design.md'
            '-TargetPath'
            'target.txt'
            '-QuotaAfterPath'
            $actualQuotaAfterPath
            '-CalibrationPath'
            $actualCalibrationPath
            '-TaskType'
            'script-change'
            '-SessionMode'
            'cold-start'
            '-CodexHome'
            $actualCodexHome
            '-ResultPath'
            $actualInspectResultPath
        ) -WorkingDirectory $root -EnvironmentVariables @{}
        Assert-True ([int]$inspectRun.exit_code -eq 0) ('實際 Windows Inspect 未成功：' + [string]$inspectRun.stdout + [string]$inspectRun.stderr)
        Assert-True (Test-Path -LiteralPath $actualInspectResultPath -PathType Leaf) '實際 Windows Inspect 結果不存在。'
        $inspectDocument = Get-Content -LiteralPath $actualInspectResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($inspectDocument.processExitCode -eq 0 -and $inspectDocument.processExitCodeSource -eq 'sidecar' -and $inspectDocument.processExitCodeSidecarPath -eq $sidecarPath) ('Inspect 未以 sidecar 填入 process exit code：' + ($inspectDocument | ConvertTo-Json -Depth 20 -Compress))
        $launcherCallText = '-ExitSidecarPath $exitSidecarPathValue'
        $productionText = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
        Assert-True ($productionText.Contains($launcherCallText)) 'F-003 reverse fixture 找不到 Invoke-Start sidecar 接線。'
        $mutantText = $productionText.Replace($launcherCallText, '')
        $mutantPath = Join-Path $phase9Root 'f003-mutant-Invoke-CodexDispatch.ps1'
        $bomEncoding = New-Object System.Text.UTF8Encoding($true)
        [IO.File]::WriteAllText($mutantPath, $mutantText, $bomEncoding)
        $reverseDispatchSlug = 'y'
        $reverseDispatchRoot = Join-Path $actualRoot '.local\ai-sessions\worktrees\y'
        $reverseHistoryRoot = Join-Path $reverseDispatchRoot '.local\ai-sessions\history\a'
        $reversePromptPath = Join-Path $reverseDispatchRoot 'dispatch-prompt.md'
        $reverseQuotaPath = Join-Path $actualRoot 'quota-before-reverse.json'
        $reverseRequestPath = Join-Path $actualRoot 'dispatch-request-reverse.json'
        Copy-Item -LiteralPath $actualQuotaPath -Destination $reverseQuotaPath -Force
        $reverseRequest = [ordered]@{}
        foreach ($property in $actualRequest.GetEnumerator()) {
            $reverseRequest[$property.Key] = $property.Value
        }
        $reverseRequest.dispatch_root = $reverseDispatchRoot
        $reverseRequest.dispatch_slug = $reverseDispatchSlug
        $reverseRequest.result_path = Join-Path $reverseHistoryRoot 'dispatch-result.json'
        $reverseRequest.preflight_result_path = Join-Path $actualRoot 'preflight-result-reverse.json'
        $reverseRequest.prepare_result_path = Join-Path $reverseHistoryRoot 'prepare.json'
        $reverseRequest.prepare_artifacts = @([ordered]@{ source = $actualArtifactSourcePath; destination = (Join-Path $reverseHistoryRoot 'artifact.txt'); sha256 = $actualArtifactSha256; purpose = 'actual Windows sidecar reverse' })
        $reverseRequest.prompt_path = $reversePromptPath
        $reverseRequest.quota_before_path = $reverseQuotaPath
        Write-Utf8NoBom -Path $reverseRequestPath -Content (($reverseRequest | ConvertTo-Json -Depth 20) + "`n")
        $reverseRun = Invoke-Phase9Process -HostPath $hostPath -Arguments @(
            '-NoProfile'
            '-File'
            $mutantPath
            '-CodexPath'
            $actualCodexPath
            '-CodexHome'
            $actualCodexHome
            '-Operation'
            'Dispatch'
            '-RequestPath'
            $reverseRequestPath
        ) -WorkingDirectory $root -EnvironmentVariables @{}
        $reverseDispatchOutput = [string]$reverseRun.stdout + [string]$reverseRun.stderr
        $reverseDispatchDocument = if (-not [string]::IsNullOrWhiteSpace($reverseDispatchOutput)) { $reverseDispatchOutput | ConvertFrom-Json } else { $null }
        Assert-True ([int]$reverseRun.exit_code -eq 0 -and $null -ne $reverseDispatchDocument -and $reverseDispatchDocument.status -eq 'started') ('F-003 reverse Dispatch 未建立可供 Inspect 驗證的 started 結果：' + $reverseDispatchOutput)
        $reverseResultPath = [string]$reverseRequest.result_path
        Assert-True (Test-Path -LiteralPath $reverseResultPath -PathType Leaf) ('F-003 reverse Dispatch result 不存在：' + $reverseResultPath)
        $reverseDispatchResultDocument = Get-Content -LiteralPath $reverseResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $reverseStartPath = [string]$reverseDispatchResultDocument.start_result_path
        Assert-True (Test-Path -LiteralPath $reverseStartPath -PathType Leaf) ('F-003 reverse Start stage result 不存在：' + $reverseStartPath)
        $reverseStartDocument = Get-Content -LiteralPath $reverseStartPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $reverseSidecarPath = [string]$reverseDispatchResultDocument.inspect_binding.process_exit_code_sidecar_path
        $reverseRootPidProperty = $reverseStartDocument.PSObject.Properties['root_pid']
        if ($null -eq $reverseRootPidProperty) {
            $reverseRootPidProperty = $reverseStartDocument.PSObject.Properties['rootPid']
        }
        $reverseRootPid = if ($null -eq $reverseRootPidProperty) { 0 } else { [int]$reverseRootPidProperty.Value }
        if ($reverseRootPid -gt 0) {
            for ($attempt = 1; $attempt -le 40; $attempt++) {
                if ($null -eq (Get-Process -Id $reverseRootPid -ErrorAction SilentlyContinue)) {
                    break
                }
                Start-Sleep -Milliseconds 150
            }
        }
        Assert-True (-not [string]::IsNullOrWhiteSpace($reverseSidecarPath) -and -not (Test-Path -LiteralPath $reverseSidecarPath -PathType Leaf)) ('F-003 reverse mutant unexpectedly produced sidecar：' + $reverseSidecarPath)
        $reverseInspectResultPath = Join-Path $actualRoot 'dispatch-inspect-result-reverse.json'
        $reverseInspectRun = Invoke-Phase9Process -HostPath $hostPath -Arguments @(
            '-NoProfile'
            '-File'
            $mutantPath
            '-Operation'
            'Inspect'
            '-DispatchResultPath'
            $reverseResultPath
            '-SourceRoot'
            $actualRoot
            '-ExecutionRoot'
            $reverseDispatchRoot
            '-LineSlug'
            'a'
            '-DispatchSlug'
            $reverseDispatchSlug
            '-RequiredIdentifier'
            'design.md'
            '-TargetPath'
            'target.txt'
            '-QuotaAfterPath'
            $actualQuotaAfterPath
            '-CalibrationPath'
            $actualCalibrationPath
            '-TaskType'
            'script-change'
            '-SessionMode'
            'cold-start'
            '-CodexHome'
            $actualCodexHome
            '-ResultPath'
            $reverseInspectResultPath
        ) -WorkingDirectory $root -EnvironmentVariables @{}
        $reverseInspectOutput = [string]$reverseInspectRun.stdout + [string]$reverseInspectRun.stderr
        $reverseInspectDocument = if (Test-Path -LiteralPath $reverseInspectResultPath -PathType Leaf) { Get-Content -LiteralPath $reverseInspectResultPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
        Assert-True ([int]$reverseInspectRun.exit_code -eq 1 -and $null -ne $reverseInspectDocument -and $reverseInspectDocument.errorCode -eq 'DispatchExitCodeUnavailable') ('F-003 reverse Inspect 未因 sidecar 缺失失敗：' + $reverseInspectOutput)
        Assert-True ($reverseInspectOutput -match 'sidecar|DispatchExitCodeUnavailable|process_exit_code') ('F-003 reverse failure did not expose missing sidecar evidence：' + $reverseInspectOutput)
        $restoredInspectResultPath = Join-Path $actualRoot 'dispatch-inspect-result-restored.json'
        $restoredInspectRun = Invoke-Phase9Process -HostPath $hostPath -Arguments @(
            '-NoProfile'
            '-File'
            $sourcePath
            '-Operation'
            'Inspect'
            '-DispatchResultPath'
            $actualResultPath
            '-SourceRoot'
            $actualRoot
            '-ExecutionRoot'
            $actualDispatchRoot
            '-LineSlug'
            'a'
            '-DispatchSlug'
            'x'
            '-RequiredIdentifier'
            'design.md'
            '-TargetPath'
            'target.txt'
            '-QuotaAfterPath'
            $actualQuotaAfterPath
            '-CalibrationPath'
            $actualCalibrationPath
            '-TaskType'
            'script-change'
            '-SessionMode'
            'cold-start'
            '-CodexHome'
            $actualCodexHome
            '-ResultPath'
            $restoredInspectResultPath
        ) -WorkingDirectory $root -EnvironmentVariables @{}
        $restoredInspectDocument = if (Test-Path -LiteralPath $restoredInspectResultPath -PathType Leaf) { Get-Content -LiteralPath $restoredInspectResultPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
        Assert-True ([int]$restoredInspectRun.exit_code -eq 0 -and $null -ne $restoredInspectDocument -and $restoredInspectDocument.processExitCode -eq 0 -and $restoredInspectDocument.processExitCodeSource -eq 'sidecar') ('F-003 reverse 後還原 Inspect 未通過：' + [string]$restoredInspectRun.stdout + [string]$restoredInspectRun.stderr)
        $script:phase9F003WindowsEvidence = [pscustomobject]@{
            run = $run
            result_path = $dispatchResultFile.FullName
            sidecar_path = $sidecarPath
            start_path = $startPath
            sidecar = $sidecarDocument
            inspect = $inspectRun
            inspect_result_path = $actualInspectResultPath
            inspect_document = $inspectDocument
            reverse = $reverseRun
            reverse_dispatch_document = $reverseDispatchResultDocument
            reverse_inspect = $reverseInspectRun
            reverse_inspect_result_path = $reverseInspectResultPath
            reverse_inspect_document = $reverseInspectDocument
            reverse_dispatch_root = $reverseDispatchRoot
            restored_inspect = $restoredInspectRun
            restored_inspect_result_path = $restoredInspectResultPath
            restored_inspect_document = $restoredInspectDocument
            mutation = 'Invoke-Start -ExitSidecarPath argument removed before the reverse CLI run.'
        }
        Write-Phase9Evidence -Label 'F003_NORMAL_PASS' -Value ([ordered]@{ dispatch = $run; sidecar = $sidecarDocument; inspect = $inspectRun; inspect_document = $inspectDocument })
        Write-Phase9Evidence -Label 'F003_REVERSE_FAILURE' -Value ([ordered]@{ dispatch = $reverseRun; dispatch_document = $reverseDispatchDocument; inspect = $reverseInspectRun; inspect_document = $reverseInspectDocument; mutation = 'Invoke-Start -ExitSidecarPath argument removed before the reverse CLI run.' })
        Write-Phase9Evidence -Label 'F003_RESTORED_PASS' -Value ([ordered]@{ inspect = $restoredInspectRun; inspect_result_path = $restoredInspectResultPath; inspect_document = $restoredInspectDocument })
        $rootPidProperty = $startDocument.PSObject.Properties['root_pid']
        if ($null -eq $rootPidProperty) {
            $rootPidProperty = $startDocument.PSObject.Properties['rootPid']
        }
        $rootPid = if ($null -eq $rootPidProperty) { 0 } else { [int]$rootPidProperty.Value }
        if ($rootPid -gt 0) {
            $rootProcess = Get-Process -Id $rootPid -ErrorAction SilentlyContinue
            if ($null -ne $rootProcess) {
                Stop-Process -Id $rootPid -Force -ErrorAction SilentlyContinue
            }
        }
        if ($reverseRootPid -gt 0) {
            $reverseProcess = Get-Process -Id $reverseRootPid -ErrorAction SilentlyContinue
            if ($null -ne $reverseProcess) {
                Stop-Process -Id $reverseRootPid -Force -ErrorAction SilentlyContinue
            }
        }
    }

    function Read-QuotaSnapshot {
        param([string]$Path)
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    $calibrationScopePlan = [pscustomobject]@{
        dispatch_slug = 'phase9-calibration'
        dispatch_kind = 'workflow'
        task_type = 'script-change'
        requested_profile = 'default'
        session_mode = 'cold-start'
        primary_remaining_percent = 80
        primary_reserve_percent = 30
        primary_budget_percent = 10
        estimate_percent = $null
        estimate_source = 'not-required-above-threshold'
        unit_kind = 'workflow-phase'
        requested_units = @('Phase 1')
        selected_units = @('Phase 1')
        deferred_units = @()
        decision = 'full'
        decision_reason = 'fixture'
        scope_plan_fingerprint = 'fixture'
    }
    $calibrationScopePlan.scope_plan_fingerprint = Get-ScopePlanFingerprint -ScopePlan $calibrationScopePlan
    $calibrationExecution = [pscustomobject]@{ completed = $true; processExitCode = 0; outputValid = $true; success = $true }
    Invoke-Case 'Phase 9 P4 over-30-minute start-fresh calibration' {
        $calibrationResult = Add-CalibrationObservation -SourceRoot $phase9Root -Path $calibrationPath -LineSlug 'line-a' -DispatchSlug 'phase9-calibration' -Profile 'default' -Model 'fixture-model' -ReasoningEffort 'high' -TaskType 'script-change' -SessionMode 'cold-start' -Usage ([pscustomobject]@{ input_tokens = 1; output_tokens = 1 }) -ExecutionResult $calibrationExecution -QuotaBeforePath $calibrationBeforePath -QuotaAfterPath $calibrationAfterPath -ScopePlan $calibrationScopePlan -BeforeSnapshotFreshAtStart $true -BeforeSnapshotCapturedAtStartUtc ([DateTime]::UtcNow.AddMinutes(-31).ToString('o'))
        Assert-True ($calibrationResult.calibrationEligible -and $calibrationResult.recordWritten) 'Start fresh 的 calibration 未標記 eligible。'
        foreach ($name in @('snapshots_present', 'snapshots_fresh', 'usage_present', 'execution_completed', 'task_type_present', 'non_negative_delta')) {
            $calibrationChecks = Get-DispatchJsonProperty -Object $calibrationResult -Name 'calibrationChecks'
            Assert-True ($null -ne $calibrationChecks -and [bool](Get-DispatchJsonProperty -Object $calibrationChecks -Name $name)) ('缺少 calibration check：' + $name)
        }
    }

    Invoke-Case 'Phase 9 P4 calibration checks identify missing usage' {
        $missingUsageResult = Add-CalibrationObservation -SourceRoot $phase9Root -Path $calibrationPath -LineSlug 'line-a' -DispatchSlug 'phase9-calibration-missing-usage' -Profile 'default' -Model 'fixture-model' -ReasoningEffort 'high' -TaskType 'script-change' -SessionMode 'cold-start' -Usage $null -ExecutionResult $calibrationExecution -QuotaBeforePath $calibrationBeforePath -QuotaAfterPath $calibrationAfterPath -ScopePlan $calibrationScopePlan -BeforeSnapshotFreshAtStart $true -BeforeSnapshotCapturedAtStartUtc ([DateTime]::UtcNow.AddMinutes(-31).ToString('o'))
        Assert-True (-not $missingUsageResult.calibrationEligible -and -not $missingUsageResult.calibrationChecks.usage_present -and @($missingUsageResult.ineligibleReasons) -contains 'usage_present') 'usage 缺漏未映射至 calibration check 與 ineligible reason。'
    }

    Invoke-Case 'Phase 9 P4 stale after and abnormal completion' {
        $abnormalExecution = [pscustomobject]@{ completed = $false; processExitCode = 9; outputValid = $true; success = $false }
        $abnormalResult = Add-CalibrationObservation -SourceRoot $phase9Root -Path $calibrationPath -LineSlug 'line-a' -DispatchSlug 'phase9-calibration-abnormal' -Profile 'default' -Model 'fixture-model' -ReasoningEffort 'high' -TaskType 'script-change' -SessionMode 'cold-start' -Usage ([pscustomobject]@{ input_tokens = 1; output_tokens = 1 }) -ExecutionResult $abnormalExecution -QuotaBeforePath $calibrationBeforePath -QuotaAfterPath $calibrationAfterPath -ScopePlan $calibrationScopePlan -BeforeSnapshotFreshAtStart $false -BeforeSnapshotCapturedAtStartUtc ([DateTime]::UtcNow.AddMinutes(-31).ToString('o'))
        Assert-True (-not $abnormalResult.calibrationEligible -and -not $abnormalResult.calibrationChecks.snapshots_fresh -and -not $abnormalResult.calibrationChecks.execution_completed) 'stale after 或 abnormal completion 未阻止 calibration。'
    }

    Invoke-Case 'Phase 9 F-008 before freshness reason is independent' {
        $beforeFreshResult = Add-CalibrationObservation -SourceRoot $phase9Root -Path (Join-Path $phase9Root 'f008-before-freshness.jsonl') -LineSlug 'line-a' -DispatchSlug 'phase9-f008-before-freshness' -Profile 'default' -Model 'fixture-model' -ReasoningEffort 'high' -TaskType 'script-change' -SessionMode 'cold-start' -Usage ([pscustomobject]@{ input_tokens = 1; output_tokens = 1 }) -ExecutionResult $calibrationExecution -QuotaBeforePath $calibrationBeforePath -QuotaAfterPath $calibrationAfterPath -ScopePlan $calibrationScopePlan -BeforeSnapshotFreshAtStart $false -BeforeSnapshotCapturedAtStartUtc ([DateTimeOffset]::UtcNow.AddMinutes(-31).ToString('o'))
        $beforeReasons = @($beforeFreshResult.ineligibleReasons)
        Assert-True (-not $beforeFreshResult.calibrationEligible -and -not $beforeFreshResult.calibrationChecks.before_fresh_at_start -and [bool]$beforeFreshResult.calibrationChecks.after_fresh_at_inspect) 'before freshness negative case 未維持獨立 check。'
        Assert-True ($beforeReasons -contains 'before_fresh_at_start' -and $beforeReasons -notcontains 'after_fresh_at_inspect') ('before freshness reason 不精確：' + ($beforeReasons -join ', '))
        $script:phase9F008BeforeEvidence = $beforeFreshResult
    }

    Invoke-Case 'Phase 9 F-008 after freshness reason is independent' {
        $afterFreshResult = Add-CalibrationObservation -SourceRoot $phase9Root -Path (Join-Path $phase9Root 'f008-after-freshness.jsonl') -LineSlug 'line-a' -DispatchSlug 'phase9-f008-after-freshness' -Profile 'default' -Model 'fixture-model' -ReasoningEffort 'high' -TaskType 'script-change' -SessionMode 'cold-start' -Usage ([pscustomobject]@{ input_tokens = 1; output_tokens = 1 }) -ExecutionResult $calibrationExecution -QuotaBeforePath $calibrationBeforePath -QuotaAfterPath $calibrationStaleAfterPath -ScopePlan $calibrationScopePlan -BeforeSnapshotFreshAtStart $true -BeforeSnapshotCapturedAtStartUtc ([DateTimeOffset]::UtcNow.ToString('o'))
        $afterReasons = @($afterFreshResult.ineligibleReasons)
        Assert-True (-not $afterFreshResult.calibrationEligible -and [bool]$afterFreshResult.calibrationChecks.before_fresh_at_start -and -not $afterFreshResult.calibrationChecks.after_fresh_at_inspect) 'after freshness negative case 未維持獨立 check。'
        Assert-True ($afterReasons -contains 'after_fresh_at_inspect' -and $afterReasons -notcontains 'before_fresh_at_start') ('after freshness reason 不精確：' + ($afterReasons -join ', '))
        $script:phase9F008AfterEvidence = $afterFreshResult
    }

    Invoke-Case 'Phase 9 F-008 reverse removal of each freshness reason fails' {
        $calibrationDefinition = $calibrationFunctionAst[0].Extent.Text
        $mutantBeforeDefinition = $calibrationDefinition.Replace('function Add-CalibrationObservation', 'function Invoke-Phase9MutantBeforeCalibration') -replace "'before_fresh_at_start',\s*'after_fresh_at_inspect',", "'after_fresh_at_inspect',"
        $mutantAfterDefinition = $calibrationDefinition.Replace('function Add-CalibrationObservation', 'function Invoke-Phase9MutantAfterCalibration') -replace "'before_fresh_at_start',\s*'after_fresh_at_inspect',", "'before_fresh_at_start',"
        Assert-True ($mutantBeforeDefinition -notmatch "'before_fresh_at_start',\s*'after_fresh_at_inspect',") 'F-008 before mutant 未移除 reason。'
        Assert-True ($mutantAfterDefinition -notmatch "'before_fresh_at_start',\s*'after_fresh_at_inspect',") 'F-008 after mutant 未移除 reason。'
        Set-Item -Path Function:\Invoke-Phase9MutantBeforeCalibration -Value ([scriptblock]::Create($mutantBeforeDefinition))
        Set-Item -Path Function:\Invoke-Phase9MutantAfterCalibration -Value ([scriptblock]::Create($mutantAfterDefinition))
        $beforeReverseFailure = $null
        try {
            $mutantBeforeResult = Invoke-Phase9MutantBeforeCalibration -SourceRoot $phase9Root -Path (Join-Path $phase9Root 'f008-before-mutant.jsonl') -LineSlug 'line-a' -DispatchSlug 'phase9-f008-before-mutant' -Profile 'default' -Model 'fixture-model' -ReasoningEffort 'high' -TaskType 'script-change' -SessionMode 'cold-start' -Usage ([pscustomobject]@{ input_tokens = 1; output_tokens = 1 }) -ExecutionResult $calibrationExecution -QuotaBeforePath $calibrationBeforePath -QuotaAfterPath $calibrationAfterPath -ScopePlan $calibrationScopePlan -BeforeSnapshotFreshAtStart $false -BeforeSnapshotCapturedAtStartUtc ([DateTimeOffset]::UtcNow.AddMinutes(-31).ToString('o'))
            Assert-True (@($mutantBeforeResult.ineligibleReasons) -contains 'before_fresh_at_start') '移除 before_fresh_at_start reason 後仍錯誤通過。'
        }
        catch {
            $beforeReverseFailure = $_.Exception.Message
        }
        $afterReverseFailure = $null
        try {
            $mutantAfterResult = Invoke-Phase9MutantAfterCalibration -SourceRoot $phase9Root -Path (Join-Path $phase9Root 'f008-after-mutant.jsonl') -LineSlug 'line-a' -DispatchSlug 'phase9-f008-after-mutant' -Profile 'default' -Model 'fixture-model' -ReasoningEffort 'high' -TaskType 'script-change' -SessionMode 'cold-start' -Usage ([pscustomobject]@{ input_tokens = 1; output_tokens = 1 }) -ExecutionResult $calibrationExecution -QuotaBeforePath $calibrationBeforePath -QuotaAfterPath $calibrationStaleAfterPath -ScopePlan $calibrationScopePlan -BeforeSnapshotFreshAtStart $true -BeforeSnapshotCapturedAtStartUtc ([DateTimeOffset]::UtcNow.ToString('o'))
            Assert-True (@($mutantAfterResult.ineligibleReasons) -contains 'after_fresh_at_inspect') '移除 after_fresh_at_inspect reason 後仍錯誤通過。'
        }
        catch {
            $afterReverseFailure = $_.Exception.Message
        }
        Assert-True (-not [string]::IsNullOrWhiteSpace($beforeReverseFailure) -and -not [string]::IsNullOrWhiteSpace($afterReverseFailure)) ('F-008 reverse 未暴露 reason 遺漏：before=' + [string]$beforeReverseFailure + '; after=' + [string]$afterReverseFailure)
        $script:phase9F008ReverseEvidence = [pscustomobject]@{ before_failure = $beforeReverseFailure; after_failure = $afterReverseFailure }
        $restoredBeforeResult = Add-CalibrationObservation -SourceRoot $phase9Root -Path (Join-Path $phase9Root 'f008-before-restored.jsonl') -LineSlug 'line-a' -DispatchSlug 'phase9-f008-before-restored' -Profile 'default' -Model 'fixture-model' -ReasoningEffort 'high' -TaskType 'script-change' -SessionMode 'cold-start' -Usage ([pscustomobject]@{ input_tokens = 1; output_tokens = 1 }) -ExecutionResult $calibrationExecution -QuotaBeforePath $calibrationBeforePath -QuotaAfterPath $calibrationAfterPath -ScopePlan $calibrationScopePlan -BeforeSnapshotFreshAtStart $false -BeforeSnapshotCapturedAtStartUtc ([DateTimeOffset]::UtcNow.AddMinutes(-31).ToString('o'))
        $restoredAfterResult = Add-CalibrationObservation -SourceRoot $phase9Root -Path (Join-Path $phase9Root 'f008-after-restored.jsonl') -LineSlug 'line-a' -DispatchSlug 'phase9-f008-after-restored' -Profile 'default' -Model 'fixture-model' -ReasoningEffort 'high' -TaskType 'script-change' -SessionMode 'cold-start' -Usage ([pscustomobject]@{ input_tokens = 1; output_tokens = 1 }) -ExecutionResult $calibrationExecution -QuotaBeforePath $calibrationBeforePath -QuotaAfterPath $calibrationStaleAfterPath -ScopePlan $calibrationScopePlan -BeforeSnapshotFreshAtStart $true -BeforeSnapshotCapturedAtStartUtc ([DateTimeOffset]::UtcNow.ToString('o'))
        Assert-True (@($restoredBeforeResult.ineligibleReasons) -contains 'before_fresh_at_start' -and @($restoredBeforeResult.ineligibleReasons) -notcontains 'after_fresh_at_inspect' -and @($restoredAfterResult.ineligibleReasons) -contains 'after_fresh_at_inspect' -and @($restoredAfterResult.ineligibleReasons) -notcontains 'before_fresh_at_start') ('F-008 reverse 後還原 production freshness reasons 不正確：before=' + (($restoredBeforeResult.ineligibleReasons) -join ',') + '; after=' + (($restoredAfterResult.ineligibleReasons) -join ','))
        Write-Phase9Evidence -Label 'F008_NORMAL_PASS' -Value ([ordered]@{ before = $script:phase9F008BeforeEvidence; after = $script:phase9F008AfterEvidence })
        Write-Phase9Evidence -Label 'F008_PRE_FIX_FAILURE' -Value ([ordered]@{
                before = [ordered]@{ expected = 'ineligibleReasons contains before_fresh_at_start'; actual = $mutantBeforeResult; failure = $beforeReverseFailure; result = 'FAIL' }
                after = [ordered]@{ expected = 'ineligibleReasons contains after_fresh_at_inspect'; actual = $mutantAfterResult; failure = $afterReverseFailure; result = 'FAIL' }
                mutation = 'Each freshness reason was removed from the Add-CalibrationObservation mutant before the reverse invocation.'
            })
        Write-Phase9Evidence -Label 'F008_REVERSE_FAILURE' -Value $script:phase9F008ReverseEvidence
        Write-Phase9Evidence -Label 'F008_RESTORED_PASS' -Value ([ordered]@{ before = $restoredBeforeResult; after = $restoredAfterResult })
    }

    function Set-Phase9DispatchInspectFixture {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [int]$SidecarExitCode
        )

        $historyPath = Join-Path $fixtureRoot '.local\ai-sessions\history'
        $preparePath = Join-Path $historyPath 'sidecar-prepare.json'
        $startPath = Join-Path $historyPath 'sidecar-start.json'
        $sidecarPath = Join-Path $historyPath 'codex-exit-sidecar.json'
        $resultPath = Join-Path $historyPath 'dispatch-result-sidecar.json'
        $scopePath = $a.scope_plan_path
        $capturedAt = [DateTimeOffset]::UtcNow.ToString('o')

        foreach ($propertyName in @('prepare_result_path', 'prepare_result_sha256', 'prepare_status', 'quota_before_captured_at_utc', 'quota_before_freshness', 'process_exit_code_sidecar_path')) {
            if ($null -eq $a.PSObject.Properties[$propertyName]) {
                $a | Add-Member -MemberType NoteProperty -Name $propertyName -Value $null
            }
        }

        Write-Utf8NoBom -Path $scopePath -Content (($calibrationScopePlan | ConvertTo-Json -Depth 20) + "`n")
        Write-Utf8NoBom -Path $preparePath -Content (([ordered]@{ operation = 'Prepare'; status = 'completed' } | ConvertTo-Json -Depth 10) + "`n")
        Write-Utf8NoBom -Path $startPath -Content (([ordered]@{ operation = 'Start'; status = 'started'; process_started = $true } | ConvertTo-Json -Depth 10) + "`n")
        Write-TestEvents -Path $a.event_stream_path -Thread $a.thread_id
        Write-Utf8NoBom -Path $a.last_message_path -Content 'design.md dispatch-a line-a'
        Write-Utf8NoBom -Path $sidecarPath -Content (([ordered]@{
                    schema = 'ai-sessions.dispatch-exit.v1'
                    line_slug = 'line-a'
                    dispatch_slug = 'dispatch-a'
                    run_id = $a.run_id
                    process_exit_code = $SidecarExitCode
                    exit_code_status = 'known'
                } | ConvertTo-Json -Depth 10) + "`n")
        $codexHome = Join-Path $fixtureRoot 'sidecar-codex-home'
        $rolloutDirectory = Join-Path $codexHome 'sessions\sidecar'
        $rolloutPath = Join-Path $rolloutDirectory 'rollout-sidecar.jsonl'
        New-Item -ItemType Directory -Path $rolloutDirectory -Force | Out-Null
        $rolloutLines = @(
            ([ordered]@{
                    type = 'session_meta'
                    payload = [ordered]@{ session_id = $a.thread_id }
                } | ConvertTo-Json -Compress -Depth 10)
            ([ordered]@{
                    type = 'turn_context'
                    timestamp = [DateTime]::UtcNow.ToString('o')
                    payload = [ordered]@{ model = 'fixture-model'; effort = 'high' }
                } | ConvertTo-Json -Compress -Depth 10)
        )
        Write-Utf8NoBom -Path $rolloutPath -Content (($rolloutLines -join "`n") + "`n")
        $a.codex_home = $codexHome

        $a.scope_plan_sha256 = Get-FileSha256 -Path $scopePath
        $a.prepare_result_path = $preparePath
        $a.prepare_result_sha256 = Get-FileSha256 -Path $preparePath
        $a.prepare_status = 'completed'
        $a.quota_before_path = $calibrationBeforePath
        $a.quota_before_sha256 = Get-FileSha256 -Path $calibrationBeforePath
        $a.quota_before_captured_at_utc = $capturedAt
        $a.quota_before_freshness = 'fresh'
        if ($null -eq $a.PSObject.Properties['process_exit_code_sidecar_path']) {
            $a | Add-Member -MemberType NoteProperty -Name 'process_exit_code_sidecar_path' -Value $sidecarPath
        }
        else {
            $a.process_exit_code_sidecar_path = $sidecarPath
        }
        $null = Write-DispatchRunRecord -Record $a -Update

        $dispatchResult = [ordered]@{
            schema = 'ai-sessions.dispatch-result.v1'
            operation = 'Dispatch'
            status = 'started'
            line_slug = 'line-a'
            dispatch_slug = 'dispatch-a'
            completed_stages = @('preflight', 'before-snapshot', 'prepare', 'start')
            failed_stage = $null
            error_code = $null
            process_started = $true
            preflight_result_path = $a.preflight_result_path
            preflight_result_sha256 = Get-FileSha256 -Path $a.preflight_result_path
            prepare_result_path = $preparePath
            prepare_result_sha256 = Get-FileSha256 -Path $preparePath
            quota_before_path = $calibrationBeforePath
            quota_before_sha256 = Get-FileSha256 -Path $calibrationBeforePath
            start_result_path = $startPath
            inspect_binding = [ordered]@{
                run_record_path = $aPath
                event_stream_path = $a.event_stream_path
                scope_plan_path = $scopePath
                quota_before_path = $calibrationBeforePath
                process_exit_code_sidecar_path = $sidecarPath
                process_exit_code = $null
                process_exit_code_source = 'sidecar-pending'
                sidecar_sha256 = $null
            }
            stage_results = [ordered]@{
                preflight = [ordered]@{ path = $a.preflight_result_path; sha256 = (Get-FileSha256 -Path $a.preflight_result_path); status = 'completed' }
                prepare = [ordered]@{ path = $preparePath; sha256 = (Get-FileSha256 -Path $preparePath); status = 'completed' }
                start = [ordered]@{ path = $startPath; sha256 = (Get-FileSha256 -Path $startPath); status = 'started' }
            }
            result_path = $resultPath
        }
        $written = Write-DispatchAtomicJsonDocument -Path $resultPath -Document $dispatchResult -SourceRoot $fixtureRoot -ExecutionRoot $fixtureRoot -TargetPath @()
        return [pscustomobject]@{
            ResultPath = $written.Path
            SidecarPath = $sidecarPath
            CalibrationPath = (Join-Path $phase9Root '.local\ai-sessions\history\sidecar-calibration.jsonl')
        }
    }

    function Set-Phase9DispatchInspectContext {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [int]$SidecarExitCode,

            [switch]$ExplicitProcessExitCode
        )

        $fixture = Set-Phase9DispatchInspectFixture -SidecarExitCode $SidecarExitCode
        $script:SourceRoot = $fixtureRoot
        $script:ExecutionRoot = $fixtureRoot
        $script:LineSlug = 'line-a'
        $script:DispatchSlug = 'dispatch-a'
        $script:DispatchResultPath = $fixture.ResultPath
        $script:EventStreamPath = $null
        $script:RunRecordPath = $null
        $script:ScopePlanPath = $null
        $script:QuotaBeforePath = $null
        $script:QuotaAfterPath = $calibrationAfterPath
        $script:CalibrationPath = $fixture.CalibrationPath
        $script:RequiredIdentifier = 'design.md'
        $script:ErrorStreamPath = $null
        $script:LastMessagePath = $null
        $script:ThreadIdPath = $null
        $script:EvidencePackPath = $null
        $script:BudgetMonitorPath = $null
        $script:AdvisorConsultReportPath = $null
        $script:Profile = 'default'
        $script:Model = 'fixture-model'
        $script:ReasoningEffort = 'high'
        $script:TaskType = 'script-change'
        $script:SessionMode = 'cold-start'
        $script:InvocationBoundParameters = [ordered]@{}
        if ($ExplicitProcessExitCode) {
            $script:ProcessExitCode = $SidecarExitCode + 1
            $script:InvocationBoundParameters['ProcessExitCode'] = $script:ProcessExitCode
        }
        else {
            $script:ProcessExitCode = $null
        }
        return $fixture
    }

    Invoke-Case 'Phase 9 F-001 Inspect pending ACL evidence cannot allow continuation' {
        $fixture = Set-Phase9DispatchInspectContext -SidecarExitCode 0
        $inspectRecord = Read-DispatchRunRecord -Path $aPath @binding
        $inspectRecord.sandbox_acl_baseline = [ordered]@{
            status = 'known'
            path = $fixtureRoot
            fingerprint = Get-JsonSha256 -Value @()
            entries = @()
            explicit_entries = @()
            captured_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            error = $null
        }
        $inspectRecord.sandbox_acl_evidence = [ordered]@{
            capture_status = 'pending'
            entries = @()
            captured_at_utc = $null
            fingerprint = $null
            error = $null
            normal_completion = $false
            continuation_allowed = $false
        }
        $null = Write-DispatchRunRecord -Record $inspectRecord -Update
        $null = Invoke-Inspect
        $afterRecord = Read-DispatchRunRecord -Path $aPath @binding
        $afterEvidence = Get-DispatchJsonProperty -Object $afterRecord -Name 'sandbox_acl_evidence'
        Assert-True ([string](Get-DispatchJsonProperty -Object $afterEvidence -Name 'capture_status') -eq 'no_match' -and -not [bool](Get-DispatchJsonProperty -Object $afterEvidence -Name 'continuation_allowed')) ('Inspect 將 pending evidence 標記為可續行：' + ($afterEvidence | ConvertTo-Json -Depth 20 -Compress))
        $script:phase9AclMode = 'sandbox'
        $gate = Invoke-Phase9ProductionAclGate -SourceRoot $phase9AclSourceRoot -ExecutionRoot $phase9AclExecutionRoot -WriteMode 'write' -ContinuationRecord $afterRecord
        Assert-True ($gate.status -eq 'continuation-denied' -and $gate.rejection_code -eq 'WorktreeAclContinuationDenied' -and @($gate.accepted_sandbox_entries).Count -eq 0) ('pending/no_match evidence 被 ACL gate 當成 whitelist：' + ($gate | ConvertTo-Json -Depth 20 -Compress))
    }

    Invoke-Case 'Phase 9 F-004 real Inspect forwards Start before freshness to calibration' {
        $fixture = Set-Phase9DispatchInspectContext -SidecarExitCode 0
        $oldCapturedAt = [DateTimeOffset]::UtcNow.AddMinutes(-31).ToString('o')
        $beforeSnapshot = ConvertFrom-DispatchJson -Content (Get-Content -LiteralPath $calibrationBeforePath -Raw -Encoding UTF8)
        $beforeSnapshot.captured_at_utc = $oldCapturedAt
        foreach ($windowName in @('primary', 'secondary')) {
            $observation = Get-DispatchJsonProperty -Object $beforeSnapshot.observations -Name $windowName
            $observation.observed_at_utc = $oldCapturedAt
        }
        Write-Utf8NoBom -Path $calibrationBeforePath -Content (($beforeSnapshot | ConvertTo-Json -Depth 20) + "`n")
        $inspectRecord = Read-DispatchRunRecord -Path $aPath @binding
        $inspectRecord.quota_before_sha256 = Get-FileSha256 -Path $calibrationBeforePath
        $inspectRecord.quota_before_captured_at_utc = $oldCapturedAt
        $inspectRecord.quota_before_freshness = 'fresh'
        $null = Write-DispatchRunRecord -Record $inspectRecord -Update

        $fixtureCalibrationFunction = (Get-Command -Name Add-CalibrationObservation -CommandType Function -ErrorAction Stop).ScriptBlock
        Set-Item -Path Function:\Add-CalibrationObservation -Value $phase9ProductionFunctionDefinitions['Add-CalibrationObservation']
        try {
            $inspectResult = Invoke-Inspect
        }
        finally {
            Set-Item -Path Function:\Add-CalibrationObservation -Value $fixtureCalibrationFunction
            $null = New-Phase8QuotaSnapshot -Path $calibrationBeforePath -PrimaryRemainingPercent 80
        }
        $calibrationResult = $inspectResult.calibration
        Assert-True ([bool]$calibrationResult.calibrationEligible -and [bool]$calibrationResult.calibrationChecks.before_fresh_at_start -and [bool]$calibrationResult.calibrationChecks.snapshots_fresh) ('real Inspect 未使用 Start 保存的 before freshness：' + ($calibrationResult | ConvertTo-Json -Depth 30 -Compress))
    }

    function Invoke-Phase9AtomicRaceRound {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [scriptblock]$Writer,

            [Parameter(Mandatory)]
            [string]$SourceRoot,

            [Parameter(Mandatory)]
            [string]$ResultPath,

            [Parameter(Mandatory)]
            [psobject]$FirstDocument,

            [Parameter(Mandatory)]
            [string]$ExpectedSha256,

            [Parameter(Mandatory)]
            [string]$SecondDocumentPath,

            [Parameter(Mandatory)]
            [string]$WorkerPath,

            [Parameter(Mandatory)]
            [string]$Label
        )

        $readyPath = Join-Path $phase9Root ('atomic-' + $Label + '-ready.txt')
        $acquiredPath = Join-Path $phase9Root ('atomic-' + $Label + '-acquired.txt')
        $readPath = Join-Path $phase9Root ('atomic-' + $Label + '-read.txt')
        $outcomePath = Join-Path $phase9Root ('atomic-' + $Label + '-outcome.json')
        $script:phase9AtomicSourceRoot = $SourceRoot
        $script:phase9AtomicResultPath = $ResultPath
        $script:phase9AtomicExpectedSha256 = $ExpectedSha256
        $script:phase9AtomicSecondDocumentPath = $SecondDocumentPath
        $script:phase9AtomicWorkerPath = $WorkerPath
        $script:phase9AtomicReadyPath = $readyPath
        $script:phase9AtomicAcquiredPath = $acquiredPath
        $script:phase9AtomicReadPath = $readPath
        $script:phase9AtomicOutcomePath = $outcomePath
        $script:phase9AtomicSecondProcess = $null
        $script:phase9AtomicWaitForWorkerAcquired = $Label -eq 'reverse'
        $script:phase9AtomicWaitForWorkerRead = $Label -eq 'reverse'
        $script:phase9AtomicAfterCasHook = {
            $workerArguments = @(
                '-NoProfile'
                '-File'
                $script:phase9AtomicWorkerPath
                '-ResultPath'
                $script:phase9AtomicResultPath
                '-ExpectedSha256'
                $script:phase9AtomicExpectedSha256
                '-DocumentPath'
                $script:phase9AtomicSecondDocumentPath
                '-ReadyPath'
                $script:phase9AtomicReadyPath
                '-AcquiredPath'
                $script:phase9AtomicAcquiredPath
                '-ReadPath'
                $script:phase9AtomicReadPath
                '-OutcomePath'
                $script:phase9AtomicOutcomePath
            )
            $workerArgumentText = ($workerArguments | ForEach-Object { ConvertTo-ProcessArgument -Value ([string]$_) }) -join ' '
            $secondProcess = New-Object System.Diagnostics.Process
            $secondStartInfo = New-Object System.Diagnostics.ProcessStartInfo
            $secondStartInfo.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
            $secondStartInfo.Arguments = $workerArgumentText
            $secondStartInfo.WorkingDirectory = $root
            $secondStartInfo.UseShellExecute = $false
            $secondStartInfo.CreateNoWindow = $true
            $secondProcess.StartInfo = $secondStartInfo
            $script:phase9AtomicSecondProcess = $secondProcess
            if (-not $secondProcess.Start()) {
                throw 'cooperative second writer Process.Start() 回傳 false。'
            }
            $readyDeadline = [DateTime]::UtcNow.AddSeconds(5)
            while (-not (Test-Path -LiteralPath $script:phase9AtomicReadyPath -PathType Leaf) -and [DateTime]::UtcNow -lt $readyDeadline) {
                Start-Sleep -Milliseconds 25
            }
            if (-not (Test-Path -LiteralPath $script:phase9AtomicReadyPath -PathType Leaf)) {
                throw 'cooperative second writer 未抵達 lock 等待點。'
            }
            if ($script:phase9AtomicWaitForWorkerAcquired) {
                $acquiredDeadline = [DateTime]::UtcNow.AddSeconds(5)
                while (-not (Test-Path -LiteralPath $script:phase9AtomicAcquiredPath -PathType Leaf) -and [DateTime]::UtcNow -lt $acquiredDeadline) {
                    Start-Sleep -Milliseconds 25
                }
                if (-not (Test-Path -LiteralPath $script:phase9AtomicAcquiredPath -PathType Leaf)) {
                    throw 'cooperative second writer 未取得 shared lock。'
                }
            }
            if ($script:phase9AtomicWaitForWorkerRead) {
                $readDeadline = [DateTime]::UtcNow.AddSeconds(5)
                while (-not (Test-Path -LiteralPath $script:phase9AtomicReadPath -PathType Leaf) -and [DateTime]::UtcNow -lt $readDeadline) {
                    Start-Sleep -Milliseconds 25
                }
                if (-not (Test-Path -LiteralPath $script:phase9AtomicReadPath -PathType Leaf)) {
                    throw 'cooperative second writer 未回報已重讀結果檔。'
                }
            }
        }
        $writerOutput = $null
        $writerError = $null
        try {
            $writerOutput = & $Writer -Path $ResultPath -Document $FirstDocument -SourceRoot $SourceRoot -ExecutionRoot $SourceRoot -TargetPath @() -ExpectedExistingSha256 $ExpectedSha256
        }
        catch {
            $writerError = $_.Exception.Message
        }
        finally {
            $script:phase9AtomicAfterCasHook = $null
            $script:phase9AtomicWaitForWorkerAcquired = $false
            $script:phase9AtomicWaitForWorkerRead = $false
            if ($null -ne $script:phase9AtomicSecondProcess) {
                $null = $script:phase9AtomicSecondProcess.WaitForExit(10000)
            }
        }
        $workerExitCode = $null
        if ($null -ne $script:phase9AtomicSecondProcess) {
            $workerExitCode = $script:phase9AtomicSecondProcess.ExitCode
            $script:phase9AtomicSecondProcess.Dispose()
        }
        $workerOutcome = $null
        if (Test-Path -LiteralPath $outcomePath -PathType Leaf) {
            $workerOutcome = Get-Content -LiteralPath $outcomePath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        $finalDocument = if (Test-Path -LiteralPath $ResultPath -PathType Leaf) { Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
        return [pscustomobject]@{
            label = $Label
            result_path = $ResultPath
            expected_sha256 = $ExpectedSha256
            writer_output = $writerOutput
            writer_error = $writerError
            worker_exit_code = $workerExitCode
            worker_outcome = $workerOutcome
            final_document = $finalDocument
            ready_path = $readyPath
            acquired_path = $acquiredPath
            read_path = $readPath
            outcome_path = $outcomePath
        }
    }

    Invoke-Case 'Phase 9 F-006 cooperative result writer lock rejects stale replacement' {
        $workerPath = Join-Path $phase9Root 'atomic-cooperative-writer.ps1'
        $workerScript = @'
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResultPath,
    [Parameter(Mandatory)][string]$ExpectedSha256,
    [Parameter(Mandatory)][string]$DocumentPath,
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$AcquiredPath,
    [Parameter(Mandatory)][string]$ReadPath,
    [Parameter(Mandatory)][string]$OutcomePath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$normalizedResultPath = [IO.Path]::GetFullPath($ResultPath)
if ([IO.Path]::DirectorySeparatorChar -eq '\') {
    $normalizedResultPath = $normalizedResultPath.ToUpperInvariant()
}
$lockSha256 = [Security.Cryptography.SHA256]::Create()
try {
    $lockIdentity = ([BitConverter]::ToString(
            $lockSha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalizedResultPath)))).Replace('-', '').ToLowerInvariant()
}
finally {
    $lockSha256.Dispose()
}
$lockRoot = Join-Path ([IO.Path]::GetTempPath()) 'codex-dispatch-result-locks'
New-Item -ItemType Directory -Path $lockRoot -Force | Out-Null
$lockPath = Join-Path $lockRoot ('.dispatch-' + $lockIdentity + '.lock')
$lock = $null
$temporaryPath = $null
function Get-Phase9FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path)))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}
try {
    [IO.File]::WriteAllText($ReadyPath, 'ready', $utf8)
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ($null -eq $lock -and [DateTime]::UtcNow -lt $deadline) {
        try {
            $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch [IO.IOException] {
            Start-Sleep -Milliseconds 25
        }
    }
    if ($null -eq $lock) {
        throw 'cooperative second writer lock timeout'
    }
    [IO.File]::WriteAllText($AcquiredPath, 'acquired', $utf8)
    $actualSha256 = Get-Phase9FileSha256 -Path $ResultPath
    [IO.File]::WriteAllText($ReadPath, 'read', $utf8)
    if (-not [string]::Equals($ExpectedSha256, $actualSha256, [StringComparison]::OrdinalIgnoreCase)) {
        [IO.File]::WriteAllText($OutcomePath, (([ordered]@{ status = 'conflict'; expected_sha256 = $ExpectedSha256; actual_sha256 = $actualSha256; path = $ResultPath } | ConvertTo-Json -Compress) + "`n"), $utf8)
        exit 2
    }
    $document = [IO.File]::ReadAllText($DocumentPath, $utf8) | ConvertFrom-Json
    $temporaryPath = Join-Path (Split-Path -Parent $ResultPath) ([guid]::NewGuid().ToString('D') + '.cooperative.tmp')
    [IO.File]::WriteAllText($temporaryPath, (($document | ConvertTo-Json -Depth 40) + "`n"), $utf8)
    if ([IO.File]::Exists($ResultPath)) {
        [IO.File]::Replace($temporaryPath, $ResultPath, [Management.Automation.Language.NullString]::Value)
    }
    else {
        [IO.File]::Move($temporaryPath, $ResultPath)
    }
    [IO.File]::WriteAllText($OutcomePath, (([ordered]@{ status = 'committed'; path = $ResultPath } | ConvertTo-Json -Compress) + "`n"), $utf8)
    exit 0
}
catch {
    [IO.File]::WriteAllText($OutcomePath, (([ordered]@{ status = 'error'; error = $_.Exception.Message; path = $ResultPath } | ConvertTo-Json -Compress) + "`n"), $utf8)
    exit 1
}
finally {
    if ($null -ne $temporaryPath -and [IO.File]::Exists($temporaryPath)) {
        [IO.File]::Delete($temporaryPath)
    }
    if ($null -ne $lock) {
        $lock.Dispose()
    }
}
'@
        Write-Utf8NoBom -Path $workerPath -Content $workerScript
        $resultPath = Join-Path $phase9Root '.local\ai-sessions\history\f006-cooperative-result.json'
        $baseDocument = [ordered]@{ schema = 'fixture.dispatch-result.v1'; version = 'base'; marker = 'initial-result' }
        $firstDocument = [ordered]@{ schema = 'fixture.dispatch-result.v1'; version = 'first'; marker = 'first-writer' }
        $secondDocument = [ordered]@{ schema = 'fixture.dispatch-result.v1'; version = 'second'; marker = 'second-writer' }
        $secondDocumentPath = Join-Path $phase9Root 'f006-second-document.json'
        Write-Utf8NoBom -Path $secondDocumentPath -Content (($secondDocument | ConvertTo-Json -Depth 20) + "`n")
        $null = Invoke-Phase9ProductionAtomicWriter -Path $resultPath -Document $baseDocument -SourceRoot $phase9Root -ExecutionRoot $phase9Root -TargetPath @()
        $expectedSha256 = Get-FileSha256 -Path $resultPath
        $productionWriter = (Get-Command -Name Invoke-Phase9ProductionAtomicWriter -CommandType Function -ErrorAction Stop).ScriptBlock
        $normalRound = Invoke-Phase9AtomicRaceRound -Writer $productionWriter -SourceRoot $phase9Root -ResultPath $resultPath -FirstDocument $firstDocument -ExpectedSha256 $expectedSha256 -SecondDocumentPath $secondDocumentPath -WorkerPath $workerPath -Label 'normal'
        Assert-True ($null -eq $normalRound.writer_error -and $normalRound.worker_exit_code -eq 2 -and $normalRound.worker_outcome.status -eq 'conflict') ('cooperative writer 未在 lock 內觀測衝突：' + ($normalRound | ConvertTo-Json -Depth 20 -Compress))
        Assert-True ($normalRound.final_document.version -eq 'first' -and $normalRound.final_document.marker -eq 'first-writer') ('cooperative writer 改寫了第一 writer 的結果：' + ($normalRound.final_document | ConvertTo-Json -Depth 20 -Compress))

        $null = Invoke-Phase9ProductionAtomicWriter -Path $resultPath -Document $baseDocument -SourceRoot $phase9Root -ExecutionRoot $phase9Root -TargetPath @()
        $reverseExpectedSha256 = Get-FileSha256 -Path $resultPath
        $mutantWriter = (Get-Command -Name Invoke-Phase9MutantAtomicWriter -CommandType Function -ErrorAction Stop).ScriptBlock
        $reverseRound = Invoke-Phase9AtomicRaceRound -Writer $mutantWriter -SourceRoot $phase9Root -ResultPath $resultPath -FirstDocument $firstDocument -ExpectedSha256 $reverseExpectedSha256 -SecondDocumentPath $secondDocumentPath -WorkerPath $workerPath -Label 'reverse'
        $reverseValidationFailure = $null
        try {
            Assert-True ($reverseRound.worker_exit_code -eq 2 -and $reverseRound.worker_outcome.status -eq 'conflict') '移除 shared lock 後仍錯誤宣稱 cooperative conflict。'
        }
        catch {
            $reverseValidationFailure = $_.Exception.Message
        }
        Assert-True ($null -ne $reverseValidationFailure -and $reverseRound.worker_outcome.status -eq 'committed') ('移除 shared lock 的 reverse 未暴露 stale overwrite：' + ($reverseRound | ConvertTo-Json -Depth 20 -Compress))

        $null = Invoke-Phase9ProductionAtomicWriter -Path $resultPath -Document $baseDocument -SourceRoot $phase9Root -ExecutionRoot $phase9Root -TargetPath @()
        $restoredExpectedSha256 = Get-FileSha256 -Path $resultPath
        $restoredRound = Invoke-Phase9AtomicRaceRound -Writer $productionWriter -SourceRoot $phase9Root -ResultPath $resultPath -FirstDocument $firstDocument -ExpectedSha256 $restoredExpectedSha256 -SecondDocumentPath $secondDocumentPath -WorkerPath $workerPath -Label 'restored'
        Assert-True ($null -eq $restoredRound.writer_error -and $restoredRound.worker_exit_code -eq 2 -and $restoredRound.worker_outcome.status -eq 'conflict') ('還原 shared lock 後未恢復衝突拒絕：' + ($restoredRound | ConvertTo-Json -Depth 20 -Compress))
        $script:phase9F006RaceEvidence = [pscustomobject]@{ normal = $normalRound; reverse = $reverseRound; reverse_validation_failure = $reverseValidationFailure; restored = $restoredRound }
        Write-Phase9Evidence -Label 'F006_NORMAL_PASS' -Value $normalRound
        Write-Phase9Evidence -Label 'F006_REVERSE_FAILURE' -Value ([ordered]@{ status = 'failed'; validation_failure = $reverseValidationFailure; round = $reverseRound })
        Write-Phase9Evidence -Label 'F006_RESTORED_PASS' -Value $restoredRound
    }

    function Align-Phase9CalibrationResetWindow {
        $beforeSnapshot = Get-Content -LiteralPath $calibrationBeforePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $afterSnapshot = Get-Content -LiteralPath $calibrationAfterPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($windowName in @('primary', 'secondary')) {
            $resetAt = [int64](Get-DispatchJsonProperty -Object (Get-DispatchJsonProperty -Object $afterSnapshot -Name $windowName) -Name 'resets_at')
            (Get-DispatchJsonProperty -Object $beforeSnapshot -Name $windowName).resets_at = $resetAt
            (Get-DispatchJsonProperty -Object (Get-DispatchJsonProperty -Object $beforeSnapshot -Name 'values') -Name $windowName).resets_at = $resetAt
            (Get-DispatchJsonProperty -Object (Get-DispatchJsonProperty -Object $beforeSnapshot -Name 'observations') -Name $windowName).resets_at = $resetAt
        }
        Write-Utf8NoBom -Path $calibrationBeforePath -Content (($beforeSnapshot | ConvertTo-Json -Depth 20) + "`n")
    }

    Invoke-Case 'Phase 9 P3 Dispatch exit sidecar supplies ProcessExitCode' {
        Align-Phase9CalibrationResetWindow
        $fixture = Set-Phase9DispatchInspectContext -SidecarExitCode 0
        $inspectResult = Invoke-Inspect
        $dispatchDocument = Get-Content -LiteralPath $fixture.ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($inspectResult.success -and $inspectResult.processExitCode -eq 0 -and $inspectResult.dispatchResultPath -eq $fixture.ResultPath) 'sidecar 未提供有效的 ProcessExitCode 給 Inspect。'
        Assert-True ($dispatchDocument.inspect_binding.process_exit_code -eq 0 -and $dispatchDocument.inspect_binding.process_exit_code_source -eq 'sidecar' -and $dispatchDocument.inspect_binding.sidecar_sha256 -match '^[a-f0-9]{64}$') 'Inspect 未持久化 sidecar binding。'
        Assert-True ($inspectResult.calibration.calibrationEligible -and (Test-Path -LiteralPath $fixture.CalibrationPath -PathType Leaf)) ('sidecar 正常結束未產生 eligible calibration observation：' + ($inspectResult.calibration | ConvertTo-Json -Depth 20 -Compress))
    }

    Invoke-Case 'Phase 9 P3 Dispatch exit sidecar mismatch stops Inspect' {
        $fixture = Set-Phase9DispatchInspectContext -SidecarExitCode 0 -ExplicitProcessExitCode
        $beforeHash = Get-FileSha256 -Path $fixture.ResultPath
        $beforeCalibrationCount = if (Test-Path -LiteralPath $fixture.CalibrationPath -PathType Leaf) { @(Get-Content -LiteralPath $fixture.CalibrationPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count } else { 0 }
        $caught = $null
        try {
            $null = Invoke-Inspect
        }
        catch {
            $caught = $_.Exception
        }
        $operationResult = if ($null -eq $caught) { $null } else { $caught.Data['operationResult'] }
        $afterCalibrationCount = if (Test-Path -LiteralPath $fixture.CalibrationPath -PathType Leaf) { @(Get-Content -LiteralPath $fixture.CalibrationPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count } else { 0 }
        Assert-True ($null -ne $operationResult -and $operationResult.errorCode -eq 'DispatchExitCodeMismatch') 'sidecar 與顯式 ProcessExitCode 不一致未回傳結構化錯誤。'
        Assert-True ((Get-FileSha256 -Path $fixture.ResultPath) -eq $beforeHash -and $afterCalibrationCount -eq $beforeCalibrationCount) 'mismatch 不應更新 Dispatch binding 或 calibration observation。'
    }

    Invoke-Case 'Phase 9 P3 Dispatch nonzero exit sidecar is preserved' {
        $fixture = Set-Phase9DispatchInspectContext -SidecarExitCode 9
        $inspectResult = Invoke-Inspect
        $dispatchDocument = Get-Content -LiteralPath $fixture.ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True (-not $inspectResult.success -and $inspectResult.processExitCode -eq 9 -and $dispatchDocument.inspect_binding.process_exit_code -eq 9) '非零 sidecar 結束碼未保留。'
        Assert-True (-not $inspectResult.calibration.calibrationEligible -and -not $inspectResult.calibration.calibrationChecks.execution_completed) '非零 sidecar 未標記 execution_completed=false。'
    }

    Invoke-Case 'Phase 9 P3 Dispatch exit sidecar unavailable stops Inspect' {
        $fixture = Set-Phase9DispatchInspectContext -SidecarExitCode 0
        Write-Utf8NoBom -Path $fixture.SidecarPath -Content '{"schema":"ai-sessions.dispatch-exit.v1","exit_code_status":"pending"}'
        $caught = $null
        try {
            $null = Invoke-Inspect
        }
        catch {
            $caught = $_.Exception
        }
        $operationResult = if ($null -eq $caught) { $null } else { $caught.Data['operationResult'] }
        Assert-True ($null -ne $operationResult -and $operationResult.errorCode -eq 'DispatchExitCodeUnavailable') 'sidecar 缺失或未完成時未回傳 unavailable。'
    }

    Invoke-Case 'Phase 9 final git status guard detects repo-root fixture residue and restored pass' {
        $fixtureEntriesBeforeCleanup = @()
        $removedFixtureEntries = New-Object System.Collections.Generic.List[string]
        if (Test-Path -LiteralPath $sRealDispatchParent -PathType Container) {
            $fixtureEntriesBeforeCleanup = @(Get-ChildItem -LiteralPath $sRealDispatchParent -Force | Select-Object -ExpandProperty Name | Sort-Object)
            foreach ($fixtureEntry in @(Get-ChildItem -LiteralPath $sRealDispatchParent -Force)) {
                if (@($sRealDispatchParentBaselineEntries) -contains $fixtureEntry.Name) {
                    continue
                }
                Assert-True (Test-PathWithinRoot -Path $fixtureEntry.FullName -Root $sRealDispatchParent) ('Phase 9 fixture cleanup 目標超出 p9-real root：' + $fixtureEntry.FullName)
                Remove-Item -LiteralPath $fixtureEntry.FullName -Recurse -Force
                $removedFixtureEntries.Add($fixtureEntry.Name)
            }
        }
        if (-not $sRealDispatchParentExistedBefore -and (Test-Path -LiteralPath $sRealDispatchParent -PathType Container) -and @(Get-ChildItem -LiteralPath $sRealDispatchParent -Force).Count -eq 0) {
            Remove-Item -LiteralPath $sRealDispatchParent -Force
        }
        $fixtureEntriesAfterCleanup = if (Test-Path -LiteralPath $sRealDispatchParent -PathType Container) {
            @(Get-ChildItem -LiteralPath $sRealDispatchParent -Force | Select-Object -ExpandProperty Name | Sort-Object)
        }
        else {
            @()
        }
        $expectedFixtureEntriesText = @($sRealDispatchParentBaselineEntries | Sort-Object) -join "`n"
        $actualFixtureEntriesText = @($fixtureEntriesAfterCleanup) -join "`n"
        Assert-True ([string]::Equals($expectedFixtureEntriesText, $actualFixtureEntriesText, [StringComparison]::Ordinal)) ('Phase 9 fixture cleanup 未還原 p9-real baseline：before=' + ($fixtureEntriesBeforeCleanup -join ',') + '; after=' + ($fixtureEntriesAfterCleanup -join ',') + '; expected=' + ($sRealDispatchParentBaselineEntries -join ','))
        $fixtureCleanup = [ordered]@{
            result = 'PASS'
            parent = $sRealDispatchParent
            parent_existed_before = $sRealDispatchParentExistedBefore
            baseline_entries = @($sRealDispatchParentBaselineEntries | Sort-Object)
            entries_before_cleanup = $fixtureEntriesBeforeCleanup
            removed_entries = @($removedFixtureEntries.ToArray() | Sort-Object)
            entries_after_cleanup = $fixtureEntriesAfterCleanup
            parent_exists_after = Test-Path -LiteralPath $sRealDispatchParent -PathType Container
        }
        $mutantPath = Join-Path $root ('phase9-status-mutant-' + [guid]::NewGuid().ToString('N') + '.md')
        $mutantStatusBefore = Invoke-Phase9RepositoryGitCommand -RepositoryRoot $root -Arguments @('status', '--short')
        Assert-True ([string]::Equals($phase9GitStatusBefore, $mutantStatusBefore, [StringComparison]::Ordinal)) 'Phase 9 git status guard 的 mutant 起點與 Phase 9 baseline 不一致。'
        $mutantStatusAfter = $null
        $mutantFailure = $null
        try {
            Write-Utf8NoBom -Path $mutantPath -Content 'Phase 9 git status guard mutant residue.'
            $mutantStatusAfter = Invoke-Phase9RepositoryGitCommand -RepositoryRoot $root -Arguments @('status', '--short')
            try {
                $null = Assert-Phase9RepositoryGitStatusUnchanged -Before $phase9GitStatusBefore -After $mutantStatusAfter
            }
            catch {
                $mutantFailure = $_.Exception.Message
            }
            Assert-True (-not [string]::IsNullOrWhiteSpace($mutantFailure)) 'Phase 9 git status guard 未捕捉 repo-root fixture residue。'
        }
        finally {
            if (Test-Path -LiteralPath $mutantPath -PathType Leaf) {
                Remove-Item -LiteralPath $mutantPath -Force
            }
        }
        $phase9GitStatusAfter = Invoke-Phase9RepositoryGitCommand -RepositoryRoot $root -Arguments @('status', '--short')
        $restoredPass = Assert-Phase9RepositoryGitStatusUnchanged -Before $phase9GitStatusBefore -After $phase9GitStatusAfter
        Assert-True ([string]::Equals($phase9GitStatusBefore, $phase9GitStatusAfter, [StringComparison]::Ordinal)) 'Phase 9 git status guard 清理 mutant 後仍有 repo status 殘留。'
        Write-Phase9Evidence -Label 'PHASE9_GIT_STATUS_GUARD_MUTANT_FAILURE' -Value ([ordered]@{
                result = 'FAIL'
                mutation = '讓 fixture 暫時在 repo 根目錄建立未追蹤檔案。'
                mutant_path = $mutantPath
                status_before = $mutantStatusBefore
                status_after = $mutantStatusAfter
                guard_failure_output = $mutantFailure
                cleanup = 'finally 已刪除 mutant 檔案。'
                fixture_cleanup = $fixtureCleanup
            })
        Write-Phase9Evidence -Label 'PHASE9_GIT_STATUS_GUARD_RESTORED_PASS' -Value ([ordered]@{
                result = 'PASS'
                guard_result = $restoredPass
                status_before = $phase9GitStatusBefore
                status_after = $phase9GitStatusAfter
                fixture_cleanup = $fixtureCleanup
            })
        Write-Phase9Evidence -Label 'PHASE9_FIXTURE_BOUNDARY_CLEANUP' -Value $fixtureCleanup
    }
}

Write-Output "TOTAL: $script:caseCount; FAILED: $script:failures; FIXTURES: $fixtureRoot"
if ($script:failures -gt 0) { exit 1 }
exit 0
