# Codex 派工機制：建立與啟動

本檔收錄 首次派遣從入口選擇、派遣單、Preflight、Prepare 到 Start 所需的契約。入口與其他階段的檔案見 `../SKILL.md`「階段路由」。

## 使用時機與入口選擇

主 Agent 依 F1 判準判定要派工後載入本 Skill。執行端角色依角色規則檔引用本 Skill 的共用作業節時，只讀取被引用的節。

| 情境 | 入口 | 必要輸入 | 提供方式 |
| --- | --- | --- | --- |
| 建立資源派遣單 | `scripts\New-DispatchOrder.ps1` | `Title`、`Role`、`TargetPath`、`TaskBody`、`Acceptance`、`Boundary`、`ReportPath`、`DispatchSlug`、`LineSlug`；`OutputPath` 選填 | 命令列參數；省略 `OutputPath` 時派遣單寫入來源工作樹 `handoff\dispatch-order-<dispatchSlug>.md`，即 `Dispatch` 讀取的位置，八個欄位定義見「派遣單契約」 |
| 首次啟動一筆派遣（正式入口） | `scripts\Invoke-CodexDispatch.ps1 -Operation Dispatch` | `source_root`、`dispatch_root`、`line_slug`、`dispatch_slug`、`write_mode`、`dispatch_kind`、至少一個 `target_path`、`prompt_path`、`task_type`、`session_mode`、`unit_kind`、`failure_receipt_path` | 只接受 `operation=Dispatch` 的 request 檔（UTF-8 無 BOM），以 `-RequestPath` 傳入；欄位表與範例見「Dispatch 正式入口」 |
| 同一 worktree 續行；換 worktree 續行；恢復或階段間檢查 | 同一 worktree 使用 `Start -ResumeThreadId`；換 worktree 使用 `Dispatch` 的 `session_mode=Continuation`；階段間檢查可分步呼叫 `Preflight`、`Prepare`、`Start` | 同一 worktree 的 Start 使用前輪 Dispatch result 記錄的 Preflight、Prepare 結果路徑及原 ScopePlan；換 worktree 使用新 `dispatchSlug`、重建 worktree 並承接父 ScopePlan | Start 參數來源見「續 session 與跨介面接手」；Dispatch 使用 request 檔；`prepare_artifacts` 只能經 request 檔傳入 |
| 執行結束或中斷後 | `Inspect`，接著 `Collect` | 事件流、stderr、last-message、Preflight 結果與報告路徑；中斷時另回收逐單位保全檔 | 命令列參數 |
| 回收完成且不再續行 | `Cleanup` | 保存清單、RunRecord、報告與 evidence 路徑 | 命令列參數或 request 檔 |
| 查詢派遣進度（唯讀） | `scripts\Get-DispatchProgress.ps1` | `WorkRoot`、`LineSlug`、`DispatchSlug` 選填；`-All` 顯示全部紀錄 | 直接執行，預設顯示未結束與最近 24 小時內結束的項目 |

`~/.ai-agents/templates/dispatch/` 提供派遣單、Request、failure receipt、result envelope、Developer 結案報告、`exceptions.md` 與 Reviewer 報告的範本。派遣單以 `New-DispatchOrder.ps1` 產生為正常路徑，範本供手動核對結構；報告範本的必要區段以 Collect 與 Cleanup 的驗證為準。

正常路徑使用的正式 operation 為 `Dispatch`、`Inspect`、`Collect` 與 `Cleanup`；`DiagnoseModelEnvironment` 只供使用者或維運者診斷。`Preflight`、`Prepare` 與 `Start` 是 `Dispatch` 內部的階段轉移，命令列保留這三個 operation 供續行、恢復與測試使用，新的一筆派遣一律從 `Dispatch` 進入。

request 欄位先依 parser 白名單驗證，再依 operation 套用欄位作用域。識別欄位為 `schema`、`operation`、`line_slug`、`dispatch_slug`。其他一般白名單欄位為 `profile`、`advisor_request_source`、`target_path`、`add_directory`、`search`、`codex_parent_option`、`literal_values`、`prepare_artifacts`、`result_path`、`preflight_result_path`。共用根目錄欄位（`commonRootFields`）為 `source_root`、`dispatch_root`、`caller_session_id`。

`Dispatch` 專用欄位（`dispatchOnlyFields`）完整清單為 `write_mode`、`dispatch_kind`、`prompt_path`、`task_type`、`session_mode`、`unit_kind`、`requested_unit`、`continue_from_scope_plan`、`background`、`required_identifier`、`failure_receipt_path`、`prepare_result_path`、`evidence_pack_path`、`advisor_consult_report_path`、`selected_requirement`。`Cleanup` 專用欄位（`cleanupOnlyFields`）為 `run_record_path`、`reviewer_report_path`、`report_path`、`evidence_path`。`Dispatch` 不接受 Cleanup 專用欄位，`Cleanup` 不接受 Dispatch 專用欄位；其他 operation 不接受共用根目錄、`result_path`、`preflight_result_path` 或兩組 operation 專用欄位。`source_root`、`result_path` 與 `preflight_result_path` 只在 `Dispatch` 與 `Cleanup` 合法。同一欄位在 request 檔與命令列不一致時以 `DispatchRequestMismatch` 停止。

Request 的 `operation` 以不區分大小寫的方式驗證，解析後使用正式 operation 名稱；命令列與 Request 的 operation 比對也不區分大小寫。結果的 `dispatch_request` 會保存 Request 檔路徑、SHA-256、位元組長度、正規化 operation、line／dispatch identity、欄位 presence，以及共用、Dispatch 與 Cleanup 欄位的正規化值。陣列欄位另保存筆數、SHA-256 與值；`literal_values` 另有獨立 SHA-256。

Start 將 Request 檔路徑、SHA-256 與 operation 綁定至 RunRecord。advisor Inspect 會重新讀取 evidence pack，核對 Start 記錄的 SHA-256 與檔案長度，並在結果中回報 evidence pack 路徑與 hash；來源變更或內容不符時停止驗收。

### Caller Session 身分與併行准入

`Dispatch`、`Preflight`、`Prepare`、`Start` 與 `Cleanup` 依序解析 caller Session ID：Request 的 `caller_session_id`、CLI `-CallerSessionId`、環境變數 `CLAUDE_CODE_SESSION_ID`、環境變數 `CODEX_THREAD_ID`。Request 的 `caller_session_id` 欄位只在 `Dispatch` 與 `Cleanup` 的 Request 有效，其他 operation 的 Request 帶此欄位時以 `DispatchRequestFieldNotAllowed` 拒絕，改由 CLI 或環境變數提供。Request 與 CLI 同時提供時採用 Request 值。四個來源皆無有效值時，以 `CallerSessionIdMissing` 在 Prepare／Start 副作用前停止；空值或超過長度上限時以 `CallerSessionIdInvalid` 停止。既有 Claude 呼叫端可繼續由 `CLAUDE_CODE_SESSION_ID` 提供身分，不需修改 Request。

RunRecord、PID 記錄、結果與 admission ledger 保存 caller Session fingerprint 及來源名稱，不複製原始 ID。Ledger 位於 source root 的 history 目錄，所有讀取、比較與原子替換都在同一個短暫獨占鎖內執行。Start 在鎖內重做 PID identity check，啟動 Codex、寫入 PID 記錄並登記 owner，避免兩個入口同時通過檢查後重複取得名額。

同一 caller Session 可同時持有一個 write admission 與最多兩個 readonly admission。Worktree write 期間可執行同線 readonly 派遣。路徑衝突比對要求至少一方為 direct-write 目標；與其他派遣的 direct-write 目標或 `--add-dir` 權限路徑相同或有父子路徑關係時，新的 admission 以 `DispatchAdmissionPathConflict` 拒絕。各派遣所屬線的 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>` 目錄及其子路徑，只有在該 admission 的路徑為 `--add-dir` 時才排除於衝突比對外；direct-write 即使位於該處，仍與其他派遣的 direct-write 目標或 `--add-dir` 路徑進行父子重疊比對。`--add-dir` 對 `--add-dir` 可並行。第二個 write 以 `DispatchAdmissionWriteLimit` 拒絕，第三個 readonly 以 `DispatchAdmissionReadonlyLimit` 拒絕。`Inspect`（含 `-WaitForCompletion`）屬回收操作，不申請新的 admission，因此不受上述名額與路徑衝突限制。`Prepare`、`Start`、`Collect -ApplyCollectedChanges` 與 `Cleanup` 照常檢查。Ledger owner 身分無法確認時，新的 admission 與 Cleanup 皆以 `DispatchAdmissionOwnerUnknown` 拒絕。

`Cleanup` 以 ledger 的 caller fingerprint、line 與 dispatch 驗證 owner；提供 RunRecord 時另比對 RunRecord 的 caller fingerprint。Owner 不相符時預設以 `DispatchAdmissionOwnerMismatch` 拒絕並保留 worktree；歷史已結束派遣可依「已結束歷史派遣的 Cleanup 接手」明示例外。Workflow worktree 的 `Collect` 通過既有驗收後，可額外指定 `-ApplyCollectedChanges` 套用變更；套用前會在 source root 鎖內比對每個目標路徑的 baseline fingerprint，漂移時以 `DispatchSourceDrift` 停止並保留 worktree。為避免 dispatch worktree 依 `.gitattributes` 檢出的行尾與來源工作樹不同而誤報漂移，`Preflight` 在 `Apply-SourceCarryIn` 之後、建立 baseline 之前，對 dispatch worktree 內 Git 追蹤清單及尚未加入 index 的未追蹤清單所列項目，若來源工作樹同一路徑存在一般檔案且位元組長度不同，以來源的原始位元組覆寫目的檔。Windows 流程以不跟隨 reparse point 的方式開啟來源與目的檔案，確認 handle 類型與最終路徑分別符合正規化根目錄加相對路徑；目的檔為唯讀時，通過驗證後以 `FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES | FILE_FLAG_OPEN_REPARSE_POINT` 開啟目的屬性 handle，透過 `SetFileInformationByHandle(FileBasicInfo)` 只改動屬性欄位清除 `ReadOnly`，並以 `ReOpenFile` 取得寫入 handle。目的檔 handle 的 `NumberOfLinks` 大於 1 時一律以 hard link 別名拒絕；串流寫入失敗時，16 MiB 以內的目的檔會在同一 handle 回復原始位元組與長度，較大目的檔不先截斷，失敗可能留下部分覆寫內容；若失敗發生於最後的長度設定或 flush 後，檔案長度可能已是來源長度。流程在 `finally` 透過同一個已驗證的屬性 handle 還原原始屬性，目錄被 junction 置換時拒絕操作。非 Windows 遇到長度不同且需要覆寫的檔案時，會在寫入前以明確指出僅支援 Windows 的錯誤拒絕；長度相同時略過同步並保留原始 SHA-256 比對，位元組不同會判定漂移。機密檔名樣式及來源不存在的路徑會略過，處理清單包含 `git ls-files` 追蹤檔案與尚未加入 dispatch index 的未追蹤檔案。同步後 baseline 記錄與來源一致的起點，`Preflight` 後來源任何位元組變化（包含只有行尾變化）都由原始 SHA-256 比對判定為漂移。Direct-write 已直接修改 source root，使用 `-ApplyCollectedChanges` 時以 `DispatchCollectApplyDirectWriteNotApplicable` 拒絕。

## 最短正常路徑

一筆派遣依下列順序推進。每一步的產物是下一步的輸入，上一步未成功時不進入下一步。

| 步驟 | 動作 | 產物 | 下游接收者 |
| --- | --- | --- | --- |
| 1 | 產生派遣單（資源派遣），或確認 `design.md` 已通過 Design 驗收（Workflow） | 派遣單或 `design.md` | Prompt 與 Codex 執行端 |
| 2 | `Preflight` 驗證 LineContext、PID 與寫入面，決定 `executionRoot` | Preflight 結果 JSON | Prepare、Start、Collect |
| 3 | `Prepare` 將交接檔複製到 `executionRoot` 並比對 SHA-256 | `-PrepareResultPath` 寫出的 `ai-sessions.prepare.v1` 文件；`-ResultPath` 只寫 CLI envelope | Start 只接受 `ai-sessions.prepare.v1` 文件 |
| 4 | `Start` 建立 ScopePlan，背景啟動 Codex | Start 結果、事件流、stderr、last-message、thread id、PID 記錄 | 主 Agent 的等待與 Inspect |
| 5 | 等待完成通知，依「完成判定與三出口」判定出口 | 出口判定 | Inspect |
| 6 | `Inspect` 解析事件流與 last-message | `success`、`outputValid`、usage、model evidence | RecoveryPrecheck 與回收三態 |
| 7 | `RecoveryPrecheck` 通過後，`Collect` 核對成果與報告，主 Agent 判定回收三態 | Collect 結果與三態判定 | 續行、升級或同步 |
| 8 | 同步報告與核准交接產物，再執行 `Cleanup` | 保存驗證結果 | 結案報告 |

`Dispatch` 串接步驟 2 至 6。預設同步等待 Codex 結束後執行 Inspect，回傳 `completed` 或 `failed`；Request 設 `background: true` 時先回傳 `status=started`，只代表 Codex 已啟動，再以 `Inspect -WaitForCompletion` 等待。步驟 7 與 8 的回收判定由主 Agent 執行，派遣不再需要在 Session 內另寫 runner。

### AI-PROFILE 前置檢查

主 Agent 在建立派遣單或 Request 前，依 `ai-profile` skill 解析目標專案根目錄 `AGENTS.local.md`，並以該 skill「鍵登錄表」的「阻擋範圍」欄對照派遣內容，得出本次派遣所需的鍵。例如撰寫或修改 `*.cs`、`*.csx` 需要 `code-style.csharp`。

- 所需鍵有效時照常派工。
- 所需鍵缺少時，依 `ai-profile`「一次問完」詢問使用者（同一輪列出其他適用且缺少的鍵），寫入後再建立派遣。
- 區塊結構錯誤時，依 `ai-profile`「錯誤處置」停止並回報，不派工。
- 鍵的值錯誤時，只停止阻擋範圍涵蓋該鍵或依該鍵分流的派遣並回報；不依賴該鍵的派遣照常進行。

執行端仍以缺少鍵或格式錯誤停止時，主 Agent 先補齊或修正，再以新的派遣重新執行；此停止不屬純技術補件，不以續行帶過。

### git-workflow 分支符合性檢查

`dispatch_kind=workflow` 且 `sourceRoot` 為 Git 來源時，主 Agent 在建立派遣單或 Request 前，確認目前分支符合 `git-workflow` 註記的模式。資源派遣與非 Git 來源不適用本節。本節只使用唯讀命令。

| 步驟 | 動作 | 不符時 |
| --- | --- | --- |
| 1 | 依「AI-PROFILE 前置檢查」確認 `git-workflow` 鍵有效 | 依該節處置，補齊後才繼續 |
| 2 | 執行 `git -C <sourceRoot> branch --show-current`，輸出為空即 detached HEAD | 停止 |
| 3 | 以同線 `design.md`「實作任務清單」的 Phase 數判定線類型（與本次派遣選定幾個 Phase 無關），Phase 數 >= 2 為線分支，其餘為直接在整合分支 | 無法取得 Phase 數時停止 |
| 4 | 對照下表。表中的 `main` 指 `git-workflow` skill「主分支判定」的結果 | 停止 |

| 模式 | 線類型 | 期望 |
| --- | --- | --- |
| `trunk` | 直接 | 目前分支為 `main` |
| `trunk` | 線分支 | 目前分支為 `feature/<lineSlug>`；`sourceRoot` 是 linked worktree，即 `git rev-parse --git-dir` 與 `git rev-parse --git-common-dir` 的結果不同；upstream 為 `main` |
| `release-flow`，已有版本標籤 | 直接 | 目前分支符合 `^(release\|hotfix)/v[0-9]+\.[0-9]+\.[0-9]+$` |
| `release-flow`，已有版本標籤 | 線分支 | 目前分支為 `feature/<lineSlug>`；`sourceRoot` 是 linked worktree；upstream 符合上列 `release` 或 `hotfix` 命名 |
| `release-flow`，尚無版本標籤 | 直接 | 目前分支為 `main` |
| `release-flow`，尚無版本標籤 | 線分支 | 目前分支為 `feature/<lineSlug>`；`sourceRoot` 是 linked worktree；upstream 為 `main` |

版本標籤的判定依 `git-workflow` skill `references/release-flow.md`「版本標籤判定」。

upstream 以 `git -C <sourceRoot> rev-parse --abbrev-ref '@{upstream}'` 讀取。

不符時停止並回報目前分支、期望分支、模式與 `sourceRoot`，不建立派遣單與 Request，不執行任何建立或切換分支的命令。分支的建立依 `workflow-orchestration`「自動推進鏈」第 1 步「分支前置」，或由使用者決定。全部通過時照常派工。

### Dispatch 正式入口

- 單位自動產生：Workflow 依 `design.md`「實作任務清單」章（`## ` 開頭且含「實作任務清單」的章節）內的 `### Phase N` 或 `#### Phase N` 標題順序產生 `requested_unit`，找不到該章時才解析全文件；章內同編號連續小節合併為一個單位，非連續重複拒絕；資源派遣依 `<sourceRoot>\.local\ai-sessions\handoff\dispatch-order-<dispatchSlug>.md` 第 3 欄產生，Request 的 `target_path` 必須與該欄完全相符。明確提供的 `requested_unit` 必須是來源清單的有序子集合。來源與 Request 不一致時，入口在 Preflight、Prepare、worktree 建立與 Codex 啟動前拒絕，回傳 `operation: DispatchRequest`、`process_started: false` 與 `detail.differences`。Request 欄位驗證錯誤的 detail 只列欄位名稱、預期格式與輸入長度，不回顯原始輸入值。
- 派遣單目標路徑：第 3 欄若填入含 `dispatchSlug` 的 worktree 絕對路徑，改用新的 `dispatchSlug` 時需同步更新目標路徑並重產派遣單。目標位於 `sourceRoot` 且所選 sandbox 能直接讀取時，建議填穩定的 `sourceRoot` 絕對路徑。`targetsOutsideRepository` 只涵蓋 `sourceRoot` 內、位於 repository 外或被 gitignore 排除的路徑；`target_path` 一律必須位於 `sourceRoot` 內，超出時 Preflight 以 `DispatchOutputBoundary` 拒絕。此建議不改變 Request `target_path` 必須與第 3 欄完全相符的條件。
- 外部資料：唯讀取證需要讀取 `sourceRoot` 以外的路徑時，以 `sourceRoot` 內的題目檔為第 3 欄目標並使用 `readonly`，外部路徑以絕對路徑逐一列在第 4 欄。read-only sandbox 可讀取這些路徑，但它們不進入 `target_path` 與 ScopePlan，派遣報告須逐條列出實際讀取的外部路徑。不以 `write` 或 direct-write 承接唯讀取證。
- Prepare 自動帶入：同線 `line.json`、`requirement-summary.md`；`dispatch_kind=resource` 且 `write_mode=readonly` 的派遣在同線沒有 `requirement-summary.md` 時略過摘要，其他派遣缺摘要時拒絕。Workflow 另帶入 `design.md`，資源派遣在第 4 欄提及 `design.md` 時帶入，並把派遣單複製到 dispatch worktree 的同線 handoff。`prepare_artifacts` 只用於追加其他檔案。
- 輸出路徑安全：`result_path` 與 `preflight_result_path` 必須位於 SourceRoot 或 ExecutionRoot，root、既有各層目錄與寫入目標任一層為 reparse point 時拒絕；未指定時輸出到 ExecutionRoot 同線 history。需要 worktree 清除後仍可從來源工作樹取用時，明確指定 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>\` 下的路徑。`prepare_result_path` 的目的地限於 ExecutionRoot 的同線 handoff、report 或 history line root，且不得與 target path 重疊；未指定時輸出到 ExecutionRoot 同線 history。目錄建立後、實際寫入前會再次核對路徑。
- direct-write：Preflight 判定不建 worktree（`worktreeCreated=false`）時，Prepare 使用 Preflight 的 `executionRoot`（即 `sourceRoot`）作為 DispatchRoot，Request 的 `dispatch_root` 只用於路徑驗證；只寫同線 handoff 的資源派遣可直接使用正式入口。
- 必填檔位：`profile` 為必填，值限「檔位用途與新舊對照」列出的四個檔位。缺少時以 `DispatchRequestMissingField` 拒絕，指定 `default` 或其他名稱時以 `DispatchRequestInvalidValue` 拒絕，兩者皆在 Preflight 前停止且 `process_started=false`。
- 可省略欄位：`requested_unit`、`prepare_artifacts`、`background`（預設 `false`）、`required_identifier`（Workflow 預設 `design.md`，資源派遣預設第一個 target 的檔名；advisor-consult 沒有 target 時預設 evidence pack 檔名，Start 注入與 Inspect 比對使用同一個值）、`selected_requirement`（本輪選定需求，傳給 Workflow Collect）與各階段結果路徑。Request 帶 `quota_before_path` 或 `quota_after_path` 時以欄位不允許拒絕。
- 輸出欄位：`status`（`started`、`completed`、`failed`）、`completed_stages`、`failed_stage`、`error_code`、`error`、`process_started`、`process_exit_code`、`termination_reason`、`inspect_status`、`inspect_success`、`requested_units`、`result_path`、`result_sha256`、`inspect_result_path`。`Collect` 的參數取自這些欄位。所有 operation 的 JSON stdout 固定使用 UTF-8（無 BOM），不依 PowerShell host 的預設主控台編碼。

背景派遣的等待命令如下。`-WaitForCompletion` 等待 sidecar 確認 Codex 行程結束，再以事件流 terminal event 決定結果，沒有固定逾時。`-WaitForCompletion` 只接受 `Dispatch` 產生的 result（需含 `result_sha256`）；逐一呼叫 Preflight、Prepare、Start 的分步入口不能用它等待，改由執行環境的背景完成通知接手後呼叫 `Inspect`。

```powershell
.\scripts\Invoke-CodexDispatch.ps1 -Operation Inspect -DispatchResultPath <result_path> `
  -SourceRoot <source_root> -ExecutionRoot <execution_root> -LineSlug <line_slug> -DispatchSlug <dispatch_slug> `
  -TargetPath <target_path> -RequiredIdentifier <required_identifier> -WriteMode <write_mode> -WaitForCompletion
```

## 額度與範圍契約

派工路徑不取得也不保存額度。`Dispatch`、`Start` 與 `Inspect` 不建立額度快照，RunRecord 與 ScopePlan 不含額度欄位，advisor 執行期間也不監看額度。需要額度數值時，由主 Agent 或使用者以 `Get-CodexQuota.ps1` 手動查詢，例如派工前呈現額度、advisor 授權請求與帳號切換。

`Get-CodexQuota.ps1 -SnapshotPath <path>` 保留既有 key-value stdout，另外寫入 `ai-sessions.quota-snapshot.v1` JSON。有效快照包含 `captured_at_utc`、`state=Valid`，以及 `primary` 與 `secondary` 的 `used_percent`、`remaining_percent`、`window_minutes`、`resets_at` 與 `source_file`。回應缺少 `secondary_window`（欄位不存在或為 null）時，快照 `secondary` 與 `observations.secondary` 為 null，`state` 仍為 `Valid`。取得額度失敗時，快照檔仍以失敗的 `state` 與 `error` 寫出，stderr 輸出失敗類別。

### 主 Agent 的帳號切換決策

帳號由腳本選擇與更換，主 Agent 派工時不指定 `-CodexHome`。本節的判定不因 `codex_accounts` 登記的帳號數不同而不同，額度數值不參與帳號選擇。

- 選帳號：未指定 `-CodexHome` 且登記清單非空時，Dispatch 依登記順序取第一個已登入的帳號。登入判定只看帳號目錄登入檔的路徑、大小與修改時間，不讀內容；缺少該檔位設定檔的帳號同樣略過。帳號是否支援檔位的 model 以服務端回應為準，不在啟動前預判。
- 換帳號：未指定 `-CodexHome` 的 Dispatch 遭服務端拒絕（usage-limit、401 或 model not supported），且事件流尚無任何 item 進度時，腳本依登記順序改試下一個帳號，以 `<原 dispatchSlug>-r<n>` 的衍生 Request 冷啟動。重試只限換帳號，同一帳號不重送。
- 不換帳號：指定 `-CodexHome`、背景模式、續行、非拒絕失敗、已有 item 進度時，維持單次選派與原失敗結果。背景模式與續行被拒後，主 Agent 依摘要檔或 RunRecord 的 `codex_home` 以 `-CodexHome` 明確指定下一個帳號。
- 全數不可用：所有登記帳號都未登入或都被拒時，Dispatch 回報 `CodexAccountsAllUnavailable`，主 Agent 依 `instructions.md`「離線改派」將全部 Codex 執行者以 `-Offline` 傳入選派入口，依 `executor-selection` skill「狀態處置」處理。
- 摘要檔：每次經過換帳號外層的 Dispatch 寫入 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>\dispatch-account-failover-<dispatchSlug>.json`，列出候選、略過原因與每次嘗試的結果。失敗嘗試留下的 dispatch worktree 不自動清理，主 Agent 依摘要檔的 `dispatch_root` 以既有 `Cleanup` 處置。

腳本換過帳號時，主 Agent 依下列格式告知使用者，帳號名稱為本機別名，摘要檔使用絕對路徑。

```text
[帳號切換] 原帳號=<name>；新帳號=<name>；拒絕種類=<usage-limit|unauthorized|model-not-supported>；摘要檔=<絕對路徑>
```

### ScopePlan 單位

`ScopePlan` 是派工前唯一的範圍決策，欄位固定如下。

```text
dispatch_slug
dispatch_kind
task_type
requested_profile
session_mode
unit_kind
requested_units[]
selected_units[]
deferred_units[]
decision
decision_reason
```

`unit_kind` 只允許 `workflow-phase`、`resource-target` 與 `advisor-evidence-question`。Workflow 以 `design.md` 的 Phase 為最小單位，資源派遣以派遣單第 3 欄的目標物件為最小單位，advisor consult 以 evidence pack 內的問題 ID 為最小單位，`requested_units` 依宣告順序排列。`Start` 的 `RequestedUnit` 依 `unit_kind` 核對。`workflow-phase` 與 `resource-target` 須為宣告單位依宣告順序的有序子集，不符以 `DispatchRequestedUnitMismatch` 拒絕工作。`advisor-evidence-question` 須與 evidence pack 宣告的問題 ID 清單完整且依序相等，不接受子集，不符以 `EvidencePackUnitOrderMismatch` 拒絕工作。執行端不得自行增加或拆分單位。

`ScopePlan` 一律選取宣告的全部單位：`selected_units` 等於 `requested_units`，`decision=full`。ScopePlan hash 紀錄與續行範圍核對照常執行。續行時讀到舊格式 ScopePlan（仍含 `primary_remaining_percent`、`estimate_source` 等額度欄位）照常接受，額度欄位忽略，不帶入新的 ScopePlan。

`advisor-consult` 只在使用者授權後啟動，呼叫端以 `AdvisorRequestSource=user-explicit` 傳入；缺少授權時以 `AdvisorAuthorizationRequired` 拒絕並不啟動 Codex。授權後使用 evidence pack 的完整問題集。授權不略過 service rejection、evidence hash、read-only sandbox 與 process identity gate。

### 需求級成本累計

需求級成本累計依 [session-artifacts skill「需求級成本累計」](../../session-artifacts/SKILL.md#需求級成本累計) 辦理，派遣結束後的追加動作依該節第 2 項。

## Advisor consult resource dispatch

`advisor` 是意見評估角色。`Profile=advisor` 只接受 `TaskType=advisor-consult`、`DispatchKind=resource` 與 `WriteMode=readonly`；Workflow、寫入模式或其他 TaskType 在 Codex 啟動前以 `AdvisorImplementationProfileRejected` 拒絕，`TaskType=advisor-consult` 未搭配 `Profile=advisor` 時以 `AdvisorProfileRequired` 拒絕。

`TaskType=advisor-consult` 使用單一 evidence pack，schema 為 `advisor-consult.evidence.v1`，必須包含目標段落原文摘錄與來源位置、已知結論、待答問題、可能反證與邊界。advisor 執行端只可讀取該 evidence pack，不得探索 repository、讀取其他來源、修改檔案或寫入 report。

evidence pack 的內容契約如下，由建立 pack 的主 Agent 負責。

- 來源與版本：每段摘錄的 `source:` 寫完整絕對路徑與行號範圍，並附該檔的版本識別（commit SHA 或檔案 SHA-256）。摘錄來自其他線或其他專案時，另寫明來源所屬的 `lineSlug` 或 work-root，與本次 advisor 派遣的 `line-slug` 區分。
- 待答問題：每題要求可直接執行的建議，於問題或 `output-rules:` 要求回答建議行動、處理位置、主要取捨、驗收方式，以及假設與推翻條件。問題聚焦實質處置，不要求因果分析或歷史回顧。
- 可能反證：寫成可檢查的問題或條件，例如「若 X 成立，建議是否改變」，讓 advisor 能逐條回答，不只列出疑慮。
- 送出前，主 Agent 先寫下自己的判斷，回收後逐項對照顧問意見，同意或不同意都附理由，以「主 Agent 決定、依據、與顧問意見異同」記錄於同線 `exceptions.md`。顧問只提供另一視角，決策由主 Agent 或使用者作出。

同一問題需要追問或補充證據時，沿用原 `dispatchSlug` 的 thread 續談，問題 ID 不變。新增目標、新增來源、新增問題單位或需要不同權限時，建立新的 evidence pack 與新的 `dispatchSlug`；新問題使用新的問題 ID，不併入原派遣的問題集合。advisor 啟動的授權依 `instructions.md` §1.5 advisor consult 掛載點：先向使用者請求，使用者在當下 Session 授權後才派工，授權不延續到其他 Session，也不依額度縮小問題範圍。

advisor 的 worktree `Start` 仍必須提供 `PrepareResultPath`，且該檔案的狀態必須是 `Prepared`。`advisor-consult` 必須提供 `AdvisorConsultReportPath`，固定位於 `executionRoot\.local\ai-sessions\report\<lineSlug>`，檔名為 `advisor-consult-<dispatchSlug>.md`，不能改指 `sourceRoot` 的同線 report 或其他來源落點。

evidence pack 必須位於 `executionRoot` 內，並以 `schema: advisor-consult.evidence.v1`、相同的 `line-slug` 與 `dispatch-slug` 開頭。正文固定包含 `目標段落`、`已知結論`、`待答問題`、`可能反證` 與 `邊界` 五個區段。`目標段落` 內必須有非空的 `source:` 與 `excerpt:`；`待答問題` 至少列出一個 `question-<id>:`，並恰好列出一次非空的 `required-output:`；文件另以非空 `output-rules:` 說明回傳規則。`邊界` 內必須各有一行 `- allowed-input:` 與 `- forbidden-action:`，限制 advisor 只讀取該 evidence pack，禁止探索來源、掃描 repository、修改檔案與發動其他派遣。

`## 待答問題` 以穩定 ID 逐行列出問題，格式為 `question-<id>: <問題>`，ID 在同一份 pack 內不可重複，順序即 ScopePlan 單位順序。同一節必須恰有一行 `required-output:`，值以半形分號分隔，每個值符合 `^#{1,6}[ \t]+\S`；說明文字另寫在 `output-rules:` 行。範例如下。

```text
question-001: <第一個評估問題>
question-002: <第二個評估問題>
required-output: ## 中斷保全結論; ## 證據支持; ## 推論; ## 未決問題
output-rules: 每一個問題以 question-<id> 回報完成狀態
```

`required-output` 缺漏、重複、分行、含非 heading 值或混入說明文字時，Start 以 `EvidencePackRequiredOutputInvalid` 停止。Start 的 advisor 必要參數為 `AdvisorConsultReportPath`、`EvidencePackPath` 與 read-only 邊界；缺少必要參數時以 `RequiredParameterMissing` 停止並列出欄位名稱。`ProfileEvidenceUnknown` 只用於 profile 設定檔的 model 或 reasoning effort 證據不可證明，不承接參數缺漏或 evidence 格式錯誤。

request 的 `prepare_artifacts` 必須是 object array。PowerShell 以 `ConvertTo-Json` 序列化單一元素時可能把陣列塌縮成 object，該形狀會被拒絕；即使只有一個 artifact，也要保留陣列形狀。

`Start` 將 evidence pack 全文內嵌 prompt，以 `---BEGIN INLINE EVIDENCE PACK---` 與 `---END INLINE EVIDENCE PACK---` 包夾，並附 `evidence-pack-sha256` 與 `evidence-pack-length`。執行端依內嵌內容作答，不需讀檔；read-only sandbox 下以工具讀檔會被核准政策阻擋，只給路徑的 prompt 會產生沒有技術結論的回覆。Start 產生 prompt 後重讀確認全文、hash 與長度，不符時以 `EvidencePackInlineMismatch` 停止。evidence pack 的 `## 待答問題` 必須有一行 `required-output:`，以分號分隔列出最終訊息必須包含的 Markdown heading。`Inspect` 逐一確認這些 heading 存在且內容非空，任一缺少時 `outputValid=false`、`success=false`，advisor report 另列「Required output gate」小節。

執行端最後訊息在 `## 中斷保全結論` 內列出 `已完成單位：<問題 ID 清單>`。Inspect 只接受 `completed_units` 為 `selected_units` 的子集合，`deferred_units` 不得標記完成；safe point 缺失時報告記為 `completed_units=unknown`，不以 `selected_units` 推論完成，後續由既有執行鏈 anchor 判定續行資格。advisor report 保存 `requested_units`、`selected_units`、`deferred_units`、`completed_units` 與授權來源。

`Start` 只驗證並保存 evidence pack SHA-256，不建立 advisor report。`Inspect` 或回收步驟依事件流與 last-message 寫入同線 `report/<lineSlug>/advisor-consult-<dispatchSlug>.md`，`AdvisorConsultReportPath` 必須位於同線 `reportLineRoot` 且檔名固定為 `advisor-consult-<dispatchSlug>.md`。報告區分證據支持、推論與未決問題。Start 前後的 SHA-256 不一致或 Inspect 缺少 Start hash 紀錄時拒絕成功判定。

### 由 Dispatch 派遣 advisor

`Dispatch` 承接 advisor 的準備步驟，呼叫端不必先手動建立 evidence pack 副本。

- evidence pack 來源有兩種合法形式。(1) `evidence_pack_path` 指向 `sourceRoot` 同線 handoff 目錄內的既存檔且未提供 `prepare_artifacts`：`Dispatch` 自動複製到 worktree 的同線 handoff 並改綁副本，副本與來源的 SHA-256 一致。(2) `evidence_pack_path` 指向 `dispatchRoot` 或 `executionRoot` 內的目的路徑，且 `prepare_artifacts` 恰有一筆 `destination` 等於該路徑、`source` 為 `sourceRoot` 同線 handoff 的既存檔：Request 階段不要求目的路徑已存在，因為 worktree 在 Preflight 才建立，呼叫端無法預先放入檔案。位於 `dispatchRoot` 或 `executionRoot` 內卻沒有這一筆 `prepare_artifacts` 時，Request 驗證以 `AdvisorEvidencePackPrepareRequired` 拒絕，訊息列出兩條修正路徑。兩種形式都會檢查 reparse point；位於其他位置時以 `AdvisorEvidencePackSourceBoundary` 或 `AdvisorEvidencePackSourceLineBoundary` 拒絕。所有拒絕都發生在 worktree 建立前，不留下產物。
- 手動 `prepare_artifacts`：Request 提供 `prepare_artifacts` 時視為手動分支，`Dispatch` 不自動複製。`source` 或 `destination` 解析後等於 `evidence_pack_path` 的項目視為相符，唯一一筆相符時其 `destination` 成為 Start 使用的 evidence pack。`evidence_pack_path` 位於 `dispatchRoot` 或 `executionRoot` 內時，Request 驗證要求 `destination` 相符的項目恰有一筆，筆數不符一律在 worktree 建立前以 `AdvisorEvidencePackPrepareRequired` 拒絕；通過 Request 後，以 `source` 相符的項目多於一筆時，`Dispatch` 以 `AdvisorEvidencePackPrepareAmbiguous` 停止。
- Inspect 目標：advisor 的 Inspect 以 Start 回報的 evidence pack 副本路徑作為目標與識別字來源，不使用 Request 的 `target_path`。
- `target_path`：Request 仍必須提供，advisor 沒有其他目標物件時填 evidence pack 本身的來源路徑，缺少時以 `DispatchRequestMissingField` 拒絕。

Request 範例如下，欄位值為示意。

```json
{
  "schema": "ai-sessions.dispatch-request.v1",
  "operation": "Dispatch",
  "line_slug": "<lineSlug>",
  "dispatch_slug": "<dispatchSlug>",
  "source_root": "<sourceRoot>",
  "dispatch_kind": "resource",
  "write_mode": "readonly",
  "task_type": "advisor-consult",
  "target_path": ["<sourceRoot>\\.local\\ai-sessions\\handoff\\<lineSlug>\\advisor-evidence-<dispatchSlug>.md"],
  "profile": "advisor",
  "advisor_request_source": "user-explicit",
  "prompt_path": "<sourceRoot>\\.local\\ai-sessions\\handoff\\<lineSlug>\\<dispatchSlug>-prompt.md",
  "evidence_pack_path": "<sourceRoot>\\.local\\ai-sessions\\handoff\\<lineSlug>\\advisor-evidence-<dispatchSlug>.md",
  "advisor_consult_report_path": "<executionRoot>\\.local\\ai-sessions\\report\\<lineSlug>\\advisor-consult-<dispatchSlug>.md"
}
```

## Git 前置探針與 worktree 生命週期

所有派遣先呼叫 `scripts\Invoke-CodexDispatch.ps1 -Operation Preflight`。每次派遣必須取得上游傳入且已驗證的 `LineContext`。`lineSlug` 識別同一條線，包含需求線與 `adhoc` 線，`dispatchSlug` 識別單次派遣，兩者分屬不同名稱空間。缺少 `LineContext`、識別字不符合 `^[a-z0-9]+(?:-[a-z0-9]+)*$`，或 `line.json` 的 `line-slug` 與傳入值不一致時，腳本以非零結束碼停止，且不建立成功狀態。

| 欄位 | 路徑或用途 |
| --- | --- |
| `sourceRoot` | 使用者指定且已解析的 work-root 絕對路徑 |
| `lineSlug` | 協調者依 `instructions.md` §1.4「工作產物落點」登記的語意化線識別 |
| `writeMode` | 派遣單第 6 欄標示「唯讀」時為 `readonly`，其餘為 `write` |
| `sourceLineRoot` | `<sourceRoot>\.local\ai-sessions\handoff\<lineSlug>` |
| `dispatchRoot` | `<sourceRoot>\.local\ai-sessions\worktrees\<dispatchSlug>` 的隔離 worktree 目標絕對路徑 |
| `dispatchLineRoot` | `<executionRoot>\.local\ai-sessions\handoff\<lineSlug>` |
| `sourceReportLineRoot` | `<sourceRoot>\.local\ai-sessions\report\<lineSlug>` |
| `reportLineRoot` | `<executionRoot>\.local\ai-sessions\report\<lineSlug>` |

`Preflight` 先驗證 manifest、目錄界線與同線 PID，再依序判定 Git 探針、HEAD 與 target 狀態，依下表決定 `executionRoot`。Git 探針只有 exit code 為 0 且 stdout 為 `true` 時才視為 Git 來源並採用 `gitOrigin=existing`，其他 Git 錯誤以非零結束碼回報。腳本不會在來源目錄執行 `git init`，也不建立 `.gitignore`、commit 或 marker。非 Git 來源的 direct-write 與唯讀記為 `gitOrigin=not-applicable`。`gitOrigin=not-applicable` 時，Start 在 `exec` 子命令後加入 `--skip-git-repo-check`，讓 Codex 在非 Git 目錄啟動；Git 來源不加此旗標。

| Git 來源 | HEAD | `writeMode` | `dispatchKind` | target 狀態 | 結果 |
| --- | --- | --- | --- | --- | --- |
| 否 | 不適用 | `readonly` | 任一 | 任一 | 直接以 `sourceRoot` 執行，唯讀 sandbox，不建 worktree、不產生 Git 產物 |
| 否 | 不適用 | `write` | `resource` | 任一 | direct-write，`executionRoot=sourceRoot`、`worktreeCreated=false` |
| 否 | 不適用 | `write` | `workflow` | 任一 | 拒絕（`DispatchPreflightFailed`），Workflow 必須在隔離 worktree 執行 |
| 是 | 有 | `readonly` | 任一 | 任一 | 建立隔離 worktree |
| 是 | 有 | `write` | 任一 | 含既存 tracked 檔 | 建立隔離 worktree |
| 是 | 有 | `write` | `resource` | 不含既存 tracked 檔（未追蹤檔、Git ignored 範圍或全新輸出） | direct-write，`executionRoot=sourceRoot`、`worktreeCreated=false`，`baseSha` 為 HEAD |
| 是 | 有 | `write` | `workflow` | 不含既存 tracked 檔 | 拒絕（`DispatchPreflightFailed`），列出每個 target 的 `RelativePath`、`Exists` 與 `IsTracked` |
| 是 | 無 | `readonly` | 任一 | 任一 | 直接以 `sourceRoot` 執行，唯讀 sandbox，不建 worktree 與 baseline |
| 是 | 無 | `write` | 任一 | 任一 | 拒絕（`DispatchPreflightFailed`），提示先在 `sourceRoot` 建立基準 commit |

上表列出的拒絕分支都在建立任何產物前發生。`SourceRootNotGitRepository` 由 Git 基準建立步驟在 sourceRoot 不是 Git repo 時拋出；依上表分流，Preflight 不會讓非 Git 來源進入該步驟。若 `Preflight` 的 `target_path` 指向尚不存在的 dispatch worktree 內路徑，該路徑不會觸發 worktree 建立；需要建立 worktree 時，target 必須是 `sourceRoot` 內已存在且可辨識的 tracked 目標。直接寫入路徑仍須通過 sourceRoot 界線驗證。

目前不支援跨 Git root 的同線交接。寫入目標在原 work-root 之外時，拆成各自 sourceRoot 的工作線，交接時引用另一線的權威文件位置；不以複製 `line.json`、`requirement-summary.md` 與設計文件的方式延續同一條線，也不另設同步或雜湊比對流程。確有無法拆線且必須共用同一線狀態的需求時，再評估是否支援。

全新目錄的 Workflow 產出沒有任何 tracked target，Preflight 會拒絕。空目錄無法成為 tracked target，也不以無關檔案（例如 `.gitignore`）湊數。做法是主 Agent 先建立該工作本來就需要的最小基準檔案並 commit，Workflow 宣告的 target 實際涵蓋其中至少一個 tracked 檔案，再依現有規則建立 worktree 派工；沒有合理的基準檔案時，主 Agent 先完成必要的首版再交由 Workflow 接續。無 HEAD 的來源仍須先建立基準 commit。


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

## 腳本介面與執行前提

本地 session 需能執行 `git` 與 `codex`。機械流程由 `scripts\Invoke-CodexDispatch.ps1` 統一承接，主 Agent 仍負責 F1 路由、profile 選擇、使用者確認、任務分類、回收三態與升級判定；腳本驗證 ScopePlan、advisor evidence-only 邊界、thread relay 與安全中止。腳本只接受絕對路徑或可在已驗證根目錄內解析的目標路徑，並以 JSON 輸出結果。

| Operation | 主要參數 | 成功輸出 | 致命失敗 |
| --- | --- | --- | --- |
| `Preflight` | `SourceRoot`、`DispatchRoot`、`LineSlug`、`DispatchSlug`、`WriteMode`、`TargetPath[]` | `executionRoot`、`gitOrigin`、`baseSha`、`worktreeCreated`、`carryInManifest`（含 `excludedSecrets`）、`targetStates`、`targetsOutsideRepository`、同線目錄、`pidCheck` | manifest、PID、Git、根目錄界線、worktree、patch 或檔案複製驗證失敗時 stderr 並 exit code 1 |
| `Prepare` | `SourceRoot`、`ExecutionRoot`、`LineSlug`、`DispatchSlug`、`PrepareArtifacts[]`、`TargetPath[]` | 每個交接檔的來源／目的路徑與 SHA-256、`Prepared` 狀態 | 交接檔缺漏、越界、複製失敗或 hash 不符時 stderr 並 exit code 1 |
| `Start` | Preflight JSON 或 `ExecutionRoot`、`PromptPath`、`Profile`、`TaskType`、`InterruptionSafeguard`（舊參數 alias 為 `DowngradeInstruction`）、ScopePlan、Codex 父層選項；advisor 另需 `AdvisorConsultReportPath`、evidence pack 與 read-only 邊界；`AdvisorRequestSource` 必須為 `user-explicit` | `rootPid`、PID 記錄、事件流、stderr、last-message、thread id relay、ScopePlan、實際參數、有效 profile 與中斷保全狀態 | ScopePlan、evidence pack、執行檔、工作目錄、啟動參數或根程序身分驗證失敗時 stderr 並 exit code 1 |
| `Inspect` | `EventStreamPath`、`ProcessExitCode`、stderr、last-message、識別字、`Model`、`TaskType`、ScopePlan、thread id 路徑 | `completed`、`turn.failed` 原因、最後一則 `agent_message`、`usage`、`secret_exposure_suspected`、`secret_exposure_findings`、`recoverable_artifacts_present`、`recoverable_artifact_files`、`outputValid`、`success`、三層 model evidence、thread relay 與 advisor report | JSONL、thread id、必要輸入或證據包 hash 格式錯誤時 stderr 並 exit code 1 |
| `Collect` | `DispatchKind`；worktree 回收使用 `DispatchRoot`、`BaseSha`、`ReportPath[]`，`-ApplyCollectedChanges` 套回核准 target；direct-write 使用 `PreflightResultPath`、`ReportPath[]`；`DispatchKind=workflow` 另必須提供 `RequirementSummaryPath`，可選 `SelectedRequirement`（例如 `#22`）；回收 Reviewer 時另提供選用的 `ReviewerReportPath` | worktree 的 tracked／staged／未追蹤差異（`allFiles` 不含 carry-in；另列 `carryInFiles`、`newFiles`、`rejectedFiles` 與 `unappliedNewFiles`），或 direct-write 的核准輸出檔案證據與報告證據；目錄型 target 至少一個非空檔，逐檔記錄長度、最後寫入時間與 SHA-256；兩者都含依 `DispatchKind` 選用的報告核對結果；提供 `ReviewerReportPath` 時另含 `reviewerFindings`（`valid`、`conclusion`、九個 unique 計數 `previous_closed_count`、`previous_open_count`、`previous_withdrawn_count`、`previous_accepted_count`、`current_new_count`、`current_open_count`、`current_closed_count`、`current_withdrawn_count`、`current_accepted_count`，以及 `duplicate_ids`、`inconsistencies`） | worktree 的差異清單或 direct-write 的核准輸出、檔案證據、報告不一致時 stderr 並 exit code 1；Start 時不存在的核准 target 檔沿用 baseline `exists=false` 做來源 drift 檢查，包含被 gitignore 排除的核准新檔；核准目錄新增且未被 gitignore 排除的子檔（包含 Start 時不存在的核准目錄）以 add 套回並檢查來源 drift；target 外新增檔列入 `unappliedNewFiles` 且不套回；來源路徑出現同名檔或內容 drift 時以 `DispatchSourceDrift` 拒絕套回；缺少 `DispatchKind` 或空 `baseSha` 被當成 Git 基準時同樣停止 |
| `Dispatch` | `-RequestPath` 指向 `operation=Dispatch` 的 request 檔；未提供 request 檔時拒絕 | `Preflight`、`Prepare`、`Start` 與 `Inspect` 的階段結果，以及 `status=completed` 或 `failed` 的 dispatch envelope；`background: true` 時回傳 `status=started`，Inspect 以 `-WaitForCompletion` 另行等待；Collect 另行呼叫 | 單位核對失敗時於任何副作用前拒絕；request、Preflight、Prepare、Start 或 Inspect 任一階段失敗時 stderr 並 exit code 1 |
| `Cleanup` | `SourceRoot`、`ExecutionRoot`、`DispatchRoot`、`LineSlug`、`DispatchSlug`、RunRecord、`ReportPath[]`；省略 `EvidencePath[]` 時保存 RunRecord 引用且位於 worktree 的既存證據，明列時只接受該 RunRecord 引用的檔案。`ReportPath[]` 與 `EvidencePath[]` 以 `-RequestPath` 傳入 `operation=Cleanup` 的 JSON 陣列，欄位分別為 `report_path` 與 `evidence_path` | 已完成保存驗證且移除目標 dispatch worktree 的結果，包含 0 位元組證據的長度與 SHA-256；自動保存 report 根目錄的 `dispatch-report-<dispatchSlug>.md` | 保存清單、路徑界線、進程或移除驗證失敗時 stderr 並 exit code 1；首次盤點後於移除前再次核對 report 根目錄；新增且未列入保存清單的檔案以 `preservation-failed` 拒絕並列出路徑，且保留 dispatch worktree；未引用的 EvidencePath 錯誤列出可接受清單；失敗時保留 dispatch worktree，不得使用其他方式強制移除 |
| `DiagnoseModelEnvironment` | `ThreadId`、`StartedAtUtc`、`Profile`；`CodexHome` 選填 | profile 設定值、actual model／reasoning effort 與 rollout 路徑的 JSON；證據不足時 actual 為 `unknown` | 缺少 `ThreadId` 或 `StartedAtUtc` 時 exit code 1。只由使用者或維運者明確呼叫，Dispatch、Start、Inspect 不呼叫 |

`Preflight` 的 `executionRoot` 分流依「Git 前置探針與 worktree 生命週期」的決策表。direct-write 回傳 `executionRoot=sourceRoot`、`worktreeCreated=false` 與核准輸出清單；`baseSha` 在非 Git 來源為空，在有 HEAD 的 Git 來源為 HEAD。建立 worktree 時先固定 `baseSha`，再套用 tracked patch 與複製未追蹤檔案。腳本遇到衝突會停止，不以空清單或來源覆寫表示成功。`Collect` 必須消費同一份 Preflight 輸出，依 `worktreeCreated` 選擇 Git 差異或 direct-write 檔案證據路徑。

`readonly` 且建立 worktree 時，`Preflight` 檢查每個 `target_path` 是否位於 dispatch worktree repository 內且未被 gitignore 排除。範圍外路徑列入 `targetsOutsideRepository`；`Start` 將清單寫入 prompt，要求執行端直接讀取這些路徑，不經 Git 狀態盤點。對未被忽略的目錄 target，`Preflight` 逐檔檢查來源目錄中的子檔，個別被 gitignore 排除的檔案也逐一列入清單；遞迴盤點會略過 ReparsePoint。

`targetStates` 記錄每個 target 的類型。已存在的路徑依實際類型記錄；新 Preflight 的缺席路徑依輸入結尾的 `\` 或 `/` 判定為目錄或精確檔案。舊版 Preflight 結果缺少 `TargetKind` 時，若 `Exists=true`，`Collect` 依 source 與 dispatch 路徑的實際狀態推斷並標示 `kind_source=inferred`；若 `Exists=false`，固定視為精確檔案，不依輸入分隔符號推斷目錄。`Collect` 發現派遣端類型與記錄類型不一致時，以 `CollectTargetKindChanged` 拒絕，包含 file 變成 directory 或 directory 變成 file；類型一致的目錄 target 維持子檔套回行為。

`Start` 會固定 `--cd`、`--sandbox`、`--profile`、`--add-dir`、`--search` 等父層選項的位置，再執行 `codex exec` 或同一 thread 的 `codex exec resume`。`--json`、`--output-last-message` 與 prompt 選項位於子命令之後。事件流、stderr、last-message、thread id 與 PID 記錄各自保存，啟動結果包含實際參數，供後續複核。

`Start` 每次都加入 `InterruptionSafeguard` prompt。收到 `Profile=advisor` 時先執行 advisor profile 與 TaskType gate，再確認 `AdvisorRequestSource=user-explicit`；`TaskType=advisor-consult` 使用 evidence pack 與完整問題單位。中斷保全不改變 profile，也不作為換檔出口。

`Inspect` 逐行解析 JSONL。空白行略過。非空行若無法解析為 JSON，或缺少有效的非空字串 type，Inspect 以非零結束碼拒絕成功結果；原始事件流保留在原始事件流來源檔，壞行只留在原始事件流，不複製到 stdout、stderr、結果 JSON、診斷物件或報告。結果的 error 與 failure 只含固定錯誤碼、事件流絕對路徑與行號；不輸出解析器訊息、來源片段或原始例外，也不以壞行後的事件繼續計算成功結果。

`Inspect` 保存事件流、usage、三層 model evidence（不主動探測 actual）、thread relay 與 advisor report。

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
| `resolved` | 實際 profile 設定檔的 top-level `model`、`model_reasoning_effort`；各檔位讀 `<CodexHome>\<檔位>.config.toml` | 檔案不存在、欄位缺少、格式錯誤或重複衝突 |
| `runtime_verifiable` | 公開可查的 actual evidence。Dispatch、Start 與 Inspect 不主動探測 rollout | 沒有公開可查證據時為 `status=unknown`、`source=public-actual-unavailable`，不複製 requested 或 resolved 值 |

明確 assertion 與 resolved 值衝突時，Start 在啟動前以 `RequestedResolutionMismatch` 停止。Inspect 不修改 RunRecord 的 model evidence，也不回傳 rollout 路徑；actual 為 unknown 不使 Inspect 以非零結束。CLI 缺失或正式啟動失敗時，RunRecord 記 `launch_state=launch-failed`、`started_at_utc=null`，Dispatch 結果為 `status=failed`、`failed_stage=start`、`process_started=false`，`completed_stages` 不含 start。

需要確認實際使用的 model 與 reasoning effort 時，由使用者或維運者明確執行診斷 operation，派工流程不呼叫它：

```powershell
pwsh -NoProfile -File .\scripts\Invoke-CodexDispatch.ps1 -Operation DiagnoseModelEnvironment `
  -Profile <檔位> -CodexHome <CodexHome> -ThreadId <thread-id> -StartedAtUtc <UTC-ISO-8601>
```

`ThreadId` 與 `StartedAtUtc` 必填，`CodexHome` 省略時依 `CODEX_HOME` 或使用者的 `.codex` 目錄解析。輸出 JSON 含 `profile_model`、`profile_reasoning_effort`、`actual_model`、`actual_reasoning_effort` 與 `rollout_paths`；找不到精確對應的 session 或時間證據不足時，actual 的 `status` 為 `unknown`，不以 profile 設定值代填。

派工腳本的回歸測試以 `scripts\tests\Test-DispatchRecoveryBinding.ps1 -Phase <1-9>` 單一入口執行，入口會依序在 Windows PowerShell 5.1 與 pwsh 7 執行並彙整結果，任一環境失敗即整體 exit 1。Phase 9 可選附加 `-SkipPhase9Diagnostic`；主組失敗時跳過診斷重跑並標示 `diagnostic_skipped=true`，省略參數時維持既有診斷行為。回收覆核時執行此入口，不需另外分別呼叫兩個執行環境。

`Collect` 在 worktree 路徑合併 `git diff <baseSha>`、`git diff --cached` 與 `git ls-files --others --exclude-standard` 的檔案清單。報告核對方式依 `DispatchKind` 分流：`workflow` 以結案報告「Phase 對照」節逐項比對檔案清單，並以「需求對照」節比對 `RequirementSummaryPath` 的需求項目編號，`resource` 只確認報告存在且非空並回傳其長度與 SHA-256。「需求對照」核對要求需求摘要同時具備 `## 程式面項目` 與 `## 功能面項目` 兩節，兩節表格的 `#` 編號合併後不得重複，且每個編號在結案報告「需求對照」表格恰有一列 `#<n>`；表格固定 6 欄（需求、驗收方向、T-code、實際行為、證據、狀態），以未跳脫的 `|` 切欄，每欄非空，狀態為四個合法值之一。缺節、摘要編號重複、缺列、重複列、多出摘要沒有的編號、欄數不符或欄位為空時，以非零結束碼停止並列出不符的編號。此核對只驗結構完整，不判定內容是否正確，內容一致性由 Reviewer 的需求對照核對負責。resource 的結案要求是逐條驗收，不逐 Phase 列出檔案清單，對它要求「Phase 對照」節會使每次資源派遣都無法回收。direct-write 路徑則讀取 Preflight 的 `targetStates`，確認每個核准輸出都存在、為非空檔案，並回傳檔案長度、最後寫入時間與 SHA-256。任一數量、路徑、檔案證據或報告不一致都停止回收，且在成果尚未完成回收前不得移除 worktree。

交接物同步由獨立的 `Prepare` operation 執行（`ai-sessions.prepare.v1`）：只複製請求中明確列出、位於同線來源與允許目的根目錄內的檔案，逐一比對來源與目的 SHA-256，全部一致才標記 `Prepared`，任一缺件、越界或 hash 不符時標記 `PrepareFailed`。`Preflight` 不複製交接物，交接物只經由 Prepare 進入 worktree；建立 worktree 時的 tracked patch 與未追蹤檔案 carry-in 是工作區內容的同步，仍由 Preflight 執行，不屬於交接物複製。worktree 模式的 Start 必須收到 `Prepared` 結果，缺少或不一致時以 `PrepareRequired`／`PrepareArtifactMismatch` 停止；direct-write 使用 `status=not-required`。CodexHome 依序取顯式參數、`CODEX_HOME`、使用者目錄下的 `.codex`，實際值寫入 Prepare 結果、Start 輸出與 RunRecord。

跨程序傳入陣列參數（`TargetPath`、`AddDirectory`、`CodexParentOption`）時，以 `-RequestPath` 傳入 `ai-sessions.dispatch-request.v1` JSON 檔，陣列元素的原文與順序即契約，逗號、空白、中文與 `$` 不經 shell 展開或重新切分。Start 續行需要提供這些陣列時，也將 `target_path`、`add_directory` 與 `codex_parent_option` 寫成 JSON array，透過 `-RequestPath` 傳入 `operation=Start` 的 request；不得以逗號字串替代。`Cleanup` 的 `report_path` 與 `evidence_path` 同樣是陣列，須放在 `operation=Cleanup` 的 request 檔中。`powershell.exe -File` 無法以命令列傳遞字串陣列，逗號串接會被視為單一字串，跨 PowerShell 執行環境呼叫時一律使用 request 檔。request 檔與命令列同一欄位不一致時以 `DispatchRequestMismatch` 停止。

服務端以 usage-limit、401 或 model not supported 拒絕時，事件流以 `turn.failed` 結束，`Inspect` 依原始事件與 stderr 判定 service rejection 分類與拒絕種類。執行端保存已確認成果、證據位置與未完成單位，該次嘗試記為失敗，同一帳號不重送。未指定 `-CodexHome` 的 Dispatch 由腳本依「主 Agent 的帳號切換決策」改試下一個帳號；全部帳號被拒時回報 `CodexAccountsAllUnavailable`，才等待重設或依 `instructions.md`「離線改派」處理。

### 額度狀態

`Get-CodexQuota.ps1` 每次呼叫都向即時額度來源取得一份新觀測，快照 `state` 只會是下列三種之一。

| 狀態 | 判定條件 | 處置 |
| --- | --- | --- |
| `Valid` | 回應含合法 `primary` 視窗，沒有拒絕旗標；`secondary` 視窗缺少或為 null 時視為帳號沒有週視窗 | 呈現給使用者或作為帳號切換的依據 |
| `ServiceRejected` | 回應帶有額度拒絕旗標，或顯示已達上限但缺少 `rate_limit_reached_type`（此時 reached type 記為 unknown） | 該帳號不作為切換候選，等待重設 |
| `SnapshotUnavailable` | 認證資料缺漏、連線失敗、逾時、HTTP 非 2xx、缺少 `primary` 視窗、回應格式或數值範圍不合法 | 以非零結束碼停止，stderr 保留失敗類別，不產生估算值 |

observation 的 `freshness` 在寫入快照時依觀測時間距今判定，30 分鐘內為 `fresh`，超過為 `stale`。需要最新數值時重新執行一次查詢。

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

`write_mode=write` 且 sandbox 為 `workspace-write` 的新 cold-start，Start 自動在父層 `exec` 前依序加入下列 token，並記入 RunRecord 的 `parent_options.codex_parent_option`。非 Windows 平台只加入第一組。readonly、advisor 與 direct-readonly 不加入任何一組。

```text
-c sandbox_workspace_write.network_access=true
-c windows.sandbox="mxc"
-c shell_environment_policy.set.NUGET_HTTP_CACHE_PATH='<executionRoot>\.local\nuget\http'
-c shell_environment_policy.set.NUGET_PACKAGES='<executionRoot>\.local\nuget\pkg'
```

`mxc` 以 AppContainer 執行命令。elevated sandbox 內 Windows TLS 取不到憑證（openai/codex#31073），HTTPS 還原必須改用 `mxc`；`mxc` 內使用者目錄下的 NuGet http-cache 與全域套件目錄不可寫，因此改到 executionRoot 內較短的 `.local\nuget\`，避免套件路徑超過 260 字元；Windows 另需開啟 `LongPathsEnabled`（`Setup-AIGlobalConfig.ps1` 檢查）。`executionRoot` 含單引號時 Start 拒絕啟動。Request 的 `codex_parent_option` 以 `-c`、`--config` 或 `--config=` 形式自帶上述任一鍵時，Start 在啟動前拒絕。續行與網路能力邊界見 `references/execution.md` 的「續 session 與跨介面接手」及「網路能力硬邊界」。

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

1. 執行角色的觸發詞或 skill 名稱。Workflow 派工（`DispatchKind=workflow`，規則層目前沒有呼叫端，見「兩種派工差異」）使用 `Developer` 的觸發詞；資源派遣使用派遣單第 2 欄指定的角色或 skill。
2. Workflow 派工使用 `dispatchLineRoot\design.md` 的絕對路徑，資源派遣使用派遣單的絕對路徑。
3. `LineContext` 的 `lineSlug`、`sourceLineRoot`、`dispatchLineRoot`、`reportLineRoot`、`sourceRoot`、`dispatchRoot` 與相關產出落點的絕對路徑。
4. 回報格式、產出落點與驗收條件。Workflow 派工另須要求結案報告包含輪起點 SHA、開工基準線、「Phase 對照」節、「需求對照」節與「判定為既有實作而未動工」節，並列出 `sourceLineRoot\requirement-summary.md` 的絕對路徑供 Developer 產出「需求對照」節。「Phase 對照」節逐 Phase 列出該 Phase 實際修改的檔案清單，供主 Agent 依 Phase 分組建立 commit。續 session 必須重述前輪「Phase 對照」與「判定為既有實作而未動工」兩節的全部條目。

需要以結構約束結案報告時，另建立 JSON Schema 檔並加入 `--output-schema <FILE>`。該選項只約束最終回應的形狀，不改變事件流格式。

## 模型檔位規則

### 本機帳號清單與準備

`<本機 .ai-agents 根目錄>\.local\machine.json` 含 `ai-agents.machine.v1`、值班欄位，以及選用的 `codex_accounts` 與 `coordinator_session_id`；值班欄位與 `coordinator_session_id` 的說明見 `collect.md`「值班通知」的欄位表。

```json
{
  "schema": "ai-agents.machine.v1",
  "codex_accounts": [
    { "name": "account-a", "codex_home": "C:\\Users\\<使用者>\\.codex-account-a" },
    { "name": "account-b", "codex_home": "C:\\Users\\<使用者>\\.codex-account-b" }
  ]
}
```

名稱符合 `^[a-z0-9]+(?:-[a-z0-9]+)*$`，目錄使用已存在的絕對路徑。名稱與正規化路徑以不區分大小寫比較唯一性，reparse point 與同目錄別名拒絕。缺少清單或空陣列時沿用 CLI `-CodexHome`、程序 `CODEX_HOME`、`~/.codex` 優先序；未登記 home 的 `codex_account_name=null`。格式異常回報 `CodexAccountConfigurationInvalid`，由使用者修正，維持原選擇。

派工帳號由使用者以 `<本機 .ai-agents 根目錄>\scripts\New-CodexDispatchAccount.ps1 -Name <名稱>` 建立，`-ProjectPath <專案路徑>` 為選填，只用於預先信任專案。執行的 PowerShell 須具備建立 Symbolic Link 的權限（系統管理員，或已啟用 Windows 開發人員模式）。腳本建立 `~/.codex-<名稱>` 與最小 `config.toml`（指定 `-ProjectPath` 時另含專案信任段落），將 `.sandbox*` 與 `review`、`deep-review`、`scan`、`advisor` 的 `<檔位>.config.toml` 連結到 `~/.codex` 同名項目，並登記 `codex_accounts`；寫入前先完整預檢帳號目錄、`config.toml` 與各連結，任一項類型或目標不符時輸出找到的連結類型、目標、預期與只刪連結的修法，不寫入任何項目；重跑只補缺項並逐項回報狀態，既有一般檔案或目錄先改名為 `<名稱>.bak-<時間戳>` 再改建連結，指向其他目標的連結則報錯停止。主 Agent 遇到帳號缺件或 profile 類型錯誤時，回報使用者以此腳本修復，不自行建立帳號目錄或連結。Setup 逐帳號檢查 `config.toml` 與各檔位連結，四個必備檔位缺少、不是連結或指向他處時警示，殘留的 `default.config.toml` 只警示不刪除。腳本只輸出登入命令，使用者在只影響登入子行程的 `CODEX_HOME` 下自行執行 `codex login`；保留 Desktop 的預設 home 與使用者／機器環境變數。帳號閒置過久導致 `Get-CodexQuota.ps1` 或派工回報 401 時，請使用者以同一登入命令重新登入。

派工時，Dispatch 在選定帳號後、Preflight 前確認該帳號的 `config.toml` 已信任派遣來源專案，缺少時在 `<machine.json 所在目錄>\codex-account.lock` 鎖內補上信任段落，並在派遣結果的 `project_trust` 記錄帳號、設定檔路徑與信任鍵。信任鍵為來源專案的 git 主工作樹根，以小寫寫入；來源是 linked worktree 時取其主工作樹根，來源不是 git 目錄時取來源目錄本身。此步驟只處理 `machine.json` 登記的帳號，使用者預設的 `~/.codex` 與未登記的 home 維持原樣，且只信任專案根目錄。

自動選帳號時，`config.toml` 不存在、是連結或格式不支援的帳號在候選階段略過並改試下一個帳號，原因碼為 `TrustConfigMissing`、`TrustConfigLinked`、`TrustConfigUnsupported`，寫入換帳號摘要檔的 `skipped` 與派遣結果 `account_failover_summary.skipped`。已登記但只手動建立 home、缺少 `config.toml` 的帳號同樣略過，由使用者以建立腳本補齊。所有帳號都被略過或拒絕時以 `CodexAccountsAllUnavailable` 拒絕派遣，訊息附各帳號的略過原因。嘗試階段的拒絕碼為 `CodexAccountConfigMissing`、`CodexAccountConfigLinked`、`CodexAccountConfigUnsupported`、`CodexAccountConfigChanged`、`CodexAccountConfigWriteFailed`、`CodexAccountTrustLockTimeout` 與 `CodexProjectPathUnsupported`。指定 `-CodexHome` 時設定異常直接拒絕，不改選其他帳號；`CodexAccountConfigChanged`、`CodexAccountConfigWriteFailed`、`CodexAccountTrustLockTimeout` 與 `CodexProjectPathUnsupported` 屬暫時性或全域性問題，該次嘗試失敗且不換帳號。主 Agent 回報使用者以建立腳本或只刪連結的修法處理，不自行編輯 `config.toml`；各碼的處置見 `recovery.md`「失敗與恢復導引」。

主 Agent 不指定 `-CodexHome`，登記清單非空時由腳本選第一個已登入帳號，不依賴 `~/.codex` 的回退解析（該目錄供 Codex Desktop 使用，不登記為派工帳號）。`Dispatch -RequestPath <Request> -CodexHome <清單中的目錄>` 只用於續行、背景模式後改派與使用者要求；指定的登記帳號未登入時以 `CodexAccountNotLoggedIn` 拒絕，不改選其他帳號。Dispatch 在 Preflight 與 Prepare 前固定 home/name，Start 明設專用 ProcessStartInfo 的 `CODEX_HOME`，RunRecord 的 `codex_home`、`effective_codex_home`、`profile_config_path` 與 `codex_account_name` 採同一選擇。同一次執行不追隨清單變更。新增程式碼與 Agent 只處理目錄、設定與環境，不讀取、輸出或搜尋任何憑證檔內容；對憑證僅可取得路徑、檔名、大小及修改時間。保留既有 Get-CodexQuota.ps1 行程內、不輸出憑證值的認證途徑。

本機唯讀證據為 `codex-cli 0.159.0` 的 `codex --help`，`--profile` 說明為將 `$CODEX_HOME/<name>.config.toml` 疊加於基礎使用者設定。派工帳號 home 的基礎 config 最小必要設定已實測（缺少 config.toml 時沒有 Windows sandbox 設定，派工的命令因需要核准而被執行政策拒絕；補上 windows.sandbox 與專案信任後可執行，內容見 README），各 home 的 profile 為指向 `~/.codex` 同名檔案的 Symbolic Link，`--profile` 經由連結讀取，保留既有 profile/model hash gate。

### 檔位用途與新舊對照

本 Skill 使用四個語意檔位，Request 的 `profile` 取自選派入口輸出的 `executor.profile`，腳本不依任務類型自動選用。各檔位的實際 model、effort 與其餘設定以 `<CodexHome>/<檔位>.config.toml` 為準，各設定檔均可保留 `[agents]` 區段，規則層只傳遞語意檔位名稱。

| 檔位 | 用途 |
| --- | --- |
| `review` | 未達大範圍條件的 Codex `Reviewer` 審查（`type=review`、`Deep=false`） |
| `deep-review` | 規則檔機制條款的審查（不論檔數），或審查範圍達 3 個檔案以上（`type=review`、`Deep=true`），旗標定義見 `executor-selection` skill |
| `scan` | 測試（煙霧驗證取證，`type=test`）、事實校閱與上網查證（`type=factcheck`）、影像產生（`type=generate`） |
| `advisor` | 意見評估（`type=advise`），授權與 gate 見「Advisor consult resource dispatch」 |

已移除的 `default`、`implement`、`intensive` 檔位不能續行，續行呼叫必須帶上表的檔位名稱，與錨點不同而以 `ParentOptionsMismatch` 拒絕，需要繼續時以新 `dispatchSlug` 冷啟動。
`Inspect` 與 `Collect` 不經檔位白名單，照常讀取舊 RunRecord。統計舊 RunRecord 時依派工角色換算檔位：reviewer 對應 `review`，scan、verify、probe 對應 `scan`；developer、support 的舊紀錄只供讀取，不換算到現行檔位。

殘留的 `~/.codex\default.config.toml` 與各派工帳號目錄內指向它的連結不再被讀取，Setup 只偵測並警示。手動清理時先以 `Remove-Item -LiteralPath <帳號目錄>\default.config.toml` 刪除各帳號內的連結，只移除連結本身，再由使用者決定是否刪除 `~/.codex\default.config.toml`。

`codex exec` 與 `codex exec resume` 屬 runtime command，接受 `--profile`。檔位以 `--profile <檔位名稱>` 傳遞，放在 `exec` 子命令之前，讀取 `<CodexHome>/<檔位名稱>.config.toml`。任一檔位的設定檔不存在時以 `ProfileEvidenceUnknown` 在啟動前拒絕，不回退其他檔位。`Dispatch`、`Start` 與 `DiagnoseModelEnvironment` 未指定檔位時，Request 路徑以 `DispatchRequestMissingField`、程序內與 CLI 路徑以 `ProfileRequired` 拒絕。

派工不在每次啟動前執行探針。正式啟動本身就是參數與檔位的驗證：啟動參數不合法、檔位設定缺漏或 CLI 缺失時，Start 以未啟動結果回報（`launch_state=launch-failed`、`process_started=false`），不產生已啟動紀錄，修正後以新的 `dispatchSlug` 重派。

探針只用於下列明確診斷情境，由使用者或維運者主動執行，不掛回 Dispatch 前置流程。

| 探針 | 使用時機 | 證明範圍 |
| --- | --- | --- |
| 版本檢查（`codex --version`） | 安裝或更換環境時 | CLI 可執行，不證明啟動參數合法 |
| 機制探針 | 修改派工腳本或流程後 | 路徑、prompt 傳遞與事件流解析可運作 |
| `DiagnoseModelEnvironment` | 需要確認實際使用的 model 與 reasoning effort 時 | profile 設定值與 rollout 中的 actual 證據 |

`--help` 在參數驗證前短路輸出，不具參數證明力。四個語意檔位以外的臨時驗證檔位，名稱與內容由使用者提供，規則層不預設其存在，也不用於派工。

`advisor` 適用於推理密集且判斷資料可事先整理成 evidence pack 的意見評估，例如方案取捨、結案或續優化判斷與設計疑點評估。實作、例行編輯、步驟完整的任務、單一命令驗證、大量讀寫或掃描由 `executor-selection` skill 選出的 Claude 執行者處理，不以 `advisor` 執行。

`advisor` 相對其他檔位的實際差異由設定檔的差集決定，不由本文件斷言。說明諮詢價值前，先讀取 `<CodexHome>/advisor.config.toml` 與 `<CodexHome>/review.config.toml`，比對兩者的 `model`、`model_reasoning_effort` 與其餘鍵。

### advisor 的前置準備

各檔位的成本與推理特性由該檔位設定檔的 model 與 effort 決定。`advisor` 的實測成本基準為一小時即可用完整個 `primary` 5 小時視窗。這項數據只用來估計諮詢規模。

降低成本的方式是減少執行端自行探索的讀取量，不是縮小任務範圍。檔位本身的成本特性由本機檔位設定決定，設定方式見 README 的 Codex profile 檔位設定章節。

派工前完成下列準備。準備不足時 `advisor` 會把額度花在自行摸索，而不是產出結論。

- 派遣單第 3 欄逐一列出目標物件的絕對路徑，不使用目錄萬用字元，避免執行端自行決定讀取範圍。
- prompt 明列已知結論、已讀過的檔案與不需重讀的部分，讓執行端直接進入判斷。
- 需要限制讀取量時，在 prompt 明文要求單一 agent 執行並說明理由。執行端派生 subagent 時每個 subagent 各自消耗額度，讀取量隨並行數累加。
- 每次派工都注入中斷保全指示，要求先寫出已確認的結果並註明實際覆蓋範圍，於安全點保存結論與證據。服務端因額度拒絕而中止時，已保存的部分成果仍可交付。

續行必須沿用初始啟動的完整父層選項，包含 `--profile`，跨檔位續行不成立。所有續行仍注入中斷保全指示，並沿用同一份 `ScopePlan` 與保全狀態。

### 額度快照

`~/.ai-agents/scripts/Get-CodexQuota.ps1` 以 Codex home 的 `auth.json` 取得認證標頭，向 `https://chatgpt.com/backend-api/wham/usage` 取得即時額度，這是額度快照的唯一來源。回應必須含 `primary` 視窗；`secondary` 視窗存在時同樣換算，缺少或為 null 時表示帳號沒有週視窗。每個視窗換算為 `used_percent`、`remaining_percent`（`100 - used_percent`）、`window_minutes`、`window_days`（`window_minutes / 1440`）與 `resets_at`（Unix timestamp，秒）。`source_file` 記錄端點與請求時間，不是本機檔案路徑。不得讀取或輸出 `auth.json` 的任何欄位值；認證資料缺漏或格式錯誤時，腳本只回報欄位名稱與檔案路徑。

快照檔一律以新檔寫入。`Get-CodexQuota.ps1 -SnapshotPath` 以排他建立開檔，目標已存在時以 `QuotaSnapshotTargetAlreadyExists` 停止且不覆寫，呼叫端每次查詢使用新的檔名。

快照只代表取得當下的用量。兩個視窗由所有檔位共用，不依模型分別計量。`advisor` 單次派遣可能在數十分鐘內耗盡整個 `primary` 視窗，需要掌握時由主 Agent 在派工前後手動查詢。快照不論 `state` 為何都不改變派工範圍，也不停止派工。

兩個視窗都是固定視窗，`used_percent` 在視窗內單調累積，跨過 `resets_at` 後歸零並跳至下一格，額度不連續回補。有週視窗的帳號，`primary` 為 5 小時視窗，`secondary` 為 7 天視窗，容量相差約 33 倍，因此同一件任務在 `primary` 消耗的百分點約為 `secondary` 的 30 倍。沒有週視窗的帳號，`primary` 視窗長度不固定，曾實測為 30 天（`primary_window_minutes=43200`）。視窗長度一律以 `window_minutes` 為準。

腳本成功時依序輸出下列兩組 key-value。帳號沒有週視窗時，以單行 `secondary_window=none` 取代 `secondary_*` 八行。主 Agent 以同一次讀取的 `primary_remaining_percent` 與 `secondary_remaining_percent` 向使用者呈現額度，例如附在 advisor 授權請求中。

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

`Inspect` 預設唯讀，不寫入額度或推薦訊號。

1. 主 Agent 先判斷工作是否屬意見評估，且判斷資料可整理成 evidence pack。其餘工作的檔位取自選派入口輸出的 `executor.profile`，審查依 `Deep` 旗標為 `review` 或 `deep-review`，測試與事實校閱為 `scan`。
2. 屬意見評估時，主 Agent 先向使用者提出 advisor 授權請求；使用者同意後以 `AdvisorRequestSource=user-explicit` 派工。使用者在當下 Session 已明確授權「送顧問不必詢問」時，同一 Session 內直接以 `user-explicit` 派工，該授權不延續到其他 Session。
3. 額度只供顯示與紀錄，由主 Agent 手動查詢，時點為派工前、advisor 前、結案時與按需查詢；派工腳本不自動查詢。查詢失敗記為 unknown，派工照常進行。
4. 所有出口都注入 `InterruptionSafeguard`，保留已確認結論、證據位置、未完成單位與不可推論內容。續行沿用原始 thread、父層選項與 ScopePlan。
5. 以 `advisor` 派工而 `advisor.config.toml` 不存在時，停止該次派工，不使用隱式 profile fallback。
6. 每次派工都在 Request 明確指定檔位，名稱限「檔位用途與新舊對照」的四個語意檔位，臨時驗證檔位不進入派工判定。

### 決策歸屬

檔位由主 Agent 於派工當下決定。主 Agent 保留派工前查詢到的兩個視窗剩餘額度與任務難度判定，供回報與後續複核使用。

### advisor 授權請求

主 Agent 判斷值得諮詢時，在派工前輸出單行授權請求，格式如下。

```text
[advisor 諮詢授權] primary 剩餘 <n>%、secondary <剩餘 <m>% 或 無週視窗>；<需要 advisor 的具體理由>。是否執行 advisor 諮詢？
```

理由必須指出該評估的推理密集點與 evidence pack 已整理完成的依據。只寫「問題較難」或「需要深入分析」不構成理由。請求文字本身不構成授權證據；使用者明確同意後，以 `AdvisorRequestSource=user-explicit` 送出派工。使用者未回覆或未明確同意時不發動 `advisor`，不等待也不重複詢問。
檔位判定不得只依 exit code 推論 profile 已生效，必須同時確認啟動參數與產出證據。

## 兩種派工差異

共用本 Skill 的機制。Workflow 派工與資源派遣只以輸入、產出與結案要求區分；兩者都先使用 `Preflight` 依寫入面選擇 dispatch worktree 或 `sourceRoot`。

| 面向 | Workflow 派工（`DispatchKind=workflow`，規則層目前沒有呼叫端；Workflow Phase 由 Claude 執行者承接，不經本 Skill） | 資源派遣（Codex 的測試、審查、顧問、事實校閱、影像產生） |
| --- | --- | --- |
| 必備輸入 | `dispatchLineRoot\design.md` 絕對路徑 | `executionRoot\.local\ai-sessions\handoff\dispatch-order-<dispatchSlug>.md` 派遣單絕對路徑 |
| 產出落點 | `reportLineRoot\implement-closure-report.md`，回收後同步至 `sourceReportLineRoot` | `executionRoot\.local\ai-sessions\report\dispatch-report-<dispatchSlug>.md`，回收後同步至 `sourceRoot` |
| 結案要求 | 「驗證證據」節的輪起點 SHA 與開工基準線皆有值，「Phase 對照」節逐 Phase 列出修改的檔案清單，且「需求對照」節涵蓋需求摘要的全部項目編號 | 先通過 `RecoveryPrecheck`，再逐條執行派遣單第 5 欄的命令並得出「收下」、「退回」或「升級」之一 |

`requirement-summary.md` 是跨派遣的持久交接檔，固定於 `sourceLineRoot\requirement-summary.md`；覆寫前備份固定於 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>`。這兩個來源落點不屬於 `dispatchRoot` 的派遣產出，資源派遣若需寫入它們，必須在 `exec` 子命令前以 `--add-dir` 分別授權來源線層 `handoff` 與 `history` 目錄。

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
| 7 | 產出落點 | 報告或產物的絕對路徑。建立 dispatch worktree 的資源派遣，此欄必須是 executionRoot（dispatch worktree）內的路徑，因為執行端 sandbox 無法寫入來源樹；指向來源樹的路徑在 `Preflight` 以 `DispatchReportPathOutsideExecutionRoot` 拒絕，回收後由 `Cleanup` 同步至來源。direct-write 派遣的 executionRoot 等於 sourceRoot，不受此限 |
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

派遣單第 5 欄列入建置或測試命令時，依派遣的寫入模式決定執行者。write 派遣由執行端執行並回報原始輸出；需要還原套件時，依「網路能力硬邊界」使用 shell 網路，連線失敗時回報受阻。readonly 派遣不執行建置或測試，該條由執行端回報「未執行」，由主 Agent 依補驗規則處理。

自我測試涵蓋三類失效，這三類的共同特徵是命令正常結束、exit code 符合預期，只有輸出是空的或結論是錯的。

| 失效類型 | 實例 | 自我測試如何攔截 |
| --- | --- | --- |
| 模式寫錯導致永遠無匹配 | `rg` 的 `\|` alternation 與 CRLF 下的 `$` 錨點 | 未修改狀態下應有匹配卻回報無匹配 |
| 門檻寫錯導致條件恆真 | 以「縮排不超過 N 個空格」約束縮排，使所有行被壓到同一數值 | 未修改狀態下就回報成立 |
| 比對範圍過寬導致條件恆假 | 比對縮排時連內容一起比，而內容本就會因其他改動而變 | 未修改狀態下的失敗原因與待驗收項目無關 |

透過 PowerShell 取得 `git show` 輸出時，以位元組讀取後自行以 UTF-8 解碼。PowerShell 會以 console 編碼解碼子行程輸出，非 ASCII 內容會變成替代字元，使逐字比對產生假性不一致。改在 Bash 以管線處理位元組同樣可行。

資源派遣的建置與測試依寫入模式與第 6 欄邊界區分。write 派遣在第 6 欄允許的範圍內由執行端執行；readonly 派遣與唯讀 Reviewer 不執行建置或測試，需要時由主 Agent 補驗。Workflow 派工沒有派遣單第 5 欄，建置與測試依 `developer.toml` 的結案 gate 由 Developer 執行。

複核政策唯一：主 Agent 逐條核對 Codex 回報的命令原文與輸出是否支持其判定結論，這是核對而非重新執行。只有在輸出與結論不一致、輸出缺漏、回報只寫「已完成」而無命令輸出，或該條執行狀態為受阻或未執行時，才實際重跑該條命令。不整套重跑全部條件。

回收覆核的外部事實查證由主 Agent 負責。主 Agent 可在回收階段使用可用的上網工具查證派遣報告涉及的版本、規格、官方行為或其他驗收必要事實。派遣報告的自述不取代查證，查證也不取代第 5 欄命令輸出。每筆查證證據必須保留查詢內容、來源連結、查證時間、相關原始輸出或摘錄，以及支持或不支持驗收結論的判定，寫入回收報告或同線查證證據。來源不足、查證失敗或結果矛盾時，標示未驗證並交由回收三態處理，不得以推測補足。

