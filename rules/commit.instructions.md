---
name: Git Commit Message Rules
description: Git Commit 撰寫規範 (Senior Level)
applyTo: "**/*"
---

# Git Commit Message Rules (Senior Level)

## 1. Core Principles

- **Atomic Focus**: 標題 (Header) 應反映最核心的邏輯變更。
- **Objective Language**: 描述使用客觀、具體的詞語，不使用「大幅提升效能」、「改善使用者體驗」、「顯著最佳化」等主觀修飾語。
- **Precision**: 描述應中性且具體，避免過度描述瑣碎細節。

## 2. Header Format

**Pattern**: `<type>([scope]): <subject>`

### 2.1 Type Whitelist (Ref: Angular & Modern Standards)

- `feat`: 新增功能實作。
- `fix`: 修正錯誤。
- `refactor`: 程式碼重構（非功能性異動）。
- `style`: 格式調整（如括號位置、分號，不影響邏輯）。
- `docs`: 僅文件異動。
- `perf`: 效能改善（不含行銷詞彙）。
- `ci`: CI 設定與腳本異動 (如 GitHub Actions, GitLab CI, scripts)。
- `test`: 新增或修正測試。
- `chore`: 建置流程、相依性套件 (Dependencies) 更新、雜項 (如 .gitignore)。

### 2.2 Scope Rules (建議省略)

- **預設省略**：Scope 為非必填項目，對於多數一般性修改，**強烈建議直接省略**。
- **白名單機制**：若確實需要說明影響範圍，僅允許填寫第一層目錄名稱（如 `prompts`, `rules`, `skills`, `scripts`, `templates`）。不在白名單內的異動一律不寫 Scope。
- **禁止隨意創造**：不接受 `all`, `update`, `config` 等無明確邊界的無效 Scope。

### 2.3 Subject Rules

- **Language**: **台灣用語正體中文 (Traditional Chinese, Taiwan)**。
- **Style**: **命令式動詞開頭**（例如：新增, 修正, 移除, 重構）。
- **Length**: 不限制長度，以完整表達變更重點為優先。
- **Forbidden**:
  - 結尾不加句號。
  - 避免使用模糊字眼（如「更新程式碼」、「修改檔案」、「調整邏輯」），必須具體說明變更內容。

## 3. Body Rules

- **Trigger**: 僅在 **「變更邏輯複雜」** 或 **「包含 Breaking Change (破壞性變更)」** 時生成。若標題已能充分說明變更，即使涉及多個檔案亦無需 Body。
- **Format**:
  - Header 與 Body 之間空一行。
  - 使用連字號 `- ` 作為條列點。
  - 每一點條列**必須**以句號 `。` 結尾。
  - 描述應保持客觀簡潔，不解釋實作細節，僅說明「變更內容」與「必要原因」。

## 4. Examples

**✅ 正確範例 (Specific & Objective):**

```text
feat(skills): 新增 check-markdown 技能

- 實作段落空白與全半形符號的自動校對規則。
- 新增技能說明與測試範例。
```

```text
fix: 修正 commit 規範格式錯誤

- 補齊遺漏的 Body 標題。
- 修正列表縮排層級。
```

**❌ 錯誤範例 (常見問題):**

```text
# 模糊動詞 + 不必要的自創 Scope
fix(all): 修改程式碼

# 行銷用語 + 主觀修飾
refactor(prompts): 大幅提升 Prompt 效能與使用者體驗

# 結尾加句號 + 大陸用語
feat: 添加新的配置項。
```
