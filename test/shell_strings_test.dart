import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The language setting: the persisted notifier, the string catalog's
/// English/Italian split, and the settings picker that writes through it.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appLocale.resetForTest();
  });

  group('AppLocaleNotifier', () {
    test('starts unset and persists a pick through load', () async {
      expect(appLocale.isSet, isFalse);
      expect(appLocale.value, isNull);
      expect(appLocale.locale, isNull);

      await appLocale.setLanguage(ShellLanguage.italiano);
      expect(appLocale.value, ShellLanguage.italiano);

      // A fresh notifier restores the persisted choice — the host loads it
      // before the first frame, exactly like the theme.
      final restored = AppLocaleNotifier();
      await restored.load();
      expect(restored.value, ShellLanguage.italiano);
      expect(restored.locale, const Locale('it'));
    });

    test('load with no persisted choice stays unset (English)', () async {
      await appLocale.load();
      expect(appLocale.isSet, isFalse);
    });

    test('an unknown persisted code falls back to unset, never a crash',
        () async {
      SharedPreferences.setMockInitialValues({'prefs.app.language': 'xx'});
      await appLocale.load();
      expect(appLocale.isSet, isFalse);
    });

    test('clear returns to unset and removes the persisted key', () async {
      await appLocale.setLanguage(ShellLanguage.italiano);
      await appLocale.clear();
      expect(appLocale.isSet, isFalse);

      final restored = AppLocaleNotifier();
      await restored.load();
      expect(restored.isSet, isFalse);
    });
  });

  group('ShellStrings', () {
    test('English keeps the historical shell strings byte-identical', () {
      const strings = ShellStrings();
      expect(strings.newGame, 'NEW GAME');
      expect(strings.continueDefault, 'CONTINUE');
      expect(strings.noSavedGames, 'NO SAVED GAMES');
      expect(strings.settingsTitle, 'SETTINGS');
      expect(strings.back, 'Back');
      expect(strings.continueLabel, 'Continue');
      expect(strings.stepHeader(2, 3, 'Options'), 'Step 2 of 3 — Options');
      expect(strings.welcome('Marcuz', 'PROBE'), 'Welcome, Marcuz, to PROBE');
      expect(strings.welcomeBack('Marcuz', 'PROBE'),
          'Welcome back, Marcuz — PROBE awaits');
    });

    test('Italian carries a full catalog with its own phrasing', () {
      final strings = ShellStrings.forLanguage(ShellLanguage.italiano);
      expect(strings.newGame, 'NUOVA PARTITA');
      expect(strings.continueDefault, 'CONTINUA');
      expect(strings.noSavedGames, 'NESSUNA PARTITA SALVATA');
      expect(strings.stepHeader(1, 3, 'Seats'), isNot(contains('Step')));
      expect(strings.welcome('Marco', 'PROBE'), contains('Marco'));
      expect(strings.welcomeBack('Marco', 'PROBE'), isNot(contains('awaits')));
    });

    test('unknown codes fall back to English', () {
      expect(
          ShellStrings.forLanguage(ShellLanguage.english).newGame, 'NEW GAME');
    });

    test('multiplayer strings: English stays byte-identical', () {
      const strings = ShellStrings();
      expect(strings.worldTitle('KZ9Q2'), 'World KZ9Q2');
      expect(strings.youName('Mara'), 'Mara (you)');
      expect(strings.clockStatus(42), 'clock 42');
      expect(
          strings.hostHandoverPending('Mara'), 'host handover to Mara pending');
      expect(strings.claimHost, 'Claim host');
      expect(strings.pendingHandovers, 'PENDING HOST HANDOVERS');
      expect(strings.deleteRoomTitle('KZ9Q2'), 'Delete world KZ9Q2?');
      expect(strings.deleteRoomBody('Mara, Marcuz'),
          contains('removed for every seat — Mara, Marcuz'));
      expect(strings.leaveRoomBodySeat('Mara', 'Marcuz'),
          contains('Your seat (Mara) is removed'));
    });

    test('multiplayer strings: Italian carries its own phrasing', () {
      final strings = ShellStrings.forLanguage(ShellLanguage.italiano);
      expect(strings.worldTitle('KZ9Q2'), 'Mondo KZ9Q2');
      expect(strings.youName('Mara'), 'Mara (tu)');
      expect(strings.hostHandoverPending('Mara'),
          'passaggio di consegne a Mara in attesa');
      expect(strings.pendingHandovers, isNot(contains('PENDING')));
      expect(strings.deleteRoomTitle('KZ9Q2'), contains('KZ9Q2'));
      expect(strings.deleteRoomBody('Mara, Marcuz'), contains('ogni posto'));
    });
  });

  group('settings language picker', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: SettingsScreen(gameId: 'probe'),
      ));
      await tester.pump();
      await tester.pump();
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('language-tile')),
        find.byKey(const ValueKey('settings-list')),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('tile shows the current language and opens the picker',
        (tester) async {
      await pumpSettings(tester);

      // Unset: the English caption with the shell's hint.
      expect(find.text('Language'), findsOneWidget);
      expect(find.text('English — more languages coming'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('language-tile')));
      await tester.pumpAndSettle();

      // Every supported language, each rendered in its own name.
      expect(find.byKey(const ValueKey('language-en')), findsOneWidget);
      expect(find.byKey(const ValueKey('language-it')), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('Italiano'), findsOneWidget);

      // Unset still shows a selection: the shell runs in English until a
      // choice exists, so the radio reflects that instead of blank.
      final group = tester.widget<RadioGroup<ShellLanguage>>(
          find.byType(RadioGroup<ShellLanguage>));
      expect(group.groupValue, ShellLanguage.english);
    });

    testWidgets('picking Italian persists and repaints the screen',
        (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.byKey(const ValueKey('language-tile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('language-it')));
      await tester.pumpAndSettle();

      // The notifier (and the dialog's title next time) is Italian…
      expect(appLocale.value, ShellLanguage.italiano);

      // …the screen re-rendered in Italian…
      expect(find.text('IMPOSTAZIONI'), findsOneWidget);
      expect(find.text('Lingua'), findsOneWidget);
      expect(find.text('Italiano'), findsOneWidget);
      expect(find.text('English'), findsNothing);

      // …and the choice survives a reload (the host's startup read).
      final restored = AppLocaleNotifier();
      await restored.load();
      expect(restored.value, ShellLanguage.italiano);
    });

    testWidgets('the English pick persists too, with the plain caption',
        (tester) async {
      await pumpSettings(tester);
      await tester.tap(find.byKey(const ValueKey('language-tile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('language-en')));
      await tester.pumpAndSettle();

      expect(appLocale.value, ShellLanguage.english);
      // Set now, so the caption drops the "more languages coming" hint.
      expect(find.text('English'), findsOneWidget);
      expect(find.text('English — more languages coming'), findsNothing);
    });

    testWidgets('cancelling the dialog changes nothing', (tester) async {
      await pumpSettings(tester);
      await tester.tap(find.byKey(const ValueKey('language-tile')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(appLocale.isSet, isFalse);
      expect(find.text('English — more languages coming'), findsOneWidget);
    });
  });
}
