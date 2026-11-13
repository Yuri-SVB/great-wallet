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

/// The provisional key from Dragon Dice, on the real screen with the engine
/// linked: a setup is opened and written, the key dialog's Roll dice (R)
/// switches to a 256-bit key in the wizard, and the file opens under the
/// key it gives. Then Wipe everything (V) removes the file.
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

  testWidgets('Roll dice re-seals the setup under a 256-bit dice key', (
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
      final EncodedPoint pt = await tester.runAsync(() async =>
              c.encodeStage(_chunk(value), o: prm.o, p: prm.p, q: prm.q).first)
          as EncodedPoint;
      points.add(OrbitVaultPoint(slot: slot, reRaw: pt.reRaw, imRaw: pt.imRaw));
    }
    final OrbitVault vault = OrbitVault(
      sigma: sigmaHex,
      iterations: 4,
      profile: Argon2Profile.basic,
      stages: <OrbitVaultStage>[
        OrbitVaultStage(required: 2, orbit: null, points: points),
      ],
    );
    final Directory dir = Directory.systemTemp.createTempSync('gw-dice-key');
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

    String log() => tester
        .widgetList<Text>(find.byType(Text))
        .map((Text t) => t.data ?? '')
        .join('\n');

    // Open the file: Main board › Open (E), its path and its key.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'File path'), path);
    await tester.enterText(
        find.widgetWithText(TextField, 'Key — 32 or 64 hex digits'), keyHex);
    await tester.tap(find.widgetWithText(FilledButton, 'Load'));
    await tester.pump();
    await settle();
    expect(log(), contains('Setup loaded.'));

    // Write (W): its path asked, the opened file's filled in; then the key
    // dialog, a fresh 128-bit key.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, path), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    await settle();
    expect(find.text('Provisional key — 128-bit'), findsOneWidget);

    // Roll dice (R): the wizard, 128 bits to start; switch to 256.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pumpAndSettle();
    expect(
        find.textContaining('The provisional key, 128 bits'), findsOneWidget);
    await tester.tap(find.text('256-bit key'));
    await tester.pump();
    expect(
        find.textContaining('The provisional key, 256 bits'), findsOneWidget);

    // Done with the system's randomness only: short, used anyway.
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use them anyway'));
    await tester.pump();
    await settle();
    expect(find.text('Provisional key — 256-bit'), findsOneWidget);
    expect(log(), contains('Re-saved with a 256-bit key from Dragon Dice.'));

    // The file opens under the dice key (copied, Alt+Q), not the first one.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(copied, isNotNull);
    final Uint8List diceKey = SetupCrypto.hexToKey(copied!);
    expect(diceKey.length, SetupCrypto.keyLenBytes256);
    final OrbitVault? reopened = await tester.runAsync<OrbitVault?>(() async =>
        OrbitVault.fromJson(await SetupCrypto.openPayload(
            File(path).readAsBytesSync(), diceKey)));
    expect(reopened!.sigma, sigmaHex);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // Wipe everything (V): one button, seven presses; six leave all as is.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.pumpAndSettle();
    expect(find.text('Wipe — press 7 times'), findsOneWidget);
    for (int i = 0; i < 6; i++) {
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
    }
    expect(find.text('Wipe — 1 more'), findsOneWidget);
    expect(File(path).existsSync(), isTrue);
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await settle();
    expect(File(path).existsSync(), isFalse);
    expect(log(), contains('Wiped: the setup file was overwritten and deleted'));

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
