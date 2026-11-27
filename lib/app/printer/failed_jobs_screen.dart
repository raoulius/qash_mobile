// failed_jobs_screen.dart
//
// "Gagal" tab: the print jobs the queue gave up on (kept locally, newest
// first) with a reprint button. Reprint re-enqueues the cached payload; the
// poll service reports the outcome to Laravel.

import 'dart:async';
import 'package:flutter/material.dart';
import 'print_queue.dart';

class FailedJobsScreen extends StatefulWidget {
  final PrintQueue printQueue;

  const FailedJobsScreen({super.key, required this.printQueue});

  @override
  State<FailedJobsScreen> createState() => _FailedJobsScreenState();
}

class _FailedJobsScreenState extends State<FailedJobsScreen> {
  List<PrintJob> _jobs = const [];
  StreamSubscription<PrintJob>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = widget.printQueue.jobUpdates.listen((_) => _load());
  }

  Future<void> _load() async {
    final jobs = await widget.printQueue.failedJobs();
    if (mounted) setState(() => _jobs = jobs);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gagal cetak')),
      body: _jobs.isEmpty
          ? const Center(child: Text('Tidak ada struk yang gagal.'))
          : ListView.separated(
              itemCount: _jobs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final job = _jobs[i];
                return ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: Text(_title(job)),
                  subtitle: Text('${_when(job)} — ${job.lastError?.replaceFirst('Bad state: ', '') ?? 'gagal'}', maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.print),
                        tooltip: 'Cetak ulang',
                        onPressed: () => _reprint(job),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Hapus',
                        onPressed: () => _remove(job),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Future<void> _reprint(PrintJob job) async {
    await widget.printQueue.reprint(job.id);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('${_title(job)} dicetak ulang')));
  }

  /// Already reported failed to the server; this only clears the local list.
  Future<void> _remove(PrintJob job) async {
    await widget.printQueue.remove(job.id);
    await _load();
  }

  static String _title(PrintJob job) {
    final p = job.receiptJson;
    final header = p['header'] is Map ? p['header'] as Map : const {};
    final type = switch (p['_jobType']) {
      'kitchen_ticket' => 'Dapur',
      'waiter_ticket' => 'Pelayan',
      'table_qr' => 'QR Meja',
      'session_open' => 'Buka sesi',
      'session_close' => 'Tutup sesi',
      'test_print' => 'Tes cetak',
      _ => 'Struk',
    };
    final ref = header['orderNumber'] ?? p['tableName'] ?? header['tableNumber'];
    return ref == null ? type : '$type #$ref';
  }

  /// Job ids are microsecond timestamps (see PrintQueue.enqueue).
  static String _when(PrintJob job) {
    final us = int.tryParse(job.id);
    if (us == null) return '';
    final t = DateTime.fromMicrosecondsSinceEpoch(us);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.day)}/${two(t.month)} ${two(t.hour)}:${two(t.minute)}';
  }
}
