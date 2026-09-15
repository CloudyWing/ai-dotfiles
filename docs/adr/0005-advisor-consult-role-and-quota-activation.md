---
status: accepted
date: 2026-09-16
---

# ADR-0005：以 advisor 意見評估角色取代 deep 檔位

## Context

ADR-0004 將 `deep` 定為可選的實作檔位，但實作一律使用預設檔位即可完成，高推理模型只在需要判斷的節點有價值，且其額度 gate 使預設檔位在週額度偏低時也要等待授權。ADR-0004 的同線並行政策與語意檔位名稱原則仍然成立，正文卻同時保留已撤回的 `deep` 條款。

## Decision

檔位集合為預設與 `advisor` 兩項，`advisor` 只用於 `TaskType=advisor-consult` 的 evidence-only 唯讀資源派遣，搭配 Workflow、寫入模式或其他 TaskType 時在啟動前拒絕，實際設定位於 `~/.codex/advisor.config.toml`。advisor 在 primary 扣除 30% reserve 後足以容納預估量時自動啟動，或在使用者明確授權時略過額度檢查與 reserve、依剩餘額度縮小問題前綴啟動；預設檔位低於門檻時不需授權，以 reserve 0 繼續派工並接受因額度耗盡而終止。規則層只認語意檔位名稱，PID 並行檢查維持 `work-root`、`line-slug` 與 `write-mode` 三鍵比對，同線唯讀派遣上限為 2，寫入模式互斥。

## Consequences

本 ADR 成為檔位、advisor 啟動與同線並行政策的唯一有效入口，ADR-0004 標為 superseded，其中的 `deep` 檔位與 `deep-consult` 條款均已失效。額度耗盡造成的中止由中斷保全與 RecoveryHandoff 承接，已確認結論與未完成單位必須保留在證據中。使用者授權路徑的修正目前只經回歸測試驗證，首次在低額度下以真實派工完成回收前，應視為待補驗證。
