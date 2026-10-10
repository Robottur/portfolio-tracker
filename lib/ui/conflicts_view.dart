import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import 'transactions_screen.dart';

class ConflictsView extends StatelessWidget {
  const ConflictsView({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final conflicts = controller.scan?.ledger.conflicted ?? {};
      final readOnly = controller.scan?.readOnly ?? true;
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
                        controller.resolveConflict(e.key, null),
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

  Future<void> _run(BuildContext context, Future<void> action) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action;
    } on Object catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(e is StateError ? e.message : 'Could not save: $e'),
        ),
      );
    }
  }
}
