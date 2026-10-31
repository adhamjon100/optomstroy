/*
 * Оптомстрой POS · веб-демо · панель «ДЕМО» поверх приложения (WP-S1; plan §3.6; ADR-113 п. 9).
 *
 * HTML поверх Flutter, вне ARB и 02: строки только русские. Цвета — CSS-переменные из contracts/design-tokens
 * (demo-tokens.css, генерирует build-site.mjs). Разделы: «Как войти», «Оплата QR», «1С», «Сеть», «Сервис».
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
      el('h3', { class: 'pd-subtitle', text: 'Тестовые клиенты' }),
      el('p', { class: 'pd-note', text: 'Кассир, старший продавец, администратор и руководитель находят клиента по имени (слово на метке) или по полному номеру. Продавец ищет только по полному номеру телефона.' }),
      el('ul', { class: 'pd-list', id: 'pd-login-customers' }, customers),
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
    return [
      el('label', { class: 'pd-toggle' }, t, el('span', null, 'Нет сети (имитация)')),
      el('p', { class: 'pd-note', text: 'Приложение покажет «Нет сети»: каталог открывается из памяти, изменения корзины уйдут на сервер, когда сеть вернётся.' }),
    ];
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
      list.appendChild(el('li', { class: 'pd-row pd-row-col', dataset: { order: o.id } },
        el('div', { class: 'pd-row-main' },
          el('span', { text: 'Заказ ' + (o.number || o.id) }),
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
    ui.panel.hidden = true;
    ui.root.classList.remove('is-open');
    ui.fab.setAttribute('aria-expanded', 'false');
    stopPolling();
    if (returnFocus || hadFocus) ui.fab.focus();
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
    var status = el('div', { class: 'pd-status', id: 'pd-status', role: 'status', 'aria-live': 'polite' });
    var panel = el('section', { id: 'pos-demo-panel', class: 'pd-panel', role: 'dialog', 'aria-modal': 'false', 'aria-labelledby': 'pd-panel-title', tabindex: '-1', hidden: true },
      el('header', { class: 'pd-panel-head' },
        el('div', null,
          el('h2', { id: 'pd-panel-title', class: 'pd-panel-title', text: 'Демо-панель' }),
          el('p', { class: 'pd-muted pd-panel-sub', text: 'Тестовые данные · 1С, SMS и банк — имитаторы' })),
        el('button', { type: 'button', class: 'pd-icon-btn', id: 'pd-close', 'aria-label': 'Закрыть демо-панель', title: 'Закрыть (Esc)', text: '✕', on: { click: function () { closePanel(true); } } })),
      el('div', { class: 'pd-panel-body' },
        section('login', 'Как войти', true, buildLogin()),
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
