import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:portfolio_core/portfolio_core.dart';

import 'privacy.dart';

/// Green for gains, red for losses; unchanged in privacy mode, where colour
/// would reveal the sign of a hidden value.
TextStyle? gainStyle(BuildContext context, Decimal value, [TextStyle? base]) {
  // Same 2-decimal rounding as signedTry/signedPercent: a shown 0.00 is never coloured.
  if (PrivacyScope.maskedOf(context) ||
      roundHalfEven(value, 2) == Decimal.zero) {
    return base;
  }
  final dark = Theme.of(context).brightness == Brightness.dark;
  final color = value > Decimal.zero
      ? (dark ? const Color(0xFF6FCF97) : const Color(0xFF1B7F3B))
      : (dark ? const Color(0xFFFF8A80) : const Color(0xFFC62828));
  return (base ?? const TextStyle()).copyWith(color: color);
}
