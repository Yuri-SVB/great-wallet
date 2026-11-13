import 'dart:io';

import 'package:celestial_peace_nf_core/celestial_peace_nf_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:great_wall_ux/great_wall_ux.dart';
import 'package:great_wallet_app/src/core/great_wall_core.dart';
import 'package:great_wallet_app/src/core/orbit_protocol.dart';
import 'package:great_wallet_app/src/ffi/core_bindings.dart';
import 'package:great_wallet_app/src/ffi/fixed.dart';
import 'package:great_wallet_app/src/ffi/library_loader.dart';
import 'package:great_wallet_app/src/setup/orbit_vault.dart';
import 'package:great_wallet_app/src/setup/setup_crypto.dart';
import 'package:great_wallet_app/src/setup/setup_screen.dart';

/// Train mode (F3) on the real screen, with the engine linked: a stage-0
/// setup whose map 1 is graded (no stop shown) and map 2 practice (stops
/// shown) is opened, its points stay hidden while recalled, a find is graded
/// and saved back into the file under the same key.
void main() {
  GreatWallCore? core;
  String? openError;

  setUpAll(() {
    try {
      core = GreatWallCore.open();
    } on CoreLibraryNotFound catch (e) {
      openError = e.toString();
    } on ArgumentError catch (e) {
      openError = 'engine library unusable: $e';
    } on StateError catch (e) {
      openError = 'engine ABI mismatch: $e';
    }
  });

  const String sigmaHex = 'A1B2C3D4E5F60718293A4B5C6D7E8F90';
  const String keyHex = 'a0a1a2a3a4a5a6a7a8a9aaabacadaeaf';
  final Uint8List key =
      Uint8List.fromList(List<int>.generate(16, (int i) => 0xA0 + i));

  testWidgets('recall hidden, a find graded, progress saved', (
    WidgetTester tester,
  ) async {
    final GreatWallCore? c = core;
    if (c == null) {
      markTestSkipped('engine unavailable — $openError');
      return;
    }
    // --- a stage-0 setup: maps 1 and 2 placed ------------------------------
    final OrbitProtocol protocol = OrbitProtocol(c);
    final Uint8List o0 = c.orbitRoot(_hex(sigmaHex));
    final List<({int slot, int reRaw, int imRaw})> placed =
        <({int slot, int reRaw, int imRaw})>[];
    for (final (int slot, int value) in <(int, int)>[
      (1, 0x13572468),
      (2, 0x2468ACE0),
    ]) {
      final ({int o, int p, int q}) prm = protocol.orbitParams(o0, slot - 1);
      final EncodedPoint pt = await tester.runAsync(() async => c
          .encodeStage(_chunk(value), o: prm.o, p: prm.p, q: prm.q)
          .first) as EncodedPoint;
      placed.add((slot: slot, reRaw: pt.reRaw, imRaw: pt.imRaw));
    }
    final Cues unaided = Cues(
      rhoNum: c.landmarkParams.rhoNum,
      rhoDen: c.landmarkParams.rhoDen,
      exponent: c.landmarkParams.badnessExponent,
      visible: 0,
    );
    final Deck deck = buildDeck(maps: <List<int>>[<int>[1, 2]], cues: unaided)
        .withCard(MemCard.map(0, 2, unaided.withVisible(null)));
    final OrbitVault vault = OrbitVault(
      sigma: sigmaHex,
      iterations: 4,
      profile: Argon2Profile.basic,
      stages: <OrbitVaultStage>[
        OrbitVaultStage(
          required: 2,
          orbit: null,
          points: <OrbitVaultPoint>[
            for (final ({int slot, int reRaw, int imRaw}) p in placed)
              OrbitVaultPoint(slot: p.slot, reRaw: p.reRaw, imRaw: p.imRaw),
          ],
        ),
      ],
      deck: deck,
    );
    final Directory dir = Directory.systemTemp.createTempSync('gw-train');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/setup.gwvault';
    await tester.runAsync(() async {
      final SealedVault sealed =
          await SetupCrypto.sealPayload(vault.toJson(), providedKey: key);
      File(path).writeAsBytesSync(sealed.fileBytes);
    });

    // --- the screen --------------------------------------------------------
    // No audio or app folders under test: their platform calls succeed
    // silently.
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.allMessagesHandler =
        (String channel, MessageHandler? handler, ByteData? message) async {
      if (handler != null) return handler(message);
      if (channel.startsWith('xyz.luan/audioplayers') ||
          channel.contains('path_provider')) {
        return const StandardMethodCodec().encodeSuccessEnvelope(null);
      }
      return null;
    };
    addTearDown(() => messenger.allMessagesHandler = null);
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    bool? trainingTold;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SetupScreen(
          core: c,
          onTrainingChanged: (bool t) => trainingTold = t,
        ),
      ),
    ));
    await tester.pump();

    Future<void> settle() async {
      for (int i = 0; i < 40; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    String log() => tester
        .widgetList<Text>(find.byType(Text))
        .map((Text t) => t.data ?? '')
        .join('\n');

    // Open the file: Main board › File path (F), the path, Open (E), the key.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();
    await tester.enterText(
        find.widgetWithText(TextField, 'File path'), path);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Key — 32 or 64 hex digits'), keyHex);
    await tester.tap(find.widgetWithText(FilledButton, 'Load'));
    await tester.pump();
    await settle();
    expect(log(), contains('Setup loaded.'));

    // F3: Train, its board in Setup's place, the progress in the log.
    await tester.sendKeyEvent(LogicalKeyboardKey.f3);
    await tester.pump();
    expect(trainingTold, isTrue);
    expect(find.byIcon(Icons.school), findsOneWidget);
    expect(log(), contains('Stage 0: needs 2 maps; 2 in the deck'));

    FractalCanvas canvas() =>
        tester.widget<FractalCanvas>(find.byType(FractalCanvas));

    // Map 1 (graded): its point hidden while recalled.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pump();
    expect(canvas().overlays.crosses, isEmpty);
    expect(canvas().overlays.frames, isEmpty);

    // Train board (Alt+W) › Recall (W), then a click on the point's leaf.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.pump();
    expect(log(), contains('(graded)'));
    canvas().onSelect!(FractalSelection(
      re: fixedToDouble(placed[0].reRaw),
      im: fixedToDouble(placed[0].imRaw),
      pixelX: 0,
      pixelY: 0,
    ));
    await tester.pump();
    expect(log(), contains('Found it. Grade it'));
    // Found: the answer shows.
    expect(canvas().overlays.crosses.length +
        canvas().overlays.frames.length, 1);

    // Good (D).
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.pump();
    expect(log(), contains('Graded good: next review on '));

    // Again on map 1: practice now (graded this session), and a miss shows
    // the answer.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.pump();
    expect(canvas().overlays.crosses, isEmpty);
    expect(log(), contains('practice: graded already this session'));
    // A neighbouring leaf of map 1's point: valid, and not the answer.
    final ({int o, int p, int q}) prm1 = protocol.orbitParams(o0, 0);
    final CoreDecodeResult truth = c.decodePoint(
        reRaw: placed[0].reRaw,
        imRaw: placed[0].imRaw,
        o: prm1.o,
        p: prm1.p,
        q: prm1.q);
    final FixedRect leaf = truth.leafRect;
    ({double re, double im})? wrong;
    for (final (int dx, int dy) in <(int, int)>[(1, 0), (-1, 0), (0, 1), (0, -1)]) {
      final int re = (leaf.reMin + leaf.reMax) ~/ 2 + dx * (leaf.reMax - leaf.reMin);
      final int im = (leaf.imMin + leaf.imMax) ~/ 2 + dy * (leaf.imMax - leaf.imMin);
      final CoreDecodeResult d =
          c.decodePoint(reRaw: re, imRaw: im, o: prm1.o, p: prm1.p, q: prm1.q);
      if (d.valid && d.path != truth.path) {
        wrong = (re: fixedToDouble(re), im: fixedToDouble(im));
        break;
      }
    }
    expect(wrong, isNotNull, reason: 'a neighbouring leaf exists');
    canvas().onSelect!(FractalSelection(
      re: wrong!.re,
      im: wrong.im,
      pixelX: 0,
      pixelY: 0,
    ));
    await tester.pump();
    expect(log(), contains('Missed (practice: graded already this session)'));
    expect(canvas().overlays.crosses.length +
        canvas().overlays.frames.length, 1);

    // Map 2 (practice): showing the answer grades nothing.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    expect(canvas().overlays.crosses, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pump();
    expect(log(), contains('The answer is shown.'));

    // Save progress (Z) under the same key.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Key — 32 or 64 hex digits'), keyHex);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    await settle();
    expect(log(), contains('Training progress saved, under the same key.'));

    // The file now holds map 1's review; map 2's schedule is untouched.
    final Deck? saved = await tester.runAsync<Deck?>(() async =>
        OrbitVault.fromJson(await SetupCrypto.openPayload(
                File(path).readAsBytesSync(), key))
            .deck);
    expect(saved!.map(0, 1)!.repetitions, 1);
    expect(saved.map(0, 1)!.due, isNotNull);
    expect(saved.map(0, 2)!.due, isNull);

    // F2: back to Setup.
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pump();
    expect(trainingTold, isFalse);
    expect(find.byIcon(Icons.tune), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await settle();
  }, timeout: const Timeout(Duration(minutes: 10)));
}

List<int> _chunk(int value) =>
    <int>[for (int i = 31; i >= 0; i--) (value >> i) & 1];

Uint8List _hex(String s) => Uint8List.fromList(<int>[
      for (int i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);
