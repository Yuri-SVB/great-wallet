import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/app/mode_shell.dart';
import 'package:great_wallet_app/src/core/great_wall_core.dart';
import 'package:great_wallet_app/src/ffi/library_loader.dart';

/// The modes on F2–F6: F4 shows Formosa, F2 brings Setup back, and the keys
/// follow the screen shown.
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
    }
  });

  testWidgets('F4 shows Formosa; F2 there brings Setup back',
      (WidgetTester tester) async {
    final GreatWallCore? c = core;
    if (c == null) {
      markTestSkipped('engine unavailable — $openError');
      return;
    }
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
    await tester.pumpWidget(MaterialApp(home: ModeShell(core: c)));
    await tester.pump();
    expect(find.text('Great Wallet — Setup'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.f4);
    await tester.pump();
    await tester.pump();
    expect(find.text('Great Wallet — Formosa'), findsOneWidget);
    expect(find.text('Formosa — passwords'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pump();
    await tester.pump();
    expect(find.text('Great Wallet — Setup'), findsOneWidget);
    expect(find.text('Formosa — passwords'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    for (int i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(seconds: 1));
    }
  });
}
