# 派遣單：<dispatch-slug>

<!--
正常路徑以 scripts\New-DispatchOrder.ps1 產生派遣單；本範本對照其輸出結構，供手動檢查或無法執行產生器時使用。
產生器參數：Title、Role、TargetPath、TaskBody、Acceptance、Boundary、ReportPath、DispatchSlug、LineSlug，OutputPath 選填。
Prepare 只接受位於同線 handoff 或 report 根目錄的派遣單；放在 scratch 會被 PrepareArtifactMismatch 拒絕。
-->

## 1. 任務標題

<Title：一句話描述本次派遣的目標>

## 2. 執行角色

`<Role：Developer、Reviewer、Support Engineer 等 agents\codex\ 下的角色名稱>`

## 3. 目標物件

```text
<TargetPath：每行一個絕對路徑；目錄以結尾反斜線標示>
```

## 4. 任務內容

<TaskBody：任務說明、審查或實作重點>

必讀檔案：
- `<絕對路徑>`

<!-- 標題恰為必讀檔案加全形冒號，每行一個反引號包住的絕對路徑，不接行號；沒有必讀檔案時刪除整個區塊。清單後的其他條列須以非清單行隔開。 -->

<!--
審查派遣在必讀檔案區塊之外寫一行循環標示：循環：<cycle_id> 第 <cycle_round> 輪（cycle_role=review）。值與 Request 的 cycle_id、cycle_round、cycle_role 一致。
第 2 輪以上的審查，必讀檔案區塊另列前輪報告與修正派遣報告；新循環第 1 輪改寫一行「本線 Reviewer 最後一份報告的 manifest round=<N>」。規格見 workflow-orchestration skill references/review-procedures.md「循環標示與第 2 輪以上的 Reviewer 派遣單」。
審查退回後的修正派遣，在此欄放「前輪未閉合 finding 處置」表，前輪報告路徑列入必讀檔案區塊；格式見同檔「修正派遣的前輪 finding 處置核對」。
-->

<!--
write 派遣可在任務內容列入需要 shell 網路的還原與建置命令（如 dotnet restore、npm install），並寫明套件來源與版本；下載套件須先取得使用者當輪同意。
readonly 派遣不加入 shell 網路覆寫，實際能否連線依環境而定，不可視為網路隔離；不列入還原、建置或測試命令，需要官方查證時改用 --search。
-->

## 5. 驗收條件與 Codex 命令

| # | 類別 | 驗收條件 | Codex 命令 |
| --- | --- | --- | --- |
| 1 | <新行為或回歸守衛> | <可由命令輸出判定的條件> | 見命令 1 |

### 命令原文

1.
```powershell
<Command：實際執行的命令原文；計數類命令使用 rg -c>
```

## 6. 執行邊界

<Boundary：唯讀或寫入範圍、禁止事項>

<!--
唯讀：不得修改目標物件、不得執行建置與測試、不得建立 commit。
寫入：列出允許產生輸出的目錄（含 restore 與 build 產物），並寫明連線失敗時保存原始輸出與退出碼後回報受阻，不改用 sandbox 外執行。
-->

- 明文寫入例外：第 7 欄報告檔 `<ReportPath>`。
- 明文寫入例外：執行角色規則檔指定的同線固定報告 `<同線固定報告絕對路徑>`。
- 明文寫入例外：同線 `exceptions.md` 的絕對路徑 `<work-root>\.local\ai-sessions\report\<line-slug>\exceptions.md`。

## 7. 產出落點

```text
<ReportPath：報告絕對路徑>
```

## 8. 回報必備欄位

逐條列出第 5 欄命令原文、完整 stdout、完整 stderr、exit code、執行時間、執行狀態與判定結果，另附每條類別與未修改狀態輸出。執行狀態為已執行、受阻、未執行或已補驗四選一，執行端只可使用前三者；受阻須說明缺少的環境能力與原始錯誤。已補驗只由主 Agent 於回收補驗後填寫。

### Runtime Request 欄位對照

| 派遣單生成輸入 | Request 欄位 | 關係 |
| --- | --- | --- |
| `LineSlug` | `line_slug` | 同一條需求線識別值。 |
| `DispatchSlug` | `dispatch_slug` | 同一次派遣識別值。 |
| `TargetPath` | `target_path` | 同一組絕對目標路徑。 |
| `Title`、`Role`、`TaskBody`、`Acceptance`、`Boundary` | 無直接欄位 | 由 Prepare 路徑轉成 Prompt 與執行限制。 |
| `ReportPath` | 無直接對應；`report_path` 僅供 Cleanup Request 使用 | 派遣單的報告落點與 Cleanup 的報告清單用途不同。 |
| `OutputPath` | 無對應欄位 | 只指定派遣單檔案的位置。 |
| 無 | `cycle_id`、`cycle_round`、`cycle_role` | 沒有派遣單生成輸入，由協調者在 Request 填寫，值與第 4 欄循環標示一致。 |

結案訊息須含派遣單絕對路徑、`<dispatch-slug>` 與 `<line-slug>`。

```text
OutputPath: <派遣單絕對路徑>
DispatchSlug: <dispatch-slug>
LineSlug: <line-slug>
```
