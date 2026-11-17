---
status: accepted
date: 2026-11-17
---

# ADR-0043：派工執行者由登錄表與選派入口判定

## Context

派工歸屬、審查配對與帳號切換寫成規則文字，分散在 ADR-0007、ADR-0014 與 ADR-0023 所記的做法中，條件改動時要同步多處。ADR-0042 之後，執行者需要依任務類型與能力比對，並在 Codex 不可用時改派。

## Decision

執行者的受理類型、能力、排序、未完成次數上限、備援 model 與檔位設定只寫在 `scripts/dispatch/executor-registry.json`，由無副作用的選派入口 `scripts/Select-DispatchExecutor.ps1` 先以必要條件過濾，再依優先條件與排序值選出。跨模型家族審查是優先條件，找不到時由同家族承接；離線只依服務端拒絕判定，同一任務累計三次未完成即轉給下一位候選。排除的方案是維持規則文字的配對表，以及由主 Agent 依額度快照指定帳號。

## Consequences

新增或調整執行者只改登錄表。Codex 檔位設定檔由登錄表產生，各機器須以 `scripts/Setup-AIGlobalConfig.ps1` 建立帳號目錄的連結，否則派工入口在啟動前停止。使用者只在候選用盡時才需要決定執行者。
