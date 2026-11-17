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

- **線層交接檔與固定報告**：線登記資料、需求摘要與設計文件分別存入 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/line.json`、`<work-root>/.local/ai-sessions/handoff/<lineSlug>/requirement-summary.md` 與 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/design.md`。執行者轉移的交接單存入 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/escalation-handoff-<序號>.md`，轉移前的舊 diff 存入 `<work-root>/.local/ai-sessions/report/<lineSlug>/escalation-prior-diff-<序號>.patch`。Developer 結案、交接檢查點、Reviewer、未解驗證、Frontend Reviewer、Contract Auditor、Architecture Review、Cleanup Review、fact-check、文件同步（`doc-sync-report.md`、`doc-edit-report.md`、`survey-doc-sync-consistency.md`）、`cost-ledger.md` 與例外紀錄存入 `<work-root>/.local/ai-sessions/report/<lineSlug>/`。寫入前依 `instructions.md` §1.4「工作產物落點」取得已驗證的 `LineContext`。
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
- **Workflow 深度**：本線的有效深度，解析優先序依 `rules/claude/40-workflow.md`「Workflow 深度」，升級判定在使用者確認需求摘要前完成。

程式面與功能面兩欄各自使用 `## 程式面項目` 與 `## 功能面項目` 二級標題，各出現恰好一次。節內只能是一個 `| # | 項目 | 內容 |` 表格，`#` 欄為純數字編號，兩節合併後不得重複；表格前後不得有說明段落、清單或其他表格，補充說明寫在「需求背景」或其他欄位。沒有項目的一節保留標題，節內只寫一行「無」。驗收方向寫入「內容」欄的完整句子，不另加第四欄，表頭第三欄不得改名。`Architect` 的 `〔需求 #n〕` 標註、Developer 的「需求對照」節與派工腳本的結構核對都以此編號為鍵。寫入後以 `scripts\Invoke-CodexDispatch.ps1` 內的 `Get-RequirementIdsFromSummary` 解析一次，確認回傳的編號與預期一致；解析失敗時依錯誤訊息修正後重新解析。

`## Workflow 深度` 節固定為下列三行，深度值只能是 `full` 或 `light`：

```markdown
## Workflow 深度

- 深度：light
- 來源：由 project-kind=sample 推導
- 升級判定：未命中（必發清單第 2 項：否；library 公開 API：否；UI 線為版面規劃或先做 Demo：否）
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

`cost-ledger.v2` 列格式見 `references/cost-ledger.md`，寫入或讀取同線 `cost-ledger.md` 時讀取。一條線的成本以 `scripts/Get-LineCost.ps1` 唯讀計算；`事件` 列由派工腳本追加，`循環重啟` 與 `候選` 列由協調者追加。

成效比對的指標、程序與基準數字見 `references/cost-comparison.md`。
