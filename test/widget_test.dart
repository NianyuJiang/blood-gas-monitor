// Basic smoke test for BloodGas.
import 'package:flutter_test/flutter_test.dart';

import 'package:blood_gas_monitor/main.dart';

void main() {
  testWidgets('App boots to home', (WidgetTester tester) async {
    await tester.pumpWidget(const GasMonitorApp());
    await tester.pump();
    expect(find.text('GAS MONITOR'), findsWidgets);
  });
}
