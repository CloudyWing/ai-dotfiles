# Codex 派工機制：回收與清理

本檔收錄 Inspect 之後的回收判定、執行端共用作業、Phase commit、Cleanup 與結案報告。入口與其他階段的檔案見 `../SKILL.md`「階段路由」。

## 已結束歷史派遣的 Cleanup 接手

不同 Session 對已確定結束的派遣執行 Cleanup 或 Collect 時，owner 不符會自動驗證終態並記錄接手。證明須同時具備最後一筆 terminal 事件、可信退出 sidecar 與 PID 三鍵確認程序已結束。驗證未通過時維持 `DispatchAdmissionOwnerMismatch`；Cleanup 另可使用明示接手，`DispatchAdmissionOwnerUnverifiable` 維持既有處理。

```powershell
pwsh -NoProfile -File .\scripts\Invoke-CodexDispatch.ps1 -Operation Cleanup -RequestPath <既有CleanupRequest> -TakeoverOwner
```

保留真實 `CallerSessionId` 與既有 Request 欄位。`TakeoverOwner` 僅適用於 Cleanup，其他 operation 回報 `CleanupTakeoverOperationInvalid`。相同 owner 仍走原流程，`owner_takeover.used=false`。

接手在來源 admission lock 內驗證全部 RunRecord 的 identity、hash 與續行鏈。已啟動 run 須有最後 `turn.completed` 或 `turn.failed`，以及同 run 的已知退出 sidecar；舊 run 僅接受通過 identity/hash 驗證且退出來源可信的 Inspect。未啟動 run 須通過 `unstarted-sandbox` 與既有未啟動證明。prepared、unknown、缺少可信終態或只有程序不存在時，保留 worktree。

PID 三鍵、程序樹與 ledger 稽核須確認程序已結束或原 PID 已重用。程序查詢被拒、仍有 root/child 或身分不明時維持拒絕。報告與全部 evidence 依位元組保存、長度及 SHA-256 回讀後，在 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>\cleanup-takeover-<dispatchSlug>-<attemptGuid>.json` 原子保存接手者、原 owner、UTC 時間、終態及程序證據、保存清單與 hash。

稽核依序為 `validated`、`preserved`、`completed`，失敗盡力記 `failed`。移除前重驗 run 集合、證據 hash、PID 與 inventory，漂移或保存／稽核失敗均保留 worktree。移除後稽核更新失敗回報 `CleanupTakeoverAuditFinalizeFailed` 與 `worktree_removed=true`，以 preserved 稽核及 cleanup-result 恢復。`cleanup-result.owner_takeover` 保存是否使用接手、稽核路徑及 SHA-256；歷史 owner fingerprint 維持原值。每次重試重新驗證，舊稽核只作證據。

Collect 自動接手在套回前寫入 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>\collect-takeover-<dispatchSlug>-<attemptGuid>.json`。稽核寫入失敗時停止套回；`sourceIntegration.owner_takeover` 記錄稽核路徑與 SHA-256。

## Phase commit 回收與驗證

Codex 端不建立 commit，因此 dispatch worktree 的 `HEAD` 在派工全程維持 `baseSha`，實作成果以未 commit 的工作區變更形式存在。回收的輸入是這份工作區差異，不是 commit 區間。

本節的 Workflow Developer 回收屬 `DispatchKind=workflow` 機制，規則層目前沒有呼叫端；Workflow Phase 由 Claude 執行者承接時的回收與 Phase commit 見 `workflow-orchestration` skill「Claude 實作路徑」。保留本機制時，Workflow Developer 的回收收下與 Phase commit 回收是兩個時點。Developer 回收判定為收下時，主 Agent 先將成果套回來源工作樹，維持未 commit 的工作區變更，不建立 Phase commit，並保留 dispatch worktree。Reviewer 退回時，續行仍使用同一個 dispatch worktree 與 thread。只有在 Reviewer 收下、需求意圖驗收完成、結案報告產出且使用者授權 commit 後，才進入 Phase commit 回收。

`Invoke-CodexDispatch.ps1 -Operation Collect` 依 `Preflight` 的 `worktreeCreated` 分流回收。`true` 時取得 `git diff <baseSha>`、`git diff --cached` 與 `git ls-files --others --exclude-standard`，再合併成完整成果清單。`false` 時不要求 `DispatchRoot` 或 `BaseSha`，改從 Preflight 的 `targetStates` 逐一核對核准輸出檔案，保存非空檔案的長度、最後寫入時間與 SHA-256 證據。direct-write 的結案報告也必須存在且非空。任何必要欄位、檔案證據或報告核對失敗時，腳本以非零結束碼停止，不把空 `baseSha` 當成 Git 基準。

Collect 在開始處檢核參數。`DispatchKind`、`ReportPath`，以及 `-ApplyCollectedChanges` 模式下的 `SourceRoot` 缺少時，錯誤碼為 `RequiredParameterMissing`。路徑參數必須是完整路徑，`C:relative.md` 這類磁碟機相對路徑也會被拒；只有路徑問題時錯誤碼為 `CollectParameterInvalidPath`。錯誤訊息逐列寫出參數名、問題與收到的值，結果的 `parameter_issues` 保存同一份清單。

差異取得後依結案報告「Phase 對照」節記載的逐 Phase 檔案清單分組。Phase commit 以 Phase 為單位回收，一個 Phase 一個 commit；`phaseCommits` 依 Phase 順序排列，commit 訊息依 `generate-commit` skill 產生。主 Agent 將各 Phase 的差異依序套用至來源分支並建立對應 commit，保留 Phase 的獨立語意。來源分支是符合 `git-workflow` 註記模式的線分支或整合分支。

「Phase 對照」節缺失時停止回收並依續 session 契約要求補齊。缺少該節時，主 Agent 只能看到一份混合全部 Phase 的差異，無從還原 Phase 邊界。

單一檔案橫跨兩個以上 Phase 時，該檔的差異歸入其最早出現的 Phase，並在回收回報中列出該檔與涉及的全部 Phase。

Claude 執行者承接的 Phase 不經本檔的 Collect 與 dispatch worktree。其檔案清單取自結案報告「Phase 對照」節，主 Agent 依 `design.md` 的 Phase 宣告順序逐 Phase 暫存指名路徑並建立 commit，沒有 dispatch worktree，不呼叫 `Cleanup`。核對與回收步驟見 `workflow-orchestration` skill「Claude 實作路徑」。

Phase 回收步驟維持一個 Phase 一個 commit，不以 merge commit 取代 Phase commit，也不在此步驟把全部 Phase squash 成單一 commit。Phase commit 回收完成並通過驗證後，依 `git-workflow` 註記模式規定的整理時機執行該 skill 的「整理流程」。每筆整理後的 commit 必須通過可用性驗證，並通過 `git-workflow` 第一層零差異 gate。任何 commit 回收衝突都停止處理，保留 dispatch worktree、來源狀態與事件證據，交由後續裁決或續行。

Phase commit 回收完成後，依 `git-workflow` skill 的「重整後驗證」節執行驗證，再同步報告與核准交接產物，最後才以 `pwsh scripts\Invoke-CodexDispatch.ps1 -Operation Cleanup` 移除 Workflow Developer dispatch worktree。Reviewer 與其他資源派遣不產生 Phase commit，直接同步報告與核准交接產物後即可呼叫相同的 `Cleanup` operation。`Cleanup` 失敗時保留 dispatch worktree，不得改用其他方式強制移除。使用者授權 commit 前不得執行 Workflow Developer dispatch worktree 的 `Cleanup`。

## 執行端共用作業

本節由角色規則檔引用。角色規則檔決定哪些產出套用哪一項作業，本節只規定作業步驟。引用本節的角色無法讀取本節時，停止寫入並回報缺件，不略過該作業。

### 覆寫前備份

適用於角色規則檔指定需保留前版的固定產出，例如 `design.md`、需求摘要與同線固定報告。依下列順序執行，備份不需詢問使用者確認。

1. 確認目標檔案是否存在。不存在時直接寫入新內容，不建立備份。
2. 確認 `<work-root>\.local\ai-sessions\history\<lineSlug>\` 存在，不存在時建立。
3. 將既有檔案改名為 `<原檔名>.<yyyyMMdd_HHmmss>` 並移入該目錄，時間戳取備份當下時間。同名備份已存在時停止並回報，不覆寫既有備份。
4. 確認備份檔存在後，才寫入新內容。

`lineSlug` 必須與同線 `line.json` 的 `line-slug` 一致。`history` 位於來源工作樹時，Codex 執行端需要啟動命令以 `--add-dir` 授權來源 `history\<lineSlug>\`。

### 共同基準與主張反證比對

適用於檢查產出者成果的角色，例如 Reviewer 與 Frontend Reviewer，以及主 Agent 的回收覆核。角色的獨立判斷順序（例如 Reviewer 的行為型判定）由角色規則檔定義，本節規定比對時的基準與記錄方式。

1. 使用與產出者相同的需求基準。實讀派遣單第 4 欄或派工 prompt 指定的 `requirement-summary.md`、`design.md` 與派遣單，在報告記錄各檔的絕對路徑與 SHA-256。基準檔與產出者引用的版本不同時，先回報版本差異，不以任一方的轉述代替原文。
2. 取得原始證據。判定依據引用檔案絕對路徑與行號，並附不超過三行的原文摘錄；命令證據附命令原文與原始輸出。轉述與摘要不作為判定依據。
3. 逐項比對產出者的具體主張。對產出者報告中與驗收有關的每一項主張記錄四欄：主張原文、主張引用的來源、支持或反駁的原始摘錄、檢查過的可能反證。主張沒有引用來源時記為「無來源」，不代為補找來源後視為成立。
4. 歸因爭議先核對可辨別事實的來源，例如 commit、檔案雜湊、命令輸出或事件流，再判斷原因；事實來源無法取得時記為未確認，不依多數意見或使用者同意定案。
5. 判定與產出者結論不同時，在報告保留雙方主張、來源與反證，交由回收三態或升級判定處理。

### Finding 編號與前輪對照

適用於產出 finding 的審查角色，例如 Reviewer、Frontend Reviewer 與 Contract Auditor。本節規定編號與前輪對照的共同步驟；finding 的分類、報告區段格式與 Reviewer manifest 由各角色規則檔定義。編號延續與停止判定的共同定義為 `instructions.md` §1.5 共同收斂契約的 `problem-key`，審查循環的 `problem-key` 即 finding ID。

1. 每項 finding 以 `F-<三位數>` 編號，自 `F-001` 起遞增。角色規則檔允許以其他識別承載者（例如 Reviewer 以 T-code 承載 Spec 判定）依該角色規定。
2. 派遣單第 4 欄或續行 prompt 列出同一角色的前輪報告時，先實讀前輪全部 finding ID 與各 ID 的前輪結束狀態。前輪報告讀取失敗時停止並回報缺件，不以本輪觀察推測前輪狀態。
3. 對前輪每個 ID 逐一判定「已閉合」「未閉合」「撤回」或「已接受殘餘風險」，引用目前檔案的位置作為依據。撤回須附撤回理由，不得把撤回推論為已閉合。只有派遣單第 4 欄、前輪報告或同線 `exceptions.md` 提供 Analyst 或使用者的明確裁決時，才可判定為已接受殘餘風險，並附裁決者、適用範圍與重新開啟條件。
4. 未閉合的前輪 finding 沿用原 ID 與原嚴重度；嚴重度變更時註明理由。同一問題不得以新措辭另開 ID。
5. 本輪新發現的 finding 自前輪最大編號之後接續編號，不重用已出現過的 ID。
6. 有前輪報告時，報告在「總覽」之後列出前輪 finding 狀態，每個前輪 ID 一列。

停止判定依共同收斂契約。同一 finding ID 連續兩輪未閉合，或同一區域連續兩輪出現新的 `Major` 以上 finding 時停止，保留證據並提出替代方向，不以更換 ID 規避計數。角色規則檔明定不備份的產出（例如 Reviewer 依派遣單覆寫的報告檔）不套用本節。以腳本或批次指令改寫既有檔案的備份另依 `instructions.md` §1.4「腳本改寫安全」，存入 `backups\<時間戳>\`，與本節的逐檔改名備份用途不同。

## 回收三態判定

背景指令結束後，主 Agent 先執行 `RecoveryPrecheck`，再讀取 dispatch worktree 內派遣單第 7 欄的產出落點，依第 5 欄逐條核對。核對與重跑的分界見上節的複核政策。主 Agent 不以 Codex 端回報中的自述取代實際判定。派遣單第 8 欄必須要求 Codex 端逐條回報每條驗收條件的命令原文與完整 stdout、完整 stderr、exit code 與執行時間。主 Agent 以抽驗方式複核回報內容，對輸出與結論不一致的條件只重跑該條命令。回報只寫「已完成」而未附命令輸出者，該條計為未成立。

標示為受阻或未執行的條件一律計為未成立，不因回報語氣看似無礙而放行。主 Agent 對每條受阻條件與每條未執行條件執行補驗，補驗結果取代原判定並將該條狀態改記為已補驗；補驗不可行時該條維持未成立。全部驗收條件成立的判定必須建立在「已執行且通過」與「已補驗且通過」兩種狀態之上，不得包含任何未補驗的受阻或未執行條件。

Codex 端不建立 commit。Workflow `Developer` 的機械 commit 由主 Agent 依 `design.md` Phase 重整後回收，資源派遣的報告與核准交接產物直接同步至來源工作樹。

| 判定 | 成立條件 | 後續動作 |
| --- | --- | --- |
| 收下 | 產出落點檔案存在且非空，全部驗收條件逐條成立，且沒有任何未補驗的受阻或未執行條件 | Workflow `Developer` 先將成果套回來源工作樹且不建立 Phase commit，保留 dispatch worktree；Reviewer、需求意圖驗收與結案報告完成後，等待使用者授權 commit 再進入 Phase commit 回收。資源派遣同步報告與核准交接產物後結束 |
| 退回 | 任一驗收條件不成立，且原因屬純技術可解，例如格式不符、欄位缺漏或未執行第 5 欄命令 | 一般純技術補件依續 session 契約使用同一個 dispatch worktree resume，帶入未達成條件清單與下一個 `recovery-round`，自動續行且不詢問使用者。完成後回到 Developer 或 Reviewer 站點。額度不足時依 `ScopePlan` 的中止保全流程保存已取得的結論與證據，再由回收端判定是否重新建立 cold-start。 |
| 升級 | 原因命中 `instructions.md` §1.5 升級兩道篩的三類拍板判準，或命中共同收斂契約的停止訊號 | 停止派遣，保留 dispatch worktree 與證據，回報未閉合清單與替代方向，等待使用者選擇方向 |

收下後仍有殘餘工作時，依 `instructions.md` 的「派工後的殘餘工作」判定處置，紀錄與環境成因的處理見本節末「派工後的殘餘工作」。

回收判定成立且不需續 session 時，先完成事件流、thread id、last-message、報告與核准交接產物同步，再以 `pwsh scripts\Invoke-CodexDispatch.ps1 -Operation Cleanup` 執行資源派遣 worktree 清理。Workflow Developer dispatch worktree 僅在使用者授權 commit、Phase commit 回收與驗證完成後執行 `Cleanup`。`Cleanup` 依 `SourceRoot\.local\ai-sessions\history\<lineSlug>\runs\<dispatchSlug>` 驗證 RunRecord 路徑與 line／dispatch／source／execution owner，RunRecord 留在 SourceRoot history，不列入 worktree 檔案保存清單。省略 `EvidencePath` 時採用 RunRecord 引用且位於 dispatch worktree 的既存證據；明列未引用檔案時拒絕並列出可接受清單。RunRecord 或 evidence 路徑越界、owner 不符、保存清單驗證失敗或 worktree 移除失敗時保留 worktree 並回報錯誤。不得改用其他方式強制移除。report 根目錄的 `dispatch-report-<dispatchSlug>.md` 一律同步至來源 report 根目錄，不依賴 `ReportPath` 是否列出；其他未列入保存清單的 report 檔案會阻止移除 worktree。

### 派工後的殘餘工作

判定順序與使用者拍板條文見 `instructions.md`「派工後的殘餘工作」，本節補充紀錄與處置細節。

- 環境成因例示：sandbox 無法還原套件、缺外部前置條件、權限不足。
- 改派對象：依登錄表選出的其他執行者。Codex 執行端的帳號由腳本自動更換；Dispatch 回報 `CodexAccountsAllUnavailable` 時依 `instructions.md`「離線改派」由選派入口回傳承接者。改派不屬補做，改派承接記為 exceptions「替代方案」。
- 補做紀錄：完成補做的主 Agent 追加 exceptions「派工後補做」，固定四欄填寫如下。
  - 內容：補做範圍（檔案、行數、驗證命令）與來源 `dispatchSlug`。
  - 依據：派工端無法完成的原因，以及小型修改例外四項的實測值（檔案數、行數、命令數）。
  - 位置：檔案與行號或 T-code。
- 重跑不計：回收覆核重跑既載命令、對照輸出與結論，不計入補做、不記錄。任何寫入改動即屬殘餘工作收尾，依 `instructions.md` 的判定順序判定並記錄；只讀重跑不算補做。

### 覆核取證助手

需實讀的來源量大到會持續留在主 Agent context 時，主 Agent 可派生冷啟動的 Claude subagent 作為覆核取證助手（`model` 見 `instructions.md`「Claude 端 sub-agent 模型指定」）。

- 輸入：同線 `lineSlug`、待核對的驗收條件原文、相關的已確定實作約束原文、證據與來源的絕對路徑。未落檔的語意不交給助手推斷，缺件時由主 Agent 補齊後再派生。
- 回傳：逐條列出條件、來源位置、支持或反駁結論的原始摘錄與缺漏項目。只回判定而無摘錄的回傳視為未完成。
- 判定：收下、退回與升級仍由主 Agent 依摘錄逐條決定，摘錄不足或矛盾時主 Agent 針對該條實讀來源。助手不取代 Reviewer 的獨立審查與 Analyst 的需求意圖裁決。

## 值班通知

回收判定為派工機制缺陷時，回收派遣的 Session 通知本機值班 Session，讓同一缺陷集中登記與修正。派工機制缺陷指派工腳本、Skill 條文或範本與實際行為不符；額度耗盡、服務端拒絕、使用者環境限制與執行端自身的任務錯誤不發通知。

本機設定位於 `~/.ai-agents/.local/machine.json`，不進版控。檔案不存在時不發通知，回收照常進行。

```json
{
  "schema": "ai-agents.machine.v1",
  "machine_id": "home",
  "duty_session_name": "duty-home",
  "maintenance_writer": true,
  "writer_duty_session_name": "duty-home"
}
```

| 欄位 | 內容 |
| --- | --- |
| `machine_id` | 本機識別，寫入通知的發生機器欄位 |
| `duty_session_name` | 本機值班 Session 的名稱，即跨 Session 訊息的收件者 |
| `maintenance_writer` | 本機是否為唯一修改並 push `.ai-agents` 的修改端；缺少時視為 `false`。兩台機器的設定中只有一台為 `true` |
| `writer_duty_session_name` | 修改端的值班 Session 名稱，非修改端轉送時使用 |

發送步驟如下：

1. 先完成回收判定並保存證據，再發送通知。
2. 以 `ListAgents` 確認 `duty_session_name` 存在，再以 `SendMessage` 發送。名稱不存在或發送失敗時不改送其他 Session，在回收報告記錄「值班通知未送達」，由下一個接手的 Session 補發。
3. 訊息第一行固定為 `[派工問題回報]`，其後逐行列出必備欄位。

| 必備欄位 | 內容 |
| --- | --- |
| 發生機器 | `machine_id` |
| 專案路徑 | `sourceRoot` 絕對路徑 |
| `lineSlug`、`dispatchSlug` | 發生缺陷的派遣識別 |
| 錯誤碼 | 腳本錯誤碼；沒有錯誤碼時寫問題的短識別 |
| 現象 | 一至三句，說明預期與實際行為 |
| 證據 | 證據檔絕對路徑，另附可獨立閱讀的原文摘錄 |
| 已做處置 | 繞道方式或「無」 |
| 未完成事項 | 仍受阻的工作或「無」 |

值班通知不構成使用者授權，也不屬於協調 Session 轉述；轉述授權的判定依 `instructions.md` §1.5「授權期限」。值班 Session 的收件、登記與分派依 `agents/codex/maintainer.toml`「值班收件」。

## 保存契約對照

Cleanup 驗證同一 dispatchSlug 的所有 RunRecord，保存各輪位於 worktree 的引用證據。無 Preflight result 與 RunRecord 時，依 U1 至 U4 的從未啟動判定處理，條件與稽核見 `recovery.md`「失敗與恢復導引」。移除 worktree 失敗後重試時，經身分驗證的 removal receipt 可證明已保存且目的檔雜湊相符的缺失來源檔。

派工產物的保存責任依下表。只有表中列出的建立者與更新者可以寫入該項；更新欄為「無」的項目建立後不再修改。回收端只做表中列出的處理，不代為補寫內容。

`Cleanup` 保存檔案時以位元組複製，並比對來源與 destination 的位元組長度與 SHA-256，兩者任一不一致即停止，不要求檔案內容為 UTF-8。非 UTF-8 的報告與日誌（例如 Windows 主控台以本機碼頁輸出的 stderr）可原樣保存，不會因解碼失敗而停在 worktree。固定報告 `exceptions.md` 的合併仍以 UTF-8 解碼，內容不是 UTF-8 時以錯誤停止。

| 保存項目 | 落點 | 建立者 | 更新者 | 回收端的處理 | 詳細節 |
| --- | --- | --- | --- | --- | --- |
| 事件流、stderr | `executionRoot` 的 `history\`，worktree 派遣為 dispatch worktree，direct-write 為來源工作樹；RunRecord 以 `event_stream_path` 與選填 `error_stream_path` 引用事件流及 stderr 的絕對路徑 | `Start` 在啟動前建立空檔；啟動失敗且檔案缺失時補建空檔 | `Start` 產生的 launcher 把 Codex 的標準輸出與標準錯誤重導寫入 | `Inspect` 以 FileStream 與 `FileShare.ReadWrite`、`FileShare.Delete` 共享讀取事件流及 last-message，維持讀取前後雜湊核對；worktree 派遣由 `Cleanup` 依 RunRecord 保存事件流與 stderr 回來源。舊 RunRecord 未記錄 `error_stream_path` 時仍可讀取與清理 | 事件流取證、完成判定與三出口 |
| last-message | 同事件流 | `Start` 啟動的 Codex 程序（`--output-last-message`） | 同建立者 | `Inspect` 只用於與事件流 finalMessage 比對；worktree 派遣由 `Cleanup` 保存回來源 | 事件流取證、完成判定與三出口 |
| thread id | 同事件流 | `Start` 在事件流出現 `thread.started` 且檔案空白時寫入 | 無；續行只讀取比對 | worktree 派遣由 `Cleanup` 保存回來源 | 續 session 與跨介面接手 |
| RunRecord | 來源 `history\<lineSlug>\runs\<dispatchSlug>\` | `Start`，目的已存在時拒絕 | `Start` 在 prompt 傳遞、啟動完成與啟動失敗時更新；`Inspect` 在事件流中斷時更新 `unknown_interruption`。皆為原子寫入 | 只讀；`Cleanup` 依其驗證路徑與 owner，不列入 worktree 保存清單 | 回收三態判定 |
| failure receipt | Request 的 `failure_receipt_path`，可位於來源同線 `history\` 或 dispatch worktree 的同線 `history\` | `Dispatch` 在建立 worktree 後寫入 `pending`，或在外層例外與續行的 `Inspect` 失敗時寫入 `failed` | `Dispatch` 成功啟動後更新為 `superseded`；同一路徑的後一次寫入取代前一次，依 `status` 判讀 | `Start` 驗證未啟動證明時讀取；`Cleanup` 的從未啟動判定可讀取符合條件的 pending／failed 收據。位於來源時原地保留，位於 dispatch worktree 時不在 `Cleanup` 保存清單，需保留時由主 Agent 在 `Cleanup` 前讀取 | 回收三態判定 |
| 未啟動 Cleanup 稽核 | 來源 `history\<lineSlug>\cleanup-unstarted-<dispatchSlug>-<attemptId>.json` | `Cleanup` 的從未啟動判定放行後寫入 `validated` | `Cleanup` 在保存、移除或失敗時更新狀態 | 留在來源同線 `history\`，不列入 worktree 保存清單 | 失敗與恢復導引 |
| 中斷保全紀錄 | `executionRoot` 的 `history\<lineSlug>\interruption-checkpoint-<dispatchSlug>-<runId>.json`，worktree 派遣為 dispatch worktree，direct-write 為來源工作樹；RunRecord 的 `interruption_checkpoint_path` 為路徑權威。不可寫時以結案訊息中的中斷保全三行交付，位置在識別字三行之前 | `Start` 建立全數未完成的初始檔，並把絕對路徑寫入 prompt | 執行端每完成一個單位以原子寫入更新 | `Inspect`、`Collect` 讀取並回傳已確認單位、未完成單位與證據位置，不回寫該檔，仍接受舊派遣記錄的來源路徑；worktree 派遣由 `Cleanup` 保存回來源同線 `history`。未執行單位不產生結論 | InterruptionSafeguard |
| Developer 結案報告 | dispatch worktree 的 `report\<lineSlug>\` | 執行端（Workflow 為 Developer）；Request 的 `prepare_artifacts` 列入來源既有報告時，`Prepare` 建立執行端副本 | 同建立者 | `Collect` 與 Reviewer 只讀；`Cleanup` 依固定報告版本規則保存，無法判定新舊時封存 worktree 版本並保留來源版本 | 結案報告與 Git 來源紀錄 |
| 協調者結案報告（需要你決定、已自行處理、僅供知悉三區） | 來源 `report\<lineSlug>\` | 主 Agent 判定內容並寫入 | 同建立者 | 不經派工回收；執行端不寫入此檔 | `instructions.md` §1.4 結案報告 |
| advisor 諮詢報告 | `executionRoot` 的 `report\<lineSlug>\advisor-consult-<dispatchSlug>.md` | `advisor-consult` 的 `Inspect`，依事件流與 last-message 產生 | 同建立者；每次 `Inspect` 覆寫 | 主 Agent 讀取後決定是否採用；`Cleanup` 保存回來源，來源已有不同內容時以目的衝突停止。advisor 執行端不寫入 | Advisor consult resource dispatch |
| 派遣報告與角色固定報告 | 派遣單第 7 欄落點、角色規則檔指定的同線固定報告 | 執行端；Request 的 `prepare_artifacts` 列入來源既有報告時，`Prepare` 建立執行端副本 | 同建立者；Reviewer 直接覆寫，Frontend Reviewer 與 Contract Auditor 先把前版移入 `history\` 再寫新版 | `Cleanup` 保存 report 根目錄的派遣報告及 `review-report`、`frontend-reviewer-report`、`contract-auditor-report`、`implement-closure-report`、`support-engineer-report`、`cleanup-review` 固定報告。以 RunRecord 啟動時間或 manifest round 判斷新舊並封存另一份；版本不明時後三者封存 worktree 版本並保留來源，前三者保留 worktree 並回報錯誤 | 派遣單契約 |
| 同線 `exceptions.md` | `report\<lineSlug>\exceptions.md` | 第一個需要記錄的執行端或主 Agent；Request 的 `prepare_artifacts` 列入來源既有檔時，`Prepare` 建立執行端副本 | 執行端與主 Agent 只追加；`Cleanup` 把 worktree 新增的區塊合入來源後以原子取代寫回 | 保留來源既有區塊；worktree 區塊與來源區塊全文相同時不附加，worktree 內重複區塊只附加一次。同標題但內文不同視為不同條目；兩邊標題前內容只含 H1 與空白時相容，來源前文維持不變，其他不一致時停止 | 回收三態判定 |
| 成果檔案 | dispatch worktree 或 direct-write 目標 | 執行端；Preflight 把來源既有的核准 target 檔帶入 worktree，不覆寫既有檔 | 執行端；`Collect -ApplyCollectedChanges` 套回來源；Workflow 由主 Agent 在使用者授權後 commit | Start 時不存在的核准 target 檔案以 baseline `exists=false` 記錄，回收清單保留該路徑，包含被 gitignore 排除的核准新檔；`Collect -ApplyCollectedChanges` 依來源 drift 檢查套回，新檔搬入、既有檔原子取代、刪除先備份，失敗時倒序回復。核准目錄新增且未被 gitignore 排除的子檔（包含 Start 時不存在的核准目錄）以 add 套回並檢查來源 drift；target 外新增檔列於 `unappliedNewFiles` 並留在 worktree。資源派遣同步核准的交接產物。direct-write 目錄 target 逐檔回傳證據且至少一檔非空 | Phase commit 回收與驗證 |
| 套回帳冊 | 來源 `history\<lineSlug>\collect-apply-ledger.json` | `Collect -ApplyCollectedChanges` 在 admission lock 內建立 | 同建立者只追加每次套回的路徑狀態與雜湊 | Preflight 依同線帳冊與來源雜湊辨識 `LineProducedFiles`；Collect 依同 dispatchSlug 的最新套回狀態檢查來源 drift。帳冊無效時停止套回，寫入失敗時回復已套用的檔案 | Phase commit 回收與驗證 |
| RunRecord 引用的執行證據：ScopePlan、launcher、prompt 傳遞副本與加上指示的 prompt、退出 sidecar、PrepareResult、Dispatch 階段結果、Inspect 結果綁定，以及 advisor evidence pack 的 SHA-256 與 length sidecar | `executionRoot` 的 `history\` | 產生該證據的 operation：PrepareResult 由 `Prepare`、階段結果由 `Dispatch`、其餘由 `Start` 與其 launcher | PrepareResult 由 `Prepare` 依狀態更新；Inspect 結果綁定由 `Inspect`；其餘無 | worktree 派遣由 `Cleanup` 驗證同一 dispatchSlug 的所有 RunRecord，並保存各輪引用的證據回來源。advisor evidence pack 的 `.sha256` 與 `.length` sidecar 由既有 `evidence_pack_path`、`execution_root` 與 `dispatch_slug` 推導 Start 寫入的 `history\evidence-pack-<dispatchSlug>.sha256`、`.length` 路徑，沿用路徑邊界驗證後保存；未新增 RunRecord 欄位 | 事件流取證、完成判定與三出口 |
| prompt 原始來源 | 呼叫端指定的 `PromptPath`，可位於來源工作樹或 `executionRoot` | 呼叫端（主 Agent 或撰寫 Request 者） | 無；`Start` 只讀取並建立傳遞副本 | RunRecord 記錄原始路徑；位於 dispatch worktree 時由 `Cleanup` 保存回來源，位於來源時原地保留 | Prompt 必備元素 |
| Dispatch result | Request 的 `result_path`；省略時為 `executionRoot` 的 `history\<lineSlug>\dispatch-result-<dispatchSlug>-<token>.json` | `Dispatch` | `Dispatch` 在提前回傳、Inspect 結束與例外三條路徑寫入同一路徑 | 主 Agent 讀取 Preflight、Prepare 結果路徑與階段結果；預設落點不在 `Cleanup` 保存清單，需保留時由主 Agent 在 `Cleanup` 前讀取 | Dispatch 正式入口 |
| 來源控制紀錄：ScopePlan hash、admission ledger、套回帳冊、PID 記錄、baseline、review finding ledger、cleanup result | 來源 `history\` 或 `history\<lineSlug>\` | ScopePlan hash、PID 記錄由 `Start`；baseline 由 Preflight；admission ledger 由第一次 admission 檢查；套回帳冊及 finding ledger 由 `Collect`；cleanup result 由 `Cleanup` | ScopePlan hash、PID 記錄與 baseline 無；admission ledger 由 Preflight、`Start` 與 `Cleanup` 的 admission 檢查；其餘由各自建立者 | 留在來源，不經 worktree 保存 | Caller Session 身分與併行准入 |

## 結案報告與 Git 來源紀錄

每次結案報告都要記錄 `gitOrigin`。`existing` 表示沿用來源既有的 Git，`not-applicable` 表示非 Git 來源的 direct-write 或唯讀派工，不使用 Git 基準。dispatch worktree 被移除不代表來源 `.git` 可被清理，Agent 不清理來源的 `.git`。

舊版腳本曾在非 Git 來源自動建立臨時 Git，其 RunRecord 或 Preflight 結果可能含 `gitOrigin=agent-created` 與 `markerPath`。現行腳本把這兩個欄位視為歷史資料照常讀取，不依其分流；報告如實記錄，是否移除該 `.git` 由使用者決定。
