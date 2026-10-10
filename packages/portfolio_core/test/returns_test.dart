import 'package:decimal/decimal.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

final cal = TradingCalendar([]);

PeriodResult run(
  Period p,
  DateTime today,
  List<Transaction> txs,
  List<PriceObservation> prices,
) => computePeriod(
  period: p,
  today: today,
  transactions: txs,
  prices: FixedPrices(prices),
  calendar: cal,
);

void main() {
  test('E: weighted flow return is 4.74%', () {
    final r = run(
      Period.oneMonth,
      date(2026, 5, 30),
      [
        buy(on: date(2026, 1, 5), qty: '1000', price: '10'),
        buy(on: date(2026, 5, 15), qty: '500', price: '10'),
      ],
      [
        obs('XIST:AAA', '10', date(2026, 4, 30)),
        obs('XIST:AAA', '10.4', date(2026, 5, 30)),
      ],
    );
    expect(r.baseline, date(2026, 4, 30));
    expect(r.gain.toString(), '600');
    expect(formatPercent(r.returnPercent!), '4.74%');
    expect(r.sinceInception, isFalse);
    expect(r.indicative, isFalse);
  });

  test('D: purchases are not profit', () {
    final r = run(
      Period.oneMonth,
      date(2026, 5, 30),
      [
        buy(on: date(2026, 1, 5), qty: '1000', price: '10'),
        buy(on: date(2026, 5, 15), qty: '500', price: '10'),
      ],
      [
        obs('XIST:AAA', '10', date(2026, 4, 30)),
        obs('XIST:AAA', '10', date(2026, 5, 30)),
      ],
    );
    expect(r.gain, Decimal.zero);
    expect(r.returnPercent, Decimal.zero);
  });

  test('lifetime matches A: gain 600', () {
    final r = run(
      Period.lifetime,
      date(2026, 5, 30),
      [buy(on: date(2026, 1, 5), qty: '100', price: '12')],
      [obs('XIST:AAA', '18', date(2026, 5, 30))],
    );
    expect(r.gain.toString(), '600');
    expect(r.valueStart, Decimal.zero);
    expect(r.sinceInception, isFalse);
    expect(r.baseline, date(2026, 1, 4));
  });

  test('baseline before first transaction is since inception', () {
    final r = run(
      Period.oneYear,
      date(2026, 3, 5),
      [buy(on: date(2026, 1, 5), qty: '100', price: '12')],
      [obs('XIST:AAA', '18', date(2026, 3, 5))],
    );
    expect(r.sinceInception, isTrue);
    expect(r.valueStart, Decimal.zero);
    expect(r.baseline, date(2026, 1, 4));
    expect(r.gain.toString(), '600');
  });

  test('non-trading baseline: Saturday purchase is in V_B, not a flow', () {
    final r = run(
      Period.oneMonth,
      date(2026, 11, 10),
      [buy(on: date(2026, 10, 10), qty: '10', price: '5')],
      [
        obs('XIST:AAA', '6', date(2026, 10, 9)),
        obs('XIST:AAA', '7', date(2026, 11, 10)),
      ],
    );
    expect(r.baseline, date(2026, 10, 10));
    expect(r.valueStart.toString(), '60');
    expect(r.gain.toString(), '10');
  });

  test('missing price makes period unavailable, never zero', () {
    final r = run(Period.lifetime, date(2026, 5, 30), [
      buy(on: date(2026, 1, 5)),
    ], []);
    expect(r.unavailableReason, 'Missing price for XIST:AAA');
    expect(r.gain, isNull);
    expect(r.returnPercent, isNull);
  });

  test('invalid ledger wins over missing prices', () {
    final r = run(Period.lifetime, date(2026, 5, 30), [
      buy(on: date(2026, 1, 5)),
      sell(on: date(2026, 1, 6), qty: '5'),
    ], []);
    expect(r.unavailableReason, 'Ledger has unresolved issues');
    expect(r.gain, isNull);
  });

  test('nonpositive weighted capital → N/A, TRY gain kept', () {
    final r = run(
      Period.oneMonth,
      date(2026, 5, 30),
      [
        buy(on: date(2026, 3, 1), qty: '10', price: '10'),
        sell(on: date(2026, 5, 1), qty: '10', price: '12'),
      ],
      [obs('XIST:AAA', '10', date(2026, 4, 30))],
    );
    expect(r.gain.toString(), '20');
    expect(r.returnPercent, isNull);
    expect(r.percentNote, 'N/A — no positive weighted capital');
  });

  test('delayed endpoint price is indicative', () {
    final r = run(
      Period.lifetime,
      date(2026, 5, 30),
      [buy(on: date(2026, 1, 5))],
      [obs('XIST:AAA', '2', date(2026, 5, 30), kind: PriceKind.delayedQuote)],
    );
    expect(r.indicative, isTrue);
  });

  test('empty ledger → gain 0, percent N/A', () {
    final r = run(Period.oneMonth, date(2026, 5, 30), [], []);
    expect(r.gain, Decimal.zero);
    expect(r.valueStart, Decimal.zero);
    expect(r.valueEnd, Decimal.zero);
    expect(r.returnPercent, isNull);
    expect(r.percentNote, 'N/A — no positive weighted capital');
  });

  test('historicalPriceNeeds: holdings at each baseline, deduplicated', () {
    final a = aaa();
    final b = Instrument.create(AssetClass.bistShare, 'BBB');
    final needs = historicalPriceNeeds(
      today: date(2026, 5, 30),
      transactions: [
        buy(on: date(2026, 1, 5), instrument: a),
        buy(on: date(2026, 4, 1), instrument: b),
        sell(on: date(2026, 5, 10), instrument: a),
      ],
      calendar: cal,
    );
    // daily = Fri 05-29; 1M = 04-30; 3M = 02-28; 1Y/lifetime before first.
    expect(needs.keys.toSet(), {
      date(2026, 5, 29),
      date(2026, 4, 30),
      date(2026, 2, 28),
    });
    expect(needs[date(2026, 5, 29)]!.map((i) => i.id), ['XIST:BBB']);
    expect(needs[date(2026, 4, 30)]!.map((i) => i.id).toSet(), {
      'XIST:AAA',
      'XIST:BBB',
    });
    expect(needs[date(2026, 2, 28)]!.map((i) => i.id), ['XIST:AAA']);
  });
}
