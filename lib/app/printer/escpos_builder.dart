// escpos_builder.dart
//
// Turns a Laravel print-job payload into ESC/POS bytes. Every job carries
// `payload.template` (see ReceiptTemplate::toPayload on the server): paper
// width, copies, logo, header/footer lines and the show.* toggles the
// merchant set in the backoffice. This file honours that descriptor; it
// knows nothing about Bluetooth or the queue.
//
// Payload contracts: app/Services/Print/*PayloadBuilder.php and
// resources/views/print/*.blade.php on the server. The backoffice preview
// (resources/views/components/receipt-preview.blade.php) is the visual spec.
//
// Labels are Indonesian by product decision.

import 'dart:math' as math;
import 'dart:typed_data';
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

class EscPosBuilder {
  /// Blank lines fed after the last printed line so it clears the tear bar.
  /// Hardware knob: the RPP02N tear bar sits about 3 lines above the head.
  /// Raise it if the footer gets torn, lower it if paper is wasted.
  static const tearFeedLines = 3;

  /// Cap on logo height in printer dots (~15mm at 203dpi). Hardware knob: the
  /// backoffice preview bounds the logo by height and lets width follow, so
  /// scaling to the paper's full width here printed a square logo 60mm tall.
  static const logoMaxHeightDots = 120;

  // ponytail: in-memory logo cache keyed by URL; add disk cache if the
  // station reboots often and logo downloads get noticeable.
  static final Map<String, img.Image?> _logoCache = {};

  /// The whole job as one byte stream, every copy back to back.
  static Future<Uint8List> buildFromJobPayload(Map<String, dynamic> payload) async =>
      Uint8List.fromList([for (final copy in await buildCopies(payload)) ...copy]);

  /// Seconds PrintQueue waits between copies so the last one can be torn off
  /// (0 when the printer cuts by itself or there is a single copy).
  static int copyPauseSeconds(Map<String, dynamic> payload) {
    final tpl = _Template.from(payload['template']);
    return tpl.copies > 1 && !tpl.autoCut ? tpl.copyPauseSeconds : 0;
  }

  /// Entry point used by PrintQueue: one byte stream per copy, so a printer
  /// without a cutter gets a tear line and a pause between them. Payload must
  /// contain `_jobType`.
  static Future<List<Uint8List>> buildCopies(Map<String, dynamic> payload) async {
    final tpl = _Template.from(payload['template']);
    final profile = await CapabilityProfile.load();
    final g = Generator(tpl.paper, profile);
    final jobType = payload['_jobType'] as String? ?? '';
    final logo = await _logo(tpl);

    final body = switch (jobType) {
      'kitchen_ticket' || 'waiter_ticket' => _ticket(g, payload, tpl, jobType),
      'table_qr' => _tableQr(g, payload, tpl),
      'session_open' => _sessionOpen(g, payload, tpl),
      'session_close' => _sessionClose(g, payload, tpl),
      'test_print' => _testPrint(g, payload, tpl),
      _ => _receipt(g, payload, tpl),
    };

    // Session slips carry the outlet under `outlet`, everything else under `header`.
    final header = jobType.startsWith('session_')
        ? {'outletName': _map(payload['outlet'])['name'], 'outletAddress': _map(payload['outlet'])['address']}
        : _map(payload['header']);
    return [
      for (var i = 1; i <= tpl.copies; i++)
        Uint8List.fromList([
          ..._top(g, tpl, logo, header),
          ...body,
          ..._bottom(g, tpl),
          // Which copy this is, and where to tear when the printer cannot cut.
          if (tpl.copies > 1) ...g.text('Salinan $i/${tpl.copies}', styles: _center),
          if (tpl.copies > 1 && !tpl.autoCut) ...g.text('- - - - sobek di sini - - - -', styles: _center),
          // Library cut() pads 5 blank lines; feed only what the tear needs, then
          // the GS V cut command (ignored by cutterless printers, honoured by others).
          ...g.feed(tearFeedLines),
          ...g.rawBytes([0x1D, 0x56, 0x00]),
        ]),
    ];
  }

  // ---- shared top / bottom ----------------------------------------------

  static List<int> _top(Generator g, _Template tpl, img.Image? logo, Map<String, dynamic> header) {
    var b = <int>[];
    if (logo != null) b += g.imageRaster(logo);
    if (tpl.headerLines.isNotEmpty) {
      for (final line in tpl.headerLines) {
        b += g.text(line.toUpperCase(), styles: _centerBold);
      }
    } else if (_s(header, 'outletName') != null) {
      b += g.text(_s(header, 'outletName')!, styles: _centerBold2);
    }
    if (tpl.show('address') && _s(header, 'outletAddress') != null) {
      b += g.text(_s(header, 'outletAddress')!, styles: _center);
    }
    if (tpl.show('taxId') && _s(header, 'taxId') != null) {
      b += g.text('NPWP ${_s(header, 'taxId')!}', styles: _center);
    }
    b += g.hr();
    return b;
  }

  static List<int> _bottom(Generator g, _Template tpl) {
    if (tpl.footerLines.isEmpty) return [];
    var b = g.hr();
    for (final line in tpl.footerLines) {
      b += g.text(line, styles: _center);
    }
    return b;
  }

  // ---- customer receipt ---------------------------------------------------

  static List<int> _receipt(Generator g, Map<String, dynamic> p, _Template tpl) {
    final h = _map(p['header']);
    var b = <int>[];

    b += g.text('STRUK', styles: _centerBold);
    if (_s(h, 'orderNumber') != null) b += g.text('#${_s(h, 'orderNumber')}', styles: _center);
    b += _reprintMarker(g, p);
    b += g.hr();

    // show.queueNumber: no queue number in the payload yet — skipped.
    if (tpl.show('time')) b += _kv(g, tpl, 'Waktu', _local(h, 'closedAt'));
    if (tpl.show('table')) b += _kv(g, tpl, 'Meja', _s(h, 'tableNumber'));
    if (tpl.show('serviceType')) b += _kv(g, tpl, 'Layanan', _s(h, 'serviceType'));
    if (tpl.show('pax')) b += _kv(g, tpl, 'Tamu', _s(h, 'guestCount'));
    if (tpl.show('cashier')) b += _kv(g, tpl, 'Kasir', _s(h, 'cashierName'));
    if (tpl.show('cashier')) b += _kv(g, tpl, 'Register', _s(h, 'cashierStation'));
    if (tpl.show('waiter')) b += _kv(g, tpl, 'Pelayan', _s(h, 'waiterName'));
    b += g.hr();

    for (final raw in _list(p['items'])) {
      final it = _map(raw);
      b += _line(g, tpl, '${_n(it, 'qty').toInt()}x ${_s(it, 'name') ?? ''}',
          _money(_n(it, 'lineTotal')), bold: true);
      b += _addons(g, it, showPrice: true);
      if (tpl.show('itemNotes')) b += _notes(g, it);
    }
    b += g.hr();

    // Server's `subtotal` is net of item discounts: print gross, then discount.
    final discount = _n(p, 'discount');
    final serviceCharge = _n(p, 'serviceCharge');
    final tax = _n(p, 'tax');
    final taxLines = _list(p['taxLines']);
    final fee = _n(p, 'applicationFee');
    final rounding = _n(p, 'cashRounding');
    final amountDue = p['amountDue'] == null ? _n(p, 'total') : _n(p, 'amountDue');
    final collected = p['amountCollected'] == null ? amountDue : _n(p, 'amountCollected');

    b += _kv(g, tpl, 'Subtotal', _money(_n(p, 'subtotal') + discount));
    if (discount > 0) b += _kv(g, tpl, 'Diskon', '-${_money(discount)}');
    if (serviceCharge > 0) b += _kv(g, tpl, 'Biaya Layanan', _money(serviceCharge));
    for (final raw in taxLines) {
      final t = _map(raw);
      b += _kv(g, tpl, _s(t, 'name') ?? 'Pajak', _money(_n(t, 'amount')));
    }
    if (taxLines.isEmpty && tax > 0) b += _kv(g, tpl, 'Pajak', _money(tax));
    if (fee > 0) b += _kv(g, tpl, _s(p, 'applicationFeeLabel') ?? 'Biaya Platform', _money(fee));
    b += g.hr();
    b += _kv(g, tpl, 'TOTAL', '${_s(p, 'currency') ?? 'IDR'} ${_money(amountDue)}', bold: true);
    if (rounding != 0) {
      b += _kv(g, tpl, 'Pembulatan', '${rounding > 0 ? '+' : '-'}${_money(rounding.abs())}');
      b += _kv(g, tpl, 'Total Dibayar', '${_s(p, 'currency') ?? 'IDR'} ${_money(collected)}', bold: true);
    }
    if (tpl.show('inclusiveTaxInfo')) {
      if (tax > 0) b += _kv(g, tpl, 'Harga termasuk pajak', _money(tax));
      if (serviceCharge > 0) b += _kv(g, tpl, 'Harga termasuk layanan', _money(serviceCharge));
    }
    b += g.hr();

    if (_s(p, 'paymentMethod') != null) {
      b += _kv(g, tpl, 'Pembayaran', _s(p, 'paymentMethod')!.toUpperCase(), bold: true);
    }
    if (_s(p, 'paymentRef') != null) b += _kv(g, tpl, 'Ref', _s(p, 'paymentRef'));
    if (_s(p, 'footer') != null) b += g.text(_s(p, 'footer')!, styles: _center);
    // "QR e-struk": the customer scans it for the e-receipt (same link as the email).
    final ereceipt = _s(p, 'ereceiptUrl');
    if (tpl.show('qr') && ereceipt != null) {
      b += g.feed(1);
      b += g.qrcode(ereceipt, size: QRSize.Size5);
      b += g.text('Scan untuk e-struk', styles: _center);
    }
    return b;
  }

  // ---- kitchen / waiter ticket (also void slips) --------------------------

  static List<int> _ticket(Generator g, Map<String, dynamic> p, _Template tpl, String jobType) {
    final h = _map(p['header']);
    final isVoid = h['void'] == true;
    var b = <int>[];

    b += g.text(isVoid ? 'BATAL' : (jobType == 'waiter_ticket' ? 'CHECKER' : 'DAPUR'), styles: _centerBold2);
    if (_s(h, 'orderNumber') != null) b += g.text('#${_s(h, 'orderNumber')}', styles: _centerBold);
    if (isVoid && _s(h, 'orderReference') != null) b += g.text(_s(h, 'orderReference')!, styles: _center);
    b += _reprintMarker(g, p);
    b += g.hr();

    if (tpl.show('time')) b += _kv(g, tpl, 'Waktu', _local(h, isVoid ? 'voidedAt' : 'orderedAt'));
    if (tpl.show('table')) b += _kv(g, tpl, 'Meja', _s(h, 'tableNumber'), bold: true);
    if (tpl.show('serviceType')) b += _kv(g, tpl, 'Layanan', _s(h, 'serviceType'));
    if (tpl.show('waiter')) b += _kv(g, tpl, 'Pelayan', _s(h, 'waiterName'));
    if (isVoid && _s(h, 'reason') != null) b += _kv(g, tpl, 'Alasan', _s(h, 'reason'));
    b += g.hr();

    for (final raw in _list(p['items'])) {
      final it = _map(raw);
      b += g.text('${_n(it, 'qty').toInt()}x ${_s(it, 'name') ?? ''}', styles: _bold);
      b += _addons(g, it, showPrice: false);
      if (tpl.show('itemNotes')) b += _notes(g, it);
    }
    if (_s(h, 'sessionId') != null) {
      b += g.hr();
      b += g.text('Sesi ${_s(h, 'sessionId')}', styles: _center);
    }
    return b;
  }

  // ---- table QR -----------------------------------------------------------

  static List<int> _tableQr(Generator g, Map<String, dynamic> p, _Template tpl) {
    final name = _s(p, 'tableName') ?? 'Meja ${_s(p, 'tableNumber') ?? ''}';
    var b = g.text(name, styles: _centerBold2);
    b += g.text('Scan untuk memesan', styles: _center);
    final url = _s(p, 'qrUrl');
    if (url != null) {
      b += g.feed(1);
      b += g.qrcode(url, size: QRSize.Size6);
      b += g.feed(1);
    }
    return b;
  }

  // ---- cashier session slips ---------------------------------------------

  static List<int> _sessionOpen(Generator g, Map<String, dynamic> p, _Template tpl) {
    var b = g.text('BUKA SESI', styles: _centerBold);
    b += g.hr();
    b += _sessionHeader(g, tpl, p);
    b += _kv(g, tpl, 'Dibuka', _local(p, 'openedAt'));
    b += g.hr();
    b += _kv(g, tpl, 'Modal Awal', '${_s(p, 'currency') ?? 'IDR'} ${_money(_n(p, 'openingFloat'))}', bold: true);
    if (_s(p, 'note') != null) b += g.text('Catatan: ${_s(p, 'note')}');
    return b;
  }

  static List<int> _sessionClose(Generator g, Map<String, dynamic> p, _Template tpl) {
    final expected = _n(p, 'expectedCash');
    final declared = _n(p, 'declaredCash');
    final variance = p['variance'] == null ? declared - expected : _n(p, 'variance');
    final cur = _s(p, 'currency') ?? 'IDR';

    var b = g.text('TUTUP SESI', styles: _centerBold);
    b += g.text('Z-REPORT', styles: _center);
    b += g.hr();
    b += _sessionHeader(g, tpl, p);
    b += _kv(g, tpl, 'Dibuka', _local(p, 'openedAt'));
    b += _kv(g, tpl, 'Ditutup', _local(p, 'closedAt'));
    b += g.hr();
    b += _kv(g, tpl, 'Modal Awal', _money(_n(p, 'openingFloat')));
    b += _kv(g, tpl, 'Penjualan Tunai', _money(_n(p, 'cashOrdersTotal')));
    b += _kv(g, tpl, 'Kas Masuk', _money(_n(p, 'cashIn')));
    b += _kv(g, tpl, 'Kas Keluar', '-${_money(_n(p, 'cashOut'))}');
    b += g.hr();
    b += _kv(g, tpl, 'Seharusnya', '$cur ${_money(expected)}', bold: true);
    b += _kv(g, tpl, 'Dihitung', '$cur ${_money(declared)}', bold: true);
    b += _kv(g, tpl, 'Selisih', '${variance < 0 ? '-' : (variance > 0 ? '+' : '')}${_money(variance.abs())}', bold: true);
    b += g.hr();
    b += _kv(g, tpl, 'Order dibayar', '${_n(p, 'ordersCount').toInt()}');
    b += _kv(g, tpl, 'Total penjualan', _money(_n(p, 'ordersTotal')));
    if (_s(p, 'note') != null) {
      b += g.hr();
      b += g.text('Catatan: ${_s(p, 'note')}');
    }
    return b;
  }

  static List<int> _sessionHeader(Generator g, _Template tpl, Map<String, dynamic> p) {
    final station = _map(p['station']);
    var b = _kv(g, tpl, 'Register', _s(station, 'name'));
    b += _kv(g, tpl, 'Kode', _s(station, 'code'));
    b += _kv(g, tpl, 'Kasir', _s(_map(p['cashier']), 'name'));
    b += _kv(g, tpl, 'Hari Usaha', _s(p, 'businessDay'));
    return b;
  }

  // ---- local test slip (station "Tes cetak" button) ------------------------

  static List<int> _testPrint(Generator g, Map<String, dynamic> p, _Template tpl) {
    var b = g.text('TES CETAK', styles: _centerBold2);
    b += g.hr();
    b += _kv(g, tpl, 'Station', _s(p, 'station'));
    b += _kv(g, tpl, 'Printer', _s(p, 'printer'));
    b += _kv(g, tpl, 'Waktu', _s(p, 'printedAt'));
    b += g.hr();
    b += g.text('Printer siap digunakan.', styles: _center);
    return b;
  }

  // ---- pieces -------------------------------------------------------------

  /// Always-on anti-fraud marker: never template-gated (server decision).
  static List<int> _reprintMarker(Generator g, Map<String, dynamic> p) {
    final meta = _map(p['meta']);
    final count = _n(meta, 'printCount').toInt();
    if (count > 1) return g.text('CETAKAN KE-$count', styles: _centerBold);
    if (meta['reprint'] == true) return g.text('CETAK ULANG', styles: _centerBold);
    if (meta['test'] == true) return g.text('TEST PRINT', styles: _centerBold);
    return [];
  }

  static List<int> _addons(Generator g, Map<String, dynamic> item, {required bool showPrice}) {
    var b = <int>[];
    for (final raw in _list(item['addons'])) {
      final a = raw is Map ? _map(raw) : {'name': raw.toString()};
      final price = _n(a, 'price');
      final suffix = showPrice && price > 0 ? ' (${_money(price)})' : '';
      b += g.text('  + ${_s(a, 'name') ?? ''}$suffix');
    }
    return b;
  }

  static List<int> _notes(Generator g, Map<String, dynamic> item) {
    final notes = _s(item, 'notes');
    return notes == null ? [] : g.text('  * $notes');
  }

  /// Label/value row; skipped entirely when the value is missing so a
  /// template toggle never prints an empty line.
  static List<int> _kv(Generator g, _Template tpl, String label, String? value, {bool bold = false}) {
    if (value == null || value.isEmpty) return [];
    return _line(g, tpl, label, value, bold: bold);
  }

  /// One line with [left] flush left and [right] flush right.
  ///
  /// Not PosColumn: its 12-unit grid gives each column a fixed share of the
  /// line and silently truncates anything longer. At 58mm (32 chars) a 6-unit
  /// column is 16 chars, which chopped "17 Sep 2026 18:32" down to
  /// "17 Sep 2026 18:" and cut long product names mid-word. When the pair
  /// genuinely doesn't fit, the value drops to its own right-aligned line
  /// instead of losing characters.
  static List<int> _line(Generator g, _Template tpl, String left, String right, {bool bold = false}) {
    final st = PosStyles(bold: bold);
    final gap = tpl.chars - left.length - right.length;
    if (gap >= 1) return g.text('$left${' ' * gap}$right', styles: st);
    return g.text(left, styles: st) +
        g.text(right, styles: st.copyWith(align: PosAlign.right));
  }

  /// Server pre-formats `<key>Local` in the outlet timezone; fall back to the
  /// ISO string's date+time if an older job lacks it.
  static String? _local(Map<String, dynamic> m, String key) {
    final local = _s(m, '${key}Local');
    if (local != null) return local;
    final iso = _s(m, key);
    return iso?.replaceFirst('T', ' ').substring(0, iso.length.clamp(0, 16));
  }

  static Future<img.Image?> _logo(_Template tpl) async {
    final url = tpl.logoUrl;
    if (url == null) return null;
    if (_logoCache.containsKey(url)) return _logoCache[url];
    img.Image? out;
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      final decoded = res.statusCode == 200 ? img.decodeImage(res.bodyBytes) : null;
      if (decoded != null) {
        // Fit inside both bounds, preserving aspect. Printable width is 384
        // dots (58mm) / 576 (80mm); keep a margin. Never upscale a small logo.
        final maxWidth = tpl.paper == PaperSize.mm58 ? 320 : 480;
        final scale = math.min(
          math.min(maxWidth / decoded.width, logoMaxHeightDots / decoded.height),
          1.0,
        );
        out = img.grayscale(scale < 1
            ? img.copyResize(decoded,
                width: (decoded.width * scale).round(),
                height: (decoded.height * scale).round())
            : decoded);
      }
    } catch (_) {
      out = null; // a missing logo must never fail the receipt
    }
    return _logoCache[url] = out;
  }

  /// Rupiah style: no decimals, dot thousands separator.
  static String _money(double amount) {
    final s = amount.round().abs().toString();
    final buf = StringBuffer(amount < 0 ? '-' : '');
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write('.');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  /// esc_pos_utils encodes text as latin1 and throws "Contains invalid
  /// characters" on anything above U+00FF, which fails the whole job — an
  /// em dash in an outlet name ("Demo Cafe — Kemang") was enough. Map the
  /// typography that actually shows up in this data, then fall back to '?'.
  static String _safe(String s) {
    const swaps = {'\u2013': '-', '\u2014': '-', '\u2018': "'", '\u2019': "'",
                   '\u201c': '"', '\u201d': '"', '\u2026': '...', '\u00a0': ' '};
    final out = StringBuffer();
    for (final rune in s.runes) {
      final ch = String.fromCharCode(rune);
      if (swaps.containsKey(ch)) {
        out.write(swaps[ch]);
      } else {
        out.write(rune <= 0xFF ? ch : '?');
      }
    }
    return out.toString();
  }

  static Map<String, dynamic> _map(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : {};
  static List<dynamic> _list(dynamic v) => v is List ? v : const [];
  static String? _s(Map<String, dynamic> m, String k) {
    final v = m[k];
    if (v == null) return null;
    final s = _safe(v.toString().trim());
    return s.isEmpty ? null : s;
  }
  static double _n(Map<String, dynamic> m, String k) => (m[k] as num?)?.toDouble() ?? 0;

  static const _center = PosStyles(align: PosAlign.center);
  static const _centerBold = PosStyles(align: PosAlign.center, bold: true);
  static const _centerBold2 = PosStyles(align: PosAlign.center, bold: true, height: PosTextSize.size2, width: PosTextSize.size2);
  static const _bold = PosStyles(bold: true);
}

/// The `payload.template` descriptor with server defaults when absent.
class _Template {
  final PaperSize paper;
  final int copies;
  final bool autoCut;
  final int copyPauseSeconds;
  final String? logoUrl;
  final List<String> headerLines;
  final List<String> footerLines;
  final Map<String, dynamic> _show;

  _Template._(this.paper, this.copies, this.autoCut, this.copyPauseSeconds, this.logoUrl, this.headerLines, this.footerLines, this._show);

  /// Characters per line at the default font: the width every padded line is
  /// aligned to.
  int get chars => paper == PaperSize.mm58 ? 32 : 48;

  factory _Template.from(dynamic raw) {
    final t = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final copies = (t['copies'] as num?)?.toInt() ?? 1;
    final logo = t['logoUrl']?.toString().trim();
    return _Template._(
      t['paperWidth']?.toString() == '58' ? PaperSize.mm58 : PaperSize.mm80,
      copies.clamp(1, 3),
      t['autoCut'] == true,
      ((t['copyPauseSeconds'] as num?)?.toInt() ?? 5).clamp(0, 15),
      (logo == null || logo.isEmpty) ? null : logo,
      [for (final l in (t['headerLines'] as List? ?? [])) EscPosBuilder._safe(l.toString())],
      [for (final l in (t['footerLines'] as List? ?? [])) EscPosBuilder._safe(l.toString())],
      t['show'] is Map ? Map<String, dynamic>.from(t['show'] as Map) : {},
    );
  }

  /// Toggles default to true when absent so an old job without a template
  /// still prints everything it has.
  bool show(String key) => _show[key] != false;
}
