/// The provisional key's dialogs, shared by the Great Wall's setup (F2/F3)
/// and Formosa (F4): the key dialog (its QR, a blind copy, Dragon Dice, a
/// scanned or typed key of your own), the QR scanner and the Dragon Dice
/// roll. One key can serve both: scan the Great Wall's QR into F4.
library;

import 'package:dragon_dice_ui/dragon_dice_ui.dart'
    show DiceRolls, DragonDiceWizard;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:great_wall_ux/great_wall_ux.dart' show UiSound;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr/qr.dart' as qr;

import '../command/command_board.dart' show D20Glyph, kCuePress;
import 'desktop_qr_scanner.dart';
import 'key_qr_painter.dart';
import 'qr_layout.dart';
import 'setup_crypto.dart';

/// The cue ids of the key's dialogs and controls.
abstract final class KeyCue {
  static const String dialogOpen = 'dialog.open';
  static const String dialogClose = 'dialog.close';
  static const String scan = 'scan';
  static const String dice = 'dice';
  static const String key = 'key';
  static const String scanCancel = 'scan.cancel';
  static const String keyQr = 'key.qr';
  static const String keyCopy = 'key.copy';
  static const String keyOwn = 'key.own';
  static const String keyDice = 'key.dice';
  static const String keyClose = 'key.close';
}

/// The Dragon Dice wizard's dialog size.
const double kDiceWizardWidth = 960;
const double kDiceWizardHeight = 620;

/// The key-size switch's padding above the wizard; the QR's side, the
/// scanner's, and the key dialog's width.
const double _kKeySizePad = 16;
const double _kQrSide = 300;
const double _kScannerSide = 320;
const double _kKeyDialogWidth = 340;

/// The key dialog's gaps, the QR's white margin, and its text sizes.
const double _kGapSmall = 4;
const double _kGap = 8;
const double _kGapWide = 12;
const double _kIntroSize = 12;
const double _kNoteSize = 11;

void _silent(String _) {}
void _soundless(UiSound _) {}

/// How a host voices the key's dialogs: its cues, its sounds and its log.
/// Silent by default.
class KeyVoice {
  const KeyVoice({
    this.cue = _silent,
    this.sound = _soundless,
    this.toast = _silent,
  });

  final void Function(String name) cue;
  final void Function(UiSound sound) sound;
  final void Function(String message) toast;

  /// Show a dialog through [show], voicing its opening and closing as [id].
  Future<T?> dialog<T>(String id, Future<T?> Function() show) async {
    cue('${KeyCue.dialogOpen}.$id');
    try {
      return await show();
    } finally {
      cue('${KeyCue.dialogClose}.$id');
    }
  }

  /// [f], voicing the press of control [id] first; null stays null.
  VoidCallback? press(String id, VoidCallback? f) => f == null
      ? null
      : () {
          cue('$kCuePress.$id');
          f();
        };
}

/// Whether in-app webcam QR scanning is available through `mobile_scanner`
/// (Android / iOS / macOS).
bool get mobileKeyScanSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// Whether the desktop (flutter_webrtc + zxing2) scan path applies — Linux and
/// Windows, where `mobile_scanner` has no backend. Best-effort: the camera may
/// fail to open on some setups, in which case the user falls back to hex.
bool get desktopKeyScanSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows);

/// Whether a key QR can be scanned here at all.
bool get keyScanSupported => mobileKeyScanSupported || desktopKeyScanSupported;

/// Zero [b].
void wipeKey(Uint8List b) => b.fillRange(0, b.length, 0);

/// Byte-mode QR matrix for a provisional key: v1 (21×21) for the 16-byte
/// key, v2 (25×25) for the 32-byte 256-bit key, both at EC level L.
qr.QrImage keyMatrix(Uint8List key) {
  final int version = key.length > SetupCrypto.keyLenBytes ? 2 : 1;
  return qr.QrImage(
    qr.QrCode(version, qr.QrErrorCorrectLevel.L)
      ..addByteData(ByteData.sublistView(key)),
  );
}

/// Scan a provisional-key QR, returning its 16 or 32 raw key bytes, or null.
/// Uses `mobile_scanner` where it has a backend, else the desktop scanner.
Future<Uint8List?> scanKey(BuildContext context,
        [KeyVoice voice = const KeyVoice()]) =>
    desktopKeyScanSupported
        ? DesktopKeyScanner.show(context)
        : _scanWithMobileScanner(context, voice);

/// The `mobile_scanner` dialog (Android / iOS / macOS): returns the raw key
/// bytes from the QR's byte segment, or null if cancelled.
Future<Uint8List?> _scanWithMobileScanner(
    BuildContext context, KeyVoice voice) async {
  Uint8List? keyBytes;
  await voice.dialog(
      KeyCue.scan,
      () => showDialog<void>(
            context: context,
            builder: (BuildContext ctx) => AlertDialog(
              title: const Text('Scan provisional key'),
              content: SizedBox(
                width: _kScannerSide,
                height: _kScannerSide,
                child: MobileScanner(
                  onDetect: (BarcodeCapture capture) {
                    if (keyBytes != null || capture.barcodes.isEmpty) return;
                    final Uint8List? raw = capture.barcodes.first.rawBytes;
                    if (raw == null || !SetupCrypto.isValidKeyLen(raw.length)) {
                      return;
                    }
                    keyBytes = Uint8List.fromList(raw);
                    Navigator.of(ctx).pop();
                  },
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: voice.press(
                      KeyCue.scanCancel, () => Navigator.of(ctx).pop()),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ));
  return keyBytes;
}

/// A provisional key from the Dragon Dice wizard: the first 16 or 32 bytes
/// of the rolls' digest; null if cancelled. The size starts at [lenBytes]
/// and can be switched in the wizard's dialog. The target is the key's
/// bits, with no margin: from 128 bits on, a digest cut to them cannot be
/// tabulated (dragon-dice/doc/FORMAT.md, "From the digest"). The caller
/// wipes the key.
Future<Uint8List?> rollKey(BuildContext context, int lenBytes,
    [KeyVoice voice = const KeyVoice()]) async {
  int len = lenBytes;
  int bits() => len == SetupCrypto.keyLenBytes
      ? SetupCrypto.keyBits
      : SetupCrypto.keyBits256;
  DiceRolls? rolled;
  await voice.dialog(
    KeyCue.dice,
    () => showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => Dialog(
        child: SizedBox(
          width: kDiceWizardWidth,
          height: kDiceWizardHeight,
          child: StatefulBuilder(
            builder:
                (BuildContext ctx, void Function(void Function()) setLocal) =>
                    Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      _kKeySizePad, _kKeySizePad, _kKeySizePad, 0),
                  child: SegmentedButton<int>(
                    segments: const <ButtonSegment<int>>[
                      ButtonSegment<int>(
                          value: SetupCrypto.keyLenBytes,
                          label: Text('${SetupCrypto.keyBits}-bit key')),
                      ButtonSegment<int>(
                          value: SetupCrypto.keyLenBytes256,
                          label: Text('${SetupCrypto.keyBits256}-bit key')),
                    ],
                    selected: <int>{len},
                    onSelectionChanged: (Set<int> s) =>
                        setLocal(() => len = s.first),
                  ),
                ),
                Expanded(
                  child: DragonDiceWizard(
                    targetBits: bits().toDouble(),
                    purpose: 'The provisional key, ${bits()} bits',
                    systemRandomByDefault: true,
                    onCue: voice.cue,
                    onDone: (DiceRolls r) {
                      rolled = r;
                      Navigator.of(ctx).pop();
                    },
                    onCancel: () => Navigator.of(ctx).pop(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  final DiceRolls? r = rolled;
  if (r == null) return null;
  final Uint8List digest = r.digest();
  r.wipe();
  final Uint8List key = Uint8List.fromList(digest.sublist(0, len));
  wipeKey(digest);
  return key;
}

/// Seals what the key guards under [ownKey], or under a fresh generated key
/// of [newLen] bytes: the key used, or an error.
typedef KeyReseal = Future<({String? error, Uint8List? key})> Function(
    {Uint8List? ownKey, required int newLen});

/// The key dialog, for a [key] that already seals [sealed] ("this setup",
/// "this vault"): Q shows its QR and Alt+Q copies it (blind), pressed again
/// they switch 128↔256 bits; I scans an existing QR to reuse its key, Alt+I
/// types one, R rolls Dragon Dice. Each new key reseals through [reseal]. The
/// dialog opens with [intro]. [copy] puts the hex key on the clipboard (by
/// default, plainly). The dialog's copy of the key is wiped on close.
Future<void> showKeyDialog(
  BuildContext context, {
  required Uint8List key,
  required KeyReseal reseal,
  required String intro,
  required String sealed,
  KeyVoice voice = const KeyVoice(),
  void Function(String hex, int bits)? copy,
}) async {
  Uint8List current = key;
  int keyLen = current.length; // 16 (128-bit) or 32 (256-bit)
  qr.QrImage matrix = keyMatrix(current);
  final bool canScan = keyScanSupported;
  bool showQr = false;
  bool copiedOnce = false;
  bool busy = false;
  final TextEditingController hexInput = TextEditingController();
  final FocusNode hexFocus = FocusNode(debugLabel: 'write-hex');

  await voice.dialog(
      KeyCue.key,
      () => showDialog<void>(
            context: context,
            builder: (BuildContext ctx) => StatefulBuilder(
              builder:
                  (BuildContext ctx, void Function(void Function()) setLocal) {
                void copyHex() {
                  final String hex = SetupCrypto.keyToHex(current);
                  if (copy != null) {
                    copy(hex, keyLen * 8);
                    return;
                  }
                  Clipboard.setData(ClipboardData(text: hex));
                  voice.toast('${keyLen * 8}-bit key copied. The clipboard is '
                      'not air-gapped — clear it after pasting into your '
                      'manager.');
                }

                // Re-seal with either the user's own key or a fresh
                // [newLen]-byte generated key, and redraw. Shared by the
                // 128↔256 toggle and the own-key paths.
                Future<bool> resealWith(
                    {Uint8List? ownKey, required int newLen}) async {
                  setLocal(() => busy = true);
                  final ({String? error, Uint8List? key}) r =
                      await reseal(ownKey: ownKey, newLen: newLen);
                  if (ownKey != null) wipeKey(ownKey);
                  if (!ctx.mounted) return false;
                  if (r.error != null || r.key == null) {
                    setLocal(() => busy = false);
                    voice.sound(UiSound.denyInput);
                    voice.toast(r.error ?? 'Could not save.');
                    return false;
                  }
                  wipeKey(current); // drop the superseded key
                  voice.sound(UiSound.exportOk);
                  setLocal(() {
                    current = r.key!;
                    keyLen = current.length;
                    matrix = keyMatrix(current);
                    busy = false;
                  });
                  return true;
                }

                int otherLen() => keyLen == SetupCrypto.keyLenBytes
                    ? SetupCrypto.keyLenBytes256
                    : SetupCrypto.keyLenBytes;

                Future<void> applyOwnKey() async {
                  Uint8List ownKey;
                  try {
                    ownKey = SetupCrypto.hexToKey(hexInput.text);
                  } on FormatException catch (e) {
                    voice.sound(UiSound.denyInput);
                    voice.toast(e.message);
                    return;
                  }
                  if (await resealWith(ownKey: ownKey, newLen: ownKey.length)) {
                    setLocal(hexInput.clear);
                    voice
                        .toast('Re-saved with your own ${keyLen * 8}-bit key.');
                  }
                }

                // Scan an existing provisional-key QR and re-seal under it, so
                // the QR already copied by hand still serves. The scanned bytes
                // are validated as a key length before use, and wiped.
                Future<void> scanOwnKey() async {
                  if (busy) return;
                  final Uint8List? scanned = await scanKey(ctx, voice);
                  if (scanned == null) return;
                  if (!SetupCrypto.isValidKeyLen(scanned.length)) {
                    wipeKey(scanned);
                    voice.sound(UiSound.denyInput);
                    voice.toast('That QR is not a valid provisional key.');
                    return;
                  }
                  if (await resealWith(
                      ownKey: scanned, newLen: scanned.length)) {
                    voice.toast('Re-saved with the scanned key — your existing '
                        'QR still opens this file.');
                  }
                }

                // R — roll Dragon Dice for a new key and re-seal under it.
                Future<void> rollOwnKey() async {
                  if (busy) return;
                  final Uint8List? rolled = await rollKey(ctx, keyLen, voice);
                  if (rolled == null || !ctx.mounted) {
                    if (rolled != null) wipeKey(rolled);
                    return;
                  }
                  if (await resealWith(ownKey: rolled, newLen: rolled.length)) {
                    voice.toast(
                        'Re-saved with a ${keyLen * 8}-bit key from Dragon Dice.');
                  }
                }

                // Q reveals the QR; pressing it again switches 128↔256 (a fresh
                // key, overwriting the file). Alt+Q copies; again switches too.
                void onShowQr() {
                  if (busy) return;
                  if (!showQr) {
                    setLocal(() => showQr = true);
                  } else {
                    resealWith(newLen: otherLen());
                  }
                }

                void onCopy() {
                  if (busy) return;
                  if (!copiedOnce) {
                    copyHex();
                    setLocal(() => copiedOnce = true);
                  } else {
                    resealWith(newLen: otherLen()).then((bool ok) {
                      if (ok && ctx.mounted) copyHex();
                    });
                  }
                }

                final int version = keyLen > SetupCrypto.keyLenBytes ? 2 : 1;
                return CallbackShortcuts(
                  bindings: <ShortcutActivator, VoidCallback>{
                    const SingleActivator(LogicalKeyboardKey.keyQ): onShowQr,
                    const SingleActivator(LogicalKeyboardKey.keyQ, alt: true):
                        onCopy,
                    // I — scan an existing QR to reuse its key; Alt+I — type
                    // your own hex key. (I is a no-op with no camera backend.)
                    if (canScan)
                      const SingleActivator(LogicalKeyboardKey.keyI):
                          scanOwnKey,
                    const SingleActivator(LogicalKeyboardKey.keyI, alt: true):
                        () => hexFocus.requestFocus(),
                    // R — not a hex digit, so typing a key in the field is safe.
                    const SingleActivator(LogicalKeyboardKey.keyR): rollOwnKey,
                    const SingleActivator(LogicalKeyboardKey.escape): () =>
                        Navigator.of(ctx).pop(),
                  },
                  child: Focus(
                    autofocus: true,
                    child: AlertDialog(
                      title: Text('Provisional key — ${keyLen * 8}-bit'),
                      content: SizedBox(
                        width: _kKeyDialogWidth,
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              Text(intro,
                                  style:
                                      const TextStyle(fontSize: _kIntroSize)),
                              const SizedBox(height: _kGap),
                              Text(
                                'Q — show the QR, to copy its dots onto a '
                                'printed template (see templates/ in the '
                                'repository).  Alt+Q — copy the key for a '
                                'password manager (blind).  Press Q or Alt+Q '
                                'again to switch to ${otherLen() * 8}-bit (a '
                                'fresh key, overwriting the file).  '
                                '${canScan ? 'I — scan an existing QR to reuse '
                                    'its key (re-seals $sealed under it).  ' : ''}'
                                'R — roll Dragon Dice for a new key, 128 or 256 '
                                'bits (re-seals $sealed under it).  '
                                'Alt+I — type your own 32- or 64-hex key '
                                '(Enter).  Esc — close.',
                                style: const TextStyle(fontSize: _kNoteSize),
                              ),
                              if (showQr) ...<Widget>[
                                const SizedBox(height: _kGapWide),
                                Center(
                                  child: Container(
                                    color: Colors.white,
                                    padding: const EdgeInsets.all(_kGapWide),
                                    child: CustomPaint(
                                      size: const Size(_kQrSide, _kQrSide),
                                      painter: KeyQrPainter(matrix),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: _kGapSmall),
                                Text(
                                  '${keyLen * 8}-bit · QR v$version. Copy each '
                                  'black dot onto the template cell of the same '
                                  'colour and place. Mistakes may touch at most '
                                  '${QrLayout(version).correctable} colour '
                                  'blocks (any number of wrong cells in one '
                                  'block counts once); the grey format cells '
                                  'are protected on their own. Do this alone, '
                                  'no cameras.',
                                  style: const TextStyle(fontSize: _kNoteSize),
                                ),
                              ],
                              const SizedBox(height: _kGapWide),
                              TextField(
                                controller: hexInput,
                                focusNode: hexFocus,
                                enabled: !busy,
                                autocorrect: false,
                                enableSuggestions: false,
                                maxLines: 1,
                                onSubmitted: (_) => applyOwnKey(),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                  labelText: 'Your own key — 32 or 64 hex '
                                      'digits (optional)',
                                  hintText:
                                      'from another source, then Enter to apply',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      actions: <Widget>[
                        TextButton.icon(
                          onPressed:
                              voice.press(KeyCue.keyQr, busy ? null : onShowQr),
                          icon: const Icon(Icons.qr_code_2),
                          label:
                              Text(showQr ? 'Switch bits (Q)' : 'Show QR (Q)'),
                        ),
                        TextButton.icon(
                          onPressed:
                              voice.press(KeyCue.keyCopy, busy ? null : onCopy),
                          icon: const Icon(Icons.copy),
                          label: const Text('Copy key (Alt+Q)'),
                        ),
                        TextButton.icon(
                          onPressed: voice.press(
                              KeyCue.keyDice, busy ? null : rollOwnKey),
                          icon: D20Glyph(
                              colour: Theme.of(ctx).colorScheme.primary),
                          label: const Text('Roll dice (R)'),
                        ),
                        if (canScan)
                          TextButton.icon(
                            onPressed: voice.press(
                                KeyCue.keyOwn, busy ? null : scanOwnKey),
                            icon: const Icon(Icons.qr_code_scanner),
                            label: const Text('Scan to reuse (I)'),
                          ),
                        TextButton(
                          onPressed: voice.press(
                              KeyCue.keyClose, () => Navigator.of(ctx).pop()),
                          child: const Text('Done'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ));
  hexInput.dispose();
  hexFocus.dispose();
  wipeKey(current); // recorded or abandoned — drop the dialog's copy
}
