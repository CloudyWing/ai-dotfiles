---
name: csharp-style
description: C# 程式碼風格規範：縮寫大小寫、泛型型別參數、成員排序、空行、換行、三元運算子等 .editorconfig 無法約束的細則。建立全新 C# 專案，或在無既有慣例的專案新增全新檔案時套用。
audience: agent
policy.allow_implicit_invocation: true
---

# C# Code Style

本 Skill 收錄 C# 風格規範中 `.editorconfig` 無法約束的部分。可由 `.editorconfig` 與內建 analyzer 約束的項目（PascalCase / camelCase 大小寫、Interface `I` 前綴、file-scoped namespace、`using` 排序、存取修飾詞、大括號位置、強制大括號、空格、縮排等）一律以專案 `.editorconfig` 為準，不在此重複條列。

## 套用範圍

- **既有專案**：以鄰近檔案的既有慣例為準，既有慣例優先於本 Skill。本 Skill 僅在既有專案無可識別慣例時，作為新增檔案的風格基準。
不主動將既有程式碼「修正」成為 Skill 的風格，以避免製造無謂的 diff 雜訊。

## 命名

- **縮寫**：縮寫的首字母大小寫依所在情境採 PascalCase 或 camelCase，其餘字母規則如下：
  - 3 個字母以上（縮略字、縮寫皆適用）：第二個字母起一律小寫，如 `Sql`、`Xml`。
  - 2 個字母的縮略字（Acronym，取數個單字的首字母組成）：全大寫或全小寫，如 `IO`、`io`。
  - 2 個字母的縮寫（Abbreviation，由單一單字取字母組成）：第二個字母起小寫，如 `Id`、`id`。
- **泛型型別參數**：單一且可為任意型別時使用 `T`；有多個型別參數，或對型別有具體語意要求時，使用 `T` 開頭的描述性單字，如 `TKey`、`TValue`、`TResult`。
- **布林成員命名**：布林型別的屬性、欄位與回傳布林的方法，命名要讀起來像「是／否」斷言，預設加 `Is`、`Has`、`Can`、`Should` 前綴，如 `IsActive`、`HasStock`、`CanCancel`。
  - 例外：對應 BCL 既有成員，或沿用框架慣例（如 UI 控制項的 `Enabled`、`Visible`）時，從其慣例，不強制改加前綴。
  - 同一型別內語意相近的布林成員採一致形式。
- **private 欄位前綴**：預設不加 `_`、`m_`、`s_` 前綴。專案 `.editorconfig` 或既有慣例另有指定時，從其規定。
- **類別後綴**：
  - 擴充方法（Extension Methods）的靜態類別以 `Extensions` 結尾（如 `StringExtensions`）。例外：Minimal API 的 Endpoint 映射類別以 `XxxEndpoints` 命名（如 `ProductEndpoints`）。
  - 靜態工具類別以 `Utils` 結尾（如 `StringUtils`）。
  - 非靜態工具類別且無其他更適合的領域驅動命名時，允許以 `Helper` 結尾（如 `ViewHelper`）。
- **Enum**：標註 `[Flags]` 的 Enum 使用複數命名（如 `FileAccessRights`）；一般 Enum 使用單數。

## 結構與排序

- **單檔單型別**：每個 `.cs` 檔案只能包含一個頂層型別（Class、Interface、Enum、Struct、Record）。Inner Class 不受此限，允許巢狀於父類別中。
- **成員型別順序**：型別成員依下列順序排列：Fields、Constructors、Finalizer、Delegates、Events、Properties、Indexers、Methods、Operators、Nested Types。巢狀型別（Enum、Interface、Struct、Class、Record）統一排在所有其他成員之後。

  ```csharp
  public class Sample {
      // Fields
      public const int MaxCount = 100;
      private static int instanceCount;
      private readonly string name;

      // Constructors
      public Sample(string name) {
          this.name = name;
      }

      // Finalizer
      ~Sample() {
      }

      // Delegates
      public delegate int Operation(int value);

      // Events
      public event EventHandler Changed;

      // Properties
      public int Count { get; private set; }

      // Indexers
      public char this[int index] => name[index];

      // Methods
      public void Reset() {
          Count = 0;
      }

      // Operators
      public static Sample operator +(Sample left, Sample right) {
          return left;
      }

      // Nested Types
      public enum State {
          Idle,
          Running
      }
  }
  ```

- **存取修飾詞順序**：同一類成員之間，依 `public`、`internal`、`protected internal`、`protected`、`private protected`、`private` 排列。
- **欄位順序**：constant 欄位排在 non-constant 之前；static 排在 non-static 之前；readonly 排在 non-readonly 之前。
- **存取子順序**：Property 與 Indexer 的 getter 排在 setter 之前；Event 的 add 存取子排在 remove 之前。
- **Locality**：依方法間的呼叫關係群聚，不依存取修飾詞排序。
  - 預設：`private` 方法緊接在第一個呼叫它的方法下方。
  - 多個相似方法都呼叫時：考慮改放在最後一個呼叫它的方法下方。

  ```csharp
  // 預設：FormatAmount 放在第一個呼叫它的 BuildSummary 下方
  public string BuildSummary(Order order) {
      return FormatAmount(order.Total);
  }

  private string FormatAmount(decimal amount) {
      return amount.ToString("C");
  }

  // 多個相似方法呼叫：Describe 放在最後一個呼叫它的 BuildDetail 下方
  public string BuildLabel(Order order) {
      return Describe(order);
  }

  public string BuildDetail(Order order) {
      return Describe(order);
  }

  private string Describe(Order order) {
      return order.Id.ToString();
  }
  ```

## 空行

- **欄位與成員空行**：欄位之間不加空行；其餘成員之間加一個空行。
- **區塊內首尾空行**：區塊（大括號內）的開頭與結尾不加空行。
- **連續空行上限**：任何位置最多保留一個連續空行。

## 排版

- **換行基準**：以 120 字元為換行基準。賦值運算子 `=` 保留在前一行；二元運算子（`&&`、`||`）與 Lambda（`=>`）換行至新行開頭。

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

- **`switch` 運算式**：每個 arm 各佔一行，`=>` 前後各一個空格；不跨 arm 對齊 `=>`；discard `_` arm 置於最後，最後一個 arm 不加結尾逗號。

  ```csharp
  string label = status switch {
      OrderStatus.Paid => "已付款",
      OrderStatus.Shipped => "已出貨",
      OrderStatus.Cancelled => "已取消",
      _ => "未知"
  };

  // ❌ 對齊 =>，任一 arm 變長就要整段重排
  string label = status switch {
      OrderStatus.Paid      => "已付款",
      OrderStatus.Shipped   => "已出貨",
      _                     => "未知"
  };
  ```

- **多行換行**：參數、引數或條件數量多到一行難以閱讀時才換行；是否每項各佔一行不強制，但換行後不應再把多項硬擠回同一行而犧牲可讀性。換行時的收尾規則：
  - 括弧（條件式、方法宣告參數、建構式參數、方法呼叫引數）換行時，右括弧 `)` 獨立成行，縮排與開頭對齊。`{` 依專案 `.editorconfig` 的大括號設定，K&R 風格時接於 `)` 後方同行。
  - 泛型方法的 `where` 約束：第一個 `where` 接於 `)` 同行，其餘 `where` 各自換行。
  - 方法鏈換行時，每個 `.` 置於新行開頭。
  - 多行引數的方法呼叫後接方法鏈時，第一個 `.` 接於 `)` 同行，其餘 `.` 各自換行。

  ```csharp
  // 條件式
  if (order.IsPaid
      && order.HasStock
      && !order.IsCancelled
  ) {
  }

  // 建構式多參數
  public OrderService(
      IOrderRepository repository,
      IPaymentGateway paymentGateway,
      ILogger<OrderService> logger
  ) {
  }

  // 泛型方法的 where 約束：第一個 where 接於 ) 同行，其餘各自換行
  public TResult Convert<TSource, TResult>(
      TSource source,
      Func<TSource, TResult> selector
  ) where TSource : class
      where TResult : class {
  }

  // 方法呼叫引數
  OrderResult result = orderService.Process(
      order,
      paymentInfo,
      cancellationToken
  );

  // 方法鏈：每個 . 置於新行開頭
  List<string> names = users
      .Where(u => u.IsActive)
      .OrderBy(u => u.Name)
      .Select(u => u.Name)
      .ToList();

  // 多行引數呼叫後接方法鏈：第一個 . 接於 ) 同行，後續每個 . 各自換行
  List<OrderItem> items = orderService.Query(
      customerId,
      startDate,
      endDate
  ).Where(item => item.IsShipped)
      .OrderBy(item => item.ShippedAt)
      .ToList();

  // ❌ 換行了，但 ) 沒有獨立成行
  if (order.IsPaid
      && order.HasStock) {
  }

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

  // 成員較多，逐行排列，最後一個成員後不加逗號
  Order order = new() {
      Id = orderId,
      CustomerName = customerName,
      TotalAmount = totalAmount,
      CreatedAt = createdAt
  };

  // 集合初始設定式 / 集合運算式同規則
  List<string> tags = [
      "new",
      "featured",
      "limited"
  ];
  ```

- **禁用 `#region`**。

## Attribute

- **型別與成員的 attribute**：每個 attribute 各自獨立成行、各用獨立中括號，置於宣告上方。
- **參數與回傳值的 attribute**：與宣告同行，inline 書寫。
- **不合併中括號**：多個 attribute 不寫成 `[A, B]`，一律逐行分開。

  ```csharp
  // 型別／成員：逐行、獨立中括號
  [Serializable]
  [Obsolete("改用 OrderServiceV2")]
  public class OrderService {
      [Required]
      [StringLength(50)]
      public string CustomerName { get; init; }
  }

  // 參數／回傳值：與宣告同行
  public OrderResult Process([FromBody] OrderRequest request) {
  }

  // ❌ 多個 attribute 合併成同一中括號
  [Required, StringLength(50)]
  public string CustomerName { get; init; }
  ```

## .NET 品質檢查

- 實作 `IDisposable` 或 `IAsyncDisposable` 的物件必須在 `using` 區塊或 `try/finally` 中釋放。發現 `new HttpClient()` 時改用 `IHttpClientFactory`。
- SOLID 的模組邊界、Interface、Adapter、依賴方向與刪除測試規則參閱 `codebase-design` skill。
- 字串串接迴圈使用 `StringBuilder` 或 `string.Join()`。對 `IEnumerable<T>` 多次執行 `.Count()` 或迴圈時先物化。同步 I/O 優先改用非同步版本。
