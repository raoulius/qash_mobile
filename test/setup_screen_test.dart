import 'package:flutter_test/flutter_test.dart';
import 'package:qash_mobile/app/config/setup_screen.dart';

void main() {
  test('pairing code: 4 to 12 characters, trimmed', () {
    for (final ok in ['ABCD', 'ABCD2345', 'ABCD2345WXYZ', ' ABCD ']) {
      expect(validatePairingCode(ok), isNull, reason: ok);
    }
    for (final bad in ['ABC', 'ABCD2345WXYZ9', '', null]) {
      expect(validatePairingCode(bad), isNotNull, reason: '$bad');
    }
  });
}
