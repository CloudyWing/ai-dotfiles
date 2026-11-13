---
name: executor-selection
description: '派工執行者選派：替任務標註類型、旗標與標籤，呼叫 Select-DispatchExecutor.ps1 依執行者登錄表選出執行者，並處理離線改派、失敗升級與升級交接單。Use when 需要判定派工執行者、標註任務、發動選派入口、處理 Codex 離線或執行者升級時。'
audience: agent
policy.allow_implicit_invocation: true
---

# 派工執行者選派

本 Skill 把「這份工作交給誰」交給資料與腳本判定。執行者清單、受理類型、能力標籤、條件、排序值、離線處置與升級鏈只存在登錄表 `scripts/dispatch/executor-registry.json`，選派由 `scripts/Select-DispatchExecutor.ps1` 執行。本 Skill 定義標註語意、入口用法、各狀態的處置與升級交接單。是否進入登錄表判定、不派清單、下限三題與小型修改例外由 `instructions.md` §1.5「F1 派工判準」規定。

## 使用時機

- 讀取本 Skill 的時點為工作已通過 `instructions.md` 的不派清單與下限三題，需要由主 Agent 以外的執行者處理時。
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
| `review` | 審查，含 `Reviewer`、`Frontend Reviewer`、`Contract Auditor` |
| `advise` | 顧問諮詢（高風險決策的跨家族交叉檢查） |

### 旗標

旗標只決定執行者是否受理，不描述能力。各類型必填的旗標由登錄表 `types.<type>.requiredFlags` 決定，類型未要求的旗標不得提供。

| 旗標 | 為真的條件 |
| --- | --- |
| `E`（範圍已列舉） | 全部目標檔案與修改位置可於派工前以絕對路徑與符號逐一列出 |
| `T`（需要測試循環） | 符合任一項即為真。修改行為邏輯或修 bug；新增或調整測試；預期驗證命令需執行超過 1 次。純機械展開（重新命名、搬移、格式、樣板、對映表套用、註解補齊）且驗證至多 1 次者為假 |

Workflow 的判定單位為 `design.md` 的 Phase。E=是代表該 Phase 的每條 T-code 皆含動詞、完整檔案路徑與修改位置；T 另計 Checkpoint 需執行建置或測試命令超過 1 次的情形（靜態 Grep、檔案比對與結案 gate 的建置與測試各一次不計）。

### 標籤

標籤分為硬能力與約束兩種。硬能力以 `-Tags` 傳入，與該類型的 `impliedTags` 取聯集後，必須是執行者能力的子集。

| 標籤 | 種類 | 意義 |
| --- | --- | --- |
| `write` | 硬能力 | 修改專案原始檔。`.local/ai-sessions/` 下的報告與暫存不算。只允許 `edit` 使用 |
| `build-test` | 硬能力 | 執行建置與測試命令 |
| `web` | 硬能力 | 上網查證 |
| `browse` | 硬能力 | 操作瀏覽器，含登入流程 |
| `desktop-control` | 硬能力 | 控制 Windows 桌面程式、擷取桌面截圖 |
| `image-gen` | 硬能力 | 產生影像 |
| `family` | 約束 | 審查者家族不得等於實作者家族，以 `-ImplementerFamily` 傳入實作者家族 |
| `gated` | 約束 | 執行者需使用者當輪授權，以 `-Authorized` 表示已取得 |

`review` 與 `advise` 必須提供 `-ImplementerFamily`。Codex 不承擔實作，實作者家族目前恆為 `claude`。

## 選派入口

```powershell
pwsh -NoProfile -File scripts/Select-DispatchExecutor.ps1 -Type <type> `
  [-E <true|false>] [-T <true|false>] [-Tags <標籤,標籤>] `
  [-ImplementerFamily <claude|codex>] [-Authorized] [-Offline <執行者 id,執行者 id>] `
  [-EscalateFrom <執行者 id>] [-Label <說明>] [-RegistryPath <路徑>] [-Describe]
```

- 以逗號連接 `-Tags` 與 `-Offline` 的多個值，不含空白，例如 `-Offline codex-scan,codex-content,codex-review,codex-advisor`。`pwsh -File` 與同一行程 `&` 呼叫都適用這個寫法。以空白分隔時，多餘的值會成為位置參數，入口以結束碼 2、錯誤碼 `SelectorParameterBinding` 拒絕。

- 輸出 stdout 單一 JSON 物件（schema `ai-agents.executor-selection.v1`），欄位含 `status`、`executor`、`degradations`、`requiresUserDecision`、`reason`、`considered` 與 `dispatchLine`。
- 輸出 `dispatchLine` 原文作為本輪的 `[派工判定]` 行，不自行改寫判定值。
- 查詢 `-Describe` 取得登錄表目前的類型、旗標需求、標籤與執行者，不做選擇。
- 選派入口無副作用，只讀登錄表，不寫檔、不呼叫網路、不查額度。離線狀態一律由呼叫端以 `-Offline` 傳入。

選擇演算法如下，結果只由輸入與登錄表決定。

1. 過濾出非「僅升級可選」、受理該類型、能力涵蓋有效標籤、條件全部符合、且（`review` 與 `advise` 時）家族不等於實作者家族的執行者。
2. 排除 `-Offline` 後取排序值最小者。該執行者需授權且未提供 `-Authorized` 時為 `needs-authorization`，否則為 `selected`。
3. 第 2 步為空且該類型有可降級約束時，放寬可降級約束重算，取排序值最小的在線執行者，狀態為 `degraded`。硬能力與受理類型永不放寬。
4. 仍為空時，依原應選出的離線執行者對該類型的離線處置回傳 `wait-reset` 或 `stopped`；沒有任何合格執行者時為 `stopped`。
5. 提供 `-EscalateFrom` 時改走升級鏈，見「失敗升級與交接單」。

### 狀態處置

| 狀態 | 結束碼 | 主 Agent 處置 |
| --- | --- | --- |
| `selected` | 0 | Claude 執行者以 Agent 工具派生，`model` 取自 `executor.model`；Codex 執行者載入 `codex-dispatch` 走資源派遣，`profile` 取自 `executor.profile` |
| `degraded` | 0 | 同 `selected`；另追加 exceptions「替代方案」，審查報告或第二意見報告首行標註「同家族審查」。`advise` 降級時由 Sonnet 以一般第二意見承接，不需 `[advisor 諮詢授權]` |
| `escalation-candidate` | 10 | 停止後續實作，整理升級交接單，請使用者拍板 |
| `needs-authorization` | 20 | 輸出 `instructions.md` 規定的 `[advisor 諮詢授權]` 請求，等待使用者當輪回覆 |
| `wait-reset` | 21 | 回報使用者並等待額度重設，不改派 |
| `stopped` | 22 | 回報使用者，附 `reason` 與已查範圍，不以其他執行者頂替硬能力 |
| 標註無效 | 2 | 依 stderr 錯誤碼修正標註後重新呼叫 |
| 登錄表無效 | 3 | 停止派工，回報錯誤碼與登錄表路徑 |

## 離線與帳號判定

離線的政策由 `instructions.md`「離線改派」規定，本節補充執行方式。

- 判定離線的唯一來源是服務端拒絕，額度數值不參與。拒絕包含 usage-limit、401、model not supported、rate limit，以及尚無 item 進度即以未分類錯誤終局失敗者。model not supported 表示該帳號的方案不含檔位設定的 model，停用訂閱的帳號也以此訊息呈現，視為該帳號不可用。
- 派工時不指定 `-CodexHome`。Dispatch 依 `machine.json` `codex_accounts` 登記順序選第一個可用帳號，遭服務端拒絕且尚無 item 進度時自動改試下一個帳號，重試只限換帳號，同一帳號不重送。帳號回報 model not supported 後記入帳號健康狀態檔，24 小時內略過該帳號與檔位 model 的組合。細節見 `codex-dispatch` skill「主 Agent 的帳號切換決策」。
- Dispatch 回報 `CodexAccountsAllUnavailable` 後，才將全部 `codex-*` 執行者 id 以逗號連接傳入 `-Offline` 重新呼叫選派入口，依回傳狀態處置。全離線時 `factcheck`、`review`、`advise` 與無 `browse`、`desktop-control` 標籤的 `test` 由 Sonnet 承接，`generate` 與帶上述標籤的 `test` 回傳 `stopped`。

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
- 保留判讀與修正迴圈決策在主 Agent，回收時依回收三態判定。追加 exceptions「替代方案」，記錄原應由 Codex `scan` 承接。

## 失敗升級與交接單

執行者無法完成工作（同一驗證項目連續失敗、回收連續退回或執行者自述無法完成）時，以 `-EscalateFrom <原執行者 id>` 呼叫選派入口取得升級候選。升級鏈依登錄表 `escalatesTo`，目前為 Haiku、Sonnet、Opus；Opus 屬「僅升級可選」，只經由升級被選中。

- 停止後續實作。升級屬共同收斂契約的收斂停止，由使用者拍板是否升級。
- 整理升級交接單。由主 Agent 依 `templates/dispatch/escalation-handoff.md` 撰寫，不由失敗的執行者撰寫，落點為 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/escalation-handoff-<序號>.md`，序號自 1 遞增。
- 傳遞有執行證據且與做法無關的資訊。

| 欄位 | 內容 | 傳遞 |
| --- | --- | --- |
| 識別 | `lineSlug`、任務、原執行者 id、升級目標 id、序號 | 傳 |
| 已驗證限制 | 每項附證據位置（檔案絕對路徑與行號，或命令原文與輸出位置） | 傳 |
| 環境限制 | 每項附證據位置 | 傳 |
| 已排除做法 | 僅限有反證者，附反證位置，標為「可被新證據推翻」 | 傳 |
| 驗收條件 | 引用原驗收條件的路徑與列號，不改寫 | 傳 |
| 半成品處置 | 半成品程式碼同時通過語法檢查、既有測試與設計對照才列為起點；任一未通過時退回輪起點 SHA，舊 diff 只作參考並標「正確性未知」 | 傳 |
| 刻意不提供 | 前一位的計畫、推理、自我評估、未驗證假設與完整對話紀錄 | 不傳，於交接單明寫 |

- 退回起點時，先以 `git diff` 將舊 diff 存為 `<work-root>/.local/ai-sessions/report/<lineSlug>/escalation-prior-diff-<序號>.patch`，再由新執行者以 `git show <輪起點 SHA>:<path>` 的內容逐檔覆寫範圍內被改動的檔案。Claude subagent 的 git 寫入類命令禁令維持不變。
- 寫入「無」於沒有通過驗證證據的欄位，不補寫推測。證據位置無法開啟的項目移入「刻意不提供」並註明原因。
- 保留舊交接單。同線同時只有一份有效交接單，新的升級以新序號建檔。
- 取證量大時，半成品是否通過的取證可交 Sonnet 取證者，判定仍由主 Agent 做出。

## 擴充登錄表

1. 修改 `scripts/dispatch/executor-registry.json`，新增或調整執行者、類型或離線處置。標籤詞彙合計不超過 8 個，排序值全表唯一。
2. 確認每個 Codex 執行者的 `onOffline` 鍵恰好等於其 `accepts`，`profile` 屬於 `codex-dispatch` 的檔位白名單。`onOffline` 值為 `fallback` 時，該類型必須另有其他非「僅升級可選」的執行者受理，否則登錄表無效；類型設 `crossFamily` 時，呼叫端必須提供 `-ImplementerFamily`。
3. 執行 `pwsh -NoProfile -File scripts/tests/Test-SelectDispatchExecutor.ps1`，全部通過才算完成。
4. 修改規則層引用的選派結果（例如本 Skill「各 delegate skill 的標註範例」的預期執行者）時同步更新。

## 各 delegate skill 的標註範例

frontmatter 宣告 `dispatch: delegate` 的 skill 不由主 Agent 自理，改依該 skill「## 任務標註」節呼叫選派入口。

| Skill | 標註 | 預期執行者 |
| --- | --- | --- |
| `generate-unit-test` | `-Type edit -E false -T true -Tags build-test` | Sonnet |
| `export-excel` | `-Type edit -E false -T false` | Sonnet |
| `generate-api-doc` | `-Type edit -E <依控制器與方法是否已逐一列出> -T false -Tags build-test` | E 為真時 Haiku，否則 Sonnet |
| `uiux-baseline` | `-Type survey` | Sonnet |
