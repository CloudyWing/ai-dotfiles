---
name: generate-api-doc
description: 為 ASP.NET Core Controller 或 Minimal API 自動補齊 XML 文件與 Swagger Attributes，讓 OpenAPI 文件完整呈現。
audience: human
dispatch: dispatchable
disable-model-invocation: true
policy.allow_implicit_invocation: false
---

# 產生 API 文件

為指定的 ASP.NET Core Controller 或 Minimal API 端點補齊 XML 文件註解與 Swagger Attributes。

## 使用方式

```
/generate-api-doc [Controller 檔案路徑或類別名稱]
```

若未傳入參數，掃描當前專案中所有 `*Controller.cs` 檔案，列出清單供使用者選擇。

## 執行步驟

### 1. 讀取目標檔案

讀取指定的 Controller 或 Minimal API 端點定義，識別：

- 所有 Public Action / Endpoint 方法
- 已存在的 XML 文件（避免重複補寫）
- 已存在的 Swagger Attributes（避免重複補寫）
- HTTP 方法與路由（`[HttpGet]`、`[Route]` 等）
- 回傳型別與可能的狀態碼

### 2. 補齊 XML 文件

依 `csharp-docs` skill 規範，為每個 Public 方法補齊：

```csharp
/// <summary>
/// [動詞開頭的第三人稱現在式說明，描述 What 與 Why]
/// </summary>
/// <param name="[paramName]">[參數說明]</param>
/// <returns>[回傳值說明]</returns>
```

規則：

- `<summary>` 以第三人稱現在式動詞開頭（Gets、Creates、Updates、Deletes、Processes）。
- 若方法已有 `<inheritdoc />`，保留不覆蓋。
- 僅補齊缺少的標籤，不移除已有內容。

### 3. 補齊 Swagger Attributes

依 HTTP 方法與回傳型別判斷要加入的 Attributes：

```csharp
[ProducesResponseType(typeof(ResponseDto), StatusCodes.Status200OK)]
[ProducesResponseType(StatusCodes.Status400BadRequest)]
[ProducesResponseType(StatusCodes.Status404NotFound)]
[ProducesResponseType(StatusCodes.Status500InternalServerError)]
```

判斷規則：

- **200 OK**：方法有回傳值時必加，型別填入實際回傳的 DTO。
- **204 No Content**：方法回傳 `void` 或 `IActionResult` 且邏輯無回傳體時。
- **400 Bad Request**：有 `[FromBody]` 或 `[FromQuery]` 參數時，且無 `[ApiController]` 自動驗證（或明確使用 `ModelState.IsValid`）時補加。
- **401 Unauthorized**：方法或 Controller 有 `[Authorize]` 時補加。
- **403 Forbidden**：`[Authorize(Roles = ...)]` 或 Policy 授權時補加。
- **404 Not Found**：方法有 `NotFound()` 呼叫時補加。
- **500 Internal Server Error**：全域例外處理涵蓋時，視專案慣例決定是否加入。

若 Controller 層級已有 `[Produces]` 或 `[ProducesResponseType]`，不重複在 Action 層級加入。

### 4. 補齊 Summary Tag（Swagger UI 用）

若 Action 方法尚無 `[EndpointSummary]`（Minimal API）或 XML `<summary>` 已覆蓋 Swagger 顯示，則不額外加入。

Controller API 的 Swagger 摘要來自 XML `<summary>`，確保存在即可。

### 5. 確認中斷點

在實際寫入檔案前，以下列格式向使用者顯示完整修改預覽：

```csharp
// [方法名稱] — 將新增以下內容：
/// <summary>
/// [說明]
/// </summary>
[ProducesResponseType(typeof(ResponseDto), StatusCodes.Status200OK)]
```

顯示完整預覽後，**停止等待使用者確認**（回覆「確認」或「OK」後）才繼續執行步驟 6。若使用者要求調整，依其指示修改預覽內容後再次確認。

### 6. 輸出修改結果

直接修改原始檔案。完成後輸出摘要：

```markdown
## 修改摘要：OrderController.cs

| 方法 | 補齊 XML 文件 | 補齊 Attributes |
| --- | --- | --- |
| GetById | ✅ | ✅ 200、404 |
| Create | ⏭️ 已存在 | ✅ 201、400、422 |
| Delete | ✅ | ✅ 204、404 |
```

## 注意事項

- 產生的 C# 程式碼遵循專案 `.editorconfig` 與 `csharp-style` skill 的風格規範。
- 若專案使用 `Swashbuckle.AspNetCore` 以外的 OpenAPI 套件，輸出前確認 Attribute 名稱是否相容。
- 不修改業務邏輯，僅新增文件相關的 Attributes 與 XML 註解。
