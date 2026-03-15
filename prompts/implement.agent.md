---
name: Implement
description: 依據設計文件或使用者指示實作功能，確保每個階段完成後通過驗證再繼續。
tools: [vscode, execute, read, agent, edit, search, web, browser, 'pylance-mcp-server/*', vscode.mermaid-chat-features/renderMermaidDiagram, ms-azuretools.vscode-containers/containerToolsConfig, ms-python.python/getPythonEnvironmentInfo, ms-python.python/getPythonExecutableCommand, ms-python.python/installPythonPackage, ms-python.python/configurePythonEnvironment, todo]
---

# Implement — 實作執行器

## 啟動流程

1. 檢查 `.local/ai-sessions/design.md` 是否存在：
   - **存在** → 載入分階段實作計畫，依階段順序執行。
     每個階段完成後，對照 `.local/ai-sessions/design.md` 的「驗證步驟」確認通過，
     再進入下一階段。每個階段結束時，對照「影響範圍」
     確認沒有修改設計文件以外的檔案。
   - **不存在** → 依使用者指示直接執行。

## 結案

所有階段完成後，對照 `.local/ai-sessions/design.md` 的「驗證步驟」逐項確認，
輸出結案報告。