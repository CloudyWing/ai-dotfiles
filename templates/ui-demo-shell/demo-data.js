/*
 * Demo 資料範本。
 * 以 script 標籤載入並掛載 window.DemoData，不使用 fetch 讀取 JSON，
 * 確保 file:// 協定下雙擊 index.html 即可開啟。
 *
 * 畫面層保留真實產品文案；設計理由、開發註記、模擬限制與待確認項只放外框或交接資料。
 */
window.DemoData = {
  title: '＜Demo 名稱＞',
  screens: [
    {
      // 畫面識別字，同時作為 screens/ 下的檔名
      id: 'screen-template',

      // 顯示於左側畫面清單
      name: '＜畫面名稱＞',

      // 畫面層檔案的相對路徑
      file: 'screens/_screen-template.html',

      // 一句話說明此畫面的主要目的
      summary: '＜一句話說明此畫面的主要目的＞',

      // 版面層級歸類。level 取 P0 主要動作區 / P1 次要資訊區 / P2 罕用收折區
      // reason 以業務行為陳述，不使用視覺詞彙
      layers: [
        { block: '＜區塊名＞', level: 'P0 主要動作區', reason: '＜以業務行為陳述的理由＞' }
      ],

      // 替身每筆必填非空字串：component: 名稱、samplePath: 絕對樣本位置、
      // contractSource: 指定基準契約定位、differences: 真實元件差異。
      substitutes: [],

      interaction: {
        // 切頁、頁籤、展開、彈窗、驗證回饋的子集，每項須有模式來源。
        allowedOperations: [],
        // 已確認的離線固定假資料，畫面複製後操作，重載重新初始化。
        fixedData: {},
        // 每筆包含 operation 與 source，定位基準模式或使用者確認來源。
        patternSources: [],
        // 尚未確認的操作或能力，只顯示，不封鎖已確認操作。
        pendingItems: []
      },

      // 註解氣泡。x 與 y 為相對於畫面容器可視區左上角的百分比，範圍 0 至 100
      annotations: [
        { no: 1, x: 12, y: 8, text: '＜說明文字＞' }
      ]
    }
  ]
};
