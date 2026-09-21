import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'app_settings.dart';
import 'app_top_bar.dart';

/// What the splash offers below the flavor text.
///
///  * [both] — NEW GAME (leads) and CONTINUE, the classic game shape.
///  * [startOnly] — NEW GAME alone (a server-only companion app).
///  * [direct] — PLAY alone: enter the app directly, no lobby (single-player
///    games, personal apps).
///  * [directAndNewGame] — PLAY (leads) then NEW GAME: single-player is the
///    front door, the shared lobby sits one tap behind for multiplayer.
enum SplashActions { both, startOnly, direct, directAndNewGame }

/// One splash scene: the greeting line and the foreground art that acts it
/// out. A null vignette keeps the bare backdrop (the founding scene lives in
/// the backdrop itself).
class SplashScene {
  const SplashScene(
      {required this.line, required this.vignette, required this.story});

  final String line;
  final String? vignette;

  /// What the vignette shows, for screen readers and tests.
  final String story;
}

/// The shell's default scene deck — capital-backdrop scenes plus the three
/// vignette acts (caravan, dungeon, tame). Apps may pass their own deck via
/// [AppSplash.scenes].
const List<SplashScene> kDefaultSplashScenes = [
  SplashScene(
    line: 'Your table is waiting — the story starts the moment you sit down.',
    vignette: null,
    story: 'The world from above, resting before the first move',
  ),
  SplashScene(
    line: 'Every traveler on the road carries a tale worth trading.',
    vignette: 'packages/kommons/assets/splash_caravan.svg',
    story: 'A caravan on the trade road, oxen hauling and spears up',
  ),
  SplashScene(
    line: 'Some doors only open for those who bring their own light.',
    vignette: 'packages/kommons/assets/splash_dungeon.svg',
    story: 'A torch-lit gate over steps the daylight never reaches',
  ),
  SplashScene(
    line: 'The wild keeps its own counsel — win it with patience, not noise.',
    vignette: 'packages/kommons/assets/splash_tame.svg',
    story: "A griffin kneeling to a trainer's open hand",
  ),
];

/// The shared main splash: background art, the app's name/description,
/// a welcome for the (anonymous or signed-in) player, a rolled flavor
/// scene, and the New Game / Continue buttons under the top bar.
///
/// The shell's own strings follow [appLocale]; the host-supplied ones
/// (this config) are the host's to localize — pass [continueLabel] when
/// the CONTINUE caption must match your game's language.
///
/// Everything app-specific arrives through the config:
///  * [appName] / [description] — the big title and the footer line
///  * [welcomeName] — "Welcome, X" (null collapses to the anonymous form)
///  * [background] / [scenes] — art + flavor deck (defaults to the shell's)
///  * [onNewGame] / [onContinue] / [continueEnabled] — the buttons; pass
///    onContinue only when the app has something to load
///  * [settingsBuilder] — forwarded to [AppTopBar], so the gear opens the
///    host's flavored settings screen
class AppSplash extends StatefulWidget {
  const AppSplash({
    super.key,
    required this.appName,
    required this.description,
    this.welcomeName,
    this.background,
    this.scenes = kDefaultSplashScenes,
    this.onNewGame,
    this.onContinue,
    this.continueEnabled = false,
    this.continueLabel,
    this.actions = SplashActions.both,
    this.directLabel,
    this.onDirect,
    this.startLabel,
    this.settingsBuilder,
    this.debugSceneIndex,
    this.animateEntrance = true,
  });

  final String appName;
  final String description;

  /// Overrides the display name in the welcome line (anonymous or
  /// signed-in). Null reads the shared account's player name.
  final String? welcomeName;
  final String? background;
  final List<SplashScene> scenes;
  final VoidCallback? onNewGame;
  final VoidCallback? onContinue;

  /// The direct-entry PLAY button's callback — fired by the
  /// [SplashActions.direct] and [directAndNewGame] variants.
  final VoidCallback? onDirect;

  /// Real enabled state of the Continue button (has local or cloud games?).
  final bool continueEnabled;

  /// The Continue button's caption. Null (the default) localizes it from
  /// the persisted [appLocale]; a host's own string wins over both.
  final String? continueLabel;

  /// The PLAY (direct-entry) button's caption. Null (the default)
  /// localizes it from the persisted [appLocale]; a host's own string wins.
  final String? directLabel;

  /// Host override for the primary button's caption (defaults to the
  /// localized NEW GAME). Non-game shells relabel it — e.g. "OPEN
  /// CATALOGUE" — without touching the shell's strings.
  final String? startLabel;
  final SplashActions actions;
  final Widget Function()? settingsBuilder;

  /// The PLAY button's caption override (the [SplashActions.direct] and
  /// [directAndNewGame] variants). Null localizes it from [appLocale].

  /// Test seam pinning the scene roll to an index (null in production).
  final int? debugSceneIndex;

  /// Whether the splash makes its entrance: the title block fades and
  /// rises first, the buttons stagger in (New Game leads, Continue 100 ms
  /// behind), and the flavor line and foreground vignette arrive last so
  /// the scene settles bottom-up. On by default — the shared first
  /// impression — and skipped automatically when the platform asks for
  /// reduced motion. Pass false for a static splash (tests, embeds).
  final bool animateEntrance;

  @override
  State<AppSplash> createState() => _AppSplashState();
}

class _AppSplashState extends State<AppSplash>
    with SingleTickerProviderStateMixin {
  // Entrance timeline (ms): the title fades and rises 0→455, the buttons
  // stagger in (New Game leads at 280, Continue follows 100 ms later, each
  // fading/rising over 280 ms), then the scene settles bottom-up — the
  // flavor line fades in at 660 and the foreground vignette rises onto the
  // valley floor at 760, each over 200 ms.
  static const int _runMs = 1000;
  static const int _btnStartMs = 280;
  static const int _staggerMs = 100;
  static const int _btnFadeMs = 280;
  static const int _flavorStartMs = 660;
  static const int _flavorMs = 200;
  static const int _vignetteStartMs = 760;
  static const int _vignetteMs = 200;
  static double _at(int ms) => ms / _runMs;

  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _runMs),
    value: widget.animateEntrance ? 0 : 1,
  );
  late final Animation<double> _titleFade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _entrance,
          curve: Interval(0.0, _at(455), curve: Curves.easeOut)));
  late final Animation<Offset> _titleRise =
      Tween(begin: const Offset(0, 0.12), end: Offset.zero).animate(
          CurvedAnimation(
              parent: _entrance,
              curve: Interval(0.0, _at(455), curve: Curves.easeOut)));
  // New Game's arrival: fade paired with a small rise, like the title.
  late final Animation<double> _newGameFade = Tween(begin: 0.0, end: 1.0)
      .animate(CurvedAnimation(
          parent: _entrance,
          curve: Interval(_at(_btnStartMs), _at(_btnStartMs + _btnFadeMs),
              curve: Curves.easeOut)));
  late final Animation<Offset> _newGameRise =
      Tween(begin: const Offset(0, 0.08), end: Offset.zero).animate(
          CurvedAnimation(
              parent: _entrance,
              curve: Interval(_at(_btnStartMs), _at(_btnStartMs + _btnFadeMs),
                  curve: Curves.easeOut)));
  // Continue's arrival: the same window shifted [_staggerMs] later.
  late final Animation<double> _continueFade = Tween(begin: 0.0, end: 1.0)
      .animate(CurvedAnimation(
          parent: _entrance,
          curve: Interval(_at(_btnStartMs + _staggerMs),
              _at(_btnStartMs + _staggerMs + _btnFadeMs),
              curve: Curves.easeOut)));
  late final Animation<Offset> _continueRise =
      Tween(begin: const Offset(0, 0.08), end: Offset.zero).animate(
          CurvedAnimation(
              parent: _entrance,
              curve: Interval(_at(_btnStartMs + _staggerMs),
                  _at(_btnStartMs + _staggerMs + _btnFadeMs),
                  curve: Curves.easeOut)));
  // The flavor line follows the buttons with a whisper of motion; the
  // vignette arrives last, rising the way the scene "lands".
  late final Animation<double> _flavorFade = Tween(begin: 0.0, end: 1.0)
      .animate(CurvedAnimation(
          parent: _entrance,
          curve: Interval(_at(_flavorStartMs), _at(_flavorStartMs + _flavorMs),
              curve: Curves.easeOut)));
  late final Animation<Offset> _flavorRise =
      Tween(begin: const Offset(0, 0.03), end: Offset.zero).animate(
          CurvedAnimation(
              parent: _entrance,
              curve: Interval(
                  _at(_flavorStartMs), _at(_flavorStartMs + _flavorMs),
                  curve: Curves.easeOut)));
  late final Animation<double> _vignetteFade = Tween(begin: 0.0, end: 1.0)
      .animate(CurvedAnimation(
          parent: _entrance,
          curve: Interval(
              _at(_vignetteStartMs), _at(_vignetteStartMs + _vignetteMs),
              curve: Curves.easeOut)));
  late final Animation<Offset> _vignetteRise =
      Tween(begin: const Offset(0, 0.15), end: Offset.zero).animate(
          CurvedAnimation(
              parent: _entrance,
              curve: Interval(
                  _at(_vignetteStartMs), _at(_vignetteStartMs + _vignetteMs),
                  curve: Curves.easeOut)));

  bool _entranceStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entranceStarted) return;
    _entranceStarted = true;
    // Respect the platform's reduced-motion request: rest at the final
    // layout (value 1) instead of animating — skipping forward() alone
    // would freeze the block at its transparent first frame.
    if (widget.animateEntrance && !MediaQuery.of(context).disableAnimations) {
      _entrance.forward();
    } else {
      _entrance.value = 1;
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  late int _sceneIndex =
      (widget.debugSceneIndex ?? Random().nextInt(widget.scenes.length)) %
          widget.scenes.length;

  SplashScene get _scene => widget.scenes[_sceneIndex];

  /// The next scene index: pinned by [AppSplash.debugSceneIndex] when set,
  /// otherwise random but never the scene already showing (with more than
  /// one scene, a revisit always brings a change).
  int get _nextSceneIndex {
    if (widget.debugSceneIndex != null) {
      return widget.debugSceneIndex! % widget.scenes.length;
    }
    var next = Random().nextInt(widget.scenes.length);
    while (next == _sceneIndex && widget.scenes.length > 1) {
      next = Random().nextInt(widget.scenes.length);
    }
    return next;
  }

  /// A covered route (a pushed screen) hides this splash by flipping its
  /// [TickerMode] off; coming back flips it on. [_RevisitDetector] turns
  /// that flip into this callback: roll a fresh scene — the flavor line and
  /// foreground vignette cross-fade to it while title and buttons stay
  /// settled, so a repeat visit reads as a new beat, not a replay.
  void _onRevisit() {
    if (widget.scenes.length < 2) return;
    setState(() => _sceneIndex = _nextSceneIndex);
  }

  /// Cross-fade span for scene swaps (instant under reduced motion).
  Duration get _swapDuration => MediaQuery.of(context).disableAnimations
      ? Duration.zero
      : const Duration(milliseconds: 450);

  String get _welcome {
    // The greeting reads the shared account state: signed-in players get
    // the welcome-back form, anonymous ones the introduction. An explicit
    // [AppSplash.welcomeName] overrides the display name only.
    final strings = appLocale.strings;
    final signedIn = account.isCloudSignedIn || account.value != null;
    final name =
        widget.welcomeName ?? account.value?.displayName ?? account.playerName;
    if (!signedIn) return strings.welcome(name, widget.appName);
    return strings.welcomeBack(name, widget.appName);
  }  /// The Continue button's caption: the host's override wins; otherwise
  /// the localized CONTINUE, or the NO SAVED GAMES caption while the
  /// button is disabled.
  String get _continueCaption {
    if (widget.continueLabel != null) return widget.continueLabel!;
    final strings = appLocale.strings;
    return widget.continueEnabled ? strings.continueDefault : strings.noSavedGames;
  }

  /// The PLAY button's caption (direct-entry variants): the host's
  /// override wins, otherwise the localized default.
  String get _directCaption =>
      widget.directLabel ?? appLocale.strings.directEntry;

  @override
  Widget build(BuildContext context) {
    return _RevisitDetector(
      onReturn: _onRevisit,
      child: Scaffold(
        body: Stack(fit: StackFit.expand, children: [
          if (widget.background != null)
            SvgPicture.asset(
              widget.background!,
              fit: BoxFit.cover,
              key: const ValueKey('splash-bg'),
            ),
          // This visit's foreground vignette, pinned to the valley floor —
          // the flavor line's scene acted out over the shared backdrop. It
          // is the entrance's last arrival, rising into place — and on a
          // revisit it cross-fades to the newly rolled scene.
          if (_scene.vignette != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: _Entrance(
                fade: _vignetteFade,
                rise: _vignetteRise,
                fadeKey: const ValueKey('entrance-vignette-fade'),
                child: AnimatedSwitcher(
                  duration: _swapDuration,
                  key: const ValueKey('splash-vignette-swap'),
                  child: Semantics(
                    key: ValueKey('splash-scene-$_sceneIndex'),
                    label: _scene.story,
                    child: SizedBox(
                      height: 150,
                      width: double.infinity,
                      child: SvgPicture.asset(
                        _scene.vignette!,
                        fit: BoxFit.contain,
                        key: const ValueKey('splash-vignette'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          SafeArea(
            child: Column(children: [
              AppTopBar(settingsBuilder: widget.settingsBuilder),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Spacer(),
                            // The entrance: title + welcome fade and rise as one
                            // block; the buttons stagger in below; the flavor
                            // line follows the buttons on its own late beat.
                            SlideTransition(
                              position: _titleRise,
                              child: FadeTransition(
                                opacity: _titleFade,
                                child: Column(children: [
                                  Text(widget.appName.toUpperCase(),
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineMedium
                                          ?.copyWith(
                                              fontWeight: FontWeight.bold,
                                              letterSpacing: 3,
                                              color: Colors.white)),
                                  const SizedBox(height: 8),
                                  Text(_welcome,
                                      key: const ValueKey('welcome-message'),
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(color: Colors.white70),
                                      textAlign: TextAlign.center),
                                  const SizedBox(height: 6),
                                  _Entrance(
                                    fade: _flavorFade,
                                    rise: _flavorRise,
                                    fadeKey:
                                        const ValueKey('entrance-flavor-fade'),
                                    child: AnimatedSwitcher(
                                      duration: _swapDuration,
                                      key: const ValueKey('splash-flavor'),
                                      child: Text(_scene.line,
                                          key: ValueKey(
                                              'splash-scene-$_sceneIndex'),
                                          style: TextStyle(
                                              color: Colors.amber.shade200,
                                              fontStyle: FontStyle.italic),
                                          textAlign: TextAlign.center),
                                    ),
                                  ),
                                ]),
                              ),
                            ),
                            const SizedBox(height: 40),
                            // The buttons stagger in after the title: the
                            // first one leads, the rest follow _staggerMs
                            // apart. The direct variants put PLAY in front
                            // (entering the app is the everyday path); the
                            // classic variants lead with NEW GAME.
                            Column(children: [
                              if (widget.actions == SplashActions.direct ||
                                  widget.actions ==
                                      SplashActions.directAndNewGame) ...[
                                _Entrance(
                                  fade: _newGameFade,
                                  rise: _newGameRise,
                                  child: SizedBox(
                                    width: double.infinity,
                                    child: FilledButton.icon(
                                      key: const ValueKey('splash-direct'),
                                      onPressed: widget.onDirect,
                                      icon: const Icon(Icons.play_arrow),
                                      label: Padding(
                                          padding: const EdgeInsets.all(14),
                                          child: Text(_directCaption)),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                              ],
                              if (widget.onNewGame != null &&
                                  widget.actions != SplashActions.direct) ...[
                                _Entrance(
                                  fade: _newGameFade,
                                  rise: _newGameRise,
                                  child: SizedBox(
                                    width: double.infinity,
                                    child: FilledButton.icon(
                                      key: const ValueKey('splash-new-game'),
                                      onPressed: widget.onNewGame,
                                      icon:
                                          const Icon(Icons.add_circle_outline),
                                      label: Padding(
                                          padding: const EdgeInsets.all(14),
                                          child: Text(widget.startLabel ??
                                              appLocale.strings.newGame)),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                              ],
                              if (widget.actions == SplashActions.both)
                                _Entrance(
                                  fade: _continueFade,
                                  rise: _continueRise,
                                  child: SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton.icon(
                                      key: const ValueKey('splash-continue'),
                                      onPressed: widget.continueEnabled
                                          ? widget.onContinue
                                          : null,
                                      icon: const Icon(Icons.play_arrow),
                                      label: Padding(
                                        padding: const EdgeInsets.all(14),
                                        child: Text(_continueCaption),
                                      ),
                                    ),
                                  ),
                                ),
                            ]),
                            const Spacer(),
                            Text(widget.description,
                                style: TextStyle(color: Colors.grey.shade400),
                                textAlign: TextAlign.center),
                          ]),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// One staggered arrival: a fade paired with a small rise, driven by the
/// splash's shared entrance controller. [fadeKey] names the fade for tests
/// (keys are API) — it must not collide with content keys.
class _Entrance extends StatelessWidget {
  const _Entrance({
    required this.fade,
    required this.rise,
    required this.child,
    this.fadeKey,
  });

  final Animation<double> fade;
  final Animation<Offset> rise;
  final Widget child;
  final Key? fadeKey;

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: rise,
      child: FadeTransition(opacity: fade, key: fadeKey, child: child),
    );
  }
}

/// Fires [onReturn] when the splash comes back from a covered route.
///
/// When a screen is pushed over a route, the router flips the covered
/// route's [TickerMode] off (and back on after pop). Depending on that
/// inherited flag gives a precise, framework-driven revisit signal: an
/// off→on transition means "we were hidden and now we are visible again".
class _RevisitDetector extends StatefulWidget {
  const _RevisitDetector({required this.onReturn, required this.child});

  final VoidCallback onReturn;
  final Widget child;

  @override
  State<_RevisitDetector> createState() => _RevisitDetectorState();
}

class _RevisitDetectorState extends State<_RevisitDetector> {
  bool? _wasEnabled;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = TickerMode.valuesOf(context).enabled;
    final was = _wasEnabled;
    _wasEnabled = enabled;
    // First build only records; a false→true flip is the revisit. The
    // callback arrives mid-rebuild (the pop that uncovered us IS the
    // rebuild), so the scene swap is deferred to after the frame —
    // setState during build would throw.
    if (was == false && enabled) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onReturn();
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
