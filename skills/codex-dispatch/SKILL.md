---
name: codex-dispatch
description: 'Codex 派工機制：依派工類型建立執行契約、以 app-server 啟動 Codex、背景等待、取證並回收結果。當需要發動 codex、撰寫派遣單或執行派遣回收判定時使用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Codex 派工機制

本 Skill 負責派工的執行機制。是否派工由 `instructions.md` §1.5 的路由規則判定，本 Skill 只處理指令、落點、等待、取證、續 session 與回收。

## Git 前置探針與 worktree 生命週期

所有派遣先建立 `DispatchPreflight`。每次派遣必須取得上游傳入且已驗證的 `LineContext`。`lineSlug` 識別同一條 Clarify 線，`dispatchSlug` 識別單次 dispatch worktree，兩者分屬不同名稱空間。缺少 `LineContext`、`lineSlug` 不符合 `^[a-z0-9]+(?:-[a-z0-9]+)*$`，或 `line.json` 的 `line-slug` 與傳入值不一致時，停止於 PID 與 Git 前置流程之前，不建立預設線或以 `dispatchSlug` 代替。

| 欄位 | 路徑或用途 |
| --- | --- |
| `sourceRoot` | 使用者指定且已解析的 work-root 絕對路徑 |
| `lineSlug` | Clarify 已登記的語意化線識別 |
| `sourceLineRoot` | `<sourceRoot>\.local\ai-sessions\handoff\<lineSlug>` |
| `dispatchRoot` | `<sourceRoot>\.local\ai-sessions\worktrees\<dispatchSlug>` |
| `dispatchLineRoot` | `<dispatchRoot>\.local\ai-sessions\handoff\<lineSlug>` |
| `sourceReportLineRoot` | `<sourceRoot>\.local\ai-sessions\report\<lineSlug>` |
| `reportLineRoot` | `<dispatchRoot>\.local\ai-sessions\report\<lineSlug>` |

`DispatchPreflight` 讀取 `<sourceLineRoot>\line.json`，確認 `schema=ai-sessions.line.v1` 與 `line-slug=<lineSlug>` 後，才建立 dispatch worktree 與同線目錄。`dispatchSlug` 只使用小寫英數與連字號，且在同一個 `sourceRoot` 內不得重複。PID 並行檢查先於 Git 前置流程執行，檢查通過後才可啟動派工。

前置流程依下列順序執行。

1. 解析 `sourceRoot`、`dispatchRoot`、`sourceLineRoot`、`dispatchLineRoot`、`sourceReportLineRoot` 與 `reportLineRoot` 的絕對路徑，確認 `dispatchSlug` 與 `lineSlug` 均符合 `^[a-z0-9]+(?:-[a-z0-9]+)*$`。
2. 讀取 `<sourceLineRoot>\line.json`，確認其 `schema` 與 `line-slug`。manifest 缺失、格式錯誤或歸屬不一致時停止派遣；既有但缺少 manifest 的目錄視為已被占用，不建立或覆寫它。
3. 掃描 PID 記錄，以 `sourceRoot` 與 `lineSlug` 執行雙鍵並行檢查。不同 `lineSlug` 的活躍記錄不阻塞派遣。
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
   - Design、Review 與其他資源派遣直接同步報告與允許的交接產物，不透過 commit 回收。
   - Workflow `Implement` 回收 dispatch worktree 的工作區差異，依結案報告「Phase 對照」節分組後建立 Phase commit。Phase 回收規則由 `git-workflow` skill 定義。
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
started-at-utc=<ISO 8601 UTC 時間>
```

派工前掃描同一個 `sourceRoot` 的 `codex-pid-*.txt`。逐檔解析 `work-root`、`line-slug`、`root-pid`（舊格式回退讀取 `pid`）與進程樹欄位。只有 `work-root` 與目前絕對路徑相同、`line-slug` 與目前 `LineContext.lineSlug` 相同、進程樹或 process group 仍存活，且根程序身分比對通過的記錄才阻塞派遣。缺少 `line-slug` 的舊格式記錄不具備線歸屬，不滿足雙鍵比對。Windows 以 `Win32_Process` 的 `ProcessId`、`ParentProcessId`、`Name` 與 `CreationDate` 查詢根程序及其所有後代，遞迴追查每一層子程序。將查得根程序的 `Name` 與 `CreationDate` 轉為 UTC 後，分別比對 PID 記錄的 `root-process-name` 與 `root-started-at-utc`。名稱採不分大小寫的完全相等比對，建立時間差距容許最多 1 秒，以涵蓋查詢與記錄序列化的時鐘精度差異；兩項必須同時符合。任一項不符或無法查詢時，判定為 PID 重用，該筆記錄不阻塞派工，也不把其目前後代視為同一個 Codex 進程樹。根程序已結束但仍有後代時，只有在根 PID 目前不存在且未發現 PID 重用的情況下，才可依 `ParentProcessId` 鏈保留活躍判定。根 PID 已被其他程序占用且身分不符時，依 PID 重用處理。Unix 以 PID 檔的 `process-group-id` 查詢 process group 成員，並以 `root-pid` 查詢根程序，依相同規則比對 `root-process-name`、`root-started-at-utc` 與查得的程序名稱、建立時間。根程序身分比對通過且群組內仍有任何程序存活時，才判定為活躍實例。根程序在身分驗證後結束但群組成員仍存活時，沿用已驗證的根程序身分與仍存在的 `process-group-id` 判定活躍；根 PID 被其他程序占用、身分比對失敗或無法完成身分驗證時，判定為 PID 重用，該筆記錄不阻塞派工。舊格式 PID 記錄若缺少 `root-process-name` 或 `root-started-at-utc`，視為無法確認身分的歷史記錄，不阻塞派工。理由是僅憑 PID、process group 或存活狀態無法排除 PID 重用。歷史進程樹已完全結束時不阻塞派工；發現同線的活躍 Codex 實例時回報活躍 PID 記錄檔、根 PID 與存活後代或 process group，停止流程，不啟動第二個同線實例。

中斷或重派前只讀取雙鍵匹配目前 `sourceRoot` 與 `lineSlug` 的 PID 記錄，再解析 `root-pid`（舊格式使用 `pid`）。Windows 執行任何 `taskkill` 前，必須先以 `Win32_Process` 查詢根程序，確認查得的 `Name` 與 `CreationDate` 分別符合 `root-process-name` 與 `root-started-at-utc`，名稱不分大小寫完全相等且建立時間差距不超過 1 秒。兩項身分比對通過後，才可執行 `taskkill /PID <root-pid> /T /F`，由系統終止根程序及整個後代樹。若根程序已先結束，先以 `Win32_Process.ParentProcessId` 找出仍存活的後代，並沿用已通過的根程序身分驗證確認其仍屬同一進程樹，再對每個仍存活的樹根執行 `taskkill /PID <descendant-pid> /T /F`，直到重新查詢不到任何後代。根 PID 被其他程序占用、身分比對失敗或舊格式缺少任一身分欄位時，判定為 PID 重用或無法確認身分，不得執行 `taskkill`，以免終止重用該 PID 的無關程序。Unix 執行 `kill -TERM -- -<process-group-id>` 前，同樣必須先完成根程序名稱與建立時間的身分比對，再確認 `process-group-id` 仍屬於該已驗證的 process group；比對失敗或無法完成比對時不得執行任何 `kill`。若依中斷策略需要強制收尾，僅對同一個已驗證的 process group 使用 `kill -KILL -- -<process-group-id>`。終止後再次以進程樹或 process group 查詢確認全部程序已結束。只終止 PID 檔記錄的單一進程或包裝 Codex 的 shell 不符合本契約。

**被強制終止過的 dispatch worktree 不得重用（Crucial）**。sandbox helper 在正常結束時才移除自己套用的 ACL；被 `taskkill` 或 session 中止時來不及清理，worktree 根目錄會殘留一條明確（非繼承）的存取控制項目，其 SID 已無對應帳號。之後在該目錄啟動的 Codex 會在套用 sandbox ACL 時失敗，全程無法執行任何命令。以 `icacls <dispatchRoot>` 與來源工作樹比對即可確認：報廢的 worktree 會多出不帶 `(I)` 標記的條目。

重派時建立新的 dispatch worktree，並以 `git -C <舊 dispatchRoot> diff` 產出的 patch 將既有成果轉移至新 worktree，不要嘗試修改 ACL。新 worktree 沿用同一個 `lineSlug`，`dispatchSlug` 另取未使用的名稱。轉移完成後，舊 worktree 依既有路徑檢查移除。

PID 記錄保留於來源工作樹的 `history`，不因 dispatch worktree 移除或 `scratch` 清理而刪除。PID 檔案是否存在不能單獨作為並行判定依據，必須合併 `work-root`、`line-slug`、進程身分比對與完整進程樹或 process group 的存活狀態；wrapper 已結束但子進程仍存活時，不得判定為可並行啟動。不同 `lineSlug` 的存活記錄必須可同時存在且不互相阻塞。

## Phase commit 回收與驗證

Codex 端不建立 commit，因此 dispatch worktree 的 `HEAD` 在派工全程維持 `baseSha`，實作成果以未 commit 的工作區變更形式存在。回收的輸入是這份工作區差異，不是 commit 區間。

主 Agent 以 `git -C <dispatchRoot> diff` 取得工作區差異，依結案報告「Phase 對照」節記載的逐 Phase 檔案清單分組。Phase commit 以 Phase 為單位回收，一個 Phase 一個 commit；`phaseCommits` 依 Phase 順序排列，commit 訊息依 `generate-commit` skill 產生。主 Agent 將各 Phase 的差異依序套用至來源分支並建立對應 commit，保留 Phase 的獨立語意。

「Phase 對照」節缺失時停止回收並依續 session 契約要求補齊。缺少該節時，主 Agent 只能看到一份混合全部 Phase 的差異，無從還原 Phase 邊界。

單一檔案橫跨兩個以上 Phase 時，該檔的差異歸入其最早出現的 Phase，並在回收回報中列出該檔與涉及的全部 Phase。

回收不將全部 Phase squash 成單一 commit，也不以 merge commit 取代 Phase commit。任何 commit 回收衝突都停止處理，保留 dispatch worktree、來源狀態與事件證據，交由後續裁決或續行。

Phase commit 回收完成後，依 `git-workflow` skill 的 `validationMode` 執行重整後驗證，再同步報告與核准交接產物，最後才移除 dispatch worktree。Design、Review 與其他資源派遣不產生 Phase commit，直接同步報告與核准交接產物。

## 執行前提與可用性檢查

派工前確認目前 session 能執行本地命令。Windows 先以 `Get-Command codex.cmd -ErrorAction SilentlyContinue` 解析 PATH 上的實體命令，將結果保存為 `codexPath`，再以該路徑取得版本與 app-server 能力資訊。版本或能力檢查失敗時停止派工，回報原始錯誤與結束碼。

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

$helpOutput = (& $codexPath --cd . --sandbox workspace-write app-server --help 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
  throw "codex app-server --help failed with exit code $LASTEXITCODE. Output: $helpOutput"
}
```

版本檢查失敗表示執行環境尚未可用，先處理 PATH、設定載入或 CLI 版本問題。app-server help probe 成功後才可建立 protocol connection。

| Session 型態 | 派工能力 | 處置 |
| --- | --- | --- |
| Desktop Code tab、VS Code 擴充、CLI、SSH 或 WSL 的 local session | 可發動 | 依本 Skill 的指令契約執行 |
| Dispatch 對話本身或 cloud session | 不可發動 | 明確回報「當前 session 不載入全域規則，請於 local Code session 發動」，不嘗試執行 `codex` |
| Dispatch 派生的 local Code session | 可發動 | 依本 Skill 的指令契約執行 |

派工命令執行前由主 Agent 準備 `sourceLineRoot`、`<sourceRoot>\.local\ai-sessions\history\<lineSlug>`、`sourceReportLineRoot`、`dispatchLineRoot`、`reportLineRoot`，以及 `dispatchRoot\.local\ai-sessions\history` 與 `scratch`。來源 `sourceLineRoot\requirement-summary.md` 與同線來源 `history` 的覆寫備份保存跨派遣交接；protocol transcript、stderr、thread id 與 PID 記錄維持在既有的 `history` 根目錄；固定報告與例外紀錄落在 `reportLineRoot`。資源派遣若需更新來源需求摘要或其 history 備份，啟動命令必須以 `--add-dir` 授權這兩個來源線層目錄。報告檔與 `<work-root>/.local/ai-sessions/report/<lineSlug>/exceptions.md` 依派遣契約的明文寫入例外處理。若主 Agent 無法完成前置作業，停止啟動並回報缺件。所有輸出父目錄必須在建立 connection 前完成建立。

## 指令契約

正式啟動使用 `codex app-server`。新工作與續 session 都在同一個 JSON-RPC over JSONL connection 上執行，`sourceRoot`、`dispatchRoot`、`dispatchSlug`、`lineSlug` 與各輸出檔案路徑都使用絕對路徑；`dispatchRoot` 固定為 `<sourceRoot>\.local\ai-sessions\worktrees\<dispatchSlug>`。protocol transcript、stderr、thread id 與 last-message 檔名使用時間戳，不另外加入未驗證的工作目錄。

一般派工的 Codex 工作目錄固定為 `dispatchRoot`。主 Agent 先建立 prompt scratch 檔，再從檔案讀取單一 prompt 字串。Prompt 不作為命令列引數，完整內容放入 `turn/start` 的單一 text item。PowerShell 端使用 `ProcessStartInfo.ArgumentList` 逐項傳遞固定選項，避免將路徑或 profile 重新組合為未處理的命令列字串。

### Windows app-server 啟動

以下 PowerShell 片段以 PowerShell 7+ 為目標。`Get-CodexQuota.ps1` 與 `Setup-AIGlobalConfig.ps1` 仍維持 Windows PowerShell 5.1 相容性。所有輸出目錄由主 Agent 在啟動前建立，Transport 的 `cwd` 固定為 `dispatchRoot`。

```powershell
$sourceRoot = "<sourceRoot>"
$dispatchRoot = Join-Path $sourceRoot ".local\ai-sessions\worktrees\<dispatchSlug>"
$lineSlug = "<lineSlug>"
$sourceLineRoot = Join-Path $sourceRoot ".local\ai-sessions\handoff\$lineSlug"
$sourceLineHistoryDir = Join-Path $sourceRoot ".local\ai-sessions\history\$lineSlug"
$dispatchLineRoot = Join-Path $dispatchRoot ".local\ai-sessions\handoff\$lineSlug"
$reportLineRoot = Join-Path $dispatchRoot ".local\ai-sessions\report\$lineSlug"
$sourceHistoryDir = Join-Path $sourceRoot ".local\ai-sessions\history"
$historyDir = Join-Path $dispatchRoot ".local\ai-sessions\history"
$scratchDir = Join-Path $dispatchRoot ".local\ai-sessions\scratch"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$promptPath = Join-Path $scratchDir "codex-prompt-$timestamp.md"
$transcriptPath = Join-Path $historyDir "codex-app-server-$timestamp.jsonl"
$lastMessagePath = Join-Path $historyDir "codex-last-message-$timestamp.md"
$stderrPath = Join-Path $historyDir "codex-app-server-$timestamp.stderr.log"
$profile = "default"
$needsSearch = $false
$extraDirectories = @()

$codexCommand = Get-Command codex.cmd -ErrorAction SilentlyContinue
if ($null -eq $codexCommand) {
  throw "codex.cmd was not found on PATH."
}
$codexPath = $codexCommand.Source
if ($profile -notin @("default", "deep")) {
  throw "Unsupported Codex profile: $profile"
}
$prompt = Get-Content -LiteralPath $promptPath -Raw

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
[void]$startInfo.ArgumentList.Add("--cd")
[void]$startInfo.ArgumentList.Add($dispatchRoot)
[void]$startInfo.ArgumentList.Add("--sandbox")
[void]$startInfo.ArgumentList.Add("workspace-write")
if ($profile -eq "deep") {
  [void]$startInfo.ArgumentList.Add("-p")
  [void]$startInfo.ArgumentList.Add("deep")
}
foreach ($directory in $extraDirectories) {
  [void]$startInfo.ArgumentList.Add("--add-dir")
  [void]$startInfo.ArgumentList.Add($directory)
}
if ($needsSearch) {
  [void]$startInfo.ArgumentList.Add("--search")
}
[void]$startInfo.ArgumentList.Add("app-server")

$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $startInfo
function Stop-VerifiedAppServerTree {
  param(
    [Parameter(Mandatory)]
    [int]$RootPid,

    [Parameter(Mandatory)]
    [pscustomobject]$RootProcess,

    [Parameter(Mandatory)]
    [DateTime]$RootCreationDateUtc
  )

  if (
    $null -eq $RootProcess -or
    [string]::IsNullOrWhiteSpace([string]$RootProcess.Name) -or
    $null -eq $RootProcess.CreationDate
  ) {
    throw "The app-server root identity is incomplete; cannot safely terminate the process tree."
  }

  $currentRoot = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $RootPid" -ErrorAction Stop
  if ($null -eq $currentRoot) {
    throw "The app-server root identity could not be revalidated; cannot safely terminate the process tree."
  }
  $currentCreationDateUtc = ([DateTime]$currentRoot.CreationDate).ToUniversalTime()
  if (
    [int]$currentRoot.ProcessId -ne $RootPid -or
    [string]$currentRoot.Name -ine [string]$RootProcess.Name -or
    [Math]::Abs(($currentCreationDateUtc - $RootCreationDateUtc).TotalSeconds) -gt 1
  ) {
    throw "The app-server root identity changed; cannot safely terminate the process tree."
  }

  & taskkill.exe /PID $RootPid /T /F | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "taskkill failed for the verified app-server process tree with exit code $LASTEXITCODE."
  }
}

$processStarted = $false
$rootProcess = $null
$rootCreationDateUtc = $null
$startedAtUtc = [DateTime]::UtcNow.ToString("o")
try {
  if (-not $process.Start()) {
    throw "codex app-server could not be started."
  }
  $processStarted = $true
  $rootProcess = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction Stop
  if ($null -eq $rootProcess) {
    throw "The app-server root process could not be found in Win32_Process."
  }
  if ([string]::IsNullOrWhiteSpace([string]$rootProcess.Name)) {
    throw "The app-server root process name could not be read from Win32_Process."
  }
  if ($null -eq $rootProcess.CreationDate) {
    throw "The app-server root process CreationDate could not be read from Win32_Process."
  }
  try {
    $rootCreationDateUtc = ([DateTime]$rootProcess.CreationDate).ToUniversalTime()
  }
  catch {
    throw "The app-server root process CreationDate could not be converted to UTC. $($_.Exception.Message)"
  }

  $pidPath = Join-Path $sourceHistoryDir "codex-pid-$timestamp.txt"
  $pidText = @(
    "pid=$($process.Id)"
    "root-pid=$($process.Id)"
    "root-process-name=$($rootProcess.Name)"
    "root-parent-pid=$($rootProcess.ParentProcessId)"
    "root-started-at-utc=$($rootCreationDateUtc.ToString('o'))"
    "process-tree-scope=pid-and-descendants"
    "process-tree-query=Win32_Process.ParentProcessId"
    "work-root=$sourceRoot"
    "line-slug=$lineSlug"
    "started-at-utc=$startedAtUtc"
  ) -join [Environment]::NewLine
  [System.IO.File]::WriteAllText($pidPath, $pidText, $utf8NoBom)
}
catch {
  $startupError = $_
  if (-not $processStarted) {
    throw $startupError
  }

  if ($null -eq $rootProcess -or $null -eq $rootCreationDateUtc) {
    Write-Error "codex app-server started but its root identity is unavailable; cannot safely terminate the process tree. $($startupError.Exception.Message)" -ErrorAction Continue
  }
  else {
    try {
      Stop-VerifiedAppServerTree `
        -RootPid $process.Id `
        -RootProcess $rootProcess `
        -RootCreationDateUtc $rootCreationDateUtc
    }
    catch {
      Write-Error "codex app-server cleanup could not be completed safely; the process tree may still be running. $($_.Exception.Message)" -ErrorAction Continue
    }
  }

  throw $startupError
}
```

Unix client 在啟動後以 root PID 查詢實際建立時間與程序名稱，將查得的建立時間轉為 UTC ISO 8601 後寫入 `root-started-at-utc`，並以 process group id 與查得的身分完成後續比對。啟動成功後若 metadata、身分轉換或 PID 記錄寫入失敗，先以已取得且重新驗證的 root 身分終止同一個 process group；身分資料不足或重新驗證失敗時，記錄無法安全終止並回報。`started-at-utc` 僅記錄啟動時刻，不得取代 root PID 的實際建立時間。

### app-server method 順序

每條 connection 建立獨立的遞增 `Int64` request id。發送 request 前先把 entry 放入 `$pendingRequests`，key 使用 invariant string；收到 response 後先以相同 key 取出並移除，再設定 result 或 RPC error。`turn/started` 可能先於 `turn/start` response 到達，先放入 `$bufferedNotifications`，取得 turn id 後只重播相同 root thread 的通知。

`thread/started` notification 只記錄 thread id、名稱、parent thread id 與暫定的 `root-candidate`／`subagent` 關係。`Job.ThreadId` 只能由已驗證的 `thread/start` 或 `thread/resume` response 設定；response 到達後再將相同 id 的候選關係確認為 `root`，其他候選維持 `subagent`。

| Method | 類型 | Params 重點 | 順序與結果 |
| --- | --- | --- | --- |
| `initialize` | request | `clientInfo`、`capabilities` | connection 第一個 request；收到 result 後才能繼續 |
| `initialized` | notification | `{}` | `initialize` 成功後立即送出 |
| `thread/start` | request | `cwd`、`model = $null`、`approvalPolicy = never`、`sandbox = workspace-write`、`ephemeral = $false` | 新 Job 建立 root thread 後取得 `thread.id` |
| `thread/resume` | request | `threadId`、`cwd`、`model = $null`、`approvalPolicy = never`、`sandbox = workspace-write` | 續 session 必須確認 response 的 `thread.id` 等於要求值 |
| `turn/start` | request | `threadId`、單一 `input` text item、`model = $null`、`effort = $null`、`outputSchema = $null` | thread 建立或恢復後送出；取得 `turn.id` 後開始 root Job |
| `turn/interrupt` | request | root `threadId`、root `turnId` | 取消時送出；只有收到 `turn/completed` 的 `cancelled`，或通過 `Test-CancelCorrelation` 的 app-server raw status `interrupted`，才能標記取消 |

新 Job 的順序固定為 `initialize`、`initialized`、`thread/start`、`turn/start`。續 session 的順序固定為 `initialize`、`initialized`、`thread/resume`、`turn/start`。每個 `turn/start` 只帶一個完整 prompt text item，prompt 內容來自已建立的 scratch 檔案。

`--cd` 固定指向 `dispatchRoot`。`--sandbox` 使用 `workspace-write`，隔離由 dispatch worktree 提供。`--add-dir` 只有在需求明確需要 worktree 外寫入時才加入，並列出絕對路徑。資源派遣若要更新來源 `sourceLineRoot\requirement-summary.md` 或寫入其覆寫備份，必須加入下列兩個線層選項，且不可改用 `dispatchRoot` 作為寫入目標。

```text
--add-dir <sourceRoot>\.local\ai-sessions\handoff\<lineSlug>
--add-dir <sourceRoot>\.local\ai-sessions\history\<lineSlug>
```

`--search` 只有在需求明確需要網路查證時才加入，並放在最後的 `app-server` 子命令前方。預設 profile 不加入 `-p`；`deep` 依額度與任務條件加入 `-p deep`。Transport stdout 只包含 app-server JSONL。

Prompt 必須明列已驗證的 `LineContext`，格式如下：

```text
lineSlug=<lineSlug>
sourceLineRoot=<sourceRoot>\.local\ai-sessions\handoff\<lineSlug>
dispatchLineRoot=<dispatchRoot>\.local\ai-sessions\handoff\<lineSlug>
reportLineRoot=<dispatchRoot>\.local\ai-sessions\report\<lineSlug>
```

Prompt 至少包含下列元素，缺一即視為契約未滿足。

1. 執行角色的觸發詞或 skill 名稱。Workflow 派工使用 `Implement` 的觸發詞；資源派遣使用派遣單第 2 欄指定的角色或 skill。
2. Workflow 派工使用 `dispatchLineRoot\design.md` 的絕對路徑，資源派遣使用派遣單的絕對路徑。
3. `LineContext` 的 `lineSlug`、`sourceLineRoot`、`dispatchLineRoot`、`reportLineRoot`、`sourceRoot`、`dispatchRoot` 與相關產出落點的絕對路徑。
4. 回報格式、產出落點與驗收條件。Workflow 派工另須要求結案報告包含輪起點 SHA、開工基準線、「Phase 對照」節與「判定為既有實作而未動工」節。「Phase 對照」節逐 Phase 列出該 Phase 實際修改的檔案清單，供主 Agent 依 Phase 分組建立 commit。續 session 必須重述前輪這兩節的全部條目。

## 模型檔位規則

本 Skill 只使用預設檔位與 `deep`。預設檔位省略 `-p`，`deep` 檔位使用 `-p deep`。實際 model id 與 reasoning effort 只存在於 `~/.codex/<檔位名稱>.config.toml`，規則層只傳遞語意檔位名稱。

`deep` 僅適用於需要自行找路、探索未知相依性或處理步驟未明確的高難度工作。例行編輯、操作步驟完整的任務、單一命令驗證與單純文件整理使用預設檔位。

### 額度快照

主 Agent 從 `<CODEX_HOME>/sessions/<yyyy>/<MM>/<dd>/rollout-<時間戳>-<thread-id>.jsonl` 讀取 session 記錄。額度資料位於 `payload.rate_limits`，必須同時取得 `primary` 與 `secondary` 視窗。每個視窗使用 `used_percent`、`window_minutes` 與 `resets_at`，其中 `used_percent` 為數值百分比、`window_minutes` 為分鐘數，`resets_at` 為 Unix timestamp（秒）。剩餘額度百分比為 `100 - used_percent`，`window_days` 為 `window_minutes / 1440`。

主 Agent 每次派工前呼叫 `~/.ai-agents/scripts/Get-CodexQuota.ps1` 取得快照。腳本掃描最近 20 個 rollout 檔，對每個視窗獨立略過無效資料與 `resets_at` 不大於目前時間的候選，再選取來源檔案寫入時間最新的候選，同檔內以 record index 由新到舊決勝。不得改用 `resets_at` 最大值挑選候選，週視窗重新錨定時 `resets_at` 會往回跳，取最大值會淘汰當日全部記錄並鎖死在舊快照。任一視窗沒有有效候選時，腳本以非零結束碼回報錯誤，不輸出估算值。

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

1. 主 Agent 先判斷任務是否需要自行找路、探索未知相依性或處理步驟未明確的多步驟問題。
2. `primary_remaining_percent` 大於或等於 30、`secondary_remaining_percent` 大於或等於 15，且任務符合高難度條件時，加入 `-p deep`。
3. `secondary_remaining_percent` 低於 15 時，省略 `-p` 使用預設檔位。週視窗重設通常在數天後，不採等待。
4. `secondary` 通過門檻但 `primary_remaining_percent` 低於 30 時，依 `primary_days_to_reset` 決定處置。距重設 30 分鐘以內時，向使用者提議等待重設後再以 `deep` 派工，不降檔；距重設超過 30 分鐘時，省略 `-p` 使用預設檔位。
5. 額度腳本失敗、輸出缺少任一視窗欄位或 `deep.config.toml` 不存在時，停止需要額度判定的派工，不使用估算值或隱式 profile fallback。
6. 預設檔位省略 `-p`。profile 名稱只允許預設與 `deep` 的語意集合。

第 4 條的等待選項只適用於 `primary`。剩餘時間影響的是「要不要等一下再派工」，不得用來放寬百分比門檻。

### 決策歸屬

檔位由主 Agent 於派工當下決定。主 Agent 必須保留兩個視窗的剩餘額度與任務難度判定，供回報與後續複核使用。

### 升級須說明理由

主 Agent 選用 `deep` 時，以一句話說明兩個剩餘額度與任務難度均符合條件。檔位判定不得只依 exit code 推論 profile 已生效，必須同時確認啟動參數與產出證據。

## Job 狀態與程序等待

Transport 建立 Job record 時將 `status` 設為 `queued`。stdout reader 逐行處理 app-server JSONL，Job State Reducer 依 root thread 的 notification、pending request response 與 process health 更新狀態。

| 目前狀態 | 觸發事件 | 下一狀態 | 判定依據 |
| --- | --- | --- | --- |
| `queued` | root `turn/started` 到達，或 `turn/start` response 的狀態為 `inProgress` | `running` | app-server 已接受 root turn |
| `queued` | `initialize`、`thread/start` 或 `thread/resume` 回傳 RPC error | `failed` | pending request 以 request id 對應錯誤 |
| `queued` | process 在取得有效 root turn 前結束 | `failed` | 沒有有效 turn 終止訊號 |
| `running` | root `turn/completed` 的 `turn.status` 為 `completed` | `completed` | app-server 明確回報正常終止 |
| `running` | root `turn/completed` 的 `turn.status` 為 `cancelled`，或已送出 `turn/interrupt` 後收到 raw status `interrupted` | `cancelled` | app-server 取消終止正規化為 Job 的 `cancelled` |
| `running` | `error`、malformed JSONL、stdout EOF 或 process 非預期離開 | `failed` | protocol 或程序生命週期失效 |
| 任一非終端狀態 | 已驗證 root `threadId`／`turnId` 的 `turn/interrupt` request 完成取消 | `cancelled` | `Test-CancelCorrelation` 確認取消 request 與 root thread／turn 一致 |
| 任一非終端狀態 | response id 不在 pending map，或 thread／turn 關聯不一致 | `failed` | protocol anomaly 無法安全歸屬 |

只要 process 仍存活且沒有 terminal notification，Job 保持 `queued` 或 `running`。stdout reader 等待下一行，程序存活狀態由 process object 與既有 PID 進程樹驗證提供。Transport 不以報告檔是否出現或輸出閒置時間推導完成與失敗。

終端狀態具有不可逆性。收到終端 notification 後，後續重複 notification 或 response 只追加 protocol evidence，不覆寫 `completed`、`failed` 或 `cancelled`。process 結束時保存 exit code、signal 與 stderr。終端 notification 先到達時保留已判定的 Job 狀態；process 在 terminal notification 前結束時將 Job 設為 `failed`。

目前 app-server 可能以 raw `turn.status = interrupted` 回報 `turn/interrupt` 的結果。只有 `Test-CancelCorrelation` 同時確認取消 request、root thread id 與 root turn id 一致時，才將此 raw status 正規化為 `cancelled`；未經取消要求或關聯不一致的 `interrupted` 與其他未知 status 均設為 `failed`。

每個 connection 初始化 `$bufferedNotifications = [System.Collections.ArrayList]::new()` 與 `$maxBufferedNotifications = 128`，並將兩者綁定至同一個 Job record。

```powershell
$maxBufferedNotifications = 128
$bufferedNotifications = [System.Collections.ArrayList]::new()
$Job.MaxBufferedNotifications = $maxBufferedNotifications
$Job.BufferedNotifications = $bufferedNotifications
```

stdout reader 呼叫 `Handle-AppServerMessage` 時傳入同一個 collection；`turn/start` response 取得 root turn id 後由 `Replay-BufferedNotifications` 重播符合 root thread／turn 的通知。單一 stdout reader 擁有該 collection，加入前檢查最大筆數；Job 進入任何 terminal 狀態時清空 collection。

`Handle-AppServerMessage` 只接受 `jsonrpc = "2.0"`。response 必須有 `id`、沒有 `method`，且恰有 `result` 或 `error` 其中一個欄位；schema 不可判讀時保存原始行、記錄 protocol error 並使 Job 進入 `failed`，不移除 pending entry 或繼續送出後續 method。

Job record 至少包含下列欄位。

| 欄位 | 語意 |
| --- | --- |
| `jobId` | 單次派遣的 Job 識別 |
| `status` | `queued`、`running`、`completed`、`failed` 或 `cancelled` |
| `threadId` | root app-server thread 識別 |
| `turnId` | root app-server turn 識別 |
| `selectedProfile` | `default` 或 `deep` |
| `cancelRequested` | 是否已送出 root `turn/interrupt` request |
| `cancelRequestId` | 已送出的 root `turn/interrupt` request id |
| `cancelThreadId` | 取消 request 指向的 root thread id |
| `cancelTurnId` | 取消 request 指向的 root turn id |
| `finalMessage` | root thread 最新 `agentMessage` 文字，可為空 |
| `finalMessageReady` | root `agentMessage` 是否已收到 `final_answer` phase |
| `outputValid` | 最後訊息是否同時包含派遣單絕對路徑、`dispatchSlug` 與 `lineSlug` |
| `responses` | 以 method 為 key 保存已完成 request 的 result |
| `threadRelations` | 保存 thread id、名稱、parent thread id 與 root／subagent 關係 |
| `threadCandidates` | root response 到達前收到的 thread 關聯候選 |
| `maxBufferedNotifications` | `bufferedNotifications` 的最大筆數，預設為 128 |
| `bufferedNotifications` | 尚未取得 turn id 前暫存的 `turn/started` notification |
| `protocolError` | JSON 解析、RPC、schema 或連線錯誤 |
| `protocolEvidence` | 終端後仍到達的重複 response、notification 或其他 protocol anomaly |
| `stderr` | app-server stderr 完整內容 |
| `startedAtUtc`、`completedAtUtc` | Job 生命週期時間 |

### 主 Agent 的等待方式

上述狀態判定發生在 Transport 進程內部。主 Agent 這一層不參與該判定，也不觀察 Job 狀態的中間變化。

主 Agent 將整段 Transport 指令以背景方式啟動，該回合即結束，不停留等待。指令結束時由執行環境的事件通知重新叫起主 Agent，主 Agent 再讀取 transcript、last-message 與報告檔進行取證與回收。主 Agent 不輪詢檔案大小、不輪詢 Job 狀態、不使用 sleep 迴圈，也不派生 sub-agent 代為等待。

此方式的前提是執行環境具備背景執行與完成通知。缺少該機制時，退回為同步阻塞執行同一段指令，取證與回收的判準不變。兩種方式的差別只在主 Agent 是否佔用回合等待，不影響 Transport 的狀態判定與終端狀態語意。

主 Agent 只在兩種情形提前介入未結束的 Transport：使用者要求中止，或依中斷策略需要強制收尾。兩者都走既有的 PID 進程樹身分比對後終止，不以其他方式停止 Transport。

## protocol transcript 與回報取證

stdout reader 收到每一行後先原樣寫入 `dispatchRoot\.local\ai-sessions\history\codex-app-server-<yyyyMMdd_HHmmss>.jsonl`，再執行 JSON 解析。空白行略過。非空行解析失敗時保存原始 line 與例外，立即將 Job 設為 `failed`，後續內容不再用於完成判定。

notification reader 即時處理 `item/completed`。`item.type = agentMessage` 且 `threadId` 為 root thread 時，將 `item.text` 更新至 `finalMessage`；`item.phase = final_answer` 時標記 final message 已可供回收前檢查。subagent thread 的訊息只寫入 progress evidence，不覆蓋 root `finalMessage`。

notification 與 Job failure 的實際分流如下。下列條件發生於尚未進入 terminal 狀態的 Job 時，會保存 `protocolError` 或原始行並使 Job 進入 `failed`。

1. JSONL 解析或 schema 失敗。包括 malformed JSON、訊息不是 JSON object、`jsonrpc` 缺少或不是 `2.0`、缺少 response 的 `id`、`id = null`、response 同時具備或同時缺少 `result`／`error`、response id 不在 pending map、object 既不是 response 也不是 notification 或 server request，以及 notification 的 `method` property 缺少、為 `null`、空字串或只含空白。
2. RPC 與 process 生命週期失敗。包括 pending response 的 `error`、`process-exit`、`timeout`，以及 stdout reader 將 malformed line、EOF 或連線錯誤轉成的 protocol event。
3. request／response 關聯失敗。包括 `thread/start`／`thread/resume` response 缺少 `thread.id`、續行 thread mismatch、既有 root thread mismatch、`turn/start` 缺少 pending entry、`turn` 或 `turn.id`、root thread mismatch、既有 root turn mismatch，以及未經取消關聯驗證的 `turn/start` `interrupted` response。
4. notification 欄位與 root 關聯失敗。包括 `thread/started` 缺少 `params.thread.id`、`thread/name/updated` 缺少 `threadId` 或 `threadName`、`turn/started` 缺少 `threadId` 或 `turn.id`、root `turn/completed` 的 thread／turn mismatch、未經取消關聯驗證的 `turn/completed` `interrupted`，以及 `error` notification。
5. 狀態與 buffer 失敗。包括 `turn/start` 或 `turn/completed` 的未知 turn status、`bufferedNotifications` 上限小於 1 或超過上限，以及 `Set-JobStatus` 收到不在五狀態合法轉移表內的逆向或不合法指定。未知的目前 Job status 會直接拋出例外，不被當成合法轉移。

下列路徑會放行且不使 Job 失敗。合法的 `inProgress`、`completed`、`cancelled` 與通過 `Test-CancelCorrelation` 的 `interrupted` 依狀態表處理；同時含有非空 `id` 與 `method` 的 server request 回覆 `-32601`；合法的 `initialize` 或其他成功 response 依既有 response reducer 完成或略過。已確認與 Job 狀態無關的 `$script:IgnoredNotificationMethods`，其正常內容直接忽略；同一 method 帶有 `status = failed`／`status = error`、`error` 或 `failureReason` 時只寫入 `ProtocolEvidence`，仍放行。忽略清單以外的未處理 notification method 也只寫入 method 名稱與原始行的 `ProtocolEvidence`，不使 Job 失敗。terminal Job 收到後續事件時清空 buffer、保留 evidence 並維持原終端狀態。

`$script:IgnoredNotificationMethods` 是抑制已確認高頻雜訊的觀察清單，不是 Job failure 白名單。app-server 版本更新後清單可能增減；每個清單 method 都必須依內容區分正常通知與失敗診斷。

`Handle-AppServerMessage` 依下列順序分流每個 JSON object。

```powershell
$script:IgnoredNotificationMethods = @(
  'mcpServer/startupStatus/updated'
  'item/agentMessage/delta'
  'thread/status/changed'
  'thread/tokenUsage/updated'
  'remoteControl/status/changed'
  'account/rateLimits/updated'
)

function Test-IgnoredNotificationFailure {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Message
  )

  $params = $Message.params
  if ($null -eq $params) {
    return $false
  }

  $status = ''
  if ($null -ne $params.PSObject.Properties['status']) {
    $status = [string]$params.status
  }
  if ($status -ieq 'failed' -or $status -ieq 'error') {
    return $true
  }

  return (
    $null -ne $params.PSObject.Properties['error'] -or
    $null -ne $params.PSObject.Properties['failureReason']
  )
}

function ConvertTo-JsonLine {
  param(
    [Parameter(Mandatory)]
    [object]$Payload
  )

  return ($Payload | ConvertTo-Json -Depth 30 -Compress)
}

function Send-JsonRpcRequest {
  param(
    [Parameter(Mandatory)]
    [System.IO.StreamWriter]$Writer,

    [Parameter(Mandatory)]
    [hashtable]$Pending,

    [Parameter(Mandatory)]
    [ref]$NextRequestId,

    [Parameter(Mandatory)]
    [string]$Method,

    [Parameter(Mandatory)]
    [object]$Params
  )

  $id = [string]$NextRequestId.Value
  $NextRequestId.Value++
  $pendingThreadId = $null
  $pendingTurnId = $null
  if ($null -ne $Params) {
    if ($null -ne $Params.PSObject.Properties['threadId']) {
      $pendingThreadId = [string]$Params.threadId
    }
    if ($null -ne $Params.PSObject.Properties['turnId']) {
      $pendingTurnId = [string]$Params.turnId
    }
  }
  $Pending[$id] = [pscustomobject]@{
    Method = $Method
    CreatedAtUtc = [DateTime]::UtcNow
    ThreadId = $pendingThreadId
    TurnId = $pendingTurnId
  }
  $request = [ordered]@{
    jsonrpc = '2.0'
    id = [int64]$id
    method = $Method
    params = $Params
  }

  try {
    $Writer.WriteLine((ConvertTo-JsonLine -Payload $request))
    $Writer.Flush()
  }
  catch {
    $Pending.Remove($id)
    throw
  }

  return $id
}

function Send-JsonRpcNotification {
  param(
    [Parameter(Mandatory)]
    [System.IO.StreamWriter]$Writer,

    [Parameter(Mandatory)]
    [string]$Method,

    [Parameter(Mandatory)]
    [object]$Params
  )

  $notification = [ordered]@{
    jsonrpc = '2.0'
    method = $Method
    params = $Params
  }
  $Writer.WriteLine((ConvertTo-JsonLine -Payload $notification))
  $Writer.Flush()
}

function Clear-JobBufferedNotifications {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Job
  )

  if ($null -ne $Job.BufferedNotifications) {
    [void]$Job.BufferedNotifications.Clear()
  }
}

function Add-BufferedNotification {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Job,

    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [System.Collections.ArrayList]$BufferedNotifications,

    [Parameter(Mandatory)]
    [pscustomobject]$Entry
  )

  if ($null -eq $Job.BufferedNotifications) {
    $Job.BufferedNotifications = $BufferedNotifications
  }
  elseif (-not [object]::ReferenceEquals($Job.BufferedNotifications, $BufferedNotifications)) {
    [void]$Job.BufferedNotifications.Clear()
    $Job.BufferedNotifications = $BufferedNotifications
  }

  $maximum = [int]$Job.MaxBufferedNotifications
  if ($maximum -lt 1) {
    $Job.ProtocolError = 'bufferedNotifications maximum must be greater than zero.'
    Clear-JobBufferedNotifications -Job $Job
    Set-JobStatus -Job $Job -Status 'failed'
    return $false
  }
  if ($BufferedNotifications.Count -ge $maximum) {
    $Job.ProtocolError = "bufferedNotifications maximum of $maximum was exceeded."
    if ($null -ne $Job.ProtocolEvidence) {
      [void]$Job.ProtocolEvidence.Add("$($Job.ProtocolError) raw=$($Entry.RawLine)")
    }
    Clear-JobBufferedNotifications -Job $Job
    Set-JobStatus -Job $Job -Status 'failed'
    return $false
  }

  [void]$BufferedNotifications.Add($Entry)
  return $true
}

function Set-JobStatus {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Job,

    [Parameter(Mandatory)]
    [ValidateSet('queued', 'running', 'completed', 'failed', 'cancelled')]
    [string]$Status,

    [string]$Evidence
  )

  $terminalStatuses = @('completed', 'failed', 'cancelled')
  if ($Status -in $terminalStatuses) {
    Clear-JobBufferedNotifications -Job $Job
  }
  if ($Job.Status -in $terminalStatuses) {
    if ($null -ne $Job.ProtocolEvidence -and -not [string]::IsNullOrWhiteSpace($Evidence)) {
      [void]$Job.ProtocolEvidence.Add($Evidence)
    }
    return
  }

  $allowedTransitions = @{
    queued = @('queued', 'running', 'failed', 'cancelled')
    running = @('running', 'completed', 'failed', 'cancelled')
    completed = @('completed')
    failed = @('failed')
    cancelled = @('cancelled')
  }
  $currentStatus = [string]$Job.Status
  if (-not $allowedTransitions.ContainsKey($currentStatus)) {
    throw "Unknown current Job status: $currentStatus"
  }
  if ($Status -notin $allowedTransitions[$currentStatus]) {
    $transitionError = "Illegal Job status transition: $currentStatus -> $Status"
    $Job.ProtocolError = $transitionError
    if ($null -ne $Job.ProtocolEvidence) {
      [void]$Job.ProtocolEvidence.Add($transitionError)
    }
    $Job.Status = 'failed'
    $Job.CompletedAtUtc = [DateTime]::UtcNow
    Clear-JobBufferedNotifications -Job $Job
    return
  }

  $Job.Status = $Status
  if ($Status -in $terminalStatuses) {
    $Job.CompletedAtUtc = [DateTime]::UtcNow
  }
}

function Test-CancelCorrelation {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Job,

    [Parameter(Mandatory)]
    [string]$ThreadId,

    [Parameter(Mandatory)]
    [string]$TurnId
  )

  if (-not $Job.CancelRequested) {
    return $false
  }
  if ([string]::IsNullOrWhiteSpace($ThreadId) -or [string]::IsNullOrWhiteSpace($TurnId)) {
    return $false
  }
  if ([string]::IsNullOrWhiteSpace([string]$Job.ThreadId) -or [string]::IsNullOrWhiteSpace([string]$Job.TurnId)) {
    return $false
  }
  if ([string]$ThreadId -ne [string]$Job.ThreadId -or [string]$TurnId -ne [string]$Job.TurnId) {
    return $false
  }
  if ([string]$Job.CancelThreadId -ne [string]$ThreadId -or [string]$Job.CancelTurnId -ne [string]$TurnId) {
    return $false
  }
  if ([string]::IsNullOrWhiteSpace([string]$Job.CancelRequestId)) {
    return $false
  }

  return $true
}

function Resolve-ThreadCandidates {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Job
  )

  if (
    $null -eq $Job.ThreadCandidates -or
    [string]::IsNullOrWhiteSpace([string]$Job.ThreadId)
  ) {
    return
  }

  foreach ($candidate in @($Job.ThreadCandidates)) {
    if ([string]$candidate.ThreadId -eq [string]$Job.ThreadId) {
      $candidate.Relation = 'root'
    }
    else {
      $candidate.Relation = 'subagent'
      if ($null -ne $Job.ProtocolEvidence) {
        [void]$Job.ProtocolEvidence.Add("Resolved thread $($candidate.ThreadId) as subagent; root=$($Job.ThreadId)")
      }
    }
    [void]$Job.ThreadCandidates.Remove($candidate)
  }
}

function Reduce-JobState {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Job,

    [Parameter(Mandatory)]
    [ValidateSet('protocol-error', 'rpc-error', 'response', 'notification', 'process-exit', 'timeout')]
    [string]$Event,

    [string]$Method,

    [pscustomobject]$Message,

    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [System.Collections.ArrayList]$BufferedNotifications,

    [pscustomobject]$PendingEntry,

    [string]$RawLine
  )

  if ($null -eq $Job.BufferedNotifications) {
    $Job.BufferedNotifications = $BufferedNotifications
  }
  elseif (-not [object]::ReferenceEquals($Job.BufferedNotifications, $BufferedNotifications)) {
    [void]$Job.BufferedNotifications.Clear()
    $Job.BufferedNotifications = $BufferedNotifications
  }

  if ($Job.Status -in @('completed', 'failed', 'cancelled')) {
    Clear-JobBufferedNotifications -Job $Job
    if ($null -ne $Job.ProtocolEvidence) {
      if (
        $Event -eq 'notification' -and
        $null -ne $Message -and
        $null -ne $Message.PSObject.Properties['method']
      ) {
        [void]$Job.ProtocolEvidence.Add("Ignored app-server notification method $([string]$Message.method) after terminal status $($Job.Status); raw=$RawLine")
      } else {
        [void]$Job.ProtocolEvidence.Add("Ignored $Event after terminal status $($Job.Status).")
      }
    }
    return
  }

  switch ($Event) {
    'protocol-error' {
      Set-JobStatus -Job $Job -Status 'failed'
      return
    }
    'rpc-error' {
      Set-JobStatus -Job $Job -Status 'failed'
      return
    }
    'process-exit' {
      Set-JobStatus -Job $Job -Status 'failed'
      return
    }
    'timeout' {
      if ([string]::IsNullOrWhiteSpace([string]$Job.ProtocolError)) {
        $Job.ProtocolError = 'app-server Job timed out before reaching a terminal state.'
      }
      Set-JobStatus -Job $Job -Status 'failed'
      return
    }
    'response' {
      if ($Method -in @('thread/start', 'thread/resume')) {
        $threadResult = $Job.Responses[$Method]
        if (
          $null -eq $threadResult -or
          $null -eq $threadResult.PSObject.Properties['thread'] -or
          $null -eq $threadResult.thread -or
          $null -eq $threadResult.thread.PSObject.Properties['id'] -or
          [string]::IsNullOrWhiteSpace([string]$threadResult.thread.id)
        ) {
          $Job.ProtocolError = "$Method response did not contain thread.id."
          Set-JobStatus -Job $Job -Status 'failed'
          return
        }
        $responseThreadId = [string]$threadResult.thread.id
        if (
          $Method -eq 'thread/resume' -and
          ($null -eq $PendingEntry -or [string]$PendingEntry.ThreadId -ne $responseThreadId)
        ) {
          $Job.ProtocolError = 'thread/resume response thread mismatch.'
          Set-JobStatus -Job $Job -Status 'failed'
          return
        }
        if (
          -not [string]::IsNullOrWhiteSpace([string]$Job.ThreadId) -and
          [string]$Job.ThreadId -ne $responseThreadId
        ) {
          $Job.ProtocolError = "$Method response thread mismatch."
          Set-JobStatus -Job $Job -Status 'failed'
          return
        }
        $Job.ThreadId = $responseThreadId
        $threadName = ''
        $parentThreadId = ''
        if ($null -ne $threadResult.thread.PSObject.Properties['name']) {
          $threadName = [string]$threadResult.thread.name
        }
        if ($null -ne $threadResult.thread.PSObject.Properties['parentThreadId']) {
          $parentThreadId = [string]$threadResult.thread.parentThreadId
        }
        if ($null -eq $Job.ThreadRelations) {
          $Job.ThreadRelations = [System.Collections.ArrayList]::new()
        }
        [void]$Job.ThreadRelations.Add([pscustomobject]@{
            ThreadId = $responseThreadId
            Name = $threadName
            ParentThreadId = $parentThreadId
            Relation = 'root'
            Source = $Method
          })
        Resolve-ThreadCandidates -Job $Job
        return
      }
      if ($Method -ne 'turn/start' -or -not $Job.Responses.ContainsKey('turn/start')) {
        return
      }
      if ($null -eq $PendingEntry) {
        $Job.ProtocolError = 'turn/start response did not have a pending request entry.'
        Set-JobStatus -Job $Job -Status 'failed'
        return
      }
      $turnStartResult = $Job.Responses['turn/start']
      if (
        $null -eq $turnStartResult -or
        $null -eq $turnStartResult.PSObject.Properties['turn'] -or
        $null -eq $turnStartResult.turn
      ) {
        $Job.ProtocolError = 'turn/start response did not contain turn.'
        Set-JobStatus -Job $Job -Status 'failed'
        return
      }
      $turn = $turnStartResult.turn
      $responseThreadId = [string]$PendingEntry.ThreadId
      if (
        [string]::IsNullOrWhiteSpace($responseThreadId) -or
        [string]::IsNullOrWhiteSpace([string]$Job.ThreadId) -or
        $responseThreadId -ne [string]$Job.ThreadId
      ) {
        $Job.ProtocolError = 'turn/start response thread mismatch.'
        Set-JobStatus -Job $Job -Status 'failed'
        return
      }
      $responseTurnId = [string]$turn.id
      if ([string]::IsNullOrWhiteSpace($responseTurnId)) {
        $Job.ProtocolError = 'turn/start response did not contain turn.id.'
        Set-JobStatus -Job $Job -Status 'failed'
        return
      }
      if (
        -not [string]::IsNullOrWhiteSpace([string]$Job.TurnId) -and
        [string]$Job.TurnId -ne $responseTurnId
      ) {
        $Job.ProtocolError = 'turn/start response turn mismatch.'
        Set-JobStatus -Job $Job -Status 'failed'
        return
      }
      if ([string]::IsNullOrWhiteSpace([string]$Job.TurnId)) {
        $Job.TurnId = $responseTurnId
      }
      Replay-BufferedNotifications -Job $Job -BufferedNotifications $BufferedNotifications
      switch ([string]$turn.status) {
        'inProgress' { Set-JobStatus -Job $Job -Status 'running' }
        'completed' {
          if ($Job.Status -eq 'queued') {
            Set-JobStatus -Job $Job -Status 'running'
          }
          Set-JobStatus -Job $Job -Status 'completed'
        }
        'cancelled' { Set-JobStatus -Job $Job -Status 'cancelled' }
        'interrupted' {
          if (Test-CancelCorrelation -Job $Job -ThreadId $responseThreadId -TurnId $responseTurnId) {
            Set-JobStatus -Job $Job -Status 'cancelled'
          } else {
            $Job.ProtocolError = 'Uncorrelated turn/start interrupted response.'
            Set-JobStatus -Job $Job -Status 'failed'
          }
        }
        default {
          $Job.ProtocolError = "Unknown turn status: $($turn.status)"
          Set-JobStatus -Job $Job -Status 'failed'
        }
      }
      return
    }
    'notification' {
      if (
        $null -eq $Message -or
        $null -eq $Message.PSObject.Properties['method'] -or
        [string]::IsNullOrWhiteSpace([string]$Message.method)
      ) {
        $Job.ProtocolError = 'Notification did not contain method.'
        Set-JobStatus -Job $Job -Status 'failed'
        return
      }

      $params = $Message.params
      switch ([string]$Message.method) {
        'thread/started' {
          if (
            $null -eq $params -or
            $null -eq $params.PSObject.Properties['thread'] -or
            $null -eq $params.thread -or
            $null -eq $params.thread.PSObject.Properties['id'] -or
            [string]::IsNullOrWhiteSpace([string]$params.thread.id)
          ) {
            $Job.ProtocolError = 'thread/started did not contain thread.id.'
            Set-JobStatus -Job $Job -Status 'failed'
            return
          }

          $notificationThreadId = [string]$params.thread.id
          $notificationThreadName = ''
          $parentThreadId = ''
          if ($null -ne $params.thread.PSObject.Properties['name']) {
            $notificationThreadName = [string]$params.thread.name
          }
          if ($null -ne $params.thread.PSObject.Properties['parentThreadId']) {
            $parentThreadId = [string]$params.thread.parentThreadId
          }
          if ($null -eq $Job.ThreadRelations) {
            $Job.ThreadRelations = [System.Collections.ArrayList]::new()
          }
          if ([string]::IsNullOrWhiteSpace([string]$Job.ThreadId)) {
            $relation = if ([string]::IsNullOrWhiteSpace($parentThreadId)) { 'root-candidate' } else { 'subagent' }
          }
          elseif ($notificationThreadId -eq [string]$Job.ThreadId) {
            $relation = 'root'
          }
          else {
            $relation = 'subagent'
          }
          $threadRelation = [pscustomobject]@{
            ThreadId = $notificationThreadId
            Name = $notificationThreadName
            ParentThreadId = $parentThreadId
            Relation = $relation
            Source = 'thread/started'
          }
          [void]$Job.ThreadRelations.Add($threadRelation)
          if ($null -eq $Job.ThreadCandidates) {
            $Job.ThreadCandidates = [System.Collections.ArrayList]::new()
          }
          if ($relation -eq 'root-candidate') {
            [void]$Job.ThreadCandidates.Add($threadRelation)
          }
          elseif ($relation -eq 'subagent' -and [string]::IsNullOrWhiteSpace([string]$Job.ThreadId)) {
            [void]$Job.ThreadCandidates.Add($threadRelation)
            if ($null -ne $Job.ProtocolEvidence) {
              [void]$Job.ProtocolEvidence.Add("Recorded subagent thread $notificationThreadId before root confirmation; parent=$parentThreadId")
            }
          }
          elseif ($relation -eq 'subagent' -and $null -ne $Job.ProtocolEvidence) {
            [void]$Job.ProtocolEvidence.Add("Recorded subagent thread $notificationThreadId; root=$($Job.ThreadId); parent=$parentThreadId")
          }
          return
        }
        'thread/name/updated' {
          if (
            $null -eq $params -or
            $null -eq $params.PSObject.Properties['threadId'] -or
            [string]::IsNullOrWhiteSpace([string]$params.threadId) -or
            $null -eq $params.PSObject.Properties['threadName']
          ) {
            $Job.ProtocolError = 'thread/name/updated did not contain threadId and threadName.'
            Set-JobStatus -Job $Job -Status 'failed'
            return
          }

          $updatedThreadId = [string]$params.threadId
          $updatedThreadName = [string]$params.threadName
          $updatedRelation = if ([string]::IsNullOrWhiteSpace([string]$Job.ThreadId)) {
            'root-candidate'
          }
          elseif ($updatedThreadId -eq [string]$Job.ThreadId) {
            'root'
          }
          else {
            'subagent'
          }
          $matchingRelations = @($Job.ThreadRelations | Where-Object { [string]$_.ThreadId -eq $updatedThreadId })
          if ($matchingRelations.Count -eq 0) {
            if ($null -eq $Job.ThreadRelations) {
              $Job.ThreadRelations = [System.Collections.ArrayList]::new()
            }
            $nameRelation = [pscustomobject]@{
              ThreadId = $updatedThreadId
              Name = $updatedThreadName
              ParentThreadId = ''
              Relation = $updatedRelation
              Source = 'thread/name/updated'
            }
            [void]$Job.ThreadRelations.Add($nameRelation)
            if ([string]::IsNullOrWhiteSpace([string]$Job.ThreadId)) {
              if ($null -eq $Job.ThreadCandidates) {
                $Job.ThreadCandidates = [System.Collections.ArrayList]::new()
              }
              [void]$Job.ThreadCandidates.Add($nameRelation)
            }
          }
          else {
            foreach ($relation in $matchingRelations) {
              $relation.Name = $updatedThreadName
            }
          }
          return
        }
        'turn/started' {
          $notificationThreadId = [string]$params.threadId
          $notificationTurnId = [string]$params.turn.id
          if (
            [string]::IsNullOrWhiteSpace($notificationThreadId) -or
            [string]::IsNullOrWhiteSpace($notificationTurnId)
          ) {
            $Job.ProtocolError = 'turn/started did not contain threadId and turn.id.'
            Set-JobStatus -Job $Job -Status 'failed'
            return
          }
          if ([string]::IsNullOrWhiteSpace([string]$Job.ThreadId)) {
            [void](Add-BufferedNotification -Job $Job -BufferedNotifications $BufferedNotifications -Entry ([pscustomobject]@{
                Method = 'turn/started'
                ThreadId = $notificationThreadId
                TurnId = $notificationTurnId
                Message = $Message
                RawLine = $RawLine
              }))
            return
          }
          if ($notificationThreadId -ne [string]$Job.ThreadId) {
            if ($null -ne $Job.ProtocolEvidence) {
              [void]$Job.ProtocolEvidence.Add("Ignored turn/started for non-root thread $notificationThreadId; raw=$RawLine")
            }
            return
          }
          if ([string]::IsNullOrWhiteSpace([string]$Job.TurnId)) {
            [void](Add-BufferedNotification -Job $Job -BufferedNotifications $BufferedNotifications -Entry ([pscustomobject]@{
                Method = 'turn/started'
                ThreadId = $notificationThreadId
                TurnId = $notificationTurnId
                Message = $Message
                RawLine = $RawLine
              }))
            return
          }
          if ($notificationTurnId -ne [string]$Job.TurnId) {
            if ($null -ne $Job.ProtocolEvidence) {
              [void]$Job.ProtocolEvidence.Add("Ignored turn/started for different turn $notificationTurnId; raw=$RawLine")
            }
            return
          }
          $Job.TurnId = $notificationTurnId
          Set-JobStatus -Job $Job -Status 'running'
          return
        }
        'item/started' {
          if ([string]$params.threadId -eq [string]$Job.ThreadId) {
            Set-JobStatus -Job $Job -Status 'running'
          }
          return
        }
        'item/completed' {
          if ([string]$params.threadId -ne [string]$Job.ThreadId) {
            return
          }
          if ($null -ne $params.item -and [string]$params.item.type -eq 'agentMessage') {
            $Job.FinalMessage = [string]$params.item.text
            $Job.FinalMessageReady = [string]$params.item.phase -eq 'final_answer'
          }
          return
        }
        'error' {
          $Job.ProtocolError = $params | ConvertTo-Json -Depth 20 -Compress
          Set-JobStatus -Job $Job -Status 'failed'
          return
        }
        'turn/completed' {
          if (
            [string]$params.threadId -ne [string]$Job.ThreadId -or
            [string]$params.turn.id -ne [string]$Job.TurnId
          ) {
            $Job.ProtocolError = 'Root turn/completed thread or turn mismatch.'
            Set-JobStatus -Job $Job -Status 'failed'
            return
          }
          switch ([string]$params.turn.status) {
            'completed' { Set-JobStatus -Job $Job -Status 'completed' }
            'cancelled' { Set-JobStatus -Job $Job -Status 'cancelled' }
            'interrupted' {
              if (Test-CancelCorrelation -Job $Job -ThreadId $params.threadId -TurnId $params.turn.id) {
                Set-JobStatus -Job $Job -Status 'cancelled'
              } else {
                $Job.ProtocolError = 'Uncorrelated turn/completed interrupted notification.'
                Set-JobStatus -Job $Job -Status 'failed'
              }
            }
            default {
              $Job.ProtocolError = "Unknown turn/completed status: $($params.turn.status)"
              Set-JobStatus -Job $Job -Status 'failed'
            }
           }
           return
         }
        default {
          $unknownMethod = [string]$Message.method
          if ($unknownMethod -in $script:IgnoredNotificationMethods) {
            if (Test-IgnoredNotificationFailure -Message $Message) {
              $diagnostic = "Ignored app-server notification method reported failure: $unknownMethod; raw=$RawLine"
              if ($null -ne $Job.ProtocolEvidence) {
                [void]$Job.ProtocolEvidence.Add($diagnostic)
              }
            }
            return
          }

          $diagnostic = "Unhandled app-server notification method: $unknownMethod; raw=$RawLine"
          if ($null -ne $Job.ProtocolEvidence) {
            [void]$Job.ProtocolEvidence.Add($diagnostic)
          }
          return
        }
       }
       return
    }
  }
}

function Replay-BufferedNotifications {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Job,

    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [System.Collections.ArrayList]$BufferedNotifications
  )

  if (
    [string]::IsNullOrWhiteSpace([string]$Job.ThreadId) -or
    [string]::IsNullOrWhiteSpace([string]$Job.TurnId)
  ) {
    return
  }

  $bufferedSnapshot = @($BufferedNotifications)
  foreach ($entry in $bufferedSnapshot) {
    if ([string]$entry.Method -ne 'turn/started') {
      continue
    }
    $entryThreadId = [string]$entry.ThreadId
    $entryTurnId = [string]$entry.TurnId
    [void]$BufferedNotifications.Remove($entry)
    if (
      $entryThreadId -eq [string]$Job.ThreadId -and
      $entryTurnId -eq [string]$Job.TurnId
    ) {
      Reduce-JobState `
        -Job $Job `
        -Event 'notification' `
        -Method 'turn/started' `
        -Message $entry.Message `
        -BufferedNotifications $BufferedNotifications `
        -RawLine $entry.RawLine
      continue
    }
    if ($null -ne $Job.ProtocolEvidence) {
      [void]$Job.ProtocolEvidence.Add("Ignored buffered turn/started for thread $entryThreadId and turn $entryTurnId; raw=$($entry.RawLine)")
    }
  }
}

function Handle-AppServerMessage {
  param(
    [Parameter(Mandatory)]
    [string]$Line,

    [Parameter(Mandatory)]
    [pscustomobject]$Job,

    [Parameter(Mandatory)]
    [hashtable]$Pending,

    [Parameter(Mandatory)]
    [System.IO.StreamWriter]$TranscriptWriter,

    [Parameter(Mandatory)]
    [System.IO.StreamWriter]$Writer,


    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [System.Collections.ArrayList]$BufferedNotifications
  )

  if ([string]::IsNullOrWhiteSpace($Line)) {
    return
  }
  $TranscriptWriter.WriteLine($Line)
  $TranscriptWriter.Flush()

  try {
    $message = $Line | ConvertFrom-Json -ErrorAction Stop
  }
  catch {
    $Job.ProtocolError = "Malformed JSONL: $($_.Exception.Message); line=$Line"
    Reduce-JobState -Job $Job -Event 'protocol-error' -BufferedNotifications $BufferedNotifications -RawLine $Line
    return
  }

  if ($null -eq $message -or $message -isnot [pscustomobject]) {
    $Job.ProtocolError = "JSON-RPC message must be a JSON object; line=$Line"
    Reduce-JobState -Job $Job -Event 'protocol-error' -BufferedNotifications $BufferedNotifications -RawLine $Line
    return
  }

  $hasJsonRpc = $null -ne $message.PSObject.Properties['jsonrpc']
  if (-not $hasJsonRpc -or [string]$message.jsonrpc -ne '2.0') {
    $Job.ProtocolError = "Invalid JSON-RPC version; line=$Line"
    Reduce-JobState -Job $Job -Event 'protocol-error' -BufferedNotifications $BufferedNotifications -RawLine $Line
    return
  }

  $hasId = $null -ne $message.PSObject.Properties['id']
  $hasMethod = $null -ne $message.PSObject.Properties['method']
  if ($hasMethod -and [string]::IsNullOrWhiteSpace([string]$message.method)) {
    $Job.ProtocolError = "JSON-RPC method must be a non-empty string; line=$Line"
    Reduce-JobState -Job $Job -Event 'protocol-error' -BufferedNotifications $BufferedNotifications -RawLine $Line
    return
  }
  if ($hasId -and $hasMethod) {
    $errorMessage = [ordered]@{
      jsonrpc = '2.0'
      id = $message.id
      error = [ordered]@{ code = -32601; message = 'Unsupported server request' }
    }
    $Writer.WriteLine((ConvertTo-JsonLine -Payload $errorMessage))
    $Writer.Flush()
    return
  }

  if ($hasId) {
    if ($null -eq $message.id) {
      $Job.ProtocolError = "JSON-RPC response id was null; line=$Line"
      Reduce-JobState -Job $Job -Event 'protocol-error' -BufferedNotifications $BufferedNotifications -RawLine $Line
      return
    }
    $hasResult = $null -ne $message.PSObject.Properties['result']
    $hasError = $null -ne $message.PSObject.Properties['error']
    if ($hasResult -eq $hasError) {
      $Job.ProtocolError = "JSON-RPC response must contain exactly one of result or error; line=$Line"
      Reduce-JobState -Job $Job -Event 'protocol-error' -BufferedNotifications $BufferedNotifications -RawLine $Line
      return
    }
    $idKey = [string]$message.id
    if (-not $Pending.ContainsKey($idKey)) {
      $Job.ProtocolError = "Unknown response id: $idKey"
      Reduce-JobState -Job $Job -Event 'protocol-error' -BufferedNotifications $BufferedNotifications -RawLine $Line
      return
    }
    $pendingEntry = $Pending[$idKey]
    [void]$Pending.Remove($idKey)
    if ($hasError) {
      $Job.ProtocolError = $message.error | ConvertTo-Json -Depth 20 -Compress
      Reduce-JobState -Job $Job -Event 'rpc-error' -BufferedNotifications $BufferedNotifications -RawLine $Line
      return
    }
    $Job.Responses[$pendingEntry.Method] = $message.result
    Reduce-JobState `
      -Job $Job `
      -Event 'response' `
      -Method $pendingEntry.Method `
      -PendingEntry $pendingEntry `
      -BufferedNotifications $BufferedNotifications `
      -RawLine $Line
    return
  }

  if ($hasMethod) {
    Reduce-JobState `
      -Job $Job `
      -Event 'notification' `
      -Message $message `
      -BufferedNotifications $BufferedNotifications `
      -RawLine $Line
    return
  }

  $Job.ProtocolError = "JSON object is not a response, notification or server request: $Line"
  Reduce-JobState -Job $Job -Event 'protocol-error' -BufferedNotifications $BufferedNotifications -RawLine $Line
}
```

stderr 以獨立 `ReadToEndAsync()` task 收集，避免 stderr buffer 阻塞 stdout reader。Job 終端後關閉 stdin，等待 process 完成，再把完整 stderr 寫入 `dispatchRoot\.local\ai-sessions\history\codex-app-server-<yyyyMMdd_HHmmss>.stderr.log`。thread id 寫入 `dispatchRoot\.local\ai-sessions\history\codex-thread-<dispatchSlug>.txt`，同步回來源工作樹後由來源 `history` 依既有保留規則保存。

Workflow 派工將 normalized Job result 的 `finalMessage` 寫入 `reportLineRoot\implement-closure-report.md`，資源派遣寫入派遣單第 7 欄指定落點。`outputValid` 僅檢查最後訊息是否同時包含派遣單絕對路徑、`dispatchSlug` 與 `lineSlug`，結果再交給 `RecoveryPrecheck`。沒有 final message 時保留空值並設為無效，不建立補償訊息。

## 續 session 與跨介面接手

若需要補齊欄位或修正純技術驗收問題，先從既有 thread id 產物讀取 `<thread-id>`，再使用同一個 app-server thread 續行。續 session 沿用同一個 `dispatchRoot`、sandbox 邊界、`LineContext` 與 PID 身分驗證。

續 session 的 Unix client 必須使用同一個 JSON-RPC over JSONL method 順序，並沿用 PID section 的 process group 身分驗證與安全關閉規則。

Windows PowerShell 以 `(Get-Command codex.cmd).Source` 解析實體路徑。解析失敗時停止並回報缺件。使用 `ProcessStartInfo.ArgumentList` 傳遞固定選項，將 `cwd` 固定為 `dispatchRoot`，以 `StreamWriter` 將續行 request 寫入同一個 app-server connection。續 session 啟動成功後同樣立即查詢根程序的 `Name`、`ParentProcessId` 與建立時間，再寫入來源工作樹的 PID 記錄。

讀取 thread id 產物後，先完成 `initialize` 與 `initialized`，再送出 `thread/resume`。必須確認 response 的 `thread.id` 與要求的 `<thread-id>` 完全相同，接著以同一個 thread id 送出 `turn/start`。續行 prompt 仍來自 scratch 檔案，並以單一 text item 傳送。

跨介面接手視為同一條 line 的續行，依序讀取下列交接物重建狀態。

1. `dispatchLineRoot\design.md`。
2. `sourceLineRoot\requirement-summary.md`。需要由 Codex 寫入或讀取來源交接時，沿用啟動命令的 `--add-dir` 授權。
3. 本輪 `dispatchRoot\.local\ai-sessions\history\codex-app-server-<yyyyMMdd_HHmmss>.jsonl`。
4. normalized Job result 產生的 `reportLineRoot\implement-closure-report.md` 或派遣單第 7 欄指定報告。

### 取消與安全關閉

取消只針對已驗證的 root `threadId`、`turnId` 與 PID 進程樹。以 root thread／turn 建立 `turn/interrupt` request，request id 寫入 pending map；request 成功送出後同步保存 `cancelRequested`、`cancelRequestId`、`cancelThreadId` 與 `cancelTurnId`。`Test-CancelCorrelation` 必須同時確認回報事件的 thread／turn 等於 Job 的 root 關聯，且等於取消 request 的目標。只有收到 root `turn/completed` 且 `turn.status = cancelled`，或通過 `Test-CancelCorrelation` 的 raw status `interrupted`，才把 Job 設為 `cancelled`。`turn/start` response 與 `turn/completed` notification 共用此 helper；RPC error、連線消失或缺少取消終止通知時保存失敗證據，Job 設為 `failed`，再依 PID section 的根程序身分比對與完整進程樹規則收尾。

關閉 connection 時先停止寫入 stdin，讀完 stdout 與 stderr，等待 process 結束，再保存 transcript、thread id、last-message、stderr 與 exit 資訊。任何 `taskkill` 或 `kill` 都必須先通過既有的根程序名稱、建立時間、PID 或 process group 身分比對；Transport 不直接終止單一 PID、wrapper 或 leaf process。

## sandbox 外環境動作

需要網路或 work-root 外環境變更的工作，由主 Agent 在派工前代執行。代執行前必須取得使用者當輪明確同意。非互動情境無法取得當輪同意時停止並回報缺件。

代執行後追加 `<work-root>/.local/ai-sessions/report/<lineSlug>/exceptions.md`，觸發類型使用「偏離設計」，並記錄外環境動作、同意依據與位置。寫入前確認 `LineContext.lineSlug` 與同線 manifest 一致。不得以開放 sandbox 網路取代 `--search`，也不得把 shell 出網工作直接派給 Codex。

## 網路能力硬邊界

`--search` 是 Codex 的唯一上網路徑，且必須放在最後的 `app-server` 子命令前方。Codex shell 無法以 `curl` 或其他一般 shell 工具出網；開啟 sandbox network access 也不代表 shell 查證可用。

下列工作需要 shell 出網，應由 Claude 端依外環境動作規則處理，或先取得使用者當輪同意後由主 Agent 代執行。

- `npm install`。
- `git fetch`。
- 下載檔案或套件。

事實查核類派遣必須啟用 `--search`。未啟用時，Codex 可能無法取得資料而改以記憶作答。

## 兩種派工差異

共用本 Skill 的機制。Workflow 派工與資源派遣只以輸入、產出與結案要求區分；兩者都先使用同一個 dispatch worktree。

| 面向 | Workflow 派工（`Implement`） | 資源派遣（`Design`、`Review`、`Engineer`、其餘一切） |
| --- | --- | --- |
| 必備輸入 | `dispatchLineRoot\design.md` 絕對路徑 | `dispatchRoot\.local\ai-sessions\handoff\dispatch-order-<dispatchSlug>.md` 派遣單絕對路徑 |
| 產出落點 | `reportLineRoot\implement-closure-report.md`，回收後同步至 `sourceReportLineRoot` | `dispatchRoot\.local\ai-sessions\report\dispatch-report-<dispatchSlug>.md`，回收後同步至 `sourceRoot` |
| 結案要求 | 「驗證證據」節的輪起點 SHA 與開工基準線皆有值，且「Phase 對照」節逐 Phase 列出修改的檔案清單 | 先通過 `RecoveryPrecheck`，再逐條執行派遣單第 5 欄的命令並得出「收下」、「退回」或「升級」之一 |

`requirement-summary.md` 是跨派遣的持久交接檔，固定於 `sourceLineRoot\requirement-summary.md`；覆寫前備份固定於 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>`。這兩個來源落點不屬於 `dispatchRoot` 的派遣產出，資源派遣若需寫入它們，必須在最後的 `app-server` 子命令前以 `--add-dir` 分別授權來源線層 `handoff` 與 `history` 目錄。

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

Codex 端不建立 commit。Workflow `Implement` 的機械 commit 由主 Agent 依 `design.md` Phase 重整後回收，資源派遣的報告與核准交接產物直接同步至來源工作樹。

| 判定 | 成立條件 | 後續動作 |
| --- | --- | --- |
| 收下 | 產出落點檔案存在且非空，全部驗收條件逐條成立 | 同步報告與核准交接產物；Workflow `Implement` 進入 Phase commit 回收，資源派遣結束 |
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
