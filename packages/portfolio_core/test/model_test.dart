import 'package:decimal/decimal.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  final today = istanbulToday(DateTime.utc(2026, 10, 10, 22, 30)); // 2026-10-11

  test('ticker normalization (Review Focus 5)', () {
    expect(Instrument.create(AssetClass.bistShare, ' thyao ').id, 'XIST:THYAO');
    expect(Instrument.create(AssetClass.crypto, 'btc').id, 'CRYPTO:BTC');
    expect(Instrument.create(AssetClass.crypto, 'btc').code, 'BTC');
    expect(
      () => Instrument.create(AssetClass.fx, 'TRY'),
      throwsFormatException,
    );
    expect(
      () => Instrument.create(AssetClass.gold, 'OUNCE'),
      throwsFormatException,
    );
    expect(
      () => Instrument.create(AssetClass.bistShare, '1AB'),
      throwsFormatException,
    );
  });

  test('Instrument.fromJson: id is authoritative', () {
    final j = Instrument.create(AssetClass.fx, 'USD', name: 'Dollar').toJson();
    expect(Instrument.fromJson(j), Instrument.create(AssetClass.fx, 'USD'));
    expect(
      () => Instrument.fromJson({...j, 'instrument_id': 'FX:usd'}),
      throwsFormatException,
    );
    expect(
      () => Instrument.fromJson({...j, 'instrument_id': 'XIST:USD'}),
      throwsFormatException,
    );
    expect(
      () => Instrument.fromJson({...j, 'symbol_at_trade': 'x' * 201}),
      throwsFormatException,
    );
    expect(
      Instrument.fromJson({...j, 'symbol_at_trade': 'whatever'}).id,
      'FX:USD',
    );
  });

  test('future date uses Istanbul date (Review Focus 2)', () {
    expect(buy(on: date(2026, 10, 11)).validate(today: today), isEmpty);
    expect(
      buy(on: date(2026, 10, 12)).validate(today: today),
      contains('effective_date is in the future'),
    );
  });

  test('dividend and split only for shares', () {
    final usd = Instrument.create(AssetClass.fx, 'USD');
    expect(
      split(on: date(2026, 1, 2), instrument: usd).validate(today: today),
      contains('SPLIT is only allowed for BIST_SHARE'),
    );
    expect(
      dividend(on: date(2026, 1, 2), instrument: usd).validate(today: today),
      contains('DIVIDEND is only allowed for BIST_SHARE'),
    );
  });

  test('dividend deductions cannot exceed gross', () {
    final t = dividend(
      on: date(2026, 1, 2),
      gross: '100',
      withholding: '60',
      fees: '50',
    );
    expect(
      t.validate(today: today),
      contains('deductions exceed gross_amount'),
    );
    final ok = dividend(on: date(2026, 1, 2), withholding: '15', fees: '5');
    expect(ok.validate(today: today), isEmpty);
    expect(ok.netDividend, Decimal.parse('80'));
  });

  test('collects all errors', () {
    final t = buy(on: date(2026, 10, 12), qty: '0', price: '0', dayOrder: 0);
    expect(t.validate(today: today), hasLength(4));
    expect(
      split(
        on: date(2026, 1, 2),
        numerator: 0,
        denominator: 0,
      ).validate(today: today),
      hasLength(2),
    );
  });

  test('json round trip keeps decimal strings', () {
    final t = buy(on: date(2026, 10, 9), qty: '100', price: '10.00');
    final j = t.toJson();
    expect(j['quantity'], '100');
    expect(j['unit_price'], '10');
    expect(j['currency'], 'TRY');
    expect(Transaction.fromJson(j).toJson(), j);
    expect(
      () => Transaction.fromJson({...j, 'quantity': 100}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'm',
          contains('quantity'),
        ),
      ),
    );
    expect(
      () => Transaction.fromJson({...j, 'currency': 'USD'}),
      throwsFormatException,
    );
    expect(
      () => Transaction.fromJson({...j, 'quantity': '0'}),
      throwsFormatException,
    );
  });

  test('json emits only fields of the type; all types round trip', () {
    final d = dividend(on: date(2026, 1, 2), withholding: '1').toJson();
    expect(d.containsKey('quantity'), isFalse);
    expect(d['withholding'], '1');
    final s = split(on: date(2026, 1, 2)).toJson();
    expect(s.containsKey('fees'), isFalse);
    expect(s['ratio_numerator'], 2);
    for (final t in [
      sell(on: date(2026, 1, 2), fees: '0'),
      dividend(on: date(2026, 1, 2)),
      split(on: date(2026, 1, 2)),
    ]) {
      expect(Transaction.fromJson(t.toJson()).toJson(), t.toJson());
    }
    expect(
      () => Transaction.fromJson({...s, 'ratio_numerator': '2'}),
      throwsFormatException,
    );
  });

  group('fromJson enforces structural rules', () {
    final b = buy(on: date(2026, 1, 2)).toJson();
    final s = split(on: date(2026, 1, 2)).toJson();
    final d = dividend(on: date(2026, 1, 2)).toJson();
    test('rejects invalid records', () {
      expect(
        () => Transaction.fromJson({...b, 'day_order': 0}),
        throwsFormatException,
      );
      expect(
        () => Transaction.fromJson({...s, 'ratio_numerator': -3}),
        throwsFormatException,
      );
      expect(
        () => Transaction.fromJson({...s, 'quantity': '1'}),
        throwsFormatException,
      );
      expect(
        () => Transaction.fromJson({...b, 'ratio_numerator': 2}),
        throwsFormatException,
      );
      expect(
        () => Transaction.fromJson({...b, 'note': 'x' * 2001}),
        throwsFormatException,
      );
      final usd = Instrument.create(AssetClass.fx, 'USD').toJson();
      expect(
        () => Transaction.fromJson({...d, 'instrument': usd}),
        throwsFormatException,
      );
    });
    test('too many digits', () {
      final t = Transaction.buy(
        instrument: aaa(),
        date: date(2026, 1, 2),
        dayOrder: 1,
        quantity: Decimal.parse('1.123456789'),
        unitPrice: Decimal.one,
        fees: Decimal.zero,
      );
      expect(
        t.validate(today: today),
        contains('quantity has too many digits'),
      );
    });
  });

  test('fund identity (Review Focus 1)', () {
    expect(Instrument.create(AssetClass.fund, ' tte ').id, 'TEFAS:TTE');
    expect(
      () => Instrument.create(AssetClass.fund, 'TTEX'),
      throwsFormatException,
    );
    expect(AssetClass.fromJson('FUND'), AssetClass.fund);
  });

  test('dividend and split are rejected for funds', () {
    final f = Instrument.create(AssetClass.fund, 'TTE');
    expect(
      dividend(on: date(2026, 1, 2), instrument: f).validate(today: today),
      contains('DIVIDEND is only allowed for BIST_SHARE'),
    );
    expect(
      split(on: date(2026, 1, 2), instrument: f).validate(today: today),
      contains('SPLIT is only allowed for BIST_SHARE'),
    );
  });

  test('fund buy round-trips through json', () {
    final f = Instrument.create(AssetClass.fund, 'TTE');
    final t = buy(
      on: date(2026, 10, 9),
      qty: '100.5',
      price: '1.157776',
      instrument: f,
    );
    expect(Transaction.fromJson(t.toJson()).toJson(), t.toJson());
    expect(Transaction.fromJson(t.toJson()).instrument, f);
  });
}
