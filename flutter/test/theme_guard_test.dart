// T-06 guard: feature screens must resolve colors through the theme, not
// hardcode them. A hardcoded color cannot react to themeModeProvider, so it
// silently breaks whichever theme it was not authored against — the exact bug
// this test exists to prevent from creeping back in.
//
// Colors belong in core/theme/atlas_theme.dart. If a feature needs a shade
// that does not exist yet, add a token there (and check its contrast) rather
// than inlining a literal here.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `Colors.white` / `Colors.black` (with optional shade suffix like `white70`)
/// and raw `Color(0x…)` literals.
final _namedLiteral = RegExp(r'\bColors\.(white|black)\d*\b');
final _hexLiteral = RegExp(r'\bColor\(\s*0x[0-9a-fA-F]+\s*\)');

/// Resolves a repo-relative directory whether the test is run from the
/// `flutter/` package root or from the repository root.
Directory _resolve(String relative) {
  for (final prefix in const ['', 'flutter/']) {
    final dir = Directory('$prefix$relative');
    if (dir.existsSync()) return dir;
  }
  fail(
    'Could not locate "$relative" from ${Directory.current.path}. '
    'Run this test from the flutter/ package root or the repo root.',
  );
}

void main() {
  group('T-06 theme guard', () {
    test('feature screens contain no hardcoded colors', () {
      final featuresDir = _resolve('lib/features');

      final dartFiles = featuresDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      // Guard the guard: if the glob silently matches nothing, the test would
      // pass vacuously and stop protecting anything.
      expect(
        dartFiles,
        isNotEmpty,
        reason: 'Found no Dart files under ${featuresDir.path}',
      );

      final offences = <String>[];

      for (final file in dartFiles) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];

          // Skip comments — prose and doc comments legitimately mention the
          // literals (including this file's own rationale being quoted).
          final trimmed = line.trimLeft();
          if (trimmed.startsWith('//')) continue;

          final match = _namedLiteral.firstMatch(line) ??
              _hexLiteral.firstMatch(line);
          if (match == null) continue;

          final relative =
              file.path.replaceAll(r'\', '/').split('lib/').last;
          offences.add(
            '  lib/$relative:${i + 1}  ${match.group(0)}\n'
            '      ${trimmed.length > 90 ? '${trimmed.substring(0, 90)}…' : trimmed}',
          );
        }
      }

      expect(
        offences,
        isEmpty,
        reason: 'Hardcoded colors found in lib/features/ '
            '(${offences.length} occurrence(s)).\n'
            'Use ThemeColors.of(context) — or add a token to '
            'core/theme/atlas_theme.dart if the shade is missing:\n'
            '${offences.join('\n')}',
      );
    });
  });
}
