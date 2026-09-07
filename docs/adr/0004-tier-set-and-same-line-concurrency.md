---
status: accepted
date: 2026-09-07
---

# ADR-0004：檔位集合與同線並行政策

## Context

ADR-0001 記載的檔位集合為 `bulk` 與 `deep`，ADR-0002 規定同線維持單一活躍實例，兩者的部分條款已不符現行契約：檔位集合改為預設與 `deep` 兩項，唯讀派遣則已放行同線並行。兩份 ADR 的其餘條款仍然有效，但 Agent 以 ADR 作為權威時無法分辨哪些條款仍適用。

## Decision

檔位集合為預設與 `deep` 兩項，`bulk` 不再存在；規則層只認語意名稱、實際設定留在 `~/.codex/<檔位名稱>.config.toml` 的原則維持，`--profile` 僅適用於 runtime command。PID 並行檢查改以 `work-root`、`line-slug` 與 `write-mode` 三鍵比對，同線兩個唯讀派遣可並行且上限為 2，任一方為寫入模式時維持互斥；`lineSlug` 作為線層識別與 manifest 登記的原則維持。

## Consequences

本 ADR 成為檔位與並行政策的唯一有效入口，ADR-0001 與 ADR-0002 標為 superseded，其正文僅保留為決策沿革。同線並行的上限取決於回收端的單線處理能力，調整上限前需重新評估統籌端的負載。
