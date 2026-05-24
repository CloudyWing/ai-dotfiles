# DataTable Template

`DataTable` 在 JSON 場景下的唯一獨特能力：**`Columns` 可省略，自動從 `Records` 第一筆物件的鍵值順序推斷欄位**。

需要巢狀路徑（如 `Customer.Name`）或多層標題（`Children`）時，請改用 `RecordSet`。

## 何時用 DataTable

| 情境 | 建議 |
| --- | --- |
| 來源資料 schema 未知，只想原樣傾倒 | DataTable（省略 `Columns`） |
| API 回傳 / DB 查詢結果直接落 Excel，欄位動態 | DataTable |
| 需要巢狀路徑取值 | RecordSet |
| 需要多層標題 | RecordSet |
| 每欄都要精確控制樣式 / 標題 / 驗證 | RecordSet 更直覺 |

## 完整範例

```json
{
  "Type": "DataTable",
  "HeaderHeight": 22,
  "RecordHeight": 20,
  "Columns": [
    { "ColumnName": "Name" },
    { "ColumnName": "Age", "HeaderText": "年齡", "FieldStyle": { "HorizontalAlignment": "Right" } },
    { "ColumnName": "Level", "Value": "Standard" }
  ],
  "Records": [
    { "Name": "John", "Age": 30 },
    { "Name": "Mary", "Age": 25 }
  ]
}
```

## 省略 Columns

```json
{
  "Type": "DataTable",
  "Records": [
    { "Name": "John", "Age": 30 },
    { "Name": "Mary", "Age": 25 }
  ]
}
```

- 欄位順序依 `Records` 內第一筆物件的鍵值順序。
- 後續記錄缺少某欄位時，該儲存格為 `null`。
- 不會自動推斷型別與樣式。

## Column 支援欄位

| 欄位 | 說明 |
| --- | --- |
| `ColumnName` | 必填，對應 `Records[]` 的鍵，**不支援巢狀路徑** |
| `HeaderText` | 欄位標題，省略時使用 `ColumnName` |
| `Value` / `Formula` | 固定值或公式，二擇一（與動態取值互斥） |
| `HeaderStyleName` / `FieldStyleName` | 引用 named style |
| `HeaderStyle` / `FieldStyle` | inline 樣式 |
| `DataValidation` | 資料儲存格驗證 |
