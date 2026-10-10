# Demo 外框範本

供 `Prototyper` sub-agent 產出 Demo 畫面時複製的起點。範本本身不含任何專案專屬內容，所有視覺數值於複製後依樣式基準檔填入。

## 使用步驟

以下步驟適用完整版。精簡版只執行步驟 1、3、4 並產出 `screens/` 目錄，其餘依下節「完整版與精簡版」處理。

1. 依 `skills/uiux/SKILL.md`「基準輸入與確認狀態」核對呼叫端選定的 app-name、baseline-path、sample-path、用途及 confirmed-choices。錯配時停止並指出缺件位置；缺基準交回協調者依 `uiux-baseline`「協調者基準準備」處理。
2. 將本目錄整份複製到 `<work-root>/.local/ai-sessions/ui-demo/<demo-name>/`。`<demo-name>` 取自需求主題，使用 kebab-case。
3. 依指定 baseline-path 的「已統一慣例」及 confirmed-choices 填入 `screens/screen.css` 的 token 值；候選與正式採用依 `uiux` 的同一程序。
4. 以 `screens/_screen-template.html` 為起點，逐一產出畫面檔，檔名對應 `demo-data.js` 的 `id`。
5. 於 `demo-data.js` 登記畫面清單、版面層級、註解及下方「替身與有限互動」的宣告資料；依該章初始化畫面固定資料。
6. 以瀏覽器開啟 `index.html` 確認。無須架站，雙擊即可。

## 完整版與精簡版

| 強度 | 用途 | 保留的檔案 |
| --- | --- | --- |
| 完整版 | 溝通媒介（需求訪談、提案、對客戶） | 全部 |
| 精簡版 | 版面契約（無訪談但版面複雜） | 僅 `screens/` 目錄 |

精簡版不複製 shell，層級說明改寫入 `design.md` 的版面資訊層級章節。

## 產品文案與設計註記分離（Crucial）

畫面層保留真實產品文案，例如日期格式提示、必填錯誤、空資料引導與業務備註欄位；設計理由、開發註記、模擬限制與待確認項只放外框或交接資料。畫面層須可單獨開啟並呈現成品外觀。

完整版將設計註記放入外框說明面板與可關閉的座標註解；精簡版放入交接資料。進入操作時關閉座標註解，關閉時移除疊層與註解清單 DOM；開啟註解時 iframe 唯讀。

## 替身與有限互動

先以呼叫端的 sample-path 與 baseline-path 對照元件，替身外觀取自樣本頁，操作方式與能力依元件契約。樣本無 JS 而無法重現的外觀列入差異及待確認，正式交付前由協調者釐清，不宣稱已相符。

1. 逐畫面填 substitutes。每筆 component、samplePath、contractSource、differences 皆為非空字串，分別記錄替身名稱、絕對樣本路徑、指定基準的契約定位及真實元件差異。無替身填空陣列，完整版外框顯示「無替身」；精簡版交接資料明記相同結論。
2. 填 interaction.allowedOperations，僅宣告切頁、頁籤、展開、彈窗、驗證回饋五種操作的子集。每項須有基準記錄或使用者確認來源，記於 patternSources 的 operation 與 source。未記錄能力或流程填入 pendingItems，交回協調者並停止該正式流程，不自行設計。pendingItems 只顯示，不封鎖已確認操作。
3. 填 interaction.fixedData，使用已確認的離線固定假資料物件，以本機原生 JS 模擬必要操作；範本預設為空物件，不虛構日曆、業務紀錄或能力。allowedOperations、patternSources、pendingItems 預設空陣列。allowedOperations 為空時外框顯示「僅供檢視」，重設仍可用。
4. 完整版外框呈現替身清單、差異、固定資料摘要、模式來源及待確認項。精簡版僅產 screens，將同一份宣告與限制放入協調者交接資料；版面層級另交 Architect，維持產品畫面與設計註記分離。

### 固定資料初始化與重設

完整版每個畫面以本機 script 載入同一份 ../demo-data.js，在 body 的 data-screen-id 填自身 screen.id，取得 interaction.fixedData 後複製為可變操作狀態，保留固定物件原值。以下腳本內嵌在畫面底部；畫面的呈現及已確認事件處理使用 demoState，不新增獨立腳本檔。

~~~html
<script src="../demo-data.js"></script>
<script>
  var screenId = document.body.getAttribute('data-screen-id');
  var screenData = window.DemoData.screens.find(function (screen) {
    return screen.id === screenId;
  });
  var fixedData = screenData && screenData.interaction
    ? screenData.interaction.fixedData || {}
    : {};
  var demoState = JSON.parse(JSON.stringify(fixedData));
  document.addEventListener('submit', function (event) {
    event.preventDefault();
  });
</script>
~~~

精簡版把同一份已確認固定資料內嵌於畫面腳本，複製為操作狀態；提交同樣以 type=button 或 preventDefault 阻擋原生表單網路送出。兩種形式均不使用 fetch、XHR、WebSocket、外部導航、真實寫入或 localStorage。

完整版使用外框 resetDemo 重設入口，先關閉座標註解，再重載目前本機畫面，保留選取索引；畫面重新複製固定資料並還原初始狀態。精簡版以重載本機頁面為重設入口，交接資料記錄開啟方式。外框只呈現宣告，不讀取 iframe DOM 或內頁狀態，不增加訊息橋接。

## 技術限制

範本刻意維持零建置與零相依，需遵守下列限制：

- 不使用任何前端框架、CDN 資源、建置工具或套件安裝。
- 不使用 `fetch` 或 XHR。資料以 `demo-data.js` 掛載 `window.DemoData` 提供，因為 `file://` 協定下讀取本機 JSON 會被瀏覽器阻擋。
- shell 不存取 `iframe` 內部的 DOM，僅設定 `src`、尺寸及註解互斥的操作狀態，避開 `file://` 下的跨文件存取限制。
- 註解氣泡以百分比座標定位於 `iframe` 上方的疊層，座標範圍 0 至 100。

## 檔案結構

```plaintext
ui-demo-shell/
├── index.html          # shell 外框：畫面清單、畫面容器、說明面板、工具列
├── shell.css           # 外框樣式，選擇器一律 .shell- 前綴
├── shell.js            # 畫面切換、註解疊層、viewport 切換、面板收合
├── demo-data.js        # 畫面清單、層級說明與註解資料
├── README.md           # 本文件
└── screens/
    ├── _screen-template.html   # 純畫面層骨架
    └── screen.css              # 畫面層共用樣式與 token
```
