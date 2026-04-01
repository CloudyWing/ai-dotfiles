# 內建 Prompt 清單

| Prompt | 用途 |
| --- | --- |
| `code-review` | 對選取的程式碼進行結構化審查，從可讀性、維護性、安全性、效能等面向提供分層建議。 |
| `create-license-and-readme-link` | 自動判斷專案屬性並推薦合適的開源授權，建立 LICENSE 檔案並將其連結補入 README.md 中。 |
| `fact-check-note` | 事實校閱助手：逐條檢查內容觀念、術語與 API 版本正確性，並標註無法確認的資訊。 |
| `fix-file-encoding` | 偵測並修正檔案亂碼問題，依副檔名轉換至正確目標編碼（Big5/ANSI → UTF-8 系列）。 |
| `generate-api-doc` | 為 ASP.NET Core Controller 或 Minimal API 自動補齊 XML 文件與 Swagger Attributes，讓 OpenAPI 文件完整呈現。 |
| `generate-changelog-zh-tw` | 依據 Git 提交紀錄自動產生 CHANGELOG 區段（繁體中文），並支援 MinVer 版本號推進規格。 |
| `generate-editorconfig-by-techstack` | 自動偵測專案的技術棧 (Tech Stack) 與主流工具，產生或補齊 .editorconfig 設定（保留既有自訂偏好）。 |
| `generate-gitignore-by-techstack` | 從 github/gitignore 下載對應技術棧的 .gitignore 範本，重新命名並針對當前專案調整。 |
| `generate-readme-zh-tw` | 自動分析目前專案結構與功能，產生一份結構清晰、工程導向的 README.md（繁體中文）。 |
| `generate-unit-test` | 針對指定的 C# 類別或方法，自動產生 NUnit 單元測試骨架，包含 Arrange/Act/Assert 結構與 NSubstitute Mock 設定。 |
| `spec-doc` | 將 clarify.md 的結構化需求元素轉化為人類可讀的開發需求規格文件，供同事參考討論。 |
| `translate-zh-en` | 技術文件雙向翻譯（繁體中文 ↔ 英文），保留程式碼區塊原文，並維持術語一致性。 |
