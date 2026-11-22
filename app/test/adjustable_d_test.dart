import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/core/great_wall_core.dart';
import 'package:great_wallet_app/src/core/orbit_protocol.dart';
import 'package:great_wallet_app/src/ffi/core_bindings.dart';
import 'package:great_wallet_app/src/ffi/library_loader.dart';
import 'package:great_wallet_app/src/setup/orbit_vault.dart';
import 'package:great_wallet_app/src/setup/setup_crypto.dart';
import 'package:great_wallet_app/src/setup/setup_screen.dart';

/// D adjusted mid-flight, on the real screen with the engine linked: the
/// advance into stage 1 is halted after two of three passes and stopped there
/// (D = 2, at once); the setup is written with the passes kept; D raised to 3
/// runs one pass only, lowered to 1 lands at once; stage 1's first point
/// confirms D and drops the passes.
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
  const int passes = 3;
  const int halted = 2;

  testWidgets('D changes mid-flight; the passes kept make it cheap', (
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
    final List<OrbitVaultPoint> points = <OrbitVaultPoint>[];
    for (final (int slot, int value) in <(int, int)>[
      (1, 0x13572468),
      (2, 0x2468ACE0),
    ]) {
      final ({int o, int p, int q}) prm = protocol.orbitParams(o0, slot - 1);
      final EncodedPoint pt = await tester.runAsync(() async => c
          .encodeStage(_chunk(value), o: prm.o, p: prm.p, q: prm.q)
          .first) as EncodedPoint;
      points.add(OrbitVaultPoint(slot: slot, reRaw: pt.reRaw, imRaw: pt.imRaw));
    }
    final OrbitVault vault = OrbitVault(
      sigma: sigmaHex,
      iterations: passes,
      profile: Argon2Profile.basic,
      stages: <OrbitVaultStage>[
        OrbitVaultStage(required: 2, orbit: null, points: points),
      ],
    );
    final Directory dir = Directory.systemTemp.createTempSync('gw-adjust-d');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/setup.gwvault';
    await tester.runAsync(() async {
      final SealedVault sealed =
          await SetupCrypto.sealPayload(vault.toJson(), providedKey: key);
      File(path).writeAsBytesSync(sealed.fileBytes);
    });

    // --- the screen --------------------------------------------------------
    // No audio or app folders under test; the clipboard is caught.
    String? copied;
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.allMessagesHandler =
        (String channel, MessageHandler? handler, ByteData? message) async {
      if (channel == SystemChannels.platform.name) {
        final MethodCall call =
            SystemChannels.platform.codec.decodeMethodCall(message);
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
          return SystemChannels.platform.codec.encodeSuccessEnvelope(null);
        }
      }
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

    Future<void> wait(int ms) async {
      await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
      await tester.pump(const Duration(milliseconds: 50));
    }

    Future<void> settle() async {
      for (int i = 0; i < 40; i++) {
        await wait(100);
      }
    }

    String log() => tester
        .widgetList<Text>(find.byType(Text))
        .map((Text t) => t.data ?? '')
        .join('\n');

    Future<void> alt(LogicalKeyboardKey k) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(k);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
    }

    Future<void> openFile(String hex, {bool prefilled = false}) async {
      await alt(LogicalKeyboardKey.keyQ); // Main board
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE); // Open
      await tester.pumpAndSettle();
      if (prefilled) {
        // The launch path is filled in.
        expect(find.widgetWithText(TextField, path), findsOneWidget);
      } else {
        await tester.enterText(
            find.widgetWithText(TextField, 'File path'), path);
      }
      await tester.enterText(
          find.widgetWithText(TextField, 'Key — 32 or 64 hex digits'), hex);
      await tester.tap(find.widgetWithText(FilledButton, 'Load'));
      await tester.pump();
      await settle();
      expect(log(), contains('Setup loaded.'));
    }

    Future<void> waitFor(String text, {int tenths = 1200}) async {
      for (int i = 0; i < tenths && !log().contains(text); i++) {
        await wait(100);
      }
      expect(log(), contains(text));
    }

    Future<OrbitVault> write() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await alt(LogicalKeyboardKey.keyQ); // Main board
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW); // Write: its path
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      await settle();
      await alt(LogicalKeyboardKey.keyQ); // copy the key, blind
      expect(copied, isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      return (await tester.runAsync<OrbitVault>(() async => OrbitVault.fromJson(
          await SetupCrypto.openPayload(File(path).readAsBytesSync(),
              SetupCrypto.hexToKey(copied!)))))!;
    }

    Future<void> stepsD() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await alt(LogicalKeyboardKey.keyW); // Setup board
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE); // Steps D
      await tester.pump();
    }

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SetupScreen(core: c)),
    ));
    await tester.pump();
    await openFile(keyHex);

    // Halted after two of three passes, then stopped there: D = 2, at once.
    await alt(LogicalKeyboardKey.digit1); // stage 1: the advance starts
    await waitFor('pass $halted/$passes', tenths: 1800);
    await alt(LogicalKeyboardKey.keyW); // Setup board
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX); // Halt, asked
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Halt').last);
    await waitFor('halted after');
    await stepsD();
    expect(log(), contains('$halted passes kept'));
    await tester.tap(find.text('Stop here (D = $halted)'));
    await tester.pump();
    expect(log(), contains('D = $halted: stage 1 from the passes kept'));

    // Written: stage 0 and the passes kept, D = 2.
    final OrbitVault first = await write();
    expect(first.stages, hasLength(1));
    expect(first.iterations, halted);
    expect(first.trail, hasLength(halted));

    // D raised to 3: one more pass, from the last one kept.
    await stepsD();
    await tester.tap(find.byTooltip('D + 1'));
    await tester.pump();
    expect(log(), contains('$halted passes kept: D = $passes runs 1 more'));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await alt(LogicalKeyboardKey.keyW);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX); // Resume
    await tester.pump();
    await waitFor('the $passes passes are kept');

    // D lowered to 1: it lands at once; the passes chain on from the first.
    await stepsD();
    await tester.enterText(
        find.widgetWithText(TextField, 'Derivation steps / stage'), '1');
    await tester.pump();
    expect(log(), contains('$passes passes kept: D = 1 lands at once.'));
    final OrbitVault second = await write();
    expect(second.iterations, 1);
    expect(second.trail, hasLength(passes));
    for (int p = 0; p < halted; p++) {
      expect(second.trail[p], first.trail[p], reason: 'pass ${p + 1}');
    }

    // Stage 1's first point confirms D: the passes are dropped, D is fixed.
    await alt(LogicalKeyboardKey.digit1); // stage 1, landed
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1); // its map 1
    await alt(LogicalKeyboardKey.keyW);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD); // Import hex
    await tester.pump();
    await tester.enterText(
        find.widgetWithText(TextField, 'Slot 1 — 8 hex digits'), '13572468');
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pump();
    await waitFor('D = 1 confirmed');
    await stepsD();
    expect(log(), contains('D confirmed: stage 1 holds a point.'));
    expect(
        tester
            .widget<TextField>(
                find.widgetWithText(TextField, 'Derivation steps / stage'))
            .enabled,
        isFalse);

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
