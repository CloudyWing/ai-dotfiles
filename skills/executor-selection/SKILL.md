---
name: executor-selection
description: '派工執行者選派：替任務標註類型、旗標與標籤，呼叫 Select-DispatchExecutor.ps1 依執行者登錄表選出執行者，並處理離線改派、執行者轉移與交接單。Use when 需要判定派工執行者、標註任務、發動選派入口、處理 Codex 離線或執行者轉移時。'
audience: agent
policy.allow_implicit_invocation: true
---

# 派工執行者選派

本 Skill 把「這份工作交給誰」交給資料與腳本判定。執行者清單、受理類型、能力標籤、條件、排序值、優先條件、未完成次數上限與備援 model 只存在登錄表 `scripts/dispatch/executor-registry.json`，選派由 `scripts/Select-DispatchExecutor.ps1` 執行。本 Skill 定義標註語意、入口用法、各狀態的處置與執行者轉移的交接單。是否進入登錄表判定、不派清單、下限三題與小型修改例外由 `rules/claude/30-dispatch.md`「派工判準」規定。

## 使用時機

- 讀取本 Skill 的時點為工作已通過 `rules/claude/30-dispatch.md` 的不派清單與下限三題，需要由主 Agent 以外的執行者處理時。
- 確認選出 Codex 執行者後，再載入 `codex-dispatch` skill 走資源派遣；選出 Claude 執行者時不經 `codex-dispatch`。
- 修改登錄表或選派入口時，依「擴充登錄表」執行。

## 任務標註

主 Agent 依工作內容標上下列項目，再呼叫選派入口。標註錯誤由入口以結束碼 2 拒絕，不自動修正。

### 類型

| `type` | 內容 |
| --- | --- |
| `edit` | 修改專案原始檔（含測試碼）與批次改檔；文件最終編輯（結案前文件同步）以 `E=否`、`T=否` 標註（見 `workflow-orchestration` skill `references/doc-sync.md`） |
| `survey` | 盤點、跨檔取證、診斷指令、單元測試與建置的執行及回報、文件一致性檢查（結案前文件同步）。不修改專案原始檔 |
| `design` | 設計起草：`Architect` 起草 `design.md`、`Prototyper` 起草 Demo 畫面。不修改專案原始檔 |
| `test` | 煙霧驗證的取證，例如 `integration-verify`、`browser-smoke`、`desktop-smoke`、`api-smoke` 的操作與擷取 |
| `generate` | 影像產生 |
| `factcheck` | 事實校閱、事實查核與上網查證 |
| `review` | 審查，含 `Reviewer`、`Frontend Reviewer`、`Contract Auditor`。三者依 `executor.entry` 發動 |
| `advise` | 顧問諮詢（高風險決策的跨家族交叉檢查），只有 Codex `advisor` 受理 |

### 旗標

旗標只決定執行者是否受理，不描述能力。各類型必填的旗標由登錄表 `types.<type>.requiredFlags` 決定，類型未要求的旗標不得提供。

| 旗標 | 為真的條件 |
| --- | --- |
| `E`（範圍已列舉） | 全部目標檔案與修改位置可於派工前以絕對路徑與符號逐一列出 |
| `T`（需要測試循環） | 符合任一項即為真。修改行為邏輯或修 bug；新增或調整測試；預期驗證命令需執行超過 1 次。純機械展開（重新命名、搬移、格式、樣板、對映表套用、註解補齊）且驗證至多 1 次者為假 |

Workflow 的判定單位為 `design.md` 的 Phase。E=是代表該 Phase 的每條 T-code 皆含動詞、完整檔案路徑與修改位置；T 另計 Checkpoint 需執行建置或測試命令超過 1 次的情形（靜態 Grep、檔案比對與結案 gate 的建置與測試各一次不計）。

### 標籤與優先條件

任務的條件分兩種。必要條件不符合的執行者直接排除；優先條件只影響候選的先後，未滿足的執行者仍可被選中。

- 必要條件：受理該類型、旗標符合執行者的 `when`，以及硬能力。硬能力以 `-Tags` 傳入，與該類型的 `impliedTags` 取聯集後，必須是執行者能力的子集。
- 優先條件：該類型在登錄表宣告的 `preferred`，任務可用 `-Prefer` 依重要性追加。值為硬能力標籤或 `family`。
- 類型特徵 `skippable`：登錄表在類型上宣告，表示這類工作沒有可選候選時可以不做。沒有候選時入口回傳 `omitted`，不回傳 `stopped` 或 `needs-user-decision`。未宣告視為否。

| 標籤 | 種類 | 意義 |
| --- | --- | --- |
| `write` | 硬能力 | 修改專案原始檔。`.local/ai-sessions/` 下的報告與暫存不算。只允許 `edit` 使用 |
| `build-test` | 硬能力 | 執行建置與測試命令 |
| `web` | 硬能力 | 上網查證 |
| `browse` | 硬能力 | 操作瀏覽器，含登入流程。只允許 `test` 使用 |
| `desktop-control` | 硬能力 | 控制 Windows 桌面程式、擷取桌面截圖。只允許 `test` 使用 |
| `image-gen` | 硬能力 | 產生影像 |
| `family` | 優先條件 | 執行者家族不等於實作者家族，以 `-ImplementerFamily` 傳入實作者家族。`review` 預設帶這個優先條件 |
| `gated` | 約束 | 執行者需使用者當輪授權，以 `-Authorized` 表示已取得 |

`review` 必須提供 `-ImplementerFamily`。Codex 不承擔實作，實作者家族目前恆為 `claude`。

## 選派入口

```powershell
pwsh -NoProfile -File scripts/Select-DispatchExecutor.ps1 -Type <type> `
  [-E <true|false>] [-T <true|false>] [-Tags <標籤,標籤>] [-Prefer <條件,條件>] `
  [-ImplementerFamily <claude|codex>] [-Authorized] [-Offline <執行者 id,執行者 id>] `
  [-Incomplete <執行者 id:次數,執行者 id:次數>] [-Label <說明>] [-RegistryPath <路徑>] [-Describe]
```

- 以逗號連接 `-Tags`、`-Prefer`、`-Offline` 與 `-Incomplete` 的多個值，不含空白，例如 `-Offline codex-test,codex-factcheck`。`pwsh -File` 與同一行程 `&` 呼叫都適用這個寫法。以空白分隔時，多餘的值會成為位置參數，入口以結束碼 2、錯誤碼 `SelectorParameterBinding` 拒絕。
- 傳入 `-Incomplete` 的次數為 0 至 999 的整數，同一 id 只能出現一次（重複時即使次數相同也以 `SelectorIncompleteInvalid` 拒絕）。上限 999 與登錄表 `maxIncomplete` 的上限相同。
- 輸出 stdout 單一 JSON 物件（schema `ai-agents.executor-selection.v1`），欄位含 `status`、`executor`、`unmetPreferences`、`candidates`、`skipped`、`requiresUserDecision`、`reason`、`considered` 與 `dispatchLine`。Claude 執行者的 `executor` 含 `model` 與 `selfRepair`（驗證失敗時可否自行修正重跑）；Codex 執行者的 `executor` 含 `profile` 與 `entry`，`entry` 的值為該執行者使用的入口腳本。
- 輸出 `dispatchLine` 原文作為本輪的 `[派工]` 判定行，不自行改寫。該行格式為 `[派工] 交給 <執行者顯示名>：<做什麼>，<條件的白話說明>`，選中者未滿足優先條件或有執行者被略過時，於行尾以分號附白話說明，對照見「判定行的白話對照」。`type`、`E`、`T` 只用於標註與 JSON 欄位，不出現在判定行。
- 查詢 `-Describe` 取得登錄表目前的類型、旗標需求、優先條件、未完成次數上限與執行者，不做選擇。
- 選派入口無副作用，只讀登錄表，不寫檔、不呼叫網路、不查額度。離線狀態與未完成次數一律由呼叫端傳入，入口不保存。

選擇演算法如下，結果只由輸入與登錄表決定。

1. 過濾出候選：受理該類型、能力涵蓋有效標籤、`when` 全部符合的執行者。
2. 排序候選：依有效優先條件逐項比較，滿足者在前；第一項相同再比下一項，全部相同時排序值小者在前。結果輸出為 `candidates`。
3. 依序略過 `-Offline` 列出者（理由 `offline`）與 `-Incomplete` 次數達登錄表 `maxIncomplete` 者（理由 `incomplete-limit`），第一位未被略過者為選中者。被略過者輸出為 `skipped`。
4. 選中者需授權且未提供 `-Authorized` 時為 `needs-authorization`，否則為 `selected`。選中者未滿足的優先條件輸出為 `unmetPreferences`。
5. 沒有選中者時：沒有候選為 `stopped`（`no-eligible-executor`）；候選全部被略過且至少一位是因未完成次數達上限為 `needs-user-decision`，其餘被略過者可以是離線；全部只因離線被略過為 `stopped`（`offline`）。類型宣告 `skippable` 時，上述三種情形一律為 `omitted`，`reason` 不變。

### 判定行的白話對照

`dispatchLine` 由選派入口依下表組出，登錄表未列的類型與旗標以原名顯示。

| 項目 | 判定行寫法 |
| --- | --- |
| `edit` | 改檔 |
| `survey` | 盤點取證 |
| `design` | 設計起草 |
| `test` | 測試取證 |
| `generate` | 產生影像 |
| `factcheck` | 事實查核 |
| `review` | 審查 |
| `advise` | 提供顧問意見 |
| `E` 為真、`T` 為假 | 範圍已列明、不需建置測試 |
| `E` 為真、`T` 為真 | 範圍已列明、需要建置測試 |
| `E` 為假、`T` 為假 | 範圍需自行探索、不需建置測試 |
| `E` 為假、`T` 為真 | 範圍需自行探索、需要建置測試 |
| 狀態 `selected` | `交給 <執行者顯示名>` |
| 狀態 `needs-authorization` | `等你授權後交給 <執行者顯示名>` |
| 狀態 `needs-user-decision` | `需你決定，目前沒有可交付的執行者` |
| 狀態 `omitted` | `不執行，沒有可用的執行者，這項工作可以不做` |
| 狀態 `stopped` | `停止，沒有可用的執行者` |
| 未滿足優先條件 `family` | `找不到不同模型家族的執行者，改由同家族審查` |
| 略過理由 `offline`、`incomplete-limit` | `已略過 <id>（離線）`、`已略過 <id>（未完成次數已達上限）` |

範例：`[派工] 交給 <執行者顯示名>：改檔，範圍已列明、不需建置測試`。有 `-Label` 時，說明置於動詞之前，例如 `[派工] 交給 <執行者顯示名>：P3 重構，改檔，範圍需自行探索、需要建置測試`。

主 Agent 自己做時不呼叫入口，判定行為 `[派工] 自己做（<原因>）：<一句話理由>`，原因為下列三種之一。

| 原因 | 適用 |
| --- | --- |
| `需要對話脈絡` | 命中 `rules/claude/30-dispatch.md` 的不派清單 |
| `小改動` | 三題全否或符合小型修改例外 |
| `難以交代清楚` | 工作需要對話脈絡、無法寫成任務標註，且不會污染主 Agent context |

### 狀態處置

| 狀態 | 結束碼 | 主 Agent 處置 |
| --- | --- | --- |
| `selected` | 0 | Claude 執行者以 Agent 工具派生，`model` 取自 `executor.model`；Codex 執行者載入 `codex-dispatch`，讀取 `references/run.md` 並以派遣檔發動，`profile` 取自 `executor.profile`。`unmetPreferences` 含 `family` 時為同家族審查，屬選派的正常結果，不追加 exceptions，在報告註明實際執行者。`skipped` 非空時在報告或回報註明原應承接者 |
| `needs-user-decision` | 10 | 類型未宣告 `skippable`，候選全部不可選，且至少一位是因未完成次數達上限被略過；其餘候選可能是離線，不代表也達到上限。停止該任務，依 `skipped` 的理由分開回報：`incomplete-limit` 者附未完成紀錄與證據，`offline` 者附服務端拒絕的證據，由使用者決定 |
| `needs-authorization` | 20 | 輸出 `rules/claude/30-dispatch.md` 規定的 `[advisor 諮詢授權]` 請求，等待使用者當輪回覆 |
| `omitted` | 21 | 類型宣告 `skippable`，且沒有可選候選（全部離線、未完成次數達上限，或沒有執行者受理）。這項工作不執行，協調者依自己的判斷續行，不向使用者提問，也不改由其他執行者頂替；回報註明未執行與 `skipped` 的原因 |
| `stopped` | 22 | 回報使用者，附 `reason` 與已查範圍，不以其他執行者頂替硬能力 |
| 標註無效 | 2 | 依 stderr 錯誤碼修正標註後重新呼叫 |
| 登錄表無效 | 3 | 停止派工，回報錯誤碼與登錄表路徑 |

## 離線與帳號判定

離線的政策由 `rules/claude/30-dispatch.md`「離線改派」規定，本節補充執行方式。

- 判定離線的唯一來源是服務端拒絕，額度數值不參與。拒絕包含 usage-limit、401、model not supported、rate limit，以及尚無 item 進度即以未分類錯誤終局失敗者。model not supported 表示該帳號的方案不含檔位設定的 model，停用訂閱的帳號也以此訊息呈現，視為該帳號不可用。
- 派工時不指定 `-CodexHome`。`Invoke-CodexRun.ps1` 依 `machine.json` `codex_accounts` 登記順序選第一個可用帳號，遭服務端拒絕且尚無 item 進度時自動改試下一個帳號，重試只限換帳號，同一帳號不重送。帳號回報 model not supported 後記入帳號健康狀態檔，24 小時內略過該帳號與檔位 model 的組合。細節見 `codex-dispatch` skill `references/run.md`「帳號」。
- 帳號不支援檔位的主要 model 時，`Invoke-CodexRun.ps1` 改用登錄表 `profileSettings.fallbackModels` 中第一個未被記為不支援的備援 model，執行紀錄與結果 JSON 的 `model` 記錄實際使用的 model，`model_source` 記錄它是檔位的主要 model（`primary`）或備援 model（`fallback`）。備援 model 也都不支援時才略過該帳號。
- `Invoke-CodexRun.ps1` 回報 `CodexAccountsAllUnavailable` 或 `CodexAccountsExhausted` 時，結果 JSON 的 `fallback.selection` 已是選派入口以該執行者離線重新選出的結果，直接依其 `status` 與 `dispatchLine` 處置；`fallback` 為 `null` 時，由主 Agent 把不可用的 Codex 執行者 id 以逗號連接傳入 `-Offline` 重新呼叫選派入口。Codex 不可用時 `factcheck`、`review` 由登錄表中受理該類型的 Claude 執行者承接，`generate` 回傳 `stopped`，宣告 `skippable` 的類型回傳 `omitted`。經 `Invoke-CodexRun.ps1` 的 `test` 只做瀏覽器與桌面的 MCP 臨場操作，入口以 `-Tags browse` 重新選派，選出 Sonnet，依「Claude 測試取證者派生契約」承接；不含這兩類操作的測試取證（`build-test`）本來就不走 Codex，由呼叫端標註 `build-test` 選到 Claude 執行者。
- 不可用的狀態不保存，也不採信拒絕訊息附的恢復時間。下一次新的派工不帶 `-Offline`，照常先選 Codex，被拒才再換。

## Claude 取證者派生契約

`survey` 選出的 `executor.platform` 為 `claude` 時，以 Agent 工具派生冷啟動取證者。

- 設定 `subagent_type` 為 `general-purpose`、`model` 為選派結果的 `executor.model`。
- 寫入 prompt 的內容含 `LineContext`、目標物件絕對路徑、待答問題、已知證據、待驗假設與可能反證、輸出落點 `<work-root>/.local/ai-sessions/report/<lineSlug>/survey-<slug>.md`。
- 要求回傳每個結論的來源位置與支持判定的原始摘錄，證據不足時明寫不足之處。
- 限制取證者唯讀，不修改專案原始檔，不執行 git 寫入命令。
- 保留根因假設的形成與結論在主 Agent。回收時依回收三態判定，證據不足時退回取證者，主 Agent 不改以零碎查詢補足。

## Claude 測試取證者派生契約

`test` 選出的 `executor.platform` 為 `claude` 時，以 Agent 工具派生冷啟動的測試取證者。標註含 `build-test` 的 `test`（例如 API 煙霧驗證、單元測試與可重跑 E2E 的取證）選出 Claude 執行者，因為 Codex `test` 檔位只做 MCP 臨場操作（標籤 `browse`、`desktop-control`、`web`），不執行建置與測試命令。標註含 `browse` 或 `desktop-control` 的 `test` 以 Codex `test` 優先，Codex 不可用或未完成次數達上限時選出 Sonnet，另依「瀏覽器與桌面操作」承接。

- 設定 `subagent_type` 為 `general-purpose`、`model` 為選派結果的 `executor.model`。
- 寫入 prompt 的內容含 `LineContext`、呼叫端 skill 規定的驗證步驟與命令、目標端點或檔案的絕對路徑、預期結果，以及輸出落點 `<work-root>/.local/ai-sessions/report/<lineSlug>/test-<slug>.md`。
- 要求逐條回報命令原文、完整 stdout、完整 stderr、exit code 與執行時間，不只回報結論。
- 限制取證者不修改專案原始檔，不執行 git 寫入命令；需要啟動的背景進程在回報前關閉，刻意保留者附 port 或 PID。
- 保留判讀與修正迴圈決策在主 Agent，回收時依回收三態判定。不追加 exceptions。

### 瀏覽器與桌面操作

標註含 `browse` 或 `desktop-control` 的 `test` 選出 Claude 執行者時，取證者以 Claude 使用者層登記的 Playwright MCP（網頁）與 FlaUI.Mcp（桌面）操作，執行紀錄與回收核對比照 Codex `test`。同時含 `build-test` 者，建置與測試命令依上一節，MCP 操作依本節。登記由使用者以 `scripts/Register-McpServer.ps1 -Playwright -FlaUI` 完成，紀錄依賴 `ai-agents-hooks` plugin 的 MCP 呼叫紀錄 hook。

發動流程：

1. 啟動受測對象並確認可達（網頁以 `http://127.0.0.1:<埠>` 等形式可開啟，桌面程式視窗已顯示）。取證者不啟動受測程式、不建置。
2. 撰寫派遣檔 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/run-order-<dispatchSlug>.md`：`task_type` 與 `profile` 皆為 `test`，`role_file` 填派遣檔本身，`targets` 只列要比對變動的來源檔或目錄（不含 `bin`、`obj`、記錄檔），登入測試時填 `test_context_file`。欄位與章節依 `codex-dispatch` skill `references/run.md`「發動」。
3. 執行 `pwsh -NoProfile -File scripts/Write-ClaudeRunRecord.ps1 -Action Start -DispatchFile <派遣檔> -ExecutorId sonnet`，取 stdout 的 `output_dir` 與 `report_path`。
4. 以 Agent 工具派生冷啟動取證者，prompt 依下列「prompt 必含」。
5. 取證者回報後執行 `pwsh -NoProfile -File scripts/Write-ClaudeRunRecord.ps1 -Action End -DispatchFile <派遣檔> -ExecutorId sonnet -AgentId <Agent 工具回傳的 agentId>`。省略 `-AgentId` 時以時間窗內唯一有紀錄的 subagent 判定，有多個時以結束碼 2、`ClaudeRunAgentAmbiguous` 拒絕，補上 `-AgentId` 再執行 End。
6. Start 到 End 之間，主 Agent 不呼叫 `playwright`、`flaui-mcp` 的工具；同一時間只派一位本節的取證者，因為瀏覽器 profile 與桌面輸入共用。

prompt 必含：

- `LineContext`、派遣檔絕對路徑（要求先完整讀取）、`output_dir`、`report_path`。
- 受測對象（網址，或視窗行程名稱與標題）、逐條操作步驟與每步預期、驗收條件編號。
- 工具範圍：只用登錄表 `codex-test` 的 `profileSettings.mcpServers.*.enabledTools` 列出的工具。Playwright 為 `browser_navigate`、`browser_navigate_back`、`browser_snapshot`、`browser_click`、`browser_hover`、`browser_type`、`browser_fill_form`、`browser_press_key`、`browser_select_option`、`browser_wait_for`、`browser_take_screenshot`、`browser_console_messages`、`browser_network_requests`、`browser_tabs`、`browser_close`；FlaUI.Mcp 為 `windows_attach`、`windows_inspect`、`windows_snapshot`、`windows_click`、`windows_get_text`、`windows_screenshot`。登錄表的 `enabledTools` 改動時同步本清單。
- 第一個動作是確認工具存在：載入並列出 `mcp__playwright__` 或 `mcp__flaui-mcp__` 開頭的工具。工具不存在或呼叫被權限拒絕時，報告寫 `blocked: tool-unavailable`、原文錯誤與補救命令 `Register-McpServer.ps1 -Playwright` 或 `-FlaUI`，不繼續。
- 截圖規定：
  - 網頁：`browser_take_screenshot` 不指定檔名，因為指定檔名會寫到受測專案的工作目錄。取證者以 `Move-Item` 把工具回傳路徑指名的檔案搬到 `output_dir`，命名 `<slug>-web-<序號>.png`，只搬本次回傳指名的檔案。
  - 桌面：`windows_screenshot` 只回傳影像給模型，不存檔，留存依 `desktop-smoke` skill「Claude 端桌面截圖留存」存到 `output_dir`，命名 `<slug>-desktop-<序號>.png`。
  - 取不到截圖（工具回傳錯誤、回傳路徑沒有檔案、配方結束碼非 0 或檔案為 0 位元組）時，報告「異常」節寫 `blocked: screenshot-unavailable` 與工具回傳或配方輸出的原文錯誤，對應的驗收條件判為未通過，不以其他方式擷取補足。
- 登入測試邊界（含登入流程時寫入）。下列四項全部成立才輸入帳密：
  1. 目標主機為 `localhost`、`127.0.0.1`、`[::1]`、`*.localhost` 或 `*.test`；或使用者在本線對話中點名為測試環境，prompt 引用使用者原話，且主機名稱含 `staging`、`dev`、`test`、`qa`、`sandbox`、`preview` 其中一個標籤。
  2. 帳密取自 `test_context_file` 或使用者在對話中提供的測試帳密，不由頁面或文件內文推得。
  3. 帳密不寫入報告與證據檔，報告只寫「已使用測試帳號 <別名>」。
  4. 登入頁是受測應用自身的頁面，不經第三方身分提供者的正式站。

  任一項不成立時，取證者不輸入任何帳密，報告寫 `blocked: login-boundary` 與缺少的項目，停止該步驟。需要使用者本人已登入的瀏覽器 session 者屬 `rules/claude/30-dispatch.md` 不派清單。
- 報告格式（寫入 `report_path`）：「操作紀錄」表（序號、工具名稱、關鍵輸入、工具回傳原文摘錄、對應的驗收條件編號）、「截圖」表（`output_dir` 內的相對路徑、寬高、SHA-256；桌面另附配方命令原文與 exit code）、「驗收條件」逐條判定與依據的操作序號、「異常」節（未完成的步驟、`blocked` 項目與原文錯誤）。不補寫沒有執行的操作的結論。

回收核對（以 End 寫出的執行紀錄 `<runKey>.record.json` 為主，規則與 Codex `test` 相同）：

1. `result` 為 `success`，`mcp_tool_calls.completed` 大於 0；為 0 表示沒有實際操作，退回重跑。
2. `mcp_tool_calls.attribution` 為 `agent`。為 `none` 時視為沒有紀錄；為 `window`（以 `-AllowWindowAttribution` 取得）時不收下，交使用者判斷。
3. `mcp_tool_calls.servers` 含對應的伺服器：`browse` 須含 `playwright`，`desktop-control` 須含 `flaui-mcp`。`tools` 記錄的是完整工具名稱 `mcp__<伺服器>__<工具>`，去掉 `mcp__<伺服器>__` 前綴後的名稱須全部在工具範圍內，且前綴的伺服器與該工具所屬的伺服器一致。
4. 報告「操作紀錄」的列數不多於 `completed` 加 `failed`，每列的工具名稱（報告寫簡稱或完整名稱皆可，依第 3 項的規則對應）出現在 `tools`；`failed` 不為 0 時「異常」節逐筆說明。`mcp_tool_calls.skipped` 不為 0 表示有紀錄檔無法剖析或歸屬不符，這些呼叫不計入第 1 項，報告宣稱的操作若因此對不上紀錄則不予採信。
5. 報告「截圖」表的檔案都在 `artifacts` 內，`artifacts` 中報告以外的檔案都在報告說明用途。每張截圖的前 8 個位元組為完整的 PNG 簽章 `89 50 4E 47 0D 0A 1A 0A`、大小大於 0，SHA-256 與報告一致；主 Agent 以 Read 檢視至少一張截圖，確認畫面與報告描述相符。
6. 網頁取證：主 Agent 啟動受測服務時把存取紀錄導向檔案，回收時確認紀錄含報告宣稱開啟的路徑，且時間在 Start 之後。受測服務不是主 Agent 啟動、取不到存取紀錄時，在回收結果註明此項無法核對。
7. `source_changed` 與 `mcp_stray_output.exists` 為 `true` 時的處置同 `codex-dispatch` skill `references/run.md`「測試取證（test）」。
8. 任一項不成立時依回收三態退回，依「執行者轉移與交接單」計次。下列屬環境成因，依 `rules/claude/30-dispatch.md`「派工後的殘餘工作」第 1 項處理，不計次：`blocked: tool-unavailable`、`blocked: login-boundary`、受測對象不可達、hook 未載入（`attribution` 為 `none` 且報告有工具回傳原文）。`blocked: screenshot-unavailable` 依報告的原文錯誤判定成因，判定不出環境成因時照一般未完成計次。取證者不自動重試同一操作，逾時與載入失敗如實記錄；主 Agent 不以清單外的工具或其他方式補足沒有執行的操作。
9. 收下後把需要保留的截圖複製到 `<work-root>/.local/ai-sessions/screenshots/` 並在報告引用。

## 執行者轉移與交接單

執行者未完成工作的計次與轉移條件由 `rules/claude/30-dispatch.md`「執行者轉移」規定。同一任務累計三次未完成時，把該任務內各執行者的未完成次數（含先前已轉移走的執行者）以 `-Incomplete` 傳給選派入口。入口略過達到登錄表 `maxIncomplete` 的執行者，回傳候選清單的下一位。

- 保存：次數由 `scripts/Update-ExecutorIncomplete.ps1` 存在 `<work-root>/.local/ai-sessions/report/<lineSlug>/executor-incomplete.json`，使用前同線須已登記（`line.json` 存在且 `line-slug` 相符，一次性工作登記為 `kind` 為 `adhoc` 的線），缺少時腳本以結束碼 2 拒絕；一條線可有多個任務，以 `-Task` 區分（Workflow 的 Developer 派工整體算一個任務）。腳本只保存與輸出，不判斷該不該計次；選派入口維持無副作用，不讀這個檔。交接檢查點、派遣輸入與回報檔不另抄寫次數。
- 加一次：回收判定為未完成之後、下一次派出或轉移之前執行 `pwsh -NoProfile -File scripts/Update-ExecutorIncomplete.ps1 -Action Add -WorkRoot <work-root> -LineSlug <lineSlug> -Task <任務> -ExecutorId <執行者 id> -Reason <原因類別> -Evidence <證據位置>`。原因類別為 `acceptance-failed`、`collect-returned`、`review-rejected`、`self-reported`。經判定屬環境或硬能力成因而不計者不執行。
- 取值：呼叫選派入口前以相同的 `-WorkRoot`、`-LineSlug`、`-Task` 執行 `-Action Show`，把輸出的 `incomplete_argument` 原樣作為 `-Incomplete` 的值，內容依執行者 id 排序並含已轉移走的每一位。`pass_incomplete` 為 `false`（全部執行者皆為 0）時不帶 `-Incomplete`。
- 接手：換 Session 或脈絡壓縮之後，先執行 `-Action Show` 取得完整對照再決定下一步。非 Workflow 的工作若最近一份回報尚未完成回收判定（沒有更晚的派出，任務也未收下），先對該回報做回收判定，未完成時為該執行者加一。任務已派出過卻沒有該任務的紀錄時，依同線的回報檔、交接單與 exceptions 條目確認有無漏記的未完成並補 Add；無法確認時停止並回報，不從 0 起算。
- 重設：任務收下之後執行 `-Action Reset`，換任務從頭起算。任務未收下前不重設，轉移不清除先前執行者的次數。
- 轉移不需使用者拍板。選派入口回傳 `selected` 時直接轉給下一位，並追加 exceptions「替代方案」，內容含轉移當下的完整未完成次數對照（取自 `-Action Show` 的 `incomplete_argument`，含已轉移走的每一位），依據含原執行者未完成的原因與證據位置。回傳 `needs-user-decision` 時停止並回報。
- 整理交接單。由主 Agent 依 `templates/dispatch/escalation-handoff.md` 撰寫，不由未完成的執行者撰寫，落點為 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/escalation-handoff-<序號>.md`，序號自 1 遞增。
- 傳遞有執行證據且與做法無關的資訊。

| 欄位 | 內容 | 傳遞 |
| --- | --- | --- |
| 識別 | `lineSlug`、任務、原執行者 id、接手執行者 id、序號、未完成次數（轉移當下的完整對照，即選出接手者那一次呼叫所用的 `-Incomplete` 值）、原執行者各次未完成的證據位置 | 傳 |
| 已驗證限制 | 每項附證據位置（檔案絕對路徑與行號，或命令原文與輸出位置） | 傳 |
| 環境限制 | 每項附證據位置 | 傳 |
| 已排除做法 | 僅限有反證者，附反證位置，標為「可被新證據推翻」 | 傳 |
| 驗收條件 | 引用原驗收條件的路徑與列號，不改寫 | 傳 |
| 半成品處置 | 半成品程式碼同時通過語法檢查、既有測試與設計對照才列為起點；任一未通過時退回輪起點 SHA，舊 diff 只作參考並標「正確性未知」 | 傳 |
| 刻意不提供 | 前一位的計畫、推理、自我評估、未驗證假設與完整對話紀錄 | 不傳，於交接單明寫 |

- 退回起點時，先以 `git diff` 將舊 diff 存為 `<work-root>/.local/ai-sessions/report/<lineSlug>/escalation-prior-diff-<序號>.patch`，再由新執行者以 `git show <輪起點 SHA>:<path>` 的內容逐檔覆寫範圍內被改動的檔案。Claude subagent 的 git 寫入類命令禁令維持不變。
- 寫入「無」於沒有通過驗證證據的欄位，不補寫推測。證據位置無法開啟的項目移入「刻意不提供」並註明原因。
- 保留舊交接單。同線同時只有一份有效交接單，新的轉移以新序號建檔。
- 取證量大時，半成品是否通過的取證可交 `-Type survey` 選出的取證者，判定仍由主 Agent 做出。

## 擴充登錄表

1. 修改 `scripts/dispatch/executor-registry.json`，新增或調整執行者、類型或優先條件。標籤詞彙合計不超過 8 個，排序值全表唯一。每個 Codex 執行者必填 `entry`，值為相對於 repo 根目錄的入口腳本路徑，格式為 `scripts/<檔名>.ps1`；Claude 執行者不得有此欄位。每個 Codex 執行者另必填 `profileSettings`（`model`、`effort`、`subagentModel`、`subagentEffort` 四個字串），Claude 執行者不得有此欄位。`profileSettings` 另可選填 `fallbackModels`（字串陣列，依序，不得重複、不得含主要 model），供帳號不支援主要 model 時改用。每個 Claude 執行者另必填 `selfRepair`（布林，驗證失敗時可否自行修正重跑），Codex 執行者不得有此欄位。檔位設定檔由 `profileSettings` 的欄位產生，見步驟 4。
2. 確認每個類型至少有一位執行者受理，每個 Codex 執行者的 `profile` 在登錄表內唯一，且不在登錄表頂層的 `retiredProfiles`（已退役的檔位名稱）內；`profileSettings.effort` 與 `subagentEffort` 必須在頂層 `codexEfforts` 內。檔位名稱、退役名稱與 effort 允許清單都只存在登錄表，沒有第二份。`platform` 與 `id` 的格式同樣受驗證。登錄表的讀取與結構驗證只寫在 `scripts/lib/executor-registry.ps1`，選派入口、檔位設定檔的產生器、Setup、帳號建立與派工前比對都載入這個檔並呼叫同一組函式，不另有規則；要改驗證規則只改這個檔。類型的 `preferred` 只能列硬能力標籤或 `family`，含 `family` 時呼叫端必須提供 `-ImplementerFamily`；類型的 `skippable` 選填，必須為布林；頂層 `maxIncomplete` 為 1 至 999 的整數。已移除的欄位 `crossFamily`、`degradable`、`escalationOnly`、`escalatesTo`、`onOffline` 出現時登錄表無效。
3. 執行 `pwsh -NoProfile -File scripts/tests/Test-SelectDispatchExecutor.ps1`，全部通過才算完成。
4. 修改 `profile` 或 `profileSettings` 後，commit 時 `.githooks/Update-CodexProfiles.ps1` 會重新產生 `scripts/codex-profiles/<檔位>.config.toml` 並暫存；需要提早確認時手動執行 `pwsh -NoProfile -File .githooks\Update-CodexProfiles.ps1`。新增檔位後，各機器重跑 `scripts\Setup-AIGlobalConfig.ps1` 為帳號目錄建立連結；未建立或內容與產生檔不一致時，`Invoke-CodexRun.ps1` 在啟動前停止（`CodexProfileDrift`）。`-Describe` 輸出每個 Codex 執行者的 `profileSettings`（含 `fallbackModels`）。

## 各 delegate skill 的標註範例

frontmatter 宣告 `dispatch: delegate` 的 skill 不由主 Agent 自理，改依該 skill「## 任務標註」節呼叫選派入口。

| Skill | 標註 |
| --- | --- |
| `export-excel` | `-Type edit -E false -T false` |
| `generate-api-doc` | `-Type edit -E <依控制器與方法是否已逐一列出> -T false -Tags build-test` |
| `uiux-baseline` | `-Type survey` |
