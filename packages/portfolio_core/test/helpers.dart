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
