---
name: e2e-manual
description: '可重跑 E2E 與操作手冊流程：從需求摘要的驗收條件挑出關鍵流程，撰寫 Playwright（網站）或 FlaUI 加 NUnit（WinForms、WPF）E2E，執行時自動截圖，全部通過才產出含畫面截圖的 .md 操作手冊。Use when 使用者明確要求建立可重跑的 E2E、操作手冊或手冊截圖，且專案的 project-kind 為 application 時。'
audience: agent
dispatch: split
policy.allow_implicit_invocation: true
---

# E2E 與操作手冊

本 Skill 產出涵蓋關鍵流程、可重跑的 E2E 測試，以及由 E2E 執行時自動截圖組成的 `.md` 操作手冊。`browser-smoke`、`desktop-smoke`、`integration-verify` 負責一次性驗證，本 Skill 負責留下可重跑的測試與手冊。本 Skill 只在使用者要求時執行，不自動掛入 Workflow。

## 流程總覽

1. 判定啟動條件。
2. 判定受測程式型別，選擇網站或視窗程式路徑。
3. 從需求摘要列出候選流程，由使用者勾選關鍵流程。
4. 撰寫 E2E 測試碼。
5. 執行 E2E，取回步驟紀錄與截圖。
6. 依更新條件判定，通過的功能才更新手冊。
7. 收尾清理並回報。

## 啟動條件

三個條件依序判定，全部成立才啟動。

| 條件 | 判定 | 不符時處置 |
| --- | --- | --- |
| 使用者明確要求 | 使用者本輪訊息明確要求建立可重跑 E2E、操作手冊或手冊截圖。Workflow 自動推進鏈、`integration-verify` 路由與 smoke skill 的指向句不構成要求，只能向使用者提示本 Skill | 不啟動，不詢問 |
| `project-kind` 為 `application` | 讀取專案 `AGENTS.local.md` 的 `project-kind`，讀取與缺少時的詢問依 `ai-profile` | 值為 `library` 或 `sample` 時停止，說明本 Skill 只適用 `application` 並附目前值；值缺少且使用者略過時停止 |
| 長期維護 | 首次使用時詢問一次「此專案是否長期維護？」，答「是」才繼續 | 答「否」時停止並說明，不寫入 `manual-root` |

- 判定「首次使用」以 `manual-root` 鍵為記號。該鍵已存在時視為已確認長期維護，兩項都不再詢問。該鍵缺少時，在同一輪訊息詢問「是否長期維護」與 `manual-root`，後者依 `ai-profile`「manual-root」附推薦答案 `docs/manual`，並說明專案不適合放 repo 內時可填 repo 外的絕對路徑。答「否」不落檔，下次要求時再問。
- 非互動執行端（Codex 派遣）無法詢問時，依 `ai-profile`「非互動執行端」停止寫入手冊的步驟。E2E 的撰寫與執行不寫入 `manual-root`，不受此阻擋。

## 專案型別分流

由上往下判定，命中第一列即停止。Blazor 列排在最前，同時符合 Blazor 與視窗程式條件的專案（例如 razor 元件放在獨立 Razor Class Library 的 Blazor Hybrid）走 Blazor 列。

| 受測程式 | 判定 | 路徑 |
| --- | --- | --- |
| Blazor（Server、WebAssembly、Hybrid）與 bUnit | 方案內有 `.razor` 檔，或相依 `Microsoft.AspNetCore.Components.*` | 測試碼寫法依 `blazor-testing` skill，本 Skill 不重複該 skill 的內容；截圖範圍、紀錄契約、手冊結構、更新條件與派遣分界仍依本 Skill。`blazor-testing` 不存在時停止並回報使用者 |
| 網站（非 Blazor） | 專案檔 SDK 為 `Microsoft.NET.Sdk.Web` 且沒有 `.razor` 元件，或 `package.json` 含前端框架與 dev server | 網站路徑：Playwright，細節見 [references/web-playwright.md](references/web-playwright.md) |
| WinForms 或 WPF 程式（含內嵌 WebView2 但不是 Blazor 者） | 專案檔有 `UseWindowsForms` 或 `UseWPF`，且沒有 `.razor` 檔。內嵌 WebView2 的網頁內容以 UIA 操作，UIA 讀不到需要操作的元素時停止並回報 | 視窗程式路徑：FlaUI 加 NUnit，細節見 [references/desktop-flaui.md](references/desktop-flaui.md) |
| 其他（CLI、背景服務、行動 App 等） | 不屬上列三類 | 停止並說明本 Skill 不涵蓋 |

兩條路徑共用下列通則：

- 建立 E2E 測試專案 `<ProjectName>.E2ETests`，置於 `tests/`，與 `<ProjectName>.Tests` 並列，命名沿用 `csharp-nunit`。Node 專案放在 `e2e/`。
- 命名測試類別為 `<Feature>E2ETests`，加 `[Category("E2E")]`。一個測試方法對應一個流程，方法名依 `csharp-nunit` 的 `[UnitOfWork]_[StateUnderTest]_[ExpectedBehavior]`。每個步驟內依序完成操作、斷言、截圖，一個流程由多個步驟組成。
- 排除 E2E 於一般單元測試 gate 之外，以 `--filter "TestCategory!=E2E"` 執行單元測試。E2E 一次只執行一個功能的測試類別，以 `--filter "TestCategory=E2E&FullyQualifiedName~<Feature>E2ETests"` 篩選，因為 `E2E_MANUAL_STAGING` 只對應一個功能。
- 閘門 `E2E_RUN=1` 放在 E2E 命名空間根的 `[SetUpFixture]` 的 `[OneTimeSetUp]`，以 `Assume.That` 檢查。未設定時整個命名空間標為 Inconclusive，在任何測試類別的基底 `[SetUp]` 啟動瀏覽器或受測程式之前就停止，避免不帶 filter 的 `dotnet test` 啟動瀏覽器或視窗程式。
- 限定受測目標為本機或測試環境，遇到正式環境 URL 或正式資料來源時停止並回報。
- 回報受測程式缺少的接縫（可覆寫的資料位置、測試帳號、穩定定位），停止等待使用者決定，接縫議定依 `csharp-nunit`「測試接縫需先議定」。
- 套用 `integration-verify`「資料異動安全規範」於會寫入資料的流程。
- 限制 E2E 只在必要操作時影響使用者，因為使用者可能同時在使用電腦。操作一律用 UIA pattern 或 CDP，不移動真實游標或鍵盤；受測程式以測試模式啟動，不搶前景，也不以最小化迴避；需要真實輸入或前景的測試標 `[Category("RealInput")]`，操作後立即還原焦點，並在回報註明；網站以 headless 執行。
- 取得使用者當輪明確同意後，才新增 NuGet、npm 套件或下載瀏覽器，這些屬安裝相依性。

## 關鍵流程選取

1. 讀取 `<work-root>/.local/ai-sessions/handoff/<lineSlug>/requirement-summary.md`。`lineSlug` 取自呼叫端 `LineContext`，須符合 `^[a-z0-9]+(?:-[a-z0-9]+)*$`，並與同線 `line.json` 的 `line-slug` 相符。
2. 列出候選流程。來源為需求摘要的「驗收方向」，以及程式面與功能面項目表格「內容」欄中描述使用者可觀察行為的驗收條件。每個候選含編號、流程名稱（動詞加對象）、來源需求編號，以及起點到終點的一句話。
3. 以表格呈現並請使用者勾選，欄位為勾選框、流程、來源、功能（建議歸入的功能名稱，即手冊檔名）。主要路徑與誤操作後果嚴重者標示「建議勾選」並附一句理由，勾選仍由使用者決定。
4. 撰寫 E2E 只針對勾選的流程。未勾選者不撰寫，也不入手冊。
5. 以使用者確認後的表格決定功能歸屬，一個功能對應一份手冊。

需求摘要不存在、讀取失敗或沒有任何驗收條件時停止，回報缺少的項目。使用者可改在對話中逐條口述流程，口述內容視為候選來源，仍走第 3 至 5 步。候選只來自需求摘要或使用者口述，不從程式碼、diff 或畫面推導。

## E2E 撰寫與執行通則

| 項目 | 網站路徑 | 視窗程式路徑 |
| --- | --- | --- |
| 工具 | Playwright | FlaUI 加 NUnit |
| 專案 | `tests/<ProjectName>.E2ETests`，.NET 專案用 `Microsoft.Playwright.NUnit`；Node 專案用 `@playwright/test` | `tests/<ProjectName>.E2ETests`，FlaUI 的 UIA 實作 WinForms 先用 UIA2、WPF 先用 UIA3 |
| 受測程式啟動 | 沿用專案既有 script 或已執行的服務，基底位址由 `E2E_BASE_URL` 傳入 | 由測試啟動 exe，生命週期規則見 [references/desktop-flaui.md](references/desktop-flaui.md) |
| 截圖工具 | Playwright 的 page screenshot | PrintWindow（`PW_RENDERFULLCONTENT`）擷取視窗內容 |
| 細節 | [references/web-playwright.md](references/web-playwright.md) | [references/desktop-flaui.md](references/desktop-flaui.md) |

## 截圖

- 產生時機：E2E 執行時，由測試在每個步驟的斷言通過之後呼叫 `ManualRecorder` 自動產生。截圖只來自這個時機，不在斷言之前截，不手動補截，也不事後以其他工具補圖。
- 截圖範圍：只截應用視窗。網站只截頁面內容，Playwright 的 page screenshot 只用於純網站，因為它不含 Blazor Hybrid 的原生外殼。視窗程式含 Blazor Hybrid 一律以 PrintWindow（flag 2，`PW_RENDERFULLCONTENT`）取得整個視窗內容，這個做法是向視窗要畫面，不受其他視窗遮擋，也不需要前景。全螢幕、多螢幕與工作列都不截。
- DPI：執行 FlaUI 的測試程序在第一個 UI 呼叫之前宣告 per-monitor DPI-aware，做法見 [references/desktop-flaui.md](references/desktop-flaui.md)。網站路徑固定 viewport 寬 1280、高 800，`DeviceScaleFactor` 為 1。
- 資料：只用測試資料，包括測試帳號、seed 或 fixture，以及 E2E 自行建立的資料。截圖出現無法確認為測試資料的內容時，該流程不入手冊並回報使用者。
- 穩定性：固定視窗或 viewport 大小，視窗大小由受測程式的測試模式決定。停用動畫，等畫面閒置後才截。
- 檔案：PNG，檔名 `flowNN-stepNN.png`，NN 為兩位數。失敗截圖只存 staging 的 `failures/`，不進手冊。

## 步驟與截圖紀錄契約

測試把每個步驟的文字與截圖寫到 staging，Claude 端讀取後組裝手冊。完整欄位、`ManualRecorder` 介面與範例見 [references/recorder.md](references/recorder.md)。

| 項目 | 規格 |
| --- | --- |
| staging 目錄 | `<work-root>/.local/ai-sessions/scratch/e2e-manual/<功能>/`，以環境變數 `E2E_MANUAL_STAGING` 傳給測試；未設定時測試照常執行，但不截圖、不寫紀錄 |
| 截圖 | `images/flowNN-stepNN.png` |
| 流程紀錄 | `flows/flowNN.json`，欄位為 `flowNo`、`flow`、`status`（`Passed`、`Failed`、`Skipped`、`Inconclusive`）、`steps[]`（`no`、`action`、`expected`、`image`）、`failure`（無失敗為 `null`，否則含 `step`、`message`、`image`） |
| 執行前 | 執行者確認沒有 `.running` 記號後清空該功能的 staging 目錄，避免舊紀錄殘留造成誤判，再建立 `.running`（見「手冊更新條件」） |
| 執行範圍 | 一次執行只跑一個功能的測試類別，`E2E_MANUAL_STAGING` 指向該功能的 staging |

## 手冊格式

命名與落點：

- 手冊路徑為 `<manual-root>/<功能>.md`，圖放 `<manual-root>/images/<功能>/flowNN-stepNN.png`。md 以相對路徑 `images/<功能>/flowNN-stepNN.png` 引用，替代文字為該步驟的操作標題，不得為空。
- `<功能>` 為使用者可讀的功能名稱，中英文皆可。檔名與資料夾名移除 `\ / : * ? " < > |`，空白改為 `-`，不以 `.` 開頭或結尾，且在同一 `manual-root` 內唯一。
- 一個功能一個檔。流程依勾選表格的順序編為流程一、流程二。
- 讀者為使用該軟體的人。主體內容不出現 Playwright、FlaUI、Locator、NUnit 等測試術語，測試資訊只放在最後的「維護資訊」節。
- 每個步驟都含編號、操作、截圖、預期結果四項。
- `manual-root` 為相對路徑時，以 `AGENTS.local.md` 所在的專案根目錄為基準；目錄不存在時建立。
- 產出後套用 `check-markdown`。

固定結構範本：

```markdown
# <功能名稱>

本手冊說明「<功能名稱>」的關鍵操作流程。畫面截圖使用測試資料。

## 開始前

- <前置條件，例如需要的帳號角色或先完成的設定；沒有時寫「無」>

## 流程一：<流程名稱>

<一句話說明這個流程要達成什麼>

### 步驟 1：<操作標題>

操作：<使用者要做什麼，以「點選」「輸入」「選擇」等動詞開頭>

![<操作標題>](images/<功能名稱>/flow01-step01.png)

預期結果：<畫面應出現的變化>

### 步驟 2：<操作標題>

（同上）

## 流程二：<流程名稱>

（同上）

## 維護資訊

- 更新日期：<yyyy-MM-dd>
- 對應 E2E：`<測試專案>` 的 `<測試類別>`
- 重新產生：要求 `e2e-manual` 重跑該功能的 E2E
```

「操作」與「預期結果」的文字取自 `flows/flowNN.json` 的 `action` 與 `expected`，由撰寫測試的人以使用者語言撰寫。Claude 端組裝時讀圖，確認每張圖與預期結果相符。

## 手冊更新條件

以功能（一份手冊）為判定單位，每個功能獨立判定。下列條件全部成立才更新該功能的手冊：

- 該功能每個勾選流程的 `flowNN.json` 存在、可解析，且 `status` 為 `Passed`。
- 測試命令結束碼為 0，且探索到的測試數大於 0。
- 每個 `steps[].image` 指向的 PNG 存在且大小大於 0。
- Claude 端讀圖後，每張圖與該步驟的預期結果相符，且畫面只含測試資料。

任一條件不成立時，該功能的手冊 md 與 `images/<功能>/` 完全不動，並回報失敗流程，欄位為流程名稱、失敗步驟編號、錯誤訊息、failure 截圖在 staging 的絕對路徑。`Skipped`、`Inconclusive` 與缺少紀錄檔都視同失敗。

依失敗原因分流：

- 修正測試碼缺陷（定位器、等待時間）後重跑，沿用 `integration-verify`「修正迴圈」，同一問題最多修 3 次。
- 回報受測程式行為與驗收條件不符的落差給使用者，不修改受測程式。這類落差正是本 Skill 要暴露的問題。

更新程序：

1. 確認 `manual-root` 可寫入。值為空、多行、不可寫入或不可達（包含網路磁碟離線）時停止，手冊與圖不動並回報路徑。這一步早於任何備份與刪除。
2. 備份既有 md 與 `images/<功能>/` 到 `<work-root>/.local/ai-sessions/backups/<時間戳>/`。
3. 刪除 `images/<功能>/`，再以 staging 的 `images/` 取代，避免留下孤兒圖。
4. 組裝並寫入 `<功能>.md`。
5. 確認 md 內每個圖片連結都指向存在的檔案。
6. 套用 `check-markdown`。第 4 至 6 步任一失敗時由備份還原並回報。

寫入前比對讀取時的 md 修改時間，不一致時停止並重新讀取，不覆寫他人的修改。

- 限制同一功能同時只有一次執行。以該功能 staging 目錄內的 `.running` 檔為記號，執行者在清空 staging 之後建立，手冊判定完成後刪除。開始前 `.running` 已存在時停止並回報，不清空；確認是前次中斷遺留時，由使用者決定刪除。

## 派遣分界

| 工作 | 執行端 | 標註 |
| --- | --- | --- |
| 撰寫 E2E 測試碼、`ManualRecorder`、測試專案設定 | Claude subagent，預期 Sonnet | `-Type edit -E false -T true -Tags build-test` |
| 執行網站路徑 E2E（Playwright），取回 `flows/`、`images/` 與測試輸出 | Codex `scan` | `-Type test -Tags browse,build-test` |
| 執行視窗程式路徑 E2E（FlaUI） | 沙盒能力未驗證，實測前不送沙盒：由使用者在本機主控台執行，或在使用者當輪同意後由 Claude 端執行 | 不派，不呼叫選派入口 |
| 勾選流程、詢問 `manual-root`、讀圖判定、組裝手冊、套用 `check-markdown` | Claude 端 | 不派 |

- 傳入選派入口的標註為上表前兩列，可直接傳給 `scripts/Select-DispatchExecutor.ps1`，分別選出 `sonnet` 與 `codex-scan`。
- 視窗程式路徑留在本機的原因是 FlaUI 在 Codex 沙盒能否操作元件尚未實測。`desktop-smoke` 已驗證的只有 WPF 建置、`Start-Process` 啟動、`System.Drawing` 截圖與 user32 視窗位置讀取。選派入口遇到含桌面控制標籤的 `test` 會選出 Codex，因此實測並更新本表之前，視窗程式路徑不呼叫選派入口。
- 輸出視窗程式路徑的判定行 `[派工判定: 不派] FlaUI 沙盒未驗證，依 e2e-manual 派遣分界由使用者主控台或 Claude 端執行`。回報的「FlaUI 沙盒能力」欄固定寫「未驗證」。
- 網站路徑遇 Codex 離線時，選派入口回傳 `stopped`，停止並回報使用者。使用者可在本機執行同一命令後交回 `flows/` 與 `images/`；不改由 Claude 端代跑。
- 以可寫入模式派遣 Codex 執行網站 E2E，因為測試會寫出建置輸出與 staging。派遣單第 6 欄的寫入範圍列出測試專案的建置輸出目錄與該功能的 staging 目錄，其餘專案檔維持唯讀。
- 手冊只由 Claude 端寫入，Codex 派遣不觸及 `manual-root`。

## 收尾清理

- 關閉本流程自行啟動的站台、瀏覽器與受測程式。
- 保留 staging 到手冊判定與回報完成，之後由主 Agent 依 `instructions.md` 環境清理處理。

## 回報格式

```text
E2E 與操作手冊：
- 功能 / 手冊：
- 勾選流程與結果：
- 手冊更新：已更新 / 未更新（原因）
- FlaUI 沙盒能力：未驗證（僅視窗程式路徑）
- 未解決項目：
```
