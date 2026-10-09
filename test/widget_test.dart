import 'package:flutter_test/flutter_test.dart';
import 'package:ilk_uygulamam/main.dart';

void main() {
  testWidgets('Yalova Wonder Kids uygulaması başlatılabiliyor', (WidgetTester tester) async {
    await tester.pumpWidget(const YalovaWonderKidsApp());

    expect(find.byType(YalovaWonderKidsApp), findsOneWidget);
  });
}