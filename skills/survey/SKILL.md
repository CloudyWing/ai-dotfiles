---
name: survey
description: 掃描專案結構並產出供團隊成員閱讀的技術文件索引。當要求掃描專案、建立文件索引、補齊技術文件或盤點專案結構時使用。
audience: human
dispatch: split
policy.allow_implicit_invocation: true
---

# 專案技術文件 Survey

輸出屬於 human-facing 文件，固定落在專案的 `docs/` 目錄。需要供 Agent 查詢的脈絡索引時，改用 `ai-context-index` skill。

## 執行流程

### Phase 1：環境偵測與文件目錄判斷

1. 掃描根目錄辨識技術棧，主動偵測：自訂基底類別、非典型連線/執行緒管控、影響執行期行為的自訂 Attribute、非標準 SQL 慣例。
2. 確認文件目錄為 `docs/`。目錄不存在時建立；目錄已存在時沿用其內容與命名慣例，在原結構內補充缺口。
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

## 派遣分界

### Phase 1：Claude 判定段

Claude 執行 Phase 1 的三個步驟。Claude 讀取根目錄與既有 `docs/` 文件，判定技術棧、特殊機制、文件目錄、掃描面向、排除路徑、輸出檔案與驗收條件。`docs/` 不存在時，Claude 僅記錄建立目錄的需求，不在使用者確認前建立目錄。`docs/` 已存在時，Claude 先讀取現有文件全文，再列出完整重寫、新增與原地擴充清單。

Phase 1 完成後必須停止，等待使用者確認工作根目錄、掃描範圍、排除路徑、輸出檔案、驗收條件，以及既有文件的重寫／新增／擴充清單。使用者確認前不建立 Codex 派遣，不寫入 `docs/` 或任何輸出檔案。

### Phase 2：Codex 掃描段

使用者確認已取得，且派遣單已逐項列出完整路徑、排除路徑、輸出要求與驗收條件後，Codex 依 Phase 1 固定的範圍執行 Phase 2。Codex 只掃描派遣單列出的適用面向，不重新決定掃描範圍；不適用的面向依既有規則標記為「不適用」，不建立未核准的對應檔案。Phase 2 可在同一派遣內連續完成，不需再次等待使用者確認。

### Phase 3：Codex 掃描段

Codex 於 Phase 2 完成後連續執行 Phase 3，驗證交叉連結、Mermaid 語法與總索引涵蓋範圍。Phase 3 不需再次等待使用者確認。若檢核需要修改，Codex 只能修改 Phase 1 已確認且派遣單已列出的輸出檔案；若需要新增輸出檔案、擴大掃描範圍或改變重寫／新增／擴充分類，必須停止並回報，交由 Claude 重新取得使用者確認。

### Codex 寫入放行條件

Codex 只有在下列條件全部成立時，才可建立或修改輸出檔案：

1. Phase 1 的範圍判定與文件清單已完成。
2. 使用者已確認 Phase 1 的範圍與文件清單。
3. 派遣單已列出目標完整路徑、排除路徑、輸出要求與驗收條件。
4. 目標檔案位於已確認的輸出範圍內，且不在排除路徑中。

任一條件不成立時，Codex 不得寫入，必須停止並回報缺少的條件。任何寫入失敗時，Codex 必須停止後續寫入，回報完整路徑、操作、錯誤與已完成的輸出，不得改寫未核准路徑、建立替代檔案或回報 Phase 成功。

此分界由本 Skill 定義，路由不回落 F1 三層表。

## 約束

- 圖表一律使用 Mermaid 語法。
- 文件以中性客觀語氣撰寫，不涉及當前任務脈絡或時間軸。
- 環境變數清單不輸出實際值（密碼、Token）。
- 不讀取 `.local/`、`.env`、`bin/`、`obj/` 等敏感路徑（除非使用者明確授權）。
- 不強制改變現有文件目錄的結構或命名慣例。
