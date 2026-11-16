# bUnit 元件測試

本檔收錄 bUnit 元件測試（搭配 NUnit、MudBlazor）的 2.x API 對照、測試基底、MudBlazor 設定、DI 替身策略、元素查詢約定與非同步等待易錯點。撰寫或修改 bUnit 元件測試時讀。

測試命名、AAA 與斷言規則依 `csharp-nunit`，本章不重述。範例的私有欄位前綴依專案 `csharp-style` 註記調整。

範例的測試專案使用 `Microsoft.NET.Sdk.Razor`、TFM `net10.0` 並啟用 ImplicitUsings，套件為 `bunit`、`MudBlazor`、`NUnit`、`NUnit3TestAdapter`、`Microsoft.NET.Test.Sdk`、`NSubstitute`；範例以 bunit 2.13.3、MudBlazor 9.11.0、NUnit 4.5.1 建置並通過。

## 套件與 API（bUnit 2.x）

bUnit 2.x 只有單一套件 `bunit`，測試環境型別為 `BunitContext`，渲染統一使用 `Render<T>`，`BunitContext` 同時實作 `IAsyncDisposable`〔官方〕。bUnit 可搭配 NUnit、MSTest 與 xUnit〔官方〕。來源：<https://bunit.dev/docs/migrations/1to2.html>、<https://learn.microsoft.com/aspnet/core/blazor/test?view=aspnetcore-10.0>。

| 1.x 名稱 | 2.x 名稱 |
| --- | --- |
| `bunit.core`、`bunit.web` 套件 | `bunit` 套件 |
| `TestContext` | `BunitContext` |
| `RenderComponent<T>`、`SetParametersAndRender` | `Render<T>` |
| `DisposeComponents()` | `DisposeComponentsAsync()` |

## 測試基底

- 建立每個測試獨立的 `BunitContext`：在 `[SetUp]` 建立，在 `[TearDown]` 以 `await DisposeAsync()` 釋放〔AAM〕〔SE〕。
- 釋放一律走非同步路徑。MudBlazor 有些服務只實作 `IAsyncDisposable`，同步 `Dispose` 會拋例外〔SE〕。
- 設定 `JSInterop.Mode = JSRuntimeMode.Loose` 的時機為元件測試只驗證 Blazor 端行為、JS interop 呼叫不是斷言對象時〔AAM〕〔SE〕。需要斷言特定 JS 呼叫時保留預設的 Strict，並設定預期呼叫〔官方〕。來源：<https://bunit.dev/docs/test-doubles/emulating-ijsruntime.html>。

完整檔案：ComponentTestBase.cs

```csharp
using Bunit;
using Microsoft.Extensions.DependencyInjection;
using MudBlazor;
using MudBlazor.Services;
using NUnit.Framework;

namespace MyApp.Components.Tests;

/// <summary>
/// 為每個測試建立獨立的 bUnit 環境，並註冊 MudBlazor 所需服務。
/// </summary>
public abstract class ComponentTestBase {
    private BunitContext? context;

    protected BunitContext Context => context ?? throw new InvalidOperationException("bUnit 環境尚未建立。");

    [SetUp]
    public void SetUpContext() {
        context = new BunitContext();
        // MudBlazor 元件會呼叫多個 JS interop；元件測試只驗證 Blazor 端行為，因此採寬鬆模式。
        context.JSInterop.Mode = JSRuntimeMode.Loose;
        context.Services.AddMudServices(options => {
            // 測試只渲染受測元件，不渲染 MainLayout 中的 MudPopoverProvider。
            options.PopoverOptions.CheckForPopoverProvider = false;
        });
    }

    [TearDown]
    public async Task TearDownContextAsync() {
        if (context is not null) {
            // MudBlazor 部分服務只實作 IAsyncDisposable，必須非同步釋放。
            await context.DisposeAsync();
            context = null;
        }
    }

    protected IRenderedComponent<MudDialogProvider> RenderDialogProvider() {
        Context.Render<MudPopoverProvider>();
        return Context.Render<MudDialogProvider>();
    }
}
```

## MudBlazor 設定

- 註冊 `AddMudServices`，並設定 `PopoverOptions.CheckForPopoverProvider = false`〔AAM〕。
- 渲染對話框前先 `Render<MudPopoverProvider>()` 再 `Render<MudDialogProvider>()`。內嵌對話框的內容出現在 `MudDialogProvider` 的渲染結果中，查詢要對 provider 做〔AAM〕。

上述設定在 MudBlazor 9.11.0 驗證，MudBlazor 主版本升級時 API 可能變動。

## DI 替身策略

- 註冊 State 類別的真實作，外部依賴（檔案系統、對話框服務、資料庫、更新服務等）換成 NSubstitute 替身或暫存目錄〔SE〕。
- 新增測試接縫前依 `csharp-nunit`「測試接縫需先議定」。

## 元素查詢

以使用者看得到的文字或 `aria-label` 查詢元素，不綁定元件庫內部的 CSS 類別，元件庫改版時測試才不會跟著壞〔AAM〕。

查詢以擴充方法集中定義在測試專案的 `ElementQueries`，後文範例沿用下列名稱與語意。

- `FindButton(text)` 對 `IRenderedComponent` 以去除前後空白後的文字完全相符查詢 `button`，找到的數量不是 1 時拋 `InvalidOperationException`。
- `HasButton(text)` 以同樣的比對方式回傳該按鈕是否存在。
- `FindByLabel(label)` 依 `aria-label` 完全相符取得唯一元素。
- `IsDisabled()` 對 `IElement` 檢查是否具有 `disabled` 屬性。

## bUnit 非同步等待與易錯點

1. 採用 `WaitForState` 加單次 Assert。`WaitForState` 在呼叫時與每次元件渲染時檢查述詞，預設逾時 1 秒，逾時拋 `WaitForFailedException`〔官方〕。慢狀態傳入較長的 `TimeSpan`，SE 使用 10 秒〔SE〕。`WaitForAssertion` 會重跑斷言直到不拋例外〔官方〕，但在 NUnit 4 下，重試過程中失敗的 `Assert.That` 會被 NUnit 記錄，最後即使通過，測試仍判失敗〔SE〕；AAM 在 NUnit 5.0.0 下使用 `WaitForAssertion` 的測試通過〔AAM〕。版本差異列於 `pending-probes.md`。來源：<https://bunit.dev/docs/interaction/awaiting-async-state.html>、<https://bunit.dev/docs/verification/async-assertion.html>。
2. 選最後才成立的訊號作為等待條件〔SE〕。例如匯出完成時，進度訊息也含「匯出結果」字樣，等文字會在中間狀態誤判完成；改等主要按鈕重新變成可按。

    ```csharp
    cut.WaitForState(() => !cut.FindButton("開始匯出").IsDisabled(), TimeSpan.FromSeconds(10));
    Assert.That(cut.Markup, Does.Contain("匯出結果"));
    ```

3. 等到明確階段再查詢並觸發〔SE〕。元件可能在找到元素之後、點擊之前重新渲染，點到已被替換的元素。以替身讓外部依賴停在目標階段，述詞同時要求按鈕可用與階段文字出現，之後才 `Find` 與 `Click`。

    ```csharp
    loader.LoadAsync(Arg.Any<CancellationToken>())
        .Returns(call => Task.Delay(Timeout.Infinite, call.Arg<CancellationToken>()));
    cut.FindButton("開始匯出").Click();
    cut.WaitForState(() => cut.Markup.Contains("從資料庫載入") && !cut.FindButton("取消").IsDisabled());
    cut.FindButton("取消").Click();
    ```
