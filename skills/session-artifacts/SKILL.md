---
name: session-artifacts
description: 'Use when 建立、讀取、回收、保存或清理 .local/ai-sessions/ 下的交接檔、派遣單、報告或其他工作產物，需要確定分類與落點時。'
audience: agent
policy.allow_implicit_invocation: true
---

# 工作產物分類與落點

本 Skill 提供 Agent 工作產物的分類與存放路徑。`lineSlug` 登記、`LineContext` 驗證、清理範圍與保留範圍由 `instructions.md` §1.4 規定。

## 產物分類與落點

Agent 執行任務產生的檔案依用途分為下列七類，存放於固定目錄。

- **線層交接檔與固定報告**：線登記資料、需求摘要與設計文件分別存入 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/line.json`、`<work-root>/.local/ai-sessions/handoff/<lineSlug>/requirement-summary.md` 與 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/design.md`。執行者升級的交接單存入 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/escalation-handoff-<序號>.md`，升級前的舊 diff 存入 `<work-root>/.local/ai-sessions/report/<lineSlug>/escalation-prior-diff-<序號>.patch`。Developer 結案、交接檢查點、Reviewer、未解驗證、Frontend Reviewer、Contract Auditor、Architecture Review、Cleanup Review、fact-check、文件同步（`doc-sync-report.md`、`doc-edit-report.md`、`survey-doc-sync-consistency.md`）、`cost-ledger.md` 與例外紀錄存入 `<work-root>/.local/ai-sessions/report/<lineSlug>/`。寫入前依 `instructions.md` §1.4「工作產物落點」取得已驗證的 `LineContext`。
- **派遣單與報告**：資源派遣單存入 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/dispatch-order-<dispatchSlug>.md`，回收報告存入 `<work-root>/.local/ai-sessions/report/dispatch-report-<dispatchSlug>.md`。`dispatchSlug` 識別單次派遣，與識別線的 `lineSlug` 分屬不同名稱空間。派遣單屬單次任務交接檔，派遣報告屬人員閱讀的報告。由 `scripts/Invoke-CodexRun.ps1` 發動的派遣，派遣檔存入 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/run-order-<dispatchSlug>.md`，每次執行的產物存入 `<work-root>/.local/ai-sessions/report/<lineSlug>/runs/`，含輸出目錄 `<runKey>/`（報告在其中）、`<runKey>.record.json`、`<runKey>.events.jsonl`、`<runKey>.stderr.txt` 與 `<runKey>.last-message.md`，屬保留性質。
- **跨 Session 脈絡紀錄**：耐久的環境前置作業、已知陷阱與覆寫備份分別存入 `CONTEXT.local.md`、`<work-root>/.local/ai-sessions/history/<lineSlug>/` 與 `<work-root>/.local/ai-sessions/backups/`。跨平台派工的事件流 `<work-root>/.local/ai-sessions/history/codex-exec-<yyyyMMdd_HHmmss>.jsonl` 與 thread id 檔 `<work-root>/.local/ai-sessions/history/codex-thread-<dispatchSlug>.txt` 存入 `history/`。腳本換帳號的摘要檔 `<work-root>/.local/ai-sessions/history/<lineSlug>/dispatch-account-failover-<dispatchSlug>.json` 與衍生 Request `<work-root>/.local/ai-sessions/history/<lineSlug>/dispatch-request-<dispatchSlug>-r<n>.json` 同樣存入 `history/`。
- **專案規範**：換機器仍適用的 `AGENTS.md`、`CLAUDE.md`、`GLOSSARY.md` 與 `docs/adr/` 存放於專案原本的規範位置，不歸入 `.local/`。
- **過程性可棄**：一次性腳本、終端輸出、日誌與暫存下載存入 `<work-root>/.local/ai-sessions/scratch/`。
- **需保留非交付**：整合任務素材、截圖、樣式基準與 Demo 畫面分別存入 `<work-root>/.local/ai-sessions/inputs/`、`screenshots/`、`style-baselines/` 與 `ui-demo/`。
- **交付產物**：使用者預期交付的資料檔、程式碼與文件存放於專案原本的位置，不放入 `.local/ai-sessions/`。

## 線登記與 LineContext

登記者與登記時機由 `instructions.md` §1.4「工作產物落點」規定。登記操作如下。

1. 從需求的核心目的推導小寫英數單字，以連字號串接為候選值，確認符合 `^[a-z0-9]+(?:-[a-z0-9]+)*$`。無法取得有效候選值時，停止派遣並要求使用者補充需求的核心目的，不設定預設 slug。
2. 對尚未登記線的對話，以不帶 `-Force` 的目錄建立操作保留 `<work-root>/.local/ai-sessions/handoff/<candidate>/`。目錄已存在或建立競爭失敗時，依序改用 `<candidate>-2`、`<candidate>-3`，直到成功建立為止。已存在但缺少 `line.json` 的目錄仍視為已占用。
3. 目錄保留成功後立即寫入 `line.json`。寫入失敗時停止後續交接檔寫入，保留該目錄作為已占用的候選值，並回報錯誤。

```json
{
  "schema": "ai-sessions.line.v1",
  "line-slug": "invoice-export",
  "semantic-label": "invoice export",
  "kind": "workflow",
  "created-at-utc": "2026-08-27T00:00:00.0000000Z"
}
```

`kind` 為選填欄位，值為 `workflow` 或 `adhoc`，缺少時視為 `workflow`。需求線使用 `workflow`；不屬任何需求線的一次性取證使用 `adhoc`。`lineSlug` 識別同一條線的持久交接與固定報告，與識別單次派遣的 `dispatchSlug` 分屬不同名稱空間。

同一條線的後續寫入、驗收、實作與審查均沿用已登記的 `lineSlug`，每次跨派遣時傳遞 `LineContext`，至少包含下列欄位：

- `sourceRoot`：已解析的 work-root 絕對路徑。
- `lineSlug`：已登記並驗證的線識別。
- `sourceLineRoot`：`<sourceRoot>/.local/ai-sessions/handoff/<lineSlug>`。
- `dispatchLineRoot`：執行端讀取同線交接檔的目錄。Claude subagent 直接修改來源工作樹時等於 `sourceLineRoot`；經 `scripts/Invoke-CodexRun.ps1` 發動時為派遣檔所在目錄。
- `reportLineRoot`：同線報告目錄，Claude 路徑為來源 `report/<lineSlug>`。

接收端驗證 `LineContext` 是硬性前置：`lineSlug` 符合上列格式，且同線 `line.json` 存在、其 `line-slug` 欄位與傳入的 `lineSlug` 一致。缺少 `LineContext`、找不到 `line.json`，或 `line-slug` 不一致時，一律停止寫入固定名稱交接檔與報告，交由上游建立正確的線脈絡，不以預設值、時間戳或 `dispatchSlug` 代替。

## requirement-summary.md 格式

需求意圖驗收與設計驗收都以同線 `requirement-summary.md` 為唯一比對依據，此檔使需求原意不依賴對話 context 而存在。只在使用者確認需求摘要後寫入，欄位如下：

- **需求背景**：核心目的與主要範圍。
- **程式面項目**：已觀察的問題、改善方向。
- **功能面項目**：新增功能、擴充方向。
- **排除項目**（若有）：明確不做的範圍。
- **已確定的實作約束**（若有）：對話過程中已由使用者拍板的實作面限制，例如指定沿用某既有機制、指定使用某既有元件而非自行實作、指定不得改動某模組。每條註明來源為使用者拍板，並保留當初的具體措辭，不改寫成抽象敘述。這類共識既非需求項目也非驗收方向，缺少此欄時會在整理摘要的過程中流失。
- **假設清單**（若有）：若需補充資訊時的合理假設。
- **驗收方向**：各項目的完成判斷依據。
- **Workflow 深度**：本線的有效深度，解析優先序依 `instructions.md` §1.5「Workflow 深度」，升級判定在使用者確認需求摘要前完成。

程式面與功能面兩欄各自使用 `## 程式面項目` 與 `## 功能面項目` 二級標題，各出現恰好一次。節內只能是一個 `| # | 項目 | 內容 |` 表格，`#` 欄為純數字編號，兩節合併後不得重複；表格前後不得有說明段落、清單或其他表格，補充說明寫在「需求背景」或其他欄位。沒有項目的一節保留標題，節內只寫一行「無」。驗收方向寫入「內容」欄的完整句子，不另加第四欄，表頭第三欄不得改名。`Architect` 的 `〔需求 #n〕` 標註、Developer 的「需求對照」節與派工腳本的結構核對都以此編號為鍵。寫入後以 `scripts\Invoke-CodexDispatch.ps1` 內的 `Get-RequirementIdsFromSummary` 解析一次，確認回傳的編號與預期一致；解析失敗時依錯誤訊息修正後重新解析。

`## Workflow 深度` 節固定為下列三行，深度值只能是 `full` 或 `light`：

```markdown
## Workflow 深度

- 深度：light
- 來源：由 project-kind=sample 推導
- 升級判定：未命中（必發清單第 2 項：否；library 公開 API：否；UI 線 B 或 C：否）
```

來源欄寫出命中的優先序層級；逐線指定時寫「Analyst 逐線指定」並附理由。

## 覆寫前備份

需求摘要、`design.md` 與需保留前版的同線固定報告，覆寫前依下列順序備份，不需詢問使用者確認。

1. 確認目標檔案是否存在。不存在時直接寫入新內容。
2. 確認 `<work-root>/.local/ai-sessions/history/<lineSlug>/` 存在，不存在時建立。
3. 將既有檔案改名為 `<原檔名>.<yyyyMMdd_HHmmss>` 並移入該目錄。同名備份已存在時停止並回報，不覆寫既有備份。
4. 確認備份檔存在後，才寫入新內容。

經 Codex 執行端執行的備份另依 `codex-dispatch` skill `references/collect.md`「覆寫前備份」。

## 需求級成本累計

同一成本目標以 `lineSlug` 加需求編號識別，例如 `rule-architecture-rebuild #22`。`dispatchSlug` 與階段只作追溯資訊，換新 `dispatchSlug`、續行或換階段都不讓同一目標的累計值歸零。累計不新增監控服務，只彙整既有的 RunRecord、事件流、failure receipt、協調者手動查詢的額度與回收紀錄。

成本紀錄的唯一落點是 `<sourceRoot>\.local\ai-sessions\report\<lineSlug>\cost-ledger.md`，只追加不改寫。寫入者依列類型分工：`事件` 列由派工腳本在 Inspect 時自動追加；其餘列類型由該線協調者（功能線為 `Analyst`，bug 線為 `Maintainer`）手寫。Codex 執行端只產出事件流，不寫入 `cost-ledger.md`。

### 列格式（cost-ledger.v2）

表格以標記行 `<!-- cost-ledger.v2 -->` 開頭，表頭固定 14 欄如下。檔案不存在時，腳本建立首行 `# <lineSlug> 成本紀錄`、標記與表頭。既有檔案沒有標記（舊版手寫表）時，腳本不改寫舊內容，在檔尾空一行後附加標記與表頭再接新列。讀取端只解析標記之後的表格。

```text
<!-- cost-ledger.v2 -->
| 時間（UTC） | 列類型 | 成本目標 | dispatchSlug | runId | cycle_id | cycle_round | cycle_role | 事件類型 | 耗時（秒） | input | cached_input | output | 備註 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
```

| 列類型 | 寫入者 | 填法 |
| --- | --- | --- |
| `事件` | 腳本 | 每個經 Dispatch result 綁定，或以 `-RunRecordPath` 解析 RunRecord 的 Inspect 一列（同一 worktree 的續行走後者），同一 `runId` 只追加一次；協調者只在 `costRecord.status` 為 `failed` 時手寫補上同一列。`dispatchSlug`、`runId`、`cycle_*` 取自 RunRecord，`null` 寫 `-`；事件類型為 `首次`（`requested_thread_id` 為 `null`）或 `續行`；耗時為 Inspect 當下減 `started_at_utc`，是運行時間的上界；三個 token 欄取自該 run 事件流最後一筆 `turn.completed.usage` 的 `input_tokens`、`cached_input_tokens`、`output_tokens`。這個值是 Codex thread 的累計值，續行 run 改寫相對錨點 run（RunRecord `previous_run_id`）的增量，錨點讀不到時寫累計值；沒有 usage 時寫 `-`。備註為 `exit=<結束碼>;result=<completed 或 failed>;task=<task_type>;usage=<status>;usage_basis=<delta、cumulative、cumulative-no-anchor 或 none>`，沒有 usage 時為 `none`；`task` 取自 Inspect 的呼叫參數，以 `-RunRecordPath` 呼叫且未給 `-TaskType` 時為 `unspecified`。`scripts/Invoke-CodexRun.ps1` 於每次嘗試結束時自行追加一列，含被服務端拒絕而沒有用量的嘗試；`runId` 為該次執行 `runKey` 去掉 `<dispatch_slug>-` 前綴後的部分，事件類型固定為 `首次`，備註為 `exit=<結束碼>;result=<success、failed 或 rejected>;task=<task_type>;account=<帳號名稱>;rejection=<種類或 none>;usage=<status>` |
| `事件（手寫）` | 協調者 | 沒有 RunRecord 的路徑完成時一列：Claude subagent 實作回收「收下」後、Sonnet 審查報告自驗後，以及沒有進入 Inspect 的啟動失敗。`runId` 填 `claude-<subagent 識別前 8 碼>-<序號>`，序號是同一 subagent 的第幾次完成，自 1 起算，讓首次與續派各為一列且不被去重合併；Codex 啟動失敗填 RunRecord 的 `run_id`，沒有 RunRecord 時填 `launch-<dispatchSlug>`；`cycle_*` 依派生 prompt 或派遣單的循環標示；事件類型填 `首次`，同一 subagent 以 SendMessage 續派時填 `續行`，沒有進入 Inspect 的啟動失敗填 `啟動失敗`；耗時填完成通知的 duration 秒數，取不到時寫 `-`；`input` 填完成通知附的 subagent token 總數，續派列填本次通知的總數減同一 subagent 已記錄 `input` 的累計和（增量；例如三次通知的總數依序為 5000、8000、12000 時，三列依序填 5000、3000、4000），`cached_input` 與 `output` 填 `-`；備註 `source=claude-subagent;model=<haiku、sonnet 或 opus>`，Codex 啟動失敗為 `source=codex-launch-failed;error=<error_code>` |
| `預算` | 協調者 | 任務開始時一列，備註寫成本目標、預算形式、預算值、計算視窗與到界處置，見下方第 1 項 |
| `重派前比較` | 協調者 | 備註寫「閉合=…；未閉合=…；下一步理由=…」，見下方第 4 項 |
| `循環重啟` | 協調者 | 依 `workflow-orchestration` skill「循環識別與重新起算」 |
| `候選` | 協調者 | 備註寫「ID=<finding ID 或 C-nnn>；嚴重度=Minor；摘要=…；來源報告=<絕對路徑>」 |
| `Claude session` | 協調者 | 事件類型填 `Claude session`，`dispatchSlug` 填 `session:<sessionId 前 8 碼>`，用量字串寫在備註，見下方第 2 項 |

未適用的欄位寫 `-`。儲存格內的 `|` 寫成 `\|`，不換行。

### 累計程序

1. 開始：任務開始時追加一列 `預算`，寫明成本目標、預算形式（牆鐘時間或額度百分點）、預算值與到界處置。預算形式為額度百分點時，同列寫明計算視窗（`primary` 或 `secondary`；帳號無週視窗時只能選 `primary`），協調者於每筆派遣前後以 `Get-CodexQuota.ps1` 手動查詢，累計只計該視窗的前後差額，before 與 after 額度寫在備註；另一視窗的數值照常記錄但不參與到界判定。未寫明視窗的額度預算列視為不完整，協調者補齊後才開始派遣。
2. 累計：Codex 派遣的 `事件` 列由腳本追加，`costRecord.status` 為 `failed` 時協調者手寫補上同一列。Claude subagent 與 Sonnet 審查由協調者追加 `事件（手寫）` 列。Claude session 列的用量格式為 `total(in=<n> cw=<n> cr=<n> out=<n>) main(in=<n> cw=<n> cr=<n> out=<n>) sub(in=<n> cw=<n> cr=<n> out=<n>)`。`total`、`main`、`sub` 分別取腳本輸出的 `total_*`、`main_*`、`subagents_*`，`in`、`cw`、`cr`、`out` 依序對應 `input_tokens`、`cache_write_tokens`、`cache_read_tokens`、`output_tokens`。值為 `unknown` 時照寫；`subagents_status` 為 `none` 時寫 `sub(none)`。任一組狀態為 `unknown` 或 `partial` 時照實記錄，不補值。
  - Claude session 數值以 `scripts/Get-ClaudeSessionUsage.ps1` 取得。已知 transcript 路徑用 `-TranscriptPath`，已知 id 用 `-SessionId`，否則用 `-WorkRoot <work-root> -Latest`。使用 `-Latest` 時核對 `last_write_time_utc` 與 `session_id` 是否為當前 session。
  - 協調者於交接檢查點與結案時各可追加一列。同一 `sessionId` 的列記錄截至當時的累積合計，成本累計取每個 `sessionId` 的最後一列，不將同一 session 的多列相加。第一版只記 token，不換算金額，token 不作到界判定。
3. 輪數與成本分開計：`PromptNotDelivered` 等啟動失敗與純格式補件不增加回收輪數（見 `codex-dispatch` skill `references/recovery.md`「回收收斂判定」），但一律計入成本累計。格式補件以同一 `cycle_round` 內的續行表示，跨階段由 `cycle_id` 區分。
4. 重派前比較：協調者在同一成本目標的下一次派遣前，追加一列 `重派前比較`，寫明本輪閉合了什麼、還差什麼、下一步值得的理由。Reviewer 或顧問額外提出、不屬既有驗收條件的改善只記為 `候選`，不自動列入下一輪必做項。
5. 到界：協調者依 `預算` 列的預算形式，以事件列耗時的加總或額度視窗的前後差額計算累計，達到預算時停止再派，交付已確認結果、未完成單位與建議選項，由使用者決定追加預算或結束。

成效比對的指標、程序與基準數字見 `references/cost-comparison.md`。
