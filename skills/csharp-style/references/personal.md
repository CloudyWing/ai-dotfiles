# C# 個人風格範例

本檔只在專案 `AGENTS.local.md` 的 `code-style.csharp` 為 `personal` 時載入，收錄與主流慣例不同的寫法，逐條附範例。可由 `.editorconfig` 約束的項目（大括號位置、欄位前綴、連續空行上限等）以專案 `.editorconfig` 為準，本檔的範例只說明 `personal` 範本的預期結果。

## 大括號與欄位

- **K&R 大括號**：`{` 接在宣告或陳述式同一行行末；`else`、`catch`、`finally` 接在 `}` 後方同行。對應範本 `csharp_new_line_before_open_brace = none`。
- **private 欄位不加前綴**：private 與 internal 欄位不加 `_`、`m_`、`s_` 前綴，採 camelCase；`const` 與 `static readonly` 欄位採 PascalCase。

  ```csharp
  public class OrderService {
      private const int MaxRetry = 3;
      private static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(30);
      private static int instanceCount;
      private readonly IOrderRepository repository;

      public OrderService(IOrderRepository repository) {
          this.repository = repository;
      }

      public Order Find(int id) {
          try {
              return repository.Find(id);
          } catch (KeyNotFoundException) {
              return Order.Empty;
          } finally {
              instanceCount++;
          }
      }
  }
  ```

## 成員順序

成員順序規則見 `SKILL.md`「結構與排序」，以下為 `personal` 風格的完整排列範例。

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

## 空行

- **連續空行上限**：任何位置最多保留一個連續空行。實際上限由專案 `.editorconfig` 決定。

  ```csharp
  public void Reset() {
      Count = 0;
  }

  public void Clear() {
      Items.Clear();
  }
  ```

## 換行收尾

- **右括弧獨立成行**：條件式、方法宣告參數、建構式參數與方法呼叫引數換行時，右括弧 `)` 獨立成行，縮排與開頭對齊；`{` 接於 `)` 後方同行。

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

  // 方法呼叫引數
  OrderResult result = orderService.Process(
      order,
      paymentInfo,
      cancellationToken
  );

  // ❌ 換行了，但 ) 沒有獨立成行
  if (order.IsPaid
      && order.HasStock) {
  }
  ```

- **第一個 `where` 接於 `)` 同行**：泛型方法的參數換行時，第一個 `where` 約束接在 `)` 後方，其餘 `where` 各自換行。

  ```csharp
  public TResult Convert<TSource, TResult>(
      TSource source,
      Func<TSource, TResult> selector
  ) where TSource : class
      where TResult : class {
  }
  ```

- **呼叫後的第一個 `.` 接於 `)` 同行**：多行引數的方法呼叫後接方法鏈時，第一個 `.` 接在 `)` 後方，其餘 `.` 各自換行。

  ```csharp
  List<OrderItem> items = orderService.Query(
      customerId,
      startDate,
      endDate
  ).Where(item => item.IsShipped)
      .OrderBy(item => item.ShippedAt)
      .ToList();
  ```

## switch 運算式與初始設定式

- **`switch` 運算式**：規則見 `SKILL.md`「排版」，`{` 接在 `switch` 同一行。

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

- **物件初始設定式**：成員較多時逐行排列，`{` 接在 `new()` 同一行，最後一個成員後不加逗號。

  ```csharp
  Order order = new() {
      Id = orderId,
      CustomerName = customerName,
      TotalAmount = totalAmount,
      CreatedAt = createdAt
  };
  ```

## Attribute

- **型別與成員的 attribute 逐行**：每個 attribute 各自獨立成行、各用獨立中括號，置於宣告上方。
- **參數與回傳值的 attribute 同行**：與宣告同行，inline 書寫。
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
