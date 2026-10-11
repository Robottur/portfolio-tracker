import 'package:portfolio_core/portfolio_core.dart';

String assetClassLabel(AssetClass c) => switch (c) {
  AssetClass.bistShare => 'BIST share',
  AssetClass.fx => 'Currency',
  AssetClass.crypto => 'Crypto',
  AssetClass.gold => 'Gold',
  AssetClass.fund => 'Fund',
};

/// Dashboard group heading.
String assetClassHeading(AssetClass c) =>
    c == AssetClass.fund ? 'Funds' : assetClassLabel(c);
