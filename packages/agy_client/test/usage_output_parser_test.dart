import 'package:agy_client/agy_client.dart';
import 'package:test/test.dart';

void main() {
  group('UsageOutputParser', () {
    test('extracts OAuth URL and email from ANSI output', () {
      const sample =
          '\x1B[36mOpen this URL to sign in:\x1B[0m https://accounts.google.com/o/oauth2/v2/auth?client_id=123&scope=openid\nSigned in as developer@gmail.com\n';
      expect(
        UsageOutputParser.extractOAuthUrl(sample),
        'https://accounts.google.com/o/oauth2/v2/auth?client_id=123&scope=openid',
      );
      expect(UsageOutputParser.extractEmail(sample), 'developer@gmail.com');
    });

    test('parses 5h, weekly, Gemini Argon/Pro/Flash, Claude & GPT quotas and AI credits', () {
      const usageDump = '''
Models & Quota
5-hour window: 82% remaining (resets in 3h 14m)
Weekly limit: 64% remaining (resets in 4d 11h)
Gemini 4 Argon        75% remaining (resets in 2h 45m)
Gemini Pro (Neon / Carbon)  80% remaining
Gemini Flash & Hydrogen     95% remaining
Claude & GPT                55% remaining (weekly resets in 5d)
AI Credits balance: 420
''';
      final parsed = UsageOutputParser.parseUsageText(usageDump);
      expect(parsed.overallFiveHourRemainingPct, 82);
      expect(parsed.overallWeeklyRemainingPct, 64);
      expect(parsed.overallFiveHourResetText, '3h 14m');
      expect(parsed.aiCreditsRemaining, 420);

      final argon = parsed.entries.firstWhere((e) => e.id == 'gemini-4-argon');
      expect(argon.fiveHourRemainingPct, 75);

      final claudeGpt = parsed.entries.firstWhere((e) => e.id == 'claude-gpt');
      expect(claudeGpt.weeklyRemainingPct, 55);
    });

    test('parses two-column table percentages and agy models list', () {
      const tableAndModels = '''
gemini-4-neon-high     Gemini 4 Neon (High)
gemini-4-argon-high    Gemini 4 Argon (High)
claude-opus-5.5-thinking  Claude Opus 5.5
Gemini 4 Argon            70%      85%    resets in 2h
Claude & GPT              40%      60%
''';
      expect(
        UsageOutputParser.outputIndicatesAuthenticated(tableAndModels),
        isTrue,
      );
      final parsed = UsageOutputParser.parseUsageText(tableAndModels);
      expect(parsed.discoveredModels, hasLength(3));
      final argon = parsed.entries.firstWhere((e) => e.id == 'gemini-4-argon');
      expect(argon.fiveHourRemainingPct, 70);
      expect(argon.weeklyRemainingPct, 85);
      final claude = parsed.entries.firstWhere((e) => e.id == 'claude-gpt');
      expect(claude.fiveHourRemainingPct, 40);
      expect(claude.weeklyRemainingPct, 60);
    });

    test('parses tab-separated agy /usage lines with ISO-8601 reset timestamps', () {
      const realOutput = '''
ERROR: logging before google.Init: I1123 07:42:17.421015       1 server_zerog.go:46] Initialized Android local timezone to Asia/Jakarta
Gemini Models\tWeekly Limit Remaining\t96%\t2026-11-29T14:30:20Z
Gemini Models\tFive Hour Limit Remaining\t100%\t2026-11-23T05:30:20Z
Claude and GPT models\tWeekly Limit Remaining\t100%\t2026-11-30T00:42:20Z
Claude and GPT models\tFive Hour Limit Remaining\t100%\t2026-11-23T05:42:20Z
Gemini 4 Argon\tGemini 4 Argon Weekly Limit\t100%\t2026-11-30T00:42:20Z
''';
      final now = DateTime.utc(2026, 11, 23, 0, 42, 20);
      final parsed = UsageOutputParser.parseUsageText(realOutput, now: now);

      expect(UsageOutputParser.outputIndicatesAuthenticated(realOutput), isTrue);
      expect(parsed.overallFiveHourRemainingPct, 100);
      expect(parsed.overallWeeklyRemainingPct, 96);
      expect(parsed.overallFiveHourResetText, '4h 48m');
      expect(parsed.overallWeeklyResetText, '6d 13h');

      final pro = parsed.entries.firstWhere((e) => e.id == 'gemini-pro');
      expect(pro.fiveHourRemainingPct, 100);
      expect(pro.weeklyRemainingPct, 96);
      expect(pro.fiveHourResetText, '4h 48m');
      expect(pro.weeklyResetText, '6d 13h');

      final flash = parsed.entries.firstWhere((e) => e.id == 'gemini-flash');
      expect(flash.weeklyRemainingPct, 96);

      final claude = parsed.entries.firstWhere((e) => e.id == 'claude-gpt');
      expect(claude.fiveHourRemainingPct, 100);
      expect(claude.weeklyRemainingPct, 100);
      expect(claude.fiveHourResetText, '5h');
      expect(claude.weeklyResetText, '7d');

      final argon = parsed.entries.firstWhere((e) => e.id == 'gemini-4-argon');
      expect(argon.weeklyRemainingPct, 100);
      expect(argon.weeklyResetText, '7d');
    });
  });
}
