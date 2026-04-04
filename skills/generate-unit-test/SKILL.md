---
name: generate-unit-test
description: 針對指定的 C# 類別或方法，自動產生 NUnit 單元測試骨架，包含 Arrange/Act/Assert 結構與 NSubstitute Mock 設定。
disable-model-invocation: true
---

# 產生 NUnit 單元測試骨架

依 `csharp-nunit` skill 規範，為指定的 C# 類別或方法產生完整的測試骨架。

## 使用方式

```
/generate-unit-test [類別名稱或 .cs 檔案路徑]
```

若未傳入參數，詢問使用者要測試哪個類別。

## 執行步驟

### 1. 讀取目標類別

讀取指定的 `.cs` 檔案，識別：

- 類別名稱與命名空間
- 建構函式參數（確認需要 Mock 的相依性）
- 所有 `public` 方法（包含方法簽名、參數類型、回傳類型）
- 是否有 `async` 方法
- 是否有 `IDisposable`

### 2. 確認測試專案位置

掃描以下位置，找到對應的測試專案：

- `*.Tests/*.csproj`
- `tests/**/*.csproj`
- `[ProjectName].Tests/`

若找不到，詢問使用者測試專案路徑；若不存在，告知需先建立測試專案。

確認測試專案有引用以下 NuGet 套件：

- `NUnit`
- `NUnit3TestAdapter`
- `NSubstitute`
- `Microsoft.NET.Test.Sdk`

### 3. 產生測試類別骨架

依照以下規範產生：

```csharp
using NSubstitute;
using NUnit.Framework;

namespace [對應的測試命名空間];

[TestFixture]
public class [ClassName]Tests
{
    private [ClassName] sut;
    private [IDependency1] dependency1;
    // ... 其餘相依性

    [SetUp]
    public void SetUp()
    {
        dependency1 = Substitute.For<[IDependency1]>();
        // ... 建立其餘 Mock
        sut = new [ClassName](dependency1);
    }

    [Test]
    public void [MethodName]_[Scenario]_[ExpectedBehavior]()
    {
        // Arrange
        // TODO: 設定輸入與 Mock 行為

        // Act
        var result = sut.[MethodName]();

        // Assert
        Assert.That(result, Is.Not.Null);
    }

    // 非同步方法範本
    [Test]
    public async Task [AsyncMethodName]_[Scenario]_[ExpectedBehavior]()
    {
        // Arrange

        // Act
        var result = await sut.[AsyncMethodName]();

        // Assert
    }
}
```

**命名規則：**

- 測試方法名稱：`[方法名稱]_[情境]_[預期結果]`（底線分隔三段式）。
- 測試類別名稱：`[被測試類別名稱]Tests`。
- 命名空間：與被測試類別相同，加上 `.Tests` 後綴。

**方法骨架生成原則：**

- 每個 `public` 方法至少生成一個 Happy Path 測試方法。
- 若方法有參數驗證（如 `null` 檢查），額外生成一個 Exception 測試。
- 若回傳值為集合，補充一個「結果為空集合」的案例。
- 所有 `TODO` 需標示測試意圖，不留空白的 AAA 區塊。

### 4. 確認輸出路徑

測試檔案路徑遵循以下慣例：

- 被測試：`src/MyProject/Services/UserService.cs`
- 測試檔：`tests/MyProject.Tests/Services/UserServiceTests.cs`

目錄不存在時自動建立。

### 5. 寫入測試檔案

若測試檔案已存在：

- **不覆蓋整個檔案**，僅追加缺少的測試方法骨架至對應的 `[TestFixture]` 類別末尾。
- 若類別完全不存在，才建立新的測試類別。

若不存在，建立完整的新測試檔。

### 6. 完成確認

輸出：

- 產生的測試檔案路徑
- 產生的測試方法清單（含方法名稱）
- 若有無法自動判斷的相依性（如靜態方法、密封類別），列出手動補充的提示
