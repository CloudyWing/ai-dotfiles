---
name: codex-dispatch
description: 'Codex 派工機制：依派工類型建立執行契約、以 codex exec 啟動 Codex、背景等待、取證並回收結果。當需要發動 codex、撰寫派遣單或執行派遣回收判定時使用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Codex 派工機制

本 Skill 負責派工的執行機制。是否派工由 `instructions.md` §1.5 的路由規則判定，本 Skill 只處理指令、落點、等待、取證、續 session 與回收。

## 使用時機與入口選擇

主 Agent 依 F1 判準判定要派工後載入本 Skill。執行端角色依角色規則檔引用本 Skill 的共用作業節時，只讀取被引用的節。

| 情境 | 入口 | 必要輸入 | 提供方式 |
| --- | --- | --- | --- |
| 建立資源派遣單 | `scripts\New-DispatchOrder.ps1` | `Title`、`Role`、`TargetPath`、`TaskBody`、`Acceptance`、`Boundary`、`ReportPath`、`DispatchSlug`、`LineSlug`；`OutputPath` 選填 | 命令列參數；省略 `OutputPath` 時派遣單寫入來源工作樹同線 `handoff\<lineSlug>\`，八個欄位定義見「派遣單契約」 |
| 首次啟動一筆派遣（正式入口） | `scripts\Invoke-CodexDispatch.ps1 -Operation Dispatch` | `source_root`、`dispatch_root`、`line_slug`、`dispatch_slug`、`write_mode`、`dispatch_kind`、至少一個 `target_path`、`prompt_path`、`task_type`、`session_mode`、`unit_kind`、`failure_receipt_path` | 只接受 `operation=Dispatch` 的 request 檔（UTF-8 無 BOM），以 `-RequestPath` 傳入；欄位表與範例見「Dispatch 正式入口」 |
| 同一 worktree 續行；換 worktree 續行；恢復或階段間檢查 | 同一 worktree 使用 `Start -ResumeThreadId`；換 worktree 使用 `Dispatch` 的 `session_mode=Continuation`；階段間檢查可分步呼叫 `Preflight`、`Prepare`、`Start` | 同一 worktree 的 Start 使用前輪 Dispatch result 記錄的 Preflight、Prepare 結果路徑及原 ScopePlan；換 worktree 使用新 `dispatchSlug`、重建 worktree 並承接父 ScopePlan | Start 參數來源見「續 session 與跨介面接手」；Dispatch 使用 request 檔；`prepare_artifacts` 只能經 request 檔傳入 |
| 執行結束或中斷後 | `Inspect`，接著 `Collect` | 事件流、stderr、last-message、Preflight 結果與報告路徑；中斷時另回收逐單位保全檔 | 命令列參數 |
| 回收完成且不再續行 | `Cleanup` | 保存清單、RunRecord、報告與 evidence 路徑 | 命令列參數或 request 檔 |
| 查詢派遣進度（唯讀） | `scripts\Get-DispatchProgress.ps1` | `WorkRoot`、`LineSlug`、`DispatchSlug` 選填；`-All` 顯示全部紀錄 | 直接執行，預設顯示未結束與最近 24 小時內結束的項目 |

`~/.ai-agents/templates/dispatch/` 提供派遣單、Request、failure receipt、result envelope、Developer 結案報告、`exceptions.md` 與 Reviewer 報告的範本。派遣單以 `New-DispatchOrder.ps1` 產生為正常路徑，範本供手動核對結構；報告範本的必要區段以 Collect 與 Cleanup 的驗證為準。

正常路徑使用的正式 operation 為 `Dispatch`、`Inspect`、`Collect` 與 `Cleanup`；`DiagnoseModelEnvironment` 只供使用者或維運者診斷。`Preflight`、`Prepare` 與 `Start` 是 `Dispatch` 內部的階段轉移，命令列保留這三個 operation 供續行、恢復與測試使用，新的一筆派遣一律從 `Dispatch` 進入。

request 欄位先依 parser 白名單驗證，再依 operation 套用欄位作用域。識別欄位為 `schema`、`operation`、`line_slug`、`dispatch_slug`。其他一般白名單欄位為 `profile`、`advisor_request_source`、`target_path`、`add_directory`、`search`、`codex_parent_option`、`literal_values`、`prepare_artifacts`、`result_path`、`preflight_result_path`。共用根目錄欄位（`commonRootFields`）為 `source_root`、`dispatch_root`、`caller_session_id`。

`Dispatch` 專用欄位（`dispatchOnlyFields`）完整清單為 `write_mode`、`dispatch_kind`、`prompt_path`、`task_type`、`session_mode`、`unit_kind`、`requested_unit`、`continue_from_scope_plan`、`background`、`required_identifier`、`failure_receipt_path`、`prepare_result_path`、`quota_before_path`、`quota_after_path`、`evidence_pack_path`、`advisor_consult_report_path`、`selected_requirement`。`Cleanup` 專用欄位（`cleanupOnlyFields`）為 `run_record_path`、`reviewer_report_path`、`report_path`、`evidence_path`。`Dispatch` 不接受 Cleanup 專用欄位，`Cleanup` 不接受 Dispatch 專用欄位；其他 operation 不接受共用根目錄、`result_path`、`preflight_result_path` 或兩組 operation 專用欄位。`source_root`、`result_path` 與 `preflight_result_path` 只在 `Dispatch` 與 `Cleanup` 合法。同一欄位在 request 檔與命令列不一致時以 `DispatchRequestMismatch` 停止。

Request 的 `operation` 以不區分大小寫的方式驗證，解析後使用正式 operation 名稱；命令列與 Request 的 operation 比對也不區分大小寫。結果的 `dispatch_request` 會保存 Request 檔路徑、SHA-256、位元組長度、正規化 operation、line／dispatch identity、欄位 presence，以及共用、Dispatch 與 Cleanup 欄位的正規化值。陣列欄位另保存筆數、SHA-256 與值；`literal_values` 另有獨立 SHA-256。

Start 將 Request 檔路徑、SHA-256 與 operation 綁定至 RunRecord。advisor Inspect 會重新讀取 evidence pack，核對 Start 記錄的 SHA-256 與檔案長度，並在結果中回報 evidence pack 路徑與 hash；來源變更或內容不符時停止驗收。

### Caller Session 身分與併行准入

`Dispatch`、`Preflight`、`Prepare`、`Start` 與 `Cleanup` 依序解析 caller Session ID：Request 的 `caller_session_id`、CLI `-CallerSessionId`、環境變數 `CLAUDE_CODE_SESSION_ID`、環境變數 `CODEX_THREAD_ID`。Request 的 `caller_session_id` 欄位只在 `Dispatch` 與 `Cleanup` 的 Request 有效，其他 operation 的 Request 帶此欄位時以 `DispatchRequestFieldNotAllowed` 拒絕，改由 CLI 或環境變數提供。Request 與 CLI 同時提供時採用 Request 值。四個來源皆無有效值時，以 `CallerSessionIdMissing` 在 Prepare／Start 副作用前停止；空值或超過長度上限時以 `CallerSessionIdInvalid` 停止。既有 Claude 呼叫端可繼續由 `CLAUDE_CODE_SESSION_ID` 提供身分，不需修改 Request。

RunRecord、PID 記錄、結果與 admission ledger 保存 caller Session fingerprint 及來源名稱，不複製原始 ID。Ledger 位於 source root 的 history 目錄，所有讀取、比較與原子替換都在同一個短暫獨占鎖內執行。Start 在鎖內重做 PID identity check，啟動 Codex、寫入 PID 記錄並登記 owner，避免兩個入口同時通過檢查後重複取得名額。

同一 caller Session 可同時持有一個 write admission 與最多兩個 readonly admission。Worktree write 期間可執行同線 readonly 派遣。路徑衝突比對要求至少一方為 direct-write 目標；與其他派遣的 direct-write 目標或 `--add-dir` 權限路徑相同或有父子路徑關係時，新的 admission 以 `DispatchAdmissionPathConflict` 拒絕。各派遣所屬線的 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>` 目錄及其子路徑，只有在該 admission 的路徑為 `--add-dir` 時才排除於衝突比對外；direct-write 即使位於該處，仍與其他派遣的 direct-write 目標或 `--add-dir` 路徑進行父子重疊比對。`--add-dir` 對 `--add-dir` 可並行。第二個 write 以 `DispatchAdmissionWriteLimit` 拒絕，第三個 readonly 以 `DispatchAdmissionReadonlyLimit` 拒絕。Ledger owner 身分無法確認時，新的 admission 與 Cleanup 皆以 `DispatchAdmissionOwnerUnknown` 拒絕。

`Cleanup` 以 ledger 的 caller fingerprint、line 與 dispatch 驗證 owner；提供 RunRecord 時另比對 RunRecord 的 caller fingerprint。Owner 不相符時以 `DispatchAdmissionOwnerMismatch` 拒絕，且保留 worktree。Workflow worktree 的 `Collect` 通過既有驗收後，可額外指定 `-ApplyCollectedChanges` 套用變更；套用前會在 source root 鎖內比對每個目標路徑的 baseline fingerprint，漂移時以 `DispatchSourceDrift` 停止並保留 worktree。Direct-write 已直接修改 source root，指定此參數時以 `DispatchCollectApplyDirectWriteNotApplicable` 拒絕。Quota monitor 更新 after snapshot 時使用相同 source root 鎖，並在鎖內完成 SHA-256 比對與 `File.Replace`。

## 最短正常路徑

一筆派遣依下列順序推進。每一步的產物是下一步的輸入，上一步未成功時不進入下一步。

| 步驟 | 動作 | 產物 | 下游接收者 |
| --- | --- | --- | --- |
| 1 | 產生派遣單（資源派遣），或確認 `design.md` 已通過 Design 驗收（Workflow） | 派遣單或 `design.md` | Prompt 與 Codex 執行端 |
| 2 | `Preflight` 驗證 LineContext、PID 與寫入面，決定 `executionRoot` | Preflight 結果 JSON | Prepare、Start、Collect |
| 3 | `Prepare` 將交接檔複製到 `executionRoot` 並比對 SHA-256 | `-PrepareResultPath` 寫出的 `ai-sessions.prepare.v1` 文件；`-ResultPath` 只寫 CLI envelope | Start 只接受 `ai-sessions.prepare.v1` 文件 |
| 4 | `Start` 建立 before 額度快照與 ScopePlan，背景啟動 Codex | Start 結果、事件流、stderr、last-message、thread id、PID 記錄 | 主 Agent 的等待與 Inspect |
| 5 | 等待完成通知，依「完成判定與三出口」判定出口 | 出口判定 | Inspect |
| 6 | `Inspect` 解析事件流與 last-message | `success`、`outputValid`、usage、model evidence | RecoveryPrecheck 與回收三態 |
| 7 | `RecoveryPrecheck` 通過後，`Collect` 核對成果與報告，主 Agent 判定回收三態 | Collect 結果與三態判定 | 續行、升級或同步 |
| 8 | 同步報告與核准交接產物，再執行 `Cleanup` | 保存驗證結果 | 結案報告 |

`Dispatch` 串接步驟 2 至 6。預設同步等待 Codex 結束後執行 Inspect，回傳 `completed` 或 `failed`；Request 設 `background: true` 時先回傳 `status=started`，只代表 Codex 已啟動，再以 `Inspect -WaitForCompletion` 等待。步驟 7 與 8 的回收判定由主 Agent 執行，派遣不再需要在 Session 內另寫 runner。

### Dispatch 正式入口

- 單位自動產生：Workflow 依 `design.md`「實作任務清單」章（`## ` 開頭且含「實作任務清單」的章節）內的 `### Phase N` 或 `#### Phase N` 標題順序產生 `requested_unit`，找不到該章時才解析全文件；章內同編號連續小節合併為一個單位，非連續重複拒絕；資源派遣依 `<sourceRoot>\.local\ai-sessions\handoff\dispatch-order-<dispatchSlug>.md` 第 3 欄產生，Request 的 `target_path` 必須與該欄完全相符。明確提供的 `requested_unit` 必須是來源清單的有序子集合。來源與 Request 不一致時，入口在 Preflight、Prepare、worktree 建立與 Codex 啟動前拒絕，回傳 `operation: DispatchRequest`、`process_started: false` 與 `detail.differences`。Request 欄位驗證錯誤的 detail 只列欄位名稱、預期格式與輸入長度，不回顯原始輸入值。
- 派遣單目標路徑：第 3 欄若填入含 `dispatchSlug` 的 worktree 絕對路徑，改用新的 `dispatchSlug` 時需同步更新目標路徑並重產派遣單。目標位於 `sourceRoot` 且所選 sandbox 能直接讀取時，建議填穩定的 `sourceRoot` 絕對路徑；`readonly` 目標在 repository 外時，還需確認 Preflight 的 `targetsOutsideRepository` 與唯讀 sandbox 允許直接讀取。此建議不改變 Request `target_path` 必須與第 3 欄完全相符的條件。
- Prepare 自動帶入：同線 `line.json`、`requirement-summary.md`；Workflow 另帶入 `design.md`，資源派遣在第 4 欄提及 `design.md` 時帶入，並把派遣單複製到 dispatch worktree 的同線 handoff。`prepare_artifacts` 只用於追加其他檔案。
- 輸出路徑安全：`result_path` 與 `preflight_result_path` 必須位於 SourceRoot 或 ExecutionRoot，root、既有各層目錄與寫入目標任一層為 reparse point 時拒絕；未指定時輸出到 ExecutionRoot 同線 history。需要 worktree 清除後仍可從來源工作樹取用時，明確指定 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>\` 下的路徑。`prepare_result_path` 的目的地限於 ExecutionRoot 的同線 handoff、report 或 history line root，且不得與 target path 重疊；未指定時輸出到 ExecutionRoot 同線 history。目錄建立後、實際寫入前會再次核對路徑。
- direct-write：Preflight 判定不建 worktree（`worktreeCreated=false`）時，Prepare 使用 Preflight 的 `executionRoot`（即 `sourceRoot`）作為 DispatchRoot，Request 的 `dispatch_root` 只用於路徑驗證；只寫同線 handoff 的資源派遣可直接使用正式入口。
- 可省略欄位：`profile`（預設 `default`）、`requested_unit`、`prepare_artifacts`、`background`（預設 `false`）、`required_identifier`（Workflow 預設 `design.md`，資源派遣預設第一個 target 的檔名；advisor-consult 沒有 target 時預設 evidence pack 檔名，Start 注入與 Inspect 比對使用同一個值）、`selected_requirement`（本輪選定需求，傳給 Workflow Collect）、各階段結果路徑與額度快照路徑。
- 輸出欄位：`status`（`started`、`completed`、`failed`）、`completed_stages`、`failed_stage`、`error_code`、`error`、`process_started`、`process_exit_code`、`termination_reason`、`inspect_status`、`inspect_success`、`requested_units`、`result_path`、`result_sha256`、`inspect_result_path`。`Collect` 的參數取自這些欄位。所有 operation 的 JSON stdout 固定使用 UTF-8（無 BOM），不依 PowerShell host 的預設主控台編碼。

背景派遣的等待命令如下。`-WaitForCompletion` 等待 sidecar 確認 Codex 行程結束，再以事件流 terminal event 決定結果，沒有固定逾時。`-WaitForCompletion` 只接受 `Dispatch` 產生的 result（需含 `result_sha256`）；逐一呼叫 Preflight、Prepare、Start 的分步入口不能用它等待，改由執行環境的背景完成通知接手後呼叫 `Inspect`。

```powershell
.\scripts\Invoke-CodexDispatch.ps1 -Operation Inspect -DispatchResultPath <result_path> `
  -SourceRoot <source_root> -ExecutionRoot <execution_root> -LineSlug <line_slug> -DispatchSlug <dispatch_slug> `
  -TargetPath <target_path> -RequiredIdentifier <required_identifier> -WriteMode <write_mode> -WaitForCompletion
```

## 失敗與恢復導引

| 失敗形狀 | 恢復方式 | 詳細節 |
| --- | --- | --- |
| 額度快照 `state` 不是 `Valid`，或 observation 為 `stale` | 記為 unknown 或 stale，派工照常進行，不改變範圍。`SnapshotUnavailable` 與 `stale` 需要最新數值時可重新查詢一次；`ServiceRejected` 不重新查詢也不重試，等待重設或新的觀測證據 | 額度狀態與回復探針 |
| admission 或 Start 準備階段失敗、Codex 程序未啟動 | 修正輸入後可用同一個 `dispatchSlug` 重新冷啟動。腳本會清除該次失敗嘗試建立的 ScopePlan hash 紀錄，`failure receipt` 與 `launch-failed` RunRecord 保留供稽核；已啟動成功者的 hash、ledger 與 owner 不受影響。若 `Cleanup` 缺少 Preflight，未啟動證明還要求 dispatch worktree 的 `.local\ai-sessions\history` 下不存在 `codex-exec-*.jsonl` 與 `codex-thread-<dispatchSlug>.txt`；任一檔案存在時以 `CleanupPreflightResultRequired` 拒絕並保留 worktree。該次嘗試已建立 dispatch worktree 時，Preflight 會因 dispatchRoot 已被占用而拒絕，此時改用新的 `dispatchSlug`；Prepare 結果檔已存在而發生 `PrepareResultCollision` 時，改用新的結果路徑或新的 `dispatchSlug` | 續 session 與跨介面接手 |
| 續行被拒 | 以 `git -C <舊 dispatchRoot> diff HEAD` 與未追蹤檔案清單轉移成果，以新的 `dispatchSlug` 冷啟動 | Codex 進程 PID 與並行檢查 |
| 事件流在最後訊息前中斷，沒有 `turn.completed` 或 `turn.failed` | 先執行 `Inspect` 與 `Collect` 取回中斷保全檔；只交付已確認單位與其證據，其餘 selected units 保持未完成 | InterruptionSafeguard |
| 事件流以 `turn.failed` 結束或 exit code 非零 | 依 C 出口取失敗原因。若事件流以 `turn.failed` 結束且結案報告不存在，`Inspect` 與 `Collect` 回報 `recoverable_artifacts_present` 及 `recoverable_artifact_files`，供主 Agent 檢視相對 `baseSha` 的 worktree 變更並決定是否以新 `dispatchSlug` 冷啟動；欄位不改變失敗判定 | 完成判定與三出口 |
| 派遣 target_path 符合機密檔名樣式 | `Preflight` 以 `PreflightSecretTargetRejected` 列出路徑並在建立 worktree 前停止 | Git 前置探針與 worktree 生命週期 |
| Prepare 失敗且 `PrepareFailed` 文件再次寫入失敗 | 由 operation result 的 `prepareResultWriteFailure.code=PrepareResultWriteFailed` 與 `prepareResultWriteFailure.path` 取得錯誤碼與目標路徑；`prepareResultSha256=null`，不將該路徑視為已成功保存的 Prepare 文件，修正寫入條件後重新 Prepare | 腳本介面與執行前提 |
| 結案訊息缺少識別字 | 標記 `PromptNotDelivered`，修正啟動方式後重新派遣 | RecoveryPrecheck |

### 四種阻塞形狀的產物與交接

派工受阻時，先判定屬於下列哪一種形狀，再依對應的產物語意與交接方式處理。腳本已承擔的部分不改由人工步驟補做。

| 阻塞形狀 | 產物語意 | 操作交接 | 詳細節 |
| --- | --- | --- | --- |
| 入口不對稱 | `Dispatch` 是新派遣的唯一正式入口；Request 檔與命令列的同名欄位語意與驗證相同，兩邊不一致時以 `DispatchRequestMismatch` 拒絕 | 新的一筆派遣一律從 `Dispatch` 進入；`Preflight`、`Prepare`、`Start` 的分步入口只用於續行、恢復與測試 | 使用時機與入口選擇、Dispatch 正式入口 |
| 失敗重試污染 | 程序未啟動的失敗嘗試留下 `failure receipt` 與 `launch-failed` RunRecord 供稽核，該次建立的 ScopePlan hash 會被清除 | 程序未啟動且未留下 dispatch worktree 時以同一個 `dispatchSlug` 重試，已留下 worktree 時改用新的 `dispatchSlug`；程序已啟動的派遣改走續行，或以新 `dispatchSlug` 冷啟動並轉移成果 | 失敗與恢復導引、續 session 與跨介面接手 |
| 外部狀態恢復 | 額度快照以新檔寫入 before 與 after，附 `state` 與 freshness；`ServiceRejected` 不重試；中斷時以中斷保全檔記錄已確認單位與證據位置 | 主 Agent 依快照呈現資訊，advisor 啟動由使用者授權；中斷後先 `Inspect`、`Collect` 取回中斷保全檔，只交付已確認單位 | 額度與範圍契約、InterruptionSafeguard、advisor 授權請求 |
| 同名參數語意 | `-ResultPath` 只寫 CLI envelope；`-PrepareResultPath` 寫 `ai-sessions.prepare.v1` 文件；每個產物只有一個寫入者 | `Start` 只接受 `ai-sessions.prepare.v1` 文件；`Collect` 的參數取自 `Dispatch` 輸出欄位，不自行拼湊路徑 | 最短正常路徑、Dispatch 正式入口 |

`ScopePlan` hash 紀錄寫入 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>\scope-plan-hash-<dispatchSlug>.json`，不同線可使用相同 `dispatchSlug`。讀取時若同線路徑不存在，才檢查舊版 history 根目錄的 `scope-plan-hash-<dispatchSlug>.json`；只有舊紀錄的 `line_slug`，或其 `root_run_id` 對應 RunRecord 的所屬線，與目前 `lineSlug` 相同時才沿用。其他線的舊紀錄不阻擋目前派遣，也不會被改寫或刪除。同一線內仍須使用不同 `dispatchSlug` 識別不同派遣。

## 額度與範圍契約

`QuotaSnapshot` 是每次派工的額度紀錄，只供顯示與成本紀錄，不作放行條件。`Get-CodexQuota.ps1 -SnapshotPath <path>` 保留既有 key-value stdout，另外寫入 `ai-sessions.quota-snapshot.v1` JSON。有效快照包含 `captured_at_utc`、`state=Valid`，以及 `primary` 與 `secondary` 的 `used_percent`、`remaining_percent`、`window_minutes`、`resets_at` 與 `source_file`。取得額度失敗時，快照檔仍以失敗的 `state` 與 `error` 寫出，stderr 輸出失敗類別；`Dispatch` 與 `Start` 把 before 快照失敗記為 unknown 後繼續，不在 before-snapshot 階段停止。

`ScopePlan` 是派工前唯一的範圍決策，欄位固定如下。

```text
dispatch_slug
dispatch_kind
task_type
requested_profile
session_mode
primary_remaining_percent
primary_reserve_percent
primary_budget_percent
estimate_percent
estimate_source
unit_kind
requested_units[]
selected_units[]
deferred_units[]
decision
decision_reason
```

`unit_kind` 只允許 `workflow-phase`、`resource-target` 與 `advisor-evidence-question`。Workflow 以 `design.md` 的 Phase 為最小單位，資源派遣以派遣單第 3 欄的目標物件為最小單位，advisor consult 以 evidence pack 內的問題 ID 為最小單位，`requested_units` 依宣告順序排列。`Start` 的 `RequestedUnit` 必須等於這組單位；只列部分目標時，執行端會以範圍不一致拒絕工作。執行端不得自行增加或拆分單位。

`ScopePlan` 一律選取宣告的全部單位：`selected_units` 等於 `requested_units`，`decision=full`，`estimate_source=not-used`，額度高低與 unknown 都不改變範圍。欄位中的額度與估算值只作紀錄。ScopePlan hash 紀錄與續行範圍核對照常執行。

`advisor-consult` 只在使用者授權後啟動，呼叫端以 `AdvisorRequestSource=user-explicit` 傳入；缺少授權時以 `AdvisorAuthorizationRequired` 拒絕並不啟動 Codex。授權後使用 evidence pack 的完整問題集。授權不略過 service rejection、evidence hash、read-only sandbox 與 process identity gate。

### 需求級成本累計

同一成本目標以 `lineSlug` 加需求編號識別，例如 `rule-architecture-rebuild #22`。`dispatchSlug` 與階段只作追溯資訊，換新 `dispatchSlug`、續行或換階段都不讓同一目標的累計值歸零。累計不新增監控服務，只彙整既有的 RunRecord、事件流、failure receipt、額度快照與回收紀錄。

成本紀錄的唯一落點是 `<sourceRoot>\.local\ai-sessions\report\<lineSlug>\cost-ledger.md`，唯一寫入者是該線協調者（功能線為 `Analyst`，bug 線為 `Maintainer`），只追加不改寫。執行端不寫入此檔。

1. 開始：任務開始時追加一列預算，寫明成本目標、預算形式（牆鐘時間或額度百分點）、預算值與到界處置。預算形式為額度百分點時，同列寫明計算視窗（`primary` 或 `secondary`），累計值只計該視窗的 before 與 after 差額；另一視窗的數值照常記錄但不參與到界判定。未寫明視窗的額度預算列視為不完整，協調者補齊後才開始派遣。
2. 累計：每筆派遣結束後追加一列，欄位為時間、成本目標、`dispatchSlug`、階段、事件類型、耗時、before 與 after 額度（取得不到時寫 unknown）與累計值。事件類型取值為啟動失敗、格式補件、續行、回收、跨階段返回。
3. 輪數與成本分開計：`PromptNotDelivered` 等啟動失敗與純格式補件不增加回收輪數（見「回收收斂判定」），但一律計入成本累計值。
4. 重派前比較：協調者在同一成本目標的下一次派遣前，於紀錄寫明本輪閉合了什麼、還差什麼、下一步值得的理由。Reviewer 或顧問額外提出、不屬既有驗收條件的改善只記為候選，不自動列入下一輪必做項。
5. 到界：累計值達到預算時，協調者停止再派，交付已確認結果、未完成單位與建議選項，由使用者決定追加預算或結束。

## InterruptionSafeguard

`InterruptionSafeguard` 套用所有冷啟動與續行。PowerShell 參數保留 `DowngradeInstruction` 作為 alias，alias 只代表相同的中斷保全語意，不代表換檔或低額度降級。輸出同時保留 `interruptionSafeguardApplied` 與 `downgradeInstructionApplied`，兩者固定為相同布林值。中斷保全參數與續行 thread id 可以同時存在，續行仍沿用原始 profile 與父層選項。

每次 `Start` 都將下列原文加入 prompt。

```text
[中斷保全]
本次工作必須可在任意中斷點交付已確認結果。開始主要探索前，先寫出目前已確認的結論、證據位置與尚未確認項目。每完成一個範圍單位，更新一次「已確認結論」與「實際覆蓋範圍」。收到中止要求時，先保存已確認結論、證據位置、未完成單位與不應推論的內容，再結束本次工作。不得以未執行的單位補寫結論。
結案訊息一律以下列三行結尾，中止與正常完成都適用，讓後續續行取得交接資料。每行為單行鍵值對，值不得為空；沒有未完成單位時填「無」。
已確認結論：<一句話>
未完成單位：<清單或「無」>
證據位置：<絕對路徑或檔案:行號>
```

`Start` 同時在 `<executionRoot>\.local\ai-sessions\history\<lineSlug>\interruption-checkpoint-<dispatchSlug>-<runId>.json` 建立初始保全檔，將 `ScopePlan.selected_units` 全列為未完成。每完成一個 selected unit，執行端依 prompt 指示更新檔案，只有具體結論與絕對證據位置齊備的單位可列入 `confirmed_units`；`incomplete_units` 必須是扣除已確認單位後仍未完成的 selected units，且維持原順序。檔案綁定 `lineSlug`、`dispatchSlug`、`run_id` 與 `selected_units`，並記錄 ScopePlan、RunRecord、事件流與保全檔來源位置。

`Inspect` 遇到事件流沒有 `turn.completed` 或 `turn.failed` 時回報 `status=interrupted`、`recoveryState=InterruptedUnknown`，並載入逐單位保全檔；不以事件流中的工具完成事件推論工作單位已完成。`Collect` 也回傳同一份保全資料。保全檔缺失時所有 selected units 保持未完成；識別、範圍或內容驗證失敗時回報 `invalid`，不採用其中的成果。保全檔補充中斷時可回收的逐單位結果，結案訊息仍保留三行中斷保全協定。

Start 另注入識別字指示：最後訊息的最末三行固定為純文字 `requiredIdentifier: <值>`、`dispatchSlug: <值>`、`lineSlug: <值>`，使用半形冒號、值不加標記。中斷保全三行放在識別字三行之前；Inspect 以整段訊息逐行比對這六個欄位，不依行序判定。

續行的前置條件依前輪終止狀態分流。前輪事件流以 `turn.completed` 結束時，`Start` 只要求 last-message 存在且非空；前輪被中止、早夭或終止狀態無法判定時，`Start` 另要求 last-message 具備 `已確認結論`、`未完成單位` 與 `證據位置` 三個單行鍵值對。無條件要求三欄位會使正常完成的派遣無法續行，因為中止路徑才會產生這些欄位。前輪以 `turn.failed` 結束且 last-message 不存在時，改用 RunRecord 的 `interruption_checkpoint_path`，驗證 line、dispatch、run 與 selected units 後交接已確認結論、未完成單位及證據位置；檢查點也不存在或驗證失敗時，以 `ResumeHandoffUnavailable` 拒絕，並列出 last-message 與檢查點兩個檔案路徑。

## Advisor consult resource dispatch

`advisor` 是意見評估角色，不是實作檔位。實作一律使用預設檔位。`Profile=advisor` 只接受 `TaskType=advisor-consult`、`DispatchKind=resource` 與 `WriteMode=readonly`；Workflow、寫入模式或其他 TaskType 在 Codex 啟動前以 `AdvisorImplementationProfileRejected` 拒絕，`TaskType=advisor-consult` 未搭配 `Profile=advisor` 時以 `AdvisorProfileRequired` 拒絕。

`TaskType=advisor-consult` 使用單一 evidence pack，schema 為 `advisor-consult.evidence.v1`，必須包含目標段落原文摘錄與來源位置、已知結論、待答問題、可能反證與邊界。advisor 執行端只可讀取該 evidence pack，不得探索 repository、讀取其他來源、修改檔案或寫入 report。

evidence pack 的內容契約如下，由建立 pack 的主 Agent 負責。

- 來源與版本：每段摘錄的 `source:` 寫完整絕對路徑與行號範圍，並附該檔的版本識別（commit SHA 或檔案 SHA-256）。摘錄來自其他線或其他專案時，另寫明來源所屬的 `lineSlug` 或 work-root，與本次 advisor 派遣的 `line-slug` 區分。
- 待答問題：每題要求可直接執行的建議，於問題或 `output-rules:` 要求回答建議行動、處理位置、主要取捨、驗收方式，以及假設與推翻條件。問題聚焦實質處置，不要求因果分析或歷史回顧。
- 可能反證：寫成可檢查的問題或條件，例如「若 X 成立，建議是否改變」，讓 advisor 能逐條回答，不只列出疑慮。
- 送出前，主 Agent 先寫下自己的判斷，回收後逐項對照顧問意見，同意或不同意都附理由，以「主 Agent 決定、依據、與顧問意見異同」記錄於同線 `exceptions.md`。顧問只提供另一視角，決策由主 Agent 或使用者作出。

同一問題需要追問或補充證據時，沿用原 `dispatchSlug` 的 thread 續談，問題 ID 不變。新增目標、新增來源、新增問題單位或需要不同權限時，建立新的 evidence pack 與新的 `dispatchSlug`；新問題使用新的問題 ID，不併入原派遣的問題集合。advisor 啟動的授權依 `instructions.md` §1.5 advisor consult 掛載點：先向使用者請求，使用者在當下 Session 授權後才派工，授權不延續到其他 Session，也不依額度縮小問題範圍。

advisor 的 worktree `Start` 仍必須提供 `PrepareResultPath`，且該檔案的狀態必須是 `Prepared`。`advisor-consult` 必須提供 `AdvisorConsultReportPath` 與 `QuotaAfterPath`。前者固定位於 `executionRoot\.local\ai-sessions\report\<lineSlug>`，檔名為 `advisor-consult-<dispatchSlug>.md`；後者必須位於 `executionRoot` 內。這兩項路徑都不能改指 `sourceRoot` 的同線 report 或其他來源落點。

evidence pack 必須位於 `executionRoot` 內，並以 `schema: advisor-consult.evidence.v1`、相同的 `line-slug` 與 `dispatch-slug` 開頭。正文固定包含 `目標段落`、`已知結論`、`待答問題`、`可能反證` 與 `邊界` 五個區段。`目標段落` 內必須有非空的 `source:` 與 `excerpt:`；`待答問題` 至少列出一個 `question-<id>:`，並恰好列出一次非空的 `required-output:`；文件另以非空 `output-rules:` 說明回傳規則。`邊界` 內必須各有一行 `- allowed-input:` 與 `- forbidden-action:`，限制 advisor 只讀取該 evidence pack，禁止探索來源、掃描 repository、修改檔案與發動其他派遣。

`## 待答問題` 以穩定 ID 逐行列出問題，格式為 `question-<id>: <問題>`，ID 在同一份 pack 內不可重複，順序即 ScopePlan 單位順序。同一節必須恰有一行 `required-output:`，值以半形分號分隔，每個值符合 `^#{1,6}[ \t]+\S`；說明文字另寫在 `output-rules:` 行。範例如下。

```text
question-001: <第一個評估問題>
question-002: <第二個評估問題>
required-output: ## 中斷保全結論; ## 證據支持; ## 推論; ## 未決問題
output-rules: 每一個問題以 question-<id> 回報完成狀態
```

`required-output` 缺漏、重複、分行、含非 heading 值或混入說明文字時，Start 以 `EvidencePackRequiredOutputInvalid` 停止。Start 的 advisor 必要參數為 `AdvisorConsultReportPath`、`EvidencePackPath`、`QuotaAfterPath` 與 read-only 邊界；缺少必要參數時以 `RequiredParameterMissing` 停止並列出欄位名稱。`ProfileEvidenceUnknown` 只用於 profile 設定檔的 model 或 reasoning effort 證據不可證明，不承接參數缺漏或 evidence 格式錯誤。

request 的 `prepare_artifacts` 必須是 object array。PowerShell 以 `ConvertTo-Json` 序列化單一元素時可能把陣列塌縮成 object，該形狀會被拒絕；即使只有一個 artifact，也要保留陣列形狀。

`Start` 將 evidence pack 全文內嵌 prompt，以 `---BEGIN INLINE EVIDENCE PACK---` 與 `---END INLINE EVIDENCE PACK---` 包夾，並附 `evidence-pack-sha256` 與 `evidence-pack-length`。執行端依內嵌內容作答，不需讀檔；read-only sandbox 下以工具讀檔會被核准政策阻擋，只給路徑的 prompt 會產生沒有技術結論的回覆。Start 產生 prompt 後重讀確認全文、hash 與長度，不符時以 `EvidencePackInlineMismatch` 停止。evidence pack 的 `## 待答問題` 必須有一行 `required-output:`，以分號分隔列出最終訊息必須包含的 Markdown heading。`Inspect` 逐一確認這些 heading 存在且內容非空，任一缺少時 `outputValid=false`、`success=false`，advisor report 另列「Required output gate」小節。

執行端最後訊息在 `## 中斷保全結論` 內列出 `已完成單位：<問題 ID 清單>`。Inspect 只接受 `completed_units` 為 `selected_units` 的子集合，`deferred_units` 不得標記完成；safe point 缺失時報告記為 `completed_units=unknown`，不以 `selected_units` 推論完成，後續由既有執行鏈 anchor 判定續行資格。advisor report 保存 `requested_units`、`selected_units`、`deferred_units`、`completed_units` 與授權來源。

`Start` 只驗證並保存 evidence pack SHA-256，不建立 advisor report。呼叫端必須以 `Get-CodexQuota.ps1` 在 Start 前建立 `QuotaAfterPath` 指向的快照，Start 只驗證該檔格式，另在 `history` 建立本次的 after 快照並記錄其 SHA-256。缺少 `QuotaAfterPath` 或 Codex home 時以非零結束。`Inspect` 或回收步驟依事件流與 last-message 寫入同線 `report/<lineSlug>/advisor-consult-<dispatchSlug>.md`，`AdvisorConsultReportPath` 必須位於同線 `reportLineRoot` 且檔名固定為 `advisor-consult-<dispatchSlug>.md`。報告區分證據支持、推論與未決問題。Start 前後的 SHA-256 不一致或 Inspect 缺少 Start hash 紀錄時拒絕成功判定。

advisor 執行期間的額度觀測只作紀錄。監看迴圈每 250 毫秒檢查 Codex 行程是否結束，預設每 1800 秒更新一次自建的 after 快照，行程結束後再取一次 terminal 快照；兩次更新之間不呼叫 quota API。更新前比對 SHA-256，一致時以暫存檔取代。每次更新在 monitor 紀錄寫入 `quota.snapshot` 事件，含快照狀態、primary／secondary 值與依 ScopePlan 計算的進度。更新失敗、雜湊不一致或 API 錯誤時，狀態記為 unknown 並附 `failure_code` 與 `failure_class`，不停止 Codex 行程。

## Git 前置探針與 worktree 生命週期

所有派遣先呼叫 `scripts\Invoke-CodexDispatch.ps1 -Operation Preflight`。每次派遣必須取得上游傳入且已驗證的 `LineContext`。`lineSlug` 識別同一條 Analyst 線，`dispatchSlug` 識別單次派遣，兩者分屬不同名稱空間。缺少 `LineContext`、識別字不符合 `^[a-z0-9]+(?:-[a-z0-9]+)*$`，或 `line.json` 的 `line-slug` 與傳入值不一致時，腳本以非零結束碼停止，且不建立成功狀態。

| 欄位 | 路徑或用途 |
| --- | --- |
| `sourceRoot` | 使用者指定且已解析的 work-root 絕對路徑 |
| `lineSlug` | Analyst 已登記的語意化線識別 |
| `writeMode` | 派遣單第 6 欄標示「唯讀」時為 `readonly`，其餘為 `write` |
| `sourceLineRoot` | `<sourceRoot>\.local\ai-sessions\handoff\<lineSlug>` |
| `dispatchRoot` | `<sourceRoot>\.local\ai-sessions\worktrees\<dispatchSlug>` 的隔離 worktree 目標絕對路徑 |
| `dispatchLineRoot` | `<executionRoot>\.local\ai-sessions\handoff\<lineSlug>` |
| `sourceReportLineRoot` | `<sourceRoot>\.local\ai-sessions\report\<lineSlug>` |
| `reportLineRoot` | `<executionRoot>\.local\ai-sessions\report\<lineSlug>` |

`Preflight` 先驗證 manifest、目錄界線與同線 PID，再依寫入面判定是否需要 worktree。`write` 模式先執行不修改來源的既有 Git 探針，只有確認目標含 tracked 檔案後才進入 Git 狀態、`baseSha` 與 worktree 流程；需要 worktree 時，Git 探針只有 exit code 為 0 且 stdout 為 `true` 時才採用 `gitOrigin=existing`，其他 Git 錯誤以非零結束碼回報。腳本不會在來源目錄執行 `git init`，也不建立 `.gitignore`、commit 或 marker；需要 worktree 而 sourceRoot 不是 Git repo 時，以 `SourceRootNotGitRepository` 在建立任何產物前停止，請使用者先自行在 sourceRoot 執行 `git init`。不需要 Git 基準的 direct-write 記為 `gitOrigin=not-applicable`。

腳本依寫入面與來源是否為 Git repo 分流 `executionRoot`。`readonly` 在 Git 來源使用隔離 worktree，在非 Git 來源直接以 `sourceRoot` 執行（唯讀 sandbox、不建 worktree、不產生 Git 產物）；`write` 只有在目標路徑包含既有 tracked 檔案時建立 worktree，非 Git 來源一律走 direct-write；只寫 Git ignored 範圍或全新輸出檔案的 `write` 直接使用 `sourceRoot`，輸出 `worktreeCreated=false`。若 `Preflight` 的 `target_path` 指向尚不存在的 dispatch worktree 內路徑，該路徑不會觸發 worktree 建立，`executionRoot` 退回 `sourceRoot`；需要建立 worktree 時，target 必須是 `sourceRoot` 內已存在且可辨識的 tracked 目標。直接寫入路徑仍須通過 sourceRoot 界線驗證。

需要 worktree 時，`Preflight` 先固定 `baseSha`，再從來源取得 tracked patch 與未追蹤檔案清單。Carry-in 套用與複製時排除檔名符合 `.env`、`.env.*`、`*.pfx`、`*.pem`、`*.key`、`secrets.*` 的檔案，並將被排除的相對路徑寫入 `carryInManifest.excludedSecrets`。清單只含路徑，不含檔案內容或雜湊。若 `target_path` 本身符合上述樣式，`Preflight` 以 `PreflightSecretTargetRejected` 列出路徑並停止，不建立 worktree。其餘 carry-in 仍依原流程套用或複製，衝突時停止並保留現況，不覆寫來源檔案。

`dispatchSlug` 限用小寫英數與連字號，同一個 `sourceRoot` 內不得重複。腳本以固定的 `sourceRoot\.local\ai-sessions\worktrees\<dispatchSlug>` 驗證 `dispatchRoot`，目標已存在時視為已被占用並停止，不以其他目錄代替隔離邊界。

腳本成功時輸出 JSON，至少包含 `executionRoot`、`gitOrigin`、`baseSha`、`worktreeCreated`、`carryInManifest`、同線目錄與 `pidCheck`。任何 manifest、PID、Git、worktree、patch、複製或路徑驗證錯誤均輸出具體 stderr 並以非零結束碼結束，不輸出空值、預設值或部分成功狀態。

## Worktree 安全不變量

被強制終止過的 dispatch worktree 不得重用。判別方式、失效後果與重派時的成果轉移程序見「Codex 進程 PID 與並行檢查」節，該節為此不變量的唯一權威敘述。

PID 重用判定以 `work-root`、`line-slug`、`write-mode`、根 PID、根程序名稱、根程序建立時間與完整進程樹為依據。Windows 以 `Win32_Process.ParentProcessId` 查詢根程序及後代，根程序名稱採不分大小寫完全相等，建立時間差距最多 1 秒；Unix 以根程序與記錄的 process group 核對。任一身分欄位不符、PID 被其他程序占用或身分無法驗證時，視為 PID 重用或不可確認，不阻塞派遣，也不得將目前後代視為同一棵樹。中止時只有身分驗證通過的根程序或 process group 才能進入終止流程，避免誤殺無關程序。

唯讀與寫入模式依同線三鍵判定。不同 `lineSlug` 的活躍記錄不互相阻塞；同線的 `write` 與任何其他活躍模式互斥；同線 `readonly` 可並行，但上限為 2。缺少 `write-mode` 的舊 PID 記錄視為 `write`。同線 readonly 已達上限或存在衝突時，`Preflight` 以非零結束碼停止。

主工作樹在 Codex 執行期間維持啟動前的 `HEAD` 與 `git status`。Codex 的工作目錄使用腳本輸出的 `executionRoot`。需求摘要及其 history 備份是跨派遣交接例外，仍寫入 `sourceLineRoot` 與 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>`；需由 Codex 寫入時，啟動參數必須明確授權這兩個線層目錄。

執行端不清理 dispatch worktree 內的 `scratch/`。該目錄隨 worktree 移除一併消失，提前清理會刪掉主 Agent 回收時需要複核的驗證證據。三態尚未結束、需要續 session 或程式碼尚未完成回收時，保留同一個 dispatch worktree。

## Codex 進程 PID 與並行檢查

PID 記錄歸屬來源工作樹的 `history`，格式為 `<sourceRoot>\.local\ai-sessions\history\codex-pid-<yyyyMMdd_HHmmss>.txt`。記錄中的 `pid` 是進程樹根，不代表一定是 Codex leaf process。Windows 以 PowerShell 的 `ProcessStartInfo` 啟動 `(Get-Command codex.cmd).Source` 時，實測 `Process.Id` 為 `35048`，查詢該 PID 的 `ProcessName` 得到 `cmd`，不是 `codex` 或 `node`；實際執行 Codex 的程序是其子進程。因此 Windows 端必須以根 PID 追查整個進程樹。

每次成功啟動 Codex 並取得進程識別碼後，立即建立一份新的 UTF-8 無 BOM 純文字檔，至少包含下列欄位。`pid` 保留作為相容欄位，值與 `root-pid` 相同。

```text
pid=<進程樹根 PID，與 root-pid 相同>
root-pid=<進程樹根 PID>
root-process-name=<根程序名稱，例如 cmd>
root-parent-pid=<根程序的 ParentProcessId>
root-started-at-utc=<ISO 8601 UTC 時間>
identity-verified=true
process-tree-scope=<Windows: pid-and-descendants；Unix: process-group>
process-tree-query=<Windows: Win32_Process.ParentProcessId；Unix: ps PGID 成員>
process-group-id=<Unix process group ID；Windows 不適用>
work-root=<sourceRoot 的絕對路徑>
line-slug=<LineContext 的 lineSlug>
dispatch-slug=<本次派遣的 dispatchSlug>
write-mode=<readonly 或 write>
started-at-utc=<ISO 8601 UTC 時間>
```

派工前掃描同一個 `sourceRoot` 的 `codex-pid-*.txt`。逐檔解析 `work-root`、`line-slug`、`write-mode`、`root-pid`（舊格式回退讀取 `pid`）與進程樹欄位。`work-root` 與目前絕對路徑相同、`line-slug` 與目前 `LineContext.lineSlug` 相同、進程樹或 process group 仍存活，且根程序身分比對通過的記錄，才進入 `write-mode` 判定。缺少 `line-slug` 的舊格式記錄不具備線歸屬，不滿足三鍵比對。

Windows 以 `Win32_Process` 的 `ProcessId`、`ParentProcessId`、`Name` 與 `CreationDate` 查詢根程序及其所有後代，遞迴追查每一層子程序。將查得根程序的 `Name` 與 `CreationDate` 轉為 UTC 後，分別比對 PID 記錄的 `root-process-name` 與 `root-started-at-utc`。名稱採不分大小寫的完全相等比對，建立時間差距容許最多 1 秒，以涵蓋查詢與記錄序列化的時鐘精度差異；兩項必須同時符合。任一項不符或無法查詢時，判定為 PID 重用，該筆記錄不阻塞派工，也不把其目前後代視為同一個 Codex 進程樹。根程序已結束但仍有後代時，只有在根 PID 目前不存在、PID 記錄含有由腳本寫入的 `identity-verified=true`、身分欄位完整且未發現 PID 重用的情況下，才可依 `ParentProcessId` 鏈保留活躍判定。根 PID 已被其他程序占用且身分不符時，依 PID 重用處理。Unix 以 PID 檔的 `process-group-id` 查詢 process group 成員，並以 `root-pid` 查詢根程序，依相同規則比對 `root-process-name`、`root-started-at-utc` 與查得的程序名稱、建立時間。根程序身分比對通過且群組內仍有任何程序存活時，才判定為活躍實例。根程序在身分驗證後結束但群組成員仍存活時，只有 PID 記錄包含由腳本在身分驗證後寫入的 `identity-verified=true`，且 `root-process-name`、`root-started-at-utc` 與有效的 `process-group-id` 都存在時，才沿用已驗證的根程序身分與仍存在的 process group 判定活躍；根 PID 被其他程序占用、身分比對失敗或無法完成身分驗證時，判定為 PID 重用，該筆記錄不阻塞派工。舊格式 PID 記錄若缺少 `root-process-name` 或 `root-started-at-utc`，視為無法確認身分的歷史記錄，不阻塞派工。理由是僅憑 PID、process group 或存活狀態無法排除 PID 重用。歷史進程樹已完全結束時不阻塞派工；發現依 `write-mode` 判定為衝突的同線活躍 Codex 實例時，回報活躍 PID 記錄檔、根 PID 與存活後代或 process group，停止流程。

`write-mode` 判定分三種結果。既有記錄與本次派遣都是 `readonly` 時互不阻塞，理由是唯讀派遣不修改目標物件，各自只寫入派遣單第 7 欄指定的報告檔，沒有共用寫入面。任一方為 `write` 時阻塞。同線同時活躍的 `readonly` 實例上限為 2，已達上限時停止派遣並等待既有實例結束，理由是回收端為單線，超過兩份同線報告會使統籌端的判定塞車。缺少 `write-mode` 的舊格式記錄一律視為 `write`。


Start catch 只會使用同一次啟動時已通過身分驗證的 in-memory snapshot。根程序在驗證後消失時，腳本先查詢同一 process group；仍有成員才沿用該 snapshot 終止，群組已空時直接完成收尾。沒有這份已通過驗證的 snapshot，或 PID 記錄缺少 identity-verified=true 時，不得終止 process group。

**被強制終止過的 dispatch worktree 不得重用（Crucial）**。sandbox helper 在正常結束時才移除自己套用的 ACL；被 `taskkill` 或 session 中止時來不及清理，worktree 根目錄會殘留一條明確（非繼承）的存取控制項目，其 SID 已無對應帳號。之後在該目錄啟動的 Codex 會在套用 sandbox ACL 時失敗，全程無法執行任何命令。以 `icacls <dispatchRoot>` 與來源工作樹比對即可確認：報廢的 worktree 會多出不帶 `(I)` 標記的條目。

重派時建立新的 dispatch worktree，並以 `git -C <舊 dispatchRoot> diff HEAD` 產出的 patch 將既有成果轉移至新 worktree，另以 `git -C <舊 dispatchRoot> ls-files --others --exclude-standard` 取得未追蹤檔案並逐一複製。不要嘗試修改 ACL。新 worktree 沿用同一個 `lineSlug`，`dispatchSlug` 另取未使用的名稱。轉移完成後，只有 `pwsh scripts\Invoke-CodexDispatch.ps1 -Operation Cleanup` 可移除舊 worktree；`Cleanup` 失敗時保留 worktree，不得改用其他方式強制移除。

PID 記錄保留於來源工作樹的 `history`，不因 dispatch worktree 移除或 `scratch` 清理而刪除。PID 檔案是否存在不能單獨作為並行判定依據，必須合併 `work-root`、`line-slug`、`write-mode`、進程身分比對與完整進程樹或 process group 的存活狀態；wrapper 已結束但子進程仍存活時，不得判定為可並行啟動。不同 `lineSlug` 的存活記錄必須可同時存在且不互相阻塞。同一 `lineSlug` 下兩個 `readonly` 記錄同樣必須可同時存在。

## Phase commit 回收與驗證

Codex 端不建立 commit，因此 dispatch worktree 的 `HEAD` 在派工全程維持 `baseSha`，實作成果以未 commit 的工作區變更形式存在。回收的輸入是這份工作區差異，不是 commit 區間。

Workflow Developer 的回收收下與 Phase commit 回收是兩個時點。Developer 回收判定為收下時，主 Agent 先將成果套回來源工作樹，維持未 commit 的工作區變更，不建立 Phase commit，並保留 dispatch worktree。Reviewer 退回時，續行仍使用同一個 dispatch worktree 與 thread。只有在 Reviewer 收下、需求意圖驗收完成、結案報告產出且使用者授權 commit 後，才進入 Phase commit 回收。

`Invoke-CodexDispatch.ps1 -Operation Collect` 依 `Preflight` 的 `worktreeCreated` 分流回收。`true` 時取得 `git diff <baseSha>`、`git diff --cached` 與 `git ls-files --others --exclude-standard`，再合併成完整成果清單。`false` 時不要求 `DispatchRoot` 或 `BaseSha`，改從 Preflight 的 `targetStates` 逐一核對核准輸出檔案，保存非空檔案的長度、最後寫入時間與 SHA-256 證據。direct-write 的結案報告也必須存在且非空。任何必要欄位、檔案證據或報告核對失敗時，腳本以非零結束碼停止，不把空 `baseSha` 當成 Git 基準。

差異取得後依結案報告「Phase 對照」節記載的逐 Phase 檔案清單分組。Phase commit 以 Phase 為單位回收，一個 Phase 一個 commit；`phaseCommits` 依 Phase 順序排列，commit 訊息依 `generate-commit` skill 產生。主 Agent 將各 Phase 的差異依序套用至來源分支並建立對應 commit，保留 Phase 的獨立語意。

「Phase 對照」節缺失時停止回收並依續 session 契約要求補齊。缺少該節時，主 Agent 只能看到一份混合全部 Phase 的差異，無從還原 Phase 邊界。

單一檔案橫跨兩個以上 Phase 時，該檔的差異歸入其最早出現的 Phase，並在回收回報中列出該檔與涉及的全部 Phase。

Phase 回收步驟維持一個 Phase 一個 commit，不以 merge commit 取代 Phase commit，也不在此步驟把全部 Phase squash 成單一 commit。Phase commit 回收完成後，若需要依成果整理歷史，可在 `rewrite-branch` 執行 squash。每筆整理後的 commit 必須通過可用性驗證，並通過 `git-workflow` 第一層零差異 gate。任何 commit 回收衝突都停止處理，保留 dispatch worktree、來源狀態與事件證據，交由後續裁決或續行。

Phase commit 回收完成後，依 `git-workflow` skill 的 `validationMode` 執行重整後驗證，再同步報告與核准交接產物，最後才以 `pwsh scripts\Invoke-CodexDispatch.ps1 -Operation Cleanup` 移除 Workflow Developer dispatch worktree。Architect、Reviewer 與其他資源派遣不產生 Phase commit，直接同步報告與核准交接產物後即可呼叫相同的 `Cleanup` operation。`Cleanup` 失敗時保留 dispatch worktree，不得改用其他方式強制移除。使用者授權 commit 前不得執行 Workflow Developer dispatch worktree 的 `Cleanup`。

## 腳本介面與執行前提

本地 session 需能執行 `git` 與 `codex`。機械流程由 `scripts\Invoke-CodexDispatch.ps1` 統一承接，主 Agent 仍負責 F1 路由、profile 選擇、使用者確認、任務分類、回收三態與升級判定；腳本驗證額度快照、ScopePlan、advisor evidence-only 邊界、thread relay 與安全中止。腳本只接受絕對路徑或可在已驗證根目錄內解析的目標路徑，並以 JSON 輸出結果。

| Operation | 主要參數 | 成功輸出 | 致命失敗 |
| --- | --- | --- | --- |
| `Preflight` | `SourceRoot`、`DispatchRoot`、`LineSlug`、`DispatchSlug`、`WriteMode`、`TargetPath[]` | `executionRoot`、`gitOrigin`、`baseSha`、`worktreeCreated`、`carryInManifest`（含 `excludedSecrets`）、`targetStates`、`targetsOutsideRepository`、同線目錄、`pidCheck` | manifest、PID、Git、根目錄界線、worktree、patch 或檔案複製驗證失敗時 stderr 並 exit code 1 |
| `Prepare` | `SourceRoot`、`ExecutionRoot`、`LineSlug`、`DispatchSlug`、`PrepareArtifacts[]`、`TargetPath[]` | 每個交接檔的來源／目的路徑與 SHA-256、`Prepared` 狀態 | 交接檔缺漏、越界、複製失敗或 hash 不符時 stderr 並 exit code 1 |
| `Start` | Preflight JSON 或 `ExecutionRoot`、`PromptPath`、`Profile`、`TaskType`、before snapshot、`InterruptionSafeguard`（舊參數 alias 為 `DowngradeInstruction`）、ScopePlan、Codex 父層選項；advisor 另需 `AdvisorConsultReportPath`、evidence pack、`QuotaAfterPath` 與 read-only 邊界；`AdvisorRequestSource` 必須為 `user-explicit` | `rootPid`、PID 記錄、事件流、stderr、last-message、thread id relay、before snapshot、ScopePlan、實際參數、有效 profile、中斷保全狀態與 monitor 證據 | 快照、ScopePlan、evidence pack、執行檔、工作目錄、啟動參數或根程序身分驗證失敗時 stderr 並 exit code 1 |
| `Inspect` | `EventStreamPath`、`ProcessExitCode`、stderr、last-message、識別字、`Model`、`TaskType`、ScopePlan、派工前後快照、thread id 路徑 | `completed`、`turn.failed` 原因、最後一則 `agent_message`、`usage`、`secret_exposure_suspected`、`secret_exposure_findings`、`recoverable_artifacts_present`、`recoverable_artifact_files`、`outputValid`、`success`、after snapshot、三層 model evidence、thread relay、advisor report 與 monitor 證據 | JSONL、thread id、必要輸入或證據包 hash 格式錯誤時 stderr 並 exit code 1 |
| `Collect` | `DispatchKind`；worktree 回收使用 `DispatchRoot`、`BaseSha`、`ReportPath[]`，`-ApplyCollectedChanges` 套回核准 target；direct-write 使用 `PreflightResultPath`、`ReportPath[]`；`DispatchKind=workflow` 另必須提供 `RequirementSummaryPath`，可選 `SelectedRequirement`（例如 `#22`）；回收 Reviewer 時另提供選用的 `ReviewerReportPath` | worktree 的 tracked／staged／未追蹤差異（`allFiles` 不含 carry-in；另列 `carryInFiles`、`newFiles`、`rejectedFiles` 與 `unappliedNewFiles`），或 direct-write 的核准輸出檔案證據與報告證據；目錄型 target 至少一個非空檔，逐檔記錄長度、最後寫入時間與 SHA-256；兩者都含依 `DispatchKind` 選用的報告核對結果；提供 `ReviewerReportPath` 時另含 `reviewerFindings`（`valid`、`conclusion`、九個 unique 計數 `previous_closed_count`、`previous_open_count`、`previous_withdrawn_count`、`previous_accepted_count`、`current_new_count`、`current_open_count`、`current_closed_count`、`current_withdrawn_count`、`current_accepted_count`，以及 `duplicate_ids`、`inconsistencies`） | worktree 的差異清單或 direct-write 的核准輸出、檔案證據、報告不一致時 stderr 並 exit code 1；Start 時不存在的核准 target 檔沿用 baseline `exists=false` 做來源 drift 檢查，包含被 gitignore 排除的核准新檔；核准目錄新增且未被 gitignore 排除的子檔（包含 Start 時不存在的核准目錄）以 add 套回並檢查來源 drift；target 外新增檔列入 `unappliedNewFiles` 且不套回；來源路徑出現同名檔或內容 drift 時以 `DispatchSourceDrift` 拒絕套回；缺少 `DispatchKind` 或空 `baseSha` 被當成 Git 基準時同樣停止 |
| `QuotaProbe` | 已驗證的 `SourceRoot`、`ExecutionRoot`、`LineSlug`、`DispatchSlug`、`Profile`、短提示、`InitialQuotaState` 與 `ProbeAttempt` | `finalStatus`、新快照路徑與 SHA-256、`processStarted=false` 與回復紀錄 | 只允許 `PostResetNoSnapshot`、`SnapshotExpired` 與 `ServiceRejected`；`ProbeAttempt > 1`，或重新取得的快照不是 `Valid` 且 `fresh` 時 stderr 並 exit code 1 |
| `Dispatch` | `-RequestPath` 指向 `operation=Dispatch` 的 request 檔；未提供 request 檔時拒絕 | `Preflight`、`Prepare`、`Start` 與 `Inspect` 的階段結果，以及 `status=completed` 或 `failed` 的 dispatch envelope；`background: true` 時回傳 `status=started`，Inspect 以 `-WaitForCompletion` 另行等待；Collect 另行呼叫 | 單位核對失敗時於任何副作用前拒絕；request、Preflight、Prepare、Start 或 Inspect 任一階段失敗時 stderr 並 exit code 1 |
| `Cleanup` | `SourceRoot`、`ExecutionRoot`、`DispatchRoot`、`LineSlug`、`DispatchSlug`、RunRecord、`ReportPath[]`；省略 `EvidencePath[]` 時保存 RunRecord 引用且位於 worktree 的既存證據，明列時只接受該 RunRecord 引用的檔案。`ReportPath[]` 與 `EvidencePath[]` 以 `-RequestPath` 傳入 `operation=Cleanup` 的 JSON 陣列，欄位分別為 `report_path` 與 `evidence_path` | 已完成保存驗證且移除目標 dispatch worktree 的結果，包含 0 位元組證據的長度與 SHA-256；自動保存 report 根目錄的 `dispatch-report-<dispatchSlug>.md` | 保存清單、路徑界線、進程或移除驗證失敗時 stderr 並 exit code 1；首次盤點後於移除前再次核對 report 根目錄；新增且未列入保存清單的檔案以 `preservation-failed` 拒絕並列出路徑，且保留 dispatch worktree；未引用的 EvidencePath 錯誤列出可接受清單；失敗時保留 dispatch worktree，不得使用其他方式強制移除 |
| `DiagnoseModelEnvironment` | `ThreadId`、`StartedAtUtc`；`Profile`（預設 `default`）、`CodexHome` 選填 | profile 設定值、actual model／reasoning effort 與 rollout 路徑的 JSON；證據不足時 actual 為 `unknown` | 缺少 `ThreadId` 或 `StartedAtUtc` 時 exit code 1。只由使用者或維運者明確呼叫，Dispatch、Start、Inspect 不呼叫 |

`Preflight` 的 `writeMode=readonly` 在 Git 來源建立隔離 worktree，在非 Git 來源直接以 `sourceRoot` 執行。`writeMode=write` 只有 tracked 目標需要 worktree；ignored 或全新輸出直接回傳 `executionRoot=sourceRoot`、`worktreeCreated=false`、空 `baseSha` 與核准輸出清單。建立 worktree 時先固定 `baseSha`，再套用 tracked patch 與複製未追蹤檔案。腳本遇到衝突會停止，不以空清單或來源覆寫表示成功。`Collect` 必須消費同一份 Preflight 輸出，依 `worktreeCreated` 選擇 Git 差異或 direct-write 檔案證據路徑。

`readonly` 且建立 worktree 時，`Preflight` 檢查每個 `target_path` 是否位於 dispatch worktree repository 內且未被 gitignore 排除。範圍外路徑列入 `targetsOutsideRepository`；`Start` 將清單寫入 prompt，要求執行端直接讀取這些路徑，不經 Git 狀態盤點。對未被忽略的目錄 target，`Preflight` 逐檔檢查來源目錄中的子檔，個別被 gitignore 排除的檔案也逐一列入清單；遞迴盤點會略過 ReparsePoint。

`targetStates` 記錄每個 target 的類型。已存在的路徑依實際類型記錄；新 Preflight 的缺席路徑依輸入結尾的 `\` 或 `/` 判定為目錄或精確檔案。舊版 Preflight 結果缺少 `TargetKind` 時，若 `Exists=true`，`Collect` 依 source 與 dispatch 路徑的實際狀態推斷並標示 `kind_source=inferred`；若 `Exists=false`，固定視為精確檔案，不依輸入分隔符號推斷目錄。`Collect` 發現派遣端類型與記錄類型不一致時，以 `CollectTargetKindChanged` 拒絕，包含 file 變成 directory 或 directory 變成 file；類型一致的目錄 target 維持子檔套回行為。

`Start` 會固定 `--cd`、`--sandbox`、`--profile`、`--add-dir`、`--search` 等父層選項的位置，再執行 `codex exec` 或同一 thread 的 `codex exec resume`。`--json`、`--output-last-message` 與 prompt 選項位於子命令之後。事件流、stderr、last-message、thread id 與 PID 記錄各自保存，啟動結果包含實際參數，供後續複核。

`Start` 每次都加入 `InterruptionSafeguard` prompt。收到 `Profile=advisor` 時先執行 advisor profile 與 TaskType gate，再確認 `AdvisorRequestSource=user-explicit`；`TaskType=advisor-consult` 使用 evidence pack 與完整問題單位。中斷保全不改變 profile，也不作為換檔出口。

`Inspect` 逐行解析 JSONL。空白行略過。非空行若無法解析為 JSON，或缺少有效的非空字串 type，Inspect 以非零結束碼拒絕成功結果；原始事件流保留在原始事件流來源檔，壞行只留在原始事件流，不複製到 stdout、stderr、結果 JSON、診斷物件或報告。結果的 error 與 failure 只含固定錯誤碼、事件流絕對路徑與行號；不輸出解析器訊息、來源片段或原始例外，也不以壞行後的事件繼續計算成功結果。

`Inspect` 保存事件流、usage、三層 model evidence（不主動探測 actual）、thread relay、advisor report 與 monitor 證據。額度 before／after snapshot 若存在則保存其實際值；snapshot 缺失或不完整時保留可取得的其他證據，`Inspect` 的成功判定不受額度快照影響。

事件流以 `turn.failed` 結束且結案報告不存在時，`Inspect` 與 `Collect` 另回報 `recoverable_artifacts_present` 與 `recoverable_artifact_files`。檔案清單列出 worktree 相對 `baseSha` 的變更檔。這些欄位供主 Agent 判斷是否以新 `dispatchSlug` 冷啟動接續，不改變原有成功判定；`turn.failed` 仍是失敗結果。

Reviewer 回收時，主 Agent 以 `Collect -ReviewerReportPath` 驗證報告的 `## Finding manifest`（schema `codex-dispatch.review-findings.v2`，規則見 `reviewer.toml`）。`reviewerFindings.valid=false` 表示報告自相矛盾或格式無法核對，`outputValid=false` 並以非零結束，依回收三態退回 Reviewer 補正；`valid=true` 且 `conclusion=fail` 表示報告有效但仍有 Critical 或 Major finding，依共同收斂契約退回 Developer 修正。兩種情況分開處理，不以 finding 數量推導結論。

v2 manifest 以 `previous_status` 記錄前輪結束時的狀態快照，以 `current_judgment` 記錄本輪對每個 finding 的判定，`counts` 含九個欄位且只供等值驗證（舊報告缺少兩個 `accepted` 欄位時以 0 驗證），`evidence` 路徑必須是絕對路徑，且同一 ID 在 manifest 與正文「本輪 finding 判定」段落的證據位置必須相同。

Reviewer manifest 的 `evidence.path` 只接受位於 SourceRoot 或 ExecutionRoot 內的路徑；UNC、範圍外絕對路徑，以及任一層為指向範圍外的 reparse point（junction、symlink）的路徑一律拒絕且不讀檔。Collect 計算 evidence 雜湊採有大小上限的串流讀取，超過上限記為 oversize 並拒絕，不整份載入。

`accepted`（已接受殘餘風險）不列入 `current_findings`、不使 `conclusion=fail`，必須附 `acceptance` 物件（`decided_by`、`scope`、`evidence`、`reopen_condition`）；Collect 的同線 finding 狀態帳保存該物件，重新開啟時沿用。裁決來源與標記規則見 `reviewer.toml`。

Workflow Collect 將 Preflight `carryInManifest` 記錄的開工前未追蹤檔列為 `carryInFiles`，不套用也不覆寫來源內容；worktree 改動了 carry-in 檔時列入 `rejectedFiles`（`reason=carry-in-protected`），來源端在派遣期間變更或刪除時同樣拒收（`reason=source-drift`）。派遣期間新增的未追蹤檔列在 `newFiles`。提供 `SelectedRequirement` 時（可為單一編號，或逗號分隔、Request 中以 JSON 陣列表示的多個編號，例如 `#4,#5,#7`），結案報告的需求對照只列全部選定需求，表格後緊接 `範圍外（本輪不要求交付）：#…` 一行（沒有範圍外編號時寫 `範圍外（本輪不要求交付）：無`），多份報告時每份各自遵守，Collect 核對兩者聯集等於需求摘要全部編號且不重複，結果見 `requirementMap.selectedRequirement` 與 `requirementMap.outOfScopeRequirementIds`；未提供時維持要求全部編號。

Collect 回收 Reviewer 報告有兩種模式，輸出的 `collect_mode` 標示採用哪一種。

| 模式 | 觸發條件 | 行為 |
| --- | --- | --- |
| `structural-only` | 只提供 `Collect -ReviewerReportPath <path>`，不帶 `ReportPath` 與 `DispatchKind` 等回收參數 | 只驗證報告格式與 manifest 一致性並回傳 `reviewerFindings`，不寫入狀態帳，不視為回收完成。Reviewer 依 `reviewer.toml` 自我檢查報告時落在此模式 |
| `full` | request 與 RunRecord 皆提供 | 執行完整身分驗證，涵蓋 request、Preflight、RunRecord、報告路徑、執行鏈 anchor 與執行端最終訊息，全部通過才寫入狀態帳 |

主 Agent 回收 Reviewer 結果時使用 `full` 模式；`structural-only` 的結果不得作為閉合判定的依據。`full` 模式依 `current_judgment` 中 `status=closed` 的 unique ID 計算本輪閉合數，並寫入同線 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>\review-finding-ledger.json`，以 `finding_id` 加 `round` 為唯一鍵保存每個 finding 的跨輪狀態。判斷某個 finding 目前是否閉合時，讀狀態帳或最新一輪的 `current_judgment`，不讀 `previous_status`。v1 報告的 `previous_status` 依 v1 條文承載本輪判定，Collect 以 manifest 與正文「前輪 finding 狀態」節一致為前提讀取，兩者不一致時拒絕回收。

Start、Inspect、RunRecord 的 model 與 reasoning effort 分為三層證據，契約為 `codex-dispatch.model-evidence.v1`：

| 層 | 來源 | unknown 條件 |
| --- | --- | --- |
| `requested` | 呼叫端明確傳入的 `-Model`、`-ReasoningEffort`，只作為 assertion | 未傳入 |
| `resolved` | 實際 profile 設定檔的 top-level `model`、`model_reasoning_effort`；預設檔位讀 `<CodexHome>\default.config.toml`，`advisor` 讀 `<CodexHome>\advisor.config.toml` | 檔案不存在、欄位缺少、格式錯誤或重複衝突 |
| `runtime_verifiable` | 公開可查的 actual evidence。Dispatch、Start 與 Inspect 不主動探測 rollout | 沒有公開可查證據時為 `status=unknown`、`source=public-actual-unavailable`，不複製 requested 或 resolved 值 |

明確 assertion 與 resolved 值衝突時，Start 在啟動前以 `RequestedResolutionMismatch` 停止。Inspect 不修改 RunRecord 的 model evidence，也不回傳 rollout 路徑；actual 為 unknown 不使 Inspect 以非零結束。CLI 缺失或正式啟動失敗時，RunRecord 記 `launch_state=launch-failed`、`started_at_utc=null`，Dispatch 結果為 `status=failed`、`failed_stage=start`、`process_started=false`，`completed_stages` 不含 start。

需要確認實際使用的 model 與 reasoning effort 時，由使用者或維運者明確執行診斷 operation，派工流程不呼叫它：

```powershell
pwsh -NoProfile -File .\scripts\Invoke-CodexDispatch.ps1 -Operation DiagnoseModelEnvironment `
  -Profile default -CodexHome <CodexHome> -ThreadId <thread-id> -StartedAtUtc <UTC-ISO-8601>
```

`ThreadId` 與 `StartedAtUtc` 必填，`CodexHome` 省略時依 `CODEX_HOME` 或使用者的 `.codex` 目錄解析。輸出 JSON 含 `profile_model`、`profile_reasoning_effort`、`actual_model`、`actual_reasoning_effort` 與 `rollout_paths`；找不到精確對應的 session 或時間證據不足時，actual 的 `status` 為 `unknown`，不以 profile 設定值代填。

派工腳本的回歸測試以 `scripts\tests\Test-DispatchRecoveryBinding.ps1 -Phase <1-9>` 單一入口執行，入口會依序在 Windows PowerShell 5.1 與 pwsh 7 執行並彙整結果，任一環境失敗即整體 exit 1。Phase 9 可選附加 `-SkipPhase9Diagnostic`；主組失敗時跳過診斷重跑並標示 `diagnostic_skipped=true`，省略參數時維持既有診斷行為。回收覆核時執行此入口，不需另外分別呼叫兩個執行環境。

`Collect` 在 worktree 路徑合併 `git diff <baseSha>`、`git diff --cached` 與 `git ls-files --others --exclude-standard` 的檔案清單。報告核對方式依 `DispatchKind` 分流：`workflow` 以結案報告「Phase 對照」節逐項比對檔案清單，並以「需求對照」節比對 `RequirementSummaryPath` 的需求項目編號，`resource` 只確認報告存在且非空並回傳其長度與 SHA-256。「需求對照」核對要求需求摘要同時具備 `## 程式面項目` 與 `## 功能面項目` 兩節，兩節表格的 `#` 編號合併後不得重複，且每個編號在結案報告「需求對照」表格恰有一列 `#<n>`；表格固定 6 欄（需求、驗收方向、T-code、實際行為、證據、狀態），以未跳脫的 `|` 切欄，每欄非空，狀態為四個合法值之一。缺節、摘要編號重複、缺列、重複列、多出摘要沒有的編號、欄數不符或欄位為空時，以非零結束碼停止並列出不符的編號。此核對只驗結構完整，不判定內容是否正確，內容一致性由 Reviewer 的需求對照核對負責。resource 的結案要求是逐條驗收，不逐 Phase 列出檔案清單，對它要求「Phase 對照」節會使每次資源派遣都無法回收。direct-write 路徑則讀取 Preflight 的 `targetStates`，確認每個核准輸出都存在、為非空檔案，並回傳檔案長度、最後寫入時間與 SHA-256。任一數量、路徑、檔案證據或報告不一致都停止回收，且在成果尚未完成回收前不得移除 worktree。

交接物同步由獨立的 `Prepare` operation 執行（`ai-sessions.prepare.v1`）：只複製請求中明確列出、位於同線來源與允許目的根目錄內的檔案，逐一比對來源與目的 SHA-256，全部一致才標記 `Prepared`，任一缺件、越界或 hash 不符時標記 `PrepareFailed`。`Preflight` 不複製交接物，交接物只經由 Prepare 進入 worktree；建立 worktree 時的 tracked patch 與未追蹤檔案 carry-in 是工作區內容的同步，仍由 Preflight 執行，不屬於交接物複製。worktree 模式的 Start 必須收到 `Prepared` 結果，缺少或不一致時以 `PrepareRequired`／`PrepareArtifactMismatch` 停止；direct-write 使用 `status=not-required`。Start 一律建立本次 before snapshot 並綁定到 RunRecord，呼叫端提供的 `QuotaBeforePath` 只驗證格式；CodexHome 依序取顯式參數、`CODEX_HOME`、使用者目錄下的 `.codex`，實際值寫入 Prepare 結果、Start 輸出與 RunRecord。

跨程序傳入陣列參數（`TargetPath`、`AddDirectory`、`CodexParentOption`）時，以 `-RequestPath` 傳入 `ai-sessions.dispatch-request.v1` JSON 檔，陣列元素的原文與順序即契約，逗號、空白、中文與 `$` 不經 shell 展開或重新切分。Start 續行需要提供這些陣列時，也將 `target_path`、`add_directory` 與 `codex_parent_option` 寫成 JSON array，透過 `-RequestPath` 傳入 `operation=Start` 的 request；不得以逗號字串替代。`Cleanup` 的 `report_path` 與 `evidence_path` 同樣是陣列，須放在 `operation=Cleanup` 的 request 檔中。`powershell.exe -File` 無法以命令列傳遞字串陣列，逗號串接會被視為單一字串，跨 PowerShell 執行環境呼叫時一律使用 request 檔。request 檔與命令列同一欄位不一致時以 `DispatchRequestMismatch` 停止。

額度快照保存 `observations`（兩個視窗最後一次實際觀測的 used／remaining、觀測時間、來源、freshness 與 resets_at）與 `service_rejection`。usage-limit 事件記為 `service_rejection`（`status=quota-rejected`、`retry_allowed=false`），不改寫最後觀測值；過期快照保留觀測值並標示 freshness，不宣稱為即時額度。收到明確額度拒絕時，執行端保存已確認成果、證據位置與未完成單位，執行狀態記為失敗，不自動重試，等待重設或新的觀測證據。

### 額度狀態與回復探針

`Get-CodexQuota.ps1` 每次呼叫都向即時額度來源取得一份新觀測，快照 `state` 只會是下列三種之一。

| 狀態 | 判定條件 | 處置 |
| --- | --- | --- |
| `Valid` | 回應含 `primary` 與 `secondary` 兩個視窗且欄位合法，沒有拒絕旗標 | 記錄額度供顯示與成本紀錄 |
| `ServiceRejected` | 回應帶有額度拒絕旗標，或顯示已達上限但缺少 `rate_limit_reached_type`（此時 reached type 記為 unknown） | 不自動重試，等待重設或新的觀測證據 |
| `SnapshotUnavailable` | 認證資料缺漏、連線失敗、逾時、HTTP 非 2xx、回應格式或數值範圍不合法 | 以非零結束碼停止，stderr 保留失敗類別，不產生估算值 |

observation 的 `freshness` 在寫入快照時依觀測時間距今判定，30 分鐘內為 `fresh`，超過為 `stale`，派工腳本讀取時沿用寫入值，不重新計算。即時來源寫出的快照一律為 `fresh`；`stale` 只出現在其他來源寫出的舊快照文件，此時照常派工、不改變範圍，需要最新數值時重新取得一次快照。

`QuotaProbe` 是額度狀態的一次性回復入口，`ProbeAttempt` 上限為 1，`InitialQuotaState` 只接受 `PostResetNoSnapshot`、`SnapshotExpired` 與 `ServiceRejected`。前兩者由呼叫端依既有快照判定，`QuotaProbe` 只以新檔重新取得即時快照；`state=Valid` 且 `freshness=fresh` 時回傳 `finalStatus=quota-source-refreshed-no-probe`，不掃描 rollout、不啟動 Codex。即時刷新失敗時以非零結束碼停止，不使用其他快照來源。`ServiceRejected` 寫入 `finalStatus=service-rejected-no-retry`，不啟動 Codex 也不重試。

回復紀錄寫入 `.local\ai-sessions\history\<lineSlug>\quota-recovery-<dispatchSlug>.json`，保留初始狀態、觸發視窗、嘗試次數、新快照路徑與 SHA-256、重試結果與最終狀態。回復紀錄是派工證據，不是額度快照來源，不得讀回當作額度估算。`QuotaProbe` 成功後，呼叫端以回傳的 `quotaSnapshotPath` 或重新取得的快照作為額度紀錄。

### 執行可用性

`Invoke-CodexDispatch.ps1` 解析 `git` 與 `codex` 的實體路徑，並在 `Start` 輸出實際的父層與子命令參數。執行檔、工作目錄或參數探針失敗時，腳本保留 stderr 與事件證據並以非零結束碼回報。

| Session 型態 | 派工能力 | 處置 |
| --- | --- | --- |
| Desktop Code tab、VS Code 擴充、CLI、SSH 或 WSL 的 local session | 可發動 | 依本 Skill 的指令契約執行 |
| Dispatch 對話本身或 cloud session | 不可發動 | 明確回報「當前 session 不載入全域規則，請於 local Code session 發動」，不嘗試執行 `codex` |
| Dispatch 派生的 local Code session | 可發動 | 依本 Skill 的指令契約執行 |

派工命令執行前由主 Agent 準備 `sourceLineRoot`、`<sourceRoot>\.local\ai-sessions\history\<lineSlug>`、`sourceReportLineRoot`、`dispatchLineRoot`、`reportLineRoot`，以及 `executionRoot\.local\ai-sessions\history` 與 `scratch`。來源 `sourceLineRoot\requirement-summary.md` 與同線來源 `history` 的覆寫備份保存跨派遣交接；事件流、stderr、thread id 與 PID 記錄維持在既有的 `history` 根目錄；固定報告與例外紀錄落在 `reportLineRoot`。資源派遣若需更新來源需求摘要或其 history 備份，啟動命令必須以 `--add-dir` 授權這兩個來源線層目錄。報告檔與 `<work-root>/.local/ai-sessions/report/<lineSlug>/exceptions.md` 依派遣契約的明文寫入例外處理。若主 Agent 無法完成前置作業，停止啟動並回報缺件。所有輸出父目錄必須在啟動前完成建立。

## 指令契約

正式啟動與續行都由 `Invoke-CodexDispatch.ps1 -Operation Start` 執行。`sourceRoot`、`executionRoot`、`dispatchSlug`、`lineSlug` 與輸出檔案路徑使用絕對路徑。腳本保存 `codex exec` 或 `codex exec resume` 的實際參數，並以 `-` 從 prompt 檔案傳遞完整內容。

`--cd`、`--sandbox`、`--add-dir`、`--search` 與 `--profile` 是 `codex` 的父層選項，必須放在 `exec` 或 `exec resume` 之前。`--json`、`--output-last-message` 與 `--output-schema` 是子命令選項，必須放在子命令之後。`--search` 只有在需求明確需要網路查證時才加入；`--add-dir` 只有在需求明確需要 worktree 外寫入時才加入，並列出絕對路徑。

### 事件流形狀

`--json` 將 JSONL 事件輸出至 stdout。每則事件是扁平 JSON 物件，以 `type` 欄位分類，不使用 JSON-RPC 封裝，也沒有 request id 與 response 關聯。實測 codex-cli 0.153.4 的最小事件序列如下。

```text
{"type":"thread.started","thread_id":"<uuid>"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"<內容>"}}
{"type":"turn.completed","usage":{"input_tokens":0,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}
```

| 事件 | 用途 |
| --- | --- |
| `thread.started` | `thread_id` 是續行識別，寫入 `executionRoot\.local\ai-sessions\history\codex-thread-<dispatchSlug>.txt` |
| `item.completed` 且 `item.type` 為 `agent_message` | 最後一則的 `text` 是結案訊息 |
| `item.completed` 且 `item.type` 為 `command_execution` | 累計次數反映實際讀取與執行量，可用於判斷派遣是否確實走完目標物件 |
| `turn.completed` | 唯一的正常完成證據，其 `usage` 提供本次實際 token 用量 |
| `error` | 伺服器端錯誤，`message` 通常緊接在 `turn.failed` 之前；Inspect 輸出前依機密鍵規則遮蔽 |
| `turn.failed` | 明確的失敗終止，`error.message` 是原因，例如額度耗盡或模型不被接受；Inspect 以遮蔽前的原文判定 service rejection 分類，結果的 `turnFailedReason` 與 `diagnosis.error` 只保留遮蔽後的訊息 |

`turn.failed` 與 `error` 只出現在事件流，不寫入 stderr。派遣失敗時 stderr 可能完全為空，因此失敗原因一律從事件流末尾取得，不以 stderr 是否有內容判斷是否失敗。Inspect 由事件訊息衍生的輸出一律經遮蔽，解析或掃描失敗時只輸出固定錯誤碼、事件流路徑與行號。

stdout 只包含事件流 JSONL，診斷訊息一律走 stderr，兩者分別重導至不同檔案。

### 跨平台啟動

`Start` 由腳本建立固定的工作目錄、父層選項、子命令選項與 prompt stdin。Windows 以進程樹根 PID 啟動並保存 `Win32_Process` 的名稱、父 PID 與建立時間；Unix 以 `setsid` 建立 process group，並由同一份快照驗證 PID、parent PID、process group、程序名稱與建立時間後，才產生 `IdentityStatus=confirmed` 與 `IdentityVerified=true`。任一欄位缺漏、格式錯誤或建立時間無法取得時，快照維持未確認狀態，腳本以非零結束碼失敗，保留已寫入的 stderr 與事件路徑。

啟動參數位置、prompt 傳遞與 PID 記錄欄位由腳本固定產生。這些輸出是後續 `Inspect`、續 session 與安全中止的輸入，主 Agent 不重新拼接命令列或以單一 PID 推論整棵進程樹。

Codex 已啟動但在根程序快照完成前早夭，或身分查詢拋出例外時，失敗路徑必須先保存已收集的 stderr，再回報 `eventStreamPath`、`errorStreamPath`、process exit code 與其他證據路徑，最後使用已持有的 process handle 或已驗證的 process group 收尾。不能以「查不到根 PID」取代原始啟動錯誤，也不能在身分無法確認時終止現有記錄所指向的程序。

### Prompt 必備元素

Prompt 必須明列已驗證的 `LineContext`，格式如下：

```text
lineSlug=<lineSlug>
sourceLineRoot=<sourceRoot>\.local\ai-sessions\handoff\<lineSlug>
dispatchLineRoot=<executionRoot>\.local\ai-sessions\handoff\<lineSlug>
reportLineRoot=<executionRoot>\.local\ai-sessions\report\<lineSlug>
```

`executionRoot` 取自 `Preflight` 的輸出，不由 Agent 自行推導。`worktreeCreated=false` 的直接寫入派遣沒有 dispatch worktree，此時 `executionRoot` 等於 `sourceRoot`，`dispatchLineRoot` 與 `reportLineRoot` 隨之落在來源工作樹。以 `dispatchRoot` 組出的路徑在該情境會指向不存在的位置。

Prompt 至少包含下列元素，缺一即視為契約未滿足。

1. 執行角色的觸發詞或 skill 名稱。Workflow 派工使用 `Developer` 的觸發詞；資源派遣使用派遣單第 2 欄指定的角色或 skill。
2. Workflow 派工使用 `dispatchLineRoot\design.md` 的絕對路徑，資源派遣使用派遣單的絕對路徑。
3. `LineContext` 的 `lineSlug`、`sourceLineRoot`、`dispatchLineRoot`、`reportLineRoot`、`sourceRoot`、`dispatchRoot` 與相關產出落點的絕對路徑。
4. 回報格式、產出落點與驗收條件。Workflow 派工另須要求結案報告包含輪起點 SHA、開工基準線、「Phase 對照」節、「需求對照」節與「判定為既有實作而未動工」節，並列出 `sourceLineRoot\requirement-summary.md` 的絕對路徑供 Developer 產出「需求對照」節。「Phase 對照」節逐 Phase 列出該 Phase 實際修改的檔案清單，供主 Agent 依 Phase 分組建立 commit。續 session 必須重述前輪「Phase 對照」與「判定為既有實作而未動工」兩節的全部條目。

需要以結構約束結案報告時，另建立 JSON Schema 檔並加入 `--output-schema <FILE>`。該選項只約束最終回應的形狀，不改變事件流格式。

## 模型檔位規則

本 Skill 只使用預設檔位與 `advisor`。實作、審查、掃描與命令執行一律使用預設檔位；`advisor` 只作意見評估。預設檔位的實際 model、effort 與其餘設定以 `~/.codex/default.config.toml` 為準，兩份 profile 設定檔均可保留 `[agents]` 區段，規則層只傳遞語意檔位名稱。

`codex exec` 與 `codex exec resume` 屬 runtime command，接受 `--profile`。檔位以 `--profile <檔位名稱>` 傳遞，放在 `exec` 子命令之前。預設檔位一律傳入 `--profile default`，讀取 `~/.codex/default.config.toml`。

派工不在每次啟動前執行探針。正式啟動本身就是參數與檔位的驗證：啟動參數不合法、檔位設定缺漏或 CLI 缺失時，Start 以未啟動結果回報（`launch_state=launch-failed`、`process_started=false`），不產生已啟動紀錄，修正後以新的 `dispatchSlug` 重派。

探針只用於下列明確診斷情境，由使用者或維運者主動執行，不掛回 Dispatch 前置流程。

| 探針 | 使用時機 | 證明範圍 |
| --- | --- | --- |
| 版本檢查（`codex --version`） | 安裝或更換環境時 | CLI 可執行，不證明啟動參數合法 |
| 機制探針 | 修改派工腳本或流程後 | 路徑、prompt 傳遞與事件流解析可運作 |
| `DiagnoseModelEnvironment` | 需要確認實際使用的 model 與 reasoning effort 時 | profile 設定值與 rollout 中的 actual 證據 |

`--help` 在參數驗證前短路輸出，不具參數證明力。低成本檔位的名稱與內容由使用者提供，規則層不預設其存在。

`advisor` 適用於推理密集且判斷資料可事先整理成 evidence pack 的意見評估，例如方案取捨、結案或續優化判斷與設計疑點評估。實作、例行編輯、步驟完整的任務、單一命令驗證、大量讀寫或掃描一律使用預設檔位，不以 `advisor` 執行。

`advisor` 相對預設檔位的實際差異由兩份設定檔的差集決定，不由本文件斷言。說明諮詢價值前，先讀取 `~/.codex/advisor.config.toml` 與 `~/.codex/default.config.toml`，比對兩者的 `model`、`model_reasoning_effort` 與其餘鍵。

### advisor 的前置準備

預設檔位的成本與推理特性由 `default.config.toml` 的 model 與 effort 決定。`advisor` 的實測成本基準為一小時即可用完整個 `primary` 5 小時視窗。這項數據只用來估計諮詢規模。

降低成本的方式是減少執行端自行探索的讀取量，不是縮小任務範圍。檔位本身的成本特性由本機檔位設定決定，設定方式見 README 的 Codex profile 檔位設定章節。

派工前完成下列準備。準備不足時 `advisor` 會把額度花在自行摸索，而不是產出結論。

- 派遣單第 3 欄逐一列出目標物件的絕對路徑，不使用目錄萬用字元，避免執行端自行決定讀取範圍。
- prompt 明列已知結論、已讀過的檔案與不需重讀的部分，讓執行端直接進入判斷。
- 需要限制讀取量時，在 prompt 明文要求單一 agent 執行並說明理由。執行端派生 subagent 時每個 subagent 各自消耗額度，讀取量隨並行數累加。
- 每次派工都注入中斷保全指示，要求先寫出已確認的結果並註明實際覆蓋範圍，於安全點保存結論與證據。服務端因額度拒絕而中止時，已保存的部分成果仍可交付。

續行必須沿用初始啟動的完整父層選項，包含 `--profile`，跨檔位續行不成立。所有續行仍注入中斷保全指示，並沿用同一份 `ScopePlan` 與保全狀態。

### 額度快照

`~/.ai-agents/scripts/Get-CodexQuota.ps1` 以 Codex home 的 `auth.json` 取得認證標頭，向 `https://chatgpt.com/backend-api/wham/usage` 取得即時額度，這是額度快照的唯一來源。回應必須同時含 `primary` 與 `secondary` 視窗，每個視窗換算為 `used_percent`、`remaining_percent`（`100 - used_percent`）、`window_minutes`、`window_days`（`window_minutes / 1440`）與 `resets_at`（Unix timestamp，秒）。`source_file` 記錄端點與請求時間，不是本機檔案路徑。不得讀取或輸出 `auth.json` 的任何欄位值；認證資料缺漏或格式錯誤時，腳本只回報欄位名稱與檔案路徑。

快照檔一律以新檔寫入。`Get-CodexQuota.ps1 -SnapshotPath` 以排他建立開檔，目標已存在時以 `QuotaSnapshotTargetAlreadyExists` 停止且不覆寫。派工腳本以 `New-QuotaSnapshotPath` 在 `history` 產生 `quota-before-*`、`quota-after-*` 或 `quota-source-refresh-<dispatchSlug>-*` 唯一檔名。呼叫端提供的 `QuotaBeforePath` 與 `QuotaAfterPath` 只驗證格式，不寫入；Start 另建本次的 before 快照並綁定到 RunRecord，advisor 另建本次的 after 快照。`Dispatch` 建立的 before 快照經 stage binding 交給 Start 沿用，不重複取得。

快照只代表取得當下的用量。兩個視窗由所有檔位共用，不依模型分別計量。`advisor` 單次派遣可能在數十分鐘內耗盡整個 `primary` 視窗，所以 advisor 執行期間定期取 after 快照作紀錄。快照不論 `state` 為何都不改變派工範圍，也不停止派工。

兩個視窗都是固定視窗，`used_percent` 在視窗內單調累積，跨過 `resets_at` 後歸零並跳至下一格，額度不連續回補。`primary` 為 5 小時視窗，`secondary` 為 7 天視窗，容量相差約 33 倍，因此同一件任務在 `primary` 消耗的百分點約為 `secondary` 的 30 倍。

腳本成功時依序輸出下列兩組 key-value。主 Agent 以同一次讀取的 `primary_remaining_percent` 與 `secondary_remaining_percent` 向使用者呈現額度，例如附在 advisor 授權請求中。

```text
primary_used_percent=
primary_remaining_percent=
primary_days_to_reset=
primary_window_minutes=
primary_window_days=
primary_resets_at=
primary_resets_at_local=
primary_source_file=
secondary_used_percent=
secondary_remaining_percent=
secondary_days_to_reset=
secondary_window_minutes=
secondary_window_days=
secondary_resets_at=
secondary_resets_at_local=
secondary_source_file=
```

### 檔位選擇與額度查詢時點

`Inspect` 預設唯讀，不寫入額度或成本以外的推薦訊號。

1. 主 Agent 先判斷工作是否屬意見評估，且判斷資料可整理成 evidence pack。實作與執行類工作一律使用預設檔位。
2. 屬意見評估時，主 Agent 先向使用者提出 advisor 授權請求；使用者同意後以 `AdvisorRequestSource=user-explicit` 派工。使用者在當下 Session 已明確授權「送顧問不必詢問」時，同一 Session 內直接以 `user-explicit` 派工，該授權不延續到其他 Session。
3. 額度只供顯示與紀錄，查詢時點為派工前、advisor 前、長時間派工執行中約每 30 分鐘、結案時與按需查詢。查詢失敗記為 unknown，派工照常進行。
4. 所有出口都注入 `InterruptionSafeguard`，保留已確認結論、證據位置、未完成單位與不可推論內容。續行沿用原始 thread、父層選項與 ScopePlan。
5. 以 `advisor` 派工而 `advisor.config.toml` 不存在時，停止該次派工，不使用隱式 profile fallback。
6. 預設檔位一律傳入 `--profile default`，檔位名稱只允許預設與 `advisor` 的語意集合，臨時驗證檔位不進入派工判定。

### 決策歸屬

檔位由主 Agent 於派工當下決定。主 Agent 保留派工前查詢到的兩個視窗剩餘額度與任務難度判定，供回報與後續複核使用。

### advisor 授權請求

主 Agent 判斷值得諮詢時，在派工前輸出單行授權請求，格式如下。

```text
[advisor 諮詢授權] primary 剩餘 <n>%、secondary 剩餘 <m>%；<需要 advisor 的具體理由>。是否執行 advisor 諮詢？
```

理由必須指出該評估的推理密集點與 evidence pack 已整理完成的依據。只寫「問題較難」或「需要深入分析」不構成理由。請求文字本身不構成授權證據；使用者明確同意後，以 `AdvisorRequestSource=user-explicit` 送出派工。使用者未回覆或未明確同意時不發動 `advisor`，不等待也不重複詢問。
檔位判定不得只依 exit code 推論 profile 已生效，必須同時確認啟動參數與產出證據。

## 完成判定與三出口

`codex exec` 是一次性 process，完成判定的依據是事件流末尾與 process 結束狀態的組合，不是單一訊號。報告檔是否出現、stdout 是否閒置、單看 exit code 都不足以判定完成。

| 出口 | 判定條件 | 後續動作 |
| --- | --- | --- |
| A 正常結束 | 背景指令已離開執行狀態、exit code 為 0，且事件流最後一則事件的 `type` 為 `turn.completed` | 進行事件流取證，再執行回收判定 |
| B 執行中查詢 | 背景指令仍在執行，使用者要求現況 | 回報事件流最後一則事件的 `type` 與時間，不中止也不改變等待方式 |
| C 早夭 | 背景指令已離開執行狀態，且事件流最後一則事件的 `type` 不是 `turn.completed` | 最後一則為 `turn.failed` 時取其 `error.message` 作為失敗原因；事件流含 `agent_message` 時取最後一則作為未完成回報，依回收三態判定，不視為正常結束；兩者皆無時讀取 stderr 與 exit code 並回報啟動失敗 |

`turn.completed` 與 exit code 0 必須同時成立才走 A 出口。任一不成立即走 C 出口，包含事件流以 `turn.completed` 結束但進程以非零結束碼離開的組合。無法取得 exit code 時同樣走 C 出口，不以事件流單方面判定成功。

C 出口的常見成因包括參數位置錯誤、模型不被伺服器接受、額度用盡與 sandbox 權限失敗。參數與環境類失敗在 stderr 留下訊息，額度與伺服器類失敗只出現在事件流的 `turn.failed`，因此兩者都必須保存並在判定時一併查看。

### 腳本背景與證據

`Start` 將 Codex 置於背景執行，立即輸出根 PID 與所有證據檔案路徑。主 Agent 由執行環境的完成通知接續，再呼叫 `Inspect` 與 `Collect`；不以檔案大小、stdout 閒置或單一 exit code 判定完成。

需要中止時，腳本只對已通過 PID 身分比對的根程序或 process group 執行安全關閉，並再次查詢確認進程樹已結束。無法完成身分驗證時保留進程與證據，不執行終止。

### 主 Agent 的等待方式

主 Agent 以執行環境的背景命令呼叫同步模式的 `Dispatch`，由該命令結束的完成通知重新接手，再讀取 Dispatch 結果、事件流、last-message 與報告檔。需要在派遣執行中做其他工作並自行決定等待時點時，改用 `background: true` 與 `Inspect -WaitForCompletion`。兩種方式的完成判定完全相同。主 Agent 不以輪詢檔案大小、stdout 閒置或派生 subagent 等待取代事件流取證。

執行環境的背景命令有時限，到時限被停止時，已啟動的 Codex 程序不受影響並照常完成。預期執行超過背景命令時限的派遣，以獨立程序啟動 `Dispatch`，或使用 `background: true` 再分段呼叫 `Inspect -WaitForCompletion`，不讓外層命令長時間輪詢。派遣內需要長時間執行的建置或測試，執行端以獨立於 Codex 的監督程序啟動，stdout 與 stderr 直接寫入檔案，Codex 因額度或服務端容量中斷時，測試結果仍可由檔案取得。

## 事件流取證

`Start` 將事件流寫入 `executionRoot\.local\ai-sessions\history\codex-exec-<yyyyMMdd_HHmmss>.jsonl`，將 stderr 寫入同目錄的 `codex-exec-<yyyyMMdd_HHmmss>.stderr.log`。兩者都必須在正常結束與失敗路徑保存。`Inspect` 逐行解析事件流，空白行略過；任一非空行格式錯誤或缺少 `type` 時以非零結束碼拒絕產出成功狀態，輸出規則同「Inspect 逐行解析 JSONL」一段。

| 取證項目 | 來源 |
| --- | --- |
| `threadId` | 第一則 `thread.started` 的 `thread_id` |
| `finalMessage` | 事件流中最後一則完整 `item.type` 為 `agent_message` 的 `text`；`--output-last-message` 檔只作一致性證據，結果記於 `lastMessageConsistency`，`finalMessageSource` 固定為 `event-stream` |
| `completed` | 事件流最後一則事件的 `type` 是否為 `turn.completed` |
| `usage` | `turn.completed` 的 `usage` 物件，作為本次實際消耗記錄 |
| `outputValid` | 最後訊息是否同時包含 required identifier（派遣單路徑或 `design.md`）、`dispatchSlug` 與 `lineSlug`；接受半形或全形冒號、等號，值可被反引號、引號或 Markdown 連結包夾，近似名稱不算符合 |
| `exitCode` | process 結束碼 |
| `stderr` | stderr 檔案完整內容 |

`Inspect` 對事件流與 last-message 掃描疑似機密樣式，包含 PEM 私鑰標頭（`-----BEGIN` 加 `PRIVATE KEY-----`）、連線字串中 `Password=` 或 `Pwd=` 後接非空值、`AKIA` 開頭的 20 字元 AWS key、`sk-` 開頭且長度至少 20 字元的 token，以及 `.env` 樣式 KEY=VALUE 中名稱含 SECRET、PASSWORD、TOKEN 或 API_KEY 的欄位。Inspect 也遞迴檢查 JSON 物件與陣列。JSON 屬性名稱移除連字號、底線、句點與空白後轉小寫；名稱含 secret、password、passwd、credential、connectionstring、privatekey 或 apikey，或以 token、pwd 結尾時，屬性值視為機密。input_tokens、cached_input_tokens、cache_write_input_tokens、output_tokens、reasoning_output_tokens 與 total_tokens 等 usage 鍵不符合此規則，遮蔽後鍵名、數值與型別維持不變。命中結果以 `json-secret-property` 樣式記錄檔案與行號；Inspect 輸出中所有 JSON 文字欄位與遞迴物件的命中值以 `***` 遮蔽，一般屬性名稱與值維持原樣。事件流或 last-message 的 JSON 解析、掃描或遮蔽失敗時，錯誤訊息與 failure 物件只包含固定錯誤碼、檔案路徑與行號，不輸出解析器訊息、來源片段、原始例外或機密值。結果以 `secret_exposure_suspected` 表示是否命中，`secret_exposure_findings` 列出檔案、行號與樣式名稱，不輸出命中內容；未命中時為 `false`。掃描結果不改變既有 success 判定。

事件流與本輪 thread、turn 屬同一份證據，因此是 `finalMessage` 的唯一來源；外部 last-message 檔可能是前輪或其他派遣的輸出，只用來比對。外部檔存在且內容與事件流不同時 `lastMessageConsistency=Mismatch`，路徑與本輪 RunRecord 不符時為 `BindingMismatch`，兩者都使 `outputValid=false`、`success=false`；比對前將 CRLF 與 CR 統一為 LF，只移除開頭一個 BOM 與結尾換行。`outputValid=true` 只在 `Inspect` 取得本輪 final message 且通過全部輸出檢查時成立，其餘情況一律為 `false`：
- 事件流沒有 `turn.completed` 或 `turn.failed`（中斷），`Inspect` 提前回傳 `recoveryState=InterruptedUnknown` 與中斷保全紀錄，`outputValid=false`。
- 事件流已結束但沒有最後的 `agent_message` 或其他必要欄位時，`Inspect` operation 以非零結束碼停止。
- 已取得 final message，但識別字不完整、外部 last-message 為 `Mismatch` 或 `BindingMismatch`。
- advisor 的 `required-output` heading 缺少或內容為空，或 completion partition 判定為 `invalid`。

`usage` 只作為事後記錄與額度對照，不取代派工前的額度快照判定。

`finalMessage` 一律保留在 `history` 的 last-message 檔，不寫入報告落點。`Wait-ForThreadRelay` 逾時後若未取得非空 `threadId`，`Start` 必須輸出 `source=not-ready` 與事件流、stderr、PID 等證據並以非零結束，不得以空字串表示成功；收到有效 `thread.started` 時才以非空 thread id 繼續。

執行角色已在派遣單第 7 欄與其規則檔指定的落點寫入報告，該檔是驗收對象。回收端若把結案摘要寫進同一路徑，會在驗收前覆蓋角色產出的完整報告。Workflow 派工的 `reportLineRoot\implement-closure-report.md` 同樣由 `Developer` 自行寫入，回收端只讀取與驗收。

報告落點檔案不存在或為空時，依回收三態的「退回」處理，要求角色補齊，不以 `finalMessage` 代寫。

## 續 session 與跨介面接手

同一 worktree 的純技術補件使用 `Start -ResumeThreadId`，沿用原 `dispatchSlug` 與 `ScopePlanPath`。`PreflightResultPath` 與 `PrepareResultPath` 分別取自前輪 Dispatch result 的 `preflight_result_path` 與 `prepare_result_path`，ScopePlan 與 thread id 取自該輪 Start 結果或 RunRecord。換 worktree 時以新的 `dispatchSlug` 呼叫 `Dispatch`，Request 使用 `session_mode=Continuation` 與 `continue_from_scope_plan` 承接父 ScopePlan，由 Dispatch 重建 worktree；原 worktree 不作新 Dispatch 的目的地。

中斷檢查點由 Start 建立於 `executionRoot` 的同線 `history`，worktree 派遣由執行端在該 worktree 更新，direct-write 的 `executionRoot` 等於 `sourceRoot`。RunRecord 保存絕對路徑，Inspect 與 Collect 依該路徑讀取；舊 RunRecord 記錄的來源同線路徑仍可讀取。Cleanup 在移除 worktree 前將檢查點與事件流依相同保存流程複製回來源同線 history，並核對保存結果。

若需要補齊欄位或修正純技術驗收問題，先從 `codex-thread-<dispatchSlug>.txt` 讀取 `thread_id`，再以 `codex exec resume` 續行。續 session 沿用同一個 `dispatchRoot`、sandbox 邊界、`LineContext`、檔位、完整 `ScopePlan` 與 PID 身分驗證規則，並重新注入 `InterruptionSafeguard`。冷啟動寫入 ScopePlan 後，Start 以原始檔案位元組計算 SHA-256，保存至 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>\scope-plan-hash-<dispatchSlug>.json`（舊版根目錄紀錄的沿用條件見本 Skill 開頭的 ScopePlan hash 說明）；紀錄固定包含 `dispatch_slug`、`line_slug`、`scope_plan_path`、`sha256` 與 `created_at_utc`，既有同名紀錄不得覆寫。`ResumeThreadId` 必須同時提供既有 `ScopePlanPath` 與前輪交接資料（last-message，或 `turn.failed` 且無 last-message 時已驗證的中斷檢查點）；Start 必須讀取同名 hash 紀錄、確認 ScopePlan 絕對路徑一致並重新計算檔案 SHA-256，紀錄缺失、路徑不符或 hash 不一致時以非零結束，且不得啟動 Codex。hash 紀錄是 ScopePlan 未被改寫的唯一判定依據，不使用 `.original.json` sidecar 或自行計算 fingerprint。hash 通過後，Start 再確認 ScopePlan 欄位完整、`selected_units` 加 `deferred_units` 等於 `requested_units`、`session_mode=cold-start`，且 `dispatch_slug`、`dispatch_kind`、`task_type`、`requested_profile`、`unit_kind` 與 `requested_units` 和本次續行呼叫參數一致；任一不一致時以非零結束，且不得啟動 Codex。範圍不足時依既有 ScopePlan 保存已確認結果與證據，再由回收端決定後續 cold-start。

續行的父層選項必須與初始啟動完全相同，包含 `--profile`、`--add-dir` 與 `--search`。這組選項從初始啟動記錄重建，不依當下判斷重新推導；任一項缺漏都會改變檔位、寫入權限或網路能力，使續行的執行條件與前一輪不一致。`Start` 會檢查續行識別、保全指示與 `ScopePlan` 是否一致，拒絕缺少必要交接資料的請求。

準備或啟動失敗的嘗試以 `launch_state=launch-failed` 與 `failure` 物件保存，包含 `phase`、`reason_code`、原始例外與事件流、stderr 等原始輸出位置，保留於執行鏈供稽核，不刪除。RunRecord 以 `attempt_parent_run_id` 記錄前一次嘗試，以 `previous_run_id` 與 `resume_anchor_run_id` 記錄可續行的 thread 錨點，兩者分欄。最新嘗試為失敗且 PID 檢查沒有活躍程序時，同一 dispatchSlug 可再冷啟動。續行時沿 `attempt_parent_run_id` 回溯，依 dispatchSlug、thread id 與可續行最小狀態選擇有效錨點；`launch-failed` 紀錄保留供稽核，任何情況都不作續行對象。PID 狀態為 `record-identity-mismatch` 時代表 PID 重用，不阻擋續行；`root-process-absent` 也不阻擋。有效活躍程序或其他身分未確認狀態會阻擋同派遣續行，錯誤訊息格式為 `ProcessIdentityBlocked：dispatch_slug=<slug>; record=<PID 記錄絕對路徑>; state=<狀態>`，多筆紀錄會逐筆列出。找不到有效錨點、thread 遺失或續行狀態不足時以 `NoValidResumeAnchor` 停止，交接已確認成果、未完成單位與 cold-start 指引。

續行沿用初始啟動的 profile，不另外比對原 thread 模型；需要確認時以 `DiagnoseModelEnvironment` 診斷。

Start 與 Inspect 的失敗結果帶 `reason_code`：`QuotaServiceRejected`、`RequiredParameterMissing`、`AdvisorImplementationProfileRejected`、`AdvisorProfileRequired`、`AdvisorAuthorizationRequired`、`EvidencePackRequiredOutputInvalid`、`EvidencePackMissing`、`EvidencePackInvalid`、`EvidencePackInlineMismatch`、`ProfileEvidenceUnknown`、`CodexLaunchFailed`、`ProcessIdentityUnknown`、`ThreadRelayTimeout` 或 `Unknown`。`turn.failed` 或非零 exit 沒有可確認原因時使用 `Unknown`，並保留原始事件行與 stderr；stderr 為空不代表沒有錯誤。

前輪以 usage-limit 中止、沒有 last-message、啟動失敗或終止原因不明時，續行沿既有執行鏈的 `attempt_parent_run_id`／`previous_run_id` 尋找有效 anchor；找不到有效 anchor 時以 `NoValidResumeAnchor` 停止。執行鏈保留失敗嘗試、事件流、ScopePlan、baseline、父層選項、process gate 與 model evidence，成果仍由 Inspect 與 Collect 驗收。有效 anchor 的事件流以 `turn.failed` 結束且沒有 last-message 時，Start 依 RunRecord 的 `interruption_checkpoint_path` 取得已驗證交接資料，新 RunRecord 的 `continuation_handoff_source_type` 記為 `interruption-checkpoint`；使用 last-message 時記為 `last-message`。兩者皆缺或檢查點驗證失敗時，以 `ResumeHandoffUnavailable` 拒絕並指出兩個檔案路徑。

初次 Start 將有效父層選項寫入 RunRecord 的 `parent_options`（`profile`、`sandbox`、`add_directory` 保留原文與順序、`search`、`codex_parent_option` 保留原文與順序、`working_directory`）與 `parent_options_sha256`。續行未顯式傳入時從錨點還原，顯式傳入時逐欄比對，任一不同即以 `ParentOptionsMismatch` 拒絕並輸出欄位、數量與首個差異索引，不以當次呼叫值覆蓋錨點值；舊 RunRecord 沒有此欄位時輸出 `ParentOptionsUnknown`，不續行原 thread。

續行不比對 worktree 的 ACL／SID 證據；ACL 證據缺少或與前輪不同時，有效 thread 仍可續行。Codex 在 `turn.started` 後沒有後續事件且非零結束時，Inspect 判定 `InterruptedUnknown`，保存事件尾段、stderr 與 exit code 並輸出 `cold_start_recommended=true`；該 worktree 不再作為續行目標，冷啟動改用新的 dispatch worktree。

續行實際失敗（`turn.failed` 或非零結束且 Inspect 判定失敗）時，Dispatch 依 Request 的 `failure_receipt_path` 寫入 `ai-sessions.dispatch-failure-receipt.v1`，不自動重送。`continuation_handoff` 含 `confirmed_results`（最新 safe point 的已確認結論與覆蓋範圍；取不到時為空陣列並標示來源不足）、`incomplete_units`（只取前輪 ScopePlan `selected_units` 的子集合，以完整字串逐一比對 safe point，不以標點切分單位名稱；deferred 或其他未選項目剔除並記錄理由；缺 safe point 時保留全部 selected_units）、`source_locations`（Request、ScopePlan、RunRecord、事件流、last-message、Inspect 結果與 safe point 證據位置）、`cold_start_entry`（新的 `dispatch_slug`、`session_mode=cold-start`、未完成單位與 root、prompt、target、識別字，`new_request_required=true`）與 `automatic_retry=false`。Inspect 擲出例外或第一次 receipt 寫入失敗而改走通用失敗路徑時，續行派遣仍帶入 `continuation_handoff`（已建立者沿用，否則依 RunRecord 與 ScopePlan 建立）；`session_mode` 的大小寫變體同樣視為續行。主 Agent 依 `cold_start_entry` 建立新的 Request 冷啟動。

`Start` 以 `ResumeThreadId` 讀取指定 `thread_id` 後建立續行命令，重新產生事件流與 stderr 檔案，不覆寫前一輪記錄。續行的父層選項從初始啟動結果重建，包含 `--profile`、`--add-dir` 與 `--search`。

`exec resume` 的 session 識別接受 `thread_id` 或 thread 名稱，UUID 優先解析。省略識別並改用 `--last` 會選取最近一次記錄的 session，該行為依賴本機記錄狀態而非本次派遣的識別，因此派工流程一律明列 `thread_id`，不使用 `--last`。Start 將錨點 RunRecord 的前輪 last-message 原文注入續行 prompt。前輪以 `turn.completed` 結束時只要求該訊息存在且非空；前輪被中止、早夭或終止狀態無法判定時，另要求訊息明列已確認結論、未完成單位與證據位置三個單行鍵值對，缺少任一項時拒絕續行。前輪事件流以 `turn.failed` 結束且 last-message 缺失時，Start 改注入 RunRecord 指向且通過驗證的中斷檢查點，並在新 RunRecord 記錄交接來源類型；檢查點缺失或驗證失敗時以 `ResumeHandoffUnavailable` 拒絕並列出兩個檔案路徑。此分流與「InterruptionSafeguard」節一致。

續行 prompt 仍來自 scratch 檔案並以 `-` 從 stdin 傳入，內容必須重述同一組 `LineContext`、`dispatchRoot`、檔位與父層選項，列出前輪「驗證證據」及「Phase 對照」的既有條目，並逐項附上未達成條件清單。已完成的條件不得以摘要取代，續行只補齊明列的缺漏。續行的對象是 Reviewer 時，未達成條件以前輪報告的 finding ID 逐一列出（例如 `F-003 未閉合：<一句話>`），並附上主 Agent 對每個 ID 所做修正的位置；不以新措辭重述缺陷，讓 Reviewer 依 ID 判定閉合狀態。

跨介面接手視為同一條 line 的續行，依序讀取下列交接物重建狀態。

1. `dispatchLineRoot\design.md`。
2. `sourceLineRoot\requirement-summary.md`。需要由 Codex 寫入或讀取來源交接時，沿用啟動命令的 `--add-dir` 授權。
3. 本輪 `executionRoot\.local\ai-sessions\history\codex-exec-<yyyyMMdd_HHmmss>.jsonl`。
4. `reportLineRoot\implement-closure-report.md` 或派遣單第 7 欄指定報告。

### 中止與安全關閉

中止只針對 PID 記錄中 `work-root`、`line-slug` 與 `dispatch-slug` 三者均匹配本次派遣的進程樹，並依「Codex 進程 PID 與並行檢查」的根程序名稱、建立時間及 process group 或後代鏈身分比對後執行。使用者要求中止前若無法完成身分驗證，保留進程與證據，不執行任何 `taskkill` 或 `kill`。終止後再次查詢確認全部程序已結束，並保存事件流、stderr 與 exit 資訊。

被中止的派遣不視為完成，依 C 出口處理。

## sandbox 外環境動作

需要網路或 work-root 外環境變更的工作，由主 Agent 在派工前代執行。代執行前必須取得使用者當輪明確同意。非互動情境無法取得當輪同意時停止並回報缺件。

代執行後追加 `<work-root>/.local/ai-sessions/report/<lineSlug>/exceptions.md`，觸發類型使用「偏離設計」，並記錄外環境動作、同意依據與位置。寫入前確認 `LineContext.lineSlug` 與同線 manifest 一致。不得以開放 sandbox 網路取代 `--search`，也不得把 shell 出網工作直接派給 Codex。

## 網路能力硬邊界

`--search` 是 Codex 的唯一上網路徑，且屬 `codex` 的父層選項，必須放在 `exec` 或 `exec resume` 之前。Codex shell 無法以 `curl` 或其他一般 shell 工具出網；開啟 sandbox network access 也不代表 shell 查證可用。

下列工作需要 shell 出網，應由 Claude 端依外環境動作規則處理，或先取得使用者當輪同意後由主 Agent 代執行。

- `npm install`。
- `git fetch`。
- 下載檔案或套件。

事實查核類派遣必須啟用 `--search`。未啟用時，Codex 可能無法取得資料而改以記憶作答。

## 兩種派工差異

共用本 Skill 的機制。Workflow 派工與資源派遣只以輸入、產出與結案要求區分；兩者都先使用 `Preflight` 依寫入面選擇 dispatch worktree 或 `sourceRoot`。

| 面向 | Workflow 派工（`Developer`） | 資源派遣（`Architect`、`Reviewer`、`Support Engineer`、其餘一切） |
| --- | --- | --- |
| 必備輸入 | `dispatchLineRoot\design.md` 絕對路徑 | `executionRoot\.local\ai-sessions\handoff\dispatch-order-<dispatchSlug>.md` 派遣單絕對路徑 |
| 產出落點 | `reportLineRoot\implement-closure-report.md`，回收後同步至 `sourceReportLineRoot` | `executionRoot\.local\ai-sessions\report\dispatch-report-<dispatchSlug>.md`，回收後同步至 `sourceRoot` |
| 結案要求 | 「驗證證據」節的輪起點 SHA 與開工基準線皆有值，「Phase 對照」節逐 Phase 列出修改的檔案清單，且「需求對照」節涵蓋需求摘要的全部項目編號 | 先通過 `RecoveryPrecheck`，再逐條執行派遣單第 5 欄的命令並得出「收下」、「退回」或「升級」之一 |

`requirement-summary.md` 是跨派遣的持久交接檔，固定於 `sourceLineRoot\requirement-summary.md`；覆寫前備份固定於 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>`。這兩個來源落點不屬於 `dispatchRoot` 的派遣產出，資源派遣若需寫入它們，必須在 `exec` 子命令前以 `--add-dir` 分別授權來源線層 `handoff` 與 `history` 目錄。

## 執行端共用作業

本節由角色規則檔引用。角色規則檔決定哪些產出套用哪一項作業，本節只規定作業步驟。引用本節的角色無法讀取本節時，停止寫入並回報缺件，不略過該作業。

### 覆寫前備份

適用於角色規則檔指定需保留前版的固定產出，例如 `design.md`、需求摘要與同線固定報告。依下列順序執行，備份不需詢問使用者確認。

1. 確認目標檔案是否存在。不存在時直接寫入新內容，不建立備份。
2. 確認 `<work-root>\.local\ai-sessions\history\<lineSlug>\` 存在，不存在時建立。
3. 將既有檔案改名為 `<原檔名>.<yyyyMMdd_HHmmss>` 並移入該目錄，時間戳取備份當下時間。同名備份已存在時停止並回報，不覆寫既有備份。
4. 確認備份檔存在後，才寫入新內容。

`lineSlug` 必須與同線 `line.json` 的 `line-slug` 一致。`history` 位於來源工作樹時，Codex 執行端需要啟動命令以 `--add-dir` 授權來源 `history\<lineSlug>\`。

### 共同基準與主張反證比對

適用於檢查產出者成果的角色，例如 Reviewer 與 Frontend Reviewer，以及主 Agent 的回收覆核。角色的獨立判斷順序（例如 Reviewer 的行為型判定）由角色規則檔定義，本節規定比對時的基準與記錄方式。

1. 使用與產出者相同的需求基準。實讀派遣單第 4 欄或派工 prompt 指定的 `requirement-summary.md`、`design.md` 與派遣單，在報告記錄各檔的絕對路徑與 SHA-256。基準檔與產出者引用的版本不同時，先回報版本差異，不以任一方的轉述代替原文。
2. 取得原始證據。判定依據引用檔案絕對路徑與行號，並附不超過三行的原文摘錄；命令證據附命令原文與原始輸出。轉述與摘要不作為判定依據。
3. 逐項比對產出者的具體主張。對產出者報告中與驗收有關的每一項主張記錄四欄：主張原文、主張引用的來源、支持或反駁的原始摘錄、檢查過的可能反證。主張沒有引用來源時記為「無來源」，不代為補找來源後視為成立。
4. 歸因爭議先核對可辨別事實的來源，例如 commit、檔案雜湊、命令輸出或事件流，再判斷原因；事實來源無法取得時記為未確認，不依多數意見或使用者同意定案。
5. 判定與產出者結論不同時，在報告保留雙方主張、來源與反證，交由回收三態或升級判定處理。

### Finding 編號與前輪對照

適用於產出 finding 的審查角色，例如 Reviewer、Frontend Reviewer 與 Contract Auditor。本節規定編號與前輪對照的共同步驟；finding 的分類、報告區段格式與 Reviewer manifest 由各角色規則檔定義。編號延續與停止判定的共同定義為 `instructions.md` §1.5 共同收斂契約的 `problem-key`，審查循環的 `problem-key` 即 finding ID。

1. 每項 finding 以 `F-<三位數>` 編號，自 `F-001` 起遞增。角色規則檔允許以其他識別承載者（例如 Reviewer 以 T-code 承載 Spec 判定）依該角色規定。
2. 派遣單第 4 欄或續行 prompt 列出同一角色的前輪報告時，先實讀前輪全部 finding ID 與各 ID 的前輪結束狀態。前輪報告讀取失敗時停止並回報缺件，不以本輪觀察推測前輪狀態。
3. 對前輪每個 ID 逐一判定「已閉合」「未閉合」「撤回」或「已接受殘餘風險」，引用目前檔案的位置作為依據。撤回須附撤回理由，不得把撤回推論為已閉合。只有派遣單第 4 欄、前輪報告或同線 `exceptions.md` 提供 Analyst 或使用者的明確裁決時，才可判定為已接受殘餘風險，並附裁決者、適用範圍與重新開啟條件。
4. 未閉合的前輪 finding 沿用原 ID 與原嚴重度；嚴重度變更時註明理由。同一問題不得以新措辭另開 ID。
5. 本輪新發現的 finding 自前輪最大編號之後接續編號，不重用已出現過的 ID。
6. 有前輪報告時，報告在「總覽」之後列出前輪 finding 狀態，每個前輪 ID 一列。

停止判定依共同收斂契約。同一 finding ID 連續兩輪未閉合，或同一區域連續兩輪出現新的 `Major` 以上 finding 時停止，保留證據並提出替代方向，不以更換 ID 規避計數。角色規則檔明定不備份的產出（例如 Reviewer 依派遣單覆寫的報告檔）不套用本節。以腳本或批次指令改寫既有檔案的備份另依 `instructions.md` §1.4「腳本改寫安全」，存入 `backups\<時間戳>\`，與本節的逐檔改名備份用途不同。

## 派遣單契約

資源派遣使用 Markdown 派遣單，來源路徑為 `sourceRoot\.local\ai-sessions\handoff\dispatch-order-<dispatchSlug>.md`，複製至 `dispatchRoot` 後供 Codex 讀取。派遣單屬該次派遣輸入；它與跨派遣的 `requirement-summary.md` 使用不同落點，後者固定於 `sourceLineRoot`。`dispatchSlug` 限用小寫英數與連字號，同一個 `sourceRoot` 內不得重複。八個欄位全部必填，缺少任一欄即視為契約未滿足。

| # | 欄位 | 內容要求 |
| --- | --- | --- |
| 1 | 任務標題 | 一句話，含動詞 |
| 2 | 執行角色 | Codex 端 Agent 觸發詞，例如「值班工程師」或 `review`，也可填 skill 名稱，例如 `fact-check-note` |
| 3 | 目標物件 | 檔案、目錄或端點的絕對路徑，逐項列出 |
| 4 | 任務內容 | 含動詞與具體對象，不使用「處理 X」或「改善 Y」等無法驗收的描述 |
| 5 | 驗收條件與 Codex 命令 | 以表格逐列提供驗收條件與第三方可執行命令；Codex 必須回報命令原文與原始輸出，包含完整 stdout、完整 stderr、exit code 與執行時間 |
| 6 | 執行邊界 | 描述工作類型、目標物件、允許的報告與交接寫入，以及不得修改目標物件等行為限制。第 6 欄不描述 repository 排除檔案清單，隔離由 dispatch worktree 與 `--cd` 提供。「唯讀」定義為不得修改目標物件、不得執行建置與測試、不得建立 commit；非唯讀派遣同樣不建立 commit，commit 由主 Agent 回收後處理。所有派遣共用三項明文寫入例外：派遣單第 7 欄的報告檔、執行角色規則檔指定的同線固定報告，以及 `<work-root>/.local/ai-sessions/report/<lineSlug>/exceptions.md`。角色固定報告的檔名由該角色的規則檔定義，派遣單不逐一列舉；第 6 欄不得以未列舉為由否定該寫入，否則角色規則與派遣單邊界會互相否定。需要完全不寫入任何檔案時，明文寫出「不產生任何檔案寫入」。 |
| 7 | 產出落點 | 報告或產物的絕對路徑 |
| 8 | 回報必備欄位 | Codex 端回報必須逐條列出第 5 欄命令原文、完整 stdout、完整 stderr、exit code、執行時間、執行狀態與判定結果。執行狀態為已執行、受阻、未執行或已補驗四選一，執行端只可使用前三者；受阻須說明缺少的環境能力與原始錯誤。已補驗只由主 Agent 於回收補驗後填寫 |

派遣單第 3 欄接受 `text` 程式碼區塊與 Markdown 條列。條列項比對前剝除 `- ` 前綴與單層成對反引號。格式錯誤時，錯誤訊息列出剝除後的路徑與原始行號。

第 5 欄格式如下。

```markdown
| # | 驗收條件 | Codex 命令 |
| --- | --- | --- |
| <n> | `<absolute-path>` 存在且非空 | `Get-Item -LiteralPath '<absolute-path>'` |
| <n> | 內容含指定欄位 | `rg -n '<pattern>' '<absolute-path>'` |
```

第 5 欄的 `rg` 命令有兩種會靜默失效的寫法。兩者都讓命令正常結束、exit code 符合預期，只有輸出是空的，因此會被執行端與複核端同時誤讀為「負向驗證通過」，而該條驗收實際上從未被檢查。

| 錯誤寫法 | 成因 | 正確寫法 |
| --- | --- | --- |
| `rg -n 'A\|B\|C'` | 派遣單多以 heredoc 產生，`\|` 原樣寫入檔案。ripgrep 使用 Rust regex，`\|` 是字面管線字元而非 alternation | `rg -n 'A|B|C'` |
| `rg -n '^## 標題$'` | 目標檔為 CRLF 時，`$` 錨點在 `\r` 之前匹配失敗，即使該行確實存在 | `rg -n '^## 標題'` 或 `rg -n '^## 標題\r?$'` |

負向驗證不得只以 `rg` 的 exit code 1 作為通過依據，必須另附一條明確計數命令佐證。理由是 exit code 1 同時代表「確實無匹配」與「模式寫錯導致無匹配」，兩者無法從結束碼區分。

第 5 欄的驗收條件分兩類，主 Agent 為每一條標示所屬類別。

| 類別 | 斷言對象 | 未修改狀態下的預期 |
| --- | --- | --- |
| 新行為條件 | 本輪要達成的結果 | 不成立 |
| 回歸守衛條件 | 本輪不得破壞的既有行為 | 成立 |

主 Agent 送出派遣單前，對每一條新行為條件執行一次自我測試。自我測試在目標尚未修改的狀態下實際跑該條命令，確認它回報不成立。任一條在未修改狀態下就回報成立時，該條無法區分「已完成」與「檢查失效」，改寫後重測，改寫前不得送出派遣單。

回歸守衛條件在未修改狀態下必然成立，無法用同一方式檢驗，改以在派遣單寫明其守衛對象，讓回收時能判斷該對象是否仍受檢查。把回歸守衛條件當成新行為條件送去自我測試，會得到「條件恆真」的錯誤結論並導致無效改寫。

報告在派遣單第 8 欄之外另附各條的類別與未修改狀態輸出，供回收時比對。

### 受阻條件

每條驗收條件有四種執行狀態，執行狀態與條件判定分開記錄。執行端只填寫前三種，已補驗由主 Agent 於回收時填寫。

| 執行狀態 | 定義 | 條件判定 |
| --- | --- | --- |
| 已執行 | 命令在執行端實際跑完並取得輸出 | 依輸出判定成立或不成立 |
| 受阻 | 命令因執行端環境能力不足而無法執行，例如程序查詢被拒、無網路、無桌面控制 | 一律計為未成立 |
| 未執行 | 執行端未嘗試該條命令 | 一律計為未成立 |
| 已補驗 | 受阻或未執行的條件由主 Agent 在回收時補跑並取得輸出 | 依補驗輸出判定成立或不成立 |

受阻計為未成立，理由是該條的斷言對象從未被檢查。把受阻視為通過會讓回報呈現「全部通過」，而實際上該條保護的行為仍是未知狀態。實測一次受阻條件被回報為「受阻」而非未成立，該條所驗的修正實際失效，主 Agent 自行補驗才發現。

執行狀態與第 5 欄的類別是兩個正交軸。類別描述斷言對象，執行狀態描述該條是否跑過，任一類別都可能出現任一執行狀態。回歸守衛條件受阻時，其「未修改狀態下必然成立」的預期本身不受影響，變的是該預期尚未被驗證。受阻代表結果未取得，不代表基準行為已失效，因此該條計為未成立並等待補驗，而非判定基準行為被破壞。

#### 所需能力標註

依賴執行端環境能力的條件，在第 5 欄「驗收條件」欄位開頭以 `[需要:<能力>]` 前綴標註，允許值為 `process-query`、`network`、`desktop`、`build`、`container`、`gpu`。需要多項時以半形逗號分隔。無前綴表示不依賴特殊能力。

前綴可機械判定，回收端據此判斷該條是否已標註，並選擇補驗環境。標註同時是派遣前的檢查點：能改寫為不依賴該能力的等價檢查時優先改寫，不改寫則接受受阻可能發生。

#### 補驗

受阻與未執行條件由主 Agent 在回收時補驗，補驗結果取代原判定，該條執行狀態改記為「已補驗」，並附補驗的命令原文、完整 stdout、完整 stderr、exit code 與執行時間，與執行端回報的原始受阻紀錄並存。

補驗只在命令無外部副作用時自動執行。命令會改變外部狀態時，例如寫入資料庫、送出網路請求、修改目標物件或建立資源，主 Agent 不得自動補驗；此時改以無副作用的等價檢查補驗，或取得使用者當輪明確同意後才執行原命令。無法判定命令是否有副作用時，視為有副作用。

主 Agent 無法補驗時，該條維持未成立並依回收三態處理。以退回續行處理受阻條件前，必須先改變執行環境的能力集合或改寫該條為不依賴該能力的檢查；能力集合未改變時的續行會產生同一受阻結果，不得作為退回的唯一動作。

派遣單第 5 欄列入建置或測試命令時，該條的執行與輸出責任仍屬主 Agent，執行端回報「未執行」即為正確行為，由主 Agent 補驗後填入結果。

自我測試涵蓋三類失效，這三類的共同特徵是命令正常結束、exit code 符合預期，只有輸出是空的或結論是錯的。

| 失效類型 | 實例 | 自我測試如何攔截 |
| --- | --- | --- |
| 模式寫錯導致永遠無匹配 | `rg` 的 `\|` alternation 與 CRLF 下的 `$` 錨點 | 未修改狀態下應有匹配卻回報無匹配 |
| 門檻寫錯導致條件恆真 | 以「縮排不超過 N 個空格」約束縮排，使所有行被壓到同一數值 | 未修改狀態下就回報成立 |
| 比對範圍過寬導致條件恆假 | 比對縮排時連內容一起比，而內容本就會因其他改動而變 | 未修改狀態下的失敗原因與待驗收項目無關 |

透過 PowerShell 取得 `git show` 輸出時，以位元組讀取後自行以 UTF-8 解碼。PowerShell 會以 console 編碼解碼子行程輸出，非 ASCII 內容會變成替代字元，使逐字比對產生假性不一致。改在 Bash 以管線處理位元組同樣可行。

資源派遣的建置與測試由主 Agent 自行執行，不列為 Codex 第 5 欄的命令輸出責任。Workflow 派工沒有派遣單第 5 欄，建置與測試依 `developer.toml` 的結案 gate 由 Developer 執行。

複核政策唯一：主 Agent 逐條核對 Codex 回報的命令原文與輸出是否支持其判定結論，這是核對而非重新執行。只有在輸出與結論不一致、輸出缺漏、回報只寫「已完成」而無命令輸出，或該條執行狀態為受阻或未執行時，才實際重跑該條命令。不整套重跑全部條件。

回收覆核的外部事實查證由主 Agent 負責。主 Agent 可在回收階段使用可用的上網工具查證派遣報告涉及的版本、規格、官方行為或其他驗收必要事實。派遣報告的自述不取代查證，查證也不取代第 5 欄命令輸出。每筆查證證據必須保留查詢內容、來源連結、查證時間、相關原始輸出或摘錄，以及支持或不支持驗收結論的判定，寫入回收報告或同線查證證據。來源不足、查證失敗或結果矛盾時，標示未驗證並交由回收三態處理，不得以推測補足。

## RecoveryPrecheck

事件流取證後，先從符合目前派工類型的 `agent_message` 取最後一則結案訊息。識別字依派工類型判定，兩種類型都必須包含 `dispatchSlug` 與 `lineSlug`，第三項識別字如下。

| 派工類型 | 第三項識別字 |
| --- | --- |
| Workflow 派工 | `dispatchLineRoot\design.md` 的絕對路徑 |
| 資源派遣 | 派遣單的絕對路徑 |

Workflow 派工沒有派遣單，以派遣單絕對路徑作為共同條件會使正常結案一律被判為 `PromptNotDelivered` 並重派。缺少任一識別字時，狀態設為 `PromptNotDelivered`，修正啟動方式後重新派遣；此狀態不計入退回次數，也不進入第 5 欄驗收缺漏的退回計數。只有 `RecoveryPrecheck` 通過後，才可進入回收三態判定。

### 回收收斂判定

回收三態套用 `instructions.md` §1.5 的共同收斂契約。一次修正連同其驗收或回歸判定為一輪，初次執行為第 1 輪。對派遣回收而言，`recovery-round` 記錄每次純技術續行增加的輪次。派遣回收的 `problem-key` 使用 `dispatchSlug` 加派遣單第 5 欄的驗收列序號，驗收列序號在同一派遣的各輪保持不變。

派遣回收的 `area-key` 為派遣單第 5 欄驗收條件所屬的目標物件檔案與節名。嚴重度映射如下。

| 循環 | `Critical` | `Major` | `Minor` |
| --- | --- | --- | --- |
| 派遣回收 | 產出遺失、證據不可追溯或錯誤同步 | 必要驗收條件不成立或回報與產出矛盾 | 單一欄位、格式或命令輸出缺漏且可直接補件 |

- 每輪逐條保存第 5 欄驗收結果、命令輸出、報告與事件證據。前輪未成立的驗收列在本輪相同 key 成立且沒有反證時標記 `closed`；本輪 key 不在前輪未成立集合且沒有同一 key 的改寫或重新命名時標記 `new-problem`。
- `dispatch-return-count` 只記錄該派遣的退回稽核資料，不作一般停止條件。`PromptNotDelivered` 是啟動契約錯誤，不增加此計數。
- 全部驗收列成立時進入下一站。前輪問題連續兩輪未閉合、同一 `area-key` 連續兩輪出現新的 `Major` 以上問題、修正需要改變需求或已確認設計，或 `recovery-round` 達到 6 輪時停止，保留證據並提出替代方向。
- 所有問題均屬純技術可解、未命中上述停止訊號，且前輪問題已閉合或本輪新問題只有 `Minor` 時自動續行。新出現的 `Major` 在尚未形成停止訊號前依純技術路徑續行。

## 回收三態判定

背景指令結束後，主 Agent 先執行 `RecoveryPrecheck`，再讀取 dispatch worktree 內派遣單第 7 欄的產出落點，依第 5 欄逐條核對。核對與重跑的分界見上節的複核政策。主 Agent 不以 Codex 端回報中的自述取代實際判定。派遣單第 8 欄必須要求 Codex 端逐條回報每條驗收條件的命令原文與完整 stdout、完整 stderr、exit code 與執行時間。主 Agent 以抽驗方式複核回報內容，對輸出與結論不一致的條件只重跑該條命令。回報只寫「已完成」而未附命令輸出者，該條計為未成立。

標示為受阻或未執行的條件一律計為未成立，不因回報語氣看似無礙而放行。主 Agent 對每條受阻條件與每條未執行條件執行補驗，補驗結果取代原判定並將該條狀態改記為已補驗；補驗不可行時該條維持未成立。全部驗收條件成立的判定必須建立在「已執行且通過」與「已補驗且通過」兩種狀態之上，不得包含任何未補驗的受阻或未執行條件。

Codex 端不建立 commit。Workflow `Developer` 的機械 commit 由主 Agent 依 `design.md` Phase 重整後回收，資源派遣的報告與核准交接產物直接同步至來源工作樹。

| 判定 | 成立條件 | 後續動作 |
| --- | --- | --- |
| 收下 | 產出落點檔案存在且非空，全部驗收條件逐條成立，且沒有任何未補驗的受阻或未執行條件 | Workflow `Developer` 先將成果套回來源工作樹且不建立 Phase commit，保留 dispatch worktree；Reviewer、需求意圖驗收與結案報告完成後，等待使用者授權 commit 再進入 Phase commit 回收。資源派遣同步報告與核准交接產物後結束 |
| 退回 | 任一驗收條件不成立，且原因屬純技術可解，例如格式不符、欄位缺漏或未執行第 5 欄命令 | 一般純技術補件依續 session 契約使用同一個 dispatch worktree resume，帶入未達成條件清單與下一個 `recovery-round`，自動續行且不詢問使用者。完成後回到 Developer 或 Reviewer 站點。額度不足時依 `ScopePlan` 的中止保全流程保存已取得的結論與證據，再由回收端判定是否重新建立 cold-start。 |
| 升級 | 原因命中 `instructions.md` §1.5 升級兩道篩的三類拍板判準，或命中共同收斂契約的停止訊號 | 停止派遣，保留 dispatch worktree 與證據，回報未閉合清單與替代方向，等待使用者選擇方向 |

回收判定成立且不需續 session 時，先完成事件流、thread id、last-message、報告與核准交接產物同步，再以 `pwsh scripts\Invoke-CodexDispatch.ps1 -Operation Cleanup` 執行資源派遣 worktree 清理。Workflow Developer dispatch worktree 僅在使用者授權 commit、Phase commit 回收與驗證完成後執行 `Cleanup`。`Cleanup` 依 `SourceRoot\.local\ai-sessions\history\<lineSlug>\runs\<dispatchSlug>` 驗證 RunRecord 路徑與 line／dispatch／source／execution owner，RunRecord 留在 SourceRoot history，不列入 worktree 檔案保存清單。省略 `EvidencePath` 時採用 RunRecord 引用且位於 dispatch worktree 的既存證據；明列未引用檔案時拒絕並列出可接受清單。RunRecord 或 evidence 路徑越界、owner 不符、保存清單驗證失敗或 worktree 移除失敗時保留 worktree 並回報錯誤。不得改用其他方式強制移除。report 根目錄的 `dispatch-report-<dispatchSlug>.md` 一律同步至來源 report 根目錄，不依賴 `ReportPath` 是否列出；其他未列入保存清單的 report 檔案會阻止移除 worktree。

## 保存契約對照

派工產物的保存責任依下表。只有表中列出的建立者與更新者可以寫入該項；更新欄為「無」的項目建立後不再修改。回收端只做表中列出的處理，不代為補寫內容。

| 保存項目 | 落點 | 建立者 | 更新者 | 回收端的處理 | 詳細節 |
| --- | --- | --- | --- | --- | --- |
| 事件流、stderr | `executionRoot` 的 `history\`，worktree 派遣為 dispatch worktree，direct-write 為來源工作樹；RunRecord 以 `event_stream_path` 與選填 `error_stream_path` 引用事件流及 stderr 的絕對路徑 | `Start` 在啟動前建立空檔；啟動失敗且檔案缺失時補建空檔 | `Start` 產生的 launcher 把 Codex 的標準輸出與標準錯誤重導寫入 | `Inspect` 以 FileStream 與 `FileShare.ReadWrite`、`FileShare.Delete` 共享讀取事件流及 last-message，維持讀取前後雜湊核對；worktree 派遣由 `Cleanup` 依 RunRecord 保存事件流與 stderr 回來源。舊 RunRecord 未記錄 `error_stream_path` 時仍可讀取與清理 | 事件流取證、完成判定與三出口 |
| last-message | 同事件流 | `Start` 啟動的 Codex 程序（`--output-last-message`） | 同建立者 | `Inspect` 只用於與事件流 finalMessage 比對；worktree 派遣由 `Cleanup` 保存回來源 | 事件流取證、完成判定與三出口 |
| thread id | 同事件流 | `Start` 在事件流出現 `thread.started` 且檔案空白時寫入 | 無；續行只讀取比對 | worktree 派遣由 `Cleanup` 保存回來源 | 續 session 與跨介面接手 |
| RunRecord | 來源 `history\<lineSlug>\runs\<dispatchSlug>\` | `Start`，目的已存在時拒絕 | `Start` 在 prompt 傳遞、啟動完成、額度觀測與啟動失敗時更新；`Inspect` 在事件流中斷時更新 `unknown_interruption`。皆為原子寫入 | 只讀；`Cleanup` 依其驗證路徑與 owner，不列入 worktree 保存清單 | 回收三態判定 |
| failure receipt | Request 的 `failure_receipt_path`，可位於來源同線 `history\` 或 dispatch worktree 的同線 `history\` | `Dispatch`，在續行的 `Inspect` 判定失敗，或外層例外且尚未寫入時 | 同建立者；同一路徑的後一次寫入取代前一次 | `Start` 驗證未啟動證明時讀取；位於來源時原地保留，位於 dispatch worktree 時不在 `Cleanup` 保存清單，需保留時由主 Agent 在 `Cleanup` 前讀取 | 回收三態判定 |
| 中斷保全紀錄 | `executionRoot` 的 `history\<lineSlug>\interruption-checkpoint-<dispatchSlug>-<runId>.json`，worktree 派遣為 dispatch worktree，direct-write 為來源工作樹；RunRecord 的 `interruption_checkpoint_path` 為路徑權威。不可寫時以結案訊息中的中斷保全三行交付，位置在識別字三行之前 | `Start` 建立全數未完成的初始檔，並把絕對路徑寫入 prompt | 執行端每完成一個單位以原子寫入更新 | `Inspect`、`Collect` 讀取並回傳已確認單位、未完成單位與證據位置，不回寫該檔，仍接受舊派遣記錄的來源路徑；worktree 派遣由 `Cleanup` 保存回來源同線 `history`。未執行單位不產生結論 | InterruptionSafeguard |
| Developer 結案報告 | dispatch worktree 的 `report\<lineSlug>\` | 執行端（Workflow 為 Developer）；Request 的 `prepare_artifacts` 列入來源既有報告時，`Prepare` 建立執行端副本 | 同建立者 | `Collect` 與 Reviewer 只讀；`Cleanup` 在來源 `report\<lineSlug>\` 建立副本，來源已有不同內容時以目的衝突停止 | 結案報告與 Git 來源紀錄 |
| 協調者結案報告（需要你決定、已自行處理、僅供知悉三區） | 來源 `report\<lineSlug>\` | 主 Agent 判定內容並寫入 | 同建立者 | 不經派工回收；執行端不寫入此檔 | `instructions.md` §1.4 結案報告 |
| advisor 諮詢報告 | `executionRoot` 的 `report\<lineSlug>\advisor-consult-<dispatchSlug>.md` | `advisor-consult` 的 `Inspect`，依事件流與 last-message 產生 | 同建立者；每次 `Inspect` 覆寫 | 主 Agent 讀取後決定是否採用；`Cleanup` 保存回來源，來源已有不同內容時以目的衝突停止。advisor 執行端不寫入 | Advisor consult resource dispatch |
| 派遣報告與角色固定報告 | 派遣單第 7 欄落點、角色規則檔指定的同線固定報告 | 執行端；Request 的 `prepare_artifacts` 列入來源既有報告時，`Prepare` 建立執行端副本 | 同建立者；Reviewer 直接覆寫，Frontend Reviewer 與 Contract Auditor 先把前版移入 `history\` 再寫新版 | `Cleanup` 自動保存 report 根目錄的派遣報告；固定名稱最新報告以兩派遣 RunRecord 的啟動時間或 manifest round 判斷新舊，worktree 較新時封存來源並取代，較舊時封存 worktree 版本並維持來源；無法判斷時保留 worktree，結果列出判斷依據 | 派遣單契約 |
| 同線 `exceptions.md` | `report\<lineSlug>\exceptions.md` | 第一個需要記錄的執行端或主 Agent；Request 的 `prepare_artifacts` 列入來源既有檔時，`Prepare` 建立執行端副本 | 執行端與主 Agent 只追加；`Cleanup` 把 worktree 新增的區塊合入來源後以原子取代寫回 | 保留來源既有區塊；worktree 區塊與來源區塊全文相同時不附加，worktree 內重複區塊只附加一次。同標題但內文不同視為不同條目；兩邊標題前內容只含 H1 與空白時相容，來源前文維持不變，其他不一致時停止 | 回收三態判定 |
| 成果檔案 | dispatch worktree 或 direct-write 目標 | 執行端；Preflight 把來源既有的核准 target 檔帶入 worktree，不覆寫既有檔 | 執行端；`Collect -ApplyCollectedChanges` 套回來源；Workflow 由主 Agent 在使用者授權後 commit | Start 時不存在的核准 target 檔案以 baseline `exists=false` 記錄，回收清單保留該路徑，包含被 gitignore 排除的核准新檔；`Collect -ApplyCollectedChanges` 依來源 drift 檢查套回，新檔搬入、既有檔原子取代、刪除先備份，失敗時倒序回復。核准目錄新增且未被 gitignore 排除的子檔（包含 Start 時不存在的核准目錄）以 add 套回並檢查來源 drift；target 外新增檔列於 `unappliedNewFiles` 並留在 worktree。資源派遣同步核准的交接產物。direct-write 目錄 target 逐檔回傳證據且至少一檔非空 | Phase commit 回收與驗證 |
| RunRecord 引用的執行證據：ScopePlan、launcher、prompt 傳遞副本與加上指示的 prompt、退出 sidecar、PrepareResult、Dispatch 階段結果、Inspect 結果綁定、額度觀測與預算監看紀錄，以及 advisor evidence pack 的 SHA-256 與 length sidecar | `executionRoot` 的 `history\` | 產生該證據的 operation：PrepareResult 由 `Prepare`、階段結果由 `Dispatch`、其餘由 `Start` 與其 launcher | PrepareResult 由 `Prepare` 依狀態更新；Inspect 結果綁定由 `Inspect`；額度觀測與預算監看紀錄由額度監看追加；其餘無 | worktree 派遣由 `Cleanup` 依 RunRecord 保存回來源。advisor evidence pack 的 `.sha256` 與 `.length` sidecar 由既有 `evidence_pack_path`、`execution_root` 與 `dispatch_slug` 推導 Start 寫入的 `history\evidence-pack-<dispatchSlug>.sha256`、`.length` 路徑，沿用路徑邊界驗證後保存；未新增 RunRecord 欄位 | 事件流取證、完成判定與三出口 |
| prompt 原始來源 | 呼叫端指定的 `PromptPath`，可位於來源工作樹或 `executionRoot` | 呼叫端（主 Agent 或撰寫 Request 者） | 無；`Start` 只讀取並建立傳遞副本 | RunRecord 記錄原始路徑；位於 dispatch worktree 時由 `Cleanup` 保存回來源，位於來源時原地保留 | Prompt 必備元素 |
| 額度快照 | `executionRoot` 的 `history\` | before 快照由 `Dispatch` 建立，獨立呼叫 `Start` 時由 `Start` 建立；advisor after 快照由 `Start` 建立；非 advisor 的結束快照由 `Inspect` 建立 | advisor after 快照由額度監看更新；其餘無 | worktree 派遣由 `Cleanup` 依 RunRecord 保存 before 與 after 快照回來源；結束快照不在保存清單 | 額度快照 |
| Dispatch result | Request 的 `result_path`；省略時為 `executionRoot` 的 `history\<lineSlug>\dispatch-result-<dispatchSlug>-<token>.json` | `Dispatch` | `Dispatch` 在提前回傳、Inspect 結束與例外三條路徑寫入同一路徑 | 主 Agent 讀取 Preflight、Prepare 結果路徑與階段結果；預設落點不在 `Cleanup` 保存清單，需保留時由主 Agent 在 `Cleanup` 前讀取 | Dispatch 正式入口 || 來源控制紀錄：ScopePlan hash、admission ledger、PID 記錄、baseline、review finding ledger、cleanup result、quota recovery | 來源 `history\` 或 `history\<lineSlug>\` | ScopePlan hash、PID 記錄由 `Start`；baseline 由 Preflight；admission ledger 由第一次 admission 檢查；finding ledger 由 `Collect`；cleanup result 由 `Cleanup`；quota recovery 由額度探測 | ScopePlan hash、PID 記錄與 baseline 無；admission ledger 由 Preflight、`Start` 與 `Cleanup` 的 admission 檢查；其餘由各自建立者 | 留在來源，不經 worktree 保存 | Caller Session 身分與併行准入 |

## 結案報告與 Git 來源紀錄

每次結案報告都要記錄 `gitOrigin`。`existing` 表示沿用來源既有的 Git，`not-applicable` 表示非 Git 來源的 direct-write 或唯讀派工，不使用 Git 基準。dispatch worktree 被移除不代表來源 `.git` 可被清理，Agent 不清理來源的 `.git`。

舊版腳本曾在非 Git 來源自動建立臨時 Git，其 RunRecord 或 Preflight 結果可能含 `gitOrigin=agent-created` 與 `markerPath`。現行腳本把這兩個欄位視為歷史資料照常讀取，不依其分流；報告如實記錄，是否移除該 `.git` 由使用者決定。
