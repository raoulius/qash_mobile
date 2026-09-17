// print_notifications.dart
//
// Fires the OS notification ("Receipt printed") when a print job succeeds.
// Separate from the in-app printing overlay (printing_overlay.dart) — this
// one should land even if the cashier has swiped the app to the background.

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class PrintNotifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _channel = AndroidNotificationDetails(
    'print_jobs',
    'Print jobs',
    channelDescription: 'Notifies when a receipt finishes printing',
    importance: Importance.low,
    priority: Priority.low,
  );

  static Future<void> init() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );
    // Android 13+ requires this at runtime (manifest declaration alone
    // isn't enough); iOS prompts automatically on first `initialize`+`show`.
    await Permission.notification.request();
  }

  static Future<void> notifyPrinted(String jobId) async {
    await _plugin.show(
      id: jobId.hashCode,
      title: 'Receipt printed',
      body: 'The last receipt printed successfully.',
      notificationDetails: const NotificationDetails(android: _channel),
    );
  }
}
