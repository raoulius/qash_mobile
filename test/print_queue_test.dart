// Covers the two queue faults behind a runaway print: the poll re-delivering
// a job it had already queued, and a stale backlog surviving to the next shift.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qash_mobile/app/printer/bluetooth_service.dart';
import 'package:qash_mobile/app/printer/print_queue.dart';

const _key = 'printer.jobQueue';

Map<String, dynamic> _job(String id, String status, {String? serverId, int attempts = 0}) => {
      'id': id,
      'receiptJson': {
        '_jobType': 'customer_receipt',
        if (serverId != null) '_serverJobId': serverId,
      },
      'status': status,
      'attempts': attempts,
      'lastError': null,
    };

String _idAgedHours(int hours) =>
    (DateTime.now().subtract(Duration(hours: hours)).microsecondsSinceEpoch).toString();

Future<void> _seed(List<Map<String, dynamic>> jobs) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_key, jsonEncode(jobs));
}

Future<List<dynamic>> _stored() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return jsonDecode(prefs.getString(_key) ?? '[]') as List<dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a re-delivered server job reuses the queued copy instead of adding one', () async {
    await _seed([_job('1', 'queued', serverId: '80')]);
    final queue = PrintQueue(printerService: BluetoothPrinterService());

    final id = await queue.enqueue({'_jobType': 'customer_receipt', '_serverJobId': '80'});

    expect(id, '1');
    final stored = await _stored();
    expect(stored.where((j) => j['receiptJson']['_serverJobId'] == '80').length, 1);
  });

  test('a different server job is still queued', () async {
    await _seed([_job('1', 'queued', serverId: '80')]);
    final queue = PrintQueue(printerService: BluetoothPrinterService());

    final id = await queue.enqueue({'_jobType': 'customer_receipt', '_serverJobId': '81'});

    expect(id, isNot('1'));
  });

  test('a job that already failed can be reprinted, not deduped away', () async {
    await _seed([_job('1', 'failed', serverId: '80', attempts: 3)]);
    final queue = PrintQueue(printerService: BluetoothPrinterService());

    final id = await queue.enqueue({'_jobType': 'customer_receipt', '_serverJobId': '80'});

    expect(id, isNot('1'));
  });

  test('a server job already printed is never printed again', () async {
    await _seed([_job('1', 'success', serverId: '80', attempts: 1)]);
    final queue = PrintQueue(printerService: BluetoothPrinterService());

    // The poll re-offers it because the acknowledgement never landed.
    final id = await queue.enqueue({'_jobType': 'kitchen_ticket', '_serverJobId': '80'});

    expect(id, '1');
    expect(await queue.statusOf(id), PrintJobStatus.success,
        reason: 'poll should re-acknowledge, not reprint');
    expect((await _stored()).length, 1);
  });

  test('an explicit reprint overrides the already-printed guard', () async {
    await _seed([_job('1', 'success', serverId: '80', attempts: 1)]);
    final queue = PrintQueue(printerService: BluetoothPrinterService());

    await queue.reprint('1');

    expect((await _stored()).length, 2);
  });

  test('pruning keeps recent successes so the guard survives a restart', () async {
    await _seed([_job(_idAgedHours(1), 'success', serverId: '80', attempts: 1)]);
    final queue = PrintQueue(printerService: BluetoothPrinterService());

    await queue.pruneCompleted();

    final stored = await _stored();
    expect(stored.length, 1, reason: 'dropping it would let a pending job reprint');
  });

  test('pruning drops a stale backlog, keeps recent work, revives stuck prints', () async {
    final stale = _idAgedHours(5);
    final recent = _idAgedHours(1);
    final stuck = _idAgedHours(1);
    await _seed([
      _job(stale, 'queued', serverId: '80'),
      _job(recent, 'queued', serverId: '81'),
      _job(stuck, 'printing', serverId: '82'),
      _job(_idAgedHours(5), 'success', serverId: '83'),
    ]);
    final queue = PrintQueue(printerService: BluetoothPrinterService());

    await queue.pruneCompleted();

    final stored = await _stored();
    final ids = stored.map((j) => j['id']).toList();
    expect(ids, isNot(contains(stale)), reason: 'yesterday must not print today');
    expect(ids, contains(recent));
    expect(ids, contains(stuck));
    expect(stored.length, 2, reason: 'the stale queued job and the old success are dropped');
    expect(
      stored.firstWhere((j) => j['id'] == stuck)['status'],
      'queued',
      reason: 'nothing retries a job left in printing',
    );
  });

  test('failures are kept for the Gagal tab', () async {
    await _seed([_job(_idAgedHours(5), 'failed', serverId: '80', attempts: 3)]);
    final queue = PrintQueue(printerService: BluetoothPrinterService());

    await queue.pruneCompleted();

    expect((await queue.failedJobs()).length, 1);
  });

  test('concurrent enqueues from poll and push both survive', () async {
    await _seed([]);
    final queue = PrintQueue(printerService: BluetoothPrinterService());

    // Poll and Reverb deliver different jobs in the same instant; a
    // load-await-save queue kept only whichever wrote last.
    await Future.wait([
      queue.enqueue({'_jobType': 'kitchen_ticket', '_serverJobId': '90'}),
      queue.enqueue({'_jobType': 'kitchen_ticket', '_serverJobId': '91'}),
    ]);

    final ids = (await _stored()).map((j) => j['receiptJson']['_serverJobId']).toSet();
    expect(ids, {'90', '91'});
  });

  test('remove dismisses a failed job', () async {
    await _seed([_job('1', 'failed', serverId: '80', attempts: 3)]);
    final queue = PrintQueue(printerService: BluetoothPrinterService());

    await queue.remove('1');

    expect(await queue.failedJobs(), isEmpty);
    expect(await _stored(), isEmpty);
  });
}
