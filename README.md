# AI 全域設定 (.ai-agents)

本目錄為個人全域 AI 輔助開發設定，適用於 Claude Code、Codex 等工具，內容充滿個人習慣與偏好，僅供參考。

**本專案必須 clone 至 `~/.ai-agents/`，setup script 與各工具連結皆依賴此路徑：**

```bash
git clone https://github.com/CloudyWing/ai-dotfiles.git ~/.ai-agents
```

## 安裝

在新的 Windows 電腦依下表由上而下進行。「系統管理員」欄標示該步驟要在以系統管理員身分開啟的 pwsh 執行，「手動」欄標示需要自行登入或操作、無法由腳本代勞的部分。MCP 伺服器（mcp-lab、infra-lab、FlaUI.Mcp）是選用項目，由另一支腳本登記，與 Setup 分離，見步驟 7。

| 步驟 | 內容 | 系統管理員 | 手動 |
| --- | --- | --- | --- |
| 1 | 安裝 git：`winget install Git.Git` | 否 | 否 |
| 2 | 安裝 PowerShell 7：`winget install Microsoft.PowerShell`。之後的命令都在 pwsh 執行 | 否 | 否 |
| 3 | 把本 repo clone 到 `~/.ai-agents`，命令見本文開頭 | 否 | 否 |
| 4 | 安裝 Claude Code CLI：`winget install Anthropic.ClaudeCode`。安裝後執行 `claude`，依畫面指示登入 | 否 | 登入帳號 |
| 5 | 執行 Setup，見下方「步驟 5」 | 是 | 否 |
| 6 | 以 `-Check` 確認結果，見下方「步驟 6」 | 否 | 否 |
| 7 | 選用：安裝 mcp-lab、infra-lab 與 FlaUI.Mcp，再以 `Register-McpServer.ps1` 登記，見下方「MCP 伺服器的安裝與登記」 | 啟用 WSL 時需要 | 依各項目的說明手動安裝 |
| 8 | 選用：Codex 派工環境，見下方「步驟 8」 | 視步驟而定 | 登入帳號 |

**步驟 5。** 以系統管理員身分開啟 pwsh 執行 Setup。加上 `-WhatIf` 可預覽，不寫入任何東西。

```powershell
~\.ai-agents\scripts\Setup-AIGlobalConfig.ps1
```

Setup 依序完成下列項目，重跑只補缺少的部分。

- 建立各工具指向本 repo 的 Symbolic Link，對應位置見 §3。
- 註冊本機 marketplace `ai-agents-local`，安裝並啟用其中的 plugin（hook 與狀態看板）。
- 安裝並啟用必裝的官方外掛 `microsoft-docs`。選裝的 `github` 與 `context7` 見 §3「Claude 使用者設定」。
- 把 `templates/claude-settings.shared.json` 套用到 `~/.claude/settings.json`，只新增缺少的項目，不覆寫既有值；寫入前先備份原檔。授權（`permissions`）與偏好設定不在範本內，由你自行設定。
- 設定本 repo 的 `core.hooksPath` 與機器層 Git 排除清單。
- 檢查 Windows 長路徑與 Codex CLI；把各派工帳號目錄的檔位設定檔建成指向 repo 產生檔的 Symbolic Link，已有一般檔案或指向別處的連結時不覆蓋，改列出要執行的命令；其餘缺件印出修復指引。

Setup 不登記任何 MCP 伺服器，也不檢查 WSL。

在 Windows PowerShell 5.1 啟動時，Setup 會印出 `winget install Microsoft.PowerShell` 安裝指引並以非零結束碼結束；不是以系統管理員身分執行時同樣直接結束。使用者目錄路徑較長時，安裝官方外掛會因 `Filename too long` 失敗，原因是 git 預設不支援過長的路徑。Setup 原樣印出 Claude Code 的輸出，執行 `git config --global core.longpaths true` 後重跑 Setup 即可。

選裝的外掛 `github` 與 `context7` 不由 Setup 安裝，安裝命令見 §3「Claude 使用者設定」。`github` 需要在啟動 Claude Code 前設定環境變數 `GITHUB_PERSONAL_ACCESS_TOKEN`，`context7` 的選用金鑰使用環境變數 `CONTEXT7_API_KEY`，兩者都只寫變數名稱，值由你自行保管。

**步驟 6。** 要確認這台電腦的設定是否齊全，而不做任何改動時，加上 `-Check`（不需系統管理員身分，只讀取現況）。輸出逐項的符合、缺少、指向錯誤位置、內容不符與無法判定，最後附統計；全部符合時結束碼為 0，否則為 1。加上 `-AsJson` 改輸出機器可讀的 JSON。`-Check` 不能與 `-Force` 或 `-EnableLongPaths` 併用。

```powershell
~\.ai-agents\scripts\Setup-AIGlobalConfig.ps1 -Check
```

檢查項目涵蓋下列範圍，Codex CLI 與版本不在檢查範圍。

- 前置軟體：pwsh 7、git 與 Claude Code CLI，缺少時輸出補救方式。
- 現役連結、工具目錄與斷鍊孤兒。
- Claude plugin 與 marketplace，含必裝的官方外掛 `microsoft-docs`，以及舊 hook 註冊。
- `settings.json` 的共用部分。
- `core.hooksPath`、`core.excludesFile` 與 Codex 檔位設定檔連結。

MCP 登記與 WSL 不在 Setup 檢查範圍，缺少時不影響結束碼；這兩項由 `Register-McpServer.ps1 -Check` 檢查。Claude Code 的登入狀態沒有唯讀的判定方式，不在檢查範圍。

**步驟 8。** 需要跨平台派工時，依 §3「Codex CLI 前置需求」安裝 Codex CLI，並依「Codex profile 檔位設定」確認檔位設定檔。派工帳號為選用，見「獨立 Codex 帳號目錄」。

### MCP 伺服器的安裝與登記

mcp-lab、infra-lab 與 FlaUI.Mcp 各自依下列說明手動安裝，安裝完成後執行 `scripts/Register-McpServer.ps1` 登記。腳本只寫設定，不拉 repo、不下載、不安裝、不啟動服務，不需要系統管理員身分。三項都是選用，只處理你指定的項目。

```powershell
~\.ai-agents\scripts\Register-McpServer.ps1 -McpLab
~\.ai-agents\scripts\Register-McpServer.ps1 -InfraLab -InfraLabDistro <發行版名稱> -InfraLabWslRepo <WSL 內 infra-lab 的路徑>
~\.ai-agents\scripts\Register-McpServer.ps1 -FlaUI
```

- 沒有指定任何項目時不做任何寫入，只印出用法。可以在同一個命令指定多項。
- `-McpLab` 與 `-InfraLab` 把範本 `templates/claude-mcp-servers.json` 的伺服器登記到 Claude Code 使用者層，名稱與範本相同。已存在的登記不會被覆寫，內容與範本不同時只回報；你另外加入的登記不受影響。新登記的 MCP 需要重新啟動 Claude Code 的 Session 才會載入。
- `-InfraLabDistro` 與 `-InfraLabWslRepo` 只在首次登記 infra-lab 時需要，登記後存於 `~/.claude.json`，重跑不必再提供。
- `-FlaUI` 把執行檔路徑寫入 Codex 桌面版設定檔 `~/.codex/config.toml` 的 `[mcp_servers.flaui-mcp]` 的 `command`，並同步更新 `.local/machine.json` 的 `codex_accounts` 登記的每個派工帳號的 `config.toml`，讓兩邊指向同一個執行檔。預設路徑為 `%LOCALAPPDATA%\Programs\FlaUI-MCP\FlaUI.Mcp.exe`，用 `-FlaUIPath` 指定其他路徑；相對路徑會先依目前的工作目錄轉成絕對路徑，設定檔裡寫的一律是完整路徑。執行檔不存在或桌面版設定檔不存在時不寫入並回報，腳本不會建立設定檔。
- 桌面版與派工帳號的處理規則相同。`[mcp_servers.flaui-mcp]` 已存在時只更新 `command` 那一行，其餘內容、編碼與換行不變，帳號端原有的 `enabled = false` 與 `startup_timeout_sec` 照舊。桌面版沒有該表時新增（含 `startup_timeout_sec = 60.0`）；派工帳號沒有該表時依 Setup 複製的形式追加整張表，`command` 與 `startup_timeout_sec` 取自桌面版設定，並加上 `enabled = false`。
- 桌面版沒有完成（設定檔不存在、寫法無法確定等）時不處理派工帳號。單一帳號的 `config.toml` 不存在、讀不到或寫法無法確定時，略過該帳號並指出帳號名稱，其餘帳號照常處理，最後結束碼為 1。沒有登記派工帳號或沒有 `machine.json` 時只處理桌面版，不影響結束碼。`-MachineConfigPath` 可指定其他的帳號登記檔。
- 每個檔案寫入前各備份一份，同一次執行放在同一個目錄 `.local/ai-sessions/backups/<時間戳>/`，桌面版為 `desktop/config.toml`，帳號為 `accounts/<帳號名稱>/config.toml`，同目錄的 `manifest.txt` 每個檔案記錄一行。取代檔案前會再確認原檔自讀取後沒有被改動（例如 Codex 剛好寫入），改動過就不寫入，回報原因並以結束碼 1 結束，確認沒有程式正在寫入後重新執行即可。設定檔是符號連結時寫入連結指向的實際檔案，連結本身保留；連結指向不存在的位置時不寫入並回報。
- 加上 `-WhatIf` 預覽，不寫入任何東西，桌面版與帳號的設定檔都不動。
- 加上 `-Check` 唯讀檢查所選項目是否已登記，沒有指定項目時檢查三項全部。infra-lab 另檢查 WSL 是否存在。FlaUI 另檢查每個派工帳號的 `command` 是否與桌面版相同，不同時指出帳號名稱。缺少任一項或不一致時結束碼為 1，全部符合為 0。mcp-lab 的服務未啟動、FlaUI.Mcp 執行檔不存在只在備註提示，不影響結束碼。檢查不寫入任何檔案。

**mcp-lab。** 來源為 [mcp-lab](https://github.com/CloudyWing/mcp-lab)，以 Docker Compose 執行 11 個 MCP 服務，位址為 `http://127.0.0.1:<固定埠號>/mcp`，安裝在 WSL。前置需求是 WSL 與 Docker。WSL 在系統管理員 pwsh 執行 `wsl --install` 啟用，重新開機後建立 Linux 使用者，詳見 [Microsoft 的 WSL 安裝說明](https://learn.microsoft.com/windows/wsl/install)。Docker 與 mcp-lab 本身的安裝與啟動，依該 repo 的 README 操作。完成後執行 `Register-McpServer.ps1 -McpLab`。登記不需要服務已在執行，服務可以之後才啟動。

**infra-lab。** 來源為 [infra-lab](https://github.com/CloudyWing/infra-lab)，以 Taskfile 驅動本機 Docker 服務，安裝在 WSL，新電腦以 `task bootstrap` 初始化。前置需求同 mcp-lab，安裝與啟動依該 repo 的 README 操作。`-InfraLabDistro` 與 `-InfraLabWslRepo` 的值，可取自在 WSL 內執行 `task mcp:config` 印出的命令，形如 `claude mcp add infra-lab --scope user -- wsl.exe -d <發行版名稱> -e bash <WSL 內 repo 路徑>/scripts/mcp.sh`，其中 `bash` 之後去掉 `/scripts/mcp.sh` 的部分就是 WSL 內 repo 路徑。完成後執行 `Register-McpServer.ps1 -InfraLab`，並帶入這兩個值。

**FlaUI.Mcp。** 來源為 [FlaUI-MCP](https://github.com/starpia-forge/FlaUI-MCP) 的 Releases，每一版有四個壓縮檔。

| 檔案 | 平台 | .NET 需求 |
| --- | --- | --- |
| `FlaUI-MCP-win-x64-<版本>-self-contained.zip` | x64 | 不需要 |
| `FlaUI-MCP-win-x64-<版本>-framework-dependent.zip` | x64 | .NET 8 Runtime |
| `FlaUI-MCP-win-arm64-<版本>-self-contained.zip` | arm64 | 不需要 |
| `FlaUI-MCP-win-arm64-<版本>-framework-dependent.zip` | arm64 | .NET 8 Runtime |

下載符合平台的壓縮檔並解壓到任意資料夾，執行檔為 `FlaUI.Mcp.exe`。本 repo 建議解壓到 `%LOCALAPPDATA%\Programs\FlaUI-MCP`，路徑不帶版號，升級時設定不必改。目前使用的版本是 v1.5.0 的 x64 framework-dependent。解壓後的步驟如下。

1. 執行 `Register-McpServer.ps1 -FlaUI`，把執行檔路徑寫入 Codex 桌面版與各派工帳號的設定。
2. 之後新登記的派工帳號，由 Setup（步驟 5）從桌面版設定複製 FlaUI 的指令。

Setup 只在派工帳號目錄的 `config.toml` 缺少 `[mcp_servers.flaui-mcp]` 的 `command` 時，才從桌面版設定複製；帳號目錄已有 `command` 時不會更新。FlaUI.Mcp 換了位置之後，重新執行 `Register-McpServer.ps1 -FlaUI`（以 `-FlaUIPath` 指定新路徑），桌面版與各派工帳號會一併更新。

---

## 1. 核心概念對照

| 概念 | 定位 | 何時生效 | 用途 |
| --- | --- | --- | --- |
| **Rule** | 規範文件 | 始終生效（自動注入每次對話） | 強制編碼規範、風格約束，AI 無法繞過 |
| **Skill** | 專門能力模組 | 知識型：AI 自動載入；指令型：使用者以 `/` 呼叫 | 封裝知識規範、可執行任務，支援腳本與資源 |
| **Agent** | 獨立代理人設定 | 依設定檔觸發或手動指定 | 定義 AI 角色、行為框架與可用工具 |

### 本專案策略

- 以 `instructions.md` 作為 Claude 與 Codex 共用的主規則檔（Single Rule）；只有 Claude 端需要的 Persona、協調、授權、派工與 Workflow 審查規則放在 `rules/claude/`，每條規則只存在一處。
- Commit 訊息生成以 `skills/generate-commit/` Skill 形式獨立管理。

### 平台分工

| 角色 | 執行端 | 觸發方式 |
| --- | --- | --- |
| Analyst、Editor | 依所在平台 | Persona，以語意切換 |
| Developer、Maintainer | Claude | Persona，以語意切換；Developer 在 Workflow 中由主 Agent 派生 |
| Architect、Prototyper | Claude | 由主 Agent 派生 |
| Developer、Refactorer、Support Engineer | Claude subagent（Haiku 或 Sonnet，依執行者登錄表） | 由主 Agent 以 Agent 工具派生，或 Maintainer 派生 Support Engineer |
| Reviewer、Frontend Reviewer、Contract Auditor | Codex（Codex 不可用時由執行者登錄表選出的 Claude Sonnet subagent 承接） | 由主 Agent 依派遣判準以資源派遣發動 |
| 測試（煙霧驗證取證）、事實校閱、顧問、影像產生 | Codex（顧問只有 Codex 受理） | 由主 Agent 依執行者登錄表以資源派遣發動 |

實作類角色（Developer、Maintainer、Support Engineer、Refactorer）只在 Claude 端執行，Codex 端只承接審查、測試取證、事實校閱、顧問與影像產生。

功能線建議在 Claude Code 處理 Analyst 與 Architect，之後的 Developer 與 Reviewer 鏈由主 Agent 在背景發動，不需手動切換平台。bug 由 Maintainer 診斷，實作交由 Support Engineer 完成。

涉及畫面的需求由 Analyst 判定 UI 線別，版面複雜或需對外溝通時派生 Prototyper 產出 Demo 畫面。畫面與使用者可見文字（UI 文字、錯誤訊息）相關工作另受 `uiux` skill 約束，該 skill 平常依觸發語自動載入；判斷本輪工作涉及畫面或使用者可見文字而它未被載入時，可直接以 `/uiux` 手動強制載入。資訊該寫在哪份文件，由 `doc-placement` skill 依讀者判定。

### 本地檔案慣例（不 commit）

`.local/` 與 `.local.` 後綴表示「本機私有、不進版控」，前者收納 AI 工作產物，後者保存本機覆寫設定：

| 檔案 | 用途 | 說明 |
| --- | --- | --- |
| `AGENTS.md` | 專案共享規範 | 專案層規則與 `AI-DECLARATIONS` 宣告，依專案版控策略管理 |
| `AGENTS.local.md` | 個人對此專案的偏好覆寫 | 僅影響目前專案，不取代專案共享規範 |
| `CONTEXT.local.md` | Session 上下文交接 | 可選的本機交接檔；僅記錄跨 session 仍有效的環境前置作業、本機限制與已知陷阱 |
| `GLOSSARY.md` | 專案專屬業務術語 | 由 `glossary` skill 依使用者確認維護 |
| `docs/adr/` | Architecture Decision Record | 依 `adr` skill 的決策門檻，經使用者同意後追加 |

`.local/` 與 `*.local.md` 由 Setup 設定的機器層 Git 排除清單排除，不需寫進專案的 `.gitignore`。

`.local/` 目錄結構如下：

```text
.local/
├── ai-context/                         # AI 脈絡索引產物
└── ai-sessions/
    ├── handoff/
    ├── report/
    ├── history/
    ├── scratch/
    ├── backups/
    ├── inputs/
    ├── screenshots/
    ├── style-baselines/
    ├── test-context/                   # 測試環境資料檔 test-context.md（保留，不進版控）
    └── ui-demo/
```

交接檔與報告綁定在本輪任務的 `work-root`，判定方式見 `instructions.md` §1.5「work-root 判定」。

#### 本機設定 machine.json

`~/.ai-agents/.local/machine.json` 是本機設定，不進版控，記錄值班 Session、派工帳號清單等只屬於這台電腦的資訊。

協調 Session 不需要登記。Agent 把啟動它的那個 Session，以及該 Session 指定的接手 Session，當作協調 Session，接受它轉述的使用者決定；你手動開的 Session 則要你直接在該 Session 回覆。轉述的判定規則見 `rules/claude/20-coordination.md`「授權期限」。

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

### Claude Code — `~/.claude/`

| 路徑 | 用途 |
| --- | --- |
| `CLAUDE.md` | 全域記憶與指令（Claude Code 會自動讀取），連結到 `instructions.md` |
| `rules/*.md` | 只在 Claude 端載入的常駐規則，啟動時與 `CLAUDE.md` 一同載入，子代理同樣載入。`rules` 是連結到 `rules/claude/` 的目錄連結；連結缺失或中斷時 Claude Code 不會提示，Persona、授權與派工規則會整組失效，連結缺失時重跑 Setup 即可恢復；連結仍存在但指向其他位置（例如 repo 搬移後）時，Setup 會印出警告並略過，確認後加 `-Force` 重跑才會重建 |
| `skills/<name>/SKILL.md` | Skills（知識型自動載入；指令型以 `/skill-name` 呼叫） |
| `agents/*.md` | 全域自訂 Persona 與 Claude 端 sub-agent |
| `settings.json` | 使用者設定。Setup 依 `templates/claude-settings.shared.json` 只新增缺少的共用項目，不覆寫既有值，授權與偏好由使用者自行設定，說明見下方「Claude 使用者設定」 |

#### Claude 使用者設定

Setup 的官方外掛與 `settings.json` 兩個步驟處理 Claude Code 使用者層的設定。範本位於 `templates/`，進版控，只含共用項目，不含授權、偏好、金鑰、權杖與機器專屬路徑。MCP 伺服器的登記由 `scripts/Register-McpServer.ps1` 處理，見「安裝」的「MCP 伺服器的安裝與登記」。

| 範本 | 內容 | 使用者 |
| --- | --- | --- |
| `templates/claude-settings.shared.json` | `~/.claude/settings.json` 的共用部分，目前為外掛啟用狀態（`ai-agents-hooks`、`line-status-board`、`microsoft-docs`）。必裝官方外掛的清單也取自這份範本 | Setup，合併進 `settings.json` |
| `templates/claude-mcp-servers.json` | 要登記的 MCP 伺服器，含名稱與位址；infra-lab 的發行版名稱與 WSL 內路徑為佔位符，由腳本參數帶入 | `Register-McpServer.ps1`，以 `claude mcp add --scope user` 登記 |

`settings.json` 的合併規則如下。

- 範本有而檔案沒有的項目新增；檔案已有的值保留，不覆寫，包含 `enabledPlugins` 內你設為 `false` 的外掛。Setup 的官方外掛步驟同樣尊重這個設定。`enabledPlugins` 內設為 `false` 的官方外掛，Setup 不安裝也不啟用，只在輸出說明你已停用，要使用時自行改回 `true`。
- 範本沒有的項目原樣保留，包含授權（`permissions`）、偏好與機器專屬設定。
- 寫入前先把原檔備份到 `.local/ai-sessions/backups/<時間戳>/settings.json`，同目錄的 `manifest.txt` 以一行記錄這次操作。
- Setup 輸出新增的項目路徑與備份位置，不印出值，可用來檢視套用前後的差異。加上 `-WhatIf` 只列出將新增的項目，不寫入。
- 檔案含 BOM、不是 UTF-8、無法剖析為 JSON、根不是物件，或含僅大小寫不同的重複鍵時，Setup 回報原因並且不寫入。
- 取代檔案前會再確認原檔自讀取後沒有被改動（例如執行中的 Claude Code 剛好寫入），改動過就不寫入，Setup 回報原因並以結束碼 1 結束，確認後重跑即可。`settings.json` 是符號連結時寫入連結指向的實際檔案，連結本身保留；連結指向不存在的位置時不寫入，同樣回報並以結束碼 1 結束。
- 範本內的外掛本次沒有安裝成功時，Setup 略過該外掛的 `enabledPlugins` 項目並說明原因，補裝後重跑 Setup 即可補上。
- PowerShell 低於 7.5 時，Setup 不改寫既有的 `settings.json`，並提示升級（`winget upgrade Microsoft.PowerShell`），因為這些版本會改變日期樣式字串的格式。

MCP 登記共 12 個，名稱為 `mcp-sql-server`、`mcp-oracle`、`mcp-elasticsearch`、`mcp-redis`、`mcp-mosquitto`、`mcp-rabbitmq`、`mcp-mailpit`、`mcp-reader`、`mcp-oidc`、`mcp-api-contract`、`mcp-docker` 與 `infra-lab`。前 11 個屬 mcp-lab，位址為 `http://127.0.0.1:<埠號>/mcp`，埠號以範本為準；`infra-lab` 經 `wsl.exe` 啟動。範本使用 mcp-lab 的預設埠號，改用其他埠號時，`Register-McpServer.ps1 -Check` 會把該項回報為內容不符。名稱已存在但內容與範本不同時，腳本只回報不覆寫，並且不印出現有內容；要改用範本時，先執行 `claude mcp remove <名稱> --scope user` 再重新執行腳本。登記只經 `claude mcp add --scope user` 寫入 `~/.claude.json`，不直接改寫該檔。缺少 `-InfraLabDistro` 或 `-InfraLabWslRepo`，或值含空白與特殊字元時，腳本略過 infra-lab 並說明補登記的方式。

官方外掛 `microsoft-docs` 為必裝，由 Setup 安裝並啟用；你在 `settings.json` 的 `enabledPlugins` 把它設為 `false` 時除外，Setup 不會重新啟用。`github` 與 `context7` 為選裝，Setup 不安裝，需要時自行執行下列命令。官方 marketplace `claude-plugins-official` 已由 Setup 加入。

```powershell
claude plugin install github@claude-plugins-official --scope user
claude plugin install context7@claude-plugins-official --scope user
```

- `github` 需要 GitHub 個人存取權杖。啟動 Claude Code 前把它設定到環境變數 `GITHUB_PERSONAL_ACCESS_TOKEN`，外掛設定引用這個名稱。權杖的值不寫進任何進版控的檔案。
- `context7` 匿名即可使用。要使用自己的方案時，啟動 Claude Code 前設定環境變數 `CONTEXT7_API_KEY`，名稱取自外掛的 README。

#### Claude Code Hook 設定

本專案的 hook 由本機 marketplace `ai-agents-local` 的 plugin `ai-agents-hooks@ai-agents-local` 提供，原始碼位於 `claude-plugins/`，由 Setup 的 8b 註冊並啟用。hook 在 Claude Code 行程內執行，不另外啟動 PowerShell；模組結構見 `AGENTS.md` §5。修改 plugin 內的 hook 後，新 session 不需重新安裝即可採用新內容。

| Hook | 觸發條件 | 用途 |
| --- | --- | --- |
| `post-edit-write` | Edit 或 Write 工具寫入檔案後 | 提示執行 check-markdown skill（`.md`）；驗證 BOM 規範（`.ps1`/`.csv` 需有 BOM，`.md`/`.json` 等不可有 BOM）。訊息只寫入 debug log，不送給模型 |
| `doc-path` | Edit 或 Write 工具寫入檔案後 | 進版控的 `.md` 含本機磁碟機絕對路徑時，以 `additionalContext` 提醒改用佔位符或相對路徑；只提醒，不阻擋寫入。偵測規則與 pre-commit 使用的 `hooks/lib/doc-path-check.ps1` 相同 |
| `turn-guard` | `UserPromptSubmit`、`PostToolUse`、`PostToolUseFailure`、`Stop` | 將每個 turn 的工具使用與失敗紀錄寫入 `~\.claude\plugins\data\ai-agents-hooks-ai-agents-local\turn-guard\` 下以 `<session_id>.` 開頭的 `.jsonl` 檔（環境變數 `CLAUDE_PLUGIN_DATA` 或 `CLAUDE_CONFIG_DIR` 有設定時改用其下的同名位置）；同一失敗在同一 turn、同一 agent 內第 2 次發生時，以 `additionalContext` 提醒該 agent 一次，要求先說明下次為何會成功，說不出來就停下回報；不阻擋工具執行。`PostToolUse` 與 `PostToolUseFailure` 只對 `Bash`、`PowerShell`、`Read`、`Grep`、`Glob`、`Edit`、`Write`、`Skill`、`Agent` 觸發，其他工具不記錄也不提醒 |
| `host-guard` | `PreToolUse`，工具為 `Bash` 或 `PowerShell` | 命令中任一區段直接呼叫 `powershell.exe`（含 `Start-Process powershell.exe`）時拒絕執行，原因附 `pwsh -NoProfile -File` 寫法。屬最佳努力的策略檢查，輸入無法解析時放行，不涵蓋巢狀 shell（例如 `cmd /c powershell.exe`）、動態組合的命令字串與別名。例外為執行 `Setup-AIGlobalConfig.ps1` 的區段；其他專案明確要求 5.1 時，在 Claude Code 設定的 `env` 加入 `AI_AGENTS_ALLOW_POWERSHELL51=1` |

#### 狀態看板 plugin

`line-status-board@ai-agents-local` 在 Claude Desktop 側邊 Pane 顯示「工作總覽」，依序為 Session、派工、Codex 額度、工作線與工作目錄五個區塊。資料來自 `scripts/Get-LineStatus.ps1 -AsJson` 與 `ccd_session_mgmt.list_sessions`，每 60 秒更新一次，也可按「重新整理」，更新過程不耗用模型 token。同一組掃描範圍在 60 秒內已由其他 Session 執行過腳本時，定時更新沿用該次結果，「最後更新」顯示該結果產生的時間，資料最舊約為兩個更新週期；按「重新整理」或切換工作目錄時一律重新執行。掃描範圍為預設清單加上目前 Session 所在的 repo。

- 點 Session 列會開啟該 Session。
- Session 在等你回答提問或核准計畫時排在最前面，黃點標示「等你回答」或「等你核准計畫」與已等待的時間，並跳一次提醒。等你同意工具權限時同樣排在最前面，標示「等你同意」；外掛取不到「已同意」的訊號，超過 5 分鐘後無法分辨仍在等待還是已同意而工具仍在執行，因此改為灰點與「同意請求 N 分鐘前」，不計入狀態列，也不再提醒。只有安裝此 plugin 的 Desktop Session 會回報等待狀態；該 Session 已封存、等待之後已有新的活動，或等待超過 24 小時時不顯示。
- 派工區塊列出 `scripts/Invoke-CodexRun.ps1` 執行中與最近結束的派工，含線、類型、帳號、已執行時間、最後事件時間、結果與耗時。最後事件的時間只供參考，長時間推理期間沒有事件屬正常。已超過總時限、且最後事件也早於總時限仍沒有結果的派工以紅色標示為可能已中斷。紀錄帶有該次的時限設定時，總時限以紀錄為準（只帶其中一項時另一項取入口預設值），最後事件只要早於回合結束寬限（至少 60 秒）就視為沒有近期事件。最後活動超過 24 小時仍沒有結果的紀錄不再列出。「複製診斷明細」複製派工的完整欄位，以及每個等待項目當下讀到的 `isRunning`、`lastActivityAt` 與判定結果。
- Codex 額度列在帳號登入失效時顯示「登入失效」與該帳號的重新登入命令，達到用量上限時顯示「已達上限」。登入由使用者自行執行。沒有週視窗的帳號，額度列的週額度位置顯示「無週視窗」。各帳號另顯示最近一次派工的結果，以及 24 小時內被服務端回報不支援的 model。帳號顯示「已達上限」且最近一次派工的服務端拒絕訊息含重設時間時，同列加註「重設 11/22 17:21（約 4 天後）」；重設時間已過或訊息沒有重設時間時不加註。重設時間取自執行紀錄的 `limit_reset_local`，只有 `Invoke-CodexRun.ps1` 寫出的紀錄帶這個欄位，加入此欄位之前產生的紀錄沒有重設時間，不會顯示。服務端訊息不含時區，重設時間視為執行機器的本地時間。重設時間取自該帳號最近一次被拒的派工，服務端沒有說明它對應哪一個額度視窗。
- 狀態列顯示一行摘要，內容為等你處理的 Session 數、執行中 Session 數與額度最低帳號的剩餘量。
- Session 由執行中轉為閒置時跳一次提醒；看板載入後取得的第一次狀態只作為比較基準。
- 全部帳號的額度剩餘量都低於 20% 時跳一次提醒，提醒文字依各帳號的額度視窗長度標示（例如 5 小時、30 天）。同一視窗只提醒一次，視窗重設後才再提醒。已達上限與登入失效的帳號視同低於門檻；有帳號查詢失敗時不提醒。
- 清理按鈕呼叫 `scripts/Invoke-WorkOverviewCleanup.ps1`，先列出可清理項目、大小與不能清的原因，按確認後才刪除。看板對工作區檔案的寫入只有清理；提醒狀態、等待狀態與共用的腳本結果存在 plugin 的 store，複製按鈕寫入剪貼簿。

Setup 的 8b 會安裝並啟用此 plugin，Desktop 開新 Session 時自動開啟 Pane。不執行 Setup 時，可手動安裝：

```powershell
claude plugin marketplace add ~/.ai-agents/claude-plugins
claude plugin install line-status-board@ai-agents-local --scope user
```

`workRoots` 可設定以分號分隔的掃描位置，空白時使用腳本預設值；`scriptPath` 可指定腳本路徑，空白時自動尋找；`notifySessionDone` 控制 Session 跑完與等你處理的提醒，預設開啟。修改設定後執行 `/reload-plugins`。plugin 需搭配同一 repo 的新版腳本。已安裝的 plugin 直接讀取本 repo 的資料夾，改動落地後新開的 Session 即使用新版，不需重跑 Setup。

### Codex — `~/.codex/`（或 `$CODEX_HOME`）

| 檔案 | 用途 |
| --- | --- |
| `AGENTS.md` | 全域指令檔（Codex 會載入） |
| `AGENTS.override.md` | 全域覆蓋檔（若存在且非空會優先套用） |

| 路徑 | 用途 |
| --- | --- |
| `agents/<name>.toml` | 自訂 Agent（執行型，以 `/agent <name>` 切換） |
| `~/.agents/skills/<name>/SKILL.md` | 使用者技能（Codex 會掃描） |

#### Codex CLI 前置需求

- 使用 `npm i -g @openai/codex` 安裝 Codex CLI，更新使用 `codex update`。
- 跨平台派工需要在 PATH 上找到 `codex`。桌面版隨附的 `bin\codex.exe` 版本固定在安裝當下，不會隨桌面版更新，不能用於派工。
- 安裝或更換環境時執行 `codex --version` 確認 CLI 可用；更換機器後先執行 `codex doctor`，確認執行檔、PATH 與本機設定可用。
- 派工腳本、狀態查詢腳本、Setup 與派工測試都需要 PowerShell 7+（pwsh）。以 Windows PowerShell 5.1 執行時，Setup 印出安裝指引後結束，其餘腳本會被 `#Requires -Version 7.0` 拒絕。
- 審查、事實校閱、影像產生、測試取證與顧問的派工由 `scripts/Invoke-CodexRun.ps1` 執行（顧問只開放輸出目錄與專案說明檔 `AGENTS.md`，測試取證的命令沙盒唯讀、只以 MCP 工具操作已啟動的受測對象，其餘直接在線工作樹執行），不建立隔離 worktree，需要 Codex 的 MXC 沙盒。偵測不到 MXC 時腳本停止並回報。

#### Windows 長路徑

線工作樹內的 NuGet 套件路徑可能超過 260 字元。執行 `Setup-AIGlobalConfig.ps1` 時會檢查 Windows 的 `LongPathsEnabled`，也可在 PowerShell 中查詢：

```powershell
Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled
```

以系統管理員身分執行下列命令可啟用長路徑；加上 `-WhatIf` 可預覽設定。設定後需重新登入或重開機才生效。

```powershell
.\scripts\Setup-AIGlobalConfig.ps1 -EnableLongPaths
```

#### Codex profile 檔位設定

1. 派工使用的檔位清單以 `scripts/dispatch/executor-registry.json` 為準，不在本文件另列。現行清單與各檔位的設定用 `pwsh -NoProfile -File scripts\Select-DispatchExecutor.ps1 -Describe` 查詢（各 Codex 執行者的 `profile` 與 `profileSettings`）。派工以 `--profile <檔位>` 讀取選定 Codex home 內的 `<CodexHome>/<檔位>.config.toml`。`scripts/Invoke-CodexRun.ps1` 依 `machine.json` 登記順序選第一個可用帳號（已登入、檔位設定檔齊備，且未被記為不支援該檔位 model），不檢查專案信任，登記清單為空時停止，不預設 `~/.codex`；選定帳號後、啟動 Codex 前，另比對實際要使用的帳號的檔位設定檔：必須是指向主 checkout 產生檔的 Symbolic Link 且內容相同（一般檔案即使內容相同也不通過，不允許單機覆寫），入口所在工作樹的登錄表設定也必須已落地到主 checkout。不一致時以結束碼 2（`CodexProfileDrift`）停止，列出每行可直接貼到 pwsh 的修正命令，不自行改檔，也不跳到下一個帳號；所有已登入帳號的檔位檔都缺失時同樣以此方式回報，不會被當成帳號全數不可用；換帳號後對新的候選帳號在使用前再比對一次，未使用的候選帳號不一致不阻擋。派遣檔的 `profile` 與 `task_type` 不符時在啟動前停止。執行者與檔位的對應由 `scripts/dispatch/executor-registry.json` 決定，規則見 `rules/claude/30-dispatch.md` 與 `executor-selection` skill。
2. 設定檔內容為各檔位要使用或覆寫的 Codex 設定，常用鍵如下。這些值寫在 `scripts/dispatch/executor-registry.json` 各 Codex 執行者的 `profileSettings`（`model`、`effort`、`subagentModel`、`subagentEffort`），不手動編輯設定檔。`profileSettings` 另可選填 `fallbackModels`，列出帳號不支援主要 model 時依序改用的 model；`Invoke-CodexRun.ps1` 以 `-c model=` 套用，產生檔只以註解列出這份清單。`profileSettings` 也可選填 `mcpServers`（目前只有測試取證檔位 `scan`：`playwright` 與 `flaui-mcp`），產生檔輸出 `[mcp_servers.*]` 表，核准模式固定 `approve`，以 `enabled_tools` 限制可用工具；省略 `command` 的伺服器（`flaui-mcp`，路徑因機器而異）由 Setup 從 Codex Desktop 的 `config.toml` 讀取 `command` 後，以 `enabled = false` 追加到各派工帳號的 `config.toml`，`-Check` 檢查該項目。`effort` 與 `subagentEffort` 必須在登錄表的 `codexEfforts` 清單內（`max` 需要 Codex 0.147 以上）。

   ```toml
   model = "<model-id>"
   model_reasoning_effort = "<effort>"

   [agents]
   default_subagent_model = "<較低成本的 model-id>"
   default_subagent_reasoning_effort = "<effort>"
   ```

3. 每個檔位的設定寫在各自的 `<檔位>.config.toml`。執行時先載入 Codex home 的 `config.toml`，再疊加所選檔位的設定。`config.toml` 內的 `[profiles.*]` 屬 legacy 格式。
4. 登錄表是檔位名稱與設定的唯一來源，增減檔位或調整 model 與推理強度只改登錄表。`.githooks/pre-commit` 以 `-FromIndex` 呼叫 `.githooks/Update-CodexProfiles.ps1`，依暫存區內的登錄表產生 `scripts/codex-profiles/<檔位>.config.toml` 並暫存，這些產生檔進版控，檔首註明請勿手改。需要手動重產生時執行 `pwsh -NoProfile -File .githooks\Update-CodexProfiles.ps1`，加 `-Check` 只比對不寫檔。
5. Setup 只處理帳號目錄：先確認 repo 內的產生檔與登錄表一致（不一致就停止並說明要先重新產生），再對 `machine.json` 登記的每個派工帳號，缺少的檔位檔建成指向本 repo `scripts/codex-profiles/` 同名產生檔的 Symbolic Link，已正確者略過。帳號目錄已有一般檔案或指向別處的連結時，Setup 不覆蓋，列出狀態與要執行的命令，結束碼為 1。不允許單台電腦覆寫檔位設定，要改設定就改登錄表。逐項建立連結時中途失敗，已建立的連結保留（它們是正確狀態），修正原因後重跑 Setup 即可補完。
6. 沒有登記任何派工帳號時，`Invoke-CodexRun.ps1` 以結束碼 4 與 `CodexAccountsNotRegistered` 停止，Setup 也不替 `~/.codex` 建立檔位設定檔。此情形需先以 `scripts\New-CodexDispatchAccount.ps1` 登記派工帳號。
7. `~/.codex` 是 Codex Desktop 自己的目錄。已登記派工帳號且各帳號目錄的連結都已指向 repo 產生檔時，派工不再讀取其中的現行檔位設定檔，Setup 逐檔列出可自行執行的 `Remove-Item -LiteralPath` 命令，不自動刪除。已退役的檔位名稱列在登錄表的 `retiredProfiles`，這些名稱的殘留檔無論如何都不再被讀取，Setup 同樣逐檔列出移除命令。

#### 獨立 Codex 帳號目錄

派工可使用專用的 Codex 帳號目錄，與 Codex Desktop 使用的預設目錄 `~/.codex` 分開。派工只在單次子行程指定 `CODEX_HOME`，不會更換、改寫 Desktop 或預設目錄的登入，因此 Desktop 使用中不會被派工切換帳號。建議的配置是 `~/.codex` 留給 Desktop 且不登記，派工用的每個帳號各用一個專用目錄。Desktop 與某個派工帳號若登入同一個 ChatGPT 帳號，兩邊仍共用該帳號的額度。

派工帳號以 `scripts\New-CodexDispatchAccount.ps1` 建立。腳本建立 `~/.codex-<名稱>` 目錄與最小 `config.toml`，以連結指向主 checkout 的 `scripts/codex-profiles/` 檔位產生檔（檔名清單取自登錄表），並登記到 `~/.ai-agents/.local/machine.json`。

```powershell
.\scripts\New-CodexDispatchAccount.ps1 -Name account-a
```

在 PowerShell 提示字元直接執行。`Invoke-CodexRun.ps1` 不做專案信任預檢，也不自動補信任。`-ProjectPath` 為選填，用於預先信任專案，例如 `-ProjectPath 'C:\Users\<使用者>\.ai-agents'`。

帳號已存在時重跑只補缺少的部分，不覆寫既有設定；之後要預先信任新專案時，以 `-ProjectPath` 重跑。設定不符時，腳本列出問題與修法，不留下做一半的狀態。加上 `-WhatIf` 可預覽而不寫入。建立 Symbolic Link 權限不足時，改以具備建立 Symbolic Link 權限的 PowerShell 重新執行。

`config.toml` 的最小內容為 `[windows]` 段。`[projects.'<小寫的專案絕對路徑>']` 由 `-ProjectPath` 預先加入。下例為加入一個專案信任後的內容。

```toml
[windows]
sandbox = "mxc"

[projects.'c:\users\<使用者>\.ai-agents']
trust_level = "trusted"
```

`[windows]` 段的 `sandbox` 接受 `"mxc"` 與 `"elevated"`，缺少 `[windows]` 段時補上 `"mxc"`。Windows 上新啟動的派工一律以 MXC 執行，由派工腳本指定，不依賴此設定值。

缺少檔位設定檔（`<檔位>.config.toml`）的登記帳號在自動選帳號時被略過（原因碼 `ProfileConfigMissing`），由 Setup 或建立腳本補齊。

未登入的帳號同樣會被略過，全部帳號都不可用時拒絕派工並說明原因。帳號回報檔位 model 不支援（停用訂閱的帳號也以此呈現）時，派工腳本把該帳號與 model 記在 `.local\codex-account-health.json`，24 小時內派工會略過該帳號；所有帳號都被記錄時仍實際嘗試一次。

腳本不執行登入，最後輸出已設定 `CODEX_HOME` 的登入命令，由使用者自行執行。

```powershell
powershell.exe -NoProfile -Command '$env:CODEX_HOME = ''C:\Users\<使用者>\.codex-account-a''; codex login'
```

帳號閒置過久時 token 會失效，`Get-CodexQuota.ps1` 或派工會回報 401。派工回報 401，或帳號因登入檔缺少、為空而被略過時，派遣結果會附上該帳號、格式與上例相同的登入命令，執行該命令重新登入。

---

## 4. 目錄結構總覽

```plaintext
~/.ai-agents/
├── .gitignore                          # 版控排除清單
├── .gitattributes                      # 行尾格式與二進位標記
├── .editorconfig                       # 編輯器格式設定（最高優先）
├── .githooks/                          # Git 原生 Hook（pre-commit、Update-Docs.ps1、Test-StagedDocPath.ps1 與 Update-CodexProfiles.ps1）
├── AGENTS.md                           # 維護本 repo 的專案層規則
├── LICENSE.md                          # 授權條款
├── README.md                           # 本文件
├── instructions.md                     # 核心開發規範（主 Rule，Claude 與 Codex 共用）
├── rules/
│   └── claude/                         # 只在 Claude 端載入的常駐規則（Persona、協調與授權、派工、Workflow 與審查）
├── docs/                               # Agent／Skill 索引（生成檔）與 ADR（adr/）
├── git-global-excludes                 # 機器層 Git 排除清單
├── agents/
│   ├── claude/                         # Persona 與 sub-agent 規則檔（.md 格式），含全部實作類角色
│   └── codex/                          # 審查類 Agent 規則檔（.toml 格式，Codex 離線時由 Claude Sonnet subagent 同樣讀取）
├── claude-plugins/                     # 本機 marketplace、hook 與狀態看板 plugin
├── skills/                             # 技能模組（Skill）
├── templates/                          # 新專案初始化範本、Demo 外框範本、派工範本，以及 Claude MCP 登記與 settings.json 的共用範本
└── scripts/                            # 安裝、派工、查詢與索引腳本（dispatch/ 責任檔、lib/ 登錄表讀取與驗證、Claude 使用者層設定、MCP 登記與 -Check 模組、codex-profiles/ 檔位設定檔產生檔、tests/ 測試）
```

---

## 5. Scripts 與命名慣例

- `scripts/` 根目錄只放使用者可直接執行的 Verb-Noun `.ps1` 與既有 `.csx` 腳本。
- `scripts/Get-LineStatus.ps1` 唯讀彙整線狀態、Git 狀態、額度與 `Invoke-CodexRun.ps1` 的執行紀錄。
- `scripts/Select-DispatchExecutor.ps1` 依任務標註與 `scripts/dispatch/executor-registry.json` 選出派工執行者並輸出 `[派工]` 判定行，唯讀、不呼叫網路。
- `scripts/Invoke-CodexRun.ps1` 對一份派遣檔執行一次 `codex exec`，目前用於審查、事實校閱、影像產生、測試取證與顧問，啟動前比對帳號目錄的檔位設定檔與 repo 產生檔。帳號由 `machine.json` 登記清單選擇，讀取主 checkout 的 `.local/machine.json`，在線工作樹發動時相同。專案信任的處理見 `skills/codex-dispatch/references/run.md` 的「帳號」章節。
- `scripts/Test-CodexReviewReport.ps1` 檢查審查報告的 finding 清單，`valid` 為 `false` 時結束碼為 1。
- `scripts/Write-ClaudeRunRecord.ps1` 為 Claude 審查者（subagent）的一次審查在 `runs\` 寫出與 Codex 同位置的執行紀錄：`-Action Start` 保存派生前的來源狀態，`-Action End` 判定 `source_changed` 與報告檢查並補完紀錄；紀錄沒有 token 用量，`Get-LineCost.ps1` 標示後不計入合計。
- `scripts/Update-ExecutorIncomplete.ps1` 保存同一任務各執行者的未完成次數（`Add`、`Show`、`Reset`），並輸出可直接作為 `Select-DispatchExecutor.ps1 -Incomplete` 的值；選派入口不讀這個檔。
- `scripts/Get-CodexQuota.ps1` 查詢 Codex 額度，只供顯示與紀錄。
- `scripts/Invoke-WorkOverviewCleanup.ps1` 列出可清理的 worktree、分支與線層歷史備份，必須指定 `-Root`；預設只列出，以 `-ConfirmPlan` 帶入列出時的 planId 才刪除。
- `scripts/Get-ClaudeSessionUsage.ps1` 唯讀彙總主 session 與子代理 transcript 用量，依 `message.id` 去重，分別輸出主 session、子代理與總計三組。
- `scripts/Get-LineCost.ps1` 唯讀彙整一條線的成本並輸出 JSON：`runs\*.record.json`（含 Claude 審查者的紀錄，標示無 token 用量）與 `cost-ledger.md` 事件列的 Codex 執行次數、model、token、結果與耗時；Claude 用量只在以 `-ClaudeSessionId` 或 `-ClaudeTranscriptPath` 指定時重用 `Get-ClaudeSessionUsage.ps1` 計算，否則為 null 並附原因。
- `scripts/Setup-AIGlobalConfig.ps1` 建立各工具的 symlink 與 Git Hook 設定，並安裝必裝的官方外掛、套用 `settings.json` 共用範本，見「安裝」與 §3。MCP 伺服器的登記不在 Setup。
- `scripts/Register-McpServer.ps1` 把 mcp-lab、infra-lab 登記到 Claude Code 使用者層，把 FlaUI.Mcp 的執行檔路徑寫入 Codex 桌面版與各派工帳號的設定，只寫設定，不安裝，可指定只處理其中幾項，附 `-WhatIf` 與唯讀的 `-Check`，見「安裝」的「MCP 伺服器的安裝與登記」。
- `scripts/lib/claude-user-config.ps1` 是 Setup 與 `Register-McpServer.ps1` 共用的 Claude 使用者層設定模組，包含 Claude CLI 呼叫、範本讀取、MCP 登記計畫、`settings.json` 合併、官方外掛安裝，以及 WSL 與連接埠探測；`scripts/lib/mcp-registration.ps1` 是 `Register-McpServer.ps1` 的登記、FlaUI 設定檔寫入與檢查；`scripts/lib/setup-check.ps1` 是 `Setup-AIGlobalConfig.ps1 -Check` 的比對與輸出。三者都只定義函式，只支援 pwsh 7。
- `scripts/New-CodexDispatchAccount.ps1` 建立派工帳號，見 §3。
- `scripts/Ensure-AiContextArtifacts.ps1` 依來源指紋決定是否重產 `.local/ai-context/` 的索引產物，並呼叫 `Export-ApiSurface.csx`、`Export-TypeHierarchy.csx` 與 `Export-ProjectGraph.csx`。
- `scripts/Export-CommentVocabularyCandidates.csx` 唯讀掃描 `.cs`，輸出資料庫註解語彙候選 JSON，由 `database-comment-generator` skill 使用。
- 內部責任檔、loader 與測試輔助放在子目錄，例如 `scripts/dispatch/` 與 `scripts/tests/`。
- `scripts/tests/Test-CodexRunAll.ps1` 執行 `Invoke-CodexRun.ps1` 的全部測試，不呼叫 Codex 服務端。`scripts/tests/Invoke-CodexRunLive.ps1 -Scenario review|failover` 以真實 Codex 驗證一筆審查與一筆換帳號，加上 `-DryRun` 只列出將執行的內容，不加 `-DryRun` 會呼叫 Codex 服務端並消耗額度。
- 派工測試只以 PowerShell 7（pwsh）執行，不再執行 Windows PowerShell 5.1。其他測試檔各自獨立執行，位於 `scripts/tests/`，其中包含 `Test-PowerShellHostGuardHook.ps1`（`powershell.exe` 攔截 hook）、`Test-TurnGuardHook.ps1`、`Test-DocLocalPathCheck.ps1` 與 `Test-PostEditWriteHook.ps1`（其餘三個 hook）、`Test-SetupRequiresPwsh7.ps1`（Setup 的版本判斷）、`Test-SetupCheck.ps1`（Setup 的 `-Check` 唯讀檢查）、`Test-ClaudeUserConfig.ps1`（Claude 使用者層設定模組）與 `Test-McpRegistration.ps1`（`Register-McpServer.ps1`）。
- hook 的四個 PowerShell 測試經 `claude-plugins/ai-agents-hooks/tests/run-hook.ts` 執行 `hooks/core/` 的判定邏輯，需要 PATH 上有 Node.js 22.18 以上（可直接執行 `.ts`）；Node.js 只用於測試，外掛執行時不需要。
- `claude-plugins/line-status-board/tests/` 另有 `lib.test.ts`、`render.test.tsx` 與 `dispatch.test.tsx` 三個測試檔，`claude-plugins/ai-agents-hooks/tests/` 有 `register.test.ts`，皆從 `claude-code/testing` 匯入，以 `claude plugin test <plugin 目錄>` 執行。
- `claude-plugins/` 內的檔案使用全小寫 kebab-case 命名。
- `.githooks/` 內為 Git 原生 Hook，由 `Setup-AIGlobalConfig.ps1` 透過 `core.hooksPath` 啟用。

### Git Hook 設定

執行 `Setup-AIGlobalConfig.ps1` 時會自動完成以下設定：

```powershell
git config core.hooksPath .githooks
```

啟用後，每次 `git commit` 會自動執行 `.githooks/Update-Docs.ps1`，重新產生 `docs/agents.md` 與 `docs/skills.md` 並納入本次 commit。這兩個檔案為生成檔，請勿手動編輯；frontmatter 不一致時，腳本以非零結束碼阻止 commit。每次 `git commit` 另會檢查 staged 的 `.md`、`.toml` 新增行是否含磁碟機絕對路徑（`.githooks/Test-StagedDocPath.ps1`），違規時阻止 commit。通過後，`.githooks/Update-CodexProfiles.ps1` 依登錄表重新產生 `scripts/codex-profiles/` 的檔位設定檔並納入本次 commit。

---

## 6. 內建 Skill 清單

詳見 [docs/skills.md](./docs/skills.md)。

Skill 分為兩種類型：

- **知識型**：Claude 依上下文自動載入並套用（如編碼規範、LINQ 查詢規則）。
- **指令型**：須使用者以 `/skill-name` 明確觸發（如 `/generate-changelog-zh-tw`、`/generate-api-doc`）。

---

## 7. 內建 Agent 清單

詳見 [docs/agents.md](./docs/agents.md)。

Agent 依執行平台分為兩類：

- **Persona**：以語意切換方式執行。適合需要多輪對話、強依賴上下文的需求分析、實作階段控制與文件編輯。
- **sub-agent**：由主 Agent 派生。適合有明確輸入與交接檔案的設計、審查、掃描與清理任務。

### Agent 執行流程

```mermaid
flowchart TD
    Analyst["**Analyst**<br />需求解構＋構想發散"]
    Prototyper["**Prototyper**<br />Demo 畫面產出"]
    Architect["**Architect**<br />系統設計"]
    Developer["**Developer**<br />程式設計師"]
    Reviewer["**Reviewer**<br />後端驗收"]
    FrontendReviewer["**Frontend Reviewer**<br />前端驗收"]
    Refactorer["**Refactorer**<br />技術債清理"]
    ArchitectureImprovement["**architecture-improvement**<br />候選分析"]
    Maintainer["**Maintainer**<br />bug 線協調者"]
    SupportEngineer["**Support Engineer**<br />實作修改"]
    Done(["任務完成"])

    Analyst --> Architect
    Analyst -->|先做 Demo| Prototyper
    Prototyper -->|回填需求摘要| Analyst
    Architect --> Developer
    Developer -->|後端審查<br />handoff| Reviewer
    Developer -->|前端審查<br />handoff| FrontendReviewer
    Developer -->|技術債清理| Refactorer
    Reviewer -->|補完實作| Developer
    Reviewer -->|重新評估範圍| Analyst
    Reviewer --> Done
    FrontendReviewer -->|補完實作| Developer
    FrontendReviewer --> Done
    Refactorer -->|驗證後交付| Done

    ArchitectureImprovement -->|候選報告| Analyst

    Maintainer -->|派生＋fix-plan| SupportEngineer
    SupportEngineer -->|回報| Maintainer
    Maintainer --> Done
```

流程分為四條路徑。

- **功能線**：Analyst 確認需求後交 Architect 設計，實作與審查由主 Agent 派出。需要先看畫面時，先由 Prototyper 產出 Demo。
- **bug 線**：Maintainer 診斷後派生 Support Engineer 修正並驗收。
- **技術債清理**：由 Refactorer 處理，每批修改後執行測試。
- **架構改善**：`architecture-improvement` skill 由人員觸發，先產出候選報告，確認範圍後才進入設計。

---

## License

This project is licensed under the [MIT License](./LICENSE.md).
