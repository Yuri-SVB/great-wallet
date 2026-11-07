import 'dart:math';
import 'dart:typed_data';

/// Bit/byte helpers for the entropy that flows between the user's fractal
/// recall and the wallet seed.
///
/// The full key-derivation chain (raw entropy -> BIP39 mnemonic ->
/// PBKDF2 seed -> BIP32 xpriv) is great-wall-core's responsibility and is NOT
/// re-implemented here (SCOPE.md: "Key derivation, BIP39, BIP32 ... never
/// handled in the UX layer"; it belongs to the engine/app boundary, surfaced
/// over FFI in a later pass). This file covers only the bit plumbing the Setup
/// orchestration needs: the points' 32-bit chunks.
class Entropy {
  Entropy._();

  /// Pack a list of 0/1 ints MSB-first into bytes. Trailing bits in a final
  /// partial byte are left-aligned (shifted up), matching `bits_to_bytes` in
  /// great-wall-core/burning_ship/encoding.py.
  static Uint8List bitsToBytes(List<int> bits) {
    final int nBytes = (bits.length + 7) ~/ 8;
    final Uint8List out = Uint8List(nBytes);
    for (int i = 0; i < bits.length; i++) {
      if (bits[i] != 0) {
        out[i >> 3] |= 1 << (7 - (i & 7));
      }
    }
    return out;
  }

  /// Expand bytes to a list of 0/1 ints, MSB-first. Inverse of [bitsToBytes]
  /// for whole-byte inputs.
  static List<int> bytesToBits(Uint8List bytes) {
    final List<int> bits = List<int>.filled(bytes.length * 8, 0);
    for (int i = 0; i < bytes.length; i++) {
      for (int j = 0; j < 8; j++) {
        bits[i * 8 + j] = (bytes[i] >> (7 - j)) & 1;
      }
    }
    return bits;
  }

  /// The Argon2 input for a chain link: the cumulative bits of every point that
  /// precedes the stage being derived, packed to bytes.
  ///
  /// This is `bits_to_bytes(prior_bits)` at its **natural length** — one byte
  /// per 8 prior bits — exactly what great-wall-core's `derive_stage_params`
  /// feeds (argon2_pipeline.py: `data = bits_to_bytes(prior_bits)`).
  static Uint8List argon2Input(List<int> priorBits) => bitsToBytes(priorBits);

  // NOTE: the Stage-0 chain-input layout and salt/pepper canonicalisation are
  // PROTOCOL and live in the shared engine (see GreatWallCore.chainInput /
  // canonicalizeSaltPepper, backed by bs_chain_input / bs_salt_pepper_-
  // canonicalize). They are deliberately NOT reimplemented here, so the wallet
  // and great-wall-core produce byte-identical seeds for the same text.

  /// Generate `bitCount` cryptographically-random bits using a secure RNG.
  ///
  /// Setup is a "write-only operation on the user's memory" (ARCHITECTURE.md
  /// §"Invariants"): a fresh root is generated here, encoded onto the fractal,
  /// and the plaintext destroyed. `bitCount` must be a multiple of 8.
  static List<int> randomBits(int bitCount, {Random? random}) {
    assert(bitCount % 8 == 0, 'bitCount must be a whole number of bytes');
    final Random rng = random ?? Random.secure();
    final Uint8List bytes = Uint8List(bitCount ~/ 8);
    for (int i = 0; i < bytes.length; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return bytesToBits(bytes);
  }

  /// Parse an uppercase-hex string into a 0/1 bit list, 4 bits per digit,
  /// MSB-first. Spaces (grouping) are ignored. Used for blind entropy input from
  /// a source the user trusts more than the device RNG. Throws [FormatException]
  /// on an empty string or any non-`[0-9A-F]` character — the message is generic
  /// (never echoes the value).
  static List<int> hexToBits(String hex) {
    final String clean = hex.replaceAll(RegExp(r'\s'), '');
    if (clean.isEmpty) throw const FormatException('no hex digits');
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(clean)) {
      throw const FormatException('hex must be uppercase 0-9 A-F');
    }
    final List<int> bits = <int>[];
    for (int i = 0; i < clean.length; i++) {
      final int v = int.parse(clean[i], radix: 16);
      for (int b = 3; b >= 0; b--) {
        bits.add((v >> b) & 1);
      }
    }
    return bits;
  }

  /// Overwrite a bit list with zeros once it is no longer needed.
  static void wipe(List<int> bits) {
    for (int i = 0; i < bits.length; i++) {
      bits[i] = 0;
    }
  }
}
