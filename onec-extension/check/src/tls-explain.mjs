// Русские объяснения ошибок TLS и сети (§2.6).

export function explainNetError(err, { host, port } = {}) {
  const code = err?.code || err?.cause?.code || '';
  const where = host ? `${host}${port ? ':' + port : ''}` : 'сервер';
  switch (code) {
    case 'DEPTH_ZERO_SELF_SIGNED_CERT':
    case 'SELF_SIGNED_CERT_IN_CHAIN':
    case 'UNABLE_TO_GET_ISSUER_CERT_LOCALLY':
    case 'UNABLE_TO_GET_ISSUER_CERT':
    case 'UNABLE_TO_VERIFY_LEAF_SIGNATURE':
      return {
        code, kind: 'tls',
        text: `сертификат ${where} не от доверенного центра (${code}); укажите корневой сертификат вашего центра: --ca файл.pem`,
      };
    case 'ERR_TLS_CERT_ALTNAME_INVALID': {
      const m = /cert'?s altnames:\s*(.*)$/i.exec(err.reason || err.message || '');
      const names = m ? m[1] : (err.altNames || err.cert?.subjectaltname || 'см. сертификат');
      return {
        code, kind: 'tls',
        text: `сертификат выдан на другое имя (${names}), а адрес — ${host}; сертификат публикации должен быть на тот адрес, по которому обращается сервер POS (Требования §4.2)`,
      };
    }
    case 'CERT_HAS_EXPIRED':
      return { code, kind: 'tls', text: `срок действия сертификата ${where} истёк — замените сертификат публикации` };
    case 'CERT_NOT_YET_VALID':
      return { code, kind: 'tls', text: `сертификат ${where} ещё не действует — проверьте дату на сервере и на этом компьютере` };
    case 'ERR_SSL_UNSUPPORTED_PROTOCOL':
    case 'ERR_SSL_TLSV1_ALERT_PROTOCOL_VERSION':
    case 'ERR_SSL_WRONG_VERSION_NUMBER':
      return { code, kind: 'tls', text: `TLS-соединение с ${where} не установлено (${code}): нужен TLS 1.2 или новее; возможно, по этому порту работает HTTP, а не HTTPS` };
    case 'ECONNREFUSED':
      return { code, kind: 'net', text: `нет связи: ${where} отказал в соединении (ECONNREFUSED) — по этому адресу и порту ничего не слушает: проверьте адрес и порт, работает ли веб-сервер, разрешена ли публикация с этого компьютера (до сертификата и TLS дело не дошло)` };
    case 'ENOTFOUND':
    case 'EAI_AGAIN':
      return { code, kind: 'net', text: `нет связи: имя ${host} не найдено (${code}) — проверьте адрес публикации и DNS` };
    case 'ETIMEDOUT':
    case 'CONNECT_TIMEOUT':
      return { code: code || 'CONNECT_TIMEOUT', kind: 'net', text: `нет связи: ${where} не ответил за отведённое время на соединение — проверьте адрес, сеть, что публикация разрешена с этого компьютера (Требования §4.2: доступ — только с адреса сервера POS)` };
    case 'ECONNRESET':
      return { code, kind: 'net', text: `соединение с ${where} сброшено (ECONNRESET) — сервер или сетевой экран закрыл соединение` };
    case 'EHOSTUNREACH':
    case 'ENETUNREACH':
      return { code, kind: 'net', text: `нет связи: сеть до ${where} недоступна (${code})` };
    case 'RESPONSE_TIMEOUT':
      return { code, kind: 'timeout', text: `нет ответа за отведённое время` };
    case 'CONTENT_LENGTH_MISMATCH':
      return { code, kind: 'net', text: `Content-Length не совпадает с размером тела: обещано ${err.declared} байт, пришло ${err.received} — ответ оборван` };
    case 'BODY_TOO_LARGE':
      return { code, kind: 'net', text: 'ответ больше допустимого размера — чтение прервано' };
    default:
      return { code: code || 'ERROR', kind: 'net', text: `ошибка связи с ${where}: ${code || err?.message || 'неизвестная ошибка'}` };
  }
}
