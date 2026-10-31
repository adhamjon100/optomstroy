/* Оптомстрой POS · веб-демо · demo-closed.html: текст по причине и возврат демо без лишней записи в истории. */
(function () {
  'use strict';
  var reason = '';
  try {
    reason = new URL(window.location.href).searchParams.get('reason') || '';
  } catch (e) {
    reason = '';
  }
  var text = document.getElementById('pd-closed-text');
  if (text && (reason === 'stolen' || reason === 'generation')) {
    text.textContent = 'Пока эта вкладка не отвечала, демо открыли в другой вкладке этого браузера. ' +
      'Чтобы данные не перепутались, здесь демо остановлено. Эту вкладку можно закрыть.';
  }
  var back = document.getElementById('pd-closed-back');
  if (back) {
    back.addEventListener('click', function (ev) {
      ev.preventDefault();
      window.location.replace(back.getAttribute('href'));
    });
  }
})();
