import 'package:celestial_peace_nf_core/celestial_peace_nf_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/setup/fact_cards.dart';
import 'package:great_wallet_app/src/setup/fact_review.dart';

/// Fact cards: the matching rules, and the review dialogs — a find takes the
/// four grades, a miss (or a find that may not be scored) only Again.
void main() {
  group('matching', () {
    test('answers ignore case and extra spaces', () {
      expect(answerMatches('  Signing-1 ', 'signing-1'), isTrue);
      expect(answerMatches('our   first  date', 'Our first date'), isTrue);
      expect(answerMatches('signing-2', 'signing-1'), isFalse);
    });

    test('σ as hex, any case and spacing', () {
      expect(sigmaMatches('AB CD 0f', 'abcd0f'), isTrue);
      expect(sigmaMatches('0xabcd0f', 'ABCD0F'), isTrue);
      expect(sigmaMatches('', ''), isFalse);
      expect(sigmaMatches('abcd0e', 'abcd0f'), isFalse);
    });

    test('the digest: unknown, wrong or this build\'s', () {
      final String commit = 'a' * kCommitHexDigits;
      expect(digestMatches(commit), isNull, reason: 'built without a digest');
      expect(digestMatches('A' * kCommitHexDigits, commit: commit), isTrue);
      expect(digestMatches('a' * 12, commit: commit), isFalse,
          reason: 'the full digest is asked');
    });

    test('a burial matches the stage whose orbit point it is', () {
      final List<int> o1 = List<int>.generate(64, (int i) => i);
      final List<int> o2 = List<int>.generate(64, (int i) => 255 - i);
      expect(buriedStage(o2, <List<int>?>[null, o1, o2]), 2);
      expect(buriedStage(List<int>.filled(64, 7), <List<int>?>[null, o1]),
          isNull);
      expect(hexBytes('0a ff'), <int>[10, 255]);
      expect(hexBytes('abc'), isNull);
    });

    test('your own cards round-trip; bad ones are refused', () {
      const CustomFact f =
          CustomFact(id: 'misc:1', prompt: 'Export salt', answer: 'SIGN-1');
      final CustomFact back = CustomFact.fromJson(f.toJson());
      expect(back.prompt, 'Export salt');
      expect(
          () => CustomFact.fromJson(<String, dynamic>{
                'id': 'other',
                'prompt': 'p',
                'answer': 'a',
              }),
          throwsFormatException);
      expect(
          () => CustomFact.fromJson(<String, dynamic>{
                'id': 'misc:2',
                'prompt': 'p',
                'answer': 'x' * (kMaxFactChars + 1),
              }),
          throwsFormatException);
      expect(isReviewedFact(MemCard.fact('misc:2')), isTrue);
      for (final String id in kParameterFacts) {
        expect(isReviewedFact(MemCard.fact(id)), isTrue, reason: id);
      }
      expect(isReviewedFact(MemCard.fact('export:1')), isFalse);
      expect(isReviewedFact(MemCard.fact(selectionFact(2))), isTrue);
      expect(selectionStage(selectionFact(2)), 2);
      expect(selectionStage(kSaltFact), isNull);
    });

    test('the maps studied match only as the same set', () {
      expect(selectionMatches(<int>{4, 1, 2}, <int>{1, 2, 4}), isTrue);
      expect(selectionMatches(<int>{1, 2}, <int>{1, 2, 4}), isFalse);
      expect(selectionMatches(<int>{1, 2, 4, 5}, <int>{1, 2, 4}), isFalse);
    });

    test('a fact holds until its chance of recall falls below r*', () {
      final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 1));
      final MemSchedule s = MemSchedule(clock);
      final MemCard fresh = MemCard.fact(kProfileFact);
      expect(factHolds(s, fresh, clock.now()), isFalse,
          reason: 'never graded');
      final MemCard graded = s.grade(fresh, Grade.good); // interval 1 day
      expect(factHolds(s, graded, clock.now().add(const Duration(hours: 23))),
          isTrue);
      expect(factHolds(s, graded, clock.now().add(const Duration(days: 2))),
          isFalse);
    });
  });

  group('dialogs', () {
    testWidgets('your own card: a find takes the four grades',
        (WidgetTester tester) async {
      Grade? got;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async => got = await showDialog<Grade>(
              context: context,
              builder: (BuildContext _) => const CustomFactDialog(
                fact: CustomFact(id: 'misc:1', prompt: 'Salt?', answer: 'X-1'),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'x-1 ');
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(find.text('Right.'), findsOneWidget);
      expect(find.text('Hard'), findsOneWidget);
      await tester.tap(find.text('Good'));
      await tester.pumpAndSettle();
      expect(got, Grade.good);
    });

    testWidgets('your own card: a miss shows the answer, only Again',
        (WidgetTester tester) async {
      Grade? got;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async => got = await showDialog<Grade>(
              context: context,
              builder: (BuildContext _) => const CustomFactDialog(
                fact: CustomFact(id: 'misc:1', prompt: 'Salt?', answer: 'X-1'),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'X-2');
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(find.textContaining('the answer is "X-1"'), findsOneWidget);
      expect(find.text('Good'), findsNothing);
      await tester.tap(find.text('Again'));
      await tester.pumpAndSettle();
      expect(got, Grade.again);
    });

    testWidgets('supply chain: without the build confirmed, only Again',
        (WidgetTester tester) async {
      final String commit = 'b' * kCommitHexDigits;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showDialog<Grade>(
              context: context,
              builder: (BuildContext _) => ProvenanceDialog(commit: commit),
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), commit);
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(find.text(kProvenanceConfirm), findsOneWidget);
      expect(find.textContaining('without the rebuild confirmed'),
          findsOneWidget);
      expect(find.text('Easy'), findsNothing);
      expect(find.text('Again'), findsOneWidget);
    });

    testWidgets('supply chain: confirmed and right, the four grades',
        (WidgetTester tester) async {
      final String commit = 'b' * kCommitHexDigits;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showDialog<Grade>(
              context: context,
              builder: (BuildContext _) => ProvenanceDialog(commit: commit),
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), commit);
      await tester.tap(find.byType(Checkbox));
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(find.text('Easy'), findsOneWidget);
    });

    testWidgets('the memory profile: picked right, the four grades',
        (WidgetTester tester) async {
      Grade? got;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async => got = await showDialog<Grade>(
              context: context,
              builder: (BuildContext _) => const ProfileDialog(
                labels: <String>['Basic', 'Advanced', 'Great Wall'],
                answer: 1,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Memory profile (m)'), findsOneWidget);
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Good'));
      await tester.pumpAndSettle();
      expect(got, Grade.good);
    });

    testWidgets('a count missed: the setup\'s shown, only Again',
        (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showDialog<Grade>(
              context: context,
              builder: (BuildContext _) =>
                  const CountDialog(factId: kStagesFact, answer: 3),
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Deep stages (N)'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '2');
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(find.textContaining('this setup\'s is 3'), findsOneWidget);
      expect(find.text('Good'), findsNothing);
      expect(find.text('Again'), findsOneWidget);
    });

    testWidgets('the maps studied: a wrong set shows the right one',
        (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showDialog<Grade>(
              context: context,
              builder: (BuildContext _) => const SelectionDialog(
                  stage: 1, maps: kMapsPerStage, studied: <int>{2, 5, 7}),
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Maps you study, stage 1'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilterChip, '2'));
      await tester.tap(find.widgetWithText(FilterChip, '5'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(find.textContaining('you study maps 2, 5, 7'), findsOneWidget);
      expect(find.text('Good'), findsNothing);
    });

    testWidgets('the maps studied: the right set takes the four grades',
        (WidgetTester tester) async {
      Grade? got;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async => got = await showDialog<Grade>(
              context: context,
              builder: (BuildContext _) => const SelectionDialog(
                  stage: 0, maps: kMapsPerStage, studied: <int>{1, 3}),
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, '3'));
      await tester.tap(find.widgetWithText(FilterChip, '1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hard'));
      await tester.pumpAndSettle();
      expect(got, Grade.hard);
    });

    testWidgets('salt by σ: a find takes the four grades',
        (WidgetTester tester) async {
      final List<int> o1 = List<int>.generate(64, (int i) => i);
      String hex(List<int> b) =>
          b.map((int v) => v.toRadixString(16).padLeft(2, '0')).join();
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showDialog<Grade>(
              context: context,
              builder: (BuildContext _) => SaltDialog(
                sigma: 'abcd',
                orbits: <List<int>?>[null, o1],
                harvest: (DateTime d) async => 'abcd',
                unbury: (String label, DateTime d) async => hex(o1),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('By σ'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'σ (hex)'), 'ABCD');
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(find.textContaining('this setup\'s σ'), findsOneWidget);
      expect(find.text('Good'), findsOneWidget);
    });
  });
}
