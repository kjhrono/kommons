import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kommons/kommons.dart';

/// Literals the sweep deliberately left alone, with the reason each is not a
/// theme ink. Everything else in `lib/` has to come from the theme.
///
/// An entry that stops matching a real literal fails the suite below: dead
/// exceptions get deleted instead of quietly widening the rule.
const _allowed = <String, ({Set<String> colors, String why})>{
  'lib/src/high_contrast.dart': (
    colors: {'white', 'black'},
    why: "it defines the contrast theme's own surfaces and ink",
  ),
  'lib/src/multiplayer/lobby_step.dart': (
    colors: {'white'},
    why: 'the invite QR needs a white mat, theme or not',
  ),
  'lib/src/multiplayer/qr_share.dart': (
    colors: {'white'},
    why: 'a QR quiet zone must stay pure white to scan',
  ),
};

/// `Colors.white24`, `Colors.grey.shade500` — the token after the dot is the
/// colour plus an optional shade/alpha suffix. The lookbehind keeps
/// `takenColors.contains` out of the report.
final _literal = RegExp(
    r'(?<![A-Za-z0-9_])Colors\.([a-zA-Z][a-zA-Z0-9]*(?:\.[a-zA-Z0-9]+)?)');

/// Blanks comments while keeping every newline, so a reported line number is
/// the real one (the sweep's own prose names `Colors.grey` on purpose).
String _blankComments(String source) => source
    .replaceAllMapped(RegExp(r'/\*[\s\S]*?\*/'),
        (match) => match.group(0)!.replaceAll(RegExp(r'[^\n]'), ' '))
    .replaceAllMapped(
        RegExp(r'//[^\n]*'), (match) => ' ' * match.group(0)!.length);

/// Every literal ink in [source], as `path:line: Colors.x`.
///
/// [Colors.transparent] is not an ink and is never reported.
List<String> findLiteralInks(String path, String source) {
  final lines = _blankComments(source).split('\n');
  final found = <String>[];
  for (var i = 0; i < lines.length; i++) {
    for (final match in _literal.allMatches(lines[i])) {
      final token = match.group(1)!;
      // The colour family, so allowlisting 'white' also covers white24/70.
      final base = token.split('.').first.replaceAll(RegExp(r'\d+$'), '');
      if (base == 'transparent') continue;
      if (_allowed[path]?.colors.contains(base) ?? false) continue;
      found.add('$path:${i + 1}: ${match.group(0)}');
    }
  }
  return found;
}

/// WCAG 2.x contrast ratio between two opaque colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('the sweep holds', () {
    test('no screen outside the allowlist paints a literal ink', () {
      final files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
      final offences = [
        for (final file in files)
          ...findLiteralInks(file.path, file.readAsStringSync()),
      ];
      expect(offences, isEmpty,
          reason: 'Route these through Theme.of(context).colorScheme — '
              'mutedInk, warningInk, readyInk, dangerInk, or inkOn(colour):\n'
              '${offences.join('\n')}');
    });

    test('the scan catches exactly what the sweep removed', () {
      expect(
          findLiteralInks('lib/screen.dart',
              "Text('x', style: TextStyle(color: Colors.grey.shade500))"),
          ['lib/screen.dart:1: Colors.grey.shade500']);
      expect(findLiteralInks('lib/screen.dart', 'Colors.white24'),
          ['lib/screen.dart:1: Colors.white24']);
      // No layout change, no ink: transparent is fine anywhere.
      expect(findLiteralInks('lib/screen.dart', 'Colors.transparent'), isEmpty);
      // A comment may name the literal it warns about, without failing.
      expect(
          findLiteralInks('lib/screen.dart',
              '// never use Colors.grey.shade500 here\nconst x = 1;'),
          isEmpty);
      // Allowlisted literals pass in their own file, and only there.
      expect(findLiteralInks('lib/src/high_contrast.dart', 'Colors.white'),
          isEmpty);
      expect(findLiteralInks('lib/src/high_contrast.dart', 'Colors.grey'),
          ['lib/src/high_contrast.dart:1: Colors.grey']);
    });

    test('every allowlist entry still matches a literal', () {
      for (final entry in _allowed.entries) {
        final source = _blankComments(File(entry.key).readAsStringSync());
        for (final colour in entry.value.colors) {
          expect(source.contains('Colors.$colour'), isTrue,
              reason: '${entry.key} no longer uses Colors.$colour — delete '
                  'the exception (${entry.value.why})');
        }
      }
    });
  });

  group('the inks stay readable', () {
    ThemeData contrastTheme(Brightness brightness) => highContrastTheme(
          ThemeData(
            colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xff4f6f52), brightness: brightness),
            useMaterial3: true,
          ),
        );

    for (final brightness in Brightness.values) {
      test('${brightness.name} contrast mode clears 4.5:1 on its surface', () {
        final scheme = contrastTheme(brightness).colorScheme;
        final surface = scheme.surface;
        final inks = {
          'mutedInk': scheme.mutedInk,
          'warningInk': scheme.warningInk,
          'readyInk': scheme.readyInk,
          'dangerInk': scheme.dangerInk,
        };
        for (final ink in inks.entries) {
          expect(_contrast(ink.value, surface), greaterThanOrEqualTo(4.5),
              reason: '${ink.key} (${ink.value}) on $surface');
        }
      });
    }

    test('the greys the sweep replaced would not have cleared it', () {
      // The bug this sweep fixes: in light contrast mode the surface is pure
      // white and the old literal stayed exactly as pale as it was.
      final surface = contrastTheme(Brightness.light).colorScheme.surface;
      expect(_contrast(Colors.grey.shade500, surface), lessThan(3),
          reason: 'a caption ink that clears 4.5:1 on a dark surface fails '
              'the moment contrast mode turns the surface white');
    });

    testWidgets('a cloud room card paints its seats from the scheme',
        (tester) async {
      final theme = contrastTheme(Brightness.light);
      final scheme = theme.colorScheme;
      final room = CloudRoom(
        code: 'K7X2M',
        clock: 8,
        hasSnapshot: true,
        hasPassword: false,
        isLocalHost: true,
        seats: const [
          CloudSeat(name: 'Ana', colorHex: 'FF9C27FF', ready: true),
          CloudSeat(name: 'Bree', colorHex: 'FF4CAF50', ready: false),
        ],
      );
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
          body: CloudRoomCard(room: room, localSeatName: 'Ana'),
        ),
      ));
      await tester.pump();

      final unready = tester.widget<Text>(find.text('Bree')).style!.color!;
      expect(unready, scheme.mutedInk,
          reason: 'an unready seat reads in the theme\'s muted ink');
      expect(_contrast(unready, scheme.surface), greaterThanOrEqualTo(4.5));

      expect(tester.widget<Icon>(find.byIcon(Icons.check_circle)).color,
          scheme.readyInk);
      expect(tester.widget<Icon>(find.byIcon(Icons.hourglass_empty)).color,
          scheme.mutedInk);
      expect(tester.widget<Icon>(find.byIcon(Icons.workspace_premium)).color,
          scheme.warningInk);
    });

    test('ink on a player colour follows that colour', () {
      final scheme = contrastTheme(Brightness.dark).colorScheme;
      expect(scheme.inkOn(const Color(0xFFFFEB3B)), const Color(0xFF1B1B1B),
          reason: 'a pale banner gets dark ink');
      expect(scheme.inkOn(const Color(0xFF1B1B1B)), const Color(0xFFFFFFFF),
          reason: 'a dark banner gets white ink');

      for (final hex in bannerPalette) {
        final swatch = bannerColor(hex);
        expect(_contrast(scheme.inkOn(swatch), swatch), greaterThanOrEqualTo(3),
            reason: 'a swatch $hex must keep its mark legible');
      }
    });
  });
}
