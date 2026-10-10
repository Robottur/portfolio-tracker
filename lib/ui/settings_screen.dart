import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:portfolio_core/portfolio_core.dart';

import '../app/app_controller.dart';
import '../platform/folder_access.dart';
import 'privacy.dart';
import 'status_banner.dart';

const _problemKinds = {
  IssueKind.badFile,
  IssueKind.missingFile,
  IssueKind.contentConflict,
  IssueKind.unsupportedVersion,
};

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    this.pick = pickRecordFolder,
  });

  final AppController controller;
  final Future<PickedFolder?> Function() pick;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AssetClass _class = AssetClass.bistShare;
  late DateTime _date = _c.today;
  final _symbol = TextEditingController();
  final _price = TextEditingController();
  String? _message;

  AppController get _c => widget.controller;

  @override
  void dispose() {
    _symbol.dispose();
    _price.dispose();
    super.dispose();
  }

  // Runs an action and shows its failure inline instead of crashing the screen.
  Future<void> _run(Future<String?> Function() f) async {
    String? msg;
    try {
      msg = await f();
    } on Object catch (e) {
      // Never e.toString(): it can echo a private value.
      msg = e is StateError
          ? e.message
          : 'Could not complete: ${e.runtimeType}';
    }
    if (mounted) setState(() => _message = msg);
  }

  static String _report(CopyReport r) {
    final s = 'Copied ${r.copied}, already present ${r.alreadyPresent}';
    return r.errors.isEmpty ? s : '$s\n${r.errors.join('\n')}';
  }

  Future<void> _chooseAgain() => _run(() async {
    final p = await widget.pick();
    if (p == null) return null;
    await _c.openFolder(p.folder, p.location);
    return null;
  });

  Future<void> _export() => _run(() async {
    final p = await widget.pick();
    return p == null ? null : _report(await _c.exportTo(p.folder));
  });

  Future<void> _restore() => _run(() async {
    final p = await widget.pick();
    if (p == null || !mounted) return null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: const Text(
          'Restore records from this folder into the current portfolio?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    return ok == true ? _report(await _c.restoreFrom(p.folder)) : null;
  });

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.utc(2000),
      lastDate: _c.today,
    );
    if (d != null) setState(() => _date = DateTime.utc(d.year, d.month, d.day));
  }

  ({Instrument? inst, String? error}) _instrument() {
    if (_symbol.text.trim().isEmpty) return (inst: null, error: null);
    try {
      final raw = _class == AssetClass.gold ? 'GRAM' : _symbol.text;
      return (inst: Instrument.create(_class, raw), error: null);
    } on FormatException catch (e) {
      return (inst: null, error: e.message);
    }
  }

  Future<void> _savePrice(Instrument inst, Decimal price) => _run(() async {
    await _c.setManualPrice(inst.id, _date, price);
    _price.clear();
    return null;
  });

  static final _bareId = RegExp(r'^[0-9a-f-]{36}$');

  static String _problemName(LedgerIssue i) => i.recordIds.isEmpty
      ? 'Folder'
      : i.recordIds.map((r) => _bareId.hasMatch(r) ? '$r.json' : r).join(', ');

  String _status(String id) {
    final s = _c.refresher.status[id];
    return [
      if (s?.lastSuccess case final t?) 'Last success: ${StatusBanner.fmt(t)}',
      if (s?.lastError case final e?) 'Last error: $e',
      if (s?.retryNotBefore case final t?)
        'Retrying after ${StatusBanner.fmt(t)}',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final scan = _c.scan;
    final problems = [
      ...?scan?.fileIssues,
      for (final i in scan?.ledger.issues ?? const <LedgerIssue>[])
        if (_problemKinds.contains(i.kind)) i,
    ];
    final anyEnabled = _c.prefs.enabledSources.isNotEmpty;
    final masked = PrivacyScope.maskedOf(context);
    final raw = _price.text.trim().isEmpty
        ? null
        : parseUserDecimal(_price.text);
    // isStorablePrice also bounds the digits; manual entry allows 8 decimals.
    final parsed =
        raw != null &&
            isStorablePrice(Decimal.parse(raw)) &&
            (raw.split('.').length < 2 || raw.split('.')[1].length <= 8)
        ? raw
        : null;
    final built = _instrument();
    final isGold = _class == AssetClass.gold;
    final heading = Theme.of(context).textTheme.titleMedium;

    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_message != null) Card(child: ListTile(title: Text(_message!))),
          Text('Folder', style: heading),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_c.prefs.folderLocation ?? 'No folder'),
            subtitle: scan == null
                ? null
                : Text('Last scan: ${StatusBanner.fmt(scan.scannedAt)}'),
          ),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => _run(() async {
                  await _c.rescan();
                  return null;
                }),
                child: const Text('Rescan'),
              ),
              OutlinedButton(
                onPressed: _chooseAgain,
                child: const Text('Choose folder again'),
              ),
            ],
          ),
          const Divider(height: 32),
          Text('Price sources', style: heading),
          for (final s in _c.sources)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s.label),
              subtitle: Text(
                'Sends: asset symbols. Contacts: ${s.domains.join(', ')}. '
                'Your quantities and costs are never sent.'
                '${_status(s.id).isEmpty ? '' : '\n${_status(s.id)}'}',
              ),
              value: _c.prefs.enabledSources.contains(s.id),
              onChanged: (on) => _run(() async {
                await _c.setSourceEnabled(s.id, on);
                return null;
              }),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: anyEnabled
                  ? () => _run(() async {
                      await _c.refreshPrices(manual: true);
                      return null;
                    })
                  : null,
              child: const Text('Refresh now'),
            ),
          ),
          const Divider(height: 32),
          Text('Manual prices', style: heading),
          DropdownButtonFormField<AssetClass>(
            key: const Key('manualClass'),
            initialValue: _class,
            decoration: const InputDecoration(labelText: 'Asset class'),
            items: [
              for (final c in AssetClass.values)
                DropdownMenuItem(value: c, child: Text(c.json)),
            ],
            onChanged: (c) => setState(() => _class = c!),
          ),
          TextField(
            key: const Key('manualSymbol'),
            controller: _symbol,
            readOnly: isGold,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: isGold ? 'Symbol (GRAM)' : 'Symbol',
              errorText: built.error,
            ),
            onChanged: (_) => setState(() {}),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Date  ${isoDate(_date)}'),
            trailing: const Icon(Icons.calendar_today),
            onTap: _pickDate,
          ),
          TextField(
            key: const Key('manualPrice'),
            controller: _price,
            obscureText: masked,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Price (TRY)',
              errorText: _price.text.trim().isNotEmpty && parsed == null
                  ? 'Enter a positive price with at most 8 decimals'
                  : null,
              helperText: parsed == null || masked ? null : '= $parsed',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed:
                  (isGold || built.inst != null) &&
                      parsed != null &&
                      !(scan?.readOnly ?? true)
                  ? () => _savePrice(
                      isGold ? Instrument.create(_class, 'GRAM') : built.inst!,
                      Decimal.parse(parsed),
                    )
                  : null,
              child: const Text('Save price'),
            ),
          ),
          for (final o in _c.prices.manualPrices)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${o.instrumentId}  ${isoDate(o.sessionDate)}'),
              subtitle: Amount('${formatTry(o.price)} TRY'),
              trailing: IconButton(
                tooltip: 'Delete manual price',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _run(() async {
                  await _c.removeManualPrice(o.instrumentId, o.sessionDate);
                  return null;
                }),
              ),
            ),
          const Divider(height: 32),
          Text('Problems', style: heading),
          if (problems.isEmpty) const Text('No problems found.'),
          for (final i in problems)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_problemName(i)),
              subtitle: Text(i.message),
            ),
          if (problems.any((i) => i.kind == IssueKind.missingFile))
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: () => _run(() async {
                  final n = await _c.republishMissing();
                  return 'Restored $n ${n == 1 ? 'record' : 'records'}';
                }),
                child: const Text('Restore missing records'),
              ),
            ),
          const Divider(height: 32),
          Text('Backup', style: heading),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: _export,
                child: const Text('Export copy…'),
              ),
              OutlinedButton(
                onPressed: _restore,
                child: const Text('Restore from…'),
              ),
            ],
          ),
          const Divider(height: 32),
          Text('Privacy', style: heading),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Hide amounts by default'),
            value: _c.prefs.privacyMode,
            onChanged: (on) => _run(() async {
              await _c.setPrivacy(on);
              return null;
            }),
          ),
          const Divider(height: 32),
          Text('About', style: heading),
          const Text('No telemetry, analytics or crash reporting.'),
        ],
      ),
    );
  }
}
