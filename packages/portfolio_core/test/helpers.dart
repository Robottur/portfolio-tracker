import 'dart:convert';
import 'dart:typed_data';

import 'package:decimal/decimal.dart';
import 'package:portfolio_core/portfolio_core.dart';

Instrument aaa() => Instrument.create(AssetClass.bistShare, 'AAA');

Transaction buy({
  required DateTime on,
  String qty = '1',
  String price = '1',
  String fees = '0',
  int dayOrder = 1,
  Instrument? instrument,
}) => Transaction.buy(
  instrument: instrument ?? aaa(),
  date: on,
  dayOrder: dayOrder,
  quantity: Decimal.parse(qty),
  unitPrice: Decimal.parse(price),
  fees: Decimal.parse(fees),
);

Transaction sell({
  required DateTime on,
  String qty = '1',
  String price = '1',
  String fees = '0',
  int dayOrder = 1,
  Instrument? instrument,
}) => Transaction.sell(
  instrument: instrument ?? aaa(),
  date: on,
  dayOrder: dayOrder,
  quantity: Decimal.parse(qty),
  unitPrice: Decimal.parse(price),
  fees: Decimal.parse(fees),
);

Transaction dividend({
  required DateTime on,
  String gross = '100',
  String withholding = '0',
  String fees = '0',
  int dayOrder = 1,
  Instrument? instrument,
}) => Transaction.dividend(
  instrument: instrument ?? aaa(),
  date: on,
  dayOrder: dayOrder,
  grossAmount: Decimal.parse(gross),
  withholding: Decimal.parse(withholding),
  fees: Decimal.parse(fees),
);

Transaction split({
  required DateTime on,
  int numerator = 2,
  int denominator = 1,
  int dayOrder = 1,
  Instrument? instrument,
}) => Transaction.split(
  instrument: instrument ?? aaa(),
  date: on,
  dayOrder: dayOrder,
  numerator: numerator,
  denominator: denominator,
);

const testPortfolioId = '11111111-1111-4111-8111-111111111111';
const testDeviceId = '22222222-2222-4222-8222-222222222222';
final testNow = DateTime.utc(2026, 10, 10, 12);

extension TransactionTestCopy on Transaction {
  /// Buy/sell only.
  Transaction copyWithPrice(String price) =>
      (type == TxType.buy ? Transaction.buy : Transaction.sell)(
        instrument: instrument,
        date: effectiveDate,
        dayOrder: dayOrder,
        quantity: quantity!,
        unitPrice: Decimal.parse(price),
        fees: fees!,
      );
}

LedgerRecord upsert({
  required Transaction tx,
  String? transactionId,
  List<String> supersedes = const [],
}) => LedgerRecord.newUpsert(
  portfolioId: testPortfolioId,
  deviceId: testDeviceId,
  transaction: tx,
  transactionId: transactionId,
  supersedes: supersedes,
  now: testNow,
);

LedgerRecord revise(LedgerRecord prev, Transaction tx) => upsert(
  tx: tx,
  transactionId: prev.transactionId,
  supersedes: [prev.recordId],
);

LedgerRecord voidOf(LedgerRecord prev) => LedgerRecord.newVoid(
  portfolioId: testPortfolioId,
  deviceId: testDeviceId,
  transactionId: prev.transactionId,
  supersedes: [prev.recordId],
  now: testNow,
);

Uint8List descriptorBytes([String portfolioId = testPortfolioId]) =>
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'schema_version': 1,
          'portfolio_id': portfolioId,
          'name': 'Test',
          'currency': 'TRY',
          'reporting_timezone': 'Europe/Istanbul',
        }),
      ),
    );

PriceObservation obs(
  String id,
  String price,
  DateTime session, {
  PriceKind kind = PriceKind.close,
  DateTime? quoteTime,
  DateTime? receivedAt,
}) => PriceObservation(
  instrumentId: id,
  price: Decimal.parse(price),
  sessionDate: session,
  quoteTime: quoteTime,
  receivedAt: receivedAt ?? testNow,
  source: 'test',
  kind: kind,
);
