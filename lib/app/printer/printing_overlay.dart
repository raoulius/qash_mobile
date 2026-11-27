// printing_overlay.dart
//
// Full-screen animation shown while a print job is in flight: a receipt
// feeding out of a printer. Purely presentational — driven by the
// PrintJobStatus stream in main.dart, not by its own timers, so it always
// reflects how long the real print actually took.

import 'package:flutter/material.dart';
import 'print_queue.dart';

enum PrintingOverlayState { hidden, printing, success }

/// Decides what the overlay shows across a whole burst of jobs.
///
/// Driven by raw PrintQueue events the overlay flashed once per event: a poll
/// that returns several pending receipts ran a full show/flash/hide cycle per
/// receipt, and a retry — which puts a job back to `queued` between attempts —
/// re-triggered the animation on every backoff. Here a job counts as in flight
/// from its first event until it succeeds or fails, so the overlay stays up for
/// the whole burst and flashes success once, at the end.
class PrintingOverlayTracker {
  final _inFlight = <String>{};
  bool _lastSucceeded = false;

  /// The state the overlay should be in after [status] for [jobId].
  PrintingOverlayState onJob(String jobId, PrintJobStatus status) {
    switch (status) {
      case PrintJobStatus.queued:
      case PrintJobStatus.printing:
        _inFlight.add(jobId);
      case PrintJobStatus.success:
        _inFlight.remove(jobId);
        _lastSucceeded = true;
      case PrintJobStatus.failed:
        _inFlight.remove(jobId);
        _lastSucceeded = false;
    }

    if (_inFlight.isNotEmpty) return PrintingOverlayState.printing;
    return _lastSucceeded ? PrintingOverlayState.success : PrintingOverlayState.hidden;
  }
}

class PrintingOverlay extends StatefulWidget {
  final PrintingOverlayState state;

  const PrintingOverlay({super.key, required this.state});

  @override
  State<PrintingOverlay> createState() => _PrintingOverlayState();
}

class _PrintingOverlayState extends State<PrintingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _feed = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _feed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.state != PrintingOverlayState.hidden;
    return IgnorePointer(
      ignoring: !active,
      child: AnimatedOpacity(
        opacity: active ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.97),
          child: SizedBox.expand(
            child: Center(
              child: widget.state == PrintingOverlayState.success
                  ? const _PrintedCheck(key: ValueKey('success'))
                  : AnimatedBuilder(
                      key: const ValueKey('printing'),
                      animation: _feed,
                      builder: (context, _) => _PrinterFeed(t: _feed.value),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Printer body with a receipt sliding out beneath it, looping while [t]
/// (0..1, from the repeating AnimationController) advances.
class _PrinterFeed extends StatelessWidget {
  final double t;

  const _PrinterFeed({required this.t});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Feed length ramps 0->1 over the first 70% of the loop, then holds
    // briefly and snaps back — reads as "one receipt, then the next".
    final feed = Curves.easeOut.transform((t / 0.7).clamp(0.0, 1.0));
    const maxReceiptHeight = 180.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 160,
          height: 60,
          decoration: BoxDecoration(
            color: scheme.primary,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.print, color: scheme.onPrimary, size: 32),
        ),
        ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: feed,
            child: Container(
              width: 130,
              height: maxReceiptHeight,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Column(
                children: List.generate(
                  6,
                  (i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Container(
                      height: 4,
                      width: i.isEven ? double.infinity : 70,
                      color: scheme.outlineVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),
        Text('Mencetak struk…', style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }
}

class _PrintedCheck extends StatelessWidget {
  const _PrintedCheck({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle, color: scheme.primary, size: 80),
        const SizedBox(height: 16),
        Text('Tercetak!', style: Theme.of(context).textTheme.titleLarge),
      ],
    );
  }
}
