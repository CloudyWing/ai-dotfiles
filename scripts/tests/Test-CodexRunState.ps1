#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$moduleRoot = Join-Path $scriptsRoot 'codex-run'
. (Join-Path $PSScriptRoot 'codex-run-fixtures\TestHelpers.ps1')
foreach ($module in @('00-common.ps1', '50-source-state.ps1', '60-ledger.ps1')) { . (Join-Path $moduleRoot $module) }

function Get-LedgerDataRow {
    param([string]$Path)
    return , @(Get-Content -LiteralPath $Path | Where-Object { $_.StartsWith('| ', [StringComparison]::Ordinal) -and $_ -notmatch '^\| ---' -and -not $_.StartsWith('| 時間（UTC）', [StringComparison]::Ordinal) })
}
function Split-LedgerRow {
    param([string]$Row)
    $inner = $Row.Substring(2, $Row.Length - 4)
    return @([regex]::Split($inner, '(?<!\\) \| '))
}

try {
    $root = New-TestDirectory -Name 'state'

    # ---------- 被審內容雜湊：git 模式 ----------
    $repo = New-TestGitRepository -Directory $root -WithWorktree
    $srcDirectory = Join-Path $repo.Root 'src'
    $null = New-Item -ItemType Directory -Path $srcDirectory -Force
    Write-TestUtf8 -Path (Join-Path $srcDirectory 'a.txt') -Text "alpha`n"
    $null = Invoke-TestGit -WorkingDirectory $repo.Root -Argument @('add', '-A')
    $null = Invoke-TestGit -WorkingDirectory $repo.Root -Argument @('commit', '-q', '-m', 'add src')
    $headOfRepo = (@(Invoke-TestGit -WorkingDirectory $repo.Root -Argument @('rev-parse', 'HEAD'))[0]).Trim()
    $targets = @($srcDirectory + '\')

    Test-Case 'STATE-GIT 目標在 git repo 內時 mode=git，記 HEAD 與差異雜湊，未變動時兩次相同' {
        $first = Get-RunSourceState -ExecutionRoot $repo.Root -Target $targets
        $second = Get-RunSourceState -ExecutionRoot $repo.Root -Target $targets
        Assert-Equal 'git' $first.mode
        Assert-Equal $headOfRepo $first.head
        Assert-True ($first.diff_sha256 -cmatch '^[0-9a-f]{64}$') 'diff_sha256 格式'
        Assert-True ($null -eq $first.content_sha256) '不適用的欄位應為 null'
        Assert-Equal ($first | ConvertTo-Json -Compress) ($second | ConvertTo-Json -Compress)
    }
    Test-Case 'STATE-GIT-CHANGE 改動追蹤檔、新增未追蹤檔、暫存變更都改變雜湊；機密樣式的未追蹤檔不納入' {
        $base = Get-RunSourceState -ExecutionRoot $repo.Root -Target $targets
        Write-TestUtf8 -Path (Join-Path $srcDirectory 'a.txt') -Text "alpha changed`n"
        $modified = Get-RunSourceState -ExecutionRoot $repo.Root -Target $targets
        Assert-True ($modified.diff_sha256 -cne $base.diff_sha256) '改動追蹤檔應改變雜湊'
        Assert-Equal $base.head $modified.head
        Write-TestUtf8 -Path (Join-Path $srcDirectory 'new.txt') -Text "new`n"
        $withUntracked = Get-RunSourceState -ExecutionRoot $repo.Root -Target $targets
        Assert-True ($withUntracked.diff_sha256 -cne $modified.diff_sha256) '新增未追蹤檔應改變雜湊'
        Write-TestUtf8 -Path (Join-Path $srcDirectory '.env') -Text 'SECRET=1'
        $withEnv = Get-RunSourceState -ExecutionRoot $repo.Root -Target $targets
        Assert-Equal $withUntracked.diff_sha256 $withEnv.diff_sha256 '.env 不應納入雜湊'
        Write-TestUtf8 -Path (Join-Path $srcDirectory 'new.txt') -Text "new edited`n"
        Assert-True ((Get-RunSourceState -ExecutionRoot $repo.Root -Target $targets).diff_sha256 -cne $withEnv.diff_sha256) '改動未追蹤檔內容應改變雜湊'
        $null = Invoke-TestGit -WorkingDirectory $repo.Root -Argument @('checkout', '--', 'src/a.txt')
        Remove-Item -LiteralPath (Join-Path $srcDirectory 'new.txt'), (Join-Path $srcDirectory '.env') -Force
        Assert-Equal $base.diff_sha256 (Get-RunSourceState -ExecutionRoot $repo.Root -Target $targets).diff_sha256 '還原後應回到原雜湊'
    }
    Test-Case 'STATE-GIT-SCOPE 範圍外的變動不改變雜湊' {
        $base = Get-RunSourceState -ExecutionRoot $repo.Root -Target $targets
        Write-TestUtf8 -Path (Join-Path $repo.Root 'readme.txt') -Text "outside the targets`n"
        Assert-Equal $base.diff_sha256 (Get-RunSourceState -ExecutionRoot $repo.Root -Target $targets).diff_sha256
        $null = Invoke-TestGit -WorkingDirectory $repo.Root -Argument @('checkout', '--', 'readme.txt')
    }
    Test-Case 'STATE-GIT-WORKTREE 執行目錄為 linked worktree 時以該 worktree 的 HEAD 與差異為準' {
        $null = Invoke-TestGit -WorkingDirectory $repo.Root -Argument @('worktree', 'remove', '--force', $repo.Worktree)
        $worktree = Join-Path $root 'wt2'
        $null = Invoke-TestGit -WorkingDirectory $repo.Root -Argument @('worktree', 'add', '-q', '-b', 'line2', $worktree)
        $wtTargets = @((Join-Path $worktree 'src\'))
        $state = Get-RunSourceState -ExecutionRoot $worktree -Target $wtTargets
        Assert-Equal 'git' $state.mode
        Assert-Equal $headOfRepo $state.head
        Write-TestUtf8 -Path (Join-Path $worktree 'src\a.txt') -Text "changed in worktree`n"
        Assert-True ((Get-RunSourceState -ExecutionRoot $worktree -Target $wtTargets).diff_sha256 -cne $state.diff_sha256) 'worktree 內的改動應改變雜湊'
    }

    # ---------- 被審內容雜湊：content 模式 ----------
    $plain = New-TestDirectory -Name 'plain'
    Write-TestUtf8 -Path (Join-Path $plain 'a.txt') -Text "alpha`n"
    Write-TestUtf8 -Path (Join-Path $plain 'sub\b.txt') -Text "bravo`n"
    Write-TestUtf8 -Path (Join-Path $plain '.env') -Text 'SECRET=1'
    $plainTargets = @(($plain + '\'))
    Test-Case 'STATE-CONTENT 非 Git 來源以內容雜湊記錄，.env 與其他機密樣式不納入，改動一般檔會改變雜湊' {
        $base = Get-RunSourceState -ExecutionRoot $plain -Target $plainTargets
        Assert-Equal 'content' $base.mode
        Assert-True ($null -eq $base.head -and $null -eq $base.diff_sha256) 'git 欄位應為 null'
        Assert-True ($base.content_sha256 -cmatch '^[0-9a-f]{64}$') 'content_sha256 格式'
        Write-TestUtf8 -Path (Join-Path $plain '.env') -Text 'SECRET=changed'
        Write-TestUtf8 -Path (Join-Path $plain 'k.pem') -Text 'pem'
        Write-TestUtf8 -Path (Join-Path $plain 'sub\secrets.json') -Text '{}'
        Assert-Equal $base.content_sha256 (Get-RunSourceState -ExecutionRoot $plain -Target $plainTargets).content_sha256 '機密樣式的改動不應影響雜湊'
        Write-TestUtf8 -Path (Join-Path $plain 'a.txt') -Text "alpha edited`n"
        Assert-True ((Get-RunSourceState -ExecutionRoot $plain -Target $plainTargets).content_sha256 -cne $base.content_sha256) '改動一般檔應改變雜湊'
        Write-TestUtf8 -Path (Join-Path $plain 'a.txt') -Text "alpha`n"
        Write-TestUtf8 -Path (Join-Path $plain 'sub\c.txt') -Text "charlie`n"
        Assert-True ((Get-RunSourceState -ExecutionRoot $plain -Target $plainTargets).content_sha256 -cne $base.content_sha256) '新增一般檔應改變雜湊'
    }
    Test-Case 'STATE-CONTENT-FILE-TARGET 目標為單一檔案時記該檔雜湊' {
        $file = Join-Path $plain 'a.txt'
        $one = Get-RunSourceState -ExecutionRoot $plain -Target @($file)
        Write-TestUtf8 -Path $file -Text "alpha again`n"
        $two = Get-RunSourceState -ExecutionRoot $plain -Target @($file)
        Assert-True ($one.content_sha256 -cne $two.content_sha256) '檔案內容改變應改變雜湊'
        Write-TestUtf8 -Path $file -Text "alpha`n"
    }
    Test-Case 'STATE-EXCLUDE-ROOT 指定排除目錄時，其中的檔案不納入雜湊（該次派遣自己的報告目錄）' {
        $excluded = Join-Path $plain 'report-dir'
        $before = Get-RunSourceState -ExecutionRoot $plain -Target $plainTargets -ExcludeRoot @($excluded)
        Write-TestUtf8 -Path (Join-Path $excluded 'runs\x.record.json') -Text '{}'
        Assert-Equal $before.content_sha256 (Get-RunSourceState -ExecutionRoot $plain -Target $plainTargets -ExcludeRoot @($excluded)).content_sha256 '排除目錄內的新檔不應影響雜湊'
        Assert-True ((Get-RunSourceState -ExecutionRoot $plain -Target $plainTargets).content_sha256 -cne $before.content_sha256) '未排除時新檔應改變雜湊'
        Remove-Item -LiteralPath $excluded -Recurse -Force
    }
    Test-Case 'STATE-JUNCTION content 模式不跟隨 junction：指向祖先的 junction 不造成無限遞迴，只記 reparse-point 標記，替換 junction 會改變雜湊' {
        $loopRoot = New-TestDirectory -Name 'junction'
        Write-TestUtf8 -Path (Join-Path $loopRoot 'a.txt') -Text "alpha`n"
        $link = Join-Path $loopRoot 'loop'
        $null = New-Item -ItemType Junction -Path $link -Target $loopRoot
        $outsideDirectory = New-TestDirectory -Name 'junction-target'
        Write-TestUtf8 -Path (Join-Path $outsideDirectory 'big.txt') -Text "outside content`n"
        $link2 = Join-Path $loopRoot 'other'
        $null = New-Item -ItemType Junction -Path $link2 -Target $outsideDirectory
        $job = Start-ThreadJob -ScriptBlock {
            param($Common, $State, $Root)
            . $Common
            . $State
            $first = Get-RunSourceState -ExecutionRoot $Root -Target @(($Root + '\'))
            $first
        } -ArgumentList (Join-Path $moduleRoot '00-common.ps1'), (Join-Path $moduleRoot '50-source-state.ps1'), $loopRoot
        $finished = Wait-Job -Job $job -Timeout 30
        if ($null -eq $finished) { Stop-Job -Job $job; Remove-Job -Job $job -Force; throw '雜湊 30 秒內沒有結束，疑似跟隨 junction 無限遞迴。' }
        $first = @(Receive-Job -Job $job -ErrorAction SilentlyContinue | Where-Object { $_ -is [pscustomobject] -and $null -ne $_.PSObject.Properties['content_sha256'] })[0]
        Remove-Job -Job $job -Force
        Assert-True ($null -ne $first -and $first.content_sha256 -cmatch '^[0-9a-f]{64}$') '應取得內容雜湊'
        Write-TestUtf8 -Path (Join-Path $outsideDirectory 'big.txt') -Text "outside content changed`n"
        Assert-Equal $first.content_sha256 (Get-RunSourceState -ExecutionRoot $loopRoot -Target @(($loopRoot + '\'))).content_sha256 'junction 指向的目錄內容不應納入雜湊'
        [IO.Directory]::Delete($link2)
        Assert-True ((Get-RunSourceState -ExecutionRoot $loopRoot -Target @(($loopRoot + '\'))).content_sha256 -cne $first.content_sha256) '移除 junction 應改變雜湊'
        [IO.Directory]::Delete($link)
    }
    Test-Case 'STATE-MIXED 目標在 repo 內外並存時兩組欄位都填，只有 repo 外時為 content' {
        $mixed = Get-RunSourceState -ExecutionRoot $repo.Root -Target @(($srcDirectory + '\'), ($plain + '\'))
        Assert-Equal 'git+content' $mixed.mode
        Assert-True ($null -ne $mixed.diff_sha256 -and $null -ne $mixed.content_sha256 -and $null -ne $mixed.head) '兩組欄位都應有值'
        $outsideOnly = Get-RunSourceState -ExecutionRoot $repo.Root -Target @($plain + '\')
        Assert-Equal 'content' $outsideOnly.mode
        Assert-True ($null -eq $outsideOnly.head) 'repo 外的目標不記 HEAD'
    }

    # ---------- 成本列 ----------
    Test-Case 'LEDGER-NEW 新檔含標題、標記行、表頭與恰 14 欄的事件列' {
        $ledger = Join-Path $root 'ledger\line-a\cost-ledger.md'
        $usage = [pscustomobject]@{ status = 'recorded'; input_tokens = 1200; cached_input_tokens = 800; output_tokens = 55; reasoning_output_tokens = 7 }
        $outcome = Add-RunCostRow -LedgerPath $ledger -LineSlug 'line-a' -DispatchSlug 'review-p1' -RunId '20261115T010203456Z-abc123' -Cycle ([pscustomobject]@{ id = 'line-a-review'; round = 2; role = 'review' }) `
            -DurationSeconds 42.9 -Usage $usage -ExitCode 0 -Result 'success' -TaskType 'review' -AccountName 'acct-a' -RejectionKind $null -EndedUtc ([DateTime]::SpecifyKind([DateTime]::Parse('2026-11-15T01:02:03'), [DateTimeKind]::Utc))
        Assert-Equal 'recorded' $outcome
        $lines = @(Get-Content -LiteralPath $ledger)
        Assert-Equal '# line-a 成本紀錄' $lines[0]
        Assert-Equal '<!-- cost-ledger.v2 -->' $lines[2]
        $rows = Get-LedgerDataRow -Path $ledger
        Assert-Equal 1 ($rows.Count)
        $cells = Split-LedgerRow -Row $rows[0]
        Assert-Equal 14 ($cells.Count)
        Assert-Equal @('2026-11-15T01:02:03Z', '事件', 'line-a', 'review-p1', '20261115T010203456Z-abc123', 'line-a-review', '2', 'review', '首次', '42', '1200', '800', '55', 'exit=0;result=success;task=review;account=acct-a;rejection=none;usage=recorded') $cells
    }
    Test-Case 'LEDGER-REJECTED 被服務端拒絕且沒有用量時 input、cached_input、output 為 -，備註含拒絕種類，cycle 缺少時為 -' {
        $ledger = Join-Path $root 'ledger\line-a\cost-ledger.md'
        $noUsage = [pscustomobject]@{ status = 'no-terminal-event'; input_tokens = $null; cached_input_tokens = $null; output_tokens = $null; reasoning_output_tokens = $null }
        $null = Add-RunCostRow -LedgerPath $ledger -LineSlug 'line-a' -DispatchSlug 'review-p1' -RunId '20261115T010204000Z-def456' -Cycle $null -DurationSeconds 3 -Usage $noUsage -ExitCode 1 -Result 'rejected' -TaskType 'review' -AccountName 'acct-b' -RejectionKind 'usage-limit'
        $rows = Get-LedgerDataRow -Path $ledger
        Assert-Equal 2 ($rows.Count)
        $cells = Split-LedgerRow -Row $rows[1]
        Assert-Equal 14 ($cells.Count)
        Assert-Equal @('-', '-', '-') @($cells[5..7])
        Assert-Equal @('-', '-', '-') @($cells[10..12])
        Assert-Equal 'exit=1;result=rejected;task=review;account=acct-b;rejection=usage-limit;usage=no-terminal-event' $cells[13]
    }
    Test-Case 'LEDGER-NULL-USAGE-FIELD usage 個別欄位為 null 時該欄填 -，其餘欄位照常記錄' {
        $ledger = Join-Path $root 'ledger\nullfield\cost-ledger.md'
        $usage = [pscustomobject]@{ status = 'recorded'; input_tokens = 700; cached_input_tokens = $null; output_tokens = 33; reasoning_output_tokens = $null }
        $null = Add-RunCostRow -LedgerPath $ledger -LineSlug 'nullfield' -DispatchSlug 'd' -RunId 'run-null' -Cycle $null -DurationSeconds 1 -Usage $usage -ExitCode 0 -Result 'success' -TaskType 'review' -AccountName 'a' -RejectionKind $null
        $cells = Split-LedgerRow -Row (Get-LedgerDataRow -Path $ledger)[0]
        Assert-Equal @('700', '-', '33') @($cells[10..12])
    }
    Test-Case 'LEDGER-DEDUPE 同 runId 已存在時略過，不重複追加' {
        $ledger = Join-Path $root 'ledger\line-a\cost-ledger.md'
        $outcome = Add-RunCostRow -LedgerPath $ledger -LineSlug 'line-a' -DispatchSlug 'review-p1' -RunId '20261115T010204000Z-def456' -Cycle $null -DurationSeconds 3 -Usage $null -ExitCode 1 -Result 'rejected' -TaskType 'review' -AccountName 'acct-b' -RejectionKind 'usage-limit'
        Assert-Equal 'skipped-existing' $outcome
        Assert-Equal 2 ((Get-LedgerDataRow -Path $ledger).Count)
    }
    Test-Case 'LEDGER-ESCAPE 欄位內的 | 跳脫為 \|，換行轉空白；欄數不是 14 時丟錯' {
        $ledger = Join-Path $root 'ledger\escape\cost-ledger.md'
        $row = @('t', '事件', 'l', 'd', 'run-esc', '-', '-', '-', '首次', '1', '-', '-', '-', "a|b`nc")
        $null = Add-RunLedgerLine -LedgerPath $ledger -RunId 'run-esc' -Row $row
        $dataRow = (Get-LedgerDataRow -Path $ledger)[0]
        Assert-True $dataRow.EndsWith('| a\|b c |') ('跳脫結果不符：' + $dataRow)
        $threw = $false
        try { $null = Add-RunLedgerLine -LedgerPath $ledger -RunId 'x' -Row @('a', 'b') } catch { $threw = $true }
        Assert-True $threw '欄數不符應丟錯'
    }
    Test-Case 'LEDGER-LEGACY 既有檔沒有標記行時附加標記與表頭，保留既有內容' {
        $ledger = Join-Path $root 'ledger\legacy\cost-ledger.md'
        Write-TestUtf8 -Path $ledger -Text "# legacy 成本紀錄`n`n舊內容一行`n"
        $null = Add-RunCostRow -LedgerPath $ledger -LineSlug 'legacy' -DispatchSlug 'd' -RunId 'run-legacy' -Cycle $null -DurationSeconds 1 -Usage $null -ExitCode 0 -Result 'success' -TaskType 'review' -AccountName 'a' -RejectionKind $null
        $text = Get-Content -LiteralPath $ledger -Raw
        Assert-True $text.Contains('舊內容一行') '既有內容被覆寫'
        Assert-True $text.Contains('<!-- cost-ledger.v2 -->') '缺少標記行'
        Assert-True $text.Contains('| 時間（UTC） | 列類型 |') '缺少表頭'
        Assert-Equal 1 ((Get-LedgerDataRow -Path $ledger).Count)
        $null = Add-RunCostRow -LedgerPath $ledger -LineSlug 'legacy' -DispatchSlug 'd' -RunId 'run-legacy-2' -Cycle $null -DurationSeconds 1 -Usage $null -ExitCode 0 -Result 'success' -TaskType 'review' -AccountName 'a' -RejectionKind $null
        Assert-Equal 1 ([regex]::Matches((Get-Content -LiteralPath $ledger -Raw), '<!-- cost-ledger.v2 -->').Count) '標記行不應重複'
        Assert-Equal 2 ((Get-LedgerDataRow -Path $ledger).Count)
    }
    Test-Case 'LEDGER-LOCK 檔案被獨佔持有時重試，釋放後追加成功' {
        $ledger = Join-Path $root 'ledger\lock\cost-ledger.md'
        $null = Add-RunCostRow -LedgerPath $ledger -LineSlug 'lock' -DispatchSlug 'd' -RunId 'run-lock-1' -Cycle $null -DurationSeconds 1 -Usage $null -ExitCode 0 -Result 'success' -TaskType 'review' -AccountName 'a' -RejectionKind $null
        $held = New-Object System.IO.FileStream -ArgumentList @($ledger, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $releaser = Start-ThreadJob -ScriptBlock { param($stream) Start-Sleep -Milliseconds 400; $stream.Dispose() } -ArgumentList $held
        try {
            $null = Add-RunCostRow -LedgerPath $ledger -LineSlug 'lock' -DispatchSlug 'd' -RunId 'run-lock-2' -Cycle $null -DurationSeconds 1 -Usage $null -ExitCode 0 -Result 'success' -TaskType 'review' -AccountName 'a' -RejectionKind $null
        }
        finally {
            $null = Wait-Job -Job $releaser
            Remove-Job -Job $releaser -Force
            $held.Dispose()
        }
        Assert-Equal 2 ((Get-LedgerDataRow -Path $ledger).Count)
    }
}
finally {
    $exitCode = Complete-TestRun
}
exit $exitCode
