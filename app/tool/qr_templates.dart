// Prints the blank provisional-key QR templates: one per key size, as SVG
// (vector, prints sharp at any size). Each holds what every key's code
// shares — the fixed cells, solid — and the cells to copy, coloured by
// codeword (the format cells grey), over a grid. The app's key dialog draws
// the key's dots over the same colours, so a copy goes cell by cell.
//
// Run from app/:  dart run tool/qr_templates.dart [output folder]
// (default: ../templates, the repository's templates/ folder).
import 'dart:io';

import 'package:great_wallet_app/src/setup/qr_layout.dart';

/// Millimetres per cell when printed, and the quiet zone in cells.
const double _cellMm = 5;
const int _quiet = 4;

/// The grid's stroke as a fraction of a cell, and its colour.
const double _gridStroke = 0.04;
const String _gridColour = '#9e9e9e';

/// Room below the code for the caption, in cells, and its font size and
/// line height.
const int _captionCells = 5;
const double _captionSize = 0.7;
const double _captionLine = 1;

/// Key sizes: bits, and the QR version their bytes ride.
const List<(int, int)> _keys = <(int, int)>[(128, 1), (256, 2)];

String _hex(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

String _svg(int bits, QrLayout l) {
  final int n = l.size;
  final int w = n + 2 * _quiet;
  final int h = w + _captionCells;
  final StringBuffer b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<svg xmlns="http://www.w3.org/2000/svg" '
        'width="${w * _cellMm}mm" height="${h * _cellMm}mm" '
        'viewBox="0 0 $w $h">')
    ..writeln('<rect width="$w" height="$h" fill="#ffffff"/>');
  for (int r = 0; r < n; r++) {
    for (int c = 0; c < n; c++) {
      final String fill = l.cellAt(r, c) == QrCell.fixed
          ? (l.fixedDarkAt(r, c) ? '#000000' : '#ffffff')
          : _hex(l.fillAt(r, c));
      b.writeln('<rect x="${c + _quiet}" y="${r + _quiet}" width="1" '
          'height="1" fill="$fill" stroke="$_gridColour" '
          'stroke-width="$_gridStroke"/>');
    }
  }
  final List<String> caption = <String>[
    '$bits-bit provisional key · QR version ${l.version}',
    'Copy each dot of the app\'s QR onto its cell.',
    'Mistakes may touch at most ${l.correctable} colour blocks;',
    'the grey cells (format) are protected on their own.',
  ];
  for (int i = 0; i < caption.length; i++) {
    // Below the quiet zone, which a scanner needs blank.
    b.writeln('<text x="$_quiet" y="${w + 1 + i * _captionLine}" '
        'font-family="sans-serif" font-size="$_captionSize">'
        '${caption[i]}</text>');
  }
  b.writeln('</svg>');
  return b.toString();
}

void main(List<String> args) {
  final Directory out = Directory(args.isEmpty ? '../templates' : args.first)
    ..createSync(recursive: true);
  for (final (int bits, int version) in _keys) {
    final File f =
        File('${out.path}/$bits-bit-provisional-key-qr-template.svg');
    f.writeAsStringSync(_svg(bits, QrLayout(version)));
    stdout.writeln('wrote ${f.path}');
  }
}
