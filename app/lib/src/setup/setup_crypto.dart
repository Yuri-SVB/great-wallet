import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'setup_vault.dart';

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

/// Password-free encryption for the provisional-key [SetupVault]: **AES-256-GCM**
/// (NIST SP 800-38D) keyed by **Argon2id** (RFC 9106) over a **128-bit key** and
/// a random per-file salt. The bulky ciphertext goes to a file; the only secret
/// the user guards is the 16-byte key.
///
/// The key is never an arbitrary password — always 128 bits, handled three ways
/// (KISS): generated → byte-mode QR (hand-coloured, scanned back, never read);
/// generated → 32 hex (blindly copied into a password manager); or supplied by
/// the user as 32 hex (own entropy source). All three are the same 16 bytes fed
/// to `Argon2id(keyBytes, salt)`, so load is one path. 16 raw bytes ride a QR
/// **version 1 (21×21)** in byte mode at EC level L (17-byte capacity).
class SetupCrypto {
  SetupCrypto._();

  static const String magic = 'greatwall-provisional-vault';
  static const int version = 3; // 3: 128-bit raw-byte key (2 was password/key)

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

  // RFC 9106 §4 "second recommended" Argon2id parameters: 64 MiB, t=3, p=4.
  static const int _argonMemKiB = 64 * 1024;
  static const int _argonIterations = 3;
  static const int _argonParallelism = 4;
  static const int _aesKeyLen = 32; // AES-256
  static const int _saltLen = 16;
  static const int _nonceLen = 12; // 96-bit GCM nonce

  // Bounds for envelope-supplied KDF parameters (anti-DoS on load).
  static const int _minMemKiB = 8 * 1024;
  static const int _maxMemKiB = 2 * 1024 * 1024;
  static const int _maxIterations = 16;
  static const int _maxParallelism = 16;

  static final AesGcm _aes = AesGcm.with256bits();

  static Future<SecretKey> _deriveAesKey(
    List<int> keyBytes,
    List<int> salt, {
    required int memKiB,
    required int iterations,
    required int parallelism,
  }) {
    final Argon2id argon2 = Argon2id(
      memory: memKiB,
      iterations: iterations,
      parallelism: parallelism,
      hashLength: _aesKeyLen,
    );
    return argon2.deriveKey(
      secretKey: SecretKey(keyBytes),
      nonce: salt, // the package names the Argon2 salt `nonce`
    );
  }

  /// Encrypt the legacy-chain [vault]. Thin wrapper over [sealPayload] on
  /// `vault.toJson()`; see it for the key/parameter semantics.
  static Future<SealedVault> sealVault(
    SetupVault vault, {
    Uint8List? providedKey,
    int genLenBytes = keyLenBytes,
  }) =>
      sealPayload(vault.toJson(),
          providedKey: providedKey, genLenBytes: genLenBytes);

  /// Encrypt an arbitrary JSON [payload] and return the ciphertext envelope plus
  /// the key — the protocol-agnostic core shared by the chain [SetupVault] and
  /// the [OrbitVault]. Uses [providedKey] (the user's own entropy, 16 or 32
  /// bytes) if given, else generates a fresh [genLenBytes]-byte key (128-bit by
  /// default, 32 for the 256-bit mode). The caller owns and wipes
  /// [SealedVault.key]; the plaintext JSON is zeroed here.
  static Future<SealedVault> sealPayload(
    Map<String, dynamic> payload, {
    Uint8List? providedKey,
    int genLenBytes = keyLenBytes,
  }) async {
    final Uint8List key = providedKey != null
        ? Uint8List.fromList(providedKey)
        : _randomBytes(genLenBytes);
    final Uint8List salt = _randomBytes(_saltLen);
    final Uint8List nonce = _randomBytes(_nonceLen);
    final List<int> plaintext = utf8.encode(jsonEncode(payload));
    try {
      final SecretKey aesKey = await _deriveAesKey(
        key,
        salt,
        memKiB: _argonMemKiB,
        iterations: _argonIterations,
        parallelism: _argonParallelism,
      );
      final SecretBox box =
          await _aes.encrypt(plaintext, secretKey: aesKey, nonce: nonce);
      final Map<String, dynamic> envelope = <String, dynamic>{
        'f': magic,
        'v': version,
        'kdf': <String, dynamic>{
          'alg': 'argon2id',
          'm': _argonMemKiB,
          't': _argonIterations,
          'p': _argonParallelism,
          'salt': base64.encode(salt),
        },
        'cipher': 'aes-256-gcm',
        'nonce': base64.encode(box.nonce),
        'ct': base64.encode(box.cipherText),
        'tag': base64.encode(box.mac.bytes),
      };
      return SealedVault(
        Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
        key,
      );
    } finally {
      _zero(plaintext);
    }
  }

  /// Decrypt an envelope produced by [sealVault] back into a legacy-chain
  /// [SetupVault]. Thin wrapper over [openPayload]; see it for error semantics.
  static Future<SetupVault> openVault(Uint8List bytes, Uint8List keyBytes) async =>
      SetupVault.fromJson(await openPayload(bytes, keyBytes));

  /// Decrypt an envelope produced by [sealPayload]/[sealVault] back into its raw
  /// JSON payload map, using the 16- or 32-byte [keyBytes] (from a scanned QR or
  /// parsed hex). The caller reconstructs the concrete vault type
  /// ([SetupVault.fromJson] or [OrbitVault.fromJson]), which discriminates the
  /// payload shape. Throws a generic [FormatException] on a non-vault file,
  /// unsupported version, wrong key, or tampering — GCM authentication makes
  /// "wrong key" and "corrupt" indistinguishable.
  static Future<Map<String, dynamic>> openPayload(
      Uint8List bytes, Uint8List keyBytes) async {
    final Map<String, dynamic> env;
    try {
      env = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Not a Great Wall vault file.');
    }
    if (env['f'] != magic || env['v'] != version) {
      throw const FormatException('Unsupported or corrupt vault file.');
    }
    final Object? kdf = env['kdf'];
    if (kdf is! Map<String, dynamic>) {
      throw const FormatException('Unsupported or corrupt vault file.');
    }
    final int memKiB = _boundedInt(kdf['m'], _minMemKiB, _maxMemKiB);
    final int iterations = _boundedInt(kdf['t'], 1, _maxIterations);
    final int parallelism = _boundedInt(kdf['p'], 1, _maxParallelism);
    final List<int> salt = _b64(kdf['salt']);
    final List<int> nonce = _b64(env['nonce']);
    final List<int> ct = _b64(env['ct']);
    final List<int> tag = _b64(env['tag']);

    final SecretKey aesKey = await _deriveAesKey(
      keyBytes,
      salt,
      memKiB: memKiB,
      iterations: iterations,
      parallelism: parallelism,
    );
    final SecretBox box = SecretBox(ct, nonce: nonce, mac: Mac(tag));
    List<int> plaintext;
    try {
      plaintext = await _aes.decrypt(box, secretKey: aesKey);
    } on SecretBoxAuthenticationError {
      throw const FormatException(
          'Could not decrypt — wrong key or corrupt file.');
    }
    try {
      final Object? decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Could not decrypt — corrupt file.');
      }
      return decoded;
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

  static int _boundedInt(Object? v, int lo, int hi) {
    if (v is! int || v < lo || v > hi) {
      throw const FormatException('Unsupported or corrupt vault file.');
    }
    return v;
  }

  static List<int> _b64(Object? v) {
    if (v is! String) {
      throw const FormatException('Unsupported or corrupt vault file.');
    }
    try {
      return base64.decode(v);
    } catch (_) {
      throw const FormatException('Unsupported or corrupt vault file.');
    }
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
