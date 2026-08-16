---
name: docker
description: 'Dockerfile 與 Docker Compose 專案慣例：.NET 多階段建置的快取層寫法、非 root 執行、Compose Specification 檔名與相依寫法。當撰寫或檢視 Dockerfile 與 Compose 設定時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Docker 容器化規範

多階段建置、HEALTHCHECK、機密注入等通用實踐不在此複述（機密規範見全域 §2 Security Baseline），本文件只收專案慣例與易錯點。

## Dockerfile（.NET 專案）

- **必須**使用多階段建置。建置階段使用 `sdk` 映像檔，執行階段使用 `aspnet` 或 `runtime` 映像檔，build stage 與 final stage **必須使用相同的 .NET 版本號**。
- **層快取（Crucial）**：逐一 COPY 每個 `.csproj`（含 `.sln`），先 `dotnet restore`，最後才 `COPY . .`。**不可使用 `COPY *.csproj` 通配符**，該語法無法匹配子目錄下的專案檔，會造成 restore 快取層失效或建置失敗。

```dockerfile
COPY ["MySolution.sln", "."]
COPY ["MyApp/MyApp.csproj", "MyApp/"]
COPY ["MyLibrary/MyLibrary.csproj", "MyLibrary/"]
RUN dotnet restore "MyApp/MyApp.csproj"
COPY . .
```

- **ENTRYPOINT DLL 名稱**：DLL 預設與專案檔名相同。若 `.csproj` 有設定 `<AssemblyName>`，則以該值為準，撰寫前應先確認。
- **非 root 執行（Crucial）**：最終執行階段以 `USER` 指令切換至非特權使用者，禁止以 root 執行容器程序。
- Dockerfile 所在目錄必須有 `.dockerignore`，至少排除 `**/.git`、`**/bin`、`**/obj`、`**/node_modules`、IDE 個人設定檔。
- 禁止在正式環境使用 `latest` 標籤，必須指定明確版本號。Alpine 變體需注意 globalization 相容性問題。

## Compose 整合

- 遵守 Compose Specification (V2+) 規範，**不加入已廢棄的頂層 `version:` 欄位**。
- 新建檔案優先使用 `compose.yml` 為主要檔名（相容舊稱 `docker-compose.yml`，但不主動建立）。
- Service 間的相依關係使用 `depends_on` 搭配 `condition: service_healthy`，取代舊式純陣列寫法。
- 開發環境使用 `compose.override.yml` 覆寫正式環境設定（如掛載原始碼 Volume、開啟偵錯埠）。
