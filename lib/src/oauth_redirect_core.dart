/// The core mobile OAuth flow, dependency-light and test-injectable: the
/// platform plumbing (Android App Links / iOS Universal Links) arrives
/// through [OauthRedirectCallbacks], so widget-free tests drive the whole
/// timeline on the VM.
library;

import 'dart:async';

import 'package:url_launcher/url_launcher.dart';
/// How long the collector waits for the redirect before treating the flow
/// as abandoned (the player back-swiped into the app and gave up) — null
/// resolves to a cancelled sign-in, not an error.
const Duration oauthDeepLinkTimeout = Duration(minutes: 10);

/// The platform callbacks the deep-link collector listens to. Both Android
/// App Links and iOS Universal Links deliver the server's redirect through
/// one [stream]; [initial] carries the cold-start link when the browser
/// session outlived the killed app process.
class OauthRedirectCallbacks {
  const OauthRedirectCallbacks({
    required this.initial,
    required this.stream,
  });

  /// The link the app was cold-started with (null on a warm start).
  final Future<Uri?> Function() initial;

  /// Links delivered while the app runs.
  final Stream<Uri> stream;
}

/// True when a redirect delivery races the flow: it arrived before
/// [collectOAuthFragmentDeepLink] armed its subscription (a cold start that
/// landed while the previous attempt was still cleaning up). Hosts that
/// cache the last delivery use this to replay it into the fresh flow — the
/// reference collector relies on [OauthRedirectCallbacks.initial] instead.
bool deferredOauthRedirect(OauthRedirectCallbacks callbacks,
        {required bool wasArmed}) =>
    !wasArmed;

/// The deep-link OAuth collector: opens [authorizeUrl] in the system
/// browser (an external session — the provider's privacy policy, and the
/// WebView-based in-app browsers Google blocks) and completes when the
/// server's redirect re-opens the app carrying the implicit fragment
/// (`…#access_token=…&refresh_token=…`).
///
/// Timelines it covers:
///
///  * **warm app** — a [OauthRedirectCallbacks.stream] event completes the
///    flow;
///  * **cold start** — the process died mid-flow, so the initial link IS
///    the callback; it is consulted before the browser even opens;
///  * **browser refused** ([onLaunchFailed]) — `launchUrl` returning false
///    (no browser, blocked scheme) surfaces as a [StateError];
///  * **player gives up** ([onTimeout]) — the wait outlives
///    [oauthDeepLinkTimeout] and resolves to null: a cancelled sign-in,
///    not an error.
///
/// A delivery that races the arm (the redirect landing between the initial
/// read and the subscription — [deferredOauthRedirect]) is reported through
/// [onDeferred] rather than swallowed, so hosts with their own delivery
/// cache can replay it.
Future<String?> collectOAuthFragmentDeepLink(
  String authorizeUrl, {
  required OauthRedirectCallbacks callbacks,
  bool Function()? onLaunchFailed,
  bool Function()? onTimeout,
  bool Function()? onDeferred,
  Duration timeout = oauthDeepLinkTimeout,
}) async {
  final completer = Completer<String?>();
  late final StreamSubscription<Uri> subscription;
  var armed = false;

  void handle(Uri? uri, {bool fromInitial = false}) {
    final fragment = uri?.fragment;
    if (fragment == null || !fragment.contains('access_token=')) return;
    if (completer.isCompleted) return;
    if (!armed && !fromInitial) {
      // A stream delivery beat the arm — report it, ignore the value: the
      // flow subscribes right after the initial read, so a racing delivery
      // is the host's replay concern, not this flow's. The initial link is
      // exempt: it IS the cold-start callback by definition.
      onDeferred?.call();
      return;
    }
    // Deliver in the same shape the web collector's `location.hash` does —
    // leading `#` included — so [AuthService.sessionFromImplicitFragment]
    // sees one contract from every collector.
    completer.complete('#$fragment');
  }

  // Cold start first: the initial link IS the callback when the process
  // was restarted mid-flow — the stream would never see it. When it
  // completes the flow there is nothing left to launch: the browser was
  // already driven by the earlier attempt.
  final initial = await callbacks.initial();
  handle(initial, fromInitial: true);
  if (completer.isCompleted) return completer.future;

  subscription = callbacks.stream.listen(
    handle,
    onError: (Object error) {
      if (!completer.isCompleted) completer.completeError(error);
    },
    onDone: () {
      if (!completer.isCompleted) completer.complete(null);
    },
  );
  armed = true;

  final launched = await launchUrl(Uri.parse(authorizeUrl),
      mode: LaunchMode.externalApplication);
  if (!launched) {
    onLaunchFailed?.call();
    await subscription.cancel();
    throw StateError(
        'Could not open the browser for sign-in — nothing answered the authorize link.');
  }

  final timer = Timer(timeout, () {
    if (completer.isCompleted) return;
    onTimeout?.call();
    completer.complete(null);
  });
  return completer.future.whenComplete(() async {
    timer.cancel();
    armed = false;
    await subscription.cancel();
  });
}
