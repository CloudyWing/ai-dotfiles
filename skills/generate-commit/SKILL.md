---
name: generate-commit
description: '依據 Git Diff 產生符合規範的 Commit 訊息，含過渡檔案過濾與拆分建議。當使用者要求提交變更或產生 commit 訊息時使用。'
audience: human
dispatch: inline
policy.allow_implicit_invocation: true
---

# 產生 Git Commit 訊息

當使用者的意圖是「建立一個 git commit」時，無論措辭為何，都必須透過本技能執行，不得直接用 Bash 執行 git 指令。涵蓋但不限於以下語意：

- 明確提及 commit：「幫我 commit」「commit 一下」「commit 這些變更」「建立 commit」「產生 commit 訊息」。
- 提交動作：「幫我提交」「把這些提交上去」「存成一個版本」。
- 詢問 commit 訊息寫法：「commit message 怎麼寫」「這段變更的 commit 訊息」。

## 執行步驟

### 0. 檢查 git-workflow 註記與 commit 落點

1. 非 Git 專案跳過步驟 0 與步驟 4，其餘流程不變。
2. 依 `git-workflow` skill「git-workflow 註記與模式載入」確認專案的 `git-workflow` 註記存在且有效。缺少或無效時停止，不 commit。
3. 依已載入模式檔的「commit 落點」檢查目前分支，不允許時停止回報。`HEAD` 為 detached 時停止。
4. 全部通過後進入步驟 1。

### 1. 取得全量變更（強制）

在產生 commit 訊息前，**必須**先看過真實的變更內容，不得僅憑對話記憶：

1. 執行 `git status --short` 一次掌握所有變更（staged、unstaged、untracked 一併呈現）。
2. 對**所有**有變更的檔案逐一取得實際差異（追蹤中的檔案用 `git diff HEAD -- <file>`，untracked 檔直接讀內容），不得因「檔名已能說明意圖」而略過。不分檔案是否已 staged，全部都要看。repo 還沒有任何 commit（`git rev-parse --verify -q HEAD` 沒有輸出）時，`HEAD` 不存在，已 staged 的檔案改用 `git diff --cached -- <file>`，未 staged 的改動用 `git diff -- <file>`。
3. **若無任何變更**，告知使用者目前沒有可 commit 的內容，流程終止，不產生 commit 訊息。

**此規則只約束「訊息措辭」，不約束「commit 範圍」。** Subject 與 Body 中對「改了什麼」的描述只取自 `git diff` 的實際輸出，不依對話或記憶補上 diff 以外的變更。對話上下文僅可用於補充 Body 中讀 diff 無法得知的資訊，即動機說明（為什麼改）、限制、後續條件與 Body Rules「必填內容」所列的項目，且須與當次 diff 直接關聯；若無把握，略去即可。Body Rules「必填內容」所列的情況不適用略去，依該節取得內容。

### 2. 判定 commit 範圍（預設全包，減去雜訊）

預設將**所有實際變更**納入本次 commit，再扣除雜訊，而非只挑對話提過的檔案：

- **高信心雜訊自動排除**：`*.bak`、`*.tmp`、`CONTEXT.local.md`、明確的除錯或一次性暫存腳本，直接不納入，不需逐一詢問。被自動排除的項目須在最後一併列出，讓使用者可推翻。
- **模糊檔案才提示確認**：無法判定是否為過渡產物時，列出並請使用者裁決，不自行決定。
- **對話未提及不等於要排除**：只要某變更的內容與本次工作主題一致，即使對話沒談到也一律納入並如實描述。對話只決定 Body 中讀 diff 無法得知的資訊怎麼寫（範圍見步驟 1），不決定「該 commit 哪些檔」。
- **手動 staged 是縮範圍的訊號，但不可默默丟**：若使用者已自行 stage 一個子集，視為刻意指定範圍；仍須列出未 staged 的相關變更並問一句是否一併納入，不得直接忽略。

### 3. 評估是否拆分 Commit

依「語意關聯」判斷：

1. 所有變更圍繞同一主題（功能、修正、重構）→ **單一 commit**，進入步驟 4。
2. 變更明顯涵蓋兩個以上**不相關**主題，且可依檔案切開（無單一檔案橫跨多主題）→ 建議**檔案級拆分**，輸出拆分計畫後依序執行。
3. 使用者選擇不拆分 → 合併為單一 commit，標題涵蓋主要變更。

**hunk 級拆分**（同一檔案內含不相關主題、需 `git add -p` 逐塊 stage）成本高且需使用者來回操作，**僅在使用者明確要求時才執行**，預設不主動提出。

檔案級拆分計畫格式：

```text
建議拆分為 N 個 commit：

Commit 1：<commit message>
  - file_a.cs
  - file_b.md

Commit 2：<commit message>
  - file_c.cs
```

### 4. 判定 fixup 目標

對每一組要 commit 的檔案，判定修正對象是否為尚未推送的 commit。與步驟 3 的拆分並用時，每組各自判定。

- 取 `rangeBase`：依 `git-workflow` skill「整理流程」的 `rangeBase` 表，由目前分支決定。無法解析時（含參照與目前分支的共同祖先不只一個）視為無候選。
- 取候選範圍 U：`git rev-list <rangeBase>..HEAD --not --remotes --no-merges`。
- 取每個已追蹤檔案 f 的最近修改者：`git log -1 --format=%H --no-merges <rangeBase>..HEAD --not --remotes -- <f>`。未追蹤的新檔沒有最近修改者。
- 由最近修改者決定目標 `T(f)`。最近修改者的第一行不以 `fixup! `、`squash! ` 或 `amend! ` 開頭時，`T(f)` 是最近修改者本身。第一行符合 `fixup! <40 碼完整 SHA>` 格式時，`T(f)` 是該 SHA 所指的 commit，使新的修正與既有的修正指向同一個目標。沒有最近修改者時 `T(f)` 為空。
- 任一檔案符合下列任一情況時，該組改為一般 commit，type 依「分類判定基準」，並說明原因，不進入下表。目的是避免新的修正接在以主題比對或目標不明的修正之後，跟著它收進另一筆 commit。
  - 最近修改者的第一行以上述三種前綴開頭，而不符合 `fixup! <40 碼完整 SHA>` 格式，例如以主題指定目標的舊 `fixup!` commit。
  - 最近修改者是符合格式的 `fixup!` commit，而它不屬本線。
  - 該 SHA 所指的 commit 不在 U，或其第一行以上述三種前綴開頭。

| 條件 | 處置 |
| --- | --- |
| U 為空，或所有 `T(f)` 為空 | 一般 commit，並說明原因（沒有未推送的修正對象，或無法判定是否已推送） |
| 任一 `T(f)` 指向不屬本線的 commit | 一般 commit，type 依「分類判定基準」，並說明該目標屬其他線或歸屬無法確認 |
| 所有檔案的 `T(f)` 都是同一個 SHA X，且 X 屬本線 | 自動建立以 X 為目標的 `fixup!` commit，不詢問 |
| 有多筆候選，即 `T(f)` 指向不同 SHA，或部分檔案有 `T(f)`、部分為空 | 詢問使用者：依目標拆成多筆 `fixup!` commit、選定單一目標，或全部改為一般 commit |
| 修正對象已推送，即最近修改該檔的 commit 不在 U | 一般 commit，type 依「分類判定基準」 |

- 本線的 commit 指本線協調者建立或收下的 commit，含交接前的協調 Session 所建立者。無法確認歸屬的 commit 視為不屬本線。目的是避免修正在整理時被收進其他線已覆核的 commit。
- 上表由上而下判定，命中即停止。
- 建立前以 `git rev-parse --verify X^{commit}` 取得目標的 40 碼完整 SHA，失敗時重新判定。
- `fixup!` commit 的訊息第一行固定為 `fixup! <目標的 40 碼完整 SHA>`，SHA 之後不接其他文字。空一行後以目標 commit 的主題作為 Body，供閱讀歷史時辨識目標。訊息以 `git commit -F` 傳入，不使用 `git commit --fixup`。這種訊息不套用 Type Whitelist、Subject Rules 與 Body Rules。
- autosquash 依第一行的 SHA 找到目標，範圍內有主題相同的 commit 時仍收進指定的那一筆。目標的第一行一律不以 `fixup! `、`squash! ` 或 `amend! ` 開頭。同一目標有多筆修正時，每一筆都直接指向該目標，autosquash 依建立順序把它們收進目標。
- 目標被改寫後 SHA 改變，autosquash 找不到目標。收合時機與找不到目標時的處理依 `git-workflow` skill `references/history-rewrite.md`「整理流程」。
- hook 拒絕時回報 hook 輸出並停止，禁止以 `--no-verify` 略過 hook。
- 完成後輸出目標 SHA 與主題，並說明該 commit 會在 `git-workflow`「整理流程」收進目標。

判定完成後進入步驟 5。

### 5. 執行 Commit

步驟 4 判定為 `fixup!` 的組別使用步驟 4 規定的訊息，不依下方規範產生訊息，staging 規則不變。

確定範圍後，**先 stage 範圍內的檔案**（`git add <files>`），再依下方規範產生訊息並 commit，不需另外詢問確認。Body Rules「必填內容」的資訊不足是例外，依該節詢問；「條列數量」的重新評估在 commit 前進行，不詢問使用者，拆分計畫依步驟 3 輸出後直接執行：

- **單一 commit**：stage 範圍內檔案後執行 `git commit`。
- **檔案級拆分**：依序「stage 該組檔案 → commit」，逐組完成。
- **hunk 級拆分（僅使用者要求時）**：輸出拆分計畫後暫停，請使用者以 `git add -p` 完成 staging 並回報，再執行對應的 commit。

**訊息傳遞方式（強制）**：含 Body 的多行訊息一律以 `git commit -F` 從檔案或 stdin 讀取，逐字保留換行與空行。不得用多個 `-m` 逐行傳遞；git 會將每個 `-m` 視為獨立段落並在段落間插入空行，使 Body 的條列之間出現多餘空行。

- PowerShell：用單引號 here-string 接 `git commit -F -`。
- Bash：用 here-doc 接 `git commit -F -`，或先將訊息寫入暫存檔再以 `git commit -F <檔案>` 提交。

Commit 執行完畢後，輸出最終的 commit 訊息內容（含本次自動排除的檔案清單），供使用者確認是否需要至 git 調整。

---

## Commit 訊息規範

### Header Format

**Pattern**: `<type>([scope]): <subject>`

#### 非 type 訊息

下列兩種訊息使用固定格式，不屬 Type Whitelist。其他訊息一律依 Pattern。

- `fixup!` commit：第一行為 `fixup! <目標的 40 碼完整 SHA>`，見步驟 4。
- merge commit：固定為 `Merge branch '<分支>'`，只用於 `git-workflow` 的 `release-flow` 合併前流程，以 `git merge --no-ff -m` 傳入。

Type Whitelist 維持下列九項。

#### Type Whitelist

- `feat`: 新增過去不存在的功能或能力。
- `fix`: 修正既有功能的錯誤，使曾經正確、後來故障的行為恢復正常。
- `refactor`: 程式碼重構，對外可觀察行為不變。
- `style`: 格式調整（如括號位置、分號，不影響邏輯）。
- `docs`: 僅文件異動。
- `perf`: 在行為不變的前提下改善效能（不含行銷詞彙）。
- `ci`: CI 設定與腳本異動（如 GitHub Actions, GitLab CI, scripts）。
- `test`: 新增或修正測試。
- `chore`: 建置流程、相依性套件更新、雜項（如 .gitignore）。

#### 分類判定基準

`feat` / `fix` / `refactor` / `perf` 的判定，**以可觀察行為的變化為準，不以變更動機為準**。

**Tie-breaker（動機 vs 行為）**：當變更的動機是「解決某個問題」，但達成手段是**新增一條過去不存在的程式路徑**時，以「能力是否為新增」為準歸 `feat`，不因動機像在補洞就歸 `fix`。唯有該行為**曾經正確運作、後來才故障**（屬回歸修復）時才歸 `fix`。

判定範例：

- 為結帳流程加入折價券套用 → `feat`（新增過去不存在的能力）。
- 修正訂單金額在特定幣別下的計算錯誤 → `fix`（既有行為故障後恢復）。
- 將使用者登入驗證邏輯抽成獨立服務、對外行為不變 → `refactor`（只動內部結構）。
- 商品列表查詢改批次載入以消除 N+1、結果相同 → `perf`（行為不變、效能改善）。

#### Scope Rules（建議省略）

- **預設省略**：Scope 為非必填項目，對於多數一般性修改，**強烈建議直接省略**。
- **白名單機制**：若確實需要說明影響範圍，僅允許填寫**專案的第一層目錄名稱**（依當前專案結構判斷，如 `src`, `tests`, `docs` 等）。不在專案目錄結構內的名稱一律不寫 Scope。
- **禁止隨意創造**：不接受 `all`, `update`, `config` 等無明確邊界的無效 Scope。

#### Subject Rules

- **Language**: **台灣用語正體中文 (Traditional Chinese, Taiwan)**。
- **Style**: **命令式動詞開頭**（例如：新增, 修正, 移除, 重構）。
- **Length**: 不限制長度，以完整表達變更重點為優先。
- **Forbidden**:
  - 結尾不加句號。
  - 避免使用模糊字眼（如「更新程式碼」、「修改檔案」、「調整邏輯」），必須具體說明變更內容。

### Body Rules

- **Trigger**: 下列任一情況成立時生成，其餘情況不寫 Body。前兩項在標題已能充分說明變更時不成立，即使涉及多個檔案亦無需 Body；第三項只看必填內容是否已寫在標題，標題說明了改動而沒有寫出必填內容時仍須生成。
  - 變更邏輯複雜。
  - 包含 Breaking Change。
  - 屬「必填內容」所列的情況，且該內容未寫在標題。
- **Format**:
  - Header 與 Body 之間空一行。
  - 使用連字號 `-` 加一個空格作為條列點。
  - 每一點條列**必須**以句號 `。` 結尾。
  - 描述保持客觀簡潔，不解釋實作細節。

#### 內容

Body 寫下列兩種資訊。

- 改完後的行為、邊界條件與失敗時的處置。
- 讀 diff 無法得知的原因、限制與後續條件，例如上線前須先完成的操作。

只陳述新增、刪除或修改了哪個類別、常數、方法或檔案的句子不寫，這些內容讀 diff 即可得知。判別方式是把句子裡的識別字與檔名拿掉，剩下的文字沒有行為、原因或限制時，該句不寫。

- 寫：「查無訂單時回傳空清單，連線失敗仍拋出例外。」
- 不寫：「新增 OrderNotFoundMessage 常數。」

#### 必填內容

下表的情況必須寫出對應內容。內容已寫在標題時視為已滿足，Body 不重複。

| 情況 | 必填內容 |
| --- | --- |
| 暫時停用、關閉或略過某項功能或檢查 | 原因與恢復條件 |
| 還原或重新啟用先前停用的功能或檢查 | 當初停用的原因是否已排除，或恢復條件是否已滿足 |
| type 為 `fix` | 修正前使用者或系統觀察到的症狀 |

- 必填內容依序取自當次 diff（含其中的程式碼註解）、對話，以及同線的需求摘要、fix-plan 與設計文件。
- 上列來源都沒有時，直接與使用者對話的 Agent 詢問使用者一次，該組等到回覆後才暫存與 commit。該組的檔案已暫存時，先以 `git restore --staged <檔案>` 取消，使其他組的 commit 不會帶入這些檔案，其中使用者在本流程開始前自行暫存的檔案在輸出註明，其他組照常進行。使用者表示不提供或不清楚時照常 commit，並在完成後的輸出註明缺少的項目。
- 無法向使用者提問的執行端不詢問，照常 commit，並在輸出註明缺少的項目。
- 不自行推測或編寫原因、恢復條件與症狀。取不到必填內容時不寫該項，Body 是否生成改依 Trigger 的其他兩項判定。

#### 條列數量

Body 依「內容」去掉不寫的句子後仍有五條以上時，在 commit 前回到步驟 3 重新評估一次，確認這些條列是否涵蓋兩個以上不相關的主題。目的是避免單筆 commit 混入多個不相關的主題，使 Body 成為變更清單。重新評估只做一次，拆分後各組的 Body 不再觸發本節，結果依下表處置。

| 重新評估的結果 | 處置 |
| --- | --- |
| 屬同一主題 | 維持單一 commit，Body 不刪減，在完成後的輸出註明已重新評估並判定為同一主題 |
| 涵蓋不相關主題，且可依檔案切開 | 先以 `git restore --staged <檔案>` 取消步驟 5 已暫存的檔案，使用者在本流程開始前自行暫存的檔案比照取消並在輸出註明，再依步驟 3 的檔案級拆分處理，各組依步驟 4 判定後逐組暫存與 commit |
| 涵蓋不相關主題，但只能以 hunk 級拆分切開 | 依步驟 3 不主動拆分，維持單一 commit，並在完成後的輸出說明涵蓋的主題 |

`fixup!` commit 與初始 commit 不適用本節。

### 初始 commit

初始 commit 指 repo 的第一筆 commit（`git rev-parse --verify -q HEAD` 沒有輸出），以及 `git-workflow` 的 `release-flow`「壓縮成初始 commit」產生的無父 commit。初始 commit 一律使用下列固定格式，不套用 Body Rules 的 Trigger 條件、「內容」「必填內容」與「條列數量」。

```text
feat: 建立 <專案名稱>

- <一句話說明這個 Repo 的用途>。
```

- `<專案名稱>` 使用 repo 根目錄名稱，或專案已宣告的產品名稱。
- 用途說明寫這個 Repo 解決的問題或提供的能力，資訊不足時詢問使用者，不自行推測。
- 主題不寫版號，版號由標籤記錄。

### Forbidden Footer

- **禁止加入 `Co-Authored-By`**：commit 訊息不得附加任何 `Co-Authored-By:` 行，包含 AI 工具的署名。
- **禁止加入執行摘要**：不得在 commit 訊息任何位置附加 AI 產生的執行狀態資訊，包含但不限於測試通過數、任務完成進度、建置結果等（如「共執行 X 個測試」、「已完成 N 項」、「Build 成功」）。Commit 訊息僅描述程式碼變更本身。

### Core Principles

- **Atomic Focus**: 標題應反映最核心的邏輯變更。
- **Objective Language**: 描述使用客觀、具體的詞語，不使用「大幅提升效能」、「改善使用者體驗」、「顯著最佳化」等主觀修飾語。

## 範例

**✅ 正確範例：**

```text
feat: 新增訂單匯出的日期區間篩選

- 起訖日期皆為選填，只填起日時匯出至當日。
- 區間超過 90 天時回傳 400，不進行匯出。
```

```text
fix: 修正結帳頁重新整理時未重新檢查折價券效期

- 結帳頁重新整理後，已過期的折價券仍從合計扣除，訂單金額低於應收金額。
```

```text
chore: 暫時停用每日對帳排程

- 對帳服務更新憑證期間排程會連續失敗並寄出警示，憑證更新完成後還原。
```

**❌ 錯誤範例：**

```text
# 模糊動詞 + 不必要的自創 Scope
fix(all): 修改程式碼

# 行銷用語 + 主觀修飾
refactor(prompts): 大幅提升 Prompt 效能與使用者體驗

# 結尾加句號+大陸用語
feat: 添加新的配置項。

# Body 只複述 diff 看得出來的改動
feat: 新增訂單匯出的日期區間篩選

- 新增 OrderExportFilter 類別。
- 修改 OrderExportController。

# 暫時停用卻沒有原因與恢復條件
chore: 暫時停用每日對帳排程

- 移除啟動程式中對帳排程的註冊。
```
