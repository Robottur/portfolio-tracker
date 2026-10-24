import 'package:portfolio_tracker/ui/privacy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('masked scope hides the text', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: PrivacyScope(masked: true, child: Amount('2,700.00')),
      ),
    );
    expect(find.text('•••••'), findsOneWidget);
    expect(find.text('2,700.00'), findsNothing);
  });

  testWidgets('unmasked scope shows the text', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: PrivacyScope(masked: false, child: Amount('2,700.00')),
      ),
    );
    expect(find.text('2,700.00'), findsOneWidget);
  });
}
