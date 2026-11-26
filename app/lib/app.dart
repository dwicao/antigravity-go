import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/performance_state.dart';
import 'state/settings_state.dart';
import 'theme/app_theme.dart';
import 'ui/shell/home_shell.dart';

class _NoTransitionsBuilder extends PageTransitionsBuilder {
  const _NoTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      child;
}

class AntigravityGoApp extends ConsumerWidget {
  const AntigravityGoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeSettings = ref.watch(
      settingsProvider.select(
        (s) => (
          localeCode: s.localeCode,
          themeMode: s.themeMode,
          accent: s.accent,
          followWallpaperColor: s.followWallpaperColor,
          dynamicAccentArgb: s.dynamicAccentArgb,
        ),
      ),
    );
    final reduceMotion =
        ref.watch(performanceProvider.select((p) => p.reduceMotion));
    final dynamicSeed = themeSettings.followWallpaperColor &&
            themeSettings.dynamicAccentArgb != null
        ? Color(themeSettings.dynamicAccentArgb!)
        : null;
    final transitionsTheme = reduceMotion
        ? const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: _NoTransitionsBuilder(),
              TargetPlatform.linux: _NoTransitionsBuilder(),
            },
          )
        : null;

    ThemeData applyMotion(ThemeData base) => transitionsTheme == null
        ? base
        : base.copyWith(pageTransitionsTheme: transitionsTheme);

    return MaterialApp(
      title: 'Antigravity Go',
      debugShowCheckedModeBanner: false,
      locale: Locale(themeSettings.localeCode),
      themeMode: themeSettings.themeMode,
      theme: applyMotion(
        AgyTheme.build(
          brightness: Brightness.light,
          accent: themeSettings.accent,
          customSeed: dynamicSeed,
        ),
      ),
      darkTheme: applyMotion(
        AgyTheme.build(
          brightness: Brightness.dark,
          accent: themeSettings.accent,
          customSeed: dynamicSeed,
        ),
      ),
      supportedLocales: const [
        Locale('en'),
        Locale('id'),
        Locale('zh'),
        Locale('es'),
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
