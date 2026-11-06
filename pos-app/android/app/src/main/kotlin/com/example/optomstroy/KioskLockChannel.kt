package com.example.optomstroy

// Закрепление планшета магазина (P-002 §8.10; 16 §10.10 «Ограничения на планшете»; ADR-115 п. 26, п. 29; 13 TAB-2-09).
//
// Приложение — владелец устройства (Device Owner): `adb shell dpm set-device-owner
// com.example.optomstroy/.KioskDeviceAdminReceiver` на сброшенном планшете без аккаунтов (16 §10.10 шаг 4). Канал:
//   status                → снимок состояния;
//   enable  {userRestrictions, lockTaskFeatures, statusBarDisabled, keyguardDisabled}
//                         → setLockTaskPackages(своё приложение), setLockTaskFeatures, addUserRestriction (только
//                           ключи KNOWN_RESTRICTIONS), setStatusBarDisabled, setKeyguardDisabled, activity-alias «Домой»
//                           + addPersistentPreferredActivity, startLockTask → снимок;
//   disable               → stopLockTask, setLockTaskPackages(пусто), функции lock task по умолчанию, clearUserRestriction
//                           для ВСЕХ ключей KNOWN_RESTRICTIONS, шторка и экран блокировки, «Домой» снят → снимок.
// Набор ограничений задаёт Dart (`kioskLockPolicy`, lib/core/hardware/kiosk_lock.dart) — одна константа, которую
// проверяет тест. Каждый шаг выполняется отдельно: сбой одного шага не оставляет остальные невыполненными (снятие
// закрепления не должно «запирать» планшет), снимок показывает итог, `error: failed` — был сбой.
// Без Device Owner enable ничего не включает (`error: not_device_owner`): закрепление экрана с подтверждением
// пользователя — не наш вариант (P-002 §8.10, «Минимум» — только по решению заказчика).
// Device Owner при disable НЕ снимается: обновление APK и подключение заново идут с тем же владельцем (16 §10.10).
// Персональных данных канал не получает и ничего не логирует.

import android.annotation.SuppressLint
import android.app.Activity
import android.app.ActivityManager
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.UserManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class KioskLockChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "kg.optomstroy/kiosk_lock"

        // activity-alias «Домой» (AndroidManifest.xml, android:enabled="false"): включается только enable.
        private const val HOME_ALIAS = "com.example.optomstroy.KioskHomeAlias"

        // Ограничения, которые канал умеет включать и снимать: ключ UserManager → минимальный API.
        @SuppressLint("InlinedApi")
        private val KNOWN_RESTRICTIONS: Map<String, Int> = linkedMapOf(
            UserManager.DISALLOW_SAFE_BOOT to Build.VERSION_CODES.M,
            UserManager.DISALLOW_FACTORY_RESET to Build.VERSION_CODES.LOLLIPOP,
            UserManager.DISALLOW_DEBUGGING_FEATURES to Build.VERSION_CODES.LOLLIPOP,
            UserManager.DISALLOW_INSTALL_APPS to Build.VERSION_CODES.LOLLIPOP,
            UserManager.DISALLOW_AUTOFILL to Build.VERSION_CODES.O,
        )

        // Функции lock task (API 28+): имя протокола → флаг. Не перечисленные в политике — выключены.
        @SuppressLint("InlinedApi")
        private val LOCK_TASK_FEATURES: Map<String, Int> = linkedMapOf(
            "system_info" to DevicePolicyManager.LOCK_TASK_FEATURE_SYSTEM_INFO,
            "notifications" to DevicePolicyManager.LOCK_TASK_FEATURE_NOTIFICATIONS,
            "home" to DevicePolicyManager.LOCK_TASK_FEATURE_HOME,
            "overview" to DevicePolicyManager.LOCK_TASK_FEATURE_OVERVIEW,
            "global_actions" to DevicePolicyManager.LOCK_TASK_FEATURE_GLOBAL_ACTIONS,
            "keyguard" to DevicePolicyManager.LOCK_TASK_FEATURE_KEYGUARD,
        )

        // Значение Android по умолчанию — только меню питания (developer.android.com, setLockTaskFeatures).
        @SuppressLint("InlinedApi")
        private const val DEFAULT_LOCK_TASK_FEATURES = DevicePolicyManager.LOCK_TASK_FEATURE_GLOBAL_ACTIONS
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val dpm = activity.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
    private val admin = ComponentName(activity, KioskDeviceAdminReceiver::class.java)
    private val homeAlias = ComponentName(activity.packageName, HOME_ALIAS)

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(snapshot(null))
            "enable" -> result.success(enable(call))
            "disable" -> result.success(disable())
            else -> result.notImplemented()
        }
    }

    // --- enable ---

    private fun enable(call: MethodCall): Map<String, Any?> {
        if (!isDeviceOwner()) return snapshot("not_device_owner")
        val restrictions = call.argument<List<String>>("userRestrictions") ?: emptyList()
        val features = call.argument<List<String>>("lockTaskFeatures") ?: emptyList()
        val statusBarDisabled = call.argument<Boolean>("statusBarDisabled") ?: true
        val keyguardDisabled = call.argument<Boolean>("keyguardDisabled") ?: true
        // Неизвестные ключи не применяются; неизвестная функция lock task видна в снимке как несовпадение функций.
        val rejected = restrictions.filterNot(KNOWN_RESTRICTIONS::containsKey)
        var ok = true
        ok = step { dpm.setLockTaskPackages(admin, arrayOf(activity.packageName)) } && ok
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            ok = step { dpm.setLockTaskFeatures(admin, featureMask(features)) } && ok
        }
        for (key in restrictions) {
            val minApi = KNOWN_RESTRICTIONS[key] ?: continue // чужой ключ не применяется (rejectedRestrictions)
            if (Build.VERSION.SDK_INT >= minApi) ok = step { dpm.addUserRestriction(admin, key) } && ok
        }
        ok = step { dpm.setStatusBarDisabled(admin, statusBarDisabled) } && ok
        // false — на устройстве задан PIN/пароль экрана блокировки: состояние не ошибка, планшет готовят без него.
        ok = step { dpm.setKeyguardDisabled(admin, keyguardDisabled) } && ok
        ok = step { setHomeApp(true) } && ok
        if (lockTaskState() == ActivityManager.LOCK_TASK_MODE_NONE) {
            ok = step { activity.startLockTask() } && ok
        }
        return snapshot(if (ok) null else "failed", rejected)
    }

    // --- disable ---

    private fun disable(): Map<String, Any?> {
        var ok = true
        if (lockTaskState() != ActivityManager.LOCK_TASK_MODE_NONE) {
            ok = step { activity.stopLockTask() } && ok
        }
        // Не владелец устройства — своих ограничений нет, снимать нечего (не ошибка: отзыв планшета без закрепления).
        if (!isDeviceOwner()) return snapshot(if (ok) null else "failed")
        // Пустой список — система сама выводит приложение из lock task, даже если stopLockTask не удался.
        ok = step { dpm.setLockTaskPackages(admin, emptyArray()) } && ok
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            ok = step { dpm.setLockTaskFeatures(admin, DEFAULT_LOCK_TASK_FEATURES) } && ok
        }
        for ((key, minApi) in KNOWN_RESTRICTIONS) {
            if (Build.VERSION.SDK_INT >= minApi) ok = step { dpm.clearUserRestriction(admin, key) } && ok
        }
        ok = step { dpm.setStatusBarDisabled(admin, false) } && ok
        ok = step { dpm.setKeyguardDisabled(admin, false) } && ok
        ok = step { setHomeApp(false) } && ok
        return snapshot(if (ok) null else "failed")
    }

    // --- приложение «Домой» ---

    private fun setHomeApp(enabled: Boolean) {
        val pm = activity.packageManager
        if (enabled) {
            pm.setComponentEnabledSetting(
                homeAlias,
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP,
            )
            val home = IntentFilter(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_HOME)
                addCategory(Intent.CATEGORY_DEFAULT)
            }
            dpm.addPersistentPreferredActivity(admin, home, homeAlias)
        } else {
            dpm.clearPackagePersistentPreferredActivities(admin, activity.packageName)
            // DEFAULT — значение манифеста: alias выключен (телефоны и ПК сотрудников «Домой» не получают).
            pm.setComponentEnabledSetting(
                homeAlias,
                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT,
                PackageManager.DONT_KILL_APP,
            )
        }
    }

    // --- снимок ---

    private fun snapshot(error: String?, rejected: List<String> = emptyList()): Map<String, Any?> {
        val deviceOwner = isDeviceOwner()
        val effective = (activity.getSystemService(Context.USER_SERVICE) as UserManager).userRestrictions
        val active = mutableListOf<String>()
        val unsupported = mutableListOf<String>()
        for ((key, minApi) in KNOWN_RESTRICTIONS) {
            if (Build.VERSION.SDK_INT < minApi) unsupported += key
            else if (effective.getBoolean(key, false)) active += key
        }
        var features: List<String>? = null
        if (deviceOwner && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            features = try {
                val mask = dpm.getLockTaskFeatures(admin)
                LOCK_TASK_FEATURES.filterValues { flag -> (mask and flag) != 0 }.keys.toList()
            } catch (e: RuntimeException) {
                null
            }
        }
        return mapOf(
            "supported" to true,
            "deviceOwner" to deviceOwner,
            "lockTaskActive" to (lockTaskState() == ActivityManager.LOCK_TASK_MODE_LOCKED),
            "homeApp" to isHomeAppEnabled(),
            "activeRestrictions" to active,
            "unsupportedRestrictions" to unsupported,
            "rejectedRestrictions" to rejected,
            "lockTaskFeatures" to features,
            "error" to error,
        )
    }

    private fun isDeviceOwner(): Boolean = dpm.isDeviceOwnerApp(activity.packageName)

    private fun isHomeAppEnabled(): Boolean =
        activity.packageManager.getComponentEnabledSetting(homeAlias) ==
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED

    private fun lockTaskState(): Int =
        (activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).lockTaskModeState

    private fun featureMask(names: List<String>): Int =
        names.fold(DevicePolicyManager.LOCK_TASK_FEATURE_NONE) { mask, name -> mask or (LOCK_TASK_FEATURES[name] ?: 0) }

    // Шаг команды: true — выполнен; исключение Android не прерывает остальные шаги.
    private inline fun step(action: () -> Unit): Boolean =
        try {
            action()
            true
        } catch (e: RuntimeException) {
            false
        }
}
