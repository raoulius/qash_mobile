// printer_bridge.dart
//
// The seam between the Svelte PWA (running inside pwa_screen.dart's
// WebView) and the native printer stack. This file implements exactly
// the contract designed earlier in src/lib/bridge/printer.ts on the
// Svelte side: listDevices / connect / print / status, each correlated
// by a request id and resolved back into a JS Promise.
//
// Deliberately the ONLY file that knows about both "the web side" and
// "the native side" at once. bluetooth_service.dart and print_queue.dart
// don't know a WebView exists; pwa_screen.dart doesn't know Bluetooth
// exists. This file is the translator between them, which is what makes
// each side independently testable (Phase 1 spike vs Phase 2 browser dev).

import 'dart:async';
import 'dart:convert';
import 'package:webview_flutter/webview_flutter.dart';
import 'bluetooth_service.dart';
import 'print_queue.dart';

class PrinterBridge {
  final BluetoothPrinterService printerService;
  final PrintQueue printQueue;
  final WebViewController webViewController;

  StreamSubscription<PrintJob>? _jobSub;
  StreamSubscription<PrinterConnectionState>? _connSub;

  PrinterBridge({
    required this.printerService,
    required this.printQueue,
    required this.webViewController,
  });

  /// Call once, after the WebViewController is created, before loading
  /// the PWA URL — registers the JS channel named "PrinterBridge", which
  /// must match window.PrinterBridge on the Svelte side exactly.
  void attach() {
    webViewController.addJavaScriptChannel(
      'PrinterBridge',
      onMessageReceived: (JavaScriptMessage message) {
        _handleIncoming(message.message);
      },
    );

    // Relay job status changes and connection state changes back to the
    // page proactively, not just as direct request/response — lets the
    // Svelte UI show live "printing…" / "reconnected" states without
    // polling. The page listens for these via a separate
    // window.__bridgeEvent(name, payload) hook (see note below).
    _jobSub = printQueue.jobUpdates.listen((job) {
      _emitEvent('printJobUpdate', {
        'id': job.id,
        'status': job.status.name,
        'attempts': job.attempts,
        'lastError': job.lastError,
      });
    });

    _connSub = printerService.connectionState.listen((state) {
      _emitEvent('connectionStateChanged', {'state': state.name});
    });
  }

  void detach() {
    _jobSub?.cancel();
    _connSub?.cancel();
  }

  Future<void> _handleIncoming(String rawMessage) async {
    Map<String, dynamic> request;
    String? id;
    try {
      request = jsonDecode(rawMessage) as Map<String, dynamic>;
      id = request['id'] as String?;
    } catch (e) {
      // Malformed message — nothing we can correlate back, so just log.
      // (Replace with your real logging if you have one wired up.)
      // ignore: avoid_print
      print('PrinterBridge: failed to decode message: $rawMessage');
      return;
    }

    if (id == null) {
      // ignore: avoid_print
      print('PrinterBridge: message missing id, cannot resolve: $rawMessage');
      return;
    }

    final action = request['action'] as String?;
    final payload = request['payload'] as Map<String, dynamic>?;

    try {
      final data = await _dispatch(action, payload);
      _resolve(id, ok: true, data: data);
    } catch (e) {
      _resolve(id, ok: false, error: e.toString());
    }
  }

  /// Routes each bridge action to the right service call. This is the
  /// list of everything the Svelte side is allowed to ask for — keep it
  /// small and explicit rather than exposing services directly.
  Future<dynamic> _dispatch(
      String? action, Map<String, dynamic>? payload) async {
    switch (action) {
      case 'listDevices':
        final devices = await printerService.scan();
        return devices
            .map((d) => {'name': d.name, 'address': d.address})
            .toList();

      case 'connect':
        final address = payload?['deviceId'] as String?;
        final name = payload?['name'] as String? ?? 'Printer';
        if (address == null) {
          throw ArgumentError('connect requires payload.deviceId');
        }
        await printerService.connect(
          PrinterDeviceInfo(name: name, address: address),
        );
        return null;

      case 'print':
        final receipt = payload?['receipt'] as Map<String, dynamic>?;
        if (receipt == null) {
          throw ArgumentError('print requires payload.receipt');
        }
        final jobId = await printQueue.enqueue(receipt);
        return {'jobId': jobId};

      case 'reprint':
        final jobId = payload?['jobId'] as String?;
        if (jobId == null) {
          throw ArgumentError('reprint requires payload.jobId');
        }
        await printQueue.reprint(jobId);
        return null;

      case 'status':
        return {
          'connectionState': printerService.currentState.name,
          'connectedDevice': printerService.connectedDevice == null
              ? null
              : {
                  'name': printerService.connectedDevice!.name,
                  'address': printerService.connectedDevice!.address,
                },
        };

      default:
        throw ArgumentError('Unknown bridge action: $action');
    }
  }

  void _resolve(String id, {required bool ok, dynamic data, String? error}) {
    final result =
        ok ? {'ok': true, 'data': data} : {'ok': false, 'error': error};
    final js =
        'window.__bridgeResolve(${jsonEncode(id)}, ${jsonEncode(result)});';
    webViewController.runJavaScript(js);
  }

  /// Fires an unsolicited event into the page (not tied to a request id).
  /// Svelte side should register: window.__bridgeEvent = (name, payload) => {...}
  /// and route 'printJobUpdate' / 'connectionStateChanged' to its stores.
  void _emitEvent(String name, Map<String, dynamic> payload) {
    final js =
        'window.__bridgeEvent && window.__bridgeEvent(${jsonEncode(name)}, ${jsonEncode(payload)});';
    webViewController.runJavaScript(js);
  }
}
