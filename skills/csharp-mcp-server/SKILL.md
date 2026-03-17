---
name: csharp-mcp-server
description: '產生或撰寫 C# MCP (Model Context Protocol) 伺服器時的最佳實踐與專案結構規劃。'
---

# C# MCP Server 建立與實作指南

當使用者需要建立擴充 AI 能力的 MCP (Model Context Protocol) 伺服器，且語言選定為 C# (通常為 .NET 10.0 以上) 時，請遵循此指南。

## 專案核心要求

- **專案結構**：依部署模式選擇：
  - **STDIO 模式**（本機整合）：建立標準 Console 應用程式 (`dotnet new console`)，使用 `Microsoft.Extensions.Hosting` 管理生命週期。
  - **Streamable HTTP 模式**（Container/Server 部署）：建立 Web 應用程式 (`dotnet new web`)，以 `WebApplicationBuilder` 啟動，通常搭配 Docker 使用。端點預設為 `/mcp`。
- **套件相依性**：必須包含支援的 MCP SDK（例如官方或社群的 `ModelContextProtocol` 預覽套件）；Streamable HTTP 模式需要 `ModelContextProtocol.AspNetCore`。
- **Log 管控**（僅 STDIO 模式）：為避免干擾 `stdio` 用來傳輸 JSON-RPC，必須將所有 Logging (如 ILogger) 導向 `stderr`，或是寫入實體檔案之中。Streamable HTTP 模式使用獨立 HTTP channel，無此限制。

## 工具實作 (Tools Implementation)

這是在 C# 中向 AI 暴露方法的環節：

- 針對被暴露為 Tool 的類別，**XML 文件註解應放在最前面，`[McpServerToolType]` 屬性緊接其後**：
```csharp
  /// <summary>
  /// Provides MCP tools for ...
  /// </summary>
  [McpServerToolType]
  public sealed class FooTools { ... }
```
- 每個工具方法應標註 `[McpServerTool]`，並務必加上 `[Description("...")]` 在方法與參數上。
  > **請注意**：參數的 `Description` 將直接影響 LLM 決定何時呼叫此工具，描述越精準、型別宣告越清楚越好。

## 初始化與執行

**STDIO 模式**：
```csharp
Host.CreateApplicationBuilder(args)
    .AddMcpServer().WithStdioServerTransport().WithTools<FooTools>()
    ...
    .RunAsync();
```

**Streamable HTTP 模式**（Docker / Container 部署）：
```csharp
string port = Environment.GetEnvironmentVariable("PORT") ?? "8080";
WebApplicationBuilder builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls($"http://0.0.0.0:{port}");
builder.Services.AddSingleton<SomeDependency>();
builder.Services
    .AddMcpServer(o => o.ServerInfo = new() { Name = "mcp-name", Version = "1.0.0" })
    .WithHttpTransport()
    .WithTools<FooTools>();
WebApplication app = builder.Build();
app.MapMcp("/mcp");   // 端點固定為 /mcp
await app.RunAsync();
```

## 防錯機制

- 定義工具參數時，應盡量支援字串轉強型別 (例如枚舉或原生型態)，內部要有 `try-catch` 防止單次工具呼叫失敗造成整個 MCP server 崩潰。