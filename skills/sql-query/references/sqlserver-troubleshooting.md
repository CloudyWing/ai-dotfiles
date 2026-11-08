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
- 辨識方式為拿 `sp_executesql` 的參數化查詢與寫死值的查詢比較。參數化時變慢、寫死值時恢復正常，很可能受 Parameter Sniffing 影響。不用 `DECLARE` 區域變數當參數化的一側，理由見 SKILL.md「Parameter Sniffing」。

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
