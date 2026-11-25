import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Smoke coverage for the shell package: the settings screen renders its
/// shared sections, hosts can append their own, OAuth buttons track the
/// provider registry, and the top bar opens the configured settings builder
/// while its theme toggle flips the app-wide notifier.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    account.resetForTest();
    appTheme.resetForTest();
  });

  testWidgets('settings screen shows shared sections and app extras',
      (tester) async {
    // The settings list is taller than the default 800x600 surface.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: SettingsScreen(
        gameId: 'probe',
        extraSections: const [
          Card(key: ValueKey('game-section'), child: SizedBox())
        ],
      ),
    ));
    await tester.pump();

    expect(find.byKey(const ValueKey('email-field')), findsOneWidget);
    // The lower cards (the contrast switch among them) sit below the fold in
    // the default 800×600 test surface; scroll them into view before asserting.
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('player-name-field')),
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-name-field')), findsOneWidget);
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('contrast-tile')),
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('contrast-tile')), findsOneWidget);
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('language-tile')),
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('language-tile')), findsOneWidget);
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('game-section')),
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('game-section')), findsOneWidget);
  });

  testWidgets(
      'oauth buttons enable only for registered providers and run their handler',
      (tester) async {
    var googleRuns = 0;
    // The settings list is taller than the default 800x600 surface.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home:
          SettingsScreen(oauthProviders: {'google': () async => googleRuns++}),
    ));
    await tester.pump();

    final google = tester
        .widget<OutlinedButton>(find.byKey(const ValueKey('oauth-google')));
    final github = tester
        .widget<OutlinedButton>(find.byKey(const ValueKey('oauth-github')));
    expect(google.onPressed, isNotNull);
    expect(github.onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('oauth-google')));
    await tester.pump();
    expect(googleRuns, 1);
  });

  testWidgets(
      'server onboarding appears while unconfigured and clears after the dialog',
      (tester) async {
    var configured = false;
    // The settings list is taller than the default 800x600 surface.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: SettingsScreen(
        serverSetup: ServerConnectionSetup(
          isConfigured: () async => configured,
          showConnectionDialog: (context) async {
            configured = true;
            return true;
          },
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('connect-server')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('connect-server')));
    await tester.pump();
    expect(find.byKey(const ValueKey('connect-server')), findsNothing);
  });

  testWidgets('top bar opens the host settings builder and toggles the theme',
      (tester) async {
    ThemeMode? openedWith;
    // The settings list is taller than the default 800x600 surface.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: ShellTopBar(
          settingsBuilder: () => SettingsScreen(
            gameId: 'probe',
            extraSections: const [
              Card(key: ValueKey('host-section'), child: SizedBox())
            ],
          ),
        ),
      ),
    ));
    await tester.pump();

    // The toggle cycles the shared notifier through all three modes
    // (light → dark → system → light), and its icon shows the NEXT step.
    // The fresh state is dark, so the top bar offers the system step first.
    expect(find.byIcon(Icons.brightness_auto_outlined), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('theme-toggle')));
    await tester.pumpAndSettle();
    expect(appTheme.mode, ThemeMode.system);

    await tester.tap(find.byKey(const ValueKey('theme-toggle')));
    await tester.pumpAndSettle();
    expect(appTheme.mode, ThemeMode.light);

    // The gear opens the host's settings screen.
    await tester.tap(find.byKey(const ValueKey('settings-button')));
    await tester.pumpAndSettle();
    openedWith = appTheme.mode;
    expect(openedWith, ThemeMode.light);
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('host-section')),
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('host-section')), findsOneWidget);

    // The settings screen carries the same toggle, and it followed along:
    // in light mode it offers the dark step. The top bar that opened this
    // route is offstage now, so this is the settings instance. (The
    // avatar picker made the list taller: scroll back up to the toggle.)
    await tester.dragUntilVisible(
      find.byIcon(Icons.dark_mode_outlined),
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, 200),
    );
    expect(find.byIcon(Icons.dark_mode_outlined), findsOneWidget);

    appTheme.mode = ThemeMode.dark; // don't leak into the next test
  });

  test('account controller resolves a connection through the injected resolver',
      () async {
    account.serverConnection = () async =>
        const ServerConnection(url: 'https://shell.test', apiKey: 'k');
    account.authService = AuthService(
      serverUrl: 'https://shell.test',
      apiKey: 'k',
      client: MockClient((request) async => http.Response(
          '{"access_token":"a","refresh_token":"r","expires_in":3600,"user":{"id":"u1","email":"p@shell.test"}}',
          200)),
    );
    await account.signInWithPassword('p@shell.test', 'secret1');
    expect(account.isCloudSignedIn, isTrue);
    expect(account.value?.email, 'p@shell.test');
  });
}
