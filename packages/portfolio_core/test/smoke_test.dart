import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

void main() {
  test(
    'decimal exact',
    () =>
        expect((Decimal.parse('0.1') + Decimal.parse('0.2')).toString(), '0.3'),
  );
}
