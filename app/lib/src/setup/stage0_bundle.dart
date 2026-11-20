/// Stage 0's bundle: what stage 0 keeps once the provisional key is gone — σ
/// and the records of stage 0's cards — sealed under stage 0's own polynomial
/// `Sh₀`, hardened like the orbit's `H*` (Argon2d, `D` passes at profile `m`).
///
/// Stage 0 is lost to any wrench attack anyway, but a stolen copy must not be
/// a cheap oracle for its points: each guess at `Sh₀` costs the whole hardened
/// derivation. Its maps' parameters θ₀ ride in the clear, so the maps render
/// without σ: a user who forgot σ recalls two maps, and the bundle gives σ
/// back. θ₀ is a cheap check of a guessed σ, and σ comes from a date, so the
/// bundle gives σ away to whoever holds it — the threat model counts σ public.
///
/// The file is JSON: the clear header (`m`, `D`, a random salt, θ₀), the GCM
/// nonce and the ciphertext. The header is the GCM associated data, so it
/// cannot be altered unseen. The plaintext is padded to a fixed size, so the
/// file's size says nothing of the cards inside.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:celestial_peace_nf_core/celestial_peace_nf_core.dart'
    show Deck, MemCard;
import 'package:cryptography/cryptography.dart';

import '../ffi/core_bindings.dart' show Argon2Profile;
import 'fact_cards.dart' show kMapsPerStage;

/// Hardens [input]: [passes] Argon2d passes at [profile], each over the
/// previous digest ([GreatWallCore.hardenKey]). Injected, so tests run without
/// the engine.
typedef Harden = Future<Uint8List> Function(
    Uint8List input, Argon2Profile profile, int passes);

/// What the bundle holds: σ, stage 0's card records, and the maps of stage 0
/// you study (its selection card's answer).
class Stage0Contents {
  const Stage0Contents({
    required this.sigma,
    required this.cards,
    this.studied = const <int>[],
  });

  final String sigma;
  final List<MemCard> cards;
  final List<int> studied;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sigma': sigma,
        'deck': Deck(cards).toJson(),
        'studied': studied,
      };

  /// Throws a [FormatException] that echoes no value on any bad field.
  factory Stage0Contents.fromJson(Map<String, dynamic> json) {
    final Object? sigma = json['sigma'];
    final Object? deck = json['deck'];
    final Object? studied = json['studied'];
    if (sigma is! String ||
        deck is! Map<String, dynamic> ||
        studied is! List ||
        !studied.every(
            (Object? v) => v is int && v >= 1 && v <= kMapsPerStage)) {
      throw const FormatException('bad bundle');
    }
    return Stage0Contents(
      sigma: sigma,
      cards: Deck.fromJson(deck).cards,
      studied: <int>[for (final Object? v in studied) v! as int],
    );
  }
}

/// The clear header: how to derive the key, and stage 0's maps.
class Stage0Header {
  const Stage0Header({
    required this.profile,
    required this.passes,
    required this.salt,
    required this.theta,
  });

  /// `m` and `D` of the bundle's own derivation (not secret).
  final Argon2Profile profile;
  final int passes;

  /// Random per bundle, so one guess at `Sh₀` cannot test many bundles: θ₀
  /// alone is shared by setups harvested on the same date.
  final Uint8List salt;

  /// θ₀,ⱼ for the maps j = 1..[kMapsPerStage], in order.
  final List<Uint8List> theta;

  Map<String, dynamic> _json() => <String, dynamic>{
        'v': Stage0Bundle.formatVersion,
        'm': profile.value,
        'D': passes,
        'salt': _hex(salt),
        'theta': <String>[for (final Uint8List t in theta) _hex(t)],
      };

  /// The associated data: the header as written.
  List<int> get _aad => utf8.encode(jsonEncode(_json()));
}

/// The bundle's file name: the setup file's, with this after it.
const String kStage0Suffix = '.stage0';

/// Seal and open stage 0's bundle.
abstract final class Stage0Bundle {
  /// The file format's version (in the clear header).
  static const int formatVersion = 1;

  /// The derivation the default `D` aims at.
  static const Duration targetDerivation = Duration(minutes: 2);

  /// The padded plaintext's size: the length prefix, the JSON, then zeros.
  static const int paddedSize = 16 * 1024;

  static const int _saltLen = 16;
  static const int _nonceLen = 12; // 96-bit GCM nonce
  static const int _lengthLen = 4; // the payload's length, big-endian
  static const int _aesKeyLen = 32; // AES-256: the hardened digest's prefix

  /// Domain separation: the key's input is never an orbit step's.
  static final List<int> _tag = utf8.encode('greatwall-stage0-bundle-v1');

  static final AesGcm _aes = AesGcm.with256bits();

  /// The default `D`: passes that take about [targetDerivation], given the
  /// seconds one pass takes at the chosen profile; at least one.
  static int defaultPasses(double secondsPerPass) => max(
      1,
      (targetDerivation.inMicroseconds /
              Duration.microsecondsPerSecond /
              secondsPerPass)
          .ceil());

  /// The key's input: the tag, the salt and `Sh₀` ([shBytes]).
  static Uint8List keyInput(Uint8List salt, Uint8List shBytes) =>
      Uint8List.fromList(<int>[..._tag, ...salt, ...shBytes]);

  /// The bundle's key: `Sh₀` ([shBytes]) hardened as [h] says. Held while a
  /// bundle is open, so a save reseals it without deriving again.
  static Future<SecretKey> deriveKey(
      Stage0Header h, Uint8List shBytes, Harden harden) async {
    final Uint8List input = keyInput(h.salt, shBytes);
    try {
      final Uint8List digest = await harden(input, h.profile, h.passes);
      final SecretKey key = SecretKey(digest.sublist(0, _aesKeyLen));
      digest.fillRange(0, digest.length, 0);
      return key;
    } finally {
      input.fillRange(0, input.length, 0);
    }
  }

  /// The bundle file for [contents], under `Sh₀` ([shBytes]) hardened by
  /// [passes] passes at [profile]; [theta] is θ₀ (stage 0's maps). Throws a
  /// [FormatException] if the contents do not fit [paddedSize].
  static Future<Uint8List> seal({
    required Stage0Contents contents,
    required Uint8List shBytes,
    required Argon2Profile profile,
    required int passes,
    required List<Uint8List> theta,
    required Harden harden,
    Random? random,
  }) async {
    if (theta.length != kMapsPerStage || passes < 1) {
      throw ArgumentError('θ₀ needs one entry per map, D at least one pass');
    }
    final Random rng = random ?? Random.secure();
    final Stage0Header h = Stage0Header(
      profile: profile,
      passes: passes,
      salt: _bytes(rng, _saltLen),
      theta: theta,
    );
    return reseal(h, contents, await deriveKey(h, shBytes, harden),
        random: rng);
  }

  /// The bundle file for [contents] under an open bundle's [key] and header
  /// [h]: a save, with a fresh nonce and no new derivation.
  static Future<Uint8List> reseal(
      Stage0Header h, Stage0Contents contents, SecretKey key,
      {Random? random}) async {
    final Random rng = random ?? Random.secure();
    final List<int> json = utf8.encode(jsonEncode(contents.toJson()));
    if (_lengthLen + json.length > paddedSize) {
      throw const FormatException('Stage 0 holds too much to seal.');
    }
    final Uint8List plain = Uint8List(paddedSize);
    ByteData.sublistView(plain).setUint32(0, json.length);
    plain.setRange(_lengthLen, _lengthLen + json.length, json);
    try {
      final SecretBox box = await _aes.encrypt(plain,
          secretKey: key, nonce: _bytes(rng, _nonceLen), aad: h._aad);
      return Uint8List.fromList(utf8.encode(jsonEncode(<String, dynamic>{
        ...h._json(),
        'nonce': _hex(box.nonce),
        'ct': base64Encode(<int>[...box.cipherText, ...box.mac.bytes]),
      })));
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  /// The clear header of a bundle [file], or a [FormatException] if it is not
  /// one. Needs no key: it is what the maps render from.
  static Stage0Header header(Uint8List file) => _parse(file).$1;

  /// Whether [file] reads as a stage 0 bundle.
  static bool isBundle(Uint8List file) {
    try {
      _parse(file);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// Open a bundle [file] with `Sh₀` ([shBytes]). Throws a generic
  /// [FormatException] when the points are wrong or the file was altered —
  /// GCM makes them indistinguishable.
  static Future<Stage0Contents> open(
          Uint8List file, Uint8List shBytes, Harden harden) async =>
      openWithKey(
          file, await deriveKey(_parse(file).$1, shBytes, harden));

  /// Open a bundle [file] with its [key] ([deriveKey]); throws as [open].
  static Future<Stage0Contents> openWithKey(
      Uint8List file, SecretKey key) async {
    const FormatException unreadable =
        FormatException('These points do not open the bundle.');
    final (Stage0Header h, List<int> nonce, List<int> sealed) = _parse(file);
    final SecretBox box = SecretBox(
      sealed.sublist(0, sealed.length - _tagLen),
      nonce: nonce,
      mac: Mac(sealed.sublist(sealed.length - _tagLen)),
    );
    List<int> plain;
    try {
      plain = await _aes.decrypt(box, secretKey: key, aad: h._aad);
    } on SecretBoxAuthenticationError {
      throw unreadable;
    }
    try {
      final int length = ByteData.sublistView(Uint8List.fromList(plain))
          .getUint32(0);
      if (_lengthLen + length > plain.length) throw unreadable;
      final Object? decoded = jsonDecode(
          utf8.decode(plain.sublist(_lengthLen, _lengthLen + length)));
      if (decoded is! Map<String, dynamic>) throw unreadable;
      return Stage0Contents.fromJson(decoded);
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  static const int _tagLen = 16; // 128-bit GCM tag

  static (Stage0Header, List<int>, List<int>) _parse(Uint8List file) {
    const FormatException bad = FormatException('not a stage 0 bundle');
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(file));
    } on Object {
      throw bad;
    }
    if (json is! Map<String, dynamic> || json['v'] != formatVersion) throw bad;
    final Object? m = json['m'], d = json['D'], salt = json['salt'];
    final Object? theta = json['theta'], nonce = json['nonce'], ct = json['ct'];
    if (m is! int ||
        d is! int ||
        d < 1 ||
        salt is! String ||
        theta is! List ||
        theta.length != kMapsPerStage ||
        nonce is! String ||
        ct is! String) {
      throw bad;
    }
    final Argon2Profile profile = Argon2Profile.values.firstWhere(
        (Argon2Profile p) => p.value == m,
        orElse: () => throw bad);
    final List<int> sealed;
    try {
      sealed = base64Decode(ct);
    } on FormatException {
      throw bad;
    }
    final Uint8List? saltBytes = _unhex(salt);
    final Uint8List? nonceBytes = _unhex(nonce);
    final List<Uint8List?> thetaBytes = <Uint8List?>[
      for (final Object? t in theta) t is String ? _unhex(t) : null,
    ];
    if (saltBytes == null ||
        nonceBytes == null ||
        thetaBytes.contains(null) ||
        sealed.length < _tagLen) {
      throw bad;
    }
    return (
      Stage0Header(
        profile: profile,
        passes: d,
        salt: saltBytes,
        theta: <Uint8List>[for (final Uint8List? t in thetaBytes) t!],
      ),
      nonceBytes,
      sealed,
    );
  }

  static Uint8List _bytes(Random rng, int n) =>
      Uint8List.fromList(List<int>.generate(n, (_) => rng.nextInt(256)));
}

String _hex(List<int> b) =>
    b.map((int v) => v.toRadixString(16).padLeft(2, '0')).join();

Uint8List? _unhex(String h) {
  if (h.length.isOdd || !RegExp(r'^[0-9a-f]*$').hasMatch(h)) return null;
  return Uint8List.fromList(<int>[
    for (int i = 0; i < h.length; i += 2)
      int.parse(h.substring(i, i + 2), radix: 16),
  ]);
}
