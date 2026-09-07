---
name: codex-dispatch
description: 'Codex 派工機制：依派工類型建立執行契約、以 codex exec 啟動 Codex、背景等待、取證並回收結果。當需要發動 codex、撰寫派遣單或執行派遣回收判定時使用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Codex 派工機制

本 Skill 負責派工的執行機制。是否派工由 `instructions.md` §1.5 的路由規則判定，本 Skill 只處理指令、落點、等待、取證、續 session 與回收。

## Git 前置探針與 worktree 生命週期

所有派遣先建立 `DispatchPreflight`。每次派遣必須取得上游傳入且已驗證的 `LineContext`。`lineSlug` 識別同一條 Analyst 線，`dispatchSlug` 識別單次 dispatch worktree，兩者分屬不同名稱空間。缺少 `LineContext`、`lineSlug` 不符合 `^[a-z0-9]+(?:-[a-z0-9]+)*$`，或 `line.json` 的 `line-slug` 與傳入值不一致時，停止於 PID 與 Git 前置流程之前，不建立預設線或以 `dispatchSlug` 代替。

| 欄位 | 路徑或用途 |
| --- | --- |
| `sourceRoot` | 使用者指定且已解析的 work-root 絕對路徑 |
| `lineSlug` | Analyst 已登記的語意化線識別 |
| `writeMode` | 本次派遣的寫入模式，派遣單第 6 欄標示「唯讀」時為 `readonly`，其餘為 `write` |
| `sourceLineRoot` | `<sourceRoot>\.local\ai-sessions\handoff\<lineSlug>` |
| `dispatchRoot` | `<sourceRoot>\.local\ai-sessions\worktrees\<dispatchSlug>` |
| `dispatchLineRoot` | `<dispatchRoot>\.local\ai-sessions\handoff\<lineSlug>` |
| `sourceReportLineRoot` | `<sourceRoot>\.local\ai-sessions\report\<lineSlug>` |
| `reportLineRoot` | `<dispatchRoot>\.local\ai-sessions\report\<lineSlug>` |

`DispatchPreflight` 讀取 `<sourceLineRoot>\line.json`，確認 `schema=ai-sessions.line.v1` 與 `line-slug=<lineSlug>` 後，才建立 dispatch worktree 與同線目錄。`dispatchSlug` 只使用小寫英數與連字號，且在同一個 `sourceRoot` 內不得重複。PID 並行檢查先於 Git 前置流程執行，檢查通過後才可啟動派工。

前置流程依下列順序執行。

1. 解析 `sourceRoot`、`dispatchRoot`、`sourceLineRoot`、`dispatchLineRoot`、`sourceReportLineRoot` 與 `reportLineRoot` 的絕對路徑，確認 `dispatchSlug` 與 `lineSlug` 均符合 `^[a-z0-9]+(?:-[a-z0-9]+)*$`。
2. 讀取 `<sourceLineRoot>\line.json`，確認其 `schema` 與 `line-slug`。manifest 缺失、格式錯誤或歸屬不一致時停止派遣；既有但缺少 manifest 的目錄視為已被占用，不建立或覆寫它。
3. 掃描 PID 記錄，以 `sourceRoot`、`lineSlug` 與 `writeMode` 執行三鍵並行檢查。不同 `lineSlug` 的活躍記錄不阻塞派遣。`writeMode` 取自派遣單第 6 欄，第 6 欄標示「唯讀」時為 `readonly`，其餘為 `write`。
4. 在 `sourceRoot` 執行 `git -C <sourceRoot> rev-parse --is-inside-work-tree`。
   - 以 exit code 為主要分流依據。只有 exit code 為 0 且 stdout 為 `true` 時，才設定 `gitOrigin=existing`，保留既有 Git，不建立 marker。
   - work-root 不在 Git 工作樹時，命令會以非零 exit code 與 `fatal` 錯誤結束，不會輸出 `false`；不能等待 `false` 作為分流結果。
   - 命令因 work-root 不在 Git 工作樹而失敗時，先告知使用者將在該目錄建立臨時 `.git`，再進入臨時 Git 流程。
   - Git 執行檔不存在或回傳其他 Git 錯誤時，停止並回報原始錯誤，不把錯誤當成可初始化的目錄。
5. 臨時 Git 流程先呼叫 `generate-gitignore-by-techstack`。範本取不到時，先告知使用者，再寫入最小內建清單 `bin/`、`obj/`、`node_modules/`、`.env` 與 `.local/`。
   Fallback 完成後不停止派工，流程繼續執行。
6. 以 `.gitignore` 過濾建置輸出、機密檔案與 `.local/` 後執行 `git init`，建立一筆僅供派工使用的初始機械 commit。初始 commit 失敗時停止後續派工並保留現況。
7. 臨時 Git 建立成功後，在 `sourceRoot\.local\ai-sessions\agent-created-git.marker` 寫入 UTF-8 無 BOM 的純文字 key-value 內容。至少包含下列欄位。

   ```text
   schema=codex-dispatch.temp-git.v1
   created-by=codex-dispatch
   work-root=<sourceRoot 的絕對路徑>
   created-at-utc=<ISO 8601 UTC 時間>
   ```

marker 是來源工作樹的控制資料，不納入初始 commit。marker 寫入失敗時停止後續派工並保留已建立的 `.git`；marker 缺失時不得刪除 `.git`。此流程的 `gitOrigin` 設為 `agent-created`，`markerPath` 設為 marker 的絕對路徑。

8. 在 `sourceRoot\.local\ai-sessions\worktrees\<dispatchSlug>` 執行 `git worktree add --detach <dispatchRoot> <baseSha>`。`baseSha` 是 Git 探針完成後記錄的來源 `HEAD`，必須在 worktree 建立前固定。
9. 在 `dispatchRoot` 建立 `.local\ai-sessions\handoff`、`report`、`history` 與 `scratch`，並建立 `dispatchLineRoot` 與 `reportLineRoot`。建立來源 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>` 與 `sourceReportLineRoot` 後，將 `<sourceLineRoot>` 的 `line.json`、`requirement-summary.md` 與派遣所需的 `design.md` 複製至 `dispatchLineRoot`。需求摘要的正本與覆寫前備份維持來源寫入模式；Codex 的有效工作目錄與本次派遣產出的同線 report、history、scratch 及一次性 handoff 產物使用 `dispatchRoot`。
10. Codex 結束後，先確認回收判定成立，再將事件流、thread id、last-message、派遣報告與核准的一次性交接產物同步回 `sourceRoot` 的同相對路徑。同線設計文件從 `dispatchLineRoot` 同步至 `sourceLineRoot`，固定報告從 `reportLineRoot` 同步至 `sourceReportLineRoot`。需求摘要與其覆寫前備份固定寫入 `sourceLineRoot` 與 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>`，不透過 dispatch worktree 回收；需要這類來源寫入的派遣必須以 `--add-dir` 明確授權這兩個線層目錄。
   - Architect、Reviewer 與其他資源派遣直接同步報告與允許的交接產物，不透過 commit 回收。
   - Workflow `Developer` 回收 dispatch worktree 的工作區差異，依結案報告「Phase 對照」節分組後建立 Phase commit。Phase 回收規則由 `git-workflow` skill 定義。
11. 完成同步後，確認 `dispatchRoot` 的實際絕對路徑仍位於 `sourceRoot\.local\ai-sessions\worktrees\<dispatchSlug>`，再執行 `git worktree remove --force <dispatchRoot>`。三態尚未結束或需要續 session 時保留同一個 dispatch worktree。

臨時 Git 保留在 `sourceRoot`，直到使用者明確觸發清理。清理前讀取並驗證 marker 的 `schema`、`created-by` 與 `work-root`。marker 不存在、格式錯誤或 `work-root` 與目前絕對路徑不一致時，拒絕刪除 `.git` 並回報原因。驗證成功且收到使用者清理指令後，才可刪除舊 `.git`、重新 `git init`、建立乾淨的 initial commit，成功後移除 marker。

主工作樹在 Codex 執行期間維持啟動前的 `HEAD` 與 `git status`。Codex 的 `--cd` 固定指向 `dispatchRoot`，不得以 `sourceRoot` 作為執行目錄。需求摘要及其 history 備份是跨派遣交接例外，仍寫入 `sourceLineRoot` 與 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>`；需由 Codex 寫入時，`--add-dir` 只授權這兩個線層目錄。

## Codex 進程 PID 與並行檢查

PID 記錄歸屬來源工作樹的 `history`，格式為 `<sourceRoot>\.local\ai-sessions\history\codex-pid-<yyyyMMdd_HHmmss>.txt`。記錄中的 `pid` 是進程樹根，不代表一定是 Codex leaf process。Windows 以 PowerShell 的 `ProcessStartInfo` 啟動 `(Get-Command codex.cmd).Source` 時，實測 `Process.Id` 為 `35048`，查詢該 PID 的 `ProcessName` 得到 `cmd`，不是 `codex` 或 `node`；實際執行 Codex 的程序是其子進程。因此 Windows 端必須以根 PID 追查整個進程樹。

每次成功啟動 Codex 並取得進程識別碼後，立即建立一份新的 UTF-8 無 BOM 純文字檔，至少包含下列欄位。`pid` 保留作為相容欄位，值與 `root-pid` 相同。

```text
pid=<進程樹根 PID，與 root-pid 相同>
root-pid=<進程樹根 PID>
root-process-name=<根程序名稱，例如 cmd>
root-parent-pid=<根程序的 ParentProcessId>
root-started-at-utc=<ISO 8601 UTC 時間>
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

Windows 以 `Win32_Process` 的 `ProcessId`、`ParentProcessId`、`Name` 與 `CreationDate` 查詢根程序及其所有後代，遞迴追查每一層子程序。將查得根程序的 `Name` 與 `CreationDate` 轉為 UTC 後，分別比對 PID 記錄的 `root-process-name` 與 `root-started-at-utc`。名稱採不分大小寫的完全相等比對，建立時間差距容許最多 1 秒，以涵蓋查詢與記錄序列化的時鐘精度差異；兩項必須同時符合。任一項不符或無法查詢時，判定為 PID 重用，該筆記錄不阻塞派工，也不把其目前後代視為同一個 Codex 進程樹。根程序已結束但仍有後代時，只有在根 PID 目前不存在且未發現 PID 重用的情況下，才可依 `ParentProcessId` 鏈保留活躍判定。根 PID 已被其他程序占用且身分不符時，依 PID 重用處理。Unix 以 PID 檔的 `process-group-id` 查詢 process group 成員，並以 `root-pid` 查詢根程序，依相同規則比對 `root-process-name`、`root-started-at-utc` 與查得的程序名稱、建立時間。根程序身分比對通過且群組內仍有任何程序存活時，才判定為活躍實例。根程序在身分驗證後結束但群組成員仍存活時，沿用已驗證的根程序身分與仍存在的 `process-group-id` 判定活躍；根 PID 被其他程序占用、身分比對失敗或無法完成身分驗證時，判定為 PID 重用，該筆記錄不阻塞派工。舊格式 PID 記錄若缺少 `root-process-name` 或 `root-started-at-utc`，視為無法確認身分的歷史記錄，不阻塞派工。理由是僅憑 PID、process group 或存活狀態無法排除 PID 重用。歷史進程樹已完全結束時不阻塞派工；發現依 `write-mode` 判定為衝突的同線活躍 Codex 實例時，回報活躍 PID 記錄檔、根 PID 與存活後代或 process group，停止流程。

`write-mode` 判定分三種結果。既有記錄與本次派遣都是 `readonly` 時互不阻塞，理由是唯讀派遣不修改目標物件，各自只寫入派遣單第 7 欄指定的報告檔，沒有共用寫入面。任一方為 `write` 時阻塞。同線同時活躍的 `readonly` 實例上限為 2，已達上限時停止派遣並等待既有實例結束，理由是回收端為單線，超過兩份同線報告會使統籌端的判定塞車。缺少 `write-mode` 的舊格式記錄一律視為 `write`。

中斷或重派前只讀取 `work-root`、`line-slug` 與 `dispatch-slug` 三者均匹配本次派遣的 PID 記錄，再解析 `root-pid`（舊格式使用 `pid`）。同線允許並行時，`dispatch-slug` 是區分同線多個活躍實例的唯一依據；缺少 `dispatch-slug` 的舊格式記錄不得作為終止對象。Windows 執行任何 `taskkill` 前，必須先以 `Win32_Process` 查詢根程序，確認查得的 `Name` 與 `CreationDate` 分別符合 `root-process-name` 與 `root-started-at-utc`，名稱不分大小寫完全相等且建立時間差距不超過 1 秒。兩項身分比對通過後，才可執行 `taskkill /PID <root-pid> /T /F`，由系統終止根程序及整個後代樹。若根程序已先結束，先以 `Win32_Process.ParentProcessId` 找出仍存活的後代，並沿用已通過的根程序身分驗證確認其仍屬同一進程樹，再對每個仍存活的樹根執行 `taskkill /PID <descendant-pid> /T /F`，直到重新查詢不到任何後代。根 PID 被其他程序占用、身分比對失敗或舊格式缺少任一身分欄位時，判定為 PID 重用或無法確認身分，不得執行 `taskkill`，以免終止重用該 PID 的無關程序。Unix 執行 `kill -TERM -- -<process-group-id>` 前，同樣必須先完成根程序名稱與建立時間的身分比對，再確認 `process-group-id` 仍屬於該已驗證的 process group；比對失敗或無法完成比對時不得執行任何 `kill`。若依中斷策略需要強制收尾，僅對同一個已驗證的 process group 使用 `kill -KILL -- -<process-group-id>`。終止後再次以進程樹或 process group 查詢確認全部程序已結束。只終止 PID 檔記錄的單一進程或包裝 Codex 的 shell 不符合本契約。

**被強制終止過的 dispatch worktree 不得重用（Crucial）**。sandbox helper 在正常結束時才移除自己套用的 ACL；被 `taskkill` 或 session 中止時來不及清理，worktree 根目錄會殘留一條明確（非繼承）的存取控制項目，其 SID 已無對應帳號。之後在該目錄啟動的 Codex 會在套用 sandbox ACL 時失敗，全程無法執行任何命令。以 `icacls <dispatchRoot>` 與來源工作樹比對即可確認：報廢的 worktree 會多出不帶 `(I)` 標記的條目。

重派時建立新的 dispatch worktree，並以 `git -C <舊 dispatchRoot> diff` 產出的 patch 將既有成果轉移至新 worktree，不要嘗試修改 ACL。新 worktree 沿用同一個 `lineSlug`，`dispatchSlug` 另取未使用的名稱。轉移完成後，舊 worktree 依既有路徑檢查移除。

PID 記錄保留於來源工作樹的 `history`，不因 dispatch worktree 移除或 `scratch` 清理而刪除。PID 檔案是否存在不能單獨作為並行判定依據，必須合併 `work-root`、`line-slug`、`write-mode`、進程身分比對與完整進程樹或 process group 的存活狀態；wrapper 已結束但子進程仍存活時，不得判定為可並行啟動。不同 `lineSlug` 的存活記錄必須可同時存在且不互相阻塞。同一 `lineSlug` 下兩個 `readonly` 記錄同樣必須可同時存在。

## Phase commit 回收與驗證

Codex 端不建立 commit，因此 dispatch worktree 的 `HEAD` 在派工全程維持 `baseSha`，實作成果以未 commit 的工作區變更形式存在。回收的輸入是這份工作區差異，不是 commit 區間。

主 Agent 以 `git -C <dispatchRoot> diff` 取得工作區差異，依結案報告「Phase 對照」節記載的逐 Phase 檔案清單分組。Phase commit 以 Phase 為單位回收，一個 Phase 一個 commit；`phaseCommits` 依 Phase 順序排列，commit 訊息依 `generate-commit` skill 產生。主 Agent 將各 Phase 的差異依序套用至來源分支並建立對應 commit，保留 Phase 的獨立語意。

「Phase 對照」節缺失時停止回收並依續 session 契約要求補齊。缺少該節時，主 Agent 只能看到一份混合全部 Phase 的差異，無從還原 Phase 邊界。

單一檔案橫跨兩個以上 Phase 時，該檔的差異歸入其最早出現的 Phase，並在回收回報中列出該檔與涉及的全部 Phase。

回收不將全部 Phase squash 成單一 commit，也不以 merge commit 取代 Phase commit。任何 commit 回收衝突都停止處理，保留 dispatch worktree、來源狀態與事件證據，交由後續裁決或續行。

Phase commit 回收完成後，依 `git-workflow` skill 的 `validationMode` 執行重整後驗證，再同步報告與核准交接產物，最後才移除 dispatch worktree。Architect、Reviewer 與其他資源派遣不產生 Phase commit，直接同步報告與核准交接產物。

## 執行前提與可用性檢查

派工前確認目前 session 能執行本地命令。Windows 先以 `Get-Command codex.cmd -ErrorAction SilentlyContinue` 解析 PATH 上的實體命令，將結果保存為 `codexPath`，再以該路徑取得版本。版本或探針失敗時停止派工，回報原始錯誤與結束碼。

```powershell
$codexCommand = Get-Command codex.cmd -ErrorAction SilentlyContinue
if ($null -eq $codexCommand) {
  throw "codex.cmd was not found on PATH."
}
$codexPath = $codexCommand.Source
$versionOutput = (& $codexPath --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
  throw "codex --version failed with exit code $LASTEXITCODE. Output: $versionOutput"
}
```

版本檢查只證明 CLI 可執行，不證明本次啟動參數合法。`--help` 在參數驗證之前就短路輸出，同樣不具驗證力。參數合法性由啟動探針負責：以本次派遣的完整父層選項加上一個極短 prompt 執行 `codex exec`，確認事件流出現 `turn.completed`。探針與正式啟動必須使用同一組父層選項，否則探針不具驗證力。

```powershell
$probeOutput = (& $codexPath --cd $dispatchRoot --sandbox workspace-write @profileOption exec --json "Reply with exactly: PONG" 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $probeOutput -notmatch '"type"\s*:\s*"turn\.completed"') {
  throw "codex exec probe failed with exit code $LASTEXITCODE. Output: $probeOutput"
}
```

| Session 型態 | 派工能力 | 處置 |
| --- | --- | --- |
| Desktop Code tab、VS Code 擴充、CLI、SSH 或 WSL 的 local session | 可發動 | 依本 Skill 的指令契約執行 |
| Dispatch 對話本身或 cloud session | 不可發動 | 明確回報「當前 session 不載入全域規則，請於 local Code session 發動」，不嘗試執行 `codex` |
| Dispatch 派生的 local Code session | 可發動 | 依本 Skill 的指令契約執行 |

派工命令執行前由主 Agent 準備 `sourceLineRoot`、`<sourceRoot>\.local\ai-sessions\history\<lineSlug>`、`sourceReportLineRoot`、`dispatchLineRoot`、`reportLineRoot`，以及 `dispatchRoot\.local\ai-sessions\history` 與 `scratch`。來源 `sourceLineRoot\requirement-summary.md` 與同線來源 `history` 的覆寫備份保存跨派遣交接；事件流、stderr、thread id 與 PID 記錄維持在既有的 `history` 根目錄；固定報告與例外紀錄落在 `reportLineRoot`。資源派遣若需更新來源需求摘要或其 history 備份，啟動命令必須以 `--add-dir` 授權這兩個來源線層目錄。報告檔與 `<work-root>/.local/ai-sessions/report/<lineSlug>/exceptions.md` 依派遣契約的明文寫入例外處理。若主 Agent 無法完成前置作業，停止啟動並回報缺件。所有輸出父目錄必須在啟動前完成建立。

## 指令契約

正式啟動使用 `codex exec`，沿用既有 session 使用 `codex exec resume`。`sourceRoot`、`dispatchRoot`、`dispatchSlug`、`lineSlug` 與各輸出檔案路徑都使用絕對路徑；`dispatchRoot` 固定為 `<sourceRoot>\.local\ai-sessions\worktrees\<dispatchSlug>`。事件流、stderr、thread id 與 last-message 檔名使用時間戳。

### 參數位置（Crucial）

`--cd`、`--sandbox`、`--add-dir`、`--search` 與 `--profile` 是 `codex` 的父層選項，必須放在 `exec` 或 `exec resume` 之前。`--json`、`--output-last-message` 與 `--output-schema` 是執行子命令的選項，放在子命令之後。位置放錯時 CLI 以 `unexpected argument` 拒絕啟動，錯誤只出現在 stderr。

`--search` 只有在需求明確需要網路查證時才加入。`--add-dir` 只有在需求明確需要 worktree 外寫入時才加入，並列出絕對路徑。

### Prompt 傳遞

一般派工的 Codex 工作目錄固定為 `dispatchRoot`。主 Agent 先建立 prompt scratch 檔，再以 `-` 作為 prompt 參數並將 scratch 的完整內容寫入標準輸入。`-` 是 Codex 從 stdin 讀取 prompt 的指示，直接寫入 stdin 可保留完整多行內容。

PowerShell 不可將未處理的 prompt 直接放入 `Start-Process -ArgumentList`，該參數會把陣列重新組合成單一命令列字串，內容中的引號、空白與換行會在再次解析時改變引數邊界。改以 `ProcessStartInfo.ArgumentList` 逐項傳遞固定選項。

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
| `thread.started` | `thread_id` 是續行識別，寫入 `dispatchRoot\.local\ai-sessions\history\codex-thread-<dispatchSlug>.txt` |
| `item.completed` 且 `item.type` 為 `agent_message` | 最後一則的 `text` 是結案訊息 |
| `turn.completed` | 唯一的正常完成證據，其 `usage` 提供本次實際 token 用量 |

stdout 只包含事件流 JSONL，診斷訊息一律走 stderr，兩者分別重導至不同檔案。

### Unix 啟動

以下 `bash` 範例適用於 Bash 或 WSL。以 `setsid` 建立專用 process group，`codexPid` 是該群組的根程序；環境沒有 `setsid` 時停止並回報缺件，不退回只記錄單一 PID。

```bash
sourceRoot="<sourceRoot>"
dispatchSlug="<dispatchSlug>"
lineSlug="<lineSlug>"
writeMode="<readonly 或 write>"
dispatchRoot="$sourceRoot/.local/ai-sessions/worktrees/$dispatchSlug"
sourceHistoryDir="$sourceRoot/.local/ai-sessions/history"
historyDir="$dispatchRoot/.local/ai-sessions/history"
scratchDir="$dispatchRoot/.local/ai-sessions/scratch"
timestamp="$(date +%Y%m%d_%H%M%S)"
promptPath="$scratchDir/codex-prompt-$timestamp.md"
lastMessagePath="$historyDir/codex-last-message-$timestamp.md"
eventStreamPath="$historyDir/codex-exec-$timestamp.jsonl"
errorStreamPath="$historyDir/codex-exec-$timestamp.stderr.log"

setsid codex \
  --cd "$dispatchRoot" \
  --sandbox workspace-write \
  exec \
  --json \
  --output-last-message "$lastMessagePath" \
  - \
  < "$promptPath" \
  > "$eventStreamPath" 2> "$errorStreamPath" &
codexPid=$!
```

PID 記錄的欄位與寫入規則見「Codex 進程 PID 與並行檢查」，Unix 端以 `ps` 取得 `comm`、`ppid` 與 `pgid` 後寫入同一組欄位。

### Windows 啟動

`ProcessStartInfo.ArgumentList` 逐項傳遞固定選項，`cwd` 固定為 `dispatchRoot`。

```powershell
$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $codexPath
$startInfo.WorkingDirectory = $dispatchRoot
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$startInfo.StandardInputEncoding = $utf8NoBom
$startInfo.StandardOutputEncoding = $utf8NoBom
$startInfo.StandardErrorEncoding = $utf8NoBom
foreach ($argument in @("--cd", $dispatchRoot, "--sandbox", "workspace-write")) {
  [void]$startInfo.ArgumentList.Add($argument)
}
if ($profileName -ne "default") {
  [void]$startInfo.ArgumentList.Add("--profile")
  [void]$startInfo.ArgumentList.Add($profileName)
}
foreach ($directory in $extraDirectories) {
  [void]$startInfo.ArgumentList.Add("--add-dir")
  [void]$startInfo.ArgumentList.Add($directory)
}
if ($needsSearch) {
  [void]$startInfo.ArgumentList.Add("--search")
}
foreach ($argument in @("exec", "--json", "--output-last-message", $lastMessagePath, "-")) {
  [void]$startInfo.ArgumentList.Add($argument)
}
```

啟動後的根程序身分查詢沿用「Codex 進程 PID 與並行檢查」的規則。`Win32_Process` 查不到剛啟動的 PID 有兩種成因，處置不同。進程仍存活但 WMI 尚未填入 `CreationDate` 時，以最多 20 次、每次 150 毫秒的間隔重試。進程已結束時重試不會成功，改以 `Process.HasExited` 與 `ExitCode` 判定並讀取 stderr。

啟動失敗路徑必須先把已收集的 stderr 寫入 `errorStreamPath`，再拋出原始例外，並以持有的 Process handle 呼叫 `Kill($true)` 終止整棵樹。參數錯誤導致的立即結束，唯一能指出原因的證據只存在於 stderr；先拋例外會使該檔從未建立，錯誤表面化為 `Win32_Process` 查不到進程，掩蓋真正的失敗原因。

Prompt 內容在啟動後寫入標準輸入並關閉該串流。

```powershell
$process.StandardInput.Write((Get-Content -LiteralPath $promptPath -Raw))
$process.StandardInput.Close()
```

### Prompt 必備元素

Prompt 必須明列已驗證的 `LineContext`，格式如下：

```text
lineSlug=<lineSlug>
sourceLineRoot=<sourceRoot>\.local\ai-sessions\handoff\<lineSlug>
dispatchLineRoot=<dispatchRoot>\.local\ai-sessions\handoff\<lineSlug>
reportLineRoot=<dispatchRoot>\.local\ai-sessions\report\<lineSlug>
```

Prompt 至少包含下列元素，缺一即視為契約未滿足。

1. 執行角色的觸發詞或 skill 名稱。Workflow 派工使用 `Developer` 的觸發詞；資源派遣使用派遣單第 2 欄指定的角色或 skill。
2. Workflow 派工使用 `dispatchLineRoot\design.md` 的絕對路徑，資源派遣使用派遣單的絕對路徑。
3. `LineContext` 的 `lineSlug`、`sourceLineRoot`、`dispatchLineRoot`、`reportLineRoot`、`sourceRoot`、`dispatchRoot` 與相關產出落點的絕對路徑。
4. 回報格式、產出落點與驗收條件。Workflow 派工另須要求結案報告包含輪起點 SHA、開工基準線、「Phase 對照」節與「判定為既有實作而未動工」節。「Phase 對照」節逐 Phase 列出該 Phase 實際修改的檔案清單，供主 Agent 依 Phase 分組建立 commit。續 session 必須重述前輪這兩節的全部條目。

需要以結構約束結案報告時，另建立 JSON Schema 檔並加入 `--output-schema <FILE>`。該選項只約束最終回應的形狀，不改變事件流格式。

## 模型檔位規則

本 Skill 只使用預設檔位與 `deep`。實際 model id 與其餘設定只存在於 `~/.codex/<檔位名稱>.config.toml`，規則層只傳遞語意檔位名稱。

`codex exec` 與 `codex exec resume` 屬 runtime command，接受 `--profile`。檔位以 `--profile <檔位名稱>` 傳遞，放在 `exec` 子命令之前。預設檔位省略 `--profile`，沿用 `~/.codex/config.toml`。

啟動探針與機制驗證可使用成本較低的獨立檔位，避免以 `deep` 驗證流程本身。該檔位的名稱與內容由使用者提供，規則層不預設其存在。

`deep` 僅適用於推理密集且執行量不大的工作，例如需要自行找路、探索未知相依性或處理步驟未明確的多步驟問題。例行編輯、操作步驟完整的任務、單一命令驗證與單純文件整理使用預設檔位。

執行量大但步驟明確的任務即使規模龐大也使用預設檔位。`deep` 改變的是模型與推理設定，不是讀寫與命令執行的吞吐，用在大量執行類工作只會拉高消耗而不改變結果。

`deep` 相對預設檔位的實際差異由兩份設定檔的差集決定，不由本文件斷言。判定任務是否值得升級前，先讀取 `~/.codex/deep.config.toml` 與 `~/.codex/config.toml`，比對兩者的 `model`、`model_reasoning_effort` 與其餘鍵，再據此說明升級能帶來什麼。

### 額度快照

主 Agent 從 `<CODEX_HOME>/sessions/<yyyy>/<MM>/<dd>/rollout-<時間戳>-<thread-id>.jsonl` 讀取 session 記錄。額度資料位於 `payload.rate_limits`，必須同時取得 `primary` 與 `secondary` 視窗。每個視窗使用 `used_percent`、`window_minutes` 與 `resets_at`，其中 `used_percent` 為數值百分比、`window_minutes` 為分鐘數，`resets_at` 為 Unix timestamp（秒）。剩餘額度百分比為 `100 - used_percent`，`window_days` 為 `window_minutes / 1440`。

主 Agent 每次派工前呼叫 `~/.ai-agents/scripts/Get-CodexQuota.ps1` 取得快照。腳本掃描最近 20 個 rollout 檔，對每個視窗獨立略過無效資料與 `resets_at` 不大於目前時間的候選，再選取來源檔案寫入時間最新的候選，同檔內以 record index 由新到舊決勝。不得改用 `resets_at` 最大值挑選候選，週視窗重新錨定時 `resets_at` 會往回跳，取最大值會淘汰當日全部記錄並鎖死在舊快照。任一視窗沒有有效候選時，腳本以非零結束碼回報錯誤，不輸出估算值。

快照必須落在目前的 `primary` 視窗內才可用於檔位判定。`resets_at` 位於未來只證明該視窗尚未重設，不證明 `used_percent` 反映目前用量：一筆數天前的 rollout，其 `secondary.resets_at` 仍可能在未來而被選為有效候選，但它記錄的是當時的累積值，不含之後的全部消耗。判定前先確認 `primary_source_file` 的寫入時間不早於 `primary_resets_at` 減去 `primary_window_minutes`。不滿足時視為快照過期，停止需要額度判定的派工，並回報來源檔名與其時間。

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

兩個視窗的門檻不同。`primary` 為 30%，`secondary` 為 15%。門檻差異來自容量差：一次 `deep` 派工實測消耗 `primary` 約 19 至 28 個百分點，15% 撐不完單次派工；同樣的消耗量在 `secondary` 不足 1 個百分點，15% 仍有數次派工的餘裕。

1. 主 Agent 先判斷任務是否推理密集且執行量不大，判準是需要自行找路、探索未知相依性或處理步驟未明確的多步驟問題，且不以大量讀寫、掃描或命令執行為主體。
2. `primary_remaining_percent` 大於或等於 30、`secondary_remaining_percent` 大於或等於 15，且任務符合第 1 條條件時，依「升級確認」節向使用者提出確認。取得當輪明確同意後才加入 `--profile deep`；未取得同意時省略該選項，使用預設檔位。
3. `secondary_remaining_percent` 低於 15 時，省略 `--profile`，使用預設檔位。週視窗重設通常在數天後，不採等待。
4. `secondary` 通過門檻但 `primary_remaining_percent` 低於 30 時，依 `primary_days_to_reset` 決定處置。距重設 30 分鐘以內時，向使用者提議等待重設後再以 `deep` 派工，不降檔；距重設超過 30 分鐘時，省略 `--profile`，使用預設檔位。
5. 額度腳本失敗、輸出缺少任一視窗欄位或 `deep.config.toml` 不存在時，停止需要額度判定的派工，不使用估算值或隱式 profile fallback。
6. 預設檔位省略 `--profile`。檔位名稱只允許預設與 `deep` 的語意集合，臨時驗證檔位不進入派工判定。

第 4 條的等待選項只適用於 `primary`。剩餘時間影響的是「要不要等一下再派工」，不得用來放寬百分比門檻。等待提議與升級確認併為同一次詢問，不分兩輪問使用者。

### 決策歸屬

檔位由主 Agent 於派工當下決定。主 Agent 必須保留兩個視窗的剩餘額度與任務難度判定，供回報與後續複核使用。

### 升級確認

`deep` 一律經使用者確認後才使用，不自動升級。理由是 `deep` 單次派工消耗 `primary` 約 19 至 28 個百分點，等同用掉當日多數派工餘裕，這個取捨屬於使用者的資源分配決定。

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
| A 正常結束 | 背景指令已離開執行狀態，且事件流最後一則事件的 `type` 為 `turn.completed` | 進行事件流取證，再執行回收判定 |
| B 執行中查詢 | 背景指令仍在執行，使用者要求現況 | 回報事件流最後一則事件的 `type` 與時間，不中止也不改變等待方式 |
| C 早夭 | 背景指令已離開執行狀態，且事件流最後一則事件的 `type` 不是 `turn.completed` | 事件流含 `agent_message` 時取最後一則作為未完成回報，依回收三態判定，不視為正常結束；沒有 `agent_message` 時讀取 stderr 與 exit code 並回報啟動或執行失敗 |

C 出口的常見成因包括參數位置錯誤、模型不被伺服器接受、額度用盡與 sandbox 權限失敗。這些都只在 stderr 留下訊息，因此 stderr 必須在兩條路徑都保存。

### 主 Agent 的等待方式

主 Agent 將整段啟動指令以背景方式執行，該回合即結束，不停留等待。指令結束時由執行環境的事件通知重新叫起主 Agent，主 Agent 再讀取事件流、last-message 與報告檔進行取證與回收。主 Agent 不輪詢檔案大小、不使用 sleep 迴圈，也不派生 sub-agent 代為等待。

此方式的前提是執行環境具備背景執行與完成通知。缺少該機制時，退回為同步阻塞執行同一段指令，取證與回收的判準不變。兩種方式的差別只在主 Agent 是否佔用回合等待，不影響完成判定。

主 Agent 只在兩種情形提前介入未結束的執行：使用者要求中止，或依中斷策略需要強制收尾。兩者都走既有的 PID 進程樹身分比對後終止。

## 事件流取證

事件流逐行寫入 `dispatchRoot\.local\ai-sessions\history\codex-exec-<yyyyMMdd_HHmmss>.jsonl`，stderr 寫入同目錄的 `codex-exec-<yyyyMMdd_HHmmss>.stderr.log`。兩者都必須在正常結束與失敗兩條路徑保存。

取證時逐行解析事件流，空白行略過。解析失敗的行保存原文並記入取證結果，不因單行解析失敗放棄整份事件流；事件流是逐行獨立的記錄，一行損毀不影響其餘行的證據價值。

| 取證項目 | 來源 |
| --- | --- |
| `threadId` | 第一則 `thread.started` 的 `thread_id` |
| `finalMessage` | `--output-last-message` 指定的檔案內容；該檔缺失或為空時，改取事件流中最後一則 `item.type` 為 `agent_message` 的 `text` |
| `completed` | 事件流最後一則事件的 `type` 是否為 `turn.completed` |
| `usage` | `turn.completed` 的 `usage` 物件，作為本次實際消耗記錄 |
| `outputValid` | 最後訊息是否同時包含派遣單絕對路徑、`dispatchSlug` 與 `lineSlug` |
| `exitCode` | process 結束碼 |
| `stderr` | stderr 檔案完整內容 |

`--output-last-message` 由 CLI 直接寫檔，比從事件流反推更可靠，因此列為 `finalMessage` 的第一來源。沒有 final message 時保留空值並將 `outputValid` 設為無效，不建立補償訊息。

`usage` 只作為事後記錄與額度對照，不取代派工前的額度快照判定。

Workflow 派工將 `finalMessage` 寫入 `reportLineRoot\implement-closure-report.md`，資源派遣寫入派遣單第 7 欄指定落點。結果再交給 `RecoveryPrecheck`。

## 續 session 與跨介面接手

若需要補齊欄位或修正純技術驗收問題，先從 `codex-thread-<dispatchSlug>.txt` 讀取 `thread_id`，再以 `codex exec resume` 續行。續 session 沿用同一個 `dispatchRoot`、sandbox 邊界、`LineContext`、檔位與 PID 身分驗證規則。

```bash
codex \
  --cd "$dispatchRoot" \
  --sandbox workspace-write \
  exec resume "$threadId" \
  --json \
  --output-last-message "$lastMessagePath" \
  - \
  < "$promptPath" \
  > "$eventStreamPath" 2> "$errorStreamPath"
```

`exec resume` 的 session 識別接受 `thread_id` 或 thread 名稱，UUID 優先解析。省略識別並改用 `--last` 會選取最近一次記錄的 session，該行為依賴本機記錄狀態而非本次派遣的識別，因此派工流程一律明列 `thread_id`，不使用 `--last`。

續行 prompt 仍來自 scratch 檔案並以 `-` 從 stdin 傳入，內容必須附上未達成條件清單。續行產生新的事件流與 stderr 檔案，不覆寫前一輪的記錄。

跨介面接手視為同一條 line 的續行，依序讀取下列交接物重建狀態。

1. `dispatchLineRoot\design.md`。
2. `sourceLineRoot\requirement-summary.md`。需要由 Codex 寫入或讀取來源交接時，沿用啟動命令的 `--add-dir` 授權。
3. 本輪 `dispatchRoot\.local\ai-sessions\history\codex-exec-<yyyyMMdd_HHmmss>.jsonl`。
4. `reportLineRoot\implement-closure-report.md` 或派遣單第 7 欄指定報告。

### 中止與安全關閉

中止只針對 PID 記錄中 `work-root`、`line-slug` 與 `dispatch-slug` 三者均匹配本次派遣的進程樹，並依「Codex 進程 PID 與並行檢查」的根程序身分比對後執行。終止後再次查詢確認全部程序已結束，並保存事件流、stderr 與 exit 資訊。

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

共用本 Skill 的機制。Workflow 派工與資源派遣只以輸入、產出與結案要求區分；兩者都先使用同一個 dispatch worktree。

| 面向 | Workflow 派工（`Developer`） | 資源派遣（`Architect`、`Reviewer`、`Support Engineer`、其餘一切） |
| --- | --- | --- |
| 必備輸入 | `dispatchLineRoot\design.md` 絕對路徑 | `dispatchRoot\.local\ai-sessions\handoff\dispatch-order-<dispatchSlug>.md` 派遣單絕對路徑 |
| 產出落點 | `reportLineRoot\implement-closure-report.md`，回收後同步至 `sourceReportLineRoot` | `dispatchRoot\.local\ai-sessions\report\dispatch-report-<dispatchSlug>.md`，回收後同步至 `sourceRoot` |
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
| 6 | 執行邊界 | 描述工作類型、目標物件、允許的報告與交接寫入，以及不得修改目標物件等行為限制。第 6 欄不描述 repository 排除檔案清單，隔離由 dispatch worktree 與 `--cd` 提供。「唯讀」定義為不得修改目標物件、不得執行建置與測試、不得建立 commit；非唯讀派遣同樣不建立 commit，commit 由主 Agent 回收後處理。派遣單第 7 欄的報告檔與 `<work-root>/.local/ai-sessions/report/<lineSlug>/exceptions.md` 是所有派遣共用的明文寫入例外。需要完全不寫入任何檔案時，明文寫出「不產生任何檔案寫入」。 |
| 7 | 產出落點 | 報告或產物的絕對路徑 |
| 8 | 回報必備欄位 | Codex 端回報必須逐條列出第 5 欄命令原文、完整 stdout、完整 stderr、exit code、執行時間與判定結果 |

第 5 欄格式如下。

```markdown
| # | 驗收條件 | Codex 命令 |
| --- | --- | --- |
| <n> | `<absolute-path>` 存在且非空 | `Get-Item -LiteralPath '<absolute-path>'` |
| <n> | 內容含指定欄位 | `rg -n '<pattern>' '<absolute-path>'` |
```

建置與測試由主 Agent 自行執行，不列為 Codex 第 5 欄的命令輸出責任。主 Agent 依需要抽驗 Codex 回報的命令，不整套重跑；只有輸出與結論不一致的條件才重跑該條命令。

## RecoveryPrecheck

事件流取證後，先從符合目前派工類型的 `agent_message` 取最後一則結案訊息。結案訊息必須同時包含派遣單絕對路徑、`dispatchSlug` 與 `lineSlug`。缺少任一識別字時，狀態設為 `PromptNotDelivered`，修正啟動方式後重新派遣；此狀態不計入退回次數，也不進入第 5 欄驗收缺漏的退回計數。只有 `RecoveryPrecheck` 通過後，才可進入回收三態判定。

## 回收三態判定

背景指令結束後，主 Agent 先執行 `RecoveryPrecheck`，再讀取 dispatch worktree 內派遣單第 7 欄的產出落點，依第 5 欄逐條執行命令。主 Agent 不以 Codex 端回報中的自述取代實際判定。派遣單第 8 欄必須要求 Codex 端逐條回報每條驗收條件的命令原文與完整 stdout、完整 stderr、exit code 與執行時間。主 Agent 以抽驗方式複核回報內容，對輸出與結論不一致的條件只重跑該條命令。回報只寫「已完成」而未附命令輸出者，該條計為未成立。

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
