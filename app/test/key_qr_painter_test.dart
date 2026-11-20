import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/setup/key_qr_painter.dart';
import 'package:great_wallet_app/src/setup/qr_layout.dart';
import 'package:qr/qr.dart' as qr;

/// The key's QR as drawn for copying: a dark data cell is a black dot on its
/// codeword's colour, a light one just the colour, a dark fixed cell solid.
void main() {
  testWidgets('dots on codeword colours, fixed cells solid',
      (WidgetTester tester) async {
    final Uint8List key =
        Uint8List.fromList(List<int>.generate(16, (int i) => i * 17));
    final qr.QrImage img = qr.QrImage(
      qr.QrCode(1, qr.QrErrorCorrectLevel.L)
        ..addByteData(ByteData.sublistView(key)),
    );
    final QrLayout l = QrLayout(1);
    const int cellPx = 10;
    final int sidePx = (l.size + 2 * KeyQrPainter.quiet) * cellPx;
    final ui.PictureRecorder rec = ui.PictureRecorder();
    KeyQrPainter(img)
        .paint(Canvas(rec), Size(sidePx.toDouble(), sidePx.toDouble()));
    final ByteData px = (await tester.runAsync<ByteData?>(() async {
      final ui.Image image = await rec.endRecording().toImage(sidePx, sidePx);
      final ByteData? d = await image.toByteData();
      image.dispose();
      return d;
    }))!;
    int argb(int x, int y) {
      final int o = (y * sidePx + x) * 4;
      return 0xFF000000 |
          (px.getUint8(o) << 16) |
          (px.getUint8(o + 1) << 8) |
          px.getUint8(o + 2);
    }

    // Centre, and a point near the corner (clear of the grid line and the
    // dot's soft edge), of a cell.
    (int, int) centre(int r, int c) => (
          (KeyQrPainter.quiet + c) * cellPx + cellPx ~/ 2,
          (KeyQrPainter.quiet + r) * cellPx + cellPx ~/ 2,
        );
    (int, int) corner(int r, int c) => (
          (KeyQrPainter.quiet + c) * cellPx + 1,
          (KeyQrPainter.quiet + r) * cellPx + 1,
        );

    int darkData = 0, lightData = 0;
    for (int r = 0; r < l.size; r++) {
      for (int c = 0; c < l.size; c++) {
        if (l.cellAt(r, c) != QrCell.data) continue;
        final (int cx, int cy) = centre(r, c);
        final (int kx, int ky) = corner(r, c);
        expect(argb(kx, ky), l.fillAt(r, c), reason: 'fill of ($r, $c)');
        if (img.isDark(r, c)) {
          expect(argb(cx, cy), kBlack, reason: 'dot at ($r, $c)');
          darkData++;
        } else {
          expect(argb(cx, cy), l.fillAt(r, c), reason: 'no dot at ($r, $c)');
          lightData++;
        }
      }
    }
    expect(darkData, greaterThan(0));
    expect(lightData, greaterThan(0));
    // A finder's corner is solid black, right to its corner.
    final (int fx, int fy) = corner(0, 0);
    expect(argb(fx, fy), kBlack);
  });
}
