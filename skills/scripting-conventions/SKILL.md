---
name: scripting-conventions
description: 'Use when 選擇或撰寫 PowerShell、Shell 或 C# Script，需判斷執行平台、編碼與相依工具時。'
audience: agent
policy.allow_implicit_invocation: true
---

# 腳本選用與規範

依執行平台、CI/CD 需求與 API 相依性選擇腳本語言：

- **PowerShell (`*.ps1`)**：Windows 環境的自動化腳本首選，編碼遵循全域 Encoding Strategy 的 UTF-8 with BOM 規則。
- **Shell (`*.sh`)**：跨平台或 CI/CD 環境使用，行尾使用 LF。
- **C# Script (`*.csx`)**：需要存取 .NET API 或 NuGet 套件的一次性腳本使用，搭配 `dotnet-script` 工具。

腳本僅在 Windows 執行時優先使用 PowerShell。需要跨平台執行時使用 Shell。需要 .NET 型別系統或 NuGet 套件時使用 C# Script。
