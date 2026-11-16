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

- 寫入 `.ps1` 檔案時，編碼遵循全域 Encoding Strategy，使用 UTF-8 with BOM。
- 讀取終端輸出時若出現亂碼或截斷，先檢查 `[Console]::OutputEncoding`，再檢查檔案編碼與 `chcp` Code Page。
- 輸出結尾不完整但既有字元可讀時，判定為截斷。限制輸出長度，或將輸出導向檔案後再讀取，不改動編碼設定。

## 輸出長度控制

- 需要完整輸出時先寫入工作產物的 `scratch/`，再分段讀取，結案時依清理規則移除暫存內容。
