---
name: workflow-orchestration
description: 'Use when 執行或回收 Clarify => Design => Implement => Review => Accept Workflow（含 workflow-depth 為 light 的線）、判定其共同收斂循環、執行結案前文件同步（含 bug 線），或規劃 Workflow 驗證與交付時。'
audience: agent
policy.allow_implicit_invocation: true
---

# Workflow 推進與收斂

本 Skill 提供 `Clarify => Design => Implement => Review => Accept` Workflow 的需求確認後分派、Design 與 Demo 驗收、逐站推進步驟、審查的發動、Claude 實作路徑（Haiku 與 Sonnet）、結案前文件同步、`light` 路徑、共同收斂契約的術語定義與驗證分層。有效深度為 `light` 的線依「light 路徑」執行，深度的解析優先序與放寬範圍由 `rules/claude/40-workflow.md`「Workflow 深度」規定。角色權責、授權類停頓、升級與收斂停止的判定順序由 `rules/claude/40-workflow.md`「Workflow 自動推進鏈與共同收斂契約」規定；交接檢查點的建檔內容依 `rules/claude/20-coordination.md`「Workflow 交接檢查點」。執行者由執行者登錄表選出，見 `executor-selection` skill。

## 需求確認後的分派

使用者確認需求摘要後，`Analyst` 依下列順序推進。

1. 尚未登記線時，依 `session-artifacts` skill「線登記與 LineContext」登記 `lineSlug` 並建立同線 `line.json`。既有 `requirement-summary.md` 依同 skill「覆寫前備份」備份後，寫入新的來源 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/requirement-summary.md`，再執行 `check-markdown`。
2. UI 線別為「版面規劃」或「先做 Demo」時，先依 `uiux-baseline` skill「協調者基準準備」完成基準與確認交接；「先做 Demo」先準備基準再交 `Prototyper`。
3. 「無畫面」與「版面規劃」：
   - 有效深度為 `light` 時（「版面規劃」依升級判定一律為 `full`，因此只會是「無畫面」），不派生 `Architect`、不做影響範圍盤點，改依「light 路徑」推進。
   - 有效深度為 `full` 時，需求涉及既有程式碼，且需求摘要未以絕對路徑列舉影響範圍時，先依 `executor-selection` skill 以 `-Type survey` 派生 Sonnet 取證者取得影響範圍盤點報告，收下後才派生 `Architect`。需求改變使用者可見的行為、命令、檔名或術語，而需求摘要未列舉使用者文件時，即使影響範圍已列舉，也派生取證者補做使用者文件盤點；盤點報告含「使用者文件引用」節，以本次改動的術語、檔名、命令與被取代的舊名稱為搜尋詞，列出使用者文件中的命中位置。
   - 以 Agent 工具派生 `Architect`（`subagent_type` 為 `Architect`，`model` 為 `sonnet`），prompt 帶入 `LineContext`、需求摘要的絕對路徑，以及盤點報告的絕對路徑（若有；未提供時 `Architect` 以需求摘要已列舉的檔案清單為盤點對象）。需求不涉及既有程式碼（全新檔案）時，盤點報告與檔案清單皆可缺。「版面規劃」傳入的需求摘要須含區塊清單與初步層級判斷。等待 `Architect` 產出 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/design.md` 後進入「Design 與 Demo 驗收」。
4. 「先做 Demo」：先以 Agent 工具派生 `Prototyper`，傳入需求摘要、畫面清單與 Demo 強度（完整版或精簡版），Demo 產出後進入「Design 與 Demo 驗收」。驗收通過並將訪談結果回填需求摘要後，再依第 3 點派生 `Architect`。

## Design 與 Demo 驗收

`Architect` 或 `Prototyper` 回傳後，`Analyst` 自己驗收產出，確認涵蓋需求摘要後再交給使用者。驗收者是 `Analyst` 本身，因為需求摘要的完整表述由 `Analyst` 產生，執行端只拿得到轉述後的版本。

1. 以 Read 工具實讀 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/design.md`，或 Demo 目錄 `<work-root>/.local/ai-sessions/ui-demo/<demo-name>/`，不依賴 sub-agent 回傳內容自述。
2. 逐項核對檢查清單。Design 依下方「Design 驗收檢查清單」，Demo 依 `uiux` skill「Demo 驗收」。
3. 有任一項不合格時先判定缺漏類型。缺漏清單全部是可機械對照的項目，且已指明修改位置與目標內容（例如同步計數、刪除段落、改寫編號或補上明文句）時，交由 Haiku subagent 依 `rules/claude/30-dispatch.md` 實作分流修改（`design.md` 與 Demo 位於 `.local\`，隔離判定視為無他人項目），完成後自動續行同一驗收循環。只剩 `Minor` 的批次修正不計輪，修正後只核對被修正的項目。缺漏涉及重新設計或需求重新解讀時，再次派生 `Architect` 或 `Prototyper`，將具體缺漏清單作為輸入傳入，計為新一輪。
4. 每輪以完整檢查清單產生結果，保留檢查項目 key、`area-key`（Design 為 `Design/<檢查項目區段>`，Demo 為 `Demo/<檢查項目區段>`）、`problem-key`（檢查清單的完整項目名稱）、嚴重度與證據，依 `rules/claude/40-workflow.md` 共同收斂判定續行或停止。兩個循環各自保存 `round` 與問題集合。
5. 沒有未閉合的 `Critical` 或 `Major` 且剩餘 `Minor` 已完成批次修正與核對，或使用者明確表示「目前版本可接受」時結束循環。

嚴重度依檢查項目影響映射。

| 循環 | `Critical` 或等級相當 | `Major` 或等級相當 | `Minor` 或等級相當 |
| --- | --- | --- | --- |
| Design | 需求項目、已確定實作約束或必要垂直路徑遺失 | 設計路徑矛盾、必要章節或正負向驗證缺漏 | 路徑、計數、標籤或格式可機械修正，且不改變行為 |
| Demo | 需求涵蓋的畫面或主要互動遺失、真實寫入或外部副作用 | 主要互動、版面層級或基準對應錯誤、誤刪產品提示、畫面含設計註記、主要替身無樣本依據、清單缺失或未揭露、外框含驗收用欄位、自增區塊或技術待辦、能力超範圍、註解或重設錯誤、流程與來源相反、錯用 app 或未確認正式流程 | 單一可定位路徑或來源標籤筆誤、已揭露但一欄格式缺漏、註解混入模擬限制或待確認項句式不合、說明表欄位或文案標點缺漏，且不改變畫面行為 |

### Design 驗收檢查清單

| 檢查項目 | 判定依據 |
| --- | --- |
| 需求覆蓋 | 需求摘要的每一項需求（程式面、功能面）在 §9 是否都有對應 T-code；若被劃入 §8 刻意排除，必須與對話中的排除共識一致 |
| [REWRITE] 配套 | 每個標 `[REWRITE]` 的 Phase 必須附「移除項目清單」子節，明列哪些既有元素在該 Phase 完成後不應存在 |
| §6 驗證正負向成對 | 每個 Phase 在 §6 的驗證步驟，正向（新功能存在）與負向（舊結構消失）必須同時具備；[REWRITE] Phase 更不得省略負向 |
| §1 需求摘要一致性 | §1 的敘述是否與需求摘要等義，未出現 Architect 擅自加入的新目標 |
| 實作約束承接 | 需求摘要「已確定的實作約束」逐條在 `design.md` 中有對應落點（寫入 §9 的 T-code 描述、§5 影響範圍或技術選型章節）；未承接者必須在 §8 明確列為排除，不接受靜默省略 |
| §6 驗證步驟可判定性 | 每個 Phase 的 §6 驗證步驟是否具體到第三方可據以判斷通過與否（如「呼叫 X 回傳 200 且資料表 Y 有對應紀錄」）；出現「確認功能正常」「檢查畫面無誤」等無法判定的描述即不合格。設計歧義因此能在 Developer 的淺層探針階段就被撞出 |
| 使用者文件盤點 | `design.md` §5 含「使用者文件」子節，列出受影響的使用者文件與段落並對應 T-code，或寫明無影響的理由 |

### 循環結束後

驗收結束後（通過或達上限），對 `design.md` §7「已知盲點與未涵蓋情境」或 `Prototyper` 回報的待確認項逐條套用 `rules/claude/20-coordination.md`「升級兩道篩」，純技術可解者自行吸收或退回執行層，僅將命中升級判準的真問題升級給使用者，並依「遇真問題只停相依部分」只停相依的工作。

Design 驗收向使用者呈現下列內容，`design.md` 是給 Developer 的 AI-optimized 交接檔，不貼全文。

1. 設計文件路徑與一句話摘要，並註明已代為驗收、使用者不需讀全文。
2. 驗收檢查結果：通過項目、未解決項目（若有）、循環輪數。
3. 升級過濾結果：需使用者拍板的真問題（若有），以及已自行吸收的項目數。
4. `Architect` 標注為「建議建立 ADR」的選型項目（若有），連同每項的被捨棄選項、維護者可能做出的違反修改與當時的來源，以及建檔須經使用者同意的說明，讓使用者看了就能直接回覆要不要建。
5. 下一步：Design 驗收通過後，主 Agent 依 `rules/claude/30-dispatch.md`「Workflow Phase 的實作分流」派生 `Developer`，不需手動切換 Persona；未通過時不派生。

Demo 驗收向使用者呈現 Demo 目錄路徑與開啟方式、版面決策說明表、驗收結果與循環輪數，以及需使用者拍板的項目。Demo 確認後，將訪談結果回填需求摘要，再依「需求確認後的分派」第 3 點派生 `Architect`。

## 自動推進鏈

Design 驗收通過後，主 Agent 依序執行下列自動推進鏈。交接檢查點的建檔與建檔內容仍依 `rules/claude/20-coordination.md`「Workflow 交接檢查點」執行，寫完後原 Session 直接繼續。

1. 分支前置。啟動 Workflow 屬 `git-workflow` 註記的阻擋範圍，先依 `git-workflow` skill「git-workflow 註記與模式載入」確認註記有效。再依該 skill「線分支與獨立 worktree」的適用判定決定直接在整合分支或開線分支；`release-flow` 已有版本標籤且目前位於主分支（`git-workflow` skill「主分支判定」的結果）時停止並詢問版號，尚無版本標籤時主分支即整合分支（見 `references/release-flow.md`「初次發佈前」）。開線分支時執行該節的建立程序並切換 work-root，之後的 `design-accepted` 交接檢查點、派工與回收都使用新 work-root。
2. 依 `rules/claude/30-dispatch.md` Workflow Phase 的實作分流逐 Phase 呼叫選派入口，將結果記入 `design-accepted` 交接檢查點「下一站」欄（格式 `Developer 派工：全部 Phase=<執行者>`，見 `references/implement-routing.md`「Workflow Phase 的判定記錄」），再依本 Skill「Claude 實作路徑」（`references/claude-implement.md`）派生 Developer。
3. 派生 Developer 並回收結果。單一 Claude 執行者依宣告順序完成全部 Phase，直接修改來源工作樹，執行者不建立 commit。回收依 `references/claude-implement.md`「主 Agent 核對」。回收「收下」後，主 Agent 立即依同檔「Phase commit 回收」逐 Phase 建立 commit，不等審查與需求意圖驗收。
4. 完成 Developer 回收後寫入 `developer-collected` 交接檢查點，並更新「下一站」欄的執行者（見 `references/implement-routing.md`「Workflow Phase 的判定記錄」）。回收後仍有殘餘工作時，依 `rules/claude/30-dispatch.md`「派工後的殘餘工作」判定處置，紀錄欄位見 `codex-dispatch` skill `references/collect.md`「派工後的殘餘工作」。
5. 文件同步。`design.md` §5「使用者文件」子節列有受影響文件時，依 `references/doc-sync.md` 執行一致性檢查、事實修正、最終編輯與事實核對，結果寫入 `report/<lineSlug>/doc-sync-report.md`；子節為「無」時記錄理由後直接進入下一步。
6. 命中 Reviewer 必發清單時，依 `rules/claude/40-workflow.md` 審查配對決定審查者並直接派出，不詢問使用者。發動方式依本 Skill「審查的發動」，Codex 與 Claude 審查者共用同一份派遣檔。未命中時記錄一句不發理由，直接進入 Analyst 需求意圖驗收。
7. 審查者以純技術原因退回時（存在未閉合的 `Critical` 或 `Major`），依 `references/claude-implement.md`「審查與修正」由同一執行者重新派生修正；執行者需要更換時依 `references/implement-routing.md`「未完成與轉移」處理。修正完成後回到 Developer 回收與審查判定，修正回收並覆核後立即由 `generate-commit` 步驟 4 建立 `fixup!` commit；修正改變了行為、術語或檔名時，對受影響段落重跑第 5 步。審查結果只剩 `Minor` 時不退回，依共同收斂契約順序 1 批次修正或記為候選後進入第 8 步。
8. 審查者收下時進入 Analyst 需求意圖驗收。Analyst 讀取 `implement-closure-report.md`、`doc-sync-report.md`（若有）與審查者的報告（同線 `<report_name>`，檔名見 `codex-dispatch` skill `references/run.md`）。需求意圖驗收完成後輸出 Workflow 結案報告，報告列出文件同步結果（受影響文件與 `doc-sync-report.md` 路徑，無影響時列理由）。
9. 結案報告完成後，確認本線成果都已成為 commit（Phase commit 與其後的 `fixup!` commit），完成報告同步。之後依 `git-workflow` 註記模式進入整理與落地。線分支的整理與符合 `rules/claude/20-coordination.md`「授權分類」落地條件的落地不需授權；`trunk` 於 push 前完成審查與整理，`release-flow` 於合併前流程整理；push 與發佈待使用者當輪授權。每個 Phase 一筆 commit 的最終形態由整理收合 `fixup!` 達成。Accept 之後對尚未推送的 Phase commit 的修正，由 `generate-commit` 步驟 4 建立 `fixup!` commit。

第 1、2 步是 Design 階段的收尾，第 3 至 5 步屬 Implement，第 6、7 步屬 Review，第 8、9 步屬 Accept。Phase commit 回收在第 3 步收下後執行。Accept 階段涵蓋 Analyst 需求意圖驗收、Workflow 結案報告，以及依註記模式的整理與落地。

## 審查的發動

審查者由選派入口以 `type=review` 選出。Codex 與 Claude 審查者使用同一份派遣檔、同一份角色規則檔與同一套回收步驟，報告是同線 `<report_name>`，報告 `## 總覽` 第一行寫明審查者。

1. 撰寫派遣檔 `handoff/<lineSlug>/run-order-<dispatchSlug>.md`，欄位與章節依 `codex-dispatch` skill `references/run.md`「發動」，循環標示見 `references/review-procedures.md`「循環標示與第 2 輪以上的 Reviewer 派遣單」。
2. 依選出的執行者發動。
   - Codex 執行者：依 `codex-dispatch` skill `references/run.md` 以 `scripts/Invoke-CodexRun.ps1` 發動。結果的結束碼為 4 且 `fallback.selection` 選出 Claude 執行者時，沿用同一份派遣檔改由該執行者審查，不等待 Codex 恢復。
   - Claude 執行者：依 `references/review-procedures.md`「Claude 審查者的發動」以 Agent 工具派生冷啟動 subagent。
3. 回收依 `codex-dispatch` skill `references/run.md`「回收」，兩種執行者相同。審查輪次與範圍依 `reviewer.toml`「審查輪次與範圍」。由同家族執行者審查不另記 exceptions。
4. 同線同時只發一位審查者，由主 Agent 自律。

## Claude 實作路徑

Workflow 的 Phase 由 Claude subagent 承接時的契約見 `references/claude-implement.md`，內含「派生契約」「Sonnet 測試循環」「主 Agent 核對」「收斂計數」「審查與修正」「Phase commit 回收」。派生 Developer 與回收其結果前讀取。

## 文件同步

受影響的使用者文件清單非空時，結案前依 `references/doc-sync.md` 執行一致性檢查、事實修正、最終編輯與事實核對，清單為空時記錄理由。各路徑的站點如下。

- `full`：「自動推進鏈」的文件同步步驟，清單取自 `design.md` §5「使用者文件」子節。
- `light`：「light 路徑」的文件同步步驟，清單取自實作驗收契約的「文件同步」列。
- bug 線：`Maintainer` 驗收通過之後，清單取自 fix-plan 的「文件影響」欄。

單一工作與 bug 線的文件同步不屬 Workflow，執行前同樣先載入本 Skill。

## light 路徑

有效深度為 `light` 的線，在使用者確認需求摘要後依下列步驟推進。有效深度、升級判定與 Reviewer 放寬的權責條款由 `rules/claude/40-workflow.md`「Workflow 深度」與「Reviewer 派遣發動判準」規定。

1. 讀取同線 `requirement-summary.md` 的 `## Workflow 深度` 節取得有效深度，不重新解析。該節不存在時視為 `full`，改依「自動推進鏈」。
2. 確認不派生 `Architect`、不做影響範圍盤點、不寫入 `design-accepted` 與 `developer-collected` 交接檢查點，也不派出 `Developer`。
3. 依 `rules/claude/30-dispatch.md` 派工判準判定實作工作的執行者，照常輸出 `[派工]` 判定行。執行者為主 Agent 小型修改例外，或選派入口選出的 Claude subagent（`references/implement-routing.md`「light 線的實作工作」）。
4. 撰寫實作驗收契約。Claude subagent 的 `acceptanceCriteria` 與主 Agent 自理的驗收列列出目標檔案絕對路徑、`requirement-summary.md` 絕對路徑與相關「已確定的實作約束」所在位置；每列標註〔需求 #n〕，每個需求編號至少被一列涵蓋（或列於需求摘要的排除項目），並含至少一個建置或測試命令與至少一項負向靜態檢查。驗收契約另含一列「文件同步」，列出受影響使用者文件的絕對路徑與段落標題並標註〔需求 #n〕，無影響時寫「不需要：<理由>」。主 Agent 動手前把驗收列原文寫入同線 `report/<lineSlug>/` 下的檔案，作為回收、審查與需求意圖驗收的比對來源。
5. 回收時檢查執行端報告與 diff。變更命中 Reviewer 必發清單第 2 項、改動 `library` 公開 API，或本線 UI 線別為「版面規劃」或「先做 Demo」時，停止後續實作站點，交 `Analyst` 依 `rules/claude/40-workflow.md`「Workflow 深度」改為 `full`，自 Design 起算。未命中時，回收並覆核後立即依 `generate-commit` skill 建立 commit，不等審查與需求意圖驗收；commit 在線分支上時不需授權，直接在整合分支上進行時 commit 即落地，須符合 `rules/claude/20-coordination.md`「授權分類」的落地條件。其後各步的修正同樣於覆核後立即 commit。
6. 文件同步。驗收契約的「文件同步」列有受影響文件時，依 `references/doc-sync.md` 執行；該列為「不需要」時直接進入下一步。
7. 依 `rules/claude/40-workflow.md`「Reviewer 派遣發動判準」的 `light` 調整判定是否發動審查；發動時派遣單依 `references/review-procedures.md`「light 線的 Reviewer 派遣單與回收」。
8. 交由 `Analyst` 執行需求意圖驗收，逐項比對來源為第 4 步實作驗收契約各列的驗收結果、派工回報（含 Claude subagent 回報、主 Agent 自理時的完成回覆）與 `doc-sync-report.md`（若有）。缺列或缺失時依回收三態退回執行端補齊。
9. 確認本線成果都已成為 commit。之後的整理、落地、push 與發佈同 `full` 的「自動推進鏈」第 9 步；需求摘要「已確定的實作約束」另有授權要求時依需求摘要。

## 共同收斂契約

四處循環共用的收斂術語機械定義表與「Minor 的批次修正與候選」見 `references/convergence.md`，判定循環收斂、處理 `Minor` 或標示循環時讀取。

### 循環識別與重新起算

Review 與實作修正循環範圍變動時的重新起算規則（3 類變動、6 步程序、`c3` 停止）見 `references/convergence.md`。

## 驗證分層

Workflow 的驗證職責按深度分四層，各層不重複執行他層的驗證：

| 層 | 執行者 | 深度 | 時機 |
| --- | --- | --- | --- |
| 淺層探針 | Claude 實作者（Developer） | 對改動的端點或畫面單發確認路徑通 | 每階段完成後，依 `design.md` §6 |
| 建置與測試 gate | Claude 實作者（Developer） | 建置與既有測試各執行一次 | 結案時一次 |
| 缺陷審查 | Codex `Reviewer`（Codex 不可用時由選派入口選出的同家族執行者審查） | diff-scoped 靜態審查，不執行測試 | 主 Agent 依 Reviewer 派遣判準與審查配對以派遣單發動 |
| 完整煙霧 | `integration-verify` skill，瀏覽器與桌面的臨場取證由 Codex `scan`（`type=test`，MCP 工具）執行，建置、啟動與 API 取證由 Claude 端執行，判讀在 Claude 端 | 多情境、寫入回查、持久化往返 | 交付節點 |

`integration-verify` 的觸發方式、Reviewer 的動態證據複核條件與需求意圖驗收的歸屬見 `rules/claude/40-workflow.md`「驗證分層與 integration-verify 掛載點」。
