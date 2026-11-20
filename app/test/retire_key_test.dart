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
import 'package:great_wallet_app/src/setup/fact_cards.dart';
import 'package:great_wallet_app/src/setup/orbit_vault.dart';
import 'package:great_wallet_app/src/setup/setup_crypto.dart';
import 'package:great_wallet_app/src/setup/setup_screen.dart';
import 'package:great_wallet_app/src/setup/stage0_bundle.dart';

/// Retiring the provisional key from Graduation's green light seals stage 0's
/// bundle next to the setup file — σ and stage 0's records under `Sh₀`
/// hardened — before the wipe; the bundle then opens with stage 0's points.
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
  const List<(int, int)> points = <(int, int)>[(1, 0x13572468), (2, 0x2468ACE0)];

  testWidgets('the green light retires the key: stage 0 is sealed first', (
    WidgetTester tester,
  ) async {
    final GreatWallCore? c = core;
    if (c == null) {
      markTestSkipped('engine unavailable — $openError');
      return;
    }
    // --- a stage-0 setup, every map and fact held for years ------------------
    final OrbitProtocol protocol = OrbitProtocol(c);
    final Uint8List o0 = c.orbitRoot(_hex(sigmaHex));
    final List<OrbitVaultPoint> placed = <OrbitVaultPoint>[];
    for (final (int slot, int value) in points) {
      final ({int o, int p, int q}) prm = protocol.orbitParams(o0, slot - 1);
      final EncodedPoint pt = await tester.runAsync(() async => c
          .encodeStage(_chunk(value), o: prm.o, p: prm.p, q: prm.q)
          .first) as EncodedPoint;
      placed.add(OrbitVaultPoint(slot: slot, reRaw: pt.reRaw, imRaw: pt.imRaw));
    }
    final Cues unaided = Cues(
      rhoNum: c.landmarkParams.rhoNum,
      rhoDen: c.landmarkParams.rhoDen,
      exponent: c.landmarkParams.badnessExponent,
      visible: 0,
    );
    const int heldDays = 100000; // recall after a week ≈ 99.999%
    MemCard held(MemCard card) => card.copyWith(
          repetitions: 5,
          intervalDays: heldDays,
          due: DateTime.now().add(const Duration(days: heldDays)),
        );
    final Deck deck = Deck(<MemCard>[
      for (final (int slot, int _) in points) held(MemCard.map(0, slot, unaided)),
      for (final String id in <String>[
        kSaltFact,
        ...kParameterFacts,
        selectionFact(0),
      ])
        held(MemCard.fact(id)),
    ]);
    final OrbitVault vault = OrbitVault(
      sigma: sigmaHex,
      iterations: 4,
      profile: Argon2Profile.basic,
      stages: <OrbitVaultStage>[
        OrbitVaultStage(required: 2, orbit: null, points: placed),
      ],
      deck: deck,
      studied: const <List<int>>[<int>[1, 2]],
    );
    final Directory dir = Directory.systemTemp.createTempSync('gw-retire');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/setup.gwvault';
    await tester.runAsync(() async {
      final SealedVault sealed =
          await SetupCrypto.sealPayload(vault.toJson(), providedKey: key);
      File(path).writeAsBytesSync(sealed.fileBytes);
    });

    // --- the screen --------------------------------------------------------
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
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SetupScreen(core: c)),
    ));
    await tester.pump();

    Future<void> settle() async {
      for (int i = 0; i < 40; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    // Open the file (Main board › E), then Train (F3).
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'File path'), path);
    await tester.enterText(
        find.widgetWithText(TextField, 'Key — 32 or 64 hex digits'), keyHex);
    await tester.tap(find.widgetWithText(FilledButton, 'Load'));
    await tester.pump();
    await settle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f3);
    await tester.pump();

    // Graduation (Train board › X): the green light, and the retirement.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pumpAndSettle();
    for (final Text t in tester.widgetList<Text>(find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(Text)))) {
      debugPrint('DIALOG: ${t.data}');
    }
    expect(
        find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('Green light')),
        findsOneWidget);
    await tester.tap(find.text('Retire the provisional key…'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Stage 0 bundle file'),
        findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'D (passes)'), '1');
    await tester.tap(find.text('Seal stage 0'));
    await tester.pump();
    for (int i = 0; i < 30 && find.text('Wipe everything').evaluate().isEmpty;
        i++) {
      await settle();
    }
    // The wipe comes next; leave it.
    expect(find.text('Wipe everything'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // --- the bundle: θ₀, m and D in the clear; stage 0's points open it ------
    final Uint8List file =
        File('$path$kStage0Suffix').readAsBytesSync();
    final Stage0Header header = Stage0Bundle.header(file);
    expect(header.passes, 1);
    expect(header.profile, Argon2Profile.basic);
    expect(header.theta.first, c.theta(o0, 0));
    final Uint8List sh = GreatWallCoreBindings.shToBytes(c.shamirInterp(
        <int>[for (final (int slot, int _) in points) slot],
        <int>[for (final (int _, int value) in points) value]));
    final Stage0Contents? back = await tester.runAsync(() => Stage0Bundle.open(
        file,
        sh,
        (Uint8List input, Argon2Profile p, int n) =>
            c.hardenKey(input, profile: p, passes: n)));
    expect(back!.sigma, sigmaHex);
    expect(back.studied, <int>[1, 2]);
    expect(back.cards.map((MemCard m) => m.id),
        containsAll(<String>['point:0:1', 'point:0:2', 'fact:${selectionFact(0)}']));
    expect(File(path).existsSync(), isTrue, reason: 'the wipe was left');

    // --- without the key: open the bundle, recall 2 maps, σ comes back -------
    String log() => tester
        .widgetList<Text>(find.byType(Text))
        .map((Text t) => t.data ?? '')
        .join('\n');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'File path'), '$path$kStage0Suffix');
    await tester.tap(find.widgetWithText(FilledButton, 'Load'));
    await tester.pump();
    await settle();
    expect(log(), contains('its maps show from its clear part'));
    // Setup board (Alt+W) › place by click (F), on maps 1 and 2.
    for (final OrbitVaultPoint pt in placed) {
      await tester.sendKeyEvent(pt.slot == 1
          ? LogicalKeyboardKey.digit1
          : LogicalKeyboardKey.digit2);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
      tester.widget<FractalCanvas>(find.byType(FractalCanvas)).onSelect!(
          FractalSelection(
              re: fixedToDouble(pt.reRaw),
              im: fixedToDouble(pt.imRaw),
              pixelX: 0,
              pixelY: 0));
      await tester.pump();
    }
    for (int i = 0; i < 30 && !log().contains('bundle is open'); i++) {
      await settle();
    }
    expect(log(), contains('bundle is open'));
    // Train (F3) › save progress (Z) reseals it, with no new derivation.
    await tester.sendKeyEvent(LogicalKeyboardKey.f3);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.pump();
    await settle();
    expect(log(), contains('bundle resealed'));
    final Stage0Contents? again = await tester.runAsync(() => Stage0Bundle.open(
        File('$path$kStage0Suffix').readAsBytesSync(),
        sh,
        (Uint8List input, Argon2Profile p, int n) =>
            c.hardenKey(input, profile: p, passes: n)));
    expect(again!.sigma, sigmaHex);
    expect(again.cards.map((MemCard m) => m.id), contains('fact:$kSaltFact'));

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
