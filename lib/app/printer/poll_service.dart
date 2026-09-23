// poll_service.dart
//
// The new "trigger" for printing in the headless print-station model.
// Replaces the old WebView + bridge approach: instead of an in-app UI
// asking to print, this service asks Laravel "any receipts waiting?" on
// a timer, and feeds whatever comes back into the SAME PrintQueue you
// already built. Nothing downstream of PrintQueue changed.
//
// WHY POLLING, NOT A WEBSOCKET: a phone that sleeps/backgrounds can't
// reliably hold an open socket — the OS suspends it. A poll is a fresh
// short HTTP request each time, which survives sleep/wake far better:
// miss a few while asleep, catch up on the next one when foregrounded.
//
// V1 ASSUMPTION: the app is foregrounded during a shift. While
// backgrounded/asleep, the timer pauses (the OS suspends it) and
// resumes on return — jobs are NOT lost because they stay 'pending' in
// Laravel until acknowledged, they just wait until the app is active.
//
// SAFETY MODEL: a job is only removed from Laravel's pending list after
// THIS service confirms a successful print and calls markPrinted. If the
// print fails or the app dies mid-job, the job stays pending and is
// retried on a later poll. That's why printing must be idempotent-ish on
// the Laravel side (mark-printed is the commit point).

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../net.dart';
import 'bluetooth_service.dart';
import 'print_queue.dart';

class PollService {
  final BluetoothPrinterService printerService;
  final PrintQueue printQueue;

  /// Base URL of your Laravel API, e.g. 'https://your-domain.com/api'.
  final String apiBaseUrl;

  /// Identifies WHICH print station this is, so Laravel only hands this
  /// phone the jobs meant for it. Set once per device (e.g. "counter-1").
  final String stationId;

  /// Bearer token for authenticating to Laravel (Sanctum). See note in
  /// _headers below.
  final String authToken;

  /// How often to ask Laravel for pending jobs. 3-5s is a good balance:
  /// fast enough that receipts feel near-instant, slow enough that you're
  /// not hammering the server.
  final Duration pollInterval;

  Timer? _timer;
  StreamSubscription<PrintJob>? _jobSub;
  bool _polling = false; // guards against overlapping polls if one is slow

  final _statusController = StreamController<String>.broadcast();

  /// Optional: surface human-readable status to a tiny on-screen indicator
  /// ("idle", "printing 1 receipt", "offline") so the cashier can glance
  /// at the station and know it's alive.
  Stream<String> get status => _statusController.stream;

  PollService({
    required this.printerService,
    required this.printQueue,
    required this.apiBaseUrl,
    required this.stationId,
    required this.authToken,
    this.pollInterval = const Duration(seconds: 4),
  });

  void start() {
    _timer?.cancel();
    // Every terminal state — including a reprint of an old failure from the
    // Gagal tab — is reported to Laravel from here, so the server's view of a
    // job tracks what actually came out of the printer.
    _jobSub ??= printQueue.jobUpdates.listen((job) {
      final serverId = job.receiptJson['_serverJobId']?.toString();
      if (serverId == null) return;
      if (job.status == PrintJobStatus.success) {
        // Never silently: an acknowledgement that keeps failing is exactly what
        // makes the server re-offer a printed job forever.
        _markPrinted(serverId)
            .catchError((e) => _emit('printed, but ack failed: $e'));
      } else if (job.status == PrintJobStatus.failed) {
        _markFailed(serverId, job.lastError)
            .catchError((e) => _emit('failed, but ack failed: $e'));
      }
    });
    // Poll once immediately, then on the interval — so the first receipt
    // after launch doesn't wait a full interval.
    _poll();
    _timer = Timer.periodic(pollInterval, (_) => _poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $authToken',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

  Future<void> _poll() async {
    if (_polling) return; // previous poll still running; skip this tick
    _polling = true;
    try {
      final jobs = await _fetchPendingJobs();
      if (jobs.isEmpty) {
        _emit('idle');
        return;
      }

      _emit('printing ${jobs.length} receipt(s)');

      for (final job in jobs) {
        final jobId = job['id'].toString();
        // Merge job_type so EscPosBuilder can dispatch to the right template
        final receiptJson = {
          '_jobType': job['job_type'] as String? ?? '',
          '_serverJobId': jobId,
          ...job['payload'] as Map<String, dynamic>,
        };

        final localJobId = await printQueue.enqueue(receiptJson);

        // The queue refuses to print a server job it has already printed, so a
        // re-offer means the acknowledgement is what went missing, not the
        // print. Re-send it and move on instead of waiting on a job that will
        // never emit another event.
        // Also guards a race: a job can reach a terminal state before
        // _awaitJobResult attaches its listener, and that listener is the only
        // thing it waits on — so it would block for its full timeout and report
        // nothing, which is how a printed job kept its pending row.
        switch (await printQueue.statusOf(localJobId)) {
          case PrintJobStatus.success:
            await _markPrinted(jobId);
            continue;
          case PrintJobStatus.failed:
            continue; // the jobUpdates listener already reported it
          default:
            break;
        }

        // Print jobs one at a time; the jobUpdates listener in start() does
        // the mark-printed / mark-failed call for this job's terminal state.
        await _awaitJobResult(localJobId);
      }
    } catch (e) {
      // Network down, server error, auth expired, etc. Stay quiet and try
      // again next tick — transient failures are normal on a phone.
      _emit('offline (will retry)');
    } finally {
      _polling = false;
    }
  }

  /// GET /print-jobs/pending?station_id=...
  /// Laravel returns a flat JSON array: [ { "id": 123, "payload": {...}, ... }, ... ]
  Future<List<Map<String, dynamic>>> _fetchPendingJobs() async {
    final uri = Uri.parse('$apiBaseUrl/print-jobs/pending')
        .replace(queryParameters: {'station_id': stationId});

    final res = await sendNoRedirect(http.Request('GET', uri)..headers.addAll(_headers))
        .timeout(const Duration(seconds: 10));

    if (res.statusCode != 200) {
      throw HttpException('pending fetch failed: ${res.statusCode}');
    }

    final body = jsonDecode(res.body) as List<dynamic>;
    return body.cast<Map<String, dynamic>>();
  }

  /// POST /print-jobs/{id}/mark-printed
  /// The commit point: only called after a confirmed successful print.
  Future<void> _markPrinted(String jobId) async {
    final uri = Uri.parse('$apiBaseUrl/print-jobs/$jobId/mark-printed');
    final res = await sendNoRedirect(http.Request('POST', uri)..headers.addAll(_headers))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      // If this fails, the job stays pending and may print again on the
      // next poll — a duplicate receipt is annoying but far better than a
      // missing one. If duplicates matter, add an idempotency guard here.
      throw HttpException('mark-printed failed: ${res.statusCode}');
    }
  }

  /// POST /print-jobs/{id}/mark-failed
  /// Called after the queue gives up (3 attempts). Without this the job stays
  /// pending server-side and is re-fetched on every lease expiry forever.
  /// Reprint later from the Gagal tab; a success there marks it printed.
  Future<void> _markFailed(String jobId, String? error) async {
    final uri = Uri.parse('$apiBaseUrl/print-jobs/$jobId/mark-failed');
    final req = http.Request('POST', uri)
      ..headers.addAll(_headers)
      ..body = jsonEncode({'error': error ?? 'print failed'});
    final res = await sendNoRedirect(req).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw HttpException('mark-failed failed: ${res.statusCode}');
    }
  }

  /// Listens to PrintQueue.jobUpdates until the given local job reaches a
  /// terminal state (success or failed), returning true on success.
  Future<bool> _awaitJobResult(String localJobId) {
    final completer = Completer<bool>();
    late StreamSubscription sub;

    sub = printQueue.jobUpdates.listen((job) {
      if (job.id != localJobId) return;
      if (job.status == PrintJobStatus.success) {
        if (!completer.isCompleted) completer.complete(true);
        sub.cancel();
      } else if (job.status == PrintJobStatus.failed) {
        if (!completer.isCompleted) completer.complete(false);
        sub.cancel();
      }
    });

    // Safety timeout so a stuck job can't hang the poll loop forever.
    Future.delayed(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        completer.complete(false);
        sub.cancel();
      }
    });

    return completer.future;
  }

  bool _disposed = false;

  /// A poll still in flight when the station is reset must not write to the
  /// closed controller.
  void _emit(String s) {
    if (!_disposed) _statusController.add(s);
  }

  void dispose() {
    _disposed = true;
    stop();
    _jobSub?.cancel();
    _statusController.close();
  }
}

class HttpException implements Exception {
  final String message;
  HttpException(this.message);
  @override
  String toString() => 'HttpException: $message';
}
