import 'dart:async';

import 'package:app_links_platform_interface/app_links_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// The PKCE code collector: `oauthCodeFromUri` extraction (query and
/// fragment forms) plus the code-aware deep-link flow driven with injected
/// platform callbacks — and over the real `url_launcher` / `app_links`
/// platform interfaces with fakes, mirroring the implicit collector's test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeLauncher launcher;
  late _FakeLinks links;

  setUp(() {
    launcher = _FakeLauncher();
    UrlLauncherPlatform.instance = launcher;
    links = _FakeLinks();
    AppLinksPlatform.instance = links;
  });

  group('oauthCodeFromUri', () {
    test('reads the code from the query', () {
      expect(
        oauthCodeFromUri(Uri.parse(
            'https://app.example/?code=abc123&state=x#/oauth-callback')),
        'abc123',
      );
    });

    test('reads the code from the fragment too', () {
      expect(oauthCodeFromUri(Uri.parse('mygame://auth#code=xyz')), 'xyz');
    });

    test('reads a fragment that carries a leading ?', () {
      expect(oauthCodeFromUri(Uri.parse('mygame://auth#?code=q1')), 'q1');
    });

    test('decodes a percent-encoded fragment value', () {
      expect(oauthCodeFromUri(Uri.parse('mygame://auth#code=a%2Bb')), 'a+b');
    });

    test('null when the redirect carries no code', () {
      expect(
          oauthCodeFromUri(Uri.parse('mygame://auth#access_token=t')), isNull);
      expect(
          oauthCodeFromUri(Uri.parse('mygame://auth?error=access_denied')),
          isNull);
    });
  });

  group('collectOAuthCodeDeepLink (injected callbacks)', () {
    const warm = OauthRedirectCallbacks(
      initial: _noInitial,
      stream: Stream.empty(),
    );

    test('launch failure throws instead of waiting for a redirect', () async {
      var launchFailed = false;
      launcher.launchSucceeds = false;
      await expectLater(
        collectOAuthCodeDeepLink(
          'https://game.example/auth/v1/authorize?provider=google',
          callbacks: warm,
          onLaunchFailed: () => launchFailed = true,
        ),
        throwsStateError,
      );
      expect(launchFailed, isTrue);
    });

    test('a warm redirect carrying the code completes the flow', () async {
      final controller = StreamController<Uri>();
      final flow = collectOAuthCodeDeepLink(
        'https://game.example/authorize',
        callbacks: OauthRedirectCallbacks(
          initial: _noInitial,
          stream: controller.stream,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      controller.add(Uri.parse('mygame://auth?code=warm-code'));
      expect(await flow, 'warm-code');
      await controller.close();
    });

    test('a token-only redirect keeps waiting; the abandon beat is null',
        () async {
      final controller = StreamController<Uri>();
      final flow = collectOAuthCodeDeepLink(
        'https://game.example/authorize',
        callbacks: OauthRedirectCallbacks(
          initial: _noInitial,
          stream: controller.stream,
        ),
        timeout: const Duration(milliseconds: 200),
      );
      await Future<void>.delayed(Duration.zero);
      // An implicit fragment is not a PKCE code — not a completion.
      controller.add(Uri.parse('mygame://auth#access_token=abc'));
      expect(await flow, isNull,
          reason: 'no code in the timeout window = cancelled flow');
      await controller.close();
    });

    test('a cold-start link IS the callback — no browser launch', () async {
      final code = await collectOAuthCodeDeepLink(
        'https://game.example/authorize',
        callbacks: const OauthRedirectCallbacks(
          initial: _coldInitial,
          stream: Stream.empty(),
        ),
      );
      expect(code, 'cold-code');
      expect(launcher.launchedUrls, isEmpty,
          reason: 'the browser was already driven by the earlier attempt');
    });
  });

  group('the native PKCE collector over the real interfaces', () {
    test('opens the browser and completes on the link', () async {
      final flow = collectOAuthCodeNative(
          'https://game.example/auth/v1/authorize?provider=google');
      await Future<void>.delayed(Duration.zero);
      expect(launcher.launchedUrls.single,
          'https://game.example/auth/v1/authorize?provider=google');
      links.controller.add(Uri.parse('mygame://auth?code=native-code'));
      expect(await flow, 'native-code');
    });
  });
}

Future<Uri?> _noInitial() async => null;

Future<Uri?> _coldInitial() async => Uri.parse('mygame://auth?code=cold-code');

class _FakeLauncher extends UrlLauncherPlatform {
  final launchedUrls = <String>[];

  /// Flip to false to emulate a device where nothing answers the link.
  bool launchSucceeds = true;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    launchedUrls.add(url);
    return launchSucceeds;
  }
}

class _FakeLinks extends AppLinksPlatform {
  final controller = StreamController<Uri>();

  @override
  Future<Uri?> getInitialLink() async => null;

  @override
  Stream<Uri> get uriLinkStream => controller.stream.asBroadcastStream();
}
