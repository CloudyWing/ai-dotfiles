# 實作分流程序

本檔收錄實作工作由 Claude subagent 承接時的派生契約、隔離操作與 Workflow Phase 的記錄格式。誰承接由執行者登錄表與選派入口判定，判定流程見 `rules/claude/30-dispatch.md`「實作分流」「Claude 實作 subagent 隔離」「Workflow Phase 的實作分流」與 `executor-selection` skill。

## 單一工作的 Claude 承接契約

無 `design.md` 的單一工作，依下列各點派生選派入口選出的 Claude subagent。

- 以 Agent 工具派生，`subagent_type` 為 `general-purpose`，`model` 取自選派入口輸出的 `executor.model`。
- prompt 另帶選派入口輸出的 `executor.selfRepair` 值。
- prompt 指定規則來源為 `~/.ai-agents/agents/claude/support-engineer.md`，以 in-context 傳入下方「有效範圍契約欄位」的完整欄位。`modificationScope` 為列舉的檔案與符號，`acceptanceCriteria` 為驗證命令加至少 1 項負向檢查。審查退回後的修正輪另傳條件式欄位 `priorFindingDisposition`，值為「前輪未閉合 finding 處置」表（格式見 `review-procedures.md`「修正派遣的前輪 finding 處置核對」），非修正輪不傳。回收時依同一節比對處置集合。
- prompt 指定回報檔落點 `<work-root>/.local/ai-sessions/report/<lineSlug>/support-engineer-report.md`，重派時覆寫同名舊檔。未完成次數不寫進 prompt 與回報檔，由協調者以 `scripts/Update-ExecutorIncomplete.ps1` 保存（見 `executor-selection` skill「執行者轉移與交接單」）。工作沒有登記線而無處寫回報檔時不指定落點。
- Workflow Phase 的規則來源為 `~/.ai-agents/agents/claude/developer.md`，契約見 `claude-implement.md`。
- 驗證未通過時依 `claude-implement.md`「驗證失敗處置」處置。主 Agent 依 `rules/claude/30-dispatch.md`「派工後的殘餘工作」判定殘餘處置。
- 派生前依 `claude-implement.md`「主 Agent 核對」第 3 項步驟 1 記錄路徑雜湊基準。回收時依該項步驟 2 至 4 取得實際改動路徑集合，核對其落在 `modificationScope` 內。行數以 `git diff HEAD --numstat` 核對已追蹤檔，未追蹤新檔以檔案行數計。並核對驗證命令輸出。超出範圍時退回。

### 有效範圍契約欄位

`Maintainer` 的 fix-plan 與改動計畫、主 Agent 交給 `Support Engineer` 的任務契約都以下列欄位承載有效範圍。欄位只保存可執行的目前結果，不傳遞完整對話歷史。

- `confirmedGoal`：使用者已確認的目標與預期結果。
- `effectiveScope`：目前允許修改的檔案、符號、端點或行為範圍。
- `roundDelta`：使用者本回合新增、縮小、擴大或更正的內容，只描述差異，不取代未受影響的既定範圍。
- `priorDecisions`：先前已確認的選擇與妥協。沒有先前決策時明記「無」，不自行重建歷史。
- `exclusions`：使用者明確排除的檔案、操作或情境。沒有排除項目時明記「無」，不以空白表示沒有排除。
- `searchScope`：允許讀取與搜尋的範圍。使用者未明示讀取限制時填「不限搜尋」。
- `modificationScope`：允許寫入的範圍，必須明確列出目標檔案、符號、端點或行為。
- `persistentConstraints`：需要跨回合與交接保留的限制，以及使用者明確解除的條件。
- `acceptanceCriteria`：來自使用者需求與改動計畫的驗證條件及使用者可見結果，同時列出正向與負向驗證步驟。
- `contractVersion` 與 `replacesVersion`：目前契約版本，以及更正時取代的版本。更正時以新版本完整重交。
- `userRequirements` 與 `agentInferences`：分開記錄使用者要求與 Agent 推定；Agent 推定不得升格為使用者要求或修改授權。
- `priorFindingDisposition`：條件式欄位，只在審查退回後的修正輪必填，值為「前輪未閉合 finding 處置」表。非修正輪不要求此欄位。

使用者明確更新某個欄位時，只更新該欄位，未被更新的目標、排除項目與持續限制原樣保留並持續有效。`searchScope` 與 `modificationScope` 永遠分開判定，不由搜尋範圍推導修改授權。目標、範圍、限制或同一回合的更新順序互相矛盾時，標示衝突並停止，不以較新、較寬或文字位置自行覆蓋。

## light 線的實作工作

有效深度為 `light` 的線沒有 `design.md` 與 Phase，實作工作依單一工作處理。

- 執行者依 `rules/claude/30-dispatch.md` 派工判準以 `-Type edit` 呼叫選派入口選出，使用上節「單一工作的 Claude 承接契約」，或由主 Agent 依小型修改例外自理。
- 契約的規格來源為同線 `requirement-summary.md`。`acceptanceCriteria` 列出其絕對路徑與相關「已確定的實作約束」所在位置，每列標註〔需求 #n〕，格式見 `../SKILL.md`「light 路徑」第 4 步。
- 隔離判定與回收核對沿用本檔「Claude 實作 subagent 隔離操作」與上節契約。

## Claude 實作 subagent 隔離操作

派生前主 Agent 執行 `git status --porcelain`，將輸出項目分為「本 Session 已知改動」與「他人項目」。處置條件見 `rules/claude/30-dispatch.md`「Claude 實作 subagent 隔離」，各條件的操作如下。

| 條件 | 操作 |
| --- | --- |
| 沒有他人項目 | 不設隔離，subagent 直接在來源工作樹修改，寫入限於列舉檔案 |
| 有他人項目，目標檔案與他人項目無交集，且目標檔案含本 Session 尚未 commit 的改動 | 不使用隔離工作樹，因為它由 `HEAD` 建立，缺少這些改動。subagent 直接在來源工作樹修改，寫入限於列舉檔案 |
| 有他人項目，目標檔案與他人項目無交集，且目標檔案不含本 Session 尚未 commit 的改動 | 派生時指定 `isolation: "worktree"`。subagent 在隔離工作樹修改並執行驗證，回傳 diff，主 Agent 以 `git apply` 套回來源工作樹（目標檔案在來源樹無任何未 commit 改動，可精確套用）。套用失敗時停止並回報，不自行合併 |
| 目標檔案與他人項目有交集 | 不派生。落入小型修改例外四項者由主 Agent 自理，否則停止並回報他人項目與交集路徑 |

上表適用單一工作。Workflow Phase 不使用隔離工作樹，原因見下節。

## Workflow Phase 的判定記錄

- `[派工]` 判定行使用選派入口輸出的 `dispatchLine`，說明以 `P<n>` 起首。
- 整個 Workflow 由各 Phase 選派結果中排序值最大的執行者單一承接。判定結果寫入 `design-accepted` 檢查點「下一站」欄，格式為 `Developer 派工：全部 Phase=<執行者>`；Phase 中另有主 Agent 執行的規則檔或文件撰寫時，於同一欄逐 Phase 標示，例如 `P1=主 Agent、P2=<執行者 id>`。
- 後續檢查點（`developer-collected`）沿用同一欄，更新執行者。未完成次數不寫入檢查點，接手時以 `scripts/Update-ExecutorIncomplete.ps1 -Action Show` 讀取（見 `executor-selection` skill「執行者轉移與交接單」）。

## Workflow 不使用隔離工作樹的原因

後續 Phase 需要看到先前 Phase 套回來源樹、尚未 commit 的成果。隔離工作樹由 `HEAD` 建立，不含這些成果，因此 Workflow Phase 的 Claude subagent 直接修改來源工作樹。

## 未完成與轉移

執行者驗證失敗、審查退回或自述無法完成時，依 `rules/claude/30-dispatch.md`「執行者轉移」計次。同一任務累計三次未完成時，依下列程序處理。

1. 以 `Update-ExecutorIncomplete.ps1 -Action Show` 取得本任務完整的未完成次數對照（含已轉移走的執行者），把 `incomplete_argument` 作為 `-Incomplete` 傳給選派入口，取得候選清單的下一位執行者。入口回傳 `needs-user-decision` 時停止並回報。
2. 依 `executor-selection` skill「執行者轉移與交接單」整理交接單。
3. 以交接單派生下一位執行者，不需使用者拍板，記 exceptions「替代方案」，依據含原執行者未完成的原因與證據的來源位置，內容含完整的未完成次數對照。
4. 未完成 Phase 的下游 Phase 依 blocking edge 等待。

不以相同條件反覆重派同一執行者。修正工作在小型修改例外門檻內時，依 `rules/claude/30-dispatch.md`「派工後的殘餘工作」處理。
