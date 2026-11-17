#Requires -Version 7.0
[CmdletBinding()]
param(
    # 單獨重跑啟動修正的一段。All 為全部案例。
    [ValidateSet('All', 'Handle', 'Encoding', 'Env', 'Wait')]
    [string]$Case = 'All'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$moduleRoot = Join-Path $scriptsRoot 'codex-run'
. (Join-Path $PSScriptRoot 'codex-run-fixtures\TestHelpers.ps1')
foreach ($module in @('00-common.ps1', '20-process.ps1', '25-sandbox.ps1')) { . (Join-Path $moduleRoot $module) }

$hostPath = [Environment]::ProcessPath
$startedPids = New-Object 'System.Collections.Generic.List[int]'
$envNames = @('FAKE_API_TOKEN', 'FAKE_SECRET_KEY', 'NUGET_API_KEY', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0')
$savedEnv = @{}
foreach ($name in $envNames) { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name) }

function Stop-FixtureProcessTree {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return }
    $null = & taskkill.exe /PID $ProcessId /T /F 2>&1
}

# fake codex 的本體。依 $env:FAKE_MODE 決定行為，結果寫到 $env:CODEX_HOME 之下。
$fakeBody = @'
$mode = $env:FAKE_MODE
$home1 = $env:CODEX_HOME
if ($mode -eq 'args-stdin-env') {
    [IO.File]::WriteAllText((Join-Path $home1 'args.json'), (ConvertTo-Json -InputObject @($args) -Compress), (New-Object Text.UTF8Encoding($false)))
    $ms = New-Object IO.MemoryStream
    [Console]::OpenStandardInput().CopyTo($ms)
    [IO.File]::WriteAllText((Join-Path $home1 'stdin.hex'), [Convert]::ToHexString($ms.ToArray()), (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $home1 'env.txt'), ((Get-ChildItem Env: | ForEach-Object { $_.Name }) -join "`n"), (New-Object Text.UTF8Encoding($false)))
    $stdout = [Console]::OpenStandardOutput()
    $raw = [byte[]]@(0xE4, 0xB8, 0xAD, 0x0A, 0xFF, 0xFE, 0x0A)
    $stdout.Write($raw, 0, $raw.Length)
    $stdout.Flush()
    $stderr = [Console]::OpenStandardError()
    $stderr.Write([byte[]]@(0x45, 0x52, 0x52, 0x0A), 0, 4)
    $stderr.Flush()
    exit 0
}
if ($mode -in @('emit-then-sleep', 'hang-no-turn', 'turn-end-hang', 'turn-end-no-message')) {
    [IO.File]::WriteAllText((Join-Path $home1 'pid.txt'), [string]$PID, (New-Object Text.UTF8Encoding($false)))
    $stdout = [Console]::OpenStandardOutput()
    $lines = if ($mode -eq 'emit-then-sleep') { @('{"type":"turn.started"}') } elseif ($mode -eq 'hang-no-turn') { @('{"type":"turn.started"}', '{"type":"item.started","item":{"type":"command_execution"}}') } else { @('{"type":"turn.started"}', '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}') }
    foreach ($line in $lines) { $bytes = [Text.Encoding]::UTF8.GetBytes($line + "`n"); $stdout.Write($bytes, 0, $bytes.Length) }
    $stdout.Flush()
    $stderr = [Console]::OpenStandardError()
    $stderr.Write([byte[]]@(0x45, 0x0A), 0, 2)
    $stderr.Flush()
    $messageIndex = [array]::IndexOf(@($args), '--output-last-message')
    if ($mode -eq 'turn-end-hang' -and $messageIndex -ge 0) { [IO.File]::WriteAllText(@($args)[$messageIndex + 1], 'done', (New-Object Text.UTF8Encoding($false))) }
    Start-Sleep -Seconds $(if ($mode -eq 'emit-then-sleep') { 9 } else { 120 })
    exit 0
}
if ($mode -eq 'mxc-ok') { if ($args -contains 'sandbox' -and $args -contains ':workspace') { Write-Output 'MXC_OK' }; exit 0 }
if ($mode -eq 'mxc-exit1') { Write-Output 'MXC_OK'; exit 1 }
if ($mode -eq 'mxc-silent') { exit 0 }
exit 9
'@

try {
    $root = New-TestDirectory -Name 'launch'
    $fakeDir = Join-Path $root 'fake'
    $fakeCodex = New-FakeCodexCmd -Directory $fakeDir -ScriptText $fakeBody
    $aiRoot = Join-Path $root 'ai agents'
    $null = New-Item -ItemType Directory -Path $aiRoot -Force

    function Invoke-FakeRun {
        param([string]$Mode, [string[]]$Argument = @('exec', '-'), [string]$Prompt = 'p', [string]$Name = 'run', [hashtable]$Extra = @{})
        $codexHome = Join-Path $root ($Name + '-home')
        $null = New-Item -ItemType Directory -Path $codexHome -Force
        [Environment]::SetEnvironmentVariable('FAKE_MODE', $Mode)
        $result = Invoke-RunCodexProcess -CodexPath $fakeCodex -Argument $Argument -Prompt $Prompt -CodexHome $codexHome -EventStreamPath (Join-Path $root ($Name + '.events.jsonl')) -StderrPath (Join-Path $root ($Name + '.stderr.txt')) @Extra
        return [pscustomobject]@{ Result = $result; Home = $codexHome; Events = (Join-Path $root ($Name + '.events.jsonl')); Stderr = (Join-Path $root ($Name + '.stderr.txt')) }
    }

    if ($Case -eq 'All') {
        # ---------- 權限設定參數 ----------
        $execRoot = Join-Path $root 'exec dir'
        $outDir = Join-Path $root 'report\runs\review-x-1'
        $reportRoot = Join-Path $root 'report\line-a'
        $permissionArgs = @(New-RunPermissionArgument -ExecutionRoot $execRoot -OutputDirectory $outDir -AiAgentsRoot $aiRoot -ReportLineRoot $reportRoot)
        $filesystem = [string]($permissionArgs | Where-Object { $_.StartsWith('permissions.dispatch_review.filesystem=', [StringComparison]::Ordinal) })
        Test-Case 'PERM-ARGS 權限設定參數含 MXC、預設權限設定與 filesystem' {
            Assert-True ($permissionArgs -contains 'windows.sandbox="mxc"') '缺少 windows.sandbox'
            Assert-True ($permissionArgs -contains 'default_permissions="dispatch_review"') '缺少 default_permissions'
            Assert-True ($filesystem.Length -gt 0) '缺少 filesystem'
            Assert-Equal 6 ($permissionArgs.Count)
            Assert-Equal @('-c', '-c', '-c') @($permissionArgs | Where-Object { $_ -ceq '-c' })
        }
        Test-Case 'PERM-FILESYSTEM filesystem 含執行目錄 read、ai-agents read、輸出目錄 write 與五個 deny 樣式' {
            Assert-True $filesystem.Contains("'" + $execRoot + "'=`"read`"") 'execution_root read'
            Assert-True $filesystem.Contains("'" + $aiRoot + "'={`".`"=`"read`", `"**/.env`"=`"deny`"") 'ai-agents read（子表，附 deny 樣式）'
            Assert-True $filesystem.Contains("'" + $outDir + "'=`"write`"") '輸出目錄 write'
            Assert-True $filesystem.Contains("'" + $reportRoot + "'={`".`"=`"read`", `"**/.env`"=`"deny`"") 'report_line_root read（在執行目錄之外時以絕對路徑鍵的子表表達，附 deny 樣式）'
            Assert-True $filesystem.Contains('":minimal"="read"') ':minimal'
            Assert-True $filesystem.Contains('glob_scan_max_depth=6') 'glob_scan_max_depth'
            Assert-True $filesystem.Contains('":workspace_roots"={"."="read"') ':workspace_roots'
            foreach ($pattern in @('**/.env', '**/.env.*', '**/*.pem', '**/*.key', '**/secrets.*')) {
                Assert-True $filesystem.Contains('"' + $pattern + '"="deny"') ($pattern + ' deny')
            }
            # 工作目錄的 :workspace_roots 與兩個工作目錄之外的可讀根目錄子表各一組，共 15 個 deny。
            Assert-Equal 15 (([regex]::Matches($filesystem, '="deny"')).Count)
        }
        Test-Case 'PERM-REPORT-ROOT-UNDER-EXEC report_line_root 在執行目錄之下時不重複加 read，但仍列入權限計畫的 read_roots' {
            $underReport = Join-Path $execRoot 'report\line-a'
            $underArgs = @(New-RunPermissionArgument -ExecutionRoot $execRoot -OutputDirectory (Join-Path $underReport 'runs\x') -AiAgentsRoot $aiRoot -ReportLineRoot $underReport)
            $underFs = [string]($underArgs | Where-Object { $_.StartsWith('permissions.dispatch_review.filesystem=', [StringComparison]::Ordinal) })
            Assert-True (-not $underFs.Contains("'" + $underReport + "'=")) '在執行目錄之下不應重複加 read'
            $plan = Get-RunPermissionPlan -ExecutionRoot $execRoot -OutputDirectory (Join-Path $underReport 'runs\x') -AiAgentsRoot $aiRoot -ReportLineRoot $underReport
            Assert-Equal @($execRoot, $aiRoot, $underReport) @($plan.read_roots)
        }
        Test-Case 'PERM-DUPLICATE-KEYS 可讀根目錄路徑相同時不輸出重複的 TOML 鍵（不分大小寫，含 execution_root 即 ~\.ai-agents）' {
            function Get-FilesystemValue {
                param([string]$Execution, [string]$Ai, [string]$Report, [string]$Output)
                $permArgs = @(New-RunPermissionArgument -ExecutionRoot $Execution -OutputDirectory $Output -AiAgentsRoot $Ai -ReportLineRoot $Report)
                return [string]($permArgs | Where-Object { $_.StartsWith('permissions.dispatch_review.filesystem=', [StringComparison]::Ordinal) })
            }
            function Get-KeyCount {
                param([string]$Text, [string]$Path)
                return ([regex]::Matches($Text, [regex]::Escape("'" + $Path + "'="), [Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
            }
            # 情形 1：execution_root 即 ~\.ai-agents。
            $same = Get-FilesystemValue -Execution $aiRoot -Ai $aiRoot -Report $reportRoot -Output $outDir
            Assert-Equal 1 (Get-KeyCount -Text $same -Path $aiRoot) 'execution_root 即 ai-agents 時該鍵只能出現一次'
            # 情形 2：大小寫與結尾分隔字元不同的同一路徑。
            $caseVariant = Get-FilesystemValue -Execution $aiRoot -Ai ($aiRoot.ToUpperInvariant() + '\') -Report $reportRoot -Output $outDir
            Assert-Equal 1 (Get-KeyCount -Text $caseVariant -Path $aiRoot) '大小寫不同的同一路徑只能出現一次'
            # 情形 3：report_line_root 與 execution_root 相同，或與 ~\.ai-agents 相同。
            $reportIsExec = Get-FilesystemValue -Execution $execRoot -Ai $aiRoot -Report $execRoot -Output (Join-Path $execRoot 'runs\x')
            Assert-Equal 1 (Get-KeyCount -Text $reportIsExec -Path $execRoot) 'report_line_root 即 execution_root 時該鍵只能出現一次'
            $reportIsAi = Get-FilesystemValue -Execution $execRoot -Ai $aiRoot -Report $aiRoot -Output $outDir
            Assert-Equal 1 (Get-KeyCount -Text $reportIsAi -Path $aiRoot) 'report_line_root 即 ai-agents 時該鍵只能出現一次'
            # 計畫的 read_roots 同樣去重。
            $plan = Get-RunPermissionPlan -ExecutionRoot $aiRoot -OutputDirectory $outDir -AiAgentsRoot $aiRoot -ReportLineRoot $aiRoot
            Assert-Equal @($aiRoot) @($plan.read_roots)
        }
        Test-Case 'PERM-PLAN 權限計畫供執行紀錄使用' {
            $plan = Get-RunPermissionPlan -ExecutionRoot ($execRoot + '\') -OutputDirectory $outDir -AiAgentsRoot $aiRoot
            Assert-Equal 'dispatch_review' $plan.name
            Assert-Equal @($execRoot, $aiRoot) @($plan.read_roots)
            $planWithReport = Get-RunPermissionPlan -ExecutionRoot $execRoot -OutputDirectory $outDir -AiAgentsRoot $aiRoot -ReportLineRoot $reportRoot
            Assert-Equal @($execRoot, $aiRoot, $reportRoot) @($planWithReport.read_roots)
            Assert-Equal @($outDir) @($plan.write_roots)
            Assert-Equal 5 (@($plan.deny_patterns).Count)
        }
        Test-Case 'PERM-INVALID 磁碟根目錄、相對路徑與含單引號的路徑以 RunPermissionArgumentInvalid 拒絕' {
            foreach ($bad in @('C:\', 'relative\dir', "C:\a'b")) {
                $null = Assert-Throws -Code 'RunPermissionArgumentInvalid' -Script { New-RunPermissionArgument -ExecutionRoot $bad -OutputDirectory $outDir -AiAgentsRoot $aiRoot }
            }
        }
        Test-Case 'PERM-NO-SANDBOX-FLAG exec 引數不含 --sandbox，注入 --sandbox 時 RunPermissionArgumentInvalid' {
            $exec = @(New-RunExecArgument -ExecutionRoot $execRoot -Profile review -OutputDirectory $outDir -LastMessagePath (Join-Path $root 'last.md') -IsGitRepository $true -AiAgentsRoot $aiRoot)
            Assert-True (-not ($exec -contains '--sandbox')) 'exec 引數含 --sandbox'
            Assert-True (-not (@($exec | Where-Object { $_ -like '--sandbox*' }).Count -gt 0)) 'exec 引數含 --sandbox*'
            $null = Assert-Throws -Code 'RunPermissionArgumentInvalid' -Script { Assert-RunPermissionArgument -Argument ($permissionArgs + @('--sandbox', 'read-only')) }
            $null = Assert-Throws -Code 'RunPermissionArgumentInvalid' -Script { Assert-RunPermissionArgument -Argument @('--sandbox=workspace-write') }
        }
        Test-Case 'EXEC-MODEL-OVERRIDE 備援 model 以 -c model= 放在 --profile 之後、exec 之前；未提供時不出現；名稱不合法時拒絕' {
            $last = Join-Path $root 'last.md'
            $override = @(New-RunExecArgument -ExecutionRoot $execRoot -Profile review -OutputDirectory $outDir -LastMessagePath $last -IsGitRepository $true -AiAgentsRoot $aiRoot -ModelOverride 'fb-model.1')
            $plain = @(New-RunExecArgument -ExecutionRoot $execRoot -Profile review -OutputDirectory $outDir -LastMessagePath $last -IsGitRepository $true -AiAgentsRoot $aiRoot)
            Assert-Equal @('--cd', $execRoot, '--profile', 'review', '-c', 'model="fb-model.1"') @($override[0..5])
            Assert-True ([array]::IndexOf($override, 'exec') -gt 5) 'model 覆寫應在 exec 之前'
            Assert-Equal 0 (@($plain | Where-Object { $_ -like 'model=*' }).Count) '未提供備援 model 時不應有 model 覆寫'
            Assert-Equal ($plain.Count + 2) $override.Count
            $null = Assert-Throws -Code 'RunModelOverrideInvalid' -Script { New-RunExecArgument -ExecutionRoot $execRoot -Profile review -OutputDirectory $outDir -LastMessagePath $last -IsGitRepository $true -AiAgentsRoot $aiRoot -ModelOverride 'bad" x' }
        }
        Test-Case 'EXEC-SEARCH -Search 時 --search 緊接在權限設定之後、exec 之前；未指定時不出現' {
            $last = Join-Path $root 'last.md'
            $plain = @(New-RunExecArgument -ExecutionRoot $execRoot -Profile content -OutputDirectory $outDir -LastMessagePath $last -IsGitRepository $true -AiAgentsRoot $aiRoot)
            $search = @(New-RunExecArgument -ExecutionRoot $execRoot -Profile content -OutputDirectory $outDir -LastMessagePath $last -IsGitRepository $true -AiAgentsRoot $aiRoot -Search)
            Assert-Equal 0 (@($plain | Where-Object { $_ -ceq '--search' }).Count) '未指定時不應有 --search'
            Assert-Equal 1 (@($search | Where-Object { $_ -ceq '--search' }).Count) '應恰有一個 --search'
            Assert-Equal ([array]::IndexOf($search, 'exec') - 1) ([array]::IndexOf($search, '--search')) '--search 應緊接在 exec 之前'
            Assert-Equal ($plain.Count + 1) $search.Count
        }
        Test-Case 'PERM-EXTRA-READ-ROOT ExtraReadRoot 以附 deny 樣式的 read 子表列出，不列入可寫範圍；位於已列根目錄之下時不重複' {
            $extra = Join-Path $root 'acct home\generated_images'
            $extraArgs = @(New-RunPermissionArgument -ExecutionRoot $execRoot -OutputDirectory $outDir -AiAgentsRoot $aiRoot -ReportLineRoot $reportRoot -ExtraReadRoot @($extra))
            $extraFs = [string]($extraArgs | Where-Object { $_.StartsWith('permissions.dispatch_review.filesystem=', [StringComparison]::Ordinal) })
            Assert-True $extraFs.Contains("'" + $extra + "'={`".`"=`"read`", `"**/.env`"=`"deny`"") ('ExtraReadRoot 子表：' + $extraFs)
            Assert-True (-not $extraFs.Contains("'" + $extra + "'=`"write`"")) 'ExtraReadRoot 不應可寫'
            Assert-Equal 20 (([regex]::Matches($extraFs, '="deny"')).Count) '多一個可讀根目錄子表，deny 多 5 個'
            $plan = Get-RunPermissionPlan -ExecutionRoot $execRoot -OutputDirectory $outDir -AiAgentsRoot $aiRoot -ReportLineRoot $reportRoot -ExtraReadRoot @($extra)
            Assert-Equal @($execRoot, $aiRoot, $reportRoot, $extra) @($plan.read_roots)
            Assert-Equal @($outDir) @($plan.write_roots)
            $noReport = Get-RunPermissionPlan -ExecutionRoot $execRoot -OutputDirectory $outDir -AiAgentsRoot $aiRoot -ExtraReadRoot @($extra)
            Assert-Equal @($execRoot, $aiRoot, $extra) @($noReport.read_roots) '未提供 report_line_root 時 ExtraReadRoot 仍列為可讀'
            $underExec = Join-Path $execRoot 'images'
            $underFs = [string](@(New-RunPermissionArgument -ExecutionRoot $execRoot -OutputDirectory $outDir -AiAgentsRoot $aiRoot -ExtraReadRoot @($underExec)) | Where-Object { $_.StartsWith('permissions.dispatch_review.filesystem=', [StringComparison]::Ordinal) })
            Assert-True (-not $underFs.Contains("'" + $underExec + "'=")) '位於執行目錄之下的 ExtraReadRoot 不應重複列出'
            $null = Assert-Throws -Code 'RunPermissionArgumentInvalid' -Script { Get-RunPermissionPlan -ExecutionRoot $execRoot -OutputDirectory $outDir -AiAgentsRoot $aiRoot -ExtraReadRoot @('relative\images') }
        }
        Test-Case 'EXEC-ARGS exec 引數順序與 --skip-git-repo-check' {
            $last = Join-Path $root 'last.md'
            $git = @(New-RunExecArgument -ExecutionRoot $execRoot -Profile review -OutputDirectory $outDir -LastMessagePath $last -IsGitRepository $true -AiAgentsRoot $aiRoot)
            $nonGit = @(New-RunExecArgument -ExecutionRoot $execRoot -Profile review -OutputDirectory $outDir -LastMessagePath $last -IsGitRepository $false -AiAgentsRoot $aiRoot)
            Assert-Equal @('--cd', $execRoot, '--profile', 'review') @($git[0..3])
            $execIndex = [array]::IndexOf($git, 'exec')
            Assert-True ($execIndex -gt 3) '缺少 exec'
            Assert-Equal @('exec', '--json', '--output-last-message', $last, '-') @($git[$execIndex..($git.Count - 1)])
            Assert-Equal @('exec', '--skip-git-repo-check', '--json', '--output-last-message', $last, '-') @($nonGit[([array]::IndexOf($nonGit, 'exec'))..($nonGit.Count - 1)])
            Assert-True ($git -contains '-c') '缺少 -c'
        }
        Test-Case 'CODEX-PATH Get-RunCodexPath 找不到執行檔時 RunCodexNotFound' {
            $null = Assert-Throws -Code 'RunCodexNotFound' -Script { Get-RunCodexPath -ConfiguredPath (Join-Path $root 'absent-codex.cmd') }
            $null = Assert-Throws -Code 'RunCodexNotFound' -Script { Get-RunCodexPath -ConfiguredPath 'codex.cmd' }
            Assert-Equal $fakeCodex (Get-RunCodexPath -ConfiguredPath $fakeCodex)
            $savedPath = $env:PATH
            try {
                $env:PATH = (New-TestDirectory -Name 'emptypath')
                $caught = Assert-Throws -Code 'RunCodexNotFound' -Script { Get-RunCodexPath }
                Assert-Equal 3 ([int]$caught.Data['ExitCode'])
            }
            finally { $env:PATH = $savedPath }
        }

        # ---------- MXC 偵測 ----------
        Test-Case 'MXC-POSITIVE 假 codex 回應 MXC_OK 且結束碼 0 時為 true' {
            [Environment]::SetEnvironmentVariable('FAKE_MODE', 'mxc-ok')
            Assert-True (Test-RunMxc -CodexPath $fakeCodex -CodexHome (New-TestDirectory -Name 'mxchome'))
        }
        Test-Case 'MXC-NEGATIVE 結束碼非零、沒有 MXC_OK、啟動失敗時為 false' {
            foreach ($mode in @('mxc-exit1', 'mxc-silent')) {
                [Environment]::SetEnvironmentVariable('FAKE_MODE', $mode)
                Assert-True (-not (Test-RunMxc -CodexPath $fakeCodex -CodexHome (New-TestDirectory -Name 'mxchome'))) ($mode + ' 應為 false')
            }
            Assert-True (-not (Test-RunMxc -CodexPath (Join-Path $root 'absent.cmd') -CodexHome (New-TestDirectory -Name 'mxchome'))) '啟動失敗應為 false'
        }

        # ---------- 引數還原、stdin、事件流位元組 ----------
        $prompt = "LineContext`n- lineSlug: x`n中文 prompt 審查`n報告檔: C:\out dir\r.md`n"
        $argsRun = $null
        Test-Case 'ARGS-ROUNDTRIP 假 codex.cmd 還原的引數與 New-RunExecArgument 逐項相同' {
            $execArgs = @(New-RunExecArgument -ExecutionRoot $execRoot -Profile review -OutputDirectory $outDir -LastMessagePath (Join-Path $root 'last message.md') -IsGitRepository $true -AiAgentsRoot $aiRoot)
            $script:argsRun = Invoke-FakeRun -Mode 'args-stdin-env' -Argument $execArgs -Prompt $prompt -Name 'args'
            Assert-Equal 0 ([int]$script:argsRun.Result.ExitCode)
            $restored = @(ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $script:argsRun.Home 'args.json') -Raw))
            Assert-Equal $execArgs.Count ($restored.Count) '引數個數'
            for ($i = 0; $i -lt $execArgs.Count; $i++) { Assert-Equal $execArgs[$i] $restored[$i] ('第 ' + $i + ' 個引數') }
        }
        Test-Case 'STDIN-BYTES stdin 位元組等於 UTF-8 無 BOM 的 prompt' {
            $expected = [Convert]::ToHexString((New-Object System.Text.UTF8Encoding -ArgumentList @($false)).GetBytes($prompt))
            Assert-Equal $expected (Get-Content -LiteralPath (Join-Path $script:argsRun.Home 'stdin.hex') -Raw)
        }
        Test-Case 'STREAM-BYTES stdout 與 stderr 以位元組原樣寫入檔案' {
            Assert-Equal 'E4B8AD0AFFFE0A' ([Convert]::ToHexString([IO.File]::ReadAllBytes($script:argsRun.Events)))
            Assert-Equal '4552520A' ([Convert]::ToHexString([IO.File]::ReadAllBytes($script:argsRun.Stderr)))
            Assert-True ($script:argsRun.Result.DurationSeconds -ge 0) '耗時'
        }
        Test-Case 'CODEX-HOME 子行程的 CODEX_HOME 為指定帳號目錄' {
            Assert-True ((Get-Content -LiteralPath (Join-Path $script:argsRun.Home 'env.txt') -Raw).Contains('CODEX_HOME')) 'CODEX_HOME'
            Assert-True (Test-Path -LiteralPath (Join-Path $script:argsRun.Home 'args.json')) '假 codex 以 CODEX_HOME 為落點，代表值正確'
        }
        Test-Case 'START-WRAPPED 每個 .Start() 都位於 Invoke-RunWithoutStdHandleInheritance 的 ScriptBlock 內' {
            foreach ($file in @('20-process.ps1', '25-sandbox.ps1')) {
                $tokens = $null
                $errors = $null
                $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $moduleRoot $file), [ref]$tokens, [ref]$errors)
                Assert-Equal 0 ($errors.Count) ($file + ' 解析失敗')
                $calls = @($ast.FindAll({
                            param($node)
                            $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                            $node.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
                            $node.Member.Value -ceq 'Start'
                        }, $true))
                foreach ($call in $calls) {
                    $wrapped = $false
                    $parent = $call.Parent
                    while ($null -ne $parent) {
                        if ($parent -is [Management.Automation.Language.ScriptBlockExpressionAst] -and
                            $parent.Parent -is [Management.Automation.Language.CommandAst] -and
                            ([string]$parent.Parent.GetCommandName() -ceq 'Invoke-RunWithoutStdHandleInheritance')) { $wrapped = $true; break }
                        $parent = $parent.Parent
                    }
                    Assert-True $wrapped ($file + ' 第 ' + $call.Extent.StartLineNumber + ' 行的 .Start() 未包在 Invoke-RunWithoutStdHandleInheritance 內')
                }
            }
        }
    }

    # ---------- [FIX-HANDLE] 背景啟動不繼承呼叫端輸出管線 ----------
    if ($Case -in @('All', 'Handle')) {
        $sleepSeconds = 14
        $positiveLimit = 6
        $mutantLimit = 10
        $probeText = @'
param([string]$ModulePath, [string]$CommonPath, [string]$Dir, [string]$Mode, [int]$Seconds, [string]$PwshPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $CommonPath
. $ModulePath
$launcher = Join-Path $Dir 'launch.cmd'
$cmdText = '@echo off' + "`r`n" + 'call "' + $PwshPath + '" -NoProfile -NonInteractive -Command "Start-Sleep ' + $Seconds + '" < nul > "' + (Join-Path $Dir 'ev.txt') + '" 2> "' + (Join-Path $Dir 'er.txt') + '"' + "`r`n" + 'exit /b 0' + "`r`n"
[IO.File]::WriteAllText($launcher, $cmdText, (New-Object Text.UTF8Encoding($false)))
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
$startInfo.WorkingDirectory = $Dir
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
foreach ($item in @('/d', '/c', 'call', $launcher)) { [void]$startInfo.ArgumentList.Add($item) }
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $startInfo
if ($Mode -eq 'guarded') { $started = Invoke-RunWithoutStdHandleInheritance -ScriptBlock { $process.Start() } }
else { $started = $process.Start() }
if (-not $started) { throw 'Start 失敗' }
Write-Output ('PID=' + $process.Id)
exit 0
'@
        $restoreProbeText = @'
param([string]$CommonPath, [string]$ModulePath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $CommonPath
. $ModulePath
$null = Initialize-RunStdHandleGuard
function Get-Flags { return @(@(-10, -11, -12) | ForEach-Object { [RunStdHandleGuard]::GetInheritFlag($_) }) }
$before = Get-Flags
$script:insideFlags = $null
$returned = Invoke-RunWithoutStdHandleInheritance -ScriptBlock { $script:insideFlags = Get-Flags; 42 }
$afterNormal = Get-Flags
$thrown = $null
try { Invoke-RunWithoutStdHandleInheritance -ScriptBlock { throw 'boom-fixture' } } catch { $thrown = $_.Exception.Message }
$afterThrow = Get-Flags
[ordered]@{ before = $before; inside = @($script:insideFlags); afterNormal = $afterNormal; returned = $returned; afterThrow = $afterThrow; thrown = $thrown } | ConvertTo-Json -Compress
exit 0
'@
        $probeDir = New-TestDirectory -Name 'handle'
        $probePath = Join-Path $probeDir 'probe.ps1'
        $restorePath = Join-Path $probeDir 'restore-probe.ps1'
        [IO.File]::WriteAllText($probePath, $probeText, (New-Object System.Text.UTF8Encoding -ArgumentList @($false)))
        [IO.File]::WriteAllText($restorePath, $restoreProbeText, (New-Object System.Text.UTF8Encoding -ArgumentList @($false)))
        $commonPath = Join-Path $moduleRoot '00-common.ps1'
        $processModule = Join-Path $moduleRoot '20-process.ps1'

        function Invoke-HandleProbe {
            param([ValidateSet('guarded', 'unguarded')][string]$Mode)
            $dir = New-TestDirectory -Name ('handle-' + $Mode)
            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            $out = & $hostPath -NoProfile -NonInteractive -File $probePath -ModulePath $processModule -CommonPath $commonPath -Dir $dir -Mode $Mode -Seconds $sleepSeconds -PwshPath $hostPath 2>&1
            $elapsed = $stopwatch.Elapsed.TotalSeconds
            $exitCode = $LASTEXITCODE
            $pidLine = @($out | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^PID=\d+$' })
            $startedPid = if ($pidLine.Count -gt 0) { [int]$pidLine[0].Substring(4) } else { 0 }
            if ($startedPid -gt 0) { $startedPids.Add($startedPid) }
            return [pscustomobject]@{ Elapsed = $elapsed; ExitCode = $exitCode; Pid = $startedPid; Output = (@($out) -join "`n") }
        }
        function Assert-HandlePredicate {
            # 呼叫端在 $positiveLimit 秒內返回，才算子行程沒有繼承呼叫端的輸出管線。
            param($Probe)
            if ($Probe.ExitCode -ne 0 -or $Probe.Pid -le 0) { throw ('探針失敗：' + $Probe.Output) }
            Assert-True ($Probe.Elapsed -lt $positiveLimit) ('呼叫端被阻擋 ' + [math]::Round($Probe.Elapsed, 1) + ' 秒')
        }

        $guarded = Invoke-HandleProbe -Mode guarded
        Stop-FixtureProcessTree -ProcessId $guarded.Pid
        $unguarded = Invoke-HandleProbe -Mode unguarded
        Stop-FixtureProcessTree -ProcessId $unguarded.Pid
        Write-Output ('INFO guarded=' + [math]::Round($guarded.Elapsed, 1) + 's unguarded=' + [math]::Round($unguarded.Elapsed, 1) + 's')

        Test-Case '[FIX-HANDLE] POSITIVE 經 Invoke-RunWithoutStdHandleInheritance 啟動後呼叫端 6 秒內返回' {
            Assert-HandlePredicate -Probe $guarded
        }
        Test-Case '[FIX-HANDLE] MUTANT 不經函式直接 Start() 時呼叫端被阻擋超過 10 秒，且同一斷言對它失敗' {
            if ($unguarded.ExitCode -ne 0 -or $unguarded.Pid -le 0) { throw ('探針失敗：' + $unguarded.Output) }
            Assert-True ($unguarded.Elapsed -gt $mutantLimit) ('對照組只阻擋 ' + [math]::Round($unguarded.Elapsed, 1) + ' 秒，無法證明測試可偵測缺少修正')
            $null = Assert-Throws -Script { Assert-HandlePredicate -Probe $unguarded }
        }
        Test-Case '[FIX-HANDLE] RESTORE 旗標在函式內清除，結束與例外後皆還原，例外原樣上拋' {
            $raw = & $hostPath -NoProfile -NonInteractive -File $restorePath -CommonPath $commonPath -ModulePath $processModule 2>&1
            if ($LASTEXITCODE -ne 0) { throw ('還原探針失敗：' + (@($raw) -join "`n")) }
            $json = @($raw | ForEach-Object { [string]$_ } | Where-Object { $_.StartsWith('{') })[0] | ConvertFrom-Json
            $before = @($json.before)
            if (-not ($before -contains 1)) { throw '前置條件不成立：呼叫端沒有可繼承的 std handle（例如在無主控台的環境），無法驗證旗標還原。請在有 std handle 的環境重跑。' }
            for ($i = 0; $i -lt 3; $i++) { if ($before[$i] -eq 1) { Assert-Equal 0 ([int]@($json.inside)[$i]) ('inside[' + $i + ']') } }
            Assert-Equal (@($json.before) -join ',') (@($json.afterNormal) -join ',') 'afterNormal'
            Assert-Equal (@($json.before) -join ',') (@($json.afterThrow) -join ',') 'afterThrow'
            Assert-Equal 42 ([int]$json.returned)
            Assert-Equal 'boom-fixture' ([string]$json.thrown)
        }
        Test-Case '[FIX-HANDLE] CLEANUP 測試啟動的子行程樹已結束' {
            foreach ($startedPid in $startedPids) {
                $deadline = [datetime]::UtcNow.AddSeconds(10)
                while ($null -ne (Get-Process -Id $startedPid -ErrorAction SilentlyContinue) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
                Assert-True ($null -eq (Get-Process -Id $startedPid -ErrorAction SilentlyContinue)) ('PID ' + $startedPid + ' 未結束')
            }
        }
    }

    # ---------- [FIX-ENCODING] 子行程編碼 ----------
    if ($Case -in @('All', 'Encoding')) {
        $encodingPrompt = '審查 prompt：中文與 English 混合'
        $expectedHex = [Convert]::ToHexString((New-Object System.Text.UTF8Encoding -ArgumentList @($false)).GetBytes($encodingPrompt))
        function Assert-StdinBytes {
            param([string]$ActualHex)
            Assert-True ($ActualHex -ceq $expectedHex) ('子行程收到的位元組與預期的 UTF-8 無 BOM 不同：' + $ActualHex)
        }
        function Invoke-MutantStartInfoRun {
            # 與 Invoke-RunCodexProcess 同一流程，但編碼由呼叫端改動。
            param([scriptblock]$Mutate, [string]$Name)
            $codexHome = New-TestDirectory -Name $Name
            $startInfo = New-RunProcessStartInfo -FileName $fakeCodex -Argument @('exec', '-')
            $startInfo.EnvironmentVariables['CODEX_HOME'] = $codexHome
            [Environment]::SetEnvironmentVariable('FAKE_MODE', 'args-stdin-env')
            & $Mutate $startInfo
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            $null = Invoke-RunWithoutStdHandleInheritance -ScriptBlock { $process.Start() }
            $null = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
            $null = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
            $process.StandardInput.Write($encodingPrompt)
            $process.StandardInput.Close()
            $process.WaitForExit()
            $process.Dispose()
            return (Get-Content -LiteralPath (Join-Path $codexHome 'stdin.hex') -Raw)
        }
        Test-Case '[FIX-ENCODING] POSITIVE Invoke-RunCodexProcess 送出的 stdin 為 UTF-8 無 BOM' {
            $run = Invoke-FakeRun -Mode 'args-stdin-env' -Prompt $encodingPrompt -Name 'enc'
            Assert-StdinBytes -ActualHex (Get-Content -LiteralPath (Join-Path $run.Home 'stdin.hex') -Raw)
        }
        Test-Case '[FIX-ENCODING] POSITIVE New-RunProcessStartInfo 的三個編碼為 UTF-8 無 BOM' {
            $startInfo = New-RunProcessStartInfo -FileName $fakeCodex -Argument @()
            foreach ($encoding in @($startInfo.StandardInputEncoding, $startInfo.StandardOutputEncoding, $startInfo.StandardErrorEncoding)) {
                Assert-Equal 65001 ([int]$encoding.CodePage)
                Assert-Equal 0 ($encoding.GetPreamble().Length) 'UTF-8 不得含 BOM'
            }
        }
        Test-Case '[FIX-ENCODING] MUTANT StandardInputEncoding 為 CP950 時子行程收到的位元組不同，同一斷言對它失敗' {
            $cp950 = [Text.Encoding]::GetEncoding(950)
            $mutantHex = Invoke-MutantStartInfoRun -Name 'enc-mutant' -Mutate { param($info) $info.StandardInputEncoding = $cp950 }
            Assert-True ($mutantHex -cne $expectedHex) 'CP950 的位元組竟與 UTF-8 相同，無法證明測試可偵測缺少修正'
            $null = Assert-Throws -Script { Assert-StdinBytes -ActualHex $mutantHex }
            $passthroughHex = Invoke-MutantStartInfoRun -Name 'enc-control' -Mutate { param($info) $null = $info }
            Assert-StdinBytes -ActualHex $passthroughHex
        }
    }

    # ---------- [FIX-FLUSH]、[FIX-TIMEOUT]、[FIX-GRACE] 等待出口與即時落地 ----------
    if ($Case -in @('All', 'Wait')) {
        function Read-SharedBytes {
            param([string]$Path)
            $stream = New-Object System.IO.FileStream -ArgumentList @($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                $buffer = New-Object 'byte[]' 4096
                return $stream.Read($buffer, 0, $buffer.Length)
            }
            finally { $stream.Dispose() }
        }
        function Test-ProcessGone {
            param([int]$ProcessId)
            for ($i = 0; $i -lt 20; $i++) {
                if ($null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
                Start-Sleep -Milliseconds 250
            }
            return $false
        }
        Test-Case '[FIX-FLUSH] POSITIVE 子行程輸出小事件後停住，執行中事件檔與 stderr 檔已有內容' {
            $codexHome = Join-Path $root 'flush-home'
            $null = New-Item -ItemType Directory -Path $codexHome -Force
            $eventsPath = Join-Path $root 'flush.events.jsonl'
            $stderrPath = Join-Path $root 'flush.stderr.txt'
            [Environment]::SetEnvironmentVariable('FAKE_MODE', 'emit-then-sleep')
            $job = Start-ThreadJob -ArgumentList @($moduleRoot, $fakeCodex, $codexHome, $eventsPath, $stderrPath) -ScriptBlock {
                param($ModuleRoot, $Fake, $CodexHome, $Events, $Stderr)
                Set-StrictMode -Version Latest
                $ErrorActionPreference = 'Stop'
                . (Join-Path $ModuleRoot '00-common.ps1')
                . (Join-Path $ModuleRoot '20-process.ps1')
                Invoke-RunCodexProcess -CodexPath $Fake -Argument @('exec', '-') -Prompt 'p' -CodexHome $CodexHome -EventStreamPath $Events -StderrPath $Stderr
            }
            try {
                $eventBytes = 0
                $stderrBytes = 0
                $stateWhenSeen = $null
                $deadline = [DateTime]::UtcNow.AddSeconds(8)
                while ([DateTime]::UtcNow -lt $deadline -and $job.State -in @('NotStarted', 'Running')) {
                    if ([IO.File]::Exists($eventsPath) -and [IO.File]::Exists($stderrPath)) {
                        $eventBytes = Read-SharedBytes -Path $eventsPath
                        $stderrBytes = Read-SharedBytes -Path $stderrPath
                        if ($eventBytes -gt 0 -and $stderrBytes -gt 0) { $stateWhenSeen = $(if ($job.State -in @('NotStarted', 'Running')) { 'Running' } else { [string]$job.State }); break }
                    }
                    Start-Sleep -Milliseconds 200
                }
                Assert-Equal 'Running' $stateWhenSeen '看到內容時子行程應仍在執行'
                Assert-True ($eventBytes -gt 0) '事件檔在執行中應已有內容'
                Assert-True ($stderrBytes -gt 0) 'stderr 檔在執行中應已有內容'
            }
            finally {
                $null = Receive-Job -Job $job -Wait -ErrorAction SilentlyContinue
                Remove-Job -Job $job -Force
            }
        }
        Test-Case '[FIX-FLUSH] MUTANT 預設 4096 緩衝的 FileStream 在寫入後、關閉前讀不到內容，同一斷言對它失敗' {
            $path = Join-Path $root 'flush-mutant.bin'
            $buffered = New-Object System.IO.FileStream -ArgumentList @($path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            try {
                $buffered.Write([byte[]]@(1, 2, 3, 4), 0, 4)
                $null = Assert-Throws -Script { Assert-True ((Read-SharedBytes -Path $path) -gt 0) '讀不到內容' }
            }
            finally { $buffered.Dispose() }
            $unbuffered = New-Object System.IO.FileStream -ArgumentList @($path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read, 0)
            try {
                $unbuffered.Write([byte[]]@(1, 2, 3, 4), 0, 4)
                Assert-Equal 4 (Read-SharedBytes -Path $path)
            }
            finally { $unbuffered.Dispose() }
        }
        Test-Case '[FIX-TIMEOUT] 子行程不輸出 turn.completed 且不結束時，入口在總時限內返回並終止行程樹' {
            $run = Invoke-FakeRun -Mode 'hang-no-turn' -Name 'timeout' -Extra @{ TimeoutSeconds = 8; TurnEndGraceSeconds = 2 }
            Assert-Equal 'timeout' $run.Result.TerminatedBy
            Assert-True ($run.Result.DurationSeconds -lt 30) ('應在時限附近返回，實際 ' + $run.Result.DurationSeconds + ' 秒')
            Assert-True ($run.Result.DurationSeconds -ge 8) '不應早於時限'
            $fakePid = [int](Get-Content -LiteralPath (Join-Path $run.Home 'pid.txt') -Raw)
            Assert-True (Test-ProcessGone -ProcessId $fakePid) '假子行程應已被終止'
            Assert-True ((Get-Content -LiteralPath $run.Events -Raw).Contains('item.started')) '終止前輸出的事件仍保留'
        }
        Test-Case '[FIX-GRACE] 事件流為 turn.completed 且最後訊息非空後，子行程在寬限內未結束則由入口終止' {
            $messagePath = Join-Path $root 'grace-last-message.md'
            $run = Invoke-FakeRun -Mode 'turn-end-hang' -Name 'grace' -Argument @('exec', '--output-last-message', $messagePath, '-') -Extra @{ TimeoutSeconds = 60; TurnEndGraceSeconds = 3; LastMessagePath = $messagePath }
            Assert-Equal 'after-turn-end' $run.Result.TerminatedBy
            Assert-True ($run.Result.DurationSeconds -lt 40) ('應在寬限後返回，實際 ' + $run.Result.DurationSeconds + ' 秒')
            $fakePid = [int](Get-Content -LiteralPath (Join-Path $run.Home 'pid.txt') -Raw)
            Assert-True (Test-ProcessGone -ProcessId $fakePid) '假子行程應已被終止'
        }
        Test-Case '[FIX-GRACE] NEGATIVE 沒有最後訊息時不套用寬限，改由總時限終止' {
            $messagePath = Join-Path $root 'grace-none-last-message.md'
            $run = Invoke-FakeRun -Mode 'turn-end-no-message' -Name 'grace-none' -Argument @('exec', '--output-last-message', $messagePath, '-') -Extra @{ TimeoutSeconds = 9; TurnEndGraceSeconds = 1; LastMessagePath = $messagePath }
            Assert-Equal 'timeout' $run.Result.TerminatedBy
            $fakePid = [int](Get-Content -LiteralPath (Join-Path $run.Home 'pid.txt') -Raw)
            Assert-True (Test-ProcessGone -ProcessId $fakePid) '假子行程應已被終止'
        }
        Test-Case '[FIX-GRACE] NEGATIVE 正常結束的子行程不被終止' {
            $run = Invoke-FakeRun -Mode 'args-stdin-env' -Name 'normal-exit' -Extra @{ TimeoutSeconds = 60; TurnEndGraceSeconds = 1 }
            Assert-True ($null -eq $run.Result.TerminatedBy) '不應有終止原因'
            Assert-Equal 0 ([int]$run.Result.ExitCode)
        }
    }

    # ---------- [FIX-ENV] 機密環境變數清除 ----------
    if ($Case -in @('All', 'Env')) {
        function Set-FixtureEnvironment {
            [Environment]::SetEnvironmentVariable('FAKE_API_TOKEN', 'fixture-token')
            [Environment]::SetEnvironmentVariable('FAKE_SECRET_KEY', 'fixture-secret')
            [Environment]::SetEnvironmentVariable('NUGET_API_KEY', 'fixture-nuget')
            [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', '1')
            [Environment]::SetEnvironmentVariable('GIT_CONFIG_KEY_0', 'core.fixture')
        }
        function Assert-SecretsRemoved {
            param([string]$EnvText)
            $names = @($EnvText -split "`n")
            foreach ($secret in @('FAKE_API_TOKEN', 'FAKE_SECRET_KEY', 'NUGET_API_KEY')) { Assert-True (-not ($names -contains $secret)) ($secret + ' 仍存在於子行程環境') }
            foreach ($kept in @('GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0')) { Assert-True ($names -contains $kept) ($kept + ' 不應被移除') }
        }
        Test-Case '[FIX-ENV] POSITIVE Invoke-RunCodexProcess 的子行程環境不含機密變數，保留 GIT_CONFIG_*' {
            Set-FixtureEnvironment
            $run = Invoke-FakeRun -Mode 'args-stdin-env' -Name 'env'
            Assert-SecretsRemoved -EnvText (Get-Content -LiteralPath (Join-Path $run.Home 'env.txt') -Raw)
            foreach ($secret in @('FAKE_API_TOKEN', 'FAKE_SECRET_KEY', 'NUGET_API_KEY')) {
                Assert-True (@($run.Result.RemovedEnvironmentVariable) -contains $secret) ($secret + ' 應出現在回傳的移除清單')
            }
        }
        Test-Case '[FIX-ENV] MUTANT 不呼叫 Remove-RunSecretEnvironmentVariable 時子行程環境含機密變數，同一斷言對它失敗' {
            Set-FixtureEnvironment
            $codexHome = New-TestDirectory -Name 'env-mutant'
            $startInfo = New-RunProcessStartInfo -FileName $fakeCodex -Argument @('exec', '-')
            $startInfo.EnvironmentVariables['CODEX_HOME'] = $codexHome
            [Environment]::SetEnvironmentVariable('FAKE_MODE', 'args-stdin-env')
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            $null = Invoke-RunWithoutStdHandleInheritance -ScriptBlock { $process.Start() }
            $null = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
            $null = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
            $process.StandardInput.Close()
            $process.WaitForExit()
            $process.Dispose()
            $envText = Get-Content -LiteralPath (Join-Path $codexHome 'env.txt') -Raw
            $null = Assert-Throws -Script { Assert-SecretsRemoved -EnvText $envText }
            Assert-True (@($envText -split "`n") -contains 'FAKE_API_TOKEN') '對照組應含 FAKE_API_TOKEN'
        }
        Test-Case '[FIX-ENV] GIT-ISOLATION 子行程環境含 GIT_CONFIG_GLOBAL 與 GIT_CONFIG_NOSYSTEM，使沙盒內 git 不讀全域與系統設定' {
            Set-FixtureEnvironment
            $gitRun = Invoke-FakeRun -Mode 'args-stdin-env' -Name 'git-env'
            $envNamesSeen = @((Get-Content -LiteralPath (Join-Path $gitRun.Home 'env.txt') -Raw) -split "`n")
            Assert-True ($envNamesSeen -contains 'GIT_CONFIG_GLOBAL') 'GIT_CONFIG_GLOBAL'
            Assert-True ($envNamesSeen -contains 'GIT_CONFIG_NOSYSTEM') 'GIT_CONFIG_NOSYSTEM'
        }
        Test-Case '[FIX-ENV] ERRORS 名單缺少、無法匯入、結構異常時分別丟對應錯誤' {
            $startInfo = New-RunProcessStartInfo -FileName $fakeCodex -Argument @()
            $listDir = New-TestDirectory -Name 'denylist'
            $null = Assert-Throws -Code 'RunEnvDenylistMissing' -Script { Remove-RunSecretEnvironmentVariable -StartInfo $startInfo -ListPath (Join-Path $listDir 'absent.psd1') }
            $broken = Join-Path $listDir 'broken.psd1'
            Write-TestUtf8 -Path $broken -Text '@{ DenyPatterns = ('
            $null = Assert-Throws -Code 'RunEnvDenylistUnreadable' -Script { Remove-RunSecretEnvironmentVariable -StartInfo $startInfo -ListPath $broken }
            $missingKey = Join-Path $listDir 'missing-key.psd1'
            Write-TestUtf8 -Path $missingKey -Text "@{ DenyPatterns = @('*X*'); KeepNames = @() }"
            $null = Assert-Throws -Code 'RunEnvDenylistInvalid' -Script { Remove-RunSecretEnvironmentVariable -StartInfo $startInfo -ListPath $missingKey }
            $emptyDeny = Join-Path $listDir 'empty-deny.psd1'
            Write-TestUtf8 -Path $emptyDeny -Text '@{ DenyPatterns = @(); KeepNames = @(); KeepPatterns = @() }'
            $null = Assert-Throws -Code 'RunEnvDenylistInvalid' -Script { Remove-RunSecretEnvironmentVariable -StartInfo $startInfo -ListPath $emptyDeny }
            $wrongType = Join-Path $listDir 'wrong-type.psd1'
            Write-TestUtf8 -Path $wrongType -Text "@{ DenyPatterns = @(1); KeepNames = @(); KeepPatterns = @() }"
            $null = Assert-Throws -Code 'RunEnvDenylistInvalid' -Script { Remove-RunSecretEnvironmentVariable -StartInfo $startInfo -ListPath $wrongType }
        }
    }
}
finally {
    foreach ($startedPid in $startedPids) { Stop-FixtureProcessTree -ProcessId $startedPid }
    foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $savedEnv[$name]) }
    [Environment]::SetEnvironmentVariable('FAKE_MODE', $null)
    $exitCode = Complete-TestRun
}
exit $exitCode
