import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formosa/formosa.dart' as formosa;
import 'package:formosa/io.dart';
import 'package:great_wallet_app/src/formosa/formosa_screen.dart';
import 'package:great_wallet_app/src/formosa/pass_vault.dart';

/// F4: a vault created from six generated sentences, an entry added, locked,
/// then opened again with four of them. Argon2id runs for real, light.
void main() {
  final formosa.ThemeSet themes = loadThemes(Directory('../formosa/themes'));
  const KdfParams light =
      KdfParams(memoryKiB: 64, iterations: 1, parallelism: 1);

  testWidgets('create, add, lock, open with 4 of 6',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Directory dir = Directory.systemTemp.createTempSync('gw-formosa');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/passwords.vault';

    Future<void> settle() async {
      for (int i = 0; i < 20; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FormosaScreen(themes: themes, kdf: light)),
    ));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Vault file'), path);
    await tester.tap(find.text('New vault'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Any 4 of 6 sentences open it: 132 bits'),
        findsOneWidget);

    // Six sentences, one theme each, from the system's randomness.
    for (int i = 0; i < 6; i++) {
      await tester.tap(find.text('System random').at(i));
      await tester.pump();
    }
    final List<String> sentences = <String>[
      for (final SelectableText t
          in tester.widgetList<SelectableText>(find.byType(SelectableText)))
        t.data!,
    ];
    expect(sentences, hasLength(6));
    await tester.tap(find.text('Create'));
    await tester.pump();
    for (int i = 0; i < 10 && find.text('Add entry').evaluate().isEmpty; i++) {
      await settle();
    }
    expect(find.textContaining('Vault created'), findsOneWidget);
    final VaultHeader h = PassVault.header(File(path).readAsBytesSync());
    expect(h.n, 6);
    expect(h.k, 4);
    expect(h.slots.map((VaultSlot s) => s.theme).toSet(), hasLength(6),
        reason: 'one theme per sentence');

    // An entry, typed in.
    await tester.tap(find.text('Add entry'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Label'), 'Mail');
    await tester.enterText(
        find.widgetWithText(TextField, 'Secret (typed, or generated below)'),
        'hunter2');
    await tester.tap(find.text('Add'));
    await tester.pump();
    await settle();
    expect(find.text('Mail'), findsOneWidget);
    expect(find.text('hunter2'), findsNothing, reason: 'hidden until shown');

    // Locked, then opened with sentences 1, 2, 4 and 6.
    await tester.tap(find.text('Lock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pump();
    await settle();
    for (final int i in <int>[0, 1, 3, 5]) {
      await tester.enterText(
          find.byWidgetPredicate((Widget w) =>
              w is TextField &&
              (w.decoration?.labelText ?? '').startsWith('Sentence ${i + 1} ')),
          sentences[i]);
    }
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Open'));
    await tester.pump();
    Future<void> grading() async {
      for (int i = 0;
          i < 10 && find.text('Grade the sentences').evaluate().isEmpty;
          i++) {
        await settle();
      }
      expect(find.text('Grade the sentences'), findsOneWidget);
    }

    // You grade the four entered (new cards are due); 3 and 5 are not.
    await grading();
    final Finder done = find.widgetWithText(FilledButton, 'Done');
    expect(tester.widget<FilledButton>(done).onPressed, isNull,
        reason: 'every one graded first');
    await tester.tap(find.text('Hard').at(0));
    for (final int row in <int>[1, 2, 3]) {
      await tester.tap(find.text('Good').at(row));
    }
    await tester.pump();
    await tester.tap(done);
    await tester.pump();
    await settle();
    expect(find.text('Mail'), findsOneWidget);
    expect(
        find.textContaining('Sentences 2, 4, 6 graded good.'), findsOneWidget);
    expect(find.textContaining('Sentence 1 graded hard.'), findsOneWidget);
    VaultHeader now() => PassVault.header(File(path).readAsBytesSync());
    for (final int id in <int>[1, 2, 4, 6]) {
      expect(now().cardOf(id)!.repetitions, 1, reason: 'sentence $id');
    }
    for (final int id in <int>[3, 5]) {
      expect(now().cardOf(id)!.due, isNull, reason: 'sentence $id');
    }

    // The entry memorised, then reviewed through Next due.
    await tester.tap(find.byTooltip('Memorise it (a CPNF card)'));
    await tester.pump();
    await settle();
    await tester.tap(find.text('Next due'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Secret'), 'hunter2');
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Good'));
    await tester.pump();
    await settle();
    expect(find.textContaining('Mail: graded good.'), findsOneWidget);

    // A sentence added (C(7, 4) wrappings), then retired again.
    await tester.tap(find.text('System random'));
    await tester.pump();
    await tester.tap(find.text('Keep it, and rewrap'));
    await tester.pump();
    for (int i = 0; i < 10 && now().n != 7; i++) {
      await settle();
    }
    expect(now().n, 7);
    expect(now().wraps, hasLength(35));
    expect(find.textContaining('Sentence 7 added'), findsOneWidget);
    await tester.tap(find.text('Retire').last);
    await tester.pump();
    for (int i = 0; i < 10 && now().n != 6; i++) {
      await settle();
    }
    expect(now().n, 6);
    expect(now().cardOf(7), isNull);

    // Opened again the same day, sentence 3 wrong: Again; the others, just
    // graded, are not due — practice.
    await tester.tap(find.text('Lock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pump();
    await settle();
    final String wrong3 = themes[now().slots[2].theme].generateRaw();
    final Map<int, String> typed = <int, String>{
      1: sentences[0],
      2: sentences[1],
      3: wrong3 == sentences[2] ? sentences[4] : wrong3,
      4: sentences[3],
      6: sentences[5],
    };
    for (final MapEntry<int, String> e in typed.entries) {
      await tester.enterText(
          find.byWidgetPredicate((Widget w) =>
              w is TextField &&
              (w.decoration?.labelText ?? '').startsWith('Sentence ${e.key} ')),
          e.value);
    }
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Open'));
    await tester.pump();
    await grading();
    expect(find.textContaining('not the vault\'s: Again'), findsOneWidget);
    expect(find.text('Good'), findsNothing,
        reason: 'a wrong one is only Again');
    await tester.tap(done);
    await tester.pump();
    await settle();
    expect(find.textContaining('Sentence 3 not the vault\'s: graded again.'),
        findsOneWidget);
    expect(find.textContaining('Sentences 1, 2, 4, 6 not due yet: practice.'),
        findsOneWidget);
    expect(now().cardOf(3)!.lapses, 1);
    expect(now().cardOf(1)!.repetitions, 1, reason: 'practice moves nothing');
  });
}
