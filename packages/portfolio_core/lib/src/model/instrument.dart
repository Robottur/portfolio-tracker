enum AssetClass {
  bistShare('BIST_SHARE', 'XIST'),
  fx('FX', 'FX'),
  crypto('CRYPTO', 'CRYPTO'),
  gold('GOLD', 'GOLD');

  const AssetClass(this.json, this.prefix);
  final String json;
  final String prefix;

  static AssetClass fromJson(String s) => values.firstWhere(
    (c) => c.json == s,
    orElse: () => throw FormatException('Unknown asset_class', s),
  );
}

final _bist = RegExp(r'^[A-Z][A-Z0-9]{1,9}$');
final _fx = RegExp(r'^[A-Z]{3}$');
final _crypto = RegExp(r'^[A-Z0-9]{2,10}$');

bool _validSymbol(AssetClass c, String s) => switch (c) {
  AssetClass.bistShare => _bist.hasMatch(s),
  AssetClass.fx => _fx.hasMatch(s) && s != 'TRY',
  AssetClass.crypto => _crypto.hasMatch(s),
  AssetClass.gold => s == 'GRAM',
};

class Instrument {
  Instrument._(this.assetClass, this.id, this.symbolAtTrade, this.nameAtTrade);

  factory Instrument.create(
    AssetClass c,
    String rawSymbol, {
    String name = '',
  }) {
    final symbol = rawSymbol.trim().toUpperCase();
    if (!_validSymbol(c, symbol)) {
      throw FormatException('Invalid symbol for ${c.json}', rawSymbol);
    }
    if (name.length > 200) throw FormatException('name too long', name);
    return Instrument._(c, '${c.prefix}:$symbol', symbol, name);
  }

  factory Instrument.fromJson(Map<String, Object?> j) {
    final c = AssetClass.fromJson(_str(j, 'asset_class'));
    final id = _str(j, 'instrument_id');
    final symbol = _str(j, 'symbol_at_trade');
    final name = _str(j, 'name_at_trade');
    if (symbol.length > 200 || name.length > 200) {
      throw const FormatException('symbol_at_trade/name_at_trade too long');
    }
    final prefix = '${c.prefix}:';
    final code = id.startsWith(prefix) ? id.substring(prefix.length) : '';
    if (!_validSymbol(c, code)) {
      throw FormatException('Invalid instrument_id', id);
    }
    return Instrument._(c, id, symbol, name);
  }

  final AssetClass assetClass;
  final String id;
  final String symbolAtTrade;
  final String nameAtTrade;

  String get code => id.substring(id.indexOf(':') + 1);

  Map<String, Object?> toJson() => {
    'asset_class': assetClass.json,
    'instrument_id': id,
    'symbol_at_trade': symbolAtTrade,
    'name_at_trade': nameAtTrade,
  };

  @override
  bool operator ==(Object other) => other is Instrument && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

String _str(Map<String, Object?> j, String field) {
  final v = j[field];
  if (v is! String) throw FormatException('$field must be a string', v);
  return v;
}
