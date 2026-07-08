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

- `instructions.md` §1.5 的 Persona 路由表**只列 Persona**（Clarify / Implement / Editor），不列 skill。
- Skill 的觸發靠 SKILL.md 內 description 的 `Use when ...` 句子。新增 skill 時不需動 §1.5 Persona 表。

## 4. 設定散佈與 Hook

- `scripts/Setup-AIGlobalConfig.ps1` 是建立所有 symlink 的入口。新增需要散佈的目錄或檔案時，需同步更新此腳本。
- 修改 `.githooks/`、`scripts/hooks/`、`agents/`、`.editorconfig` 等基礎設定時，確認 `Setup-AIGlobalConfig.ps1` 與 `README.md` §3 是否需要對應更新。

## 5. 設定位置權威對照

- `README.md` §3「各家 AI 工具全域設定位置」是各工具設定路徑的權威對照表。不確定某項設定該放哪裡時優先查它。
- `README.md` §4 是目錄結構總覽。
