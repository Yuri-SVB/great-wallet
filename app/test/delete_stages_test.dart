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
import 'package:great_wallet_app/src/setup/stage0_bundle.dart';

/// Earlier stages deleted from the setup file, on the real screen with the
/// engine linked: stage 0 goes from a two-stage setup — a warning (it does
/// not pass the gate), a typed confirmation, the key that opened the file,
/// stage 0's bundle sealed first — and the file keeps stage 1 alone. Stage 0
/// cannot be selected, and, the file opened again, the gate leaves it out.
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

  testWidgets('stage 0 deleted: its bundle sealed, the file keeps stage 1',
      (WidgetTester tester) async {
    final GreatWallCore? c = core;
    if (c == null) {
      markTestSkipped('engine unavailable — $openError');
      return;
    }
    // --- a two-stage setup: stage 0's 2 points, stage 1's 3 -----------------
    final OrbitProtocol protocol = OrbitProtocol(c);
    final Uint8List o0 = c.orbitRoot(_hex(sigmaHex));
    // Stage 1's orbit point as a file would carry it (any 64 bytes do here).
    final Uint8List o1 = Uint8List.fromList(
        <int>[for (int i = 0; i < kOrbitPointLen; i++) (0x40 + i) & 0xFF]);
    Future<List<OrbitVaultPoint>> place(
        Uint8List o, List<(int, int)> values) async {
      final List<OrbitVaultPoint> out = <OrbitVaultPoint>[];
      for (final (int slot, int value) in values) {
        final ({int o, int p, int q}) prm = protocol.orbitParams(o, slot - 1);
        final EncodedPoint pt = await tester.runAsync(() async => c
            .encodeStage(_chunk(value), o: prm.o, p: prm.p, q: prm.q)
            .first) as EncodedPoint;
        out.add(OrbitVaultPoint(slot: slot, reRaw: pt.reRaw, imRaw: pt.imRaw));
      }
      return out;
    }

    final OrbitVault vault = OrbitVault(
      sigma: sigmaHex,
      iterations: 1,
      profile: Argon2Profile.basic,
      stages: <OrbitVaultStage>[
        OrbitVaultStage(
            required: 2,
            orbit: null,
            points: await place(
                o0, <(int, int)>[(1, 0x13572468), (2, 0x2468ACE0)])),
        OrbitVaultStage(
            required: 3,
            orbit: List<int>.of(o1),
            points: await place(o1, <(int, int)>[
              (1, 0x0F1E2D3C),
              (2, 0x4B5A6978),
              (3, 0x8796A5B4),
            ])),
      ],
    );
    final Directory dir = Directory.systemTemp.createTempSync('gw-delete');
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

    Future<void> waitFor(String text) async {
      for (int i = 0; i < 1200 && !log().contains(text); i++) {
        await wait(100);
      }
      expect(log(), contains(text));
    }

    Future<void> alt(LogicalKeyboardKey k) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(k);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
    }

    Future<void> openFile() async {
      await alt(LogicalKeyboardKey.keyQ); // Main board
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE); // Open
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'File path'), path);
      await tester.enterText(
          find.widgetWithText(TextField, 'Key — 32 or 64 hex digits'), keyHex);
      await tester.tap(find.widgetWithText(FilledButton, 'Load'));
      await tester.pump();
      await waitFor('Setup loaded.');
    }

    Future<void> graduation() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.f3); // Train
      await tester.pump();
      await alt(LogicalKeyboardKey.keyW); // Train board
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX); // Graduation
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SetupScreen(core: c)),
    ));
    await tester.pump();
    await openFile();

    // Graduation › Delete earlier stages: stage 0, which does not pass the
    // gate (no maps studied) — warned; Delete only once "delete" is typed.
    await graduation();
    await tester.tap(find.text('Delete earlier stages…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('WARNING: not passing the graduation gate yet: '
        'stage 0.'), findsOneWidget);
    final Finder delete = find.widgetWithText(FilledButton, 'Delete');
    expect(tester.widget<FilledButton>(delete).onPressed, isNull);
    await tester.enterText(
        find.widgetWithText(TextField, 'Type "delete" to confirm'), 'delete');
    await tester.pump();
    await tester.tap(delete);
    await tester.pumpAndSettle();

    // The key that opened the file, then stage 0's bundle, sealed first.
    await tester.enterText(
        find.widgetWithText(TextField, 'Key — 32 or 64 hex digits'), keyHex);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pump();
    for (int i = 0;
        i < 600 && find.text('Delete stage 0: its bundle first').evaluate().isEmpty;
        i++) {
      await wait(100);
    }
    await tester.enterText(find.widgetWithText(TextField, 'D (passes)'), '1');
    await tester.tap(find.widgetWithText(FilledButton, 'Seal stage 0'));
    await tester.pump();
    await waitFor('Stages 0 to 0 deleted from the setup file');
    expect(File('$path$kStage0Suffix').existsSync(), isTrue,
        reason: 'stage 0 keeps training from its bundle');

    // The file keeps stage 1 alone, its orbit point with it.
    final OrbitVault saved = (await tester.runAsync<OrbitVault>(() async =>
        OrbitVault.fromJson(await SetupCrypto.openPayload(
            File(path).readAsBytesSync(), key))))!;
    expect(saved.firstStage, 1);
    expect(saved.stages, hasLength(1));
    expect(saved.stages.single.orbit, o1);
    expect(saved.stages.single.points, hasLength(3));

    // Stage 0 cannot be selected.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await alt(LogicalKeyboardKey.digit0);
    expect(log(), contains('Stage 0 is deleted from this setup file'));

    // Opened again: the gate leaves stage 0 out.
    await tester.pumpWidget(const SizedBox());
    await settle();
    await tester.pumpWidget(MaterialApp(
      key: const ValueKey<int>(2),
      home: Scaffold(body: SetupScreen(core: c)),
    ));
    await tester.pump();
    await openFile();
    await graduation();
    expect(find.text('Stage 0: deleted from this file, left out of the gate.'),
        findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();

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
