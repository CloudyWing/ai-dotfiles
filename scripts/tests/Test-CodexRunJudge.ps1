#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$moduleRoot = Join-Path $scriptsRoot 'codex-run'
. (Join-Path $PSScriptRoot 'codex-run-fixtures\TestHelpers.ps1')
foreach ($module in @('00-common.ps1', '30-judge.ps1')) { . (Join-Path $moduleRoot $module) }

try {
    $root = New-TestDirectory -Name 'judge'
    $modelMessage = "The 'gpt-6.1-terra' model is not supported when using Codex with a ChatGPT account."
    $toolEchoLine = '2026-11-09T09:00:58.993011Z ERROR codex_core::tools::router: error=exec_command failed: CreateProcess { message: "Rejected(\"`rg -n \\\"Unauthorized|401\\\" skills`\") rejected: blocked by policy" }'
    $mcpNoiseLine = '2026-11-09T08:51:23.026988Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed'
    $metadataWarning = [ordered]@{ type = 'item.completed'; item = [ordered]@{ id = 'item_0'; type = 'error'; message = 'Model metadata for `gpt-6.1-sol` not found. Defaulting to fallback metadata.' } }
    $usageGood = [ordered]@{ input_tokens = 1000; cached_input_tokens = 600; output_tokens = 50; reasoning_output_tokens = 10 }

    function Get-Evidence {
        param([string]$Name, [object[]]$Event = @(), [string[]]$RawLine = @(), [string]$Stderr = '', [object]$ExitCode = $null)
        $files = New-TestEventStream -Directory $root -Name $Name -Event $Event -RawLine $RawLine -Stderr $Stderr
        return Get-RunEventEvidence -EventStreamPath $files.event -StderrPath $files.error -ExitCode $ExitCode
    }

    # ---------- 事件流判讀 ----------
    Test-Case 'EVID-USAGE-LIMIT usage limit 為 usage-limit，零 item 進度，可換帳號' {
        $e = Get-Evidence -Name 'usage' -Event @([ordered]@{ type = 'turn.started' }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'You hit your usage limit' } })
        Assert-Equal 'usage-limit' $e.rejection_kind
        Assert-Equal 0 $e.item_event_count
        Assert-Equal $false $e.completed
        Assert-Equal 'no-terminal-event' $e.usage.status
        Assert-True (Test-RunFailoverEligible -Evidence $e)
    }
    Test-Case 'EVID-LIMIT-RESET 從 usage limit 訊息擷取重設時間：原始字串與本地 ISO 時間；解析不出來或非 usage limit 為 null' {
        $message = "You$([char]0x2019)ve hit your usage limit. Upgrade to Pro (https://example.test/upgrade), visit https://example.test/usage to purchase more credits or try again at Nov 22nd, 2026 5:21 PM."
        $e = Get-Evidence -Name 'reset' -Event @([ordered]@{ type = 'turn.started' }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = $message } })
        Assert-Equal 'usage-limit' $e.rejection_kind
        Assert-Equal 'Nov 22nd, 2026 5:21 PM' $e.limit_reset_raw
        $expected = ([DateTime]::new(2026, 11, 22, 17, 21, 0, [DateTimeKind]::Local)).ToString('yyyy-MM-ddTHH:mm:sszzz', [Globalization.CultureInfo]::InvariantCulture)
        Assert-Equal $expected $e.limit_reset_local
        $stderr = Get-Evidence -Name 'reset-stderr' -Event @([ordered]@{ type = 'turn.started' }) -Stderr ('2026-11-09T09:02:00Z ERROR codex_core::client: ' + $message) -ExitCode 1
        Assert-Equal $expected $stderr.limit_reset_local
        $none = Get-Evidence -Name 'reset-none' -Event @([ordered]@{ type = 'turn.started' }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'You hit your usage limit' } })
        Assert-Equal 'usage-limit' $none.rejection_kind
        Assert-True ($null -eq $none.limit_reset_raw -and $null -eq $none.limit_reset_local) '訊息沒有重設時間時為 null'
        $other = Get-Evidence -Name 'reset-other' -Event @([ordered]@{ type = 'turn.started' }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'unexpected status 401 Unauthorized, try again at Nov 22nd, 2026 5:21 PM' } })
        Assert-True ($null -eq $other.limit_reset_local) '非 usage limit 不擷取重設時間'
    }
    Test-Case 'PARSE-LIMIT-RESET 容忍序數後綴、逗號與 12 小時制，其他寫法與不存在的日期為 null' {
        $cases = @(
            @{ text = 'try again at Nov 22nd, 2026 5:21 PM.'; raw = 'Nov 22nd, 2026 5:21 PM'; local = [DateTime]::new(2026, 11, 22, 17, 21, 0) },
            @{ text = 'or try again at Dec 1st 2026 12:05 AM'; raw = 'Dec 1st 2026 12:05 AM'; local = [DateTime]::new(2026, 12, 1, 0, 5, 0) },
            @{ text = 'try again at March 3rd, 2027 12:00 PM'; raw = 'March 3rd, 2027 12:00 PM'; local = [DateTime]::new(2027, 3, 3, 12, 0, 0) },
            @{ text = 'Try again at Jan 2nd, 2027, 9:30 am'; raw = 'Jan 2nd, 2027, 9:30 am'; local = [DateTime]::new(2027, 1, 2, 9, 30, 0) },
            @{ text = 'try again at Sept. 14th, 2026 11:59 PM'; raw = 'Sept. 14th, 2026 11:59 PM'; local = [DateTime]::new(2026, 9, 14, 23, 59, 0) }
        )
        foreach ($case in $cases) {
            $reset = Get-RunUsageLimitReset -Text $case.text
            Assert-True ($null -ne $reset) $case.text
            Assert-Equal $case.raw $reset.raw
            $localTime = [DateTime]::SpecifyKind($case.local, [DateTimeKind]::Local)
            Assert-Equal $localTime.ToString('yyyy-MM-ddTHH:mm:sszzz', [Globalization.CultureInfo]::InvariantCulture) $reset.local
        }
        foreach ($text in @($null, '', 'try again later', 'try again at 2026-11-22 17:21', 'try again at Nov 22nd 17:21', 'try again at Feb 30th, 2026 5:21 PM', 'try again at Nov 22nd, 2026 13:21 PM', 'try again at in 5 days')) {
            Assert-True ($null -eq (Get-RunUsageLimitReset -Text $text)) ([string]$text)
        }
    }
    Test-Case 'EVID-MODEL-NOT-SUPPORTED model is not supported（含 model metadata 警告項目）' {
        $e = Get-Evidence -Name 'model' -Event @([ordered]@{ type = 'thread.started'; thread_id = 'x' }, $metadataWarning, [ordered]@{ type = 'turn.started' },
            [ordered]@{ type = 'error'; message = $modelMessage }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = $modelMessage } })
        Assert-Equal 'model-not-supported' $e.rejection_kind
        Assert-Equal 0 $e.item_event_count
        Assert-True (Test-RunFailoverEligible -Evidence $e)
    }
    Test-Case 'EVID-UNAUTHORIZED 401 Unauthorized（事件流與只有 stderr 兩種來源）' {
        $e = Get-Evidence -Name 'unauth' -Event @([ordered]@{ type = 'error'; message = 'unexpected status 401 Unauthorized' }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'unexpected status 401 Unauthorized' } })
        Assert-Equal 'unauthorized' $e.rejection_kind
        $line = '2026-11-09T09:02:00.123456Z ERROR codex_core::client: unexpected status 401 Unauthorized: Missing bearer or basic authentication in header'
        $stderrOnly = Get-Evidence -Name 'unauth-stderr' -Event @([ordered]@{ type = 'turn.started' }) -Stderr ($mcpNoiseLine + "`n" + $toolEchoLine + "`n" + $line)
        Assert-Equal 'unauthorized' $stderrOnly.rejection_kind
        Assert-True (Test-RunFailoverEligible -Evidence $stderrOnly)
    }
    Test-Case 'EVID-RATE-LIMIT rate limit 與 429 為 rate-limited，Reconnecting 不計' {
        $rate = Get-Evidence -Name 'rate' -Event @([ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'rate limit exceeded' } })
        $http429 = Get-Evidence -Name 'http429' -Event @([ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'HTTP 429 Too many requests' } })
        Assert-Equal 'rate-limited' $rate.rejection_kind
        Assert-Equal 'rate-limited' $http429.rejection_kind
        $reconnect = Get-Evidence -Name 'reconnect' -Event @([ordered]@{ type = 'turn.started' }, [ordered]@{ type = 'error'; message = 'Reconnecting... 2/5 (HTTP 429 Too Many Requests)' },
            [ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'agent_message'; text = 'ok' } }, [ordered]@{ type = 'turn.completed'; usage = $usageGood })
        Assert-True ($null -eq $reconnect.rejection_kind) 'Reconnecting 後完成的執行不應被判為拒絕'
        $reconnectFailed = Get-Evidence -Name 'reconnect-failed' -Event @([ordered]@{ type = 'error'; message = 'Reconnecting... 5/5 (HTTP 429)' }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'Reconnecting... 5/5 (HTTP 429)' } })
        Assert-True ($null -eq $reconnectFailed.rejection_kind) '暫時性重連訊息不算拒絕'
    }
    Test-Case 'EVID-MIXED turn.failed 之前有實際工作項目時計數為 2，不可換帳號' {
        $e = Get-Evidence -Name 'mixed' -Event @([ordered]@{ type = 'item.started'; item = [ordered]@{ type = 'command_execution' } },
            [ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'agent_message'; text = 'partial' } },
            [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = $modelMessage } })
        Assert-Equal 'model-not-supported' $e.rejection_kind
        Assert-Equal 2 $e.item_event_count
        Assert-True (-not (Test-RunFailoverEligible -Evidence $e))
    }
    Test-Case 'EVID-COMPLETED 無任何拒絕的正常完成' {
        $e = Get-Evidence -Name 'done' -Event @([ordered]@{ type = 'thread.started'; thread_id = 'x' }, [ordered]@{ type = 'turn.started' },
            [ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'agent_message'; text = 'done' } }, [ordered]@{ type = 'turn.completed'; usage = $usageGood }) -Stderr ($mcpNoiseLine + "`n" + $toolEchoLine + "`n2026-11-09T09:01:00.000000Z INFO codex_core::client: 401 Unauthorized is documented here")
        Assert-True ($null -eq $e.rejection_kind)
        Assert-Equal 1 $e.item_event_count
        Assert-Equal $true $e.completed
        Assert-Equal 'recorded' $e.usage.status
        Assert-True (-not (Test-RunFailoverEligible -Evidence $e))
    }
    Test-Case 'EVID-UNCLASSIFIED 未歸類的終局失敗且零進度為 unclassified，本地失敗詞彙與已有進度不算' {
        $forbidden = Get-Evidence -Name 'forbidden' -Event @([ordered]@{ type = 'turn.started' }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = '403 Forbidden' } })
        Assert-Equal 'unclassified' $forbidden.rejection_kind
        Assert-True (Test-RunFailoverEligible -Evidence $forbidden)
        $local = Get-Evidence -Name 'local' -Event @([ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = 'sandbox command failed' } })
        Assert-True ($null -eq $local.rejection_kind) '本地失敗不應判為拒絕'
        $progress = Get-Evidence -Name 'progress-failed' -Event @([ordered]@{ type = 'item.started'; item = [ordered]@{ type = 'command_execution' } }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = '403 Forbidden' } })
        Assert-True ($null -eq $progress.rejection_kind) '已有進度的失敗不應判為未分類拒絕'
        $stderrOnly = Get-Evidence -Name 'stderr-terminal' -Event @([ordered]@{ type = 'turn.started' }) -Stderr ('2026-11-09T09:02:00Z ERROR codex_core::client: upstream exploded') -ExitCode 1
        Assert-Equal 'unclassified' $stderrOnly.rejection_kind
        $stderrNoExit = Get-Evidence -Name 'stderr-terminal-noexit' -Event @([ordered]@{ type = 'turn.started' }) -Stderr ('2026-11-09T09:02:00Z ERROR codex_core::client: upstream exploded')
        Assert-True ($null -eq $stderrNoExit.rejection_kind)
    }
    Test-Case 'EVID-LOCAL-INSTRUCTIONS 啟動時載入專案說明檔被本機權限拒絕（零進度）屬本地失敗，不是服務端拒絕、不換帳號；其他零進度的終局失敗維持 unclassified' {
        $stderrLine = '2026-11-17T12:07:07.255872Z ERROR codex_core::session: Failed to create session: failed to load AGENTS.md instructions for environment `local`: 存取被拒。 (os error 5)'
        $local = Get-Evidence -Name 'instructions-denied' -Event @() -Stderr $stderrLine -ExitCode 1
        Assert-True ($null -eq $local.rejection_kind) '本機載入說明檔失敗不應判為拒絕'
        Assert-True (-not (Test-RunFailoverEligible -Evidence $local)) '不應換帳號'
        $other = Get-Evidence -Name 'other-zero-progress' -Event @() -Stderr '2026-11-17T12:07:07Z ERROR codex_core::session: Failed to create session: upstream exploded' -ExitCode 1
        Assert-Equal 'unclassified' $other.rejection_kind
    }
    Test-Case 'EVID-USAGE 用量取最後一筆有效的 turn.completed，不逐筆加總' {
        $second = [ordered]@{ input_tokens = 2500; cached_input_tokens = 1200; output_tokens = 90 }
        $e = Get-Evidence -Name 'usage-last' -Event @([ordered]@{ type = 'turn.completed'; usage = $usageGood }, [ordered]@{ type = 'turn.completed'; usage = $second })
        Assert-Equal 'recorded' $e.usage.status
        Assert-Equal 2500 ([long]$e.usage.input_tokens)
        Assert-Equal 1200 ([long]$e.usage.cached_input_tokens)
        Assert-Equal 90 ([long]$e.usage.output_tokens)
        Assert-True ($null -eq $e.usage.reasoning_output_tokens) '缺少的欄位應為 null，不補 0'
        $noField = Get-Evidence -Name 'usage-none' -Event @([ordered]@{ type = 'turn.completed' })
        Assert-Equal 'no-usage-field' $noField.usage.status
        Assert-True ($null -eq $noField.usage.input_tokens)
        $invalid = Get-Evidence -Name 'usage-invalid' -Event @([ordered]@{ type = 'turn.completed'; usage = [ordered]@{ input_tokens = 'x'; output_tokens = 1 } })
        Assert-Equal 'no-usage-field' $invalid.usage.status
    }
    Test-Case 'EVID-USAGE-EXTRA-FIELDS usage 含巢狀或字串欄位、缺少個別欄位時，其餘欄位照常讀取，缺少的欄位為 null' {
        $nested = [ordered]@{ input_tokens = 900; cached_input_tokens = 'n/a'; output_tokens = 40; input_tokens_details = [ordered]@{ cached = 5 }; note = 'extra' }
        $e = Get-Evidence -Name 'usage-extra' -Event @([ordered]@{ type = 'turn.completed'; usage = $nested })
        Assert-Equal 'recorded' $e.usage.status
        Assert-Equal 900 ([long]$e.usage.input_tokens)
        Assert-Equal 40 ([long]$e.usage.output_tokens)
        Assert-True ($null -eq $e.usage.cached_input_tokens) '非數值的欄位應為 null'
        Assert-True ($null -eq $e.usage.reasoning_output_tokens) '缺少的欄位應為 null'
        $missingOutput = Get-Evidence -Name 'usage-no-output' -Event @([ordered]@{ type = 'turn.completed'; usage = [ordered]@{ input_tokens = 1 } })
        Assert-Equal 'no-usage-field' $missingOutput.usage.status
    }
    Test-Case 'EVID-STDERR-LIMITS 只出現在 stderr ERROR 行的 usage limit 與 rate limit 被分類，Reconnecting 與工具回顯行不算，已完成的執行不算' {
        $usageLine = '2026-11-09T09:02:00Z ERROR codex_core::client: You have hit your usage limit. Try again later.'
        $usage = Get-Evidence -Name 'stderr-usage' -Event @([ordered]@{ type = 'turn.started' }) -Stderr $usageLine -ExitCode 1
        Assert-Equal 'usage-limit' $usage.rejection_kind
        Assert-True (Test-RunFailoverEligible -Evidence $usage)
        $plain = Get-Evidence -Name 'stderr-usage-plain' -Event @([ordered]@{ type = 'turn.started' }) -Stderr 'ERROR: usage limit reached' -ExitCode 1
        Assert-Equal 'usage-limit' $plain.rejection_kind
        $rate = Get-Evidence -Name 'stderr-rate' -Event @([ordered]@{ type = 'turn.started' }) -Stderr '2026-11-09T09:02:00Z ERROR codex_core::client: rate limit exceeded (HTTP 429)' -ExitCode 1
        Assert-Equal 'rate-limited' $rate.rejection_kind
        $reconnect = Get-Evidence -Name 'stderr-reconnect' -Event @([ordered]@{ type = 'turn.started' }) -Stderr '2026-11-09T09:02:00Z ERROR codex_core::client: Reconnecting... 2/5 (HTTP 429)' -ExitCode 1
        Assert-True ($reconnect.rejection_kind -ne 'rate-limited' -and $reconnect.rejection_kind -ne 'usage-limit') 'Reconnecting 不應判為 rate-limited'
        $toolEcho = Get-Evidence -Name 'stderr-tool-echo' -Event @([ordered]@{ type = 'turn.started' }) -Stderr $toolEchoLine -ExitCode 1
        Assert-True ($toolEcho.rejection_kind -ne 'usage-limit' -and $toolEcho.rejection_kind -ne 'rate-limited') '工具失敗回顯行不應判為拒絕'
        $completed = Get-Evidence -Name 'stderr-completed' -Event @([ordered]@{ type = 'turn.started' }, [ordered]@{ type = 'turn.completed'; usage = $usageGood }) -Stderr $usageLine -ExitCode 0
        Assert-True ($null -eq $completed.rejection_kind) '已完成的執行不應判為被拒絕'
    }
    Test-Case 'EVID-UNPARSABLE 事件流含無法解析的行時略過該行，不丟例外' {
        $e = Get-Evidence -Name 'garbage' -Event @([ordered]@{ type = 'turn.started' }) -RawLine @('{ this is not json', 'plain text line', '[1,2,3]') -Stderr ''
        Assert-Equal 3 $e.unparsable_line_count
        Assert-True ($null -eq $e.rejection_kind)
        Assert-Equal 0 $e.item_event_count
    }
    Test-Case 'EVID-MISSING-FILE 事件流檔不存在時不丟例外' {
        $e = Get-RunEventEvidence -EventStreamPath (Join-Path $root 'absent.jsonl')
        Assert-True ($null -eq $e.rejection_kind)
        Assert-Equal 0 $e.item_event_count
        Assert-Equal $false $e.completed
    }

    # ---------- [FIX-ITEM] turn.failed 之前的錯誤項目不計為進度 ----------
    $errorOnlyEvents = @([ordered]@{ type = 'thread.started'; thread_id = 'x' }, $metadataWarning, [ordered]@{ type = 'turn.started' },
        [ordered]@{ type = 'error'; message = $modelMessage }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = $modelMessage } })
    function Get-MutantItemCount {
        # 對照組：把所有 item.* 事件都計入。
        param([string]$EventStreamPath)
        $count = 0
        foreach ($line in (Get-Content -LiteralPath $EventStreamPath)) {
            $event = ConvertFrom-Json -InputObject $line
            if ([string]$event.type -like 'item.*') { $count++ }
        }
        return $count
    }
    function Assert-NoProgress {
        param([int]$Count)
        Assert-True ($Count -eq 0) ('只有錯誤項目的事件流不應有進度，計數為 ' + $Count)
    }
    Test-Case '[FIX-ITEM] POSITIVE 只有 item.type=error 時計數為 0 且可換帳號；混入 agent_message 為 1；缺 item 物件為 0' {
        $e = Get-Evidence -Name 'item-error-only' -Event $errorOnlyEvents
        Assert-Equal 0 $e.item_event_count
        Assert-True (Test-RunFailoverEligible -Evidence $e)
        Assert-NoProgress -Count $e.item_event_count
        $withMessage = Get-Evidence -Name 'item-with-message' -Event (@($errorOnlyEvents[0..2]) + @([ordered]@{ type = 'item.completed'; item = [ordered]@{ type = 'agent_message'; text = 'x' } }) + @($errorOnlyEvents[3..4]))
        Assert-Equal 1 $withMessage.item_event_count
        Assert-True (-not (Test-RunFailoverEligible -Evidence $withMessage))
        $noItem = Get-Evidence -Name 'item-missing' -Event @([ordered]@{ type = 'item.started' }, [ordered]@{ type = 'item.completed'; item = $null }, [ordered]@{ type = 'turn.failed'; error = [ordered]@{ message = $modelMessage } })
        Assert-Equal 0 $noItem.item_event_count
    }
    Test-Case '[FIX-ITEM] MUTANT 把所有 item.* 事件計入的對照計數器，對同一份事件流得到非零計數，同一斷言對它失敗' {
        $files = New-TestEventStream -Directory $root -Name 'item-mutant' -Event $errorOnlyEvents
        $mutantCount = Get-MutantItemCount -EventStreamPath $files.event
        Assert-True ($mutantCount -gt 0) '對照計數器應得到非零計數'
        $null = Assert-Throws -Script { Assert-NoProgress -Count $mutantCount }
    }

    # ---------- 結果判定表 ----------
    Test-Case 'RESULT-TABLE 判定表 6 列加拒絕列的結果與原因' {
        $none = [pscustomobject]@{ rejection_kind = $null; item_event_count = 0 }
        $lastMessage = Join-Path $root 'last.md'
        $emptyMessage = Join-Path $root 'last-empty.md'
        $report = Join-Path $root 'report.md'
        $emptyReport = Join-Path $root 'report-empty.md'
        Write-TestUtf8 -Path $lastMessage -Text 'done'
        [IO.File]::WriteAllBytes($emptyMessage, [byte[]]@())
        Write-TestUtf8 -Path $report -Text '# 報告'
        [IO.File]::WriteAllBytes($emptyReport, [byte[]]@())
        $absent = Join-Path $root 'absent.md'
        $cases = @(
            @{ name = '拒絕'; exit = 1; message = $absent; report = $absent; evidence = [pscustomobject]@{ rejection_kind = 'usage-limit'; item_event_count = 0 }; result = 'rejected'; reason = 'usage-limit' },
            @{ name = '拒絕且結束碼 0'; exit = 0; message = $lastMessage; report = $report; evidence = [pscustomobject]@{ rejection_kind = 'unauthorized'; item_event_count = 3 }; result = 'rejected'; reason = 'unauthorized' },
            @{ name = '非零結束碼'; exit = 2; message = $lastMessage; report = $report; evidence = $none; result = 'failed'; reason = 'nonzero-exit' },
            @{ name = '最後訊息不存在'; exit = 0; message = $absent; report = $report; evidence = $none; result = 'failed'; reason = 'no-last-message' },
            @{ name = '最後訊息為空'; exit = 0; message = $emptyMessage; report = $report; evidence = $none; result = 'failed'; reason = 'no-last-message' },
            @{ name = '報告不存在'; exit = 0; message = $lastMessage; report = $absent; evidence = $none; result = 'failed'; reason = 'report-missing' },
            @{ name = '報告為空'; exit = 0; message = $lastMessage; report = $emptyReport; evidence = $none; result = 'failed'; reason = 'report-empty' },
            @{ name = '成功'; exit = 0; message = $lastMessage; report = $report; evidence = $none; result = 'success'; reason = $null }
        )
        foreach ($case in $cases) {
            $actual = Get-RunResult -ExitCode $case.exit -LastMessagePath $case.message -ReportPath $case.report -Evidence $case.evidence
            Assert-Equal $case.result $actual.result ($case.name + ' result')
            Assert-Equal $case.reason $actual.failure_reason ($case.name + ' failure_reason')
        }
    }
    Test-Case 'RESULT-NOT-SUCCESS 結束碼 0、最後訊息非空、無報告時不被判為 success' {
        $lastMessage = Join-Path $root 'last2.md'
        Write-TestUtf8 -Path $lastMessage -Text 'done'
        $actual = Get-RunResult -ExitCode 0 -LastMessagePath $lastMessage -ReportPath (Join-Path $root 'absent-report.md') -Evidence ([pscustomobject]@{ rejection_kind = $null; item_event_count = 0 })
        Assert-True ($actual.result -ne 'success') '不應為 success'
        Assert-Equal 'report-missing' $actual.failure_reason
    }
    Test-Case 'RESULT-TIMEOUT 逾時為 failed（timeout），拒絕種類優先；回合結束後終止者不看結束碼，仍須最後訊息與報告' {
        $none = [pscustomobject]@{ rejection_kind = $null; item_event_count = 0 }
        $lastMessage = Join-Path $root 'last-t.md'
        $report = Join-Path $root 'report-t.md'
        $absent = Join-Path $root 'absent-t.md'
        Write-TestUtf8 -Path $lastMessage -Text 'done'
        Write-TestUtf8 -Path $report -Text '# 報告'
        $timedOut = Get-RunResult -ExitCode 1 -LastMessagePath $lastMessage -ReportPath $report -Evidence $none -TimedOut
        Assert-Equal 'failed' $timedOut.result
        Assert-Equal 'timeout' $timedOut.failure_reason
        $timedOutRejected = Get-RunResult -ExitCode 1 -LastMessagePath $absent -ReportPath $absent -Evidence ([pscustomobject]@{ rejection_kind = 'unauthorized'; item_event_count = 0 }) -TimedOut
        Assert-Equal 'rejected' $timedOutRejected.result
        $terminated = Get-RunResult -ExitCode 1 -LastMessagePath $lastMessage -ReportPath $report -Evidence $none -TerminatedAfterTurnEnd
        Assert-Equal 'success' $terminated.result
        $terminatedNoReport = Get-RunResult -ExitCode 1 -LastMessagePath $lastMessage -ReportPath $absent -Evidence $none -TerminatedAfterTurnEnd
        Assert-Equal 'report-missing' $terminatedNoReport.failure_reason
        $notTerminated = Get-RunResult -ExitCode 1 -LastMessagePath $lastMessage -ReportPath $report -Evidence $none
        Assert-Equal 'nonzero-exit' $notTerminated.failure_reason
    }
    Test-Case 'FAILOVER-ELIGIBLE 換帳號資格只看拒絕種類與零進度' {
        Assert-True (-not (Test-RunFailoverEligible -Evidence $null))
        Assert-True (-not (Test-RunFailoverEligible -Evidence ([pscustomobject]@{ rejection_kind = $null; item_event_count = 0 })))
        Assert-True (Test-RunFailoverEligible -Evidence ([pscustomobject]@{ rejection_kind = 'rate-limited'; item_event_count = 0 }))
        Assert-True (-not (Test-RunFailoverEligible -Evidence ([pscustomobject]@{ rejection_kind = 'rate-limited'; item_event_count = 1 })))
    }
}
finally {
    $exitCode = Complete-TestRun
}
exit $exitCode
