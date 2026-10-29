import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ky.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('ru'), Locale('en'), Locale('ky')];

  /// Экран: SCR-45. ч. E; действия. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Пригласить снова'**
  String get admin_invites_again;

  /// Экран: SCR-45. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Роль назначена существующему аккаунту'**
  String get admin_invites_applied_existing;

  /// Экран: SCR-45. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Приглашение создано. Сотрудник может войти по номеру {phone}'**
  String admin_invites_created(String phone);

  /// Экран: SCR-45. ч. E; empty. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Приглашений нет'**
  String get admin_invites_empty;

  /// Экран: SCR-45. этап E, 03 §16.7 (ADR-097); `409 PHONE_ALREADY_REGISTERED` с `reason=customer_account` (08 §4.18.4 «Уточнения» п. 2); правило — Q-312; текст предложен владельцем словаря (в 02/03 не задан) — согласовать при вычитке; D FA-07. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Номер принадлежит клиенту. Чтобы сделать его сотрудником, назначьте роль в карточке пользователя'**
  String get admin_invites_error_customer_account;

  /// Экран: SCR-45. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Срок действия — от 1 до 90 дней'**
  String get admin_invites_error_expiry;

  /// Экран: SCR-45. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите 9 цифр номера'**
  String get admin_invites_error_phone;

  /// Экран: SCR-45. ч. E; 409. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Номер уже принадлежит активному сотруднику. Измените его роль в карточке'**
  String get admin_invites_error_registered;

  /// Экран: SCR-45. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выберите роль'**
  String get admin_invites_error_role;

  /// Экран: SCR-45. ч. E; поле. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Действует до'**
  String get admin_invites_expires_label;

  /// Экран: SCR-45. этап E, 03 §16.7 (ADR-097); поле формы приглашения, необязательно, ≤ 150 (UI-45-009); D FA-03. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'ФИО'**
  String get admin_invites_fullname_label;

  /// Экран: SCR-45. ч. E; подсказка (Q-038). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'SMS приглашённому не отправляется. Сообщите сотруднику, что вход выполняется по номеру телефона'**
  String get admin_invites_no_sms_hint;

  /// Экран: SCR-45. этап E, 03 §16.7 (ADR-097); поле формы приглашения (UI-45-009); D FA-03. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Телефон'**
  String get admin_invites_phone_label;

  /// Экран: SCR-45. ч. E; действия. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отозвать'**
  String get admin_invites_revoke;

  /// Экран: SCR-45. ч. E; кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отправить приглашение'**
  String get admin_invites_send;

  /// Экран: SCR-45. ч. E; версия 1.7; подзаголовок формы UI-45-009 (ядро v1.9 §24.2). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сотрудники не регистрируются сами: сотрудник войдёт по этому номеру после приглашения'**
  String get admin_invites_staff_only_hint;

  /// Экран: SCR-45. ч. E; форма. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Приглашение сотрудника'**
  String get admin_invites_title;

  /// Экран: SCR-45. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Приглашение для этого номера обновлено'**
  String get admin_invites_updated;

  /// Экран: SCR-45. ч. E; панель привязки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтвердить'**
  String get admin_links_confirm;

  /// Экран: SCR-45. этап E, 03 §16.7 (ADR-097); пустая вкладка «Привязки клиентов» (UI-45-017); текст предложен владельцем словаря (в 02/03 не задан) — согласовать при вычитке; D FA-03. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Запросов на привязку нет'**
  String get admin_links_empty;

  /// Экран: SCR-45. ч. E; 409. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'У клиента уже есть подтверждённая привязка'**
  String get admin_links_error_conflict;

  /// Экран: SCR-45. ч. E; панель привязки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отклонить'**
  String get admin_links_reject;

  /// Экран: SCR-45. ч. E; панель привязки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отклонить все'**
  String get admin_links_reject_all;

  /// Экран: SCR-46. ч. E; caption. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Изменено {time} · {name}'**
  String admin_settings_changed_by(String name, String time);

  /// Экран: SCR-46. ч. E; 409. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Настройки изменены другим администратором'**
  String get admin_settings_conflict_banner;

  /// Экран: SCR-46. ч. E; `ConfirmDialog`; с v1.4 не используется (`CUSTOMER_SELF_SERVICE` — только env, ядро §19.2); ключ сохранён. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Новые клиенты не смогут регистрироваться; у существующих клиентов главный экран станет недоступен'**
  String get admin_settings_customer_mode_disable_confirm;

  /// Экран: SCR-46. ч. E; `ConfirmDialog` destructive; с v1.4 не используется (`CUSTOMER_SELF_SERVICE` — только env, ядро §19.2); ключ сохранён. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиенты смогут регистрироваться по телефону, видеть каталог с ценами своего вида цены и оформлять заявки-заказы'**
  String get admin_settings_customer_mode_enable_confirm;

  /// Экран: SCR-46. ч. E; env `CUSTOMER_SELF_SERVICE`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'По умолчанию на сервере: {value}'**
  String admin_settings_customer_mode_env(String value);

  /// Экран: SCR-46. ч. E; UI-46-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Режим клиента (самообслуживание)'**
  String get admin_settings_customer_mode_label;

  /// Экран: SCR-46. ч. E; диалог. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверьте изменения'**
  String get admin_settings_diff_title;

  /// Экран: SCR-46. ч. E; тултип. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Задаётся на сервере. Изменение — через администратора сервера'**
  String get admin_settings_env_hint;

  /// Экран: SCR-46. ч. E; → SCR-47. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'История изменений'**
  String get admin_settings_history_link;

  /// Экран: SCR-46. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не больше 30 минут для сотрудников'**
  String get admin_settings_idle_error;

  /// Экран: SCR-46. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'От 2 до 1440 минут'**
  String get admin_settings_interval_error;

  /// Экран: SCR-46. ч. E; UI-46-009. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сущности: {entities}. По умолчанию на сервере: {value}'**
  String admin_settings_interval_group_hint(String entities, String value);

  /// Экран: SCR-46. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите значение от 0 до 100 % с шагом 0,5'**
  String get admin_settings_limit_error;

  /// Экран: SCR-46. ч. E; чекбокс. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Может подтверждать сверх лимита'**
  String get admin_settings_limit_override;

  /// Экран: SCR-46. ч. E; подпись. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'было {value} %'**
  String admin_settings_limit_was(String value);

  /// Экран: SCR-46. ч. E; предупреждение. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Лимит подтверждающей роли ниже лимита подчинённой роли'**
  String get admin_settings_limits_override_warning;

  /// Экран: SCR-46. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Лимиты скидок сохранены. Применятся в течение минуты'**
  String get admin_settings_limits_saved;

  /// Экран: SCR-46. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите целое число не меньше 0'**
  String get admin_settings_low_stock_error;

  /// Экран: SCR-46. ч. E; диалог. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Устройства с версией ниже {version} перестанут работать до обновления'**
  String admin_settings_min_version_confirm(String version);

  /// Экран: SCR-46. ч. E; баннер. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Лимиты должны совпадать с «Правилами продаж» 1С, иначе 1С отклонит заказ'**
  String get admin_settings_onec_rules_banner;

  /// Экран: SCR-46. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'От 180 до 600 секунд'**
  String get admin_settings_otp_ttl_error;

  /// Экран: SCR-46. ч. E; `owner`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Просмотр. Изменять настройки может администратор'**
  String get admin_settings_readonly_banner;

  /// Экран: SCR-46. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'От 5 до 1440 минут'**
  String get admin_settings_receivables_error;

  /// Экран: SCR-46. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Настройки сохранены'**
  String get admin_settings_saved;

  /// Экран: SCR-46. ч. E; секции. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вход и сессии'**
  String get admin_settings_section_auth;

  /// Экран: SCR-46. ч. E; секции. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Корзины'**
  String get admin_settings_section_carts;

  /// Экран: SCR-46. ч. E; секции. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долги'**
  String get admin_settings_section_debts;

  /// Экран: SCR-46. ч. E; секции. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Лимиты скидок'**
  String get admin_settings_section_limits;

  /// Экран: SCR-46. ч. E; секции. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата и возвраты'**
  String get admin_settings_section_payments;

  /// Экран: SCR-46. ч. E; секции. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Печать'**
  String get admin_settings_section_print;

  /// Экран: SCR-46. ч. E; секции. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Регистрация и режим клиента'**
  String get admin_settings_section_registration;

  /// Экран: SCR-46. ч. E; секции. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Склад и остатки'**
  String get admin_settings_section_stock;

  /// Экран: SCR-46. ч. E; секции. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Синхронизация'**
  String get admin_settings_section_sync;

  /// Экран: SCR-46. ч. E; секции. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Тексты и контакты'**
  String get admin_settings_section_texts;

  /// Экран: SCR-46. ч. E; секции. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Версии приложения'**
  String get admin_settings_section_versions;

  /// Экран: SCR-46. ч. E; заголовок. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Настройки системы'**
  String get admin_settings_title;

  /// Экран: SCR-46. ч. E; диалог. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сохранить изменения в секции {name}?'**
  String admin_settings_unsaved_confirm(String name);

  /// Экран: SCR-46. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Формат версии: 1.4.0'**
  String get admin_settings_version_error;

  /// Экран: SCR-46. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Рекомендуемая версия не может быть ниже минимальной'**
  String get admin_settings_version_order_error;

  /// Экран: SCR-45. этап E, 03 §16.7 (ADR-097); заголовок блока карточки пользователя, зона D; D FA-03. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Действия'**
  String get admin_users_actions_section;

  /// Экран: SCR-45. ч. E; `pending_activation`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Активировать'**
  String get admin_users_activate;

  /// Экран: SCR-45. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Пользователь активирован'**
  String get admin_users_activated;

  /// Экран: SCR-45. ч. E; ссылка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Аудит пользователя'**
  String get admin_users_audit_link;

  /// Экран: SCR-45. ч. E; кнопки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заблокировать'**
  String get admin_users_block;

  /// Экран: SCR-45. ч. E; диалог. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заблокировать {name}? Все сеансы будут завершены, приглашение аннулировано'**
  String admin_users_block_confirm(String name);

  /// Экран: SCR-45. ч. E; 409. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Данные изменены другим администратором'**
  String get admin_users_conflict_banner;

  /// Экран: SCR-45. ч. E; блок сессий. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Устройств: {count} · последний вход {time}'**
  String admin_users_devices(int count, String time);

  /// Экран: SCR-45. ч. E; подсказка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Права изменятся в течение минуты; при понижении прав все сеансы пользователя будут завершены'**
  String get admin_users_effect_hint;

  /// Экран: SCR-45. ч. E; версия 1.6; UI-45-024. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Закрыть? Код больше не будет показан'**
  String get admin_users_emergency_close_confirm;

  /// Экран: SCR-45. ч. E; версия 1.6; UI-45-023 (ядро §22.13 п.2, §23 п.8). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выдать аварийный код входа'**
  String get admin_users_emergency_code;

  /// Экран: SCR-45. ч. E; версия 1.6; 11 SEC-131. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Передайте код лично или голосом после проверки личности. Не отправляйте код через мессенджеры'**
  String get admin_users_emergency_hint;

  /// Экран: SCR-45. этап E, 03 §16.7 (ADR-097); кнопка шага 1 диалога аварийного кода (UI-45-024); D FA-03. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выдать код'**
  String get admin_users_emergency_issue;

  /// Экран: SCR-45. ч. E; версия 1.6; `422 VALIDATION_FAILED`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Код можно выдать только активному сотруднику'**
  String get admin_users_emergency_not_allowed;

  /// Экран: SCR-45. ч. E; версия 1.6; `429 RATE_LIMITED`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Лимит аварийных кодов на сегодня исчерпан'**
  String get admin_users_emergency_rate_limited;

  /// Экран: SCR-45. ч. E; версия 1.6; `reason=other`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Иное'**
  String get admin_users_emergency_reason_other;

  /// Экран: SCR-45. ч. E; версия 1.6; `reason=sim_lost`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Утерян доступ к SIM-карте'**
  String get admin_users_emergency_reason_sim;

  /// Экран: SCR-45. ч. E; версия 1.6; `reason=sms_unavailable`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'SMS не доходят'**
  String get admin_users_emergency_reason_sms;

  /// Экран: SCR-45. ч. E; версия 1.6; UI-45-024, `{code}` — String. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Код {code} действует до {time}. Он показывается один раз'**
  String admin_users_emergency_shown(String code, String time);

  /// Экран: SCR-45. ч. E; версия 1.6; UI-45-024. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Аварийный код входа для {name}'**
  String admin_users_emergency_title(String name);

  /// Экран: SCR-45. ч. E; empty. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Пользователи не найдены'**
  String get admin_users_empty;

  /// Экран: SCR-45. ч. E; 422. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нельзя заблокировать свою учётную запись'**
  String get admin_users_error_self_block;

  /// Экран: SCR-45. ч. E; 422. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нельзя снять с себя роль администратора'**
  String get admin_users_error_self_demotion;

  /// Экран: SCR-45. этап E, 03 §16.7 (ADR-097); значение «все» фильтров роли и статуса; D FA-03. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все'**
  String get admin_users_filter_all;

  /// Экран: SCR-45. ч. E; фильтры. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Роль'**
  String get admin_users_filter_role;

  /// Экран: SCR-45. ч. E; фильтры. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Статус'**
  String get admin_users_filter_status;

  /// Экран: SCR-45. ч. E; кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'+ Пригласить'**
  String get admin_users_invite_button;

  /// Экран: SCR-45. ч. E; чекбокс. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'По роли'**
  String get admin_users_limit_by_role;

  /// Экран: SCR-45. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Лимит от 0 до 100 %'**
  String get admin_users_limit_error;

  /// Экран: SCR-45. ч. E; поле. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Индивидуальный лимит скидки'**
  String get admin_users_limit_label;

  /// Экран: SCR-45. ч. E; тултип. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Роль «Руководитель» назначает только руководитель'**
  String get admin_users_owner_hint;

  /// Экран: SCR-45. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'PIN сброшен'**
  String get admin_users_pin_reset;

  /// Экран: SCR-45. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Укажите причину (не менее 5 символов)'**
  String get admin_users_reason_error;

  /// Экран: SCR-45. ч. E; поле. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Причина'**
  String get admin_users_reason_label;

  /// Экран: SCR-45. ч. E; кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сбросить PIN'**
  String get admin_users_reset_pin;

  /// Экран: SCR-45. ч. E; диалог. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'PIN будет сброшен. Сотрудник задаст новый PIN после входа по SMS'**
  String get admin_users_reset_pin_confirm;

  /// Экран: SCR-45. ч. E; кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Завершить все сессии'**
  String get admin_users_revoke_sessions;

  /// Экран: SCR-45. ч. E; диалог. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Роль {name}: {old} → {newValue}'**
  String admin_users_role_diff(String name, String newValue, String old);

  /// Экран: SCR-45. ч. E; кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сохранить роль'**
  String get admin_users_role_save;

  /// Экран: SCR-45. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Роль изменена. Права обновятся в течение минуты'**
  String get admin_users_role_saved;

  /// Экран: SCR-45. ч. E; блок. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Роль'**
  String get admin_users_role_section;

  /// Экран: SCR-45. ч. E; поиск. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Имя или телефон'**
  String get admin_users_search_hint;

  /// Экран: SCR-45. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все сеансы пользователя завершены'**
  String get admin_users_sessions_revoked;

  /// Экран: SCR-45. этап E, 03 §16.7 (ADR-097); заголовок блока карточки пользователя, зона D (UI-45-006); D FA-03. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Устройства и сессии'**
  String get admin_users_sessions_section;

  /// Экран: SCR-45. ч. E; шапка карточки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'По приглашению'**
  String get admin_users_source_invitation;

  /// Экран: SCR-45. ч. E; шапка карточки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Самостоятельная регистрация'**
  String get admin_users_source_self;

  /// Экран: SCR-45. ч. E; вкладки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Приглашения · {count}'**
  String admin_users_tab_invitations(int count);

  /// Экран: SCR-45. ч. E; вкладки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Привязки клиентов · {count}'**
  String admin_users_tab_links(int count);

  /// Экран: SCR-45. ч. E; вкладки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Пользователи · {count}'**
  String admin_users_tab_users(int count);

  /// Экран: SCR-45. ч. E; заголовок. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Пользователи'**
  String get admin_users_title;

  /// Экран: SCR-45. ч. E; кнопки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Разблокировать'**
  String get admin_users_unblock;

  /// Экран: SCR-45. ч. E; блок. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Склады'**
  String get admin_users_warehouses;

  /// Экран: SCR-47. ч. E; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сброшен PIN сотрудника'**
  String get audit_action_auth_pin_reset;

  /// Экран: SCR-47. ч. E; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Разрешена продажа в долг'**
  String get audit_action_credit_sale_approved;

  /// Экран: SCR-47. ч. E; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Просмотр детализации долга'**
  String get audit_action_customer_finance_view;

  /// Экран: SCR-47. ч. E; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Изменены лимиты скидок'**
  String get audit_action_discount_limits_changed;

  /// Экран: SCR-47. ч. E; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтверждена скидка сверх лимита'**
  String get audit_action_discount_over_limit_approved;

  /// Экран: SCR-47. ч. E; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Запрошена отмена заказа'**
  String get audit_action_order_cancel_requested;

  /// Экран: SCR-47. ч. E; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата QR подтверждена вручную'**
  String get audit_action_payment_manual_qr_confirmed;

  /// Экран: SCR-47. ч. E; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Изменены настройки'**
  String get audit_action_settings_changed;

  /// Экран: SCR-47. ч. E; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ручной запуск синхронизации'**
  String get audit_action_sync_manual_started;

  /// Экран: SCR-47. ч. E; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Применены цены из 1С'**
  String get audit_action_sync_prices_applied;

  /// Экран: SCR-47. ч. E; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Применены остатки из 1С'**
  String get audit_action_sync_stock_applied;

  /// Экран: SCR-47. ч. E; fallback. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Событие {code}'**
  String audit_action_unknown(String code);

  /// Экран: SCR-47. ч. E; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Пользователь заблокирован'**
  String get audit_action_user_blocked;

  /// Экран: SCR-47. ч. E; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Изменены роли'**
  String get audit_action_user_role_changed;

  /// Экран: SCR-47. ч. E; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Пользователь разблокирован'**
  String get audit_action_user_unblocked;

  /// Экран: SCR-47. ч. E; деталь. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Стало'**
  String get audit_after;

  /// Экран: SCR-47. ч. E; деталь. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Было'**
  String get audit_before;

  /// Экран: SCR-47. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скопировано'**
  String get audit_copied;

  /// Экран: SCR-47. ч. E; empty. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Изменить период'**
  String get audit_empty_action;

  /// Экран: SCR-47. ч. E; empty. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Записей за период нет'**
  String get audit_empty_title;

  /// Экран: SCR-47. ч. E; R2; в R1 не используется (UI-47-012 скрыт, версия 1.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Экспорт будет доступен в следующей версии'**
  String get audit_export_r2_tooltip;

  /// Экран: SCR-47. ч. E; фильтры. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Действие'**
  String get audit_filter_action;

  /// Экран: SCR-47. ч. E; фильтры. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Объект'**
  String get audit_filter_object;

  /// Экран: SCR-47. ч. E; фильтры. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Результат'**
  String get audit_filter_result;

  /// Экран: SCR-47. ч. E; фильтры. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Пользователь'**
  String get audit_filter_user;

  /// Экран: SCR-47. ч. E; ICU plural. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Фильтры ({count})'**
  String audit_filters_button(int count);

  /// Экран: SCR-47. ч. E; `admin`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'скрыто'**
  String get audit_masked_value;

  /// Экран: SCR-47. ч. E; валидация; ядро §20.2 п.15. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Период не больше 366 дней'**
  String get audit_period_error;

  /// Экран: SCR-47. ч. E; деталь. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Причина'**
  String get audit_reason;

  /// Экран: SCR-47. ч. E; `StatusChip`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отказано'**
  String get audit_result_denied;

  /// Экран: SCR-47. ч. E; `StatusChip`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ошибка'**
  String get audit_result_error;

  /// Экран: SCR-47. ч. E; `StatusChip`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Успешно'**
  String get audit_result_ok;

  /// Экран: SCR-47. ч. E; деталь. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтверждение'**
  String get audit_step_up_method;

  /// Экран: SCR-47. ч. E; заголовок. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Журнал аудита'**
  String get audit_title;

  /// Экран: SCR-02. ч. A; снекбар: step-up отменён или PIN не задан. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Включить биометрию можно позже в настройках'**
  String get auth_bio_enable_later;

  /// Экран: SCR-02, SCR-04. ч. A; подсказка `StepUpDialog` (до решения Q-201). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтвердите PIN-кодом, чтобы включить вход по биометрии'**
  String get auth_bio_enable_stepup_hint;

  /// Экран: SCR-08. ч. A; 09 §9.3. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Биометрия на устройстве изменилась. Войдите по номеру телефона и включите вход заново'**
  String get auth_bio_invalidated;

  /// Экран: SCR-08. ч. A; 09 §9.3. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Биометрия временно заблокирована. Введите PIN или войдите по номеру'**
  String get auth_bio_lockout;

  /// Экран: SCR-02. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Включить'**
  String get auth_bio_offer_enable;

  /// Экран: SCR-02. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не сейчас'**
  String get auth_bio_offer_later;

  /// Экран: SCR-02. ч. A; UI-02-018. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Входить по биометрии?'**
  String get auth_bio_offer_title;

  /// Экран: SCR-02. ч. A; 09 §4.3. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Доступ закрыт. Обратитесь к администратору магазина'**
  String get auth_blocked_message;

  /// Экран: SCR-01. ч. A; текст макета. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Найдите товар за секунды'**
  String get auth_brand_feature_1_body;

  /// Экран: SCR-01. ч. A; текст макета. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Быстрый поиск товаров'**
  String get auth_brand_feature_1_title;

  /// Экран: SCR-01. ч. A; «в реальном времени» макета не используется (остатки — снимок, D-29). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'По всем складам'**
  String get auth_brand_feature_2_body;

  /// Экран: SCR-01. ч. A; «в реальном времени» макета не используется (остатки — снимок, D-29). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Актуальные остатки'**
  String get auth_brand_feature_2_title;

  /// Экран: SCR-01. ч. A; текст макета. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Чеки, накладные, счета на оплату'**
  String get auth_brand_feature_3_body;

  /// Экран: SCR-01. ч. A; текст макета. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказы и документы'**
  String get auth_brand_feature_3_title;

  /// Экран: SCR-01. ч. A; текст макета. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Интерфейс создан для продавцов'**
  String get auth_brand_feature_4_body;

  /// Экран: SCR-01. ч. A; текст макета. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Удобно и просто'**
  String get auth_brand_feature_4_title;

  /// Экран: SCR-01. ч. A; макет; Q-200. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ваши данные защищены'**
  String get auth_brand_secure;

  /// Экран: SCR-01, 02, 08 (expanded). ч. A; текст макета. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Рабочее место продавца'**
  String get auth_brand_subtitle;

  /// Экран: SCR-01. ч. A; = `auth_bio_invalidated`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Биометрия на устройстве изменилась. Войдите по номеру телефона и включите вход заново'**
  String get auth_entry_bio_invalidated;

  /// Экран: SCR-01. ч. A; UI-01-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Код запрошен с другого устройства. Запросите новый код'**
  String get auth_entry_device_mismatch;

  /// Экран: SCR-01. ч. A; UI-01-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Этот номер уже зарегистрирован. Войдите по коду из SMS'**
  String get auth_entry_phone_registered;

  /// Экран: SCR-01. ч. A; UI-01-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'PIN заблокирован. Войдите по коду из SMS'**
  String get auth_entry_pin_locked;

  /// Экран: SCR-01. ч. A; UI-01-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Войдите по коду из SMS, чтобы задать новый PIN'**
  String get auth_entry_pin_reset;

  /// Экран: SCR-01. ч. A; UI-01-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Регистрация прервана. Данные сохранятся на этом устройстве 15 минут'**
  String get auth_entry_registration_cancelled;

  /// Экран: SCR-01. ч. A; UI-01-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Время регистрации истекло. Подтвердите номер ещё раз — введённые данные сохранятся'**
  String get auth_entry_registration_expired;

  /// Экран: SCR-01. ч. A; UI-01-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продолжите регистрацию: подтвердите номер кодом из SMS'**
  String get auth_entry_registration_resume;

  /// Экран: SCR-01. ч. A; UI-01-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Для безопасности мы завершили все сессии. Войдите снова'**
  String get auth_entry_reuse_detected;

  /// Экран: SCR-01. ч. A; UI-01-017; 09 `auth_session_revoked`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сессия завершена. Войдите снова'**
  String get auth_entry_session_revoked;

  /// Экран: SCR-02. ч. A; новый. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Код запрошен с другого устройства. Запросите новый код'**
  String get auth_error_device_mismatch;

  /// Экран: SCR-01…08. ч. A; 03 §13.3. Источник: 02 §7; текст совпадает с 03 §13.3
  ///
  /// In ru, this message translates to:
  /// **'Нет связи с сервером. Проверьте сеть и повторите'**
  String get auth_error_network;

  /// Экран: SCR-02. ч. A; 03 §13.3. Источник: 02 §7; текст совпадает с 03 §13.3
  ///
  /// In ru, this message translates to:
  /// **'Код устарел. Запросите новый'**
  String get auth_error_otp_expired;

  /// Экран: SCR-02. ч. A; 03 §13.3 (09: `auth_otp_error_invalid`). Источник: 02 §7; текст совпадает с 03 §13.3
  ///
  /// In ru, this message translates to:
  /// **'Неверный код. Осталось попыток: {n}'**
  String auth_error_otp_invalid(int n);

  /// Экран: SCR-02. ч. A; 03 §13.3. Источник: 02 §7; текст совпадает с 03 §13.3
  ///
  /// In ru, this message translates to:
  /// **'Попытки исчерпаны. Запросите новый код через {seconds} с'**
  String auth_error_otp_locked(int seconds);

  /// Экран: SCR-01, 02. ч. A; 03 §13.3. Источник: 02 §7; текст совпадает с 03 §13.3
  ///
  /// In ru, this message translates to:
  /// **'Слишком много запросов. Подождите {seconds} с'**
  String auth_error_rate_limited(int seconds);

  /// Экран: SCR-01, 02. ч. A; при ≥ 60 с; 09 `auth_phone_error_rate_limited`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Слишком много запросов кода на этот номер. Попробуйте через {minutes} мин'**
  String auth_error_rate_limited_min(int minutes);

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §13.3
  ///
  /// In ru, this message translates to:
  /// **'Сессия завершена. Войдите снова'**
  String get auth_error_revoked;

  /// Экран: SCR-01, 02. ч. A; 03 §13.3. Источник: 02 §7; текст совпадает с 03 §13.3
  ///
  /// In ru, this message translates to:
  /// **'Не удалось отправить SMS. Попробуйте позже'**
  String get auth_error_sms_provider;

  /// Экран: SCR-01…08. ч. A; 03 §13.3. Источник: 02 §7; текст совпадает с 03 §13.3
  ///
  /// In ru, this message translates to:
  /// **'Сервер не ответил. Повторить'**
  String get auth_error_timeout;

  /// Экран: SCR-01, 02. ч. A; макет: «© 2024 OptomStroy. Все права защищены.»; год — текущий, бренд — Q-200. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'© {year} Оптомстрой. Все права защищены.'**
  String auth_footer_copyright(String year);

  /// Экран: SCR-02. ч. A; 09 §3.2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Изменить номер'**
  String get auth_otp_change_phone;

  /// Экран: SCR-02. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверяем код…'**
  String get auth_otp_checking;

  /// Экран: SCR-02. ч. A; Semantics. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Код из SMS, 6 цифр'**
  String get auth_otp_code_a11y;

  /// Экран: SCR-02. ч. A; UI-02-016 (ядро §19.2). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось отправить SMS'**
  String get auth_otp_delivery_failed;

  /// Экран: SCR-02. ч. A; UI-02-016 (`GET /auth/otp/challenges/{challengeId}`, ядро §19.2). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отправляем SMS…'**
  String get auth_otp_delivery_queued;

  /// Экран: SCR-02. ч. A; UI-02-016 (ядро §19.2). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'SMS отправлено'**
  String get auth_otp_delivery_sent;

  /// Экран: SCR-02. ч. A; только dev/staging. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'dev: код {code}'**
  String auth_otp_dev_code(String code);

  /// Экран: SCR-02. ч. A; новый. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось отправить новый код. Введите код из предыдущего SMS'**
  String get auth_otp_fallback_previous;

  /// Экран: SCR-02. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не приходит SMS?'**
  String get auth_otp_no_sms;

  /// Экран: SCR-02. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверьте номер. SMS может прийти в течение 1–2 минут. Если SMS не приходит, отправьте код повторно или обратитесь в поддержку'**
  String get auth_otp_no_sms_body;

  /// Экран: SCR-02. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет подключения. Код будет проверен, когда появится сеть'**
  String get auth_otp_offline;

  /// Экран: SCR-02. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отправить код повторно'**
  String get auth_otp_resend;

  /// Экран: SCR-02. ч. A; 09 §4.4. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отправить повторно через {mmss}'**
  String auth_otp_resend_in(String mmss);

  /// Экран: SCR-02. ч. A; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Код отправлен повторно'**
  String get auth_otp_resent;

  /// Экран: SCR-02. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отправили на {phone}'**
  String auth_otp_sent_to(String phone);

  /// Экран: SCR-02. ч. A; кнопка L. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтвердить'**
  String get auth_otp_submit;

  /// Экран: SCR-02. ч. A; 09 §4.4. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите код из SMS'**
  String get auth_otp_title;

  /// Экран: SCR-02. ч. A; 09 §4.4. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Код действует ещё {mmss}'**
  String auth_otp_ttl_timer(String mmss);

  /// Экран: SCR-02. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Код подтверждён'**
  String get auth_otp_verified;

  /// Экран: SCR-01, SCR-08. этап E, 03 §16.7 (ADR-097); предупреждение до `verify` при входе другого сотрудника; `name` — ФИО прежнего пользователя (04 FLOW-002.A3, FLOW-009.E1; 07 §11.2); FIX-EF-10. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'У {name} есть неотправленные изменения корзины — они будут отправлены при его следующем входе'**
  String auth_pending_changes_other_user(String name);

  /// Экран: SCR-01. ч. A; Semantics. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Номер телефона, 9 цифр после +996'**
  String get auth_phone_a11y;

  /// Экран: SCR-01. ч. A; кнопка ×. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Очистить номер'**
  String get auth_phone_clear_a11y;

  /// Экран: SCR-01. ч. A; 09 §3.3. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите номер телефона'**
  String get auth_phone_error_empty;

  /// Экран: SCR-01. ч. A; новый (вставка «8 (…)»). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите номер в формате +996 XXX XXX XXX'**
  String get auth_phone_error_format;

  /// Экран: SCR-01. ч. A; 09 §3.3. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Похоже, номер указан неверно. Проверьте и попробуйте снова'**
  String get auth_phone_error_invalid;

  /// Экран: SCR-01. ч. A; 09 §3.3. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Слишком много цифр. Проверьте номер'**
  String get auth_phone_error_long;

  /// Экран: SCR-01. ч. A; 09 §3.3. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сервер не принял номер. Проверьте формат +996 XXX XXX XXX'**
  String get auth_phone_error_server_invalid;

  /// Экран: SCR-01. ч. A; 09 §3.3. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Номер должен содержать 9 цифр после +996'**
  String get auth_phone_error_short;

  /// Экран: SCR-01. ч. A; подсказка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите 9 цифр после +996'**
  String get auth_phone_hint;

  /// Экран: SCR-01. ч. A; ICU. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{Ещё {count} цифра} few{Ещё {count} цифры} many{Ещё {count} цифр} other{Ещё {count} цифры}}'**
  String auth_phone_hint_remaining(int count);

  /// Экран: SCR-01. ч. A; подпись поля. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Номер телефона'**
  String get auth_phone_label;

  /// Экран: SCR-01. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нужна сеть для входа'**
  String get auth_phone_offline_hint;

  /// Экран: SCR-01. ч. A; после 1 с. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отправляем код…'**
  String get auth_phone_sending;

  /// Экран: SCR-01. ч. A; 11 Шаблон 2 (кратко). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Для входа мы отправим SMS с одноразовым кодом. Служебные SMS не требуют отдельного согласия; рекламные SMS не отправляются'**
  String get auth_phone_sms_notice;

  /// Экран: SCR-01. ч. A; полный текст — Шаблон 2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подробнее'**
  String get auth_phone_sms_notice_more;

  /// Экран: SCR-01. ч. A; кнопка L. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Получить код'**
  String get auth_phone_submit;

  /// Экран: SCR-01. ч. A; лимит. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Получить код через {mmss}'**
  String auth_phone_submit_wait(String mmss);

  /// Экран: SCR-01. ч. A; не упоминает регистрацию. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отправим SMS с кодом подтверждения'**
  String get auth_phone_subtitle;

  /// Экран: SCR-01. ч. A; ≤ 40 симв.. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вход по номеру телефона'**
  String get auth_phone_title;

  /// Экран: SCR-08, 90. ч. A; 09 §9.6. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Неверный PIN. Осталось попыток: {n}'**
  String auth_pin_error_invalid(int n);

  /// Экран: SCR-08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'PIN заблокирован после 5 неверных попыток. Войдите по SMS и задайте новый PIN'**
  String get auth_pin_locked;

  /// Экран: SCR-01…08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Позвонить'**
  String get auth_support_call;

  /// Экран: SCR-01…08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скопировать номер'**
  String get auth_support_copy;

  /// Экран: SCR-01…08. ч. A; нет контактов в кэше. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Обратитесь к администратору магазина'**
  String get auth_support_fallback;

  /// Экран: SCR-01…08. ч. A; лист контактов. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Техническая поддержка'**
  String get auth_support_title;

  /// Экран: SCR-20. ч. C; ICU plural (03 §16.3); счётчик и `Semantics`. Источник: 02 §7; текст совпадает с 03 §16.3
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{{count} позиция} few{{count} позиции} many{{count} позиций} other{{count} позиции}}'**
  String cart_a11y_positions(int count);

  /// Экран: SCR-20. ч. C; UI-20-024. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Принять новые цены'**
  String get cart_banner_accept_prices;

  /// Экран: SCR-20. ч. C; CART-018. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет сети. Изменения сохранены и будут отправлены'**
  String get cart_banner_offline;

  /// Экран: SCR-20. ч. C; UI-20-012; ICU plural — этап F, FIX-F-16, 03 §16.8 (ADR-103). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Цены изменились · {count, plural, one{{count} позиция} few{{count} позиции} many{{count} позиций} other{{count} позиции}}'**
  String cart_banner_prices_changed(int count);

  /// Экран: SCR-20. ч. C; ORD-027. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Корзина восстановлена из заказа № {number}: {reason}'**
  String cart_banner_restored_from_order(String number, String reason);

  /// Экран: SCR-20. ч. C; CART-016. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Данные от {time} — обновляем…'**
  String cart_banner_stale(String time);

  /// Экран: SCR-20. ч. C; UI-20-012; ICU plural — этап F, FIX-F-16, 03 §16.8 (ADR-103). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Недостаточно остатка · {count, plural, one{{count} позиция} few{{count} позиции} many{{count} позиций} other{{count} позиции}}'**
  String cart_banner_stock(int count);

  /// Экран: SCR-20. ч. C; UI-20-029 (ICU plural); ICU plural — этап F, FIX-F-16, 03 §16.8 (ADR-103). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{Будет удалена {count} позиция} few{Будет удалено {count} позиции} many{Будет удалено {count} позиций} other{Будет удалено {count} позиции}}. Отложенные заказы не затрагиваются'**
  String cart_clear_dialog_body(int count);

  /// Экран: SCR-20. ч. C; UI-20-029. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Очистить'**
  String get cart_clear_dialog_confirm;

  /// Экран: SCR-20. ч. C; UI-20-029. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Очистить корзину?'**
  String get cart_clear_dialog_title;

  /// Экран: SCR-20. ч. C; UI-20-003. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Очистить корзину'**
  String get cart_clear_tooltip;

  /// Экран: SCR-20. ч. C; UI-20-021, подпись `CartFab` UI-10-040 / UI-20-019: `{positions}` — `cart_a11y_positions` / `cart_positions_short`, `{units}` — по единицам из 1С. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{positions} · {units}'**
  String cart_counter_units(String positions, String units);

  /// Экран: SCR-20. ч. C; UI-20-016. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Создать заказ'**
  String get cart_cta_create_order;

  /// Экран: SCR-20, drawer, настольные платформы. прототип 2026-10-29, ADR-112, версия 1.16; UI-20-016 с подсказкой клавиши; без клавиатуры — `cart_cta_create_order`; у customer — `cart_customer_submit`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Создать заказ · F9'**
  String get cart_cta_create_order_hotkey;

  /// Экран: SCR-20. ч. C; UI-20-015. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отложить заказ'**
  String get cart_cta_park;

  /// Экран: SCR-20, drawer, настольные платформы. прототип 2026-10-29, ADR-112, версия 1.16; UI-20-015 с подсказкой клавиши; без клавиатуры — `cart_cta_park`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отложить · F8'**
  String get cart_cta_park_hotkey;

  /// Экран: SCR-20. ч. C; UI-20-022. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Примите новые цены'**
  String get cart_cta_reason_accept_prices;

  /// Экран: SCR-20. ч. C; UI-20-022 / UI-20-020. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверяем результат создания заказа…'**
  String get cart_cta_reason_checking;

  /// Экран: SCR-20. ч. C; UI-20-022. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Корзина пуста'**
  String get cart_cta_reason_empty;

  /// Экран: SCR-20. ч. C; UI-20-022. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нужна сеть, чтобы создать заказ'**
  String get cart_cta_reason_offline;

  /// Экран: SCR-20. ч. C; UI-20-022. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Уменьшите количество до доступного'**
  String get cart_cta_reason_reduce_qty;

  /// Экран: SCR-20. ч. C; UI-20-022. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Обновляем данные…'**
  String get cart_cta_reason_refreshing;

  /// Экран: SCR-20. ч. C; UI-20-022. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Удалите недоступные позиции'**
  String get cart_cta_reason_remove_unavailable;

  /// Экран: SCR-20. ч. C; UI-20-004. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент: не выбран'**
  String get cart_customer_empty;

  /// Экран: SCR-20. ч. C; после `POST /cart/customer`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Цены пересчитаны по условиям клиента'**
  String get cart_customer_prices_recalculated;

  /// Экран: SCR-20, SCR-21. ч. C; версия 1.7; CTA `customer` (ядро v1.9 §24.2). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отправить заявку'**
  String get cart_customer_submit;

  /// Экран: SCR-20. ч. C; UI-20-032. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Применить {limit} %'**
  String cart_discount_apply_limit(String limit);

  /// Экран: SCR-20. ч. C; UI-20-031. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтвердить скидку больше {limit} % может старший продавец или администратор в своей учётной записи. Отложите заказ — старший откроет его на своём устройстве, либо выйдите, чтобы он вошёл на этом терминале'**
  String cart_discount_approval_dialog_body(String limit);

  /// Экран: SCR-20. ч. C; UI-20-031. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Как получить подтверждение'**
  String get cart_discount_approval_how;

  /// Экран: SCR-20. ч. C; UI-20-031. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Понятно'**
  String get cart_discount_approval_ok;

  /// Экран: SCR-20. ч. C; UI-20-031. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отложить заказ'**
  String get cart_discount_approval_park;

  /// Экран: SCR-20. ч. C; UI-20-033: `senior_seller`/`admin`, возобновлённая чужая корзина, в пределах своего лимита. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтвердить скидку {percent} %'**
  String cart_discount_approve_button(String percent);

  /// Экран: SCR-20. ч. C; после override. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтвердил: {name}'**
  String cart_discount_approved_by(String name);

  /// Экран: SCR-20. ч. C; DISC-005. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скидка клиента {percent} % уже учтена'**
  String cart_discount_customer_included(String percent);

  /// Экран: SCR-20. ч. C; локальная валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите число от 0 до 100'**
  String get cart_discount_invalid;

  /// Экран: SCR-20. ч. C; UI-20-013. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скидка'**
  String get cart_discount_label;

  /// Экран: SCR-20. ч. C; UI-20-013. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ваш лимит: {limit} %'**
  String cart_discount_limit_tooltip(String limit);

  /// Экран: SCR-20. ч. C; `422 DISCOUNT_LIMIT_EXCEEDED`, корзина не изменена. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Больше {limit} % без подтверждения нельзя. Действует прежняя скидка {applied} %'**
  String cart_discount_over_limit(String applied, String limit);

  /// Экран: SCR-20. ч. C; потолок подтверждающих ролей, Q-015. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скидка больше {max} % не допускается'**
  String cart_discount_over_max(String max);

  /// Экран: SCR-20. ч. C; UI-20-033. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Причина скидки'**
  String get cart_discount_override_reason_label;

  /// Экран: SCR-20. ч. C; UI-20-033. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Укажите причину скидки'**
  String get cart_discount_override_reason_required;

  /// Экран: SCR-20, drawer. прототип 2026-10-29, ADR-112, версия 1.16; крестик drawer и `barrierLabel` затемнения. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Закрыть корзину'**
  String get cart_drawer_close_a11y;

  /// Экран: SCR-20, drawer. прототип 2026-10-29, ADR-112, версия 1.16; приглушённый суффикс заголовка «Корзина» (UI-20-001); `{count}` — int. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'· {count} поз.'**
  String cart_drawer_title_count(int count);

  /// Экран: SCR-20. ч. C; UI-20-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Добавьте товары из каталога или отсканируйте штрихкод'**
  String get cart_empty_body;

  /// Экран: SCR-20. ч. C; UI-20-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отложенные заказы ({count})'**
  String cart_empty_parked(int count);

  /// Экран: SCR-20. ч. C; UI-20-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Корзина пуста'**
  String get cart_empty_title;

  /// Экран: SCR-20. ч. C; UI-20-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'К каталогу'**
  String get cart_empty_to_catalog;

  /// Экран: SCR-20. ч. C; `CartFab` (03 §16.2); ICU plural (03 §16.3; ревью закрытия E, RS-7). Источник: 02 §7; текст совпадает с 03 §16.2
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{Открыть корзину, {count} позиция, {total}} few{Открыть корзину, {count} позиции, {total}} many{Открыть корзину, {count} позиций, {total}} other{Открыть корзину, {count} позиции, {total}}}'**
  String cart_fab_a11y(int count, String total);

  /// Экран: SCR-10, SCR-50 (`CartFab`). этап E, 03 §16.7 (ADR-097); a11y `CartFab`, когда сумма корзины неизвестна (вариант `cart_fab_a11y` без `total`); EQ-HOME-04; ICU plural (03 §16.3; ревью закрытия E, RS-7). Источник: 02 §7; текст совпадает с 03 §16.3; вариант без суммы (02 §7, EQ-HOME-04)
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{Открыть корзину, {count} позиция} few{Открыть корзину, {count} позиции} many{Открыть корзину, {count} позиций} other{Открыть корзину, {count} позиции}}'**
  String cart_fab_a11y_nototal(int count);

  /// Экран: SCR-10 (шапка), шапка оболочки staff expanded+. паритет функций 2026-10-29, ADR-112, версия 1.20; UI-10-041: первая строка кнопки-итога при непустой корзине — единицы, как прежняя подпись `CartFab` («Корзина · 6 шт, 12,5 м»); «5 поз. · 6 шт» — в тултипе (`cart_counter_units`); шапке не хватает места — строка свёрнута (§3.1 п. 7, версия 1.21). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Корзина · {units}'**
  String cart_header_label_units(String units);

  /// Экран: SCR-10 (шапка), шапка оболочки staff medium+. паритет функций 2026-10-29, ADR-112, версия 1.20; UI-10-041: тултип и добавка к `Semantics` кнопки-итога при неудачном сохранении корзины (записи очереди `dead`, строка `failed`) — иконка `warning` и текст; повтор — в drawer («Ошибка сохранения · Повторить», `cart_save_state_failed`). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Корзина не сохранена'**
  String get cart_header_save_failed;

  /// Экран: SCR-10 (шапка), шапка оболочки staff medium+. ревью переноса прототипа 2026-10-29, ADR-112, версия 1.19; UI-10-041: тултип кнопки-итога и добавка к `Semantics` (`cart_fab_a11y` / `cart_fab_a11y_nototal`), когда изменились цены, не хватает остатка, позиция недоступна или конфликт версий — warning всегда с иконкой и текстом (ядро §24.1). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В корзине есть предупреждения'**
  String get cart_header_warning;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.3; форма макета без склонения
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{Товаров ({count})} other{Товаров ({count})}}'**
  String cart_items_count(int count);

  /// Экран: SCR-16. ч. B; общий с SCR-20. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Удалить позицию из корзины?'**
  String get cart_line_delete_confirm;

  /// Экран: SCR-20. ч. C; количество → 0. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Удалить «{name}» из корзины?'**
  String cart_line_delete_dialog_title(String name);

  /// Экран: SCR-20. ч. C; UI-20-028. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Позиция удалена'**
  String get cart_line_deleted_snackbar;

  /// Экран: SCR-20. ч. C; UI-20-011. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Цена изменилась: было {old} → стало {newValue}'**
  String cart_line_price_changed(String newValue, String old);

  /// Экран: SCR-20. ч. C; UI-20-025. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Уменьшить до {available}'**
  String cart_line_reduce_to(String available);

  /// Экран: SCR-20. ч. C; UI-20-011. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Удалить позицию'**
  String get cart_line_remove_unavailable;

  /// Экран: SCR-20. ч. C; UI-20-011. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Доступно {available} {unit}'**
  String cart_line_stock_available(String available, String unit);

  /// Экран: SCR-20. этап F, 03 §16.8 (ADR-103); строка корзины `customer` при `customer_stock_display=status`, без числа (AC-UI-20-030, AC-UI-16-012); FQ-CART-06 (fe). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Недостаточно товара'**
  String get cart_line_stock_short_customer;

  /// Экран: SCR-20. ч. C; UI-20-011. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Товар больше не продаётся'**
  String get cart_line_unavailable;

  /// Экран: SCR-20. ч. C; CART-024. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Слишком много позиций (максимум {max}). Оформите часть заказа отдельно'**
  String cart_max_items(String max);

  /// Экран: SCR-20. ч. C; UI-20-026. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Название (необязательно)'**
  String get cart_park_dialog_name_hint;

  /// Экран: SCR-20. ч. C; UI-20-026. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отложить заказ'**
  String get cart_park_dialog_title;

  /// Экран: SCR-20. ч. C; после `POST /cart/park`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ отложен'**
  String get cart_parked_snackbar;

  /// Экран: SCR-20. ч. C; действие снекбара. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Открыть отложенные'**
  String get cart_parked_snackbar_open;

  /// Экран: SCR-20. ч. C; UI-20-002. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отложенные заказы'**
  String get cart_parked_tooltip;

  /// Экран: SCR-20. ч. C; UI-20-021, шапка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{count} поз.'**
  String cart_positions_short(int count);

  /// Экран: SCR-20. ч. C; ошибка `checkout-preview`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось проверить заказ · Повторить'**
  String get cart_preview_failed;

  /// Экран: SCR-20. ч. C; `QTY_BELOW_MIN`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Минимальная партия — {min} {unit}'**
  String cart_qty_below_min(String min, String unit);

  /// Экран: SCR-20. ч. C; `QTY_NOT_MULTIPLE`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите количество кратно {step} {unit}'**
  String cart_qty_invalid(String step, String unit);

  /// Экран: SCR-20. ч. C; §4.11.1, этапы 3–4. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверьте заказ в списке заказов'**
  String get cart_result_unknown_check_list;

  /// Экран: SCR-20. ч. C; §4.11.1, этап 2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверка занимает больше обычного. Продолжаем проверять'**
  String get cart_result_unknown_long;

  /// Экран: SCR-20. ч. C; §4.11.1 → SCR-25. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Открыть список заказов'**
  String get cart_result_unknown_open_orders;

  /// Экран: SCR-20. ч. C; UI-20-020. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Повторить сейчас'**
  String get cart_result_unknown_retry;

  /// Экран: SCR-20. ч. C; UI-20-020. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверяем результат создания заказа…'**
  String get cart_result_unknown_title;

  /// Экран: SCR-20. ч. C; §4.11.1, этап 4. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Разблокировать корзину'**
  String get cart_result_unknown_unlock;

  /// Экран: SCR-20. ч. C; UI-20-023. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ошибка сохранения · Повторить'**
  String get cart_save_state_failed;

  /// Экран: SCR-20. ч. C; UI-20-023. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В очереди: {count}'**
  String cart_save_state_queued(int count);

  /// Экран: SCR-20. ч. C; UI-20-023. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сохранено'**
  String get cart_save_state_saved;

  /// Экран: SCR-20. ч. C; UI-20-023. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сохраняем…'**
  String get cart_save_state_saving;

  /// Экран: SCR-20. ч. C; HID-скан. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Товар со штрихкодом {code} не найден'**
  String cart_scan_not_found(String code);

  /// Экран: SCR-20. ч. C; `CartSummary`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скидка ({percent} %)'**
  String cart_summary_discount(String percent);

  /// Экран: SCR-20. ч. C; `CartSummary` (форма макета без склонения, 03 §16.3). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Товаров ({count})'**
  String cart_summary_items(int count);

  /// Экран: SCR-20. ч. C; UI-20-030. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'предварительно'**
  String get cart_summary_preliminary;

  /// Экран: SCR-20, зона F. прототип 2026-10-29, ADR-112, версия 1.16; подпись под «Итого», новый UI-20-034. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Итог пересчитывает сервер по ценам 1С при оформлении'**
  String get cart_summary_server_note;

  /// Экран: SCR-20. ч. C; `CartSummary`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Итого'**
  String get cart_summary_total;

  /// Экран: SCR-20. ч. C; заголовок. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Корзина'**
  String get cart_title;

  /// Экран: SCR-20. ч. C; CART-009 п.4; ICU plural — этап F, FIX-F-16, 03 §16.8 (ADR-103). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Корзина обновлена с сервера: {count, plural, one{изменена {count} позиция} few{изменено {count} позиции} many{изменено {count} позиций} other{изменено {count} позиции}}'**
  String cart_updated_from_server(int count);

  /// Экран: SCR-20. ч. C; UI-20-027. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Применить мои изменения'**
  String get cart_version_conflict_apply_mine;

  /// Экран: SCR-20. ч. C; UI-20-027. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оставить как на сервере'**
  String get cart_version_conflict_keep_server;

  /// Экран: SCR-10/14; SCR-20. ч. B, C; CART-017; ключ переименован при сборке 02 (был `error_version_conflict`, конфликт текста с 02c; общий `error_version_conflict` — «Данные изменились на другом устройстве»); UI-20-027. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Корзина изменена на другом устройстве'**
  String get cart_version_conflict_title;

  /// Экран: SCR-20. ч. C; UI-20-005; ядро §19.2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Склад корзины'**
  String get cart_warehouse_change_title;

  /// Экран: SCR-20. ч. C; UI-20-005; ядро §19.2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Склад изменён: {warehouse}. Проверьте позиции с нехваткой: {count}'**
  String cart_warehouse_change_warnings(int count, String warehouse);

  /// Экран: SCR-20. ч. C; UI-20-005; ядро §19.2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Склад изменён: {warehouse}. Доступность пересчитана'**
  String cart_warehouse_changed(String warehouse);

  /// Экран: SCR-20. ч. C; UI-20-005. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Склад: {warehouse} · цены «{priceList}»'**
  String cart_warehouse_label(String priceList, String warehouse);

  /// Экран: SCR-20. ч. C; UI-20-005 (офлайн). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сменить склад можно только при подключении к сети'**
  String get cart_warehouse_readonly_tooltip;

  /// Экран: SCR-30. ч. D; UI-30-003. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Принять оплату'**
  String get cashier_action_accept_payment;

  /// Экран: SCR-30. ч. D; UI-30-003. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Каталог'**
  String get cashier_action_catalog;

  /// Экран: SCR-30. ч. D; тултип disabled. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет сети: операции оплаты недоступны'**
  String get cashier_action_offline_hint;

  /// Экран: SCR-30. ч. D; UI-30-004. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидают оплаты · {count}'**
  String cashier_awaiting_title(int count);

  /// Экран: SCR-30. ч. D; лист UI-30-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все просрочки'**
  String get cashier_debts_all;

  /// Экран: SCR-30. ч. D; нет снимка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет данных из 1С о долгах'**
  String get cashier_debts_no_data;

  /// Экран: SCR-30. ч. D; пусто. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Просроченных долгов нет'**
  String get cashier_debts_none;

  /// Экран: SCR-30. ч. D; UI-30-007. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Просрочено: {count, plural, one{{count} клиент} few{{count} клиента} many{{count} клиентов} other{{count} клиента}} на {amount}'**
  String cashier_debts_summary(String amount, int count);

  /// Экран: SCR-30. ч. D; Z6. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долги и просрочки'**
  String get cashier_debts_title;

  /// Экран: SCR-30. ч. D; UI-30-009. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ваш лимит ручной скидки: {percent}'**
  String cashier_discounts_limit(String percent);

  /// Экран: SCR-30. ч. D; UI-30-009. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сверх лимита подтверждает: {roles}'**
  String cashier_discounts_override(String roles);

  /// Экран: SCR-30. ч. D; UI-30-009. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Правил скидок 1С: {count}'**
  String cashier_discounts_rules_count(int count);

  /// Экран: SCR-30. ч. D; Z7. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скидки и условия продаж'**
  String get cashier_discounts_title;

  /// Экран: SCR-30. ч. D; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент убран из избранного'**
  String get cashier_favorite_removed;

  /// Экран: SCR-30. ч. D; пусто. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отмечайте клиентов звездой, чтобы они появились здесь'**
  String get cashier_favorites_empty;

  /// Экран: SCR-30. ч. D; UI-30-005. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Избранные клиенты'**
  String get cashier_favorites_title;

  /// Экран: SCR-30. ч. D; Error. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось загрузить данные кассы'**
  String get cashier_load_error;

  /// Экран: SCR-30. ч. D; пусто. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ «{q}» не найден'**
  String cashier_lookup_not_found(String q);

  /// Экран: SCR-30. ч. D; строка `isPaid`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплачен'**
  String get cashier_lookup_order_paid;

  /// Экран: SCR-30. ч. D; поле. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Номер заказа или скан с распечатки'**
  String get cashier_lookup_order_placeholder;

  /// Экран: SCR-30. ч. D; вкладка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент (долг)'**
  String get cashier_lookup_tab_customer;

  /// Экран: SCR-30. ч. D; вкладка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ'**
  String get cashier_lookup_tab_order;

  /// Экран: SCR-30. ч. D; лист UI-30-016. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Найти заказ или клиента'**
  String get cashier_lookup_title;

  /// Экран: SCR-30. ч. D; OfflineNoData. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет сети. Данные кассы недоступны без подключения'**
  String get cashier_offline_no_data;

  /// Экран: SCR-30. ч. D; UI-30-015. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все транзакции'**
  String get cashier_recent_all;

  /// Экран: SCR-30. ч. D; пусто. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Операций за сегодня нет'**
  String get cashier_recent_empty;

  /// Экран: SCR-30. ч. D; UI-30-006. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Недавние операции'**
  String get cashier_recent_title;

  /// Экран: SCR-30. ч. D; ReadyStale. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось обновить, данные от {time}'**
  String cashier_refresh_failed(String time);

  /// Экран: SCR-30. ч. D; UI-30-012. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Требуют разбора · {count}'**
  String cashier_review_title(int count);

  /// Экран: SCR-30. ч. D; поле UI-30-002. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент: имя, телефон или код 1С'**
  String get cashier_search_placeholder;

  /// Экран: SCR-30. ч. D; < 2 символов + Enter. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите не менее 2 символов'**
  String get cashier_search_too_short;

  /// Экран: SCR-30. ч. D; UI-30-001. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ошибка обмена с 1С: {entity}. Последний успешный обмен — {time}. Ошибок: {count}'**
  String cashier_sync_banner(int count, String entity, String time);

  /// Экран: SCR-30. ч. D; UI-30-001, если `consecutiveErrors` не пришло. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ошибка обмена с 1С: {entity}. Последний успешный обмен — {time}'**
  String cashier_sync_banner_no_count(String entity, String time);

  /// Экран: SCR-30. ч. D; UI-30-001/010. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Открыть статус'**
  String get cashier_sync_open;

  /// Экран: SCR-30. ч. D; Z8. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Синхронизация с 1С'**
  String get cashier_sync_title;

  /// Экран: SCR-30. ч. D; заголовок. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Касса'**
  String get cashier_title;

  /// Экран: SCR-30. ч. D; плитки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Наличные'**
  String get cashier_totals_cash;

  /// Экран: SCR-30. ч. D; строка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказов: {orders} · Платежей: {payments}'**
  String cashier_totals_counts(String orders, String payments);

  /// Экран: SCR-30. ч. D; плитки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В долг'**
  String get cashier_totals_credit;

  /// Экран: SCR-30. ч. D; плитки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'QR'**
  String get cashier_totals_qr;

  /// Экран: SCR-30. ч. D; UI-30-014. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сегодня'**
  String get cashier_totals_title;

  /// Экран: SCR-30. ч. D; п.11 SCR-30, SCR-37, SCR-38, SCR-39). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверить'**
  String get cashier_unfinished_check;

  /// Экран: SCR-30. ч. D; описание баннера (P-IDEMP); `{amount}` — сумма заказа, не долг; для долга — без суммы и имени. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'подтверждение QR по заказу № {number}'**
  String cashier_unfinished_desc_confirm(String number);

  /// Экран: SCR-30. ч. D; описание баннера (P-IDEMP); `{amount}` — сумма заказа, не долг; для долга — без суммы и имени. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'оплата долга клиента'**
  String get cashier_unfinished_desc_debt;

  /// Экран: SCR-30. ч. D; описание баннера (P-IDEMP); `{amount}` — сумма заказа, не долг; для долга — без суммы и имени. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'приём {amount} по заказу № {number}'**
  String cashier_unfinished_desc_order(String amount, String number);

  /// Экран: SCR-30. ч. D; описание баннера. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'заявка на возврат по заказу № {number}'**
  String cashier_unfinished_desc_return(String number);

  /// Экран: SCR-30. ч. D; описание баннера (P-IDEMP); `{amount}` — сумма заказа, не долг; для долга — без суммы и имени. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'аннулирование платежа № {number}'**
  String cashier_unfinished_desc_void(String number);

  /// Экран: SCR-30. ч. D; баннер при незавершённой операции в памяти текущей сессии (P-IDEMP; в drift не хранится). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Незавершённая операция: {description}'**
  String cashier_unfinished_operation(String description);

  /// Экран: SCR-30. ч. D; UI-30-018. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'обновлено {time}'**
  String cashier_updated_at(String time);

  /// Экран: SCR-10/11/12 (compact). ч. B; v1.1; ANIM-006 (03 §11.2); версия 1.23: на medium и шире вместо снекбара — тост `catalog_added_toast` (ADR-112), у `customer` действие тоста «Открыть» — вторая часть этой строки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Добавлено · Открыть'**
  String get catalog_added_snackbar;

  /// Экран: SCR-10/11/12, medium+. прототип 2026-10-29, ADR-112, версия 1.16; тост после «+ Добавить»; на compact остаётся `catalog_added_snackbar`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Добавлено: {name}'**
  String catalog_added_toast(String name);

  /// Экран: карточки. ч. B; Semantics. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{name}, {price} за {unitFull}, {stock}, артикул {sku}'**
  String catalog_card_a11y(String name, String price, String sku, String stock, String unitFull);

  /// Экран: карточки. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выбрать вариант'**
  String get catalog_card_choose_variant;

  /// Экран: SCR-10/11/12, карточки сетки и списка (SCR-50 — через общий компонент). прототип 2026-10-29, ADR-112, версия 1.16; кнопка карточки, когда товар уже в корзине (вместо `QuantityStepper`, UI-10-109); нажатие добавляет шаг; `{qty}` — String, отформатированное количество. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В корзине · {qty} — ещё +1'**
  String catalog_card_in_cart_add_more(String qty);

  /// Экран: SCR-10/11/12, вид «Компакт». прототип 2026-10-29, ADR-112, версия 1.16; короткая кнопка строки таблицы для товара в корзине (UI-10-118). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ещё · {qty}'**
  String catalog_card_in_cart_short(String qty);

  /// Экран: карточки. ч. B; INV-042. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Доступно {qty} {unit}'**
  String catalog_card_max_available(String qty, String unit);

  /// Экран: SCR-10/11/12/40. ч. B; v1.1; UI-10-119. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Другой вариант'**
  String get catalog_card_other_variant;

  /// Экран: карточки. ч. B; INV-026. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{warehouse}: {qty} {unit}'**
  String catalog_card_other_warehouse(String qty, String unit, String warehouse);

  /// Экран: карточки. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет в наличии'**
  String get catalog_card_out_of_stock;

  /// Экран: карточки. ч. B; CART-013. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Цена изменилась'**
  String get catalog_card_price_changed;

  /// Экран: карточки. ч. B; Q-206. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'от {price}'**
  String catalog_card_price_from(String price);

  /// Экран: карточки. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'/ {unit}'**
  String catalog_card_price_unit(String unit);

  /// Экран: карточки. ч. B; CART-012. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Удалить позицию из корзины?'**
  String get catalog_card_remove_confirm;

  /// Экран: карточки. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Арт. {sku}'**
  String catalog_card_sku(String sku);

  /// Экран: карточки. ч. B; INV-052. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Артикул не указан'**
  String get catalog_card_sku_missing;

  /// Экран: SCR-10/11/12, вид «Компакт». QA прототипа 2026-10-29, ADR-112, версия 1.17; короткая подпись недоступной кнопки строки таблицы при неизвестном остатке (UI-10-118) тем же кеглем, что «+ Добавить»; полная `ds_stock_unknown` — в тултипе и для экранного диктора. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет данных'**
  String get catalog_card_stock_unknown_short;

  /// Экран: SCR-10/11/12/40. ч. B; v1.1; ICU по `count`; UI-10-119. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{variant} · {unit} / {variant} · {unit} · в корзине {count} вар.'**
  String catalog_card_variant_label(int count, String unit, String variant);

  /// Экран: SCR-10. этап E, 03 §16.7 (ADR-097); UI-10-118 заголовок колонки; CAT-UI EQ-CAT-07; с версии 1.16 не используется: колонка убрана из «Компакта» (UI-10-118, ADR-112 п. 3), ключ сохранён до ответа на Q-334 (откат «Компакта»). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Доступно'**
  String get catalog_compact_col_available;

  /// Экран: SCR-10. этап E, 03 §16.7 (ADR-097); UI-10-118 заголовок колонки; CAT-UI EQ-CAT-07. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Наименование'**
  String get catalog_compact_col_name;

  /// Экран: SCR-10. этап E, 03 §16.7 (ADR-097); UI-10-118: заголовок колонки «Фото» визуально пустой, текст — только `Semantics`; CAT-UI EQ-CAT-07; с версии 1.16 не используется: колонка убрана из «Компакта» (UI-10-118, ADR-112 п. 3), ключ сохранён до ответа на Q-334 (откат «Компакта»). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Фото'**
  String get catalog_compact_col_photo_a11y;

  /// Экран: SCR-10. этап E, 03 §16.7 (ADR-097); UI-10-118 заголовок колонки; CAT-UI EQ-CAT-07. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Цена'**
  String get catalog_compact_col_price;

  /// Экран: SCR-10. этап E, 03 §16.7 (ADR-097); UI-10-118 заголовок колонки; CAT-UI EQ-CAT-07; с версии 1.16 не используется: колонка убрана из «Компакта» (UI-10-118, ADR-112 п. 3), ключ сохранён до ответа на Q-334 (откат «Компакта»). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Кол-во'**
  String get catalog_compact_col_qty;

  /// Экран: SCR-10. этап E, 03 §16.7 (ADR-097); UI-10-118 заголовок колонки вида «Компакт»; CAT-UI EQ-CAT-07. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Артикул'**
  String get catalog_compact_col_sku;

  /// Экран: SCR-10/11/12, вид «Компакт». прототип 2026-10-29, ADR-112, версия 1.16; заголовок колонки статуса остатка с количеством (UI-10-118). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Наличие'**
  String get catalog_compact_col_stock;

  /// Экран: SCR-10. этап E, 03 §16.7 (ADR-097); UI-10-118 заголовок колонки (единица); CAT-UI EQ-CAT-07; с версии 1.16 не используется: колонка убрана из «Компакта» (UI-10-118, ADR-112 п. 3), ключ сохранён до ответа на Q-334 (откат «Компакта»). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ед.'**
  String get catalog_compact_col_unit;

  /// Экран: SCR-10. этап E, 03 §16.7 (ADR-097); UI-10-118 заголовок колонки (варианты); CAT-UI EQ-CAT-07; с версии 1.16 не используется: колонка убрана из «Компакта» (UI-10-118, ADR-112 п. 3), ключ сохранён до ответа на Q-334 (откат «Компакта»). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вар.'**
  String get catalog_compact_col_variants;

  /// Экран: SCR-10. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Товары появятся после синхронизации с 1С'**
  String get catalog_empty_category_body;

  /// Экран: SCR-10. ч. B; = `ds_empty_category_title`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В этой категории пока нет товаров'**
  String get catalog_empty_category_title;

  /// Экран: SCR-10. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Измените или сбросьте фильтры'**
  String get catalog_empty_filtered_body;

  /// Экран: SCR-10. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ничего не найдено'**
  String get catalog_empty_filtered_title;

  /// Экран: SCR-10. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось загрузить каталог'**
  String get catalog_error_title;

  /// Экран: SCR-10/11/12/14. ч. B; v1.1; ANIM-009, 03 §9.23. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Добавлено в избранное · Отменить'**
  String get catalog_favorite_added;

  /// Экран: SCR-10/11/12/14. ч. B; v1.1; снекбар `error`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось сохранить избранное · Повторить'**
  String get catalog_favorite_error;

  /// Экран: SCR-10/11/12/14. ч. B; v1.1. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Удалено из избранного · Отменить'**
  String get catalog_favorite_removed;

  /// Экран: SCR-10/11/12. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Фильтры'**
  String get catalog_filters_button;

  /// Экран: SCR-10/11/12, встроенная панель фильтров. прототип 2026-10-29, ADR-112, версия 1.16; ссылка сброса в панели; `filters_reset_all` «Сбросить все» остаётся для активных фильтров. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сбросить фильтры'**
  String get catalog_filters_reset;

  /// Экран: SCR-10. ч. B; ICU plural (03 §16.3). Источник: 02 §7; формы «a / b / c» 02 §7 преобразованы в ICU plural (03 §16.3); текст совпадает с 03 §16.3
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{Найдено: {count} товар} few{Найдено: {count} товара} many{Найдено: {count} товаров} other{Найдено: {count} товара}}'**
  String catalog_found_count(int count);

  /// Экран: SCR-10. ч. B; версия 1.5; UI-10-120; 04 FLOW-001.S8. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Каталог загружен'**
  String get catalog_initial_load_done;

  /// Экран: SCR-10. ч. B; первичная загрузка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Загружаем каталог… {percent} %'**
  String catalog_initial_loading(String percent);

  /// Экран: SCR-10/11/12. ч. B; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Загружаем ещё товары…'**
  String get catalog_loading_more;

  /// Экран: SCR-10/11/12. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось загрузить · Повторить'**
  String get catalog_loading_more_error;

  /// Экран: SCR-10. ч. B; чип подборки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Избранное'**
  String get catalog_preset_favorites;

  /// Экран: SCR-10/12, medium+. прототип 2026-10-29, ADR-112, версия 1.16; кнопка строки управления, `favorite=true`; `catalog_preset_favorites` остаётся для compact и SCR-50. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Избранные'**
  String get catalog_preset_favorites_toolbar;

  /// Экран: SCR-10/12, medium+. прототип 2026-10-29, ADR-112, версия 1.16; кнопка строки управления, сортировка `updatedAt:desc` (CQ-LAY-04 пересмотрен ADR-112); `catalog_sort_newest` «Сначала новые» остаётся в меню сортировки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Новые'**
  String get catalog_preset_newest;

  /// Экран: SCR-10. ч. B; чип подборки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Недавние'**
  String get catalog_preset_recent;

  /// Экран: SCR-10. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выйти из аккаунта?'**
  String get catalog_profile_logout_confirm;

  /// Экран: SCR-10. ч. B; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Очистить'**
  String get catalog_recent_clear;

  /// Экран: SCR-10. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Список недавно просмотренных товаров будет удалён на всех устройствах'**
  String get catalog_recent_clear_confirm_body;

  /// Экран: SCR-10. ч. B; `ConfirmDialog`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Очистить недавние товары?'**
  String get catalog_recent_clear_confirm_title;

  /// Экран: SCR-10. ч. B; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось очистить · Повторить'**
  String get catalog_recent_clear_error;

  /// Экран: SCR-10. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нужна сеть'**
  String get catalog_recent_clear_offline_tooltip;

  /// Экран: SCR-10. ч. B; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Недавние товары'**
  String get catalog_recent_title;

  /// Экран: SCR-10. ч. B; снекбар HID. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'+{qty} · {name}'**
  String catalog_scan_added(String name, String qty);

  /// Экран: SCR-10. ч. B; Windows. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Используйте сканер: наведите на штрихкод и нажмите курок'**
  String get catalog_scanner_hid_hint;

  /// Экран: SCR-10. ч. B; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Категории товаров'**
  String get catalog_sidebar_categories_title;

  /// Экран: SCR-10/11/12. паритет функций 2026-10-29, ADR-112, версия 1.20; UI-10-046: кнопка внизу колонки категорий (medium+), колонка сворачивается до 72, выбор сохраняется (`sidebarCollapsed`). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Свернуть каталог'**
  String get catalog_sidebar_collapse;

  /// Экран: SCR-10/11/12. паритет функций 2026-10-29, ADR-112, версия 1.20; UI-10-046: та же кнопка в свёрнутой колонке. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Развернуть каталог'**
  String get catalog_sidebar_expand;

  /// Экран: SCR-10. ч. B; макет, со счётчиком. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Избранное'**
  String get catalog_sidebar_favorites;

  /// Экран: SCR-10/11/12. ч. B; `available:desc` (ядро §19.2; Q-204 закрыт). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сначала в наличии'**
  String get catalog_sort_in_stock_first;

  /// Экран: SCR-10/12. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'По названию А–Я'**
  String get catalog_sort_name_asc;

  /// Экран: SCR-10/12. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'По названию Я–А'**
  String get catalog_sort_name_desc;

  /// Экран: SCR-10/12. ч. B; `updatedAt:desc`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сначала новые'**
  String get catalog_sort_newest;

  /// Экран: SCR-10/11/12. ч. B; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'По возрастанию цены'**
  String get catalog_sort_price_asc;

  /// Экран: SCR-10/11/12. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'По убыванию цены'**
  String get catalog_sort_price_desc;

  /// Экран: SCR-11. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'По релевантности'**
  String get catalog_sort_relevance;

  /// Экран: SCR-10/11/12. ч. B; `sku:asc` (ядро §19.2; Q-204 закрыт). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'По артикулу'**
  String get catalog_sort_sku;

  /// Экран: SCR-10. ч. B; заголовок корня; также первая плитка ленты подкатегорий (ADR-112). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все товары'**
  String get catalog_title_all;

  /// Экран: SCR-10. ч. B; `ViewModeSegmented`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Компакт'**
  String get catalog_view_compact;

  /// Экран: SCR-10. ч. B; `ViewModeSegmented`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сетка'**
  String get catalog_view_grid;

  /// Экран: SCR-10. ч. B; `ViewModeSegmented`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Список'**
  String get catalog_view_list;

  /// Экран: SCR-12. ч. B; compact. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все категории'**
  String get category_all_categories;

  /// Экран: SCR-12. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все'**
  String get category_all_chip;

  /// Экран: SCR-12/14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Каталог'**
  String get category_breadcrumb_root;

  /// Экран: SCR-12. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Товары появятся после синхронизации с 1С или снимите фильтры'**
  String get category_empty_body;

  /// Экран: SCR-12. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось загрузить категорию'**
  String get category_error_title;

  /// Экран: SCR-12. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Фильтр «{name}» снят — нет товаров в категории'**
  String category_filter_removed(String name);

  /// Экран: SCR-12. ч. B; ICU. Источник: 02 §7; формы «a / b / c» 02 §7 преобразованы в ICU plural (03 §16.3)
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{Найдено: {count} товар} few{Найдено: {count} товара} many{Найдено: {count} товаров} other{Найдено: {count} товара}}'**
  String category_found_count(int count);

  /// Экран: SCR-12. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'К каталогу'**
  String get category_not_found_action;

  /// Экран: SCR-12. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Категория больше не существует'**
  String get category_not_found_title;

  /// Экран: SCR-10/12. ревью переноса прототипа 2026-10-29, ADR-112, версия 1.19; `Semantics` первой карточки ленты «Все товары» (`catalog_title_all`): видимая подпись входит в доступное имя (WCAG 2.5.3); `{name}` — раздел; ICU plural (03 §16.3). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{Все товары: {name}, {count} товар} few{Все товары: {name}, {count} товара} many{Все товары: {name}, {count} товаров} other{Все товары: {name}, {count} товара}}'**
  String category_ribbon_all_a11y(int count, String name);

  /// Экран: SCR-10/12. прототип 2026-10-29, ADR-112, версия 1.16; стрелка ленты, тултип и Semantics. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Прокрутить подкатегории вправо'**
  String get category_ribbon_next;

  /// Экран: SCR-10/12. прототип 2026-10-29, ADR-112, версия 1.16; стрелка ленты, тултип и Semantics; закрывает CQ-LAY-02. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Прокрутить подкатегории влево'**
  String get category_ribbon_prev;

  /// Экран: SCR-12. ч. B; Semantics; ICU plural (03 §16.3) — «Смесители, 124 товара» (SCR-12.8), до версии 1.19 — «{name}, {count} товаров» без склонения (ревью переноса прототипа 2026-10-29, ADR-112, версия 1.19). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{{name}, {count} товар} few{{name}, {count} товара} many{{name}, {count} товаров} other{{name}, {count} товара}}'**
  String category_tile_a11y(int count, String name);

  /// Экран: SCR-12. ч. B; INV-052. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Без категории'**
  String get category_uncategorized;

  /// Экран: SCR-21. ч. C; 07 §11.2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Корзина и выбранные параметры сохранятся. Адрес и телефоны получателя придётся ввести заново'**
  String get checkout_abort_body;

  /// Экран: SCR-21. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Прервать'**
  String get checkout_abort_confirm;

  /// Экран: SCR-21. ч. C; фокус по умолчанию. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продолжить оформление'**
  String get checkout_abort_continue;

  /// Экран: SCR-21. ч. C; UI-21-030. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Прервать оформление?'**
  String get checkout_abort_title;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите адрес доставки'**
  String get checkout_address_hint;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Адрес доставки'**
  String get checkout_address_label;

  /// Экран: SCR-21. ч. C; Адрес. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите адрес доставки'**
  String get checkout_address_required;

  /// Экран: SCR-21. ч. C; Адрес. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Адрес не длиннее 300 символов'**
  String get checkout_address_too_long;

  /// Экран: SCR-21. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вернуться в корзину'**
  String get checkout_back_to_cart;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отмена'**
  String get checkout_cancel;

  /// Экран: SCR-21. ч. C; ORD-008. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверено в 1С · {time}'**
  String checkout_checked_onec(String time);

  /// Экран: SCR-21. ч. C; STALE_DATA. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверено по данным от {time}'**
  String checkout_checked_snapshot(String time);

  /// Экран: SCR-21. ч. C; Комментарий. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{count}/200'**
  String checkout_comment_counter(int count);

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Комментарий для курьера…'**
  String get checkout_comment_hint;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Комментарий курьеру (необязательно)'**
  String get checkout_comment_label;

  /// Экран: SCR-21. ч. C; CREDIT_*. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продажа в долг недоступна: {reason}'**
  String checkout_conflict_credit(String reason);

  /// Экран: SCR-21. ч. C; DISCOUNT_LIMIT_EXCEEDED. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скидка больше лимита роли ({limit} %)'**
  String checkout_conflict_discount(String limit);

  /// Экран: SCR-21. ч. C; PRICE_CHANGED. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Цена изменилась: {name} — было {old}, стало {newValue}'**
  String checkout_conflict_price(String name, String newValue, String old);

  /// Экран: SCR-21. ч. C; STOCK_INSUFFICIENT. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Недостаточно остатка: {name} — доступно {available}'**
  String checkout_conflict_stock(String available, String name);

  /// Экран: SCR-21. ч. C; VARIANT_UNAVAILABLE. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Товар больше не продаётся: {name}'**
  String checkout_conflict_unavailable(String name);

  /// Экран: SCR-21. ч. C; UI-21-021. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ нельзя создать: данные изменились'**
  String get checkout_conflicts_title;

  /// Экран: SCR-21. ч. C; UI-21-009. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'По умолчанию — телефон получателя'**
  String get checkout_courier_phone_hint;

  /// Экран: SCR-21. ч. C; IDEMPOTENCY_KEY_REUSED / INTERNAL. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось создать заказ. Код обращения: {requestId}'**
  String checkout_create_failed(String requestId);

  /// Экран: SCR-21. ч. C; через 8 с. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'1С отвечает дольше обычного — заказ будет отправлен автоматически'**
  String get checkout_creating_slow;

  /// Экран: SCR-21. ч. C; UI-21-028. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Разрешить продажу в долг'**
  String get checkout_credit_allow;

  /// Экран: SCR-21. ч. C; обязательно, ≤ 200. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Причина разрешения'**
  String get checkout_credit_allow_reason_label;

  /// Экран: SCR-21. ч. C; PAY-032. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Разрешено: {name}'**
  String checkout_credit_allowed_by(String name);

  /// Экран: SCR-21. ч. C; CASH-007. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Разрешить продажу в долг может старший продавец или администратор в своей учётной записи. Отложите заказ — старший откроет его на своём устройстве и оформит сам, либо выйдите, чтобы он вошёл на этом терминале'**
  String get checkout_credit_approval_dialog_body;

  /// Экран: SCR-21. ч. C; UI-21-027. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отложить заказ'**
  String get checkout_credit_approval_park;

  /// Экран: SCR-21. ч. C; UI-21-027, кнопка диалога. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Понятно'**
  String get checkout_credit_help_ok;

  /// Экран: SCR-21. ч. C; UI-21-027. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Как получить разрешение старшего'**
  String get checkout_credit_how_to_approve;

  /// Экран: SCR-21. ч. C; Клиент для `credit`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Для продажи в долг выберите клиента из 1С'**
  String get checkout_credit_needs_customer;

  /// Экран: SCR-21. ч. C; имя отложенной корзины. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долг: {customer} · {time}'**
  String checkout_credit_parked_name(String customer, String time);

  /// Экран: SCR-21. ч. C; CREDIT_LIMIT_EXCEEDED. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Превышен лимит: доступно {remaining}'**
  String checkout_credit_reason_limit(String remaining);

  /// Экран: SCR-21. ч. C; DEBT-012; **с версии 1.6 не используется** — неполный снимок даёт `stale_snapshot` (`checkout_credit_reason_stale`), значение `no_data` в 08 нет (ядро §22.4, §23 п.5). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет данных из 1С о просрочке или лимите'**
  String get checkout_credit_reason_no_data;

  /// Экран: SCR-21. ч. C; admin (Q-208). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет права продажи в долг'**
  String get checkout_credit_reason_no_permission;

  /// Экран: SCR-21. ч. C; `CREDIT_BLOCKED`, `creditReason=credit_not_allowed` (ядро §23 п.5). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отсрочка не разрешена соглашением'**
  String get checkout_credit_reason_not_allowed;

  /// Экран: SCR-21. ч. C; `422 CUSTOMER_NOT_IDENTIFIED` без `creditReason` (ядро §23 п.5). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выберите клиента из 1С'**
  String get checkout_credit_reason_not_identified;

  /// Экран: SCR-21. ч. C; PAY-033; **с версии 1.5 не используется** — для долга `503` не возвращается, недоступность 1С при устаревшем снимке — `checkout_credit_reason_stale` (ядро §22.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'1С недоступна: продажа в долг невозможна, выберите наличные или QR'**
  String get checkout_credit_reason_onec_unavailable;

  /// Экран: SCR-21. ч. C; `CREDIT_BLOCKED`, `creditReason=overdue`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Есть просроченная задолженность {amount}'**
  String checkout_credit_reason_overdue(String amount);

  /// Экран: SCR-21. ч. C; PAY-036. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продажа в долг недоступна: обратитесь к старшему продавцу'**
  String get checkout_credit_reason_seller;

  /// Экран: SCR-21. ч. C; RECEIVABLES_STALE (`stale_snapshot`); текст — 10 PAY-033 (версия 1.5). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Данные о долге устарели, 1С недоступна: продажа в долг невозможна, выберите наличные или QR'**
  String get checkout_credit_reason_stale;

  /// Экран: SCR-21. ч. C; cash; admin. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Создать заказ'**
  String get checkout_cta_create;

  /// Экран: SCR-21. ч. C; credit. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Создать заказ в долг'**
  String get checkout_cta_create_credit;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Создать заказ и показать QR'**
  String get checkout_cta_create_qr;

  /// Экран: SCR-21. ч. C; loading. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Создаём заказ…'**
  String get checkout_cta_creating;

  /// Экран: SCR-21. ч. C; D-32. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нужна сеть'**
  String get checkout_cta_offline;

  /// Экран: SCR-21. ч. C; seller. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'нет'**
  String get checkout_customer_debt_flag_no;

  /// Экран: SCR-21. ч. C; seller. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'просрочка'**
  String get checkout_customer_debt_flag_overdue;

  /// Экран: SCR-21. ч. C; seller (Q-017). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'есть'**
  String get checkout_customer_debt_flag_yes;

  /// Экран: SCR-21. ч. C; UI-21-005; для seller долг — «есть / нет / просрочка». Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'История: {orders} · Долг: {debt} · Скидка: {discount}'**
  String checkout_customer_meta(String debt, String discount, String orders);

  /// Экран: SCR-21. ч. C; макет; UI-21-004. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'+ Новый клиент'**
  String get checkout_customer_new;

  /// Экран: SCR-21. ч. C; CustomerPicker empty. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиенты не найдены по «{query}»'**
  String checkout_customer_not_found(String query);

  /// Экран: SCR-21. ч. C; версия 1.7; `customer`, вместо подписи о создании в 1С. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заявка уйдёт в магазин на согласование. Цены и наличие магазин подтвердит при согласовании'**
  String get checkout_customer_onec_note;

  /// Экран: SCR-21. ч. C; версия 1.7; плитка `cash` для `customer`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата при получении'**
  String get checkout_customer_pay_on_pickup;

  /// Экран: SCR-21. ч. C; версия 1.7; плитка `qr_bakai` для `customer` при `features.qrProvider ≠ none`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплатить по QR'**
  String get checkout_customer_pay_qr;

  /// Экран: SCR-21. ч. C; CUST-014. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидает 1С'**
  String get checkout_customer_pending_onec;

  /// Экран: SCR-21. ч. C; версия 1.7; `QR_PROVIDER=none` или `payment_method_unavailable`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата по QR сейчас недоступна. Выберите оплату при получении'**
  String get checkout_customer_qr_unavailable;

  /// Экран: SCR-21. ч. C; UI-21-023; Q-026. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Розничный покупатель'**
  String get checkout_customer_retail_chip;

  /// Экран: SCR-21. ч. C; макет; UI-21-003. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите имя, телефон или часть имени…'**
  String get checkout_customer_search_hint;

  /// Экран: SCR-21. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выбрать дату…'**
  String get checkout_date_pick;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сегодня'**
  String get checkout_date_today;

  /// Экран: SCR-21. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Завтра'**
  String get checkout_date_tomorrow;

  /// Экран: SCR-21. ч. C; PAY-035. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долг после заказа (прогноз): {amount} · лимит доступен: {limit} · данные 1С от {time}'**
  String checkout_debt_forecast(String amount, String limit, String time);

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Доставка курьером'**
  String get checkout_delivery_hint;

  /// Экран: SCR-21. ч. C; Способ получения. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выберите способ получения'**
  String get checkout_delivery_method_required;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Доставка'**
  String get checkout_delivery_title;

  /// Экран: SCR-21. ч. C; ORD-022. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Похожий заказ № {number} создан {minutes} мин назад. Создать ещё один?'**
  String checkout_duplicate_body(int minutes, String number);

  /// Экран: SCR-21. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Создать ещё один'**
  String get checkout_duplicate_create;

  /// Экран: SCR-21. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Открыть заказ'**
  String get checkout_duplicate_open;

  /// Экран: SCR-21. ч. C; ORD-022. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Похожий заказ уже создан'**
  String get checkout_duplicate_title;

  /// Экран: SCR-21. ч. C; FORBIDDEN. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Недостаточно прав для этого способа оплаты'**
  String get checkout_forbidden_payment;

  /// Экран: SCR-21. ч. C; Сводка ошибок. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Исправьте поля: {count}'**
  String checkout_form_errors_summary(int count);

  /// Экран: SCR-21. ч. C; ICU plural; макет «5 товаров» заменено. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'({count} позиций)'**
  String checkout_items_count(int count);

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Изменить'**
  String get checkout_items_edit;

  /// Экран: SCR-21. ч. C; disabled в R1. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выбрать на карте'**
  String get checkout_map_button;

  /// Экран: SCR-21. ч. C; Q-178. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Карта — в следующей версии'**
  String get checkout_map_tooltip;

  /// Экран: SCR-21. ч. C; UI-21-020. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Далее'**
  String get checkout_next;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ будет создан в 1С и отправлен на согласование'**
  String get checkout_onec_note;

  /// Экран: SCR-21. ч. C; ORD-026. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ будет отправлен в 1С автоматически, как только она станет доступна'**
  String get checkout_onec_note_offline;

  /// Экран: SCR-21. ч. C; UI-21-031. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'1С сейчас недоступна. Заказ будет отправлен в 1С автоматически. Продажа в долг — только по актуальным данным о долге'**
  String get checkout_onec_unavailable_banner;

  /// Экран: SCR-21. ч. C; ORD-027. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Открыть восстановленную корзину'**
  String get checkout_open_restored_cart;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата в нашем магазине'**
  String get checkout_pay_cash_hint;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Наличными в кассу'**
  String get checkout_pay_cash_title;

  /// Экран: SCR-21. ч. C; PaymentMethodCard loading. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверяем долг…'**
  String get checkout_pay_checking_debt;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата позже (по согласованию)'**
  String get checkout_pay_credit_hint;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Без оплаты / долг'**
  String get checkout_pay_credit_title;

  /// Экран: SCR-21. ч. C; PAY-010; переход в SCR-38 — кнопкой UI-22-012. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'После создания заказа нажмите «Принять оплату»'**
  String get checkout_pay_info_cash_cashier;

  /// Экран: SCR-21. ч. C; PAY-011. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'После создания заказа передайте клиента в кассу'**
  String get checkout_pay_info_cash_seller;

  /// Экран: SCR-21. ч. C; PAY-034. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Срок оплаты — по соглашению с клиентом в 1С: до {date}'**
  String checkout_pay_info_credit(String date);

  /// Экран: SCR-21. ч. C; PAY-022. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'После создания заказа будет показан QR-код Бакай Банка. Оплату подтвердит кассир по выписке банка'**
  String get checkout_pay_info_qr_manual;

  /// Экран: SCR-21. ч. C; только при QR_WEBHOOK_ENABLED (PAY-027). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'После создания заказа будет сформирован QR-код для оплаты через Бакай Банк. После оплаты заказ будет автоматически отмечен как оплаченный'**
  String get checkout_pay_info_qr_webhook;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата картой по QR'**
  String get checkout_pay_qr_hint;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'QR / карта Бакай Банк'**
  String get checkout_pay_qr_title;

  /// Экран: SCR-21. ч. C; Способ оплаты. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выберите способ оплаты'**
  String get checkout_payment_required;

  /// Экран: SCR-21. ч. C; Телефон другого получателя / телефон получателя доставки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите 9 цифр номера'**
  String get checkout_phone_invalid;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент заберёт сам'**
  String get checkout_pickup_hint;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Самовывоз'**
  String get checkout_pickup_title;

  /// Экран: SCR-21. ч. C; после перезапуска. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Адрес и телефоны получателя не сохраняются на устройстве — введите их заново'**
  String get checkout_pii_not_saved_hint;

  /// Экран: SCR-21. ч. C; макет «Печатать счёт на оплату». Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Счёт на оплату'**
  String get checkout_print_invoice;

  /// Экран: SCR-21. ч. C; PRINT-002, PRINT-003. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'PDF, A4; печать после получения номера 1С'**
  String get checkout_print_invoice_hint;

  /// Экран: SCR-21. ч. C; PrintOptions disabled. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Настройте принтер в Настройках'**
  String get checkout_print_printer_missing;

  /// Экран: SCR-21. ч. C; PRINT-005. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Товарный чек'**
  String get checkout_print_receipt;

  /// Экран: SCR-21. ч. C; D-26. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не является фискальным документом, 80 мм'**
  String get checkout_print_receipt_hint;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Печать после создания заказа'**
  String get checkout_print_title;

  /// Экран: SCR-21. ч. C; PRINT-004. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Накладная (предварительная)'**
  String get checkout_print_waybill;

  /// Экран: SCR-21. ч. C; PRINT-004. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не является документом отгрузки; накладная — из 1С'**
  String get checkout_print_waybill_hint;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент'**
  String get checkout_receiver_customer;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Получает сам клиент'**
  String get checkout_receiver_customer_hint;

  /// Экран: SCR-21. ч. C; UI-21-024. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'ФИО получателя'**
  String get checkout_receiver_name_label;

  /// Экран: SCR-21. ч. C; ФИО другого получателя. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите ФИО получателя'**
  String get checkout_receiver_name_required;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Другой человек'**
  String get checkout_receiver_other;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Товар получает другой человек'**
  String get checkout_receiver_other_hint;

  /// Экран: SCR-21. ч. C; UI-21-025. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Телефон получателя'**
  String get checkout_receiver_phone_label;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Получатель'**
  String get checkout_receiver_title;

  /// Экран: SCR-21. ч. C; UI-21-009 (доставка; отличается от `checkout_receiver_phone_label`). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Телефон для курьера'**
  String get checkout_recipient_phone_label;

  /// Экран: SCR-21. ч. C; ONEC_REJECTED. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'1С отклонила заказ: {reason}'**
  String checkout_rejected_onec(String reason);

  /// Экран: SCR-21, SCR-22, SCR-26. ч. C; HID-скан. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Закройте оформление, чтобы сканировать товары'**
  String get checkout_scan_ignored;

  /// Экран: SCR-21. ч. C; заголовок секции. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент'**
  String get checkout_section_customer;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Получение товара'**
  String get checkout_section_delivery;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Состав заказа'**
  String get checkout_section_items;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата'**
  String get checkout_section_payment;

  /// Экран: SCR-21. ч. C; Дата и интервал. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Этот интервал уже прошёл'**
  String get checkout_slot_past;

  /// Экран: SCR-21. ч. C; Дата и интервал. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выберите дату и время доставки'**
  String get checkout_slot_required;

  /// Экран: SCR-21. ч. C; макет «с 14:00 до 18:00». Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'с {from} до {to}'**
  String checkout_slot_value(String from, String to);

  /// Экран: SCR-21. ч. C; compact. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Шаг {step} из 4 · {title}'**
  String checkout_step_counter(String step, String title);

  /// Экран: SCR-21. этап F, 03 §16.8 (ADR-103); compact, число шагов из параметра (у клиента 3 шага, SCR-21.1 «Уточнения» п. 1); `{total}` — число шагов строкой; FQ-CHK-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Шаг {step} из {total} · {title}'**
  String checkout_step_counter_n(String step, String title, String total);

  /// Экран: SCR-21. ч. C; CheckoutStepper. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент'**
  String get checkout_step_customer;

  /// Экран: SCR-21. ч. C; CheckoutStepper. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Получение'**
  String get checkout_step_delivery;

  /// Экран: SCR-21. ч. C; CheckoutStepper. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Завершение'**
  String get checkout_step_done;

  /// Экран: SCR-21. ч. C; CheckoutStepper. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата'**
  String get checkout_step_payment;

  /// Экран: SCR-21. ч. C; DISC-005. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скидка клиента (из 1С)'**
  String get checkout_summary_customer_discount;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скидка ({percent} %)'**
  String checkout_summary_discount(String percent);

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сумма без скидки'**
  String get checkout_summary_subtotal;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Итого к оплате'**
  String get checkout_summary_total;

  /// Экран: SCR-21. ч. C; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Желаемое время доставки'**
  String get checkout_time_label;

  /// Экран: SCR-21. ч. C; UI-21-001; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтверждение заказа'**
  String get checkout_title;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет долга'**
  String get customer_card_accept_disabled_no_debt;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент ещё не создан в 1С'**
  String get customer_card_accept_disabled_no_onec;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Принять оплату по долгу'**
  String get customer_card_action_accept_debt;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В заказ'**
  String get customer_card_action_to_cart;

  /// Экран: SCR-32. ч. D; NotFound. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'К списку клиентов'**
  String get customer_card_back_to_list;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Код 1С: {code}'**
  String customer_card_code(String code);

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Код POS: {code}'**
  String customer_card_code_pos(String code);

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Контакты не указаны'**
  String get customer_card_contacts_empty;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Контакты и адреса'**
  String get customer_card_contacts_title;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Доступно (прогноз)'**
  String get customer_card_debt_available;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сальдо'**
  String get customer_card_debt_balance;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Лимит'**
  String get customer_card_debt_limit;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Доступно (прогноз) {available} из {limit}'**
  String customer_card_debt_limit_available(String available, String limit);

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет данных из 1С'**
  String get customer_card_debt_no_data;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Просрочено'**
  String get customer_card_debt_overdue;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент добавлен в избранное'**
  String get customer_card_favorite_added;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент убран из избранного'**
  String get customer_card_favorite_removed;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'ИНН: {inn}'**
  String customer_card_inn(String inn);

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Пользователи приложения'**
  String get customer_card_links_title;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Помечен на удаление в 1С'**
  String get customer_card_marked_deleted;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долг: {amount}'**
  String customer_card_metric_debt(String amount);

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долг: нет'**
  String get customer_card_metric_debt_flag_no;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долг: есть'**
  String get customer_card_metric_debt_flag_yes;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скидка: {percent}'**
  String customer_card_metric_discount(String percent);

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'История: {count, plural, one{{count} заказ} few{{count} заказа} many{{count} заказов} other{{count} заказа}}'**
  String customer_card_metric_history(int count);

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Просрочка'**
  String get customer_card_metric_overdue_flag;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент не найден'**
  String get customer_card_not_found;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Карточка клиента недоступна без сети'**
  String get customer_card_offline;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'ожидает 1С'**
  String get customer_card_pending_onec;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продажа в долг станет доступна после создания клиента в 1С'**
  String get customer_card_pending_onec_hint;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'не подтверждён'**
  String get customer_card_phone_not_verified;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'подтверждён'**
  String get customer_card_phone_verified;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В корзине выбран {current}. Скидка клиента и цены будут пересчитаны'**
  String customer_card_replace_body(String current);

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заменить'**
  String get customer_card_replace_cta;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заменить клиента в корзине?'**
  String get customer_card_replace_title;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Системный клиент для розничных продаж без карточки'**
  String get customer_card_retail_system;

  /// Экран: SCR-32. ч. D; HID на карточке. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сканирование доступно в поиске'**
  String get customer_card_scan_hint;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Операции'**
  String get customer_card_segment_operations;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказы'**
  String get customer_card_segment_orders;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Суммы долга и история покупок доступны кассиру'**
  String get customer_card_seller_info;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скидки'**
  String get customer_card_tab_discounts;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'История'**
  String get customer_card_tab_history;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказы и операции'**
  String get customer_card_tab_orders;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долги'**
  String get customer_card_tab_receivables;

  /// Экран: SCR-32. ч. D; ядро §19.4. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Индивидуальный предприниматель'**
  String get customer_card_type_entrepreneur;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Физическое лицо'**
  String get customer_card_type_individual;

  /// Экран: SCR-32. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Юридическое лицо'**
  String get customer_card_type_legal;

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Автоматические скидки и акции 1С применяются при проведении заказа и здесь не показываются'**
  String get customer_discounts_auto_note;

  /// Экран: SCR-35. ч. D; Partial; кнопка — общий «Повторить». Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось загрузить'**
  String get customer_discounts_block_error;

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скидка клиента из 1С: {percent}'**
  String customer_discounts_client_discount(String percent);

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скидка клиента не задана'**
  String get customer_discounts_client_none;

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продажа в долг: разрешена'**
  String get customer_discounts_credit_allowed;

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Лимит долга: {amount}'**
  String customer_discounts_credit_limit(String amount);

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'не разрешена'**
  String get customer_discounts_credit_not_allowed;

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ {subtotal} → скидка {percent} = {discount} → итог {total} (предварительно, итог определяет 1С)'**
  String customer_discounts_example(String discount, String percent, String subtotal, String total);

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Условия клиента недоступны без сети'**
  String get customer_discounts_offline;

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сверх лимита подтверждает: {roles}'**
  String customer_discounts_override_roles(String roles);

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вид цены'**
  String get customer_discounts_price_list;

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вид цены не задан — используется розничный'**
  String get customer_discounts_price_list_default;

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ваш лимит ручной скидки: {percent}'**
  String customer_discounts_role_limit(String percent);

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Действует'**
  String get customer_discounts_rule_active;

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не действует'**
  String get customer_discounts_rule_inactive;

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Итог в 1С'**
  String get customer_discounts_rule_onec_total;

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'1С'**
  String get customer_discounts_rule_source_onec;

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'POS'**
  String get customer_discounts_rule_source_pos;

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Правил для клиента нет'**
  String get customer_discounts_rules_empty;

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Правила скидок'**
  String get customer_discounts_rules_title;

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отсрочка: {days} дн.'**
  String customer_discounts_term_days(String days);

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Условия оплаты'**
  String get customer_discounts_terms_title;

  /// Экран: SCR-35. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скидки и условия'**
  String get customer_discounts_title;

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Изменить период'**
  String get customer_history_change_period;

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Документов: {count}'**
  String customer_history_count(int count);

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долг — только по данным 1С, см. вкладку «Долги»'**
  String get customer_history_debt_note;

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'История из 1С загружена с {date}'**
  String customer_history_depth(String date);

  /// Экран: SCR-33. ч. D; если `historyFrom` пустое (ядро §19.2). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ранние покупки могут отсутствовать'**
  String get customer_history_depth_unknown;

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Покупок за период нет'**
  String get customer_history_empty;

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Показаны все документы за период'**
  String get customer_history_end;

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось загрузить позиции'**
  String get customer_history_items_error;

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'История покупок недоступна без сети'**
  String get customer_history_offline;

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Документы 1С на {time}'**
  String customer_history_onec_as_of(String time);

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Открыть заказ'**
  String get customer_history_open_order;

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'30 дней'**
  String get customer_history_preset_30;

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'90 дней'**
  String get customer_history_preset_90;

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Период…'**
  String get customer_history_preset_custom;

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Год'**
  String get customer_history_preset_year;

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Дата «по» раньше даты «с»'**
  String get customer_history_range_invalid;

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все'**
  String get customer_history_source_all;

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продажи 1С'**
  String get customer_history_source_onec;

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказы POS'**
  String get customer_history_source_pos;

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'История покупок'**
  String get customer_history_title;

  /// Экран: SCR-33. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Покупок на сумму: {amount}'**
  String customer_history_total(String amount);

  /// Экран: SCR-50, SCR-01. ч. E, A; версия 1.5; UI-50-015; 04 FLOW-035.E1. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сервис для покупателей временно недоступен'**
  String get customer_mode_disabled;

  /// Экран: SCR-50, SCR-01. ч. E, A; версия 1.5; UI-50-015. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказы через приложение сейчас не принимаются. Обратитесь в магазин'**
  String get customer_mode_disabled_body;

  /// Экран: SCR-26. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введённые данные не сохранятся'**
  String get customer_new_abort_body;

  /// Экран: SCR-26. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отменить создание'**
  String get customer_new_abort_confirm;

  /// Экран: SCR-26. ч. C; UI-26-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отменить создание клиента?'**
  String get customer_new_abort_title;

  /// Экран: SCR-26. ч. C; UI-26-009. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Адрес'**
  String get customer_new_address_label;

  /// Экран: SCR-26. ч. C; UI-26-018. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось проверить номер на дубли'**
  String get customer_new_check_failed;

  /// Экран: SCR-26. ч. C; UI-26-018. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Повторить проверку'**
  String get customer_new_check_retry;

  /// Экран: SCR-26. ч. C; проверка дублей. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверяем…'**
  String get customer_new_checking;

  /// Экран: SCR-26. ч. C; Комментарий. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{count}/500'**
  String customer_new_comment_counter(int count);

  /// Экран: SCR-26. ч. C; UI-26-010. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Комментарий'**
  String get customer_new_comment_label;

  /// Экран: SCR-26. ч. C; UI-26-014. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Создать клиента'**
  String get customer_new_create;

  /// Экран: SCR-26. ч. C; сеть. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось создать клиента · Повторить'**
  String get customer_new_create_failed;

  /// Экран: SCR-26. ч. C; CUST-014. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент создан · ожидает 1С'**
  String get customer_new_created_snackbar;

  /// Экран: SCR-26. ч. C; UI-26-003, `matchType=inn`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Найден клиент с этим ИНН'**
  String get customer_new_duplicate_inn_title;

  /// Экран: SCR-26. ч. C; CUSTOMER_DUPLICATE_SUSPECTED. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Найден клиент с этим номером'**
  String get customer_new_duplicate_title;

  /// Экран: SCR-26. ч. C; cashier+. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Всё равно создать'**
  String get customer_new_force_create;

  /// Экран: SCR-26. ч. C; UI-26-015. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Причина создания при совпадении номера'**
  String get customer_new_force_reason_label;

  /// Экран: SCR-26. ч. C; префикс в `comment` (UI-26-015), не отображается как отдельная строка UI. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Причина создания при совпадении: {reason}'**
  String customer_new_force_reason_prefix(String reason);

  /// Экран: SCR-26. ч. C; Причина при дубле. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Укажите, почему создаётся новый клиент при совпадении номера'**
  String get customer_new_force_reason_required;

  /// Экран: SCR-26. ч. C; UI-26-003, Windows. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Создать новую карточку, несмотря на совпадение'**
  String get customer_new_force_tooltip;

  /// Экран: SCR-26. ч. C; ИНН. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'ИНН — 14 цифр'**
  String get customer_new_inn_invalid;

  /// Экран: SCR-26. ч. C; UI-26-006. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'ИНН'**
  String get customer_new_inn_label;

  /// Экран: SCR-26. ч. C; UI-26-004. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'ФИО или наименование'**
  String get customer_new_name_label;

  /// Экран: SCR-26. ч. C; ФИО. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите ФИО или наименование'**
  String get customer_new_name_required;

  /// Экран: SCR-26. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Совпадений не найдено'**
  String get customer_new_no_duplicates;

  /// Экран: SCR-26. ч. C; D-32. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нужна сеть, чтобы создать клиента'**
  String get customer_new_offline;

  /// Экран: SCR-26. ч. C; CUST-014. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент сначала сохраняется в приложении и автоматически создаётся в 1С. До подтверждения 1С ему можно продавать за наличные и по QR, но не в долг'**
  String get customer_new_onec_note;

  /// Экран: SCR-26. ч. C; Телефон. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите 9 цифр номера'**
  String get customer_new_phone_invalid;

  /// Экран: SCR-26. ч. C; UI-26-002. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Телефон'**
  String get customer_new_phone_label;

  /// Экран: SCR-26. ч. C; CUST-016. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Если это другой клиент — обратитесь к кассиру или старшему продавцу'**
  String get customer_new_seller_duplicate_hint;

  /// Экран: SCR-26. ч. C; UI-26-003, > 3 кандидатов. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Показать ещё ({count})'**
  String customer_new_show_more(int count);

  /// Экран: SCR-26. ч. C; CUST-012. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверка в 1С сейчас недоступна — возможен дубль. Проверено по данным приложения от {time}'**
  String customer_new_stale_check(String time);

  /// Экран: SCR-26. ч. C; UI-26-001. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Новый клиент'**
  String get customer_new_title;

  /// Экран: SCR-26. ч. C; entrepreneur (ядро §19.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'ИП'**
  String get customer_new_type_entrepreneur;

  /// Экран: SCR-26. ч. C; individual. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Физ. лицо'**
  String get customer_new_type_individual;

  /// Экран: SCR-26. ч. C; legal. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Юр. лицо'**
  String get customer_new_type_legal;

  /// Экран: SCR-26. ч. C; UI-26-003. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выбрать этого клиента'**
  String get customer_new_use_existing;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.3
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{{count} заказ} few{{count} заказа} many{{count} заказов} other{{count} заказа}}'**
  String customer_orders_count(int count);

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выберите клиента'**
  String get customers_search_detail_empty;

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиенты не найдены по «{q}»'**
  String customers_search_empty(String q);

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось найти клиентов'**
  String get customers_search_error;

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все'**
  String get customers_search_filter_all;

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'С долгом'**
  String get customers_search_filter_debt;

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Избранные'**
  String get customers_search_filter_favorites;

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'С просрочкой'**
  String get customers_search_filter_overdue;

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Есть долг'**
  String get customers_search_has_debt;

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите имя, телефон или код клиента'**
  String get customers_search_hint_idle;

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Помечен на удаление'**
  String get customers_search_marked_deleted;

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'по коду'**
  String get customers_search_match_code;

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'по ИНН: {count}'**
  String customers_search_match_inn(int count);

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Найдено по имени'**
  String get customers_search_match_name;

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'по телефону'**
  String get customers_search_match_phone;

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'+ Новый клиент'**
  String get customers_search_new;

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Поиск клиентов недоступен без сети'**
  String get customers_search_offline;

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Просрочка'**
  String get customers_search_overdue_flag;

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'ожидает 1С'**
  String get customers_search_pending_onec;

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Для поиска по телефону введите номер полностью'**
  String get customers_search_phone_full_hint;

  /// Экран: SCR-31. ч. D; примечание к тексту: общий `ds_search_placeholder_customers`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите имя, телефон или часть имени…'**
  String get customers_search_placeholder;

  /// Экран: SCR-20, SCR-21, SCR-31. ч. D; `seller`, ядро §19.4. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите полный номер телефона или код клиента'**
  String get customers_search_seller_hint;

  /// Экран: SCR-31. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиенты'**
  String get customers_search_title;

  /// Экран: SCR-90 A. ч. A; владелец 03; текст взят из п. 8 экрана (в словаре части — ссылка «см. 03 §16.5»). Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Сеть восстановлена. Отправляем изменения…'**
  String get ds_back_online;

  /// Экран: карточки. ч. B; 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'+ Добавить'**
  String get ds_button_add;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Применить'**
  String get ds_button_apply;

  /// Экран: все. ч. A, B; 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.2
  ///
  /// In ru, this message translates to:
  /// **'Отмена'**
  String get ds_button_cancel;

  /// Экран: все. ч. A; 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Закрыть'**
  String get ds_button_close;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Ещё'**
  String get ds_button_more;

  /// Экран: все. ч. B; 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Готово'**
  String get ds_button_ok;

  /// Экран: все. ч. B; 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Открыть'**
  String get ds_button_open;

  /// Экран: все. ч. B; 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Сбросить'**
  String get ds_button_reset;

  /// Экран: все. ч. A, B; 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.2
  ///
  /// In ru, this message translates to:
  /// **'Повторить'**
  String get ds_button_retry;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Показать {count}'**
  String ds_button_show_n(int count);

  /// Экран: все. ч. B; 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Отменить'**
  String get ds_button_undo;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Подтвердите действие'**
  String get ds_confirm_title_default;

  /// Экран: общие. ч. D; предложение в общий словарь 03 [НОВОЕ ИМЯ]; кнопка «Проверить» — `payment_check`. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Скопировано'**
  String get ds_copied;

  /// Экран: общие. ч. D; предложение в общий словарь 03 [НОВОЕ ИМЯ]; кнопка «Проверить» — `payment_check`. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Скопировать номер'**
  String get ds_copy_number;

  /// Экран: общие. ч. D; предложение в общий словарь 03 [НОВОЕ ИМЯ]; кнопка «Проверить» — `payment_check`. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Скопировать телефон'**
  String get ds_copy_phone;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Соглашение клиента без отсрочки'**
  String get ds_credit_not_allowed;

  /// Экран: все. ч. B; 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'данные от {time}'**
  String ds_data_as_of(String time);

  /// Экран: SCR-10/12. ч. B; 03 §9.43. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В этой категории пока нет товаров'**
  String get ds_empty_category_title;

  /// Экран: SCR-17. ч. B; 03 §9.43. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Камера недоступна'**
  String get ds_empty_no_camera_title;

  /// Экран: SCR-10, SCR-90 (`EmptyState.offlineNoCache`). этап E, 03 §16.7 (ADR-097); текст, 03 §9.43. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Подключитесь к сети и выполните синхронизацию'**
  String get ds_empty_offline_no_cache_body;

  /// Экран: SCR-10, SCR-90 (`EmptyState.offlineNoCache`). этап E, 03 §16.7 (ADR-097); заголовок, 03 §9.43; 02 SCR-10 (состояние «Нет данных офлайн»); CAT-UI EQ-CAT-07. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Нет данных для работы без сети'**
  String get ds_empty_offline_no_cache_title;

  /// Экран: SCR-11. ч. B; 03 §9.43. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ничего не найдено по «{query}»'**
  String ds_empty_search_title(String query);

  /// Экран: SCR-10, SCR-14, SCR-50 (`FavoriteToggle`). этап E, 03 §16.7 (ADR-097); a11y, состояние «выкл.», 03 §9.23; CAT-UI EQ-CAT-07. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Добавить в избранное'**
  String get ds_favorite_add_a11y;

  /// Экран: SCR-10, SCR-14, SCR-50 (`FavoriteToggle`). этап E, 03 §16.7 (ADR-097); a11y, состояние «вкл.», 03 §9.23; CAT-UI EQ-CAT-07. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'В избранном'**
  String get ds_favorite_on_a11y;

  /// Экран: SCR-14 (`ImageGallery`). этап E, 03 §16.7 (ADR-097); кнопка для screen reader, 03 §9.15; EQ-PD-02. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Следующее фото'**
  String get ds_gallery_next_a11y;

  /// Экран: SCR-14 (`ImageGallery`). этап E, 03 §16.7 (ADR-097); кнопка для screen reader, 03 §9.15; EQ-PD-02. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Предыдущее фото'**
  String get ds_gallery_prev_a11y;

  /// Экран: SCR-14 (`ImageGallery`). этап E, 03 §16.7 (ADR-097); a11y кнопки зума, 03 §9.15; EQ-PD-02. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Увеличить'**
  String get ds_gallery_zoom_in_a11y;

  /// Экран: SCR-14 (`ImageGallery`). этап E, 03 §16.7 (ADR-097); a11y кнопки зума, 03 §9.15; EQ-PD-02. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Уменьшить'**
  String get ds_gallery_zoom_out_a11y;

  /// Экран: общие. ч. D; предложение в общий словарь 03 [НОВОЕ ИМЯ]; кнопка «Проверить» — `payment_check`. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Статус операции уточняется'**
  String get ds_idempotency_pending;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Загрузка…'**
  String get ds_loading;

  /// Экран: все. ч. B; 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Долгая загрузка…'**
  String get ds_loading_long;

  /// Экран: все. ч. B; 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Нет фото'**
  String get ds_no_photo;

  /// Экран: SCR-90 A; все. ч. A, B; владелец 03; 03 §16.5; в части A: см. 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Нет сети. Показаны данные от {time}. Заказы недоступны'**
  String ds_offline_banner(String time);

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Нет подключения. Для входа нужна сеть'**
  String get ds_offline_unlock;

  /// Экран: SCR-90 A; SCR-10. ч. A, B; владелец 03; 03 §16.5; в части A: см. 03 §16.5. Источник: 02 §7; текст 02 оставлен вместо 03 §16.5 «1С недоступна: заказы будут отправлены позже; продажа в долг недоступна»: ядро §22.4: при недоступности 1С продажа в долг разрешена по свежему полному снимку долга; текст 03 §16.5 «продажа в долг недоступна» противоречит ядру, текст 02 §7 (ссылка на ядро §22.4 в 02 SCR-90) выровнен с ним
  ///
  /// In ru, this message translates to:
  /// **'1С недоступна: заказы будут отправлены позже; продажа в долг — только по актуальным данным о долге'**
  String get ds_onec_down;

  /// Экран: все. ч. B; 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Цена не указана'**
  String get ds_price_missing;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Сначала аннулируйте или подтвердите текущий платёж'**
  String get ds_qr_open_payment_hint;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Повторить без банка'**
  String get ds_qr_retry_without_bank;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'QR не сформирован банком. Покажите клиенту QR-табличку кассы; оплату подтвердит кассир'**
  String get ds_qr_static_plate_hint;

  /// Экран: компонент `QuantityStepper`. этап E, 03 §16.7 (ADR-097); a11y кнопки «−», 03 §9.20; EQ-PD-02. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Уменьшить количество'**
  String get ds_qty_decrease_a11y;

  /// Экран: компонент `QuantityStepper`. этап E, 03 §16.7 (ADR-097); a11y кнопки «+», 03 §9.20; EQ-PD-02. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Увеличить количество'**
  String get ds_qty_increase_a11y;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Есть долг · подробности в карточке клиента'**
  String get ds_receivable_details_hint;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Есть долг'**
  String get ds_receivable_has_debt;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Просрочка'**
  String get ds_receivable_overdue;

  /// Экран: SCR-90 A. ч. A; владелец 03; текст взят из п. 8 экрана (в словаре части — ссылка «см. 03 §16.5»). Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Подключаемся…'**
  String get ds_reconnecting;

  /// Экран: SCR-90 E. ч. A; 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Код: {requestId}'**
  String ds_request_id(String requestId);

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Введите имя, телефон или часть имени…'**
  String get ds_search_placeholder_customers;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Поиск товара по названию, коду или штрих-коду…'**
  String get ds_search_placeholder_products;

  /// Экран: SCR-90 A. ч. A; владелец 03; текст взят из п. 8 экрана (в словаре части — ссылка «см. 03 §16.5»). Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Сервер недоступен'**
  String get ds_server_down;

  /// Экран: SCR-90 B. ч. A; 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Подтвердите действие'**
  String get ds_step_up_title;

  /// Экран: все. ч. B; 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Остаток неизвестен'**
  String get ds_stock_unknown;

  /// Экран: шапка, SCR-43 (`SyncIndicator`). этап E, 03 §16.7 (ADR-097); вариант `error`, 03 §9.40; EQ-E009-03. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Ошибка синхронизации'**
  String get ds_sync_error;

  /// Экран: шапка, SCR-43 (`SyncIndicator`, `OfflineBanner`). этап E, 03 §16.7 (ADR-097); вариант `offline`, 03 §9.40, §9.41; EQ-E009-03. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Нет сети'**
  String get ds_sync_offline;

  /// Экран: шапка, SCR-43 (`SyncIndicator`). этап E, 03 §16.7 (ADR-097); вариант `syncing`, 03 §9.40; EQ-E009-03. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Обновляем…'**
  String get ds_sync_syncing;

  /// Экран: SCR-90 C3. ч. A. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Требуется обновление приложения'**
  String get ds_update_required;

  /// Экран: все. ч. B; 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'обновлено {time}'**
  String ds_updated_at(String time);

  /// Экран: SCR-04, 90 F. ч. A; 03 §16.5. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сервер работает в режиме только чтения — изменения временно недоступны'**
  String get error_app_read_only;

  /// Экран: SCR-20, SCR-21. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Корзина пуста'**
  String get error_cart_empty;

  /// Экран: SCR-21. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продажа в долг недоступна'**
  String get error_credit_blocked;

  /// Экран: SCR-21. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Превышен лимит долга клиента'**
  String get error_credit_limit_exceeded;

  /// Экран: SCR-26. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Найден клиент с этим номером'**
  String get error_customer_duplicate_suspected;

  /// Экран: SCR-21. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выберите клиента'**
  String get error_customer_not_identified;

  /// Экран: SCR-20, SCR-21. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скидка больше вашего лимита ({limit} %)'**
  String error_discount_limit_exceeded(String limit);

  /// Экран: все. ч. B, C; 08 §2.4. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Недостаточно прав'**
  String get error_forbidden;

  /// Экран: SCR-21, SCR-22. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Операция уже выполняется'**
  String get error_idempotency_in_progress;

  /// Экран: SCR-90 E; все. ч. A, B, C; 03 §16.5; 03 §16.2; текст выровнен при сборке 02 с 02a/02b; код обращения показывается отдельной строкой `ds_request_id` «Код: {requestId}» (03 §16.5). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось выполнить. Повторите'**
  String get error_internal;

  /// Экран: SCR-12/14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не найдено'**
  String get error_not_found;

  /// Экран: SCR-21, SCR-22. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'1С отклонила документ'**
  String get error_onec_rejected;

  /// Экран: SCR-21, SCR-22, SCR-24. ч. C; 03 §16.2 (пример). Источник: 02 §7; текст совпадает с 03 §16.2
  ///
  /// In ru, this message translates to:
  /// **'1С временно недоступна. Заказ будет отправлен позже'**
  String get error_onec_unavailable;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Действие недоступно в текущем статусе'**
  String get error_order_state_invalid;

  /// Экран: SCR-22. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Статус платежа изменился'**
  String get error_payment_state_invalid;

  /// Экран: SCR-20, SCR-21. ч. C; 08 §2.4. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Цены изменились. Подтвердите новые цены'**
  String get error_price_changed;

  /// Экран: SCR-22. ч. C; код `[НОВОЕ ИМЯ]` в 08 §2.4. Источник: 02 §7; текст 02 оставлен вместо 03 §16.5 (код QR_UNAVAILABLE) «Банк недоступен»: ядро v1.9 §24.4: в R1 основной вариант QR_PROVIDER=onec — QR формирует 1С, а не банк; текст 03 §16.5 «Банк недоступен» неверен для этого варианта, нейтральный текст 02 §7 подходит для onec и bakai (B-AR-11, docs/reviews/B_architecture_review.md)
  ///
  /// In ru, this message translates to:
  /// **'QR временно недоступен'**
  String get error_qr_unavailable;

  /// Экран: SCR-14/16; SCR-20. ч. B, C; текст выровнен при сборке 02 с 02b (было «Количество меньше минимальной партии»). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Минимальная партия — {min} {unit}'**
  String error_qty_below_min(String min, String unit);

  /// Экран: SCR-14/16; SCR-20. ч. B, C; текст выровнен при сборке 02 с 02b (было «… кратно {factor}»). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Количество должно быть кратно {m} {unit}'**
  String error_qty_not_multiple(String m, String unit);

  /// Экран: SCR-11. ч. B; 03 §9.44. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Слишком много запросов, подождите {seconds} с'**
  String error_rate_limited(int seconds);

  /// Экран: SCR-21. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Данные о долге устарели'**
  String get error_receivables_stale;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.5 (код RETURN_QTY_EXCEEDED)
  ///
  /// In ru, this message translates to:
  /// **'Можно вернуть не больше {n}'**
  String error_return_qty_exceeded(int n);

  /// Экран: SCR-20, SCR-21, SCR-22, SCR-24. ч. C; `StepUpDialog`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтвердите действие'**
  String get error_step_up_required;

  /// Экран: SCR-10/14/16; SCR-20, SCR-21. ч. B, C; 03 §16.2; 03 §16.2 (пример). Источник: 02 §7; текст совпадает с 03 §16.2
  ///
  /// In ru, this message translates to:
  /// **'Недостаточно остатка: доступно {available} {unit}'**
  String error_stock_insufficient(String available, String unit);

  /// Экран: SCR-43. ч. E; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Синхронизация уже выполняется'**
  String get error_sync_already_running;

  /// Экран: SCR-10/14/15/16; SCR-20, SCR-21. ч. B, C; 08 §2.4. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Товар больше не продаётся'**
  String get error_variant_unavailable;

  /// Экран: SCR-20. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Данные изменились на другом устройстве'**
  String get error_version_conflict;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Регистрация продолжится без сканирования лица'**
  String get face_cancel_body;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Прервать сканирование?'**
  String get face_cancel_title;

  /// Экран: SCR-05. ч. A; R2, Q-027. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Согласен(на) на обработку изображения лица для этой проверки'**
  String get face_consent_label;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продолжить без сканирования'**
  String get face_continue_without;

  /// Экран: SCR-05. ч. A; юр. проверка Q-003, Q-027. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Снимки обрабатываются на устройстве и не сохраняются'**
  String get face_data_notice;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Готово'**
  String get face_done;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось завершить сканирование'**
  String get face_failed_title;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Слишком ярко — уберите источник света из кадра'**
  String get face_hint_bright;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Расположите лицо в овале'**
  String get face_hint_center;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подойдите ближе'**
  String get face_hint_closer;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Слишком темно'**
  String get face_hint_dark;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Откройте глаза'**
  String get face_hint_eyes;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отодвиньтесь немного'**
  String get face_hint_farther;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В кадре должно быть одно лицо'**
  String get face_hint_many_faces;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Лицо не найдено'**
  String get face_hint_no_face;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Держите телефон неподвижно'**
  String get face_hint_steady;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Слишком сильно — поверните немного назад'**
  String get face_hint_too_far;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Настроить позже'**
  String get face_later;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Настроить вход по-другому'**
  String get face_other_method;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Слишком много попыток. Повторите через {mmss}'**
  String face_paused_attempts(String mmss);

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Начать заново'**
  String get face_restart;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Попробуйте ещё раз'**
  String get face_retry;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Повторить шаг'**
  String get face_retry_step;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Поверните устройство вертикально'**
  String get face_rotate_device;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Пропустить'**
  String get face_skip;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Начать'**
  String get face_start;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Шаг {n} из 4'**
  String face_step_counter(int n);

  /// Экран: SCR-05. ч. A; 09 §10.3. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Посмотрите прямо в камеру'**
  String get face_step_front;

  /// Экран: SCR-05. ч. A; 09 §10.3. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Медленно поверните голову влево'**
  String get face_step_left;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отлично'**
  String get face_step_ok;

  /// Экран: SCR-05. ч. A; 09 §10.3. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Теперь поверните голову вправо'**
  String get face_step_right;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не получается?'**
  String get face_step_timeout_title;

  /// Экран: SCR-05. ч. A; 09 §10.3. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Поднимите подбородок немного вверх'**
  String get face_step_up;

  /// Экран: SCR-05. ч. A; R2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сканирование лица'**
  String get face_title;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет фронтальной камеры. Вход защищён PIN-кодом'**
  String get face_unsupported_no_camera;

  /// Экран: SCR-05. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сканирование лица недоступно на этом устройстве'**
  String get face_unsupported_title;

  /// Экран: SCR-40. ч. E; + `ds_button_undo`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент убран из избранного'**
  String get favorites_customer_removed_snackbar;

  /// Экран: SCR-40. ч. E; кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Найти клиента'**
  String get favorites_empty_customers_action;

  /// Экран: SCR-40. ч. E; `EmptyState`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отмечайте клиентов звездой в карточке клиента'**
  String get favorites_empty_customers_body;

  /// Экран: SCR-40. ч. E; `EmptyState`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Избранных клиентов пока нет'**
  String get favorites_empty_customers_title;

  /// Экран: SCR-40. ч. E; плейсхолдер. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Фильтр по избранным клиентам'**
  String get favorites_filter_customers_hint;

  /// Экран: SCR-40. ч. E; диктор. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Товар {name}, цена {price}, {stock}, в избранном'**
  String favorites_item_a11y(String name, String price, String stock);

  /// Экран: SCR-40. ч. E; `deletion_mark`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не продаётся'**
  String get favorites_not_sold_label;

  /// Экран: SCR-40. ч. E; офлайн. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидает отправки'**
  String get favorites_pending_label;

  /// Экран: SCR-40. ч. E; ICU plural. Источник: 02 §7; формы «a / b / c» 02 §7 преобразованы в ICU plural (03 §16.3)
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{{count} товар} few{{count} товара} many{{count} товаров} other{{count} товара}}'**
  String favorites_products_found(int count);

  /// Экран: SCR-40. ч. E; ошибка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось убрать из избранного. Повторите'**
  String get favorites_remove_error;

  /// Экран: SCR-40. ч. E; + `ds_button_undo`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Убрано из избранного'**
  String get favorites_removed_snackbar;

  /// Экран: SCR-40. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сканирование работает во вкладке «Товары»'**
  String get favorites_scan_ignored;

  /// Экран: SCR-40. ч. E; тултип. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Убрать из избранного'**
  String get favorites_star_remove_tooltip;

  /// Экран: SCR-40. ч. E; ICU plural. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиенты · {count}'**
  String favorites_tab_customers_count(int count);

  /// Экран: SCR-40. ч. E; ICU plural. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Товары · {count}'**
  String favorites_tab_products_count(int count);

  /// Экран: SCR-40. ч. E; заголовок. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Избранное'**
  String get favorites_title;

  /// Экран: SCR-40. ч. E; кнопка S. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В заказ'**
  String get favorites_to_order_button;

  /// Экран: SCR-13. ч. B; с v1.4 не используется — `/search/products` принимает все фильтры (ядро §19.2); ключ сохранён. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Фильтр применён к найденному'**
  String get filters_applied_locally;

  /// Экран: SCR-13. ч. B; 08 §4.4.2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выбрано максимум 10 характеристик'**
  String get filters_attr_limit;

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Бренд'**
  String get filters_brand_title;

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Категория'**
  String get filters_category_title;

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Цвет'**
  String get filters_color_title;

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось загрузить фильтры · Повторить'**
  String get filters_error_load;

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Только избранное'**
  String get filters_favorites_only;

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Только в наличии'**
  String get filters_in_stock;

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Модель / серия'**
  String get filters_model_title;

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет товаров'**
  String get filters_no_results;

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ослабьте условия'**
  String get filters_no_results_hint;

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Фильтры по сохранённым данным от {time}'**
  String filters_offline_note(String time);

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Минимальная цена больше максимальной'**
  String get filters_price_error_range;

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'от'**
  String get filters_price_from;

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В выдаче: {min} — {max} · вид цены «{priceList}»'**
  String filters_price_range_hint(String max, String min, String priceList);

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Цена, сом'**
  String get filters_price_title;

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'до'**
  String get filters_price_to;

  /// Экран: SCR-10/13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сбросить все'**
  String get filters_reset_all;

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Показать все ({count})'**
  String filters_show_all(int count);

  /// Экран: SCR-13. ч. B; ICU. Источник: 02 §7; формы «a / b / c» 02 §7 преобразованы в ICU plural (03 §16.3)
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{Показать {count} товар} few{Показать {count} товара} many{Показать {count} товаров} other{Показать {count} товара}}'**
  String filters_show_n(int count);

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Размер'**
  String get filters_size_title;

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'данные остатков от {time}'**
  String filters_stock_as_of(String time);

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Фильтры'**
  String get filters_title;

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'склад корзины'**
  String get filters_warehouse_cart_hint;

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Склад'**
  String get filters_warehouse_title;

  /// Экран: SCR-13. ч. B; INV-026. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Остатки склада «{name}». Продажа — со склада корзины'**
  String filters_warehouse_view_note(String name);

  /// Экран: SCR-13. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Только с фото'**
  String get filters_with_photo_only;

  /// Экран: SCR-90 A. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Это действие требует связи с сервером. Каталог и корзина доступны из кэша (обновлено {time})'**
  String global_offline_body(String time);

  /// Экран: SCR-90 A. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продолжить работу из кэша'**
  String get global_offline_continue;

  /// Экран: SCR-90 A. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет подключения к сети'**
  String get global_offline_title;

  /// Экран: все (roleGuard). этап E, 03 §16.7 (ADR-097); снекбар guard G-7 для `/payments/new` (`visual/navigation.md` §4.1); FIX-EF-05. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Приём оплаты выполняет кассир'**
  String get global_payment_cashier_only;

  /// Экран: SCR-90 D. ч. A; текст взят из п. 8 экрана (в словаре части — ссылка «тексты §10.8»). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет доступа к биометрии. Разрешите Face ID в настройках или используйте PIN'**
  String get global_permission_biometrics;

  /// Экран: SCR-90 D. ч. A; текст взят из п. 8 экрана (в словаре части — ссылка «тексты §10.8»). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет доступа к камере. Разрешите доступ в настройках устройства'**
  String get global_permission_camera;

  /// Экран: SCR-90 D. ч. A; текст взят из п. 8 экрана (в словаре части — ссылка «тексты §10.8»). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Открыть настройки'**
  String get global_permission_open_settings;

  /// Экран: SCR-90 H. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ваши права изменены администратором'**
  String get global_permissions_changed;

  /// Экран: SCR-90 E. ч. A; 03 §16.5. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Код скопирован'**
  String get global_request_id_copied;

  /// Экран: все (roleGuard). этап E, 03 §16.7 (ADR-097); снекбар guard G-7 (`visual/navigation.md` §4.1); FIX-EF-05. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Раздел недоступен для вашей роли'**
  String get global_role_forbidden;

  /// Экран: SCR-90 B2. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{action} превышает ваш лимит ({limit}). Его может выполнить старший продавец или администратор в своей сессии'**
  String global_senior_body(String action, String limit);

  /// Экран: SCR-90 B2. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нужно подтверждение старшего'**
  String get global_senior_title;

  /// Экран: SCR-90 C. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Черновик корзины ({count}) сохранён на этом устройстве и будет восстановлен после входа'**
  String global_session_draft_saved(int count);

  /// Экран: SCR-90 C. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сессия завершена'**
  String get global_session_ended_title;

  /// Экран: SCR-90 C. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Войти снова'**
  String get global_session_login_again;

  /// Экран: SCR-90 C. ч. A; текст взят из п. 8 экрана (в словаре части — ссылка «тексты §10.8»). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сессию завершил администратор. Войдите снова по номеру телефона'**
  String get global_session_reason_admin;

  /// Экран: SCR-90 C. ч. A; текст взят из п. 8 экрана (в словаре части — ссылка «тексты §10.8»). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сессия привязана к другому устройству. Войдите снова'**
  String get global_session_reason_device_mismatch;

  /// Экран: SCR-90 C. ч. A; текст взят из п. 8 экрана (в словаре части — ссылка «тексты §10.8»). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Срок входа истёк. Войдите снова по номеру телефона'**
  String get global_session_reason_expired;

  /// Экран: SCR-90 C. ч. A; текст взят из п. 8 экрана (в словаре части — ссылка «тексты §10.8»). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вход выполнен на другом устройстве или устройство удалено из списка. Войдите снова'**
  String get global_session_reason_other_device;

  /// Экран: SCR-90 C. ч. A; текст взят из п. 8 экрана (в словаре части — ссылка «тексты §10.8»). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Номер входа изменён. Войдите снова'**
  String get global_session_reason_phone_changed;

  /// Экран: SCR-90 C. ч. A; текст взят из п. 8 экрана (в словаре части — ссылка «тексты §10.8»). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Для безопасности мы завершили все сессии. Войдите снова'**
  String get global_session_reason_reuse;

  /// Экран: SCR-90 C3. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Обновить'**
  String get global_update_action;

  /// Экран: SCR-90 C3. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Установите версию {minVersion} или новее, чтобы продолжить работу'**
  String global_update_body(String minVersion);

  /// Экран: SCR-90 C3. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Позже'**
  String get global_update_later;

  /// Экран: SCR-90 C3. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Доступна новая версия приложения'**
  String get global_update_soft;

  /// Экран: SCR-50. ч. E; Android [ТИПОВО]. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нажмите ещё раз для выхода'**
  String get home_back_to_exit;

  /// Экран: SCR-50. ч. E; карточка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Избранное'**
  String get home_favorites;

  /// Экран: SCR-50. ч. E; баннер. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Привязка к организации ожидает подтверждения администратором'**
  String get home_link_conflict;

  /// Экран: SCR-50. ч. E; баннер. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Мы нашли организацию {name}. Это вы?'**
  String home_link_proposed(String name);

  /// Экран: SCR-50. ч. E; кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверить'**
  String get home_link_proposed_action;

  /// Экран: SCR-50. ч. E; баннер. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Организация не подтверждена. Заказы оформляются как новый клиент'**
  String get home_link_rejected;

  /// Экран: SCR-50. ч. E; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Загружаем ещё товары…'**
  String get home_loading_more;

  /// Экран: SCR-50. ч. E; карточка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Мой долг'**
  String get home_my_debt;

  /// Экран: SCR-50. ч. E; DEBT-009. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет данных из 1С'**
  String get home_my_debt_no_data;

  /// Экран: SCR-50. ч. E; до `confirmed`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долг доступен после подтверждения организации'**
  String get home_my_debt_unavailable;

  /// Экран: SCR-50. ч. E; карточка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Мои заказы'**
  String get home_my_orders;

  /// Экран: SCR-50. ч. E; ICU plural. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{count} в работе'**
  String home_my_orders_active(int count);

  /// Экран: SCR-50. ч. E; нет `totalEstimate` (замечание №20). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Есть заказы в работе'**
  String get home_my_orders_active_nocount;

  /// Экран: SCR-50. этап E, 03 §16.7 (ADR-097); пустая карточка «Мои заказы» (UI-50-004); EQ-HOME-04. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказов нет'**
  String get home_my_orders_empty;

  /// Экран: SCR-50. ч. E; чип. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ваш вид цены: {name}'**
  String home_price_list_label(String name);

  /// Экран: SCR-50. этап E, 03 §16.7 (ADR-097); тултип чипа вида цены (UI-50-007); EQ-HOME-04. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Цены показаны по вашему виду цены'**
  String get home_price_list_tooltip;

  /// Экран: SCR-50. ч. E; блок. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Очистить'**
  String get home_recent_clear;

  /// Экран: SCR-50. ч. E; блок. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Недавние товары'**
  String get home_recent_title;

  /// Экран: SCR-06. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Найдено несколько карточек с вашим номером. Администратор магазина проверит данные и свяжется с вами'**
  String get link_body_conflict;

  /// Экран: SCR-06. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В учётной системе магазина есть клиент с вашим номером. Подтвердите, что это вы — заказы и условия станут доступны в приложении'**
  String get link_body_found;

  /// Экран: SCR-06. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Условия обслуживания уточнит менеджер магазина'**
  String get link_body_none;

  /// Экран: SCR-06. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Да, это я'**
  String get link_confirm;

  /// Экран: SCR-06, 07. ч. A; один текст ячейки для нескольких ключей. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Связаться с магазином'**
  String get link_contact_shop;

  /// Экран: SCR-06. ч. A; SRC-B-145. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Финансовые данные не показываются до подтверждения'**
  String get link_finance_hidden;

  /// Экран: SCR-06. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет, это не я'**
  String get link_reject;

  /// Экран: SCR-06. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Мы не будем связывать аккаунт с этой карточкой. Если карточка всё же ваша, объединить их сможет администратор магазина'**
  String get link_reject_body;

  /// Экран: SCR-06. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Это не ваша карточка?'**
  String get link_reject_title;

  /// Экран: SCR-06. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ищем вашу карточку…'**
  String get link_searching;

  /// Экран: SCR-06. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Карточка привязана'**
  String get link_success;

  /// Экран: SCR-06. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нужна помощь администратора'**
  String get link_title_conflict;

  /// Экран: SCR-06. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Мы нашли вашу карточку клиента'**
  String get link_title_found;

  /// Экран: SCR-06. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Карточка клиента будет создана при первом заказе'**
  String get link_title_none;

  /// Экран: SCR-06. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидает подтверждения администратором'**
  String get link_wait_admin;

  /// Экран: SCR-01…08. ч. A; `state` ∈ ожидание / ввод / проверка / успех / ошибка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Персонаж: {state}'**
  String mascot_state_a11y(String state);

  /// Экран: SCR-44. ч. E. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Цена в корзине изменилась'**
  String get notification_kind_cart_price_changed;

  /// Экран: SCR-44. ч. E. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Остаток в корзине изменился'**
  String get notification_kind_cart_stock_changed;

  /// Экран: SCR-44. ч. E. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продажа в долг заблокирована'**
  String get notification_kind_credit_blocked;

  /// Экран: SCR-44. ч. E. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Статус заказа'**
  String get notification_kind_order_status;

  /// Экран: SCR-44. ч. E. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата'**
  String get notification_kind_payment_status;

  /// Экран: SCR-44. ч. E. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заявка на возврат'**
  String get notification_kind_return_status;

  /// Экран: SCR-44. ч. E; `[НОВОЕ ИМЯ префикса]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ошибка синхронизации'**
  String get notification_kind_sync_error;

  /// Экран: SCR-44. ч. E. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Система'**
  String get notification_kind_system;

  /// Экран: SCR-44. ч. E; действия. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подробнее'**
  String get notifications_action_details;

  /// Экран: SCR-44. ч. E; действия. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Это не я'**
  String get notifications_action_not_me;

  /// Экран: SCR-44. ч. E; действия. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Открыть корзину'**
  String get notifications_action_open_cart;

  /// Экран: SCR-44. ч. E; диктор. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Уведомления, {count} непрочитанных'**
  String notifications_bell_a11y(int count);

  /// Экран: SCR-44. этап F, 03 §16.8 (ADR-103); заголовок группы дня UI-44-007 (SCR-44.2); FQ-NOTIF-02. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сегодня'**
  String get notifications_day_today;

  /// Экран: SCR-44. этап F, 03 §16.8 (ADR-103); заголовок группы дня UI-44-007 (SCR-44.2); FQ-NOTIF-02. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вчера'**
  String get notifications_day_yesterday;

  /// Экран: SCR-44. ч. E; empty. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет уведомлений выбранного вида'**
  String get notifications_empty_filtered;

  /// Экран: SCR-44. этап F, 03 §16.8 (ADR-103); `EmptyState notifications` (SCR-44.7); FQ-NOTIF-02. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Уведомлений нет'**
  String get notifications_empty_title;

  /// Экран: SCR-44. ч. E; сегменты. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все'**
  String get notifications_filter_all;

  /// Экран: SCR-44. этап F, 03 §16.8 (ADR-103); чип фильтра видов (SCR-44.2); FQ-NOTIF-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Корзина'**
  String get notifications_filter_kind_cart;

  /// Экран: SCR-44. этап F, 03 §16.8 (ADR-103); чип фильтра видов (SCR-44.2); FQ-NOTIF-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долг'**
  String get notifications_filter_kind_debt;

  /// Экран: SCR-44. этап F, 03 §16.8 (ADR-103); чип фильтра видов (SCR-44.2); FQ-NOTIF-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказы'**
  String get notifications_filter_kind_orders;

  /// Экран: SCR-44. этап F, 03 §16.8 (ADR-103); чип фильтра видов (SCR-44.2); FQ-NOTIF-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата'**
  String get notifications_filter_kind_payment;

  /// Экран: SCR-44. этап F, 03 §16.8 (ADR-103); чип фильтра видов (SCR-44.2); FQ-NOTIF-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Возвраты'**
  String get notifications_filter_kind_returns;

  /// Экран: SCR-44. этап F, 03 §16.8 (ADR-103); чип фильтра видов (SCR-44.2); FQ-NOTIF-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Синхронизация'**
  String get notifications_filter_kind_sync;

  /// Экран: SCR-44. этап F, 03 §16.8 (ADR-103); чип фильтра видов (SCR-44.2); FQ-NOTIF-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Система'**
  String get notifications_filter_kind_system;

  /// Экран: SCR-44. ч. E; сегменты. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Непрочитанные ({count})'**
  String notifications_filter_unread(int count);

  /// Экран: SCR-44. ч. E; диктор. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Непрочитанное: {title}, {time}'**
  String notifications_item_unread_a11y(String time, String title);

  /// Экран: SCR-44. ч. E; меню. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отметить прочитанным'**
  String get notifications_mark_read;

  /// Экран: SCR-44. ч. E; ICU plural. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{count} новое / новых уведомления(-й)'**
  String notifications_new_above(int count);

  /// Экран: SCR-44. ч. E; кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Прочитать все'**
  String get notifications_read_all;

  /// Экран: SCR-44. этап F, 03 §16.8 (ADR-103); действие пустого состояния при фильтре (SCR-44.7); FQ-NOTIF-02. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сбросить фильтры'**
  String get notifications_reset_filters;

  /// Экран: SCR-44. ч. E; устаревшие данные. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Уведомления обновлены в {time}'**
  String notifications_stale_banner(String time);

  /// Экран: SCR-44. ч. E; заголовок. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Уведомления'**
  String get notifications_title;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.3
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, =0{Уведомлений нет} one{{count} непрочитанное} few{{count} непрочитанных} many{{count} непрочитанных} other{{count} непрочитанных}}'**
  String notifications_unread(int count);

  /// Экран: SCR-44. ч. E; popover. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все уведомления'**
  String get notifications_view_all;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отменить заказ'**
  String get order_action_cancel;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Запросить отмену'**
  String get order_action_cancel_request;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Принять оплату'**
  String get order_action_pay;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Повторить заказ'**
  String get order_action_repeat;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заявка на возврат'**
  String get order_action_return;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Показать QR'**
  String get order_action_show_qr;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Запрос отмены отправлен в 1С {time}'**
  String order_banner_cancel_requested(String time);

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Требуется вмешательство администратора: заказ не отправлен в 1С'**
  String get order_banner_dead;

  /// Экран: SCR-24. ч. C; UI-24-015; ядро §19.2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ не удалось однозначно сопоставить с документом 1С. Нужна ручная привязка'**
  String get order_banner_match_ambiguous;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'1С отклонила заказ: {reason}'**
  String order_banner_rejected(String reason);

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидает отправки в 1С'**
  String get order_banner_submitting;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Итог уточнён 1С: было {old}, стало {newValue}'**
  String order_banner_total_adjusted(String newValue, String old);

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отменить заказ № {number}?'**
  String order_cancel_dialog_title(String number);

  /// Экран: SCR-24. этап F, 03 §16.8 (ADR-103); безопасная кнопка диалога отмены UI-24-017 (фокус); FQ-FEORD-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не отменять'**
  String get order_cancel_keep;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оставить авансом'**
  String get order_cancel_money_advance;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вернуть деньги клиенту'**
  String get order_cancel_money_refund;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент отказался'**
  String get order_cancel_reason_customer_refused;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Дубль'**
  String get order_cancel_reason_duplicate;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ошибка оформления'**
  String get order_cancel_reason_error;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Другое'**
  String get order_cancel_reason_other;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Укажите причину отмены'**
  String get order_cancel_reason_required;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Запрос отмены отправлен в 1С'**
  String get order_cancel_requested_snackbar;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отмена недоступна в статусе «{status}»'**
  String order_cancel_unavailable(String status);

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ отменён'**
  String get order_cancelled_snackbar;

  /// Экран: SCR-22. ч. C; UI-22-012. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Принять оплату'**
  String get order_created_accept_payment;

  /// Экран: SCR-22. ч. C; Q-208. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплату примет кассир. Заказ № {number}'**
  String order_created_admin_handoff(String number);

  /// Экран: SCR-22. ч. C; ORD-031. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ не удалось отправить в 1С — администратор получил уведомление'**
  String get order_created_banner_dead;

  /// Экран: SCR-22. ч. C; ORD-025. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ сохранён и будет отправлен в 1С автоматически. Счёт можно напечатать после получения номера 1С'**
  String get order_created_banner_submitting;

  /// Экран: SCR-22. ч. C; PAY-011. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Передайте клиента в кассу. Заказ № {number}, к оплате {total}'**
  String order_created_cash_handoff(String number, String total);

  /// Экран: SCR-22. ч. C; PAY-034. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продажа в долг · оплатить до {date}'**
  String order_created_credit_due(String date);

  /// Экран: SCR-22. ч. C; PAY-034. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Срок оплаты — по соглашению в 1С'**
  String get order_created_credit_due_agreement;

  /// Экран: SCR-22. ч. C; `customer`, когда QR не сформирован (`qr_pending` без `qr`, `warnings[QR_UNAVAILABLE]`); версия 1.7 — при `QR_PROVIDER=onec` клиент видит QR своей заявки (ядро v1.9 §24.4; §14 п.23 ч. C закрыто). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплатите заказ в кассе магазина'**
  String get order_created_customer_pay_hint;

  /// Экран: SCR-22. ч. C; версия 1.7; `customer`, способ `cash`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата при получении. Заявка № {number} отправлена в магазин на согласование'**
  String order_created_customer_pay_on_pickup(String number);

  /// Экран: SCR-22. ч. C; версия 1.7; `customer`, `QR_PROVIDER=onec` (ядро v1.9 §24.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплатите заявку по QR — магазин получит подтверждение оплаты автоматически'**
  String get order_created_customer_qr_hint;

  /// Экран: SCR-22, SCR-24. ч. C; PRINT-001. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось напечатать · Повторить'**
  String get order_created_doc_failed;

  /// Экран: SCR-22, SCR-24. ч. C; PrintOptions. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Напечатан'**
  String get order_created_doc_printed;

  /// Экран: SCR-22, SCR-24. ч. C; PRINT-001. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В очереди на печать'**
  String get order_created_doc_queued;

  /// Экран: SCR-22. ч. C; UI-22-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сумма поступления'**
  String get order_created_manual_amount_label;

  /// Экран: SCR-22. ч. C; Сумма поступления не совпадает. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сумма отличается от заказа: платёж уйдёт на разбор'**
  String get order_created_manual_amount_mismatch;

  /// Экран: SCR-22. ч. C; UI-22-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Комментарий'**
  String get order_created_manual_comment_label;

  /// Экран: SCR-22. ч. C; UI-22-009. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтвердить оплату вручную'**
  String get order_created_manual_confirm;

  /// Экран: SCR-22. ч. C; UI-22-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Референс банка / номер из выписки'**
  String get order_created_manual_ref_label;

  /// Экран: SCR-22. ч. C; Референс пуст / короче 4. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите референс из выписки банка (не короче 4 символов)'**
  String get order_created_manual_ref_required;

  /// Экран: SCR-22. ч. C; UI-22-017. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Время поступления'**
  String get order_created_manual_time_label;

  /// Экран: SCR-22. ч. C; UI-22-011. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Новый заказ'**
  String get order_created_new_order;

  /// Экран: SCR-22. ч. C; UI-22-002. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ № {number}'**
  String order_created_number(String number);

  /// Экран: SCR-22. ч. C; submitting. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидает отправки в 1С'**
  String get order_created_onec_pending;

  /// Экран: SCR-22. ч. C; UI-22-010. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Открыть заказ'**
  String get order_created_open_order;

  /// Экран: SCR-22. ч. C; UI-22-015. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Другой способ оплаты'**
  String get order_created_other_method;

  /// Экран: SCR-22. ч. C; seller. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сменить способ оплаты может кассир'**
  String get order_created_other_method_seller;

  /// Экран: SCR-22. ч. C; received. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата получена'**
  String get order_created_paid;

  /// Экран: SCR-22. ч. C; только confirmationKind=webhook. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Получено автоматически'**
  String get order_created_paid_auto;

  /// Экран: SCR-22. ч. C; manual. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата подтверждена вручную'**
  String get order_created_paid_manual;

  /// Экран: SCR-22. ч. C; Статус платежа изменился. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Статус платежа изменился. Данные обновлены'**
  String get order_created_payment_state_changed;

  /// Экран: SCR-22. ч. C; qr_expired. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Срок QR истёк'**
  String get order_created_qr_expired;

  /// Экран: SCR-22. ч. C; QrPanel loading. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Формируем QR…'**
  String get order_created_qr_forming;

  /// Экран: SCR-22. ч. C; provider none (Q-014). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'QR не сформирован банком. Покажите клиенту QR-табличку кассы; оплату подтвердит кассир'**
  String get order_created_qr_none;

  /// Экран: SCR-22. ч. C; UI-22-004. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата заказа {number} · Бакай Банк'**
  String order_created_qr_purpose(String number);

  /// Экран: SCR-22. ч. C; PAY-025. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Перевыпустить QR'**
  String get order_created_qr_reissue;

  /// Экран: SCR-22. ч. C; UI-22-013. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Показать покупателю'**
  String get order_created_qr_show_customer;

  /// Экран: SCR-22. ч. C; elqr_static. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'QR торговой точки, без срока действия'**
  String get order_created_qr_static;

  /// Экран: SCR-22. ч. C; QrPanel. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата по QR · Бакай Банк'**
  String get order_created_qr_title;

  /// Экран: SCR-22. ч. C; QR недоступен. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'QR временно недоступен. Покажите QR-табличку или выберите другой способ'**
  String get order_created_qr_unavailable;

  /// Экран: SCR-22. ч. C; версия 1.7; `warnings[QR_UNAVAILABLE]` при `QR_PROVIDER=onec`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'QR не получен из 1С. Покажите QR-табличку кассы — оплату подтвердит кассир — или выберите другой способ'**
  String get order_created_qr_unavailable_onec;

  /// Экран: SCR-22. ч. C; UI-22-005. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Действует до {time} · осталось {left}'**
  String order_created_qr_valid_until(String left, String time);

  /// Экран: SCR-22. ч. C; PAY-024. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сумма оплаты не совпадает с заказом — требуется разбор кассиром'**
  String get order_created_review_amount;

  /// Экран: SCR-22. ч. C; версия 1.6; `late_payment` (ядро §23 п.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата поступила после истечения QR — требуется разбор кассиром'**
  String get order_created_review_late;

  /// Экран: SCR-22. ч. C; unknown_reference. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Платёж с неизвестным референсом — требуется разбор'**
  String get order_created_review_reference;

  /// Экран: SCR-22. ч. C; UI-22-001. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ создан'**
  String get order_created_title;

  /// Экран: SCR-22. ч. C; qr_shown. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидаем оплату'**
  String get order_created_waiting_payment;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долг по заказу: оплачено {paid} из {total} (по данным 1С от {time})'**
  String order_credit_paid_of(String paid, String time, String total);

  /// Экран: SCR-24. ч. C; UI-24-004. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Карточка ›'**
  String get order_customer_card_link;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'После оплаты'**
  String get order_doc_after_payment;

  /// Экран: SCR-24. ч. C; UI-24-009. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скачать PDF'**
  String get order_doc_download;

  /// Экран: SCR-24. ч. C; UI-24-009, раздел 3.9 (версия 1.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Файл содержит персональные данные клиента. Не сохраняйте его в общие папки терминала'**
  String get order_doc_pdn_warning;

  /// Экран: SCR-22, SCR-24. ч. C; UI-22-008, UI-24-009. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Просмотр'**
  String get order_doc_preview;

  /// Экран: SCR-22, SCR-24. ч. C; UI-22-008, UI-24-009. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Печать'**
  String get order_doc_print;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидает номер 1С'**
  String get order_doc_waiting_number;

  /// Экран: SCR-24. этап F, 03 §16.8 (ADR-103); документ UI-24-009; FQ-FEORD-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Накладная'**
  String get order_doc_waybill;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Печатается из 1С при отгрузке'**
  String get order_doc_waybill_from_onec;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплатить до {date}'**
  String order_due_date(String date);

  /// Экран: SCR-24. ч. C; UI-24-003, compact. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Свернуть историю'**
  String get order_history_collapse;

  /// Экран: SCR-24. ч. C; UI-24-003, compact. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Показать всю историю'**
  String get order_history_show_all;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Приложение'**
  String get order_history_source_app;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'1С'**
  String get order_history_source_onec;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ не найден или недоступен'**
  String get order_not_found;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Статус из 1С: {time} · Обновить'**
  String order_onec_freshness(String time);

  /// Экран: SCR-24. ч. C; UI-24-021; ядро §19.2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Привязать к документу 1С'**
  String get order_onec_link_action;

  /// Экран: SCR-24. ч. C; UI-24-022. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выберите документ 1С, соответствующий заказу № {number}, или введите его номер'**
  String order_onec_link_body(String number);

  /// Экран: SCR-24. ч. C; UI-24-022. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Привязать'**
  String get order_onec_link_confirm;

  /// Экран: SCR-24. ч. C; UI-24-021. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ привязан к документу 1С № {onecNumber}'**
  String order_onec_link_done(String onecNumber);

  /// Экран: SCR-24. этап F, 03 §16.8 (ADR-103); поле номера документа 1С в диалоге UI-24-022; FQ-FEORD-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Номер документа 1С'**
  String get order_onec_link_number;

  /// Экран: SCR-24. ч. C; UI-24-022. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Причина привязки'**
  String get order_onec_link_reason;

  /// Экран: SCR-24. ч. C; UI-24-022. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Привязка к документу 1С'**
  String get order_onec_link_title;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'№ 1С {number} от {date}'**
  String order_onec_number(String date, String number);

  /// Экран: SCR-24. ч. C; UI-24-014. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Обновить'**
  String get order_onec_refresh;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'1С недоступна, показаны данные от {time}'**
  String order_onec_unavailable_snackbar(String time);

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплачено {paid} из {total}'**
  String order_paid_of(String paid, String total);

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Платежей нет'**
  String get order_payments_empty;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Добавить к текущей'**
  String get order_repeat_add;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В корзине {count} позиций. Добавить позиции заказа к текущей корзине или отложить текущую?'**
  String order_repeat_dialog_body(int count);

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отложить текущую и начать новую'**
  String get order_repeat_park_and_new;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Добавляем {n} из {count}…'**
  String order_repeat_progress(int count, int n);

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не добавлено: {count} (снято с продажи)'**
  String order_repeat_skipped(int count);

  /// Экран: SCR-24. ч. C; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сканирование номера заказа доступно в списке заказов'**
  String get order_scan_hint;

  /// Экран: SCR-24. этап F, 03 §16.8 (ADR-103); заголовок секции UI-24-009; FQ-FEORD-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Документы'**
  String get order_section_documents;

  /// Экран: SCR-24. этап F, 03 §16.8 (ADR-103); заголовок секции UI-24-003; FQ-FEORD-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'История статусов'**
  String get order_section_history;

  /// Экран: SCR-24. этап F, 03 §16.8 (ADR-103); заголовок секции платежей (SCR-24); FQ-FEORD-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Платежи'**
  String get order_section_payments;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ № {number}'**
  String order_title(String number);

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все'**
  String get orders_chip_all;

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ждут оплаты'**
  String get orders_chip_awaiting_payment;

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отменены и отклонены'**
  String get orders_chip_cancelled;

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Закрыты'**
  String get orders_chip_closed;

  /// Экран: SCR-25. ч. C; UI-25-003, `statusCounts` (ядро §19.2). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{label} · {count}'**
  String orders_chip_count(int count, String label);

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В работе'**
  String get orders_chip_in_progress;

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отгружены'**
  String get orders_chip_shipped;

  /// Экран: SCR-25. этап F, 03 §16.8 (ADR-103); колонка таблицы expanded (SCR-25); FQ-FEORD-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент'**
  String get orders_col_customer;

  /// Экран: SCR-25. этап F, 03 §16.8 (ADR-103); колонка таблицы expanded (SCR-25); FQ-FEORD-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Дата'**
  String get orders_col_date;

  /// Экран: SCR-25. этап F, 03 §16.8 (ADR-103); колонка таблицы expanded (SCR-25, «№ POS / № 1С»); FQ-FEORD-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'№'**
  String get orders_col_number;

  /// Экран: SCR-25. этап F, 03 §16.8 (ADR-103); колонка таблицы expanded (SCR-25, AC-UI-25-005); FQ-FEORD-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплачено'**
  String get orders_col_paid;

  /// Экран: SCR-25. этап F, 03 §16.8 (ADR-103); колонка таблицы expanded (SCR-25); FQ-FEORD-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Статус'**
  String get orders_col_status;

  /// Экран: SCR-25. этап F, 03 §16.8 (ADR-103); колонка таблицы expanded (SCR-25); FQ-FEORD-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сумма'**
  String get orders_col_total;

  /// Экран: SCR-25. ч. C; 03 `EmptyState.orders`, роли с `order.create`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Создать заказ'**
  String get orders_empty_create;

  /// Экран: SCR-25. ч. C; дополнение к 03 (§14 п.22). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ничего не найдено по выбранным фильтрам'**
  String get orders_empty_filtered_title;

  /// Экран: SCR-25. ч. C; 03 `EmptyState.orders`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказов пока нет'**
  String get orders_empty_no_orders_title;

  /// Экран: SCR-25. ч. C; 03 `EmptyState.search`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверьте запрос или отсканируйте штрихкод'**
  String get orders_empty_search_body;

  /// Экран: SCR-25. ч. C; 03 `EmptyState.search`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ничего не найдено по „{q}“'**
  String orders_empty_search_title(String q);

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Фильтры'**
  String get orders_filters;

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Найдено: {count} за период'**
  String orders_found_count(int count);

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось загрузить заказы · Повторить'**
  String get orders_load_failed;

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долг'**
  String get orders_paid_credit;

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплачен'**
  String get orders_paid_full;

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{paid} из {total}'**
  String orders_paid_partial(String paid, String total);

  /// Экран: SCR-25. этап F, 03 §16.8 (ADR-103); вариант фильтра оплаты UI-25-012 («Оплачен / не оплачен», `isPaid=false`); FQ-FEORD-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не оплачен'**
  String get orders_paid_unpaid;

  /// Экран: SCR-25. ч. C; UI-25-004. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'7 дней'**
  String get orders_period_7_days;

  /// Экран: SCR-25. ч. C; UI-25-004. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Период…'**
  String get orders_period_custom;

  /// Экран: SCR-25. ч. C; UI-25-004. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Месяц'**
  String get orders_period_month;

  /// Экран: SCR-25. ч. C; UI-25-004. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сегодня'**
  String get orders_period_today;

  /// Экран: SCR-25. ч. C; UI-25-004. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вчера'**
  String get orders_period_yesterday;

  /// Экран: SCR-25. ч. C; устаревшие данные. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Обновить'**
  String get orders_refresh;

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сбросить фильтры'**
  String get orders_reset_filters;

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ с номером {number} не найден'**
  String orders_scan_not_found(String number);

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все'**
  String get orders_scope_all;

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Мои'**
  String get orders_scope_mine;

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Номер заказа POS или 1С'**
  String get orders_search_hint;

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сначала новые'**
  String get orders_sort_newest;

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'По статусу'**
  String get orders_sort_status;

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'По сумме'**
  String get orders_sort_total;

  /// Экран: SCR-25. ч. C; устаревшие данные. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Данные от {time}'**
  String orders_stale(String time);

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказы'**
  String get orders_title;

  /// Экран: SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Мои заказы'**
  String get orders_title_mine;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.3
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{Осталось попыток: {count}} other{Осталось попыток: {count}}}'**
  String otp_attempts_left(int count);

  /// Экран: SCR-23. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В корзине уже есть {count} позиций. Отложить текущую корзину и продолжить выбранный заказ?'**
  String parked_active_not_empty_body(int count);

  /// Экран: SCR-23. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отложить текущую и продолжить'**
  String get parked_active_not_empty_confirm;

  /// Экран: SCR-23. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Удалится через {days} дн.'**
  String parked_card_expires(String days);

  /// Экран: SCR-23. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Удалится завтра'**
  String get parked_card_expires_tomorrow;

  /// Экран: SCR-23. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{count} позиций · {total} (предварительно)'**
  String parked_card_items_total(int count, String total);

  /// Экран: SCR-23. ч. C; UI-23-007, `409`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ изменился. Список обновлён'**
  String get parked_delete_conflict;

  /// Экран: SCR-23. ч. C; UI-23-013. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Автор: {owner}'**
  String parked_delete_dialog_author(String owner);

  /// Экран: SCR-23. ч. C; UI-23-013 (ICU plural). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ «{name}» ({count} позиций) будет удалён без возможности восстановления'**
  String parked_delete_dialog_body(int count, String name);

  /// Экран: SCR-23. ч. C; UI-23-013. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Удалить'**
  String get parked_delete_dialog_confirm;

  /// Экран: SCR-23. ч. C; UI-23-013. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Удалить отложенный заказ?'**
  String get parked_delete_dialog_title;

  /// Экран: SCR-23. ч. C; UI-23-007 (ядро §19.2). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Удалить отложенный заказ'**
  String get parked_delete_tooltip;

  /// Экран: SCR-23. ч. C; UI-23-007. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отложенный заказ удалён'**
  String get parked_deleted_snackbar;

  /// Экран: SCR-23. ч. C; UI-23-009. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вернуться в корзину'**
  String get parked_empty_back_to_cart;

  /// Экран: SCR-23. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отложенный заказ сохраняется кнопкой «Отложить заказ» в корзине'**
  String get parked_empty_body;

  /// Экран: SCR-23. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отложенных заказов нет'**
  String get parked_empty_title;

  /// Экран: SCR-23. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ уже недоступен'**
  String get parked_not_available;

  /// Экран: SCR-23. ч. C; офлайн. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нужна сеть'**
  String get parked_offline_tooltip;

  /// Экран: SCR-23. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Просмотр отложенных заказов. Продолжить заказ может продавец или старший продавец'**
  String get parked_owner_readonly;

  /// Экран: SCR-23. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Восстановлен из заказа № {number}'**
  String parked_restored_chip(String number);

  /// Экран: SCR-23. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продолжить'**
  String get parked_resume;

  /// Экран: SCR-23. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ «{name}» автора {owner} продолжен вами'**
  String parked_resumed_foreign_snackbar(String name, String owner);

  /// Экран: SCR-23. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все'**
  String get parked_scope_all;

  /// Экран: SCR-23. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Мои'**
  String get parked_scope_mine;

  /// Экран: SCR-23. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отложенные заказы'**
  String get parked_title;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ уже оплачен: {paid} из {total}'**
  String payment_already_paid(String paid, String total);

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Товары {subtotal} · Скидка {percent} −{discount} · Итого {total} · Оплачено {paid}'**
  String payment_breakdown(String discount, String paid, String percent, String subtotal, String total);

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сдача: {amount}'**
  String payment_change(String amount);

  /// Экран: SCR-38. ч. D. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Проверить'**
  String get payment_check;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Закрыть без приёма оплаты?'**
  String get payment_close_confirm;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'QR останется активным до {time}, оплата будет видна в заказе'**
  String payment_close_qr_note(String time);

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент: {customer}. К оплате {amount}, получено {received}, сдача {change}'**
  String payment_confirm_body_cash(String amount, String change, String customer, String received);

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтвердить приём'**
  String get payment_confirm_cta;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтвердите приём оплаты'**
  String get payment_confirm_title;

  /// Экран: SCR-38. ч. D; **с версии 1.5 на SCR-38 не используется** (способ `credit` — только SCR-21; аннулирование QR — также `senior_seller`, 11 §4.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Превышен лимит: доступно {remaining}'**
  String payment_credit_blocked_limit(String remaining);

  /// Экран: SCR-38. ч. D; **с версии 1.5 на SCR-38 не используется** (способ `credit` — только SCR-21; аннулирование QR — также `senior_seller`, 11 §4.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'1С недоступна: продажа в долг невозможна, выберите наличные или QR'**
  String get payment_credit_blocked_onec;

  /// Экран: SCR-38. ч. D; **с версии 1.5 на SCR-38 не используется** (способ `credit` — только SCR-21; аннулирование QR — также `senior_seller`, 11 §4.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продажа в долг недоступна: есть просроченная задолженность {amount}'**
  String payment_credit_blocked_overdue(String amount);

  /// Экран: SCR-38. ч. D; **с версии 1.5 на SCR-38 не используется** (способ `credit` — только SCR-21; аннулирование QR — также `senior_seller`, 11 §4.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продажа в долг недоступна: обратитесь к старшему продавцу'**
  String get payment_credit_blocked_seller;

  /// Экран: SCR-38. ч. D; **с версии 1.5 на SCR-38 не используется** (способ `credit` — только SCR-21; аннулирование QR — также `senior_seller`, 11 §4.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Данные о долге устарели'**
  String get payment_credit_blocked_stale;

  /// Экран: SCR-38. ч. D; **с версии 1.5 на SCR-38 не используется** (способ `credit` — только SCR-21; аннулирование QR — также `senior_seller`, 11 §4.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверяем долг…'**
  String get payment_credit_checking;

  /// Экран: SCR-38. ч. D; **с версии 1.5 на SCR-38 не используется** (способ `credit` — только SCR-21; аннулирование QR — также `senior_seller`, 11 §4.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выберите наличные или QR'**
  String get payment_credit_choose_other;

  /// Экран: SCR-38. ч. D; **с версии 1.5 на SCR-38 не используется** (способ `credit` — только SCR-21; аннулирование QR — также `senior_seller`, 11 §4.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Зафиксировать продажу в долг на {amount}? Срок оплаты: {date}'**
  String payment_credit_confirm(String amount, String date);

  /// Экран: SCR-38. ч. D; версия 1.5; UI-38-013. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ оформлен в долг. Срок оплаты: {date}. Деньги по заказу принимаются как оплата долга клиента'**
  String payment_credit_order_info(String date);

  /// Экран: SCR-38. ч. D; **с версии 1.5 на SCR-38 не используется** (способ `credit` — только SCR-21; аннулирование QR — также `senior_seller`, 11 §4.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Разрешить продажу в долг'**
  String get payment_credit_override;

  /// Экран: SCR-38. ч. D; **с версии 1.5 на SCR-38 не используется** (способ `credit` — только SCR-21; аннулирование QR — также `senior_seller`, 11 §4.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Причина разрешения (не менее 5 символов)'**
  String get payment_credit_override_reason;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Принять {amount}'**
  String payment_cta_accept(String amount);

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Всё сальдо'**
  String get payment_debt_all;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выбрать документы'**
  String get payment_debt_alloc_explicit;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Автоматически (FIFO, как в 1С)'**
  String get payment_debt_alloc_fifo;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сумма оплаты'**
  String get payment_debt_amount;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долг клиента {customer} · сальдо {balance}'**
  String payment_debt_context(String balance, String customer);

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сумма больше сальдо {balance}'**
  String payment_debt_exceeds(String balance);

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Остаток после оплаты (прогноз): {amount}'**
  String payment_debt_forecast(String amount);

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Просроченное'**
  String get payment_debt_overdue;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Платёж принят, ожидает отражения в 1С'**
  String get payment_debt_pending_onec;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Готово'**
  String get payment_done;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сумма не совпадает: платёж отправлен на разбор'**
  String get payment_manual_mismatch;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Референс банка или номер выписки'**
  String get payment_manual_reference;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите референс от 4 до 64 символов'**
  String get payment_manual_reference_error;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтверждение оплаты по выписке'**
  String get payment_manual_title;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Наличными в кассу'**
  String get payment_method_cash;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата в нашем магазине'**
  String get payment_method_cash_sub;

  /// Экран: SCR-38. ч. D; **с версии 1.5 на SCR-38 не используется** (способ `credit` — только SCR-21; аннулирование QR — также `senior_seller`, 11 §4.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Без оплаты / долг'**
  String get payment_method_credit;

  /// Экран: SCR-38. ч. D; **с версии 1.5 на SCR-38 не используется** (способ `credit` — только SCR-21; аннулирование QR — также `senior_seller`, 11 §4.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата позже (по согласованию)'**
  String get payment_method_credit_sub;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'QR / карта Бакай Банк'**
  String get payment_method_qr;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата картой по QR'**
  String get payment_method_qr_sub;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Способ оплаты'**
  String get payment_method_title;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата недоступна для заказа в статусе «{status}»'**
  String payment_not_payable(String status);

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет сети: оплата невозможна'**
  String get payment_offline;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отражено в 1С'**
  String get payment_onec_confirmed;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оформите ПКО в 1С'**
  String get payment_onec_manual;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидает отражения в 1С'**
  String get payment_onec_pending;

  /// Экран: SCR-38. ч. D; версия 1.5; `409 open_payment_exists` (08 §4.8.6). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'По заказу открыт QR-платёж. Сначала проверьте поступление по выписке или аннулируйте QR'**
  String get payment_open_qr_exists;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ № {number} · {customer}'**
  String payment_order_context(String customer, String number);

  /// Экран: SCR-38. ч. D; анимация «формирование QR». Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Другой способ оплаты'**
  String get payment_other_method;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось напечатать чек'**
  String get payment_print_failed;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Товарный чек (нефискальный, 80 мм)'**
  String get payment_print_receipt;

  /// Экран: SCR-38. ч. D; примечание к тексту: показ — только при `Payment.qr.autoConfirm=true`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'После оплаты заказ будет автоматически отмечен как оплаченный'**
  String get payment_qr_auto_note;

  /// Экран: SCR-38. ч. D; анимация «формирование QR». Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось сформировать QR'**
  String get payment_qr_create_error;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Формируем QR…'**
  String get payment_qr_creating;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Срок QR истёк'**
  String get payment_qr_expired;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'После оплаты кассир подтвердит поступление по выписке'**
  String get payment_qr_manual_note;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Обновить QR'**
  String get payment_qr_reissue;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Показать покупателю'**
  String get payment_qr_show_customer;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отменить QR-оплату и принять наличными?'**
  String get payment_qr_switch_confirm;

  /// Экран: SCR-38. ч. D; **с версии 1.5 на SCR-38 не используется** (способ `credit` — только SCR-21; аннулирование QR — также `senior_seller`, 11 §4.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отмена QR доступна кассиру'**
  String get payment_qr_switch_senior_hint;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Банк недоступен для QR. Покажите статический QR и подтвердите оплату вручную или выберите другой способ'**
  String get payment_qr_unavailable;

  /// Экран: SCR-38. ч. D; версия 1.7; `warnings[QR_UNAVAILABLE]` при `QR_PROVIDER=onec`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'1С не сформировала QR. Покажите статический QR и подтвердите оплату вручную или выберите другой способ'**
  String get payment_qr_unavailable_onec;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ № {number} · действует до {time}'**
  String payment_qr_valid_until(String number, String time);

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидаем оплату'**
  String get payment_qr_waiting;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Без сдачи'**
  String get payment_quick_exact;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Получено от клиента'**
  String get payment_received_label;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Получено меньше суммы к оплате'**
  String get payment_received_less;

  /// Экран: SCR-22, SCR-24. ч. C; 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Требует проверки: сумма не совпадает'**
  String get payment_review_amount_mismatch;

  /// Экран: SCR-22, SCR-24, SCR-37, SCR-48. ч. C; версия 1.6; ключ владельца 03 §16.5 — предложение (С-18 (2)), ядро §23 п.4. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Требует проверки: оплата после истечения QR'**
  String get payment_review_late_payment;

  /// Экран: SCR-22, SCR-24, SCR-37, SCR-48. ч. C; версия 1.6; ключ владельца 03 §16.5 — предложение (С-18 (2)), ядро §23 п.4. Источник: 02 §7; текст из 03 §16.5 (приоритет 03, ядро §19.1), в 02 §7 было «Требует проверки: нет уведомления банка»
  ///
  /// In ru, this message translates to:
  /// **'Ожидает подтверждения по выписке'**
  String get payment_review_no_webhook;

  /// Экран: SCR-22, SCR-24. ч. C; 03 §16.5. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Требует проверки: неизвестная ссылка платежа'**
  String get payment_review_unknown_reference;

  /// Экран: SCR-38. ч. D; HID; Unknown; п.11. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сканирование недоступно во время оплаты'**
  String get payment_scan_disabled;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Принято {amount}'**
  String payment_success(String amount);

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сдача {amount}'**
  String payment_success_change(String amount);

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Платёж № {number}'**
  String payment_success_number(String number);

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Приём оплаты'**
  String get payment_title;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'К оплате'**
  String get payment_to_pay;

  /// Экран: SCR-38. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Связь прервалась. Проверьте результат — деньги не принимайте повторно'**
  String get payment_unknown;

  /// Экран: SCR-38. ч. D; HID; Unknown; п.11. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Закрыть? Результат операции неизвестен'**
  String get payment_unknown_close_confirm;

  /// Экран: SCR-38. ч. D; HID; Unknown; п.11. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отменить операцию'**
  String get payment_unknown_discard;

  /// Экран: SCR-38. ч. D; HID; Unknown; п.11. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отменяйте, только если деньги не принимались: после отмены проверить результат будет нельзя'**
  String get payment_unknown_discard_body;

  /// Экран: SCR-07. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Аккаунт активирован'**
  String get pending_activated_snackbar;

  /// Экран: SCR-07. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Аккаунт заблокирован администратором. Обратитесь в магазин'**
  String get pending_blocked_body;

  /// Экран: SCR-07. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Аккаунт заблокирован'**
  String get pending_blocked_title;

  /// Экран: SCR-07. ч. A; срок — Q-203. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Администратор магазина должен подтвердить ваш аккаунт и назначить роль. Обычно это занимает до 1 рабочего дня'**
  String get pending_body;

  /// Экран: SCR-07. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверить статус'**
  String get pending_check;

  /// Экран: SCR-07. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось проверить статус'**
  String get pending_check_error;

  /// Экран: SCR-07. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'проверено {time}'**
  String pending_checked_at(String time);

  /// Экран: SCR-06, 07. ч. A; один текст ячейки для нескольких ключей. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Связаться с магазином'**
  String get pending_contact_shop;

  /// Экран: SCR-07. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'ФИО'**
  String get pending_field_name;

  /// Экран: SCR-07. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Телефон'**
  String get pending_field_phone;

  /// Экран: SCR-07. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Зарегистрирован'**
  String get pending_field_registered;

  /// Экран: SCR-07. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выйти из аккаунта'**
  String get pending_logout;

  /// Экран: SCR-07. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Чтобы войти снова, понадобится код из SMS'**
  String get pending_logout_body;

  /// Экран: SCR-07. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выйти из аккаунта?'**
  String get pending_logout_title;

  /// Экран: SCR-07. ч. A; чип. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'активирован · {role}'**
  String pending_status_active(String role);

  /// Экран: SCR-07. ч. A; чип. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'заблокирован'**
  String get pending_status_blocked;

  /// Экран: SCR-07. ч. A; чип. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'проверяем…'**
  String get pending_status_checking;

  /// Экран: SCR-07. ч. A; чип. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'ожидает активации'**
  String get pending_status_waiting;

  /// Экран: SCR-07. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Аккаунт ожидает активации'**
  String get pending_title;

  /// Экран: SCR-14. ч. B; compact. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Добавлено {qty} {unit} · Открыть корзину'**
  String product_added_snackbar(String qty, String unit);

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Штрихкод: {values}'**
  String product_barcodes(String values);

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'ещё {count}'**
  String product_barcodes_more(int count);

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В корзину · {sum}'**
  String product_cta_add(String sum);

  /// Экран: SCR-14. ч. B; CART-002. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Добавить ещё'**
  String get product_cta_add_more;

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет в наличии'**
  String get product_cta_out_of_stock;

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Добавление недоступно'**
  String get product_cta_unavailable;

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Свернуть'**
  String get product_description_collapse;

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Читать полностью'**
  String get product_description_expand;

  /// Экран: SCR-14. ч. B; вкладки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Описание'**
  String get product_description_title;

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Товар больше не продаётся'**
  String get product_discontinued_banner;

  /// Экран: SCR-14. ч. B; Semantics. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Фото {index} из {count}'**
  String product_gallery_counter_a11y(int count, String index);

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В корзине: {qty} {unit}'**
  String product_in_cart(String qty, String unit);

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Товар не найден или снят с продажи'**
  String get product_not_found_title;

  /// Экран: SCR-14. ч. B; staff. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Код 1С: {code}'**
  String product_onec_code(String code);

  /// Экран: SCR-14. ч. B; INV-026. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Есть на складе «{warehouse}»: {qty} {unit}. Продажа с другого склада одним заказом — вне R1'**
  String product_other_warehouse(String qty, String unit, String warehouse);

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вид цены по клиенту корзины или по умолчанию для роли'**
  String get product_price_list_tooltip;

  /// Экран: SCR-14. ч. B; cashier+. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все виды цен'**
  String get product_price_lists_all;

  /// Экран: SCR-14. ч. B; INV-013. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет цены — обратитесь к администратору'**
  String get product_price_missing_hint;

  /// Экран: SCR-14. ч. B; INV-031. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'За {pack}: {price}'**
  String product_price_per_pack(String pack, String price);

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'/ {unit}'**
  String product_price_unit(String unit);

  /// Экран: SCR-14. ч. B; скидка клиента 1С. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ваша цена'**
  String get product_price_your;

  /// Экран: SCR-14. ч. B; CART-014. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Уменьшите количество в корзине'**
  String get product_qty_reduce_hint;

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Кратность {multiple} {unit} · мин. партия {min} {unit}'**
  String product_qty_rules(String min, String multiple, String unit);

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Количество'**
  String get product_qty_title;

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Артикул скопирован'**
  String get product_sku_copied;

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Артикул не указан'**
  String get product_sku_missing;

  /// Экран: SCR-14. ч. B; INV-011. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'артикул товара'**
  String get product_sku_product_note;

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Арт. варианта: {sku}'**
  String product_sku_variant(String sku);

  /// Экран: SCR-14. ч. B; INV-016. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Показать все ({count})'**
  String product_specs_show_all(int count);

  /// Экран: SCR-14. ч. B; вкладки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Характеристики'**
  String get product_specs_title;

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'склад корзины'**
  String get product_stock_cart_warehouse;

  /// Экран: SCR-14. ч. B; заголовки колонок. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Склад · Остаток · Резерв · Доступно'**
  String get product_stock_columns;

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет данных по складам'**
  String get product_stock_empty;

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось получить остатки · Повторить'**
  String get product_stock_error;

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Остатки по складам'**
  String get product_stock_title;

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Доступно всего: {qty} {unit}'**
  String product_stock_total(String qty, String unit);

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Единица'**
  String get product_unit_title;

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{axis}: {value}'**
  String product_variant_axis(String axis, String value);

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет такого сочетания'**
  String get product_variant_combination_missing;

  /// Экран: SCR-14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выберите {axis}'**
  String product_variant_select_error(String axis);

  /// Экран: SCR-14. ч. B; вкладки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Склады'**
  String get product_warehouses_tab;

  /// Экран: SCR-41. ч. E; подсказка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Например: сантехника, строительство'**
  String get profile_activity_hint;

  /// Экран: SCR-41. ч. E; поле. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сфера деятельности (необязательно)'**
  String get profile_activity_label;

  /// Экран: SCR-10 (шапка), шапка оболочки staff medium+. ревью переноса прототипа 2026-10-29, ADR-112, версия 1.19; UI-10-006: `Semantics` блока пользователя (аватар, имя и роль), меню UI-10-033. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Профиль: {name}, {role}'**
  String profile_avatar_a11y(String name, String role);

  /// Экран: SCR-10 (шапка), шапка оболочки staff medium+. ревью переноса прототипа 2026-10-29, ADR-112, версия 1.19; UI-10-006: `Semantics` блока пользователя, когда роль неизвестна (`{name}` — имя или подпись роли). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Профиль: {name}'**
  String profile_avatar_a11y_name(String name);

  /// Экран: SCR-41. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Год рождения от 1920 до {maxYear}'**
  String profile_birthyear_error_range(String maxYear);

  /// Экран: SCR-41. ч. E; поле. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Год рождения (необязательно)'**
  String get profile_birthyear_label;

  /// Экран: SCR-41. ч. E; 409. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Профиль изменён на другом устройстве. Проверьте и сохраните ещё раз'**
  String get profile_conflict;

  /// Экран: SCR-41. ч. E; блок `customer`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент 1С'**
  String get profile_customer_link_title;

  /// Экран: SCR-41. ч. E; статус `conflict`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидает подтверждения администратором'**
  String get profile_customer_link_waiting;

  /// Экран: SCR-41. ч. E; диалог. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отменить изменения?'**
  String get profile_discard_confirm;

  /// Экран: SCR-41. ч. E; кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Изменить данные'**
  String get profile_edit_button;

  /// Экран: SCR-41. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'От 2 до 150 символов'**
  String get profile_fullname_error_length;

  /// Экран: SCR-41. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите ФИО'**
  String get profile_fullname_error_required;

  /// Экран: SCR-41. ч. E; поле. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'ФИО'**
  String get profile_fullname_label;

  /// Экран: SCR-41. ч. E; шапка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вход: {device} · {time}'**
  String profile_last_login(String device, String time);

  /// Экран: SCR-41. ч. E; UI-41-001, данные `GET /auth/sessions`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вход: {deviceName} · {time}'**
  String profile_login_device(String deviceName, String time);

  /// Экран: SCR-41. ч. E; пункт. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выйти'**
  String get profile_logout;

  /// Экран: SCR-41, SCR-42. ч. E; пункт / кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выйти на всех устройствах'**
  String get profile_logout_all;

  /// Экран: SCR-41, SCR-42. ч. E; диалог. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все сеансы, включая этот, будут завершены. Потребуется вход по SMS'**
  String get profile_logout_all_confirm;

  /// Экран: SCR-41. ч. E; снекбар на SCR-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вы вышли на всех устройствах'**
  String get profile_logout_all_done;

  /// Экран: SCR-41. ч. E; кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выйти всё равно'**
  String get profile_logout_anyway;

  /// Экран: SCR-41. ч. E; диалог. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выйти из аккаунта?'**
  String get profile_logout_confirm;

  /// Экран: SCR-41. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вы вышли. Сессия на сервере будет завершена при появлении сети'**
  String get profile_logout_offline_done;

  /// Экран: SCR-41. ч. E; предупреждение. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В корзине есть неотправленные изменения'**
  String get profile_logout_unsynced_cart;

  /// Экран: SCR-41. ч. E; пункт, `Ctrl+L`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заблокировать'**
  String get profile_menu_lock;

  /// Экран: SCR-41. ч. E; пункт. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Мои заказы'**
  String get profile_menu_my_orders;

  /// Экран: SCR-41. ч. E; пункт. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Мои транзакции'**
  String get profile_menu_my_transactions;

  /// Экран: SCR-41. ч. E; пункт. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Уведомления'**
  String get profile_menu_notifications;

  /// Экран: SCR-41. ч. E; пункт. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Настройки'**
  String get profile_menu_settings;

  /// Экран: SCR-41. ч. E; disabled, метка R2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сменить пользователя'**
  String get profile_menu_switch_user;

  /// Экран: SCR-41. ч. E; пункт. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Синхронизация'**
  String get profile_menu_sync;

  /// Экран: SCR-41. ч. E; пустое значение. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не указано'**
  String get profile_not_specified;

  /// Экран: SCR-41. ч. E; подсказка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Недоступно без сети'**
  String get profile_offline_action_disabled;

  /// Экран: SCR-41. ч. E; диалог. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Прервать смену номера?'**
  String get profile_phone_abort_confirm;

  /// Экран: SCR-41. ч. E; пункт. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сменить номер телефона'**
  String get profile_phone_change;

  /// Экран: SCR-41. ч. E; диалог. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'После смены номера вход выполняется по новому номеру. Все другие устройства будут отключены'**
  String get profile_phone_change_confirm;

  /// Экран: SCR-41. ч. E; успех. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Номер изменён. Другие устройства отключены'**
  String get profile_phone_changed;

  /// Экран: SCR-41. ч. E; шаг 2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Код отправлен на {phone}'**
  String profile_phone_code_sent(String phone);

  /// Экран: SCR-41. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите 9 цифр номера'**
  String get profile_phone_error_format;

  /// Экран: SCR-41. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Это ваш текущий номер'**
  String get profile_phone_error_same;

  /// Экран: SCR-41. ч. E; `PHONE_ALREADY_REGISTERED`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Этот номер уже используется другим пользователем'**
  String get profile_phone_error_taken;

  /// Экран: SCR-41. ч. E; кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Получить код'**
  String get profile_phone_get_code;

  /// Экран: SCR-41. ч. E; поле. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Новый номер телефона'**
  String get profile_phone_new_label;

  /// Экран: SCR-41. ч. E; кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отправить код ещё раз'**
  String get profile_phone_resend;

  /// Экран: SCR-41. ч. E; таймер. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отправить код повторно через {seconds} с'**
  String profile_phone_resend_in(int seconds);

  /// Экран: SCR-41. ч. E; метка R2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скоро'**
  String get profile_r2_badge;

  /// Экран: SCR-41. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Данные сохранены'**
  String get profile_saved;

  /// Экран: SCR-41. ч. E; устаревшие данные. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Данные профиля от {time}'**
  String profile_stale_banner(String time);

  /// Экран: SCR-41. ч. E; заголовок. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Профиль'**
  String get profile_title;

  /// Экран: SCR-41. ч. E; ссылка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Доступно обновление'**
  String get profile_update_available;

  /// Экран: SCR-41. ч. E; пустое необязательное поле. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не указано'**
  String get profile_value_not_set;

  /// Экран: SCR-41. ч. E; caption. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Версия {version} ({build}) · {platform}'**
  String profile_version(String build, String platform, String version);

  /// Экран: SCR-16. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Удалить'**
  String get qty_delete;

  /// Экран: SCR-16. ч. B; INV-005. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Минимальная партия — {min} {unit}'**
  String qty_error_below_min(String min, String unit);

  /// Экран: SCR-16. ч. B; INV-004. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Количество должно быть кратно {m} {unit}'**
  String qty_error_not_multiple(String m, String unit);

  /// Экран: SCR-16. ч. B; INV-006. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Количество упаковок должно быть целым'**
  String get qty_error_pack_integer;

  /// Экран: SCR-16. ч. B; INV-001. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Для единицы „{unit}“ допустимо не более {n} знаков после запятой'**
  String qty_error_precision(int n, String unit);

  /// Экран: SCR-16. ч. B; 10 §4.1. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Доступно только {available} {unit} на складе «{warehouse}»'**
  String qty_error_stock(String available, String unit, String warehouse);

  /// Экран: SCR-16. ч. B; INV-010. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Слишком большое количество'**
  String get qty_error_too_large;

  /// Экран: SCR-16. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Кратность: {multiple} {unit} · Мин. партия: {min} {unit} · Доступно: {available} {unit}'**
  String qty_hint_rules(String available, String min, String multiple, String unit);

  /// Экран: SCR-16. ч. B; Semantics. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'стереть'**
  String get qty_key_backspace_a11y;

  /// Экран: SCR-16. ч. B; Semantics. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'запятая'**
  String get qty_key_decimal_a11y;

  /// Экран: SCR-16. ч. B; Semantics. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'цифра {d}'**
  String qty_key_digit_a11y(String d);

  /// Экран: SCR-16. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Доступно по данным от {time}'**
  String qty_offline_note(String time);

  /// Экран: SCR-16, SCR-14. ч. B; INV-003. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{packs} {pack} = {base} {unit}'**
  String qty_pack_conversion(String base, String pack, String packs, String unit);

  /// Экран: SCR-16. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'+{count}'**
  String qty_quick_add(int count);

  /// Экран: SCR-16. ч. B; INV-004. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Округлить до {next}'**
  String qty_round_up(String next);

  /// Экран: SCR-16. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Количество · {name}'**
  String qty_sheet_title(String name);

  /// Экран: SCR-16. ч. B; CART-012. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'0 — удалить позицию из корзины'**
  String get qty_zero_delete_hint;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.3
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{Просрочка {count} день} few{Просрочка {count} дня} many{Просрочка {count} дней} other{Просрочка {count} дня}}'**
  String receivable_overdue_days(int count);

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Принять оплату по долгу'**
  String get receivables_accept_payment;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Данные 1С на {time}'**
  String receivables_as_of(String time);

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Доступно (прогноз)'**
  String get receivables_available;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Аванс'**
  String get receivables_balance_advance;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долг'**
  String get receivables_balance_debt;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долга нет'**
  String get receivables_balance_zero;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сумма'**
  String get receivables_col_amount;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Дата'**
  String get receivables_col_date;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Документ'**
  String get receivables_col_document;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Срок оплаты'**
  String get receivables_col_due;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Просрочка'**
  String get receivables_col_overdue_days;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплачено'**
  String get receivables_col_paid;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Остаток'**
  String get receivables_col_remaining;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Статус'**
  String get receivables_col_status;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продажа в долг возможна'**
  String get receivables_credit_allowed;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продажа в долг недоступна: лимит исчерпан'**
  String get receivables_credit_blocked_limit;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продажа в долг недоступна: нет данных из 1С о просрочке или лимите'**
  String get receivables_credit_blocked_no_data;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продажа в долг недоступна: есть просроченная задолженность'**
  String get receivables_credit_blocked_overdue;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продажа в долг недоступна: данные о долге устарели'**
  String get receivables_credit_blocked_stale;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отсрочка по соглашению не разрешена'**
  String get receivables_credit_not_allowed;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Детализация не открыта'**
  String get receivables_detail_cancelled;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Документов с остатком нет'**
  String get receivables_detail_empty;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Для просмотра документов подтвердите личность. Просмотр записывается в журнал'**
  String get receivables_detail_locked_body;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Детализация по документам'**
  String get receivables_detail_locked_title;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Детализация расчётов в 1С не ведётся'**
  String get receivables_detail_not_kept;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Детализация открыта до {time} · просмотр записан в аудит'**
  String receivables_detail_open_until(String time);

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Показать детализацию'**
  String get receivables_detail_show;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Просмотр детализации долга: {customer}'**
  String receivables_detail_step_up_reason(String customer);

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидает оплаты до {date}'**
  String receivables_doc_due_until(String date);

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Просрочен {days} дн.'**
  String receivables_doc_overdue_n(String days);

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплачен'**
  String get receivables_doc_paid;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все'**
  String get receivables_filter_all;

  /// Экран: SCR-34. ч. D; чип UI-34-004 (ядро §19.2). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скидки и корректировки'**
  String get receivables_filter_discounts;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказы'**
  String get receivables_filter_orders;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Просроченные'**
  String get receivables_filter_overdue;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Платежи'**
  String get receivables_filter_payments;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Возвраты'**
  String get receivables_filter_returns;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Реализации'**
  String get receivables_filter_shipments;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Лимит'**
  String get receivables_limit;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Лимит: нет данных'**
  String get receivables_limit_none;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось загрузить долг клиента'**
  String get receivables_load_error;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет данных из 1С'**
  String get receivables_no_data;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Данные о долге недоступны без сети'**
  String get receivables_offline;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Открытые заказы в долг'**
  String get receivables_open_orders;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Просрочено {amount} · {days, plural, one{{days} день} few{{days} дня} many{{days} дней} other{{days} дня}}'**
  String receivables_overdue(String amount, int days);

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Обновить'**
  String get receivables_refresh;

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'1С недоступна, показаны данные от {time}'**
  String receivables_refresh_onec_down(String time);

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Данные могут быть неактуальны (от {time})'**
  String receivables_stale(String time);

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отсрочка: {days} дн.'**
  String receivables_term(String days);

  /// Экран: SCR-34. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долги и взаиморасчёты'**
  String get receivables_title;

  /// Экран: SCR-03. ч. A; 11 Шаблон 1. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Согласен(на) на обработку сведений о сфере деятельности (необязательно; можно отозвать в настройках)'**
  String get reg_activity_consent_label;

  /// Экран: SCR-03. ч. A; список — Q-203. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Прораб, строитель'**
  String get reg_activity_foreman;

  /// Экран: SCR-03. ч. A; список — Q-203. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Монтажная организация'**
  String get reg_activity_installer;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не указывать'**
  String get reg_activity_none;

  /// Экран: SCR-03. ч. A; список — Q-203. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Другое'**
  String get reg_activity_other;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Уточните сферу (до 60 символов)'**
  String get reg_activity_other_hint;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выберите из списка'**
  String get reg_activity_placeholder;

  /// Экран: SCR-03. ч. A; список — Q-203. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сантехник'**
  String get reg_activity_plumber;

  /// Экран: SCR-03. ч. A; список — Q-203. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Частное лицо'**
  String get reg_activity_private;

  /// Экран: SCR-03. ч. A; список — Q-203. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Магазин, перепродажа'**
  String get reg_activity_reseller;

  /// Экран: SCR-04. ч. A; чип. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'доступно'**
  String get reg_bio_available;

  /// Экран: SCR-04. ч. A; отдельное согласие. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Разрешаю вход по биометрии устройства (можно отключить в настройках)'**
  String get reg_bio_consent_label;

  /// Экран: SCR-04. ч. A; версия 1.7; 09 REG-038. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Биометрия не включена. Задайте PIN-код, чтобы входить в приложение'**
  String get reg_bio_failed_set_pin;

  /// Экран: SCR-04. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Настроить биометрию позже'**
  String get reg_bio_later;

  /// Экран: SCR-04. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Без Windows Hello'**
  String get reg_bio_later_windows;

  /// Экран: SCR-04. ч. A; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Биометрия не включена. Вход — по PIN-коду. Включить можно в настройках'**
  String get reg_bio_not_enabled;

  /// Экран: SCR-04. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Настройте отпечаток или распознавание лица в настройках устройства'**
  String get reg_bio_not_enrolled;

  /// Экран: SCR-04. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Открыть настройки'**
  String get reg_bio_open_settings;

  /// Экран: SCR-04. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Биометрия устройства'**
  String get reg_bio_tile_title;

  /// Экран: SCR-04. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Недоступно на этом устройстве'**
  String get reg_bio_unsupported;

  /// Экран: SCR-04. ч. A; D-13. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Windows Hello — только для быстрого входа перед PIN, не заменяет PIN'**
  String get reg_bio_windows_hello;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'ГГГГ'**
  String get reg_birth_year_placeholder;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введённые данные сохранятся на этом устройстве 15 минут'**
  String get reg_cancel_body;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Прервать'**
  String get reg_cancel_confirm;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продолжить заполнение'**
  String get reg_cancel_continue;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Прервать регистрацию?'**
  String get reg_cancel_title;

  /// Экран: SCR-04. ч. A; ≤ 20 симв. — допускается 22 (проверить golden). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Завершить регистрацию'**
  String get reg_complete;

  /// Экран: SCR-04. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нужна сеть, чтобы завершить регистрацию'**
  String get reg_complete_offline;

  /// Экран: SCR-03. ч. A; 11 Шаблон 1 («Нажимая «Продолжить»…»). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продолжить'**
  String get reg_continue;

  /// Экран: SCR-03. ч. A; 09 §7.4; Q-161. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите год от {minYear} до {maxYear}'**
  String reg_error_birth_year_range(String maxYear, String minYear);

  /// Экран: SCR-03. ч. A; 09 §7.4. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Укажите год рождения'**
  String get reg_error_birth_year_required;

  /// Экран: SCR-03. ч. A; 09 §7.4 (уточнён). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Чтобы продолжить, подтвердите, что ознакомлены с условиями обработки данных'**
  String get reg_error_consent_required;

  /// Экран: SCR-03. ч. A; 09 §7.4. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Используйте только буквы, пробел и дефис'**
  String get reg_error_name_invalid;

  /// Экран: SCR-03. ч. A; новый. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'ФИО должно содержать от 2 до 120 символов'**
  String get reg_error_name_length;

  /// Экран: SCR-03. ч. A; 09 §7.4. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите фамилию и имя'**
  String get reg_error_name_required;

  /// Экран: SCR-04. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось завершить регистрацию. Данные сохранены — повторите'**
  String get reg_error_network;

  /// Экран: SCR-04, 08. ч. A; 09 §7.4. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'PIN-коды не совпадают'**
  String get reg_error_pin_mismatch;

  /// Экран: SCR-04, 08. ч. A; 09 §7.4. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выберите PIN без повторяющихся или последовательных цифр'**
  String get reg_error_pin_weak;

  /// Экран: SCR-03, 04. ч. A; 09 §7.3. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Время регистрации истекло. Подтвердите номер ещё раз — введённые данные сохранятся'**
  String get reg_error_token_expired;

  /// Экран: SCR-03, 04. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтвердить номер снова'**
  String get reg_expired_action;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сфера деятельности (необязательно)'**
  String get reg_field_activity;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Год рождения *'**
  String get reg_field_birth_year;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'ФИО *'**
  String get reg_field_name;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Фамилия, имя и отчество (если есть)'**
  String get reg_field_name_hint;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Телефон'**
  String get reg_field_phone;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Эти данные увидит администратор магазина'**
  String get reg_form_subtitle;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Расскажите о себе'**
  String get reg_form_title;

  /// Экран: SCR-03…05. ч. A; шапка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Регистрация'**
  String get reg_header;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Без согласия сфера деятельности не будет сохранена'**
  String get reg_hint_activity_consent;

  /// Экран: SCR-04. ч. A; R2 при FACE-SCAN. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Далее'**
  String get reg_next;

  /// Экран: SCR-03. ч. A; UI-03-014. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Я ознакомлен(а) с условиями обработки персональных данных *'**
  String get reg_pd_ack_label;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подробнее'**
  String get reg_pd_more;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Изменить'**
  String get reg_phone_change;

  /// Экран: SCR-03. ч. A; чип. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'подтверждён'**
  String get reg_phone_verified;

  /// Экран: SCR-04, 08, 90. ч. A; 03 §9.6. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'PIN, введено {n} из {length}'**
  String reg_pin_a11y(String length, int n);

  /// Экран: SCR-04, 08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Придумайте PIN-код'**
  String get reg_pin_create;

  /// Экран: SCR-04, 08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Повторите PIN-код'**
  String get reg_pin_repeat;

  /// Экран: SCR-04, 08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{length} цифр, без повторов и простых последовательностей'**
  String reg_pin_rules_hint(String length);

  /// Экран: SCR-04. ч. A; версия 1.7; плитка PIN клиента. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Можно выключить, если включена биометрия'**
  String get reg_pin_tile_optional;

  /// Экран: SCR-04. ч. A; D-48. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Обязателен для сотрудников: нужен для разблокировки и подтверждения операций'**
  String get reg_pin_tile_required;

  /// Экран: SCR-04. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'PIN-код приложения'**
  String get reg_pin_tile_title;

  /// Экран: SCR-04. ч. A; версия 1.7; `login_protection_required` (09 REG-038). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выберите способ защиты входа: PIN-код или биометрию'**
  String get reg_protection_required;

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Мы восстановили введённые ранее данные'**
  String get reg_restored_banner;

  /// Экран: SCR-04. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Чтобы не вводить код из SMS при каждом входе'**
  String get reg_security_subtitle;

  /// Экран: SCR-04. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Защита входа'**
  String get reg_security_title;

  /// Экран: SCR-04. ч. A; версия 1.7; режим «первый вход сотрудника». Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Начать работу'**
  String get reg_staff_first_complete;

  /// Экран: SCR-04. ч. A; версия 1.7; режим «первый вход сотрудника». Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вы вошли по приглашению администратора. PIN нужен для разблокировки и подтверждения операций'**
  String get reg_staff_first_subtitle;

  /// Экран: SCR-04. ч. A; версия 1.7; режим «первый вход сотрудника» (09 §7.6). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Задайте PIN-код для работы'**
  String get reg_staff_first_title;

  /// Экран: SCR-06. ч. A; R1 (ядро v1.9 §24.2); название шага — ядро §19.3. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Привязка'**
  String get reg_step_customer_link;

  /// Экран: SCR-03…06. ч. A; степпер. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Данные'**
  String get reg_step_data;

  /// Экран: SCR-04, 06. ч. A; степпер. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Готово'**
  String get reg_step_done;

  /// Экран: SCR-05. ч. A; R2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Лицо'**
  String get reg_step_face;

  /// Экран: SCR-03…06. ч. A; степпер. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Защита входа'**
  String get reg_step_security;

  /// Экран: SCR-03…06. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Шаг {n} из {total} · {name}'**
  String reg_stepper_compact(int n, String name, String total);

  /// Экран: SCR-04. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Аккаунт создан. Администратор магазина активирует его и назначит роль'**
  String get reg_success_pending;

  /// Экран: SCR-04. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вход настроен: PIN-код'**
  String get reg_success_security_pin;

  /// Экран: SCR-04. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вход настроен: PIN-код · биометрия'**
  String get reg_success_security_pin_bio;

  /// Экран: SCR-04. ч. A; 09 §7.4. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Добро пожаловать, {name}!'**
  String reg_success_title(String name);

  /// Экран: SCR-03. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Время на регистрацию: ещё {mmss}'**
  String reg_timer(String mmss);

  /// Экран: SCR-03. ч. A; предупреждение. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Укажите фамилию и имя полностью — так администратору проще вас найти'**
  String get reg_warning_name_one_word;

  /// Экран: SCR-03. ч. A; полный текст, версия — Q-027. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Шаблон 1 (11 §10.3)'**
  String get register_consent_pd_text;

  /// Экран: SCR-04, 02. ч. A; версия — Q-027. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Шаблон 3 (11 §10.3)'**
  String get register_security_consent_text;

  /// Экран: SCR-48. ч. E; ссылка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Аудит'**
  String get reports_audit_link;

  /// Экран: SCR-48. ч. E; строки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Средний чек'**
  String get reports_avg_check;

  /// Экран: SCR-48. ч. E; строки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отменено: {count}'**
  String reports_cancelled(int count);

  /// Экран: SCR-48. ч. E; карточки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долги'**
  String get reports_card_debts;

  /// Экран: SCR-48. ч. E; карточки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'QR-сверка'**
  String get reports_card_qr;

  /// Экран: SCR-48. ч. E; карточки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продажи'**
  String get reports_card_sales;

  /// Экран: SCR-48. ч. E; caption. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'По данным 1С на {time}'**
  String reports_debt_as_of(String time);

  /// Экран: SCR-48. ч. E; корзины. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'0–30 дней'**
  String get reports_debt_bucket_0_30;

  /// Экран: SCR-48. ч. E; корзины. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'31–60'**
  String get reports_debt_bucket_31_60;

  /// Экран: SCR-48. ч. E; корзины. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'61–90'**
  String get reports_debt_bucket_61_90;

  /// Экран: SCR-48. ч. E; корзины. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'более 90'**
  String get reports_debt_bucket_90_plus;

  /// Экран: SCR-48. ч. E; долги. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Просрочено'**
  String get reports_debt_overdue;

  /// Экран: SCR-48. ч. E; warning. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Данные 1С от {time} могут быть неактуальны'**
  String reports_debt_stale(String time);

  /// Экран: SCR-48. ч. E; долги. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Общий долг'**
  String get reports_debt_total;

  /// Экран: SCR-48. ч. E; строки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скидки'**
  String get reports_discount_total;

  /// Экран: SCR-48. ч. E; empty. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долгов нет'**
  String get reports_empty_debts;

  /// Экран: SCR-48. ч. E; empty. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'QR-платежей нет'**
  String get reports_empty_qr;

  /// Экран: SCR-48. ч. E; empty. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продаж за период нет'**
  String get reports_empty_sales;

  /// Экран: SCR-48. ч. E; кнопка диалога. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выгрузить'**
  String get reports_export_confirm_action;

  /// Экран: SCR-48. ч. E; сценарий включения. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'«{report}» за {period}. Файл содержит финансовые данные'**
  String reports_export_confirm_body(String period, String report);

  /// Экран: SCR-48. ч. E; сценарий включения (Q-156 (Q-217)). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выгрузить в CSV?'**
  String get reports_export_confirm_title;

  /// Экран: SCR-48. ч. E; R2 — в R1 элемент не показывается (Q-156 (Q-217)). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Экспорт CSV'**
  String get reports_export_csv;

  /// Экран: SCR-48. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Файл сохранён'**
  String get reports_export_done;

  /// Экран: SCR-48. ч. E; ошибка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось выгрузить файл. Повторите'**
  String get reports_export_error;

  /// Экран: SCR-48. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Открыть'**
  String get reports_export_open;

  /// Экран: SCR-48. ч. E; R2; в R1 не используется (UI-48-006 скрыт, версия 1.4). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Экспорт будет доступен в следующей версии'**
  String get reports_export_r2_tooltip;

  /// Экран: SCR-48. ч. E; разрез. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Дни'**
  String get reports_groupby_day;

  /// Экран: SCR-48. ч. E; разрез. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Способы оплаты'**
  String get reports_groupby_method;

  /// Экран: SCR-48. ч. E; разрез. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Месяцы'**
  String get reports_groupby_month;

  /// Экран: SCR-48. ч. E; разрез. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продавцы'**
  String get reports_groupby_seller;

  /// Экран: SCR-48. ч. E; разрез. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Склады'**
  String get reports_groupby_warehouse;

  /// Экран: SCR-48. ч. E; разрез. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Недели'**
  String get reports_groupby_week;

  /// Экран: SCR-48. ч. E; способы. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Наличные'**
  String get reports_method_cash;

  /// Экран: SCR-48. ч. E; способы. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В долг'**
  String get reports_method_credit;

  /// Экран: SCR-48. ч. E; способы. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'QR Бакай Банк'**
  String get reports_method_qr;

  /// Экран: SCR-48. ч. E; ICU plural. Источник: 02 §7; формы «a / b / c» 02 §7 преобразованы в ICU plural (03 §16.3)
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{{count} заказ} few{{count} заказа} many{{count} заказов} other{{count} заказа}}'**
  String reports_orders_count(int count);

  /// Экран: SCR-48. ч. E; строки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплачено'**
  String get reports_paid_total;

  /// Экран: SCR-48. ч. E; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отложенные заказы ({count})'**
  String reports_parked_link(int count);

  /// Экран: SCR-48. ч. E; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отложенные заказы'**
  String get reports_parked_link_nocount;

  /// Экран: SCR-48. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Период не больше 366 дней'**
  String get reports_period_error;

  /// Экран: SCR-48. ч. E; фильтр. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все'**
  String get reports_qr_filter_all;

  /// Экран: SCR-48. ч. E; фильтр. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вручную'**
  String get reports_qr_filter_manual;

  /// Экран: SCR-48. ч. E; фильтр. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Расхождения'**
  String get reports_qr_filter_unmatched;

  /// Экран: SCR-48. ч. E; QR. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтверждено вручную'**
  String get reports_qr_manual;

  /// Экран: SCR-48. ч. E; QR. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Расхождения'**
  String get reports_qr_unmatched;

  /// Экран: SCR-48. ч. E; QR. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтверждено банком'**
  String get reports_qr_webhook;

  /// Экран: SCR-48. ч. E; метка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'из 1С'**
  String get reports_source_onec;

  /// Экран: SCR-48. ч. E; заголовок. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отчёты'**
  String get reports_title;

  /// Экран: SCR-39. ч. D; версия 1.6; UI-39-015. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Согласовать заявку'**
  String get return_accept;

  /// Экран: SCR-39. ч. D; версия 1.6. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заявка будет согласована в приложении. Документ возврата и деньги оформляются в 1С'**
  String get return_accept_body;

  /// Экран: SCR-39. ч. D; версия 1.6. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Согласовать заявку на возврат?'**
  String get return_accept_title;

  /// Экран: SCR-39. ч. D; версия 1.6; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заявка согласована'**
  String get return_accepted;

  /// Экран: SCR-39. ч. D; версия 1.6; `409 already_in_onec`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заявка уже передана в 1С: согласование и отклонение — в 1С'**
  String get return_already_in_onec;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Предварительно: {amount}'**
  String return_amount(String amount);

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Комментарий'**
  String get return_comment_label;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Опишите причину (не менее 10 символов)'**
  String get return_comment_required;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Возврат оформлен в 1С: {document}'**
  String return_completed(String document);

  /// Экран: SCR-39. ч. D; UI-39-014, ядро §19.2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Черновик заявки по заказу № {number} будет удалён без возможности восстановления'**
  String return_delete_body(String number);

  /// Экран: SCR-39. ч. D; UI-39-014, ядро §19.2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Удалить черновик'**
  String get return_delete_draft;

  /// Экран: SCR-39. ч. D; UI-39-014. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Удалить черновик заявки?'**
  String get return_delete_title;

  /// Экран: SCR-39. ч. D; UI-39-014. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Черновик заявки удалён'**
  String get return_deleted;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Возвраты оформляются в 1С'**
  String get return_disabled;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Черновик сохранён'**
  String get return_draft_saved;

  /// Экран: SCR-39. ч. D; версия 1.6; CASH-007. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Черновик сотрудника {name}'**
  String return_foreign_draft(String name);

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Больше, чем можно вернуть ({max})'**
  String return_item_exceeds(String max);

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'возвращено полностью'**
  String get return_item_fully_returned;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Можно вернуть: {max}'**
  String return_item_max(String max);

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продано {sold}, возвращено {returned}'**
  String return_item_sold_returned(String returned, String sold);

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выберите хотя бы одну позицию'**
  String get return_items_required;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Позиции к возврату'**
  String get return_items_title;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выбранные позиции не сохранятся'**
  String get return_leave_body;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выйти без сохранения?'**
  String get return_leave_title;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет данных о прежних возвратах — количество будет проверено в 1С'**
  String get return_no_previous_data;

  /// Экран: SCR-39. ч. D; версия 1.6; `404`, 11 SEC-030 (г). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заявка не найдена'**
  String get return_not_found;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Возврат недоступен: заказ не отгружен'**
  String get return_not_returnable;

  /// Экран: SCR-39. ч. D; EditingOffline. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет сети: сохранение и отправка недоступны'**
  String get return_offline_hint;

  /// Экран: SCR-39. ч. D; Offline. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заявка недоступна без сети'**
  String get return_offline_no_data;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Документ возврата, приход на склад и возврат денег оформляются в 1С. Приложение передаёт заявку'**
  String get return_onec_note;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Брак'**
  String get return_reason_defect;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не подошёл'**
  String get return_reason_not_suitable;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Иное'**
  String get return_reason_other;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выберите причину возврата'**
  String get return_reason_required;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ошибка продавца'**
  String get return_reason_seller_error;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Излишек'**
  String get return_reason_surplus;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Причина возврата (обязательно)'**
  String get return_reason_title;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Пересорт'**
  String get return_reason_wrong_item;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Наличными'**
  String get return_refund_kind_cash;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Зачесть в долг'**
  String get return_refund_kind_offset;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'QR'**
  String get return_refund_kind_qr;

  /// Экран: SCR-39. ч. D; версия 1.6; UI-39-016. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отклонить заявку'**
  String get return_reject;

  /// Экран: SCR-39. ч. D; версия 1.6. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Укажите причину (не менее 5 символов)'**
  String get return_reject_reason_error;

  /// Экран: SCR-39. ч. D; версия 1.6. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Причина отклонения'**
  String get return_reject_reason_label;

  /// Экран: SCR-39. ч. D; версия 1.6. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отклонить заявку на возврат?'**
  String get return_reject_title;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заявка отклонена: {reason}'**
  String return_rejected(String reason);

  /// Экран: SCR-39. ч. D; версия 1.6; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заявка отклонена'**
  String get return_rejected_done;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сохранить черновик'**
  String get return_save_draft;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выбрать всё'**
  String get return_select_all;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ № {order} от {date} · Реализация {shipment}'**
  String return_source(String date, String order, String shipment);

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Статус из 1С на {time}'**
  String return_status_as_of(String time);

  /// Экран: SCR-39. ч. D; версия 1.6; описание step-up. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Решение по заявке на возврат № {number}'**
  String return_step_up_decision(String number);

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отправка заявки на возврат на {amount} по заказу № {number}'**
  String return_step_up_reason(String amount, String number);

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отправить заявку'**
  String get return_submit;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заявка отправлена в 1С'**
  String get return_submitted;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сумма заявки превышает порог. Отправить может старший продавец или администратор в своей сессии. Черновик сохранён'**
  String get return_threshold;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заявка на возврат'**
  String get return_title_new;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Возврат № {number}'**
  String return_title_view(String number);

  /// Экран: SCR-39. ч. D; Unknown. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Связь прервалась. Проверьте результат — заявка могла быть сохранена'**
  String get return_unknown;

  /// Экран: SCR-39. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заявка изменена на другом устройстве. Данные обновлены'**
  String get return_version_conflict;

  /// Название роли (общий ключ 03 §16.5, правило 03 §16.2 role_<code>). Текст — 07 §5.4 roles.name_ru (B-AR-11)
  ///
  /// In ru, this message translates to:
  /// **'Администратор'**
  String get role_admin;

  /// Название роли (общий ключ 03 §16.5, правило 03 §16.2 role_<code>). Текст — 07 §5.4 roles.name_ru (B-AR-11)
  ///
  /// In ru, this message translates to:
  /// **'Кассир'**
  String get role_cashier;

  /// Название роли (общий ключ 03 §16.5, правило 03 §16.2 role_<code>). Текст — 07 §5.4 roles.name_ru (B-AR-11)
  ///
  /// In ru, this message translates to:
  /// **'Клиент'**
  String get role_customer;

  /// Название роли (общий ключ 03 §16.5, правило 03 §16.2 role_<code>). Текст — 07 §5.4 roles.name_ru (B-AR-11)
  ///
  /// In ru, this message translates to:
  /// **'Интеграция'**
  String get role_integration;

  /// Название роли (общий ключ 03 §16.5, правило 03 §16.2 role_<code>). Текст — 07 §5.4 roles.name_ru (B-AR-11)
  ///
  /// In ru, this message translates to:
  /// **'Руководитель'**
  String get role_owner;

  /// Название роли (общий ключ 03 §16.5, правило 03 §16.2 role_<code>). Текст — 07 §5.4 roles.name_ru (B-AR-11)
  ///
  /// In ru, this message translates to:
  /// **'Продавец'**
  String get role_seller;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.2
  ///
  /// In ru, this message translates to:
  /// **'Старший продавец'**
  String get role_senior_seller;

  /// Экран: SCR-17. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'+{qty} {unit} · {name}'**
  String scan_added(String name, String qty, String unit);

  /// Экран: SCR-17. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Штрихкод привязан к нескольким товарам, проверьте выбор'**
  String get scan_ambiguous;

  /// Экран: SCR-17. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Камера недоступна. Закройте другие приложения, использующие камеру'**
  String get scan_camera_error;

  /// Экран: SCR-17. ч. B; ICU. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Найдено {count} вариантов. Выберите вариант'**
  String scan_choose_variant(int count);

  /// Экран: SCR-10/17. ч. B; Windows. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отсканировано {value} · {name} +{qty} {unit}'**
  String scan_hid_result(String name, String qty, String unit, String value);

  /// Экран: SCR-10/17. ч. B; Windows. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сканер: ожидание. USB/Bluetooth-сканер в режиме клавиатуры, суффикс Enter'**
  String get scan_hid_waiting;

  /// Экран: SCR-17. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Наведите камеру на штрихкод товара или упаковки'**
  String get scan_hint;

  /// Экран: SCR-17. ч. B; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Наведите камеру на штрихкод или QR-код с распечатки заказа'**
  String get scan_hint_order;

  /// Экран: SCR-17. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Штрихкод не распознан, попробуйте ещё раз'**
  String get scan_invalid_code;

  /// Экран: SCR-17. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось проверить штрихкод · Повторить'**
  String get scan_lookup_error;

  /// Экран: SCR-17. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ввести вручную'**
  String get scan_manual_entry;

  /// Экран: SCR-17. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Разрешите доступ к камере в настройках устройства'**
  String get scan_no_camera_body;

  /// Экран: SCR-17. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Штрихкод {value} не найден'**
  String scan_not_found(String value);

  /// Экран: SCR-17. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Поиск по сохранённому каталогу от {time}'**
  String scan_offline_note(String time);

  /// Экран: SCR-17. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Открыть карточку'**
  String get scan_open_product;

  /// Экран: SCR-17. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Открыть настройки'**
  String get scan_open_settings;

  /// Экран: SCR-17. ч. B; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Номер: {value}'**
  String scan_order_value(String value);

  /// Экран: SCR-17. ч. B; Q-207. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Серия'**
  String get scan_series;

  /// Экран: SCR-17. ч. B; ICU. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Добавлено {count} позиций'**
  String scan_series_summary(int count);

  /// Экран: SCR-17. ч. B; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Распознано: {value} · {format}'**
  String scan_test_result(String format, String value);

  /// Экран: SCR-17. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сканирование'**
  String get scan_title;

  /// Экран: SCR-17. ч. B; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сканирование номера заказа'**
  String get scan_title_order;

  /// Экран: SCR-17. ч. B; добавлено при сборке 1.1 из п. 8 экрана. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверка камеры-сканера'**
  String get scan_title_test;

  /// Экран: SCR-17. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выключить фонарик'**
  String get scan_torch_off_a11y;

  /// Экран: SCR-17. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Включить фонарик'**
  String get scan_torch_on_a11y;

  /// Экран: SCR-11. ч. B; бейджи. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'штрихкод (точно)'**
  String get search_badge_barcode_exact;

  /// Экран: SCR-11. ч. B; бейджи. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'название'**
  String get search_badge_name;

  /// Экран: SCR-11. ч. B; бейджи. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'артикул'**
  String get search_badge_sku;

  /// Экран: SCR-11. ч. B; бейджи. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'артикул (начало)'**
  String get search_badge_sku_prefix;

  /// Экран: SCR-11/14. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Штрихкод привязан к нескольким товарам, проверьте выбор'**
  String get search_barcode_ambiguous;

  /// Экран: SCR-11. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Возможно, товар не выгружен из 1С'**
  String get search_barcode_not_found_body;

  /// Экран: SCR-11. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Штрихкод {value} не найден'**
  String search_barcode_not_found_title(String value);

  /// Экран: SCR-11. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверьте запрос или отсканируйте штрихкод'**
  String get search_empty_body;

  /// Экран: SCR-11. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ввести вручную'**
  String get search_enter_manually;

  /// Экран: SCR-11. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось выполнить поиск · Повторить'**
  String get search_error_inline;

  /// Экран: SCR-10/11/12, шапка оболочки staff medium+. ревью переноса прототипа 2026-10-29, ADR-112, версия 1.19; `Semantics(textField)` поля поиска шапки (03 §9.7) и иконки поиска compact SCR-12 — вместо `search_title` «Результаты поиска» (WCAG 2.4.6, 4.1.2). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Поиск товара'**
  String get search_field_a11y;

  /// Экран: SCR-11. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Найдено: {count} по «{query}»'**
  String search_found_count(int count, String query);

  /// Экран: SCR-11. ч. B; `isEstimate`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Найдено: около {count} по «{query}»'**
  String search_found_estimate(int count, String query);

  /// Экран: SCR-11. ч. B; ICU. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите ещё {count} символ / символа — для артикула и штрихкода любой длины'**
  String search_hint_more_chars(int count);

  /// Экран: SCR-11. ч. B; чипы `matchType`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все'**
  String get search_match_all;

  /// Экран: SCR-11. ч. B; чипы `matchType`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Штрихкод'**
  String get search_match_barcode;

  /// Экран: SCR-11. ч. B; чипы `matchType`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Название'**
  String get search_match_name;

  /// Экран: SCR-11. ч. B; чипы `matchType`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Артикул'**
  String get search_match_sku;

  /// Экран: SCR-11. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не нашли? Проверьте раскладку клавиатуры или отсканируйте штрихкод'**
  String get search_not_found_hint;

  /// Экран: SCR-11. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Поиск по сохранённому каталогу от {time}'**
  String search_offline_note(String time);

  /// Экран: SCR-10/11. ч. B; макет. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Поиск товара по названию, коду или штрих-коду…'**
  String get search_placeholder;

  /// Экран: SCR-11. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Недавние запросы'**
  String get search_recent_queries_title;

  /// Экран: SCR-11. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сканировать снова'**
  String get search_scan_again;

  /// Экран: SCR-10/11. ч. B; 03 §16.2. Источник: 02 §7; текст совпадает с 03 §16.2
  ///
  /// In ru, this message translates to:
  /// **'Сканировать штрихкод'**
  String get search_scanner_tooltip;

  /// Экран: SCR-11. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Во всех категориях'**
  String get search_scope_all;

  /// Экран: SCR-11. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В категории «{name}»'**
  String search_scope_category(String name);

  /// Экран: SCR-11. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Возможно, вы искали «{query}»'**
  String search_suggested_query(String query);

  /// Экран: SCR-11. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Результаты поиска'**
  String get search_title;

  /// Экран: SCR-42. ч. E; строка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Идентификатор устройства: …{suffix}'**
  String settings_about_device_id(String suffix);

  /// Экран: SCR-42. ч. E; ссылки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Лицензии'**
  String get settings_about_licenses;

  /// Экран: SCR-42. ч. E; строки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Минимальная поддерживаемая версия'**
  String get settings_about_min_version;

  /// Экран: SCR-42. ч. E; ссылки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Политика обработки персональных данных'**
  String get settings_about_privacy;

  /// Экран: SCR-42. ч. E; строки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Рекомендуемая версия'**
  String get settings_about_recommended_version;

  /// Экран: SCR-42. ч. E; ссылки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Техническая поддержка'**
  String get settings_about_support;

  /// Экран: SCR-42. ч. E; строки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Версия'**
  String get settings_about_version;

  /// Экран: SCR-42. ч. E; dropdown. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Автоблокировка'**
  String get settings_autolock_label;

  /// Экран: SCR-42. ч. E; значение. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Через {minutes} мин'**
  String settings_autolock_value(int minutes);

  /// Экран: SCR-42. ч. E; тумблер Android. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вход по отпечатку или лицу'**
  String get settings_bio_android;

  /// Экран: SCR-42. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Биометрия не подтверждена. Вход по биометрии не включён'**
  String get settings_bio_cancelled;

  /// Экран: SCR-42. ч. E; чекбокс. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Согласен'**
  String get settings_bio_consent_check;

  /// Экран: SCR-42. ч. E; лист (текст — Q-027). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Согласие на вход по биометрии'**
  String get settings_bio_consent_title;

  /// Экран: SCR-42. ч. E; диалог. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вход по биометрии будет отключён на этом устройстве'**
  String get settings_bio_disable_confirm;

  /// Экран: SCR-42. ч. E; кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Включить'**
  String get settings_bio_enable;

  /// Экран: SCR-42. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вход по биометрии включён'**
  String get settings_bio_enabled;

  /// Экран: SCR-42. ч. E; тумблер iOS. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вход по Face ID / Touch ID'**
  String get settings_bio_ios;

  /// Экран: SCR-42. ч. E; ссылка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Настроить в системе'**
  String get settings_bio_open_system;

  /// Экран: SCR-42. ч. E; подпись. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Биометрия на устройстве недоступна или не настроена'**
  String get settings_bio_unavailable;

  /// Экран: SCR-42. ч. E; тумблер Windows. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Windows Hello перед вводом PIN'**
  String get settings_bio_windows;

  /// Экран: SCR-42. ч. E; подпись. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Windows Hello только подтверждает присутствие. Вход всегда завершается PIN приложения'**
  String get settings_bio_windows_note;

  /// Экран: SCR-42. ч. E; 409. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Настройки изменены на другом устройстве. Показаны актуальные значения'**
  String get settings_conflict;

  /// Экран: SCR-42. ч. E; сегменты. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Авто'**
  String get settings_density_auto;

  /// Экран: SCR-42. ч. E; группа `AppRadio` (UI-42-006). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Компактная'**
  String get settings_density_compact;

  /// Экран: SCR-42. ч. E; сегменты. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Плотность'**
  String get settings_density_label;

  /// Экран: SCR-42. ч. E; сегменты. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Стандартная'**
  String get settings_density_standard;

  /// Экран: SCR-42. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'От 1 до 60 символов'**
  String get settings_device_name_error;

  /// Экран: SCR-42. этап E, 03 §16.7 (ADR-097); самоназвание языка (SCR-42.2), при переводе не меняется; EQ-DREST-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'English'**
  String get settings_language_en;

  /// Экран: SCR-42. этап E, 03 §16.7 (ADR-097); самоназвание языка (SCR-42.2), при переводе не меняется; EQ-DREST-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Кыргызча'**
  String get settings_language_ky;

  /// Экран: SCR-42. этап E, 03 §16.7 (ADR-097); самоназвание языка (SCR-42.2), при переводе не меняется; EQ-DREST-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Русский'**
  String get settings_language_ru;

  /// Экран: SCR-42. ч. E; ky/en disabled (покрытие ARB < 95 %). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скоро'**
  String get settings_language_soon;

  /// Экран: SCR-42. ч. E; подсказка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Недоступно без сети'**
  String get settings_offline_disabled;

  /// Экран: SCR-42. ч. E; диалог. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Прервать смену PIN?'**
  String get settings_pin_abort_confirm;

  /// Экран: SCR-42. ч. E; кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сменить PIN'**
  String get settings_pin_change;

  /// Экран: SCR-42. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'PIN изменён'**
  String get settings_pin_changed;

  /// Экран: SCR-42. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'PIN не совпадает. Введите ещё раз'**
  String get settings_pin_error_mismatch;

  /// Экран: SCR-42. ч. E; `pin_weak`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Слишком простой PIN: не используйте одинаковые цифры, последовательности и год рождения'**
  String get settings_pin_error_weak;

  /// Экран: SCR-42. ч. E; ссылка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Забыли PIN?'**
  String get settings_pin_forgot;

  /// Экран: SCR-42. ч. E; лист. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Новый PIN'**
  String get settings_pin_new_title;

  /// Экран: SCR-42. ч. E; лист. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Повторите PIN'**
  String get settings_pin_repeat_title;

  /// Экран: SCR-42. ч. E; подпись тумблера. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Для сотрудников PIN обязателен'**
  String get settings_pin_required_staff;

  /// Экран: SCR-42. ч. E; строка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'PIN приложения: установлен'**
  String get settings_pin_status_set;

  /// Экран: SCR-42. ч. E; ошибка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось напечатать: {reason}'**
  String settings_print_error(String reason);

  /// Экран: SCR-42. ч. E; кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Тестовая печать'**
  String get settings_print_test;

  /// Экран: SCR-42. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Тестовая страница отправлена на принтер'**
  String get settings_print_test_ok;

  /// Экран: SCR-42. ч. E; содержимое образца (PRINT-010). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'ТЕСТОВАЯ ПЕЧАТЬ · не является фискальным документом'**
  String get settings_print_test_page_title;

  /// Экран: SCR-42. ч. E; поля. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Адрес принтера'**
  String get settings_printer_address;

  /// Экран: SCR-42. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите адрес принтера, например 192.168.1.50'**
  String get settings_printer_address_error;

  /// Экран: SCR-42. ч. E; тумблер. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Печатать автоматически после создания заказа'**
  String get settings_printer_autoprint;

  /// Экран: SCR-42. ч. E; dropdown. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Принтер по умолчанию'**
  String get settings_printer_default;

  /// Экран: SCR-42. ч. E; радио. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Чек 80 мм'**
  String get settings_printer_format_80mm;

  /// Экран: SCR-42. ч. E; радио. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'A4'**
  String get settings_printer_format_a4;

  /// Экран: SCR-42. ч. E; поля. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Порт'**
  String get settings_printer_port;

  /// Экран: SCR-42. ч. E; валидация. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Порт от 1 до 65535'**
  String get settings_printer_port_error;

  /// Экран: SCR-42. ч. E; лист политики ПДн (`GET /me/consents`). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Версия от {date}'**
  String settings_privacy_policy_version(String date);

  /// Экран: SCR-42. ч. E; версия 1.7; `customer`, 09 REG-038. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нельзя выключить единственный способ защиты входа. Сначала включите другой'**
  String get settings_protection_last_method;

  /// Экран: SCR-42. ч. E; тумблер. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Уменьшить анимации'**
  String get settings_reduce_motion;

  /// Экран: SCR-42. ч. E; тумблер. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Требовать PIN при запуске'**
  String get settings_require_pin_label;

  /// Экран: SCR-42. ч. E; откат. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось сохранить настройку. Значение возвращено'**
  String get settings_save_error;

  /// Экран: SCR-42. ч. E; тумблер. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сразу добавлять в корзину'**
  String get settings_scanner_add_to_cart;

  /// Экран: SCR-42. этап E, 03 §16.7 (ADR-097); секция «Сканер», порог HID-скана (UI-42-012, п. 2.2.11); EQ-SCAN-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Интервал между символами'**
  String get settings_scanner_interval_label;

  /// Экран: SCR-42. этап E, 03 §16.7 (ADR-097); значения 30/50/80/100 мс (по умолчанию 50); `ms` — уже отформатированное число; EQ-SCAN-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{ms} мс'**
  String settings_scanner_interval_value(String ms);

  /// Экран: SCR-42. ч. E; сегмент. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Камера'**
  String get settings_scanner_mode_camera;

  /// Экран: SCR-42. ч. E; сегмент. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Аппаратный (HID)'**
  String get settings_scanner_mode_hid;

  /// Экран: SCR-42. ч. E; подсказка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сканер не отправил окончание. Выберите «Без суффикса» или настройте сканер'**
  String get settings_scanner_no_suffix;

  /// Экран: SCR-42. ч. E; значения. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Enter'**
  String get settings_scanner_suffix_enter;

  /// Экран: SCR-42. ч. E; dropdown. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Окончание скана'**
  String get settings_scanner_suffix_label;

  /// Экран: SCR-42. ч. E; значения. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Без суффикса'**
  String get settings_scanner_suffix_none;

  /// Экран: SCR-42. ч. E; значения. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Tab'**
  String get settings_scanner_suffix_tab;

  /// Экран: SCR-42. ч. E; кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверить камерой'**
  String get settings_scanner_test_camera;

  /// Экран: SCR-42. ч. E; результат. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Найден: {name} · арт. {sku}'**
  String settings_scanner_test_found(String name, String sku);

  /// Экран: SCR-42. ч. E; поле теста. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отсканируйте любой штрихкод…'**
  String get settings_scanner_test_hint;

  /// Экран: SCR-42. ч. E; результат. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Штрихкод {code} не найден в каталоге'**
  String settings_scanner_test_not_found(String code);

  /// Экран: SCR-42. ч. E; секция. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'О приложении'**
  String get settings_section_about;

  /// Экран: SCR-42. ч. E; секция. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отображение'**
  String get settings_section_display;

  /// Экран: SCR-42. ч. E; секция. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Язык'**
  String get settings_section_language;

  /// Экран: SCR-42. ч. E; секция. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Принтер'**
  String get settings_section_printer;

  /// Экран: SCR-42. ч. E; секция. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сканер штрихкодов'**
  String get settings_section_scanner;

  /// Экран: SCR-42. ч. E; секция. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Защита входа'**
  String get settings_section_security;

  /// Экран: SCR-42. ч. E; секция. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Устройства и сессии'**
  String get settings_section_sessions;

  /// Экран: SCR-42. ч. E; действие. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Переименовать'**
  String get settings_session_rename;

  /// Экран: SCR-42. ч. E; кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Завершить'**
  String get settings_session_revoke;

  /// Экран: SCR-42. ч. E; диалог. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Завершить сеанс на устройстве {device}?'**
  String settings_session_revoke_confirm(String device);

  /// Экран: SCR-42. ч. E; ошибка `DELETE /auth/sessions/{id}`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось завершить сеанс. Повторите'**
  String get settings_session_revoke_error;

  /// Экран: SCR-42. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сеанс завершён'**
  String get settings_session_revoked;

  /// Экран: SCR-42. ч. E; строка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Активность: {time}'**
  String settings_sessions_last_active(String time);

  /// Экран: SCR-42. этап E, 03 §16.7 (ADR-097); `ErrorState.inline` секции «Устройства и сессии» (SCR-42.7); текст предложен владельцем словаря (в 02/03 не задан) — согласовать при вычитке; EQ-DREST-03. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось загрузить список устройств'**
  String get settings_sessions_load_error;

  /// Экран: SCR-42. ч. E; устаревшие данные. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Список устройств от {time}'**
  String settings_sessions_stale_banner(String time);

  /// Экран: SCR-42. ч. E; метка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Это устройство'**
  String get settings_sessions_this_device;

  /// Экран: SCR-42. ч. E; устаревшие данные. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Настройки от {time}'**
  String settings_stale_caption(String time);

  /// Экран: SCR-42. ч. E; `[НОВОЕ ИМЯ]`, Q-218. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Размер текста'**
  String get settings_text_scale_label;

  /// Экран: SCR-42. ч. E; `[НОВОЕ ИМЯ]`, Q-218. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Крупнее'**
  String get settings_text_scale_large;

  /// Экран: SCR-42. ч. E; `[НОВОЕ ИМЯ]`, Q-218. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Системный'**
  String get settings_text_scale_system;

  /// Экран: SCR-42. ч. E; `[НОВОЕ ИМЯ]`, Q-218. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Крупный'**
  String get settings_text_scale_xlarge;

  /// Экран: SCR-42. ч. E; заголовок. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Настройки'**
  String get settings_title;

  /// Экран: оболочка staff, medium+. прототип 2026-10-29, ADR-112, версия 1.16; кнопка-бургер в шапке (UI-10-002 и все staff-экраны), тултип и Semantics; открывает drawer навигации. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Меню разделов'**
  String get shell_menu_open;

  /// Экран: оболочка staff, medium+. прототип 2026-10-29, ADR-112, версия 1.16; Semantics-метка drawer навигации (03 §9.56). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Навигация'**
  String get shell_nav_a11y;

  /// Экран: оболочка staff, medium+. прототип 2026-10-29, ADR-112, версия 1.16; заголовок второй группы drawer (Заказы, Отложенные заказы, Касса, Отчёты, Журнал аудита и др.); заменяет меню «Ещё» navigation.md §2.2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Другие разделы'**
  String get shell_nav_more;

  /// Экран: SCR-00. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Повторите попытку. Если ошибка повторяется, обратитесь в поддержку'**
  String get splash_init_error_body;

  /// Экран: SCR-00. ч. A; UI-00-005. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось запустить приложение'**
  String get splash_init_error_title;

  /// Экран: SCR-00, все auth. ч. A; Semantics. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Логотип Оптомстрой'**
  String get splash_logo_a11y;

  /// Экран: SCR-00. ч. A; после 2 с индикатора. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверяем сессию…'**
  String get splash_status_checking;

  /// Экран: SCR-00. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Обновляем данные…'**
  String get splash_status_refreshing;

  /// Экран: SCR-00. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Версия {version} ({build})'**
  String splash_version(String build, String version);

  /// Экран: SCR-00. ч. A; Windows. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Версия {version} ({build}) · {deviceName}'**
  String splash_version_terminal(String build, String deviceName, String version);

  /// Экран: SCR-23. ч. C; 03 §9.39. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отложен'**
  String get status_cart_parked;

  /// Экран: SCR-45. ч. E; `invitation_status`; `[НОВОЕ ИМЯ ключей]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Принято'**
  String get status_invitation_accepted;

  /// Экран: SCR-45. ч. E; `invitation_status`; `[НОВОЕ ИМЯ ключей]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Истекло'**
  String get status_invitation_expired;

  /// Экран: SCR-45. ч. E; `invitation_status`; `[НОВОЕ ИМЯ ключей]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидает'**
  String get status_invitation_pending;

  /// Экран: SCR-45. ч. E; `invitation_status`; `[НОВОЕ ИМЯ ключей]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отозвано'**
  String get status_invitation_revoked;

  /// Экран: SCR-41, SCR-45. этап E, 03 §16.7 (ADR-097); `StatusChip` `customer_link_status=confirmed` (03 §9.39); текст предложен владельцем словаря (в 02/03 не задан) — согласовать при вычитке; D FA-03. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Подтверждена'**
  String get status_link_confirmed;

  /// Экран: SCR-41, SCR-45. этап E, 03 §16.7 (ADR-097); `StatusChip` `customer_link_status=conflict` (03 §9.39); текст предложен владельцем словаря (в 02/03 не задан) — согласовать при вычитке; D FA-03. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Конфликт'**
  String get status_link_conflict;

  /// Экран: SCR-41, SCR-45. этап E, 03 §16.7 (ADR-097); `StatusChip` `customer_link_status=proposed` (03 §9.39); текст предложен владельцем словаря (в 02/03 не задан) — согласовать при вычитке; D FA-03. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Ожидает подтверждения'**
  String get status_link_proposed;

  /// Экран: SCR-41, SCR-45. этап E, 03 §16.7 (ADR-097); `StatusChip` `customer_link_status=rejected` (03 §9.39); текст предложен владельцем словаря (в 02/03 не задан) — согласовать при вычитке; D FA-03. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Отклонена'**
  String get status_link_rejected;

  /// Экран: SCR-24, SCR-25. ч. C; событие ORD-040. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Согласован'**
  String get status_order_approved;

  /// Экран: SCR-22, SCR-24, SCR-25. ч. C; ядро §17.2. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидает оплаты'**
  String get status_order_awaiting_payment;

  /// Экран: SCR-24, SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидает отгрузки'**
  String get status_order_awaiting_shipment;

  /// Экран: SCR-24, SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отменён'**
  String get status_order_cancelled;

  /// Экран: SCR-24, SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Закрыт'**
  String get status_order_closed;

  /// Экран: журналы. ч. C; в рабочих экранах не встречается (ядро §17.2). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Черновик (технический)'**
  String get status_order_draft;

  /// Экран: SCR-24, SCR-25. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Частично возвращён'**
  String get status_order_partially_returned;

  /// Экран: SCR-22, SCR-24, SCR-25. ч. C; 03 §16.2 (пример). Источник: 02 §7; текст совпадает с 03 §16.2
  ///
  /// In ru, this message translates to:
  /// **'На согласовании'**
  String get status_order_pending_approval;

  /// Экран: SCR-24, SCR-25. ч. C; реализация 1С. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отгружен'**
  String get status_order_shipped;

  /// Экран: SCR-22, SCR-24, SCR-25. ч. C; ORD-027. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отклонён 1С'**
  String get status_order_submit_failed;

  /// Экран: SCR-22, SCR-24, SCR-25. ч. C; D-20. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидает отправки в 1С'**
  String get status_order_submitting;

  /// Экран: SCR-22, SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидает оплаты наличными'**
  String get status_payment_cash_pending;

  /// Экран: SCR-22, SCR-24. ч. C; PAY-037. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В долг'**
  String get status_payment_credit;

  /// Экран: SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Создан'**
  String get status_payment_initiated;

  /// Экран: SCR-22, SCR-24. ч. C; PAY-024. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтверждён вручную, на проверке'**
  String get status_payment_manual_confirm;

  /// Экран: SCR-22, SCR-24. ч. C; PAY-025. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Срок QR истёк'**
  String get status_payment_qr_expired;

  /// Экран: SCR-22, SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Формируется QR'**
  String get status_payment_qr_pending;

  /// Экран: SCR-22, SCR-24. ч. C; 03 §16.2 (пример). Источник: 02 §7; текст совпадает с 03 §16.2
  ///
  /// In ru, this message translates to:
  /// **'Ожидаем оплату'**
  String get status_payment_qr_shown;

  /// Экран: SCR-22, SCR-24. ч. C. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Получен'**
  String get status_payment_received;

  /// Экран: SCR-24. ч. C; PAY-051. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Возвращён'**
  String get status_payment_refunded;

  /// Экран: SCR-24. ч. C; PAY-050. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Аннулирован'**
  String get status_payment_voided;

  /// Экран: SCR-43. этап E, 03 §16.7 (ADR-097); `StatusChip` `sync_run_status=failed` (03 §9.39); текст предложен владельцем словаря (в 02/03 не задан) — согласовать при вычитке; EQ-E009-04. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Ошибка'**
  String get status_sync_failed;

  /// Экран: SCR-43. этап E, 03 §16.7 (ADR-097); `StatusChip` `sync_run_status=partial` (03 §9.39); текст предложен владельцем словаря (в 02/03 не задан) — согласовать при вычитке; EQ-E009-04. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Частично'**
  String get status_sync_partial;

  /// Экран: SCR-43. этап E, 03 §16.7 (ADR-097); `StatusChip` `sync_run_status=queued` (03 §9.39); текст — как «В очереди» SCR-43 (UI-43-008); EQ-E009-04. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'В очереди'**
  String get status_sync_queued;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.2
  ///
  /// In ru, this message translates to:
  /// **'Выполняется'**
  String get status_sync_running;

  /// Экран: SCR-43. этап E, 03 §16.7 (ADR-097); `StatusChip` `sync_run_status=success` (03 §9.39); текст предложен владельцем словаря (в 02/03 не задан) — согласовать при вычитке; EQ-E009-04. Источник: 02 §7; текст совпадает с 03 §16.5
  ///
  /// In ru, this message translates to:
  /// **'Успешно'**
  String get status_sync_success;

  /// Экран: SCR-45. ч. E; `user_status`; `[НОВОЕ ИМЯ ключей]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Активен'**
  String get status_user_active;

  /// Экран: SCR-45. ч. E; `user_status`; `[НОВОЕ ИМЯ ключей]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заблокирован'**
  String get status_user_blocked;

  /// Экран: SCR-45. ч. E; `user_status`; `[НОВОЕ ИМЯ ключей]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Удалён'**
  String get status_user_deleted;

  /// Экран: SCR-45. ч. E; `user_status`; `[НОВОЕ ИМЯ ключей]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не завершена регистрация'**
  String get status_user_pending;

  /// Экран: SCR-45. ч. E; `user_status`; `[НОВОЕ ИМЯ ключей]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидает активации'**
  String get status_user_pending_activation;

  /// Экран: SCR-90 B. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтвердить кодом из SMS'**
  String get stepup_by_sms;

  /// Экран: SCR-90 B. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нужна сеть для подтверждения'**
  String get stepup_offline;

  /// Экран: SCR-90 B. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'PIN заблокирован. Подтвердите кодом из SMS'**
  String get stepup_pin_locked;

  /// Экран: SCR-90 B. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'PIN не задан. Подтвердите кодом из SMS и задайте PIN в настройках'**
  String get stepup_pin_not_set;

  /// Экран: SCR-90 B. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Повторно в течение 15 минут подтверждать не потребуется'**
  String get stepup_reuse_hint;

  /// Экран: `StepUpDialog`. этап E, 03 §16.7 (ADR-097); кнопка способа «Код из SMS», 03 §16.7; D SS-02. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отправить код'**
  String get stepup_send_code;

  /// Экран: SCR-90 B. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Отправить код на {phoneMasked}?'**
  String stepup_sms_confirm(String phoneMasked);

  /// Экран: `StepUpDialog`. этап E, 03 §16.7 (ADR-097); вкладка способа, 03 §9.46; D SS-02. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'PIN'**
  String get stepup_tab_pin;

  /// Экран: `StepUpDialog`. этап E, 03 §16.7 (ADR-097); вкладка способа, 03 §9.46; D SS-02. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Код из SMS'**
  String get stepup_tab_sms;

  /// Экран: `StepUpDialog`. этап E, 03 §16.7 (ADR-097); состояние `verifying`, 03 §9.46; D SS-02. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверяем…'**
  String get stepup_verifying;

  /// Экран: SCR-10, SCR-14, SCR-50 (`StockBadge`). этап E, 03 §16.7 (ADR-097); вариант `inStock` без числа (в т. ч. `customer` при `customer_stock_display=status`), 03 §9.17; EQ-PD-01, FIX-EF-04. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В наличии'**
  String get stock_badge_in_stock;

  /// Экран: SCR-10, SCR-14, SCR-50 (`StockBadge`). этап E, 03 §16.7 (ADR-097); вариант `inStock` с числом (`available`, единица), 03 §9.17; EQ-PD-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В наличии · {qty} {unit}'**
  String stock_badge_in_stock_qty(String qty, String unit);

  /// Экран: SCR-10, SCR-14, SCR-50 (`StockBadge`). этап E, 03 §16.7 (ADR-097); вариант `low` без числа, 03 §9.17; EQ-PD-01, FIX-EF-04. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Мало'**
  String get stock_badge_low;

  /// Экран: SCR-10, SCR-14, SCR-50 (`StockBadge`). этап E, 03 §16.7 (ADR-097); вариант `low` с числом, 03 §9.17; EQ-PD-01. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Мало · {qty} {unit}'**
  String stock_badge_low_qty(String qty, String unit);

  /// Экран: SCR-43. ч. E; caption. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Проверено {time} · обновляется каждые 30 с'**
  String sync_checked_at(String time);

  /// Экран: SCR-43. ч. E; `EmptyState generic`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ошибок нет'**
  String get sync_empty_errors;

  /// Экран: SCR-43. ч. E; `EmptyState generic`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Очередь пуста'**
  String get sync_empty_outbox;

  /// Экран: SCR-43. ч. E; `EmptyState generic`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Прогонов за период нет'**
  String get sync_empty_runs;

  /// Экран: SCR-43, SCR-44. Подпись сущности синхронизации, enum sync_entity = `attributes` (ядро §6, §17.3); развёрнуто из шаблона `sync_entity_<code>`. ч. E; 17 значений `sync_entity` (ядро §6, §17.3); `[НОВОЕ ИМЯ префикса]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Характеристики'**
  String get sync_entity_attributes;

  /// Экран: SCR-43, SCR-44. Подпись сущности синхронизации, enum sync_entity = `barcodes` (ядро §6, §17.3); развёрнуто из шаблона `sync_entity_<code>`. ч. E; 17 значений `sync_entity` (ядро §6, §17.3); `[НОВОЕ ИМЯ префикса]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Штрихкоды'**
  String get sync_entity_barcodes;

  /// Экран: SCR-43, SCR-44. Подпись сущности синхронизации, enum sync_entity = `categories` (ядро §6, §17.3); развёрнуто из шаблона `sync_entity_<code>`. ч. E; 17 значений `sync_entity` (ядро §6, §17.3); `[НОВОЕ ИМЯ префикса]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Категории'**
  String get sync_entity_categories;

  /// Экран: SCR-43, SCR-44. Подпись сущности синхронизации, enum sync_entity = `customers` (ядро §6, §17.3); развёрнуто из шаблона `sync_entity_<code>`. ч. E; 17 значений `sync_entity` (ядро §6, §17.3); `[НОВОЕ ИМЯ префикса]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиенты'**
  String get sync_entity_customers;

  /// Экран: SCR-43, SCR-44. Подпись сущности синхронизации, enum sync_entity = `discounts` (ядро §6, §17.3); развёрнуто из шаблона `sync_entity_<code>`. ч. E; 17 значений `sync_entity` (ядро §6, §17.3); `[НОВОЕ ИМЯ префикса]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скидки'**
  String get sync_entity_discounts;

  /// Экран: SCR-43, SCR-44. Подпись сущности синхронизации, enum sync_entity = `images` (ядро §6, §17.3); развёрнуто из шаблона `sync_entity_<code>`. ч. E; 17 значений `sync_entity` (ядро §6, §17.3); `[НОВОЕ ИМЯ префикса]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Фото'**
  String get sync_entity_images;

  /// Экран: SCR-43, SCR-44. Подпись сущности синхронизации, enum sync_entity = `order_status` (ядро §6, §17.3); развёрнуто из шаблона `sync_entity_<code>`. ч. E; 17 значений `sync_entity` (ядро §6, §17.3); `[НОВОЕ ИМЯ префикса]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Статусы заказов'**
  String get sync_entity_order_status;

  /// Экран: SCR-43, SCR-44. Подпись сущности синхронизации, enum sync_entity = `payment_docs` (ядро §6, §17.3); развёрнуто из шаблона `sync_entity_<code>`. ч. E; 17 значений `sync_entity` (ядро §6, §17.3); `[НОВОЕ ИМЯ префикса]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Платёжные документы'**
  String get sync_entity_payment_docs;

  /// Экран: SCR-43, SCR-44. Подпись сущности синхронизации, enum sync_entity = `prices` (ядро §6, §17.3); развёрнуто из шаблона `sync_entity_<code>`. ч. E; 17 значений `sync_entity` (ядро §6, §17.3); `[НОВОЕ ИМЯ префикса]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Цены'**
  String get sync_entity_prices;

  /// Экран: SCR-43, SCR-44. Подпись сущности синхронизации, enum sync_entity = `products` (ядро §6, §17.3); развёрнуто из шаблона `sync_entity_<code>`. ч. E; 17 значений `sync_entity` (ядро §6, §17.3); `[НОВОЕ ИМЯ префикса]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Товары'**
  String get sync_entity_products;

  /// Экран: SCR-43, SCR-44. Подпись сущности синхронизации, enum sync_entity = `receivables` (ядро §6, §17.3); развёрнуто из шаблона `sync_entity_<code>`. ч. E; 17 значений `sync_entity` (ядро §6, §17.3); `[НОВОЕ ИМЯ префикса]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долги'**
  String get sync_entity_receivables;

  /// Экран: SCR-43, SCR-44. Подпись сущности синхронизации, enum sync_entity = `return_docs` (ядро §6, §17.3); развёрнуто из шаблона `sync_entity_<code>`. ч. E; 17 значений `sync_entity` (ядро §6, §17.3); `[НОВОЕ ИМЯ префикса]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Документы возвратов'**
  String get sync_entity_return_docs;

  /// Экран: SCR-43, SCR-44. Подпись сущности синхронизации, enum sync_entity = `sales_history` (ядро §6, §17.3); развёрнуто из шаблона `sync_entity_<code>`. ч. E; 17 значений `sync_entity` (ядро §6, §17.3); `[НОВОЕ ИМЯ префикса]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'История продаж'**
  String get sync_entity_sales_history;

  /// Экран: SCR-43, SCR-44. Подпись сущности синхронизации, enum sync_entity = `stock` (ядро §6, §17.3); развёрнуто из шаблона `sync_entity_<code>`. ч. E; 17 значений `sync_entity` (ядро §6, §17.3); `[НОВОЕ ИМЯ префикса]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Остатки'**
  String get sync_entity_stock;

  /// Экран: SCR-43, SCR-44. Подпись сущности синхронизации, enum sync_entity = `units` (ядро §6, §17.3); развёрнуто из шаблона `sync_entity_<code>`. ч. E; 17 значений `sync_entity` (ядро §6, §17.3); `[НОВОЕ ИМЯ префикса]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Единицы'**
  String get sync_entity_units;

  /// Экран: SCR-43, SCR-44. Подпись сущности синхронизации, enum sync_entity = `variants` (ядро §6, §17.3); развёрнуто из шаблона `sync_entity_<code>`. ч. E; 17 значений `sync_entity` (ядро §6, §17.3); `[НОВОЕ ИМЯ префикса]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Варианты'**
  String get sync_entity_variants;

  /// Экран: SCR-43, SCR-44. Подпись сущности синхронизации, enum sync_entity = `warehouses` (ядро §6, §17.3); развёрнуто из шаблона `sync_entity_<code>`. ч. E; 17 значений `sync_entity` (ядро §6, §17.3); `[НОВОЕ ИМЯ префикса]`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Склады'**
  String get sync_entity_warehouses;

  /// Экран: SCR-43. ч. E; ICU plural. Источник: 02 §7; формы «a / b / c» 02 §7 преобразованы в ICU plural (03 §16.3)
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{{count} ошибка подряд} few{{count} ошибки подряд} many{{count} ошибок подряд} other{{count} ошибки подряд}}'**
  String sync_errors_count(int count);

  /// Экран: SCR-43. ч. E; ICU plural. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'каждые {minutes} мин'**
  String sync_interval(int minutes);

  /// Экран: SCR-43. ч. E; строка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Последний успешный обмен: {time}'**
  String sync_last_success(String time);

  /// Экран: SCR-43. этап E, 03 §16.7 (ADR-097); офлайн, локальный `sync_meta` (SCR-43.7); EQ-E009-03. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Каталог на устройстве обновлён {time}'**
  String sync_local_updated_at(String time);

  /// Экран: SCR-43. ч. E; версия 1.5; ядро §22.8. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Обмен запускает 1С: ручной запуск недоступен'**
  String get sync_manual_run_inbound_mode;

  /// Экран: SCR-43. ч. E; `sync_mode`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Полная загрузка'**
  String get sync_mode_full;

  /// Экран: SCR-43. ч. E; `sync_mode`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Только изменения'**
  String get sync_mode_incremental;

  /// Экран: SCR-43. ч. E; `sync_mode`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сверка'**
  String get sync_mode_reconcile;

  /// Экран: SCR-43. ч. E; empty. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ещё не синхронизировано'**
  String get sync_never;

  /// Экран: SCR-43. ч. E; строка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Следующий: {time}'**
  String sync_next_run(String time);

  /// Экран: SCR-43. ч. E; статус. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'1С доступна'**
  String get sync_onec_reachable;

  /// Экран: SCR-43. ч. E; статус. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'1С недоступна'**
  String get sync_onec_unreachable;

  /// Экран: SCR-43. ч. E; 409. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Документ уже отправлен в 1С'**
  String get sync_outbox_already_sent;

  /// Экран: SCR-43. ч. E; зона A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'В очереди {pending} · Ошибки {failed} · Отказы {dead}'**
  String sync_outbox_counts(String dead, String failed, String pending);

  /// Экран: SCR-43. ч. E; снекбар. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Поставлено в очередь'**
  String get sync_outbox_retried;

  /// Экран: SCR-43. ч. E; кнопка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Повторить'**
  String get sync_outbox_retry;

  /// Экран: SCR-43. ч. E; диалог. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Повторить отправку {number} в 1С? Убедитесь, что причина ошибки устранена'**
  String sync_outbox_retry_confirm(String number);

  /// Экран: SCR-43. ч. E; статус. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Есть задержки'**
  String get sync_overall_degraded;

  /// Экран: SCR-43. ч. E; статус. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Обмен нарушен'**
  String get sync_overall_failed;

  /// Экран: SCR-43. ч. E; статус. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Обмен работает'**
  String get sync_overall_ok;

  /// Экран: SCR-43. ч. E; подсказка. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ручной запуск выполняет старший продавец или администратор'**
  String get sync_permission_hint;

  /// Экран: SCR-43. ч. E; 429. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Слишком частый запуск. Повторите через {seconds} с'**
  String sync_rate_limited(int seconds);

  /// Экран: SCR-43. ч. E; loading. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Обновляем…'**
  String get sync_run_button_busy;

  /// Экран: SCR-43. ч. E; `senior_seller`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Обновить статусы'**
  String get sync_run_button_order_status;

  /// Экран: SCR-43. ч. E; `senior_seller`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Обновить цены'**
  String get sync_run_button_prices;

  /// Экран: SCR-43. ч. E; `senior_seller`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Обновить остатки'**
  String get sync_run_button_stock;

  /// Экран: SCR-43. ч. E; диалог. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Что синхронизировать'**
  String get sync_run_dialog_entity;

  /// Экран: SCR-43. ч. E; диалог. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Режим'**
  String get sync_run_dialog_mode;

  /// Экран: SCR-43. ч. E; диалог. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Запуск синхронизации'**
  String get sync_run_dialog_title;

  /// Экран: SCR-43. ч. E; снекбары. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'завершена'**
  String get sync_run_done;

  /// Экран: SCR-43. ч. E; снекбары. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Синхронизация не выполнена'**
  String get sync_run_failed;

  /// Экран: SCR-43. ч. E; предупреждение. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Полная загрузка увеличивает нагрузку на 1С и может занять до {minutes} мин. Рекомендуется вне рабочего времени'**
  String sync_run_full_warning(int minutes);

  /// Экран: SCR-43. этап E, 03 §16.7 (ADR-097); SCR-43.4: предупреждение `full`/`reconcile` без оценки длительности (текст `sync_run_full_warning` без числа); EQ-E009-05. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Полная загрузка увеличивает нагрузку на 1С и может занять продолжительное время. Рекомендуется вне рабочего времени'**
  String get sync_run_full_warning_no_estimate;

  /// Экран: SCR-43. ч. E; `admin`/`owner`. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Запустить…'**
  String get sync_run_open_dialog;

  /// Экран: SCR-43. ч. E; снекбары. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Завершено с ошибками: {count}'**
  String sync_run_partial(int count);

  /// Экран: SCR-43. ч. E; снекбары. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Синхронизация запущена'**
  String get sync_run_started;

  /// Экран: SCR-43. ч. E; прогон. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'идёт {minutes} мин'**
  String sync_running_for(int minutes);

  /// Экран: SCR-43. ч. E; баннер. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{entity}: данные старше {minutes} мин'**
  String sync_stale_banner(String entity, int minutes);

  /// Экран: SCR-43. ч. E; вкладки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сущности'**
  String get sync_tab_entities;

  /// Экран: SCR-43. ч. E; вкладки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ошибки'**
  String get sync_tab_errors;

  /// Экран: SCR-43. ч. E; вкладки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Outbox'**
  String get sync_tab_outbox;

  /// Экран: SCR-43. ч. E; вкладки. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Прогоны'**
  String get sync_tab_runs;

  /// Экран: SCR-43. ч. E; заголовок. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Синхронизация с 1С'**
  String get sync_title;

  /// Экран: SCR-43. ч. E; `triggeredBy=null`, до появления `trigger` в 08. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Автоматически'**
  String get sync_trigger_auto;

  /// Экран: SCR-43. ч. E; `sync_trigger` (07); используются после добавления `trigger` в `SyncRun` 08 (замечание №17). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'По зависимости'**
  String get sync_trigger_dependency;

  /// Экран: SCR-43. ч. E; `sync_trigger` (07); используются после добавления `trigger` в `SyncRun` 08 (замечание №17). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вручную: {name}'**
  String sync_trigger_manual(String name);

  /// Экран: SCR-43. ч. E; `sync_trigger` (07); используются после добавления `trigger` в `SyncRun` 08 (замечание №17). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Повтор'**
  String get sync_trigger_retry;

  /// Экран: SCR-43. ч. E; `sync_trigger` (07); используются после добавления `trigger` в `SyncRun` 08 (замечание №17). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'По расписанию'**
  String get sync_trigger_schedule;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Принять оплату'**
  String get transaction_details_action_accept;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтвердить вручную'**
  String get transaction_details_action_confirm_manual;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Открыть заказ'**
  String get transaction_details_action_open_order;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Печать'**
  String get transaction_details_action_print;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заявка на возврат'**
  String get transaction_details_action_return;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Аннулировать платёж'**
  String get transaction_details_action_void;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Аудит'**
  String get transaction_details_audit;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все записи'**
  String get transaction_details_audit_all;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Автор'**
  String get transaction_details_author;

  /// Экран: SCR-37. ч. D; NotFound. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'К журналу операций'**
  String get transaction_details_back_to_list;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сдача'**
  String get transaction_details_change;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Оплата подтверждена'**
  String get transaction_details_confirm_done;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Референс банка или номер выписки'**
  String get transaction_details_confirm_reference;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите референс от 4 до 64 символов'**
  String get transaction_details_confirm_reference_error;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент'**
  String get transaction_details_customer;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Устройство'**
  String get transaction_details_device;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'История статусов'**
  String get transaction_details_history;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Способ'**
  String get transaction_details_method;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Операция не найдена'**
  String get transaction_details_not_found;

  /// Экран: SCR-37. ч. D; ReadyOffline. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет сети: действия недоступны'**
  String get transaction_details_offline;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Номер в 1С'**
  String get transaction_details_onec_number;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Получено'**
  String get transaction_details_received;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Связанные документы'**
  String get transaction_details_related;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Связанных документов нет'**
  String get transaction_details_related_empty;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Возврат оформляется в 1С'**
  String get transaction_details_return_in_onec;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Требует проверки: получено {received} из {amount}'**
  String transaction_details_review_mismatch(String amount, String received);

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Требует проверки: неизвестная ссылка платежа'**
  String get transaction_details_review_unknown;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'1С'**
  String get transaction_details_source_onec;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'POS'**
  String get transaction_details_source_pos;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Статус платежа изменился. Данные обновлены'**
  String get transaction_details_state_changed;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Результат операции неизвестен · Проверить'**
  String get transaction_details_unknown_result;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Платёж {amount} по заказу № {number} будет аннулирован. Деньги не должны быть получены'**
  String transaction_details_void_body(String amount, String number);

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Опишите причину (не менее 5 символов)'**
  String get transaction_details_void_comment_required;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Платёж аннулирован'**
  String get transaction_details_void_done;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ошибка кассира'**
  String get transaction_details_void_reason_cashier_error;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент отказался'**
  String get transaction_details_void_reason_customer_refused;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Дубликат'**
  String get transaction_details_void_reason_duplicate;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Иное'**
  String get transaction_details_void_reason_other;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Деньги получены — оформите возврат в 1С'**
  String get transaction_details_void_received_hint;

  /// Экран: SCR-37. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Аннулировать платёж?'**
  String get transaction_details_void_title;

  /// Экран: SCR-37. ч. D; UI-37-011 (накладная). Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Печатается из 1С'**
  String get transaction_details_waybill_onec;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{Показать {count} операцию} few{Показать {count} операции} many{Показать {count} операций} other{Показать {count} операции}}'**
  String transactions_apply_n(int count);

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Операций за период нет'**
  String get transactions_empty;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Показаны все операции за период'**
  String get transactions_end;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сотрудник'**
  String get transactions_filter_actor;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Клиент'**
  String get transactions_filter_customer;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось применить фильтр'**
  String get transactions_filter_failed;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Тип операции'**
  String get transactions_filter_kind;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Способ оплаты'**
  String get transactions_filter_method;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Статус'**
  String get transactions_filter_status;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Фильтры · {count}'**
  String transactions_filters(int count);

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Продажа в долг разрешена'**
  String get transactions_kind_credit_sale_approved;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Скидка сверх лимита'**
  String get transactions_kind_discount_override;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ручное подтверждение QR'**
  String get transactions_kind_manual_qr_confirm;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ отменён'**
  String get transactions_kind_order_cancelled;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заказ создан'**
  String get transactions_kind_order_created;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Платёж получен'**
  String get transactions_kind_payment_received;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Платёж аннулирован'**
  String get transactions_kind_payment_voided;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Возврат'**
  String get transactions_kind_refund;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заявка на возврат'**
  String get transactions_kind_return_requested;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Наличные'**
  String get transactions_method_cash;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Долг'**
  String get transactions_method_credit;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'QR'**
  String get transactions_method_qr;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Журнал операций недоступен без сети'**
  String get transactions_offline;

  /// Экран: SCR-36. ч. D; Offline с данными в памяти. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет сети. Показаны данные от {time}'**
  String transactions_offline_stale(String time);

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Только мои'**
  String get transactions_only_mine;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'7 дней'**
  String get transactions_period_7d;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Период…'**
  String get transactions_period_custom;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Месяц'**
  String get transactions_period_month;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сегодня'**
  String get transactions_period_today;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Период больше {days} дней'**
  String transactions_period_too_long(String days);

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вчера'**
  String get transactions_period_yesterday;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сбросить всё'**
  String get transactions_reset_all;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Номер документа'**
  String get transactions_search_number;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'1С'**
  String get transactions_source_onec;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ошибка отправки в 1С'**
  String get transactions_status_onec_error;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Ожидает оплаты'**
  String get transactions_status_pending;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Получено'**
  String get transactions_status_received;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Возврат'**
  String get transactions_status_returned;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Аннулировано, отменено'**
  String get transactions_status_voided;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Операций: {count}'**
  String transactions_sum_count(int count);

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Приход'**
  String get transactions_sum_in;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Возвраты и аннулирования'**
  String get transactions_sum_out;

  /// Экран: SCR-36. ч. D. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Транзакции'**
  String get transactions_title;

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.3; сокращения единиц не склоняются; полная форма — `unit_pcs_full`: `one{штука} few{штуки} many{штук}` для screen reader
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{{count} шт} other{{count} шт}}'**
  String unit_pcs(int count);

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.3; полная форма для screen reader; other добавлен сборкой (ICU)
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{штука} few{штуки} many{штук} other{штуки}}'**
  String unit_pcs_full(int count);

  /// Экран: SCR-08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Войти по биометрии'**
  String get unlock_bio_button;

  /// Экран: SCR-08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Забыли PIN?'**
  String get unlock_forgot_pin;

  /// Экран: SCR-08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Windows Hello'**
  String get unlock_hello_button;

  /// Экран: SCR-08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Подтверждено Windows Hello · введите PIN'**
  String get unlock_hello_verified;

  /// Экран: SCR-08. ч. A; overlay. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Через {minutes} мин бездействия'**
  String unlock_locked_idle(int minutes);

  /// Экран: SCR-08. ч. A; overlay. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заблокировано вручную'**
  String get unlock_locked_manual;

  /// Экран: SCR-08. ч. A; overlay. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Экран заблокирован'**
  String get unlock_locked_title;

  /// Экран: SCR-08. ч. A; UI-08-014. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сохранить PIN'**
  String get unlock_new_pin_save;

  /// Экран: SCR-08. ч. A; UI-08-014. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Задайте новый PIN'**
  String get unlock_new_pin_title;

  /// Экран: SCR-08. ч. A; Q-241. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет подключения. Для входа нужна сеть'**
  String get unlock_offline;

  /// Экран: SCR-08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'или PIN-код'**
  String get unlock_or_pin;

  /// Экран: SCR-08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Войти по номеру телефона'**
  String get unlock_phone_login;

  /// Экран: SCR-08. ч. A; UI-08-014. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'PIN изменён'**
  String get unlock_pin_changed;

  /// Экран: SCR-08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Введите PIN-код приложения'**
  String get unlock_pin_hint;

  /// Экран: SCR-08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Войдите по коду из SMS, затем задайте новый PIN. Несохранённые данные на экране будут потеряны; корзина сохранится'**
  String get unlock_reset_body;

  /// Экран: SCR-08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Войти по SMS'**
  String get unlock_reset_confirm;

  /// Экран: SCR-08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сбросить PIN?'**
  String get unlock_reset_title;

  /// Экран: SCR-08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Войти по SMS'**
  String get unlock_sms_login;

  /// Экран: SCR-08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сменить аккаунт'**
  String get unlock_switch_account;

  /// Экран: SCR-08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Текущий пользователь выйдет на этом устройстве. Корзина сохранится на сервере'**
  String get unlock_switch_body;

  /// Экран: SCR-08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сменить'**
  String get unlock_switch_confirm;

  /// Экран: SCR-08. ч. A. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Сменить аккаунт?'**
  String get unlock_switch_title;

  /// Экран: SCR-15. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Добавить в корзину · {sum}'**
  String variant_add_cta(String sum);

  /// Экран: SCR-15. ч. B; ICU. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Добавлено {count} позиции / позиций'**
  String variant_added_snackbar(int count);

  /// Экран: SCR-15. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет в наличии на складе корзины'**
  String get variant_all_out_hint;

  /// Экран: SCR-15. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Не удалось загрузить варианты · Повторить'**
  String get variant_load_error;

  /// Экран: SCR-15. ч. B; CART-005. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вариант уже в корзине. Объединить количества?'**
  String get variant_merge_confirm;

  /// Экран: SCR-15. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'{axis}'**
  String variant_mode_axis(String axis);

  /// Экран: SCR-15. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Все варианты списком'**
  String get variant_mode_list;

  /// Экран: SCR-15. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Нет'**
  String get variant_out_of_stock;

  /// Экран: SCR-15. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Добавлено {added} из {total}. «{name}» больше не продаётся'**
  String variant_partial_added(String added, String name, String total);

  /// Экран: SCR-15. ч. B; CART-005. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Заменить вариант'**
  String get variant_replace_cta;

  /// Экран: SCR-15. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Вариант не найден'**
  String get variant_search_empty;

  /// Экран: SCR-15. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Найти по артикулу'**
  String get variant_search_placeholder;

  /// Экран: SCR-15. ч. B. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выберите вариант'**
  String get variant_select_error;

  /// Экран: SCR-15. ч. B; ICU. Источник: 02 §7
  ///
  /// In ru, this message translates to:
  /// **'Выбрано: {count} вариантов · {qty} {unit}'**
  String variant_selected_summary(int count, String qty, String unit);

  /// Экран: SCR-15. ч. B; ICU. Источник: 02 §7; формы «a / b / c» 02 §7 преобразованы в ICU plural (03 §16.3)
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{{count} вариант · ось: {axis}} few{{count} варианта · ось: {axis}} many{{count} вариантов · ось: {axis}} other{{count} варианта · ось: {axis}}}'**
  String variant_sheet_count(String axis, int count);

  /// Общий ключ (владелец 03, ядро §18.1/§19.1). Источник: 03 §16.3
  ///
  /// In ru, this message translates to:
  /// **'{count, plural, one{{count} вариант} few{{count} варианта} many{{count} вариантов} other{{count} варианта}}'**
  String variants_count(int count);
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['en', 'ky', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ky':
      return AppLocalizationsKy();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
