# 整合測試資料庫容器映像

本輪撰寫或修改 SQL Server 或 Oracle 整合測試容器設定時載入本檔，使用方式依 `csharp-integration-test` SKILL.md「資料庫容器目標版本」。版本先後與相容性層級沿用 `sql-query` 的 `references/sqlserver.md`、`references/oracle.md`，本檔只記載映像。最後查證日：2026-11-04。

## SQL Server 映像對照

列由舊到新，「標示」欄即 `target.sqlserver` 的合法值。映像名稱為 `mcr.microsoft.com/mssql/server`，標籤從 [MCR 標籤清單](https://mcr.microsoft.com/artifact/mar/mssql/server/tags) 選用「標籤字首」開頭的固定標籤。

| 標示 | 映像 | 標籤字首與範例 | 引擎落差 | 來源 |
| --- | --- | --- | --- | --- |
| `2012` | 無對應映像，改用 `2017` 列的映像 | 同 `2017` 列 | 實際引擎為 `2017`，以相容性層級模擬目標 | [What is SQL Server on Linux?](https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-overview) |
| `2014` | 無對應映像，改用 `2017` 列的映像 | 同 `2017` 列 | 實際引擎為 `2017`，以相容性層級模擬目標 | [What is SQL Server on Linux?](https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-overview) |
| `2016` | 無對應映像，改用 `2017` 列的映像 | 同 `2017` 列 | 實際引擎為 `2017`，以相容性層級模擬目標 | [What is SQL Server on Linux?](https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-overview) |
| `2017` | `mcr.microsoft.com/mssql/server` | `2017-`，例如 `2017-GA-ubuntu` | 無 | [Quickstart: Run SQL Server Linux container images with Docker](https://learn.microsoft.com/sql/linux/install-upgrade/quickstart-install-docker) |
| `2019` | `mcr.microsoft.com/mssql/server` | `2019-`，例如 `2019-CU18-ubuntu-20.04` | 無 | [Deploy and connect to SQL Server Linux containers](https://learn.microsoft.com/en-us/sql/linux/containers/deploy) |
| `2022` | `mcr.microsoft.com/mssql/server` | `2022-`，例如 `2022-CU11-ubuntu-22.04` | 無 | [Quickstart: Run SQL Server Linux container images with Docker](https://learn.microsoft.com/sql/linux/install-upgrade/quickstart-install-docker) |
| `2025` | `mcr.microsoft.com/mssql/server` | `2025-`，例如 `2025-GA-ubuntu` | 無 | [Quickstart: Run SQL Server Linux container images with Docker](https://learn.microsoft.com/sql/linux/install-upgrade/quickstart-install-docker) |

`2012`、`2014`、`2016` 三列的依據是 SQL Server on Linux 自 `2017` 起提供，官方容器映像都是 Linux 映像。

## Oracle 映像對照

列由舊到新，「標示」欄即 `target.oracle` 的合法值。「來源類型」的「官方」指 Oracle 文件，「發佈者」指 gvenzl 映像的 GitHub 頁面；gvenzl 映像不是 Oracle 官方映像。gvenzl 映像另有 `slim`、`full` 與 `faststart` 變體，標籤以 `-slim`、`-full`、`-faststart` 等字尾區分。

| 標示 | 映像 | 無免費映像時 | 來源類型 | 來源 |
| --- | --- | --- | --- | --- |
| `11g` | `gvenzl/oracle-xe:11.2.0.2` | 不適用 | 發佈者 | [gvenzl/oci-oracle-xe](https://github.com/gvenzl/oci-oracle-xe) |
| `12cR1` | 無免費映像 | 先詢問能否使用企業版映像；不能時改用 `18c` 列的映像，實際引擎為 `18c`。本檔未收錄 `12cR1` 企業版標籤，由使用者提供 | 發佈者 | [gvenzl/oci-oracle-xe](https://github.com/gvenzl/oci-oracle-xe)、[gvenzl/oci-oracle-free](https://github.com/gvenzl/oci-oracle-free) |
| `12cR2` | 無免費映像 | 先詢問能否使用企業版映像；不能時改用 `18c` 列的映像，實際引擎為 `18c`。本檔未收錄 `12cR2` 企業版標籤，由使用者提供 | 發佈者 | [gvenzl/oci-oracle-xe](https://github.com/gvenzl/oci-oracle-xe)、[gvenzl/oci-oracle-free](https://github.com/gvenzl/oci-oracle-free) |
| `18c` | `gvenzl/oracle-xe:18.4.0` | 不適用 | 發佈者 | [gvenzl/oci-oracle-xe](https://github.com/gvenzl/oci-oracle-xe) |
| `19c` | 無免費映像 | 先詢問能否使用企業版映像 `container-registry.oracle.com/database/enterprise:19.3.0.0`；不能時改用 `21c` 列的映像，實際引擎為 `21c` | 官方、發佈者 | [Setting Up Oracle Database](https://docs.oracle.com/cd/F26413_61/books/DeployCont/c-Setting-Up-Oracle-Database.html)、[gvenzl/oci-oracle-xe](https://github.com/gvenzl/oci-oracle-xe)、[gvenzl/oci-oracle-free](https://github.com/gvenzl/oci-oracle-free) |
| `21c` | `gvenzl/oracle-xe:21.3.0` | 不適用 | 發佈者 | [gvenzl/oci-oracle-xe](https://github.com/gvenzl/oci-oracle-xe) |
| `23ai` | `gvenzl/oracle-free` 版本號早於 `23.26` 的標籤，例如 `gvenzl/oracle-free:23.9`；發佈者已將這些標籤標為不支援，可能移除 | 不適用 | 發佈者 | [gvenzl/oci-oracle-free](https://github.com/gvenzl/oci-oracle-free) |
| `26ai` | `gvenzl/oracle-free` 版本號 `23.26` 起的標籤，例如 `gvenzl/oracle-free:23.26.3` | 不適用 | 發佈者 | [gvenzl/oci-oracle-free](https://github.com/gvenzl/oci-oracle-free)、[buildContainerImage.sh](https://github.com/gvenzl/oci-oracle-free/blob/main/buildContainerImage.sh) |

`12cR1`、`12cR2`、`19c` 三列「無免費映像」的依據是兩個 gvenzl 頁面列出的支援標籤只有 `11.2.0.2`、`18.4.0`、`21.3.0` 與 `23.x`。

企業版映像需先登入 Oracle Container Registry 並接受授權條款才能拉取，見 [Setting Up Oracle Database](https://docs.oracle.com/cd/F26413_61/books/DeployCont/c-Setting-Up-Oracle-Database.html)。

## 指定映像寫法

| 模組 | 寫法 | 來源 |
| --- | --- | --- |
| `Testcontainers.MsSql` | 以建構子傳入映像，例如 `new MsSqlBuilder("mcr.microsoft.com/mssql/server:2022-CU14-ubuntu-22.04").Build()` | [Testcontainers for .NET: MSSQL](https://dotnet.testcontainers.org/modules/mssql/) |
| `Testcontainers.Oracle` | 以建構子 `OracleBuilder(string image)` 傳入映像；無參數建構子與預設映像常數已標為 obsolete | [OracleBuilder.cs](https://github.com/testcontainers/testcontainers-dotnet/blob/develop/src/Testcontainers.Oracle/OracleBuilder.cs) |
