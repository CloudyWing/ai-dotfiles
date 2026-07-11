---
name: csharp-nunit
description: 'C# NUnit 測試規範：確保單元測試套用 AAA 模式、TestCase 資料驅動與合適的斷言 (Assertions)。當撰寫或修改 C# 單元測試時自動套用。'
---

# NUnit 單元測試最佳實踐

當要求為 C# 撰寫單元測試時，請自動套用以下規範 (以 NUnit 為主)。

## 測試結構 (Structure)

- 使用 `[Test]` 標示無參數的單一測試案例。
- 嚴格遵守 **Arrange-Act-Assert (AAA)** 模式，三個區塊間應空一行以利閱讀，不加 `// Arrange`、`// Act`、`// Assert` 等區塊注釋。
- 測試方法命名遵循 `[UnitOfWork]_[StateUnderTest]_[ExpectedBehavior]` 格式（例如 `Calculate_InvalidInput_ThrowsArgumentException`）。
- 若需共用上下文，優先使用 `[SetUp]` 與 `[TearDown]`。

## 資料驅動測試 (Data-Driven Tests)

- 當測試邏輯相同但輸入輸出不同的大量相似情境時，必須使用資料驅動標籤：
  - `[TestCase(...)]`：用於簡單的行內資料。
  - `[TestCaseSource]`：用於複雜的物件圖或須呼叫方法的外部資料來源。
  - `[Values]` 或 `[Random]`：用於讓測試框架自動生成組合測試。

## 斷言 (Assertions)

- 基本判斷：使用 `Assert.That(actual, Is.EqualTo(expected))` 驗證值相等。
- 例外測試：驗證方法拋出例外時，必須使用 `Assert.Throws<T>()` 或非同步的 `Assert.ThrowsAsync<T>()`。
- 集合測試：優先使用 `CollectionAssert`；字串特定比對優先使用 `StringAssert`。
- 多重斷言：當單一測試包含多個 Assert 驗證時，優先使用 `using (Assert.EnterMultipleScope())`。
- 若專案有引進並偏好使用 FluentAssertions 或 Shouldly，則全面改用 Fluent API (例如 `result.Should().BeTrue()`)。

## 隔離與 Mock 設計

- 單一測試方法只驗證一種行為，避免過多 Assert 導致失焦。
- 利用 **NSubstitute** 作為 Mock 框架，隔離外部依賴，透過介面 (Interface) 來替代實際的資料存取或外部呼叫。
- 確保所有測試案例互相獨立，可平行不依賴執行順序 (Idempotent)。

## 非同步測試

- 非同步測試方法回傳 `Task`（不回傳 `void`）：

```csharp
[Test]
public async Task SaveOrderAsync_ValidOrder_PersistsToDatabaseAsync() {
    // Arrange
    IOrderRepository repo = Substitute.For<IOrderRepository>();
    OrderService sut = new(repo);

    // Act
    await sut.SaveOrderAsync(new Order { Id = 1 });

    // Assert
    await repo.Received(1).InsertAsync(Arg.Any<Order>());
}
```

- **非同步例外驗證**：使用 `Assert.ThrowsAsync<T>()`：

```csharp
[Test]
public async Task GetOrderAsync_NotFound_ThrowsKeyNotFoundExceptionAsync() {
    IOrderRepository repo = Substitute.For<IOrderRepository>();
    repo.GetByIdAsync(Arg.Any<int>()).Returns((Order?)null);
    OrderService sut = new(repo);

    Assert.ThrowsAsync<KeyNotFoundException>(
        async () => await sut.GetOrderAsync(99)
    );
}
```

- **非同步 SetUp / TearDown**：方法加上 `async Task` 回傳型別，NUnit 4+ 原生支援：

```csharp
[SetUp]
public async Task SetUpAsync() {
    db = await DbFixture.CreateAsync();
}

[TearDown]
public async Task TearDownAsync() {
    await db.DisposeAsync();
}
```
