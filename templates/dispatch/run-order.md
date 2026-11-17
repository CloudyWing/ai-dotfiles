# 派遣檔：<dispatch-slug>

<!--
本檔是 scripts\Invoke-CodexRun.ps1 的唯一輸入。入口只解析「## 派遣設定」之下的第一個 json 區塊，其餘章節全文留給 Codex 閱讀。
派遣檔放在 Codex 可讀取的位置：執行目錄（execution_root）、~\.ai-agents 或同線報告目錄（report_line_root）之下。
欄位規則：
- schema 固定 ai-agents.codex-run-order.v1。
- line_slug、dispatch_slug 為小寫英數與連字號。
- task_type 取 review、factcheck、generate、test 或 advise，各類型的 role_file、report_name 與入口差異見 skills\codex-dispatch\references\run.md「依 task_type 的差異」。
- profile 取選派入口輸出的 executor.profile；改由 Claude 審查者承接時沿用原值，Claude 審查者不讀這一欄。
- role_file、execution_root、report_line_root、targets、required_reads 一律為絕對路徑；targets 的目錄以結尾反斜線標示，required_reads 可為空陣列。
- report_name 只含檔名。報告落在 <report_line_root>\runs\<dispatch_slug>-<runId>\<report_name>。
- advisor_request_source、evidence_file、question_ids 只在 task_type 為 advise 時填寫且三者必填，其他類型不得出現；advise 的 profile 固定為 advisor，required_reads 為空陣列，見 skills\codex-dispatch\references\run.md「顧問（advise）」。
- test_context_file 只在 task_type 為 test 時選填，值為 <work-root>\.local\ai-sessions\test-context\test-context.md 的絕對路徑（檔案必須存在）；test 的 profile 固定為 scan，role_file 填派遣檔本身，受測對象與登入方式寫在「## 任務」，見 skills\codex-dispatch\references\run.md「測試取證（test）」。
- cycle 選填，含 id、round（正整數）、role，寫入成本帳的 cycle 欄位；省略時三欄寫「-」。
- 不得出現其他鍵，也不得列出 .env、.env.*、*.pem、*.key、secrets.* 等機密樣式檔。
-->

## 派遣設定

```json
{
  "schema": "ai-agents.codex-run-order.v1",
  "line_slug": "<line-slug>",
  "dispatch_slug": "<dispatch-slug>",
  "task_type": "review",
  "profile": "review",
  "role_file": "C:\\Users\\<user>\\.ai-agents\\agents\\codex\\reviewer.toml",
  "execution_root": "C:\\Users\\<user>\\.ai-agents.wt\\<line-slug>",
  "report_line_root": "C:\\Users\\<user>\\.ai-agents.wt\\<line-slug>\\.local\\ai-sessions\\report\\<line-slug>",
  "report_name": "review-report.md",
  "targets": [
    "C:\\Users\\<user>\\.ai-agents.wt\\<line-slug>\\scripts\\"
  ],
  "required_reads": [
    "C:\\Users\\<user>\\.ai-agents.wt\\<line-slug>\\.local\\ai-sessions\\handoff\\<line-slug>\\design.md"
  ],
  "cycle": { "id": "<cycle-id>", "round": 1, "role": "review" }
}
```

## 任務

<任務說明、審查重點與前輪報告路徑。審查退回後的修正派遣在此放「前輪未閉合 finding 處置」表。>

## 驗收條件

| # | 類別 | 驗收條件 |
| --- | --- | --- |
| 1 | <新行為或回歸守衛> | <可由報告內容判定的條件> |

## 邊界

固定唯讀。不得修改目標物件，不得執行建置與測試，不得建立 commit。審查報告的自驗命令 `scripts/Test-CodexReviewReport.ps1` 不在此限。唯一可寫入的位置是 prompt 指定的輸出目錄，報告檔、影像與例外回報都寫在其中。

## 回報必備欄位

報告含下列內容。以下為審查的欄位；事實校閱改依 `fact-check-note` skill「報告格式」，影像產生改為逐一列出輸出目錄內的影像檔名與用途，測試取證改為逐條驗收條件的操作紀錄（MCP 工具與結果）、截圖檔名與對應條件，顧問改為對 `question_ids` 的每個題號各用一個標題回答，都保留 `## 例外回報`。

- `## 總覽`：審查結論（pass 或 fail）與逐條驗收條件的判定。
- `## Finding manifest`：唯一一個 json 區塊，格式為 `codex-run.review-findings.v1`，每個 finding 有 `id`、`severity`、`status`、`summary`。
- `## 例外回報`：偏離設計、自行採用假設、範圍外既有問題等條目，格式同 `exceptions.md`；沒有時刪除整節。
