import 'package:decimal/decimal.dart';

import '../dates.dart';
import '../decimal_util.dart';
import 'instrument.dart';

enum TxType {
  buy('BUY'),
  sell('SELL'),
  dividend('DIVIDEND'),
  split('SPLIT');

  const TxType(this.json);
  final String json;
}

class Transaction {
  Transaction._({
    required this.type,
    required this.effectiveDate,
    required this.dayOrder,
    required this.instrument,
    this.quantity,
    this.unitPrice,
    this.fees,
    this.grossAmount,
    this.withholding,
    this.ratioNumerator,
    this.ratioDenominator,
    this.note,
  });

  factory Transaction.buy({
    required Instrument instrument,
    required DateTime date,
    required int dayOrder,
    required Decimal quantity,
    required Decimal unitPrice,
    required Decimal fees,
    String? note,
  }) => Transaction._(
    type: TxType.buy,
    effectiveDate: date,
    dayOrder: dayOrder,
    instrument: instrument,
    quantity: quantity,
    unitPrice: unitPrice,
    fees: fees,
    note: note,
  );

  factory Transaction.sell({
    required Instrument instrument,
    required DateTime date,
    required int dayOrder,
    required Decimal quantity,
    required Decimal unitPrice,
    required Decimal fees,
    String? note,
  }) => Transaction._(
    type: TxType.sell,
    effectiveDate: date,
    dayOrder: dayOrder,
    instrument: instrument,
    quantity: quantity,
    unitPrice: unitPrice,
    fees: fees,
    note: note,
  );

  factory Transaction.dividend({
    required Instrument instrument,
    required DateTime date,
    required int dayOrder,
    required Decimal grossAmount,
    required Decimal withholding,
    required Decimal fees,
    String? note,
  }) => Transaction._(
    type: TxType.dividend,
    effectiveDate: date,
    dayOrder: dayOrder,
    instrument: instrument,
    grossAmount: grossAmount,
    withholding: withholding,
    fees: fees,
    note: note,
  );

  factory Transaction.split({
    required Instrument instrument,
    required DateTime date,
    required int dayOrder,
    required int numerator,
    required int denominator,
    String? note,
  }) => Transaction._(
    type: TxType.split,
    effectiveDate: date,
    dayOrder: dayOrder,
    instrument: instrument,
    ratioNumerator: numerator,
    ratioDenominator: denominator,
    note: note,
  );

  factory Transaction.fromJson(Map<String, Object?> j) {
    final type = TxType.values.firstWhere(
      (t) => t.json == _field<String>(j, 'type'),
      orElse: () => throw FormatException('Unknown type', j['type']),
    );
    if (_field<String>(j, 'currency') != 'TRY') {
      throw FormatException('currency must be TRY', j['currency']);
    }
    final date = parseIsoDate(_field<String>(j, 'effective_date'));
    final order = _field<int>(j, 'day_order');
    final inst = Instrument.fromJson(
      _field<Map<String, Object?>>(j, 'instrument'),
    );
    final note = j['note'];
    if (note != null && note is! String) {
      throw FormatException('note must be a string', note);
    }
    final n = note as String?;
    const own = {
      TxType.buy: {'quantity', 'unit_price', 'fees'},
      TxType.sell: {'quantity', 'unit_price', 'fees'},
      TxType.dividend: {'gross_amount', 'withholding', 'fees'},
      TxType.split: {'ratio_numerator', 'ratio_denominator'},
    };
    const all = {
      'quantity',
      'unit_price',
      'fees',
      'gross_amount',
      'withholding',
      'ratio_numerator',
      'ratio_denominator',
    };
    for (final f in all.difference(own[type]!)) {
      if (j.containsKey(f)) {
        throw FormatException('$f is not allowed for ${type.json}');
      }
    }
    final t = switch (type) {
      TxType.buy || TxType.sell => Transaction._(
        type: type,
        effectiveDate: date,
        dayOrder: order,
        instrument: inst,
        quantity: _dec(j, 'quantity'),
        unitPrice: _dec(j, 'unit_price'),
        fees: _dec(j, 'fees', allowZero: true),
        note: n,
      ),
      TxType.dividend => Transaction._(
        type: type,
        effectiveDate: date,
        dayOrder: order,
        instrument: inst,
        grossAmount: _dec(j, 'gross_amount'),
        withholding: _dec(j, 'withholding', allowZero: true),
        fees: _dec(j, 'fees', allowZero: true),
        note: n,
      ),
      TxType.split => Transaction._(
        type: type,
        effectiveDate: date,
        dayOrder: order,
        instrument: inst,
        ratioNumerator: _field<int>(j, 'ratio_numerator'),
        ratioDenominator: _field<int>(j, 'ratio_denominator'),
        note: n,
      ),
    };
    final errors = t._structuralErrors();
    if (errors.isNotEmpty) throw FormatException(errors.join('; '));
    return t;
  }

  final TxType type;
  final DateTime effectiveDate;
  final int dayOrder;
  final Instrument instrument;
  final Decimal? quantity, unitPrice, fees, grossAmount, withholding;
  final int? ratioNumerator, ratioDenominator;
  final String? note;

  /// Money fields times [rate] at full precision; a split has none.
  Transaction scaledBy(Decimal rate) {
    if (type == TxType.split) return this;
    Decimal? k(Decimal? v) => v == null ? null : v * rate;
    return Transaction._(
      type: type,
      effectiveDate: effectiveDate,
      dayOrder: dayOrder,
      instrument: instrument,
      quantity: quantity,
      unitPrice: k(unitPrice),
      fees: k(fees),
      grossAmount: k(grossAmount),
      withholding: k(withholding),
      note: note,
    );
  }

  Decimal get netDividend =>
      grossAmount! - (withholding ?? Decimal.zero) - (fees ?? Decimal.zero);

  /// Messages are shown verbatim by the UI; all problems are collected.
  List<String> validate({required DateTime today}) => [
    if (effectiveDate.isAfter(today)) 'effective_date is in the future',
    ..._structuralErrors(),
  ];

  /// Everything except the future-date rule; fromJson enforces it too.
  List<String> _structuralErrors() {
    final e = <String>[];
    void fits(String name, Decimal? v) {
      if (v != null && (v.scale > 8 || v.precision - v.scale > 18)) {
        e.add('$name has too many digits');
      }
    }

    fits('quantity', quantity);
    fits('unit_price', unitPrice);
    fits('fees', fees);
    fits('gross_amount', grossAmount);
    fits('withholding', withholding);
    if (dayOrder < 1) e.add('day_order must be at least 1');
    if ((note?.length ?? 0) > 2000) {
      e.add('note is longer than 2000 characters');
    }
    void positive(String name, Decimal? v) {
      if (v == null) {
        e.add('$name is required');
      } else if (v <= Decimal.zero) {
        e.add('$name must be greater than 0');
      }
    }

    void nonNegative(String name, Decimal? v) {
      if (v == null) {
        e.add('$name is required');
      } else if (v < Decimal.zero) {
        e.add('$name must not be negative');
      }
    }

    switch (type) {
      case TxType.buy:
      case TxType.sell:
        positive('quantity', quantity);
        positive('unit_price', unitPrice);
        nonNegative('fees', fees);
      case TxType.dividend:
        if (instrument.assetClass != AssetClass.bistShare) {
          e.add('DIVIDEND is only allowed for BIST_SHARE');
        }
        positive('gross_amount', grossAmount);
        nonNegative('withholding', withholding);
        nonNegative('fees', fees);
        if (grossAmount != null &&
            withholding != null &&
            fees != null &&
            withholding! + fees! > grossAmount!) {
          e.add('deductions exceed gross_amount');
        }
      case TxType.split:
        if (instrument.assetClass != AssetClass.bistShare) {
          e.add('SPLIT is only allowed for BIST_SHARE');
        }
        if ((ratioNumerator ?? 0) < 1) {
          e.add('ratio_numerator must be at least 1');
        }
        if ((ratioDenominator ?? 0) < 1) {
          e.add('ratio_denominator must be at least 1');
        }
    }
    return e;
  }

  Map<String, Object?> toJson() => {
    'type': type.json,
    'effective_date': isoDate(effectiveDate),
    'day_order': dayOrder,
    'instrument': instrument.toJson(),
    if (quantity != null) 'quantity': quantity.toString(),
    if (unitPrice != null) 'unit_price': unitPrice.toString(),
    if (fees != null) 'fees': fees.toString(),
    'currency': 'TRY',
    if (grossAmount != null) 'gross_amount': grossAmount.toString(),
    if (withholding != null) 'withholding': withholding.toString(),
    if (ratioNumerator != null) 'ratio_numerator': ratioNumerator,
    if (ratioDenominator != null) 'ratio_denominator': ratioDenominator,
    if (note != null) 'note': note,
  };
}

T _field<T>(Map<String, Object?> j, String name) {
  final v = j[name];
  if (v is! T) throw FormatException('$name has wrong type or is missing', v);
  return v;
}

Decimal _dec(Map<String, Object?> j, String name, {bool allowZero = false}) {
  final s = _field<String>(j, name);
  try {
    return parseDecimalField(s, allowZero: allowZero);
  } on FormatException catch (e) {
    throw FormatException('$name: ${e.message}', s);
  }
}
