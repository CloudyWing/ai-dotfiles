---
name: codex-dispatch
description: 'Codex 派工機制：依派工類型建立執行契約、以 codex exec 啟動 Codex、背景等待、取證並回收結果。當需要發動 codex、撰寫派遣單或執行派遣回收判定時使用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Codex 派工機制

本 Skill 負責派工的執行機制。是否派工由 `instructions.md` §1.5 的路由規則判定，本 Skill 只處理指令、落點、等待、取證、續 session 與回收。

## 使用時機與入口選擇

主 Agent 依 F1 判準判定要派工後載入本 Skill。執行端角色依角色規則檔引用本 Skill 的共用作業節時，只讀取被引用的節。

| 情境 | 入口 | 必要輸入 | 提供方式 |
| --- | --- | --- | --- |
| 建立資源派遣單 | `scripts\New-DispatchOrder.ps1` | `Title`、`Role`、`TargetPath`、`TaskBody`、`Acceptance`、`Boundary`、`ReportPath`、`DispatchSlug`、`LineSlug`；`OutputPath` 選填 | 命令列參數；省略 `OutputPath` 時派遣單寫入來源工作樹同線 `handoff\<lineSlug>\`，八個欄位定義見「派遣單契約」 |
| 首次啟動一筆派遣 | `scripts\Invoke-CodexDispatch.ps1 -Operation Dispatch` | `source_root`、`dispatch_root`、`line_slug`、`dispatch_slug`、至少一個 `target_path`、`prompt_path` 與 Start 所需欄位 | 只接受 `operation=Dispatch` 的 request 檔，以 `-RequestPath` 傳入 |
| 續行、恢復或需要在階段之間插入檢查 | 逐一呼叫 `Preflight`、`Prepare`、`Start` | 各 operation 的參數見「腳本介面與執行前提」 | 命令列參數；`prepare_artifacts` 沒有命令列參數，只能經 request 檔傳入 |
| 執行結束後 | `Inspect`，接著 `Collect` | 事件流、stderr、last-message、Preflight 結果與報告路徑 | 命令列參數 |
| 回收完成且不再續行 | `Cleanup` | 保存清單、RunRecord、報告與 evidence 路徑 | 命令列參數或 request 檔 |

request 檔的 `source_root`、`result_path` 與 `preflight_result_path` 只在 `Dispatch` 與 `Cleanup` 合法，其他 operation 改用對應的命令列參數。同一欄位在 request 檔與命令列不一致時以 `DispatchRequestMismatch` 停止。

## 最短正常路徑

一筆派遣依下列順序推進。每一步的產物是下一步的輸入，上一步未成功時不進入下一步。

| 步驟 | 動作 | 產物 | 下游接收者 |
| --- | --- | --- | --- |
| 1 | 產生派遣單（資源派遣），或確認 `design.md` 已通過 Design 驗收（Workflow） | 派遣單或 `design.md` | Prompt 與 Codex 執行端 |
| 2 | `Preflight` 驗證 LineContext、PID 與寫入面，決定 `executionRoot` | Preflight 結果 JSON | Prepare、Start、Collect |
| 3 | `Prepare` 將交接檔複製到 `executionRoot` 並比對 SHA-256 | `-PrepareResultPath` 寫出的 `ai-sessions.prepare.v1` 文件；`-ResultPath` 只寫 CLI envelope | Start 只接受 `ai-sessions.prepare.v1` 文件 |
| 4 | `Start` 建立 before 額度快照與 ScopePlan，背景啟動 Codex | Start 結果、事件流、stderr、last-message、thread id、PID 記錄 | 主 Agent 的等待與 Inspect |
| 5 | 等待完成通知，依「完成判定與三出口」判定出口 | 出口判定 | Inspect |
| 6 | `Inspect` 解析事件流與 last-message | `success`、`outputValid`、usage、model evidence | RecoveryPrecheck 與回收三態 |
| 7 | `RecoveryPrecheck` 通過後，`Collect` 核對成果與報告，主 Agent 判定回收三態 | Collect 結果與三態判定 | 續行、升級或同步 |
| 8 | 同步報告與核准交接產物，再執行 `Cleanup` | 保存驗證結果 | 結案報告 |

`Dispatch` 串接步驟 2 至 4，回傳 `status=started` 只代表 Codex 已啟動，不代表已檢查或已回收。步驟 5 至 8 仍由主 Agent 接續執行。

## 失敗與恢復導引

| 失敗形狀 | 恢復方式 | 詳細節 |
| --- | --- | --- |
| 額度快照 `state` 不是 `Valid`，或 observation 為 `stale` | 依「額度狀態與回復探針」重新取得即時快照；`ServiceRejected` 不自動重試 | 額度狀態與回復探針 |
| Preflight、Prepare 或 Start 在 Codex 啟動前失敗 | 修正輸入後以新的 `dispatchSlug` 重跑。失敗留下的 Prepare 結果、ScopePlan hash 紀錄或 `launch-failed` RunRecord 會使同名重試以 `PrepareResultCollision`、hash 不符或 ACL gate 拒絕 | 續 session 與跨介面接手 |
| 續行被拒 | 以 `git -C <舊 dispatchRoot> diff HEAD` 與未追蹤檔案清單轉移成果，以新的 `dispatchSlug` 冷啟動 | Codex 進程 PID 與並行檢查 |
| 事件流以 `turn.failed` 結束或 exit code 非零 | 依 C 出口取失敗原因，再依回收三態判定 | 完成判定與三出口 |
| 結案訊息缺少識別字 | 標記 `PromptNotDelivered`，修正啟動方式後重新派遣 | RecoveryPrecheck |

`dispatchSlug` 在同一個 `sourceRoot` 內不得重複，目前沒有查詢已使用 slug 的入口。`scope-plan-hash-<dispatchSlug>.json` 只以 `dispatchSlug` 命名，不同線使用同名 slug 會互相影響。命名時在 slug 中帶入線別或用途，撞名時列出 `<sourceRoot>\.local\ai-sessions\history\scope-plan-hash-*.json` 與 `worktrees\` 目錄確認已用名稱。

## 額度與範圍契約

`QuotaSnapshot` 是每次派工的額度輸入。`Get-CodexQuota.ps1 -SnapshotPath <path>` 保留既有 key-value stdout，另外寫入 `ai-sessions.quota-snapshot.v1` JSON。有效快照必須包含 `captured_at_utc`、`state=Valid`，以及 `primary` 與 `secondary` 的 `used_percent`、`remaining_percent`、`window_minutes`、`resets_at` 與 `source_file`。任何視窗缺欄位、狀態不是 `Valid` 或 reset 造成差值不可解釋時，派工以非零結束碼停止或依「額度狀態與回復探針」處理，不產生估算值。`state=Valid` 但 observation 的 freshness 為 `stale` 時不在此停止，改由 `ScopePlan` 決定。預設檔位走低額度分支並只選第一個宣告單位，`advisor-consult` 以 `blocked-no-fresh-quota` 拒絕。取得額度失敗時，快照檔仍以失敗的 `state` 與 `error` 寫出，stderr 輸出失敗類別。

`ScopePlan` 是派工前唯一的範圍決策，欄位固定如下。

```text
dispatch_slug
dispatch_kind
task_type
requested_profile
session_mode
primary_remaining_percent
primary_reserve_percent
primary_budget_percent
estimate_percent
estimate_source
unit_kind
requested_units[]
selected_units[]
deferred_units[]
decision
decision_reason
```

`unit_kind` 只允許 `workflow-phase`、`resource-target` 與 `advisor-evidence-question`。`decision` 只允許 `full`、`scoped`、`blocked-insufficient-budget`、`blocked-no-estimate`、`blocked-no-fresh-quota` 與 `user-decision-required`。Workflow 以 `design.md` 的 Phase 為最小單位，資源派遣以派遣單第 3 欄的目標物件為最小單位，advisor consult 以 evidence pack 內的問題 ID 為最小單位，`requested_units` 依 evidence pack 宣告順序排列。執行端不得自行增加或拆分單位。

先判定目標檔位門檻，再決定是否需要估算。預設檔位的門檻為 primary 剩餘 30% 與 secondary 剩餘 15%。兩個視窗都達到門檻時，`ScopePlan` 直接使用 `decision=full`、`estimate_source=not-required-above-threshold`，不要求校準樣本或保守量級。`advisor-consult` 不適用高額度放寬，一律依 activation 規則計算預算。任一視窗低於門檻時，才使用相同 `model`、`profile`、`session_mode` 與 `task_type` 分組的 eligible 樣本第 75 百分位或已核准的保守量級。低於門檻且沒有估算資料的預設檔位派工使用 `decision=scoped`、`estimate_source=bounded-single-unit`，只選第一個宣告單位並在該單位後停止，不等待使用者決定。`advisor-consult` 沒有同分組樣本時使用 task type 保守量級 24%，不跨分組借用樣本。

預設檔位低於門檻時維持預設檔位，不等待 `primary_resets_at`，也不產生 `user-decision-required`。此分支的 reserve 為 0，以 primary 剩餘作為預算，依宣告順序取可容納的最長前綴；連第一個單位都無法容納或 primary 剩餘為 0 時，仍選取第一個宣告單位並設 `stop_after_selected_units=true`。額度在執行中耗盡時，由 Budget monitor 與 `InterruptionSafeguard` 沿既有執行鏈保存狀態，主 Agent 不手動補寫 last-message 或 report。observation 為 `stale` 時同樣進入此分支，但不計算最長前綴，固定以 `estimate_source=bounded-single-unit` 只選第一個宣告單位。沒有任何 observation 時維持 `blocked-no-fresh-quota`，明確 service rejection 維持不自動重試，兩者不進入此分支。

`advisor-consult` 的 activation 分兩條路徑。額度充足指快照有效且 fresh、沒有 service rejection、已取得估算，且 `primary_remaining_percent - 30 >= estimate_percent × 1.25`；此時 `AdvisorRequestSource` 記為 `automatic-quota`，reserve 為 30%，`advisor_hard_limit_percent = estimate_percent × 1.25`，不需要使用者確認。使用者授權以 `AdvisorRequestSource=user-explicit` 表達，不檢查額度剩餘，reserve 為 0，`primary_budget_percent` 為 primary 剩餘；完整 estimate 除以問題數得到 `advisor_unit_estimate_percent`，依宣告順序取可容納的最長前綴，第一個問題即超出預算時仍選取第一個問題並記錄 `minimum_unit_over_budget=true`，其餘問題列入 `deferred_units`。使用者授權只略過 reserve 與額度門檻，不略過快照有效性、service rejection、evidence hash、read-only sandbox 與 process identity gate。兩條路徑都不成立時，以 `AdvisorAuthorizationRequired` 拒絕並不啟動 Codex。

## InterruptionSafeguard

`InterruptionSafeguard` 套用所有冷啟動與續行。PowerShell 參數保留 `DowngradeInstruction` 作為 alias，alias 只代表相同的中斷保全語意，不代表換檔或低額度降級。輸出同時保留 `interruptionSafeguardApplied` 與 `downgradeInstructionApplied`，兩者固定為相同布林值。中斷保全參數與續行 thread id 可以同時存在，續行仍沿用原始 profile 與父層選項。

每次 `Start` 都將下列原文加入 prompt。

```text
[中斷保全]
本次工作必須可在任意中斷點交付已確認結果。開始主要探索前，先寫出目前已確認的結論、證據位置與尚未確認項目。每完成一個範圍單位，更新一次「已確認結論」與「實際覆蓋範圍」。收到中止要求時，先保存已確認結論、證據位置、未完成單位與不應推論的內容，再結束本次工作。不得以未執行的單位補寫結論。
結案訊息一律以下列三行結尾，中止與正常完成都適用，讓後續續行取得交接資料。每行為單行鍵值對，值不得為空；沒有未完成單位時填「無」。
已確認結論：<一句話>
未完成單位：<清單或「無」>
證據位置：<絕對路徑或檔案:行號>
```

續行的前置條件依前輪終止狀態分流。前輪事件流以 `turn.completed` 結束時，`Start` 只要求 last-message 存在且非空；前輪被中止、早夭或終止狀態無法判定時，`Start` 另要求 last-message 具備 `已確認結論`、`未完成單位` 與 `證據位置` 三個單行鍵值對。無條件要求三欄位會使正常完成的派遣無法續行，因為中止路徑才會產生這些欄位。

## Advisor consult resource dispatch

`advisor` 是意見評估角色，不是實作檔位。實作一律使用預設檔位。`Profile=advisor` 只接受 `TaskType=advisor-consult`、`DispatchKind=resource` 與 `WriteMode=readonly`；Workflow、寫入模式或其他 TaskType 在 Codex 啟動前以 `AdvisorImplementationProfileRejected` 拒絕，`TaskType=advisor-consult` 未搭配 `Profile=advisor` 時以 `AdvisorProfileRequired` 拒絕。

`TaskType=advisor-consult` 使用單一 evidence pack，schema 為 `advisor-consult.evidence.v1`，必須包含目標段落原文摘錄與來源位置、已知結論、待答問題、可能反證與邊界。advisor 執行端只可讀取該 evidence pack，不得探索 repository、讀取其他來源、修改檔案或寫入 report。

advisor 的 worktree `Start` 仍必須提供 `PrepareResultPath`，且該檔案的狀態必須是 `Prepared`。`advisor-consult` 必須提供 `AdvisorConsultReportPath` 與 `QuotaAfterPath`。前者固定位於 `executionRoot\.local\ai-sessions\report\<lineSlug>`，檔名為 `advisor-consult-<dispatchSlug>.md`；後者必須位於 `executionRoot` 內。這兩項路徑都不能改指 `sourceRoot` 的同線 report 或其他來源落點。

evidence pack 必須位於 `executionRoot` 內，並以 `schema: advisor-consult.evidence.v1`、相同的 `line-slug` 與 `dispatch-slug` 開頭。正文固定包含 `目標段落`、`已知結論`、`待答問題`、`可能反證` 與 `邊界` 五個區段。`目標段落` 內必須有非空的 `source:` 與 `excerpt:`；`待答問題` 至少列出一個 `question-<id>:`，並恰好列出一次非空的 `required-output:`；文件另以非空 `output-rules:` 說明回傳規則。`邊界` 內必須各有一行 `- allowed-input:` 與 `- forbidden-action:`，限制 advisor 只讀取該 evidence pack，禁止探索來源、掃描 repository、修改檔案與發動其他派遣。

`## 待答問題` 以穩定 ID 逐行列出問題，格式為 `question-<id>: <問題>`，ID 在同一份 pack 內不可重複，順序即 ScopePlan 單位順序。同一節必須恰有一行 `required-output:`，值以半形分號分隔，每個值符合 `^#{1,6}[ \t]+\S`；說明文字另寫在 `output-rules:` 行。範例如下。

```text
question-001: <第一個評估問題>
question-002: <第二個評估問題>
required-output: ## 中斷保全結論; ## 證據支持; ## 推論; ## 未決問題
output-rules: 每一個問題以 question-<id> 回報完成狀態
```

`required-output` 缺漏、重複、分行、含非 heading 值或混入說明文字時，Start 以 `EvidencePackRequiredOutputInvalid` 停止。Start 的 advisor 必要參數為 `AdvisorConsultReportPath`、`EvidencePackPath`、`QuotaAfterPath` 與 read-only 邊界；缺少必要參數時以 `RequiredParameterMissing` 停止並列出欄位名稱。`ProfileEvidenceUnknown` 只用於 profile 設定檔的 model 或 reasoning effort 證據不可證明，不承接參數缺漏或 evidence 格式錯誤。

request 的 `prepare_artifacts` 必須是 object array。PowerShell 以 `ConvertTo-Json` 序列化單一元素時可能把陣列塌縮成 object，該形狀會被拒絕；即使只有一個 artifact，也要保留陣列形狀。

`Start` 將 evidence pack 全文內嵌 prompt，以 `---BEGIN INLINE EVIDENCE PACK---` 與 `---END INLINE EVIDENCE PACK---` 包夾，並附 `evidence-pack-sha256` 與 `evidence-pack-length`。執行端依內嵌內容作答，不需讀檔；read-only sandbox 下以工具讀檔會被核准政策阻擋，只給路徑的 prompt 會產生沒有技術結論的回覆。Start 產生 prompt 後重讀確認全文、hash 與長度，不符時以 `EvidencePackInlineMismatch` 停止。evidence pack 的 `## 待答問題` 必須有一行 `required-output:`，以分號分隔列出最終訊息必須包含的 Markdown heading。`Inspect` 逐一確認這些 heading 存在且內容非空，任一缺少時 `outputValid=false`、`success=false`，advisor report 另列「Required output gate」小節。

執行端最後訊息在 `## 中斷保全結論` 內列出 `已完成單位：<問題 ID 清單>`。Inspect 只接受 `completed_units` 為 `selected_units` 的子集合，`deferred_units` 不得標記完成；safe point 缺失時報告記為 `completed_units=unknown`，不以 `selected_units` 推論完成，後續由既有執行鏈 anchor 判定續行資格。advisor report 保存 `requested_units`、`selected_units`、`deferred_units`、`completed_units`、activation mode、授權來源、reserve、primary budget 與 unit estimate。

`Start` 只驗證並保存 evidence pack SHA-256，不建立 advisor report。呼叫端必須以 `Get-CodexQuota.ps1` 在 Start 前建立 `QuotaAfterPath` 指向的快照，Start 只驗證該檔格式，另在 `history` 建立本次的 after 快照並記錄其 SHA-256。Budget monitor 只更新這份自建快照：更新前後比對 SHA-256，一致時以暫存檔取代，不一致時以 `QuotaAfterSnapshotChanged` 停止。缺少 `QuotaAfterPath`、Codex home 或任一次更新失敗時以非零結束。Budget monitor 在 Codex 行程結束後仍必須補做一次 terminal quota snapshot 與 budget gate；terminal snapshot 超過 `primary_budget_percent` 時寫入 `AbortedByBudget` 事件、保留對應證據並使 `Start` 以非零結束，未超限時維持 completed。`Inspect` 或回收步驟依事件流與 last-message 寫入同線 `report/<lineSlug>/advisor-consult-<dispatchSlug>.md`，`AdvisorConsultReportPath` 必須位於同線 `reportLineRoot` 且檔名固定為 `advisor-consult-<dispatchSlug>.md`。報告區分證據支持、推論與未決問題。Start 前後的 SHA-256 不一致、Inspect 缺少 Start hash 紀錄或讀到 `AbortedByBudget` 時拒絕成功判定。

Budget monitor 同時觀察事件流與可更新的 after quota snapshot。每輪比較 primary `resets_at`，reset window 改變時寫入跨 reset 紀錄並標記不可校準，停止監看。超過 `primary-budget-percent` 時先寫入 stop request，等待最新 `agent_message` 的 `## 中斷保全結論` 區段含非空保全結論、已確認結論、證據位置與實際覆蓋範圍，最多等待 `abort-grace-seconds`，再使用已驗證的 `Stop-VerifiedProcessTree`。Codex 行程結束後仍執行一次 terminal snapshot 與 budget gate。中止後確認整棵程序樹已結束，保存 `AbortedByBudget`；等待期間沒有完整保全結論時追加 `safe-point-missing`。根程序身分無法確認時不得終止，保存 `IdentityUnverified`。

## Git 前置探針與 worktree 生命週期

所有派遣先呼叫 `scripts\Invoke-CodexDispatch.ps1 -Operation Preflight`。每次派遣必須取得上游傳入且已驗證的 `LineContext`。`lineSlug` 識別同一條 Analyst 線，`dispatchSlug` 識別單次派遣，兩者分屬不同名稱空間。缺少 `LineContext`、識別字不符合 `^[a-z0-9]+(?:-[a-z0-9]+)*$`，或 `line.json` 的 `line-slug` 與傳入值不一致時，腳本以非零結束碼停止，且不建立成功狀態。

| 欄位 | 路徑或用途 |
| --- | --- |
| `sourceRoot` | 使用者指定且已解析的 work-root 絕對路徑 |
| `lineSlug` | Analyst 已登記的語意化線識別 |
| `writeMode` | 派遣單第 6 欄標示「唯讀」時為 `readonly`，其餘為 `write` |
| `sourceLineRoot` | `<sourceRoot>\.local\ai-sessions\handoff\<lineSlug>` |
| `dispatchRoot` | `<sourceRoot>\.local\ai-sessions\worktrees\<dispatchSlug>` 的隔離 worktree 目標絕對路徑 |
| `dispatchLineRoot` | `<executionRoot>\.local\ai-sessions\handoff\<lineSlug>` |
| `sourceReportLineRoot` | `<sourceRoot>\.local\ai-sessions\report\<lineSlug>` |
| `reportLineRoot` | `<executionRoot>\.local\ai-sessions\report\<lineSlug>` |

`Preflight` 先驗證 manifest、目錄界線與同線 PID，再依寫入面判定是否需要 worktree。`write` 模式先執行不修改來源的既有 Git 探針，只有確認目標含 tracked 檔案後才進入 Git 狀態、`baseSha` 與 worktree 流程；非 Git 目錄的 direct-write 不建立臨時 Git。需要 worktree 時，Git 探針只有 exit code 為 0 且 stdout 為 `true` 時才採用 `gitOrigin=existing`；不在 Git 工作樹的明確 `fatal` 才可進入臨時 Git 流程，其他 Git 錯誤以非零結束碼回報。臨時 Git 的 `.git`、marker 與初始 commit 由腳本建立並保留，直到使用者明確觸發清理。

腳本依寫入面分流 `executionRoot`。`readonly` 固定使用隔離 worktree，`write` 只有在目標路徑包含既有 tracked 檔案時建立 worktree；只寫 Git ignored 範圍或全新輸出檔案的 `write` 直接使用 `sourceRoot`，輸出 `worktreeCreated=false`。若 `Preflight` 的 `target_path` 指向尚不存在的 dispatch worktree 內路徑，該路徑不會觸發 worktree 建立，`executionRoot` 退回 `sourceRoot`；需要建立 worktree 時，target 必須是 `sourceRoot` 內已存在且可辨識的 tracked 目標。直接寫入路徑仍須通過 sourceRoot 界線驗證。

需要 worktree 時，腳本在建立前固定 `baseSha`，以來源 `git diff HEAD --binary --no-ext-diff` 產生 tracked carry-in，並以 `git ls-files --others --exclude-standard` 取得未追蹤檔案。來源工作樹的未提交變更會帶入 dispatch worktree，`carryInManifest` 記錄 tracked patch、未追蹤檔案、複製結果與相關路徑。patch 與未追蹤檔案都在 dispatch worktree 套用或複製，路徑與目的檔案先通過根目錄界線檢查。套用或複製衝突時以非零結束碼停止並保留現況，不覆寫來源檔案。

`dispatchSlug` 限用小寫英數與連字號，同一個 `sourceRoot` 內不得重複。腳本以固定的 `sourceRoot\.local\ai-sessions\worktrees\<dispatchSlug>` 驗證 `dispatchRoot`，目標已存在時視為已被占用並停止，不以其他目錄代替隔離邊界。

臨時 Git 的 marker 是來源工作樹的控制資料，不納入初始機械 commit。marker 寫入失敗時停止後續派工並保留已建立的 `.git`；marker 缺失時不得刪除 `.git`。清理前必須重新讀取並驗證 marker 的 `schema`、`created-by` 與 `work-root`，任一缺失、格式錯誤或路徑不一致都拒絕清理。

腳本成功時輸出 JSON，至少包含 `executionRoot`、`gitOrigin`、`baseSha`、`worktreeCreated`、`carryInManifest`、同線目錄與 `pidCheck`。任何 manifest、PID、Git、worktree、patch、複製或路徑驗證錯誤均輸出具體 stderr 並以非零結束碼結束，不輸出空值、預設值或部分成功狀態。

## Worktree 安全不變量

被強制終止過的 dispatch worktree 不得重用。判別方式、失效後果與重派時的成果轉移程序見「Codex 進程 PID 與並行檢查」節，該節為此不變量的唯一權威敘述。

PID 重用判定以 `work-root`、`line-slug`、`write-mode`、根 PID、根程序名稱、根程序建立時間與完整進程樹為依據。Windows 以 `Win32_Process.ParentProcessId` 查詢根程序及後代，根程序名稱採不分大小寫完全相等，建立時間差距最多 1 秒；Unix 以根程序與記錄的 process group 核對。任一身分欄位不符、PID 被其他程序占用或身分無法驗證時，視為 PID 重用或不可確認，不阻塞派遣，也不得將目前後代視為同一棵樹。中止時只有身分驗證通過的根程序或 process group 才能進入終止流程，避免誤殺無關程序。

唯讀與寫入模式依同線三鍵判定。不同 `lineSlug` 的活躍記錄不互相阻塞；同線的 `write` 與任何其他活躍模式互斥；同線 `readonly` 可並行，但上限為 2。缺少 `write-mode` 的舊 PID 記錄視為 `write`。同線 readonly 已達上限或存在衝突時，`Preflight` 以非零結束碼停止。

主工作樹在 Codex 執行期間維持啟動前的 `HEAD` 與 `git status`。Codex 的工作目錄使用腳本輸出的 `executionRoot`。需求摘要及其 history 備份是跨派遣交接例外，仍寫入 `sourceLineRoot` 與 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>`；需由 Codex 寫入時，啟動參數必須明確授權這兩個線層目錄。

執行端不清理 dispatch worktree 內的 `scratch/`。該目錄隨 worktree 移除一併消失，提前清理會刪掉主 Agent 回收時需要複核的驗證證據。三態尚未結束、需要續 session 或程式碼尚未完成回收時，保留同一個 dispatch worktree。

## Codex 進程 PID 與並行檢查

PID 記錄歸屬來源工作樹的 `history`，格式為 `<sourceRoot>\.local\ai-sessions\history\codex-pid-<yyyyMMdd_HHmmss>.txt`。記錄中的 `pid` 是進程樹根，不代表一定是 Codex leaf process。Windows 以 PowerShell 的 `ProcessStartInfo` 啟動 `(Get-Command codex.cmd).Source` 時，實測 `Process.Id` 為 `35048`，查詢該 PID 的 `ProcessName` 得到 `cmd`，不是 `codex` 或 `node`；實際執行 Codex 的程序是其子進程。因此 Windows 端必須以根 PID 追查整個進程樹。

每次成功啟動 Codex 並取得進程識別碼後，立即建立一份新的 UTF-8 無 BOM 純文字檔，至少包含下列欄位。`pid` 保留作為相容欄位，值與 `root-pid` 相同。

```text
pid=<進程樹根 PID，與 root-pid 相同>
root-pid=<進程樹根 PID>
root-process-name=<根程序名稱，例如 cmd>
root-parent-pid=<根程序的 ParentProcessId>
root-started-at-utc=<ISO 8601 UTC 時間>
identity-verified=true
process-tree-scope=<Windows: pid-and-descendants；Unix: process-group>
process-tree-query=<Windows: Win32_Process.ParentProcessId；Unix: ps PGID 成員>
process-group-id=<Unix process group ID；Windows 不適用>
work-root=<sourceRoot 的絕對路徑>
line-slug=<LineContext 的 lineSlug>
dispatch-slug=<本次派遣的 dispatchSlug>
write-mode=<readonly 或 write>
started-at-utc=<ISO 8601 UTC 時間>
```

派工前掃描同一個 `sourceRoot` 的 `codex-pid-*.txt`。逐檔解析 `work-root`、`line-slug`、`write-mode`、`root-pid`（舊格式回退讀取 `pid`）與進程樹欄位。`work-root` 與目前絕對路徑相同、`line-slug` 與目前 `LineContext.lineSlug` 相同、進程樹或 process group 仍存活，且根程序身分比對通過的記錄，才進入 `write-mode` 判定。缺少 `line-slug` 的舊格式記錄不具備線歸屬，不滿足三鍵比對。

Windows 以 `Win32_Process` 的 `ProcessId`、`ParentProcessId`、`Name` 與 `CreationDate` 查詢根程序及其所有後代，遞迴追查每一層子程序。將查得根程序的 `Name` 與 `CreationDate` 轉為 UTC 後，分別比對 PID 記錄的 `root-process-name` 與 `root-started-at-utc`。名稱採不分大小寫的完全相等比對，建立時間差距容許最多 1 秒，以涵蓋查詢與記錄序列化的時鐘精度差異；兩項必須同時符合。任一項不符或無法查詢時，判定為 PID 重用，該筆記錄不阻塞派工，也不把其目前後代視為同一個 Codex 進程樹。根程序已結束但仍有後代時，只有在根 PID 目前不存在、PID 記錄含有由腳本寫入的 `identity-verified=true`、身分欄位完整且未發現 PID 重用的情況下，才可依 `ParentProcessId` 鏈保留活躍判定。根 PID 已被其他程序占用且身分不符時，依 PID 重用處理。Unix 以 PID 檔的 `process-group-id` 查詢 process group 成員，並以 `root-pid` 查詢根程序，依相同規則比對 `root-process-name`、`root-started-at-utc` 與查得的程序名稱、建立時間。根程序身分比對通過且群組內仍有任何程序存活時，才判定為活躍實例。根程序在身分驗證後結束但群組成員仍存活時，只有 PID 記錄包含由腳本在身分驗證後寫入的 `identity-verified=true`，且 `root-process-name`、`root-started-at-utc` 與有效的 `process-group-id` 都存在時，才沿用已驗證的根程序身分與仍存在的 process group 判定活躍；根 PID 被其他程序占用、身分比對失敗或無法完成身分驗證時，判定為 PID 重用，該筆記錄不阻塞派工。舊格式 PID 記錄若缺少 `root-process-name` 或 `root-started-at-utc`，視為無法確認身分的歷史記錄，不阻塞派工。理由是僅憑 PID、process group 或存活狀態無法排除 PID 重用。歷史進程樹已完全結束時不阻塞派工；發現依 `write-mode` 判定為衝突的同線活躍 Codex 實例時，回報活躍 PID 記錄檔、根 PID 與存活後代或 process group，停止流程。

`write-mode` 判定分三種結果。既有記錄與本次派遣都是 `readonly` 時互不阻塞，理由是唯讀派遣不修改目標物件，各自只寫入派遣單第 7 欄指定的報告檔，沒有共用寫入面。任一方為 `write` 時阻塞。同線同時活躍的 `readonly` 實例上限為 2，已達上限時停止派遣並等待既有實例結束，理由是回收端為單線，超過兩份同線報告會使統籌端的判定塞車。缺少 `write-mode` 的舊格式記錄一律視為 `write`。


Start catch 只會使用同一次啟動時已通過身分驗證的 in-memory snapshot。根程序在驗證後消失時，腳本先查詢同一 process group；仍有成員才沿用該 snapshot 終止，群組已空時直接完成收尾。沒有這份已通過驗證的 snapshot，或 PID 記錄缺少 identity-verified=true 時，不得終止 process group。

**被強制終止過的 dispatch worktree 不得重用（Crucial）**。sandbox helper 在正常結束時才移除自己套用的 ACL；被 `taskkill` 或 session 中止時來不及清理，worktree 根目錄會殘留一條明確（非繼承）的存取控制項目，其 SID 已無對應帳號。之後在該目錄啟動的 Codex 會在套用 sandbox ACL 時失敗，全程無法執行任何命令。以 `icacls <dispatchRoot>` 與來源工作樹比對即可確認：報廢的 worktree 會多出不帶 `(I)` 標記的條目。

重派時建立新的 dispatch worktree，並以 `git -C <舊 dispatchRoot> diff HEAD` 產出的 patch 將既有成果轉移至新 worktree，另以 `git -C <舊 dispatchRoot> ls-files --others --exclude-standard` 取得未追蹤檔案並逐一複製。不要嘗試修改 ACL。新 worktree 沿用同一個 `lineSlug`，`dispatchSlug` 另取未使用的名稱。轉移完成後，只有 `pwsh scripts\Invoke-CodexDispatch.ps1 -Operation Cleanup` 可移除舊 worktree；`Cleanup` 失敗時保留 worktree，不得改用其他方式強制移除。

PID 記錄保留於來源工作樹的 `history`，不因 dispatch worktree 移除或 `scratch` 清理而刪除。PID 檔案是否存在不能單獨作為並行判定依據，必須合併 `work-root`、`line-slug`、`write-mode`、進程身分比對與完整進程樹或 process group 的存活狀態；wrapper 已結束但子進程仍存活時，不得判定為可並行啟動。不同 `lineSlug` 的存活記錄必須可同時存在且不互相阻塞。同一 `lineSlug` 下兩個 `readonly` 記錄同樣必須可同時存在。

## Phase commit 回收與驗證

Codex 端不建立 commit，因此 dispatch worktree 的 `HEAD` 在派工全程維持 `baseSha`，實作成果以未 commit 的工作區變更形式存在。回收的輸入是這份工作區差異，不是 commit 區間。

Workflow Developer 的回收收下與 Phase commit 回收是兩個時點。Developer 回收判定為收下時，主 Agent 先將成果套回來源工作樹，維持未 commit 的工作區變更，不建立 Phase commit，並保留 dispatch worktree。Reviewer 退回時，續行仍使用同一個 dispatch worktree 與 thread。只有在 Reviewer 收下、需求意圖驗收完成、結案報告產出且使用者授權 commit 後，才進入 Phase commit 回收。

`Invoke-CodexDispatch.ps1 -Operation Collect` 依 `Preflight` 的 `worktreeCreated` 分流回收。`true` 時取得 `git diff <baseSha>`、`git diff --cached` 與 `git ls-files --others --exclude-standard`，再合併成完整成果清單。`false` 時不要求 `DispatchRoot` 或 `BaseSha`，改從 Preflight 的 `targetStates` 逐一核對核准輸出檔案，保存非空檔案的長度、最後寫入時間與 SHA-256 證據。direct-write 的結案報告也必須存在且非空。任何必要欄位、檔案證據或報告核對失敗時，腳本以非零結束碼停止，不把空 `baseSha` 當成 Git 基準。

差異取得後依結案報告「Phase 對照」節記載的逐 Phase 檔案清單分組。Phase commit 以 Phase 為單位回收，一個 Phase 一個 commit；`phaseCommits` 依 Phase 順序排列，commit 訊息依 `generate-commit` skill 產生。主 Agent 將各 Phase 的差異依序套用至來源分支並建立對應 commit，保留 Phase 的獨立語意。

「Phase 對照」節缺失時停止回收並依續 session 契約要求補齊。缺少該節時，主 Agent 只能看到一份混合全部 Phase 的差異，無從還原 Phase 邊界。

單一檔案橫跨兩個以上 Phase 時，該檔的差異歸入其最早出現的 Phase，並在回收回報中列出該檔與涉及的全部 Phase。

Phase 回收步驟維持一個 Phase 一個 commit，不以 merge commit 取代 Phase commit，也不在此步驟把全部 Phase squash 成單一 commit。Phase commit 回收完成後，若需要依成果整理歷史，可在 `rewrite-branch` 執行 squash。每筆整理後的 commit 必須通過可用性驗證，並通過 `git-workflow` 第一層零差異 gate。任何 commit 回收衝突都停止處理，保留 dispatch worktree、來源狀態與事件證據，交由後續裁決或續行。

Phase commit 回收完成後，依 `git-workflow` skill 的 `validationMode` 執行重整後驗證，再同步報告與核准交接產物，最後才以 `pwsh scripts\Invoke-CodexDispatch.ps1 -Operation Cleanup` 移除 Workflow Developer dispatch worktree。Architect、Reviewer 與其他資源派遣不產生 Phase commit，直接同步報告與核准交接產物後即可呼叫相同的 `Cleanup` operation。`Cleanup` 失敗時保留 dispatch worktree，不得改用其他方式強制移除。使用者授權 commit 前不得執行 Workflow Developer dispatch worktree 的 `Cleanup`。

## 腳本介面與執行前提

本地 session 需能執行 `git` 與 `codex`。機械流程由 `scripts\Invoke-CodexDispatch.ps1` 統一承接，主 Agent 仍負責 F1 路由、profile 選擇、使用者確認、任務分類、回收三態與升級判定；腳本驗證額度快照、ScopePlan、advisor evidence-only 邊界、thread relay 與安全中止。腳本只接受絕對路徑或可在已驗證根目錄內解析的目標路徑，並以 JSON 輸出結果。

| Operation | 主要參數 | 成功輸出 | 致命失敗 |
| --- | --- | --- | --- |
| `Preflight` | `SourceRoot`、`DispatchRoot`、`LineSlug`、`DispatchSlug`、`WriteMode`、`TargetPath[]` | `executionRoot`、`gitOrigin`、`baseSha`、`worktreeCreated`、`carryInManifest`、同線目錄、`pidCheck` | manifest、PID、Git、根目錄界線、worktree、patch 或檔案複製驗證失敗時 stderr 並 exit code 1 |
| `Prepare` | `SourceRoot`、`ExecutionRoot`、`LineSlug`、`DispatchSlug`、`PrepareArtifacts[]`、`TargetPath[]` | 每個交接檔的來源／目的路徑與 SHA-256、`Prepared` 狀態 | 交接檔缺漏、越界、複製失敗或 hash 不符時 stderr 並 exit code 1 |
| `Start` | Preflight JSON 或 `ExecutionRoot`、`PromptPath`、`Profile`、`TaskType`、before snapshot、`InterruptionSafeguard`（舊參數 alias 為 `DowngradeInstruction`）、ScopePlan、Codex 父層選項；advisor 另需 `AdvisorConsultReportPath`、evidence pack、`QuotaAfterPath` 與 read-only 邊界；`AdvisorRequestSource` 為選用，省略時先進入 activation，額度充足才標記 `automatic-quota` | `rootPid`、PID 記錄、事件流、stderr、last-message、thread id relay、before snapshot、ScopePlan、實際參數、有效 profile、中斷保全狀態與 monitor 證據 | 快照、ScopePlan、evidence pack、執行檔、工作目錄、啟動參數或根程序身分驗證失敗時 stderr 並 exit code 1 |
| `Inspect` | `EventStreamPath`、`ProcessExitCode`、stderr、last-message、識別字、`Model`、`TaskType`、ScopePlan、派工前後快照、thread id 路徑 | `completed`、`turn.failed` 原因、最後一則 `agent_message`、`usage`、`outputValid`、`success`、after snapshot、三層 model evidence、thread relay、advisor report 與 monitor 證據 | JSONL、thread id、必要輸入或證據包 hash 格式錯誤時 stderr 並 exit code 1 |
| `Collect` | `DispatchKind`；worktree 回收使用 `DispatchRoot`、`BaseSha`、`ReportPath[]`；direct-write 使用 `PreflightResultPath`、`ReportPath[]`；`DispatchKind=workflow` 另必須提供 `RequirementSummaryPath`；回收 Reviewer 時另提供選用的 `ReviewerReportPath` | worktree 的 tracked／staged／未追蹤差異，或 direct-write 的核准輸出檔案證據與報告證據；兩者都含依 `DispatchKind` 選用的報告核對結果；提供 `ReviewerReportPath` 時另含 `reviewerFindings`（`valid`、`conclusion`、七個 unique 計數 `previous_closed_count`、`previous_open_count`、`previous_withdrawn_count`、`current_new_count`、`current_open_count`、`current_closed_count`、`current_withdrawn_count`，以及 `duplicate_ids`、`inconsistencies`） | worktree 的差異清單或 direct-write 的核准輸出、檔案證據、報告不一致時 stderr 並 exit code 1；缺少 `DispatchKind` 或空 `baseSha` 被當成 Git 基準時同樣停止 |
| `QuotaProbe` | 已驗證的 `SourceRoot`、`ExecutionRoot`、`LineSlug`、`DispatchSlug`、`Profile`、短提示、`InitialQuotaState` 與 `ProbeAttempt` | `finalStatus`、新快照路徑與 SHA-256、`processStarted=false` 與回復紀錄 | 只允許 `PostResetNoSnapshot`、`SnapshotExpired` 與 `ServiceRejected`；`ProbeAttempt > 1`，或重新取得的快照不是 `Valid` 且 `fresh` 時 stderr 並 exit code 1 |
| `Dispatch` | request file 或等價的 `SourceRoot`、`DispatchRoot`、`WriteMode`、`DispatchKind`、`TargetPath[]`、Prepare 結果、prompt 與 ScopePlan 參數 | `Preflight`、`Prepare`、`Start` 的階段結果與 `status=started` 的 dispatch envelope；Inspect 與 Collect 另行呼叫 | request、Preflight、Prepare 或 Start 任一階段驗證失敗時 stderr 並 exit code 1 |
| `Cleanup` | `SourceRoot`、`ExecutionRoot`、`DispatchRoot`、`LineSlug`、`DispatchSlug`、RunRecord、報告與 evidence 路徑 | 已完成保存驗證且移除目標 dispatch worktree 的結果 | 保存清單、路徑界線、進程、ACL 或移除驗證失敗時 stderr 並 exit code 1；失敗時保留 dispatch worktree，不得使用其他方式強制移除 |

`Preflight` 的 `writeMode=readonly` 固定建立隔離 worktree。`writeMode=write` 只有 tracked 目標需要 worktree；ignored 或全新輸出直接回傳 `executionRoot=sourceRoot`、`worktreeCreated=false`、空 `baseSha` 與核准輸出清單。建立 worktree 時先固定 `baseSha`，再套用 tracked patch 與複製未追蹤檔案。腳本遇到衝突會停止，不以空清單或來源覆寫表示成功。`Collect` 必須消費同一份 Preflight 輸出，依 `worktreeCreated` 選擇 Git 差異或 direct-write 檔案證據路徑。

`Start` 會固定 `--cd`、`--sandbox`、`--profile`、`--add-dir`、`--search` 等父層選項的位置，再執行 `codex exec` 或同一 thread 的 `codex exec resume`。`--json`、`--output-last-message` 與 prompt 選項位於子命令之後。事件流、stderr、last-message、thread id 與 PID 記錄各自保存，啟動結果包含實際參數，供後續複核。

`Start` 每次都加入 `InterruptionSafeguard` prompt。收到 `Profile=advisor` 時先執行 advisor profile 與 TaskType gate，再依 `AdvisorRequestSource` 與額度判定 activation；`TaskType=advisor-consult` 使用 evidence pack、問題單位與 activation 決定的 reserve。預設檔位低於門檻時維持預設檔位，改由 ScopePlan 控制範圍。中斷保全不改變 profile，也不作為換檔出口。

`Inspect` 逐行解析 JSONL。空白行略過；單行解析失敗時保存原文與行號，繼續解析其餘事件，讓完整事件流仍可供診斷，但只要存在壞行，`Inspect` 就以非零結束碼拒絕產出成功狀態。可解析且具備必要欄位的 `turn.failed` 或非零 process exit code 是派工證據中的失敗結果，腳本仍輸出完整結果 JSON，其中 `success=false`、`status=inspected`。`Inspect` 本身的結束碼沿用傳入的 `ProcessExitCode`，Codex 以非零結束時 `Inspect` 也以相同非零值結束；呼叫端以結果 JSON 判定檢查內容，以結束碼判定 Codex 是否正常結束。缺少事件、非空 `type`、必要的 `thread_id`、成功事件的 `usage`、最後一則 `agent_message` 或其他必要欄位時，`Inspect` operation 以非零結束。`outputValid=false` 只表示存在 final message 但該訊息缺少必要識別字。

`Inspect` 保存事件流、usage、三層 model evidence、thread relay、advisor report 與 monitor 證據。額度 before／after snapshot 若存在則保存其實際值；snapshot 缺失或不完整時保留可取得的其他證據，不因校準觀測而改變 `Inspect` 的成功判定。

Reviewer 回收時，主 Agent 以 `Collect -ReviewerReportPath` 驗證報告的 `## Finding manifest`（schema `codex-dispatch.review-findings.v2`，規則見 `reviewer.toml`）。`reviewerFindings.valid=false` 表示報告自相矛盾或格式無法核對，`outputValid=false` 並以非零結束，依回收三態退回 Reviewer 補正；`valid=true` 且 `conclusion=fail` 表示報告有效但仍有 Critical 或 Major finding，依共同收斂契約退回 Developer 修正。兩種情況分開處理，不以 finding 數量推導結論。

v2 manifest 以 `previous_status` 記錄前輪結束時的狀態快照，以 `current_judgment` 記錄本輪對每個 finding 的判定，`counts` 含七個欄位且只供等值驗證，`evidence` 路徑必須是絕對路徑，且同一 ID 在 manifest 與正文「本輪 finding 判定」段落的證據位置必須相同。

Collect 回收 Reviewer 報告有兩種模式，輸出的 `collect_mode` 標示採用哪一種。

| 模式 | 觸發條件 | 行為 |
| --- | --- | --- |
| `structural-only` | 提供 `ReviewerReportPath`，但缺少 request 或 RunRecord | 只驗證報告格式與 manifest 一致性並回傳 `reviewerFindings`，不寫入狀態帳，不視為回收完成。Reviewer 依 `reviewer.toml` 自我檢查報告時落在此模式 |
| `full` | request 與 RunRecord 皆提供 | 執行完整身分驗證，涵蓋 request、Preflight、RunRecord、報告路徑、執行鏈 anchor 與執行端最終訊息，全部通過才寫入狀態帳 |

主 Agent 回收 Reviewer 結果時使用 `full` 模式；`structural-only` 的結果不得作為閉合判定的依據。`full` 模式依 `current_judgment` 中 `status=closed` 的 unique ID 計算本輪閉合數，並寫入同線 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>\review-finding-ledger.json`，以 `finding_id` 加 `round` 為唯一鍵保存每個 finding 的跨輪狀態。判斷某個 finding 目前是否閉合時，讀狀態帳或最新一輪的 `current_judgment`，不讀 `previous_status`。v1 報告的 `previous_status` 依 v1 條文承載本輪判定，Collect 以 manifest 與正文「前輪 finding 狀態」節一致為前提讀取，兩者不一致時拒絕回收。

Start、Inspect、RunRecord 的 model 與 reasoning effort 分為三層證據，契約為 `codex-dispatch.model-evidence.v1`：

| 層 | 來源 | unknown 條件 |
| --- | --- | --- |
| `requested` | 呼叫端明確傳入的 `-Model`、`-ReasoningEffort`，只作為 assertion | 未傳入 |
| `resolved` | 實際 profile 設定檔的 top-level `model`、`model_reasoning_effort`；預設檔位讀 `<CodexHome>\default.config.toml`，`advisor` 讀 `<CodexHome>\advisor.config.toml` | 檔案不存在、欄位缺少、格式錯誤或重複衝突 |
| `runtime_verifiable` | 以 `session_meta.payload.session_id` 精確對應事件流 `thread_id` 的 rollout，取本輪 `turn_context.payload.model` 與 `payload.effort` | 找不到對應 rollout、欄位缺少或多筆值衝突 |

明確 assertion 與 resolved 值衝突時，Start 在啟動前以 `RequestedResolutionMismatch` 停止。Inspect 保存 resolved 與 runtime 的實際 evidence 值；任一為 unknown 或兩者不一致時，保留差異作為診斷資訊，不使 Inspect 以非零結束。事件流 error 中的「recorded with model X」只作為原 thread 模型的診斷證據，不填入本輪 runtime 值。

派工腳本的回歸測試以 `Test-DispatchRecoveryBinding.ps1 -Phase 1|2|3` 單一入口執行，入口會在 Windows PowerShell 5.1 與 pwsh 7 各啟動一次並聚合結果，任一環境失敗即整體 exit 1。回收覆核時執行此入口，不需另外分別呼叫兩個執行環境。

`Collect` 在 worktree 路徑合併 `git diff <baseSha>`、`git diff --cached` 與 `git ls-files --others --exclude-standard` 的檔案清單。報告核對方式依 `DispatchKind` 分流：`workflow` 以結案報告「Phase 對照」節逐項比對檔案清單，並以「需求對照」節比對 `RequirementSummaryPath` 的需求項目編號，`resource` 只確認報告存在且非空並回傳其長度與 SHA-256。「需求對照」核對要求需求摘要同時具備 `## 程式面項目` 與 `## 功能面項目` 兩節，兩節表格的 `#` 編號合併後不得重複，且每個編號在結案報告「需求對照」表格恰有一列 `#<n>`；表格固定 6 欄（需求、驗收方向、T-code、實際行為、證據、狀態），以未跳脫的 `|` 切欄，每欄非空，狀態為四個合法值之一。缺節、摘要編號重複、缺列、重複列、多出摘要沒有的編號、欄數不符或欄位為空時，以非零結束碼停止並列出不符的編號。此核對只驗結構完整，不判定內容是否正確，內容一致性由 Reviewer 的需求對照核對負責。resource 的結案要求是逐條驗收，不逐 Phase 列出檔案清單，對它要求「Phase 對照」節會使每次資源派遣都無法回收。direct-write 路徑則讀取 Preflight 的 `targetStates`，確認每個核准輸出都存在、為非空檔案，並回傳檔案長度、最後寫入時間與 SHA-256。任一數量、路徑、檔案證據或報告不一致都停止回收，且在成果尚未完成回收前不得移除 worktree。

交接物同步由獨立的 `Prepare` operation 執行（`ai-sessions.prepare.v1`）：只複製請求中明確列出、位於同線來源與允許目的根目錄內的檔案，逐一比對來源與目的 SHA-256，全部一致才標記 `Prepared`，任一缺件、越界或 hash 不符時標記 `PrepareFailed`。`Preflight` 不複製交接物，交接物只經由 Prepare 進入 worktree；建立 worktree 時的 tracked patch 與未追蹤檔案 carry-in 是工作區內容的同步，仍由 Preflight 執行，不屬於交接物複製。worktree 模式的 Start 必須收到 `Prepared` 結果，缺少或不一致時以 `PrepareRequired`／`PrepareArtifactMismatch` 停止；direct-write 使用 `status=not-required`。Start 一律建立本次 before snapshot 並綁定到 RunRecord，呼叫端提供的 `QuotaBeforePath` 只驗證格式；CodexHome 依序取顯式參數、`CODEX_HOME`、使用者目錄下的 `.codex`，實際值寫入 Prepare 結果、Start 輸出與 RunRecord。

跨程序傳入陣列參數（`TargetPath`、`AddDirectory`、`CodexParentOption`）時，以 `-RequestPath` 傳入 `ai-sessions.dispatch-request.v1` JSON 檔，陣列元素的原文與順序即契約，逗號、空白、中文與 `$` 不經 shell 展開或重新切分。`powershell.exe -File` 無法以命令列傳遞字串陣列，逗號串接會被視為單一字串，跨 PowerShell 執行環境呼叫時一律使用 request 檔。request 檔與命令列同一欄位不一致時以 `DispatchRequestMismatch` 停止。

額度快照保存 `observations`（兩個視窗最後一次實際觀測的 used／remaining、觀測時間、來源、freshness 與 resets_at）與 `service_rejection`。usage-limit 事件記為 `service_rejection`（`status=quota-rejected`、`retry_allowed=false`），不改寫最後觀測值；過期快照保留觀測值並標示 freshness，不宣稱為即時額度。預設檔位在低於門檻時依「額度與範圍契約」的低額度分支繼續派工，不進入等待使用者決定；中斷保全沿用既有執行鏈錨點保存狀態。收到明確額度拒絕後不自動重試，等待重設或新的觀測證據。advisor-consult 的 reserve 依 activation 路徑決定，額度充足為 30%，使用者授權為 0。

### 額度狀態與回復探針

`Get-CodexQuota.ps1` 每次呼叫都向即時額度來源取得一份新觀測，快照 `state` 只會是下列三種之一。

| 狀態 | 判定條件 | 處置 |
| --- | --- | --- |
| `Valid` | 回應含 `primary` 與 `secondary` 兩個視窗且欄位合法，沒有拒絕旗標 | 進入額度門檻判定 |
| `ServiceRejected` | 回應帶有額度拒絕旗標 | 不自動重試，等待重設或新的觀測證據 |
| `SnapshotUnavailable` | 認證資料缺漏、連線失敗、逾時、HTTP 非 2xx、回應格式或數值範圍不合法 | 以非零結束碼停止，stderr 保留失敗類別，不產生估算值 |

observation 的 `freshness` 在寫入快照時依觀測時間距今判定，30 分鐘內為 `fresh`，超過為 `stale`，派工腳本讀取時沿用寫入值，不重新計算。即時來源寫出的快照一律為 `fresh`；`stale` 只出現在其他來源寫出的舊快照文件，此時依「額度與範圍契約」的低額度分支處理，或重新取得一次快照。

`QuotaProbe` 是額度狀態的一次性回復入口，`ProbeAttempt` 上限為 1，`InitialQuotaState` 只接受 `PostResetNoSnapshot`、`SnapshotExpired` 與 `ServiceRejected`。前兩者由呼叫端依既有快照判定，`QuotaProbe` 以新檔重新取得即時快照，`state=Valid` 且 `freshness=fresh` 時回傳 `finalStatus=quota-source-refreshed-no-probe`，不啟動 Codex；否則以非零結束碼停止。`ServiceRejected` 寫入 `finalStatus=service-rejected-no-retry`，不啟動 Codex 也不重試。

回復紀錄寫入 `.local\ai-sessions\history\<lineSlug>\quota-recovery-<dispatchSlug>.json`，保留初始狀態、觸發視窗、嘗試次數、新快照路徑與 SHA-256、重試結果與最終狀態。回復紀錄是派工證據，不是額度快照來源，不得讀回當作額度估算。`QuotaProbe` 成功後，呼叫端以回傳的 `quotaSnapshotPath` 或重新取得的快照進入額度門檻判定；`advisor-consult` 依額度充足或使用者授權重新判定 activation。`advisor` 的使用者授權不略過快照有效性。

### 執行可用性

`Invoke-CodexDispatch.ps1` 解析 `git` 與 `codex` 的實體路徑，並在 `Start` 輸出實際的父層與子命令參數。執行檔、工作目錄或參數探針失敗時，腳本保留 stderr 與事件證據並以非零結束碼回報。

| Session 型態 | 派工能力 | 處置 |
| --- | --- | --- |
| Desktop Code tab、VS Code 擴充、CLI、SSH 或 WSL 的 local session | 可發動 | 依本 Skill 的指令契約執行 |
| Dispatch 對話本身或 cloud session | 不可發動 | 明確回報「當前 session 不載入全域規則，請於 local Code session 發動」，不嘗試執行 `codex` |
| Dispatch 派生的 local Code session | 可發動 | 依本 Skill 的指令契約執行 |

派工命令執行前由主 Agent 準備 `sourceLineRoot`、`<sourceRoot>\.local\ai-sessions\history\<lineSlug>`、`sourceReportLineRoot`、`dispatchLineRoot`、`reportLineRoot`，以及 `executionRoot\.local\ai-sessions\history` 與 `scratch`。來源 `sourceLineRoot\requirement-summary.md` 與同線來源 `history` 的覆寫備份保存跨派遣交接；事件流、stderr、thread id 與 PID 記錄維持在既有的 `history` 根目錄；固定報告與例外紀錄落在 `reportLineRoot`。資源派遣若需更新來源需求摘要或其 history 備份，啟動命令必須以 `--add-dir` 授權這兩個來源線層目錄。報告檔與 `<work-root>/.local/ai-sessions/report/<lineSlug>/exceptions.md` 依派遣契約的明文寫入例外處理。若主 Agent 無法完成前置作業，停止啟動並回報缺件。所有輸出父目錄必須在啟動前完成建立。

## 指令契約

正式啟動與續行都由 `Invoke-CodexDispatch.ps1 -Operation Start` 執行。`sourceRoot`、`executionRoot`、`dispatchSlug`、`lineSlug` 與輸出檔案路徑使用絕對路徑。腳本保存 `codex exec` 或 `codex exec resume` 的實際參數，並以 `-` 從 prompt 檔案傳遞完整內容。

`--cd`、`--sandbox`、`--add-dir`、`--search` 與 `--profile` 是 `codex` 的父層選項，必須放在 `exec` 或 `exec resume` 之前。`--json`、`--output-last-message` 與 `--output-schema` 是子命令選項，必須放在子命令之後。`--search` 只有在需求明確需要網路查證時才加入；`--add-dir` 只有在需求明確需要 worktree 外寫入時才加入，並列出絕對路徑。

### 事件流形狀

`--json` 將 JSONL 事件輸出至 stdout。每則事件是扁平 JSON 物件，以 `type` 欄位分類，不使用 JSON-RPC 封裝，也沒有 request id 與 response 關聯。實測 codex-cli 0.153.4 的最小事件序列如下。

```text
{"type":"thread.started","thread_id":"<uuid>"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"<內容>"}}
{"type":"turn.completed","usage":{"input_tokens":0,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}
```

| 事件 | 用途 |
| --- | --- |
| `thread.started` | `thread_id` 是續行識別，寫入 `executionRoot\.local\ai-sessions\history\codex-thread-<dispatchSlug>.txt` |
| `item.completed` 且 `item.type` 為 `agent_message` | 最後一則的 `text` 是結案訊息 |
| `item.completed` 且 `item.type` 為 `command_execution` | 累計次數反映實際讀取與執行量，可用於判斷派遣是否確實走完目標物件 |
| `turn.completed` | 唯一的正常完成證據，其 `usage` 提供本次實際 token 用量 |
| `error` | 伺服器端錯誤，`message` 是原文，通常緊接在 `turn.failed` 之前 |
| `turn.failed` | 明確的失敗終止，`error.message` 是原因，例如額度耗盡或模型不被接受 |

`turn.failed` 與 `error` 只出現在事件流，不寫入 stderr。派遣失敗時 stderr 可能完全為空，因此失敗原因一律從事件流末尾取得，不以 stderr 是否有內容判斷是否失敗。

stdout 只包含事件流 JSONL，診斷訊息一律走 stderr，兩者分別重導至不同檔案。

### 跨平台啟動

`Start` 由腳本建立固定的工作目錄、父層選項、子命令選項與 prompt stdin。Windows 以進程樹根 PID 啟動並保存 `Win32_Process` 的名稱、父 PID 與建立時間；Unix 以 `setsid` 建立 process group，並由同一份快照驗證 PID、parent PID、process group、程序名稱與建立時間後，才產生 `IdentityStatus=confirmed` 與 `IdentityVerified=true`。任一欄位缺漏、格式錯誤或建立時間無法取得時，快照維持未確認狀態，腳本以非零結束碼失敗，保留已寫入的 stderr 與事件路徑。

啟動參數位置、prompt 傳遞與 PID 記錄欄位由腳本固定產生。這些輸出是後續 `Inspect`、續 session 與安全中止的輸入，主 Agent 不重新拼接命令列或以單一 PID 推論整棵進程樹。

Codex 已啟動但在根程序快照完成前早夭，或身分查詢拋出例外時，失敗路徑必須先保存已收集的 stderr，再回報 `eventStreamPath`、`errorStreamPath`、process exit code 與其他證據路徑，最後使用已持有的 process handle 或已驗證的 process group 收尾。不能以「查不到根 PID」取代原始啟動錯誤，也不能在身分無法確認時終止現有記錄所指向的程序。

### Prompt 必備元素

Prompt 必須明列已驗證的 `LineContext`，格式如下：

```text
lineSlug=<lineSlug>
sourceLineRoot=<sourceRoot>\.local\ai-sessions\handoff\<lineSlug>
dispatchLineRoot=<executionRoot>\.local\ai-sessions\handoff\<lineSlug>
reportLineRoot=<executionRoot>\.local\ai-sessions\report\<lineSlug>
```

`executionRoot` 取自 `Preflight` 的輸出，不由 Agent 自行推導。`worktreeCreated=false` 的直接寫入派遣沒有 dispatch worktree，此時 `executionRoot` 等於 `sourceRoot`，`dispatchLineRoot` 與 `reportLineRoot` 隨之落在來源工作樹。以 `dispatchRoot` 組出的路徑在該情境會指向不存在的位置。

Prompt 至少包含下列元素，缺一即視為契約未滿足。

1. 執行角色的觸發詞或 skill 名稱。Workflow 派工使用 `Developer` 的觸發詞；資源派遣使用派遣單第 2 欄指定的角色或 skill。
2. Workflow 派工使用 `dispatchLineRoot\design.md` 的絕對路徑，資源派遣使用派遣單的絕對路徑。
3. `LineContext` 的 `lineSlug`、`sourceLineRoot`、`dispatchLineRoot`、`reportLineRoot`、`sourceRoot`、`dispatchRoot` 與相關產出落點的絕對路徑。
4. 回報格式、產出落點與驗收條件。Workflow 派工另須要求結案報告包含輪起點 SHA、開工基準線、「Phase 對照」節、「需求對照」節與「判定為既有實作而未動工」節，並列出 `sourceLineRoot\requirement-summary.md` 的絕對路徑供 Developer 產出「需求對照」節。「Phase 對照」節逐 Phase 列出該 Phase 實際修改的檔案清單，供主 Agent 依 Phase 分組建立 commit。續 session 必須重述前輪「Phase 對照」與「判定為既有實作而未動工」兩節的全部條目。

需要以結構約束結案報告時，另建立 JSON Schema 檔並加入 `--output-schema <FILE>`。該選項只約束最終回應的形狀，不改變事件流格式。

## 模型檔位規則

本 Skill 只使用預設檔位與 `advisor`。實作、審查、掃描與命令執行一律使用預設檔位；`advisor` 只作意見評估。預設檔位的實際 model、effort 與其餘設定以 `~/.codex/default.config.toml` 為準，兩份 profile 設定檔均可保留 `[agents]` 區段，規則層只傳遞語意檔位名稱。

`codex exec` 與 `codex exec resume` 屬 runtime command，接受 `--profile`。檔位以 `--profile <檔位名稱>` 傳遞，放在 `exec` 子命令之前。預設檔位一律傳入 `--profile default`，讀取 `~/.codex/default.config.toml`。

探針分兩種，證明範圍不同，不可互相取代。

| 探針 | 檔位 | 證明範圍 |
| --- | --- | --- |
| 機制探針 | 成本較低的獨立檔位 | 派工流程本身可運作，例如路徑、prompt 傳遞與事件流解析 |
| 正式參數探針 | 與本次派遣完全相同的檔位 | 本次啟動參數合法且該檔位可用 |

機制探針只在驗證流程改動時使用，不能代替正式參數探針。正式派工前一律執行正式參數探針；以 `advisor` 派工時，該探針同樣使用 `advisor`，其消耗計入本次派遣。低成本檔位的名稱與內容由使用者提供，規則層不預設其存在。

版本探針只證明 CLI 可執行，不證明本次啟動參數合法。`--help` 在參數驗證前短路輸出，也不具正式參數證明力。正式參數探針必須沿用本次派遣完整的父層選項與檔位；腳本的 `Start` 輸出實際參數與證據路徑，供呼叫端執行及核對該探針，不能以機制探針的成功取代正式參數探針。

`advisor` 適用於推理密集且判斷資料可事先整理成 evidence pack 的意見評估，例如方案取捨、結案或續優化判斷與設計疑點評估。實作、例行編輯、步驟完整的任務、單一命令驗證、大量讀寫或掃描一律使用預設檔位，不以 `advisor` 執行。

`advisor` 相對預設檔位的實際差異由兩份設定檔的差集決定，不由本文件斷言。說明諮詢價值前，先讀取 `~/.codex/advisor.config.toml` 與 `~/.codex/default.config.toml`，比對兩者的 `model`、`model_reasoning_effort` 與其餘鍵。

### advisor 的前置準備

預設檔位的成本與推理特性由 `default.config.toml` 的 model 與 effort 決定。`advisor` 的實測成本基準為一小時即可用完整個 `primary` 5 小時視窗。這項數據只用來估計諮詢規模，不直接取代依分組累積的校準值。

降低成本的方式是減少執行端自行探索的讀取量，不是縮小任務範圍。檔位本身的成本特性由本機檔位設定決定，設定方式見 README 的 Codex profile 檔位設定章節。

派工前完成下列準備。準備不足時 `advisor` 會把額度花在自行摸索，而不是產出結論。

- 派遣單第 3 欄逐一列出目標物件的絕對路徑，不使用目錄萬用字元，避免執行端自行決定讀取範圍。
- prompt 明列已知結論、已讀過的檔案與不需重讀的部分，讓執行端直接進入判斷。
- 需要限制讀取量時，在 prompt 明文要求單一 agent 執行並說明理由。執行端派生 subagent 時每個 subagent 各自消耗額度，讀取量隨並行數累加。
- 額度不足以支撐完整任務時，在 prompt 加入中斷保全指示：要求先寫出已確認的結果並註明實際覆蓋範圍，於安全點保存結論與證據，再結束目前派遣。實測該指示可使中斷的派遣仍交付部分成果。

本機檔位設定調整後，冷啟動的消耗結構隨之改變，前述門檻應依調整後的實測值重新校準，不沿用調整前的數據。

續行同一 thread 的輸入快取狀態與冷啟動不同，因此續行與冷啟動必須分組校準。續行必須沿用初始啟動的完整父層選項，包含 `--profile`，跨檔位續行不成立。所有續行仍注入中斷保全指示，並沿用同一份 `ScopePlan` 與保全狀態。

### 額度快照

`~/.ai-agents/scripts/Get-CodexQuota.ps1` 以 Codex home 的 `auth.json` 取得認證標頭，向 `https://chatgpt.com/backend-api/wham/usage` 取得即時額度，這是額度快照的唯一來源。回應必須同時含 `primary` 與 `secondary` 視窗，每個視窗換算為 `used_percent`、`remaining_percent`（`100 - used_percent`）、`window_minutes`、`window_days`（`window_minutes / 1440`）與 `resets_at`（Unix timestamp，秒）。`source_file` 記錄端點與請求時間，不是本機檔案路徑。不得讀取或輸出 `auth.json` 的任何欄位值；認證資料缺漏或格式錯誤時，腳本只回報欄位名稱與檔案路徑。

快照檔一律以新檔寫入。`Get-CodexQuota.ps1 -SnapshotPath` 以排他建立開檔，目標已存在時以 `QuotaSnapshotTargetAlreadyExists` 停止且不覆寫。派工腳本以 `New-QuotaSnapshotPath` 在 `history` 產生 `quota-before-*`、`quota-after-*` 或 `quota-source-refresh-<dispatchSlug>-*` 唯一檔名。呼叫端提供的 `QuotaBeforePath` 與 `QuotaAfterPath` 只驗證格式，不寫入；Start 另建本次的 before 快照並綁定到 RunRecord，advisor 另建本次的 after 快照。`Dispatch` 建立的 before 快照經 stage binding 交給 Start 沿用，不重複取得。

快照只代表取得當下的用量。兩個視窗由所有檔位共用，不依模型分別計量。`advisor` 單次派遣可能在數十分鐘內耗盡整個 `primary` 視窗，使派工當下的剩餘百分比無法代表派遣全程可用的額度，因此執行中的用量由 Budget monitor 以 after 快照追蹤。快照 `state=Valid` 時交由 `ScopePlan` 依「額度與範圍契約」處理；`state` 不是 `Valid` 時停止派工，或依「額度狀態與回復探針」處理。

兩個視窗都是固定視窗，`used_percent` 在視窗內單調累積，跨過 `resets_at` 後歸零並跳至下一格，額度不連續回補。`primary` 為 5 小時視窗，`secondary` 為 7 天視窗，容量相差約 33 倍，因此同一件任務在 `primary` 消耗的百分點約為 `secondary` 的 30 倍。

腳本成功時依序輸出下列兩組 key-value。主 Agent 以同一次讀取的 `primary_remaining_percent` 與 `secondary_remaining_percent` 進行檔位判定。

```text
primary_used_percent=
primary_remaining_percent=
primary_days_to_reset=
primary_window_minutes=
primary_window_days=
primary_resets_at=
primary_resets_at_local=
primary_source_file=
secondary_used_percent=
secondary_remaining_percent=
secondary_days_to_reset=
secondary_window_minutes=
secondary_window_days=
secondary_resets_at=
secondary_resets_at_local=
secondary_source_file=
```

### 額度門檻與檔位選擇

`Inspect` 預設唯讀。`Inspect` 不寫入 `quota-calibration.jsonl`；`ScopePlan` 可讀取既有檔案作為歷史資料。

預設檔位的門檻為 `primary` 30% 與 `secondary` 15%。`advisor` 不使用固定門檻表，依「額度與範圍契約」的 activation 規則判定額度充足或使用者授權。

門檻與估算依既有 `model`、`profile`、冷啟動／續行與 `task_type` 分組資料讀取。設定檔更換模型後，既有資料只能作為歷史觀測，不能直接套用到新的分組。

1. 主 Agent 先判斷工作是否屬意見評估，且判斷資料可整理成 evidence pack。實作與執行類工作一律使用預設檔位。
2. 屬意見評估且額度充足時，主 Agent 可在適當的節點直接發動 `advisor` 諮詢，不需要使用者確認。
3. 額度不足時，只有使用者授權才發動 `advisor`，並以 `AdvisorRequestSource=user-explicit` 傳入；授權後不檢查額度剩餘，範圍依剩餘額度縮小問題前綴。
4. 預設檔位低於門檻、快照 `state=Valid` 時（observation 為 fresh 或 stale 皆同），冷啟動與續行維持預設檔位，依低額度分支繼續派工，不等待使用者決定。所有出口都注入 `InterruptionSafeguard`，保留已確認結論、證據位置、未完成單位與不可推論內容。續行沿用原始 thread、父層選項與 ScopePlan。
5. 額度腳本失敗、輸出缺少任一視窗欄位，或以 `advisor` 派工而 `advisor.config.toml` 不存在時，停止需要額度判定的派工，不使用估算值或隱式 profile fallback。
6. 預設檔位一律傳入 `--profile default`，檔位名稱只允許預設與 `advisor` 的語意集合，臨時驗證檔位不進入派工判定。

`ScopePlan` 仍可讀取既有 `<sourceRoot>\.local\ai-sessions\history\quota-calibration.jsonl` 的歷史資料，用於估算與門檻判定；`Inspect` 不新增或更新該檔案，也不輸出推薦訊號。

### 決策歸屬

檔位由主 Agent 於派工當下決定。主 Agent 必須保留兩個視窗的剩餘額度與任務難度判定，供回報與後續複核使用。

### advisor 授權請求

額度充足時 `advisor` 直接啟動，不輸出授權請求。額度不足且主 Agent 判斷值得諮詢時，才在派工前輸出單行授權請求，格式如下。

```text
[advisor 諮詢授權] primary 剩餘 <n>%；完整評估預估 <m>%；本次授權會略過 30% primary reserve，並依可用額度縮小問題前綴；<需要 advisor 的具體理由>。是否執行 advisor 諮詢？
```

理由必須指出該評估的推理密集點與 evidence pack 已整理完成的依據。只寫「問題較難」或「需要深入分析」不構成理由。請求文字本身不構成授權證據；使用者明確同意後，以 `AdvisorRequestSource=user-explicit` 重新送出派工。使用者未回覆或未明確同意時不發動 `advisor`，不等待也不重複詢問。

檔位判定不得只依 exit code 推論 profile 已生效，必須同時確認啟動參數與產出證據。

## 完成判定與三出口

`codex exec` 是一次性 process，完成判定的依據是事件流末尾與 process 結束狀態的組合，不是單一訊號。報告檔是否出現、stdout 是否閒置、單看 exit code 都不足以判定完成。

| 出口 | 判定條件 | 後續動作 |
| --- | --- | --- |
| A 正常結束 | 背景指令已離開執行狀態、exit code 為 0，且事件流最後一則事件的 `type` 為 `turn.completed` | 進行事件流取證，再執行回收判定 |
| B 執行中查詢 | 背景指令仍在執行，使用者要求現況 | 回報事件流最後一則事件的 `type` 與時間，不中止也不改變等待方式 |
| C 早夭 | 背景指令已離開執行狀態，且事件流最後一則事件的 `type` 不是 `turn.completed` | 最後一則為 `turn.failed` 時取其 `error.message` 作為失敗原因；事件流含 `agent_message` 時取最後一則作為未完成回報，依回收三態判定，不視為正常結束；兩者皆無時讀取 stderr 與 exit code 並回報啟動失敗 |

`turn.completed` 與 exit code 0 必須同時成立才走 A 出口。任一不成立即走 C 出口，包含事件流以 `turn.completed` 結束但進程以非零結束碼離開的組合。無法取得 exit code 時同樣走 C 出口，不以事件流單方面判定成功。

C 出口的常見成因包括參數位置錯誤、模型不被伺服器接受、額度用盡與 sandbox 權限失敗。參數與環境類失敗在 stderr 留下訊息，額度與伺服器類失敗只出現在事件流的 `turn.failed`，因此兩者都必須保存並在判定時一併查看。

### 腳本背景與證據

`Start` 將 Codex 置於背景執行，立即輸出根 PID 與所有證據檔案路徑。主 Agent 由執行環境的完成通知接續，再呼叫 `Inspect` 與 `Collect`；不以檔案大小、stdout 閒置或單一 exit code 判定完成。

需要中止時，腳本只對已通過 PID 身分比對的根程序或 process group 執行安全關閉，並再次查詢確認進程樹已結束。無法完成身分驗證時保留進程與證據，不執行終止。

### 主 Agent 的等待方式

主 Agent 優先以背景方式執行 `Start`，由執行環境的完成通知重新接手，再讀取事件流、last-message 與報告檔。若執行環境沒有背景完成通知，改以相同父層選項、子命令、prompt 與證據路徑同步阻塞執行；背景與同步的完成判定完全相同。主 Agent 不以輪詢檔案大小、stdout 閒置或派生 subagent 等待取代事件流取證。

## 事件流取證

`Start` 將事件流寫入 `executionRoot\.local\ai-sessions\history\codex-exec-<yyyyMMdd_HHmmss>.jsonl`，將 stderr 寫入同目錄的 `codex-exec-<yyyyMMdd_HHmmss>.stderr.log`。兩者都必須在正常結束與失敗路徑保存。`Inspect` 逐行解析事件流，空白行略過；任一非空行格式錯誤或缺少 `type` 時保存壞行原文並以非零結束碼拒絕產出成功狀態，不放棄其餘可解析事件的診斷價值。

| 取證項目 | 來源 |
| --- | --- |
| `threadId` | 第一則 `thread.started` 的 `thread_id` |
| `finalMessage` | 事件流中最後一則完整 `item.type` 為 `agent_message` 的 `text`；`--output-last-message` 檔只作一致性證據，結果記於 `lastMessageConsistency`，`finalMessageSource` 固定為 `event-stream` |
| `completed` | 事件流最後一則事件的 `type` 是否為 `turn.completed` |
| `usage` | `turn.completed` 的 `usage` 物件，作為本次實際消耗記錄 |
| `outputValid` | 最後訊息是否同時包含派遣單絕對路徑、`dispatchSlug` 與 `lineSlug` |
| `exitCode` | process 結束碼 |
| `stderr` | stderr 檔案完整內容 |

事件流與本輪 thread、turn 屬同一份證據，因此是 `finalMessage` 的唯一來源；外部 last-message 檔可能是前輪或其他派遣的輸出，只用來比對。外部檔存在且內容與事件流不同時 `lastMessageConsistency=Mismatch`，路徑與本輪 RunRecord 不符時為 `BindingMismatch`，兩者都使 `outputValid=false`、`success=false`；比對前將 CRLF 與 CR 統一為 LF，只移除開頭一個 BOM 與結尾換行。事件流沒有最後的 `agent_message` 時，`Inspect` 以非零結束碼停止；只有已取得 final message 但識別字不完整時才輸出 `outputValid=false`。若事件流最後為 `turn.completed` 但 monitor 含 `AbortedByBudget` 或 `monitor.terminal-budget-exceeded`，`Inspect` 保留完整事件與 monitor 證據，輸出 `success=false`。

`usage` 只作為事後記錄與額度對照，不取代派工前的額度快照判定。

`finalMessage` 一律保留在 `history` 的 last-message 檔，不寫入報告落點。`Wait-ForThreadRelay` 逾時後若未取得非空 `threadId`，`Start` 必須輸出 `source=not-ready` 與事件流、stderr、PID 等證據並以非零結束，不得以空字串表示成功；收到有效 `thread.started` 時才以非空 thread id 繼續。

執行角色已在派遣單第 7 欄與其規則檔指定的落點寫入報告，該檔是驗收對象。回收端若把結案摘要寫進同一路徑，會在驗收前覆蓋角色產出的完整報告。Workflow 派工的 `reportLineRoot\implement-closure-report.md` 同樣由 `Developer` 自行寫入，回收端只讀取與驗收。

報告落點檔案不存在或為空時，依回收三態的「退回」處理，要求角色補齊，不以 `finalMessage` 代寫。

## 續 session 與跨介面接手

若需要補齊欄位或修正純技術驗收問題，先從 `codex-thread-<dispatchSlug>.txt` 讀取 `thread_id`，再以 `codex exec resume` 續行。續 session 沿用同一個 `dispatchRoot`、sandbox 邊界、`LineContext`、檔位、完整 `ScopePlan` 與 PID 身分驗證規則，並重新注入 `InterruptionSafeguard`。冷啟動寫入 ScopePlan 後，Start 以原始檔案位元組計算 SHA-256，保存至 `<sourceRoot>\.local\ai-sessions\history\scope-plan-hash-<dispatchSlug>.json`；紀錄固定包含 `dispatch_slug`、`line_slug`、`scope_plan_path`、`sha256` 與 `created_at_utc`，既有同名紀錄不得覆寫。`ResumeThreadId` 必須同時提供既有 `ScopePlanPath` 與前輪 last-message 交接資料；Start 必須讀取同名 hash 紀錄、確認 ScopePlan 絕對路徑一致並重新計算檔案 SHA-256，紀錄缺失、路徑不符或 hash 不一致時以非零結束，且不得啟動 Codex。hash 紀錄是 ScopePlan 未被改寫的唯一判定依據，不使用 `.original.json` sidecar 或自行計算 fingerprint。hash 通過後，Start 再確認 ScopePlan 欄位完整、`selected_units` 加 `deferred_units` 等於 `requested_units`、`session_mode=cold-start`，且 `dispatch_slug`、`dispatch_kind`、`task_type`、`requested_profile`、`unit_kind` 與 `requested_units` 和本次續行呼叫參數一致；任一不一致時以非零結束，且不得啟動 Codex。範圍不足時依既有 ScopePlan 保存已確認結果與證據，再由回收端決定後續 cold-start。

續行的父層選項必須與初始啟動完全相同，包含 `--profile`、`--add-dir` 與 `--search`。這組選項從初始啟動記錄重建，不依當下判斷重新推導；任一項缺漏都會改變檔位、寫入權限或網路能力，使續行的執行條件與前一輪不一致。`Start` 會檢查續行識別、保全指示與 `ScopePlan` 是否一致，拒絕缺少必要交接資料的請求。

準備或啟動失敗的嘗試以 `launch_state=launch-failed` 與 `failure` 物件保存，包含 `phase`、`reason_code`、原始例外與事件流、stderr 等原始輸出位置，保留於執行鏈供稽核，不刪除。RunRecord 以 `attempt_parent_run_id` 記錄前一次嘗試，以 `previous_run_id` 與 `resume_anchor_run_id` 記錄可續行的 thread 錨點，兩者分欄。最新嘗試為失敗且 PID 檢查沒有活躍程序時，同一 dispatchSlug 可再冷啟動。續行時沿 `attempt_parent_run_id` 往回略過失敗嘗試，找到有效錨點並把略過的嘗試與理由寫入 `resume_diagnostics.skipped_attempts`；找不到有效錨點時以 `NoValidResumeAnchor` 停止。

續行在建立 launcher 前比對原 thread 模型與本次 resolved 模型。原 thread 模型依序取自錨點 RunRecord 的 runtime 證據、錨點對應 rollout 的 `turn_context`，以及錨點事件流 error 中唯一可解析的「recorded with model X」。兩邊都確認且不同時以 `ThreadModelMismatch` 停止，任一邊無法確認時以 `ThreadModelUnknown` 停止，兩者都不啟動 Codex 並輸出雙方證據。模型不一致時改以新 dispatchSlug 冷啟動。reasoning effort 不同不阻擋續行，差異保存於證據。

Start 與 Inspect 的失敗結果帶 `reason_code`：`QuotaStop`、`QuotaServiceRejected`、`RequiredParameterMissing`、`AdvisorImplementationProfileRejected`、`AdvisorProfileRequired`、`AdvisorAuthorizationRequired`、`EvidencePackRequiredOutputInvalid`、`EvidencePackMissing`、`EvidencePackInvalid`、`EvidencePackInlineMismatch`、`ProfileEvidenceUnknown`、`CodexLaunchFailed`、`ProcessIdentityUnknown`、`ThreadRelayTimeout`、`BudgetMonitorStopped`、`ThreadModelMismatch`、`ThreadModelUnknown` 或 `Unknown`。`turn.failed` 或非零 exit 沒有可確認原因時使用 `Unknown`，並保留原始事件行與 stderr；stderr 為空不代表沒有錯誤。

前輪以 usage-limit 中止、沒有 last-message、啟動失敗或終止原因不明時，續行沿既有執行鏈的 `attempt_parent_run_id`／`previous_run_id` 尋找有效 anchor；找不到有效 anchor 時以 `NoValidResumeAnchor` 停止。執行鏈保留失敗嘗試、事件流、ScopePlan、baseline、父層選項、process gate、ACL gate 與 model evidence，成果仍由 Inspect 與 Collect 驗收。沒有 last-message 本身不是拒絕原因。

初次 Start 將有效父層選項寫入 RunRecord 的 `parent_options`（`profile`、`sandbox`、`add_directory` 保留原文與順序、`search`、`codex_parent_option` 保留原文與順序、`working_directory`）與 `parent_options_sha256`。續行未顯式傳入時從錨點還原，顯式傳入時逐欄比對，任一不同即以 `ParentOptionsMismatch` 拒絕並輸出欄位、數量與首個差異索引，不以當次呼叫值覆蓋錨點值；舊 RunRecord 沒有此欄位時輸出 `ParentOptionsUnknown`，不續行原 thread。

啟動 launcher 前，於 process gate 之後、模型比對之前，比較 dispatch root 相對 source root 多出的非繼承 ACE。多出條目時以 `WorktreeAclResidue` 停止，查詢失敗時以 `WorktreeAclUnknown` 停止；direct-write 且兩者同根時為 `not-applicable`。Codex 在 `turn.started` 後沒有後續事件且非零結束時，Inspect 判定 `InterruptedUnknown`，保存事件尾段、stderr 與 exit code，重新檢查 ACL 並輸出 `cold_start_recommended=true`；該 worktree 不再作為續行目標，冷啟動改用新的 dispatch worktree。

`Start` 以 `ResumeThreadId` 讀取指定 `thread_id` 後建立續行命令，重新產生事件流與 stderr 檔案，不覆寫前一輪記錄。續行的父層選項從初始啟動結果重建，包含 `--profile`、`--add-dir` 與 `--search`。

`exec resume` 的 session 識別接受 `thread_id` 或 thread 名稱，UUID 優先解析。省略識別並改用 `--last` 會選取最近一次記錄的 session，該行為依賴本機記錄狀態而非本次派遣的識別，因此派工流程一律明列 `thread_id`，不使用 `--last`。Start 將錨點 RunRecord 的前輪 last-message 原文注入續行 prompt。前輪以 `turn.completed` 結束時只要求該訊息存在且非空；前輪被中止、早夭或終止狀態無法判定時，另要求訊息明列已確認結論、未完成單位與證據位置三個單行鍵值對，缺少任一項時拒絕續行。此分流與「InterruptionSafeguard」節一致。

續行 prompt 仍來自 scratch 檔案並以 `-` 從 stdin 傳入，內容必須重述同一組 `LineContext`、`dispatchRoot`、檔位與父層選項，列出前輪「驗證證據」及「Phase 對照」的既有條目，並逐項附上未達成條件清單。已完成的條件不得以摘要取代，續行只補齊明列的缺漏。續行的對象是 Reviewer 時，未達成條件以前輪報告的 finding ID 逐一列出（例如 `F-003 未閉合：<一句話>`），並附上主 Agent 對每個 ID 所做修正的位置；不以新措辭重述缺陷，讓 Reviewer 依 ID 判定閉合狀態。

跨介面接手視為同一條 line 的續行，依序讀取下列交接物重建狀態。

1. `dispatchLineRoot\design.md`。
2. `sourceLineRoot\requirement-summary.md`。需要由 Codex 寫入或讀取來源交接時，沿用啟動命令的 `--add-dir` 授權。
3. 本輪 `executionRoot\.local\ai-sessions\history\codex-exec-<yyyyMMdd_HHmmss>.jsonl`。
4. `reportLineRoot\implement-closure-report.md` 或派遣單第 7 欄指定報告。

### 中止與安全關閉

中止只針對 PID 記錄中 `work-root`、`line-slug` 與 `dispatch-slug` 三者均匹配本次派遣的進程樹，並依「Codex 進程 PID 與並行檢查」的根程序名稱、建立時間及 process group 或後代鏈身分比對後執行。使用者要求中止前若無法完成身分驗證，保留進程與證據，不執行任何 `taskkill` 或 `kill`。終止後再次查詢確認全部程序已結束，並保存事件流、stderr 與 exit 資訊。

被中止的派遣不視為完成，依 C 出口處理。

## sandbox 外環境動作

需要網路或 work-root 外環境變更的工作，由主 Agent 在派工前代執行。代執行前必須取得使用者當輪明確同意。非互動情境無法取得當輪同意時停止並回報缺件。

代執行後追加 `<work-root>/.local/ai-sessions/report/<lineSlug>/exceptions.md`，觸發類型使用「偏離設計」，並記錄外環境動作、同意依據與位置。寫入前確認 `LineContext.lineSlug` 與同線 manifest 一致。不得以開放 sandbox 網路取代 `--search`，也不得把 shell 出網工作直接派給 Codex。

## 網路能力硬邊界

`--search` 是 Codex 的唯一上網路徑，且屬 `codex` 的父層選項，必須放在 `exec` 或 `exec resume` 之前。Codex shell 無法以 `curl` 或其他一般 shell 工具出網；開啟 sandbox network access 也不代表 shell 查證可用。

下列工作需要 shell 出網，應由 Claude 端依外環境動作規則處理，或先取得使用者當輪同意後由主 Agent 代執行。

- `npm install`。
- `git fetch`。
- 下載檔案或套件。

事實查核類派遣必須啟用 `--search`。未啟用時，Codex 可能無法取得資料而改以記憶作答。

## 兩種派工差異

共用本 Skill 的機制。Workflow 派工與資源派遣只以輸入、產出與結案要求區分；兩者都先使用 `Preflight` 依寫入面選擇 dispatch worktree 或 `sourceRoot`。

| 面向 | Workflow 派工（`Developer`） | 資源派遣（`Architect`、`Reviewer`、`Support Engineer`、其餘一切） |
| --- | --- | --- |
| 必備輸入 | `dispatchLineRoot\design.md` 絕對路徑 | `executionRoot\.local\ai-sessions\handoff\dispatch-order-<dispatchSlug>.md` 派遣單絕對路徑 |
| 產出落點 | `reportLineRoot\implement-closure-report.md`，回收後同步至 `sourceReportLineRoot` | `executionRoot\.local\ai-sessions\report\dispatch-report-<dispatchSlug>.md`，回收後同步至 `sourceRoot` |
| 結案要求 | 「驗證證據」節的輪起點 SHA 與開工基準線皆有值，「Phase 對照」節逐 Phase 列出修改的檔案清單，且「需求對照」節涵蓋需求摘要的全部項目編號 | 先通過 `RecoveryPrecheck`，再逐條執行派遣單第 5 欄的命令並得出「收下」、「退回」或「升級」之一 |

`requirement-summary.md` 是跨派遣的持久交接檔，固定於 `sourceLineRoot\requirement-summary.md`；覆寫前備份固定於 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>`。這兩個來源落點不屬於 `dispatchRoot` 的派遣產出，資源派遣若需寫入它們，必須在 `exec` 子命令前以 `--add-dir` 分別授權來源線層 `handoff` 與 `history` 目錄。

## 執行端共用作業

本節由角色規則檔引用。角色規則檔決定哪些產出套用哪一項作業，本節只規定作業步驟。引用本節的角色無法讀取本節時，停止寫入並回報缺件，不略過該作業。

### 覆寫前備份

適用於角色規則檔指定需保留前版的固定產出，例如 `design.md`、需求摘要與同線固定報告。依下列順序執行，備份不需詢問使用者確認。

1. 確認目標檔案是否存在。不存在時直接寫入新內容，不建立備份。
2. 確認 `<work-root>\.local\ai-sessions\history\<lineSlug>\` 存在，不存在時建立。
3. 將既有檔案改名為 `<原檔名>.<yyyyMMdd_HHmmss>` 並移入該目錄，時間戳取備份當下時間。同名備份已存在時停止並回報，不覆寫既有備份。
4. 確認備份檔存在後，才寫入新內容。

`lineSlug` 必須與同線 `line.json` 的 `line-slug` 一致。`history` 位於來源工作樹時，Codex 執行端需要啟動命令以 `--add-dir` 授權來源 `history\<lineSlug>\`。角色規則檔明定不備份的產出（例如 Reviewer 依派遣單覆寫的報告檔）不套用本節。以腳本或批次指令改寫既有檔案的備份另依 `instructions.md` §1.4「腳本改寫安全」，存入 `backups\<時間戳>\`，與本節的逐檔改名備份用途不同。

## 派遣單契約

資源派遣使用 Markdown 派遣單，來源路徑為 `sourceRoot\.local\ai-sessions\handoff\dispatch-order-<dispatchSlug>.md`，複製至 `dispatchRoot` 後供 Codex 讀取。派遣單屬該次派遣輸入；它與跨派遣的 `requirement-summary.md` 使用不同落點，後者固定於 `sourceLineRoot`。`dispatchSlug` 限用小寫英數與連字號，同一個 `sourceRoot` 內不得重複。八個欄位全部必填，缺少任一欄即視為契約未滿足。

| # | 欄位 | 內容要求 |
| --- | --- | --- |
| 1 | 任務標題 | 一句話，含動詞 |
| 2 | 執行角色 | Codex 端 Agent 觸發詞，例如「值班工程師」或 `review`，也可填 skill 名稱，例如 `fact-check-note` |
| 3 | 目標物件 | 檔案、目錄或端點的絕對路徑，逐項列出 |
| 4 | 任務內容 | 含動詞與具體對象，不使用「處理 X」或「改善 Y」等無法驗收的描述 |
| 5 | 驗收條件與 Codex 命令 | 以表格逐列提供驗收條件與第三方可執行命令；Codex 必須回報命令原文與原始輸出，包含完整 stdout、完整 stderr、exit code 與執行時間 |
| 6 | 執行邊界 | 描述工作類型、目標物件、允許的報告與交接寫入，以及不得修改目標物件等行為限制。第 6 欄不描述 repository 排除檔案清單，隔離由 dispatch worktree 與 `--cd` 提供。「唯讀」定義為不得修改目標物件、不得執行建置與測試、不得建立 commit；非唯讀派遣同樣不建立 commit，commit 由主 Agent 回收後處理。所有派遣共用三項明文寫入例外：派遣單第 7 欄的報告檔、執行角色規則檔指定的同線固定報告，以及 `<work-root>/.local/ai-sessions/report/<lineSlug>/exceptions.md`。角色固定報告的檔名由該角色的規則檔定義，派遣單不逐一列舉；第 6 欄不得以未列舉為由否定該寫入，否則角色規則與派遣單邊界會互相否定。需要完全不寫入任何檔案時，明文寫出「不產生任何檔案寫入」。 |
| 7 | 產出落點 | 報告或產物的絕對路徑 |
| 8 | 回報必備欄位 | Codex 端回報必須逐條列出第 5 欄命令原文、完整 stdout、完整 stderr、exit code、執行時間、執行狀態與判定結果。執行狀態為已執行、受阻、未執行或已補驗四選一，執行端只可使用前三者；受阻須說明缺少的環境能力與原始錯誤。已補驗只由主 Agent 於回收補驗後填寫 |

第 5 欄格式如下。

```markdown
| # | 驗收條件 | Codex 命令 |
| --- | --- | --- |
| <n> | `<absolute-path>` 存在且非空 | `Get-Item -LiteralPath '<absolute-path>'` |
| <n> | 內容含指定欄位 | `rg -n '<pattern>' '<absolute-path>'` |
```

第 5 欄的 `rg` 命令有兩種會靜默失效的寫法。兩者都讓命令正常結束、exit code 符合預期，只有輸出是空的，因此會被執行端與複核端同時誤讀為「負向驗證通過」，而該條驗收實際上從未被檢查。

| 錯誤寫法 | 成因 | 正確寫法 |
| --- | --- | --- |
| `rg -n 'A\|B\|C'` | 派遣單多以 heredoc 產生，`\|` 原樣寫入檔案。ripgrep 使用 Rust regex，`\|` 是字面管線字元而非 alternation | `rg -n 'A|B|C'` |
| `rg -n '^## 標題$'` | 目標檔為 CRLF 時，`$` 錨點在 `\r` 之前匹配失敗，即使該行確實存在 | `rg -n '^## 標題'` 或 `rg -n '^## 標題\r?$'` |

負向驗證不得只以 `rg` 的 exit code 1 作為通過依據，必須另附一條明確計數命令佐證。理由是 exit code 1 同時代表「確實無匹配」與「模式寫錯導致無匹配」，兩者無法從結束碼區分。

第 5 欄的驗收條件分兩類，主 Agent 為每一條標示所屬類別。

| 類別 | 斷言對象 | 未修改狀態下的預期 |
| --- | --- | --- |
| 新行為條件 | 本輪要達成的結果 | 不成立 |
| 回歸守衛條件 | 本輪不得破壞的既有行為 | 成立 |

主 Agent 送出派遣單前，對每一條新行為條件執行一次自我測試。自我測試在目標尚未修改的狀態下實際跑該條命令，確認它回報不成立。任一條在未修改狀態下就回報成立時，該條無法區分「已完成」與「檢查失效」，改寫後重測，改寫前不得送出派遣單。

回歸守衛條件在未修改狀態下必然成立，無法用同一方式檢驗，改以在派遣單寫明其守衛對象，讓回收時能判斷該對象是否仍受檢查。把回歸守衛條件當成新行為條件送去自我測試，會得到「條件恆真」的錯誤結論並導致無效改寫。

報告在派遣單第 8 欄之外另附各條的類別與未修改狀態輸出，供回收時比對。

### 受阻條件

每條驗收條件有四種執行狀態，執行狀態與條件判定分開記錄。執行端只填寫前三種，已補驗由主 Agent 於回收時填寫。

| 執行狀態 | 定義 | 條件判定 |
| --- | --- | --- |
| 已執行 | 命令在執行端實際跑完並取得輸出 | 依輸出判定成立或不成立 |
| 受阻 | 命令因執行端環境能力不足而無法執行，例如程序查詢被拒、無網路、無桌面控制 | 一律計為未成立 |
| 未執行 | 執行端未嘗試該條命令 | 一律計為未成立 |
| 已補驗 | 受阻或未執行的條件由主 Agent 在回收時補跑並取得輸出 | 依補驗輸出判定成立或不成立 |

受阻計為未成立，理由是該條的斷言對象從未被檢查。把受阻視為通過會讓回報呈現「全部通過」，而實際上該條保護的行為仍是未知狀態。實測一次受阻條件被回報為「受阻」而非未成立，該條所驗的修正實際失效，主 Agent 自行補驗才發現。

執行狀態與第 5 欄的類別是兩個正交軸。類別描述斷言對象，執行狀態描述該條是否跑過，任一類別都可能出現任一執行狀態。回歸守衛條件受阻時，其「未修改狀態下必然成立」的預期本身不受影響，變的是該預期尚未被驗證。受阻代表結果未取得，不代表基準行為已失效，因此該條計為未成立並等待補驗，而非判定基準行為被破壞。

#### 所需能力標註

依賴執行端環境能力的條件，在第 5 欄「驗收條件」欄位開頭以 `[需要:<能力>]` 前綴標註，允許值為 `process-query`、`network`、`desktop`、`build`、`container`、`gpu`。需要多項時以半形逗號分隔。無前綴表示不依賴特殊能力。

前綴可機械判定，回收端據此判斷該條是否已標註，並選擇補驗環境。標註同時是派遣前的檢查點：能改寫為不依賴該能力的等價檢查時優先改寫，不改寫則接受受阻可能發生。

#### 補驗

受阻與未執行條件由主 Agent 在回收時補驗，補驗結果取代原判定，該條執行狀態改記為「已補驗」，並附補驗的命令原文、完整 stdout、完整 stderr、exit code 與執行時間，與執行端回報的原始受阻紀錄並存。

補驗只在命令無外部副作用時自動執行。命令會改變外部狀態時，例如寫入資料庫、送出網路請求、修改目標物件或建立資源，主 Agent 不得自動補驗；此時改以無副作用的等價檢查補驗，或取得使用者當輪明確同意後才執行原命令。無法判定命令是否有副作用時，視為有副作用。

主 Agent 無法補驗時，該條維持未成立並依回收三態處理。以退回續行處理受阻條件前，必須先改變執行環境的能力集合或改寫該條為不依賴該能力的檢查；能力集合未改變時的續行會產生同一受阻結果，不得作為退回的唯一動作。

派遣單第 5 欄列入建置或測試命令時，該條的執行與輸出責任仍屬主 Agent，執行端回報「未執行」即為正確行為，由主 Agent 補驗後填入結果。

自我測試涵蓋三類失效，這三類的共同特徵是命令正常結束、exit code 符合預期，只有輸出是空的或結論是錯的。

| 失效類型 | 實例 | 自我測試如何攔截 |
| --- | --- | --- |
| 模式寫錯導致永遠無匹配 | `rg` 的 `\|` alternation 與 CRLF 下的 `$` 錨點 | 未修改狀態下應有匹配卻回報無匹配 |
| 門檻寫錯導致條件恆真 | 以「縮排不超過 N 個空格」約束縮排，使所有行被壓到同一數值 | 未修改狀態下就回報成立 |
| 比對範圍過寬導致條件恆假 | 比對縮排時連內容一起比，而內容本就會因其他改動而變 | 未修改狀態下的失敗原因與待驗收項目無關 |

透過 PowerShell 取得 `git show` 輸出時，以位元組讀取後自行以 UTF-8 解碼。PowerShell 會以 console 編碼解碼子行程輸出，非 ASCII 內容會變成替代字元，使逐字比對產生假性不一致。改在 Bash 以管線處理位元組同樣可行。

資源派遣的建置與測試由主 Agent 自行執行，不列為 Codex 第 5 欄的命令輸出責任。Workflow 派工沒有派遣單第 5 欄，建置與測試依 `developer.toml` 的結案 gate 由 Developer 執行。

複核政策唯一：主 Agent 逐條核對 Codex 回報的命令原文與輸出是否支持其判定結論，這是核對而非重新執行。只有在輸出與結論不一致、輸出缺漏、回報只寫「已完成」而無命令輸出，或該條執行狀態為受阻或未執行時，才實際重跑該條命令。不整套重跑全部條件。

回收覆核的外部事實查證由主 Agent 負責。主 Agent 可在回收階段使用可用的上網工具查證派遣報告涉及的版本、規格、官方行為或其他驗收必要事實。派遣報告的自述不取代查證，查證也不取代第 5 欄命令輸出。每筆查證證據必須保留查詢內容、來源連結、查證時間、相關原始輸出或摘錄，以及支持或不支持驗收結論的判定，寫入回收報告或同線查證證據。來源不足、查證失敗或結果矛盾時，標示未驗證並交由回收三態處理，不得以推測補足。

## RecoveryPrecheck

事件流取證後，先從符合目前派工類型的 `agent_message` 取最後一則結案訊息。識別字依派工類型判定，兩種類型都必須包含 `dispatchSlug` 與 `lineSlug`，第三項識別字如下。

| 派工類型 | 第三項識別字 |
| --- | --- |
| Workflow 派工 | `dispatchLineRoot\design.md` 的絕對路徑 |
| 資源派遣 | 派遣單的絕對路徑 |

Workflow 派工沒有派遣單，以派遣單絕對路徑作為共同條件會使正常結案一律被判為 `PromptNotDelivered` 並重派。缺少任一識別字時，狀態設為 `PromptNotDelivered`，修正啟動方式後重新派遣；此狀態不計入退回次數，也不進入第 5 欄驗收缺漏的退回計數。只有 `RecoveryPrecheck` 通過後，才可進入回收三態判定。

### 回收收斂判定

回收三態套用 `instructions.md` §1.5 的共同收斂契約。一次修正連同其驗收或回歸判定為一輪，初次執行為第 1 輪。對派遣回收而言，`recovery-round` 記錄每次純技術續行增加的輪次。派遣回收的 `problem-key` 使用 `dispatchSlug` 加派遣單第 5 欄的驗收列序號，驗收列序號在同一派遣的各輪保持不變。

派遣回收的 `area-key` 為派遣單第 5 欄驗收條件所屬的目標物件檔案與節名。嚴重度映射如下。

| 循環 | `Critical` | `Major` | `Minor` |
| --- | --- | --- | --- |
| 派遣回收 | 產出遺失、證據不可追溯或錯誤同步 | 必要驗收條件不成立或回報與產出矛盾 | 單一欄位、格式或命令輸出缺漏且可直接補件 |

- 每輪逐條保存第 5 欄驗收結果、命令輸出、報告與事件證據。前輪未成立的驗收列在本輪相同 key 成立且沒有反證時標記 `closed`；本輪 key 不在前輪未成立集合且沒有同一 key 的改寫或重新命名時標記 `new-problem`。
- `dispatch-return-count` 只記錄該派遣的退回稽核資料，不作一般停止條件。`PromptNotDelivered` 是啟動契約錯誤，不增加此計數。
- 全部驗收列成立時進入下一站。前輪問題連續兩輪未閉合、同一 `area-key` 連續兩輪出現新的 `Major` 以上問題、修正需要改變需求或已確認設計，或 `recovery-round` 達到 6 輪時停止，保留證據並提出替代方向。
- 所有問題均屬純技術可解、未命中上述停止訊號，且前輪問題已閉合或本輪新問題只有 `Minor` 時自動續行。新出現的 `Major` 在尚未形成停止訊號前依純技術路徑續行。

## 回收三態判定

背景指令結束後，主 Agent 先執行 `RecoveryPrecheck`，再讀取 dispatch worktree 內派遣單第 7 欄的產出落點，依第 5 欄逐條核對。核對與重跑的分界見上節的複核政策。主 Agent 不以 Codex 端回報中的自述取代實際判定。派遣單第 8 欄必須要求 Codex 端逐條回報每條驗收條件的命令原文與完整 stdout、完整 stderr、exit code 與執行時間。主 Agent 以抽驗方式複核回報內容，對輸出與結論不一致的條件只重跑該條命令。回報只寫「已完成」而未附命令輸出者，該條計為未成立。

標示為受阻或未執行的條件一律計為未成立，不因回報語氣看似無礙而放行。主 Agent 對每條受阻條件與每條未執行條件執行補驗，補驗結果取代原判定並將該條狀態改記為已補驗；補驗不可行時該條維持未成立。全部驗收條件成立的判定必須建立在「已執行且通過」與「已補驗且通過」兩種狀態之上，不得包含任何未補驗的受阻或未執行條件。

Codex 端不建立 commit。Workflow `Developer` 的機械 commit 由主 Agent 依 `design.md` Phase 重整後回收，資源派遣的報告與核准交接產物直接同步至來源工作樹。

| 判定 | 成立條件 | 後續動作 |
| --- | --- | --- |
| 收下 | 產出落點檔案存在且非空，全部驗收條件逐條成立，且沒有任何未補驗的受阻或未執行條件 | Workflow `Developer` 先將成果套回來源工作樹且不建立 Phase commit，保留 dispatch worktree；Reviewer、需求意圖驗收與結案報告完成後，等待使用者授權 commit 再進入 Phase commit 回收。資源派遣同步報告與核准交接產物後結束 |
| 退回 | 任一驗收條件不成立，且原因屬純技術可解，例如格式不符、欄位缺漏或未執行第 5 欄命令 | 一般純技術補件依續 session 契約使用同一個 dispatch worktree resume，帶入未達成條件清單與下一個 `recovery-round`，自動續行且不詢問使用者。完成後回到 Developer 或 Reviewer 站點。額度不足時依 `ScopePlan` 的中止保全流程保存已取得的結論與證據，再由回收端判定是否重新建立 cold-start。 |
| 升級 | 原因命中 `instructions.md` §1.5 升級兩道篩的三類拍板判準，或命中共同收斂契約的停止訊號 | 停止派遣，保留 dispatch worktree 與證據，回報未閉合清單與替代方向，等待使用者選擇方向 |

回收判定成立且不需續 session 時，先完成事件流、thread id、last-message、報告與核准交接產物同步，再以 `pwsh scripts\Invoke-CodexDispatch.ps1 -Operation Cleanup` 執行資源派遣 worktree 清理。Workflow Developer dispatch worktree 僅在使用者授權 commit、Phase commit 回收與驗證完成後執行 `Cleanup`。`Cleanup` 失敗時保留 worktree，不得改用其他方式強制移除。派遣報告固定同步至 `sourceRoot\.local\ai-sessions\report\dispatch-report-<dispatchSlug>.md`，除非派遣單第 7 欄指定其他產出落點。

## 結案報告與臨時 Git 提醒

每次結案報告都要記錄 `gitOrigin` 與 marker 狀態。`gitOrigin=agent-created` 且 `sourceRoot\.local\ai-sessions\agent-created-git.marker` 仍存在時，報告加入下列資訊。

```text
臨時 Git 狀態：agent-created
marker：<sourceRoot>\.local\ai-sessions\agent-created-git.marker（仍存在）
清理提醒：提示使用者確認初版完成後，由使用者觸發臨時 Git 清理。
```

報告必須提示使用者觸發清理，Agent 不自行判定初版完成，也不執行 `.git` 清理。清理動作仍須重新讀取並驗證 marker 的 `schema`、`created-by` 與 `work-root`；marker 缺失、格式錯誤或路徑不一致時，報告標示拒絕清理並保留 `.git`。

`gitOrigin=existing` 時，報告記錄來源工作樹沿用既有 Git，且未建立 Agent marker。dispatch worktree 被移除不代表來源 `.git` 可被清理。臨時 Git 的 marker 狀態與清理提醒屬結案資訊，不能取代使用者觸發的清理流程。
