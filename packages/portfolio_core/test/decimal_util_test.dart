import 'package:decimal/decimal.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

void main() {
  test('divide is half-even at 28 digits', () {
    expect(
      divide(Decimal.one, Decimal.fromInt(3)).toString(),
      '0.3333333333333333333333333333',
    );
    expect(roundHalfEven(Decimal.parse('0.125'), 2).toString(), '0.12');
    expect(roundHalfEven(Decimal.parse('0.135'), 2).toString(), '0.14');
    expect(roundHalfEven(Decimal.parse('-0.125'), 2).toString(), '-0.12');
    expect(roundHalfEven(Decimal.parse('-0.135'), 2).toString(), '-0.14');
  });
  test('formatting', () {
    expect(formatTry(Decimal.parse('2700')), '2,700.00');
    expect(formatTry(Decimal.parse('-1234567.005')), '-1,234,567.00');
    expect(formatTry(Decimal.parse('-0.001')), '0.00');
    expect(formatTry(Decimal.parse('999.995')), '1,000.00');
    expect(formatPercent(Decimal.parse('4.73684210526')), '4.74%');
    expect(formatQuantity(Decimal.parse('0.12345678')), '0.12345678');
    expect(formatQuantity(Decimal.parse('1500.50')), '1,500.5');
    expect(formatQuantity(Decimal.parse('1000')), '1,000');
  });
  test('record decimal fields', () {
    expect(parseDecimalField('10.00').toString(), '10');
    for (final bad in [
      '1e3',
      '-1',
      '1,000',
      '.5',
      '1.123456789',
      '0',
      '',
      ' 1',
      '1\n',
    ]) {
      expect(() => parseDecimalField(bad), throwsFormatException, reason: bad);
    }
    expect(parseDecimalField('0', allowZero: true), Decimal.zero);
    expect(
      parseDecimalField('123456789012345678').toString(),
      '123456789012345678',
    );
    expect(
      () => parseDecimalField('1234567890123456789'),
      throwsFormatException,
    );
  });
  test('user decimal input (Review Focus 1)', () {
    expect(parseUserDecimal('12,50'), '12.50');
    expect(parseUserDecimal(' 12.5 '), '12.5');
    expect(parseUserDecimal('1.234,56'), isNull);
    expect(parseUserDecimal('1,234.56'), isNull);
    expect(parseUserDecimal('abc'), isNull);
    expect(parseUserDecimal(''), isNull);
    expect(parseUserDecimal('1,2,3'), isNull);
  });
}
