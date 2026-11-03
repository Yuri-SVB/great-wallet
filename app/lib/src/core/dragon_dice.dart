import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'encoding_constants.dart';
import 'entropy.dart';

/// Dragon Dice entry: points from rolls of a d20, for users who would rather
/// not take the device's random generator on trust
/// (next-steps/dragon-dice.md). The interim in-app form: the standalone module
/// with frozen vectors and the Bayesian bias check is still to come, and will
/// pin the encoding below.

/// Faces of the die: a d20.
const int kDiceFaces = 20;

/// Domain tag hashed ahead of the rolls, so the digest is never the same as
/// another use of SHA-512 over the same bytes. `v0`: interim, until the
/// module's frozen vectors pin the encoding.
const String kDiceDomainTag = 'great-wall/dragon-dice/v0';

/// Bits a fair roll carries: `log₂ 20 ≈ 4.32`.
final double kDiceBitsPerRoll = math.log(kDiceFaces) / math.ln2;

/// Fewest rolls for one point: `⌈32 / log₂ 20⌉ = 8`.
final int kDiceRollsPerPoint =
    (EncodingConstants.bitsPerPoint / kDiceBitsPerRoll).ceil();

/// Bits of a SHA-512 digest: the most points one roll sequence can give.
const int _kDigestBits = 512;

/// The rolls in [text]: whole numbers `1..`[kDiceFaces], separated by spaces
/// or commas. Throws [FormatException] on anything else; the message never
/// echoes the input.
List<int> parseDiceRolls(String text) {
  final List<String> parts = text
      .split(RegExp(r'[\s,]+'))
      .where((String p) => p.isNotEmpty)
      .toList();
  final List<int> rolls = <int>[];
  for (final String p in parts) {
    final int? v = int.tryParse(p);
    if (v == null || v < 1 || v > kDiceFaces) {
      throw const FormatException('rolls must be whole numbers 1-20');
    }
    rolls.add(v);
  }
  return rolls;
}

/// The bits of [points] points (MSB first, [EncodingConstants.bitsPerPoint]
/// each) from [rolls]: SHA-512 of the domain tag followed by the rolls, one
/// byte each, cut to the bits needed. Needs at least [kDiceRollsPerPoint] rolls
/// a point, each `1..`[kDiceFaces]; throws [ArgumentError] otherwise.
List<int> diceToBits(List<int> rolls, {int points = 1}) {
  final int bits = points * EncodingConstants.bitsPerPoint;
  if (points < 1 || bits > _kDigestBits) {
    throw ArgumentError.value(points, 'points');
  }
  if (rolls.length < points * kDiceRollsPerPoint) {
    throw ArgumentError('too few rolls');
  }
  if (rolls.any((int r) => r < 1 || r > kDiceFaces)) {
    throw ArgumentError('rolls must be 1-$kDiceFaces');
  }
  final List<int> tag = utf8.encode(kDiceDomainTag);
  final Uint8List input = Uint8List(tag.length + rolls.length)
    ..setAll(0, tag)
    ..setAll(tag.length, rolls);
  final Uint8List digest = Uint8List.fromList(sha512.convert(input).bytes);
  input.fillRange(0, input.length, 0);
  final List<int> all = Entropy.bytesToBits(digest);
  digest.fillRange(0, digest.length, 0);
  final List<int> out = List<int>.of(all.take(bits));
  Entropy.wipe(all);
  return out;
}
