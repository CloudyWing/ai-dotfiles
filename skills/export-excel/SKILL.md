---
name: export-excel
description: '匯出 Excel 試算表的技能，主要支援 Grid 與 RecordSet 兩種模板，可自訂樣式、命名樣式、資料驗證與工作表保護。'
---

# Excel 試算表匯出技能

## 觸發條件

使用者提到 Excel 相關的建立、匯出、產生、製作需求時，執行本 Skill。常見觸發語句包含但不限於：

- 「幫我建立 / 產生 / 製作 / 匯出 xxx Excel」
- 明確說「使用 export-excel」

## 執行流程

1. **分析需求** — 從使用者描述中確認：工作表數量、欄位清單、是否需要靜態標題列（Grid）、資料來源格式、輸出路徑、是否需要資料驗證或共用樣式。
2. **產生 JSON** — 依下方格式規範產生 JSON 內容，寫入暫存檔（例如工作目錄下的 `spreadsheet.json`）。
3. **執行腳本** — 呼叫 `export-excel.csx` 並傳入 JSON 檔路徑與輸出路徑。
4. **回報結果** — 告知使用者輸出檔路徑與工作表摘要。

### 執行指令

```bash
dotnet script export-excel.csx <json-or-json-file> <output-path>
```

- `json-or-json-file`：JSON 字串、副檔名 `.json` 的檔案路徑，或 `-` 表示由 stdin 讀取（建議使用檔案，避免 shell 跳脫問題）。
- `output-path`：輸出的 `.xlsx` 路徑。

---

## JSON 根結構

根層級為工作表陣列，每個工作表可包含 Styles 與 Templates：

```json
[
  {
    "SheetName": "Sheet1",
    "DefaultRowHeight": 20,
    "Password": "sheet-pass",
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
    "Metadata": { "reportType": "monthly" },
    "Styles": {
      "Header": { "HasBorder": true, "Font": { "Style": "Bold" } }
    },
    "Templates": [ ]
  }
]
```

### 工作表層級欄位

| 欄位 | 型別 | 說明 |
| --- | --- | --- |
| `SheetName` | string | 工作表名稱，省略時自動命名 |
| `DefaultRowHeight` | number | 預設列高 |
| `Password` | string | 工作表保護密碼，配合 `Style.IsLocked` 控制鎖定範圍 |
| `FreezePanes` | object | 凍結 `Row` 列與 `Column` 欄，例：`{ "Row": 1, "Column": 0 }` |
| `IsAutoFilterEnabled` | boolean | 啟用自動篩選，每張工作表僅一組 |
| `ColumnWidths` | object / array | 欄寬，兩種格式擇一（見下） |
| `PageSettings.PageOrientation` | enum | `Portrait`（預設）、`Landscape` |
| `PageSettings.PaperSize` | enum | `A4`、`A3`、`Letter`、`Legal` 等 |
| `Metadata` | object | 自訂附加資料，供 renderer 或擴充邏輯讀取 |
| `Styles` | object | 工作表層級 named styles（見「Named Styles」章節） |
| `Templates` | array | 工作表上的 template 定義 |

#### ColumnWidths 兩種格式

物件形式（鍵為欄位索引字串）：

```json
{ "ColumnWidths": { "0": 18, "1": 24 } }
```

陣列形式：

```json
{ "ColumnWidths": [ { "Index": 0, "Width": 18 }, { "Index": 1, "Width": 24 } ] }
```

---

## Named Styles

`Styles` 在工作表層級宣告共用樣式，template 內以 `StyleName`、`HeaderStyleName` 或 `FieldStyleName` 引用。

```json
{
  "Styles": {
    "Header": { "HasBorder": true, "Font": { "Style": "Bold", "Size": 12 } },
    "Money":  { "HorizontalAlignment": "Right", "DataFormat": "#,##0.00" }
  },
  "Templates": [
    {
      "Type": "Grid",
      "Rows": [
        {
          "Cells": [
            { "Value": "標題", "StyleName": "Header", "Style": { "HorizontalAlignment": "Center" } }
          ]
        }
      ]
    }
  ]
}
```

**繼承規則**：找到 named style 後，inline 的 `Style` 只覆寫 JSON 中明確宣告的屬性。例如 inline 只寫 `Font.Style` 時，不會清掉 named style 中的字型名稱、大小或顏色。

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
          "StyleName": "Header",
          "Style": { "HorizontalAlignment": "Center" }
        }
      ]
    },
    {
      "Cells": [
        { "Value": "A1" },
        { "Formula": "SUM(A2:A10)", "Style": { "DataFormat": "#,##0.00" } },
        { "ColumnSpan": 2, "RowSpan": 2, "Value": "合併格" },
        {
          "Value": "下拉選單",
          "DataValidation": {
            "ValidationType": "List",
            "ListItems": ["A", "B", "C"],
            "IsDropdownShown": true
          }
        }
      ]
    }
  ]
}
```

**Cell 支援欄位**：

| 欄位 | 說明 |
| --- | --- |
| `Value` | 固定值，與 `Formula` 擇一 |
| `Formula` | 公式字串，與 `Value` 擇一 |
| `ColumnSpan` / `RowSpan` | 合併格範圍，預設 `1` |
| `StyleName` | 引用 named style |
| `Style` | inline 樣式，可與 `StyleName` 同時存在 |
| `DataValidation` | 儲存格資料驗證（見下方「DataValidation」章節） |

**空白列與 Template 起始位置**：在 `Rows` 陣列中插入無 `Cells` 內容（或 `Cells` 為空陣列）的列，可作為空白間隔列，控制下一個 Template 的起始列位置。

---

### RecordSet — 強型別資料繫結表格

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
      "FieldStyleName": "Money",
      "DataValidation": {
        "ValidationType": "Decimal",
        "Operator": "GreaterThanOrEqual",
        "Value1": 0
      }
    },
    {
      "HeaderText": "客戶資訊",
      "Children": [
        { "HeaderText": "名稱", "FieldKey": "Customer.Name" },
        { "HeaderText": "城市", "FieldKey": "Customer.Address.City" }
      ]
    }
  ],
  "Records": [
    {
      "OrderId": 1001,
      "Amount": 1250.40,
      "Customer": { "Name": "Northwind", "Address": { "City": "Seattle" } }
    }
  ]
}
```

**Column 支援欄位**：

| 欄位 | 說明 |
| --- | --- |
| `HeaderText` | 欄位標題 |
| `FieldKey` | 從 `Records[]` 取值，**支援巢狀路徑**如 `Customer.Address.City` |
| `Value` | 固定值，與 `FieldKey` / `Formula` 三擇一 |
| `Formula` | 固定公式，與 `FieldKey` / `Value` 三擇一 |
| `HeaderStyleName` / `FieldStyleName` | 引用 named style |
| `HeaderStyle` / `FieldStyle` | inline 樣式 |
| `DataValidation` | 資料儲存格驗證 |
| `Children` | 子欄位，建立多層標題 |

**樣式預設值**：

- **RecordSet `HeaderStyle`**：預設框線 + 粗體（Bold）。
- **RecordSet `FieldStyle`**：預設框線，無粗體。
- **Grid `Style`**：無預設，未指定則一律空白樣式。
- 指定 inline `HeaderStyle` / `FieldStyle`，或引用 `StyleName` 而未提供 inline `Style` 時，預設值完全失效，所有需要的屬性（含框線）都必須明確寫出。

---

## Style 完整欄位

| 欄位 | 可用值 |
| --- | --- |
| `HorizontalAlignment` | `Left`、`Center`、`Right` |
| `VerticalAlignment` | `Top`、`Middle`、`Bottom` |
| `HasBorder` | `true` / `false` |
| `WrapText` | `true` / `false` |
| `BackgroundColor` | 色彩值（見下） |
| `DataFormat` | Excel 格式字串，如 `"#,##0.00"`、`"yyyy-MM-dd"` |
| `IsLocked` | `true` / `false`，配合工作表 `Password` 控制保護範圍 |
| `Font.Name` | 字型名稱 |
| `Font.Size` | 字型大小 |
| `Font.Color` | 色彩值（見下） |
| `Font.Style` | `None`、`Bold`、`Italic`、`Underline`、`Strikeout`，可組合（字串以 `,` 分隔，或用陣列） |

**色彩值三種格式**：

- 命名色彩，如 `"Red"`、`"White"`
- HTML 色碼，如 `"#FFAA00"`
- RGB / ARGB 物件，如 `{ "R": 255, "G": 170, "B": 0 }`（`A` 可選）

列舉值（對齊、PageOrientation、PaperSize、ValidationType、Operator、Font.Style）支援名稱或數值，字串比對不分大小寫。

---

## DataValidation

`Grid` 的 `Cells[].DataValidation` 與 `RecordSet` 的 `Columns[].DataValidation` 使用相同結構。

| 欄位 | 型別 | 說明 |
| --- | --- | --- |
| `ValidationType` | enum | `List`、`Integer`、`Decimal`、`Date`、`Time`、`TextLength`、`Custom`，未設定時預設為 `List` |
| `Operator` | enum / null | `Between`、`NotBetween`、`Equal`、`NotEqual`、`GreaterThan`、`LessThan`、`GreaterThanOrEqual`、`LessThanOrEqual` |
| `Value1` | any | 第一比較值 |
| `Value2` | any | 第二比較值（如 Between 範圍上限） |
| `ListItems` | string[] / null | 清單驗證可選值，項目必須是字串 |
| `Formula` | string / null | 自訂驗證公式，或數值 / 日期 / 時間驗證的公式來源 |
| `IsDropdownShown` | boolean | 清單驗證是否顯示下拉選單 |
| `IsBlankAllowed` | boolean | 是否允許空白值 |
| `ErrorTitle` / `ErrorMessage` | string / null | 驗證失敗時的對話框內容 |
| `IsErrorAlertShown` | boolean | 是否顯示錯誤提示 |
| `PromptTitle` / `PromptMessage` | string / null | 選取儲存格時顯示的提示訊息 |
| `IsInputPromptShown` | boolean | 是否顯示輸入提示 |

---

## 完整範例

```json
[
  {
    "SheetName": "銷售報表",
    "DefaultRowHeight": 20,
    "FreezePanes": { "Row": 1, "Column": 0 },
    "IsAutoFilterEnabled": true,
    "ColumnWidths": { "0": 12, "1": 24, "2": 16, "3": 16 },
    "Styles": {
      "Title": {
        "HasBorder": true,
        "HorizontalAlignment": "Center",
        "BackgroundColor": "#1F4E79",
        "Font": { "Style": "Bold", "Size": 14, "Color": "White" }
      },
      "Money": {
        "HasBorder": true,
        "HorizontalAlignment": "Right",
        "DataFormat": "#,##0.00"
      }
    },
    "Templates": [
      {
        "Type": "Grid",
        "Rows": [
          {
            "Height": 28,
            "Cells": [
              { "Value": "銷售報表", "ColumnSpan": 4, "StyleName": "Title" }
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
          { "HeaderText": "客戶", "FieldKey": "Customer.Name" },
          {
            "HeaderText": "數量",
            "FieldKey": "Qty",
            "FieldStyle": { "HasBorder": true, "HorizontalAlignment": "Right" },
            "DataValidation": {
              "ValidationType": "Integer",
              "Operator": "Between",
              "Value1": 1,
              "Value2": 9999
            }
          },
          {
            "HeaderText": "金額",
            "FieldKey": "Amount",
            "FieldStyleName": "Money"
          }
        ],
        "Records": [
          { "Id": 1, "Customer": { "Name": "Northwind" }, "Qty": 3, "Amount": 45000 },
          { "Id": 2, "Customer": { "Name": "Adventure Works" }, "Qty": 5, "Amount": 30000 }
        ]
      }
    ]
  }
]
```

執行：

```bash
dotnet script export-excel.csx report.json output.xlsx
```

---

## 進階參考（需要時再讀）

- **DataTable template** → `references/data-table.md`
  - 何時用 DataTable 而非 RecordSet、`Columns` 省略自動推斷的行為。
- **JSON 錯誤代碼對照** → `references/error-codes.md`
  - `SE-JSON-xxx` 對照、JSON path 格式、排查步驟。

---

## 前置需求

```bash
dotnet tool install -g dotnet-script
```
