---
name: generate-commit
description: '依據 Git Diff 產生符合規範的 Commit 訊息，含過渡檔案過濾與拆分建議。'
---

# 產生 Git Commit 訊息

當使用者要求產生、撰寫或協助撰寫 Git Commit 訊息時，請自動套用本技能。

## 執行步驟

### 1. 取得實際變更（強制）

在產生 commit 訊息前，**必須**先執行以下命令取得真實的變更內容：

1. 執行 `git diff --cached --stat` 查看已 staged 的檔案清單。
2. 若無 staged 內容，改執行 `git diff --stat` 查看 unstaged 變更。
3. 對關鍵檔案執行 `git diff --cached [file]`（或 `git diff [file]`）取得具體的程式碼差異。

🚨 **絕對禁止**僅根據對話上下文或記憶推斷變更內容。Commit 訊息必須 100% 反映 `git diff` 的實際輸出。

### 2. 過濾過渡檔案

檢查 diff 結果，將以下類型的檔案標記為「建議不 commit」：

- Agent 產生的臨時檔案（如 `*.bak`、`*.tmp`）
- 工作狀態檔案（如 `Agents.local.md`）
- 中間測試腳本或除錯用途的暫存檔

標記後**不自動排除**，僅提示使用者確認是否需要 unstage。

### 3. 評估是否拆分 Commit

分析 diff 中的檔案變更，依「語意關聯」判斷是否建議拆分為多個 commit：

**判斷規則：**

- 若所有變更圍繞同一個功能或修正，建議**單一 commit**。
- 若變更涵蓋兩個以上不相關的語意（例如：A 組是新增功能、B 組是修正錯字），建議**拆分為多個 commit**。

**拆分時的輸出格式：**

```text
建議拆分為 N 個 commit：

Commit 1：<commit message>
  - file_a.cs
  - file_b.cs

Commit 2：<commit message>
  - file_c.md
  - file_d.md
```

若使用者選擇不拆分，則產生一個涵蓋所有變更的合併 commit 訊息。

### 4. 產生 Commit 訊息

依據下方規範產生 commit 訊息。

---

## Commit 訊息規範

### Header Format

**Pattern**: `<type>([scope]): <subject>`

#### Type Whitelist

- `feat`: 新增功能實作
- `fix`: 修正錯誤
- `refactor`: 程式碼重構（非功能性異動）
- `style`: 格式調整（如括號位置、分號，不影響邏輯）
- `docs`: 僅文件異動
- `perf`: 效能改善（不含行銷詞彙）
- `ci`: CI 設定與腳本異動（如 GitHub Actions, GitLab CI, scripts）
- `test`: 新增或修正測試
- `chore`: 建置流程、相依性套件更新、雜項（如 .gitignore）

#### Scope Rules（建議省略）

- **預設省略**：Scope 為非必填項目，對於多數一般性修改，**強烈建議直接省略**。
- **白名單機制**：若確實需要說明影響範圍，僅允許填寫第一層目錄名稱（如 `prompts`, `rules`, `skills`, `scripts`, `templates`）。不在白名單內的異動一律不寫 Scope。
- **禁止隨意創造**：不接受 `all`, `update`, `config` 等無明確邊界的無效 Scope。

#### Subject Rules

- **Language**: **台灣用語正體中文 (Traditional Chinese, Taiwan)**。
- **Style**: **命令式動詞開頭**（例如：新增, 修正, 移除, 重構）。
- **Length**: 不限制長度，以完整表達變更重點為優先。
- **Forbidden**:
  - 結尾不加句號。
  - 避免使用模糊字眼（如「更新程式碼」、「修改檔案」、「調整邏輯」），必須具體說明變更內容。

### Body Rules

- **Trigger**: 僅在 **「變更邏輯複雜」** 或 **「包含 Breaking Change」** 時生成。若標題已能充分說明變更，即使涉及多個檔案亦無需 Body。
- **Format**:
  - Header 與 Body 之間空一行。
  - 使用連字號 `-` 加一個空格作為條列點。
  - 每一點條列**必須**以句號 `。` 結尾。
  - 描述應保持客觀簡潔，不解釋實作細節，僅說明「變更內容」與「必要原因」。

### Core Principles

- **Atomic Focus**: 標題應反映最核心的邏輯變更。
- **Objective Language**: 描述使用客觀、具體的詞語，不使用「大幅提升效能」、「改善使用者體驗」、「顯著最佳化」等主觀修飾語。
- **Precision**: 描述應中性且具體，避免過度描述瑣碎細節。

## 範例

**✅ 正確範例：**

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

**❌ 錯誤範例：**

```text
# 模糊動詞 + 不必要的自創 Scope
fix(all): 修改程式碼

# 行銷用語 + 主觀修飾
refactor(prompts): 大幅提升 Prompt 效能與使用者體驗

# 結尾加句號+大陸用語
feat: 添加新的配置項。
```
