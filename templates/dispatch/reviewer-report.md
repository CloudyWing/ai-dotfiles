# 實作驗收報告

## 總覽

- 審查範圍：<diff 範圍與 commit>
- 結論：<pass 或 fail>。<一句話說明 open 的 Critical／Major>
- 缺陷審查：CONFIRMED <n>；PLAUSIBLE <n>

## Finding manifest

```json
{
  "schema": "codex-dispatch.review-findings.v2",
  "line_slug": "<line-slug>",
  "dispatch_slug": "<dispatch-slug>",
  "round": 1,
  "previous_status": [],
  "current_judgment": [
    {
      "id": "F-001",
      "status": "open",
      "severity": "Major",
      "evidence": [
        {
          "path": "<證據檔絕對路徑>",
          "line": 1
        }
      ]
    }
  ],
  "current_findings": [
    {
      "id": "F-001",
      "axis": "Standards",
      "status": "open",
      "severity": "Major",
      "disposition": "new",
      "summary": "<一句話描述缺陷>"
    }
  ],
  "counts": {
    "previous_closed": 0,
    "previous_open": 0,
    "previous_withdrawn": 0,
    "previous_accepted": 0,
    "current_new": 1,
    "current_open": 1,
    "current_closed": 0,
    "current_withdrawn": 0,
    "current_accepted": 0
  },
  "conclusion": "fail"
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

## Standards 缺陷審查

### [F-001] [CONFIRMED] [Major] <缺陷標題>

- 位置：<檔案:行號>
- failure_scenario：<具體輸入或狀態導致的錯誤結果>
- 判定依據：<依據>
