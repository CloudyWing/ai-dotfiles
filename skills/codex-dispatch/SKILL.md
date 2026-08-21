---
name: codex-dispatch
description: 'Codex 派工機制：依派工類型建立執行契約、啟動 Codex、等待事件流、取證並回收結果。當需要發動 codex、撰寫派遣單或執行派遣回收判定時使用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Codex 派工機制

本 Skill 負責派工的執行機制。是否派工由 `instructions.md` §1.5 的路由規則判定，本 Skill 只處理指令、落點、等待、取證、續 session 與回收。

## 執行前提與可用性檢查

派工前確認目前 session 能執行本地命令，並確認 `codex` 可由 `PATH` 解析。執行下列命令取得版本並檢查啟動環境。

```powershell
codex --version
```

`codex --version` 失敗時，先回報執行檔不存在或設定載入失敗的具體訊息。版本檢查失敗不等同派工工作失敗，需先處理執行環境問題。

| Session 型態 | 派工能力 | 處置 |
| --- | --- | --- |
| Desktop Code tab、VS Code 擴充、CLI、SSH 或 WSL 的 local session | 可發動 | 依本 Skill 的指令契約執行 |
| Dispatch 對話本身或 cloud session | 不可發動 | 明確回報「當前 session 不載入全域規則，請於 local Code session 發動」，不嘗試執行 `codex` |
| Dispatch 派生的 local Code session | 可發動 | 依本 Skill 的指令契約執行 |

派工命令執行前由主 Agent 準備 `<work-root>/.local/ai-sessions/history/` 與 `<work-root>/.local/ai-sessions/report/`。這是主 Agent 的事件流與報告落點前置作業，不屬於 Codex 子工作。唯讀派遣的 Codex 子工作不得建立或修改 `history/` 目錄；第 7 欄報告檔與 `<work-root>/.local/ai-sessions/report/exceptions.md` 依第 6 欄的明文寫入例外處理。若主 Agent 無法完成前置作業，停止啟動並回報缺件。重導向與 `--output-last-message` 不會建立父目錄，目錄缺少時 shell 會先失敗。

## 指令契約

正式啟動使用 `codex exec`，沿用既有 session 使用 `codex exec resume`。實際父層選項位置依下方範例執行。

`<work-root>`、`<slug>` 與各輸出檔案路徑都使用絕對路徑。`<slug>` 限用小寫英數與連字號，且在同一個 `<work-root>` 內不得重複。事件流檔名使用時間戳，不另外加入 slug。

一般派工使用下列契約。若工作需要網路查證，將 `--search` 放在 `exec` 前方的父層選項位置。

以下正式派工的 `bash` 範例適用於 Bash 或 WSL。Bash 使用反斜線作為行接續，使用 `>` 與 `2>&1` 將標準輸出與錯誤輸出合併，並在命令末尾加上 `&` 以背景執行。

Windows PowerShell 不使用反斜線作為行接續，改用反引號。PowerShell 的 `Start-Process` 可啟動背景程序，標準輸出與錯誤輸出分別使用 `-RedirectStandardOutput` 與 `-RedirectStandardError`，再使用 `Wait-Process` 等待完成。兩個輸出檔應分開保存，避免將兩個串流指定到同一個檔案。

```bash
codex \
  --cd "<work-root>" \
  --sandbox workspace-write \
  --add-dir "<work-root> 外的寫入落點" \
  --search \
  exec \
  --json \
  --output-last-message "<work-root>/.local/ai-sessions/history/codex-last-message-<yyyyMMdd_HHmmss>.md" \
  "<prompt>" \
  > "<work-root>/.local/ai-sessions/history/codex-exec-<yyyyMMdd_HHmmss>.jsonl" 2>&1 &
```

Windows PowerShell 等價寫法如下。

```powershell
$workRoot = "<work-root>"
$historyDir = Join-Path $workRoot ".local\ai-sessions\history"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$lastMessagePath = Join-Path $historyDir "codex-last-message-$timestamp.md"
$eventStreamPath = Join-Path $historyDir "codex-exec-$timestamp.jsonl"
$errorStreamPath = Join-Path $historyDir "codex-exec-$timestamp.stderr.log"
$prompt = "<prompt>"

$process = Start-Process -FilePath "codex" `
  -ArgumentList @(
    "--cd", $workRoot,
    "--sandbox", "workspace-write",
    "--add-dir", "<work-root> 外的寫入落點",
    "--search",
    "exec",
    "--json",
    "--output-last-message", $lastMessagePath,
    $prompt
  ) `
  -RedirectStandardOutput $eventStreamPath `
  -RedirectStandardError $errorStreamPath `
  -PassThru

$process | Wait-Process
```

沒有網路需求時省略 `--search`。沒有 work-root 外寫入落點時省略 `--add-dir`。參數職責如下。

| 參數 | 用途 |
| --- | --- |
| `--cd` | 指定 Codex 執行時的工作根目錄 |
| `--sandbox` | 指定執行權限。寫入型派工使用 `workspace-write`，唯讀查證使用 `read-only` |
| `--add-dir` | 授權 work-root 以外的必要寫入落點 |
| `--search` | 啟用 Codex 的網路查證能力，位置必須在 `exec` 前方 |
| `--json` | 將事件流輸出為 JSON Lines |
| `--output-last-message` | 將最後一則訊息寫入獨立檔案，供事件流無法落地時回退取證 |
| `>` | 將事件流導向 `history/codex-exec-<yyyyMMdd_HHmmss>.jsonl` |

`--cd`、`--sandbox`、`--add-dir` 與 `--search` 都是 `codex` 的父層選項。它們必須放在 `exec` 或 `exec resume` 前方。`--output-last-message` 屬執行子命令的選項，放在 `exec` 後方。

Prompt 至少包含下列元素，缺一即視為契約未滿足。

1. 執行角色的觸發詞或 skill 名稱。Workflow 派工使用 `Implement` 的觸發詞；資源派遣使用派遣單第 2 欄指定的角色或 skill。
2. Workflow 派工使用 `design.md` 的絕對路徑，資源派遣使用派遣單的絕對路徑。
3. `<work-root>` 的絕對路徑。
4. 回報格式、產出落點與驗收條件。Workflow 派工另須要求結案報告包含輪起點 SHA、開工基準線、輪終點 commit，以及「判定為既有實作而未動工」節。續 session 必須重述前輪該節的全部條目。

## 模型檔位規則

`burn` 與 `deep` 是兩條獨立軸線。

- `burn` 用於額度充裕時加速日常的大批量標準化編輯。
- `deep` 用於需要自行找路、步驟未明確的高難度任務。

實際 model id 與 effort 只存在於 `~/.codex/<檔位名稱>.config.toml`。本 Skill 只使用 `burn` 與 `deep` 這兩個白名單名稱。未指定 `-p` 時使用預設省用檔位。規則不得自行加入 `-p`。

### 額度快照

`codex usage` 是 TUI，需要真實終端機。主 Agent 在非互動環境無法執行，實測 Bash 與 PowerShell 皆回傳 `stdin is not a terminal`。因此由使用者在終端機執行後提供兩個數字，剩餘額度百分比與距離重置天數。快照當天有效，隔日沒有新快照時一律使用預設省用檔位。

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

### 大輪後快照失效

單輪派工達大任務標準時，該輪結束後先前快照即失效。下一輪需新的數字才能再升級。

Codex 遇到不存在的 profile 可能靜默回退預設值並以成功結束。執行前確認名稱只使用白名單，結束後以實際事件流與產出驗證結果判定，不以 exit code 單獨推論檔位已生效。

## 背景執行與三出口等待

主 Agent 以背景方式執行 `codex exec`，持續觀察背景指令狀態與事件流檔案大小。事件流檔案大小是執行中的唯一可觀測存活訊號。

| 出口 | 判定條件 | 後續動作 |
| --- | --- | --- |
| A 正常結束 | 背景指令已離開執行狀態，且事件流最後一則事件的 `type` 為 `turn.completed` | 進行事件流取證，再執行回收判定 |
| B 停滯 | 背景指令仍在執行，事件流檔案大小連續 20 次輪詢未增加。每次間隔 30 秒，合計 10 分鐘 | 停止等待，回報最後一則事件的 `type` 與時間，交由使用者決定續等或中止 |
| C 早夭 | 背景指令已離開執行狀態，且事件流最後一則事件的 `type` 不是 `turn.completed` | 事件流含 `agent_message` 時取最後一則作為未完成回報，依 F1 與回收三態判定，不視為正常結束；沒有 `agent_message` 時讀取事件流末尾錯誤文字並回報啟動失敗 |

只以報告檔是否出現作為終止條件，無法區分 Codex 中途崩潰與仍在執行。出口 B 使用檔案大小停滯作為停止依據。

## 事件流取證

`--json` 事件流是 append-only 的 JSON Lines。每則助理輸出對應 `item.completed` 事件，格式如下。

```json
{"type":"item.completed","item":{"id":"item_68","type":"agent_message","text":"# 派工結案報告\n..."}}
```

thread id 事件格式如下。

```json
{"type":"thread.started","thread_id":"01a01619-fbef-7ee2-aea3-39598e04388e"}
```

由後往前掃描事件流，取最後一則符合目前派工類型的 `agent_message`。Workflow 派工取同時包含「驗證證據」與輪起點 SHA、開工基準線、輪終點 commit 三欄的訊息，寫入 `report/implement-closure-report.md`。資源派遣取符合派遣單第 8 欄要求的訊息，寫入派遣單第 7 欄指定的落點。

主 Agent 將 `thread.started` 的 `thread_id` 寫入 `<work-root>/.local/ai-sessions/history/codex-thread-<slug>.txt`，續 session 先讀取該檔。

取證失效時依下列狀態處理。

- F1。事件流中沒有符合條件的結案訊息。判定必要欄位缺失，Workflow 派工依續 session 契約補齊；資源派遣依回收三態判定為未達成驗收條件。
- F2。事件流沒有落地。回退讀取本輪 `history/codex-last-message-<yyyyMMdd_HHmmss>.md`，並在回報中標示取證來源為 last-message 檔。
- F3。事件流含多則符合條件的訊息。取最後一則，並以其輪終點 commit 或回報欄位作為最新值。

事件流、thread id 與 last-message 檔都保留於 `history/`，直到回收判定完成。`history/` 不屬於自動清理範圍。

## 續 session 與跨介面接手

若需要補齊欄位或修正純技術驗收問題，依上一輪事件流的 `thread.started` 事件取得 `<thread-id>`，再使用同一 session 續行。

以下 `bash` 範例適用於 Bash 或 WSL。Bash 使用反斜線作為行接續；需要背景執行時在命令末尾加上 `&`，需要記錄標準輸出與錯誤輸出時使用 `>` 與 `2>&1`。

Windows PowerShell 使用反引號作為行接續。使用 `Start-Process` 背景執行 `exec resume`，以 `-RedirectStandardOutput` 與 `-RedirectStandardError` 分開保存輸出，再使用 `Wait-Process` 等待完成。

```bash
codex \
  --cd "<work-root>" \
  --sandbox "<sandbox-mode>" \
  --add-dir "<work-root> 外的寫入落點" \
  exec resume "<thread-id>" \
  --json \
  -o "<work-root>/.local/ai-sessions/history/codex-last-message-<yyyyMMdd_HHmmss>.md" \
  "<prompt>"
```

Windows PowerShell 等價寫法如下。

```powershell
$workRoot = "<work-root>"
$historyDir = Join-Path $workRoot ".local\ai-sessions\history"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$lastMessagePath = Join-Path $historyDir "codex-last-message-$timestamp.md"
$eventStreamPath = Join-Path $historyDir "codex-exec-resume-$timestamp.jsonl"
$errorStreamPath = Join-Path $historyDir "codex-exec-resume-$timestamp.stderr.log"
$prompt = "<prompt>"

$process = Start-Process -FilePath "codex" `
  -ArgumentList @(
    "--cd", $workRoot,
    "--sandbox", "<sandbox-mode>",
    "--add-dir", "<work-root> 外的寫入落點",
    "exec", "resume", "<thread-id>",
    "--json",
    "-o", $lastMessagePath,
    $prompt
  ) `
  -RedirectStandardOutput $eventStreamPath `
  -RedirectStandardError $errorStreamPath `
  -PassThru

$process | Wait-Process
```

`exec resume` 不接受父層選項。`--cd`、`--sandbox` 與 `--add-dir` 必須放在 `exec resume` 前方，`-o` 放在子命令後方。需要網路查證時，將 `--search` 加在 `exec resume` 前方。

`<sandbox-mode>` 必須沿用原派工的 sandbox 邊界。當派遣單包含第 7 欄報告檔或 `<work-root>/.local/ai-sessions/report/exceptions.md` 的明文寫入例外時，沿用足以寫入該落點的 sandbox 模式；除此以外不得修改目標物件、執行建置與測試或建立 commit。續 session 不得擴大其他寫入範圍或提高 sandbox 權限。

讀不到 thread id 檔案時開新 session，並在 prompt 附上設計文件與退回報告的絕對路徑。跨介面接手視為新 session，依序讀取下列交接物重建狀態。

1. `<work-root>/.local/ai-sessions/handoff/design.md`。
2. `<work-root>/.local/ai-sessions/handoff/requirement-summary.md`。
3. 本輪 `history/codex-exec-<yyyyMMdd_HHmmss>.jsonl`。
4. 事件流取證產生的 `report/implement-closure-report.md` 或派遣單第 7 欄指定報告。

## sandbox 外環境動作

需要網路或 work-root 外環境變更的工作，由主 Agent 在派工前代執行。代執行前必須取得使用者當輪明確同意。非互動情境無法取得當輪同意時停止並回報缺件。

代執行後追加 `<work-root>/.local/ai-sessions/report/exceptions.md`，觸發類型使用「偏離設計」，並記錄外環境動作、同意依據與位置。不得以開放 sandbox 網路取代 `--search`，也不得把 shell 出網工作直接派給 Codex。

## 網路能力硬邊界

`--search` 是 Codex 的唯一上網路徑，且必須放在 `exec` 或 `exec resume` 前方。Codex shell 無法以 `curl` 或其他一般 shell 工具出網；開啟 sandbox network access 也不代表 shell 查證可用。

下列工作需要 shell 出網，應由 Claude 端依外環境動作規則處理，或先取得使用者當輪同意後由主 Agent 代執行。

- `npm install`。
- `git fetch`。
- 下載檔案或套件。

事實查核類派遣必須啟用 `--search`。未啟用時，Codex 可能無法取得資料而改以記憶作答。

## 兩種派工差異

共用本 Skill 的機制。Workflow 派工與資源派遣只以輸入、產出與結案要求區分。

| 面向 | Workflow 派工（`Implement`） | 資源派遣（`Review`、`Engineer`、其餘一切） |
| --- | --- | --- |
| 必備輸入 | `<work-root>/.local/ai-sessions/handoff/design.md` 絕對路徑 | `<work-root>/.local/ai-sessions/handoff/dispatch-order-<slug>.md` 派遣單絕對路徑 |
| 產出落點 | `<work-root>/.local/ai-sessions/report/implement-closure-report.md` | `<work-root>/.local/ai-sessions/report/dispatch-report-<slug>.md` |
| 結案要求 | 「驗證證據」節的輪起點 SHA、開工基準線、輪終點 commit 三欄皆有值 | 逐條執行派遣單第 5 欄的判定方式，得出本 Skill 的「收下」、「退回」或「升級」之一 |

## 派遣單契約

資源派遣使用 Markdown 派遣單，路徑為 `<work-root>/.local/ai-sessions/handoff/dispatch-order-<slug>.md`。`<slug>` 限用小寫英數與連字號，同一個 `<work-root>` 內不得重複。八個欄位全部必填，缺少任一欄即視為契約未滿足。

| # | 欄位 | 內容要求 |
| --- | --- | --- |
| 1 | 任務標題 | 一句話，含動詞 |
| 2 | 執行角色 | Codex 端 Agent 觸發詞，例如「值班工程師」或 `review`，也可填 skill 名稱，例如 `fact-check-note` |
| 3 | 目標物件 | 檔案、目錄或端點的絕對路徑，逐項列出 |
| 4 | 任務內容 | 含動詞與具體對象，不使用「處理 X」或「改善 Y」等無法驗收的描述 |
| 5 | 驗收條件 | 以表格逐列提供條件與判定方式 |
| 6 | 邊界 | 列出不得改動的範圍。「唯讀」定義為不得修改目標物件、不得執行建置與測試、不得建立 commit；派遣單第 7 欄的報告檔與 `<work-root>/.local/ai-sessions/report/exceptions.md` 為所有派遣共用的明文寫入例外。需要完全不寫入任何檔案的任務，另用「不產生任何檔案寫入」描述。 |
| 7 | 產出落點 | 報告或產物的絕對路徑 |
| 8 | 回報必備欄位 | Codex 端回報必須出現的欄位清單 |

第 5 欄的每條判定方式必須是第三方可執行的命令或機械檢查動作。格式如下。

```markdown
| # | 驗收條件 | 判定方式 |
| --- | --- | --- |
| <n> | `<絕對路徑>` 存在且非空 | Read 該檔確認內容非空 |
| <n> | 報告含「校閱時間」欄位且格式為 `YYYY-MM-DD HH:mm` | Grep `^- \*\*校閱時間\*\*：` |
```

## 回收三態判定

背景指令結束後，主 Agent 讀取派遣單第 7 欄的產出落點，依第 5 欄逐條執行判定方式。主 Agent 不以 Codex 端回報中的自述取代實際判定。派遣單第 8 欄必須要求 Codex 端逐條回報每條驗收條件的命令原文與完整輸出。主 Agent 以抽驗方式複核回報內容，對輸出與結論不一致的條件逐條重跑。回報只寫「已完成」而未附命令輸出者，該條計為未成立。

| 判定 | 成立條件 | 後續動作 |
| --- | --- | --- |
| 收下 | 產出落點檔案存在且非空，全部驗收條件逐條成立 | 進入 Claude 端整合，派遣結束 |
| 退回 | 任一驗收條件不成立，且原因屬純技術可解，例如格式不符、欄位缺漏、範圍溢出第 6 欄或未執行判定方式 | 依續 session 契約 resume，附未達成條件清單。退回上限 2 次 |
| 升級 | 原因命中 `instructions.md` §1.5 升級兩道篩的三類拍板判準，或退回已達 2 次仍不成立 | 停止派遣，依「遇真問題全停」升級使用者拍板 |

回報寫明「已完成」而判定方式未實際執行時，該條仍計為未成立。派遣報告固定寫入 `<work-root>/.local/ai-sessions/report/dispatch-report-<slug>.md`，除非派遣單第 7 欄指定其他產出落點。
