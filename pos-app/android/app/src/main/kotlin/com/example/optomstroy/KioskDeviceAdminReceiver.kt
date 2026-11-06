package com.example.optomstroy

// Приёмник администратора устройства — компонент владельца устройства (Device Owner) планшета магазина
// (P-002 §8.10; 16 §10.10 шаг 4: `adb shell dpm set-device-owner com.example.optomstroy/.KioskDeviceAdminReceiver`;
// 13 TAB-2-09). Своих действий у приёмника нет: закрепление включает и снимает `KioskLockChannel` по командам
// приложения (подключение, отзыв, аварийный выход). Политики — res/xml/device_admin.xml (пустой список).

import android.app.admin.DeviceAdminReceiver

class KioskDeviceAdminReceiver : DeviceAdminReceiver()
