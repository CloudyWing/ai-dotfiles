---
name: docker
description: 'Dockerfile 與容器化最佳實踐：多階段建置、非 root 執行、層快取最佳化與安全性規範。'
---

# Docker 容器化規範

當使用者要求撰寫或檢視 Dockerfile、Compose 檔案或容器化部署設定時，請自動套用以下規範。

## Dockerfile 多階段建置（Crucial）

- .NET 專案的 Dockerfile **必須**使用多階段建置（Multi-stage Build），分離建置環境與執行環境，縮小最終映像檔大小。
- 建置階段使用 `sdk` 映像檔，執行階段使用 `aspnet` 或 `runtime` 映像檔。

```dockerfile
# ✅ 正確：多階段建置
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY ["MyApp/MyApp.csproj", "MyApp/"]
RUN dotnet restore "MyApp/MyApp.csproj"
COPY . .
RUN dotnet publish "MyApp/MyApp.csproj" -c Release -o /app/publish

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final
WORKDIR /app
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "MyApp.dll"]
```

## 層快取最佳化（Crucial）

- **先複製專案檔，再 restore，最後複製原始碼**：`COPY *.csproj` → `RUN dotnet restore` → `COPY .`。確保相依性套件未變動時，restore 層可被快取。
- 變動頻率低的指令放在 Dockerfile 前段，變動頻率高的放後段。
- 禁止在單一 `RUN` 指令中混合安裝套件與複製程式碼。

## .dockerignore

- Dockerfile 所在目錄必須包含 `.dockerignore`，排除不需進入建置上下文的檔案：

```text
**/.git
**/bin
**/obj
**/node_modules
**/.vs
**/.idea
**/Thumbs.db
**/*.user
**/*.suo
```

## 非 root 執行（Crucial）

- 最終執行階段**禁止**以 root 使用者執行容器程序。
- 使用 `USER` 指令切換至非特權使用者：

```dockerfile
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final
RUN adduser --disabled-password --no-create-home appuser
WORKDIR /app
COPY --from=build /app/publish .
USER appuser
ENTRYPOINT ["dotnet", "MyApp.dll"]
```

## 健康檢查

- 正式環境的 Dockerfile 應包含 `HEALTHCHECK` 指令：

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1
```

## 環境變數與機密

- **禁止**在 Dockerfile 中硬編碼機密（密碼、連線字串、Token）。
- 機密透過執行期環境變數、Docker Secrets 或外部密鑰管理服務注入。
- `ENV` 僅用於非敏感的執行期設定（如 `ASPNETCORE_ENVIRONMENT`、`DOTNET_RUNNING_IN_CONTAINER`）。

## 映像檔標籤

- 禁止在正式環境使用 `latest` 標籤，必須指定明確版本號（如 `8.0`、`8.0-alpine`）。
- 若追求最小映像檔大小，優先考慮 Alpine 變體（如 `aspnet:8.0-alpine`），但需注意 globalization 相關的相容性問題。

## Compose 整合

- Compose 檔案規範參閱全域規範的 Docker Compose 章節。
- Service 間的相依關係使用 `depends_on` 搭配 `condition: service_healthy`。
- 開發環境使用 `compose.override.yml` 覆寫正式環境設定（如掛載原始碼 Volume、開啟偵錯埠）。
