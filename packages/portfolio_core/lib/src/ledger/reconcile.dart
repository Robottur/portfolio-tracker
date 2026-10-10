import 'dart:convert';

import '../model/record.dart';
import '../model/transaction.dart';
import 'issue.dart';

class ReconcileResult {
  const ReconcileResult(this.leaves, this.issues, this.conflicted);

  /// transactionId -> single active leaf (UPSERT or VOID).
  final Map<String, LedgerRecord> leaves;
  final List<LedgerIssue> issues;

  /// transactionId -> competing leaves.
  final Map<String, List<LedgerRecord>> conflicted;

  /// UPSERT leaves only, ordered by transaction id.
  List<Transaction> get transactions => [
    for (final id in leaves.keys.toList()..sort())
      if (leaves[id]!.operation == RecordOp.upsert) leaves[id]!.transaction!,
  ];
}

/// Never throws and never picks a winner: any transaction with an issue is
/// left out of [ReconcileResult.leaves]. Output does not depend on input order.
ReconcileResult reconcile(Iterable<LedgerRecord> records) {
  final issues = <LedgerIssue>[];
  final excluded = <String>{};

  // Dedupe by recordId; same id with different content is a conflict.
  final byId = <String, LedgerRecord>{};
  final conflictTx = <String, Set<String>>{}; // recordId -> transactionIds
  for (final r in records) {
    final old = byId[r.recordId];
    if (old == null) {
      byId[r.recordId] = r;
    } else if (!old.sameContentAs(r)) {
      conflictTx
          .putIfAbsent(r.recordId, () => {old.transactionId})
          .add(r.transactionId);
    }
  }
  for (final e in conflictTx.entries) {
    excluded.addAll(e.value);
    issues.add(
      LedgerIssue(
        IssueKind.contentConflict,
        'Two different files share one record id',
        transactionId: e.value.length == 1 ? e.value.first : null,
        recordIds: [e.key],
      ),
    );
  }

  final groups = <String, List<LedgerRecord>>{};
  for (final r in byId.values) {
    groups.putIfAbsent(r.transactionId, () => []).add(r);
  }

  final leaves = <String, LedgerRecord>{};
  final conflicted = <String, List<LedgerRecord>>{};
  for (final txId in groups.keys.toList()..sort()) {
    if (excluded.contains(txId)) continue;
    final group = groups[txId]!
      ..sort((a, b) => a.recordId.compareTo(b.recordId));
    final inGroup = {for (final r in group) r.recordId};

    final invalid = <String>{}, missing = <String>{};
    final superseded = <String>{};
    final refs = <String, Set<String>>{}; // recordId -> in-group parents
    for (final r in group) {
      final parents = refs[r.recordId] = {};
      for (final p in r.supersedes.toSet()) {
        if (p == r.recordId) {
          invalid.add(r.recordId);
        } else if (inGroup.contains(p)) {
          parents.add(p);
          superseded.add(p);
        } else if (byId.containsKey(p)) {
          invalid.add(r.recordId); // parent belongs to another transaction
        } else {
          missing.add(r.recordId);
        }
      }
    }
    if (invalid.isEmpty && _hasCycle(refs)) {
      invalid.addAll(inGroup);
    }

    if (invalid.isNotEmpty) {
      issues.add(
        LedgerIssue(
          IssueKind.invalidHistory,
          'Invalid revision history',
          transactionId: txId,
          recordIds: invalid.toList()..sort(),
        ),
      );
    } else if (missing.isNotEmpty) {
      issues.add(
        LedgerIssue(
          IssueKind.missingParent,
          'Waiting for an earlier revision to sync',
          transactionId: txId,
          recordIds: missing.toList()..sort(),
        ),
      );
    } else {
      final heads = [
        for (final r in group)
          if (!superseded.contains(r.recordId)) r,
      ];
      if (heads.length == 1) {
        leaves[txId] = heads.single;
      } else {
        conflicted[txId] = heads;
        issues.add(
          LedgerIssue(
            IssueKind.competingLeaves,
            'Competing edits need a decision',
            transactionId: txId,
            recordIds: [for (final h in heads) h.recordId],
          ),
        );
      }
    }
  }

  issues.sort((a, b) => _key(a).compareTo(_key(b)));
  return ReconcileResult(leaves, issues, conflicted);
}

String _key(LedgerIssue i) =>
    '${i.kind.index.toString().padLeft(2, '0')}|${i.transactionId}|${jsonEncode(i.recordIds)}';

bool _hasCycle(Map<String, Set<String>> refs) {
  final done = <String>{}, active = <String>{};
  bool visit(String n) {
    if (done.contains(n)) return false;
    if (!active.add(n)) return true;
    for (final p in refs[n]!) {
      if (visit(p)) return true;
    }
    active.remove(n);
    done.add(n);
    return false;
  }

  return refs.keys.any(visit);
}
