# Dispatch 模組索引

入口 `scripts/Invoke-CodexDispatch.ps1` 依下列順序以 dot-source 載入模組。函式定義共用入口的 script scope。

| 載入順序 | 模組 | 責任 | 主要函式 |
| ---: | --- | --- | --- |
| 1 | `common-runtime.ps1` | OS 判定、路徑正規化、外部程序與 Git 命令包裝、文字輸出 | `Test-IsWindowsPlatform`、`Resolve-AbsolutePath`、`Test-PathWithinRoot`、`Invoke-ExternalCommand`、`Invoke-GitCommand`、`Write-Utf8NoBom` |
| 2 | `git-baseline.ps1` | Git repository 狀態、carry-in、working tree snapshot、baseline 與輸出路徑守衛 | `Apply-SourceCarryIn`、`Get-DispatchFileSnapshot`、`New-DispatchBaseline`、`Read-DispatchBaseline`、`Get-DispatchIncrementalChanges`、`Resolve-DispatchBaselineBinding` |
| 3 | `dispatch-scope.ps1` | Request 欄位驗證、單位解析、ScopePlan 與 continuation 範圍 | `Apply-DispatchRequest`、`Assert-DispatchRequestRequiredField`、`Get-DispatchDeclaredUnitList`、`New-ScopePlan`、`Get-ScopePlanFingerprint`、`Test-ContinuationScopePlan` |
| 4 | `dispatch-evidence.ps1` | Parent options、模型證據、Profile 診斷與 evidence binding | `New-ParentOptionsModel`、`New-DispatchEvidenceBinding`、`Resolve-CodexHomeForEvidence`、`Read-ProfileModelEvidence`、`Invoke-ModelEnvironmentDiagnostic` |
| 5 | `quota-observation.ps1` | Quota Snapshot、觀測、Budget Monitor 與 quota probe | `Read-QuotaSnapshot`、`Get-QuotaSnapshotFreshness`、`Get-OrCreateQuotaSnapshot`、`Invoke-QuotaObservationSnapshot`、`Invoke-AdvisorBudgetMonitor`、`Invoke-QuotaProbe` |
| 6 | `advisor-evidence.ps1` | Advisor 契約、Prompt、evidence pack、thread relay 與報告 | `New-DispatchPrompt`、`Assert-AdvisorContract`、`Test-AdvisorEvidencePack`、`Wait-ForThreadRelay`、`Write-AdvisorConsultReport` |
| 7 | `process-identity.ps1` | RunRecord process identity、Windows 與 Unix process snapshot、PID 與 process tree 驗證 | `Read-LineManifest`、`Get-WindowsProcessSnapshots`、`Get-UnixProcessSnapshot`、`Test-RecordedProcessIdentity`、`Get-DescendantProcessIds`、`Get-PidCheckResult` |
| 8 | `reviewer-contract.ps1` | Reviewer 報告與 finding schema 驗證、evidence 連結、finding ledger 與 Collect 判定 | `Test-ReviewerFindingReport`、`Resolve-ReviewerEvidencePath`、`Write-ReviewerFindingLedger`、`Get-ReviewerFindingsForCollect` |
| 9 | `run-recovery.ps1` | RunRecord 與 event stream 讀取、失敗分類、續行鏈結與 Collect identity 解析 | `Get-DispatchEventEvidence`、`Get-RecoveryChainModel`、`Read-DispatchRunRecord`、`Resolve-PreviousDispatchRun`、`Resolve-InspectDispatchRun`、`Resolve-DispatchCollectIdentityRequestSource`、`Test-DispatchCollectIdentity` |
| 10 | `prepare-stage.ps1` | Prepare root 與目的地解析、stage binding、result 與 failure receipt 讀寫、Prepare 執行 | `Resolve-PrepareDestinationRoot`、`New-DispatchStageBinding`、`Assert-DispatchStageBinding`、`Write-DispatchFailureReceipt`、`Resolve-PrepareResultBinding`、`Invoke-Prepare` |
| 11 | `dispatch-lifecycle.ps1` | Preflight 與 Dispatch 階段協調、stage 結果及 Dispatch result binding 寫入 | `Invoke-Preflight`、`Write-DispatchStageResult`、`Write-DispatchInspectResultBinding`、`New-DispatchResultEnvelope`、`Invoke-Dispatch` |
| 12 | `start-lifecycle.ps1` | Codex launcher 與 executable 選擇、Start evidence、process tree 管理及 Start 執行 | `Get-CodexExecutablePath`、`New-CodexLauncher`、`Write-StartPidRecord`、`Stop-VerifiedProcessTree`、`Initialize-DispatchOutputFile`、`Invoke-Start` |
| 13 | `inspect-lifecycle.ps1` | event 與 exit sidecar 判讀、Dispatch inspect binding 驗證及 Inspect 執行 | `Read-DispatchExitSidecar`、`Wait-DispatchExitAndTerminalEvent`、`Resolve-DispatchInspectBinding`、`Invoke-Inspect` |
| 14 | `collect-contract.ps1` | Requirement summary 與報告解析、需求參照及直接寫入證據驗證、Collect 執行 | `Get-RequirementIdsFromSummary`、`Get-RequirementMap`、`Get-ReportReferencedPaths`、`Get-DirectWriteFileEvidence`、`Invoke-DirectWriteCollect`、`Invoke-Collect` |
| 15 | `cleanup.ps1` | Cleanup identity 驗證、檔案清單與 UTF-8 readback、保留證據及 Cleanup 執行 | `New-CleanupOperationResult`、`Get-CleanupInventory`、`Test-CleanupUtf8Readback`、`Preserve-CleanupFile`、`Invoke-Cleanup` |
| 16 | `Invoke-DispatchConcurrency.ps1` | Caller Session fingerprint、持久 admission ledger、跨程序獨占鎖、名額與來源路徑互斥、owner 驗證及 Collect source integration | `Get-DispatchCallerSessionIdentity`、`Open-DispatchAdmissionLock`、`Assert-DispatchAdmission`、`Invoke-DispatchAdmissionStart`、`Assert-DispatchAdmissionOwner`、`Invoke-DispatchSourceIntegration` |
