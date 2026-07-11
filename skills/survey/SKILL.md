---
name: survey
description: 掃描專案結構並產出完整技術文件索引，供團隊成員與 AI 快速理解專案全貌。當要求掃描專案、建立文件索引、補齊技術文件或盤點專案結構時使用。
---

# 專案技術文件 Survey

當使用者要求掃描專案、建立文件索引、補齊技術文件或盤點專案結構時，請套用本 Skill。

## 執行流程

### Phase 1：環境偵測與文件目錄判斷

1. 掃描根目錄辨識技術棧，主動偵測：自訂基底類別、非典型連線/執行緒管控、影響執行期行為的自訂 Attribute、非標準 SQL 慣例。
2. 偵測文件目錄（不限資料夾名稱，找含大量專案相關 `.md` 的目錄）：
   - 無符合目錄 → 建立 `docs/`。
   - 有且結構符合 → 沿用，缺口原地補充。
   - 有但結構不同 → 維持原有命名與結構，在原結構內擴充。
3. 若文件目錄已有現有文件，先讀取全文，再列出「將完整重寫 / 將新增 / 將原地擴充」的清單供使用者確認後再寫入。

### Phase 2：並行掃描（僅掃描適用面向）

| 面向 | 預設檔案 |
| --- | --- |
| 總覽 | `_index.md` |
| 技術棧 | `tech-stack.md` |
| 目錄結構 | `directory-structure.md` |
| 環境變數 | `environment-variables.md` |
| 架構設計 | `architecture.md` |
| 資料模型 | `data-model.md` |
| 業務流程 | `business-flows.md` |
| 頁面流向 | `page-flows.md` |
| API | `api-endpoints.md` |
| 驗證與權限 | `auth-and-permissions.md` |
| 前端狀態 | `frontend-state.md` |
| 部署與 CI/CD | `deployment.md` |
| 基礎設施機制 | `infrastructure-patterns.md` |
| 決策與債務 | `decisions-and-debt.md` |

不適用的面向在總索引標「不適用」，不產出對應檔案。

現有文件有缺口時，直接補充進原始檔案（Merge 模式），禁止另建 `*-supplement.md` 類附錄。

### Phase 3：品質自我檢核

驗證交叉連結、靜態驗證 Mermaid 語法、確認總索引涵蓋所有已產出文件。

## 約束

- 圖表一律使用 Mermaid 語法。
- 文件以中性客觀語氣撰寫，不涉及當前任務脈絡或時間軸。
- 環境變數清單不輸出實際值（密碼、Token）。
- 不讀取 `.local/`、`.env`、`bin/`、`obj/` 等敏感路徑（除非使用者明確授權）。
- 不強制改變現有文件目錄的結構或命名慣例。
