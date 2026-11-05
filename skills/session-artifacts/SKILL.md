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
- **派遣單與報告**：資源派遣單存入 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/dispatch-order-<dispatchSlug>.md`，回收報告存入 `<work-root>/.local/ai-sessions/report/dispatch-report-<dispatchSlug>.md`。`dispatchSlug` 識別單次派遣，與識別線的 `lineSlug` 分屬不同名稱空間。派遣單屬單次任務交接檔，派遣報告屬人員閱讀的報告。
- **跨 Session 脈絡紀錄**：耐久的環境前置作業、已知陷阱與覆寫備份分別存入 `CONTEXT.local.md`、`<work-root>/.local/ai-sessions/history/<lineSlug>/` 與 `<work-root>/.local/ai-sessions/backups/`。跨平台派工的事件流 `<work-root>/.local/ai-sessions/history/codex-exec-<yyyyMMdd_HHmmss>.jsonl` 與 thread id 檔 `<work-root>/.local/ai-sessions/history/codex-thread-<dispatchSlug>.txt` 存入 `history/`。腳本換帳號的摘要檔 `<work-root>/.local/ai-sessions/history/<lineSlug>/dispatch-account-failover-<dispatchSlug>.json` 與衍生 Request `<work-root>/.local/ai-sessions/history/<lineSlug>/dispatch-request-<dispatchSlug>-r<n>.json` 同樣存入 `history/`。
- **專案規範**：換機器仍適用的 `AGENTS.md`、`CLAUDE.md`、`GLOSSARY.md` 與 `docs/adr/` 存放於專案原本的規範位置，不歸入 `.local/`。
- **過程性可棄**：一次性腳本、終端輸出、日誌與暫存下載存入 `<work-root>/.local/ai-sessions/scratch/`。
- **需保留非交付**：整合任務素材、截圖、樣式基準與 Demo 畫面分別存入 `<work-root>/.local/ai-sessions/inputs/`、`screenshots/`、`style-baselines/` 與 `ui-demo/`。
- **交付產物**：使用者預期交付的資料檔、程式碼與文件存放於專案原本的位置，不放入 `.local/ai-sessions/`。

## 需求級成本累計

同一成本目標以 `lineSlug` 加需求編號識別，例如 `rule-architecture-rebuild #22`。`dispatchSlug` 與階段只作追溯資訊，換新 `dispatchSlug`、續行或換階段都不讓同一目標的累計值歸零。累計不新增監控服務，只彙整既有的 RunRecord、事件流、failure receipt、協調者手動查詢的額度與回收紀錄。

成本紀錄的唯一落點是 `<sourceRoot>\.local\ai-sessions\report\<lineSlug>\cost-ledger.md`，唯一寫入者是該線協調者（功能線為 `Analyst`，bug 線為 `Maintainer`），只追加不改寫。執行端不寫入此檔。

1. 開始：任務開始時追加一列預算，寫明成本目標、預算形式（牆鐘時間或額度百分點）、預算值與到界處置。預算形式為額度百分點時，同列寫明計算視窗（`primary` 或 `secondary`；帳號無週視窗時只能選 `primary`），協調者於每筆派遣前後以 `Get-CodexQuota.ps1` 手動查詢，累計值只計該視窗的前後差額；另一視窗的數值照常記錄但不參與到界判定。未寫明視窗的額度預算列視為不完整，協調者補齊後才開始派遣。
2. 累計：每筆派遣結束後追加一列，欄位為時間、成本目標、`dispatchSlug`、階段、事件類型、耗時、before 與 after 額度（取得不到時寫 unknown）、用量與累計值。事件類型取值為啟動失敗、格式補件、續行、回收、跨階段返回、Claude session。Codex 列沿用額度差額與 before、after 欄。Claude session 列的 `dispatchSlug` 寫 `session:<sessionId 前 8 碼>`，額度欄寫 `n/a`，用量格式為 `total(in=<n> cw=<n> cr=<n> out=<n>) main(in=<n> cw=<n> cr=<n> out=<n>) sub(in=<n> cw=<n> cr=<n> out=<n>)`。`total`、`main`、`sub` 分別取腳本輸出的 `total_*`、`main_*`、`subagents_*`，`in`、`cw`、`cr`、`out` 依序對應 `input_tokens`、`cache_write_tokens`、`cache_read_tokens`、`output_tokens`。值為 `unknown` 時照寫；`subagents_status` 為 `none` 時寫 `sub(none)`。任一組狀態為 `unknown` 或 `partial` 時照實記錄，不補值。
  - Claude session 數值以 `scripts/Get-ClaudeSessionUsage.ps1` 取得。已知 transcript 路徑用 `-TranscriptPath`，已知 id 用 `-SessionId`，否則用 `-WorkRoot <work-root> -Latest`。使用 `-Latest` 時核對 `last_write_time_utc` 與 `session_id` 是否為當前 session。
  - 協調者於交接檢查點與結案時各可追加一列。同一 `sessionId` 的列記錄截至當時的累積合計，成本累計取每個 `sessionId` 的最後一列，不將同一 session 的多列相加。第一版只記 token，不換算金額，token 不作到界判定。
3. 輪數與成本分開計：`PromptNotDelivered` 等啟動失敗與純格式補件不增加回收輪數（見 `codex-dispatch` skill `references/recovery.md`「回收收斂判定」），但一律計入成本累計值。
4. 重派前比較：協調者在同一成本目標的下一次派遣前，於紀錄寫明本輪閉合了什麼、還差什麼、下一步值得的理由。Reviewer 或顧問額外提出、不屬既有驗收條件的改善只記為候選，不自動列入下一輪必做項。
5. 到界：累計值達到預算時，協調者停止再派，交付已確認結果、未完成單位與建議選項，由使用者決定追加預算或結束。
