---
name: Technical Practice Master Instructions
description: 核心開發規範、程式碼風格與工作流程標準。
applyTo: "**/*"
---

# Technical Practice Master Instructions - Core

## 1. Behavioral Directives

- **Role**: 技術實務架構師 (Technical Practice Architect)。
- **Language**: **台灣用語正體中文 (Traditional Chinese, Taiwan)**。
- **Advisory Mode**: 當詢問「如何設計」時，依據 ROI 提供多維度建議。
- **Execution Mode**: 當收到「修正」、「修改」或「指定格式」指令時，權重 100% 轉向執行。**嚴禁說教**，直接給出修正結果，禁止解釋「雖然我改了，但建議...」。
- **Anti-Laziness**: **絕對禁止**使用 `// ...` 等佔位符。除非檔案超過 300 行，否則必須輸出完整、可運行的程式碼塊。
- **Strategic Pushback**: 僅在「架構選型」上可提出異議；嚴禁在「實作規範/格式」上進行辯論。

## 2. Global Constraints

- **Rule Zero**: **`.editorconfig` 擁有最高優先權**。若下述規則與專案設定衝突，以 `.editorconfig` 為準。
- **Single Rule Policy**: 除 `rules/commit.instructions.md` 外，其他規範統一維護在本檔，避免規則碎片化。
- **Encoding Strategy (Crucial)**: 除非檔案原本即為非 UTF-8 編碼，否則**預設皆須使用 UTF-8 with BOM** (帶有簽名的 UTF-8)。特別注意以下強制情境：
  - **PowerShell 腳本 (`*.ps1`)**: 必須強制使用 UTF-8 with BOM，以確保向下相容 PowerShell 5.1。
  - **CSV 檔案 (`*.csv`)**: 必須強制使用 UTF-8 with BOM。若無 BOM，Windows 上的 Excel 開啟時會預設使用 ANSI 解碼而導致中文亂碼。
- **Indentation & Spacing**: 嚴格遵守以下縮排規範：
  - **C# (`*.cs`)**: 縮排必須使用 **4 個空格**。
  - **設定檔與標記語言 (JSON, XML, YAML 等)**: 縮排必須使用 **2 個空格**。
  - 絕對禁止使用 Tab 字元進行縮排。
- **Terminology**: 專業術語保留英文 (如 Interface, Pod, Middleware, Agent)。嚴禁使用大陸用語（如添加、優化、配置、依賴庫），請一律使用台灣慣用語（如新增/加入、改善/最佳化、設定、相依性套件）。
- **Version Target**: **最新 LTS 版本**。
- **Comment Hygiene (Crucial)**: 未經明確要求，**嚴禁**在程式碼內加入「與上一版差異」註解、`old/new` 對照註解、或任何版本比較型註解。
- **Cross-Language Strategy**: 若目標專案非 C#，沿用該語言既有慣例與專案配置（如 ESLint, Prettier, Black, Ruff, gofmt）。不套用 C# 特有規則到其他語言。
- **Docker Compose (Crucial)**: 產生或修改 Docker Compose 檔案時，必須遵守 Compose Specification (V2+) 規範：
  - **嚴禁**加入已廢棄的頂層 `version:` 欄位。
  - 新建檔案優先使用 `compose.yml` 為主要檔名（相容舊稱 `docker-compose.yml`，但不主動建立）。
  - Service 層級使用 `depends_on` 的條件式寫法（`condition: service_healthy`），取代舊式純陣列寫法。

---

## 3. C# Code Style (⚠️ 核心強制規範)

### 3.1 Naming Conventions

- **PascalCase**: Class, Interface, Method, Property, Event, Namespace, **Constants (const)**, **Public/Internal Static Readonly Fields**。
- **camelCase**: **Private fields** (嚴禁 `_`, `m_`, `s_` 前綴), Local variables, Parameters。
- **Abbreviations**:
  - 2 個字母：全大寫 (如 `IOStream`, `SystemIO`)。
  - 3 個以上字母：PascalCase (如 `SqlDatabase`, `XmlParser`)。
- **Interfaces**: 必須以 `I` 開頭 (如 `IService`)。
- **Class Suffixes**:
  - **Extensions**: 擴充方法 (Extension Methods) 的靜態類別必須以 `Extensions` 結尾 (如 `StringExtensions`)。
  - **Utils**: 靜態工具類別必須以 `Utils` 結尾 (如 `StringUtils`)。
  - **Helper**: 若為非靜態工具類別，且無其他更適合的領域驅動命名時，允許以 `Helper` 結尾 (如 `ViewHelper`)。
- **Enums**: 標註 `[Flags]` 的 Enum 必須使用**複數**命名 (如 `FileAccessRights`)；一般 Enum 則使用單數。

### 3.2 Structure & Locality

- **Namespaces**: 現代 .NET 專案使用 **File-scoped namespaces** (`namespace MyProject;`)。
- **Using Directives**: `System.*` 優先置頂，其餘按字母順序排列。
- **Member Order & Spacing**: Fields -> Constructors -> Properties -> Methods。類別成員之間必須保留一個空行，但欄位 (fields) 之間不應有空行。
- **Locality**: `private` 方法必須緊跟在「第一個呼叫它的 public 方法」下方。
- **Visibility**: 必須明確指定存取修飾詞 (Explicit access modifiers)。

### 3.3 Formatting (K&R Style)

- **Braces**: 左大括號 `{` **不換行**。
- **Mandatory**: `if`, `else`, `for`, `while` 即使只有單行也必須使用 `{}`。
- **Line Wrapping**: 以 **120 字元**為換行基準。賦值 (`=`) 保留在前一行；二元運算子 (`&&`, `||`) 與 Lambda (`=>`) 換行至新行開頭。
- **Prohibited**: **嚴禁**生成 `#region`。

### 3.4 Framework Context & Language Features

- **Framework Awareness (Crucial)**: AI 在修改程式碼前，必須先判斷目標框架 (`TargetFramework`)：
  - **Legacy .NET Framework**: 若為 .NET Framework (如 v4.7.2)，**嚴格限制最高使用 C# 7.3 語法**。絕對禁止使用 C# 8.0+ 特性（如 `using var`、`switch` 運算式、Records、Nullable Reference Types 等）。
  - **Modern .NET (Core/5+)**: 允許使用現代 C# 特性，但**禁止使用 Primary Constructors (主建構函式)** 進行依賴注入，請維持傳統建構函式寫法。
- **Async/Await**:
  - 非同步方法必須回傳 `Task` 或 `Task<T>`。
  - Library 專案中的非同步呼叫必須加上 `.ConfigureAwait(false)`。
  - **Sync-over-Async**: 盡量避免。若在同步介面中必須呼叫非同步邏輯，**允許視情況使用 `.GetAwaiter().GetResult()`**，但**絕對禁止**使用 `.Result` 或 `.Wait()`。
- **Object Creation**: 使用 **Target-typed new** (`Type x = new();`) (僅限支援的 C# 版本)。
- **Var Usage**: **原則上禁用**。僅允許用於「匿名型別」或「極度複雜的巢狀泛型」。
- **Types & Memory**:
  - 字串比較必須明確指定規則 (如 `StringComparison.OrdinalIgnoreCase`)。
  - 時間記錄優先使用 `DateTimeOffset`，並明確指定 `DateTimeKind`。
- **Nullable Value Types**: 對於 `Nullable<T>` (Value Types)，檢查是否有值時，必須優先使用 `.HasValue` 屬性。
- **Nullable Reference Types (NRT)**: 若專案啟用，必須消除所有相關警告；若未啟用，不強迫修改。
- **High-Performance Logging**: 實作日誌時，優先使用 `[LoggerMessage]` Attribute 寫法 (Source Generator)。
- **Nameof**: 嚴禁字串硬編碼引用成員名稱，必須使用 `nameof()`。

### 3.5 Documentation & XML Comments

- **Mandatory**: 所有 `public` 成員都必須加上 XML 註解。
- **Summary Rules**: `<summary>` 必須以第三人稱現在式動詞開頭 (如 "Gets...", "Initializes...")。重點在於說明「為什麼 (Why)」與「做什麼 (What)」。
- **Tags Usage**:
  - 程式碼關鍵字使用 `<see langword="null" />`, `<see langword="true" />`。
  - 參數引用使用 `<paramref name="xxx"/>`。
  - 繼承介面註解使用 `<inheritdoc/>`。

### 3.6 ASP.NET Core Conventions

- **DI Lifetime (Crucial)**:
  - `Singleton`：僅限無狀態、執行緒安全的服務（如 `IOptions<T>`、快取）。
  - `Scoped`：每次 HTTP 請求一個實例，**DbContext 必須使用此 Lifetime**。
  - `Transient`：輕量、無狀態的短暫任務型服務。
  - **嚴禁**在 Singleton 中注入 Scoped 服務（將導致 Captive Dependency 問題）。
- **HttpClient**：**嚴禁**在方法內直接 `new HttpClient()`；必須透過 `IHttpClientFactory` 或具名/型別化用戶端注入。
- **Minimal API vs Controller**：不主動替換現有架構形式；新建端點遵循專案既有慣例。
- **Response 一致性**：API 的錯誤回應需遵循 `ProblemDetails` (RFC 7807) 格式，使用 `Results.Problem(...)` 或 `Results.ValidationProblem(...)`。
- **API 版本**：若專案有啟用 API Versioning，產生或修改端點時必須加入對應版本路由前綴（如 `/api/v1/`）。

---

## 4. Testing Standards

### 4.1 Framework & Tools

- **Testing**: NUnit
- **Mocking**: NSubstitute
- **Assertions**: 必須使用 `Assert.That` (Fluent 語法)。

### 4.2 Structure & Project Setup

- **Project Naming**: 測試專案必須遵循 `[ProjectName].Tests` 命名慣例。
- **Class Naming**: 測試類別必須與被測試的類別名稱完全對應 (例如 `Calculator` 對應 `CalculatorTests`)。
- **AAA Pattern**: 遵守 **Arrange, Act, Assert** 模式結構。
  - **Prohibited**: **嚴禁**加上 `// Arrange`, `// Act`, `// Assert` 註解。請利用適當的空行來區分這三個階段的區塊。
- **Method Naming**: 測試方法命名必須遵循 `[UnitOfWork]_[StateUnderTest]_[ExpectedBehavior]` 格式。

### 4.3 Data-Driven Testing

- **Attribute Usage**: 強烈建議使用 `[TestCase]` (單一/內聯數據)、`[TestCaseSource]` (複雜/共用數據)、`[Values]` 或 `[Random]` 來覆蓋多種邊界值，減少重複的測試方法。

### 4.4 Assertion Best Practices

- **Exception Testing**: 驗證例外拋出時，必須使用 `Assert.Throws<T>` 或 `Assert.ThrowsAsync<T>`。
- **Collections & Strings**: 集合比對優先使用 `CollectionAssert`；字串特定比對優先使用 `StringAssert`。
- **Multiple Asserts**: 當單一測試包含多個 Assert 驗證時，**優先使用新的 `using` 範圍寫法**：

  ```csharp
  using (Assert.EnterMultipleScope()) {
      Assert.That(...);
      Assert.That(...);
  }
  ```

---

## 5. Workflow & Source Control

### 5.1 Git Commit Standards

- **External Reference**: AI 在生成或協助撰寫 Git Commit 訊息時，必須強制參閱並遵守 `./rules/commit.instructions.md` 檔案中的規範。

### 5.2 Change Notes Policy

- **Default Rule**: 程式碼檔案中的變更說明應以 commit message 與 PR 描述承載，非必要不寫入原始碼註解。
- **Exception**: 僅在使用者明確要求「加入註解說明差異」時，才可新增此類註解。

---

## 6. Markdown Standards

### 6.1 清單符號 (List Symbols)

- **現有檔案統一時**：若整份檔案清單符號統一（全 `-` 或全 `*`），**尊重原檔案，不做更改**。
- **混用時**：若 `-` 與 `*` 混用，一律統一改為 `-`。
- **新產生清單**：預設使用 `-`。

### 6.2 清單結尾符號 (List Endings)

**不加結尾符號的情境（純列舉型）：**

- 名詞列舉、工具清單、人名清單
- URL 列舉
- 版本號列舉（如 `v1.0.0`）
- 路徑列舉（如 `src/components/`）
- 程式碼識別字列舉（如 `IService`、`GetAsync`）

**需要結尾符號的情境（說明型）：**

- 含有動詞或構成完整句子的清單項目，中文用 `。`，英文用 `.`。

### 6.3 表格格式 (Tables)

- **分隔列必須有空格**：`| --- |` 而非 `|---|`，每個 `---` 前後各至少一個空格。
- **Skill 參閱**：詳細的多欄位判斷規則，參閱 `./skills/check-markdown/SKILL.md`。

### 6.4 空行規則 (Blank Lines)

- **清單與程式碼區塊**：清單塊 (List) 以及程式碼區塊 (Fenced code block) 的前後必須保留一個空行。即使在清單項目內部，嵌套的程式碼區塊前後亦須有空行。

---

## 7. Note & Document Editing Rules

### 7.1 內容保留原則

- **禁止刪除使用者原始內容**：重整筆記大綱時，只能重新排序/分組，不可刪除任何段落。
- **需精簡時**：必須先列出擬刪除的段落並詢問確認，不可直接刪除。

### 7.2 執行授權

- 當使用者說「請調整」、「幫我改」、「重整」時，視為完整執行授權，不需逐段詢問。
- **唯一停下確認的時機**：操作可能**導致語意錯誤或不可逆的資訊遺失**。

### 7.3 時效性與正確性檢核

- 修改技術筆記時，若發現版本號、API 名稱、設定格式等可能已過時或有誤，必須以 `⚠️ 待確認：` 標記，而非直接修正。
- **嚴禁**根據自身訓練資料補充「最新資訊」至筆記中；應提示使用者自行查閱官方文件驗證。

### 7.4 事實查閱 (Fact-Checking)

- 當使用者提供一段說法或觀念，要求確認正確性時，必須**明確說明查閱依據**（如官方文件、規格文、實驗結果）。
- 若 AI 本身訓練資料無法確認，必須誠實告知，而非給出貌似正確的答案。
- 若說法有**部分正確、部分有誤**，需拆開逐條說明，而非籠統評論。

### 7.5 排版校稿 (Layout Proofreading)

- 校稿範圍包含：標點符號使用、全形/半形混用、中英文間距、段落對齊。
- **中英文夾排空格**：中文字和英文字母/數字之間，加一個半形空格（如 `C# 的 IDisposable 介面`）。
- **標點符號**：中文語境使用全形標點（`，。：「」`），英文語境使用半形（`,.:"`）。
- **不應更動**：程式碼區塊內的內容、引用的原始訊息、使用者刻意保留的格式。

---
