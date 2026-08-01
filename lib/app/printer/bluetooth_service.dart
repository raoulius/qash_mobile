// bluetooth_service.dart
//
// THIS IS THE FILE TO TEST FIRST, IN ISOLATION, AGAINST THE REAL RPP02N —
// before wiring it into the bridge or anything else. Everything upstream
// (printer_bridge.dart, the Svelte app) assumes this file's public API
// works exactly as declared. If it doesn't, that's a contained, one-file
// problem, not a tangled one.
//
// WHY ANDROID AND iOS ARE HANDLED DIFFERENTLY (read this before editing):
//
// The RPP02N is a Bluetooth Classic / SPP printer that is MFi-certified
// (confirmed by it appearing in iOS Settings > Bluetooth after pairing).
// That single fact forces a platform split:
//
//   - Android: Classic SPP is a normal, unrestricted OS capability.
//     flutter_pos_printer_platform_image_3 handles it directly.
//
//   - iOS: Apple does NOT expose generic Bluetooth Classic / SPP to apps.
//     The only sanctioned path for a Classic device is Apple's
//     ExternalAccessory framework, which requires the printer's MFi
//     "protocol string" (a vendor-specific identifier like
//     "com.something.printer") declared in Info.plist under
//     UISupportedExternalAccessoryProtocols. flutter_pos_printer_platform's
//     own docs confirm classic BT is Android-only in that package — it
//     does NOT cover this path.
//
// This file exposes ONE interface (scan / connect / print / disconnect)
// and routes to the correct implementation per-platform internally. The
// Android half is fully implemented below. The iOS half needs the MFi
// protocol string filled in — see _IosClassicPrinter and the TODO there.
//
// HOW TO FIND THE iOS PROTOCOL STRING (do this during the Phase 1 spike):
//   1. Build a tiny test screen that calls EAAccessoryManager and logs
//      `accessory.protocolStrings` for all connectedAccessories.
//      (A short Swift snippet for this is in the comment at the bottom
//      of this file — wire it into a MethodChannel temporarily.)
//   2. Pair the RPP02N as you already have, then run that debug call.
//   3. Whatever string(s) print out, paste them into Info.plist under
//      UISupportedExternalAccessoryProtocols AND into PROTOCOL_STRING
//      below.
//   4. Some printer vendors document this string directly in their SDK
//      manual — worth a quick check before doing step 1-3 manually.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_pos_printer_platform_image_3/flutter_pos_printer_platform_image_3.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PrinterConnectionState { disconnected, connecting, connected, error }

class PrinterDeviceInfo {
  final String name;
  final String address; // MAC on Android; identifier string on iOS
  PrinterDeviceInfo({required this.name, required this.address});
}

class BluetoothPrinterService {
  static const _prefsKeyLastDeviceAddress = 'printer.lastDeviceAddress';
  static const _prefsKeyLastDeviceName = 'printer.lastDeviceName';

  final _stateController = StreamController<PrinterConnectionState>.broadcast();
  Stream<PrinterConnectionState> get connectionState => _stateController.stream;

  PrinterConnectionState _currentState = PrinterConnectionState.disconnected;
  PrinterConnectionState get currentState => _currentState;

  PrinterDeviceInfo? _connectedDevice;
  PrinterDeviceInfo? get connectedDevice => _connectedDevice;

  // ---- Public API (identical on both platforms) ----------------------

  Future<List<PrinterDeviceInfo>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) {
    return Platform.isAndroid ? _androidScan(timeout) : _iosScan(timeout);
  }

  Future<void> connect(PrinterDeviceInfo device) async {
    _setState(PrinterConnectionState.connecting);
    try {
      if (Platform.isAndroid) {
        await _androidConnect(device);
      } else {
        await _iosConnect(device);
      }
      _connectedDevice = device;
      _setState(PrinterConnectionState.connected);
      await _rememberDevice(device);
    } catch (e) {
      _setState(PrinterConnectionState.error);
      rethrow;
    }
  }

  Future<void> disconnect() async {
    if (Platform.isAndroid) {
      await _androidDisconnect();
    } else {
      await _iosDisconnect();
    }
    _connectedDevice = null;
    _setState(PrinterConnectionState.disconnected);
  }

  /// Sends raw ESC/POS bytes (from escpos_builder.dart) to the connected
  /// printer. Throws if nothing is connected — callers (print_queue.dart)
  /// are expected to call connect()/reconnectToLastKnown() first.
  Future<void> printBytes(Uint8List bytes) async {
    if (_connectedDevice == null) {
      throw StateError('No printer connected');
    }
    if (Platform.isAndroid) {
      await _androidPrint(bytes);
    } else {
      await _iosPrint(bytes);
    }
  }

  /// Attempts to reconnect to whichever printer was last successfully
  /// connected, without requiring the user to re-pick it from a list.
  /// Returns true if reconnection succeeded.
  Future<bool> reconnectToLastKnown() async {
    final prefs = await SharedPreferences.getInstance();
    final address = prefs.getString(_prefsKeyLastDeviceAddress);
    final name = prefs.getString(_prefsKeyLastDeviceName);
    if (address == null) return false;

    try {
      await connect(
          PrinterDeviceInfo(name: name ?? 'Printer', address: address));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _rememberDevice(PrinterDeviceInfo device) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeyLastDeviceAddress, device.address);
    await prefs.setString(_prefsKeyLastDeviceName, device.name);
  }

  void _setState(PrinterConnectionState s) {
    _currentState = s;
    _stateController.add(s);
  }

  void dispose() {
    _stateController.close();
  }

  // ---- Android implementation (flutter_pos_printer_platform_image_3) --
  // Classic SPP is fully supported on Android by this package; isBle:
  // false is what selects Classic over BLE.

  final _androidManager = PrinterManager.instance;

  Future<List<PrinterDeviceInfo>> _androidScan(Duration timeout) async {
    final found = <PrinterDeviceInfo>[];
    final completer = Completer<List<PrinterDeviceInfo>>();

    final sub = _androidManager
        .discovery(type: PrinterType.bluetooth, isBle: false)
        .listen((device) {
      found.add(PrinterDeviceInfo(
        name: device.name ?? 'Unknown printer',
        address: device.address ?? '',
      ));
    });

    Timer(timeout, () {
      sub.cancel();
      if (!completer.isCompleted) completer.complete(found);
    });

    return completer.future;
  }

  Future<void> _androidConnect(PrinterDeviceInfo device) async {
    await _androidManager.connect(
      type: PrinterType.bluetooth,
      model: BluetoothPrinterInput(
        name: device.name,
        address: device.address,
        isBle: false,
        autoConnect: true,
      ),
    );
  }

  Future<void> _androidDisconnect() async {
    await _androidManager.disconnect(type: PrinterType.bluetooth);
  }

  Future<void> _androidPrint(Uint8List bytes) async {
    final ok = await _androidManager.send(type: PrinterType.bluetooth, bytes: bytes.toList());
    // ignore: avoid_print
    print('[BT] send result: $ok  bytes=${bytes.length}');
    if (!ok) throw StateError('Print failed: send() returned false');
  }

  // ---- iOS implementation (ExternalAccessory / MFi Classic) -----------
  //
  // NOT YET FUNCTIONAL — requires the MFi protocol string (see file
  // header). The shape below is correct; PROTOCOL_STRING is the only
  // missing piece. Until it's filled in, these methods throw clearly
  // rather than silently doing nothing, so a missed iOS test shows up
  // immediately instead of shipping broken.

  // TODO: replace with the real protocol string found via the debug
  // helper described in the file header, e.g. "com.rongta.print" —
  // this is a placeholder and WILL NOT WORK as-is.
  static const String _iosProtocolString =
      'REPLACE_WITH_REAL_MFI_PROTOCOL_STRING';

  Future<List<PrinterDeviceInfo>> _iosScan(Duration timeout) async {
    // ExternalAccessory does not "scan" the way Bluetooth Classic does on
    // Android — MFi accessories must already be paired at the OS level
    // (Settings > Bluetooth), which yours already is. So "scanning" on
    // iOS really means: list currently connected/paired EA accessories
    // matching our protocol string.
    //
    // This requires a small native Swift MethodChannel calling
    // EAAccessoryManager.shared().connectedAccessories, filtered by
    // protocolStrings.contains(_iosProtocolString). Not implemented here
    // because it needs native Swift code living in ios/Runner, not Dart —
    // see the Swift snippet at the bottom of this file to wire that up.
    throw UnimplementedError(
      'iOS Classic/MFi scanning requires a native ExternalAccessory '
      'MethodChannel — see comment block at the bottom of bluetooth_service.dart',
    );
  }

  Future<void> _iosConnect(PrinterDeviceInfo device) async {
    throw UnimplementedError(
      'iOS Classic/MFi connect requires the native ExternalAccessory '
      'session — fill in _iosProtocolString and the native channel first',
    );
  }

  Future<void> _iosDisconnect() async {
    throw UnimplementedError(
        'See _iosConnect — native EA session not wired up yet');
  }

  Future<void> _iosPrint(Uint8List bytes) async {
    throw UnimplementedError(
        'See _iosConnect — native EA session not wired up yet');
  }
}

/*
 * SWIFT SNIPPET — for finding / using the MFi protocol string on iOS.
 * This is NOT Dart, it does not belong in this file's compiled output —
 * it's reference for the native ios/Runner/AppDelegate.swift work needed
 * to complete _iosScan/_iosConnect/_iosPrint above.
 *
 * import ExternalAccessory
 *
 * func debugListConnectedAccessories() {
 *     let manager = EAAccessoryManager.shared()
 *     for accessory in manager.connectedAccessories {
 *         print("Name: \(accessory.name)")
 *         print("Protocols: \(accessory.protocolStrings)")
 *     }
 * }
 *
 * func openSession(protocolString: String) -> EASession? {
 *     let manager = EAAccessoryManager.shared()
 *     guard let accessory = manager.connectedAccessories.first(where: {
 *         $0.protocolStrings.contains(protocolString)
 *     }) else { return nil }
 *     let session = EASession(accessory: accessory, forProtocol: protocolString)
 *     session?.outputStream?.open()
 *     return session
 * }
 *
 * // Writing bytes once the session's outputStream is open:
 * // let written = session.outputStream?.write(bytes, maxLength: bytes.count)
 *
 * Wire debugListConnectedAccessories() behind a temporary MethodChannel
 * call during the Phase 1 spike to read the real protocol string off your
 * physical RPP02N, then delete the temporary channel once
 * _iosProtocolString is filled in for good.
 */
