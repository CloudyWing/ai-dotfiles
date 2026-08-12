# Demo 外框範本

供 `UI Demo` sub-agent 產出 Demo 畫面時複製的起點。範本本身不含任何專案專屬內容，所有視覺數值於複製後依樣式基準檔填入。

## 使用步驟

1. 讀取樣式基準檔 `<work-root>/.local/ai-sessions/baselines/ui-style-baseline.md`。檔案不存在時，先執行 `uiux-baseline` skill 產生。
2. 將本目錄整份複製到 `<work-root>/.local/ai-sessions/ui-demo/<demo-name>/`。`<demo-name>` 取自需求主題，使用 kebab-case。
3. 依基準檔「已統一慣例」節填入 `screens/screen.css` 的 token 值。
4. 以 `screens/_screen-template.html` 為起點，逐一產出畫面檔，檔名對應 `demo-data.js` 的 `id`。
5. 於 `demo-data.js` 登記畫面清單、版面層級與註解資料。
6. 以瀏覽器開啟 `index.html` 確認。無須架站，雙擊即可。

## 完整版與精簡版

| 強度 | 用途 | 保留的檔案 |
| --- | --- | --- |
| 完整版 | 溝通媒介（需求訪談、提案、對客戶） | 全部 |
| 精簡版 | 版面契約（無訪談但版面複雜） | 僅 `screens/` 目錄 |

精簡版不複製 shell，層級說明改寫入 `design.md` 的版面資訊層級章節。

## 畫面層零說明文字（Crucial）

`screens/*.html` 內禁止出現任何說明文字、註解氣泡、標註框或設計備註。畫面層必須可單獨以瀏覽器開啟，且開啟後看到的就是成品外觀。

所有說明只能存在於兩個位置，一是 shell 的說明面板，二是可關閉的註解疊層。註解關閉時，疊層的 DOM 節點會直接被移除，不以隱藏樣式處理，避免在檢視原始碼或列印時外洩。

此規則的理由是 Demo 會被拿去對外展示。畫面上的說明文字會被誤認為實際功能備註，造成對交付範圍的認知落差。

## 技術限制

範本刻意維持零建置與零相依，需遵守下列限制：

- 不使用任何前端框架、CDN 資源、建置工具或套件安裝。
- 不使用 `fetch` 或 XHR。資料以 `demo-data.js` 掛載 `window.DemoData` 提供，因為 `file://` 協定下讀取本機 JSON 會被瀏覽器阻擋。
- shell 不存取 `iframe` 內部的 DOM，僅設定 `src` 與尺寸，避開 `file://` 下的跨文件存取限制。
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
