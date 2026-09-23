// station_native.dart
//
// Native hooks on channel "qash/station" while a station is active:
// - Android (MainActivity.kt): keep the screen on + a foreground service so
//   the poll timers keep running when the cashier switches apps.
// - iOS (AppDelegate.swift): keep the screen on only. iOS has no foreground
//   service equivalent, so the station must stay in front.
// No-ops elsewhere.

import 'dart:io';
import 'package:flutter/services.dart';

class StationNative {
  static const _ch = MethodChannel('qash/station');

  static Future<void> start(String stationLabel) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await _ch.invokeMethod('keepScreenOn', true);
    if (Platform.isAndroid) await _ch.invokeMethod('startForeground', stationLabel);
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await _ch.invokeMethod('keepScreenOn', false);
    if (Platform.isAndroid) await _ch.invokeMethod('stopForeground');
  }
}
