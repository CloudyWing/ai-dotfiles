# 內建 Agent 清單

| Agent | 類型 / 平台 | 讀者 | 用途 |
| --- | --- | --- | --- |
| `Analyst` | Persona / Claude | agent | 需求解構與釐清，透過對話將模糊需求轉化為可驗證標準。 |
| `Architect` | sub-agent / Claude | agent | 以 SA/SD 視角將需求元素轉化為系統設計文件，含架構、技術選型與分階段實作計畫。 |
| `Editor` | Persona / Claude | human | 文件編輯：與作者討論文件結構與內容，協助潤稿與重組敘事。寫作過程中的協作為主要用法。 |
| `Prototyper` | sub-agent / Claude | human | 依需求摘要與專案樣式基準產出可在瀏覽器開啟的 Demo 畫面，供需求訪談與版面確認使用。 |
| `contract-auditor` | sub-agent / Codex | human | 掃描前後端 API 介面，比對 Controller/DTO 與 TypeScript Client 型別的一致性，列出不一致點與修正建議。 |
| `developer` | Persona / Codex | agent | 依據設計文件實作功能，屬於 Clarify => Design => Implement => Review => Accept 流程中的實作階段 Persona。 |
| `frontend-reviewer` | sub-agent / Codex | human | 比對設計文件與實際 Vue 3 前端程式碼，盤點元件品質、效能問題與規範偏離，產出差異報告。 |
| `maintainer` | Persona / Codex | human | 維護工程師：判定進入類型，執行 bug 診斷與需求調整的範圍決定，產出 fix-plan 後交由 Support Engineer 實作並驗收。 |
| `refactorer` | sub-agent / Codex | human | 掃描 C#/.NET 專案，清除技術債、現代化程式碼語法，並強化符合專案慣例的程式碼品質。每次清理後執行測試確保行為不變。 |
| `reviewer` | sub-agent / Codex | human | 依派遣單執行設計核對、規範掃描與 diff-scoped 缺陷審查，逐條回報驗收條件並產出差異報告。 |
| `support-engineer` | sub-agent / Codex | agent | 技術支援工程師：依 fix-plan、需求調整計畫或派遣單完成實作修改，回報改動範圍與驗證證據。 |
