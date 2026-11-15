---
name: repo-rule-change
description: 'Use when 在 .ai-agents repo 修改 instructions.md、agents/ 下的 Agent 規則檔（Claude .md 或 Codex .toml）或 SKILL.md 的機制條款，需要知道改完後要同步哪些位置與 pre-commit 會檢查什麼時。'
audience: agent
policy.allow_implicit_invocation: true
---

# 本 repo 的規則檔改寫

本 Skill 只收改寫規則檔後須同步的位置與格式限制。條文該寫在哪一層依 `instructions.md` §0，內容寫法依 `writing-for-agents`，資訊落點依 `doc-placement`，三者不在此重述。

## 改完後的同步位置

Agent 規則檔在 `agents/claude/*.md` 與 `agents/codex/*.toml`。改完逐項確認，不適用者略過。

1. 引用清查，被改的章節標題、條目名稱或檔名，可能被其他規則檔以「」或 `§` 引用。以 `rg -n "<被改的字串>" instructions.md agents skills README.md docs/adr` 搜尋，逐處確認引用仍成立。
2. Persona 增減、Agent 檔增減或改名、symlink、目錄、腳本清單或 plugin 的改動，依 `AGENTS.md` §5 同步 `$personaAgents`、`README.md` 與 `scripts/Setup-AIGlobalConfig.ps1`。
3. 機制條款改寫必須審查，審查者不得是改寫者。發動判準與派遣單前置見 `instructions.md`「Reviewer 派遣發動判準」與 `workflow-orchestration` skill `references/review-procedures.md`，不在此重述。

## Codex agent TOML 格式

- 頂層鍵只允許 `name`、`description`、`developer_instructions`。Codex 讀到其他頂層鍵時判定整份檔案 malformed 並丟棄該 agent，只在 stderr 印一行警告，執行不中斷，所以錯誤不易察覺。
- 基本字串內的反斜線一律是跳脫序列開頭，合法跳脫字元為 `b`、`t`、`e`、`f`、`n`、`r`、`\`、`"`、`x`、`u`、`U`（以 `Update-Docs.ps1` 的 `Assert-CodexTomlEscapeSequence` 為準），其他組合同樣使整份檔案 malformed。
- 供文件生成使用的中繼資料以單行註解承載，格式為 `# doc-meta: <key> = "<value>"`。慣例上置於 `description` 之後、`developer_instructions` 之前；硬性要求是不得寫入 `developer_instructions` 多行字串內，否則會變成 agent 指令的一部分。目前使用的是 `audience`，值為 `agent` 或 `human`，生成 `docs/agents.md` 的「讀者」欄時由 `Get-TomlMetaValue` 讀取。
- Claude agent `.md` 的 frontmatter 同樣必須有合法的 `audience`。
- 以上由 `.githooks/Update-Docs.ps1` 於 pre-commit 檢查（`Assert-CodexTomlTopLevelKey`、`Assert-CodexTomlEscapeSequence`、`Get-TomlMetaValue`），違規即中止 commit。

## 驗證

- 改完執行 `pwsh -NoProfile -File .githooks\Update-Docs.ps1`，確認正常結束，且 `docs/` 只出現預期的生成變動。
