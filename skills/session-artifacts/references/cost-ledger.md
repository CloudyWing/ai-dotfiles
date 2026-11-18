# 需求級成本累計

本檔收錄 `cost-ledger.md` 的 `cost-ledger.v2` 列格式。寫入或讀取同線 `cost-ledger.md` 時讀取。成本計算使用 `scripts/Get-LineCost.ps1`，成效比對的指標與基準數字見 `cost-comparison.md`。

成本以 `lineSlug` 識別。`dispatchSlug` 與階段只作追溯資訊，換新 `dispatchSlug` 或換階段都不讓同一條線的累計歸零。計算入口為 `pwsh -NoProfile -File scripts/Get-LineCost.ps1 -WorkRoot <work-root> -LineSlug <lineSlug>`，唯讀、輸出 JSON、不寫任何檔案、不自動寫入成本紀錄。腳本彙整 `report\<lineSlug>\runs\*.record.json` 與本檔的 `事件` 列（只採計 runId 不在 RunRecord 中的列），不推算。Claude 用量只在以 `-ClaudeSessionId` 或 `-ClaudeTranscriptPath` 指定時計算（重用 `Get-ClaudeSessionUsage.ps1`），否則為 null 並附原因。

成本紀錄的落點是 `<sourceRoot>\.local\ai-sessions\report\<lineSlug>\cost-ledger.md`，只追加不改寫。`事件` 列由派工腳本自動追加。`循環重啟` 與 `候選` 列由該線協調者（功能線為 `Analyst`，bug 線為 `Maintainer`）手寫，記錄循環識別與 `Minor` 的處置，不屬成本。Codex 執行端只產出事件流，不寫入 `cost-ledger.md`。

## 列格式（cost-ledger.v2）

表格以標記行 `<!-- cost-ledger.v2 -->` 開頭，表頭固定 14 欄如下。檔案不存在時，腳本建立首行 `# <lineSlug> 成本紀錄`、標記與表頭。既有檔案沒有標記（舊版手寫表）時，腳本不改寫舊內容，在檔尾空一行後附加標記與表頭再接新列。讀取端只解析標記之後的表格。

```text
<!-- cost-ledger.v2 -->
| 時間（UTC） | 列類型 | 成本目標 | dispatchSlug | runId | cycle_id | cycle_round | cycle_role | 事件類型 | 耗時（秒） | input | cached_input | output | 備註 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
```

| 列類型 | 寫入者 | 填法 |
| --- | --- | --- |
| `事件` | 腳本 | `scripts/Invoke-CodexRun.ps1` 於每次嘗試結束時自行追加一列，含被服務端拒絕而沒有用量的嘗試；`runId` 為該次執行 `runKey` 去掉 `<dispatch_slug>-` 前綴後的部分，事件類型固定為 `首次`，備註為 `exit=<結束碼>;result=<success、failed 或 rejected>;task=<task_type>;account=<帳號名稱>;rejection=<種類或 none>;usage=<status>` |
| `循環重啟` | 協調者 | 依 `workflow-orchestration` skill「循環識別與重新起算」 |
| `候選` | 協調者 | 備註寫「ID=<finding ID 或 C-nnn>；嚴重度=Minor；摘要=…；來源報告=<絕對路徑>」 |

未適用的欄位寫 `-`。儲存格內的 `|` 寫成 `\|`，不換行。

輪數與成本分開判定：純格式補件不增加回收輪數（見 `codex-dispatch` skill `references/collect.md`「回收收斂判定」）。格式補件以同一 `cycle_round` 內的重跑表示，跨階段由 `cycle_id` 區分。
