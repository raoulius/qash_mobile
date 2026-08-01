// main.dart  —  headless polling print station
//
// First launch: shows SetupScreen asking for server URL + activation token.
// After activation, DeviceConfig is saved to SharedPreferences and the
// station screen starts automatically on every subsequent launch.

import 'package:flutter/material.dart';
import 'app/config/config_service.dart';
import 'app/config/device_config.dart';
import 'app/config/setup_screen.dart';
import 'app/printer/bluetooth_service.dart';
import 'app/printer/print_queue.dart';
import 'app/printer/poll_service.dart';
import 'app/printer/reverb_service.dart';
import 'app/permissions/permissions.dart';
import 'app/dashboard/dashboard_stats_service.dart';
import 'app/dashboard/dashboard_screen.dart';

void main() {
  runApp(const PrintStationApp());
}

class PrintStationApp extends StatelessWidget {
  const PrintStationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Print Station',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const _Launcher(),
    );
  }
}

/// Loads config from SharedPreferences; shows SetupScreen if not yet activated.
class _Launcher extends StatefulWidget {
  const _Launcher();

  @override
  State<_Launcher> createState() => _LauncherState();
}

class _LauncherState extends State<_Launcher> {
  DeviceConfig? _config;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await ConfigService.load();
    setState(() {
      _config = config;
      _loading = false;
    });
  }

  void _onActivated(DeviceConfig config) {
    setState(() => _config = config);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_config == null) {
      return SetupScreen(onActivated: _onActivated);
    }
    return StationScreen(config: _config!);
  }
}

class StationScreen extends StatefulWidget {
  final DeviceConfig config;

  const StationScreen({super.key, required this.config});

  @override
  State<StationScreen> createState() => _StationScreenState();
}

class _StationScreenState extends State<StationScreen> {
  late final BluetoothPrinterService _printerService;
  late final PrintQueue _printQueue;
  late final PollService _pollService;
  late final ReverbService _reverbService;
  late final DashboardStatsService _dashboardStatsService;

  String _printerStatus = 'starting…';
  String _pollStatus = 'starting…';
  String _pushStatus = 'starting…';
  int _navIndex = 0;

  @override
  void initState() {
    super.initState();
    final cfg = widget.config;
    _printerService = BluetoothPrinterService();
    _printQueue = PrintQueue(printerService: _printerService);
    _pollService = PollService(
      printerService: _printerService,
      printQueue: _printQueue,
      apiBaseUrl: cfg.apiBaseUrl,
      stationId: cfg.stationId,
      authToken: cfg.apiToken,
    );
    _reverbService = ReverbService(
      printQueue: _printQueue,
      apiBaseUrl: cfg.apiBaseUrl,
      tenantId: cfg.tenantId,
      outletId: cfg.outletId,
      stationId: cfg.stationId,
      apiToken: cfg.apiToken,
      appKey: cfg.reverbAppKey,
      reverbHost: cfg.reverbHost,
      reverbPort: cfg.reverbPort,
      secure: cfg.reverbSecure,
    );
    _dashboardStatsService = DashboardStatsService(
      apiBaseUrl: cfg.apiBaseUrl,
      authToken: cfg.apiToken,
    );

    _printerService.connectionState.listen((s) {
      setState(() => _printerStatus = s.name);
    });
    _pollService.status.listen((s) {
      setState(() => _pollStatus = s);
    });
    _reverbService.status.listen((s) {
      setState(() => _pushStatus = s);
    });

    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final perm = await BluetoothPermissions.ensureGranted();
    if (!perm.granted) {
      setState(() => _printerStatus = 'permission denied: ${perm.reason}');
      return;
    }

    await _printQueue.pruneCompleted();

    // Start network services immediately — don't block on Bluetooth.
    _pollService.start();
    _reverbService.start();

    // Bluetooth reconnect runs in parallel; UI updates via connectionState stream.
    _printerService.reconnectToLastKnown().then((reconnected) {
      if (!reconnected && mounted) {
        setState(() => _printerStatus = 'no printer — tap to connect');
      }
    });
  }

  Future<void> _pickPrinter() async {
    setState(() => _printerStatus = 'scanning…');
    final devices = await _printerService.scan();
    if (!mounted) return;
    if (devices.isEmpty) {
      setState(() => _printerStatus = 'no printers found');
      return;
    }
    final chosen = await showDialog<PrinterDeviceInfo>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Select printer'),
        children: devices
            .map((d) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, d),
                  child: Text('${d.name}  (${d.address})'),
                ))
            .toList(),
      ),
    );
    if (chosen != null) {
      await _printerService.connect(chosen);
    }
  }

  Future<void> _resetDevice() async {
    await ConfigService.clear();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute<void>(builder: (_) => const _Launcher()),
    );
  }

  @override
  void dispose() {
    _reverbService.dispose();
    _pollService.dispose();
    _printQueue.dispose();
    _printerService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _navIndex,
        children: [
          _buildStationTab(context),
          DashboardScreen(statsService: _dashboardStatsService),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _navIndex,
        onDestinationSelected: (i) => setState(() => _navIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.print), label: 'Station'),
          NavigationDestination(icon: Icon(Icons.dashboard), label: 'Dashboard'),
        ],
      ),
    );
  }

  Widget _buildStationTab(BuildContext context) {
    final cfg = widget.config;
    return Scaffold(
      appBar: AppBar(
        title: Text('${cfg.stationId} — ${cfg.tenantId}'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) { if (v == 'reset') _resetDevice(); },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'reset', child: Text('Reset device…')),
            ],
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.print, size: 64),
            const SizedBox(height: 24),
            Text('Printer: $_printerStatus',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Poll: $_pollStatus',
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text('Push: $_pushStatus',
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _pickPrinter,
              icon: const Icon(Icons.bluetooth_searching),
              label: const Text('Connect / change printer'),
            ),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'Keep this app open during your shift so receipts print '
                'automatically as transactions complete.',
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
