# 審查程序

本檔收錄審查配對判定之後的派遣單細節、規則檔改寫的審查前置與 Reviewer 回收的輸入規格。配對與發動條件見 `instructions.md`「審查配對」「Reviewer 派遣發動判準」。入口見 `../SKILL.md`「審查程序」。Sonnet 審查的逐站步驟見 `../SKILL.md`「Sonnet 審查路徑」。

## 規則檔改寫的審查前置

規則檔的機制條款改寫必發，且審查者不得是改寫者。改寫者對自己剛產出的條款存在盲點，需由外部 Agent 稽核。

- 變更盤點：改寫者必須在派遣單附上變更盤點，逐筆列出本輪改動、其中的撤回與更正，以及反覆修改次數最多的區域。盤點讓審查者能針對機制層改動做一致性檢查；缺少盤點的全庫掃描容易漏掉機制層問題。
- 交互比對：改寫者另行自檢一次，與審查結果交互比對。兩者可見範圍不同，改寫者知道改動歷史，能看出規範描述的是某個檔案的舊行為；審查者只讀當前內容，不受「這是我寫的」影響。兩份結果各自可能包含對方沒有的項目，因此合併後才是完整清單，不以任一份取代另一份。

## Reviewer 派遣單與回收

- 讀取範圍：Reviewer Agent 只讀取派遣單、指定目標，以及第 4 欄指定的 `design.md`、同線 `requirement-summary.md` 與 Developer 結案報告（若有），依第 5 欄逐條回報驗收結果。
- 審查 Workflow 實作時，主 Agent 在第 4 欄同時列出 `design.md`、同線 `requirement-summary.md` 與 Developer 結案報告三份檔案的絕對路徑，供 Reviewer 執行需求對照核對。
- 第二輪以後的審查：`Reviewer`、`Frontend Reviewer` 與 `Contract Auditor` 對同一條線的第二輪以後審查，第 4 欄另列同一角色前輪報告的絕對路徑，審查者依其 `F-<三位數>` finding ID 判定閉合狀態。
- 回收後：設計歧義由同線 `Analyst` 依 `handoff/<lineSlug>/requirement-summary.md` 原文裁決，裁決前依 `analyst.md` 的 context 完整性自我聲明確認依據來源。

## 循環標示與第 2 輪以上的 Reviewer 派遣單

Reviewer 派遣單第 4 欄依下列規格標示審查循環，循環術語見 `../SKILL.md`「共同收斂契約」與「循環識別與重新起算」。

- 寫入一行循環標示，格式為 `循環：<cycle_id> 第 <cycle_round> 輪（cycle_role=review）`。這一行是第 4 欄的一般文字行，不含路徑，放在「必讀檔案：」區塊之外。Codex 派遣的值與 Request 的 `cycle_id`、`cycle_round`、`cycle_role` 一致。
- 第 2 輪以上：「必讀檔案：」區塊另列前輪報告與修正派遣報告的絕對路徑。修正派遣報告在 Workflow 為 `report/<lineSlug>/implement-closure-report.md`，在 `light` 線與單一工作為第 4 欄既有的派工回報檔，內含「前輪 finding 處置結果」表。
- 新循環第 1 輪：不列前輪報告，另寫一行 `本線 Reviewer 最後一份報告的 manifest round=<N>`；Reviewer 本輪 manifest `round` 為 N+1。
- 維持 manifest `round` 為同線同角色的審查序號，新循環不重設。Collect 的 finding 狀態帳以 `finding_id/round` 為鍵，重設會觸發 `LedgerConflict`。循環內輪次寫在報告「總覽」的循環行，不進 manifest。漏寫 `manifest round` 行而觸發 `LedgerConflict` 時，協調者補上該行後重派。

## 修正派遣的前輪 finding 處置核對

審查退回後的修正派生，協調者對前輪每一個未閉合 finding 寫明處置，執行端逐條回報結果，回收時機械比對。不要求每輪修完全部 finding。前輪未閉合 ID 為前輪 Reviewer 報告 manifest `current_judgment` 中 `status=open` 的全部 ID，`accepted` 不計。

協調者撰寫處置表，以 in-context 方式隨派生 prompt 傳入：Workflow 放在 Developer 派生 prompt，單一工作放在分流 A 的 `priorFindingDisposition` 欄位，分流 B 放在派遣單第 4 欄並把前輪報告路徑列入「必讀檔案：」區塊。

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

執行端不改變處置欄的值，並在回報（Workflow 為 `implement-closure-report.md`，單一工作為分流 A 第 5 點的回報，分流 B 為第 7 欄報告）加入下列結果表。「結果」欄限 `已修正`、`依派生處置未動`、`依裁決未動`、`受阻`；`受阻` 在證據欄寫原因。

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
