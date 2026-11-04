---
name: csharp-integration-test
description: 'C# 整合測試規範：WebApplicationFactory、Testcontainers、依 AI-PROFILE 目標版本鍵選用資料庫容器映像與相容性層級、資料隔離與認證繞道。當撰寫或修改整合測試（跨資料庫、HTTP 管線、外部相依）時自動套用。'
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
| 資料庫（SQL Server / Oracle） | Testcontainers 起真實容器，映像與相容性層級依「資料庫容器目標版本」選定；禁止以 InMemory Provider 代替（行為差異大，查詢語意不可信） |
| Redis / RabbitMQ | Testcontainers 起真實容器 |
| 第三方 HTTP 服務 | WireMock.Net 等 HTTP stub，不直接打真實外部服務 |
| 自家程式碼 | 不 Mock。整合測試的目的就是驗證真實組裝，內部服務一律走真實實作 |

- 容器以 fixture 層級共用：`[OneTimeSetUp]` 啟動、`[OneTimeTearDown]` 釋放，不在每個測試方法重啟容器。
- 依全域 §1.4 背景進程清理：測試結束容器必須釋放，優先使用 Testcontainers 的自動清理（Ryuk / `DisposeAsync`）。

## 資料庫容器目標版本

撰寫或修改 SQL Server 或 Oracle 整合測試容器設定時，依專案 AI-PROFILE 的目標版本鍵選定映像，讓測試引擎與正式環境一致。映像對照與來源只記載在 `references/container-images.md`，本節不寫具體版本。

| Provider | 讀取的鍵 | 載入的檔案 |
| --- | --- | --- |
| SQL Server | `target.sqlserver`、`target.sqlserver.compat` | 本文件，加上 `references/container-images.md` |
| Oracle | `target.oracle` | 本文件，加上 `references/container-images.md` |

- 讀鍵：鍵的語意、合法值、適用偵測、詢問與非互動執行端處置依 `sql-query` SKILL.md「目標版本」，先載入 `sql-query` 再執行本節。鍵缺少時依該節「讀取與詢問」詢問，必答。
- 選映像：取參考檔對照表中「標示」與鍵值相同的列。該列有映像時使用該映像；該列標示無對應映像時，依該列指示改用其他列的映像。
- 註明落差：實際引擎版本與目標版本不同時，在啟動容器的 fixture 以註解寫出目標版本、實際引擎版本與「以相容性層級模擬」或「引擎較新」的落差說明，並在本輪回覆重述一次。
- 固定標籤：使用參考檔所列映像與標籤字首下的固定標籤，不使用 `latest` 或 `<主版本>-latest` 這類浮動標籤。
- SQL Server 相容性層級：每次建立或重建測試資料庫後執行 `ALTER DATABASE [<資料庫>] SET COMPATIBILITY_LEVEL = <n>`。`<n>` 為有效相容性層級，即 `target.sqlserver.compat` 的值，未填時取 `sql-query` 的 `references/sqlserver.md`「版本與相容性層級對照」中目標版本的預設相容性層級。`<n>` 不在實際引擎版本的「可設定相容性層級」內時，停止並回報目標版本、實際引擎版本與 `<n>`，不改用其他層級。
- Oracle 無免費映像：參考檔該列標示無免費映像時，先詢問使用者能否使用 Oracle Container Registry 企業版映像（需登入並接受授權條款）。使用者同意時改用企業版映像，使用者表示不能使用時，才依該列改用較新的最近免費映像並註明落差。非互動執行端無法詢問時，停止該 Oracle 容器的映像設定，在報告寫明目標版本、待確認的企業版映像可用性與參考檔該列的兩個選項，交由上游取得使用者答案；不依賴該容器設定的其他工作照常進行。
- Oracle 相容性：不調整 Oracle `COMPATIBLE` 初始化參數。
- 使用者略過：專案已有容器映像設定時保留不改。新建容器設定時使用參考檔對照表最後一列（最新版本）有映像的固定標籤，不設定 SQL Server 相容性層級，並在 fixture 註解與回覆註明「未確認目標版本」。
- 既有設定：既有映像或相容性層級與鍵推導的結果不同時，在回覆列出差異，不改寫既有設定。只有本輪本來就要修改容器設定時，才採用推導的結果。

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
