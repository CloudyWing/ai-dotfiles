# Codex 派工機制：失敗與恢復

本檔收錄 派遣失敗或中斷時的恢復導引與回收前的 RecoveryPrecheck。入口與其他階段的檔案見 `../SKILL.md`「階段路由」。

## 失敗與恢復導引

| 失敗形狀 | 恢復方式 | 詳細節 |
| --- | --- | --- |
| Dispatch 回報 `CodexAccountsAllUnavailable`（登記帳號全數未登入、或因 `config.toml` 設定異常被略過，或被服務端拒絕），或單一嘗試被服務端拒絕（usage-limit、401、model not supported） | 同一帳號不重送。未指定 `-CodexHome` 時腳本已逐帳號嘗試，回報全數不可用時依 `instructions.md`「離線改派」重新呼叫選派入口並依回傳狀態處置；略過原因含 `TrustConfigMissing`、`TrustConfigLinked` 或 `TrustConfigUnsupported` 時，先回報使用者並列出各帳號的略過原因與下一列的修法，再依「離線改派」處置，不靜默改派。指定 `-CodexHome`、背景模式或續行被拒時，主 Agent 依摘要檔或 RunRecord 指定下一個帳號 | 額度與範圍契約 |
| Dispatch 於 `preflight` 階段回報 `CodexAccountConfigMissing`、`CodexAccountConfigLinked`、`CodexAccountConfigUnsupported`、`CodexAccountConfigChanged`、`CodexAccountConfigWriteFailed`、`CodexAccountTrustLockTimeout` 或 `CodexProjectPathUnsupported` | 不換帳號，主 Agent 不自行編輯 `config.toml`。`CodexAccountConfigMissing` 請使用者以 `New-CodexDispatchAccount.ps1 -Name <名稱>` 重跑；`CodexAccountConfigLinked` 請使用者以 `(Get-Item -LiteralPath '<路徑>' -Force).Delete()` 只刪除連結後重跑建立腳本；`CodexAccountConfigUnsupported` 請使用者依訊息的行號人工修正，既有非 `trusted` 的專案設定視為使用者決定，腳本不覆寫；`CodexAccountConfigChanged` 稍後重派；`CodexAccountTrustLockTimeout` 確認沒有卡住的程序後重派；`CodexAccountConfigWriteFailed` 排除權限或磁碟原因後重派；`CodexProjectPathUnsupported` 改用不含單引號或控制字元的絕對路徑 | `start.md`「本機帳號清單與準備」 |
| admission 或 Start 準備階段失敗、Codex 程序未啟動 | 修正輸入後可用同一個 `dispatchSlug` 重新冷啟動；該次派遣經過換帳號外層、已寫出 `history/<lineSlug>/dispatch-account-failover-<dispatchSlug>.json` 時，摘要檔保留供稽核，腳本以 `DispatchAccountFailoverSummaryCollision` 拒絕同一個 `dispatchSlug`，改用新的 `dispatchSlug`。腳本會清除該次失敗嘗試建立的 ScopePlan hash 紀錄，`failure receipt` 與 `launch-failed` RunRecord 保留供稽核；已啟動成功者的 hash、ledger 與 owner 不受影響。Cleanup 依 Preflight result、符合未啟動條件且無事件流的 `launch-failed` RunRecord，或無兩者時的 U1 至 U4 從未啟動判定放行。U1 要求 worktree history 無 `codex-exec-*.jsonl` 與 `codex-thread-<dispatchSlug>.txt`；U2 要求來源 `history\<lineSlug>\runs\<dispatchSlug>\` 無 RunRecord；U3 要求相符的 dispatch-request，預設讀 `history\<lineSlug>\dispatch-request-<dispatchSlug>.json`，可用 `dispatch_request_path` 指定，或使用 `process_started=false` 的 pending／failed 收據與已結束的 dispatcher 身分；舊版 failed 收據可沒有 dispatcher 身分。收據只能經 CLI `-FailureReceiptPath` 提供，Cleanup Request 不接受 `failure_receipt_path`；收據顯示 dispatcher 仍在執行或狀態不明時，U3 不通過，不改用 dispatch-request。U4 要求 admission ledger 無該 dispatchSlug 的 entry。放行後留存 `cleanup-unstarted-<dispatchSlug>-<attemptId>.json` 稽核檔。三種證據皆不成立時以 `CleanupPreflightResultRequired` 拒絕並列出未通過項目；有 RunRecord 時提供 `run_record_path`，有啟動痕跡或 ledger entry 時依續行或 owner 接手流程處理。請勿手寫 Preflight result、failure receipt、RunRecord 或 dispatch-request。該次嘗試已建立 dispatch worktree 時，Preflight 會因 dispatchRoot 已被占用而拒絕，此時改用新的 `dispatchSlug`；Prepare 結果檔已存在而發生 `PrepareResultCollision` 時，改用新的結果路徑或新的 `dispatchSlug` | 續 session 與跨介面接手 |
| 續行被拒 | 以 `git -C <舊 dispatchRoot> diff HEAD` 與未追蹤檔案清單轉移成果，以新的 `dispatchSlug` 冷啟動 | Codex 進程 PID 與並行檢查 |
| 事件流在最後訊息前中斷，沒有 `turn.completed` 或 `turn.failed` | 先執行 `Inspect` 與 `Collect` 取回中斷保全檔；只交付已確認單位與其證據，其餘 selected units 保持未完成 | InterruptionSafeguard |
| 事件流以 `turn.failed` 結束或 exit code 非零 | 依 C 出口取失敗原因。若事件流以 `turn.failed` 結束且結案報告不存在，`Inspect` 與 `Collect` 回報 `recoverable_artifacts_present` 及 `recoverable_artifact_files`，供主 Agent 檢視相對 `baseSha` 的 worktree 變更並決定是否以新 `dispatchSlug` 冷啟動；欄位不改變失敗判定 | 完成判定與三出口 |
| `DispatchInputOrderLocationInvalid` | 派遣單存在於 `handoff` 根目錄時，移至訊息列出的線目錄並移除根目錄檔案後重送；prompt 引用 Start 注入的路徑 | 派遣單契約 |
| `DispatchInputOrderMissing` | 依訊息中的線目錄路徑建立派遣單後重送 | 派遣單契約 |
| `DispatchInputRequiredReadHeadingInvalid`、`DispatchInputRequiredReadEmpty`、`DispatchInputRequiredReadLineInvalid`、`DispatchInputRequiredReadMultiplePaths`、`DispatchInputRequiredReadNotAbsolute`、`DispatchInputReferenceMissing` | 依訊息的正確寫法修正派遣單第 4 欄並重送，確認區塊內路徑存在；提示 `DispatchInputOutsideBlockPath` 與 `DispatchInputRequiredReadAbsent` 不擋派遣，需要執行端必讀的檔案列入區塊 | 派遣單契約 |
| `DispatchInputDirectoryScanLimit`，目標目錄掃描超過 10000 個項目，無法確認是否含 C# 檔 | 將 `target_path` 縮小至實際要修改的子目錄或檔案後重送 | AI-PROFILE 前置檢查 |
| 派遣 target_path 符合機密檔名樣式 | `Preflight` 以 `PreflightSecretTargetRejected` 列出路徑並在建立 worktree 前停止 | Git 前置探針與 worktree 生命週期 |
| Prepare 失敗且 `PrepareFailed` 文件再次寫入失敗 | 由 operation result 的 `prepareResultWriteFailure.code=PrepareResultWriteFailed` 與 `prepareResultWriteFailure.path` 取得錯誤碼與目標路徑；`prepareResultSha256=null`，不將該路徑視為已成功保存的 Prepare 文件，修正寫入條件後重新 Prepare | 腳本介面與執行前提 |
| 結案訊息缺少識別字 | 標記 `PromptNotDelivered`，修正啟動方式後重新派遣 | RecoveryPrecheck |

### 外部程序逾時

遇到 `DispatchExternalCommandTimeout` 時，讀取進度檔最後一行確認停留的 stage。Preflight 已建立 worktree 時，以 failure receipt 依 Cleanup 的未啟動流程處理。系統不自動重試；重試前確認目錄 target 的被忽略子檔規模。

### 離線改派的執行細節

成立條件與政策見 `instructions.md`「離線改派」，各狀態的處置見 `executor-selection` skill「狀態處置」，本節補充執行細節。

- 判定證據：Dispatch 回報的 `CodexAccountsAllUnavailable` 與摘要檔 `history/<lineSlug>/dispatch-account-failover-<dispatchSlug>.json`（候選、略過原因與每次嘗試的拒絕種類），不採用各帳號最近一次派遣事件流。
- 規則來源：承接者以該工作原本的規則檔為規則來源（`reviewer.toml`、`frontend-reviewer.toml`、`contract-auditor.toml` 等），由選派入口回傳的執行者承接。
- 產出落點：降級審查依 `workflow-orchestration` skill「Sonnet 審查路徑」寫入 `review-report-claude.md`；事實查核改由 Sonnet 承接時沿用原派遣單第 7 欄的報告落點，不經 `codex-dispatch` 腳本。
- exceptions 依據：「替代方案」的依據欄含原方案失敗原因與摘要檔的絕對路徑。
- 停止：選派入口回傳 `stopped`（硬能力沒有替代者）或 `wait-reset`（顧問）時，不改派，回報使用者。
- 恢復：帳號恢復後新派遣照常使用 Codex，不回頭重做已承接的工作。

### 四種阻塞形狀的產物與交接

派工受阻時，先判定屬於下列哪一種形狀，再依對應的產物語意與交接方式處理。腳本已承擔的部分不改由人工步驟補做。

| 阻塞形狀 | 產物語意 | 操作交接 | 詳細節 |
| --- | --- | --- | --- |
| 入口不對稱 | `Dispatch` 是新派遣的唯一正式入口；Request 檔與命令列的同名欄位語意與驗證相同，兩邊不一致時以 `DispatchRequestMismatch` 拒絕 | 新的一筆派遣一律從 `Dispatch` 進入；`Preflight`、`Prepare`、`Start` 的分步入口只用於續行、恢復與測試 | 使用時機與入口選擇、Dispatch 正式入口 |
| 失敗重試污染 | worktree 建立後先寫 `status=pending` 的收據；失敗時寫 `failed`，成功啟動後更新為 `superseded`。`launch-failed` RunRecord 供稽核，該次失敗嘗試建立的 ScopePlan hash 會被清除 | 程序未啟動、未留下 dispatch worktree 且未寫出換帳號摘要檔時以同一個 `dispatchSlug` 重試，已留下 worktree 或摘要檔時改用新的 `dispatchSlug`；程序已啟動的派遣改走續行，或以新 `dispatchSlug` 冷啟動並轉移成果 | 失敗與恢復導引、續 session 與跨介面接手 |
| 外部狀態恢復 | 服務端拒絕時同一帳號不重試，未指定 `-CodexHome` 時腳本改試下一個帳號；中斷時以中斷保全檔記錄已確認單位與證據位置 | 主 Agent 需要額度數值供顯示時依 `instructions.md`「派工的額度查詢與範圍」手動查詢，advisor 啟動由使用者授權；中斷後先 `Inspect`、`Collect` 取回中斷保全檔，只交付已確認單位 | 額度與範圍契約、InterruptionSafeguard、advisor 授權請求 |
| 同名參數語意 | `-ResultPath` 只寫 CLI envelope；`-PrepareResultPath` 寫 `ai-sessions.prepare.v1` 文件；每個產物只有一個寫入者 | `Start` 只接受 `ai-sessions.prepare.v1` 文件；`Collect` 的參數取自 `Dispatch` 輸出欄位，不自行拼湊路徑 | 最短正常路徑、Dispatch 正式入口 |

`ScopePlan` hash 紀錄寫入 `<sourceRoot>\.local\ai-sessions\history\<lineSlug>\scope-plan-hash-<dispatchSlug>.json`，不同線可使用相同 `dispatchSlug`。讀取時若同線路徑不存在，才檢查舊版 history 根目錄的 `scope-plan-hash-<dispatchSlug>.json`；只有舊紀錄的 `line_slug`，或其 `root_run_id` 對應 RunRecord 的所屬線，與目前 `lineSlug` 相同時才沿用。其他線的舊紀錄不阻擋目前派遣，也不會被改寫或刪除。同一線內仍須使用不同 `dispatchSlug` 識別不同派遣。

## RecoveryPrecheck

事件流取證後，先從符合目前派工類型的 `agent_message` 取最後一則結案訊息。識別字依派工類型判定，兩種類型都必須包含 `dispatchSlug` 與 `lineSlug`，第三項識別字如下。

| 派工類型 | 第三項識別字 |
| --- | --- |
| Workflow 派工 | `dispatchLineRoot\design.md` 的絕對路徑 |
| 資源派遣 | 派遣單的絕對路徑 |

Workflow 派工沒有派遣單，以派遣單絕對路徑作為共同條件會使正常結案一律被判為 `PromptNotDelivered` 並重派。缺少任一識別字時，狀態設為 `PromptNotDelivered`，修正啟動方式後重新派遣；此狀態不計入退回次數，也不進入第 5 欄驗收缺漏的退回計數。只有 `RecoveryPrecheck` 通過後，才可進入回收三態判定。

### 回收收斂判定

回收三態套用 `instructions.md` §1.5 的共同收斂契約。一次修正連同其驗收或回歸判定為一輪，初次執行為第 1 輪。對派遣回收而言，`recovery-round` 記錄每次純技術續行增加的輪次。派遣回收的 `problem-key` 使用 `dispatchSlug` 加派遣單第 5 欄的驗收列序號，驗收列序號在同一派遣的各輪保持不變。

派遣回收的 `area-key` 為派遣單第 5 欄驗收條件所屬的目標物件檔案與節名。嚴重度映射如下。

| 循環 | `Critical` | `Major` | `Minor` |
| --- | --- | --- | --- |
| 派遣回收 | 產出遺失、證據不可追溯或錯誤同步 | 必要驗收條件不成立或回報與產出矛盾 | 單一欄位、格式或命令輸出缺漏且可直接補件 |

- 每輪逐條保存第 5 欄驗收結果、命令輸出、報告與事件證據。前輪未成立的驗收列在本輪相同 key 成立且沒有反證時標記 `closed`；本輪 key 不在前輪未成立集合且沒有同一 key 的改寫或重新命名時標記 `new-problem`。
- `dispatch-return-count` 只記錄該派遣的退回稽核資料，不作一般停止條件。`PromptNotDelivered` 是啟動契約錯誤，不增加此計數。
- 全部驗收列成立時進入下一站。前輪問題連續兩輪未閉合、同一 `area-key` 連續兩輪出現新的 `Major` 以上問題、修正需要改變需求或已確認設計，或 `recovery-round` 達到 6 輪時停止，保留證據並提出替代方向。
- 所有問題均屬純技術可解、未命中上述停止訊號，且前輪問題已閉合或本輪新問題只有 `Minor` 時自動續行。新出現的 `Major` 在尚未形成停止訊號前依純技術路徑續行。

