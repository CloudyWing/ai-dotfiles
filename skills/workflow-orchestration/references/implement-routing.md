# 實作分流程序

本檔收錄實作工作改由 Claude Haiku subagent 承接時的派生契約、隔離操作與 Workflow Phase 的記錄格式。誰承接、何時承接的判定條件見 `instructions.md`「實作分流」「Haiku 隔離」「Workflow Phase 的實作分流」。入口見 `../SKILL.md`「實作分流程序」。

## 單一工作的 Haiku 承接契約

無 `design.md` 的單一工作，依下列六點派生 Haiku subagent。

- 以 Agent 工具派生，`subagent_type` 為 `general-purpose`，`model` 為 `haiku`。
- prompt 指定規則來源為 `~/.ai-agents/agents/codex/support-engineer.toml`，要求依「分流 A」執行，以 in-context 傳入完整契約欄位。`modificationScope` 為列舉的檔案與符號，`acceptanceCriteria` 為 1 個驗證命令加至少 1 項負向檢查。
- Workflow Phase 的規則來源為 `~/.ai-agents/agents/codex/developer.toml`，契約見 `../SKILL.md`「Haiku 實作路徑」。
- 驗證未通過時不修正重試，回報命令原文與原始輸出。主 Agent 依 `instructions.md`「派工後的殘餘工作」判定處置。
- 派生前依 `../SKILL.md`「主 Agent 核對」第 3 項步驟 1 記錄路徑雜湊基準。回收時依該項步驟 2 至 4 取得實際改動路徑集合，核對其落在 `modificationScope` 內。行數以 `git diff HEAD --numstat` 核對已追蹤檔，未追蹤新檔以檔案行數計。並核對驗證命令輸出。超出範圍時退回。
- Haiku subagent 產出的 diff 視為派工產出，適用 Reviewer 必發清單（`instructions.md` 必發清單之後的補充句承擔）。

## Haiku 隔離操作

派生前主 Agent 執行 `git status --porcelain`，將輸出項目分為「本 Session 已知改動」與「他人項目」。處置條件見 `instructions.md`「Haiku 隔離」，各條件的操作如下。

| 條件 | 操作 |
| --- | --- |
| 沒有他人項目 | 不設隔離，Haiku 直接在來源工作樹修改，寫入限於列舉檔案 |
| 有他人項目，目標檔案與他人項目無交集，且目標檔案含本 Session 尚未 commit 的改動 | 不使用隔離工作樹，因為它由 `HEAD` 建立，缺少這些改動。Haiku 直接在來源工作樹修改，寫入限於列舉檔案 |
| 有他人項目，目標檔案與他人項目無交集，且目標檔案不含本 Session 尚未 commit 的改動 | 派生時指定 `isolation: "worktree"`。Haiku 在隔離工作樹修改並執行驗證，回傳 diff，主 Agent 以 `git apply` 套回來源工作樹（目標檔案在來源樹無任何未 commit 改動，可精確套用）。套用失敗時停止並回報，不自行合併 |
| 目標檔案與他人項目有交集 | 不使用 Haiku。落入小型修改例外四項者由主 Agent 自理，否則依實作分流改走 Codex 派工 |

上表適用單一工作。Workflow Phase 不使用隔離工作樹，原因見下節。

## Workflow Phase 的判定記錄

- `[派工判定]` 理由以 `P<n> E=<是|否> T=<是|否>` 起首，執行者欄位格式同 `instructions.md` 路由優先序第 3 點。
- 判定結果寫入 `design-accepted` 檢查點「下一站」欄，格式為 `Developer 派工：P1=Haiku subagent、P2=Codex…`。
- 後續檢查點（`developer-collected`）沿用同一欄並更新改派結果。不新增檢查點欄位，不新增檔案。

## Workflow 不使用隔離工作樹的原因

後段 Haiku Phase 與 Codex 派工的 carry-in 都需要看到先前執行者套回來源樹、尚未 commit 的成果。隔離工作樹由 `HEAD` 建立，不含這些成果，因此 Workflow Phase 的 Haiku 直接修改來源工作樹。

## 混合時的順序與交接

- 全部 Codex Phase 併為單一 Workflow 派工，`RequestedUnit` 為 Codex Phase 依 `design.md` 宣告順序的有序子集，該派工的宣告單位即此子集，`ScopePlan` 的 `selected_units` 等於它。
- `-SelectedRequirement` 為 Codex Phase 所服務的需求編號。
- 執行順序為：先執行阻塞來源不含 Codex Phase 的 Haiku Phase（前段），再執行 Codex 派工，最後執行阻塞來源含 Codex Phase 的 Haiku Phase（後段）。
- Codex 派工的 `Preflight` 以 carry-in 帶入前段 Haiku 成果，後段 Haiku 在 Codex 成果套回來源樹之後執行。

## 失敗與改派

Haiku Phase 驗證失敗或 Reviewer 退回，修正工作超過小型修改例外門檻時，依下列程序改派 Codex。

1. 新建 Workflow 派工，`RequestedUnit` 為該 Phase。
2. 記 exceptions「替代方案」，依據含 Haiku 失敗原因與證據的來源位置。
3. 失敗 Phase 的下游 Phase 依 blocking edge 等待。

不反覆重派 Haiku。修正工作在門檻內時，依 `instructions.md`「派工後的殘餘工作」處理。
