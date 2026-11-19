---
name: csharp-di
description: '.NET 相依性注入規範：Generic Host 的容器建立、服務註冊慣例、Keyed Services 與 Service Locator 禁令。當撰寫涉及 DI 容器配置（多實作、非 Web 宿主）的程式碼時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# .NET 相依性注入規範

## Generic Host

- **禁止**在 Generic Host 應用程式中手動建立 `ServiceCollection` 再 `BuildServiceProvider()`，除非是單元測試場景。

## 註冊慣例

### 介面與實作分離

- 註冊服務時**必須**以介面為服務型別，具體實作為實作型別。
- 禁止直接註冊具體類別（除非該類別本身就是最終消費端，如 `BackgroundService`）。

### 多實作註冊

- 同一介面的多個實作，優先使用 **Keyed Services**（.NET 8+）區分。

## 禁止模式

- **Service Locator**：禁止在業務邏輯中直接呼叫 `IServiceProvider.GetService<T>()`。服務應透過建構函式注入，而非在方法內自行解析。唯一允許的例外是工廠方法與 `BackgroundService` 內的 Scope 建立。
