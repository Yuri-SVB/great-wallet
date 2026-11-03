import 'package:flutter/services.dart';

/// The command board's twelve keys, by **position**: the 3 × 4 block under
/// the left hand, rows top to bottom. USB HID codes name positions (after a US
/// QWERTY board), not characters, so the board works the same on every
/// layout; a [KeyboardLayout] only changes the letters printed on it.
const List<PhysicalKeyboardKey> kBoardKeys = <PhysicalKeyboardKey>[
  PhysicalKeyboardKey.keyQ,
  PhysicalKeyboardKey.keyW,
  PhysicalKeyboardKey.keyE,
  PhysicalKeyboardKey.keyR,
  PhysicalKeyboardKey.keyA,
  PhysicalKeyboardKey.keyS,
  PhysicalKeyboardKey.keyD,
  PhysicalKeyboardKey.keyF,
  PhysicalKeyboardKey.keyZ,
  PhysicalKeyboardKey.keyX,
  PhysicalKeyboardKey.keyC,
  PhysicalKeyboardKey.keyV,
];

/// Columns and rows of the board.
const int kBoardColumns = 4;
const int kBoardRows = 3;

/// The build-time default layout's `--dart-define` key.
const String kKeyboardLayoutDefine = 'KEYBOARD_LAYOUT';

/// The letters a keyboard layout prints on the board's keys. The default is
/// set at build time (`--dart-define=KEYBOARD_LAYOUT=azerty`), never detected;
/// the user may switch for the session.
enum KeyboardLayout {
  qwerty('QWERTY', <String>['Q', 'W', 'E', 'R', 'A', 'S', 'D', 'F', 'Z', 'X', 'C', 'V']),
  azerty('AZERTY', <String>['A', 'Z', 'E', 'R', 'Q', 'S', 'D', 'F', 'W', 'X', 'C', 'V']),
  qwertz('QWERTZ', <String>['Q', 'W', 'E', 'R', 'A', 'S', 'D', 'F', 'Y', 'X', 'C', 'V']),
  dvorak('Dvorak', <String>["'", ',', '.', 'P', 'A', 'O', 'E', 'U', ';', 'Q', 'J', 'K']),
  colemak('Colemak', <String>['Q', 'W', 'F', 'P', 'A', 'R', 'S', 'T', 'Z', 'X', 'C', 'V']);

  const KeyboardLayout(this.label, this.keys);

  /// Its name, as shown.
  final String label;

  /// The letter on each board key, in [kBoardKeys] order.
  final List<String> keys;

  /// The build's default: the `KEYBOARD_LAYOUT` define (an enum name, any
  /// case), QWERTY if unset or unknown.
  static KeyboardLayout get buildDefault =>
      named(const String.fromEnvironment(kKeyboardLayoutDefine));

  /// The layout called [name] (any case), QWERTY if none is.
  static KeyboardLayout named(String name) => KeyboardLayout.values.firstWhere(
        (KeyboardLayout l) => l.name == name.toLowerCase(),
        orElse: () => KeyboardLayout.qwerty,
      );

  /// The next layout, for cycling.
  KeyboardLayout get next =>
      KeyboardLayout.values[(index + 1) % KeyboardLayout.values.length];
}
