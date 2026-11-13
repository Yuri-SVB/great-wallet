/// The card stats wizard (Train, Main board Z): every card of the deck, and
/// for the one picked its schedule and the chance of recalling it over time
/// (the forgetting curve, [MemSchedule.recall]).
library;

import 'dart:math' as math;

import 'package:celestial_peace_nf_core/celestial_peace_nf_core.dart'
    show CardKind, ForgettingParams, MemCard, MemSchedule;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// [t] as a local date, YYYY-MM-DD.
String dateText(DateTime t) {
  final DateTime l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)}';
}

/// A chance as a whole percentage.
String percentText(double r) => '${(r * _kPercent).round()}%';
const double _kPercent = 100;

/// A card's name in the wizard.
String cardName(MemCard c) => c.kind == CardKind.point
    ? 'Stage ${c.stageIndex}, map ${c.slot}'
    : 'Fact: ${c.factId}';

/// The cards ([cards]) listed, ↑ ↓ to pick one, its stats and recall curve
/// beside.
class CardStatsView extends StatefulWidget {
  const CardStatsView({
    super.key,
    required this.cards,
    required this.schedule,
    required this.now,
    this.initial = 0,
  });

  final List<MemCard> cards;
  final MemSchedule schedule;
  final DateTime now;

  /// The card picked first.
  final int initial;

  @override
  State<CardStatsView> createState() => _CardStatsViewState();
}

class _CardStatsViewState extends State<CardStatsView> {
  late int _at = widget.cards.isEmpty
      ? 0
      : widget.initial.clamp(0, widget.cards.length - 1);

  static const double _listWidth = 200;
  static const double _gap = 12;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final int n = widget.cards.length;
    if (n == 0) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _at = (_at + 1) % n);
    } else if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _at = (_at - 1 + n) % n);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// The picked card's stats, label and value.
  List<(String, String)> _stats(MemCard c) {
    final MemSchedule s = widget.schedule;
    final DateTime? last = s.lastReview(c);
    final double? recall = s.recall(c, widget.now);
    final DateTime? due = c.due;
    return <(String, String)>[
      (
        'State',
        !c.isGraded
            ? 'practice: stops count as targets'
            : last == null
                ? 'new: not graded yet'
                : 'graded'
      ),
      ('Interval', '${c.intervalDays} days'),
      ('Ease', c.easeFactor.toStringAsFixed(2)),
      ('Successes in a row', '${c.repetitions}'),
      ('Lapses', '${c.lapses}'),
      ('Last review', last == null ? '—' : dateText(last)),
      ('Due', due == null || !due.isAfter(widget.now) ? 'now' : dateText(due)),
      (
        'Recall now',
        recall == null ? '—' : percentText(recall)
      ),
      ('Consolidated', s.consolidated(c) ? 'yes' : 'no'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (widget.cards.isEmpty) {
      return const Center(child: Text('No cards yet.'));
    }
    final MemCard card = widget.cards[_at];
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: _listWidth,
            child: ListView(
              children: <Widget>[
                for (int i = 0; i < widget.cards.length; i++)
                  ListTile(
                    dense: true,
                    selected: i == _at,
                    title: Text(cardName(widget.cards[i])),
                    onTap: () => setState(() => _at = i),
                  ),
              ],
            ),
          ),
          const VerticalDivider(width: _gap * 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(cardName(card), style: theme.textTheme.titleMedium),
                const SizedBox(height: _gap / 2),
                for (final (String label, String value) in _stats(card))
                  Row(
                    children: <Widget>[
                      SizedBox(width: _listWidth, child: Text(label)),
                      Expanded(child: Text(value)),
                    ],
                  ),
                const SizedBox(height: _gap),
                Text('Chance of recalling it over time',
                    style: theme.textTheme.bodySmall),
                Expanded(
                  child: widget.schedule.recall(card, widget.now) == null
                      ? const Center(
                          child: Text('No curve yet: it starts with the first '
                              'graded review, without stops.'),
                        )
                      : CustomPaint(
                          painter: RecallCurvePainter(
                            schedule: widget.schedule,
                            card: card,
                            now: widget.now,
                            colour: theme.colorScheme.primary,
                            ink: theme.colorScheme.onSurface,
                            labelStyle: theme.textTheme.bodySmall ??
                                const TextStyle(),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The forgetting curve of a graded [card], from its last review on: the
/// chance of recalling it, with when it is due and now marked, and `r*`
/// (the chance when due) as a guide. The chance axis runs from a step below
/// the curve's lowest point to 100%, so the curve fills the plot.
class RecallCurvePainter extends CustomPainter {
  RecallCurvePainter({
    required this.schedule,
    required this.card,
    required this.now,
    required this.colour,
    required this.ink,
    required this.labelStyle,
  });

  final MemSchedule schedule;
  final MemCard card;
  final DateTime now;
  final Color colour;
  final Color ink;
  final TextStyle labelStyle;

  /// The chance axis's step: its floor is a whole number of these.
  static const double _axisStep = 0.1;

  /// The span shown: this many intervals from the last review, or past now.
  static const int _intervalsShown = 3;

  /// Points along the curve, room left for the labels, stroke widths, and the
  /// guide's and markers' dimming.
  static const int _samples = 120;
  static const double _labelRoom = 36;
  static const double _labelSize = 11;
  static const double _curveStroke = 2;
  static const double _lineStroke = 1;
  static const double _faint = 0.4;
  static const int _hoursPerDay = 24;

  @override
  void paint(Canvas canvas, Size size) {
    final DateTime last = schedule.lastReview(card)!;
    final double interval = card.intervalDays.toDouble();
    final double nowDays = now.difference(last).inMinutes /
        Duration.minutesPerHour /
        _hoursPerDay;
    final double span = math.max(interval * _intervalsShown, nowDays + interval);
    final Rect plot = Rect.fromLTRB(
        _labelRoom, _labelSize, size.width - _labelSize, size.height - _labelRoom);
    DateTime when(double days) => last.add(Duration(
        minutes: (days * _hoursPerDay * Duration.minutesPerHour).round()));
    final List<double> rs = <double>[
      for (int i = 0; i <= _samples; i++)
        schedule.recall(card, when(span * i / _samples))!,
    ];
    final double floor = math.max(
        0, ((rs.reduce(math.min) / _axisStep).floor() - 1) * _axisStep);
    Offset at(double days, double r) => Offset(
        plot.left + plot.width * days / span,
        plot.bottom - plot.height * (r - floor) / (1 - floor));

    final Paint axis = Paint()
      ..color = ink.withValues(alpha: _faint)
      ..strokeWidth = _lineStroke;
    canvas.drawLine(plot.bottomLeft, plot.bottomRight, axis);
    canvas.drawLine(plot.bottomLeft, plot.topLeft, axis);
    final double rStar = schedule.forgetting.retentionAtDue;
    canvas.drawLine(at(0, rStar), at(span, rStar), axis);

    final Path curve = Path();
    for (int i = 0; i <= _samples; i++) {
      final Offset p = at(span * i / _samples, rs[i]);
      i == 0 ? curve.moveTo(p.dx, p.dy) : curve.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
        curve,
        Paint()
          ..color = colour
          ..style = PaintingStyle.stroke
          ..strokeWidth = _curveStroke);

    void marker(double days, String text, Color c) {
      final Offset top = at(days, 1);
      canvas.drawLine(top, at(days, floor),
          Paint()
            ..color = c
            ..strokeWidth = _lineStroke);
      _label(canvas, text, at(days, floor).translate(0, _labelSize / 2), c,
          centred: true);
    }

    marker(interval, 'due ${dateText(card.due!)}', ink.withValues(alpha: _faint));
    if (nowDays >= 0 && nowDays <= span) marker(nowDays, 'now', ink);

    _label(canvas, percentText(1), at(0, 1).translate(-_labelRoom, -_labelSize / 2), ink);
    _label(canvas, percentText(rStar),
        at(0, rStar).translate(-_labelRoom, -_labelSize / 2), ink);
    _label(canvas, percentText(floor),
        at(0, floor).translate(-_labelRoom, -_labelSize / 2), ink);
    _label(canvas, '+${span.round()} d',
        at(span, floor).translate(-_labelRoom, _labelSize * 2), ink);
  }

  void _label(Canvas canvas, String text, Offset at, Color c,
      {bool centred = false}) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
          text: text,
          style: labelStyle.copyWith(color: c, fontSize: _labelSize)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, centred ? at.translate(-tp.width / 2, 0) : at);
    tp.dispose();
  }

  @override
  bool shouldRepaint(RecallCurvePainter old) =>
      !identical(old.card, card) ||
      old.now != now ||
      old.colour != colour ||
      old.labelStyle != labelStyle;
}

/// The default chance of recalling a card when due, for the help text.
const double kRetentionAtDue = ForgettingParams.defaultRetentionAtDue;
