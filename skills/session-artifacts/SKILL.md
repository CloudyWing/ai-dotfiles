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

- **線層交接檔與固定報告**：線登記資料、需求摘要與設計文件分別存入 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/line.json`、`<work-root>/.local/ai-sessions/handoff/<lineSlug>/requirement-summary.md` 與 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/design.md`。Developer 結案、交接檢查點、Reviewer、未解驗證、Frontend Reviewer、Contract Auditor、Architecture Review、Cleanup Review、fact-check 與例外紀錄存入 `<work-root>/.local/ai-sessions/report/<lineSlug>/`。寫入前依 `instructions.md` §1.4「工作產物落點」取得已驗證的 `LineContext`。
- **派遣單與報告**：資源派遣單存入 `<work-root>/.local/ai-sessions/handoff/dispatch-order-<dispatchSlug>.md`，回收報告存入 `<work-root>/.local/ai-sessions/report/dispatch-report-<dispatchSlug>.md`。`dispatchSlug` 識別單次派遣，與識別線的 `lineSlug` 分屬不同名稱空間。派遣單屬單次任務交接檔，派遣報告屬人員閱讀的報告。
- **跨 Session 脈絡紀錄**：耐久的環境前置作業、已知陷阱與覆寫備份分別存入 `CONTEXT.local.md`、`<work-root>/.local/ai-sessions/history/<lineSlug>/` 與 `<work-root>/.local/ai-sessions/backups/`。跨平台派工的事件流 `<work-root>/.local/ai-sessions/history/codex-exec-<yyyyMMdd_HHmmss>.jsonl` 與 thread id 檔 `<work-root>/.local/ai-sessions/history/codex-thread-<dispatchSlug>.txt` 存入 `history/`。
- **專案規範**：換機器仍適用的 `AGENTS.md`、`CLAUDE.md`、`GLOSSARY.md` 與 `docs/adr/` 存放於專案原本的規範位置，不歸入 `.local/`。
- **過程性可棄**：一次性腳本、終端輸出、日誌與暫存下載存入 `<work-root>/.local/ai-sessions/scratch/`。
- **需保留非交付**：整合任務素材、截圖、樣式基準與 Demo 畫面分別存入 `<work-root>/.local/ai-sessions/inputs/`、`screenshots/`、`style-baselines/` 與 `ui-demo/`。
- **交付產物**：使用者預期交付的資料檔、程式碼與文件存放於專案原本的位置，不放入 `.local/ai-sessions/`。
