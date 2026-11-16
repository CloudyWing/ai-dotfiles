---
name: doc-placement
description: 'Use when 撰寫或修改會進版控的 .md 文件（README、docs、AGENTS.md、規則檔）、程式碼註解、XML 文件、commit 訊息或 PR 描述，需要判定讀者與資訊落點，或要寫入本機路徑、內部代碼、實作細節與設計經過時。'
audience: agent
dispatch: inline
policy.allow_implicit_invocation: true
---

# 內容落點與讀者判定

寫入內容前先判定讀者與資訊落點，使本機路徑、實作細節、內部代碼與設計經過只出現在適合的位置。本 Skill 判定內容該寫在哪裡、寫給誰，格式與寫法由各承接 Skill 負責。

## 寫入前三問

寫入進版控的內容前，依序回答下列三題。

1. 讀者是誰。選項為終端使用者、開發者與維護者、其他機器上的協作者、Agent、僅本機。
2. 這份資訊在其他機器與其他時間是否仍成立。
3. 這份資訊屬於「落點對照表」的哪一類。

AI-facing 但進版控的檔案（規則檔、skill）同樣適用。`.local/` 下的交接檔與報告不受限。

## 落點對照表

第一欄 ID 供 Reviewer finding 與案例核對引用。

| ID | 資訊類型 | 落點 | 進版控文件的處置 |
| --- | --- | --- | --- |
| L1 | 本機路徑、使用者目錄、磁碟位置、機器專屬設定與環境差異 | `AGENTS.local.md`、`CONTEXT.local.md`、`.local/`（不進版控） | 改寫為佔位符或相對路徑，不寫實際路徑 |
| L2 | 使用者入門：用途、安裝、使用方式、設定項、常見問題 | README、使用手冊 | 只寫讀者完成操作所需的內容 |
| L3 | 設計理由、取捨與修改經過 | `docs/adr/`（依 `adr` skill）、`design.md`、commit 訊息、PR 描述 | 不寫入 README、UI 文字與程式碼註解 |
| L4 | 實作細節與內部機制：欄位清單、格式清單、內部流程、設定檔結構、派工與 hook 的內部行為 | `docs/` 開發者文件、規則檔或程式碼本身 | README 與 UI 只留一句用途並連結 |
| L5 | 內部代碼與診斷明細：錯誤代碼、失敗原因代碼、交易或請求 ID、堆疊 | 記錄、診斷資料或報告 | 不放入 UI 文字、錯誤訊息、README |
| L6 | 顯示給使用者的文字（UI 文字、錯誤訊息） | 依 `uiux`「使用者可見文字」U1 至 U8 | 同左 |
| L7 | 其他文件已有權威版本的資訊 | 保留單一來源，其餘改為連結 | 與規則檔重複的 README 段落改連結 |

## 適用範圍與承接

每類位置只由一處承接，條文不在多處重複。

| 位置 | 判定讀者與落點 | 格式與寫法 |
| --- | --- | --- |
| `.md` 文件（README、docs、AGENTS.md、skill） | 本 skill | `check-markdown`、`doc-editing`、`writing-for-agents` |
| UI 文字、顯示給使用者的錯誤訊息 | `uiux`「使用者可見文字」 | `uiux` |
| 程式碼註解 | 本 skill（L1、L3、L4） | `csharp-comments` |
| XML 文件 | 本 skill（L1、L3、L4） | `csharp-docs` |
| commit 訊息與 PR 描述 | 本 skill（L1、L3、L4） | `generate-commit` |
| 規則層（`instructions.md`、`rules/claude/`、`agents/`） | 本 skill；規則層另依 `instructions.md` §0 排除路徑與命令配方 | `check-markdown`、`doc-editing`（僅 `.md` 檔案）、`writing-for-agents` |
| 工作產物 | `session-artifacts` | 同左 |
| 對話回覆 | 不適用 | 不適用 |

## 本機路徑機械檢查

- 本 repo 的 pre-commit 於 staged 的 `.md`、`.toml` 新增行含磁碟機絕對路徑時阻擋 commit，偵測由 `.githooks/Test-StagedDocPath.ps1` 執行。
- 已安裝 `ai-agents-hooks` plugin 的專案，Claude Code 以 Write 或 Edit 寫入進版控的 `.md` 時，若本次寫入的文字含磁碟機絕對路徑，plugin 的 doc-path hook 會提醒改用佔位符或相對路徑；只提醒，不阻擋寫入。
- 佔位符形式不算違規，例如 `<使用者>`、`<sourceRoot>`、`C:\<使用者>\...`。
- `.local/` 目錄與 `*.local.md` 不檢查。
