import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_settings.dart';
import '../high_contrast_toggle_button.dart';

/// One node of the lobby wizard's progress rail.
class LobbyStepDescriptor {
  const LobbyStepDescriptor(
      {required this.title, required this.icon, this.subtitle, this.summary});

  final String title;
  final IconData icon;

  /// One-line hint shown under the step header. Null keeps the header
  /// tighter — the rail and navigation are unaffected.
  final String? subtitle;

  /// The choice this step currently holds, in a few words — 'Elf', 'Solo',
  /// 'Medium · 48291'. The rail prints it as a second, quieter line under the
  /// step's name, so the whole setup reads from the progress bar itself; where
  /// the names drop away (a narrow phone, very large text) the same string
  /// becomes a tappable chip instead. Null leaves the step's label alone.
  ///
  /// Tapping the value is a deeper shortcut than tapping the step's name: see
  /// [LobbyWizard.onRevealControl].
  ///
  /// Keep it short: a rail node is 48–96dp wide, so anything past a couple of
  /// words is ellipsized there (the chip fallback shows it in full).
  final String? summary;
}

/// The new-game wizard's scaffolding: a horizontal progress rail (done steps
/// marked with a check, the current one highlighted, all tappable), the
/// "Step X of Y — Title" header with its subtitle, and Back/Continue
/// navigation. The host app supplies the step descriptors and the body of
/// the current step — every kjhrono game gets the same road.
///
/// The rail adapts to the screen it gets: step names sit under their nodes
/// where there is room, and drop away on a phone (or with very large text)
/// so every node keeps a finger-sized target instead of a clipped label. The
/// header always names the current step, and each node carries a full
/// screen-reader label either way — see [_ProgressRail].
///
/// A node's *name* opens its step; the *value* under it opens the control that
/// value came from, through [onRevealControl]. A host that does not implement
/// that seam keeps the old behaviour: the value tap just opens the step.
class LobbyWizard extends StatefulWidget {
  const LobbyWizard({
    super.key,
    required this.steps,
    required this.current,
    required this.onGoto,
    required this.body,
    this.title,
    this.appBarActions,
    this.canContinue,
    this.banner,
    this.onDone,
    this.doneLabel,
    this.onRevealControl,
  })  : assert(steps.length > 0),
        assert(current >= 0 && current < steps.length),
        assert(
            onDone == null || doneLabel != null, 'a done action needs a label');

  final List<LobbyStepDescriptor> steps;
  final int current;
  final ValueChanged<int> onGoto;
  final List<Widget> body;

  /// The bar's heading. Null uses the shell's own "NEW GAME", translated
  /// with the rest of the chrome — a host that names the road ("NEW
  /// CAMPAIGN") still overrides it.
  final String? title;

  /// Host app's top-bar actions (theme toggle, settings gear) shown beside
  /// the wizard's title, after the contrast toggle the wizard supplies.
  ///
  /// The contrast toggle is already in the bar by default — setup is often
  /// the first thing a low-vision player meets, and it must be readable
  /// before they know where Settings is. A host that places its own
  /// [HighContrastToggleButton] among these actions keeps just that one, so
  /// the control never appears twice.
  final List<Widget>? appBarActions;

  /// Per-step gate on the Continue button: given the current step index,
  /// return false to disable it (e.g. the avatar needs a name before the
  /// player may move on). The host owns the message — surface the reason in
  /// the step body; a disabled button alone says "not yet". The rail stays
  /// free navigation by design: the gate steers the primary path, it does
  /// not lock the map. Null keeps every step's Continue enabled.
  ///
  /// The gate is also the rail's completion source, and it is asked about
  /// every step, not just the one on screen: a step behind the player wears
  /// its check — and lights the rule leading into the next step — only when
  /// this answers true for it. Jumping ahead over a step whose gate was still
  /// closed therefore leaves that node marked as unfinished rather than
  /// claiming a gate the host never opened. Answer for any index (the answer
  /// should depend on that step's own state, not on which step is current).
  ///
  /// Null keeps every step's Continue enabled, and leaves the rail with the
  /// only evidence it has on its own: a step behind the player is checked
  /// when the player actually visited it. A rail jump over a step therefore
  /// does not tick it, even though no gate will ever object.
  final bool Function(int stepIndex)? canContinue;

  /// A persistent notice rendered above the rail on EVERY step — a pending
  /// handover, a maintenance note — so the message survives step changes
  /// while the step bodies come and go. Null renders nothing.
  final Widget? banner;

  /// The step's destination when it is not the next step — a section opened
  /// from a review screen, which returns there. When set it replaces Continue
  /// on every step (Back stays), still obeys [canContinue], and stands alone
  /// on the last step. Null keeps the usual walk forward.
  final VoidCallback? onDone;

  /// The label on [onDone]'s button ('BACK TO REVIEW', 'SAVE CHANGES'). The
  /// shell cannot name a destination it does not know, so the host supplies
  /// the words — and they get translated with the rest of the host's text.
  final String? doneLabel;

  /// Called when the player taps a step's chosen value — the quiet line under
  /// the step's name, or its chip on an icon-only rail — rather than the name
  /// itself: a request to open the control that value came from, not just the
  /// step that owns it. The wizard has already moved to the step and laid its
  /// body out when this runs, so the host can scroll its own anchor widget
  /// into view and hand it focus. Focus alone only shows where the platform
  /// reports keyboard highlighting, so a host should also flash a
  /// [RevealHighlight] on that control — on touch, the ring is the only cue
  /// the jump happened. Null leaves the value tap as plain navigation, which is
  /// what every host did before this seam existed.
  final ValueChanged<int>? onRevealControl;

  @override
  State<LobbyWizard> createState() => _LobbyWizardState();
}

class _LobbyWizardState extends State<LobbyWizard> {
  /// The step whose control the player asked for, while the wizard waits for
  /// that step's body to be built and scrolled to its top. The body resets its
  /// own offset as it lays out, so the reveal has to wait for that frame's end
  /// rather than racing it from the tap handler.
  int? _pendingReveal;

  /// The steps the player has actually stood on. Only consulted when the host
  /// supplies no [LobbyWizard.canContinue]: without a gate, a visit is the one
  /// piece of progress the wizard can vouch for itself. A rail jump over a
  /// step leaves it out, so the rail cannot claim an answer nobody gave.
  final Set<int> _visited = <int>{};

  @override
  void initState() {
    super.initState();
    _visited.add(widget.current);
  }

  /// The rail's value was tapped: open its step, then reveal its control.
  /// Tapping the value of the step already on screen needs no navigation —
  /// its body is laid out and in place, so the host is told right away.
  /// (Waiting for a post-frame callback here would stall: a value tap does
  /// not dirty the tree, so there may be no frame to call back from.)
  void _openControl(int index) {
    if (index == widget.current) {
      _pendingReveal = null;
      widget.onRevealControl?.call(index);
      return;
    }
    _pendingReveal = index;
    widget.onGoto(index);
  }

  @override
  void didUpdateWidget(covariant LobbyWizard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Standing on a step is what counts as visiting it; rebuilding with the
    // same index simply records the same step again.
    _visited.add(widget.current);
    // A host may refuse the move (its own gate) or go somewhere else; a
    // reveal must not fire on some later, unrelated visit to that step.
    if (_pendingReveal != null && widget.current != _pendingReveal) {
      _pendingReveal = null;
    }
  }

  /// The step body has laid out: its scroll is back at the top, so a pending
  /// reveal can now scroll to its control without being undone.
  void _afterStepLaidOut() {
    final target = _pendingReveal;
    if (target == null || target != widget.current) return;
    _pendingReveal = null;
    widget.onRevealControl?.call(target);
  }

  /// Whether step [i] is behind the player AND cleared.
  ///
  /// Being earlier than the current step is not the same as being done: the
  /// rail is free navigation, so a player can jump over a step whose Continue
  /// is still disabled. Its check and the rule leading out of it come from
  /// the gate, not from the index, or the rail would announce progress the
  /// host never granted. With no gate to ask, the rail falls back to the one
  /// fact it knows: whether the player has been on that step. A jump over an
  /// unvisited step therefore leaves it open instead of assuming it was
  /// answered.
  bool _isStepDone(int i) {
    if (i >= widget.current) return false;
    final gate = widget.canContinue;
    if (gate != null) return gate(i);
    return _visited.contains(i);
  }

  /// Whether the host already put a contrast toggle in [LobbyWizard.appBarActions]
  /// — a duplicate glyph would read as two different controls.
  bool get _hostSuppliesContrastToggle =>
      widget.appBarActions
          ?.any((action) => action is HighContrastToggleButton) ??
      false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? appLocale.strings.newGame),
        centerTitle: true,
        actions: [
          // Readable setup is not an opt-in: the toggle rides the wizard's own
          // bar so a player can flip contrast without leaving the flow. The
          // rail repaints by itself (it listens to [appContrast]); the shell
          // root repaints the rest of the app.
          if (!_hostSuppliesContrastToggle) const HighContrastToggleButton(),
          ...?widget.appBarActions,
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(children: [
            if (widget.banner != null) widget.banner!,
            _rail(context),
            Expanded(
              child: _StepBody(
                step: widget.current,
                onLaidOut: _afterStepLaidOut,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // A heading, announced again whenever the step changes:
                    // the visual rail moves, but only a live region tells a
                    // screen-reader user that the whole body was replaced.
                    Semantics(
                      header: true,
                      liveRegion: true,
                      child: Text(
                          appLocale.strings.stepHeader(
                              widget.current + 1,
                              widget.steps.length,
                              widget.steps[widget.current].title),
                          style: const TextStyle(
                              fontSize: 28, fontWeight: FontWeight.bold)),
                    ),
                    if (widget.steps[widget.current].subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(widget.steps[widget.current].subtitle!,
                          // The theme's secondary ink: a fixed grey washes out
                          // on a light surface (and is the sort of hardcoded
                          // colour the light-mode pass keeps digging out).
                          style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                    ],
                    const SizedBox(height: 20),
                    ...widget.body,
                    const SizedBox(height: 24),
                    _nav(),
                  ],
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _rail(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: _ProgressRail(
          steps: widget.steps,
          current: widget.current,
          onGoto: widget.onGoto,
          onValueTap: _openControl,
          isStepDone: _isStepDone,
        ),
      );

  Widget _nav() {
    // The host's gate decides whether this step is complete; without a
    // gate every step may continue.
    final mayContinue = widget.canContinue?.call(widget.current) ?? true;
    final hasBack = widget.current > 0;
    // A done action owns the primary slot: an edit visit ends at the recap
    // it came from, never at the next setup step.
    final hasDone = widget.onDone != null;
    final hasContinue = !hasDone && widget.current < widget.steps.length - 1;
    final hasPrimary = hasDone || hasContinue;

    final back = hasBack
        ? OutlinedButton.icon(
            onPressed: () => widget.onGoto(widget.current - 1),
            icon: const Icon(Icons.chevron_left),
            label: Text(appLocale.strings.back),
          )
        : null;
    final primary = hasDone
        ? FilledButton.icon(
            key: const ValueKey('wizard-done'),
            onPressed: mayContinue ? widget.onDone : null,
            icon: const Icon(Icons.check),
            label: Text(widget.doneLabel!),
          )
        : hasContinue
            ? FilledButton.icon(
                onPressed: mayContinue
                    ? () => widget.onGoto(widget.current + 1)
                    : null,
                icon: const Icon(Icons.chevron_right),
                label: Text(appLocale.strings.continueLabel),
              )
            : null;

    return LayoutBuilder(builder: (context, constraints) {
      // Two intrinsic buttons need ~318dp at 1× text (Back + Continue is
      // ~313dp), and nearly all of that is label text — so the reader's text
      // size moves the width at which the pair can still share a line. Below
      // it both actions take the whole line instead: stretching them makes
      // the primary easy to hit, and keeps large text from leaving Back on
      // one ragged line and the primary left-aligned on the next. A lone
      // action only stretches on a genuinely tiny screen; scaling its
      // threshold would balloon a single button across a wide tablet.
      final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final stackBelow = hasBack && hasPrimary ? 318.0 * textScale : 318.0;
      if (constraints.maxWidth < stackBelow) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (back != null) back,
            if (back != null && primary != null) const SizedBox(height: 8),
            if (primary != null) primary,
          ],
        );
      }

      // Wide enough for a row: Back left and the primary action right where
      // both fit; a step with only one button keeps it on the edge it always
      // had. A Wrap still catches the cases that outgrow the row (a long
      // translated done label that is wider than the step even at 1×) by
      // putting them on separate lines rather than clipping.
      final alignment = hasBack && hasPrimary
          ? WrapAlignment.spaceBetween
          : hasPrimary
              ? WrapAlignment.end
              : WrapAlignment.start;
      return SizedBox(
        width: double.infinity,
        child: Wrap(
          alignment: alignment,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            if (back != null) back,
            if (primary != null) primary,
          ],
        ),
      );
    });
  }
}

/// The scrolling area of the current step.
///
/// It exists for one reason: the offset belongs to the step that set it. A
/// shared scroll view kept the previous step's position, so jumping to a
/// shorter step landed mid-form — sometimes with the header already scrolled
/// away. Keying the view by step would reset the offset too, but it would
/// also remount the host's widgets (and their focus and text state) on every
/// step change; resetting the controller keeps that state.
class _StepBody extends StatefulWidget {
  const _StepBody({required this.step, required this.child, this.onLaidOut});

  final int step;
  final Widget child;

  /// Called at the end of the frame in which a new step was built, after its
  /// scroll has been reset to the top. The wizard listens for this to reveal
  /// the control a rail value pointed at, once the host's widgets exist.
  final VoidCallback? onLaidOut;

  @override
  State<_StepBody> createState() => _StepBodyState();
}

class _StepBodyState extends State<_StepBody> {
  final _controller = ScrollController();

  @override
  void didUpdateWidget(covariant _StepBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.step == widget.step) return;
    // A new step opens on its header, never halfway down the last one.
    // Deferred past the build: jumping here dispatches a scroll notification
    // mid-build, and the AppBar listens for those (setState during build).
    // The next frame paints at the top, so nothing flickers.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The reset comes first: a host asked to reveal a control scrolls to it,
      // and must not be yanked back to the top right afterwards.
      if (_controller.hasClients) _controller.jumpTo(0);
      widget.onLaidOut?.call();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        // SingleChildScrollView (not ListView): every step's controls stay
        // built so screen-reader labels, tests and finders see the whole step
        // even when it scrolls.
        key: const ValueKey('wizard-body'),
        controller: _controller,
        padding: const EdgeInsets.all(24),
        child: widget.child,
      );
}

/// The wizard's progress rail: one tappable node per step, joined by a track,
/// the current step highlighted and earlier ones checked.
///
/// It adapts to the space it is given. Where a node is wide enough for a
/// legible label (and the player has not scaled text past that), each node
/// names its step; on a very narrow phone the labels drop away and the width
/// goes into finger-sized targets instead — the header above the body still
/// names the step, and every node keeps its tooltip and screen-reader label.
/// A rail that cannot fit even the bare nodes scrolls horizontally and keeps
/// the active node in view.
///
/// It is also the wizard's keyboard and D-pad control: Tab lands on the nodes,
/// the arrow keys (which is what an Android D-pad and a TV remote send) walk
/// one step at a time and take focus with them, Home and End jump to either
/// end, and Enter or a remote's select activates the focused step. Nothing
/// here needs a pointer.
///
/// Values are a pointer shortcut on a labelled rail: the node's screen-reader
/// sentence already carries the value, so the line under it stays out of the
/// semantics tree rather than being announced twice. On an icon-only rail the
/// value is the chip, which is a button in its own right — there it also
/// carries the deeper action (open the step's control) for assistive tools.
/// On a phone too narrow to hold that whole line (below 360dp) it keeps the
/// two values in reach — the step in hand and the next one — and counts the
/// rest in a pill; the values it leaves out stay in the node sentences, so a
/// screen reader still hears all of them.
class _ProgressRail extends StatefulWidget {
  const _ProgressRail({
    required this.steps,
    required this.current,
    required this.onGoto,
    required this.onValueTap,
    required this.isStepDone,
  });

  final List<LobbyStepDescriptor> steps;
  final int current;
  final ValueChanged<int> onGoto;

  /// Whether a step has been cleared: behind the player and past its gate —
  /// or, with no gate supplied, one the player has actually visited. Index
  /// alone cannot answer it: the rail lets a player jump ahead over a step
  /// whose Continue is still disabled (see [LobbyWizard.canContinue]).
  final bool Function(int) isStepDone;

  /// A step's value was tapped: open that step and its control (rather than
  /// just the step, which is what the name and the node still do).
  final ValueChanged<int> onValueTap;

  @override
  State<_ProgressRail> createState() => _ProgressRailState();
}

class _ProgressRailState extends State<_ProgressRail> {
  /// Gap between two nodes; narrow, because the node targets carry the rail
  /// and a 320dp phone must still fit six of them without scrolling.
  static const _connectorWidth = 6.0;

  /// A node narrower than this cannot hold a legible [_labelSize] step name,
  /// so the rail drops the labels and spends the width on the targets.
  static const _labelNodeWidth = 48.0;

  static const _labelSize = 11.0;

  /// The chosen value's line under the step name — smaller and quieter than
  /// the name, one line only, so the rail gains a line rather than a crowd.
  static const _summarySize = 10.0;

  /// Flutter's minimum comfortable target; the rail never gets thinner than
  /// this, scrolling instead on genuinely tiny screens.
  static const _minNodeWidth = 44.0;
  static const _maxNodeWidth = 96.0;
  static const _minTargetHeight = 48.0;

  static const _nodePadding = 4.0;
  static const _dotSize = 34.0;

  /// The keyboard focus ring sits outside the disc, in the gap the node's own
  /// padding leaves, so it never covers the current step's fill: focus and
  /// "you are here" can be different nodes and both must read at a glance.
  static const _focusRingGap = 4.0;
  static const _focusRingWidth = 2.0;

  /// Past ~1.4× the labels compete with the nodes for the same pixels, so the
  /// rail goes icon-only rather than clipping a two-line smear.
  static const _maxLabelScale = 1.4;

  /// Below this width the value chips stop being a line and become a scroller
  /// of near-identical pills — a 320dp phone holds two of them beside the
  /// count. 360dp and up keeps the whole line.
  static const _collapseChipsBelow = 360.0;

  late List<GlobalKey> _nodeKeys = _freshKeys();
  late List<FocusNode> _focusNodes = _freshFocusNodes();

  List<GlobalKey> _freshKeys() =>
      List<GlobalKey>.generate(widget.steps.length, (_) => GlobalKey());

  List<FocusNode> _freshFocusNodes() => List<FocusNode>.generate(
      widget.steps.length, (i) => FocusNode(debugLabel: 'wizard rail node $i'));

  @override
  void initState() {
    super.initState();
    _watchFocus();
    _revealCurrent(jump: true);
  }

  /// The ring is painted from the node's own focus state, so the rail has to
  /// repaint when focus moves — a keyboard user can be standing on a step the
  /// wizard has not navigated to yet.
  void _watchFocus() {
    for (final node in _focusNodes) {
      node.addListener(_onFocusChanged);
    }
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  void _releaseFocusNodes(List<FocusNode> nodes) {
    for (final node in nodes) {
      node.removeListener(_onFocusChanged);
      node.dispose();
    }
  }

  @override
  void didUpdateWidget(covariant _ProgressRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.steps.length != widget.steps.length) {
      _nodeKeys = _freshKeys();
      _releaseFocusNodes(_focusNodes);
      _focusNodes = _freshFocusNodes();
      _watchFocus();
    }
    if (oldWidget.current != widget.current ||
        oldWidget.steps.length != widget.steps.length) {
      _revealCurrent(jump: false);
    }
  }

  @override
  void dispose() {
    _releaseFocusNodes(_focusNodes);
    super.dispose();
  }

  /// Arrow keys walk the rail one step at a time, carrying focus with them so
  /// the highlighted node is also the focused one. That is the whole keyboard
  /// and D-pad path: Android's D-pad and a TV remote arrive here as arrow
  /// keys, Tab still stops on every node, and Enter (or a remote's select)
  /// activates the focused step through the node's own InkWell. At either end
  /// the key is left unhandled, so an arrow can still leave the rail instead
  /// of being swallowed by it.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final last = widget.steps.length - 1;
    final target = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowRight ||
      LogicalKeyboardKey.arrowDown =>
        widget.current < last ? widget.current + 1 : null,
      LogicalKeyboardKey.arrowLeft ||
      LogicalKeyboardKey.arrowUp =>
        widget.current > 0 ? widget.current - 1 : null,
      LogicalKeyboardKey.home => widget.current == 0 ? null : 0,
      LogicalKeyboardKey.end => widget.current == last ? null : last,
      _ => null,
    };
    if (target == null) return KeyEventResult.ignored;
    // Focus first: the node already exists at that index, and the host's
    // onGoto may rebuild or even gate the step, but the keyboard should still
    // be standing where the player pointed it.
    _focusNodes[target].requestFocus();
    widget.onGoto(target);
    return KeyEventResult.handled;
  }

  /// Bring the active node on screen — after the frame, when the rail has
  /// been laid out. A rail that fits needs no scrolling and does nothing.
  void _revealCurrent({required bool jump}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final nodeContext = _nodeKeys[widget.current].currentContext;
      if (nodeContext == null) return;
      final scrollable = Scrollable.maybeOf(nodeContext);
      if (scrollable == null || !scrollable.position.hasContentDimensions) {
        return;
      }
      if (scrollable.position.maxScrollExtent <= 0) return;
      Scrollable.ensureVisible(
        nodeContext,
        alignment: 0.5,
        duration: jump ? Duration.zero : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.steps.length;
    final connectors = _connectorWidth * (count - 1);
    final textScaler = MediaQuery.textScalerOf(context);
    final hasSummaries = widget.steps.any((step) {
      final summary = step.summary;
      return summary != null && summary.isNotEmpty;
    });
    // The contrast toggle can live anywhere (the setup app bar); the rail
    // listens to it itself, so its shape cues repaint even when the host does
    // not rebuild on the flip.
    return ListenableBuilder(
      listenable: appContrast,
      builder: (context, _) => LayoutBuilder(builder: (context, constraints) {
        final perNode = (constraints.maxWidth - connectors) / count;
        // Compare the scaled *label* size, not the raw factor: a non-linear
        // scaler can leave small text alone and blow up headings.
        final showLabels = perNode >= _labelNodeWidth &&
            textScaler.scale(_labelSize) <= _labelSize * _maxLabelScale;
        final nodeWidth = perNode
            .clamp(showLabels ? _labelNodeWidth : _minNodeWidth, _maxNodeWidth)
            .toDouble();
        final railWidth = nodeWidth * count + connectors;
        // Centre the rail when it does not need the whole width (a tablet
        // would otherwise leave it hugging the left edge).
        final contentWidth =
            railWidth < constraints.maxWidth ? constraints.maxWidth : railWidth;
        // A non-focusable Focus only listens: it never adds a stop to the Tab
        // order, it just gets the arrow keys that bubble up from whichever rail
        // node (or value chip) the player is on.
        return Focus(
          canRequestFocus: false,
          onKeyEvent: _onKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: contentWidth,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < count; i++) ...[
                        if (i > 0) _connector(i),
                        _node(i, nodeWidth,
                            showLabels: showLabels, hasSummaries: hasSummaries),
                      ],
                    ],
                  ),
                ),
              ),
              // The values ride the labels wherever the labels fit. Only when
              // they have dropped away (a narrow phone, very large text) does
              // the chip line take over — the same facts never appear twice.
              if (!showLabels && hasSummaries) _summaryRow(context),
            ],
          ),
        );
      }),
    );
  }

  /// The steps that carry a chosen value, in rail order.
  List<int> get _valuedSteps => [
        for (var i = 0; i < widget.steps.length; i++)
          if (widget.steps[i].summary?.isNotEmpty ?? false) i,
      ];

  /// The chosen values as one compact line under the rail, used only when the
  /// rail is icon-only. It scrolls sideways rather than wrapping: a second
  /// row would push the step header down on exactly the phones that can least
  /// afford it — and on a very narrow phone it stops being a line at all,
  /// keeping two values and a count (see [_leadingChipSteps]). The count opens
  /// [_showAllValues], so the values it stands for stay one tap away.
  Widget _summaryRow(BuildContext context) {
    // The screen, not the rail's padded inner width: a 360dp phone keeps the
    // whole line even though its rail measures 336.
    final screenWidth = MediaQuery.sizeOf(context).width;
    final valued = _valuedSteps;
    if (valued.isEmpty) return const SizedBox.shrink();
    // On a very narrow rail the line keeps the two values a player can act
    // on: where they are and where they are going. The rest are not lost —
    // every node's screen-reader sentence still carries its own value, and the
    // count pill opens the whole list for a pointer or a keyboard.
    final shown =
        screenWidth < _collapseChipsBelow ? _leadingChipSteps(valued) : valued;
    final hidden = valued.length - shown.length;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            for (final i in shown) _chip(context, i),
            if (hidden > 0) _hiddenChips(context, hidden),
          ],
        ),
      ),
    );
  }

  /// The two chips a narrow rail shows: the current step's value (or the next
  /// one that has a value, when this step has none) and the value after it —
  /// the choice in hand and the next decision on the road. In step order, so
  /// the line still reads left to right like the rail above it.
  List<int> _leadingChipSteps(List<int> valued) {
    if (valued.length <= 2) return valued;
    final atOrAfter = valued.where((i) => i >= widget.current);
    final primary = atOrAfter.isNotEmpty ? atOrAfter.first : valued.last;
    final secondary = valued[(valued.indexOf(primary) + 1) % valued.length];
    return [primary, secondary]..sort();
  }

  /// The count pill standing in for the chips the narrow line left out. It is
  /// a real control now: tapping it opens [_showAllValues], so a value hidden
  /// behind the count is never out of reach. Its own label names the action —
  /// the rail's nodes already announce each value, so repeating them here
  /// would be noise — and the count stays a visual cue, not a second reading.
  Widget _hiddenChips(BuildContext context, int hidden) {
    final scheme = Theme.of(context).colorScheme;
    void open() => _showAllValues();
    return Semantics(
      key: const ValueKey('wizard-summary-more'),
      button: true,
      label: appLocale.strings.showAllValues,
      excludeSemantics: true,
      onTap: open,
      child: Tooltip(
        message: appLocale.strings.showAllValues,
        excludeFromSemantics: true,
        child: Material(
          color: scheme.onSurface.withValues(alpha: 0.08),
          shape: StadiumBorder(
            side: BorderSide(
                color: appContrast.enabled
                    ? scheme.outline
                    : scheme.onSurface.withValues(alpha: 0.14),
                width: appContrast.enabled ? 2 : 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: open,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 34),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    '+$hidden',
                    style: TextStyle(
                      fontSize: _summarySize,
                      fontWeight: FontWeight.w600,
                      color: appContrast.enabled
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The compact list behind the count pill: every step that has a chosen
  /// value, in rail order, including the chips a very narrow line had to
  /// hide. A row does what its chip would have done — opens that step and
  /// reveals the control the value came from — so the hidden values stay
  /// reachable from the rail itself rather than through the review screen.
  ///
  /// It is a sheet, not a route: the rail and the step stay behind it, and a
  /// dismiss changes nothing.
  Future<void> _showAllValues() async {
    final valued = _valuedSteps;
    if (valued.isEmpty) return;
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return ConstrainedBox(
          // Compact: the six values a setup has fit without covering the
          // wizard. A taller set scrolls inside the sheet instead.
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Semantics(
                  header: true,
                  child: Text(
                    appLocale.strings.chosenValues,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    for (final i in valued)
                      ListTile(
                        key: ValueKey('wizard-values-$i'),
                        dense: true,
                        leading: Icon(widget.steps[i].icon, size: 20),
                        title: Text(widget.steps[i].title),
                        subtitle: Text(widget.steps[i].summary!),
                        trailing: const Icon(Icons.chevron_right, size: 18),
                        onTap: () => Navigator.of(sheetContext).pop(i),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
    if (picked != null && mounted) widget.onValueTap(picked);
  }

  /// One step's value as a chip. The visible label is excluded from semantics:
  /// the wrapper names the value AND the step that owns it, so a screen reader
  /// hears "Elf — Avatar, button" instead of just "Elf".
  Widget _chip(BuildContext context, int index) {
    final scheme = Theme.of(context).colorScheme;
    final step = widget.steps[index];
    return Semantics(
      key: ValueKey('wizard-summary-$index'),
      button: true,
      label: '${step.summary} — ${step.title}',
      excludeSemantics: true,
      onTap: () => widget.onValueTap(index),
      child: Tooltip(
        message: appLocale.strings.editStep(step.title),
        excludeFromSemantics: true,
        child: Material(
          color: scheme.onSurface.withValues(alpha: 0.08),
          shape: StadiumBorder(
            side: BorderSide(
                color: appContrast.enabled
                    ? scheme.outline
                    : scheme.onSurface.withValues(alpha: 0.14),
                width: appContrast.enabled ? 2 : 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => widget.onValueTap(index),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 34),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(step.icon, size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text(
                    step.summary!,
                    style: TextStyle(
                      fontSize: _labelSize,
                      fontWeight: appContrast.enabled
                          ? FontWeight.w700
                          : FontWeight.w600,
                      color: appContrast.enabled
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _connector(int i) {
    final scheme = Theme.of(context).colorScheme;
    final contrast = appContrast.enabled;
    // The rule is lit by the step to its left: it reads "this much of the
    // road was actually cleared", so a gate that never passed keeps its
    // segment dim even when the player has walked past it.
    final done = widget.isStepDone(i - 1);
    return SizedBox(
      key: ValueKey('wizard-rail-connector-$i'),
      width: _connectorWidth,
      child: Padding(
        padding: const EdgeInsets.only(top: _nodePadding + _dotSize / 2 - 1),
        child: Container(
          // Contrast thickens the rule instead of tinting it: the order of the
          // steps still reads when the hues do not.
          height: contrast ? 4 : 2,
          color: done
              ? (contrast
                  ? scheme.onSurface
                  : scheme.primary.withValues(alpha: 0.5))
              : (contrast
                  ? scheme.outlineVariant
                  : scheme.onSurface.withValues(alpha: 0.12)),
        ),
      ),
    );
  }

  /// One step's node. The visible circle and label are excluded from
  /// semantics: the wrapper speaks the whole state in one sentence ("Step 2
  /// of 6 — Start, button, selected") instead of reading a lone glyph and a
  /// second copy of the title.
  Widget _node(int i, double width,
      {required bool showLabels, required bool hasSummaries}) {
    final step = widget.steps[i];
    final isCurrent = i == widget.current;
    final isDone = widget.isStepDone(i);
    // Focus is the keyboard's cursor, which is not the same thing as "the
    // step you are on": Tab and the arrow keys can leave it on a node the
    // wizard has not navigated to, and the ring has to say so on its own.
    final hasFocus = _focusNodes[i].hasFocus;
    final scheme = Theme.of(context).colorScheme;
    final summary = step.summary;
    final textScaler = MediaQuery.textScalerOf(context);
    final contrast = appContrast.enabled;
    // Contrast mode inverts the current disc instead of tinting it, rings
    // every disc, and numbers them: the current step still reads as current
    // on a screen that shows no hues at all.
    final dotColor = contrast
        ? (isCurrent ? scheme.onSurface : scheme.surface)
        : isCurrent
            ? scheme.primary
            // Completed: a tinted disc still reads as done in both themes.
            : isDone
                ? scheme.primary.withValues(alpha: 0.3)
                // Waiting: a quiet surface step, never an invisible one.
                : scheme.onSurface.withValues(alpha: 0.1);
    final inkColor = contrast
        ? (isCurrent ? scheme.surface : scheme.onSurface)
        : isCurrent
            ? scheme.onPrimary
            : isDone
                ? scheme.onSurface
                : scheme.onSurfaceVariant;
    return Semantics(
      key: ValueKey('wizard-rail-node-$i'),
      container: true,
      button: true,
      selected: isCurrent,
      // The value is part of the sentence a screen reader gets, not a second
      // node: "Step 4 of 6 — Game options, Sandbox".
      label:
          appLocale.strings.stepHeader(i + 1, widget.steps.length, step.title) +
              ((summary == null || summary.isEmpty) ? '' : ', $summary'),
      // One sentence per node: the icon and the visible label below are the
      // same information drawn twice, so they are not announced again.
      excludeSemantics: true,
      onTap: () => widget.onGoto(i),
      child: Tooltip(
        message: step.title,
        excludeFromSemantics: true,
        child: InkWell(
          focusNode: _focusNodes[i],
          onTap: () => widget.onGoto(i),
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _minTargetHeight),
            child: SizedBox(
              key: _nodeKeys[i],
              width: width,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 2, vertical: _nodePadding),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The disc keeps its exact size and place; the focus ring
                    // is painted outside it in the node's own padding, so the
                    // connector, the label and the tap target never shift
                    // when a keyboard user tabs through the rail.
                    SizedBox(
                      width: _dotSize,
                      height: _dotSize,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned.fill(
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: dotColor,
                                border: contrast
                                    ? Border.all(
                                        color: isCurrent
                                            ? scheme.onSurface
                                            : scheme.outline,
                                        width: isCurrent ? 3 : 2)
                                    : null,
                              ),
                              // A done step keeps its check either way; the rest
                              // show their order number in contrast instead of
                              // an icon.
                              child: isDone
                                  ? Icon(Icons.check, size: 18, color: inkColor)
                                  : contrast
                                      ? Text('${i + 1}',
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w800,
                                            height: 1,
                                            color: inkColor,
                                          ))
                                      : Icon(step.icon,
                                          size: 18, color: inkColor),
                            ),
                          ),
                          if (hasFocus)
                            Positioned(
                              left: -_focusRingGap,
                              top: -_focusRingGap,
                              width: _dotSize + _focusRingGap * 2,
                              height: _dotSize + _focusRingGap * 2,
                              child: CustomPaint(
                                key: ValueKey('wizard-rail-focus-ring-$i'),
                                painter: _FocusRingPainter(
                                  // Theme-aware, and deliberately not the
                                  // current step's `primary`: a dashed ring in
                                  // the scheme's tertiary reads as "keyboard
                                  // focus" even when it lands beside the
                                  // solid, filled disc of the current step.
                                  color: contrast
                                      ? scheme.onSurface
                                      : scheme.tertiary,
                                  width: _focusRingWidth,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (showLabels) ...[
                      const SizedBox(height: 4),
                      SizedBox(
                        // Always two lines tall, scaled with the player's text
                        // size: a one-word step and a two-word one keep the
                        // same node height, so the rail stays an even band
                        // instead of a ragged one.
                        height: textScaler.scale(_labelSize) * 1.15 * 2,
                        child: Center(
                          child: Text(
                            step.title,
                            key: ValueKey('wizard-step-label-$i'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: _labelSize,
                              height: 1.15,
                              fontWeight: isCurrent
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              // The current step is underlined in contrast
                              // mode: weight alone is a softer cue than a rule
                              // under the word.
                              decoration: contrast && isCurrent
                                  ? TextDecoration.underline
                                  : null,
                              decorationThickness: 2,
                              // Selected steps read at full contrast, the rest
                              // at the theme's secondary ink — legible without
                              // shouting over the active node.
                              color: contrast
                                  ? scheme.onSurface
                                  : isCurrent
                                      ? scheme.onSurface
                                      : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                      // The chosen value, one line at a smaller size. The slot
                      // is reserved for every node when any step has one, so
                      // the band stays even; a step without a value keeps the
                      // slot empty instead of lifting its name out of line.
                      if (hasSummaries)
                        SizedBox(
                          // The value is its own shortcut (onValueTap opens the
                          // control it came from), so the line gets a 24dp
                          // tap band — the WCAG minimum target — instead of
                          // the bare ~14dp the text would occupy. The slot is
                          // still reserved for every node, empty or not, so
                          // the rail stays one even band.
                          height: textScaler.scale(_summarySize) * 1.2 + 10,
                          width: double.infinity,
                          child: summary == null || summary.isEmpty
                              ? Center(
                                  child: Text('',
                                      key: ValueKey('wizard-step-summary-$i')))
                              : GestureDetector(
                                  // Opaque: the whole band is the target, and
                                  // the inner gesture wins the tap over the
                                  // node's own InkWell around it.
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => widget.onValueTap(i),
                                  child: Center(
                                    child: Text(
                                      summary,
                                      key: ValueKey('wizard-step-summary-$i'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: _summarySize,
                                        height: 1.2,
                                        fontWeight: contrast
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: contrast
                                            ? scheme.onSurface
                                            : scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The rail's keyboard focus ring: a dashed circle painted just outside a
/// step's disc.
///
/// The dash is the point. A solid ring would be the current step's own mark in
/// contrast mode (where the active disc is ringed at 3dp in full ink), so
/// focus would be indistinguishable from "you are here" whenever the two sat
/// on neighbouring nodes. Dashes, drawn in the scheme's own ink, survive a
/// theme that shows no hues at all.
class _FocusRingPainter extends CustomPainter {
  const _FocusRingPainter({required this.color, required this.width});

  final Color color;
  final double width;

  /// Length of one dash and of the gap after it. Chosen so the ring reads as
  /// eight or so clear marks at 34-42dp rather than a dotted blur.
  static const double _dash = 4.5;
  static const double _gap = 3.5;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    final circle = Path()..addOval((Offset.zero & size).deflate(width / 2));
    for (final metric in circle.computeMetrics()) {
      var along = 0.0;
      while (along < metric.length) {
        final end =
            along + _dash < metric.length ? along + _dash : metric.length;
        canvas.drawPath(metric.extractPath(along, end), paint);
        along = end + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FocusRingPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.width != width;
}
