import 'package:celestial_peace_nf_core/celestial_peace_nf_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/setup/card_stats.dart';

/// The card stats wizard: the cards listed, the picked one's schedule, and
/// its recall curve once graded.
void main() {
  final DateTime day0 = DateTime.utc(2026, 11, 1, 12);
  const Cues unaided = Cues(rhoNum: 1, rhoDen: 2, exponent: 2, visible: 0);
  const Cues aided = Cues(rhoNum: 1, rhoDen: 2, exponent: 2);

  testWidgets('lists the cards, shows stats, ↓ picks the next',
      (WidgetTester tester) async {
    final MemSchedule s = MemSchedule(FakeClock(day0));
    final MemCard graded = s.grade(MemCard.map(0, 1, unaided), Grade.good);
    final MemCard practice = MemCard.map(0, 2, aided);
    final DateTime now = day0.add(const Duration(days: 2));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 760,
          height: 480,
          child: CardStatsView(
              cards: <MemCard>[graded, practice], schedule: s, now: now),
        ),
      ),
    ));
    expect(find.text('Stage 0, map 1'), findsNWidgets(2)); // list + title
    expect(find.text('graded'), findsOneWidget);
    expect(find.text(percentText(s.recall(graded, now)!)), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(find.text('practice: stops count as targets'), findsOneWidget);
    expect(find.textContaining('No curve yet'), findsOneWidget);
  });

  test('names and dates', () {
    expect(cardName(MemCard.map(2, 5, unaided)), 'Stage 2, map 5');
    expect(cardName(MemCard.fact('salt')), 'Fact: salt');
    expect(percentText(0.9), '90%');
  });
}
