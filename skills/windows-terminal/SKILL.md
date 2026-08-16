---
name: windows-terminal
description: 'Use when 在 Windows 執行終端機命令，需要處理輸出編碼、中文亂碼或輸出截斷時。'
audience: agent
policy.allow_implicit_invocation: true
---

# Windows 終端機輸出規範

在 Windows 環境執行可能輸出中文的命令時，先設定終端輸出編碼：

```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
```

## 編碼與輸出診斷

- 可能輸出中文的命令包含 `dotnet test`、`git log` 與 `git diff`。執行前先設定 `[Console]::OutputEncoding`。
- 寫入 `.ps1` 檔案時，編碼遵循全域 Encoding Strategy，使用 UTF-8 with BOM。
- 讀取終端輸出時若出現亂碼或截斷，先檢查 `[Console]::OutputEncoding`，再檢查檔案編碼與 `chcp` Code Page。
- 輸出結尾不完整但既有字元可讀時，判定為截斷。限制輸出長度，或將輸出導向檔案後再讀取，不改動編碼設定。
- 遇到亂碼時先確認編碼狀態與來源，再針對診斷結果修正，不反覆嘗試沒有新假設的命令組合。

## 輸出長度控制

- 查詢 Git 歷史時使用 `git log -n <count>` 限制筆數。
- 讀取差異時指定檔案，例如 `git diff -- <specific file>`。
- 需要完整輸出時先寫入工作產物的 `scratch/`，再分段讀取，結案時依清理規則移除暫存內容。
