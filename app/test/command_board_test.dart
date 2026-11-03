import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/command/command_board.dart';
import 'package:great_wallet_app/src/command/keyboard_layout.dart';

/// The command board: keys by position, letters by layout; disabled commands
/// stay in place; hover and focus explain a button, and leaving restores.
void main() {
  test('every layout labels the twelve board keys', () {
    expect(kBoardKeys, hasLength(kBoardRows * kBoardColumns));
    for (final KeyboardLayout l in KeyboardLayout.values) {
      expect(l.keys, hasLength(kBoardKeys.length), reason: l.label);
    }
    expect(KeyboardLayout.azerty.keys.take(4), <String>['A', 'Z', 'E', 'R']);
    expect(kBoardKeys.first, PhysicalKeyboardKey.keyQ);
  });

  test('the build default is named, any case, else QWERTY', () {
    expect(KeyboardLayout.named('AZERTY'), KeyboardLayout.azerty);
    expect(KeyboardLayout.named('dvorak'), KeyboardLayout.dvorak);
    expect(KeyboardLayout.named('klingon'), KeyboardLayout.qwerty);
    expect(KeyboardLayout.named(''), KeyboardLayout.qwerty);
    expect(KeyboardLayout.qwerty.next, KeyboardLayout.azerty);
    expect(KeyboardLayout.colemak.next, KeyboardLayout.qwerty);
  });

  Widget host({
    required List<BoardCommand?> commands,
    KeyboardLayout layout = KeyboardLayout.qwerty,
    ValueChanged<String?>? onExplain,
    ValueChanged<CommandContext>? onContext,
    ValueChanged<String>? onCue,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: CommandBoard(
            active: CommandContext.main,
            commands: commands,
            layout: layout,
            colour: Colors.white,
            onContext: onContext ?? (_) {},
            onExplain: onExplain ?? (_) {},
            onCue: onCue ?? (_) {},
          ),
        ),
      );

  testWidgets('buttons carry their layout letters and run when enabled',
      (WidgetTester tester) async {
    int runs = 0;
    final List<BoardCommand?> commands = List<BoardCommand?>.filled(12, null)
      ..[0] = BoardCommand(
        name: 'First',
        help: 'Does the first thing.',
        icon: Icons.save,
        run: () => runs++,
      )
      ..[1] = BoardCommand(
        name: 'Second',
        help: 'Not now.',
        icon: Icons.key,
        enabled: false,
        run: () => runs += 100,
      );
    await tester.pumpWidget(
      host(commands: commands, layout: KeyboardLayout.azerty),
    );
    // AZERTY prints A and Z on the first two keys (the Q and W positions).
    expect(find.text('A'), findsWidgets);
    expect(find.text('Z'), findsWidgets);
    await tester.tap(find.byIcon(Icons.save));
    await tester.tap(find.byIcon(Icons.key));
    expect(runs, 1, reason: 'the disabled command does not run');
  });

  testWidgets('hover explains a button; leaving restores',
      (WidgetTester tester) async {
    final List<String?> explained = <String?>[];
    final List<BoardCommand?> commands = List<BoardCommand?>.filled(12, null)
      ..[5] = BoardCommand(
        name: 'Fifth',
        help: 'Explains itself.',
        icon: Icons.save,
        run: () {},
      );
    await tester.pumpWidget(
      host(commands: commands, onExplain: explained.add),
    );
    final TestGesture mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byIcon(Icons.save)));
    await tester.pump();
    expect(explained.last, contains('Fifth (S)'));
    expect(explained.last, contains('Explains itself.'));
    await mouse.moveTo(const Offset(1000, 1000));
    await tester.pump();
    expect(explained.last, isNull);
  });

  testWidgets('pressing and hovering a button voice its cues',
      (WidgetTester tester) async {
    final List<String> cues = <String>[];
    final List<BoardCommand?> commands = List<BoardCommand?>.filled(12, null)
      ..[0] = BoardCommand(
        name: 'First',
        help: 'Voiced.',
        icon: Icons.save,
        run: () {},
      ).withCue('main.first')
      ..[1] = BoardCommand(
        name: 'Second',
        help: 'Not now.',
        icon: Icons.key,
        enabled: false,
        run: () {},
      ).withCue('main.second');
    await tester.pumpWidget(host(commands: commands, onCue: cues.add));
    final TestGesture mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    // Off the board, so the way in crosses nothing else.
    await mouse.addPointer(location: const Offset(1000, 1000));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byIcon(Icons.save)));
    await tester.pump();
    expect(cues, <String>['$kCueHover.main.first']);
    await tester.tap(find.byIcon(Icons.save));
    expect(cues.last, '$kCuePress.main.first');
    cues.clear();
    await tester.tap(find.byIcon(Icons.key));
    expect(cues, isNot(contains('$kCuePress.main.second')),
        reason: 'a disabled button is not pressed');
    await mouse.moveTo(tester.getCenter(find.byIcon(CommandContext.path.icon)));
    await tester.pump();
    expect(cues.last, '$kCueHover.${contextTabCue(CommandContext.path)}');
  });

  testWidgets('a tab switches context', (WidgetTester tester) async {
    CommandContext? picked;
    await tester.pumpWidget(host(
      commands: List<BoardCommand?>.filled(12, null),
      onContext: (CommandContext c) => picked = c,
    ));
    await tester.tap(find.byIcon(CommandContext.path.icon));
    expect(picked, CommandContext.path);
  });

  testWidgets('the drawn glyphs paint', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Row(
        children: <Widget>[
          HopGlyph(spread: true, colour: Colors.white),
          HopGlyph(spread: false, colour: Colors.white),
          D20Glyph(colour: Colors.white),
        ],
      ),
    ));
    expect(find.byType(HopGlyph), findsNWidgets(2));
    expect(find.byType(D20Glyph), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
