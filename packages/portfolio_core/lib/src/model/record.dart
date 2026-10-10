import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../strict_json.dart';
import 'transaction.dart';

const maxRecordBytes = 65536;
const _maxNameLength = 200;
final _uuidRe = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final _createdRe = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$');

bool isUuid(String s) => _uuidRe.hasMatch(s);

/// [message] is short and safe to show; it never contains file content.
class RecordFormatException implements Exception {
  RecordFormatException(this.code, this.message);

  /// too_large, bad_json, unsupported_version, wrong_portfolio, invalid_field
  final String code;
  final String message;

  @override
  String toString() => 'RecordFormatException($code): $message';
}

enum RecordOp {
  upsert('UPSERT'),
  voided('VOID');

  const RecordOp(this.json);
  final String json;
}

class LedgerRecord {
  LedgerRecord._({
    required this.schemaVersion,
    required this.portfolioId,
    required this.recordId,
    required this.transactionId,
    required this.supersedes,
    required this.operation,
    required this.createdAt,
    required this.deviceId,
    this.transaction,
  });

  factory LedgerRecord.newUpsert({
    required String portfolioId,
    required String deviceId,
    required Transaction transaction,
    String? transactionId,
    List<String> supersedes = const [],
    required DateTime now,
  }) => LedgerRecord._(
    schemaVersion: 1,
    portfolioId: portfolioId,
    recordId: const Uuid().v4(),
    transactionId: transactionId ?? const Uuid().v4(),
    supersedes: List.unmodifiable(supersedes),
    operation: RecordOp.upsert,
    createdAt: _toSecond(now),
    deviceId: deviceId,
    transaction: transaction,
  );

  factory LedgerRecord.newVoid({
    required String portfolioId,
    required String deviceId,
    required String transactionId,
    List<String> supersedes = const [],
    required DateTime now,
  }) => LedgerRecord._(
    schemaVersion: 1,
    portfolioId: portfolioId,
    recordId: const Uuid().v4(),
    transactionId: transactionId,
    supersedes: List.unmodifiable(supersedes),
    operation: RecordOp.voided,
    createdAt: _toSecond(now),
    deviceId: deviceId,
  );

  final int schemaVersion;
  final String portfolioId, recordId, transactionId, deviceId;
  final List<String> supersedes;
  final RecordOp operation;
  final DateTime createdAt;
  final Transaction? transaction;

  String get fileName => '$recordId.json';

  Map<String, Object?> _toJson() => {
    'schema_version': schemaVersion,
    'portfolio_id': portfolioId,
    'record_id': recordId,
    'transaction_id': transactionId,
    'supersedes': supersedes,
    'operation': operation.json,
    'created_at': _isoSecond(createdAt),
    'device_id': deviceId,
    'transaction': transaction?.toJson(),
  };

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(const JsonEncoder.withIndent('  ').convert(_toJson())),
  );

  /// Both sides are canonical (fixed key order), so comparing the encoded
  /// form is deep equality of the parsed content.
  bool sameContentAs(LedgerRecord other) =>
      jsonEncode(_toJson()) == jsonEncode(other._toJson());

  static LedgerRecord decode(Uint8List bytes, {required String portfolioId}) {
    final j = _parseObject(bytes);
    // Version first, so a newer file is "unsupported", not "invalid".
    if (j['schema_version'] != 1) {
      throw RecordFormatException(
        'unsupported_version',
        'unsupported schema_version',
      );
    }
    return _guard(() {
      if (_str(j, 'portfolio_id') != portfolioId) {
        throw RecordFormatException(
          'wrong_portfolio',
          'record belongs to another portfolio',
        );
      }
      final id = _uuid(j, 'record_id');
      final txId = _uuid(j, 'transaction_id');
      final device = _uuid(j, 'device_id');
      final sup = j['supersedes'];
      if (sup is! List) {
        throw const FormatException('supersedes must be a list');
      }
      final supersedes = <String>[
        for (final s in sup)
          if (s is String && isUuid(s))
            s
          else
            throw const FormatException('supersedes entries must be UUIDs'),
      ];
      final op = RecordOp.values.firstWhere(
        (o) => o.json == j['operation'],
        orElse: () => throw const FormatException('unknown operation'),
      );
      final created = _str(j, 'created_at');
      final createdAt = _createdRe.hasMatch(created)
          ? DateTime.tryParse(created)
          : null;
      if (createdAt == null || _isoSecond(createdAt) != created) {
        throw const FormatException('created_at must be ISO UTC with Z');
      }
      final tx = j['transaction'];
      Transaction? transaction;
      if (op == RecordOp.upsert) {
        if (tx is! Map<String, Object?>) {
          throw const FormatException('UPSERT requires a transaction');
        }
        transaction = Transaction.fromJson(tx);
      } else if (tx != null) {
        throw const FormatException('VOID must not carry a transaction');
      }
      return LedgerRecord._(
        schemaVersion: 1,
        portfolioId: portfolioId,
        recordId: id,
        transactionId: txId,
        supersedes: List.unmodifiable(supersedes),
        operation: op,
        createdAt: createdAt,
        deviceId: device,
        transaction: transaction,
      );
    });
  }
}

class PortfolioDescriptor {
  PortfolioDescriptor._(this.portfolioId, this.name);

  factory PortfolioDescriptor.create(String name) {
    try {
      return PortfolioDescriptor._(const Uuid().v4(), _checkName(name));
    } on FormatException catch (e) {
      throw ArgumentError.value(name, 'name', e.message);
    }
  }

  final String portfolioId;
  final String name;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      const JsonEncoder.withIndent('  ').convert({
        'schema_version': 1,
        'portfolio_id': portfolioId,
        'name': name,
        'currency': 'TRY',
        'reporting_timezone': 'Europe/Istanbul',
      }),
    ),
  );

  static PortfolioDescriptor decode(Uint8List bytes) {
    final j = _parseObject(bytes);
    if (j['schema_version'] != 1) {
      throw RecordFormatException(
        'unsupported_version',
        'unsupported schema_version',
      );
    }
    return _guard(() {
      if (j['currency'] != 'TRY') {
        throw const FormatException('currency must be TRY');
      }
      if (j['reporting_timezone'] != 'Europe/Istanbul') {
        throw const FormatException(
          'reporting_timezone must be Europe/Istanbul',
        );
      }
      return PortfolioDescriptor._(
        _uuid(j, 'portfolio_id'),
        _checkName(_str(j, 'name')),
      );
    });
  }
}

String _checkName(String name) {
  final n = name.trim();
  if (n.isEmpty || n.length > _maxNameLength) {
    throw const FormatException('name must be 1-200 characters');
  }
  return n;
}

DateTime _toSecond(DateTime t) {
  final u = t.toUtc();
  return DateTime.utc(u.year, u.month, u.day, u.hour, u.minute, u.second);
}

String _isoSecond(DateTime t) =>
    '${_toSecond(t).toIso8601String().split('.').first}Z';

Map<String, Object?> _parseObject(Uint8List bytes) {
  if (bytes.length > maxRecordBytes) {
    throw RecordFormatException('too_large', 'file is larger than 64 KiB');
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf) {
    throw RecordFormatException(
      'bad_json',
      'file starts with a byte-order mark',
    );
  }
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    throw RecordFormatException('bad_json', 'file is not valid UTF-8');
  }
  try {
    final v = decodeStrictJson(text);
    if (v is Map<String, Object?>) return v;
    throw RecordFormatException('bad_json', 'top level must be an object');
  } on FormatException catch (e) {
    // Only message and offset: e.source is the whole untrusted file.
    final at = e.offset == null ? '' : ' at offset ${e.offset}';
    throw RecordFormatException('bad_json', '${_short(e.message)}$at');
  }
}

/// Maps FormatException from field parsing to invalid_field (ruling R1).
T _guard<T>(T Function() f) {
  try {
    return f();
  } on FormatException catch (e) {
    throw RecordFormatException('invalid_field', _short(e.message));
  }
}

String _short(String m) => m.length > 200 ? '${m.substring(0, 200)}...' : m;

String _str(Map<String, Object?> j, String k) {
  final v = j[k];
  if (v is! String) throw FormatException('$k must be a string');
  return v;
}

String _uuid(Map<String, Object?> j, String k) {
  final v = _str(j, k);
  if (!isUuid(v)) throw FormatException('$k must be a lowercase UUID');
  return v;
}
