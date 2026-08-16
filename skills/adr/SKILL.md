---
name: adr
description: '依決策門檻建立追加式 Architecture Decision Record，管理序號、狀態與被推翻的決策。'
audience: human
disable-model-invocation: true
policy.allow_implicit_invocation: false
---

# Architecture Decision Record

## 寫入門檻

只有下列三條全部成立時才建立 ADR：

1. 決策會影響多個模組、長期行為或公開契約。
2. 存在需要記錄的替代方案、取捨或風險。
3. 未來維護者需要知道採用理由才能安全修改系統。

任一條不成立時，將決策留在原本的設計文件或程式碼脈絡，不建立 ADR。

## 建立規則

- 先讀取 `docs/adr/` 的檔名，取目前最大四位數序號加一；不存在時從 `0001` 開始。
- 使用 `templates/adr/0000-template.md` 的 frontmatter，`status` 必須為 `proposed`、`accepted`、`rejected` 或 `superseded` 之一。
- 正文的 `Context`、`Decision` 與 `Consequences` 各以 1 至 3 句話完成，內容直接記錄決策與可驗證影響。
- ADR 採追加式寫入，不覆寫或重排既有 ADR。若舊決策被推翻，建立新序號的 ADR，並只將舊 ADR 的 `status` 標為 `superseded`。
- 已否決的方案以 `status: rejected` 保留，讓後續設計知道它已被評估且不應直接重提。

## 驗證

- 確認新檔案序號未與既有 ADR 衝突。
- 確認 frontmatter 有 `status`，且正文每個區段符合 1 至 3 句話限制。
- 確認既有 ADR 的正文未被改寫，推翻關係由新 ADR 與舊 ADR 的狀態共同表達。
