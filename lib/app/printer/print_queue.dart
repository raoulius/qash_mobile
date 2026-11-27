// print_queue.dart
//
// Sits between the job source (poll_service.dart) and
// bluetooth_service.dart. Exists to
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

  /// Emits every time a job's status changes — the station screen, the Gagal
  /// tab and PollService (server acknowledgements) listen to this.
  Stream<PrintJob> get jobUpdates => _jobUpdates.stream;

  bool _processing = false;

  PrintQueue({required this.printerService});

  /// Paper width ('58'/'80') the last server job was laid out for; the station
  /// screen compares it with the printer's.
  String? lastSlipPaper;

  /// Enqueues a receipt for printing and immediately attempts to process
  /// the queue. Returns the local job id for correlation.
  /// [force] bypasses the server-job guard below — it is what makes a manual
  /// reprint of an already-printed slip possible.
  Future<String> enqueue(Map<String, dynamic> receiptJson, {bool force = false}) async {
    final jobs = await _loadJobs();

    // One server job prints once, whatever the server later says. The poll
    // re-offers a job every time its lease expires, and an acknowledgement that
    // fails to land leaves it pending forever — that combination printed the
    // same kitchen ticket nine times, 32 seconds apart. Treating an existing
    // non-failed copy as "already handled" makes the device idempotent per
    // server job id, so a broken acknowledgement costs a stale row on the
    // server instead of an endless stack of paper.
    final serverId = receiptJson['_serverJobId']?.toString();
    final template = receiptJson['template'];
    if (serverId != null && template is Map && template['paperWidth'] != null) {
      lastSlipPaper = template['paperWidth'].toString();
    }
    if (!force && serverId != null) {
      for (final j in jobs) {
        if (j.receiptJson['_serverJobId']?.toString() == serverId &&
            j.status != PrintJobStatus.failed) {
          unawaited(_processQueue());
          return j.id;
        }
      }
    }

    final job = PrintJob(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      receiptJson: receiptJson,
    );
    jobs.add(job);
    await _saveJobs(jobs);
    _jobUpdates.add(job);

    unawaited(_processQueue());
    return job.id;
  }

  /// Re-queues a previously failed or completed job by id — used for the
  /// "reprint" button. Cheaper than re-fetching from Laravel since the
  /// receipt data is already cached on-device.
  ///
  /// A failed original is replaced by the new attempt, so the Gagal tab
  /// drops it at once — left there, a second tap printed a second copy. If
  /// the retry fails too, the new job shows up in its place.
  Future<void> reprint(String jobId) async {
    final jobs = await _loadJobs();
    final existing = jobs.firstWhere((j) => j.id == jobId,
        orElse: () => throw ArgumentError('Unknown job id: $jobId'));
    if (existing.status == PrintJobStatus.failed) jobs.remove(existing);
    await enqueue(existing.receiptJson, force: true);
  }

  /// Current status of a stored job, or null if it is gone. Lets the poll tell
  /// "queued, wait for it" from "already printed, just re-acknowledge it".
  Future<PrintJobStatus?> statusOf(String jobId) async {
    for (final j in await _loadJobs()) {
      if (j.id == jobId) return j.status;
    }
    return null;
  }

  Future<void> _processQueue() async {
    if (_processing) return; // avoid concurrent drains
    _processing = true;
    try {
      // Re-read after each pass: an enqueue that arrives mid-drain hits the
      // guard above and is dropped, so a single pass leaves it sitting in the
      // queue until something else happens to trigger a drain. `attempted`
      // keeps each job to one try per drain, leaving the backoff timers in
      // _attemptJob to own retries.
      final attempted = <String>{};
      while (true) {
        final jobs = await _loadJobs();
        final due = jobs
            .where((j) => j.status == PrintJobStatus.queued && !attempted.contains(j.id))
            .toList();
        if (due.isEmpty) break;
        for (final job in due) {
          attempted.add(job.id);
          await _attemptJob(job);
        }
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
          throw StateError('Printer tidak terhubung (mati atau di luar jangkauan Bluetooth)');
        }
      }

      // Copy by copy: a printer without a cutter needs time to tear each one off.
      final copies = await EscPosBuilder.buildCopies(job.receiptJson);
      final pause = Duration(seconds: EscPosBuilder.copyPauseSeconds(job.receiptJson));
      for (var i = 0; i < copies.length; i++) {
        if (i > 0) await Future<void>.delayed(pause);
        await printerService.printBytes(copies[i]);
      }

      job.status = PrintJobStatus.success;
      job.lastError = null;
      await _updateJob(job);
    } catch (e) {
      // StateError.toString() prefixes "Bad state: ", which then shows up in the backoffice.
      job.lastError = e is StateError ? e.message : e.toString();

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
    if (!jobs.contains(job)) jobs.add(job); // pruned mid-print: keep its outcome
    await _saveJobs(jobs);
    _jobUpdates.add(job);
  }

  /// The one job list every method mutates. Loaded once, then only changed
  /// synchronously after an await — never "load, await, save" — so a Reverb
  /// enqueue landing mid status-write can't overwrite it with a stale copy
  /// (that turned a printed job back into `printing`, which the next launch
  /// re-queued and printed again).
  List<PrintJob>? _jobs;
  Future<List<PrintJob>>? _loading;

  Future<List<PrintJob>> _loadJobs() async {
    if (_jobs != null) return _jobs!;
    return _loading ??= () async {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      return _jobs = raw == null
          ? <PrintJob>[]
          : (jsonDecode(raw) as List<dynamic>)
              .map((j) => PrintJob.fromJson(j as Map<String, dynamic>))
              .toList();
    }();
  }

  Future<void> _saveJobs(List<PrintJob> jobs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(jobs.map((j) => j.toJson()).toList()));
  }

  /// Failed jobs, newest first — the Gagal tab's data source.
  Future<List<PrintJob>> failedJobs() async {
    final jobs = await _loadJobs();
    return jobs.where((j) => j.status == PrintJobStatus.failed).toList().reversed.toList();
  }

  /// Dismisses a job from the Gagal tab. Server side it is already marked
  /// failed, so nothing else needs to know.
  Future<void> remove(String jobId) async {
    final jobs = await _loadJobs();
    jobs.removeWhere((j) => j.id == jobId);
    await _saveJobs(jobs);
  }

  /// Forgets every job — used when the device is reset/re-activated.
  Future<void> clear() async {
    final jobs = await _loadJobs();
    jobs.clear();
    await _saveJobs(jobs);
  }

  /// Call on app start. Drops successes, keeps the last [keepFailedCount]
  /// failures for a manual reprint, and keeps only *recent* unfinished work.
  ///
  /// Unfinished jobs older than [maxAge] are dropped: a shift that ended with a
  /// dead printer must not flush yesterday's backlog the next morning, and the
  /// server still has those jobs pending, so nothing is lost — a poll
  /// re-delivers anything that genuinely still needs printing. Jobs stuck in
  /// `printing` (app killed mid-print) are reset to `queued`, since nothing
  /// else ever retries that state.
  Future<void> pruneCompleted({
    int keepFailedCount = 20,
    Duration maxAge = const Duration(hours: 2),
  }) async {
    final jobs = await _loadJobs();

    final failed = jobs.where((j) => j.status == PrintJobStatus.failed).toList();
    final trimmedFailed = failed.length > keepFailedCount
        ? failed.sublist(failed.length - keepFailedCount)
        : failed;

    final unfinished = jobs
        .where((j) =>
            (j.status == PrintJobStatus.queued || j.status == PrintJobStatus.printing) &&
            _age(j) < maxAge)
        .map((j) => j..status = PrintJobStatus.queued)
        .toList();

    // Recent successes are kept, not dropped: they are what [enqueue] checks to
    // refuse printing a server job twice, so throwing them away on every launch
    // would reopen that hole for anything still pending on the server.
    final recentlyPrinted = jobs
        .where((j) => j.status == PrintJobStatus.success && _age(j) < maxAge)
        .toList();

    final kept = [...unfinished, ...recentlyPrinted, ...trimmedFailed];
    jobs
      ..clear()
      ..addAll(kept);
    await _saveJobs(jobs);
  }

  /// Ids are microsecond timestamps (see [enqueue]), so they double as a clock.
  static Duration _age(PrintJob job) {
    final us = int.tryParse(job.id);
    if (us == null) return Duration.zero;
    return DateTime.now().difference(DateTime.fromMicrosecondsSinceEpoch(us));
  }

  void dispose() {
    _jobUpdates.close();
  }
}