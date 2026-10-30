---
name: csharp-style
description: C# 程式碼風格規範：依專案 AGENTS.local.md 的 code-style.csharp 註記載入 personal、standard 或 project 風格，並收錄縮寫大小寫、泛型型別參數、成員排序、空行、換行、三元運算子等 .editorconfig 無法約束的共用細則。撰寫或修改 C# 程式碼時套用。
audience: agent
policy.allow_implicit_invocation: true
---

# C# Code Style

本 Skill 收錄 C# 風格規範中 `.editorconfig` 無法約束的部分。可由 `.editorconfig` 與內建 analyzer 約束的項目（PascalCase / camelCase 大小寫、欄位前綴、Interface `I` 前綴、file-scoped namespace、`using` 排序、存取修飾詞、大括號位置、強制大括號、空格、縮排等）一律以專案 `.editorconfig` 為準，不在此重複條列。

## 套用範圍

- **優先序**：專案有 `.editorconfig` 時，其可約束的規則為最高優先；`.editorconfig` 未設定的規則，由本 Skill 本體與「風格註記與載入」選定的參考檔提供。
- **風格來源**：每個專案只依 `AGENTS.local.md` 的 `code-style.csharp` 註記決定風格，不為判定風格而掃描鄰近程式碼。為理解功能而閱讀程式碼不受此限。
- 不主動將既有程式碼「修正」成為 Skill 的風格，以避免製造無謂的 diff 雜訊。

## 風格註記與載入

### 註記格式

專案根目錄的 `AGENTS.local.md`（Git 專案為 `git rev-parse --show-toplevel` 的目錄，非 Git 專案為 work-root）以成對的完整獨立行標記保存註記，檔案編碼為 UTF-8 無 BOM：

```text
<!-- AI-PROFILE:BEGIN -->
code-style.csharp: personal
<!-- AI-PROFILE:END -->
```

解析規則如下：

- 逐行讀取兩個標記之間的 `key: value`，鍵與值各自去除前後空白。
- 鍵只能由小寫英數、`.`、`-` 組成；值為非空的單行文字。
- 略過空行。未知鍵視為其他控制項，讀取時忽略，寫入時原樣保留。
- `code-style.csharp` 只接受 `personal`、`standard`、`project`，大小寫須完全一致。

下列任一情形停止相依工作並向使用者指出錯誤位置，不猜測選擇，不修改檔案：

- 只有單邊標記，或標記不是完整獨立行。
- 檔案內有兩個以上 `AI-PROFILE` 區塊。
- 區塊內有重複鍵、無法解析成 `key: value` 的非空行，或不合法的鍵。
- `code-style.csharp` 的值不在上列三者之內。

### 第一次詢問

`AGENTS.local.md` 不存在、沒有 `AI-PROFILE` 區塊，或區塊內沒有 `code-style.csharp` 鍵時，詢問使用者一次，收到答案前停止相依的 C# 撰寫工作。

| 專案狀態 | 判定方式 | 提供的選項 |
| --- | --- | --- |
| 新專案 | 由 `create-dotnet-project` 建立，或專案根目錄下沒有任何 `*.cs` 檔 | `personal`、`standard` |
| 既有專案 | 專案根目錄下已有 `*.cs` 檔 | `personal`、`standard`、`project` |

各選項的意義如下：

- `personal`：使用者習慣風格，對應 `~/.ai-agents/templates/.editorconfig`。
- `standard`：Microsoft 官方慣例為主的標準風格，對應 `~/.ai-agents/templates/.editorconfig.standard`。
- `project`：沿用既有專案自己的寫法，首次取樣後記錄於專案範例檔，不對應任何 `.editorconfig` 範本。

### 非互動執行端

無法向使用者提問的執行端（例如 Codex 派遣）遇到缺少註記或註記格式錯誤時，依下列方式處理：

- 停止相依的 C# 撰寫工作，不寫入註記，不猜測風格，也不改用其他註記值。
- 在報告寫明停止原因為「缺少 `code-style.csharp` 註記」或指出的格式錯誤，並附 `AGENTS.local.md` 的絕對路徑。
- 不依賴 C# 風格的其他工作照常完成。

主 Agent 依 `codex-dispatch` skill `references/start.md`「C# 風格註記前置檢查」在派工前補齊註記。

### 寫入前的本機排除

註記與 `project` 範例檔屬個人本機資料，寫入前先確認不會被團隊看到。Git 專案對 `AGENTS.local.md`，以及選 `project` 時的 `.local/ai-context/csharp-style-project.md`，逐項執行下列檢查：

1. 執行 `git ls-files --error-unmatch <path>`。命令成功代表檔案已被追蹤，停止寫入並提示使用者先處理追蹤狀態，不宣稱已隱藏。
2. 執行 `git check-ignore -q <path>`。命令成功代表已被排除，直接寫入。
3. 未追蹤且未排除時，將路徑追加至 `git rev-parse --git-common-dir` 所指目錄下的 `info/exclude`，再以 `git check-ignore -q <path>` 確認生效後寫入。此做法同時適用於 worktree。

非 Git 專案照常寫入本機路徑，並在回應中說明此專案沒有 Git 排除機制。本機排除只防止檔案進入版控，不提供存取權限控制。

### 寫入註記

1. `AGENTS.local.md` 不存在時，以 `~/.ai-agents/templates/AGENTS.local.md.template` 建立。
2. 寫入前重新讀取檔案，與解析時的內容比對；內容已變動時停止，重新讀取後再處理，不覆寫其他工作的修改。
3. 已有區塊時只插入或修改 `code-style.csharp` 一行；沒有區塊時，在檔尾追加完整區塊。區塊外內容與其他鍵全部保留。

### 依註記載入

| 註記值 | 載入的檔案 |
| --- | --- |
| `personal` | 本體，加上 `references/personal.md` |
| `standard` | 僅本體 |
| `project` | 本體，加上專案根目錄的 `.local/ai-context/csharp-style-project.md` |

規則重疊時，依序以專案 `.editorconfig`、註記所選的參考檔、本體為準。`standard` 不載入 `references/personal.md`。

### project 範例檔

選定 `project` 的那一次詢問，取樣既有專案中具代表性的 C# 檔案（涵蓋不同層級或專案的 3 至 5 個檔案；專案的 C# 檔不足 3 個時取樣全部檔案），寫入 `.local/ai-context/csharp-style-project.md`。之後的開發只讀本體與此範例檔，不再取樣。

- 逐項記錄已觀察到的寫法，每項附一段範例與來源檔案路徑。
- 涵蓋本體與 `references/personal.md` 列出的風格面向，例如大括號、欄位前綴、右括弧、Attribute 與初始設定式排版；未觀察到的面向標示「未判定」，不推測補值。
- 範例檔不存在、內容為空或沒有任何已觀察項目時，停止相依工作並要求使用者補足或重新取樣，不自動改選其他註記值。

## 命名

- **縮寫**：縮寫的首字母大小寫依所在情境採 PascalCase 或 camelCase，其餘字母規則如下：
  - 3 個字母以上（縮略字、縮寫皆適用）：第二個字母起一律小寫，如 `Sql`、`Xml`。
  - 2 個字母的縮略字（Acronym，取數個單字的首字母組成）：全大寫或全小寫，如 `IO`、`io`。
  - 2 個字母的縮寫（Abbreviation，由單一單字取字母組成）：第二個字母起小寫，如 `Id`、`id`。
- **泛型型別參數**：單一且可為任意型別時使用 `T`；有多個型別參數，或對型別有具體語意要求時，使用 `T` 開頭的描述性單字，如 `TKey`、`TValue`、`TResult`。
- **布林成員命名**：布林型別的屬性、欄位與回傳布林的方法，命名要讀起來像「是／否」斷言，預設加 `Is`、`Has`、`Can`、`Should` 前綴，如 `IsActive`、`HasStock`、`CanCancel`。
  - 例外：對應 BCL 既有成員，或沿用框架慣例（如 UI 控制項的 `Enabled`、`Visible`）時，從其慣例，不強制改加前綴。
  - 同一型別內語意相近的布林成員採一致形式。
- **類別後綴**：
  - 擴充方法（Extension Methods）的靜態類別以 `Extensions` 結尾（如 `StringExtensions`）。例外：Minimal API 的 Endpoint 映射類別以 `XxxEndpoints` 命名（如 `ProductEndpoints`）。
  - 靜態工具類別以 `Utils` 結尾（如 `StringUtils`）。
  - 非靜態工具類別且無其他更適合的領域驅動命名時，允許以 `Helper` 結尾（如 `ViewHelper`）。
- **Enum**：標註 `[Flags]` 的 Enum 使用複數命名（如 `FileAccessRights`）；一般 Enum 使用單數。

## 結構與排序

- **單檔單型別**：每個 `.cs` 檔案只能包含一個頂層型別（Class、Interface、Enum、Struct、Record）。Inner Class 不受此限，允許巢狀於父類別中。
- **成員型別順序**：型別成員依下列順序排列：Fields、Constructors、Finalizer、Delegates、Events、Properties、Indexers、Methods、Operators、Nested Types。巢狀型別（Enum、Interface、Struct、Class、Record）統一排在所有其他成員之後。
- **存取修飾詞順序**：同一類成員之間，依 `public`、`internal`、`protected internal`、`protected`、`private protected`、`private` 排列。
- **欄位順序**：constant 欄位排在 non-constant 之前；static 排在 non-static 之前；readonly 排在 non-readonly 之前。
- **存取子順序**：Property 與 Indexer 的 getter 排在 setter 之前；Event 的 add 存取子排在 remove 之前。
- **Locality**：依方法間的呼叫關係群聚，不依存取修飾詞排序。
  - 預設：`private` 方法緊接在第一個呼叫它的方法下方。
  - 多個相似方法都呼叫時：考慮改放在最後一個呼叫它的方法下方。

  ```csharp
  // 預設：FormatAmount 放在第一個呼叫它的 BuildSummary 下方
  public string BuildSummary(Order order) => FormatAmount(order.Total);

  private string FormatAmount(decimal amount) => amount.ToString("C");

  // 多個相似方法呼叫：Describe 放在最後一個呼叫它的 BuildDetail 下方
  public string BuildLabel(Order order) => Describe(order);

  public string BuildDetail(Order order) => Describe(order);

  private string Describe(Order order) => order.Id.ToString();
  ```

## 空行

- **欄位與成員空行**：欄位之間不加空行；其餘成員之間加一個空行。
- **區塊內首尾空行**：區塊（大括號內）的開頭與結尾不加空行。

## 排版

- **換行基準**：以 120 字元為換行基準。賦值運算子 `=` 保留在前一行；二元運算子（`&&`、`||`）與 Lambda（`=>`）換行至新行開頭。專案 `.editorconfig` 設定運算子換行位置時以其為準。

  ```csharp
  // = 留在前一行，運算式換行
  decimal total = basePrice
      + shippingFee
      + taxAmount;

  // => 換至新行開頭，與 = 做區隔
  public string DisplayName
      => $"{firstName} {lastName}";

  // ❌ 二元運算子留在行末，不易看出下一行仍屬同一運算式
  decimal subtotal = basePrice +
      shippingFee +
      taxAmount;
  ```

- **三元運算子**：
  - 短且非巢狀：保持單行。
  - 過長：換行，`?` 與 `:` 置於新行開頭。
  - 巢狀：一律換行，下列兩種排版皆可。

  ```csharp
  // 短，單行
  string label = isActive ? "啟用" : "停用";

  // 過長，換行
  string message = isActive
      ? BuildActiveMessage(user)
      : BuildInactiveMessage(user);

  // 巢狀排版一：逐層縮排，子條件置於 : 之後
  string grade = score >= 90
      ? "A"
      : score >= 60
          ? "B"
          : "C";

  // 巢狀排版二：各分支左對齊（ASP.NET Core 原始碼風格）
  string size = count > 100 ? "large"
      : count > 10 ? "medium"
      : "small";

  // ❌ 巢狀卻全擠在單行，分支邊界難以辨識
  string tier = amount >= 10000 ? "VIP" : amount >= 1000 ? "Gold" : "Silver";
  ```

- **`switch` 運算式**：每個 arm 各佔一行，`=>` 前後各一個空格；不跨 arm 對齊 `=>`；discard `_` arm 置於最後，最後一個 arm 不加結尾逗號。`{` 位置依 `.editorconfig` 設定。
- **多行換行**：參數、引數或條件數量多到一行難以閱讀時才換行；是否每項各佔一行不強制，但換行後不應再把多項硬擠回同一行而犧牲可讀性。方法鏈換行時，每個 `.` 置於新行開頭。

  ```csharp
  // 方法鏈：每個 . 置於新行開頭
  List<string> names = users
      .Where(u => u.IsActive)
      .OrderBy(u => u.Name)
      .Select(u => u.Name)
      .ToList();

  // ❌ 換行了，卻把引數硬擠回同一行，失去換行的意義
  OrderResult result = orderService.Process(order, paymentInfo,
      cancellationToken);
  ```

- **物件與集合初始設定式**：是否使用初始設定式、target-typed `new()` 或集合運算式 `[]` 由 `.editorconfig` 與 analyzer 約束；此處僅規範多行時的排版。
  - 成員少且單行不過長：保持單行。
  - 成員較多或單行過長：每個成員各佔一行，最後一個成員後不加結尾逗號。`{` 位置依 `.editorconfig` 設定。

  ```csharp
  // 成員少，單行
  CartItem item = new() { ProductId = productId, Quantity = 1 };

  // 集合運算式：成員較多時逐行排列，最後一個成員後不加逗號
  List<string> tags = [
      "new",
      "featured",
      "limited"
  ];
  ```

- **禁用 `#region`**。

## .NET 品質檢查

- 實作 `IDisposable` 或 `IAsyncDisposable` 的物件必須在 `using` 區塊或 `try/finally` 中釋放。發現 `new HttpClient()` 時改用 `IHttpClientFactory`。
- SOLID 的模組邊界、Interface、Adapter、依賴方向與刪除測試規則參閱 `codebase-design` skill。
- 字串串接迴圈使用 `StringBuilder` 或 `string.Join()`。對 `IEnumerable<T>` 多次執行 `.Count()` 或迴圈時先物化。同步 I/O 優先改用非同步版本。
