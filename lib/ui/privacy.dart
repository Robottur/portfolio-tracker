import 'package:flutter/material.dart';

class PrivacyScope extends InheritedWidget {
  const PrivacyScope({super.key, required this.masked, required super.child});

  final bool masked;

  static bool maskedOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PrivacyScope>()?.masked ??
      true; // fail closed

  @override
  bool updateShouldNotify(PrivacyScope old) => masked != old.masked;
}

/// Every amount, quantity and percentage is shown through this widget.
class Amount extends StatelessWidget {
  const Amount(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) =>
      Text(PrivacyScope.maskedOf(context) ? '•••••' : text, style: style);
}
