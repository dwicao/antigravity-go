import 'package:antigravity_go/state/usage_state.dart';
import 'package:antigravity_go/ui/usage/usage_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('UsagePage displays 5-hour, weekly, Gemini Argon, Neon/Carbon, Hydrogen/Flash, and Claude & GPT limits', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(usageProvider.notifier).applyRawProbeOutput('''
5-hour window: 88% remaining (resets in 4h 10m)
Weekly limit: 71% remaining (resets in 5d 2h)
Gemini 4 Argon 90% remaining
Gemini Pro (Neon / Carbon) 84% remaining
Gemini Flash & Hydrogen 96% remaining
Claude & GPT 62% remaining (weekly resets in 4d)
AI Credits balance: 250
''');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: UsagePage(autoRefreshOnOpen: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Usage Limits & Quotas'), findsOneWidget);
    expect(find.text('5-Hour Rolling Window'), findsOneWidget);
    expect(find.text('Weekly Limit'), findsOneWidget);
    expect(find.text('Gemini 4 Argon'), findsOneWidget);
    expect(find.text('Gemini 4 Neon & Carbon'), findsOneWidget);

    final listScrollable = find.descendant(
      of: find.byType(ListView),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('Gemini 4 Hydrogen & 3.8 Flash'),
      200,
      scrollable: listScrollable,
    );
    expect(find.text('Gemini 4 Hydrogen & 3.8 Flash'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Claude & GPT'),
      200,
      scrollable: listScrollable,
    );
    expect(find.text('Claude & GPT'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('250 credits'),
      200,
      scrollable: listScrollable,
    );
    expect(find.text('250 credits'), findsOneWidget);
  });
}
