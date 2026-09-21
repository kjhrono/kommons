import 'dart:async';

import 'package:app_links_platform_interface/app_links_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// The deep-link OAuth collector: the core flow is driven with injected
/// platform callbacks (no real browser or app-link backend on the VM),
/// covering the warm return, the cold start, the refused launch and the
/// abandoned wait — plus the controller wiring through the real
/// `url_launcher` / `app_links` platform interfaces with fakes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeLauncher launcher;
  late _FakeLinks links;

  setUp(() {
    // Fresh fakes per test: every collector path goes through the same
    // platform interfaces a device would (launch + app links), so the VM
    // never reaches for a method channel.
    launcher = _FakeLauncher();
    UrlLauncherPlatform.instance = launcher;
    links = _FakeLinks();
    AppLinksPlatform.instance = links;
  });

  group('core flow (injected callbacks)', () {
    const warm = OauthRedirectCallbacks(
      initial: _noInitial,
      stream: Stream.empty(),
    );

    test('launch failure throws instead of waiting for a redirect', () async {
      var launchFailed = false;
      launcher.launchSucceeds = false;
      await expectLater(
        collectOAuthFragmentDeepLink(
          'https://game.example/auth/v1/authorize?provider=google',
          callbacks: warm,
          onLaunchFailed: () => launchFailed = true,
        ),
        throwsStateError,
      );
      expect(launchFailed, isTrue);
    });

    test('a warm redirect carrying the token completes the flow', () async {
      final controller = StreamController<Uri>();
      final flow = collectOAuthFragmentDeepLink(
        'https://game.example/authorize',
        callbacks: OauthRedirectCallbacks(
          initial: _noInitial,
          stream: controller.stream,
        ),
      );
      // Let the subscription arm before the delivery.
      await Future<void>.delayed(Duration.zero);
      controller
          .add(Uri.parse('mygame://auth#access_token=abc&refresh_token=def'));
      expect(await flow, '#access_token=abc&refresh_token=def');
      await controller.close();
    });

    test('an error fragment keeps waiting; the abandon beat cancels quietly',
        () async {
      final controller = StreamController<Uri>();
      final flow = collectOAuthFragmentDeepLink(
        'https://game.example/authorize',
        callbacks: OauthRedirectCallbacks(
          initial: _noInitial,
          stream: controller.stream,
        ),
        timeout: const Duration(milliseconds: 200),
      );
      await Future<void>.delayed(Duration.zero);
      // The provider's access_denied fragment carries no token: not a
      // completion. The flow stays armed until the abandon beat.
      controller.add(Uri.parse('mygame://auth#error=access_denied'));
      expect(await flow, isNull,
          reason: 'no token in the timeout window = cancelled flow');
      await controller.close();
    });

    test('a cold-start link IS the callback — no browser launch', () async {
      final fragment = await collectOAuthFragmentDeepLink(
        'https://game.example/authorize',
        callbacks: const OauthRedirectCallbacks(
          initial: _coldInitial,
          stream: Stream.empty(),
        ),
      );
      expect(fragment, '#access_token=cold&refresh_token=start');
      expect(launcher.launchedUrls, isEmpty,
          reason: 'the browser was already driven by the earlier attempt');
    });
  });

  group('the native collector over the real interfaces', () {
    test('opens the browser and completes on the link', () async {
      final flow = collectOAuthFragmentNative(
          'https://game.example/auth/v1/authorize?provider=github');
      await Future<void>.delayed(Duration.zero);
      expect(launcher.launchedUrls.single,
          'https://game.example/auth/v1/authorize?provider=github');
      links.controller
          .add(Uri.parse('mygame://auth#access_token=gh&refresh_token=x'));
      expect(await flow, '#access_token=gh&refresh_token=x');
    });

    test('signInWithProvider uses the host-set oauthRedirectUri end to end',
        () async {
      SharedPreferences.setMockInitialValues({});
      account.resetForTest();
      await account.load();
      final service = _FakeAuthService();
      account.authService = service;
      account.oauthRedirectUri = Uri.parse('mygame://auth');
      // The documented host injection: the core flow over this test's own
      // link plumbing (the AppLinks wrapper's bridge is a process-wide
      // singleton, so a fresh fake needs the explicit seam).
      account.collectOAuthFragment = (url) => collectOAuthFragmentDeepLink(
            url,
            callbacks: OauthRedirectCallbacks(
              initial: links.getInitialLink,
              stream: links.uriLinkStream,
            ),
          );
      final flow = account.signInWithProvider('google');
      await Future<void>.delayed(Duration.zero);
      expect(service.authorizeCalls.single.toString(),
          startsWith('mygame://auth'));
      expect(launcher.launchedUrls.single, startsWith('mygame://auth'));
      links.controller
          .add(Uri.parse('mygame://auth#access_token=tok&refresh_token=ref'));
      await flow;
      expect(account.value?.provider, 'google');
      expect(account.value?.email, 'ada@example.com');
      account.collectOAuthFragment = null;
      account.oauthRedirectUri = null;
    });
  });
}

Future<Uri?> _noInitial() async => null;

Future<Uri?> _coldInitial() async =>
    Uri.parse('mygame://auth#access_token=cold&refresh_token=start');

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

class _FakeAuthService extends AuthService {
  _FakeAuthService() : super(serverUrl: 'https://game.example');

  final authorizeCalls = <Uri>[];

  @override
  Uri authorizeUrl({required String provider, required Uri redirectTo}) {
    // Built on the redirect target so the launch asserts the deep-link scheme
    // (what this test is about), carrying the real path shape so the fixture
    // stays recognisable as production traffic.
    final call = redirectTo.replace(
        path: '/auth/v1/authorize',
        queryParameters: {'provider': provider, 'redirect_to': redirectTo.toString()});
    authorizeCalls.add(call);
    return call;
  }

  @override
  Future<({String id, String email, bool confirmed})> fetchUser(
          String accessToken) async =>
      (id: 'u1', email: 'ada@example.com', confirmed: true);
}
