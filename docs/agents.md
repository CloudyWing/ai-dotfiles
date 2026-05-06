# 內建 Agent 清單

| Agent | 類型 / 平台 | 用途 |
| --- | --- | --- |
| `Clarify` | Persona / Claude | 需求解構與釐清，透過對話將模糊需求轉化為可驗證標準。 |
| `Debug` | Persona / Claude | 以系統化方式診斷、分析並修復程式錯誤，每次修改都有明確的假設依據，絕不盲目嘗試。 |
| `Design` | sub-agent / Claude | 以 SA/SD 視角將需求元素轉化為系統設計文件，含架構、技術選型與分階段實作計畫。 |
| `Editor` | Persona / Claude | 文件編輯：分析 Markdown 檔案的結構與內容，產出改善建議清單，經使用者確認後執行修改。 |
| `Propose` | Persona / Claude | 產品構想探索：針對現有專案挖掘擴充方向，或將模糊想法塑形為功能藍圖，產出提案清單供使用者決定範圍。 |
| `api-contract` | sub-agent / Codex | 掃描前後端 API 介面，比對 Controller/DTO 與 TypeScript Client 型別的一致性，列出不一致點與修正建議。 |
| `cleanup` | sub-agent / Codex | 掃描 C#/.NET 專案，清除技術債、現代化程式碼語法，並強化符合專案慣例的程式碼品質。每次清理後執行測試確保行為不變。 |
| `frontend-review` | sub-agent / Codex | 比對設計文件與實際 Vue 3 前端程式碼，盤點元件品質、效能問題與規範偏離，產出差異報告。 |
| `implement` | Persona / Codex | 依據設計文件實作功能，屬於 Clarify => Design => Implement => Review 流程中的實作階段 Persona。 |
| `review` | sub-agent / Codex | 實作完成後比對設計文件與實際程式碼，盤點遺漏、品質不足與刻意略過的項目，產出差異報告。 |
| `survey` | sub-agent / Codex | 掃描專案結構並產出完整技術文件索引，供團隊成員與 AI 快速理解專案全貌。 |
