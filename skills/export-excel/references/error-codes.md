# JSON 錯誤代碼對照

`SpreadsheetDocument.FromJson(...)` 解析失敗時，錯誤訊息會附 `SE-JSON-xxx` 代碼與 JSON path。

## 路徑格式

JSON root 是工作表陣列，所以路徑從 `$[0]` 開始：

```text
$[0]                                       第 0 張工作表
$[0].Templates[1]                          第 0 張工作表的第 1 個 template
$[0].Templates[0].Rows[2].Cells[3]         Grid 第 2 列第 3 格
$[0].Templates[0].Columns[1].DataValidation  RecordSet 第 1 欄的資料驗證
```

## 常見錯誤碼

| 代碼 | 範例訊息 | 處理方向 |
| --- | --- | --- |
| `SE-JSON-001` | `... must be a 32-bit integer.` | 該欄位型別錯誤，多半是把數字寫成字串或浮點 |
| `SE-JSON-002` | `... is required.` | 必填欄位缺失，依路徑補上 |
| `SE-JSON-003` | `... cannot specify both 'Value' and 'Formula'.` | 互斥欄位同時存在，依設計擇一保留 |

實際代碼會持續擴增，但格式固定為 `SE-JSON-xxx: <JSON path> <說明>`。

## 排查步驟

1. 取出錯誤訊息中的 `$[...]` 路徑。
2. 在原 JSON 用編輯器跳到對應節點（VSCode 可用「Go to Symbol」或手動展開）。
3. 對照訊息描述修正型別、補欄位、或拆掉互斥欄位。
4. 若同一檔案有多處錯誤，FromJson 只會拋出第一個失敗點，修完要再跑一次。
