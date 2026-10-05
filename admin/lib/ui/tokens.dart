// Copied from app/lib/ui/tokens.dart by tools/sync-admin-ui.mjs. Edit the original, not this copy.
import 'package:flutter/material.dart';

import '../theme.dart';

// Additions to the verbatim token layer in theme.dart. Kept here so theme.dart can be
// regenerated from the guide without losing them.

/// Violet for AI-reader text and icons. In dark mode the guide's #5B3DF5 reads at 2.7:1
/// on its soft ground, so dark mode uses a lighter violet (approved by Santosh).
Color get aiAccentInk => isDark ? const Color(0xFF9F8CFF) : aiAccent;

/// Idle ring colour from the completion-ring spec (guide section 5).
Color get ringIdle => isDark ? const Color(0xFF3A3A44) : const Color(0xFFDEDEE6);

/// Avatar person colours. None is a state colour or the accent.
const personColors = <Color>[
  Color(0xFF0F8B8D),
  Color(0xFF2F6FEB),
  Color(0xFFC2417A),
  Color(0xFF8B5E3C),
  Color(0xFF4F6D8A),
  Color(0xFF6B7F1A),
  Color(0xFFB4532A),
  Color(0xFF3D7068),
];

Color personColor(String seed) {
  var h = 0;
  for (final c in seed.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return personColors[h % personColors.length];
}

/// Question text: section size, lighter and looser for reading.
TextStyle get questionStyle =>
    sectionStyle.copyWith(fontWeight: FontWeight.w600, height: 1.48, letterSpacing: -0.37);

/// Option and answer text.
TextStyle get optionStyle => rowTitleStyle.copyWith(fontSize: 16, fontWeight: FontWeight.w500, height: 1.4);

/// Scrim behind centred cards: 32% black in light, 62% in dark (guide section 5).
Color get scrim => isDark ? const Color(0x9E000000) : const Color(0x52000000);

/// Matches figures inside prose so they can be set in mono: 18, 5:42, 14/20, 70%, 4.5.
final figurePattern = RegExp(r'\d+(?:[.:/]\d+)*%?');
