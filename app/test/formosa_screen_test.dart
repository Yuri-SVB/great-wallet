import 'dart:convert';
import 'dart:io';

import 'package:celestial_peace_nf_core/celestial_peace_nf_core.dart'
    show MemCard;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formosa/formosa.dart' as formosa;
import 'package:formosa/io.dart';
import 'package:great_wallet_app/src/command/command_board.dart';
import 'package:great_wallet_app/src/formosa/formosa_screen.dart';
import 'package:great_wallet_app/src/formosa/pass_vault.dart';

/// F4: a vault created from six generated sentences and a provisional key,
/// an entry added, locked, then opened again with four of them, and with the
/// key; the key retired at the green light, and a new one added; the entry
/// copied into a second vault — through the board, as F2 and F3's, in a
/// 1280 × 800 window with nothing scrolled to. Argon2id runs for real, light.
void main() {
  final formosa.ThemeSet themes = loadThemes(Directory('../formosa/themes'));
  const KdfParams light =
      KdfParams(memoryKiB: 64, iterations: 1, parallelism: 1);
  const String keyHex = 'a0a1a2a3a4a5a6a7a8a9aaabacadaeaf';

  testWidgets('create, add, lock, open with 4 of 6',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
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

    // A board command, by its name; run in context [c] (its tab first).
    Finder command(String name) => find.byWidgetPredicate(
        (Widget w) => w is Semantics && w.properties.label == name);
    bool enabled(String name) =>
        tester
            .widget<InkWell>(find.ancestor(
                of: command(name), matching: find.byType(InkWell)))
            .onTap !=
        null;
    Future<void> run(CommandContext c, String name) async {
      await tester.tap(find.descendant(
          of: find.byType(CommandBoard), matching: find.byIcon(c.icon)));
      await tester.pump();
      expect(enabled(name), isTrue, reason: name);
      await tester.tap(command(name));
      await tester.pump();
    }

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FormosaScreen(themes: themes, kdf: light)),
    ));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Vault file'), path);
    await run(CommandContext.vault, 'New vault');
    await tester.pumpAndSettle();
    expect(find.textContaining('Any 4 of 6 sentences open it: 132 bits'),
        findsOneWidget);

    // Six sentences, one theme each, from the system's randomness.
    for (int i = 0; i < 6; i++) {
      await tester.tap(find.byTooltip('System random').at(i));
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
    final Finder keyDialog = find.text('Provisional key — 128-bit');
    for (int i = 0; i < 10 && keyDialog.evaluate().isEmpty; i++) {
      await settle();
    }
    // The provisional key: a key of our own, typed, reseals the vault.
    expect(keyDialog, findsOneWidget);
    expect(find.textContaining('Vault created'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(
            TextField, 'Your own key — 32 or 64 hex digits (optional)'),
        keyHex);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await settle();
    expect(find.textContaining('Re-saved with your own 128-bit key'),
        findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(CommandBoard),
        matching: find.byIcon(CommandContext.vault.icon)));
    await tester.pump();
    expect(find.textContaining('not yet.'), findsOneWidget,
        reason: 'no sentence graded: the gate is shut');
    expect(enabled('Retire the provisional key'), isFalse);

    // F1 folds the panel away, and back.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.pump();
    expect(find.byType(CommandBoard), findsNothing);
    expect(find.byTooltip('Restore (F1)'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.pump();
    expect(find.byType(CommandBoard), findsOneWidget);
    final VaultHeader h = PassVault.header(File(path).readAsBytesSync());
    expect(h.n, 6);
    expect(h.k, 4);
    expect(h.slots.map((VaultSlot s) => s.theme).toSet(), hasLength(6),
        reason: 'one theme per sentence');

    // An entry, typed in: Alt+W picks the Entries board, Q adds.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Label'), 'Mail');
    await tester.enterText(
        find.widgetWithText(TextField, 'Login (optional)'), 'alice');
    await tester.enterText(
        find.widgetWithText(TextField, 'Secret (typed, or generated below)'),
        'hunter2');
    await tester.tap(find.text('Add'));
    await tester.pump();
    await settle();
    expect(find.text('Mail'), findsWidgets);
    expect(find.textContaining('alice'), findsWidgets, reason: 'its login');
    expect(find.textContaining('hunter2'), findsNothing,
        reason: 'hidden until shown');
    await run(CommandContext.entries, 'Copy login');
    await settle();
    expect(find.textContaining("Mail's login: copied"), findsOneWidget);

    // Edited: a new login, the same secret.
    await run(CommandContext.entries, 'Edit entry');
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Login (optional)'), 'bob');
    await tester.enterText(
        find.widgetWithText(TextField, 'Folder (optional, e.g. Work/Mail)'),
        ' Work / /Mail/ ');
    await tester.tap(find.text('Save'));
    await tester.pump();
    await settle();
    expect(find.textContaining('bob'), findsWidgets);
    expect(find.textContaining('alice'), findsNothing);
    expect(find.textContaining('in Work/Mail'), findsOneWidget,
        reason: 'its folder, normalised');

    // Right and Left step through the folders: all, Work, Work/Mail.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    for (int i = 0; i < 2; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
    }
    expect(
        tester
            .widget<ListTile>(find.ancestor(
                of: find.byIcon(Icons.folder).last,
                matching: find.byType(ListTile)))
            .selected,
        isTrue,
        reason: 'the folder Work/Mail, last in its pane');
    expect(find.textContaining('in Work/Mail'), findsNothing,
        reason: 'listed in its own folder');
    for (int i = 0; i < 2; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
    }
    expect(find.textContaining('in Work/Mail'), findsOneWidget,
        reason: 'all entries again');

    // Locked, then opened with sentences 1, 2, 4 and 6.
    await run(CommandContext.vault, 'Lock');
    await tester.pumpAndSettle();
    await run(CommandContext.vault, 'Open');
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
    expect(find.text('Mail'), findsWidgets);
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

    // Next due: first the sentences never graded (3 and 5) — 3 typed from
    // memory and graded, 5 shown (so Again); then the entry, memorised.
    final Finder inDialog = find.byType(AlertDialog);
    final List<int> reviewed = <int>[];
    for (int i = 0; i < 2; i++) {
      await run(CommandContext.vault, 'Next due');
      await tester.pumpAndSettle();
      final String title = tester
          .widget<Text>(find.descendant(
              of: inDialog,
              matching: find.textContaining(RegExp(r'^Sentence \d \('))))
          .data!;
      final int slot = int.parse(title.split(' ')[1]);
      reviewed.add(slot);
      if (slot == 5) {
        // Shown: the sentence on screen, and Again the only way out.
        await tester.tap(find.text('Show'));
        await tester.pumpAndSettle();
        expect(find.textContaining('It is: ${sentences[4]}'), findsOneWidget);
        expect(find.text('Good'), findsNothing);
        await tester.tap(find.text('Again'));
        await tester.pump();
        await settle();
        expect(
            find.textContaining('Sentence 5: graded again.'), findsOneWidget);
        expect(now().cardOf(5)!.lapses, 1);
        continue;
      }
      await tester.enterText(
          find.descendant(of: inDialog, matching: find.byType(TextField)),
          sentences[slot - 1]);
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Good'));
      await tester.pump();
      await settle();
      expect(
          find.textContaining('Sentence $slot: graded good.'), findsOneWidget);
      expect(now().cardOf(slot)!.repetitions, 1);
    }
    expect(reviewed..sort(), <int>[3, 5]);
    await run(CommandContext.entries, 'Memorise');
    await settle();
    await run(CommandContext.vault, 'Next due');
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Secret'), 'hunter2');
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Good'));
    await tester.pump();
    await settle();
    expect(find.textContaining('Mail: graded good.'), findsOneWidget);

    // A sentence added (C(7, 4) wrappings), then retired again.
    await run(CommandContext.sentences, 'New sentence (system random)');
    await run(CommandContext.sentences, 'Keep the new sentence, and rewrap');
    final Finder added = find.textContaining('Sentence 7 added');
    for (int i = 0; i < 10 && added.evaluate().isEmpty; i++) {
      await settle();
    }
    expect(added, findsOneWidget);
    expect(now().n, 7);
    expect(now().wraps, hasLength(35));
    await tester.tap(find.textContaining('Sentence 7 ('));
    await tester.pump();
    await run(CommandContext.sentences, 'Retire the sentence');
    for (int i = 0; i < 10 && now().n != 6; i++) {
      await settle();
    }
    expect(now().n, 6);
    expect(now().cardOf(7), isNull);

    // Opened again the same day, sentence 3 wrong: Again; the others, not
    // due yet, are graded too, for partial credit (next to none so soon).
    await run(CommandContext.vault, 'Lock');
    await tester.pumpAndSettle();
    await run(CommandContext.vault, 'Open');
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
    expect(find.textContaining('(early: partial credit)'), findsNWidgets(4));
    for (int row = 0; row < 4; row++) {
      await tester.tap(find.text('Good').at(row));
    }
    await tester.pump();
    await tester.tap(done);
    await tester.pump();
    await settle();
    expect(find.textContaining('Sentence 3 not the vault\'s: graded again.'),
        findsOneWidget);
    expect(find.textContaining('Sentences 1, 2, 4, 6 graded good.'),
        findsOneWidget);
    expect(now().cardOf(3)!.lapses, 1);
    expect(now().cardOf(1)!.repetitions, 1,
        reason: 'an early success keeps its run');
    expect(now().cardOf(1)!.intervalDays, closeTo(1, 0.01),
        reason: 'minutes after a review, next to no credit');

    // Opened with the provisional key alone: nothing graded.
    final List<String> before = <String>[
      for (final MemCard c in now().cards) jsonEncode(c.toJson()),
    ];
    await run(CommandContext.vault, 'Lock');
    await tester.pumpAndSettle();
    await run(CommandContext.vault, 'Open');
    await settle();
    await run(CommandContext.vault, 'Open with the provisional key');
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Key — 32 or 64 hex digits'), keyHex);
    await tester.tap(find.widgetWithText(FilledButton, 'Open').last);
    await tester.pump();
    for (int i = 0; i < 10 && find.text('Mail').evaluate().isEmpty; i++) {
      await settle();
    }
    expect(find.text('Mail'), findsWidgets);
    expect(find.textContaining('no sentence is graded'), findsOneWidget);
    expect(<String>[
      for (final MemCard c in now().cards) jsonEncode(c.toJson()),
    ], before);
    await run(CommandContext.vault, 'Next due');
    expect(find.textContaining('Nothing is due.'), findsOneWidget,
        reason: 'every card reviewed today');

    // ε set to 100 % for this vault: the green light, and the key retired;
    // then a new one.
    await run(CommandContext.vault, 'T and ε');
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'T (days)'), '3');
    await tester.enterText(find.widgetWithText(TextField, 'ε (%)'), '100');
    await tester.pump();
    expect(
        find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('green light.')),
        findsOneWidget,
        reason: 'previewed as typed');
    await tester.tap(find.text('Set'));
    await tester.pump();
    await settle();
    expect(now().gapSeconds, const Duration(days: 3).inSeconds);
    expect(now().epsilon, 1);
    expect(find.textContaining('green light.'), findsOneWidget);
    await run(CommandContext.vault, 'Retire the provisional key');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retire it'));
    await tester.pump();
    final Finder retired = find.textContaining('Provisional key retired');
    for (int i = 0; i < 10 && retired.evaluate().isEmpty; i++) {
      await settle();
    }
    expect(retired, findsOneWidget);
    expect(now().provisional, isNull);
    await run(CommandContext.vault, 'Add a provisional key');
    for (int i = 0; i < 10 && keyDialog.evaluate().isEmpty; i++) {
      await settle();
    }
    expect(keyDialog, findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(now().provisional, isNotNull);

    // Mail held, the vault locked, a second vault made: Mail pasted into it.
    await run(CommandContext.entries, 'Hold to copy');
    expect(find.textContaining('1 entry held'), findsOneWidget);
    expect(enabled('Paste held entries'), isFalse, reason: 'its own vault');
    await run(CommandContext.vault, 'Lock');
    await tester.pumpAndSettle();
    expect(find.textContaining('1 entry held'), findsOneWidget,
        reason: 'held across the lock');
    final String path2 = '${dir.path}/other.vault';
    await tester.enterText(find.widgetWithText(TextField, 'Vault file'), path2);
    await run(CommandContext.vault, 'New vault');
    await tester.pumpAndSettle();
    for (int i = 0; i < 6; i++) {
      await tester.tap(find.byTooltip('System random').at(i));
      await tester.pump();
    }
    await tester.tap(find.text('Create'));
    await tester.pump();
    for (int i = 0; i < 10 && keyDialog.evaluate().isEmpty; i++) {
      await settle();
    }
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Mail'), findsNothing);
    await run(CommandContext.entries, 'Paste held entries');
    await settle();
    expect(find.text('Mail'), findsWidgets);
    expect(find.textContaining('1 entry copied from $path.'), findsOneWidget);
    expect(find.textContaining('in Work/Mail'), findsOneWidget,
        reason: 'the folder travels');
    expect(find.textContaining('held'), findsNothing, reason: 'pasted once');
  });
}
