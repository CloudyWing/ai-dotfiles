---
name: csharp-integration-test
description: 'C# 整合測試規範：WebApplicationFactory、Testcontainers、資料隔離與認證繞道。當撰寫或修改整合測試（跨資料庫、HTTP 管線、外部相依）時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# C# 整合測試規範

單元測試規範參閱 `csharp-nunit` skill；測試框架同樣使用 NUnit。

## 專案結構與命名

- 整合測試獨立成 `[ProjectName].IntegrationTests` 專案，不與單元測試混在同一專案（相依與執行時間特性不同，需可分開執行）。
- 測試類別與命名規則沿用 `csharp-nunit` skill（`[UnitOfWork]_[StateUnderTest]_[ExpectedBehavior]`）。
- 所有整合測試標註 `[Category("Integration")]`，CI 中與單元測試分 stage 執行。

## Web API 測試（WebApplicationFactory）

- 以自訂 Factory 繼承 `WebApplicationFactory<Program>` 集中覆寫設定，測試類別共用，不在個別測試中臨時覆寫：

```csharp
public class ApiTestFactory : WebApplicationFactory<Program> {
    protected override void ConfigureWebHost(IWebHostBuilder builder) {
        builder.UseEnvironment("IntegrationTest");
        builder.ConfigureServices(services => {
            // 以 Testcontainers 連線字串替換正式 DbContext 註冊
        });
    }
}
```

- `Program` 需可被測試專案存取：Minimal API 專案在 `Program.cs` 結尾補 `public partial class Program { }`。
- 環境名稱固定使用 `IntegrationTest`，對應的 `appsettings.IntegrationTest.json` 只放測試專用覆寫，不複製整份設定。

## 外部相依的替身策略（Crucial）

| 相依 | 策略 |
| --- | --- |
| 資料庫（SQL Server / Oracle） | Testcontainers 起真實容器，禁止以 InMemory Provider 代替（行為差異大，查詢語意不可信） |
| Redis / RabbitMQ | Testcontainers 起真實容器 |
| 第三方 HTTP 服務 | WireMock.Net 等 HTTP stub，不直接打真實外部服務 |
| 自家程式碼 | 不 Mock。整合測試的目的就是驗證真實組裝，內部服務一律走真實實作 |

- 容器以 fixture 層級共用：`[OneTimeSetUp]` 啟動、`[OneTimeTearDown]` 釋放，不在每個測試方法重啟容器。
- 依全域 §1.4 背景進程清理：測試結束容器必須釋放，優先使用 Testcontainers 的自動清理（Ryuk / `DisposeAsync`）。

## 資料隔離（Crucial）

- 每個測試自行建立所需資料，**禁止**依賴其他測試留下的資料或共用種子資料的隱含狀態。
- 測試間清理採 Respawn（依外鍵順序清表）或每 fixture 重建 schema，不逐測試手寫 DELETE。
- 測試資料的識別值避免寫死常見值（如 ID = 1），使用工廠方法產生，降低互相污染的機率。
- 涉及資料庫的測試類別停用平行執行（`[NonParallelizable]`），或以資料庫 / schema 隔離後才開放平行。

## 認證繞道

- 需要通過 `[Authorize]` 的測試，註冊測試專用 `AuthenticationHandler` 發出假 `ClaimsPrincipal`，claims 結構（`sub` 等）比照 `csharp-auth` skill 的慣例。
- **禁止**為了測試在正式程式碼加開關關閉認證；繞道只存在於測試專案的 Factory 設定中。

## 斷言重點

- 驗證行為以「可觀察結果」為準：HTTP 狀態碼與回應體、資料庫實際狀態、佇列中的訊息，不斷言內部呼叫次數（那是單元測試搭配 Mock 的手段）。
- 回應體反序列化為型別後斷言欄位，不對 JSON 字串做子字串比對。
