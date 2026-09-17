---
status: accepted
date: 2026-09-16
---

# ADR-0007：以 Dispatch operation 作為單一派工入口

## Context

主 Agent 原本必須自行串接 `Preflight`、before quota snapshot、`Prepare` 與 `Start` 四個操作並逐一傳遞結果路徑，實測發生以 `powershell.exe -File` 傳陣列造成位置參數錯位而覆寫來源 `instructions.md`，以及 `SessionMode` 取值、Prepare 結果檔名與 Inspect 參數多次傳錯。另外 `Start` 為非阻塞，回傳後未保留 process handle 也未將 launcher 的結束碼落檔，而 `Inspect` 將 `ProcessExitCode` 列為必要參數，因此以背景方式發動的派遣無法執行 `Inspect`，連帶產不出 `CalibrationObservation`。

## Decision

在 `Invoke-CodexDispatch.ps1` 新增 `-Operation Dispatch`，只接受一份 `ai-sessions.dispatch-request.v1` request JSON，內部依序完成 Preflight、before snapshot、Prepare 與 Start，輸出單一 `ai-sessions.dispatch-result.v1` 結果檔，陣列一律經 JSON 傳遞。Dispatch 另將 launcher 的結束碼寫入 `history` 的 sidecar 並登記於結果檔的 `inspect_binding`，`Inspect` 接受該 sidecar 作為 `ProcessExitCode` 來源，命令列顯式傳入時必須與其一致。既有七個 operation 的 ValidateSet、欄位驗證、執行路徑與四段手動鏈結全部保留，Dispatch-only 欄位只在 `operation=Dispatch` 時啟用。

## Consequences

Dispatch 是並存且建議使用的入口，`RecoveryHandoff` 與續行場景仍單獨呼叫 `Start` 與 `Inspect`，不因新入口而失效。Preflight、before snapshot 或 Prepare 失敗時結果檔記 `process_started=false` 且不呼叫 Start，Start 在行程已啟動後的失敗沿用原有證據並標為 `failed_stage=start`，不誤報為未啟動。結束碼落檔後，背景派遣才能走完 `Inspect`，ADR-0008 的校準樣本累積才會在實務上生效；已排除的替代方案為另建獨立腳本與以 Dispatch 取代舊入口。
