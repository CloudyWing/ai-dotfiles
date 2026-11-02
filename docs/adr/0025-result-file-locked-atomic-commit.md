---
status: accepted
date: 2026-11-02
---

# ADR-0025：派遣結果檔以共用鎖、hash 重讀與原子替換提交

## Context

Inspect 的結果綁定、Dispatch 的初始與失敗結果，以及其他結果寫入者可能同時更新同一份結果檔。各 writer 各自實作 check-then-replace 時，競態沒有閉合，後寫者會以過期內容覆蓋先寫者。

## Decision

所有遵守協定的 writer 經 `Write-DispatchAtomicJsonDocument` 提交，依正規化後的結果檔路徑取得相同的 deterministic lock，持鎖期間重新讀取目前 hash 並與預期 hash 比對。不一致時以 `DispatchResultBindingConflict` 拒絕且保留現有檔案，一致才以 `File.Replace` 等原子方式替換，並在路徑 guard 通過後才進入此流程。`Resolve-DispatchInspectBinding` 等呼叫端不得另寫一套 check-then-replace。

## Consequences

保護範圍只涵蓋遵守同一協定的 writer，外部任意寫入者不受保護，驗證與結案不得宣稱受協定保證。新增會更新結果檔的程式路徑時必須呼叫同一函式，衝突時由呼叫端依回收契約重新取得最新 binding。
