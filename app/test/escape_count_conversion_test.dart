import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/core/core_escape_count_source.dart';

void main() {
  group('escapeCountsFromExact', () {
    test('passes exact counts through, non-escaping already == maxIterations', () {
      // The engine's u32 raster writes the true count, and max_iter for a
      // non-escaping point — the convention great-wall-ux already expects, so
      // no remap applies.
      final Uint32List exact = Uint32List.fromList(<int>[64, 0, 9]);
      expect(escapeCountsFromExact(exact, 64), <int>[64, 0, 9]);
    });

    test('preserves counts above 255, which the u8 raster could not', () {
      // The whole reason this path exists: under the u8 encoding these three
      // fold onto the same value, and a canonical island's flood fill would
      // treat them as one level set.
      final Uint32List exact = Uint32List.fromList(<int>[12, 267, 522, 777]);
      expect(escapeCountsFromExact(exact, 1024), <int>[12, 267, 522, 777]);
    });

    test('no row flip: engine row y maps directly to UX row y', () {
      final Uint32List exact = Uint32List.fromList(<int>[
        10, 11, // row 0
        20, 21, // row 1
        30, 31, // row 2
      ]);
      expect(escapeCountsFromExact(exact, 64), <int>[10, 11, 20, 21, 30, 31]);
    });

    test('copies rather than aliasing the FFI buffer', () {
      // The source frees the native buffer right after converting, so the
      // result must not be a view onto it.
      final Uint32List exact = Uint32List.fromList(<int>[1, 2, 3]);
      final Uint32List counts = escapeCountsFromExact(exact, 64);
      exact[0] = 99;
      expect(counts[0], 1);
    });

    test('output length matches the input', () {
      expect(escapeCountsFromExact(Uint32List(20), 64).length, 20);
    });
  });
}
