// station_native.dart
//
// Android-only hooks (MainActivity.kt, channel "qash/station"): keep the
// screen on and hold a foreground service while a station is active so the
// poll timers keep running when the cashier switches apps. No-ops elsewhere.

import 'dart:io';
import 'package:flutter/services.dart';

class StationNative {
  static const _ch = MethodChannel('qash/station');

  static Future<void> start(String stationLabel) async {
    if (!Platform.isAndroid) return;
    await _ch.invokeMethod('keepScreenOn', true);
    await _ch.invokeMethod('startForeground', stationLabel);
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    await _ch.invokeMethod('keepScreenOn', false);
    await _ch.invokeMethod('stopForeground');
  }
}
