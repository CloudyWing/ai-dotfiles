---
name: workflow-orchestration
description: 'Use when 執行或回收 Clarify => Design => Implement => Review => Accept Workflow（含 workflow-depth 為 light 的線）、判定其共同收斂循環、執行結案前文件同步（含 bug 線），或規劃 Workflow 驗證與交付時。'
audience: agent
policy.allow_implicit_invocation: true
---

# Workflow 推進與收斂

本 Skill 提供 `Clarify => Design => Implement => Review => Accept` Workflow 的需求確認後分派、Design 與 Demo 驗收、逐站推進步驟、實作分流程序與審查程序（含 Sonnet 審查路徑）、Claude 實作路徑（Haiku 與 Sonnet）、結案前文件同步、`light` 路徑、共同收斂契約的術語定義與驗證分層。有效深度為 `light` 的線依「light 路徑」執行，深度的解析優先序與放寬範圍由 `rules/claude/40-workflow.md`「Workflow 深度」規定。角色權責、授權類停頓、升級與收斂停止的判定順序由 `rules/claude/40-workflow.md`「Workflow 自動推進鏈與共同收斂契約」規定；交接檢查點的建檔內容依 `rules/claude/20-coordination.md`「Workflow 交接檢查點」。執行者由執行者登錄表選出，見 `executor-selection` skill。

## 需求確認後的分派

使用者確認需求摘要後，`Analyst` 依下列順序推進。

1. 尚未登記線時，依 `session-artifacts` skill「線登記與 LineContext」登記 `lineSlug` 並建立同線 `line.json`。既有 `requirement-summary.md` 依同 skill「覆寫前備份」備份後，寫入新的來源 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/requirement-summary.md`，再執行 `check-markdown`。
2. 涉及畫面的 B／C 線先依 `uiux-baseline` skill「協調者基準準備」完成基準與確認交接；C 線先準備基準再交 `Prototyper`。
3. A 線與 B 線：
   - 有效深度為 `light` 時（B 線依升級判定一律為 `full`，因此只會是 A 線），不派生 `Architect`、不做影響範圍盤點，改依「light 路徑」推進。
   - 有效深度為 `full` 時，需求涉及既有程式碼，且需求摘要未以絕對路徑列舉影響範圍時，先依 `executor-selection` skill 以 `-Type survey` 派生 Sonnet 取證者取得影響範圍盤點報告，收下後才派生 `Architect`。需求改變使用者可見的行為、命令、檔名或術語，而需求摘要未列舉使用者文件時，即使影響範圍已列舉，也派生取證者補做使用者文件盤點；盤點報告含「使用者文件引用」節，以本次改動的術語、檔名、命令與被取代的舊名稱為搜尋詞，列出使用者文件中的命中位置。
   - 以 Agent 工具派生 `Architect`（`subagent_type` 為 `Architect`，`model` 為 `sonnet`），prompt 帶入 `LineContext`、需求摘要的絕對路徑，以及盤點報告的絕對路徑（若有；未提供時 `Architect` 以需求摘要已列舉的檔案清單為盤點對象）。需求不涉及既有程式碼（全新檔案）時，盤點報告與檔案清單皆可缺。B 線傳入的需求摘要須含區塊清單與初步層級判斷。等待 `Architect` 產出 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/design.md` 後進入「Design 與 Demo 驗收」。
4. C 線：先以 Agent 工具派生 `Prototyper`，傳入需求摘要、畫面清單與 Demo 強度（完整版或精簡版），Demo 產出後進入「Design 與 Demo 驗收」。驗收通過並將訪談結果回填需求摘要後，再依第 3 點派生 `Architect`。

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
4. `Architect` 標注為「建議建立 ADR」的選型項目（若有），連同建檔須由使用者手動觸發 `adr` skill 的說明。
5. 下一步：Design 驗收通過後，主 Agent 依 `rules/claude/30-dispatch.md`「Workflow Phase 的實作分流」派生 `Developer`，不需手動切換 Persona；未通過時不派生。

Demo 驗收向使用者呈現 Demo 目錄路徑與開啟方式、版面決策說明表、驗收結果與循環輪數，以及需使用者拍板的項目。Demo 確認後，將訪談結果回填需求摘要，再依「需求確認後的分派」第 3 點派生 `Architect`。

## 自動推進鏈

Design 驗收通過後，主 Agent 依序執行下列自動推進鏈。交接檢查點的建檔與建檔內容仍依 `rules/claude/20-coordination.md`「Workflow 交接檢查點」執行，寫完後原 Session 直接繼續。

1. 分支前置。啟動 Workflow 屬 `git-workflow` 註記的阻擋範圍，先依 `git-workflow` skill「git-workflow 註記與模式載入」確認註記有效。再依該 skill「線分支與獨立 worktree」的適用判定決定直接在整合分支或開線分支；`release-flow` 已有版本標籤且目前位於主分支（`git-workflow` skill「主分支判定」的結果）時停止並詢問版號，尚無版本標籤時主分支即整合分支（見 `references/release-flow.md`「初次發佈前」）。開線分支時執行該節的建立程序並切換 work-root，之後的 `design-accepted` 交接檢查點、派工與回收都使用新 work-root。
2. 依 `rules/claude/30-dispatch.md` Workflow Phase 的實作分流逐 Phase 呼叫選派入口，將結果記入 `design-accepted` 交接檢查點「下一站」欄（格式 `Developer 派工：全部 Phase=<執行者>`，見 `references/implement-routing.md`「Workflow Phase 的判定記錄」），再依本 Skill「Claude 實作路徑」派生 Developer。
3. 派生 Developer 並回收結果。單一 Claude 執行者依宣告順序完成全部 Phase，直接修改來源工作樹，不建立 Phase commit。回收依「Claude 實作路徑」的「主 Agent 核對」。回收「收下」後，協調者在同線 `cost-ledger.md` 追加一列 `事件（手寫）`，欄位見 `session-artifacts` skill「需求級成本累計」。
4. 完成 Developer 回收後寫入 `developer-collected` 交接檢查點，並更新「下一站」欄的升級結果。回收後仍有殘餘工作時，依 `rules/claude/30-dispatch.md`「派工後的殘餘工作」判定處置，紀錄欄位見 `codex-dispatch` skill `references/collect.md`「派工後的殘餘工作」。
5. 文件同步。`design.md` §5「使用者文件」子節列有受影響文件時，依 `references/doc-sync.md` 執行一致性檢查、事實修正、最終編輯與事實核對，結果寫入 `report/<lineSlug>/doc-sync-report.md`；子節為「無」時記錄理由後直接進入下一步。
6. 命中 Reviewer 必發清單時，依 `rules/claude/40-workflow.md` 審查配對決定審查者並直接派出，不詢問使用者。Codex `Reviewer` 依 `codex-dispatch` skill `references/run.md` 發動；Codex 離線時選派入口回傳 `degraded`，改走本 Skill「Sonnet 審查路徑」。未命中時記錄一句不發理由，直接進入 Analyst 需求意圖驗收。
7. 審查者以純技術原因退回時（存在未閉合的 `Critical` 或 `Major`），依「Claude 實作路徑」的「審查與修正」由同一執行者重新派生修正；執行者需要更換時依 `references/implement-routing.md`「失敗與升級」處理。修正完成後回到 Developer 回收與審查判定；修正改變了行為、術語或檔名時，對受影響段落重跑第 5 步。審查結果只剩 `Minor` 時不退回，依共同收斂契約順序 1 批次修正或記為候選後進入第 8 步。
8. 審查者收下時進入 Analyst 需求意圖驗收。Analyst 讀取 `implement-closure-report.md`、`doc-sync-report.md`（若有）與審查者的報告（`review-report.md`，降級時為 `review-report-claude.md`）。需求意圖驗收完成後輸出 Workflow 結案報告，報告列出文件同步結果（受影響文件與 `doc-sync-report.md` 路徑，無影響時列理由）。
9. 結案報告完成後等待使用者當輪授權 commit；取得授權後才執行 Phase commit 回收，完成驗證與報告同步。之後依 `git-workflow` 註記模式進入整理與落地，`trunk` 於 push 前整理，`release-flow` 執行合併前流程；整理、落地、push 與合併都待使用者當輪授權。Accept 之後對尚未推送的 Phase commit 的修正，由 `generate-commit` 步驟 4 建立 `fixup!` commit。

第 1、2 步是 Design 階段的收尾，第 3 至 5 步屬 Implement，第 6、7 步屬 Review，第 8、9 步屬 Accept。Accept 階段涵蓋 Analyst 需求意圖驗收、Workflow 結案報告、使用者授權後的 Phase commit 回收，以及依註記模式的整理與落地。

## 實作分流程序

實作工作的執行者判定（任務標註、選派入口、隔離條件、Workflow Phase 的單一執行者）在 `rules/claude/30-dispatch.md`「實作分流」「Claude 實作 subagent 隔離」「Workflow Phase 的實作分流」與 `executor-selection` skill。單一工作的 Claude 承接契約、隔離操作、Workflow Phase 的記錄格式與失敗升級見 `references/implement-routing.md`。單一工作的 Claude 承接不屬 Workflow，派生前先載入本 Skill。

## 審查程序

審查配對與發動條件在 `rules/claude/40-workflow.md`「審查配對」「Reviewer 派遣發動判準」。規則檔改寫的審查前置、Reviewer 派遣單與回收規格見 `references/review-procedures.md`。

## Sonnet 審查路徑

Codex 離線、選派入口以 `degraded` 回傳 Sonnet subagent 時，依下列步驟執行。

1. 建立派遣單八欄，寫入 `handoff/<lineSlug>/dispatch-order-<dispatchSlug>.md`，第 7 欄報告落點依 `reviewer.toml`。第 4 欄含循環標示行，格式見 `references/review-procedures.md`「循環標示與第 2 輪以上的 Reviewer 派遣單」。
2. 以 Agent 工具派生冷啟動 subagent，`subagent_type` 為 `general-purpose`，`model` 為 `sonnet`，規則來源為 `~/.ai-agents/agents/codex/reviewer.toml`，prompt 帶 `LineContext`、派遣單路徑與循環標示。審查輪次與範圍依 `reviewer.toml`「審查輪次與範圍」，第 1 輪完整度與第 2 輪以上的審查範圍同樣適用於 Sonnet 審查者。
3. 審查者將報告寫入派遣單第 7 欄指定的路徑，預設為 `report/<lineSlug>/review-report-claude.md`，報告首行標註「同家族審查」，不寫 `review-report.md`。主 Agent 追加 exceptions「替代方案」，並把報告 `## 例外回報` 節的條目併入同線 `exceptions.md`。
4. 報告完成後以 `pwsh -NoProfile -File scripts/Test-CodexReviewReport.ps1 -ReportPath <報告路徑>` 自驗 manifest，`valid` 為 `true` 後主 Agent 依回收三態判定。此路徑沒有執行紀錄與自動追加的成本列，協調者在同線 `cost-ledger.md` 追加一列 `事件（手寫）`，`cycle_role` 為 `review`，欄位見 `session-artifacts` skill「需求級成本累計」。
5. 同線同時只發一位審查者，由主 Agent 自律。

## Claude 實作路徑

Workflow 的 Phase 由 Claude subagent 承接（執行者見 `design-accepted` 檢查點「下一站」欄），依下列契約執行。Haiku 與 Sonnet 共用本節，差異列於「Sonnet 測試循環」。

### 派生契約

- 以 Agent 工具派生，`subagent_type` 為 `general-purpose`，`model` 為選派結果的 `executor.model`（`haiku` 或 `sonnet`；升級時 `opus`），冷啟動。
- prompt 含：規則來源 `~/.ai-agents/agents/claude/developer.md` 全文（in-context 傳入）；`design.md` 絕對路徑；`LineContext`，其中 `dispatchLineRoot` 等於 `sourceLineRoot`、`reportLineRoot` 為來源 `report/<lineSlug>`；`requirement-summary.md` 絕對路徑；本批 Phase 清單與各 Phase 的 T-code；報告落點；審查退回後的修正輪另含「前輪未閉合 finding 處置」表（格式見 `references/review-procedures.md`「修正派遣的前輪 finding 處置核對」）與循環標示。
- 報告落點固定為 `report/<lineSlug>/implement-closure-report.md`。
- `design.md` §5 含使用者文件 T-code 時，prompt 另帶 `references/doc-sync.md`「草稿原則」原文。
- 一次派生涵蓋執行者承接的全部 Phase，依宣告順序逐 Phase 執行與驗證。
- 派生前記錄路徑雜湊基準，派生後再記錄一次，供核對第 3 項使用，步驟見「主 Agent 核對」第 3 項。
- 禁止 `git add`、`git commit`、`git stash`、`git checkout`、`git reset`，寫入限於本批 Phase 的 T-code 檔案。

### Sonnet 測試循環

- Haiku 驗證失敗時不修復重試，回報命令原文與原始輸出。
- Sonnet 驗證失敗時可修正後重跑。每次修正前寫出假設（「我認為問題出在 X，因為 Y，所以改 Z」），修改限本 Phase 的 T-code 檔案。
- 同一驗證項目連續 3 次失敗時停止，於報告「未解決項目」列出命令原文與原始輸出，交主 Agent 依「失敗與升級」判定。

### 主 Agent 核對

`Invoke-CodexDispatch.ps1 -Operation Collect -DispatchKind workflow` 不可用於 Claude 實作報告。`scripts/dispatch/collect-contract.ps1` 的 `Invoke-Collect` 除 `Preflight` 之外，必須提供 worktree 的 `DispatchRoot` 與 `BaseSha`，並經 `Resolve-DispatchBaselineBinding` 讀取 dispatch baseline 檔，Claude 實作路徑沒有 dispatch worktree 與 baseline。因此主 Agent（可交覆核取證助手）依 `templates/dispatch/closure-report.md` 註解列出的三項檢查，加上範圍與驗證證據，逐項核對下列六項；修正輪另核對第 7 項。

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
7. 修正輪的處置核對：報告「前輪 finding 處置結果」節依 `references/review-procedures.md`「修正派遣的前輪 finding 處置核對」比對，集合與處置值全部相符。

三態判定：適用各項皆通過為「收下」；純技術缺漏為「退回」，重新派生視為修正輪次；涉及業務語意或需改變已確認設計為「升級」。報告缺失或為空時第 1 項不成立，退回，不補寫。實際改動路徑超出 Phase 範圍時退回，並要求執行者還原基準線為 clean 的越界檔案，仍越界則依 `references/implement-routing.md`「失敗與升級」處理，主 Agent 不自行還原來源樹。收下後寫入 `developer-collected` 檢查點，「已回收」欄列報告路徑與三態。

### 收斂計數

- `round`：初次派生為第 1 輪，審查者退回後的每次修正增加 1 輪，以同一 `cycle_id` 的 `cycle_round` 計。`max-rounds` 為 6，以 `cycle_id` 為單位，依「循環識別與重新起算」另起的新循環從零起算。
- `problem-key`：驗證項目使用 `<lineSlug>-impl` 加 `design.md` §6 Checkpoint 項目序號；Review 沿用 `F-<三位數>`。`dispatch-return-count` 不適用（沒有 dispatch），Git 的 `return-count` 照常分開判定。
- 停止訊號與判定順序沿用 `rules/claude/40-workflow.md` 共同收斂契約，不因執行者為 Claude 而放寬。

### 審查與修正

- 審查配對依 `rules/claude/40-workflow.md` 審查配對，Claude 實作的變更由 Codex `Reviewer` 審查。必發清單第 1 項因 diff 觸及程式碼檔而命中，不另設豁免。
- 審查者退回的修正：各 finding 依小型修改例外重判。門檻內者由主 Agent 自理，或以「前輪未閉合 finding 處置」表與 Phase 範圍重新派生同一執行者；同一執行者無法完成時依 `references/implement-routing.md`「失敗與升級」處理。

### Phase commit 回收

- 使用者授權 commit 後，依報告「Phase 對照」節逐 Phase 暫存指名路徑並建立 commit，commit 落在符合 `git-workflow` 註記模式的來源分支，commit 訊息依 `generate-commit` skill；依 `design.md` 的 Phase 宣告順序回收，同檔橫跨多個 Phase 時沿用「歸入最早 Phase」。
- Claude 實作路徑沒有 dispatch worktree，不呼叫 `Cleanup`。

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
3. 依 `rules/claude/30-dispatch.md` F1 判準判定實作工作的執行者，照常輸出 `[派工判定]` 行。執行者為主 Agent 小型修改例外，或選派入口選出的 Claude subagent（`references/implement-routing.md`「light 線的實作工作」）。
4. 撰寫實作驗收契約。Claude subagent 的 `acceptanceCriteria` 與主 Agent 自理的驗收列列出目標檔案絕對路徑、`requirement-summary.md` 絕對路徑與相關「已確定的實作約束」所在位置；每列標註〔需求 #n〕，每個需求編號至少被一列涵蓋（或列於需求摘要的排除項目），並含至少一個建置或測試命令與至少一項負向靜態檢查。驗收契約另含一列「文件同步」，列出受影響使用者文件的絕對路徑與段落標題並標註〔需求 #n〕，無影響時寫「不需要：<理由>」。主 Agent 動手前把驗收列原文寫入同線 `report/<lineSlug>/` 下的檔案，作為回收、審查與需求意圖驗收的比對來源。
5. 回收時檢查執行端報告與 diff。變更命中 Reviewer 必發清單第 2 項、改動 `library` 公開 API，或本線 UI 線別為 B、C 線時，停止後續實作站點，交 `Analyst` 依 `rules/claude/40-workflow.md`「Workflow 深度」改為 `full`，自 Design 起算。
6. 文件同步。驗收契約的「文件同步」列有受影響文件時，依 `references/doc-sync.md` 執行；該列為「不需要」時直接進入下一步。
7. 依 `rules/claude/40-workflow.md`「Reviewer 派遣發動判準」的 `light` 調整判定是否發動審查；發動時派遣單依 `references/review-procedures.md`「light 線的 Reviewer 派遣單與回收」。
8. 交由 `Analyst` 執行需求意圖驗收，逐項比對來源為第 4 步實作驗收契約各列的驗收結果、派工回報（含 Claude subagent 回報、主 Agent 自理時的完成回覆）與 `doc-sync-report.md`（若有）。缺列或缺失時依回收三態退回執行端補齊。
9. 建立 commit 前取得使用者當輪授權，與 `full` 相同。

## 共同收斂契約

四處循環共用下列收斂契約。下游規則檔只補充自身循環的識別來源與驗收方式。

| 名稱 | 機械定義 | 來源 |
| --- | --- | --- |
| `round` | 一次修正連同其驗收或回歸判定為一輪，初次執行為第 1 輪。後續續行各增加 1 輪。Review 與實作修正循環以同一 `cycle_id` 的 `cycle_round` 計；其餘循環以各自保存的計數計 | 交接 prompt、回報或回歸紀錄 |
| `target-key` | 審查或修正對象的短識別，小寫英數與連字號，例如 `c16-move` | 協調者於循環建立時指定 |
| `cycle_id` | `<target-key>-c<n>`，`c<n>` 為同一 `target-key` 的循環世代，自 `c1` 起算 | 協調者寫入 Request、派遣單或派生 prompt 的循環標示 |
| `cycle_round` | 循環內輪次，語意同 `round` | 同 `cycle_id` |
| `cycle_role` | `review` 為審查，`fix` 為實作或修正 | 同 `cycle_id` |
| `area-key` | 同一函式或同一節規則的穩定識別。規則文件使用檔案絕對路徑加最近的 Markdown 標題；檢查清單使用所屬循環與檢查項目區段 | 原始檔案標題、函式位置或驗收清單區段 |
| `problem-key` | 同一問題跨輪次不變的識別。Review 使用 `F-<三位數>`；Design 與 Demo 使用驗收檢查項目 key；派遣回收使用 `dispatchSlug` 加第 5 欄驗收列序號；Git 使用既有 finding ID 或建立時指定的固定 key | Reviewer 報告、驗收清單、派遣單第 5 欄或 Git 修正紀錄 |
| `closed` | 前輪仍未解決的問題，在本輪相同 key 的驗收結果通過，且本輪沒有該 key 的反證 | 本輪完整驗收輸出與證據 |
| `new-problem` | 本輪問題 key 不在前輪未解決問題集合，且沒有同一 key 的改寫或重新命名 | 前後輪問題集合比對 |
| `severity` | `Critical`、`Major`、`Minor`。Review 沿用 `reviewer.toml`；其他循環依檢查項目影響映射 | Reviewer 規則或各循環的嚴重度映射 |
| `max-rounds` | 6 輪，以每個循環為單位；Review 與實作修正循環以 `cycle_id` 計。只防止失控，不取代問題閉合與方向變更判定 | 需求摘要與設計文件 |

### Minor 的批次修正與候選

收斂判定順序 1 結束循環時，協調者對每個剩餘 `Minor` 擇一處理，不為 `Minor` 單獨再開一輪複審。

- 批次修正：在同一站內以一次修正處理全部剩餘 `Minor`。下一輪已因 `Critical` 或 `Major` 需要修正時，把 `Minor` 併入該輪的處置表，處置為修正。循環已結束時，協調者依 `rules/claude/30-dispatch.md`「派工後的殘餘工作」小型門檻自理，或派生同一執行者做一次修正，派生 prompt 標明為 `Minor` 批次修正並列出 finding，不附處置表；修正後只做建置與測試 gate，不增加輪次，不重新判定問題集合。
- 記為候選：協調者在同線 `cost-ledger.md` 追加 `候選` 列，格式見 `session-artifacts` skill「需求級成本累計」。
- Design 與 Demo 驗收循環的 `Minor` 一律批次修正，不記為候選，因為設計文件與 Demo 是下游直接使用的輸入。
- 批次修正的 diff 不適用 `rules/claude/40-workflow.md` Reviewer 必發清單第 1 項。只改措辭、標點、格式，或補寫既有規則的說明文字，沒有改到機制條款時，不觸發新一輪審查；觸及第 2 項，或改到規則檔的機制條款（第 5 項）時，依必發清單另發審查，該審查是新循環的第 1 輪，不是原循環的複審。
- 派遣回收的驗收列與 Git 回歸矩陣仍是放行門檻，全部成立才進入下一站。驗收列的 `Minor` 補件由協調者依小型門檻收尾，超過門檻時退回執行端補件，兩者都不增加 `recovery-round`。Git 回歸矩陣只剩 `Minor` 列失敗時，以一次批次修正處理後重跑同一份矩陣，不增加 `round`，細節見 `git-workflow` skill 第三層。

### 循環識別與重新起算

適用對象為有 `cycle_id` 的 Review 與實作修正循環。Design、Demo、派遣回收與 Git 修正循環的範圍變動依判定順序 5 停止並升級，不套用本節。

協調者在循環建立時指定 `cycle_id`，每一輪在 Request、派遣單第 4 欄或派生 prompt 標示 `cycle_id`、`cycle_round` 與 `cycle_role`。原循環尚未以判定順序 1 結束，且下列任一變動成立時，原循環停止累計，改以新循環從第 1 輪重新起算。

| 變動類型 | 判定 |
| --- | --- |
| 目標 | 下一輪派遣單第 3 欄出現上一輪第 3 欄沒有的路徑。縮小目標不觸發，原循環繼續，被移出目標的 finding 在下一輪標「撤回（目標已移出）」 |
| 需求 | `requirement-summary.md` 的程式面或功能面項目，或「已確定的實作約束」被改動 |
| 方案 | `design.md` 的已確認設計（技術選型、Phase 內容）被改動，或審查裁決改採與原循環不同的方案 |

「需求」與「方案」兩類依判定順序 5 先停止並升級，使用者拍板後才重新起算；「目標」類由協調者自行判定。重新起算依下列程序執行。

1. 追加 `循環重啟` 列到同線 `cost-ledger.md`：`cycle_id` 欄填新 ID，`cycle_round` 填 `1`，備註寫「舊循環=<舊 cycle_id>；變動類型=目標|需求|方案；原因=<一句話>；舊循環結束輪次=<n>；舊循環未結 ID 與處置=<F-nnn:延後|撤回|由新循環第 1 輪重新審查,…>」。變動原因只記在這一列。
2. 建立新 `cycle_id`，世代為同一 `target-key` 加 1，例如 `c16-move-c1` 變為 `c16-move-c2`。
3. 執行新循環第 1 輪的完整審查（`reviewer.toml`「審查輪次與範圍」），不傳前輪報告，舊循環的未閉合 ID 不帶入新循環，仍存在的缺陷由第 1 輪重新發現。
4. 重設三個計數：`max-rounds`、「連續兩輪未閉合」與「同一 `area-key` 連續兩輪新 `Major`」都以 `cycle_id` 為單位，新循環從零起算。
5. 保留舊循環已發生的 run 與成本在原 `cycle_id` 之下，舊循環的 `cycle_round` 不再增加。
6. 同一 `target-key` 的世代將達 `c3` 時停止。協調者在追加 `循環重啟` 列之前停止，向使用者說明前兩個循環的結束輪次與變動原因，取得使用者確認後才建立 `c3`，防止以重新起算繞過 `max-rounds`。

Sonnet 審查與 Claude 實作路徑沒有 RunRecord，協調者仍在派遣單或派生 prompt 標示循環，並手寫 `循環重啟` 列與 `事件（手寫）` 列。

收斂判定的執行順序與停止門檻見 `rules/claude/40-workflow.md`「Workflow 自動推進鏈與共同收斂契約」。

`RecoveryPrecheck` 未通過的 `PromptNotDelivered` 屬啟動契約錯誤。先修正啟動條件，再重新派遣；此狀態不計入派遣回收計數。純技術的報告欄位缺漏、驗收輸出缺漏與格式錯誤直接進入自動補件路徑，不形成使用者詢問站點。`dispatch-return-count` 與 Git 的 `return-count` 分開保存、分開增加、分開判定，任一循環的成功或續行都不重設另一循環的計數。

## 驗證分層

Workflow 的驗證職責按深度分四層，各層不重複執行他層的驗證：

| 層 | 執行者 | 深度 | 時機 |
| --- | --- | --- | --- |
| 淺層探針 | Claude 實作者（Developer） | 對改動的端點或畫面單發確認路徑通 | 每階段完成後，依 `design.md` §6 |
| 建置與測試 gate | Claude 實作者（Developer） | 建置與既有測試各執行一次 | 結案時一次 |
| 缺陷審查 | Codex `Reviewer`（Codex 離線時降級為 Claude Sonnet subagent） | diff-scoped 靜態審查，不執行測試 | 主 Agent 依 Reviewer 派遣判準與審查配對以派遣單發動 |
| 完整煙霧 | `integration-verify` skill，取證由 Codex `scan`（`type=test`）執行，判讀在 Claude 端 | 多情境、寫入回查、持久化往返 | 交付節點 |

`integration-verify` 的觸發方式、Reviewer 的動態證據複核條件與需求意圖驗收的歸屬見 `rules/claude/40-workflow.md`「驗證分層與 integration-verify 掛載點」。
