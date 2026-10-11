import 'package:flutter/material.dart';

import 'package:portfolio_core/portfolio_core.dart';

import '../app/app_controller.dart';
import 'transactions_screen.dart';

class ConflictsView extends StatefulWidget {
  const ConflictsView({super.key, required this.controller});

  final AppController controller;

  @override
  State<ConflictsView> createState() => _ConflictsViewState();
}

class _ConflictsViewState extends State<ConflictsView> {
  bool _busy = false; // one resolution at a time

  AppController get controller => widget.controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final conflicts = controller.scan?.ledger.conflicted ?? {};
      final readOnly = (controller.scan?.readOnly ?? true) || _busy;
      return Scaffold(
        appBar: AppBar(title: const Text('Conflicts')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (conflicts.isEmpty) const Text('No conflicts'),
            for (final e in conflicts.entries) ...[
              for (final leaf in e.value)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Device ${leaf.deviceId}'),
                        Text('Created ${leaf.createdAt.toIso8601String()}'),
                        const SizedBox(height: 8),
                        if (leaf.transaction != null)
                          txFields(leaf.transaction!)
                        else
                          const Text('VOID'),
                        TextButton(
                          onPressed: readOnly
                              ? null
                              : () => _run(
                                  context,
                                  controller.resolveConflict(
                                    e.key,
                                    leaf.transaction,
                                    expectedLeafIds: _ids(e.value),
                                  ),
                                ),
                          child: const Text('Keep this version'),
                        ),
                      ],
                    ),
                  ),
                ),
              OutlinedButton(
                onPressed: readOnly
                    ? null
                    : () => _run(
                        context,
                        controller.resolveConflict(
                          e.key,
                          null,
                          expectedLeafIds: _ids(e.value),
                        ),
                      ),
                child: const Text('Void transaction'),
              ),
              const Divider(height: 32),
            ],
          ],
        ),
      );
    },
  );

  Set<String> _ids(List<LedgerRecord> leaves) => {
    for (final l in leaves) l.recordId,
  };

  Future<void> _run(BuildContext context, Future<bool> action) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      if (!await action) {
        messenger.showSnackBar(
          const SnackBar(content: Text(AppController.savedLocallyMessage)),
        );
      }
    } on Object catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(e is StateError ? e.message : 'Could not save: $e'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
