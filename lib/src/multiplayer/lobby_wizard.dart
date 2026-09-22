import 'package:flutter/material.dart';

import '../app_settings.dart';

/// One node of the lobby wizard's progress rail.
class LobbyStepDescriptor {
  const LobbyStepDescriptor(
      {required this.title, required this.icon, this.subtitle});

  final String title;
  final IconData icon;

  /// One-line hint shown under the step header. Null keeps the header
  /// tighter — the rail and navigation are unaffected.
  final String? subtitle;
}

/// The new-game wizard's scaffolding: a horizontal progress rail (done steps
/// dimmed with a check, the current one highlighted, all tappable), the
/// "Step X of Y — Title" header with its subtitle, and Back/Continue
/// navigation. The host app supplies the step descriptors and the body of
/// the current step — every kjhrono game gets the same road.
class LobbyWizard extends StatelessWidget {
  const LobbyWizard({
    super.key,
    required this.steps,
    required this.current,
    required this.onGoto,
    required this.body,
    this.title = 'NEW GAME',
    this.appBarActions,
    this.canContinue,
    this.banner,
  })  : assert(steps.length > 0),
        assert(current >= 0 && current < steps.length);

  final List<LobbyStepDescriptor> steps;
  final int current;
  final ValueChanged<int> onGoto;
  final List<Widget> body;
  final String title;

  /// Host app's top-bar actions (theme toggle, settings gear) shown beside
  /// the wizard's title.
  final List<Widget>? appBarActions;

  /// Per-step gate on the Continue button: given the current step index,
  /// return false to disable it (e.g. the avatar needs a name before the
  /// player may move on). The host owns the message — surface the reason in
  /// the step body; a disabled button alone says "not yet". The rail stays
  /// free navigation by design: the gate steers the primary path, it does
  /// not lock the map. Null keeps every step's Continue enabled.
  final bool Function(int stepIndex)? canContinue;

  /// A persistent notice rendered above the rail on EVERY step — a pending
  /// handover, a maintenance note — so the message survives step changes
  /// while the step bodies come and go. Null renders nothing.
  final Widget? banner;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        centerTitle: true,
        actions: appBarActions,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(children: [
            if (banner != null) banner!,
            _rail(context),
            Expanded(
              // SingleChildScrollView (not ListView): every step's controls
              // stay built so screen-reader labels, tests and finders see the
              // whole step even when it scrolls.
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        appLocale.strings.stepHeader(
                            current + 1, steps.length, steps[current].title),
                        style: const TextStyle(
                            fontSize: 28, fontWeight: FontWeight.bold)),
                    if (steps[current].subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(steps[current].subtitle!,
                          style: TextStyle(color: Colors.grey.shade400)),
                    ],
                    const SizedBox(height: 20),
                    ...body,
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
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          for (var i = 0; i < steps.length; i++) ...[
            if (i > 0)
              Expanded(child: Container(height: 2, color: Colors.white12)),
            Tooltip(
              message: steps[i].title,
              child: InkWell(
                onTap: () => onGoto(i),
                customBorder: const CircleBorder(),
                child: CircleAvatar(
                  radius: 16,
                  backgroundColor: steps[i] == steps[current]
                      ? Theme.of(context).colorScheme.primary
                      : current > i
                          ? Colors.white24
                          : Colors.white10,
                  child: current > i
                      ? const Icon(Icons.check, size: 16)
                      : Icon(steps[i].icon, size: 16),
                ),
              ),
            ),
          ],
        ]),
      );

  Widget _nav() {
    // The host's gate decides whether this step is complete; without a
    // gate every step may continue.
    final mayContinue = canContinue?.call(current) ?? true;
    return Row(children: [
      if (current > 0)
        OutlinedButton.icon(
          onPressed: () => onGoto(current - 1),
          icon: const Icon(Icons.chevron_left),
          label: Text(appLocale.strings.back),
        ),
      const Spacer(),
      if (current < steps.length - 1)
        FilledButton.icon(
          onPressed: mayContinue ? () => onGoto(current + 1) : null,
          icon: const Icon(Icons.chevron_right),
          label: Text(appLocale.strings.continueLabel),
        ),
    ]);
  }
}
