# AI 全域設定 (.ai-agents)

如有需要建立個人開發設定，建議參考 [awesome-copilot](https://github.com/github/awesome-copilot)。

本目錄為個人全域 AI 輔助開發設定，適用於 GitHub Copilot、Gemini CLI、Claude Code、Codex、Antigravity 等工具，內容充滿個人習慣與偏好，僅供參考。

---

## 1. 核心概念對照

| 概念 | 定位 | 何時生效 | 用途 |
| --- | --- | --- | --- |
| **Rule** | 規範文件 | 始終生效（自動注入每次對話） | 強制編碼規範、風格約束，AI 無法繞過 |
| **Prompt** | 可重用提示範本 | 使用者手動以 `/` 呼叫 | 封裝常用指令，如 code review、commit 生成 |
| **Skill** | 專門能力模組 | AI 判斷與請求相關時自動載入 | 結合指令 + 腳本 + 資源的複合任務 |
| **Agent** | 獨立代理人設定 | 依設定檔觸發或手動指定 | 定義 AI 角色、行為框架與可用工具 |

### 本專案策略

- 以 `instructions.md` 作為唯一主規則檔（Single Rule）。
- Commit 訊息生成以 `skills/generate-commit/` Skill 形式獨立管理，不再列為頂層 Rule。
- 暫不拆分更多獨立 rule 檔案，避免維護成本升高。

### 本地檔案慣例（不 commit）

`.local.` 後綴表示「本機私有、不進版控」，對應兩種用途：

| 檔案 | 用途 | 說明 |
| --- | --- | --- |
| `AGENTS.local.md` | 個人私有 AI 規則 | 覆蓋 `instructions.md` 的個人偏好 |
| `CONTEXT.local.md` | Session 上下文交接 | 記錄當前任務進度、踩過的坑與環境狀態，跨 session 延續用（自行定義，非業界標準） |

兩個檔案均已列入 `.gitignore`，適用於本目錄及各專案根目錄。

---

## 2. Windows 連結類型對照表

本專案使用 **Symbolic Link (符號連結)** 來實現跨工具共用設定檔。

| 特性 | Shortcut (捷徑) | Hard Link (實體連結) | Junction Point (連接點) | Symbolic Link (符號連結) |
| --- | --- | --- | --- | --- |
| 支援對象 | 檔案與資料夾 | **僅限檔案** | **僅限資料夾** | 檔案與資料夾 |
| 跨磁碟機 | 支援 | ❌ | 支援 | 支援 |
| 對程式透明 | ❌ 視為獨立檔案 | ✅ | ✅ | ✅ |
| 刪除本尊後 | 捷徑失效 | **內容還在** | 連結失效 | 連結失效 |

> **建立時需要系統管理員權限建立 Symbolic Link。**

---

## 3. 各家 AI 工具全域設定位置

### Gemini CLI — `~/.gemini/`

| 檔案 | 用途 |
| --- | --- |
| `GEMINI.md` | 全域規則：注入每次對話的核心指令 |
| `settings.json` | CLI 偏好設定（模型、主題、語言等） |

### Antigravity — `~/.gemini/antigravity/`

| 資料夾 | 用途 |
| --- | --- |
| `global_workflows/` | 跨專案可用的 Workflow 定義 |

### Claude Code — `~/.claude/`

| 路徑 | 用途 |
| --- | --- |
| `CLAUDE.md` | 全域記憶與指令（Claude Code 會自動讀取） |
| `skills/<name>/SKILL.md` | Skills（可自動觸發與 `/skill-name` 指令） |
| `commands/*.md` | 舊版自訂指令位置，仍可用，與 skills 等效 |
| `agents/*.agent.md` | 全域自訂 Agent（可用 `@agent-name` 呼叫） |

### Codex — `~/.codex/`（或 `$CODEX_HOME`）

| 檔案 | 用途 |
| --- | --- |
| `AGENTS.md` | 全域指令檔（Codex 會載入） |
| `AGENTS.override.md` | 全域覆蓋檔（若存在且非空會優先套用） |

| 路徑 | 用途 |
| --- | --- |
| `~/.agents/skills/<name>/SKILL.md` | 使用者技能（Codex 會掃描） |

### GitHub Copilot CLI — `~/.copilot/`（全域）

| 路徑 | 用途 |
| --- | --- |
| `copilot-instructions.md` | 全域規則：注入每次對話的核心指令 |
| `skills/<name>/SKILL.md` | 全域技能模組，AI 依上下文自動載入 |

### GitHub Copilot — `<repo>/.github/`（專案）或 `%APPDATA%\Code\User\`（全域）

| 路徑 | 用途 |
| --- | --- |
| `instructions/*.instructions.md` | 全域指令規則（需 `applyTo: "**"` 以套用至所有檔案） |
| `prompts/*.prompt.md` | 全域提示範本，Chat 中以 `/` 呼叫 |

> 本專案實際來源為 `~/.ai-agents/`，再由腳本建立至各工具入口的符號連結。

---

## 4. VS Code 引用方式

| 來源 | 載入方式 |
| --- | --- |
| 全域指令規則 | 符號連結至 `%APPDATA%\Code\User\instructions\*.instructions.md` |
| 工作區規則 | 符號連結至各專案的 `.github/copilot-instructions.md` |
| Commit 補充規則 | 透過 VS Code 設定 `commitMessageGeneration.instructions` |
| 提示範本 | 符號連結至 `%APPDATA%\Code\User\prompts\*.prompt.md` |
| 技能模組 | 放置於 `~/.copilot/skills/`，AI 依上下文自動查閱 |

### `settings.json` 範例

為了避免路徑解析錯誤，請一律使用**絕對路徑**（`~` 不保證支援）：

```json
{
    "github.copilot.chat.commitMessageGeneration.instructions": [
        { "file": "C:/Users/<你的帳號>/.ai-agents/skills/generate-commit/SKILL.md" }
    ]
}
```

> ⚠️ **以下路徑以 Windows 原生 VS Code 為基準。**
> 若使用 Remote - WSL 開發，符號連結目標須改為 WSL 內的路徑（如 `~/.vscode-server/data/User/instructions/`），否則 VS Code Server 將無法讀取。
>
> **注意**：一般程式碼與測試規則，建議放至全域 `instructions/` 目錄或各專案的 `.github/copilot-instructions.md`，不透過 `settings.json` 逐一指定。
---

## 5. Visual Studio 限制

> ⚠️ **Visual Studio（非 VS Code）不支援使用者層級全域 AI 設定。**
>
> 僅支援方案層級的 `.github/copilot-instructions.md` 或 GitHub Organization 集中管理。
> 若需跨專案共用規則，須透過符號連結讓各方案指向同一來源。

---

## 6. 目錄結構總覽

```plaintext
~/.ai-agents/
├── .gitignore                          # 版控排除清單
├── .gitattributes                      # 行尾格式與二進位標記
├── README.md                           # 本文件
├── instructions.md                     # 核心開發規範（主 Rule）
├── agents/                             # 自訂 Agent 定義
│   ├── clarify.agent.md
│   ├── cleanup.agent.md
│   ├── debug.agent.md
│   ├── design.agent.md
│   ├── editor.agent.md
│   ├── implement.agent.md
│   ├── review.agent.md
│   └── survey.agent.md
├── prompts/                            # 提示範本（Prompt）
│   ├── code-review.prompt.md
│   ├── create-license-and-readme-link.prompt.md
│   ├── fact-check-note.prompt.md
│   ├── fix-file-encoding.prompt.md
│   ├── generate-api-doc.prompt.md
│   ├── generate-changelog-zh-tw.prompt.md
│   ├── generate-editorconfig-by-techstack.prompt.md
│   ├── generate-gitignore-by-techstack.prompt.md
│   ├── generate-readme-zh-tw.prompt.md
│   ├── generate-unit-test.prompt.md
│   ├── spec-doc.prompt.md
│   └── translate-zh-en.prompt.md
├── skills/                             # 技能模組（Skill）
│   ├── check-markdown/                 # Markdown 格式檢查（平台感知）
│   ├── context-map/                    # 大型重構前建立變更影響範圍分析
│   ├── csharp-aspnetcore/              # ASP.NET Core DI Lifetime、HttpClient、ProblemDetails
│   ├── csharp-async/                   # C# 非同步設計最佳實踐
│   ├── csharp-di/                      # .NET DI 進階：Generic Host、Keyed Services、Decorator
│   ├── csharp-docs/                    # C# XML 註解標準
│   ├── csharp-mcp-server/              # C# MCP Server 建立指南
│   ├── csharp-nunit/                   # C# NUnit + NSubstitute 測試規範
│   ├── docker/                         # Dockerfile 多階段建置、非 root、層快取
│   ├── ef-core/                        # EF Core DbContext、查詢效能、Migration
│   ├── generate-commit/                # Git Commit 訊息生成（Diff-based + 拆分建議）
│   └── sql-query/                      # T-SQL 查詢規範、索引友善、參數化
├── templates/                          # 新專案初始化範本
│   ├── .editorconfig                   # 全語言 EditorConfig 範本
│   └── LICENSE.md                      # MIT 授權範本（含佔位符）
└── scripts/
    └── Setup-AIGlobalConfig.ps1        # 全域設定連結自動化腳本
```

---

## 7. 內建 Prompt 清單

| Prompt | 用途 |
| --- | --- |
| `code-review` | 程式碼審查：從安全性、正確性、SOLID 設計到可讀性進行分層評估。 |
| `create-license-and-readme-link` | 開源授權設定：推薦授權選項、建立 LICENSE 並連結至 README。 |
| `fact-check-note` | 事實校閱：逐條檢查內容觀念與術語，標註明確無法確認的資訊。 |
| `fix-file-encoding` | 偵測檔案編碼（Big5/ANSI/UTF-8）並依副檔名轉換目標編碼，特別處理 `.ps1`、`.csv`、`.cs`。 |
| `generate-api-doc` | API 文件：為 ASP.NET Core Controller 或 Minimal API 補齊 OpenAPI 標註。 |
| `generate-changelog-zh-tw` | 產生 CHANGELOG：依提交紀錄產生並插入區段，支援 MinVer 版本推進規格。 |
| `generate-editorconfig-by-techstack` | `.editorconfig` 設定：自動偵測技術棧產生或補齊設定，保留既有偏好。 |
| `generate-gitignore-by-techstack` | `.gitignore` 設定：自動偵測技術棧，從 github/gitignore 下載官方範本並客製化。 |
| `generate-readme-zh-tw` | 產生 README：生成結構清晰、工程導向的繁中說明文件。 |
| `generate-unit-test` | 產生單元測試：針對指定類別自動產生 NUnit + NSubstitute 骨架。 |
| `spec-doc` | 需求規格文件：將 `clarify.md` 轉化為人類可讀的開發需求規格，供同事參考討論。 |
| `translate-zh-en` | 技術文件翻譯：繁中 ↔ 英文，保留程式碼區塊，維持術語一致性。 |

---

## 8. 內建 Skill 清單

| Skill | 用途 |
| --- | --- |
| `check-markdown` | 偵測文件平台（GitHub/VitePress 等），套用對應語法規則並修正格式。 |
| `context-map` | 大型重構前建立受影響類別清單，確認影響範圍後再動手修改。 |
| `csharp-aspnetcore` | ASP.NET Core 開發規範：DI Lifetime、HttpClient、ProblemDetails、API 版本控制。 |
| `csharp-async` | C# 非同步設計：Task/ValueTask 規範、禁止 `.Wait()` 與 `async void`。 |
| `csharp-di` | .NET DI 進階：Generic Host、Worker Service、Keyed Services、Decorator 模式。 |
| `csharp-docs` | C# XML 文件：統一 `<summary>`、`<param>`、`<returns>` 標準語法。 |
| `csharp-mcp-server` | C# MCP Server：Console App 起手式、DI 設定、stdio Log 管控。 |
| `csharp-nunit` | C# 測試：NUnit + NSubstitute 的 AAA 模式與資料驅動測試規範。 |
| `docker` | Dockerfile 與容器化：多階段建置、非 root 執行、層快取最佳化。 |
| `ef-core` | Entity Framework Core：DbContext Lifetime、N+1 防範、Migration 管理。 |
| `generate-commit` | Git Commit 訊息生成：強制 Diff-based 流程、過渡檔案過濾、拆分建議。 |
| `sql-query` | T-SQL 查詢撰寫：參數化查詢、索引友善寫法、效能陷阱迴避。 |

---

## 9. 內建 Agent 清單

Agent 存放於 `agents/` 目錄，同步至 Claude Code `~/.claude/agents/`。

> **關於 Agent 共用與放置策略：**
> - **VS Code** 會讀到 `%APPDATA%\Code\User\prompts\` 裡的 `.agent.md`、`~/.copilot/agents/` 以及 `~/.claude/agents/`。
> - **Copilot CLI** 會讀到 `~/.copilot/agents/` 以及 `~/.claude/agents/`。
> - 若重複放置清單會導致顯示多個相同名稱的 agent。
> - 故本專案統一集中在 `~/.claude/agents/` 建立連結管理，以避免重複顯示。

| Agent | 用途 |
| --- | --- |
| `Survey` | 掃描專案結構並產出完整技術文件索引，供團隊成員與 AI 快速理解專案全貌。 |
| `Clarify` | 需求解構與釐清，透過來回提問將模糊需求轉化為可驗證標準，產出結構化需求元素清單。 |
| `Design` | 以 SA/SD 視角將需求元素轉化為系統設計文件，含架構、技術選型與分階段實作計畫。 |
| `Editor` | 文件編輯：分析 Markdown 結構、內容與格式，產出建議清單，確認後直接執行修改。 |
| `Implement` | 依據設計文件或使用者指示實作功能，確保每個階段完成後通過驗證再繼續。 |
| `Review` | 實作驗收：比對設計文件與實際程式碼，盤點遺漏與品質問題，產出差異報告並銜接 Clarify。 |
| `Debug` | 系統化除錯：以 Phase-based 流程診斷並修復程式錯誤，強制假設先行，禁止盲目嘗試。 |
| `Cleanup` | 技術債清除：掃描 C#/.NET 專案，清除死程式碼、強制命名規範、現代化語法，每批修改後驗證測試。 |

---

## License

This project is licensed under the [MIT License](./LICENSE.md).
