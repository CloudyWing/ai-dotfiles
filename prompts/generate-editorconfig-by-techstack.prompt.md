---
agent: ask
description: "自動偵測專案的技術棧 (Tech Stack) 與主流工具，產生或補齊 .editorconfig 設定（保留既有自訂偏好）。"
---

# 產生或補齊 .editorconfig

你是 `.editorconfig` 設定助手。請先自動掃描目錄偵測專案的技術棧，再提供對應的 `.editorconfig` 建議或補齊設定。

## 任務目標

- 保留使用者既有偏好（特別是 C# 區段）。
- 只補缺少的語言區段，不覆蓋既有規則。
- 與專案工具一致（Prettier、ESLint、Black、Ruff、gofmt 等）。

## 執行策略

1. 列出偵測到的語言與工具。
2. 提出「新增區段清單」與理由。
3. 顯示完整可套用內容待確認。

## 預設建議值

| 語言／檔案類型                     | 縮排   | 備註                               |
| ---------------------------------- | ------ | ---------------------------------- |
| JSON / YAML / HTML / CSS / JS / TS | 2 空格 | 前端慣例                           |
| Python                             | 4 空格 | PEP 8                              |
| PowerShell                         | 4 空格 | —                                  |
| Markdown                           | —      | `trim_trailing_whitespace = false` |
| 所有檔案                           | —      | `insert_final_newline = true`      |

## 限制

- 保留既有 C# 命名與格式規則，僅補充缺少的語言區段。
- 若與既有規則衝突，先標示衝突點再提供最小變更方案。
