---
name: ai-profile
description: 'Use when 需要讀取、詢問或寫入專案 AGENTS.local.md 的 AI-PROFILE 區塊鍵（code-style.csharp、project-kind、workflow-depth、git-workflow），或需判定哪些鍵缺少而須一次詢問時。'
audience: agent
dispatch: inline
policy.allow_implicit_invocation: true
---

# AI-PROFILE 共用機制

本 Skill 定義專案 `AGENTS.local.md` 中 `AI-PROFILE` 區塊的格式、解析、錯誤處置、鍵登錄表、一次問完、非互動處置、本機排除與寫入。各鍵的取值對行為的影響，由鍵登錄表「負責的 skill」欄所列的 skill 定義。

## 區塊格式

`AGENTS.local.md` 位於專案根目錄。Git 專案為 `git rev-parse --show-toplevel` 的目錄，非 Git 專案為 work-root。檔案編碼為 UTF-8 無 BOM，以成對的完整獨立行標記保存鍵值，例如：

```text
<!-- AI-PROFILE:BEGIN -->
code-style.csharp: personal
project-kind: library
<!-- AI-PROFILE:END -->
```

## 解析規則

- 逐行讀取兩個標記之間的 `key: value`，鍵與值各自去除前後空白。
- 鍵只能由小寫英數、`.`、`-` 組成；值為非空的單行文字。
- 略過空行。鍵登錄表以外的鍵視為其他控制項，讀取時忽略，寫入時原樣保留。
- 已登錄鍵的值須與鍵登錄表「合法值」欄大小寫完全一致。

## 錯誤處置

兩類錯誤都向使用者指出錯誤位置，不猜測選擇，不修改檔案。

- **結構錯誤**：只有單邊標記或標記不是完整獨立行；檔案內有兩個以上 `AI-PROFILE` 區塊；區塊內有重複鍵、無法解析成 `key: value` 的非空行，或不合法的鍵。停止所有依賴 AI-PROFILE 鍵的工作。
- **值錯誤**：已登錄鍵的值不在合法值之內。停止阻擋範圍涵蓋該鍵的工作，以及依該鍵分流的規則所屬的工作；不改用其他值，也不套用未設定處置。

## 鍵登錄表

| 鍵 | 合法值 | 負責的 skill | 適用條件 | 阻擋範圍 | 缺少時處置 |
| --- | --- | --- | --- | --- | --- |
| `code-style.csharp` | `personal`、`standard`、`project` | `csharp-style` | 專案含 `*.csproj`、`*.sln`、`*.slnx`、`*.cs` 或 `*.csx` | 撰寫或修改 `*.cs`、`*.csx` | 詢問，選項依 `csharp-style` |
| `project-kind` | `library`、`application`、`sample` | `ai-profile` | 專案含 `instructions.md` §1.5 work-root 判定所列的技術棧根標記 | `generate-readme-zh-tw` 的專案分類；`integration-verify` 步驟一的套件判定與 `sample` 深度 | 詢問並附「推薦答案偵測」的推薦答案；未回答時各消費端採其未設定處置 |
| `workflow-depth` | `full`、`light` | `workflow-orchestration` | 進入 Workflow 時 | 不阻擋 | 不詢問；依 `instructions.md`「Workflow 深度」由 `project-kind` 推導 |
| `git-workflow` | `trunk`、`release-flow` | `git-workflow` | 專案位於 Git repo | commit、啟動 Workflow、建立分支 | 詢問並附 `git-workflow` skill「推薦值推導」的推薦答案；各值的語意由該 skill 定義 |

鍵缺少的判定為 `AGENTS.local.md` 不存在、沒有 `AI-PROFILE` 區塊，或區塊內沒有該鍵。

## project-kind

### 取值定義

| 值 | 定義 | 範例 |
| --- | --- | --- |
| `library` | 主要產出被其他程式碼引用，`public` 成員是對外契約 | 發佈為套件的類別庫 |
| `application` | 主要產出是給人或系統執行的程式，含 Web、桌面、CLI、背景服務 | Web 站台、桌面程式、dotnet tool |
| `sample` | 主要產出是示範或實驗，程式碼本身不長期維護也不對外提供契約 | 技術示範專案 |

鍵描述 repo 的主要產出，不依子目錄分別註記。

### 專案層解析

鍵為 `library` 時，同 repo 內下列專案不套用 `library` 規則，改依 `application` 處理。

- 測試專案：專案檔（含 `Directory.Build.props`）設定 `IsTestProject` 為 `true`，或有 `Microsoft.NET.Test.Sdk` 的 `PackageReference`。
- 非打包專案：專案檔（含 `Directory.Build.props`）設定 `IsPackable` 為 `false`。

鍵為 `application` 或 `sample` 時不做專案層覆寫。Web 專案以專案檔 SDK 為 `Microsoft.NET.Sdk.Web` 判定，供消費端區分 Web 與非 Web。專案層解析的輸出為有效類型與是否為 Web。

### 推薦答案偵測

推薦答案只用於詢問時附上，經使用者確認才寫入。依下列順序判定，命中即停止，並把命中的依據寫成理由。

1. repo 根目錄名稱或其上一層目錄名稱含 `Sample`、`Demo`、`Example`（不分大小寫）時，推薦 `sample`。
2. 專案檔 `OutputType` 為 `Library`（或未設定且 SDK 不是 Web、Worker）、`IsPackable` 不是 `false`，且有 `PackageId`、`Version` 或 `GeneratePackageOnBuild` 任一項，同時未設定 `PackAsTool` 時，推薦 `library`。
3. 專案檔 `OutputType` 為 `Exe` 或 `WinExe`，或 SDK 為 `Microsoft.NET.Sdk.Web`、`Microsoft.NET.Sdk.Worker`，或有 `UseWPF`、`UseWindowsForms`，或 `PackAsTool` 為 `true` 時，推薦 `application`。
4. `package.json` 專案沒有 `"private": true` 且有 `main`、`exports` 或 `types` 欄位時推薦 `library`；有 `bin` 欄位，或有前端框架與 dev server 時推薦 `application`。
5. 以上皆未命中（含其他技術棧）時，推薦 `application`，理由註明「無打包與示範特徵可偵測，採預設」。

新專案尚無專案檔時只適用第 1 與第 5 項，並參考建立要求中的描述。

## 一次問完

- **觸發**：鍵登錄表中任一鍵在其阻擋範圍內第一次被需要，且該鍵缺少。
- **收集**：列出鍵登錄表中適用此專案、缺少，且缺少時處置為詢問的全部鍵，包含阻擋範圍不涵蓋當前工作的鍵。`workflow-depth` 不詢問，不列入。本 Session 內使用者已略過的鍵，只在其自身阻擋範圍涵蓋當前工作時再次列出。
- **呈現**：在同一輪訊息列出全部鍵。每個鍵附合法選項、推薦答案與理由；負責的 skill 有選項差異者（例如 `code-style.csharp` 的新專案與既有專案）依該 skill 提供選項。阻擋範圍涵蓋當前工作的鍵標示必答，其餘標示可略過。
- **等待**：必答鍵收到答案前，停止被阻擋的工作，不被阻擋的工作照常進行。可略過的鍵未回答時照常工作，留待其阻擋範圍被需要時再問。
- **寫入**：依「寫入」一次寫入本輪收到的全部鍵，未回答的鍵不寫。推薦答案須經使用者確認（含「照推薦」之類的明確回覆）才寫入。
- **後續動作**：`code-style.csharp` 的值為 `project` 時，寫入後依 `csharp-style`「project 範例檔」取樣。

## 非互動執行端

無法向使用者提問的執行端（例如 Codex 派遣）依下列方式處理：

- 停止阻擋範圍涵蓋當前工作的缺少鍵所對應的工作，不寫入區塊、不猜測、不改用其他值。
- 在報告寫明缺少的鍵名、被停止的工作與 `AGENTS.local.md` 的絕對路徑；格式錯誤時指出錯誤位置。
- 列出缺少但不阻擋當前工作的鍵，標示「未設定」與所採的未設定處置，照常工作。
- 完成不依賴缺少鍵的其他工作。

主 Agent 依 `codex-dispatch` skill `references/start.md`「AI-PROFILE 前置檢查」在派工前補齊。

## 本機排除

`AGENTS.local.md` 與鍵登錄表負責的 skill 指定的本機檔案（目前為 `csharp-style` 的 `.local/ai-context/csharp-style-project.md`）屬個人本機資料，寫入前先確認不會被團隊看到。Git 專案逐項執行下列檢查：

1. 執行 `git ls-files --error-unmatch <path>`。命令成功代表檔案已被追蹤，停止寫入並提示使用者先處理追蹤狀態，不宣稱已隱藏。
2. 執行 `git check-ignore -q <path>`。命令成功代表已被排除，直接寫入。
3. 未追蹤且未排除時，將路徑追加至 `git rev-parse --git-common-dir` 所指目錄下的 `info/exclude`，再以 `git check-ignore -q <path>` 確認生效後寫入。此做法同時適用於 worktree。

非 Git 專案照常寫入本機路徑，並在回應中說明此專案沒有 Git 排除機制。本機排除只防止檔案進入版控，不提供存取權限控制。

## 寫入

1. `AGENTS.local.md` 不存在時，以 `~/.ai-agents/templates/AGENTS.local.md.template` 建立。
2. 寫入前重新讀取檔案，與解析時的內容比對；內容已變動時停止，重新讀取後再處理，不覆寫其他工作的修改。
3. 已有區塊時只插入或修改本輪收到的各鍵所在行；沒有區塊時，在檔尾追加完整區塊。區塊外內容與其他鍵全部保留，本輪的全部鍵在一次寫入中完成。
