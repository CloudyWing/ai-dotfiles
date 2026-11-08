---
name: docker
description: 'Dockerfile 與 Docker Compose 專案慣例：.NET 多階段建置的快取層寫法、非 root 執行、.NET 映像缺少字型與 Nginx 官方映像的設定陷阱、Compose Specification 檔名與相依寫法。當撰寫或檢視 Dockerfile、Compose 設定或 Nginx 容器設定時自動套用。'
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

## 官方映像注意事項

### .NET 映像缺少字型

- `mcr.microsoft.com/dotnet/aspnet` 等映像的 Linux 標籤以精簡的發行版為基礎，沒有 `/usr/share/fonts`。產生 PDF、圖片或其他需要字型的功能，要在映像中自行安裝字型。
- 依映像的發行版開啟 `ttf-mscorefonts-installer` 所在的套件元件：

| 映像標籤 | 發行版 | 套件來源檔 | 元件 |
| --- | --- | --- | --- |
| .NET 6 預設標籤 | Debian 11 | `/etc/apt/sources.list` | `contrib` |
| .NET 8 預設標籤 | Debian 12 | `/etc/apt/sources.list.d/debian.sources` | `contrib` |
| .NET 10 預設標籤 | Ubuntu 24.04 | `/etc/apt/sources.list.d/ubuntu.sources` | `multiverse` |

- 上表只涵蓋不帶作業系統後綴的預設標籤。同一 .NET 版本另有其他發行版標籤（例如 `6.0-bookworm-slim`、`8.0-noble`、`8.0-alpine`），套件來源檔與套件管理器依實際發行版判定。
- Debian 12 的 .NET 官方映像沒有 `/etc/apt/sources.list`，套件來源只在 `debian.sources`，對 `/etc/apt/sources.list` 執行 `sed` 會因找不到檔案而失敗。下列範例只適用 Debian 12 映像，.NET 10 預設映像改依上表的 Ubuntu 套件來源與 `multiverse` 元件。
- 安裝步驟放在 `USER` 指令之前，`apt-get` 需要 root 權限。

```dockerfile
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS base
RUN sed -i 's/^Components: main$/& contrib/' /etc/apt/sources.list.d/debian.sources \
    && grep -q '^Components:.* contrib' /etc/apt/sources.list.d/debian.sources
RUN apt-get update && apt-get install -y ttf-mscorefonts-installer fontconfig
RUN fc-cache -f -v
USER app
```

### Nginx

- `map` 只能放在 `http` 區塊，定義的變數對所有 `server` 區塊都有效。多個 `map` 定義相同的輸出變數時，以最後載入的為準，前面的定義被捨棄。
- `conf.d/*.conf` 依檔名字母順序載入，各檔的 `map` 共用同一個命名空間。將所有 `map` 集中在單一 conf 檔（例如 `maps.conf`），避免被其他檔案覆蓋。
- `access_log`、`error_log` 在 `server` 或 `location` 設定時覆寫上層，未設定時繼承 `http` 或 main 層的設定。`error_log` 可設在 main、`http`、`mail`、`stream`、`server`、`location`；`access_log` 可設在 `http`、`server`、`location`、`if in location`、`limit_except`。
- 官方映像 1.19 起支援 template，`/etc/nginx/templates/*.template` 在容器啟動時以環境變數替換，輸出到 `/etc/nginx/conf.d/`。替換只在容器啟動時進行，修改環境變數後要重建容器（`docker compose up -d`）；`nginx -s reload` 不會重新替換。需要頻繁調整設定時，改用直接掛載 conf 檔。

## Compose 整合

- 遵守 Compose Specification (V2+) 規範，**不加入已廢棄的頂層 `version:` 欄位**。
- 新建檔案優先使用 `compose.yml` 為主要檔名（相容舊稱 `docker-compose.yml`，但不主動建立）。
- Service 間的相依關係使用 `depends_on` 搭配 `condition: service_healthy`，取代舊式純陣列寫法。
- 開發環境使用 `compose.override.yml` 覆寫正式環境設定（如掛載原始碼 Volume、開啟偵錯埠）。
