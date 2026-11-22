import 'package:antigravity_go/ui/auth/google_login_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('GoogleLoginSheet offers Google, Enterprise, and API Key tabs', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: GoogleLoginSheet(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Antigravity Account'), findsOneWidget);
    expect(find.text('Sign in with Google Account'), findsOneWidget);
    expect(find.text('Verify'), findsOneWidget);

    await tester.tap(find.text('Enterprise'));
    await tester.pump();
    expect(find.text('Google Cloud Project ID'), findsOneWidget);

    await tester.tap(find.text('API Key'));
    await tester.pump();
    expect(find.text('GEMINI_API_KEY'), findsOneWidget);
  });
}
