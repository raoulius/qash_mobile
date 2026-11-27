// The overlay used to flash once per queue event. These cases are the two
// real sequences that caused it: a poll returning several pending receipts,
// and a retry backoff putting a job back to `queued`.
import 'package:flutter_test/flutter_test.dart';
import 'package:qash_mobile/app/printer/print_queue.dart';
import 'package:qash_mobile/app/printer/printing_overlay.dart';

void main() {
  test('a burst of receipts stays printing, flashing success once at the end', () {
    final t = PrintingOverlayTracker();
    // Poll enqueues 3 jobs, then they print one after another.
    expect(t.onJob('a', PrintJobStatus.queued), PrintingOverlayState.printing);
    expect(t.onJob('b', PrintJobStatus.queued), PrintingOverlayState.printing);
    expect(t.onJob('c', PrintJobStatus.queued), PrintingOverlayState.printing);
    expect(t.onJob('a', PrintJobStatus.printing), PrintingOverlayState.printing);
    expect(t.onJob('a', PrintJobStatus.success), PrintingOverlayState.printing);
    expect(t.onJob('b', PrintJobStatus.printing), PrintingOverlayState.printing);
    expect(t.onJob('b', PrintJobStatus.success), PrintingOverlayState.printing);
    expect(t.onJob('c', PrintJobStatus.printing), PrintingOverlayState.printing);
    expect(t.onJob('c', PrintJobStatus.success), PrintingOverlayState.success);
  });

  test('a retry backoff does not drop the overlay', () {
    final t = PrintingOverlayTracker();
    t.onJob('a', PrintJobStatus.queued);
    expect(t.onJob('a', PrintJobStatus.printing), PrintingOverlayState.printing);
    // Attempt failed; the queue puts it back to queued until the backoff fires.
    expect(t.onJob('a', PrintJobStatus.queued), PrintingOverlayState.printing);
    expect(t.onJob('a', PrintJobStatus.printing), PrintingOverlayState.printing);
    expect(t.onJob('a', PrintJobStatus.success), PrintingOverlayState.success);
  });

  test('giving up hides the overlay instead of flashing success', () {
    final t = PrintingOverlayTracker();
    t.onJob('a', PrintJobStatus.queued);
    expect(t.onJob('a', PrintJobStatus.failed), PrintingOverlayState.hidden);
  });

  test('a job still printing keeps the overlay up when another one fails', () {
    final t = PrintingOverlayTracker();
    t.onJob('a', PrintJobStatus.printing);
    t.onJob('b', PrintJobStatus.queued);
    expect(t.onJob('a', PrintJobStatus.failed), PrintingOverlayState.printing);
    expect(t.onJob('b', PrintJobStatus.success), PrintingOverlayState.success);
  });
}
