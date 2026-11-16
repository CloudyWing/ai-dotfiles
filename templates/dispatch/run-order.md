# 派遣檔：<dispatch-slug>

<!--
本檔是 scripts\Invoke-CodexRun.ps1 的唯一輸入。入口只解析「## 派遣設定」之下的第一個 json 區塊，其餘章節全文留給 Codex 閱讀。
派遣檔放在 Codex 可讀取的位置：執行目錄（execution_root）、~\.ai-agents 或同線報告目錄（report_line_root）之下。
欄位規則：
- schema 固定 ai-agents.codex-run-order.v1。
- line_slug、dispatch_slug 為小寫英數與連字號。
- task_type 目前只接受 review。
- profile 取選派入口輸出的 executor.profile；改由 Claude 審查者承接時沿用原值，Claude 審查者不讀這一欄。
- role_file、execution_root、report_line_root、targets、required_reads 一律為絕對路徑；targets 的目錄以結尾反斜線標示，required_reads 可為空陣列。
- report_name 只含檔名。報告落在 <report_line_root>\runs\<dispatch_slug>-<runId>\<report_name>。
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

審查類固定唯讀。不得修改目標物件，不得執行建置與測試，不得建立 commit。報告的自驗命令 `scripts/Test-CodexReviewReport.ps1` 不在此限。唯一可寫入的位置是 prompt 指定的輸出目錄，報告檔與例外回報都寫在其中。

## 回報必備欄位

報告含下列內容。

- `## 總覽`：審查結論（pass 或 fail）與逐條驗收條件的判定。
- `## Finding manifest`：唯一一個 json 區塊，格式為 `codex-run.review-findings.v1`，每個 finding 有 `id`、`severity`、`status`、`summary`。
- `## 例外回報`：偏離設計、自行採用假設、範圍外既有問題等條目，格式同 `exceptions.md`；沒有時刪除整節。
