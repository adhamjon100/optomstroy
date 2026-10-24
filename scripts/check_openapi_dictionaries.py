#!/usr/bin/env python3
"""check_openapi_dictionaries.py — сверка корня OpenAPI (contracts/openapi/parts/00_root.yaml) со словарями ТЗ.

B-AR-10 (в) (docs/reviews/B_architecture_review.md): перенос в репозиторий скрипта сверки части 1 RM-B-003
(contracts/openapi/NOTES.md §6 п.2). Без сети, детерминированно. Проверяет:
  1. ProblemCode = таблица 08 §2.4; enum `code` скелета 08 §8 ⊆ ProblemCode; WarningCode ∩ ProblemCode = {QR_UNAVAILABLE};
  2. PermissionCode = 11 §4.3 (состав и порядок);
  3. enum-схемы = 07 §6.1 и CHECK-перечни 07 §6.1.1 (владелец значений — 07);
  4. StepUpOperation = 08 §2.12;
  5. корень документа: теги = 08 §8, openapi 3.0.3, paths {}, security, Limit ≤ 200, общие заголовки и параметры;
     все $ref корня разрешаются в СОБРАННОМ документе (корень может ссылаться на схему модуля, например
     Customer.discounts → CustomersDiscountsResponse, B-AR-06); camelCase полей, PascalCase схем;
  6. примеры 08 §3.7 валидны по Customer и ролевым представлениям CustomerView*, негативные случаи отвергаются.

Запуск: python -I -X utf8 scripts/check_openapi_dictionaries.py   (после scripts/build_openapi.py)
Код выхода: 0 — расхождений нет; 1 — есть расхождения.
"""
import json
import re
import sys
from pathlib import Path

import jsonschema
import yaml

ROOT = str(Path(__file__).resolve().parent.parent)
SRC = ROOT + '/contracts/openapi/parts/00_root.yaml'
BUILT = ROOT + '/contracts/openapi/pos-api.v1.yaml'
raw = open(SRC, encoding='utf-8').read()
root = yaml.safe_load(raw)
built = yaml.safe_load(open(BUILT, encoding='utf-8').read())
d08 = open(ROOT + '/docs/specification/08_API_SPECIFICATION.md', encoding='utf-8').read().splitlines()
d07 = open(ROOT + '/docs/specification/07_DATA_MODEL.md', encoding='utf-8').read().splitlines()
d11 = open(ROOT + '/docs/specification/11_SECURITY_PRIVACY.md', encoding='utf-8').read().splitlines()
S = root['components']['schemas']
fails = []


def check(name, cond, msg=''):
    print(('OK   ' if cond else 'FAIL ') + name + (('  ' + msg) if msg and not cond else ''))
    if not cond:
        fails.append(name)


# 1. ProblemCode == таблица 08 §2.4
i0 = next(i for i, l in enumerate(d08) if l.startswith('**Полный перечень кодов'))
codes = []
for l in d08[i0:i0 + 80]:
    if l.startswith('Правило приоритета'):
        break
    m = re.match(r'^\| `([A-Z_]+)`', l)
    if m:
        codes.append(m.group(1))
pc = S['ProblemCode']['enum']
check('ProblemCode = 08 §2.4 (%d кодов в таблице, %d в enum)' % (len(codes), len(pc)),
      sorted(codes) == sorted(pc) and len(pc) == len(set(pc)), str(set(codes) ^ set(pc)))
# 1b. перечень скелета 08 §8 входит в ProblemCode
S8 = next(i for i, l in enumerate(d08) if l.startswith('## 8. '))
sk = next(i for i, l in enumerate(d08) if i > S8 and l.strip() == 'code:')
blob = ' '.join(l.split('#')[0] for l in d08[sk:sk + 12])
sk_codes = set(re.findall(r'\b[A-Z][A-Z_]{3,}\b', blob))
check('08 §8 enum ⊆ ProblemCode (%d)' % len(sk_codes), sk_codes <= set(pc), str(sk_codes - set(pc)))
check('WarningCode ∩ ProblemCode без QR_UNAVAILABLE пусто', set(S['WarningCode']['enum']) & set(pc) == {'QR_UNAVAILABLE'})

# 2. PermissionCode == 11 §4.3 (порядок и состав)
perm = [m.group(1) for l in d11 if (m := re.match(r'^\| \d+a? \| `([a-z_.]+)` \|', l))]
check('PermissionCode = 11 §4.3 (%d кодов)' % len(perm), perm == S['PermissionCode']['enum'],
      str(set(perm) ^ set(S['PermissionCode']['enum'])))

# 3. enum-ы = 07 §6.1
m07 = {}
s61 = next(i for i, l in enumerate(d07) if l.startswith('### 6.1. '))
s611 = next(i for i, l in enumerate(d07) if l.startswith('#### 6.1.1.'))
for l in d07[s61:s611]:  # только таблица 07 §6.1
    cells = re.split(r'(?<!\\)\|', l)
    if len(cells) > 3 and re.match(r'^ `[a-z_]+`', cells[1]):
        name = re.match(r'^ `([a-z_]+)`', cells[1]).group(1)
        q = re.match(r'^ `([^`]+)`', cells[2])
        if q:
            m07[name] = [v.strip() for v in q.group(1).split('\\|')]
mapping = {
    'UserKind': 'user_kind', 'UserStatus': 'user_status', 'RoleCode': 'role_code',
    'CustomerLinkStatus': 'customer_link_status', 'CartStatus': 'cart_status', 'OrderStatus': 'order_status',
    'DeliveryMethod': 'delivery_method', 'ReceiverKind': 'receiver_kind', 'PaymentMethod': 'payment_method',
    'PaymentStatus': 'payment_status', 'ReturnRequestStatus': 'return_request_status',
    'TransactionKind': 'transaction_kind', 'SyncEntity': 'sync_entity', 'SyncMode': 'sync_mode',
    'SyncRunStatus': 'sync_run_status', 'OutboxStatus': 'outbox_status', 'NotificationKind': 'notification_kind',
    'InvitationStatus': 'invitation_status', 'DevicePlatform': 'device_platform', 'SessionKind': 'session_kind',
    'StepUpMethod': 'step_up_method', 'OtpPurpose': 'otp_purpose', 'ConsentKind': 'consent_kind',
    'BarcodeType': 'barcode_type', 'CustomerSource': 'customer_source', 'CustomerType': 'customer_type',
    'CustomerOnecStatus': 'customer_onec_status', 'ContactKind': 'contact_kind', 'LinkMatchMethod': 'link_match_method',
    'DiscountSource': 'discount_source', 'DiscountKind': 'discount_kind', 'StatusChangeSource': 'status_change_source',
    'TransactionSource': 'transaction_source', 'ReturnReason': 'return_reason', 'SyncTrigger': 'sync_trigger',
    'OutboxAggregate': 'outbox_aggregate', 'PrintDocumentKind': 'print_document_kind', 'OnecSyncState': 'onec_sync_state'}
for k, t in mapping.items():
    exp = m07.get(t)
    check('%s = 07 §6.1 %s' % (k, t), exp is not None and exp == S[k]['enum'], 'ожидалось %s, есть %s' % (exp, S[k]['enum']))
checks_0711 = {
    'ReviewReason': 'payments.review_reason', 'CancelReasonCode': 'orders.cancel_reason_code',
    'RefundIntent': 'orders.refund_intent', 'ReceivableDocumentKind': 'receivable_documents.kind',
    'ReceivableDocumentStatus': 'receivable_documents.status', 'PrintPaper': 'print_jobs.paper',
    'NotificationSeverity': 'notifications.severity', 'QrProviderMode': 'payments.qr_provider',
    'OutboxOperation': 'onec_outbox.operation', 'CustomerStockDisplay': 'app_settings.customer_stock_display'}
for k, f in checks_0711.items():
    row = next((l for l in d07 if l.startswith('| `%s`' % f) or l.startswith('| значение ключа `%s`' % f)), None)
    vals = re.findall(r'`([a-z0-9_]+)`', row.split('|')[2].split('(')[0]) if row else None
    check('%s = 07 §6.1.1 %s' % (k, f), vals == S[k]['enum'], 'ожидалось %s, есть %s' % (vals, S[k]['enum']))
sec = next(l for l in d07 if l.startswith('| `sync_errors.error_code`'))
check('SyncErrorCode = 07 §6.1.1 (14)', sorted(re.findall(r'`([A-Z_]+)`', sec.split('|')[2])) == sorted(S['SyncErrorCode']['enum']))
inv = next(l for l in d07 if l.startswith('| `user_invitations.role`'))
check('Invitation.roles = 07 §6.1.1 user_invitations.role',
      re.findall(r'`([a-z_]+)`', inv.split('|')[2]) == S['Invitation']['properties']['roles']['items']['enum'])

# 4. StepUpOperation = таблица 08 §2.12
t0 = next(i for i, l in enumerate(d08) if l.startswith('| `operation` | `scope`'))
ops = []
for l in d08[t0 + 2:t0 + 12]:
    if not l.startswith('|'):
        break
    ops += re.findall(r'`([a-z_.]+)`', l.split('|')[1])
check('StepUpOperation = 08 §2.12 (%d)' % len(ops), sorted(ops) == sorted(S['StepUpOperation']['enum']),
      str(set(ops) ^ set(S['StepUpOperation']['enum'])))
check('StepUpOperation ⊆ profile.*/session.* ∪ PermissionCode',
      all(o.startswith(('profile.', 'session.')) or o in perm for o in S['StepUpOperation']['enum']))

# 5. корень документа
t8 = next(i for i, l in enumerate(d08) if i > S8 and l.rstrip() == 'tags:')
sk_tags = []
for l in d08[t8 + 1:]:
    if not l.startswith('  - name:'):
        break
    sk_tags.append(l.split('- name:')[1].strip())
check('tags = 08 §8 (%d)' % len(sk_tags), sk_tags == [t['name'] for t in root['tags']])
check('openapi = 3.0.3', root['openapi'] == '3.0.3')
check('paths = {}', root['paths'] == {})
check('security по умолчанию = bearerAuth', root['security'] == [{'bearerAuth': []}])
check('Limit.maximum = 200', root['components']['parameters']['Limit']['schema']['maximum'] == 200)
need_headers = {'XRequestId', 'RetryAfter', 'IdempotentReplayed', 'XDataAsOf', 'XMinAppVersion', 'XRecommendedAppVersion', 'ETag'}
check('заголовки ответов 08 §2.3', need_headers <= set(root['components']['headers']))
need_params = {'DeviceId', 'AppVersion', 'Platform', 'RequestId', 'IdempotencyKey', 'StepUpToken', 'IfNoneMatch', 'Limit', 'Cursor'}
check('параметры-заголовки 08 §2.3', need_params <= set(root['components']['parameters']))
refs = re.findall(r'"#/components/(\w+)/(\w+)"', raw)
bad = [r for r in refs if r[1] not in built['components'].get(r[0], {})]
check('все $ref корня разрешаются в собранном документе (%d)' % len(refs), not bad, str(bad))
ext = sorted({r[1] for r in refs if r[1] not in root['components'].get(r[0], {})})
if ext:
    print('info ссылки корня на схемы модулей: ' + ', '.join(ext))
props_bad = [(n, p) for n, sc in S.items() for p in (sc.get('properties') or {}) if not re.match(r'^[a-z][A-Za-z0-9]*$', p)]
check('поля — camelCase', not props_bad, str(props_bad))
names_bad = [n for n in S if not re.match(r'^[A-Z][A-Za-z0-9]*$', n)]
check('имена схем — PascalCase', not names_bad, str(names_bad))


# 6. примеры 08 валидны по схемам (OAS 3.0 nullable → JSON Schema)
def conv(x):
    if isinstance(x, dict):
        y = {k: conv(v) for k, v in x.items()
             if not k.startswith('x-') and k not in ('example', 'nullable', 'readOnly', 'discriminator')}
        if x.get('nullable'):
            y = {'anyOf': [{'type': 'null'}, y]}
        return y
    if isinstance(x, list):
        return [conv(v) for v in x]
    return x


js = {'components': {'schemas': conv(built['components']['schemas'])}}


def validator(name):
    return jsonschema.Draft7Validator({'$ref': '#/components/schemas/' + name, **js}, format_checker=jsonschema.FormatChecker())


def validate(label, name, inst):
    errs = sorted(validator(name).iter_errors(inst), key=str)
    check('пример валиден: %s → %s' % (label, name), not errs, '; '.join(e.message[:140] for e in errs[:3]))


def grab_json(start_marker):
    i = next(i for i, l in enumerate(d08) if l.startswith(start_marker)) + 1
    while not d08[i].startswith('```json'):
        i += 1
    j = i + 1
    buf = []
    while not d08[j].startswith('```'):
        buf.append(d08[j])
        j += 1
    return json.loads('\n'.join(buf))


seller = grab_json('Пример `Customer` для роли `seller`')
cashier = grab_json('Пример того же `Customer` для роли `cashier`')
validate('08 §3.7 seller', 'CustomerViewSeller', seller)
validate('08 §3.7 seller', 'Customer', seller)
validate('08 §3.7 cashier', 'CustomerViewCashier', cashier)
validate('08 §3.7 cashier', 'Customer', cashier)
validate('08 §3.1', 'Money', {'amount': '16007.50', 'currency': 'KGS'})
check('негатив: CustomerViewSeller отвергает inn', not validator('CustomerViewSeller').is_valid(dict(seller, inn='1')))
check('негатив: CustomerViewCashier отвергает phoneMasked', not validator('CustomerViewCashier').is_valid(dict(cashier, phoneMasked='x')))
check('негатив: Money отвергает "16007.5"', not validator('Money').is_valid({'amount': '16007.5', 'currency': 'KGS'}))
check('негатив: Money отвергает USD', not validator('Money').is_valid({'amount': '1.00', 'currency': 'USD'}))
check('негатив: Quantity отвергает лишнее поле price', not validator('Quantity').is_valid(
    {'value': '6', 'unitId': '0192e0b2-0000-7000-8000-000000000001', 'price': '1.00'}))
check('Problem: минимальный валиден', validator('Problem').is_valid(
    {'type': 'https://api.example/problems/not-found', 'title': 'Не найдено', 'status': 404, 'code': 'NOT_FOUND', 'requestId': 'r'}))
check('негатив: Problem отвергает код предупреждения STALE_DATA', not validator('Problem').is_valid(
    {'type': 'https://api.example/p', 'title': 't', 'status': 500, 'code': 'STALE_DATA', 'requestId': 'r'}))
check('Percent: "100.00" валиден, "100.5" нет', validator('Percent').is_valid('100.00') and not validator('Percent').is_valid('100.5'))
check('PhoneE164: +996700000001 валиден, +99670000000 нет',
      validator('PhoneE164').is_valid('+996700000001') and not validator('PhoneE164').is_valid('+99670000000'))


# 7. Исправления архитектурной проверки этапа B (схемы собранного документа)
validate('08 §4.11.5 not_in_onec (B-AR-06)', 'Receivable',
         {'customerId': '0192e0b2-0000-7000-8000-000000000001', 'balance': None, 'asOf': None, 'reason': 'not_in_onec'})
check('негатив: Receivable отвергает reason вне словаря',
      not validator('Receivable').is_valid({'customerId': '0192e0b2-0000-7000-8000-000000000001', 'balance': None,
                                            'asOf': None, 'reason': 'unknown'}))
check('негатив: PUT /admin/users/{id}/roles — две роли отвергаются схемой (B-AR-02)',
      not validator('AdminUsersRolesSetRequest').is_valid({'roles': ['cashier', 'seller'], 'rowVersion': 1}))
check('PUT /admin/users/{id}/roles — одна роль валидна',
      validator('AdminUsersRolesSetRequest').is_valid({'roles': ['cashier'], 'rowVersion': 1}))
check('негатив: POST /admin/users — две роли отвергаются схемой (B-AR-02)', not validator('AdminUsersCreateRequest').is_valid(
    {'phone': '+996700000001', 'fullName': 'Тест Тестов', 'roles': ['seller', 'cashier']}))
validate('удаление штрихкода C-2 (B-AR-05)', 'IntegrationsOnecChangeObject',
         {'type': 'ObjectDeletion', 'objectType': 'InformationRegister_ШтрихкодыНоменклатуры', 'ref': '4601234567890'})
check('негатив: IntegrationsOnecChangeObject.ref > 150 символов', not validator('IntegrationsOnecChangeObject').is_valid(
    {'type': 'ObjectDeletion', 'objectType': 'InformationRegister_ШтрихкодыНоменклатуры', 'ref': '7' * 151}))
_csr = built['components']['schemas']['CatalogSyncResponse']
_ces = _csr.get('x-entity-schema') or {}
check('CatalogSyncResponse.x-entity-schema = anyOf items (B-AR-14)',
      sorted(_ces.values()) == sorted(x['$ref'] for x in _csr['properties']['items']['items']['anyOf'])
      and all(v.split('/')[-1] in built['components']['schemas'] for v in _ces.values()))
check('Profile.birthYear ≥ 1920, как в телах запросов (B-AR-16)', S['Profile']['properties']['birthYear'].get('minimum') == 1920)

print('\nИТОГ:', 'ошибок нет' if not fails else '%d ошибок' % len(fails))
sys.exit(1 if fails else 0)
