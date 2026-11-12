# 步驟與截圖紀錄契約

本檔定義 E2E 測試交給 Claude 端組裝手冊的資料格式。測試在 staging 目錄寫出每個流程的 `flowNN.json` 與截圖，Claude 端只讀這兩樣東西判定與組裝，不解析測試框架的結果檔。網站、視窗程式與 Blazor 專案的測試碼都寫出同一份契約。

## staging 結構

```text
<E2E_MANUAL_STAGING>/              # = <work-root>/.local/ai-sessions/scratch/e2e-manual/<功能>/
├── flows/
│   ├── flow01.json
│   └── flow02.json
├── images/
│   ├── flow01-step01.png
│   └── flow01-step02.png
└── failures/
    └── flow02-fail.png
```

- 執行者在每次執行前清空該功能的 staging 目錄。
- 環境變數 `E2E_MANUAL_STAGING` 未設定時，`ManualRecorder` 所有成員為 no-op，測試照常執行。

## flowNN.json 欄位

| 欄位 | 型別 | 說明 |
| --- | --- | --- |
| `flowNo` | 整數 | 流程編號，對應勾選表格順序，從 1 起算 |
| `flow` | 字串 | 流程名稱，動詞加對象，手冊的流程標題 |
| `status` | 字串 | `Passed`、`Failed`、`Skipped`、`Inconclusive` 四者之一 |
| `steps` | 陣列 | 依執行順序列出已完成的步驟 |
| `steps[].no` | 整數 | 步驟編號，從 1 起算 |
| `steps[].action` | 字串 | 使用者語言的操作描述，以「點選」「輸入」「選擇」等動詞開頭 |
| `steps[].expected` | 字串 | 使用者語言的預期結果，描述畫面應出現的變化 |
| `steps[].image` | 字串 | 相對 staging 根目錄的截圖路徑，例如 `images/flow01-step01.png` |
| `failure` | 物件或 `null` | 無失敗為 `null`；失敗時含 `step`（失敗發生在第幾步）、`message`（錯誤訊息）、`image`（`failures/flowNN-fail.png`，截圖失敗時為 `null`） |

範例：

```json
{
  "flowNo": 1,
  "flow": "新增商品到購物車並結帳",
  "status": "Passed",
  "steps": [
    {
      "no": 1,
      "action": "點選商品清單中的「測試商品 A」",
      "expected": "畫面顯示商品明細與「加入購物車」按鈕",
      "image": "images/flow01-step01.png"
    },
    {
      "no": 2,
      "action": "點選「加入購物車」",
      "expected": "右上角購物車數量變為 1",
      "image": "images/flow01-step02.png"
    }
  ],
  "failure": null
}
```

## ManualRecorder 介面

| 成員 | 行為 |
| --- | --- |
| 建構子 `ManualRecorder(string? stagingRoot, int flowNo, string flowName)` | `stagingRoot` 為 `null` 或空字串時，所有成員為 no-op |
| `Task StepAsync(string action, string expected, Func<string, Task> captureAsync)` | 計算 `images/flowNN-stepNN.png` 的絕對路徑，呼叫 `captureAsync(path)` 寫出截圖，再登錄步驟 |
| `Task CaptureFailureAsync(Func<string, Task> captureAsync)` | 寫出 `failures/flowNN-fail.png`；截圖本身失敗時吞下例外，只記錄 `image` 為 `null` |
| `void Complete(string status, string? failureMessage)` | 在 `[TearDown]` 以 `TestContext.CurrentContext.Result.Outcome.Status` 呼叫，寫出 `flows/flowNN.json` |

- 呼叫 `StepAsync` 的位置在該步驟的斷言之後，斷言失敗時不會產生該步驟的截圖。
- 失敗步驟編號為最後一個成功步驟加 1。

## C# 範例實作

一個檔案一個型別。命名、存取修飾詞與欄位前綴依專案 `.editorconfig` 與 `AGENTS.local.md` 的 `code-style.csharp` 調整。

```csharp
using System.Text.Encodings.Web;
using System.Text.Json;
using NUnit.Framework;

namespace MyApp.E2ETests;

public sealed class ManualRecorder
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    private readonly string? stagingRoot;
    private readonly int flowNo;
    private readonly string flowName;
    private readonly List<RecordedStep> steps = [];
    private string? failureImage;

    public ManualRecorder(string? stagingRoot, int flowNo, string flowName)
    {
        this.stagingRoot = string.IsNullOrWhiteSpace(stagingRoot) ? null : stagingRoot;
        this.flowNo = flowNo;
        this.flowName = flowName;
    }

    public static ManualRecorder FromEnvironment(int flowNo, string flowName)
    {
        return new ManualRecorder(Environment.GetEnvironmentVariable("E2E_MANUAL_STAGING"), flowNo, flowName);
    }

    public async Task StepAsync(string action, string expected, Func<string, Task> captureAsync)
    {
        int stepNo = steps.Count + 1;
        string relativePath = $"images/flow{flowNo:00}-step{stepNo:00}.png";

        if (stagingRoot is not null)
        {
            string fullPath = Path.Combine(stagingRoot, relativePath);
            Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
            await captureAsync(fullPath);
        }

        steps.Add(new RecordedStep(stepNo, action, expected, relativePath));
    }

    public async Task CaptureFailureAsync(Func<string, Task> captureAsync)
    {
        if (stagingRoot is null)
        {
            return;
        }

        string relativePath = $"failures/flow{flowNo:00}-fail.png";
        string fullPath = Path.Combine(stagingRoot, relativePath);
        Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);

        try
        {
            await captureAsync(fullPath);
            failureImage = relativePath;
        }
        catch (Exception ex)
        {
            // 失敗截圖不應遮蓋原本的測試失敗原因
            TestContext.Out.WriteLine($"Failure screenshot skipped: {ex.Message}");
        }
    }

    public void Complete(string status, string? failureMessage)
    {
        if (stagingRoot is null)
        {
            return;
        }

        RecordedFailure? failure = status == "Passed"
            ? null
            : new RecordedFailure(steps.Count + 1, failureMessage ?? string.Empty, failureImage);

        RecordedFlow record = new(flowNo, flowName, status, steps, failure);
        string path = Path.Combine(stagingRoot, "flows", $"flow{flowNo:00}.json");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(record, JsonOptions));
    }
}
```

`RecordedFlow`、`RecordedStep`、`RecordedFailure` 各自一個檔案：

```csharp
namespace MyApp.E2ETests;

public sealed record RecordedFlow(
    int FlowNo,
    string Flow,
    string Status,
    IReadOnlyList<RecordedStep> Steps,
    RecordedFailure? Failure);

public sealed record RecordedStep(int No, string Action, string Expected, string Image);

public sealed record RecordedFailure(int Step, string Message, string? Image);
```

測試類別的 `[TearDown]` 寫法：

```csharp
[TearDown]
public async Task TearDownAsync()
{
    // SetUp 的 Assume 略過測試時尚未建立 recorder，不寫紀錄
    if (recorder is null)
    {
        return;
    }

    TestStatus outcome = TestContext.CurrentContext.Result.Outcome.Status;

    if (outcome == TestStatus.Failed)
    {
        await recorder.CaptureFailureAsync(path => CaptureAsync(path));
    }

    // NUnit 的 Warning 不在契約的四個值內，視同失敗
    string status = outcome == TestStatus.Warning ? "Failed" : outcome.ToString();
    recorder.Complete(status, TestContext.CurrentContext.Result.Message);
}
```

`CaptureAsync` 依路徑實作：網站路徑見 `web-playwright.md`，視窗程式路徑見 `desktop-flaui.md`。

## Node 專案

`@playwright/test` 專案以 TypeScript 寫出同一份 JSON 契約：

- 在 spec 檔建立對應 `ManualRecorder` 的 helper，`StepAsync` 以 `page.screenshot({ path })` 截圖。
- 在 `test.afterEach` 依 `testInfo.status` 寫出 `flows/flowNN.json`。Playwright Test 的 `passed`、`failed`、`timedOut`、`skipped`、`interrupted` 對應為 `Passed`、`Failed`、`Failed`、`Skipped`、`Failed`。
- 欄位名稱、檔名格式與 staging 結構與本檔一致。
