# project-kind 推薦答案偵測

本檔收錄詢問 `project-kind` 時產生推薦答案的 5 步偵測順序。需要為 `project-kind` 附推薦答案時讀取，其餘情境不需要。

推薦答案只用於詢問時附上，經使用者確認才寫入。依下列順序判定，命中即停止，並把命中的依據寫成理由。

1. repo 根目錄名稱或其上一層目錄名稱含 `Sample`、`Demo`、`Example`（不分大小寫）時，推薦 `sample`。
2. 專案檔 `OutputType` 為 `Library`（或未設定且 SDK 不是 Web、Worker）、`IsPackable` 不是 `false`，且有 `PackageId`、`Version` 或 `GeneratePackageOnBuild` 任一項，同時未設定 `PackAsTool` 時，推薦 `library`。
3. 專案檔 `OutputType` 為 `Exe` 或 `WinExe`，或 SDK 為 `Microsoft.NET.Sdk.Web`、`Microsoft.NET.Sdk.Worker`，或有 `UseWPF`、`UseWindowsForms`，或 `PackAsTool` 為 `true` 時，推薦 `application`。
4. `package.json` 專案沒有 `"private": true` 且有 `main`、`exports` 或 `types` 欄位時推薦 `library`；有 `bin` 欄位，或有前端框架與 dev server 時推薦 `application`。
5. 以上皆未命中（含其他技術棧）時，推薦 `application`，理由註明「無打包與示範特徵可偵測，採預設」。

新專案尚無專案檔時只適用第 1 與第 5 項，並參考建立要求中的描述。
