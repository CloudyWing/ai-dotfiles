# 狀態看板（line-status-board）

在 Claude Desktop 側邊 Pane 顯示「工作總覽」，依序為 Session、派工、Codex 額度、工作線與工作目錄五個區塊。

## 安裝

`scripts/Setup-AIGlobalConfig.ps1` 會安裝並啟用此 plugin，Desktop 開新 Session 時自動開啟 Pane。不執行 Setup 時，可手動安裝：

```powershell
claude plugin marketplace add ~/.ai-agents/claude-plugins
claude plugin install line-status-board@ai-agents-local --scope user
```

已安裝的 plugin 直接讀取本 repo 的資料夾，repo 更新後新開的 Session 即使用新版，不需重新安裝。plugin 需搭配同一 repo 的腳本。

## 設定

修改設定後執行 `/reload-plugins`。

| 設定 | 用途 | 預設 |
| --- | --- | --- |
| `workRoots` | 以分號分隔的掃描位置，另會加入目前 Session 所在的 repo | 空白，使用腳本的預設位置 |
| `scriptPath` | 狀態腳本的路徑 | 空白，自動尋找 |
| `notifySessionDone` | Session 跑完與等你處理時的提醒 | 開啟 |

## 資料來源與更新

資料來自 `scripts/Get-LineStatus.ps1 -AsJson` 與 `ccd_session_mgmt.list_sessions`，每 60 秒更新一次，也可按「重新整理」，更新過程不耗用模型 token。

同一組掃描範圍在 60 秒內已由其他 Session 執行過腳本時，定時更新沿用該次結果，「最後更新」顯示該結果產生的時間，資料最舊約為兩個更新週期。按「重新整理」或切換工作目錄時一律重新執行。

## 各區塊的行為

**Session**

- 點 Session 列會開啟該 Session。
- Session 在等你回答提問或核准計畫時排在最前面，黃點標示「等你回答」或「等你核准計畫」與已等待的時間，並跳一次提醒。
- 等你同意工具權限時同樣排在最前面，標示「等你同意」。外掛取不到「已同意」的訊號，超過 5 分鐘後無法分辨仍在等待還是已同意而工具仍在執行，因此改為灰點與「同意請求 N 分鐘前」，不計入狀態列，也不再提醒。
- 只有安裝此 plugin 的 Desktop Session 會回報等待狀態。該 Session 已封存、等待之後已有新的活動，或等待超過 24 小時時不顯示。
- Session 由執行中轉為閒置時跳一次提醒。看板載入後取得的第一次狀態只作為比較基準。

**派工**

- 列出 `scripts/Invoke-CodexRun.ps1` 執行中與最近結束的派工，含線、類型、帳號、已執行時間、最後事件時間、結果與耗時。
- 最後事件的時間只供參考，長時間推理期間沒有事件屬正常。
- 已超過總時限、且最後事件也早於總時限仍沒有結果的派工，以紅色標示為可能已中斷。紀錄帶有該次的時限設定時，總時限以紀錄為準（只帶其中一項時另一項取入口預設值），最後事件只要早於回合結束寬限（至少 60 秒）就視為沒有近期事件。
- 最後活動超過 24 小時仍沒有結果的紀錄不再列出。
- 「複製診斷明細」複製派工的完整欄位，以及每個等待項目當下讀到的 `isRunning`、`lastActivityAt` 與判定結果。

**Codex 額度**

- 帳號登入失效時顯示「登入失效」與該帳號的重新登入命令，登入由使用者自行執行。達到用量上限時顯示「已達上限」。
- 沒有週視窗的帳號，週額度位置顯示「無週視窗」。
- 各帳號另顯示最近一次派工的結果，以及 24 小時內被服務端回報不支援的 model。
- 帳號顯示「已達上限」且最近一次派工的服務端拒絕訊息含重設時間時，同列加註重設時間，例如「重設 11/22 17:21（約 4 天後）」。重設時間已過或訊息沒有重設時間時不加註。
- 重設時間取自執行紀錄的 `limit_reset_local`。只有 `Invoke-CodexRun.ps1` 寫出的紀錄帶這個欄位，加入此欄位之前產生的紀錄沒有重設時間，不會顯示。服務端訊息不含時區，視為執行機器的本地時間；服務端也沒有說明它對應哪一個額度視窗。
- 全部帳號的額度剩餘量都低於 20% 時跳一次提醒，提醒文字依各帳號的額度視窗長度標示（例如 5 小時、30 天）。同一視窗只提醒一次，視窗重設後才再提醒。已達上限與登入失效的帳號視同低於門檻；有帳號查詢失敗時不提醒。

**狀態列與清理**

- 狀態列顯示一行摘要，內容為等你處理的 Session 數、執行中 Session 數與額度最低帳號的剩餘量。
- 清理按鈕呼叫 `scripts/Invoke-WorkOverviewCleanup.ps1`，先列出可清理項目、大小與不能清的原因，按確認後才刪除。
- 看板對工作區檔案的寫入只有清理。提醒狀態、等待狀態與共用的腳本結果存在 plugin 的 store，複製按鈕寫入剪貼簿。

## 測試

`tests/` 下有 `lib.test.ts`、`render.test.tsx` 與 `dispatch.test.tsx`，從 `claude-code/testing` 匯入，以 `claude plugin test <plugin 目錄>` 執行。
