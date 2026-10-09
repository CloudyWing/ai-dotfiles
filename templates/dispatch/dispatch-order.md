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

<TaskBody：任務說明、必讀參考檔的絕對路徑、審查或實作重點>

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

結案訊息須含派遣單絕對路徑、`<dispatch-slug>` 與 `<line-slug>`。

```text
OutputPath: <派遣單絕對路徑>
DispatchSlug: <dispatch-slug>
LineSlug: <line-slug>
```
