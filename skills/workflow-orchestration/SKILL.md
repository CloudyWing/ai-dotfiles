---
name: workflow-orchestration
description: 'Use when 執行或回收 Clarify => Design => Implement => Review => Accept Workflow（含 workflow-depth 為 light 的線）、判定其共同收斂循環，或規劃 Workflow 驗證與交付時。'
audience: agent
policy.allow_implicit_invocation: true
---

# Workflow 推進與收斂

本 Skill 提供 `Clarify => Design => Implement => Review => Accept` Workflow 的逐站推進步驟、實作分流程序與審查程序（含 Sonnet 審查路徑）、Haiku 實作路徑、`light` 路徑、共同收斂契約的術語定義與驗證分層。有效深度為 `light` 的線依「light 路徑」執行，深度的解析優先序與放寬範圍由 `instructions.md` §1.5「Workflow 深度」規定。角色權責、授權類停頓、升級與收斂停止的判定順序由 `instructions.md` §1.5「Workflow 自動推進鏈與共同收斂契約」規定；交接檢查點的建檔內容依 `instructions.md` §1.4「Workflow 交接檢查點」。

## 自動推進鏈

Design 驗收通過後，主 Agent 依序執行下列自動推進鏈。交接檢查點的建檔與建檔內容仍依 §1.4 執行，建議接手指令輸出後原 Session 直接繼續。

1. 分支前置。啟動 Workflow 屬 `git-workflow` 註記的阻擋範圍，先依 `git-workflow` skill「git-workflow 註記與模式載入」確認註記有效。再依該 skill「線分支與獨立 worktree」的適用判定決定直接在整合分支或開線分支；`release-flow` 目前位於主分支（`git-workflow` skill「主分支判定」的結果）時停止並詢問版號（見 `references/release-flow.md`）。開線分支時執行該節的建立程序並切換 work-root，之後的 `design-accepted` 交接檢查點、派工與回收都使用新 work-root。
2. 依 `instructions.md` Workflow Phase 的實作分流逐 Phase 判定執行者，將結果記入 `design-accepted` 交接檢查點「下一站」欄（格式 `Developer 派工：P<n>=<執行者>`），輸出建議接手指令後依各 Phase 的執行者派工進入 Developer 實作。Codex Phase 走 Workflow 派工契約，Haiku Phase 走本 Skill「Haiku 實作路徑」。
3. 派遣 Developer 並回收結果。Codex Phase 收下時，先將成果套回來源工作樹，不建立 Phase commit，並保留 dispatch worktree 供後續 Reviewer 退回續行。Haiku Phase 的回收依「Haiku 實作路徑」。混合時依前段 Haiku、Codex 單一派工、後段 Haiku 的順序執行。
4. 完成 Developer 回收後寫入 `developer-collected` 交接檢查點，並更新「下一站」欄的改派結果。回收後仍有殘餘工作時，依 `instructions.md`「派工後的殘餘工作」判定處置，紀錄欄位見 `codex-dispatch` skill `references/collect.md`「派工後的殘餘工作」。
5. 命中 Reviewer 必發清單時，依 `instructions.md` 審查配對決定審查者並直接派出，不詢問使用者。Codex `Reviewer` 走資源派遣，Claude Sonnet subagent 走本 Skill「Sonnet 審查路徑」，Workflow 混合時按 Phase 切分兩位審查者，依序各發一份派遣單。未命中時記錄一句不發理由，直接進入 Analyst 需求意圖驗收。
6. 審查者以純技術原因退回時，Codex Phase 使用保留的同一 dispatch worktree 與 thread 自動續行 Developer 修正；Haiku Phase 依「Haiku 實作路徑」的審查與修正處理。修正完成後回到 Developer 回收與審查判定。
7. 審查者收下時進入 Analyst 需求意圖驗收。Analyst 讀取 `implement-closure-report.md`、`implement-closure-report-haiku-pre.md`、`implement-closure-report-haiku-post.md`（若有）與兩位審查者的報告（`review-report.md`、`review-report-claude.md`，若有）。需求意圖驗收完成後輸出 Workflow 結案報告。
8. 結案報告完成後等待使用者當輪授權 commit；取得授權後才執行 Phase commit 回收，完成驗證與報告同步後移除 dispatch worktree（全 Haiku 時沒有 dispatch worktree）。之後依 `git-workflow` 註記模式進入整理與落地，`trunk` 於 push 前整理，`release-flow` 執行合併前流程；整理、落地、push 與合併都待使用者當輪授權。Accept 之後對尚未推送的 Phase commit 的修正，由 `generate-commit` 步驟 4 建立 `fixup!` commit。

第 1、2 步是 Design 階段的收尾，第 3、4 步屬 Implement，第 5、6 步屬 Review，第 7、8 步屬 Accept。Accept 階段涵蓋 Analyst 需求意圖驗收、Workflow 結案報告、使用者授權後的 Phase commit 回收，以及依註記模式的整理與落地。

## 實作分流程序

實作工作的執行者判定條件（E／T 旗標、隔離條件、Workflow Phase 的判定與混合條件）在 `instructions.md`「實作分流」「Haiku 隔離」「Workflow Phase 的實作分流」。單一工作的 Haiku 承接契約、隔離操作、Workflow Phase 的記錄格式、混合順序與失敗改派見 `references/implement-routing.md`。單一工作的 Haiku 承接不屬 Workflow，派生前先載入本 Skill。

## 審查程序

審查配對與發動條件在 `instructions.md`「審查配對」「Reviewer 派遣發動判準」。混合 Workflow 的雙審查者派遣單、規則檔改寫的審查前置、Reviewer 派遣單與回收規格見 `references/review-procedures.md`。

## Sonnet 審查路徑

審查配對判定由 Claude Sonnet subagent 審查時，依下列步驟執行。

1. 建立派遣單八欄，寫入 `handoff/dispatch-order-<dispatchSlug>.md`，第 7 欄報告落點依 `reviewer.toml`。
2. 以 Agent 工具派生冷啟動 subagent，`subagent_type` 為 `general-purpose`，`model` 為 `sonnet`，規則來源為 `~/.ai-agents/agents/codex/reviewer.toml`，prompt 帶 `LineContext` 與派遣單路徑。
3. 審查者將同線鏡像報告寫入 `report/<lineSlug>/review-report-claude.md`，不寫 `review-report.md`。
4. 報告完成後以 `Invoke-CodexDispatch.ps1 -Operation Collect -ReviewerReportPath <報告路徑>` 自驗 manifest，主 Agent 依回收三態判定。此路徑不經 Preflight、Prepare、Start、Inspect，沒有 RunRecord 與 PID 三鍵檢查，Collect 僅做結構核對。
5. 同線同時只發一位審查者，並行上限 2 的腳本控管不適用此路徑，由主 Agent 自律。

## Haiku 實作路徑

Workflow 的 Phase 由 Claude Haiku subagent 承接時（判定條件見 `instructions.md` Workflow Phase 的實作分流），依下列契約執行。

### 派生契約

- 以 Agent 工具派生，`subagent_type` 為 `general-purpose`，`model` 為 `haiku`，冷啟動。
- prompt 含：規則來源 `~/.ai-agents/agents/codex/developer.toml` 全文（in-context 傳入）並宣告適用其「Claude 端 Haiku 承接」節；`design.md` 絕對路徑；`LineContext`，其中 `dispatchLineRoot` 等於 `sourceLineRoot`、`reportLineRoot` 為來源 `report/<lineSlug>`；`requirement-summary.md` 絕對路徑；本批 Phase 清單與各 Phase 的 T-code；混合時另附該批 Phase 所服務的需求編號；報告落點。
- 報告落點：全 Haiku 時為 `report/<lineSlug>/implement-closure-report.md`。混合時前段與後段各寫一份批次報告，前段為 `report/<lineSlug>/implement-closure-report-haiku-pre.md`，後段為 `report/<lineSlug>/implement-closure-report-haiku-post.md`，`implement-closure-report.md` 保留給 Codex 派工。後段不讀取前段報告，每份報告只涵蓋該批 Phase，彙整由 Analyst 需求意圖驗收讀取全部批次報告與 Codex 結案報告完成。
- 一次派生涵蓋同一段（全部、前段或後段）的全部 Haiku Phase，依宣告順序逐 Phase 執行與驗證。
- 派生前記錄路徑雜湊基準，派生後再記錄一次，供核對第 3 項使用，步驟見「主 Agent 核對」第 3 項。
- 禁止 `git add`、`git commit`、`git stash`、`git checkout`、`git reset`，寫入限於本批 Phase 的 T-code 檔案。驗證失敗不修復重試，回報命令原文與原始輸出。

### 主 Agent 核對

`Invoke-CodexDispatch.ps1 -Operation Collect -DispatchKind workflow` 不可用於 Haiku 報告。`scripts/dispatch/collect-contract.ps1` 的 `Invoke-Collect` 除 `Preflight` 之外，必須提供 worktree 的 `DispatchRoot` 與 `BaseSha`，並經 `Resolve-DispatchBaselineBinding` 讀取 dispatch baseline 檔，Haiku 路徑沒有 dispatch worktree 與 baseline。因此主 Agent（可交覆核取證助手）依 `templates/dispatch/closure-report.md` 註解列出的三項檢查，加上範圍與驗證證據，逐項核對下列六項。混合時前段與後段各自成批，每批各自核對一次，核對對象為該批報告、該批派生前後的差異與該批 Phase 的 T-code 檔案。

1. 「需求對照」節唯一，表格固定 6 欄且每欄非空，狀態限「已交付」「部分交付」「未交付」「排除（design.md §8）」，欄內 `|` 已跳脫。
2. 混合時表格的選定需求為該批 Phase 所服務的需求，其餘編號列於表格後緊接的一行 `範圍外（本輪不要求交付）：#…`，中間不留空行；選定需求與範圍外編號的聯集等於 `requirement-summary.md` 的全部編號且不重複。全 Haiku 時表格涵蓋全部編號。
3. 「Phase 對照」節以反引號列出的路徑集合，等於本次派生實際改動的路徑。實際改動路徑依下列步驟取得，涵蓋已追蹤檔的內容變更、新增的未追蹤檔、派生前已存在的未追蹤檔被修改，以及已暫存變更。
   1. 派生前取候選路徑：`git status --porcelain --untracked-files=all` 列出的全部路徑，聯集本批各 Phase 的 T-code 目標檔。對每個存在的路徑記錄 SHA-256（例如 `Get-FileHash -Algorithm SHA256`），不存在者記為「不存在」。
   2. 派生後取候選路徑：重跑 `git status --porcelain --untracked-files=all`，聯集步驟 1 的路徑集合，對每個存在的路徑再記錄一次 SHA-256。
   3. 比對雜湊：派生前後雜湊不同，或「不存在」變為存在、存在變為不存在的路徑，列為已改動。
   4. 聯集補漏：取派生後 `git diff HEAD --name-only` 與 `git ls-files --others --exclude-standard` 的聯集，其中不在步驟 1 路徑集合內的路徑列為已改動；已在步驟 1 集合內的路徑以步驟 3 的雜湊結果為準。步驟 3 與本步驟的結果取聯集，即為實際改動路徑集合。
4. 實際改動路徑皆落在 `design.md` §5 影響範圍與本批 Phase 的 T-code 檔案內，且不含他人項目的檔案。
5. 「驗證證據」節的輪起點 SHA、開工基準線、工作區變更三欄有值；每筆動態驗證附命令原文與執行時間；主 Agent 重跑結案 gate 的建置與測試命令各一次，與報告輸出核對。重跑屬回收覆核，不算補做。
6. 「判定為既有實作而未動工」節的每筆登記含檔案路徑與行號；`design.md` §6 負向檢查（移除清單 Grep）結果為 0。

三態判定：六項皆通過為「收下」；純技術缺漏為「退回」，重新派生視為修正輪次；涉及業務語意或需改變已確認設計為「升級」。報告缺失或為空時第 1 項不成立，退回，不補寫。實際改動路徑超出 Phase 範圍時退回，並要求 Haiku 還原基準線為 clean 的越界檔案，仍越界則該 Phase 改派 Codex，主 Agent 不自行還原來源樹。收下後寫入 `developer-collected` 檢查點，「已回收」欄列 Haiku 報告路徑與三態。

### 收斂計數

- `round`：初次派生為第 1 輪，審查者退回後的每次修正增加 1 輪，`max-rounds` 為 6。
- `problem-key`：驗證項目使用 `<lineSlug>-haiku-<批次序號>` 加 `design.md` §6 Checkpoint 項目序號；Review 沿用 `F-<三位數>`。`dispatch-return-count` 不適用（沒有 dispatch），Git 的 `return-count` 照常分開判定。
- 停止訊號與判定順序沿用 `instructions.md` 共同收斂契約，不因執行者為 Claude 而放寬。

### 審查與修正

- 審查配對依 `instructions.md` 審查配對：Haiku Phase 涉及的檔案由 Codex `Reviewer` 審查；混合時 Codex Phase 另由 Sonnet subagent 審查（各一份派遣單，依序執行）。必發清單第 1 項因 diff 觸及程式碼檔而命中，不另設豁免。
- 審查者退回的修正：各 finding 依小型修改例外與實作分流重判。門檻內且 E=是、T=否者，新派生冷啟動 Haiku subagent（prompt 附 finding 清單與 Phase 範圍），或由主 Agent 自理；超過門檻的 Phase 依 `instructions.md` Workflow Phase 的實作分流第 5 點與 `references/implement-routing.md`「失敗與改派」改派 Codex。

### Phase commit 回收

- 使用者授權 commit 後，Haiku Phase 依其報告「Phase 對照」節逐 Phase 暫存指名路徑並建立 commit，commit 落在符合 `git-workflow` 註記模式的來源分支，commit 訊息依 `generate-commit` skill；與 Codex Phase 依 `design.md` 的 Phase 宣告順序交錯回收；同檔橫跨多個 Phase 時沿用「歸入最早 Phase」。
- 全 Haiku 時沒有 dispatch worktree，不呼叫 `Cleanup`；混合時僅 Codex 派工的 worktree 依既有流程 `Cleanup`。

## light 路徑

有效深度為 `light` 的線，在使用者確認需求摘要後依下列步驟推進。有效深度、升級判定與 Reviewer 放寬的權責條款由 `instructions.md` §1.5「Workflow 深度」與「Reviewer 派遣發動判準」規定。

1. 讀取同線 `requirement-summary.md` 的 `## Workflow 深度` 節取得有效深度，不重新解析。該節不存在時視為 `full`，改依「自動推進鏈」。
2. 確認不派生 `Architect`、不做影響範圍盤點、不寫入 `design-accepted` 與 `developer-collected` 交接檢查點，也不派出 `Developer`。
3. 依 `instructions.md` F1 判準與實作分流判定實作工作的執行者，照常輸出 `[派工判定]` 行。執行者為主 Agent 小型修改例外、Haiku subagent（`references/implement-routing.md`「light 線的實作工作」）或 Codex 資源派遣。
4. 撰寫實作驗收契約。Codex 資源派遣時，派遣單第 3 欄列出目標檔案絕對路徑；第 4 欄列出 `requirement-summary.md` 絕對路徑與相關「已確定的實作約束」所在位置；第 5 欄每列標註〔需求 #n〕，每個需求編號至少被一列涵蓋（或列於需求摘要的排除項目），並含至少一個建置或測試命令與至少一項負向靜態檢查。Haiku subagent 的 `acceptanceCriteria` 與主 Agent 自理的驗收列採相同欄位要求，主 Agent 動手前把驗收列原文寫入同線 `report/<lineSlug>/` 下的檔案，作為回收、審查與需求意圖驗收的比對來源。
5. 回收時檢查執行端報告與 diff。變更命中 Reviewer 必發清單第 2 項、改動 `library` 公開 API，或本線 UI 線別為 B、C 線時，停止後續實作站點，交 `Analyst` 依 `instructions.md`「Workflow 深度」改為 `full`，自 Design 起算。
6. 依 `instructions.md`「Reviewer 派遣發動判準」的 `light` 調整判定是否發動審查；發動時派遣單依 `references/review-procedures.md`「light 線的 Reviewer 派遣單與回收」。
7. 交由 `Analyst` 執行需求意圖驗收，逐項比對來源為第 4 步實作驗收契約各列的驗收結果與資源派遣報告（含 Haiku subagent 回報、主 Agent 自理時的完成回覆）。缺列或缺失時依回收三態退回執行端補齊。
8. 建立 commit 前取得使用者當輪授權，與 `full` 相同。

## 共同收斂契約

四處循環共用下列收斂契約。下游規則檔只補充自身循環的識別來源與驗收方式。

| 名稱 | 機械定義 | 來源 |
| --- | --- | --- |
| `round` | 一次修正連同其驗收或回歸判定為一輪，初次執行為第 1 輪。後續續行各增加 1 輪 | 交接 prompt、回報或回歸紀錄 |
| `area-key` | 同一函式或同一節規則的穩定識別。規則文件使用檔案絕對路徑加最近的 Markdown 標題；檢查清單使用所屬循環與檢查項目區段 | 原始檔案標題、函式位置或驗收清單區段 |
| `problem-key` | 同一問題跨輪次不變的識別。Review 使用 `F-<三位數>`；Design 與 Demo 使用驗收檢查項目 key；派遣回收使用 `dispatchSlug` 加第 5 欄驗收列序號；Git 使用既有 finding ID 或建立時指定的固定 key | Reviewer 報告、驗收清單、派遣單第 5 欄或 Git 修正紀錄 |
| `closed` | 前輪仍未解決的問題，在本輪相同 key 的驗收結果通過，且本輪沒有該 key 的反證 | 本輪完整驗收輸出與證據 |
| `new-problem` | 本輪問題 key 不在前輪未解決問題集合，且沒有同一 key 的改寫或重新命名 | 前後輪問題集合比對 |
| `severity` | `Critical`、`Major`、`Minor`。Review 沿用 `reviewer.toml`；其他循環依檢查項目影響映射 | Reviewer 規則或各循環的嚴重度映射 |
| `max-rounds` | 6 輪。只防止失控，不取代問題閉合與方向變更判定 | 需求摘要與設計文件 |

收斂判定的執行順序與停止門檻見 `instructions.md` §1.5「Workflow 自動推進鏈與共同收斂契約」。

`RecoveryPrecheck` 未通過的 `PromptNotDelivered` 屬啟動契約錯誤。先修正啟動條件，再重新派遣；此狀態不計入派遣回收計數。純技術的報告欄位缺漏、驗收輸出缺漏與格式錯誤直接進入自動補件路徑，不形成使用者詢問站點。`dispatch-return-count` 與 Git 的 `return-count` 分開保存、分開增加、分開判定，任一循環的成功或續行都不重設另一循環的計數。

## 驗證分層

Workflow 的驗證職責按深度分四層，各層不重複執行他層的驗證：

| 層 | 執行者 | 深度 | 時機 |
| --- | --- | --- | --- |
| 淺層探針 | Developer | 對改動的端點或畫面單發確認路徑通 | 每階段完成後，依 `design.md` §6 |
| 建置與測試 gate | Developer | 建置與既有測試各執行一次 | 結案時一次 |
| 缺陷審查 | Reviewer（Codex `Reviewer` 或 Claude Sonnet subagent，依審查配對） | diff-scoped 靜態審查，不執行測試 | 主 Agent 依 Reviewer 派遣判準與審查配對以派遣單發動 |
| 完整煙霧 | `integration-verify` skill | 多情境、寫入回查、持久化往返 | 交付節點 |

`integration-verify` 的觸發方式、Reviewer 的動態證據複核條件與需求意圖驗收的歸屬見 `instructions.md` §1.5「驗證分層與 integration-verify 掛載點」。
