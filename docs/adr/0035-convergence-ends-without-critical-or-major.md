---
status: proposed
date: 2026-11-11
---

# ADR-0035：共同收斂契約以沒有未閉合的 Critical 或 Major 結束循環

## Context

共同收斂契約原本要求全部檢查項目通過才結束循環，新出現的 `Minor` 也會讓 Design、Review、實作修正、派遣回收與 Git 修正循環多開一輪，增加重做的輪次與派工成本。循環的輪數也沒有循環識別，範圍變動後重新起算時無從判斷是否在繞過 6 輪上限。

## Decision

循環在沒有未閉合的 `Critical` 或 `Major` 時結束，剩餘的 `Minor` 以一次批次修正處理或記為候選；批次修正沒有改到機制條款時不觸發新一輪審查。Review 與實作修正循環以 `cycle_id` 與 `cycle_round` 計輪，審查目標擴大或需求、設計被改動時另起新循環重新計輪，同一 `target-key` 的第三次循環（`c3`）先停下取得使用者確認。排除收緊輪數上限、維持全部通過才結束，以及重設 manifest `round` 三個方案，因為前兩者不處理 `Minor` 造成的額外輪次，後者會讓輪數上限失去作用。

## Consequences

`Minor` 不再單獨觸發複審，循環輪數下降，代價是部分 `Minor` 以候選形式留到後續處理。批次修正改到機制條款時仍會開新循環，次數由 `c3` 停止條件限制；`instructions.md`、`analyst.md`、`workflow-orchestration`、`codex-dispatch` 與 `git-workflow` 的收斂判定須維持同一套說法。
