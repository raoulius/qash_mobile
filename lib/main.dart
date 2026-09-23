// main.dart  —  headless polling print station
//
// First launch: shows SetupScreen asking for server URL + activation token.
// After activation, DeviceConfig is saved to SharedPreferences and the
// station screen starts automatically on every subsequent launch.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;
import 'app/net.dart';
import 'app/theme.dart';
import 'app/config/config_service.dart';
import 'app/config/device_config.dart';
import 'app/config/setup_screen.dart';
import 'app/printer/bluetooth_service.dart';
import 'app/printer/print_queue.dart';
import 'app/printer/poll_service.dart';
import 'app/printer/reverb_service.dart';
import 'app/printer/print_notifications.dart';
import 'app/printer/printing_overlay.dart';
import 'app/printer/failed_jobs_screen.dart';
import 'app/station_native.dart';
import 'app/permissions/permissions.dart';
import 'app/dashboard/dashboard_stats_service.dart';
import 'app/dashboard/dashboard_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PrintNotifications.init();
  runApp(const PrintStationApp());
}

class PrintStationApp extends StatelessWidget {
  const PrintStationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Qash Mobile',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
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

class _StationScreenState extends State<StationScreen> with WidgetsBindingObserver {
  late final BluetoothPrinterService _printerService;
  late final PrintQueue _printQueue;
  late final PollService _pollService;
  late final ReverbService _reverbService;
  late final DashboardStatsService _dashboardStatsService;

  String _printerStatus = 'Memulai…';
  String _pollStatus = 'Memulai…';
  String _pushStatus = 'Memulai…';
  int _navIndex = 0;
  int _failedCount = 0;

  PrintingOverlayState _overlayState = PrintingOverlayState.hidden;
  final _overlayTracker = PrintingOverlayTracker();
  Timer? _overlayHideTimer;
  Timer? _reconnectTimer;
  StreamSubscription<void>? _unauthorizedSub;

  /// Server rejected our token (revoked, or re-activated on another phone).
  bool _revoked = false;

  /// Bluetooth permission refused; retried when the cashier returns from Settings.
  bool _permissionDenied = false;
  bool _started = false;

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
      setState(() => _printerStatus = switch (s) {
            PrinterConnectionState.connected =>
              'Terhubung: ${_printerService.connectedDevice?.name ?? 'printer'}',
            PrinterConnectionState.connecting => 'Menghubungkan…',
            PrinterConnectionState.disconnected => 'Tidak terhubung',
            PrinterConnectionState.error => 'Gagal terhubung',
          });
    });
    // Printer dropped (powered off, out of range): retry the last-known
    // device every 30s so the cashier doesn't have to notice and tap.
    _reconnectTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_printerService.currentState == PrinterConnectionState.disconnected) {
        _printerService.reconnectToLastKnown();
      }
    });
    _pollService.status.listen((s) {
      setState(() => _pollStatus = s);
    });
    _reverbService.status.listen((s) {
      setState(() => _pushStatus = s);
    });
    _printQueue.jobUpdates.listen(_onJobUpdate);
    _unauthorizedSub = deviceUnauthorized.stream.listen((_) {
      if (_revoked || !mounted) return;
      _pollService.stop();
      _reverbService.dispose();
      setState(() => _revoked = true);
    });
    WidgetsBinding.instance.addObserver(this);

    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final perm = await BluetoothPermissions.ensureGranted();
    if (!mounted) return;
    setState(() => _permissionDenied = !perm.granted);
    if (!perm.granted) {
      setState(() => _printerStatus = perm.reason ?? 'Izin Bluetooth ditolak');
      return;
    }

    if (_started) return; // two quick resumes can both re-run bootstrap
    _started = true;
    await _printQueue.pruneCompleted();
    _refreshFailedCount();
    // After Bluetooth, so first launch doesn't stack prompts before setup.
    await PrintNotifications.requestPermission();
    await BluetoothPermissions.askBatteryExemptionOnce();

    // Keep the screen on and hold a foreground service so polling survives
    // the cashier switching apps or the screen timing out.
    StationNative.start('${widget.config.stationId} — ${widget.config.tenantId}');

    // Start network services immediately — don't block on Bluetooth.
    _pollService.start();
    _reverbService.start();

    // Bluetooth reconnect runs in parallel; UI updates via connectionState stream.
    _printerService.reconnectToLastKnown().then((reconnected) {
      if (!reconnected && mounted) {
        setState(() => _printerStatus = 'Belum ada printer — ketuk Hubungkan');
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from system Settings: services never started, so start them now.
    if (state != AppLifecycleState.resumed || !_permissionDenied) return;
    BluetoothPermissions.isGranted().then((ok) {
      if (ok && _permissionDenied) _bootstrap();
    });
  }

  void _onJobUpdate(PrintJob job) {
    // In the foreground the overlay already says it; notify only when the
    // cashier is in another app.
    if (job.status == PrintJobStatus.success &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      PrintNotifications.notifyPrinted(job.id);
    }
    if (job.status == PrintJobStatus.failed || job.status == PrintJobStatus.success) {
      _refreshFailedCount();
    }

    final next = _overlayTracker.onJob(job.id, job.status);
    if (next != _overlayState) setState(() => _overlayState = next);

    _overlayHideTimer?.cancel();
    if (next == PrintingOverlayState.success) {
      _overlayHideTimer = Timer(const Duration(milliseconds: 900), () {
        if (mounted) setState(() => _overlayState = PrintingOverlayState.hidden);
      });
    }
  }

  Future<void> _refreshFailedCount() async {
    final n = (await _printQueue.failedJobs()).length;
    if (mounted && n != _failedCount) setState(() => _failedCount = n);
  }

  /// Local slip, no server job id: proves the printer link without touching
  /// the backend. 58mm layout so it also fits the narrow RPP02N.
  Future<void> _testPrint() async {
    final cfg = widget.config;
    await _printQueue.enqueue({
      '_jobType': 'test_print',
      'template': {'paperWidth': '58'},
      'header': {'outletName': cfg.tenantId},
      'station': cfg.stationId,
      'printer': _printerService.connectedDevice?.name,
      'printedAt': DateTime.now().toString().substring(0, 16),
    });
  }

  Future<void> _pickPrinter() async {
    setState(() => _printerStatus = 'Mencari printer…');
    final devices = await _printerService.scan();
    if (!mounted) return;
    if (devices.isEmpty) {
      setState(() => _printerStatus = 'Printer tidak ditemukan');
      return;
    }
    final chosen = await showDialog<PrinterDeviceInfo>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Pilih printer'),
        children: devices
            .map((d) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, d),
                  child: Text('${d.name}  (${d.address})'),
                ))
            .toList(),
      ),
    );
    if (chosen == null) return;
    try {
      await _printerService.connect(chosen);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal terhubung ke ${chosen.name}. Pastikan printer menyala.')),
      );
    }
  }

  Future<void> _resetDevice({bool confirm = true}) async {
    if (confirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Reset perangkat?'),
          content: const Text(
              'Station ini akan berhenti mencetak sampai diaktifkan lagi '
              'dengan token baru dari backoffice.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
          ],
        ),
      );
      if (ok != true) return;
    }
    // Old jobs belong to the old station token; don't replay them under a new one.
    await _printQueue.clear();
    await ConfigService.clear();
    await StationNative.stop();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute<void>(builder: (_) => const _Launcher()),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unauthorizedSub?.cancel();
    _overlayHideTimer?.cancel();
    _reconnectTimer?.cancel();
    _reverbService.dispose();
    _pollService.dispose();
    _printQueue.dispose();
    _printerService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_revoked) return _buildRevoked(context);
    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: _navIndex,
            children: [
              _buildStationTab(context),
              FailedJobsScreen(printQueue: _printQueue),
              DashboardScreen(statsService: _dashboardStatsService),
            ],
          ),
          Positioned.fill(child: PrintingOverlay(state: _overlayState)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _navIndex,
        onDestinationSelected: (i) => setState(() => _navIndex = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.print), label: 'Printer'),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _failedCount > 0,
              label: Text('$_failedCount'),
              child: const Icon(Icons.error_outline),
            ),
            label: 'Gagal',
          ),
          const NavigationDestination(icon: Icon(Icons.dashboard), label: 'Dashboard'),
        ],
      ),
    );
  }

  Widget _buildRevoked(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.link_off, size: 64, color: theme.colorScheme.error),
                const SizedBox(height: 24),
                Text('Perangkat dinonaktifkan',
                    style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  'Server menolak token station ini — dicabut di backoffice atau '
                  'sudah diaktifkan di HP lain. Minta token baru ke admin.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => _resetDevice(confirm: false),
                  child: const Text('Aktivasi ulang'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStationTab(BuildContext context) {
    final cfg = widget.config;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Image.asset(AppTheme.logo(context, 'logotype'), height: 24),
            Text(
              '${cfg.stationId} — ${cfg.tenantId}',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) { if (v == 'reset') _resetDevice(); },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'reset', child: Text('Reset perangkat…')),
            ],
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.print,
                      size: 48,
                      color: Theme.of(context).colorScheme.onPrimaryContainer),
                ),
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        _StatusRow(icon: Icons.bluetooth, label: 'Printer', value: _printerStatus),
                        const Divider(height: 24),
                        _StatusRow(icon: Icons.sync, label: 'Server', value: _pollStatus),
                        const Divider(height: 24),
                        _StatusRow(icon: Icons.cloud_sync, label: 'Real-time', value: _pushStatus),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                if (_permissionDenied) ...[
                  OutlinedButton.icon(
                    onPressed: openAppSettings,
                    icon: const Icon(Icons.settings),
                    label: const Text('Buka Pengaturan'),
                  ),
                  const SizedBox(height: 12),
                ],
                FilledButton.icon(
                  onPressed: _pickPrinter,
                  icon: const Icon(Icons.bluetooth_searching),
                  label: const Text('Hubungkan / ganti printer'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _printerService.currentState == PrinterConnectionState.connected
                      ? _testPrint
                      : null,
                  icon: const Icon(Icons.receipt_long),
                  label: const Text('Tes cetak'),
                ),
                const SizedBox(height: 16),
                Text(
                  'Biarkan aplikasi ini terbuka selama shift agar struk '
                  'tercetak otomatis setiap transaksi selesai.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatusRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 20, color: scheme.primary),
        const SizedBox(width: 12),
        Text(label, style: Theme.of(context).textTheme.titleMedium),
        const Spacer(),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
