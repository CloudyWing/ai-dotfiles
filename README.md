# AI 全域設定 (.ai-agents)

如有需要建立個人開發設定，建議參考 [awesome-copilot](https://github.com/github/awesome-copilot)。

本目錄為個人全域 AI 輔助開發設定，適用於 GitHub Copilot、Gemini CLI、Antigravity 等工具，內容充滿個人習慣與偏好，僅供參考。

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
- 僅保留 `rules/commit.instructions.md` 作為 Commit 專用補充規則（因 VS Code 讀取情境需求）。
- 暫不拆分更多獨立 rule 檔案，避免維護成本升高。

---

## 2. Windows 連結類型對照表

本專案使用 **Symbolic Link (符號連結)** 來實現跨工具共用設定檔。

| 特性 | Shortcut (捷徑) | Hard Link (實體連結) | Junction Point (連接點) | Symbolic Link (符號連結) |
| --- | --- | --- | --- | --- |
| 支援對象 | 檔案與資料夾 | **僅限檔案** | **僅限資料夾** | 檔案與資料夾 |
| 跨磁碟機 | 支援 | ❌ | 支援 | 支援 |
| 對程式透明 | ❌ 視為獨立檔案 | ✅ | ✅ | ✅ |
| 刪除本尊後 | 捷徑失效 | **內容還在** | 連結失效 | 連結失效 |

> **建需系統管理員權限建立 Symbolic Link。**

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

### GitHub Copilot — `<repo>/.github/` 或 `~/.copilot/`

| 檔案 / 資料夾 | 用途 |
| --- | --- |
| `copilot-instructions.md` | 主要全域規則，自動注入所有對話 |
| `rules/commit.instructions.md` | Commit 訊息生成時使用的補充規則 |
| `prompts/*.prompt.md` | 可重用提示範本 |
| `skills/<name>/SKILL.md` | 技能模組，AI 依上下文自動載入 |

> 本專案實際來源為 `~/.ai-agents/`，再由腳本建立至各工具入口的符號連結。

---

## 4. VS Code 引用方式

| 來源 | 載入方式 |
| --- | --- |
| 全域/工作區規則 | 建立符號連結至專案的 `.github/copilot-instructions.md` |
| Commit 補充規則 | 透過 VS Code 設定 `commitMessageGeneration.instructions` |
| 提示範本 | 使用者在 Chat 中手動匯入 |
| 技能模組 | AI 依上下文自動查閱 |

### `settings.json` 範例

為了避免路徑解析錯誤，請一律使用**絕對路徑**（`~` 不保證支援）：

```json
{
    "github.copilot.chat.commitMessageGeneration.instructions": [
        { "file": "C:/Users/<你的帳號>/.ai-agents/rules/commit.instructions.md" }
    ]
}
```

> **注意**：一般程式碼與測試規則，Copilot 建議放至專案的 `.github/copilot-instructions.md`，不再透過 `settings.json` 指定。

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
├── rules/
│   └── commit.instructions.md         # Git Commit 補充規範
├── prompts/                            # 提示範本（Prompt）
│   ├── code-review.prompt.md
│   ├── fact-check-note.prompt.md
│   ├── generate-api-doc.prompt.md
│   ├── generate-changelog-zh-tw.prompt.md
│   ├── generate-editorconfig-by-techstack.prompt.md
│   ├── generate-unit-test.prompt.md
│   ├── create-license-and-readme-link.prompt.md
│   ├── create-readme-zh-tw.prompt.md
│   ├── proofread-note.prompt.md
│   ├── setup-gitignore-by-techstack.prompt.md
│   └── translate-zh-en.prompt.md
├── skills/                             # 技能模組（Skill）
│   ├── check-markdown/                 # Markdown 格式檢查（平台感知）
│   ├── context-map/                    # 大型重構前建立變更影響範圍分析
│   ├── csharp-async/                   # C# 非同步設計最佳實踐
│   ├── csharp-docs/                    # C# XML 註解標準
│   ├── csharp-mcp-server-generator/    # C# MCP Server 建立指南
│   ├── csharp-nunit/                   # C# NUnit + NSubstitute 測試規範
│   ├── dotnet-best-practices/          # .NET 通用品質守門員
│   └── fix-file-encoding/              # 檔案編碼偵測與修正
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
| `fact-check-note` | 事實校閱：逐條檢查內容觀念與術語，標註明確無法確認的資訊。 |
| `generate-api-doc` | API 文件：為 ASP.NET Core Controller 或 Minimal API 補齊 OpenAPI 標註。 |
| `generate-changelog-zh-tw` | 產生 CHANGELOG：依提交紀錄產生並插入區段，支援 MinVer 版本推進規格。 |
| `generate-editorconfig-by-techstack` | `.editorconfig` 設定：自動偵測技術棧产生或補齊設定，保留既有偏好。 |
| `generate-unit-test` | 產生單元測試：針對指定類別自動產生 NUnit + NSubstitute 骨架。 |
| `create-license-and-readme-link` | 開源授權設定：推薦授權選項、建立 LICENSE 並連結至 README。 |
| `create-readme-zh-tw` | 產生 README：生成結構清晰、工程導向的繁中說明文件。 |
| `proofread-note` | 校稿筆記：改善文章可讀性，修正語句，保留原始內容與語氣。 |
| `setup-gitignore-by-techstack` | `.gitignore` 設定：自動偵測技術棧，從 github/gitignore 下載官方範本並客製化。 |
| `translate-zh-en` | 技術文件翻譯：繁中 ↔ 英文，保留程式碼區塊，維持術語一致性。 |

---

## 8. 內建 Skill 清單

| Skill | 用途 |
| --- | --- |
| `check-markdown` | 偵測文件平台（GitHub/VitePress 等），套用對應語法規則並修正格式。 |
| `context-map` | 大型重構前建立受影響類別清單，確認影響範圍後再動手修改。 |
| `csharp-async` | C# 非同步設計：Task/ValueTask 規範、禁止 `.Wait()` 與 `async void`。 |
| `csharp-docs` | C# XML 文件：統一 `<summary>`、`<param>`、`<returns>` 標準語法。 |
| `csharp-mcp-server-generator` | C# MCP Server：Console App 起手式、DI 設定、stdio Log 管控。 |
| `csharp-nunit` | C# 測試：NUnit + NSubstitute 的 AAA 模式與資料驅動測試規範。 |
| `dotnet-best-practices` | .NET 品質守門：資源管理、SOLID 違反、效能陷阱偵測。 |
| `fix-file-encoding` | 偵測編碼（Big5/ANSI/UTF-8）並依副檔名轉換，特別處理 `.ps1`、`.cs`。 |

---

## License

This project is licensed under the [MIT License](./LICENSE.md).
