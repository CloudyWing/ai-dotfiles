# 內建 Skill 清單

| Skill | 類型 | 用途 |
| --- | --- | --- |
| `api-smoke` | 知識型 | Web API 煙霧驗證流程。當需要在修改或開發 Web API 端點後驗證 API 行為，或使用者要求呼叫 Swagger、寫腳本測試 API、進行多情境 API 測試時使用。 |
| `browser-smoke` | 知識型 | 瀏覽器煙霧驗證流程。當需要在修改 Web UI、頁面、路由、表單、互動、樣式、響應式版面或前端狀態後使用瀏覽器驗證，或使用者明確要求檢查畫面、console/network error、互動行為與 UI 修正結果時使用。 |
| `check-markdown` | 知識型 | 當要求檢查 Markdown、修正格式或整理文件時使用。依據專案文件平台修正格式與排版問題。 |
| `context-map` | 知識型 | 當要求重構、移植、拆分、合併或介面變更時使用。建立相依關係圖與變更影響範圍分析，降低遺漏修改的風險。 |
| `create-license-and-readme-link` | 指令型 | 自動判斷專案屬性並推薦合適的開源授權，建立 LICENSE 檔案並將其連結補入 README.md 中。 |
| `csharp-aspnetcore` | 知識型 | ASP.NET Core 開發規範：DI Lifetime、HttpClient、回應格式與 API 版本控制。當偵測到 ASP.NET Core 專案或使用者要求撰寫 API 端點時自動套用。 |
| `csharp-async` | 知識型 | C# 非同步設計最佳實踐：強制套用 Task/ValueTask 與 ConfigureAwait 等非同步開發規範。 |
| `csharp-background-service` | 知識型 | Background Service 開發規範：BackgroundService、IHostedService、Channel Queue 模式與生命週期管理。 |
| `csharp-di` | 知識型 | .NET 相依性注入進階規範：Generic Host、Worker Service、Keyed Services 與 Decorator 模式。 |
| `csharp-docs` | 知識型 | C# 文件與 XML 註解標準：強制使用標準標籤與用詞規範產生類別與方法的說明。 |
| `csharp-error-handling` | 知識型 | C# 例外處理規範：例外設計原則、Guard Clause、全域錯誤處理與 ProblemDetails 回應標準化。 |
| `csharp-grpc` | 知識型 | gRPC 服務開發規範：Proto 檔案管理、服務實作、攔截器、錯誤處理與用戶端工廠模式。 |
| `csharp-linq` | 知識型 | LINQ 查詢規範：延遲執行、物化時機、查詢可讀性與效能陷阱迴避。當撰寫 In-Memory 集合操作或 LINQ to Objects 時自動套用。 |
| `csharp-mcp-server` | 知識型 | 產生或撰寫 C# MCP (Model Context Protocol) 伺服器時的最佳實踐與專案結構規劃。 |
| `csharp-nrt` | 知識型 | C# Nullable Reference Types 規範：依類別用途選擇正確的屬性宣告策略，禁止用假預設值消除警告。 |
| `csharp-nunit` | 知識型 | C# NUnit 測試規範：確保單元測試套用 AAA 模式、TestCase 資料驅動與合適的斷言 (Assertions)。 |
| `csharp-signalr` | 知識型 | SignalR Hub 開發規範：Hub Lifetime、群組管理、認證整合、錯誤處理與 Scale-Out 策略。 |
| `csharp-validation` | 知識型 | C# 輸入驗證規範：DataAnnotations、FluentValidation 選型、驗證層級劃分與 ASP.NET Core 整合策略。 |
| `desktop-smoke` | 知識型 | Windows 桌面應用煙霧驗證流程。當需要在修改 WinForm 或 WPF 應用後驗證行為，或使用者要求測試桌面程式、檢查視窗程式的互動與畫面時使用。 |
| `docker` | 知識型 | Dockerfile 與 Docker Compose 最佳實踐：多階段建置、非 root 執行、層快取最佳化與 Compose Specification 規範。 |
| `ef-core` | 知識型 | Entity Framework Core 開發規範：DbContext Lifetime、查詢效能、Migration 管理與變更追蹤最佳實踐。 |
| `export-excel` | 知識型 | 匯出 Excel 試算表的技能，支援 Grid 與 RecordSet 模板，並可自訂樣式與格式。 |
| `fact-check-note` | 知識型 | 事實校閱助手：逐條檢查技術內容的觀念、術語與 API 版本正確性，並標註無法確認的資訊。Use when the user asks to verify, fact-check, or audit the accuracy of technical documentation or notes. |
| `fix-file-encoding` | 指令型 | 偵測並修正檔案亂碼問題，依副檔名轉換至正確目標編碼（Big5/ANSI → UTF-8 系列）。 |
| `generate-api-doc` | 指令型 | 為 ASP.NET Core Controller 或 Minimal API 自動補齊 XML 文件與 Swagger Attributes，讓 OpenAPI 文件完整呈現。 |
| `generate-changelog-zh-tw` | 指令型 | 依據 Git 提交紀錄自動產生 CHANGELOG 區段（繁體中文），並支援 MinVer 版本號推進規格。 |
| `generate-commit` | 知識型 | 依據 Git Diff 產生符合規範的 Commit 訊息，含過渡檔案過濾與拆分建議。 |
| `generate-editorconfig-by-techstack` | 指令型 | 自動偵測專案的技術棧與主流工具，產生或補齊 .editorconfig 設定，保留既有自訂偏好。 |
| `generate-gitignore-by-techstack` | 指令型 | 從 github/gitignore 下載對應技術棧的 .gitignore 範本，合併並針對當前專案調整。 |
| `generate-readme-zh-tw` | 指令型 | 自動分析目前專案結構與功能，產生一份結構清晰、工程導向的 README.md（繁體中文）。 |
| `generate-unit-test` | 指令型 | 針對指定的 C# 類別或方法，自動產生 NUnit 單元測試骨架，包含 Arrange/Act/Assert 結構與 NSubstitute Mock 設定。 |
| `git-workflow` | 知識型 | Git 分支策略與協作規範：分支命名、PR 流程、Merge 策略與版本標籤管理。 |
| `integration-verify` | 知識型 | 開發完成後的整合驗證入口。當使用者要求在功能開發完成後自行驗證、做整合測試，或說「幫我驗證」「驗證一下功能」但未指定驗證方式時使用。判斷專案類型後先執行既有單元測試，再路由到對應的煙霧驗證流程。 |
| `merge-data` | 知識型 | 多份資料檔整合流程。當需要將兩份以上的資料檔（如 JSON、CSV）合併、補齊闕漏欄位或去重成單一檔案時使用。以 dry-run、筆數核對與抽樣比對降低整合錯誤。 |
| `openapi-client` | 知識型 | 前後端 API 契約規範：OpenAPI Client 產生策略、Axios 封裝、型別同步與錯誤處理。 |
| `pinia` | 知識型 | Pinia 狀態管理規範：Store 設計、Setup Store 寫法、跨 Store 互動、持久化策略與元件整合。 |
| `requirement-context` | 知識型 | 當使用者明確要求盤點需求上下文，或要求從專案文件、程式碼與資料庫查找需求相關背景資訊時使用。 |
| `spec-doc` | 指令型 | 將 Clarify 整理的需求摘要轉化為人類可讀的開發需求規格文件，供同事參考討論。 |
| `sql-query` | 知識型 | T-SQL 查詢撰寫規範：參數化查詢、索引友善寫法、效能陷阱迴避與可讀性格式要求。適用於 SQL Server 與 Oracle 雙資料庫。 |
| `survey` | 知識型 | 掃描專案結構並產出完整技術文件索引，供團隊成員與 AI 快速理解專案全貌。 |
| `typescript-frontend` | 知識型 | 前端 TypeScript 規範：strict 模式、型別設計、泛型使用、型別窄化與 Vue 3 整合。當偵測到前端 TypeScript 專案時自動套用。 |
| `vitest` | 知識型 | 前端測試規範：Vitest 設定、Vue 元件測試、Composable 測試、Mock 策略與測試結構。 |
| `vue3` | 知識型 | Vue 3 開發規範：Composition API、<script setup>、Composable 設計、元件結構與 Vite 建置設定。當偵測到 Vue 3 專案時自動套用。 |
| `vue-router` | 知識型 | Vue Router 4 開發規範：路由設計、Navigation Guard、動態載入、Meta 型別安全與權限控制。 |
