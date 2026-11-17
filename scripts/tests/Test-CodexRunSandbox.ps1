#Requires -Version 7.0
# 沙盒強制力實測。以 New-RunPermissionArgument 的輸出經 codex sandbox 子命令執行命令，不呼叫服務端。
# MXC 不可用時以失敗結束並指出原因，不跳過。需要本機已安裝 codex，且 ~\.ai-agents 存在。
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$moduleRoot = Join-Path $scriptsRoot 'codex-run'
. (Join-Path $PSScriptRoot 'codex-run-fixtures\TestHelpers.ps1')
foreach ($module in @('00-common.ps1', '20-process.ps1', '25-sandbox.ps1')) { . (Join-Path $moduleRoot $module) }

try {
    $root = New-TestDirectory -Name 'sandbox'
    $codexPath = Get-RunCodexPath
    $codexHome = Join-Path $root 'codex-home'
    $null = New-Item -ItemType Directory -Path $codexHome -Force
    $aiAgentsRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ai-agents'
    $instructions = Join-Path $aiAgentsRoot 'instructions.md'

    $mxcAvailable = Test-RunMxc -CodexPath $codexPath -CodexHome $codexHome
    Test-Case 'SANDBOX-MXC 本機 MXC 可用（不可用時整組失敗，不跳過）' {
        Assert-True $mxcAvailable 'MXC 偵測探針失敗：codex sandbox 無法在 windows.sandbox=mxc 下執行 cmd.exe。'
        Assert-True ([IO.File]::Exists($instructions)) ('前置條件不成立：找不到 ' + $instructions)
    }

    if ($mxcAvailable) {
        function New-SandboxFixture {
            # OutputUnderExec 為 true 時，輸出目錄位於執行目錄之下，否則位於執行目錄之外。
            # AiMode：real 使用本機的 ~\.ai-agents；fake 另建含機密樣式檔的假 ai-agents 目錄；exec 使 execution_root 即 ai-agents 根目錄。
            param([string]$Name, [switch]$OutputUnderExec, [ValidateSet('real', 'fake', 'exec')][string]$AiMode = 'real')
            $base = New-TestDirectory -Name $Name
            $exec = Join-Path $base 'exec'
            $report = Join-Path $base 'report'
            foreach ($dir in @($exec, (Join-Path $exec 'sub'), $report)) { $null = New-Item -ItemType Directory -Path $dir -Force }
            $outParent = if ($OutputUnderExec) { Join-Path $exec 'report\runs' } else { Join-Path $report 'runs' }
            $out = Join-Path $outParent 'review-x-1'
            $null = New-Item -ItemType Directory -Path $out -Force
            Write-TestUtf8 -Path (Join-Path $exec 'a.txt') -Text 'hello-sandbox'
            Write-TestUtf8 -Path (Join-Path $exec '.env') -Text 'SECRET=fixture-env'
            Write-TestUtf8 -Path (Join-Path $exec '.env.local') -Text 'SECRET=fixture-env-local'
            Write-TestUtf8 -Path (Join-Path $exec 'secrets.json') -Text '{"k":"fixture-secrets"}'
            Write-TestUtf8 -Path (Join-Path $exec 'sub\x.pem') -Text 'fixture-pem'
            Write-TestUtf8 -Path (Join-Path $exec 'sub\x.key') -Text 'fixture-key'
            Write-TestUtf8 -Path (Join-Path $exec 'sub\secrets.txt') -Text 'fixture-secrets-sub'
            $reportRoot = if ($OutputUnderExec) { Join-Path $exec 'report' } else { $report }
            Write-TestUtf8 -Path (Join-Path $reportRoot 'previous-report.md') -Text 'previous-report-content'
            Write-TestUtf8 -Path (Join-Path $reportRoot '.env') -Text 'SECRET=fixture-report-env'
            Write-TestUtf8 -Path (Join-Path $reportRoot 'secrets.json') -Text '{"k":"fixture-report-secrets"}'
            $ai = $aiAgentsRoot
            if ($AiMode -eq 'fake') {
                $ai = Join-Path $base 'ai'
                Write-TestUtf8 -Path (Join-Path $ai 'guide.md') -Text 'ai-guide-content'
                Write-TestUtf8 -Path (Join-Path $ai '.env') -Text 'SECRET=fixture-ai-env'
                Write-TestUtf8 -Path (Join-Path $ai 'sub\x.pem') -Text 'fixture-ai-pem'
            }
            if ($AiMode -eq 'exec') { $ai = $exec }
            return [pscustomobject]@{ Exec = $exec; OutParent = $outParent; Out = $out; Base = $base; Report = $reportRoot; Ai = $ai }
        }
        function Invoke-SandboxProbe {
            param($Fixture, [string[]]$Command, [string]$Name, [switch]$OutputOnly)
            $permissionArgs = if ($OutputOnly) { @(New-RunPermissionArgument -ExecutionRoot $Fixture.Out -OutputDirectory $Fixture.Out -OutputOnly) }
            else { @(New-RunPermissionArgument -ExecutionRoot $Fixture.Exec -OutputDirectory $Fixture.Out -AiAgentsRoot $Fixture.Ai -ReportLineRoot $Fixture.Report) }
            $workingDirectory = if ($OutputOnly) { $Fixture.Out } else { $Fixture.Exec }
            $arguments = New-Object 'System.Collections.Generic.List[string]'
            for ($i = 0; $i -lt $permissionArgs.Count; $i += 2) {
                if ($permissionArgs[$i + 1].StartsWith('default_permissions=', [StringComparison]::Ordinal)) { continue }
                $arguments.Add($permissionArgs[$i])
                $arguments.Add($permissionArgs[$i + 1])
            }
            foreach ($item in @('sandbox', '--include-managed-config', '--permission-profile', 'dispatch_review', '--', 'cmd.exe', '/d', '/c')) { $arguments.Add($item) }
            foreach ($item in $Command) { $arguments.Add($item) }
            $eventPath = Join-Path $Fixture.Base ($Name + '.out')
            $result = Invoke-RunCodexProcess -CodexPath $codexPath -Argument @($arguments.ToArray()) -Prompt '' -CodexHome $codexHome -EventStreamPath $eventPath -StderrPath (Join-Path $Fixture.Base ($Name + '.err')) -WorkingDirectory $workingDirectory
            $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($eventPath)) + [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $Fixture.Base ($Name + '.err'))))
            return [pscustomobject]@{ ExitCode = [int]$result.ExitCode; Text = $text }
        }
        function Assert-ReadDenied {
            param($Fixture, [string]$Path, [string]$Name, [string]$Secret)
            $probe = Invoke-SandboxProbe -Fixture $Fixture -Command @('type', $Path) -Name $Name
            Assert-True ($probe.ExitCode -ne 0) ($Path + ' 應被沙盒拒絕讀取，但結束碼為 0')
            Assert-True (-not $probe.Text.Contains($Secret)) ($Path + ' 的內容外洩到輸出')
        }
        function Assert-WriteDenied {
            param($Fixture, [string]$Directory, [string]$Name)
            $target = Join-Path $Directory ('denied-' + $Name)
            $probe = Invoke-SandboxProbe -Fixture $Fixture -Command @('md', $target) -Name $Name
            Assert-True ($probe.ExitCode -ne 0) ($Directory + ' 應被沙盒拒絕寫入，但結束碼為 0')
            Assert-True (-not (Test-Path -LiteralPath $target)) ($target + ' 竟被建立')
        }

        $outside = New-SandboxFixture -Name 'outside'
        Test-Case 'SANDBOX-READ-EXEC 沙盒內命令讀執行目錄內一般檔成功' {
            $probe = Invoke-SandboxProbe -Fixture $outside -Command @('type', (Join-Path $outside.Exec 'a.txt')) -Name 'read-exec'
            Assert-Equal 0 $probe.ExitCode
            Assert-True $probe.Text.Contains('hello-sandbox') '讀不到檔案內容'
        }
        Test-Case 'SANDBOX-READ-AIAGENTS 沙盒內命令讀 ~\.ai-agents\instructions.md 成功' {
            $direct = Invoke-SandboxProbe -Fixture $outside -Command @('type', $instructions) -Name 'read-ai'
            Assert-Equal 0 $direct.ExitCode
            Assert-True ($direct.Text.Length -gt 100) '讀到的內容過短'
        }
        Test-Case 'SANDBOX-WRITE-OUTPUT 寫輸出目錄內新檔成功（輸出目錄在執行目錄之外）' {
            $target = Join-Path $outside.Out 'report.md'
            $probe = Invoke-SandboxProbe -Fixture $outside -Command @('copy', '/y', (Join-Path $outside.Exec 'a.txt'), $target) -Name 'write-out'
            Assert-Equal 0 $probe.ExitCode
            Assert-True (Test-Path -LiteralPath $target) '輸出目錄內沒有產生檔案'
            Assert-Equal 'hello-sandbox' ((Get-Content -LiteralPath $target -Raw).Trim())
        }
        Test-Case 'SANDBOX-WRITE-DENIED 寫執行目錄根目錄與輸出目錄的上層被拒' {
            Assert-WriteDenied -Fixture $outside -Directory $outside.Exec -Name 'write-exec'
            Assert-WriteDenied -Fixture $outside -Directory (Join-Path $outside.Exec 'sub') -Name 'write-exec-sub'
            Assert-WriteDenied -Fixture $outside -Directory $outside.OutParent -Name 'write-outparent'
        }
        Test-Case 'SANDBOX-READ-SECRET-ROOT 讀執行目錄根目錄的 .env、.env.local、secrets.json 被拒' {
            Assert-ReadDenied -Fixture $outside -Path (Join-Path $outside.Exec '.env') -Name 'read-env' -Secret 'fixture-env'
            Assert-ReadDenied -Fixture $outside -Path (Join-Path $outside.Exec '.env.local') -Name 'read-env-local' -Secret 'fixture-env-local'
            Assert-ReadDenied -Fixture $outside -Path (Join-Path $outside.Exec 'secrets.json') -Name 'read-secrets' -Secret 'fixture-secrets'
        }
        Test-Case 'SANDBOX-READ-SECRET-SUB 讀子目錄的 x.pem、x.key、secrets.txt 被拒' {
            Assert-ReadDenied -Fixture $outside -Path (Join-Path $outside.Exec 'sub\x.pem') -Name 'read-pem' -Secret 'fixture-pem'
            Assert-ReadDenied -Fixture $outside -Path (Join-Path $outside.Exec 'sub\x.key') -Name 'read-key' -Secret 'fixture-key'
            Assert-ReadDenied -Fixture $outside -Path (Join-Path $outside.Exec 'sub\secrets.txt') -Name 'read-secrets-sub' -Secret 'fixture-secrets-sub'
        }

        Test-Case 'SANDBOX-REPORT-ROOT-READ report_line_root 在執行目錄之外時，讀輸出目錄之外的前輪報告成功，寫該目錄被拒，輸出目錄仍可寫' {
            $probe = Invoke-SandboxProbe -Fixture $outside -Command @('type', (Join-Path $outside.Report 'previous-report.md')) -Name 'read-report-root'
            Assert-Equal 0 $probe.ExitCode
            Assert-True $probe.Text.Contains('previous-report-content') '讀不到前輪報告內容'
            Assert-WriteDenied -Fixture $outside -Directory $outside.Report -Name 'write-report-root'
            $target = Join-Path $outside.Out 'still-writable.md'
            $write = Invoke-SandboxProbe -Fixture $outside -Command @('copy', '/y', (Join-Path $outside.Exec 'a.txt'), $target) -Name 'write-out-after-report-read'
            Assert-Equal 0 $write.ExitCode
            Assert-True (Test-Path -LiteralPath $target) '輸出目錄應仍可寫'
        }

        $fakeAi = New-SandboxFixture -Name 'fakeai' -AiMode fake
        Test-Case 'SANDBOX-SECRET-OUTSIDE-ROOTS 工作目錄之外的可讀根目錄（ai-agents、report_line_root）內，一般檔可讀、機密樣式檔被拒，輸出目錄仍可寫' {
            $guide = Invoke-SandboxProbe -Fixture $fakeAi -Command @('type', (Join-Path $fakeAi.Ai 'guide.md')) -Name 'fakeai-read-guide'
            Assert-Equal 0 $guide.ExitCode
            Assert-True $guide.Text.Contains('ai-guide-content') '讀不到 ai-agents 內的一般檔'
            Assert-ReadDenied -Fixture $fakeAi -Path (Join-Path $fakeAi.Ai '.env') -Name 'fakeai-read-env' -Secret 'fixture-ai-env'
            Assert-ReadDenied -Fixture $fakeAi -Path (Join-Path $fakeAi.Ai 'sub\x.pem') -Name 'fakeai-read-pem' -Secret 'fixture-ai-pem'
            $previous = Invoke-SandboxProbe -Fixture $fakeAi -Command @('type', (Join-Path $fakeAi.Report 'previous-report.md')) -Name 'fakeai-read-previous'
            Assert-Equal 0 $previous.ExitCode
            Assert-ReadDenied -Fixture $fakeAi -Path (Join-Path $fakeAi.Report '.env') -Name 'fakeai-report-env' -Secret 'fixture-report-env'
            Assert-ReadDenied -Fixture $fakeAi -Path (Join-Path $fakeAi.Report 'secrets.json') -Name 'fakeai-report-secrets' -Secret 'fixture-report-secrets'
            $target = Join-Path $fakeAi.Out 'report.md'
            $write = Invoke-SandboxProbe -Fixture $fakeAi -Command @('copy', '/y', (Join-Path $fakeAi.Exec 'a.txt'), $target) -Name 'fakeai-write-out'
            Assert-Equal 0 $write.ExitCode
            Assert-True (Test-Path -LiteralPath $target) '輸出目錄應仍可寫'
            Assert-WriteDenied -Fixture $fakeAi -Directory $fakeAi.Ai -Name 'fakeai-write-ai'
        }
        $execIsAi = New-SandboxFixture -Name 'execisai' -AiMode exec
        Test-Case 'SANDBOX-EXEC-IS-AI execution_root 即 ~\.ai-agents 時沙盒可啟動，讀寫與機密樣式邊界不變' {
            $read = Invoke-SandboxProbe -Fixture $execIsAi -Command @('type', (Join-Path $execIsAi.Exec 'a.txt')) -Name 'execisai-read'
            Assert-Equal 0 $read.ExitCode ('沙盒無法以重複的根目錄啟動：' + $read.Text)
            Assert-True $read.Text.Contains('hello-sandbox') '讀不到檔案內容'
            Assert-WriteDenied -Fixture $execIsAi -Directory $execIsAi.Exec -Name 'execisai-write'
            Assert-ReadDenied -Fixture $execIsAi -Path (Join-Path $execIsAi.Exec '.env') -Name 'execisai-env' -Secret 'fixture-env'
            $target = Join-Path $execIsAi.Out 'report.md'
            $write = Invoke-SandboxProbe -Fixture $execIsAi -Command @('copy', '/y', (Join-Path $execIsAi.Exec 'a.txt'), $target) -Name 'execisai-write-out'
            Assert-Equal 0 $write.ExitCode
            Assert-True (Test-Path -LiteralPath $target) '輸出目錄應可寫'
        }

        $outputOnly = New-SandboxFixture -Name 'outputonly'
        Write-TestUtf8 -Path (Join-Path $outputOnly.Out 'in.txt') -Text 'hello-output-only'
        Write-TestUtf8 -Path (Join-Path $outputOnly.Out '.env') -Text 'SECRET=fixture-out-env'
        # 專案根目錄（.git 所在）放說明檔與一個同層的一般檔：Codex 啟動時會載入說明檔，同層其他檔案仍須被拒。
        $null = New-Item -ItemType Directory -Path (Join-Path $outputOnly.Base '.git') -Force
        Write-TestUtf8 -Path (Join-Path $outputOnly.Base 'AGENTS.md') -Text 'project-agents-content'
        Write-TestUtf8 -Path (Join-Path $outputOnly.Base 'sibling.txt') -Text 'project-sibling-content'
        Test-Case 'SANDBOX-OUTPUT-ONLY 不開放工作目錄：輸出目錄可讀可寫，工作目錄、ai-agents、report_line_root 與輸出目錄的上層都讀寫被拒，輸出目錄內的機密樣式檔被拒' {
            $read = Invoke-SandboxProbe -Fixture $outputOnly -Command @('type', (Join-Path $outputOnly.Out 'in.txt')) -Name 'oo-read-out' -OutputOnly
            Assert-Equal 0 $read.ExitCode
            Assert-True $read.Text.Contains('hello-output-only') '讀不到輸出目錄內的檔案'
            $target = Join-Path $outputOnly.Out 'report.md'
            $write = Invoke-SandboxProbe -Fixture $outputOnly -Command @('copy', '/y', (Join-Path $outputOnly.Out 'in.txt'), $target) -Name 'oo-write-out' -OutputOnly
            Assert-Equal 0 $write.ExitCode
            Assert-True (Test-Path -LiteralPath $target) '輸出目錄內沒有產生檔案'
            # AGENTS.md 由 Codex 行程自己在啟動時載入（以權限設定的檔案項判定），不經沙盒內的子行程，因此這裡不斷言 cmd 能讀它；
            # 能否啟動由真實發動驗證。此處只確認開放這個檔案不帶出同層其他檔案，也不使它可寫。
            $docWrite = Invoke-SandboxProbe -Fixture $outputOnly -Command @('copy', '/y', (Join-Path $outputOnly.Out 'in.txt'), (Join-Path $outputOnly.Base 'AGENTS.md')) -Name 'oo-write-agents' -OutputOnly
            Assert-True ($docWrite.ExitCode -ne 0) 'AGENTS.md 不得可寫'
            Assert-Equal 'project-agents-content' ((Get-Content -LiteralPath (Join-Path $outputOnly.Base 'AGENTS.md') -Raw).Trim()) 'AGENTS.md 內容被改'
            foreach ($denied in @(@((Join-Path $outputOnly.Base 'sibling.txt'), 'project-sibling-content', 'oo-read-sibling'), @((Join-Path $outputOnly.Exec 'a.txt'), 'hello-sandbox', 'oo-read-exec'), @((Join-Path $outputOnly.Report 'previous-report.md'), 'previous-report-content', 'oo-read-report'), @($instructions, 'instructions', 'oo-read-ai'), @((Join-Path $outputOnly.Out '.env'), 'fixture-out-env', 'oo-read-env'))) {
                $probe = Invoke-SandboxProbe -Fixture $outputOnly -Command @('type', $denied[0]) -Name $denied[2] -OutputOnly
                Assert-True ($probe.ExitCode -ne 0) ($denied[0] + ' 應被拒絕讀取')
                Assert-True (-not $probe.Text.Contains($denied[1])) ($denied[0] + ' 的內容外洩')
            }
            foreach ($dir in @($outputOnly.Exec, $outputOnly.OutParent, $outputOnly.Report)) {
                $deniedTarget = Join-Path $dir 'denied-oo'
                $probe = Invoke-SandboxProbe -Fixture $outputOnly -Command @('md', $deniedTarget) -Name 'oo-write-denied' -OutputOnly
                Assert-True ($probe.ExitCode -ne 0) ($dir + ' 應被拒絕寫入')
                Assert-True (-not (Test-Path -LiteralPath $deniedTarget)) ($deniedTarget + ' 竟被建立')
            }
        }

        $inside = New-SandboxFixture -Name 'inside' -OutputUnderExec
        Test-Case 'SANDBOX-NESTED-WRITE 輸出目錄在執行目錄之下時，輸出目錄可寫' {
            $target = Join-Path $inside.Out 'report.md'
            $probe = Invoke-SandboxProbe -Fixture $inside -Command @('copy', '/y', (Join-Path $inside.Exec 'a.txt'), $target) -Name 'nested-write-out'
            Assert-Equal 0 $probe.ExitCode
            Assert-True (Test-Path -LiteralPath $target) '輸出目錄內沒有產生檔案'
        }
        Test-Case 'SANDBOX-NESTED-REPORT-ROOT report_line_root 在執行目錄之下時，讀前輪報告成功，寫 report_line_root 被拒' {
            $probe = Invoke-SandboxProbe -Fixture $inside -Command @('type', (Join-Path $inside.Report 'previous-report.md')) -Name 'nested-read-report-root'
            Assert-Equal 0 $probe.ExitCode
            Assert-True $probe.Text.Contains('previous-report-content') '讀不到前輪報告內容'
            Assert-WriteDenied -Fixture $inside -Directory $inside.Report -Name 'nested-write-report-root'
            Assert-ReadDenied -Fixture $inside -Path (Join-Path $inside.Report '.env') -Name 'nested-report-env' -Secret 'fixture-report-env'
        }
        Test-Case 'SANDBOX-NESTED-DENIED 輸出目錄在執行目錄之下時，其餘位置仍不可寫、機密檔仍不可讀' {
            Assert-WriteDenied -Fixture $inside -Directory $inside.Exec -Name 'nested-write-exec'
            Assert-WriteDenied -Fixture $inside -Directory $inside.OutParent -Name 'nested-write-outparent'
            Assert-ReadDenied -Fixture $inside -Path (Join-Path $inside.Exec '.env') -Name 'nested-read-env' -Secret 'fixture-env'
        }
    }
}
finally {
    $exitCode = Complete-TestRun
}
exit $exitCode
