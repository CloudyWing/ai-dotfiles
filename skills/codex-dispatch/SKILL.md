---
name: codex-dispatch
description: 'Codex 派工機制：依派工類型建立執行契約、以 codex exec 啟動 Codex、背景等待、取證並回收結果。當需要發動 codex、撰寫派遣單或執行派遣回收判定時使用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Codex 派工機制

本 Skill 負責派工的執行機制。是否派工由 `instructions.md` §1.5 的路由規則判定，本 Skill 只處理指令、落點、等待、取證、續 session 與回收。

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

腳本依寫入面分流 `executionRoot`。`readonly` 固定使用隔離 worktree，`write` 只有在目標路徑包含既有 tracked 檔案時建立 worktree；只寫 Git ignored 範圍或全新輸出檔案的 `write` 直接使用 `sourceRoot`，輸出 `worktreeCreated=false`。直接寫入路徑仍須通過 sourceRoot 界線驗證。

需要 worktree 時，腳本在建立前固定 `baseSha`，以來源 `git diff HEAD --binary --no-ext-diff` 產生 tracked carry-in，並以 `git ls-files --others --exclude-standard` 取得未追蹤檔案。patch 與未追蹤檔案都在 dispatch worktree 套用或複製，路徑與目的檔案先通過根目錄界線檢查。套用或複製衝突時以非零結束碼停止並保留現況，不覆寫來源檔案。

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

重派時建立新的 dispatch worktree，並以 `git -C <舊 dispatchRoot> diff HEAD` 產出的 patch 將既有成果轉移至新 worktree，另以 `git -C <舊 dispatchRoot> ls-files --others --exclude-standard` 取得未追蹤檔案並逐一複製。不要嘗試修改 ACL。新 worktree 沿用同一個 `lineSlug`，`dispatchSlug` 另取未使用的名稱。轉移完成後，舊 worktree 依既有路徑檢查移除。

PID 記錄保留於來源工作樹的 `history`，不因 dispatch worktree 移除或 `scratch` 清理而刪除。PID 檔案是否存在不能單獨作為並行判定依據，必須合併 `work-root`、`line-slug`、`write-mode`、進程身分比對與完整進程樹或 process group 的存活狀態；wrapper 已結束但子進程仍存活時，不得判定為可並行啟動。不同 `lineSlug` 的存活記錄必須可同時存在且不互相阻塞。同一 `lineSlug` 下兩個 `readonly` 記錄同樣必須可同時存在。

## Phase commit 回收與驗證

Codex 端不建立 commit，因此 dispatch worktree 的 `HEAD` 在派工全程維持 `baseSha`，實作成果以未 commit 的工作區變更形式存在。回收的輸入是這份工作區差異，不是 commit 區間。

`Invoke-CodexDispatch.ps1 -Operation Collect` 取得 `git diff <baseSha>`、`git diff --cached` 與 `git ls-files --others --exclude-standard`，再合併成完整成果清單。回收前以合併後的檔案清單與結案報告「Phase 對照」節逐項核對，數量或路徑不符時腳本以非零結束碼停止並回報差異。已暫存變更與未追蹤新增檔案都必須出現在核對結果中。

差異取得後依結案報告「Phase 對照」節記載的逐 Phase 檔案清單分組。Phase commit 以 Phase 為單位回收，一個 Phase 一個 commit；`phaseCommits` 依 Phase 順序排列，commit 訊息依 `generate-commit` skill 產生。主 Agent 將各 Phase 的差異依序套用至來源分支並建立對應 commit，保留 Phase 的獨立語意。

「Phase 對照」節缺失時停止回收並依續 session 契約要求補齊。缺少該節時，主 Agent 只能看到一份混合全部 Phase 的差異，無從還原 Phase 邊界。

單一檔案橫跨兩個以上 Phase 時，該檔的差異歸入其最早出現的 Phase，並在回收回報中列出該檔與涉及的全部 Phase。

回收不將全部 Phase squash 成單一 commit，也不以 merge commit 取代 Phase commit。任何 commit 回收衝突都停止處理，保留 dispatch worktree、來源狀態與事件證據，交由後續裁決或續行。

Phase commit 回收完成後，依 `git-workflow` skill 的 `validationMode` 執行重整後驗證，再同步報告與核准交接產物，最後才移除 dispatch worktree。Architect、Reviewer 與其他資源派遣不產生 Phase commit，直接同步報告與核准交接產物。程式碼差異尚未完成回收前不得移除 worktree。

## 腳本介面與執行前提

本地 session 需能執行 `git` 與 `codex`。機械流程由 `scripts\Invoke-CodexDispatch.ps1` 統一承接，主 Agent 仍負責 F1 路由、profile 選擇、使用者確認、任務分類、回收三態與升級判定；腳本驗證 deep 週期位置、套用已選定的降級出口，並保存校準觀測。腳本只接受絕對路徑或可在已驗證根目錄內解析的目標路徑，並以 JSON 輸出結果。

| Operation | 主要參數 | 成功輸出 | 致命失敗 |
| --- | --- | --- | --- |
| `Preflight` | `SourceRoot`、`DispatchRoot`、`LineSlug`、`DispatchSlug`、`WriteMode`、`TargetPath[]` | `executionRoot`、`gitOrigin`、`baseSha`、`worktreeCreated`、`carryInManifest`、同線目錄、`pidCheck` | manifest、PID、Git、根目錄界線、worktree、patch 或檔案複製驗證失敗時 stderr 並 exit code 1 |
| `Start` | Preflight JSON 或 `ExecutionRoot`、`PromptPath`、`Profile`、`DeepRequestSource`、`SecondaryDaysToReset`、`SecondaryRemainingPercent`、`DowngradeInstruction`、Codex 父層選項 | `rootPid`、PID 記錄、事件流、stderr、last-message、thread id 路徑、實際參數、有效 profile、週期位置與降級狀態 | deep 主動提議未通過週期 gate、執行檔、工作目錄、啟動參數或根程序身分取得失敗時 stderr 並 exit code 1 |
| `Inspect` | `EventStreamPath`、`ProcessExitCode`、stderr、last-message、識別字、`Model`、`TaskType`、冷啟動／續行、派工前後快照 | `completed`、`turn.failed` 原因、最後一則 `agent_message`、`usage`、`outputValid`、`success`、校準紀錄路徑、分組樣本數與提議訊號 | JSONL 格式錯誤、必要輸入缺失或校準快照格式錯誤時 stderr 並 exit code 1 |
| `Collect` | `DispatchRoot`、`BaseSha`、`ReportPath[]` | tracked diff、staged diff、未追蹤檔案、合併清單與報告逐項核對結果 | 差異清單與結案報告不一致時 stderr 並 exit code 1，保留 worktree |

`Preflight` 的 `writeMode=readonly` 固定建立隔離 worktree。`writeMode=write` 只有 tracked 目標需要 worktree；ignored 或全新輸出直接回傳 `executionRoot=sourceRoot` 與 `worktreeCreated=false`。建立 worktree 時先固定 `baseSha`，再套用 tracked patch 與複製未追蹤檔案。腳本遇到衝突會停止，不以空清單或來源覆寫表示成功。

`Start` 會固定 `--cd`、`--sandbox`、`--profile`、`--add-dir`、`--search` 等父層選項的位置，再執行 `codex exec` 或同一 thread 的 `codex exec resume`。`--json`、`--output-last-message` 與 prompt 選項位於子命令之後。事件流、stderr、last-message、thread id 與 PID 記錄各自保存，啟動結果包含實際參數，供後續複核。

`Start` 收到 `DowngradeInstruction` 時固定改用預設檔位，並在派工 prompt 的副本加入降級指示。收到 `Profile=deep` 時必須指定 `DeepRequestSource`。`agent-proposal` 只在兩個 `secondary` gate 條件同時成立時啟動；`user-explicit` 不受該 gate 阻擋，但 prompt 與 JSON 輸出都保留週期位置和剩餘額度。

`Inspect` 逐行解析 JSONL。空白行略過；單行解析失敗時保存原文與行號，繼續解析其餘事件，讓完整事件流仍可供診斷，但只要存在壞行，`Inspect` 就以非零結束碼拒絕產出成功狀態。可解析且具備必要欄位的 `turn.failed` 或非零 process exit code 是派工證據中的失敗結果，腳本仍輸出 `success=false`；缺少事件、非空 `type`、必要的 `thread_id`、成功事件的 `usage`、最後一則 `agent_message` 或其他必要欄位時，`Inspect` operation 以非零結束。`outputValid=false` 只表示存在 final message 但該訊息缺少必要識別字。

`Inspect` 在提供 `sourceRoot` 或 `CalibrationPath` 時追加校準紀錄。紀錄使用 `<sourceRoot>\.local\ai-sessions\history\quota-calibration.jsonl`，分組鍵為 `model`、`profile`、冷啟動／續行，任務類型只保留為欄位。紀錄不足 5 筆時只回報觀測數量；達到 5 筆時只輸出由主 Agent 提議新門檻的訊號，腳本不修改規則。

`Collect` 合併 `git diff <baseSha>`、`git diff --cached` 與 `git ls-files --others --exclude-standard` 的檔案清單，再以結案報告「Phase 對照」節逐項比對。任一數量或路徑不一致都停止回收，且在程式碼差異尚未完成回收前不得移除 worktree。

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

`Start` 由腳本建立固定的工作目錄、父層選項、子命令選項與 prompt stdin。Windows 以進程樹根 PID 啟動並保存 `Win32_Process` 的名稱、父 PID 與建立時間；Unix 以 `setsid` 建立 process group。環境缺少必要執行檔、無法取得根程序身分或無法建立輸出路徑時，腳本以非零結束碼失敗，保留已寫入的 stderr 與事件路徑。

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
4. 回報格式、產出落點與驗收條件。Workflow 派工另須要求結案報告包含輪起點 SHA、開工基準線、「Phase 對照」節與「判定為既有實作而未動工」節。「Phase 對照」節逐 Phase 列出該 Phase 實際修改的檔案清單，供主 Agent 依 Phase 分組建立 commit。續 session 必須重述前輪這兩節的全部條目。

需要以結構約束結案報告時，另建立 JSON Schema 檔並加入 `--output-schema <FILE>`。該選項只約束最終回應的形狀，不改變事件流格式。

## 模型檔位規則

本 Skill 只使用預設檔位與 `deep`。預設檔位的實測基準標註為 `gpt-5.6-luna @ xhigh`。實際 model id 與其餘設定仍以 `~/.codex/<檔位名稱>.config.toml` 為準，規則層只傳遞語意檔位名稱。

`codex exec` 與 `codex exec resume` 屬 runtime command，接受 `--profile`。檔位以 `--profile <檔位名稱>` 傳遞，放在 `exec` 子命令之前。預設檔位省略 `--profile`，沿用 `~/.codex/config.toml`。

探針分兩種，證明範圍不同，不可互相取代。

| 探針 | 檔位 | 證明範圍 |
| --- | --- | --- |
| 機制探針 | 成本較低的獨立檔位 | 派工流程本身可運作，例如路徑、prompt 傳遞與事件流解析 |
| 正式參數探針 | 與本次派遣完全相同的檔位 | 本次啟動參數合法且該檔位可用 |

機制探針只在驗證流程改動時使用，不能代替正式參數探針。正式派工前一律執行正式參數探針；以 `deep` 派工時，該探針同樣使用 `deep`，其消耗計入本次派遣。低成本檔位的名稱與內容由使用者提供，規則層不預設其存在。

版本探針只證明 CLI 可執行，不證明本次啟動參數合法。`--help` 在參數驗證前短路輸出，也不具正式參數證明力。正式參數探針必須沿用本次派遣完整的父層選項與檔位；腳本的 `Start` 輸出實際參數與證據路徑，供呼叫端執行及核對該探針，不能以機制探針的成功取代正式參數探針。

`deep` 僅適用於推理密集且執行量不大的工作，例如需要自行找路、探索未知相依性或處理步驟未明確的多步驟問題。例行編輯、操作步驟完整的任務、單一命令驗證與單純文件整理使用預設檔位。

執行量大但步驟明確的任務即使規模龐大也使用預設檔位。`deep` 改變的是模型與推理設定，不是讀寫與命令執行的吞吐，用在大量執行類工作只會拉高消耗而不改變結果。

`deep` 相對預設檔位的實際差異由兩份設定檔的差集決定，不由本文件斷言。判定任務是否值得升級前，先讀取 `~/.codex/deep.config.toml` 與 `~/.codex/config.toml`，比對兩者的 `model`、`model_reasoning_effort` 與其餘鍵，再據此說明升級能帶來什麼。

### deep 的前置準備

預設檔位的實測基準為 `gpt-5.6-luna @ xhigh`。`deep` 的實測成本基準為一小時即可用完整個 `primary` 5 小時視窗。這項數據只用來說明週期位置風險，不直接取代依分組累積的校準門檻。

降低成本的方式是減少執行端自行探索的讀取量，不是縮小任務範圍。檔位本身的成本特性由本機檔位設定決定，配置方式見 README 的 Codex profile 檔位設定章節。

派工前完成下列準備。準備不足時 `deep` 會把額度花在自行摸索目標物件，而不是產出結論。

- 派遣單第 3 欄逐一列出目標物件的絕對路徑，不使用目錄萬用字元，避免執行端自行決定讀取範圍。
- prompt 明列已知結論、已讀過的檔案與不需重讀的部分，讓執行端直接進入判斷。
- 需要限制讀取量時，在 prompt 明文要求單一 agent 執行並說明理由。執行端派生 subagent 時每個 subagent 各自消耗額度，讀取量隨並行數累加。
- 額度不足以支撐完整任務時，在 prompt 加入降級指示：要求先寫出已確認的結果並註明實際覆蓋範圍，不要在零產出的情況下中斷。實測該指示可使中斷的派遣仍交付部分成果。

本機檔位設定調整後，冷啟動的消耗結構隨之改變，前述門檻應依調整後的實測值重新校準，不沿用調整前的數據。

續行同一 thread 的輸入快取狀態與冷啟動不同，因此續行與冷啟動必須分組校準。續行必須沿用初始啟動的完整父層選項，包含 `--profile`，跨檔位續行不成立；以預設檔位冷啟動後改用 `deep` 續行會同時違反續行契約，不採用。

### 額度快照

主 Agent 從 `<CODEX_HOME>/sessions/<yyyy>/<MM>/<dd>/rollout-<時間戳>-<thread-id>.jsonl` 讀取 session 記錄。額度資料位於 `payload.rate_limits`，必須同時取得 `primary` 與 `secondary` 視窗。每個視窗使用 `used_percent`、`window_minutes` 與 `resets_at`，其中 `used_percent` 為數值百分比、`window_minutes` 為分鐘數，`resets_at` 為 Unix timestamp（秒）。剩餘額度百分比為 `100 - used_percent`，`window_days` 為 `window_minutes / 1440`。

主 Agent 每次派工前呼叫 `~/.ai-agents/scripts/Get-CodexQuota.ps1` 取得快照。腳本掃描最近 20 個 rollout 檔，對每個視窗先捨棄格式無效、`resets_at` 已過期、事件時間不在自身視窗內的候選，再依事件時間由早到晚比較相鄰的有效候選。若較晚候選的 `used_percent` 低於較早候選，且兩筆事件之間尚未跨過較早候選的 `resets_at`，則將較晚事件視為帳號切換跳變點，作廢該視窗跳變點之前的候選。完成跳變失效化後，從剩下的有效候選依額度事件自身的時間選取最新候選，同檔內以 record index 由新到舊決勝。不得改用 `resets_at` 最大值挑選候選，週視窗重新錨定時 `resets_at` 會往回跳，取最大值會淘汰當日全部記錄並鎖死在舊快照。任一視窗沒有有效候選時，腳本以非零結束碼回報錯誤，不輸出估算值。

快照必須落在目前的 `primary` 視窗內才可用於檔位判定。`resets_at` 位於未來只證明該視窗尚未重設，不證明 `used_percent` 反映目前用量：一筆數天前的 rollout，其 `secondary.resets_at` 仍可能在未來而被選為有效候選，但它記錄的是當時的累積值，不含之後的全部消耗。兩個視窗由所有檔位共用，不依模型分別計量。快照的失準來源是消耗速率而非歸屬：`deep` 單次派遣可能在數十分鐘內耗盡整個 `primary` 視窗，使派工當下的剩餘百分比無法代表派遣全程可用的額度。

判定前逐一確認兩個視窗的來源檔時間距今都不超過各自的 `window_minutes`，即任一視窗的快照都不得比該視窗更舊。只驗證 `primary` 時，`primary` 在 5 小時內而 `secondary` 已數天未更新的組合會通過檢查，使 `secondary_remaining_percent` 採用過期值。任一視窗不滿足時視為快照過期，停止需要額度判定的派工，並回報該視窗的來源檔名與其時間。不以 `primary_resets_at` 減 `primary_window_minutes` 反推視窗起點再比對，該算式在記錄寫入時間落在視窗邊界前後數秒時會判定為過期。

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

`Inspect` 預設唯讀。未提供 `sourceRoot` 與 `CalibrationPath` 時不寫入 `quota-calibration.jsonl`；只有明確提供其中一個校準落點時才追加校準紀錄。

兩個視窗的門檻不同，且依檔位分別設定。

| 檔位 | `primary` 門檻 | `secondary` 門檻 |
| --- | --- | --- |
| 預設 | 30% | 15% |
| `deep` 冷啟動 | 60% | 15% |
| `deep` 續行 | 30% | 15% |

預設檔位與 `deep` 的門檻依 `model`、`profile`、冷啟動／續行分組校準。上表是目前規則值，只有在同一分組累積至少 5 筆觀測後，主 Agent 才能提出新門檻；使用者確認後才可修改規則。

`deep` 的實際消耗依模型與派工方式而異。設定檔更換模型後，既有實測值只能作為歷史觀測，不能直接套用到新的分組。

1. 主 Agent 先判斷任務是否推理密集且執行量不大，判準是需要自行找路、探索未知相依性或處理步驟未明確的多步驟問題，且不以大量讀寫、掃描或命令執行為主體。
2. 主 Agent 主動提議 `deep` 時，兩個視窗的剩餘額度必須達到上表對應門檻，且 `secondary_days_to_reset <= 2`、`secondary_remaining_percent >= 40`。任一週期條件不成立時，不提出 `deep` 確認。
3. 使用者明示要求 `deep` 時，週期位置 gate 不阻擋派遣，但主 Agent 必須先告知 `secondary_days_to_reset`、`secondary_remaining_percent` 與一小時即可用完整個 `primary` 5 小時視窗的實測成本基準。
4. 主動提議符合條件時，依「升級確認」節向使用者提出確認。取得當輪明確同意後才加入 `--profile deep`；未取得同意時使用預設檔位。週期位置 gate 與使用者明示要求是兩條分開處理的路徑。
5. 低於目標 profile 門檻但快照有效時，一律省略 `--profile`，使用預設檔位，並在 prompt 加入下列降級指示。請先交付已確認的結果，明確標明實際覆蓋範圍；即使額度不足，也不得在零產出的情況下中斷。
6. 額度腳本失敗、輸出缺少任一視窗欄位或 `deep.config.toml` 不存在時，停止需要額度判定的派工，不使用估算值或隱式 profile fallback。
7. 預設檔位省略 `--profile`。檔位名稱只允許預設與 `deep` 的語意集合，臨時驗證檔位不進入派工判定。

每次派遣結束時，`Invoke-CodexDispatch.ps1 -Operation Inspect` 追加一筆 `<sourceRoot>\.local\ai-sessions\history\quota-calibration.jsonl`。紀錄至少包含 `model`、`profile`、冷啟動／續行、任務類型、`turn.completed.usage`、派工前後的 `primary` 與 `secondary` 快照，以及完成、失敗與實際輸出結果。校準分組鍵只有 `model`、`profile`、冷啟動／續行，任務類型只作紀錄欄位。樣本少於 5 筆時只保留觀測紀錄；達到 5 筆時輸出供主 Agent 判讀的提議訊號，腳本不修改門檻，也不輸出自動更新值。

### 決策歸屬

檔位由主 Agent 於派工當下決定。主 Agent 必須保留兩個視窗的剩餘額度與任務難度判定，供回報與後續複核使用。

### 升級確認

`deep` 一律經使用者確認後才使用，不自動升級。理由是冷啟動的 `deep` 派工可能耗盡整個 `primary` 視窗，等同用掉該視窗全部派工餘裕，這個取捨屬於使用者的資源分配決定。確認請求必須明白告知本次派遣可能耗盡當前視窗，不只列出剩餘百分比。

額度與任務條件皆成立時，主 Agent 在派工前輸出單行確認請求，格式如下。

```text
[deep 升級確認] primary 剩餘 <n>%、secondary 剩餘 <n>%；<需要 deep 的具體理由>。是否升級？
```

理由必須指出該任務的推理密集點與執行量判斷，例如「根因橫跨三個模組且無既有測試可定位，讀寫量小」。只寫「任務較難」或「需要深入分析」不構成理由。

使用者未回覆或未明確同意時，以預設檔位派工，不等待也不重複詢問。

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
| `finalMessage` | `--output-last-message` 指定的檔案內容；該檔缺失或為空時，改取事件流中最後一則 `item.type` 為 `agent_message` 的 `text` |
| `completed` | 事件流最後一則事件的 `type` 是否為 `turn.completed` |
| `usage` | `turn.completed` 的 `usage` 物件，作為本次實際消耗記錄 |
| `outputValid` | 最後訊息是否同時包含派遣單絕對路徑、`dispatchSlug` 與 `lineSlug` |
| `exitCode` | process 結束碼 |
| `stderr` | stderr 檔案完整內容 |

`--output-last-message` 由 CLI 直接寫檔，比從事件流反推更可靠，因此列為 `finalMessage` 的第一來源。事件流沒有最後的 `agent_message` 時，`Inspect` 以非零結束碼停止；只有已取得 final message 但識別字不完整時才輸出 `outputValid=false`。

`usage` 只作為事後記錄與額度對照，不取代派工前的額度快照判定。

`finalMessage` 一律保留在 `history` 的 last-message 檔，不寫入報告落點。

執行角色已在派遣單第 7 欄與其規則檔指定的落點寫入報告，該檔是驗收對象。回收端若把結案摘要寫進同一路徑，會在驗收前覆蓋角色產出的完整報告。Workflow 派工的 `reportLineRoot\implement-closure-report.md` 同樣由 `Developer` 自行寫入，回收端只讀取與驗收。

報告落點檔案不存在或為空時，依回收三態的「退回」處理，要求角色補齊，不以 `finalMessage` 代寫。

## 續 session 與跨介面接手

若需要補齊欄位或修正純技術驗收問題，先從 `codex-thread-<dispatchSlug>.txt` 讀取 `thread_id`，再以 `codex exec resume` 續行。續 session 沿用同一個 `dispatchRoot`、sandbox 邊界、`LineContext`、檔位與 PID 身分驗證規則。

續行的父層選項必須與初始啟動完全相同，包含 `--profile`、`--add-dir` 與 `--search`。這組選項從初始啟動記錄重建，不依當下判斷重新推導；任一項缺漏都會改變檔位、寫入權限或網路能力，使續行的執行條件與前一輪不一致。

`Start` 以 `ResumeThreadId` 讀取指定 `thread_id` 後建立續行命令，重新產生事件流與 stderr 檔案，不覆寫前一輪記錄。續行的父層選項從初始啟動結果重建，包含 `--profile`、`--add-dir` 與 `--search`。

`exec resume` 的 session 識別接受 `thread_id` 或 thread 名稱，UUID 優先解析。省略識別並改用 `--last` 會選取最近一次記錄的 session，該行為依賴本機記錄狀態而非本次派遣的識別，因此派工流程一律明列 `thread_id`，不使用 `--last`。

續行 prompt 仍來自 scratch 檔案並以 `-` 從 stdin 傳入，內容必須重述同一組 `LineContext`、`dispatchRoot`、檔位與父層選項，列出前輪「驗證證據」及「Phase 對照」的既有條目，並逐項附上未達成條件清單。已完成的條件不得以摘要取代，續行只補齊明列的缺漏。

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
| 結案要求 | 「驗證證據」節的輪起點 SHA 與開工基準線皆有值，且「Phase 對照」節逐 Phase 列出修改的檔案清單 | 先通過 `RecoveryPrecheck`，再逐條執行派遣單第 5 欄的命令並得出「收下」、「退回」或「升級」之一 |

`requirement-summary.md` 是跨派遣的持久交接檔，固定於 `sourceLineRoot\requirement-summary.md`；覆寫前備份固定於 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>`。這兩個來源落點不屬於 `dispatchRoot` 的派遣產出，資源派遣若需寫入它們，必須在 `exec` 子命令前以 `--add-dir` 分別授權來源線層 `handoff` 與 `history` 目錄。

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
| 8 | 回報必備欄位 | Codex 端回報必須逐條列出第 5 欄命令原文、完整 stdout、完整 stderr、exit code、執行時間與判定結果 |

第 5 欄格式如下。

```markdown
| # | 驗收條件 | Codex 命令 |
| --- | --- | --- |
| <n> | `<absolute-path>` 存在且非空 | `Get-Item -LiteralPath '<absolute-path>'` |
| <n> | 內容含指定欄位 | `rg -n '<pattern>' '<absolute-path>'` |
```

建置與測試由主 Agent 自行執行，不列為 Codex 第 5 欄的命令輸出責任。

複核政策唯一：主 Agent 逐條核對 Codex 回報的命令原文與輸出是否支持其判定結論，這是核對而非重新執行。只有在輸出與結論不一致、輸出缺漏，或回報只寫「已完成」而無命令輸出時，才實際重跑該條命令。不整套重跑全部條件。

回收覆核的外部事實查證由主 Agent 負責。主 Agent 可在回收階段使用可用的上網工具查證派遣報告涉及的版本、規格、官方行為或其他驗收必要事實。派遣報告的自述不取代查證，查證也不取代第 5 欄命令輸出。每筆查證證據必須保留查詢內容、來源連結、查證時間、相關原始輸出或摘錄，以及支持或不支持驗收結論的判定，寫入回收報告或同線查證證據。來源不足、查證失敗或結果矛盾時，標示未驗證並交由回收三態處理，不得以推測補足。

## RecoveryPrecheck

事件流取證後，先從符合目前派工類型的 `agent_message` 取最後一則結案訊息。識別字依派工類型判定，兩種類型都必須包含 `dispatchSlug` 與 `lineSlug`，第三項識別字如下。

| 派工類型 | 第三項識別字 |
| --- | --- |
| Workflow 派工 | `dispatchLineRoot\design.md` 的絕對路徑 |
| 資源派遣 | 派遣單的絕對路徑 |

Workflow 派工沒有派遣單，以派遣單絕對路徑作為共同條件會使正常結案一律被判為 `PromptNotDelivered` 並重派。缺少任一識別字時，狀態設為 `PromptNotDelivered`，修正啟動方式後重新派遣；此狀態不計入退回次數，也不進入第 5 欄驗收缺漏的退回計數。只有 `RecoveryPrecheck` 通過後，才可進入回收三態判定。

## 回收三態判定

背景指令結束後，主 Agent 先執行 `RecoveryPrecheck`，再讀取 dispatch worktree 內派遣單第 7 欄的產出落點，依第 5 欄逐條核對。核對與重跑的分界見上節的複核政策。主 Agent 不以 Codex 端回報中的自述取代實際判定。派遣單第 8 欄必須要求 Codex 端逐條回報每條驗收條件的命令原文與完整 stdout、完整 stderr、exit code 與執行時間。主 Agent 以抽驗方式複核回報內容，對輸出與結論不一致的條件只重跑該條命令。回報只寫「已完成」而未附命令輸出者，該條計為未成立。

Codex 端不建立 commit。Workflow `Developer` 的機械 commit 由主 Agent 依 `design.md` Phase 重整後回收，資源派遣的報告與核准交接產物直接同步至來源工作樹。

| 判定 | 成立條件 | 後續動作 |
| --- | --- | --- |
| 收下 | 產出落點檔案存在且非空，全部驗收條件逐條成立 | 同步報告與核准交接產物；Workflow `Developer` 進入 Phase commit 回收，資源派遣結束 |
| 退回 | 任一驗收條件不成立，且原因屬純技術可解，例如格式不符、欄位缺漏或未執行第 5 欄命令 | 依續 session 契約使用同一個 dispatch worktree resume，附未達成條件清單。退回上限 2 次；`PromptNotDelivered` 不計入此上限 |
| 升級 | 原因命中 `instructions.md` §1.5 升級兩道篩的三類拍板判準，或退回已達 2 次仍不成立 | 保留 dispatch worktree 與證據，停止派遣，依「遇真問題全停」升級使用者拍板 |

回收判定成立且不需續 session 時，先完成事件流、thread id、last-message、報告與核准交接產物同步，再依 Git 前置探針的路徑檢查移除 dispatch worktree。派遣報告固定同步至 `sourceRoot\.local\ai-sessions\report\dispatch-report-<dispatchSlug>.md`，除非派遣單第 7 欄指定其他產出落點。

## 結案報告與臨時 Git 提醒

每次結案報告都要記錄 `gitOrigin` 與 marker 狀態。`gitOrigin=agent-created` 且 `sourceRoot\.local\ai-sessions\agent-created-git.marker` 仍存在時，報告加入下列資訊。

```text
臨時 Git 狀態：agent-created
marker：<sourceRoot>\.local\ai-sessions\agent-created-git.marker（仍存在）
清理提醒：提示使用者確認初版完成後，由使用者觸發臨時 Git 清理。
```

報告必須提示使用者觸發清理，Agent 不自行判定初版完成，也不執行 `.git` 清理。清理動作仍須重新讀取並驗證 marker 的 `schema`、`created-by` 與 `work-root`；marker 缺失、格式錯誤或路徑不一致時，報告標示拒絕清理並保留 `.git`。

`gitOrigin=existing` 時，報告記錄來源工作樹沿用既有 Git，且未建立 Agent marker。dispatch worktree 被移除不代表來源 `.git` 可被清理。臨時 Git 的 marker 狀態與清理提醒屬結案資訊，不能取代使用者觸發的清理流程。
