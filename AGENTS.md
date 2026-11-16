# .ai-agents Contributor Guide

本檔提供在 .ai-agents 專案工作時需注意的事實。完整目錄結構與各工具設定路徑請見 `README.md`。

## 1. 修改全域規則

- 全域規則的單一來源是 `instructions.md` 與 `rules/claude/`。`instructions.md` 收 Claude 與 Codex 兩端都需要的規則；`rules/claude/` 收只有 Claude 端需要的 Persona、協調、授權、派工與 Workflow 審查規則，Codex 端讀不到。
- 各家 AI 工具的全域指令檔（如 CLAUDE.md、AGENTS.md、GEMINI.md 等）均為 Windows Symbolic Link，最終都指向 `instructions.md`。`rules/claude/` 由 Setup 連結為 `~/.claude/rules`，不帶 `paths` frontmatter 的 `.md` 在 Claude Code 啟動時依檔名順序載入，檔名的數字前綴決定順序。具體對應關係見 `README.md` §3。
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
- 修改 `.githooks/`、`claude-plugins/`、`agents/`、`rules/`、`.editorconfig` 等基礎設定時，確認 `Setup-AIGlobalConfig.ps1` 與 `README.md` §3 是否需要對應更新。
- 新增或調整 plugin 內容時，同步確認 Setup 的 8b、8c 與 `README.md` §3。
- `docs/agents.md` 與 `docs/skills.md` 為 `.githooks/Update-Docs.ps1` 於 pre-commit 產生的生成檔，請勿手動編輯，手改會在下次 commit 被覆蓋。
- `Update-Docs.ps1` 在 pre-commit 階段只對 `docs/agents.md` 與 `docs/skills.md` 執行 `git add`，不再處理 `instructions.md`。這兩個生成檔不手動編輯，通常不會有未暫存的變更；拆成多筆 commit 時，仍依 `git-workflow` skill 先確認 hook 的暫存目標再安排分組。Agent 的 Persona／sub-agent 分類由該腳本的 `$personaAgents` 清單決定；新增 Persona 時需同步更新此清單。
- `.githooks/pre-commit` 在 `Update-Docs.ps1` 之後以 `pwsh` 執行 `.githooks/Test-StagedDocPath.ps1`。staged 的 `.md`、`.toml` 新增行含磁碟機絕對路徑（如使用者目錄）時阻擋 commit，`.local` 目錄與 `*.local.md` 不檢查。偵測規則在 `claude-plugins/ai-agents-hooks/hooks/lib/doc-path-check.ps1`。需要在進版控的文件寫路徑時，改用佔位符（如 `<sourceRoot>`）或相對路徑。

## 6. 設定位置權威對照

- `README.md` §3「各家 AI 工具全域設定位置」是各工具設定路徑的權威對照表。不確定某項設定該放哪裡時優先查它。
- `README.md` §4 是目錄結構總覽。

## 7. PowerShell 版本

- 派工腳本（`scripts\Invoke-CodexDispatch.ps1` 與 `scripts\dispatch\`、`scripts\Invoke-CodexRun.ps1` 與 `scripts\codex-run\`）、`scripts\` 下其他由 Claude 端呼叫的腳本、`claude-plugins\` 的 hook 與派工測試只支援 pwsh 7，檔首宣告 `#Requires -Version 7.0`。例外是 `scripts\Ensure-AiContextArtifacts.ps1`，檔首沒有版本宣告。
- `scripts\Setup-AIGlobalConfig.ps1` 同樣只支援 pwsh 7，但檔首維持 `#Requires -Version 5.1`，本體語法維持 5.1 可解析。它在 Windows PowerShell 5.1 啟動時印出 `winget install Microsoft.PowerShell` 安裝指引後以非零結束碼結束，判斷通過後才 dot-source 宣告 `#Requires -Version 7.0` 的模組。寫法見 `powershell` skill「編碼與版本目標」。
- `.githooks\Update-Docs.ps1` 由 pre-commit 以 `powershell.exe` 執行，檔首為 `#Requires -Version 5.1`，本體須維持 5.1 可解析。
