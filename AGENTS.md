# .ai-agents Contributor Guide

本檔提供在 .ai-agents 專案工作時需注意的事實。完整目錄結構與各工具設定路徑請見 `README.md`。

## 1. 修改全域規則

- 全域規則的單一來源是 `instructions.md` 與 `rules/claude/`。`instructions.md` 收 Claude 與 Codex 兩端都需要的規則；`rules/claude/` 收只有 Claude 端需要的 Persona、協調、授權、派工與 Workflow 審查規則，Codex 端讀不到。
- 各家 AI 工具的全域指令檔（如 CLAUDE.md、AGENTS.md、GEMINI.md 等）均為 Windows Symbolic Link，最終都指向 `instructions.md`。`rules/claude/` 由 Setup 連結為 `~/.claude/rules`，不帶 `paths` frontmatter 的 `.md` 在 Claude Code 啟動時依檔名順序載入，檔名的數字前綴決定順序。具體對應關係見 `README.md`「設定放在哪裡」。
- 修改全域規則一律改 `instructions.md` 或 `rules/claude/` 下的檔案，不要去改各工具目錄下的 symlink。新增規則時依 `instructions.md` §0 判定寫入哪一處。
- 修改 `instructions.md`、`rules/claude/` 與 `agents/` 下的規則檔或 SKILL.md 的機制條款前，先讀 `.claude/skills/repo-rule-change/SKILL.md`（同步位置與 Codex TOML 格式限制）。
- 上述全域指令檔位於各工具的使用者設定目錄。本檔是 repo 根目錄的專案層 `AGENTS.md`，只記錄維護本 repo 所需的事實，兩者同名但不是同一份檔案。

## 2. 新增 / 修改 Skill

- Skill 寫入 `skills/<name>/SKILL.md` 即可，各家工具會透過各自的 symlink 同時讀到，不需要為各工具各寫一份。
- 只在維護本 repo 時適用的 skill 放 `.claude/skills/`，不放 `skills/`。新增或搬移 skill 前，先讀 `.claude/skills/repo-skill-authoring/SKILL.md`（放置位置、frontmatter 檢查與生成檔）。

## 3. Persona 路由規則

- `rules/claude/10-persona-routing.md` 的 Persona 路由表**只列 Persona**（Analyst / Developer / Editor / Maintainer），不列 skill。`Support Engineer` 是 `Maintainer` 派生的執行層 sub-agent，不在 Persona 表。
- Skill 的觸發靠 SKILL.md 內 description 的 `Use when ...` 句子。新增 skill 時不需動 Persona 表。

## 4. Codex Agent 定義格式

- `agents/codex/*.toml` 的頂層 bare key 只允許 `name`、`description`、`developer_instructions` 三個。Codex 讀到其他頂層鍵時會丟棄整份 agent 定義，只在 stderr 印一行警告。修改 `agents/codex/*.toml` 前先讀 `.claude/skills/repo-rule-change/SKILL.md`（其餘格式限制與 pre-commit 檢查）。

## 5. 設定散佈與 Hook

- `scripts/Setup-AIGlobalConfig.ps1` 是建立所有 symlink 的入口。新增需要散佈的目錄或檔案時，需同步更新此腳本。
- 修改 `.githooks/`、`claude-plugins/`、`agents/`、`rules/`、`.editorconfig` 等基礎設定時，確認 `Setup-AIGlobalConfig.ps1` 與 `README.md`「設定放在哪裡」是否需要對應更新。
- 新增或調整 plugin 內容時，同步確認 Setup 的 8b、8c 與 `README.md`「設定放在哪裡」。
- `docs/agents.md` 與 `docs/skills.md` 為 `.githooks/Update-Docs.ps1` 於 pre-commit 產生的生成檔，請勿手動編輯，手改會在下次 commit 被覆蓋。
- `Update-Docs.ps1` 在 pre-commit 階段只對 `docs/agents.md` 與 `docs/skills.md` 執行 `git add`。這兩個生成檔不手動編輯，通常不會有未暫存的變更；拆成多筆 commit 時，仍依 `git-workflow` skill 先確認 hook 的暫存目標再安排分組。Agent 的 Persona／sub-agent 分類由該腳本的 `$personaAgents` 清單決定；新增 Persona 時需同步更新此清單。
- `scripts/codex-profiles/<檔位>.config.toml` 為 `.githooks/Update-CodexProfiles.ps1` 於 pre-commit 由 `scripts/dispatch/executor-registry.json` 的 `profileSettings` 產生並暫存的生成檔，請勿手動編輯；要改檔位的 model 或推理強度就改登錄表。該腳本以 pwsh 7 執行（`-Check` 只比對不寫檔，pre-commit 加 `-FromIndex` 以暫存區的登錄表產生），在 `Test-StagedDocPath.ps1` 之後由 `pre-commit` 呼叫。各派工帳號目錄的檔位設定檔由 `scripts\Setup-AIGlobalConfig.ps1` 與 `New-CodexDispatchAccount.ps1` 建成指向這些產生檔的連結。
- 執行者登錄表的讀取與結構驗證只在 `scripts/lib/executor-registry.ps1`。`scripts/Select-DispatchExecutor.ps1` 只 dot-source 這一個檔（以自身所在位置為基準），`scripts/codex-run/45-profile-sync.ps1` 也 dot-source 它，產生器、Setup、帳號建立與 `Invoke-CodexRun.ps1` 的派工前比對經由後者使用同一組函式。該檔只定義函式，與選派入口同樣不寫檔、不呼叫網路、不讀取環境變數，`scripts/tests/Test-SelectDispatchExecutor.ps1` 的 S03、S06 會檢查。
- `templates/claude-mcp-servers.json` 與 `templates/claude-settings.shared.json` 進版控，不得含機器專屬路徑、金鑰與任何權杖。`settings.json` 範本不含授權（`permissions`）與偏好類的鍵，Setup 不寫入這些項目；MCP 範本只含類型與位址，不含 `headers` 與 `env`。
- `~\.claude.json` 只讀，由 Claude Code 持續改寫且含僅大小寫不同的鍵，讀取一律用 `ConvertFrom-Json -AsHashTable`，寫入只經 `claude mcp add --scope user`。判定登記是否存在時不使用 `claude mcp list` 與 `claude mcp get`，兩者會連線並對 `infra-lab` 啟動 `wsl.exe`。Setup 的官方外掛與 `settings.json` 兩個步驟（8d、8e）的內容在 `scripts/lib/claude-user-config.ps1`，`-Check` 的比對在 `scripts/lib/setup-check.ps1`，後者不得呼叫寫入函式。
- MCP 伺服器（mcp-lab、infra-lab、FlaUI.Mcp、Playwright MCP）的登記由 `scripts/Register-McpServer.ps1` 處理，Setup 與 Setup 的 `-Check` 不登記也不檢查它們，也不檢查 WSL。該腳本只寫設定，不拉 repo、不下載、不安裝、不啟動服務；實際內容在 `scripts/lib/mcp-registration.ps1`，Claude 端登記共用 `claude-user-config.ps1`。Playwright MCP 與 `-FlaUI` 的 Claude 端登記（`flaui-mcp`）不進 `templates/claude-mcp-servers.json`，因為兩者帶機器專屬的路徑或環境變數；登記內容由 `Get-PlaywrightMcpDefinition` 與 `Get-FlaUIClaudeMcpDefinition` 提供。
- Codex 桌面版設定檔（`~\.codex\config.toml`）與 `.local\machine.json` 登記的各派工帳號的 `config.toml`，在 `Register-McpServer.ps1 -FlaUI` 內寫入，且只新增或更新 `[mcp_servers.flaui-mcp]` 的 `command`（派工帳號缺少該表時依 Setup 複製的形式追加整張表，組表內容共用 `45-profile-sync.ps1` 的 `Get-CodexMcpAccountBlock`）。每個檔案寫入前各備份一份，不建立設定檔，其餘位元組、編碼與換行不變，不刪除 `.codex` 目錄下的任何檔案。寫入一律經 `claude-user-config.ps1` 的受保護寫入（`Resolve-ConfigWriteTarget`、`Save-ConfigFileBackup`、`Write-ConfigFileGuarded`，`settings.json` 同用）。這套寫入把連結解析到實際目標，備份取自讀到的位元組，取代前確認原檔未被改動。Setup 本身只在派工帳號目錄缺少 `command` 時從桌面版設定檔複製，帳號目錄已有 `command` 時不更新；更新既有的 `command` 只由 `-FlaUI` 處理。測試與子行程呼叫該腳本時必須以 `-MachineConfigPath` 指向暫存的 `machine.json`，預設值是 repo 的 `.local\machine.json`（真實帳號）。
- `.githooks/pre-commit` 在 `Update-Docs.ps1` 之後以 `pwsh` 執行 `.githooks/Test-StagedDocPath.ps1`。staged 的 `.md`、`.toml` 新增行含磁碟機絕對路徑（如使用者目錄）時阻擋 commit，`.local` 目錄與 `*.local.md` 不檢查。偵測規則在 `claude-plugins/ai-agents-hooks/hooks/lib/doc-path-check.ps1`。需要在進版控的文件寫路徑時，改用佔位符（如 `<sourceRoot>`）或相對路徑。
- `ai-agents-hooks` 的 hook 是函式型外掛的 TypeScript 模組，`hooks/hooks.json` 只列 `modules`，不另以命令型 hook 註冊同一事件。事件註冊在 `hooks/register.ts`，判定邏輯在 `hooks/core/`，`tests/run-hook.ts` 讓 `scripts/tests/` 的 PowerShell 測試以命令型 hook 的 stdin 與 stdout 形式執行這些邏輯。`hooks/core/doc-path.ts` 與 `doc-path-check.ps1` 是同一套規則的兩份實作，改其中一份時同步改另一份，`scripts/tests/Test-DocLocalPathCheck.ps1` 會以同一組輸入比對兩者。`hooks/core/mcp-call-record.ts` 在 `playwright` 與 `flaui-mcp` 的每次 MCP 工具呼叫後，於 `%LOCALAPPDATA%\ai-agents\mcp-calls\<agent_id>\` 寫一個紀錄檔（主執行緒的呼叫沒有 `agent_id`，寫在 `_main` 目錄），只記歸屬與成敗，不記工具的輸入、輸出與錯誤原文（避免測試帳密進入紀錄）。`scripts/Write-ClaudeRunRecord.ps1` 的 End 只刪除本次採用的紀錄檔，時間窗外、其他 agent 與無法剖析的檔案保留，因此 End 之後目錄仍有檔案不代表清理失敗。測試在 `scripts/tests/Test-McpCallHook.ps1`。

## 6. README 的範圍

- `README.md` 的讀者是要安裝與使用這套設定的人。內容限於用途、安裝步驟、核心概念、本機檔案慣例、設定放在哪裡、目錄結構、腳本一覽、日常維護會遇到的事，以及 Skill 與 Agent 的索引。
- 內部機制依 `doc-placement` 不寫入 README。本 repo 的落點是腳本本身、對應的 skill 或本檔，plugin 的行為細節寫在該 plugin 目錄的 `README.md`。
- `README.md`「設定放在哪裡」是各工具設定路徑的權威對照表，「目錄結構」是目錄總覽。不確定某項設定該放哪裡時優先查它。
- 引用 README 時寫章節名稱，不寫章節編號。

## 7. PowerShell 版本

- 派工腳本（`scripts\Invoke-CodexRun.ps1` 與 `scripts\codex-run\`、`scripts\dispatch\`）、`scripts\Register-McpServer.ps1`、`scripts\lib\claude-user-config.ps1`、`scripts\lib\mcp-registration.ps1` 與 `scripts\lib\setup-check.ps1`、`scripts\` 下其他由 Claude 端呼叫的腳本、`claude-plugins\ai-agents-hooks\hooks\lib\` 的 PowerShell 函式庫與派工測試只支援 pwsh 7，檔首宣告 `#Requires -Version 7.0`。
- `scripts\Setup-AIGlobalConfig.ps1` 同樣只支援 pwsh 7，但檔首維持 `#Requires -Version 5.1`，本體語法維持 5.1 可解析。它在 Windows PowerShell 5.1 啟動時印出 `winget install Microsoft.PowerShell` 安裝指引後以非零結束碼結束，判斷通過後才 dot-source 宣告 `#Requires -Version 7.0` 的模組。寫法見 `powershell` skill「編碼與版本目標」。
- `.githooks\Update-Docs.ps1` 由 pre-commit 以 `powershell.exe` 執行，檔首為 `#Requires -Version 5.1`，本體須維持 5.1 可解析。

## 8. 主 checkout 即執行環境

- 本 repo 的主 checkout 是各工具全域設定 symlink 的目標，其他專案也直接執行這裡的派工腳本與 hook。改動落地到 `main` 即對所有專案與 Session 生效，不需等 push。
- 需要使用者重跑 `scripts/Setup-AIGlobalConfig.ps1`、改連結或實測後才能運作的改動不落地，留在線分支，並在回報列出落地前使用者須完成的操作。這是 `rules/claude/20-coordination.md`「授權分類」落地條件第 3 項（落地後整合分支的狀態不會壞掉）在本 repo 的判定方式。
- Setup 的 8d、8e 只補缺少的項目，在已設定好的電腦重跑不會變動。`-Check` 讀取的範本與模組落地後立即生效。這類改動落地前，建議在主 checkout 以系統管理員 pwsh 執行一次 `Setup-AIGlobalConfig.ps1 -WhatIf` 確認輸出；不要從線工作樹執行，否則 marketplace 會指向工作樹。
