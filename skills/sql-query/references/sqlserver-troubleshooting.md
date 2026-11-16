# SQL Server 排查參考

排查 SQL Server 查詢變慢、查詢被阻塞或執行時間忽快忽慢時載入本檔。撰寫查詢的規則見 `sql-query` SKILL.md「SQL Server 專屬語法」。本檔的查詢屬診斷查詢，不受共通規範「禁止 `SELECT *`」與逗號前置格式約束。

## 鎖定與阻塞

- 預設隔離等級 READ COMMITTED 且未開啟 `READ_COMMITTED_SNAPSHOT` 時，讀取要取得共用鎖定（S），修改中的交易持有互斥鎖定（X），兩者不能並存，讀取會被擋住。
- 連線的 `LOCK_TIMEOUT` 預設為 `-1`，伺服器端的鎖定等待沒有上限，一路等到持有鎖定的交易 commit 或 rollback，或被用戶端命令逾時、死結處置中止。錯誤訊息不會說明被誰擋住，應用程式端通常只看到命令逾時或畫面一直轉圈，容易被誤判成查詢寫得不好而去看執行計畫；阻塞來源要查 `sys.dm_exec_requests`。
- 確認是否正在被阻塞時查 `sys.dm_exec_requests`，`blocking_session_id` 為正值時代表正在等該 session，`wait_type` 為 `LCK_M_` 開頭時才是鎖定等待。負值有特殊意義（例如 `-5` 表示無法確定 latch 擁有者），本身不代表效能問題。
- 常見成因：
  - 交易期間夾雜應用程式運算、外部 API 呼叫或等待使用者輸入，鎖定一直沒釋放。單一陳述式本身就是一個交易，單獨一句 `UPDATE` 一樣會鎖住資料；自動認可模式下做完就釋放，明確交易或隱含交易模式下會持有到 commit 或 rollback。
  - 條件欄位沒有可用索引，掃描大量資料列，鎖住的範圍遠大於實際需要。
  - 鎖定升級（Lock Escalation）：單一陳述式在同一張未分割的資料表或索引上取得 5,000 個以上的鎖定（或鎖定記憶體超過門檻）時，引擎會嘗試把列鎖或頁鎖換成單一資料表鎖；升級成功後擋住的是整張表。其他 session 持有不相容的資料表鎖時，升級嘗試會失敗並保留原本的鎖定。
  - 大範圍的報表 `SELECT` 取得共用鎖定，反過來擋住修改資料的交易。
- 資料庫已開啟 `READ_COMMITTED_SNAPSHOT` 時，讀取改走資料列版本控制，不取得共用鎖定，上述讀寫互相阻塞的情況多半不會發生。

## Parameter Sniffing

### 找出受影響的查詢

執行時間變異極大（Max/Avg 比率過高）的查詢通常就是 Parameter Sniffing 的徵兆，結果同時帶出清除計畫快取所需的 `plan_handle`：

```sql
SELECT TOP 20
    t.text AS [SQL Text],
    st.execution_count,
    [Max Elapsed (ms)] = st.max_elapsed_time / 1000,
    [Avg Elapsed (ms)] = (st.total_elapsed_time / st.execution_count) / 1000,
    -- Max/Avg Ratio：若 > 10 代表極度不穩定 (忽快忽慢)
    [Max/Avg Ratio] = CAST(st.max_elapsed_time * 1.0 / NULLIF(st.total_elapsed_time / st.execution_count, 0) AS DECIMAL(10,2)),
    st.plan_handle,
    st.last_execution_time
FROM sys.dm_exec_query_stats AS st
CROSS APPLY sys.dm_exec_sql_text(st.sql_handle) AS t
WHERE t.dbid = DB_ID('{YourDatabaseName}')
  AND st.execution_count > 50  -- 過濾掉偶發查詢
ORDER BY [Max/Avg Ratio] DESC;
```

- `sys.dm_exec_sql_text(st.sql_handle)` 對 ad hoc 查詢回傳的 `dbid` 為 NULL，上面的 `WHERE t.dbid = ...` 會把這類查詢篩掉；需要涵蓋時改以 `sys.dm_exec_plan_attributes(st.plan_handle)` 的 `dbid` 篩選。
- `sys.dm_exec_query_stats` 只涵蓋仍留在計畫快取的查詢，服務重啟或清過快取後統計歸零。已啟用 Query Store 時，改用其報表看歷史趨勢。
- 辨識方式為拿 `sp_executesql` 的參數化查詢與寫死值的查詢比較。參數化時變慢、寫死值時恢復正常，很可能受 Parameter Sniffing 影響。不用 `DECLARE` 區域變數當參數化的一側，理由見本檔「Parameter Sniffing 成因與處理方式」。

### 清除計畫快取

```sql
-- 清除特定計畫，影響最小；plan_handle 識別的是整個批次的計畫
-- 以上方查詢取得的實際 varbinary 值取代 <plan_handle>，不加大括號
DBCC FREEPROCCACHE (<plan_handle>);

-- 清除整個伺服器的計畫快取，所有查詢會瞬間變慢，非必要不使用
DBCC FREEPROCCACHE;
```

### Query Store

- SQL Server 2016 起提供，持續收集查詢的執行計畫與效能數據。發現計畫分岔導致效能忽快忽慢時，可用強制計畫將穩定的計畫固定下來。
- SQL Server 2022 起，新建立的資料庫預設開啟 Query Store。
- 在舊版手動開啟時，檢查 `MAX_STORAGE_SIZE_MB` 與 `QUERY_CAPTURE_MODE`，避免記錄過多 Ad-hoc 查詢而耗盡空間或影響 CPU。

## 遺漏索引

從 DMV 找出遺漏索引並組合建立語法：

```sql
SELECT TOP 20
    CONVERT (varchar(30), getdate(), 126) AS runtime,
    CONVERT (decimal (28, 1),
        migs.avg_total_user_cost * migs.avg_user_impact * (migs.user_seeks + migs.user_scans)
        ) AS estimated_improvement,
    'CREATE INDEX missing_index_' +
        CONVERT (varchar, mig.index_group_handle) + '_' +
        CONVERT (varchar, mid.index_handle) + ' ON ' +
        mid.statement + ' (' + ISNULL (mid.equality_columns, '') +
        CASE
            WHEN mid.equality_columns IS NOT NULL
            AND mid.inequality_columns IS NOT NULL THEN ','
            ELSE ''
        END + ISNULL (mid.inequality_columns, '') + ')' +
        ISNULL (' INCLUDE (' + mid.included_columns + ')', '') AS create_index_statement
FROM sys.dm_db_missing_index_groups mig
JOIN sys.dm_db_missing_index_group_stats migs ON
    migs.group_handle = mig.index_group_handle
JOIN sys.dm_db_missing_index_details mid ON
    mig.index_handle = mid.index_handle
ORDER BY estimated_improvement DESC;
```

產出的建議依 SKILL.md「索引設計」評估整併，不直接全數建立。執行時間極長的查詢可先看估計執行計畫找明顯缺漏的索引，時間降下來後再以實際執行計畫驗證。

## Parameter Sniffing 成因與處理方式

SQL Server 第一次編譯參數化查詢時，依當下傳入的參數值估算筆數並快取計畫，在重新編譯或計畫被清除前，後續不同參數值重用同一份計畫。參數值對應的資料量落差極大時，重用的計畫會讓其中一方效能崩潰，例如 `@Status = 0` 對到 10 筆、`@Status = 1` 對到 500 萬筆。判定依據是參數值對應的資料量落差，與參數值本身的數值大小無關。

- 只有預存程序、透過 `sp_executesql` 送出的查詢與 prepared 查詢會被嗅探。.NET 的參數化查詢（`SqlCommand` 搭配 `SqlParameter`、Dapper、EF Core）在伺服器端以 `sp_executesql` 執行，呼叫 `SqlCommand.Prepare()` 時則以 `sp_prepexec` 等 prepared 方式執行，兩者都屬於會被嗅探的範圍。
- 重現或比較時，以 `sp_executesql` 作為參數化的一側，不用 `DECLARE` 區域變數。區域變數在編譯期看不到值（加了 `OPTION (RECOMPILE)` 時例外），最佳化器改用統計資料的平均密度估算，沒有統計資料時改用啟發式估算，行為接近 `OPTIMIZE FOR UNKNOWN`，比出來的差異與 Parameter Sniffing 無關。
- 處理方式依查詢性質選擇：

| 方式 | 作法 | 代價 |
| --- | --- | --- |
| `OPTION (OPTIMIZE FOR (@p = value))` | 針對大宗值產生計畫 | 小眾值被迫使用大宗值的計畫而變慢，資料量大時可搭配篩選索引 |
| `OPTION (OPTIMIZE FOR UNKNOWN)` | 改用欄位統計分佈的平均值產生中庸計畫 | 計畫不再針對任何特定值最佳化 |
| `OPTION (RECOMPILE)` | 每次執行依當下參數重新編譯 | 增加 CPU 編譯成本，適合執行頻率低、參數組合複雜的報表，不適合高併發 OLTP |
| Parameter Sensitive Plan 最佳化 | 由引擎為同一查詢依參數分派多份計畫，查詢不需改寫 | 只支援等號述詞，最多挑選三個述詞；版本、相容性層級門檻與各層級的述詞挑選差異見 `sqlserver.md` |
| Query Store 強制計畫 | 將穩定的計畫固定下來 | 需啟用 Query Store，設定注意事項見本檔「Query Store」 |

找出受影響的查詢與清除計畫快取的方式，見本檔「Parameter Sniffing」的「找出受影響的查詢」與「清除計畫快取」。
