package com.example.optomstroy

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// FlutterFragmentActivity — требование local_auth и BiometricPrompt (09 §9.2, T-BIO-018).
class MainActivity : FlutterFragmentActivity() {
    private var biometricCrypto: BiometricCryptoChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        biometricCrypto = BiometricCryptoChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        biometricCrypto?.dispose()
        biometricCrypto = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
