/// The layout of a provisional key's QR (versions 1 and 2, error correction
/// level L): which cells are fixed (pre-printed on the template), which carry
/// the format, and which codeword each data cell belongs to — so the cells
/// can be coloured by codeword, and the mistakes a copy may hold counted in
/// codewords. Pure Dart: the app draws it, and `app/tool/qr_templates.dart`
/// prints the templates from it.
library;

/// What a cell of the code is.
enum QrCell {
  /// Key-independent: finders and their separators, timing, the alignment
  /// pattern (version 2), the dark module. Pre-printed on the template.
  fixed,

  /// The format information (error correction level and mask): depends on
  /// the key's mask, protected by its own code.
  format,

  /// A bit of a codeword.
  data,

  /// A leftover cell after the last codeword (version 2 has seven).
  remainder,
}

/// The cell layout of a QR code of [version] (1 or 2).
class QrLayout {
  QrLayout(this.version)
      : assert(_byVersion.containsKey(version)),
        size = _baseSize + _sizeStep * version {
    _place();
  }

  final int version;

  /// Cells per side: 21 for version 1, 25 for version 2.
  final int size;

  static const int _baseSize = 17;
  static const int _sizeStep = 4;
  static const int _finder = 8; // a finder with its separator
  static const int _timing = 6;
  static const int _alignHalf = 2; // the 5×5 alignment pattern's half-width
  static const int _alignFromEnd = 7; // its centre, from the far edge
  static const int _bitsPerCodeword = 8;

  /// Codewords in all, and how many may hold mistakes and still decode, at
  /// level L (ISO/IEC 18004, the error-correction table: v1-L (26,19,2),
  /// v2-L (44,34,4)).
  static const Map<int, ({int codewords, int correctable})> _byVersion =
      <int, ({int codewords, int correctable})>{
    1: (codewords: 26, correctable: 2),
    2: (codewords: 44, correctable: 4),
  };

  int get codewords => _byVersion[version]!.codewords;

  /// How many codewords a copy may get wrong (any number of cells within one
  /// codeword counting once) and still scan.
  int get correctable => _byVersion[version]!.correctable;

  late final List<List<int>> _codeword =
      List<List<int>>.generate(size, (_) => List<int>.filled(size, -1));

  /// The codeword cell ([row], [col]) belongs to, or -1 for a cell that is
  /// not a codeword's.
  int codewordAt(int row, int col) => _codeword[row][col];

  /// What cell ([row], [col]) is.
  QrCell cellAt(int row, int col) {
    if (_isFixed(row, col)) return QrCell.fixed;
    if (_isFormat(row, col)) return QrCell.format;
    return _codeword[row][col] < 0 ? QrCell.remainder : QrCell.data;
  }

  bool _isFixed(int r, int c) {
    bool corner(int r0, int c0) =>
        r >= r0 && r < r0 + _finder && c >= c0 && c < c0 + _finder;
    if (corner(0, 0) ||
        corner(0, size - _finder) ||
        corner(size - _finder, 0)) {
      return true;
    }
    if (r == _timing || c == _timing) return true;
    if (r == size - _finder && c == _finder) return true; // the dark module
    if (version >= 2) {
      final int a = size - _alignFromEnd;
      if ((r - a).abs() <= _alignHalf && (c - a).abs() <= _alignHalf) {
        return true;
      }
    }
    return false;
  }

  bool _isFormat(int r, int c) {
    if (_isFixed(r, c)) return false;
    // Beside the top-left finder, then along the other two.
    if (r == _finder && (c <= _finder || c >= size - _finder)) return true;
    if (c == _finder && (r <= _finder || r >= size - _finder)) return true;
    return false;
  }

  /// Whether the fixed cell ([row], [col]) is dark, as every key's code
  /// draws it: the finders' rings and cores, the timing's alternation, the
  /// alignment pattern's ring and centre, the dark module.
  bool fixedDarkAt(int row, int col) {
    final int n = size;
    bool finder(int r0, int c0) {
      final int dr = row - r0, dc = col - c0;
      const int edge = _finder - 2; // the 7×7 finder's last row and column
      const int coreFrom = 2, coreTo = 4;
      if (dr < 0 || dc < 0 || dr > edge || dc > edge) return false;
      final bool ring = dr == 0 || dr == edge || dc == 0 || dc == edge;
      final bool core =
          dr >= coreFrom && dr <= coreTo && dc >= coreFrom && dc <= coreTo;
      return ring || core;
    }

    final int far = n - _finder + 1; // a far finder's first row or column
    if (finder(0, 0) || finder(0, far) || finder(far, 0)) return true;
    if (row == _timing && col >= _finder && col < n - _finder) {
      return col.isEven;
    }
    if (col == _timing && row >= _finder && row < n - _finder) {
      return row.isEven;
    }
    if (row == n - _finder && col == _finder) return true; // the dark module
    if (version >= 2) {
      final int a = n - _alignFromEnd;
      final int dr = (row - a).abs(), dc = (col - a).abs();
      if (dr <= _alignHalf && dc <= _alignHalf) {
        return dr == _alignHalf || dc == _alignHalf || (dr == 0 && dc == 0);
      }
    }
    return false;
  }

  /// The data cells in placement order (ISO/IEC 18004 §7.7.3): two columns
  /// at a time from the right, up then down, skipping the timing column;
  /// each codeword's eight bits, most significant first.
  void _place() {
    int bit = 0;
    final int bits = codewords * _bitsPerCodeword;
    bool up = true;
    for (int col = size - 1; col > 0; col -= 2) {
      if (col == _timing) col--;
      for (int i = 0; i < size; i++) {
        final int row = up ? size - 1 - i : i;
        for (int c = col; c > col - 2; c--) {
          if (_isFixed(row, c) || _isFormat(row, c)) continue;
          if (bit < bits) _codeword[row][c] = bit ~/ _bitsPerCodeword;
          bit++;
        }
      }
      up = !up;
    }
  }

  /// The fill of cell ([row], [col]) as 0xAARRGGBB: a light colour per
  /// codeword (neighbouring codewords differ), light grey for the format,
  /// white otherwise — the fixed cells are drawn by their own dark/light.
  int fillAt(int row, int col) => switch (cellAt(row, col)) {
        QrCell.data =>
          kCodewordColours[_codeword[row][col] % kCodewordColours.length],
        QrCell.format => kFormatColour,
        QrCell.fixed || QrCell.remainder => kWhite,
      };
}

/// Light colours for the codewords, cycled in placement order.
const List<int> kCodewordColours = <int>[
  0xFFFFD6D6, // rose
  0xFFD6ECFF, // sky
  0xFFDDF5D0, // mint
  0xFFFFF0C2, // sand
  0xFFEBDDFF, // lilac
  0xFFD2F4F0, // aqua
  0xFFFFE0C7, // peach
  0xFFE6E6E6, // pale grey
];

/// The format cells' fill, and white.
const int kFormatColour = 0xFFC8C8C8;
const int kWhite = 0xFFFFFFFF;
const int kBlack = 0xFF000000;
