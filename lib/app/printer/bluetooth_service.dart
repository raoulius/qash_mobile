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
// and routes to the correct implementation per-platform internally. Both
// halves are implemented: Android via flutter_pos_printer_platform_image_3
// below, iOS via a MethodChannel to ios/Runner/PrinterEAChannel.swift.
// The iOS half still needs the MFi protocol string filled in — see the
// TODO on _iosProtocolString below.
//
// HOW TO FIND THE iOS PROTOCOL STRING:
//   1. Pair the RPP02N in Settings > Bluetooth, build to a physical
//      iPhone (EA does not work in the Simulator).
//   2. Call _iosChannel.invokeMethod('listAccessories') — it returns
//      each paired accessory's name + protocolStrings.
//   3. Paste the matching string into UISupportedExternalAccessoryProtocols
//      in Info.plist AND into _iosProtocolString below.
//   4. Some printer vendors document this string directly in their SDK
//      manual — worth a quick check before doing step 1-2 manually.

import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
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
  ///
  /// Bootstrap, the 30s retry timer and PrintQueue all call this; concurrent
  /// callers share the one attempt in flight instead of racing connect().
  Future<bool> reconnectToLastKnown() =>
      _reconnecting ??= _reconnect().whenComplete(() => _reconnecting = null);
  Future<bool>? _reconnecting;

  Future<bool> _reconnect() async {
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
    _btStateSub?.cancel();
    _stateController.close();
  }

  // ---- Android implementation (flutter_pos_printer_platform_image_3) --
  // Classic SPP is fully supported on Android by this package; isBle:
  // false is what selects Classic over BLE.

  final _androidManager = PrinterManager.instance;
  StreamSubscription<BTStatus>? _btStateSub;

  BluetoothPrinterService() {
    if (Platform.isAndroid) {
      // The plugin reports the socket dropping (printer off / out of range);
      // without this the UI says "connected" until the next job fails.
      _btStateSub = _androidManager.stateBluetooth.listen((status) {
        if (status == BTStatus.none && _connectedDevice != null) {
          _connectedDevice = null;
          _setState(PrinterConnectionState.disconnected);
        }
      });
    }
  }

  Future<List<PrinterDeviceInfo>> _androidScan(Duration timeout) async {
    final found = <PrinterDeviceInfo>[];
    final completer = Completer<List<PrinterDeviceInfo>>();

    final sub = _androidManager
        .discovery(type: PrinterType.bluetooth, isBle: false)
        .listen((device) {
      found.add(PrinterDeviceInfo(
        name: device.name,
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
    if (!ok) throw StateError('Print failed: send() returned false');
  }

  // ---- iOS implementation (ExternalAccessory / MFi Classic) -----------
  //
  // Backed by ios/Runner/PrinterEAChannel.swift over MethodChannel
  // "qash/printer_ea". EA accessories must already be paired at the OS
  // level (Settings > Bluetooth) — there is no live scan on iOS, "scan"
  // just lists paired accessories matching our protocol string.

  static const MethodChannel _iosChannel = MethodChannel('qash/printer_ea');

  // TODO: replace with the real protocol string. Find it by calling
  // _iosChannel.invokeMethod('listAccessories') on a physical iPhone with
  // the RPP02N paired — it returns each accessory's protocolStrings. Must
  // exactly match UISupportedExternalAccessoryProtocols in Info.plist.
  static const String _iosProtocolString =
      'REPLACE_WITH_REAL_MFI_PROTOCOL_STRING';

  Future<List<PrinterDeviceInfo>> _iosScan(Duration timeout) async {
    final result = await _iosChannel.invokeMethod<List<Object?>>(
      'scan',
      {'protocolString': _iosProtocolString},
    );
    return (result ?? [])
        .cast<Map<Object?, Object?>>()
        .map((m) => PrinterDeviceInfo(
              name: m['name'] as String? ?? 'Unknown printer',
              address: m['address'] as String? ?? '',
            ))
        .toList();
  }

  Future<void> _iosConnect(PrinterDeviceInfo device) async {
    await _iosChannel.invokeMethod('connect', {
      'address': device.address,
      'protocolString': _iosProtocolString,
    });
  }

  Future<void> _iosDisconnect() async {
    await _iosChannel.invokeMethod('disconnect');
  }

  Future<void> _iosPrint(Uint8List bytes) async {
    await _iosChannel.invokeMethod('print', {'bytes': bytes});
  }
}

// The native EA implementation lives in ios/Runner/PrinterEAChannel.swift
// (channel "qash/printer_ea") — see that file for connect/print/backpressure
// details, and its "listAccessories" method for discovering the protocol
// string above.
