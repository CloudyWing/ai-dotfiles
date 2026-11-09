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

## light 線的 Reviewer 派遣單與回收

有效深度為 `light` 的線發動審查時，派遣單依下列規格撰寫。

- 第 4 欄列出同線 `requirement-summary.md`、實作驗收契約、派工回報與前輪報告（若有）的絕對路徑，不列 `design.md` 與 Developer 結案報告。實作驗收契約依執行者而定：Claude subagent 為派生 prompt 中的 `acceptanceCriteria`，主 Agent 將其原文另存為檔案後列入；主 Agent 自理為完成回覆中逐列標註〔需求 #n〕的驗收列，同樣另存為檔案後列入。
- Spec 基準為需求摘要與實作驗收契約的驗收列。`agents/codex/reviewer.toml` 已規定未指定設計文件時依派遣單第 4 欄與第 5 欄執行。
- 回收後的設計歧義由同線 `Analyst` 依需求摘要原文與實作驗收契約的驗收列裁決。
