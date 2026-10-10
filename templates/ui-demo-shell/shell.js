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
    panelToggle: document.getElementById('panelToggle'),
    resetDemo: document.getElementById('resetDemo'),
    substituteList: document.getElementById('substituteList'),
    interactionSummary: document.getElementById('interactionSummary')
  };

  function currentScreen() {
    var screen = data.screens[currentScreenIndex];
    return isSelectableScreen(screen) ? screen : null;
  }

  function hasText(value) {
    return typeof value === 'string' && value.trim().length > 0;
  }

  function isSelectableScreen(screen) {
    return !!screen && typeof screen === 'object' && hasText(screen.name) && hasText(screen.file);
  }

  function screenLabel(screen, index) {
    var label = '第 ' + (index + 1) + ' 筆畫面';

    if (screen && hasText(screen.name)) {
      return label + '「' + screen.name + '」';
    }

    if (screen && screen.id !== undefined && screen.id !== null && String(screen.id).length > 0) {
      return label + '（ID：' + String(screen.id) + '）';
    }

    return label;
  }

  function missingScreenFields(screen) {
    var missing = [];

    if (!screen || !hasText(screen.name)) {
      missing.push('名稱（screen.name）');
    }

    if (!screen || !hasText(screen.file)) {
      missing.push('檔案（screen.file）');
    }

    return missing;
  }

  function clear(node) {
    while (node.firstChild) {
      node.removeChild(node.firstChild);
    }
  }

  // 1. 畫面清單：點擊切換 iframe 的 src 並更新說明面板
  function buildScreenList() {
    clear(el.screenList);

    for (var index = 0; index < data.screens.length; index++) {
      var screen = data.screens[index];
      var item = document.createElement('li');
      item.className = 'shell-nav-item';

      if (!isSelectableScreen(screen)) {
        item.classList.add('shell-nav-item-invalid');
        item.textContent = screenLabel(screen, index) + '：資料缺漏：' + missingScreenFields(screen).join('、') + '。';
        el.screenList.appendChild(item);
        continue;
      }

      var button = document.createElement('button');
      button.type = 'button';
      button.className = 'shell-nav-button';
      button.textContent = screen.name;
      (function (screenIndex) {
        button.addEventListener('click', function () {
          selectScreen(screenIndex);
        });
      }(index));
      item.appendChild(button);
      el.screenList.appendChild(item);
    }
  }

  function markActiveNavItem() {
    var items = el.screenList.children;

    for (var i = 0; i < items.length; i++) {
      var button = items[i].querySelector('button');

      if (!button) {
        items[i].classList.remove('shell-nav-item-active');
        continue;
      }

      if (i === currentScreenIndex) {
        items[i].classList.add('shell-nav-item-active');
        button.setAttribute('aria-current', 'page');
      } else {
        items[i].classList.remove('shell-nav-item-active');
        button.removeAttribute('aria-current');
      }
    }
  }

  function selectScreen(index) {
    if (!isSelectableScreen(data.screens[index])) {
      return;
    }

    currentScreenIndex = index;

    var screen = currentScreen();

    if (!screen) {
      return;
    }

    annotationOn = false;
    applyAnnotationInteractionState();
    el.resetDemo.disabled = false;
    el.frame.setAttribute('src', screen.file);
    markActiveNavItem();
    renderPanel(screen);
  }

  function renderPanel(screen) {
    el.summary.textContent = screen.summary || '';
    renderSubstitutes(screen);
    renderInteractionSummary(screen);

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

  function renderSubstitutes(screen) {
    clear(el.substituteList);
    var substitutes = Array.isArray(screen.substitutes) ? screen.substitutes : [];

    if (substitutes.length === 0) {
      var empty = document.createElement('li');
      empty.textContent = '無替身';
      el.substituteList.appendChild(empty);
      return;
    }

    substitutes.forEach(function (substitute) {
      var item = document.createElement('li');
      var fields = ['component', 'samplePath', 'contractSource', 'differences'];
      item.textContent = fields.map(function (field) {
        var value = substitute && substitute[field];
        return field + '：' + (hasText(value) ? value : '資料缺漏');
      }).join('；');
      el.substituteList.appendChild(item);
    });
  }

  function renderInteractionSummary(screen) {
    clear(el.interactionSummary);
    var interaction = screen.interaction || {};
    var operations = Array.isArray(interaction.allowedOperations) ? interaction.allowedOperations : [];
    var sources = Array.isArray(interaction.patternSources) ? interaction.patternSources : [];
    var pending = Array.isArray(interaction.pendingItems) ? interaction.pendingItems : [];

    function append(text) {
      var line = document.createElement('p');
      line.textContent = text;
      el.interactionSummary.appendChild(line);
    }

    append('允許操作：' + (operations.length ? operations.join('、') : '僅供檢視'));
    append('固定資料：' + JSON.stringify(interaction.fixedData || {}));
    append('模式來源：' + (sources.length ? sources.map(function (source) {
      return (source && hasText(source.operation) ? source.operation : '資料缺漏') + '：' +
        (source && hasText(source.source) ? source.source : '資料缺漏');
    }).join('；') : '無'));
    append('待確認項：' + (pending.length ? pending.join('、') : '無'));
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

  function applyAnnotationInteractionState() {
    el.frame.style.pointerEvents = annotationOn ? 'none' : '';
    if (annotationOn) {
      el.frame.setAttribute('tabindex', '-1');
    } else {
      el.frame.removeAttribute('tabindex');
    }
    el.annotationToggle.textContent = '註解模式：' + (annotationOn ? '開' : '關');
    el.annotationToggle.setAttribute('aria-pressed', String(annotationOn));
    renderAnnotations();
  }

  function toggleAnnotation() {
    annotationOn = !annotationOn;
    applyAnnotationInteractionState();
  }

  function resetCurrentScreen() {
    annotationOn = false;
    applyAnnotationInteractionState();
    var screen = currentScreen();
    el.resetDemo.disabled = !screen;
    if (!screen) {
      return;
    }
    el.frame.setAttribute('src', screen.file);
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
    el.resetDemo.addEventListener('click', resetCurrentScreen);
    el.resetDemo.disabled = !currentScreen();
    applyAnnotationInteractionState();

    var initialScreenIndex = -1;
    for (var i = 0; i < data.screens.length; i++) {
      if (isSelectableScreen(data.screens[i])) {
        initialScreenIndex = i;
        break;
      }
    }

    if (initialScreenIndex >= 0) {
      selectScreen(initialScreenIndex);
    } else if (data.screens.length === 0) {
      var empty = document.createElement('p');
      empty.className = 'shell-empty';
      empty.textContent = '尚未於 demo-data.js 登記任何畫面。';
      el.screenList.appendChild(empty);
    }
  }

  document.addEventListener('DOMContentLoaded', init);
})();
