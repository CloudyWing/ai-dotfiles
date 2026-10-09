---
name: generate-gitattributes
description: 產生或補齊 .gitattributes，統一行尾處理、二進位識別與 lock files 標記，保留既有自訂偏好。
audience: human
dispatch: dispatchable
disable-model-invocation: true
policy.allow_implicit_invocation: false
---

# 產生或補齊 .gitattributes

## 範本來源

本 Skill 的規則內容以 `~/.ai-agents/templates/.gitattributes` 為單一來源。修改建議規則時，**只改範本檔，不改 SKILL.md**。SKILL.md 僅描述執行流程。

範本檔位於使用者家目錄下的 `.ai-agents/` 專案。執行時若找不到範本檔，告知使用者後流程終止，不自行重建內容。

## 執行步驟

### 1. 讀取範本與既有 .gitattributes

1. 讀取 `~/.ai-agents/templates/.gitattributes`，取得完整的建議內容。
2. 若目標專案的 `.gitattributes` 已存在：
   - 完整讀取現有內容。
   - 識別使用者已自訂的規則（如刻意設定的 `eol`、`merge` 策略等）。
   - 後續步驟僅**補齊範本中有、現有檔案中缺少的規則**，不覆蓋已有設定。
3. 若不存在，後續步驟以範本內容為基底建立全新檔案。

### 2. 衝突偵測

若已存在 `.gitattributes`，逐條比對既有規則與範本規則：

1. 列出**衝突點**：同一個 pattern（如 `*`、`*.ps1`）但屬性不同（如現有 `eol=crlf`，範本為 `eol=lf`）。
2. 對每個衝突點，提供**最小變更方案**：優先保留使用者已設定的值，僅補齊完全缺少的規則。
3. 若衝突點超過 3 個，在進入步驟 3 前先列出衝突清單，讓使用者決定哪些保留、哪些覆蓋。

特別注意以下既有設定不可靜默覆蓋：

- 已存在的 `* text=auto eol=crlf`（與範本方向相反，必須確認）。
- 已存在的 `merge=binary` 或 `diff=` 自訂驅動設定。
- 已存在的 `linguist-*` 屬性。

若無衝突，直接進入步驟 3。

### 3. 套用前確認

顯示完整的 `.gitattributes` 預覽內容（或僅顯示新增/修改的段落），**停止等待使用者確認**後再執行寫入。確認格式：

```
以下是將要寫入的 .gitattributes 內容（新增段落）：

# 預設所有文字檔使用 LF，二進位檔不轉換
* text=auto eol=lf
...

確認後將寫入，請回覆「確認」。
```

若使用者要求調整，修改後重新顯示確認。

### 4. 寫入結果

**已存在 .gitattributes**：使用 Merge 模式，將缺少的規則插入對應分組（依範本的分組標題對齊）。若原檔沒有對應分組標題，將新規則歸入語意最接近的段落，或追加於檔案末尾。

**不存在 .gitattributes**：直接以範本內容建立新檔。

### 5. 後續提醒

寫入完成後，提醒使用者下列事項（不自動執行）：

1. **`core.autocrlf` 設定**：若使用者全域 git config 仍是 `core.autocrlf=true`，建議改為 `false`，避免與 `.gitattributes` 雙重處理：

   ```bash
   git config --global core.autocrlf false
   ```

2. **既有檔案 normalize**：新增或修改 `.gitattributes` 後，既有檔案的行尾不會自動套用新規則。需執行以下指令重新正規化（會產生一次大量 diff，建議獨立成一個 commit）：

   ```bash
   git add --renormalize .
   git commit -m "chore: 套用 .gitattributes 行尾規則重新 normalize"
   ```

3. **跨平台確認**：若團隊有 Windows / macOS / Linux 混用成員，確認 `.editorconfig` 的 `end_of_line` 與此 `.gitattributes` 設定方向一致（如皆為 LF）。

### 6. 完成確認

輸出：

- 範本來源路徑。
- 新增的段落清單。
- 略過（已存在）的規則清單。
- 衝突清單與處理結果。
