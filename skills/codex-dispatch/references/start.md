# Codex 派工機制：前置檢查、檔位與額度

本檔收錄派工前的 AI-PROFILE 前置檢查、檔位用途與額度快照。入口與其他階段的檔案見 `../SKILL.md`「階段路由」。

## AI-PROFILE 前置檢查

主 Agent 在建立派遣檔前，依 `ai-profile` skill 解析目標專案根目錄 `AGENTS.local.md`，並以該 skill「鍵登錄表」的「阻擋範圍」欄對照派遣內容，得出本次派遣所需的鍵。例如撰寫或修改 `*.cs`、`*.csx` 需要 `code-style.csharp`。

- 所需鍵有效時照常派工。
- 所需鍵缺少時，依 `ai-profile`「一次問完」詢問使用者（同一輪列出其他適用且缺少的鍵），寫入後再建立派遣。
- 區塊結構錯誤時，依 `ai-profile`「錯誤處置」停止並回報，不派工。
- 鍵的值錯誤時，只停止阻擋範圍涵蓋該鍵或依該鍵分流的派遣並回報；不依賴該鍵的派遣照常進行。

執行端仍以缺少鍵或格式錯誤停止時，主 Agent 先補齊或修正，再以新的派遣重新執行；此停止不屬純技術補件。

## 檔位用途

本 Skill 使用四個語意檔位，派遣檔的 `profile` 取自選派入口輸出的 `executor.profile`，腳本不依任務類型自動選用。各檔位的實際 model、effort 與其餘設定由登錄表 `profileSettings` 產生，產生檔經帳號目錄的連結以 `<CodexHome>/<檔位>.config.toml` 讀取，各設定檔均可保留 `[agents]` 區段，規則層只傳遞語意檔位名稱。

| 檔位 | 用途 |
| --- | --- |
| `review` | Codex `Reviewer` 審查（`type=review`），不依檔數或規則檔與否分層 |
| `scan` | 測試（煙霧驗證取證，`type=test`），目前由 `scripts/Invoke-CodexRun.ps1` 發動，以 MCP 工具臨場操作，見 `run.md`「測試取證（test）」；執行者與入口以登錄表為準 |
| `content` | 事實校閱與上網查證（`type=factcheck`）、影像產生（`type=generate`） |
| `advisor` | 意見評估（`type=advise`），目前由 `scripts/Invoke-CodexRun.ps1` 發動，見 `run.md`「顧問（advise）」 |

## 額度快照

`~/.ai-agents/scripts/Get-CodexQuota.ps1` 以 Codex home 的 `auth.json` 取得認證標頭，向 `https://chatgpt.com/backend-api/wham/usage` 取得即時額度，這是額度快照的唯一來源。回應必須含 `primary` 視窗；`secondary` 視窗存在時同樣換算，缺少或為 null 時表示帳號沒有週視窗。每個視窗換算為 `used_percent`、`remaining_percent`（`100 - used_percent`）、`window_minutes`、`window_days`（`window_minutes / 1440`）與 `resets_at`（Unix timestamp，秒）。`source_file` 記錄端點與請求時間，不是本機檔案路徑。不得讀取或輸出 `auth.json` 的任何欄位值；認證資料缺漏或格式錯誤時，腳本只回報欄位名稱與檔案路徑。

快照檔一律以新檔寫入。`Get-CodexQuota.ps1 -SnapshotPath` 以排他建立開檔，目標已存在時以 `QuotaSnapshotTargetAlreadyExists` 停止且不覆寫，呼叫端每次查詢使用新的檔名。

快照只代表取得當下的用量。兩個視窗由所有檔位共用，不依模型分別計量。`advisor` 單次派遣可能在數十分鐘內耗盡整個 `primary` 視窗，需要掌握時由主 Agent 在派工前後手動查詢。快照不論 `state` 為何都不改變派工範圍，也不停止派工。

兩個視窗都是固定視窗，`used_percent` 在視窗內單調累積，跨過 `resets_at` 後歸零並跳至下一格，額度不連續回補。有週視窗的帳號，`primary` 為 5 小時視窗，`secondary` 為 7 天視窗，容量相差約 33 倍，因此同一件任務在 `primary` 消耗的百分點約為 `secondary` 的 30 倍。沒有週視窗的帳號，`primary` 視窗長度不固定，曾實測為 30 天（`primary_window_minutes=43200`）。視窗長度一律以 `window_minutes` 為準。

腳本成功時依序輸出下列兩組 key-value。帳號沒有週視窗時，以單行 `secondary_window=none` 取代 `secondary_*` 八行。主 Agent 以同一次讀取的 `primary_remaining_percent` 與 `secondary_remaining_percent` 向使用者呈現額度，例如附在 advisor 授權請求中。

```text
primary_used_percent=
primary_remaining_percent=
primary_days_to_reset=
primary_window_minutes=
primary_window_days=
primary_resets_at=
primary_resets_at_local=
primary_source_file=
secondary_used_percent=
secondary_remaining_percent=
secondary_days_to_reset=
secondary_window_minutes=
secondary_window_days=
secondary_resets_at=
secondary_resets_at_local=
secondary_source_file=
```
