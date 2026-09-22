import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The ShellApp wrapper: the persisted theme, locale and account preloads
/// wired into one MaterialApp, with passthrough overrides for hosts that
/// need them. The harness records what the resolved MaterialApp actually
/// applied to a descendant.
void main() {
  Brightness? capturedBrightness;
  Locale? capturedLocale;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    account.resetForTest();
    appTheme.resetForTest();
    appLocale.resetForTest();
    capturedBrightness = null;
    capturedLocale = null;
  });

  Widget harness({ThemeMode? themeMode, Locale? locale}) => ShellApp(
        title: 'Probe',
        seedColor: const Color(0xff7a5c2e),
        themeMode: themeMode,
        locale: locale,
        home: Builder(builder: (context) {
          capturedBrightness = Theme.of(context).brightness;
          capturedLocale = Localizations.localeOf(context);
          return const Scaffold(body: SizedBox.expand());
        }),
      );

  testWidgets('defaults: dark seeded theme, unset locale, preloads ran',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(capturedBrightness, Brightness.dark,
        reason: 'appTheme defaults to dark');
    expect(capturedLocale, const Locale('en'),
        reason: 'no language picked: MaterialApp resolves the platform default '
            '(en in the test harness) over the shell\'s supported locales');
    expect(account.isLoaded, isTrue, reason: 'the shell preloads the account');
  });

  testWidgets('persisted choices restore before the frame matters',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'prefs.app.themeMode': 'light',
      'prefs.app.language': 'it',
      'prefs.account.playerName': 'Marcuz',
    });
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(capturedBrightness, Brightness.light);
    expect(capturedLocale, const Locale('it'));
    expect(account.playerName, 'Marcuz');
  });

  testWidgets('the top-bar toggle repaints the whole app', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(capturedBrightness, Brightness.dark);

    appTheme.mode = ThemeMode.light;
    await tester.pumpAndSettle();
    expect(capturedBrightness, Brightness.light);

    appTheme.mode = ThemeMode.dark; // don't leak into other tests
  });

  testWidgets('explicit overrides win over the persisted values',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'prefs.app.themeMode': 'dark',
      'prefs.app.language': 'en',
    });
    await tester.pumpWidget(
        harness(themeMode: ThemeMode.light, locale: const Locale('it')));
    await tester.pumpAndSettle();

    expect(capturedBrightness, Brightness.light);
    expect(capturedLocale, const Locale('it'),
        reason: 'the override wins; note MaterialApp resolution falls back '
            'when an override is not in supportedLocales');
  });
}
