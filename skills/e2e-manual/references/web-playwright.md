# 網站路徑：Playwright

本檔是 `e2e-manual` 網站路徑的寫法。Blazor 專案改依 `blazor-testing` skill 撰寫測試碼，截圖與紀錄契約仍依本 Skill。

## 專案設定

- .NET 專案：建立 `tests/<ProjectName>.E2ETests`，參考 `Microsoft.Playwright.NUnit`、`NUnit`、`NUnit3TestAdapter`、`Microsoft.NET.Test.Sdk`。測試類別繼承 `PageTest`，由基底類別提供 `Page`、`Context` 與 `Browser`。
- Node 專案：使用 `@playwright/test`，測試放在 `e2e/`，spec 檔命名為 `<功能>.spec.ts`，紀錄契約依 `recorder.md`「Node 專案」。
- 版本：套件版本沿用專案的 Central Package Management 或 `package.json` 既有設定，新增套件前取得使用者當輪同意。

## 瀏覽器安裝

- .NET 專案在建置後執行建置輸出目錄下的 `playwright.ps1`，例如 `pwsh tests/<ProjectName>.E2ETests/bin/Debug/<tfm>/playwright.ps1 install chromium`。
- Node 專案執行 `npx playwright install chromium`。
- 下載瀏覽器屬安裝相依性，執行前取得使用者當輪同意。

## 受測站台

- 沿用專案既有的啟動方式（`dotnet run`、`npm run dev`）或已在執行的服務。
- 以環境變數 `E2E_BASE_URL` 傳入基底位址。缺少時測試失敗並說明缺少的變數，不內建預設位址。
- 確認 `E2E_BASE_URL` 指向本機或測試環境，看到正式環境網域時停止並回報。

## 測試資料與登入

- 取得測試帳號的順序沿用 `browser-smoke`「登入與測試帳號」。
- E2E 自行建立的資料加唯一前綴 `e2e-<8 碼>`，便於識別與清理，也讓截圖中的資料一眼可辨認為測試資料。
- 寫入資料的流程依 `integration-verify`「資料異動安全規範」。

## 固定瀏覽器環境

以 headless 執行，不開啟可見的瀏覽器視窗，避免干擾同時使用電腦的使用者。`Microsoft.Playwright.NUnit` 預設為 headless，不設定 `HEADED=1`；Node 專案不在設定中開啟 `headless: false`。

覆寫 `PageTest` 的 `ContextOptions`，固定 viewport、縮放與語系，讓每次截圖一致：

```csharp
public override BrowserNewContextOptions ContextOptions()
{
    return new BrowserNewContextOptions
    {
        ViewportSize = new ViewportSize { Width = 1280, Height = 800 },
        DeviceScaleFactor = 1,
        Locale = "zh-TW",
        BaseURL = Environment.GetEnvironmentVariable("E2E_BASE_URL")
    };
}
```

Node 專案在 `playwright.config.ts` 的 `use` 設定 `viewport: { width: 1280, height: 800 }`、`deviceScaleFactor: 1`、`locale: 'zh-TW'`。

## 定位器

- 優先以 role、label、可見文字定位，例如 `Page.GetByRole(AriaRole.Button, new() { Name = "加入購物車" })`。
- 缺少穩定定位方式時回報使用者，不修改受測頁面。

## 截圖

```csharp
private Task CaptureAsync(string path)
{
    return Page.ScreenshotAsync(new PageScreenshotOptions
    {
        Path = path,
        Animations = ScreenshotAnimations.Disabled,
        Caret = ScreenshotCaret.Hide
    });
}
```

- 只截 viewport，不使用 `FullPage`，讓手冊截圖與使用者實際看到的畫面一致。
- 目標元素不在可視範圍時，先呼叫 `ScrollIntoViewIfNeededAsync` 再截圖。
- 截圖前以 Web-first 斷言（`Expect(...).ToBeVisibleAsync()` 等）等待畫面穩定。

## 流程骨架

以購物車結帳為情境，一個流程一個測試方法：

`E2E_RUN` 閘門放在命名空間根的 `[SetUpFixture]`。`PageTest` 的基底 `[SetUp]` 會在衍生類別的 `[SetUp]` 之前啟動瀏覽器，閘門放在衍生類別時，不帶 filter 的 `dotnet test` 仍會啟動瀏覽器，沒裝瀏覽器時還會變成 Failed。`[SetUpFixture]` 的 `[OneTimeSetUp]` 早於所有測試類別執行，`Assume` 不成立時整個命名空間標為 Inconclusive，瀏覽器不會啟動。

```csharp
using NUnit.Framework;

namespace MyApp.E2ETests;

[SetUpFixture]
public class E2ESetUpFixture
{
    [OneTimeSetUp]
    public void OneTimeSetUp()
    {
        Assume.That(Environment.GetEnvironmentVariable("E2E_RUN"), Is.EqualTo("1"), "未設定 E2E_RUN=1，略過 E2E");
    }
}
```

```csharp
[TestFixture]
[Category("E2E")]
public class CheckoutE2ETests : PageTest
{
    private ManualRecorder? recorder;

    [SetUp]
    public void SetUp()
    {
        recorder = null;
    }

    [Test]
    public async Task Checkout_WithOneItem_ShowsOrderCompleted()
    {
        recorder = ManualRecorder.FromEnvironment(1, "新增商品到購物車並結帳");

        await Page.GotoAsync("/products");
        await Page.GetByText("測試商品 A").ClickAsync();
        await Expect(Page.GetByRole(AriaRole.Button, new() { Name = "加入購物車" })).ToBeVisibleAsync();
        await recorder.StepAsync("點選商品清單中的「測試商品 A」", "畫面顯示商品明細與「加入購物車」按鈕", CaptureAsync);

        await Page.GetByRole(AriaRole.Button, new() { Name = "加入購物車" }).ClickAsync();
        await Expect(Page.GetByTestId("cart-count")).ToHaveTextAsync("1");
        await recorder.StepAsync("點選「加入購物車」", "右上角購物車數量變為 1", CaptureAsync);
    }
}
```

`[TearDown]` 依 `recorder.md` 的寫法呼叫 `CaptureFailureAsync` 與 `Complete`。閘門不成立時測試不執行，也不會寫出紀錄，Claude 端依「缺少紀錄檔視同失敗」判定。

## 執行命令

```powershell
$env:E2E_RUN = '1'
$env:E2E_BASE_URL = 'https://localhost:5001'
$env:E2E_MANUAL_STAGING = '<work-root>\.local\ai-sessions\scratch\e2e-manual\<功能>'
dotnet test tests/<ProjectName>.E2ETests --filter "TestCategory=E2E&FullyQualifiedName~<Feature>E2ETests"
```

一次只執行一個功能的測試類別，`E2E_MANUAL_STAGING` 指向同一個功能，避免不同功能的 `flowNN.json` 與截圖互相覆蓋。Node 專案以相同環境變數執行 `npx playwright test e2e/<功能>.spec.ts`。
