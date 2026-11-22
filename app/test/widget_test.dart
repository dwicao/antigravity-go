import 'package:antigravity_go/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('AntigravityGoApp renders HomeShell and onboarding banner', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: AntigravityGoApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Antigravity Go'), findsOneWidget);
    expect(find.text('Antigravity in your pocket'), findsOneWidget);
  });
}
