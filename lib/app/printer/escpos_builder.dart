// escpos_builder.dart
//
// Converts the structured receipt JSON (sent by Laravel, relayed through
// Svelte and the JS bridge) into raw ESC/POS bytes the RPP02N understands.
//
// Deliberately kept dumb: this file knows nothing about Bluetooth, the
// bridge, or how bytes get to the printer — it only turns data in, into
// bytes out. That separation is what let Phase 2 (Svelte UI) get built
// against a printer that didn't exist yet, and is what lets you swap
// printer brands later without touching the UI or backend at all.
//
// Expected input shape (mirrors what Laravel should send):
// {
//   "header": { "storeName": "...", "address": "...", "phone": "..." },
//   "items": [ { "name": "...", "qty": 2, "price": 15000 } ],
//   "subtotal": 30000,
//   "tax": 3000,
//   "total": 33000,
//   "paymentMethod": "Cash",
//   "paymentRef": "TXN-00123",
//   "footer": "Thank you for your purchase",
//   "qrPayload": null   // optional — set if you want a QR on the receipt
// }

import 'dart:typed_data';
import 'package:esc_pos_utils/esc_pos_utils.dart';

class Receipt {
  final String storeName;
  final String? address;
  final String? phone;
  final List<ReceiptItem> items;
  final int subtotal;
  final int tax;
  final int total;
  final String? paymentMethod;
  final String? paymentRef;
  final String? footer;
  final String? qrPayload;

  Receipt({
    required this.storeName,
    this.address,
    this.phone,
    required this.items,
    required this.subtotal,
    required this.tax,
    required this.total,
    this.paymentMethod,
    this.paymentRef,
    this.footer,
    this.qrPayload,
  });

  factory Receipt.fromJson(Map<String, dynamic> json) {
    final header = json['header'] as Map<String, dynamic>? ?? {};
    final itemsJson = json['items'] as List<dynamic>? ?? [];

    return Receipt(
      storeName: header['storeName'] as String? ?? 'Receipt',
      address: header['address'] as String?,
      phone: header['phone'] as String?,
      items: itemsJson
          .map((i) => ReceiptItem.fromJson(i as Map<String, dynamic>))
          .toList(),
      subtotal: (json['subtotal'] as num?)?.toInt() ?? 0,
      tax: (json['tax'] as num?)?.toInt() ?? 0,
      total: (json['total'] as num?)?.toInt() ?? 0,
      paymentMethod: json['paymentMethod'] as String?,
      paymentRef: json['paymentRef'] as String?,
      footer: json['footer'] as String?,
      qrPayload: json['qrPayload'] as String?,
    );
  }
}

class ReceiptItem {
  final String name;
  final int qty;
  final int
      price; // unit price, smallest currency unit (e.g. Rupiah, no decimals)

  ReceiptItem({required this.name, required this.qty, required this.price});

  factory ReceiptItem.fromJson(Map<String, dynamic> json) => ReceiptItem(
        name: json['name'] as String? ?? '',
        qty: (json['qty'] as num?)?.toInt() ?? 1,
        // Laravel sends 'unitPrice' on customer receipts, 'price' legacy
        price: (json['unitPrice'] as num?)?.toInt() ??
            (json['price'] as num?)?.toInt() ??
            0,
      );

  int get lineTotal => qty * price;
}

class EscPosBuilder {
  /// Paper width in mm. RPP02N is a 58mm-class printer — confirm against
  /// the actual unit/spec sheet. If wrong, text will wrap incorrectly
  /// (too early or run off the edge) but will not damage the printer.
  static const PaperSize defaultPaperSize = PaperSize.mm58;

  /// Builds the full byte sequence for one receipt, including the final
  /// paper cut. Returns raw bytes ready to hand to the Bluetooth socket —
  /// this function never throws on missing optional fields; it only
  /// throws if [profile] fails to load (extremely rare, indicates a
  /// packaging issue, not a data issue).
  static Future<List<int>> build(
    Receipt receipt, {
    PaperSize paperSize = defaultPaperSize,
  }) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize, profile);
    var bytes = <int>[];

    bytes += generator.text(
      receipt.storeName,
      styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2),
    );

    if (receipt.address != null) {
      bytes += generator.text(receipt.address!,
          styles: const PosStyles(align: PosAlign.center));
    }
    if (receipt.phone != null) {
      bytes += generator.text(receipt.phone!,
          styles: const PosStyles(align: PosAlign.center));
    }

    bytes += generator.hr();

    for (final item in receipt.items) {
      bytes += generator.row([
        PosColumn(
          text: item.name,
          width: 7,
          styles: const PosStyles(align: PosAlign.left),
        ),
        PosColumn(
          text: '${item.qty}x',
          width: 2,
          styles: const PosStyles(align: PosAlign.center),
        ),
        PosColumn(
          text: _formatCurrency(item.lineTotal),
          width: 3,
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]);
    }

    bytes += generator.hr();

    bytes += _totalsRow(generator, 'Subtotal', receipt.subtotal);
    if (receipt.tax > 0) {
      bytes += _totalsRow(generator, 'Tax', receipt.tax);
    }
    bytes += _totalsRow(generator, 'Total', receipt.total, emphasize: true);

    bytes += generator.feed(1);

    if (receipt.paymentMethod != null) {
      bytes += generator.text('Payment: ${receipt.paymentMethod}');
    }
    if (receipt.paymentRef != null) {
      bytes += generator.text('Ref: ${receipt.paymentRef}');
    }

    if (receipt.qrPayload != null && receipt.qrPayload!.isNotEmpty) {
      bytes += generator.feed(1);
      // NOTE: esc_pos_utils' Generator.qrcode() signature varies slightly
      // across versions. If your installed version supports sizing, e.g.
      // generator.qrcode(receipt.qrPayload!, size: QRSize.size4), feel
      // free to add it back — left plain here since the exact param name
      // isn't guaranteed across versions.
      bytes += generator.qrcode(receipt.qrPayload!);
    }

    if (receipt.footer != null) {
      bytes += generator.feed(1);
      bytes += generator.text(receipt.footer!,
          styles: const PosStyles(align: PosAlign.center));
    }

    bytes += generator.feed(2);
    bytes += generator.cut();

    return bytes;
  }

  static List<int> _totalsRow(
    Generator generator,
    String label,
    int amount, {
    bool emphasize = false,
  }) {
    return generator.row([
      PosColumn(
        text: label,
        width: 8,
        styles: PosStyles(align: PosAlign.left, bold: emphasize),
      ),
      PosColumn(
        text: _formatCurrency(amount),
        width: 4,
        styles: PosStyles(align: PosAlign.right, bold: emphasize),
      ),
    ]);
  }

  /// Minimal currency formatting — no decimals, thousands separator.
  /// Adjust to your locale (this assumes Rupiah-style whole-unit pricing,
  /// matching the "smallest currency unit, no decimals" convention used
  /// in the ReceiptItem price field above).
  static String _formatCurrency(int amount) {
    final s = amount.toString();
    final buffer = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buffer.write('.');
      buffer.write(s[i]);
    }
    return buffer.toString();
  }

  /// Convenience: builds and returns as Uint8List, which is what most
  /// Bluetooth send APIs expect rather than a plain List<int>.
  static Future<Uint8List> buildAsBytes(
    Receipt receipt, {
    PaperSize paperSize = defaultPaperSize,
  }) async {
    final list = await build(receipt, paperSize: paperSize);
    return Uint8List.fromList(list);
  }

  /// Dispatcher used by [PrintQueue]. Payload must contain '_jobType'
  /// (merged in by poll_service / reverb_service before enqueuing).
  static Future<Uint8List> buildFromJobPayload(
    Map<String, dynamic> payload, {
    PaperSize paperSize = defaultPaperSize,
  }) async {
    final jobType = payload['_jobType'] as String? ?? '';
    switch (jobType) {
      case 'kitchen_ticket':
        return _buildKitchenTicket(payload, paperSize);
      case 'table_qr':
        return _buildTableQr(payload, paperSize);
      default:
        // customer_receipt and any future types go through Receipt
        return buildAsBytes(Receipt.fromJson(payload), paperSize: paperSize);
    }
  }

  static Future<Uint8List> _buildKitchenTicket(
    Map<String, dynamic> payload,
    PaperSize paperSize,
  ) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize, profile);
    var bytes = <int>[];

    final header = payload['header'] as Map<String, dynamic>? ?? {};
    bytes += generator.text(
      'KITCHEN',
      styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2),
    );
    bytes += generator.text(
      'Table ${header['tableNumber'] ?? '-'}  |  ${header['orderedAt'] ?? ''}',
      styles: const PosStyles(align: PosAlign.center),
    );
    bytes += generator.hr();

    final items = payload['items'] as List<dynamic>? ?? [];
    for (final raw in items) {
      final item = raw as Map<String, dynamic>;
      final name = item['name'] as String? ?? '';
      final qty = (item['qty'] as num?)?.toInt() ?? 1;
      final notes = item['notes'] as String?;
      bytes += generator.row([
        PosColumn(
          text: '$qty x $name',
          width: 12,
          styles: const PosStyles(align: PosAlign.left, bold: true),
        ),
      ]);
      if (notes != null && notes.isNotEmpty) {
        bytes += generator.text(
          '  * $notes',
          styles: const PosStyles(align: PosAlign.left),
        );
      }
    }

    bytes += generator.feed(2);
    bytes += generator.cut();
    return Uint8List.fromList(bytes);
  }

  static Future<Uint8List> _buildTableQr(
    Map<String, dynamic> payload,
    PaperSize paperSize,
  ) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize, profile);
    var bytes = <int>[];

    final tableName = payload['tableName'] as String? ??
        'Table ${payload['tableNumber'] ?? ''}';
    bytes += generator.text(
      tableName,
      styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2),
    );
    bytes += generator.text(
      'Scan to order',
      styles: const PosStyles(align: PosAlign.center),
    );
    bytes += generator.hr();

    final qrUrl = payload['qrUrl'] as String?;
    if (qrUrl != null && qrUrl.isNotEmpty) {
      bytes += generator.qrcode(qrUrl);
    }

    bytes += generator.feed(2);
    bytes += generator.cut();
    return Uint8List.fromList(bytes);
  }
}
