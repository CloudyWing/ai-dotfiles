# 內建 Skill 清單

## user-invoked

| Skill | 類型 | 讀者 | 用途 |
| --- | --- | --- | --- |
| `adr` | 指令型 | human | 依決策門檻建立追加式 Architecture Decision Record，管理序號、狀態與被推翻的決策。 |
| `architecture-improvement` | 指令型 | human | 以 Git hotspot 縮小分析範圍，使用 deletion test 篩選改善候選並產出架構改善報告。 |
| `create-license-and-readme-link` | 指令型 | human | 自動判斷專案屬性並推薦合適的開源授權，建立 LICENSE 檔案並將其連結補入 README.md 中。 |
| `fix-file-encoding` | 指令型 | human | 偵測並修正檔案亂碼問題，依副檔名轉換至正確目標編碼（Big5/ANSI → UTF-8 系列）。 |
| `generate-api-doc` | 指令型 | human | 為 ASP.NET Core Controller 或 Minimal API 自動補齊 XML 文件與 Swagger Attributes，讓 OpenAPI 文件完整呈現。 |
| `generate-changelog-zh-tw` | 指令型 | human | 依據 Git 提交紀錄自動產生 CHANGELOG 區段（繁體中文），並支援 MinVer 版本號推進規格。 |
| `generate-editorconfig-by-techstack` | 指令型 | human | 依專案技術棧與 .NET 框架版本，從範本過濾出對應的 .editorconfig 段落並補齊，保留既有自訂偏好。 |
| `generate-frontend-lint-config` | 指令型 | human | 產生或補齊前端 Lint 設定（Prettier + ESLint Flat Config），統一格式化與程式碼品質規則，保留既有自訂偏好。 |
| `generate-gitattributes` | 指令型 | human | 產生或補齊 .gitattributes，統一行尾處理、二進位識別與 lock files 標記，保留既有自訂偏好。 |
| `generate-gitignore-by-techstack` | 指令型 | human | 從 github/gitignore 下載對應技術棧的 .gitignore 範本，合併並針對當前專案調整。 |
| `generate-readme-zh-tw` | 指令型 | human | 自動分析目前專案結構與功能，產生一份結構清晰、工程導向的 README.md（繁體中文）。 |
| `generate-unit-test` | 指令型 | human | 針對指定的 C# 類別或方法，自動產生 NUnit 單元測試骨架，包含 Arrange/Act/Assert 結構與 NSubstitute Mock 設定。 |
| `project-setup` | 指令型 | human | 探索專案的 solo／team 模式與既有規範產物，建立 AGENTS.md、CLAUDE.md、GLOSSARY.md、docs/adr/ 與 AI 宣告區塊。 |
| `spec-doc` | 指令型 | human | 依 Clarify 需求摘要、design.md 或使用者口述範圍與程式碼盤點，產生人類可讀的開發需求規格文件，供同事參考討論。 |

## model-invoked

| Skill | 類型 | 讀者 | 用途 |
| --- | --- | --- | --- |
| `ai-context-index` | 知識型 | agent | 依 AGENTS.md 宣告探索技術棧與既有產物，呼叫宣告工具產生 AI 脈絡索引並寫入 .local/ai-context/。 |
| `api-smoke` | 知識型 | agent | Web API 煙霧驗證流程。當需要在修改或開發 Web API 端點後驗證 API 行為，或使用者要求呼叫 Swagger、寫腳本測試 API、進行多情境 API 測試時使用。 |
| `apply-fact-check` | 知識型 | human | 依據事實校閱報告修改技術文件：以事實層為不可違反的約束，由改檔者負責表達層的措辭與行文連貫。Use when the user asks to apply fact-check results to a document, or to edit a document based on a previously produced fact-check-report.md. |
| `browser-smoke` | 知識型 | agent | 瀏覽器煙霧驗證流程。當需要在修改 Web UI、頁面、路由、表單、互動、樣式、響應式版面或前端狀態後使用瀏覽器驗證，或使用者明確要求檢查畫面、console/network error、互動行為與 UI 修正結果時使用。 |
| `check-markdown` | 知識型 | human | 當要求檢查 Markdown、修正格式或整理文件時使用。依據專案文件平台修正格式與排版問題。 |
| `codebase-design` | 知識型 | agent | Use when 設計或審查模組邊界、Interface、Adapter、依賴方向與可測試性時。 |
| `codex-dispatch` | 知識型 | agent | Codex 派工機制：依派工類型建立執行契約、以 app-server 啟動 Codex、背景等待、取證並回收結果。當需要發動 codex、撰寫派遣單或執行派遣回收判定時使用。 |
| `csharp-aspnetcore` | 知識型 | agent | ASP.NET Core 開發規範：DI Lifetime、HttpClient、回應格式與 API 版本控制。當偵測到 ASP.NET Core 專案或使用者要求撰寫 API 端點時自動套用。 |
| `csharp-auth` | 知識型 | agent | ASP.NET Core 認證授權規範：JWT Bearer 驗證參數、OIDC 整合、Claims 慣例與 Policy 授權。當撰寫或修改認證、授權、Token 驗證相關程式碼時自動套用。 |
| `csharp-background-service` | 知識型 | agent | Background Service 開發規範：BackgroundService、IHostedService、Channel Queue 模式與生命週期管理。當撰寫或審查 .NET 背景工作、排程任務或佇列處理邏輯時自動套用。 |
| `csharp-comments` | 知識型 | agent | C# 註解風格：單行註解格式、註解用途原則，以及 TODO / UNDONE / HACK 工作清單關鍵字的分類與使用時機。撰寫或檢視 C# 程式碼註解時套用。 |
| `csharp-di` | 知識型 | agent | .NET 相依性注入進階規範：Generic Host、Keyed Services、Decorator 模式與容器驗證。當撰寫涉及 DI 容器進階配置（多實作、裝飾、非 Web 宿主）的程式碼時自動套用。 |
| `csharp-docs` | 知識型 | agent | C# 文件與 XML 註解標準：強制使用標準標籤與用詞規範產生類別與方法的說明。Use when writing, reviewing, or generating XML documentation comments (///) in C# files, or when the user asks to add, fix, or supplement XML docs. |
| `csharp-error-handling` | 知識型 | agent | C# 例外處理規範：例外設計原則、Guard Clause、全域錯誤處理與 ProblemDetails 回應標準化。當設計例外、撰寫 try-catch 或全域錯誤處理時自動套用。 |
| `csharp-grpc` | 知識型 | agent | gRPC 服務開發規範：Proto 檔案管理、服務實作、攔截器、錯誤處理與用戶端工廠模式。當偵測到 gRPC 專案或撰寫 .proto、gRPC 服務與用戶端時自動套用。 |
| `csharp-integration-test` | 知識型 | agent | C# 整合測試規範：WebApplicationFactory、Testcontainers、資料隔離與認證繞道。當撰寫或修改整合測試（跨資料庫、HTTP 管線、外部相依）時自動套用。 |
| `csharp-language-features` | 知識型 | agent | Use when 讀取或修改 C# 專案設定、TargetFramework 或 C# 程式碼，需判斷語言特性、非同步與型別選用時。 |
| `csharp-linq` | 知識型 | agent | LINQ 查詢規範：物化時機、回傳型別、語法選用與鏈式排版的專案慣例。當撰寫 In-Memory 集合操作或 LINQ to Objects 時自動套用。 |
| `csharp-mcp-server` | 知識型 | agent | 產生或撰寫 C# MCP (Model Context Protocol) 伺服器時的最佳實踐與專案結構規劃。 |
| `csharp-nrt` | 知識型 | agent | C# Nullable Reference Types 規範：依類別用途選擇正確的屬性宣告策略，禁止用假預設值消除警告。當專案啟用 NRT 且撰寫或修改型別宣告時自動套用。 |
| `csharp-nunit` | 知識型 | agent | C# NUnit 測試規範：確保單元測試套用 AAA 模式、TestCase 資料驅動與合適的斷言 (Assertions)。當撰寫或修改 C# 單元測試時自動套用。 |
| `csharp-signalr` | 知識型 | agent | SignalR Hub 開發規範：Hub Lifetime、群組管理、認證整合、錯誤處理與 Scale-Out 策略。當撰寫或修改 SignalR Hub 與即時推播功能時自動套用。 |
| `csharp-silent-defects` | 知識型 | agent | Use when 讀取或修改 C# 程式碼，需要檢查合法且不易在開發環境顯現的執行期、時序、文化、數值、集合順序或資源陷阱時。 |
| `csharp-style` | 知識型 | agent | C# 程式碼風格規範：縮寫大小寫、泛型型別參數、成員排序、空行、換行、三元運算子等 .editorconfig 無法約束的細則。建立全新 C# 專案，或在無既有慣例的專案新增全新檔案時套用。 |
| `csharp-validation` | 知識型 | agent | C# 輸入驗證規範：DataAnnotations、FluentValidation 選型、驗證層級劃分與 ASP.NET Core 整合策略。當撰寫 Request 驗證或設計輸入檢核時自動套用。 |
| `desktop-smoke` | 知識型 | agent | Windows 桌面應用煙霧驗證流程。當需要在修改 WinForm 或 WPF 應用後驗證行為，或使用者要求測試桌面程式、檢查視窗程式的互動與畫面時使用。 |
| `doc-editing` | 知識型 | agent | Use when 修改技術筆記、規格文件或 Markdown 文件，需要保留內容、查閱事實與維持文件結構時。 |
| `docker` | 知識型 | agent | Dockerfile 與 Docker Compose 專案慣例：.NET 多階段建置的快取層寫法、非 root 執行、Compose Specification 檔名與相依寫法。當撰寫或檢視 Dockerfile 與 Compose 設定時自動套用。 |
| `ef-core` | 知識型 | agent | Entity Framework Core 開發規範：DbContext Lifetime、查詢效能、Migration 管理與變更追蹤最佳實踐。當偵測到 EF Core 相依，或撰寫 DbContext、資料庫查詢與 Migration 時自動套用。 |
| `export-excel` | 知識型 | human | 匯出 Excel 試算表的技能，主要支援 Grid 與 RecordSet 兩種模板，可自訂樣式、命名樣式、資料驗證與工作表保護。當要求匯出或產生 Excel 檔案時使用。 |
| `fact-check-note` | 知識型 | human | 技術內容事實校閱：逐條檢查技術文件的觀念、術語與 API 版本正確性，產出附官方依據的校閱報告，作為改檔流程的輸入。Use when the user asks to verify, fact-check, or audit the accuracy of technical documentation or notes. |
| `generate-commit` | 知識型 | human | 依據 Git Diff 產生符合規範的 Commit 訊息，含過渡檔案過濾與拆分建議。當使用者要求提交變更或產生 commit 訊息時使用。 |
| `git-workflow` | 知識型 | agent | Git 分支策略與協作規範：分支命名、PR 模板、Merge 策略選用與 Git Hooks 慣例。當討論分支管理、PR 流程或版本發布時自動套用。 |
| `glossary` | 知識型 | human | 維護專案專屬業務術語表，處理使用者用詞衝突、程式碼語意矛盾與即時寫入。Use when 專案已宣告詞彙表，且當前對話或程式碼使用了表中既有術語但語意與定義不符時。 |
| `integration-verify` | 知識型 | agent | 開發完成後的整合驗證入口。當使用者要求在功能開發完成後自行驗證、做整合測試，或說「幫我驗證」「驗證一下功能」但未指定驗證方式時使用。判斷專案類型後先執行既有單元測試，再路由到對應的煙霧驗證流程。 |
| `merge-data` | 知識型 | human | 多份資料檔整合流程。當需要將兩份以上的資料檔（如 JSON、CSV）合併、補齊闕漏欄位或去重成單一檔案時使用。以 dry-run、筆數核對與抽樣比對降低整合錯誤。 |
| `messaging` | 知識型 | agent | 訊息佇列開發規範：RabbitMQ 與 MQTT 的命名慣例、冪等消費、重試與 DLQ 策略、訊息版本演進。當撰寫或修改訊息發佈與消費邏輯時自動套用。 |
| `openapi-client` | 知識型 | agent | 前後端 API 契約規範：OpenAPI Client 產生策略、Axios 封裝、型別同步與錯誤處理。當撰寫前端 API 呼叫層或同步前後端型別時自動套用。 |
| `pinia` | 知識型 | agent | Pinia 狀態管理規範：Store 設計、Setup Store 寫法、跨 Store 互動、持久化策略與元件整合。當撰寫或修改 Pinia Store 及其元件整合時自動套用。 |
| `powershell` | 知識型 | agent | PowerShell 腳本撰寫規範：嚴格模式、錯誤處理、參數宣告、Verb-Noun 命名與 5.1 相容語法邊界。當撰寫或修改 `*.ps1` / `*.psm1` 腳本時自動套用。 |
| `redis-caching` | 知識型 | agent | Redis 快取開發規範：Key 命名階層、TTL 策略、Cache-Aside 模式與 StackExchange.Redis 連線管理。當撰寫或修改快取邏輯時自動套用。 |
| `requirement-context` | 知識型 | agent | 當使用者明確要求盤點需求上下文，或要求從專案文件、程式碼與資料庫查找需求相關背景資訊時使用。 |
| `scripting-conventions` | 知識型 | agent | Use when 選擇或撰寫 PowerShell、Shell 或 C# Script，需判斷執行平台、編碼與相依工具時。 |
| `sql-query` | 知識型 | agent | SQL 撰寫規範：參數化查詢、索引友善寫法、效能陷阱迴避與可讀性格式要求，涵蓋 SQL Server（T-SQL）與 Oracle 雙資料庫的語法差異與語意陷阱。當撰寫或審查原生 SQL 時自動套用。 |
| `survey` | 知識型 | human | 掃描專案結構並產出供團隊成員閱讀的技術文件索引。當要求掃描專案、建立文件索引、補齊技術文件或盤點專案結構時使用。 |
| `typescript-frontend` | 知識型 | agent | 前端 TypeScript 規範：strict 模式、型別設計、泛型使用、型別窄化與 Vue 3 整合。當偵測到前端 TypeScript 專案時自動套用。 |
| `uiux` | 知識型 | agent | UI/UX 決策規範，含版面資訊層級、改動邊界與不可自由裁量清單、決策攤開格式、互動狀態與響應式版面。當新增或改動畫面版面、頁面配置、表單或列表排版、儀表板、元件擺放位置、響應式行為、互動狀態呈現時自動套用；使用者說「優化版面」「調整畫面」「這頁太亂」「幫我做個畫面」時亦適用。 |
| `uiux-baseline` | 知識型 | agent | 掃描專案產出樣式基準，抽取色彩、間距、字級、圓角的實際使用值與可整段複用的具名版型模式，並區分已統一慣例與專案內部不一致項。Use when the user asks to build a UI style baseline, inventory a project's existing visual conventions, or when a Demo or layout plan needs a visual reference before being produced. |
| `vitest` | 知識型 | agent | 前端測試規範：Vitest 設定、Vue 元件測試、Composable 測試、Mock 策略與測試結構。當撰寫或修改前端測試時自動套用。 |
| `vue-router` | 知識型 | agent | Vue Router 4 開發規範：路由設計、Navigation Guard、動態載入、Meta 型別安全與權限控制。當撰寫或修改路由設定與 Navigation Guard 時自動套用。 |
| `vue3` | 知識型 | agent | Vue 3 開發規範：Composition API、<script setup>、Composable 設計、元件結構與 Vite 建置設定。當偵測到 Vue 3 專案時自動套用。 |
| `windows-terminal` | 知識型 | agent | Use when 在 Windows 執行終端機命令，需要處理輸出編碼、中文亂碼或輸出截斷時。 |
| `writing-for-agents` | 知識型 | agent | Use when 撰寫或修改全域 Agent 規範、Skill 文件或交接文件，需要控制資訊密度與驗收條件時。 |
