# Oracle 排查參考

排查 Oracle 慢 SQL、判讀執行計畫或評估是否補索引時載入本檔。撰寫查詢的規則見 `sql-query` SKILL.md「Oracle 專屬語法」。本檔的查詢屬診斷查詢，不受共通規範「禁止 `SELECT *`」與逗號前置格式約束。

## 資料來源與授權

| 檢視 | 內容 | 資料存活範圍 | 需 Diagnostics Pack |
| --- | --- | --- | --- |
| `V$SESSION` | 目前每條 session 與即時狀態（STATUS、等待事件、目前 SQL_ID） | 連線存在期間，斷線即消失 | 否 |
| `V$SQL` | Shared Pool 快取的 SQL 文字與執行統計，一個 child cursor 一列 | Cursor 留在 Shared Pool 期間，age out 即消失 | 否 |
| `V$SQLAREA` | `V$SQL` 依 `SQL_ID` 彙總，一句一列，另有 `VERSION_COUNT` | 同 `V$SQL` | 否 |
| `V$SQL_SHARED_CURSOR` | 每個 child cursor 無法共用的原因 | 同 `V$SQL` | 否 |
| `V$ACTIVE_SESSION_HISTORY`（ASH） | 每秒取樣的 Active Session 活動 | 近期，記憶體環形緩衝，重啟即失 | 是 |
| `DBA_HIST_ACTIVE_SESS_HISTORY`（AWR） | ASH 取樣持久化 | 預設約 8 天，重啟仍在 | 是 |

- `V$` 檢視讀的是 SGA 記憶體裡的即時狀態，資料不落地；`DBA_HIST_` 是定期寫到 `SYSAUX` 的歷史快照，AWR 預設每小時一張快照，系統當下卡死時快照可能尚未產生。排查正在發生的問題使用 `V$`。
- `V$SESSION`、`V$SQL` 是 public synonym，對應 `SYS` 底下多一個底線的 `V_$` 檢視。一般帳號預設沒有存取權，授權方式擇一：
  - `GRANT SELECT_CATALOG_ROLE TO <username>;`，一次給予資料字典與所有 `V$` 檢視。
  - `GRANT SELECT ON SYS.V_$SESSION TO <username>;`，只放行單一檢視。授權對象必須寫帶底線的 `SYS.V_$*`，寫 `V$SESSION` 會因為那只是 synonym 而報 `ORA-02030`。
- ASH 與 AWR 屬 Oracle Diagnostics Pack，需 Enterprise Edition 且另外購買授權。`control_management_pack_access` 設為 `DIAGNOSTIC+TUNING` 時就查得到資料，只代表功能在資料庫層開著，不代表環境有授權；未確認授權前不查詢這兩類檢視。
  - 所有 `DBA_HIST_` 檢視都屬 Diagnostics Pack，只有 `DBA_HIST_SNAPSHOT`、`DBA_HIST_DATABASE_INSTANCE`、`DBA_HIST_SNAP_ERROR`、`DBA_HIST_SEG_STAT`、`DBA_HIST_SEG_STAT_OBJ`、`DBA_HIST_UNDOSTAT` 免授權，且對 SQL 級排查幫助不大。
  - `$ORACLE_HOME/rdbms/admin/` 底下的 `awrrpt.sql`、`ashrpt.sql`、`addmrpt.sql` 等報表腳本同屬此 Pack。

## 找出有問題的 SQL

### 正在執行的 SQL

```sql
SELECT
    s.SID,
    s.SERIAL#,           -- 與 SID 合起來唯一識別一條 session
    s.USERNAME,
    s.STATUS,            -- ACTIVE = 此刻正在執行呼叫
    s.STATE,             -- WAITING = 目前正卡在等待
    s.EVENT,
    s.WAIT_CLASS,
    s.WAIT_TIME_MICRO,   -- STATE 為 WAITING 時是這個等待已等多久（微秒）
    s.LAST_CALL_ET,      -- STATUS 為 ACTIVE 時，這個呼叫已執行的秒數
    s.SQL_ID,
    q.SQL_TEXT           -- 可能因 age out 而為空
FROM V$SESSION s
LEFT JOIN V$SQL q
    ON q.SQL_ID = s.SQL_ID
    AND q.CHILD_NUMBER = s.SQL_CHILD_NUMBER
WHERE s.STATUS = 'ACTIVE'
    AND (s.STATE <> 'WAITING' OR s.WAIT_CLASS <> 'Idle')   -- 非等待狀態時 WAIT_CLASS 是上一次等待
    AND s.USERNAME IS NOT NULL
ORDER BY s.LAST_CALL_ET DESC;
```

- 以 `LEFT JOIN` 接 `V$SQL`，SQL 被 age out 時 `SQL_TEXT` 變空，session 那列仍保留。
- join 條件同時用 `SQL_ID` 與 `CHILD_NUMBER`，一個 `SQL_ID` 底下可能有多個 child cursor。
- 呼叫已執行多久看 `LAST_CALL_ET`；卡在什麼等待、等了多久，先確認 `STATE` 為 `WAITING`，再看 `EVENT` 與 `WAIT_TIME_MICRO`。不用 `SECONDS_IN_WAIT` 排序，它的語意隨 `STATE` 變動，且已被標為 deprecated。
- `V$SESSION` 每條連線只留目前的 `SQL_ID` 與上一句的 `PREV_SQL_ID`，事後回頭找慢 SQL 改查 `V$SQL`。

### 最近執行過的 SQL

SQL 跑完後、age out 之前都留在 `V$SQL`，依成本排序挑出高成本的 SQL：

```sql
SELECT
    q.SQL_ID,
    q.CHILD_NUMBER,
    q.EXECUTIONS,
    ROUND(q.ELAPSED_TIME / 1000000, 3) AS TOTAL_SECONDS,
    ROUND(q.ELAPSED_TIME / NULLIF(q.EXECUTIONS, 0) / 1000000, 3) AS AVG_SECONDS,
    q.BUFFER_GETS,
    q.DISK_READS,
    q.ROWS_PROCESSED,
    q.LAST_ACTIVE_TIME,
    q.SQL_TEXT
FROM V$SQL q
WHERE q.LAST_ACTIVE_TIME >= SYSDATE - (10 / 1440)   -- 最近 10 分鐘
    AND q.EXECUTIONS > 0
    -- 排除這條查詢自己：AND UPPER(q.SQL_TEXT) NOT LIKE '%FROM V$SQL%'
ORDER BY q.ELAPSED_TIME DESC
FETCH FIRST 20 ROWS ONLY;
```

| 排序或條件 | 回答的問題 |
| --- | --- |
| `ELAPSED_TIME DESC` | 累計最耗時的 SQL |
| `ELAPSED_TIME / EXECUTIONS` | 單次平均最慢的 SQL；`ELAPSED_TIME` 是 parse、執行與 fetch 的累計資料庫時間，平行執行時含協調者與各 worker 的時間，可能大於實際經過時間 |
| `BUFFER_GETS DESC` | 邏輯讀取最多，常是掃太多資料 |
| `EXECUTIONS DESC` | 被呼叫最多次，抓 N+1 |
| `LAST_ACTIVE_TIME` | 篩選最近跑過的，不是成本指標 |

- `FETCH FIRST` 的版本門檻見 `references/oracle.md`。
- 判斷 SQL 成本看 `BUFFER_GETS`（邏輯讀取），它反映 SQL 實際碰了多少資料塊，不受快取冷熱影響。`DISK_READS`（實體讀取）會隨快取變暖而下降，`DISK_READS` 高但 `BUFFER_GETS` 不高多半只是冷快取。

### 找出 N+1

字面值不同的 SQL 會散成不同的 `SQL_ID`，`V$SQLAREA` 的 `EXECUTIONS` 只抓得到有綁變數的 N+1。以 `FORCE_MATCHING_SIGNATURE` 分組可同時抓兩種，它把字面值當成 bind 變數處理後才計算簽章，只差在字面值的 SQL 會得到相同的值：

```sql
SELECT
    q.FORCE_MATCHING_SIGNATURE,
    COUNT(DISTINCT q.SQL_ID) AS VARIANT_COUNT,
    SUM(q.EXECUTIONS) AS TOTAL_EXEC,
    MAX(q.SQL_TEXT) AS SAMPLE_SQL
FROM V$SQL q
WHERE q.FORCE_MATCHING_SIGNATURE <> 0          -- 排除沒有簽章的列
GROUP BY q.FORCE_MATCHING_SIGNATURE
HAVING SUM(q.EXECUTIONS) > 10000               -- 門檻依系統調整
ORDER BY TOTAL_EXEC DESC;
```

- `VARIANT_COUNT = 1` 且 `TOTAL_EXEC` 很高：有綁變數的同一句被大量執行。
- `VARIANT_COUNT` 很大：同一邏輯查詢以字面值散成大量 `SQL_ID`，每個字面值都要 hard parse，額外拖累 Shared Pool。

### VERSION_COUNT 偏高

`V$SQLAREA.VERSION_COUNT` 是同一 `SQL_ID` 的 child cursor 數。

- 良性成因為 Adaptive Cursor Sharing。條件欄位資料傾斜時，Oracle 為選擇率差很多的 bind 值各生一個 child、配不同計畫，通常只多幾個。可從 `V$SQL` 的 `IS_BIND_SENSITIVE` 與 `IS_BIND_AWARE` 確認。
- 不良成因為 bind 型別或長度不一致、optimizer 環境或 schema 物件不同，導致 child 一直無法共用。
- 查 `V$SQL_SHARED_CURSOR` 看每個 child 哪個 mismatch 欄位為 `Y`，判斷是哪一種。

## 取得實際執行計畫

只產生預估計畫的 Explain Plan 全是 Optimizer 的估計值；判斷索引需要實際撈回筆數與實際讀取的資料塊，以 `GATHER_PLAN_STATISTICS` 執行一次再印出計畫：

```sql
SELECT /*+ GATHER_PLAN_STATISTICS */
    o.ORDER_ID,
    o.STATUS
FROM ORDERS o
WHERE o.ORDER_DATE >= :start_date
    AND o.ORDER_DATE < :end_date;

SELECT *
FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(FORMAT => 'ALLSTATS LAST'));
```

- `DISPLAY_CURSOR` 未指定 `SQL_ID` 時，抓的是這條 session 最後執行的 SQL。在 SQL Developer 中兩句間隔太久，會抓到工具自己的內部查詢並顯示「basic plan statistics not available」。兩句以 Run Script 一起送出，或先查出目標的 `SQL_ID` 與 `CHILD_NUMBER`，改呼叫 `DISPLAY_CURSOR('<sql_id>', <child_number>, 'ALLSTATS LAST')`；第二個參數傳 `NULL` 會列出該 `SQL_ID` 底下所有 child。

## 解讀執行計畫

- `TABLE ACCESS FULL`：全表掃描。大表只撈少量資料卻出現它，是可疑點；資料量很少時全表掃描不一定比較貴。
- `INDEX RANGE SCAN`、`INDEX UNIQUE SCAN`：走索引。條件命中的資料佔比太高時，走了索引一樣很慢。
- `TABLE ACCESS BY INDEX ROWID`：用索引找到 ROWID 後回資料表取其他欄位，即回表。這一步的 `A-Rows` 很大時，代表要回表的資料太多，可評估把查詢需要的欄位一起放進索引。
- `E-Rows` 是預估筆數，`A-Rows` 是實際輸出筆數，只有實際執行統計才有 `A-Rows`。兩者差距很大時，先懷疑統計資訊過期，重新收集：

  ```sql
  EXEC DBMS_STATS.GATHER_TABLE_STATS(ownname => 'APP', tabname => 'ORDERS');
  ```

- `Buffers` 可反推表的規模。資料塊預設 8 KB，一列 100 bytes 的窄表一塊約裝幾十列。估計 50 萬列而全表掃描的 `Buffers` 只有 8，代表表其實很小，只是統計還停在舊值。
- 估計失準的其他成因還有資料分佈不均、欄位相關性與 Bind Peeking。Bind Peeking 是 hard parse 時依第一次傳入的 bind 值建計畫，與 SQL Server 的 Parameter Sniffing 同源。
- `A-Time` 與 `Buffers` 都很小時，即使看到 `TABLE ACCESS FULL` 也不需要加索引，以實際成本為準。

## 判斷是否補索引

依序回答下列問題，不因看到全表掃描就加索引：

1. 條件欄位過濾掉的資料夠多嗎？以 `COUNT(*)`、`COUNT(DISTINCT ...)` 與實際查詢範圍的命中筆數估算選擇率。命中筆數相對全表很小時，索引才有意義；撈出一大半資料時，Optimizer 多半會判斷全表掃描較划算。
2. 計畫已經是 `INDEX RANGE SCAN` 仍然慢嗎？問題可能在回表太多、統計過期或查詢被高頻重複呼叫，再加一個索引通常沒用。
3. 條件欄位被函式包住嗎？處理方式見 SKILL.md Oracle 專屬節「Function-Based Index」。

## 驗證調整結果

執行時間的落差可能只來自主機當下的資源使用率，以執行計畫的變化驗證：

- 取資料方式是否從 `TABLE ACCESS FULL` 變成預期的 `INDEX RANGE SCAN`。
- 邏輯讀取（`Buffers`）是否下降。
- 結果筆數是否不變。改索引不應改變查詢結果，筆數變了代表有地方弄錯。
