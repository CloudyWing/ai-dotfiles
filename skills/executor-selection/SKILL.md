---
name: executor-selection
description: '派工執行者選派：替任務標註類型、旗標與標籤，呼叫 Select-DispatchExecutor.ps1 依執行者登錄表選出執行者，並處理離線改派、執行者轉移與交接單。Use when 需要判定派工執行者、標註任務、發動選派入口、處理 Codex 離線或執行者轉移時。'
audience: agent
policy.allow_implicit_invocation: true
---

# 派工執行者選派

本 Skill 把「這份工作交給誰」交給資料與腳本判定。執行者清單、受理類型、能力標籤、條件、排序值、優先條件、未完成次數上限與備援 model 只存在登錄表 `scripts/dispatch/executor-registry.json`，選派由 `scripts/Select-DispatchExecutor.ps1` 執行。本 Skill 定義標註語意、入口用法、各狀態的處置與執行者轉移的交接單。是否進入登錄表判定、不派清單、下限三題與小型修改例外由 `rules/claude/30-dispatch.md`「F1 派工判準」規定。

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
| `survey` | 盤點、跨檔取證、診斷指令、單元測試與建置的執行及回報、一般第二意見、文件一致性檢查（結案前文件同步）。不修改專案原始檔 |
| `test` | 煙霧驗證的取證，例如 `integration-verify`、`browser-smoke`、`desktop-smoke`、`api-smoke` 的操作與擷取 |
| `generate` | 影像產生 |
| `factcheck` | 事實校閱、事實查核與上網查證 |
| `review` | 審查，含 `Reviewer`、`Frontend Reviewer`、`Contract Auditor`。三者依 `executor.entry` 發動 |
| `advise` | 顧問諮詢（高風險決策的跨家族交叉檢查） |

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

| 標籤 | 種類 | 意義 |
| --- | --- | --- |
| `write` | 硬能力 | 修改專案原始檔。`.local/ai-sessions/` 下的報告與暫存不算。只允許 `edit` 使用 |
| `build-test` | 硬能力 | 執行建置與測試命令 |
| `web` | 硬能力 | 上網查證 |
| `browse` | 硬能力 | 操作瀏覽器，含登入流程 |
| `desktop-control` | 硬能力 | 控制 Windows 桌面程式、擷取桌面截圖 |
| `image-gen` | 硬能力 | 產生影像 |
| `family` | 優先條件 | 執行者家族不等於實作者家族，以 `-ImplementerFamily` 傳入實作者家族。`review` 與 `advise` 預設帶這個優先條件 |
| `gated` | 約束 | 執行者需使用者當輪授權，以 `-Authorized` 表示已取得 |

`review` 與 `advise` 必須提供 `-ImplementerFamily`。Codex 不承擔實作，實作者家族目前恆為 `claude`。

## 選派入口

```powershell
pwsh -NoProfile -File scripts/Select-DispatchExecutor.ps1 -Type <type> `
  [-E <true|false>] [-T <true|false>] [-Tags <標籤,標籤>] [-Prefer <條件,條件>] `
  [-ImplementerFamily <claude|codex>] [-Authorized] [-Offline <執行者 id,執行者 id>] `
  [-Incomplete <執行者 id:次數,執行者 id:次數>] [-Label <說明>] [-RegistryPath <路徑>] [-Describe]
```

- 以逗號連接 `-Tags`、`-Prefer`、`-Offline` 與 `-Incomplete` 的多個值，不含空白，例如 `-Offline codex-scan,codex-content`。`pwsh -File` 與同一行程 `&` 呼叫都適用這個寫法。以空白分隔時，多餘的值會成為位置參數，入口以結束碼 2、錯誤碼 `SelectorParameterBinding` 拒絕。
- 傳入 `-Incomplete` 的次數為 0 至 999 的整數，同一 id 只能出現一次（重複時即使次數相同也以 `SelectorIncompleteInvalid` 拒絕）。上限 999 與登錄表 `maxIncomplete` 的上限相同。
- 輸出 stdout 單一 JSON 物件（schema `ai-agents.executor-selection.v1`），欄位含 `status`、`executor`、`unmetPreferences`、`candidates`、`skipped`、`requiresUserDecision`、`reason`、`considered` 與 `dispatchLine`。Codex 執行者的 `executor` 另含 `entry`，值為該執行者使用的入口腳本。
- 輸出 `dispatchLine` 原文作為本輪的 `[派工判定]` 行，不自行改寫判定值。選中者未滿足優先條件時該行附 `未滿足優先條件=<名稱>`，`family` 寫成 `family（同家族審查）`；有執行者被略過時附 `略過=<id:理由>`。
- 查詢 `-Describe` 取得登錄表目前的類型、旗標需求、優先條件、未完成次數上限與執行者，不做選擇。
- 選派入口無副作用，只讀登錄表，不寫檔、不呼叫網路、不查額度。離線狀態與未完成次數一律由呼叫端傳入，入口不保存。

選擇演算法如下，結果只由輸入與登錄表決定。

1. 過濾出候選：受理該類型、能力涵蓋有效標籤、`when` 全部符合的執行者。
2. 排序候選：依有效優先條件逐項比較，滿足者在前；第一項相同再比下一項，全部相同時排序值小者在前。結果輸出為 `candidates`。
3. 依序略過 `-Offline` 列出者（理由 `offline`）與 `-Incomplete` 次數達登錄表 `maxIncomplete` 者（理由 `incomplete-limit`），第一位未被略過者為選中者。被略過者輸出為 `skipped`。
4. 選中者需授權且未提供 `-Authorized` 時為 `needs-authorization`，否則為 `selected`。選中者未滿足的優先條件輸出為 `unmetPreferences`。
5. 沒有選中者時：沒有候選為 `stopped`（`no-eligible-executor`）；候選全部被略過且至少一位是因未完成次數達上限為 `needs-user-decision`，其餘被略過者可以是離線；全部只因離線被略過為 `stopped`（`offline`）。

### 狀態處置

| 狀態 | 結束碼 | 主 Agent 處置 |
| --- | --- | --- |
| `selected` | 0 | Claude 執行者以 Agent 工具派生，`model` 取自 `executor.model`；Codex 執行者載入 `codex-dispatch`，依 `executor.entry` 讀取對應流程（`scripts/Invoke-CodexRun.ps1` 且角色為 `Reviewer` 時讀 `references/run.md` 並以派遣檔發動，不使用 `New-DispatchInputs.ps1`；其餘讀 `references/start.md`），`profile` 取自 `executor.profile`。`unmetPreferences` 含 `family` 時為同家族審查或同家族第二意見，屬選派的正常結果，不追加 exceptions，在報告註明實際執行者；`advise` 由 Sonnet 以一般第二意見承接時不需 `[advisor 諮詢授權]`。`skipped` 非空時在報告或回報註明原應承接者 |
| `needs-user-decision` | 10 | 候選全部不可選，且至少一位是因未完成次數達上限被略過；其餘候選可能是離線，不代表也達到上限。停止該任務，依 `skipped` 的理由分開回報：`incomplete-limit` 者附未完成紀錄與證據，`offline` 者附服務端拒絕的證據，由使用者決定 |
| `needs-authorization` | 20 | 輸出 `rules/claude/30-dispatch.md` 規定的 `[advisor 諮詢授權]` 請求，等待使用者當輪回覆 |
| `stopped` | 22 | 回報使用者，附 `reason` 與已查範圍，不以其他執行者頂替硬能力 |
| 標註無效 | 2 | 依 stderr 錯誤碼修正標註後重新呼叫 |
| 登錄表無效 | 3 | 停止派工，回報錯誤碼與登錄表路徑 |

## 離線與帳號判定

離線的政策由 `rules/claude/30-dispatch.md`「離線改派」規定，本節補充執行方式。

- 判定離線的唯一來源是服務端拒絕，額度數值不參與。拒絕包含 usage-limit、401、model not supported、rate limit，以及尚無 item 進度即以未分類錯誤終局失敗者。model not supported 表示該帳號的方案不含檔位設定的 model，停用訂閱的帳號也以此訊息呈現，視為該帳號不可用。
- 派工時不指定 `-CodexHome`。Dispatch 依 `machine.json` `codex_accounts` 登記順序選第一個可用帳號，遭服務端拒絕且尚無 item 進度時自動改試下一個帳號，重試只限換帳號，同一帳號不重送。帳號回報 model not supported 後記入帳號健康狀態檔，24 小時內略過該帳號與檔位 model 的組合。細節見 `codex-dispatch` skill「主 Agent 的帳號切換決策」。
- 帳號不支援檔位的主要 model 時，`Invoke-CodexRun.ps1` 改用登錄表 `profileSettings.fallbackModels` 中第一個未被記為不支援的備援 model，執行紀錄與結果 JSON 的 `model` 記錄實際使用的 model，`model_source` 記錄它是檔位的主要 model（`primary`）或備援 model（`fallback`）。備援 model 也都不支援時才略過該帳號。
- `Invoke-CodexRun.ps1` 回報 `CodexAccountsAllUnavailable` 或 `CodexAccountsExhausted` 時，結果 JSON 的 `fallback.selection` 已是選派入口以該執行者離線重新選出的結果，直接依其 `status` 與 `dispatchLine` 處置；`fallback` 為 `null` 時才手動帶 `-Offline` 呼叫。`Invoke-CodexDispatch.ps1` 回報 `CodexAccountsAllUnavailable` 後，由主 Agent 把不可用的 Codex 執行者 id 以逗號連接傳入 `-Offline` 重新呼叫選派入口。Codex 不可用時 `factcheck`、`review`、`advise` 與無 `browse`、`desktop-control` 標籤的 `test` 由 Sonnet 承接，`generate` 與帶上述標籤的 `test` 回傳 `stopped`。
- 不可用的狀態不保存，也不採信拒絕訊息附的恢復時間。下一次新的派工不帶 `-Offline`，照常先選 Codex，被拒才再換。

## Claude 取證者派生契約

`survey` 選出 Sonnet 時，以 Agent 工具派生冷啟動取證者。

- 設定 `subagent_type` 為 `general-purpose`、`model` 為 `sonnet`。
- 寫入 prompt 的內容含 `LineContext`、目標物件絕對路徑、待答問題、已知證據、待驗假設與可能反證、輸出落點 `<work-root>/.local/ai-sessions/report/<lineSlug>/survey-<slug>.md`。
- 要求回傳每個結論的來源位置與支持判定的原始摘錄，證據不足時明寫不足之處。
- 限制取證者唯讀，不修改專案原始檔，不執行 git 寫入命令。
- 保留根因假設的形成與結論在主 Agent。回收時依回收三態判定，證據不足時退回取證者，主 Agent 不改以零碎查詢補足。

## Claude 測試取證者派生契約

`test` 因 Codex 全離線而選出 Sonnet 時，以 Agent 工具派生冷啟動的測試取證者。只有標註不含 `browse`、`desktop-control` 的 `test` 會選出 Sonnet，例如 API 煙霧驗證與單元測試的取證。

- 設定 `subagent_type` 為 `general-purpose`、`model` 為 `sonnet`。
- 寫入 prompt 的內容含 `LineContext`、呼叫端 skill 規定的驗證步驟與命令、目標端點或檔案的絕對路徑、預期結果，以及輸出落點 `<work-root>/.local/ai-sessions/report/<lineSlug>/test-<slug>.md`。
- 要求逐條回報命令原文、完整 stdout、完整 stderr、exit code 與執行時間，不只回報結論。
- 限制取證者不修改專案原始檔，不執行 git 寫入命令；需要啟動的背景進程在回報前關閉，刻意保留者附 port 或 PID。
- 保留判讀與修正迴圈決策在主 Agent，回收時依回收三態判定。不追加 exceptions，在回報中註明原應由 Codex `scan` 承接。

## 執行者轉移與交接單

執行者未完成工作的計次與轉移條件由 `rules/claude/30-dispatch.md`「執行者轉移」規定。同一任務累計三次未完成時，以 `-Incomplete` 把該任務內各執行者的未完成次數傳給選派入口，例如 `-Incomplete haiku:3`；先前已轉移過的執行者一併列出，例如 `-Incomplete haiku:3,sonnet:3`。入口略過達到登錄表 `maxIncomplete` 的執行者，回傳候選清單的下一位。

- 保存同一任務完整的未完成次數，格式為固定一行 `未完成次數：<執行者 id>:<n>,<執行者 id>:<n>`。列出本任務曾承接的全部執行者，含目前這一位與已轉移走的每一位。任務尚無任何未完成時一律寫成 `未完成次數：無`，不省略這一行；讀到「無」表示全部執行者皆為 0，此時呼叫選派入口不帶 `-Incomplete`。其餘情況冒號之後的內容就是 `-Incomplete` 的參數值，呼叫選派入口時整串帶入，不只帶目前這一位。
- 寫入這一行於下列落點，不另建計數檔。
  - Workflow 的 Developer 派工：交接檢查點「下一站」欄，以 `；` 接在 `Developer 派工：全部 Phase=<執行者>` 的同一行，不另起一行。自 `design-accepted` 檢查點起就寫出，此時為 `未完成次數：無`。每次 Developer 回收寫入 `developer-collected` 檢查點時更新。「下一站」改為文件同步、Reviewer 或需求意圖驗收之後，這一行仍保留在同一欄，直到任務收下。
  - 其餘工作（含審查派遣）：該任務每一次派出的派遣輸入，含重派與轉移後的派出。有派遣檔時寫在派遣檔 `## 任務` 章節；只有派生 prompt 時寫在 prompt，prompt 同時指定回報檔落點（單一工作見 `workflow-orchestration` skill `references/implement-routing.md`「單一工作的 Claude 承接契約」），並要求執行者在回報檔第一行照抄，使這一行留在線的報告目錄。協調者回收時核對回報檔第一行與派出時帶入的對照相同，不同或缺少時依派出時的對照更正該行。以該任務最近一次派出為準。沒有登記線、因而沒有回報檔可寫的工作，由協調者在下一次派出的 prompt 帶入完整對照；中斷後讀不到時依本節的接手條目停止並回報。
  - 轉移時：另寫入交接單「識別」的「未完成次數」欄與 exceptions「替代方案」條目的「內容」。
- 更新這一行於回收判定為未完成之後、下一次派出或轉移之前：把該執行者的次數加一，其餘執行者的次數原樣保留。經判定屬環境或硬能力成因而不計者不加。
- 讀取這一行於接手時（換 Session 或脈絡壓縮之後），先取得完整對照再決定下一步。非 Workflow 的工作若最近一份回報尚未完成回收判定（沒有更晚的派出，任務也未收下），先對該回報做回收判定，未完成時為該執行者加一。這一行寫著「無」時全部執行者皆為 0。任務已派出過而讀不到這一行時不從 0 起算，依同線的回報檔、交接單與 exceptions 條目重建；無法重建時停止並回報。
- 重設於任務收下之後，換任務從頭起算。任務未收下前不重設，轉移不清除先前執行者的次數。
- 轉移不需使用者拍板。選派入口回傳 `selected` 時直接轉給下一位，並追加 exceptions「替代方案」，依據含原執行者未完成的原因與證據位置。回傳 `needs-user-decision` 時停止並回報。
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
- 取證量大時，半成品是否通過的取證可交 Sonnet 取證者，判定仍由主 Agent 做出。

## 擴充登錄表

1. 修改 `scripts/dispatch/executor-registry.json`，新增或調整執行者、類型或優先條件。標籤詞彙合計不超過 8 個，排序值全表唯一。每個 Codex 執行者必填 `entry`，值為相對於 repo 根目錄的入口腳本路徑，格式為 `scripts/<檔名>.ps1`；Claude 執行者不得有此欄位。每個 Codex 執行者另必填 `profileSettings`（`model`、`effort`、`subagentModel`、`subagentEffort` 四個字串），Claude 執行者不得有此欄位。`profileSettings` 另可選填 `fallbackModels`（字串陣列，依序，不得重複、不得含主要 model），供帳號不支援主要 model 時改用。檔位設定檔由這些欄位產生，見步驟 4。
2. 確認每個類型至少有一位執行者受理，每個 Codex 執行者的 `profile` 在登錄表內唯一，且不在登錄表頂層的 `retiredProfiles`（已退役的檔位名稱）內；`profileSettings.effort` 與 `subagentEffort` 必須在頂層 `codexEfforts` 內。檔位名稱、退役名稱與 effort 允許清單都只存在登錄表，沒有第二份。`platform` 與 `id` 的格式同樣受驗證。登錄表的讀取與結構驗證只寫在 `scripts/lib/executor-registry.ps1`，選派入口、檔位設定檔的產生器、Setup、帳號建立與派工前比對都載入這個檔並呼叫同一組函式，不另有規則；要改驗證規則只改這個檔。類型的 `preferred` 只能列硬能力標籤或 `family`，含 `family` 時呼叫端必須提供 `-ImplementerFamily`；頂層 `maxIncomplete` 為 1 至 999 的整數。已移除的欄位 `crossFamily`、`degradable`、`escalationOnly`、`escalatesTo`、`onOffline` 出現時登錄表無效。
3. 執行 `pwsh -NoProfile -File scripts/tests/Test-SelectDispatchExecutor.ps1`，全部通過才算完成。
4. 修改 `profile` 或 `profileSettings` 後，commit 時 `.githooks/Update-CodexProfiles.ps1` 會重新產生 `scripts/codex-profiles/<檔位>.config.toml` 並暫存；需要提早確認時手動執行 `pwsh -NoProfile -File .githooks\Update-CodexProfiles.ps1`。新增檔位後，各機器重跑 `scripts\Setup-AIGlobalConfig.ps1` 為帳號目錄建立連結；未建立或內容與產生檔不一致時，`Invoke-CodexRun.ps1` 在啟動前停止（`CodexProfileDrift`）。`-Describe` 輸出每個 Codex 執行者的 `profileSettings`（含 `fallbackModels`）。
5. 修改規則層引用的選派結果（例如本 Skill「各 delegate skill 的標註範例」的預期執行者）時同步更新。

## 各 delegate skill 的標註範例

frontmatter 宣告 `dispatch: delegate` 的 skill 不由主 Agent 自理，改依該 skill「## 任務標註」節呼叫選派入口。

| Skill | 標註 | 預期執行者 |
| --- | --- | --- |
| `export-excel` | `-Type edit -E false -T false` | Sonnet |
| `generate-api-doc` | `-Type edit -E <依控制器與方法是否已逐一列出> -T false -Tags build-test` | E 為真時 Haiku，否則 Sonnet |
| `uiux-baseline` | `-Type survey` | Sonnet |
