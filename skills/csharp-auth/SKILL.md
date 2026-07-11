---
name: csharp-auth
description: 'ASP.NET Core 認證授權規範：JWT Bearer 驗證參數、OIDC 整合、Claims 慣例與 Policy 授權。當撰寫或修改認證、授權、Token 驗證相關程式碼時自動套用。'
---

# ASP.NET Core 認證授權規範

當撰寫或修改認證（Authentication）、授權（Authorization）、JWT / OIDC Token 驗證相關程式碼時，請自動套用以下規範。機密管理（signing key、client secret 不落原始碼）依全域 §2 Security Baseline，本文件不重複。

## JWT Bearer 驗證（Crucial）

- 有 OIDC Provider（IdP）時，一律設定 `Authority` 走 discovery 文件自動取得 JWKS，**禁止**在程式碼或設定檔中硬編碼簽章金鑰或手動貼上 JWKS 內容。
- `TokenValidationParameters` 必須明確設定，不依賴預設值：

```csharp
builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options => {
        options.Authority = builder.Configuration["Auth:Authority"];
        options.TokenValidationParameters = new TokenValidationParameters {
            ValidateIssuer = true,
            ValidateAudience = true,
            ValidAudience = builder.Configuration["Auth:Audience"],
            ValidateLifetime = true,
            ClockSkew = TimeSpan.FromMinutes(1)
        };
        options.MapInboundClaims = false;
    });
```

- **ClockSkew**：明確設為 1 分鐘以內，不使用預設的 5 分鐘（過長的容忍值等於延長 Token 有效期）。
- **僅開發環境**允許 `RequireHttpsMetadata = false`，且必須以環境判斷包住，不得寫死。

## Claims 慣例（Crucial）

- 設定 `MapInboundClaims = false`，保留 OIDC 標準 claim 名稱（`sub`、`email`、`name`），**禁止**依賴 Microsoft 舊式 SOAP claim URI（`http://schemas.xmlsoap.org/...`）的自動改名。
- 使用者識別一律取 `sub`，不使用 `NameIdentifier` 與 `sub` 混用；專案內以擴充方法統一取值：

```csharp
public static class ClaimsPrincipalExtensions {
    public static string GetUserId(this ClaimsPrincipal principal) {
        return principal.FindFirstValue("sub")
            ?? throw new InvalidOperationException("Token 缺少 sub claim。");
    }
}
```

- 自訂 claim 使用小寫 snake_case 或短名稱（如 `tenant_id`、`permissions`），跨服務保持一致，不混用 PascalCase。

## 授權策略

- **Policy 優先於 Role 字串**：授權判斷以 Policy 名稱為單位註冊與引用，`[Authorize(Roles = "Admin")]` 僅限單純角色即可表達的情境；複合條件（角色 + claim + 資源）一律走 Policy 或 `IAuthorizationRequirement`。
- Policy 名稱以常數類別集中管理，引用處使用 `nameof()` 或常數，不散落字串。
- **預設拒絕**：對外 API 專案設定 Fallback Policy，未標註的端點預設要求已認證，匿名端點必須明確標 `[AllowAnonymous]`：

```csharp
builder.Services.AddAuthorization(options => {
    options.FallbackPolicy = new AuthorizationPolicyBuilder()
        .RequireAuthenticatedUser()
        .Build();
});
```

- Middleware 順序固定為 `UseAuthentication()` → `UseAuthorization()`，且在 `MapControllers()` / `MapXxx()` 之前。

## 錯誤回應語意

- **401 Unauthorized**：未帶 Token 或 Token 無效；**403 Forbidden**：Token 有效但權限不足。不得混用，也不得以 404 掩蓋 403（除非專案明確採用資源隱藏策略並記錄於設計文件）。
- 401/403 回應格式與全域錯誤處理一致（ProblemDetails，參閱 `csharp-error-handling` skill），不回傳含內部細節的錯誤訊息（如「金鑰驗證失敗於 ...」）。

## 禁止模式

- 禁止自行實作 JWT 簽發與驗證邏輯（自刻 HMAC 比對、手動 Base64 解析 payload 後直接信任內容）。
- 禁止在前端可見的 Token（Access Token）中放入敏感資料；Token payload 視同公開資訊。
- 禁止以 `context.User.Identity.IsAuthenticated` 手動判斷取代 `[Authorize]`（繞過 Policy 與 Fallback 機制）。
- 測試環境繞過認證一律使用測試專用的 AuthenticationHandler（參閱 `csharp-integration-test` skill），禁止在正式程式碼中留「測試後門」旗標。
