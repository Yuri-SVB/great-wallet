import 'package:flutter/material.dart';
import 'package:qr/qr.dart' as qr;

import 'qr_layout.dart';

/// Paints a provisional key's QR for copying onto a printed template: each
/// cell filled with its codeword's light colour (the format cells grey), the
/// fixed cells solid as the template prints them, and the key's dark cells as
/// black dots ([QrLayout]).
class KeyQrPainter extends CustomPainter {
  KeyQrPainter(this.image) : layout = QrLayout(_versionOf(image.moduleCount));

  final qr.QrImage image;
  final QrLayout layout;

  static int _versionOf(int size) => (size - _kBaseSize) ~/ _kSizeStep;
  static const int _kBaseSize = 17;
  static const int _kSizeStep = 4;

  /// QR spec mandates a clear margin of at least 4 modules around the symbol;
  /// without it decoders often fail to lock onto the finder patterns.
  static const int quiet = 4;

  /// A dot's radius, and the grid's stroke, as fractions of a cell.
  static const double _dot = 0.32;
  static const double _gridStroke = 0.04;
  static const Color _grid = Color(0xFF9E9E9E);

  @override
  void paint(Canvas canvas, Size size) {
    final int n = image.moduleCount;
    final double cell = size.width / (n + 2 * quiet);
    final double off = quiet * cell; // top-left of the symbol proper
    final Paint ink = Paint()..color = const Color(kBlack);
    final Paint grid = Paint()
      ..color = _grid
      ..style = PaintingStyle.stroke
      ..strokeWidth = cell * _gridStroke;
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(kWhite));
    for (int r = 0; r < n; r++) {
      for (int c = 0; c < n; c++) {
        final Rect rect =
            Rect.fromLTWH(off + c * cell, off + r * cell, cell, cell);
        final bool dark = image.isDark(r, c);
        if (layout.cellAt(r, c) == QrCell.fixed) {
          if (dark) canvas.drawRect(rect, ink);
        } else {
          canvas.drawRect(rect, Paint()..color = Color(layout.fillAt(r, c)));
          if (dark) canvas.drawCircle(rect.center, cell * _dot, ink);
        }
        canvas.drawRect(rect, grid);
      }
    }
  }

  @override
  bool shouldRepaint(KeyQrPainter oldDelegate) => oldDelegate.image != image;
}
