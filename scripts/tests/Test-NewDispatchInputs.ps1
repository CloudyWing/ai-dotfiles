#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptsRoot = Split-Path -Parent $PSScriptRoot
$repositoryRoot = Split-Path -Parent $scriptsRoot
$generatorPath = Join-Path $scriptsRoot 'New-DispatchInputs.ps1'
$orderScriptPath = Join-Path $scriptsRoot 'New-DispatchOrder.ps1'
$entryPath = Join-Path $scriptsRoot 'Invoke-CodexDispatch.ps1'
. (Join-Path $scriptsRoot 'dispatch\dispatch-input-checks.ps1')
$pwshPath = (Get-Process -Id $PID).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('new-dispatch-inputs-' + [guid]::NewGuid().ToString('N'))
$codexHome = Join-Path $tempRoot 'codex-home'
$passed = 0
$failed = 0
$previousCodexHome = $env:CODEX_HOME

function Test-Case {
    param([string]$Id, [scriptblock]$Check)
    try {
        & $Check
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

function Write-TextFile {
    param([string]$Path, [string]$Content)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-FileListing {
    param([string]$Root)
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\\.git\\' } | ForEach-Object { $_.FullName } | Sort-Object)
}

function Invoke-Git {
    param([string]$Root, [string[]]$Arguments)
    $output = & git -C $Root @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('git ' + ($Arguments -join ' ') + ' 失敗：' + ($output -join "`n")) }
}

function New-Fixture {
    param([Parameter(Mandatory)][string]$Name, [ValidateSet('none', 'git', 'git-nocommit')][string]$Git = 'none')
    $root = Join-Path $tempRoot $Name
    [void][IO.Directory]::CreateDirectory($root)
    Write-TextFile -Path (Join-Path $root 'target.txt') -Content 'fixture target'
    Write-TextFile -Path (Join-Path $root '.gitignore') -Content ".local/`r`n"
    if ($Git -ne 'none') {
        Invoke-Git -Root $root -Arguments @('init', '--quiet')
        Invoke-Git -Root $root -Arguments @('config', 'user.email', 'inputs@example.invalid')
        Invoke-Git -Root $root -Arguments @('config', 'user.name', 'Inputs Fixture')
        if ($Git -eq 'git') {
            Invoke-Git -Root $root -Arguments @('add', '--', '.gitignore', 'target.txt')
            Invoke-Git -Root $root -Arguments @('commit', '--quiet', '-m', 'fixture')
        }
    }
    return $root
}

function New-AcceptanceRows {
    return @(@{ Category = '新行為'; Condition = 'fixture condition'; Command = 'Get-Date' })
}

function Get-OrderArguments {
    param([string]$Root, [string]$LineSlug, [string]$DispatchSlug, [string]$ReportPath)
    return @{
        SourceRoot   = $Root
        LineSlug     = $LineSlug
        DispatchSlug = $DispatchSlug
        TargetPath   = @(Join-Path $Root 'target.txt')
        Role         = 'Analyst'
        Title        = 'fixture title'
        TaskBody     = 'fixture task body'
        Acceptance   = (New-AcceptanceRows)
        Boundary     = 'fixture boundary'
        ReportPath   = $(if ([string]::IsNullOrWhiteSpace($ReportPath)) { Join-Path $Root ('.local\ai-sessions\report\' + $LineSlug + '\report.md') } else { $ReportPath })
    }
}

# 在目前行程內執行產生器。腳本內的 exit 只結束腳本本身，stderr 以 Console.SetError 擷取。
function Invoke-Generator {
    param([Parameter(Mandatory)][hashtable]$Arguments, [string]$ScriptPath = $generatorPath)
    $originalError = [Console]::Error
    $writer = New-Object System.IO.StringWriter
    [Console]::SetError($writer)
    $stdout = ''
    $bindingError = $null
    $exitCode = 0
    try {
        $global:LASTEXITCODE = 0
        $stdout = (@(& $ScriptPath @Arguments) | ForEach-Object { [string]$_ }) -join "`n"
        $exitCode = [int]$LASTEXITCODE
    }
    catch {
        $bindingError = $_.Exception.Message
        $exitCode = -1
    }
    finally { [Console]::SetError($originalError) }
    return [pscustomobject]@{ ExitCode = $exitCode; Stdout = $stdout; Stderr = $writer.ToString().Trim(); BindingError = $bindingError }
}

function Get-FailureCode {
    param([Parameter(Mandatory)][object]$Result)
    try { return [string](($Result.Stderr | ConvertFrom-Json -ErrorAction Stop).code) } catch { return '' }
}

function Invoke-RealValidateOnly {
    param([Parameter(Mandatory)][string]$RequestPath)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $pwshPath
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $entryPath, '-Operation', 'Dispatch', '-RequestPath', $RequestPath, '-ValidateOnly')) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdoutTask.Wait()
        $stderrTask.Wait()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdoutTask.Result; Stderr = $stderrTask.Result }
    }
    finally { $process.Dispose() }
}

function New-AdvisorEvidencePack {
    param([string]$Root, [string]$LineSlug, [string]$DispatchSlug)
    $path = Join-Path $Root ('.local\ai-sessions\handoff\' + $LineSlug + '\advisor-evidence-' + $DispatchSlug + '.md')
    $content = @('schema: advisor-consult.evidence.v1', ('line-slug: ' + $LineSlug), ('dispatch-slug: ' + $DispatchSlug), '', '## 目標段落', '', 'source: target.txt:1', 'excerpt: fixture target', '', '## 已知結論', '', 'fixture conclusion', '', '## 待答問題', '', 'question-001: fixture question', 'required-output: ## 中斷保全結論; ## 證據支持; ## 推論; ## 未決問題', 'output-rules: answer only from this evidence pack', '', '## 可能反證', '', 'fixture counterevidence', '', '## 邊界', '', '- allowed-input: this evidence pack only', '- forbidden-action: source exploration, repository scan, file mutation, external dispatch') -join "`r`n"
    Write-TextFile -Path $path -Content ($content + "`r`n")
    return $path
}

function Get-LabelValues {
    param([string]$PromptText)
    $values = [ordered]@{}
    foreach ($label in @('lineSlug', 'sourceRoot', 'dispatchRoot', 'sourceLineRoot', 'dispatchLineRoot', 'reportLineRoot')) {
        $match = [regex]::Match($PromptText, '(?im)^\s*(?:-\s*)?' + $label + '\s*[:=]\s*(?<value>[^\r\n]+)')
        $values[$label] = if ($match.Success) { $match.Groups['value'].Value.Trim() } else { $null }
    }
    return $values
}

try {
    New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
    foreach ($profileFile in @('config.toml', 'review.config.toml', 'scan.config.toml', 'content.config.toml', 'advisor.config.toml')) {
        Write-TextFile -Path (Join-Path $codexHome $profileFile) -Content ("model = `"fixture-model`"`r`nmodel_reasoning_effort = `"high`"`r`n")
    }
    $env:CODEX_HOME = $codexHome

    # 正向 1、6：五種合法組合產出的 Request 以真實入口 -ValidateOnly exit 0，stdout 為單一 JSON。
    $combinations = @(
        @{ TaskType = 'review'; Profile = 'review' }
        @{ TaskType = 'test'; Profile = 'scan' }
        @{ TaskType = 'generate'; Profile = 'content' }
        @{ TaskType = 'factcheck'; Profile = 'content' }
        @{ TaskType = 'advise'; Profile = 'advisor' }
    )
    foreach ($combination in $combinations) {
        $capturedCombination = $combination
        Test-Case ('P01 合法組合 {0}/{1} 產出的 Request 通過 -ValidateOnly' -f $combination.TaskType, $combination.Profile) {
            $name = 'combo-' + $capturedCombination.TaskType
            $root = New-Fixture -Name $name
            $arguments = Get-OrderArguments -Root $root -LineSlug 'combo-line' -DispatchSlug ('combo-' + $capturedCombination.TaskType)
            $arguments.TaskType = $capturedCombination.TaskType
            $arguments.Profile = $capturedCombination.Profile
            $arguments.SemanticLabel = 'combination fixture'
            if ($capturedCombination.TaskType -eq 'advise') {
                $arguments = @{ SourceRoot = $root; LineSlug = 'combo-line'; DispatchSlug = 'combo-advise'; TaskType = 'advise'; Profile = 'advisor'; SemanticLabel = 'combination fixture' }
                $arguments.EvidencePackPath = New-AdvisorEvidencePack -Root $root -LineSlug 'combo-line' -DispatchSlug 'combo-advise'
            }
            $result = Invoke-Generator -Arguments $arguments
            Assert-True ($result.ExitCode -eq 0) ("產生器失敗 exit=$($result.ExitCode) binding=$($result.BindingError) stderr=$($result.Stderr)")
            $document = $result.Stdout | ConvertFrom-Json -ErrorAction Stop
            Assert-True ($document.validate_only.exit_code -eq 0 -and $document.line_manifest_created -eq $true -and (Test-Path -LiteralPath $document.request_path -PathType Leaf) -and (Test-Path -LiteralPath $document.prompt_path -PathType Leaf)) ("stdout JSON 缺少必要欄位或檔案：" + $result.Stdout)
            if ($capturedCombination.TaskType -eq 'advise') {
                Assert-True ($null -eq $document.order_path) 'advise 的 order_path 應為 null'
            }
            else {
                Assert-True (Test-Path -LiteralPath $document.order_path -PathType Leaf) 'order_path 指向的派遣單不存在'
            }
            $real = Invoke-RealValidateOnly -RequestPath $document.request_path
            $realDocument = $real.Stdout | ConvertFrom-Json -ErrorAction Stop
            Assert-True ($real.ExitCode -eq 0 -and @($realDocument.findings | Where-Object { $_.severity -eq 'error' }).Count -eq 0) ("真實入口 -ValidateOnly 失敗 exit=$($real.ExitCode) stderr=$($real.Stderr) stdout=$($real.Stdout)")
            $request = Get-Content -LiteralPath $document.request_path -Raw -Encoding UTF8 | ConvertFrom-Json
            $expectedTaskType = if ($capturedCombination.TaskType -eq 'advise') { 'advisor-consult' } else { $capturedCombination.TaskType }
            Assert-True ($request.task_type -ceq $expectedTaskType -and $request.profile -ceq $capturedCombination.Profile -and $request.write_mode -ceq 'readonly' -and $request.dispatch_kind -ceq 'resource' -and $request.session_mode -ceq 'cold-start') 'Request 固定欄位不符'
        }
    }

    # 正向 2：line.json 建立與沿用。
    Test-Case 'P02 line.json 不存在時建立且欄位齊備，已存在時雜湊不變' {
        $root = New-Fixture -Name 'line-manifest'
        $arguments = Get-OrderArguments -Root $root -LineSlug 'manifest-line' -DispatchSlug 'manifest-a'
        $arguments.TaskType = 'generate'; $arguments.Profile = 'content'; $arguments.SemanticLabel = '清單測試'; $arguments.LineKind = 'adhoc'
        $first = Invoke-Generator -Arguments $arguments
        Assert-True ($first.ExitCode -eq 0) ("第一次產生失敗：$($first.Stderr) $($first.BindingError)")
        $manifestPath = Join-Path $root '.local\ai-sessions\handoff\manifest-line\line.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($manifest.schema -ceq 'ai-sessions.line.v1' -and $manifest.'line-slug' -ceq 'manifest-line' -and $manifest.'semantic-label' -ceq '清單測試' -and $manifest.kind -ceq 'adhoc' -and -not [string]::IsNullOrWhiteSpace([string]$manifest.'created-at-utc')) 'line.json 欄位不齊備'
        $bytes = [IO.File]::ReadAllBytes($manifestPath)
        Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF)) 'line.json 不應含 BOM'
        $hashBefore = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        $arguments.DispatchSlug = 'manifest-b'
        $arguments.Remove('SemanticLabel')
        $second = Invoke-Generator -Arguments $arguments
        Assert-True ($second.ExitCode -eq 0 -and ($second.Stdout | ConvertFrom-Json).line_manifest_created -eq $false) ("第二次產生失敗或誤建 line.json：$($second.Stderr)")
        Assert-True ($hashBefore -ceq (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash) 'line.json 雜湊在第二次執行後改變'
    }

    # 正向 3：prompt 開頭的 LineContext 區塊含六個標籤，且值與 DI-LINECTX-A 解析結果一致。
    Test-Case 'P03 prompt 含 LineContext 區塊與六個標籤，值符合預期執行目錄' {
        foreach ($mode in @('none', 'git')) {
            $root = New-Fixture -Name ('prompt-' + $mode) -Git $mode
            $mock = Get-DispatchExpectedExecutionMode -SourceRoot $root -DispatchSlug 'prompt-a' -WriteMode 'readonly' -IsRepository ($mode -eq 'git') -HasBaseCommit ($mode -eq 'git')
            $reportPath = Join-Path $mock.executionRoot '.local\ai-sessions\report\prompt-line\report.md'
            $arguments = Get-OrderArguments -Root $root -LineSlug 'prompt-line' -DispatchSlug 'prompt-a' -ReportPath $reportPath
            $arguments.TaskType = 'review'; $arguments.Profile = 'review'; $arguments.SemanticLabel = 'prompt fixture'
            $result = Invoke-Generator -Arguments $arguments
            Assert-True ($result.ExitCode -eq 0) ("[$mode] 產生失敗：$($result.Stderr) $($result.BindingError)")
            $promptText = Get-Content -LiteralPath ($result.Stdout | ConvertFrom-Json).prompt_path -Raw -Encoding UTF8
            Assert-True ($promptText -match '(?i)LineContext') "[$mode] prompt 缺少 LineContext 標示"
            $values = Get-LabelValues -PromptText $promptText
            foreach ($label in $values.Keys) { Assert-True ($null -ne $values[$label]) "[$mode] 缺少標籤 $label" }
            $expectedExecution = $mock.executionRoot
            Assert-True ($values.lineSlug -ceq 'prompt-line' -and $values.sourceRoot -ieq $root -and $values.dispatchRoot -ieq $expectedExecution) "[$mode] lineSlug、sourceRoot 或 dispatchRoot 不符：$($values | ConvertTo-Json -Compress)"
            Assert-True ($values.sourceLineRoot -ieq (Join-Path $root '.local\ai-sessions\handoff\prompt-line') -and $values.dispatchLineRoot -ieq (Join-Path $expectedExecution '.local\ai-sessions\handoff\prompt-line') -and $values.reportLineRoot -ieq (Join-Path $expectedExecution '.local\ai-sessions\report\prompt-line')) "[$mode] 目錄標籤不符：$($values | ConvertTo-Json -Compress)"
        }
    }

    # 正向 4：RequiredRead 區塊；未帶時輸出與僅呼叫 New-DispatchOrder.ps1 相同。
    Test-Case 'P04 帶 -RequiredRead 時派遣單含必讀檔案區塊，未帶時與 New-DispatchOrder.ps1 輸出相同' {
        $root = New-Fixture -Name 'required-read'
        $readFile = Join-Path $root 'notes\ref.md'
        Write-TextFile -Path $readFile -Content 'ref'
        $arguments = Get-OrderArguments -Root $root -LineSlug 'reqread-line' -DispatchSlug 'reqread-a'
        $arguments.TaskType = 'generate'; $arguments.Profile = 'content'; $arguments.SemanticLabel = 'required read fixture'
        $arguments.RequiredRead = @($readFile)
        $with = Invoke-Generator -Arguments $arguments
        Assert-True ($with.ExitCode -eq 0) ("帶 RequiredRead 失敗：$($with.Stderr) $($with.BindingError)")
        $orderText = Get-Content -LiteralPath ($with.Stdout | ConvertFrom-Json).order_path -Raw -Encoding UTF8
        Assert-True ($orderText.Contains('必讀檔案：') -and $orderText.Contains('- `' + $readFile + '`')) '派遣單缺少必讀檔案區塊或逐行反引號路徑'

        $directRoot = New-Fixture -Name 'required-read-direct'
        $directArguments = Get-OrderArguments -Root $directRoot -LineSlug 'plain-line' -DispatchSlug 'plain-a'
        $directOrderPath = Join-Path $directRoot '.local\ai-sessions\handoff\plain-line\dispatch-order-plain-a.md'
        & $orderScriptPath -Title $directArguments.Title -Role $directArguments.Role -TargetPath $directArguments.TargetPath -TaskBody $directArguments.TaskBody -Acceptance $directArguments.Acceptance -Boundary $directArguments.Boundary -ReportPath $directArguments.ReportPath -DispatchSlug 'plain-a' -LineSlug 'plain-line' -OutputPath $directOrderPath | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) 'New-DispatchOrder.ps1 直接呼叫失敗'
        $directText = Get-Content -LiteralPath $directOrderPath -Raw -Encoding UTF8
        Remove-Item -LiteralPath $directOrderPath -Force
        $plainArguments = Get-OrderArguments -Root $directRoot -LineSlug 'plain-line' -DispatchSlug 'plain-a'
        $plainArguments.TaskType = 'generate'; $plainArguments.Profile = 'content'; $plainArguments.SemanticLabel = 'plain fixture'
        $plain = Invoke-Generator -Arguments $plainArguments
        Assert-True ($plain.ExitCode -eq 0) ("未帶 RequiredRead 失敗：$($plain.Stderr) $($plain.BindingError)")
        $plainText = Get-Content -LiteralPath ($plain.Stdout | ConvertFrom-Json).order_path -Raw -Encoding UTF8
        Assert-True ($plainText -ceq $directText) '未帶 RequiredRead 的派遣單與直接呼叫 New-DispatchOrder.ps1 的輸出不同'
    }

    # 正向 5：預期執行模式與 Invoke-Preflight 實際值一致。
    Test-Case 'P05 Get-DispatchExpectedExecutionMode 與 Invoke-Preflight 在建 worktree 與不建 worktree 兩種 fixture 一致' {
        foreach ($mode in @('git', 'none', 'git-nocommit')) {
            $root = New-Fixture -Name ('mode-' + $mode) -Git $mode
            $slug = 'mode-' + $mode
            $lineRoot = Join-Path $root ('.local\ai-sessions\handoff\' + $slug)
            Write-TextFile -Path (Join-Path $lineRoot 'line.json') -Content ((([ordered]@{ schema = 'ai-sessions.line.v1'; 'line-slug' = $slug } | ConvertTo-Json -Compress)) + "`r`n")
            $isRepository = $mode -ne 'none'
            $expected = Get-DispatchExpectedExecutionMode -SourceRoot $root -DispatchSlug $slug -WriteMode 'readonly' -IsRepository $isRepository -HasBaseCommit ($mode -eq 'git')
            $dispatchRoot = Join-Path $root ('.local\ai-sessions\worktrees\' + $slug)
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $pwshPath
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $entryPath, '-Operation', 'Preflight', '-SourceRoot', $root, '-DispatchRoot', $dispatchRoot, '-LineSlug', $slug, '-DispatchSlug', $slug, '-WriteMode', 'readonly', '-TargetPath', (Join-Path $root 'target.txt'), '-DispatchKind', 'workflow', '-TaskType', 'script-change')) { $startInfo.ArgumentList.Add($argument) }
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
            $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
            $process = [System.Diagnostics.Process]::Start($startInfo)
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            $stdoutTask.Wait(); $stderrTask.Wait()
            $preflightExit = $process.ExitCode
            $process.Dispose()
            Assert-True ($preflightExit -eq 0) "[$mode] Preflight 失敗 exit=$preflightExit stderr=$($stderrTask.Result)"
            $actual = $stdoutTask.Result | ConvertFrom-Json
            Assert-True ([bool]$actual.worktreeCreated -eq [bool]$expected.worktreeCreated) "[$mode] worktreeCreated 預期 $($expected.worktreeCreated) 實際 $($actual.worktreeCreated)"
            Assert-True ([string]::Equals([string]$actual.executionRoot, [string]$expected.executionRoot, [StringComparison]::OrdinalIgnoreCase) -and [string]::Equals([string]$actual.dispatchRoot, [string]$expected.dispatchRoot, [StringComparison]::OrdinalIgnoreCase)) "[$mode] executionRoot 或 dispatchRoot 不一致：預期 $($expected.executionRoot) / $($expected.dispatchRoot)，實際 $($actual.executionRoot) / $($actual.dispatchRoot)"
            if ($mode -eq 'git') { Assert-True ([bool]$actual.worktreeCreated) 'git fixture 應建立 worktree' } else { Assert-True (-not [bool]$actual.worktreeCreated) "$mode fixture 不應建立 worktree" }
        }
    }

    # 負向 1。
    Test-Case 'N01 -TaskType edit 以 DispatchInputTaskTypeUnsupported 拒絕且無任何新檔' {
        $root = New-Fixture -Name 'neg-edit'
        $before = Get-FileListing -Root $root
        $arguments = Get-OrderArguments -Root $root -LineSlug 'neg-line' -DispatchSlug 'neg-edit'
        $arguments.TaskType = 'edit'; $arguments.Profile = 'content'; $arguments.SemanticLabel = 'neg'
        $result = Invoke-Generator -Arguments $arguments
        Assert-True ($result.ExitCode -eq 1 -and (Get-FailureCode $result) -ceq 'DispatchInputTaskTypeUnsupported') ("結果不符：exit=$($result.ExitCode) code=$(Get-FailureCode $result) stderr=$($result.Stderr)")
        Assert-True (@(Compare-Object $before (Get-FileListing -Root $root)).Count -eq 0) '拒絕後出現新檔'
    }

    # 負向 2。
    foreach ($mismatch in @(@('review', 'scan'), @('generate', 'scan'), @('test', 'content'))) {
        $capturedMismatch = $mismatch
        Test-Case ('N02 -TaskType {0} -Profile {1} 以 DispatchInputProfileTaskMismatch 拒絕' -f $mismatch[0], $mismatch[1]) {
            $root = New-Fixture -Name ('neg-mismatch-' + $capturedMismatch[0] + '-' + $capturedMismatch[1])
            $before = Get-FileListing -Root $root
            $arguments = Get-OrderArguments -Root $root -LineSlug 'neg-line' -DispatchSlug 'neg-mismatch'
            $arguments.TaskType = $capturedMismatch[0]; $arguments.Profile = $capturedMismatch[1]; $arguments.SemanticLabel = 'neg'
            $result = Invoke-Generator -Arguments $arguments
            Assert-True ($result.ExitCode -eq 1 -and (Get-FailureCode $result) -ceq 'DispatchInputProfileTaskMismatch') ("結果不符：exit=$($result.ExitCode) code=$(Get-FailureCode $result) stderr=$($result.Stderr)")
            Assert-True (@(Compare-Object $before (Get-FileListing -Root $root)).Count -eq 0) '拒絕後出現新檔'
        }
    }

    # 負向 2a。
    foreach ($removedProfile in @('deep-review', 'default', 'implement', 'intensive')) {
        $capturedRemoved = $removedProfile
        Test-Case ("N02a -Profile $removedProfile 在參數繫結階段被拒絕並列出現行檔位") {
            $root = New-Fixture -Name ('neg-profile-' + $capturedRemoved)
            $before = Get-FileListing -Root $root
            $arguments = Get-OrderArguments -Root $root -LineSlug 'neg-line' -DispatchSlug 'neg-profile'
            $arguments.TaskType = 'review'; $arguments.Profile = $capturedRemoved; $arguments.SemanticLabel = 'neg'
            $result = Invoke-Generator -Arguments $arguments
            Assert-True ($result.ExitCode -ne 0 -and $null -ne $result.BindingError) ("應在參數繫結階段失敗：exit=$($result.ExitCode) stdout=$($result.Stdout)")
            Assert-True ([regex]::IsMatch($result.BindingError, 'review,\s*scan,\s*content,\s*advisor')) ("錯誤訊息未列出現行四個檔位：" + $result.BindingError)
            Assert-True (@(Compare-Object $before (Get-FileListing -Root $root)).Count -eq 0) '拒絕後出現新檔'
        }
    }

    # 負向 3。
    Test-Case 'N03 line.json 不存在且無 -SemanticLabel 時拒絕，無殘留檔' {
        $root = New-Fixture -Name 'neg-no-label'
        $before = Get-FileListing -Root $root
        $arguments = Get-OrderArguments -Root $root -LineSlug 'neg-line' -DispatchSlug 'neg-nolabel'
        $arguments.TaskType = 'generate'; $arguments.Profile = 'content'
        $result = Invoke-Generator -Arguments $arguments
        Assert-True ($result.ExitCode -eq 1 -and (Get-FailureCode $result) -ceq 'DispatchRequestMissingField') ("結果不符：exit=$($result.ExitCode) code=$(Get-FailureCode $result) stderr=$($result.Stderr)")
        Assert-True (@(Compare-Object $before (Get-FileListing -Root $root)).Count -eq 0) '拒絕後出現新檔'
    }

    # 負向 4。
    Test-Case 'N04 line.json 的 line-slug 不符時以 DispatchInputLineManifestMismatch 拒絕且雜湊不變' {
        $root = New-Fixture -Name 'neg-manifest-mismatch'
        $manifestPath = Join-Path $root '.local\ai-sessions\handoff\neg-line\line.json'
        Write-TextFile -Path $manifestPath -Content ((([ordered]@{ schema = 'ai-sessions.line.v1'; 'line-slug' = 'other-line' } | ConvertTo-Json -Compress)) + "`r`n")
        $hashBefore = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        $before = Get-FileListing -Root $root
        $arguments = Get-OrderArguments -Root $root -LineSlug 'neg-line' -DispatchSlug 'neg-mismatch'
        $arguments.TaskType = 'generate'; $arguments.Profile = 'content'; $arguments.SemanticLabel = 'neg'
        $result = Invoke-Generator -Arguments $arguments
        Assert-True ($result.ExitCode -eq 1 -and (Get-FailureCode $result) -ceq 'DispatchInputLineManifestMismatch') ("結果不符：exit=$($result.ExitCode) code=$(Get-FailureCode $result) stderr=$($result.Stderr)")
        Assert-True ($hashBefore -ceq (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash) 'line.json 雜湊改變'
        Assert-True (@(Compare-Object $before (Get-FileListing -Root $root)).Count -eq 0) '拒絕後出現新檔'
    }

    # 負向 5。
    Test-Case 'N05 目標輸出已存在時以 DispatchInputOutputExists 拒絕且既有檔雜湊不變' {
        $root = New-Fixture -Name 'neg-exists'
        $promptPath = Join-Path $root '.local\ai-sessions\handoff\neg-line\dispatch-prompt-neg-exists.md'
        Write-TextFile -Path $promptPath -Content 'existing prompt'
        $hashBefore = (Get-FileHash -LiteralPath $promptPath -Algorithm SHA256).Hash
        $before = Get-FileListing -Root $root
        $arguments = Get-OrderArguments -Root $root -LineSlug 'neg-line' -DispatchSlug 'neg-exists'
        $arguments.TaskType = 'generate'; $arguments.Profile = 'content'; $arguments.SemanticLabel = 'neg'
        $result = Invoke-Generator -Arguments $arguments
        Assert-True ($result.ExitCode -eq 1 -and (Get-FailureCode $result) -ceq 'DispatchInputOutputExists') ("結果不符：exit=$($result.ExitCode) code=$(Get-FailureCode $result) stderr=$($result.Stderr)")
        Assert-True ($hashBefore -ceq (Get-FileHash -LiteralPath $promptPath -Algorithm SHA256).Hash) '既有檔雜湊改變'
        Assert-True (@(Compare-Object $before (Get-FileListing -Root $root)).Count -eq 0) '拒絕後出現新檔'
    }

    # 負向 6。
    Test-Case 'N06 -RequiredRead 含相對路徑時沿用既有必讀檔案錯誤碼拒絕，回滾本次建立的檔案並保留本次新建的 line.json' {
        $root = New-Fixture -Name 'neg-relative-read'
        $before = Get-FileListing -Root $root
        $arguments = Get-OrderArguments -Root $root -LineSlug 'neg-line' -DispatchSlug 'neg-read'
        $arguments.TaskType = 'generate'; $arguments.Profile = 'content'; $arguments.SemanticLabel = 'neg'
        $arguments.RequiredRead = @('notes\relative.md')
        $result = Invoke-Generator -Arguments $arguments
        $code = Get-FailureCode $result
        Assert-True ($result.ExitCode -eq 1 -and $code.StartsWith('DispatchInputRequiredRead', [StringComparison]::Ordinal)) ("結果不符：exit=$($result.ExitCode) code=$code stderr=$($result.Stderr)")
        $manifestPath = Join-Path $root '.local\ai-sessions\handoff\neg-line\line.json'
        $leftover = @(Compare-Object $before (Get-FileListing -Root $root) | ForEach-Object { [string]$_.InputObject })
        Assert-True ($leftover.Count -eq 1 -and [string]::Equals($leftover[0], $manifestPath, [StringComparison]::OrdinalIgnoreCase)) ('拒絕後除 line.json 外仍出現新檔（本次建立的檔案未回滾）：' + ($leftover -join '; '))
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($manifest.'line-slug' -ceq 'neg-line' -and $manifest.schema -ceq 'ai-sessions.line.v1') '保留的 line.json 內容不符'
    }

    # Git 探針失敗但不是「不是 repository」時，回報錯誤而不預判為非 repository（以損毀的全域設定檔使 git 失敗）。
    Test-Case 'N11 Git 探針因非「不是 repository」的原因失敗時以 DispatchInputGitProbeFailed 拒絕，不預判 worktreeCreated=false' {
        $root = New-Fixture -Name 'neg-git-probe'
        $badConfig = Join-Path $tempRoot 'bad-global-gitconfig'
        Write-TextFile -Path $badConfig -Content "this is not a valid git config line`r`n"
        $before = Get-FileListing -Root $root
        $arguments = Get-OrderArguments -Root $root -LineSlug 'neg-line' -DispatchSlug 'neg-probe'
        $arguments.TaskType = 'generate'; $arguments.Profile = 'content'; $arguments.SemanticLabel = 'neg'
        $previousGlobalConfig = $env:GIT_CONFIG_GLOBAL
        $env:GIT_CONFIG_GLOBAL = $badConfig
        try { $result = Invoke-Generator -Arguments $arguments }
        finally { $env:GIT_CONFIG_GLOBAL = $previousGlobalConfig }
        Assert-True ($result.ExitCode -eq 1 -and (Get-FailureCode $result) -ceq 'DispatchInputGitProbeFailed') ("結果不符：exit=$($result.ExitCode) code=$(Get-FailureCode $result) stderr=$($result.Stderr)")
        Assert-True (@(Compare-Object $before (Get-FileListing -Root $root)).Count -eq 0) '拒絕後出現新檔'
    }

    # 負向 7。以替身入口使自檢失敗。
    Test-Case 'N07 自檢失敗時 exit 1，本次建立的檔案全數刪除，先前存在的 line.json 保留' {
        $stubScripts = Join-Path $tempRoot 'stub-scripts'
        New-Item -ItemType Directory -Path (Join-Path $stubScripts 'dispatch') -Force | Out-Null
        Copy-Item -LiteralPath $generatorPath -Destination (Join-Path $stubScripts 'New-DispatchInputs.ps1')
        Copy-Item -LiteralPath $orderScriptPath -Destination (Join-Path $stubScripts 'New-DispatchOrder.ps1')
        Copy-Item -LiteralPath (Join-Path $scriptsRoot 'dispatch\dispatch-input-checks.ps1') -Destination (Join-Path $stubScripts 'dispatch\dispatch-input-checks.ps1')
        Copy-Item -LiteralPath (Join-Path $scriptsRoot 'dispatch\executor-registry.json') -Destination (Join-Path $stubScripts 'dispatch\executor-registry.json')
        Write-TextFile -Path (Join-Path $stubScripts 'Invoke-CodexDispatch.ps1') -Content @'
[Console]::Error.WriteLine('stub: request 缺少必要欄位 target_path')
exit 1
'@
        $root = New-Fixture -Name 'neg-selfcheck'
        $manifestPath = Join-Path $root '.local\ai-sessions\handoff\neg-line\line.json'
        Write-TextFile -Path $manifestPath -Content ((([ordered]@{ schema = 'ai-sessions.line.v1'; 'line-slug' = 'neg-line' } | ConvertTo-Json -Compress)) + "`r`n")
        $hashBefore = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        $before = Get-FileListing -Root $root
        $arguments = Get-OrderArguments -Root $root -LineSlug 'neg-line' -DispatchSlug 'neg-selfcheck'
        $arguments.TaskType = 'generate'; $arguments.Profile = 'content'
        $result = Invoke-Generator -Arguments $arguments -ScriptPath (Join-Path $stubScripts 'New-DispatchInputs.ps1')
        Assert-True ($result.ExitCode -eq 1 -and (Get-FailureCode $result) -ceq 'DispatchInputSelfCheckFailed') ("結果不符：exit=$($result.ExitCode) code=$(Get-FailureCode $result) stderr=$($result.Stderr) binding=$($result.BindingError)")
        Assert-True (@(Compare-Object $before (Get-FileListing -Root $root)).Count -eq 0) '自檢失敗後本次建立的檔案未全數刪除'
        Assert-True ((Test-Path -LiteralPath $manifestPath -PathType Leaf) -and $hashBefore -ceq (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash) '先前存在的 line.json 被刪除或改變'
    }

    Test-Case 'N07b 自檢失敗時，本次新建的 line.json 保留，其餘本次新建的檔案全數刪除' {
        $stubScripts = Join-Path $tempRoot 'stub-scripts-b'
        New-Item -ItemType Directory -Path (Join-Path $stubScripts 'dispatch') -Force | Out-Null
        Copy-Item -LiteralPath $generatorPath -Destination (Join-Path $stubScripts 'New-DispatchInputs.ps1')
        Copy-Item -LiteralPath $orderScriptPath -Destination (Join-Path $stubScripts 'New-DispatchOrder.ps1')
        Copy-Item -LiteralPath (Join-Path $scriptsRoot 'dispatch\dispatch-input-checks.ps1') -Destination (Join-Path $stubScripts 'dispatch\dispatch-input-checks.ps1')
        Copy-Item -LiteralPath (Join-Path $scriptsRoot 'dispatch\executor-registry.json') -Destination (Join-Path $stubScripts 'dispatch\executor-registry.json')
        Write-TextFile -Path (Join-Path $stubScripts 'Invoke-CodexDispatch.ps1') -Content @'
[Console]::Error.WriteLine('stub: request 缺少必要欄位 target_path')
exit 1
'@
        $root = New-Fixture -Name 'neg-selfcheck-new-manifest'
        $before = Get-FileListing -Root $root
        $arguments = Get-OrderArguments -Root $root -LineSlug 'neg-line' -DispatchSlug 'neg-selfcheck-b'
        $arguments.TaskType = 'generate'; $arguments.Profile = 'content'; $arguments.SemanticLabel = 'neg'
        $result = Invoke-Generator -Arguments $arguments -ScriptPath (Join-Path $stubScripts 'New-DispatchInputs.ps1')
        Assert-True ($result.ExitCode -eq 1 -and (Get-FailureCode $result) -ceq 'DispatchInputSelfCheckFailed') ("結果不符：exit=$($result.ExitCode) code=$(Get-FailureCode $result) stderr=$($result.Stderr)")
        $manifestPath = Join-Path $root '.local\ai-sessions\handoff\neg-line\line.json'
        $leftover = @(Compare-Object $before (Get-FileListing -Root $root) | ForEach-Object { [string]$_.InputObject })
        Assert-True ($leftover.Count -eq 1 -and [string]::Equals($leftover[0], $manifestPath, [StringComparison]::OrdinalIgnoreCase)) ('自檢失敗後除 line.json 外仍有新檔：' + ($leftover -join '; '))
        Assert-True ((Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json).'line-slug' -ceq 'neg-line') '保留的 line.json 內容不符'
        Assert-True ($result.Stderr.Contains('line.json')) '自檢失敗訊息未說明 line.json 保留'
    }

    # git 探針 exit 0 但輸出不是 true（SourceRoot 位於 .git 目錄內，輸出 false）時，比照 Preflight 失敗回報，不預判 worktreeCreated=false。
    Test-Case 'N12 Git 探針 exit 0 但輸出不是 true 時以 DispatchInputGitProbeFailed 拒絕' {
        $repo = New-Fixture -Name 'neg-git-dir-root' -Git 'git'
        $root = Join-Path $repo '.git'
        Write-TextFile -Path (Join-Path $root 'target.txt') -Content 'fixture target'
        $listRoot = { @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object { $_.FullName }) }
        $beforeFiles = @(& $listRoot)
        $arguments = Get-OrderArguments -Root $root -LineSlug 'neg-line' -DispatchSlug 'neg-gitdir'
        $arguments.TaskType = 'generate'; $arguments.Profile = 'content'; $arguments.SemanticLabel = 'neg'
        $result = Invoke-Generator -Arguments $arguments
        Assert-True ($result.ExitCode -eq 1 -and (Get-FailureCode $result) -ceq 'DispatchInputGitProbeFailed') ("結果不符：exit=$($result.ExitCode) code=$(Get-FailureCode $result) stderr=$($result.Stderr)")
        Assert-True (@(& $listRoot).Count -eq $beforeFiles.Count) '拒絕後出現新檔'
    }

    # 負向 8。
    Test-Case 'N08start.md 的 LineContext 範例含 sourceRoot= 與 dispatchRoot=' {
        $startText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills\codex-dispatch\references\start.md') -Raw -Encoding UTF8
        $match = [regex]::Match($startText, '(?s)Prompt 必須明列已驗證的 `LineContext`.*?```text\r?\n(?<block>.*?)```')
        Assert-True $match.Success '找不到 LineContext 範例區塊'
        Assert-True ($match.Groups['block'].Value.Contains('sourceRoot=') -and $match.Groups['block'].Value.Contains('dispatchRoot=')) 'LineContext 範例缺少 sourceRoot= 或 dispatchRoot='
    }

    # 負向 9。
    foreach ($relativePath in @('scripts\New-DispatchInputs.ps1', 'scripts\tests\Test-NewDispatchInputs.ps1', 'scripts\tests\Test-PowerShellHostGuardHook.ps1', 'claude-plugins\ai-agents-hooks\hooks\powershell-host-guard-hook.ps1')) {
        $capturedRelativePath = $relativePath
        Test-Case ("N09 $relativePath 為 UTF-8 with BOM 與 CRLF") {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $repositoryRoot $capturedRelativePath))
            Assert-True ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) '缺少 UTF-8 BOM'
            $text = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
            Assert-True ($text.StartsWith('#Requires -Version 7.0', [StringComparison]::Ordinal)) '首行不是 #Requires -Version 7.0'
            Assert-True (-not [regex]::IsMatch($text, '(?<!\r)\n')) '含單獨 LF 行尾'
        }
    }

    # 補充：建 worktree 的來源下，ReportPath 不在 executionRoot 內時預先拒絕。
    Test-Case 'N10 Preflight 會建 worktree 時 ReportPath 不在 executionRoot 內以 DispatchReportPathOutsideExecutionRoot 拒絕' {
        $root = New-Fixture -Name 'neg-report-outside' -Git 'git'
        $before = Get-FileListing -Root $root
        $arguments = Get-OrderArguments -Root $root -LineSlug 'neg-line' -DispatchSlug 'neg-report'
        $arguments.TaskType = 'generate'; $arguments.Profile = 'content'; $arguments.SemanticLabel = 'neg'
        $result = Invoke-Generator -Arguments $arguments
        Assert-True ($result.ExitCode -eq 1 -and (Get-FailureCode $result) -ceq 'DispatchReportPathOutsideExecutionRoot') ("結果不符：exit=$($result.ExitCode) code=$(Get-FailureCode $result) stderr=$($result.Stderr)")
        Assert-True (@(Compare-Object $before (Get-FileListing -Root $root)).Count -eq 0) '拒絕後出現新檔'
    }
}
finally {
    $env:CODEX_HOME = $previousCodexHome
    if (Test-Path -LiteralPath $tempRoot) {
        foreach ($worktreeRoot in @(Get-ChildItem -LiteralPath $tempRoot -Directory -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath (Join-Path $worktreeRoot.FullName '.git')) {
                $null = & git -C $worktreeRoot.FullName worktree prune 2>&1
            }
        }
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output ("PASSED {0} FAILED {1}" -f $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
