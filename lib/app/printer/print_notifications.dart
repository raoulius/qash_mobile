// print_notifications.dart
//
// Fires the OS notification ("Struk tercetak") when a print job succeeds.
// Separate from the in-app printing overlay (printing_overlay.dart) — this
// one should land even if the cashier has swiped the app to the background.

import 'dart:ui' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class PrintNotifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _channel = AndroidNotificationDetails(
    'print_jobs',
    'Cetak struk',
    channelDescription: 'Pemberitahuan saat struk selesai dicetak',
    importance: Importance.low,
    priority: Priority.low,
    color: Color(0xFFFF8343), // logo orange
  );

  static Future<void> init() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_qash'),
        iOS: DarwinInitializationSettings(),
      ),
    );
  }

  /// Android 13+ requires this at runtime (manifest declaration alone isn't
  /// enough). Called from the station bootstrap, not main(), so a fresh
  /// install isn't greeted by prompts before it is even activated.
  static Future<void> requestPermission() => Permission.notification.request();

  static Future<void> notifyPrinted(String jobId) async {
    await _plugin.show(
      id: jobId.hashCode,
      title: 'Struk tercetak',
      body: 'Struk terakhir berhasil dicetak.',
      notificationDetails: const NotificationDetails(android: _channel),
    );
  }
}
