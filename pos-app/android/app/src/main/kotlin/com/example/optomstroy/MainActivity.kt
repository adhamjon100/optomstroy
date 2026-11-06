package com.example.optomstroy

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// FlutterFragmentActivity — требование local_auth и BiometricPrompt (09 §9.2, T-BIO-018).
class MainActivity : FlutterFragmentActivity() {
    private var biometricCrypto: BiometricCryptoChannel? = null

    // Закрепление планшета магазина (Device Owner, lock task; 13 TAB-2-09, ADR-115 п. 29). На устройствах без
    // Device Owner канал только сообщает состояние — поведение приложения сотрудников не меняется.
    private var kioskLock: KioskLockChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        biometricCrypto = BiometricCryptoChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        kioskLock = KioskLockChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        biometricCrypto?.dispose()
        biometricCrypto = null
        kioskLock?.dispose()
        kioskLock = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
