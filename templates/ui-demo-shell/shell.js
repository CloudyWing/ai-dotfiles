/*
 * Demo 外框行為。
 * 僅使用原生 DOM API，不引入任何框架、CDN 資源、fetch 或 XHR。
 * 資料來源為 demo-data.js 掛載的 window.DemoData，確保 file:// 協定下可直接雙擊開啟。
 */
(function () {
  'use strict';

  var data = window.DemoData || { title: 'UI Demo', screens: [] };

  var currentScreenIndex = 0;
  var annotationOn = false;
  var frameWidth = 1280;

  var el = {
    title: document.getElementById('shellTitle'),
    screenList: document.getElementById('screenList'),
    frame: document.getElementById('screenFrame'),
    frameWrap: document.getElementById('frameWrap'),
    overlay: document.getElementById('annotationOverlay'),
    summary: document.getElementById('screenSummary'),
    layerRows: document.getElementById('layerRows'),
    annotationSection: document.getElementById('annotationSection'),
    annotationList: document.getElementById('annotationList'),
    annotationToggle: document.getElementById('annotationToggle'),
    panel: document.getElementById('infoPanel'),
    panelToggle: document.getElementById('panelToggle')
  };

  function currentScreen() {
    return data.screens[currentScreenIndex] || null;
  }

  function clear(node) {
    while (node.firstChild) {
      node.removeChild(node.firstChild);
    }
  }

  // 1. 畫面清單：點擊切換 iframe 的 src 並更新說明面板
  function buildScreenList() {
    clear(el.screenList);

    data.screens.forEach(function (screen, index) {
      var item = document.createElement('li');
      item.className = 'shell-nav-item';
      item.textContent = screen.name || screen.id;
      item.addEventListener('click', function () {
        selectScreen(index);
      });
      el.screenList.appendChild(item);
    });
  }

  function markActiveNavItem() {
    var items = el.screenList.children;

    for (var i = 0; i < items.length; i++) {
      if (i === currentScreenIndex) {
        items[i].classList.add('shell-nav-item-active');
      } else {
        items[i].classList.remove('shell-nav-item-active');
      }
    }
  }

  function selectScreen(index) {
    currentScreenIndex = index;

    var screen = currentScreen();

    if (!screen) {
      return;
    }

    el.frame.setAttribute('src', screen.file);
    markActiveNavItem();
    renderPanel(screen);
    renderAnnotations();
  }

  function renderPanel(screen) {
    el.summary.textContent = screen.summary || '';

    clear(el.layerRows);

    (screen.layers || []).forEach(function (layer) {
      var row = document.createElement('tr');

      [layer.block, layer.level, layer.reason].forEach(function (value) {
        var cell = document.createElement('td');
        cell.textContent = value || '';
        row.appendChild(cell);
      });

      el.layerRows.appendChild(row);
    });
  }

  // 2. 註解模式：關閉時直接移除疊層 DOM 節點，不使用隱藏樣式
  function renderAnnotations() {
    clear(el.overlay);
    clear(el.annotationList);

    var screen = currentScreen();

    if (!screen || !annotationOn) {
      return;
    }

    (screen.annotations || []).forEach(function (note) {
      var bubble = document.createElement('div');
      bubble.className = 'shell-bubble';
      bubble.style.left = note.x + '%';
      bubble.style.top = note.y + '%';
      bubble.textContent = String(note.no);
      bubble.title = note.text || '';
      el.overlay.appendChild(bubble);

      var line = document.createElement('li');
      line.value = note.no;
      line.textContent = note.text || '';
      el.annotationList.appendChild(line);
    });
  }

  function toggleAnnotation() {
    annotationOn = !annotationOn;
    el.annotationToggle.textContent = '註解模式：' + (annotationOn ? '開' : '關');
    el.annotationToggle.setAttribute('aria-pressed', String(annotationOn));
    renderAnnotations();
  }

  // 3. viewport 切換：改變 iframe 容器寬度
  function applyFrameWidth(width) {
    frameWidth = width;
    el.frameWrap.style.width = width + 'px';
  }

  function bindViewportButtons() {
    var buttons = document.querySelectorAll('[data-width]');

    Array.prototype.forEach.call(buttons, function (button) {
      button.addEventListener('click', function () {
        Array.prototype.forEach.call(buttons, function (other) {
          other.classList.remove('shell-btn-active');
        });
        button.classList.add('shell-btn-active');
        applyFrameWidth(parseInt(button.getAttribute('data-width'), 10));
      });
    });
  }

  // 4. 說明面板收合：收合後畫面容器佔滿可用寬度
  function togglePanel() {
    var collapsed = el.panel.classList.toggle('shell-panel-collapsed');
    el.panelToggle.textContent = collapsed ? '展開說明' : '收合說明';
  }

  function init() {
    el.title.textContent = data.title || 'UI Demo';

    buildScreenList();
    bindViewportButtons();
    applyFrameWidth(frameWidth);

    el.annotationToggle.addEventListener('click', toggleAnnotation);
    el.panelToggle.addEventListener('click', togglePanel);

    if (data.screens.length > 0) {
      selectScreen(0);
    } else {
      var empty = document.createElement('p');
      empty.className = 'shell-empty';
      empty.textContent = '尚未於 demo-data.js 登記任何畫面。';
      el.screenList.appendChild(empty);
    }
  }

  document.addEventListener('DOMContentLoaded', init);
})();
