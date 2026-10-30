---
name: workflow-orchestration
description: 'Use when 執行或回收 Clarify => Design => Implement => Review => Accept Workflow、判定其共同收斂循環，或規劃 Workflow 驗證與交付時。'
audience: agent
policy.allow_implicit_invocation: true
---

# Workflow 推進與收斂

本 Skill 提供 `Clarify => Design => Implement => Review => Accept` Workflow 的逐站推進步驟、共同收斂契約的術語定義與驗證分層。角色權責、授權類停頓、升級與收斂停止的判定順序由 `instructions.md` §1.5「Workflow 自動推進鏈與共同收斂契約」規定；交接檢查點的建檔內容依 `instructions.md` §1.4「Workflow 交接檢查點」。

## 自動推進鏈

Design 驗收通過後，主 Agent 依序執行下列自動推進鏈。交接檢查點的建檔與建檔內容仍依 §1.4 執行，建議接手指令輸出後原 Session 直接繼續。

1. 寫入 `design-accepted` 交接檢查點，輸出建議接手指令後直接派工進入 Developer。
2. 派遣 Developer 並回收結果。Workflow Developer 收下時，先將成果套回來源工作樹，不建立 Phase commit，並保留 dispatch worktree 供後續 Reviewer 退回續行。
3. 完成 Developer 回收後寫入 `developer-collected` 交接檢查點。
4. 命中 Reviewer 必發清單時，命中必發清單即直接派出 Reviewer，不詢問使用者。未命中時記錄一句不發理由，直接進入 Analyst 需求意圖驗收。
5. Reviewer 以純技術原因退回時，使用保留的同一 dispatch worktree 與 thread 自動續行 Developer 修正；修正完成後回到 Developer 回收與 Reviewer 判定。
6. Reviewer 收下時進入 Analyst 需求意圖驗收。需求意圖驗收完成後輸出 Workflow 結案報告。
7. 結案報告完成後等待使用者當輪授權 commit；取得授權後才執行 Phase commit 回收，完成驗證與報告同步後移除 dispatch worktree。

第 1 步是 Design 階段的收尾，第 2、3 步屬 Implement，第 4、5 步屬 Review，第 6、7 步屬 Accept。Accept 階段涵蓋 Analyst 需求意圖驗收、Workflow 結案報告，以及使用者授權後的 Phase commit 回收。

## 共同收斂契約

四處循環共用下列收斂契約。下游規則檔只補充自身循環的識別來源與驗收方式。

| 名稱 | 機械定義 | 來源 |
| --- | --- | --- |
| `round` | 一次修正連同其驗收或回歸判定為一輪，初次執行為第 1 輪。後續續行各增加 1 輪 | 交接 prompt、回報或回歸紀錄 |
| `area-key` | 同一函式或同一節規則的穩定識別。規則文件使用檔案絕對路徑加最近的 Markdown 標題；檢查清單使用所屬循環與檢查項目區段 | 原始檔案標題、函式位置或驗收清單區段 |
| `problem-key` | 同一問題跨輪次不變的識別。Review 使用 `F-<三位數>`；Design 與 Demo 使用驗收檢查項目 key；派遣回收使用 `dispatchSlug` 加第 5 欄驗收列序號；Git 使用既有 finding ID 或建立時指定的固定 key | Reviewer 報告、驗收清單、派遣單第 5 欄或 Git 修正紀錄 |
| `closed` | 前輪仍未解決的問題，在本輪相同 key 的驗收結果通過，且本輪沒有該 key 的反證 | 本輪完整驗收輸出與證據 |
| `new-problem` | 本輪問題 key 不在前輪未解決問題集合，且沒有同一 key 的改寫或重新命名 | 前後輪問題集合比對 |
| `severity` | `Critical`、`Major`、`Minor`。Review 沿用 `reviewer.toml`；其他循環依檢查項目影響映射 | Reviewer 規則或各循環的嚴重度映射 |
| `max-rounds` | 6 輪。只防止失控，不取代問題閉合與方向變更判定 | 需求摘要與設計文件 |

收斂判定的執行順序與停止門檻見 `instructions.md` §1.5「Workflow 自動推進鏈與共同收斂契約」。

`RecoveryPrecheck` 未通過的 `PromptNotDelivered` 屬啟動契約錯誤。先修正啟動條件，再重新派遣；此狀態不計入派遣回收計數。純技術的報告欄位缺漏、驗收輸出缺漏與格式錯誤直接進入自動補件路徑，不形成使用者詢問站點。`dispatch-return-count` 與 Git 的 `return-count` 分開保存、分開增加、分開判定，任一循環的成功或續行都不重設另一循環的計數。

## 驗證分層

Workflow 的驗證職責按深度分四層，各層不重複執行他層的驗證：

| 層 | 執行者 | 深度 | 時機 |
| --- | --- | --- | --- |
| 淺層探針 | Developer | 對改動的端點或畫面單發確認路徑通 | 每階段完成後，依 `design.md` §6 |
| 建置與測試 gate | Developer | 建置與既有測試各執行一次 | 結案時一次 |
| 缺陷審查 | Reviewer | diff-scoped 靜態審查，不執行測試 | 主 Agent 依 Reviewer 派遣判準以派遣單發動 |
| 完整煙霧 | `integration-verify` skill | 多情境、寫入回查、持久化往返 | 交付節點 |

`integration-verify` 的觸發方式、Reviewer 的動態證據複核條件與需求意圖驗收的歸屬見 `instructions.md` §1.5「驗證分層與 integration-verify 掛載點」。
