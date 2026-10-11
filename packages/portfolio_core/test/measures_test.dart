import 'package:decimal/decimal.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

Decimal d(String s) => Decimal.parse(s);

// USD rates are 28-digit roundings (1 / U), so USD values compare at 20 digits.
Decimal r20(Decimal x) => roundHalfEven(x, 20);

final day1 = DateTime.utc(2026, 1, 5);
final day2 = DateTime.utc(2026, 2, 2);
final today = DateTime.utc(2026, 3, 1);
final cal = TradingCalendar([]);
final usdInst = Instrument.create(AssetClass.fx, 'USD');

PeriodResult life(Rates r, List<Transaction> txs, PriceLookup p) =>
    measuredPeriod(
      rates: r,
      period: Period.lifetime,
      today: today,
      transactions: txs,
      prices: p,
      calendar: cal,
    );

CpiSeries cpi(Map<String, String> m) => CpiSeries({
  for (final e in m.entries) e.key: CpiEntry(d(e.value), 'manual'),
});

void main() {
  test('real: 261 months of 28-digit percents convert fast', () {
    final months = <String, String>{};
    for (var i = 0; i < 261; i++) {
      final n = 2005 * 12 + i;
      months['${n ~/ 12}-${(n % 12 + 1).toString().padLeft(2, '0')}'] =
          '1.2345678901234567890123456789';
    }
    final txs = [
      for (var i = 0; i < 300; i++)
        buy(on: DateTime.utc(2005 + (i % 20), 1 + i % 12, 5), dayOrder: i),
    ];
    final sw = Stopwatch()..start();
    convertTransactions(txs, RealRates(cpi(months), today: today));
    expect(sw.elapsedMilliseconds, lessThan(1000));
  });

  test('usd: worked example', () {
    final prices = FixedPrices([
      obs('FX:USD', '30', day1),
      obs('XIST:AAA', '15', today),
      obs('FX:USD', '40', today),
    ]);
    final rates = UsdRates(prices);
    final txs = convertTransactions([
      buy(on: day1, qty: '100', price: '10'),
    ], rates);
    final pos = replay(txs, through: today).positions['XIST:AAA']!;
    expect(r20(pos.cost), r20(divide(d('1000'), d('30'))));
    final value =
        pos.quantity * convertPrices(prices, rates).latest('XIST:AAA')!.price;
    expect(r20(value), d('37.5'));
    final gain = value - pos.cost;
    expect(roundHalfEven(divide(gain * d('100'), pos.cost), 2), d('12.5'));
  });

  test('real: worked example', () {
    final prices = FixedPrices([obs('XIST:AAA', '15', today)]);
    final rates = RealRates(cpi({'2026-02': '20'}), today: today);
    final r = life(rates, [buy(on: day1, qty: '100', price: '10')], prices);
    expect(r.valueEnd, d('1500'));
    expect(r.gain, d('300'));
    expect(roundHalfEven(r.returnPercent!, 2), d('25'));
    expect(rates.note, 'inflation known through 2026-02');
    final est = RealRates(
      CpiSeries({'2026-02': CpiEntry(d('20'), 'tcmb')}),
      today: today,
    );
    expect(est.note, 'inflation known through 2026-02 (estimate)');
    final pos = replay(
      convertTransactions([buy(on: day1, qty: '100', price: '10')], rates),
      through: today,
    ).positions['XIST:AAA']!;
    expect(pos.cost, d('1200'));
  });

  test('fees and dividends convert at their own dates; split unchanged', () {
    final half = _Fixed({day1: d('0.5'), day2: d('0.25')});
    final out = convertTransactions([
      buy(on: day1, fees: '5'),
      dividend(on: day2, gross: '10', withholding: '1'),
      split(on: day2),
    ], half);
    expect(out[0].fees, d('2.5'));
    expect(out[1].grossAmount, d('2.5'));
    expect(out[1].withholding, d('0.25'));
    expect(out[2].ratioNumerator, 2);
    expect(out[2].unitPrice, isNull);
  });

  test('usd: a rate older than 10 days is missing', () {
    final buyDay = DateTime.utc(2026, 1, 20);
    final txs = [buy(on: buyDay, qty: '1', price: '10')];
    final stale = FixedPrices([
      obs('FX:USD', '30', DateTime.utc(2026, 1, 1)),
      obs('XIST:AAA', '15', today),
      obs('FX:USD', '40', today),
    ]);
    final r = life(UsdRates(stale), txs, stale);
    expect(r.unavailableReason, 'Missing USD/TRY rate for 2026-01-20');
    final fresh = FixedPrices([
      obs('FX:USD', '30', DateTime.utc(2026, 1, 12)),
      obs('XIST:AAA', '15', today),
      obs('FX:USD', '40', today),
    ]);
    expect(life(UsdRates(fresh), txs, fresh).unavailableReason, isNull);
  });

  test('measured Modified Dietz', () {
    final prices = FixedPrices([
      obs('FX:USD', '30', day1),
      obs('FX:USD', '32', day2),
      obs('XIST:AAA', '15', today),
      obs('FX:USD', '40', today),
    ]);
    final txs = [
      buy(on: day1, qty: '100', price: '10'),
      buy(on: day2, qty: '50', price: '12'),
    ];
    final r = life(UsdRates(prices), txs, prices);
    final hand =
        d('100') * d('15') / d('40') +
        d('50') * d('15') / d('40') -
        d('1000') / d('30') -
        d('600') / d('32');
    expect(r20(r.gain!), r20(hand.toDecimal(scaleOnInfinitePrecision: 40)));
    final by = computePeriod(
      period: Period.lifetime,
      today: today,
      transactions: [
        buy(
          on: day1,
          qty: '100',
          price: (d('10') * divide(Decimal.one, d('30'))).toString(),
        ),
        buy(
          on: day2,
          qty: '50',
          price: (d('12') * divide(Decimal.one, d('32'))).toString(),
        ),
      ],
      prices: FixedPrices([
        obs(
          'XIST:AAA',
          (d('15') * divide(Decimal.one, d('40'))).toString(),
          today,
        ),
      ]),
      calendar: cal,
    );
    expect(r20(r.returnPercent!), r20(by.returnPercent!));
  });

  test('usd: missing rate gives reason', () {
    final prices = FixedPrices([obs('XIST:AAA', '15', today)]);
    final r = life(UsdRates(prices), [buy(on: day1)], prices);
    expect(r.unavailableReason, 'Missing USD/TRY rate for 2026-01-05');
    expect(r.gain, isNull);
  });

  test('real: month before data is missing', () {
    final prices = FixedPrices([obs('XIST:AAA', '15', today)]);
    final rates = RealRates(cpi({'2026-03': '2'}), today: today);
    final r = life(rates, [buy(on: day1)], prices);
    expect(r.unavailableReason, 'Inflation missing for 2026-01');
    expect(
      life(RealRates(cpi({}), today: today), [
        buy(on: day1),
      ], prices).unavailableReason,
      'Add inflation data in Settings',
    );
  });

  test('holding FX:USD has USD gain 0', () {
    final prices = FixedPrices([
      obs('FX:USD', '30', day1),
      obs('FX:USD', '40', today),
    ]);
    final rates = UsdRates(prices);
    final txs = convertTransactions([
      buy(on: day1, qty: '10', price: '30', instrument: usdInst),
    ], rates);
    final pos = replay(txs, through: today).positions['FX:USD']!;
    final v =
        pos.quantity * convertPrices(prices, rates).latest('FX:USD')!.price;
    expect(r20(v - pos.cost), d('0'));
  });
  test('non-lifetime: baseline prices convert at the baseline rate', () {
    final prices = FixedPrices([
      obs('FX:USD', '30', day1),
      obs('FX:USD', '32', DateTime.utc(2026, 1, 30)),
      obs('XIST:AAA', '12', DateTime.utc(2026, 1, 30)),
      obs('XIST:AAA', '15', today),
      obs('FX:USD', '40', today),
    ]);
    final r = measuredPeriod(
      rates: UsdRates(prices),
      period: Period.oneMonth,
      today: today,
      transactions: [buy(on: day1, qty: '100', price: '10')],
      prices: prices,
      calendar: cal,
    );
    expect(r.baseline, DateTime.utc(2026, 2, 1));
    expect(r20(r.valueStart!), r20(divide(d('1200'), d('32'))));
    expect(r20(r.valueEnd!), d('37.5'));
  });

  test('stale latest price converts at the latest rate', () {
    final prices = FixedPrices([
      obs('XIST:AAA', '15', DateTime.utc(2026, 2, 20)),
      obs('FX:USD', '32', DateTime.utc(2026, 2, 20)),
      obs('FX:USD', '40', today),
    ]);
    final p = convertPrices(prices, UsdRates(prices)).latest('XIST:AAA')!;
    expect(r20(p.price), r20(d('15') * divide(Decimal.one, d('40'))));
  });

  test('invalid ledger reports the ledger, not a missing rate', () {
    final prices = FixedPrices([obs('XIST:AAA', '15', today)]);
    final r = life(UsdRates(prices), [sell(on: day1)], prices);
    expect(r.unavailableReason, 'Ledger has unresolved issues');
  });
}

class _Fixed implements Rates {
  _Fixed(this._m);
  final Map<DateTime, Decimal> _m;
  @override
  Decimal? at(DateTime day) => _m[day];
  @override
  Decimal? get current => Decimal.one;
  @override
  String missing(DateTime day) => 'x';
  @override
  String? get note => null;
}
