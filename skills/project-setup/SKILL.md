---
name: project-setup
description: '探索專案的 solo／team 模式與既有規範產物，建立 AGENTS.md、CLAUDE.md、GLOSSARY.md、docs/adr/ 與 AI 宣告區塊。'
audience: human
disable-model-invocation: true
policy.allow_implicit_invocation: false
---

# 專案層設定

本 Skill 建立專案層的 Agent 入口與宣告，不負責替專案決定業務術語，也不把未確認的內容寫入 `GLOSSARY.md`。

## 探索流程

1. 確認專案根目錄、Git 根目錄與目前工作樹狀態。讀取但不覆寫既有 `AGENTS.md`、`CLAUDE.md`、`AGENTS.local.md`、`GLOSSARY.md`、`docs/adr/` 與 `.local/ai-context/`。
2. 判定或詢問專案模式：
   - `solo`：專案層檔案依專案既有版控策略管理，保留在 `AGENTS.md`、`GLOSSARY.md` 與 `docs/adr/`。
   - `team`：專案層檔案只供本機 Agent 使用，固定寫入 `.git/info/exclude`，不修改專案 `.gitignore`。
3. 掃描既有 `AGENTS.md` 的 `AI-DECLARATIONS` 區塊，確認宣告的 `context-index-query`、`glossary`、`adr` 與 `context-index` 路徑。區塊外內容與使用者既有規則全部保留。
4. 掃描技術棧、測試命令、文件索引與 ADR 檔名。只有實際存在的檔案、目錄與命令才列為已確認事實。

## 產生與更新

- `AGENTS.md` 不存在時，以 `~/.ai-agents/templates/AGENTS.md.template` 建立；存在時只補上或更新 `AI-DECLARATIONS` 區塊。
- `CLAUDE.md` 不存在時，以 `~/.ai-agents/templates/CLAUDE.md.template` 建立，首行必須是 `@AGENTS.md`。存在時保留 Claude 專屬區塊，確保首行仍為 `@AGENTS.md`。
- 建立 `GLOSSARY.md` 時使用 `~/.ai-agents/templates/GLOSSARY.md.template`，詞彙內容交由 `glossary` skill 與使用者逐項確認。
- 建立 `docs/adr/` 與 `.local/ai-context/` 目錄。ADR 範本使用 `~/.ai-agents/templates/adr/0000-template.md`，索引產物由 `ai-context-index` skill 產生。
- 宣告格式只使用下列四個鍵。路徑與命令必須反映本次探索結果：

  ```markdown
  <!-- AI-DECLARATIONS:BEGIN -->
  - `context-index-query`：<工具或命令>
  - `glossary`：`GLOSSARY.md`
  - `adr`：`docs/adr/`
  - `context-index`：`.local/ai-context/`
  <!-- AI-DECLARATIONS:END -->
  ```

## team 模式排除護欄

切換至 `team` 模式前，對下列每一項分別執行 `git ls-files --error-unmatch`：

- `AGENTS.md`
- `GLOSSARY.md`
- `docs/adr/`

命令成功代表目標已被 Git 追蹤。先提示使用者執行對應的 `git rm --cached`，再重新檢查；未完成解除追蹤前不宣稱排除規則已生效。

確認目標未被追蹤後，逐項追加至 `.git/info/exclude`。只追加這三項固定清單，不修改 `.gitignore`，也不建立 `.out-of-scope/` 或其他未宣告目錄。

## 與其他 Skill 的分工

- 本 Skill 只建立或更新 `AGENTS.md` 的宣告區塊，不維護 `GLOSSARY.md` 本體。
- `glossary` skill 負責術語衝突、使用者確認與詞彙表即時寫入。
- `ai-context-index` skill 負責依宣告工具產生 `.local/ai-context/` 產物。
- `adr` skill 負責判斷決策門檻與新增 ADR。

## 驗證

- 確認 `AGENTS.md` 存在且有成對 `AI-DECLARATIONS` 標記。
- 確認宣告的 `GLOSSARY.md`、`docs/adr/` 與 `.local/ai-context/` 路徑可由 `Test-Path` 判定存在。
- 確認 `CLAUDE.md` 首行為 `@AGENTS.md`。
- `team` 模式確認 `.git/info/exclude` 含三項固定清單，且 `git status --porcelain` 不列出這三項。
- 確認未修改 `.gitignore`，且不存在 `.out-of-scope/`。
