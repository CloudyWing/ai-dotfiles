# Claude 實作路徑

本檔收錄 Workflow 的 Phase 由 Claude subagent 承接時的派生契約、驗證失敗處置、主 Agent 核對、收斂計數、審查與修正，以及 Phase commit 回收。派生 Developer 與回收其結果前讀取。逐站順序見 `../SKILL.md`「自動推進鏈」。

Workflow 的 Phase 由 Claude subagent 承接（執行者見 `design-accepted` 檢查點「下一站」欄），依下列契約執行。各執行者共用本檔，驗證失敗的處置依選派結果的 `executor.selfRepair`，見「驗證失敗處置」。

## 派生契約

- 以 Agent 工具派生，`subagent_type` 為 `general-purpose`，`model` 為選派結果的 `executor.model`，冷啟動。
- prompt 含：規則來源 `~/.ai-agents/agents/claude/developer.md` 全文（in-context 傳入）；選派結果的 `executor.selfRepair` 值；`design.md` 絕對路徑；`LineContext`，其中 `dispatchLineRoot` 等於 `sourceLineRoot`、`reportLineRoot` 為來源 `report/<lineSlug>`；`requirement-summary.md` 絕對路徑；本批 Phase 清單與各 Phase 的 T-code；報告落點；審查退回後的修正輪另含「前輪未閉合 finding 處置」表（格式見 `review-procedures.md`「修正派遣的前輪 finding 處置核對」）與循環標示。
- 報告落點固定為 `report/<lineSlug>/implement-closure-report.md`。
- `design.md` §5 含使用者文件 T-code 時，prompt 另帶 `doc-sync.md`「草稿原則」原文。
- 一次派生涵蓋執行者承接的全部 Phase，依宣告順序逐 Phase 執行與驗證。
- 派生前記錄路徑雜湊基準，派生後再記錄一次，供核對第 3 項使用，步驟見「主 Agent 核對」第 3 項。
- 禁止 `git add`、`git commit`、`git stash`、`git checkout`、`git reset`，寫入限於本批 Phase 的 T-code 檔案。

## 驗證失敗處置

- 派生 prompt 的 `selfRepair` 為 `false` 時，驗證失敗不修復重試，回報命令原文與原始輸出。
- 其餘情形（值為 `true`，或未經選派入口派生而沒有此值）驗證失敗可修正後重跑。每次修正前寫出假設（「我認為問題出在 X，因為 Y，所以改 Z」），修改限本 Phase 的 T-code 檔案。
- 同一驗證項目連續 3 次失敗時停止，於報告「未解決項目」列出命令原文與原始輸出，交主 Agent 依 `implement-routing.md`「未完成與轉移」判定。

## 主 Agent 核對

主 Agent（可交覆核取證助手）依 `templates/dispatch/closure-report.md` 註解列出的三項檢查，加上範圍與驗證證據，逐項核對下列六項；修正輪另核對第 7 項。

1. 「需求對照」節唯一，表格固定 6 欄且每欄非空，狀態限「已交付」「部分交付」「未交付」「排除（design.md §8）」，欄內 `|` 已跳脫。
2. 表格涵蓋 `requirement-summary.md` 的全部編號且不重複。部分 Phase 由主 Agent 執行時，主 Agent 執行的需求編號列於表格後緊接的一行 `範圍外（本輪不要求交付）：#…`，中間不留空行；表格與範圍外編號的聯集等於全部編號。
3. 「Phase 對照」節以反引號列出的路徑集合，等於本次派生實際改動的路徑。實際改動路徑依下列步驟取得，涵蓋已追蹤檔的內容變更、新增的未追蹤檔、派生前已存在的未追蹤檔被修改，以及已暫存變更。
   1. 派生前取候選路徑：`git status --porcelain --untracked-files=all` 列出的全部路徑，聯集本批各 Phase 的 T-code 目標檔。對每個存在的路徑記錄 SHA-256（例如 `Get-FileHash -Algorithm SHA256`），不存在者記為「不存在」。
   2. 派生後取候選路徑：重跑 `git status --porcelain --untracked-files=all`，聯集步驟 1 的路徑集合，對每個存在的路徑再記錄一次 SHA-256。
   3. 比對雜湊：派生前後雜湊不同，或「不存在」變為存在、存在變為不存在的路徑，列為已改動。
   4. 聯集補漏：取派生後 `git diff HEAD --name-only` 與 `git ls-files --others --exclude-standard` 的聯集，其中不在步驟 1 路徑集合內的路徑列為已改動；已在步驟 1 集合內的路徑以步驟 3 的雜湊結果為準。步驟 3 與本步驟的結果取聯集，即為實際改動路徑集合。
4. 實際改動路徑皆落在 `design.md` §5 影響範圍與本批 Phase 的 T-code 檔案內，且不含他人項目的檔案。
5. 「驗證證據」節的輪起點 SHA、開工基準線、工作區變更三欄有值；每筆動態驗證附命令原文與執行時間；主 Agent 重跑結案 gate 的建置與測試命令各一次，與報告輸出核對。重跑屬回收覆核，不算補做。
6. 「判定為既有實作而未動工」節的每筆登記含檔案路徑與行號；`design.md` §6 負向檢查（移除清單 Grep）結果為 0。
7. 修正輪的處置核對：報告「前輪 finding 處置結果」節依 `review-procedures.md`「修正派遣的前輪 finding 處置核對」比對，集合與處置值全部相符。

三態判定：適用各項皆通過為「收下」；純技術缺漏為「退回」，重新派生視為修正輪次；涉及業務語意或需改變已確認設計為「升級」。報告缺失或為空時第 1 項不成立，退回，不補寫。實際改動路徑超出 Phase 範圍時退回，並要求執行者還原基準線為 clean 的越界檔案，仍越界則依 `implement-routing.md`「未完成與轉移」處理，主 Agent 不自行還原來源樹。收下後寫入 `developer-collected` 檢查點，「已回收」欄列報告路徑與三態。

## 收斂計數

- `round`：初次派生為第 1 輪，審查者退回後的每次修正增加 1 輪，以同一 `cycle_id` 的 `cycle_round` 計。`max-rounds` 為 6，以 `cycle_id` 為單位，依 `convergence.md`「循環識別與重新起算」另起的新循環從零起算。
- `problem-key`：驗證項目使用 `<lineSlug>-impl` 加 `design.md` §6 Checkpoint 項目序號；Review 沿用 `F-<三位數>`。`dispatch-return-count` 不適用（沒有 dispatch），Git 的 `return-count` 照常分開判定。
- 停止訊號與判定順序沿用 `rules/claude/40-workflow.md` 共同收斂契約，不因執行者為 Claude 而放寬。

## 審查與修正

- 審查配對依 `rules/claude/40-workflow.md` 審查配對，Claude 實作的變更由 Codex `Reviewer` 審查。必發清單第 1 項因 diff 觸及程式碼檔而命中，不另設豁免。
- 審查者退回的修正：各 finding 依小型修改例外重判。門檻內者由主 Agent 自理，或以「前輪未閉合 finding 處置」表與 Phase 範圍重新派生同一執行者；同一執行者無法完成時依 `implement-routing.md`「未完成與轉移」處理。

## Phase commit 回收

- 回收判定為「收下」後立即執行，不等審查與需求意圖驗收。依報告「Phase 對照」節逐 Phase 暫存指名路徑並建立 commit，commit 落在符合 `git-workflow` 註記模式的來源分支，commit 訊息依 `generate-commit` skill；依 `design.md` 的 Phase 宣告順序回收，同檔橫跨多個 Phase 時沿用「歸入最早 Phase」。
- 來源分支為線分支時不需授權。來源分支為整合分支時 commit 即落地，不需授權，須符合 `rules/claude/20-coordination.md`「授權分類」的落地條件。
- 審查退回的修正與文件同步的改動，回收並覆核後由 `generate-commit` 步驟 4 建立 `fixup!` commit。每個 Phase 一筆 commit 的最終形態由 `git-workflow` skill「整理流程」收合 `fixup!` 達成，整理時點依模式檔。
