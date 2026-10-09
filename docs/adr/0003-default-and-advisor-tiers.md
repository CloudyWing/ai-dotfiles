---
status: accepted
date: 2026-10-09
---

# ADR-0003：檔位集合為預設與 advisor

## Context

`agents/codex/*.toml` 的頂層鍵只允許 `name`、`description` 與 `developer_instructions`，寫入其他鍵會使 Codex 靜默丟棄整份 agent 定義，因此模型設定無法綁在 agent 定義上。實作一律以預設檔位即可完成，高推理模型只在需要判斷的節點有價值，先前以可選實作檔位與額度 gate 啟動高推理模型的做法讓派工在額度偏低時卡在等待授權。

## Decision

規則層只認語意檔位名稱，集合為預設與 `advisor` 兩項，實際 model 與 reasoning effort 留在 `~/.codex/<檔位名稱>.config.toml`。`advisor` 只用於 `TaskType=advisor-consult` 的 evidence-only 唯讀資源派遣，只讀 evidence pack 並核對其 SHA-256，搭配 Workflow、寫入模式或其他 TaskType 時在啟動前拒絕；每次諮詢由主 Agent 先向使用者提出授權請求，以 `AdvisorRequestSource=user-explicit` 啟動，當下 Session 的「送顧問不必詢問」授權只在該 Session 有效。排除的方案為 `bulk`／`deep` 實作檔位與依額度門檻自動啟動 advisor。

## Consequences

model id 改名或配比調整只改本機設定，規則層不洩漏模型代號；代價是 profile 檔不進版控，換機器需重新建立，由 `Setup-AIGlobalConfig.ps1` 的環境檢查與 README 前置需求承接。Codex 遇到不存在的 profile 會靜默回退預設值，檔位值域只能由規則層以白名單約束。
