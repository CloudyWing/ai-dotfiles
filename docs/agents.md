# 內建 Agent 清單

| Agent | 類型 / 平台 | 用途 |
| --- | --- | --- |
| `Clarify` | Persona / Claude | 需求解構與釐清，透過對話將模糊需求轉化為可驗證標準。 |
| `Design` | sub-agent / Claude | 以 SA/SD 視角將需求元素轉化為系統設計文件，含架構、技術選型與分階段實作計畫。 |
| `Editor` | Persona / Claude | 文件編輯：與作者討論文件結構與內容，協助潤稿與重組敘事。寫作過程中的協作為主要用法。 |
| `api-contract` | sub-agent / Codex | 掃描前後端 API 介面，比對 Controller/DTO 與 TypeScript Client 型別的一致性，列出不一致點與修正建議。 |
| `cleanup` | sub-agent / Codex | 掃描 C#/.NET 專案，清除技術債、現代化程式碼語法，並強化符合專案慣例的程式碼品質。每次清理後執行測試確保行為不變。 |
| `debug` | Persona / Codex | bug 線協調者：系統化診斷 bug 根因、產出輕量 fix-plan、派生同 session 匿名 subagent 執行修正並驗收其產出，每次修改都有明確假設依據。 |
| `frontend-review` | sub-agent / Codex | 比對設計文件與實際 Vue 3 前端程式碼，盤點元件品質、效能問題與規範偏離，產出差異報告。 |
| `implement` | Persona / Codex | 依據設計文件實作功能，屬於 Clarify => Design => Implement => Review 流程中的實作階段 Persona。 |
| `review` | sub-agent / Codex | 實作完成後比對設計文件與實際程式碼，盤點遺漏、品質不足與刻意略過的項目，產出差異報告。 |
