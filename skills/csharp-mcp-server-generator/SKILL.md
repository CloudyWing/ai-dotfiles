---
name: csharp-mcp-server-generator
description: '產生或撰寫 C# MCP (Model Context Protocol) 伺服器時的最佳實踐與專案結構規劃。'
---

# C# MCP Server 建立與實作指南

當使用者需要建立擴充 AI 能力的 MCP (Model Context Protocol) 伺服器，且語言選定為 C# (通常為 .NET 8.0 以上) 時，請遵循此指南。

## 專案核心要求

- **專案結構**：建立標準的 Console 應用程式 (`dotnet new console`)。
- **套件相依性**：必須包含支援星期的 MCP SDK (例如官方或社群的 `ModelContextProtocol` 預覽套件)，以及 `Microsoft.Extensions.Hosting` (DI 容器與生命週期管理)。
- **Log 管控**：為避免干擾 `stdio` 用來傳輸 JSON-RPC，必須將所有的 Logging (如 ILogger) 導向 `stderr`，或是寫入實體檔案之中。

## 工具實作 (Tools Implementation)

這是在 C# 中向 AI 暴露方法的環節：

- 針對被暴露為 Tool 的類別檔案，請標註對應的屬性標籤 (例如 `[McpServerToolType]`)。
- 每個工具方法應標註 `[McpServerTool]`，並務必加上 `[Description("...")]` 在方法與參數上。
  > **請注意**：參數的 `Description` 將直接影響 LLM 決定何時呼叫此工具，描述越精準、型別宣告越清楚越好。

## 初始化與執行

- 透過 `Host.CreateApplicationBuilder()` 註冊依賴服務。
- 設定 STDIO Server transport 進行本機端溝通 (VS Code / Claude Desktop 常見用法)。
- 確保透過 `RunAsync()` 讓 Console App 維持啟動狀態。

## 防錯機制

- 定義工具參數時，應盡量支援字串轉強型別 (例如枚舉或原生型態)，內部要有 `try-catch` 防止單次工具呼叫失敗造成整個 MCP server 崩潰。
