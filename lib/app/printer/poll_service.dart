// poll_service.dart
//
// The ONLY way this app gets print jobs: GET /print-jobs/pending, then feed the
// result into PrintQueue. Reverb (reverb_service.dart) never carries a job; its
// `print.jobs-waiting` event only makes this fetch run now instead of at the
// next tick. Printing a pushed payload as well as the polled copy is what
// printed one job twice on 2026-09-15.
//
// CADENCE: one self-rescheduling timer; the next fetch is planned only after
// the previous one finishes, so two /pending requests are never in flight.
// - socket subscribed and the backend has sent `print.jobs-waiting` this
//   session: every 30 s (keeps the 120 s heartbeat, covers a missed push)
// - otherwise (socket down, or an older backend that never sends it): every 4 s
// - network error / 5xx: 4 s doubling to 60 s; 429: Retry-After; 401: stop
//
// BACKGROUND: on Android the StationService foreground service keeps the
// process (and this timer) alive when the app is backgrounded. On iOS the
// timer pauses while backgrounded and resumes on return — jobs are NOT lost
// because they stay 'pending' in Laravel until acknowledged.
//
// SAFETY MODEL: a job is only removed from Laravel's pending list after THIS
// service confirms a successful print and calls markPrinted. If the print
// fails or the app dies mid-job, the job stays pending and is re-offered when
// its 30 s lease runs out. A re-offer of a job this device already printed is
// re-acknowledged, never reprinted (PrintedJobIds below).

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../net.dart';
import 'print_queue.dart';

class PollService {
  static const fastInterval = Duration(seconds: 4);
  static const slowInterval = Duration(seconds: 30);
  static const maxBackoff = Duration(seconds: 60);
  static const wakeDebounce = Duration(milliseconds: 300);

  /// The one running loop in this isolate. Starting another stops this one, so
  /// a second StationScreen or a repeated start() can never poll alongside it.
  static PollService? _active;

  final PrintQueue printQueue;

  /// Absolute tenant API root from the server, e.g.
  /// 'https://demo-cafe.withqash-demo.tech/api'.
  final String apiBaseUrl;

  /// Identifies WHICH print station this is, so Laravel only hands this
  /// phone the jobs meant for it.
  final String stationId;

  /// Bearer token for authenticating to Laravel.
  final String authToken;

  final _printed = PrintedJobIds();

  /// Shared by every instance: the last request of a loop that was just
  /// replaced may still be out, and the new loop must queue behind it.
  static bool _fetching = false;

  Timer? _next;
  Timer? _debounce;
  bool _running = false;
  bool _fetchAgain = false; // a wake-up arrived mid-fetch
  bool _subscribed = false;
  bool _pushSeen = false; // backend proved it sends print.jobs-waiting
  int _failures = 0;
  Duration? _retryAfter;
  StreamSubscription<PrintJob>? _jobSub;
  StreamSubscription<void>? _printerSub;

  final _statusController = StreamController<String>.broadcast();

  /// Human-readable status for the station screen ("Menunggu struk", ...).
  Stream<String> get status => _statusController.stream;

  PollService({
    required this.printQueue,
    required this.apiBaseUrl,
    required this.stationId,
    required this.authToken,
  });

  void start() {
    if (_active != this) _active?.stop();
    _active = this;
    _running = true;
    // Every terminal state — including a reprint of an old failure from the
    // Gagal tab — is reported to Laravel from here, so the server's view of a
    // job tracks what actually came out of the printer.
    _jobSub ??= printQueue.jobUpdates.listen((job) {
      final serverId = job.receiptJson['_serverJobId']?.toString();
      if (serverId == null) return;
      if (job.status == PrintJobStatus.success) {
        _printed.add(serverId);
        // Never silently: an acknowledgement that keeps failing is exactly what
        // makes the server re-offer a printed job forever.
        _markPrinted(serverId)
            .catchError((e) => _emit('Tercetak, tapi gagal lapor ke server'));
      } else if (job.status == PrintJobStatus.failed) {
        _markFailed(serverId, job.lastError)
            .catchError((e) => _emit('Gagal cetak, dan gagal lapor ke server'));
      }
    });
    // Report a printer change now rather than at the next (up to 30 s) poll.
    _printerSub ??= printQueue.printerService.connectionState.listen((_) => _wake());
    _fetchNow();
  }

  void stop() {
    _running = false;
    _next?.cancel();
    _debounce?.cancel();
    if (_active == this) _active = null;
  }

  /// ReverbService: the station channel subscription came up or went away.
  void onPushSubscription(bool subscribed) {
    if (subscribed == _subscribed) return;
    _subscribed = subscribed;
    if (subscribed) {
      _fetchNow(); // whatever was created while the socket was down
    } else {
      _schedule(); // back to 4 s now, not after the 30 s already waiting
    }
  }

  /// ReverbService: `print.jobs-waiting` arrived. It carries no job — fetch.
  void onJobsWaiting() {
    _pushSeen = true;
    _wake();
  }

  void _wake() {
    _debounce?.cancel();
    _debounce = Timer(wakeDebounce, _fetchNow);
  }

  void _fetchNow() {
    if (!_running) return;
    if (_fetching) {
      _fetchAgain = true;
      return;
    }
    _next?.cancel();
    _run();
  }

  Future<void> _run() async {
    _fetching = true;
    try {
      await _poll();
    } catch (e) {
      _failures++; // never let one bad response end the loop
      _emit('Offline — mencoba lagi');
    } finally {
      _fetching = false;
    }
    final loop = _active; // this loop, or the one that replaced it meanwhile
    if (loop == null) return;
    if (loop._fetchAgain) {
      loop._fetchAgain = false;
      loop._fetchNow();
    } else {
      loop._schedule();
    }
  }

  void _schedule() {
    _next?.cancel();
    if (!_running || _fetching) return; // _run schedules once the fetch ends
    _next = Timer(_delay(), _fetchNow);
  }

  Duration _delay() {
    if (_retryAfter != null) return _retryAfter!;
    if (_failures > 0) {
      final s = fastInterval.inSeconds * pow(2, min(_failures - 1, 5));
      return Duration(seconds: min(s.toInt(), maxBackoff.inSeconds));
    }
    return _subscribed && _pushSeen ? slowInterval : fastInterval;
  }

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $authToken',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

  Future<void> _poll() async {
    _retryAfter = null;
    final List<Map<String, dynamic>> jobs;
    try {
      // Every poll reports the printer link; the backoffice shows "Printer
      // tidak terhubung" for anything but connected. Older servers ignore it.
      final printer = printQueue.printerService;
      final printerName = printer.connectedDevice?.name;
      final uri = Uri.parse('$apiBaseUrl/print-jobs/pending').replace(queryParameters: {
        'station_id': stationId,
        'printer': printer.currentState.name,
        if (printerName != null) 'printer_name': printerName,
      });
      final res = await sendNoRedirect(http.Request('GET', uri)..headers.addAll(_headers))
          .timeout(const Duration(seconds: 10));
      switch (res.statusCode) {
        case 200:
          jobs = (jsonDecode(res.body) as List<dynamic>).cast<Map<String, dynamic>>();
        case 401:
          // sendNoRedirect already raised deviceUnauthorized; StationScreen
          // swaps to the re-activate screen. Polling again can't help.
          stop();
          _emit('Perangkat tidak terdaftar — aktivasi ulang');
          return;
        case 429:
          final s = int.tryParse(res.headers['retry-after'] ?? '');
          if (s != null) {
            _retryAfter = Duration(seconds: s);
          } else {
            _failures++;
          }
          _emit('Server sibuk — mencoba lagi');
          return;
        default:
          throw HttpException('pending fetch failed: ${res.statusCode}');
      }
    } catch (e) {
      // Network down, 5xx, timeout — transient on a phone; back off.
      _failures++;
      _emit('Offline — mencoba lagi');
      return;
    }
    _failures = 0;

    if (jobs.isEmpty) {
      _emit('Menunggu struk');
      return;
    }
    _emit('Mencetak ${jobs.length} struk');

    for (final job in jobs) {
      final jobId = job['id'].toString();
      // Printed before; the acknowledgement is what got lost. Re-send it.
      if (await _printed.contains(jobId)) {
        _markPrinted(jobId).catchError((e) => _emit('Tercetak, tapi gagal lapor ke server'));
        continue;
      }
      final payload = job['payload'];
      if (payload is! Map<String, dynamic>) continue; // malformed: don't block the rest
      // Merge job_type so EscPosBuilder can dispatch to the right template.
      final localJobId = await printQueue.enqueue({
        '_jobType': job['job_type'] as String? ?? '',
        '_serverJobId': jobId,
        ...payload,
      });
      // The queue also refuses to reprint a server job it still holds as
      // printed (the jobUpdates listener may not have recorded it yet).
      // Anything else is left to the queue; the jobUpdates listener reports
      // its outcome, and a re-offer after the lease dedupes on the server id.
      if (await printQueue.statusOf(localJobId) == PrintJobStatus.success) {
        _markPrinted(jobId).catchError((e) => _emit('Tercetak, tapi gagal lapor ke server'));
      }
    }
  }

  /// POST /print-jobs/{id}/mark-printed
  /// The commit point: only called after a confirmed successful print.
  Future<void> _markPrinted(String jobId) async {
    final uri = Uri.parse('$apiBaseUrl/print-jobs/$jobId/mark-printed');
    final res = await sendNoRedirect(http.Request('POST', uri)..headers.addAll(_headers))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      // The job stays pending and is re-offered after its lease; PrintedJobIds
      // turns that into another acknowledgement, not another print.
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
    _printerSub?.cancel();
    _statusController.close();
  }
}

/// Server job ids this device printed in the last 24 h (newest 500), persisted.
/// The server re-offers a job whose mark-printed never landed for up to 6 h,
/// across app restarts that prune the queue's own copy, so this is the set
/// that turns a re-offer into a re-acknowledgement instead of a second print.
class PrintedJobIds {
  static const _prefsKey = 'printer.printedJobIds';
  static const _max = 500;
  static const _ttl = Duration(hours: 24);

  Map<String, int>? _ids; // server job id -> printed at (ms since epoch), oldest first
  Future<Map<String, int>>? _loading;

  Future<Map<String, int>> _load() async {
    if (_ids != null) return _ids!;
    return _loading ??= () async {
      final raw = (await SharedPreferences.getInstance()).getString(_prefsKey);
      return _ids = raw == null
          ? <String, int>{}
          : Map<String, int>.from(jsonDecode(raw) as Map<String, dynamic>);
    }();
  }

  Future<bool> contains(String id) async => (await _load()).containsKey(id);

  Future<void> add(String id) async {
    final ids = await _load();
    final now = DateTime.now().millisecondsSinceEpoch;
    ids
      ..remove(id)
      ..[id] = now
      ..removeWhere((_, t) => now - t > _ttl.inMilliseconds);
    while (ids.length > _max) {
      ids.remove(ids.keys.first);
    }
    await (await SharedPreferences.getInstance()).setString(_prefsKey, jsonEncode(ids));
  }
}

class HttpException implements Exception {
  final String message;
  HttpException(this.message);
  @override
  String toString() => 'HttpException: $message';
}
