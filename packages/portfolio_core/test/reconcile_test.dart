import 'dart:convert';
import 'dart:typed_data';

import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  final buy1 = buy(on: DateTime.utc(2026, 10, 1), price: '10');
  final buy2 = buy(on: DateTime.utc(2026, 10, 2), price: '20');

  IssueKind only(ReconcileResult r) => r.issues.single.kind;

  test('offline additions from two devices are each counted once', () {
    final a = upsert(tx: buy1), b = upsert(tx: buy2);
    expect(reconcile([a, b, a]).transactions, hasLength(2));
  });

  test('two corrections create competing leaves; resolver converges', () {
    final r0 = upsert(tx: buy1);
    final r1 = revise(r0, buy1.copyWithPrice('11'));
    final r2 = revise(r0, buy1.copyWithPrice('12'));
    final res = reconcile([r0, r1, r2]);
    expect(only(res), IssueKind.competingLeaves);
    expect(res.issues.single.message, 'Competing edits need a decision');
    expect(res.transactions, isEmpty);
    expect(res.leaves, isEmpty);
    expect(res.conflicted[r0.transactionId], hasLength(2));

    final r3 = upsert(
      tx: buy1.copyWithPrice('12'),
      transactionId: r0.transactionId,
      supersedes: [r1.recordId, r2.recordId, r1.recordId],
    );
    final fixed = reconcile([r3, r2, r1, r0]);
    expect(fixed.issues, isEmpty);
    expect(fixed.transactions.single.unitPrice.toString(), '12');
  });

  test('edit vs void conflict is competing leaves', () {
    final r0 = upsert(tx: buy1);
    final res = reconcile([
      r0,
      revise(r0, buy1.copyWithPrice('11')),
      voidOf(r0),
    ]);
    expect(only(res), IssueKind.competingLeaves);
  });

  test('child before parent stays pending', () {
    final r1 = revise(upsert(tx: buy1), buy1.copyWithPrice('11'));
    final res = reconcile([r1]);
    expect(only(res), IssueKind.missingParent);
    expect(res.issues.single.recordIds, [r1.recordId]);
    expect(res.transactions, isEmpty);
  });

  test('same record id with different content is a conflict', () {
    final r = upsert(tx: buy1);
    final j = jsonDecode(utf8.decode(r.encode())) as Map<String, Object?>;
    (j['transaction'] as Map<String, Object?>)['unit_price'] = '99';
    final twin = LedgerRecord.decode(
      Uint8List.fromList(utf8.encode(jsonEncode(j))),
      portfolioId: testPortfolioId,
    );
    final other = upsert(tx: buy2);
    for (final input in [
      [r, twin, other],
      [other, twin, r],
    ]) {
      final res = reconcile(input);
      expect(only(res), IssueKind.contentConflict);
      expect(res.issues.single.recordIds, [r.recordId]);
      expect(res.leaves.keys, [other.transactionId]);
    }
  });

  test('void hides, re-upsert restores', () {
    final r0 = upsert(tx: buy1);
    final v1 = voidOf(r0);
    expect(reconcile([r0, v1]).transactions, isEmpty);
    expect(reconcile([r0, v1]).issues, isEmpty);
    final u2 = upsert(
      tx: buy1,
      transactionId: r0.transactionId,
      supersedes: [v1.recordId],
    );
    expect(reconcile([u2, v1, r0]).transactions, hasLength(1));
  });

  test('superseding a record of another transaction is invalid history', () {
    final a = upsert(tx: buy1), b = upsert(tx: buy2);
    final bad = upsert(
      tx: buy1,
      transactionId: a.transactionId,
      supersedes: [b.recordId],
    );
    final res = reconcile([a, b, bad]);
    expect(only(res), IssueKind.invalidHistory);
    expect(res.leaves.keys, [b.transactionId]);
  });

  test('self reference is invalid history', () {
    // Record ids are random, so build a self reference via decoded JSON.
    final r = upsert(tx: buy1);
    final j = jsonDecode(utf8.decode(r.encode())) as Map<String, Object?>;
    j['supersedes'] = [r.recordId];
    final self = LedgerRecord.decode(
      Uint8List.fromList(utf8.encode(jsonEncode(j))),
      portfolioId: testPortfolioId,
    );
    final res = reconcile([self]);
    expect(only(res), IssueKind.invalidHistory);
    expect(res.transactions, isEmpty);
  });

  test('cycle is invalid history, in any order', () {
    final a = upsert(tx: buy1);
    Map<String, Object?> j(LedgerRecord r, List<String> sup) =>
        (jsonDecode(utf8.decode(r.encode())) as Map<String, Object?>)
          ..['supersedes'] = sup;
    LedgerRecord dec(Map<String, Object?> m) => LedgerRecord.decode(
      Uint8List.fromList(utf8.encode(jsonEncode(m))),
      portfolioId: testPortfolioId,
    );
    final b = revise(a, buy1.copyWithPrice('11'));
    final a2 = dec(j(a, [b.recordId])); // a supersedes b, b supersedes a
    for (final input in [
      [a2, b],
      [b, a2],
    ]) {
      final res = reconcile(input);
      expect(only(res), IssueKind.invalidHistory);
      expect(res.leaves, isEmpty);
    }
  });

  test('two roots of one transaction are competing leaves', () {
    final a = upsert(tx: buy1);
    final b = upsert(tx: buy2, transactionId: a.transactionId);
    expect(only(reconcile([a, b])), IssueKind.competingLeaves);
  });

  test('an issue in one transaction leaves others active', () {
    final ok = upsert(tx: buy2);
    final pending = revise(upsert(tx: buy1), buy1.copyWithPrice('11'));
    final res = reconcile([pending, ok]);
    expect(res.transactions, hasLength(1));
    expect(res.leaves.keys, [ok.transactionId]);
  });
}
