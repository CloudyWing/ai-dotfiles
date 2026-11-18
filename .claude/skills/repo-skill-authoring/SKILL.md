---
name: repo-skill-authoring
description: 'Use when 在 .ai-agents repo 新增、搬移或修改 skills/ 下的 SKILL.md，或要判斷一個 skill 該放全域 skills/ 還是本 repo 專屬的 .claude/skills/ 時。'
audience: agent
policy.allow_implicit_invocation: true
---

# 本 repo 的 Skill 建立與修改

本 Skill 只收維護 .ai-agents 時才用得到的事實，包含 skill 放哪裡、pre-commit 擋什麼、哪些檔案是生成物。內容寫法依 `writing-for-agents`，資訊落點依 `doc-placement`，`.md` 排版依 `check-markdown`，三者不在此重述。

## 放置位置與散佈範圍

| 目的 | 寫入位置 | 散佈範圍 |
| --- | --- | --- |
| 所有專案都適用的 skill | `skills/<name>/SKILL.md` | `~/.claude/skills` 與 `~/.agents/skills` 都是指向 repo `skills/` 的 symlink（`README.md`「設定放在哪裡」），Claude 與 Codex 同時讀到，不需各寫一份 |
| 只在維護本 repo 時適用的 skill | `.claude/skills/<name>/SKILL.md` | 只有在本 repo 內啟動的 Claude Code 會載入。`.gitignore` 排除 `.claude/*`，只放行 `.claude/skills/` |

- 放進 `skills/` 的內容會散佈到使用者的所有專案，寫入前先確認它對其他專案成立。
- `README.md`「設定放在哪裡」記載 Codex 掃描 `~/.agents/skills`，`.claude/skills/` 不在其中。需要 Codex 也遵守的專屬步驟，在 `AGENTS.md` 留指向該檔的一句話。

## Frontmatter 與 pre-commit 檢查

`.githooks/Update-Docs.ps1` 在 pre-commit 逐一檢查 `skills/*/SKILL.md`，違反即中止 commit，錯誤訊息會列出檔案路徑。下表以 `Update-Docs.ps1` 的 `Get-SkillMetadata` 與 `Assert-SkillFrontMatterConsistency` 為準。

| 欄位 | 要求 |
| --- | --- |
| `name` | 必填。與目錄名相同（慣例，目前沒有機械檢查） |
| `description` | 必填。慣例以單引號包住（腳本不檢查引號），寫成 `Use when ...` 或情境句，skill 是否被載入取決於這句 |
| `audience` | 必填，值為 `agent` 或 `human` |
| `dispatch` | `audience: human` 時必填，值為 `delegate`、`inline`、`split` 或 `either`；`split` 另須有 `## 派遣分界` 章節 |
| `disable-model-invocation` 與 `policy.allow_implicit_invocation` | 兩者必須相反（預設分別為 `false` 與 `true`），不一致即失敗 |

`.claude/skills/` 不在掃描範圍，專屬 skill 不受上表檢查，也不出現在 `docs/skills.md`，寫完需自行對照。

## 載入觸發

- Skill 靠 `description` 的觸發句被載入。
- 需要依檔案類型強制載入時，在 `instructions.md` §1.5「Skill 載入紀律」的對照表新增一列。`rules/claude/10-persona-routing.md` 的 Persona 表只列 Persona，不列 skill。

## 生成檔

- 新增 skill 後執行一次 `pwsh -NoProfile -File .githooks\Update-Docs.ps1`，確認沒有違規，且 `docs/skills.md` 只多出新 skill 那一列。
