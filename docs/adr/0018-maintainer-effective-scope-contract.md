---
status: accepted
date: 2026-11-02
---

# ADR-0018：Maintainer 與 Support Engineer 的有效範圍與交付契約

## Context

Maintainer 跨回合會遺失使用者已確認的範圍與限制，Support Engineer 在契約不完整時自行推定範圍，搜尋不限也曾被誤當成修改不限。

## Decision

Maintainer 以 in-context 的有效範圍狀態承接連續回合，提出或派出變更前以一行回述有效範圍、搜尋範圍、持續限制、本輪差異、使用者要求與 Agent 推定，以使用者需求與改動計畫雙重驗收，並在多義高影響操作未明確授權時先列出具體效果範圍再取得決策。Support Engineer 要求交付契約含目標、有效範圍、本輪差異、先前決策、排除項目、`searchScope` 與 `modificationScope`、持續限制、驗證條件及 `contractVersion`，缺漏或矛盾時停止並回報上游，有派遣單的 `task` 以派遣單為唯一契約。排除完整歷史轉送、強制計畫落檔與讓 Support Engineer 自行修訂範圍。

## Consequences

上游傳入的 fix-plan 未帶新契約欄位時 Support Engineer 會停止並回報，這是設計帶來的行為變化。規則只寫在兩份 TOML 的 `developer_instructions`，頂層鍵維持三個，防護效果仍須在實際對話中觀察。
