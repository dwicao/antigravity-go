import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/settings_state.dart';
import 'theme/app_theme.dart';
import 'ui/shell/home_shell.dart';

class AntigravityGoApp extends ConsumerWidget {
  const AntigravityGoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return MaterialApp(
      title: 'Antigravity Go',
      debugShowCheckedModeBanner: false,
      themeMode: settings.themeMode,
      theme: AgyTheme.build(
        brightness: Brightness.light,
        accent: settings.accent,
      ),
      darkTheme: AgyTheme.build(
        brightness: Brightness.dark,
        accent: settings.accent,
      ),
      supportedLocales: const [
        Locale('en'),
        Locale('zh'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const HomeShell(),
    );
  }
}
