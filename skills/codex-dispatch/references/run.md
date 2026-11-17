# 單次執行入口（Invoke-CodexRun）

選派入口輸出的 `executor.entry` 為 `scripts/Invoke-CodexRun.ps1` 時依本檔執行，適用 `Reviewer`、`Frontend Reviewer` 與 `Contract Auditor`。`executor.entry` 為其他值時依 `start.md`。

一次發動是一個 `codex exec` 行程，直接在線工作樹執行。命令在 MXC 沙盒內只能讀取工作目錄、`~\.ai-agents` 與線的報告目錄，只能寫入該次執行的輸出目錄，讀不到 `.env`、`.env.*`、`*.pem`、`*.key`、`secrets.*`。失敗時整筆重跑，沒有續行。

本入口不使用 `New-DispatchInputs.ps1`、`New-DispatchOrder.ps1`、Request JSON、Preflight、Prepare、Inspect、Collect 與 Cleanup。本檔自成一體，發動、等待與回收不需要再讀 `start.md`、`execution.md`、`collect.md` 與 `recovery.md`。

## 發動

1. 寫派遣檔。複製 `templates/dispatch/run-order.md`，存為 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/run-order-<dispatchSlug>.md`，填寫 `## 派遣設定` 的 JSON 區塊與 `## 任務`、`## 驗收條件`、`## 邊界`、`## 回報必備欄位` 四個章節。
   - `profile` 填選派入口輸出的 `executor.profile`。
   - `role_file` 填角色規則檔的絕對路徑，審查依角色為 `~\.ai-agents\agents\codex\reviewer.toml`、`frontend-reviewer.toml` 或 `contract-auditor.toml` 展開後的路徑。
   - `execution_root` 填線工作樹根目錄。`report_line_root` 填 `<work-root>/.local/ai-sessions/report/<lineSlug>`，該目錄必須已存在。
   - `report_name` 填報告檔名，只含檔名，依角色為 `review-report.md`、`frontend-reviewer-report.md` 或 `contract-auditor-report.md`。
   - `targets` 列出目標物件的絕對路徑，目錄以結尾反斜線標示。`required_reads` 列出必讀檔，例如 `design.md`、`requirement-summary.md`、結案報告與前輪審查報告。
   - 路徑不得指向 `.env`、`.env.*`、`*.pem`、`*.key`、`secrets.*`，也不得位於工作目錄、`~\.ai-agents` 與線的報告目錄之外。`execution_root`、`report_line_root` 與 `report_name` 不得含 `&`、`|`、`<`、`>`、`^`、`%` 與雙引號。
   - `## 驗收條件` 逐條寫出可判定的條件。需要審查者核對的既有證據，把命令原文與原始輸出檔的路徑寫進該條，並把輸出檔列入 `required_reads`。
   - `cycle` 填循環標示，`## 任務` 章節第一行另寫 `循環：<cycle_id> 第 <cycle_round> 輪（cycle_role=review）`。第 2 輪以上把前輪審查報告與修正報告列入 `required_reads`，寫法見 `workflow-orchestration` skill `references/review-procedures.md`。
2. 執行入口。以背景命令執行，完成時會收到通知，不輪詢。

   ```powershell
   pwsh -NoProfile -File scripts/Invoke-CodexRun.ps1 -DispatchFile "<派遣檔絕對路徑>"
   ```

   入口自行選擇派工帳號，不指定 `CODEX_HOME`。帳號登記讀取主 checkout 的 `.local\machine.json`，在線工作樹發動時結果相同。

   單次執行的總時限預設 1800 秒，需要調整時加 `-TimeoutSeconds <秒>`。等待與終止的規則見「等待與終止」。

## 結果

入口在 stdout 輸出一份 JSON，並以結束碼表示結果。人員可讀的診斷訊息在 stderr。

| 結束碼 | `status` | 意義 | 處置 |
| --- | --- | --- | --- |
| 0 | `success` | Codex 正常結束且報告存在 | 進入「回收」。`error` 非空時表示健康狀態檔寫入失敗，不影響本次結果，把訊息回報使用者 |
| 1 | `failed` 或 `rejected` | 執行失敗（含逾時，執行紀錄的 `failure_reason` 為 `timeout`），或服務端拒絕時已有進度 | 讀 `final.stderr_path` 與 `final.events_path` 判斷原因後整筆重跑 |
| 1 | `stopped`，或沒有 JSON 輸出 | 執行紀錄或成本列寫入失敗，或入口發生未預期的錯誤 | 讀 stderr 的錯誤訊息；報告若已產生仍保留在輸出目錄，排除原因後重跑 |
| 2 | `stopped` | 派遣檔無效或引用的路徑不合格 | 依 `error.details` 列出的每個路徑與原因修正派遣檔 |
| 2 | `stopped` | `error.code` 為 `CodexProfileDrift`：實際要使用的帳號的檔位設定檔與主 checkout 的產生檔不一致（內容不同或連結指向他處），或產生檔與登錄表不一致 | 逐行貼到 pwsh 執行 `error.message` 列出的修正命令（重跑 `Update-CodexProfiles.ps1`、重跑 Setup 或移走帳號目錄內的一般檔案後重建連結），再重跑。入口沒有啟動 Codex，也沒有改任何檔案 |
| 3 | `stopped` | 非 Windows、找不到 codex，或 MXC 不可用 | 回報使用者，不改用其他沙盒 |
| 4 | `stopped` | 沒有登記帳號、全部帳號不可用，或候選帳號都被服務端拒絕 | 見「帳號」 |

`attempts` 列出每一次嘗試。換帳號後的每次嘗試各有自己的執行紀錄、輸出目錄與成本列。`final` 指向最後一次嘗試的報告、紀錄、最後訊息、事件流與 stderr。`attempts[].model` 與 `final.model` 是該次嘗試實際使用的 model，`final.model_source` 為 `primary`（檔位的主要 model）或 `fallback`（備援 model）。`fallback` 只在結束碼 4 時有值，內容見「帳號」。

執行紀錄的 `timeout_seconds` 與 `turn_end_grace_seconds` 是該次實際套用的總時限與回合結束寬限（秒），在 Codex 啟動前寫出的紀錄初稿就有值，執行中即可讀取。

每次嘗試的檔案位於 `<report_line_root>\runs\`：輸出目錄 `<runKey>\`、`<runKey>.record.json`、`<runKey>.events.jsonl`、`<runKey>.stderr.txt`、`<runKey>.last-message.md`。

## 等待與終止

- 事件流與 stderr 在執行中即時寫入檔案，可以在執行中讀取進度。
- 超過總時限（`-TimeoutSeconds`）時，入口終止整棵 Codex 行程樹，結果為 `failed`，`failure_reason` 為 `timeout`，執行紀錄的 `terminated_by_entry` 為 `timeout`。
- 事件流的最後一個事件為 `turn.completed` 且最後訊息檔非空之後，Codex 行程 60 秒內仍未結束時，入口終止行程樹，執行紀錄的 `terminated_by_entry` 為 `after-turn-end`。結果依報告判定，與正常結束相同，報告存在且格式合格即為成功，不需要重跑。
- 行程由入口終止時，執行紀錄的 `exit_code` 是終止所致的值，不作為判定依據。

## 沙盒內的 git

入口對 Codex 行程設定 `GIT_CONFIG_GLOBAL=NUL` 與 `GIT_CONFIG_NOSYSTEM=1`，沙盒內的 git 不讀全域與系統設定。沙盒不授權使用者家目錄的 `.gitconfig`，未設定時 git 在讀取設定檔時整個失敗。

沙盒不允許行程切換到唯讀目錄，因此需要工作樹的命令不可用，與設定檔無關。

| 可用 | 不可用 |
| --- | --- |
| `git rev-parse`、`git log`、`git show`、`git diff <rev> <rev>`、`git diff --cached`、`git ls-files -m -o --exclude-standard`、`git ls-tree` | `git status`、`git diff`（比對工作樹）、`git diff HEAD` |

需要工作樹狀態時，用 `git ls-files -m -o --exclude-standard` 列出已修改與未追蹤的檔案，用 `git diff --cached --name-status HEAD` 列出已暫存的變更，再以 `git ls-tree --name-only HEAD -- <path>` 判定 HEAD 是否有該路徑。HEAD 有者以 `git show HEAD:<path>` 與直接讀取的檔案內容比對，HEAD 沒有者（已暫存新增、重新命名後的新路徑、未追蹤）不執行 `git show`，整份讀取檔案。Reviewer 的盤點步驟見 `agents/codex/reviewer.toml`「啟動流程」第 5 點。

`git ls-files --exclude-standard` 與 `git diff --cached` 在沙盒內會於 stderr 印出無法存取使用者層級 git 設定的 warning，結束碼仍為 0，以結束碼判定成敗。

## 回收

回收分兩步。先判定這份報告能不能用，再依報告的審查結論決定下一站。

### 報告是否可用

依序核對下列各項，全部成立為「收下」。

1. 讀 `final.report_path` 的報告全文，確認報告含派遣檔 `## 回報必備欄位` 要求的各節，且 `## 總覽` 第一行的審查者與實際執行者相符。
2. 確認 `final.review_report_check.valid` 為 `true`。
3. 確認 `final.source_changed` 為 `false`。
4. 逐條核對派遣檔 `## 驗收條件`：報告對每一條都有判定，判定引用的檔案與行號存在，且內容支持該判定。只在判定與引用內容不一致、引用位置不存在，或該條涉及需求摘要的已確定實作約束時，才實讀來源複核。

任一項不成立時依下表處置。

| 情形 | 判定 | 處置 |
| --- | --- | --- |
| 報告缺節、`review_report_check.valid` 為 `false`、驗收條件缺判定或引用無法定位 | 退回 | 以同一份派遣檔重跑，並在 `## 任務` 補一行指出上一份報告缺少的部分。`errors` 會指出不合格的 finding 與欄位 |
| `source_changed` 為 `true`，改動來自本 Session | 退回 | 停止改動目標後重跑 |
| `source_changed` 為 `true`，改動來源不明 | 升級 | 回報使用者，不採用該報告 |
| 報告指出設計歧義，或判定需要改變需求摘要與已確認設計 | 升級 | 交同線 `Analyst` 依需求摘要原文裁決，裁決不了時交使用者 |

### 收下後的處理

收下當下先執行下列兩步，不論審查結論為何。

1. 把報告 `## 例外回報` 節的條目併入同線 `<work-root>/.local/ai-sessions/report/<lineSlug>/exceptions.md`。
2. 把報告複製為同線 `<work-root>/.local/ai-sessions/report/<lineSlug>/<report_name>`，覆寫既有檔。同線後續 Session、需求意圖驗收與下一輪派遣檔的 `required_reads` 都使用這個路徑。

再依報告「總覽」的結論行與 manifest `findings` 決定下一站。結論行與 manifest 不一致時以 manifest 為準，並把不一致記入回收紀錄。

| 審查結論 | 下一站 |
| --- | --- |
| `fail`：`status=open` 的 finding 含 `Critical` 或 `Major` | 依共同收斂契約退回實作者修正，修正後以下一輪派遣檔複審。修正派生的處置表見 `workflow-orchestration` skill `references/review-procedures.md` |
| `pass`，仍有 `status=open` 的 `Minor` | 不再複審。依共同收斂契約判定順序 1，一次批次修正或記為候選 |
| `pass`，沒有 `open` 的 finding | 進入需求意圖驗收 |

## 帳號

- 入口依登記順序選第一個可用帳號。已登入、該檔位的設定檔存在，且檔位的主要 model 或任一備援 model 未被記為該帳號不支援，三項都成立才算可用。全部帳號都被記為不支援時，入口取記錄時間最早的帳號以主要 model 實際嘗試一次。
- 備援 model 取自登錄表該檔位的 `profileSettings.fallbackModels`。帳號的主要 model 已被記為不支援時，入口以 `-c model=<備援 model>` 改用第一個未被記為不支援的備援 model，其餘設定沿用檔位設定檔。
- 服務端拒絕且尚無任何進度時，拒絕原因為 model not supported 者改試同一帳號的下一個 model，其餘原因改試下一個帳號。同一帳號的同一個 model 不重送。
- 拒絕原因為未授權時，PowerShell 版重新登入命令原文轉給使用者。命令在結果 JSON 的 `attempts[].relogin_command`（每次嘗試各一個）與 `final.relogin_command`（最後一次嘗試），其餘嘗試為 `null`，stderr 不輸出。
- 帳號因登入檔缺少或為空而被略過時，分兩種情形。全部帳號都被略過、結束碼為 4 時，含重新登入命令的略過摘要寫在 `error.message`，stderr 輸出同一則訊息，命令原文轉給使用者。仍有可用帳號時，入口只在 stderr 列出被略過帳號的名稱與原因代碼，沒有重新登入命令，結果 JSON 的 `attempts` 與 `final` 也只含實際嘗試的帳號。
- 結束碼 4 且 `error.code` 為 `CodexAccountsAllUnavailable` 或 `CodexAccountsExhausted` 時，入口已以該檔位的執行者離線呼叫選派入口，結果在 `fallback`：`unavailable_executor` 是不可用的執行者 id，`selection` 是選派入口的輸出原文。以 `selection.dispatchLine` 作為判定行，依 `selection.status` 與 `executor-selection` skill「狀態處置」處置；選出 Claude 執行者時沿用同一份派遣檔，依 `workflow-orchestration` skill `references/review-procedures.md`「Claude 審查者的發動」派出。`fallback` 為 `null` 時，改以 `-Offline <執行者 id>` 手動呼叫選派入口。入口不保存不可用的狀態，下一次新的派工照常先選 Codex。
- 選定帳號後、啟動 Codex 前，入口只讀比對實際要使用的帳號目錄內該檔位的設定檔與主 checkout（`machine.json` 所在 repo）的產生檔（內容相同，CRLF 與 LF 視為相同；若是連結必須指向該產生檔），並確認產生檔等於登錄表預期內容。不一致時以結束碼 2、`CodexProfileDrift` 停止，不改檔，不跳到下一個帳號。換帳號後對新的候選帳號在使用前同樣比對，未使用的候選帳號不一致不阻擋。檔位設定檔的來源是登錄表 `profileSettings`，產生與連結方式見 README §3「Codex profile 檔位設定」。
- 入口不做專案信任預檢，也不自動補信任。

## 成本列

入口在每次嘗試結束時對同線 `cost-ledger.md` 追加一列 `事件`，含被服務端拒絕而沒有用量的嘗試。成本列寫入失敗（結束碼 1、`stopped`）時該次嘗試沒有成本列。一條線的成本以 `scripts/Get-LineCost.ps1` 計算。帳號與拒絕種類寫在備註欄，格式為 `exit=…;result=…;task=…;account=…;rejection=…;usage=…`。協調者不需為這些嘗試手寫列。

## 重跑

重跑使用同一份派遣檔與同一個 `dispatch_slug`，入口以時間戳與隨機碼區分每次執行，不會覆寫前一次的輸出。逾時的執行已由入口終止並寫入結果，直接重跑。主 Agent 手動終止背景命令時，執行紀錄沒有結束時間，不影響下一次發動。

## 切回現行入口

把登錄表 `codex-review` 的 `entry` 改回 `scripts/Invoke-CodexDispatch.ps1` 後，選派結果即指向現行入口。現行入口的 Collect 檢查的是舊格式的審查報告，`reviewer.toml`、`frontend-reviewer.toml` 與 `contract-auditor.toml` 目前只產出新格式，切回時需一併還原三份的報告格式。
