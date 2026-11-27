package com.qashmobile.app

import android.content.Intent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Channel "qash/station": keeps the screen on and runs a foreground service
 * while a station is active, so the poll loop survives the cashier switching
 * apps or the screen timing out. Dart side: lib/app/station_native.dart.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "qash/station")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "keepScreenOn" -> {
                        val on = call.arguments as? Boolean ?: false
                        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        result.success(null)
                    }
                    "startForeground" -> {
                        val intent = Intent(this, StationService::class.java)
                            .putExtra(StationService.EXTRA_TEXT, call.arguments as? String)
                        if (android.os.Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                        result.success(null)
                    }
                    "stopForeground" -> {
                        stopService(Intent(this, StationService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
