// Renders the real payload shapes the Laravel backend sends (captured from
// print_jobs on 2026-09-17) and checks the template descriptor is honoured.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:qash_mobile/app/printer/escpos_builder.dart';

Map<String, dynamic> _template({String paper = '80', int copies = 1, Map<String, bool> show = const {}}) => {
      'paperWidth': paper,
      'copies': copies,
      'logoUrl': null,
      'headerLines': ['Danke Schon'],
      'footerLines': ['Terima kasih!'],
      'show': {
        'address': true, 'taxId': true, 'cashier': true, 'waiter': true, 'table': true,
        'serviceType': true, 'time': true, 'itemNotes': true, 'pax': false,
        'queueNumber': false, 'inclusiveTaxInfo': false, 'qr': false, ...show,
      },
      'qrContent': null,
    };

final _receipt = {
  '_jobType': 'customer_receipt',
  'currency': 'IDR',
  'header': {
    'outletName': 'Main Outlet', 'outletAddress': 'Jalan Graha Permai V, Bekasi',
    'orderNumber': 6, 'tableNumber': null, 'serviceType': 'Takeaway', 'guestCount': null,
    'waiterName': null, 'cashierName': 'Sari', 'cashierStation': 'Counter 1',
    'closedAt': '2026-09-17T06:54:25+00:00', 'closedAtLocal': '17 Sep 2026 13:54',
  },
  'items': [
    {'qty': 1, 'name': 'Iced Caramel Latte', 'notes': 'less ice', 'addons': [{'name': 'Extra shot', 'price': 5000}], 'lineTotal': 38000, 'unitPrice': 43000},
  ],
  'subtotal': 38000, 'discount': 5000, 'serviceCharge': 0, 'tax': 3800,
  'taxLines': [{'name': 'PB1', 'amount': 3800}],
  'applicationFee': 0, 'applicationFeeLabel': 'Platform Fee', 'cashRounding': 0,
  'amountDue': 41800, 'amountCollected': 41800, 'total': 41800,
  'paymentMethod': 'digital', 'paymentRef': 'DEM-2D8E13620F', 'footer': null,
  'meta': {'reprint': false, 'printCount': 2},
  'template': _template(),
};

String _text(List<int> bytes) => latin1.decode(bytes, allowInvalid: true);
int _count(String hay, String needle) => needle.allMatches(hay).length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('NPWP and the e-receipt QR print only when switched on', () async {
    Map<String, dynamic> receipt(bool on) => {
          ..._receipt,
          'header': {...(_receipt['header'] as Map<String, dynamic>), 'taxId': '01.234.567.8-901.000'},
          'ereceiptUrl': 'https://demo.test/order/summary/abc',
          'template': _template(show: {'taxId': on, 'qr': on}),
        };
    final withBoth = _text(await EscPosBuilder.buildFromJobPayload(receipt(true)));
    expect(withBoth, contains('NPWP 01.234.567.8-901.000'));
    expect(withBoth, contains('Scan untuk e-struk'));

    final without = _text(await EscPosBuilder.buildFromJobPayload(receipt(false)));
    expect(without, isNot(contains('NPWP')));
    expect(without, isNot(contains('Scan untuk e-struk')));
  });

  test('customer receipt honours template, money lines and reprint marker', () async {
    final out = _text(await EscPosBuilder.buildFromJobPayload(_receipt));
    expect(out, contains('DANKE SCHON')); // header line replaces outlet name, uppercased
    expect(out, contains('Jalan Graha Permai V'));
    expect(out, contains('CETAKAN KE-2'));
    expect(out, contains('43.000')); // gross subtotal = net 38.000 + discount 5.000
    expect(out, contains('-5.000'));
    expect(out, contains('PB1'));
    expect(out, contains('41.800'));
    expect(out, contains('+ Extra shot (5.000)'));
    expect(out, contains('* less ice'));
    expect(out, contains('Kasir'));
    expect(out, contains('Terima kasih!'));
    expect(out, contains('DIGITAL'));
    expect(_count(out, '\x1dV'), 1, reason: 'one cut per copy'); // GS V
  });

  test('toggles hide rows and copies repeat the slip', () async {
    final p = Map<String, dynamic>.from(_receipt)
      ..['template'] = _template(paper: '58', copies: 2, show: {'cashier': false, 'itemNotes': false, 'address': false});
    final out = _text(await EscPosBuilder.buildFromJobPayload(p));
    expect(out, isNot(contains('Kasir')));
    expect(out, isNot(contains('less ice')));
    expect(out, isNot(contains('Jalan Graha')));
    expect(_count(out, '\x1dV'), 2);
    expect(_count(out, 'CETAKAN KE-2'), 2);
  });

  test('kitchen ticket, void slip and waiter title', () async {
    final kitchen = {
      '_jobType': 'kitchen_ticket',
      'header': {'orderNumber': 6, 'tableNumber': 'T6', 'serviceType': 'Dine In', 'orderedAtLocal': '17 Sep 2026 13:32', 'sessionId': 15},
      'items': [{'qty': 2, 'name': 'Nasi Goreng', 'addons': [{'name': 'Extra cheese'}], 'notes': 'no chili'}],
      'meta': {'reprint': false},
      'template': _template(),
    };
    var out = _text(await EscPosBuilder.buildFromJobPayload(kitchen));
    expect(out, contains('DAPUR'));
    expect(out, contains('2x Nasi Goreng'));
    expect(out, contains('+ Extra cheese'));
    expect(out, isNot(contains('(')), reason: 'kitchen never prints prices');
    expect(out, contains('Sesi 15'));

    out = _text(await EscPosBuilder.buildFromJobPayload({...kitchen, '_jobType': 'waiter_ticket'}));
    expect(out, contains('PELAYAN'));

    out = _text(await EscPosBuilder.buildFromJobPayload({
      ...kitchen,
      'header': {'void': true, 'reason': 'customer left', 'voidedAtLocal': '17 Sep 2026 14:00', 'sessionId': 15},
    }));
    expect(out, contains('BATAL'));
    expect(out, contains('customer left'));
  });

  test('table QR, session open and close render their own layouts', () async {
    var out = _text(await EscPosBuilder.buildFromJobPayload({
      '_jobType': 'table_qr', 'tableName': 'T6', 'qrUrl': 'https://demo-cafe.withqash-demo.tech/o/main/order?session=x', 'template': _template(),
    }));
    expect(out, contains('T6'));
    expect(out, contains('Scan untuk memesan'));
    expect(out, contains('\x1d(k'), reason: 'QR command emitted');

    out = _text(await EscPosBuilder.buildFromJobPayload({
      '_jobType': 'session_open', 'currency': 'IDR',
      'outlet': {'name': 'Main Outlet', 'address': 'Bekasi'}, 'station': {'name': 'Bar Register', 'code': 'bar-register'},
      'cashier': {'name': 'Demo Admin'}, 'businessDay': '2026-09-07', 'openedAtLocal': '07 Sep 2026 13:03', 'openingFloat': 125000,
      'template': _template(),
    }));
    expect(out, contains('BUKA SESI'));
    expect(out, contains('Bar Register'));
    expect(out, contains('125.000'));

    out = _text(await EscPosBuilder.buildFromJobPayload({
      '_jobType': 'session_close', 'currency': 'IDR', 'outlet': {'name': 'Main Outlet'}, 'station': {'name': 'Bar Register'},
      'cashier': {'name': 'Demo Admin'}, 'openingFloat': 125000, 'cashOrdersTotal': 50000, 'cashIn': 0, 'cashOut': 10000,
      'expectedCash': 165000, 'declaredCash': 160000, 'ordersCount': 3, 'ordersTotal': 90000, 'template': _template(),
    }));
    expect(out, contains('TUTUP SESI'));
    expect(out, contains('Selisih'));
    expect(out, contains('-5.000'));
    expect(out, contains('Order dibayar'));
  });

  test('58mm keeps long values whole instead of truncating them', () async {
    final p = Map<String, dynamic>.from(_receipt)..['template'] = _template(paper: '58');
    p['items'] = <Map<String, dynamic>>[
      {'qty': 2, 'name': 'Chocolate Hazelnut Frappe', 'lineTotal': 96000, 'addons': [], 'notes': null},
    ];
    final out = _text(await EscPosBuilder.buildFromJobPayload(p));
    // A 6-of-12 PosColumn is 16 chars at 58mm; this value is 17.
    expect(out, contains('17 Sep 2026 13:54'));
    expect(out, contains('2x Chocolate Hazelnut Frappe'));
  });

  test('characters above latin1 are mapped, not thrown', () async {
    final p = Map<String, dynamic>.from(_receipt);
    p['header'] = {...(p['header'] as Map), 'outletName': 'Demo Cafe \u2014 Kemang'};
    p['template'] = _template()..['headerLines'] = <String>[];
    final out = _text(await EscPosBuilder.buildFromJobPayload(p));
    expect(out, contains('Demo Cafe - Kemang'));
  });

  test('a job without a template still prints with defaults', () async {
    final p = Map<String, dynamic>.from(_receipt)..remove('template');
    final out = _text(await EscPosBuilder.buildFromJobPayload(p));
    expect(out, contains('Main Outlet'));
    expect(out, contains('41.800'));
    expect(_count(out, '\x1dV'), 1);
  });

  test('the station test slip prints its fields on 58mm without a server job', () async {
    final out = _text(await EscPosBuilder.buildFromJobPayload({
      '_jobType': 'test_print',
      'template': {'paperWidth': '58'},
      'header': {'outletName': 'demo-cafe'},
      'station': 'counter-1',
      'printer': 'RPP02N',
      'printedAt': '2026-09-23 19:40',
    }));

    expect(out, contains('TES CETAK'));
    expect(out, contains('counter-1'));
    expect(out, contains('RPP02N'));
    expect(out, isNot(contains('STRUK')), reason: 'must not fall through to the receipt layout');
  });
}
