import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/core/dragon_dice.dart';
import 'package:great_wallet_app/src/core/encoding_constants.dart';

/// Dragon Dice entry: d20 rolls → SHA-512 under the domain tag → the bits of
/// whole points. Known answers from Python's hashlib.
void main() {
  /// [bits] as lowercase hex, 4 bits a digit.
  String hex(List<int> bits) {
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < bits.length; i += 4) {
      final int v =
          bits[i] << 3 | bits[i + 1] << 2 | bits[i + 2] << 1 | bits[i + 3];
      out.write(v.toRadixString(16));
    }
    return out.toString();
  }

  test('eight rolls a point: ⌈32 / log₂ 20⌉', () {
    expect(kDiceRollsPerPoint, 8);
    expect(kDiceRollsPerPoint * kDiceBitsPerRoll,
        greaterThanOrEqualTo(EncodingConstants.bitsPerPoint));
  });

  test('rolls parse from spaces or commas, 1 to 20 only', () {
    expect(parseDiceRolls(' 7 20,3  15 '), <int>[7, 20, 3, 15]);
    expect(parseDiceRolls(''), isEmpty);
    for (final String bad in <String>['0', '21', 'a', '-3', '2.5']) {
      expect(() => parseDiceRolls(bad), throwsFormatException, reason: bad);
    }
  });

  test('known answers', () {
    expect(hex(diceToBits(<int>[1, 2, 3, 4, 5, 6, 7, 8])), '6cbc18c7');
    expect(hex(diceToBits(List<int>.filled(16, 20), points: 2)),
        '5cd3e29bc5f10b08');
    // Every roll counts, extra ones too.
    expect(hex(diceToBits(<int>[1, 2, 3, 4, 5, 6, 7, 8, 9])), '7c39832b');
  });

  test('too few rolls, a face out of range, or too many points throw', () {
    expect(() => diceToBits(<int>[1, 2, 3, 4, 5, 6, 7]), throwsArgumentError);
    expect(() => diceToBits(List<int>.filled(8, 21)), throwsArgumentError);
    expect(() => diceToBits(List<int>.filled(8, 0)), throwsArgumentError);
    expect(() => diceToBits(List<int>.filled(17 * 8, 1), points: 17),
        throwsArgumentError);
    expect(() => diceToBits(List<int>.filled(8, 1), points: 0),
        throwsArgumentError);
  });
}
