---
status: accepted
date: 2026-11-04
---

# ADR-0033：版本知識依引擎拆入參考檔，目標版本鍵記錄正式環境最低版本

## Context

Agent 撰寫 SQL 時常用到正式環境不支援的語法，因為正式環境的版本不在 repo 內，Agent 沒有判斷依據。`sql-query` 原有的版本門檻散落在分頁、T-SQL 對照表與自動編號等段落，同一門檻可能在多處記載。目標版本需要一個專案層的註記位置，並由撰寫 SQL 與設定 EF Core provider 的 skill 讀取。這項決策影響 `ai-profile`、`sql-query`、`ef-core` 三個 skill 與專案 `AGENTS.local.md` 的契約，後續新增其他外部系統的版本註記時也會沿用。

## Decision

版本知識依引擎拆成參考檔，`SKILL.md` 本體不寫具體版本。

- `sql-query` 新增 `references/sqlserver.md` 與 `references/oracle.md`，`ef-core` 新增 `references/provider-compatibility.md`。每個引擎一個檔，檔內以固定章節記載版本對照、功能版本門檻、替代寫法、寫法注意事項或語意陷阱，以及開發機版本查詢。
- 載入哪個參考檔由本輪涉及的資料庫決定，鍵值只決定檔內各列的判讀結果。Oracle 空字串等於 NULL 這類語意陷阱與版本無關，依資料庫載入可確保鍵缺少或略過時仍會讀到。
- 門檻表每列描述一種完整用法，附「支援條件」欄，可同時含引擎版本與相容性層級條件，每個條件都成立才算有支援。版本先後以對照表的列順序判定，不以字面數值比較。條件帶 Service Pack 等更新層級時，鍵值無法表達，在該產品版本判定為不支援。
- 每列門檻附官方文件連結，寫入前查證。查不到官方來源，或兩份官方文件互相矛盾的候選列不寫入。表內沒有的用法不憑記憶斷言版本。
- 留在本體的版本字樣改為指向參考檔的簡短標記，使同一門檻只在一處記載。無版本維度的 Oracle 專屬內容（T-SQL 對照表、識別字大小寫折疊、參數化範例等）保留在 `SKILL.md`。

目標版本以 AI-PROFILE 三個鍵記錄，負責 skill 為 `sql-query`。

| 鍵 | 語意 | 缺少時 |
| --- | --- | --- |
| `target.sqlserver` | 正式環境必須支援的最低 SQL Server 引擎版本，多個正式環境時記最低者 | 詢問且必答 |
| `target.sqlserver.compat` | 正式環境資料庫的相容性層級，選填，多個資料庫時記最低者 | 不獨立詢問，視為引擎版本的預設相容性層級 |
| `target.oracle` | 正式環境必須支援的最低 Oracle 版本，多個正式環境時記最低者 | 詢問且必答 |

- 鍵值不填開發機版本。有 mcp-sql-server 或 mcp-oracle 連線時，開發機版本只作為詢問時的推薦值；與已註記值不一致時同一 Session 提醒一次，不阻擋工作，不改寫鍵值。
- 相容性層級與引擎版本分成兩個鍵，因為 EF Core 與 SQL Server 依相容性層級產生不同 SQL，同一引擎版本可設定多個層級。
- 合法值採固定清單，與既有 AI-PROFILE 鍵一致，下限沿用原有文字邊界（SQL Server 2012、Oracle 11g）。
- 使用者明確略過詢問時，假定目標為對照表最舊的合法值及其預設相容性層級，不使用在該版本不成立的用法，回覆註明「未確認目標版本」。同一 Session 再次涉及時依 `ai-profile`「一次問完」重新列出。
- 審查既有 SQL 時鍵缺少不詢問、不阻擋，報告標示「未確認目標版本」。
- 鍵語意、詢問流程與判讀方式只在 `sql-query`「目標版本」定義一次，`ai-profile` 與 `ef-core` 以指標引用。`ef-core` 依鍵設定 `UseCompatibilityLevel` 或 `UseOracleSQLCompatibility`；略過時不設定相容性選項，既有設定與推導值不同時只回報差異。

排除下列方案：

- 每個版本一個參考檔：同一功能會在所有後續版本檔重複，新版本發行時要新增檔案並重新查證。
- 依版本區間切檔：區間邊界取決於查證前尚未確定的版本事實。
- 依功能類別切檔（函式、DDL、分頁）：每類只有數列，仍需引擎維度的路由。
- 三個引擎合併為單一檔：載入條件不同，每次載入都帶入無關引擎的內容。
- 依鍵值決定載入哪個檔：鍵缺少或略過時會漏載版本中立的語意陷阱。
- 相容性層級併入 `target.sqlserver` 的值：組合字串破壞「值為單一標示」的比對。
- 負責 skill 設為 `ef-core`：撰寫 SQL 不一定經過 EF Core。
- 合法值改為格式驗證：新版本免改清單，但錯字無法由 `ai-profile` 值錯誤處置攔截。
- 門檻表每列只帶一種門檻類型，再以合併規則判讀：連續兩輪審查在判讀規則產生同區域的 Major 問題，改為每列一種完整用法加支援條件。

## Consequences

新版本發行後，在合法值清單與參考檔對照表更新前，填入新版本會被 `ai-profile` 視為值錯誤而停止工作。新增或修改門檻列時須先查證官方來源，並維持同一門檻只在一處記載。`ef-core` 單獨載入時須同時載入 `sql-query` 才能取得鍵語意。

`target.sqlserver.compat` 已設定而 `target.sqlserver` 缺少時，先詢問引擎版本並保留 `compat` 的值；`compat` 超出該引擎版本的可設定範圍時視同值錯誤。

Oracle `UseOracleSQLCompatibility` enum 多載適用的 EF Core 版本未決。Oracle 的 API 頁寫只存在於 EF Core 8，Breaking changes 頁寫 EF Core 6 以上搭配 Oracle EF Core 21.12.1。`provider-compatibility.md` 不斷言版本，以專案引用的 `Oracle.EntityFrameworkCore` 實際提供的多載為準；該方法首次引入的 provider 版本同樣未查得。官方文件更新或取得實測證據後，再補入對應列。

Elasticsearch、Redis、RabbitMQ、MQTT broker 的版本註記不在本決策範圍，另開線時沿用本 ADR 的依引擎切檔與「正式環境最低版本」語意。`csharp-integration-test` 的 Testcontainers 容器版本是否對應目標鍵，另行決定。
