/*
 * Demo 資料範本。
 * 以 script 標籤載入並掛載 window.DemoData，不使用 fetch 讀取 JSON，
 * 確保 file:// 協定下雙擊 index.html 即可開啟。
 *
 * 說明文字只放在本檔與 shell 說明面板，畫面層 screens/*.html 內禁止出現任何說明文字。
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

      // 註解氣泡。x 與 y 為相對於畫面容器可視區左上角的百分比，範圍 0 至 100
      annotations: [
        { no: 1, x: 12, y: 8, text: '＜說明文字＞' }
      ]
    }
  ]
};
