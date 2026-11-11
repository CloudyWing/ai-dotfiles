# 實作分流程序

本檔收錄實作工作由 Claude subagent（Haiku 或 Sonnet，升級時 Opus）承接時的派生契約、隔離操作與 Workflow Phase 的記錄格式。誰承接由執行者登錄表與選派入口判定，判定流程見 `instructions.md`「實作分流」「Claude 實作 subagent 隔離」「Workflow Phase 的實作分流」與 `executor-selection` skill。入口見 `../SKILL.md`「實作分流程序」。

## 單一工作的 Claude 承接契約

無 `design.md` 的單一工作，依下列各點派生選派入口選出的 Claude subagent。

- 以 Agent 工具派生，`subagent_type` 為 `general-purpose`，`model` 取自選派入口輸出的 `executor.model`（`haiku` 或 `sonnet`）。
- prompt 指定規則來源為 `~/.ai-agents/agents/codex/support-engineer.toml`，要求依「分流 A」執行，以 in-context 傳入完整契約欄位。`modificationScope` 為列舉的檔案與符號，`acceptanceCriteria` 為驗證命令加至少 1 項負向檢查。審查退回後的修正輪另傳條件式欄位 `priorFindingDisposition`，值為「前輪未閉合 finding 處置」表（格式見 `review-procedures.md`「修正派遣的前輪 finding 處置核對」），非修正輪不傳。回收時依同一節比對處置集合。
- Workflow Phase 的規則來源為 `~/.ai-agents/agents/codex/developer.toml`，契約見 `../SKILL.md`「Claude 實作路徑」。
- 驗證未通過時，Haiku 不修正重試，回報命令原文與原始輸出；Sonnet 依 `../SKILL.md`「Sonnet 測試循環」修正。主 Agent 依 `instructions.md`「派工後的殘餘工作」判定殘餘處置。
- 派生前依 `../SKILL.md`「主 Agent 核對」第 3 項步驟 1 記錄路徑雜湊基準。回收時依該項步驟 2 至 4 取得實際改動路徑集合，核對其落在 `modificationScope` 內。行數以 `git diff HEAD --numstat` 核對已追蹤檔，未追蹤新檔以檔案行數計。並核對驗證命令輸出。超出範圍時退回。
- Claude subagent 產出的 diff 視為派工產出，適用 Reviewer 必發清單（`instructions.md` 必發清單之後的補充句承擔）。

## light 線的實作工作

有效深度為 `light` 的線沒有 `design.md` 與 Phase，實作工作依單一工作處理。

- 執行者依 `instructions.md` F1 判準以 `-Type edit` 呼叫選派入口選出，使用上節「單一工作的 Claude 承接契約」，或由主 Agent 依小型修改例外自理。
- 契約的規格來源為同線 `requirement-summary.md`。`acceptanceCriteria` 列出其絕對路徑與相關「已確定的實作約束」所在位置，每列標註〔需求 #n〕，格式見 `../SKILL.md`「light 路徑」第 4 步。
- 隔離判定與回收核對沿用本檔「Claude 實作 subagent 隔離操作」與上節契約。

## Claude 實作 subagent 隔離操作

派生前主 Agent 執行 `git status --porcelain`，將輸出項目分為「本 Session 已知改動」與「他人項目」。處置條件見 `instructions.md`「Claude 實作 subagent 隔離」，各條件的操作如下。

| 條件 | 操作 |
| --- | --- |
| 沒有他人項目 | 不設隔離，subagent 直接在來源工作樹修改，寫入限於列舉檔案 |
| 有他人項目，目標檔案與他人項目無交集，且目標檔案含本 Session 尚未 commit 的改動 | 不使用隔離工作樹，因為它由 `HEAD` 建立，缺少這些改動。subagent 直接在來源工作樹修改，寫入限於列舉檔案 |
| 有他人項目，目標檔案與他人項目無交集，且目標檔案不含本 Session 尚未 commit 的改動 | 派生時指定 `isolation: "worktree"`。subagent 在隔離工作樹修改並執行驗證，回傳 diff，主 Agent 以 `git apply` 套回來源工作樹（目標檔案在來源樹無任何未 commit 改動，可精確套用）。套用失敗時停止並回報，不自行合併 |
| 目標檔案與他人項目有交集 | 不派生。落入小型修改例外四項者由主 Agent 自理，否則停止並回報他人項目與交集路徑 |

上表適用單一工作。Workflow Phase 不使用隔離工作樹，原因見下節。

## Workflow Phase 的判定記錄

- `[派工判定]` 使用選派入口輸出的 `dispatchLine`，理由以 `P<n>` 起首。
- 整個 Workflow 由各 Phase 選派結果中排序值最大的執行者單一承接。判定結果寫入 `design-accepted` 檢查點「下一站」欄，格式為 `Developer 派工：全部 Phase=<執行者>`；Phase 中另有主 Agent 執行的規則檔或文件撰寫時，於同一欄逐 Phase 標示，例如 `P1=主 Agent、P2=Sonnet subagent`。
- 後續檢查點（`developer-collected`）沿用同一欄並更新升級結果。不新增檢查點欄位，不新增檔案。

## Workflow 不使用隔離工作樹的原因

後續 Phase 需要看到先前 Phase 套回來源樹、尚未 commit 的成果。隔離工作樹由 `HEAD` 建立，不含這些成果，因此 Workflow Phase 的 Claude subagent 直接修改來源工作樹。

## 失敗與升級

執行者驗證失敗或審查退回，且依 `../SKILL.md`「Sonnet 測試循環」或收斂契約判定該執行者無法完成時，依下列程序處理。

1. 以 `-EscalateFrom <原執行者 id>` 呼叫選派入口取得升級候選。
2. 依 `executor-selection` skill「失敗升級與交接單」整理升級交接單，停止後續實作並請使用者拍板。
3. 使用者同意後，以交接單派生升級目標，記 exceptions「替代方案」，依據含原執行者失敗原因與證據的來源位置。
4. 失敗 Phase 的下游 Phase 依 blocking edge 等待。

不以相同條件反覆重派同一執行者。修正工作在小型修改例外門檻內時，依 `instructions.md`「派工後的殘餘工作」處理。
