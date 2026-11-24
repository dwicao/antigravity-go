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
    ).first;
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

  testWidgets('UsagePage renders % left and Reset countdown from real agy /usage tab output', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final future5h = DateTime.now().toUtc().add(const Duration(hours: 4, minutes: 30));
    final futureWeek = DateTime.now().toUtc().add(const Duration(days: 5, hours: 13));
    container.read(usageProvider.notifier).applyRawProbeOutput('''
Gemini Models\tWeekly Limit Remaining\t96%\t${futureWeek.toIso8601String()}
Gemini Models\tFive Hour Limit Remaining\t100%\t${future5h.toIso8601String()}
Claude and GPT models\tWeekly Limit Remaining\t100%\t${futureWeek.toIso8601String()}
Claude and GPT models\tFive Hour Limit Remaining\t100%\t${future5h.toIso8601String()}
Gemini 4 Argon\tGemini 4 Argon Weekly Limit\t100%\t${futureWeek.toIso8601String()}
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

    expect(find.text('96%'), findsOneWidget);
    expect(find.textContaining('left · 4% used'), findsWidgets);
    expect(find.textContaining('Reset in 5d 1'), findsWidgets);
    expect(find.textContaining('Reset in 4h '), findsWidgets);
  });

  testWidgets('UsagePage cleans glog noise and separates left vs used % cleanly', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final future5h = DateTime.now().toUtc().add(const Duration(hours: 4, minutes: 55));
    final futureWeek = DateTime.now().toUtc().add(const Duration(days: 6, hours: 23));
    container.read(usageProvider.notifier).applyRawProbeOutput('''
ERROR: logging before google.Init: I1124 03:36:05.798729       1 server_zerog.go:46] Initialized Android local timezone to Asia/Jakarta
Gemini Models\tWeekly Limit Remaining\t100%\t${futureWeek.toIso8601String()}
Gemini Models\tFive Hour Limit Remaining\t100%\t${future5h.toIso8601String()}
Remaining credits\t0
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

    expect(find.textContaining('0% used'), findsWidgets);
    expect(container.read(usageProvider).rawProbeOutput,
        isNot(contains('ERROR: logging before google.Init')));
  });

  testWidgets('UsagePage renders merged Gemini Models, Claude & GPT pools, and Upgrade button', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final future5h = DateTime.now().toUtc().add(const Duration(hours: 2));
    final futureWeek = DateTime.now().toUtc().add(const Duration(days: 6));
    container.read(usageProvider.notifier).applyRawProbeOutput('''
gemini-4-neon-high\tGemini 4 Neon (High)
gemini-pro-orchestrator\tOrchestrator (Carbon)
claude-opus-5-5-medium\tClaude Opus 5.5 (Medium)
Gemini Models\tWeekly Limit Remaining\t73%\t${futureWeek.toIso8601String()}
Gemini Models\tFive Hour Limit Remaining\t27%\t${future5h.toIso8601String()}
Claude and GPT models\tWeekly Limit Remaining\t100%\t${futureWeek.toIso8601String()}
Claude and GPT models\tFive Hour Limit Remaining\t100%\t${future5h.toIso8601String()}
Remaining credits\t0
Upgrade\thttps://antigravity.google/g1-upgrade
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

    expect(find.text('Gemini Models'), findsOneWidget);
    expect(find.text('Claude and GPT models'), findsOneWidget);
    expect(find.text('27%'), findsOneWidget);
    expect(find.text('73%'), findsOneWidget);

    final listScrollable = find.descendant(
      of: find.byType(ListView),
      matching: find.byType(Scrollable),
    ).first;
    await tester.scrollUntilVisible(
      find.text('Upgrade'),
      200,
      scrollable: listScrollable,
    );
    expect(find.text('Upgrade'), findsOneWidget);
    expect(find.text('0 credits'), findsOneWidget);
  });
}
