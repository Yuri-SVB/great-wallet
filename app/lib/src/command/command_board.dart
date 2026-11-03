import 'package:flutter/material.dart';

import 'keyboard_layout.dart';

/// A context of the command board: a fixed set of twelve commands, switched
/// with Alt and one of the board's top-row keys (as selecting a unit switches
/// its command card).
enum CommandContext {
  main('Main', Icons.home),
  setup('Setup', Icons.tune),
  path('Path', Icons.route),
  view('View', Icons.palette);

  const CommandContext(this.label, this.icon);
  final String label;
  final IconData icon;

  /// The board key (index into [kBoardKeys]) that, with Alt, selects it: the
  /// top row, left to right.
  int get key => index;
}

/// One command on the board: what it shows and what it does. [enabled] is
/// asked at every build; a disabled command stays in place, greyed out.
@immutable
class BoardCommand {
  const BoardCommand({
    required this.name,
    required this.help,
    required this.run,
    this.icon,
    this.glyph,
    this.enabled = true,
    this.active = false,
    this.repeats = false,
  }) : assert(icon != null || glyph != null);

  /// Its name, shown on hover and in the log.
  final String name;

  /// What it does and why, shown in the log while it has the pointer or focus.
  final String help;

  final VoidCallback run;
  final IconData? icon;

  /// A drawn glyph, for commands no stock icon fits.
  final Widget Function(Color colour)? glyph;
  final bool enabled;

  /// A toggle that is on: drawn lit.
  final bool active;

  /// Runs again while its key is held (steps such as volume or brightness).
  final bool repeats;
}

/// Size of a board button and the gap between buttons, in logical pixels.
const double kBoardButtonWidth = 56;
const double kBoardButtonHeight = 44;
const double kBoardGap = 4;

/// The command board: the context tabs above a 3 × 4 grid of buttons, each
/// with its icon and its key's letter in the current [layout]. Hovering or
/// focusing a button (or a tab) reports its explanation through [onExplain],
/// and null when it leaves.
class CommandBoard extends StatelessWidget {
  const CommandBoard({
    super.key,
    required this.active,
    required this.commands,
    required this.layout,
    required this.onContext,
    required this.onExplain,
    required this.colour,
  });

  /// The context shown.
  final CommandContext active;

  /// Its commands, one per board key ([kBoardKeys] order); null for an empty
  /// slot.
  final List<BoardCommand?> commands;
  final KeyboardLayout layout;
  final ValueChanged<CommandContext> onContext;
  final ValueChanged<String?> onExplain;

  /// Foreground colour of icons and letters.
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final CommandContext c in CommandContext.values)
              Padding(
                padding: const EdgeInsets.only(right: kBoardGap),
                child: _Tab(
                  tab: c,
                  selected: c == active,
                  keyLabel: 'Alt+${layout.keys[c.key]}',
                  colour: colour,
                  onTap: () => onContext(c),
                  onExplain: onExplain,
                ),
              ),
          ],
        ),
        const SizedBox(height: kBoardGap),
        for (int row = 0; row < kBoardRows; row++)
          Padding(
            padding: const EdgeInsets.only(bottom: kBoardGap),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (int col = 0; col < kBoardColumns; col++)
                  Padding(
                    padding: const EdgeInsets.only(right: kBoardGap),
                    child: _Button(
                      command: commands[row * kBoardColumns + col],
                      keyLabel: layout.keys[row * kBoardColumns + col],
                      colour: colour,
                      onExplain: onExplain,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The explanation of [command] under its key [keyLabel].
String explainCommand(BoardCommand command, String keyLabel) =>
    '${command.name} ($keyLabel)'
    '${command.enabled ? '' : ' — not available now'}. ${command.help}';

class _Tab extends StatelessWidget {
  const _Tab({
    required this.tab,
    required this.selected,
    required this.keyLabel,
    required this.colour,
    required this.onTap,
    required this.onExplain,
  });

  final CommandContext tab;
  final bool selected;
  final String keyLabel;
  final Color colour;
  final VoidCallback onTap;
  final ValueChanged<String?> onExplain;

  @override
  Widget build(BuildContext context) {
    final String text = '${tab.label} commands ($keyLabel).';
    return _Hover(
      onExplain: onExplain,
      text: text,
      child: Material(
        color: selected ? colour.withValues(alpha: 0.18) : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: colour.withValues(alpha: selected ? 0.8 : 0.25)),
        ),
        child: InkWell(
          onTap: onTap,
          onFocusChange: (bool has) => onExplain(has ? text : null),
          child: SizedBox(
            width: kBoardButtonWidth,
            height: 26,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(tab.icon, size: 14, color: colour),
                const SizedBox(width: 3),
                Text(
                  keyLabel.substring(keyLabel.length - 1),
                  style: TextStyle(color: colour, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({
    required this.command,
    required this.keyLabel,
    required this.colour,
    required this.onExplain,
  });

  final BoardCommand? command;
  final String keyLabel;
  final Color colour;
  final ValueChanged<String?> onExplain;

  @override
  Widget build(BuildContext context) {
    final BoardCommand? c = command;
    final bool live = c != null && c.enabled;
    final Color fg = colour.withValues(alpha: live ? 1.0 : 0.3);
    final Widget face = SizedBox(
      width: kBoardButtonWidth,
      height: kBoardButtonHeight,
      child: Stack(
        children: <Widget>[
          if (c != null)
            Center(
              child: c.glyph != null
                  ? c.glyph!(fg)
                  : Icon(c.icon, size: 22, color: fg),
            ),
          Positioned(
            left: 4,
            top: 2,
            child: Text(
              keyLabel,
              style: TextStyle(color: fg, fontSize: 10),
            ),
          ),
        ],
      ),
    );
    final ShapeBorder shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(4),
      side: BorderSide(color: colour.withValues(alpha: c == null ? 0.1 : 0.35)),
    );
    if (c == null) return Material(color: Colors.transparent, shape: shape, child: face);
    final String text = explainCommand(c, keyLabel);
    return _Hover(
      onExplain: onExplain,
      text: text,
      child: Material(
        color: c.active ? colour.withValues(alpha: 0.22) : Colors.transparent,
        shape: shape,
        child: InkWell(
          onTap: c.enabled ? c.run : null,
          canRequestFocus: true,
          onFocusChange: (bool has) => onExplain(has ? text : null),
          child: Semantics(label: c.name, button: true, child: face),
        ),
      ),
    );
  }
}

/// Reports [text] while the pointer is over [child], and null when it leaves.
class _Hover extends StatelessWidget {
  const _Hover({required this.onExplain, required this.text, required this.child});

  final ValueChanged<String?> onExplain;
  final String text;
  final Widget child;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => onExplain(text),
        onExit: (_) => onExplain(null),
        child: child,
      );
}

/// The landmark exponent's glyphs (cpnf landmark cues): bars with arrows
/// spreading out (`|◂▸|`: longer hops tolerated, fewer stops) or squeezing in
/// (`▸||◂`: shorter hops, more stops).
class HopGlyph extends StatelessWidget {
  const HopGlyph({super.key, required this.spread, required this.colour});

  final bool spread;
  final Color colour;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: const Size(26, 16),
        painter: _HopPainter(spread: spread, colour: colour),
      );
}

class _HopPainter extends CustomPainter {
  _HopPainter({required this.spread, required this.colour});

  final bool spread;
  final Color colour;

  /// Stroke width, arrowhead size and the bars' inset, in logical pixels.
  static const double _stroke = 2;
  static const double _head = 4;
  static const double _inset = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..color = colour
      ..strokeWidth = _stroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final double w = size.width;
    final double h = size.height;
    final double mid = w / 2;
    final double y = h / 2;
    void arrow(double from, double to) {
      canvas.drawLine(Offset(from, y), Offset(to, y), p);
      final double back = to > from ? -_head : _head;
      canvas.drawLine(Offset(to, y), Offset(to + back, y - _head), p);
      canvas.drawLine(Offset(to, y), Offset(to + back, y + _head), p);
    }

    if (spread) {
      // |◂ ▸|: bars at the ends, arrows from the middle out to them.
      canvas.drawLine(const Offset(_inset, 0), Offset(_inset, h), p);
      canvas.drawLine(Offset(w - _inset, 0), Offset(w - _inset, h), p);
      arrow(mid - 1, _inset + _stroke);
      arrow(mid + 1, w - _inset - _stroke);
    } else {
      // ▸||◂: bars in the middle, arrows from the ends in to them.
      canvas.drawLine(Offset(mid - _head / 2, 0), Offset(mid - _head / 2, h), p);
      canvas.drawLine(Offset(mid + _head / 2, 0), Offset(mid + _head / 2, h), p);
      arrow(0, mid - _head / 2 - _stroke);
      arrow(w, mid + _head / 2 + _stroke);
    }
  }

  @override
  bool shouldRepaint(_HopPainter old) =>
      old.spread != spread || old.colour != colour;
}
