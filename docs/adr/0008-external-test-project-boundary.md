---
status: accepted
date: 2026-10-13
---

# ADR-0008：外部測試專案的引用方式與原專案不侵入邊界

## Context

部分舊 .NET 專案的架構無法直接撰寫單元測試，或因團隊合作不適合把測試專案放進正式 repo，但仍需要降低修改一處造成其他行為回歸的風險。測試若要求修改原專案（加入測試接縫、`InternalsVisibleTo`、改 `.csproj` 或 `.sln`），會讓團隊成員的版控出現非預期變更。

## Decision

`legacy-test-harness` Skill 將測試專案放在原 repo 之外，以 `ProjectReference` 或建置後的 DLL 引用被測程式，原專案版控內所有追蹤檔案（含原始碼、`.csproj`、`.sln`、設定檔）一律不變，只允許 `bin`、`obj` 等建置輸出。相依以 NSubstitute、反射或選用的執行期替換在測試端切斷，無法切斷且需要真實資料庫、HTTP 或 UI 的行為交給既有整合測試 Skill，不以外部宿主或隔離資料庫的黑箱整合測試取代。

## Consequences

不侵入的證據為對原專案執行 `git status` 與 `git diff`，追蹤檔案有任何變更即判定不通過。無法在原專案外切斷的相依會留下「未覆蓋與原因」紀錄，測試採盡力而為，覆蓋率不作為驗收標準。
