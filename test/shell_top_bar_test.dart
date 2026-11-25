import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSync extends ShellSyncController {
  _FakeSync(super.state);
  int syncs = 0;

  @override
  Future<void> syncNow() async => syncs++;
}

Future<void> _pump(WidgetTester tester, PreferredSizeWidget bar,
    {double width = 360}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(appBar: bar, body: const Text('body')),
  ));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    account.resetForTest();
    appTheme.resetForTest();
    appLocale.resetForTest();
  });

  group('ShellAvatar', () {
    test('tokens round-trip and unknown tokens read as null', () {
      for (final avatar in [
        ShellAvatar.initials,
        ShellAvatar.provider,
        ShellAvatar.preset(ShellAvatarPreset.all.first),
      ]) {
        expect(ShellAvatar.tryParse(avatar.token), avatar);
      }
      expect(ShellAvatar.tryParse('preset:nope'), isNull);
      expect(ShellAvatar.tryParse('garbage'), isNull);
    });

    test('resolve prefers the photo when unset, falls back without one', () {
      expect(ShellAvatar.resolve(null, photoUrl: 'https://x/p.png'),
          ShellAvatar.provider);
      expect(ShellAvatar.resolve(null), ShellAvatar.initials);
      expect(ShellAvatar.resolve(ShellAvatar.provider), ShellAvatar.initials);
    });

    test('initials from names and emails', () {
      expect(shellInitials('Marco Sartori'), 'MS');
      expect(shellInitials('marcuz'), 'M');
      expect(shellInitials('marco.sartori@example.com'), 'M');
      expect(shellInitials(''), '');
    });

    test('provider photo and name come from the metadata', () {
      final metadata = {
        'avatar_url': 'https://lh3.example/photo',
        'full_name': 'Marco Sartori',
      };
      expect(
          providerPhotoUrlFromMetadata(metadata), 'https://lh3.example/photo');
      expect(providerDisplayNameFromMetadata(metadata), 'Marco Sartori');
      expect(
          providerPhotoUrlFromMetadata({'picture': 'http://insecure'}), isNull);
    });
  });

  group('avatar sync', () {
    test('reconcile pushes a local avatar the cloud never saw', () {
      final result = shellPreferencesReconcile(
        cloudPreferences: const {},
        localTheme: null,
        localLocale: null,
        localPlayerName: null,
        localAvatar: 'preset:fox',
        localStamps: const {'avatar': 10},
      );
      expect(result.push[ShellPrefKey.avatar], 'preset:fox');
    });

    test('sign-in pulls the cloud avatar and exposes the Google photo',
        () async {
      account.serverConnection = () async =>
          const ServerConnection(url: 'https://shell.test', apiKey: 'k');
      final metadata = {
        'avatar_url': 'https://lh3.example/photo',
        'full_name': 'Marco Sartori',
        'kommons': {
          'avatar': 'preset:rocket',
          'updatedAt': {'avatar': 1900000000},
        },
      };
      account.authService = AuthService(
        serverUrl: 'https://shell.test',
        apiKey: 'k',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/v1/signup')) {
            return http.Response(
                jsonEncode({
                  'error_code': 'user_already_registered',
                  'msg': 'User already registered',
                }),
                422);
          }
          if (request.url.path.endsWith('/auth/v1/token')) {
            return http.Response(
                jsonEncode({
                  'access_token': 'at',
                  'refresh_token': 'rt',
                  'expires_at': 1900000000,
                  'user': {
                    'id': 'u1',
                    'email': 'marco@shell.test',
                    'user_metadata': metadata,
                  },
                }),
                200);
          }
          if (request.url.path.endsWith('/auth/v1/user')) {
            if (request.method == 'PUT') return http.Response('{}', 200);
            return http.Response(
                jsonEncode({
                  'id': 'u1',
                  'email': 'marco@shell.test',
                  'user_metadata': metadata,
                }),
                200);
          }
          return http.Response('unexpected', 404);
        }),
      );

      await account.signInWithPassword('marco@shell.test', 'whatever-1');
      await account.debugFlushPendingPreferencePushes();

      expect(account.avatar, ShellAvatar.tryParse('preset:rocket'));
      expect(account.providerPhotoUrl, 'https://lh3.example/photo');
      expect(account.providerDisplayName, 'Marco Sartori');

      final identity = ShellAccountIdentity();
      addTearDown(identity.dispose);
      expect(identity.value.name, 'Marco Sartori');
      expect(identity.value.kinds, {ShellSignInKind.email});
    });
  });

  group('ShellTopBar', () {
    testWidgets('narrow: two rows, guest identity, no optional slots',
        (tester) async {
      await _pump(tester, const ShellTopBar());
      await tester.pump();

      expect(
          find.byKey(const ValueKey('shell-top-bar-narrow')), findsOneWidget);
      expect(find.text('Guest'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('shell-kind-anonymous')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-info')), findsOneWidget);
      expect(find.byKey(const ValueKey('theme-toggle')), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-sync')), findsNothing);
      expect(find.byKey(const ValueKey('shell-notifications')), findsNothing);
      expect(find.byKey(const ValueKey('shell-plan-free')), findsNothing);
      // No version and no sign-in/out button in the bar itself.
      expect(find.byKey(const ValueKey('app-version-chip')), findsNothing);
    });

    testWidgets('signed in: name, then email; one icon per sign-in method',
        (tester) async {
      final identity = ValueNotifier(const ShellIdentity(
        email: 'marco@example.com',
        kinds: {ShellSignInKind.email, ShellSignInKind.google},
      ));
      await _pump(tester, ShellTopBar(identity: identity));
      expect(find.text('marco@example.com'), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-kind-email')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-kind-google')), findsOneWidget);

      identity.value = const ShellIdentity(
        name: 'Marco',
        email: 'marco@example.com',
        kinds: {ShellSignInKind.google},
      );
      await tester.pump();
      expect(find.text('Marco'), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-kind-email')), findsNothing);
    });

    testWidgets('plan badge, sync status and notifications', (tester) async {
      final plan = ValueNotifier(ShellPlan.free);
      final sync = _FakeSync(const ShellSyncState());
      final unread = ValueNotifier(3);
      var opened = 0;
      await _pump(
          tester,
          ShellTopBar(
            plan: plan,
            sync: sync,
            unreadNotifications: unread,
            onNotificationsPressed: (_) => opened++,
          ));

      expect(find.text('FREE'), findsOneWidget);
      plan.value = ShellPlan.premium;
      await tester.pump();
      expect(find.text('PREMIUM'), findsOneWidget);

      expect(find.text('Cloud · synced'), findsOneWidget);
      sync.value = sync.value.copyWith(online: false, pendingChanges: 2);
      await tester.pump();
      expect(find.text('Offline · local · 2 to sync'), findsOneWidget);
      sync.value = sync.value.copyWith(mode: ShellStorageMode.local);
      await tester.pump();
      expect(find.text('Local'), findsOneWidget);

      expect(find.text('3'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shell-notifications')));
      expect(opened, 1);
    });

    testWidgets('sync sheet switches mode and syncs', (tester) async {
      final sync = _FakeSync(const ShellSyncState());
      await _pump(tester, ShellTopBar(sync: sync));
      await tester.tap(find.byKey(const ValueKey('shell-sync')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('shell-sync-now')));
      expect(sync.syncs, 1);

      await tester.tap(find.text('This device'));
      await tester.pump();
      expect(sync.value.mode, ShellStorageMode.local);
      // Working locally: nothing to sync.
      await tester.tap(find.byKey(const ValueKey('shell-sync-now')));
      expect(sync.syncs, 1);
    });

    testWidgets('wide: one row', (tester) async {
      await _pump(
        tester,
        ShellTopBar(plan: ValueNotifier(ShellPlan.free)),
        width: 1000,
      );
      expect(find.byKey(const ValueKey('shell-top-bar-wide')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-top-bar-narrow')), findsNothing);
      // The body starts right under the single row.
      expect(tester.getTopLeft(find.text('body')).dy, ShellTopBar.rowHeight);
    });

    testWidgets('identity tap opens settings; info opens About',
        (tester) async {
      await _pump(
          tester,
          ShellTopBar(
            settingsBuilder: () => const Scaffold(body: Text('my settings')),
          ));
      await tester.tap(find.byKey(const ValueKey('shell-identity')));
      await tester.pumpAndSettle();
      expect(find.text('my settings'), findsOneWidget);
      Navigator.of(tester.element(find.text('my settings'))).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('shell-info')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shell-about')), findsOneWidget);
    });

    testWidgets('follows the Italian language', (tester) async {
      await appLocale.setLanguage(ShellLanguage.italiano);
      await _pump(tester, const ShellTopBar());
      expect(find.text('Ospite'), findsOneWidget);
    });
  });

  group('settings avatar picker', () {
    testWidgets('picking a preset saves and persists it', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester
          .pumpWidget(const MaterialApp(home: SettingsScreen(gameId: 'probe')));
      await tester.pump();

      final fox = find.byKey(const ValueKey('avatar-option-preset:fox'));
      await tester.dragUntilVisible(fox,
          find.byKey(const ValueKey('settings-list')), const Offset(0, -200));
      await tester.tap(fox);
      await tester.pump();

      expect(account.avatar?.token, 'preset:fox');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('prefs.account.avatar'), 'preset:fox');
      // No Google photo on this account: no photo option.
      expect(
          find.byKey(const ValueKey('avatar-option-provider')), findsNothing);
    });
  });

  test('ShellSyncState.workingLocally', () {
    expect(const ShellSyncState().workingLocally, isFalse);
    expect(const ShellSyncState(online: false).workingLocally, isTrue);
    expect(const ShellSyncState(mode: ShellStorageMode.local).workingLocally,
        isTrue);
    expect(kIsWeb, isFalse);
  });
}
