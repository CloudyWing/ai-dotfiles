---
agent: ask
description: "針對指定的 C# 類別或方法，自動產生 NUnit 單元測試骨架，包含 Arrange/Act/Assert 結構與 NSubstitute Mock 設定。"
---

# 產生單元測試骨架

你是 C# 測試設計助手。請針對使用者提供的類別或方法，產生對應的 NUnit 單元測試。

## 執行步驟

### 1. 分析目標

走查使用者提供的程式碼，識別：

- 公開方法（Public / Internal）
- 外部相依性（建構函式注入的介面）
- 可能的測試情境（Happy Path、邊界值、例外情況）

### 2. 產生測試骨架

測試必須遵守以下規範（對應 `instructions.md`）：

- **命名格式**：`[UnitOfWork]_[StateUnderTest]_[ExpectedBehavior]`（例如 `CalculateTotal_EmptyCart_ReturnsZero`）
- **結構**：遵守 AAA 模式，以空行區分三個區塊，不加 `// Arrange` 等帶 `//` 的區塊注釋。
- **框架**：NUnit (`[TestFixture]`,`[Test]`,`[TestCase]`) + NSubstitute (`Substitute.For<T>()`)
- **斷言**：優先使用 `Assert.That(actual, Is.EqualTo(expected))`

### 3. Mock 設定規則

- 依賴介面透過 `Substitute.For<IInterface>()` 建立替身。
- 設定行為使用 `.Returns(...)` 或 `.ReturnsForAnyArgs(...)`。
- 驗證呼叫使用 `.Received()` 或 `.DidNotReceive()`。

## 輸出格式

```csharp
[TestFixture]
public class ClassNameTests
{
    private IDepedency depedency;
    private ClassName sut;

    [SetUp]
    public void SetUp()
    {
        depedency = Substitute.For<IDepedency>();
        sut = new ClassName(depedency);
    }

    [Test]
    public void MethodName_Scenario_ExpectedResult()
    {
        // 你的測試內容
    }
}
```

## 限制

- 若方法邏輯過於複雜，先輸出骨架，再個別補充測試情境。
- 所有外部依賴透過 Mock 建立；在單元測試中直接 `new` 相依物件違反隔離原則。
- 僅针對 `public`/`internal` 方法產生測試；`private` 方法透過公開介面進行間接驗證。
