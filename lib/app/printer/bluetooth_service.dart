// bluetooth_service.dart
//
// The only file that talks to the printer hardware. Everything upstream
// (print_queue.dart and the station screen) assumes this file's public API
// works exactly as declared, so test it against the real RPP02N first when
// something prints wrong — it's a contained, one-file problem.
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
  static const _prefsKeyPaper = 'printer.paperWidth';

  final _stateController = StreamController<PrinterConnectionState>.broadcast();
  Stream<PrinterConnectionState> get connectionState => _stateController.stream;

  PrinterConnectionState _currentState = PrinterConnectionState.disconnected;
  PrinterConnectionState get currentState => _currentState;

  PrinterDeviceInfo? _connectedDevice;
  PrinterDeviceInfo? get connectedDevice => _connectedDevice;

  // ---- Paper width ----------------------------------------------------
  // A printer cannot be asked its paper width (the plugin never hands back
  // what the printer replies), so: the width set by hand in the app, else a
  // guess from the printer's name, else unknown. Reported on every poll; the
  // backoffice and the station screen flag a slip width that differs.

  /// '58' or '80' set by hand in the app; null = guess from the name.
  String? paperOverride;

  /// What this printer prints on: the override, else the name guess.
  String? get paperWidth => paperOverride ?? paperGuess(connectedDevice?.name);

  /// '58'/'80' from a printer's name, or null when it says nothing.
  /// ponytail: name heuristic; the in-app override is the fix when it guesses wrong.
  static String? paperGuess(String? name) {
    final n = (name ?? '').toUpperCase();
    if (n.contains('RPP02') || n.contains('PT-210') || n.contains('MTP-2')) return '58';
    final m = RegExp(r'(?<![0-9])(58|80)(?![0-9])').firstMatch(n);
    return m?.group(1);
  }

  Future<void> loadPaperOverride() async {
    final saved = (await SharedPreferences.getInstance()).getString(_prefsKeyPaper);
    paperOverride = saved == '58' || saved == '80' ? saved : null;
  }

  /// Saves the hand-set width ('58'/'80', null = automatic) and tells listeners
  /// (the poll reports it at once).
  Future<void> setPaperOverride(String? width) async {
    paperOverride = width;
    final prefs = await SharedPreferences.getInstance();
    width == null ? await prefs.remove(_prefsKeyPaper) : await prefs.setString(_prefsKeyPaper, width);
    if (!_stateController.isClosed) _stateController.add(_currentState);
  }

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
      throw StateError('Printer tidak terhubung');
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
    // The plugin reports a failed connect as `false`, not an error; ignoring it
    // showed (and reported to the server) a printer that was never connected.
    final ok = await _androidManager.connect(
      type: PrinterType.bluetooth,
      model: BluetoothPrinterInput(
        name: device.name,
        address: device.address,
        isBle: false,
        autoConnect: true,
      ),
    );
    if (!ok) throw StateError('Gagal terhubung ke printer');
  }

  Future<void> _androidDisconnect() async {
    await _androidManager.disconnect(type: PrinterType.bluetooth);
  }

  Future<void> _androidPrint(Uint8List bytes) async {
    final ok = await _androidManager.send(type: PrinterType.bluetooth, bytes: bytes.toList());
    if (!ok) throw StateError('Printer tidak merespons');
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
              name: m['name'] as String? ?? 'Printer tanpa nama',
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
