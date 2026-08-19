# .ai-agents Contributor Guide

本檔提供在 .ai-agents 專案工作時需注意的事實。完整目錄結構與各工具設定路徑請見 `README.md`。

## 1. 修改全域規則

- 全域規則的單一來源是 `instructions.md`。
- 各家 AI 工具的全域指令檔（如 CLAUDE.md、AGENTS.md、GEMINI.md 等）均為 Windows Symbolic Link，最終都指向 `instructions.md`。具體對應關係見 `README.md` §3。
- 修改全域規則一律改 `instructions.md`，不要去改各工具目錄下的 symlink。

## 2. 新增 / 修改 Skill

- Skill 寫入 `skills/<name>/SKILL.md` 即可，各家工具會透過各自的 symlink 同時讀到。
- 不需要為各工具各寫一份。

## 3. Persona 路由規則

- `instructions.md` §1.5 的 Persona 路由表**只列 Persona**（Clarify / Implement / Editor / Engineer），不列 skill。
- Skill 的觸發靠 SKILL.md 內 description 的 `Use when ...` 句子。新增 skill 時不需動 §1.5 Persona 表。

## 4. Codex Agent 定義格式

- `agents/codex/*.toml` 的頂層 bare key 只允許 `name`、`description`、`developer_instructions` 三個。Codex 讀到其他頂層鍵時會判定整份檔案 malformed 並丟棄該 agent 定義，只在 stderr 印一行警告，不中斷執行。
- 其他供文件生成使用的中繼資料以單行註解承載，格式為 `# doc-meta: <key> = "<value>"`。慣例上將它置於 `description` 之後、`developer_instructions` 之前。硬性要求是不得寫入 `developer_instructions` 多行字串內，否則會成為 agent 指令內容的一部分，不再是中繼資料。目前使用的是 `audience`，值為 `agent` 或 `human`。
- `.githooks/Update-Docs.ps1` 以 `Get-TomlMetaValue` 讀取該註解產生 `docs/agents.md` 的「讀者」欄，並以 `Assert-CodexTomlTopLevelKey` 檢查頂層鍵白名單。違反白名單時 pre-commit 直接失敗，避免 Codex 端的靜默丟棄。

## 5. 設定散佈與 Hook

- `scripts/Setup-AIGlobalConfig.ps1` 是建立所有 symlink 的入口。新增需要散佈的目錄或檔案時，需同步更新此腳本。
- 修改 `.githooks/`、`scripts/hooks/`、`agents/`、`.editorconfig` 等基礎設定時，確認 `Setup-AIGlobalConfig.ps1` 與 `README.md` §3 是否需要對應更新。
- `docs/agents.md` 與 `docs/skills.md` 為 `.githooks/Update-Docs.ps1` 於 pre-commit 產生的生成檔，請勿手動編輯，手改會在下次 commit 被覆蓋。Agent 的 Persona／sub-agent 分類由該腳本的 `$personaAgents` 清單決定；新增 Persona 時需同步更新此清單。

## 6. 設定位置權威對照

- `README.md` §3「各家 AI 工具全域設定位置」是各工具設定路徑的權威對照表。不確定某項設定該放哪裡時優先查它。
- `README.md` §4 是目錄結構總覽。
