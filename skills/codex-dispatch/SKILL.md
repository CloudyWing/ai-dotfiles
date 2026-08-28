---
name: codex-dispatch
description: 'Codex 派工機制：依派工類型建立執行契約、啟動 Codex、等待事件流、取證並回收結果。當需要發動 codex、撰寫派遣單或執行派遣回收判定時使用。'
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

派工前掃描同一個 `sourceRoot` 的 `codex-pid-*.txt`。逐檔解析 `work-root`、`line-slug`、`root-pid`（舊格式回退讀取 `pid`）與進程樹欄位。只有 `work-root` 與目前絕對路徑相同、`line-slug` 與目前 `LineContext.lineSlug` 相同，且進程樹或 process group 仍存活的記錄才阻塞派遣。缺少 `line-slug` 的舊格式記錄不具備線歸屬，不滿足雙鍵比對。Windows 以 `Win32_Process` 的 `ProcessId`、`ParentProcessId`、`Name` 與 `CreationDate` 查詢根程序及其所有後代，遞迴追查每一層子程序；根程序已結束但仍有任何後代存活時，仍判定為活躍實例。Unix 以 PID 檔的 `process-group-id` 查詢 process group 成員，群組內仍有任何程序存活時，仍判定為活躍實例。歷史進程樹已完全結束時不阻塞派工；發現同線的活躍 Codex 實例時回報活躍 PID 記錄檔、根 PID 與存活後代或 process group，停止流程，不啟動第二個同線實例。

中斷或重派前只讀取雙鍵匹配目前 `sourceRoot` 與 `lineSlug` 的 PID 記錄，再解析 `root-pid`（舊格式使用 `pid`）。Windows 執行 `taskkill /PID <root-pid> /T /F`，由系統終止根程序及整個後代樹。若根程序已先結束，先以 `Win32_Process.ParentProcessId` 找出仍存活的後代，再對每個仍存活的樹根執行 `taskkill /PID <descendant-pid> /T /F`，直到重新查詢不到任何後代。Unix 執行 `kill -TERM -- -<process-group-id>` 終止整個 process group；若依中斷策略需要強制收尾，對同一個 process group 使用 `kill -KILL -- -<process-group-id>`。終止後再次以進程樹或 process group 查詢確認全部程序已結束。只終止 PID 檔記錄的單一進程或包裝 Codex 的 shell 不符合本契約。

**被強制終止過的 dispatch worktree 不得重用（Crucial）**。sandbox helper 在正常結束時才移除自己套用的 ACL；被 `taskkill` 或 session 中止時來不及清理，worktree 根目錄會殘留一條明確（非繼承）的存取控制項目，其 SID 已無對應帳號。之後在該目錄啟動的 Codex 會在套用 sandbox ACL 時失敗，全程無法執行任何命令。以 `icacls <dispatchRoot>` 與來源工作樹比對即可確認：報廢的 worktree 會多出不帶 `(I)` 標記的條目。

重派時建立新的 dispatch worktree，並以 `git -C <舊 dispatchRoot> diff` 產出的 patch 將既有成果轉移至新 worktree，不要嘗試修改 ACL。新 worktree 沿用同一個 `lineSlug`，`dispatchSlug` 另取未使用的名稱。轉移完成後，舊 worktree 依既有路徑檢查移除。

PID 記錄保留於來源工作樹的 `history`，不因 dispatch worktree 移除或 `scratch` 清理而刪除。PID 檔案是否存在不能單獨作為並行判定依據，必須合併 `work-root`、`line-slug` 與完整進程樹或 process group 的存活狀態；wrapper 已結束但子進程仍存活時，不得判定為可並行啟動。不同 `lineSlug` 的存活記錄必須可同時存在且不互相阻塞。

## Phase commit 回收與驗證

Codex 端不建立 commit，因此 dispatch worktree 的 `HEAD` 在派工全程維持 `baseSha`，實作成果以未 commit 的工作區變更形式存在。回收的輸入是這份工作區差異，不是 commit 區間。

主 Agent 以 `git -C <dispatchRoot> diff` 取得工作區差異，依結案報告「Phase 對照」節記載的逐 Phase 檔案清單分組。Phase commit 以 Phase 為單位回收，一個 Phase 一個 commit；`phaseCommits` 依 Phase 順序排列，commit 訊息依 `generate-commit` skill 產生。主 Agent 將各 Phase 的差異依序套用至來源分支並建立對應 commit，保留 Phase 的獨立語意。

「Phase 對照」節缺失時停止回收並依續 session 契約要求補齊。缺少該節時，主 Agent 只能看到一份混合全部 Phase 的差異，無從還原 Phase 邊界。

單一檔案橫跨兩個以上 Phase 時，該檔的差異歸入其最早出現的 Phase，並在回收回報中列出該檔與涉及的全部 Phase。

回收不將全部 Phase squash 成單一 commit，也不以 merge commit 取代 Phase commit。任何 commit 回收衝突都停止處理，保留 dispatch worktree、來源狀態與事件證據，交由後續裁決或續行。

Phase commit 回收完成後，依 `git-workflow` skill 的 `validationMode` 執行重整後驗證，再同步報告與核准交接產物，最後才移除 dispatch worktree。Design、Review 與其他資源派遣不產生 Phase commit，直接同步報告與核准交接產物。

## 執行前提與可用性檢查

派工前確認目前 session 能執行本地命令。Windows 先以 `Get-Command codex.cmd` 解析 PATH 上的實體命令，將結果保存為 `codexPath`，再以該路徑取得版本並檢查啟動環境。

```powershell
$codexCommand = Get-Command codex.cmd -ErrorAction SilentlyContinue
if ($null -eq $codexCommand) {
  throw "codex.cmd was not found on PATH."
}
$codexPath = $codexCommand.Source
& $codexPath --version
```

版本檢查失敗時，先回報執行檔不存在或設定載入失敗的具體訊息。版本檢查失敗不等同派工工作失敗，需先處理執行環境問題。

| Session 型態 | 派工能力 | 處置 |
| --- | --- | --- |
| Desktop Code tab、VS Code 擴充、CLI、SSH 或 WSL 的 local session | 可發動 | 依本 Skill 的指令契約執行 |
| Dispatch 對話本身或 cloud session | 不可發動 | 明確回報「當前 session 不載入全域規則，請於 local Code session 發動」，不嘗試執行 `codex` |
| Dispatch 派生的 local Code session | 可發動 | 依本 Skill 的指令契約執行 |

派工命令執行前由主 Agent 準備 `sourceLineRoot`、`<sourceRoot>\.local\ai-sessions\history\<lineSlug>`、`sourceReportLineRoot`、`dispatchLineRoot`、`reportLineRoot`，以及 `dispatchRoot\.local\ai-sessions\history` 與 `scratch`。來源 `sourceLineRoot\requirement-summary.md` 與同線來源 `history` 的覆寫備份保存跨派遣交接；事件流與 PID 記錄維持在既有的 `history` 根目錄；固定報告與例外紀錄落在 `reportLineRoot`。資源派遣若需更新來源需求摘要或其 history 備份，啟動命令必須以 `--add-dir` 授權這兩個來源線層目錄。報告檔與 `<work-root>/.local/ai-sessions/report/<lineSlug>/exceptions.md` 依派遣契約的明文寫入例外處理。若主 Agent 無法完成前置作業，停止啟動並回報缺件。重導向與 `--output-last-message` 不會建立父目錄，目錄缺少時 shell 會先失敗。

## 指令契約

正式啟動使用 `codex exec`，沿用既有 session 使用 `codex exec resume`。`sourceRoot`、`dispatchRoot`、`dispatchSlug`、`lineSlug` 與各輸出檔案路徑都使用絕對路徑；`dispatchRoot` 固定為 `<sourceRoot>\.local\ai-sessions\worktrees\<dispatchSlug>`。事件流檔名使用時間戳，不另外加入 slug。

一般派工的 Codex 工作目錄固定為 `dispatchRoot`。主 Agent 先建立 prompt scratch 檔，再從檔案讀取單一 prompt 字串。PowerShell 不可將未處理的 `$prompt` 直接放入 `Start-Process -ArgumentList`，因為該參數會把陣列重新組合成單一命令列字串，內容中的引號、空白與換行會在再次解析時改變引數邊界。PowerShell 範例改以 `ProcessStartInfo.ArgumentList` 逐項傳遞固定選項，將 prompt 參數設為 `-`，再把 scratch 的完整內容寫入 `StandardInput`；`-` 是 Codex 從 stdin 讀取 prompt 的指示，直接寫入 stdin 可保留完整多行內容。`--cd`、`--sandbox`、`--add-dir` 與 `--search` 是 `codex` 的父層選項，必須放在 `exec` 或 `exec resume` 前方；`--output-last-message` 屬執行子命令的選項，放在子命令後方。

以下 `bash` 範例適用於 Bash 或 WSL。沒有網路需求時省略 `--search`，沒有 worktree 外寫入需求時省略 `--add-dir`。

```bash
sourceRoot="<sourceRoot>"
dispatchRoot="$sourceRoot/.local/ai-sessions/worktrees/<dispatchSlug>"
lineSlug="<lineSlug>"
sourceLineRoot="$sourceRoot/.local/ai-sessions/handoff/$lineSlug"
sourceLineHistoryDir="$sourceRoot/.local/ai-sessions/history/$lineSlug"
dispatchLineRoot="$dispatchRoot/.local/ai-sessions/handoff/$lineSlug"
reportLineRoot="$dispatchRoot/.local/ai-sessions/report/$lineSlug"
sourceHistoryDir="$sourceRoot/.local/ai-sessions/history"
historyDir="$dispatchRoot/.local/ai-sessions/history"
scratchDir="$dispatchRoot/.local/ai-sessions/scratch"
timestamp="$(date +%Y%m%d_%H%M%S)"
promptPath="$scratchDir/codex-prompt-$timestamp.md"
lastMessagePath="$historyDir/codex-last-message-$timestamp.md"
eventStreamPath="$historyDir/codex-exec-$timestamp.jsonl"
errorStreamPath="$historyDir/codex-exec-$timestamp.stderr.log"

cat > "$promptPath" <<'PROMPT'
<prompt>
PROMPT
prompt="$(cat "$promptPath")"

setsid codex \
  --cd "$dispatchRoot" \
  --sandbox workspace-write \
  exec \
  --json \
  --output-last-message "$lastMessagePath" \
  "$prompt" \
  > "$eventStreamPath" 2> "$errorStreamPath" &
codexPid=$!
startedAtUtc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rootProcessName="$(ps -o comm= -p "$codexPid" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
rootParentPid="$(ps -o ppid= -p "$codexPid" | tr -d '[:space:]')"
processGroupId="$(ps -o pgid= -p "$codexPid" | tr -d '[:space:]')"
printf 'pid=%s\nroot-pid=%s\nroot-process-name=%s\nroot-parent-pid=%s\nroot-started-at-utc=%s\nprocess-tree-scope=process-group\nprocess-tree-query=ps-pgid-membership\nprocess-group-id=%s\nwork-root=%s\nline-slug=%s\nstarted-at-utc=%s\n' "$codexPid" "$codexPid" "$rootProcessName" "$rootParentPid" "$startedAtUtc" "$processGroupId" "$sourceRoot" "$lineSlug" "$startedAtUtc" > "$sourceHistoryDir/codex-pid-$timestamp.txt"
```

Unix 範例以 `setsid` 建立專用 process group，`codexPid` 是該群組的根程序；若環境沒有 `setsid`，停止並回報缺件，不得退回只記錄單一 PID。Windows PowerShell 使用 `Get-Command codex.cmd` 解析 PATH 上的實體命令。解析失敗時回報缺件並停止。PowerShell 使用 `ProcessStartInfo` 的 `ArgumentList` 傳遞固定選項，以 `-` 指示 Codex 從標準輸入讀取 prompt；成功啟動後立即查詢根程序的 `Name` 與 `ParentProcessId` 並記錄進程樹欄位，再分別保存標準輸出與錯誤輸出並使用 `WaitForExit()` 等待完成。

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
$lastMessagePath = Join-Path $historyDir "codex-last-message-$timestamp.md"
$eventStreamPath = Join-Path $historyDir "codex-exec-$timestamp.jsonl"
$errorStreamPath = Join-Path $historyDir "codex-exec-$timestamp.stderr.log"

$codexCommand = Get-Command codex.cmd -ErrorAction SilentlyContinue
if ($null -eq $codexCommand) {
  throw "codex.cmd was not found on PATH."
}
$codexPath = $codexCommand.Source
[System.IO.File]::WriteAllText($promptPath, "<prompt>", [System.Text.UTF8Encoding]::new($false))
$prompt = Get-Content -LiteralPath $promptPath -Raw

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $codexPath
$startInfo.UseShellExecute = $false
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
[void]$startInfo.ArgumentList.Add("exec")
[void]$startInfo.ArgumentList.Add("--json")
[void]$startInfo.ArgumentList.Add("--output-last-message")
[void]$startInfo.ArgumentList.Add($lastMessagePath)
[void]$startInfo.ArgumentList.Add("-")

$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $startInfo
if (-not $process.Start()) {
  throw "codex.cmd could not be started."
}
$startedAtUtc = [DateTime]::UtcNow.ToString("o")
$rootProcess = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction Stop
if ($null -eq $rootProcess) {
  throw "The started process could not be found in Win32_Process."
}
$pidPath = Join-Path $sourceHistoryDir "codex-pid-$timestamp.txt"
$pidText = @(
  "pid=$($process.Id)"
  "root-pid=$($process.Id)"
  "root-process-name=$($rootProcess.Name)"
  "root-parent-pid=$($rootProcess.ParentProcessId)"
  "root-started-at-utc=$startedAtUtc"
  "process-tree-scope=pid-and-descendants"
  "process-tree-query=Win32_Process.ParentProcessId"
  "work-root=$sourceRoot"
  "line-slug=$lineSlug"
  "started-at-utc=$startedAtUtc"
) -join [Environment]::NewLine
[System.IO.File]::WriteAllText($pidPath, $pidText, [System.Text.UTF8Encoding]::new($false))

$stderrTask = $process.StandardError.ReadToEndAsync()
$process.StandardInput.Write($prompt)
$process.StandardInput.Close()

$writer = [System.IO.StreamWriter]::new($eventStreamPath, $false, [System.Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true
while ($null -ne ($line = $process.StandardOutput.ReadLine())) { $writer.WriteLine($line) }
$writer.Close()
$process.WaitForExit()
[System.IO.File]::WriteAllText($errorStreamPath, $stderrTask.GetAwaiter().GetResult(), [System.Text.UTF8Encoding]::new($false))
```

`--cd` 固定指向 `dispatchRoot`。`--sandbox` 使用 `workspace-write`，隔離由 dispatch worktree 提供。`--add-dir` 只有在需求明確需要 worktree 外寫入時才加入，並列出絕對路徑。資源派遣若要更新來源 `sourceLineRoot\requirement-summary.md` 或寫入其覆寫備份，必須在 `exec` 前加入下列兩個線層選項，且不可改用 `dispatchRoot` 作為寫入目標。

```text
--add-dir <sourceRoot>\.local\ai-sessions\handoff\<lineSlug>
--add-dir <sourceRoot>\.local\ai-sessions\history\<lineSlug>
```

`--search` 只有在需求明確需要網路查證時才加入，且放在 `exec` 或 `exec resume` 前方。`--json` 將事件流輸出為 JSON Lines，`--output-last-message` 將最後一則訊息寫入獨立檔案。

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

`burn` 與 `deep` 是兩條獨立軸線。

- `burn` 用於額度充裕時加速日常的大批量標準化編輯。
- `deep` 用於需要自行找路、步驟未明確的高難度任務。

實際 model id 與 effort 只存在於 `~/.codex/<檔位名稱>.config.toml`。本 Skill 只使用 `burn` 與 `deep` 這兩個白名單名稱。未指定 `-p` 時使用預設省用檔位。規則不得自行加入 `-p`。

### 額度快照

主 Agent 從 `<CODEX_HOME>/sessions/<yyyy>/<MM>/<dd>/rollout-<時間戳>-<thread-id>.jsonl` 讀取 session 記錄。額度資料位於 `payload.rate_limits`。使用 `payload.rate_limits.primary.used_percent`、`payload.rate_limits.primary.window_minutes` 與 `payload.rate_limits.primary.resets_at`，其中 `used_percent` 為數值百分比、`window_minutes` 為分鐘數，`resets_at` 為 Unix timestamp（秒）。剩餘額度百分比為 `100 - used_percent`，`window_minutes` 除以 `1440` 得到週期天數。

主 Agent 每次派工前呼叫 `~/.ai-agents/scripts/Get-CodexQuota.ps1` 取得快照。腳本掃描最近 20 個 rollout 檔，僅採用 `resets_at` 大於目前時間的候選，並在候選中選擇 `resets_at` 最大者，避免週期滾動後以最新檔案的歸零值誤判額度。找不到有效快照時，腳本以非零結束碼回報錯誤，不使用預設值。

### 額度門檻

| 距離重置 | 允許升級至 `burn` 的剩餘額度門檻 |
| --- | --- |
| 4 天以上 | 不升級，無論剩餘多少 |
| 3 天 | 剩餘 ≥ 70% |
| 2 天 | 剩餘 ≥ 45% |
| 1 天 | 剩餘 ≥ 15% |

曲線為前緊後鬆。前段封死是為了避免過早開啟；最後一天門檻最低，因為未使用的額度於重置時作廢。

### 任務規模推級

本輪任務規模大時，門檻上推一級，例如剩 2 天套用 3 天那格。判定大任務的依據為下列任一條件，T-code 數達 40 條以上、含 `[REWRITE]` Phase，或涉及檔案數達 20 個以上。

### 決策歸屬

檔位由主 Agent 於派工當下決定，不逐次詢問使用者。判斷需同時知道剩餘額度與任務規模，前者只有使用者取得，後者只有主 Agent 掌握；將決策交給使用者等同要求其判斷看不到的量。

### 升級須說明理由

預設永遠是省用檔位。主 Agent 決定升級時必須以一句話說明依據，引用快照數字與規模判定，不得默默升級。

Codex 遇到不存在的 profile 可能靜默回退預設值並以成功結束。執行前確認名稱只使用白名單，結束後以實際事件流與產出驗證結果判定，不以 exit code 單獨推論檔位已生效。

## 背景執行與三出口等待

主 Agent 以背景方式執行 `codex exec`，持續觀察背景指令狀態與事件流檔案大小。事件流檔案大小只表示事件流是否有新進度；背景進程存活與並行檢查依 PID 記錄的完整進程樹或 process group 判定。

| 出口 | 判定條件 | 後續動作 |
| --- | --- | --- |
| A 正常結束 | 背景指令已離開執行狀態，且事件流最後一則事件的 `type` 為 `turn.completed` | 進行事件流取證，再執行回收判定 |
| B 停滯 | 背景指令仍在執行，事件流檔案大小連續 20 次輪詢未增加。每次間隔 30 秒，合計 10 分鐘 | 停止等待，回報最後一則事件的 `type` 與時間，交由使用者決定續等或中止 |
| C 早夭 | 背景指令已離開執行狀態，且事件流最後一則事件的 `type` 不是 `turn.completed` | 事件流含 `agent_message` 時取最後一則作為未完成回報，依 F1 與回收三態判定，不視為正常結束；沒有 `agent_message` 時讀取事件流末尾錯誤文字並回報啟動失敗 |

只以報告檔是否出現作為終止條件，無法區分 Codex 中途崩潰與仍在執行。出口 B 使用檔案大小停滯作為停止依據。

出口 B 成立的前提是事件流在執行期間逐行落地。啟動範例以逐行 `StreamWriter` 搭配 `AutoFlush` 寫入事件流，Bash 端則以重導向達成同一效果。改用 `ReadToEndAsync` 之類的作法會把整份 stdout 留在啟動端的記憶體，事件流檔案在進程結束前維持 0 bytes，出口 B 的檔案大小判準恆不成立，且啟動端被終止時整份事件流一併遺失。

## 事件流取證

`--json` 事件流是 append-only 的 JSON Lines。每則助理輸出對應 `item.completed` 事件，格式如下。

```json
{"type":"item.completed","item":{"id":"item_68","type":"agent_message","text":"# 派工結案報告\n..."}}
```

thread id 事件格式如下。

```json
{"type":"thread.started","thread_id":"01a01619-fbef-7ee2-aea3-39598e04388e"}
```

由後往前掃描事件流，取最後一則符合目前派工類型的 `agent_message`。Workflow 派工取同時包含「驗證證據」與「Phase 對照」兩節的訊息，寫入 `reportLineRoot\implement-closure-report.md`，再同步至 `sourceReportLineRoot`。資源派遣取符合派遣單第 8 欄要求的訊息，寫入派遣單第 7 欄指定的落點。

主 Agent 將 `thread.started` 的 `thread_id` 寫入 `dispatchRoot\.local\ai-sessions\history\codex-thread-<dispatchSlug>.txt`，同步回來源工作樹後保留於 `sourceRoot\.local\ai-sessions\history`，續 session 先讀取同一份記錄。

取證失效時依下列狀態處理。

- F1。事件流中沒有符合條件的結案訊息。判定必要欄位缺失，Workflow 派工依續 session 契約補齊；資源派遣依回收三態判定為未達成驗收條件。
- F2。事件流沒有落地。回退讀取本輪 `dispatchRoot\.local\ai-sessions\history\codex-last-message-<yyyyMMdd_HHmmss>.md`，並在回報中標示取證來源為 last-message 檔。
- F3。事件流含多則符合條件的訊息。取最後一則，並以其回報欄位作為最新值。

事件流、thread id 與 last-message 檔在回收判定完成前保留於 `dispatchRoot\.local\ai-sessions\history`。同步回來源工作樹後，來源 `history` 依既有保留規則保存取證，不屬於自動清理範圍。

## 續 session 與跨介面接手

若需要補齊欄位或修正純技術驗收問題，依上一輪事件流的 `thread.started` 事件取得 `<thread-id>`，再使用同一 session 續行。

以下 `bash` 範例適用於 Bash 或 WSL。續 session 沿用同一個 `dispatchRoot` 與原派工的 sandbox 邊界。Prompt 仍先寫入 `scratch`，再以 `$(cat "$promptPath")` 讀取單一字串；需要背景執行時在命令末尾加上 `&`，標準輸出與錯誤輸出分別保存。

```bash
sourceRoot="<sourceRoot>"
dispatchRoot="$sourceRoot/.local/ai-sessions/worktrees/<dispatchSlug>"
lineSlug="<lineSlug>"
sourceLineRoot="$sourceRoot/.local/ai-sessions/handoff/$lineSlug"
sourceLineHistoryDir="$sourceRoot/.local/ai-sessions/history/$lineSlug"
dispatchLineRoot="$dispatchRoot/.local/ai-sessions/handoff/$lineSlug"
reportLineRoot="$dispatchRoot/.local/ai-sessions/report/$lineSlug"
sourceHistoryDir="$sourceRoot/.local/ai-sessions/history"
historyDir="$dispatchRoot/.local/ai-sessions/history"
scratchDir="$dispatchRoot/.local/ai-sessions/scratch"
timestamp="$(date +%Y%m%d_%H%M%S)"
promptPath="$scratchDir/codex-prompt-$timestamp.md"
lastMessagePath="$historyDir/codex-last-message-$timestamp.md"
eventStreamPath="$historyDir/codex-exec-resume-$timestamp.jsonl"
errorStreamPath="$historyDir/codex-exec-resume-$timestamp.stderr.log"

cat > "$promptPath" <<'PROMPT'
<prompt>
PROMPT
prompt="$(cat "$promptPath")"

setsid codex \
  --cd "$dispatchRoot" \
  --sandbox workspace-write \
  exec resume "<thread-id>" \
  --json \
  --output-last-message "$lastMessagePath" \
  "$prompt" \
  > "$eventStreamPath" 2> "$errorStreamPath" &
codexPid=$!
startedAtUtc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rootProcessName="$(ps -o comm= -p "$codexPid" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
rootParentPid="$(ps -o ppid= -p "$codexPid" | tr -d '[:space:]')"
processGroupId="$(ps -o pgid= -p "$codexPid" | tr -d '[:space:]')"
printf 'pid=%s\nroot-pid=%s\nroot-process-name=%s\nroot-parent-pid=%s\nroot-started-at-utc=%s\nprocess-tree-scope=process-group\nprocess-tree-query=ps-pgid-membership\nprocess-group-id=%s\nwork-root=%s\nline-slug=%s\nstarted-at-utc=%s\n' "$codexPid" "$codexPid" "$rootProcessName" "$rootParentPid" "$startedAtUtc" "$processGroupId" "$sourceRoot" "$lineSlug" "$startedAtUtc" > "$sourceHistoryDir/codex-pid-$timestamp.txt"
```

Windows PowerShell 以 `(Get-Command codex.cmd).Source` 解析實體路徑。解析失敗時停止並回報缺件。使用 `ProcessStartInfo` 的 `ArgumentList` 傳遞固定選項，以 `-` 指示 Codex 從標準輸入讀取 prompt；續 session 啟動成功後同樣立即查詢根程序的 `Name` 與 `ParentProcessId` 並寫入來源工作樹的 PID 記錄，再分別保存標準輸出與錯誤輸出並使用 `WaitForExit()` 等待完成。

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
$lastMessagePath = Join-Path $historyDir "codex-last-message-$timestamp.md"
$eventStreamPath = Join-Path $historyDir "codex-exec-resume-$timestamp.jsonl"
$errorStreamPath = Join-Path $historyDir "codex-exec-resume-$timestamp.stderr.log"

$codexCommand = Get-Command codex.cmd -ErrorAction SilentlyContinue
if ($null -eq $codexCommand) {
  throw "codex.cmd was not found on PATH."
}
$codexPath = $codexCommand.Source
[System.IO.File]::WriteAllText($promptPath, "<prompt>", [System.Text.UTF8Encoding]::new($false))
$prompt = Get-Content -LiteralPath $promptPath -Raw

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $codexPath
$startInfo.UseShellExecute = $false
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
[void]$startInfo.ArgumentList.Add("exec")
[void]$startInfo.ArgumentList.Add("resume")
[void]$startInfo.ArgumentList.Add("<thread-id>")
[void]$startInfo.ArgumentList.Add("--json")
[void]$startInfo.ArgumentList.Add("--output-last-message")
[void]$startInfo.ArgumentList.Add($lastMessagePath)
[void]$startInfo.ArgumentList.Add("-")

$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $startInfo
if (-not $process.Start()) {
  throw "codex.cmd could not be started."
}
$startedAtUtc = [DateTime]::UtcNow.ToString("o")
$rootProcess = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction Stop
if ($null -eq $rootProcess) {
  throw "The resumed process could not be found in Win32_Process."
}
$pidPath = Join-Path $sourceHistoryDir "codex-pid-$timestamp.txt"
$pidText = @(
  "pid=$($process.Id)"
  "root-pid=$($process.Id)"
  "root-process-name=$($rootProcess.Name)"
  "root-parent-pid=$($rootProcess.ParentProcessId)"
  "root-started-at-utc=$startedAtUtc"
  "process-tree-scope=pid-and-descendants"
  "process-tree-query=Win32_Process.ParentProcessId"
  "work-root=$sourceRoot"
  "line-slug=$lineSlug"
  "started-at-utc=$startedAtUtc"
) -join [Environment]::NewLine
[System.IO.File]::WriteAllText($pidPath, $pidText, [System.Text.UTF8Encoding]::new($false))

$stderrTask = $process.StandardError.ReadToEndAsync()
$process.StandardInput.Write($prompt)
$process.StandardInput.Close()

$writer = [System.IO.StreamWriter]::new($eventStreamPath, $false, [System.Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true
while ($null -ne ($line = $process.StandardOutput.ReadLine())) { $writer.WriteLine($line) }
$writer.Close()
$process.WaitForExit()
[System.IO.File]::WriteAllText($errorStreamPath, $stderrTask.GetAwaiter().GetResult(), [System.Text.UTF8Encoding]::new($false))
```

`--cd`、`--sandbox`、`--add-dir` 與 `--search` 都是 `codex` 的父層選項，必須放在 `exec resume` 前方。`--output-last-message` 屬執行子命令的選項，放在子命令後方。`<sandbox-mode>` 必須沿用原派工邊界；續 session 不擴大其他寫入範圍或提高 sandbox 權限。需要網路查證時，將 `--search` 加在 `exec resume` 前方。

讀不到 thread id 檔案時開新 session，並在 prompt 附上設計文件與退回報告的絕對路徑。跨介面接手視為新 session，依序讀取下列交接物重建狀態。

1. `dispatchLineRoot\design.md`。
2. `sourceLineRoot\requirement-summary.md`。需要由 Codex 寫入或讀取來源交接時，沿用啟動命令的 `--add-dir` 授權。
3. 本輪 `dispatchRoot\.local\ai-sessions\history\codex-exec-<yyyyMMdd_HHmmss>.jsonl`。
4. 事件流取證產生的 `reportLineRoot\implement-closure-report.md` 或派遣單第 7 欄指定報告。

## sandbox 外環境動作

需要網路或 work-root 外環境變更的工作，由主 Agent 在派工前代執行。代執行前必須取得使用者當輪明確同意。非互動情境無法取得當輪同意時停止並回報缺件。

代執行後追加 `<work-root>/.local/ai-sessions/report/<lineSlug>/exceptions.md`，觸發類型使用「偏離設計」，並記錄外環境動作、同意依據與位置。寫入前確認 `LineContext.lineSlug` 與同線 manifest 一致。不得以開放 sandbox 網路取代 `--search`，也不得把 shell 出網工作直接派給 Codex。

## 網路能力硬邊界

`--search` 是 Codex 的唯一上網路徑，且必須放在 `exec` 或 `exec resume` 前方。Codex shell 無法以 `curl` 或其他一般 shell 工具出網；開啟 sandbox network access 也不代表 shell 查證可用。

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

`requirement-summary.md` 是跨派遣的持久交接檔，固定於 `sourceLineRoot\requirement-summary.md`；覆寫前備份固定於 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>`。這兩個來源落點不屬於 `dispatchRoot` 的派遣產出，資源派遣若需寫入它們，必須在 `exec` 或 `exec resume` 前以 `--add-dir` 分別授權來源線層 `handoff` 與 `history` 目錄。

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
