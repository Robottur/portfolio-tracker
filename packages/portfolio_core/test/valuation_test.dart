import 'package:decimal/decimal.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

Position pos(String id, String qty) =>
    Position(Instrument.create(AssetClass.bistShare, id.split(':').last))
      ..quantity = Decimal.parse(qty);

void main() {
  final d = date(2026, 10, 9);

  test('missing price is never zero', () {
    final prices = {'XIST:AAA': obs('XIST:AAA', '10.5', d)};
    final v = valueHoldings({
      'XIST:AAA': pos('XIST:AAA', '2'),
      'XIST:BBB': pos('XIST:BBB', '3'),
      'XIST:ZZZ': pos('XIST:ZZZ', '0'),
    }, (id) => prices[id]);
    expect(v.total, isNull);
    expect(v.knownValue, Decimal.parse('21'));
    expect(v.missing, ['XIST:BBB']);
    expect(v.holdingValues.keys, ['XIST:AAA']);
    expect(v.status, DataStatus.unavailable);
  });

  test('status by kinds and exact value', () {
    Valuation run(PriceKind k) => valueHoldings({
      'XIST:AAA': pos('XIST:AAA', '0.3'),
    }, (_) => obs('XIST:AAA', '0.1', d, kind: k));
    expect(run(PriceKind.close).total, Decimal.parse('0.03'));
    expect(run(PriceKind.close).status, DataStatus.complete);
    expect(run(PriceKind.delayedQuote).status, DataStatus.indicative);
    expect(run(PriceKind.derived).status, DataStatus.indicative);
    expect(run(PriceKind.manual).status, DataStatus.manual);
  });

  test('missing list is sorted', () {
    final v = valueHoldings({
      'XIST:BB': pos('XIST:BB', '1'),
      'XIST:AA': pos('XIST:AA', '1'),
    }, (_) => null);
    expect(v.missing, ['XIST:AA', 'XIST:BB']);
    expect(v.knownValue, Decimal.zero);
  });
}
