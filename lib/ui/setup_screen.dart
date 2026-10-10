import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../platform/folder_access.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.controller,
    this.pick = pickRecordFolder,
  });

  final AppController controller;
  final Future<PickedFolder?> Function() pick;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  String? _error;
  bool _busy = false;

  Future<void> _open({String? createName}) async {
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final p = await widget.pick();
      if (p == null) return;
      await widget.controller.openFolder(
        p.folder,
        p.location,
        createName: createName,
      );
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = e is StateError ? e.message : e.toString());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NameDialog(),
    );
    if (name != null && name.trim().isNotEmpty) {
      await _open(createName: name.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final lost = widget.controller.folderAccessLost;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Asset Portfolio',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Your portfolio lives in a folder you choose. To use it on '
                  'several devices, set up Syncthing separately and share '
                  'that folder; this app does not sync for you.',
                ),
                const SizedBox(height: 24),
                if (lost) ...[
                  const Text('The portfolio folder is no longer accessible.'),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _busy ? null : _open,
                    child: const Text('Choose folder again'),
                  ),
                  const SizedBox(height: 8),
                ],
                if (lost)
                  OutlinedButton(
                    onPressed: _busy ? null : _create,
                    child: const Text('Create portfolio'),
                  )
                else ...[
                  FilledButton(
                    onPressed: _busy ? null : _create,
                    child: const Text('Create portfolio'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _busy ? null : _open,
                    child: const Text('Open existing portfolio'),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog();

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Portfolio name'),
    content: TextField(controller: _c, autofocus: true),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _c.text),
        child: const Text('Create'),
      ),
    ],
  );
}
