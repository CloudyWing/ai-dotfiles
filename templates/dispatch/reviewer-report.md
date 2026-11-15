# 實作驗收報告

## 總覽

- 審查範圍：<diff 範圍與 commit>
- 結論：<pass 或 fail>。<一句話說明 open 的 Critical／Major>
- 缺陷審查：CONFIRMED <n>；PLAUSIBLE <n>
- 循環：<cycle_id> 第 <cycle_round> 輪（未標示時填「未標示」）

## Finding manifest

```json
{
  "schema": "codex-run.review-findings.v1",
  "findings": [
    {
      "id": "F-001",
      "severity": "Major",
      "status": "open",
      "summary": "<一句話描述缺陷>"
    }
  ]
}
```

## 動態證據複核

<依派遣單第 5 欄逐條列出命令原文、完整 stdout、完整 stderr、exit code、執行時間、執行狀態與判定。>

## Standards

<Standards 軸審查摘要；列出本輪 Standards 類 finding ID。>

## Spec

<Spec 軸審查摘要；列出本輪 Spec 類 finding ID。>

## 需求對照核對

<Developer 結案報告需求對照的列數、選定需求與範圍外清單核對結果。>

## 前輪 finding 狀態

- [<F-xxx>] 前輪狀態：<狀態> [<嚴重度>]。

## 本輪 finding 判定

- [F-001] 未閉合 [Major] — <判定說明>。證據：<證據檔絕對路徑>:<行號>

## 修正範圍外候選

<!-- 第 2 輪以上才有此節，沒有候選時刪除整節。只收修正範圍外新發現的 Minor，編號為 C 加三位數，編號外不加方括號，不列入 manifest，不影響結論。 -->

- C-001 [Minor] 位置：<檔案:行號> — <一句話 summary>

## Standards 缺陷審查

### [F-001] [CONFIRMED] [Major] <缺陷標題>

- 位置：<檔案:行號>
- failure_scenario：<具體輸入或狀態導致的錯誤結果>
- 判定依據：<依據>

## 例外回報

<!-- 沒有例外時刪除整節。條目格式與同線 exceptions.md 相同，由主 Agent 回收後併入。 -->

### <yyyy-MM-dd HH:mm:ss> - <觸發類型>

- 觸發類型：<偏離設計 | 自行採用假設 | 替代方案 | 範圍外既有問題 | 未涵蓋決策 | 繞過授權>
- 內容：<發生什麼>
- 依據：<為何這樣決定>
- 位置：<檔案:行號>
