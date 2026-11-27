import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Held strongly so the EASession/StreamDelegate isn't deallocated mid-print.
  private var printerEAChannel: PrinterEAChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    printerEAChannel = PrinterEAChannel(messenger: engineBridge.applicationRegistrar.messenger())

    // "qash/station" (lib/app/station_native.dart): iOS has no foreground
    // service, so an active station just keeps the screen from sleeping —
    // polling only runs while the app is in front.
    FlutterMethodChannel(name: "qash/station", binaryMessenger: engineBridge.applicationRegistrar.messenger())
      .setMethodCallHandler { call, result in
        if call.method == "keepScreenOn" {
          UIApplication.shared.isIdleTimerDisabled = (call.arguments as? Bool) ?? false
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
  }
}
