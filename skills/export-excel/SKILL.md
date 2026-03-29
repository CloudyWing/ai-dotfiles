---
name: export-excel
description: '匯出 Excel 試算表的技能，支援 Grid 與 RecordSet 模板，並可自訂樣式與格式。'
---

# Excel 試算表匯出技能

## 觸發條件

使用者要求「匯出 Excel」、「產生試算表」或明確說「使用 export-excel」時，執行本 Skill。

## 執行流程

1. **分析需求** — 從使用者描述中確認：工作表數量、欄位清單、是否需要靜態標題列（Grid）、資料來源格式、輸出路徑。
2. **產生 JSON** — 依下方格式規範產生 JSON 內容，寫入暫存檔（例如 `/tmp/spreadsheet.json`）。
3. **執行腳本** — 呼叫 `export-excel.csx` 並傳入 JSON 檔路徑與輸出路徑。
4. **回報結果** — 告知使用者輸出檔路徑與工作表摘要。

### 執行指令

```bash
dotnet script export-excel.csx <json-or-json-file> <output-path>
```

- `json-or-json-file`：JSON 字串，或副檔名 `.json` 的檔案路徑（建議使用檔案，避免 shell 跳脫問題）。
- `output-path`：輸出的 `.xlsx` 路徑。

---

## JSON 格式規範

根層級為工作表陣列，每個工作表包含 Templates 陣列：

```json
[
  {
    "SheetName": "Sheet1",
    "DefaultRowHeight": 20,
    "FreezePanes": { "Row": 1, "Column": 0 },
    "IsAutoFilterEnabled": true,
    "ColumnWidths": [
      { "Index": 0, "Width": 18 },
      { "Index": 1, "Width": 24 }
    ],
    "PageSettings": {
      "PageOrientation": "Portrait",
      "PaperSize": "A4"
    },
    "Templates": [ ... ]
  }
]
```

- **FreezePanes**：凍結前 N 列與前 M 欄。`{ "Row": 1, "Column": 0 }` 表示凍結第一列、不凍結欄；省略 `Column` 時視為 0。
- **IsAutoFilterEnabled**：`true` 時啟用工作表的自動篩選功能。注意：Excel 每個工作表僅支援一組自動篩選，通常會自動套用於工作表內的資料區域。
- **PageOrientation**：`Portrait`（預設）、`Landscape`。
- **PaperSize**：`A4`、`A3`、`Letter`、`Legal` 等。

---

## Template 類型

### Grid — 自由格線（標題列、摘要區塊）

```json
{
  "Type": "Grid",
  "Rows": [
    {
      "Height": 28,
      "Cells": [
        {
          "Value": "標題文字",
          "ColumnSpan": 4,
          "Style": {
            "HorizontalAlignment": "Center",
            "HasBorder": true,
            "Font": { "Name": "Calibri", "Size": 14, "Style": "Bold" }
          }
        }
      ]
    },
    {
      "Cells": [
        { "Value": "A1" },
        { "Formula": "SUM(A2:A10)", "Style": { "DataFormat": "#,##0.00" } },
        { "ColumnSpan": 2, "RowSpan": 2, "Value": "合併格" }
      ]
    }
  ]
}
```

**Style 可用欄位**：

| 欄位 | 可用值 |
| --- | --- |
| `HorizontalAlignment` | `Left`、`Center`、`Right` |
| `VerticalAlignment` | `Top`、`Middle`、`Bottom` |
| `HasBorder` | `true` / `false` |
| `WrapText` | `true` / `false` |
| `BackgroundColor` | `"#RRGGBB"` 或 `"255,200,100"` (R,G,B) |
| `DataFormat` | Excel 格式字串，如 `"#,##0.00"`、`"yyyy-MM-dd"` |
| `Font.Name` | 字型名稱 |
| `Font.Size` | 字型大小（數字） |
| `Font.Style` | `None`、`Bold`、`Italic`、`Underline`、`Strikeout`（可組合以 `,` 分隔） |

---

### RecordSet — 資料繫結表格

```json
{
  "Type": "RecordSet",
  "HeaderHeight": 22,
  "RecordHeight": 20,
  "Columns": [
    { "HeaderText": "訂單編號", "FieldKey": "OrderId" },
    {
      "HeaderText": "金額",
      "FieldKey": "Amount",
      "FieldStyle": { "HorizontalAlignment": "Right", "DataFormat": "#,##0.00" }
    },
    {
      "HeaderText": "狀態",
      "FieldKey": "Status",
      "HeaderStyle": { "Font": { "Style": "Bold" } }
    }
  ],
  "Records": [
    { "OrderId": 1001, "Amount": 1250.40, "Status": "完成" },
    { "OrderId": 1002, "Amount": 980.00, "Status": "處理中" }
  ]
}
```

- **FieldKey** 對應 Records 內的 JSON 屬性名稱（區分大小寫）。
- **HeaderStyle** / **FieldStyle** 結構與 Grid 的 `Style` 相同。

---

## 完整範例

```json
[
  {
    "SheetName": "銷售報表",
    "DefaultRowHeight": 20,
    "FreezePanes": { "Row": 1, "Column": 0 },
    "IsAutoFilterEnabled": true,
    "ColumnWidths": [
      { "Index": 0, "Width": 12 },
      { "Index": 1, "Width": 24 },
      { "Index": 2, "Width": 16 },
      { "Index": 3, "Width": 16 }
    ],
    "Templates": [
      {
        "Type": "Grid",
        "Rows": [
          {
            "Height": 28,
            "Cells": [
              {
                "Value": "銷售報表",
                "ColumnSpan": 4,
                "Style": {
                  "HorizontalAlignment": "Center",
                  "HasBorder": true,
                  "Font": { "Style": "Bold", "Size": 14 }
                }
              }
            ]
          }
        ]
      },
      {
        "Type": "RecordSet",
        "HeaderHeight": 22,
        "RecordHeight": 20,
        "Columns": [
          { "HeaderText": "編號", "FieldKey": "Id" },
          { "HeaderText": "產品", "FieldKey": "Product" },
          {
            "HeaderText": "數量",
            "FieldKey": "Qty",
            "FieldStyle": { "HorizontalAlignment": "Right" }
          },
          {
            "HeaderText": "金額",
            "FieldKey": "Amount",
            "FieldStyle": { "HorizontalAlignment": "Right", "DataFormat": "#,##0.00" }
          }
        ],
        "Records": [
          { "Id": 1, "Product": "筆記型電腦", "Qty": 3, "Amount": 45000 },
          { "Id": 2, "Product": "顯示器", "Qty": 5, "Amount": 30000 }
        ]
      }
    ]
  }
]
```

執行：

```bash
dotnet script export-excel.csx /tmp/report.json output.xlsx
```

---

## 前置需求

```bash
dotnet tool install -g dotnet-script
```
