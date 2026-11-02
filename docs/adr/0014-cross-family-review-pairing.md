---
status: accepted
date: 2026-11-02
---

# ADR-0014：審查者與實作者採跨模型家族配對

## Context

審查者與實作者屬同一模型家族時，家族共有的盲點不易被發現，而審查原本一律派給 Codex `Reviewer`，Codex 實作的變更也由 Codex 審查。

## Decision

審查者依序判定，規則檔機制條款改寫由 Codex `Reviewer`，Codex 執行端的變更由 Claude Sonnet subagent，Claude 家族（主 Agent、Haiku subagent）的變更由 Codex `Reviewer`，每個變更唯一對應一位審查者。審查範圍含兩個家族時以新增與刪除行數較多者為實作者，Workflow 混合時按 Phase 切分，帳號全數不可用而由 Claude 承接時改由 Sonnet subagent 審查並在 exceptions 註明「同家族審查」。排除一律由 Codex 審查與一律由 Claude 審查，兩者都會讓部分變更由同家族審查。

## Consequences

是否發動審查仍由必發清單決定，本決策只決定審查者，`Frontend Reviewer` 與 `Contract Auditor` 維持 Codex。Sonnet 審查路徑需要派生契約與鏡像報告 `review-report-claude.md`，維護於 `workflow-orchestration`。
