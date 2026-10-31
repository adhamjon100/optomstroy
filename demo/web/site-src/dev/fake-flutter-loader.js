// Оптомстрой POS · веб-демо · ИМИТАЦИЯ загрузчика Flutter для dev-сервера WP-S1 (не публикуется).
// Подставляется вместо {{flutter_js}} в настоящий pos-app/web/flutter_bootstrap.js: тот вызывает
// _flutter.loader.load({onEntrypointLoaded}) → initializeEngine() → runApp(), ждёт событие flutter-first-frame.
// Имитация повторяет то, что важно странице: KeyboardBinding Flutter слушает keydown/keyup на window в фазе захвата
// (регистрируется при инициализации движка — позже скриптов страницы), connectivity_plus слушает online/offline на
// window, есть шапка (68 lp; compact — 56), нижняя навигация compact (80 lp) и FAB экрана.
var _flutter = (window._flutter = window._flutter || {});
(function () {
  'use strict';
  var stub = (window.__stub = { keys: [], net: [], firstFrameAt: null, initAt: null });

  function css() {
    var s = document.createElement('style');
    s.textContent = [
      '#stub-app{position:fixed;inset:0;z-index:0;background:#F1F6FC;font:14px/20px Inter,"Segoe UI",Arial,sans-serif;color:#0E1456;overflow:hidden}',
      '.stub-header{position:absolute;left:0;right:0;top:0;height:68px;display:flex;align-items:center;gap:12px;padding:0 16px;background:#fff;border-bottom:1px solid #E3E9F2;box-sizing:border-box}',
      '.stub-header button{height:40px;min-width:40px;border:1px solid #E3E9F2;border-radius:12px;background:#fff;cursor:pointer}',
      '.stub-title{font-weight:600;white-space:nowrap}',
      '#stub-input{flex:1;min-width:80px;height:40px;border:1px solid #7D879A;border-radius:12px;padding:0 12px}',
      '.stub-main{position:absolute;left:0;right:0;top:68px;bottom:0;padding:16px;display:grid;grid-template-columns:repeat(auto-fill,minmax(176px,1fr));gap:12px;overflow:auto;box-sizing:border-box}',
      '.stub-card{height:120px;border-radius:16px;background:#fff;border:1px solid #E3E9F2;padding:12px;box-sizing:border-box}',
      '#stub-fab{position:absolute;right:16px;bottom:16px;width:56px;height:56px;border-radius:16px;border:0;background:#D9380F;color:#fff;font-size:24px}',
      '.stub-bottom{display:none;position:absolute;left:0;right:0;bottom:0;height:80px;background:#fff;border-top:1px solid #E3E9F2}',
      '.stub-bottom button{flex:1;border:0;background:transparent;font-size:12px}',
      '@media (max-width:599.98px){.stub-header{height:56px}.stub-main{top:56px;bottom:80px}.stub-bottom{display:flex}#stub-fab{bottom:96px}.stub-title{display:none}}',
    ].join('\n');
    document.head.appendChild(s);
  }

  function app() {
    var root = document.createElement('div');
    root.id = 'stub-app';
    root.setAttribute('data-stub', 'flutter-view');
    var cards = '';
    for (var i = 1; i <= 12; i++) cards += '<div class="stub-card">Товар ' + i + ' (имитация)</div>';
    root.innerHTML =
      '<header class="stub-header" data-nav="header">' +
      '<button type="button" data-nav="burger" aria-label="Меню">☰</button>' +
      '<span class="stub-title">Каталог — имитация Flutter</span>' +
      '<input id="stub-input" placeholder="Поиск товаров" aria-label="Поиск товаров">' +
      '<button type="button" data-nav="cart">Корзина</button>' +
      '<button type="button" data-nav="avatar">ТК</button>' +
      '</header>' +
      '<main class="stub-main">' + cards + '</main>' +
      '<button type="button" id="stub-fab" data-stub="fab" aria-label="Действие экрана">+</button>' +
      '<nav class="stub-bottom" data-nav="bottom">' +
      ['Каталог', 'Поиск', 'Корзина', 'Заказы', 'Ещё'].map(function (t, i) { return '<button type="button" data-nav="tab-' + i + '">' + t + '</button>'; }).join('') +
      '</nav>';
    document.body.appendChild(root);
  }

  function config() {
    return fetch('/__dev/mock-config', { cache: 'no-store' }).then(function (r) { return r.json(); }, function () { return {}; });
  }

  _flutter.loader = {
    load: function (opts) {
      return config().then(function (cfg) {
        return new Promise(function (r) { setTimeout(r, Number(cfg.flutterDelayMs || 600)); }).then(function () {
          if (cfg.flutterFail) throw new Error('Имитация: движок Flutter не запустился');
          return opts.onEntrypointLoaded({
            initializeEngine: function () {
              stub.initAt = Date.now();
              ['keydown', 'keyup'].forEach(function (t) {
                window.addEventListener(t, function (e) {
                  stub.keys.push({ type: e.type, key: e.key, target: e.target && (e.target.id || e.target.tagName) });
                }, true);
              });
              window.addEventListener('online', function () { stub.net.push('online'); });
              window.addEventListener('offline', function () { stub.net.push('offline'); });
              return Promise.resolve({
                runApp: function () {
                  css();
                  app();
                  requestAnimationFrame(function () {
                    requestAnimationFrame(function () {
                      stub.firstFrameAt = Date.now();
                      window.dispatchEvent(new Event('flutter-first-frame'));
                    });
                  });
                  return Promise.resolve();
                },
              });
            },
          });
        });
      });
    },
  };
})();
