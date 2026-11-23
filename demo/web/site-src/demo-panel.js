/*
 * Оптомстрой POS · веб-демо · панель «ДЕМО» поверх приложения (WP-S1; plan §3.6; ADR-113 п. 9).
 *
 * HTML поверх Flutter, вне ARB и 02: строки только русские. Цвета — CSS-переменные из contracts/design-tokens
 * (demo-tokens.css, генерирует build-site.mjs). Разделы: «Как войти», «Планшет магазина», «Оплата QR», «1С», «Сеть»,
 * «Сервис». В «Как войти» — и подсказка о входе по лицу или отпечатку (passkey, 15 ADR-116; сам вход — в интерфейсе
 * приложения, SCR-42 → SCR-08; страница — demo-passkey.js). «Планшет магазина» (P-002 TAB-3-01, ADR-115) — подсказка и список планшетов из GET state: первое
 * подключение идёт через настоящий интерфейс приложения (вход администратором, SCR-54), новых точек входа нет.
 * Переключение «Вернуться к обычному входу» / «Планшет магазина» / «Подключить этот браузер заново» (TAB-3-02) —
 * перенос данных приложения в хранилище страницы при перезагрузке (demo-kiosk.js, P.boot.kioskSwitch).
 *
 * Клавиатура (critic «ввод в HTML-панели перехватывают горячие клавиши Flutter»): Flutter слушает keydown/keyup на window
 * в фазе захвата. Слушатель этой панели регистрируется на window в той же фазе РАНЬШЕ Flutter (скрипт выполняется до
 * загрузки flutter_bootstrap.js) и для событий из панели вызывает stopImmediatePropagation — ввод в полях панели
 * работает (действие по умолчанию не отменяется), а горячие клавиши приложения (Esc, F2, Ctrl+…) не срабатывают.
 * Esc при открытой панели закрывает её (и тоже не доходит до приложения).
 * Указатель: события из панели не всплывают до window (pointermove/up Flutter слушает там).
 * Панель немодальная: приложение под ней остаётся доступным (например, экран QR виден, пока жмёте «Оплатить сейчас»),
 * шапка (68 lp) и нижняя навигация (80 lp) приложения панелью не перекрываются.
 */
(function (global) {
  'use strict';

  var P = global.PosDemoPage = global.PosDemoPage || {};
  var doc = global.document;
  var B = global.__posDemo;
  var D = P.data || {};

  var ui = {
    root: null,
    fab: null,
    panel: null,
    status: null,
    hint: null,
    qrBox: null,
    onecBox: null,
    kioskBox: null,
    kioskMode: null,
    kioskSwitch: null,
    kioskSwitchSig: null,
    netNote: null,
    serviceInfo: null,
    devBox: null,
    offlineToggle: null,
    confirmBox: null,
  };
  var isOpen = false;
  var pollTimer = null;
  var lastState = null;
  var lastStateError = null;
  var panelPointers = {};
  var statusTimer = null;
  // Поле ввода приложения, в котором был фокус, когда «ДЕМО» нажали мышью (вставка на экранах входа, 2026-11-08):
  // после закрытия панели фокус возвращается в него, и Ctrl+V сразу после «Скопировать» вставляет номер или код.
  var appFocus = null;

  // ---------------------------------------------------------------- DOM
  function el(tag, props) {
    var n = doc.createElement(tag);
    if (props) {
      Object.keys(props).forEach(function (k) {
        var v = props[k];
        if (v === undefined || v === null || v === false) return;
        if (k === 'text') n.textContent = v;
        else if (k === 'class') n.className = v;
        else if (k === 'on') Object.keys(v).forEach(function (ev) { n.addEventListener(ev, v[ev]); });
        else if (k === 'dataset') Object.keys(v).forEach(function (d) { n.dataset[d] = v[d]; });
        else if (k in n && typeof v !== 'string') n[k] = v;
        else n.setAttribute(k, v === true ? '' : String(v));
      });
    }
    for (var i = 2; i < arguments.length; i++) {
      var c = arguments[i];
      if (c === null || c === undefined || c === false) continue;
      if (Array.isArray(c)) c.forEach(function (x) { if (x) n.appendChild(typeof x === 'string' ? doc.createTextNode(x) : x); });
      else n.appendChild(typeof c === 'string' ? doc.createTextNode(c) : c);
    }
    return n;
  }

  function clear(n) {
    while (n.firstChild) n.removeChild(n.firstChild);
  }

  function formatPhone(e164) {
    var d = String(e164 || '').replace(/\D/g, '');
    if (d.length === 12 && d.indexOf('996') === 0) return '+996 ' + d.slice(3, 6) + ' ' + d.slice(6, 9) + ' ' + d.slice(9);
    return String(e164 || '');
  }

  // Денежные суммы приходят строкой с точкой ("1250.00") или числом; без арифметики с плавающей точкой.
  function formatMoney(v) {
    if (v === undefined || v === null || v === '') return '';
    var s = typeof v === 'number' ? v.toFixed(2) : String(v);
    var m = /^(-?)(\d+)(?:\.(\d+))?$/.exec(s.trim());
    if (!m) return s;
    var int = m[2].replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
    var frac = ((m[3] || '') + '00').slice(0, 2);
    return m[1] + int + ',' + frac + ' сом';
  }

  function setStatus(text, kind) {
    if (!ui.status) return;
    ui.status.textContent = text || '';
    ui.status.dataset.kind = kind || 'info';
    if (statusTimer) clearTimeout(statusTimer);
    if (text) {
      statusTimer = setTimeout(function () {
        if (ui.status) ui.status.textContent = '';
      }, kind === 'error' ? 12000 : 5000);
    }
  }

  function errorText(e) {
    if (!e) return 'ошибка';
    if (e.code === 'not_found' || /unknown|не поддерж/i.test(String(e.message))) return 'команда не поддерживается сервером демо';
    return e.message || String(e);
  }

  // ---------------------------------------------------------------- копирование
  function legacyCopy(text) {
    var active = doc.activeElement;
    var ta = el('textarea', { readonly: true, 'aria-hidden': 'true', class: 'pd-offscreen' });
    ta.value = text;
    ui.root.appendChild(ta);
    ta.select();
    var ok = false;
    try {
      ok = doc.execCommand('copy');
    } catch (e) {
      ok = false;
    }
    ui.root.removeChild(ta);
    if (active && active.focus) active.focus();
    return ok ? Promise.resolve() : Promise.reject(new Error('copy'));
  }

  function copyText(text) {
    var nav = global.navigator;
    if (nav.clipboard && typeof nav.clipboard.writeText === 'function' && global.isSecureContext) {
      return nav.clipboard.writeText(text).catch(function () { return legacyCopy(text); });
    }
    return legacyCopy(text);
  }

  function copyButton(value, label, doneText, aria) {
    var btn = el('button', { type: 'button', class: 'pd-btn pd-btn-small pd-copy', text: label, 'aria-label': aria || label, dataset: { copy: value } });
    btn.addEventListener('click', function () {
      copyText(value).then(function () {
        btn.textContent = 'Скопировано';
        btn.classList.add('is-done');
        setStatus(doneText, 'ok');
        setTimeout(function () {
          btn.textContent = label;
          btn.classList.remove('is-done');
        }, 1500);
      }, function () {
        setStatus('Не удалось скопировать — выделите текст и нажмите Ctrl+C.', 'error');
      });
    });
    return btn;
  }

  // ---------------------------------------------------------------- разделы
  function section(id, title, openByDefault, body) {
    var det = el('details', { class: 'pd-section', id: 'pd-sec-' + id, open: !!openByDefault });
    det.appendChild(el('summary', { class: 'pd-section-title', text: title }));
    var box = el('div', { class: 'pd-section-body' });
    (Array.isArray(body) ? body : [body]).forEach(function (b) { if (b) box.appendChild(b); });
    det.appendChild(box);
    return det;
  }

  function buildLogin() {
    var code = D.otpCode || '246810';
    var rows = (D.roles || []).map(function (r) {
      return el('li', { class: 'pd-row' },
        el('div', { class: 'pd-row-main' },
          el('span', { class: 'pd-phone', text: formatPhone(r.phone) }),
          el('span', { class: 'pd-muted', text: r.label })),
        copyButton(r.phone, 'Скопировать номер', 'Номер ' + formatPhone(r.phone) + ' скопирован.', 'Скопировать номер ' + formatPhone(r.phone)));
    });
    var customers = (D.customers || []).map(function (c) {
      return el('li', { class: 'pd-row pd-row-compact' },
        el('span', { class: 'pd-chip', text: c.search }),
        el('div', { class: 'pd-row-main' },
          el('span', { text: c.name }),
          el('span', { class: 'pd-muted', text: (c.phone ? formatPhone(c.phone) + ' · ' : '') + c.note })));
    });
    return [
      el('div', { class: 'pd-code' },
        el('div', null,
          el('div', { class: 'pd-muted', text: 'Код из SMS для любого номера' }),
          el('div', { class: 'pd-code-value', text: code })),
        copyButton(code, 'Скопировать', 'Код ' + code + ' скопирован.', 'Скопировать код ' + code)),
      el('h3', { class: 'pd-subtitle', text: 'Номера для входа' }),
      el('ul', { class: 'pd-list', id: 'pd-login-roles' }, rows),
      el('p', { class: 'pd-note' },
        'Сотрудник при первом входе придумывает PIN из 6 цифр, например ',
        el('b', { text: D.pinExample || '715382' }),
        '. Простые PIN ' + (D.pinBad || ['111111', '123456']).join(' и ') + ' не подойдут.'),
      D.customerPinNote ? el('p', { class: 'pd-note', text: D.customerPinNote }) : null,
      // Вход по лицу или отпечатку — passkey браузера (15 ADR-116 п. 1, п. 4; 09 BIO-035, BIO-041). Подписи переключателя
      // SCR-42 — из 02 §7: settings_bio_windows_key, settings_bio_windows, settings_bio_android. Режим выбирает приложение
      // (браузер на Windows — ключ входа или гейт; остальные — привязка), поэтому текст называет оба случая.
      el('h3', { class: 'pd-subtitle', text: 'Вход по лицу или отпечатку' }),
      el('p', { class: 'pd-note', id: 'pd-login-passkey', text: 'После входа по коду: «Настройки» (меню профиля в шапке или «Профиль») → «Защита входа». Браузер попросит лицо, отпечаток или PIN устройства и сохранит ключ доступа (passkey) для этого адреса сайта.' }),
      el('p', { class: 'pd-note', id: 'pd-login-passkey-os', text: 'Windows: «Вход через Windows Hello» — дальше вход без PIN приложения. Если браузер так не умеет, будет «Windows Hello перед вводом PIN»: после Windows Hello нужен PIN приложения. Телефон и другие системы: «Вход по отпечатку или лицу» — вход без PIN.' }),
      el('p', { class: 'pd-note', id: 'pd-login-passkey-reset', text: '«Сбросить демо» может не удалить ключ из Windows или Google — его удаляют в настройках ключей доступа. На планшете магазина вход по лицу не предлагается.' }),
      el('h3', { class: 'pd-subtitle', text: 'Тестовые клиенты' }),
      el('p', { class: 'pd-note', text: 'Кассир, старший продавец, администратор и руководитель находят клиента по имени (слово на метке) или по полному номеру. Продавец ищет только по полному номеру телефона.' }),
      el('ul', { class: 'pd-list', id: 'pd-login-customers' }, customers),
    ];
  }

  // ---------------------------------------------------------------- «Планшет магазина» (P-002 TAB-3-01, TAB-3-02)
  // Признак режима планшета в этом браузере: ключ хранилища приложения `kiosk.tablet_id` (SecureKey.kioskTabletId,
  // pos-app/lib/core/storage/secure_storage.dart) в localStorage под префиксом flutter_secure_storage_web. Значение
  // зашифровано — панель смотрит только, есть ли ключ, и ничего не расшифровывает (demo-kiosk.js).
  var KIOSK_FLAG_KEY = 'FlutterSecureStorage.kiosk.tablet_id';
  function isKioskDevice() {
    if (P.kiosk) return P.kiosk.isTablet();
    try {
      return global.localStorage.getItem(KIOSK_FLAG_KEY) !== null;
    } catch (e) {
      return false;
    }
  }

  function buildKiosk() {
    var K = D.kiosk || {};
    var admin = K.adminPhone || '+996777000901';
    var code = D.otpCode || '246810';
    var step = function () {
      return el('li', null, Array.prototype.slice.call(arguments));
    };
    ui.kioskMode = el('p', { class: 'pd-note', id: 'pd-kiosk-mode' });
    ui.kioskSwitch = el('div', { class: 'pd-dyn', id: 'pd-kiosk-switch' });
    ui.kioskSwitchSig = null;
    ui.kioskBox = el('div', { class: 'pd-dyn', id: 'pd-kiosk-tablets' }, el('p', { class: 'pd-muted', text: 'Загрузка…' }));
    return [
      el('p', { class: 'pd-note', text: 'Режим для торгового зала: покупатель сам выбирает товары и отправляет заявку, оплата — на кассе. Подключение — в настоящем интерфейсе приложения.' }),
      // режим этого браузера и переключение — сразу под вводным текстом (TAB-3-02)
      ui.kioskMode,
      ui.kioskSwitch,
      el('ol', { class: 'pd-steps', id: 'pd-kiosk-steps' },
        step('Войдите администратором: ', el('b', { text: formatPhone(admin) }), ', код ', el('b', { text: code }), '. При первом входе задайте PIN из 6 цифр, например ', el('b', { text: D.pinExample || '715382' }), '.'),
        step('Меню разделов «☰» → «Администратор» → в шапке экрана «Пользователи» кнопка разделов → «Планшеты магазина».'),
        step('«Сделать это устройство планшетом магазина» → имя, например «', el('b', { text: K.tabletName || 'Планшет у входа' }), '», склад → «Сделать это устройство планшетом магазина» → PIN администратора.'),
        step('Появится аварийный код выхода — один раз. ', K.exitCodeNote || 'Аварийный код выхода в демо можно не записывать.', ' «Готово» — откроется витрина планшета.'),
        step('Заявка: «+ Добавить» → кнопка корзины → «Оформить заявку» → номер на экранной клавиатуре, например ', el('b', { text: formatPhone(K.buyerPhone || '+996700000101') }), ' (карточка «1С») или любой другой → код ', el('b', { text: code }), ' → «Отправить заявку».'),
        step('Заявка — в разделе «1С» ниже с пометкой «С планшета». Кассир (', el('b', { text: formatPhone(K.cashierPhone || '+996777000906') }), ') видит её в «Ожидают оплаты»: «Вернуться к обычному входу» ниже → войдите кассиром. Кнопка «Планшет магазина» вернёт тот же планшет без подключения заново.')),
      el('div', { class: 'pd-inline' }, copyButton(admin, 'Скопировать номер администратора', 'Номер ' + formatPhone(admin) + ' скопирован.', 'Скопировать номер администратора ' + formatPhone(admin))),
      el('p', { class: 'pd-note', text: 'В браузере планшет не закрепляется на экране (на планшете Android закрепление обязательно). Повторный код — через 10 с, а не 60 с. Оповещение «планшет не на связи» в демо выключено. «Сбросить демо» удаляет и планшет: после сброса — только новое подключение (шаги 1–4).' }),
      el('h3', { class: 'pd-subtitle', text: 'Планшеты магазина' }),
      ui.kioskBox,
    ];
  }

  function control(action, args, okText) {
    return B.control(action, args).then(function (data) {
      if (okText) setStatus(okText, 'ok');
      refreshState();
      return data;
    }, function (e) {
      setStatus('Не выполнено: ' + errorText(e), 'error');
      throw e;
    });
  }

  function buildQr() {
    var auto = el('input', { type: 'checkbox', id: 'pd-qr-auto', checked: true });
    var polls = el('input', { type: 'number', id: 'pd-qr-polls', class: 'pd-input pd-input-num', min: '1', max: '60', step: '1', value: String(D.qrDefaultPolls || 5), 'aria-label': 'Число опросов до автооплаты' });
    var seconds = el('span', { class: 'pd-muted', id: 'pd-qr-seconds' });
    var updateSeconds = function () {
      var n = Math.max(1, Math.min(60, parseInt(polls.value, 10) || 1));
      seconds.textContent = '≈ ' + Math.round(n * (D.qrPollSeconds || 3.6)) + ' с';
    };
    updateSeconds();
    var apply = function () {
      var n = Math.max(1, Math.min(60, parseInt(polls.value, 10) || 1));
      polls.value = String(n);
      updateSeconds();
      control('POST qr/config', { paidAfterPolls: auto.checked ? n : 0 }, auto.checked ? 'Автооплата QR: через ' + n + ' опросов.' : 'Автооплата QR выключена: оплачивайте кнопкой.').catch(function () {});
    };
    auto.addEventListener('change', apply);
    polls.addEventListener('change', apply);
    polls.addEventListener('input', updateSeconds);
    ui.qrBox = el('div', { class: 'pd-dyn', id: 'pd-qr-list' }, el('p', { class: 'pd-muted', text: 'Загрузка…' }));
    return [
      el('label', { class: 'pd-toggle' }, auto, el('span', null, 'Оплачивать QR автоматически')),
      el('div', { class: 'pd-inline' }, el('span', { text: 'через' }), polls, el('span', { text: 'опросов' }), seconds),
      el('h3', { class: 'pd-subtitle', text: 'Ожидают оплаты' }),
      ui.qrBox,
    ];
  }

  function buildOnec() {
    var down = el('input', { type: 'checkbox', id: 'pd-onec-down' });
    down.addEventListener('change', function () {
      control('POST onec/down', { down: down.checked }, down.checked ? '«1С» недоступна: заказы ждут в очереди.' : '«1С» снова доступна.').catch(function () {
        down.checked = !down.checked;
      });
    });
    ui.onecDown = down;
    ui.onecMode = el('div', { class: 'pd-dyn', id: 'pd-onec-mode' });
    ui.onecBox = el('div', { class: 'pd-dyn', id: 'pd-onec-orders' }, el('p', { class: 'pd-muted', text: 'Загрузка…' }));
    return [
      el('label', { class: 'pd-toggle' }, down, el('span', null, '«1С» недоступна')),
      ui.onecMode,
      el('h3', { class: 'pd-subtitle', text: 'Последние заказы' }),
      ui.onecBox,
    ];
  }

  function buildNetwork() {
    var t = el('input', { type: 'checkbox', id: 'pd-offline' });
    t.checked = !!B.offline;
    t.addEventListener('change', function () {
      B.setOffline(t.checked);
      setStatus(t.checked ? 'Сеть «отключена»: приложение работает в офлайн-режиме.' : 'Сеть снова есть.', 'ok');
    });
    ui.offlineToggle = t;
    ui.netNote = el('p', { class: 'pd-note', id: 'pd-net-note', text: networkNote() });
    return [
      el('label', { class: 'pd-toggle' }, t, el('span', null, 'Нет сети (имитация)')),
      ui.netNote,
    ];
  }

  // Подсказка «Сеть»: на планшете магазина корзина только на сервере (P-002 §15) — без сети заявку не оформить.
  function networkNote() {
    return isKioskDevice()
      ? 'Планшет магазина покажет «Нет связи»: товары смотреть можно, «В корзину» и отправка заявки недоступны, пока сеть не вернётся.'
      : 'Приложение покажет «Нет сети»: каталог открывается из памяти, изменения корзины уйдут на сервер, когда сеть вернётся.';
  }

  function buildService() {
    var resetBtn = el('button', { type: 'button', class: 'pd-btn pd-btn-danger', id: 'pd-reset', text: 'Сбросить демо' });
    var confirm = el('div', { class: 'pd-confirm', id: 'pd-reset-confirm', role: 'alertdialog', 'aria-labelledby': 'pd-reset-q', hidden: true },
      el('p', { id: 'pd-reset-q', text: 'Все данные демо в этом браузере будут удалены: заказы, корзины, вход и настройки. Демо начнётся заново.' }),
      el('div', { class: 'pd-actions-row' },
        el('button', { type: 'button', class: 'pd-btn pd-btn-danger', id: 'pd-reset-yes', text: 'Сбросить', on: { click: function () { doReset(); } } }),
        el('button', { type: 'button', class: 'pd-btn', id: 'pd-reset-no', text: 'Отмена', on: { click: function () { closeConfirm(true); } } })));
    ui.confirmBox = confirm;
    resetBtn.addEventListener('click', function () {
      confirm.hidden = false;
      var no = doc.getElementById('pd-reset-no');
      if (no) no.focus();
    });
    ui.resetBtn = resetBtn;
    ui.serviceInfo = el('dl', { class: 'pd-info', id: 'pd-service-info' });
    ui.devBox = el('pre', { class: 'pd-dev', id: 'pd-dev' });
    // review fixes (critic [11]): лицензии сторонних компонентов — со страницы, а не только из комментария в backend.js.
    var licenses = el('p', { class: 'pd-note', id: 'pd-licenses' },
      el('a', { href: 'THIRD_PARTY_NOTICES.txt', target: '_blank', rel: 'noopener', id: 'pd-licenses-link', text: 'Лицензии сторонних компонентов' }),
      ' · ',
      el('a', { href: 'assets/NOTICES', target: '_blank', rel: 'noopener', text: 'лицензии приложения (Flutter)' }),
      // ADR-113 п. 11 (а): собственный код — только для просмотра, без лицензии.
      el('br'), 'Код «Оптомстрой POS» показан только для просмотра, без лицензии. Все права защищены.');
    return [
      resetBtn,
      confirm,
      ui.serviceInfo,
      licenses,
      el('details', { class: 'pd-subsection' }, el('summary', { text: 'Для разработчика' }), ui.devBox),
    ];
  }

  function closeConfirm(focusReset) {
    if (!ui.confirmBox || ui.confirmBox.hidden) return false;
    ui.confirmBox.hidden = true;
    if (focusReset && ui.resetBtn) ui.resetBtn.focus();
    return true;
  }

  function doReset() {
    setStatus('Сбрасываем демо…', 'info');
    if (P.boot && typeof P.boot.resetDemo === 'function') P.boot.resetDemo('panel');
  }

  // ---------------------------------------------------------------- состояние из /__demo/state
  function renderQr(st) {
    var box = ui.qrBox;
    if (!box) return;
    clear(box);
    if (!st) {
      box.appendChild(el('p', { class: 'pd-muted', text: lastStateError ? 'Управление демо недоступно: ' + lastStateError : 'Загрузка…' }));
      return;
    }
    var qr = st.qr || {};
    var auto = doc.getElementById('pd-qr-auto');
    var polls = doc.getElementById('pd-qr-polls');
    if (auto && typeof qr.paidAfterPolls === 'number' && doc.activeElement !== auto && doc.activeElement !== polls) {
      auto.checked = qr.paidAfterPolls > 0;
      if (qr.paidAfterPolls > 0 && polls) polls.value = String(qr.paidAfterPolls);
    }
    var pending = qr.pending || [];
    if (!pending.length) {
      box.appendChild(el('p', { class: 'pd-muted', text: 'Нет QR, ожидающих оплаты.' }));
      return;
    }
    var list = el('ul', { class: 'pd-list' });
    pending.forEach(function (q) {
      var pid = q.paymentId || q.externalId;
      var amountForm = el('form', { class: 'pd-inline pd-amount', hidden: true },
        el('input', { type: 'text', inputmode: 'decimal', class: 'pd-input', name: 'amount', placeholder: 'Сумма, сом', 'aria-label': 'Сумма оплаты, сом', autocomplete: 'off' }),
        el('button', { type: 'submit', class: 'pd-btn pd-btn-small pd-btn-primary', text: 'Оплатить' }));
      amountForm.addEventListener('submit', function (ev) {
        ev.preventDefault();
        var raw = String(amountForm.elements.amount.value || '').replace(/\s/g, '').replace(',', '.');
        if (!/^\d+(\.\d{1,2})?$/.test(raw)) {
          setStatus('Сумма — число, например 1250 или 1250,50.', 'error');
          return;
        }
        control('POST qr/' + pid + '/pay', { amount: raw }, 'QR оплачен суммой ' + formatMoney(raw) + '.').catch(function () {});
      });
      var title = (q.orderNumber ? 'Заказ ' + q.orderNumber : 'Платёж') + (q.amount !== undefined ? ' · ' + formatMoney(q.amount) : '');
      list.appendChild(el('li', { class: 'pd-row pd-row-col', dataset: { payment: pid } },
        el('div', { class: 'pd-row-main' },
          el('span', { text: title }),
          el('span', { class: 'pd-muted', text: typeof q.polls === 'number' ? 'опросов: ' + q.polls : '' })),
        el('div', { class: 'pd-actions-row' },
          el('button', { type: 'button', class: 'pd-btn pd-btn-small pd-btn-primary', text: 'Оплатить сейчас', dataset: { act: 'qr-pay' }, on: { click: function () { control('POST qr/' + pid + '/pay', {}, 'QR оплачен.').catch(function () {}); } } }),
          el('button', { type: 'button', class: 'pd-btn pd-btn-small', text: 'Оплатить другой суммой', dataset: { act: 'qr-amount' }, on: { click: function () {
            amountForm.hidden = !amountForm.hidden;
            if (!amountForm.hidden) amountForm.elements.amount.focus();
          } } }),
          el('button', { type: 'button', class: 'pd-btn pd-btn-small', text: 'Истечь', dataset: { act: 'qr-expire' }, on: { click: function () { control('POST qr/' + pid + '/expire', {}, 'Срок QR истёк.').catch(function () {}); } } })),
        amountForm));
    });
    box.appendChild(list);
  }

  var ONEC_STATUS = { 'НеСогласован': 'не согласован', 'КВыполнению': 'к выполнению', 'Закрыт': 'закрыт' };

  function renderOnec(st) {
    var box = ui.onecBox;
    if (!box) return;
    clear(box);
    clear(ui.onecMode);
    if (!st) {
      box.appendChild(el('p', { class: 'pd-muted', text: lastStateError ? 'Управление демо недоступно: ' + lastStateError : 'Загрузка…' }));
      return;
    }
    var onec = st.onec || {};
    if (ui.onecDown && doc.activeElement !== ui.onecDown) ui.onecDown.checked = !!onec.down;
    var rejecting = onec.orderMode === 'reject' && Number(onec.failNext || 0) > 0;
    if (rejecting) {
      ui.onecMode.appendChild(el('div', { class: 'pd-inline' },
        el('span', { class: 'pd-badge pd-badge-warn', text: 'Следующий заказ «1С» отклонит' }),
        el('button', { type: 'button', class: 'pd-btn pd-btn-small', id: 'pd-onec-reject-cancel', text: 'Отменить', on: { click: function () { control('POST onec/orders/mode', { mode: 'accept', failNext: 0 }, '«1С» принимает заказы.').catch(function () {}); } } })));
    } else {
      ui.onecMode.appendChild(el('button', { type: 'button', class: 'pd-btn pd-btn-small', id: 'pd-onec-reject', text: 'Отклонить следующий заказ', on: { click: function () { control('POST onec/orders/mode', { mode: 'reject', failNext: 1 }, 'Следующий заказ «1С» отклонит.').catch(function () {}); } } }));
    }
    var orders = st.orders || [];
    if (!orders.length) {
      box.appendChild(el('p', { class: 'pd-muted', text: 'Заказов пока нет.' }));
      return;
    }
    var returnsByOrder = {};
    (st.returns || []).forEach(function (r) {
      if (!r.orderId) return;
      (returnsByOrder[r.orderId] = returnsByOrder[r.orderId] || []).push(r);
    });
    var list = el('ul', { class: 'pd-list' });
    orders.slice(0, 10).forEach(function (o) {
      var acts = Array.isArray(o.actions) ? o.actions : null;
      var can = function (a) { return !acts || acts.indexOf(a) >= 0; };
      var rets = (o.returns || returnsByOrder[o.id] || []).filter(function (r) { return r.status !== 'completed' && r.status !== 'rejected'; });
      var ret = rets[0] || null;
      var status = o.onecStatus ? ONEC_STATUS[o.onecStatus] || o.onecStatus : null;
      var meta = [o.onecNumber ? '1С ' + o.onecNumber : 'в «1С» не передан', status, o.shipped ? 'отгружен' : null, o.total !== undefined ? formatMoney(o.total) : null].filter(Boolean).join(' · ');
      var btn = function (label, act, enabled, fn) {
        return el('button', { type: 'button', class: 'pd-btn pd-btn-small', text: label, disabled: !enabled, dataset: { act: act }, on: { click: fn } });
      };
      list.appendChild(el('li', { class: 'pd-row pd-row-col', dataset: { order: o.id, createdVia: o.createdVia || '' } },
        el('div', { class: 'pd-row-main' },
          el('span', null,
            'Заказ ' + (o.number || o.id),
            // заявка с планшета магазина (orders.created_via = kiosk; пометка как у кассира, 02 §7 order_badge_kiosk)
            o.createdVia === 'kiosk' ? el('span', { class: 'pd-badge pd-badge-kiosk', text: 'С планшета' }) : null),
          el('span', { class: 'pd-muted', text: meta })),
        el('div', { class: 'pd-actions-row' },
          btn('Согласовать', 'approve', can('approve'), function () { control('POST orders/' + o.id + '/onec-status', { status: 'КВыполнению', approved: true }, 'Заказ согласован в «1С».').catch(function () {}); }),
          btn('Отгрузить', 'ship', can('ship'), function () { control('POST orders/' + o.id + '/ship', {}, 'Заказ отгружен.').catch(function () {}); }),
          btn('Закрыть', 'close', can('close'), function () { control('POST orders/' + o.id + '/onec-status', { status: 'Закрыт' }, 'Заказ закрыт в «1С».').catch(function () {}); }),
          btn('Выполнить возврат', 'return', !!ret && can('return'), function () {
            if (ret) control('POST returns/' + ret.externalId + '/status', { status: 'completed' }, 'Возврат проведён в «1С».').catch(function () {});
          }))));
    });
    box.appendChild(list);
  }

  var TABLET_STATUS = { active: 'подключён', revoked: 'отключён' };

  function formatTime(iso) {
    if (!iso) return null;
    var d = new Date(iso);
    if (isNaN(d.getTime())) return null;
    var p = function (n) { return (n < 10 ? '0' : '') + n; };
    return p(d.getDate()) + '.' + p(d.getMonth() + 1) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
  }

  // ---- переключение «планшет ↔ обычный вход» (P-002 TAB-3-02; 12 T-KIOSK-051)
  var KIOSK_SWITCH_STATUS = {
    normal: 'Возвращаемся к обычному входу…',
    kiosk: 'Возвращаем планшет магазина…',
    reconnect: 'Готовим подключение заново…',
  };

  function requestSwitch(to) {
    setStatus(KIOSK_SWITCH_STATUS[to], 'info');
    if (!P.boot || typeof P.boot.kioskSwitch !== 'function' || !P.boot.kioskSwitch(to)) {
      setStatus('Переключить не удалось: браузер не даёт хранилище страницы.', 'error');
    }
  }

  function switchButton(id, text, kind, to, aria) {
    return el('button', { type: 'button', class: 'pd-btn' + (kind ? ' pd-btn-' + kind : ''), id: id, text: text, 'aria-label': aria || text, dataset: { kioskSwitch: to }, on: { click: function () { requestSwitch(to); } } });
  }

  function formatAt(ms) {
    return (ms ? formatTime(new Date(ms).toISOString()) : null) || '—';
  }

  function reconnectBlock(lead) {
    return el('div', { id: 'pd-kiosk-reconnect-box' },
      el('p', { class: 'pd-note', text: lead }),
      el('div', { class: 'pd-actions-row' }, switchButton('pd-kiosk-reconnect', 'Подключить этот браузер заново', '', 'reconnect')),
      el('p', { class: 'pd-muted', text: 'Затем войдите администратором → «Планшеты магазина» → «Подключить заново этот планшет» → выберите планшет → PIN: тот же планшет (история заявок сохраняется), новый аварийный код.' + (isKioskDevice() ? '' : ' Текущий вход сохранится и вернётся кнопкой «Вернуться к обычному входу».') }));
  }

  // Что предложить — по режиму браузера, отложенным данным (P.kiosk.slotInfo, без значений) и списку планшетов сервера;
  // итог последнего переключения — P.kiosk.result. Перерисовка — только при изменении (кнопки не теряют фокус).
  function renderKioskSwitch(st) {
    var box = ui.kioskSwitch;
    if (!box) return;
    var kiosk = P.kiosk || null;
    var ok = !!(kiosk && kiosk.available());
    var tablet = isKioskDevice();
    var slotK = ok ? kiosk.slotInfo('kiosk') : null;
    var slotN = ok ? kiosk.slotInfo('normal') : null;
    var res = kiosk ? kiosk.result : null;
    var tablets = st && st.kiosk && Array.isArray(st.kiosk.tablets) ? st.kiosk.tablets.length : null;
    var sig = JSON.stringify([ok, tablet, slotK, slotN, res && [res.to, res.ok, res.reason], tablets === null ? null : tablets > 0]);
    if (sig === ui.kioskSwitchSig) return;
    ui.kioskSwitchSig = sig;
    clear(box);
    if (!ok) {
      box.appendChild(el('p', { class: 'pd-muted', text: 'Переключение «планшет ↔ обычный вход» недоступно: браузер не даёт хранилище страницы.' }));
      return;
    }
    if (res && res.to === 'kiosk' && !res.ok) {
      box.appendChild(el('p', { class: 'pd-badge pd-badge-warn', id: 'pd-kiosk-notice', dataset: { reason: res.reason || '' }, text: 'Планшет магазина вернуть не удалось: ' + kiosk.reasonText(res.reason) + '. Подключите этот браузер заново.' }));
    }
    if (tablet) {
      box.appendChild(el('p', { class: 'pd-note', text: '«Вернуться к обычному входу»: данные планшета останутся в этом браузере — кнопка «Планшет магазина» вернёт тот же планшет без подключения заново. Корзина планшета очистится, как при гашении экрана. ' + (slotN && !slotN.broken ? 'Вернётся прежний вход (отложен ' + formatAt(slotN.at) + ').' : 'Затем откроется экран входа.') }));
      box.appendChild(el('div', { class: 'pd-actions-row' }, switchButton('pd-kiosk-to-normal', 'Вернуться к обычному входу', 'primary', 'normal')));
      box.appendChild(reconnectBlock('Планшет просит подключить заново или данные не вернулись? «Подключить этот браузер заново» удалит данные планшета в этом браузере (идентификатор браузера сохранится).'));
      return;
    }
    if (slotK && !slotK.broken) {
      box.appendChild(el('p', { class: 'pd-note', text: 'Планшет магазина отложен ' + formatAt(slotK.at) + ': кнопка вернёт его без подключения заново, корзина будет пустой. Текущий вход сохранится и вернётся кнопкой «Вернуться к обычному входу».' + (slotK.stale ? ' Прошло больше 7 дней: планшет может попросить подключить заново.' : '') }));
      box.appendChild(el('div', { class: 'pd-actions-row' }, switchButton('pd-kiosk-to-kiosk', 'Планшет магазина', 'primary', 'kiosk', 'Планшет магазина: вернуть этот браузер в режим планшета')));
      return;
    }
    if (tablets === null) return;
    if (tablets > 0) {
      box.appendChild(reconnectBlock('Данных планшета в этом браузере нет. Подключите этот браузер к планшету из списка «Планшеты магазина» внизу раздела:'));
      return;
    }
    box.appendChild(el('p', { class: 'pd-note', id: 'pd-kiosk-first', text: 'Планшет в этом браузере ещё не подключён: шаги 1–4 ниже. После «Сбросить демо» подключение только новое — прежний планшет удалён вместе с данными демо.' }));
  }

  function renderKiosk(st) {
    if (ui.kioskMode) {
      ui.kioskMode.textContent = isKioskDevice()
        ? 'Этот браузер сейчас — планшет магазина.'
        : 'Этот браузер сейчас — обычный вход.';
    }
    renderKioskSwitch(st);
    if (ui.netNote) ui.netNote.textContent = networkNote();
    var box = ui.kioskBox;
    if (!box) return;
    clear(box);
    if (!st) {
      box.appendChild(el('p', { class: 'pd-muted', text: lastStateError ? 'Управление демо недоступно: ' + lastStateError : 'Загрузка…' }));
      return;
    }
    var k = st.kiosk || null;
    if (!k) {
      box.appendChild(el('p', { class: 'pd-muted', text: 'Сервер демо не сообщает о планшетах.' }));
      return;
    }
    if (!k.enabled) box.appendChild(el('p', { class: 'pd-badge pd-badge-warn', text: 'Режим планшета на сервере демо выключен' }));
    var tablets = k.tablets || [];
    if (!tablets.length) {
      box.appendChild(el('p', { class: 'pd-muted', text: 'Планшетов пока нет.' }));
      return;
    }
    var list = el('ul', { class: 'pd-list' });
    tablets.forEach(function (t) {
      var seen = formatTime(t.lastSeenAt);
      var meta = [TABLET_STATUS[t.status] || t.status, seen ? 'связь ' + seen : 'связи ещё не было', 'id ' + String(t.id || '').slice(0, 8)].join(' · ');
      list.appendChild(el('li', { class: 'pd-row pd-row-compact', dataset: { tablet: t.id, status: t.status } },
        el('div', { class: 'pd-row-main' },
          el('span', { text: t.name || 'Планшет' }),
          el('span', { class: 'pd-muted', text: meta }))));
    });
    box.appendChild(list);
  }

  function renderService(st) {
    var dl = ui.serviceInfo;
    if (!dl) return;
    clear(dl);
    var info = B.info || {};
    var build = (P.boot && P.boot.build) || {};
    var storageName = { opfs: 'OPFS браузера', idb: 'IndexedDB браузера', memory: 'только в памяти — не сохранится после перезагрузки' };
    var persist = P.store.get(P.KEYS.persist);
    var rows = [
      ['Сборка', (build.buildId || info.buildId || '—') + (build.gitHead ? ' · ' + String(build.gitHead).slice(0, 8) : '')],
      ['Данные демо', String(build.epochKey || info.epochKey || '—').slice(0, 16)],
      ['Хранилище', storageName[info.storage] || info.storage || '—'],
      ['Запись на диск', (function () {
        var hl = B.storageHealth;
        if (info.storage === 'memory') return 'не выполняется (данные только в памяти вкладки)';
        if (hl && hl.ok === false) return 'НЕ УДАЁТСЯ — изменения пропадут после перезагрузки (' + String(hl.error || 'ошибка браузера').slice(0, 120) + '). Освободите место на диске и обновите страницу.';
        return 'работает';
      })()],
      ['Постоянное хранение', persist === 'granted' ? 'разрешено браузером' : persist === 'denied' ? 'браузер не разрешил' : 'неизвестно'],
      ['Вкладка', 'поколение ' + (P.lock ? P.lock.generation : '—')],
    ];
    if (st && st.seed) {
      var s = st.seed;
      rows.push(['История заказов', s.state === 'done' ? 'создана' : s.state === 'failed' ? 'не создана: ' + (s.message || 'ошибка') : 'создаётся' + (typeof s.pct === 'number' ? ' · ' + s.pct + ' %' : '')]);
    }
    rows.forEach(function (r) {
      dl.appendChild(el('dt', { text: r[0] }));
      dl.appendChild(el('dd', { text: r[1] }));
    });
    if (ui.devBox) {
      var dev = { bridge: B._stats, counters: st ? st.counters || null : null, timings: info.timings || null, lock: P.lock ? P.lock.log.slice(-8) : null };
      try {
        ui.devBox.textContent = JSON.stringify(dev, null, 1).slice(0, 6000);
      } catch (e) {
        ui.devBox.textContent = String(e);
      }
    }
  }

  function render() {
    renderKiosk(lastState);
    renderQr(lastState);
    renderOnec(lastState);
    renderService(lastState);
    if (ui.offlineToggle) ui.offlineToggle.checked = !!B.offline;
  }

  function refreshState() {
    if (!B.isReady) {
      render();
      return Promise.resolve(null);
    }
    return B.control('GET state', null, { timeoutMs: 8000 }).then(function (st) {
      lastState = st || {};
      lastStateError = null;
      render();
      return st;
    }, function (e) {
      lastState = null;
      lastStateError = errorText(e);
      render();
      return null;
    });
  }

  function startPolling() {
    stopPolling();
    refreshState();
    pollTimer = setInterval(function () {
      // Не перерисовывать список, пока в нём фокус ввода (сумма QR): иначе поле пропадёт под рукой.
      var a = doc.activeElement;
      if (a && ui.panel && ui.panel.contains(a) && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA')) return;
      refreshState();
    }, 2000);
  }

  function stopPolling() {
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = null;
  }

  // ---------------------------------------------------------------- открыть / закрыть
  function openPanel() {
    if (!ui.root || isOpen) return;
    isOpen = true;
    hideHint();
    ui.panel.hidden = false;
    ui.root.classList.add('is-open');
    ui.fab.setAttribute('aria-expanded', 'true');
    startPolling();
    ui.panel.focus();
  }

  // Открыть панель на разделе id (review fixes: плашка «Данные демо не сохраняются» ведёт в «Сервис»).
  function openSection(id) {
    if (!ui.root) mount();
    openPanel();
    var det = doc.getElementById('pd-sec-' + id);
    if (!det) return false;
    det.open = true;
    try {
      det.scrollIntoView({ block: 'start' });
    } catch (e) { /* ignore */ }
    var sum = det.querySelector('summary');
    if (sum) sum.focus();
    return true;
  }

  function closePanel(returnFocus) {
    if (!ui.root || !isOpen) return;
    isOpen = false;
    closeConfirm(false);
    var hadFocus = ui.panel.contains(doc.activeElement);
    var back = appFocus;
    appFocus = null;
    ui.panel.hidden = true;
    ui.root.classList.remove('is-open');
    ui.fab.setAttribute('aria-expanded', 'false');
    stopPolling();
    if (!(returnFocus || hadFocus)) return;
    // Панель открыли мышью из поля ввода приложения — фокус обратно в поле (элемент ввода движка Flutter: связь с
    // полем у движка остаётся, пока фокус ушёл в панель); иначе — на кнопку «ДЕМО», как прежде.
    if (back && back.isConnected && engineInput(back)) {
      try {
        back.focus({ preventScroll: true });
        return;
      } catch (e) { /* ignore */ }
    }
    ui.fab.focus();
  }

  // Элемент ввода движка Flutter web (скрытый INPUT/TEXTAREA поля в фокусе) или null.
  function engineInput(a) {
    if (!a || (a.tagName !== 'INPUT' && a.tagName !== 'TEXTAREA')) return null;
    if (a.classList && a.classList.contains('flt-text-editing')) return a;
    if (typeof a.closest === 'function' && a.closest('flt-text-editing-host')) return a;
    return null;
  }

  function toggle() {
    if (isOpen) closePanel(true);
    else openPanel();
  }

  function hideHint() {
    if (ui.hint && ui.hint.parentNode) ui.hint.parentNode.removeChild(ui.hint);
    ui.hint = null;
  }

  function showHintOnce() {
    if (P.store.get(P.KEYS.hintShown)) return;
    P.store.set(P.KEYS.hintShown, '1');
    ui.hint = el('div', { class: 'pd-hint', id: 'pd-hint', role: 'note' }, 'Здесь — как войти и управление демо');
    ui.hint.addEventListener('click', hideHint);
    ui.root.appendChild(ui.hint);
    setTimeout(hideHint, 10000);
  }

  // ---------------------------------------------------------------- изоляция ввода от Flutter
  function inPanel(ev) {
    if (!ui.root) return false;
    var path = typeof ev.composedPath === 'function' ? ev.composedPath() : null;
    if (path && path.length) return path.indexOf(ui.root) >= 0;
    return ui.root.contains(ev.target);
  }

  var keyStats = { swallowed: 0, esc: 0 };
  var swallowEscUp = false;
  function onKeyCapture(ev) {
    if (!ui.root) return;
    var isEsc = ev.key === 'Escape' || ev.key === 'Esc';
    // keyup того Esc, который закрыл панель, тоже не отдаём приложению: у Flutter не должно быть «отпускания» без нажатия.
    if (isEsc && ev.type === 'keyup' && swallowEscUp) {
      swallowEscUp = false;
      ev.stopImmediatePropagation();
      ev.preventDefault();
      return;
    }
    if (isOpen && isEsc) {
      ev.stopImmediatePropagation();
      ev.preventDefault();
      if (ev.type === 'keydown') {
        keyStats.esc++;
        swallowEscUp = true;
        if (!closeConfirm(true)) closePanel(inPanel(ev));
      }
      return;
    }
    if (inPanel(ev)) {
      keyStats.swallowed++;
      ev.stopImmediatePropagation();
    }
  }
  // Регистрируется при загрузке скрипта — раньше KeyboardBinding Flutter (тот же window, та же фаза захвата).
  ['keydown', 'keyup', 'keypress'].forEach(function (t) { global.addEventListener(t, onKeyCapture, true); });

  function isolatePointer(root) {
    var stop = function (ev) { ev.stopPropagation(); };
    root.addEventListener('pointerdown', function (ev) {
      panelPointers[ev.pointerId] = true;
      ev.stopPropagation();
    });
    root.addEventListener('pointermove', function (ev) {
      if (ev.buttons === 0 || panelPointers[ev.pointerId]) ev.stopPropagation();
    });
    ['pointerup', 'pointercancel'].forEach(function (t) {
      root.addEventListener(t, function (ev) {
        if (panelPointers[ev.pointerId]) {
          delete panelPointers[ev.pointerId];
          ev.stopPropagation();
        }
      });
    });
    ['wheel', 'touchstart', 'touchmove', 'touchend', 'mousedown', 'mouseup', 'click', 'dblclick', 'contextmenu'].forEach(function (t) {
      root.addEventListener(t, stop, t === 'wheel' || t.indexOf('touch') === 0 ? { passive: true } : false);
    });
  }

  // ---------------------------------------------------------------- монтирование
  function mount() {
    if (ui.root) return;
    var root = el('div', { id: 'pos-demo-panel-root', class: 'pd-root', translate: 'no', lang: 'ru' });
    var fab = el('button', { type: 'button', id: 'pos-demo-fab', class: 'pd-fab', 'aria-expanded': 'false', 'aria-controls': 'pos-demo-panel', 'aria-label': 'Демо-панель: как войти и управление демо', title: 'Демо-панель' },
      el('span', { class: 'pd-fab-label', text: 'ДЕМО' }),
      el('span', { class: 'pd-fab-dot', 'aria-hidden': 'true' }));
    fab.addEventListener('click', toggle);
    // До того как нажатие мышью переведёт фокус на «ДЕМО»: запомнить поле ввода приложения (см. appFocus).
    fab.addEventListener('pointerdown', function () {
      if (!isOpen) appFocus = engineInput(doc.activeElement);
    }, true);
    var status = el('div', { class: 'pd-status', id: 'pd-status', role: 'status', 'aria-live': 'polite' });
    var panel = el('section', { id: 'pos-demo-panel', class: 'pd-panel', role: 'dialog', 'aria-modal': 'false', 'aria-labelledby': 'pd-panel-title', tabindex: '-1', hidden: true },
      el('header', { class: 'pd-panel-head' },
        el('div', null,
          el('h2', { id: 'pd-panel-title', class: 'pd-panel-title', text: 'Демо-панель' }),
          el('p', { class: 'pd-muted pd-panel-sub', text: 'Тестовые данные · 1С, SMS и банк — имитаторы' })),
        el('button', { type: 'button', class: 'pd-icon-btn', id: 'pd-close', 'aria-label': 'Закрыть демо-панель', title: 'Закрыть (Esc)', text: '✕', on: { click: function () { closePanel(true); } } })),
      el('div', { class: 'pd-panel-body' },
        section('login', 'Как войти', true, buildLogin()),
        section('kiosk', 'Планшет магазина', false, buildKiosk()),
        section('qr', 'Оплата QR', false, buildQr()),
        section('onec', '«1С»', false, buildOnec()),
        section('net', 'Сеть', false, buildNetwork()),
        section('service', 'Сервис', false, buildService())),
      status);
    root.appendChild(fab);
    root.appendChild(panel);
    ui.root = root;
    ui.fab = fab;
    ui.panel = panel;
    ui.status = status;
    isolatePointer(root);
    doc.body.appendChild(root);
    B.on('offline', function (d) {
      fab.dataset.offline = d.offline ? '1' : '';
      if (ui.offlineToggle) ui.offlineToggle.checked = !!d.offline;
    });
    render();
    showHintOnce();
  }

  P.panel = {
    mount: mount,
    open: openPanel,
    openSection: openSection,
    close: closePanel,
    refresh: refreshState,
    get isOpen() { return isOpen; },
    get mounted() { return !!ui.root; },
    keyStats: keyStats,
    formatMoney: formatMoney,
    formatPhone: formatPhone,
  };
})(window);
