---
name: generate-editorconfig-by-techstack
description: 依專案技術棧與 .NET 框架版本，從範本過濾出對應的 .editorconfig 段落並補齊，保留既有自訂偏好。
disable-model-invocation: true
---

# 產生或補齊 .editorconfig

## 範本來源

本 Skill 的規則內容以 `~/.ai-agents/templates/.editorconfig` 為單一來源。修改建議規則時，**只改範本檔，不改 SKILL.md**。SKILL.md 僅描述執行流程與過濾邏輯。

範本檔位於使用者家目錄下的 `.ai-agents/` 專案。執行時若找不到範本檔，告知使用者後流程終止，不自行重建內容。

### 範本的 Profile 機制

範本含 `# @profile: <name>` 段落標記，由本 Skill 依技術棧過濾：

| Profile | 適用情境 | 過濾規則 |
| --- | --- | --- |
| 未標記 | 所有技術棧通用 | 一律保留 |
| `csharp-modern` | C# 8+ / .NET Core / .NET 5+ | `<TargetFramework>` 為 `net5+` / `netcoreapp*` / `net8.0-*` 等現代框架時保留；`net4x` 時整段移除 |
| `dotnet-framework` | .NET Framework 4.x | `<TargetFramework>` 為 `net4x` 時保留；現代 .NET 時整段移除 |

非 .NET 技術棧執行時，所有 `.NET / C#` 相關段落（含未標記的 `[*.{cs,vb}]`、`[*.cs]` 與兩個 profile 段）一律跳過。

## 執行步驟

### 1. 偵測技術棧與框架版本

掃描專案根目錄：

| 偵測依據 | 識別結果 |
| --- | --- |
| `*.csproj`、`*.sln`、`*.slnx` | C# / .NET 專案 |
| `package.json` | Node.js / 前端 |
| `*.py`、`pyproject.toml` | Python |
| `go.mod` | Go |
| `Dockerfile` | Docker |
| `*.ps1` | PowerShell |

偵測到 .NET 專案時，**必須**進一步讀取 `*.csproj` 的 `<TargetFramework>` 或 `<TargetFrameworks>` 欄位，判定屬於：

- **.NET Framework**（`net4x`，如 `net472`、`net48`）→ 套用 `dotnet-framework` profile
- **Modern .NET**（`net5.0` 以上、`netcoreapp*`、`net8.0-windows` 等）→ 套用 `csharp-modern` profile
- **多目標**（`<TargetFrameworks>` 同時含 Framework 與 Modern）→ 兩個 profile 都套用，由 IDE 依檔案副檔名與 pattern 解析

若 solution 內多個專案目標框架不一致，以**最舊**的為準（最保守，避免新設定漏給舊專案）。

### 2. 讀取範本

讀取 `~/.ai-agents/templates/.editorconfig`，解析三類段落：

- **通用段落**：未標記的 `[*]`、`[*.md]`、`[*.{json,...}]`、`[*.py]`、`[*.ps1]`、`[*.{csv,bat,cmd}]`、`[*.{cs,vb}]`、`[*.cs]`（不含 `# @profile` 標記）
- **`csharp-modern` 段落**：標記 `# @profile: csharp-modern` 之後到下一個 `# @profile` 或檔尾之間的所有段落
- **`dotnet-framework` 段落**：標記 `# @profile: dotnet-framework` 之後到下一個 `# @profile` 或檔尾之間的所有段落

### 3. 依技術棧過濾段落

依步驟 1 的偵測結果，組合最終輸出：

| 偵測結果 | 套用的範本段落 |
| --- | --- |
| 純 .NET Framework | 通用段落 + `dotnet-framework`，移除所有 .NET 相關段落以外的非 .NET 技術段（若專案無 Python / Go 等） |
| 純 Modern .NET | 通用段落 + `csharp-modern` |
| 多目標 .NET | 通用段落 + `csharp-modern` + `dotnet-framework` |
| 非 .NET 技術棧 | 通用段落，但**移除** `[*.{cs,vb}]` 與 `[*.cs]`（純 C# 設定對非 .NET 專案無用） |
| 混合 .NET + 其他 | 通用段落 + 對應 .NET profile |

非 .NET 通用段落（`[*.py]`、`[*.ps1]` 等）即使該專案無此檔案類型也保留，因為 glob filter 不會誤套用，且未來新增該類型檔案時可直接生效。

### 4. 讀取既有 .editorconfig

若 `.editorconfig` 已存在：

1. 完整讀取現有內容。
2. 識別使用者已自訂的 pattern 與設定鍵（如刻意設定的 `indent_size`、`end_of_line` 等）。
3. 後續步驟僅**補齊缺少的段落或設定鍵**，不覆蓋已有設定。

若不存在，後續步驟以步驟 3 的過濾結果建立全新檔案。

### 5. 衝突偵測

若已存在 `.editorconfig`，比對現有設定鍵與本次過濾後內容的差異：

1. 列出**衝突點**：同一個 pattern 與設定鍵但值不同（如現有 `indent_size = 2`，範本為 `4`）。
2. 對每個衝突點，提供**最小變更方案**：優先保留使用者已設定的值，僅補齊完全缺少的設定鍵。
3. 若衝突點超過 3 個，在進入步驟 6 前先列出衝突清單，讓使用者決定哪些保留、哪些覆蓋。

特別注意以下既有設定不可靜默覆蓋：

- 已存在的 `[*.{cs,vb,aspx,master}]` `charset` 設定（與 BOM 策略相關，必須確認）。
- 已存在的 `dotnet_diagnostic.*.severity`（影響建置警告等級）。
- 已存在的命名規則（`dotnet_naming_*`）。

若無衝突，直接進入步驟 6。

### 6. 套用前確認

顯示完整的 `.editorconfig` 預覽內容（或僅顯示新增/修改的段落），**停止等待使用者確認**後再執行寫入。確認格式：

```
偵測技術棧：[結果]
套用 Profile：[結果]

以下是將要寫入的 .editorconfig 內容（新增段落）：

[*]
charset = utf-8
...

確認後將寫入，請回覆「確認」。
```

若使用者要求調整，修改後重新顯示確認。

### 7. 寫入結果

**已存在 .editorconfig**：使用 Merge 模式，將缺少的段落或設定鍵插入對應位置，不移動或覆蓋已有內容。**寫入時必須移除所有 `# @profile: ...` 標記行**（標記僅供範本與 skill 過濾使用，不應出現在最終專案檔案中）。

**不存在 .editorconfig**：依步驟 3 的過濾結果建立新檔，同樣移除 `# @profile` 標記。

### 8. 完成確認

輸出：

- 偵測到的技術棧與 `<TargetFramework>`。
- 套用的 Profile 清單。
- 新增的段落或設定鍵清單。
- 略過（已存在）的段落清單。
- 衝突清單與處理結果。
- 範本來源路徑。
