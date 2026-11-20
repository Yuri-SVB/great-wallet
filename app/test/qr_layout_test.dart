import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/setup/qr_layout.dart';
import 'package:qr/qr.dart' as qr;

/// The key QR's layout: the cell counts of the standard, and — on real key
/// codes — every codeword read back from its cells through the layout, the
/// data ones checked against the key's byte-mode bitstream.
void main() {
  /// The standard's masks (ISO/IEC 18004 §7.8.2).
  bool mask(int p, int i, int j) => switch (p) {
        0 => (i + j).isEven,
        1 => i.isEven,
        2 => j % 3 == 0,
        3 => (i + j) % 3 == 0,
        4 => ((i ~/ 2) + (j ~/ 3)).isEven,
        5 => (i * j) % 2 + (i * j) % 3 == 0,
        6 => ((i * j) % 2 + (i * j) % 3).isEven,
        _ => ((i * j) % 3 + (i + j) % 2).isEven,
      };

  /// Data codewords at level L: 19 in version 1, 34 in version 2.
  int dataCodewords(int v) => v == 1 ? 19 : 34;

  /// A key's data codewords in byte mode: mode 0100, the 8-bit count, the
  /// bytes, the terminator, then the pad bytes 0xEC, 0x11 in turn.
  List<int> expectedData(List<int> key, int capacity) {
    final List<int> bits = <int>[];
    void put(int value, int n) {
      for (int i = n - 1; i >= 0; i--) {
        bits.add((value >> i) & 1);
      }
    }

    put(4, 4);
    put(key.length, 8);
    for (final int b in key) {
      put(b, 8);
    }
    for (int i = 0; i < 4 && bits.length < capacity * 8; i++) {
      bits.add(0);
    }
    while (bits.length % 8 != 0) {
      bits.add(0);
    }
    final List<int> out = <int>[
      for (int i = 0; i < bits.length; i += 8)
        bits.sublist(i, i + 8).fold<int>(0, (int a, int b) => (a << 1) | b),
    ];
    for (int i = 0; out.length < capacity; i++) {
      out.add(i.isEven ? 0xEC : 0x11);
    }
    return out;
  }

  test('cell counts: 208 data cells in version 1, 352 + 7 in version 2', () {
    for (final (int v, int data, int rest) in <(int, int, int)>[
      (1, 208, 0),
      (2, 352, 7),
    ]) {
      final QrLayout l = QrLayout(v);
      int d = 0, r = 0, f = 0;
      for (int i = 0; i < l.size; i++) {
        for (int j = 0; j < l.size; j++) {
          switch (l.cellAt(i, j)) {
            case QrCell.data:
              d++;
            case QrCell.remainder:
              r++;
            case QrCell.format:
              f++;
            case QrCell.fixed:
              break;
          }
        }
      }
      expect(d, data, reason: 'v$v data');
      expect(r, rest, reason: 'v$v remainder');
      expect(f, 30, reason: 'v$v format: two copies of 15');
    }
  });

  test('every codeword is read from its cells, on real keys', () {
    final math.Random rng = math.Random(11);
    for (final int bytes in <int>[16, 32]) {
      for (int k = 0; k < 20; k++) {
        final Uint8List key = Uint8List.fromList(
            List<int>.generate(bytes, (_) => rng.nextInt(256)));
        final int v = bytes > 16 ? 2 : 1;
        final qr.QrCode code = qr.QrCode(v, qr.QrErrorCorrectLevel.L)
          ..addByteData(ByteData.sublistView(key));
        final qr.QrImage img = qr.QrImage(code);
        final QrLayout l = QrLayout(v);
        expect(img.moduleCount, l.size);
        final List<int> rebuilt = List<int>.filled(l.codewords, 0);
        final List<int> seen = List<int>.filled(l.codewords, 0);
        // Walk the cells in placement order: bit order within a codeword.
        bool up = true;
        for (int col = l.size - 1; col > 0; col -= 2) {
          if (col == 6) col--;
          for (int i = 0; i < l.size; i++) {
            final int row = up ? l.size - 1 - i : i;
            for (int c = col; c > col - 2; c--) {
              final int w = l.codewordAt(row, c);
              if (w < 0) continue;
              final bool bit =
                  img.isDark(row, c) != mask(img.maskPattern, row, c);
              rebuilt[w] = (rebuilt[w] << 1) | (bit ? 1 : 0);
              seen[w]++;
            }
          }
          up = !up;
        }
        expect(seen, everyElement(8));
        // The fixed cells are what every key's code draws there.
        for (int r = 0; r < l.size; r++) {
          for (int c = 0; c < l.size; c++) {
            if (l.cellAt(r, c) == QrCell.fixed) {
              expect(l.fixedDarkAt(r, c), img.isDark(r, c),
                  reason: 'v$v fixed cell ($r, $c)');
            }
          }
        }
        expect(rebuilt.sublist(0, dataCodewords(v)),
            expectedData(key, dataCodewords(v)),
            reason: 'v$v key $k');
      }
    }
  });

  test('the budget: 2 codewords for 128-bit keys, 4 for 256-bit', () {
    expect(QrLayout(1).correctable, 2);
    expect(QrLayout(2).correctable, 4);
    // Neighbouring codewords differ in colour.
    final QrLayout l = QrLayout(2);
    expect(l.fillAt(l.size - 1, l.size - 1),
        isNot(l.fillAt(l.size - 5, l.size - 1)));
  });
}
