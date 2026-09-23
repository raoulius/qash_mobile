// permissions.dart
//
// Centralizes all Bluetooth-related runtime permission requests.
//
// Android 12 (API 31) split the old single "Bluetooth" permission into
// BLUETOOTH_SCAN and BLUETOOTH_CONNECT, both requested at *runtime* (not
// just declared in the manifest). Below API 31, scanning for Bluetooth
// devices required ACCESS_FINE_LOCATION instead — an old, easy-to-forget
// quirk that still bites on devices stuck on older Android versions.
//
// iOS handles this differently: there's no "request permission" call at
// all. Bluetooth usage strings (NSBluetoothAlwaysUsageDescription, etc.)
// must be declared in Info.plist, and iOS shows its own system prompt the
// first time any Bluetooth API is touched. This file's iOS path is mostly
// a no-op that exists so callers don't need platform-specific branching.

import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

class BluetoothPermissionResult {
  final bool granted;
  final String? reason; // human-readable reason when granted == false

  const BluetoothPermissionResult(this.granted, [this.reason]);
}

class BluetoothPermissions {
  /// Call this before any scan/connect attempt. Safe to call repeatedly —
  /// if everything is already granted it resolves immediately without
  /// showing any prompts.
  static Future<BluetoothPermissionResult> ensureGranted() async {
    if (Platform.isIOS) {
      // No runtime request API on iOS. As long as Info.plist has the usage
      // strings (see ios/Runner/Info.plist), the system handles prompting
      // automatically the first time CoreBluetooth/ExternalAccessory is used.
      return const BluetoothPermissionResult(true);
    }

    if (Platform.isAndroid) {
      return _ensureAndroidGranted();
    }

    // Other platforms (web, desktop) aren't part of this app's target set.
    return const BluetoothPermissionResult(
      false,
      'Platform ini tidak mendukung printer Bluetooth',
    );
  }

  /// Checks without prompting — for re-checking when the cashier comes back
  /// from system Settings (the prompt itself pauses/resumes the app, so
  /// prompting on resume would loop).
  static Future<bool> isGranted() async {
    if (!Platform.isAndroid) return Platform.isIOS;
    for (final p in await _androidRequired()) {
      if (!await p.isGranted) return false;
    }
    return true;
  }

  static Future<List<Permission>> _androidRequired() async {
    if (await _androidSdkInt() >= 31) {
      // Android 12+: explicit scan/connect permissions.
      return [Permission.bluetoothScan, Permission.bluetoothConnect];
    }
    // Android < 12: scanning needs location; legacy bluetooth/bluetoothAdmin
    // are install-time (manifest-only) on these versions, no runtime prompt
    // needed for them.
    return [Permission.locationWhenInUse];
  }

  static Future<BluetoothPermissionResult> _ensureAndroidGranted() async {
    final statuses = await (await _androidRequired()).request();

    final allGranted = statuses.values.every((s) => s.isGranted);
    if (allGranted) return const BluetoothPermissionResult(true);

    final anyPermanentlyDenied =
        statuses.values.any((s) => s.isPermanentlyDenied);

    return BluetoothPermissionResult(
      false,
      anyPermanentlyDenied
          ? 'Izin Bluetooth ditolak. Aktifkan di Pengaturan agar printer bisa dipakai.'
          : 'Izin Bluetooth diperlukan untuk mencari printer.',
    );
  }

  /// Reads the Android SDK (API) level. Falls back to assuming 31+ (the
  /// stricter path) if it can't be determined, since that's the safer
  /// default — it just means asking for two permissions instead of one.
  static Future<int> _androidSdkInt() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.version.sdkInt;
    } catch (_) {
      return 31;
    }
  }
}