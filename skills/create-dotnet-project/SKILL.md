---
name: create-dotnet-project
description: 建立新的 .NET 方案：詢問 C# 風格並寫入註記，以 slnx 格式建立方案、src 與 tests 實體資料夾及 Solution Folder，再依序產生 .editorconfig、.gitignore、.gitattributes 與專案層設定。Use when 使用者要求建立新的 .NET 方案或專案骨架時；既有專案不適用。
audience: agent
dispatch: inline
policy.allow_implicit_invocation: true
---

# 建立新的 .NET 方案

本 Skill 是新 .NET 方案的編排入口，完成後專案具備 `.slnx`、一致的實體資料夾與 Solution Folder，以及依風格註記產生的 `.editorconfig`。各步驟需要使用者逐項確認，因此由 Claude 端直接執行。既有專案的開發與設定補齊不經本 Skill。

## 輸入

依序取得下列輸入，缺少時詢問使用者，不自行假設：

| 輸入 | 用途 |
| --- | --- |
| 專案根目錄 | 方案與設定檔的落點，使用絕對路徑 |
| solution 名稱 | `dotnet new sln --name` 的值，也是 `.slnx` 檔名 |
| 目標框架 | 例如 `net10.0`；方案尚無 `*.csproj` 時，傳給 `generate-editorconfig-by-techstack` 判定 profile |
| 專案模式 | `solo` 或 `team`，傳給 `project-setup` |

## 前置檢查

任一項不成立時停止，回報原因與已建立項目，不覆寫既有檔案，不下載或安裝 SDK：

1. 執行 `dotnet --version` 取得實際選定的 SDK 版本。
2. 執行 `dotnet new sln --help`，確認輸出列有 `--format` 選項；沒有時代表 SDK 早於 9.0.200，停止。
3. 專案根目錄已存在任何 `*.sln`、`*.slnx` 或 `*.csproj` 時視為既有專案，停止。根目錄不存在時建立該目錄。

## 執行步驟

### 1. 確認 Git 狀態

在專案根目錄執行 `git rev-parse --show-toplevel`。不是 Git 專案時，詢問使用者是否執行 `git init`，依使用者的明確決定處理；使用者不初始化時，後續依非 Git 專案處理風格註記，並在完成回報中說明沒有 Git 排除機制。

### 2. 詢問風格並寫入註記

依 `csharp-style` skill「風格註記與載入」，以新專案身分詢問使用者，選項只有 `personal` 與 `standard`。依該節完成本機排除檢查後，寫入專案根目錄 `AGENTS.local.md` 的 `code-style.csharp`。收到答案並寫入成功前，不進入下一步。

### 3. 建立 slnx 方案

```powershell
dotnet new sln --name <solution 名稱> --format slnx --output <專案根目錄>
```

確認 `<專案根目錄>\<solution 名稱>.slnx` 存在，且根目錄沒有同名 `.sln`。命令失敗或產出不符時停止。

### 4. 建立實體資料夾與 Solution Folder

實體資料夾與 Solution Folder 各自建立，不假設建立其中一者會產生另一者。

1. 在專案根目錄建立 `src` 與 `tests` 兩個實體資料夾。
2. 重新讀取 `.slnx`，在 `<Solution>` 元素下加入下列兩個節點，保留檔案其餘內容：

   ```xml
   <Folder Name="/src/" />
   <Folder Name="/tests/" />
   ```

3. 寫入前比對讀取時的內容，檔案已變動時停止並重新讀取。
4. 寫入後重新讀取 `.slnx`，確認兩個 `Folder Name` 各出現一次。

### 5. 產生設定檔

依序執行下列 skill，每個 skill 保留其自身的預覽、確認、既有內容保護與下載授權流程。使用者未確認預覽或未授權下載時，停止該步驟並回報，不以其他產物替代。

| 順序 | Skill | 傳入的輸入 | 載入方式 |
| --- | --- | --- | --- |
| 1 | `generate-editorconfig-by-techstack` | 專案根目錄、目標框架、`code-style.csharp` 註記值 | Skill 工具 |
| 2 | `generate-gitignore-by-techstack` | 專案根目錄、.NET 技術棧 | 以 Read 讀取 `~/.ai-agents/skills/generate-gitignore-by-techstack/SKILL.md` 全文後依其步驟執行 |
| 3 | `generate-gitattributes` | 專案根目錄、範本 | 以 Read 讀取 `~/.ai-agents/skills/generate-gitattributes/SKILL.md` 全文後依其步驟執行 |
| 4 | `project-setup` | 專案根目錄、Git 狀態、`solo` 或 `team` 模式 | 以 Read 讀取 `~/.ai-agents/skills/project-setup/SKILL.md` 全文後依其步驟執行 |

後三個 skill 設有 `disable-model-invocation: true`，只供使用者單獨手動觸發；本 Skill 以讀取全文的方式明確載入，不改變其觸發設定。

### 6. 完成確認

輸出下列項目：

- SDK 版本與 `--format` 檢查結果。
- `.slnx` 路徑、兩個 Solution Folder 與兩個實體資料夾。
- `code-style.csharp` 註記值、`AGENTS.local.md` 路徑與本機排除狀態。
- 四個設定 skill 各自的執行結果，含略過或停止的步驟與原因。

## 失敗處置

| 情境 | 處置 |
| --- | --- |
| SDK 不支援 `--format` 或 `dotnet` 不可執行 | 停止，回報 SDK 版本；不下載、不改用 `.sln` |
| 根目錄已有方案或專案檔 | 停止，不覆寫；既有專案改走一般開發流程 |
| 風格註記無法寫入或本機排除無法確保 | 依 `csharp-style` skill 的錯誤處置停止，保留原檔 |
| `.slnx` 在讀取後被其他程序修改 | 停止並重新讀取，不覆寫其他工作 |
| 設定 skill 的預覽未確認或下載未授權 | 停止該步驟，回報已完成與未完成項目 |
