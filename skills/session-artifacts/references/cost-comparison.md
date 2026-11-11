# 降本成效比對方法

本檔定義如何比較收斂規則調整前後的審查循環輪數與成本，用來判斷共同收斂契約的調整是否減少修正加複審的輪數。資料來源 `cost-ledger.md` 的列格式見 `../SKILL.md`「需求級成本累計」。

## 適用範圍

- M1、M1u 計入 Codex 派遣的 `事件` 列與 Claude subagent 路徑的 `事件（手寫）` 列中 `cycle_role=review` 者。
- M2、M3 只計 Codex 派遣的 `事件` 列。`事件（手寫）` 列另列一行 Claude subagent token 合計，不併入 M2 的分子分母，因為兩者計量單位不同。
- M4 只計 `事件（手寫）` 列中 `cycle_role=fix` 者，與 M2 分開呈現。

## 名詞

- 審查循環：同一 `lineSlug` 下同一 `cycle_id` 的全部 `cycle_role=review` 列。
- 實作循環：同一 `lineSlug` 下同一 `cycle_id` 的全部 `cycle_role=fix` 列。
- run 的 input：usage 的 `input_tokens`，含 cached 部分。

## 指標

| 指標 | 定義 |
| --- | --- |
| M1 | 每個審查循環的輪數，取該循環 `cycle_round` 的最大值；各循環取中位數。輪數是流程事實，納入全部列，不要求有 usage。此為主要口徑 |
| M1u | 每個審查循環中有 usage 的不重複輪次數；各循環取中位數。只作輔助，用來檢查 M1 與 M2 的樣本是否一致 |
| M2 | 第 2 輪以上占 Reviewer input 的比例，等於有 usage 的 Codex 審查 run 中 `cycle_round>=2` 的 input 總和除以全部 input 總和，跨循環合併；另列各循環個別比例 |
| M3 | usage 覆蓋率，等於有 usage 的 `事件` 列數除以 `事件` 列數，新舊兩組分別列出 |
| M4 | 每個實作循環的輪數，取該循環 `cycle_round` 的最大值；各循環取中位數。基準期的實作由 Codex Developer 承接，輪次定義與 Claude subagent 列不可比，M4 只列新資料，不與舊組比較 |

## 新資料算法

1. 讀取各線 `report\<lineSlug>\cost-ledger.md` 中 `<!-- cost-ledger.v2 -->` 標記之後的表格，取 `列類型` 為 `事件` 或 `事件（手寫）` 的列，以 `lineSlug` 加 `runId` 去重。
2. 篩選 `cycle_id` 不是 `-` 的列計算 M1、M1u、M2、M4。`cycle_id` 為 `-` 的 `事件` 列計入 M3 分母，並在結果中列為「未標記」。
3. `input` 欄為 `-` 的列視為無 usage。
4. 核對數字時，取該 run 事件流最後一筆 `turn.completed.usage`，續行 run 再減去錨點 run 的同一值（口徑見「口徑說明」）。備註 `usage_basis=cumulative-no-anchor` 的續行列是累計值，計入 M2 前先標出。事件流路徑取 RunRecord 的 `event_stream_path`；該路徑已不存在時，把它相對於 RunRecord `execution_root` 的部分接到 `source_root`，即 Cleanup 保存的副本。
5. 依「指標」計算 M1、M1u、M2、M3、M4。

下列程式區塊承載上述算法，`-LedgerRoot` 為含 `report\` 的 `.local\ai-sessions` 目錄。可存成暫存檔執行，例如 `pwsh -NoProfile -File <暫存檔> -LedgerRoot '<work-root>\.local\ai-sessions'`。

<!-- new-data-snippet -->

```powershell
param([Parameter(Mandatory)][string]$LedgerRoot)
$ErrorActionPreference = 'Stop'
function Get-Median([double[]]$Value) {
    $s = @($Value | Sort-Object)
    $n = $s.Count
    if ($n -eq 0) { return $null }
    if ($n % 2) { return $s[[int][math]::Floor($n / 2)] }
    return ($s[$n / 2 - 1] + $s[$n / 2]) / 2
}
function Get-Sum([object[]]$Row) {
    $total = 0.0
    foreach ($r in $Row) { $total += [double]$r.Input }
    return $total
}
$ledgers = @(Get-ChildItem -Path (Join-Path $LedgerRoot 'report') -Filter 'cost-ledger.md' -Recurse -File)
$rows = foreach ($f in $ledgers) {
    $inV2 = $false
    foreach ($line in Get-Content -LiteralPath $f.FullName -Encoding UTF8) {
        if ($line -match '<!-- cost-ledger\.v2 -->') { $inV2 = $true; continue }
        if (-not $inV2 -or $line -notmatch '^\| ') { continue }
        $c = @(($line.Trim().Trim('|') -split '(?<!\\)\|') | ForEach-Object { $_.Trim() })
        if ($c.Count -lt 14 -or $c[1] -notin @('事件', '事件（手寫）')) { continue }
        [pscustomobject]@{ Line = $f.Directory.Name; Kind = $c[1]; RunId = $c[4]; CycleId = $c[5]; Round = $c[6]; Role = $c[7]; Input = $c[10]; Note = $c[13] }
    }
}
$unique = @($rows | Sort-Object Line, RunId -Unique)
$review = @($unique | Where-Object { $_.Role -eq 'review' -and $_.CycleId -ne '-' })
$m1 = @(); $m1u = @()
foreach ($g in @($review | Group-Object Line, CycleId)) {
    $m1 += (@($g.Group | ForEach-Object { [int]$_.Round }) | Measure-Object -Maximum).Maximum
    $u = @($g.Group | Where-Object { $_.Input -ne '-' } | ForEach-Object { [int]$_.Round } | Sort-Object -Unique).Count
    if ($u -gt 0) { $m1u += $u }
}
$codex = @($review | Where-Object { $_.Kind -eq '事件' -and $_.Input -ne '-' })
$all = Get-Sum $codex
$r2 = Get-Sum @($codex | Where-Object { [int]$_.Round -ge 2 })
"M1 median = $(Get-Median $m1) over $($m1 -join ',')"
"M1u median = $(Get-Median $m1u) over $($m1u -join ',')"
if ($all -gt 0) { "M2 combined = $([math]::Round($r2 / $all * 100, 2))%" } else { 'M2 combined = 無 usage' }
foreach ($g in @($codex | Group-Object Line, CycleId)) {
    $t = Get-Sum $g.Group
    $t2 = Get-Sum @($g.Group | Where-Object { [int]$_.Round -ge 2 })
    "M2 $($g.Name) = $([math]::Round($t2 / $t * 100, 2))%"
}
$noAnchor = @($codex | Where-Object { $_.Note -match 'usage_basis=cumulative-no-anchor' })
"M2 含累計口徑的續行列 = $($noAnchor.Count)（runId：$(@($noAnchor | ForEach-Object { $_.RunId }) -join ',')）"
$events = @($unique | Where-Object { $_.Kind -eq '事件' })
$unmarked = @($events | Where-Object { $_.CycleId -eq '-' }).Count
"M3 = $(@($events | Where-Object { $_.Input -ne '-' }).Count)/$($events.Count)（未標記 $unmarked 列）"
$fix = @($unique | Where-Object { $_.Kind -eq '事件（手寫）' -and $_.Role -eq 'fix' -and $_.CycleId -ne '-' })
$m4 = @()
foreach ($g in @($fix | Group-Object Line, CycleId)) { $m4 += (@($g.Group | ForEach-Object { [int]$_.Round }) | Measure-Object -Maximum).Maximum }
"M4 median = $(Get-Median $m4) over $($m4 -join ',')"
$claude = @($unique | Where-Object { $_.Kind -eq '事件（手寫）' -and $_.Input -ne '-' })
"Claude subagent token 合計 = $(Get-Sum $claude)（不併入 M2）"
```

M3 的分母含 `cycle_id` 為 `-` 的 `事件` 列。

## 舊資料（基準）算法

基準使用下節的基準鏈。輪次取自各報告的 manifest `round`，input 取自 `C:\Users\CloudyWing\.ai-agents\.local\ai-sessions\report\dispatch-cost-ledger\raw\runs.csv`（排除 `is_fixture=True`）中 `line_slug` 與 `dispatch_slug` 對應的列，只計 `usage_available=True` 的列，同一 slug 有多個 run 時加總。歷史派遣不回填 `cycle_*` 欄位或 usage，基準只以本節算法計算。

## 比較規則

- 每組至少 3 個審查循環才下結論，不足時只列數字並標「樣本不足」。
- 兩組的 M3 差距超過 20 個百分點時，在結論旁標示 usage 覆蓋不對等。
- 新組的 `事件（手寫）` 列另列 Claude subagent token 合計，與 M2 分開呈現。
- M2 的母體是基準鏈的審查 run，與成本分析「Reviewer 有 77% 的 input 花在第 2 輪以上」的母體（全部 Reviewer run）不同，兩個數字不互相比較。

## 基準鏈

來源為 `C:\Users\CloudyWing\.ai-agents\.local\ai-sessions\report\dispatch-report-redo-cause-scan-2.md`「Q1 實際輪數」與逐次證據表，資料截止 2026-11-01。

| 鏈 | lineSlug | 輪數（manifest `round`） | slug 與輪次對應 | 輪次來源 |
| --- | --- | ---: | --- | --- |
| schema-ai-integration | `schema-ai-integration` | 9 | `review-schema-ai-integration`=1、`-r2`=2、`-r3`=3、`-r4`=4、`-r5b`=5、`-r6`=6、`-r7`=7、`-r8`=8、`-r9`=9；`-r5` 無有效報告不計 | 各 `dispatch-report-<slug>.md` 的 manifest |
| codex-account-setup | `codex-account-setup` | 10 | `reviewer-codex-account-setup-2` 至 `-11` 依序為 1 至 10；無後綴 slug 報告缺失不計 | 同上 |
| c16-move | `rule-architecture-rebuild` | 10 | `reviewer-c16-move1`=1、`reviewer-c16-move1-2` 至 `-9` 為 2 至 9、`reviewer-c16-move2-1`=10 | 同上 |
| backlog-batch-3 | `backlog-batch-3` | 11 | `reviewer-batch-3b`=1、`3d`=2、`3e`=3、`3g`=4、`3i`=5、`3j`=6、`3q`=7、`3s`=8、`3w`=9；第 10、11 輪無對應 usage | `report\backlog-batch-3\review-report-round1.md` 至 `round11.md` 的 manifest |
| batch4-p1b | `rule-architecture-rebuild` | 6 | `reviewer-batch4-p1b-1` 至 `-6` 對應 `review-report-batch4-p1b-r1.md` 至 `r6.md` | `report\rule-architecture-rebuild\` 同名報告；r7 與 r6 狀態不相連，不計 |

`reviewer-batch`（推導 22 輪）與 `reviewer-batch4-p`（推導 19 輪）是混有多個對象的 slug 基名，已拆成各對象，最長連續鏈即上表 batch4-p1b，不另列入。

## 基準快照

資料截止 2026-11-01，依「舊資料（基準）算法」重算。

| 指標 | 值 |
| --- | --- |
| M1 | 中位數 10（9、10、10、11、6） |
| M1u | 中位數 9（有 usage 的輪次數 9、9、10、9；batch4-p1b 無 usage 排除） |
| M2（4 條鏈合併） | 91.48%（第 1 輪合計 31,562,832，全部 370,316,922） |
| M2 各鏈 | schema-ai-integration 92.08%、codex-account-setup 87.58%、c16-move 90.92%、backlog-batch-3 92.91% |
| M3 | schema-ai-integration 9/9、codex-account-setup 9/10、c16-move 10/10、backlog-batch-3 9/9（僅計表列 slug）、batch4-p1b 0/6 |

2026-11-10 以下列命令重算，pwsh 7 與 Windows PowerShell 5.1 輸出相同，exit code 0。

```text
pwsh -NoProfile -File <暫存檔> -RunsCsv 'C:\Users\CloudyWing\.ai-agents\.local\ai-sessions\report\dispatch-cost-ledger\raw\runs.csv'

chain                  rounds usage_rounds runs usage_runs input_total input_r1 m2_pct
schema-ai-integration       9            9    9          9   130335500 10321830  92.08
codex-account-setup        10            9   10          9    32123117  3989000  87.58
c16-move                   10           10   10         10   126552666 11490483  90.92
backlog-batch-3            11            9    9          9    81305639  5761519  92.91
batch4-p1b                  6            0    6          0           0        0
M1 median = 10 over 9,10,10,11,6
M1u median = 9 over 9,9,10,9
M2 combined = 91.48% (r1=31562832, total=370316922)
```

重算方式為將下列腳本存成暫存檔（例如 `<work-root>\.local\ai-sessions\scratch\baseline.ps1`），再執行 `pwsh -NoProfile -File <暫存檔> -RunsCsv 'C:\Users\CloudyWing\.ai-agents\.local\ai-sessions\report\dispatch-cost-ledger\raw\runs.csv'`。腳本依上節基準鏈表對映 slug 與輪次，加總 `usage_available=True` 列的 `input_tokens`。

```powershell
param([Parameter(Mandatory)][string]$RunsCsv)
$ErrorActionPreference = 'Stop'
$chains = [ordered]@{
    'schema-ai-integration' = @{ line = 'schema-ai-integration'; rounds = 9; map = [ordered]@{ 'review-schema-ai-integration' = 1; 'review-schema-ai-integration-r2' = 2; 'review-schema-ai-integration-r3' = 3; 'review-schema-ai-integration-r4' = 4; 'review-schema-ai-integration-r5b' = 5; 'review-schema-ai-integration-r6' = 6; 'review-schema-ai-integration-r7' = 7; 'review-schema-ai-integration-r8' = 8; 'review-schema-ai-integration-r9' = 9 } }
    'codex-account-setup'   = @{ line = 'codex-account-setup'; rounds = 10; map = [ordered]@{} }
    'c16-move'              = @{ line = 'rule-architecture-rebuild'; rounds = 10; map = [ordered]@{ 'reviewer-c16-move1' = 1; 'reviewer-c16-move2-1' = 10 } }
    'backlog-batch-3'       = @{ line = 'backlog-batch-3'; rounds = 11; map = [ordered]@{ 'reviewer-batch-3b' = 1; 'reviewer-batch-3d' = 2; 'reviewer-batch-3e' = 3; 'reviewer-batch-3g' = 4; 'reviewer-batch-3i' = 5; 'reviewer-batch-3j' = 6; 'reviewer-batch-3q' = 7; 'reviewer-batch-3s' = 8; 'reviewer-batch-3w' = 9 } }
    'batch4-p1b'            = @{ line = 'rule-architecture-rebuild'; rounds = 6; map = [ordered]@{} }
}
for ($i = 2; $i -le 11; $i++) { $chains['codex-account-setup'].map["reviewer-codex-account-setup-$i"] = $i - 1 }
for ($i = 2; $i -le 9; $i++) { $chains['c16-move'].map["reviewer-c16-move1-$i"] = $i }
for ($i = 1; $i -le 6; $i++) { $chains['batch4-p1b'].map["reviewer-batch4-p1b-$i"] = $i }

$rows = Import-Csv -LiteralPath $RunsCsv | Where-Object { $_.is_fixture -ne 'True' }
$m1 = @(); $m1u = @(); $allR1 = 0.0; $allTotal = 0.0
foreach ($name in $chains.Keys) {
    $c = $chains[$name]; $usageRounds = @{}; $r1 = 0.0; $total = 0.0; $runCount = 0; $usageCount = 0
    foreach ($slug in $c.map.Keys) {
        $round = $c.map[$slug]
        $hits = @($rows | Where-Object { $_.line_slug -eq $c.line -and $_.dispatch_slug -eq $slug })
        $runCount += $hits.Count
        foreach ($h in $hits | Where-Object { $_.usage_available -eq 'True' }) {
            $usageCount++; $usageRounds[$round] = $true
            $v = [double]$h.input_tokens; $total += $v
            if ($round -eq 1) { $r1 += $v }
        }
    }
    $m1 += $c.rounds
    if ($total -gt 0) { $m1u += $usageRounds.Count; $allR1 += $r1; $allTotal += $total }
    $share = if ($total -gt 0) { [math]::Round((($total - $r1) / $total) * 100, 2) } else { $null }
    [pscustomobject]@{ chain = $name; rounds = $c.rounds; usage_rounds = $usageRounds.Count; runs = $runCount; usage_runs = $usageCount; input_total = [int64]$total; input_r1 = [int64]$r1; m2_pct = $share }
}
function Get-Median([double[]]$v) { $s = $v | Sort-Object; $n = $s.Count; if ($n % 2) { $s[[int][math]::Floor($n / 2)] } else { ($s[$n / 2 - 1] + $s[$n / 2]) / 2 } }
"M1 median = $(Get-Median $m1) over $($m1 -join ',')"
"M1u median = $(Get-Median $m1u) over $($m1u -join ',')"
"M2 combined = $([math]::Round((($allTotal - $allR1) / $allTotal) * 100, 2))% (r1=$([int64]$allR1), total=$([int64]$allTotal))"
```

M1u 以有 usage 的輪次數計算，不取有 usage 的最大輪次。

## 口徑說明

`turn.completed.usage` 是 Codex thread 的累計值。2026-11-10 的真實派遣 `cost-probe`（scan 檔位）驗證如下：首次 run 的事件流只有 1 筆 `turn.completed`，值為 input 1,230,828、cached 1,144,448、output 13,215；同一 thread 續行的 run 只產生 1 個 item（回答 ok），`turn.completed` 卻是 input 1,329,370、cached 1,241,216、output 14,375，比首次 run 還大。因此單一 run 的用量取該事件流最後一筆 `turn.completed.usage`，續行 run 再減去錨點 run 的同一值；上例續行 run 的實際用量為 input 98,542、cached 96,768、output 1,160。

基準鏈的審查 run 在 `runs.csv` 全部是 `is_continuation=False` 的冷啟動，每個 slug 一個 run，累計口徑不影響基準的 M2。`runs.csv` 整體有 172 個續行 run，input 合計占全部的 33.3%，這些列是累計值；以 `runs.csv` 計算其他指標時，續行列需先換算為增量。
