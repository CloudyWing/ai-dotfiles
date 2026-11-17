# AI 全域設定 (.ai-agents)

本目錄為個人全域 AI 輔助開發設定，適用於 Claude Code、Codex 等工具，內容充滿個人習慣與偏好，僅供參考。

**本專案必須 clone 至 `~/.ai-agents/`，setup script 與各工具連結皆依賴此路徑：**

```bash
git clone https://github.com/CloudyWing/ai-dotfiles.git ~/.ai-agents
```

## 安裝

1. 以系統管理員身分開啟 PowerShell 7（pwsh），在 pwsh 執行 Setup。在 Windows PowerShell 5.1 啟動時，Setup 會印出 `winget install Microsoft.PowerShell` 安裝指引並以非零結束碼結束；不是以系統管理員身分執行時同樣直接結束。加上 `-WhatIf` 可預覽。

   ```powershell
   ~\.ai-agents\scripts\Setup-AIGlobalConfig.ps1
   ```

   要確認這台電腦的設定是否齊全、連結是否指向正確位置，而不做任何改動時，加上 `-Check`（不需系統管理員身分，只讀取現況）。輸出逐項的符合、缺少、指向錯誤位置、內容不符與無法判定，最後附統計；全部符合時結束碼為 0，否則為 1。加上 `-AsJson` 改輸出機器可讀的 JSON。檢查項目涵蓋現役連結、工具目錄、斷鍊孤兒、Claude plugin 與 marketplace、舊 hook 註冊、`core.hooksPath`、`core.excludesFile` 與 Codex 檔位設定檔連結；Codex CLI 與版本不在檢查範圍。`-Check` 不能與 `-Force` 或 `-EnableLongPaths` 併用。

   ```powershell
   ~\.ai-agents\scripts\Setup-AIGlobalConfig.ps1 -Check
   ```

2. Setup 依序完成下列項目，重跑只補缺少的部分。
   - 建立各工具指向本 repo 的 Symbolic Link，對應位置見 §3。
   - 註冊本機 marketplace `ai-agents-local`，安裝並啟用其中的 plugin（hook 與狀態看板）。
   - 設定本 repo 的 `core.hooksPath` 與機器層 Git 排除清單。
   - 檢查 Windows 長路徑與 Codex CLI；把各派工帳號目錄的檔位設定檔建成指向 repo 產生檔的 Symbolic Link，已有一般檔案或指向別處的連結時不覆蓋，改列出要執行的命令；其餘缺件印出修復指引。
3. 需要跨平台派工時，依 §3「Codex CLI 前置需求」安裝 Codex CLI，並依「Codex profile 檔位設定」確認檔位設定檔。派工帳號目錄為選用，見「獨立 Codex 帳號目錄」。

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
| 測試（煙霧驗證取證）、事實校閱、顧問、影像產生 | Codex | 由主 Agent 依執行者登錄表以資源派遣發動 |

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
| `docs/adr/` | Architecture Decision Record | 由 `adr` skill 依決策門檻追加 |

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
| `settings.json` | 工具權限與其他使用者設定 |

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
- Codex 額度列在帳號登入失效時顯示「登入失效」與該帳號的重新登入命令，達到用量上限時顯示「已達上限」。登入由使用者自行執行。沒有週視窗的帳號，額度列的週額度位置顯示「無週視窗」。各帳號另顯示最近一次派工的結果，以及 24 小時內被服務端回報不支援的 model。
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

派工 worktree 內的 NuGet 套件路徑可能超過 260 字元。執行 `Setup-AIGlobalConfig.ps1` 時會檢查 Windows 的 `LongPathsEnabled`，也可在 PowerShell 中查詢：

```powershell
Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled
```

以系統管理員身分執行下列命令可啟用長路徑；加上 `-WhatIf` 可預覽設定。設定後需重新登入或重開機才生效。

```powershell
.\scripts\Setup-AIGlobalConfig.ps1 -EnableLongPaths
```

#### Codex profile 檔位設定

1. 派工使用的檔位清單以 `scripts/dispatch/executor-registry.json` 為準，不在本文件另列。現行清單與各檔位的設定用 `pwsh -NoProfile -File scripts\Select-DispatchExecutor.ps1 -Describe` 查詢（各 Codex 執行者的 `profile` 與 `profileSettings`）。派工以 `--profile <檔位>` 讀取選定 Codex home 內的 `<CodexHome>/<檔位>.config.toml`。未指定 home 時，`machine.json` 登記清單非空則由腳本依登記順序選第一個可用帳號（已登入、檔位設定檔齊備、專案信任可用，且未被記為不支援該檔位 model），清單為空才預設 `~/.codex`。審查類使用的 `scripts/Invoke-CodexRun.ps1` 不檢查專案信任，登記清單為空時停止，不預設 `~/.codex`；選定帳號後、啟動 Codex 前，另比對實際要使用的帳號的檔位設定檔：必須是指向主 checkout 產生檔的 Symbolic Link 且內容相同（一般檔案即使內容相同也不通過，不允許單機覆寫），入口所在工作樹的登錄表設定也必須已落地到主 checkout。不一致時以結束碼 2（`CodexProfileDrift`）停止，列出每行可直接貼到 pwsh 的修正命令，不自行改檔，也不跳到下一個帳號；所有已登入帳號的檔位檔都缺失時同樣以此方式回報，不會被當成帳號全數不可用；換帳號後對新的候選帳號在使用前再比對一次，未使用的候選帳號不一致不阻擋。Request 必須指定 `profile`；指定 `default`、缺少 `profile` 或設定檔不存在時在啟動前拒絕。執行者與檔位的對應由 `scripts/dispatch/executor-registry.json` 決定，規則見 `rules/claude/30-dispatch.md` 與 `executor-selection` skill。
2. 設定檔內容為各檔位要使用或覆寫的 Codex 設定，常用鍵如下。這些值寫在 `scripts/dispatch/executor-registry.json` 各 Codex 執行者的 `profileSettings`（`model`、`effort`、`subagentModel`、`subagentEffort`），不手動編輯設定檔。`profileSettings` 另可選填 `fallbackModels`，列出帳號不支援主要 model 時依序改用的 model；`Invoke-CodexRun.ps1` 以 `-c model=` 套用，產生檔只以註解列出這份清單。`profileSettings` 也可選填 `mcpServers`（目前只有測試取證檔位 `scan`：`playwright` 與 `flaui-mcp`），產生檔輸出 `[mcp_servers.*]` 表，核准模式固定 `approve`，以 `enabled_tools` 限制可用工具；省略 `command` 的伺服器（`flaui-mcp`，路徑因機器而異）由 Setup 從 Codex Desktop 的 `config.toml` 讀取 `command` 後，以 `enabled = false` 追加到各派工帳號的 `config.toml`，`-Check` 檢查該項目。`effort` 與 `subagentEffort` 必須在登錄表的 `codexEfforts` 清單內（`max` 需要 Codex 0.147 以上，見 §8）。

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
6. 沒有登記任何派工帳號時，舊入口 `Invoke-CodexDispatch.ps1` 回退使用 `~/.codex`，而 Setup 不再替 `~/.codex` 建立檔位設定檔。此情形需先以 `scripts\New-CodexDispatchAccount.ps1` 登記派工帳號，或自行在 `~/.codex` 準備檔位設定檔。
7. `~/.codex` 是 Codex Desktop 自己的目錄。已登記派工帳號且各帳號目錄的連結都已指向 repo 產生檔時，派工不再讀取其中的現行檔位設定檔，Setup 逐檔列出可自行執行的 `Remove-Item -LiteralPath` 命令，不自動刪除。沒有登記派工帳號時，舊入口回退使用這些檔案，不要移除。已退役的檔位名稱列在登錄表的 `retiredProfiles`，這些名稱的殘留檔無論如何都不再被讀取，Setup 同樣逐檔列出移除命令。

#### 獨立 Codex 帳號目錄

派工可使用專用的 Codex 帳號目錄，與 Codex Desktop 使用的預設目錄 `~/.codex` 分開。派工只在單次子行程指定 `CODEX_HOME`，不會更換、改寫 Desktop 或預設目錄的登入，因此 Desktop 使用中不會被派工切換帳號。建議的配置是 `~/.codex` 留給 Desktop 且不登記，派工用的每個帳號各用一個專用目錄。Desktop 與某個派工帳號若登入同一個 ChatGPT 帳號，兩邊仍共用該帳號的額度。

派工帳號以 `scripts\New-CodexDispatchAccount.ps1` 建立。腳本建立 `~/.codex-<名稱>` 目錄與最小 `config.toml`，以連結指向主 checkout 的 `scripts/codex-profiles/` 檔位產生檔（檔名清單取自登錄表），並登記到 `~/.ai-agents/.local/machine.json`。

```powershell
.\scripts\New-CodexDispatchAccount.ps1 -Name account-a
```

在 PowerShell 提示字元直接執行。派工時會自動把派遣的專案加入該帳號的信任清單，建立帳號時不必列出專案。`-ProjectPath` 為選填，用於預先信任專案，例如 `-ProjectPath 'C:\Users\<使用者>\.ai-agents'`。

帳號已存在時重跑只補缺少的部分，不覆寫既有設定；之後新增專案不需要重跑。設定不符時，腳本列出問題與修法，不留下做一半的狀態。加上 `-WhatIf` 可預覽而不寫入。建立 Symbolic Link 權限不足時，改以具備建立 Symbolic Link 權限的 PowerShell 重新執行。

`config.toml` 的最小內容為 `[windows]` 段。`[projects.'<小寫的專案絕對路徑>']` 由派工時自動補上，或由 `-ProjectPath` 預先加入。下例為補上一個專案信任後的內容。

```toml
[windows]
sandbox = "mxc"

[projects.'c:\users\<使用者>\.ai-agents']
trust_level = "trusted"
```

`[windows]` 段的 `sandbox` 接受 `"mxc"` 與 `"elevated"`，缺少 `[windows]` 段時補上 `"mxc"`。Windows 上新啟動的派工一律以 MXC 執行，由派工腳本指定，不依賴此設定值。

缺少 `config.toml` 的登記帳號在自動選帳號時被略過（原因碼 `TrustConfigMissing`），由建立腳本補齊。

`config.toml` 設定異常的帳號會被略過，全部帳號都不可用時拒絕派工並說明原因。帳號回報檔位 model 不支援（停用訂閱的帳號也以此呈現）時，派工腳本把該帳號與 model 記在 `.local\codex-account-health.json`，24 小時內派工會略過該帳號；所有帳號都被記錄時仍實際嘗試一次。

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
├── templates/                          # 新專案初始化範本、Demo 外框範本與派工範本
└── scripts/                            # 安裝、派工、查詢與索引腳本（dispatch/ 責任檔、lib/ 登錄表讀取與驗證、codex-profiles/ 檔位設定檔產生檔、tests/ 測試）
```

---

## 5. Scripts 與命名慣例

- `scripts/` 根目錄只放使用者可直接執行的 Verb-Noun `.ps1` 與既有 `.csx` 腳本。
- `scripts/Get-DispatchProgress.ps1` 唯讀查詢派遣進度，可依 `LineSlug` 或 `DispatchSlug` 篩選；預設顯示未結束與最近 24 小時內結束的項目。
- `scripts/Get-LineStatus.ps1` 唯讀彙整線狀態、Git 狀態、額度與 `Invoke-CodexRun.ps1` 的執行紀錄。
- `scripts/Select-DispatchExecutor.ps1` 依任務標註與 `scripts/dispatch/executor-registry.json` 選出派工執行者並輸出 `[派工]` 判定行，唯讀、不呼叫網路。
- `scripts/New-DispatchInputs.ps1` 產生資源派遣（唯讀）的輸入，一次寫出 Request、`line.json`（不存在時）、prompt 與派遣單，並以 `Invoke-CodexDispatch.ps1 -Operation Dispatch -ValidateOnly` 自檢；自檢失敗時刪除本次建立的檔案，新建的 `line.json` 保留。
- `scripts/Invoke-CodexRun.ps1` 對一份派遣檔執行一次 `codex exec`，目前用於審查、事實校閱、影像產生、測試取證與顧問，啟動前比對帳號目錄的檔位設定檔與 repo 產生檔。帳號由 `machine.json` 登記清單選擇，讀取主 checkout 的 `.local/machine.json`，在線工作樹發動時相同。專案信任的處理見 `skills/codex-dispatch/references/run.md` 的「帳號」章節。
- `scripts/Test-CodexReviewReport.ps1` 檢查審查報告的 finding 清單，`valid` 為 `false` 時結束碼為 1。
- `scripts/Write-ClaudeRunRecord.ps1` 為 Claude 審查者（subagent）的一次審查在 `runs\` 寫出與 Codex 同位置的執行紀錄：`-Action Start` 保存派生前的來源狀態，`-Action End` 判定 `source_changed` 與報告檢查並補完紀錄；紀錄沒有 token 用量，`Get-LineCost.ps1` 標示後不計入合計。
- `scripts/Update-ExecutorIncomplete.ps1` 保存同一任務各執行者的未完成次數（`Add`、`Show`、`Reset`），並輸出可直接作為 `Select-DispatchExecutor.ps1 -Incomplete` 的值；選派入口不讀這個檔。
- `scripts/Get-CodexQuota.ps1` 查詢 Codex 額度，只供顯示與紀錄。
- `scripts/Invoke-WorkOverviewCleanup.ps1` 列出可清理的 worktree、分支與線層歷史備份，必須指定 `-Root`；預設只列出，以 `-ConfirmPlan` 帶入列出時的 planId 才刪除。
- `scripts/Get-ClaudeSessionUsage.ps1` 唯讀彙總主 session 與子代理 transcript 用量，依 `message.id` 去重，分別輸出主 session、子代理與總計三組。
- `scripts/Get-LineCost.ps1` 唯讀彙整一條線的成本並輸出 JSON：`runs\*.record.json`（含 Claude 審查者的紀錄，標示無 token 用量）與 `cost-ledger.md` 事件列的 Codex 執行次數、model、token、結果與耗時；Claude 用量只在以 `-ClaudeSessionId` 或 `-ClaudeTranscriptPath` 指定時重用 `Get-ClaudeSessionUsage.ps1` 計算，否則為 null 並附原因。
- `scripts/Setup-AIGlobalConfig.ps1` 建立各工具的 symlink 與 Git Hook 設定，見「安裝」與 §3。
- `scripts/Invoke-CodexDispatch.ps1` 是 Codex 資源派遣的入口，由 `codex-dispatch` skill 呼叫。
- `scripts/New-DispatchOrder.ps1` 依參數產生派遣單 Markdown 並驗證驗收命令。
- `scripts/New-CodexDispatchAccount.ps1` 建立派工帳號，見 §3。
- `scripts/Ensure-AiContextArtifacts.ps1` 依來源指紋決定是否重產 `.local/ai-context/` 的索引產物，並呼叫 `Export-ApiSurface.csx`、`Export-TypeHierarchy.csx` 與 `Export-ProjectGraph.csx`。
- `scripts/Export-CommentVocabularyCandidates.csx` 唯讀掃描 `.cs`，輸出資料庫註解語彙候選 JSON，由 `database-comment-generator` skill 使用。
- 內部責任檔、loader 與測試輔助放在子目錄，例如 `scripts/dispatch/` 與 `scripts/tests/`；派工測試入口位於 `scripts/tests/Test-DispatchRecoveryBinding.ps1`。
- `scripts/tests/Test-CodexRunAll.ps1` 執行 `Invoke-CodexRun.ps1` 的全部測試，不呼叫 Codex 服務端。`scripts/tests/Invoke-CodexRunLive.ps1 -Scenario review|failover` 以真實 Codex 驗證一筆審查與一筆換帳號，加上 `-DryRun` 只列出將執行的內容，不加 `-DryRun` 會呼叫 Codex 服務端並消耗額度。
- 派工測試只以 PowerShell 7（pwsh）執行，不再執行 Windows PowerShell 5.1。其他測試檔各自獨立執行，位於 `scripts/tests/`，其中包含 `Test-NewDispatchInputs.ps1`（輸入產生器）、`Test-PowerShellHostGuardHook.ps1`（`powershell.exe` 攔截 hook）、`Test-TurnGuardHook.ps1`、`Test-DocLocalPathCheck.ps1` 與 `Test-PostEditWriteHook.ps1`（其餘三個 hook）、`Test-SetupRequiresPwsh7.ps1`（Setup 的版本判斷）、`Test-SetupCheck.ps1`（Setup 的 `-Check` 唯讀檢查）與 `Test-DispatchStartHandleInheritance.ps1`（啟動時不繼承呼叫端的標準輸出入 handle）。
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

> 功能線：Analyst 收斂需求後由 Architect 設計，設計驗收通過後由主 Agent 依執行者登錄表派生 Claude subagent 進入實作，再以資源派遣發動 Codex 審查（Codex 不可用時由執行者登錄表選出的 Claude Sonnet subagent 承接）。判定為先做 Demo 時，Analyst 先派生 Prototyper 產出 Demo 畫面，驗收並回填需求摘要後再進入 Architect。Refactorer 由 Claude subagent 承接，處理程式碼技術債與語法現代化，每批修改後驗證測試。`architecture-improvement` 是人員明確觸發的 Skill，依 Git hotspot 與 deletion test 縮小候選範圍，先產出候選報告，確認範圍後才進入設計。bug 線：Maintainer 診斷後派生 Support Engineer 執行修正並驗收。

---

## 8. 疑難排解

### `model_reasoning_effort` 版本相容性

Codex 0.130 只接受 `model_reasoning_effort` 為 `none`、`minimal`、`low`、`medium`、`high` 或 `xhigh`。設定為 `max` 時，會在讀取 `config.toml` 階段整份載入失敗，任何子命令皆無法執行。Codex 0.147 已接受 `max`。

若對桌面版隨附 binary 執行 `codex update`，會回傳下列訊息：

```text
Could not detect the Codex installation method
```

請改用 npm 全域安裝的 Codex CLI，並以 `codex --version` 確認 PATH 解析到正確的執行檔。

## License

This project is licensed under the [MIT License](./LICENSE.md).
