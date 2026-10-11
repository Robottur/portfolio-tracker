import 'package:flutter/material.dart';
import 'package:portfolio_core/portfolio_core.dart';

import '../app/app_controller.dart';
import 'asset_labels.dart';
import 'conflicts_view.dart';
import 'privacy.dart';
import 'transaction_form.dart';

typedef TxEntry = ({String id, String recordId, Transaction tx});

/// Label/value rows for a transaction; numeric values must go through [Amount].
Widget txFields(Transaction t) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    _row('Type', Text(t.type.json)),
    _row(
      'Asset',
      Text('${assetClassLabel(t.instrument.assetClass)} ${t.instrument.code}'),
    ),
    _row('Date', Text(isoDate(t.effectiveDate))),
    _row('Day order', Text('${t.dayOrder}')),
    if (t.quantity != null)
      _row('Quantity', Amount(formatQuantity(t.quantity!))),
    if (t.unitPrice != null)
      _row('Unit price (TRY)', Amount(formatQuantity(t.unitPrice!))),
    if (t.grossAmount != null)
      _row('Gross amount (TRY)', Amount(formatQuantity(t.grossAmount!))),
    if (t.withholding != null)
      _row('Withholding (TRY)', Amount(formatQuantity(t.withholding!))),
    if (t.ratioNumerator != null)
      _row('Split ratio', Amount('${t.ratioNumerator}:${t.ratioDenominator}')),
    if (t.fees != null) _row('Fees (TRY)', Amount(formatQuantity(t.fees!))),
    if (t.note != null) _row('Note', Text(t.note!)),
  ],
);

Widget _row(String label, Widget value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 2),
  child: Row(
    children: [
      SizedBox(width: 140, child: Text(label)),
      Flexible(child: value),
    ],
  ),
);

class TransactionsScreen extends StatelessWidget {
  const TransactionsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final scan = controller.scan;
      final readOnly = scan?.readOnly ?? true;
      final conflicts = scan?.ledger.conflicted.length ?? 0;
      final entries =
          <TxEntry>[
            for (final e in (scan?.ledger.leaves ?? {}).entries)
              if (e.value.operation == RecordOp.upsert)
                (
                  id: e.key,
                  recordId: e.value.recordId,
                  tx: e.value.transaction!,
                ),
          ]..sort((a, b) {
            final c = b.tx.effectiveDate.compareTo(a.tx.effectiveDate);
            return c != 0 ? c : b.tx.dayOrder.compareTo(a.tx.dayOrder);
          });
      return Scaffold(
        floatingActionButton: FloatingActionButton(
          tooltip: 'Add transaction',
          onPressed: readOnly
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => TransactionForm(controller: controller),
                  ),
                ),
          child: const Icon(Icons.add),
        ),
        body: ListView(
          children: [
            if (readOnly)
              const ListTile(
                leading: Icon(Icons.lock_outline),
                title: Text(AppController.readOnlyMessage),
              ),
            if (conflicts > 0)
              ListTile(
                tileColor: Theme.of(context).colorScheme.errorContainer,
                leading: const Icon(Icons.call_split),
                title: Text('$conflicts conflicts need a decision'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ConflictsView(controller: controller),
                  ),
                ),
              ),
            if (entries.isEmpty) const ListTile(title: Text('No transactions')),
            for (final e in entries)
              ListTile(
                title: Text('${e.tx.type.json} ${e.tx.instrument.code}'),
                subtitle: Text(isoDate(e.tx.effectiveDate)),
                trailing: _summary(e.tx),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        TransactionDetail(controller: controller, entry: e),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );

  Widget _summary(Transaction t) => switch (t.type) {
    TxType.buy || TxType.sell => Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Amount(formatQuantity(t.quantity!)),
        Amount('@ ${formatQuantity(t.unitPrice!)}'),
      ],
    ),
    TxType.dividend => Amount(formatQuantity(t.grossAmount!)),
    TxType.split => Amount('${t.ratioNumerator}:${t.ratioDenominator}'),
  };
}

class TransactionDetail extends StatelessWidget {
  const TransactionDetail({
    super.key,
    required this.controller,
    required this.entry,
  });

  final AppController controller;
  final TxEntry entry;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final leaf = controller.scan?.ledger.leaves[entry.id];
      final live = leaf != null && leaf.operation == RecordOp.upsert;
      final tx = live ? leaf.transaction! : entry.tx;
      final blocked = controller.newIssues(
        controller.previewChange(replacingTransactionId: entry.id),
      );
      final recordId = live ? leaf.recordId : entry.recordId;
      final canEdit = live && !(controller.scan?.readOnly ?? true);
      return Scaffold(
        appBar: AppBar(title: Text('${tx.type.json} ${tx.instrument.code}')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            txFields(tx),
            if (blocked.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Voiding is blocked: ${blocked.first.message}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                FilledButton(
                  onPressed: canEdit
                      ? () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => TransactionForm(
                              controller: controller,
                              existing: (
                                id: entry.id,
                                recordId: recordId,
                                tx: tx,
                              ),
                            ),
                          ),
                        )
                      : null,
                  child: const Text('Correct'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: canEdit && blocked.isEmpty
                      ? () => _confirmVoid(context, recordId)
                      : null,
                  child: const Text('Void'),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );

  Future<void> _confirmVoid(BuildContext context, String recordId) async {
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Void this transaction?'),
        content: const Text('It stays in the history but no longer counts.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Void'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (!await controller.voidTransaction(
        entry.id,
        expectedRecordId: recordId,
      )) {
        messenger.showSnackBar(
          const SnackBar(content: Text(AppController.savedLocallyMessage)),
        );
      }
      if (context.mounted) nav.pop();
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_msg(e))));
    }
  }
}

String _msg(Object e) => e is StateError ? e.message : 'Could not save: $e';
