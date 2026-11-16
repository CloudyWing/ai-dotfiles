# 派工（Claude 端規則）

本檔是只在 Claude 端載入的常駐規則，經 `~/.claude/rules/` 與 `instructions.md` 一同於啟動時載入。兩端共用的規則在 `instructions.md`。本檔以「」引用的條目不在本檔時，位於同目錄的其他規則檔或 `instructions.md`。

## 跨平台派工掛載點

規則層判斷是否派工，執行者由執行者登錄表選出。登錄表 `scripts/dispatch/executor-registry.json` 是執行者、受理類型、能力標籤、條件、排序值、優先條件、未完成次數上限與備援 model 的唯一來源，選派入口為 `scripts/Select-DispatchExecutor.ps1`，標註語意與狀態處置見 `executor-selection` skill。選出 Codex 執行者後，指令參數、落點、等待、事件流取證、續 session 與回收方式由 `codex-dispatch` skill 提供；選出 Claude 執行者時以 Agent 工具派生，不經 `codex-dispatch`。Codex 端的檔位用途見 `codex-dispatch` skill「檔位用途與新舊對照」，執行者與檔位的對應只存在登錄表。

### F1 派工判準

先判定工作是否留在主 Agent，再由登錄表選出執行者。Claude 端在對話、需求釐清、脈絡保管與回收覆核上具唯一可行性，這類工作不派出。

本輪工作命中某個 skill 時，先讀該 skill frontmatter 的 `dispatch` 欄位。`inline` 直接由 Claude 端處理；`delegate` 不由主 Agent 自理，依該 skill「## 任務標註」節呼叫選派入口；`split` 依該 skill 的「## 派遣分界」章節拆分。這三個值不再走下列判定順序。`either` 不指定歸屬，依下列判定順序處理。

判定依下列順序執行，命中即停止。

1. **不派清單**：對話中的系統設計與方案取捨；bug 根因假設的形成；需求釐清與需求意圖驗收；規則檔與文件的撰寫或改寫；討論脈絡的保管與判斷；帶使用者登入 session 的瀏覽器操作；Artifacts 發布；本流程自行產生的暫存清理。命中時一律由 Claude 主 Agent 處理，輸出「不派」。根因假設的形成與結論維持在主 Agent，取證可依下列判定派出。
2. **下限三題**：skill 未宣告 `dispatch`、宣告為 `either`，或本輪工作不對應任何 skill 時，主 Agent 依下列三題工作量下限判定是否仍由主 Agent 承接。三題全否時輸出「下限自理」，不進入後續判定。
3. **灰帶規則**：三題至少一題為是，但工作需要主 Agent 的對話脈絡、無法寫成任務標註交給冷啟動執行者時，會污染主 Agent context 者以 `type=survey` 呼叫選派入口，派生 Sonnet subagent 並帶入主 Agent 整理的完整脈絡；不會污染者由主 Agent 自理，輸出「灰帶→自理」。
4. **登錄表判定**：其餘三題至少一題為是的工作，主 Agent 依 `executor-selection` skill「任務標註」標上類型、旗標與標籤，呼叫選派入口，以輸出的 `dispatchLine` 作為判定行，依回傳狀態處置。診斷指令與跨檔掃描直接以 `type=survey` 進入本項，取證者的派生內容見 `executor-selection` skill「Claude 取證者派生契約」。

下限三題為：是否需要執行建置、測試或多步驟命令；目標範圍是否無法事前列舉，需由執行端自行探索；是否為跨多檔的重複性機械改動。單檔、單一關注點、無需建置或測試的樣式或文字調整屬三題全否，不因目標副檔名是程式碼檔而改判。單一命令即可完成且不寫入任何檔案的查詢同樣屬三題全否，判準是命令數與寫入行為，不是檔案涵蓋範圍。

**小型修改例外**：同時符合下列四項時，第一題「是否需要執行建置、測試或多步驟命令」視為否。

1. 目標檔案已於動手前以絕對路徑逐一列出。
2. 目標檔案不超過 2 個。
3. 預估改動行數（新增與刪除合計）不超過 60 行。
4. 驗證只需執行 1 個專案既有的建置或測試命令。

「跨多檔」指 3 個檔案以上，因此四項成立時第二、三題亦為否，輸出「下限自理」，由 Claude 主 Agent 自理，結果附驗證命令原文與原始輸出（完整 stdout、stderr 與 exit code）。任一項不符時，第一題依原文判定。

規則檔與文件的撰寫或改寫屬不派清單，即使輸入、限制、驗收條件與產出落點可完整寫成任務標註，也不交給 subagent 或 Codex。例外是結案前文件同步的一致性檢查（`-Type survey`）與最終編輯（`-Type edit -E false -T false`），由 Sonnet subagent 承接，最終編輯依責任編輯規則，程序與理由見 `workflow-orchestration` skill `references/doc-sync.md`。

**主 Agent 自理的範圍**：主 Agent 自理只限小型修改例外（判定行為「下限自理」）與灰帶規則中不會污染主 Agent context 的工作（判定行為「灰帶→自理」），兩者都不需取得使用者同意；其餘進入登錄表判定的工作一律依選派結果派出，不以理由替代派出。

**主 Agent 的派工權限**：主 Agent 派工時可依 F1 判準決定是否派工、標註任務並以選派入口選出執行者、撰寫派生 prompt 或派遣單、回收「收下／退回／升級」三態結果。主 Agent 不直接修改程式碼，小型修改例外、灰帶規則的自理與「派工後的殘餘工作」收尾除外；選出 Codex 執行者後不跳過 `codex-dispatch` skill 的機制流程。

**實作分流**：須由主 Agent 以外者執行的實作工作（`type=edit`），含 Workflow 的 Implement 階段，執行者由登錄表依 E、T 旗標選出，旗標定義見 `executor-selection` skill「任務標註」。派生 Claude 實作 subagent 前先載入 `workflow-orchestration` skill，派生契約、驗證失敗處置與回收核對見其 `references/implement-routing.md`。

**Claude 實作 subagent 隔離**：派生前以 `git status --porcelain` 區分本 Session 已知改動與他人項目，不覆寫他人未提交的改動。沒有他人項目時 subagent 直接修改來源工作樹；有他人項目且目標檔案與其無交集時，目標檔案含本 Session 未 commit 的改動則直接修改來源工作樹（隔離工作樹缺少該改動），否則使用隔離工作樹並套回成果（操作見 `references/implement-routing.md`）；目標檔案與他人項目有交集時不派生，符合小型修改例外四項者由主 Agent 自理，否則停止並回報他人項目與交集路徑。Workflow Phase 不使用隔離工作樹。

**Workflow Phase 的實作分流**：判定單位為 `design.md` 的 Phase。

1. 主 Agent 於 Design 驗收通過、寫入 `design-accepted` 檢查點時逐 Phase 以 `-Type edit` 呼叫選派入口，各輸出一行 `[派工判定]`，結果記入該檢查點「下一站」欄，不新增欄位。
2. Phase 單位的 E、T 判定依 `executor-selection` skill「任務標註」。
3. Phase 目標檔案與他人項目有交集時，停止並回報他人項目與交集路徑。
4. 整個 Workflow 由各 Phase 選派結果中排序值最大的執行者在同一次派生中依序完成全部 Phase，記為 `Developer 派工：全部 Phase=<執行者>`。理由是同一執行者做完前面的 Phase 後已理解相關程式碼，接著做後面的 Phase 較不易出錯；這個理由只在同一次派生延續脈絡時成立，因此不把 Phase 拆給不同的冷啟動執行者。
5. 執行者無法完成時依「執行者轉移」處理。轉移後的執行者為冷啟動，以 `developer-collected` 檢查點與已完成 Phase 的成果為輸入，承接剩餘的 Phase。

**執行者轉移**：同一任務有多個符合的執行者時，目前的執行者每發生一次下列情況計為一次未完成：驗收條件未通過、回收退回、審查以未閉合的 `Critical` 或 `Major` 退回、執行者自述無法完成。四種情況合併計次，以同一任務為單位，同一次回收或同一輪審查只計一次；自述無法完成同樣只計一次，不單獨觸發轉移。累計三次未完成時，以 `-Incomplete <執行者 id>:<次數>` 把同一任務內各執行者的未完成次數傳給選派入口，入口略過已達上限者並選出候選清單的下一位。依 `executor-selection` skill「執行者轉移與交接單」整理交接單後轉給下一位，不需使用者拍板，並追加 exceptions「替代方案」。沒有可選的候選且至少一位已達上限時選派入口回傳 `needs-user-decision`，此時停止並回報，由使用者決定。次數上限寫在登錄表 `maxIncomplete`。協調者把同一任務全部執行者的未完成次數保存在線層產物，每次計次後更新，接手時先讀取，呼叫選派入口時完整帶入（含已轉移走的執行者），任務收下後才重設；落點與格式見 `executor-selection` skill「執行者轉移與交接單」。目的是避免換 Session 或轉移後遺失先前執行者的次數而重選已用盡者。同一執行者不以相同條件反覆重派。執行者自述無法完成只當作一次未完成的回報，不採信其自述的原因。成因是否屬執行環境做不到或執行者缺少該任務所需的硬能力，由協調者依證據判定（原始輸出、錯誤訊息，必要時重現）；判定屬實時不計入未完成次數，依「派工後的殘餘工作」判定順序第 1 項修環境或改派；無法判定或查無證據時，照一般未完成計次。

使用者未明說由哪一端執行時，依上列判定順序處理。

所有派工的回收覆核均適用以下權限宣告：主 Agent 可自行上網查證外部事實，不受執行端平台限制；不得只讀派遣報告或接受執行端自述，也不以未執行的部分補寫結論。查證證據欄位、保存落點與查證失敗處理依 `codex-dispatch` skill 的回收契約。

「不得只讀派遣報告」的覆核對象是每條驗收條件與其證據是否相符，依 `codex-dispatch` skill 的複核政策逐條核對命令原文與原始輸出。主 Agent 只在下列情形實讀來源或重跑命令：輸出與結論不一致、輸出缺漏、回報只寫已完成，或該條涉及需求摘要的已確定實作約束與設計歧義。符合上列條件以外的來源，不因覆核而整份重讀。需實讀的來源量大時可派覆核取證助手，判定仍由主 Agent 做出（見 `codex-dispatch` skill `references/collect.md`「覆核取證助手」）。

**派工後的殘餘工作**：其中的「第 1 項」指小型修改例外。

> 派出的工作由執行端完成。回收後若有殘餘工作，依第 1 項的小型門檻（不超過 2 檔、60 行、1 個驗證命令）判定：門檻內由 Claude 收尾，並記為「派工後補做」；超過門檻就退回執行端。執行環境做不到的工作，修環境或改派其他執行者，不反覆重派。回收覆核時重跑命令不算補做。

本節的執行端泛指 Claude subagent 與 Codex 執行端。判定順序如下，命中即停止。

1. 成因屬執行環境做不到時，修環境或改派依登錄表選出的其他執行者，同一成因不以相同條件重派。成因由協調者依證據判定（原始輸出、錯誤訊息，必要時重現），不採信執行端自述的原因；無法判定或查無證據時不適用本項。
2. 殘餘工作符合小型修改例外四項時由 Claude 收尾（E=是且 T=否為 Haiku subagent，其餘為主 Agent），追加 exceptions「派工後補做」。
3. 其餘退回執行端。

「主 Agent 的派工權限」的「不直接修改程式碼」不涵蓋小型修改例外自理與本節收尾。紀錄欄位與環境成因的處置見 `codex-dispatch` skill `references/collect.md`「派工後的殘餘工作」。

### 派工的額度查詢與範圍

額度查詢只供顯示與紀錄，不作派工的放行條件，也不參與執行者選擇。主 Agent 不因額度向使用者詢問是否派工或實測，advisor 授權除外。派工腳本不自動查詢額度，由主 Agent 以 `Get-CodexQuota.ps1` 手動查詢，時點為派工前、advisor 諮詢前、結案時，以及按需查詢。查詢失敗、快照過期或視窗重設時記為 unknown，派工照常進行，不推算餘額。

派工範圍由派遣契約明確宣告，額度不改寫範圍。`ScopePlan` 只適用經 `scripts\Invoke-CodexDispatch.ps1` 發動的 Codex 資源派遣與 `advisor-consult`，經 `scripts\Invoke-CodexRun.ps1` 發動的派遣以派遣檔的 `targets` 為範圍，不使用 `ScopePlan`。最小單位固定如下。資源派遣使用派遣單第 3 欄的目標物件，`advisor-consult` 使用 evidence pack 內依宣告順序排列的問題 ID。`selected_units` 等於宣告的全部單位，執行端不得自行拆分、增加或改變 `selected_units` 與 `deferred_units`。

低額度或 unknown 都不縮小範圍、不停止執行中的派工。服務端明確拒絕（例如 usage-limit）時，執行端保存已確認成果、證據位置與未完成單位，執行狀態記為失敗，不重試，不以未執行的單位補寫結論。經 `Invoke-CodexDispatch.ps1` 發動的派工保存 `ScopePlan`，所有派工保存 usage，作為成本紀錄。

**離線改派**：執行者只分在線與離線，判定離線的唯一來源是服務端拒絕（usage-limit、401、model not supported，以及尚無 item 進度即遭服務端拒絕的其他錯誤），額度數值不參與。帳號由入口腳本依 `machine.json` `codex_accounts` 登記清單動態選擇與更換，主 Agent 不指定 `-CodexHome`；帳號檢查、換帳號與重新登入命令的處理見 `executor-selection` skill「離線與帳號判定」與 `codex-dispatch` skill `references/recovery.md`。

1. 「全數不可用」只依入口腳本的回報判定：`Invoke-CodexDispatch.ps1` 回報 `CodexAccountsAllUnavailable`，或 `Invoke-CodexRun.ps1` 回報 `CodexAccountsAllUnavailable` 或 `CodexAccountsExhausted`。
2. 全數確認不可用後，依選派入口選出的下一位處置（由同家族執行者審查或提供第二意見、改由 Sonnet 承接測試取證或事實查核，或停止回報），各狀態的處置見 `executor-selection` skill「狀態處置」。`Invoke-CodexRun.ps1` 已在結果 JSON 的 `fallback.selection` 附上選派入口的輸出，直接採用，不必重新呼叫；`Invoke-CodexDispatch.ps1` 回報後，由主 Agent 把不可用的 Codex 執行者以 `-Offline` 傳入（多個 id 以逗號連接，例如 `-Offline codex-scan,codex-content,codex-advisor`）重新呼叫選派入口。不可用的狀態不保存，下一次新的派工照常先選 Codex。
3. 依選派結果改由其他執行者承接，是登錄表比對的正常結果，不追加 exceptions；在報告或回報中註明實際執行者與原應承接者。主 Agent 不自行頂替，硬能力（桌面控制、影像產生、瀏覽器與登入測試）沒有替代者時停止並回報使用者。

### advisor consult 的不限階段掛載點

`advisor` 是意見評估角色。`advisor-consult` 是 `DispatchKind=resource` 的 evidence-only 資源派遣，可由 `Analyst`、`Maintainer` 或主 Agent 在任一站作為詢問討論的對象。適用條件是推理密集，且判斷資料可事先整理成 evidence pack；大量讀寫、掃描、建置、測試與命令執行類工作不使用 advisor。evidence pack 的內容、執行端讀取邊界、profile 拒絕條件、hash 檢查與報告落點依 `codex-dispatch` skill「Advisor consult resource dispatch」。

**諮詢分級**：諮詢依適用條件分為下列三類，執行者由登錄表依類型選出，授權要求不同。

| 類別 | 適用條件 | 類型與執行者 | 授權 |
| --- | --- | --- | --- |
| 一般第二意見 | 方案取捨的另一角度、規則條款自洽性檢查、設計疑點複審 | `type=survey`，冷啟動 Claude Sonnet subagent，輸入為問題與證據檔絕對路徑 | 不需使用者授權 |
| 高風險決策的跨家族交叉檢查 | 符合任一項即屬高風險決策。改變公開契約、資料結構或安全邊界；不可逆操作（刪除、發版、force push）；Sonnet 第二意見之間結論相左且影響 Phase 方向 | `type=advise`，Codex `advisor`；離線時改由 Sonnet 第二意見接手並標註同家族審查 | 啟動 Codex `advisor` 沿用 `[advisor 諮詢授權]` 與 `AdvisorRequestSource=user-explicit`；Sonnet 接手不需授權 |
| 事實查核 | 版本、API 行為、外部規格等須上網查證的事實 | `type=factcheck`，Codex `content`；離線時改由 Sonnet subagent 承接 | 不需使用者授權 |

advisor 只在使用者授權後啟動，以 `AdvisorRequestSource=user-explicit` 傳入。主 Agent 判斷值得諮詢時先向使用者提出請求，請求附上當下查詢到的額度供使用者判斷。請求原文固定如下，請求本身不構成授權。使用者在當下 Session 已明確授權「送顧問不必詢問」時，同一 Session 內直接以 `user-explicit` 派工；該授權不延續到其他 Session。

```text
[advisor 諮詢授權] primary 剩餘 <n>%、secondary <剩餘 <m>% 或 無週視窗>；<推理密集點與資料已整理成 evidence pack 的理由>。是否執行 advisor 諮詢？
```

授權後使用 evidence pack 的完整問題集，不依額度縮小。授權不略過 service rejection、evidence pack hash、read-only 與 process identity 檢查。
