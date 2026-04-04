---
name: generate-editorconfig-by-techstack
description: 自動偵測專案的技術棧與主流工具，產生或補齊 .editorconfig 設定，保留既有自訂偏好。
disable-model-invocation: true
---

# 產生或補齊 .editorconfig

## 執行步驟

### 1. 偵測技術棧

掃描專案根目錄，識別使用的語言與工具：

| 偵測依據 | 識別技術 |
| --- | --- |
| `*.csproj`、`*.sln` | C# / .NET |
| `package.json` | JavaScript / TypeScript / Node.js |
| `tsconfig.json` | TypeScript |
| `*.vue` | Vue 3 |
| `vite.config.*` | Vite |
| `*.py`、`pyproject.toml` | Python |
| `go.mod` | Go |
| `Dockerfile`、`docker-compose*.yml` | Docker |
| `*.md`、`*.json`、`*.yaml`、`*.yml` | 標記語言 / 設定檔 |

### 2. 讀取既有 .editorconfig

若 `.editorconfig` 已存在：

1. 完整讀取現有內容。
2. 識別使用者已自訂的設定（如刻意設定的 `indent_size`、`end_of_line` 等）。
3. 後續步驟僅**補齊缺少的段落**，不覆蓋已有設定。

若不存在，從空白開始建立。

### 3. 產生設定內容

依偵測到的技術棧組合對應規則，套用下列各段落：

#### 全域基礎（所有專案必加）

```ini
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
indent_style = space
indent_size = 2
```

#### C# / .NET

```ini
[*.cs]
indent_size = 4

[*.{csproj,props,targets}]
indent_size = 2

[*.{sln}]
indent_style = tab
```

#### PowerShell

```ini
[*.ps1]
charset = utf-8-bom
end_of_line = crlf
indent_size = 4
```

#### CSV

```ini
[*.csv]
charset = utf-8-bom
trim_trailing_whitespace = false
```

#### Python

```ini
[*.py]
indent_size = 4
max_line_length = 88
```

#### Go

```ini
[*.go]
indent_style = tab
indent_size = 4
```

#### Markdown

```ini
[*.md]
trim_trailing_whitespace = false
max_line_length = off
```

#### YAML / JSON / TOML

```ini
[*.{yaml,yml,json,toml}]
indent_size = 2
```

#### Shell Script

```ini
[*.sh]
end_of_line = lf
indent_size = 2
```

#### Dockerfile

```ini
[Dockerfile]
indent_size = 4
```

### 4. 寫入結果

**已存在 .editorconfig**：使用 Merge 模式，將缺少的段落插入適當位置，不移動或覆蓋已有內容。

**不存在 .editorconfig**：依上述順序建立完整的新檔。

### 5. 完成確認

輸出：

- 偵測到的技術棧清單
- 新增的段落清單
- 略過（已存在）的段落清單
