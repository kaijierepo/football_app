import 'package:flutter_test/flutter_test.dart';

import 'package:football_flutter_app/main.dart';

void main() {
  testWidgets('App boots to the home shell', (WidgetTester tester) async {
    await tester.pumpWidget(const FootballApp());
    await tester.pump();
    expect(find.byType(HomeShell), findsOneWidget);
  });
}
