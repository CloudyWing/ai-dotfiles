# Workflow 結案報告：<dispatch-slug>

<!--
寫入 <work-root>\.local\ai-sessions\report\<line-slug>\implement-closure-report.md。格式定義以 agents\codex\developer.toml「Workflow 結案報告格式」為準。
Workflow Collect 驗證下列三項，不符時以非零結束：
- 「需求對照」節唯一，表格固定 6 欄且每欄非空；狀態限「已交付」「部分交付」「未交付」「排除（design.md §8）」四個字串，排除須含括號內文字。
- 有選定需求時，表格後緊接一行「範圍外（本輪不要求交付）：#…」，中間不留空行。
- 「Phase 對照」節以反引號列出的路徑集合，須與本輪 Git 差異一致。
Claude 執行者（Haiku 或 Sonnet）承接時只寫一份 implement-closure-report.md，涵蓋承接的全部 Phase。Claude 實作路徑不執行 Collect，由主 Agent 依 workflow-orchestration「Claude 實作路徑」逐項核對上列三項。
-->

## 已完成項目

- <T-code 與描述> — <驗證結果>

## 判定為既有實作而未動工

- <T-code 與描述> — 判定依據：<檔案:行號> / <等同設計要求的理由>

## 驗證證據

- build：<通過或失敗>
- test：<通過 N／失敗 N，失敗時列出清單>
- 輪起點 SHA：<sha 或 N/A（原因）>
- 開工基準線：<clean，或開工前既存的未提交與未追蹤檔案清單>
- 工作區變更：<git status --porcelain 的完整輸出>
- 動態驗證：<命令原文> → <輸出摘要>（執行時間 yyyy-MM-dd HH:mm:ss）

## Phase 對照

- Phase <N>：`<實際修改的檔案路徑>`

## 需求對照

| 需求 | 驗收方向 | T-code | 實際行為 | 證據 | 狀態 |
| --- | --- | --- | --- | --- | --- |
| #<n> | <需求摘要該項的驗收方向原文> | <T-code 或 無> | <交付後的可觀察行為> | <檔案:行號，或命令原文與驗證證據節的對應條目> | <已交付、部分交付、未交付、排除（design.md §8） 四選一> |
範圍外（本輪不要求交付）：#<n>、#<n>

## 前輪 finding 處置結果

<!-- 審查退回後的修正輪才有此節，沒有前輪未閉合 finding 時刪除整節。逐列對應派生 prompt 的「前輪未閉合 finding 處置」表，處置值照抄；結果限已修正、依派生處置未動、依裁決未動、受阻。核對方式見 workflow-orchestration skill references/review-procedures.md「修正派遣的前輪 finding 處置核對」。 -->

| finding ID | 處置 | 結果 | 證據 |
| --- | --- | --- | --- |
| F-<nnn> | <修正、延後或接受> | <已修正、依派生處置未動、依裁決未動或受阻> | <修正位置、處置表列或裁決位置> |

## 未解決項目

- <T-code 與描述> — <目前狀態／待使用者決定的事項>
