# Codex 派工機制：執行與續行

本檔收錄 Codex 啟動後的中斷保全、完成判定、事件流取證、續 session 與執行邊界。入口與其他階段的檔案見 `../SKILL.md`「階段路由」。

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

## 完成判定與三出口

`codex exec` 是一次性 process，完成判定的依據是事件流末尾與 process 結束狀態的組合，不是單一訊號。報告檔是否出現、stdout 是否閒置、單看 exit code 都不足以判定完成。

| 出口 | 判定條件 | 後續動作 |
| --- | --- | --- |
| A 正常結束 | 背景指令已離開執行狀態、exit code 為 0，且事件流最後一則事件的 `type` 為 `turn.completed` | 進行事件流取證，再執行回收判定 |
| B 執行中查詢 | 背景指令仍在執行，使用者要求現況 | 回報事件流最後一則事件的 `type` 與時間，不中止也不改變等待方式。此為回應使用者要求的單次讀取，不構成輪詢 |
| C 早夭 | 背景指令已離開執行狀態，且事件流最後一則事件的 `type` 不是 `turn.completed` | 最後一則為 `turn.failed` 時取其 `error.message` 作為失敗原因；事件流含 `agent_message` 時取最後一則作為未完成回報，依回收三態判定，不視為正常結束；兩者皆無時讀取 stderr 與 exit code 並回報啟動失敗 |

`turn.completed` 與 exit code 0 必須同時成立才走 A 出口。任一不成立即走 C 出口，包含事件流以 `turn.completed` 結束但進程以非零結束碼離開的組合。無法取得 exit code 時同樣走 C 出口，不以事件流單方面判定成功。

C 出口的常見成因包括參數位置錯誤、模型不被伺服器接受、額度用盡與 sandbox 權限失敗。參數與環境類失敗在 stderr 留下訊息，額度與伺服器類失敗只出現在事件流的 `turn.failed`，因此兩者都必須保存並在判定時一併查看。

### 腳本背景與證據

單獨呼叫的 `Start` 將 Codex 置於背景執行，thread relay 最多等待 5 秒後即輸出根 PID 與所有證據檔案路徑。`Dispatch` 同步模式（`background: false`）內部的 Start 會等待 Codex 行程結束才回傳，前景執行時間因此等於整個派遣的執行時間。主 Agent 由執行環境的完成通知接續，再呼叫 `Inspect` 與 `Collect`；不以檔案大小、stdout 閒置或單一 exit code 判定完成。

需要中止時，腳本只對已通過 PID 身分比對的根程序或 process group 執行安全關閉，並再次查詢確認進程樹已結束。無法完成身分驗證時保留進程與證據，不執行終止。

### 主 Agent 的等待方式

每次派遣只發一次背景等待，由完成通知接手。同步模式以執行環境的背景命令呼叫 `Dispatch`；`background: true` 時以一次 `Inspect -WaitForCompletion` 等待。二擇一，完成通知到達後再讀取 Dispatch 結果、事件流、last-message 與報告檔。兩種方式的完成判定完全相同，等待期間做其他工作不改變等待次數。

分步 `Start` 或 `Start -ResumeThreadId` 回傳 RunRecord 後，可用 `Inspect -WaitForCompletion -RunRecordPath <run_record_path>` 等待該輪，並提供來源、執行根目錄、line、dispatch、目標與識別字。

主 Agent 不輪詢。不以查詢行程（如 `Get-Process`）、讀取事件流尾端、`sleep` 或檔案大小反覆查狀態，也不以派生 subagent 等待取代事件流取證。

執行環境的背景命令有時限，到時限被停止時，已啟動的 Codex 程序不受影響並照常完成。預期執行超過背景命令時限的派遣，一開始就以獨立程序啟動 `Dispatch`，使一次等待涵蓋全程。背景命令因時限意外中止時，補發一次等待，仍不輪詢。派遣內需要長時間執行的建置或測試，執行端以獨立於 Codex 的監督程序啟動，stdout 與 stderr 直接寫入檔案，Codex 因額度或服務端容量中斷時，測試結果仍可由檔案取得。

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

`usage` 只作為事後記錄。

`finalMessage` 一律保留在 `history` 的 last-message 檔。報告落點由執行角色寫入；非 Git 來源的 readonly 派遣因 sandbox 唯讀無法寫入，由 Inspect 將 `finalMessage` 以 UTF-8 無 BOM 逐字寫成第 7 欄報告，結果的 `reportWriteback.status` 為 `written`、`unchanged` 或 `skipped`（既有檔內容不同時不覆寫）。`Wait-ForThreadRelay` 逾時後若未取得非空 `threadId`，`Start` 必須輸出 `source=not-ready` 與事件流、stderr、PID 等證據並以非零結束，不得以空字串表示成功；收到有效 `thread.started` 時才以非空 thread id 繼續。

執行角色已在派遣單第 7 欄與其規則檔指定的落點寫入報告，該檔是驗收對象。回收端若把結案摘要寫進同一路徑，會在驗收前覆蓋角色產出的完整報告。`DispatchKind=workflow` 機制的 `reportLineRoot\implement-closure-report.md` 同樣由 `Developer` 自行寫入，回收端只讀取與驗收。

由執行角色寫報告的派遣，報告落點檔案不存在或為空時，依回收三態的「退回」處理，要求角色補齊，不以 `finalMessage` 代寫。非 Git 來源的 readonly 派遣改由 Inspect 代寫，代寫結果為 `skipped` 或報告仍缺件時同樣依「退回」處理。

## 續 session 與跨介面接手

### 帳號與儲存目錄的兩種交接

| 情況 | 操作 | 保留條件 |
| --- | --- | --- |
| 使用者手動切換預設 home 的登入者，home 未變 | 以原 home、明確 thread ID 執行 `Start -ResumeThreadId` | profile/hash、完整父層選項、ScopePlan、last-message／檢查點與 PID 守衛照常驗證 |
| 切至另一獨立 home | 先 Inspect、Collect 原派遣，使用新 dispatchSlug、新 Request 與 `session_mode=cold-start` | 以檢查點承接已確認結果、未完成 selected units 及其來源，保留已完成成果的引用 |

同一派遣固定使用原 home。Start 比較 anchor 的 `effective_codex_home`，缺少時回退 `codex_home`；兩側名稱都有值時另比對名稱。不符回報 `ResumeAccountMismatch`，缺目錄、缺 home 或兩欄矛盾回報 `ResumeAccountUnverifiable`，保留 worktree 並交由主 Agent 建立新 slug。舊 RunRecord 缺名稱時採目錄綁定並記錄相容判定。腳本只證明儲存目錄與別名，無法確認同目錄內登入者的實際身分；同目錄手動切登入者後原 thread 可續行為需求提供的實測情形。

跨 home 的新 prompt 逐項引用原 ScopePlan、RunRecord、Inspect／Collect 結果、已完成成果與中斷檢查點的絕對路徑。新 `requested_unit` 只列檢查點中尚未完成的 selected units，維持原順序；deferred 與未選單位均不納入。以既有 `prepare_artifacts` 保存原 ScopePlan 與檢查點副本及 SHA-256，讓新執行端可實讀來源；新 cold-start 依明列的未完成單位建立自己的 ScopePlan。

`continue_from_scope_plan` 保留既有同 thread continuation 的限制。跨 home 的 cold-start 以上述來源材料與明列單位交接，不使用原 thread 的 resume，不複製 sessions 或憑證，也不把原派遣的 admission 轉給新派遣。原派遣已啟動且尚未結束時保留其 worktree 與 admission，所有新派遣仍接受既有並行與路徑衝突檢查。

### 同 home 的續行與跨介面接手

同 home、同一 worktree 的純技術補件使用 `Start -ResumeThreadId`，沿用原 `dispatchSlug` 與 `ScopePlanPath`。`PreflightResultPath` 與 `PrepareResultPath` 分別取自前輪 Dispatch result 的 `preflight_result_path` 與 `prepare_result_path`，ScopePlan 與 thread id 取自該輪 Start 結果或 RunRecord。同 home 換 worktree 時以新的 `dispatchSlug` 呼叫 `Dispatch`，Request 使用 `session_mode=Continuation` 與 `continue_from_scope_plan` 承接父 ScopePlan，由 Dispatch 重建 worktree；原 worktree 不作新 Dispatch 的目的地。

來源交接檔更新後，先確認該 dispatchSlug 沒有存活程序，再以 `prepare_mode=refresh` 執行 Prepare。Prepare 會核對 worktree 副本與既有 Prepare 紀錄，封存可替換的舊副本並產生新的 Prepare result。以該 result 的路徑呼叫 `Start -ResumeThreadId -PrepareResultPath <新 result>`，再以 `Inspect -WaitForCompletion -RunRecordPath <新 RunRecord>` 等待。若副本已被執行端修改，Prepare 會拒絕覆寫。

中斷檢查點由 Start 建立於 `executionRoot` 的同線 `history`，worktree 派遣由執行端在該 worktree 更新，direct-write 的 `executionRoot` 等於 `sourceRoot`。RunRecord 保存絕對路徑，Inspect 與 Collect 依該路徑讀取；舊 RunRecord 記錄的來源同線路徑仍可讀取。Cleanup 在移除 worktree 前將檢查點與事件流依相同保存流程複製回來源同線 history，並核對保存結果。

若需要補齊欄位或修正純技術驗收問題，先從 `codex-thread-<dispatchSlug>.txt` 讀取 `thread_id`，再以 `codex exec resume` 續行。續 session 沿用同一個 `dispatchRoot`、sandbox 邊界、`LineContext`、檔位、完整 `ScopePlan` 與 PID 身分驗證規則，並重新注入 `InterruptionSafeguard`。冷啟動寫入 ScopePlan 後，Start 以原始檔案位元組計算 SHA-256，保存至 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>\scope-plan-hash-<dispatchSlug>.json`（舊版根目錄紀錄的沿用條件見本 Skill 開頭的 ScopePlan hash 說明）；紀錄固定包含 `dispatch_slug`、`line_slug`、`scope_plan_path`、`sha256` 與 `created_at_utc`，既有同名紀錄不得覆寫。`ResumeThreadId` 必須同時提供既有 `ScopePlanPath` 與前輪交接資料（last-message，或 `turn.failed` 且無 last-message 時已驗證的中斷檢查點）；Start 必須讀取同名 hash 紀錄、確認 ScopePlan 絕對路徑一致並重新計算檔案 SHA-256，紀錄缺失、路徑不符或 hash 不一致時以非零結束，且不得啟動 Codex。hash 紀錄是 ScopePlan 未被改寫的唯一判定依據，不使用 `.original.json` sidecar 或自行計算 fingerprint。hash 通過後，Start 再確認 ScopePlan 欄位完整、`selected_units` 加 `deferred_units` 等於 `requested_units`、`session_mode=cold-start`，且 `dispatch_slug`、`dispatch_kind`、`task_type`、`requested_profile`、`unit_kind` 與 `requested_units` 和本次續行呼叫參數一致；任一不一致時以非零結束，且不得啟動 Codex。範圍不足時依既有 ScopePlan 保存已確認結果與證據，再由回收端決定後續 cold-start。

續行的父層選項必須與初始啟動完全相同，包含 `--profile`、`--add-dir` 與 `--search`。這組選項從初始啟動記錄重建，不依當下判斷重新推導；任一項缺漏都會改變檔位、寫入權限或網路能力，使續行的執行條件與前一輪不一致。`Start` 會檢查續行識別、保全指示與 `ScopePlan` 是否一致，拒絕缺少必要交接資料的請求。

準備或啟動失敗的嘗試以 `launch_state=launch-failed` 與 `failure` 物件保存，包含 `phase`、`reason_code`、原始例外與事件流、stderr 等原始輸出位置，保留於執行鏈供稽核，不刪除。RunRecord 以 `attempt_parent_run_id` 記錄前一次嘗試，以 `previous_run_id` 與 `resume_anchor_run_id` 記錄可續行的 thread 錨點，兩者分欄。最新嘗試為失敗且 PID 檢查沒有活躍程序時，同一 dispatchSlug 可再冷啟動。續行時沿 `attempt_parent_run_id` 回溯，依 dispatchSlug、thread id 與可續行最小狀態選擇有效錨點；`launch-failed` 紀錄保留供稽核，任何情況都不作續行對象。PID 狀態為 `record-identity-mismatch` 時代表 PID 重用，不阻擋續行；`root-process-absent` 也不阻擋。有效活躍程序或其他身分未確認狀態會阻擋同派遣續行，錯誤訊息格式為 `ProcessIdentityBlocked：dispatch_slug=<slug>; record=<PID 記錄絕對路徑>; state=<狀態>`，多筆紀錄會逐筆列出。找不到有效錨點、thread 遺失或續行狀態不足時以 `NoValidResumeAnchor` 停止，交接已確認成果、未完成單位與 cold-start 指引。

續行沿用初始啟動的 profile，不另外比對原 thread 模型；需要確認時以 `DiagnoseModelEnvironment` 診斷。

Start 與 Inspect 的失敗結果帶 `reason_code`：`QuotaServiceRejected`、`RequiredParameterMissing`、`AdvisorImplementationProfileRejected`、`AdvisorProfileRequired`、`ProfileRequired`、`AdvisorAuthorizationRequired`、`EvidencePackRequiredOutputInvalid`、`EvidencePackMissing`、`EvidencePackInvalid`、`EvidencePackInlineMismatch`、`ProfileEvidenceUnknown`、`CodexLaunchFailed`、`ProcessIdentityUnknown`、`ThreadRelayTimeout`、`ServiceStreamDisconnected` 或 `Unknown`。`turn.failed` 或非零 exit 沒有可確認原因時使用 `Unknown`，並保留原始事件行與 stderr；stderr 為空不代表沒有錯誤。thread relay not-ready 的錯誤訊息附上 stderr 摘要。stderr 不超過 64 KiB 時，全文先經遮蔽規則處理，再取末 20 行與 1,200 字元；超過 64 KiB 時不附原文，只附固定說明與檔案大小、路徑等中繼資料，因為截斷後的片段可能已失去遮蔽規則辨認所需的上下文。錯誤訊息與 failure record 只帶已遮蔽的摘要。遮蔽規則涵蓋 `Authorization` 與 `Proxy-Authorization` header 的值。

Inspect 在開始處一次檢查同一次呼叫會因缺少而拒絕的參數，缺少時以單一 `RequiredParameterMissing` 錯誤列出全部參數名與可取得的來源，例如 Request 欄位、RunRecord 欄位或 `DispatchResultPath` 綁定。Inspect 不從 RunRecord 自動補值，缺少的值由呼叫端依列出的來源補齊後重新呼叫。

事件流含服務端串流中斷（`stream disconnected before completion`）、沒有 usage-limit 證據，且最後一個事件不是 `turn.completed` 時，不論終止事件是 `turn.failed` 或頂層 `error`，Inspect 都分類為 `ServiceStreamDisconnected`，並輸出 `retry_allowed=true`、`resumable` 與 `recommended_next_step`。有 safe point 與未完成單位時 `resumable=true`，建議以新 `dispatchSlug` 冷啟動並只派未完成單位；否則依 ScopePlan 的 `selected_units` 重新執行。usage-limit 證據優先，維持 `QuotaServiceRejected`、`retry_allowed=false` 與 `resumable=false`。其他失敗的 `retry_allowed` 為空值，可否重試由主 Agent 依原始事件與 stderr 判斷。

前輪以 usage-limit 中止、沒有 last-message、啟動失敗或終止原因不明時，續行沿既有執行鏈的 `attempt_parent_run_id`／`previous_run_id` 尋找有效 anchor；找不到有效 anchor 時以 `NoValidResumeAnchor` 停止。執行鏈保留失敗嘗試、事件流、ScopePlan、baseline、父層選項、process gate 與 model evidence，成果仍由 Inspect 與 Collect 驗收。有效 anchor 的事件流以 `turn.failed` 結束且沒有 last-message 時，Start 依 RunRecord 的 `interruption_checkpoint_path` 取得已驗證交接資料，新 RunRecord 的 `continuation_handoff_source_type` 記為 `interruption-checkpoint`；使用 last-message 時記為 `last-message`。兩者皆缺或檢查點驗證失敗時，以 `ResumeHandoffUnavailable` 拒絕並指出兩個檔案路徑。

初次 Start 將有效父層選項寫入 RunRecord 的 `parent_options`（`profile`、`sandbox`、`add_directory` 保留原文與順序、`search`、`codex_parent_option` 保留原文與順序、`working_directory`）與 `parent_options_sha256`。續行未顯式傳入時從錨點還原，顯式傳入時逐欄比對，任一不同即以 `ParentOptionsMismatch` 拒絕並輸出欄位、數量與首個差異索引，不以當次呼叫值覆蓋錨點值；舊 RunRecord 沒有此欄位時輸出 `ParentOptionsUnknown`，不續行原 thread。

自動 token 組（shell 網路、`mxc` 與 NuGet 路徑覆寫，見 `references/start.md`「指令契約」）只在新 cold-start 合成，記錄於 `parent_options.codex_parent_option`。續行一律沿用錨點記錄的完整陣列：錨點含完整 token 組時原樣沿用；只含網路 token 的舊錨點維持原狀，不補加 `mxc` 與 NuGet 覆寫；token 組不完整或與原始派遣語意不符時以 `ParentOptionsMismatch` 拒絕。需要新的 token 組但錨點不含時，以新的 `dispatchSlug` 冷啟動。

續行不比對 worktree 的 ACL／SID 證據；ACL 證據缺少或與前輪不同時，有效 thread 仍可續行。Codex 在 `turn.started` 後沒有後續事件且非零結束時，Inspect 判定 `InterruptedUnknown`，保存事件尾段、stderr 與 exit code 並輸出 `cold_start_recommended=true`；該 worktree 不再作為續行目標，冷啟動改用新的 dispatch worktree。

續行實際失敗（`turn.failed` 或非零結束且 Inspect 判定失敗）時，Dispatch 依 Request 的 `failure_receipt_path` 寫入 `ai-sessions.dispatch-failure-receipt.v1`，不自動重送。`continuation_handoff` 含 `confirmed_results`（最新 safe point 的已確認結論與覆蓋範圍；取不到時為空陣列並標示來源不足）、`incomplete_units`（只取前輪 ScopePlan `selected_units` 的子集合，以完整字串逐一比對 safe point，不以標點切分單位名稱；deferred 或其他未選項目剔除並記錄理由；缺 safe point 時保留全部 selected_units）、`source_locations`（Request、ScopePlan、RunRecord、事件流、last-message、Inspect 結果與 safe point 證據位置）、`cold_start_entry`（新的 `dispatch_slug`、`session_mode=cold-start`、未完成單位與 root、prompt、target、識別字，`new_request_required=true`）與 `automatic_retry=false`。服務端串流中斷或 usage-limit 拒絕時，receipt 另含 `failure_classification`、`retry_allowed`、`resumable` 與 `recommended_next_step`，值與 Inspect 的分類一致。Inspect 擲出例外或第一次 receipt 寫入失敗而改走通用失敗路徑時，續行派遣仍帶入 `continuation_handoff`（已建立者沿用，否則依 RunRecord 與 ScopePlan 建立）；`session_mode` 的大小寫變體同樣視為續行。主 Agent 依 `cold_start_entry` 建立新的 Request 冷啟動。

`Start` 以 `ResumeThreadId` 讀取指定 `thread_id` 後建立續行命令，重新產生事件流與 stderr 檔案，不覆寫前一輪記錄。續行的父層選項從初始啟動結果重建，包含 `--profile`、`--add-dir` 與 `--search`。

`exec resume` 的 session 識別接受 `thread_id` 或 thread 名稱，UUID 優先解析。省略識別並改用 `--last` 會選取最近一次記錄的 session，該行為依賴本機記錄狀態而非本次派遣的識別，因此派工流程一律明列 `thread_id`，不使用 `--last`。Start 將錨點 RunRecord 的前輪 last-message 原文注入續行 prompt。前輪以 `turn.completed` 結束時只要求該訊息存在且非空；前輪被中止、早夭或終止狀態無法判定時，另要求訊息明列已確認結論、未完成單位與證據位置三個單行鍵值對，缺少任一項時拒絕續行。前輪事件流以 `turn.failed` 結束且 last-message 缺失時，Start 改注入 RunRecord 指向且通過驗證的中斷檢查點，並在新 RunRecord 記錄交接來源類型；檢查點缺失或驗證失敗時以 `ResumeHandoffUnavailable` 拒絕並列出兩個檔案路徑。此分流與「InterruptionSafeguard」節一致。

續行 prompt 仍來自 scratch 檔案並以 `-` 從 stdin 傳入，內容必須重述同一組 `LineContext`、`dispatchRoot`、檔位與父層選項，列出前輪「驗證證據」及「Phase 對照」的既有條目，並逐項附上未達成條件清單。已完成的條件不得以摘要取代，續行只補齊明列的缺漏。續行的對象是 Reviewer 時，未達成條件以前輪報告的 finding ID 逐一列出（例如 `F-003 未閉合：<一句話>`），並附上主 Agent 對每個 ID 所做修正的位置；不以新措辭重述缺陷，讓 Reviewer 依 ID 判定閉合狀態。

跨介面接手視為同一條 line 的續行，依序讀取下列交接物重建狀態。

1. `dispatchLineRoot\design.md`。
2. `sourceLineRoot\requirement-summary.md`。需要由 Codex 寫入或讀取來源交接時，沿用啟動命令的 `--add-dir` 授權。
3. 本輪 `executionRoot\.local\ai-sessions\history\codex-exec-<yyyyMMdd_HHmmss>.jsonl`。
4. 派遣單第 7 欄指定報告；`DispatchKind=workflow` 機制另讀 `reportLineRoot\implement-closure-report.md`。

### 中止與安全關閉

中止只針對 PID 記錄中 `work-root`、`line-slug` 與 `dispatch-slug` 三者均匹配本次派遣的進程樹，並依「Codex 進程 PID 與並行檢查」的根程序名稱、建立時間及 process group 或後代鏈身分比對後執行。使用者要求中止前若無法完成身分驗證，保留進程與證據，不執行任何 `taskkill` 或 `kill`。終止後再次查詢確認全部程序已結束，並保存事件流、stderr 與 exit 資訊。

被中止的派遣不視為完成，依 C 出口處理。

## sandbox 外環境動作

work-root 外的環境變更，例如安裝全域工具、修改系統設定或寫入 work-root 以外的目錄，由主 Agent 在派工前代執行。代執行前必須取得使用者當輪明確同意。非互動情境無法取得當輪同意時停止並回報缺件。

代執行後追加 `<work-root>/.local/ai-sessions/report/<lineSlug>/exceptions.md`，觸發類型使用「偏離設計」，並記錄外環境動作、同意依據與位置。寫入前確認 `LineContext.lineSlug` 與同線 manifest 一致。

work-root 內需要 shell 網路的建置與還原，依「網路能力硬邊界」判定派給 Codex 或由主 Agent 處理。下載套件或相依性仍須先取得使用者當輪明確同意，同意後才派工。

## 網路能力硬邊界

Codex 有兩個彼此獨立的網路開關。

| 開關 | 啟用條件 | 用途 |
| --- | --- | --- |
| `-c sandbox_workspace_write.network_access=true` | Start 在 `write_mode=write` 且 sandbox 為 `workspace-write` 的新 cold-start 自動加入，置於 `exec` 前；Request 不提供開關，`codex_parent_option` 自帶同名覆寫時於啟動前拒絕 | shell 出網，例如 `dotnet restore`、`npm install`、`git fetch` 與下載套件 |
| `--search` | 依派遣需要指定，屬 `codex` 的父層選項，置於 `exec` 或 `exec resume` 前 | Codex 的官方查證工具，不提供 shell 網路 |

- 派遣 write 工作時，shell 可嘗試網路還原與建置。Windows 上 Start 同時改用 `mxc` 並把 NuGet 路徑指到 executionRoot 內，使 HTTPS 與 restore 可在 sandbox 內完成；npm、git 等其他工具在 `mxc` 內是否需要寫入使用者目錄未驗證。實際連線仍受本機網路、防火牆與組織政策影響；連線失敗時保存命令原文、stderr 與退出碼並回報受阻，不改用 sandbox 外執行、`danger-full-access` 或 `unelevated` 補足。
- readonly 派遣（含 worktree readonly、advisor 與 direct-readonly）不帶 shell 網路覆寫，shell 出網預期失敗。唯讀 Reviewer 不執行建置或測試。
- 需要 shell 網路的工作派 write；工作必須唯讀時，網路動作改由主 Agent 依「sandbox 外環境動作」處理。
- 事實查核類派遣必須啟用 `--search`。未啟用時，Codex 可能無法取得資料而改以記憶作答。shell 網路覆寫不取代 `--search`。

