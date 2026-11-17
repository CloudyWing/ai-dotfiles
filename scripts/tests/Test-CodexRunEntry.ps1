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
    param($Environment, [string]$OrderPath, [string]$CodexPath, [string]$MachinePath, [switch]$OmitMachine, [string]$EntryScript = $entryPath, [int]$TimeoutSeconds = 0, [string]$ProfileSourceRoot, [switch]$CheckProfile)
    [Environment]::SetEnvironmentVariable('FAKE_CODEX_SCENARIO_DIR', $Environment.Scenarios)
    if ([string]::IsNullOrEmpty($CodexPath)) { $CodexPath = $Environment.Codex }
    if ([string]::IsNullOrEmpty($MachinePath)) { $MachinePath = $Environment.Machine }
    $errPath = Join-Path $Environment.Base ('stderr-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    $arguments = @('-NoProfile', '-File', $EntryScript, '-DispatchFile', $OrderPath, '-CodexPath', $CodexPath)
    if (-not $OmitMachine) { $arguments += @('-MachineConfigPath', $MachinePath) }
    if (-not [string]::IsNullOrEmpty($ProfileSourceRoot)) { $arguments += @('-ProfileSourceRoot', $ProfileSourceRoot) } elseif (-not $CheckProfile) { $arguments += '-SkipProfileCheck' }
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
                'timeout_seconds', 'turn_end_grace_seconds', 'source_state_start', 'source_state_end', 'source_changed', 'exit_code', 'result', 'failure_reason', 'terminated_by_entry', 'rejection_kind', 'item_event_count', 'usage', 'last_message', 'events_path', 'stderr_path', 'report', 'review_report_check', 'permission')) {
            Assert-True ($null -ne $record.PSObject.Properties[$field]) ('缺少欄位 ' + $field)
        }
        Assert-Equal 'ai-agents.codex-run-record.v1' $record.schema
        Assert-Equal 'acct-a' $record.account.name
        Assert-Equal 'model-a' $record.model
        # 未指定時限時，紀錄寫入入口實際套用的預設值（取自 Invoke-CodexRunMain 的參數預設，不在測試寫死數字）。
        $runAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $moduleRoot '70-run.ps1'), [ref]$null, [ref]$null)
        $mainFunction = @($runAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-CodexRunMain' }, $true))[0]
        $mainParameters = $mainFunction.Body.ParamBlock.Parameters
        $defaultOf = { param([string]$Name) [int](@($mainParameters | Where-Object { $_.Name.VariablePath.UserPath -ceq $Name })[0].DefaultValue.Value) }
        Assert-True ((& $defaultOf 'TimeoutSeconds') -gt 0) '讀不到 TimeoutSeconds 的預設值'
        Assert-Equal (& $defaultOf 'TimeoutSeconds') ([int]$record.timeout_seconds)
        Assert-Equal (& $defaultOf 'TurnEndGraceSeconds') ([int]$record.turn_end_grace_seconds)
        Assert-True ($record.timeout_seconds -is [long] -or $record.timeout_seconds -is [int]) 'timeout_seconds 應為整數'
        $draft = Get-Record -Path (Join-Path $e1.Scenarios 'record-draft-acct-a.json')
        Assert-True ($null -eq $draft.ended_utc -and $null -eq $draft.result) '初稿應在 Codex 結束前寫出（ended_utc 與 result 尚為 null）'
        Assert-Equal ([int]$record.timeout_seconds) ([int]$draft.timeout_seconds) '初稿的 timeout_seconds'
        Assert-Equal ([int]$record.turn_end_grace_seconds) ([int]$draft.turn_end_grace_seconds) '初稿的 turn_end_grace_seconds'
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
        Copy-Item -LiteralPath (Join-Path $scriptsRoot 'lib') -Destination (Join-Path $worktreeScripts 'lib') -Recurse
        $null = New-Item -ItemType Directory -Path (Join-Path $worktreeScripts 'dispatch') -Force
        Copy-Item -LiteralPath (Join-Path $scriptsRoot 'dispatch\executor-registry.json') -Destination (Join-Path $worktreeScripts 'dispatch\executor-registry.json')
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
        Assert-True ($null -ne $run.Document.PSObject.Properties['fallback']) '結果文件應有 fallback 欄位'
        Assert-True ($null -eq $run.Document.fallback) '找不到登錄表（此環境的主 checkout 沒有登錄表）時 fallback 為 null'
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
        # 以 -TimeoutSeconds 指定非預設值：初稿（執行中）與完稿都記錄實際套用的 8 秒。
        $draft = Get-Record -Path (Join-Path $e18.Scenarios 'record-draft-acct-a.json')
        Assert-True ($null -eq $draft.ended_utc) '初稿應在 Codex 結束前寫出'
        Assert-Equal 8 ([int]$draft.timeout_seconds) '初稿的 timeout_seconds'
        Assert-Equal 8 ([int]$record.timeout_seconds) '完稿的 timeout_seconds'
        Assert-Equal ([int]$draft.turn_end_grace_seconds) ([int]$record.turn_end_grace_seconds)
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
        $wrapperText = "param([string]`$DispatchFile, [string]`$CodexPath, [string]`$MachineConfigPath, [switch]`$SkipProfileCheck)`n" +
        "Set-StrictMode -Version Latest`n`$ErrorActionPreference = 'Stop'`n" +
        "foreach (`$module in (Get-ChildItem -LiteralPath '" + $moduleRoot + "' -Filter '*.ps1' | Sort-Object -Property Name)) { . `$module.FullName }`n" +
        "`$outcome = Invoke-CodexRunMain -DispatchFile `$DispatchFile -CodexPath `$CodexPath -MachineConfigPath `$MachineConfigPath -TurnEndGraceSeconds 3 -SkipProfileCheck:`$SkipProfileCheck`n" +
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
        # 以非預設的回合結束寬限（3 秒）發動：初稿與完稿都記錄實際套用的值，可為 0 以上的整數。
        $draft = Get-Record -Path (Join-Path $e19.Scenarios 'record-draft-acct-a.json')
        Assert-True ($null -eq $draft.ended_utc) '初稿應在 Codex 結束前寫出'
        Assert-Equal 3 ([int]$draft.turn_end_grace_seconds) '初稿的 turn_end_grace_seconds'
        Assert-Equal 3 ([int]$record.turn_end_grace_seconds) '完稿的 turn_end_grace_seconds'
        Assert-Equal ([int]$draft.timeout_seconds) ([int]$record.timeout_seconds)
        Assert-Equal 'recorded' $record.usage.status
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$record.ended_utc)) 'ended_utc 應已寫入'
    }
    . (Join-Path $moduleRoot '45-profile-sync.ps1')
    function New-ProfileRoot {
        param($Environment, [scriptblock]$Mutate)
        # 假 repo 根目錄：登錄表複製自本 repo（可用 $Mutate 改 JSON），產生檔由該登錄表產生；兩個帳號目錄的 review 檔位檔複製自產生檔。
        $root = Join-Path $Environment.Base 'profile-root'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'scripts\dispatch') -Force
        Copy-Item -LiteralPath (Join-Path $scriptsRoot 'dispatch\executor-registry.json') -Destination (Join-Path $root 'scripts\dispatch\executor-registry.json')
        if ($null -ne $Mutate) {
            $registryFile = Join-Path $root 'scripts\dispatch\executor-registry.json'
            $registryObject = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($registryFile)) -Depth 30
            & $Mutate $registryObject
            [IO.File]::WriteAllText($registryFile, (ConvertTo-Json -InputObject $registryObject -Depth 30))
        }
        $null = Sync-CodexProfileGeneratedFile -RegistryPath (Get-CodexProfileRegistryPath -RepoRoot $root) -OutputDirectory (Get-CodexProfileGeneratedDirectory -RepoRoot $root)
        $generated = Join-Path (Get-CodexProfileGeneratedDirectory -RepoRoot $root) 'review.config.toml'
        foreach ($homePath in @($Environment.HomeA, $Environment.HomeB)) { Copy-Item -LiteralPath $generated -Destination (Join-Path $homePath 'review.config.toml') -Force }
        return $root
    }
    function New-LinkShimWrapper {
        param($Environment)
        # 沒有 Symbolic Link 權限時，以包裝腳本把連結狀態替身為「正確的連結」，其餘比對（內容、產生檔、登錄表、工作樹）照常執行。
        $wrapper = Join-Path $Environment.Base 'Invoke-LinkShim.ps1'
        $text = "param([string]`$DispatchFile, [string]`$CodexPath, [string]`$MachineConfigPath, [string]`$ProfileSourceRoot)`n" +
        "Set-StrictMode -Version Latest`n`$ErrorActionPreference = 'Stop'`n" +
        "foreach (`$module in (Get-ChildItem -LiteralPath '" + $moduleRoot + "' -Filter '*.ps1' | Sort-Object -Property Name)) { . `$module.FullName }`n" +
        "function Get-CodexProfileLinkState { param([string]`$LinkPath, [string]`$TargetPath) return [pscustomobject]@{ state = 'ok'; path = `$LinkPath; expected_target = `$TargetPath; actual_target = `$TargetPath; kind = 'SymbolicLink'; fix_commands = [string[]]@(); fix_note = `$null } }`n" +
        "`$outcome = Invoke-CodexRunMain -DispatchFile `$DispatchFile -CodexPath `$CodexPath -MachineConfigPath `$MachineConfigPath -ProfileSourceRoot `$ProfileSourceRoot`n" +
        "[Console]::Out.WriteLine((ConvertTo-AsciiJson -InputObject `$outcome.Document -Depth 10 -Compress))`nexit `$outcome.ExitCode`n"
        Write-TestUtf8 -Path $wrapper -Text $text
        return $wrapper
    }
    Test-Case 'E2E-PROFILE-MATCH 帳號目錄的檔位設定檔與 repo 產生檔一致：照常啟動並成功' {
        $e20 = New-EntryEnvironment -Name 'profilematch'
        Set-Scenario -Environment $e20 -Account 'acct-a' -Scenario @{ events = $successEvents; exit_code = 0; last_message = '審查完成'; report = (New-ReviewReportText) }
        $profileRoot = New-ProfileRoot -Environment $e20
        $run = Invoke-Entry -Environment $e20 -OrderPath (New-OrderFile -Environment $e20) -ProfileSourceRoot $profileRoot -EntryScript (New-LinkShimWrapper -Environment $e20)
        Assert-Success $run
        Assert-Equal 0 $run.ExitCode
        $calls20 = Get-Call -Environment $e20
        Assert-True ($calls20.Count -ge 1) '一致時應啟動 codex'
    }
    Test-Case 'E2E-PROFILE-DRIFT 檔位設定檔與 repo 產生檔不一致：結束碼 2、不啟動 codex、不改檔、訊息含修正命令' {
        $e21 = New-EntryEnvironment -Name 'profiledrift'
        Set-Scenario -Environment $e21 -Account 'acct-a' -Scenario @{ events = $successEvents; exit_code = 0; last_message = '審查完成'; report = (New-ReviewReportText) }
        $profileRoot = New-ProfileRoot -Environment $e21
        $driftPath = Join-Path $e21.HomeA 'review.config.toml'
        Write-TestUtf8 -Path $driftPath -Text "model = `"hand-edited`"`n"
        $before = Get-FileHash -LiteralPath $driftPath
        $beforeGenerated = Get-FileHash -LiteralPath (Join-Path (Get-CodexProfileGeneratedDirectory -RepoRoot $profileRoot) 'review.config.toml')
        $run = Invoke-Entry -Environment $e21 -OrderPath (New-OrderFile -Environment $e21) -ProfileSourceRoot $profileRoot
        Assert-Equal 2 $run.ExitCode
        Assert-Equal 'stopped' $run.Document.status
        Assert-Equal 'CodexProfileDrift' $run.Document.error.code
        Assert-True ($run.Document.error.message.Contains($driftPath)) '訊息應列出不一致的檔案路徑'
        Assert-True ($run.Document.error.message.Contains('ProfileFileDrift')) '訊息應含問題代碼'
        Assert-True ($run.Document.error.message.Contains('New-Item -ItemType SymbolicLink')) '訊息應含修正命令'
        Assert-True ($run.Document.error.message.Contains((Join-Path (Get-CodexProfileGeneratedDirectory -RepoRoot $profileRoot) 'review.config.toml'))) '修正命令的連結目標應指向比對基準 repo 的產生檔'
        $commandLines = @($run.Document.error.message -split "`r?`n" | Where-Object { $_ -match '^(New-Item|Remove-Item|Move-Item) ' })
        Assert-True ($commandLines.Count -ge 2) '每個命令應獨立成行'
        foreach ($commandLine in $commandLines) { Assert-True ($commandLine -cnotmatch '[一-鿿]') ('命令行不得混說明：' + $commandLine) }
        $calls21 = Get-Call -Environment $e21
        Assert-Equal 0 $calls21.Count '不一致時不得啟動 codex'
        Assert-Equal $before.Hash (Get-FileHash -LiteralPath $driftPath).Hash '不得改動帳號目錄的檔案'
        Assert-Equal $beforeGenerated.Hash (Get-FileHash -LiteralPath (Join-Path (Get-CodexProfileGeneratedDirectory -RepoRoot $profileRoot) 'review.config.toml')).Hash '不得改動 repo 產生檔'
    }
    Test-Case 'E2E-PROFILE-SCOPE-UNUSED 只檢查實際要使用的帳號：第一個帳號一致、未使用的第二個帳號不一致時照常成功' {
        $e22 = New-EntryEnvironment -Name 'profilescope1'
        Set-Scenario -Environment $e22 -Account 'acct-a' -Scenario @{ events = $successEvents; exit_code = 0; last_message = '審查完成'; report = (New-ReviewReportText) }
        $profileRoot = New-ProfileRoot -Environment $e22
        Write-TestUtf8 -Path (Join-Path $e22.HomeB 'review.config.toml') -Text "model = `"hand-edited`"`n"
        $run = Invoke-Entry -Environment $e22 -OrderPath (New-OrderFile -Environment $e22) -ProfileSourceRoot $profileRoot -EntryScript (New-LinkShimWrapper -Environment $e22)
        Assert-Success $run
        Assert-Equal 0 $run.ExitCode
        Assert-Equal @('acct-a') @($run.Document.attempts | ForEach-Object { $_.account })
    }
    Test-Case 'E2E-PROFILE-SCOPE-FAILOVER 換帳號後對新的候選帳號在使用前再比對：第一個被拒、第二個不一致時結束碼 2，不啟動第二個帳號' {
        $e23 = New-EntryEnvironment -Name 'profilescope2'
        Set-Scenario -Environment $e23 -Account 'acct-a' -Scenario @{ events = $usageLimitEvents; exit_code = 1; last_message = $null; report = $null }
        Set-Scenario -Environment $e23 -Account 'acct-b' -Scenario @{ events = $successEvents; exit_code = 0; last_message = 'ok'; report = (New-ReviewReportText) }
        $profileRoot = New-ProfileRoot -Environment $e23
        $driftPath = Join-Path $e23.HomeB 'review.config.toml'
        Write-TestUtf8 -Path $driftPath -Text "model = `"hand-edited`"`n"
        $run = Invoke-Entry -Environment $e23 -OrderPath (New-OrderFile -Environment $e23) -ProfileSourceRoot $profileRoot -EntryScript (New-LinkShimWrapper -Environment $e23)
        Assert-Equal 2 $run.ExitCode
        Assert-Equal 'CodexProfileDrift' $run.Document.error.code
        Assert-True ($run.Document.error.message.Contains($driftPath)) '訊息應列出第二個帳號的檔案'
        Assert-Equal @('acct-a') @($run.Document.attempts | ForEach-Object { $_.account })
        $calls23 = Get-Call -Environment $e23
        Assert-Equal 0 @($calls23 | Where-Object { $_.subcommand -ceq 'exec' -and $_.account -ceq 'acct-b' }).Count '不得啟動第二個帳號'
    }
    Test-Case 'E2E-PROFILE-MAIN-ROOT 未指定 -ProfileSourceRoot 時以 machine.json 所在的主 checkout 為比對基準，修正命令的連結目標指向主 checkout' {
        $e24 = New-EntryEnvironment -Name 'profilemain'
        Set-Scenario -Environment $e24 -Account 'acct-a' -Scenario @{ events = $successEvents; exit_code = 0; last_message = 'ok'; report = (New-ReviewReportText) }
        $mainRoot = $e24.Repo.Root
        $null = New-Item -ItemType Directory -Path (Join-Path $mainRoot 'scripts\dispatch') -Force
        Copy-Item -LiteralPath (Join-Path $scriptsRoot 'dispatch\executor-registry.json') -Destination (Join-Path $mainRoot 'scripts\dispatch\executor-registry.json')
        $null = Sync-CodexProfileGeneratedFile -RegistryPath (Get-CodexProfileRegistryPath -RepoRoot $mainRoot) -OutputDirectory (Get-CodexProfileGeneratedDirectory -RepoRoot $mainRoot)
        Write-TestUtf8 -Path (Join-Path $e24.HomeA 'review.config.toml') -Text "model = `"hand-edited`"`n"
        $run = Invoke-Entry -Environment $e24 -OrderPath (New-OrderFile -Environment $e24) -CheckProfile
        Assert-Equal 2 $run.ExitCode
        Assert-Equal 'CodexProfileDrift' $run.Document.error.code
        Assert-True ($run.Document.error.message.Contains((Join-Path $mainRoot 'scripts\codex-profiles\review.config.toml'))) '連結目標應指向主 checkout 的產生檔'
        Assert-True (-not $run.Document.error.message.Contains((Join-Path $repoRoot 'scripts\codex-profiles'))) '不得指向入口所在 repo 的產生檔'
    }
    Test-Case 'E2E-PROFILE-ALL-MISSING 所有已登入帳號的檔位檔都缺失：回報 CodexProfileDrift（結束碼 2）與修正命令，不是 CodexAccountsAllUnavailable，不啟動 codex' {
        $e25 = New-EntryEnvironment -Name 'profileallmissing'
        $profileRoot = New-ProfileRoot -Environment $e25
        foreach ($homePath in @($e25.HomeA, $e25.HomeB)) { Remove-Item -LiteralPath (Join-Path $homePath 'review.config.toml') -Force }
        $run = Invoke-Entry -Environment $e25 -OrderPath (New-OrderFile -Environment $e25) -ProfileSourceRoot $profileRoot
        Assert-Equal 2 $run.ExitCode
        Assert-Equal 'CodexProfileDrift' $run.Document.error.code
        Assert-True ($run.Document.error.code -cne 'CodexAccountsAllUnavailable') '不得回報帳號全數不可用'
        Assert-True ($run.Document.error.message.Contains('ProfileFileMissing')) '訊息應含代碼'
        Assert-True ($run.Document.error.message.Contains((Join-Path $e25.HomeA 'review.config.toml')) -and $run.Document.error.message.Contains((Join-Path $e25.HomeB 'review.config.toml'))) '應列出每個缺檔的帳號'
        $commandLines = @($run.Document.error.message -split "`r?`n" | Where-Object { $_ -match '^New-Item -ItemType SymbolicLink ' })
        Assert-True ($commandLines.Count -ge 2) '每個帳號各有可貼上的建立連結命令'
        $calls25 = Get-Call -Environment $e25
        Assert-Equal 0 $calls25.Count '不得啟動 codex'
    }
    Test-Case 'E2E-PROFILE-REGULAR-FILE 帳號目錄的檔位檔是內容相同的一般檔案：判不一致（ProfileFileNotLink），結束碼 2，不啟動 codex' {
        $e26 = New-EntryEnvironment -Name 'profileregular'
        Set-Scenario -Environment $e26 -Account 'acct-a' -Scenario @{ events = $successEvents; exit_code = 0; last_message = '審查完成'; report = (New-ReviewReportText) }
        $profileRoot = New-ProfileRoot -Environment $e26
        $run = Invoke-Entry -Environment $e26 -OrderPath (New-OrderFile -Environment $e26) -ProfileSourceRoot $profileRoot
        Assert-Equal 2 $run.ExitCode
        Assert-Equal 'CodexProfileDrift' $run.Document.error.code
        Assert-True ($run.Document.error.message.Contains('ProfileFileNotLink')) '訊息應含代碼'
        $calls26 = Get-Call -Environment $e26
        Assert-Equal 0 $calls26.Count '不得啟動 codex'
    }
    Test-Case 'E2E-PROFILE-TREE-NOT-LANDED 入口所在工作樹的登錄表設定尚未落地到主 checkout：結束碼 2，訊息說明尚未落地，不啟動 codex' {
        $e27 = New-EntryEnvironment -Name 'profiletree'
        Set-Scenario -Environment $e27 -Account 'acct-a' -Scenario @{ events = $successEvents; exit_code = 0; last_message = '審查完成'; report = (New-ReviewReportText) }
        # 主 checkout（假）的登錄表與產生檔是另一組設定，帳號檔位檔與它一致；入口所在 repo（本 repo）的登錄表則是現行設定。
        $profileRoot = New-ProfileRoot -Environment $e27 -Mutate { param($r) @($r.executors | Where-Object { $_.platform -ceq 'codex' -and $_.profile -ceq 'review' })[0].profileSettings.model = 'm-main-checkout-only' }
        $run = Invoke-Entry -Environment $e27 -OrderPath (New-OrderFile -Environment $e27) -ProfileSourceRoot $profileRoot -EntryScript (New-LinkShimWrapper -Environment $e27)
        Assert-Equal 2 $run.ExitCode
        Assert-Equal 'CodexProfileDrift' $run.Document.error.code
        Assert-True ($run.Document.error.message.Contains('TreeRegistryNotLanded')) '訊息應含代碼'
        Assert-True ($run.Document.error.message.Contains('尚未落地')) '訊息應說明工作樹的登錄表尚未落地'
        $calls27 = Get-Call -Environment $e27
        Assert-Equal 0 $calls27.Count '不得啟動 codex'
    }
    # ---------- 備援 model 與全部帳號不可用時的下一位執行者 ----------
    # 入口會比對所在工作樹的登錄表與 -ProfileSourceRoot 的產生檔，因此假 repo 沿用出貨登錄表的備援清單，不另行改寫；
    # 執行者 id、顯示名稱、主要與備援 model 都由登錄表讀出，不寫死出貨登錄表的值。review 檔位沒有備援 model 時相關案例略過。
    function Get-ReviewExecutorNode {
        param([string]$ProfileRoot)
        $registryObject = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Get-CodexProfileRegistryPath -RepoRoot $ProfileRoot))) -Depth 30
        return @($registryObject.executors | Where-Object { $_.platform -ceq 'codex' -and $_.profile -ceq 'review' })[0]
    }
    Test-Case 'E2E-FALLBACK-MODEL 帳號不支援主要 model 時同帳號改用備援 model：第二次嘗試帶 -c model=，紀錄與結果註明實際 model' {
        $e30 = New-EntryEnvironment -Name 'fallbackmodel'
        $profileRoot = New-ProfileRoot -Environment $e30
        $reviewNode = Get-ReviewExecutorNode -ProfileRoot $profileRoot
        $primary = [string]$reviewNode.profileSettings.model
        $fallbacks = @($reviewNode.profileSettings.PSObject.Properties['fallbackModels'] | ForEach-Object { $_.Value })
        if ($fallbacks.Count -eq 0) { Write-Output 'SKIP E2E-FALLBACK-MODEL 出貨登錄表的 review 檔位沒有備援 model'; return }
        $fb = [string]$fallbacks[0]
        Set-Scenario -Environment $e30 -Account 'acct-a' -Scenario @{ events = $modelEvents; exit_code = 1; last_message = $null; report = $null }
        Set-Scenario -Environment $e30 -Account ('acct-a@' + $fb) -Scenario @{ events = $successEvents; exit_code = 0; last_message = '審查完成'; report = (New-ReviewReportText) }
        $run = Invoke-Entry -Environment $e30 -OrderPath (New-OrderFile -Environment $e30) -ProfileSourceRoot $profileRoot -EntryScript (New-LinkShimWrapper -Environment $e30)
        Assert-Success $run
        Assert-Equal 0 $run.ExitCode
        $attempts = @($run.Document.attempts)
        Assert-Equal @('acct-a', 'acct-a') @($attempts | ForEach-Object { $_.account })
        Assert-Equal @($primary, $fb) @($attempts | ForEach-Object { $_.model })
        Assert-Equal @('rejected', 'success') @($attempts | ForEach-Object { $_.result })
        Assert-Equal 'model-not-supported' $attempts[0].rejection_kind
        Assert-Equal $fb $run.Document.final.model
        Assert-Equal 'fallback' $run.Document.final.model_source
        Assert-True ($null -eq $run.Document.fallback) '成功時 fallback 為 null'
        $records = @($attempts | ForEach-Object { Get-Record -Path $_.record_path })
        Assert-Equal @('primary', 'fallback') @($records | ForEach-Object { $_.model_source })
        Assert-Equal $fb $records[1].model
        $execCalls = @((Get-Call -Environment $e30) | Where-Object { $_.subcommand -eq 'exec' })
        Assert-Equal 2 $execCalls.Count
        Assert-Equal 0 (@($execCalls[0].args | Where-Object { $_ -match '^model=' }).Count) '主要 model 的嘗試不應帶 model 覆寫'
        Assert-Equal 1 (@($execCalls[1].args | Where-Object { $_ -match ('^model="?' + [regex]::Escape($fb) + '"?$') }).Count) '備援 model 的嘗試應帶 -c model=<備援 model>'
        $stdin = Get-Content -LiteralPath (Join-Path $e30.Scenarios 'stdin-acct-a.txt') -Raw
        Assert-True ($stdin.Contains('審查者: ' + [string]$reviewNode.display + '；model: ' + $fb + '（備援）')) ('prompt 未註明實際 model：' + $stdin)
        $health = Get-Content -LiteralPath $e30.Health -Raw | ConvertFrom-Json
        Assert-Equal @($primary) @($health.entries | ForEach-Object { $_.model }) '健康狀態檔應只記錄被拒絕的主要 model'
        # 第二次發動：主要 model 已記為不支援，直接以備援 model 嘗試，不再試主要 model。
        $callsBefore = (Get-Call -Environment $e30).Count
        $second = Invoke-Entry -Environment $e30 -OrderPath (New-OrderFile -Environment $e30 -FileName 'order2.md') -ProfileSourceRoot $profileRoot -EntryScript (New-LinkShimWrapper -Environment $e30)
        Assert-Equal 0 $second.ExitCode
        Assert-Equal @($fb) @($second.Document.attempts | ForEach-Object { $_.model })
        Assert-Equal 1 (@((Get-Call -Environment $e30) | Select-Object -Skip $callsBefore | Where-Object { $_.subcommand -eq 'exec' }).Count)
    }
    Test-Case 'E2E-FALLBACK-MODEL-CHAIN 備援 model 也被拒時依序試下一個備援 model，都被拒才換下一個帳號' {
        $e31 = New-EntryEnvironment -Name 'fallbackchain'
        $profileRoot = New-ProfileRoot -Environment $e31
        $reviewNode = Get-ReviewExecutorNode -ProfileRoot $profileRoot
        $fallbacks = @($reviewNode.profileSettings.PSObject.Properties['fallbackModels'] | ForEach-Object { $_.Value })
        if ($fallbacks.Count -eq 0) { Write-Output 'SKIP E2E-FALLBACK-MODEL-CHAIN 出貨登錄表的 review 檔位沒有備援 model'; return }
        Set-Scenario -Environment $e31 -Account 'acct-a' -Scenario @{ events = $modelEvents; exit_code = 1; last_message = $null; report = $null }
        Set-Scenario -Environment $e31 -Account 'acct-b' -Scenario @{ events = $successEvents; exit_code = 0; last_message = '審查完成'; report = (New-ReviewReportText) }
        $run = Invoke-Entry -Environment $e31 -OrderPath (New-OrderFile -Environment $e31) -ProfileSourceRoot $profileRoot -EntryScript (New-LinkShimWrapper -Environment $e31)
        Assert-Success $run
        Assert-Equal 0 $run.ExitCode
        $attempts = @($run.Document.attempts)
        Assert-Equal (@(@('acct-a') * (1 + $fallbacks.Count)) + @('acct-b')) @($attempts | ForEach-Object { $_.account })
        Assert-Equal (@([string]$reviewNode.profileSettings.model) + @($fallbacks | ForEach-Object { [string]$_ })) @($attempts | Where-Object { $_.account -eq 'acct-a' } | ForEach-Object { $_.model })
        Assert-Equal 'primary' $run.Document.final.model_source
        Assert-Equal (1 + $fallbacks.Count) (@((Get-Content -LiteralPath $e31.Health -Raw | ConvertFrom-Json).entries).Count) '每個被拒的 model 各有一筆紀錄'
    }
    Test-Case 'E2E-FALLBACK-MODEL-USAGE-LIMIT 額度用完不是 model 問題：不在同帳號改試備援 model，直接換下一個帳號' {
        $e32 = New-EntryEnvironment -Name 'fallbackusage'
        $profileRoot = New-ProfileRoot -Environment $e32
        Set-Scenario -Environment $e32 -Account 'acct-a' -Scenario @{ events = $usageLimitEvents; exit_code = 1; last_message = $null; report = $null }
        Set-Scenario -Environment $e32 -Account 'acct-b' -Scenario @{ events = $successEvents; exit_code = 0; last_message = '審查完成'; report = (New-ReviewReportText) }
        $run = Invoke-Entry -Environment $e32 -OrderPath (New-OrderFile -Environment $e32) -ProfileSourceRoot $profileRoot -EntryScript (New-LinkShimWrapper -Environment $e32)
        Assert-Success $run
        Assert-Equal 0 $run.ExitCode
        Assert-Equal @('acct-a', 'acct-b') @($run.Document.attempts | ForEach-Object { $_.account })
        Assert-Equal 'primary' $run.Document.final.model_source
    }
    Test-Case 'E2E-NEXT-EXECUTOR-EXHAUSTED 候選帳號都被拒：結束碼 4，fallback 帶選派入口選出的下一位執行者，不寫任何狀態檔' {
        $e33 = New-EntryEnvironment -Name 'nextexhausted'
        $profileRoot = New-ProfileRoot -Environment $e33
        $reviewId = [string](Get-ReviewExecutorNode -ProfileRoot $profileRoot).id
        Set-Scenario -Environment $e33 -Account 'acct-a' -Scenario @{ events = $usageLimitEvents; exit_code = 1; last_message = $null; report = $null }
        Set-Scenario -Environment $e33 -Account 'acct-b' -Scenario @{ events = $usageLimitEvents; exit_code = 1; last_message = $null; report = $null }
        $before = Get-DirectorySnapshot -Root $e33.MachineDirectory
        $run = Invoke-Entry -Environment $e33 -OrderPath (New-OrderFile -Environment $e33) -ProfileSourceRoot $profileRoot -EntryScript (New-LinkShimWrapper -Environment $e33)
        Assert-Success $run
        Assert-Equal 4 $run.ExitCode
        Assert-Equal 'CodexAccountsExhausted' $run.Document.error.code
        Assert-Equal $reviewId $run.Document.fallback.unavailable_executor
        $selection = $run.Document.fallback.selection
        Assert-Equal 'selected' $selection.status
        Assert-Equal 'claude' $selection.executor.platform
        Assert-True ($selection.executor.id -cne $reviewId) '下一位不應是被拒絕的執行者'
        Assert-Equal @($reviewId) @($selection.labels.offline)
        Assert-Equal @('family') @($selection.unmetPreferences)
        Assert-True ($selection.dispatchLine.Contains('同家族審查') -and $selection.dispatchLine.Contains('略過=' + $reviewId + ':offline')) $selection.dispatchLine
        Assert-Equal $before (Get-DirectorySnapshot -Root $e33.MachineDirectory) '額度用完不應留下任何狀態檔，下一次派工照常先試 Codex'
    }
    Test-Case 'E2E-NEXT-EXECUTOR-ALL-UNAVAILABLE 全部帳號未登入：結束碼 4、CodexAccountsAllUnavailable，fallback 同樣帶下一位執行者' {
        $e34 = New-EntryEnvironment -Name 'nextunavailable'
        $profileRoot = New-ProfileRoot -Environment $e34
        Remove-Item -LiteralPath (Join-Path $e34.HomeA 'auth.json'), (Join-Path $e34.HomeB 'auth.json') -Force
        $run = Invoke-Entry -Environment $e34 -OrderPath (New-OrderFile -Environment $e34) -ProfileSourceRoot $profileRoot -EntryScript (New-LinkShimWrapper -Environment $e34)
        Assert-Success $run
        Assert-Equal 4 $run.ExitCode
        Assert-Equal 'CodexAccountsAllUnavailable' $run.Document.error.code
        Assert-Equal 'selected' $run.Document.fallback.selection.status
        Assert-Equal 'claude' $run.Document.fallback.selection.executor.platform
        Assert-Equal 0 ((Get-Call -Environment $e34).Count)
    }
    Test-Case 'E2E-ROLES Frontend Reviewer 與 Contract Auditor 以同一入口發動：報告依 report_name 落在輸出目錄且通過 manifest 檢查，prompt 指向各自的角色規則檔' {
        foreach ($role in @(@('frontend-reviewer', 'frontend-reviewer-report.md'), @('contract-auditor', 'contract-auditor-report.md'))) {
            $envRole = New-EntryEnvironment -Name ('role-' + $role[0])
            $roleFile = Join-Path $envRole.Exec ($role[0] + '.toml')
            Copy-Item -LiteralPath (Join-Path $repoRoot ('agents\codex\' + $role[0] + '.toml')) -Destination $roleFile
            Set-Scenario -Environment $envRole -Account 'acct-a' -Scenario @{ events = $successEvents; exit_code = 0; last_message = '審查完成'; report = (New-ReviewReportText) }
            $orderRole = New-OrderFile -Environment $envRole -Slug ($role[0] + '-p1') -Override @{ role_file = $roleFile; report_name = $role[1] }
            $runRole = Invoke-Entry -Environment $envRole -OrderPath $orderRole
            Assert-Success $runRole
            Assert-Equal 0 $runRole.ExitCode
            Assert-Equal 'success' $runRole.Document.status
            Assert-Equal $role[1] (Split-Path -Leaf $runRole.Document.final.report_path)
            Assert-True (Test-Path -LiteralPath $runRole.Document.final.report_path) ($role[0] + ' 報告不存在')
            Assert-Equal $true $runRole.Document.final.review_report_check.valid
            $stdinRole = Get-Content -LiteralPath (Join-Path $envRole.Scenarios 'stdin-acct-a.txt') -Raw
            Assert-True ($stdinRole.Contains($roleFile)) ('prompt 未指向角色規則檔：' + $stdinRole)
            Assert-True ($stdinRole.Contains('報告檔: ' + $runRole.Document.final.report_path)) ('prompt 的報告檔行不符：' + $stdinRole)
            Assert-True (-not $stdinRole.Contains('以 Reviewer 身分')) 'prompt 不應把所有角色寫成 Reviewer'
        }
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
