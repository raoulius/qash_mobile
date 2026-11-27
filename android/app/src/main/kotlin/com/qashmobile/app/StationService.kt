package com.qashmobile.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Persistent "Print station running" notification. Its only job is to keep
 * the app process (and therefore the Dart poll timers) alive while the app
 * is not in the foreground. It does no work itself.
 *
 * The foreground service keeps the process, not the CPU: with the screen off
 * the CPU sleeps, the poll timer stops, and the backoffice shows the station
 * offline (only a Reverb push still woke it to print). The partial wake lock
 * keeps the CPU running; Doze still needs the battery-optimisation exemption
 * that permissions.dart asks for.
 */
class StationService : Service() {
    companion object {
        const val EXTRA_TEXT = "text"
        private const val CHANNEL = "station"
        private const val ID = 1
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Notification channels are API 26+, but the app's minSdk is 24, so a
        // Nougat device (the J7 Prime ships one) would crash on class load here.
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "Print station", NotificationManager.IMPORTANCE_LOW)
            )
            Notification.Builder(this, CHANNEL)
        } else {
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        val open = PendingIntent.getActivity(
            this, 0, packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE
        )
        val notification = builder
            .setContentTitle("Print station aktif")
            .setContentText(intent?.getStringExtra(EXTRA_TEXT) ?: "Menunggu struk…")
            .setSmallIcon(R.drawable.ic_stat_qash)
            .setColor(0xFFFF8343.toInt()) // logo orange
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(ID, notification)
        }
        if (wakeLock?.isHeld != true) {
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "qash:station")
                .apply { setReferenceCounted(false); acquire() }
        }
        // Not STICKY: a restart after the process dies would bring back only this
        // notification, with no Flutter engine polling behind it.
        return START_NOT_STICKY
    }
}
