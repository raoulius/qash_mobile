// The job-fetch acceptance checks, on fake time against a fake server that
// applies the real contract: 30 s lease, max 10 per poll, mark-printed.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qash_mobile/app/net.dart';
import 'package:qash_mobile/app/printer/bluetooth_service.dart';
import 'package:qash_mobile/app/printer/poll_service.dart';
import 'package:qash_mobile/app/printer/print_queue.dart';

class _Printer extends BluetoothPrinterService {
  PrinterConnectionState state = PrinterConnectionState.connected;
  PrinterDeviceInfo? device = PrinterDeviceInfo(name: 'fake', address: '00');
  @override
  PrinterConnectionState get currentState => state;
  @override
  PrinterDeviceInfo? get connectedDevice => device;
  @override
  Future<void> printBytes(Uint8List bytes) async {}
}

class _Server {
  final WidgetTester tester;
  _Server(this.tester);

  final pendingAt = <Duration>[]; // fake-clock time of each /pending call
  Uri? pendingUrl; // the last one
  int inFlight = 0, maxInFlight = 0;
  int status = 200;
  Map<String, String> headers = {};
  double markFailRate = 0;
  final _rng = Random(1);
  final _leasedUntil = <int, Duration>{};
  final printed = <int>{};
  final markPrintedCalls = <String>[];
  int _nextId = 1;

  Duration get now => tester.binding.clock.now().difference(_epoch);
  static final _epoch = DateTime(2000);

  int createJob() {
    final id = _nextId++;
    _leasedUntil[id] = Duration.zero;
    return id;
  }

  late final client = MockClient((req) async {
    final path = req.url.path;
    if (path.endsWith('/print-jobs/pending')) {
      pendingAt.add(now);
      pendingUrl = req.url;
      maxInFlight = max(maxInFlight, ++inFlight);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      inFlight--;
      if (status != 200) return http.Response('', status, headers: headers);
      final due = _leasedUntil.entries
          .where((e) => !printed.contains(e.key) && e.value <= now)
          .take(10)
          .map((e) => e.key)
          .toList();
      for (final id in due) {
        _leasedUntil[id] = now + const Duration(seconds: 30);
      }
      return http.Response(
          jsonEncode([
            for (final id in due)
              {
                'id': id,
                'job_type': 'test_print',
                'station_id': 'kitchen',
                'payload': {'station': 'kitchen'},
                'created_at': '',
              }
          ]),
          200);
    }
    final m = RegExp(r'/print-jobs/(\d+)/mark-printed$').firstMatch(path);
    if (m != null) {
      markPrintedCalls.add(m[1]!);
      if (_rng.nextDouble() < markFailRate) return http.Response('', 500);
      printed.add(int.parse(m[1]!));
      return http.Response('{"ok":true}', 200);
    }
    return http.Response('', 404);
  });

  /// Gaps between consecutive /pending calls, in whole seconds.
  List<int> gaps() => [
        for (var i = 1; i < pendingAt.length; i++)
          (pendingAt[i] - pendingAt[i - 1]).inMilliseconds ~/ 1000
      ];
}

/// Fake time, but with real time slices in between: EscPosBuilder loads its
/// capability profile through the asset bundle, which is real I/O.
Future<void> _advance(WidgetTester tester, Duration d) async {
  const step = Duration(milliseconds: 100);
  for (var t = Duration.zero; t < d; t += step) {
    await tester.pump(step);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
  }
}

PollService _poller(PrintQueue queue) => PollService(
      printQueue: queue,
      apiBaseUrl: 'https://t.example/api',
      stationId: 'kitchen',
      authToken: 'tok',
    );

void main() {
  late _Server server;
  late PrintQueue queue;
  late PollService poller;
  final original = httpClient;

  Future<void> setUpStation(WidgetTester tester, {Map<String, Object> prefs = const {}}) async {
    SharedPreferences.setMockInitialValues(prefs);
    rootBundle.clear(); // a cached asset load can belong to the last test's fake zone
    server = _Server(tester);
    httpClient = server.client;
    queue = PrintQueue(printerService: _Printer());
    poller = _poller(queue);
  }

  Future<void> tearDownStation(WidgetTester tester) async {
    poller.dispose();
    await tester.pump(const Duration(minutes: 1)); // let in-flight work drain
    httpClient = original;
  }

  testWidgets('idle station, socket up: ~20 polls in 10 minutes, never two in flight',
      (tester) async {
    await setUpStation(tester);
    poller.onPushSubscription(true);
    poller.start();
    poller.onJobsWaiting(); // backend proves it sends the event
    await tester.pump(const Duration(seconds: 1));
    final before = server.pendingAt.length;

    await tester.pump(const Duration(minutes: 10));

    expect(server.pendingAt.length - before, inInclusiveRange(19, 21));
    expect(server.maxInFlight, 1);
    await tearDownStation(tester);
  });

  testWidgets('older backend that never sends the event keeps 4 s polling', (tester) async {
    await setUpStation(tester);
    poller.onPushSubscription(true);
    poller.start();

    await tester.pump(const Duration(minutes: 1));

    expect(server.gaps().toSet(), {4});
    await tearDownStation(tester);
  });

  testWidgets('a new job is fetched and printed within ~1 s of the push', (tester) async {
    await setUpStation(tester);
    poller.onPushSubscription(true);
    poller.start();
    poller.onJobsWaiting();
    await tester.pump(const Duration(seconds: 5));
    final printed = <String>[];
    queue.jobUpdates.listen((j) {
      if (j.status == PrintJobStatus.success) printed.add(j.receiptJson['_serverJobId']);
    });

    final id = server.createJob();
    // A burst of events (and one arriving mid-fetch) must not stack fetches.
    for (var i = 0; i < 5; i++) {
      poller.onJobsWaiting();
      await tester.pump(const Duration(milliseconds: 20));
    }
    final calls = server.pendingAt.length;
    await _advance(tester, const Duration(milliseconds: 900));

    expect(server.pendingAt.length - calls, 1, reason: 'debounced to one fetch');
    expect(printed, ['$id']);
    expect(server.printed, {id});
    await tearDownStation(tester);
  });

  testWidgets('socket drop returns to 4 s within one cycle, 30 s after reconnect + event',
      (tester) async {
    await setUpStation(tester);
    poller.onPushSubscription(true);
    poller.start();
    poller.onJobsWaiting();
    await tester.pump(const Duration(seconds: 65));

    poller.onPushSubscription(false);
    var mark = server.pendingAt.length;
    await tester.pump(const Duration(seconds: 4, milliseconds: 100));
    expect(server.pendingAt.length - mark, 1, reason: 'no waiting out the 30 s timer');
    await tester.pump(const Duration(seconds: 20));
    expect(server.gaps().last, 4);

    mark = server.pendingAt.length;
    poller.onPushSubscription(true);
    await tester.pump(const Duration(milliseconds: 100));
    expect(server.pendingAt.length - mark, 1, reason: 'reconnect fetches immediately');
    poller.onJobsWaiting();
    await tester.pump(const Duration(minutes: 2));
    expect(server.gaps().last, 30);
    await tearDownStation(tester);
  });

  testWidgets('errors back off 4→60 s and reset on success; 429 honours Retry-After',
      (tester) async {
    await setUpStation(tester);
    server.status = 503;
    poller.start();
    await tester.pump(const Duration(minutes: 4));
    expect(server.gaps().take(6).toList(), [4, 8, 16, 32, 60, 60]);

    server.status = 429;
    server.headers = {'retry-after': '17'};
    await tester.pump(const Duration(minutes: 1, seconds: 30));
    expect(server.gaps().last, 17);

    server.status = 200;
    await tester.pump(const Duration(seconds: 30));
    expect(server.gaps().last, 4);
    await tearDownStation(tester);
  });

  testWidgets('every poll reports the printer; printer_name only while connected',
      (tester) async {
    await setUpStation(tester);
    final printer = queue.printerService as _Printer
      ..state = PrinterConnectionState.disconnected
      ..device = null;
    poller.start();
    await tester.pump(const Duration(milliseconds: 100));
    expect(server.pendingUrl!.queryParameters,
        {'station_id': 'kitchen', 'printer': 'disconnected'});

    printer
      ..state = PrinterConnectionState.connected
      ..device = PrinterDeviceInfo(name: 'RPP02N', address: '00');
    await tester.pump(const Duration(seconds: 4));
    expect(server.pendingUrl!.queryParameters,
        {'station_id': 'kitchen', 'printer': 'connected', 'printer_name': 'RPP02N'});
    await tearDownStation(tester);
  });

  testWidgets('401 stops polling for good', (tester) async {
    await setUpStation(tester);
    server.status = 401;
    var unauthorized = 0;
    final sub = deviceUnauthorized.stream.listen((_) => unauthorized++);
    poller.start();
    await tester.pump(const Duration(minutes: 5));

    expect(server.pendingAt.length, 1);
    expect(unauthorized, 1, reason: 'StationScreen shows the re-activate screen');
    sub.cancel(); // awaiting it on this global stream stalls fake time
    await tearDownStation(tester);
  });

  testWidgets('a second station instance or a repeated start() never adds a loop',
      (tester) async {
    await setUpStation(tester);
    poller.start();
    poller.start(); // resume / reconnect path calling start again
    final again = _poller(queue)..start(); // a rebuilt StationScreen
    await tester.pump(const Duration(minutes: 1));

    // The new loop queues behind the old one's request, fetches right after
    // it (the one back-to-back gap), then runs alone.
    expect(server.gaps().skip(1).toSet(), {4});
    expect(server.maxInFlight, 1);
    again.dispose();
    await tearDownStation(tester);
  });

  testWidgets('a job already printed is re-acknowledged, not reprinted', (tester) async {
    await setUpStation(tester, prefs: {
      'printer.printedJobIds': jsonEncode({'1': DateTime.now().millisecondsSinceEpoch}),
    });
    final id = server.createJob(); // id 1: printed before a restart, ack lost
    var prints = 0;
    queue.jobUpdates.listen((j) => prints++);
    poller.start();
    await tester.pump(const Duration(seconds: 1));

    expect(prints, 0);
    expect(server.markPrintedCalls, ['$id']);
    expect(server.printed, {id});
    await tearDownStation(tester);
  });

  testWidgets('50 orders with flaky acks and a restart mid-shift: zero double prints',
      (tester) async {
    await setUpStation(tester);
    server.markFailRate = 0.3; // acks lost → server re-offers after the lease
    final prints = <String, int>{};
    void count(PrintQueue q) => q.jobUpdates.listen((j) {
          if (j.status != PrintJobStatus.success) return;
          final id = j.receiptJson['_serverJobId'] as String;
          prints[id] = (prints[id] ?? 0) + 1;
        });
    count(queue);
    poller.onPushSubscription(true);
    poller.start();

    for (var i = 0; i < 50; i++) {
      server.createJob();
      if (i % 7 != 3) poller.onJobsWaiting(); // some pushes are lost
      await _advance(tester, const Duration(seconds: 3));
      if (i == 25) {
        // App killed and relaunched: new queue and poller, same storage.
        poller.dispose();
        queue.dispose();
        queue = PrintQueue(printerService: _Printer());
        count(queue);
        poller = _poller(queue)..start();
        poller.onPushSubscription(true);
      }
    }
    await _advance(tester, const Duration(minutes: 3));

    expect(prints.length, 50);
    expect(prints.values.where((n) => n > 1), isEmpty);
    expect(server.printed.length, 50, reason: 'every job eventually acknowledged');
    expect(server.markPrintedCalls.length, greaterThan(50), reason: 'lost acks were re-offered');
    await tearDownStation(tester);
  });
}
