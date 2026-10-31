/*
 * Оптомстрой POS · веб-демо · порядок загрузки страницы и экран загрузки (WP-S1; plan §3.1; ADR-113 п. 8–9).
 *
 *  1. Проверка среды (demo-env.js) → при замечаниях — «Откройте на компьютере в Chrome или Edge» и «Всё равно продолжить».
 *  2. Замок одной вкладки (demo-lock.js) → занят: «Демо уже открыто в другой вкладке» и «Продолжить здесь».
 *  3. Отложенный сброс (флаг или ?reset=1) → очистка хранилища origin ДО запуска воркера и Flutter (demo-reset.js).
 *  4. demo/build.json → ключ эпохи; сменился — предупреждение «Демо обновлено» → очистка. Файла нет (404) или он
 *     испорчен — «Сайт демо собран неполностью» (демо не запускается); сбой сети/5xx — только с сохранённым ключом.
 *     Хранилище, на котором эпоха уже запускалась, запоминается (optomstroy.demo.storageKind) и выбирается снова.
 *  5. navigator.storage.persist() — один раз; новое поколение тома (fencing).
 *  6. Воркер backend/backend.js (demo-bridge.js, init) и параллельно flutter_bootstrap.js.
 *  7. Экран загрузки скрывается, когда есть и первый кадр Flutter (window.__posOnFlutterFirstFrame), и `ready`
 *     воркера; затем появляется кнопка «ДЕМО». `fatal` воркера — текст ошибки и «Сбросить демо» (fatal fenced —
 *     уход, как при потере замка; pglite_aborted после запуска — «Обновите страницу»). Сообщение воркера `storage
 *     {ok:false}` — постоянная плашка «Данные демо не сохраняются…» со ссылкой на раздел «Сервис».
 * Потеря замка → мост останавливается (fenceExit) → location.replace('demo-closed.html'): Flutter дальше не работает.
 *
 * Параметры адреса (снимаются из адреса до запуска Flutter): reset=1, takeover=1, storage=opfs|idb|memory,
 * envcheck=0 (пропустить проверку среды — для smoke). Только на 127.0.0.1/localhost: initExtra=<json> — доп. поля init.
 */
(function (global) {
  'use strict';

  var P = global.PosDemoPage = global.PosDemoPage || {};
  var doc = global.document;
  var B = global.__posDemo;
  var K = P.KEYS;

  var STAGES = {
    loaded: 'Сервер демо загружен',
    pglite: 'Запускаем базу данных PostgreSQL…',
    storage: 'Открываем хранилище браузера…',
    migrate: 'Готовим базу данных…',
    snapshot: 'Загружаем данные демо…',
    seed: 'Готовим данные демо…',
    staff: 'Готовим сотрудников…',
    catalog: 'Загружаем каталог…',
    fake1c: 'Запускаем имитатор «1С»…',
    onec: 'Запускаем имитатор «1С»…',
    nest: 'Запускаем сервер…',
    worker: 'Запускаем фоновые задачи…',
    sync: 'Синхронизируем данные…',
    ready: 'Сервер демо готов',
  };

  var boot = {
    startedAt: Date.now(),
    steps: [],
    env: null,
    lockResult: null,
    lastWipe: null,
    build: null,
    storage: null,
    firstFrame: false,
    hidden: false,
    error: null,
  };
  function step(name, data) {
    boot.steps.push({ t: Date.now() - boot.startedAt, step: name, data: data || null });
  }

  // ---------------------------------------------------------------- экран
  var E = {};
  function q(id) { return doc.getElementById(id); }
  function bindScreen() {
    E.screen = q('loading');
    E.stage = q('pd-stage');
    E.bar = q('pd-bar');
    E.progress = q('pd-progress');
    E.body = q('pd-body');
    E.actions = q('pd-actions');
    E.title = q('pd-title');
    E.spinner = E.screen ? E.screen.querySelector('.spinner') : null;
    E.steps = q('pd-steps');
  }

  function h(tag, cls, text) {
    var n = doc.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined && text !== null) n.textContent = text;
    return n;
  }

  function clearNode(n) {
    if (!n) return;
    while (n.firstChild) n.removeChild(n.firstChild);
  }

  function view(name) {
    if (E.screen) E.screen.dataset.view = name;
  }

  function stage(text, pct) {
    if (E.stage && text) E.stage.textContent = text;
    if (E.bar && typeof pct === 'number') {
      var v = Math.max(0, Math.min(100, Math.round(pct)));
      E.bar.style.width = v + '%';
      if (E.progress) E.progress.setAttribute('aria-valuenow', String(v));
    }
  }

  function setTitle(text) {
    if (E.title) E.title.textContent = text;
  }

  // notice({title, text: [..], list: [..], pre, buttons: [{id, label, kind, onClick}]}) → в карточке экрана загрузки
  function notice(opts) {
    clearNode(E.body);
    clearNode(E.actions);
    if (opts.title) setTitle(opts.title);
    (opts.text || []).forEach(function (t) { E.body.appendChild(h('p', 'pd-p', t)); });
    if (opts.list && opts.list.length) {
      var ul = h('ul', 'pd-issues');
      opts.list.forEach(function (t) { ul.appendChild(h('li', null, t)); });
      E.body.appendChild(ul);
    }
    if (opts.pre) E.body.appendChild(h('pre', 'pd-pre', opts.pre));
    var first = null;
    (opts.buttons || []).forEach(function (b) {
      var btn = h('button', 'pd-btn ' + (b.kind === 'primary' ? 'pd-btn-primary' : b.kind === 'danger' ? 'pd-btn-danger' : ''), b.label);
      btn.type = 'button';
      if (b.id) btn.id = b.id;
      btn.addEventListener('click', function () {
        btn.disabled = true;
        b.onClick(btn);
      });
      E.actions.appendChild(btn);
      if (!first) first = btn;
    });
    if (first && opts.focus !== false) {
      try {
        first.focus();
      } catch (e) { /* ignore */ }
    }
  }

  function clearNotice() {
    clearNode(E.body);
    clearNode(E.actions);
    setTitle('Оптомстрой POS · демо');
  }

  function hideScreen() {
    if (boot.hidden) return;
    boot.hidden = true;
    step('hidden');
    if (typeof global.__posHideLoading === 'function') {
      global.__posHideLoading();
    } else if (E.screen) {
      E.screen.classList.add('is-done');
      var el = E.screen;
      setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, 250);
    }
  }

  // Ошибка, когда приложение уже показано: отдельный слой поверх Flutter (экран загрузки уже удалён).
  function overlay(opts) {
    var old = q('pd-overlay');
    if (old && old.parentNode) old.parentNode.removeChild(old);
    var wrap = h('div', 'pd-screen pd-overlay');
    wrap.id = 'pd-overlay';
    wrap.setAttribute('role', 'alertdialog');
    wrap.setAttribute('aria-modal', 'true');
    var card = h('div', 'pd-card');
    var title = h('h1', 'pd-title', opts.title);
    title.id = 'pd-overlay-title';
    wrap.setAttribute('aria-labelledby', 'pd-overlay-title');
    card.appendChild(title);
    (opts.text || []).forEach(function (t) { card.appendChild(h('p', 'pd-p', t)); });
    if (opts.pre) card.appendChild(h('pre', 'pd-pre', opts.pre));
    var actions = h('div', 'pd-actions');
    (opts.buttons || []).forEach(function (b) {
      var btn = h('button', 'pd-btn ' + (b.kind === 'primary' ? 'pd-btn-primary' : b.kind === 'danger' ? 'pd-btn-danger' : ''), b.label);
      btn.type = 'button';
      if (b.id) btn.id = b.id;
      btn.addEventListener('click', function () {
        btn.disabled = true;
        b.onClick(btn);
      });
      actions.appendChild(btn);
    });
    card.appendChild(actions);
    wrap.appendChild(card);
    // Клавиши и указатель из слоя — не приложению.
    ['keydown', 'keyup', 'pointerdown', 'pointerup', 'pointermove', 'wheel'].forEach(function (t) {
      wrap.addEventListener(t, function (ev) { ev.stopPropagation(); });
    });
    doc.body.appendChild(wrap);
    var btn0 = actions.querySelector('button');
    if (btn0) btn0.focus();
    return wrap;
  }

  // ---------------------------------------------------------------- действия
  function reload() {
    global.location.replace(global.location.pathname);
  }

  // «Сбросить демо»: флаг → остановить воркер (закрыть PGlite, отпустить OPFS) → перезагрузка; очистка — при загрузке.
  function resetDemo(reason) {
    step('reset-request', { reason: reason });
    P.reset.request(reason || 'panel');
    if (P.panel && P.panel.mounted) {
      try {
        P.panel.close(false);
      } catch (e) { /* ignore */ }
    }
    if (boot.hidden) {
      overlay({ title: 'Сброс демо…', text: ['Останавливаем демо и удаляем данные в этом браузере.'] });
    } else {
      view('loading');
      clearNotice();
      stage('Сброс демо…', 5);
    }
    var done = false;
    var go = function () {
      if (done) return;
      done = true;
      // Флаг уже стоит; ?reset=1 — на случай недоступного localStorage.
      global.location.replace(global.location.pathname + (P.store.available ? '' : '?reset=1'));
    };
    B._shutdown({ timeoutMs: 2000 }).then(go, go);
    setTimeout(go, 3000);
  }

  function showFatal(f) {
    step('fatal', f);
    boot.error = f;
    var msg = String((f && f.message) || 'неизвестная ошибка');
    var buttons = [
      { id: 'pd-fatal-reset', label: 'Сбросить демо', kind: 'primary', onClick: function () { resetDemo('fatal'); } },
      { id: 'pd-fatal-reload', label: 'Обновить страницу', onClick: function () { reload(); } },
    ];
    var text = ['Встроенный сервер демо остановился с ошибкой. Обновите страницу; если ошибка повторится — сбросьте демо: данные демо в этом браузере будут удалены.'];
    var reloadFirst = function () {
      buttons = [buttons[1], buttons[0]];
      buttons[0].kind = 'primary';
      buttons[1].kind = '';
    };
    // OPFS: том держит другая (замороженная) вкладка — её sync access handle не отпущены (WP-B3: fatal code storage_busy).
    if (f && f.code === 'storage_busy') {
      text = ['Данные демо заняты другой вкладкой этого браузера, которая не отвечает. Закройте другие вкладки с демо и обновите страницу. Сбрасывать демо не нужно.'];
      reloadFirst();
    }
    // review fixes: PGlite погиб уже после запуска — данные до последней записи на диск сохранены, сброс не нужен.
    if (f && f.code === 'pglite_aborted') {
      text = ['Сервер демо остановился. Обновите страницу: сохранённые данные демо останутся. Если ошибка повторяется — сбросьте демо.'];
      reloadFirst();
    }
    // review fixes: сайт собран без demo/build.json (или он испорчен) / нет сети при первом визите — сброс не поможет.
    if (f && (f.code === 'config' || f.code === 'network')) {
      text = f.code === 'config'
        ? ['Сайт демо собран неполностью: нет файла версии demo/build.json или он испорчен. Сообщите об этом тому, кто прислал ссылку. Данные демо в этом браузере не тронуты.']
        : ['Не удалось загрузить версию демо: проверьте подключение к интернету и обновите страницу.'];
      buttons = [{ id: 'pd-fatal-reload', label: 'Обновить страницу', kind: 'primary', onClick: function () { reload(); } }];
    }
    if (!boot.hidden) {
      view('fatal');
      stage('Ошибка запуска сервера демо', 100);
      notice({ title: 'Сервер демо не запустился', text: text, pre: msg.slice(0, 1500), buttons: buttons });
    } else {
      overlay({ title: 'Сервер демо остановился', text: text, pre: msg.slice(0, 1500), buttons: buttons });
    }
  }

  // Потеря замка (другая вкладка, steal, смена поколения) или сигнал воркера `fenced`.
  var leaving = false;
  function onLockLost(info) {
    if (leaving) return;
    leaving = true;
    step('lock-lost', info);
    // `release` пришёл, когда поколение уже сменилось (вкладка была заморожена и замок отобрали) — это steal.
    var reason = info.reason === 'released' ? (P.lock.isGenerationCurrent() ? 'moved' : 'stolen') : info.reason;
    try {
      if (boot.hidden) overlay({ title: 'Демо переносится в другую вкладку…', text: ['Эта вкладка закрывает демо.'] });
      else {
        view('loading');
        clearNotice();
        stage('Демо переносится в другую вкладку…', 100);
      }
    } catch (e) { /* ignore */ }
    var go = function () {
      P.lock.finishRelease(info.from);
      global.location.replace('demo-closed.html?reason=' + encodeURIComponent(reason));
    };
    var timer = setTimeout(go, 4500);
    B._fenceExit({ flush: info.reason === 'released' }).then(function (r) {
      step('fence-exit', r);
      clearTimeout(timer);
      go();
    }, function () {
      clearTimeout(timer);
      go();
    });
  }

  // ---------------------------------------------------------------- шаги загрузки
  function envGate(env, params) {
    if (!env.issues.length || params.get('envcheck') === '0') return Promise.resolve('skip');
    var sig = env.issues.map(function (i) { return i.code; }).sort().join(',');
    if (P.store.get(K.envAck) === sig) return Promise.resolve('acked');
    return new Promise(function (resolve) {
      view('env');
      stage('Проверка браузера', 4);
      notice({
        title: 'Откройте на компьютере в Chrome или Edge',
        text: ['Демо «Оптомстрой POS» рассчитано на компьютер с Chrome или Edge. В этом браузере оно может работать с ошибками:'],
        list: env.issues.map(function (i) { return i.text; }),
        buttons: [{ id: 'pd-env-continue', label: 'Всё равно продолжить', kind: 'primary', onClick: function () {
          P.store.set(K.envAck, sig);
          resolve('continue');
        } }],
      });
    });
  }

  function lockBusy() {
    return new Promise(function (resolve) {
      view('lock');
      stage('Демо уже открыто', 6);
      notice({
        title: 'Демо уже открыто в другой вкладке',
        text: [
          'Демо работает только в одной вкладке, чтобы данные не перепутались.',
          'Перейдите в ту вкладку или продолжите здесь — та вкладка закроет демо, сделанное в ней сохранится.',
        ],
        buttons: [{ id: 'pd-lock-takeover', label: 'Продолжить здесь', kind: 'primary', onClick: function () { resolve('takeover'); } }],
      });
    });
  }

  function epochGate() {
    return new Promise(function (resolve) {
      view('epoch');
      stage('Демо обновлено', 8);
      notice({
        title: 'Демо обновлено',
        text: [
          'Изменилось устройство данных демо, поэтому оно начнётся заново.',
          'Заказы, корзины, вход и настройки демо в этом браузере будут удалены.',
        ],
        buttons: [{ id: 'pd-epoch-continue', label: 'Начать заново', kind: 'primary', onClick: function () { resolve(); } }],
      });
    });
  }

  function wipe(reason) {
    step('wipe-start', { reason: reason });
    view('reset');
    clearNotice();
    stage(reason === 'epoch' ? 'Начинаем демо заново…' : 'Сброс демо…', 10);
    return P.reset.wipeAll({ onStatus: function (t) { stage(t); } }).then(function (report) {
      boot.lastWipe = report;
      step('wipe-done', { ok: report.ok, ms: report.ms, leftovers: report.leftovers });
      if (report.ok) {
        P.reset.clearFlag();
        return report;
      }
      view('reset-failed');
      notice({
        title: 'Не удалось полностью очистить данные демо',
        text: ['Данные демо заняты другой вкладкой или процессом браузера. Закройте другие вкладки с демо и нажмите «Повторить».'],
        pre: report.leftovers.join('\n'),
        buttons: [{ id: 'pd-wipe-retry', label: 'Повторить', kind: 'primary', onClick: function () { reload(); } }],
      });
      return new Promise(function () { /* стоп: остаёмся на экране */ });
    });
  }

  // demo/build.json → {buildId, epochKey, …}.
  // Review fixes: ответ сервера без файла (404 и любой не-2xx), не-JSON или без epochKey — ошибка конфигурации сайта
  // ({configError}): демо НЕ запускается на базе «optomstroy-demo-unknown» (раньше так и было, а когда файл появлялся,
  // проверка «первый визит + есть данные» стирала данные заказчика без предупреждения «Демо обновлено»).
  // Сбой сети (fetch отклонён) — только с уже сохранённым ключом эпохи: эпоху не проверяем и данные не стираем
  // ({failed: true}); без сохранённого ключа — {networkError}.
  function loadBuild() {
    var storedKey = P.store.get(K.epochKey);
    var configError = function (why) {
      if (global.console) global.console.warn('Оптомстрой демо: demo/build.json — ' + why);
      return { configError: true, message: 'demo/build.json: ' + why };
    };
    var transient = function (why) {
      if (global.console) global.console.warn('Оптомстрой демо: demo/build.json не прочитан (' + why + ')');
      if (storedKey) return { buildId: P.store.get(K.buildId) || storedKey, epochKey: storedKey, failed: true };
      return { networkError: true, message: 'demo/build.json: ' + why };
    };
    return global.fetch('demo/build.json', { cache: 'no-store', credentials: 'same-origin' }).then(function (r) {
      // 5xx — временный сбой хостинга (как сеть); 404 и прочие 4xx — файла на сайте нет: ошибка сборки сайта.
      if (r.status >= 500) return transient('HTTP ' + r.status);
      if (!r.ok) return configError('HTTP ' + r.status);
      return r.json().then(function (j) {
        var b = j && typeof j === 'object' ? j : null;
        if (!b) return configError('не объект JSON');
        if (!b.epochKey || !/^[0-9A-Za-z-]{6,64}$/.test(String(b.epochKey))) return configError('нет ключа эпохи epochKey');
        if (!b.buildId) b.buildId = String(b.epochKey);
        return b;
      }, function () {
        return configError('не JSON');
      });
    }, function (e) {
      return transient('сеть: ' + String((e && e.message) || e));
    });
  }

  // ---------------------------------------------------------------- где лежат данные эпохи (review fixes)
  function readStorageKind(epochKey) {
    try {
      var o = JSON.parse(P.store.get(K.storageKind) || 'null');
      return o && o.epochKey === epochKey && /^(opfs|idb)$/.test(o.storage) ? o : null;
    } catch (e) {
      return null;
    }
  }
  // После ready на сохраняемом хранилище: запомнить его (следующий визит откроет то же, а не выберет заново).
  function rememberStorageKind(info) {
    if (!info || !/^(opfs|idb)$/.test(info.storage) || !boot.build || !boot.build.epochKey) return;
    var prev = readStorageKind(boot.build.epochKey);
    var count = prev && prev.storage === info.storage ? (prev.readyCount || 0) + 1 : 1;
    P.store.set(K.storageKind, JSON.stringify({ epochKey: boot.build.epochKey, storage: info.storage, readyCount: count, lastReadyAt: Date.now() }));
  }
  // Сравнить фактический запуск с ожидаемым: данные этой эпохи уже были, а воркер начал с пустого тома
  // (браузер удалил данные сайта, оставив localStorage) или хранилище с данными не открылось (запуск в памяти).
  function storageSurprise(info) {
    var r = boot.rememberedStorage;
    // Только когда запускались на запомненном хранилище (не ?storage= разработчика и не первый визит эпохи).
    if (!r || !info || !boot.storage || boot.storage.source !== 'remembered') return null;
    if (info.storage !== r.storage) {
      return 'Сохранённые данные демо в этом браузере сейчас недоступны — эта вкладка работает без сохранения. Закройте другие вкладки с демо и обновите страницу.';
    }
    if (info.warm === false && (r.readyCount || 0) >= 1) {
      return 'Браузер удалил сохранённые данные демо — демо начато заново.';
    }
    return null;
  }

  function requestPersistOnce() {
    var st = global.navigator.storage;
    if (!st || typeof st.persist !== 'function') return Promise.resolve(null);
    var persisted = typeof st.persisted === 'function' ? st.persisted().catch(function () { return false; }) : Promise.resolve(false);
    return persisted.then(function (p) {
      if (p) {
        P.store.set(K.persist, 'granted');
        return true;
      }
      if (P.store.get(K.persist)) return false; // уже спрашивали
      P.store.set(K.persist, 'asked');
      // Не ждём: Firefox показывает вопрос пользователю, а загрузка не должна от него зависеть.
      st.persist().then(function (r) {
        P.store.set(K.persist, r ? 'granted' : 'denied');
      }, function () {
        P.store.set(K.persist, 'denied');
      });
      return false;
    });
  }

  function slug(s) {
    var v = String(s || 'unknown').toLowerCase().replace(/[^a-z0-9-]/g, '').slice(0, 16);
    return v || 'unknown';
  }

  function stripParams(params) {
    var drop = ['reset', 'takeover', 'envcheck', 'storage', 'initExtra'];
    var changed = false;
    drop.forEach(function (k) {
      if (params.has(k)) {
        params.delete(k);
        changed = true;
      }
    });
    if (!changed) return;
    var qs = params.toString();
    try {
      global.history.replaceState(global.history.state, '', global.location.pathname + (qs ? '?' + qs : '') + global.location.hash);
    } catch (e) { /* ignore */ }
  }

  function isLocalDev() {
    return /^(127\.0\.0\.1|localhost|\[::1\])$/.test(global.location.hostname);
  }

  function loadFlutter() {
    step('flutter-load');
    // pdf.js предпросмотра PDF (пакет printing) — с этого сайта, а не с unpkg.com: пакет загрузит pdfjs/pdf.min.js
    // (загрузчик pdf.js 5, tools/pdfjs-files.mjs) при первом предпросмотре; CSP сайта чужих хостов не разрешает.
    global.dartPdfJsBaseUrl = 'pdfjs/';
    var s = doc.createElement('script');
    s.src = 'flutter_bootstrap.js';
    s.async = true;
    s.onerror = function () {
      showFlutterError('Не удалось загрузить приложение (flutter_bootstrap.js). Проверьте интернет и обновите страницу.');
    };
    doc.body.appendChild(s);
  }

  function showFlutterError(text) {
    step('flutter-error', { text: text });
    if (boot.hidden) return;
    view('fatal');
    notice({
      title: 'Приложение не запустилось',
      text: [text],
      buttons: [
        { id: 'pd-app-reload', label: 'Обновить страницу', kind: 'primary', onClick: function () { reload(); } },
        { id: 'pd-app-reset', label: 'Сбросить демо', onClick: function () { resetDemo('app-error'); } },
      ],
    });
  }

  // flutter_bootstrap.js при ошибке запуска движка пишет текст в #loading .error — добавляем кнопки.
  function watchBootstrapErrors() {
    if (!E.screen || typeof global.MutationObserver !== 'function') return;
    var mo = new global.MutationObserver(function () {
      var err = E.screen.querySelector('.error');
      if (err && err.textContent && !boot.hidden && !q('pd-app-reload')) {
        view('fatal');
        clearNode(E.actions);
        notice({
          title: 'Приложение не запустилось',
          text: [],
          buttons: [
            { id: 'pd-app-reload', label: 'Обновить страницу', kind: 'primary', onClick: function () { reload(); } },
            { id: 'pd-app-reset', label: 'Сбросить демо', onClick: function () { resetDemo('app-error'); } },
          ],
        });
      }
    });
    mo.observe(E.screen, { childList: true, subtree: true, characterData: true });
  }

  function markStep(id, state) {
    if (!E.steps) return;
    var li = E.steps.querySelector('[data-step="' + id + '"]');
    if (li) li.dataset.state = state;
  }

  function maybeHide() {
    if (boot.hidden || !boot.firstFrame || !B.isReady || B.phase === 'fatal') return;
    stage('Готово', 100);
    hideScreen();
    if (P.panel) P.panel.mount();
    var surprise = storageSurprise(B.info);
    boot.storageSurprise = surprise;
    if (surprise) toast(surprise, 15000);
    else if (B.info && B.info.storage === 'memory') toast('Данные демо не сохранятся после перезагрузки: браузер не дал сохранить их.');
    if (B.storageHealth && !B.storageHealth.ok) showStorageBanner(B.storageHealth);
  }

  function toast(text, ms) {
    var t = h('div', 'pd-toast', text);
    t.setAttribute('role', 'status');
    doc.body.appendChild(t);
    setTimeout(function () { if (t.parentNode) t.parentNode.removeChild(t); }, ms || 10000);
  }

  // ---------------------------------------------------------------- плашка «данные не сохраняются» (review fixes)
  // Воркер сообщает `storage {ok:false}` после сбоя изменяющего сброса тома (или двух фоновых подряд): квота, нет
  // места на диске, отказ IndexedDB/OPFS. Пока плашка висит, изменения живут только в памяти вкладки.
  function showStorageBanner(hl) {
    boot.storageBanner = { shownAt: Date.now(), error: hl && hl.error };
    step('storage-banner', { error: hl && hl.error, failures: hl && hl.failures });
    var old = q('pd-storage-banner');
    if (old) {
      old.hidden = false;
      return;
    }
    var bar = h('div', 'pd-storage-banner');
    bar.id = 'pd-storage-banner';
    bar.setAttribute('role', 'alert');
    bar.setAttribute('lang', 'ru');
    var txt = h('div', 'pd-storage-text');
    txt.appendChild(h('strong', null, 'Данные демо не сохраняются. '));
    txt.appendChild(h('span', null, 'Браузер не даёт записать их на диск (возможно, мало места). Сделанное после этого пропадёт при перезагрузке страницы.'));
    bar.appendChild(txt);
    var acts = h('div', 'pd-storage-actions');
    var open = h('button', 'pd-btn pd-btn-small', 'Открыть «Сервис»');
    open.type = 'button';
    open.id = 'pd-storage-open';
    open.addEventListener('click', function () {
      if (P.panel && P.panel.openSection) P.panel.openSection('service');
    });
    var hide = h('button', 'pd-btn pd-btn-small', 'Скрыть');
    hide.type = 'button';
    hide.id = 'pd-storage-hide';
    hide.addEventListener('click', function () { bar.hidden = true; });
    acts.appendChild(open);
    acts.appendChild(hide);
    bar.appendChild(acts);
    ['keydown', 'keyup', 'pointerdown', 'pointerup', 'pointermove', 'wheel'].forEach(function (t) {
      bar.addEventListener(t, function (ev) { ev.stopPropagation(); });
    });
    doc.body.appendChild(bar);
  }
  function hideStorageBanner() {
    var b = q('pd-storage-banner');
    if (b && b.parentNode) b.parentNode.removeChild(b);
    if (boot.storageBanner) boot.storageBanner.hiddenAt = Date.now();
    step('storage-ok');
  }

  function wireBridge() {
    B.on('progress', function (p) {
      var label = p.label || STAGES[p.stage] || 'Запускаем сервер демо…';
      var pct = typeof p.pct === 'number' ? 12 + p.pct * 0.8 : null;
      if (!boot.hidden && B.phase === 'starting') stage(label, pct);
      markStep('server', 'active');
    });
    B.on('ready', function (info) {
      step('ready', { storage: info.storage, startMs: info.startMs, warm: info.warm });
      markStep('server', 'done');
      if (!boot.firstFrame) stage('Сервер демо готов, загружаем приложение…', 94);
      rememberStorageKind(info);
      maybeHide();
    });
    B.on('fatal', function (f) {
      // review fixes: fence не совпал ещё до открытия тома — эта вкладка проиграла другой; «Сбросить демо» здесь стёр
      // бы данные, с которыми работает та вкладка. Уходим, как при потере замка.
      if (f && f.code === 'fenced') {
        onLockLost({ reason: 'generation', from: null, worker: f });
        return;
      }
      markStep('server', 'error');
      showFatal(f);
    });
    B.on('storage', function (hl) {
      if (hl && hl.ok === false) {
        if (boot.hidden) showStorageBanner(hl);
      } else hideStorageBanner();
    });
    B.on('fenced', function (m) {
      onLockLost({ reason: 'generation', from: null, worker: m });
    });
    B.on('slow', function () {
      if (boot.hidden || B.phase !== 'starting') return;
      clearNode(E.actions);
      E.body.appendChild(h('p', 'pd-p', 'Запуск занимает больше обычного. Можно подождать или сбросить демо.'));
      var btn = h('button', 'pd-btn', 'Сбросить демо');
      btn.type = 'button';
      btn.id = 'pd-slow-reset';
      btn.addEventListener('click', function () { resetDemo('slow'); });
      E.actions.appendChild(btn);
    });
  }

  function wireLifecycle() {
    var flush = function (reason) {
      if (!leaving) B._flush(reason);
    };
    global.addEventListener('pagehide', function () { flush('pagehide'); });
    doc.addEventListener('visibilitychange', function () {
      if (doc.visibilityState === 'hidden') flush('hidden');
    });
    // Review fixes (smoke «замороженная вкладка»): сброс по событию `freeze` убран. Он запускал в воркере чтение fence
    // из IndexedDB ровно в момент заморозки, и замороженная транзакция держала хранилище fence: «Продолжить здесь» в
    // другой вкладке ждало записи нового поколения ~56 с. Перед заморозкой вкладка всегда сначала скрыта — сброс по
    // `visibilitychange: hidden` уже сделан.
  }

  function main() {
    bindScreen();
    watchBootstrapErrors();
    wireBridge();
    var params;
    try {
      params = new URL(global.location.href).searchParams;
    } catch (e) {
      params = new URLSearchParams('');
    }
    // storage= и initExtra= на 127.0.0.1/localhost переживают перезагрузку (сброс) через sessionStorage — для dev-прогонов.
    var devParam = function (name) {
      var v = params.get(name);
      if (!isLocalDev()) return v;
      if (v !== null) P.session.set('optomstroy.demo.dev.' + name, v);
      else v = P.session.get('optomstroy.demo.dev.' + name);
      return v;
    };
    var storageOverride = devParam('storage');
    var initExtraRaw = isLocalDev() ? devParam('initExtra') : null;
    var initExtra = null;
    if (initExtraRaw) {
      try {
        initExtra = JSON.parse(initExtraRaw);
      } catch (e) {
        initExtra = null;
      }
    }
    var keepDevParams = function () {
      if (!isLocalDev()) return;
      if (storageOverride) P.session.set('optomstroy.demo.dev.storage', storageOverride);
      if (initExtraRaw) P.session.set('optomstroy.demo.dev.initExtra', initExtraRaw);
    };
    var takeover = params.get('takeover') === '1';
    stage('Проверка браузера…', 2);
    markStep('check', 'active');

    return P.env.check().then(function (env) {
      boot.env = { kind: env.kind, issues: env.issues.map(function (i) { return i.code; }), caps: env.caps };
      step('env', boot.env);
      return envGate(env, params);
    }).then(function () {
      markStep('check', 'done');
      view('loading');
      clearNotice();
      stage('Проверяем другие вкладки…', 5);
      P.lock.onLost(onLockLost);
      return P.lock.acquire({
        takeover: takeover,
        onBusy: lockBusy,
        onStatus: function (t) {
          view('loading');
          clearNotice();
          stage(t, 6);
        },
      });
    }).then(function (lr) {
      boot.lockResult = lr;
      step('lock', lr);
      view('loading');
      clearNotice();
      if (P.reset.isPending()) return wipe('reset');
      return null;
    }).then(function () {
      stripParams(params);
      stage('Проверяем версию демо…', 9);
      return loadBuild();
    }).then(function (build) {
      if (build.configError || build.networkError) {
        step('build-error', build);
        markStep('check', 'error');
        showFatal({ code: build.configError ? 'config' : 'network', message: build.message });
        return new Promise(function () { /* стоп: без версии демо не запускается */ });
      }
      boot.build = build;
      B.build = build;
      var ep = build.failed ? 'unknown' : P.reset.checkEpoch(build);
      step('epoch', { state: ep, epochKey: build.epochKey });
      if (ep === 'changed') return epochGate().then(function () { return wipe('epoch'); });
      if (ep === 'first') {
        return P.reset.hasData().then(function (has) {
          if (has) return wipe('foreign');
          return null;
        });
      }
      return null;
    }).then(function () {
      keepDevParams();
      if (!boot.build.failed) P.reset.rememberEpoch(boot.build);
      view('loading');
      clearNotice();
      stage('Готовим хранилище…', 11);
      boot.rememberedStorage = readStorageKind(boot.build.epochKey);
      return Promise.all([requestPersistOnce(), P.lock.bumpGeneration(), P.env.pickStorage(storageOverride, boot.rememberedStorage && boot.rememberedStorage.storage)]);
    }).then(function (r) {
      var persisted = r[0];
      var generation = r[1];
      var st = r[2];
      var dbName = 'optomstroy-demo-' + slug(boot.build.epochKey);
      if (st.storage === 'idb' || st.fallback.indexOf('idb') >= 0) P.reset.rememberDb('/pglite/' + dbName);
      boot.storage = { storage: st.storage, fallback: st.fallback, source: st.source, dbName: dbName, generation: generation };
      step('start', boot.storage);
      stage('Загружаем сервер демо…', 12);
      markStep('server', 'active');
      markStep('app', 'active');
      wireLifecycle();
      B._start({
        epochKey: boot.build.epochKey,
        buildId: boot.build.buildId,
        dbName: dbName,
        storage: st.storage,
        storageFallback: st.fallback,
        generation: generation,
        tabId: P.lock.tabId,
        persisted: !!persisted,
        extra: initExtra,
      });
      global.__posOnFlutterFirstFrame = function () {
        boot.firstFrame = true;
        step('first-frame');
        markStep('app', 'done');
        if (!B.isReady && B.phase === 'starting') stage('Приложение загружено, запускаем сервер демо…');
        maybeHide();
      };
      loadFlutter();
    }).catch(function (e) {
      step('boot-error', { message: String(e && e.message || e) });
      showFatal({ message: 'Ошибка загрузки страницы демо: ' + (e && e.stack ? e.stack : e), code: 'boot' });
    });
  }

  boot.resetDemo = resetDemo;
  boot.main = main;
  boot.reload = reload;
  P.boot = boot;

  if (!B || !P.env || !P.lock || !P.reset) {
    // Какой-то из скриптов не выполнился (очень старый браузер или ошибка загрузки).
    var t = doc.getElementById('pd-stage');
    if (t) t.textContent = 'Этот браузер не может запустить демо. Откройте ссылку на компьютере в Chrome или Edge.';
    return;
  }
  main();
})(window);
