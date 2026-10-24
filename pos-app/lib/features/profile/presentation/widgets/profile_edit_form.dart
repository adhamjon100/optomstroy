// Форма «Изменить данные» SCR-41 (02 UI-41-009, SCR-41.4, SCR-41.8; 08 §4.3.2 `PATCH /me/profile`): ФИО
// (обязательно, 2…150), год рождения (1920…текущий − 14), сфера деятельности (≤ 64); телефон — только чтение.
// «Сохранить» активна при изменениях и валидных полях; повторное нажатие во время запроса игнорируется; `409
// VERSION_CONFLICT` — поля перезаполняются значениями сервера и показывается `profile_conflict`.
// ПДн — только память (в лог и на диск не пишутся).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/profile/domain/entities/user_profile.dart';
import 'package:optomstroy/features/profile/domain/repositories/profile_repository.dart';
import 'package:uuid/uuid.dart';

/// Проверки полей профиля (02 SCR-41.8).
abstract final class ProfileValidation {
  static final RegExp _name = RegExp(r"^[\p{L}\s\-'’]+$", unicode: true);

  /// Ошибка ФИО: `required` / `length` / `null`.
  static String? fullName(AppLocalizations l10n, String v) {
    final String t = v.trim();
    if (t.isEmpty) return l10n.profile_fullname_error_required;
    if (t.length < 2 || t.length > ProfilePatch.fullNameMax || !_name.hasMatch(t)) {
      return l10n.profile_fullname_error_length;
    }
    return null;
  }

  /// Ошибка года рождения (необязательный, 1920…[nowYear] − 14).
  static String? birthYear(AppLocalizations l10n, String v, int nowYear) {
    final String t = v.trim();
    if (t.isEmpty) return null;
    final int? y = int.tryParse(t);
    final int max = nowYear - 14;
    if (y == null || y < ProfilePatch.birthYearMin || y > max) return l10n.profile_birthyear_error_range('$max');
    return null;
  }
}

/// Форма редактирования профиля; закрывается с обновлёнными данными (`ProfileData`) после `200`.
class ProfileEditForm extends StatefulWidget {
  const ProfileEditForm({required this.profile, required this.repository, required this.nowYear, super.key});

  /// Ключи для тестов.
  static const Key nameKey = ValueKey<String>('profile-edit-name');
  static const Key yearKey = ValueKey<String>('profile-edit-year');
  static const Key activityKey = ValueKey<String>('profile-edit-activity');
  static const Key saveKey = ValueKey<String>('profile-edit-save');
  static const Key conflictKey = ValueKey<String>('profile-edit-conflict');

  final ProfileData profile;
  final ProfileRepository repository;
  final int nowYear;

  @override
  State<ProfileEditForm> createState() => _ProfileEditFormState();
}

class _ProfileEditFormState extends State<ProfileEditForm> {
  late ProfileData _base = widget.profile;
  late final TextEditingController _name = TextEditingController(text: _base.fullName ?? '');
  late final TextEditingController _year = TextEditingController(text: _base.birthYear?.toString() ?? '');
  late final TextEditingController _activity = TextEditingController(text: _base.activitySphere ?? '');
  bool _saving = false;
  bool _conflict = false;
  String? _error;
  final String _key = const Uuid().v4();

  @override
  void dispose() {
    _name.dispose();
    _year.dispose();
    _activity.dispose();
    super.dispose();
  }

  bool get _changed =>
      _name.text.trim() != (_base.fullName ?? '') ||
      _year.text.trim() != (_base.birthYear?.toString() ?? '') ||
      _activity.text.trim() != (_base.activitySphere ?? '');

  Future<void> _save() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    if (_saving || !_changed) return;
    if (ProfileValidation.fullName(l10n, _name.text) != null ||
        ProfileValidation.birthYear(l10n, _year.text, widget.nowYear) != null) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final String activity = _activity.text.trim();
    final Result<ProfileData> r = await widget.repository.update(
      ProfilePatch(
        rowVersion: _base.rowVersion ?? 0,
        fullName: _name.text.trim() == (_base.fullName ?? '') ? null : _name.text.trim(),
        birthYear: int.tryParse(_year.text.trim()),
        activitySphere: activity.isEmpty ? null : activity,
        clearActivitySphere: activity.isEmpty && (_base.activitySphere ?? '').isNotEmpty,
      ),
      idempotencyKey: _key,
    );
    if (!mounted) return;
    switch (r) {
      case Success<ProfileData>(:final value):
        Navigator.of(context).pop(value);
      case FailureResult<ProfileData>(:final failure):
        final Map<String, Object?> current = failure is ConflictFailure && failure.kind == ConflictKind.versionConflict
            ? (failure.details['current'] is Map
                  ? (failure.details['current']! as Map).cast<String, Object?>()
                  : const <String, Object?>{})
            : const <String, Object?>{};
        setState(() {
          _saving = false;
          if (failure is ConflictFailure && failure.kind == ConflictKind.versionConflict) {
            _conflict = true;
            _base = ProfileData(
              fullName: current['fullName'] as String? ?? _base.fullName,
              birthYear: current['birthYear'] as int? ?? _base.birthYear,
              activitySphere: current['activitySphere'] as String? ?? _base.activitySphere,
              phoneE164: _base.phoneE164,
              rowVersion: current['rowVersion'] as int? ?? _base.rowVersion,
            );
            _name.text = _base.fullName ?? '';
            _year.text = _base.birthYear?.toString() ?? '';
            _activity.text = _base.activitySphere ?? '';
          } else {
            _error = ErrorTexts.message(l10n, UiErrorMapper.fromFailure(failure));
          }
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String? nameError = _name.text.isEmpty && !_changed ? null : ProfileValidation.fullName(l10n, _name.text);
    final String? yearError = ProfileValidation.birthYear(l10n, _year.text, widget.nowYear);
    final bool canSave = _changed && nameError == null && yearError == null && !_saving;
    final SizedBox gap = SizedBox(height: context.space.s4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (_conflict)
          Padding(
            key: ProfileEditForm.conflictKey,
            padding: EdgeInsets.only(bottom: context.space.s3),
            child: ErrorState.banner(message: l10n.profile_conflict, tone: ErrorStateTone.warning),
          ),
        if (_error != null)
          Padding(
            padding: EdgeInsets.only(bottom: context.space.s3),
            child: ErrorState.inline(message: _error!, onRetry: () => unawaited(_save())),
          ),
        AppTextField(
          key: ProfileEditForm.nameKey,
          controller: _name,
          label: l10n.profile_fullname_label,
          errorText: nameError,
          maxLength: ProfilePatch.fullNameMax,
          onChanged: (_) => setState(() {}),
        ),
        gap,
        AppTextField(
          key: ProfileEditForm.yearKey,
          controller: _year,
          label: l10n.profile_birthyear_label,
          errorText: yearError,
          keyboardType: TextInputType.number,
          maxLength: 4,
          onChanged: (_) => setState(() {}),
        ),
        gap,
        AppTextField(
          key: ProfileEditForm.activityKey,
          controller: _activity,
          label: l10n.profile_activity_label,
          hint: l10n.profile_activity_hint,
          maxLength: ProfilePatch.activitySphereMax,
          textInputAction: TextInputAction.done,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => unawaited(_save()),
        ),
        SizedBox(height: context.space.s5),
        AppButton(
          key: ProfileEditForm.saveKey,
          // Ключа «Сохранить» в словаре нет (GQ-FEADM-06) — «Применить».
          label: l10n.ds_button_apply,
          size: AppButtonSize.l,
          expand: true,
          loading: _saving,
          onPressed: canSave ? () => unawaited(_save()) : null,
        ),
      ],
    );
  }
}
