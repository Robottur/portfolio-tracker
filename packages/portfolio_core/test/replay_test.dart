import 'package:decimal/decimal.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

final d1 = DateTime.utc(2026, 1, 1);
final d2 = DateTime.utc(2026, 1, 2);
final d3 = DateTime.utc(2026, 1, 3);
final d4 = DateTime.utc(2026, 1, 4);

List<String> strs(Iterable<Object?> xs) => xs.map((d) => d.toString()).toList();

void main() {
  test('A: purchases and partial sale', () {
    final r = replay([
      buy(on: d1, qty: '100', price: '10'),
      buy(on: d2, qty: '100', price: '20'),
      sell(on: d3, qty: '50', price: '18'),
    ]);
    final p = r.positions['XIST:AAA']!;
    expect(strs([p.quantity, p.cost, p.averageCost, p.realized]), [
      '150',
      '2250',
      '15',
      '150',
    ]);
    expect(strs(r.flows.map((f) => f.amount)), ['1000', '2000', '-900']);
    expect(r.valid, isTrue);
  });

  test('B: fees and full liquidation leave exact zero', () {
    final r = replay([
      buy(on: d1, qty: '100', price: '10', fees: '10'),
      sell(on: d2, qty: '100', price: '12', fees: '10'),
    ]);
    final p = r.positions['XIST:AAA']!;
    expect(p.quantity, Decimal.zero);
    expect(p.cost, Decimal.zero);
    expect(p.averageCost, isNull);
    expect(p.realized.toString(), '180');
  });

  test('C: split then dividend', () {
    final r = replay([
      buy(on: d1, qty: '100', price: '10'),
      split(on: d2),
      dividend(on: d3, gross: '100', withholding: '10'),
    ]);
    final p = r.positions['XIST:AAA']!;
    expect(strs([p.quantity, p.cost, p.averageCost, p.dividends]), [
      '200',
      '1000',
      '5',
      '90',
    ]);
    expect(r.flows.last.amount.toString(), '-90');
  });

  test('repeated partial sales then full close leave no dust', () {
    final r = replay([
      buy(on: d1, qty: '3', price: '10'),
      sell(on: d2, qty: '1', price: '10'),
      sell(on: d3, qty: '1', price: '10'),
      sell(on: d4, qty: '1', price: '10'),
    ]);
    expect(r.positions['XIST:AAA']!.cost, Decimal.zero);
  });

  test('two offline sales that oversell are flagged and skipped', () {
    final r = replay([
      buy(on: d1, qty: '10'),
      sell(on: d2, qty: '8'),
      sell(on: d3, qty: '8'),
    ]);
    expect(r.valid, isFalse);
    final i = r.issues.single;
    expect(i.kind, IssueKind.oversell);
    expect(i.message, 'Sell quantity exceeds holding');
    expect(i.recordIds, ['XIST:AAA', '2026-01-03']);
    expect(r.positions['XIST:AAA']!.quantity.toString(), '2');
    expect(r.flows, hasLength(2));
  });

  test('same date same day_order is a collision', () {
    final r = replay([buy(on: d1), buy(on: d1)]);
    final i = r.issues.single;
    expect(i.kind, IssueKind.dayOrderCollision);
    expect(i.message, 'Two entries share the same date and order');
    expect(i.recordIds, ['XIST:AAA', '2026-01-01']);
    expect(r.valid, isFalse);
  });

  test('G: sort is by effective date, not input order', () {
    final txs = [
      buy(on: d1, qty: '100', price: '10'),
      buy(on: d2, qty: '100', price: '20'),
      sell(on: d3, qty: '50', price: '18'),
    ];
    final r = replay(txs.reversed);
    expect(r.valid, isTrue);
    expect(strs(r.flows.map((f) => f.amount)), ['1000', '2000', '-900']);
  });

  test('dayOrder orders entries within a day', () {
    final r = replay([sell(on: d1, dayOrder: 2), buy(on: d1, dayOrder: 1)]);
    expect(r.valid, isTrue);
  });

  test('through is inclusive', () {
    final r = replay([buy(on: d1), buy(on: d2), buy(on: d3)], through: d2);
    expect(r.positions['XIST:AAA']!.quantity.toString(), '2');
    expect(r.flows, hasLength(2));
  });

  test('split without a position is a no-op', () {
    final r = replay([split(on: d1)]);
    expect(r.valid, isTrue);
    expect(r.positions, isEmpty);
  });

  test('split with a non-terminating ratio stays exact on cost', () {
    final r = replay([
      buy(on: d1, qty: '3', price: '10'),
      split(on: d2, numerator: 1, denominator: 3),
    ]);
    final p = r.positions['XIST:AAA']!;
    expect(strs([p.quantity, p.cost]), ['1', '30']);
  });
}
