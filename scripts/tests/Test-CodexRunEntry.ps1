#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $scriptsRoot
$moduleRoot = Join-Path $scriptsRoot 'codex-run'
$entryPath = Join-Path $scriptsRoot 'Invoke-CodexRun.ps1'
. (Join-Path $PSScriptRoot 'codex-run-fixtures\TestHelpers.ps1')
. (Join-Path $moduleRoot '00-common.ps1')
$fakeCodexText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'codex-run-fixtures\fake-codex.ps1'))
$hostPath = [Environment]::ProcessPath
$savedScenarioDir = [Environment]::GetEnvironmentVariable('FAKE_CODEX_SCENARIO_DIR')
$fence = '```'

function Get-DirectorySnapshot {
    # 目錄下全部檔案的相對路徑與雜湊（可排除頂層目錄名），用來確認沒有被改動。
    param([string]$Root, [string[]]$ExcludeTopLevel = @())
    $lines = foreach ($file in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force)) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\')
        if ($ExcludeTopLevel -contains $relative.Split('\')[0]) { continue }
        $relative + ' ' + (Get-RunSha256File -Path $file.FullName)
    }
    return (@($lines | Sort-Object) -join "`n")
}
function Get-WorktreeList {
    param([string]$Repository)
    return ((Invoke-TestGit -WorkingDirectory $Repository -Argument @('worktree', 'list')) -join "`n")
}
function Split-LedgerRow {
    param([string]$Row)
    return @([regex]::Split($Row.Substring(2, $Row.Length - 4), '(?<!\\) \| '))
}
function Get-LedgerDataRow {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return , @() }
    return , @(Get-Content -LiteralPath $Path | Where-Object { $_.StartsWith('| ', [StringComparison]::Ordinal) -and $_ -notmatch '^\| ---' -and -not $_.StartsWith('| 時間（UTC）', [StringComparison]::Ordinal) })
}

function New-ReviewReportText {
    param([string]$Severity = 'Minor')
    return "# 審查報告`n`n## 總覽`n`n結論：pass`n`n## Finding manifest`n`n${fence}json`n" +
    '{"schema":"codex-run.review-findings.v1","findings":[{"id":"F-001","severity":"' + $Severity + '","status":"open","summary":"範例"}]}' + "`n${fence}`n`n## 例外回報`n`n無`n"
}
$usageGood = [ordered]@{ input_tokens = 1200; cached_input_tokens = 800; output_tokens = 55; reasoning_output_tokens = 7 }
$successEvents = @([ordered]@{ type = 'thread.started'; thread_id = 'fx' }, [ordered]@{ type = 'turn.started' },
    [ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'agent_message'; text = 'done' } }, [ordered]@{ type = 'turn.completed'; usage = $usageGood })
$usageLimitEvents = @([ordered]@{ type = 'thread.started'; thread_id = 'fx' }, [ordered]@{ type = 'turn.started' },
    [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'You hit your usage limit.' } })
$unauthorizedEvents = @([ordered]@{ type = 'turn.started' }, [ordered]@{ type = 'error'; message = 'unexpected status 401 Unauthorized' }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'unexpected status 401 Unauthorized' } })
$modelEvents = @([ordered]@{ type = 'turn.started' }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = "The 'gpt-x' model is not supported when using Codex with a ChatGPT account." } })

function New-EntryEnvironment {
    param([string]$Name, [switch]$NoGit)
    $base = New-TestDirectory -Name $Name
    if ($NoGit) {
        $exec = Join-Path $base 'exec'
        $null = New-Item -ItemType Directory -Path $exec -Force
        $machineDirectory = Join-Path $base 'machine'
        $repo = $null
    }
    else {
        $repo = New-TestGitRepository -Directory $base -WithWorktree
        $exec = $repo.Worktree
        $machineDirectory = Join-Path $repo.Root '.local'
    }
    $homeA = New-TestAccountHome -Root (Join-Path $base 'homes') -Name 'acct-a' -Profile 'review' -Model 'model-a'
    $homeB = New-TestAccountHome -Root (Join-Path $base 'homes') -Name 'acct-b' -Profile 'review' -Model 'model-b'
    $machine = New-TestMachineConfig -Directory $machineDirectory -Account @(@{ name = 'acct-a'; codex_home = $homeA }, @{ name = 'acct-b'; codex_home = $homeB })
    $scenarios = Join-Path $base 'scenarios'
    $null = New-Item -ItemType Directory -Path $scenarios -Force
    $codex = New-FakeCodexCmd -Directory (Join-Path $base 'fake') -ScriptText $fakeCodexText
    Write-TestUtf8 -Path (Join-Path $exec 'src\a.txt') -Text "alpha`n"
    Write-TestUtf8 -Path (Join-Path $exec 'role.toml') -Text 'name = "reviewer"'
    Write-TestUtf8 -Path (Join-Path $exec 'design.md') -Text '# design'
    $reportRoot = Join-Path $exec '.local\ai-sessions\report\line-a'
    $null = New-Item -ItemType Directory -Path $reportRoot -Force
    if ($NoGit) { Write-TestUtf8 -Path (Join-Path $exec '.env') -Text 'SECRET=1' }
    return [pscustomobject]@{
        Base = $base; Repo = $repo; Exec = $exec; Machine = $machine; MachineDirectory = $machineDirectory; Scenarios = $scenarios; Codex = $codex
        HomeA = $homeA; HomeB = $homeB; ReportRoot = $reportRoot; Calls = (Join-Path $scenarios 'calls.jsonl'); Health = (Join-Path $machineDirectory 'codex-account-health.json')
    }
}
function Set-Scenario {
    param($Environment, [string]$Account, [hashtable]$Scenario)
    Write-TestUtf8 -Path (Join-Path $Environment.Scenarios ($Account + '.json')) -Text (ConvertTo-Json -InputObject $Scenario -Depth 12)
}
function New-OrderFile {
    param($Environment, [string]$Slug = 'review-p1', [hashtable]$Override = @{}, [string]$FileName = 'order.md')
    $setting = [ordered]@{
        schema = 'ai-agents.codex-run-order.v1'; line_slug = 'line-a'; dispatch_slug = $Slug; task_type = 'review'; profile = 'review'
        role_file = (Join-Path $Environment.Exec 'role.toml'); execution_root = $Environment.Exec; report_line_root = $Environment.ReportRoot
        report_name = 'review-report.md'; targets = @(($Environment.Exec + '\src\')); required_reads = @((Join-Path $Environment.Exec 'design.md'))
        cycle = [ordered]@{ id = 'line-a-review'; round = 1; role = 'review' }
    }
    foreach ($key in $Override.Keys) { $setting[$key] = $Override[$key] }
    $path = Join-Path $Environment.Exec ('.local\ai-sessions\handoff\line-a\' + $FileName)
    Write-TestUtf8 -Path $path -Text ("# 派遣檔`n`n## 派遣設定`n`n${fence}json`n" + (ConvertTo-Json -InputObject $setting -Depth 6) + "`n${fence}`n`n## 任務`n`n審查 src。`n")
    return $path
}
function Invoke-Entry {
    param($Environment, [string]$OrderPath, [string]$CodexPath, [string]$MachinePath, [switch]$OmitMachine, [string]$EntryScript = $entryPath, [int]$TimeoutSeconds = 0)
    [Environment]::SetEnvironmentVariable('FAKE_CODEX_SCENARIO_DIR', $Environment.Scenarios)
    if ([string]::IsNullOrEmpty($CodexPath)) { $CodexPath = $Environment.Codex }
    if ([string]::IsNullOrEmpty($MachinePath)) { $MachinePath = $Environment.Machine }
    $errPath = Join-Path $Environment.Base ('stderr-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    $arguments = @('-NoProfile', '-File', $EntryScript, '-DispatchFile', $OrderPath, '-CodexPath', $CodexPath)
    if (-not $OmitMachine) { $arguments += @('-MachineConfigPath', $MachinePath) }
    if ($TimeoutSeconds -gt 0) { $arguments += @('-TimeoutSeconds', [string]$TimeoutSeconds) }
    $output = & $hostPath @arguments 2> $errPath
    $exitCode = $LASTEXITCODE
    $stdoutText = (@($output | ForEach-Object { [string]$_ }) -join "`n")
    $document = $null
    try { $document = ConvertFrom-Json -InputObject $stdoutText } catch { $document = $null }
    return [pscustomobject]@{ ExitCode = $exitCode; Stdout = $stdoutText; Document = $document; Stderr = (Get-Content -LiteralPath $errPath -Raw -ErrorAction SilentlyContinue) }
}
function Get-Call {
    param($Environment)
    if (-not (Test-Path -LiteralPath $Environment.Calls)) { return , @() }
    return , @(Get-Content -LiteralPath $Environment.Calls | ForEach-Object { ConvertFrom-Json -InputObject $_ })
}
function Get-Record {
    param([string]$Path)
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}
function Assert-Success {
    param($Run)
    Assert-True ($null -ne $Run.Document) ('stdout 不是 JSON：' + $Run.Stdout + ' / stderr：' + $Run.Stderr)
}

# 測試行程帶著機密變數，入口必須在啟動 codex 前把它清除（E2E-CALLS 核對）。
$savedFakeToken = [Environment]::GetEnvironmentVariable('FAKE_API_TOKEN')
[Environment]::SetEnvironmentVariable('FAKE_API_TOKEN', 'fixture-token-must-not-reach-codex')

try {
    # ---------- 成功審查 ----------
    $e1 = New-EntryEnvironment -Name 'success'
    Set-Scenario -Environment $e1 -Account 'acct-a' -Scenario @{ events = $successEvents; exit_code = 0; last_message = '審查完成'; report = (New-ReviewReportText) }
    $order1 = New-OrderFile -Environment $e1
    $worktreesBefore = Get-WorktreeList -Repository $e1.Repo.Root
    $treeBefore = Get-DirectorySnapshot -Root $e1.Exec -ExcludeTopLevel @('.local')
    $run1 = Invoke-Entry -Environment $e1 -OrderPath $order1
    $worktreesAfter = Get-WorktreeList -Repository $e1.Repo.Root
    $treeAfter = Get-DirectorySnapshot -Root $e1.Exec -ExcludeTopLevel @('.local')

    Test-Case 'E2E-SUCCESS 成功審查：結束碼 0、status=success、報告在該次派遣專屬輸出目錄' {
        Assert-Success $run1
        Assert-Equal 0 $run1.ExitCode
        Assert-Equal 'success' $run1.Document.status
        Assert-Equal 'ai-agents.codex-run-result.v1' $run1.Document.schema
        Assert-Equal 1 (@($run1.Document.attempts).Count)
        $runKey = $run1.Document.final.run_key
        Assert-True ($runKey -cmatch '^review-p1-\d{8}T\d{9}Z-[0-9a-f]{6}$') ('runKey 格式：' + $runKey)
        $outputDirectory = Join-Path $e1.ReportRoot ('runs\' + $runKey)
        Assert-Equal (Join-Path $outputDirectory 'review-report.md') $run1.Document.final.report_path
        Assert-True (Test-Path -LiteralPath $run1.Document.final.report_path) '報告不存在'
        foreach ($name in @('.record.json', '.events.jsonl', '.stderr.txt', '.last-message.md')) {
            Assert-True (Test-Path -LiteralPath (Join-Path $e1.ReportRoot ('runs\' + $runKey + $name))) ($name + ' 不存在')
        }
        Assert-Equal $true $run1.Document.final.review_report_check.valid
        Assert-True ($null -eq $run1.Document.error) 'error 應為 null'
    }
    Test-Case 'E2E-NO-RESIDUE 執行前後 git worktree list 逐字相同，線工作樹（.local 以外）沒有被改動' {
        Assert-Equal $worktreesBefore $worktreesAfter
        Assert-Equal $treeBefore $treeAfter
    }
    Test-Case 'E2E-RECORD 執行紀錄含 §2.3.5 全部欄位，來源雜湊前後一致' {
        $record = Get-Record -Path $run1.Document.final.record_path
        foreach ($field in @('schema', 'run_key', 'run_id', 'line_slug', 'dispatch_slug', 'task_type', 'profile', 'dispatch_file', 'account', 'model', 'execution_root', 'output_dir', 'report_path', 'started_utc', 'ended_utc', 'duration_seconds',
                'source_state_start', 'source_state_end', 'source_changed', 'exit_code', 'result', 'failure_reason', 'terminated_by_entry', 'rejection_kind', 'item_event_count', 'usage', 'last_message', 'events_path', 'stderr_path', 'report', 'review_report_check', 'permission')) {
            Assert-True ($null -ne $record.PSObject.Properties[$field]) ('缺少欄位 ' + $field)
        }
        Assert-Equal 'ai-agents.codex-run-record.v1' $record.schema
        Assert-Equal 'acct-a' $record.account.name
        Assert-Equal 'model-a' $record.model
        Assert-Equal (Get-RunSha256File -Path $order1) $record.dispatch_file.sha256
        Assert-Equal 'success' $record.result
        Assert-Equal 0 ([int]$record.exit_code)
        Assert-True ($null -ne $record.ended_utc) 'ended_utc'
        Assert-Equal 'git' $record.source_state_start.mode
        Assert-True ($null -ne $record.source_state_start.head -and $null -ne $record.source_state_start.diff_sha256) 'source_state_start 缺 head 或 diff_sha256'
        Assert-Equal ($record.source_state_start | ConvertTo-Json -Compress) ($record.source_state_end | ConvertTo-Json -Compress)
        Assert-Equal $false $record.source_changed
        Assert-Equal 'recorded' $record.usage.status
        Assert-Equal 1200 ([long]$record.usage.input_tokens)
        Assert-Equal 'dispatch_review' $record.permission.name
        Assert-True (@($record.permission.read_roots) -contains $e1.ReportRoot) 'permission.read_roots 應含 report_line_root'
        Assert-Equal $true $record.review_report_check.valid
        Assert-True ($record.report.exists -and $record.report.bytes -gt 0) 'report 欄位'
    }
    Test-Case 'E2E-LEDGER 成本帳多出恰一列，14 欄，備註含 account、rejection=none、usage=recorded' {
        $rows = Get-LedgerDataRow -Path (Join-Path $e1.ReportRoot 'cost-ledger.md')
        Assert-Equal 1 ($rows.Count)
        $cells = Split-LedgerRow -Row $rows[0]
        Assert-Equal 14 ($cells.Count)
        Assert-Equal @('事件', 'line-a', 'review-p1', 'line-a-review', '1', 'review', '首次', '1200', '800', '55') @($cells[1], $cells[2], $cells[3], $cells[5], $cells[6], $cells[7], $cells[8], $cells[10], $cells[11], $cells[12])
        Assert-True ($cells[4] -ceq ($run1.Document.final.run_key.Substring('review-p1-'.Length))) 'runId 應為 runKey 去掉 dispatchSlug 的部分'
        Assert-True ($cells[13].Contains('account=acct-a') -and $cells[13].Contains('rejection=none') -and $cells[13].Contains('usage=recorded') -and $cells[13].Contains('result=success') -and $cells[13].Contains('task=review')) ('備註：' + $cells[13])
    }
    Test-Case 'E2E-CALLS 呼叫紀錄：探針一次、exec 一次，exec 引數不含 --sandbox，含 --profile review 與 --cd，stdin 含 LineContext 與報告檔' {
        $calls = Get-Call -Environment $e1
        Assert-Equal @('sandbox', 'exec') @($calls | ForEach-Object { $_.subcommand })
        $exec = $calls[1]
        $execArgs = @($exec.args)
        Assert-True (-not ($execArgs -contains '--sandbox')) 'exec 引數含 --sandbox'
        Assert-True ($execArgs -contains '--profile' -and $execArgs[[array]::IndexOf($execArgs, '--profile') + 1] -ceq 'review') '缺少 --profile review'
        Assert-Equal $e1.Exec $execArgs[[array]::IndexOf($execArgs, '--cd') + 1]
        Assert-True ($execArgs -contains 'windows.sandbox="mxc"' -and $execArgs -contains 'default_permissions="dispatch_review"') '缺少 MXC 或預設權限設定'
        Assert-True (-not ($execArgs -contains '--skip-git-repo-check')) 'git repo 不應加 --skip-git-repo-check'
        Assert-Equal $e1.HomeA $exec.codex_home
        $stdin = Get-Content -LiteralPath (Join-Path $e1.Scenarios 'stdin-acct-a.txt') -Raw
        Assert-True ($stdin.Contains('LineContext') -and $stdin.Contains('- lineSlug: line-a') -and $stdin.Contains('- executionRoot: ' + $e1.Exec)) 'stdin 缺 LineContext'
        Assert-True ($stdin.Contains('報告檔: ' + $run1.Document.final.report_path)) 'stdin 缺報告檔行'
        Assert-True ($stdin.Contains($order1)) 'stdin 缺派遣檔路徑'
        Assert-Equal 'fixture-token-must-not-reach-codex' ([Environment]::GetEnvironmentVariable('FAKE_API_TOKEN')) '前置條件：測試行程必須帶著機密變數，斷言才有意義'
        Assert-Equal 0 (@($calls | Where-Object { $_.env_names -contains 'FAKE_API_TOKEN' }).Count) '機密環境變數不應傳給 codex'
    }
    Test-Case 'E2E-STDERR 診斷行寫在 stderr，stdout 只有單一 JSON' {
        Assert-True ($run1.Stderr.Contains('acct-a')) 'stderr 缺診斷行'
        Assert-True (-not $run1.Stdout.Contains("`n")) 'stdout 應為單行 JSON'
        Assert-True (-not [regex]::IsMatch($run1.Stdout, '[^\x00-\x7F]')) 'stdout 應為 ASCII'
    }

    # ---------- linked worktree 沒有 .local\machine.json ----------
    Test-Case 'E2E-LINKED-WORKTREE 入口位於沒有 machine.json 的 linked worktree 時，從主 checkout 選得到帳號' {
        $e2 = New-EntryEnvironment -Name 'linked'
        Set-Scenario -Environment $e2 -Account 'acct-a' -Scenario @{ events = $successEvents; exit_code = 0; last_message = 'ok'; report = (New-ReviewReportText) }
        $worktreeScripts = Join-Path $e2.Exec 'scripts'
        $null = New-Item -ItemType Directory -Path $worktreeScripts -Force
        Copy-Item -LiteralPath $entryPath -Destination $worktreeScripts
        Copy-Item -LiteralPath $moduleRoot -Destination (Join-Path $worktreeScripts 'codex-run') -Recurse
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $e2.Exec '.local\machine.json'))) '前置條件：worktree 不應有 machine.json'
        $run = Invoke-Entry -Environment $e2 -OrderPath (New-OrderFile -Environment $e2) -OmitMachine -EntryScript (Join-Path $worktreeScripts 'Invoke-CodexRun.ps1')
        Assert-Success $run
        Assert-Equal 0 $run.ExitCode
        Assert-Equal 'acct-a' $run.Document.attempts[0].account
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $e2.Exec '.local\codex-account.lock'))) 'worktree 的 .local 不應出現鎖檔'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $e2.Exec '.local\codex-account-health.json'))) 'worktree 的 .local 不應出現健康狀態檔'
    }

    # ---------- 換帳號 ----------
    Test-Case 'E2E-FAILOVER usage limit 零進度時換下一個帳號：兩次嘗試、兩筆紀錄、兩列成本帳，彼此沒有連結' {
        $e3 = New-EntryEnvironment -Name 'failover'
        Set-Scenario -Environment $e3 -Account 'acct-a' -Scenario @{ events = $usageLimitEvents; exit_code = 1; last_message = $null; report = $null }
        Set-Scenario -Environment $e3 -Account 'acct-b' -Scenario @{ events = $successEvents; exit_code = 0; last_message = 'ok'; report = (New-ReviewReportText) }
        $run = Invoke-Entry -Environment $e3 -OrderPath (New-OrderFile -Environment $e3)
        Assert-Success $run
        Assert-Equal 0 $run.ExitCode
        Assert-Equal 'success' $run.Document.status
        $attempts = @($run.Document.attempts)
        Assert-Equal 2 ($attempts.Count)
        Assert-Equal @('acct-a', 'acct-b') @($attempts | ForEach-Object { $_.account })
        Assert-Equal @('rejected', 'success') @($attempts | ForEach-Object { $_.result })
        Assert-Equal 'usage-limit' $attempts[0].rejection_kind
        Assert-True ($attempts[0].run_key -cne $attempts[1].run_key) 'runKey 應不同'
        $records = @($attempts | ForEach-Object { Get-Content -LiteralPath $_.record_path -Raw })
        Assert-True (-not $records[0].Contains($attempts[1].run_key)) 'A 的紀錄不應指向 B'
        Assert-True (-not $records[1].Contains($attempts[0].run_key)) 'B 的紀錄不應指向 A'
        Assert-Equal 2 (@(Get-ChildItem -LiteralPath (Join-Path $e3.ReportRoot 'runs') -Directory).Count) '兩個輸出目錄'
        $rows = Get-LedgerDataRow -Path (Join-Path $e3.ReportRoot 'cost-ledger.md')
        Assert-Equal 2 ($rows.Count)
        $cellsA = Split-LedgerRow -Row $rows[0]
        $cellsB = Split-LedgerRow -Row $rows[1]
        Assert-Equal @('-', '-', '-') @($cellsA[10..12])
        Assert-True ($cellsA[13].Contains('rejection=usage-limit') -and $cellsA[13].Contains('account=acct-a') -and $cellsA[13].Contains('result=rejected')) $cellsA[13]
        Assert-True ($cellsB[13].Contains('result=success') -and $cellsB[13].Contains('account=acct-b')) $cellsB[13]
        $calls = Get-Call -Environment $e3
        Assert-Equal @('sandbox', 'exec', 'exec') @($calls | ForEach-Object { $_.subcommand })
        Assert-Equal @($e3.HomeA, $e3.HomeB) @($calls[1].codex_home, $calls[2].codex_home)
    }
    Test-Case 'E2E-HEALTH model-not-supported 拒絕後主 checkout 的健康狀態檔含該帳號，第二次發動直接略過該帳號' {
        $e4 = New-EntryEnvironment -Name 'health'
        Set-Scenario -Environment $e4 -Account 'acct-a' -Scenario @{ events = $modelEvents; exit_code = 1; last_message = $null; report = $null }
        Set-Scenario -Environment $e4 -Account 'acct-b' -Scenario @{ events = $successEvents; exit_code = 0; last_message = 'ok'; report = (New-ReviewReportText) }
        $first = Invoke-Entry -Environment $e4 -OrderPath (New-OrderFile -Environment $e4)
        Assert-Success $first
        Assert-Equal 0 $first.ExitCode
        Assert-True (Test-Path -LiteralPath $e4.Health) '健康狀態檔不在主 checkout 的 .local'
        $document = Get-Content -LiteralPath $e4.Health -Raw | ConvertFrom-Json
        Assert-Equal @('acct-a') @($document.entries | ForEach-Object { $_.account_name })
        Assert-Equal 'model-not-supported' $document.entries[0].reason_code
        $callsBefore = (Get-Call -Environment $e4).Count
        $second = Invoke-Entry -Environment $e4 -OrderPath (New-OrderFile -Environment $e4 -FileName 'order2.md')
        Assert-Success $second
        Assert-Equal 0 $second.ExitCode
        $newCalls = @((Get-Call -Environment $e4) | Select-Object -Skip $callsBefore)
        Assert-Equal @('sandbox', 'exec') @($newCalls | ForEach-Object { $_.subcommand })
        Assert-True (-not (@($newCalls | Where-Object { $_.account -eq 'acct-a' }).Count -gt 0)) '第二次發動不應再呼叫 acct-a'
        Assert-Equal @('acct-b') @($second.Document.attempts | ForEach-Object { $_.account })
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $e4.Exec '.local\codex-account-health.json'))) 'worktree 的 .local 不應有健康狀態檔'
    }

    # ---------- 來源變動、非 Git 來源、重複發動 ----------
    Test-Case 'E2E-SOURCE-CHANGED 審查期間來源被改動時 source_changed=true（紀錄與結果文件）' {
        $e5 = New-EntryEnvironment -Name 'changed'
        Set-Scenario -Environment $e5 -Account 'acct-a' -Scenario @{ events = $successEvents; exit_code = 0; last_message = 'ok'; report = (New-ReviewReportText); modify_target = (Join-Path $e5.Exec 'src\a.txt') }
        $run = Invoke-Entry -Environment $e5 -OrderPath (New-OrderFile -Environment $e5)
        Assert-Success $run
        Assert-Equal 0 $run.ExitCode
        Assert-Equal $true $run.Document.final.source_changed
        $record = Get-Record -Path $run.Document.final.record_path
        Assert-Equal $true $record.source_changed
        Assert-True ($record.source_state_start.diff_sha256 -cne $record.source_state_end.diff_sha256) '兩次雜湊應不同'
    }
    Test-Case 'E2E-NON-GIT 非 Git 來源以 content 模式記雜湊並加 --skip-git-repo-check' {
        $e6 = New-EntryEnvironment -Name 'nongit' -NoGit
        Set-Scenario -Environment $e6 -Account 'acct-a' -Scenario @{ events = $successEvents; exit_code = 0; last_message = 'ok'; report = (New-ReviewReportText) }
        $run = Invoke-Entry -Environment $e6 -OrderPath (New-OrderFile -Environment $e6 -Override @{ targets = @(($e6.Exec + '\')) })
        Assert-Success $run
        Assert-Equal 0 $run.ExitCode
        $record = Get-Record -Path $run.Document.final.record_path
        Assert-Equal 'content' $record.source_state_start.mode
        Assert-True ($null -ne $record.source_state_start.content_sha256 -and $null -eq $record.source_state_start.diff_sha256) 'content 模式欄位'
        Assert-Equal $false $record.source_changed
        $calls = Get-Call -Environment $e6
        Assert-True (@($calls[1].args) -contains '--skip-git-repo-check') '非 Git 來源應加 --skip-git-repo-check'
    }
    Test-Case 'E2E-SAME-SLUG 同一個 dispatchSlug 連續發動兩次得到不同 runKey 與輸出目錄' {
        $e7 = New-EntryEnvironment -Name 'sameslug'
        Set-Scenario -Environment $e7 -Account 'acct-a' -Scenario @{ events = $successEvents; exit_code = 0; last_message = 'ok'; report = (New-ReviewReportText) }
        $order = New-OrderFile -Environment $e7
        $first = Invoke-Entry -Environment $e7 -OrderPath $order
        $second = Invoke-Entry -Environment $e7 -OrderPath $order
        Assert-Success $first
        Assert-Success $second
        Assert-True ($first.Document.final.run_key -cne $second.Document.final.run_key) 'runKey 應不同'
        Assert-True ((Split-Path -Parent $first.Document.final.report_path) -cne (Split-Path -Parent $second.Document.final.report_path)) '輸出目錄應不同'
        Assert-True ((Test-Path -LiteralPath $first.Document.final.report_path) -and (Test-Path -LiteralPath $second.Document.final.report_path)) '兩份報告都應保留'
        Assert-Equal 2 ((Get-LedgerDataRow -Path (Join-Path $e7.ReportRoot 'cost-ledger.md')).Count)
    }

    # ---------- 負向：啟動前即停止 ----------
    Test-Case 'E2E-MISSING-READ 派遣檔缺少必讀檔：結束碼 2、RunPathsInvalid，沒有任何呼叫也沒有建立輸出目錄' {
        $e8 = New-EntryEnvironment -Name 'missingread'
        Set-Scenario -Environment $e8 -Account 'acct-a' -Scenario @{ events = $successEvents; exit_code = 0; last_message = 'ok'; report = (New-ReviewReportText) }
        $ghost = Join-Path $e8.Exec 'absent-design.md'
        $run = Invoke-Entry -Environment $e8 -OrderPath (New-OrderFile -Environment $e8 -Override @{ required_reads = @($ghost) })
        Assert-Success $run
        Assert-Equal 2 $run.ExitCode
        Assert-Equal 'stopped' $run.Document.status
        Assert-Equal 'RunPathsInvalid' $run.Document.error.code
        Assert-Equal $ghost $run.Document.error.details[0].path
        Assert-Equal 'missing' $run.Document.error.details[0].reason
        Assert-Equal 1 ([regex]::Matches($run.Stderr, [regex]::Escape($ghost)).Count) 'stderr 的問題路徑應只出現一次'
        Assert-Equal 0 ((Get-Call -Environment $e8).Count) '不應呼叫 codex'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $e8.ReportRoot 'runs'))) '不應建立輸出目錄'
    }
    Test-Case 'E2E-MXC-UNAVAILABLE 探針失敗：結束碼 3、RunMxcUnavailable，沒有 exec 呼叫' {
        $e9 = New-EntryEnvironment -Name 'nomxc'
        Set-Scenario -Environment $e9 -Account 'acct-a' -Scenario @{ events = $successEvents; exit_code = 0; mxc = 'fail' }
        $run = Invoke-Entry -Environment $e9 -OrderPath (New-OrderFile -Environment $e9)
        Assert-Success $run
        Assert-Equal 3 $run.ExitCode
        Assert-Equal 'RunMxcUnavailable' $run.Document.error.code
        Assert-Equal @('sandbox') @((Get-Call -Environment $e9) | ForEach-Object { $_.subcommand })
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $e9.ReportRoot 'runs'))) '不應建立輸出目錄'
    }
    Test-Case 'E2E-CODEX-NOT-FOUND 找不到 codex 執行檔：結束碼 3、RunCodexNotFound' {
        $e10 = New-EntryEnvironment -Name 'nocodex'
        $run = Invoke-Entry -Environment $e10 -OrderPath (New-OrderFile -Environment $e10) -CodexPath (Join-Path $e10.Base 'absent\codex.cmd')
        Assert-Success $run
        Assert-Equal 3 $run.ExitCode
        Assert-Equal 'RunCodexNotFound' $run.Document.error.code
    }
    Test-Case 'E2E-NO-ACCOUNTS 無登記帳號：結束碼 4、CodexAccountsNotRegistered，沒有 exec 呼叫' {
        $e11 = New-EntryEnvironment -Name 'noaccounts'
        $emptyMachine = New-TestMachineConfig -Directory (New-TestDirectory -Name 'emptyreg') -Account @()
        $run = Invoke-Entry -Environment $e11 -OrderPath (New-OrderFile -Environment $e11) -MachinePath $emptyMachine
        Assert-Success $run
        Assert-Equal 4 $run.ExitCode
        Assert-Equal 'CodexAccountsNotRegistered' $run.Document.error.code
        Assert-Equal 0 ((Get-Call -Environment $e11).Count)
    }
    Test-Case 'E2E-ALL-UNAVAILABLE 全部帳號都不可用：結束碼 4、CodexAccountsAllUnavailable，訊息附登入命令' {
        $e12 = New-EntryEnvironment -Name 'allunavailable'
        Remove-Item -LiteralPath (Join-Path $e12.HomeA 'auth.json'), (Join-Path $e12.HomeB 'auth.json') -Force
        $run = Invoke-Entry -Environment $e12 -OrderPath (New-OrderFile -Environment $e12)
        Assert-Success $run
        Assert-Equal 4 $run.ExitCode
        Assert-Equal 'CodexAccountsAllUnavailable' $run.Document.error.code
        Assert-True ($run.Document.error.message.Contains('$env:CODEX_HOME=''' + $e12.HomeA + '''; codex login')) '缺少 acct-a 的登入命令'
        Assert-Equal 0 ((Get-Call -Environment $e12).Count)
    }

    # ---------- 負向：執行結果 ----------
    Test-Case 'E2E-REJECT-WITH-PROGRESS 拒絕但已有 item 進度：不換帳號、結束碼 1、只有一次 exec' {
        $e13 = New-EntryEnvironment -Name 'progress'
        $events = @([ordered]@{ type = 'turn.started' }, [ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'agent_message'; text = 'partial' } }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'You hit your usage limit.' } })
        Set-Scenario -Environment $e13 -Account 'acct-a' -Scenario @{ events = $events; exit_code = 1; last_message = $null; report = $null }
        Set-Scenario -Environment $e13 -Account 'acct-b' -Scenario @{ events = $successEvents; exit_code = 0; last_message = 'ok'; report = (New-ReviewReportText) }
        $run = Invoke-Entry -Environment $e13 -OrderPath (New-OrderFile -Environment $e13)
        Assert-Success $run
        Assert-Equal 1 $run.ExitCode
        Assert-Equal 'rejected' $run.Document.status
        Assert-Equal 1 (@($run.Document.attempts).Count)
        Assert-Equal 1 (@((Get-Call -Environment $e13) | Where-Object { $_.subcommand -eq 'exec' }).Count) '只應有一次 exec'
        Assert-Equal 1 ((Get-LedgerDataRow -Path (Join-Path $e13.ReportRoot 'cost-ledger.md')).Count)
    }
    Test-Case 'E2E-EXHAUSTED 兩個帳號都被拒：結束碼 4、CodexAccountsExhausted、兩列成本帳，unauthorized 附登入命令' {
        $e14 = New-EntryEnvironment -Name 'exhausted'
        Set-Scenario -Environment $e14 -Account 'acct-a' -Scenario @{ events = $usageLimitEvents; exit_code = 1; last_message = $null; report = $null }
        Set-Scenario -Environment $e14 -Account 'acct-b' -Scenario @{ events = $unauthorizedEvents; exit_code = 1; last_message = $null; report = $null }
        $run = Invoke-Entry -Environment $e14 -OrderPath (New-OrderFile -Environment $e14)
        Assert-Success $run
        Assert-Equal 4 $run.ExitCode
        Assert-Equal 'stopped' $run.Document.status
        Assert-Equal 'CodexAccountsExhausted' $run.Document.error.code
        Assert-Equal 2 (@($run.Document.attempts).Count)
        Assert-Equal 2 ((Get-LedgerDataRow -Path (Join-Path $e14.ReportRoot 'cost-ledger.md')).Count)
        Assert-True ($null -eq $run.Document.attempts[0].relogin_command) 'usage-limit 不需要登入命令'
        Assert-Equal ('$env:CODEX_HOME=''' + $e14.HomeB + '''; codex login') $run.Document.attempts[1].relogin_command
        Assert-Equal ('$env:CODEX_HOME=''' + $e14.HomeB + '''; codex login') $run.Document.final.relogin_command
    }
    Test-Case 'E2E-REPORT-MISSING 報告不存在或為空時 result=failed，原因 report-missing 與 report-empty，結束碼 1' {
        $e15 = New-EntryEnvironment -Name 'noreport'
        Set-Scenario -Environment $e15 -Account 'acct-a' -Scenario @{ events = $successEvents; exit_code = 0; last_message = 'ok'; report = $null }
        $missing = Invoke-Entry -Environment $e15 -OrderPath (New-OrderFile -Environment $e15)
        Assert-Success $missing
        Assert-Equal 1 $missing.ExitCode
        Assert-Equal 'failed' $missing.Document.status
        Assert-Equal 'report-missing' (Get-Record -Path $missing.Document.final.record_path).failure_reason
        Set-Scenario -Environment $e15 -Account 'acct-a' -Scenario @{ events = $successEvents; exit_code = 0; last_message = 'ok'; report = '' }
        $empty = Invoke-Entry -Environment $e15 -OrderPath (New-OrderFile -Environment $e15)
        Assert-Equal 1 $empty.ExitCode
        Assert-Equal 'report-empty' (Get-Record -Path $empty.Document.final.record_path).failure_reason
        Assert-Equal 1 (@((Get-Call -Environment $e15) | Where-Object { $_.subcommand -eq 'exec' } | Select-Object -First 1).Count)
    }
    Test-Case 'E2E-NONZERO-EXIT 非零結束碼且無拒絕種類時 failed（nonzero-exit），不換帳號' {
        $e16 = New-EntryEnvironment -Name 'nonzero'
        Set-Scenario -Environment $e16 -Account 'acct-a' -Scenario @{ events = @([ordered]@{ type = 'turn.started' }); exit_code = 3; last_message = 'x'; report = (New-ReviewReportText) }
        $run = Invoke-Entry -Environment $e16 -OrderPath (New-OrderFile -Environment $e16)
        Assert-Success $run
        Assert-Equal 1 $run.ExitCode
        Assert-Equal 'failed' $run.Document.status
        Assert-Equal 'nonzero-exit' (Get-Record -Path $run.Document.final.record_path).failure_reason
        Assert-Equal 1 (@((Get-Call -Environment $e16) | Where-Object { $_.subcommand -eq 'exec' }).Count)
    }
    Test-Case 'E2E-MANIFEST-INVALID 審查報告 manifest 不合格：result 仍為 success，review_report_check 指出 finding 與欄位' {
        $e17 = New-EntryEnvironment -Name 'badmanifest'
        Set-Scenario -Environment $e17 -Account 'acct-a' -Scenario @{ events = $successEvents; exit_code = 0; last_message = 'ok'; report = (New-ReviewReportText -Severity 'High') }
        $run = Invoke-Entry -Environment $e17 -OrderPath (New-OrderFile -Environment $e17)
        Assert-Success $run
        Assert-Equal 0 $run.ExitCode
        Assert-Equal 'success' $run.Document.status
        Assert-Equal $false $run.Document.final.review_report_check.valid
        Assert-Equal @("F-001 severity: invalid value 'High'") @($run.Document.final.review_report_check.errors)
    }
    Test-Case 'E2E-TIMEOUT 總時限內沒有結束：入口在時限內返回，行程樹已消失，紀錄 failed 與 timeout，不換帳號' {
        $e18 = New-EntryEnvironment -Name 'timeout'
        Set-Scenario -Environment $e18 -Account 'acct-a' -Scenario @{ events = @([ordered]@{ type = 'turn.started' }, [ordered]@{ type = 'item.started'; item = [ordered]@{ type = 'command_execution' } }); exit_code = 0; hang_seconds = 120 }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-Entry -Environment $e18 -OrderPath (New-OrderFile -Environment $e18) -TimeoutSeconds 8
        $watch.Stop()
        Assert-Success $run
        Assert-True ($watch.Elapsed.TotalSeconds -lt 60) ('應在時限附近返回，實際 ' + [int]$watch.Elapsed.TotalSeconds + ' 秒')
        Assert-Equal 1 $run.ExitCode
        Assert-Equal 'failed' $run.Document.status
        $record = Get-Record -Path $run.Document.final.record_path
        Assert-Equal 'failed' $record.result
        Assert-Equal 'timeout' $record.failure_reason
        Assert-Equal 'timeout' $record.terminated_by_entry
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$record.ended_utc)) 'ended_utc 應已寫入'
        Assert-Equal 1 (@((Get-Call -Environment $e18) | Where-Object { $_.subcommand -eq 'exec' }).Count)
        $fakePid = [int](Get-Content -LiteralPath (Join-Path $e18.Scenarios 'pid-acct-a.txt') -Raw)
        $gone = $false
        for ($i = 0; $i -lt 20 -and -not $gone; $i++) { $gone = $null -eq (Get-Process -Id $fakePid -ErrorAction SilentlyContinue); if (-not $gone) { Start-Sleep -Milliseconds 250 } }
        Assert-True $gone '假 codex 行程應已被終止'
    }
    Test-Case 'E2E-TURN-END-GRACE 回合結束後行程不結束：寬限後由入口終止，報告存在且格式合格時判成功並在紀錄註記' {
        $e19 = New-EntryEnvironment -Name 'graceend'
        Set-Scenario -Environment $e19 -Account 'acct-a' -Scenario @{ events = $successEvents; exit_code = 0; last_message = '審查完成'; report = (New-ReviewReportText); hang_seconds = 120 }
        $wrapper = Join-Path $e19.Base 'Invoke-ShortGrace.ps1'
        $wrapperText = "param([string]`$DispatchFile, [string]`$CodexPath, [string]`$MachineConfigPath)`n" +
        "Set-StrictMode -Version Latest`n`$ErrorActionPreference = 'Stop'`n" +
        "foreach (`$module in (Get-ChildItem -LiteralPath '" + $moduleRoot + "' -Filter '*.ps1' | Sort-Object -Property Name)) { . `$module.FullName }`n" +
        "`$outcome = Invoke-CodexRunMain -DispatchFile `$DispatchFile -CodexPath `$CodexPath -MachineConfigPath `$MachineConfigPath -TurnEndGraceSeconds 3`n" +
        "[Console]::Out.WriteLine((ConvertTo-AsciiJson -InputObject `$outcome.Document -Depth 10 -Compress))`nexit `$outcome.ExitCode`n"
        Write-TestUtf8 -Path $wrapper -Text $wrapperText
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-Entry -Environment $e19 -OrderPath (New-OrderFile -Environment $e19) -EntryScript $wrapper
        $watch.Stop()
        Assert-Success $run
        Assert-True ($watch.Elapsed.TotalSeconds -lt 90) ('應在寬限後返回，實際 ' + [int]$watch.Elapsed.TotalSeconds + ' 秒')
        Assert-Equal 0 $run.ExitCode
        Assert-Equal 'success' $run.Document.status
        Assert-Equal $true $run.Document.final.review_report_check.valid
        $record = Get-Record -Path $run.Document.final.record_path
        Assert-Equal 'success' $record.result
        Assert-Equal 'after-turn-end' $record.terminated_by_entry
        Assert-Equal 'recorded' $record.usage.status
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$record.ended_utc)) 'ended_utc 應已寫入'
    }
    Test-Case 'E2E-DISPATCH-UNTOUCHED 本線對現行入口目錄 scripts\dispatch 的變更只有登錄表' {
        $status = @(& git -C $repoRoot status --porcelain -- scripts/dispatch)
        if ($LASTEXITCODE -ne 0) { throw 'git status 失敗，無法核對 scripts\dispatch 的變更。' }
        $changed = @($status | ForEach-Object { ([string]$_).Substring(3).Trim('"') } | Sort-Object)
        $allowed = @('scripts/dispatch/executor-registry.json')
        $unexpected = @($changed | Where-Object { $allowed -cnotcontains $_ })
        Assert-Equal 0 ($unexpected.Count) ('scripts\dispatch 有登錄表以外的變更：' + ($unexpected -join ', '))
    }
}
finally {
    [Environment]::SetEnvironmentVariable('FAKE_CODEX_SCENARIO_DIR', $savedScenarioDir)
    [Environment]::SetEnvironmentVariable('FAKE_API_TOKEN', $savedFakeToken)
    $exitCode = Complete-TestRun
}
exit $exitCode
