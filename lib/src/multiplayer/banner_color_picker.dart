import 'package:flutter/material.dart';

import 'lobby_seat.dart';

/// A shared palette for banner colors (the same defaults the lobby assigns to
/// new seats). Kept here so the picker and the lobby agree on what "used"
/// means.
const List<String> bannerPalette = [
  'FF9C27FF', // violet
  'FF4CAF50', // green
  'FF2196F3', // blue
  'FFFF9800', // orange
  'FFE91E63', // pink
  'FF00BCD4', // cyan
  'FFFFEB3B', // yellow
  'FF795548', // brown
  'FF607D8B', // blue grey
  'FFFF5252', // red
  'FF3F51B5', // indigo
  'FF00E676', // mint
  'FFFF6D00', // deep orange
  'FFC6FF00', // lime
  'FFD500F9', // purple
  'FF8D6E63', // tan
];

/// Returns the ARGB hex string (no leading 0x) for a [Color].
String bannerColorHex(Color color) =>
    color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();

Color bannerColor(String hex) {
  final normalized = hex.trim().replaceFirst('#', '').toUpperCase();
  final padded =
      normalized.length == 6 ? 'FF$normalized' : normalized.padLeft(8, '0');
  return Color(int.tryParse(padded, radix: 16) ?? 0xFF9C27FF);
}

/// The first palette color no seat has taken, cycling from the start when a
/// table outgrows the palette. Complements [bannerColorHex] (arbitrary color
/// → hex) for the common "give the new seat a free banner" case.
String nextFreeBannerColorHex({Set<String> taken = const {}}) {
  final upper = taken.map((h) => h.toUpperCase()).toSet();
  for (final hex in bannerPalette) {
    if (!upper.contains(hex.toUpperCase())) return hex;
  }
  return bannerPalette.first;
}

/// Shows the banner color picker for [slot]. Returns the chosen ARGB hex
/// string, or null when the dialog was dismissed. [takenColors] lists the
/// colorHex values other seats already use; those swatches get a marker and
/// picking them again is allowed but labelled.
Future<String?> showBannerColorPicker(
  BuildContext context, {
  required LobbySeat slot,
  Set<String> takenColors = const {},
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) =>
        _BannerColorDialog(slot: slot, takenColors: takenColors),
  );
}

class _BannerColorDialog extends StatefulWidget {
  const _BannerColorDialog({required this.slot, required this.takenColors});

  final LobbySeat slot;
  final Set<String> takenColors;

  @override
  State<_BannerColorDialog> createState() => _BannerColorDialogState();
}

class _BannerColorDialogState extends State<_BannerColorDialog> {
  late HSVColor _hsv = HSVColor.fromColor(bannerColor(widget.slot.colorHex));
  late final TextEditingController _hexController =
      TextEditingController(text: _hex(_hsv.toColor()));

  static String _hex(Color color) => '#${bannerColorHex(color).substring(2)}';

  void _apply(Color color) {
    setState(() {
      _hsv = HSVColor.fromColor(color);
      _hexController.text = _hex(color);
    });
  }

  void _commit(Color color) =>
      Navigator.pop(dialogContext, bannerColorHex(color));

  BuildContext get dialogContext => context;

  @override
  Widget build(BuildContext context) {
    final current = _hsv.toColor();
    return AlertDialog(
      title: Text("${widget.slot.name}'s banner"),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Live preview of the banner as it will appear on the map.
              Container(
                height: 44,
                decoration: BoxDecoration(
                  color: current,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white24),
                ),
                child: Center(
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.flag, color: Colors.black54, size: 20),
                    const SizedBox(width: 8),
                    Text(widget.slot.name,
                        style: const TextStyle(
                            color: Colors.black87,
                            fontWeight: FontWeight.bold)),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              const Text('PALETTE',
                  style: TextStyle(
                      fontSize: 11, letterSpacing: 1.1, color: Colors.grey)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final hex in bannerPalette)
                    _Swatch(
                      color: bannerColor(hex),
                      selected: bannerColorHex(current) == hex.toUpperCase(),
                      takenByOther:
                          widget.takenColors.contains(hex.toUpperCase()),
                      onTap: () => _apply(bannerColor(hex)),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('CUSTOM',
                  style: TextStyle(
                      fontSize: 11, letterSpacing: 1.1, color: Colors.grey)),
              _HueSlider(
                hue: _hsv.hue,
                saturation: _hsv.saturation,
                value: _hsv.value,
                onChanged: (hue) => _apply(_hsv.withHue(hue).toColor()),
              ),
              Row(children: [
                const SizedBox(width: 8),
                Expanded(
                  child: Slider(
                    value: _hsv.saturation,
                    onChanged: (saturation) =>
                        _apply(_hsv.withSaturation(saturation).toColor()),
                    label: 'Saturation',
                  ),
                ),
              ]),
              Row(children: [
                const SizedBox(width: 8),
                Expanded(
                  child: Slider(
                    value: _hsv.value,
                    onChanged: (value) =>
                        _apply(_hsv.withValue(value).toColor()),
                    label: 'Brightness',
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              TextField(
                controller: _hexController,
                decoration: const InputDecoration(
                  labelText: 'Hex',
                  hintText: '#9C27FF',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (text) {
                  final color = bannerColor(text);
                  _apply(color);
                  _commit(color);
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel')),
        FilledButton.icon(
          icon: const Icon(Icons.check, size: 16),
          label: const Text('Use this color'),
          onPressed: () => _commit(current),
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(
      {required this.color,
      required this.selected,
      required this.takenByOther,
      required this.onTap});

  final Color color;
  final bool selected;
  final bool takenByOther;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: takenByOther ? 'Already used by another player' : 'Use color',
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
                color: selected ? Colors.white : Colors.white24,
                width: selected ? 3 : 1),
          ),
          child: takenByOther
              ? const Icon(Icons.person, size: 14, color: Colors.black45)
              : (selected
                  ? const Icon(Icons.check, size: 16, color: Colors.black54)
                  : null),
        ),
      ),
    );
  }
}

/// Horizontal hue strip with a subtle rainbow gradient and the value thumb.
class _HueSlider extends StatelessWidget {
  const _HueSlider(
      {required this.hue,
      required this.saturation,
      required this.value,
      required this.onChanged});

  final double hue;
  final double saturation;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Slider(
      value: hue,
      max: 360,
      onChanged: onChanged,
      label: 'Hue',
    );
  }
}
