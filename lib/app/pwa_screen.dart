// pwa_screen.dart
//
// Hosts the Svelte PWA in a WebView and wires the PrinterBridge to it.
// This file is intentionally thin — it doesn't know what's inside the
// PWA, doesn't know about receipts or Bluetooth specifics, just:
//   1. loads the URL
//   2. constructs the native services
//   3. attaches the bridge so the page can reach them
//
// PWA_URL should point at wherever Laravel serves the built Svelte app.
// During Phase 2 development (Svelte in a browser, bridge not present),
// you won't use this screen at all — it only matters once you're
// assembling Phase 3.

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'printer/bluetooth_service.dart';
import 'printer/print_queue.dart';
import 'printer/printer_bridge.dart';

class PwaScreen extends StatefulWidget {
  final String pwaUrl;

  const PwaScreen({super.key, required this.pwaUrl});

  @override
  State<PwaScreen> createState() => _PwaScreenState();
}

class _PwaScreenState extends State<PwaScreen> {
  late final WebViewController _webViewController;
  late final BluetoothPrinterService _printerService;
  late final PrintQueue _printQueue;
  late final PrinterBridge _printerBridge;

  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();

    _printerService = BluetoothPrinterService();
    _printQueue = PrintQueue(printerService: _printerService);

    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => setState(() => _loading = false),
          onWebResourceError: (error) {
            setState(() {
              _loading = false;
              _loadError = 'Failed to load app: ${error.description}';
            });
          },
        ),
      );

    _printerBridge = PrinterBridge(
      printerService: _printerService,
      printQueue: _printQueue,
      webViewController: _webViewController,
    );
    _printerBridge.attach();

    // Attempt to silently reconnect to whichever printer was last paired,
    // so the cashier doesn't have to re-pick it from a list every launch.
    _printerService.reconnectToLastKnown();
    _printQueue.pruneCompleted();

    _webViewController.loadRequest(Uri.parse(widget.pwaUrl));
  }

  @override
  void dispose() {
    _printerBridge.detach();
    _printerService.dispose();
    _printQueue.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            WebViewWidget(controller: _webViewController),
            if (_loading)
              const Center(child: CircularProgressIndicator()),
            if (_loadError != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_loadError!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: () {
                          setState(() {
                            _loadError = null;
                            _loading = true;
                          });
                          _webViewController.reload();
                        },
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}