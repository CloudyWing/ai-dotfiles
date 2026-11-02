---
status: accepted
date: 2026-11-02
---

# ADR-0012：C# 風格以 personal、standard 範本與 project 範例檔三選一承載

## Context

C# 風格原本由 `csharp-style` 依鄰近程式碼推斷，同一專案的結果因檔案而異，`.editorconfig` 範本也只有 personal 一版。

## Decision

`code-style.csharp` 在 `personal`、`standard`、`project` 之間三選一。`personal` 對應 `templates/.editorconfig` 與 `references/personal.md`，`standard` 對應 `templates/.editorconfig.standard` 且不載入 personal 參考檔，`project` 只提供既有專案選擇，首次取樣後寫入本機 `.local/ai-context/csharp-style-project.md` 且不對應範本。每個專案只依註記決定風格，不為判定風格掃描鄰近程式碼，專案 `.editorconfig` 可約束的規則優先。

## Consequences

新專案只提供 `personal` 與 `standard`，日常開發不主動產生或改寫 `.editorconfig`，產生仍走 `generate-editorconfig-by-techstack`。`project` 範例檔屬本機排除路徑，換機器需重新取樣；排除提供 project 版範本與把個人風格放入團隊追蹤檔。
