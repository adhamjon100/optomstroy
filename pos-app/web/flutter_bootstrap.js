// Запуск Flutter в браузере «Оптомстрой POS», веб-демо ADR-113 (общий для страницы сборки web/index.html и страницы веб-демо
// demo/web/site-src/index.html). Две строки-шаблона ниже (загрузчик flutter.js и конфигурация сборки) подставляет
// `flutter build web`; в комментариях их писать нельзя — подстановка заменяет каждое вхождение.
//
// Отличия от загрузчика Flutter по умолчанию:
// * без service worker (сборка `--pwa-strategy=none`): после новой выкладки не остаётся устаревший кэш;
// * `fontFallbackBaseUrl: 'fonts/'` — запасной Roboto движок берёт с того же сайта
//   (`fonts/roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2`, кладёт сборка сайта), а не с fonts.gstatic.com;
//   интерфейс рисуется шрифтом Inter из ассетов приложения;
// * экран загрузки `#loading` скрывается по первому кадру Flutter (событие `flutter-first-frame`). Страница может
//   отложить скрытие: если задана `window.__posOnFlutterFirstFrame`, вызывается она (например, веб-демо ждёт ещё
//   и готовности встроенного сервера), а скрытие — её забота (`window.__posHideLoading()`);
// * ошибка запуска движка показывается на экране загрузки, а не оставляет пустую страницу. Ту же функцию
//   приложение вызывает само (`window.__posShowStartError(message)`), если запуск сорвался уже после первого `await`
//   его `main()`: загрузчик Flutter этого Future не ждёт (веб-демо, lib/app/demo/main_web_demo.dart).
{{flutter_js}}
{{flutter_build_config}}

(function () {
  'use strict';

  function loadingElement() {
    return document.getElementById('loading');
  }

  // Скрыть экран загрузки (повторный вызов ничего не делает).
  function hideLoading() {
    var el = loadingElement();
    if (!el || el.classList.contains('is-done')) return;
    el.classList.add('is-done');
    window.setTimeout(function () {
      if (el.parentNode) el.parentNode.removeChild(el);
    }, 250);
  }

  // Текст ошибки запуска на экране загрузки.
  function showStartError(error) {
    console.error('Оптомстрой POS: запуск не удался', error);
    var el = loadingElement();
    if (!el) return;
    var box = el.querySelector('.error');
    if (!box) {
      box = document.createElement('div');
      box.className = 'error';
      el.appendChild(box);
    }
    var spinner = el.querySelector('.spinner');
    if (spinner) spinner.style.display = 'none';
    box.textContent = 'Не удалось запустить приложение. Обновите страницу; если ошибка повторится, ' +
      'откройте её в Chrome или Edge.';
  }

  window.__posHideLoading = hideLoading;
  window.__posShowStartError = showStartError;

  window.addEventListener('flutter-first-frame', function () {
    if (typeof window.__posOnFlutterFirstFrame === 'function') {
      window.__posOnFlutterFirstFrame();
      return;
    }
    hideLoading();
  }, { once: true });

  // Конфигурация движка: передаётся и загрузчику, и initializeEngine — со своим onEntrypointLoaded загрузчик её сам
  // в движок не передаёт (иначе Roboto опять запрашивается с fonts.gstatic.com).
  var engineConfig = {
    fontFallbackBaseUrl: 'fonts/',
  };

  _flutter.loader.load({
    config: engineConfig,
    onEntrypointLoaded: async function (engineInitializer) {
      try {
        var appRunner = await engineInitializer.initializeEngine(engineConfig);
        await appRunner.runApp();
      } catch (error) {
        showStartError(error);
      }
    },
  }).catch(showStartError);
})();
