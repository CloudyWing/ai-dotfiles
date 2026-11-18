---
name: session-artifacts
description: 'Use when 建立、讀取、回收、保存或清理 .local/ai-sessions/ 下的交接檔、派遣單、報告或其他工作產物，需要確定分類與落點時。'
audience: agent
policy.allow_implicit_invocation: true
---

# 工作產物分類與落點

本 Skill 提供 Agent 工作產物的分類與存放路徑。`lineSlug` 登記、`LineContext` 驗證、清理範圍與保留範圍由 `instructions.md` §1.4 規定。

## 產物分類與落點

Agent 執行任務產生的檔案依用途分為下列七類，存放於固定目錄。

- **線層交接檔與固定報告**：線登記資料、需求摘要與設計文件分別存入 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/line.json`、`<work-root>/.local/ai-sessions/handoff/<lineSlug>/requirement-summary.md` 與 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/design.md`。執行者轉移的交接單存入 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/escalation-handoff-<序號>.md`，轉移前的舊 diff 存入 `<work-root>/.local/ai-sessions/report/<lineSlug>/escalation-prior-diff-<序號>.patch`。Developer 結案、交接檢查點、跨線全貌文件 `coordination-overview.md`（見「跨線全貌文件」）、Reviewer、未解驗證、Frontend Reviewer、Contract Auditor、Architecture Review、Cleanup Review、fact-check、文件同步（`doc-sync-report.md`、`doc-edit-report.md`、`survey-doc-sync-consistency.md`）、`cost-ledger.md` 與例外紀錄存入 `<work-root>/.local/ai-sessions/report/<lineSlug>/`。寫入前依 `instructions.md` §1.4「工作產物落點」取得已驗證的 `LineContext`。
- **派遣檔與報告**：`dispatchSlug` 識別單次派遣，與識別線的 `lineSlug` 分屬不同名稱空間。派遣檔存入 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/run-order-<dispatchSlug>.md`，每次執行的產物存入 `<work-root>/.local/ai-sessions/report/<lineSlug>/runs/`，含輸出目錄 `<runKey>/`（報告在其中）、`<runKey>.record.json`、`<runKey>.events.jsonl`、`<runKey>.stderr.txt` 與 `<runKey>.last-message.md`，屬保留性質。
- **跨 Session 脈絡紀錄**：耐久的環境前置作業、已知陷阱與覆寫備份分別存入 `CONTEXT.local.md`、`<work-root>/.local/ai-sessions/history/<lineSlug>/` 與 `<work-root>/.local/ai-sessions/backups/`。
- **專案規範**：換機器仍適用的 `AGENTS.md`、`CLAUDE.md`、`GLOSSARY.md` 與 `docs/adr/` 存放於專案原本的規範位置，不歸入 `.local/`。
- **過程性可棄**：一次性腳本、終端輸出、日誌與暫存下載存入 `<work-root>/.local/ai-sessions/scratch/`。
- **需保留非交付**：整合任務素材、截圖、樣式基準、Demo 畫面與測試環境資料檔分別存入 `<work-root>/.local/ai-sessions/inputs/`、`screenshots/`、`style-baselines/`、`ui-demo/` 與 `test-context/test-context.md`。測試取證的截圖在派遣的輸出目錄內產生，收下後把需要保留的複製到 `screenshots/`。測試環境資料檔的建立與使用見「測試環境資料檔」。
- **交付產物**：使用者預期交付的資料檔、程式碼與文件存放於專案原本的位置，不放入 `.local/ai-sessions/`。

## 測試環境資料檔

本機 E2E 與測試取證需要登入時，兩端的執行者都讀專案層的 `<work-root>/.local/ai-sessions/test-context/test-context.md`。測試帳號跨線共用，壽命長於任何一條線，因此不放在線目錄。

- 內容：受測程式的啟動方式與網址、測試帳號與密碼（含各帳號的角色與用途）、測試資料的重置方式、不可操作的資料範圍。骨架以 `templates/test-context.md.template` 為準。
- 保留：屬保留性質，不在任務結束的自動清理範圍，位於 `.local/`，不進版控。
- 外送：檔案內容會隨執行端讀取送到模型服務端，只放專為測試建立的帳號，不放正式環境或個人帳號。檔名不落在機密檔樣式內，專案自己的 `.env`、`*.pem`、`*.key`、`secrets.*` 仍禁止 Codex 的命令讀取。
- 建立：Agent 不自行建立帳號，也不把其他來源的帳密抄進來。需要登入而此檔不存在時，依範本在固定位置建立，把能從專案讀到的欄位（啟動命令、網址與連接埠、seed 資料中已有的測試帳號名稱）先填好，密碼欄留空，在對話以可點擊的檔案連結列出該檔與待填欄位後停止，等使用者直接編輯填入密碼並回覆已填妥，Agent 讀檔確認待填欄位都有值再繼續。密碼不經由對話提供。
- 派工：`test` 派遣把此檔的絕對路徑填入派遣檔 `test_context_file`，見 `codex-dispatch` skill `references/run.md`「測試取證（test）」。

## 線登記與 LineContext

登記者與登記時機由 `instructions.md` §1.4「工作產物落點」規定。登記操作如下。

1. 從需求的核心目的推導小寫英數單字，以連字號串接為候選值，確認符合 `^[a-z0-9]+(?:-[a-z0-9]+)*$`。無法取得有效候選值時，停止派遣並要求使用者補充需求的核心目的，不設定預設 slug。
2. 對尚未登記線的對話，以不帶 `-Force` 的目錄建立操作保留 `<work-root>/.local/ai-sessions/handoff/<candidate>/`。目錄已存在或建立競爭失敗時，依序改用 `<candidate>-2`、`<candidate>-3`，直到成功建立為止。已存在但缺少 `line.json` 的目錄仍視為已占用。
3. 目錄保留成功後立即寫入 `line.json`。寫入失敗時停止後續交接檔寫入，保留該目錄作為已占用的候選值，並回報錯誤。

```json
{
  "schema": "ai-sessions.line.v1",
  "line-slug": "invoice-export",
  "semantic-label": "invoice export",
  "kind": "workflow",
  "created-at-utc": "2026-08-27T00:00:00.0000000Z"
}
```

`kind` 為選填欄位，值為 `workflow` 或 `adhoc`，缺少時視為 `workflow`。需求線使用 `workflow`；不屬任何需求線的一次性取證使用 `adhoc`。`lineSlug` 識別同一條線的持久交接與固定報告，與識別單次派遣的 `dispatchSlug` 分屬不同名稱空間。

同一條線的後續寫入、驗收、實作與審查均沿用已登記的 `lineSlug`，每次跨派遣時傳遞 `LineContext`，至少包含下列欄位：

- `sourceRoot`：已解析的 work-root 絕對路徑。
- `lineSlug`：已登記並驗證的線識別。
- `sourceLineRoot`：`<sourceRoot>/.local/ai-sessions/handoff/<lineSlug>`。
- `dispatchLineRoot`：執行端讀取同線交接檔的目錄。Claude subagent 直接修改來源工作樹時等於 `sourceLineRoot`；經 `scripts/Invoke-CodexRun.ps1` 發動時為派遣檔所在目錄。
- `reportLineRoot`：同線報告目錄，Claude 路徑為來源 `report/<lineSlug>`。

接收端驗證 `LineContext` 是硬性前置：`lineSlug` 符合上列格式，且同線 `line.json` 存在、其 `line-slug` 欄位與傳入的 `lineSlug` 一致。缺少 `LineContext`、找不到 `line.json`，或 `line-slug` 不一致時，一律停止寫入固定名稱交接檔與報告，交由上游建立正確的線脈絡，不以預設值、時間戳或 `dispatchSlug` 代替。

## 跨線全貌文件

全貌文件記錄協調者同時協調多條線時的現況，使新的主 Session 或壓縮後的主 Session 不依對話記憶接續。單一線的交接由 `handoff-checkpoint.md` 承擔，全貌文件不重抄其欄位。

- **建立條件**：協調者同時協調兩條以上尚未結案的線（含子 Session 或子代理承接的子線）時建立。只協調單一線時不建立，該線的交接由 `handoff-checkpoint.md` 承擔。
- **位置**：每個 work-root 只有一份，固定為 `<work-root>/.local/ai-sessions/report/coordination/coordination-overview.md`，線登記檔為 `handoff/coordination/line.json`，其 `kind` 為 `adhoc`。不論協調者有沒有自己的需求線，一律使用這個位置，讓接手者不需要任何線索就能定位。
- **固定 slug 的登記**：`coordination` 是保留給全貌文件的 slug，需求線登記時不使用。`handoff/coordination/` 與其 `line.json` 已存在時沿用，不依「線登記與 LineContext」的遞增規則改用 `coordination-2`，否則接手者會另建一份而遺棄原檔。目錄存在但缺少 `line.json` 時補寫 `line.json` 後沿用。`line.json` 的 `line-slug` 不是 `coordination`，或 `kind` 不是 `adhoc` 時，停止並回報使用者，不另建其他目錄。目錄不存在時才登記。
- **保留**：檔案屬同線報告，依 `instructions.md` §1.4 的保留清單保留，不在自動清理範圍。
- **範本**：`templates/coordination-overview.md.template`，區塊標題與表頭固定，不增減區塊。建立實際文件時刪除範本內的全部註解。
- **維護者**：協調者手動維護，不設腳本或檢查。

四個區塊的內容與更新方式如下。

| 區塊 | 內容 | 更新時機 | 更新方式 |
| --- | --- | --- | --- |
| 現況 | 更新時間、整合分支與遠端的位置、未 push 的 commit、進行中的線工作樹 | push、落地、建立或移除線工作樹之後；接手核對發現不一致時 | 整段覆寫 |
| 各線狀態 | 線名、執行者（子 Session 或子代理的識別）、分支與工作樹、目前在哪一站、下一步 | 派出、回收、換站、結案時 | 逐列更新；結案的線移除該列；尚未開線的待辦列在表尾，站欄填「未開線」 |
| 等使用者決定 | 提出時間、線名（或「跨線」）、一句話問題 | 依「升級兩道篩」判定須使用者拍板時 | 新增一列；使用者回覆後移除該列，回覆內容構成決定時同時追加到「已拍板的決定」 |
| 已拍板的決定 | 時間、使用者原話、適用範圍（線名與涵蓋邊界，或「跨線」） | 使用者做出決定的當輪 | 只追加，不壓縮、不改寫、不移除既有條目；決定被後續決定取代時，追加新條目並註明取代哪一條，原條目不動 |

- 不寫歷史經過、已結案線的細節與各線報告的內容。這些由 `git log` 與各線的 `handoff/<lineSlug>/`、`report/<lineSlug>/` 承載，全貌文件需要時只寫路徑。
- 各線的站名只寫一個詞，細節與該線的未決事項留在該線的 `handoff-checkpoint.md`。「等使用者決定」只收須使用者回覆的問題。
- 「已拍板的決定」記錄決定本身，不構成授權。決策權交付字樣的效力依 `rules/claude/20-coordination.md`「授權期限」。
- 篇幅以協調者能整份載入為準。前三個區塊合計超過 300 行時，移除混入的歷史經過、已結案線的細節與各線報告的重抄；「已拍板的決定」不計入此上限，也不因篇幅壓縮。

接手時依下列步驟進行。

1. 在固定位置讀取全貌文件。不存在時表示沒有進行中的跨線協調，仍在進行的單一線依該線的 `handoff-checkpoint.md` 接續。
2. 依「各線狀態」逐線依 `rules/claude/20-coordination.md`「Workflow 交接檢查點」第 4 點接手該線。沒有檢查點的線，實讀同線 `requirement-summary.md`（以 brief 承接而沒有需求摘要的線略過）與 `report/<lineSlug>/` 下的結案或派工回報。站欄為「未開線」的列沒有交接物可讀，只作為待辦。
3. 以 `git` 與磁碟的實際狀態核對「現況」（分支位置、未 push 的 commit、`git worktree list`）。與文件不一致時以實際狀態為準，並更正文件。
4. 逐項確認「等使用者決定」仍待回覆，已被使用者回覆者移除並依回覆更新其他區塊。

## requirement-summary.md 格式

需求意圖驗收與設計驗收都以同線 `requirement-summary.md` 為唯一比對依據，此檔使需求原意不依賴對話 context 而存在。只在使用者確認需求摘要後寫入，欄位如下：

- **需求背景**：核心目的與主要範圍。
- **程式面項目**：已觀察的問題、改善方向。
- **功能面項目**：新增功能、擴充方向。
- **排除項目**（若有）：明確不做的範圍。
- **已確定的實作約束**（若有）：對話過程中已由使用者拍板的實作面限制，例如指定沿用某既有機制、指定使用某既有元件而非自行實作、指定不得改動某模組。每條註明來源為使用者拍板，並保留當初的具體措辭，不改寫成抽象敘述。這類共識既非需求項目也非驗收方向，缺少此欄時會在整理摘要的過程中流失。
- **假設清單**（若有）：若需補充資訊時的合理假設。
- **驗收方向**：各項目的完成判斷依據。
- **Workflow 深度**：本線的有效深度，解析優先序依 `rules/claude/40-workflow.md`「Workflow 深度」，升級判定在使用者確認需求摘要前完成。

程式面與功能面兩欄各自使用 `## 程式面項目` 與 `## 功能面項目` 二級標題，各出現恰好一次。節內只能是一個 `| # | 項目 | 內容 |` 表格，`#` 欄為純數字編號，兩節合併後不得重複；表格前後不得有說明段落、清單或其他表格，補充說明寫在「需求背景」或其他欄位。沒有項目的一節保留標題，節內只寫一行「無」。驗收方向寫入「內容」欄的完整句子，不另加第四欄，表頭第三欄不得改名。`Architect` 的 `〔需求 #n〕` 標註、Developer 的「需求對照」節與主 Agent 的結構核對都以此編號為鍵。

`## Workflow 深度` 節固定為下列三行，深度值只能是 `full` 或 `light`：

```markdown
## Workflow 深度

- 深度：light
- 來源：由 project-kind=sample 推導
- 升級判定：未命中（必發清單第 2 項：否；library 公開 API：否；UI 線為版面規劃或先做 Demo：否）
```

來源欄寫出命中的優先序層級；逐線指定時寫「Analyst 逐線指定」並附理由。

## 覆寫前備份

需求摘要、`design.md` 與需保留前版的同線固定報告，覆寫前依下列順序備份，不需詢問使用者確認。

1. 確認目標檔案是否存在。不存在時直接寫入新內容。
2. 確認 `<work-root>/.local/ai-sessions/history/<lineSlug>/` 存在，不存在時建立。
3. 將既有檔案改名為 `<原檔名>.<yyyyMMdd_HHmmss>` 並移入該目錄。同名備份已存在時停止並回報，不覆寫既有備份。
4. 確認備份檔存在後，才寫入新內容。

經 Codex 執行端執行的備份另依 `codex-dispatch` skill `references/collect.md`「覆寫前備份」。

## 需求級成本累計

`cost-ledger.v2` 列格式見 `references/cost-ledger.md`，寫入或讀取同線 `cost-ledger.md` 時讀取。一條線的成本以 `scripts/Get-LineCost.ps1` 唯讀計算；`事件` 列由派工腳本追加，`循環重啟` 與 `候選` 列由協調者追加。

成效比對的指標、程序與基準數字見 `references/cost-comparison.md`。
