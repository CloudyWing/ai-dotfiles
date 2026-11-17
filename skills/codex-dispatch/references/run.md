# 單次執行入口（Invoke-CodexRun）

選派入口輸出的 `executor.entry` 為 `scripts/Invoke-CodexRun.ps1` 時依本檔執行，適用審查（`Reviewer`、`Frontend Reviewer`、`Contract Auditor`）、事實校閱、影像產生、測試取證（`test`）與顧問諮詢（`advise`）。`executor.entry` 為其他值時依 `start.md`。

一次發動是一個 `codex exec` 行程，直接在線工作樹執行。命令在 MXC 沙盒內只能讀取工作目錄、`~\.ai-agents` 與線的報告目錄（影像產生另加選定帳號的 `generated_images`；顧問不開放這些目錄，只能讀寫輸出目錄，另以檔案單位唯讀開放專案說明檔），只能寫入該次執行的輸出目錄，讀不到 `.env`、`.env.*`、`*.pem`、`*.key`、`secrets.*`。失敗時整筆重跑，沒有續行。

本入口不使用 `New-DispatchInputs.ps1`、`New-DispatchOrder.ps1`、Request JSON、Preflight、Prepare、Inspect、Collect 與 Cleanup。本檔自成一體，發動、等待與回收不需要再讀 `start.md`、`execution.md`、`collect.md` 與 `recovery.md`。

## 發動

1. 寫派遣檔。複製 `templates/dispatch/run-order.md`，存為 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/run-order-<dispatchSlug>.md`，填寫 `## 派遣設定` 的 JSON 區塊與 `## 任務`、`## 驗收條件`、`## 邊界`、`## 回報必備欄位` 四個章節。
   - `task_type` 填選派時的類型，`profile` 填選派入口輸出的 `executor.profile`。
   - `role_file` 填角色規則檔的絕對路徑，各類型的值見「依 task_type 的差異」。
   - `advise` 另填 `advisor_request_source`、`evidence_file`、`question_ids`，見「顧問（advise）」；其他類型不得出現這三個鍵。
   - `test` 可選填 `test_context_file`，見「測試取證（test）」；其他類型不得出現這個鍵。
   - `execution_root` 填線工作樹根目錄。`report_line_root` 填 `<work-root>/.local/ai-sessions/report/<lineSlug>`，該目錄必須已存在。
   - `report_name` 填報告檔名，只含檔名，各類型的值見「依 task_type 的差異」。
   - `targets` 列出目標物件的絕對路徑，目錄以結尾反斜線標示。`required_reads` 列出必讀檔，例如 `design.md`、`requirement-summary.md`、結案報告與前輪審查報告。
   - 路徑不得指向 `.env`、`.env.*`、`*.pem`、`*.key`、`secrets.*`，也不得位於工作目錄、`~\.ai-agents` 與線的報告目錄之外。`execution_root`、`report_line_root` 與 `report_name` 不得含 `&`、`|`、`<`、`>`、`^`、`%` 與雙引號。
   - `## 驗收條件` 逐條寫出可判定的條件。需要審查者核對的既有證據，把命令原文與原始輸出檔的路徑寫進該條，並把輸出檔列入 `required_reads`。
   - `cycle` 填循環標示（審查以外的類型可省略），`## 任務` 章節第一行另寫 `循環：<cycle_id> 第 <cycle_round> 輪（cycle_role=review）`。第 2 輪以上把前輪審查報告與修正報告列入 `required_reads`，寫法見 `workflow-orchestration` skill `references/review-procedures.md`。
2. 執行入口。以背景命令執行，完成時會收到通知，不輪詢。

   ```powershell
   pwsh -NoProfile -File scripts/Invoke-CodexRun.ps1 -DispatchFile "<派遣檔絕對路徑>"
   ```

   入口自行選擇派工帳號，不指定 `CODEX_HOME`。帳號登記讀取主 checkout 的 `.local\machine.json`，在線工作樹發動時結果相同。

   單次執行的總時限預設 1800 秒，需要調整時加 `-TimeoutSeconds <秒>`。等待與終止的規則見「等待與終止」。

### 依 task_type 的差異

入口依 `task_type` 決定下表最後一欄的差異，其餘流程相同。`task_type` 不在表內時以結束碼 2、`RunTaskTypeUnsupported` 停止，不啟動 Codex。

| `task_type` | `role_file` | `report_name` | 入口的差異 |
| --- | --- | --- | --- |
| `review` | `~\.ai-agents\agents\codex\reviewer.toml`、`frontend-reviewer.toml` 或 `contract-auditor.toml` | 依角色為 `review-report.md`、`frontend-reviewer-report.md` 或 `contract-auditor-report.md` | 成功後檢查報告的 Finding manifest，結果在 `final.review_report_check`；prompt 以「審查者:」行標明實際執行者 |
| `factcheck` | `~\.ai-agents\skills\fact-check-note\SKILL.md` | `fact-check-report.md` | 在 `exec` 前加 `--search`；不做 manifest 檢查，`final.review_report_check` 為 `null` |
| `generate` | 派遣檔本身（影像產生沒有專屬角色規則檔，任務、驗收條件與輸出規則全寫在派遣檔） | 自訂，例如 `generate-report.md` | 選定帳號的 `<CODEX_HOME>\generated_images` 列為可讀（不存在時入口先建立）。影像先產在該處，`## 任務` 要求 Codex 複製到輸出目錄，並在報告逐一列出影像檔名；不做 manifest 檢查 |
| `test` | 派遣檔本身（測試取證沒有專屬角色規則檔，任務、受測對象、驗收條件與回報欄位全寫在派遣檔） | 自訂，例如 `test-report.md` | 只接受檔位 `scan`；命令沙盒維持唯讀，操作與取證只經檔位設定檔掛上的 MCP 工具；見「測試取證（test）」 |
| `advise` | 派遣檔本身（顧問沒有角色規則檔） | 自訂，例如 `advice-report.md` | 不開放工作目錄，可讀可寫根目錄只有輸出目錄，另以檔案單位唯讀開放專案說明檔，`--cd` 指向輸出目錄；evidence 全文內嵌 prompt；Codex 的最後訊息由入口存成 `report_name`；結束時檢查報告含每個題號，見「顧問（advise）」 |

`profile` 與 `task_type` 綁定：`advise` 只接受檔位 `advisor`，`test` 只接受檔位 `scan`，其他類型不接受這兩個專屬檔位，不符時以結束碼 2、`RunTaskProfileMismatch` 停止，不啟動 Codex。

### 測試取證（test）

測試取證分兩段。建置、還原套件、啟動受測程式與執行可重跑的測試專案（含 `dotnet test` 的 FlaUI 與 Playwright 測試）由 Claude 端在沙盒外完成，不派給 Codex；Codex 只以 MCP 工具臨場操作已啟動的受測對象並取證。網頁用 `playwright`，桌面用 `flaui-mcp`，兩者只在檔位 `scan` 掛上，其他類型不載入。

- 派工前準備（Claude 端）：確認受測對象已啟動且可由 MCP 工具到達（網頁已能開啟，桌面程式視窗已顯示）；需要登入時確認測試環境資料檔存在。入口不檢查受測對象是否已啟動。
- 派遣檔：`role_file` 填派遣檔本身。受測對象寫在 `## 任務`，網頁寫網址，桌面寫視窗標題與行程識別碼（`windows_attach` 用行程識別碼附加，不列舉其他視窗）。`targets` 只列要比對變動的來源檔或目錄，不含 `bin`、`obj`、記錄檔等受測程式執行時會寫入的位置，否則 `source_changed` 會被誤觸發。
- `test_context_file`：選填，測試環境資料檔的絕對路徑，固定為 `<work-root>/.local/ai-sessions/test-context/test-context.md`（建立與格式見 `session-artifacts` skill「測試環境資料檔」）。入口檢查路徑形態、檔案存在，並以檔案單位唯讀開放（執行紀錄 `permission.read_files`），不開放其所在目錄，也不受可讀根目錄限制。
- 檔位設定檔：登錄表 `codex-scan` 的 `profileSettings.mcpServers` 產生 `[mcp_servers.*]` 表，核准模式固定 `approve`（`codex exec` 的核准政策為 `never`，未設定時 MCP 工具被拒），以 `enabled_tools` 只開放需要的工具。`flaui-mcp` 的指令路徑因機器而異，不進產生檔，由帳號目錄 `config.toml` 以 `enabled = false` 提供，`Setup-AIGlobalConfig.ps1` 從 Codex Desktop 的 `config.toml` 只讀取單行字串的 `command` 與 `startup_timeout_sec` 後追加；帳號沒有 `config.toml`、讀不到或編碼不明（非 UTF-8、含 NUL）、來源的 `command` 格式無法確定時，Setup 不寫檔並計入阻塞。帳號缺少時入口以結束碼 2、`CodexMcpConfigMissing` 停止，訊息列出重跑 Setup 的命令。
- 輸出落點：入口對 Codex 行程設定 `PLAYWRIGHT_MCP_OUTPUT_DIR` 為該次輸出目錄，自動命名的截圖與頁面快照存入其中。`## 任務` 與 prompt 要求截圖不指定檔名，指定檔名的截圖會寫到工作目錄根，`<execution_root>\.playwright-mcp` 不納入來源雜湊，入口在啟動前後各記一次該目錄的檔案狀態，`mcp_stray_output.exists` 為 `true` 且 `files` 列出檔名時，表示這些檔案是本次新增或變動的殘留；先前就存在且沒變動的檔案不算。列舉失敗（例如子目錄沒有存取權限）時派遣照常完成，`mcp_stray_output.state` 為 `indeterminate`、`exists` 為 `null` 並附 `error`，回收時人工檢查該目錄。
- 桌面截圖：`windows_screenshot` 只把影像回傳給模型，不存檔，不作為留存證據。桌面畫面的留存方式尚未定案，需要留存時由 Claude 端在沙盒外擷取。
- 紀錄與結果：執行紀錄與 `final` 另含 `mcp_tool_calls`（`completed`、`failed` 次數與用到的伺服器）、`artifacts`（輸出目錄內報告以外的檔案，相對路徑）與 `mcp_stray_output`。不做報告格式檢查，`final.review_report_check` 為 `null`。
- 回收：讀 `final.report_path` 全文，逐條核對派遣檔 `## 驗收條件`，並以 `mcp_tool_calls.completed` 與 `artifacts` 核對報告宣稱的操作與截圖確實存在；`completed` 為 0 表示沒有實際操作，退回重跑。判讀是否符合預期與修正迴圈決策留在 Claude 端。`source_changed` 與 `mcp_stray_output.exists` 為 `true` 的處置同審查。收下後把輸出目錄內需要保留的截圖複製到 `<work-root>/.local/ai-sessions/screenshots/` 並在報告引用。
- 網路邊界：命令沙盒內連不到本機服務，API 呼叫與資料回查由 Claude 端執行，不派 `test`。
- 資料異動：寫入資料的操作依 `integration-verify` 的資料異動安全規範，Claude 端確認後在 `## 任務` 寫明可操作的資料範圍。

### 顧問（advise）

顧問是 evidence-only 的唯讀諮詢：協調者把問題與證據整理成 evidence pack，顧問只依內嵌內容回答，不讀工作目錄。適用條件是推理密集，且判斷資料可事先整理成 evidence pack；大量讀寫、掃描、建置、測試與命令執行類工作不使用顧問。

- 授權：每次發動都需使用者當輪授權（`rules/claude/30-dispatch.md`「advisor consult 的不限階段掛載點」）。派遣檔的 `advisor_request_source` 必須是 `user-explicit`，缺少或不符時以結束碼 2、`RunAdvisorAuthorizationRequired` 停止，不啟動 Codex。
- 派遣檔：`evidence_file` 是 evidence pack 的絕對路徑，須位於可讀範圍內，只檢查存在且非空，不驗證內容格式。`question_ids` 是題號的非空陣列，每個題號不含空白。`role_file` 填派遣檔本身，`targets` 填 evidence pack，`required_reads` 必須是空陣列（顧問不讀檔）。`execution_root` 照常填寫，顧問不可讀取。
- 讀取邊界：`--cd` 指向該次的輸出目錄，可讀根目錄只有輸出目錄，不含 `execution_root`、`report_line_root` 與 `~\.ai-agents`，也不帶 `--search`。Codex 建立 session 時會從輸出目錄往上載入專案的 `AGENTS.override.md` 與 `AGENTS.md`（到含 `.git` 的專案根目錄為止），讀不到會無法啟動，因此入口只把實際存在的這幾個檔案以檔案單位開放為唯讀（執行紀錄 `permission.read_files`），不開放其所在目錄。找不到 `.git` 時 Codex 只看工作目錄，不開放任何上層檔案。顧問需要的其他規則條文由協調者摘錄進 evidence pack。
- 雜湊：入口讀 evidence pack 並記錄 SHA-256 與長度，全文內嵌 prompt（以 `<<<EVIDENCE-BEGIN ...>>>` 與 `<<<EVIDENCE-END>>>` 包夾）後逐字比對，不一致時以結束碼 2、`RunEvidenceInlineMismatch` 停止，不啟動 Codex。結束時再算一次，與啟動時不同或檔案已不存在，則 `source_changed` 為 `true`，結果為 `failed`、`failure_reason` 為 `source-changed`、結束碼 1（回答齊備也一樣，報告不可信）。換帳號或換 model 重跑前 evidence 已被改或刪除時，以結束碼 2、`RunEvidenceChangedBetweenAttempts` 停止，不以新內容重跑。起訖雜湊與長度在執行紀錄與結果的 `evidence`（`sha256`、`sha256_end`、`bytes`、`inline_verified`）。
- 報告：入口把 Codex 的最後訊息存成輸出目錄內的 `report_name`。prompt 要求每個題號各用一個標題回答，結束時檢查報告含每一個題號（整個詞比對）。缺少時結果為 `failed`，`failure_reason` 為 `questions-missing`，結束碼 1，入口不自動重跑。只要有非空的報告，不論結果都列出缺少的題號（`final.missing_question_ids`），`final.question_check` 為 `checked`；沒有報告可檢查時 `question_check` 為 `unavailable`，`missing_question_ids` 為 `null`。
- evidence pack 的內容由協調者負責：每段摘錄附完整絕對路徑、行號範圍與版本識別（commit SHA 或檔案 SHA-256）；每題要求可直接執行的建議（處理位置、主要取捨、驗收方式、假設與推翻條件），聚焦實質處置，不要求因果分析；可能反證寫成可逐條回答的條件。
- 送出前，協調者先寫下自己的判斷；回收後逐項對照顧問意見，同意或不同意都附理由，以「主 Agent 決定、依據、與顧問意見異同」記錄於同線 `exceptions.md`。顧問只提供另一視角，決策由主 Agent 或使用者作出。
- 回收：讀 `final.report_path` 全文並逐題核對。`source_changed` 為 `true`（`failure_reason` 為 `source-changed`）時重新整理 evidence pack 後重跑；有缺少的題號時以同一份派遣檔重跑。收下後把報告複製為同線 `<work-root>/.local/ai-sessions/report/<lineSlug>/advisor-consult-<dispatchSlug>.md`。
- 追問：新增問題、來源或證據時建立新的 evidence pack、新的題號與新的 `dispatch_slug`，不續行，也不併入原派遣的題號。授權不延續到其他 Session，也不依額度縮小題號範圍。

## 結果

入口在 stdout 輸出一份 JSON，並以結束碼表示結果。人員可讀的診斷訊息在 stderr。

| 結束碼 | `status` | 意義 | 處置 |
| --- | --- | --- | --- |
| 0 | `success` | Codex 正常結束且報告存在 | 進入「回收」。`error` 非空時表示健康狀態檔寫入失敗，不影響本次結果，把訊息回報使用者 |
| 1 | `failed` 或 `rejected` | 執行失敗（含逾時，執行紀錄的 `failure_reason` 為 `timeout`），或服務端拒絕時已有進度 | 讀 `final.stderr_path` 與 `final.events_path` 判斷原因後整筆重跑 |
| 1 | `stopped`，或沒有 JSON 輸出 | 執行紀錄或成本列寫入失敗，或入口發生未預期的錯誤 | 讀 stderr 的錯誤訊息；報告若已產生仍保留在輸出目錄，排除原因後重跑 |
| 2 | `stopped` | 派遣檔無效或引用的路徑不合格 | 依 `error.details` 列出的每個路徑與原因修正派遣檔 |
| 2 | `stopped` | `error.code` 為 `CodexProfileDrift`：實際要使用的帳號的檔位設定檔與主 checkout 的產生檔不一致（內容不同或連結指向他處），或產生檔與登錄表不一致 | 逐行貼到 pwsh 執行 `error.message` 列出的修正命令（重跑 `Update-CodexProfiles.ps1`、重跑 Setup 或移走帳號目錄內的一般檔案後重建連結），再重跑。入口沒有啟動 Codex，也沒有改任何檔案 |
| 2 | `stopped` | `error.code` 為 `CodexMcpConfigMissing`（`test`）：帳號目錄 `config.toml` 缺少檔位 `scan` 需要的 MCP 伺服器 command | 以 pwsh 執行 `error.message` 列出的 Setup 命令後重跑。入口沒有啟動 Codex，也沒有改任何檔案 |
| 3 | `stopped` | 非 Windows、找不到 codex，或 MXC 不可用 | 回報使用者，不改用其他沙盒 |
| 4 | `stopped` | 沒有登記帳號、全部帳號不可用，或候選帳號都被服務端拒絕 | 見「帳號」 |

`attempts` 列出每一次嘗試。換帳號後的每次嘗試各有自己的執行紀錄、輸出目錄與成本列。`final` 指向最後一次嘗試的報告、紀錄、最後訊息、事件流與 stderr。`attempts[].model` 與 `final.model` 是該次嘗試實際使用的 model，`final.model_source` 為 `primary`（檔位的主要 model）或 `fallback`（備援 model）。`fallback` 只在結束碼 4 時有值，內容見「帳號」。

執行紀錄的 `timeout_seconds` 與 `turn_end_grace_seconds` 是該次實際套用的總時限與回合結束寬限（秒），在 Codex 啟動前寫出的紀錄初稿就有值，執行中即可讀取。

執行紀錄的 `limit_reset_raw` 與 `limit_reset_local` 只在 `rejection_kind` 為 `usage-limit` 且服務端訊息含「try again at <月> <日>, <年> <時:分> AM/PM」時有值，其餘為 `null`。`limit_reset_raw` 是訊息中的原始時間字串，`limit_reset_local` 是解析後的 ISO 8601 時間。訊息不含時區，入口視為執行機器的本地時間，因此 `limit_reset_local` 帶本機時區位移。月名、日期、時間無法依這個格式解析時兩欄皆為 `null`，不影響拒絕判定、換帳號與結束碼。加入這兩個欄位之前產生的紀錄沒有它們，面板讀到時視為沒有重設時間。訊息不指出是哪一種額度視窗，兩欄只記錄服務端給的重設時間。

每次嘗試的檔案位於 `<report_line_root>\runs\`：輸出目錄 `<runKey>\`、`<runKey>.record.json`、`<runKey>.events.jsonl`、`<runKey>.stderr.txt`、`<runKey>.last-message.md`。

## 等待與終止

- 事件流與 stderr 在執行中即時寫入檔案，可以在執行中讀取進度。
- 超過總時限（`-TimeoutSeconds`）時，入口終止整棵 Codex 行程樹，結果為 `failed`，`failure_reason` 為 `timeout`，執行紀錄的 `terminated_by_entry` 為 `timeout`。
- 事件流的最後一個事件為 `turn.completed` 且最後訊息檔非空之後，Codex 行程 60 秒內仍未結束時，入口終止行程樹，執行紀錄的 `terminated_by_entry` 為 `after-turn-end`。結果依報告判定，與正常結束相同，報告存在且格式合格即為成功，不需要重跑。
- 行程由入口終止時，執行紀錄的 `exit_code` 是終止所致的值，不作為判定依據。

## 沙盒內的 git

入口對 Codex 行程設定 `GIT_CONFIG_GLOBAL=NUL` 與 `GIT_CONFIG_NOSYSTEM=1`，沙盒內的 git 不讀全域與系統設定。沙盒不授權使用者家目錄的 `.gitconfig`，未設定時 git 在讀取設定檔時整個失敗。

沙盒不允許行程切換到唯讀目錄，因此需要工作樹的命令不可用，與設定檔無關。

| 可用 | 不可用 |
| --- | --- |
| `git rev-parse`、`git log`、`git show`、`git diff <rev> <rev>`、`git diff --cached`、`git ls-files -m -o --exclude-standard`、`git ls-tree` | `git status`、`git diff`（比對工作樹）、`git diff HEAD` |

需要工作樹狀態時，用 `git ls-files -m -o --exclude-standard` 列出已修改與未追蹤的檔案，用 `git diff --cached --name-status HEAD` 列出已暫存的變更，再以 `git ls-tree --name-only HEAD -- <path>` 判定 HEAD 是否有該路徑。HEAD 有者以 `git show HEAD:<path>` 與直接讀取的檔案內容比對，HEAD 沒有者（已暫存新增、重新命名後的新路徑、未追蹤）不執行 `git show`，整份讀取檔案。Reviewer 的盤點步驟見 `agents/codex/reviewer.toml`「啟動流程」第 5 點。

`git ls-files --exclude-standard` 與 `git diff --cached` 在沙盒內會於 stderr 印出無法存取使用者層級 git 設定的 warning，結束碼仍為 0，以結束碼判定成敗。

## 回收

以下「報告是否可用」與「收下後的處理」適用審查。事實校閱與影像產生見「事實校閱與影像產生的回收」，顧問見「顧問（advise）」的回收項。

回收分兩步。先判定這份報告能不能用，再依報告的審查結論決定下一站。

### 報告是否可用

依序核對下列各項，全部成立為「收下」。

1. 讀 `final.report_path` 的報告全文，確認報告含派遣檔 `## 回報必備欄位` 要求的各節，且 `## 總覽` 第一行的審查者與實際執行者相符。
2. 確認 `final.review_report_check.valid` 為 `true`。
3. 確認 `final.source_changed` 為 `false`。
4. 逐條核對派遣檔 `## 驗收條件`：報告對每一條都有判定，判定引用的檔案與行號存在，且內容支持該判定。只在判定與引用內容不一致、引用位置不存在，或該條涉及需求摘要的已確定實作約束時，才實讀來源複核。

任一項不成立時依下表處置。

| 情形 | 判定 | 處置 |
| --- | --- | --- |
| 報告缺節、`review_report_check.valid` 為 `false`、驗收條件缺判定或引用無法定位 | 退回 | 以同一份派遣檔重跑，並在 `## 任務` 補一行指出上一份報告缺少的部分。`errors` 會指出不合格的 finding 與欄位 |
| `source_changed` 為 `true`，改動來自本 Session | 退回 | 停止改動目標後重跑 |
| `source_changed` 為 `true`，改動來源不明 | 升級 | 回報使用者，不採用該報告 |
| 報告指出設計歧義，或判定需要改變需求摘要與已確認設計 | 升級 | 交同線 `Analyst` 依需求摘要原文裁決，裁決不了時交使用者 |

### 收下後的處理

收下當下先執行下列兩步，不論審查結論為何。

1. 把報告 `## 例外回報` 節的條目併入同線 `<work-root>/.local/ai-sessions/report/<lineSlug>/exceptions.md`。
2. 把報告複製為同線 `<work-root>/.local/ai-sessions/report/<lineSlug>/<report_name>`，覆寫既有檔。同線後續 Session、需求意圖驗收與下一輪派遣檔的 `required_reads` 都使用這個路徑。

再依報告「總覽」的結論行與 manifest `findings` 決定下一站。結論行與 manifest 不一致時以 manifest 為準，並把不一致記入回收紀錄。

| 審查結論 | 下一站 |
| --- | --- |
| `fail`：`status=open` 的 finding 含 `Critical` 或 `Major` | 依共同收斂契約退回實作者修正，修正後以下一輪派遣檔複審。修正派生的處置表見 `workflow-orchestration` skill `references/review-procedures.md` |
| `pass`，仍有 `status=open` 的 `Minor` | 不再複審。依共同收斂契約判定順序 1，一次批次修正或記為候選 |
| `pass`，沒有 `open` 的 finding | 進入需求意圖驗收 |

### 事實校閱與影像產生的回收

依序核對下列各項，全部成立為「收下」。任一項不成立時以同一份派遣檔重跑，並在 `## 任務` 補一行指出上一份報告缺少的部分；`source_changed` 為 `true` 的處置同審查。

1. 讀 `final.report_path` 的報告全文，確認報告含派遣檔 `## 回報必備欄位` 要求的各節。事實校閱的報告格式依 `fact-check-note` skill「報告格式」，每個 `❌` 條目附官方依據。
2. 確認 `final.source_changed` 為 `false`。
3. 逐條核對派遣檔 `## 驗收條件`。影像產生另確認報告列出的每個影像檔都在輸出目錄內且非空；影像品質由人判斷。

收下後先把報告 `## 例外回報` 節的條目併入同線 `exceptions.md`，再依類型處理。

- 事實校閱：同線 `report/<lineSlug>/fact-check-report.md` 已存在時，先依 `fact-check-note` skill「寫入前 Rotation」改名，再把報告複製為該路徑，接著進入 `apply-fact-check`。
- 影像產生：把影像從輸出目錄複製到派遣要求的落點。輸出目錄保留原檔。

## 帳號

- 入口依登記順序選第一個可用帳號。已登入、該檔位的設定檔存在，且檔位的主要 model 或任一備援 model 未被記為該帳號不支援，三項都成立才算可用。全部帳號都被記為不支援時，入口取記錄時間最早的帳號以主要 model 實際嘗試一次。
- 備援 model 取自登錄表該檔位的 `profileSettings.fallbackModels`。帳號的主要 model 已被記為不支援時，入口以 `-c model=<備援 model>` 改用第一個未被記為不支援的備援 model，其餘設定沿用檔位設定檔。
- 服務端拒絕且尚無任何進度時，拒絕原因為 model not supported 者改試同一帳號的下一個 model，其餘原因改試下一個帳號。同一帳號的同一個 model 不重送。
- 拒絕原因為未授權時，PowerShell 版重新登入命令原文轉給使用者。命令在結果 JSON 的 `attempts[].relogin_command`（每次嘗試各一個）與 `final.relogin_command`（最後一次嘗試），其餘嘗試為 `null`，stderr 不輸出。
- 帳號因登入檔缺少或為空而被略過時，分兩種情形。全部帳號都被略過、結束碼為 4 時，含重新登入命令的略過摘要寫在 `error.message`，stderr 輸出同一則訊息，命令原文轉給使用者。仍有可用帳號時，入口只在 stderr 列出被略過帳號的名稱與原因代碼，沒有重新登入命令，結果 JSON 的 `attempts` 與 `final` 也只含實際嘗試的帳號。
- 結束碼 4 且 `error.code` 為 `CodexAccountsAllUnavailable` 或 `CodexAccountsExhausted` 時，入口已以該檔位的執行者離線呼叫選派入口，結果在 `fallback`：`unavailable_executor` 是不可用的執行者 id，`selection` 是選派入口的輸出原文。以 `selection.dispatchLine` 作為判定行，依 `selection.status` 與 `executor-selection` skill「狀態處置」處置；選出 Claude 執行者時沿用同一份派遣檔，依 `workflow-orchestration` skill `references/review-procedures.md`「Claude 審查者的發動」派出。`test` 只做瀏覽器與桌面的 MCP 臨場操作，入口以 `-Tags browse` 重新選派，`selection.status` 必為 `stopped`，停止並回報使用者。`fallback` 為 `null` 時，改以 `-Offline <執行者 id>` 手動呼叫選派入口。入口不保存不可用的狀態，下一次新的派工照常先選 Codex。
- 選定帳號後、啟動 Codex 前，入口只讀比對實際要使用的帳號目錄內該檔位的設定檔與主 checkout（`machine.json` 所在 repo）的產生檔（內容相同，CRLF 與 LF 視為相同；若是連結必須指向該產生檔），並確認產生檔等於登錄表預期內容。不一致時以結束碼 2、`CodexProfileDrift` 停止，不改檔，不跳到下一個帳號。換帳號後對新的候選帳號在使用前同樣比對，未使用的候選帳號不一致不阻擋。檔位設定檔的來源是登錄表 `profileSettings`，產生與連結方式見 README §3「Codex profile 檔位設定」。
- 入口不做專案信任預檢，也不自動補信任。

## 成本列

入口在每次嘗試結束時對同線 `cost-ledger.md` 追加一列 `事件`，含被服務端拒絕而沒有用量的嘗試。成本列寫入失敗（結束碼 1、`stopped`）時該次嘗試沒有成本列。一條線的成本以 `scripts/Get-LineCost.ps1` 計算。帳號與拒絕種類寫在備註欄，格式為 `exit=…;result=…;task=…;account=…;rejection=…;usage=…`。協調者不需為這些嘗試手寫列。

## 重跑

重跑使用同一份派遣檔與同一個 `dispatch_slug`，入口以時間戳與隨機碼區分每次執行，不會覆寫前一次的輸出。逾時的執行已由入口終止並寫入結果，直接重跑。主 Agent 手動終止背景命令時，執行紀錄沒有結束時間，不影響下一次發動。

## 切回現行入口

把登錄表對應執行者的 `entry` 改回 `scripts/Invoke-CodexDispatch.ps1` 後，選派結果即指向現行入口。

- `codex-review`：現行入口的 Collect 檢查的是舊格式的審查報告，`reviewer.toml`、`frontend-reviewer.toml` 與 `contract-auditor.toml` 目前只產出新格式，切回時需一併還原三份的報告格式。
- `codex-scan`：現行入口在 dispatch worktree 內以可寫沙盒建置、測試與截圖，不掛 MCP。切回時一併把登錄表 `codex-scan` 的 `build-test` 標籤加回，並還原 `integration-verify`、`browser-smoke`、`desktop-smoke` 與 `api-smoke` 的派遣分界。
- `codex-content`：事實校閱與影像產生一起切回。`fact-check-note` skill「派遣發動」需一併還原為現行入口的派遣單寫法（唯讀 sandbox、`--search` 由 Request 指定、報告落點為派遣單第 7 欄）。
