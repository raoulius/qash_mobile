// print_queue.dart
//
// Sits between printer_bridge.dart and bluetooth_service.dart. Exists to
// answer one question reliably: "what happens if the printer is briefly
// disconnected, out of range, or the app gets killed mid-print?"
//
// Without this file, a failed print is a dead end — the cashier taps
// Print, nothing happens, and there's no record that it was ever supposed
// to print. With this file, every print request becomes a durable job:
// it's persisted to disk before anything touches Bluetooth, retried a
// few times with backoff, and only dropped after the caller can see it
// failed and choose to retry manually (e.g. a "reprint" tap).
//
// Persistence uses SharedPreferences as a simple JSON-encoded list, which
// is plenty for a queue that's normally 0-1 items deep. If volume ever
// grows much higher, swap the storage for sqflite/Isar without changing
// the public API below.

import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'bluetooth_service.dart';
import 'escpos_builder.dart'; // Receipt import removed — buildFromJobPayload handles all types

enum PrintJobStatus { queued, printing, success, failed }

class PrintJob {
  final String id;
  final Map<String, dynamic> receiptJson; // raw receipt data, for replay/reprint
  PrintJobStatus status;
  int attempts;
  String? lastError;

  PrintJob({
    required this.id,
    required this.receiptJson,
    this.status = PrintJobStatus.queued,
    this.attempts = 0,
    this.lastError,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'receiptJson': receiptJson,
        'status': status.name,
        'attempts': attempts,
        'lastError': lastError,
      };

  factory PrintJob.fromJson(Map<String, dynamic> json) => PrintJob(
        id: json['id'] as String,
        receiptJson: json['receiptJson'] as Map<String, dynamic>,
        status: PrintJobStatus.values.firstWhere(
          (s) => s.name == json['status'],
          orElse: () => PrintJobStatus.queued,
        ),
        attempts: json['attempts'] as int? ?? 0,
        lastError: json['lastError'] as String?,
      );
}

class PrintQueue {
  static const _prefsKey = 'printer.jobQueue';
  static const _maxAttempts = 3;
  static const _retryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
  ];

  final BluetoothPrinterService printerService;
  final _jobUpdates = StreamController<PrintJob>.broadcast();

  /// Emits every time a job's status changes — the bridge listens to this
  /// to relay status back to the Svelte UI (e.g. "printing...", "done",
  /// "failed, tap to retry").
  Stream<PrintJob> get jobUpdates => _jobUpdates.stream;

  bool _processing = false;

  PrintQueue({required this.printerService});

  /// Enqueues a receipt for printing and immediately attempts to process
  /// the queue. Returns the job id so the caller (the bridge) can report
  /// it back across to Svelte for correlation.
  Future<String> enqueue(Map<String, dynamic> receiptJson) async {
    final job = PrintJob(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      receiptJson: receiptJson,
    );
    final jobs = await _loadJobs();
    jobs.add(job);
    await _saveJobs(jobs);
    _jobUpdates.add(job);

    unawaited(_processQueue());
    return job.id;
  }

  /// Re-queues a previously failed or completed job by id — used for the
  /// "reprint" button. Cheaper than re-fetching from Laravel since the
  /// receipt data is already cached on-device.
  Future<void> reprint(String jobId) async {
    final jobs = await _loadJobs();
    final existing = jobs.firstWhere((j) => j.id == jobId,
        orElse: () => throw ArgumentError('Unknown job id: $jobId'));
    await enqueue(existing.receiptJson);
  }

  Future<void> _processQueue() async {
    if (_processing) return; // avoid concurrent drains
    _processing = true;
    try {
      var jobs = await _loadJobs();
      for (final job in jobs.where((j) => j.status == PrintJobStatus.queued)) {
        await _attemptJob(job);
      }
    } finally {
      _processing = false;
    }
  }

  Future<void> _attemptJob(PrintJob job) async {
    job.status = PrintJobStatus.printing;
    job.attempts += 1;
    await _updateJob(job);

    try {
      // If nothing's connected, try the last-known printer before giving
      // up — covers the common case of the app restarting mid-shift.
      if (printerService.connectedDevice == null) {
        final reconnected = await printerService.reconnectToLastKnown();
        if (!reconnected) {
          throw StateError('No printer connected and no known device to reconnect to');
        }
      }

      final bytes = await EscPosBuilder.buildFromJobPayload(job.receiptJson);
      await printerService.printBytes(bytes);

      job.status = PrintJobStatus.success;
      job.lastError = null;
      await _updateJob(job);
    } catch (e) {
      job.lastError = e.toString();

      if (job.attempts >= _maxAttempts) {
        job.status = PrintJobStatus.failed;
        await _updateJob(job);
        return;
      }

      job.status = PrintJobStatus.queued; // will be retried
      await _updateJob(job);

      final delay = _retryDelays[(job.attempts - 1).clamp(0, _retryDelays.length - 1)];
      Timer(delay, () => unawaited(_processQueue()));
    }
  }

  Future<void> _updateJob(PrintJob job) async {
    final jobs = await _loadJobs();
    final idx = jobs.indexWhere((j) => j.id == job.id);
    if (idx >= 0) {
      jobs[idx] = job;
    } else {
      jobs.add(job);
    }
    await _saveJobs(jobs);
    _jobUpdates.add(job);
  }

  Future<List<PrintJob>> _loadJobs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((j) => PrintJob.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Future<void> _saveJobs(List<PrintJob> jobs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(jobs.map((j) => j.toJson()).toList()));
  }

  /// Clears completed/failed jobs older than this session — call
  /// periodically (e.g. on app start) so the persisted queue doesn't grow
  /// unbounded. Keeps failed jobs around long enough for a manual reprint.
  Future<void> pruneCompleted({int keepFailedCount = 20}) async {
    final jobs = await _loadJobs();
    final failed = jobs.where((j) => j.status == PrintJobStatus.failed).toList();
    final trimmedFailed = failed.length > keepFailedCount
        ? failed.sublist(failed.length - keepFailedCount)
        : failed;
    final stillQueued = jobs
        .where((j) => j.status == PrintJobStatus.queued || j.status == PrintJobStatus.printing)
        .toList();
    await _saveJobs([...stillQueued, ...trimmedFailed]);
  }

  void dispose() {
    _jobUpdates.close();
  }
}