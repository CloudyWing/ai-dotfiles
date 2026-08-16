---
name: architecture-improvement
description: '以 Git hotspot 縮小分析範圍，使用 deletion test 篩選改善候選並產出架構改善報告。'
audience: human
disable-model-invocation: true
policy.allow_implicit_invocation: false
---

# Architecture Improvement

## 使用時機

使用者希望改善模組邊界、Interface、依賴方向、耦合程度或大型模組的變更成本時，使用本 Skill。此流程先提供可驗證的候選清單，再由使用者決定是否進入實作。

## 分析範圍

### 1. 以 Git hotspot 限定範圍

先取得固定基準：

```powershell
git rev-parse HEAD
```

依固定基準檢查近期變更頻率、變更檔案數與同一檔案的重複變更。使用 `git log --stat`、`git log --name-only` 或指定檔案的歷史資料建立證據。分析結果必須列出：

- 候選檔案或目錄。
- 變更次數與統計期間。
- 反覆變更的功能群組或責任線索。
- 目前可觀察到的依賴方向與測試影響。

只把具有 Git 證據且能對應到具體程式碼的範圍列為候選。大型目錄、整個 solution 或單純命名不一致的項目，不得直接視為改善目標。

### 2. 使用 deletion test 篩選候選

對每個候選提出刪除測試。假設移除該模組、Interface、Adapter 或依賴後，逐項檢查：

1. 是否仍有編譯時參考、註冊或反射呼叫。
2. 是否破壞公開 API、跨模組契約或資料流。
3. 是否造成測試失去必要的 seam，或讓測試只能依賴實作細節。
4. 是否能以較小的模組、單一方向的依賴或既有抽象承擔原本責任。

刪除測試只用來判斷候選的 leverage 與 locality，不在使用者確認前直接刪除或重構程式碼。與 `codebase-design` Skill 的 module、interface、seam、adapter、depth 詞彙保持一致。

## 交付流程

1. 掃描 Git hotspot 與候選程式碼。
2. 對每個候選執行 deletion test，保留檢查證據。
3. 先產出候選清單、影響範圍、風險與建議順序。
4. 將報告寫入 `<work-root>/.local/ai-sessions/report/architecture-review.md`。
5. 等使用者選定候選與改動範圍後，才進入設計或實作階段。

報告至少包含以下標題：

```markdown
# Architecture Review
## 分析基準
## Git Hotspot
## Deletion Test 候選
## 需要使用者決定
```

若報告已存在，先保留既有報告，再以本次任務的備份規範處理覆寫。報告只呈現可由 Git、程式碼或測試引用驗證的事實；無法確認的反射、執行期註冊或外部契約列為需手動確認。

## 邊界

- 本 Skill 不取代 `Cleanup`。`Cleanup` 處理語法現代化、死程式碼與既有規範清理。
- 本 Skill 不直接決定模組拆分、公開 API 變更或資料流改造。
- 未取得使用者選定範圍前，不修改程式碼與專案設定。
- 不使用外部網頁產生報告，候選依據限定為目標 repository 的 Git、程式碼與測試。
