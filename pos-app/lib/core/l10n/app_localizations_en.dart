// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get admin_invites_again => 'Пригласить снова';

  @override
  String get admin_invites_applied_existing => 'Роль назначена существующему аккаунту';

  @override
  String admin_invites_created(String phone) {
    return 'Приглашение создано. Сотрудник может войти по номеру $phone';
  }

  @override
  String get admin_invites_empty => 'Приглашений нет';

  @override
  String get admin_invites_error_customer_account =>
      'Номер принадлежит клиенту. Чтобы сделать его сотрудником, назначьте роль в карточке пользователя';

  @override
  String get admin_invites_error_expiry => 'Срок действия — от 1 до 90 дней';

  @override
  String get admin_invites_error_phone => 'Введите 9 цифр номера';

  @override
  String get admin_invites_error_registered =>
      'Номер уже принадлежит активному сотруднику. Измените его роль в карточке';

  @override
  String get admin_invites_error_role => 'Выберите роль';

  @override
  String get admin_invites_expires_label => 'Действует до';

  @override
  String get admin_invites_fullname_label => 'ФИО';

  @override
  String get admin_invites_no_sms_hint =>
      'SMS приглашённому не отправляется. Сообщите сотруднику, что вход выполняется по номеру телефона';

  @override
  String get admin_invites_phone_label => 'Телефон';

  @override
  String get admin_invites_revoke => 'Отозвать';

  @override
  String get admin_invites_send => 'Отправить приглашение';

  @override
  String get admin_invites_staff_only_hint =>
      'Сотрудники не регистрируются сами: сотрудник войдёт по этому номеру после приглашения';

  @override
  String get admin_invites_title => 'Приглашение сотрудника';

  @override
  String get admin_invites_updated => 'Приглашение для этого номера обновлено';

  @override
  String get admin_links_confirm => 'Подтвердить';

  @override
  String get admin_links_empty => 'Запросов на привязку нет';

  @override
  String get admin_links_error_conflict => 'У клиента уже есть подтверждённая привязка';

  @override
  String get admin_links_reject => 'Отклонить';

  @override
  String get admin_links_reject_all => 'Отклонить все';

  @override
  String admin_settings_changed_by(String name, String time) {
    return 'Изменено $time · $name';
  }

  @override
  String get admin_settings_conflict_banner => 'Настройки изменены другим администратором';

  @override
  String get admin_settings_customer_mode_disable_confirm =>
      'Новые клиенты не смогут регистрироваться; у существующих клиентов главный экран станет недоступен';

  @override
  String get admin_settings_customer_mode_enable_confirm =>
      'Клиенты смогут регистрироваться по телефону, видеть каталог с ценами своего вида цены и оформлять заявки-заказы';

  @override
  String admin_settings_customer_mode_env(String value) {
    return 'По умолчанию на сервере: $value';
  }

  @override
  String get admin_settings_customer_mode_label => 'Режим клиента (самообслуживание)';

  @override
  String get admin_settings_diff_title => 'Проверьте изменения';

  @override
  String get admin_settings_env_hint => 'Задаётся на сервере. Изменение — через администратора сервера';

  @override
  String get admin_settings_history_link => 'История изменений';

  @override
  String get admin_settings_idle_error => 'Не больше 30 минут для сотрудников';

  @override
  String get admin_settings_interval_error => 'От 2 до 1440 минут';

  @override
  String admin_settings_interval_group_hint(String entities, String value) {
    return 'Сущности: $entities. По умолчанию на сервере: $value';
  }

  @override
  String get admin_settings_limit_error => 'Введите значение от 0 до 100 % с шагом 0,5';

  @override
  String get admin_settings_limit_override => 'Может подтверждать сверх лимита';

  @override
  String admin_settings_limit_was(String value) {
    return 'было $value %';
  }

  @override
  String get admin_settings_limits_override_warning => 'Лимит подтверждающей роли ниже лимита подчинённой роли';

  @override
  String get admin_settings_limits_saved => 'Лимиты скидок сохранены. Применятся в течение минуты';

  @override
  String get admin_settings_low_stock_error => 'Введите целое число не меньше 0';

  @override
  String admin_settings_min_version_confirm(String version) {
    return 'Устройства с версией ниже $version перестанут работать до обновления';
  }

  @override
  String get admin_settings_onec_rules_banner =>
      'Лимиты должны совпадать с «Правилами продаж» 1С, иначе 1С отклонит заказ';

  @override
  String get admin_settings_otp_ttl_error => 'От 180 до 600 секунд';

  @override
  String get admin_settings_readonly_banner => 'Просмотр. Изменять настройки может администратор';

  @override
  String get admin_settings_receivables_error => 'От 5 до 1440 минут';

  @override
  String get admin_settings_saved => 'Настройки сохранены';

  @override
  String get admin_settings_section_auth => 'Вход и сессии';

  @override
  String get admin_settings_section_carts => 'Корзины';

  @override
  String get admin_settings_section_debts => 'Долги';

  @override
  String get admin_settings_section_limits => 'Лимиты скидок';

  @override
  String get admin_settings_section_payments => 'Оплата и возвраты';

  @override
  String get admin_settings_section_print => 'Печать';

  @override
  String get admin_settings_section_registration => 'Регистрация и режим клиента';

  @override
  String get admin_settings_section_stock => 'Склад и остатки';

  @override
  String get admin_settings_section_sync => 'Синхронизация';

  @override
  String get admin_settings_section_texts => 'Тексты и контакты';

  @override
  String get admin_settings_section_versions => 'Версии приложения';

  @override
  String get admin_settings_title => 'Настройки системы';

  @override
  String admin_settings_unsaved_confirm(String name) {
    return 'Сохранить изменения в секции $name?';
  }

  @override
  String get admin_settings_version_error => 'Формат версии: 1.4.0';

  @override
  String get admin_settings_version_order_error => 'Рекомендуемая версия не может быть ниже минимальной';

  @override
  String get admin_users_actions_section => 'Действия';

  @override
  String get admin_users_activate => 'Активировать';

  @override
  String get admin_users_activated => 'Пользователь активирован';

  @override
  String get admin_users_audit_link => 'Аудит пользователя';

  @override
  String get admin_users_block => 'Заблокировать';

  @override
  String admin_users_block_confirm(String name) {
    return 'Заблокировать $name? Все сеансы будут завершены, приглашение аннулировано';
  }

  @override
  String get admin_users_conflict_banner => 'Данные изменены другим администратором';

  @override
  String admin_users_devices(int count, String time) {
    return 'Устройств: $count · последний вход $time';
  }

  @override
  String get admin_users_effect_hint =>
      'Права изменятся в течение минуты; при понижении прав все сеансы пользователя будут завершены';

  @override
  String get admin_users_emergency_close_confirm => 'Закрыть? Код больше не будет показан';

  @override
  String get admin_users_emergency_code => 'Выдать аварийный код входа';

  @override
  String get admin_users_emergency_hint =>
      'Передайте код лично или голосом после проверки личности. Не отправляйте код через мессенджеры';

  @override
  String get admin_users_emergency_issue => 'Выдать код';

  @override
  String get admin_users_emergency_not_allowed => 'Код можно выдать только активному сотруднику';

  @override
  String get admin_users_emergency_rate_limited => 'Лимит аварийных кодов на сегодня исчерпан';

  @override
  String get admin_users_emergency_reason_other => 'Иное';

  @override
  String get admin_users_emergency_reason_sim => 'Утерян доступ к SIM-карте';

  @override
  String get admin_users_emergency_reason_sms => 'SMS не доходят';

  @override
  String admin_users_emergency_shown(String code, String time) {
    return 'Код $code действует до $time. Он показывается один раз';
  }

  @override
  String admin_users_emergency_title(String name) {
    return 'Аварийный код входа для $name';
  }

  @override
  String get admin_users_empty => 'Пользователи не найдены';

  @override
  String get admin_users_error_self_block => 'Нельзя заблокировать свою учётную запись';

  @override
  String get admin_users_error_self_demotion => 'Нельзя снять с себя роль администратора';

  @override
  String get admin_users_filter_all => 'Все';

  @override
  String get admin_users_filter_role => 'Роль';

  @override
  String get admin_users_filter_status => 'Статус';

  @override
  String get admin_users_invite_button => '+ Пригласить';

  @override
  String get admin_users_limit_by_role => 'По роли';

  @override
  String get admin_users_limit_error => 'Лимит от 0 до 100 %';

  @override
  String get admin_users_limit_label => 'Индивидуальный лимит скидки';

  @override
  String get admin_users_owner_hint => 'Роль «Руководитель» назначает только руководитель';

  @override
  String get admin_users_pin_reset => 'PIN сброшен';

  @override
  String get admin_users_reason_error => 'Укажите причину (не менее 5 символов)';

  @override
  String get admin_users_reason_label => 'Причина';

  @override
  String get admin_users_reset_pin => 'Сбросить PIN';

  @override
  String get admin_users_reset_pin_confirm => 'PIN будет сброшен. Сотрудник задаст новый PIN после входа по SMS';

  @override
  String get admin_users_revoke_sessions => 'Завершить все сессии';

  @override
  String admin_users_role_diff(String name, String newValue, String old) {
    return 'Роль $name: $old → $newValue';
  }

  @override
  String get admin_users_role_save => 'Сохранить роль';

  @override
  String get admin_users_role_saved => 'Роль изменена. Права обновятся в течение минуты';

  @override
  String get admin_users_role_section => 'Роль';

  @override
  String get admin_users_search_hint => 'Имя или телефон';

  @override
  String get admin_users_sessions_revoked => 'Все сеансы пользователя завершены';

  @override
  String get admin_users_sessions_section => 'Устройства и сессии';

  @override
  String get admin_users_source_invitation => 'По приглашению';

  @override
  String get admin_users_source_self => 'Самостоятельная регистрация';

  @override
  String admin_users_tab_invitations(int count) {
    return 'Приглашения · $count';
  }

  @override
  String admin_users_tab_links(int count) {
    return 'Привязки клиентов · $count';
  }

  @override
  String admin_users_tab_users(int count) {
    return 'Пользователи · $count';
  }

  @override
  String get admin_users_title => 'Пользователи';

  @override
  String get admin_users_unblock => 'Разблокировать';

  @override
  String get admin_users_warehouses => 'Склады';

  @override
  String get audit_action_auth_pin_reset => 'Сброшен PIN сотрудника';

  @override
  String get audit_action_credit_sale_approved => 'Разрешена продажа в долг';

  @override
  String get audit_action_customer_finance_view => 'Просмотр детализации долга';

  @override
  String get audit_action_discount_limits_changed => 'Изменены лимиты скидок';

  @override
  String get audit_action_discount_over_limit_approved => 'Подтверждена скидка сверх лимита';

  @override
  String get audit_action_order_cancel_requested => 'Запрошена отмена заказа';

  @override
  String get audit_action_payment_manual_qr_confirmed => 'Оплата QR подтверждена вручную';

  @override
  String get audit_action_settings_changed => 'Изменены настройки';

  @override
  String get audit_action_sync_manual_started => 'Ручной запуск синхронизации';

  @override
  String get audit_action_sync_prices_applied => 'Применены цены из 1С';

  @override
  String get audit_action_sync_stock_applied => 'Применены остатки из 1С';

  @override
  String audit_action_unknown(String code) {
    return 'Событие $code';
  }

  @override
  String get audit_action_user_blocked => 'Пользователь заблокирован';

  @override
  String get audit_action_user_role_changed => 'Изменены роли';

  @override
  String get audit_action_user_unblocked => 'Пользователь разблокирован';

  @override
  String get audit_after => 'Стало';

  @override
  String get audit_before => 'Было';

  @override
  String get audit_copied => 'Скопировано';

  @override
  String get audit_empty_action => 'Изменить период';

  @override
  String get audit_empty_title => 'Записей за период нет';

  @override
  String get audit_export_r2_tooltip => 'Экспорт будет доступен в следующей версии';

  @override
  String get audit_filter_action => 'Действие';

  @override
  String get audit_filter_object => 'Объект';

  @override
  String get audit_filter_result => 'Результат';

  @override
  String get audit_filter_user => 'Пользователь';

  @override
  String audit_filters_button(int count) {
    return 'Фильтры ($count)';
  }

  @override
  String get audit_masked_value => 'скрыто';

  @override
  String get audit_period_error => 'Период не больше 366 дней';

  @override
  String get audit_reason => 'Причина';

  @override
  String get audit_result_denied => 'Отказано';

  @override
  String get audit_result_error => 'Ошибка';

  @override
  String get audit_result_ok => 'Успешно';

  @override
  String get audit_step_up_method => 'Подтверждение';

  @override
  String get audit_title => 'Журнал аудита';

  @override
  String get auth_bio_enable_later => 'Включить биометрию можно позже в настройках';

  @override
  String get auth_bio_enable_stepup_hint => 'Подтвердите PIN-кодом, чтобы включить вход по биометрии';

  @override
  String get auth_bio_invalidated =>
      'Биометрия на устройстве изменилась. Войдите по номеру телефона и включите вход заново';

  @override
  String get auth_bio_lockout => 'Биометрия временно заблокирована. Введите PIN или войдите по номеру';

  @override
  String get auth_bio_offer_enable => 'Включить';

  @override
  String get auth_bio_offer_later => 'Не сейчас';

  @override
  String get auth_bio_offer_title => 'Входить по биометрии?';

  @override
  String get auth_blocked_message => 'Доступ закрыт. Обратитесь к администратору магазина';

  @override
  String get auth_brand_feature_1_body => 'Найдите товар за секунды';

  @override
  String get auth_brand_feature_1_title => 'Быстрый поиск товаров';

  @override
  String get auth_brand_feature_2_body => 'По всем складам';

  @override
  String get auth_brand_feature_2_title => 'Актуальные остатки';

  @override
  String get auth_brand_feature_3_body => 'Чеки, накладные, счета на оплату';

  @override
  String get auth_brand_feature_3_title => 'Заказы и документы';

  @override
  String get auth_brand_feature_4_body => 'Интерфейс создан для продавцов';

  @override
  String get auth_brand_feature_4_title => 'Удобно и просто';

  @override
  String get auth_brand_secure => 'Ваши данные защищены';

  @override
  String get auth_brand_subtitle => 'Рабочее место продавца';

  @override
  String get auth_entry_bio_invalidated =>
      'Биометрия на устройстве изменилась. Войдите по номеру телефона и включите вход заново';

  @override
  String get auth_entry_device_mismatch => 'Код запрошен с другого устройства. Запросите новый код';

  @override
  String get auth_entry_phone_registered => 'Этот номер уже зарегистрирован. Войдите по коду из SMS';

  @override
  String get auth_entry_pin_locked => 'PIN заблокирован. Войдите по коду из SMS';

  @override
  String get auth_entry_pin_reset => 'Войдите по коду из SMS, чтобы задать новый PIN';

  @override
  String get auth_entry_registration_cancelled => 'Регистрация прервана. Данные сохранятся на этом устройстве 15 минут';

  @override
  String get auth_entry_registration_expired =>
      'Время регистрации истекло. Подтвердите номер ещё раз — введённые данные сохранятся';

  @override
  String get auth_entry_registration_resume => 'Продолжите регистрацию: подтвердите номер кодом из SMS';

  @override
  String get auth_entry_reuse_detected => 'Для безопасности мы завершили все сессии. Войдите снова';

  @override
  String get auth_entry_session_revoked => 'Сессия завершена. Войдите снова';

  @override
  String get auth_error_device_mismatch => 'Код запрошен с другого устройства. Запросите новый код';

  @override
  String get auth_error_network => 'Нет связи с сервером. Проверьте сеть и повторите';

  @override
  String get auth_error_otp_expired => 'Код устарел. Запросите новый';

  @override
  String auth_error_otp_invalid(int n) {
    return 'Неверный код. Осталось попыток: $n';
  }

  @override
  String auth_error_otp_locked(int seconds) {
    return 'Попытки исчерпаны. Запросите новый код через $seconds с';
  }

  @override
  String auth_error_rate_limited(int seconds) {
    return 'Слишком много запросов. Подождите $seconds с';
  }

  @override
  String auth_error_rate_limited_min(int minutes) {
    return 'Слишком много запросов кода на этот номер. Попробуйте через $minutes мин';
  }

  @override
  String get auth_error_revoked => 'Сессия завершена. Войдите снова';

  @override
  String get auth_error_sms_provider => 'Не удалось отправить SMS. Попробуйте позже';

  @override
  String get auth_error_timeout => 'Сервер не ответил. Повторить';

  @override
  String auth_footer_copyright(String year) {
    return '© $year Оптомстрой. Все права защищены.';
  }

  @override
  String get auth_otp_change_phone => 'Изменить номер';

  @override
  String get auth_otp_checking => 'Проверяем код…';

  @override
  String get auth_otp_code_a11y => 'Код из SMS, 6 цифр';

  @override
  String get auth_otp_delivery_failed => 'Не удалось отправить SMS';

  @override
  String get auth_otp_delivery_queued => 'Отправляем SMS…';

  @override
  String get auth_otp_delivery_sent => 'SMS отправлено';

  @override
  String auth_otp_dev_code(String code) {
    return 'dev: код $code';
  }

  @override
  String get auth_otp_fallback_previous => 'Не удалось отправить новый код. Введите код из предыдущего SMS';

  @override
  String get auth_otp_no_sms => 'Не приходит SMS?';

  @override
  String get auth_otp_no_sms_body =>
      'Проверьте номер. SMS может прийти в течение 1–2 минут. Если SMS не приходит, отправьте код повторно или обратитесь в поддержку';

  @override
  String get auth_otp_offline => 'Нет подключения. Код будет проверен, когда появится сеть';

  @override
  String get auth_otp_resend => 'Отправить код повторно';

  @override
  String auth_otp_resend_in(String mmss) {
    return 'Отправить повторно через $mmss';
  }

  @override
  String get auth_otp_resent => 'Код отправлен повторно';

  @override
  String auth_otp_sent_to(String phone) {
    return 'Отправили на $phone';
  }

  @override
  String get auth_otp_submit => 'Подтвердить';

  @override
  String get auth_otp_title => 'Введите код из SMS';

  @override
  String auth_otp_ttl_timer(String mmss) {
    return 'Код действует ещё $mmss';
  }

  @override
  String get auth_otp_verified => 'Код подтверждён';

  @override
  String auth_pending_changes_other_user(String name) {
    return 'У $name есть неотправленные изменения корзины — они будут отправлены при его следующем входе';
  }

  @override
  String get auth_phone_a11y => 'Номер телефона, 9 цифр после +996';

  @override
  String get auth_phone_clear_a11y => 'Очистить номер';

  @override
  String get auth_phone_error_empty => 'Введите номер телефона';

  @override
  String get auth_phone_error_format => 'Введите номер в формате +996 XXX XXX XXX';

  @override
  String get auth_phone_error_invalid => 'Похоже, номер указан неверно. Проверьте и попробуйте снова';

  @override
  String get auth_phone_error_long => 'Слишком много цифр. Проверьте номер';

  @override
  String get auth_phone_error_server_invalid => 'Сервер не принял номер. Проверьте формат +996 XXX XXX XXX';

  @override
  String get auth_phone_error_short => 'Номер должен содержать 9 цифр после +996';

  @override
  String get auth_phone_hint => 'Введите 9 цифр после +996';

  @override
  String auth_phone_hint_remaining(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Ещё $count цифры',
      many: 'Ещё $count цифр',
      few: 'Ещё $count цифры',
      one: 'Ещё $count цифра',
    );
    return '$_temp0';
  }

  @override
  String get auth_phone_label => 'Номер телефона';

  @override
  String get auth_phone_offline_hint => 'Нужна сеть для входа';

  @override
  String get auth_phone_sending => 'Отправляем код…';

  @override
  String get auth_phone_sms_notice =>
      'Для входа мы отправим SMS с одноразовым кодом. Служебные SMS не требуют отдельного согласия; рекламные SMS не отправляются';

  @override
  String get auth_phone_sms_notice_more => 'Подробнее';

  @override
  String get auth_phone_submit => 'Получить код';

  @override
  String auth_phone_submit_wait(String mmss) {
    return 'Получить код через $mmss';
  }

  @override
  String get auth_phone_subtitle => 'Отправим SMS с кодом подтверждения';

  @override
  String get auth_phone_title => 'Вход по номеру телефона';

  @override
  String auth_pin_error_invalid(int n) {
    return 'Неверный PIN. Осталось попыток: $n';
  }

  @override
  String get auth_pin_locked => 'PIN заблокирован после 5 неверных попыток. Войдите по SMS и задайте новый PIN';

  @override
  String get auth_support_call => 'Позвонить';

  @override
  String get auth_support_copy => 'Скопировать номер';

  @override
  String get auth_support_fallback => 'Обратитесь к администратору магазина';

  @override
  String get auth_support_title => 'Техническая поддержка';

  @override
  String cart_a11y_positions(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count позиции',
      many: '$count позиций',
      few: '$count позиции',
      one: '$count позиция',
    );
    return '$_temp0';
  }

  @override
  String get cart_banner_accept_prices => 'Принять новые цены';

  @override
  String get cart_banner_offline => 'Нет сети. Изменения сохранены и будут отправлены';

  @override
  String cart_banner_prices_changed(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count позиции',
      many: '$count позиций',
      few: '$count позиции',
      one: '$count позиция',
    );
    return 'Цены изменились · $_temp0';
  }

  @override
  String cart_banner_restored_from_order(String number, String reason) {
    return 'Корзина восстановлена из заказа № $number: $reason';
  }

  @override
  String cart_banner_stale(String time) {
    return 'Данные от $time — обновляем…';
  }

  @override
  String cart_banner_stock(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count позиции',
      many: '$count позиций',
      few: '$count позиции',
      one: '$count позиция',
    );
    return 'Недостаточно остатка · $_temp0';
  }

  @override
  String cart_clear_dialog_body(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Будет удалено $count позиции',
      many: 'Будет удалено $count позиций',
      few: 'Будет удалено $count позиции',
      one: 'Будет удалена $count позиция',
    );
    return '$_temp0. Отложенные заказы не затрагиваются';
  }

  @override
  String get cart_clear_dialog_confirm => 'Очистить';

  @override
  String get cart_clear_dialog_title => 'Очистить корзину?';

  @override
  String get cart_clear_tooltip => 'Очистить корзину';

  @override
  String cart_counter_units(String positions, String units) {
    return '$positions · $units';
  }

  @override
  String get cart_cta_create_order => 'Создать заказ';

  @override
  String get cart_cta_create_order_hotkey => 'Создать заказ · F9';

  @override
  String get cart_cta_park => 'Отложить заказ';

  @override
  String get cart_cta_park_hotkey => 'Отложить · F8';

  @override
  String get cart_cta_reason_accept_prices => 'Примите новые цены';

  @override
  String get cart_cta_reason_checking => 'Проверяем результат создания заказа…';

  @override
  String get cart_cta_reason_empty => 'Корзина пуста';

  @override
  String get cart_cta_reason_offline => 'Нужна сеть, чтобы создать заказ';

  @override
  String get cart_cta_reason_reduce_qty => 'Уменьшите количество до доступного';

  @override
  String get cart_cta_reason_refreshing => 'Обновляем данные…';

  @override
  String get cart_cta_reason_remove_unavailable => 'Удалите недоступные позиции';

  @override
  String get cart_customer_empty => 'Клиент: не выбран';

  @override
  String get cart_customer_prices_recalculated => 'Цены пересчитаны по условиям клиента';

  @override
  String get cart_customer_submit => 'Отправить заявку';

  @override
  String cart_discount_apply_limit(String limit) {
    return 'Применить $limit %';
  }

  @override
  String cart_discount_approval_dialog_body(String limit) {
    return 'Подтвердить скидку больше $limit % может старший продавец или администратор в своей учётной записи. Отложите заказ — старший откроет его на своём устройстве, либо выйдите, чтобы он вошёл на этом терминале';
  }

  @override
  String get cart_discount_approval_how => 'Как получить подтверждение';

  @override
  String get cart_discount_approval_ok => 'Понятно';

  @override
  String get cart_discount_approval_park => 'Отложить заказ';

  @override
  String cart_discount_approve_button(String percent) {
    return 'Подтвердить скидку $percent %';
  }

  @override
  String cart_discount_approved_by(String name) {
    return 'Подтвердил: $name';
  }

  @override
  String cart_discount_customer_included(String percent) {
    return 'Скидка клиента $percent % уже учтена';
  }

  @override
  String get cart_discount_invalid => 'Введите число от 0 до 100';

  @override
  String get cart_discount_label => 'Скидка';

  @override
  String cart_discount_limit_tooltip(String limit) {
    return 'Ваш лимит: $limit %';
  }

  @override
  String cart_discount_over_limit(String applied, String limit) {
    return 'Больше $limit % без подтверждения нельзя. Действует прежняя скидка $applied %';
  }

  @override
  String cart_discount_over_max(String max) {
    return 'Скидка больше $max % не допускается';
  }

  @override
  String get cart_discount_override_reason_label => 'Причина скидки';

  @override
  String get cart_discount_override_reason_required => 'Укажите причину скидки';

  @override
  String get cart_drawer_close_a11y => 'Закрыть корзину';

  @override
  String cart_drawer_title_count(int count) {
    return '· $count поз.';
  }

  @override
  String get cart_empty_body => 'Добавьте товары из каталога или отсканируйте штрихкод';

  @override
  String cart_empty_parked(int count) {
    return 'Отложенные заказы ($count)';
  }

  @override
  String get cart_empty_title => 'Корзина пуста';

  @override
  String get cart_empty_to_catalog => 'К каталогу';

  @override
  String cart_fab_a11y(int count, String total) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Открыть корзину, $count позиции, $total',
      many: 'Открыть корзину, $count позиций, $total',
      few: 'Открыть корзину, $count позиции, $total',
      one: 'Открыть корзину, $count позиция, $total',
    );
    return '$_temp0';
  }

  @override
  String cart_fab_a11y_nototal(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Открыть корзину, $count позиции',
      many: 'Открыть корзину, $count позиций',
      few: 'Открыть корзину, $count позиции',
      one: 'Открыть корзину, $count позиция',
    );
    return '$_temp0';
  }

  @override
  String cart_header_label_units(String units) {
    return 'Корзина · $units';
  }

  @override
  String get cart_header_save_failed => 'Корзина не сохранена';

  @override
  String get cart_header_warning => 'В корзине есть предупреждения';

  @override
  String cart_items_count(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Товаров ($count)',
      one: 'Товаров ($count)',
    );
    return '$_temp0';
  }

  @override
  String get cart_line_delete_confirm => 'Удалить позицию из корзины?';

  @override
  String cart_line_delete_dialog_title(String name) {
    return 'Удалить «$name» из корзины?';
  }

  @override
  String get cart_line_deleted_snackbar => 'Позиция удалена';

  @override
  String cart_line_price_changed(String newValue, String old) {
    return 'Цена изменилась: было $old → стало $newValue';
  }

  @override
  String cart_line_reduce_to(String available) {
    return 'Уменьшить до $available';
  }

  @override
  String get cart_line_remove_unavailable => 'Удалить позицию';

  @override
  String cart_line_stock_available(String available, String unit) {
    return 'Доступно $available $unit';
  }

  @override
  String get cart_line_stock_short_customer => 'Недостаточно товара';

  @override
  String get cart_line_unavailable => 'Товар больше не продаётся';

  @override
  String cart_max_items(String max) {
    return 'Слишком много позиций (максимум $max). Оформите часть заказа отдельно';
  }

  @override
  String get cart_park_dialog_name_hint => 'Название (необязательно)';

  @override
  String get cart_park_dialog_title => 'Отложить заказ';

  @override
  String get cart_parked_snackbar => 'Заказ отложен';

  @override
  String get cart_parked_snackbar_open => 'Открыть отложенные';

  @override
  String get cart_parked_tooltip => 'Отложенные заказы';

  @override
  String cart_positions_short(int count) {
    return '$count поз.';
  }

  @override
  String get cart_preview_failed => 'Не удалось проверить заказ · Повторить';

  @override
  String cart_qty_below_min(String min, String unit) {
    return 'Минимальная партия — $min $unit';
  }

  @override
  String cart_qty_invalid(String step, String unit) {
    return 'Введите количество кратно $step $unit';
  }

  @override
  String get cart_result_unknown_check_list => 'Проверьте заказ в списке заказов';

  @override
  String get cart_result_unknown_long => 'Проверка занимает больше обычного. Продолжаем проверять';

  @override
  String get cart_result_unknown_open_orders => 'Открыть список заказов';

  @override
  String get cart_result_unknown_retry => 'Повторить сейчас';

  @override
  String get cart_result_unknown_title => 'Проверяем результат создания заказа…';

  @override
  String get cart_result_unknown_unlock => 'Разблокировать корзину';

  @override
  String get cart_save_state_failed => 'Ошибка сохранения · Повторить';

  @override
  String cart_save_state_queued(int count) {
    return 'В очереди: $count';
  }

  @override
  String get cart_save_state_saved => 'Сохранено';

  @override
  String get cart_save_state_saving => 'Сохраняем…';

  @override
  String cart_scan_not_found(String code) {
    return 'Товар со штрихкодом $code не найден';
  }

  @override
  String cart_summary_discount(String percent) {
    return 'Скидка ($percent %)';
  }

  @override
  String cart_summary_items(int count) {
    return 'Товаров ($count)';
  }

  @override
  String get cart_summary_preliminary => 'предварительно';

  @override
  String get cart_summary_server_note => 'Итог пересчитывает сервер по ценам 1С при оформлении';

  @override
  String get cart_summary_total => 'Итого';

  @override
  String get cart_title => 'Корзина';

  @override
  String cart_updated_from_server(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'изменено $count позиции',
      many: 'изменено $count позиций',
      few: 'изменено $count позиции',
      one: 'изменена $count позиция',
    );
    return 'Корзина обновлена с сервера: $_temp0';
  }

  @override
  String get cart_version_conflict_apply_mine => 'Применить мои изменения';

  @override
  String get cart_version_conflict_keep_server => 'Оставить как на сервере';

  @override
  String get cart_version_conflict_title => 'Корзина изменена на другом устройстве';

  @override
  String get cart_warehouse_change_title => 'Склад корзины';

  @override
  String cart_warehouse_change_warnings(int count, String warehouse) {
    return 'Склад изменён: $warehouse. Проверьте позиции с нехваткой: $count';
  }

  @override
  String cart_warehouse_changed(String warehouse) {
    return 'Склад изменён: $warehouse. Доступность пересчитана';
  }

  @override
  String cart_warehouse_label(String priceList, String warehouse) {
    return 'Склад: $warehouse · цены «$priceList»';
  }

  @override
  String get cart_warehouse_readonly_tooltip => 'Сменить склад можно только при подключении к сети';

  @override
  String get cashier_action_accept_payment => 'Принять оплату';

  @override
  String get cashier_action_catalog => 'Каталог';

  @override
  String get cashier_action_offline_hint => 'Нет сети: операции оплаты недоступны';

  @override
  String cashier_awaiting_title(int count) {
    return 'Ожидают оплаты · $count';
  }

  @override
  String get cashier_debts_all => 'Все просрочки';

  @override
  String get cashier_debts_no_data => 'Нет данных из 1С о долгах';

  @override
  String get cashier_debts_none => 'Просроченных долгов нет';

  @override
  String cashier_debts_summary(String amount, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count клиента',
      many: '$count клиентов',
      few: '$count клиента',
      one: '$count клиент',
    );
    return 'Просрочено: $_temp0 на $amount';
  }

  @override
  String get cashier_debts_title => 'Долги и просрочки';

  @override
  String cashier_discounts_limit(String percent) {
    return 'Ваш лимит ручной скидки: $percent';
  }

  @override
  String cashier_discounts_override(String roles) {
    return 'Сверх лимита подтверждает: $roles';
  }

  @override
  String cashier_discounts_rules_count(int count) {
    return 'Правил скидок 1С: $count';
  }

  @override
  String get cashier_discounts_title => 'Скидки и условия продаж';

  @override
  String get cashier_favorite_removed => 'Клиент убран из избранного';

  @override
  String get cashier_favorites_empty => 'Отмечайте клиентов звездой, чтобы они появились здесь';

  @override
  String get cashier_favorites_title => 'Избранные клиенты';

  @override
  String get cashier_load_error => 'Не удалось загрузить данные кассы';

  @override
  String cashier_lookup_not_found(String q) {
    return 'Заказ «$q» не найден';
  }

  @override
  String get cashier_lookup_order_paid => 'Оплачен';

  @override
  String get cashier_lookup_order_placeholder => 'Номер заказа или скан с распечатки';

  @override
  String get cashier_lookup_tab_customer => 'Клиент (долг)';

  @override
  String get cashier_lookup_tab_order => 'Заказ';

  @override
  String get cashier_lookup_title => 'Найти заказ или клиента';

  @override
  String get cashier_offline_no_data => 'Нет сети. Данные кассы недоступны без подключения';

  @override
  String get cashier_recent_all => 'Все транзакции';

  @override
  String get cashier_recent_empty => 'Операций за сегодня нет';

  @override
  String get cashier_recent_title => 'Недавние операции';

  @override
  String cashier_refresh_failed(String time) {
    return 'Не удалось обновить, данные от $time';
  }

  @override
  String cashier_review_title(int count) {
    return 'Требуют разбора · $count';
  }

  @override
  String get cashier_search_placeholder => 'Клиент: имя, телефон или код 1С';

  @override
  String get cashier_search_too_short => 'Введите не менее 2 символов';

  @override
  String cashier_sync_banner(int count, String entity, String time) {
    return 'Ошибка обмена с 1С: $entity. Последний успешный обмен — $time. Ошибок: $count';
  }

  @override
  String cashier_sync_banner_no_count(String entity, String time) {
    return 'Ошибка обмена с 1С: $entity. Последний успешный обмен — $time';
  }

  @override
  String get cashier_sync_open => 'Открыть статус';

  @override
  String get cashier_sync_title => 'Синхронизация с 1С';

  @override
  String get cashier_title => 'Касса';

  @override
  String get cashier_totals_cash => 'Наличные';

  @override
  String cashier_totals_counts(String orders, String payments) {
    return 'Заказов: $orders · Платежей: $payments';
  }

  @override
  String get cashier_totals_credit => 'В долг';

  @override
  String get cashier_totals_qr => 'QR';

  @override
  String get cashier_totals_title => 'Сегодня';

  @override
  String get cashier_unfinished_check => 'Проверить';

  @override
  String cashier_unfinished_desc_confirm(String number) {
    return 'подтверждение QR по заказу № $number';
  }

  @override
  String get cashier_unfinished_desc_debt => 'оплата долга клиента';

  @override
  String cashier_unfinished_desc_order(String amount, String number) {
    return 'приём $amount по заказу № $number';
  }

  @override
  String cashier_unfinished_desc_return(String number) {
    return 'заявка на возврат по заказу № $number';
  }

  @override
  String cashier_unfinished_desc_void(String number) {
    return 'аннулирование платежа № $number';
  }

  @override
  String cashier_unfinished_operation(String description) {
    return 'Незавершённая операция: $description';
  }

  @override
  String cashier_updated_at(String time) {
    return 'обновлено $time';
  }

  @override
  String get catalog_added_snackbar => 'Добавлено · Открыть';

  @override
  String catalog_added_toast(String name) {
    return 'Добавлено: $name';
  }

  @override
  String catalog_card_a11y(String name, String price, String sku, String stock, String unitFull) {
    return '$name, $price за $unitFull, $stock, артикул $sku';
  }

  @override
  String get catalog_card_choose_variant => 'Выбрать вариант';

  @override
  String catalog_card_in_cart_add_more(String qty) {
    return 'В корзине · $qty — ещё +1';
  }

  @override
  String catalog_card_in_cart_short(String qty) {
    return 'Ещё · $qty';
  }

  @override
  String catalog_card_max_available(String qty, String unit) {
    return 'Доступно $qty $unit';
  }

  @override
  String get catalog_card_other_variant => 'Другой вариант';

  @override
  String catalog_card_other_warehouse(String qty, String unit, String warehouse) {
    return '$warehouse: $qty $unit';
  }

  @override
  String get catalog_card_out_of_stock => 'Нет в наличии';

  @override
  String get catalog_card_price_changed => 'Цена изменилась';

  @override
  String catalog_card_price_from(String price) {
    return 'от $price';
  }

  @override
  String catalog_card_price_unit(String unit) {
    return '/ $unit';
  }

  @override
  String get catalog_card_remove_confirm => 'Удалить позицию из корзины?';

  @override
  String catalog_card_sku(String sku) {
    return 'Арт. $sku';
  }

  @override
  String get catalog_card_sku_missing => 'Артикул не указан';

  @override
  String get catalog_card_stock_unknown_short => 'Нет данных';

  @override
  String catalog_card_variant_label(int count, String unit, String variant) {
    return '$variant · $unit / $variant · $unit · в корзине $count вар.';
  }

  @override
  String get catalog_compact_col_available => 'Доступно';

  @override
  String get catalog_compact_col_name => 'Наименование';

  @override
  String get catalog_compact_col_photo_a11y => 'Фото';

  @override
  String get catalog_compact_col_price => 'Цена';

  @override
  String get catalog_compact_col_qty => 'Кол-во';

  @override
  String get catalog_compact_col_sku => 'Артикул';

  @override
  String get catalog_compact_col_stock => 'Наличие';

  @override
  String get catalog_compact_col_unit => 'Ед.';

  @override
  String get catalog_compact_col_variants => 'Вар.';

  @override
  String get catalog_empty_category_body => 'Товары появятся после синхронизации с 1С';

  @override
  String get catalog_empty_category_title => 'В этой категории пока нет товаров';

  @override
  String get catalog_empty_filtered_body => 'Измените или сбросьте фильтры';

  @override
  String get catalog_empty_filtered_title => 'Ничего не найдено';

  @override
  String get catalog_error_title => 'Не удалось загрузить каталог';

  @override
  String get catalog_favorite_added => 'Добавлено в избранное · Отменить';

  @override
  String get catalog_favorite_error => 'Не удалось сохранить избранное · Повторить';

  @override
  String get catalog_favorite_removed => 'Удалено из избранного · Отменить';

  @override
  String get catalog_filters_button => 'Фильтры';

  @override
  String get catalog_filters_reset => 'Сбросить фильтры';

  @override
  String catalog_found_count(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Найдено: $count товара',
      many: 'Найдено: $count товаров',
      few: 'Найдено: $count товара',
      one: 'Найдено: $count товар',
    );
    return '$_temp0';
  }

  @override
  String get catalog_initial_load_done => 'Каталог загружен';

  @override
  String catalog_initial_loading(String percent) {
    return 'Загружаем каталог… $percent %';
  }

  @override
  String get catalog_loading_more => 'Загружаем ещё товары…';

  @override
  String get catalog_loading_more_error => 'Не удалось загрузить · Повторить';

  @override
  String get catalog_preset_favorites => 'Избранное';

  @override
  String get catalog_preset_favorites_toolbar => 'Избранные';

  @override
  String get catalog_preset_newest => 'Новые';

  @override
  String get catalog_preset_recent => 'Недавние';

  @override
  String get catalog_profile_logout_confirm => 'Выйти из аккаунта?';

  @override
  String get catalog_recent_clear => 'Очистить';

  @override
  String get catalog_recent_clear_confirm_body =>
      'Список недавно просмотренных товаров будет удалён на всех устройствах';

  @override
  String get catalog_recent_clear_confirm_title => 'Очистить недавние товары?';

  @override
  String get catalog_recent_clear_error => 'Не удалось очистить · Повторить';

  @override
  String get catalog_recent_clear_offline_tooltip => 'Нужна сеть';

  @override
  String get catalog_recent_title => 'Недавние товары';

  @override
  String catalog_scan_added(String name, String qty) {
    return '+$qty · $name';
  }

  @override
  String get catalog_scanner_hid_hint => 'Используйте сканер: наведите на штрихкод и нажмите курок';

  @override
  String get catalog_sidebar_categories_title => 'Категории товаров';

  @override
  String get catalog_sidebar_collapse => 'Свернуть каталог';

  @override
  String get catalog_sidebar_expand => 'Развернуть каталог';

  @override
  String get catalog_sidebar_favorites => 'Избранное';

  @override
  String get catalog_sort_in_stock_first => 'Сначала в наличии';

  @override
  String get catalog_sort_name_asc => 'По названию А–Я';

  @override
  String get catalog_sort_name_desc => 'По названию Я–А';

  @override
  String get catalog_sort_newest => 'Сначала новые';

  @override
  String get catalog_sort_price_asc => 'По возрастанию цены';

  @override
  String get catalog_sort_price_desc => 'По убыванию цены';

  @override
  String get catalog_sort_relevance => 'По релевантности';

  @override
  String get catalog_sort_sku => 'По артикулу';

  @override
  String get catalog_title_all => 'Все товары';

  @override
  String get catalog_view_compact => 'Компакт';

  @override
  String get catalog_view_grid => 'Сетка';

  @override
  String get catalog_view_list => 'Список';

  @override
  String get category_all_categories => 'Все категории';

  @override
  String get category_all_chip => 'Все';

  @override
  String get category_breadcrumb_root => 'Каталог';

  @override
  String get category_empty_body => 'Товары появятся после синхронизации с 1С или снимите фильтры';

  @override
  String get category_error_title => 'Не удалось загрузить категорию';

  @override
  String category_filter_removed(String name) {
    return 'Фильтр «$name» снят — нет товаров в категории';
  }

  @override
  String category_found_count(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Найдено: $count товара',
      many: 'Найдено: $count товаров',
      few: 'Найдено: $count товара',
      one: 'Найдено: $count товар',
    );
    return '$_temp0';
  }

  @override
  String get category_not_found_action => 'К каталогу';

  @override
  String get category_not_found_title => 'Категория больше не существует';

  @override
  String category_ribbon_all_a11y(int count, String name) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Все товары: $name, $count товара',
      many: 'Все товары: $name, $count товаров',
      few: 'Все товары: $name, $count товара',
      one: 'Все товары: $name, $count товар',
    );
    return '$_temp0';
  }

  @override
  String get category_ribbon_next => 'Прокрутить подкатегории вправо';

  @override
  String get category_ribbon_prev => 'Прокрутить подкатегории влево';

  @override
  String category_tile_a11y(int count, String name) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$name, $count товара',
      many: '$name, $count товаров',
      few: '$name, $count товара',
      one: '$name, $count товар',
    );
    return '$_temp0';
  }

  @override
  String get category_uncategorized => 'Без категории';

  @override
  String get checkout_abort_body =>
      'Корзина и выбранные параметры сохранятся. Адрес и телефоны получателя придётся ввести заново';

  @override
  String get checkout_abort_confirm => 'Прервать';

  @override
  String get checkout_abort_continue => 'Продолжить оформление';

  @override
  String get checkout_abort_title => 'Прервать оформление?';

  @override
  String get checkout_address_hint => 'Введите адрес доставки';

  @override
  String get checkout_address_label => 'Адрес доставки';

  @override
  String get checkout_address_required => 'Введите адрес доставки';

  @override
  String get checkout_address_too_long => 'Адрес не длиннее 300 символов';

  @override
  String get checkout_back_to_cart => 'Вернуться в корзину';

  @override
  String get checkout_cancel => 'Отмена';

  @override
  String checkout_checked_onec(String time) {
    return 'Проверено в 1С · $time';
  }

  @override
  String checkout_checked_snapshot(String time) {
    return 'Проверено по данным от $time';
  }

  @override
  String checkout_comment_counter(int count) {
    return '$count/200';
  }

  @override
  String get checkout_comment_hint => 'Комментарий для курьера…';

  @override
  String get checkout_comment_label => 'Комментарий курьеру (необязательно)';

  @override
  String checkout_conflict_credit(String reason) {
    return 'Продажа в долг недоступна: $reason';
  }

  @override
  String checkout_conflict_discount(String limit) {
    return 'Скидка больше лимита роли ($limit %)';
  }

  @override
  String checkout_conflict_price(String name, String newValue, String old) {
    return 'Цена изменилась: $name — было $old, стало $newValue';
  }

  @override
  String checkout_conflict_stock(String available, String name) {
    return 'Недостаточно остатка: $name — доступно $available';
  }

  @override
  String checkout_conflict_unavailable(String name) {
    return 'Товар больше не продаётся: $name';
  }

  @override
  String get checkout_conflicts_title => 'Заказ нельзя создать: данные изменились';

  @override
  String get checkout_courier_phone_hint => 'По умолчанию — телефон получателя';

  @override
  String checkout_create_failed(String requestId) {
    return 'Не удалось создать заказ. Код обращения: $requestId';
  }

  @override
  String get checkout_creating_slow => '1С отвечает дольше обычного — заказ будет отправлен автоматически';

  @override
  String get checkout_credit_allow => 'Разрешить продажу в долг';

  @override
  String get checkout_credit_allow_reason_label => 'Причина разрешения';

  @override
  String checkout_credit_allowed_by(String name) {
    return 'Разрешено: $name';
  }

  @override
  String get checkout_credit_approval_dialog_body =>
      'Разрешить продажу в долг может старший продавец или администратор в своей учётной записи. Отложите заказ — старший откроет его на своём устройстве и оформит сам, либо выйдите, чтобы он вошёл на этом терминале';

  @override
  String get checkout_credit_approval_park => 'Отложить заказ';

  @override
  String get checkout_credit_help_ok => 'Понятно';

  @override
  String get checkout_credit_how_to_approve => 'Как получить разрешение старшего';

  @override
  String get checkout_credit_needs_customer => 'Для продажи в долг выберите клиента из 1С';

  @override
  String checkout_credit_parked_name(String customer, String time) {
    return 'Долг: $customer · $time';
  }

  @override
  String checkout_credit_reason_limit(String remaining) {
    return 'Превышен лимит: доступно $remaining';
  }

  @override
  String get checkout_credit_reason_no_data => 'Нет данных из 1С о просрочке или лимите';

  @override
  String get checkout_credit_reason_no_permission => 'Нет права продажи в долг';

  @override
  String get checkout_credit_reason_not_allowed => 'Отсрочка не разрешена соглашением';

  @override
  String get checkout_credit_reason_not_identified => 'Выберите клиента из 1С';

  @override
  String get checkout_credit_reason_onec_unavailable =>
      '1С недоступна: продажа в долг невозможна, выберите наличные или QR';

  @override
  String checkout_credit_reason_overdue(String amount) {
    return 'Есть просроченная задолженность $amount';
  }

  @override
  String get checkout_credit_reason_seller => 'Продажа в долг недоступна: обратитесь к старшему продавцу';

  @override
  String get checkout_credit_reason_stale =>
      'Данные о долге устарели, 1С недоступна: продажа в долг невозможна, выберите наличные или QR';

  @override
  String get checkout_cta_create => 'Создать заказ';

  @override
  String get checkout_cta_create_credit => 'Создать заказ в долг';

  @override
  String get checkout_cta_create_qr => 'Создать заказ и показать QR';

  @override
  String get checkout_cta_creating => 'Создаём заказ…';

  @override
  String get checkout_cta_offline => 'Нужна сеть';

  @override
  String get checkout_customer_debt_flag_no => 'нет';

  @override
  String get checkout_customer_debt_flag_overdue => 'просрочка';

  @override
  String get checkout_customer_debt_flag_yes => 'есть';

  @override
  String checkout_customer_meta(String debt, String discount, String orders) {
    return 'История: $orders · Долг: $debt · Скидка: $discount';
  }

  @override
  String get checkout_customer_new => '+ Новый клиент';

  @override
  String checkout_customer_not_found(String query) {
    return 'Клиенты не найдены по «$query»';
  }

  @override
  String get checkout_customer_onec_note =>
      'Заявка уйдёт в магазин на согласование. Цены и наличие магазин подтвердит при согласовании';

  @override
  String get checkout_customer_pay_on_pickup => 'Оплата при получении';

  @override
  String get checkout_customer_pay_qr => 'Оплатить по QR';

  @override
  String get checkout_customer_pending_onec => 'Ожидает 1С';

  @override
  String get checkout_customer_qr_unavailable => 'Оплата по QR сейчас недоступна. Выберите оплату при получении';

  @override
  String get checkout_customer_retail_chip => 'Розничный покупатель';

  @override
  String get checkout_customer_search_hint => 'Введите имя, телефон или часть имени…';

  @override
  String get checkout_date_pick => 'Выбрать дату…';

  @override
  String get checkout_date_today => 'Сегодня';

  @override
  String get checkout_date_tomorrow => 'Завтра';

  @override
  String checkout_debt_forecast(String amount, String limit, String time) {
    return 'Долг после заказа (прогноз): $amount · лимит доступен: $limit · данные 1С от $time';
  }

  @override
  String get checkout_delivery_hint => 'Доставка курьером';

  @override
  String get checkout_delivery_method_required => 'Выберите способ получения';

  @override
  String get checkout_delivery_title => 'Доставка';

  @override
  String checkout_duplicate_body(int minutes, String number) {
    return 'Похожий заказ № $number создан $minutes мин назад. Создать ещё один?';
  }

  @override
  String get checkout_duplicate_create => 'Создать ещё один';

  @override
  String get checkout_duplicate_open => 'Открыть заказ';

  @override
  String get checkout_duplicate_title => 'Похожий заказ уже создан';

  @override
  String get checkout_forbidden_payment => 'Недостаточно прав для этого способа оплаты';

  @override
  String checkout_form_errors_summary(int count) {
    return 'Исправьте поля: $count';
  }

  @override
  String checkout_items_count(int count) {
    return '($count позиций)';
  }

  @override
  String get checkout_items_edit => 'Изменить';

  @override
  String get checkout_map_button => 'Выбрать на карте';

  @override
  String get checkout_map_tooltip => 'Карта — в следующей версии';

  @override
  String get checkout_next => 'Далее';

  @override
  String get checkout_onec_note => 'Заказ будет создан в 1С и отправлен на согласование';

  @override
  String get checkout_onec_note_offline => 'Заказ будет отправлен в 1С автоматически, как только она станет доступна';

  @override
  String get checkout_onec_unavailable_banner =>
      '1С сейчас недоступна. Заказ будет отправлен в 1С автоматически. Продажа в долг — только по актуальным данным о долге';

  @override
  String get checkout_open_restored_cart => 'Открыть восстановленную корзину';

  @override
  String get checkout_pay_cash_hint => 'Оплата в нашем магазине';

  @override
  String get checkout_pay_cash_title => 'Наличными в кассу';

  @override
  String get checkout_pay_checking_debt => 'Проверяем долг…';

  @override
  String get checkout_pay_credit_hint => 'Оплата позже (по согласованию)';

  @override
  String get checkout_pay_credit_title => 'Без оплаты / долг';

  @override
  String get checkout_pay_info_cash_cashier => 'После создания заказа нажмите «Принять оплату»';

  @override
  String get checkout_pay_info_cash_seller => 'После создания заказа передайте клиента в кассу';

  @override
  String checkout_pay_info_credit(String date) {
    return 'Срок оплаты — по соглашению с клиентом в 1С: до $date';
  }

  @override
  String get checkout_pay_info_qr_manual =>
      'После создания заказа будет показан QR-код Бакай Банка. Оплату подтвердит кассир по выписке банка';

  @override
  String get checkout_pay_info_qr_webhook =>
      'После создания заказа будет сформирован QR-код для оплаты через Бакай Банк. После оплаты заказ будет автоматически отмечен как оплаченный';

  @override
  String get checkout_pay_qr_hint => 'Оплата картой по QR';

  @override
  String get checkout_pay_qr_title => 'QR / карта Бакай Банк';

  @override
  String get checkout_payment_required => 'Выберите способ оплаты';

  @override
  String get checkout_phone_invalid => 'Введите 9 цифр номера';

  @override
  String get checkout_pickup_hint => 'Клиент заберёт сам';

  @override
  String get checkout_pickup_title => 'Самовывоз';

  @override
  String get checkout_pii_not_saved_hint =>
      'Адрес и телефоны получателя не сохраняются на устройстве — введите их заново';

  @override
  String get checkout_print_invoice => 'Счёт на оплату';

  @override
  String get checkout_print_invoice_hint => 'PDF, A4; печать после получения номера 1С';

  @override
  String get checkout_print_printer_missing => 'Настройте принтер в Настройках';

  @override
  String get checkout_print_receipt => 'Товарный чек';

  @override
  String get checkout_print_receipt_hint => 'Не является фискальным документом, 80 мм';

  @override
  String get checkout_print_title => 'Печать после создания заказа';

  @override
  String get checkout_print_waybill => 'Накладная (предварительная)';

  @override
  String get checkout_print_waybill_hint => 'Не является документом отгрузки; накладная — из 1С';

  @override
  String get checkout_receiver_customer => 'Клиент';

  @override
  String get checkout_receiver_customer_hint => 'Получает сам клиент';

  @override
  String get checkout_receiver_name_label => 'ФИО получателя';

  @override
  String get checkout_receiver_name_required => 'Введите ФИО получателя';

  @override
  String get checkout_receiver_other => 'Другой человек';

  @override
  String get checkout_receiver_other_hint => 'Товар получает другой человек';

  @override
  String get checkout_receiver_phone_label => 'Телефон получателя';

  @override
  String get checkout_receiver_title => 'Получатель';

  @override
  String get checkout_recipient_phone_label => 'Телефон для курьера';

  @override
  String checkout_rejected_onec(String reason) {
    return '1С отклонила заказ: $reason';
  }

  @override
  String get checkout_scan_ignored => 'Закройте оформление, чтобы сканировать товары';

  @override
  String get checkout_section_customer => 'Клиент';

  @override
  String get checkout_section_delivery => 'Получение товара';

  @override
  String get checkout_section_items => 'Состав заказа';

  @override
  String get checkout_section_payment => 'Оплата';

  @override
  String get checkout_slot_past => 'Этот интервал уже прошёл';

  @override
  String get checkout_slot_required => 'Выберите дату и время доставки';

  @override
  String checkout_slot_value(String from, String to) {
    return 'с $from до $to';
  }

  @override
  String checkout_step_counter(String step, String title) {
    return 'Шаг $step из 4 · $title';
  }

  @override
  String checkout_step_counter_n(String step, String title, String total) {
    return 'Шаг $step из $total · $title';
  }

  @override
  String get checkout_step_customer => 'Клиент';

  @override
  String get checkout_step_delivery => 'Получение';

  @override
  String get checkout_step_done => 'Завершение';

  @override
  String get checkout_step_payment => 'Оплата';

  @override
  String get checkout_summary_customer_discount => 'Скидка клиента (из 1С)';

  @override
  String checkout_summary_discount(String percent) {
    return 'Скидка ($percent %)';
  }

  @override
  String get checkout_summary_subtotal => 'Сумма без скидки';

  @override
  String get checkout_summary_total => 'Итого к оплате';

  @override
  String get checkout_time_label => 'Желаемое время доставки';

  @override
  String get checkout_title => 'Подтверждение заказа';

  @override
  String get customer_card_accept_disabled_no_debt => 'Нет долга';

  @override
  String get customer_card_accept_disabled_no_onec => 'Клиент ещё не создан в 1С';

  @override
  String get customer_card_action_accept_debt => 'Принять оплату по долгу';

  @override
  String get customer_card_action_to_cart => 'В заказ';

  @override
  String get customer_card_back_to_list => 'К списку клиентов';

  @override
  String customer_card_code(String code) {
    return 'Код 1С: $code';
  }

  @override
  String customer_card_code_pos(String code) {
    return 'Код POS: $code';
  }

  @override
  String get customer_card_contacts_empty => 'Контакты не указаны';

  @override
  String get customer_card_contacts_title => 'Контакты и адреса';

  @override
  String get customer_card_debt_available => 'Доступно (прогноз)';

  @override
  String get customer_card_debt_balance => 'Сальдо';

  @override
  String get customer_card_debt_limit => 'Лимит';

  @override
  String customer_card_debt_limit_available(String available, String limit) {
    return 'Доступно (прогноз) $available из $limit';
  }

  @override
  String get customer_card_debt_no_data => 'Нет данных из 1С';

  @override
  String get customer_card_debt_overdue => 'Просрочено';

  @override
  String get customer_card_favorite_added => 'Клиент добавлен в избранное';

  @override
  String get customer_card_favorite_removed => 'Клиент убран из избранного';

  @override
  String customer_card_inn(String inn) {
    return 'ИНН: $inn';
  }

  @override
  String get customer_card_links_title => 'Пользователи приложения';

  @override
  String get customer_card_marked_deleted => 'Помечен на удаление в 1С';

  @override
  String customer_card_metric_debt(String amount) {
    return 'Долг: $amount';
  }

  @override
  String get customer_card_metric_debt_flag_no => 'Долг: нет';

  @override
  String get customer_card_metric_debt_flag_yes => 'Долг: есть';

  @override
  String customer_card_metric_discount(String percent) {
    return 'Скидка: $percent';
  }

  @override
  String customer_card_metric_history(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count заказа',
      many: '$count заказов',
      few: '$count заказа',
      one: '$count заказ',
    );
    return 'История: $_temp0';
  }

  @override
  String get customer_card_metric_overdue_flag => 'Просрочка';

  @override
  String get customer_card_not_found => 'Клиент не найден';

  @override
  String get customer_card_offline => 'Карточка клиента недоступна без сети';

  @override
  String get customer_card_pending_onec => 'ожидает 1С';

  @override
  String get customer_card_pending_onec_hint => 'Продажа в долг станет доступна после создания клиента в 1С';

  @override
  String get customer_card_phone_not_verified => 'не подтверждён';

  @override
  String get customer_card_phone_verified => 'подтверждён';

  @override
  String customer_card_replace_body(String current) {
    return 'В корзине выбран $current. Скидка клиента и цены будут пересчитаны';
  }

  @override
  String get customer_card_replace_cta => 'Заменить';

  @override
  String get customer_card_replace_title => 'Заменить клиента в корзине?';

  @override
  String get customer_card_retail_system => 'Системный клиент для розничных продаж без карточки';

  @override
  String get customer_card_scan_hint => 'Сканирование доступно в поиске';

  @override
  String get customer_card_segment_operations => 'Операции';

  @override
  String get customer_card_segment_orders => 'Заказы';

  @override
  String get customer_card_seller_info => 'Суммы долга и история покупок доступны кассиру';

  @override
  String get customer_card_tab_discounts => 'Скидки';

  @override
  String get customer_card_tab_history => 'История';

  @override
  String get customer_card_tab_orders => 'Заказы и операции';

  @override
  String get customer_card_tab_receivables => 'Долги';

  @override
  String get customer_card_type_entrepreneur => 'Индивидуальный предприниматель';

  @override
  String get customer_card_type_individual => 'Физическое лицо';

  @override
  String get customer_card_type_legal => 'Юридическое лицо';

  @override
  String get customer_discounts_auto_note =>
      'Автоматические скидки и акции 1С применяются при проведении заказа и здесь не показываются';

  @override
  String get customer_discounts_block_error => 'Не удалось загрузить';

  @override
  String customer_discounts_client_discount(String percent) {
    return 'Скидка клиента из 1С: $percent';
  }

  @override
  String get customer_discounts_client_none => 'Скидка клиента не задана';

  @override
  String get customer_discounts_credit_allowed => 'Продажа в долг: разрешена';

  @override
  String customer_discounts_credit_limit(String amount) {
    return 'Лимит долга: $amount';
  }

  @override
  String get customer_discounts_credit_not_allowed => 'не разрешена';

  @override
  String customer_discounts_example(String discount, String percent, String subtotal, String total) {
    return 'Заказ $subtotal → скидка $percent = $discount → итог $total (предварительно, итог определяет 1С)';
  }

  @override
  String get customer_discounts_offline => 'Условия клиента недоступны без сети';

  @override
  String customer_discounts_override_roles(String roles) {
    return 'Сверх лимита подтверждает: $roles';
  }

  @override
  String get customer_discounts_price_list => 'Вид цены';

  @override
  String get customer_discounts_price_list_default => 'Вид цены не задан — используется розничный';

  @override
  String customer_discounts_role_limit(String percent) {
    return 'Ваш лимит ручной скидки: $percent';
  }

  @override
  String get customer_discounts_rule_active => 'Действует';

  @override
  String get customer_discounts_rule_inactive => 'Не действует';

  @override
  String get customer_discounts_rule_onec_total => 'Итог в 1С';

  @override
  String get customer_discounts_rule_source_onec => '1С';

  @override
  String get customer_discounts_rule_source_pos => 'POS';

  @override
  String get customer_discounts_rules_empty => 'Правил для клиента нет';

  @override
  String get customer_discounts_rules_title => 'Правила скидок';

  @override
  String customer_discounts_term_days(String days) {
    return 'Отсрочка: $days дн.';
  }

  @override
  String get customer_discounts_terms_title => 'Условия оплаты';

  @override
  String get customer_discounts_title => 'Скидки и условия';

  @override
  String get customer_history_change_period => 'Изменить период';

  @override
  String customer_history_count(int count) {
    return 'Документов: $count';
  }

  @override
  String get customer_history_debt_note => 'Долг — только по данным 1С, см. вкладку «Долги»';

  @override
  String customer_history_depth(String date) {
    return 'История из 1С загружена с $date';
  }

  @override
  String get customer_history_depth_unknown => 'Ранние покупки могут отсутствовать';

  @override
  String get customer_history_empty => 'Покупок за период нет';

  @override
  String get customer_history_end => 'Показаны все документы за период';

  @override
  String get customer_history_items_error => 'Не удалось загрузить позиции';

  @override
  String get customer_history_offline => 'История покупок недоступна без сети';

  @override
  String customer_history_onec_as_of(String time) {
    return 'Документы 1С на $time';
  }

  @override
  String get customer_history_open_order => 'Открыть заказ';

  @override
  String get customer_history_preset_30 => '30 дней';

  @override
  String get customer_history_preset_90 => '90 дней';

  @override
  String get customer_history_preset_custom => 'Период…';

  @override
  String get customer_history_preset_year => 'Год';

  @override
  String get customer_history_range_invalid => 'Дата «по» раньше даты «с»';

  @override
  String get customer_history_source_all => 'Все';

  @override
  String get customer_history_source_onec => 'Продажи 1С';

  @override
  String get customer_history_source_pos => 'Заказы POS';

  @override
  String get customer_history_title => 'История покупок';

  @override
  String customer_history_total(String amount) {
    return 'Покупок на сумму: $amount';
  }

  @override
  String get customer_mode_disabled => 'Сервис для покупателей временно недоступен';

  @override
  String get customer_mode_disabled_body => 'Заказы через приложение сейчас не принимаются. Обратитесь в магазин';

  @override
  String get customer_new_abort_body => 'Введённые данные не сохранятся';

  @override
  String get customer_new_abort_confirm => 'Отменить создание';

  @override
  String get customer_new_abort_title => 'Отменить создание клиента?';

  @override
  String get customer_new_address_label => 'Адрес';

  @override
  String get customer_new_check_failed => 'Не удалось проверить номер на дубли';

  @override
  String get customer_new_check_retry => 'Повторить проверку';

  @override
  String get customer_new_checking => 'Проверяем…';

  @override
  String customer_new_comment_counter(int count) {
    return '$count/500';
  }

  @override
  String get customer_new_comment_label => 'Комментарий';

  @override
  String get customer_new_create => 'Создать клиента';

  @override
  String get customer_new_create_failed => 'Не удалось создать клиента · Повторить';

  @override
  String get customer_new_created_snackbar => 'Клиент создан · ожидает 1С';

  @override
  String get customer_new_duplicate_inn_title => 'Найден клиент с этим ИНН';

  @override
  String get customer_new_duplicate_title => 'Найден клиент с этим номером';

  @override
  String get customer_new_force_create => 'Всё равно создать';

  @override
  String get customer_new_force_reason_label => 'Причина создания при совпадении номера';

  @override
  String customer_new_force_reason_prefix(String reason) {
    return 'Причина создания при совпадении: $reason';
  }

  @override
  String get customer_new_force_reason_required => 'Укажите, почему создаётся новый клиент при совпадении номера';

  @override
  String get customer_new_force_tooltip => 'Создать новую карточку, несмотря на совпадение';

  @override
  String get customer_new_inn_invalid => 'ИНН — 14 цифр';

  @override
  String get customer_new_inn_label => 'ИНН';

  @override
  String get customer_new_name_label => 'ФИО или наименование';

  @override
  String get customer_new_name_required => 'Введите ФИО или наименование';

  @override
  String get customer_new_no_duplicates => 'Совпадений не найдено';

  @override
  String get customer_new_offline => 'Нужна сеть, чтобы создать клиента';

  @override
  String get customer_new_onec_note =>
      'Клиент сначала сохраняется в приложении и автоматически создаётся в 1С. До подтверждения 1С ему можно продавать за наличные и по QR, но не в долг';

  @override
  String get customer_new_phone_invalid => 'Введите 9 цифр номера';

  @override
  String get customer_new_phone_label => 'Телефон';

  @override
  String get customer_new_seller_duplicate_hint =>
      'Если это другой клиент — обратитесь к кассиру или старшему продавцу';

  @override
  String customer_new_show_more(int count) {
    return 'Показать ещё ($count)';
  }

  @override
  String customer_new_stale_check(String time) {
    return 'Проверка в 1С сейчас недоступна — возможен дубль. Проверено по данным приложения от $time';
  }

  @override
  String get customer_new_title => 'Новый клиент';

  @override
  String get customer_new_type_entrepreneur => 'ИП';

  @override
  String get customer_new_type_individual => 'Физ. лицо';

  @override
  String get customer_new_type_legal => 'Юр. лицо';

  @override
  String get customer_new_use_existing => 'Выбрать этого клиента';

  @override
  String customer_orders_count(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count заказа',
      many: '$count заказов',
      few: '$count заказа',
      one: '$count заказ',
    );
    return '$_temp0';
  }

  @override
  String get customers_search_detail_empty => 'Выберите клиента';

  @override
  String customers_search_empty(String q) {
    return 'Клиенты не найдены по «$q»';
  }

  @override
  String get customers_search_error => 'Не удалось найти клиентов';

  @override
  String get customers_search_filter_all => 'Все';

  @override
  String get customers_search_filter_debt => 'С долгом';

  @override
  String get customers_search_filter_favorites => 'Избранные';

  @override
  String get customers_search_filter_overdue => 'С просрочкой';

  @override
  String get customers_search_has_debt => 'Есть долг';

  @override
  String get customers_search_hint_idle => 'Введите имя, телефон или код клиента';

  @override
  String get customers_search_marked_deleted => 'Помечен на удаление';

  @override
  String get customers_search_match_code => 'по коду';

  @override
  String customers_search_match_inn(int count) {
    return 'по ИНН: $count';
  }

  @override
  String get customers_search_match_name => 'Найдено по имени';

  @override
  String get customers_search_match_phone => 'по телефону';

  @override
  String get customers_search_new => '+ Новый клиент';

  @override
  String get customers_search_offline => 'Поиск клиентов недоступен без сети';

  @override
  String get customers_search_overdue_flag => 'Просрочка';

  @override
  String get customers_search_pending_onec => 'ожидает 1С';

  @override
  String get customers_search_phone_full_hint => 'Для поиска по телефону введите номер полностью';

  @override
  String get customers_search_placeholder => 'Введите имя, телефон или часть имени…';

  @override
  String get customers_search_seller_hint => 'Введите полный номер телефона или код клиента';

  @override
  String get customers_search_title => 'Клиенты';

  @override
  String get ds_back_online => 'Сеть восстановлена. Отправляем изменения…';

  @override
  String get ds_button_add => '+ Добавить';

  @override
  String get ds_button_apply => 'Применить';

  @override
  String get ds_button_cancel => 'Отмена';

  @override
  String get ds_button_close => 'Закрыть';

  @override
  String get ds_button_more => 'Ещё';

  @override
  String get ds_button_ok => 'Готово';

  @override
  String get ds_button_open => 'Открыть';

  @override
  String get ds_button_reset => 'Сбросить';

  @override
  String get ds_button_retry => 'Повторить';

  @override
  String ds_button_show_n(int count) {
    return 'Показать $count';
  }

  @override
  String get ds_button_undo => 'Отменить';

  @override
  String get ds_confirm_title_default => 'Подтвердите действие';

  @override
  String get ds_copied => 'Скопировано';

  @override
  String get ds_copy_number => 'Скопировать номер';

  @override
  String get ds_copy_phone => 'Скопировать телефон';

  @override
  String get ds_credit_not_allowed => 'Соглашение клиента без отсрочки';

  @override
  String ds_data_as_of(String time) {
    return 'данные от $time';
  }

  @override
  String get ds_empty_category_title => 'В этой категории пока нет товаров';

  @override
  String get ds_empty_no_camera_title => 'Камера недоступна';

  @override
  String get ds_empty_offline_no_cache_body => 'Подключитесь к сети и выполните синхронизацию';

  @override
  String get ds_empty_offline_no_cache_title => 'Нет данных для работы без сети';

  @override
  String ds_empty_search_title(String query) {
    return 'Ничего не найдено по «$query»';
  }

  @override
  String get ds_favorite_add_a11y => 'Добавить в избранное';

  @override
  String get ds_favorite_on_a11y => 'В избранном';

  @override
  String get ds_gallery_next_a11y => 'Следующее фото';

  @override
  String get ds_gallery_prev_a11y => 'Предыдущее фото';

  @override
  String get ds_gallery_zoom_in_a11y => 'Увеличить';

  @override
  String get ds_gallery_zoom_out_a11y => 'Уменьшить';

  @override
  String get ds_idempotency_pending => 'Статус операции уточняется';

  @override
  String get ds_loading => 'Загрузка…';

  @override
  String get ds_loading_long => 'Долгая загрузка…';

  @override
  String get ds_no_photo => 'Нет фото';

  @override
  String ds_offline_banner(String time) {
    return 'Нет сети. Показаны данные от $time. Заказы недоступны';
  }

  @override
  String get ds_offline_unlock => 'Нет подключения. Для входа нужна сеть';

  @override
  String get ds_onec_down =>
      '1С недоступна: заказы будут отправлены позже; продажа в долг — только по актуальным данным о долге';

  @override
  String get ds_price_missing => 'Цена не указана';

  @override
  String get ds_qr_open_payment_hint => 'Сначала аннулируйте или подтвердите текущий платёж';

  @override
  String get ds_qr_retry_without_bank => 'Повторить без банка';

  @override
  String get ds_qr_static_plate_hint =>
      'QR не сформирован банком. Покажите клиенту QR-табличку кассы; оплату подтвердит кассир';

  @override
  String get ds_qty_decrease_a11y => 'Уменьшить количество';

  @override
  String get ds_qty_increase_a11y => 'Увеличить количество';

  @override
  String get ds_receivable_details_hint => 'Есть долг · подробности в карточке клиента';

  @override
  String get ds_receivable_has_debt => 'Есть долг';

  @override
  String get ds_receivable_overdue => 'Просрочка';

  @override
  String get ds_reconnecting => 'Подключаемся…';

  @override
  String ds_request_id(String requestId) {
    return 'Код: $requestId';
  }

  @override
  String get ds_search_placeholder_customers => 'Введите имя, телефон или часть имени…';

  @override
  String get ds_search_placeholder_products => 'Поиск товара по названию, коду или штрих-коду…';

  @override
  String get ds_server_down => 'Сервер недоступен';

  @override
  String get ds_step_up_title => 'Подтвердите действие';

  @override
  String get ds_stock_unknown => 'Остаток неизвестен';

  @override
  String get ds_sync_error => 'Ошибка синхронизации';

  @override
  String get ds_sync_offline => 'Нет сети';

  @override
  String get ds_sync_syncing => 'Обновляем…';

  @override
  String get ds_update_required => 'Требуется обновление приложения';

  @override
  String ds_updated_at(String time) {
    return 'обновлено $time';
  }

  @override
  String get error_app_read_only => 'Сервер работает в режиме только чтения — изменения временно недоступны';

  @override
  String get error_cart_empty => 'Корзина пуста';

  @override
  String get error_credit_blocked => 'Продажа в долг недоступна';

  @override
  String get error_credit_limit_exceeded => 'Превышен лимит долга клиента';

  @override
  String get error_customer_duplicate_suspected => 'Найден клиент с этим номером';

  @override
  String get error_customer_not_identified => 'Выберите клиента';

  @override
  String error_discount_limit_exceeded(String limit) {
    return 'Скидка больше вашего лимита ($limit %)';
  }

  @override
  String get error_forbidden => 'Недостаточно прав';

  @override
  String get error_idempotency_in_progress => 'Операция уже выполняется';

  @override
  String get error_internal => 'Не удалось выполнить. Повторите';

  @override
  String get error_not_found => 'Не найдено';

  @override
  String get error_onec_rejected => '1С отклонила документ';

  @override
  String get error_onec_unavailable => '1С временно недоступна. Заказ будет отправлен позже';

  @override
  String get error_order_state_invalid => 'Действие недоступно в текущем статусе';

  @override
  String get error_payment_state_invalid => 'Статус платежа изменился';

  @override
  String get error_price_changed => 'Цены изменились. Подтвердите новые цены';

  @override
  String get error_qr_unavailable => 'QR временно недоступен';

  @override
  String error_qty_below_min(String min, String unit) {
    return 'Минимальная партия — $min $unit';
  }

  @override
  String error_qty_not_multiple(String m, String unit) {
    return 'Количество должно быть кратно $m $unit';
  }

  @override
  String error_rate_limited(int seconds) {
    return 'Слишком много запросов, подождите $seconds с';
  }

  @override
  String get error_receivables_stale => 'Данные о долге устарели';

  @override
  String error_return_qty_exceeded(int n) {
    return 'Можно вернуть не больше $n';
  }

  @override
  String get error_step_up_required => 'Подтвердите действие';

  @override
  String error_stock_insufficient(String available, String unit) {
    return 'Недостаточно остатка: доступно $available $unit';
  }

  @override
  String get error_sync_already_running => 'Синхронизация уже выполняется';

  @override
  String get error_variant_unavailable => 'Товар больше не продаётся';

  @override
  String get error_version_conflict => 'Данные изменились на другом устройстве';

  @override
  String get face_cancel_body => 'Регистрация продолжится без сканирования лица';

  @override
  String get face_cancel_title => 'Прервать сканирование?';

  @override
  String get face_consent_label => 'Согласен(на) на обработку изображения лица для этой проверки';

  @override
  String get face_continue_without => 'Продолжить без сканирования';

  @override
  String get face_data_notice => 'Снимки обрабатываются на устройстве и не сохраняются';

  @override
  String get face_done => 'Готово';

  @override
  String get face_failed_title => 'Не удалось завершить сканирование';

  @override
  String get face_hint_bright => 'Слишком ярко — уберите источник света из кадра';

  @override
  String get face_hint_center => 'Расположите лицо в овале';

  @override
  String get face_hint_closer => 'Подойдите ближе';

  @override
  String get face_hint_dark => 'Слишком темно';

  @override
  String get face_hint_eyes => 'Откройте глаза';

  @override
  String get face_hint_farther => 'Отодвиньтесь немного';

  @override
  String get face_hint_many_faces => 'В кадре должно быть одно лицо';

  @override
  String get face_hint_no_face => 'Лицо не найдено';

  @override
  String get face_hint_steady => 'Держите телефон неподвижно';

  @override
  String get face_hint_too_far => 'Слишком сильно — поверните немного назад';

  @override
  String get face_later => 'Настроить позже';

  @override
  String get face_other_method => 'Настроить вход по-другому';

  @override
  String face_paused_attempts(String mmss) {
    return 'Слишком много попыток. Повторите через $mmss';
  }

  @override
  String get face_restart => 'Начать заново';

  @override
  String get face_retry => 'Попробуйте ещё раз';

  @override
  String get face_retry_step => 'Повторить шаг';

  @override
  String get face_rotate_device => 'Поверните устройство вертикально';

  @override
  String get face_skip => 'Пропустить';

  @override
  String get face_start => 'Начать';

  @override
  String face_step_counter(int n) {
    return 'Шаг $n из 4';
  }

  @override
  String get face_step_front => 'Посмотрите прямо в камеру';

  @override
  String get face_step_left => 'Медленно поверните голову влево';

  @override
  String get face_step_ok => 'Отлично';

  @override
  String get face_step_right => 'Теперь поверните голову вправо';

  @override
  String get face_step_timeout_title => 'Не получается?';

  @override
  String get face_step_up => 'Поднимите подбородок немного вверх';

  @override
  String get face_title => 'Сканирование лица';

  @override
  String get face_unsupported_no_camera => 'Нет фронтальной камеры. Вход защищён PIN-кодом';

  @override
  String get face_unsupported_title => 'Сканирование лица недоступно на этом устройстве';

  @override
  String get favorites_customer_removed_snackbar => 'Клиент убран из избранного';

  @override
  String get favorites_empty_customers_action => 'Найти клиента';

  @override
  String get favorites_empty_customers_body => 'Отмечайте клиентов звездой в карточке клиента';

  @override
  String get favorites_empty_customers_title => 'Избранных клиентов пока нет';

  @override
  String get favorites_filter_customers_hint => 'Фильтр по избранным клиентам';

  @override
  String favorites_item_a11y(String name, String price, String stock) {
    return 'Товар $name, цена $price, $stock, в избранном';
  }

  @override
  String get favorites_not_sold_label => 'Не продаётся';

  @override
  String get favorites_pending_label => 'Ожидает отправки';

  @override
  String favorites_products_found(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count товара',
      many: '$count товаров',
      few: '$count товара',
      one: '$count товар',
    );
    return '$_temp0';
  }

  @override
  String get favorites_remove_error => 'Не удалось убрать из избранного. Повторите';

  @override
  String get favorites_removed_snackbar => 'Убрано из избранного';

  @override
  String get favorites_scan_ignored => 'Сканирование работает во вкладке «Товары»';

  @override
  String get favorites_star_remove_tooltip => 'Убрать из избранного';

  @override
  String favorites_tab_customers_count(int count) {
    return 'Клиенты · $count';
  }

  @override
  String favorites_tab_products_count(int count) {
    return 'Товары · $count';
  }

  @override
  String get favorites_title => 'Избранное';

  @override
  String get favorites_to_order_button => 'В заказ';

  @override
  String get filters_applied_locally => 'Фильтр применён к найденному';

  @override
  String get filters_attr_limit => 'Выбрано максимум 10 характеристик';

  @override
  String get filters_brand_title => 'Бренд';

  @override
  String get filters_category_title => 'Категория';

  @override
  String get filters_color_title => 'Цвет';

  @override
  String get filters_error_load => 'Не удалось загрузить фильтры · Повторить';

  @override
  String get filters_favorites_only => 'Только избранное';

  @override
  String get filters_in_stock => 'Только в наличии';

  @override
  String get filters_model_title => 'Модель / серия';

  @override
  String get filters_no_results => 'Нет товаров';

  @override
  String get filters_no_results_hint => 'Ослабьте условия';

  @override
  String filters_offline_note(String time) {
    return 'Фильтры по сохранённым данным от $time';
  }

  @override
  String get filters_price_error_range => 'Минимальная цена больше максимальной';

  @override
  String get filters_price_from => 'от';

  @override
  String filters_price_range_hint(String max, String min, String priceList) {
    return 'В выдаче: $min — $max · вид цены «$priceList»';
  }

  @override
  String get filters_price_title => 'Цена, сом';

  @override
  String get filters_price_to => 'до';

  @override
  String get filters_reset_all => 'Сбросить все';

  @override
  String filters_show_all(int count) {
    return 'Показать все ($count)';
  }

  @override
  String filters_show_n(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Показать $count товара',
      many: 'Показать $count товаров',
      few: 'Показать $count товара',
      one: 'Показать $count товар',
    );
    return '$_temp0';
  }

  @override
  String get filters_size_title => 'Размер';

  @override
  String filters_stock_as_of(String time) {
    return 'данные остатков от $time';
  }

  @override
  String get filters_title => 'Фильтры';

  @override
  String get filters_warehouse_cart_hint => 'склад корзины';

  @override
  String get filters_warehouse_title => 'Склад';

  @override
  String filters_warehouse_view_note(String name) {
    return 'Остатки склада «$name». Продажа — со склада корзины';
  }

  @override
  String get filters_with_photo_only => 'Только с фото';

  @override
  String global_offline_body(String time) {
    return 'Это действие требует связи с сервером. Каталог и корзина доступны из кэша (обновлено $time)';
  }

  @override
  String get global_offline_continue => 'Продолжить работу из кэша';

  @override
  String get global_offline_title => 'Нет подключения к сети';

  @override
  String get global_payment_cashier_only => 'Приём оплаты выполняет кассир';

  @override
  String get global_permission_biometrics =>
      'Нет доступа к биометрии. Разрешите Face ID в настройках или используйте PIN';

  @override
  String get global_permission_camera => 'Нет доступа к камере. Разрешите доступ в настройках устройства';

  @override
  String get global_permission_open_settings => 'Открыть настройки';

  @override
  String get global_permissions_changed => 'Ваши права изменены администратором';

  @override
  String get global_request_id_copied => 'Код скопирован';

  @override
  String get global_role_forbidden => 'Раздел недоступен для вашей роли';

  @override
  String global_senior_body(String action, String limit) {
    return '$action превышает ваш лимит ($limit). Его может выполнить старший продавец или администратор в своей сессии';
  }

  @override
  String get global_senior_title => 'Нужно подтверждение старшего';

  @override
  String global_session_draft_saved(int count) {
    return 'Черновик корзины ($count) сохранён на этом устройстве и будет восстановлен после входа';
  }

  @override
  String get global_session_ended_title => 'Сессия завершена';

  @override
  String get global_session_login_again => 'Войти снова';

  @override
  String get global_session_reason_admin => 'Сессию завершил администратор. Войдите снова по номеру телефона';

  @override
  String get global_session_reason_device_mismatch => 'Сессия привязана к другому устройству. Войдите снова';

  @override
  String get global_session_reason_expired => 'Срок входа истёк. Войдите снова по номеру телефона';

  @override
  String get global_session_reason_other_device =>
      'Вход выполнен на другом устройстве или устройство удалено из списка. Войдите снова';

  @override
  String get global_session_reason_phone_changed => 'Номер входа изменён. Войдите снова';

  @override
  String get global_session_reason_reuse => 'Для безопасности мы завершили все сессии. Войдите снова';

  @override
  String get global_update_action => 'Обновить';

  @override
  String global_update_body(String minVersion) {
    return 'Установите версию $minVersion или новее, чтобы продолжить работу';
  }

  @override
  String get global_update_later => 'Позже';

  @override
  String get global_update_soft => 'Доступна новая версия приложения';

  @override
  String get home_back_to_exit => 'Нажмите ещё раз для выхода';

  @override
  String get home_favorites => 'Избранное';

  @override
  String get home_link_conflict => 'Привязка к организации ожидает подтверждения администратором';

  @override
  String home_link_proposed(String name) {
    return 'Мы нашли организацию $name. Это вы?';
  }

  @override
  String get home_link_proposed_action => 'Проверить';

  @override
  String get home_link_rejected => 'Организация не подтверждена. Заказы оформляются как новый клиент';

  @override
  String get home_loading_more => 'Загружаем ещё товары…';

  @override
  String get home_my_debt => 'Мой долг';

  @override
  String get home_my_debt_no_data => 'Нет данных из 1С';

  @override
  String get home_my_debt_unavailable => 'Долг доступен после подтверждения организации';

  @override
  String get home_my_orders => 'Мои заказы';

  @override
  String home_my_orders_active(int count) {
    return '$count в работе';
  }

  @override
  String get home_my_orders_active_nocount => 'Есть заказы в работе';

  @override
  String get home_my_orders_empty => 'Заказов нет';

  @override
  String home_price_list_label(String name) {
    return 'Ваш вид цены: $name';
  }

  @override
  String get home_price_list_tooltip => 'Цены показаны по вашему виду цены';

  @override
  String get home_recent_clear => 'Очистить';

  @override
  String get home_recent_title => 'Недавние товары';

  @override
  String get link_body_conflict =>
      'Найдено несколько карточек с вашим номером. Администратор магазина проверит данные и свяжется с вами';

  @override
  String get link_body_found =>
      'В учётной системе магазина есть клиент с вашим номером. Подтвердите, что это вы — заказы и условия станут доступны в приложении';

  @override
  String get link_body_none => 'Условия обслуживания уточнит менеджер магазина';

  @override
  String get link_confirm => 'Да, это я';

  @override
  String get link_contact_shop => 'Связаться с магазином';

  @override
  String get link_finance_hidden => 'Финансовые данные не показываются до подтверждения';

  @override
  String get link_reject => 'Нет, это не я';

  @override
  String get link_reject_body =>
      'Мы не будем связывать аккаунт с этой карточкой. Если карточка всё же ваша, объединить их сможет администратор магазина';

  @override
  String get link_reject_title => 'Это не ваша карточка?';

  @override
  String get link_searching => 'Ищем вашу карточку…';

  @override
  String get link_success => 'Карточка привязана';

  @override
  String get link_title_conflict => 'Нужна помощь администратора';

  @override
  String get link_title_found => 'Мы нашли вашу карточку клиента';

  @override
  String get link_title_none => 'Карточка клиента будет создана при первом заказе';

  @override
  String get link_wait_admin => 'Ожидает подтверждения администратором';

  @override
  String mascot_state_a11y(String state) {
    return 'Персонаж: $state';
  }

  @override
  String get notification_kind_cart_price_changed => 'Цена в корзине изменилась';

  @override
  String get notification_kind_cart_stock_changed => 'Остаток в корзине изменился';

  @override
  String get notification_kind_credit_blocked => 'Продажа в долг заблокирована';

  @override
  String get notification_kind_order_status => 'Статус заказа';

  @override
  String get notification_kind_payment_status => 'Оплата';

  @override
  String get notification_kind_return_status => 'Заявка на возврат';

  @override
  String get notification_kind_sync_error => 'Ошибка синхронизации';

  @override
  String get notification_kind_system => 'Система';

  @override
  String get notifications_action_details => 'Подробнее';

  @override
  String get notifications_action_not_me => 'Это не я';

  @override
  String get notifications_action_open_cart => 'Открыть корзину';

  @override
  String notifications_bell_a11y(int count) {
    return 'Уведомления, $count непрочитанных';
  }

  @override
  String get notifications_day_today => 'Сегодня';

  @override
  String get notifications_day_yesterday => 'Вчера';

  @override
  String get notifications_empty_filtered => 'Нет уведомлений выбранного вида';

  @override
  String get notifications_empty_title => 'Уведомлений нет';

  @override
  String get notifications_filter_all => 'Все';

  @override
  String get notifications_filter_kind_cart => 'Корзина';

  @override
  String get notifications_filter_kind_debt => 'Долг';

  @override
  String get notifications_filter_kind_orders => 'Заказы';

  @override
  String get notifications_filter_kind_payment => 'Оплата';

  @override
  String get notifications_filter_kind_returns => 'Возвраты';

  @override
  String get notifications_filter_kind_sync => 'Синхронизация';

  @override
  String get notifications_filter_kind_system => 'Система';

  @override
  String notifications_filter_unread(int count) {
    return 'Непрочитанные ($count)';
  }

  @override
  String notifications_item_unread_a11y(String time, String title) {
    return 'Непрочитанное: $title, $time';
  }

  @override
  String get notifications_mark_read => 'Отметить прочитанным';

  @override
  String notifications_new_above(int count) {
    return '$count новое / новых уведомления(-й)';
  }

  @override
  String get notifications_read_all => 'Прочитать все';

  @override
  String get notifications_reset_filters => 'Сбросить фильтры';

  @override
  String notifications_stale_banner(String time) {
    return 'Уведомления обновлены в $time';
  }

  @override
  String get notifications_title => 'Уведомления';

  @override
  String notifications_unread(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count непрочитанных',
      many: '$count непрочитанных',
      few: '$count непрочитанных',
      one: '$count непрочитанное',
      zero: 'Уведомлений нет',
    );
    return '$_temp0';
  }

  @override
  String get notifications_view_all => 'Все уведомления';

  @override
  String get order_action_cancel => 'Отменить заказ';

  @override
  String get order_action_cancel_request => 'Запросить отмену';

  @override
  String get order_action_pay => 'Принять оплату';

  @override
  String get order_action_repeat => 'Повторить заказ';

  @override
  String get order_action_return => 'Заявка на возврат';

  @override
  String get order_action_show_qr => 'Показать QR';

  @override
  String order_banner_cancel_requested(String time) {
    return 'Запрос отмены отправлен в 1С $time';
  }

  @override
  String get order_banner_dead => 'Требуется вмешательство администратора: заказ не отправлен в 1С';

  @override
  String get order_banner_match_ambiguous =>
      'Заказ не удалось однозначно сопоставить с документом 1С. Нужна ручная привязка';

  @override
  String order_banner_rejected(String reason) {
    return '1С отклонила заказ: $reason';
  }

  @override
  String get order_banner_submitting => 'Ожидает отправки в 1С';

  @override
  String order_banner_total_adjusted(String newValue, String old) {
    return 'Итог уточнён 1С: было $old, стало $newValue';
  }

  @override
  String order_cancel_dialog_title(String number) {
    return 'Отменить заказ № $number?';
  }

  @override
  String get order_cancel_keep => 'Не отменять';

  @override
  String get order_cancel_money_advance => 'Оставить авансом';

  @override
  String get order_cancel_money_refund => 'Вернуть деньги клиенту';

  @override
  String get order_cancel_reason_customer_refused => 'Клиент отказался';

  @override
  String get order_cancel_reason_duplicate => 'Дубль';

  @override
  String get order_cancel_reason_error => 'Ошибка оформления';

  @override
  String get order_cancel_reason_other => 'Другое';

  @override
  String get order_cancel_reason_required => 'Укажите причину отмены';

  @override
  String get order_cancel_requested_snackbar => 'Запрос отмены отправлен в 1С';

  @override
  String order_cancel_unavailable(String status) {
    return 'Отмена недоступна в статусе «$status»';
  }

  @override
  String get order_cancelled_snackbar => 'Заказ отменён';

  @override
  String get order_created_accept_payment => 'Принять оплату';

  @override
  String order_created_admin_handoff(String number) {
    return 'Оплату примет кассир. Заказ № $number';
  }

  @override
  String get order_created_banner_dead => 'Заказ не удалось отправить в 1С — администратор получил уведомление';

  @override
  String get order_created_banner_submitting =>
      'Заказ сохранён и будет отправлен в 1С автоматически. Счёт можно напечатать после получения номера 1С';

  @override
  String order_created_cash_handoff(String number, String total) {
    return 'Передайте клиента в кассу. Заказ № $number, к оплате $total';
  }

  @override
  String order_created_credit_due(String date) {
    return 'Продажа в долг · оплатить до $date';
  }

  @override
  String get order_created_credit_due_agreement => 'Срок оплаты — по соглашению в 1С';

  @override
  String get order_created_customer_pay_hint => 'Оплатите заказ в кассе магазина';

  @override
  String order_created_customer_pay_on_pickup(String number) {
    return 'Оплата при получении. Заявка № $number отправлена в магазин на согласование';
  }

  @override
  String get order_created_customer_qr_hint =>
      'Оплатите заявку по QR — магазин получит подтверждение оплаты автоматически';

  @override
  String get order_created_doc_failed => 'Не удалось напечатать · Повторить';

  @override
  String get order_created_doc_printed => 'Напечатан';

  @override
  String get order_created_doc_queued => 'В очереди на печать';

  @override
  String get order_created_manual_amount_label => 'Сумма поступления';

  @override
  String get order_created_manual_amount_mismatch => 'Сумма отличается от заказа: платёж уйдёт на разбор';

  @override
  String get order_created_manual_comment_label => 'Комментарий';

  @override
  String get order_created_manual_confirm => 'Подтвердить оплату вручную';

  @override
  String get order_created_manual_ref_label => 'Референс банка / номер из выписки';

  @override
  String get order_created_manual_ref_required => 'Введите референс из выписки банка (не короче 4 символов)';

  @override
  String get order_created_manual_time_label => 'Время поступления';

  @override
  String get order_created_new_order => 'Новый заказ';

  @override
  String order_created_number(String number) {
    return 'Заказ № $number';
  }

  @override
  String get order_created_onec_pending => 'Ожидает отправки в 1С';

  @override
  String get order_created_open_order => 'Открыть заказ';

  @override
  String get order_created_other_method => 'Другой способ оплаты';

  @override
  String get order_created_other_method_seller => 'Сменить способ оплаты может кассир';

  @override
  String get order_created_paid => 'Оплата получена';

  @override
  String get order_created_paid_auto => 'Получено автоматически';

  @override
  String get order_created_paid_manual => 'Оплата подтверждена вручную';

  @override
  String get order_created_payment_state_changed => 'Статус платежа изменился. Данные обновлены';

  @override
  String get order_created_qr_expired => 'Срок QR истёк';

  @override
  String get order_created_qr_forming => 'Формируем QR…';

  @override
  String get order_created_qr_none =>
      'QR не сформирован банком. Покажите клиенту QR-табличку кассы; оплату подтвердит кассир';

  @override
  String order_created_qr_purpose(String number) {
    return 'Оплата заказа $number · Бакай Банк';
  }

  @override
  String get order_created_qr_reissue => 'Перевыпустить QR';

  @override
  String get order_created_qr_show_customer => 'Показать покупателю';

  @override
  String get order_created_qr_static => 'QR торговой точки, без срока действия';

  @override
  String get order_created_qr_title => 'Оплата по QR · Бакай Банк';

  @override
  String get order_created_qr_unavailable => 'QR временно недоступен. Покажите QR-табличку или выберите другой способ';

  @override
  String get order_created_qr_unavailable_onec =>
      'QR не получен из 1С. Покажите QR-табличку кассы — оплату подтвердит кассир — или выберите другой способ';

  @override
  String order_created_qr_valid_until(String left, String time) {
    return 'Действует до $time · осталось $left';
  }

  @override
  String get order_created_review_amount => 'Сумма оплаты не совпадает с заказом — требуется разбор кассиром';

  @override
  String get order_created_review_late => 'Оплата поступила после истечения QR — требуется разбор кассиром';

  @override
  String get order_created_review_reference => 'Платёж с неизвестным референсом — требуется разбор';

  @override
  String get order_created_title => 'Заказ создан';

  @override
  String get order_created_waiting_payment => 'Ожидаем оплату';

  @override
  String order_credit_paid_of(String paid, String time, String total) {
    return 'Долг по заказу: оплачено $paid из $total (по данным 1С от $time)';
  }

  @override
  String get order_customer_card_link => 'Карточка ›';

  @override
  String get order_doc_after_payment => 'После оплаты';

  @override
  String get order_doc_download => 'Скачать PDF';

  @override
  String get order_doc_pdn_warning =>
      'Файл содержит персональные данные клиента. Не сохраняйте его в общие папки терминала';

  @override
  String get order_doc_preview => 'Просмотр';

  @override
  String get order_doc_print => 'Печать';

  @override
  String get order_doc_waiting_number => 'Ожидает номер 1С';

  @override
  String get order_doc_waybill => 'Накладная';

  @override
  String get order_doc_waybill_from_onec => 'Печатается из 1С при отгрузке';

  @override
  String order_due_date(String date) {
    return 'Оплатить до $date';
  }

  @override
  String get order_history_collapse => 'Свернуть историю';

  @override
  String get order_history_show_all => 'Показать всю историю';

  @override
  String get order_history_source_app => 'Приложение';

  @override
  String get order_history_source_onec => '1С';

  @override
  String get order_not_found => 'Заказ не найден или недоступен';

  @override
  String order_onec_freshness(String time) {
    return 'Статус из 1С: $time · Обновить';
  }

  @override
  String get order_onec_link_action => 'Привязать к документу 1С';

  @override
  String order_onec_link_body(String number) {
    return 'Выберите документ 1С, соответствующий заказу № $number, или введите его номер';
  }

  @override
  String get order_onec_link_confirm => 'Привязать';

  @override
  String order_onec_link_done(String onecNumber) {
    return 'Заказ привязан к документу 1С № $onecNumber';
  }

  @override
  String get order_onec_link_number => 'Номер документа 1С';

  @override
  String get order_onec_link_reason => 'Причина привязки';

  @override
  String get order_onec_link_title => 'Привязка к документу 1С';

  @override
  String order_onec_number(String date, String number) {
    return '№ 1С $number от $date';
  }

  @override
  String get order_onec_refresh => 'Обновить';

  @override
  String order_onec_unavailable_snackbar(String time) {
    return '1С недоступна, показаны данные от $time';
  }

  @override
  String order_paid_of(String paid, String total) {
    return 'Оплачено $paid из $total';
  }

  @override
  String get order_payments_empty => 'Платежей нет';

  @override
  String get order_repeat_add => 'Добавить к текущей';

  @override
  String order_repeat_dialog_body(int count) {
    return 'В корзине $count позиций. Добавить позиции заказа к текущей корзине или отложить текущую?';
  }

  @override
  String get order_repeat_park_and_new => 'Отложить текущую и начать новую';

  @override
  String order_repeat_progress(int count, int n) {
    return 'Добавляем $n из $count…';
  }

  @override
  String order_repeat_skipped(int count) {
    return 'Не добавлено: $count (снято с продажи)';
  }

  @override
  String get order_scan_hint => 'Сканирование номера заказа доступно в списке заказов';

  @override
  String get order_section_documents => 'Документы';

  @override
  String get order_section_history => 'История статусов';

  @override
  String get order_section_payments => 'Платежи';

  @override
  String order_title(String number) {
    return 'Заказ № $number';
  }

  @override
  String get orders_chip_all => 'Все';

  @override
  String get orders_chip_awaiting_payment => 'Ждут оплаты';

  @override
  String get orders_chip_cancelled => 'Отменены и отклонены';

  @override
  String get orders_chip_closed => 'Закрыты';

  @override
  String orders_chip_count(int count, String label) {
    return '$label · $count';
  }

  @override
  String get orders_chip_in_progress => 'В работе';

  @override
  String get orders_chip_shipped => 'Отгружены';

  @override
  String get orders_col_customer => 'Клиент';

  @override
  String get orders_col_date => 'Дата';

  @override
  String get orders_col_number => '№';

  @override
  String get orders_col_paid => 'Оплачено';

  @override
  String get orders_col_status => 'Статус';

  @override
  String get orders_col_total => 'Сумма';

  @override
  String get orders_empty_create => 'Создать заказ';

  @override
  String get orders_empty_filtered_title => 'Ничего не найдено по выбранным фильтрам';

  @override
  String get orders_empty_no_orders_title => 'Заказов пока нет';

  @override
  String get orders_empty_search_body => 'Проверьте запрос или отсканируйте штрихкод';

  @override
  String orders_empty_search_title(String q) {
    return 'Ничего не найдено по „$q“';
  }

  @override
  String get orders_filters => 'Фильтры';

  @override
  String orders_found_count(int count) {
    return 'Найдено: $count за период';
  }

  @override
  String get orders_load_failed => 'Не удалось загрузить заказы · Повторить';

  @override
  String get orders_paid_credit => 'Долг';

  @override
  String get orders_paid_full => 'Оплачен';

  @override
  String orders_paid_partial(String paid, String total) {
    return '$paid из $total';
  }

  @override
  String get orders_paid_unpaid => 'Не оплачен';

  @override
  String get orders_period_7_days => '7 дней';

  @override
  String get orders_period_custom => 'Период…';

  @override
  String get orders_period_month => 'Месяц';

  @override
  String get orders_period_today => 'Сегодня';

  @override
  String get orders_period_yesterday => 'Вчера';

  @override
  String get orders_refresh => 'Обновить';

  @override
  String get orders_reset_filters => 'Сбросить фильтры';

  @override
  String orders_scan_not_found(String number) {
    return 'Заказ с номером $number не найден';
  }

  @override
  String get orders_scope_all => 'Все';

  @override
  String get orders_scope_mine => 'Мои';

  @override
  String get orders_search_hint => 'Номер заказа POS или 1С';

  @override
  String get orders_sort_newest => 'Сначала новые';

  @override
  String get orders_sort_status => 'По статусу';

  @override
  String get orders_sort_total => 'По сумме';

  @override
  String orders_stale(String time) {
    return 'Данные от $time';
  }

  @override
  String get orders_title => 'Заказы';

  @override
  String get orders_title_mine => 'Мои заказы';

  @override
  String otp_attempts_left(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Осталось попыток: $count',
      one: 'Осталось попыток: $count',
    );
    return '$_temp0';
  }

  @override
  String parked_active_not_empty_body(int count) {
    return 'В корзине уже есть $count позиций. Отложить текущую корзину и продолжить выбранный заказ?';
  }

  @override
  String get parked_active_not_empty_confirm => 'Отложить текущую и продолжить';

  @override
  String parked_card_expires(String days) {
    return 'Удалится через $days дн.';
  }

  @override
  String get parked_card_expires_tomorrow => 'Удалится завтра';

  @override
  String parked_card_items_total(int count, String total) {
    return '$count позиций · $total (предварительно)';
  }

  @override
  String get parked_delete_conflict => 'Заказ изменился. Список обновлён';

  @override
  String parked_delete_dialog_author(String owner) {
    return 'Автор: $owner';
  }

  @override
  String parked_delete_dialog_body(int count, String name) {
    return 'Заказ «$name» ($count позиций) будет удалён без возможности восстановления';
  }

  @override
  String get parked_delete_dialog_confirm => 'Удалить';

  @override
  String get parked_delete_dialog_title => 'Удалить отложенный заказ?';

  @override
  String get parked_delete_tooltip => 'Удалить отложенный заказ';

  @override
  String get parked_deleted_snackbar => 'Отложенный заказ удалён';

  @override
  String get parked_empty_back_to_cart => 'Вернуться в корзину';

  @override
  String get parked_empty_body => 'Отложенный заказ сохраняется кнопкой «Отложить заказ» в корзине';

  @override
  String get parked_empty_title => 'Отложенных заказов нет';

  @override
  String get parked_not_available => 'Заказ уже недоступен';

  @override
  String get parked_offline_tooltip => 'Нужна сеть';

  @override
  String get parked_owner_readonly =>
      'Просмотр отложенных заказов. Продолжить заказ может продавец или старший продавец';

  @override
  String parked_restored_chip(String number) {
    return 'Восстановлен из заказа № $number';
  }

  @override
  String get parked_resume => 'Продолжить';

  @override
  String parked_resumed_foreign_snackbar(String name, String owner) {
    return 'Заказ «$name» автора $owner продолжен вами';
  }

  @override
  String get parked_scope_all => 'Все';

  @override
  String get parked_scope_mine => 'Мои';

  @override
  String get parked_title => 'Отложенные заказы';

  @override
  String payment_already_paid(String paid, String total) {
    return 'Заказ уже оплачен: $paid из $total';
  }

  @override
  String payment_breakdown(String discount, String paid, String percent, String subtotal, String total) {
    return 'Товары $subtotal · Скидка $percent −$discount · Итого $total · Оплачено $paid';
  }

  @override
  String payment_change(String amount) {
    return 'Сдача: $amount';
  }

  @override
  String get payment_check => 'Проверить';

  @override
  String get payment_close_confirm => 'Закрыть без приёма оплаты?';

  @override
  String payment_close_qr_note(String time) {
    return 'QR останется активным до $time, оплата будет видна в заказе';
  }

  @override
  String payment_confirm_body_cash(String amount, String change, String customer, String received) {
    return 'Клиент: $customer. К оплате $amount, получено $received, сдача $change';
  }

  @override
  String get payment_confirm_cta => 'Подтвердить приём';

  @override
  String get payment_confirm_title => 'Подтвердите приём оплаты';

  @override
  String payment_credit_blocked_limit(String remaining) {
    return 'Превышен лимит: доступно $remaining';
  }

  @override
  String get payment_credit_blocked_onec => '1С недоступна: продажа в долг невозможна, выберите наличные или QR';

  @override
  String payment_credit_blocked_overdue(String amount) {
    return 'Продажа в долг недоступна: есть просроченная задолженность $amount';
  }

  @override
  String get payment_credit_blocked_seller => 'Продажа в долг недоступна: обратитесь к старшему продавцу';

  @override
  String get payment_credit_blocked_stale => 'Данные о долге устарели';

  @override
  String get payment_credit_checking => 'Проверяем долг…';

  @override
  String get payment_credit_choose_other => 'Выберите наличные или QR';

  @override
  String payment_credit_confirm(String amount, String date) {
    return 'Зафиксировать продажу в долг на $amount? Срок оплаты: $date';
  }

  @override
  String payment_credit_order_info(String date) {
    return 'Заказ оформлен в долг. Срок оплаты: $date. Деньги по заказу принимаются как оплата долга клиента';
  }

  @override
  String get payment_credit_override => 'Разрешить продажу в долг';

  @override
  String get payment_credit_override_reason => 'Причина разрешения (не менее 5 символов)';

  @override
  String payment_cta_accept(String amount) {
    return 'Принять $amount';
  }

  @override
  String get payment_debt_all => 'Всё сальдо';

  @override
  String get payment_debt_alloc_explicit => 'Выбрать документы';

  @override
  String get payment_debt_alloc_fifo => 'Автоматически (FIFO, как в 1С)';

  @override
  String get payment_debt_amount => 'Сумма оплаты';

  @override
  String payment_debt_context(String balance, String customer) {
    return 'Долг клиента $customer · сальдо $balance';
  }

  @override
  String payment_debt_exceeds(String balance) {
    return 'Сумма больше сальдо $balance';
  }

  @override
  String payment_debt_forecast(String amount) {
    return 'Остаток после оплаты (прогноз): $amount';
  }

  @override
  String get payment_debt_overdue => 'Просроченное';

  @override
  String get payment_debt_pending_onec => 'Платёж принят, ожидает отражения в 1С';

  @override
  String get payment_done => 'Готово';

  @override
  String get payment_manual_mismatch => 'Сумма не совпадает: платёж отправлен на разбор';

  @override
  String get payment_manual_reference => 'Референс банка или номер выписки';

  @override
  String get payment_manual_reference_error => 'Введите референс от 4 до 64 символов';

  @override
  String get payment_manual_title => 'Подтверждение оплаты по выписке';

  @override
  String get payment_method_cash => 'Наличными в кассу';

  @override
  String get payment_method_cash_sub => 'Оплата в нашем магазине';

  @override
  String get payment_method_credit => 'Без оплаты / долг';

  @override
  String get payment_method_credit_sub => 'Оплата позже (по согласованию)';

  @override
  String get payment_method_qr => 'QR / карта Бакай Банк';

  @override
  String get payment_method_qr_sub => 'Оплата картой по QR';

  @override
  String get payment_method_title => 'Способ оплаты';

  @override
  String payment_not_payable(String status) {
    return 'Оплата недоступна для заказа в статусе «$status»';
  }

  @override
  String get payment_offline => 'Нет сети: оплата невозможна';

  @override
  String get payment_onec_confirmed => 'Отражено в 1С';

  @override
  String get payment_onec_manual => 'Оформите ПКО в 1С';

  @override
  String get payment_onec_pending => 'Ожидает отражения в 1С';

  @override
  String get payment_open_qr_exists =>
      'По заказу открыт QR-платёж. Сначала проверьте поступление по выписке или аннулируйте QR';

  @override
  String payment_order_context(String customer, String number) {
    return 'Заказ № $number · $customer';
  }

  @override
  String get payment_other_method => 'Другой способ оплаты';

  @override
  String get payment_print_failed => 'Не удалось напечатать чек';

  @override
  String get payment_print_receipt => 'Товарный чек (нефискальный, 80 мм)';

  @override
  String get payment_qr_auto_note => 'После оплаты заказ будет автоматически отмечен как оплаченный';

  @override
  String get payment_qr_create_error => 'Не удалось сформировать QR';

  @override
  String get payment_qr_creating => 'Формируем QR…';

  @override
  String get payment_qr_expired => 'Срок QR истёк';

  @override
  String get payment_qr_manual_note => 'После оплаты кассир подтвердит поступление по выписке';

  @override
  String get payment_qr_reissue => 'Обновить QR';

  @override
  String get payment_qr_show_customer => 'Показать покупателю';

  @override
  String get payment_qr_switch_confirm => 'Отменить QR-оплату и принять наличными?';

  @override
  String get payment_qr_switch_senior_hint => 'Отмена QR доступна кассиру';

  @override
  String get payment_qr_unavailable =>
      'Банк недоступен для QR. Покажите статический QR и подтвердите оплату вручную или выберите другой способ';

  @override
  String get payment_qr_unavailable_onec =>
      '1С не сформировала QR. Покажите статический QR и подтвердите оплату вручную или выберите другой способ';

  @override
  String payment_qr_valid_until(String number, String time) {
    return 'Заказ № $number · действует до $time';
  }

  @override
  String get payment_qr_waiting => 'Ожидаем оплату';

  @override
  String get payment_quick_exact => 'Без сдачи';

  @override
  String get payment_received_label => 'Получено от клиента';

  @override
  String get payment_received_less => 'Получено меньше суммы к оплате';

  @override
  String get payment_review_amount_mismatch => 'Требует проверки: сумма не совпадает';

  @override
  String get payment_review_late_payment => 'Требует проверки: оплата после истечения QR';

  @override
  String get payment_review_no_webhook => 'Ожидает подтверждения по выписке';

  @override
  String get payment_review_unknown_reference => 'Требует проверки: неизвестная ссылка платежа';

  @override
  String get payment_scan_disabled => 'Сканирование недоступно во время оплаты';

  @override
  String payment_success(String amount) {
    return 'Принято $amount';
  }

  @override
  String payment_success_change(String amount) {
    return 'Сдача $amount';
  }

  @override
  String payment_success_number(String number) {
    return 'Платёж № $number';
  }

  @override
  String get payment_title => 'Приём оплаты';

  @override
  String get payment_to_pay => 'К оплате';

  @override
  String get payment_unknown => 'Связь прервалась. Проверьте результат — деньги не принимайте повторно';

  @override
  String get payment_unknown_close_confirm => 'Закрыть? Результат операции неизвестен';

  @override
  String get payment_unknown_discard => 'Отменить операцию';

  @override
  String get payment_unknown_discard_body =>
      'Отменяйте, только если деньги не принимались: после отмены проверить результат будет нельзя';

  @override
  String get pending_activated_snackbar => 'Аккаунт активирован';

  @override
  String get pending_blocked_body => 'Аккаунт заблокирован администратором. Обратитесь в магазин';

  @override
  String get pending_blocked_title => 'Аккаунт заблокирован';

  @override
  String get pending_body =>
      'Администратор магазина должен подтвердить ваш аккаунт и назначить роль. Обычно это занимает до 1 рабочего дня';

  @override
  String get pending_check => 'Проверить статус';

  @override
  String get pending_check_error => 'Не удалось проверить статус';

  @override
  String pending_checked_at(String time) {
    return 'проверено $time';
  }

  @override
  String get pending_contact_shop => 'Связаться с магазином';

  @override
  String get pending_field_name => 'ФИО';

  @override
  String get pending_field_phone => 'Телефон';

  @override
  String get pending_field_registered => 'Зарегистрирован';

  @override
  String get pending_logout => 'Выйти из аккаунта';

  @override
  String get pending_logout_body => 'Чтобы войти снова, понадобится код из SMS';

  @override
  String get pending_logout_title => 'Выйти из аккаунта?';

  @override
  String pending_status_active(String role) {
    return 'активирован · $role';
  }

  @override
  String get pending_status_blocked => 'заблокирован';

  @override
  String get pending_status_checking => 'проверяем…';

  @override
  String get pending_status_waiting => 'ожидает активации';

  @override
  String get pending_title => 'Аккаунт ожидает активации';

  @override
  String product_added_snackbar(String qty, String unit) {
    return 'Добавлено $qty $unit · Открыть корзину';
  }

  @override
  String product_barcodes(String values) {
    return 'Штрихкод: $values';
  }

  @override
  String product_barcodes_more(int count) {
    return 'ещё $count';
  }

  @override
  String product_cta_add(String sum) {
    return 'В корзину · $sum';
  }

  @override
  String get product_cta_add_more => 'Добавить ещё';

  @override
  String get product_cta_out_of_stock => 'Нет в наличии';

  @override
  String get product_cta_unavailable => 'Добавление недоступно';

  @override
  String get product_description_collapse => 'Свернуть';

  @override
  String get product_description_expand => 'Читать полностью';

  @override
  String get product_description_title => 'Описание';

  @override
  String get product_discontinued_banner => 'Товар больше не продаётся';

  @override
  String product_gallery_counter_a11y(int count, String index) {
    return 'Фото $index из $count';
  }

  @override
  String product_in_cart(String qty, String unit) {
    return 'В корзине: $qty $unit';
  }

  @override
  String get product_not_found_title => 'Товар не найден или снят с продажи';

  @override
  String product_onec_code(String code) {
    return 'Код 1С: $code';
  }

  @override
  String product_other_warehouse(String qty, String unit, String warehouse) {
    return 'Есть на складе «$warehouse»: $qty $unit. Продажа с другого склада одним заказом — вне R1';
  }

  @override
  String get product_price_list_tooltip => 'Вид цены по клиенту корзины или по умолчанию для роли';

  @override
  String get product_price_lists_all => 'Все виды цен';

  @override
  String get product_price_missing_hint => 'Нет цены — обратитесь к администратору';

  @override
  String product_price_per_pack(String pack, String price) {
    return 'За $pack: $price';
  }

  @override
  String product_price_unit(String unit) {
    return '/ $unit';
  }

  @override
  String get product_price_your => 'Ваша цена';

  @override
  String get product_qty_reduce_hint => 'Уменьшите количество в корзине';

  @override
  String product_qty_rules(String min, String multiple, String unit) {
    return 'Кратность $multiple $unit · мин. партия $min $unit';
  }

  @override
  String get product_qty_title => 'Количество';

  @override
  String get product_sku_copied => 'Артикул скопирован';

  @override
  String get product_sku_missing => 'Артикул не указан';

  @override
  String get product_sku_product_note => 'артикул товара';

  @override
  String product_sku_variant(String sku) {
    return 'Арт. варианта: $sku';
  }

  @override
  String product_specs_show_all(int count) {
    return 'Показать все ($count)';
  }

  @override
  String get product_specs_title => 'Характеристики';

  @override
  String get product_stock_cart_warehouse => 'склад корзины';

  @override
  String get product_stock_columns => 'Склад · Остаток · Резерв · Доступно';

  @override
  String get product_stock_empty => 'Нет данных по складам';

  @override
  String get product_stock_error => 'Не удалось получить остатки · Повторить';

  @override
  String get product_stock_title => 'Остатки по складам';

  @override
  String product_stock_total(String qty, String unit) {
    return 'Доступно всего: $qty $unit';
  }

  @override
  String get product_unit_title => 'Единица';

  @override
  String product_variant_axis(String axis, String value) {
    return '$axis: $value';
  }

  @override
  String get product_variant_combination_missing => 'Нет такого сочетания';

  @override
  String product_variant_select_error(String axis) {
    return 'Выберите $axis';
  }

  @override
  String get product_warehouses_tab => 'Склады';

  @override
  String get profile_activity_hint => 'Например: сантехника, строительство';

  @override
  String get profile_activity_label => 'Сфера деятельности (необязательно)';

  @override
  String profile_avatar_a11y(String name, String role) {
    return 'Профиль: $name, $role';
  }

  @override
  String profile_avatar_a11y_name(String name) {
    return 'Профиль: $name';
  }

  @override
  String profile_birthyear_error_range(String maxYear) {
    return 'Год рождения от 1920 до $maxYear';
  }

  @override
  String get profile_birthyear_label => 'Год рождения (необязательно)';

  @override
  String get profile_conflict => 'Профиль изменён на другом устройстве. Проверьте и сохраните ещё раз';

  @override
  String get profile_customer_link_title => 'Клиент 1С';

  @override
  String get profile_customer_link_waiting => 'Ожидает подтверждения администратором';

  @override
  String get profile_discard_confirm => 'Отменить изменения?';

  @override
  String get profile_edit_button => 'Изменить данные';

  @override
  String get profile_fullname_error_length => 'От 2 до 150 символов';

  @override
  String get profile_fullname_error_required => 'Введите ФИО';

  @override
  String get profile_fullname_label => 'ФИО';

  @override
  String profile_last_login(String device, String time) {
    return 'Вход: $device · $time';
  }

  @override
  String profile_login_device(String deviceName, String time) {
    return 'Вход: $deviceName · $time';
  }

  @override
  String get profile_logout => 'Выйти';

  @override
  String get profile_logout_all => 'Выйти на всех устройствах';

  @override
  String get profile_logout_all_confirm => 'Все сеансы, включая этот, будут завершены. Потребуется вход по SMS';

  @override
  String get profile_logout_all_done => 'Вы вышли на всех устройствах';

  @override
  String get profile_logout_anyway => 'Выйти всё равно';

  @override
  String get profile_logout_confirm => 'Выйти из аккаунта?';

  @override
  String get profile_logout_offline_done => 'Вы вышли. Сессия на сервере будет завершена при появлении сети';

  @override
  String get profile_logout_unsynced_cart => 'В корзине есть неотправленные изменения';

  @override
  String get profile_menu_lock => 'Заблокировать';

  @override
  String get profile_menu_my_orders => 'Мои заказы';

  @override
  String get profile_menu_my_transactions => 'Мои транзакции';

  @override
  String get profile_menu_notifications => 'Уведомления';

  @override
  String get profile_menu_settings => 'Настройки';

  @override
  String get profile_menu_switch_user => 'Сменить пользователя';

  @override
  String get profile_menu_sync => 'Синхронизация';

  @override
  String get profile_not_specified => 'Не указано';

  @override
  String get profile_offline_action_disabled => 'Недоступно без сети';

  @override
  String get profile_phone_abort_confirm => 'Прервать смену номера?';

  @override
  String get profile_phone_change => 'Сменить номер телефона';

  @override
  String get profile_phone_change_confirm =>
      'После смены номера вход выполняется по новому номеру. Все другие устройства будут отключены';

  @override
  String get profile_phone_changed => 'Номер изменён. Другие устройства отключены';

  @override
  String profile_phone_code_sent(String phone) {
    return 'Код отправлен на $phone';
  }

  @override
  String get profile_phone_error_format => 'Введите 9 цифр номера';

  @override
  String get profile_phone_error_same => 'Это ваш текущий номер';

  @override
  String get profile_phone_error_taken => 'Этот номер уже используется другим пользователем';

  @override
  String get profile_phone_get_code => 'Получить код';

  @override
  String get profile_phone_new_label => 'Новый номер телефона';

  @override
  String get profile_phone_resend => 'Отправить код ещё раз';

  @override
  String profile_phone_resend_in(int seconds) {
    return 'Отправить код повторно через $seconds с';
  }

  @override
  String get profile_r2_badge => 'Скоро';

  @override
  String get profile_saved => 'Данные сохранены';

  @override
  String profile_stale_banner(String time) {
    return 'Данные профиля от $time';
  }

  @override
  String get profile_title => 'Профиль';

  @override
  String get profile_update_available => 'Доступно обновление';

  @override
  String get profile_value_not_set => 'Не указано';

  @override
  String profile_version(String build, String platform, String version) {
    return 'Версия $version ($build) · $platform';
  }

  @override
  String get qty_delete => 'Удалить';

  @override
  String qty_error_below_min(String min, String unit) {
    return 'Минимальная партия — $min $unit';
  }

  @override
  String qty_error_not_multiple(String m, String unit) {
    return 'Количество должно быть кратно $m $unit';
  }

  @override
  String get qty_error_pack_integer => 'Количество упаковок должно быть целым';

  @override
  String qty_error_precision(int n, String unit) {
    return 'Для единицы „$unit“ допустимо не более $n знаков после запятой';
  }

  @override
  String qty_error_stock(String available, String unit, String warehouse) {
    return 'Доступно только $available $unit на складе «$warehouse»';
  }

  @override
  String get qty_error_too_large => 'Слишком большое количество';

  @override
  String qty_hint_rules(String available, String min, String multiple, String unit) {
    return 'Кратность: $multiple $unit · Мин. партия: $min $unit · Доступно: $available $unit';
  }

  @override
  String get qty_key_backspace_a11y => 'стереть';

  @override
  String get qty_key_decimal_a11y => 'запятая';

  @override
  String qty_key_digit_a11y(String d) {
    return 'цифра $d';
  }

  @override
  String qty_offline_note(String time) {
    return 'Доступно по данным от $time';
  }

  @override
  String qty_pack_conversion(String base, String pack, String packs, String unit) {
    return '$packs $pack = $base $unit';
  }

  @override
  String qty_quick_add(int count) {
    return '+$count';
  }

  @override
  String qty_round_up(String next) {
    return 'Округлить до $next';
  }

  @override
  String qty_sheet_title(String name) {
    return 'Количество · $name';
  }

  @override
  String get qty_zero_delete_hint => '0 — удалить позицию из корзины';

  @override
  String receivable_overdue_days(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Просрочка $count дня',
      many: 'Просрочка $count дней',
      few: 'Просрочка $count дня',
      one: 'Просрочка $count день',
    );
    return '$_temp0';
  }

  @override
  String get receivables_accept_payment => 'Принять оплату по долгу';

  @override
  String receivables_as_of(String time) {
    return 'Данные 1С на $time';
  }

  @override
  String get receivables_available => 'Доступно (прогноз)';

  @override
  String get receivables_balance_advance => 'Аванс';

  @override
  String get receivables_balance_debt => 'Долг';

  @override
  String get receivables_balance_zero => 'Долга нет';

  @override
  String get receivables_col_amount => 'Сумма';

  @override
  String get receivables_col_date => 'Дата';

  @override
  String get receivables_col_document => 'Документ';

  @override
  String get receivables_col_due => 'Срок оплаты';

  @override
  String get receivables_col_overdue_days => 'Просрочка';

  @override
  String get receivables_col_paid => 'Оплачено';

  @override
  String get receivables_col_remaining => 'Остаток';

  @override
  String get receivables_col_status => 'Статус';

  @override
  String get receivables_credit_allowed => 'Продажа в долг возможна';

  @override
  String get receivables_credit_blocked_limit => 'Продажа в долг недоступна: лимит исчерпан';

  @override
  String get receivables_credit_blocked_no_data => 'Продажа в долг недоступна: нет данных из 1С о просрочке или лимите';

  @override
  String get receivables_credit_blocked_overdue => 'Продажа в долг недоступна: есть просроченная задолженность';

  @override
  String get receivables_credit_blocked_stale => 'Продажа в долг недоступна: данные о долге устарели';

  @override
  String get receivables_credit_not_allowed => 'Отсрочка по соглашению не разрешена';

  @override
  String get receivables_detail_cancelled => 'Детализация не открыта';

  @override
  String get receivables_detail_empty => 'Документов с остатком нет';

  @override
  String get receivables_detail_locked_body =>
      'Для просмотра документов подтвердите личность. Просмотр записывается в журнал';

  @override
  String get receivables_detail_locked_title => 'Детализация по документам';

  @override
  String get receivables_detail_not_kept => 'Детализация расчётов в 1С не ведётся';

  @override
  String receivables_detail_open_until(String time) {
    return 'Детализация открыта до $time · просмотр записан в аудит';
  }

  @override
  String get receivables_detail_show => 'Показать детализацию';

  @override
  String receivables_detail_step_up_reason(String customer) {
    return 'Просмотр детализации долга: $customer';
  }

  @override
  String receivables_doc_due_until(String date) {
    return 'Ожидает оплаты до $date';
  }

  @override
  String receivables_doc_overdue_n(String days) {
    return 'Просрочен $days дн.';
  }

  @override
  String get receivables_doc_paid => 'Оплачен';

  @override
  String get receivables_filter_all => 'Все';

  @override
  String get receivables_filter_discounts => 'Скидки и корректировки';

  @override
  String get receivables_filter_orders => 'Заказы';

  @override
  String get receivables_filter_overdue => 'Просроченные';

  @override
  String get receivables_filter_payments => 'Платежи';

  @override
  String get receivables_filter_returns => 'Возвраты';

  @override
  String get receivables_filter_shipments => 'Реализации';

  @override
  String get receivables_limit => 'Лимит';

  @override
  String get receivables_limit_none => 'Лимит: нет данных';

  @override
  String get receivables_load_error => 'Не удалось загрузить долг клиента';

  @override
  String get receivables_no_data => 'Нет данных из 1С';

  @override
  String get receivables_offline => 'Данные о долге недоступны без сети';

  @override
  String get receivables_open_orders => 'Открытые заказы в долг';

  @override
  String receivables_overdue(String amount, int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days дня',
      many: '$days дней',
      few: '$days дня',
      one: '$days день',
    );
    return 'Просрочено $amount · $_temp0';
  }

  @override
  String get receivables_refresh => 'Обновить';

  @override
  String receivables_refresh_onec_down(String time) {
    return '1С недоступна, показаны данные от $time';
  }

  @override
  String receivables_stale(String time) {
    return 'Данные могут быть неактуальны (от $time)';
  }

  @override
  String receivables_term(String days) {
    return 'Отсрочка: $days дн.';
  }

  @override
  String get receivables_title => 'Долги и взаиморасчёты';

  @override
  String get reg_activity_consent_label =>
      'Согласен(на) на обработку сведений о сфере деятельности (необязательно; можно отозвать в настройках)';

  @override
  String get reg_activity_foreman => 'Прораб, строитель';

  @override
  String get reg_activity_installer => 'Монтажная организация';

  @override
  String get reg_activity_none => 'Не указывать';

  @override
  String get reg_activity_other => 'Другое';

  @override
  String get reg_activity_other_hint => 'Уточните сферу (до 60 символов)';

  @override
  String get reg_activity_placeholder => 'Выберите из списка';

  @override
  String get reg_activity_plumber => 'Сантехник';

  @override
  String get reg_activity_private => 'Частное лицо';

  @override
  String get reg_activity_reseller => 'Магазин, перепродажа';

  @override
  String get reg_bio_available => 'доступно';

  @override
  String get reg_bio_consent_label => 'Разрешаю вход по биометрии устройства (можно отключить в настройках)';

  @override
  String get reg_bio_failed_set_pin => 'Биометрия не включена. Задайте PIN-код, чтобы входить в приложение';

  @override
  String get reg_bio_later => 'Настроить биометрию позже';

  @override
  String get reg_bio_later_windows => 'Без Windows Hello';

  @override
  String get reg_bio_not_enabled => 'Биометрия не включена. Вход — по PIN-коду. Включить можно в настройках';

  @override
  String get reg_bio_not_enrolled => 'Настройте отпечаток или распознавание лица в настройках устройства';

  @override
  String get reg_bio_open_settings => 'Открыть настройки';

  @override
  String get reg_bio_tile_title => 'Биометрия устройства';

  @override
  String get reg_bio_unsupported => 'Недоступно на этом устройстве';

  @override
  String get reg_bio_windows_hello => 'Windows Hello — только для быстрого входа перед PIN, не заменяет PIN';

  @override
  String get reg_birth_year_placeholder => 'ГГГГ';

  @override
  String get reg_cancel_body => 'Введённые данные сохранятся на этом устройстве 15 минут';

  @override
  String get reg_cancel_confirm => 'Прервать';

  @override
  String get reg_cancel_continue => 'Продолжить заполнение';

  @override
  String get reg_cancel_title => 'Прервать регистрацию?';

  @override
  String get reg_complete => 'Завершить регистрацию';

  @override
  String get reg_complete_offline => 'Нужна сеть, чтобы завершить регистрацию';

  @override
  String get reg_continue => 'Продолжить';

  @override
  String reg_error_birth_year_range(String maxYear, String minYear) {
    return 'Введите год от $minYear до $maxYear';
  }

  @override
  String get reg_error_birth_year_required => 'Укажите год рождения';

  @override
  String get reg_error_consent_required =>
      'Чтобы продолжить, подтвердите, что ознакомлены с условиями обработки данных';

  @override
  String get reg_error_name_invalid => 'Используйте только буквы, пробел и дефис';

  @override
  String get reg_error_name_length => 'ФИО должно содержать от 2 до 120 символов';

  @override
  String get reg_error_name_required => 'Введите фамилию и имя';

  @override
  String get reg_error_network => 'Не удалось завершить регистрацию. Данные сохранены — повторите';

  @override
  String get reg_error_pin_mismatch => 'PIN-коды не совпадают';

  @override
  String get reg_error_pin_weak => 'Выберите PIN без повторяющихся или последовательных цифр';

  @override
  String get reg_error_token_expired =>
      'Время регистрации истекло. Подтвердите номер ещё раз — введённые данные сохранятся';

  @override
  String get reg_expired_action => 'Подтвердить номер снова';

  @override
  String get reg_field_activity => 'Сфера деятельности (необязательно)';

  @override
  String get reg_field_birth_year => 'Год рождения *';

  @override
  String get reg_field_name => 'ФИО *';

  @override
  String get reg_field_name_hint => 'Фамилия, имя и отчество (если есть)';

  @override
  String get reg_field_phone => 'Телефон';

  @override
  String get reg_form_subtitle => 'Эти данные увидит администратор магазина';

  @override
  String get reg_form_title => 'Расскажите о себе';

  @override
  String get reg_header => 'Регистрация';

  @override
  String get reg_hint_activity_consent => 'Без согласия сфера деятельности не будет сохранена';

  @override
  String get reg_next => 'Далее';

  @override
  String get reg_pd_ack_label => 'Я ознакомлен(а) с условиями обработки персональных данных *';

  @override
  String get reg_pd_more => 'Подробнее';

  @override
  String get reg_phone_change => 'Изменить';

  @override
  String get reg_phone_verified => 'подтверждён';

  @override
  String reg_pin_a11y(String length, int n) {
    return 'PIN, введено $n из $length';
  }

  @override
  String get reg_pin_create => 'Придумайте PIN-код';

  @override
  String get reg_pin_repeat => 'Повторите PIN-код';

  @override
  String reg_pin_rules_hint(String length) {
    return '$length цифр, без повторов и простых последовательностей';
  }

  @override
  String get reg_pin_tile_optional => 'Можно выключить, если включена биометрия';

  @override
  String get reg_pin_tile_required => 'Обязателен для сотрудников: нужен для разблокировки и подтверждения операций';

  @override
  String get reg_pin_tile_title => 'PIN-код приложения';

  @override
  String get reg_protection_required => 'Выберите способ защиты входа: PIN-код или биометрию';

  @override
  String get reg_restored_banner => 'Мы восстановили введённые ранее данные';

  @override
  String get reg_security_subtitle => 'Чтобы не вводить код из SMS при каждом входе';

  @override
  String get reg_security_title => 'Защита входа';

  @override
  String get reg_staff_first_complete => 'Начать работу';

  @override
  String get reg_staff_first_subtitle =>
      'Вы вошли по приглашению администратора. PIN нужен для разблокировки и подтверждения операций';

  @override
  String get reg_staff_first_title => 'Задайте PIN-код для работы';

  @override
  String get reg_step_customer_link => 'Привязка';

  @override
  String get reg_step_data => 'Данные';

  @override
  String get reg_step_done => 'Готово';

  @override
  String get reg_step_face => 'Лицо';

  @override
  String get reg_step_security => 'Защита входа';

  @override
  String reg_stepper_compact(int n, String name, String total) {
    return 'Шаг $n из $total · $name';
  }

  @override
  String get reg_success_pending => 'Аккаунт создан. Администратор магазина активирует его и назначит роль';

  @override
  String get reg_success_security_pin => 'Вход настроен: PIN-код';

  @override
  String get reg_success_security_pin_bio => 'Вход настроен: PIN-код · биометрия';

  @override
  String reg_success_title(String name) {
    return 'Добро пожаловать, $name!';
  }

  @override
  String reg_timer(String mmss) {
    return 'Время на регистрацию: ещё $mmss';
  }

  @override
  String get reg_warning_name_one_word => 'Укажите фамилию и имя полностью — так администратору проще вас найти';

  @override
  String get register_consent_pd_text =>
      'Оператор (владелец записей): <полное наименование магазина, ИНН, адрес, контакт ответственного за персональные данные>. Цели: создание учётной записи и вход по номеру телефона, оформление заказов, взаиморасчёты, обеспечение безопасности. Данные: номер телефона, фамилия, имя, отчество, год рождения (для идентификации при обращениях и восстановлении доступа), идентификатор устройства, технические данные сессии. Основание: исполнение договора (условий работы с магазином) и законные интересы оператора по обеспечению безопасности (ст. 79 Цифрового кодекса КР). Срок: период использования учётной записи и до <N> лет после — в части, необходимой для бухгалтерского учёта. Права: доступ, уточнение, удаление (с ограничениями ст. 83), возражение, ограничение обработки, отзыв согласия — через раздел «Профиль → Персональные данные» или по контакту ответственного. Передача: данные хранятся на сервере в Кыргызской Республике; передача за пределы КР не осуществляется. Нажимая «Продолжить», вы подтверждаете, что ознакомлены с этой информацией.';

  @override
  String get register_security_consent_text =>
      'Вы можете включить быстрый вход с помощью отпечатка пальца или распознавания лица, встроенных в ваше устройство. Приложение не получает, не сохраняет и не передаёт изображение лица или отпечаток: проверку выполняет операционная система, а приложение узнаёт только её результат. Включение необязательно; вместо этого можно использовать PIN-код приложения. Отключить можно в любой момент в настройках, при этом потребуется повторный вход по SMS-коду.';

  @override
  String get reports_audit_link => 'Аудит';

  @override
  String get reports_avg_check => 'Средний чек';

  @override
  String reports_cancelled(int count) {
    return 'Отменено: $count';
  }

  @override
  String get reports_card_debts => 'Долги';

  @override
  String get reports_card_qr => 'QR-сверка';

  @override
  String get reports_card_sales => 'Продажи';

  @override
  String reports_debt_as_of(String time) {
    return 'По данным 1С на $time';
  }

  @override
  String get reports_debt_bucket_0_30 => '0–30 дней';

  @override
  String get reports_debt_bucket_31_60 => '31–60';

  @override
  String get reports_debt_bucket_61_90 => '61–90';

  @override
  String get reports_debt_bucket_90_plus => 'более 90';

  @override
  String get reports_debt_overdue => 'Просрочено';

  @override
  String reports_debt_stale(String time) {
    return 'Данные 1С от $time могут быть неактуальны';
  }

  @override
  String get reports_debt_total => 'Общий долг';

  @override
  String get reports_discount_total => 'Скидки';

  @override
  String get reports_empty_debts => 'Долгов нет';

  @override
  String get reports_empty_qr => 'QR-платежей нет';

  @override
  String get reports_empty_sales => 'Продаж за период нет';

  @override
  String get reports_export_confirm_action => 'Выгрузить';

  @override
  String reports_export_confirm_body(String period, String report) {
    return '«$report» за $period. Файл содержит финансовые данные';
  }

  @override
  String get reports_export_confirm_title => 'Выгрузить в CSV?';

  @override
  String get reports_export_csv => 'Экспорт CSV';

  @override
  String get reports_export_done => 'Файл сохранён';

  @override
  String get reports_export_error => 'Не удалось выгрузить файл. Повторите';

  @override
  String get reports_export_open => 'Открыть';

  @override
  String get reports_export_r2_tooltip => 'Экспорт будет доступен в следующей версии';

  @override
  String get reports_groupby_day => 'Дни';

  @override
  String get reports_groupby_method => 'Способы оплаты';

  @override
  String get reports_groupby_month => 'Месяцы';

  @override
  String get reports_groupby_seller => 'Продавцы';

  @override
  String get reports_groupby_warehouse => 'Склады';

  @override
  String get reports_groupby_week => 'Недели';

  @override
  String get reports_method_cash => 'Наличные';

  @override
  String get reports_method_credit => 'В долг';

  @override
  String get reports_method_qr => 'QR Бакай Банк';

  @override
  String reports_orders_count(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count заказа',
      many: '$count заказов',
      few: '$count заказа',
      one: '$count заказ',
    );
    return '$_temp0';
  }

  @override
  String get reports_paid_total => 'Оплачено';

  @override
  String reports_parked_link(int count) {
    return 'Отложенные заказы ($count)';
  }

  @override
  String get reports_parked_link_nocount => 'Отложенные заказы';

  @override
  String get reports_period_error => 'Период не больше 366 дней';

  @override
  String get reports_qr_filter_all => 'Все';

  @override
  String get reports_qr_filter_manual => 'Вручную';

  @override
  String get reports_qr_filter_unmatched => 'Расхождения';

  @override
  String get reports_qr_manual => 'Подтверждено вручную';

  @override
  String get reports_qr_unmatched => 'Расхождения';

  @override
  String get reports_qr_webhook => 'Подтверждено банком';

  @override
  String get reports_source_onec => 'из 1С';

  @override
  String get reports_title => 'Отчёты';

  @override
  String get return_accept => 'Согласовать заявку';

  @override
  String get return_accept_body => 'Заявка будет согласована в приложении. Документ возврата и деньги оформляются в 1С';

  @override
  String get return_accept_title => 'Согласовать заявку на возврат?';

  @override
  String get return_accepted => 'Заявка согласована';

  @override
  String get return_already_in_onec => 'Заявка уже передана в 1С: согласование и отклонение — в 1С';

  @override
  String return_amount(String amount) {
    return 'Предварительно: $amount';
  }

  @override
  String get return_comment_label => 'Комментарий';

  @override
  String get return_comment_required => 'Опишите причину (не менее 10 символов)';

  @override
  String return_completed(String document) {
    return 'Возврат оформлен в 1С: $document';
  }

  @override
  String return_delete_body(String number) {
    return 'Черновик заявки по заказу № $number будет удалён без возможности восстановления';
  }

  @override
  String get return_delete_draft => 'Удалить черновик';

  @override
  String get return_delete_title => 'Удалить черновик заявки?';

  @override
  String get return_deleted => 'Черновик заявки удалён';

  @override
  String get return_disabled => 'Возвраты оформляются в 1С';

  @override
  String get return_draft_saved => 'Черновик сохранён';

  @override
  String return_foreign_draft(String name) {
    return 'Черновик сотрудника $name';
  }

  @override
  String return_item_exceeds(String max) {
    return 'Больше, чем можно вернуть ($max)';
  }

  @override
  String get return_item_fully_returned => 'возвращено полностью';

  @override
  String return_item_max(String max) {
    return 'Можно вернуть: $max';
  }

  @override
  String return_item_sold_returned(String returned, String sold) {
    return 'Продано $sold, возвращено $returned';
  }

  @override
  String get return_items_required => 'Выберите хотя бы одну позицию';

  @override
  String get return_items_title => 'Позиции к возврату';

  @override
  String get return_leave_body => 'Выбранные позиции не сохранятся';

  @override
  String get return_leave_title => 'Выйти без сохранения?';

  @override
  String get return_no_previous_data => 'Нет данных о прежних возвратах — количество будет проверено в 1С';

  @override
  String get return_not_found => 'Заявка не найдена';

  @override
  String get return_not_returnable => 'Возврат недоступен: заказ не отгружен';

  @override
  String get return_offline_hint => 'Нет сети: сохранение и отправка недоступны';

  @override
  String get return_offline_no_data => 'Заявка недоступна без сети';

  @override
  String get return_onec_note =>
      'Документ возврата, приход на склад и возврат денег оформляются в 1С. Приложение передаёт заявку';

  @override
  String get return_reason_defect => 'Брак';

  @override
  String get return_reason_not_suitable => 'Не подошёл';

  @override
  String get return_reason_other => 'Иное';

  @override
  String get return_reason_required => 'Выберите причину возврата';

  @override
  String get return_reason_seller_error => 'Ошибка продавца';

  @override
  String get return_reason_surplus => 'Излишек';

  @override
  String get return_reason_title => 'Причина возврата (обязательно)';

  @override
  String get return_reason_wrong_item => 'Пересорт';

  @override
  String get return_refund_kind_cash => 'Наличными';

  @override
  String get return_refund_kind_offset => 'Зачесть в долг';

  @override
  String get return_refund_kind_qr => 'QR';

  @override
  String get return_reject => 'Отклонить заявку';

  @override
  String get return_reject_reason_error => 'Укажите причину (не менее 5 символов)';

  @override
  String get return_reject_reason_label => 'Причина отклонения';

  @override
  String get return_reject_title => 'Отклонить заявку на возврат?';

  @override
  String return_rejected(String reason) {
    return 'Заявка отклонена: $reason';
  }

  @override
  String get return_rejected_done => 'Заявка отклонена';

  @override
  String get return_save_draft => 'Сохранить черновик';

  @override
  String get return_select_all => 'Выбрать всё';

  @override
  String return_source(String date, String order, String shipment) {
    return 'Заказ № $order от $date · Реализация $shipment';
  }

  @override
  String return_status_as_of(String time) {
    return 'Статус из 1С на $time';
  }

  @override
  String return_step_up_decision(String number) {
    return 'Решение по заявке на возврат № $number';
  }

  @override
  String return_step_up_reason(String amount, String number) {
    return 'Отправка заявки на возврат на $amount по заказу № $number';
  }

  @override
  String get return_submit => 'Отправить заявку';

  @override
  String get return_submitted => 'Заявка отправлена в 1С';

  @override
  String get return_threshold =>
      'Сумма заявки превышает порог. Отправить может старший продавец или администратор в своей сессии. Черновик сохранён';

  @override
  String get return_title_new => 'Заявка на возврат';

  @override
  String return_title_view(String number) {
    return 'Возврат № $number';
  }

  @override
  String get return_unknown => 'Связь прервалась. Проверьте результат — заявка могла быть сохранена';

  @override
  String get return_version_conflict => 'Заявка изменена на другом устройстве. Данные обновлены';

  @override
  String get role_admin => 'Администратор';

  @override
  String get role_cashier => 'Кассир';

  @override
  String get role_customer => 'Клиент';

  @override
  String get role_integration => 'Интеграция';

  @override
  String get role_owner => 'Руководитель';

  @override
  String get role_seller => 'Продавец';

  @override
  String get role_senior_seller => 'Старший продавец';

  @override
  String scan_added(String name, String qty, String unit) {
    return '+$qty $unit · $name';
  }

  @override
  String get scan_ambiguous => 'Штрихкод привязан к нескольким товарам, проверьте выбор';

  @override
  String get scan_camera_error => 'Камера недоступна. Закройте другие приложения, использующие камеру';

  @override
  String scan_choose_variant(int count) {
    return 'Найдено $count вариантов. Выберите вариант';
  }

  @override
  String scan_hid_result(String name, String qty, String unit, String value) {
    return 'Отсканировано $value · $name +$qty $unit';
  }

  @override
  String get scan_hid_waiting => 'Сканер: ожидание. USB/Bluetooth-сканер в режиме клавиатуры, суффикс Enter';

  @override
  String get scan_hint => 'Наведите камеру на штрихкод товара или упаковки';

  @override
  String get scan_hint_order => 'Наведите камеру на штрихкод или QR-код с распечатки заказа';

  @override
  String get scan_invalid_code => 'Штрихкод не распознан, попробуйте ещё раз';

  @override
  String get scan_lookup_error => 'Не удалось проверить штрихкод · Повторить';

  @override
  String get scan_manual_entry => 'Ввести вручную';

  @override
  String get scan_no_camera_body => 'Разрешите доступ к камере в настройках устройства';

  @override
  String scan_not_found(String value) {
    return 'Штрихкод $value не найден';
  }

  @override
  String scan_offline_note(String time) {
    return 'Поиск по сохранённому каталогу от $time';
  }

  @override
  String get scan_open_product => 'Открыть карточку';

  @override
  String get scan_open_settings => 'Открыть настройки';

  @override
  String scan_order_value(String value) {
    return 'Номер: $value';
  }

  @override
  String get scan_series => 'Серия';

  @override
  String scan_series_summary(int count) {
    return 'Добавлено $count позиций';
  }

  @override
  String scan_test_result(String format, String value) {
    return 'Распознано: $value · $format';
  }

  @override
  String get scan_title => 'Сканирование';

  @override
  String get scan_title_order => 'Сканирование номера заказа';

  @override
  String get scan_title_test => 'Проверка камеры-сканера';

  @override
  String get scan_torch_off_a11y => 'Выключить фонарик';

  @override
  String get scan_torch_on_a11y => 'Включить фонарик';

  @override
  String get search_badge_barcode_exact => 'штрихкод (точно)';

  @override
  String get search_badge_name => 'название';

  @override
  String get search_badge_sku => 'артикул';

  @override
  String get search_badge_sku_prefix => 'артикул (начало)';

  @override
  String get search_barcode_ambiguous => 'Штрихкод привязан к нескольким товарам, проверьте выбор';

  @override
  String get search_barcode_not_found_body => 'Возможно, товар не выгружен из 1С';

  @override
  String search_barcode_not_found_title(String value) {
    return 'Штрихкод $value не найден';
  }

  @override
  String get search_empty_body => 'Проверьте запрос или отсканируйте штрихкод';

  @override
  String get search_enter_manually => 'Ввести вручную';

  @override
  String get search_error_inline => 'Не удалось выполнить поиск · Повторить';

  @override
  String get search_field_a11y => 'Поиск товара';

  @override
  String search_found_count(int count, String query) {
    return 'Найдено: $count по «$query»';
  }

  @override
  String search_found_estimate(int count, String query) {
    return 'Найдено: около $count по «$query»';
  }

  @override
  String search_hint_more_chars(int count) {
    return 'Введите ещё $count символ / символа — для артикула и штрихкода любой длины';
  }

  @override
  String get search_match_all => 'Все';

  @override
  String get search_match_barcode => 'Штрихкод';

  @override
  String get search_match_name => 'Название';

  @override
  String get search_match_sku => 'Артикул';

  @override
  String get search_not_found_hint => 'Не нашли? Проверьте раскладку клавиатуры или отсканируйте штрихкод';

  @override
  String search_offline_note(String time) {
    return 'Поиск по сохранённому каталогу от $time';
  }

  @override
  String get search_placeholder => 'Поиск товара по названию, коду или штрих-коду…';

  @override
  String get search_recent_queries_title => 'Недавние запросы';

  @override
  String get search_scan_again => 'Сканировать снова';

  @override
  String get search_scanner_tooltip => 'Сканировать штрихкод';

  @override
  String get search_scope_all => 'Во всех категориях';

  @override
  String search_scope_category(String name) {
    return 'В категории «$name»';
  }

  @override
  String search_suggested_query(String query) {
    return 'Возможно, вы искали «$query»';
  }

  @override
  String get search_title => 'Результаты поиска';

  @override
  String settings_about_device_id(String suffix) {
    return 'Идентификатор устройства: …$suffix';
  }

  @override
  String get settings_about_licenses => 'Лицензии';

  @override
  String get settings_about_min_version => 'Минимальная поддерживаемая версия';

  @override
  String get settings_about_privacy => 'Политика обработки персональных данных';

  @override
  String get settings_about_recommended_version => 'Рекомендуемая версия';

  @override
  String get settings_about_support => 'Техническая поддержка';

  @override
  String get settings_about_version => 'Версия';

  @override
  String get settings_autolock_label => 'Автоблокировка';

  @override
  String settings_autolock_value(int minutes) {
    return 'Через $minutes мин';
  }

  @override
  String get settings_bio_android => 'Вход по отпечатку или лицу';

  @override
  String get settings_bio_cancelled => 'Биометрия не подтверждена. Вход по биометрии не включён';

  @override
  String get settings_bio_consent_check => 'Согласен';

  @override
  String get settings_bio_consent_title => 'Согласие на вход по биометрии';

  @override
  String get settings_bio_disable_confirm => 'Вход по биометрии будет отключён на этом устройстве';

  @override
  String get settings_bio_enable => 'Включить';

  @override
  String get settings_bio_enabled => 'Вход по биометрии включён';

  @override
  String get settings_bio_ios => 'Вход по Face ID / Touch ID';

  @override
  String get settings_bio_open_system => 'Настроить в системе';

  @override
  String get settings_bio_unavailable => 'Биометрия на устройстве недоступна или не настроена';

  @override
  String get settings_bio_windows => 'Windows Hello перед вводом PIN';

  @override
  String get settings_bio_windows_note =>
      'Windows Hello только подтверждает присутствие. Вход всегда завершается PIN приложения';

  @override
  String get settings_conflict => 'Настройки изменены на другом устройстве. Показаны актуальные значения';

  @override
  String get settings_density_auto => 'Авто';

  @override
  String get settings_density_compact => 'Компактная';

  @override
  String get settings_density_label => 'Плотность';

  @override
  String get settings_density_standard => 'Стандартная';

  @override
  String get settings_device_name_error => 'От 1 до 60 символов';

  @override
  String get settings_language_en => 'English';

  @override
  String get settings_language_ky => 'Кыргызча';

  @override
  String get settings_language_ru => 'Русский';

  @override
  String get settings_language_soon => 'Скоро';

  @override
  String get settings_offline_disabled => 'Недоступно без сети';

  @override
  String get settings_pin_abort_confirm => 'Прервать смену PIN?';

  @override
  String get settings_pin_change => 'Сменить PIN';

  @override
  String get settings_pin_changed => 'PIN изменён';

  @override
  String get settings_pin_error_mismatch => 'PIN не совпадает. Введите ещё раз';

  @override
  String get settings_pin_error_weak =>
      'Слишком простой PIN: не используйте одинаковые цифры, последовательности и год рождения';

  @override
  String get settings_pin_forgot => 'Забыли PIN?';

  @override
  String get settings_pin_new_title => 'Новый PIN';

  @override
  String get settings_pin_repeat_title => 'Повторите PIN';

  @override
  String get settings_pin_required_staff => 'Для сотрудников PIN обязателен';

  @override
  String get settings_pin_status_set => 'PIN приложения: установлен';

  @override
  String settings_print_error(String reason) {
    return 'Не удалось напечатать: $reason';
  }

  @override
  String get settings_print_test => 'Тестовая печать';

  @override
  String get settings_print_test_ok => 'Тестовая страница отправлена на принтер';

  @override
  String get settings_print_test_page_title => 'ТЕСТОВАЯ ПЕЧАТЬ · не является фискальным документом';

  @override
  String get settings_printer_address => 'Адрес принтера';

  @override
  String get settings_printer_address_error => 'Введите адрес принтера, например 192.168.1.50';

  @override
  String get settings_printer_autoprint => 'Печатать автоматически после создания заказа';

  @override
  String get settings_printer_default => 'Принтер по умолчанию';

  @override
  String get settings_printer_format_80mm => 'Чек 80 мм';

  @override
  String get settings_printer_format_a4 => 'A4';

  @override
  String get settings_printer_port => 'Порт';

  @override
  String get settings_printer_port_error => 'Порт от 1 до 65535';

  @override
  String settings_privacy_policy_version(String date) {
    return 'Версия от $date';
  }

  @override
  String get settings_protection_last_method =>
      'Нельзя выключить единственный способ защиты входа. Сначала включите другой';

  @override
  String get settings_reduce_motion => 'Уменьшить анимации';

  @override
  String get settings_require_pin_label => 'Требовать PIN при запуске';

  @override
  String get settings_save_error => 'Не удалось сохранить настройку. Значение возвращено';

  @override
  String get settings_scanner_add_to_cart => 'Сразу добавлять в корзину';

  @override
  String get settings_scanner_interval_label => 'Интервал между символами';

  @override
  String settings_scanner_interval_value(String ms) {
    return '$ms мс';
  }

  @override
  String get settings_scanner_mode_camera => 'Камера';

  @override
  String get settings_scanner_mode_hid => 'Аппаратный (HID)';

  @override
  String get settings_scanner_no_suffix => 'Сканер не отправил окончание. Выберите «Без суффикса» или настройте сканер';

  @override
  String get settings_scanner_suffix_enter => 'Enter';

  @override
  String get settings_scanner_suffix_label => 'Окончание скана';

  @override
  String get settings_scanner_suffix_none => 'Без суффикса';

  @override
  String get settings_scanner_suffix_tab => 'Tab';

  @override
  String get settings_scanner_test_camera => 'Проверить камерой';

  @override
  String settings_scanner_test_found(String name, String sku) {
    return 'Найден: $name · арт. $sku';
  }

  @override
  String get settings_scanner_test_hint => 'Отсканируйте любой штрихкод…';

  @override
  String settings_scanner_test_not_found(String code) {
    return 'Штрихкод $code не найден в каталоге';
  }

  @override
  String get settings_section_about => 'О приложении';

  @override
  String get settings_section_display => 'Отображение';

  @override
  String get settings_section_language => 'Язык';

  @override
  String get settings_section_printer => 'Принтер';

  @override
  String get settings_section_scanner => 'Сканер штрихкодов';

  @override
  String get settings_section_security => 'Защита входа';

  @override
  String get settings_section_sessions => 'Устройства и сессии';

  @override
  String get settings_session_rename => 'Переименовать';

  @override
  String get settings_session_revoke => 'Завершить';

  @override
  String settings_session_revoke_confirm(String device) {
    return 'Завершить сеанс на устройстве $device?';
  }

  @override
  String get settings_session_revoke_error => 'Не удалось завершить сеанс. Повторите';

  @override
  String get settings_session_revoked => 'Сеанс завершён';

  @override
  String settings_sessions_last_active(String time) {
    return 'Активность: $time';
  }

  @override
  String get settings_sessions_load_error => 'Не удалось загрузить список устройств';

  @override
  String settings_sessions_stale_banner(String time) {
    return 'Список устройств от $time';
  }

  @override
  String get settings_sessions_this_device => 'Это устройство';

  @override
  String settings_stale_caption(String time) {
    return 'Настройки от $time';
  }

  @override
  String get settings_text_scale_label => 'Размер текста';

  @override
  String get settings_text_scale_large => 'Крупнее';

  @override
  String get settings_text_scale_system => 'Системный';

  @override
  String get settings_text_scale_xlarge => 'Крупный';

  @override
  String get settings_title => 'Настройки';

  @override
  String get shell_menu_open => 'Меню разделов';

  @override
  String get shell_nav_a11y => 'Навигация';

  @override
  String get shell_nav_more => 'Другие разделы';

  @override
  String get splash_init_error_body => 'Повторите попытку. Если ошибка повторяется, обратитесь в поддержку';

  @override
  String get splash_init_error_title => 'Не удалось запустить приложение';

  @override
  String get splash_logo_a11y => 'Логотип Оптомстрой';

  @override
  String get splash_status_checking => 'Проверяем сессию…';

  @override
  String get splash_status_refreshing => 'Обновляем данные…';

  @override
  String splash_version(String build, String version) {
    return 'Версия $version ($build)';
  }

  @override
  String splash_version_terminal(String build, String deviceName, String version) {
    return 'Версия $version ($build) · $deviceName';
  }

  @override
  String get status_cart_parked => 'Отложен';

  @override
  String get status_invitation_accepted => 'Принято';

  @override
  String get status_invitation_expired => 'Истекло';

  @override
  String get status_invitation_pending => 'Ожидает';

  @override
  String get status_invitation_revoked => 'Отозвано';

  @override
  String get status_link_confirmed => 'Подтверждена';

  @override
  String get status_link_conflict => 'Конфликт';

  @override
  String get status_link_proposed => 'Ожидает подтверждения';

  @override
  String get status_link_rejected => 'Отклонена';

  @override
  String get status_order_approved => 'Согласован';

  @override
  String get status_order_awaiting_payment => 'Ожидает оплаты';

  @override
  String get status_order_awaiting_shipment => 'Ожидает отгрузки';

  @override
  String get status_order_cancelled => 'Отменён';

  @override
  String get status_order_closed => 'Закрыт';

  @override
  String get status_order_draft => 'Черновик (технический)';

  @override
  String get status_order_partially_returned => 'Частично возвращён';

  @override
  String get status_order_pending_approval => 'На согласовании';

  @override
  String get status_order_shipped => 'Отгружен';

  @override
  String get status_order_submit_failed => 'Отклонён 1С';

  @override
  String get status_order_submitting => 'Ожидает отправки в 1С';

  @override
  String get status_payment_cash_pending => 'Ожидает оплаты наличными';

  @override
  String get status_payment_credit => 'В долг';

  @override
  String get status_payment_initiated => 'Создан';

  @override
  String get status_payment_manual_confirm => 'Подтверждён вручную, на проверке';

  @override
  String get status_payment_qr_expired => 'Срок QR истёк';

  @override
  String get status_payment_qr_pending => 'Формируется QR';

  @override
  String get status_payment_qr_shown => 'Ожидаем оплату';

  @override
  String get status_payment_received => 'Получен';

  @override
  String get status_payment_refunded => 'Возвращён';

  @override
  String get status_payment_voided => 'Аннулирован';

  @override
  String get status_sync_failed => 'Ошибка';

  @override
  String get status_sync_partial => 'Частично';

  @override
  String get status_sync_queued => 'В очереди';

  @override
  String get status_sync_running => 'Выполняется';

  @override
  String get status_sync_success => 'Успешно';

  @override
  String get status_user_active => 'Активен';

  @override
  String get status_user_blocked => 'Заблокирован';

  @override
  String get status_user_deleted => 'Удалён';

  @override
  String get status_user_pending => 'Не завершена регистрация';

  @override
  String get status_user_pending_activation => 'Ожидает активации';

  @override
  String get stepup_by_sms => 'Подтвердить кодом из SMS';

  @override
  String get stepup_offline => 'Нужна сеть для подтверждения';

  @override
  String get stepup_pin_locked => 'PIN заблокирован. Подтвердите кодом из SMS';

  @override
  String get stepup_pin_not_set => 'PIN не задан. Подтвердите кодом из SMS и задайте PIN в настройках';

  @override
  String get stepup_reuse_hint => 'Повторно в течение 15 минут подтверждать не потребуется';

  @override
  String get stepup_send_code => 'Отправить код';

  @override
  String stepup_sms_confirm(String phoneMasked) {
    return 'Отправить код на $phoneMasked?';
  }

  @override
  String get stepup_tab_pin => 'PIN';

  @override
  String get stepup_tab_sms => 'Код из SMS';

  @override
  String get stepup_verifying => 'Проверяем…';

  @override
  String get stock_badge_in_stock => 'В наличии';

  @override
  String stock_badge_in_stock_qty(String qty, String unit) {
    return 'В наличии · $qty $unit';
  }

  @override
  String get stock_badge_low => 'Мало';

  @override
  String stock_badge_low_qty(String qty, String unit) {
    return 'Мало · $qty $unit';
  }

  @override
  String sync_checked_at(String time) {
    return 'Проверено $time · обновляется каждые 30 с';
  }

  @override
  String get sync_empty_errors => 'Ошибок нет';

  @override
  String get sync_empty_outbox => 'Очередь пуста';

  @override
  String get sync_empty_runs => 'Прогонов за период нет';

  @override
  String get sync_entity_attributes => 'Характеристики';

  @override
  String get sync_entity_barcodes => 'Штрихкоды';

  @override
  String get sync_entity_categories => 'Категории';

  @override
  String get sync_entity_customers => 'Клиенты';

  @override
  String get sync_entity_discounts => 'Скидки';

  @override
  String get sync_entity_images => 'Фото';

  @override
  String get sync_entity_order_status => 'Статусы заказов';

  @override
  String get sync_entity_payment_docs => 'Платёжные документы';

  @override
  String get sync_entity_prices => 'Цены';

  @override
  String get sync_entity_products => 'Товары';

  @override
  String get sync_entity_receivables => 'Долги';

  @override
  String get sync_entity_return_docs => 'Документы возвратов';

  @override
  String get sync_entity_sales_history => 'История продаж';

  @override
  String get sync_entity_stock => 'Остатки';

  @override
  String get sync_entity_units => 'Единицы';

  @override
  String get sync_entity_variants => 'Варианты';

  @override
  String get sync_entity_warehouses => 'Склады';

  @override
  String sync_errors_count(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count ошибки подряд',
      many: '$count ошибок подряд',
      few: '$count ошибки подряд',
      one: '$count ошибка подряд',
    );
    return '$_temp0';
  }

  @override
  String sync_interval(int minutes) {
    return 'каждые $minutes мин';
  }

  @override
  String sync_last_success(String time) {
    return 'Последний успешный обмен: $time';
  }

  @override
  String sync_local_updated_at(String time) {
    return 'Каталог на устройстве обновлён $time';
  }

  @override
  String get sync_manual_run_inbound_mode => 'Обмен запускает 1С: ручной запуск недоступен';

  @override
  String get sync_mode_full => 'Полная загрузка';

  @override
  String get sync_mode_incremental => 'Только изменения';

  @override
  String get sync_mode_reconcile => 'Сверка';

  @override
  String get sync_never => 'Ещё не синхронизировано';

  @override
  String sync_next_run(String time) {
    return 'Следующий: $time';
  }

  @override
  String get sync_onec_reachable => '1С доступна';

  @override
  String get sync_onec_unreachable => '1С недоступна';

  @override
  String get sync_outbox_already_sent => 'Документ уже отправлен в 1С';

  @override
  String sync_outbox_counts(String dead, String failed, String pending) {
    return 'В очереди $pending · Ошибки $failed · Отказы $dead';
  }

  @override
  String get sync_outbox_retried => 'Поставлено в очередь';

  @override
  String get sync_outbox_retry => 'Повторить';

  @override
  String sync_outbox_retry_confirm(String number) {
    return 'Повторить отправку $number в 1С? Убедитесь, что причина ошибки устранена';
  }

  @override
  String get sync_overall_degraded => 'Есть задержки';

  @override
  String get sync_overall_failed => 'Обмен нарушен';

  @override
  String get sync_overall_ok => 'Обмен работает';

  @override
  String get sync_permission_hint => 'Ручной запуск выполняет старший продавец или администратор';

  @override
  String sync_rate_limited(int seconds) {
    return 'Слишком частый запуск. Повторите через $seconds с';
  }

  @override
  String get sync_run_button_busy => 'Обновляем…';

  @override
  String get sync_run_button_order_status => 'Обновить статусы';

  @override
  String get sync_run_button_prices => 'Обновить цены';

  @override
  String get sync_run_button_stock => 'Обновить остатки';

  @override
  String get sync_run_dialog_entity => 'Что синхронизировать';

  @override
  String get sync_run_dialog_mode => 'Режим';

  @override
  String get sync_run_dialog_title => 'Запуск синхронизации';

  @override
  String get sync_run_done => 'завершена';

  @override
  String get sync_run_failed => 'Синхронизация не выполнена';

  @override
  String sync_run_full_warning(int minutes) {
    return 'Полная загрузка увеличивает нагрузку на 1С и может занять до $minutes мин. Рекомендуется вне рабочего времени';
  }

  @override
  String get sync_run_full_warning_no_estimate =>
      'Полная загрузка увеличивает нагрузку на 1С и может занять продолжительное время. Рекомендуется вне рабочего времени';

  @override
  String get sync_run_open_dialog => 'Запустить…';

  @override
  String sync_run_partial(int count) {
    return 'Завершено с ошибками: $count';
  }

  @override
  String get sync_run_started => 'Синхронизация запущена';

  @override
  String sync_running_for(int minutes) {
    return 'идёт $minutes мин';
  }

  @override
  String sync_stale_banner(String entity, int minutes) {
    return '$entity: данные старше $minutes мин';
  }

  @override
  String get sync_tab_entities => 'Сущности';

  @override
  String get sync_tab_errors => 'Ошибки';

  @override
  String get sync_tab_outbox => 'Outbox';

  @override
  String get sync_tab_runs => 'Прогоны';

  @override
  String get sync_title => 'Синхронизация с 1С';

  @override
  String get sync_trigger_auto => 'Автоматически';

  @override
  String get sync_trigger_dependency => 'По зависимости';

  @override
  String sync_trigger_manual(String name) {
    return 'Вручную: $name';
  }

  @override
  String get sync_trigger_retry => 'Повтор';

  @override
  String get sync_trigger_schedule => 'По расписанию';

  @override
  String get transaction_details_action_accept => 'Принять оплату';

  @override
  String get transaction_details_action_confirm_manual => 'Подтвердить вручную';

  @override
  String get transaction_details_action_open_order => 'Открыть заказ';

  @override
  String get transaction_details_action_print => 'Печать';

  @override
  String get transaction_details_action_return => 'Заявка на возврат';

  @override
  String get transaction_details_action_void => 'Аннулировать платёж';

  @override
  String get transaction_details_audit => 'Аудит';

  @override
  String get transaction_details_audit_all => 'Все записи';

  @override
  String get transaction_details_author => 'Автор';

  @override
  String get transaction_details_back_to_list => 'К журналу операций';

  @override
  String get transaction_details_change => 'Сдача';

  @override
  String get transaction_details_confirm_done => 'Оплата подтверждена';

  @override
  String get transaction_details_confirm_reference => 'Референс банка или номер выписки';

  @override
  String get transaction_details_confirm_reference_error => 'Введите референс от 4 до 64 символов';

  @override
  String get transaction_details_customer => 'Клиент';

  @override
  String get transaction_details_device => 'Устройство';

  @override
  String get transaction_details_history => 'История статусов';

  @override
  String get transaction_details_method => 'Способ';

  @override
  String get transaction_details_not_found => 'Операция не найдена';

  @override
  String get transaction_details_offline => 'Нет сети: действия недоступны';

  @override
  String get transaction_details_onec_number => 'Номер в 1С';

  @override
  String get transaction_details_received => 'Получено';

  @override
  String get transaction_details_related => 'Связанные документы';

  @override
  String get transaction_details_related_empty => 'Связанных документов нет';

  @override
  String get transaction_details_return_in_onec => 'Возврат оформляется в 1С';

  @override
  String transaction_details_review_mismatch(String amount, String received) {
    return 'Требует проверки: получено $received из $amount';
  }

  @override
  String get transaction_details_review_unknown => 'Требует проверки: неизвестная ссылка платежа';

  @override
  String get transaction_details_source_onec => '1С';

  @override
  String get transaction_details_source_pos => 'POS';

  @override
  String get transaction_details_state_changed => 'Статус платежа изменился. Данные обновлены';

  @override
  String get transaction_details_unknown_result => 'Результат операции неизвестен · Проверить';

  @override
  String transaction_details_void_body(String amount, String number) {
    return 'Платёж $amount по заказу № $number будет аннулирован. Деньги не должны быть получены';
  }

  @override
  String get transaction_details_void_comment_required => 'Опишите причину (не менее 5 символов)';

  @override
  String get transaction_details_void_done => 'Платёж аннулирован';

  @override
  String get transaction_details_void_reason_cashier_error => 'Ошибка кассира';

  @override
  String get transaction_details_void_reason_customer_refused => 'Клиент отказался';

  @override
  String get transaction_details_void_reason_duplicate => 'Дубликат';

  @override
  String get transaction_details_void_reason_other => 'Иное';

  @override
  String get transaction_details_void_received_hint => 'Деньги получены — оформите возврат в 1С';

  @override
  String get transaction_details_void_title => 'Аннулировать платёж?';

  @override
  String get transaction_details_waybill_onec => 'Печатается из 1С';

  @override
  String transactions_apply_n(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Показать $count операции',
      many: 'Показать $count операций',
      few: 'Показать $count операции',
      one: 'Показать $count операцию',
    );
    return '$_temp0';
  }

  @override
  String get transactions_empty => 'Операций за период нет';

  @override
  String get transactions_end => 'Показаны все операции за период';

  @override
  String get transactions_filter_actor => 'Сотрудник';

  @override
  String get transactions_filter_customer => 'Клиент';

  @override
  String get transactions_filter_failed => 'Не удалось применить фильтр';

  @override
  String get transactions_filter_kind => 'Тип операции';

  @override
  String get transactions_filter_method => 'Способ оплаты';

  @override
  String get transactions_filter_status => 'Статус';

  @override
  String transactions_filters(int count) {
    return 'Фильтры · $count';
  }

  @override
  String get transactions_kind_credit_sale_approved => 'Продажа в долг разрешена';

  @override
  String get transactions_kind_discount_override => 'Скидка сверх лимита';

  @override
  String get transactions_kind_manual_qr_confirm => 'Ручное подтверждение QR';

  @override
  String get transactions_kind_order_cancelled => 'Заказ отменён';

  @override
  String get transactions_kind_order_created => 'Заказ создан';

  @override
  String get transactions_kind_payment_received => 'Платёж получен';

  @override
  String get transactions_kind_payment_voided => 'Платёж аннулирован';

  @override
  String get transactions_kind_refund => 'Возврат';

  @override
  String get transactions_kind_return_requested => 'Заявка на возврат';

  @override
  String get transactions_method_cash => 'Наличные';

  @override
  String get transactions_method_credit => 'Долг';

  @override
  String get transactions_method_qr => 'QR';

  @override
  String get transactions_offline => 'Журнал операций недоступен без сети';

  @override
  String transactions_offline_stale(String time) {
    return 'Нет сети. Показаны данные от $time';
  }

  @override
  String get transactions_only_mine => 'Только мои';

  @override
  String get transactions_period_7d => '7 дней';

  @override
  String get transactions_period_custom => 'Период…';

  @override
  String get transactions_period_month => 'Месяц';

  @override
  String get transactions_period_today => 'Сегодня';

  @override
  String transactions_period_too_long(String days) {
    return 'Период больше $days дней';
  }

  @override
  String get transactions_period_yesterday => 'Вчера';

  @override
  String get transactions_reset_all => 'Сбросить всё';

  @override
  String get transactions_search_number => 'Номер документа';

  @override
  String get transactions_source_onec => '1С';

  @override
  String get transactions_status_onec_error => 'Ошибка отправки в 1С';

  @override
  String get transactions_status_pending => 'Ожидает оплаты';

  @override
  String get transactions_status_received => 'Получено';

  @override
  String get transactions_status_returned => 'Возврат';

  @override
  String get transactions_status_voided => 'Аннулировано, отменено';

  @override
  String transactions_sum_count(int count) {
    return 'Операций: $count';
  }

  @override
  String get transactions_sum_in => 'Приход';

  @override
  String get transactions_sum_out => 'Возвраты и аннулирования';

  @override
  String get transactions_title => 'Транзакции';

  @override
  String unit_pcs(int count) {
    String _temp0 = intl.Intl.pluralLogic(count, locale: localeName, other: '$count шт', one: '$count шт');
    return '$_temp0';
  }

  @override
  String unit_pcs_full(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'штуки',
      many: 'штук',
      few: 'штуки',
      one: 'штука',
    );
    return '$_temp0';
  }

  @override
  String get unlock_bio_button => 'Войти по биометрии';

  @override
  String get unlock_forgot_pin => 'Забыли PIN?';

  @override
  String get unlock_hello_button => 'Windows Hello';

  @override
  String get unlock_hello_verified => 'Подтверждено Windows Hello · введите PIN';

  @override
  String unlock_locked_idle(int minutes) {
    return 'Через $minutes мин бездействия';
  }

  @override
  String get unlock_locked_manual => 'Заблокировано вручную';

  @override
  String get unlock_locked_title => 'Экран заблокирован';

  @override
  String get unlock_new_pin_save => 'Сохранить PIN';

  @override
  String get unlock_new_pin_title => 'Задайте новый PIN';

  @override
  String get unlock_offline => 'Нет подключения. Для входа нужна сеть';

  @override
  String get unlock_or_pin => 'или PIN-код';

  @override
  String get unlock_phone_login => 'Войти по номеру телефона';

  @override
  String get unlock_pin_changed => 'PIN изменён';

  @override
  String get unlock_pin_hint => 'Введите PIN-код приложения';

  @override
  String get unlock_reset_body =>
      'Войдите по коду из SMS, затем задайте новый PIN. Несохранённые данные на экране будут потеряны; корзина сохранится';

  @override
  String get unlock_reset_confirm => 'Войти по SMS';

  @override
  String get unlock_reset_title => 'Сбросить PIN?';

  @override
  String get unlock_sms_login => 'Войти по SMS';

  @override
  String get unlock_switch_account => 'Сменить аккаунт';

  @override
  String get unlock_switch_body => 'Текущий пользователь выйдет на этом устройстве. Корзина сохранится на сервере';

  @override
  String get unlock_switch_confirm => 'Сменить';

  @override
  String get unlock_switch_title => 'Сменить аккаунт?';

  @override
  String variant_add_cta(String sum) {
    return 'Добавить в корзину · $sum';
  }

  @override
  String variant_added_snackbar(int count) {
    return 'Добавлено $count позиции / позиций';
  }

  @override
  String get variant_all_out_hint => 'Нет в наличии на складе корзины';

  @override
  String get variant_load_error => 'Не удалось загрузить варианты · Повторить';

  @override
  String get variant_merge_confirm => 'Вариант уже в корзине. Объединить количества?';

  @override
  String variant_mode_axis(String axis) {
    return '$axis';
  }

  @override
  String get variant_mode_list => 'Все варианты списком';

  @override
  String get variant_out_of_stock => 'Нет';

  @override
  String variant_partial_added(String added, String name, String total) {
    return 'Добавлено $added из $total. «$name» больше не продаётся';
  }

  @override
  String get variant_replace_cta => 'Заменить вариант';

  @override
  String get variant_search_empty => 'Вариант не найден';

  @override
  String get variant_search_placeholder => 'Найти по артикулу';

  @override
  String get variant_select_error => 'Выберите вариант';

  @override
  String variant_selected_summary(int count, String qty, String unit) {
    return 'Выбрано: $count вариантов · $qty $unit';
  }

  @override
  String variant_sheet_count(String axis, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count варианта · ось: $axis',
      many: '$count вариантов · ось: $axis',
      few: '$count варианта · ось: $axis',
      one: '$count вариант · ось: $axis',
    );
    return '$_temp0';
  }

  @override
  String variants_count(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count варианта',
      many: '$count вариантов',
      few: '$count варианта',
      one: '$count вариант',
    );
    return '$_temp0';
  }
}
