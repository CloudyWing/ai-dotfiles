# 審查程序

本檔收錄審查配對判定之後的派遣單細節、規則檔改寫的審查前置與 Reviewer 回收的輸入規格。配對與發動條件見 `rules/claude/40-workflow.md`「審查配對」「Reviewer 派遣發動判準」。發動步驟見 `../SKILL.md`「審查的發動」。

## 規則檔改寫的審查前置

規則檔的機制條款改寫必發，且審查者不得是改寫者。改寫者對自己剛產出的條款存在盲點，需由外部 Agent 稽核。

- 變更盤點：改寫者必須在派遣單附上變更盤點，逐筆列出本輪改動、其中的撤回與更正，以及反覆修改次數最多的區域。盤點讓審查者能針對機制層改動做一致性檢查；缺少盤點的全庫掃描容易漏掉機制層問題。
- 交互比對：改寫者另行自檢一次，與審查結果交互比對。兩者可見範圍不同，改寫者知道改動歷史，能看出規範描述的是某個檔案的舊行為；審查者只讀當前內容，不受「這是我寫的」影響。兩份結果各自可能包含對方沒有的項目，因此合併後才是完整清單，不以任一份取代另一份。

## Reviewer 派遣單與回收

- 讀取範圍：Reviewer Agent 只讀取派遣單、指定目標，以及第 4 欄指定的 `design.md`、同線 `requirement-summary.md` 與 Developer 結案報告（若有），依第 5 欄逐條回報驗收結果。
- 審查 Workflow 實作時，主 Agent 在第 4 欄同時列出 `design.md`、同線 `requirement-summary.md` 與 Developer 結案報告三份檔案的絕對路徑，供 Reviewer 執行需求對照核對。
- 第二輪以後的審查：`Reviewer`、`Frontend Reviewer` 與 `Contract Auditor` 對同一條線的第二輪以後審查，第 4 欄另列同一角色前輪報告的絕對路徑，審查者依其 `F-<三位數>` finding ID 判定閉合狀態。
- 派遣輸入一律是派遣檔（`templates/dispatch/run-order.md`），各欄內容寫入派遣檔的對應部分，對應見 `reviewer.toml`「啟動流程」。Codex 審查者的發動與回收依 `codex-dispatch` skill `references/run.md`，Claude 審查者的發動依本檔「Claude 審查者的發動」。本檔其餘各節的「第 N 欄」指派遣檔的對應部分。
- 回收後：設計歧義由同線 `Analyst` 依 `handoff/<lineSlug>/requirement-summary.md` 原文裁決，裁決前依 `analyst.md` 的 context 完整性自我聲明確認依據來源。

## Claude 審查者的發動

選派入口選出 Claude 執行者時（Codex 不可用，或 Codex 審查者已達未完成次數上限），依下列步驟發動。派遣檔、角色規則檔與回收步驟與 Codex 審查者相同。執行紀錄由 `scripts/Write-ClaudeRunRecord.ps1` 寫入 `<report_line_root>\runs\`，與 Codex 的 `*.record.json` 同一位置，`scripts/Get-LineCost.ps1` 讀得到這一輪。

1. 沿用或撰寫派遣檔。Codex 被拒絕後改派時沿用同一份派遣檔；直接選出 Claude 執行者時依 `codex-dispatch` skill `references/run.md`「發動」第 1 步撰寫，`profile` 填 `review` 類型 Codex 執行者的檔位（選派入口 `-Describe` 可查），Claude 審查者不讀這一欄。
2. 開始：執行 `pwsh -NoProfile -File scripts/Write-ClaudeRunRecord.ps1 -Action Start -DispatchFile <派遣檔> -ExecutorId <執行者 id>`。腳本驗證派遣檔與執行者、建立輸出目錄、保存派生前的來源狀態（記錄 `HEAD`、目標相對於 `HEAD` 的差異雜湊與未追蹤檔案的內容雜湊），並寫出尚未結束的執行紀錄，紀錄同時記下 Start 當時的派遣檔雜湊、`targets` 與 `report_check` 作為 End 的比對基準；stdout 的 JSON 給出 `output_dir` 與 `report_path`。快照只涵蓋 `targets`：審查者寫入 `targets` 以外的檔案，或寫入 `report_line_root` 之內的其他檔案時，這項比對偵測不到，Claude 審查者沒有沙盒限制寫入範圍。腳本失敗時排除原因後重新執行，取得成功結果之前不派生審查者。同一派遣與執行者已有尚未結束的紀錄時，先對該次執行第 4 步，再重新開始。
3. 以 Agent 工具派生冷啟動 subagent，`subagent_type` 為 `general-purpose`，`model` 取自選派入口輸出的 `executor.model`。prompt 與入口產生的格式相同，內容如下。

   ```text
   LineContext
   - lineSlug: <lineSlug>
   - dispatchLineRoot: <派遣檔所在目錄>
   - reportLineRoot: <report_line_root>
   - executionRoot: <execution_root>
   輸出目錄: <output_dir>
   報告檔: <report_path>
   審查者: <executor.display>；同家族審查

   請依角色規則檔 `<role_file>` 定義的審查角色，先完整讀取該檔，再讀取派遣檔 `<派遣檔絕對路徑>` 依其內容執行。
   ```

4. 結束：subagent 回報後執行 `pwsh -NoProfile -File scripts/Write-ClaudeRunRecord.ps1 -Action End -DispatchFile <派遣檔> -ExecutorId <執行者 id>`。腳本以 Start 記下的基準（不是目前的派遣檔內容）取得派生後的來源狀態，比對派生前的狀態得出 `source_changed`（`targets` 被刪除也算已變），核對派遣檔雜湊是否仍與 Start 相同，並對報告執行 `Test-CodexReviewReport.ps1` 同一套檢查得出 `review_report_check`，補完執行紀錄。回收依 `run.md`「回收」，入口結果 JSON 的 `final.source_changed` 與 `final.review_report_check` 改取自 End 輸出的同名欄位。`result` 為 `failed` 時不收下，`failure_reason` 為 `source-changed`、`dispatch-changed`、`report-missing` 或 `review-report-invalid`，排除原因後重新發動。`source_changed` 為 `false` 只表示 `targets` 的內容與 `HEAD` 沒有變動，不表示審查者沒有寫入其他位置。紀錄沒有 token 用量，`Get-LineCost.ps1` 在該列標示 `platform` 為 `claude`，不計入 token 合計並於 `warnings` 列出。
5. 收下後同樣把報告複製為同線 `<report_name>`，並把 `## 例外回報` 節的條目併入同線 `exceptions.md`。

## 循環標示與第 2 輪以上的 Reviewer 派遣單

Reviewer 派遣單第 4 欄依下列規格標示審查循環，循環術語見 `convergence.md`「共同收斂契約」與「循環識別與重新起算」。

- 寫入一行循環標示，格式為 `循環：<cycle_id> 第 <cycle_round> 輪（cycle_role=review）`。這一行是第 4 欄的一般文字行，不含路徑，放在「必讀檔案：」區塊之外。派遣檔形式把這一行寫在 `## 任務` 章節的第一行，並把同一組值填入 `## 派遣設定` 的 `cycle`。
- 第 2 輪以上：「必讀檔案：」區塊另列前輪報告與修正派遣報告的絕對路徑。修正派遣報告在 Workflow 為 `report/<lineSlug>/implement-closure-report.md`，在 `light` 線與單一工作為第 4 欄既有的派工回報檔，內含「前輪 finding 處置結果」表。
- 新循環第 1 輪：不列前輪報告。

## 修正派遣的前輪 finding 處置核對

審查退回後的修正派生，協調者對前輪每一個未閉合 finding 寫明處置，執行端逐條回報結果，回收時機械比對。不要求每輪修完全部 finding。前輪未閉合 ID 為前輪 Reviewer 報告 manifest `findings` 中 `status=open` 的全部 ID，`accepted` 不計。

協調者撰寫處置表，以 in-context 方式隨派生 prompt 傳入：Workflow 放在 Developer 派生 prompt，單一工作放在 `priorFindingDisposition` 欄位。

```markdown
### 前輪未閉合 finding 處置

前輪報告：<絕對路徑>

| finding ID | 嚴重度 | 處置 | 理由或裁決來源 |
| --- | --- | --- | --- |
| F-003 | Major | 修正 | - |
| F-007 | Minor | 延後 | 記為候選，cost-ledger.md 候選列 |
| F-010 | Minor | 接受 | 裁決位置：<絕對路徑:行號> |
```

- `修正`：本輪修正該 ID。
- `延後`：本輪不修，協調者在同線 `cost-ledger.md` 追加 `候選` 列。只有 `Minor` 可延後。
- `接受`：取得條件同 `reviewer.toml`「已接受殘餘風險」，必須附 Analyst 或使用者的裁決位置。`Critical` 與 `Major` 的處置只可為 `修正` 或 `接受`。

執行端不改變處置欄的值，並在回報（Workflow 為 `implement-closure-report.md`，單一工作為 `Support Engineer` 的回報）加入下列結果表。「結果」欄限 `已修正`、`依派生處置未動`、`依裁決未動`、`受阻`；`受阻` 在證據欄寫原因。

```markdown
## 前輪 finding 處置結果

| finding ID | 處置 | 結果 | 證據 |
| --- | --- | --- | --- |
| F-003 | 修正 | 已修正 | <絕對路徑>:<起行>-<迄行> |
| F-007 | 延後 | 依派生處置未動 | 派生處置表 F-007 列 |
| F-010 | 接受 | 依裁決未動 | <裁決位置> |
```

回收時令 U 為前輪未閉合 ID 集合，D1 為處置表 ID 集合，D2 為結果表 ID 集合。下列各項同時成立才收下：

- U 等於 D1。
- D1 等於 D2。
- 逐 ID 的處置值在 D1 與 D2 相同，且屬允許集合。
- 處置為 `修正` 的列，證據欄含修正位置。
- `Critical` 與 `Major` 沒有 `延後`。

任一不成立為純技術缺件，依回收三態退回。結果為 `受阻` 的列同樣依回收三態處理。

## light 線的 Reviewer 派遣單與回收

有效深度為 `light` 的線發動審查時，派遣單依下列規格撰寫。

- 第 4 欄列出同線 `requirement-summary.md`、實作驗收契約、派工回報與前輪報告（若有）的絕對路徑，不列 `design.md` 與 Developer 結案報告。實作驗收契約依執行者而定：Claude subagent 為派生 prompt 中的 `acceptanceCriteria`，主 Agent 將其原文另存為檔案後列入；主 Agent 自理為完成回覆中逐列標註〔需求 #n〕的驗收列，同樣另存為檔案後列入。
- Spec 基準為需求摘要與實作驗收契約的驗收列。`agents/codex/reviewer.toml` 已規定未指定設計文件時依派遣單第 4 欄與第 5 欄執行。
- 回收後的設計歧義由同線 `Analyst` 依需求摘要原文與實作驗收契約的驗收列裁決。
