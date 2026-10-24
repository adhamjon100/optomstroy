package com.example.optomstroy

// Криптопривязка `biometric_refresh` к системной биометрии (D-13; 09 §9.2; ADR-013 и уточнение этапа D).
//
// Ключ AES-256-GCM в AndroidKeyStore:
//   setUserAuthenticationRequired(true) + setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG) —
//   авторизация на КАЖДУЮ операцию, без окна валидности, только сильная биометрия (Class 3);
//   setInvalidatedByBiometricEnrollment(true) — новый отпечаток/лицо делает ключ недействительным
//   (KeyPermanentlyInvalidatedException → сигнал `invalidated`, ключ и шифртекст удаляются).
// Шифрование и расшифровка выполняются только в onAuthenticationSucceeded с CryptoObject(cipher) от
// BiometricPrompt (BIOMETRIC_STRONG): подмена колбэка без реальной биометрии не даёт рабочего Cipher
// (MASTG-TEST-0018). Шифртекст и IV — в приватных SharedPreferences (без ключа бесполезны; allowBackup=false).
// API < 30: биометрический вход не предлагается (09 §9.4: API 28–29 — только после проверки на устройстве).
// Биометрических данных приложение не получает; секрет и PIN не логируются.

import android.app.Activity
import android.content.Context
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.Base64
import android.view.WindowManager
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.InvalidAlgorithmParameterException
import java.security.KeyStore
import java.security.UnrecoverableKeyException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class BiometricCryptoChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "kg.optomstroy/biometric_crypto"
        private const val KEY_ALIAS = "optomstroy.biometric_refresh.v1"
        private const val PREFS = "optomstroy_biometric_crypto"
        private const val PREF_CIPHERTEXT = "ct"
        private const val PREF_IV = "iv"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private var inFlight: CancellationSignal? = null

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        inFlight?.cancel()
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capability" -> result.success(capability())
            "has" -> result.success(hasCiphertext())
            "clear" -> {
                clearAll()
                result.success(null)
            }
            "store" -> {
                val secret = call.argument<String>("secret") // check-secrets: allow — имя поля/заголовка, не секрет
                if (secret.isNullOrEmpty()) {
                    result.success(failure("failed"))
                } else {
                    store(secret, prompt(call), result)
                }
            }
            "read" -> read(prompt(call), result)
            // AU-07 (02 SCR-08.4 п. 3; 09 §9.2): новый `biometric_refresh` шифруется ТЕМ ЖЕ ключом — без нового ключа
            // и без удаления прежнего; ключ требует BiometricPrompt на каждую операцию, поэтому диалог остаётся.
            "replace" -> {
                val secret = call.argument<String>("secret") // check-secrets: allow — имя поля/заголовка, не секрет
                if (secret.isNullOrEmpty()) {
                    result.success(failure("failed"))
                } else {
                    replace(secret, prompt(call), result)
                }
            }
            // AU-16 (02 SCR-02.4, SCR-08; Q-181): экраны OTP/PIN — без скриншотов, записи экрана и миниатюры
            // в переключателе приложений. Флаг снимается, когда закрыт последний такой экран.
            "secureScreen" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                activity.runOnUiThread { setSecureWindow(enabled) }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // --- secureScreen: FLAG_SECURE окна приложения ---

    private fun setSecureWindow(enabled: Boolean) {
        if (enabled) {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    // --- capability ---

    private fun capability(): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return mapOf(
                "kind" to "none",
                "availability" to "unsupported",
                "cryptoBinding" to false,
                "reason" to "api_level",
            )
        }
        return capabilityApi30()
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun capabilityApi30(): Map<String, Any?> {
        val manager = activity.getSystemService(BiometricManager::class.java)
        val code = manager?.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            ?: BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE
        val (availability, reason) = when (code) {
            BiometricManager.BIOMETRIC_SUCCESS -> "available" to null
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "not_enrolled" to "not_enrolled"
            BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> "unsupported" to "hw_unavailable"
            BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> "unsupported" to "no_hardware_or_weak_only"
            else -> "unsupported" to "security_update_required"
        }
        return mapOf(
            "kind" to "android_class3",
            "availability" to availability,
            "cryptoBinding" to true,
            "reason" to reason,
        )
    }

    // --- store: новый ключ → BiometricPrompt(CryptoObject) → шифрование ---

    private fun store(secret: String, texts: PromptTexts, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.success(failure("not_available"))
            return
        }
        clearAll()
        val cipher = try {
            val key = createKey()
            Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, key) }
        } catch (e: InvalidAlgorithmParameterException) {
            // Нет зарегистрированной сильной биометрии: ключ с обязательной аутентификацией не создаётся.
            clearAll()
            result.success(failure("not_enrolled"))
            return
        } catch (e: KeyPermanentlyInvalidatedException) {
            clearAll()
            result.success(failure("invalidated"))
            return
        } catch (e: Exception) {
            clearAll()
            result.success(failure("failed"))
            return
        }
        authenticate(cipher, texts, result) { authorized ->
            val ciphertext = authorized.doFinal(secret.toByteArray(Charsets.UTF_8))
            prefs().edit()
                .putString(PREF_CIPHERTEXT, Base64.encodeToString(ciphertext, Base64.NO_WRAP))
                .putString(PREF_IV, Base64.encodeToString(authorized.iv, Base64.NO_WRAP))
                .apply()
            mapOf("ok" to true)
        }
    }

    // --- replace: существующий ключ → BiometricPrompt(CryptoObject) → шифрование нового секрета ---

    private fun replace(secret: String, texts: PromptTexts, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.success(failure("not_available"))
            return
        }
        if (!hasCiphertext()) {
            result.success(failure("no_credential"))
            return
        }
        val cipher = try {
            val key = loadKey()
            if (key == null) {
                clearAll()
                result.success(failure("invalidated"))
                return
            }
            Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, key) }
        } catch (e: KeyPermanentlyInvalidatedException) {
            clearAll()
            result.success(failure("invalidated"))
            return
        } catch (e: UnrecoverableKeyException) {
            clearAll()
            result.success(failure("invalidated"))
            return
        } catch (e: Exception) {
            result.success(failure("failed"))
            return
        }
        authenticate(cipher, texts, result) { authorized ->
            val ciphertext = authorized.doFinal(secret.toByteArray(Charsets.UTF_8))
            prefs().edit()
                .putString(PREF_CIPHERTEXT, Base64.encodeToString(ciphertext, Base64.NO_WRAP))
                .putString(PREF_IV, Base64.encodeToString(authorized.iv, Base64.NO_WRAP))
                .apply()
            mapOf("ok" to true)
        }
    }

    // --- read: BiometricPrompt(CryptoObject) → расшифровка ---

    private fun read(texts: PromptTexts, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.success(failure("not_available"))
            return
        }
        val stored = prefs()
        val ct = stored.getString(PREF_CIPHERTEXT, null)
        val iv = stored.getString(PREF_IV, null)
        if (ct == null || iv == null) {
            result.success(failure("no_credential"))
            return
        }
        val cipher = try {
            val key = loadKey()
            if (key == null) {
                // Шифртекст без ключа: ключ удалён системой (смена биометрии / сброс блокировки экрана).
                clearAll()
                result.success(failure("invalidated"))
                return
            }
            Cipher.getInstance(TRANSFORMATION).apply {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, Base64.decode(iv, Base64.NO_WRAP)))
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
            clearAll()
            result.success(failure("invalidated"))
            return
        } catch (e: UnrecoverableKeyException) {
            clearAll()
            result.success(failure("invalidated"))
            return
        } catch (e: Exception) {
            result.success(failure("failed"))
            return
        }
        authenticate(cipher, texts, result) { authorized ->
            val plain = authorized.doFinal(Base64.decode(ct, Base64.NO_WRAP))
            mapOf("ok" to true, "value" to String(plain, Charsets.UTF_8))
        }
    }

    // --- BiometricPrompt (framework, API 30: setAllowedAuthenticators) ---

    private fun authenticate(
        cipher: Cipher,
        texts: PromptTexts,
        result: MethodChannel.Result,
        onAuthorized: (Cipher) -> Map<String, Any?>,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.success(failure("not_available"))
            return
        }
        inFlight?.cancel()
        val signal = CancellationSignal()
        inFlight = signal
        var replied = false
        fun reply(value: Map<String, Any?>) {
            if (replied) return
            replied = true
            if (inFlight === signal) inFlight = null
            result.success(value)
        }

        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(res: BiometricPrompt.AuthenticationResult) {
                val authorized = res.cryptoObject?.cipher
                if (authorized == null) {
                    reply(failure("failed"))
                    return
                }
                try {
                    reply(onAuthorized(authorized))
                } catch (e: KeyPermanentlyInvalidatedException) {
                    clearAll()
                    reply(failure("invalidated"))
                } catch (e: Exception) {
                    reply(failure("failed"))
                }
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                reply(failure(mapPromptError(errorCode)))
            }

            // onAuthenticationFailed: неудачное касание — диалог остаётся открытым, ответа нет.
        }

        try {
            val builder = BiometricPrompt.Builder(activity)
                .setTitle(texts.title)
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                .setConfirmationRequired(false)
                .setNegativeButton(texts.cancel, activity.mainExecutor) { _, _ ->
                    reply(failure("cancelled"))
                }
            texts.subtitle?.let { builder.setSubtitle(it) }
            builder.build().authenticate(
                BiometricPrompt.CryptoObject(cipher),
                signal,
                activity.mainExecutor,
                callback,
            )
        } catch (e: Exception) {
            reply(failure("failed"))
        }
    }

    private fun mapPromptError(code: Int): String = when (code) {
        BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED,
        BiometricPrompt.BIOMETRIC_ERROR_CANCELED,
        BiometricPrompt.BIOMETRIC_ERROR_TIMEOUT -> "cancelled"
        BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT,
        BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT_PERMANENT -> "lockout"
        BiometricPrompt.BIOMETRIC_ERROR_NO_BIOMETRICS -> "not_enrolled"
        BiometricPrompt.BIOMETRIC_ERROR_HW_NOT_PRESENT,
        BiometricPrompt.BIOMETRIC_ERROR_HW_UNAVAILABLE -> "not_available"
        else -> "failed"
    }

    // --- ключ ---

    @RequiresApi(Build.VERSION_CODES.R)
    private fun createKey(): SecretKey {
        deleteKey()
        return try {
            generateKey(strongBox = activity.packageManager.hasSystemFeature("android.hardware.strongbox_keystore"))
        } catch (e: StrongBoxUnavailableException) {
            generateKey(strongBox = false)
        }
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun generateKey(strongBox: Boolean): SecretKey {
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            // 0 секунд = авторизация на каждую операцию (без окна валидности), только BIOMETRIC_STRONG.
            .setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
            .setInvalidatedByBiometricEnrollment(true)
            .setIsStrongBoxBacked(strongBox)
            .build()
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(spec)
        return generator.generateKey()
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    private fun loadKey(): SecretKey? = keyStore().getKey(KEY_ALIAS, null) as SecretKey?

    private fun deleteKey() {
        try {
            val ks = keyStore()
            if (ks.containsAlias(KEY_ALIAS)) ks.deleteEntry(KEY_ALIAS)
        } catch (e: Exception) {
            // Хранилище ключей недоступно — удалять нечего.
        }
    }

    // --- шифртекст ---

    private fun prefs() = activity.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun hasCiphertext(): Boolean = prefs().contains(PREF_CIPHERTEXT)

    private fun clearAll() {
        prefs().edit().clear().apply()
        deleteKey()
    }

    private fun failure(code: String): Map<String, Any?> = mapOf("ok" to false, "error" to code)

    private data class PromptTexts(val title: String, val subtitle: String?, val cancel: String)

    private fun prompt(call: MethodCall) = PromptTexts(
        title = call.argument<String>("title").orEmpty().ifEmpty { " " },
        subtitle = call.argument<String>("subtitle"),
        cancel = call.argument<String>("cancel").orEmpty().ifEmpty { " " },
    )
}
