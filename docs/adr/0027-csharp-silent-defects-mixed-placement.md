---
status: accepted
date: 2026-11-02
---

# ADR-0027：靜默缺陷規則混合收納，C# 變更一律載入 csharp-silent-defects

## Context

合法且沒有編譯警告的執行期陷阱，在小資料量、單一 process 與固定文化的開發環境不易顯現，正式環境才暴露。這類規則橫跨背景服務、快取、EF Core、SQL 等元件，全放進 `instructions.md` 會增加所有任務的固定 context，全搬入同一 skill 又會與元件專屬 skill 重複。

## Decision

跨元件的條目收納於 `csharp-silent-defects`，每條 `SD-` 規則須同時通過四條篩選判準，框架差異寫在同一條目。只屬單一元件的規則留在 `csharp-background-service`、`redis-caching`、`ef-core`、`sql-query` 等 skill，維持唯一歸屬，`instructions.md` 的 `*.cs` 載入列追加 `csharp-silent-defects`。排除依 framework 分章，也排除只依 analyzer 警告判定。

## Consequences

所有 C# 變更都增加 `csharp-silent-defects` 的載入量，因此每條規則限於一到兩句加一條機械判準。新增陷阱時先判斷歸屬，已有元件專屬 skill 者寫入該 skill，不在本 skill 重複收錄。
