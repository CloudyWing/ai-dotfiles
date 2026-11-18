#Requires -Version 7.0
[CmdletBinding()]
param([string]$Cases)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$scriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Invoke-WorkOverviewCleanup.ps1'))
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$tempRoot = Join-Path $tempBase ('wo-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
if (-not $tempRoot.StartsWith($tempBase + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '測試目錄未位於系統暫存目錄' }
$script:failed = 0
$script:passed = 0
$script:executed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:gapDirectories = [Collections.Generic.List[string]]::new()

function New-InaccessibleDirectory {
    [CmdletBinding()]
    param([string]$Path)
    # 結尾為句點的資料夾可由父層列出，但以一般路徑無法開啟，用來模擬無法列舉的子目錄而不更動 ACL。
    $extended = '\\?\' + $Path
    $null = [IO.Directory]::CreateDirectory($extended)
    $script:gapDirectories.Add($extended)
}

function Assert-True {
    [CmdletBinding()]
    param([bool]$Condition, [string]$Message = '條件不成立')
    if (-not $Condition) { throw $Message }
}

function Test-Case {
    [CmdletBinding()]
    param([string]$Id, [scriptblock]$Check)
    if (-not [string]::IsNullOrWhiteSpace($Cases) -and ($Cases -split ',') -notcontains $Id) { return }
    $null = $script:executed.Add($Id)
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

function Write-TestFile {
    [CmdletBinding()]
    param([string]$Path, [string]$Text)
    $parent = [IO.Path]::GetDirectoryName($Path)
    $null = [IO.Directory]::CreateDirectory($parent)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Invoke-TestGit {
    [CmdletBinding()]
    param([string]$WorkRoot, [string[]]$Arguments)
    $output = @(& git -C $WorkRoot @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ')：$($output -join ' ')" }
    return ($output -join "`n")
}

function Invoke-Cleanup {
    [CmdletBinding()]
    param([string[]]$Roots, [object]$Sessions = @(), [switch]$Unknown, [switch]$AsHuman, [string]$Target = 'all', [string]$ConfirmPlan, [string[]]$ClosedLine = @(), [int]$LargeFileBytes = 16, [switch]$PassVerbose)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Get-Process -Id $PID).Path
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $arguments = @('-NoProfile', '-NonInteractive', '-File', $scriptPath, '-Root', ($Roots -join ';'), '-Target', $Target, '-LargeFileBytes', [string]$LargeFileBytes)
    if (-not $AsHuman) { $arguments += '-AsJson' }
    if ($PassVerbose) { $arguments += '-Verbose' }
    if (-not $Unknown) { $arguments += '-SessionsFromStdin' }
    if ($PSBoundParameters.ContainsKey('ConfirmPlan')) { $arguments += @('-ConfirmPlan', $ConfirmPlan) }
    if ($ClosedLine.Count -gt 0) { $arguments += @('-ClosedLine', ($ClosedLine -join ',')) }
    foreach ($argument in $arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        $null = $process.Start()
        if (-not $Unknown) { $process.StandardInput.Write((ConvertTo-Json -InputObject @{ sessions = @($Sessions) } -Depth 10 -Compress)) }
        $process.StandardInput.Close()
        $out = $process.StandardOutput.ReadToEndAsync()
        $err = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $out.GetAwaiter().GetResult()
        $stderr = $err.GetAwaiter().GetResult()
        if ($process.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($stdout)) { throw "清理腳本 exit 1：$stderr" }
        $value = $null
        if (-not $AsHuman -and -not [string]::IsNullOrWhiteSpace($stdout)) { $value = ConvertFrom-Json -InputObject $stdout }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout; StdErr = $stderr; Value = $value }
    }
    finally { $process.Dispose() }
}

function Get-ItemByPath {
    [CmdletBinding()]
    param([object]$Plan, [string]$Path)
    $found = @($Plan.items | Where-Object { $_.path -eq $Path })
    Assert-True ($found.Count -eq 1) "找不到唯一項目：$Path"
    return $found[0]
}

function New-ClosedLine {
    [CmdletBinding()]
    param([string]$WorkRoot, [string]$Slug)
    $base = Join-Path $WorkRoot '.local\ai-sessions'
    Write-TestFile (Join-Path $base "handoff\$Slug\line.json") "{`"line-slug`":`"$Slug`"}"
    Write-TestFile (Join-Path $base "handoff\$Slug\requirement-summary.md") '需求'
    Write-TestFile (Join-Path $base "handoff\$Slug\design.md") '設計'
    $checkpoint = Join-Path $base "report\$Slug\handoff-checkpoint.md"
    Write-TestFile $checkpoint '- 檢查點類型：`developer-collected`（完成）'
    (Get-Item -LiteralPath $checkpoint).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-30)
}

function Get-TreeFingerprint {
    [CmdletBinding()]
    param([string]$Path)
    $entries = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force | Sort-Object FullName | ForEach-Object { "$( $_.FullName )|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" })
    return $entries -join "`n"
}

try {
    $null = [IO.Directory]::CreateDirectory($tempRoot)
    Test-Case K01 {
        $bytes = [IO.File]::ReadAllBytes($scriptPath)
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        Assert-True ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191 -and $errors.Count -eq 0)
        Assert-True ([IO.File]::ReadAllText($scriptPath).StartsWith('#Requires -Version 7.0'))
    }
    $lineRoot = Join-Path $tempRoot 'line-fixture'
    $null = [IO.Directory]::CreateDirectory($lineRoot)
    New-ClosedLine $lineRoot 'alpha'
    $lineBase = Join-Path $lineRoot '.local\ai-sessions'
    $historyFile = Join-Path $lineBase 'history\alpha\candidate.txt'
    $selfFile = Join-Path $lineBase 'history\alpha\self.txt'
    $extraFile = Join-Path $lineBase 'handoff\alpha\extra.txt'
    Write-TestFile $historyFile 'history fixture'
    Write-TestFile $selfFile 'self fixture'
    Write-TestFile $extraFile 'extra fixture'
    Write-TestFile (Join-Path $lineBase 'report\alpha\own.md') $selfFile
    $externalReport = Join-Path $lineBase 'report\beta\reference.md'
    Write-TestFile $externalReport $historyFile
    $initial = Invoke-Cleanup @($lineRoot) -Target lines -ClosedLine @('alpha')
    Test-Case L04 {
        Assert-True ($initial.ExitCode -eq 0) $initial.StdErr
        $history = @($initial.Value.items | Where-Object { $_.lineSlug -eq 'alpha' -and $_.category -eq 'history' })[0]
        Assert-True ($history.status -eq 'cleanable' -and $history.protectedFileCount -eq 1 -and ($history.reasons -join '') -like "*$externalReport*")
        Assert-True ($history.fileCount -eq 1)
        foreach ($reference in @('.local\ai-sessions\history\alpha\candidate.txt', ($historyFile -replace '\\', '\\'), (Split-Path -Parent $historyFile))) {
            Write-TestFile $externalReport $reference
            $listed = Invoke-Cleanup @($lineRoot) -Target lines -ClosedLine @('alpha')
            $row = @($listed.Value.items | Where-Object { $_.lineSlug -eq 'alpha' -and $_.category -eq 'history' })[0]
            Assert-True ($row.protectedFileCount -ge 1) "引用未生效：$reference"
        }
        Write-TestFile $externalReport $historyFile
    }
    Write-TestFile (Join-Path $lineBase 'report\alpha\large.unknown') ('a' * 30)
    [IO.File]::WriteAllBytes((Join-Path $lineBase 'report\alpha\binary.txt'), [byte[]](0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16))
    Write-TestFile (Join-Path $lineBase 'report\alpha\small.txt') 'small'
    Write-TestFile (Join-Path $lineBase 'report\alpha\large.log') ('log text ' * 5)
    Test-Case L05 {
        $listed = Invoke-Cleanup @($lineRoot) -Target lines -ClosedLine @('alpha')
        $review = @($listed.Value.items | Where-Object { $_.category -eq 'report-logs' -and $_.status -eq 'needs-review' })
        Assert-True ($review.Count -eq 1 -and ($review[0].reasons -join '') -match '大檔類型不在可清理清單' -and ($review[0].reasons -join '') -match '不是文字檔')
        Assert-True (@($listed.Value.items | Where-Object { $_.category -eq 'report-logs' -and $_.status -eq 'cleanable' }).Count -eq 1)
    }
    $oldBackup = Join-Path $lineBase 'backups\20000101_010101\old.txt'
    $newBackup = Join-Path $lineBase ('backups\' + [DateTime]::Now.ToString('yyyyMMdd_HHmmss') + '\new.txt')
    Write-TestFile $oldBackup 'old backup'
    Write-TestFile $newBackup 'new backup'
    Test-Case L06 {
        $listed = Invoke-Cleanup @($lineRoot) -Target lines -ClosedLine @('alpha')
        $old = Get-ItemByPath $listed.Value (Split-Path -Parent $oldBackup)
        $recent = Get-ItemByPath $listed.Value (Split-Path -Parent $newBackup)
        Assert-True ($old.status -eq 'cleanable' -and $recent.status -eq 'protected')
    }
    Test-Case T024 {
        $listed = Invoke-Cleanup @($lineRoot) -Target lines -ClosedLine @('alpha')
        $backup = Get-ItemByPath $listed.Value (Split-Path -Parent $oldBackup)
        Assert-True ($null -eq $backup.lineSlug -and $null -eq $backup.category) '備份項目的 lineSlug 與 category 應為 null'
        Assert-True ($listed.StdOut -match '"lineSlug":null,"category":null') 'JSON 契約應輸出 null 而非空字串'
        Assert-True ($listed.StdOut -notmatch '"lineSlug":"","category"') 'JSON 不應輸出空字串'
    }
    Test-Case L08 {
        $templates = @(
            '`.local\ai-sessions\history\<lineSlug>`'
            '`.local\ai-sessions\handoff\<lineSlug>\*`'
            "$lineBase\history\<lineSlug>"
            '.local\ai-sessions\report\*.log'
            '<root>\.local\ai-sessions\history\alpha\candidate.txt'
            '.local\ai-sessions\history'
            '.local\ai-sessions\backups'
            '.local\ai-sessions'
            $lineBase
            (Join-Path $lineBase 'history')
        ) -join "`n"
        Write-TestFile $externalReport $templates
        try {
            $listed = Invoke-Cleanup @($lineRoot) -Target lines -ClosedLine @('alpha')
            Assert-True ($listed.ExitCode -eq 0) $listed.StdErr
            $history = @($listed.Value.items | Where-Object { $_.lineSlug -eq 'alpha' -and $_.category -eq 'history' })[0]
            Assert-True ($history.status -eq 'cleanable' -and $history.protectedFileCount -eq 0 -and $history.fileCount -eq 2) "範本或類別層級路徑不應保護歷史：$($history.status) $($history.reasons -join '；')"
            $extras = @($listed.Value.items | Where-Object { $_.lineSlug -eq 'alpha' -and $_.category -eq 'handoff-extras' })[0]
            Assert-True ($extras.status -eq 'cleanable' -and $extras.protectedFileCount -eq 0) '範本不應保護 handoff 暫存'
            $backup = Get-ItemByPath $listed.Value (Split-Path -Parent $oldBackup)
            Assert-True ($backup.status -eq 'cleanable') ($backup.reasons -join '；')
        }
        finally { Write-TestFile $externalReport $historyFile }
    }
    Test-Case L09 {
        foreach ($concrete in @((Split-Path -Parent $historyFile), '.local\ai-sessions\history\alpha', $historyFile)) {
            Write-TestFile $externalReport ('範本 `.local\ai-sessions\history\<lineSlug>` 與具體路徑 `' + $concrete + '`')
            try {
                $listed = Invoke-Cleanup @($lineRoot) -Target lines -ClosedLine @('alpha')
                $history = @($listed.Value.items | Where-Object { $_.lineSlug -eq 'alpha' -and $_.category -eq 'history' })[0]
                Assert-True ($history.protectedFileCount -ge 1) "具體路徑應維持保護：$concrete"
                Assert-True (($history.reasons -join '') -like "*$externalReport*") '應指出引用來源'
            }
            finally { Write-TestFile $externalReport $historyFile }
        }
    }
    Test-Case L07 {
        $active = Invoke-Cleanup @($lineRoot) -Target lines -ClosedLine @('alpha') -Sessions @(@{ name = 'alpha'; cwd = $lineRoot })
        $row = @($active.Value.items | Where-Object { $_.lineSlug -eq 'alpha' -and $_.category -eq 'all' })
        Assert-True ($row.Count -eq 1 -and $row[0].status -eq 'protected' -and ($row[0].reasons -join '') -match 'Session')
        $unknown = Invoke-Cleanup @($lineRoot) -Target lines -ClosedLine @('alpha') -Unknown
        Assert-True (-not $unknown.Value.sessionsKnown -and @($unknown.Value.items | Where-Object { $_.lineSlug -eq 'alpha' -and $_.status -eq 'protected' }).Count -gt 0)
    }
    $listed = Invoke-Cleanup @($lineRoot) -Target lines -ClosedLine @('alpha')
    $beforeLines = Get-TreeFingerprint $lineRoot
    Test-Case D01 {
        $result = Invoke-Cleanup @($lineRoot) -Target lines -ClosedLine @('alpha') -ConfirmPlan ('0' * 64)
        Assert-True ($result.ExitCode -eq 3 -and (Get-TreeFingerprint $lineRoot) -ceq $beforeLines)
    }
    Test-Case D03 {
        $added = Join-Path $lineBase 'handoff\alpha\added.txt'
        Write-TestFile $added 'added file'
        $changed = Get-TreeFingerprint $lineRoot
        $result = Invoke-Cleanup @($lineRoot) -Target lines -ClosedLine @('alpha') -ConfirmPlan $listed.Value.planId
        Assert-True ($result.ExitCode -eq 3 -and (Get-TreeFingerprint $lineRoot) -ceq $changed)
        [IO.File]::Delete($added)
    }
    Test-Case D05 {
        $mutex = [Threading.Mutex]::new($false, 'Global\ai-agents-work-overview-cleanup')
        $held = $false
        try {
            $held = $mutex.WaitOne(0)
            Assert-True $held
            $result = Invoke-Cleanup @($lineRoot) -Target lines -ClosedLine @('alpha')
            Assert-True ($result.ExitCode -eq 4)
        }
        finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
    }
    Test-Case D06 {
        $output = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $scriptPath -AsJson 2>&1)
        Assert-True ($LASTEXITCODE -ne 0 -and $output.Count -gt 0)
    }
    Test-Case D04 {
        $outside = Join-Path $tempRoot 'junction-target'
        $null = [IO.Directory]::CreateDirectory($outside)
        $targetFile = Join-Path $outside 'keep.txt'
        Write-TestFile $targetFile 'keep'
        $junction = Join-Path $lineBase 'handoff\alpha\junction'
        $null = New-Item -ItemType Junction -Path $junction -Target $outside
        try {
            $plan = Invoke-Cleanup @($lineRoot) -Target lines -ClosedLine @('alpha')
            $item = @($plan.Value.items | Where-Object { $_.lineSlug -eq 'alpha' -and $_.category -eq 'handoff-extras' })[0]
            Assert-True ($item.protectedFileCount -ge 1 -and ($item.reasons -join '') -match '連結點')
            $deleted = Invoke-Cleanup @($lineRoot) -Target lines -ClosedLine @('alpha') -ConfirmPlan $plan.Value.planId
            Assert-True ($deleted.ExitCode -eq 0 -and (Test-Path -LiteralPath $targetFile))
        }
        finally { if (Test-Path -LiteralPath $junction) { Remove-Item -LiteralPath $junction -Force } }
        Write-TestFile $extraFile 'extra fixture'
        Write-TestFile $selfFile 'self fixture'
        Write-TestFile $oldBackup 'old backup'
        Write-TestFile (Join-Path $lineBase 'report\alpha\large.log') ('log text ' * 5)
    }
    Test-Case Static {
        $text = [IO.File]::ReadAllText($scriptPath)
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0 -and ([regex]::Matches($text, '--force')).Count -eq 0)
        Assert-True ($text -notmatch 'branch\s+-D|worktree\s+remove\s+-f|--force\s+--force|Remove-Item[^\r\n]*-Recurse')
        foreach ($member in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'Delete' }, $true))) {
            $owner = $member.Parent
            while ($null -ne $owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
            Assert-True ($null -ne $owner -and $owner.Name -eq 'Remove-CleanupFiles')
        }
    }
    Test-Case StaticDelete {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        $commandsOf = {
            param($scope)
            @($scope.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        }
        foreach ($name in @('Remove-CleanupPlan', 'Remove-CleanupFiles', 'Confirm-PlannedItem')) {
            $function = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
            Assert-True ($function.Count -eq 1) "找不到函式 $name"
            $commands = & $commandsOf $function[0]
            Assert-True ($commands -notcontains 'Get-CleanupPlan' -and $commands -notcontains 'Get-ReferenceIndex') "$name 不得重算計畫或引用索引"
        }
        $all = & $commandsOf $ast
        Assert-True (@($all | Where-Object { $_ -eq 'Get-CleanupPlan' }).Count -eq 1) '計畫只能在主流程建立一次'
        Assert-True (@($all | Where-Object { $_ -eq 'Get-ReferenceIndex' }).Count -eq 1) '引用索引只能建立一次'
    }
    Test-Case F008Static {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        $functionOf = {
            param($name)
            $found = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
            Assert-True ($found.Count -eq 1) "找不到函式 $name"
            return $found[0]
        }
        $commandsOf = { param($scope) @($scope.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() }) }
        Assert-True ((& $commandsOf (& $functionOf 'Confirm-PlannedItem')) -contains 'Clear-PlanCaches') '確認流程每項都要清除連結點快取'
        Assert-True ((& $commandsOf (& $functionOf 'Get-CleanupPlan')) -contains 'Clear-PlanCaches') '建立計畫時要清除連結點快取'
        Assert-True ((& $functionOf 'Clear-PlanCaches').Extent.Text -match 'ReparseCache') '快取清除須含連結點快取'
    }
    Test-Case F007 {
        $gapRoot = Join-Path $tempRoot 'reference-gap-empty-fixture'
        foreach ($slug in @('with-files', 'no-files')) { New-ClosedLine $gapRoot $slug }
        $gapBase = Join-Path $gapRoot '.local\ai-sessions'
        Write-TestFile (Join-Path $gapBase 'handoff\with-files\extra.txt') 'extra'
        $emptyBackup = Join-Path $gapBase 'backups\20000101_010101'
        $null = [IO.Directory]::CreateDirectory($emptyBackup)
        New-InaccessibleDirectory (Join-Path $gapBase 'inputs\unreadable.')
        $plan = Invoke-Cleanup @($gapRoot) -Target lines -ClosedLine @('with-files', 'no-files') -LargeFileBytes 1048576
        Assert-True ($plan.ExitCode -eq 0) $plan.StdErr
        $withFiles = @($plan.Value.items | Where-Object { $_.lineSlug -eq 'with-files' -and $_.category -eq 'handoff-extras' })
        Assert-True ($withFiles.Count -eq 1 -and $withFiles[0].status -eq 'needs-review' -and ($withFiles[0].reasons -join '') -match '引用來源') '有檔案時仍須因引用來源無法讀取而降為待確認'
        $empty = @($plan.Value.items | Where-Object { $_.lineSlug -eq 'no-files' -and $_.category -in @('history', 'handoff-extras', 'report-logs') })
        Assert-True ($empty.Count -eq 0) "沒有檔案的類別不得產生項目：$($empty | ConvertTo-Json -Compress -Depth 4)"
        $blank = @($plan.Value.items | Where-Object { $_.status -eq 'needs-review' -and $_.fileCount -eq 0 -and $_.protectedFileCount -eq 0 })
        Assert-True ($blank.Count -eq 0) "不得有檔案數為 0 的待確認項目：$($blank | ConvertTo-Json -Compress -Depth 4)"
        Assert-True ($plan.Value.totals.needsReviewCount -eq 1) "待確認數應只計有檔案的項目：$($plan.Value.totals.needsReviewCount)"
        $backup = Get-ItemByPath $plan.Value $emptyBackup
        Assert-True ($backup.status -ne 'needs-review') "沒有檔案的備份不得因引用缺口降為待確認：$($backup.status)"
    }
    Test-Case D02 {
        $plan = Invoke-Cleanup @($lineRoot) -Target lines -ClosedLine @('alpha')
        $result = Invoke-Cleanup @($lineRoot) -Target lines -ClosedLine @('alpha') -ConfirmPlan $plan.Value.planId
        Assert-True ($result.ExitCode -eq 0) $result.StdErr
        Assert-True ($result.Value.result.freedBytes -eq $plan.Value.totals.cleanableBytes)
        foreach ($name in @('line.json', 'requirement-summary.md', 'design.md')) { Assert-True (Test-Path -LiteralPath (Join-Path $lineBase "handoff\alpha\$name")) }
        Assert-True ((Test-Path -LiteralPath $historyFile) -and -not (Test-Path -LiteralPath $selfFile) -and -not (Test-Path -LiteralPath $extraFile))
        Assert-True ((Test-Path -LiteralPath $newBackup) -and (Test-Path -LiteralPath (Join-Path $lineBase 'report\alpha\small.txt')))
    }
    Test-Case L10 {
        $multiRoot = Join-Path $tempRoot 'multi-fixture'
        foreach ($slug in @('multi-a', 'multi-b', 'multi-c')) {
            Write-TestFile (Join-Path $multiRoot ".local\ai-sessions\handoff\$slug\line.json") "{`"line-slug`":`"$slug`"}"
            Write-TestFile (Join-Path $multiRoot ".local\ai-sessions\history\$slug\h.txt") "history $slug"
        }
        $plan = Invoke-Cleanup @($multiRoot) -Target lines -ClosedLine @('multi-a', 'multi-b')
        Assert-True ($plan.ExitCode -eq 0) $plan.StdErr
        foreach ($slug in @('multi-a', 'multi-b')) {
            $row = @($plan.Value.items | Where-Object { $_.lineSlug -eq $slug -and $_.category -eq 'history' })
            Assert-True ($row.Count -eq 1 -and $row[0].status -eq 'cleanable') "$slug 未被視為已結案"
        }
        $other = @($plan.Value.items | Where-Object { $_.lineSlug -eq 'multi-c' })
        Assert-True ($other.Count -eq 1 -and $other[0].category -eq 'all' -and $other[0].status -eq 'protected') 'multi-c 不應被視為已結案'
        $semicolon = Invoke-Cleanup @($multiRoot) -Target lines -ClosedLine @('multi-a;multi-c')
        Assert-True (@($semicolon.Value.items | Where-Object { $_.category -eq 'history' -and $_.status -eq 'cleanable' }).Count -eq 2)
    }
    Test-Case F005 {
        $presRoot = Join-Path $tempRoot 'preserve-fixture'
        New-ClosedLine $presRoot 'keep'
        $presBase = Join-Path $presRoot '.local\ai-sessions'
        $preservedNames = @('cost-ledger.md')
        foreach ($name in $preservedNames) { Write-TestFile (Join-Path $presBase "handoff\keep\$name") "preserved $name" }
        Write-TestFile (Join-Path $presBase 'handoff\keep\extra.txt') 'extra'
        $onlyPreserved = Join-Path $presBase 'backups\20000101_010101'
        $mixed = Join-Path $presBase 'backups\20000102_010101'
        Write-TestFile (Join-Path $onlyPreserved 'cost-ledger.md') 'ledger'
        Write-TestFile (Join-Path $mixed 'cost-ledger.md') 'ledger'
        Write-TestFile (Join-Path $mixed 'old.txt') 'old'
        $plan = Invoke-Cleanup @($presRoot) -Target lines -ClosedLine @('keep')
        Assert-True ($plan.ExitCode -eq 0) $plan.StdErr
        $extras = @($plan.Value.items | Where-Object { $_.lineSlug -eq 'keep' -and $_.category -eq 'handoff-extras' })
        Assert-True ($extras.Count -eq 1 -and $extras[0].status -eq 'cleanable' -and $extras[0].fileCount -eq 1 -and $extras[0].sizeBytes -eq 5) '保留清單檔案不應計入可清檔案與大小'
        $preservedBackup = Get-ItemByPath $plan.Value $onlyPreserved
        Assert-True ($preservedBackup.status -eq 'protected' -and ($preservedBackup.reasons -join '') -match '僅含保留清單檔案')
        $mixedBackup = Get-ItemByPath $plan.Value $mixed
        Assert-True ($mixedBackup.status -eq 'cleanable' -and $mixedBackup.fileCount -eq 1 -and $mixedBackup.sizeBytes -eq 3)
        $result = Invoke-Cleanup @($presRoot) -Target lines -ClosedLine @('keep') -ConfirmPlan $plan.Value.planId
        Assert-True ($result.ExitCode -eq 0) "確認刪除應成功：exit $($result.ExitCode) $($result.StdErr)"
        Assert-True ($result.Value.result.failed.Count -eq 0)
        Assert-True ($result.Value.result.freedBytes -eq $plan.Value.totals.cleanableBytes) "釋出 $($result.Value.result.freedBytes) 與可清 $($plan.Value.totals.cleanableBytes) 不一致"
        foreach ($name in $preservedNames) { Assert-True (Test-Path -LiteralPath (Join-Path $presBase "handoff\keep\$name")) "$name 應保留" }
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $presBase 'handoff\keep\extra.txt')))
        Assert-True ((Test-Path -LiteralPath (Join-Path $mixed 'cost-ledger.md')) -and -not (Test-Path -LiteralPath (Join-Path $mixed 'old.txt')) -and (Test-Path -LiteralPath (Join-Path $onlyPreserved 'cost-ledger.md')))
    }
    try {
        $repo = Join-Path $tempRoot 'main'
        $null = [IO.Directory]::CreateDirectory($repo)
        $null = Invoke-TestGit $repo @('init', '-b', 'main')
        $null = Invoke-TestGit $repo @('config', 'user.name', 'Fixture')
        $null = Invoke-TestGit $repo @('config', 'user.email', 'fixture@example.invalid')
        $null = Invoke-TestGit $repo @('config', 'core.autocrlf', 'false')
        Write-TestFile (Join-Path $repo 'tracked.txt') 'tracked'
        Write-TestFile (Join-Path $repo '.gitignore') ".local/`n"
        $null = Invoke-TestGit $repo @('add', '.gitignore', 'tracked.txt')
        $null = Invoke-TestGit $repo @('commit', '-m', 'fixture')
        $clean = Join-Path $tempRoot 'clean'
        $null = Invoke-TestGit $repo @('worktree', 'add', '-b', 'clean-branch', $clean)
        $before = Get-TreeFingerprint $tempRoot
        $probe = Invoke-Cleanup @($repo, $clean) -Target worktrees
        $after = Get-TreeFingerprint $tempRoot
        Test-Case K02 { Assert-True ($probe.ExitCode -eq 0) $probe.StdErr; Assert-True ($before -ceq $after); Assert-True ($probe.Value.mode -eq 'list') }
        Test-Case K03 { $item = Get-ItemByPath $probe.Value $clean; Assert-True ($item.status -eq 'cleanable') ($item.reasons -join '；'); Assert-True ($item.sizeBytes -gt 0) }
        Test-Case T024w {
            $item = Get-ItemByPath $probe.Value $clean
            Assert-True ($null -eq $item.lineSlug -and $null -eq $item.category) '一般 worktree 的 lineSlug 與 category 應為 null'
            Assert-True ($probe.StdOut -notmatch '"lineSlug":""') 'JSON 不應輸出空字串的 lineSlug'
        }
        $cleanTracked = Join-Path $clean 'tracked.txt'
        Write-TestFile $cleanTracked 'dirty'
        Test-Case K04 {
            $row = Get-ItemByPath (Invoke-Cleanup @($repo, $clean) -Target worktrees).Value $clean
            Assert-True ($row.status -eq 'needs-review' -and ($row.reasons -join '') -match '未 commit')
        }
        Write-TestFile $cleanTracked 'tracked'
        $untrackedFile = Join-Path $clean 'untracked.txt'
        Write-TestFile $untrackedFile 'untracked'
        Test-Case K05 {
            $row = Get-ItemByPath (Invoke-Cleanup @($repo, $clean) -Target worktrees).Value $clean
            Assert-True ($row.status -eq 'needs-review' -and ($row.reasons -join '') -match '未追蹤')
        }
        [IO.File]::Delete($untrackedFile)
        $ahead = Join-Path $tempRoot 'ahead'
        $null = Invoke-TestGit $repo @('worktree', 'add', '-b', 'ahead-branch', $ahead)
        Write-TestFile (Join-Path $ahead 'tracked.txt') 'ahead'
        $null = Invoke-TestGit $ahead @('add', 'tracked.txt')
        $null = Invoke-TestGit $ahead @('commit', '-m', 'ahead fixture')
        Test-Case K06 {
            $row = Get-ItemByPath (Invoke-Cleanup @($repo, $ahead) -Target worktrees).Value $ahead
            Assert-True ($row.status -eq 'needs-review' -and ($row.reasons -join '') -match '未合入')
        }
        $detached = Join-Path $tempRoot 'detached'
        $null = Invoke-TestGit $repo @('worktree', 'add', '--detach', $detached)
        Test-Case K07 { $row = Get-ItemByPath (Invoke-Cleanup @($repo, $detached) -Target worktrees).Value $detached; Assert-True ($row.status -eq 'needs-review') }
        Test-Case K08 {
            $row = Get-ItemByPath (Invoke-Cleanup @($repo, $clean) -Target worktrees -Sessions @(@{ cwd = (Join-Path $clean 'child'); name = 'another' })).Value $clean
            Assert-True ($row.status -eq 'needs-review' -and ($row.reasons -join '') -match 'Session 使用中')
        }
        Test-Case K09 {
            $result = Invoke-Cleanup @($repo, $clean) -Target worktrees -Unknown
            $row = Get-ItemByPath $result.Value $clean
            Assert-True (-not $result.Value.sessionsKnown -and $row.status -eq 'needs-review' -and ($row.reasons -join '') -match '未取得 Session')
        }
        $outerBlocked = Join-Path $tempRoot 'outer-blocked'
        $innerBlocked = Join-Path $outerBlocked '.local\nested\inner-blocked'
        $null = Invoke-TestGit $repo @('worktree', 'add', '-b', 'outer-blocked-branch', $outerBlocked)
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $innerBlocked))
        $null = Invoke-TestGit $repo @('worktree', 'add', '--detach', $innerBlocked)
        Test-Case K11 {
            $row = Get-ItemByPath (Invoke-Cleanup @($repo, $outerBlocked) -Target worktrees).Value $outerBlocked
            Assert-True ($row.status -eq 'needs-review' -and ($row.reasons -join '') -match '內含 1 個無法清理的 worktree')
        }
        $outer = Join-Path $tempRoot 'outer-clean'
        $inner = Join-Path $outer '.local\nested\inner-clean'
        $null = Invoke-TestGit $repo @('worktree', 'add', '-b', 'outer-clean-branch', $outer)
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $inner))
        $null = Invoke-TestGit $repo @('worktree', 'add', '-b', 'inner-clean-branch', $inner)
        New-ClosedLine $repo 'nested'
        New-ClosedLine $outer 'nested'
        Write-TestFile (Join-Path $inner '.local\large.txt') ('n' * 10000)
        Test-Case K11b {
            $plan = (Invoke-Cleanup @($repo, $outer, $inner) -Target worktrees).Value
            $outerRow = Get-ItemByPath $plan $outer
            $innerRow = Get-ItemByPath $plan $inner
            Assert-True ($outerRow.status -eq 'cleanable' -and $innerRow.status -eq 'cleanable') (($outerRow.reasons + $innerRow.reasons) -join '；')
            Assert-True ($outerRow.sizeBytes -lt $innerRow.sizeBytes)
        }
        $locked = Join-Path $tempRoot 'locked'
        $null = Invoke-TestGit $repo @('worktree', 'add', '-b', 'locked-branch', $locked)
        $null = Invoke-TestGit $repo @('worktree', 'lock', $locked)
        Test-Case K12 { $row = Get-ItemByPath (Invoke-Cleanup @($repo, $locked) -Target worktrees).Value $locked; Assert-True ($row.status -eq 'needs-review' -and ($row.reasons -join '') -match '鎖定') }
        New-ClosedLine $clean 'k13'
        Test-Case K13 {
            $row = Get-ItemByPath (Invoke-Cleanup @($repo, $clean) -Target worktrees -ClosedLine @('k13')).Value $clean
            Assert-True ($row.status -eq 'needs-review' -and ($row.reasons -join '') -match '未保存')
        }
        Write-TestFile (Join-Path $clean '.local\ai-sessions\inputs\keep.txt') 'keep'
        Test-Case K14 { $row = Get-ItemByPath (Invoke-Cleanup @($repo, $clean) -Target worktrees).Value $clean; Assert-True ($row.status -eq 'needs-review' -and ($row.reasons -join '') -match '含需保留素材') }
        New-ClosedLine $repo 'done'
        Write-TestFile (Join-Path $repo '.local\ai-sessions\handoff\pending\line.json') '{"line-slug":"pending"}'
        Write-TestFile (Join-Path $repo '.local\ai-sessions\history\done\fixture.txt') 'history fixture'
        Write-TestFile (Join-Path $repo '.local\ai-sessions\handoff\done\extra.txt') 'handoff fixture'
        Write-TestFile (Join-Path $repo '.local\ai-sessions\report\done\large.log') ('report fixture ' * 5)
        Test-Case L01 {
            $plan = (Invoke-Cleanup @($repo) -Target lines).Value
            foreach ($category in @('history', 'handoff-extras', 'report-logs')) {
                $rows = @($plan.items | Where-Object { $_.lineSlug -eq 'done' -and $_.category -eq $category -and $_.status -eq 'cleanable' })
                Assert-True ($rows.Count -eq 1 -and $rows[0].fileCount -gt 0 -and $rows[0].sizeBytes -gt 0) "缺少類別 $category；$((@($plan.items | Where-Object { $_.lineSlug -eq 'done' }) | ConvertTo-Json -Compress -Depth 5))"
            }
        }
        Test-Case L02 {
            $plan = Invoke-Cleanup @($repo) -Target lines
            Assert-True ($plan.ExitCode -eq 0)
            foreach ($reserved in @('line.json', 'requirement-summary.md', 'design.md')) { Assert-True (Test-Path -LiteralPath (Join-Path $repo ".local\ai-sessions\handoff\done\$reserved")) }
        }
        Test-Case L03 {
            New-ClosedLine $repo 'recent'
            (Get-Item -LiteralPath (Join-Path $repo '.local\ai-sessions\report\recent\handoff-checkpoint.md')).LastWriteTimeUtc = [DateTime]::UtcNow
            New-ClosedLine $repo 'design-only'
            Write-TestFile (Join-Path $repo '.local\ai-sessions\report\design-only\handoff-checkpoint.md') '- 檢查點類型：design-accepted'
            $null = Invoke-TestGit $repo @('branch', 'feature/unmerged-line', 'ahead-branch')
            New-ClosedLine $repo 'unmerged-line'
            $plan = (Invoke-Cleanup @($repo) -Target lines -Sessions @(@{ name = 'done'; cwd = $repo })).Value
            foreach ($slug in @('pending', 'recent', 'design-only', 'unmerged-line', 'done')) {
                Assert-True (@($plan.items | Where-Object { $_.lineSlug -eq $slug -and $_.category -eq 'all' -and $_.status -eq 'protected' }).Count -eq 1) "線未受保護：$slug"
            }
            $linkedPlan = (Invoke-Cleanup @($repo, $clean) -Target lines).Value
            Assert-True (@($linkedPlan.items | Where-Object { $_.lineSlug -eq 'k13' -and $_.category -eq 'all' -and $_.status -eq 'protected' }).Count -eq 1)
            $unknownPlan = (Invoke-Cleanup @($repo) -Target lines -Unknown).Value
            Assert-True (@($unknownPlan.items | Where-Object { $_.lineSlug -eq 'done' -and $_.category -eq 'all' -and $_.status -eq 'protected' }).Count -eq 1)
        }
        Test-Case D08 {
            $plan = Invoke-Cleanup @($outer, $inner) -Target worktrees
            $outerRow = Get-ItemByPath $plan.Value $outer
            $innerRow = Get-ItemByPath $plan.Value $inner
            Assert-True ($outerRow.status -eq 'cleanable' -and $innerRow.status -eq 'cleanable')
            $result = Invoke-Cleanup @($outer, $inner) -Target worktrees -ConfirmPlan $plan.Value.planId
            Assert-True ($result.ExitCode -eq 0) $result.StdErr
            $ids = @($result.Value.result.deleted.id)
            Assert-True ([array]::IndexOf($ids, $innerRow.id) -lt [array]::IndexOf($ids, $outerRow.id))
            Assert-True (-not (Test-Path -LiteralPath $inner) -and -not (Test-Path -LiteralPath $outer))
            Assert-True ($result.Value.result.freedBytes -eq $plan.Value.totals.cleanableBytes)
            Assert-True ([string]::IsNullOrWhiteSpace((Invoke-TestGit $repo @('branch', '--list', 'outer-clean-branch', 'inner-clean-branch'))))
        }
        Test-Case D08Failure {
            $outerFail = Join-Path $tempRoot 'outer-failure'
            $innerFail = Join-Path $outerFail '.local\nested\inner-failure'
            $null = Invoke-TestGit $repo @('worktree', 'add', '-b', 'outer-failure-branch', $outerFail)
            $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $innerFail))
            $null = Invoke-TestGit $repo @('worktree', 'add', '-b', 'inner-failure-branch', $innerFail)
            New-ClosedLine $outerFail 'nested'
            $lockedFile = Join-Path $innerFail '.local\locked.txt'
            Write-TestFile $lockedFile 'locked'
            $plan = Invoke-Cleanup @($outerFail, $innerFail) -Target worktrees
            $outerRow = Get-ItemByPath $plan.Value $outerFail
            $innerRow = Get-ItemByPath $plan.Value $innerFail
            Assert-True ($outerRow.status -eq 'cleanable' -and $innerRow.status -eq 'cleanable') "計畫列：outer=$($outerRow.status) $($outerRow.reasons -join '；') inner=$($innerRow.status) $($innerRow.reasons -join '；')"
            $lock = [IO.File]::Open($lockedFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
            try {
                $result = Invoke-Cleanup @($outerFail, $innerFail) -Target worktrees -ConfirmPlan $plan.Value.planId
                Assert-True ($result.ExitCode -eq 2) "結束碼 $($result.ExitCode)：$($result.StdOut) $($result.StdErr)"
                Assert-True (@($result.Value.result.failed | Where-Object { $_.id -eq $outerRow.id -and $_.reason -eq '狀態已變更' }).Count -eq 1) "失敗清單：$($result.Value.result.failed | ConvertTo-Json -Compress)"
                Assert-True (Test-Path -LiteralPath $outerFail)
            }
            finally { $lock.Dispose() }
        }
        Test-Case F003w {
            $gapWorktree = Join-Path $tempRoot 'gap-worktree'
            $null = Invoke-TestGit $repo @('worktree', 'add', '-b', 'gap-worktree-branch', $gapWorktree)
            $control = Get-ItemByPath (Invoke-Cleanup @($repo, $gapWorktree) -Target worktrees).Value $gapWorktree
            Assert-True ($control.status -eq 'cleanable') "對照組應為可清：$($control.reasons -join '；')"
            New-InaccessibleDirectory (Join-Path $gapWorktree '.local\unreadable.')
            $plan = Invoke-Cleanup @($repo, $gapWorktree) -Target worktrees
            Assert-True ($plan.ExitCode -eq 0) "無法讀取的子目錄不應使整份計畫失敗：$($plan.StdErr)"
            $row = Get-ItemByPath $plan.Value $gapWorktree
            Assert-True ($row.status -eq 'needs-review' -and ($row.reasons -join '') -match '無法讀取') "應降級為待確認：$($row.status) $($row.reasons -join '；')"
        }
    }
    catch {
        $script:failed++
        Write-Output "BLOCKED Git 夾具：$($_.Exception.Message)"
        $expected = @(2..9 | ForEach-Object { 'K{0:D2}' -f $_ }) + @('K11', 'K11b', 'K12', 'K13', 'K14', 'T024w', 'L01', 'L02', 'L03', 'D08', 'D08Failure', 'F003w')
        $unexecuted = @($expected | Where-Object { -not $script:executed.Contains($_) })
        Write-Output "未執行：$($unexecuted -join '、')。"
    }
    Test-Case F003 {
        $gapRoot = Join-Path $tempRoot 'gap-fixture'
        foreach ($slug in @('gap', 'fine')) { New-ClosedLine $gapRoot $slug }
        $gapBase = Join-Path $gapRoot '.local\ai-sessions'
        Write-TestFile (Join-Path $gapBase 'history\gap\ok.txt') 'ok'
        New-InaccessibleDirectory (Join-Path $gapBase 'history\gap\unreadable.')
        Write-TestFile (Join-Path $gapBase 'handoff\fine\extra.txt') 'extra'
        Write-TestFile (Join-Path $gapBase 'backups\20000101_010101\old.txt') 'old'
        New-InaccessibleDirectory (Join-Path $gapBase 'backups\20000102_010101\unreadable.')
        $plan = Invoke-Cleanup @($gapRoot) -Target lines -ClosedLine @('gap', 'fine')
        Assert-True ($plan.ExitCode -eq 0) "無法讀取的子目錄不應使整份計畫失敗：$($plan.StdErr)"
        $history = @($plan.Value.items | Where-Object { $_.lineSlug -eq 'gap' -and $_.category -eq 'history' })
        Assert-True ($history.Count -eq 1 -and $history[0].status -eq 'needs-review' -and ($history[0].reasons -join '') -match '無法讀取' -and $history[0].sizeBytes -eq 2) "history 項目應待確認且大小忽略無法存取項目：$($history | ConvertTo-Json -Compress)"
        $fine = @($plan.Value.items | Where-Object { $_.lineSlug -eq 'fine' -and $_.category -eq 'handoff-extras' })
        Assert-True ($fine.Count -eq 1 -and $fine[0].status -eq 'cleanable') '其他線的項目應照常列出'
        $unreadableBackup = Get-ItemByPath $plan.Value (Join-Path $gapBase 'backups\20000102_010101')
        Assert-True ($unreadableBackup.status -eq 'needs-review' -and ($unreadableBackup.reasons -join '') -match '無法讀取')
        Assert-True ((Get-ItemByPath $plan.Value (Join-Path $gapBase 'backups\20000101_010101')).status -eq 'cleanable')
        $result = Invoke-Cleanup @($gapRoot) -Target lines -ClosedLine @('gap', 'fine') -ConfirmPlan $plan.Value.planId
        Assert-True ($result.ExitCode -eq 0) "確認刪除應成功：exit $($result.ExitCode) $($result.StdErr)"
        Assert-True ((Test-Path -LiteralPath (Join-Path $gapBase 'history\gap\ok.txt')) -and -not (Test-Path -LiteralPath (Join-Path $gapBase 'handoff\fine\extra.txt'))) '待確認項目不得刪除，可清項目應刪除'
        $referenceRoot = Join-Path $tempRoot 'reference-gap-fixture'
        New-ClosedLine $referenceRoot 'refgap'
        Write-TestFile (Join-Path $referenceRoot '.local\ai-sessions\handoff\refgap\extra.txt') 'extra'
        New-InaccessibleDirectory (Join-Path $referenceRoot '.local\ai-sessions\inputs\unreadable.')
        $referencePlan = Invoke-Cleanup @($referenceRoot) -Target lines -ClosedLine @('refgap')
        Assert-True ($referencePlan.ExitCode -eq 0) $referencePlan.StdErr
        $extras = @($referencePlan.Value.items | Where-Object { $_.lineSlug -eq 'refgap' -and $_.category -eq 'handoff-extras' })
        Assert-True ($extras.Count -eq 1 -and $extras[0].status -eq 'needs-review' -and ($extras[0].reasons -join '') -match '引用來源') '引用來源無法讀取時不得列為可清'
    }
}
finally {
    foreach ($gap in $script:gapDirectories) { try { [IO.Directory]::Delete($gap, $false) } catch { Write-Output "WARN 無法移除測試用目錄 $gap" } }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
Write-Output "TOTAL pass=$script:passed fail=$script:failed"
if ($script:failed -gt 0) { exit 1 }
exit 0
