import 'package:decimal/decimal.dart';

import '../dates.dart';
import '../decimal_util.dart';
import '../ledger/issue.dart';
import '../model/instrument.dart';
import '../model/transaction.dart';

class Position {
  Position(this.instrument);

  final Instrument instrument;
  Decimal quantity = Decimal.zero;
  Decimal cost = Decimal.zero;
  Decimal realized = Decimal.zero;
  Decimal dividends = Decimal.zero;

  Decimal? get averageCost =>
      quantity > Decimal.zero ? divide(cost, quantity) : null;
}

class Flow {
  const Flow(this.date, this.amount);

  final DateTime date;
  final Decimal amount;
}

class ReplayResult {
  const ReplayResult(this.positions, this.flows, this.issues);

  final Map<String, Position> positions;
  final List<Flow> flows;
  final List<LedgerIssue> issues;

  bool get valid => issues.isEmpty;
}

/// Weighted-average-cost replay. [through] is inclusive.
ReplayResult replay(Iterable<Transaction> txs, {DateTime? through}) {
  // Index tiebreak keeps the sort stable for colliding entries.
  final sorted =
      [
        for (final (i, t) in txs.indexed)
          if (through == null || !t.effectiveDate.isAfter(through)) (i, t),
      ]..sort((a, b) {
        final c = a.$2.effectiveDate.compareTo(b.$2.effectiveDate);
        if (c != 0) return c;
        final o = a.$2.dayOrder.compareTo(b.$2.dayOrder);
        return o != 0 ? o : a.$1.compareTo(b.$1);
      });

  final positions = <String, Position>{};
  final flows = <Flow>[];
  final issues = <LedgerIssue>[];
  Transaction? prev;

  for (final (_, t) in sorted) {
    final id = t.instrument.id;
    final ctx = [id, isoDate(t.effectiveDate)];
    if (prev != null &&
        prev.effectiveDate == t.effectiveDate &&
        prev.dayOrder == t.dayOrder) {
      issues.add(
        LedgerIssue(
          IssueKind.dayOrderCollision,
          'Two entries share the same date and order',
          recordIds: ctx,
        ),
      );
    }
    prev = t;

    final p = positions[id];
    switch (t.type) {
      case TxType.buy:
        final amount = t.quantity! * t.unitPrice! + t.fees!;
        final pos = positions.putIfAbsent(id, () => Position(t.instrument));
        pos.quantity += t.quantity!;
        pos.cost += amount;
        flows.add(Flow(t.effectiveDate, amount));
      case TxType.sell:
        final q = t.quantity!;
        if (p == null || q > p.quantity) {
          issues.add(
            LedgerIssue(
              IssueKind.oversell,
              'Sell quantity exceeds holding',
              recordIds: ctx,
            ),
          );
          continue;
        }
        final released = q == p.quantity
            ? p.cost
            : divide(p.cost * q, p.quantity);
        final proceeds = q * t.unitPrice! - t.fees!;
        p.quantity -= q;
        p.cost -= released;
        p.realized += proceeds - released;
        flows.add(Flow(t.effectiveDate, -proceeds));
      case TxType.dividend:
        final net = t.netDividend;
        final pos = positions.putIfAbsent(id, () => Position(t.instrument));
        pos.dividends += net;
        flows.add(Flow(t.effectiveDate, -net));
      case TxType.split:
        if (p != null) {
          final q = divide(
            p.quantity * Decimal.fromInt(t.ratioNumerator!),
            Decimal.fromInt(t.ratioDenominator!),
          );
          // A record quantity has at most 8 decimals, so the rest could never be sold.
          if (q.scale > 8) {
            issues.add(
              LedgerIssue(
                IssueKind.unsupportedSplit,
                'Split leaves a fraction beyond 8 decimals; '
                'record the cash-in-lieu sale first',
                recordIds: ctx,
              ),
            );
            continue;
          }
          p.quantity = q;
        }
    }
  }
  return ReplayResult(positions, flows, issues);
}
