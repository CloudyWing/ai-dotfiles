---
name: csharp-silent-defects
description: 'Use when 讀取或修改 C# 程式碼，需要檢查合法且不易在開發環境顯現的執行期、時序、文化、數值、集合順序或資源陷阱時。'
audience: agent
policy.allow_implicit_invocation: true
---

# C# 靜默缺陷規範

本 Skill 收納跨元件的執行期、時序與資源陷阱。規則適用於合法且通常沒有編譯器警告的 C# 程式碼，並與元件專屬 Skill 的唯一歸屬規則並存。

## 四條篩選判準

每條 SD 規則都必須同時符合下列四項判準。任一項不成立時，回到對應的元件專屬 Skill 或一般程式碼規範。

| 判準 | 定義 |
| --- | --- |
| F1 | 使用合法 API 與合法語法，編譯器不產生警告，程式碼表面符合一般 code review 期待。 |
| F2 | 在空資料、小資料量、單一 process、單機、固定文化或無併發的開發與測試條件下不易顯現。 |
| F3 | 使用者可觀察到的輸出、延遲、資料頁面或資源異常位置，與造成異常的初始化、時序、集合或轉換位置分離。 |
| F4 | 根因屬執行期行為、時序或資源，不是命名、格式或單純寫法偏好。 |

## 條目固定格式

每條規則使用唯一的 `SD-XXX` ID，包含一到兩句說明、一條以「機械判準」開頭的可判定條件、F1 至 F4 的收錄結果，以及同一條目中的框架差異說明。

```markdown
### SD-XXX — <條目名稱>

<一到兩句說明。>

機械判準：<若出現條件 X 且沒有條件 Y，即判定違反。>

篩選結果：F1：<結果>；F2：<結果>；F3：<結果>；F4：<結果>。

框架差異：net4x：<表現>；ASP.NET Core：<表現>。
```

## 啟動路徑阻塞

本分類收納 Host、DI、型別初始化與啟動前全量工作的執行期阻塞條目。

### SD-001 — 啟動註冊 factory 執行外部 I/O

啟動或建立 Service Provider 時執行資料庫、檔案、HTTP 或 Redis 的同步外部 I/O，會把相依性解析時間轉成 Host 尚未就緒的延遲。

機械判準：`AddSingleton`、`AddOptions`、`ConfigureServices` 或等效註冊 factory 內直接呼叫外部 I/O，且沒有延後至可取消的背景或請求路徑，即判定違反。

篩選結果：F1：合法 API、無警告；F2：固定設定或本機服務不易暴露；F3：Host 延遲與 factory 根因分離；F4：啟動時序與外部資源。

框架差異：`net4x`：`Application_Start`、OWIN `Startup` 或 Service Locator 建立路徑會同步執行；ASP.NET Core：`Program`、Generic Host 或 DI factory 建立路徑會同步執行。

### SD-002 — static 初始化執行外部 I/O

靜態欄位初始化或 static constructor 進行外部 I/O，會把首次型別使用的延遲或例外投射到不相關的 Endpoint。

機械判準：static initializer 或 static constructor 內出現 `File`、`SqlConnection.Open`、`HttpClient`、Redis connect 或同等外部 I/O，即判定違反。

篩選結果：F1：合法語法、無警告；F2：測試若先完成初始化不易暴露；F3：首次 Endpoint 症狀與型別初始化根因分離；F4：冷啟動時序與外部資源。

框架差異：`net4x` 與 ASP.NET Core 均於首次型別使用時觸發；例外包裝層與 Host 管線不同。

### SD-003 — Options 驗證執行外部呼叫

Options 驗證若查詢外部服務，會在組態建立或 Host 啟動階段把遠端故障轉成整個應用程式無法就緒。

機械判準：`IValidateOptions<T>`、`Validate` callback 或等效驗證 callback 直接執行外部 I/O，且沒有 bounded timeout 與可觀察失敗狀態，即判定違反。

篩選結果：F1：合法介面、無警告；F2：測試常使用靜態組態；F3：啟動失敗與遠端查詢根因分離；F4：驗證時序與網路資源。

框架差異：`net4x`：自訂組態驗證通常掛在 `Startup` 或 `Application_Start`；ASP.NET Core：Options validation 可在建構或首次解析時觸發。

### SD-004 — 建構 pipeline 元件時執行外部 I/O

Middleware、Filter 或 Controller constructor 執行外部 I/O，會使 pipeline 建立或第一個請求承擔未宣告的阻塞。

機械判準：上述 constructor 內含同步或未受 Host readiness 控制的資料庫、檔案、HTTP 或 Redis 呼叫，即判定違反。

篩選結果：F1：合法建構函式、無警告；F2：本機資料源快速時不易看出；F3：Endpoint 延遲與 constructor 根因分離；F4：請求啟動時序與外部資源。

框架差異：`net4x`：MVC Filter、Module 或 Controller factory 可能於請求建立時觸發；ASP.NET Core：Middleware 建構通常在 pipeline 建立時觸發，scoped factory 則可能延至請求。

### SD-005 — readiness gate 等待後續 producer Task

啟動 readiness gate 等待由後續啟動流程才會完成的 Task，會形成無限等待或把相依性註冊順序變成隱性阻塞。

機械判準：啟動方法 await `TaskCompletionSource`、共享初始化 Task 或相依服務 Task，且 producer 在同一啟動 barrier 之後才可執行，沒有 timeout、取消或失敗完成，即判定違反。

篩選結果：F1：合法 Task 使用、無警告；F2：單一服務或已預先完成的 Task 不易暴露；F3：Host 不就緒與 producer 所在路徑分離；F4：Task 時序與啟動資源。

框架差異：`net4x`：OWIN 或自訂啟動 barrier 常以共享 Task 實作；ASP.NET Core：Generic Host 的 sequential startup 會放大未完成 Task 的影響。

### SD-006 — 啟動流程丟棄非同步 Task

啟動流程丟棄非同步 Task，會讓 Host 宣告就緒時必要狀態仍未建立，失敗也沒有回到啟動結果。

機械判準：`Task.Run`、非同步初始化呼叫或 fire-and-forget 委派的 Task 未 await、未保存、未連結取消，且沒有 readiness/status contract，即判定違反。

篩選結果：F1：合法非同步語法、無警告；F2：本機初始化快速時看似已完成；F3：後續請求錯誤與啟動時丟棄 Task 分離；F4：Task 生命週期與錯誤資源。

框架差異：`net4x`：`Application_Start` 或 OWIN 啟動可在背景 Task 仍執行時返回；ASP.NET Core：Host 會視啟動方法返回判定服務啟動，未觀察 Task 不會自動成為失敗。

### SD-007 — Lazy 冷啟動外部 I/O

Lazy 初始化把遠端 I/O 延後至第一個請求，會將冷啟動延遲與失敗轉給任意呼叫端。

機械判準：`Lazy<T>`、`Lazy<Task<T>>` 或 static cache value factory 內有外部 I/O，且沒有預熱結果、timeout 與失敗狀態契約，即判定違反。

篩選結果：F1：合法 Lazy API、無警告；F2：熱身後或單元測試預先觸發不易暴露；F3：第一個 Endpoint 症狀與 lazy factory 根因分離；F4：冷啟動時序與遠端資源。

框架差異：`net4x` 與 ASP.NET Core 均支援 Lazy；例外快取與請求管線重試行為由 Host 實作決定。

### SD-008 — 啟動階段無界全量掃描

啟動階段同步掃描完整資料源或完整檔案樹，會使資料量成長直接轉成程序起動阻塞。

機械判準：`Startup`、Host builder、module initializer 或等效入口在接受流量前呼叫無界 `GetAll`、`ToList`、遞迴檔案掃描或全量 metadata 載入，且沒有上限或背景切換，即判定違反。

篩選結果：F1：合法查詢、無警告；F2：小資料集或空資料集不易暴露；F3：起動時間與全量掃描根因分離；F4：資料量、I/O 與啟動時序。

框架差異：`net4x`：`Application_Start`、Global.asax 或 OWIN 入口承擔掃描；ASP.NET Core：Host builder、`Program` 或 startup filter 承擔掃描。

## 共享狀態與執行緒安全

本分類收納跨請求、背景工作、static、並行集合與取消來源的共享狀態條目。

### SD-009 — Singleton 可變集合跨請求讀寫

Singleton service 保存可變 `List<T>`、`Dictionary<TKey,TValue>` 或 `HashSet<T>`，並由請求與背景工作同時讀寫，會產生遺失更新、列舉例外或不一致輸出。

機械判準：Singleton 的 instance field 是可變集合，且至少有一條請求或背景執行路徑寫入，未使用同一個明確同步策略，即判定違反。

篩選結果：F1：合法型別、無警告；F2：單一請求或單一 process 測試不易暴露；F3：回應資料異常與共享 field 根因分離；F4：共享記憶體與併發時序。

框架差異：`net4x` 與 ASP.NET Core 均可能透過 Singleton 或 static 共享；ASP.NET Core hosted service 使背景寫入更常與請求並行。

### SD-010 — static 可變 buffer 跨呼叫共用

static `StringBuilder`、緩衝區或相似可變工作物件被多個呼叫共用，會把一次輸出的內容混入另一個呼叫。

機械判準：static field 型別為可變 buffer，且方法在無 lock、thread-local 或每次建立新實例的情況下呼叫 `Append`、寫入或清除，即判定違反。

篩選結果：F1：合法成員、無警告；F2：測試序列執行時不易暴露；F3：輸出污染與 static buffer 根因分離；F4：共享資源與執行緒交錯。

框架差異：`net4x` 與 ASP.NET Core 的 static field 生命週期均跨請求；ThreadPool 排程差異可能改變發生頻率。

### SD-011 — shared map check-then-act 競爭窗口

共享 map 的 check-then-act 會讓兩個呼叫同時通過檢查並覆寫彼此結果。

機械判準：同一共享 map 先呼叫 `ContainsKey`、索引讀取或 `Count` 判斷，再於未持有同一同步區段時呼叫 `Add`、索引寫入或移除，即判定違反。

篩選結果：F1：合法集合操作、無警告；F2：單執行緒測試不易暴露；F3：缺少項目或覆寫結果與競爭窗口分離；F4：共享狀態與時序。

框架差異：`net4x` 與 ASP.NET Core 的競爭語意相同；可用的原子 API 版本依目標 framework 判定。

### SD-012 — ConcurrentDictionary factory 副作用重複

`ConcurrentDictionary.GetOrAdd` 或 `AddOrUpdate` 的 factory 可能執行多次，factory 內的發送、寫入或計數副作用會重複。

機械判準：Concurrent dictionary factory 內包含外部 I/O、非冪等寫入、遞增計數或事件發佈，且呼叫端把 factory 執行次數當成一次保證，即判定違反。

篩選結果：F1：合法並行集合 API、無警告；F2：無競爭或 cache hit 測試不易暴露；F3：重複外部效果與字典原子更新根因分離；F4：併發時序與外部資源。

框架差異：`net4x` 與 ASP.NET Core 均不應把 factory invocation 次數當作 exactly-once 契約；方法可用性依 framework 版本。

### SD-013 — IMemoryCache factory 非 single-flight

`IMemoryCache.GetOrCreate` factory 的執行次數不是單飛保證，副作用可能重複或多個請求同時回源。

機械判準：`GetOrCreate`、`GetOrCreateAsync` 或等效 cache factory 內含非冪等外部 I/O，且沒有 per-key lock、single-flight 或冪等保護，即判定違反。

篩選結果：F1：合法 Cache API、無警告；F2：單請求或熱 cache 測試不易暴露；F3：重複回源與 cache factory 根因分離；F4：併發資源與回源時序。

框架差異：`net4x`：`MemoryCache` 的 factory 行為依實作；ASP.NET Core：`IMemoryCache` 也不提供 factory exactly-once 保證。

### SD-014 — lock 內完成 TaskCompletionSource

`TaskCompletionSource.SetResult` 在 lock 內執行時，inline continuation 可能重入共享物件或等待另一把 lock，造成死結或長時間持鎖。

機械判準：lock 區段內呼叫 `SetResult`、`SetException` 或 `SetCanceled`，且 TCS 未以 `TaskCreationOptions.RunContinuationsAsynchronously` 建立，即判定違反。

篩選結果：F1：合法 Task API、無警告；F2：沒有同步 continuation 或低競爭測試不易暴露；F3：請求卡住與 completion lock 根因分離；F4：Continuation 排程與 lock 資源。

框架差異：`net4x` 與 ASP.NET Core 均可能 inline continuation；可用的 TCS 建構式依 C# 與 framework 版本調整。

### SD-015 — lock 外返回共享集合或 deferred IEnumerable

共享集合在 lock 內取出後以可變引用或 deferred `IEnumerable<T>` 返回，呼叫端會在 lock 外觀察到被修改的內容。

機械判準：同步區段返回內部集合、`IEnumerable<T>` 或 iterator，且沒有 snapshot、不可變複本或 lock 外的生命週期契約，即判定違反。

篩選結果：F1：合法集合回傳、無警告；F2：小資料或無同時寫入測試不易暴露；F3：回應列舉錯誤與 lock 釋放後的共享引用分離；F4：共享記憶體與列舉時序。

框架差異：`net4x` 與 ASP.NET Core 的 deferred execution 語意相同；ASP.NET Core 請求並行度可能提高暴露機率。

### SD-016 — 跨請求共用 CancellationTokenSource

多個請求共用同一 `CancellationTokenSource`，一個請求取消會中斷其他請求，或 reset 會重用仍被舊工作持有的 token。

機械判準：request-scoped operation 使用 static、Singleton 或跨請求 field 的 CTS，且取消與工作生命週期沒有一對一對應，即判定違反。

篩選結果：F1：合法取消 API、無警告；F2：單請求測試不易暴露；F3：其他請求取消與共享 CTS 根因分離；F4：取消時序與共享資源。

框架差異：`net4x`：沒有現代 `TryReset`，應重新建立 CTS；ASP.NET Core 現代 .NET 可用 `TryReset`，但僅限確認所有舊 consumer 已完成後。

## 時間

本分類收納 elapsed duration、point-in-time / ordering、calendar / business date 與 deadline / timeout 的時間條目。

| 用途 | 判定重點 |
| --- | --- |
| elapsed duration | 使用單調時鐘量測經過時間，避免牆上時鐘調整影響結果。 |
| point-in-time / ordering | 儲存與比較帶有明確時區及精度的時間點，避免排序鍵碰撞。 |
| calendar / business date | 依業務時區與日曆邊界計算日期，不把固定秒數當成日曆規則。 |
| deadline / timeout | 先建立單一絕對 deadline，再把剩餘時間傳給每個操作。 |

### SD-017 — 以 wall-clock subtraction 量測 elapsed duration

用 `DateTime.Now` 或 `DateTime.UtcNow` 相減量測工作耗時，系統校時會讓耗時變負數或突然增加。

機械判準：經過時間、重試間隔或效能量測以 wall-clock subtraction 計算，而非 `Stopwatch` 或等效單調時鐘，即判定違反。

篩選結果：F1：合法 DateTime API、無警告；F2：時鐘穩定的測試不易暴露；F3：SLA 或 retry 異常與量測來源分離；F4：時間來源與執行期時序。

框架差異：`net4x`：使用 `Stopwatch`；ASP.NET Core：可使用 `Stopwatch` 或注入 `TimeProvider`，兩者都不以 wall clock 相減量測 elapsed。

### SD-018 — 以截斷 timestamp 估算 elapsed duration 或 lease

以截斷到秒或毫秒的事件時間戳估算工作耗時，短工作會被算成零，長工作會因精度差異錯誤過期。

機械判準：將 `DateTime`、`DateTimeOffset` 或資料庫 timestamp 先 `Truncate`、格式化或轉整數，再用於 elapsed、lease 或 retry 判斷，即判定違反。

篩選結果：F1：合法轉換、無警告；F2：小資料與長間隔測試不易暴露；F3：過期或零耗時結果與精度截斷根因分離；F4：時間精度與資源租約。

框架差異：`net4x` 與 ASP.NET Core 都可能有資料庫或序列化精度落差；測量 elapsed 仍須使用單調時鐘。

### SD-019 — 混用 local、UTC、Unspecified 或未帶 offset 時間點

將 local `DateTime`、UTC `DateTime` 與帶 offset 的 `DateTimeOffset` 混存或直接比較，會使跨服務的先後判斷受來源設定影響。

機械判準：同一資料欄位或排序流程混用 `DateTimeKind.Local`、`Utc`、`Unspecified` 或未標示 offset 的字串，即判定違反。

篩選結果：F1：合法時間型別、無警告；F2：單機同時區測試不易暴露；F3：跨服務排序或增量查詢異常與來源 Kind 分離；F4：時間點與序列化資源。

框架差異：`net4x` 與 ASP.NET Core 均不會替混用的 `DateTimeKind` 自動補齊業務語意；ASP.NET Core 可用 `TimeProvider` 取得明確 UTC 時間。

### SD-020 — 低精度 timestamp 作為排序或唯一鍵

以低精度時間戳作為 last-write-wins、cursor 或去重唯一鍵，快速連續事件會互相覆寫。

機械判準：事件唯一性或排序只使用秒、毫秒或資料庫截斷時間，未追加唯一序號、資料庫 identity 或其他穩定 tie-breaker，即判定違反。

篩選結果：F1：合法欄位與比較、無警告；F2：低流量測試不易暴露；F3：遺失事件或順序錯誤與時間精度根因分離；F4：時間精度與資料資源。

框架差異：`net4x` 與 ASP.NET Core 均需顯式追加唯一鍵；序列化與資料庫 precision 依使用的 provider 判定。

### SD-021 — 以固定 24 小時代替 calendar day

用 `AddHours(24)` 或固定 24 小時代替下一個業務日，日曆邊界可能因時區規則而偏移。

機械判準：業務日、每日截止或下一次日曆事件以固定小時數推算，未使用指定時區的 calendar conversion，即判定違反。

篩選結果：F1：合法 DateTime API、無警告；F2：沒有日曆邊界變化的測試不易暴露；F3：報表日或排程日錯誤與固定時數根因分離；F4：日曆規則與時間資源。

框架差異：`net4x`：以 `TimeZoneInfo` 與注入時鐘實作；ASP.NET Core：可用 `TimeZoneInfo`，支援的現代 .NET 另可透過 `TimeProvider` 注入目前時間。

### SD-022 — 以 server local date 判定 business date

直接使用伺服器 `DateTime.Today` 或 `DateTime.Now.Date` 判定業務日，多地部署時會把機器所在地當成業務時區。

機械判準：業務日判斷直接讀 process local date，且沒有明確的 business time zone 參數或轉換，即判定違反。

篩選結果：F1：合法系統時間、無警告；F2：開發機與正式機同時區時不易暴露；F3：日結、報表或快取分區錯誤與伺服器時區根因分離；F4：日曆來源與部署資源。

框架差異：`net4x` 與 ASP.NET Core 都需顯式使用業務時區；ASP.NET Core 的 request culture 不等於業務時區。

### SD-023 — retry 每次重設 timeout

每次 retry 都重新建立完整 timeout，會讓多次等待累加超過呼叫端承諾的總時限。

機械判準：retry loop 在每次迭代重新設定 `CancelAfter(timeout)`、HTTP timeout 或等待上限，未先建立絕對 deadline 並傳遞剩餘時間，即判定違反。

篩選結果：F1：合法 retry API、無警告；F2：單次成功或無延遲測試不易暴露；F3：總延遲超標與 retry 內重設 timeout 根因分離；F4：期限時序與外部資源。

框架差異：`net4x`：以注入 clock 加 `DateTimeOffset` 計算 deadline；ASP.NET Core：支援的現代 .NET 可用 `TimeProvider`，CancellationToken 仍需逐層傳遞。

### SD-024 — 混淆 timeout cancellation 與 caller cancellation

把 timeout 觸發的取消當成成功，或把呼叫端取消當成可重試錯誤，會讓未完成工作靜默遺失或持續佔用資源。

機械判準：catch `OperationCanceledException` 後無條件回傳成功、無條件 retry，或未檢查 caller token 與 timeout token 的來源，即判定違反。

篩選結果：F1：合法例外處理、無警告；F2：無取消或寬鬆 timeout 測試不易暴露；F3：成功回應或重試風暴與取消來源根因分離；F4：取消時序與資源生命週期。

框架差異：`net4x` 與 ASP.NET Core 都需區分 caller cancellation 與 operation timeout；ASP.NET Core pipeline 通常提供 request-aborted token。

## 數值與捨入

本分類收納浮點邊界、decimal 轉換、捨入位置與數值比較的執行期條目。

### SD-025 — Math.Pow 與 Math.Log 的單向短程轉換

`Math.Pow` 與 `Math.Log` 的灰帶計算採單向短程進 `double`，結果立即回 `decimal`，並在明確邊界只捨入一次。

機械判準：若金融或精確業務流程呼叫 `Math.Pow` 或 `Math.Log`，必須可見 `decimal -> double -> Math.Pow/Math.Log -> decimal` 的單向短程，且後續流程只有一個明示捨入點；反覆 double / decimal 往返或中途捨入即判定違反。

篩選結果：F1：合法數學 API、無警告；F2：一般值與小資料測試不易暴露精度差；F3：最終金額與中間轉換根因分離；F4：浮點資源與精度時序。

框架差異：`net4x` 與 ASP.NET Core 都使用 `Math.Pow`、`Math.Log`；`double.IsFinite` 的可用性不同，需依 SD-029 的框架規則處理。

### SD-026 — 金融流程明示 MidpointRounding

`MidpointRounding` 預設值是可觀察的業務行為，不能把 runtime default 當成金額規則。

機械判準：金融、稅額或計費流程呼叫 `Math.Round`、`decimal.Round` 或等效 API 時，未明示 `MidpointRounding` 即判定違反。

篩選結果：F1：合法 overload、無警告；F2：非 midpoint 的資料不易暴露；F3：金額差異與預設捨入模式根因分離；F4：數值語意與 runtime default。

框架差異：`net4x` 與 ASP.NET Core 均要求明示 `MidpointRounding`；可用列舉值依目標 framework 版本確認。

### SD-027 — 先聚合再於邊界單次捨入

捨入位置會改變總額，逐項捨入與總和後捨入不能由實作自由選擇。

機械判準：集合聚合的 `Select`、迴圈或每筆轉換內呼叫捨入，再於後續加總，且沒有設計文件指定此為業務規則；預設要求先完成精確聚合，再於輸出邊界捨入一次，即判定違反。

篩選結果：F1：合法 LINQ / decimal API、無警告；F2：小筆數或整數金額不易暴露；F3：總額差異與逐筆捨入位置分離；F4：數值運算順序。

框架差異：`net4x` 與 ASP.NET Core 的 decimal 加總語意相同；EF provider 投影時仍需確認捨入落點。

### SD-028 — 整數除法在轉型前截斷

整數除法在轉型前已截斷小數，後續轉成 `decimal` 無法恢復比例。

機械判準：`/` 左右兩側皆為整數型別，結果先被 cast、assign 或傳入 decimal API，且沒有先將至少一側轉為 decimal，即判定違反。

篩選結果：F1：合法算術、無警告；F2：整除或小數結果未被測試時不易暴露；F3：比例或百分比錯誤與轉型位置分離；F4：數值型別與運算順序。

框架差異：`net4x` 與 ASP.NET Core 的整數除法語意相同；nullable 與 checked context 不改變此截斷結果。

### SD-029 — double 回轉 decimal 前檢查有限值與範圍

`double.NaN`、正負 infinity 或超出 decimal 範圍的值在回到 decimal 時會失敗或造成未處理例外。

機械判準：`double` 回轉 `decimal` 前未檢查 `IsNaN`、`IsInfinity` 或有限範圍，即判定違反；現代 .NET 可用 `double.IsFinite`，仍須檢查 decimal 範圍。

篩選結果：F1：合法轉型、無警告；F2：正常輸入與小數值測試不易暴露；F3：API 例外與數學輸入根因分離；F4：數值範圍與 runtime 資源。

框架差異：`net4x`：使用 `double.IsNaN` 與 `double.IsInfinity`；ASP.NET Core 現代 .NET：可使用 `double.IsFinite`，仍需檢查 decimal 範圍。

### SD-030 — 金額使用 double 累加

金額或精確數量以 `double` 累加，再在回應邊界才轉成 `decimal`，會讓二進位浮點誤差累積到不可逆。

機械判準：金融欄位、金額 DTO 或計費 accumulator 使用 `double`，且不屬於 SD-025 的單向數學灰帶，即判定違反。

篩選結果：F1：合法型別與運算、無警告；F2：小筆數與可整除值不易暴露；F3：最終金額誤差與 accumulator 型別分離；F4：數值精度與記憶體資料。

框架差異：`net4x` 與 ASP.NET Core 都應以 decimal 保存金額；數學 library 的 double 邊界只適用 SD-025。

### SD-031 — Convert.ToInt32 與 cast 的 rounding policy

`Convert.ToInt32(double)` 採 midpoint rounding，直接 cast 則截斷，兩者不能在索引、數量或金額單位轉換中隨意替換。

機械判準：以單一 `Convert.ToInt32` 呼叫或單一明確整數 cast expression 為判定單位。對 `Convert.ToInt32`，檢查範圍是該呼叫的引數表達式；對 `(int)doubleExpression`，檢查範圍是 cast expression 內被轉型的 operand expression，包含其完整子表達式，不延伸到外層宣告、賦值或呼叫端包裝。因此 `Convert.ToInt32(x)` 與 `(int)x` 的檢查範圍都是 `x`。當對應範圍可產生非整數 `double`，且該範圍內沒有明示 truncation、floor、ceiling 或 midpoint policy，即判定違反。

篩選結果：F1：合法轉換 API、無警告；F2：整數輸入不易暴露；F3：數量差異與轉換 API 根因分離；F4：數值轉換語意。

框架差異：`net4x` 與 ASP.NET Core 的 `Convert.ToInt32` 與 cast 語意均須明示；負數邊界也必須納入判定。

### SD-032 — 以 double.Epsilon 取代尺度化 tolerance

以 `double.Epsilon` 作為一般計算的誤差容許值，幾乎等同要求 bit-level 相等，會讓本應相等的結果被判定為不同。

機械判準：浮點結果比較固定使用 `double.Epsilon`，且沒有依業務尺度定義 absolute 或 relative tolerance，即判定違反。

篩選結果：F1：合法常數與比較、無警告；F2：小數值或完全相同輸入測試不易暴露；F3：判定分支錯誤與 tolerance 選擇分離；F4：浮點 runtime 語意。

框架差異：`net4x` 與 ASP.NET Core 的 `double.Epsilon` 語意相同；可用的數學 helper 依 framework 版本選擇。

## 文化與字串解析

本分類收納人類表示、機器表示、文化 provider、解析與 identifier 比較的條目。

### SD-033 — 機器數字輸入缺少明確文化

機器輸入使用目前文化解析數字，會在小數點與千分位符號不同的環境得到不同值。

機械判準：來自 DB、HTTP、Redis、檔案、設定或 protocol 的數字呼叫 `Parse`、`TryParse` 或 model conversion，未傳入 `InvariantCulture` 或明確 provider；人類輸入是明示 culture 的例外，即判定違反。

篩選結果：F1：合法 Parse overload、無警告；F2：開發與正式文化相同時不易暴露；F3：數值結果與解析文化根因分離；F4：解析 runtime 行為。

框架差異：`net4x` 與 ASP.NET Core 的 `System.Globalization` API 相同；ASP.NET Core model binding 的 provider 仍需由設計明示。

### SD-034 — 機器時間輸入缺少明確 wire format

機器時間字串使用目前文化或 implicit parse，會把日期順序與 AM/PM 語意交給部署文化。

機械判準：外部機器時間呼叫 `DateTime.Parse`、`DateTimeOffset.Parse` 或無 provider 的等效 API，未使用 ISO round-trip、`ParseExact` 加 invariant provider 或明確 wire format，即判定違反。

篩選結果：F1：合法日期 API、無警告；F2：單一地區測試不易暴露；F3：時間點錯誤與解析文化根因分離；F4：解析 runtime 與時間資源。

框架差異：`net4x` 與 ASP.NET Core 均應使用明確 wire format；model binder、JSON formatter 與舊版 MVC 的預設 provider 可能不同。

### SD-035 — machine output 使用目前文化格式化

機器欄位以 `ToString()` 或插值使用目前文化格式化後才寫入 DB、Cache、Key 或 signature，回讀或比對會依文化改變。

機械判準：machine output 的數字、日期或 decimal 呼叫無 provider 的 `ToString()`，或在儲存、Key、signature 路徑使用未指定格式的 interpolation，即判定違反。

篩選結果：F1：合法格式化、無警告；F2：文化固定時不易暴露；F3：回讀或 signature 失敗與格式化根因分離；F4：字串資源與文化 runtime。

框架差異：`net4x` 與 ASP.NET Core 均要求 machine output 使用 `InvariantCulture` 與明確格式；UI output 可使用指定人類 culture。

### SD-036 — machine identifier 使用 CurrentCulture comparer

機器識別值使用 `CurrentCulture` comparer，會使大小寫、排序或等值判定受使用者或 process culture 影響。

機械判準：ID、Cache Key、Header、protocol token 或資料庫代碼使用 `StringComparer.CurrentCulture`、`CurrentCultureIgnoreCase` 或 culture-sensitive `Compare`，即判定違反。

篩選結果：F1：合法 comparer、無警告；F2：單一文化測試不易暴露；F3：去重或查找差異與 comparer 根因分離；F4：字串比較 runtime。

框架差異：`net4x` 與 ASP.NET Core 均應使用 `Ordinal` 或 `OrdinalIgnoreCase`；目前 culture 可透過 request 或 process 設定改變。

### SD-037 — machine identifier 使用無參數大小寫轉換

用無參數 `ToLower()` 或 `ToUpper()` 正規化機器識別值，會讓字元映射依文化改變。

機械判準：ID、Key、token 或 protocol field 呼叫無參數 `ToLower` / `ToUpper`，且未改用 `ToLowerInvariant`、`ToUpperInvariant` 或 ordinal equality，即判定違反。

篩選結果：F1：合法字串 API、無警告；F2：開發文化與正式文化相同時不易暴露；F3：Key miss 或 token mismatch 與正規化根因分離；F4：字串文化 runtime。

框架差異：`net4x` 與 ASP.NET Core 均支援 invariant normalization；Unicode 與 comparer 行為仍需保持同一策略。

### SD-038 — machine token Regex 缺少 CultureInvariant

Regex 對機器 token 使用 `IgnoreCase` 卻未指定 `CultureInvariant`，會把文化規則帶入 protocol 判定。

機械判準：machine token 的 `Regex` 或 `RegexOptions` 包含 `IgnoreCase`，但沒有 `CultureInvariant`，且結果用於驗證、路由、Key 或 protocol，即判定違反。

篩選結果：F1：合法 Regex options、無警告；F2：單一 culture 測試不易暴露；F3：驗證分支與 regex culture 根因分離；F4：Regex runtime 與文化資源。

框架差異：`net4x` 與 ASP.NET Core 的 `RegexOptions.CultureInvariant` 均應依目標 framework 使用；避免以 UI culture 影響 machine token。

### SD-039 — 共用 human formatted string 到 machine path

將人類格式化字串同時送給 UI 與機器儲存，會讓其中一條路徑因文化變動而無法回讀。

機械判準：同一個 `formatted`、插值結果或 `ToString` 結果同時傳入 UI、報表與 DB、Cache、Key、signature 或 API machine field，即判定違反。

篩選結果：F1：合法資料流、無警告；F2：單一文化或只驗 UI 測試不易暴露；F3：回讀錯誤與共享表示根因分離；F4：字串表示與文化資源。

框架差異：`net4x` 與 ASP.NET Core 都需拆分 human representation 與 machine representation；框架 formatter 不改變此邊界。

### SD-040 — machine composite formatting 缺少 provider

`string.Format`、`FormattableString` 或 composite formatting 未指定 provider 時，machine protocol 或 hash input 會採用目前文化。

機械判準：machine output 路徑呼叫無 provider 的 composite formatting overload，且未在後續使用明確 invariant representation，即判定違反。

篩選結果：F1：合法 formatting overload、無警告；F2：文化固定時不易暴露；F3：hash、cache 或 wire mismatch 與 provider 缺失根因分離；F4：格式化 runtime 與文化資源。

框架差異：`net4x` 與 ASP.NET Core 均需在 composite formatting 邊界指定 `InvariantCulture`；UI 文字可指定人類 culture。

### SD-041 — zh-TW TaiwanCalendar 與機器日期字串

`zh-TW` 的預設行事曆為 `TaiwanCalendar`。`DateTime` 的 `ToString` 與 `Parse` 在該文化下會產生或解讀民國年，同一份程式在不同地區設定的機器上會得到不同結果。

機械判準：日期字串的讀者是機器時，一律以 InvariantCulture 搭配明確格式字串處理，不依賴執行環境的文化預設，即判定違反。

篩選結果：F1：合法 DateTime API、無警告；F2：固定機器文化或單一地區設定測試不易暴露；F3：日期值差異與 culture default 根因分離；F4：文化、解析與執行期設定。

框架差異：`net4x` 與 ASP.NET Core 均可能受 `zh-TW` 的 TaiwanCalendar 影響；`DateTime` 的 ToString 與 Parse 需顯式指定 invariant provider 與格式。

## 集合順序保證

本分類收納集合列舉、平行完成順序、佇列順序與序列化順序的執行期條目。資料庫分頁查詢的唯一排序鍵由 `ef-core` 與 `sql-query` 唯一承擔。

### SD-042 — 依賴 Dictionary 列舉順序

依賴 `Dictionary<TKey,TValue>` 列舉順序產生 API、Cache、signature 或報表輸出，會把實作細節誤當成契約。

機械判準：Dictionary 直接轉成有序輸出、逐項簽章或拿來代表 business rank，且沒有明確 `OrderBy` 或儲存的 sequence 欄位，即判定違反。

篩選結果：F1：合法列舉、無警告；F2：小資料與固定 runtime 常呈現相同順序；F3：輸出差異與 map 列舉根因分離；F4：集合 runtime 與序列化資源。

框架差異：`net4x`：Dictionary 順序不提供契約；ASP.NET Core 現代 .NET 即使目前常保留插入順序，也不可當成公開契約。

### SD-043 — 依賴無序集合的 business order

`HashSet<T>`、`ConcurrentBag<T>` 或其他無序集合的列舉順序不能代表輸入順序或優先順序。

機械判準：上述集合直接作為 API list、批次順序、UI 順序或 signature input，且沒有排序鍵或 sequence metadata，即判定違反。

篩選結果：F1：合法集合 API、無警告；F2：小集合與固定雜湊狀態不易暴露；F3：輸出順序與雜湊集合根因分離；F4：集合 runtime 與執行緒資源。

框架差異：`net4x` 與 ASP.NET Core 均不保證此類集合的 business order；ConcurrentBag 還可能反映不同 thread 的完成順序。

### SD-044 — 未排序 Distinct、GroupBy 或 ToLookup 結果

`Distinct`、`GroupBy` 或 `ToLookup` 的結果直接被當成業務順序，會讓來源、provider 或實作差異改變輸出。

機械判準：這些 operator 的結果未經明確 `OrderBy` / `ThenBy`，即傳入有順序意義的回應、批次或頁面，即判定違反。

篩選結果：F1：合法 LINQ、無警告；F2：小資料與穩定來源不易暴露；F3：順序差異與 deferred / provider 行為分離；F4：集合執行期與 provider 資源。

框架差異：`net4x` 與 ASP.NET Core 的 LINQ to Objects 與 `IQueryable` provider 可能有不同執行時機；輸出契約仍需明確排序。

### SD-045 — 平行處理使用 worker 完成順序

平行處理後把完成順序當成輸入順序，會使回應或批次結果在負載改變時重排。

機械判準：`Parallel.ForEach`、多工作 producer 或 `ConcurrentBag` 收集結果後，未使用輸入 index、sequence number 或 final sort 即輸出，即判定違反。

篩選結果：F1：合法平行 API、無警告；F2：小資料與單執行緒排程不易暴露；F3：結果順序與 worker 完成時序分離；F4：執行緒排程與集合資源。

框架差異：`net4x` 與 ASP.NET Core 都不保證平行工作完成順序；ThreadPool 與工作量會改變結果排列。

### SD-046 — Task.WhenAny 結果直接 append

以 `Task.WhenAny` 收集完成結果並直接 append，會把完成順序當成邏輯順序。

機械判準：`WhenAny` loop 內將完成 task 結果 append 到輸出集合，且沒有原始 index、排序鍵或明確完成順序契約，即判定違反。

篩選結果：F1：合法 Task API、無警告；F2：每個工作耗時相同的測試不易暴露；F3：回應重排與 completion order 根因分離；F4：Task 排程與記憶體集合。

框架差異：`net4x` 與 ASP.NET Core 的 `Task` 排程均不保證完成順序；若要保留輸入順序應以 index 配對。

### SD-047 — 多 producer Channel 使用 dequeue 順序

多 producer Channel 或 `IAsyncEnumerable` 的 dequeue 順序是排程結果，不等於來源事件的業務順序。

機械判準：多個 writer 將事件寫入 Channel，consumer 未讀取 sequence number、partition key 或排序緩衝，即以 dequeue 順序更新狀態或輸出，即判定違反。

篩選結果：F1：合法 Channel / async stream、無警告；F2：單 producer 或低負載測試不易暴露；F3：狀態順序錯誤與 producer 排程根因分離；F4：執行緒時序與佇列資源。

框架差異：`net4x`：若使用自訂 queue 也需明確 sequence；ASP.NET Core：`System.Threading.Channels` 與 async stream 不提供跨 producer 的 business order。

### SD-048 — 非唯一 OrderBy 缺少唯一 tie-breaker

只依非唯一欄位 `OrderBy` 排序，不能保證相同 key 的相對順序，跨執行緒、provider 或頁面輸出可能漂移。

機械判準：有順序契約的結果只 `OrderBy` 非唯一欄位，未追加唯一 `ThenBy`、identity 或 sequence；資料庫分頁例外由 `ef-core` 與 `sql-query` 補回，即判定違反。

篩選結果：F1：合法排序 API、無警告；F2：測試資料通常沒有相同 key；F3：同 key 重排與缺少 tie-breaker 根因分離；F4：集合排序與 provider 資源。

框架差異：`net4x` 與 ASP.NET Core 均需顯式追加唯一 tie-breaker；資料來源 provider 可能採不同穩定排序。

### SD-049 — raw serialization 順序用於 byte contract

將 Dictionary 或無序物件直接序列化後拿 raw JSON 做 signature、cache key 或 byte-level diff，會把 property order 當成契約。

機械判準：raw serialization 結果用於 hash、signature、cache key 或 byte comparison，且未先 canonicalize key order 或使用明確排序結構，即判定違反。

篩選結果：F1：合法 serializer、無警告；F2：固定 serializer 與小資料常呈現同一輸出；F3：signature / cache miss 與序列化順序根因分離；F4：序列化 runtime 與記憶體資源。

框架差異：`net4x` 與 ASP.NET Core 使用的 serializer、Dictionary 實作與設定可能不同；公開 byte contract 必須自行 canonicalize。
