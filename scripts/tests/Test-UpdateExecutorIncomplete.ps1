#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$script = Join-Path $scriptsRoot 'Update-ExecutorIncomplete.ps1'
$selector = Join-Path $scriptsRoot 'Select-DispatchExecutor.ps1'
. (Join-Path $PSScriptRoot 'codex-run-fixtures\TestHelpers.ps1')

function Invoke-Concurrent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Script, [Parameter(Mandatory)][object[]]$ArgumentSet)

    # 同時啟動多個行程再一起等待，回傳各自的結束碼與 stderr。
    $items = foreach ($set in $ArgumentSet) {
        $out = Join-Path (Get-TestTempRoot) ('cc-' + [guid]::NewGuid().ToString('N') + '.txt')
        $process = Start-Process -FilePath 'pwsh' -ArgumentList (@('-NoProfile', '-File', $Script) + @($set)) -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError ($out + '.err')
        [pscustomobject]@{ Process = $process; Out = $out }
    }
    foreach ($item in $items) { $item.Process.WaitForExit() }
    return @($items | ForEach-Object {
            $stderr = if ([IO.File]::Exists($_.Out + '.err')) { [IO.File]::ReadAllText($_.Out + '.err') } else { '' }
            foreach ($file in @($_.Out, ($_.Out + '.err'))) { if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } }
            [pscustomobject]@{ Code = $_.Process.ExitCode; Stderr = $stderr }
        })
}

function Invoke-Incomplete {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Argument)

    $stderrPath = Join-Path (Get-TestTempRoot) ('inc-stderr-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        $stdout = @(& pwsh -NoProfile -File $script @Argument 2>$stderrPath)
        $code = $LASTEXITCODE
        $stderr = if ([IO.File]::Exists($stderrPath)) { [IO.File]::ReadAllText($stderrPath) } else { '' }
    }
    finally { if ([IO.File]::Exists($stderrPath)) { [IO.File]::Delete($stderrPath) } }
    $text = ($stdout | ForEach-Object { [string]$_ }) -join "`n"
    $json = $null
    if (-not [string]::IsNullOrWhiteSpace($text)) { try { $json = ConvertFrom-Json -InputObject $text } catch { $json = $null } }
    return [pscustomobject]@{ Code = $code; Json = $json; Stderr = $stderr }
}

try {
    $workRoot = New-TestDirectory -Name 'incomplete'
    $sessions = Join-Path $workRoot '.local\ai-sessions'
    $null = New-Item -ItemType Directory -Path (Join-Path $sessions 'handoff\line-a') -Force
    Write-TestUtf8 -Path (Join-Path $sessions 'handoff\line-a\line.json') -Text '{"line-slug":"line-a"}'
    $common = @('-WorkRoot', $workRoot, '-LineSlug', 'line-a')
    $filePath = Join-Path $sessions 'report\line-a\executor-incomplete.json'
    function Add-One { [CmdletBinding()] param([string]$Task = 'impl', [string]$Executor = 'haiku') return (Invoke-Incomplete ($common + @('-Action', 'Add', '-Task', $Task, '-ExecutorId', $Executor, '-Reason', 'acceptance-failed', '-Evidence', 'report.md:12'))) }

    Test-Case 'INC-SHOW-EMPTY 沒有紀錄時輸出空值並標示不必帶參數，且不建立檔案' {
        $result = Invoke-Incomplete ($common + @('-Action', 'Show', '-Task', 'impl'))
        Assert-Equal 0 $result.Code $result.Stderr
        Assert-True ($null -eq $result.Json.incomplete_argument)
        Assert-Equal $false $result.Json.pass_incomplete
        Assert-True ($result.Json.note -like '*不必帶 -Incomplete*')
        Assert-True (-not [IO.File]::Exists($filePath))
    }
    Test-Case 'INC-ADD 加一次後次數為 1，檔案落在線的 report 目錄並記錄原因與證據' {
        $result = Add-One
        Assert-Equal 0 $result.Code $result.Stderr
        Assert-Equal 'haiku:1' $result.Json.incomplete_argument
        Assert-Equal $true $result.Json.pass_incomplete
        Assert-True ([IO.File]::Exists($filePath))
        $stored = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json
        Assert-Equal 'line-a' $stored.line_slug
        Assert-Equal 'acceptance-failed' $stored.tasks.impl.events[0].reason
        Assert-Equal 'report.md:12' $stored.tasks.impl.events[0].evidence
    }
    Test-Case 'INC-ORDER 同一任務多位執行者的輸出順序固定為執行者 id 的序數排序，與加入順序無關' {
        $null = Add-One -Executor 'sonnet'
        $null = Add-One -Executor 'haiku'
        $null = Add-One -Executor 'opus'
        $result = Invoke-Incomplete ($common + @('-Action', 'Show', '-Task', 'impl'))
        Assert-Equal 'haiku:2,opus:1,sonnet:1' $result.Json.incomplete_argument
        Assert-Equal @('haiku', 'opus', 'sonnet') @($result.Json.counts | ForEach-Object { $_.executor })
    }
    Test-Case 'INC-TASKS 一條線的多個任務各自計次' {
        $other = Add-One -Task 'review'
        Assert-Equal 'haiku:1' $other.Json.incomplete_argument
        $impl = Invoke-Incomplete ($common + @('-Action', 'Show', '-Task', 'impl'))
        Assert-Equal 'haiku:2,opus:1,sonnet:1' $impl.Json.incomplete_argument
    }
    Test-Case 'INC-SELECTOR 輸出值可直接作為選派入口的 -Incomplete' {
        $shown = Invoke-Incomplete ($common + @('-Action', 'Show', '-Task', 'impl'))
        $output = @(& pwsh -NoProfile -File $selector -Type edit -E true -T false -Incomplete $shown.Json.incomplete_argument 2>&1)
        Assert-Equal 0 $LASTEXITCODE (($output | ForEach-Object { [string]$_ }) -join "`n")
        $selection = (($output | ForEach-Object { [string]$_ }) -join "`n") | ConvertFrom-Json
        Assert-True ($selection.status -in @('selected', 'needs-user-decision', 'stopped'))
    }
    Test-Case 'INC-RESET 重設後該任務次數歸零，其他任務不受影響' {
        $reset = Invoke-Incomplete ($common + @('-Action', 'Reset', '-Task', 'impl'))
        Assert-Equal 0 $reset.Code $reset.Stderr
        Assert-True ($null -eq $reset.Json.incomplete_argument)
        Assert-Equal $false $reset.Json.pass_incomplete
        $shown = Invoke-Incomplete ($common + @('-Action', 'Show', '-Task', 'impl'))
        Assert-True ($null -eq $shown.Json.incomplete_argument)
        $other = Invoke-Incomplete ($common + @('-Action', 'Show', '-Task', 'review'))
        Assert-Equal 'haiku:1' $other.Json.incomplete_argument
        $again = Add-One
        Assert-Equal 'haiku:1' $again.Json.incomplete_argument
    }
    Test-Case 'INC-UNKNOWN-EXECUTOR 未知執行者 id 以結束碼 2 拒絕且不改檔' {
        $before = [IO.File]::ReadAllText($filePath)
        $result = Add-One -Executor 'nobody'
        Assert-Equal 2 $result.Code
        Assert-True ($result.Stderr -like '*IncompleteExecutorUnknown*')
        Assert-Equal $before ([IO.File]::ReadAllText($filePath))
    }
    Test-Case 'INC-ADD-MISSING-PARAM Add 缺 ExecutorId、Reason 或 Evidence 時以結束碼 2 拒絕；Show 帶這些參數也拒絕' {
        $result = Invoke-Incomplete ($common + @('-Action', 'Add', '-Task', 'impl', '-ExecutorId', 'haiku', '-Reason', 'collect-returned'))
        Assert-Equal 2 $result.Code
        Assert-True ($result.Stderr -like '*IncompleteParameterMissing*')
        $result = Invoke-Incomplete ($common + @('-Action', 'Show', '-Task', 'impl', '-ExecutorId', 'haiku'))
        Assert-Equal 2 $result.Code
    }
    Test-Case 'INC-LINE-MISMATCH line.json 的 line-slug 不符時拒絕' {
        $null = New-Item -ItemType Directory -Path (Join-Path $sessions 'handoff\line-b') -Force
        Write-TestUtf8 -Path (Join-Path $sessions 'handoff\line-b\line.json') -Text '{"line-slug":"other"}'
        $result = Invoke-Incomplete @('-Action', 'Show', '-WorkRoot', $workRoot, '-LineSlug', 'line-b', '-Task', 'impl')
        Assert-Equal 2 $result.Code
        Assert-True ($result.Stderr -like '*IncompleteLineManifestMismatch*')
    }
    Test-Case 'INC-LINE-MISSING 沒有 line.json 的線一律以結束碼 2 拒絕並指出要先登記，Add、Show、Reset 皆不建立檔案；登記為 adhoc 線後可用' {
        $adhocFile = Join-Path $sessions 'report\adhoc-x\executor-incomplete.json'
        foreach ($mode in @(@('-Action', 'Add', '-ExecutorId', 'sonnet', '-Reason', 'self-reported', '-Evidence', 'cmd output'), @('-Action', 'Show'), @('-Action', 'Reset'))) {
            $result = Invoke-Incomplete ($mode + @('-WorkRoot', $workRoot, '-LineSlug', 'adhoc-x', '-Task', 'one'))
            Assert-Equal 2 $result.Code ($mode -join ' ')
            Assert-True ($result.Stderr -like '*IncompleteLineManifestMissing*' -and $result.Stderr -like '*adhoc*')
        }
        Assert-True (-not [IO.File]::Exists($adhocFile))
        $null = New-Item -ItemType Directory -Path (Join-Path $sessions 'handoff\adhoc-x') -Force
        Write-TestUtf8 -Path (Join-Path $sessions 'handoff\adhoc-x\line.json') -Text '{"line-slug":"adhoc-x","kind":"adhoc"}'
        $registered = Invoke-Incomplete @('-Action', 'Add', '-WorkRoot', $workRoot, '-LineSlug', 'adhoc-x', '-Task', 'one', '-ExecutorId', 'sonnet', '-Reason', 'self-reported', '-Evidence', 'cmd output')
        Assert-Equal 0 $registered.Code $registered.Stderr
        Assert-Equal 'sonnet:1' $registered.Json.incomplete_argument
        Assert-True ([IO.File]::Exists($adhocFile))
    }
    Test-Case 'INC-PARALLEL 同時多個 Add 不遺失次數與事件，不同任務也互不覆蓋' {
        $null = New-Item -ItemType Directory -Path (Join-Path $sessions 'handoff\line-c') -Force
        Write-TestUtf8 -Path (Join-Path $sessions 'handoff\line-c\line.json') -Text '{"line-slug":"line-c"}'
        $parallelFile = Join-Path $sessions 'report\line-c\executor-incomplete.json'
        $argumentSet = @()
        foreach ($index in 1..4) { $argumentSet += , @('-Action', 'Add', '-WorkRoot', $workRoot, '-LineSlug', 'line-c', '-Task', 'impl', '-ExecutorId', 'haiku', '-Reason', 'acceptance-failed', '-Evidence', ('e' + $index)) }
        foreach ($index in 1..3) { $argumentSet += , @('-Action', 'Add', '-WorkRoot', $workRoot, '-LineSlug', 'line-c', '-Task', 'review', '-ExecutorId', 'sonnet', '-Reason', 'review-rejected', '-Evidence', ('r' + $index)) }
        $results = Invoke-Concurrent $script $argumentSet
        Assert-Equal 7 @($results | Where-Object { $_.Code -eq 0 }).Count (($results | ForEach-Object { [string]$_.Code + ' ' + $_.Stderr }) -join "`n")
        $stored = Get-Content -LiteralPath $parallelFile -Raw | ConvertFrom-Json
        Assert-Equal 4 $stored.tasks.impl.counts.haiku
        Assert-Equal 4 @($stored.tasks.impl.events).Count
        Assert-Equal 3 $stored.tasks.review.counts.sonnet
        Assert-Equal 3 @($stored.tasks.review.events).Count
    }
    Test-Case 'INC-INNER-CORRUPT 內層結構損毀（counts、次數、events）一律拒絕且原檔逐字不變，Show、Add、Reset 皆然' {
        $null = New-Item -ItemType Directory -Path (Join-Path $sessions 'handoff\line-d') -Force
        Write-TestUtf8 -Path (Join-Path $sessions 'handoff\line-d\line.json') -Text '{"line-slug":"line-d"}'
        $corruptFile = Join-Path $sessions 'report\line-d\executor-incomplete.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $corruptFile) -Force
        $cases = @(
            '{"schema":"ai-agents.executor-incomplete.v1","line_slug":"line-d","tasks":{"impl":{"counts":null,"events":[]}}}',
            '{"schema":"ai-agents.executor-incomplete.v1","line_slug":"line-d","tasks":{"impl":{"counts":[1],"events":[]}}}',
            '{"schema":"ai-agents.executor-incomplete.v1","line_slug":"line-d","tasks":{"impl":{"counts":{"haiku":-1},"events":[]}}}',
            '{"schema":"ai-agents.executor-incomplete.v1","line_slug":"line-d","tasks":{"impl":{"counts":{"haiku":"2"},"events":[]}}}',
            '{"schema":"ai-agents.executor-incomplete.v1","line_slug":"line-d","tasks":{"impl":{"counts":{"haiku":1},"events":"x"}}}',
            '{"schema":"ai-agents.executor-incomplete.v1","line_slug":"line-d","tasks":{"impl":{"counts":{"haiku":1},"events":[1]}}}',
            '{"schema":"ai-agents.executor-incomplete.v1","line_slug":"line-d","tasks":{"impl":"x"}}',
            '{"schema":"ai-agents.executor-incomplete.v1","line_slug":"line-d","tasks":{"other":{"counts":{"haiku":1}}}}'
        )
        $base = @('-WorkRoot', $workRoot, '-LineSlug', 'line-d', '-Task', 'impl')
        foreach ($text in $cases) {
            Write-TestUtf8 -Path $corruptFile -Text $text
            $before = [IO.File]::ReadAllText($corruptFile)
            foreach ($mode in @(@('-Action', 'Show'), @('-Action', 'Add', '-ExecutorId', 'haiku', '-Reason', 'acceptance-failed', '-Evidence', 'x'), @('-Action', 'Reset'))) {
                $result = Invoke-Incomplete ($base + $mode)
                Assert-Equal 2 $result.Code ($text + ' / ' + ($mode -join ' '))
                Assert-True ($result.Stderr -like '*IncompleteFileInvalid*')
                Assert-Equal $before ([IO.File]::ReadAllText($corruptFile))
            }
        }
    }
    Test-Case 'INC-BAD-SLUG 無效的 LineSlug、Task 與損毀檔案以結束碼 2 拒絕' {
        Assert-Equal 2 (Invoke-Incomplete @('-Action', 'Show', '-WorkRoot', $workRoot, '-LineSlug', 'Bad_Slug', '-Task', 'impl')).Code
        Assert-Equal 2 (Invoke-Incomplete ($common + @('-Action', 'Show', '-Task', 'Bad Task'))).Code
        Write-TestUtf8 -Path $filePath -Text '{ not json'
        $result = Invoke-Incomplete ($common + @('-Action', 'Show', '-Task', 'impl'))
        Assert-Equal 2 $result.Code
        Assert-True ($result.Stderr -like '*IncompleteFileInvalid*')
        Assert-Equal '{ not json' ([IO.File]::ReadAllText($filePath))
    }
}
finally {
    $exitCode = Complete-TestRun
}
exit $exitCode
