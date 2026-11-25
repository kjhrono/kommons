import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kommons/kommons.dart';
import 'package:mediasart_auth_client/mediasart_auth_client.dart' as kit;
import 'package:shared_preferences/shared_preferences.dart';

class _Notes implements ShellBackupSource {
  _Notes(this.notes, {this.appId = 'notes', this.schemaVersion = 2});
  List<String> notes;
  @override
  final String appId;
  @override
  final int schemaVersion;
  int? importedFrom;

  @override
  Future<Map<String, dynamic>> exportData() async => {'notes': notes};

  @override
  Future<void> importData(Map<String, dynamic> data, int fromVersion) async {
    notes = List<String>.from(data['notes'] as List);
    importedFrom = fromVersion;
  }
}

class _Files extends ShellBackupFiles {
  Uint8List? saved;
  String? savedName;
  Uint8List? toPick;

  @override
  Future<bool> save(String fileName, Uint8List bytes) async {
    savedName = fileName;
    saved = bytes;
    return true;
  }

  @override
  Future<Uint8List?> pick() async => toPick;
}

String _jwt(Map<String, dynamic> claims) {
  String b64(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${b64({'alg': 'none'})}.${b64(claims)}.sig';
}

class _Host extends IdentityAccountHost {
  _Host(this.current);
  kit.AuthSession? current;
  final _changes = StreamController<Object?>.broadcast();
  int signedOut = 0;
  @override
  late final kit.MediasartAuth auth = _Auth();
  @override
  String get oauthRedirectTo => 'app://auth';
  @override
  String get resetRedirectTo => 'https://app.test/reset';
  @override
  kit.AuthSession? get currentSession => current;
  @override
  Stream<Object?> get sessionChanges => _changes.stream;
  @override
  Future<void> adoptSession(kit.AuthSession session) async {
    current = session;
    _changes.add(null);
  }

  @override
  Future<void> signOut() async {
    signedOut++;
    current = null;
    _changes.add(null);
  }
}

class _Auth implements kit.MediasartAuth {
  @override
  String get supabaseUrl => 'https://identity.test';
  @override
  String get anonKey => 'anon';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    account.resetForTest();
    appLocale.resetForTest();
    appTheme.resetForTest();
    appAccent.resetForTest();
  });

  group('backup file', () {
    test('round-trips, with the app, version and date', () async {
      final source = _Notes(['a', 'b']);
      final bytes =
          await encodeShellBackup(source, now: DateTime.utc(2026, 11, 25));
      final file = await decodeShellBackup(bytes, _Notes([]));
      expect(file.appId, 'notes');
      expect(file.schemaVersion, 2);
      expect(file.createdAt, DateTime.utc(2026, 11, 25));
      expect(file.encrypted, isFalse);
      expect(file.data, {
        'notes': ['a', 'b']
      });
    });

    test('a password encrypts it; wrong password and no password', () async {
      final bytes = await encodeShellBackup(_Notes(['secret']),
          password: 'pw-1', iterations: 1000);
      expect(utf8.decode(bytes), isNot(contains('secret')));
      final locked = await decodeShellBackup(bytes, _Notes([]));
      expect(locked.encrypted, isTrue);
      expect(locked.data, isNull);
      await expectLater(
          decodeShellBackup(bytes, _Notes([]), password: 'nope'),
          throwsA(isA<ShellBackupException>().having(
              (e) => e.error, 'error', ShellBackupError.wrongPassword)));
      final open = await decodeShellBackup(bytes, _Notes([]), password: 'pw-1');
      expect(open.data, {
        'notes': ['secret']
      });
    });

    Future<ShellBackupError?> refusal(
        Uint8List bytes, ShellBackupSource to) async {
      try {
        await decodeShellBackup(bytes, to);
        return null;
      } on ShellBackupException catch (e) {
        return e.error;
      }
    }

    test('refuses another app, a newer version, and damage', () async {
      final bytes = await encodeShellBackup(_Notes(['a']));
      expect(await refusal(bytes, _Notes([], appId: 'other')),
          ShellBackupError.wrongApp);
      expect(await refusal(bytes, _Notes([], schemaVersion: 1)),
          ShellBackupError.newerVersion);
      expect(
          await refusal(Uint8List.fromList(utf8.encode('hello')), _Notes([])),
          ShellBackupError.corrupt);

      final envelope = jsonDecode(utf8.decode(bytes)) as Map;
      envelope['payload'] = jsonEncode({
        'notes': ['tampered']
      });
      expect(
          await refusal(Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
              _Notes([])),
          ShellBackupError.corrupt);
    });

    testWidgets('card: export saves; import asks, then replaces',
        (tester) async {
      final source = _Notes(['mine']);
      final files = _Files();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ShellBackupCard(
                  source: source, files: files, kdfIterations: 1000))));

      /// Pumps until the card's work is done (its progress bar animates
      /// forever while busy, so pumpAndSettle would never return).
      Future<void> settle() async {
        for (var i = 0; i < 50; i++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump(const Duration(milliseconds: 50));
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
        }
        await tester.pump(const Duration(milliseconds: 300));
      }

      await tester.tap(find.byKey(const ValueKey('backup-export')));
      await settle();
      await tester.tap(find.byKey(const ValueKey('backup-password-ok')));
      await settle();
      expect(files.savedName, startsWith('notes-backup-'));
      expect(find.text('Backup saved.'), findsOneWidget);

      source.notes = ['changed'];
      files.toPick = files.saved;
      await tester.tap(find.byKey(const ValueKey('backup-import')));
      await settle();
      expect(find.byKey(const ValueKey('backup-confirm')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('backup-confirm-replace')));
      await settle();
      expect(source.notes, ['mine']);
      expect(source.importedFrom, 2);
      expect(find.text('Backup restored.'), findsOneWidget);
    });

    testWidgets('card: another app’s backup is refused with a reason',
        (tester) async {
      final files = _Files()
        ..toPick = await tester
            .runAsync(() => encodeShellBackup(_Notes(['x'], appId: 'other')));
      final source = _Notes(['mine']);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: ShellBackupCard(source: source, files: files))));
      await tester.tap(find.byKey(const ValueKey('backup-import')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('This is a backup of another app.'), findsOneWidget);
      expect(source.notes, ['mine']);
    });
  });

  group('colour themes', () {
    testWidgets('picking an accent re-seeds ShellApp and persists',
        (tester) async {
      _tall(tester);
      await tester.pumpWidget(ShellApp(
        seedColor: const Color(0xff7a5c2e),
        home: const SettingsScreen(),
      ));
      await tester.pumpAndSettle();
      final before = Theme.of(tester.element(find.byType(SettingsScreen)))
          .colorScheme
          .primary;

      await tester.tap(find.byKey(const ValueKey('accent-ocean')));
      await tester.pumpAndSettle();
      expect(appAccent.value?.id, 'ocean');
      final after = Theme.of(tester.element(find.byType(SettingsScreen)))
          .colorScheme
          .primary;
      expect(after, isNot(before));
      expect(
          (await SharedPreferences.getInstance()).getString('prefs.app.accent'),
          'ocean');

      await tester.tap(find.byKey(const ValueKey('accent-app')));
      await tester.pumpAndSettle();
      expect(appAccent.value, isNull);
    });

    testWidgets('allowAccent: false hides the picker', (tester) async {
      _tall(tester);
      await tester.pumpWidget(ShellApp(
        seedColor: const Color(0xff7a5c2e),
        allowAccent: false,
        home: const SettingsScreen(),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('accent-card')), findsNothing);
    });

    test('accent takes part in the cross-app sync', () {
      final result = shellPreferencesReconcile(
        cloudPreferences: const {
          'accent': 'violet',
          'updatedAt': {'accent': 20},
        },
        localTheme: null,
        localLocale: null,
        localPlayerName: null,
        localAccent: 'ocean',
        localStamps: const {'accent': 10},
      );
      expect(result.pull[ShellPrefKey.accent], 'violet');
    });
  });

  group('settings layout', () {
    testWidgets('fixed sections in order; hidden ones drop out',
        (tester) async {
      _tall(tester);
      await tester.pumpWidget(MaterialApp(
          home: SettingsScreen(
        backup: _Notes([]),
        premiumSection: const Card(key: ValueKey('premium-here')),
      )));
      await tester.pump();
      double y(String text) => tester.getTopLeft(find.text(text)).dy;
      final order = [
        'PROFILE',
        'ACCOUNT',
        'APPEARANCE',
        'LANGUAGE',
        'DATA',
        'PREMIUM',
        'ABOUT'
      ];
      for (var i = 1; i < order.length; i++) {
        expect(y(order[i]), greaterThan(y(order[i - 1])),
            reason: '${order[i]} below ${order[i - 1]}');
      }
      expect(find.byKey(const ValueKey('backup-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('premium-here')), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(
          home: SettingsScreen(hiddenSections: {
        ShellSettingsSection.language,
        ShellSettingsSection.about,
      })));
      await tester.pump();
      expect(find.text('LANGUAGE'), findsNothing);
      expect(find.text('ABOUT'), findsNothing);
      expect(find.text('DATA'), findsNothing, reason: 'nothing to show');
      expect(find.text('PROFILE'), findsOneWidget);
    });
  });

  group('delete account', () {
    late _Host host;
    late List<String> events;
    late List<Map<String, dynamic>> calls;
    final opened = <Uri>[];

    setUp(() async {
      events = [];
      calls = [];
      opened.clear();
      host = _Host(kit.AuthSession(
        userId: 'u1',
        email: 'u1@example.test',
        accessToken: _jwt({'sub': 'u1', 'exp': 4102444800}),
        refreshToken: 'rt',
      ));
      account.identityAuthService = AuthService(
          serverUrl: 'https://identity.test',
          client: MockClient((_) async => http.Response('{}', 200)));
      account.deleteAccountClient = MockClient((request) async {
        expect(request.url.toString(),
            'https://identity.test/functions/v1/account-delete');
        calls.add(jsonDecode(request.body) as Map<String, dynamic>);
        events.add('server');
        return http.Response('{"removed":"notes"}', 200);
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('prefs.license.notes.u1', 'license');
      await prefs.setString('prefs.license.notes.u1.tamper', '[]');
      await prefs.setString('prefs.license.other.u1', 'keep');
    });

    Future<void> open(WidgetTester tester,
        {Future<void> Function()? beforeRemove}) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ShellDeleteAccountTile(
        appId: 'notes',
        appName: 'Notes',
        beforeRemove: beforeRemove,
        openUrl: (url) async {
          opened.add(url);
          return true;
        },
      ))));
      await tester.pump();
    }

    Future<void> choose(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(const ValueKey('delete-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    testWidgets('hidden while signed out', (tester) async {
      await open(tester);
      expect(find.byKey(const ValueKey('delete-account')), findsNothing);
    });

    testWidgets('this app only: needs the word, app data first, then server',
        (tester) async {
      account.attachIdentityHost(host);
      await open(tester, beforeRemove: () async => events.add('app'));
      await choose(tester, 'delete-choice-app');

      final confirm = find.byKey(const ValueKey('delete-account-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.enterText(
          find.byKey(const ValueKey('delete-account-confirm-field')), 'delete');
      await tester.pump();
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      expect(events, ['app', 'server']);
      expect(
          calls.single, {'scope': 'app', 'app_id': 'notes', 'confirm': true});
      expect(host.signedOut, 1);
      expect(find.text('Your data was removed from Notes.'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('prefs.license.notes.u1'), isNull);
      expect(prefs.getString('prefs.license.notes.u1.tamper'), isNull);
      expect(prefs.getString('prefs.license.other.u1'), 'keep',
          reason: 'other apps keep their licenses');
    });

    testWidgets('whole account: opens the mediasart.com account page',
        (tester) async {
      account.attachIdentityHost(host);
      // No sync push (and its timer) for a test-only language switch.
      await appLocale.applySynced(ShellLanguage.italiano);
      await open(tester);
      await choose(tester, 'delete-choice-everywhere');
      expect(opened.single.toString(), 'https://mediasart.com/it/account');
      expect(calls, isEmpty, reason: 'nothing deleted from the app');
      expect(host.signedOut, 0);
    });

    testWidgets('a failing app cleanup stops the removal', (tester) async {
      account.attachIdentityHost(host);
      await open(tester, beforeRemove: () async => throw StateError('no'));
      await choose(tester, 'delete-choice-app');
      await tester.enterText(
          find.byKey(const ValueKey('delete-account-confirm-field')), 'DELETE');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('delete-account-confirm')));
      await tester.pumpAndSettle();
      expect(events, isEmpty);
      expect(host.signedOut, 0);
    });
  });
}
