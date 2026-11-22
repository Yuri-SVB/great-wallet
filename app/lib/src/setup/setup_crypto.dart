import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Result of sealing a vault: the ciphertext [fileBytes] (stored on disk) and
/// the 16-byte provisional [key] (rendered by the caller as a byte-mode QR
/// and/or 32 hex digits, then wiped). File + key are a lock and its key — keep
/// the file anywhere, guard the key, destroy the key to render the file
/// unrecoverable.
class SealedVault {
  SealedVault(this.fileBytes, this.key);
  final Uint8List fileBytes;
  final Uint8List key;
}

/// Password-free encryption for the provisional-key vault: **AES-256-GCM**
/// (NIST SP 800-38D) keyed by **Argon2id** (RFC 9106) over a **128-bit key** and
/// a random per-file salt. The bulky ciphertext goes to a file; the only secret
/// the user guards is the 16-byte key.
///
/// **The file** is bytes indistinguishable from random: `salt ‖ nonce ‖
/// ciphertext ‖ tag`, with nothing in the clear — no format name, no version,
/// no settings (they are constants), no dates. A leaked file that is not
/// deciphered must not tell an attacker when its owner will next open it
/// (next-steps/timing-concealment-onions-and-mock-flows.md).
///
/// **The plaintext is padded to a random length** ([paddedMin] plus a random
/// amount below [paddedSpread]): the payload's length (4 bytes, big-endian),
/// the payload JSON, then zeros. So the file's size says nothing of how many
/// stages or maps it holds, and it changes with every save. A payload larger
/// than [paddedMin] (stage 1's passes, kept while D is open) is padded to the
/// next power of two instead: its size tells only its order of magnitude.
/// Fields to be sealed under other keys later (Star Clock) nest inside the
/// payload.
///
/// The key is never an arbitrary password — always 128 bits, handled three ways
/// (KISS): generated → byte-mode QR (hand-coloured, scanned back, never read);
/// generated → 32 hex (blindly copied into a password manager); or supplied by
/// the user as 32 hex (own entropy source). All three are the same 16 bytes fed
/// to `Argon2id(keyBytes, salt)`, so load is one path. 16 raw bytes ride a QR
/// **version 1 (21×21)** in byte mode at EC level L (17-byte capacity).
class SetupCrypto {
  SetupCrypto._();

  /// 128-bit key = 16 bytes = 32 hex digits. 16 bytes fit a byte-mode QR v1 at
  /// EC level L (capacity 17 bytes). The optional 256-bit "tin-foil" key = 32
  /// bytes = 64 hex digits, which rides a byte-mode QR v2 (25×25) at EC-L. Both
  /// lengths feed Argon2id the same way; the length is the user's choice and is
  /// never stored — load accepts either.
  static const int keyBits = 128;
  static const int keyLenBytes = keyBits ~/ 8; // 16
  static const int keyHexDigits = keyLenBytes * 2; // 32
  static const int keyBits256 = 256;
  static const int keyLenBytes256 = keyBits256 ~/ 8; // 32
  static const int keyHexDigits256 = keyLenBytes256 * 2; // 64

  /// Whether [n] is an accepted provisional-key length in bytes (16 or 32).
  static bool isValidKeyLen(int n) =>
      n == keyLenBytes || n == keyLenBytes256;

  /// The padded plaintext's length: at least this, which any payload must fit
  /// in (with its length prefix) …
  static const int paddedMin = 256 * 1024;

  /// … plus a random amount below this.
  static const int paddedSpread = 256 * 1024;

  // RFC 9106 §4 "second recommended" Argon2id parameters: 64 MiB, t=3, p=4.
  // Constants: the file carries no settings.
  static const int _argonMemKiB = 64 * 1024;
  static const int _argonIterations = 3;
  static const int _argonParallelism = 4;
  static const int _aesKeyLen = 32; // AES-256
  static const int _saltLen = 16;
  static const int _nonceLen = 12; // 96-bit GCM nonce
  static const int _tagLen = 16; // 128-bit GCM tag
  static const int _lengthLen = 4; // the payload's length, big-endian

  /// Associated data: the format's name, authenticated though never stored.
  static final List<int> _aad = utf8.encode('greatwall-setup-v4');

  static final AesGcm _aes = AesGcm.with256bits();

  static Future<SecretKey> _deriveAesKey(List<int> keyBytes, List<int> salt) {
    final Argon2id argon2 = Argon2id(
      memory: _argonMemKiB,
      iterations: _argonIterations,
      parallelism: _argonParallelism,
      hashLength: _aesKeyLen,
    );
    return argon2.deriveKey(
      secretKey: SecretKey(keyBytes),
      nonce: salt, // the package names the Argon2 salt `nonce`
    );
  }

  /// The padded plaintext's length for [n] bytes of length prefix and JSON:
  /// [paddedMin] plus a random amount below [paddedSpread]; above [paddedMin]
  /// (a power of two), the next power of two.
  static int paddedSize(int n, Random rng) {
    if (n <= paddedMin) return paddedMin + rng.nextInt(paddedSpread);
    int size = paddedMin;
    while (size < n) {
      size *= 2;
    }
    return size;
  }

  /// Encrypt a JSON [payload] (the orbit vault's), padded to a random length,
  /// and return the file plus the key. Uses [providedKey] (the user's own
  /// entropy, 16 or 32 bytes) if given, else generates a fresh
  /// [genLenBytes]-byte key (128-bit by default, 32 for the 256-bit mode). The
  /// caller owns and wipes [SealedVault.key]; the plaintext is zeroed here.
  static Future<SealedVault> sealPayload(
    Map<String, dynamic> payload, {
    Uint8List? providedKey,
    int genLenBytes = keyLenBytes,
  }) async {
    final List<int> json = utf8.encode(jsonEncode(payload));
    final Random rng = Random.secure();
    final Uint8List plaintext = Uint8List(
        paddedSize(_lengthLen + json.length, rng)); // zeros: the padding
    ByteData.sublistView(plaintext).setUint32(0, json.length);
    plaintext.setRange(_lengthLen, _lengthLen + json.length, json);
    _zero(json);
    final Uint8List key = providedKey != null
        ? Uint8List.fromList(providedKey)
        : _randomBytes(genLenBytes);
    final Uint8List salt = _randomBytes(_saltLen);
    final Uint8List nonce = _randomBytes(_nonceLen);
    try {
      final SecretKey aesKey = await _deriveAesKey(key, salt);
      final SecretBox box = await _aes.encrypt(plaintext,
          secretKey: aesKey, nonce: nonce, aad: _aad);
      final BytesBuilder file = BytesBuilder(copy: false)
        ..add(salt)
        ..add(box.nonce)
        ..add(box.cipherText)
        ..add(box.mac.bytes);
      return SealedVault(file.toBytes(), key);
    } finally {
      _zero(plaintext);
    }
  }

  /// Decrypt a file produced by [sealPayload] back into its raw JSON payload
  /// map, using the 16- or 32-byte [keyBytes] (from a scanned QR or parsed
  /// hex). The caller reconstructs the vault from it. Throws a generic
  /// [FormatException] on a wrong key, a file that is not a setup file, or
  /// tampering — GCM authentication makes them indistinguishable.
  static Future<Map<String, dynamic>> openPayload(
      Uint8List bytes, Uint8List keyBytes) async {
    const FormatException unreadable =
        FormatException('Could not decrypt — wrong key or corrupt file.');
    if (bytes.length < _saltLen + _nonceLen + _lengthLen + _tagLen) {
      throw unreadable;
    }
    final int ctEnd = bytes.length - _tagLen;
    final SecretKey aesKey =
        await _deriveAesKey(keyBytes, bytes.sublist(0, _saltLen));
    final SecretBox box = SecretBox(
      bytes.sublist(_saltLen + _nonceLen, ctEnd),
      nonce: bytes.sublist(_saltLen, _saltLen + _nonceLen),
      mac: Mac(bytes.sublist(ctEnd)),
    );
    List<int> plaintext;
    try {
      plaintext = await _aes.decrypt(box, secretKey: aesKey, aad: _aad);
    } on SecretBoxAuthenticationError {
      throw unreadable;
    }
    try {
      int length = 0;
      for (int i = 0; i < _lengthLen; i++) {
        length = (length << 8) | plaintext[i]; // big-endian
      }
      if (_lengthLen + length > plaintext.length) throw unreadable;
      final Object? decoded = jsonDecode(
          utf8.decode(plaintext.sublist(_lengthLen, _lengthLen + length)));
      if (decoded is! Map<String, dynamic>) throw unreadable;
      return decoded;
    } on FormatException {
      throw unreadable;
    } finally {
      _zero(plaintext);
    }
  }

  /// Parse 32 hex digits (128-bit) or 64 (256-bit), whitespace ignored, any
  /// case, into the key. Throws a generic [FormatException] on bad input.
  static Uint8List hexToKey(String hex) {
    final String clean = hex.replaceAll(RegExp(r'\s'), '').toUpperCase();
    if ((clean.length != keyHexDigits && clean.length != keyHexDigits256) ||
        !RegExp(r'^[0-9A-F]+$').hasMatch(clean)) {
      throw const FormatException('A key is 32 or 64 hex digits (0–9 A–F).');
    }
    final int lenBytes = clean.length ~/ 2;
    final Uint8List out = Uint8List(lenBytes);
    for (int i = 0; i < lenBytes; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// The key as uppercase hex digits (the manager / manual form).
  static String keyToHex(Uint8List key) {
    final StringBuffer sb = StringBuffer();
    for (final int b in key) {
      sb.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
    return sb.toString();
  }

  static Uint8List _randomBytes(int n) {
    final Random rng = Random.secure();
    final Uint8List out = Uint8List(n);
    for (int i = 0; i < n; i++) {
      out[i] = rng.nextInt(256);
    }
    return out;
  }

  static void _zero(List<int> b) {
    for (int i = 0; i < b.length; i++) {
      b[i] = 0;
    }
  }
}
