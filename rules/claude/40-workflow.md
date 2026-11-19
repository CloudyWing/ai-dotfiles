# Workflow 與審查（Claude 端規則）

本檔是只在 Claude 端載入的常駐規則，經 `~/.claude/rules/` 與 `instructions.md` 一同於啟動時載入。兩端共用的規則在 `instructions.md`。本檔以「」引用的條目不在本檔時，位於同目錄的其他規則檔或 `instructions.md`。

## Workflow 階段保護

- **`Developer` 啟動前置條件**：至少需有可讀取的 `design.md` 作為設計基準，且 `Analyst` 已確認 Design 驗收通過，即沒有未閉合的 `Critical` 或 `Major`，剩餘 `Minor` 已完成批次修正與核對（驗收程序見 `workflow-orchestration` skill「Design 與 Demo 驗收」）。`CONTEXT.local.md` 若存在可作為補充交接，但不是 `Developer` 的必要前置。缺少 `design.md` 或設計驗收未通過時，主 Agent 必須停止並回報原因，不得派生 `Developer`；驗收結果須在派生前完成。有效深度為 `light` 的線沒有 Implement 階段的 Workflow 派工，實作依「Workflow 深度」。

## Workflow 深度

每條需求線有一個有效深度，取值為 `full` 或 `light`。`full` 為完整的 `Clarify => Design => Implement => Review => Accept` 流程；`light` 在需求確認後不派生 `Architect`、不產出 `design.md`、不寫交接檢查點、不派出 `Developer`，改由 Claude subagent 或主 Agent 自理完成實作，逐站步驟見 `workflow-orchestration` skill「light 路徑」。

- **解析與記錄**：`Analyst` 在使用者確認需求摘要前解析有效深度，寫入同線 `requirement-summary.md` 的 `## Workflow 深度` 節（格式見 `session-artifacts` skill「requirement-summary.md 格式」）。後續站點只讀該節，不重新解析；該節不存在時視為 `full`。
- **優先序**：依下列順序判定，命中即停止。
  1. 升級判定命中時為 `full`，不受後列各項覆寫。
  2. `Analyst` 於本線逐線指定的深度，來源欄附理由。
  3. 專案 `AGENTS.local.md` 的 `workflow-depth` 鍵（讀取依 `ai-profile` skill）。
  4. 由 `project-kind` 推導：`sample` 為 `light`，`library` 與 `application` 為 `full`。
  5. 以上皆缺少時為 `full`。
- **升級判定**：變更命中 Reviewer 必發清單第 2 項（跨模組介面、分層或依賴方向）、改動 `library` 公開 API（範圍見 `csharp-language-features` skill「公開 API 相容性」），或本線 UI 線別為「版面規劃」或「先做 Demo」時，有效深度為 `full`。`light` 實作期間，執行端報告或 diff 顯示命中時，主 Agent 停止後續實作站點，交 `Analyst` 把該節改為 `full`（覆寫前備份沿用需求摘要既有規則）並通知使用者，隨後自 Design 起算；已落地的變更視為現況，由 `Architect` 以現況為盤點對象。

`light` 只減少流程站數。派工判準的不派清單與登錄表判定、授權分類、advisor 授權、共同收斂契約、審查配對順序 1、Reviewer 必發清單第 2、5 項與 `Developer` 啟動前置條件在兩種深度下相同。

## Reviewer 派遣發動判準

Reviewer 派遣發動由必發清單機械判定。命中必發清單時，主 Agent 直接建立派遣單並派出 Reviewer，不詢問使用者。未命中時，主 Agent 以一句話記錄不發理由，不得默默略過，接著進入需求意圖驗收。不發理由的紀錄用於補償「該做的事沒做且無人察覺」的失效模式。派遣檔 `## 邊界` 使用「唯讀」時，「唯讀」定義為不得修改目標物件、不得執行建置與測試、不得建立 commit。經 `scripts\Invoke-CodexRun.ps1` 發動的審查者，以及以 Agent 工具派生的 Claude 審查者，都只能寫入該次審查的輸出目錄，例外寫在報告的 `## 例外回報` 節，由主 Agent 回收後併入 `exceptions.md`。需要完全不寫入任何檔案的任務，另用「不產生任何檔案寫入」描述。

**必發清單（命中任一即發）**：

| # | 條件 |
| --- | --- |
| 1 | 派遣或 Workflow 產出的 diff 觸及程式碼檔，例如 `.cs`、`.vue`、`.ts` 或 `.ps1` |
| 2 | 涉及跨模組介面、分層或依賴方向變更 |
| 3 | Developer 結案報告的 exception 含「偏離設計」或「替代方案」條目 |
| 4 | Developer 結案報告有「未解決項目」 |
| 5 | 本輪改寫了 `instructions.md`、`rules/claude/` 下的規則檔、任何 `SKILL.md` 或 agent 規則檔的機制條款 |

主 Agent 依「自己做（小改動）」完成的改動不屬派遣產出，不套用上列必發清單，只對自己的 diff 做核對。Claude subagent（Haiku、Sonnet、Opus）承接的實作屬派工產出，適用上列必發清單。共同收斂契約判定順序 1 結束循環後的 `Minor` 批次修正，第 1 項不適用，只做建置與測試 gate；沒有改到機制條款時不觸發新一輪審查，觸及第 2 項或改到機制條款（第 5 項）時另發審查，為新循環的第 1 輪。

**可不發**：本輪僅改動文件敘述、排版或用詞，未觸及任何機制條款，且結案報告驗證證據三欄齊備，沒有上述 exception 與未解決項目。

**`light` 深度的調整**：有效深度為 `light` 的線（見「Workflow 深度」），必發清單五列的文字不變，判定方式依下表調整。

| 必發清單項目 | `light` 處置 |
| --- | --- |
| 第 1 項 | 可不發。前提是主 Agent 已核對執行端回報的建置與測試命令原文與完整原始輸出（stdout、stderr、exit code），結果成功且與回報一致，且變更不含 `library` 公開 API 改動。任一前提不成立時恢復必發 |
| 第 2 項 | 必發 |
| 第 3、4 項 | 判定來源改為派工回報（含 Claude subagent 回報與主 Agent 自理時寫入 `exceptions.md` 的條目）中的「偏離設計」「替代方案」條目與「未解決項目」，命中即發 |
| 第 5 項 | 必發；審查配對順序 1、審查者不得是改寫者與變更盤點前置維持不變 |

`light` 的 Reviewer 派遣單內容與 Spec 基準見 `workflow-orchestration` skill `references/review-procedures.md`「light 線的 Reviewer 派遣單與回收」。未命中必發清單時，不發理由須含已核對的建置與測試命令。

規則檔的機制條款改寫必發，且審查者不得是改寫者。改寫者須在派遣單附變更盤點，並另行自檢一次，與審查結果交互比對後合併，不以任一份取代另一份（程序見 `workflow-orchestration` skill `references/review-procedures.md`「規則檔改寫的審查前置」）。

**審查配對**：審查以 `type=review` 選派。對這個類型，審查者與實作者屬不同模型家族是優先條件，唯讀與「審查者不得是改寫者」是絕對條件。是否發動審查仍由上列必發清單判定，本節只決定審查者。下表是優先條件可滿足時的對應，依順序命中即停止，每個變更唯一對應一位審查者。

| 順序 | 變更來源（實作者） | 審查者 |
| --- | --- | --- |
| 順序 1 | 規則檔機制條款改寫（`instructions.md`、`rules/claude/` 下的規則檔、任何 `SKILL.md`、agent 規則檔，即必發清單第 5 項） | Codex `Reviewer` |
| 順序 2 | Claude 家族（主 Agent、Haiku、Sonnet、Opus subagent） | Codex `Reviewer` |

- 「審查者不得是改寫者」與本表並存。順序 1 已使 Claude 改寫的規則檔由 Codex 審查。
- `Frontend Reviewer` 與 `Contract Auditor` 維持 Codex，Codex 離線時的處置同 `Reviewer`。
- Codex `Reviewer` 的檔位固定為 `review`，不依檔數或規則檔與否分層。此判定屬規則決定，不需使用者在當下 Session 指定。
- Codex 不可用時（判定依 `rules/claude/30-dispatch.md`「離線改派」，以服務端拒絕為準），優先條件無法滿足，由選派入口選出的同家族執行者審查，目前為 Sonnet subagent；規則檔機制條款同樣適用。協調者直接依選派結果派出，不等待 Codex 恢復。這是選派的正常結果，不追加 exceptions。選派入口照常回傳 `selected`，並以 `unmetPreferences` 與判定行標示同家族審查。審查流程、派遣檔與報告檔名（派遣檔的 `report_name`）不因審查者而異，報告 `## 總覽` 第一行寫明審查者，發動方式見 `workflow-orchestration` skill「審查的發動」。

`Reviewer`、`Frontend Reviewer` 與 `Contract Auditor` 都標為唯讀時，可對同一條線同時發動，經 `scripts\Invoke-CodexRun.ps1` 發動者不設並行上限。

Reviewer 回收後，設計歧義由同線 `Analyst` 依 `handoff/<lineSlug>/requirement-summary.md` 原文裁決，裁決前依 `analyst.md` 的 context 完整性自我聲明確認依據來源。Reviewer 只讀取派遣檔、指定目標，以及派遣檔 `required_reads` 指定的 `design.md`、同線 `requirement-summary.md`、Developer 結案報告（若有）與前輪報告，不自行修改程式碼、執行建置或測試；`required_reads` 的檔案清單與回收程序見 `workflow-orchestration` skill `references/review-procedures.md`「Reviewer 派遣單與回收」。

## Workflow 自動推進鏈與共同收斂契約

Design 驗收通過後，主 Agent 依 `workflow-orchestration` skill「自動推進鏈」逐站推進 Developer 派生與回收、文件同步、Reviewer 判定、Analyst 需求意圖驗收與 Workflow 結案報告。各站的階段歸屬與交接檢查點時點見該節。每批工作回收並覆核後立即建立本機 commit，不等審查與需求意圖驗收；Workflow 直接在整合分支上進行時，commit 即落地，不需授權，須符合「授權分類」的落地條件。結案後的整理、落地、push 與發佈依「授權分類」與 `git-workflow` 註記模式。

自動推進鏈依「連續推進」逐站進行，停頓處置有兩類。

- 授權類停頓：「授權分類」中須當輪直接授權的動作（push、發佈等；advisor 諮詢在當下 Session 已授權者除外），等待使用者當輪回覆。整理與符合落地條件的落地不需授權，不在此停頓。轉述授權的判定依「授權期限」。
- 升級與收斂停止：業務語意缺口、範圍取捨、妥協確認或共同收斂契約的停止訊號，停止相依的派遣，保留證據，回報未閉合清單與替代方向，等待使用者選擇方向；不相依的站點依「遇真問題只停相依部分」繼續。

執行者無法完成工作時依「執行者轉移」處理，不屬收斂停止。Review 退回後的修正循環與派遣回收循環的未閉合問題同樣依「執行者轉移」計次，見下列判定順序之後的適用範圍。

收斂術語 `round`、`area-key`、`problem-key`、`closed`、`new-problem`、`severity`、`max-rounds`、`cycle_id`、`cycle_round`、`cycle_role` 與 `target-key` 的機械定義，`Minor` 的批次修正與候選，範圍變動時的循環重新起算，以及派遣回收與 Git 計數分開判定的規則，見 `workflow-orchestration` skill「共同收斂契約」與「循環識別與重新起算」。四處循環共用該契約與下列判定順序。

收斂判定依下列順序執行。

1. 沒有未閉合的 `Critical` 或 `Major`（含前輪遺留與本輪新增）時結束循環並進入下一站。剩餘的 `Minor` 由一次批次修正處理或記為候選，不為 `Minor` 單獨再開一輪複審。
2. 任一前輪 `Critical` 或 `Major` 問題連續兩輪未閉合時停止，保留證據並提出替代方向。
3. 同一 `area-key` 連續兩輪出現新的 `Major` 以上問題時停止，保留證據並提出替代方向。
4. 存在未閉合的 `Critical` 或 `Major`，這些問題均屬純技術可解，且未命中前兩項停止訊號時自動續行下一輪。新出現的 `Major` 在尚未形成兩輪同區域或同問題停止訊號前，依純技術路徑續行修正。
5. 修正需要改變 `requirement-summary.md` 的需求、範圍或 `design.md` 的已確認設計時停止，依升級兩道篩交由使用者拍板。
6. 同一循環的 `round` 達到 6 輪，或同一 `target-key` 的循環世代將達 `c3`（第三次另起循環）時停止，不以「仍有進展」覆寫安全上限；回報未閉合問題、證據與替代方向，取得使用者確認後才繼續。Review 與實作修正循環的 `round` 以同一 `cycle_id` 的 `cycle_round` 計；Design、Demo、派遣回收與 Git 修正循環以各自循環保存的 `round` 計。

**Review 修正與派遣回收循環的適用範圍**：這兩種循環不適用順序 2、順序 3 與順序 6 的 6 輪上限，改依「執行者轉移」。存在未閉合的 `Critical` 或 `Major` 而退回時，為目前的執行者計一次未完成並續行下一輪；累計達上限時轉給候選清單的下一位，選派入口回傳 `needs-user-decision` 時才停止並回報。順序 1、順序 4、順序 5 與順序 6 的 `c3` 上限照常適用。Design、Demo、文件同步與 Git 修正循環照常適用全部順序。目的是讓可由其他執行者解決的純技術問題不提早交給使用者。

## 驗證分層與 integration-verify 掛載點

Workflow 驗證四層（淺層探針、建置與測試 gate、缺陷審查、完整煙霧）的執行者、深度與時機見 `workflow-orchestration` skill「驗證分層」。

- `integration-verify` 掛載點：於交付節點（feature 整體完成、交付前）執行一次，由使用者手動觸發，不納入 Developer 結案自動流程。煙霧驗證的瀏覽器與桌面臨場取證由 Codex `test`（`type=test`，以 MCP 工具操作）執行，建置、可重跑測試專案與 API 取證依派工判準選派，由選派入口選出的 Claude 執行者在沙盒外執行，受測程式由主 Agent 以背景進程啟動並在驗證結束後依 §1.4「背景進程清理」關閉，判讀與修正迴圈決策留在 Claude 端；淺層探針與建置測試 gate 由 Claude 實作者執行，缺陷審查由 Codex `Reviewer` 執行（Codex 不可用時由選派入口選出的同家族執行者審查，目前為 Sonnet subagent）。
- Reviewer 不執行測試與動態驗證，正常路徑是讀取 Developer 結案報告附帶的原始輸出並做靜態核對；重跑唯讀命令的條件見 `agents/codex/reviewer.toml`「動態證據複核」。
- Maintainer 不承擔常規驗證，依進入類型執行 bug 診斷或需求調整；`Support Engineer` 只執行計畫指定的驗證步驟。

**需求意圖驗收不屬於上述四層。** 四層驗證的比對軸是「程式碼是否正確、是否符合 `design.md`」，需求意圖驗收的比對軸是「交付結果是否仍是當初談定的那件事」，兩者互不取代。此職責歸 `Analyst`，因為需求摘要與對話中達成的實作約束由 `Analyst` 產生並保管於 `handoff/<lineSlug>/requirement-summary.md`，其他 Agent 只拿得到轉述後的版本。執行方式見 `~/.ai-agents/agents/claude/analyst.md`。

**結案前文件同步也不屬於上述四層。** 它的比對軸是「使用者文件是否與改動後的行為一致、是否以讀者角度定稿」，不取代 Reviewer 審查。受影響文件清單非空時，主 Agent 依 `workflow-orchestration` skill `references/doc-sync.md` 執行一致性檢查、事實修正、最終編輯與事實核對，`Analyst` 於需求意圖驗收核對其完成。
