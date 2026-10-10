import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:portfolio_core/portfolio_core.dart';

import '../app/app_controller.dart';
import 'privacy.dart';
import 'transactions_screen.dart';

const _badNumber = 'Enter a number like 12.50';

class TransactionForm extends StatefulWidget {
  const TransactionForm({super.key, required this.controller, this.existing});

  final AppController controller;

  /// Set when correcting; the saved record supersedes this transaction.
  final TxEntry? existing;

  @override
  State<TransactionForm> createState() => _TransactionFormState();
}

class _TransactionFormState extends State<TransactionForm> {
  late TxType _type;
  late AssetClass _class;
  late DateTime _date;
  bool _orderTouched = false;
  bool _saving = false;
  String? _saveError;
  final _symbol = TextEditingController();
  final _order = TextEditingController();
  final _qty = TextEditingController();
  final _price = TextEditingController();
  final _fees = TextEditingController();
  final _gross = TextEditingController();
  final _withholding = TextEditingController();
  final _ratioNum = TextEditingController();
  final _ratioDen = TextEditingController();
  final _note = TextEditingController();

  AppController get _c => widget.controller;
  TxEntry? get _old => widget.existing;

  @override
  void initState() {
    super.initState();
    final t = _old?.tx;
    _type = t?.type ?? TxType.buy;
    _class = t?.instrument.assetClass ?? AssetClass.bistShare;
    _date = t?.effectiveDate ?? _c.today;
    _orderTouched = t != null;
    _order.text = '${t?.dayOrder ?? _c.nextDayOrder(_date)}';
    if (t != null) {
      _symbol.text = t.instrument.code;
      _qty.text = t.quantity?.toString() ?? '';
      _price.text = t.unitPrice?.toString() ?? '';
      _fees.text = t.fees?.toString() ?? '';
      _gross.text = t.grossAmount?.toString() ?? '';
      _withholding.text = t.withholding?.toString() ?? '';
      _ratioNum.text = t.ratioNumerator?.toString() ?? '';
      _ratioDen.text = t.ratioDenominator?.toString() ?? '';
      _note.text = t.note ?? '';
    }
    if (_class == AssetClass.gold) _symbol.text = 'GRAM';
  }

  @override
  void dispose() {
    for (final t in [
      _symbol, _order, _qty, _price, _fees, _gross, //
      _withholding, _ratioNum, _ratioDen, _note,
    ]) {
      t.dispose();
    }
    super.dispose();
  }

  // Empty optional fields count as zero; a bad number is null.
  Decimal? _dec(TextEditingController c, {bool optional = false}) {
    if (c.text.trim().isEmpty) return optional ? Decimal.zero : null;
    final s = parseUserDecimal(c.text);
    return s == null ? null : Decimal.parse(s);
  }

  Widget _decimalField(
    String key,
    String label,
    TextEditingController c, {
    bool optional = false,
  }) {
    final text = c.text.trim();
    final parsed = text.isEmpty ? null : parseUserDecimal(text);
    return TextField(
      key: Key(key),
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        errorText: text.isNotEmpty && parsed == null ? _badNumber : null,
        // Shows the value actually read, so a thousands-separator misread is visible.
        helperText: parsed == null ? null : '= $parsed',
      ),
      onChanged: (_) => setState(() {}),
    );
  }

  Widget _intField(String key, String label, TextEditingController c) =>
      TextField(
        key: Key(key),
        controller: c,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          errorText: c.text.isNotEmpty && int.tryParse(c.text.trim()) == null
              ? 'Enter a whole number'
              : null,
        ),
        onChanged: (v) => setState(() {
          if (identical(c, _order)) _orderTouched = true;
        }),
      );

  ({Transaction? tx, String? symbolError}) _build() {
    final Instrument inst;
    try {
      inst = Instrument.create(
        _class,
        _class == AssetClass.gold ? 'GRAM' : _symbol.text,
        name: _old?.tx.instrument.nameAtTrade ?? '',
      );
    } on FormatException catch (e) {
      return (tx: null, symbolError: _symbol.text.isEmpty ? null : e.message);
    }
    final order = int.tryParse(_order.text.trim());
    final note = _note.text.trim().isEmpty ? null : _note.text.trim();
    final fees = _dec(_fees, optional: true);
    if (order == null || fees == null) return (tx: null, symbolError: null);
    Transaction? tx;
    switch (_type) {
      case TxType.buy || TxType.sell:
        final q = _dec(_qty), p = _dec(_price);
        if (q != null && p != null) {
          final make = _type == TxType.buy ? Transaction.buy : Transaction.sell;
          tx = make(
            instrument: inst,
            date: _date,
            dayOrder: order,
            quantity: q,
            unitPrice: p,
            fees: fees,
            note: note,
          );
        }
      case TxType.dividend:
        final g = _dec(_gross), w = _dec(_withholding, optional: true);
        if (g != null && w != null) {
          tx = Transaction.dividend(
            instrument: inst,
            date: _date,
            dayOrder: order,
            grossAmount: g,
            withholding: w,
            fees: fees,
            note: note,
          );
        }
      case TxType.split:
        final n = int.tryParse(_ratioNum.text.trim());
        final d = int.tryParse(_ratioDen.text.trim());
        if (n != null && d != null) {
          tx = Transaction.split(
            instrument: inst,
            date: _date,
            dayOrder: order,
            numerator: n,
            denominator: d,
            note: note,
          );
        }
    }
    return (tx: tx, symbolError: null);
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.utc(2000),
      lastDate: _c.today,
    );
    if (d == null) return;
    setState(() {
      _date = DateTime.utc(d.year, d.month, d.day);
      if (!_orderTouched) _order.text = '${_c.nextDayOrder(_date)}';
    });
  }

  Future<void> _save(Transaction tx) async {
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final nav = Navigator.of(context);
    try {
      final old = _old;
      await (old == null
          ? _c.addTransaction(tx)
          : _c.correctTransaction(old.id, tx));
      nav.pop();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = e is StateError ? e.message : 'Could not save: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final built = _build();
    final tx = built.tx;
    final errors = tx?.validate(today: _c.today) ?? const <String>[];
    final preview = tx == null
        ? null
        : _c.previewChange(candidate: tx, replacingTransactionId: _old?.id);
    final issues = preview == null
        ? const <LedgerIssue>[]
        : _c.newIssues(preview);
    final readOnly = _c.scan?.readOnly ?? true;
    final canSave =
        tx != null && errors.isEmpty && issues.isEmpty && !readOnly && !_saving;
    final isGold = _class == AssetClass.gold;
    final bist = _class == AssetClass.bistShare;

    return Scaffold(
      appBar: AppBar(
        title: Text(_old == null ? 'New transaction' : 'Correct transaction'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_old != null) ...[
            const Text('Previous values'),
            txFields(_old!.tx),
            const Divider(height: 24),
          ],
          SegmentedButton<TxType>(
            showSelectedIcon: false,
            segments: [
              for (final t in TxType.values)
                ButtonSegment(
                  value: t,
                  label: Text(t.json),
                  enabled: bist || t == TxType.buy || t == TxType.sell,
                ),
            ],
            selected: {_type},
            onSelectionChanged: (s) => setState(() => _type = s.first),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<AssetClass>(
            key: const Key('assetClass'),
            initialValue: _class,
            decoration: const InputDecoration(labelText: 'Asset class'),
            items: [
              for (final c in AssetClass.values)
                DropdownMenuItem(value: c, child: Text(c.json)),
            ],
            onChanged: (c) => setState(() {
              _class = c!;
              if (c == AssetClass.gold) {
                _symbol.text = 'GRAM';
              } else if (_symbol.text == 'GRAM') {
                _symbol.clear();
              }
              if (c != AssetClass.bistShare &&
                  (_type == TxType.dividend || _type == TxType.split)) {
                _type = TxType.buy;
              }
            }),
          ),
          TextField(
            key: const Key('symbol'),
            controller: _symbol,
            readOnly: isGold,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: 'Symbol',
              errorText: built.symbolError,
            ),
            onChanged: (_) => setState(() {}),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Date  ${isoDate(_date)}'),
            trailing: const Icon(Icons.calendar_today),
            onTap: _pickDate,
          ),
          _intField('dayOrder', 'Day order', _order),
          if (_type == TxType.buy || _type == TxType.sell) ...[
            _decimalField('quantity', isGold ? 'grams' : 'Quantity', _qty),
            _decimalField('price', 'Unit price (TRY)', _price),
          ],
          if (_type == TxType.dividend) ...[
            _decimalField('gross', 'Gross amount (TRY)', _gross),
            _decimalField(
              'withholding',
              'Withholding (TRY)',
              _withholding,
              optional: true,
            ),
          ],
          if (_type == TxType.split) ...[
            _intField('ratioNum', 'Ratio numerator', _ratioNum),
            _intField('ratioDen', 'Ratio denominator', _ratioDen),
          ],
          if (_type != TxType.split)
            _decimalField('fees', 'Fees (TRY)', _fees, optional: true),
          TextField(
            key: const Key('note'),
            controller: _note,
            decoration: const InputDecoration(labelText: 'Note'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          if (tx != null) _previewPanel(tx, preview!),
          for (final m in [...errors, ...issues.map((i) => i.message)])
            Text(
              m,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_saveError != null)
            Text(
              _saveError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: canSave ? () => _save(tx) : null,
              child: const Text('Save'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewPanel(Transaction tx, ReplayResult after) {
    final before = _c.replayNow.positions[tx.instrument.id];
    final now = after.positions[tx.instrument.id];
    String pair(String Function(Position?) f) => '${f(before)} → ${f(now)}';
    String qty(Position? p) => formatQuantity(p?.quantity ?? Decimal.zero);
    String cost(Position? p) => formatTry(p?.cost ?? Decimal.zero);
    String avg(Position? p) {
      final a = p?.averageCost;
      return a == null ? '-' : formatTry(a);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Effect on ${tx.instrument.id}'),
        Row(
          children: [
            const SizedBox(width: 100, child: Text('Quantity')),
            Amount(pair(qty)),
          ],
        ),
        Row(
          children: [
            const SizedBox(width: 100, child: Text('Cost')),
            Amount(pair(cost)),
          ],
        ),
        Row(
          children: [
            const SizedBox(width: 100, child: Text('Average')),
            Amount(pair(avg)),
          ],
        ),
      ],
    );
  }
}
